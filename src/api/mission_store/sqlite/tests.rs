use super::{assistant_message_metadata, AssistantMessageMetadataInput, SqliteMissionStore};
use crate::agents::{
    CompletionConfidence, CompletionEvidence, CompletionSignal, CostSource, TerminalReason,
};
use crate::api::control::AgentEvent;
use crate::api::mission_store::{
    now_string, Automation, AutomationDriver, AwaitingKind, CommandSource, FreshSession,
    MissionExecutionState, MissionMode, MissionProjectPatch, MissionStatus, MissionStore,
    MissionToolExecution, MissionToolExecutionState, PalomaCooldownState, PalomaDecision,
    PalomaMissionCard, PalomaSchedulerJob, PalomaUserPreferences, RetryConfig, StopPolicy,
    TelegramAlert, TelegramAlertPreference, TelegramChannel, TelegramConversation,
    TelegramConversationMessage, TelegramConversationMessageDirection,
    TelegramMissionInterestLevel, TelegramMissionSubscription, TelegramStructuredMemoryEntry,
    TelegramStructuredMemoryKind, TelegramStructuredMemoryScope, TelegramTriggerMode, TelegramUser,
    TelegramUserRole, TelegramWorkflow, TelegramWorkflowEvent, TelegramWorkflowKind,
    TelegramWorkflowStatus, TriggerType,
};
use crate::cost::TokenUsage;
use rusqlite::params;
use serde_json::json;
use uuid::Uuid;

#[tokio::test]
async fn native_claim_sql_failure_rolls_back_insert_and_release_transaction() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteMissionStore::new(dir.path().into(), "claim-failure")
        .await
        .unwrap();
    let m = store
        .create_mission(Some("claim"), None, None, None, None, Some("grok"), None)
        .await
        .unwrap();
    // Fail AFTER attempt insertion, while writing its rollback receipt.
    store.conn.lock().await.execute_batch("CREATE TRIGGER fail_claim BEFORE INSERT ON mission_native_prompt_claims BEGIN SELECT RAISE(ABORT, 'injected claim failure'); END;").unwrap();
    let failed = Uuid::new_v4();
    assert!(store
        .claim_native_prompt(m.id, "grok", None, None, failed)
        .await
        .is_err());
    assert!(!store.native_prompt_attempted(m.id, "grok").await.unwrap());
    store
        .conn
        .lock()
        .await
        .execute_batch("DROP TRIGGER fail_claim;")
        .unwrap();
    let receipt = Uuid::new_v4();
    assert!(store
        .claim_native_prompt(m.id, "grok", None, None, receipt)
        .await
        .unwrap());
    assert!(!store
        .release_native_prompt_no_launch(m.id, "grok", None, failed)
        .await
        .unwrap());
    // Fail AFTER token deletion: transaction rollback must restore both rows.
    store.conn.lock().await.execute_batch("CREATE TRIGGER fail_release BEFORE DELETE ON mission_native_prompt_attempts BEGIN SELECT RAISE(ABORT, 'injected release failure'); END;").unwrap();
    assert!(store
        .release_native_prompt_no_launch(m.id, "grok", None, receipt)
        .await
        .is_err());
    assert!(store.native_prompt_attempted(m.id, "grok").await.unwrap());
    store
        .conn
        .lock()
        .await
        .execute_batch("DROP TRIGGER fail_release;")
        .unwrap();
    assert!(store
        .release_native_prompt_no_launch(m.id, "grok", None, receipt)
        .await
        .unwrap());
    let reopened = SqliteMissionStore::new(dir.path().into(), "claim-failure")
        .await
        .unwrap();
    assert!(!reopened
        .native_prompt_attempted(m.id, "grok")
        .await
        .unwrap());
}

#[tokio::test]
async fn reparent_child_missions_moves_only_direct_children() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let create = |title: &'static str, parent: Option<Uuid>| {
        let store = &store;
        async move {
            store
                .create_mission_with_parent(
                    Some(title),
                    None,
                    None,
                    None,
                    None,
                    false,
                    None,
                    None,
                    parent,
                    None,
                )
                .await
                .expect("create")
        }
    };
    let old = create("old", None).await;
    let new = create("new", None).await;
    let worker = create("worker", Some(old.id)).await;
    let grandchild = create("grandchild", Some(worker.id)).await;
    let moved = store.reparent_child_missions(old.id, new.id).await.unwrap();
    assert_eq!(moved, vec![worker.id]);
    assert!(store.get_child_missions(old.id).await.unwrap().is_empty());
    assert_eq!(
        store.get_child_missions(new.id).await.unwrap()[0].id,
        worker.id
    );
    assert_eq!(
        store.get_child_missions(worker.id).await.unwrap()[0].id,
        grandchild.id
    );
}

#[tokio::test]
async fn codex_fast_mode_round_trips_and_updates() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission_with_parent(
            Some("fast codex"),
            None,
            None,
            Some("gpt-5.6-sol"),
            Some("low"),
            true,
            Some("codex"),
            None,
            None,
            None,
        )
        .await
        .expect("create fast mission");
    assert!(
        store
            .get_mission(mission.id)
            .await
            .unwrap()
            .unwrap()
            .fast_mode
    );

    let updated = store
        .update_mission_run_settings(
            mission.id,
            None,
            None,
            None,
            None,
            Some(false),
            None,
            None,
            "new-session",
        )
        .await
        .expect("disable fast mode");
    assert!(!updated.fast_mode);
}

#[tokio::test]
async fn log_events_batch_keeps_order_and_sequences() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let a = store
        .create_mission(Some("A"), None, None, None, None, None, None)
        .await
        .unwrap();
    let b = store
        .create_mission(Some("B"), None, None, None, None, None, None)
        .await
        .unwrap();
    let title = |id, t: &str| AgentEvent::MissionStatusChanged {
        completion: None,
        execution: None,
        mission_id: id,
        status: MissionStatus::Active,
        summary: Some(t.into()),
    };
    let batch: Vec<(Uuid, AgentEvent)> = (0..300)
        .map(|i| {
            if i % 3 == 0 {
                (b.id, title(b.id, &format!("b{i}")))
            } else {
                (a.id, title(a.id, &format!("a{i}")))
            }
        })
        .collect();
    let results = store.log_events(batch).await;
    assert_eq!(results.len(), 300);
    assert!(results.iter().all(Result::is_ok));
    let events = store.get_events(a.id, None, None, None).await.unwrap();
    assert_eq!(events.len(), 200);
    let seqs: Vec<i64> = events.iter().map(|e| e.sequence).collect();
    assert!(seqs.windows(2).all(|w| w[1] > w[0]), "increasing sequences");
    assert!(events[0].content.contains("a1") && events[199].content.contains("a299"));
    assert_eq!(
        store
            .get_events(b.id, None, None, None)
            .await
            .unwrap()
            .len(),
        100
    );
}

#[tokio::test]
async fn status_events_global_feed_paginates_by_timestamp() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");

    // Three missions, one status change each, backdated to distinct
    // timestamps (force_backdate_for_test stamps all of a mission's
    // events at once, hence one mission per instant).
    let cases = [
        ("Alpha", MissionStatus::Completed, "2026-06-01T10:00:00Z"),
        ("Bravo", MissionStatus::Failed, "2026-06-02T10:00:00Z"),
        (
            "Charlie",
            MissionStatus::AwaitingUser,
            "2026-06-03T10:00:00Z",
        ),
    ];
    let mut ids = Vec::new();
    for (title, status, ts) in &cases {
        let mission = store
            .create_mission(Some(title), None, None, None, None, None, None)
            .await
            .expect("mission");
        store
            .log_event(
                mission.id,
                &AgentEvent::MissionStatusChanged {
                    completion: None,
                    execution: None,
                    mission_id: mission.id,
                    status: *status,
                    summary: Some(format!("{title} status change")),
                },
            )
            .await
            .expect("log status event");
        // Noise: a different event type that must not appear in the feed.
        store
            .log_event(
                mission.id,
                &AgentEvent::MissionTitleChanged {
                    mission_id: mission.id,
                    title: title.to_string(),
                },
            )
            .await
            .expect("log noise event");
        store
            .force_backdate_for_test(mission.id, ts)
            .await
            .expect("backdate");
        ids.push(mission.id);
    }

    // Full feed: newest first, status events only.
    let all = store
        .get_status_events_global(None, 10)
        .await
        .expect("global feed");
    assert_eq!(all.len(), 3);
    assert!(all.iter().all(|e| e.event_type == "mission_status_changed"));
    assert_eq!(all[0].timestamp, "2026-06-03T10:00:00Z");
    assert_eq!(all[0].metadata["status"], "awaiting_user");
    assert_eq!(all[2].timestamp, "2026-06-01T10:00:00Z");

    // Cursor pagination: page of 2, then everything strictly older.
    let page = store
        .get_status_events_global(None, 2)
        .await
        .expect("first page");
    assert_eq!(page.len(), 2);
    let older = store
        .get_status_events_global(Some(&page[1].timestamp), 10)
        .await
        .expect("second page");
    assert_eq!(older.len(), 1);
    assert_eq!(older[0].timestamp, "2026-06-01T10:00:00Z");

    // Summaries decorate the feed.
    let summaries = store.get_mission_summaries(&ids).await.expect("summaries");
    assert_eq!(summaries.len(), 3);
    assert_eq!(summaries[&ids[0]].title.as_deref(), Some("Alpha"));
}

fn test_memory_entry(
    channel_id: Uuid,
    chat_id: i64,
    scope: TelegramStructuredMemoryScope,
    kind: TelegramStructuredMemoryKind,
    label: Option<&str>,
    value: &str,
    subject_user_id: Option<i64>,
) -> TelegramStructuredMemoryEntry {
    TelegramStructuredMemoryEntry {
        id: Uuid::new_v4(),
        channel_id,
        chat_id,
        mission_id: None,
        scope,
        kind,
        label: label.map(|value| value.to_string()),
        value: value.to_string(),
        subject_user_id,
        subject_username: subject_user_id.map(|_| "th0rgal".to_string()),
        subject_display_name: subject_user_id.map(|_| "@th0rgal".to_string()),
        source_message_id: Some(1),
        source_role: "user".to_string(),
        created_at: "2026-04-08T10:00:00Z".to_string(),
        updated_at: "2026-04-08T10:00:00Z".to_string(),
    }
}

async fn create_test_channel(store: &SqliteMissionStore) -> Uuid {
    let mission = store
        .create_mission(
            Some("Telegram memory tests"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission");
    let channel = TelegramChannel {
        id: Uuid::new_v4(),
        mission_id: mission.id,
        bot_token: format!("test-token-{}", Uuid::new_v4()),
        bot_username: Some("ana_lfgbot_test".to_string()),
        allowed_chat_ids: vec![],
        trigger_mode: TelegramTriggerMode::MentionOrDm,
        active: true,
        webhook_secret: None,
        instructions: None,
        auto_create_missions: true,
        default_backend: Some("claudecode".to_string()),
        default_model_override: None,
        default_model_effort: None,
        default_workspace_id: None,
        default_config_profile: None,
        default_agent: None,
        created_at: "2026-04-08T10:00:00Z".to_string(),
        updated_at: "2026-04-08T10:00:00Z".to_string(),
    };
    store
        .create_telegram_channel(channel.clone())
        .await
        .expect("telegram channel");
    channel.id
}

#[tokio::test]
async fn paloma_decisions_keep_only_the_latest() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteMissionStore::new(dir.path().to_path_buf(), "prune")
        .await
        .unwrap();
    let total = super::PALOMA_DECISIONS_KEPT + 2 * super::PALOMA_DECISION_PRUNE_EVERY;
    {
        let conn = store.conn.lock().await;
        conn.execute_batch("BEGIN").unwrap();
        for n in 0..total {
            conn.execute(
                    "INSERT INTO paloma_decisions (id, event_source, channel, reason_code,
                        proposed_action, allowed, policy_snapshot_json, created_at)
                     VALUES (?1, 'scheduler', 'telegram', 'long_running', 'create_alert', 1, '{}', ?2)",
                    params![format!("seed-{n}"), format!("2026-05-20T10:00:00.{n:09}Z")],
                )
                .unwrap();
        }
        conn.execute_batch("COMMIT").unwrap();
    }
    for n in 0..super::PALOMA_DECISION_PRUNE_EVERY {
        store
            .create_paloma_decision(PalomaDecision {
                id: Uuid::new_v4(),
                event_source: "scheduler".to_string(),
                mission_id: None,
                user_id: None,
                channel: "telegram".to_string(),
                reason_code: "long_running".to_string(),
                proposed_action: "create_alert".to_string(),
                allowed: true,
                suppression_reason: None,
                policy_snapshot_json: "{}".to_string(),
                generated_text_hash: None,
                generated_text_preview: None,
                created_at: format!("2026-06-01T10:00:00.{n:09}Z"),
            })
            .await
            .unwrap();
    }
    let kept: i64 = store
        .conn
        .lock()
        .await
        .query_row("SELECT COUNT(*) FROM paloma_decisions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert!(
        kept <= super::PALOMA_DECISIONS_KEPT + super::PALOMA_DECISION_PRUNE_EVERY,
        "kept {kept}"
    );
    assert!(kept >= super::PALOMA_DECISIONS_KEPT, "kept {kept}");
    let latest = store.list_paloma_decisions(1).await.unwrap();
    assert!(latest[0].created_at.starts_with("2026-06-01"));
}

#[tokio::test]
async fn telegram_paloma_user_cursor_and_subscription_round_trip() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Paloma state"), None, None, None, None, None, None)
        .await
        .expect("mission");

    let user = store
        .upsert_telegram_user(TelegramUser {
            id: Uuid::new_v4(),
            telegram_user_id: 1_139_694_048,
            username: Some("thomas".to_string()),
            display_name: Some("Thomas".to_string()),
            role: TelegramUserRole::Owner,
            created_at: "2026-05-20T10:00:00Z".to_string(),
            updated_at: "2026-05-20T10:00:00Z".to_string(),
        })
        .await
        .expect("upsert user");
    assert_eq!(user.role, TelegramUserRole::Owner);

    let loaded = store
        .get_telegram_user(1_139_694_048)
        .await
        .expect("get user")
        .expect("user exists");
    assert_eq!(loaded.username.as_deref(), Some("thomas"));

    let cursor = store
        .get_or_create_telegram_user_cursor(1_139_694_048)
        .await
        .expect("cursor");
    assert!(cursor.last_status_at.is_none());
    store
        .update_telegram_user_last_status_at(
            1_139_694_048,
            "2026-05-20T10:10:00Z",
            "{\"mission\":7}",
        )
        .await
        .expect("update cursor");
    let cursor = store
        .get_or_create_telegram_user_cursor(1_139_694_048)
        .await
        .expect("cursor reload");
    assert_eq!(
        cursor.last_status_at.as_deref(),
        Some("2026-05-20T10:10:00Z")
    );
    assert_eq!(
        cursor.last_seen_event_sequence_by_mission_json,
        "{\"mission\":7}"
    );
    store
        .update_telegram_user_last_digest_at(1_139_694_048, "2026-05-20T10:20:00Z")
        .await
        .expect("update digest cursor");
    let cursor = store
        .get_or_create_telegram_user_cursor(1_139_694_048)
        .await
        .expect("cursor after digest update");
    assert_eq!(
        cursor.last_digest_at.as_deref(),
        Some("2026-05-20T10:20:00Z")
    );
    assert_eq!(
        cursor.last_status_at.as_deref(),
        Some("2026-05-20T10:10:00Z")
    );
    assert_eq!(
        cursor.last_seen_event_sequence_by_mission_json,
        "{\"mission\":7}"
    );
    store
        .update_telegram_user_last_alert_ack_at(1_139_694_048, "2026-05-20T10:30:00Z")
        .await
        .expect("update alert ack cursor");
    let cursor = store
        .get_or_create_telegram_user_cursor(1_139_694_048)
        .await
        .expect("cursor after alert ack update");
    assert_eq!(
        cursor.last_alert_ack_at.as_deref(),
        Some("2026-05-20T10:30:00Z")
    );
    assert_eq!(
        cursor.last_digest_at.as_deref(),
        Some("2026-05-20T10:20:00Z")
    );

    store
        .upsert_telegram_mission_subscription(TelegramMissionSubscription {
            id: Uuid::new_v4(),
            telegram_user_id: 1_139_694_048,
            mission_id: mission.id,
            interest_level: TelegramMissionInterestLevel::High,
            reason: Some("status command".to_string()),
            expires_at: None,
            created_at: "2026-05-20T10:00:00Z".to_string(),
            updated_at: "2026-05-20T10:00:00Z".to_string(),
        })
        .await
        .expect("subscription");
    let subscriptions = store
        .list_telegram_mission_subscriptions(1_139_694_048)
        .await
        .expect("subscriptions");
    assert_eq!(subscriptions.len(), 1);
    assert_eq!(
        subscriptions[0].interest_level,
        TelegramMissionInterestLevel::High
    );

    store
        .create_telegram_alert_preference(TelegramAlertPreference {
            id: Uuid::new_v4(),
            telegram_user_id: 1_139_694_048,
            scope: "mission".to_string(),
            scope_value: Some(mission.id.to_string()),
            rule_text: "mute from Telegram feedback".to_string(),
            enabled: true,
            created_from_message_id: Some(12),
            created_at: "2026-05-20T10:00:00Z".to_string(),
            updated_at: "2026-05-20T10:00:00Z".to_string(),
        })
        .await
        .expect("alert preference");
    let preferences = store
        .list_telegram_alert_preferences(1_139_694_048)
        .await
        .expect("alert preferences");
    assert_eq!(preferences.len(), 1);
    assert_eq!(
        preferences[0].rule_text,
        "mute from Telegram feedback".to_string()
    );

    let alert = TelegramAlert {
        id: Uuid::new_v4(),
        telegram_user_id: 1_139_694_048,
        mission_id: Some(mission.id),
        event_kind: "mission_completed".to_string(),
        importance: "high".to_string(),
        title: "Paloma state".to_string(),
        body: "Paloma state is now completed.".to_string(),
        status: "pending".to_string(),
        telegram_message_id: None,
        last_error: None,
        created_at: "2026-05-20T10:00:00Z".to_string(),
        sent_at: None,
        acknowledged_at: None,
    };
    assert!(store
        .create_telegram_alert_if_absent(alert.clone())
        .await
        .expect("first alert")
        .is_some());
    assert!(store
        .create_telegram_alert_if_absent(alert)
        .await
        .expect("duplicate alert")
        .is_none());
    let pending = store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("pending alerts");
    assert_eq!(pending.len(), 1);
    store
        .mark_telegram_alert_failed(pending[0].id, "temporary Telegram outage")
        .await
        .expect("record failed attempt");
    let retryable = store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("retryable alerts");
    assert_eq!(retryable.len(), 1);
    assert_eq!(
        retryable[0].last_error.as_deref(),
        Some("temporary Telegram outage")
    );
    assert_eq!(
        store
            .recover_stale_telegram_alerts("2026-05-20T10:00:30Z", 10)
            .await
            .expect("recover stale alert"),
        1
    );
    let recovered = store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("recovered alerts");
    assert_eq!(recovered.len(), 1);
    assert!(recovered[0].last_error.is_none());
    store
        .mark_telegram_alert_sent(recovered[0].id, Some(99), "2026-05-20T10:01:00Z")
        .await
        .expect("mark sent");
    let sent_alert = store
        .get_telegram_alert_by_message_id(1_139_694_048, 99)
        .await
        .expect("sent alert by message id")
        .expect("sent alert exists");
    assert_eq!(sent_alert.mission_id, Some(mission.id));
    let second_digest_alert_id = Uuid::new_v4();
    store
        .create_telegram_alert_if_absent(TelegramAlert {
            id: second_digest_alert_id,
            telegram_user_id: 1_139_694_048,
            mission_id: Some(mission.id),
            event_kind: "mission_failed".to_string(),
            importance: "high".to_string(),
            title: "Paloma state".to_string(),
            body: "Paloma state failed.".to_string(),
            status: "pending".to_string(),
            telegram_message_id: None,
            last_error: None,
            created_at: "2026-05-20T10:01:30Z".to_string(),
            sent_at: None,
            acknowledged_at: None,
        })
        .await
        .expect("second digest alert");
    store
        .mark_telegram_alert_sent(second_digest_alert_id, Some(99), "2026-05-20T10:01:40Z")
        .await
        .expect("mark second digest alert sent");
    let same_mission_digest_alert = store
        .get_telegram_alert_by_message_id(1_139_694_048, 99)
        .await
        .expect("same-mission digest alert lookup")
        .expect("same-mission digest alert exists");
    assert_eq!(same_mission_digest_alert.mission_id, Some(mission.id));
    let other_mission = store
        .create_mission(
            Some("Other Paloma state"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("other mission");
    let cross_mission_digest_alert_id = Uuid::new_v4();
    store
        .create_telegram_alert_if_absent(TelegramAlert {
            id: cross_mission_digest_alert_id,
            telegram_user_id: 1_139_694_048,
            mission_id: Some(other_mission.id),
            event_kind: "mission_failed".to_string(),
            importance: "high".to_string(),
            title: "Other Paloma state".to_string(),
            body: "Other Paloma state failed.".to_string(),
            status: "pending".to_string(),
            telegram_message_id: None,
            last_error: None,
            created_at: "2026-05-20T10:01:50Z".to_string(),
            sent_at: None,
            acknowledged_at: None,
        })
        .await
        .expect("cross-mission digest alert");
    store
        .mark_telegram_alert_sent(
            cross_mission_digest_alert_id,
            Some(99),
            "2026-05-20T10:02:00Z",
        )
        .await
        .expect("mark cross-mission digest alert sent");
    assert_eq!(
        store
            .get_telegram_alert_by_message_id(1_139_694_048, 99)
            .await
            .expect_err("cross-mission digest alert lookup"),
        "ambiguous_digest_reply"
    );
    assert!(store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("pending alerts after sent")
        .is_empty());

    let queued_after_mute_id = Uuid::new_v4();
    let queued_after_mute = TelegramAlert {
        id: queued_after_mute_id,
        telegram_user_id: 1_139_694_048,
        mission_id: Some(mission.id),
        event_kind: "mission_awaiting_user".to_string(),
        importance: "high".to_string(),
        title: "Paloma state".to_string(),
        body: "Paloma state needs input.".to_string(),
        status: "pending".to_string(),
        telegram_message_id: None,
        last_error: Some("previous retry".to_string()),
        created_at: "2026-05-20T10:02:00Z".to_string(),
        sent_at: None,
        acknowledged_at: None,
    };
    store
        .create_telegram_alert_if_absent(queued_after_mute)
        .await
        .expect("queued alert after mute");
    assert_eq!(
        store
            .acknowledge_pending_telegram_alerts_for_mission(
                1_139_694_048,
                mission.id,
                "2026-05-20T10:03:00Z",
            )
            .await
            .expect("acknowledge pending alerts"),
        1
    );
    assert!(store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("pending alerts after ack")
        .is_empty());
    store
        .mark_telegram_alert_failed(queued_after_mute_id, "late Telegram failure")
        .await
        .expect("late failure should not requeue acknowledged alert");
    assert!(store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("pending alerts after late failure")
        .is_empty());

    let failure_alert_id = Uuid::new_v4();
    let routine_alert_id = Uuid::new_v4();
    let scoped_ack_mission_id = Uuid::new_v4();
    for (id, event_kind, created_at) in [
        (failure_alert_id, "mission_failed", "2026-05-20T10:04:00Z"),
        (
            routine_alert_id,
            "mission_not_feasible",
            "2026-05-20T10:04:01Z",
        ),
    ] {
        store
            .create_telegram_alert_if_absent(TelegramAlert {
                id,
                telegram_user_id: 1_139_694_048,
                mission_id: Some(scoped_ack_mission_id),
                event_kind: event_kind.to_string(),
                importance: "high".to_string(),
                title: "Paloma state".to_string(),
                body: format!("Paloma state: {event_kind}."),
                status: "pending".to_string(),
                telegram_message_id: None,
                last_error: None,
                created_at: created_at.to_string(),
                sent_at: None,
                acknowledged_at: None,
            })
            .await
            .expect("create scoped ack alert");
    }
    assert!(
        store
            .acknowledge_pending_telegram_alert(
                1_139_694_048,
                routine_alert_id,
                "2026-05-20T10:05:00Z",
            )
            .await
            .expect("acknowledge one pending alert")
    );
    let pending_after_single_ack = store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("pending alerts after single ack");
    assert_eq!(pending_after_single_ack.len(), 1);
    assert_eq!(pending_after_single_ack[0].id, failure_alert_id);

    let decision = PalomaDecision {
        id: Uuid::new_v4(),
        event_source: "scheduler".to_string(),
        mission_id: Some(mission.id),
        user_id: Some(1_139_694_048),
        channel: "telegram".to_string(),
        reason_code: "long_running".to_string(),
        proposed_action: "create_alert".to_string(),
        allowed: true,
        suppression_reason: None,
        policy_snapshot_json: serde_json::json!({
            "long_running_minutes": 30,
            "quiet_after_user_message_minutes": 30,
        })
        .to_string(),
        generated_text_hash: Some("abc123".to_string()),
        generated_text_preview: Some("Paloma state is still running.".to_string()),
        created_at: "2026-05-20T10:04:00Z".to_string(),
    };
    store
        .create_paloma_decision(decision.clone())
        .await
        .expect("paloma decision");
    let decisions = store
        .list_paloma_decisions(10)
        .await
        .expect("paloma decisions");
    assert_eq!(decisions.len(), 1);
    assert_eq!(decisions[0], decision);

    assert!(store
        .claim_paloma_scheduler_job(
            "paloma_alert_scan",
            "worker-a",
            "2026-05-20T10:05:00Z",
            "2026-05-20T10:06:00Z",
        )
        .await
        .expect("claim scheduler job"));
    assert!(!store
        .claim_paloma_scheduler_job(
            "paloma_alert_scan",
            "worker-b",
            "2026-05-20T10:05:30Z",
            "2026-05-20T10:06:30Z",
        )
        .await
        .expect("blocked by active lease"));
    store
        .finish_paloma_scheduler_job(
            "paloma_alert_scan",
            "worker-a",
            "2026-05-20T10:05:40Z",
            None,
        )
        .await
        .expect("finish scheduler job");
    let jobs: Vec<PalomaSchedulerJob> = store
        .list_paloma_scheduler_jobs()
        .await
        .expect("scheduler jobs");
    assert_eq!(jobs.len(), 1);
    assert_eq!(jobs[0].name, "paloma_alert_scan");
    assert_eq!(jobs[0].run_count, 1);
    assert_eq!(
        jobs[0].last_finished_at.as_deref(),
        Some("2026-05-20T10:05:40Z")
    );
}

#[tokio::test]
async fn telegram_conversation_upsert_preserves_row_and_lists_latest_first() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;
    let mission = store
        .create_mission(Some("Origin"), None, None, None, None, None, None)
        .await
        .expect("mission");

    let created = store
        .upsert_telegram_conversation(TelegramConversation {
            id: Uuid::new_v4(),
            channel_id,
            chat_id: 101,
            mission_id: Some(mission.id),
            chat_title: Some("Paloma DM".to_string()),
            chat_type: Some("private".to_string()),
            last_message_at: Some("2026-04-08T10:00:00Z".to_string()),
            created_at: "2026-04-08T10:00:00Z".to_string(),
            updated_at: "2026-04-08T10:00:00Z".to_string(),
        })
        .await
        .expect("create conversation");

    let updated = store
        .upsert_telegram_conversation(TelegramConversation {
            id: Uuid::new_v4(),
            channel_id,
            chat_id: 101,
            mission_id: Some(mission.id),
            chat_title: None,
            chat_type: None,
            last_message_at: Some("2026-04-08T10:05:00Z".to_string()),
            created_at: "2026-04-08T10:05:00Z".to_string(),
            updated_at: "2026-04-08T10:05:00Z".to_string(),
        })
        .await
        .expect("update conversation");

    assert_eq!(updated.id, created.id);
    assert_eq!(updated.chat_title.as_deref(), Some("Paloma DM"));
    assert_eq!(updated.chat_type.as_deref(), Some("private"));
    assert_eq!(
        updated.last_message_at.as_deref(),
        Some("2026-04-08T10:05:00Z")
    );

    let listed = store
        .list_telegram_conversations(channel_id, 10)
        .await
        .expect("list conversations");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, created.id);
}

#[tokio::test]
async fn telegram_conversation_messages_round_trip_and_bump_last_message_at() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;
    let mission = store
        .create_mission(Some("Origin"), None, None, None, None, None, None)
        .await
        .expect("mission");
    let conversation = store
        .upsert_telegram_conversation(TelegramConversation {
            id: Uuid::new_v4(),
            channel_id,
            chat_id: 202,
            mission_id: Some(mission.id),
            chat_title: Some("Thread".to_string()),
            chat_type: Some("private".to_string()),
            last_message_at: Some("2026-04-08T10:00:00Z".to_string()),
            created_at: "2026-04-08T10:00:00Z".to_string(),
            updated_at: "2026-04-08T10:00:00Z".to_string(),
        })
        .await
        .expect("conversation");

    store
        .create_telegram_conversation_message(TelegramConversationMessage {
            id: Uuid::new_v4(),
            conversation_id: conversation.id,
            channel_id,
            chat_id: 202,
            mission_id: Some(mission.id),
            workflow_id: None,
            telegram_message_id: Some(11),
            direction: TelegramConversationMessageDirection::Inbound,
            role: "user".to_string(),
            sender_user_id: Some(1),
            sender_username: Some("marilyn".to_string()),
            sender_display_name: Some("Marilyn".to_string()),
            reply_to_message_id: None,
            text: "First".to_string(),
            created_at: "2026-04-08T10:01:00Z".to_string(),
        })
        .await
        .expect("inbound message");

    store
        .create_telegram_conversation_message(TelegramConversationMessage {
            id: Uuid::new_v4(),
            conversation_id: conversation.id,
            channel_id,
            chat_id: 202,
            mission_id: Some(mission.id),
            workflow_id: None,
            telegram_message_id: Some(12),
            direction: TelegramConversationMessageDirection::Outbound,
            role: "assistant".to_string(),
            sender_user_id: None,
            sender_username: Some("ana_lfgbot_test".to_string()),
            sender_display_name: Some("@ana_lfgbot_test".to_string()),
            reply_to_message_id: Some(11),
            text: "Reply".to_string(),
            created_at: "2026-04-08T10:02:00Z".to_string(),
        })
        .await
        .expect("outbound message");

    let messages = store
        .list_telegram_conversation_messages(conversation.id, 10)
        .await
        .expect("list messages");
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0].text, "Reply");
    assert_eq!(
        messages[0].direction,
        TelegramConversationMessageDirection::Outbound
    );
    assert_eq!(messages[1].text, "First");

    let refreshed = store
        .get_telegram_conversation_by_chat(channel_id, 202)
        .await
        .expect("get conversation")
        .expect("conversation exists");
    assert_eq!(
        refreshed.last_message_at.as_deref(),
        Some("2026-04-08T10:02:00Z")
    );
}

#[tokio::test]
async fn telegram_workflow_round_trip_supports_pending_lookup_and_events() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;
    let mission = store
        .create_mission(Some("Origin"), None, None, None, None, None, None)
        .await
        .expect("mission");
    let origin = store
        .upsert_telegram_conversation(TelegramConversation {
            id: Uuid::new_v4(),
            channel_id,
            chat_id: 303,
            mission_id: Some(mission.id),
            chat_title: Some("Origin".to_string()),
            chat_type: Some("private".to_string()),
            last_message_at: Some("2026-04-08T10:00:00Z".to_string()),
            created_at: "2026-04-08T10:00:00Z".to_string(),
            updated_at: "2026-04-08T10:00:00Z".to_string(),
        })
        .await
        .expect("origin conversation");
    let target = store
        .upsert_telegram_conversation(TelegramConversation {
            id: Uuid::new_v4(),
            channel_id,
            chat_id: 404,
            mission_id: None,
            chat_title: Some("Marilyn".to_string()),
            chat_type: Some("private".to_string()),
            last_message_at: Some("2026-04-08T10:00:00Z".to_string()),
            created_at: "2026-04-08T10:00:00Z".to_string(),
            updated_at: "2026-04-08T10:00:00Z".to_string(),
        })
        .await
        .expect("target conversation");

    let workflow = store
        .create_telegram_workflow(TelegramWorkflow {
            id: Uuid::new_v4(),
            channel_id,
            origin_conversation_id: origin.id,
            origin_chat_id: 303,
            origin_mission_id: Some(mission.id),
            target_conversation_id: Some(target.id),
            target_chat_id: Some(404),
            target_chat_title: Some("Marilyn".to_string()),
            target_chat_type: Some("private".to_string()),
            target_request_message_id: Some(9001),
            initiated_by_user_id: Some(7),
            initiated_by_username: Some("th0rgal".to_string()),
            kind: TelegramWorkflowKind::RequestReply,
            status: TelegramWorkflowStatus::WaitingExternal,
            request_text: "Ask Marilyn for leads".to_string(),
            latest_reply_text: None,
            summary: None,
            last_error: None,
            created_at: "2026-04-08T10:00:00Z".to_string(),
            updated_at: "2026-04-08T10:00:00Z".to_string(),
            completed_at: None,
        })
        .await
        .expect("create workflow");

    let pending = store
        .get_pending_telegram_workflow_for_target_chat(channel_id, 404)
        .await
        .expect("pending workflow")
        .expect("workflow exists");
    assert_eq!(pending.id, workflow.id);
    assert_eq!(pending.target_request_message_id, Some(9001));

    let pending_by_request = store
        .get_pending_telegram_workflow_for_target_message(channel_id, 404, 9001)
        .await
        .expect("pending workflow by request")
        .expect("workflow exists by request");
    assert_eq!(pending_by_request.id, workflow.id);

    store
        .create_telegram_workflow_event(TelegramWorkflowEvent {
            id: Uuid::new_v4(),
            workflow_id: workflow.id,
            conversation_id: Some(target.id),
            event_type: "external_reply_received".to_string(),
            payload_json: "{\"text\":\"Lead A\"}".to_string(),
            created_at: "2026-04-08T10:03:00Z".to_string(),
        })
        .await
        .expect("create workflow event");

    let mut completed = workflow.clone();
    completed.status = TelegramWorkflowStatus::RelayedToOrigin;
    completed.latest_reply_text = Some("Lead A".to_string());
    completed.summary = Some("Lead A relayed".to_string());
    completed.updated_at = "2026-04-08T10:04:00Z".to_string();
    completed.completed_at = Some("2026-04-08T10:04:00Z".to_string());
    store
        .update_telegram_workflow(completed.clone())
        .await
        .expect("update workflow");

    let pending_after = store
        .get_pending_telegram_workflow_for_target_chat(channel_id, 404)
        .await
        .expect("pending lookup after completion");
    assert!(pending_after.is_none());

    let listed = store
        .list_telegram_workflows(channel_id, 10)
        .await
        .expect("list workflows");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].status, TelegramWorkflowStatus::RelayedToOrigin);
    assert_eq!(listed[0].summary.as_deref(), Some("Lead A relayed"));

    let events = store
        .list_telegram_workflow_events(workflow.id, 10)
        .await
        .expect("list workflow events");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type, "external_reply_received");
}

#[test]
fn assistant_message_metadata_uses_normalized_cost_shape() {
    let completion_evidence = Some(CompletionEvidence {
        terminal_reason: Some(TerminalReason::Completed),
        completion_signal: CompletionSignal::NativeTerminal,
        completion_confidence: CompletionConfidence::High,
        native_terminal_seen: true,
        pending_tools: None,
        transport_failure_stage: None,
        provider_error_source: None,
        failure_class: None,
        classification_source: "structured".to_string(),
    });
    let metadata = assistant_message_metadata(AssistantMessageMetadataInput {
        success: true,
        cost_cents: 42,
        cost_source: CostSource::Estimated,
        usage: &Some(TokenUsage {
            input_tokens: 10,
            output_tokens: 2,
            cache_creation_input_tokens: None,
            cache_read_input_tokens: None,
        }),
        model: &Some("gpt-4o".to_string()),
        model_normalized: &Some("gpt-4o".to_string()),
        shared_files: &None,
        resumable: false,
        completion_evidence: &completion_evidence,
    });

    assert_eq!(
        metadata,
        json!({
            "success": true,
            "cost_cents": 42,
            "cost": {
                "amount_cents": 42,
                "currency": "USD",
                "source": "estimated",
            },
            "usage": {
                "input_tokens": 10,
                "output_tokens": 2,
                "cache_creation_input_tokens": null,
                "cache_read_input_tokens": null,
            },
            "model": "gpt-4o",
            "model_normalized": "gpt-4o",
            "completion_evidence": {
                "terminal_reason": "Completed",
                "completion_signal": "native_terminal",
                "completion_confidence": "high",
                "native_terminal_seen": true,
                "pending_tools": null,
                "transport_failure_stage": null,
                "provider_error_source": null,
                "failure_class": null,
                "classification_source": "structured",
            },
        })
    );
}

#[test]
fn assistant_message_metadata_skips_optional_none_fields() {
    let metadata = assistant_message_metadata(AssistantMessageMetadataInput {
        success: false,
        cost_cents: 0,
        cost_source: CostSource::Unknown,
        usage: &None,
        model: &None,
        model_normalized: &None,
        shared_files: &None,
        resumable: false,
        completion_evidence: &None,
    });

    assert_eq!(
        metadata,
        json!({
            "success": false,
            "cost_cents": 0,
            "cost": {
                "amount_cents": 0,
                "currency": "USD",
                "source": "unknown",
            },
        })
    );
}

#[tokio::test]
async fn update_mission_metadata_is_noop_when_fields_missing() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Initial"), None, None, None, None, None, None)
        .await
        .expect("mission");

    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Renamed")),
            Some(Some("Short summary")),
            Some(Some("backend_heuristic")),
            None,
            Some(Some("v1")),
        )
        .await
        .expect("set metadata");

    let after_set = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let metadata_updated_at = after_set
        .metadata_updated_at
        .clone()
        .expect("metadata timestamp should be set");
    let updated_at = after_set.updated_at.clone();

    store
        .update_mission_metadata(mission.id, None, None, None, None, None)
        .await
        .expect("noop metadata update");

    let after_noop = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");

    assert_eq!(after_noop.title.as_deref(), Some("Renamed"));
    assert_eq!(
        after_noop.short_description.as_deref(),
        Some("Short summary")
    );
    assert_eq!(
        after_noop.metadata_source.as_deref(),
        Some("backend_heuristic")
    );
    assert_eq!(after_noop.metadata_model.as_deref(), None);
    assert_eq!(after_noop.metadata_version.as_deref(), Some("v1"));
    assert_eq!(
        after_noop.metadata_updated_at.as_deref(),
        Some(metadata_updated_at.as_str())
    );
    assert_eq!(after_noop.updated_at, updated_at);
}

#[tokio::test]
async fn update_mission_metadata_can_clear_fields() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Initial"), None, None, None, None, None, None)
        .await
        .expect("mission");

    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Renamed")),
            Some(Some("Short summary")),
            Some(Some("backend_heuristic")),
            None,
            Some(Some("v1")),
        )
        .await
        .expect("set metadata");

    store
        .update_mission_metadata(
            mission.id,
            Some(None),
            Some(None),
            Some(None),
            None,
            Some(None),
        )
        .await
        .expect("clear metadata fields");

    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(mission.title, None);
    assert_eq!(mission.short_description, None);
    assert_eq!(mission.metadata_source, None);
    assert_eq!(mission.metadata_version, None);
}

/// Regression for the #572 incident: a global store and the per-user store
/// open the same DB file and run migrations concurrently at startup. The
/// `github_pr` INTEGER→TEXT conversion's DROP must NOT fail the store init
/// when a racing init already dropped/re-added the column — otherwise the
/// service silently falls back to an in-memory store and loses visibility of
/// every persisted mission.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_init_on_integer_github_pr_does_not_fall_back() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let base = temp_dir.path().to_path_buf();

    // Seed a DB, then force it into the pre-#572 shape: github_pr is INTEGER
    // and the newer columns are absent.
    {
        let store = SqliteMissionStore::new(base.clone(), "race")
            .await
            .expect("seed store");
        drop(store);
        let db = base.join("missions-race.db");
        let conn = rusqlite::Connection::open(&db).expect("open seed");
        conn.execute("ALTER TABLE missions DROP COLUMN github_pr", [])
            .expect("drop text github_pr");
        conn.execute("ALTER TABLE missions ADD COLUMN github_pr INTEGER", [])
            .expect("re-add integer github_pr");
        for column in [
            "desired_state",
            "next_check_at",
            "requires_local_disk",
            "fast_mode",
            "service_tier",
        ] {
            conn.execute(&format!("ALTER TABLE missions DROP COLUMN {column}"), [])
                .ok();
        }
        for column in [
            "repository",
            "branch",
            "prior_worker_mission_id",
            "prior_outcome",
            "prior_result_digest",
        ] {
            conn.execute(&format!("ALTER TABLE board_tasks DROP COLUMN {column}"), [])
                .expect("drop board task column for migration race");
        }
    }

    // Two concurrent initializations on the SAME db file — both must succeed.
    let h1 = {
        let p = base.clone();
        tokio::spawn(async move { SqliteMissionStore::new(p, "race").await.map(|_| ()) })
    };
    let h2 = {
        let p = base.clone();
        tokio::spawn(async move { SqliteMissionStore::new(p, "race").await.map(|_| ()) })
    };
    let (r1, r2) = tokio::join!(h1, h2);
    assert!(
        r1.expect("join1").is_ok(),
        "concurrent init 1 must not fail (would fall back to in-memory)"
    );
    assert!(
        r2.expect("join2").is_ok(),
        "concurrent init 2 must not fail (would fall back to in-memory)"
    );

    // github_pr is TEXT and the new columns exist after the race.
    let db = base.join("missions-race.db");
    let conn = rusqlite::Connection::open(&db).expect("open verify");
    let ty: String = conn
        .query_row(
            "SELECT type FROM pragma_table_info('missions') WHERE name = 'github_pr'",
            [],
            |r| r.get(0),
        )
        .expect("github_pr column present");
    assert_eq!(ty.to_uppercase(), "TEXT");
    for col in [
        "desired_state",
        "next_check_at",
        "requires_local_disk",
        "fast_mode",
        "service_tier",
    ] {
        let exists: bool = conn
            .prepare("SELECT 1 FROM pragma_table_info('missions') WHERE name = ?1")
            .unwrap()
            .exists([col])
            .unwrap();
        assert!(
            exists,
            "{} column must exist after concurrent migration",
            col
        );
    }
    for col in [
        "repository",
        "branch",
        "prior_worker_mission_id",
        "prior_outcome",
        "prior_result_digest",
    ] {
        let exists: bool = conn
            .prepare("SELECT 1 FROM pragma_table_info('board_tasks') WHERE name = ?1")
            .unwrap()
            .exists([col])
            .unwrap();
        assert!(
            exists,
            "{col} board_tasks column must survive concurrent migration"
        );
    }
}

#[tokio::test]
async fn active_mission_scan_preserves_client_placement_for_recovery() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteMissionStore::new(dir.path().to_path_buf(), "test-user")
        .await
        .unwrap();
    let mission = store
        .create_mission(Some("Native goal"), None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                tags: Some(vec!["placement:client".into()]),
                project: Some(Some("verity".into())),
                track: Some(Some("import".into())),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();
    let active = store.get_all_active_missions().await.unwrap();
    let found = active.iter().find(|m| m.id == mission.id).unwrap();
    assert!(crate::api::control::client_placement::is_tagged(
        &found.project.tags
    ));
    assert_eq!(found.project.project.as_deref(), Some("verity"));
    assert_eq!(found.project.track.as_deref(), Some("import"));
}

#[tokio::test]
async fn project_metadata_and_awaiting_kind_roundtrip() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Tagged"), None, None, None, None, None, None)
        .await
        .expect("mission");

    // Fresh mission has no project metadata or awaiting_kind.
    assert!(mission.project.is_empty());
    assert_eq!(mission.awaiting_kind, None);

    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                preserve_updated_at: false,
                tag_patch: None,
                title: None,
                project: Some(Some("verity-core".to_string())),
                track: Some(Some("C3-bridge-collapse".to_string())),
                intent: Some(Some("review_merge_pr".to_string())),
                github_pr: Some(Some("lfglabs-dev/verity#2070".to_string())),
                tags: Some(vec!["c3".to_string(), "blocking".to_string()]),
                desired_state: Some(Some("waiting_ci".to_string())),
                next_check_at: Some(Some("2026-07-01T00:00:00Z".to_string())),
            },
        )
        .await
        .expect("set project");

    let fetched = store
        .get_mission(mission.id)
        .await
        .expect("get")
        .expect("exists");
    assert_eq!(fetched.project.project.as_deref(), Some("verity-core"));
    assert_eq!(fetched.project.track.as_deref(), Some("C3-bridge-collapse"));
    assert_eq!(fetched.project.intent.as_deref(), Some("review_merge_pr"));
    assert_eq!(
        fetched.project.github_pr.as_deref(),
        Some("lfglabs-dev/verity#2070")
    );
    assert_eq!(fetched.project.tags, vec!["c3", "blocking"]);
    assert_eq!(fetched.project.desired_state.as_deref(), Some("waiting_ci"));
    assert_eq!(
        fetched.project.next_check_at.as_deref(),
        Some("2026-07-01T00:00:00Z")
    );

    // Partial update leaves untouched fields intact and can clear one.
    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                project: Some(None),
                ..Default::default()
            },
        )
        .await
        .expect("clear project");
    let fetched = store
        .get_mission(mission.id)
        .await
        .expect("get")
        .expect("exists");
    assert_eq!(fetched.project.project, None);
    assert_eq!(fetched.project.track.as_deref(), Some("C3-bridge-collapse"));
    assert_eq!(
        fetched.project.github_pr.as_deref(),
        Some("lfglabs-dev/verity#2070")
    );
    assert_eq!(fetched.project.desired_state.as_deref(), Some("waiting_ci"));
    assert_eq!(fetched.project.tags, vec!["c3", "blocking"]);

    // awaiting_kind persists, and is cleared on a status change away from
    // AwaitingUser.
    store
        .set_mission_awaiting_kind(mission.id, Some(AwaitingKind::Decision))
        .await
        .expect("set kind");
    store
        .update_mission_status(mission.id, MissionStatus::AwaitingUser)
        .await
        .expect("awaiting status");
    let fetched = store
        .get_mission(mission.id)
        .await
        .expect("get")
        .expect("exists");
    assert_eq!(fetched.awaiting_kind, Some(AwaitingKind::Decision));

    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("active status");
    let fetched = store
        .get_mission(mission.id)
        .await
        .expect("get")
        .expect("exists");
    assert_eq!(
        fetched.awaiting_kind, None,
        "awaiting_kind must clear when leaving AwaitingUser"
    );
}

#[tokio::test]
async fn mission_origin_roundtrip_and_tag_backfill() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Spawned"), None, None, None, None, None, None)
        .await
        .expect("mission");
    assert_eq!(mission.origin, None);
    assert_eq!(mission.origin_session_id, None);

    store
        .set_mission_origin(mission.id, "hermes", Some("20260804_101500_ab12cd34"))
        .await
        .expect("set origin");
    let fetched = store
        .get_mission(mission.id)
        .await
        .expect("get")
        .expect("exists");
    assert_eq!(fetched.origin.as_deref(), Some("hermes"));
    assert_eq!(
        fetched.origin_session_id.as_deref(),
        Some("20260804_101500_ab12cd34")
    );
    let listed = store.list_missions(10, 0).await.expect("list");
    let listed = listed.iter().find(|m| m.id == mission.id).expect("listed");
    assert_eq!(listed.origin.as_deref(), Some("hermes"));

    // Legacy hermes missions (tag only, no origin column) get backfilled by
    // the migration pass.
    let legacy = store
        .create_mission(Some("Legacy"), None, None, None, None, None, None)
        .await
        .expect("legacy mission");
    store
        .update_mission_project(
            legacy.id,
            MissionProjectPatch {
                tags: Some(vec!["origin:hermes-assistant".to_string()]),
                ..Default::default()
            },
        )
        .await
        .expect("tag legacy");
    {
        let conn = store.conn.lock().await;
        SqliteMissionStore::run_migrations(&conn).expect("re-run migration");
    }
    let fetched = store
        .get_mission(legacy.id)
        .await
        .expect("get")
        .expect("exists");
    assert_eq!(
        fetched.origin.as_deref(),
        Some("hermes"),
        "tag-only hermes mission must be backfilled to origin='hermes'"
    );
}

#[tokio::test]
async fn update_mission_title_marks_user_metadata_source() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Initial"), None, None, None, None, None, None)
        .await
        .expect("mission");

    store
        .update_mission_metadata(
            mission.id,
            None,
            None,
            Some(Some("backend_heuristic")),
            Some(Some("gpt-5")),
            Some(Some("v1")),
        )
        .await
        .expect("seed metadata source");
    let seeded = store
        .get_mission(mission.id)
        .await
        .expect("get seeded mission")
        .expect("mission exists");
    let seeded_metadata_updated_at = seeded
        .metadata_updated_at
        .expect("seed metadata timestamp should exist");

    store
        .update_mission_title(mission.id, "Manual title")
        .await
        .expect("rename mission");

    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(mission.title.as_deref(), Some("Manual title"));
    assert_eq!(mission.metadata_source.as_deref(), Some("user"));
    assert_eq!(mission.metadata_model, None);
    assert_eq!(mission.metadata_version, None);
    let metadata_updated_at = mission
        .metadata_updated_at
        .expect("manual title update should set metadata timestamp");
    assert!(
        metadata_updated_at >= seeded_metadata_updated_at,
        "manual title update should advance metadata timestamp"
    );
}

#[tokio::test]
async fn create_mission_marks_user_metadata_source_when_title_is_provided() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");

    let titled = store
        .create_mission(
            Some("User titled mission"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create titled mission");
    assert_eq!(titled.metadata_source.as_deref(), Some("user"));
    assert!(
        titled.metadata_updated_at.is_some(),
        "titled mission should set metadata_updated_at"
    );

    let untitled = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create untitled mission");
    assert_eq!(untitled.metadata_source, None);
    assert_eq!(untitled.metadata_updated_at, None);

    let blank_titled = store
        .create_mission(Some("  "), None, None, None, None, None, None)
        .await
        .expect("create blank titled mission");
    assert_eq!(blank_titled.metadata_source, None);
    assert_eq!(blank_titled.metadata_updated_at, None);
}

#[tokio::test]
async fn get_total_cost_cents_prefers_normalized_shape_with_legacy_fallback() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Cost mission"), None, None, None, None, None, None)
        .await
        .expect("mission");

    let conn = store.conn.lock().await;
    let query = r#"
            INSERT INTO mission_events (
                mission_id, sequence, event_type, timestamp, metadata
            ) VALUES (?1, ?2, 'assistant_message', ?3, ?4)
        "#;

    conn.execute(
        query,
        params![
            mission.id.to_string(),
            1i64,
            "2026-02-21T00:00:00Z",
            json!({
                "cost": { "amount_cents": 150 },
                "cost_cents": 99
            })
            .to_string()
        ],
    )
    .expect("insert normalized + legacy");
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            2i64,
            "2026-02-21T00:00:01Z",
            json!({ "cost_cents": 25 }).to_string()
        ],
    )
    .expect("insert legacy");
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            3i64,
            "2026-02-21T00:00:02Z",
            json!({ "cost": { "amount_cents": 5 } }).to_string()
        ],
    )
    .expect("insert normalized");
    drop(conn);

    let total = store
        .get_total_cost_cents()
        .await
        .expect("total cost should calculate");
    assert_eq!(total, 180);
}

#[tokio::test]
async fn get_total_cost_cents_clamps_negative_values_to_zero() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Cost mission"), None, None, None, None, None, None)
        .await
        .expect("mission");

    let conn = store.conn.lock().await;
    let query = r#"
            INSERT INTO mission_events (
                mission_id, sequence, event_type, timestamp, metadata
            ) VALUES (?1, ?2, 'assistant_message', ?3, ?4)
        "#;

    conn.execute(
        query,
        params![
            mission.id.to_string(),
            1i64,
            "2026-02-21T00:00:00Z",
            json!({ "cost": { "amount_cents": -50 } }).to_string()
        ],
    )
    .expect("insert malformed negative normalized");
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            2i64,
            "2026-02-21T00:00:01Z",
            json!({ "cost_cents": -10 }).to_string()
        ],
    )
    .expect("insert malformed negative legacy");
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            3i64,
            "2026-02-21T00:00:02Z",
            json!({ "cost": { "amount_cents": 25 } }).to_string()
        ],
    )
    .expect("insert valid normalized");
    drop(conn);

    let total = store
        .get_total_cost_cents()
        .await
        .expect("total cost should calculate");
    assert_eq!(total, 25);
}

#[tokio::test]
async fn get_cost_by_source_groups_by_provenance() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(
            Some("Cost source mission"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission");

    let conn = store.conn.lock().await;
    let query = r#"
            INSERT INTO mission_events (
                mission_id, sequence, event_type, timestamp, metadata
            ) VALUES (?1, ?2, 'assistant_message', ?3, ?4)
        "#;

    // Actual cost
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            1i64,
            "2026-02-22T00:00:00Z",
            json!({
                "cost": { "amount_cents": 100, "source": "actual", "currency": "USD" }
            })
            .to_string()
        ],
    )
    .expect("insert actual");

    // Estimated cost
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            2i64,
            "2026-02-22T00:00:01Z",
            json!({
                "cost": { "amount_cents": 50, "source": "estimated", "currency": "USD" }
            })
            .to_string()
        ],
    )
    .expect("insert estimated");

    // Unknown cost (explicit)
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            3i64,
            "2026-02-22T00:00:02Z",
            json!({
                "cost": { "amount_cents": 10, "source": "unknown", "currency": "USD" }
            })
            .to_string()
        ],
    )
    .expect("insert unknown");

    // Legacy cost (no source field → unknown)
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            4i64,
            "2026-02-22T00:00:03Z",
            json!({ "cost_cents": 5 }).to_string()
        ],
    )
    .expect("insert legacy");

    drop(conn);

    let (actual, estimated, unknown) = store
        .get_cost_by_source()
        .await
        .expect("cost by source should calculate");
    assert_eq!(actual, 100);
    assert_eq!(estimated, 50);
    // Unknown (10) + legacy (5) both go into the unknown bucket
    assert_eq!(unknown, 15);
}

#[tokio::test]
async fn get_usage_by_model_aggregates_tokens_and_cost_per_model() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(
            Some("Usage by model mission"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission");

    let conn = store.conn.lock().await;
    let query = r#"
            INSERT INTO mission_events (
                mission_id, sequence, event_type, timestamp, metadata
            ) VALUES (?1, ?2, 'assistant_message', ?3, ?4)
        "#;

    // Two calls to claude-3-5-sonnet with usage + cost
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            1i64,
            "2026-04-22T00:00:00Z",
            json!({
                "model": "claude-3-5-sonnet-20241022",
                "model_normalized": "claude-3-5-sonnet",
                "usage": {
                    "input_tokens": 1000,
                    "output_tokens": 500,
                    "cache_creation_input_tokens": 200,
                    "cache_read_input_tokens": 300
                },
                "cost": { "amount_cents": 12, "source": "actual" }
            })
            .to_string()
        ],
    )
    .expect("insert sonnet 1");
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            2i64,
            "2026-04-22T00:01:00Z",
            json!({
                "model": "claude-3-5-sonnet-20241022",
                "model_normalized": "claude-3-5-sonnet",
                "usage": {
                    "input_tokens": 2000,
                    "output_tokens": 800,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 100
                },
                "cost": { "amount_cents": 25, "source": "actual" }
            })
            .to_string()
        ],
    )
    .expect("insert sonnet 2");

    // One call to gpt-4o with usage + cost
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            3i64,
            "2026-04-22T00:02:00Z",
            json!({
                "model": "gpt-4o-2024-08-06",
                "model_normalized": "gpt-4o",
                "usage": {
                    "input_tokens": 500,
                    "output_tokens": 200
                },
                "cost": { "amount_cents": 4, "source": "actual" }
            })
            .to_string()
        ],
    )
    .expect("insert gpt-4o");

    // Legacy rows may carry a stale normalized model. Prefer the raw model
    // and recalculate estimated costs with current pricing.
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            4i64,
            "2026-04-22T00:03:00Z",
            json!({
                "model": "gpt-5.5",
                "model_normalized": "gpt-5",
                "usage": {
                    "input_tokens": 10000,
                    "output_tokens": 2000
                },
                "cost": { "amount_cents": 33, "source": "estimated" }
            })
            .to_string()
        ],
    )
    .expect("insert legacy gpt-5.5");

    drop(conn);

    let rows = store
        .get_usage_by_model(None)
        .await
        .expect("aggregate by model");

    assert_eq!(rows.len(), 3);
    let sonnet = rows
        .iter()
        .find(|row| row.model == "claude-3-5-sonnet")
        .expect("sonnet usage");
    assert_eq!(sonnet.requests, 2);
    assert_eq!(sonnet.input_tokens, 3000);
    assert_eq!(sonnet.output_tokens, 1300);
    assert_eq!(sonnet.cache_creation_tokens, 200);
    assert_eq!(sonnet.cache_read_tokens, 400);
    assert_eq!(sonnet.cost_cents, 37);

    let gpt_4o = rows
        .iter()
        .find(|row| row.model == "gpt-4o")
        .expect("gpt-4o usage");
    assert_eq!(gpt_4o.requests, 1);
    assert_eq!(gpt_4o.cost_cents, 4);

    let gpt_55 = rows
        .iter()
        .find(|row| row.model == "gpt-5.5")
        .expect("gpt-5.5 usage");
    assert_eq!(gpt_55.requests, 1);
    assert_eq!(gpt_55.input_tokens, 10000);
    assert_eq!(gpt_55.output_tokens, 2000);
    assert_eq!(gpt_55.cost_cents, 11);
    assert!(!rows.iter().any(|row| row.model == "gpt-5"));

    // since=… filter should drop the older entries.
    let recent = store
        .get_usage_by_model(Some("2026-04-22T00:01:30Z"))
        .await
        .expect("filtered aggregate");
    assert_eq!(recent.len(), 2);
    assert!(recent.iter().any(|row| row.model == "gpt-4o"));
    assert!(recent.iter().any(|row| row.model == "gpt-5.5"));
}

#[tokio::test]
async fn get_cost_since_filters_by_timestamp() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(
            Some("Period cost mission"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission");

    let conn = store.conn.lock().await;
    let query = r#"
            INSERT INTO mission_events (
                mission_id, sequence, event_type, timestamp, metadata
            ) VALUES (?1, ?2, 'assistant_message', ?3, ?4)
        "#;

    // Old event — outside the "since" window
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            1i64,
            "2026-02-01T00:00:00Z",
            json!({
                "cost": { "amount_cents": 200, "source": "actual" }
            })
            .to_string()
        ],
    )
    .expect("insert old actual");

    // Recent events — inside the "since" window
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            2i64,
            "2026-02-20T00:00:00Z",
            json!({
                "cost": { "amount_cents": 30, "source": "actual" }
            })
            .to_string()
        ],
    )
    .expect("insert recent actual");
    conn.execute(
        query,
        params![
            mission.id.to_string(),
            3i64,
            "2026-02-21T00:00:00Z",
            json!({
                "cost": { "amount_cents": 15, "source": "estimated" }
            })
            .to_string()
        ],
    )
    .expect("insert recent estimated");

    drop(conn);

    // All-time totals
    let all_total = store.get_total_cost_cents().await.expect("all-time total");
    assert_eq!(all_total, 245); // 200 + 30 + 15

    // Period-filtered: since 2026-02-15 should only include the two recent events
    let since = "2026-02-15T00:00:00Z";
    let period_total = store
        .get_total_cost_cents_since(since)
        .await
        .expect("period total");
    assert_eq!(period_total, 45); // 30 + 15

    let (actual, estimated, unknown) = store
        .get_cost_by_source_since(since)
        .await
        .expect("period cost by source");
    assert_eq!(actual, 30);
    assert_eq!(estimated, 15);
    assert_eq!(unknown, 0);
}

#[tokio::test]
async fn queued_user_messages_are_not_persisted_until_processing_starts() {
    use crate::api::control::AgentEvent;
    use uuid::Uuid;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Queue order"), None, None, None, None, None, None)
        .await
        .expect("mission");

    let queued_id = Uuid::new_v4();
    store
        .log_event(
            mission.id,
            &AgentEvent::UserMessage {
                id: queued_id,
                content: "B".to_string(),
                queued: true,
                mission_id: Some(mission.id),
                source: None,
            },
        )
        .await
        .expect("queued event should be ignored");

    let events = store
        .get_events(mission.id, None, None, None)
        .await
        .expect("events");
    assert!(
        events.is_empty(),
        "queued messages should not be stored yet"
    );

    store
        .log_event(
            mission.id,
            &AgentEvent::UserMessage {
                id: Uuid::new_v4(),
                content: "A".to_string(),
                queued: false,
                mission_id: Some(mission.id),
                source: None,
            },
        )
        .await
        .expect("first user");
    store
        .log_event(
            mission.id,
            &AgentEvent::AssistantMessage {
                id: Uuid::new_v4(),
                content: "reply A".to_string(),
                success: true,
                cost_cents: 0,
                cost_source: CostSource::Unknown,
                usage: None,
                model: None,
                model_normalized: None,
                mission_id: Some(mission.id),
                shared_files: None,
                resumable: false,
                completion_evidence: None,
            },
        )
        .await
        .expect("reply A");
    store
        .log_event(
            mission.id,
            &AgentEvent::UserMessage {
                id: queued_id,
                content: "B".to_string(),
                queued: false,
                mission_id: Some(mission.id),
                source: None,
            },
        )
        .await
        .expect("dequeued B");
    store
        .log_event(
            mission.id,
            &AgentEvent::AssistantMessage {
                id: Uuid::new_v4(),
                content: "reply B".to_string(),
                success: true,
                cost_cents: 0,
                cost_source: CostSource::Unknown,
                usage: None,
                model: None,
                model_normalized: None,
                mission_id: Some(mission.id),
                shared_files: None,
                resumable: false,
                completion_evidence: None,
            },
        )
        .await
        .expect("reply B");

    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let history: Vec<(String, String)> = mission
        .history
        .into_iter()
        .map(|entry| (entry.role, entry.content))
        .collect();
    assert_eq!(
        history,
        vec![
            ("user".to_string(), "A".to_string()),
            ("assistant".to_string(), "reply A".to_string()),
            ("user".to_string(), "B".to_string()),
            ("assistant".to_string(), "reply B".to_string()),
        ]
    );
}

#[tokio::test]
async fn user_message_source_is_persisted_in_metadata() {
    use crate::api::control::AgentEvent;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(
            Some("source attribution"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission");

    store
        .log_event(
            mission.id,
            &AgentEvent::UserMessage {
                id: Uuid::new_v4(),
                content: "hello".to_string(),
                queued: false,
                mission_id: Some(mission.id),
                source: Some("api:user-123".to_string()),
            },
        )
        .await
        .expect("user message with source");

    let events = store
        .get_events(mission.id, None, None, None)
        .await
        .expect("events");
    let user_event = events
        .iter()
        .find(|e| e.event_type == "user_message")
        .expect("user_message row");
    // The persisted metadata JSON is the forensic record of who/what posted
    // this message — it must carry the attribution source.
    assert_eq!(
        user_event.metadata.get("source").and_then(|v| v.as_str()),
        Some("api:user-123"),
        "persisted metadata should contain the attribution source, got {}",
        user_event.metadata
    );
}

#[tokio::test]
async fn antigravity_snapshots_remain_durable_and_finalized_steps_cannot_reopen() {
    use crate::api::control::events::TextOp;
    let temp_dir = tempfile::tempdir().unwrap();
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .unwrap();
    let mission = store
        .create_mission(Some("native bubbles"), None, None, None, None, None, None)
        .await
        .unwrap();
    let bubble = "antigravity:session:turn:1";
    let snapshot = |revision, text: &str, done| AgentEvent::TextOp {
        mission_id: mission.id,
        bubble_id: bubble.into(),
        ops: if done {
            vec![
                TextOp::Snapshot {
                    text: text.into(),
                    revision,
                },
                TextOp::Finalize,
            ]
        } else {
            vec![TextOp::Snapshot {
                text: text.into(),
                revision,
            }]
        },
    };
    store
        .log_event(mission.id, &snapshot(1, "First 🦀", false))
        .await
        .unwrap();
    let active = store
        .get_events(mission.id, None, None, None)
        .await
        .unwrap();
    assert_eq!(active[0].event_type, "text_op");
    store
        .log_event(mission.id, &snapshot(2, "First 🦀 complete", true))
        .await
        .unwrap();
    store
        .log_event(mission.id, &snapshot(1, "First 🦀", false))
        .await
        .unwrap();
    store
        .log_event(mission.id, &snapshot(2, "First 🦀 complete", true))
        .await
        .unwrap();
    let events = store
        .get_events(mission.id, None, None, None)
        .await
        .unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type, "assistant_message_canonical");
    assert_eq!(events[0].content, "First 🦀 complete");
    assert_eq!(events[0].metadata["revision"], 2);
}

#[tokio::test]
async fn finalized_text_ops_collapse_to_canonical_assistant_row() {
    use crate::api::control::{AgentEvent, TextOp};

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("text ops"), None, None, None, None, None, None)
        .await
        .expect("mission");

    store
        .log_event(
            mission.id,
            &AgentEvent::TextOp {
                mission_id: mission.id,
                bubble_id: "bubble-a".to_string(),
                ops: vec![TextOp::Insert {
                    pos: 0,
                    text: "Hello wrld".to_string(),
                }],
            },
        )
        .await
        .expect("first op");
    store
        .log_event(
            mission.id,
            &AgentEvent::TextOp {
                mission_id: mission.id,
                bubble_id: "bubble-a".to_string(),
                ops: vec![
                    TextOp::Insert {
                        pos: 7,
                        text: "o".to_string(),
                    },
                    TextOp::Finalize,
                ],
            },
        )
        .await
        .expect("finalize op");

    let events = store
        .get_events(mission.id, None, None, None)
        .await
        .expect("events");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type, "assistant_message_canonical");
    assert_eq!(events[0].event_id.as_deref(), Some("bubble-a"));
    assert_eq!(events[0].content, "Hello world");
}

#[tokio::test]
async fn hybrid_memory_search_prioritizes_specific_fact_matches() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;

    store
        .upsert_telegram_structured_memory(test_memory_entry(
            channel_id,
            10,
            TelegramStructuredMemoryScope::User,
            TelegramStructuredMemoryKind::Fact,
            Some("identifiant prod"),
            "POLARIS-19",
            Some(42),
        ))
        .await
        .expect("user fact");
    store
        .upsert_telegram_structured_memory(test_memory_entry(
            channel_id,
            10,
            TelegramStructuredMemoryScope::Chat,
            TelegramStructuredMemoryKind::Note,
            None,
            "Les logs prod sont sur le serveur principal",
            None,
        ))
        .await
        .expect("chat note");

    let hits = store
        .search_telegram_memory_context_hybrid(
            channel_id,
            10,
            Some(42),
            "Quel est mon identifiant prod ?",
            5,
        )
        .await
        .expect("hybrid search");

    assert!(!hits.is_empty(), "expected at least one hybrid hit");
    assert_eq!(hits[0].entry.label.as_deref(), Some("identifiant prod"));
    assert_eq!(hits[0].entry.value, "POLARIS-19");
    assert!(hits[0].score > hits.last().map(|hit| hit.score).unwrap_or(0.0));
}

#[tokio::test]
async fn paloma_mission_card_roundtrips_through_upsert_touch_and_archive() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Card mission"), None, None, None, None, None, None)
        .await
        .expect("mission");
    let channel_id = create_test_channel(&store).await;

    let initial = PalomaMissionCard {
        mission_id: mission.id,
        telegram_user_id: 1_139_694_048,
        channel_id,
        chat_id: 1_139_694_048,
        message_id: 100,
        content_hash: "hash-v1".to_string(),
        anchor_ts: "2026-05-24T01:00:00Z".to_string(),
        last_edit_ts: "2026-05-24T01:00:00Z".to_string(),
        version: 1,
        archived: false,
    };
    store
        .upsert_paloma_mission_card(initial.clone())
        .await
        .expect("insert card");

    let loaded = store
        .get_paloma_mission_card(mission.id)
        .await
        .expect("get card")
        .expect("card exists");
    assert_eq!(loaded.message_id, 100);
    assert_eq!(loaded.content_hash, "hash-v1");
    assert!(!loaded.archived);

    store
        .touch_paloma_mission_card(mission.id, "hash-v2", "2026-05-24T01:30:00Z")
        .await
        .expect("touch card");
    let touched = store
        .get_paloma_mission_card(mission.id)
        .await
        .expect("get touched")
        .expect("card exists after touch");
    assert_eq!(touched.content_hash, "hash-v2");
    assert_eq!(touched.version, 2);
    // Anchor untouched by `touch_paloma_mission_card`; only re-anchor
    // replaces it.
    assert_eq!(touched.anchor_ts, "2026-05-24T01:00:00Z");

    let active_cards = store
        .list_active_paloma_mission_cards(1_139_694_048)
        .await
        .expect("list cards");
    assert_eq!(active_cards.len(), 1);

    store
        .archive_paloma_mission_card(mission.id)
        .await
        .expect("archive card");
    let after_archive = store
        .list_active_paloma_mission_cards(1_139_694_048)
        .await
        .expect("list cards post-archive");
    assert!(after_archive.is_empty(), "archived cards must be excluded");
    let still_present = store
        .get_paloma_mission_card(mission.id)
        .await
        .expect("get archived")
        .expect("archived row still readable");
    assert!(still_present.archived);
}

#[tokio::test]
async fn paloma_cooldown_state_roundtrips_and_resets_per_mission() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission_a = store
        .create_mission(Some("Mission A"), None, None, None, None, None, None)
        .await
        .expect("mission A");
    let mission_b = store
        .create_mission(Some("Mission B"), None, None, None, None, None, None)
        .await
        .expect("mission B");

    let state_a = PalomaCooldownState {
        mission_id: mission_a.id,
        alert_class: "mission_long_running".to_string(),
        telegram_user_id: 1_139_694_048,
        last_sent_at: "2026-05-24T01:00:00Z".to_string(),
        next_eligible_at: "2026-05-24T01:30:00Z".to_string(),
        backoff_step: 0,
    };
    store
        .upsert_paloma_cooldown_state(state_a.clone())
        .await
        .expect("insert cooldown A");
    let state_b = PalomaCooldownState {
        mission_id: mission_b.id,
        alert_class: "mission_awaiting_user".to_string(),
        telegram_user_id: 1_139_694_048,
        last_sent_at: "2026-05-24T01:00:00Z".to_string(),
        next_eligible_at: "2026-05-24T01:30:00Z".to_string(),
        backoff_step: 0,
    };
    store
        .upsert_paloma_cooldown_state(state_b.clone())
        .await
        .expect("insert cooldown B");

    // Update mission A in-place (same primary key) to bump the step.
    let bumped = PalomaCooldownState {
        backoff_step: 1,
        next_eligible_at: "2026-05-24T03:30:00Z".to_string(),
        ..state_a.clone()
    };
    store
        .upsert_paloma_cooldown_state(bumped.clone())
        .await
        .expect("bump cooldown");
    let reloaded = store
        .get_paloma_cooldown_state(1_139_694_048, mission_a.id, "mission_long_running")
        .await
        .expect("reload cooldown")
        .expect("row present");
    assert_eq!(reloaded.backoff_step, 1);
    assert_eq!(reloaded.next_eligible_at, "2026-05-24T03:30:00Z");

    // Reset wipes mission A only; mission B is untouched.
    store
        .reset_paloma_cooldown_for_mission(mission_a.id)
        .await
        .expect("reset cooldown A");
    let after_reset = store
        .get_paloma_cooldown_state(1_139_694_048, mission_a.id, "mission_long_running")
        .await
        .expect("get post-reset");
    assert!(after_reset.is_none(), "mission A cooldown must be gone");
    let mission_b_still_there = store
        .get_paloma_cooldown_state(1_139_694_048, mission_b.id, "mission_awaiting_user")
        .await
        .expect("get B")
        .expect("B still present");
    assert_eq!(mission_b_still_there.backoff_step, 0);
}

#[tokio::test]
async fn paloma_cooldown_resets_when_mission_status_changes() {
    // Mission status transitions are a meaningful signal change: the
    // user gets a fresh shot at being notified about the new state, so
    // cooldown must be wiped.
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(
            Some("Reset on status change"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission");

    store
        .upsert_paloma_cooldown_state(PalomaCooldownState {
            mission_id: mission.id,
            alert_class: "mission_long_running".to_string(),
            telegram_user_id: 1_139_694_048,
            last_sent_at: "2026-05-24T01:00:00Z".to_string(),
            next_eligible_at: "2026-05-24T09:00:00Z".to_string(),
            backoff_step: 2,
        })
        .await
        .expect("insert cooldown");

    store
        .update_mission_status(mission.id, MissionStatus::AwaitingUser)
        .await
        .expect("status change");

    let after = store
        .get_paloma_cooldown_state(1_139_694_048, mission.id, "mission_long_running")
        .await
        .expect("get cooldown after status change");
    assert!(
        after.is_none(),
        "status change must wipe cooldown so the new state alerts immediately"
    );
}

#[tokio::test]
async fn paloma_user_preferences_roundtrip_and_sent_count_window() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");

    assert!(store
        .get_paloma_user_preferences(1_139_694_048)
        .await
        .expect("get prefs")
        .is_none());

    let mut prefs = PalomaUserPreferences::default_for(1_139_694_048, "2026-05-24T00:00:00Z");
    prefs.timezone = "Europe/Paris".to_string();
    prefs.max_interrupts_per_hour = 2;
    store
        .upsert_paloma_user_preferences(prefs.clone())
        .await
        .expect("upsert prefs");
    let loaded = store
        .get_paloma_user_preferences(1_139_694_048)
        .await
        .expect("get prefs after insert")
        .expect("prefs exist");
    assert_eq!(loaded.timezone, "Europe/Paris");
    assert_eq!(loaded.max_interrupts_per_hour, 2);
    assert_eq!(loaded.quiet_hours_start, Some(23));
    assert_eq!(loaded.quiet_hours_end, Some(8));

    // Re-upsert updates fields in place (no duplicates).
    let mut prefs2 = prefs.clone();
    prefs2.max_interrupts_per_hour = 5;
    prefs2.updated_at = "2026-05-24T01:00:00Z".to_string();
    store
        .upsert_paloma_user_preferences(prefs2)
        .await
        .expect("upsert prefs again");
    let reloaded = store
        .get_paloma_user_preferences(1_139_694_048)
        .await
        .expect("get prefs after re-upsert")
        .expect("prefs exist");
    assert_eq!(reloaded.max_interrupts_per_hour, 5);

    // Sent-count window: 0 with no sent alerts.
    let count = store
        .count_paloma_sent_alerts_since(1_139_694_048, "2026-05-24T00:00:00Z")
        .await
        .expect("count");
    assert_eq!(count, 0);

    // Insert a pending alert and mark it sent, then assert it's counted.
    let mission = store
        .create_mission(Some("Counting"), None, None, None, None, None, None)
        .await
        .expect("mission");
    let alert = TelegramAlert {
        id: Uuid::new_v4(),
        telegram_user_id: 1_139_694_048,
        mission_id: Some(mission.id),
        event_kind: "mission_failed:1".to_string(),
        importance: "high".to_string(),
        title: "X".to_string(),
        body: "X failed.".to_string(),
        status: "pending".to_string(),
        telegram_message_id: None,
        last_error: None,
        created_at: "2026-05-24T02:00:00Z".to_string(),
        sent_at: None,
        acknowledged_at: None,
    };
    let inserted = store
        .create_telegram_alert_if_absent(alert)
        .await
        .expect("insert alert")
        .expect("inserted");
    store
        .mark_telegram_alert_sent(inserted.id, Some(42), "2026-05-24T02:01:00Z")
        .await
        .expect("mark sent");

    let count_after = store
        .count_paloma_sent_alerts_since(1_139_694_048, "2026-05-24T00:00:00Z")
        .await
        .expect("count after");
    assert_eq!(count_after, 1);
    // Window that excludes the send time returns 0.
    let count_recent = store
        .count_paloma_sent_alerts_since(1_139_694_048, "2026-05-24T03:00:00Z")
        .await
        .expect("count recent");
    assert_eq!(count_recent, 0);
}

#[tokio::test]
async fn paloma_sent_count_treats_digest_bundle_as_one_message() {
    // Regression: rate limit must count Telegram messages, not the alert
    // rows they bundled. A digest with N alerts shares one
    // telegram_message_id; counting rows would burn the user's hourly
    // budget N× faster than reality.
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Bundled"), None, None, None, None, None, None)
        .await
        .expect("mission");

    // Five distinct pending alerts marked sent under the same digest
    // message_id — counts as one interrupt.
    for n in 0..5 {
        let alert = TelegramAlert {
            id: Uuid::new_v4(),
            telegram_user_id: 1_139_694_048,
            mission_id: Some(mission.id),
            event_kind: format!("mission_failed:{n}"),
            importance: "high".to_string(),
            title: "X".to_string(),
            body: "X failed.".to_string(),
            status: "pending".to_string(),
            telegram_message_id: None,
            last_error: None,
            created_at: format!("2026-05-24T01:0{n}:00Z"),
            sent_at: None,
            acknowledged_at: None,
        };
        let inserted = store
            .create_telegram_alert_if_absent(alert)
            .await
            .expect("insert")
            .expect("new row");
        store
            .mark_telegram_alert_sent(inserted.id, Some(777), "2026-05-24T02:00:00Z")
            .await
            .expect("mark sent");
    }
    // A second digest a few minutes later — different message_id.
    let alert = TelegramAlert {
        id: Uuid::new_v4(),
        telegram_user_id: 1_139_694_048,
        mission_id: Some(mission.id),
        event_kind: "mission_long_running".to_string(),
        importance: "normal".to_string(),
        title: "X".to_string(),
        body: "X still running.".to_string(),
        status: "pending".to_string(),
        telegram_message_id: None,
        last_error: None,
        created_at: "2026-05-24T02:30:00Z".to_string(),
        sent_at: None,
        acknowledged_at: None,
    };
    let inserted = store
        .create_telegram_alert_if_absent(alert)
        .await
        .expect("insert second")
        .expect("new row");
    store
        .mark_telegram_alert_sent(inserted.id, Some(778), "2026-05-24T02:30:00Z")
        .await
        .expect("mark sent second");

    let count = store
        .count_paloma_sent_alerts_since(1_139_694_048, "2026-05-24T00:00:00Z")
        .await
        .expect("count");
    // Six alert rows, two distinct Telegram messages → count == 2.
    assert_eq!(count, 2);
}

#[tokio::test]
async fn paloma_refresh_pending_telegram_alert_body_overwrites_stale_pending_row() {
    // Regression: long-running alerts collapse to one event_kind per
    // mission and `INSERT OR IGNORE` keeps the first body. The refresh
    // helper must update the pending row in place so a 4-hour-stale
    // "running for 0m" body doesn't show up in the digest.
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Long runner"), None, None, None, None, None, None)
        .await
        .expect("mission");

    let alert = TelegramAlert {
        id: Uuid::new_v4(),
        telegram_user_id: 1_139_694_048,
        mission_id: Some(mission.id),
        event_kind: "mission_long_running".to_string(),
        importance: "normal".to_string(),
        title: "Long runner".to_string(),
        body: "Long runner is still running.".to_string(),
        status: "pending".to_string(),
        telegram_message_id: None,
        last_error: None,
        created_at: "2026-05-24T01:00:00Z".to_string(),
        sent_at: None,
        acknowledged_at: None,
    };
    store
        .create_telegram_alert_if_absent(alert)
        .await
        .expect("insert")
        .expect("new row");

    let refreshed = store
        .refresh_pending_telegram_alert_body(
            1_139_694_048,
            mission.id,
            "mission_long_running",
            "Long runner",
            "Long runner is still running.\n\nLatest: now active for 4h.",
            "high",
        )
        .await
        .expect("refresh");
    assert!(refreshed, "should report row updated");

    let pending = store
        .list_pending_telegram_alerts(1_139_694_048, 10)
        .await
        .expect("list");
    assert_eq!(pending.len(), 1);
    assert!(pending[0].body.contains("4h"));
    assert_eq!(pending[0].importance, "high");

    // Sent alerts are not refreshed — only pending.
    store
        .mark_telegram_alert_sent(pending[0].id, Some(99), "2026-05-24T05:00:00Z")
        .await
        .expect("mark sent");
    let refreshed2 = store
        .refresh_pending_telegram_alert_body(
            1_139_694_048,
            mission.id,
            "mission_long_running",
            "Long runner",
            "Long runner is still running.\n\nLatest: now 8h.",
            "high",
        )
        .await
        .expect("refresh after sent");
    assert!(!refreshed2, "sent rows must not be refreshed");
}

#[tokio::test]
async fn get_latest_events_returns_newest_n_in_chronological_order() {
    use crate::api::control::AgentEvent;
    // Regression: callers want "what just happened", not the first
    // events of a long-running mission. `get_events(..., limit, 0)`
    // returns oldest-first; `get_latest_events` must return the tail.
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Long stream"), None, None, None, None, None, None)
        .await
        .expect("mission");

    for n in 0..50 {
        store
            .log_event(
                mission.id,
                &AgentEvent::AssistantMessage {
                    id: Uuid::new_v4(),
                    content: format!("msg-{n}"),
                    success: true,
                    cost_cents: 0,
                    cost_source: CostSource::Unknown,
                    usage: None,
                    model: None,
                    model_normalized: None,
                    mission_id: Some(mission.id),
                    shared_files: None,
                    resumable: false,
                    completion_evidence: None,
                },
            )
            .await
            .expect("log");
    }

    let latest = store
        .get_latest_events(mission.id, 5)
        .await
        .expect("get_latest_events");
    assert_eq!(latest.len(), 5);
    // Returned ASC, so the *first* element of latest 5 corresponds to
    // event #45 and the last to event #49.
    let contents: Vec<&str> = latest.iter().map(|e| e.content.as_str()).collect();
    assert_eq!(
        contents,
        vec!["msg-45", "msg-46", "msg-47", "msg-48", "msg-49"]
    );
}

#[tokio::test]
async fn nth_recent_event_sequence_anchors_on_conversation_messages() {
    use crate::api::control::AgentEvent;
    // The conversation-anchored snapshot needs the sequence of the
    // Nth-most-recent user/assistant message, ignoring the (far more
    // numerous) tool calls in between.
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Tool heavy"), None, None, None, None, None, None)
        .await
        .expect("mission");

    let anchor_types = ["user_message", "assistant_message"];

    // No conversation messages yet → None.
    assert_eq!(
        store
            .nth_recent_event_sequence(mission.id, &anchor_types, 1)
            .await
            .expect("query"),
        None
    );

    // Interleave 5 assistant messages with 3 tool calls between each.
    // Record each assistant message's sequence as we go.
    let mut assistant_seqs: Vec<i64> = Vec::new();
    for n in 0..5 {
        store
            .log_event(
                mission.id,
                &AgentEvent::AssistantMessage {
                    id: Uuid::new_v4(),
                    content: format!("assistant-{n}"),
                    success: true,
                    cost_cents: 0,
                    cost_source: CostSource::Unknown,
                    usage: None,
                    model: None,
                    model_normalized: None,
                    mission_id: Some(mission.id),
                    shared_files: None,
                    resumable: false,
                    completion_evidence: None,
                },
            )
            .await
            .expect("log assistant");
        assistant_seqs.push(store.max_event_sequence(mission.id).await.expect("max"));
        for t in 0..3 {
            store
                .log_event(
                    mission.id,
                    &AgentEvent::ToolCall {
                        tool_call_id: format!("tc-{n}-{t}"),
                        name: "bash".to_string(),
                        args: serde_json::json!({"cmd": "echo hi"}),
                        mission_id: Some(mission.id),
                    },
                )
                .await
                .expect("log tool");
        }
    }

    // 1st-most-recent conversation message = the last assistant (index 4).
    assert_eq!(
        store
            .nth_recent_event_sequence(mission.id, &anchor_types, 1)
            .await
            .expect("query"),
        Some(assistant_seqs[4])
    );
    // 3rd-most-recent = assistant index 2, even though ~6 tool calls
    // sit between it and the head.
    assert_eq!(
        store
            .nth_recent_event_sequence(mission.id, &anchor_types, 3)
            .await
            .expect("query"),
        Some(assistant_seqs[2])
    );
    // Asking for more conversation messages than exist → None.
    assert_eq!(
        store
            .nth_recent_event_sequence(mission.id, &anchor_types, 6)
            .await
            .expect("query"),
        None
    );
}

#[tokio::test]
async fn paloma_cooldown_preserved_when_status_update_is_a_noop() {
    // Regression: heartbeats and internal restarts can re-set the same
    // status. Wiping cooldown in that case would skip the user's
    // exponential backoff.
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Heartbeat"), None, None, None, None, None, None)
        .await
        .expect("mission");

    store
        .upsert_paloma_cooldown_state(PalomaCooldownState {
            mission_id: mission.id,
            alert_class: "mission_long_running".to_string(),
            telegram_user_id: 1_139_694_048,
            last_sent_at: "2026-05-24T01:00:00Z".to_string(),
            next_eligible_at: "2026-05-24T09:00:00Z".to_string(),
            backoff_step: 2,
        })
        .await
        .expect("insert cooldown");

    // Mission starts as Pending. Set it Active for real — should wipe.
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("status change");
    let after_real_change = store
        .get_paloma_cooldown_state(1_139_694_048, mission.id, "mission_long_running")
        .await
        .expect("get cooldown");
    assert!(
        after_real_change.is_none(),
        "real status change must wipe cooldown"
    );

    // Re-insert cooldown, then write Active again — must NOT wipe.
    store
        .upsert_paloma_cooldown_state(PalomaCooldownState {
            mission_id: mission.id,
            alert_class: "mission_long_running".to_string(),
            telegram_user_id: 1_139_694_048,
            last_sent_at: "2026-05-24T02:00:00Z".to_string(),
            next_eligible_at: "2026-05-24T10:00:00Z".to_string(),
            backoff_step: 2,
        })
        .await
        .expect("reinsert cooldown");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("no-op status write");
    let after_noop = store
        .get_paloma_cooldown_state(1_139_694_048, mission.id, "mission_long_running")
        .await
        .expect("get cooldown")
        .expect("cooldown still present");
    assert_eq!(
        after_noop.backoff_step, 2,
        "no-op status writes must leave the backoff ladder intact"
    );
}

#[tokio::test]
async fn paloma_memory_consolidation_deletes_older_explicit_rules_and_search_rows() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;
    let older_id = Uuid::new_v4();
    let newer_id = Uuid::new_v4();
    let channel_id_str = channel_id.to_string();

    {
        let conn = store.conn.lock().await;
        for (id, value, updated_at) in [
            (older_id, "tell me everything", "2026-05-20T10:00:00Z"),
            (newer_id, "only failures", "2026-05-20T11:00:00Z"),
        ] {
            conn.execute(
                "INSERT INTO telegram_structured_memory (
                        id, channel_id, chat_id, mission_id, scope, kind, label, normalized_label,
                        value, subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                     ) VALUES (?1, ?2, 10, NULL, 'user', 'preference', 'alerts', 'alerts',
                        ?3, 42, 'th0rgal', '@th0rgal', 1, 'user',
                        '2026-05-20T09:00:00Z', ?4)",
                params![id.to_string(), channel_id_str, value, updated_at],
            )
            .expect("insert duplicate memory");
            conn.execute(
                "INSERT INTO telegram_structured_memory_fts (
                        entry_id, channel_id, chat_id, scope, subject_user_id, search_text
                     ) VALUES (?1, ?2, 10, 'user', 42, ?3)",
                params![
                    id.to_string(),
                    channel_id_str,
                    format!("preference alerts {}", value)
                ],
            )
            .expect("insert duplicate memory search row");
        }
    }

    let deleted = store
        .consolidate_telegram_structured_memory(channel_id, 1)
        .await
        .expect("consolidate memory");
    assert_eq!(deleted, 1);

    let entries = store
        .list_telegram_structured_memory(channel_id, Some(10), Some(42), 10)
        .await
        .expect("list memory");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, newer_id);
    assert_eq!(entries[0].value, "only failures");

    let old_hits = store
        .search_telegram_memory_context(channel_id, 10, Some(42), "everything", 10)
        .await
        .expect("search old memory");
    assert!(old_hits.is_empty());
    let new_hits = store
        .search_telegram_memory_context(channel_id, 10, Some(42), "failures", 10)
        .await
        .expect("search new memory");
    assert_eq!(new_hits.len(), 1);
    assert_eq!(new_hits[0].id, newer_id);
}

#[tokio::test]
async fn hybrid_memory_search_keeps_user_scope_across_chat_contexts() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;

    store
        .upsert_telegram_structured_memory(test_memory_entry(
            channel_id,
            1,
            TelegramStructuredMemoryScope::User,
            TelegramStructuredMemoryKind::Fact,
            Some("code universel"),
            "ASTRA-42",
            Some(42),
        ))
        .await
        .expect("user fact");

    let hits = store
        .search_telegram_memory_context_hybrid(
            channel_id,
            999,
            Some(42),
            "Quel est mon code universel ?",
            5,
        )
        .await
        .expect("hybrid search");

    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].entry.scope, TelegramStructuredMemoryScope::User);
    assert_eq!(hits[0].entry.value, "ASTRA-42");
}

#[tokio::test]
async fn hybrid_memory_search_reflects_updated_fact_values() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;

    store
        .upsert_telegram_structured_memory(test_memory_entry(
            channel_id,
            1,
            TelegramStructuredMemoryScope::User,
            TelegramStructuredMemoryKind::Fact,
            Some("code universel"),
            "ASTRA-42",
            Some(42),
        ))
        .await
        .expect("initial fact");
    store
        .upsert_telegram_structured_memory(test_memory_entry(
            channel_id,
            1,
            TelegramStructuredMemoryScope::User,
            TelegramStructuredMemoryKind::Fact,
            Some("code universel"),
            "ASTRA-43",
            Some(42),
        ))
        .await
        .expect("updated fact");

    let hits = store
        .search_telegram_memory_context_hybrid(channel_id, 1, Some(42), "mon code universel", 5)
        .await
        .expect("hybrid search");

    assert_eq!(hits[0].entry.value, "ASTRA-43");
}

#[tokio::test]
async fn telegram_memory_fts_upsert_replaces_existing_entry_in_place() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let channel_id = create_test_channel(&store).await;

    store
        .upsert_telegram_structured_memory(test_memory_entry(
            channel_id,
            1,
            TelegramStructuredMemoryScope::User,
            TelegramStructuredMemoryKind::Fact,
            Some("code universel"),
            "ASTRA-42",
            Some(42),
        ))
        .await
        .expect("initial fact");
    store
        .upsert_telegram_structured_memory(test_memory_entry(
            channel_id,
            1,
            TelegramStructuredMemoryScope::User,
            TelegramStructuredMemoryKind::Fact,
            Some("code universel"),
            "ASTRA-43",
            Some(42),
        ))
        .await
        .expect("updated fact");

    let conn = store.conn.lock().await;
    let row_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM telegram_structured_memory_fts",
            [],
            |row| row.get(0),
        )
        .expect("fts row count");
    let search_text: String = conn
        .query_row(
            "SELECT search_text FROM telegram_structured_memory_fts LIMIT 1",
            [],
            |row| row.get(0),
        )
        .expect("fts search text");
    drop(conn);

    assert_eq!(row_count, 1);
    assert!(search_text.contains("astra 43"));
    assert!(!search_text.contains("astra 42"));
}

#[tokio::test]
async fn telegram_memory_migration_bootstraps_empty_fts_index_only_when_needed() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let db_path = temp_dir.path().to_path_buf();
    let channel_id;

    {
        let store = SqliteMissionStore::new(db_path.clone(), "test-user")
            .await
            .expect("sqlite store");
        channel_id = create_test_channel(&store).await;
        store
            .upsert_telegram_structured_memory(test_memory_entry(
                channel_id,
                1,
                TelegramStructuredMemoryScope::User,
                TelegramStructuredMemoryKind::Fact,
                Some("code universel"),
                "ASTRA-42",
                Some(42),
            ))
            .await
            .expect("user fact");

        let conn = store.conn.lock().await;
        conn.execute("DELETE FROM telegram_structured_memory_fts", [])
            .expect("clear fts rows");
    }

    let store = SqliteMissionStore::new(db_path.clone(), "test-user")
        .await
        .expect("sqlite store reopen");
    let conn = store.conn.lock().await;
    let row_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM telegram_structured_memory_fts",
            [],
            |row| row.get(0),
        )
        .expect("fts row count");
    drop(conn);

    assert_eq!(row_count, 1);

    let hits = store
        .search_telegram_memory_context_hybrid(channel_id, 1, Some(42), "code universel", 5)
        .await
        .expect("hybrid search");
    assert_eq!(hits[0].entry.value, "ASTRA-42");
}

#[tokio::test]
async fn telegram_memory_migration_does_not_rebuild_populated_fts_index() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let db_path = temp_dir.path().to_path_buf();

    {
        let store = SqliteMissionStore::new(db_path.clone(), "test-user")
            .await
            .expect("sqlite store");
        let channel_id = create_test_channel(&store).await;
        store
            .upsert_telegram_structured_memory(test_memory_entry(
                channel_id,
                1,
                TelegramStructuredMemoryScope::User,
                TelegramStructuredMemoryKind::Fact,
                Some("code universel"),
                "ASTRA-42",
                Some(42),
            ))
            .await
            .expect("user fact");

        let conn = store.conn.lock().await;
        conn.execute(
                "UPDATE telegram_structured_memory_fts SET search_text = 'stale marker' WHERE rowid IN (
                    SELECT rowid FROM telegram_structured_memory_fts LIMIT 1
                )",
                [],
            )
            .expect("overwrite fts search text");
    }

    let store = SqliteMissionStore::new(db_path, "test-user")
        .await
        .expect("sqlite store reopen");
    let conn = store.conn.lock().await;
    let search_text: String = conn
        .query_row(
            "SELECT search_text FROM telegram_structured_memory_fts LIMIT 1",
            [],
            |row| row.get(0),
        )
        .expect("fts search text");
    drop(conn);

    assert_eq!(search_text, "stale marker");
}

#[tokio::test]
async fn get_events_since_returns_only_events_after_seq() {
    use crate::api::control::AgentEvent;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("seq test"), None, None, None, None, None, None)
        .await
        .expect("mission");

    for i in 0..5 {
        store
            .log_event(
                mission.id,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content: format!("msg {i}"),
                    queued: false,
                    mission_id: Some(mission.id),
                    source: None,
                },
            )
            .await
            .expect("log user message");
        store
            .log_event(
                mission.id,
                &AgentEvent::AssistantMessage {
                    id: Uuid::new_v4(),
                    content: format!("reply {i}"),
                    success: true,
                    cost_cents: 0,
                    cost_source: CostSource::Unknown,
                    usage: None,
                    model: None,
                    model_normalized: None,
                    mission_id: Some(mission.id),
                    shared_files: None,
                    resumable: false,
                    completion_evidence: None,
                },
            )
            .await
            .expect("log assistant");
    }

    // Max sequence should reflect all 10 events
    let max = store.max_event_sequence(mission.id).await.expect("max seq");
    assert_eq!(max, 10);

    // since_seq=0 returns all 10 events, ordered ASC
    let from_zero = store
        .get_events_since(mission.id, 0, None, None)
        .await
        .expect("get_events_since zero");
    assert_eq!(from_zero.len(), 10);
    let seqs: Vec<i64> = from_zero.iter().map(|e| e.sequence).collect();
    assert_eq!(seqs, (1..=10).collect::<Vec<_>>());

    // since_seq=5 returns events 6..=10
    let tail = store
        .get_events_since(mission.id, 5, None, None)
        .await
        .expect("get_events_since tail");
    assert_eq!(tail.len(), 5);
    assert_eq!(tail.first().map(|e| e.sequence), Some(6));
    assert_eq!(tail.last().map(|e| e.sequence), Some(10));

    // since_seq=10 returns empty (caller is already caught up)
    let empty = store
        .get_events_since(mission.id, 10, None, None)
        .await
        .expect("get_events_since empty");
    assert!(empty.is_empty());

    // limit clamps the response
    let limited = store
        .get_events_since(mission.id, 0, None, Some(3))
        .await
        .expect("get_events_since limited");
    assert_eq!(limited.len(), 3);
    assert_eq!(
        limited.iter().map(|e| e.sequence).collect::<Vec<_>>(),
        vec![1, 2, 3]
    );

    // event_types filter narrows further
    let assistants_only = store
        .get_events_since(mission.id, 0, Some(&["assistant_message"]), None)
        .await
        .expect("get_events_since types");
    assert_eq!(assistants_only.len(), 5);
    for e in &assistants_only {
        assert_eq!(e.event_type, "assistant_message");
    }
}

#[tokio::test]
async fn get_events_before_returns_only_events_below_seq_in_ascending_order() {
    use crate::api::control::AgentEvent;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("before test"), None, None, None, None, None, None)
        .await
        .expect("mission");

    for i in 0..5 {
        store
            .log_event(
                mission.id,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content: format!("msg {i}"),
                    queued: false,
                    mission_id: Some(mission.id),
                    source: None,
                },
            )
            .await
            .expect("log user message");
        store
            .log_event(
                mission.id,
                &AgentEvent::AssistantMessage {
                    id: Uuid::new_v4(),
                    content: format!("reply {i}"),
                    success: true,
                    cost_cents: 0,
                    cost_source: CostSource::Unknown,
                    usage: None,
                    model: None,
                    model_normalized: None,
                    mission_id: Some(mission.id),
                    shared_files: None,
                    resumable: false,
                    completion_evidence: None,
                },
            )
            .await
            .expect("log assistant");
    }

    // before_seq=11 returns all 10 events, ordered ASC.
    let all = store
        .get_events_before(mission.id, 11, None, None)
        .await
        .expect("get_events_before all");
    assert_eq!(all.len(), 10);
    let seqs: Vec<i64> = all.iter().map(|e| e.sequence).collect();
    assert_eq!(seqs, (1..=10).collect::<Vec<_>>());

    // before_seq=6 returns sequences 1..=5, ordered ASC.
    let head = store
        .get_events_before(mission.id, 6, None, None)
        .await
        .expect("get_events_before head");
    assert_eq!(head.len(), 5);
    assert_eq!(head.first().map(|e| e.sequence), Some(1));
    assert_eq!(head.last().map(|e| e.sequence), Some(5));

    // before_seq=1 returns empty (caller already at the start).
    let empty = store
        .get_events_before(mission.id, 1, None, None)
        .await
        .expect("get_events_before empty");
    assert!(empty.is_empty());

    // With limit=3 and before_seq=11 we want the 3 events IMMEDIATELY
    // preceding seq=11 — i.e. seqs 8, 9, 10 — returned in ASC order.
    // This is the contract that drives backwards pagination: each page
    // must be the latest N below the cursor, then sorted oldest-first.
    let last_three = store
        .get_events_before(mission.id, 11, None, Some(3))
        .await
        .expect("get_events_before limited");
    assert_eq!(last_three.len(), 3);
    assert_eq!(
        last_three.iter().map(|e| e.sequence).collect::<Vec<_>>(),
        vec![8, 9, 10]
    );

    // event_types filter narrows further (asks for only the assistant
    // events strictly before seq=11; sequences 2,4,6,8,10).
    let assistants_only = store
        .get_events_before(mission.id, 11, Some(&["assistant_message"]), None)
        .await
        .expect("get_events_before types");
    assert_eq!(assistants_only.len(), 5);
    for e in &assistants_only {
        assert_eq!(e.event_type, "assistant_message");
    }
    assert_eq!(
        assistants_only
            .iter()
            .map(|e| e.sequence)
            .collect::<Vec<_>>(),
        vec![2, 4, 6, 8, 10]
    );
}

// The `GET /events` handler routes a cursor-less request to
// `get_events_before(i64::MAX)` so the default page is the NEWEST `limit`
// events (the tail), ascending — not the oldest rows. This locks in that
// contract and the X-Max-Sequence value the handler reports alongside it.
#[tokio::test]
async fn no_cursor_default_returns_newest_page_ascending() {
    use crate::api::control::AgentEvent;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("default page"), None, None, None, None, None, None)
        .await
        .expect("mission");

    for i in 0..10 {
        store
            .log_event(
                mission.id,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content: format!("msg {i}"),
                    queued: false,
                    mission_id: Some(mission.id),
                    source: None,
                },
            )
            .await
            .expect("log user message");
    }

    // No-cursor + limit=3 must yield the newest three (8, 9, 10) ASC,
    // exactly what the handler now emits for `?limit=3` with no cursor.
    let newest = store
        .get_events_before(mission.id, i64::MAX, None, Some(3))
        .await
        .expect("get newest page");
    assert_eq!(
        newest.iter().map(|e| e.sequence).collect::<Vec<_>>(),
        vec![8, 9, 10],
        "no-cursor default should return the tail, not the oldest rows"
    );

    // X-Max-Sequence reflects the true tail regardless of the page limit.
    let max = store.max_event_sequence(mission.id).await.expect("max seq");
    assert_eq!(max, 10);

    // Explicit forward replay (`since_seq=0`) still pages from the start —
    // this path is untouched by the default change.
    let from_start = store
        .get_events_since(mission.id, 0, None, Some(3))
        .await
        .expect("get_events_since zero");
    assert_eq!(
        from_start.iter().map(|e| e.sequence).collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
}

#[tokio::test]
async fn max_event_sequence_is_zero_for_mission_with_no_events() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("empty"), None, None, None, None, None, None)
        .await
        .expect("mission");
    let max = store.max_event_sequence(mission.id).await.expect("max seq");
    assert_eq!(max, 0);
}

#[tokio::test]
async fn stale_query_uses_event_timestamp_when_newer_than_updated_at() {
    // Regression: a long agent run that's actively producing tool_call /
    // tool_result events but no assistant turns leaves `mission.updated_at`
    // frozen at the last turn boundary. The stale-cleanup query used to
    // look at `updated_at` alone and would auto-close such missions even
    // though they were demonstrably still active. With the events-aware
    // query, a recent event must keep the mission out of the result set.
    use crate::api::control::AgentEvent;
    use crate::api::mission_store::MissionStatus;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(
            Some("active-with-tool-calls"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("set active");

    // Back-date both metadata and any pre-existing events to 3 hours ago,
    // *then* log a fresh tool_call event so the events tail is current.
    let three_hours_ago = (chrono::Utc::now() - chrono::Duration::hours(3)).to_rfc3339();
    store
        .force_backdate_for_test(mission.id, &three_hours_ago)
        .await
        .expect("backdate");

    store
        .log_event(
            mission.id,
            &AgentEvent::ToolCall {
                tool_call_id: "tc-1".to_string(),
                name: "bash".to_string(),
                args: serde_json::json!({"command": "gh run watch 12345"}),
                mission_id: Some(mission.id),
            },
        )
        .await
        .expect("log fresh tool_call");

    // 2-hour staleness cutoff: even though `updated_at` is 3h old, the
    // fresh event must keep the mission out of the stale set.
    let stale = store
        .get_stale_active_missions(2)
        .await
        .expect("query stale");
    assert!(
        stale.iter().all(|m| m.id != mission.id),
        "mission with a recent tool_call must not be flagged stale (updated_at \
             alone is no longer the stale signal)"
    );
}

#[tokio::test]
async fn stale_query_flags_truly_idle_active_missions() {
    // Counterpart to the regression: a mission whose metadata *and* event
    // tail are both older than the cutoff is genuinely stale.
    use crate::api::mission_store::MissionStatus;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("idle"), None, None, None, None, None, None)
        .await
        .expect("mission");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("set active");
    let three_hours_ago = (chrono::Utc::now() - chrono::Duration::hours(3)).to_rfc3339();
    store
        .force_backdate_for_test(mission.id, &three_hours_ago)
        .await
        .expect("backdate");

    let stale = store
        .get_stale_active_missions(2)
        .await
        .expect("query stale");
    assert!(
        stale.iter().any(|m| m.id == mission.id),
        "mission with no recent events and old updated_at must still be flagged"
    );
}

#[tokio::test]
async fn recent_server_shutdown_query_skips_assistant_missions() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");

    let task_mission = store
        .create_mission(Some("task"), None, None, None, None, None, None)
        .await
        .expect("task mission");
    store
        .update_mission_status_with_reason(
            task_mission.id,
            MissionStatus::Interrupted,
            Some("server_shutdown"),
        )
        .await
        .expect("mark task interrupted");

    let assistant_mission = store
        .create_mission(Some("assistant"), None, None, None, None, None, None)
        .await
        .expect("assistant mission");
    store
        .update_mission_mode(assistant_mission.id, MissionMode::Assistant)
        .await
        .expect("set assistant mode");
    store
        .update_mission_status_with_reason(
            assistant_mission.id,
            MissionStatus::Interrupted,
            Some("server_shutdown"),
        )
        .await
        .expect("mark assistant interrupted");

    let mission_ids = store
        .get_recent_server_shutdown_mission_ids(48)
        .await
        .expect("recent server-shutdown missions");

    assert!(mission_ids.contains(&task_mission.id));
    assert!(!mission_ids.contains(&assistant_mission.id));

    let restart_mission = store
        .create_mission(Some("restart"), None, None, None, None, None, None)
        .await
        .expect("restart mission");
    store
        .update_mission_status_with_reason(
            restart_mission.id,
            MissionStatus::Interrupted,
            Some("service_restart"),
        )
        .await
        .expect("mark service_restart");
    let cancelled = store
        .create_mission(Some("cancelled"), None, None, None, None, None, None)
        .await
        .expect("cancelled mission");
    store
        .update_mission_status_with_reason(
            cancelled.id,
            MissionStatus::Interrupted,
            Some("cancelled"),
        )
        .await
        .expect("mark cancelled");
    let mission_ids = store
        .get_recent_server_shutdown_mission_ids(48)
        .await
        .expect("recent restart missions");
    assert!(
        mission_ids.contains(&restart_mission.id),
        "service_restart must be recovered with server_shutdown"
    );
    assert!(!mission_ids.contains(&cancelled.id));
}

#[tokio::test]
async fn text_delta_latest_update_advances_sequence_for_since_seq_replay() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("streaming"), None, None, None, None, None, None)
        .await
        .expect("mission");

    store
        .log_event(
            mission.id,
            &AgentEvent::TextDelta {
                content: "first draft".to_string(),
                mission_id: Some(mission.id),
            },
        )
        .await
        .expect("first text delta");
    let first_seq = store
        .max_event_sequence(mission.id)
        .await
        .expect("first max sequence");

    store
        .log_event(
            mission.id,
            &AgentEvent::ToolCall {
                tool_call_id: "tool-1".to_string(),
                name: "bash".to_string(),
                args: json!({ "command": "true" }),
                mission_id: Some(mission.id),
            },
        )
        .await
        .expect("tool call");
    let after_tool_seq = store
        .max_event_sequence(mission.id)
        .await
        .expect("tool max sequence");

    store
        .log_event(
            mission.id,
            &AgentEvent::TextDelta {
                content: "final useful draft".to_string(),
                mission_id: Some(mission.id),
            },
        )
        .await
        .expect("updated text delta");
    let final_seq = store
        .max_event_sequence(mission.id)
        .await
        .expect("final max sequence");

    assert!(after_tool_seq > first_seq);
    assert!(final_seq > after_tool_seq);

    let replay = store
        .get_events_since(mission.id, after_tool_seq, None, None)
        .await
        .expect("events since tool");
    assert_eq!(replay.len(), 1);
    assert_eq!(replay[0].event_type, "text_delta");
    assert_eq!(replay[0].content, "final useful draft");
    assert_eq!(replay[0].sequence, final_seq);
}

#[tokio::test]
async fn stale_query_uses_max_timestamp_not_max_sequence() {
    // Regression for a subtler variant: `log_event` updates an existing
    // row in-place when it sees a duplicate `event_id` (e.g. a
    // `text_delta_latest` row gets its `timestamp` rewritten on every
    // streamed delta), so the row with the highest `sequence` can carry
    // an *older* timestamp than a refreshed lower-sequence row. A query
    // that reads `ORDER BY sequence DESC LIMIT 1` would then miss the
    // refreshed row and falsely flag the mission stale. We force this
    // ordering by hand and confirm `MAX(timestamp)` recovers correctly.
    use crate::api::mission_store::MissionStatus;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("inplace-update"), None, None, None, None, None, None)
        .await
        .expect("mission");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("set active");

    let now = chrono::Utc::now();
    let three_hours_ago = (now - chrono::Duration::hours(3)).to_rfc3339();
    let one_minute_ago = (now - chrono::Duration::minutes(1)).to_rfc3339();
    let mid = mission.id.to_string();

    // Drive raw inserts so we can pin (sequence, timestamp) independently.
    // Highest sequence carries an old timestamp; a lower-sequence row
    // carries the recent one — exactly the in-place-update layout that
    // a sequence-based MAX would mishandle.
    store
        .force_backdate_for_test(mission.id, &three_hours_ago)
        .await
        .expect("backdate metadata");
    let conn = store.conn.clone();
    let three_hours_ago_clone = three_hours_ago.clone();
    let one_minute_ago_clone = one_minute_ago.clone();
    let mid_clone = mid.clone();
    tokio::task::spawn_blocking(move || {
        let conn = conn.blocking_lock();
        // Lower sequence, recent timestamp (the "refreshed" row)
        conn.execute(
            "INSERT INTO mission_events (mission_id, sequence, event_type, timestamp, content)
                 VALUES (?1, 1, 'text_delta', ?2, 'streaming…')",
            rusqlite::params![mid_clone, one_minute_ago_clone],
        )
        .expect("insert refreshed row");
        // Higher sequence, old timestamp (would be the row picked by ORDER BY sequence DESC)
        conn.execute(
            "INSERT INTO mission_events (mission_id, sequence, event_type, timestamp, content)
                 VALUES (?1, 2, 'tool_call', ?2, 'cmd')",
            rusqlite::params![mid_clone, three_hours_ago_clone],
        )
        .expect("insert old high-seq row");
    })
    .await
    .expect("raw inserts");

    let stale = store
        .get_stale_active_missions(2)
        .await
        .expect("query stale");
    assert!(
        stale.iter().all(|m| m.id != mission.id),
        "mission whose newest activity lives on a *lower* sequence row than \
             the highest sequence must NOT be flagged stale"
    );
}

#[tokio::test]
async fn stale_query_handles_missions_with_no_events() {
    // A freshly-created active mission with no events at all should fall
    // back to `updated_at` (via COALESCE in the query). When `updated_at`
    // is fresh, the mission is not stale.
    use crate::api::mission_store::MissionStatus;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("brand new"), None, None, None, None, None, None)
        .await
        .expect("mission");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("set active");

    let stale = store
        .get_stale_active_missions(2)
        .await
        .expect("query stale");
    assert!(
        stale.iter().all(|m| m.id != mission.id),
        "freshly-created mission with current updated_at and no events \
             must not be flagged stale"
    );
}

#[tokio::test]
async fn migration_purges_inactive_harness_loop_rows_on_reopen() {
    use std::collections::HashMap;

    // Keep the tempdir alive across two `new()` calls so we exercise the
    // migration path on an existing DB.
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let path = temp_dir.path().to_path_buf();

    let store = SqliteMissionStore::new(path.clone(), "test-user")
        .await
        .expect("first open");

    let mission = store
        .create_mission(
            Some("goal mission"),
            None,
            None,
            None,
            None,
            Some("codex"),
            None,
        )
        .await
        .expect("mission");

    // Seed: one inactive harness_loop row (the stale UI artifact we want
    // gone), one inactive scheduler row (user-defined, must be kept),
    // and one active harness_loop row (in-progress loop, must be kept).
    let stale_harness = Automation {
        id: Uuid::new_v4(),
        mission_id: mission.id,
        command_source: CommandSource::NativeLoop {
            harness: "codex".to_string(),
            command: "goal".to_string(),
            args: json!({ "objective": "old cycle" }),
        },
        trigger: TriggerType::AgentFinished,
        variables: HashMap::new(),
        active: false,
        created_at: now_string(),
        last_triggered_at: None,
        retry_config: RetryConfig::default(),
        stop_policy: StopPolicy::Never,
        fresh_session: FreshSession::Keep,
        consecutive_failures: 0,
        driver: AutomationDriver::HarnessLoop,
    };
    let preserved_scheduler = Automation {
        id: Uuid::new_v4(),
        mission_id: mission.id,
        command_source: CommandSource::Inline {
            content: "user-paused automation".into(),
        },
        trigger: TriggerType::AgentFinished,
        variables: HashMap::new(),
        active: false,
        created_at: now_string(),
        last_triggered_at: None,
        retry_config: RetryConfig::default(),
        stop_policy: StopPolicy::Never,
        fresh_session: FreshSession::Keep,
        consecutive_failures: 0,
        driver: AutomationDriver::Scheduler,
    };
    let preserved_active_harness = Automation {
        id: Uuid::new_v4(),
        mission_id: mission.id,
        command_source: CommandSource::NativeLoop {
            harness: "codex".to_string(),
            command: "goal".to_string(),
            args: json!({ "objective": "running cycle" }),
        },
        trigger: TriggerType::AgentFinished,
        variables: HashMap::new(),
        active: true,
        created_at: now_string(),
        last_triggered_at: None,
        retry_config: RetryConfig::default(),
        stop_policy: StopPolicy::Never,
        fresh_session: FreshSession::Keep,
        consecutive_failures: 0,
        driver: AutomationDriver::HarnessLoop,
    };
    let stale_id = stale_harness.id;
    let preserved_scheduler_id = preserved_scheduler.id;
    let preserved_active_id = preserved_active_harness.id;
    store
        .create_automation(stale_harness)
        .await
        .expect("seed stale");
    store
        .create_automation(preserved_scheduler)
        .await
        .expect("seed user-paused");
    store
        .create_automation(preserved_active_harness)
        .await
        .expect("seed active");

    // Drop the store to release the SQLite connection, then re-open —
    // this triggers `run_migrations` against the existing schema.
    drop(store);

    let store = SqliteMissionStore::new(path, "test-user")
        .await
        .expect("reopen triggers migration");
    let rows = store
        .get_mission_automations(mission.id)
        .await
        .expect("list");
    let ids: Vec<_> = rows.iter().map(|r| r.id).collect();
    assert!(
        !ids.contains(&stale_id),
        "stale inactive harness_loop row should be purged by migration"
    );
    assert!(
        ids.contains(&preserved_scheduler_id),
        "inactive scheduler row is user-defined and must survive migration"
    );
    assert!(
        ids.contains(&preserved_active_id),
        "active harness_loop row represents an in-progress loop and must survive"
    );
}

#[tokio::test]
async fn durable_job_terminal_automation_roundtrips() {
    use std::collections::HashMap;

    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(
            Some("durable owner"),
            None,
            None,
            None,
            None,
            Some("codex"),
            None,
        )
        .await
        .expect("mission");
    let job_id = Uuid::new_v4();
    let automation = Automation {
        id: Uuid::new_v4(),
        mission_id: mission.id,
        command_source: CommandSource::Inline {
            content: "inspect terminal job".into(),
        },
        trigger: TriggerType::DurableJobTerminal { job_id },
        variables: HashMap::new(),
        active: true,
        created_at: now_string(),
        last_triggered_at: None,
        retry_config: RetryConfig::default(),
        stop_policy: StopPolicy::AfterFirstFire,
        fresh_session: FreshSession::Keep,
        consecutive_failures: 0,
        driver: AutomationDriver::Scheduler,
    };

    store
        .create_automation(automation.clone())
        .await
        .expect("create automation");
    let loaded = store
        .get_automation(automation.id)
        .await
        .expect("load automation")
        .expect("automation exists");
    assert_eq!(loaded.trigger, TriggerType::DurableJobTerminal { job_id });
}

#[tokio::test]
async fn proxy_usage_records_and_aggregates() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");

    store
        .record_proxy_usage("gpt-oss-120b", 1_000, 200, 3)
        .await
        .expect("record 1");
    store
        .record_proxy_usage("gpt-oss-120b", 500, 100, 2)
        .await
        .expect("record 2");
    store
        .record_proxy_usage("zai-glm-4.7", 50, 10, 1)
        .await
        .expect("record 3");

    let by_model = store
        .get_proxy_usage_by_model(None)
        .await
        .expect("by model");
    assert_eq!(by_model.len(), 2);
    let gpt = by_model
        .iter()
        .find(|m| m.model == "gpt-oss-120b")
        .expect("gpt row");
    assert_eq!(gpt.requests, 2);
    assert_eq!(gpt.input_tokens, 1_500);
    assert_eq!(gpt.output_tokens, 300);
    assert_eq!(gpt.cost_cents, 5);

    // All three rows were written "now", so they share one day/hour bucket.
    let by_day = store.get_proxy_usage_by_day(None).await.expect("by day");
    assert_eq!(by_day.len(), 1);
    assert_eq!(by_day[0].requests, 3);
    assert_eq!(by_day[0].input_tokens, 1_550);
    assert_eq!(by_day[0].cost_cents, 6);

    let by_hour = store.get_proxy_usage_by_hour(None).await.expect("by hour");
    assert_eq!(by_hour.len(), 1);
    assert_eq!(by_hour[0].requests, 3);
    assert_eq!(by_hour[0].hour.len(), "2026-06-04T10".len());

    // A `since` in the future excludes everything.
    let future = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
    let filtered = store
        .get_proxy_usage_by_model(Some(&future))
        .await
        .expect("filtered");
    assert!(filtered.is_empty());
}

#[tokio::test]
async fn board_tasks_roundtrip() {
    use crate::api::mission_store::{
        BoardTaskOutcome, BoardTaskRole, BoardTaskStatus, NewBoardTask,
    };
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("store");

    let boss = store
        .create_mission(Some("boss"), None, None, None, None, None, None)
        .await
        .expect("boss mission");

    let new = |key: &str, deps: Vec<&str>| NewBoardTask {
        task_key: key.to_string(),
        title: format!("title-{key}"),
        prompt: format!("prompt-{key}"),
        backend: "codex".to_string(),
        model_override: Some("gpt-5.5".to_string()),
        model_effort: Some("high".to_string()),
        working_directory: Some("/workspaces/x/wt-1".to_string()),
        repository: Some("Th0rgal/sandboxed.sh".to_string()),
        branch: Some("agent/test".to_string()),
        role: BoardTaskRole::Reviewer,
        acceptance_criteria: vec!["tests pass".into()],
        verification_command: Some("cargo test".into()),
        design_domain: Some("mission-store".into()),
        declared_write_set: vec!["src/api/mission_store".into()],
        risk_class: "high".into(),
        token_budget: Some(10_000),
        cost_budget_cents: Some(250),
        depends_on: deps.into_iter().map(String::from).collect(),
    };

    let tasks = store
        .upsert_board_tasks(boss.id, vec![new("t1", vec![]), new("t2", vec!["t1"])])
        .await
        .expect("upsert");
    assert_eq!(tasks.len(), 2);
    assert_eq!(tasks[0].status, BoardTaskStatus::Pending);
    assert_eq!(tasks[1].depends_on, vec!["t1".to_string()]);
    assert_eq!(tasks[0].repository.as_deref(), Some("Th0rgal/sandboxed.sh"));
    assert_eq!(tasks[0].branch.as_deref(), Some("agent/test"));
    assert_eq!(tasks[0].role, BoardTaskRole::Reviewer);
    assert_eq!(tasks[0].acceptance_criteria, vec!["tests pass"]);
    assert_eq!(tasks[0].declared_write_set, vec!["src/api/mission_store"]);
    assert_eq!(tasks[0].token_budget, Some(10_000));

    // Active boards includes our boss.
    let active = store.list_active_board_missions().await.expect("active");
    assert_eq!(active, vec![boss.id]);

    // Bind t1 to a worker, settle it, look it up by worker.
    let worker = Uuid::new_v4();
    let mut t1 = tasks[0].clone();
    t1.worker_mission_id = Some(worker);
    t1.status = BoardTaskStatus::Running;
    t1.attempts = 1;
    store.save_board_task(&t1).await.expect("save running");

    let by_worker = store
        .get_board_task_by_worker(worker)
        .await
        .expect("by worker")
        .expect("found");
    assert_eq!(by_worker.task_key, "t1");

    let mut settled = by_worker;
    settled.status = BoardTaskStatus::Settled;
    settled.outcome = Some(BoardTaskOutcome::Success);
    settled.result_digest = Some("did the thing".to_string());
    store.save_board_task(&settled).await.expect("save settled");

    let listed = store.list_board_tasks(boss.id).await.expect("list");
    let t1 = listed.iter().find(|t| t.task_key == "t1").unwrap();
    assert_eq!(t1.status, BoardTaskStatus::Settled);
    assert_eq!(t1.outcome, Some(BoardTaskOutcome::Success));
    assert_eq!(t1.result_digest.as_deref(), Some("did the thing"));

    // Upserting an existing pending task updates it; settled stays.
    let updated = store
        .upsert_board_tasks(boss.id, vec![new("t2", vec![]), new("t1", vec![])])
        .await
        .expect("upsert again");
    let t2 = updated.iter().find(|t| t.task_key == "t2").unwrap();
    assert!(t2.depends_on.is_empty(), "pending task should be updated");
    let t1 = updated.iter().find(|t| t.task_key == "t1").unwrap();
    assert_eq!(
        t1.status,
        BoardTaskStatus::Settled,
        "settled task must not be reset by upsert"
    );

    // get_board_task by id.
    let fetched = store
        .get_board_task(t2.id)
        .await
        .expect("get")
        .expect("some");
    assert_eq!(fetched.task_key, "t2");
}

/// The roadmap read: tasks resolve to a project through their boss
/// mission's tag with family-prefix semantics, so `verity` sees the tasks
/// of a boss tagged `verity-core` — and `verity-x` never leaks into `ver`.
#[tokio::test]
async fn board_tasks_resolve_to_their_boss_missions_project_family() {
    use crate::api::mission_store::NewBoardTask;
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("store");

    let tag = |project: &str| MissionProjectPatch {
        preserve_updated_at: false,
        tag_patch: None,
        title: None,
        project: Some(Some(project.to_string())),
        track: None,
        intent: None,
        github_pr: None,
        tags: None,
        desired_state: None,
        next_check_at: None,
    };
    let task = |key: &str| NewBoardTask {
        task_key: key.to_string(),
        title: format!("title-{key}"),
        prompt: "p".to_string(),
        backend: "codex".to_string(),
        ..Default::default()
    };

    let core_boss = store
        .create_mission(Some("core boss"), None, None, None, None, None, None)
        .await
        .expect("boss");
    store
        .update_mission_project(core_boss.id, tag("verity-core"))
        .await
        .expect("tag core");
    store
        .upsert_board_tasks(core_boss.id, vec![task("c1"), task("c2")])
        .await
        .expect("core tasks");

    let exact_boss = store
        .create_mission(Some("exact boss"), None, None, None, None, None, None)
        .await
        .expect("boss");
    store
        .update_mission_project(exact_boss.id, tag("verity"))
        .await
        .expect("tag exact");
    store
        .upsert_board_tasks(exact_boss.id, vec![task("e1")])
        .await
        .expect("exact tasks");

    let other_boss = store
        .create_mission(Some("other boss"), None, None, None, None, None, None)
        .await
        .expect("boss");
    store
        .update_mission_project(other_boss.id, tag("lido"))
        .await
        .expect("tag other");
    store
        .upsert_board_tasks(other_boss.id, vec![task("o1")])
        .await
        .expect("other tasks");

    let verity = store
        .list_board_tasks_for_project("verity")
        .await
        .expect("verity tasks");
    let keys: Vec<&str> = verity.iter().map(|t| t.task_key.as_str()).collect();
    assert_eq!(verity.len(), 3, "family = exact + prefixed: {keys:?}");
    assert!(keys.contains(&"c1") && keys.contains(&"c2") && keys.contains(&"e1"));

    // `ver` is not a family of `verity` (prefix must break on '-').
    assert!(store
        .list_board_tasks_for_project("ver")
        .await
        .expect("ver")
        .is_empty());
    assert_eq!(
        store
            .list_board_tasks_for_project("lido")
            .await
            .expect("lido")
            .len(),
        1
    );

    // `_` is a literal, not a LIKE wildcard: `verity_x` must not match
    // the `verityXx-*` family (and vice versa).
    let odd_boss = store
        .create_mission(Some("odd boss"), None, None, None, None, None, None)
        .await
        .expect("boss");
    store
        .update_mission_project(odd_boss.id, tag("verityXx-core"))
        .await
        .expect("tag odd");
    store
        .upsert_board_tasks(odd_boss.id, vec![task("x1")])
        .await
        .expect("odd tasks");
    assert!(store
        .list_board_tasks_for_project("verity_x")
        .await
        .expect("underscore literal")
        .is_empty());
}

#[tokio::test]
async fn project_attempt_and_outbox_ledgers_are_idempotent() {
    use crate::api::mission_store::{BoardOutboxItem, BoardTaskRole, NewBoardTask, TaskAttempt};
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("store");
    let boss = store
        .create_mission(Some("boss"), None, None, None, None, None, None)
        .await
        .expect("boss");
    let task = store
        .upsert_board_tasks(
            boss.id,
            vec![NewBoardTask {
                task_key: "worker".into(),
                title: "worker".into(),
                prompt: "implement".into(),
                ..Default::default()
            }],
        )
        .await
        .expect("task")
        .remove(0);

    let attempt = TaskAttempt {
        id: Uuid::new_v4(),
        task_id: task.id,
        attempt_number: 1,
        mission_id: Uuid::new_v4(),
        backend: "codex".into(),
        model: Some("gpt-5.6-terra".into()),
        role: BoardTaskRole::Worker,
        run_id: None,
        commit_sha: None,
        changed_files: vec![],
        verification_evidence: serde_json::json!({}),
        cost_cents: None,
        terminal_class: None,
        started_at: now_string(),
        finished_at: None,
    };
    store
        .create_task_attempt(attempt.clone())
        .await
        .expect("attempt");
    store
        .create_task_attempt(attempt)
        .await
        .expect("idempotent attempt");
    store
        .finish_task_attempt(
            task.id,
            1,
            "success",
            Some("deadbeef"),
            &["src/lib.rs".into()],
            &serde_json::json!({"command": "cargo test", "passed": true}),
            Some(42),
        )
        .await
        .expect("finish");
    let attempts = store.list_task_attempts(task.id).await.expect("attempts");
    assert_eq!(attempts.len(), 1);
    assert_eq!(attempts[0].commit_sha.as_deref(), Some("deadbeef"));

    let delivery = BoardOutboxItem {
        id: Uuid::new_v4(),
        boss_mission_id: boss.id,
        task_id: Some(task.id),
        delivery_kind: "spawn".into(),
        idempotency_key: "beal:worker:1:spawn".into(),
        payload: serde_json::json!({"mission_id": attempts[0].mission_id}),
        state: "pending".into(),
        attempts: 0,
        created_at: now_string(),
        acknowledged_at: None,
    };
    store
        .enqueue_board_outbox(delivery.clone())
        .await
        .expect("enqueue");
    store
        .enqueue_board_outbox(delivery)
        .await
        .expect("idempotent enqueue");
    assert_eq!(store.list_pending_board_outbox(10).await.unwrap().len(), 1);
    store
        .acknowledge_board_outbox("beal:worker:1:spawn")
        .await
        .unwrap();
    assert!(store
        .list_pending_board_outbox(10)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn client_outbox_backlog_does_not_starve_server_deliveries() {
    use crate::api::mission_store::BoardOutboxItem;
    let temp = tempfile::tempdir().unwrap();
    let store = SqliteMissionStore::new(temp.path().to_path_buf(), "outbox-lanes")
        .await
        .unwrap();
    let boss = Uuid::new_v4();
    for index in 0..1001 {
        store
            .enqueue_board_outbox(BoardOutboxItem {
                id: Uuid::new_v4(),
                boss_mission_id: boss,
                task_id: None,
                delivery_kind: "client_message".into(),
                idempotency_key: format!("client:{index}"),
                payload: serde_json::json!({}),
                state: "pending".into(),
                attempts: 0,
                created_at: "2026-01-01T00:00:00Z".into(),
                acknowledged_at: None,
            })
            .await
            .unwrap();
    }
    store
        .enqueue_board_outbox(BoardOutboxItem {
            id: Uuid::new_v4(),
            boss_mission_id: boss,
            task_id: None,
            delivery_kind: "controller_notification".into(),
            idempotency_key: "server:wake".into(),
            payload: serde_json::json!({}),
            state: "pending".into(),
            attempts: 0,
            created_at: "2026-01-02T00:00:00Z".into(),
            acknowledged_at: None,
        })
        .await
        .unwrap();
    let server = store
        .list_pending_board_outbox_filtered(1000, Some(false))
        .await
        .unwrap();
    assert_eq!(server.len(), 1);
    assert_eq!(server[0].idempotency_key, "server:wake");
    let client = store
        .list_pending_board_outbox_filtered(1000, Some(true))
        .await
        .unwrap();
    assert_eq!(client.len(), 1000);
    assert!(client
        .iter()
        .all(|item| item.delivery_kind == "client_message"));
}

/// FLEET-001: deferred goals round-trip and the scheduled-pending query
/// surfaces only Pending missions that carry a goal, with scheduling fields
/// populated (verifies the SELECT column indices).
#[tokio::test]
async fn deferred_goal_and_scheduled_pending_round_trip() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Scheduled"), None, None, None, None, None, None)
        .await
        .expect("mission");
    store
        .set_mission_scheduling(
            mission.id,
            &crate::api::mission_store::MissionScheduling {
                priority: 7,
                not_before: Some("2099-01-01T00:00:00Z".to_string()),
                deadline: Some("2099-02-01T00:00:00Z".to_string()),
            },
        )
        .await
        .expect("set scheduling");

    // No goal yet -> not scheduled-pending.
    assert!(store
        .get_scheduled_pending_missions()
        .await
        .expect("list")
        .is_empty());

    store
        .set_deferred_goal(mission.id, Some("run the report".to_string()))
        .await
        .expect("set goal");
    assert_eq!(
        store
            .get_deferred_goal(mission.id)
            .await
            .expect("get")
            .as_deref(),
        Some("run the report")
    );

    let pending = store.get_scheduled_pending_missions().await.expect("list");
    assert_eq!(pending.len(), 1);
    let m = &pending[0];
    assert_eq!(m.id, mission.id);
    assert_eq!(m.scheduling.priority, 7);
    assert_eq!(
        m.scheduling.not_before.as_deref(),
        Some("2099-01-01T00:00:00Z")
    );
    assert_eq!(
        m.scheduling.deadline.as_deref(),
        Some("2099-02-01T00:00:00Z")
    );

    // Clearing the goal removes it from the scheduled-pending set.
    store
        .set_deferred_goal(mission.id, None)
        .await
        .expect("clear");
    assert!(store
        .get_deferred_goal(mission.id)
        .await
        .expect("get")
        .is_none());
    assert!(store
        .get_scheduled_pending_missions()
        .await
        .expect("list")
        .is_empty());
}

#[tokio::test]
async fn initial_user_message_is_not_lost_beyond_history_window() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "test-user")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("Long mission"), None, None, None, None, None, None)
        .await
        .expect("mission");
    for index in 0..206 {
        let content = if index == 0 {
            "Fix, commit and push the original PR".to_string()
        } else {
            format!("later message {index}")
        };
        store
            .log_event(
                mission.id,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content,
                    queued: false,
                    mission_id: Some(mission.id),
                    source: None,
                },
            )
            .await
            .expect("persist user event");
    }

    let projected = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(projected.history.len(), 200);
    assert_ne!(
        projected
            .history
            .first()
            .map(|entry| entry.content.as_str()),
        Some("Fix, commit and push the original PR")
    );
    assert_eq!(
        store
            .get_initial_user_message(mission.id)
            .await
            .expect("initial prompt")
            .as_deref(),
        Some("Fix, commit and push the original PR")
    );
}

#[tokio::test]
async fn updating_missing_mission_status_fails_closed() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "missing-status")
        .await
        .expect("sqlite store");

    let missing = Uuid::new_v4();
    let error = store
        .update_mission_status(missing, MissionStatus::Acknowledged)
        .await
        .expect_err("missing mission status update must not report success");
    assert!(error.contains("not found"), "unexpected error: {error}");
}

#[tokio::test]
async fn mission_run_generations_exclude_ack_and_ignore_late_updates() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "run-test")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("leased"), None, None, None, None, None, None)
        .await
        .expect("mission");
    store
        .update_mission_status(mission.id, MissionStatus::AwaitingUser)
        .await
        .unwrap();

    assert!(store
        .begin_mission_run(mission.id, "actor-a", Some("mission-a.scope"))
        .await
        .unwrap_err()
        .contains("activate it before acquiring"));
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();

    let first = store
        .begin_mission_run(mission.id, "actor-a", Some("mission-a.scope"))
        .await
        .expect("first generation");
    assert_eq!(first.generation, 1);
    assert!(store
        .begin_mission_run(mission.id, "actor-b", None)
        .await
        .unwrap_err()
        .contains("already has non-terminal run"));
    assert!(store
        .update_mission_status(mission.id, MissionStatus::Acknowledged)
        .await
        .unwrap_err()
        .contains("cannot be acknowledged"));

    assert!(store
        .finish_mission_run(first.run_id, first.generation, Some("settled"))
        .await
        .unwrap());
    store
        .update_mission_status(mission.id, MissionStatus::Acknowledged)
        .await
        .unwrap();
    assert!(store
        .begin_mission_run(mission.id, "actor-b", None)
        .await
        .unwrap_err()
        .contains("acknowledged mission"));
    store
        .update_mission_status(mission.id, MissionStatus::Interrupted)
        .await
        .unwrap();
    assert!(store
        .begin_mission_run(mission.id, "actor-b", None)
        .await
        .unwrap_err()
        .contains("activate it before acquiring"));
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();
    let second = store
        .begin_mission_run(mission.id, "actor-b", None)
        .await
        .expect("second generation");
    assert_eq!(second.generation, 2);
    assert!(!store
        .heartbeat_mission_run(
            first.run_id,
            first.generation,
            MissionExecutionState::Running,
            None,
        )
        .await
        .unwrap());
    assert_eq!(
        store
            .get_active_mission_run(mission.id)
            .await
            .unwrap()
            .unwrap()
            .run_id,
        second.run_id
    );
}

#[tokio::test]
async fn registered_tool_execution_is_scoped_to_its_run() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let store = SqliteMissionStore::new(temp_dir.path().to_path_buf(), "tool-test")
        .await
        .expect("sqlite store");
    let mission = store
        .create_mission(Some("tool"), None, None, None, None, None, None)
        .await
        .unwrap();
    let run = store
        .begin_mission_run(mission.id, "actor", None)
        .await
        .unwrap();
    let now = chrono::Utc::now();
    let tool = MissionToolExecution {
        tool_call_id: "call-1".to_string(),
        run_id: run.run_id,
        tool_kind: "Bash".to_string(),
        state: MissionToolExecutionState::Provisional,
        started_at: now.to_rfc3339(),
        heartbeat_at: now.to_rfc3339(),
        deadline_at: (now + chrono::Duration::seconds(120)).to_rfc3339(),
        process_pid: None,
        durable_job_id: None,
        completed_at: None,
        exit_status: None,
        failure_class: None,
    };
    store.register_tool_execution(&tool).await.unwrap();
    assert_eq!(
        store
            .list_active_tool_executions(run.run_id)
            .await
            .unwrap()
            .len(),
        1
    );
    assert!(store
        .finish_tool_execution(
            run.run_id,
            "call-1",
            MissionToolExecutionState::Completed,
            Some(0),
            None,
        )
        .await
        .unwrap());
    assert!(store
        .list_active_tool_executions(run.run_id)
        .await
        .unwrap()
        .is_empty());
}
