use super::*;

async fn mk(store: &Arc<dyn MissionStore>, parent: Option<Uuid>) -> Uuid {
    store
        .create_mission_with_parent(
            Some("m"),
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
        .id
}

#[tokio::test]
async fn leaf_mission_is_never_guarded() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let leaf = mk(&store, None).await;
    // No children → never armed, regardless of how many times it parks.
    for _ in 0..5 {
        assert!(!maybe_arm_stall_guard_wakeup(&store, leaf).await);
    }
}

#[tokio::test]
async fn orchestrator_arms_then_caps_then_resets() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let boss = mk(&store, None).await;
    let _child = mk(&store, Some(boss)).await; // makes `boss` an orchestrator
    reset_stall_guard(boss);
    // Arms up to the cap, then stops (leaves it for a human).
    for _ in 0..STALL_GUARD_MAX_CONSECUTIVE_ARMS {
        assert!(maybe_arm_stall_guard_wakeup(&store, boss).await);
    }
    assert!(!maybe_arm_stall_guard_wakeup(&store, boss).await); // capped
                                                                // A real user message resets the budget.
    reset_stall_guard(boss);
    assert!(maybe_arm_stall_guard_wakeup(&store, boss).await);
    reset_stall_guard(boss);
}

#[test]
fn project_patches_only_arbitrate_the_writer_lease_when_they_could_change_it() {
    let parse = |json: &str| -> UpdateMissionProjectRequest {
        serde_json::from_str(json).expect("valid patch")
    };

    // Retagging metadata cannot make a mission a writer, so it must not be
    // gated on someone else's lease.
    assert!(!patch_can_change_writer_status(
        &parse(r#"{"project":"verity","track":"phase1d/core-c3"}"#),
        &[],
    ));
    assert!(!patch_can_change_writer_status(&parse(r#"{}"#), &[]));
    assert!(!patch_can_change_writer_status(
        &parse(r#"{"desired_state":"green","next_check_at":"2026-08-05T00:00:00Z"}"#),
        &[],
    ));
    assert!(!patch_can_change_writer_status(
        &parse(r#"{"project":"verity","tags":["orb-folder:audits"]}"#),
        &[],
    ));
    assert!(!patch_can_change_writer_status(
        &parse(r#"{"tags":["pr-writer","orb-folder:new"]}"#),
        &["pr-writer".into(), "orb-folder:old".into()],
    ));

    // Anything `becomes_writer` is derived from still arbitrates.
    assert!(patch_can_change_writer_status(
        &parse(r#"{"github_pr":"https://github.com/o/r/pull/1"}"#),
        &[],
    ));
    assert!(patch_can_change_writer_status(
        &parse(r#"{"writer":true}"#),
        &[]
    ));
    assert!(patch_can_change_writer_status(
        &parse(r#"{"writer":false}"#),
        &[],
    ));
    assert!(patch_can_change_writer_status(
        &parse(r#"{"intent":"implementation"}"#),
        &[],
    ));
    assert!(patch_can_change_writer_status(
        &parse(r#"{"tags":["pr-writer"]}"#),
        &[],
    ));

    // An explicit null is a clear, not an absence: dropping the PR or the
    // intent changes writer status just as much as setting one.
    assert!(patch_can_change_writer_status(
        &parse(r#"{"github_pr":null}"#),
        &[],
    ));
    assert!(patch_can_change_writer_status(
        &parse(r#"{"intent":null}"#),
        &[],
    ));

    // A patch that mixes both still arbitrates.
    assert!(patch_can_change_writer_status(
        &parse(r#"{"project":"verity","writer":true}"#),
        &[],
    ));
}

#[tokio::test]
async fn delete_rejects_paused_mission_until_resumed_or_cancelled() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mid = mk(&store, None).await;
    store
        .update_mission_status(mid, MissionStatus::Paused)
        .await
        .expect("pause");

    // Deleting a paused mission is refused with 409 and leaves it intact.
    let err = delete_mission_with_children(&store, mid, &[])
        .await
        .expect_err("paused delete should be refused");
    assert_eq!(err.0, StatusCode::CONFLICT);
    assert!(store.get_mission(mid).await.expect("get").is_some());

    // Once it leaves Paused (e.g. resumed → Interrupted), delete succeeds.
    store
        .update_mission_status(mid, MissionStatus::Interrupted)
        .await
        .expect("resume");
    delete_mission_with_children(&store, mid, &[])
        .await
        .expect("delete after resume");
    assert!(store.get_mission(mid).await.expect("get").is_none());
}

#[test]
fn resolve_actor_prefers_explicit_then_falls_back_to_user() {
    let user = AuthUser {
        id: "u-123".to_string(),
        username: "thomas".to_string(),
    };
    // Explicit override wins (trimmed).
    assert_eq!(
        resolve_actor(Some("  system:fleet-watcher ".to_string()), &user),
        "system:fleet-watcher"
    );
    // Blank override is ignored → falls back to the user.
    assert_eq!(resolve_actor(Some("   ".to_string()), &user), "user:thomas");
    assert_eq!(resolve_actor(None, &user), "user:thomas");
    // No username → fall back to the id.
    let anon = AuthUser {
        id: "u-123".to_string(),
        username: String::new(),
    };
    assert_eq!(resolve_actor(None, &anon), "user:u-123");
}
