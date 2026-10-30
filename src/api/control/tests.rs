#[test]
fn a_settings_handoff_resumes_only_dead_missions() {
    use super::{should_queue_resume, MissionStatus};
    assert!(should_queue_resume(MissionStatus::Failed, None));
    assert!(should_queue_resume(MissionStatus::Interrupted, Some(true)));
    assert!(!should_queue_resume(MissionStatus::Failed, Some(false)));
    assert!(!should_queue_resume(MissionStatus::Active, None));
    assert!(!should_queue_resume(MissionStatus::Paused, None));
    assert!(!should_queue_resume(MissionStatus::Acknowledged, None));
    assert!(!should_queue_resume(MissionStatus::Completed, None));
}

#[test]
fn registered_liveness_interrupt_skips_hermes_tagged_writer() {
    assert!(super::skip_idle_registered_liveness_interrupt(
        None,
        None,
        &["origin:hermes-assistant".to_string()],
    ));
    assert!(!super::skip_idle_registered_liveness_interrupt(
        None,
        None,
        &[],
    ));
}

mod fabricated_origin {
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// The measured incident: "20260805_night_supervision" — valid in
    /// shape, existing nowhere.
    #[test]
    fn an_unconfigured_state_db_means_could_not_check() {
        // Serialised via a scoped env var: no HERMES_STATE_DB → None,
        // never Some(false) — stripping attribution on deployments
        // without the database would be the larger harm.
        let _guard = ENV_LOCK.lock().unwrap();
        let previous = std::env::var("HERMES_STATE_DB").ok();
        std::env::remove_var("HERMES_STATE_DB");
        assert_eq!(super::super::hermes_session_exists("any"), None);
        if let Some(value) = previous {
            std::env::set_var("HERMES_STATE_DB", value);
        }
    }

    #[test]
    fn a_real_db_answers_true_and_false() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = tempfile::tempdir().expect("tmp");
        let path = dir.path().join("state.db");
        let connection = rusqlite::Connection::open(&path).expect("open");
        connection
            .execute("CREATE TABLE sessions (id TEXT PRIMARY KEY)", [])
            .expect("schema");
        connection
            .execute(
                "INSERT INTO sessions (id) VALUES ('20260805_093524_88112a')",
                [],
            )
            .expect("insert");
        drop(connection);
        let previous = std::env::var("HERMES_STATE_DB").ok();
        std::env::set_var("HERMES_STATE_DB", &path);

        assert_eq!(
            super::super::hermes_session_exists("20260805_093524_88112a"),
            Some(true)
        );
        assert_eq!(
            super::super::hermes_session_exists("20260805_night_supervision"),
            Some(false)
        );

        match previous {
            Some(value) => std::env::set_var("HERMES_STATE_DB", value),
            None => std::env::remove_var("HERMES_STATE_DB"),
        }
    }
}

mod create_idempotency {
    use crate::api::control::MissionStatus;
    use crate::api::mission_store::{InMemoryMissionStore, Mission, MissionStore};
    use std::sync::Arc;

    async fn store_with(
        title: &str,
        origin: Option<&str>,
        status: MissionStatus,
    ) -> (Arc<dyn MissionStore>, Mission) {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let mission = store
            .create_mission(Some(title), None, None, None, None, None, None)
            .await
            .expect("create");
        if let Some(origin) = origin {
            store
                .set_mission_origin(mission.id, "hermes", Some(origin))
                .await
                .expect("origin");
        }
        store
            .update_mission_status(mission.id, status)
            .await
            .expect("status");
        (store, mission)
    }

    /// The measured incident: `fix(ci)` created twice 30 seconds apart,
    /// same (absent) origin, first copy still working.
    #[tokio::test]
    async fn a_retry_shaped_duplicate_coalesces() {
        let (store, first) = store_with(
            "fix(ci): mechanical Lean warning cleanup",
            None,
            MissionStatus::Active,
        )
        .await;
        let found = super::super::find_recent_identical_mission(
            &store,
            "fix(ci): mechanical Lean warning cleanup",
            None,
        )
        .await;
        assert_eq!(found.map(|m| m.id), Some(first.id));
    }

    #[tokio::test]
    async fn a_different_title_does_not_coalesce() {
        let (store, _) = store_with("lane A", None, MissionStatus::Active).await;
        assert!(
            super::super::find_recent_identical_mission(&store, "lane B", None)
                .await
                .is_none()
        );
    }

    /// Same title from a DIFFERENT conversation is parallel work, not a
    /// retry — two controllers may legitimately race the same lane name.
    #[tokio::test]
    async fn a_different_origin_does_not_coalesce() {
        let (store, _) = store_with(
            "lane A",
            Some("20260805_093524_88112a"),
            MissionStatus::Active,
        )
        .await;
        assert!(super::super::find_recent_identical_mission(
            &store,
            "lane A",
            Some("20260805_152329_6058d9"),
        )
        .await
        .is_none());
    }

    #[tokio::test]
    async fn a_matching_origin_coalesces() {
        let (store, first) = store_with(
            "lane A",
            Some("20260805_093524_88112a"),
            MissionStatus::Active,
        )
        .await;
        let found = super::super::find_recent_identical_mission(
            &store,
            "lane A",
            Some("20260805_093524_88112a"),
        )
        .await;
        assert_eq!(found.map(|m| m.id), Some(first.id));
    }

    /// Re-dispatching a lane whose previous run finished, failed, or is
    /// merely PARKED is intent, not a retry artifact. `Acknowledged` and
    /// `AwaitingUser` are non-terminal but will not run again on their
    /// own — coalescing onto them would swallow the new dispatch.
    #[tokio::test]
    async fn a_settled_or_parked_mission_does_not_coalesce() {
        for status in [
            MissionStatus::Completed,
            MissionStatus::Failed,
            MissionStatus::Interrupted,
            MissionStatus::Acknowledged,
            MissionStatus::AwaitingUser,
        ] {
            let (store, _) = store_with("lane A", None, status).await;
            assert!(
                super::super::find_recent_identical_mission(&store, "lane A", None)
                    .await
                    .is_none(),
                "a {status:?} mission must not absorb a new create"
            );
        }
    }

    #[tokio::test]
    async fn whitespace_variants_of_the_title_still_match() {
        let (store, first) = store_with("lane A", None, MissionStatus::Active).await;
        let found = super::super::find_recent_identical_mission(&store, "  lane A  ", None).await;
        assert_eq!(found.map(|m| m.id), Some(first.id));
    }

    #[tokio::test]
    async fn an_empty_title_never_coalesces() {
        let (store, _) = store_with("lane A", None, MissionStatus::Active).await;
        assert!(
            super::super::find_recent_identical_mission(&store, "   ", None)
                .await
                .is_none()
        );
    }
}

#[test]
fn goal_completion_disarms_and_suspension_never_rearms() {
    // 1. Completion ends the loop: no resume path may rebuild `/goal`.
    for status in [
        "complete",
        "cleared",
        "budget_limited",
        "aborted",
        "aborted:cancelled",
    ] {
        assert_eq!(goal_mode_after_status(status), Some(false), "{status}");
    }
    assert_eq!(goal_mode_after_status("active"), Some(true));
    // 2./3. The trailing `paused` of a stopped turn (or a plain reply's
    // turn) leaves the state untouched, so a Stop's disarm survives.
    for status in ["paused", "blocked", "usageLimited", "budgetLimited"] {
        assert_eq!(goal_mode_after_status(status), None, "{status}");
    }
}

#[tokio::test]
async fn user_stop_disarms_goal_and_grok_goal_automation() {
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(
        mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "goal-stop-test")
            .await
            .unwrap(),
    );
    let (events_tx, mut events_rx) = broadcast::channel(16);
    let mission = store
        .create_mission(Some("goal"), None, None, None, None, Some("grok"), None)
        .await
        .unwrap();
    store
        .update_mission_goal(mission.id, true, Some("ship it"))
        .await
        .unwrap();
    super::super::grok_goal::create_goal_automation(&store, mission.id, "ship it")
        .await
        .unwrap();

    disarm_goal_on_user_stop(&store, &events_tx, mission.id)
        .await
        .unwrap();

    let after = store.get_mission(mission.id).await.unwrap().unwrap();
    assert!(!after.goal_mode, "Stop must disarm automatic goal resumes");
    assert_eq!(after.goal_objective.as_deref(), Some("ship it"));
    assert!(
        super::super::grok_goal::active_goal_for_mission(&store, mission.id)
            .await
            .is_none(),
        "the AgentFinished continuation must not fire after Stop"
    );
    assert!(matches!(
        events_rx.try_recv(),
        Ok(AgentEvent::GoalStatus { status, .. }) if status == "aborted:cancelled"
    ));
    // The cancelled turn's trailing `paused` does not re-arm it.
    assert_eq!(goal_mode_after_status("paused"), None);
    // A Stop with no goal is a no-op.
    disarm_goal_on_user_stop(&store, &events_tx, mission.id)
        .await
        .unwrap();
    assert!(events_rx.try_recv().is_err());
}

#[test]
fn parse_goal_objective_tolerates_whitespace_variants() {
    assert_eq!(
        parse_goal_objective("/goal write the docs").as_deref(),
        Some("write the docs")
    );
    assert_eq!(
        parse_goal_objective("/goal\nMulti-line objective\nwith details").as_deref(),
        Some("Multi-line objective\nwith details")
    );
    assert_eq!(
        parse_goal_objective("  /goal   spaced   ").as_deref(),
        Some("spaced")
    );
    assert!(parse_goal_objective("/goal").is_none());
    assert!(parse_goal_objective("/goal   ").is_none());
    assert!(parse_goal_objective("/goals are nice").is_none());
    assert!(parse_goal_objective("plain message").is_none());
}

#[test]
fn canonical_goal_message_normalises_to_space_form() {
    // Backend goal drivers only recognise "/goal <objective>"; every
    // whitespace variant must canonicalise to that form.
    assert_eq!(
        canonical_goal_message("/goal ship it").as_deref(),
        Some("/goal ship it")
    );
    assert_eq!(
        canonical_goal_message("/goal\nMulti-line objective\nwith details").as_deref(),
        Some("/goal Multi-line objective\nwith details")
    );
    assert!(canonical_goal_message("/goals are nice").is_none());
    assert!(canonical_goal_message("plain message").is_none());
}

#[test]
fn awaiting_writer_lease_grace_policy() {
    use super::awaiting_pr_writer_lease_expired;
    // Fresh AwaitingUser writers keep their lease.
    let fresh = chrono::Utc::now().to_rfc3339();
    assert!(!awaiting_pr_writer_lease_expired(&fresh));
    // A writer idle far past the grace window releases it.
    let stale = (chrono::Utc::now() - chrono::Duration::hours(13)).to_rfc3339();
    assert!(awaiting_pr_writer_lease_expired(&stale));
    // Unparseable timestamps fail closed on exclusivity (lease held).
    assert!(!awaiting_pr_writer_lease_expired("not-a-timestamp"));
    assert!(!awaiting_pr_writer_lease_expired(""));
}

use super::*;
use crate::api::mission_store::{MissionMode, MissionProjectPatch};
use std::sync::Arc;

static METADATA_REFRESH_TEST_LOCK: std::sync::LazyLock<tokio::sync::Mutex<()>> =
    std::sync::LazyLock::new(|| tokio::sync::Mutex::new(()));

async fn metadata_refresh_test_guard() -> tokio::sync::MutexGuard<'static, ()> {
    let guard = METADATA_REFRESH_TEST_LOCK.lock().await;
    reset_metadata_refresh_test_state();
    guard
}

#[test]
fn disk_estimate_preserves_emergency_free_space() {
    let usage = crate::api::monitoring::DiskUsage {
        measured_path: "/srv/sandboxed-storage".into(),
        filesystem: "statvfs:test".to_string(),
        used: 0,
        total: 100 << 30,
        available: 100 << 30,
    };
    assert!(disk_estimate_refusal(&usage, 20, 64).is_none());
    // Equality is admitted: the emergency reserve remains exactly intact.
    let exact = crate::api::monitoring::DiskUsage {
        available: 84 << 30,
        total: 84 << 30,
        ..usage.clone()
    };
    assert!(disk_estimate_refusal(&exact, 20, 64).is_none());
    let low = crate::api::monitoring::DiskUsage {
        available: 80 << 30,
        total: 80 << 30,
        ..usage
    };
    let refusal = disk_estimate_refusal(&low, 20, 64).unwrap();
    assert!(refusal.contains("20 GiB scratch"));
    assert!(refusal.contains("64 GiB"));
    assert!(refusal.contains("80 GiB is free"));
    assert!(refusal.contains("/srv/sandboxed-storage"));
}

#[test]
fn mission_heartbeat_preserves_registered_user_waits() {
    assert!(is_user_wait_tool("request_user_input"));
    assert!(is_user_wait_tool("AskUserQuestion"));
    assert!(is_user_wait_tool("frontend_tool"));
    assert!(is_user_wait_tool("question"));
    assert!(is_user_wait_tool("ui_confirm"));
    assert!(!is_user_wait_tool("workspace_bash"));
    assert_eq!(
        mission_heartbeat_state(1, true, false),
        MissionExecutionState::WaitingUser
    );
    assert_eq!(
        mission_heartbeat_state(1, false, false),
        MissionExecutionState::WaitingTool
    );
    assert_eq!(
        mission_heartbeat_state(0, false, false),
        MissionExecutionState::Running
    );
    assert_eq!(
        mission_heartbeat_state(1, false, true),
        MissionExecutionState::WaitingRemoteJob
    );
}

#[tokio::test]
async fn remote_terminal_wake_detects_live_actor_ownership() {
    let mission_id = Uuid::new_v4();
    let run_id = Uuid::new_v4();
    let (cmd_tx, mut cmd_rx) = mpsc::channel(1);
    tokio::spawn(async move {
        let Some(ControlCommand::GetActorRunLease {
            mission_id: requested_mission_id,
            respond,
        }) = cmd_rx.recv().await
        else {
            panic!("expected GetActorRunLease query");
        };
        assert_eq!(requested_mission_id, mission_id);
        let _ = respond.send(Some((run_id, 7)));
    });

    assert_eq!(
        control_actor_mission_run(&cmd_tx, mission_id)
            .await
            .unwrap(),
        Some((run_id, 7))
    );
}

#[tokio::test]
async fn remote_terminal_wake_does_not_confuse_another_actor() {
    let target_mission_id = Uuid::new_v4();
    let (cmd_tx, mut cmd_rx) = mpsc::channel(1);
    tokio::spawn(async move {
        let Some(ControlCommand::GetActorRunLease {
            mission_id: requested_mission_id,
            respond,
        }) = cmd_rx.recv().await
        else {
            panic!("expected GetActorRunLease query");
        };
        assert_eq!(requested_mission_id, target_mission_id);
        let _ = respond.send(None);
    });

    assert!(control_actor_mission_run(&cmd_tx, target_mission_id)
        .await
        .unwrap()
        .is_none());
}

#[tokio::test]
async fn cancelling_a_detached_wait_closes_its_run_lease() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("detached wait"), None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();
    let run = store
        .begin_mission_run(mission.id, "remote-build:test", None)
        .await
        .unwrap();
    store
        .heartbeat_mission_run(
            run.run_id,
            run.generation,
            MissionExecutionState::WaitingRemoteJob,
            None,
        )
        .await
        .unwrap();
    store
        .update_mission_status(mission.id, MissionStatus::Interrupted)
        .await
        .unwrap();

    assert!(finish_detached_run_for_cancel(&store, mission.id)
        .await
        .unwrap());
    assert!(store
        .get_active_mission_run(mission.id)
        .await
        .unwrap()
        .is_none());
    assert!(!finish_detached_run_for_cancel(&store, mission.id)
        .await
        .unwrap());
}

#[test]
fn remote_terminal_wake_closes_parked_parallel_lease() {
    let mission_id = Uuid::new_v4();
    let run_id = Uuid::new_v4();

    assert_eq!(
        select_actor_run_lease(mission_id, false, None, None, false, Some((run_id, 9)),),
        None,
        "a parked parallel runner retains its lease but owns no process"
    );
    assert_eq!(
        select_actor_run_lease(mission_id, false, None, None, true, Some((run_id, 9)),),
        Some((run_id, 9))
    );
}

#[test]
fn remote_terminal_wake_repairs_an_unparked_orphan_only() {
    assert!(terminal_wake_must_wait_for_harness(
        MissionExecutionState::Running,
        true
    ));
    assert!(!terminal_wake_must_wait_for_harness(
        MissionExecutionState::Running,
        false
    ));
    assert!(!terminal_wake_must_wait_for_harness(
        MissionExecutionState::WaitingRemoteJob,
        true
    ));
}

#[test]
fn only_fresh_accepted_remote_builds_prove_liveness() {
    let now = chrono::Utc::now();
    let mut handle = crate::remote_node::job_ledger::JobHandle {
        mission_id: Uuid::new_v4(),
        node_id: "node-a".to_string(),
        job_id: Uuid::new_v4(),
        started_at: now - chrono::Duration::seconds(120),
        submission_sequence: 0,
        accepted_at: Some(now - chrono::Duration::seconds(30)),
        heartbeat_at: None,
        disk_reservation_bytes: 0,
        kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
        identity: None,
        wait_for_completion: Some(true),
        wake_on_terminal: false,
    };
    assert!(remote_build_handle_proves_liveness(&handle, now));
    handle.heartbeat_at = Some(now - chrono::Duration::seconds(61));
    assert!(!remote_build_handle_proves_liveness(&handle, now));
    handle.heartbeat_at = Some(now - chrono::Duration::seconds(1));
    assert!(remote_build_handle_proves_liveness(&handle, now));
    handle.kind = crate::remote_node::job_ledger::JobHandleKind::Mission;
    assert!(!remote_build_handle_proves_liveness(&handle, now));
    handle.kind = crate::remote_node::job_ledger::JobHandleKind::RemoteBuild;
    handle.wait_for_completion = Some(false);
    assert!(!remote_build_handle_proves_liveness(&handle, now));
}

#[tokio::test]
async fn unresolved_remote_build_parks_a_turn_even_with_a_stale_heartbeat() {
    let dir = tempfile::tempdir().unwrap();
    let mission_id = Uuid::new_v4();
    crate::remote_node::job_ledger::record(
        dir.path(),
        crate::remote_node::job_ledger::JobHandle {
            mission_id,
            node_id: "node-a".to_string(),
            job_id: Uuid::new_v4(),
            started_at: chrono::Utc::now() - chrono::Duration::minutes(5),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now() - chrono::Duration::minutes(5)),
            heartbeat_at: Some(chrono::Utc::now() - chrono::Duration::minutes(2)),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
            identity: None,
            wait_for_completion: None,
            wake_on_terminal: true,
        },
    )
    .await
    .unwrap();

    assert!(mission_has_unresolved_remote_build(dir.path(), mission_id).await);
    assert!(!mission_has_unresolved_remote_build(dir.path(), Uuid::new_v4()).await);

    let synchronous_mission_id = Uuid::new_v4();
    let synchronous_job_id = Uuid::new_v4();
    crate::remote_node::job_ledger::record(
        dir.path(),
        crate::remote_node::job_ledger::JobHandle {
            mission_id: synchronous_mission_id,
            node_id: "node-sync".to_string(),
            job_id: synchronous_job_id,
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
            identity: None,
            wait_for_completion: Some(true),
            wake_on_terminal: false,
        },
    )
    .await
    .unwrap();
    assert!(
        mission_has_unresolved_remote_build(dir.path(), synchronous_mission_id).await,
        "a synchronous waiter must keep its mission continuation recoverable"
    );
    crate::remote_node::job_ledger::require_terminal_wake(
        dir.path(),
        synchronous_job_id,
        synchronous_mission_id,
    )
    .await
    .unwrap();
    assert!(mission_has_unresolved_remote_build(dir.path(), synchronous_mission_id).await);

    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("remote wait"), None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();
    let run = store
        .begin_mission_run(mission.id, "test", None)
        .await
        .unwrap();
    crate::remote_node::job_ledger::record(
        dir.path(),
        crate::remote_node::job_ledger::JobHandle {
            mission_id: mission.id,
            node_id: "node-b".to_string(),
            job_id: Uuid::new_v4(),
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
            identity: None,
            wait_for_completion: None,
            wake_on_terminal: true,
        },
    )
    .await
    .unwrap();
    assert!(
        mission_should_park_on_remote_build(&store, dir.path(), mission.id)
            .await
            .is_some()
    );
    store
        .heartbeat_mission_run(
            run.run_id,
            run.generation,
            MissionExecutionState::Stopping,
            None,
        )
        .await
        .unwrap();
    assert!(
        mission_should_park_on_remote_build(&store, dir.path(), mission.id)
            .await
            .is_none()
    );
}

#[tokio::test]
async fn actor_startup_preserves_accepted_remote_harnesses() {
    use crate::remote_node::job_ledger::{self, JobHandle, JobHandleKind};
    let dir = tempfile::tempdir().unwrap();
    for (kind, accepted, preserve) in [
        (JobHandleKind::Mission, true, true),
        (JobHandleKind::Mission, false, false),
        (JobHandleKind::Tentative, true, false),
    ] {
        let mission_id = Uuid::new_v4();
        let job_id = Uuid::new_v4();
        job_ledger::record(
            dir.path(),
            JobHandle {
                mission_id,
                job_id,
                node_id: "old-agent".into(),
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: accepted.then(chrono::Utc::now),
                heartbeat_at: None,
                disk_reservation_bytes: 0,
                kind,
                identity: None,
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();
        assert_eq!(
            recoverable_inherited_remote_wait(
                dir.path(),
                mission_id,
                MissionExecutionState::WaitingRemoteJob,
                MissionStatus::Active
            )
            .await
            .unwrap(),
            preserve.then_some(job_id)
        );
        assert_eq!(
            recoverable_inherited_remote_wait(
                dir.path(),
                mission_id,
                MissionExecutionState::WaitingRemoteJob,
                MissionStatus::Interrupted
            )
            .await
            .unwrap(),
            None
        );
    }
}

#[tokio::test]
async fn actor_startup_preserves_only_ledger_backed_remote_waits() {
    let dir = tempfile::tempdir().unwrap();
    let mission_id = Uuid::new_v4();
    let job_id = Uuid::new_v4();
    crate::remote_node::job_ledger::record(
        dir.path(),
        crate::remote_node::job_ledger::JobHandle {
            mission_id,
            node_id: "node-a".to_string(),
            job_id,
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
            identity: Some(crate::remote_node::job_ledger::RemoteJobIdentity {
                version: 0,
                base_tree_sha: None,
                builder_image_digest: None,
                build_protocol_version: None,
                behavior_env_digest: None,
                repository: "https://example.invalid/repo.git".to_string(),
                commit: "abc123".to_string(),
                cwd_rel_known: true,
                cwd_rel: None,
                command: vec!["lake".to_string(), "build".to_string()],
                artifacts: Vec::new(),
                toolchain: Some("leanprover/lean4:v4.24.0".to_string()),
                source_bundle_digest: None,
            }),
            wait_for_completion: Some(true),
            wake_on_terminal: true,
        },
    )
    .await
    .unwrap();

    assert_eq!(
        recoverable_inherited_remote_wait(
            dir.path(),
            mission_id,
            MissionExecutionState::WaitingRemoteJob,
            MissionStatus::Active,
        )
        .await
        .unwrap(),
        Some(job_id)
    );
    assert_eq!(
        recoverable_inherited_remote_wait(
            dir.path(),
            mission_id,
            MissionExecutionState::Running,
            MissionStatus::Active,
        )
        .await
        .unwrap(),
        None
    );
    assert_eq!(
        recoverable_inherited_remote_wait(
            dir.path(),
            Uuid::new_v4(),
            MissionExecutionState::WaitingRemoteJob,
            MissionStatus::Active,
        )
        .await
        .unwrap(),
        None
    );
    assert_eq!(
        recoverable_inherited_remote_wait(
            dir.path(),
            mission_id,
            MissionExecutionState::WaitingRemoteJob,
            MissionStatus::Paused,
        )
        .await
        .unwrap(),
        None,
        "an operator-paused mission must not be resurrected on restart"
    );

    let fire_and_forget_mission_id = Uuid::new_v4();
    crate::remote_node::job_ledger::record(
        dir.path(),
        crate::remote_node::job_ledger::JobHandle {
            mission_id: fire_and_forget_mission_id,
            node_id: "node-b".to_string(),
            job_id: Uuid::new_v4(),
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
            identity: None,
            wait_for_completion: Some(false),
            wake_on_terminal: false,
        },
    )
    .await
    .unwrap();
    assert_eq!(
        recoverable_inherited_remote_wait(
            dir.path(),
            fire_and_forget_mission_id,
            MissionExecutionState::WaitingRemoteJob,
            MissionStatus::Active,
        )
        .await
        .unwrap(),
        None,
        "fire-and-forget jobs must not arm a continuation after restart"
    );

    let finalized_sync_mission_id = Uuid::new_v4();
    let finalized_sync_job_id = Uuid::new_v4();
    crate::remote_node::job_ledger::record(
        dir.path(),
        crate::remote_node::job_ledger::JobHandle {
            mission_id: finalized_sync_mission_id,
            node_id: "node-c".to_string(),
            job_id: finalized_sync_job_id,
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
            identity: Some(crate::remote_node::job_ledger::RemoteJobIdentity {
                version: 0,
                base_tree_sha: None,
                builder_image_digest: None,
                build_protocol_version: None,
                behavior_env_digest: None,
                repository: "https://example.invalid/repo.git".to_string(),
                commit: "def456".to_string(),
                cwd_rel_known: true,
                cwd_rel: None,
                command: vec!["lake".to_string(), "build".to_string()],
                artifacts: Vec::new(),
                toolchain: Some("leanprover/lean4:v4.24.0".to_string()),
                source_bundle_digest: None,
            }),
            wait_for_completion: Some(true),
            wake_on_terminal: false,
        },
    )
    .await
    .unwrap();
    assert!(crate::remote_node::job_ledger::finalize(
        dir.path(),
        finalized_sync_job_id,
        "succeeded",
        Some(0),
    )
    .await
    .unwrap());
    assert!(
        crate::remote_node::job_ledger::pending_terminal_wakes(dir.path())
            .await
            .unwrap()
            .iter()
            .all(|receipt| receipt.job_id != finalized_sync_job_id),
        "normal synchronous completion must not race its HTTP result with a wake"
    );
    assert_eq!(
        recoverable_inherited_remote_wait(
            dir.path(),
            finalized_sync_mission_id,
            MissionExecutionState::WaitingRemoteJob,
            MissionStatus::Active,
        )
        .await
        .unwrap(),
        Some(finalized_sync_job_id),
        "startup must arm a terminal receipt when the synchronous wait lease survived"
    );
    assert!(
        crate::remote_node::job_ledger::pending_terminal_wakes(dir.path())
            .await
            .unwrap()
            .iter()
            .any(|receipt| receipt.job_id == finalized_sync_job_id)
    );

    assert!(
        crate::remote_node::job_ledger::finalize(dir.path(), job_id, "succeeded", Some(0),)
            .await
            .unwrap()
    );
    assert_eq!(
        recoverable_inherited_remote_wait(
            dir.path(),
            mission_id,
            MissionExecutionState::WaitingRemoteJob,
            MissionStatus::Active,
        )
        .await
        .unwrap(),
        Some(job_id),
        "an undelivered terminal receipt must survive actor startup cleanup"
    );
}

#[tokio::test]
async fn graceful_shutdown_preserves_accepted_remote_wait_without_interrupting_run() {
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("remote wait during deploy"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .unwrap();
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();
    let run = store
        .begin_mission_run(mission.id, "remote-build:test", None)
        .await
        .unwrap();
    store
        .heartbeat_mission_run(
            run.run_id,
            run.generation,
            MissionExecutionState::Running,
            None,
        )
        .await
        .unwrap();
    let job_id = Uuid::new_v4();
    crate::remote_node::job_ledger::record(
        dir.path(),
        crate::remote_node::job_ledger::JobHandle {
            mission_id: mission.id,
            node_id: "node-a".to_string(),
            job_id,
            started_at: chrono::Utc::now(),
            submission_sequence: 1,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
            identity: None,
            wait_for_completion: Some(true),
            wake_on_terminal: true,
        },
    )
    .await
    .unwrap();

    assert!(
        preserve_remote_wait_during_shutdown(&store, dir.path(), mission.id).await,
        "an accepted exact job must own the mission across a backend restart"
    );
    let preserved = store
        .get_active_mission_run(mission.id)
        .await
        .unwrap()
        .expect("run lease must stay non-terminal");
    assert_eq!(preserved.run_id, run.run_id);
    assert_eq!(
        preserved.execution_state,
        MissionExecutionState::Running,
        "shutdown can race the heartbeat that parks an accepted remote job"
    );
    assert_eq!(
        store.get_mission(mission.id).await.unwrap().unwrap().status,
        MissionStatus::Active
    );

    crate::remote_node::job_ledger::remove(dir.path(), job_id).await;
    assert!(
        !preserve_remote_wait_during_shutdown(&store, dir.path(), mission.id).await,
        "a cancelled ledger handle must not protect a stale wait lease"
    );
}

#[test]
fn detached_remote_wait_is_healthy_only_while_its_lease_heartbeat_is_fresh() {
    assert!(detached_remote_wait_is_healthy(
        MissionExecutionState::WaitingRemoteJob,
        60
    ));
    assert!(!detached_remote_wait_is_healthy(
        MissionExecutionState::WaitingRemoteJob,
        61
    ));
    assert!(!detached_remote_wait_is_healthy(
        MissionExecutionState::Running,
        1
    ));
}

#[test]
fn tool_execution_deadlines_are_bounded_by_tool_class() {
    assert_eq!(
        tool_execution_deadline_secs("Read", &serde_json::json!({"path": "README.md"})),
        PROVISIONAL_TOOL_DEADLINE_SECS
    );
    assert_eq!(
        tool_execution_deadline_secs("Bash", &serde_json::json!({"command": "git status"})),
        MANAGED_SHELL_TOOL_DEADLINE_SECS
    );
    assert_eq!(
        tool_execution_deadline_secs(
            "bash",
            &serde_json::json!({"command": "cd Verity && lake build"})
        ),
        LONG_BUILD_TOOL_DEADLINE_SECS
    );
    assert_eq!(
        tool_execution_deadline_secs(
            "Shell",
            &serde_json::json!({"cmd": "remote-lean-build -- lake test"})
        ),
        LONG_BUILD_TOOL_DEADLINE_SECS
    );
}

fn reset_metadata_refresh_test_state() {
    let stale_tasks = {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        tasks
            .drain()
            .map(|(_, entry)| entry.handle)
            .collect::<Vec<_>>()
    };
    for task in stale_tasks {
        task.abort();
    }

    let mut baselines = MISSION_METADATA_REFRESH_BASELINES
        .lock()
        .expect("metadata refresh baseline lock poisoned");
    baselines.clear();
}

#[test]
fn canonical_github_pr_equates_url_and_compact_forms() {
    assert_eq!(
        canonical_github_pr("https://github.com/lfglabs-dev/verity/pull/2168/"),
        "lfglabs-dev/verity#2168"
    );
    assert_eq!(
        canonical_github_pr("LFGLABS-DEV/VERITY#2168"),
        "lfglabs-dev/verity#2168"
    );
    assert_eq!(
        canonical_github_pr(
            "https://github.com/lfglabs-dev/verity/pull/2168/files?diff=split#discussion"
        ),
        "lfglabs-dev/verity#2168"
    );
    assert_eq!(
        canonical_github_pr("lfglabs-dev/verity#2168/commits"),
        "lfglabs-dev/verity#2168"
    );
}

#[test]
fn pr_writer_inference_prefers_explicit_capability() {
    assert!(inferred_pr_writer(None, Some("integration_repair"), None));
    for prompt in [
        "Rebasing the branch onto main",
        "Merging the approved changes",
        "Committing the repair",
        "Pushing the updated branch",
    ] {
        assert!(inferred_pr_writer(None, None, Some(prompt)), "{prompt}");
    }
    for prompt in [
        "Audit only; rebasing is forbidden",
        "Do not commit or push the branch",
        "Merging is prohibited",
        "Stop before rebasing onto main",
    ] {
        assert!(!inferred_pr_writer(None, None, Some(prompt)), "{prompt}");
    }
    assert!(inferred_pr_writer(
        None,
        None,
        Some("Run tests before committing to the branch")
    ));
    assert!(inferred_pr_writer(
        None,
        None,
        Some("No tests required; fix the failing branch")
    ));
    assert!(inferred_pr_writer(
        None,
        None,
        Some("Do not commit or push; fix the failing branch")
    ));
    assert!(inferred_pr_writer(
        None,
        None,
        Some("Fix the prohibited dependency usage")
    ));
    assert!(inferred_pr_writer(
        None,
        None,
        Some("Implement the banned-import repair")
    ));
    assert!(!inferred_pr_writer(
        None,
        None,
        Some("Merge prohibited by policy")
    ));
    assert!(!inferred_pr_writer(None, None, Some("Push forbidden")));
    assert!(!inferred_pr_writer(
        None,
        None,
        Some("Merging is currently prohibited")
    ));
    assert!(!inferred_pr_writer(
        None,
        None,
        Some("Push is temporarily forbidden")
    ));
    assert!(!inferred_pr_writer(
        None,
        Some("read_only_audit"),
        Some("Inspect CI and report status")
    ));
    assert!(!inferred_pr_writer(
        Some(false),
        Some("review_merge_pr"),
        None
    ));
    assert!(inferred_pr_writer(
        Some(true),
        Some("read_only_audit"),
        None
    ));
    assert!(requested_pr_writer(
        Some(true),
        Some(&["pr-readonly".to_string()]),
        Some("read_only_audit"),
        None
    ));
    assert!(!requested_pr_writer(
        Some(false),
        Some(&["pr-writer".to_string()]),
        Some("integration_repair"),
        None
    ));
    let normalized =
        normalize_mission_tags(Some(&[" pr-writer ".to_string(), " ".to_string()])).unwrap();
    assert_eq!(normalized, ["pr-writer"]);
    assert!(requested_pr_writer(
        None,
        Some(&normalized),
        Some("read_only_audit"),
        None
    ));
}

#[test]
fn remote_terminal_wake_precedes_parked_user_followups() {
    let mission_id = Uuid::new_v4();
    let user_id = Uuid::new_v4();
    let wake_id = Uuid::new_v4();
    let mut queue = VecDeque::new();
    enqueue_control_message(
        &mut queue,
        (
            user_id,
            "user follow-up".to_string(),
            None,
            Some(mission_id),
            None,
        ),
    );
    enqueue_control_message(
        &mut queue,
        (
            wake_id,
            "terminal receipt".to_string(),
            None,
            Some(mission_id),
            Some("remote-build-terminal".to_string()),
        ),
    );

    assert_eq!(queue.pop_front().map(|entry| entry.0), Some(wake_id));
    assert_eq!(queue.pop_front().map(|entry| entry.0), Some(user_id));
}

#[test]
fn startup_recovery_prefers_submission_order_over_completion_order() {
    let older_started_at = chrono::Utc::now() - chrono::Duration::minutes(5);
    let newer_started_at = chrono::Utc::now() - chrono::Duration::minutes(1);

    assert!(
        crate::remote_node::job_ledger::validation_order(2, newer_started_at)
            > crate::remote_node::job_ledger::validation_order(1, older_started_at)
    );
    assert!(
        crate::remote_node::job_ledger::validation_order(0, newer_started_at)
            > crate::remote_node::job_ledger::validation_order(0, older_started_at)
    );
}

#[tokio::test]
async fn readonly_authority_cannot_be_escalated_by_prompt_text() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("Read-only PR audit"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .unwrap();
    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                github_pr: Some(Some("owner/repo#42".to_string())),
                tags: Some(vec!["pr-readonly".to_string()]),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let mission = store.get_mission(mission.id).await.unwrap().unwrap();

    assert!(!mission_is_pr_writer_with_prompt(
        &mission,
        Some("Fix and update the PR after review")
    ));
    assert!(!message_requests_pr_writer(
        &mission,
        "Fix and update the PR after review"
    ));

    let mut unclassified = mission.clone();
    unclassified.project.tags.clear();
    assert!(message_requests_pr_writer(
        &unclassified,
        "Fix and update the PR after review"
    ));
}

#[tokio::test]
async fn durable_writer_classification_survives_history_projection() {
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(
        mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "long-writer")
            .await
            .unwrap(),
    );
    let mission = store
        .create_mission(Some("Legacy writer"), None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                github_pr: Some(Some("owner/repo#46".to_string())),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    for index in 0..206 {
        store
            .log_event(
                mission.id,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content: if index == 0 {
                        "Fix, commit and push this PR".to_string()
                    } else {
                        format!("neutral follow-up {index}")
                    },
                    queued: false,
                    mission_id: Some(mission.id),
                    source: None,
                },
            )
            .await
            .unwrap();
    }
    let projected = store.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(projected.history.len(), 200);
    assert!(!mission_is_pr_writer(&projected));
    assert!(mission_is_pr_writer_in_store(&store, &projected)
        .await
        .unwrap());
}

#[tokio::test]
async fn attention_inventory_rejects_partial_store_results() {
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("visible worker"), None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                project: Some(Some("eip-8282".into())),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    for _ in 0..5001 {
        store
            .create_mission(
                Some("unrelated newer work"),
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .await
            .unwrap();
    }
    let keys = vec!["eip-8282".to_string()];
    let inventory = |paths| MissionStoreInventory {
        live: vec![store.clone()],
        offline_sqlite: paths,
        offline_file_users: vec![],
        base_dir: dir.path().to_path_buf(),
    };
    let complete = ControlHub::collect_attention_inventory(inventory(vec![]), &keys)
        .await
        .unwrap();
    assert_eq!(complete.len(), 1);
    let unavailable = dir.path().join("missing.db");
    let partial =
        ControlHub::collect_attention_inventory(inventory(vec![unavailable]), &keys).await;
    assert!(
        partial.is_err(),
        "successful live rows cannot hide an unavailable offline store"
    );
}

#[test]
fn offline_attention_preserves_decision_and_grace_fields() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions.db");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("CREATE TABLE missions (id TEXT, status TEXT, title TEXT, workspace_id TEXT, backend TEXT, created_at TEXT, updated_at TEXT, project TEXT, track TEXT, intent TEXT, github_pr TEXT, awaiting_kind TEXT, origin_session_id TEXT, last_status_change_at TEXT);").unwrap();
    let id = Uuid::new_v4().to_string();
    let now = chrono::Utc::now();
    let recent = now.to_rfc3339();
    let expired = (now - chrono::Duration::hours(1)).to_rfc3339();
    db.execute("INSERT INTO missions(id,status,project,awaiting_kind,origin_session_id,last_status_change_at,updated_at) VALUES (?1,'awaiting_user','eip-8282','decision','hermes-session',?2,?3)", rusqlite::params![id,recent,expired]).unwrap();
    let rows = collect_attention_missions_from_sqlite(&path, "eip-8282").unwrap();
    assert_eq!(rows[0].awaiting_kind, Some(AwaitingKind::Decision));
    assert_eq!(rows[0].origin_session_id.as_deref(), Some("hermes-session"));
    assert!(!crate::api::operator_attention::mission_needs_operator(
        &rows[0], false, None, now
    ));
    db.execute("UPDATE missions SET last_status_change_at=?1", [&expired])
        .unwrap();
    let rows = collect_attention_missions_from_sqlite(&path, "eip-8282").unwrap();
    assert!(crate::api::operator_attention::mission_needs_operator(
        &rows[0], false, None, now
    ));
    // Legacy rows predate `awaiting_kind`: they are kept (as the live
    // store keeps `None`), not treated as an inventory failure.
    db.execute("UPDATE missions SET awaiting_kind=NULL", [])
        .unwrap();
    let rows = collect_attention_missions_from_sqlite(&path, "eip-8282").unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].awaiting_kind, None);
    assert!(!crate::api::operator_attention::mission_needs_operator(
        &rows[0], false, None, now
    ));
    // A present but unknown kind is still an error.
    db.execute("UPDATE missions SET awaiting_kind='bogus'", [])
        .unwrap();
    assert!(collect_attention_missions_from_sqlite(&path, "eip-8282").is_err());
}

#[test]
fn offline_sqlite_writer_scan_reads_deferred_goal_without_migrations() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions-offline.db");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE missions (
                    id TEXT PRIMARY KEY, status TEXT, github_pr TEXT,
                    intent TEXT, tags TEXT, deferred_goal TEXT
                 );
                 CREATE TABLE mission_events (
                    mission_id TEXT, sequence INTEGER, event_type TEXT, content TEXT,
                    content_file TEXT
                 );",
        )
        .unwrap();
    let mission_id = Uuid::new_v4();
    connection
        .execute(
            "INSERT INTO missions (id, status, github_pr, intent, tags, deferred_goal)
                 VALUES (?1, 'pending', ?2, NULL, '[]', 'Fix, commit and push')",
            rusqlite::params![mission_id.to_string(), "owner/repo#42"],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO mission_events
                 (mission_id, sequence, event_type, content, content_file)
                 VALUES (?1, 1, 'user_message', 'Inspect status only', NULL)",
            rusqlite::params![mission_id.to_string()],
        )
        .unwrap();
    drop(connection);

    let found =
        find_existing_pr_writer_in_sqlite(&path, "https://github.com/owner/repo/pull/42", None)
            .unwrap()
            .unwrap();

    assert_eq!(found.id, mission_id);
    assert_eq!(found.status, MissionStatus::Pending);
}

#[test]
fn offline_sqlite_writer_scan_respects_readonly_deferred_goal() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions-readonly.db");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE missions (
                    id TEXT PRIMARY KEY, status TEXT, github_pr TEXT,
                    intent TEXT, tags TEXT, deferred_goal TEXT
                 );
                 CREATE TABLE mission_events (
                    mission_id TEXT, sequence INTEGER, event_type TEXT, content TEXT,
                    content_file TEXT
                 );",
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO missions (id, status, github_pr, intent, tags, deferred_goal)
                 VALUES (?1, 'pending', 'owner/repo#45', NULL, '[\"pr-readonly\"]',
                         'Fix and update the PR after review')",
            rusqlite::params![Uuid::new_v4().to_string()],
        )
        .unwrap();
    drop(connection);

    assert!(
        find_existing_pr_writer_in_sqlite(&path, "owner/repo#45", None)
            .unwrap()
            .is_none()
    );
}

#[test]
fn offline_sqlite_writer_scan_ignores_schema_without_pr_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions-legacy.db");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE missions (id TEXT PRIMARY KEY, status TEXT);
                 CREATE TABLE mission_events (
                    mission_id TEXT, sequence INTEGER, event_type TEXT, content TEXT
                 );",
        )
        .unwrap();
    drop(connection);

    assert!(
        find_existing_pr_writer_in_sqlite(&path, "owner/repo#42", None)
            .unwrap()
            .is_none()
    );
}

#[test]
fn offline_sqlite_writer_scan_adapts_to_missing_optional_columns() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions-partial.db");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE missions (
                    id TEXT PRIMARY KEY, status TEXT, github_pr TEXT
                 );
                 CREATE TABLE mission_events (
                    mission_id TEXT, sequence INTEGER, event_type TEXT, content TEXT
                 );",
        )
        .unwrap();
    let mission_id = Uuid::new_v4();
    connection
        .execute(
            "INSERT INTO missions (id, status, github_pr)
                 VALUES (?1, 'active', 'owner/repo#44')",
            rusqlite::params![mission_id.to_string()],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO mission_events
                 (mission_id, sequence, event_type, content)
                 VALUES (?1, 1, 'user_message', 'Fix, commit and push this PR')",
            rusqlite::params![mission_id.to_string()],
        )
        .unwrap();
    drop(connection);

    let found = find_existing_pr_writer_in_sqlite(&path, "owner/repo#44", None)
        .unwrap()
        .unwrap();
    assert_eq!(found.id, mission_id);
    assert_eq!(found.status, MissionStatus::Active);
}

#[test]
fn offline_sqlite_writer_scan_reads_externalized_initial_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions-offline.db");
    let prompt_path = dir.path().join("initial-prompt.txt");
    std::fs::write(&prompt_path, "Fix this PR, commit and push").unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE missions (
                    id TEXT PRIMARY KEY, status TEXT, github_pr TEXT,
                    intent TEXT, tags TEXT, deferred_goal TEXT
                 );
                 CREATE TABLE mission_events (
                    mission_id TEXT, sequence INTEGER, event_type TEXT, content TEXT,
                    content_file TEXT
                 );",
        )
        .unwrap();
    let mission_id = Uuid::new_v4();
    connection
        .execute(
            "INSERT INTO missions (id, status, github_pr, intent, tags, deferred_goal)
                 VALUES (?1, 'active', ?2, NULL, '[]', NULL)",
            rusqlite::params![mission_id.to_string(), "owner/repo#43"],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO mission_events
                 (mission_id, sequence, event_type, content, content_file)
                 VALUES (?1, 1, 'user_message', NULL, ?2)",
            rusqlite::params![mission_id.to_string(), prompt_path.to_string_lossy()],
        )
        .unwrap();
    drop(connection);

    let found = find_existing_pr_writer_in_sqlite(&path, "owner/repo#43", None)
        .unwrap()
        .unwrap();

    assert_eq!(found.id, mission_id);
    assert_eq!(found.status, MissionStatus::Active);
}

fn stored_test_event(
    mission_id: Uuid,
    sequence: i64,
    event_type: &str,
    tool_call_id: Option<&str>,
    content: &str,
) -> mission_store::StoredEvent {
    mission_store::StoredEvent {
        id: sequence,
        mission_id,
        sequence,
        event_type: event_type.to_string(),
        timestamp: format!("2026-06-04T10:00:{sequence:02}Z"),
        event_id: Some(format!("event-{sequence}")),
        tool_call_id: tool_call_id.map(ToString::to_string),
        tool_name: tool_call_id.map(|_| "bash".to_string()),
        content: content.to_string(),
        metadata: serde_json::json!({}),
    }
}

#[test]
fn durable_job_result_parser_accepts_direct_and_mcp_content_shapes() {
    let job = serde_json::json!({
        "id": "11111111-1111-1111-1111-111111111111",
        "stdout_log": "/workspace/.sandboxed-sh/durable-jobs/job/stdout.log",
        "command": "lake build"
    });
    assert_eq!(parse_durable_job_result(&job), Some(job.clone()));

    let wrapped = serde_json::json!({
        "content": [{
            "type": "text",
            "text": serde_json::to_string(&job).unwrap()
        }]
    });
    assert_eq!(parse_durable_job_result(&wrapped), Some(job));
    assert!(parse_durable_job_result(&serde_json::json!({
        "content": "not a job"
    }))
    .is_none());
}

#[test]
fn conversation_projection_stubs_older_tool_pairs() {
    let mission_id = Uuid::new_v4();
    let events = vec![
        stored_test_event(mission_id, 1, "user_message", None, "start"),
        stored_test_event(
            mission_id,
            2,
            "tool_call",
            Some("tool-1"),
            "{\"cmd\":\"old\"}",
        ),
        stored_test_event(
            mission_id,
            3,
            "tool_result",
            Some("tool-1"),
            "{\"ok\":true}",
        ),
        stored_test_event(
            mission_id,
            4,
            "tool_call",
            Some("tool-2"),
            "{\"cmd\":\"new\"}",
        ),
        stored_test_event(
            mission_id,
            5,
            "tool_result",
            Some("tool-2"),
            "{\"ok\":true}",
        ),
        stored_test_event(mission_id, 6, "assistant_message", None, "done"),
    ];

    let keep_full_tool_call_ids = HashSet::from(["tool-2".to_string()]);
    let projected = project_conversation_events(events, &keep_full_tool_call_ids, &HashMap::new());

    assert_eq!(
        projected
            .iter()
            .map(|event| event.event_type.as_str())
            .collect::<Vec<_>>(),
        vec![
            "user_message",
            "tool_stub",
            "tool_call",
            "tool_result",
            "assistant_message"
        ]
    );
    let stub = projected
        .iter()
        .find(|event| event.event_type == "tool_stub")
        .expect("older tool call should be stubbed");
    assert_eq!(stub.tool_call_id.as_deref(), Some("tool-1"));
    assert!(stub.content.is_empty());
    assert_eq!(stub.metadata["lazy"], serde_json::json!(true));
    assert_eq!(stub.metadata["has_result"], serde_json::json!(true));
    assert_eq!(stub.metadata["result_sequence"], serde_json::json!(3));
    assert_eq!(
        stub.metadata["call_content_bytes"],
        serde_json::json!("{\"cmd\":\"old\"}".len())
    );
}

#[test]
fn conversation_projection_keeps_interactive_ui_tools_full() {
    // An old, answered AskUserQuestion must NOT be stubbed: the dashboard
    // needs its args to render the question, otherwise it shows the
    // misleading empty "reply below" prompt for an already-answered item.
    let mission_id = Uuid::new_v4();
    let mut call = stored_test_event(
        mission_id,
        1,
        "tool_call",
        Some("q-1"),
        "{\"questions\":[{\"question\":\"Pick one\",\"options\":[]}]}",
    );
    call.tool_name = Some("AskUserQuestion".to_string());
    let mut result = stored_test_event(
        mission_id,
        2,
        "tool_result",
        Some("q-1"),
        "{\"answers\":[[\"A\"]]}",
    );
    result.tool_name = Some("AskUserQuestion".to_string());
    // A newer ordinary tool pair that SHOULD still be stubbed.
    let newer_call = stored_test_event(mission_id, 3, "tool_call", Some("b-1"), "{\"cmd\":\"x\"}");
    let newer_result =
        stored_test_event(mission_id, 4, "tool_result", Some("b-1"), "{\"ok\":true}");

    let projected = project_conversation_events(
        vec![call, result, newer_call, newer_result],
        &HashSet::new(),
        &HashMap::new(),
    );

    // The question call + result survive intact.
    let q_call = projected
        .iter()
        .find(|e| e.tool_call_id.as_deref() == Some("q-1") && e.event_type == "tool_call")
        .expect("question tool_call kept full");
    assert!(q_call.content.contains("Pick one"));
    assert!(projected
        .iter()
        .any(|e| e.tool_call_id.as_deref() == Some("q-1") && e.event_type == "tool_result"));
    // The ordinary newer pair is stubbed as usual.
    assert!(projected
        .iter()
        .any(|e| e.tool_call_id.as_deref() == Some("b-1") && e.event_type == "tool_stub"));
}

#[test]
fn conversation_projection_uses_global_keep_full_set() {
    let mission_id = Uuid::new_v4();
    let events = vec![
        stored_test_event(mission_id, 20, "tool_call", Some("older-page-newest"), "{}"),
        stored_test_event(
            mission_id,
            21,
            "tool_result",
            Some("older-page-newest"),
            "{\"ok\":true}",
        ),
    ];

    let projected = project_conversation_events(events, &HashSet::new(), &HashMap::new());

    assert_eq!(projected.len(), 1);
    assert_eq!(projected[0].event_type, "tool_stub");
    assert_eq!(
        projected[0].tool_call_id.as_deref(),
        Some("older-page-newest")
    );
}

#[test]
fn conversation_projection_uses_persisted_tool_summary_across_page_boundary() {
    let mission_id = Uuid::new_v4();
    let events = vec![stored_test_event(
        mission_id,
        10,
        "tool_call",
        Some("split-tool"),
        "{}",
    )];
    let summaries = HashMap::from([(
        "split-tool".to_string(),
        mission_store::ToolCallSummary {
            has_result: true,
            result_sequence: Some(11),
            result_timestamp: Some("2026-06-04T10:00:11Z".to_string()),
            call_content_bytes: 2,
            result_content_bytes: 14,
        },
    )]);

    let projected = project_conversation_events(events, &HashSet::new(), &summaries);

    assert_eq!(projected.len(), 1);
    let stub = &projected[0];
    assert_eq!(stub.event_type, "tool_stub");
    assert_eq!(stub.metadata["has_result"], serde_json::json!(true));
    assert_eq!(stub.metadata["result_sequence"], serde_json::json!(11));
    assert_eq!(
        stub.metadata["result_timestamp"],
        serde_json::json!("2026-06-04T10:00:11Z")
    );
    assert_eq!(stub.metadata["result_content_bytes"], serde_json::json!(14));
}

#[test]
fn conversation_projection_keeps_inflight_tools_full() {
    let mission_id = Uuid::new_v4();
    let events = vec![stored_test_event(
        mission_id,
        10,
        "tool_call",
        Some("inflight-tool"),
        "{\"cmd\":\"long\"}",
    )];
    let summaries = HashMap::from([(
        "inflight-tool".to_string(),
        mission_store::ToolCallSummary {
            has_result: false,
            result_sequence: None,
            result_timestamp: None,
            call_content_bytes: "{\"cmd\":\"long\"}".len(),
            result_content_bytes: 0,
        },
    )]);

    let projected = project_conversation_events(events, &HashSet::new(), &summaries);

    assert_eq!(projected.len(), 1);
    assert_eq!(projected[0].event_type, "tool_call");
    assert_eq!(projected[0].content, "{\"cmd\":\"long\"}");
}

fn test_automation_with_mode(
    fresh_session: mission_store::FreshSession,
    variables: HashMap<String, String>,
) -> mission_store::Automation {
    mission_store::Automation {
        id: Uuid::new_v4(),
        mission_id: Uuid::new_v4(),
        command_source: mission_store::CommandSource::Inline {
            content: "ping".to_string(),
        },
        trigger: mission_store::TriggerType::AgentFinished,
        variables,
        active: true,
        created_at: mission_store::now_string(),
        last_triggered_at: None,
        retry_config: mission_store::RetryConfig::default(),
        stop_policy: mission_store::StopPolicy::Never,
        fresh_session,
        consecutive_failures: 0,
        driver: mission_store::AutomationDriver::Scheduler,
    }
}

#[test]
fn test_resolve_agent_finished_target_mission_switches_on_completed() {
    let source_mission_id = Uuid::new_v4();
    let next_mission_id = Uuid::new_v4();
    let mut vars = HashMap::new();
    vars.insert("nextSessionId".to_string(), next_mission_id.to_string());
    let automation = test_automation_with_mode(mission_store::FreshSession::Switch, vars);

    let target = resolve_agent_finished_target_mission(
        source_mission_id,
        MissionStatus::Completed,
        &automation,
    );
    assert_eq!(target, next_mission_id);
}

#[test]
fn test_resolve_agent_finished_target_mission_does_not_switch_when_not_completed() {
    let source_mission_id = Uuid::new_v4();
    let next_mission_id = Uuid::new_v4();
    let mut vars = HashMap::new();
    vars.insert("nextSessionId".to_string(), next_mission_id.to_string());
    let automation = test_automation_with_mode(mission_store::FreshSession::Switch, vars);

    let target = resolve_agent_finished_target_mission(
        source_mission_id,
        MissionStatus::Active,
        &automation,
    );
    assert_eq!(target, source_mission_id);
}

#[test]
fn text_op_stream_transform_converts_cumulative_delta_to_insert_then_replace() {
    let mission_id = Uuid::new_v4();
    let mut buffers = HashMap::new();

    let first = text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: "hello".to_string(),
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );
    assert_eq!(first.len(), 1);
    match &first[0] {
        AgentEvent::TextOp {
            mission_id: actual_mission,
            bubble_id,
            ops,
        } => {
            assert_eq!(*actual_mission, mission_id);
            assert_eq!(bubble_id, "text_delta_latest");
            assert_eq!(
                ops,
                &vec![TextOp::Insert {
                    pos: 0,
                    text: "hello".to_string(),
                }]
            );
        }
        other => panic!("expected text_op, got {other:?}"),
    }

    let second = text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: "hello world".to_string(),
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );
    assert_eq!(second.len(), 1);
    match &second[0] {
        AgentEvent::TextOp {
            mission_id: actual_mission,
            bubble_id,
            ops,
        } => {
            assert_eq!(*actual_mission, mission_id);
            assert_eq!(bubble_id, "text_delta_latest");
            assert_eq!(
                ops,
                &vec![TextOp::Replace {
                    range: (0, 5),
                    text: "hello world".to_string(),
                }]
            );
        }
        other => panic!("expected text_op, got {other:?}"),
    }
}

#[test]
fn text_op_stream_buffer_resets_across_a_cut_turn_so_send_now_reply_is_not_glued() {
    // Live repro c24318b8: a remote Claude Code turn streamed "step 1..5
    // done", Send now interrupted it (no final assistant message), and the
    // next turn's first snapshot reached Orb as
    // replace(0..len, "step 1 done…step 5 doneYou said …").
    let mission_id = Uuid::new_v4();
    let delta = |content: &str| AgentEvent::TextDelta {
        content: content.to_string(),
        mission_id: Some(mission_id),
    };
    let ops = |events: Vec<AgentEvent>| -> Vec<Vec<TextOp>> {
        events
            .into_iter()
            .filter_map(|event| match event {
                AgentEvent::TextOp { ops, .. } => Some(ops),
                _ => None,
            })
            .collect()
    };
    // Cut by a status change.
    let mut buffers = HashMap::new();
    let _ = text_op_events_for_stream(delta("step 1 done\nstep 5 done"), &mut buffers);
    let cut = text_op_events_for_stream(
        AgentEvent::MissionStatusChanged {
            completion: None,
            execution: None,
            mission_id,
            status: MissionStatus::Interrupted,
            summary: None,
        },
        &mut buffers,
    );
    assert_eq!(ops(cut), vec![vec![TextOp::Finalize]]);
    assert_eq!(
        ops(text_op_events_for_stream(delta("You said"), &mut buffers)),
        vec![vec![TextOp::Insert {
            pos: 0,
            text: "You said".into()
        }]]
    );
    // A delivered user message alone also starts a fresh buffer; a queued
    // one does not touch the running turn.
    let mut buffers = HashMap::new();
    let _ = text_op_events_for_stream(delta("step 1 done"), &mut buffers);
    let user = |queued: bool| AgentEvent::UserMessage {
        id: Uuid::new_v4(),
        content: "retest queued".into(),
        queued,
        mission_id: Some(mission_id),
        source: None,
    };
    let _ = text_op_events_for_stream(user(true), &mut buffers);
    assert_eq!(
        buffers.get(&mission_id).map(String::as_str),
        Some("step 1 done")
    );
    let _ = text_op_events_for_stream(user(false), &mut buffers);
    assert_eq!(
        ops(text_op_events_for_stream(delta("You said"), &mut buffers)),
        vec![vec![TextOp::Insert {
            pos: 0,
            text: "You said".into()
        }]]
    );
}

#[test]
fn text_op_stream_transform_merges_incremental_delta_fragments() {
    let mission_id = Uuid::new_v4();
    let mut buffers = HashMap::new();

    let _ = text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: "No, it is not actually enforced yet.".to_string(),
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );

    let second = text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: "\n\nCurrent state:".to_string(),
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );

    match &second[0] {
        AgentEvent::TextOp { ops, .. } => {
            assert_eq!(
                ops,
                &vec![TextOp::Replace {
                    range: (0, 36),
                    text: "No, it is not actually enforced yet.\n\nCurrent state:".to_string(),
                }]
            );
        }
        other => panic!("expected text_op, got {other:?}"),
    }
}

#[test]
fn text_op_stream_transform_ignores_replayed_shorter_prefixes() {
    let mission_id = Uuid::new_v4();
    let mut buffers = HashMap::new();

    let _ = text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: "The docs are accurate about this current state.".to_string(),
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );

    let second = text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: "The docs are accurate".to_string(),
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );

    match &second[0] {
        AgentEvent::TextOp { ops, .. } => {
            assert_eq!(
                ops,
                &vec![TextOp::Replace {
                    range: (0, 47),
                    text: "The docs are accurate about this current state.".to_string(),
                }]
            );
        }
        other => panic!("expected text_op, got {other:?}"),
    }
}

#[test]
fn text_op_stream_transform_finalizes_before_assistant_message() {
    let mission_id = Uuid::new_v4();
    let mut buffers = HashMap::new();

    let _ = text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: "draft".to_string(),
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );

    let finalized = text_op_events_for_stream(
        AgentEvent::AssistantMessage {
            id: Uuid::new_v4(),
            content: "final".to_string(),
            success: true,
            cost_cents: 0,
            cost_source: crate::agents::CostSource::Unknown,
            usage: None,
            model: None,
            model_normalized: None,
            mission_id: Some(mission_id),
            shared_files: None,
            resumable: false,
            completion_evidence: None,
        },
        &mut buffers,
    );

    assert_eq!(finalized.len(), 2);
    match &finalized[0] {
        AgentEvent::TextOp {
            mission_id: actual_mission,
            bubble_id,
            ops,
        } => {
            assert_eq!(*actual_mission, mission_id);
            assert_eq!(bubble_id, "text_delta_latest");
            assert_eq!(ops, &vec![TextOp::Finalize]);
        }
        other => panic!("expected finalize text_op, got {other:?}"),
    }
    assert!(matches!(finalized[1], AgentEvent::AssistantMessage { .. }));
    assert!(buffers.is_empty());
}

#[tokio::test]
async fn delete_mission_with_children_removes_worker_missions() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let boss = store
        .create_mission(Some("Boss mission"), None, None, None, None, None, None)
        .await
        .expect("boss mission should be created");
    let worker = store
        .create_mission_with_parent(
            Some("Worker mission"),
            None,
            None,
            None,
            None,
            false,
            None,
            None,
            Some(boss.id),
            None,
        )
        .await
        .expect("worker mission should be created");
    let nested_worker = store
        .create_mission_with_parent(
            Some("Nested worker mission"),
            None,
            None,
            None,
            None,
            false,
            None,
            None,
            Some(worker.id),
            None,
        )
        .await
        .expect("nested worker mission should be created");

    let deleted_ids = delete_mission_with_children(&store, boss.id, &[])
        .await
        .expect("delete should cascade to workers");

    assert_eq!(deleted_ids[0], boss.id);
    assert!(deleted_ids.contains(&worker.id));
    assert!(deleted_ids.contains(&nested_worker.id));
    assert!(store.get_mission(boss.id).await.unwrap().is_none());
    assert!(store.get_mission(worker.id).await.unwrap().is_none());
    assert!(store.get_mission(nested_worker.id).await.unwrap().is_none());
}

#[tokio::test]
async fn delete_refuses_to_cascade_without_include_descendants() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let parent = store
        .create_mission(Some("EV Bench"), None, None, None, None, None, None)
        .await
        .unwrap();
    let child = store
        .create_mission_with_parent(
            Some("Benchmarks"),
            None,
            None,
            None,
            None,
            false,
            None,
            None,
            Some(parent.id),
            None,
        )
        .await
        .unwrap();
    store
        .update_mission_status(child.id, MissionStatus::Active)
        .await
        .unwrap();
    let ids = collect_child_mission_ids(&store, parent.id).await.unwrap();
    let mut descendants = Vec::new();
    for id in ids {
        descendants.push(store.get_mission(id).await.unwrap().unwrap());
    }
    for opt in [None, Some(false)] {
        let (status, body) = require_descendant_opt_in(parent.id, opt, &descendants).unwrap_err();
        assert_eq!(status, StatusCode::CONFLICT);
        assert!(
            body.contains("1 descendant session: Benchmarks (running)"),
            "{body}"
        );
        assert!(body.contains("include_descendants=true"), "{body}");
    }
    assert!(require_descendant_opt_in(parent.id, Some(true), &descendants).is_ok());
    assert!(require_descendant_opt_in(parent.id, None, &[]).is_ok());
    // Nothing was deleted by the refusal.
    assert!(store.get_mission(child.id).await.unwrap().is_some());
}

#[tokio::test]
async fn deleted_workspace_cleanup_preserves_legacy_quarantine_without_authorization() {
    let temp = tempfile::tempdir().unwrap();
    let workspaces = Arc::new(workspace::WorkspaceStore::new(temp.path().to_path_buf()).await);
    let parent = workspace::workspaces_root_for(temp.path());
    let trash = parent.join(format!(
        ".deleted-mission-{}-{}",
        Uuid::new_v4(),
        Uuid::new_v4()
    ));
    let unrelated = parent.join(".deleted-mission-user-files");
    tokio::fs::create_dir_all(&trash).await.unwrap();
    tokio::fs::write(trash.join("artifact"), b"old build")
        .await
        .unwrap();
    tokio::fs::create_dir_all(&unrelated).await.unwrap();
    start_deleted_workspace_cleanup(workspaces);
    tokio::task::yield_now().await;
    assert!(
        trash.join("artifact").exists(),
        "a legacy name is not discard permission"
    );
    assert!(unrelated.exists());
}

#[tokio::test]
async fn history_deletion_retains_worker_workspace_dirs() {
    let temp = tempfile::tempdir().expect("temp dir should be created");
    let workspaces = Arc::new(workspace::WorkspaceStore::new(temp.path().to_path_buf()).await);
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let boss = store
        .create_mission(Some("Boss mission"), None, None, None, None, None, None)
        .await
        .expect("boss mission should be created");
    let worker = store
        .create_mission_with_parent(
            Some("Worker mission"),
            None,
            None,
            None,
            None,
            false,
            None,
            None,
            Some(boss.id),
            None,
        )
        .await
        .expect("worker mission should be created");

    let boss_dir = workspace::mission_workspace_dir_for_root(temp.path(), boss.id);
    let worker_dir = workspace::mission_workspace_dir_for_root(temp.path(), worker.id);
    tokio::fs::create_dir_all(&boss_dir)
        .await
        .expect("boss workspace dir should be created");
    tokio::fs::create_dir_all(&worker_dir)
        .await
        .expect("worker workspace dir should be created");

    store
        .update_mission_status(worker.id, MissionStatus::Paused)
        .await
        .unwrap();
    let refused = cleanup_mission_workspace_dirs_for_delete(&store, &workspaces, boss.id, &[])
        .await
        .unwrap_err();
    assert_eq!(refused.0, StatusCode::CONFLICT);
    assert!(boss_dir.exists());
    assert!(worker_dir.exists());
    store
        .update_mission_status(worker.id, MissionStatus::Completed)
        .await
        .unwrap();

    let deleted_dirs = cleanup_mission_workspace_dirs_for_delete(&store, &workspaces, boss.id, &[])
        .await
        .expect("workspace cleanup should succeed");

    assert!(deleted_dirs.is_empty());
    assert!(boss_dir.exists());
    assert!(worker_dir.exists());
    assert!(store.get_mission(boss.id).await.unwrap().is_some());
    assert!(store.get_mission(worker.id).await.unwrap().is_some());
}

#[cfg(unix)]
#[tokio::test]
async fn delete_refuses_changed_persisted_filesystem_until_identity_is_restored() {
    let temp = tempfile::tempdir().expect("temp dir should be created");
    let storage = temp.path().join("relocated-storage");
    std::fs::create_dir_all(&storage).expect("storage should be created");
    let workspaces = Arc::new(workspace::WorkspaceStore::new(temp.path().to_path_buf()).await);
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("relocated mission"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission should be created");
    let mission_dir = workspace::mission_workspace_dir_for_root(&storage, mission.id);
    std::fs::create_dir_all(&mission_dir).expect("mission directory should be created");

    let registry_dir = temp.path().join(".sandboxed-sh");
    std::fs::create_dir_all(&registry_dir).expect("registry directory should be created");
    let registry_path = registry_dir.join("mission-workspace-roots.json");
    let actual_identity = workspace::filesystem_identity(&storage).unwrap();
    std::fs::write(
        &registry_path,
        serde_json::json!({ mission.id.to_string(): {
            "path": storage,
            "filesystem_identity": actual_identity
        }})
        .to_string(),
    )
    .expect("registry should be written");

    // A completely unavailable persisted root must leave both the
    // checkout and its database record intact.
    let unavailable_storage = temp.path().join("temporarily-unmounted-storage");
    std::fs::rename(&storage, &unavailable_storage).expect("storage should disappear");
    let error = cleanup_mission_workspace_dirs_for_delete(&store, &workspaces, mission.id, &[])
        .await
        .expect_err("deletion must fail closed for an unavailable filesystem");
    assert_eq!(error.0, StatusCode::CONFLICT);
    assert!(store.get_mission(mission.id).await.unwrap().is_some());
    assert!(unavailable_storage
        .join("workspaces")
        .join(mission_dir.file_name().unwrap())
        .exists());
    std::fs::rename(&unavailable_storage, &storage).expect("storage should be restored");

    // An unmount can also leave the mountpoint path behind on a different
    // filesystem. That identity mismatch is equally unsafe to delete.
    std::fs::write(
        &registry_path,
        serde_json::json!({ mission.id.to_string(): {
            "path": storage,
            "filesystem_identity": "dev:changed-after-unmount"
        }})
        .to_string(),
    )
    .expect("mismatched registry should be written");
    let error = cleanup_mission_workspace_dirs_for_delete(&store, &workspaces, mission.id, &[])
        .await
        .expect_err("deletion must fail closed for a replaced filesystem");
    assert_eq!(error.0, StatusCode::CONFLICT);
    assert!(store.get_mission(mission.id).await.unwrap().is_some());
    assert!(mission_dir.exists());

    std::fs::write(
        &registry_path,
        serde_json::json!({ mission.id.to_string(): {
            "path": storage,
            "filesystem_identity": actual_identity
        }})
        .to_string(),
    )
    .expect("restored registry should be written");

    cleanup_mission_workspace_dirs_for_delete(&store, &workspaces, mission.id, &[])
        .await
        .expect("deletion should proceed after the original filesystem is restored");
    delete_mission_with_children(&store, mission.id, &[])
        .await
        .expect("database record should delete only after verified cleanup");
    assert!(
        mission_dir.exists(),
        "history deletion preserves source even after placement verifies"
    );
    assert!(store.get_mission(mission.id).await.unwrap().is_none());
}

#[tokio::test]
async fn cleanup_stale_active_missions_once_keeps_recent_active_mission_active() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("Claude retry validation"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission should be created");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("mission should become active");

    let (events_tx, _events_rx) = broadcast::channel(8);
    let (cmd_tx, _cmd_rx) = mpsc::channel(8);
    cleanup_stale_active_missions_once(&store, 24, &events_tx, &cmd_tx).await;

    let stored = store
        .get_mission(mission.id)
        .await
        .expect("mission lookup should succeed")
        .expect("mission should exist");
    assert_eq!(stored.status, MissionStatus::Active);
}

#[tokio::test]
async fn cleanup_stale_active_missions_once_skips_hermes_tagged_writer() {
    let inner = Arc::new(mission_store::InMemoryMissionStore::new());
    let store: Arc<dyn MissionStore> = inner.clone();
    let mission = store
        .create_mission(
            Some("Grok 4.6 — repair Verity PR #2332"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission should be created");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("mission should become active");
    store
        .update_mission_project(
            mission.id,
            mission_store::MissionProjectPatch {
                preserve_updated_at: false,
                tag_patch: None,
                title: None,
                project: None,
                track: None,
                intent: None,
                github_pr: None,
                tags: Some(vec!["origin:hermes-assistant".to_string()]),
                desired_state: None,
                next_check_at: None,
            },
        )
        .await
        .expect("tags should apply");
    let stale_at = (chrono::Utc::now() - chrono::Duration::hours(3)).to_rfc3339();
    inner
        .test_set_updated_at(mission.id, stale_at)
        .await
        .expect("updated_at should backdate");

    let (events_tx, _events_rx) = broadcast::channel(8);
    let (cmd_tx, _cmd_rx) = mpsc::channel(8);
    cleanup_stale_active_missions_once(&store, 2, &events_tx, &cmd_tx).await;

    let stored = store
        .get_mission(mission.id)
        .await
        .expect("mission lookup should succeed")
        .expect("mission should exist");
    assert_eq!(stored.status, MissionStatus::Active);
}

#[tokio::test]
async fn cleanup_stale_active_missions_once_skips_client_placed_mission() {
    let inner = Arc::new(mission_store::InMemoryMissionStore::new());
    let store: Arc<dyn MissionStore> = inner.clone();
    let mission = store
        .create_mission(
            Some("CTRL-G"),
            None,
            None,
            None,
            None,
            Some("antigravity"),
            None,
        )
        .await
        .expect("mission should be created");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("mission should become active");
    store
        .update_mission_project(
            mission.id,
            mission_store::MissionProjectPatch {
                preserve_updated_at: false,
                tag_patch: None,
                title: None,
                project: None,
                track: None,
                intent: None,
                github_pr: None,
                tags: Some(vec!["placement:client".to_string()]),
                desired_state: None,
                next_check_at: None,
            },
        )
        .await
        .expect("tags should apply");
    let run = store
        .begin_mission_run(
            mission.id,
            "orb-client:3ca54946-9af5-4ee6-83a2-983bc4b946b0",
            Some("orb-cwd:/Users/thomas/work"),
        )
        .await
        .expect("client run should start");
    let stale_at = (chrono::Utc::now() - chrono::Duration::hours(3)).to_rfc3339();
    inner
        .test_set_updated_at(mission.id, stale_at)
        .await
        .expect("updated_at should backdate");

    let (events_tx, _events_rx) = broadcast::channel(8);
    let (cmd_tx, _cmd_rx) = mpsc::channel(8);
    cleanup_stale_active_missions_once(&store, 2, &events_tx, &cmd_tx).await;

    let stored = store
        .get_mission(mission.id)
        .await
        .expect("mission lookup should succeed")
        .expect("mission should exist");
    assert_eq!(stored.status, MissionStatus::Active);
    let active_run = store
        .get_active_mission_run(mission.id)
        .await
        .expect("active run query should succeed")
        .expect("client run must remain active until the client settles it");
    assert_eq!(active_run.run_id, run.run_id);
}

#[tokio::test]
async fn cleanup_stale_active_missions_once_closes_untagged_stale_mission() {
    let inner = Arc::new(mission_store::InMemoryMissionStore::new());
    let store: Arc<dyn MissionStore> = inner.clone();
    let mission = store
        .create_mission(Some("untagged worker"), None, None, None, None, None, None)
        .await
        .expect("mission should be created");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("mission should become active");
    let stale_at = (chrono::Utc::now() - chrono::Duration::hours(3)).to_rfc3339();
    inner
        .test_set_updated_at(mission.id, stale_at)
        .await
        .expect("updated_at should backdate");

    let (events_tx, _events_rx) = broadcast::channel(8);
    let (cmd_tx, mut cmd_rx) = mpsc::channel(8);
    tokio::spawn(async move {
        if let Some(ControlCommand::CancelMission { respond, .. }) = cmd_rx.recv().await {
            let _ = respond.send(Ok(CancelMissionOutcome::NoRunner));
        }
    });
    cleanup_stale_active_missions_once(&store, 2, &events_tx, &cmd_tx).await;

    let stored = store
        .get_mission(mission.id)
        .await
        .expect("mission lookup should succeed")
        .expect("mission should exist");
    assert_eq!(stored.status, MissionStatus::Completed);
}

#[test]
fn test_parse_image_tag() {
    let tags = parse_rich_tags(r#"<image path="./chart.png" alt="My Chart" />"#);
    assert_eq!(tags.len(), 1);
    assert_eq!(tags[0].tag_type, RichTagType::Image);
    assert_eq!(tags[0].path, "./chart.png");
    assert_eq!(tags[0].alt.as_deref(), Some("My Chart"));
}

#[test]
fn test_parse_file_tag() {
    let tags = parse_rich_tags(r#"<file path="./report.pdf" name="Report" />"#);
    assert_eq!(tags.len(), 1);
    assert_eq!(tags[0].tag_type, RichTagType::File);
    assert_eq!(tags[0].path, "./report.pdf");
    assert_eq!(tags[0].name.as_deref(), Some("Report"));
}

#[test]
fn test_parse_multiple_tags() {
    let content = r#"Here is the chart:
<image path="./a.png" alt="A" />
And the report:
<file path="./b.pdf" name="B" />"#;
    let tags = parse_rich_tags(content);
    assert_eq!(tags.len(), 2);
    assert_eq!(tags[0].tag_type, RichTagType::Image);
    assert_eq!(tags[0].path, "./a.png");
    assert_eq!(tags[1].tag_type, RichTagType::File);
    assert_eq!(tags[1].path, "./b.pdf");
}

#[test]
fn test_parse_no_tags() {
    let tags = parse_rich_tags("Hello world, no tags here.");
    assert!(tags.is_empty());
}

#[test]
fn test_parse_malformed_tag() {
    // Unclosed tag should not match
    let tags = parse_rich_tags(r#"<image path="./chart.png" "#);
    assert!(tags.is_empty());
    // Missing path attribute
    let tags = parse_rich_tags(r#"<image alt="no path" />"#);
    assert!(tags.is_empty());
}

#[test]
fn test_strip_numeric_title_suffix() {
    assert_eq!(
        strip_numeric_title_suffix("Fix flaky CI (2)"),
        "Fix flaky CI"
    );
    assert_eq!(strip_numeric_title_suffix("Fix flaky CI"), "Fix flaky CI");
    assert_eq!(
        strip_numeric_title_suffix("Fix flaky CI (alpha)"),
        "Fix flaky CI (alpha)"
    );
}

#[test]
fn test_has_significant_metadata_drift_detects_minor_and_major_changes() {
    assert!(!has_significant_metadata_drift(
        "Fix the login redirect race",
        "Fix login redirect race"
    ));
    assert!(has_significant_metadata_drift(
        "Fix the login redirect race",
        "Investigate websocket reconnect failures"
    ));
}

#[test]
fn test_has_significant_metadata_drift_handles_unicode_equivalents() {
    assert!(!has_significant_metadata_drift(
        "Исправить сбой входа!",
        "исправить   сбой входа"
    ));
}

#[test]
fn test_is_near_duplicate_title_handles_plural_variant() {
    assert!(is_near_duplicate_title(
        "Fix flaky CI pipeline",
        "Fix flaky CI pipelines"
    ));
}

#[test]
fn test_is_near_duplicate_title_rejects_different_topic() {
    assert!(!is_near_duplicate_title(
        "Investigate API timeout on auth",
        "Refactor dashboard sidebar layout"
    ));
}

#[tokio::test]
async fn test_disambiguate_generated_title_appends_next_suffix() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let existing = store
        .create_mission(Some("Fix flaky CI"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .create_mission(Some("Fix flaky CI (2)"), None, None, None, None, None, None)
        .await
        .expect("create mission");

    let disambiguated = disambiguate_generated_title(&store, existing.id, "Fix flaky CI").await;
    assert_eq!(disambiguated, "Fix flaky CI (3)");
}

#[tokio::test]
async fn test_disambiguate_generated_title_scans_beyond_first_page() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    store
        .create_mission(
            Some("Need unique title"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create mission");

    let mut probe_id = Uuid::nil();
    for idx in 0..205 {
        let mission = store
            .create_mission(
                Some(&format!("Filler {}", idx)),
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .await
            .expect("create mission");
        if idx == 204 {
            probe_id = mission.id;
        }
    }

    let disambiguated = disambiguate_generated_title(&store, probe_id, "Need unique title").await;
    assert_eq!(disambiguated, "Need unique title (2)");
}

#[tokio::test]
async fn test_disambiguate_generated_title_handles_punctuation_only_titles() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let existing = store
        .create_mission(Some("!!!"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .create_mission(Some("!!! (2)"), None, None, None, None, None, None)
        .await
        .expect("create mission");

    let disambiguated = disambiguate_generated_title(&store, existing.id, "!!!").await;
    assert_eq!(disambiguated, "!!! (3)");
}

#[tokio::test]
async fn test_disambiguate_generated_title_handles_unicode_casefolding() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    store
        .create_mission(
            Some("Исправить сбой входа"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create mission");
    let probe = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");

    let disambiguated =
        disambiguate_generated_title(&store, probe.id, "ИСПРАВИТЬ СБОЙ ВХОДА").await;
    assert_eq!(disambiguated, "ИСПРАВИТЬ СБОЙ ВХОДА (2)");
}

#[tokio::test]
async fn test_disambiguate_generated_title_handles_near_duplicate_variants() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    store
        .create_mission(
            Some("Fix flaky CI pipeline"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create mission");
    let probe = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");

    let disambiguated =
        disambiguate_generated_title(&store, probe.id, "Fix flaky CI pipelines").await;
    assert_eq!(disambiguated, "Fix flaky CI pipelines (2)");
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_populates_short_description_from_first_message() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    let history = vec![("user".to_string(), "Hi".to_string())];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        Some("Hi"),
        false,
    )
    .await;

    assert_eq!(updated_title, None);
    assert_eq!(updated_short_description.as_deref(), Some("Hi"));
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_generates_title_after_first_assistant_reply() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    let history = vec![
        (
            "user".to_string(),
            "Investigate oauth callback timeout in production".to_string(),
        ),
        (
            "assistant".to_string(),
            "Investigate oauth callback timeout root cause\nStarting with logs.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(
        updated_title.as_deref(),
        Some("Investigate oauth callback timeout root cause")
    );
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Investigate oauth callback timeout root cause")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_bootstrap_title_uses_first_assistant_response() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    let history = vec![
        (
            "user".to_string(),
            "Investigate oauth callback timeout in production".to_string(),
        ),
        (
            "assistant".to_string(),
            "Initial root cause hypothesis: oauth callback host mismatch.".to_string(),
        ),
        (
            "assistant".to_string(),
            "Follow-up: retry timing also contributes to failures.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(
        updated_title.as_deref(),
        Some("Initial root cause hypothesis: oauth callback host mismatch.")
    );
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Initial root cause hypothesis: oauth callback host mismatch.")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_bootstrap_uses_first_successful_assistant_response()
{
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    let history = vec![
        (
            "user".to_string(),
            "Fix oauth callback failures on mobile safari".to_string(),
        ),
        (
            "assistant".to_string(),
            "Error: unable to complete analysis because logs are missing.".to_string(),
        ),
        (
            "assistant".to_string(),
            "Identified root cause: callback URL host mismatch in production.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(
        updated_title.as_deref(),
        Some("Identified root cause: callback URL host mismatch in production.")
    );
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Identified root cause: callback URL host mismatch in production.")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_waits_for_successful_assistant_before_bootstrap() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    let history = vec![
        (
            "user".to_string(),
            "Fix oauth callback failures on mobile safari".to_string(),
        ),
        (
            "assistant".to_string(),
            "Error: unable to complete analysis because logs are missing.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(updated_title, None);
    assert_eq!(updated_short_description, None);
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_does_not_overwrite_user_managed_title() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Initial title"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            None,
            None,
            Some(Some(METADATA_SOURCE_USER)),
            None,
            None,
        )
        .await
        .expect("mark title as user-managed");
    let mission = store
        .get_mission(mission.id)
        .await
        .expect("load mission")
        .expect("mission exists");
    let history = vec![
        ("user".to_string(), "Track flaky auth tests".to_string()),
        (
            "assistant".to_string(),
            "Auth test flakes are caused by parallel DB seed races.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, c)| c.as_str()),
        true,
    )
    .await;

    assert_eq!(updated_title, None);
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Auth test flakes are caused by parallel DB seed races.")
    );
}

#[tokio::test]
async fn test_refresh_mission_metadata_preserves_user_source_when_only_short_description_changes() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("User chosen title"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create mission");
    store
        .update_mission_title(mission.id, "User chosen title")
        .await
        .expect("mark title as user managed");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Investigate oauth callback timeout".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Root cause is stale oauth callback cache state across retries."
                        .to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, _events_rx) = broadcast::channel::<AgentEvent>(16);
    refresh_mission_metadata_for_milestone(&store, &events_tx, mission.id).await;

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(refreshed.title.as_deref(), Some("User chosen title"));
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Root cause is stale oauth callback cache state across retries.")
    );
    assert_eq!(
        refreshed.metadata_source.as_deref(),
        Some(METADATA_SOURCE_USER)
    );
    assert_eq!(
        refreshed.metadata_version.as_deref(),
        Some(METADATA_VERSION_V1)
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_prefers_assistant_short_description_when_title_exists(
) {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("Existing mission title"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create mission");
    let history = vec![
        ("user".to_string(), "Hi".to_string()),
        (
            "assistant".to_string(),
            "Investigate oauth callback timeout root cause and retry behavior.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(updated_title, None);
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Investigate oauth callback timeout root cause and retry behavior.")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_upgrades_existing_short_description_from_assistant()
{
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            None,
            Some(Some("Hi")),
            Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC)),
            None,
            Some(Some(METADATA_VERSION_V1)),
        )
        .await
        .expect("seed short description");
    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let history = vec![
        ("user".to_string(), "Hi".to_string()),
        (
            "assistant".to_string(),
            "Investigate oauth callback timeout root cause and retry behavior.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(
        updated_title.as_deref(),
        Some("Investigate oauth callback timeout root cause and retry behavior.")
    );
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Investigate oauth callback timeout root cause and retry behavior.")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_bootstrap_short_description_prefers_first_assistant_even_when_overlap_is_high(
) {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            None,
            Some(Some("Investigate oauth callback timeout root cause")),
            Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC)),
            None,
            Some(Some(METADATA_VERSION_V1)),
        )
        .await
        .expect("seed short description");
    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let history = vec![
        (
            "user".to_string(),
            "Investigate oauth callback timeout root cause".to_string(),
        ),
        (
            "assistant".to_string(),
            "Investigate oauth callback timeout root cause and retry behavior.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(
        updated_title.as_deref(),
        Some("Investigate oauth callback timeout root cause and retry behavior.")
    );
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Investigate oauth callback timeout root cause and retry behavior.")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_uses_recent_titles_as_negative_context() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    store
        .create_mission(
            Some("Fix login redirect"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create existing mission");
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create probe mission");
    let history = vec![
        (
            "user".to_string(),
            "Fix login redirect on mobile safari callback flow".to_string(),
        ),
        (
            "assistant".to_string(),
            "Fix login redirect\nI'll investigate auth callback handling.".to_string(),
        ),
    ];

    let (updated_title, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    assert_eq!(
        updated_title.as_deref(),
        Some("Fix login redirect - mobile safari callback flow")
    );
    assert_eq!(
        updated_short_description.as_deref(),
        Some("Fix login redirect")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_negative_context_scans_beyond_first_page() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    store
        .create_mission(
            Some("Fix login redirect"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create existing mission");

    for idx in 0..320 {
        store
            .create_mission(
                Some(&format!("Filler mission {}", idx)),
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .await
            .expect("create filler mission");
    }

    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create probe mission");
    let history = vec![
        (
            "user".to_string(),
            "Fix login redirect in admin callback flow for enterprise SSO".to_string(),
        ),
        (
            "assistant".to_string(),
            "Fix login redirect\nI'll investigate auth callback handling.".to_string(),
        ),
    ];

    let (updated_title, _) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;

    let updated_title = updated_title.expect("title should be generated");
    assert_ne!(updated_title, "Fix login redirect");
    assert!(
        updated_title.starts_with("Fix login redirect - admin callback flow"),
        "unexpected diversified title: {updated_title}"
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_refreshes_on_milestone_event() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Legacy title"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Legacy title")),
            Some(Some("Legacy short description")),
            Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC)),
            None,
            None,
        )
        .await
        .expect("seed metadata");
    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let history = vec![
        (
            "user".to_string(),
            "Investigate production timeout in payment worker".to_string(),
        ),
        ("assistant".to_string(), "Thanks, checking now.".to_string()),
        (
            "assistant".to_string(),
            "Investigate payment timeout root cause\nStarting with logs.".to_string(),
        ),
    ];

    let without_milestone = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        false,
    )
    .await;
    assert_eq!(without_milestone, (None, None));

    let with_milestone = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        true,
    )
    .await;
    assert_eq!(
        with_milestone.0.as_deref(),
        Some("Investigate payment timeout root cause")
    );
    assert_eq!(
        with_milestone.1.as_deref(),
        Some("Investigate payment timeout root cause")
    );
}

#[tokio::test]
async fn test_generate_mission_metadata_updates_refresh_uses_recent_conversational_short_description(
) {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Legacy title"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Legacy title")),
            Some(Some("Legacy short description")),
            Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC)),
            None,
            None,
        )
        .await
        .expect("seed metadata");
    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let history = vec![
        (
            "user".to_string(),
            "Start by auditing invoice retry failures in webhook processing.".to_string(),
        ),
        (
            "assistant".to_string(),
            "Acknowledged. I'll inspect the retry pipeline first.".to_string(),
        ),
        (
            "user".to_string(),
            "Check current retry backoff settings.".to_string(),
        ),
        (
            "assistant".to_string(),
            "Backoff settings retrieved from worker config.".to_string(),
        ),
        (
            "user".to_string(),
            "Look at dead-letter queue behavior next.".to_string(),
        ),
        (
            "assistant".to_string(),
            "Dead-letter queue is receiving retries after max attempts.".to_string(),
        ),
        (
            "user".to_string(),
            "Confirm alerting on repeated failures.".to_string(),
        ),
        (
            "assistant".to_string(),
            "Current alerts only trigger on total outage.".to_string(),
        ),
        (
            "user".to_string(),
            "Propose what we should change.".to_string(),
        ),
        (
            "assistant".to_string(),
            "Finalize webhook retry policy with staged backoff and failure alert routing."
                .to_string(),
        ),
    ];

    let (_, updated_short_description) = generate_mission_metadata_updates(
        &store,
        mission.id,
        &mission,
        &history,
        history.first().map(|(_, content)| content.as_str()),
        true,
    )
    .await;

    assert_eq!(
        updated_short_description.as_deref(),
        Some("Finalize webhook retry policy with staged backoff and failure alert routing.")
    );
}

#[tokio::test]
async fn test_refresh_mission_metadata_for_milestone_updates_store_and_emits_event() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let model_override = "openai/gpt-5";
    let mission = store
        .create_mission(
            Some("Legacy title"),
            None,
            None,
            Some(model_override),
            None,
            None,
            None,
        )
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Legacy title")),
            Some(Some("Legacy short description")),
            Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC)),
            None,
            None,
        )
        .await
        .expect("seed metadata");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Investigate oauth callback timeout".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content:
                        "Investigate oauth callback timeout root cause\nStarting with ingress logs."
                            .to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    refresh_mission_metadata_for_milestone(&store, &events_tx, mission.id).await;

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(
        refreshed.title.as_deref(),
        Some("Investigate oauth callback timeout root cause")
    );
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Investigate oauth callback timeout root cause")
    );
    assert_eq!(
        refreshed.metadata_source.as_deref(),
        Some(METADATA_SOURCE_BACKEND_HEURISTIC)
    );
    assert_eq!(
        refreshed.metadata_version.as_deref(),
        Some(METADATA_VERSION_V1)
    );
    assert_eq!(refreshed.metadata_model.as_deref(), Some(model_override));

    let mut saw_metadata_event = false;
    while let Ok(event) = events_rx.try_recv() {
        if let AgentEvent::MissionMetadataUpdated {
            mission_id,
            metadata_model,
            updated_at,
            ..
        } = event
        {
            if mission_id == mission.id {
                assert_eq!(metadata_model.as_deref(), Some(model_override));
                assert_eq!(updated_at.as_deref(), Some(refreshed.updated_at.as_str()));
                saw_metadata_event = true;
                break;
            }
        }
    }
    assert!(
        saw_metadata_event,
        "expected mission_metadata_updated event"
    );
}

#[tokio::test]
async fn test_schedule_mission_metadata_refresh_for_milestone_updates_store_and_emits_event() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Legacy title"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Legacy title")),
            Some(Some("Legacy short description")),
            Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC)),
            None,
            None,
        )
        .await
        .expect("seed metadata");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Investigate websocket reconnect loop".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Investigate websocket reconnect loop root cause".to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    schedule_mission_metadata_refresh_for_milestone(&store, &events_tx, mission.id);

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .expect("timed out waiting for metadata refresh event");
    assert!(
        saw_metadata_event,
        "expected mission_metadata_updated event"
    );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(
        refreshed.title.as_deref(),
        Some("Investigate websocket reconnect loop root cause")
    );
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Investigate websocket reconnect loop root cause")
    );
}

#[tokio::test]
async fn test_maybe_schedule_mission_metadata_refresh_for_status_forces_terminal_statuses() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Legacy title"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Legacy title")),
            Some(Some("Legacy short description")),
            Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC)),
            None,
            None,
        )
        .await
        .expect("seed metadata");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Investigate websocket reconnect loop".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Checking ingress timeout settings".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Investigate websocket reconnect loop root cause".to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    maybe_schedule_mission_metadata_refresh_for_status(
        &store,
        &events_tx,
        mission.id,
        MissionStatus::Completed,
    );

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .expect("timed out waiting for metadata refresh event");
    assert!(
        saw_metadata_event,
        "expected mission_metadata_updated event"
    );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(
        refreshed.title.as_deref(),
        Some("Investigate websocket reconnect loop root cause")
    );
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Investigate websocket reconnect loop root cause")
    );
}

#[tokio::test]
async fn test_maybe_schedule_mission_metadata_refresh_for_status_skips_non_milestone_statuses() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("Existing mission title"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Existing mission title")),
            Some(Some("Existing mission short description")),
            None,
            None,
            None,
        )
        .await
        .expect("seed metadata");
    let seeded = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let seeded_updated_at = seeded
        .metadata_updated_at
        .clone()
        .expect("seed metadata timestamp");

    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Investigate websocket reconnect loop".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Investigate websocket reconnect loop root cause".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Collecting additional traces".to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    maybe_schedule_mission_metadata_refresh_for_status(
        &store,
        &events_tx,
        mission.id,
        MissionStatus::Active,
    );

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_millis(250), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(
        !saw_metadata_event,
        "did not expect metadata refresh for non-milestone status"
    );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(refreshed.title.as_deref(), Some("Existing mission title"));
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Existing mission short description")
    );
    assert_eq!(
        refreshed.metadata_updated_at.as_deref(),
        Some(seeded_updated_at.as_str())
    );
}

#[tokio::test]
async fn test_schedule_mission_metadata_refresh_updates_store_without_force_refresh() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Investigate websocket reconnect loop".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Investigate websocket reconnect loop root cause".to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    schedule_mission_metadata_refresh(&store, &events_tx, mission.id, false);

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .expect("timed out waiting for metadata refresh event");
    assert!(
        saw_metadata_event,
        "expected mission_metadata_updated event"
    );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(
        refreshed.title.as_deref(),
        Some("Investigate websocket reconnect loop root cause")
    );
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Investigate websocket reconnect loop root cause")
    );
}

#[tokio::test]
async fn test_persist_mission_history_and_schedule_metadata_refresh_emits_metadata_update() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    let entries = vec![
        MissionHistoryEntry {
            role: "user".to_string(),
            content: "Debug websocket reconnect loop".to_string(),
        },
        MissionHistoryEntry {
            role: "assistant".to_string(),
            content: "Root cause is stale session token refresh ordering".to_string(),
        },
    ];

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    persist_mission_history_and_schedule_metadata_refresh(&store, &events_tx, mission.id, &entries)
        .await;

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .expect("timed out waiting for metadata refresh event");
    assert!(
        saw_metadata_event,
        "expected mission_metadata_updated event"
    );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(
        refreshed.title.as_deref(),
        Some("Root cause is stale session token refresh ordering")
    );
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Root cause is stale session token refresh ordering")
    );
}

#[tokio::test]
async fn test_schedule_mission_metadata_refresh_skips_non_cadence_updates_without_force_refresh() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Existing mission title")),
            Some(Some("Existing mission short description")),
            None,
            None,
            None,
        )
        .await
        .expect("seed metadata");
    let seeded = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let seeded_updated_at = seeded
        .metadata_updated_at
        .clone()
        .expect("seed metadata timestamp");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Initial request".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Initial response".to_string(),
                },
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Follow-up request".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Refined response".to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    schedule_mission_metadata_refresh(&store, &events_tx, mission.id, false);

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_millis(300), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(
        !saw_metadata_event,
        "metadata refresh should not run before cadence threshold when force_refresh is false"
    );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(refreshed.title.as_deref(), Some("Existing mission title"));
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Existing mission short description")
    );
    assert_eq!(
        refreshed.metadata_updated_at.as_deref(),
        Some(seeded_updated_at.as_str())
    );
}

#[tokio::test]
async fn test_schedule_mission_metadata_refresh_ignores_non_conversational_entries_for_cadence() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Existing mission title")),
            Some(Some("Existing mission short description")),
            None,
            None,
            None,
        )
        .await
        .expect("seed metadata");
    let seeded = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let seeded_updated_at = seeded
        .metadata_updated_at
        .clone()
        .expect("seed metadata timestamp");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Initial request".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Initial response".to_string(),
                },
                MissionHistoryEntry {
                    role: "tool".to_string(),
                    content: "tool_call: inspect logs".to_string(),
                },
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Follow-up request".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Follow-up response".to_string(),
                },
                MissionHistoryEntry {
                    role: "tool".to_string(),
                    content: "tool_result: log output".to_string(),
                },
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Investigate retries".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Retries are triggered by 502s".to_string(),
                },
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "Patch retry jitter".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "Added jitter and bounded retries".to_string(),
                },
            ],
        )
        .await
        .expect("seed history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    schedule_mission_metadata_refresh(&store, &events_tx, mission.id, false);

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_millis(300), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(
            !saw_metadata_event,
            "metadata refresh should not run when only non-conversational entries push history length to cadence boundary"
        );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(refreshed.title.as_deref(), Some("Existing mission title"));
    assert_eq!(
        refreshed.short_description.as_deref(),
        Some("Existing mission short description")
    );
    assert_eq!(
        refreshed.metadata_updated_at.as_deref(),
        Some(seeded_updated_at.as_str())
    );
}

#[tokio::test]
async fn test_schedule_mission_metadata_refresh_uses_last_refresh_baseline_not_global_modulo() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Legacy title"), None, None, None, None, None, None)
        .await
        .expect("create mission");

    let mut history: Vec<MissionHistoryEntry> = Vec::new();
    for idx in 0..27 {
        let role = if idx % 2 == 0 { "user" } else { "assistant" };
        history.push(MissionHistoryEntry {
            role: role.to_string(),
            content: format!("history entry {}", idx),
        });
    }
    store
        .update_mission_history(mission.id, &history)
        .await
        .expect("seed history");

    let (forced_events_tx, _forced_events_rx) = broadcast::channel::<AgentEvent>(16);
    refresh_mission_metadata_for_milestone(&store, &forced_events_tx, mission.id).await;

    let after_forced = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    let forced_timestamp = after_forced
        .metadata_updated_at
        .clone()
        .expect("forced refresh should set metadata timestamp");

    for idx in 27..30 {
        let role = if idx % 2 == 0 { "user" } else { "assistant" };
        history.push(MissionHistoryEntry {
            role: role.to_string(),
            content: format!("post-forced history entry {}", idx),
        });
    }
    store
        .update_mission_history(mission.id, &history)
        .await
        .expect("update history");

    let (events_tx, mut events_rx) = broadcast::channel::<AgentEvent>(16);
    schedule_mission_metadata_refresh(&store, &events_tx, mission.id, false);

    let saw_metadata_event = tokio::time::timeout(std::time::Duration::from_millis(300), async {
        loop {
            match events_rx.recv().await {
                Ok(AgentEvent::MissionMetadataUpdated { mission_id, .. })
                    if mission_id == mission.id =>
                {
                    break true;
                }
                Ok(_) => continue,
                Err(_) => break false,
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(
        !saw_metadata_event,
        "metadata refresh should not run only 3 conversational turns after a forced refresh"
    );

    let refreshed = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(
        refreshed.metadata_updated_at.as_deref(),
        Some(forced_timestamp.as_str())
    );
}

#[tokio::test]
async fn test_should_refresh_metadata_by_cadence_rebases_when_history_is_rewritten_shorter() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Existing mission"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Existing mission")),
            Some(Some("Existing short description")),
            None,
            None,
            None,
        )
        .await
        .expect("seed metadata");
    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");

    clear_mission_metadata_refresh_state(mission.id);

    assert!(!should_refresh_metadata_by_cadence(
        mission.id, &mission, 24, false
    ));
    assert!(!should_refresh_metadata_by_cadence(
        mission.id, &mission, 4, false
    ));
    assert!(!should_refresh_metadata_by_cadence(
        mission.id, &mission, 13, false
    ));
    assert!(should_refresh_metadata_by_cadence(
        mission.id, &mission, 14, false
    ));

    clear_mission_metadata_refresh_state(mission.id);
}

#[tokio::test]
async fn test_record_metadata_refresh_baseline_from_mission_rebases_manual_title_updates() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Existing mission"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_history(
            mission.id,
            &[
                MissionHistoryEntry {
                    role: "user".to_string(),
                    content: "one".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "two".to_string(),
                },
                MissionHistoryEntry {
                    role: "tool".to_string(),
                    content: "{}".to_string(),
                },
                MissionHistoryEntry {
                    role: "assistant".to_string(),
                    content: "three".to_string(),
                },
            ],
        )
        .await
        .expect("seed history");
    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Existing mission")),
            Some(Some("Existing short description")),
            None,
            None,
            None,
        )
        .await
        .expect("seed metadata");
    let mission = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");

    clear_mission_metadata_refresh_state(mission.id);
    record_metadata_refresh_baseline(mission.id, 0);

    record_metadata_refresh_baseline_from_mission(mission.id, &mission);

    assert!(!should_refresh_metadata_by_cadence(
        mission.id, &mission, 11, false
    ));
    assert!(!should_refresh_metadata_by_cadence(
        mission.id, &mission, 12, false
    ));
    assert!(should_refresh_metadata_by_cadence(
        mission.id, &mission, 13, false
    ));

    clear_mission_metadata_refresh_state(mission.id);
}

#[tokio::test]
async fn test_register_metadata_refresh_task_replaces_existing_task_for_same_mission() {
    let mission_id = Uuid::new_v4();
    let mut tasks: HashMap<Uuid, MetadataRefreshTaskEntry> = HashMap::new();

    let first = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let first_task_id = first.id();
    let registration = register_metadata_refresh_task(&mut tasks, mission_id, false, 1, first);
    assert!(registration.superseded.is_none());
    assert_eq!(tasks.len(), 1);
    assert_eq!(
        tasks.get(&mission_id).map(|entry| entry.handle.id()),
        Some(first_task_id)
    );

    let second = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let second_task_id = second.id();
    let registration = register_metadata_refresh_task(&mut tasks, mission_id, false, 2, second);
    let replaced = registration
        .superseded
        .expect("expected previous task to be replaced");
    assert_eq!(replaced.id(), first_task_id);
    replaced.abort();

    assert_eq!(tasks.len(), 1);
    assert_eq!(
        tasks.get(&mission_id).map(|entry| entry.handle.id()),
        Some(second_task_id)
    );

    if let Some(active) = tasks.remove(&mission_id) {
        active.handle.abort();
    }
}

#[tokio::test]
async fn test_register_metadata_refresh_task_keeps_in_flight_forced_task_over_non_forced() {
    let mission_id = Uuid::new_v4();
    let mut tasks: HashMap<Uuid, MetadataRefreshTaskEntry> = HashMap::new();

    let forced = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let forced_task_id = forced.id();
    let forced_registration =
        register_metadata_refresh_task(&mut tasks, mission_id, true, 1, forced);
    assert!(forced_registration.superseded.is_none());

    let non_forced = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let non_forced_task_id = non_forced.id();
    let non_forced_registration =
        register_metadata_refresh_task(&mut tasks, mission_id, false, 2, non_forced);
    let rejected = non_forced_registration
        .superseded
        .expect("new non-forced task should be rejected");
    assert_eq!(rejected.id(), non_forced_task_id);
    rejected.abort();

    assert_eq!(tasks.len(), 1);
    assert_eq!(
        tasks.get(&mission_id).map(|entry| entry.handle.id()),
        Some(forced_task_id)
    );
    assert!(tasks
        .get(&mission_id)
        .is_some_and(|entry| entry.force_refresh));

    if let Some(active) = tasks.remove(&mission_id) {
        active.handle.abort();
    }
}

#[tokio::test]
async fn test_register_metadata_refresh_task_forced_replaces_non_forced() {
    let mission_id = Uuid::new_v4();
    let mut tasks: HashMap<Uuid, MetadataRefreshTaskEntry> = HashMap::new();

    let non_forced = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let non_forced_task_id = non_forced.id();
    let non_forced_registration =
        register_metadata_refresh_task(&mut tasks, mission_id, false, 1, non_forced);
    assert!(non_forced_registration.superseded.is_none());

    let forced = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let forced_task_id = forced.id();
    let forced_registration =
        register_metadata_refresh_task(&mut tasks, mission_id, true, 2, forced);
    let replaced = forced_registration
        .superseded
        .expect("existing non-forced task should be replaced");
    assert_eq!(replaced.id(), non_forced_task_id);
    replaced.abort();

    assert_eq!(tasks.len(), 1);
    assert_eq!(
        tasks.get(&mission_id).map(|entry| entry.handle.id()),
        Some(forced_task_id)
    );
    assert!(tasks
        .get(&mission_id)
        .is_some_and(|entry| entry.force_refresh));

    if let Some(active) = tasks.remove(&mission_id) {
        active.handle.abort();
    }
}

#[tokio::test]
async fn test_should_skip_metadata_refresh_schedule_rejects_non_forced_when_forced_in_flight() {
    let mission_id = Uuid::new_v4();
    let mut tasks: HashMap<Uuid, MetadataRefreshTaskEntry> = HashMap::new();

    let forced = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let registration = register_metadata_refresh_task(&mut tasks, mission_id, true, 1, forced);
    assert!(registration.superseded.is_none());

    assert!(should_skip_metadata_refresh_schedule(
        &mut tasks, mission_id, false
    ));
    assert!(!should_skip_metadata_refresh_schedule(
        &mut tasks, mission_id, true
    ));

    if let Some(active) = tasks.remove(&mission_id) {
        active.handle.abort();
    }
}

#[tokio::test]
async fn test_should_skip_metadata_refresh_schedule_drops_finished_tasks() {
    let mission_id = Uuid::new_v4();
    let mut tasks: HashMap<Uuid, MetadataRefreshTaskEntry> = HashMap::new();

    let finished = tokio::spawn(async {});
    let registration = register_metadata_refresh_task(&mut tasks, mission_id, true, 1, finished);
    assert!(registration.superseded.is_none());
    tokio::task::yield_now().await;

    assert!(!should_skip_metadata_refresh_schedule(
        &mut tasks, mission_id, false
    ));
    assert!(tasks.is_empty());
}

#[tokio::test]
async fn test_complete_metadata_refresh_task_only_removes_matching_generation() {
    let mission_id = Uuid::new_v4();
    let mut tasks: HashMap<Uuid, MetadataRefreshTaskEntry> = HashMap::new();

    let task = tokio::spawn(async {});
    let registration = register_metadata_refresh_task(&mut tasks, mission_id, false, 42, task);
    assert!(registration.superseded.is_none());
    assert_eq!(tasks.len(), 1);

    complete_metadata_refresh_task(&mut tasks, mission_id, 41);
    assert_eq!(tasks.len(), 1);

    complete_metadata_refresh_task(&mut tasks, mission_id, 42);
    assert!(tasks.is_empty());
}

#[tokio::test]
async fn test_clear_mission_metadata_refresh_state_removes_task_and_baseline() {
    let _guard = metadata_refresh_test_guard().await;
    let mission_id = Uuid::new_v4();
    let other_mission_id = Uuid::new_v4();

    clear_mission_metadata_refresh_state(mission_id);

    let task = tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });

    {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        tasks.insert(
            mission_id,
            MetadataRefreshTaskEntry {
                handle: task,
                force_refresh: false,
                task_id: 1,
            },
        );
        tasks.insert(
            other_mission_id,
            MetadataRefreshTaskEntry {
                handle: tokio::spawn(async {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }),
                force_refresh: false,
                task_id: 2,
            },
        );
    }

    {
        let mut baselines = MISSION_METADATA_REFRESH_BASELINES
            .lock()
            .expect("metadata refresh baseline lock poisoned");
        baselines.insert(mission_id, 10);
        baselines.insert(other_mission_id, 20);
    }

    clear_mission_metadata_refresh_state(mission_id);

    {
        let tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        assert!(!tasks.contains_key(&mission_id));
        assert!(tasks.contains_key(&other_mission_id));
    }
    {
        let baselines = MISSION_METADATA_REFRESH_BASELINES
            .lock()
            .expect("metadata refresh baseline lock poisoned");
        assert!(!baselines.contains_key(&mission_id));
        assert_eq!(baselines.get(&other_mission_id), Some(&20usize));
    }

    clear_mission_metadata_refresh_state(other_mission_id);
}

#[tokio::test]
async fn test_clear_stale_mission_metadata_refresh_state_prunes_deleted_missions() {
    let _guard = metadata_refresh_test_guard().await;
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());

    let deleted_mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create deleted mission");
    let existing_mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create existing mission");

    let deleted_task = tokio::spawn(std::future::pending::<()>());
    let existing_task = tokio::spawn(std::future::pending::<()>());

    {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        tasks.insert(
            deleted_mission.id,
            MetadataRefreshTaskEntry {
                task_id: 1,
                force_refresh: false,
                handle: deleted_task,
            },
        );
        tasks.insert(
            existing_mission.id,
            MetadataRefreshTaskEntry {
                task_id: 2,
                force_refresh: false,
                handle: existing_task,
            },
        );

        let mut baselines = MISSION_METADATA_REFRESH_BASELINES
            .lock()
            .expect("metadata refresh baseline lock poisoned");
        baselines.insert(deleted_mission.id, 10);
        baselines.insert(existing_mission.id, 20);
    }

    store
        .delete_mission(deleted_mission.id)
        .await
        .expect("delete mission should succeed");

    clear_stale_mission_metadata_refresh_state(&store).await;

    {
        let tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        assert!(!tasks.contains_key(&deleted_mission.id));
        assert!(tasks.contains_key(&existing_mission.id));
    }

    {
        let baselines = MISSION_METADATA_REFRESH_BASELINES
            .lock()
            .expect("metadata refresh baseline lock poisoned");
        assert!(!baselines.contains_key(&deleted_mission.id));
        assert_eq!(baselines.get(&existing_mission.id), Some(&20usize));
    }

    clear_mission_metadata_refresh_state(existing_mission.id);
}

#[test]
fn test_mission_metadata_updated_event_serializes_explicit_null_clears() {
    let mission_id = Uuid::new_v4();
    let event = AgentEvent::MissionMetadataUpdated {
        mission_id,
        title: None,
        short_description: Some("Investigate timeout path".to_string()),
        metadata_updated_at: None,
        updated_at: None,
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
    };

    let value = serde_json::to_value(event).expect("serialize mission metadata event");
    assert_eq!(
        value.get("type").and_then(|v| v.as_str()),
        Some("mission_metadata_updated")
    );
    assert!(value.get("title").is_some(), "title key should be present");
    assert!(value.get("title").is_some_and(serde_json::Value::is_null));
    assert_eq!(
        value.get("short_description").and_then(|v| v.as_str()),
        Some("Investigate timeout path")
    );
    assert!(
        value
            .get("metadata_updated_at")
            .is_some_and(serde_json::Value::is_null),
        "metadata_updated_at key should be present as null when cleared"
    );
    assert!(
        value
            .get("updated_at")
            .is_some_and(serde_json::Value::is_null),
        "updated_at key should be present as null when not provided"
    );
}

#[test]
fn test_extract_short_description_from_history_allows_short_messages() {
    let history = vec![("user".to_string(), "Hi".to_string())];
    let extracted = extract_short_description_from_history(&history, 160);
    assert_eq!(extracted.as_deref(), Some("Hi"));
}

#[test]
fn terminal_verdict_prefers_explicit_blocked_over_optimistic_body() {
    let content = "Final decision: **BLOCKED** on exact head abc.\n\nAll existing builds pass.";
    assert_eq!(terminal_verdict_from_content(content), Some("blocked"));
    assert_eq!(
        terminal_verdict_description("blocked"),
        "VERDICT: BLOCKED — exact-head review reported unresolved blockers."
    );
}

#[test]
fn terminal_verdict_does_not_treat_historical_mentions_as_current() {
    let content =
        "Review complete. The prior certifier was BLOCKED, but this head still needs analysis.";
    assert_eq!(terminal_verdict_from_content(content), None);
}

#[test]
fn terminal_verdict_recognizes_clean_contract() {
    assert_eq!(
        terminal_verdict_from_content("VERDICT: CLEAN\nExact head verified."),
        Some("clean")
    );
}

#[test]
fn test_extract_short_description_from_history_skips_fenced_code_blocks() {
    let history = vec![(
        "user".to_string(),
        "```rust\nfn main() {}\n```\nInvestigate rust build failure".to_string(),
    )];
    let extracted = extract_short_description_from_history(&history, 160);
    assert_eq!(extracted.as_deref(), Some("Investigate rust build failure"));
}

#[test]
fn test_extract_short_description_from_history_returns_none_for_code_only_message() {
    let history = vec![("user".to_string(), "```bash\necho test\n```".to_string())];
    let extracted = extract_short_description_from_history(&history, 160);
    assert_eq!(extracted, None);
}

#[test]
fn test_extract_short_description_from_history_skips_tilde_fenced_code_blocks() {
    let history = vec![(
        "user".to_string(),
        "~~~python\nprint('hi')\n~~~\nDescribe retry strategy".to_string(),
    )];
    let extracted = extract_short_description_from_history(&history, 160);
    assert_eq!(extracted.as_deref(), Some("Describe retry strategy"));
}

#[test]
fn test_extract_short_description_from_history_handles_unclosed_fence() {
    let history = vec![(
        "user".to_string(),
        "```markdown\nInvestigate flaky CI timeout".to_string(),
    )];
    let extracted = extract_short_description_from_history(&history, 160);
    assert_eq!(extracted.as_deref(), Some("Investigate flaky CI timeout"));
}

#[test]
fn test_extract_short_description_from_history_strips_markdown_prefixes() {
    let history = vec![(
        "user".to_string(),
        "## > - * 1. Investigate flaky CI timeout".to_string(),
    )];
    let extracted = extract_short_description_from_history(&history, 160);
    assert_eq!(extracted.as_deref(), Some("Investigate flaky CI timeout"));
}

#[test]
fn test_extract_short_description_from_history_strips_ordered_list_markers() {
    let history = vec![(
        "user".to_string(),
        "12) Resolve dashboard state drift".to_string(),
    )];
    let extracted = extract_short_description_from_history(&history, 160);
    assert_eq!(extracted.as_deref(), Some("Resolve dashboard state drift"));
}

#[test]
fn test_extract_title_from_assistant_skips_fenced_code_blocks() {
    let title =
        extract_title_from_assistant("```rust\nfn main() {}\n```\nFix flaky CI timeout handling");
    assert_eq!(title.as_deref(), Some("Fix flaky CI timeout handling"));
}

#[test]
fn test_extract_title_from_assistant_returns_none_for_code_only_message() {
    let title = extract_title_from_assistant("```bash\necho test\n```");
    assert_eq!(title, None);
}

#[test]
fn test_extract_title_from_assistant_skips_tilde_fenced_code_blocks() {
    let title = extract_title_from_assistant("~~~json\n{\"ok\":true}\n~~~\n# Final status summary");
    assert_eq!(title.as_deref(), Some("Final status summary"));
}

#[test]
fn test_normalize_model_effort_accepts_supported_values() {
    assert_eq!(normalize_model_effort("low"), Some("low".to_string()));
    assert_eq!(
        normalize_model_effort(" Medium "),
        Some("medium".to_string())
    );
    assert_eq!(normalize_model_effort("HIGH"), Some("high".to_string()));
    assert_eq!(normalize_model_effort("xhigh"), Some("xhigh".to_string()));
    assert_eq!(normalize_model_effort("MAX"), Some("max".to_string()));
}

#[test]
fn test_normalize_model_effort_for_backend_accepts_codex_max() {
    assert_eq!(
        normalize_model_effort_for_backend(Some("codex"), "high"),
        Some("high".to_string())
    );
    assert_eq!(
        normalize_model_effort_for_backend(Some("codex"), "max"),
        Some("max".to_string())
    );
    assert_eq!(
        normalize_model_effort_for_backend(Some("claudecode"), "max"),
        Some("max".to_string())
    );
}

#[test]
fn test_normalize_model_effort_rejects_invalid_values() {
    assert_eq!(normalize_model_effort(""), None);
    assert_eq!(normalize_model_effort("turbo"), None);
}

#[test]
fn test_normalize_model_override_for_backend_keeps_provider_prefix_for_opencode() {
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), " openai/gpt-5-codex "),
        Some("openai/gpt-5-codex".to_string())
    );
}

#[test]
fn test_normalize_model_override_for_backend_maps_legacy_kimi_aliases() {
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), "kimi-k3"),
        Some("kimi/k3".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), " KIMI-K3-256K "),
        Some("kimi/k3-256k".to_string())
    );
}

#[test]
fn test_normalize_model_override_for_backend_maps_muse_spark_onto_meta() {
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), "muse-spark-1.2"),
        Some("meta/muse-spark-1.2".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), "muse/muse-spark-1.2"),
        Some("meta/muse-spark-1.2".to_string())
    );
}

#[test]
fn test_normalize_model_override_for_backend_maps_bare_grok_onto_xai() {
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), "grok-4.6"),
        Some("xai/grok-4.6".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), "xai/grok-4.6"),
        Some("xai/grok-4.6".to_string())
    );
    // Native grok backend keeps the bare CLI id.
    assert_eq!(
        normalize_model_override_for_backend(Some("grok"), "grok-4.6"),
        Some("grok-4.6".to_string())
    );
}

#[test]
fn test_normalize_model_override_for_backend_strips_provider_prefix_for_non_opencode() {
    assert_eq!(
        normalize_model_override_for_backend(Some("codex"), "openai/gpt-5-codex"),
        Some("gpt-5-codex".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("claudecode"), "anthropic/claude-opus-4-7"),
        Some("claude-opus-4-7".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("claudecode"), "anthropic/claude-opus-4-8"),
        Some("claude-opus-4-8".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("codex"), "   "),
        None
    );
}

#[test]
fn claudecode_default_is_opus_5_and_upgrades_legacy_opus_48() {
    assert_eq!(
        crate::library::normalize_claude_code_default_model(None),
        "claude-opus-5"
    );
    assert_eq!(
        crate::library::normalize_claude_code_default_model(Some("claude-opus-4-8".to_string())),
        "claude-opus-5"
    );
    assert_eq!(
        crate::library::normalize_claude_code_default_model(Some(
            "anthropic/claude-opus-4.8".to_string()
        )),
        "claude-opus-5"
    );
    assert_eq!(
        crate::library::normalize_claude_code_default_model(Some("claude-sonnet-5".to_string())),
        "claude-sonnet-5"
    );
}

#[test]
fn test_normalize_model_override_for_codex_maps_gpt_56_alias_to_sol() {
    assert_eq!(
        normalize_model_override_for_backend(Some("codex"), "gpt-5.6"),
        Some("gpt-5.6-sol".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("codex"), "openai/gpt-5.6"),
        Some("gpt-5.6-sol".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("codex"), "gpt-6"),
        Some("gpt-6-astra".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("codex"), "openai/gpt-6"),
        Some("gpt-6-astra".to_string())
    );
    assert_eq!(resolve_codex_default_model(), "gpt-6.1-sol");
    assert_eq!(
        normalize_model_override_for_backend(Some("opencode"), "openai/gpt-5.6"),
        Some("openai/gpt-5.6".to_string())
    );
    assert_eq!(
        normalize_model_override_for_backend(Some("codex"), "codex/gpt-5.6-terra"),
        Some("gpt-5.6-terra".to_string())
    );
}

fn board_task_with_backend_and_model(backend: &str, model: &str) -> NewBoardTask {
    NewBoardTask {
        task_key: "model-check".to_string(),
        title: "Model check".to_string(),
        prompt: "Verify board model validation".to_string(),
        backend: backend.to_string(),
        model_override: Some(model.to_string()),
        model_effort: None,
        working_directory: None,
        repository: None,
        branch: None,
        depends_on: Vec::new(),
        ..Default::default()
    }
}

#[tokio::test]
async fn board_upsert_rejects_native_model_backend_mismatch_without_persisting() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let boss_id = Uuid::new_v4();
    let mut tasks = vec![board_task_with_backend_and_model(
        "grok",
        "codex/gpt-5.6-terra",
    )];

    let result = validate_and_normalize_board_tasks(&mut tasks);
    if result.is_ok() {
        store.upsert_board_tasks(boss_id, tasks).await.unwrap();
    }

    let (status, error) = result.expect_err("mismatched native backend must be rejected");
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(error.contains("task `model-check`"));
    assert!(error.contains("codex"));
    assert!(error.contains("grok"));
    assert!(store.list_board_tasks(boss_id).await.unwrap().is_empty());
}

#[test]
fn retired_gemini_board_task_is_rejected_at_registration() {
    let mut tasks = vec![board_task_with_backend_and_model("gemini", "old-model")];
    let (status, error) = validate_and_normalize_board_tasks(&mut tasks).unwrap_err();
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(error.contains("agy models"));
}

#[test]
fn board_upsert_normalizes_matching_native_model_backend_prefix() {
    let mut tasks = vec![board_task_with_backend_and_model(
        "codex",
        "codex/gpt-5.6-terra",
    )];

    validate_and_normalize_board_tasks(&mut tasks).unwrap();

    assert_eq!(tasks[0].model_override.as_deref(), Some("gpt-5.6-terra"));
}

#[test]
fn test_native_backend_prefix_only_accepts_harness_qualifiers() {
    assert_eq!(native_backend_prefix("codex/gpt-5.6-terra"), Some("codex"));
    assert_eq!(
        native_backend_prefix("claudecode/claude-opus-4-7"),
        Some("claudecode")
    );
    assert_eq!(native_backend_prefix("openai/gpt-5.6-terra"), None);
    assert_eq!(native_backend_prefix("codex/"), None);
}

#[test]
fn fast_mode_accepts_supported_codex_models_only() {
    assert!(validate_fast_mode("codex", Some("gpt-5.6-sol"), true).is_ok());
    assert!(validate_fast_mode("codex", Some("gpt-5.5"), true).is_ok());
    assert!(validate_fast_mode("codex", Some("gpt-5.4-mini"), true).is_ok());
    let missing = validate_fast_mode("codex", None, true).unwrap_err();
    assert!(missing.contains("Codex default"), "{missing}");
    assert!(missing.contains("model_override"), "{missing}");
    assert!(validate_fast_mode("claudecode", Some("gpt-5.6-sol"), true).is_err());
    assert!(validate_fast_mode("codex", Some("gpt-5.3-codex"), true).is_err());
    assert!(validate_fast_mode("codex", Some("gpt-5.3-codex"), false).is_ok());
}

#[test]
fn test_native_backend_agent_only_accepts_native_harness_names() {
    assert_eq!(native_backend_agent("codex"), Some("codex"));
    assert_eq!(native_backend_agent(" Codex "), Some("codex"));
    assert_eq!(native_backend_agent("claudecode"), Some("claudecode"));
    assert_eq!(native_backend_agent("antigravity"), Some("antigravity"));
    assert_eq!(native_backend_agent("grok"), Some("grok"));
    assert_eq!(native_backend_agent("build"), None);
    assert_eq!(native_backend_agent("plan"), None);
    assert_eq!(native_backend_agent("opencode"), None);
}

#[test]
fn native_backend_agent_selector_is_consumed_for_native_harnesses() {
    let mut agent = Some("ClaudeCode".to_string());
    let mut backend = None;
    apply_native_backend_agent_selector(&mut agent, &mut backend).unwrap();
    assert_eq!(backend.as_deref(), Some("claudecode"));
    assert_eq!(agent, None);

    let mut agent = Some("codex".to_string());
    let mut backend = Some("codex".to_string());
    apply_native_backend_agent_selector(&mut agent, &mut backend).unwrap();
    assert_eq!(agent, None);
}

#[test]
fn native_backend_agent_selector_preserves_real_opencode_agent() {
    let mut agent = Some("codex".to_string());
    let mut backend = Some("opencode".to_string());
    apply_native_backend_agent_selector(&mut agent, &mut backend).unwrap();
    assert_eq!(backend.as_deref(), Some("opencode"));
    assert_eq!(agent.as_deref(), Some("codex"));
}

#[test]
fn native_backend_agent_selector_rejects_conflicting_backend() {
    let mut agent = Some("antigravity".to_string());
    let mut backend = Some("codex".to_string());
    let error = apply_native_backend_agent_selector(&mut agent, &mut backend).unwrap_err();
    assert!(error.contains("selects backend 'antigravity'"));
    assert_eq!(agent.as_deref(), Some("antigravity"));
}

#[test]
fn test_mission_search_relevance_score_prefers_exact_phrase() {
    let now = mission_store::now_string();
    let strong = Mission {
        id: Uuid::new_v4(),
        status: MissionStatus::Active,
        title: Some("Fix login timeout regression".to_string()),
        short_description: Some("Investigate timeout happening after login redirect".to_string()),
        metadata_updated_at: None,
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
        workspace_id: crate::workspace::DEFAULT_WORKSPACE_ID,
        workspace_name: Some("Sandboxed".to_string()),
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        backend: "claudecode".to_string(),
        config_profile: None,
        history: Vec::new(),
        created_at: now.clone(),
        updated_at: now.clone(),
        interrupted_at: None,
        paused_at: None,
        resumable: false,
        desktop_sessions: Vec::new(),
        session_id: None,
        terminal_reason: None,
        terminal_evidence: None,
        parent_mission_id: None,
        working_directory: None,
        requires_local_disk: true,
        mission_mode: MissionMode::default(),
        goal_mode: false,
        goal_objective: None,
        first_viewed_at: None,
        scheduling: Default::default(),
        project: Default::default(),
        activity: Default::default(),
        awaiting_kind: None,
        origin: None,
        origin_session_id: None,
    };
    let weak = Mission {
        id: Uuid::new_v4(),
        status: MissionStatus::Active,
        title: Some("Login failure investigation".to_string()),
        short_description: Some("Issue affecting auth flow and API retries".to_string()),
        metadata_updated_at: None,
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
        workspace_id: crate::workspace::DEFAULT_WORKSPACE_ID,
        workspace_name: Some("Sandboxed".to_string()),
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        backend: "claudecode".to_string(),
        config_profile: None,
        history: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
        interrupted_at: None,
        paused_at: None,
        resumable: false,
        desktop_sessions: Vec::new(),
        session_id: None,
        terminal_reason: None,
        terminal_evidence: None,
        parent_mission_id: None,
        working_directory: None,
        requires_local_disk: true,
        mission_mode: MissionMode::default(),
        goal_mode: false,
        goal_objective: None,
        first_viewed_at: None,
        scheduling: Default::default(),
        project: Default::default(),
        activity: Default::default(),
        awaiting_kind: None,
        origin: None,
        origin_session_id: None,
    };

    let strong_score =
        mission_search_relevance_score(&strong, "login timeout", strong.workspace_name.as_deref());
    let weak_score =
        mission_search_relevance_score(&weak, "login timeout", weak.workspace_name.as_deref());

    assert!(strong_score > weak_score);
}

#[test]
fn test_mission_search_relevance_score_supports_query_expansion() {
    let now = mission_store::now_string();
    let mission = Mission {
        id: Uuid::new_v4(),
        status: MissionStatus::Completed,
        title: Some("Release prep for dashboard deploy".to_string()),
        short_description: Some("Ship the rollout to production".to_string()),
        metadata_updated_at: None,
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
        workspace_id: crate::workspace::DEFAULT_WORKSPACE_ID,
        workspace_name: Some("Sandboxed".to_string()),
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        backend: "codex".to_string(),
        config_profile: None,
        history: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
        interrupted_at: None,
        paused_at: None,
        resumable: false,
        desktop_sessions: Vec::new(),
        session_id: None,
        terminal_reason: None,
        terminal_evidence: None,
        parent_mission_id: None,
        working_directory: None,
        requires_local_disk: true,
        mission_mode: MissionMode::default(),
        goal_mode: false,
        goal_objective: None,
        first_viewed_at: None,
        scheduling: Default::default(),
        project: Default::default(),
        activity: Default::default(),
        awaiting_kind: None,
        origin: None,
        origin_session_id: None,
    };

    let score = mission_search_relevance_score(
        &mission,
        "deploy rollout",
        mission.workspace_name.as_deref(),
    );
    assert!(score > 0.0);
}

#[test]
fn test_mission_search_relevance_score_supports_abbreviation_query_expansion() {
    let now = mission_store::now_string();
    let mission = Mission {
        id: Uuid::new_v4(),
        status: MissionStatus::Completed,
        title: Some("Fix session id timeout handling".to_string()),
        short_description: Some("Normalize cookie session id parsing".to_string()),
        metadata_updated_at: None,
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
        workspace_id: crate::workspace::DEFAULT_WORKSPACE_ID,
        workspace_name: Some("Sandboxed".to_string()),
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        backend: "codex".to_string(),
        config_profile: None,
        history: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
        interrupted_at: None,
        paused_at: None,
        resumable: false,
        desktop_sessions: Vec::new(),
        session_id: None,
        terminal_reason: None,
        terminal_evidence: None,
        parent_mission_id: None,
        working_directory: None,
        requires_local_disk: true,
        mission_mode: MissionMode::default(),
        goal_mode: false,
        goal_objective: None,
        first_viewed_at: None,
        scheduling: Default::default(),
        project: Default::default(),
        activity: Default::default(),
        awaiting_kind: None,
        origin: None,
        origin_session_id: None,
    };

    let score =
        mission_search_relevance_score(&mission, "sid timeout", mission.workspace_name.as_deref());
    assert!(score > 0.0);
}

#[test]
fn test_mission_search_relevance_score_returns_zero_for_non_matching_query() {
    let now = mission_store::now_string();
    let mission = Mission {
        id: Uuid::new_v4(),
        status: MissionStatus::Completed,
        title: Some("Implement payment retry flow".to_string()),
        short_description: Some("Handle webhook retries for failed invoices".to_string()),
        metadata_updated_at: None,
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
        workspace_id: crate::workspace::DEFAULT_WORKSPACE_ID,
        workspace_name: Some("Sandboxed".to_string()),
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        backend: "codex".to_string(),
        config_profile: None,
        history: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
        interrupted_at: None,
        paused_at: None,
        resumable: false,
        desktop_sessions: Vec::new(),
        session_id: None,
        terminal_reason: None,
        terminal_evidence: None,
        parent_mission_id: None,
        working_directory: None,
        requires_local_disk: true,
        mission_mode: MissionMode::default(),
        goal_mode: false,
        goal_objective: None,
        first_viewed_at: None,
        scheduling: Default::default(),
        project: Default::default(),
        activity: Default::default(),
        awaiting_kind: None,
        origin: None,
        origin_session_id: None,
    };

    let score = mission_search_relevance_score(
        &mission,
        "kubernetes autoscaling",
        mission.workspace_name.as_deref(),
    );
    assert_eq!(score, 0.0);
}

#[test]
fn test_mission_search_relevance_score_ignores_natural_language_stopwords() {
    let now = mission_store::now_string();
    let mission = Mission {
        id: Uuid::new_v4(),
        status: MissionStatus::Completed,
        title: Some("Fix session id timeout handling".to_string()),
        short_description: Some("Root cause was stale session id parsing".to_string()),
        metadata_updated_at: None,
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
        workspace_id: crate::workspace::DEFAULT_WORKSPACE_ID,
        workspace_name: Some("Sandboxed".to_string()),
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        backend: "codex".to_string(),
        config_profile: None,
        history: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
        interrupted_at: None,
        paused_at: None,
        resumable: false,
        desktop_sessions: Vec::new(),
        session_id: None,
        terminal_reason: None,
        terminal_evidence: None,
        parent_mission_id: None,
        working_directory: None,
        requires_local_disk: true,
        mission_mode: MissionMode::default(),
        goal_mode: false,
        goal_objective: None,
        first_viewed_at: None,
        scheduling: Default::default(),
        project: Default::default(),
        activity: Default::default(),
        awaiting_kind: None,
        origin: None,
        origin_session_id: None,
    };

    let score = mission_search_relevance_score(
        &mission,
        "where did we fix the session id timeout",
        mission.workspace_name.as_deref(),
    );
    assert!(score > 0.0);
}

#[test]
fn test_mission_moment_relevance_score_prefers_exact_phrase_match() {
    let exact = mission_moment_relevance_score(
        "assistant",
        "Root cause was a session id timeout in OAuth callback handling.",
        "session id timeout",
    );
    let loose = mission_moment_relevance_score(
        "assistant",
        "Investigating OAuth callback handling and login failures.",
        "session id timeout",
    );
    assert!(exact > loose);
}

#[test]
fn test_mission_moment_relevance_score_returns_zero_for_unrelated_query() {
    let score = mission_moment_relevance_score(
        "assistant",
        "Investigate payment webhook retry loop",
        "kubernetes autoscaling",
    );
    assert_eq!(score, 0.0);
}

#[test]
fn test_mission_moment_relevance_score_ignores_natural_language_stopwords() {
    let score = mission_moment_relevance_score(
        "assistant",
        "We fixed the session id timeout by normalizing the cookie key.",
        "show me where we fixed the session id timeout",
    );
    assert!(score > 0.0);
}

#[test]
fn test_mission_moment_relevance_score_supports_abbreviation_query_expansion() {
    let score = mission_moment_relevance_score(
        "assistant",
        "We fixed the session id timeout by normalizing the cookie key.",
        "sid timeout",
    );
    assert!(score > 0.0);
}

#[test]
fn test_mission_moment_rationale_prefers_phrase_match_with_expansion() {
    let rationale = mission_moment_rationale(
        "assistant",
        "The issue was in session id parsing for cookie state.",
        "sid parsing",
    );
    assert_eq!(rationale, "Phrase match in assistant message");
}

#[test]
fn test_mission_moment_rationale_lists_matched_terms() {
    let rationale = mission_moment_rationale(
        "assistant",
        "The auth flow kept failing because login credentials expired.",
        "why did signin fail",
    );
    assert!(rationale.starts_with("Matched "));
    assert!(rationale.ends_with(" in assistant message"));
    assert!(rationale.contains("fail"));
}

#[test]
fn test_mission_moment_snippet_truncates_utf8_safely() {
    let source = "Fix résumé parser by preserving naïve unicode handling in results";
    let snippet = mission_moment_snippet(source, 18);
    assert!(snippet.ends_with('…'));
    assert!(snippet.chars().count() <= 19);
}

#[test]
fn test_mission_search_query_hash_normalizes_equivalent_queries() {
    let hash_a = mission_search_query_hash("Login Timeout");
    let hash_b = mission_search_query_hash(" login   timeout ");
    let hash_c = mission_search_query_hash("LOGIN-timeout");
    assert_eq!(hash_a, hash_b);
    assert_eq!(hash_b, hash_c);
}

#[test]
fn test_mission_search_freshness_key_changes_on_metadata_update() {
    let now = mission_store::now_string();
    let mut mission = Mission {
        id: Uuid::new_v4(),
        status: MissionStatus::Completed,
        title: Some("Implement payment retry flow".to_string()),
        short_description: Some("Handle webhook retries for failed invoices".to_string()),
        metadata_updated_at: Some(now.clone()),
        metadata_source: None,
        metadata_model: None,
        metadata_version: None,
        workspace_id: crate::workspace::DEFAULT_WORKSPACE_ID,
        workspace_name: Some("Sandboxed".to_string()),
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        backend: "codex".to_string(),
        config_profile: None,
        history: Vec::new(),
        created_at: now.clone(),
        updated_at: now.clone(),
        interrupted_at: None,
        paused_at: None,
        resumable: false,
        desktop_sessions: Vec::new(),
        session_id: None,
        terminal_reason: None,
        terminal_evidence: None,
        parent_mission_id: None,
        working_directory: None,
        requires_local_disk: true,
        mission_mode: MissionMode::default(),
        goal_mode: false,
        goal_objective: None,
        first_viewed_at: None,
        scheduling: Default::default(),
        project: Default::default(),
        activity: Default::default(),
        awaiting_kind: None,
        origin: None,
        origin_session_id: None,
    };
    let before = mission_search_freshness_key(
        &[MissionSearchCandidate {
            mission: mission.clone(),
            relevance_score: 1.0,
        }],
        100,
    );

    mission.short_description = Some("Handle webhook retries and alerting".to_string());
    mission.metadata_updated_at = Some("2099-01-01T00:00:00Z".to_string());
    let after = mission_search_freshness_key(
        &[MissionSearchCandidate {
            mission,
            relevance_score: 1.0,
        }],
        100,
    );

    assert_ne!(before, after);
}

#[tokio::test]
async fn test_mission_search_recency_fingerprint_changes_on_metadata_update() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("Investigate cache drift"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("mission should be created");

    let before = mission_search_recency_fingerprint(&store)
        .await
        .expect("recency fingerprint should be computed");

    store
        .update_mission_metadata(
            mission.id,
            Some(Some("Investigate cache drift")),
            Some(Some("Updated metadata")),
            None,
            None,
            None,
        )
        .await
        .expect("metadata update should succeed");

    let after = mission_search_recency_fingerprint(&store)
        .await
        .expect("recency fingerprint should be computed");
    assert_ne!(before, after);
}

#[tokio::test]
async fn test_mission_search_recency_fingerprint_changes_for_non_head_mission_update() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let older_mission = store
        .create_mission(Some("Older mission"), None, None, None, None, None, None)
        .await
        .expect("older mission should be created");
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    let newer_mission = store
        .create_mission(Some("Newer mission"), None, None, None, None, None, None)
        .await
        .expect("newer mission should be created");

    let before = mission_search_recency_fingerprint(&store)
        .await
        .expect("recency fingerprint should be computed");

    store
        .update_mission_metadata(
            older_mission.id,
            Some(Some("Older mission")),
            Some(Some("Metadata changed on older mission")),
            None,
            None,
            None,
        )
        .await
        .expect("metadata update should succeed");

    // Ensure older_mission is non-head at read time.
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    store
        .update_mission_title(newer_mission.id, "Newer mission touched")
        .await
        .expect("title update should succeed");

    let after = mission_search_recency_fingerprint(&store)
        .await
        .expect("recency fingerprint should be computed");
    assert_ne!(before, after);
}

#[test]
fn test_mission_search_cache_hit_by_freshness_requires_recency_match() {
    let entry = MissionSearchCacheEntry {
        cached_at: std::time::Instant::now(),
        freshness_key: 42,
        recency_fingerprint: 100,
        results: Vec::new(),
    };

    assert!(mission_search_cache_hit_by_freshness(&entry, 100, 42));
    assert!(!mission_search_cache_hit_by_freshness(&entry, 101, 42));
}

#[test]
fn test_automation_library_command_body_strips_frontmatter() {
    let content = r#"---
description: Analyze failures
params: [service]
---

Investigate <service/> failures.
"#;
    assert_eq!(
        automation_library_command_body(content),
        "Investigate <service/> failures."
    );
}

#[test]
fn test_automation_library_command_body_without_frontmatter() {
    assert_eq!(
        automation_library_command_body("  Echo current status. \n"),
        "Echo current status."
    );
}

#[test]
fn test_enqueue_agent_finished_messages_appends_after_existing_queue_items() {
    let existing_target = Uuid::new_v4();
    let restart_target = Uuid::new_v4();
    let mut queue = VecDeque::from([(
        Uuid::new_v4(),
        "queued user message".to_string(),
        None,
        Some(existing_target),
        Some("api:test-user".to_string()),
    )]);

    enqueue_agent_finished_messages(
        &mut queue,
        vec![
            RoutedAutomationMessage {
                content: "restart 1".to_string(),
                target_mission_id: restart_target,
            },
            RoutedAutomationMessage {
                content: "restart 2".to_string(),
                target_mission_id: restart_target,
            },
        ],
    );

    let ordered: Vec<(String, Option<Uuid>)> = queue
        .into_iter()
        .map(|(_, content, _, mission_id, _)| (content, mission_id))
        .collect();
    assert_eq!(
        ordered,
        vec![
            ("queued user message".to_string(), Some(existing_target)),
            ("restart 1".to_string(), Some(restart_target)),
            ("restart 2".to_string(), Some(restart_target)),
        ]
    );
}

#[test]
fn test_queue_has_pending_target_mission_matches_same_mission_only() {
    let mission_id = Uuid::new_v4();
    let other_mission_id = Uuid::new_v4();
    let queue = VecDeque::from([
        (
            Uuid::new_v4(),
            "other mission".to_string(),
            None,
            Some(other_mission_id),
            None,
        ),
        (
            Uuid::new_v4(),
            "current mission".to_string(),
            None,
            Some(mission_id),
            None,
        ),
    ]);

    assert!(queue_has_pending_target_mission(&queue, mission_id));
    assert!(!queue_has_pending_target_mission(&queue, Uuid::new_v4()));
}

#[tokio::test]
async fn paused_queued_delivery_is_parked_without_blocking_runnable_work() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let remote_wait = store
        .create_mission(Some("remote wait"), None, None, None, None, None, None)
        .await
        .expect("create remote-wait mission");
    store
        .update_mission_status(remote_wait.id, MissionStatus::Active)
        .await
        .expect("activate remote-wait mission");
    let remote_run = store
        .begin_mission_run(remote_wait.id, "remote-build:test", None)
        .await
        .expect("begin remote-wait run");
    store
        .heartbeat_mission_run(
            remote_run.run_id,
            remote_run.generation,
            MissionExecutionState::WaitingRemoteJob,
            None,
        )
        .await
        .expect("park remote-wait run");
    let paused = store
        .create_mission(Some("paused"), None, None, None, None, None, None)
        .await
        .expect("create paused mission");
    store
        .update_mission_status(paused.id, MissionStatus::Paused)
        .await
        .expect("pause mission");
    let active = store
        .create_mission(Some("active"), None, None, None, None, None, None)
        .await
        .expect("create active mission");
    store
        .update_mission_status(active.id, MissionStatus::Active)
        .await
        .expect("activate mission");

    let paused_entry = (
        Uuid::new_v4(),
        "park me".to_string(),
        None,
        Some(paused.id),
        None,
    );
    let remote_entry = (
        Uuid::new_v4(),
        "wait for receipt".to_string(),
        None,
        Some(remote_wait.id),
        None,
    );
    let active_entry = (
        Uuid::new_v4(),
        "run me".to_string(),
        None,
        Some(active.id),
        None,
    );
    let mut queue = VecDeque::from([
        remote_entry.clone(),
        paused_entry.clone(),
        active_entry.clone(),
    ]);

    let popped = pop_next_runnable_control_queue(&mut queue, &store)
        .await
        .expect("active delivery should be selected");
    assert_eq!(popped.0, active_entry.0);
    assert_eq!(
        queue,
        VecDeque::from([remote_entry.clone(), paused_entry.clone()])
    );

    assert!(pop_next_runnable_control_queue(&mut queue, &store)
        .await
        .is_none());
    assert_eq!(queue, VecDeque::from([remote_entry, paused_entry]));
}

#[tokio::test]
async fn failed_run_acquisition_restores_prior_status_and_reason() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("resume"), None, None, None, None, None, None)
        .await
        .expect("create mission");
    store
        .update_mission_status_with_reason(
            mission.id,
            MissionStatus::Interrupted,
            Some("transport"),
        )
        .await
        .expect("interrupt mission");
    let interrupted = store
        .get_mission(mission.id)
        .await
        .expect("load mission")
        .expect("mission exists");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("optimistic activation");
    let (events_tx, mut events_rx) = broadcast::channel(4);

    restore_mission_after_failed_run_acquisition(&store, &events_tx, &interrupted)
        .await
        .expect("restore prior status");

    let restored = store
        .get_mission(mission.id)
        .await
        .expect("reload mission")
        .expect("mission exists");
    assert_eq!(restored.status, MissionStatus::Interrupted);
    assert_eq!(restored.terminal_reason.as_deref(), Some("transport"));
    assert!(matches!(
        events_rx.try_recv(),
        Ok(AgentEvent::MissionStatusChanged {
            status: MissionStatus::Interrupted,
            ..
        })
    ));
}

#[test]
fn cancelling_provisional_parallel_queues_releases_cached_runner_settings() {
    for clear_all in [false, true] {
        let id = Uuid::new_v4();
        let mut runner = crate::api::mission_runner::MissionRunner::new(
            id,
            Uuid::new_v4(),
            None,
            Some("old-backend".into()),
            None,
            None,
            Some("old-model".into()),
            None,
            false,
            None,
        );
        let message = Uuid::new_v4();
        runner.queue_message(
            message,
            "pending".into(),
            None,
            Some("host-queue:api:test".into()),
        );
        let mut runners = HashMap::from([(id, runner)]);
        prune_empty_provisional_runners(&mut runners);
        assert!(runners.contains_key(&id));
        let runner = runners.get_mut(&id).unwrap();
        if clear_all {
            runner.clear_queue();
        } else {
            assert!(runner.remove_from_queue(message));
        }
        prune_empty_provisional_runners(&mut runners);
        assert!(
            !runners.contains_key(&id),
            "later dispatch must reload current mission settings"
        );
    }
}

#[test]
fn queue_snapshot_replays_prepared_parallel_message_until_run_exists() {
    let main_mission = Uuid::new_v4();
    let parallel_mission = Uuid::new_v4();
    let main_queue = VecDeque::from([(
        Uuid::new_v4(),
        "main".to_string(),
        None,
        Some(main_mission),
        Some("api:test".to_string()),
    )]);
    let mut runner = crate::api::mission_runner::MissionRunner::new(
        parallel_mission,
        Uuid::new_v4(),
        None,
        Some("codex".to_string()),
        None,
        None,
        None,
        None,
        false,
        None,
    );
    let parallel_message_id = Uuid::new_v4();
    runner.queue_message(
        parallel_message_id,
        "parallel".to_string(),
        None,
        Some("task-board".to_string()),
    );
    runner
        .take_next_message_for_start()
        .expect("parallel message should move to the in-flight slot");
    assert!(runner.queue.is_empty());
    let parallel = std::collections::HashMap::from([(parallel_mission, runner)]);

    let snapshot = serialize_queue_snapshot(&main_queue, &parallel, &HashMap::new());
    let messages: Vec<QueuedMessage> = serde_json::from_str(&snapshot).unwrap();
    assert_eq!(messages.len(), 2);
    assert!(messages.iter().any(|message| {
        message.id == parallel_message_id
            && message.content == "parallel"
            && message.mission_id == Some(parallel_mission)
            && !message.inflight
    }));
    assert!(messages
        .iter()
        .any(|message| message.content == "main" && !message.inflight));
}

#[test]
fn queue_snapshot_marks_parallel_message_consumed_with_durable_run() {
    let mission_id = Uuid::new_v4();
    let mut runner = crate::api::mission_runner::MissionRunner::new(
        mission_id,
        Uuid::new_v4(),
        None,
        Some("codex".to_string()),
        None,
        None,
        None,
        None,
        false,
        None,
    );
    let message_id = Uuid::new_v4();
    runner.queue_message(
        message_id,
        "parallel".into(),
        None,
        Some("task-board".into()),
    );
    runner
        .take_next_message_for_start()
        .expect("message should enter prepared slot");
    runner.durable_run = Some(MissionRun {
        run_id: Uuid::new_v4(),
        mission_id,
        generation: 1,
        execution_state: MissionExecutionState::Running,
        owner_actor_id: "control:test".into(),
        scope_unit: None,
        started_at: now_string(),
        heartbeat_at: now_string(),
        stopping_at: None,
        ended_at: None,
        terminal_reason: None,
    });
    let runners = std::collections::HashMap::from([(mission_id, runner)]);

    let snapshot = serialize_queue_snapshot(&VecDeque::new(), &runners, &HashMap::new());
    let messages: Vec<QueuedMessage> = serde_json::from_str(&snapshot).unwrap();

    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].id, message_id);
    assert!(messages[0].inflight);
}

#[test]
fn restart_marks_inflight_parallel_messages_consumed_without_replay() {
    let pending_id = Uuid::new_v4();
    let inflight_id = Uuid::new_v4();
    let (pending, consumed) = partition_restored_control_messages(vec![
        QueuedMessage {
            id: pending_id,
            content: "not started".into(),
            agent: None,
            mission_id: Some(Uuid::new_v4()),
            source: None,
            inflight: false,
            queue_error: None,
        },
        QueuedMessage {
            id: inflight_id,
            content: "already started".into(),
            agent: None,
            mission_id: Some(Uuid::new_v4()),
            source: Some("task-board".into()),
            inflight: true,
            queue_error: None,
        },
    ]);

    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, pending_id);
    assert_eq!(consumed.len(), 1);
    assert_eq!(consumed[0].id, inflight_id);
    assert!(consumed[0].inflight);

    let recovered = HashMap::from([(inflight_id, consumed[0].clone())]);
    let snapshot = serialize_queue_snapshot(&VecDeque::new(), &HashMap::new(), &recovered);
    let reparsed: Vec<QueuedMessage> = serde_json::from_str(&snapshot).unwrap();
    let (replayed_again, consumed_again) = partition_restored_control_messages(reparsed);
    assert!(replayed_again.is_empty());
    assert_eq!(consumed_again.len(), 1);
    assert_eq!(consumed_again[0].id, inflight_id);
}

#[test]
fn scheduler_batch_recovery_retains_all_ids_without_serializing_aliases() {
    let outer = Uuid::new_v4();
    let a = Uuid::new_v4();
    let b = Uuid::new_v4();
    let content = deferred_messages::join(
        &deferred_messages::encode(a, "same"),
        &deferred_messages::encode(b, "same"),
    );
    for inflight in [false, true] {
        let entry = QueuedMessage {
            id: outer,
            content: content.clone(),
            agent: None,
            mission_id: Some(Uuid::new_v4()),
            source: Some("scheduler".into()),
            inflight,
            queue_error: None,
        };
        let (pending, consumed) = partition_restored_control_messages(vec![entry]);
        let restored = pending.first().or_else(|| consumed.first()).unwrap();
        for id in [outer, a, b] {
            assert!(control_message_contains_id(
                restored.id,
                &restored.content,
                restored.source.as_deref(),
                id
            ));
        }
        // User prose resembling an internal envelope never owns another ID.
        assert!(!control_message_contains_id(
            outer,
            &content,
            Some("api:test"),
            a
        ));
        let queue = pending
            .into_iter()
            .map(|entry| {
                (
                    entry.id,
                    entry.content,
                    entry.agent,
                    entry.mission_id,
                    entry.source,
                )
            })
            .collect();
        let recovered = consumed
            .into_iter()
            .map(|entry| (entry.id, entry))
            .collect();
        let serialized = serialize_queue_snapshot(&queue, &HashMap::new(), &recovered);
        let rows: Vec<QueuedMessage> = serde_json::from_str(&serialized).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, outer);
        assert_eq!(rows[0].inflight, inflight);
    }
}

#[test]
fn test_accept_user_message_id_rejects_duplicate_retry_id() {
    let message_id = Uuid::new_v4();
    let mut accepted = HashSet::new();

    assert!(accept_user_message_id(&mut accepted, message_id));
    assert!(!accept_user_message_id(&mut accepted, message_id));
}

fn assistant(content: &str) -> MissionHistoryEntry {
    MissionHistoryEntry {
        role: "assistant".to_string(),
        content: content.to_string(),
    }
}

#[test]
fn classify_awaiting_kind_detects_decisions_and_acks() {
    // Trailing question → decision.
    assert_eq!(
        classify_awaiting_kind(&[assistant("I found two options. Which one do you prefer?")]),
        AwaitingKind::Decision
    );
    // Approval-seeking phrasing without a literal trailing '?'.
    assert_eq!(
        classify_awaiting_kind(&[assistant(
            "The migration is ready. Should I apply it now to prod?"
        )]),
        AwaitingKind::Decision
    );
    // Plain "done" statement → ack.
    assert_eq!(
        classify_awaiting_kind(&[assistant("Done. Opened PR #569 and merged it.")]),
        AwaitingKind::Ack
    );
    // No assistant text at all → ack (don't fabricate an open question).
    assert_eq!(
        classify_awaiting_kind(&[MissionHistoryEntry {
            role: "user".to_string(),
            content: "go".to_string(),
        }]),
        AwaitingKind::Ack
    );
    // Only the *last* assistant message matters.
    assert_eq!(
        classify_awaiting_kind(&[
            assistant("Should I start? "),
            assistant("All set, deployed and verified."),
        ]),
        AwaitingKind::Ack
    );
}

#[test]
fn test_mission_status_for_terminal_reason_defers_turn_complete_until_idle_finalization() {
    // With a follow-up still queued/scheduled the mission stays whatever
    // it was — the next turn will resolve its status.
    assert_eq!(
        mission_status_for_terminal_reason(TerminalReason::TurnComplete, false),
        None
    );
    // No follow-up: the agent's turn ended cleanly and the mission is
    // parked waiting for the user. The Needs-You bucket is keyed on
    // exactly this state.
    assert_eq!(
        mission_status_for_terminal_reason(TerminalReason::TurnComplete, true),
        Some((MissionStatus::AwaitingUser, "turn_complete"))
    );
    // Explicit agent-declared completion still maps to Completed (green
    // in Finished), distinct from the auto AwaitingUser path above.
    assert_eq!(
        mission_status_for_terminal_reason(TerminalReason::Completed, true),
        Some((MissionStatus::Completed, "completed"))
    );
}

#[test]
fn deferred_goal_replaces_stale_prompt_on_failed_follow_up() {
    let original = "You are GPT-5.6 Pro with web search. Research…";
    let follow_up = "retry now, the provider is fixed";
    assert_eq!(
        deferred_goal_for_incoming_message(MissionStatus::Failed, Some(original), follow_up),
        follow_up
    );
    assert_eq!(
        deferred_goal_for_incoming_message(MissionStatus::Pending, Some(original), follow_up),
        format!("{original}\n{follow_up}")
    );
    assert!(follow_up_should_requeue_as_pending(MissionStatus::Failed));
    assert!(!follow_up_should_requeue_as_pending(MissionStatus::Pending));
}

#[test]
fn message_activates_mission_includes_waiting_background() {
    // A resume delivered while background jobs are still live lands on a
    // WaitingBackground mission; it must be activation-eligible so the flip
    // to Active clears first_viewed_at and closes the ack race.
    assert!(message_activates_mission(MissionStatus::WaitingBackground));
    for status in [
        MissionStatus::Pending,
        MissionStatus::Interrupted,
        MissionStatus::Blocked,
        MissionStatus::Completed,
        MissionStatus::Failed,
        MissionStatus::AwaitingUser,
        MissionStatus::Acknowledged,
    ] {
        assert!(
            message_activates_mission(status),
            "{status} should activate"
        );
    }
    // Already-running and explicitly-paused missions are handled elsewhere
    // (a running mission needs no activation; a paused one must stay parked
    // until the user resumes it), so they are not activation-eligible here.
    assert!(!message_activates_mission(MissionStatus::Active));
    assert!(!message_activates_mission(MissionStatus::Paused));
}

#[test]
fn acknowledgement_is_blocked_while_background_tasks_are_registered() {
    assert!(background_tasks_block_ack(MissionStatus::Acknowledged, 1));
    assert!(!background_tasks_block_ack(MissionStatus::Acknowledged, 0));
    assert!(!background_tasks_block_ack(MissionStatus::Active, 1));
}

#[test]
fn every_targeted_queued_delivery_reasserts_mission_activation() {
    let mission_id = Uuid::new_v4();

    assert!(queued_delivery_requires_activation(Some(mission_id), None));
    assert!(queued_delivery_requires_activation(
        Some(mission_id),
        Some("agent_finished")
    ));
    assert!(queued_delivery_requires_activation(
        Some(mission_id),
        Some("transport_auto_resume")
    ));
    assert!(queued_delivery_requires_activation(
        None,
        Some("transport_auto_resume")
    ));
    assert!(!queued_delivery_requires_activation(None, None));

    assert!(message_activates_mission(MissionStatus::Interrupted));
    assert!(message_activates_mission(MissionStatus::Acknowledged));
    assert!(!message_activates_mission(MissionStatus::Active));
    assert!(!message_activates_mission(MissionStatus::Paused));
}

#[test]
fn durable_remote_job_heartbeat_keeps_projected_health_healthy() {
    let health = projected_running_health(
        crate::api::mission_runner::MissionRunState::Running,
        600,
        true,
        true,
    );
    assert!(matches!(
        health,
        crate::api::mission_runner::MissionHealth::Healthy
    ));

    let without_remote_job = projected_running_health(
        crate::api::mission_runner::MissionRunState::Running,
        600,
        true,
        false,
    );
    assert!(matches!(
        without_remote_job,
        crate::api::mission_runner::MissionHealth::Stalled { .. }
    ));
}

#[test]
fn raw_remote_auto_placement_reprobes_every_node() {
    use crate::remote_node::RemoteNodeStatus;

    assert!(remote_node_needs_on_demand_probe(None));
    assert!(remote_node_needs_on_demand_probe(Some(
        &RemoteNodeStatus::Unknown
    )));
    for status in [
        RemoteNodeStatus::Degraded,
        RemoteNodeStatus::Offline,
        RemoteNodeStatus::Disabled,
    ] {
        assert!(remote_node_needs_on_demand_probe(Some(&status)));
    }
    assert!(remote_node_needs_on_demand_probe(Some(
        &RemoteNodeStatus::Online
    )));
}

#[test]
fn durable_wakeup_supersession_is_scoped_to_job_id() {
    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    let first_key = wakeup_supersession_key(
        Some("durable-job-terminal"),
        &mission_store::TriggerType::DurableJobTerminal { job_id: first },
    );
    let replacement_key = wakeup_supersession_key(
        Some("durable-job-terminal"),
        &mission_store::TriggerType::DurableJobTerminal { job_id: first },
    );
    let independent_key = wakeup_supersession_key(
        Some("durable-job-terminal"),
        &mission_store::TriggerType::DurableJobTerminal { job_id: second },
    );

    assert_eq!(first_key, replacement_key);
    assert_ne!(first_key, independent_key);
    assert_eq!(
        wakeup_supersession_key(
            Some("automation-manager"),
            &mission_store::TriggerType::Interval { seconds: 60 }
        ),
        wakeup_supersession_key(
            Some("claude-builtin"),
            &mission_store::TriggerType::Interval { seconds: 120 }
        )
    );
}

#[test]
fn remote_harness_plan_is_explicit_about_node_support() {
    // Explicit raw command wins regardless of backend.
    assert_eq!(
        plan_remote_harness(Some(" hostname "), "grok", None, Some("p")).unwrap(),
        RemoteHarnessPlan::Raw {
            command: "hostname".into()
        }
    );
    assert_eq!(
        plan_remote_harness(
            None,
            "claudecode",
            Some("anthropic/claude-opus-5"),
            Some("do it")
        )
        .unwrap(),
        RemoteHarnessPlan::ClaudeCode {
            resume_session_id: None,
            model: Some("claude-opus-5".into()),
            prompt: "do it".into()
        }
    );
    assert_eq!(
        plan_remote_harness(None, "opencode", Some("xai/grok-4.6"), Some("do it")).unwrap(),
        RemoteHarnessPlan::OpenCode {
            resume_session_id: None,
            model: Some("xai/grok-4.6".into()),
            prompt: "do it".into()
        }
    );
    assert_eq!(
        plan_remote_harness(
            None,
            "opencode",
            Some("builtin/xai/grok-4.6"),
            Some("do it")
        )
        .unwrap(),
        RemoteHarnessPlan::OpenCode {
            resume_session_id: None,
            model: Some("xai/grok-4.6".into()),
            prompt: "do it".into()
        }
    );
    let no_model = plan_remote_harness(None, "opencode", None, Some("do it"))
        .expect_err("opencode needs a routed model");
    assert!(
        no_model.starts_with("REMOTE_MODEL_REQUIRED: "),
        "{no_model}"
    );
    let rejected = plan_remote_harness(None, "unknown", Some("grok-4.6"), Some("do it"))
        .expect_err("unknown harness");
    assert!(
        rejected.starts_with("REMOTE_HARNESS_UNSUPPORTED: "),
        "{rejected}"
    );
    assert!(rejected.contains("'unknown'"), "{rejected}");
    assert!(rejected.contains("claudecode or opencode"), "{rejected}");
    let no_prompt = plan_remote_harness(None, "claudecode", None, Some("   ")).expect_err("prompt");
    assert!(
        no_prompt.starts_with("REMOTE_PROMPT_REQUIRED: "),
        "{no_prompt}"
    );
}

#[test]
fn antigravity_stderr_reaches_the_job_log_without_oauth_material() {
    let script = format!(
            "exec sh -c 'echo AGY_ERROR: boom >&2; echo see https://accounts.google.com/o/oauth2 >&2; echo out' 2> >({ANTIGRAVITY_STDERR_FILTER} >&2)"
        );
    let output = std::process::Command::new("bash")
        .args(["-c", &script])
        .output()
        .expect("bash");
    // Process substitution may flush just after the leader exits.
    std::thread::sleep(std::time::Duration::from_millis(200));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "out");
    assert!(stderr.contains("AGY_ERROR: boom"), "{stderr}");
    assert!(!stderr.contains("accounts.google.com"), "{stderr}");
}

#[test]
fn retired_gemini_remote_launch_is_rejected_without_fallback() {
    let error = plan_remote_harness(None, "gemini", Some("gemini-old"), Some("hello"))
        .expect_err("retired harness must not run");
    assert!(error.starts_with(REMOTE_HARNESS_UNSUPPORTED));
    assert!(!REMOTE_NODE_HARNESSES.contains(&"gemini"));
    assert!(matches!(
        plan_remote_harness(None, "antigravity", Some("gemini-account"), Some("hello")),
        Ok(RemoteHarnessPlan::Antigravity { .. })
    ));
    let large_prompt = "'".repeat(40 * 1024);
    let plan = plan_remote_harness(None, "antigravity", Some("agy-demo"), Some(&large_prompt))
        .expect("40 KiB antigravity prompt should be accepted");
    let execution = remote_execution_for_plan(&plan, "", "");
    assert!(!execution.command.contains("2>/dev/null"));
    assert!(execution.command.contains(ANTIGRAVITY_STDERR_FILTER));
    assert!(
        execution.command.contains("exec agy ") && execution.command.contains("\"$(cat <&3)\""),
        "{}",
        execution.command
    );
    let oversized = "a".repeat(crate::antigravity::MAX_PROMPT_BYTES + 1);
    let rejected = plan_remote_harness(None, "antigravity", Some("agy-demo"), Some(&oversized))
        .expect_err("oversized antigravity prompt must be rejected before mission creation");
    assert!(
        rejected.contains("Antigravity prompts must be at most 64 KiB"),
        "{rejected}"
    );
}

#[test]
fn remote_codex_uses_native_cli_and_secret_env_for_launch_and_resume() {
    let plan = plan_remote_harness(
        None,
        "codex",
        Some("openai/gpt-5.4"),
        Some("say 'hi'; $(false)"),
    )
    .unwrap();
    assert!(plan.uses_core_proxy());
    let execution = remote_execution_for_plan(&plan, "https://core.example/", "secret-test-key");
    assert!(!execution.command.contains("secret-test-key"));
    assert!(execution.command.contains("exec python3 -c"));
    // The configuration (prompt, session) is staged on fd 3, never in argv.
    assert!(!execution.command.contains("$(false)"));
    assert!(!execution.command.contains("commit_attribution"));
    let config = staged_codex_config(&execution);
    assert_eq!(config["prompt"], "say 'hi'; $(false)");
    assert!(config["session"].is_null());
    let settings = config["settings"].to_string();
    assert!(settings.contains("wire_api"));
    assert!(settings.contains("https://core.example/v1"));
    assert!(!settings.contains("commit_attribution"));
    assert_eq!(
        execution.env.unwrap()[REMOTE_PROXY_KEY_ENV],
        "secret-test-key"
    );
    let resume = RemoteHarnessPlan::Codex {
        service_tier: None,
        effort: Some("high".into()),
        fast_mode: true,
        model: "openai/gpt-5.4".into(),
        prompt: "continue".into(),
        resume_session_id: Some("thread-123".into()),
        fallback_prompt: Some("HISTORY\n\ncontinue".into()),
    };
    let execution = remote_execution_for_plan(&resume, "https://core.example", "secret-test-key");
    assert!(execution.command.contains("thread/resume"));
    let config = staged_codex_config(&execution);
    assert_eq!(config["session"], "thread-123");
    assert_eq!(config["fallback_prompt"], "HISTORY\n\ncontinue");
    let settings = config["settings"].to_string();
    assert!(settings.contains("model_reasoning_effort"));
    assert!(settings.contains("service_tier"));
    assert!(plan_remote_harness(None, "codex", Some("gpt-6-astra"), Some("/goal test")).is_ok());
    match plan_remote_harness(None, "codex", None, Some("do it")).unwrap() {
        RemoteHarnessPlan::Codex { model, .. } => {
            assert_eq!(model, resolve_codex_default_model())
        }
        other => panic!("unexpected plan {other:?}"),
    }
}

/// Run the job's fd-3 staging prelude in bash and parse what the driver reads.
fn staged_codex_config(execution: &RemoteExecution) -> serde_json::Value {
    let prelude = execution.command.split("exec python3").next().unwrap();
    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(format!("{prelude}cat <&3"))
        .env_clear()
        .envs(execution.env.clone().unwrap_or_default())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    serde_json::from_slice(&output.stdout).unwrap()
}

/// Mission c96df4f9: a large first prompt inlined in argv failed with
/// "Argument list too long" before Codex created its thread.
#[test]
fn remote_codex_large_prompt_stays_out_of_argv() {
    let prompt = format!("{}TAIL", "x'y ".repeat(150_000));
    let plan = plan_remote_harness(None, "codex", Some("openai/gpt-5.4"), Some(&prompt)).unwrap();
    let execution = remote_execution_for_plan(&plan, "https://core.example", "k");
    assert!(execution.command.len() < INLINE_PROMPT_LIMIT);
    let env = execution.env.clone().unwrap();
    assert!(env.values().all(|value| value.len() <= STDIN_PROMPT_CHUNK));
    assert_eq!(staged_codex_config(&execution)["prompt"], prompt);
}

#[test]
fn remote_codex_launch_without_model_records_configured_default() {
    let default = resolve_codex_default_model();
    assert_eq!(
        mission_create::remote_codex_default_model(
            Some("codex"),
            Some("auto-managed:default"),
            None
        ),
        Some(default.clone())
    );
    assert_eq!(
        mission_create::remote_codex_default_model(
            Some("codex"),
            Some("auto-managed:large"),
            Some("  ")
        ),
        Some(default)
    );
    // Local launches keep the runner's own default resolution.
    assert_eq!(
        mission_create::remote_codex_default_model(Some("codex"), None, None),
        None
    );
    assert_eq!(
        mission_create::remote_codex_default_model(Some("codex"), Some(" "), None),
        None
    );
    // Raw commands carry their own auth/model.
    assert_eq!(
        mission_create::remote_codex_default_model(
            Some("codex"),
            Some("ashur"),
            Some("codex exec x")
        ),
        None
    );
    assert_eq!(
        mission_create::remote_codex_default_model(Some("opencode"), Some("ashur"), None),
        None
    );
}

#[test]
fn remote_claude_initial_identity_and_continuation_use_the_same_session() {
    let id = "c84bf30f-0d21-417e-82b7-48bda29ab007";
    let fresh = RemoteHarnessPlan::ClaudeCode {
        model: Some("claude-opus-5-5".into()),
        prompt: "Remember a marker".into(),
        resume_session_id: None,
    };
    let mut execution = remote_execution_for_plan(&fresh, "https://core.example", "test");
    bind_remote_claude_session(&mut execution, id);
    assert!(execution
        .command
        .contains(&format!("claude -p --session-id '{id}' ")));
    assert!(!execution.command.contains("--resume"));
    let resumed = RemoteHarnessPlan::ClaudeCode {
        model: Some("claude-opus-5-5".into()),
        prompt: "Recall it".into(),
        resume_session_id: Some(id.into()),
    };
    let execution = remote_execution_for_plan(&resumed, "https://core.example", "test");
    assert!(execution.command.contains(&format!("--resume '{id}'")));
    assert!(!execution.command.contains("--session-id"));
}

#[test]
fn remote_antigravity_plan_uses_native_plan_mode() {
    let plan = RemoteHarnessPlan::Antigravity {
        effort: None,
        model: Some("gemini-4-argon-medium".into()),
        prompt: "/plan split the work across agents".into(),
        resume_session_id: None,
    };
    let execution = remote_execution_for_plan(&plan, "https://core.example", "test");
    assert!(
        execution
            .command
            .contains("'--mode' 'plan' '-p' 'split the work across agents'"),
        "{}",
        execution.command
    );
    let plain = RemoteHarnessPlan::Antigravity {
        effort: None,
        model: None,
        prompt: "hello".into(),
        resume_session_id: None,
    };
    assert!(
        !remote_execution_for_plan(&plain, "https://core.example", "test")
            .command
            .contains("--mode")
    );
}

#[test]
fn remote_opencode_config_declares_a_context_limit() {
    let config = remote_opencode_config("private", "https://core.example");
    let limit = &config["provider"]["builtin"]["models"]["private"]["limit"];
    assert_eq!(limit["context"], 200_000);
    assert_eq!(limit["output"], 32_000);
}

#[test]
fn remote_opencode_config_uses_the_real_window_for_direct_gemini() {
    for model in ["google/gemini-4-argon", "builtin/google/gemini-4-argon-eap"] {
        let config = remote_opencode_config(model, "https://core.example");
        let limit = &config["provider"]["builtin"]["models"][model]["limit"];
        assert_eq!(limit["context"], 1_048_576, "{model}");
    }
    for model in [
        "builtin/smart",
        "smart",
        "zai/glm-5.3",
        "antigravity/gemini-4-argon",
    ] {
        assert_eq!(remote_opencode_context_limit(model), 200_000, "{model}");
    }
}

#[test]
fn remote_opencode_long_prompt_reaches_opencode_on_stdin_not_argv() {
    // Mission c13b82ea: a Claude Code -> OpenCode transfer of 165 messages failed with
    // "Argument list too long (os error 7)" because the history was the positional prompt.
    let prompt = format!(
        "Transferred conversation\n{}",
        "earlier turn with details ".repeat(20_000)
    );
    let plan = RemoteHarnessPlan::OpenCode {
        model: Some("xai/grok-4.6".into()),
        prompt: prompt.clone(),
        resume_session_id: None,
    };
    let execution = remote_execution_for_plan(&plan, "https://core.example", "test");
    assert!(execution.command.len() < 8192, "{}", execution.command);
    assert!(execution.command.contains("opencode run --format json"));
    assert!(execution.command.ends_with(" <&3"), "{}", execution.command);
    assert!(!execution.command.contains("earlier turn with details"));
    let env = execution.env.unwrap();
    let parts: Vec<_> = env
        .iter()
        .filter(|(key, _)| key.starts_with(STDIN_PROMPT_ENV))
        .collect();
    assert!(parts.len() > 1);
    assert!(parts
        .iter()
        .all(|(key, value)| key.len() + value.len() < 128 * 1024));

    // Short prompts use stdin too: `opencode run` wraps any positional
    // argument containing a space in literal quotes (mission 4ad4bc01 got
    // `"/goal …"`), while it appends non-TTY stdin verbatim.
    let short = RemoteHarnessPlan::OpenCode {
        model: Some("xai/grok-4.6".into()),
        prompt: "/goal say \"hi\" twice".into(),
        resume_session_id: None,
    };
    let execution = remote_execution_for_plan(&short, "https://core.example", "test");
    assert!(execution.command.ends_with(" <&3"), "{}", execution.command);
    assert!(!execution.command.contains("say"), "{}", execution.command);
    let env = execution.env.unwrap();
    let staged: String = (0..)
        .map_while(|i| env.get(&format!("{STDIN_PROMPT_ENV}{i}")).cloned())
        .collect();
    assert_eq!(staged, "/goal say \"hi\" twice");
}

#[test]
fn remote_claude_long_prompt_reaches_claude_on_stdin_not_argv() {
    // Fork 0a9943ec replayed 370 KB of history as the positional prompt.
    let prompt = format!("-{}é'\"$HOME`x`", "fork context ".repeat(30_000));
    let plan = RemoteHarnessPlan::ClaudeCode {
        model: Some("claude-opus-5-5".into()),
        prompt: prompt.clone(),
        resume_session_id: None,
    };
    let mut execution = remote_execution_for_plan(&plan, "https://core.example", "test");
    bind_remote_claude_session(&mut execution, "c84bf30f-0d21-417e-82b7-48bda29ab007");
    assert!(execution.command.len() < 4096, "{}", execution.command);
    assert!(execution.command.contains("claude -p --session-id "));
    assert!(execution.command.ends_with(" <&3"), "{}", execution.command);
    let env = execution.env.unwrap();
    let parts: Vec<_> = env
        .iter()
        .filter(|(key, _)| key.starts_with(STDIN_PROMPT_ENV))
        .collect();
    assert!(parts.len() > 1);
    assert!(parts
        .iter()
        .all(|(key, value)| key.len() + value.len() < 128 * 1024));
    assert_eq!(env["ANTHROPIC_AUTH_TOKEN"], "test");

    // The prelude really reassembles the prompt and scrubs the parts.
    let staged = stdin_prompt(&prompt).unwrap();
    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(format!(
            "{}env | grep -c '^{STDIN_PROMPT_ENV}' >&2; cat <&3",
            staged.prelude
        ))
        .env_clear()
        .envs(&staged.env)
        .env("PATH", "/usr/bin:/bin")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), prompt);
    assert_eq!(String::from_utf8_lossy(&output.stderr).trim(), "0");

    assert!(stdin_prompt("short").is_none());
    // 40 KB of apostrophes quotes to ~160 KB.
    assert!(stdin_prompt(&"'".repeat(40 * 1024)).is_some());
    let huge = format!("objective {}latest turn", "é".repeat(STDIN_PROMPT_LIMIT));
    let staged = stdin_prompt(&huge).unwrap();
    let total: usize = staged.env.values().map(String::len).sum();
    assert!(total <= STDIN_PROMPT_LIMIT, "{total}");
    let joined: String = (0..staged.env.len())
        .map(|i| staged.env[&format!("{STDIN_PROMPT_ENV}{i}")].as_str())
        .collect();
    assert!(joined.starts_with("objective "));
    assert!(joined.ends_with("latest turn"));
    assert!(joined.contains("Middle of this prompt omitted"));
}

#[test]
fn remote_execution_routes_selected_model_through_core_proxy_env() {
    let plan = RemoteHarnessPlan::ClaudeCode {
        resume_session_id: None,
        model: Some("claude-opus-5".into()),
        prompt: "say 'hi'".into(),
    };
    let exec = remote_execution_for_plan(&plan, "https://core.example", "sk-proxy-abc");
    assert!(
            exec.command
                .contains("claude -p --dangerously-skip-permissions --output-format stream-json --verbose --include-partial-messages --settings "),
            "{}",
            exec.command
        );
    assert!(
        exec.command.contains(" --model 'claude-opus-5' "),
        "{}",
        exec.command
    );
    assert!(
        exec.command
            .contains(r#""attribution":{"commit":"","pr":""}"#),
        "remote Claude never adds commit attribution: {}",
        exec.command
    );
    // Single quotes inside the prompt are shell-escaped.
    assert!(
        exec.command.ends_with(&shell_single_quote("say 'hi'")),
        "{}",
        exec.command
    );
    assert_eq!(shell_single_quote("a'b"), "'a'\\''b'");
    assert!(!exec.command.contains("sk-proxy-abc"));
    let env = exec.env.unwrap();
    assert_eq!(env["ANTHROPIC_BASE_URL"], "https://core.example");
    assert_eq!(env["ANTHROPIC_AUTH_TOKEN"], "sk-proxy-abc");
    assert_eq!(exec.label, "claudecode/claude-opus-5");

    let plan = RemoteHarnessPlan::OpenCode {
        resume_session_id: None,
        model: Some("xai/grok-4.6".into()),
        prompt: "build".into(),
    };
    let exec = remote_execution_for_plan(&plan, "https://core.example/", "sk-proxy-abc");
    assert!(
        exec.command
            .contains("opencode run --format json --thinking --model 'builtin/xai/grok-4.6' <&3"),
        "{}",
        exec.command
    );
    assert!(!exec.command.contains("opencode.json"), "{}", exec.command);
    assert!(!exec.command.contains("sk-proxy-abc"));
    let env = exec.env.unwrap();
    assert_eq!(env[REMOTE_PROXY_KEY_ENV], "sk-proxy-abc");
    let config: serde_json::Value = serde_json::from_str(&env[REMOTE_OPENCODE_CONFIG_ENV]).unwrap();
    assert_eq!(
        config["provider"]["builtin"]["options"]["baseURL"],
        "https://core.example/v1"
    );
    assert_eq!(
        config["provider"]["builtin"]["options"]["apiKey"],
        "{env:SANDBOXED_PROXY_API_KEY}"
    );
    assert_eq!(
        config["provider"]["builtin"]["models"]["xai/grok-4.6"]["name"],
        "xai/grok-4.6"
    );
    assert!(!env[REMOTE_OPENCODE_CONFIG_ENV].contains("sk-proxy-abc"));
    // Map key and --model agree even when the client sent `builtin/`,
    // and a leading-dash prompt reaches stdin, never yargs.
    let plan =
        plan_remote_harness(None, "opencode", Some("builtin/xai/grok-4.6"), Some("-x")).unwrap();
    let exec = remote_execution_for_plan(&plan, "https://core.example", "k");
    assert!(
        exec.command.ends_with("--model 'builtin/xai/grok-4.6' <&3"),
        "{}",
        exec.command
    );
    let env = exec.env.unwrap();
    assert_eq!(env[&format!("{STDIN_PROMPT_ENV}0")], "-x");
    let config: serde_json::Value = serde_json::from_str(&env[REMOTE_OPENCODE_CONFIG_ENV]).unwrap();
    assert!(config["provider"]["builtin"]["models"]["xai/grok-4.6"].is_object());
    let plan = RemoteHarnessPlan::ClaudeCode {
        resume_session_id: None,
        model: None,
        prompt: "--help".into(),
    };
    assert!(remote_execution_for_plan(&plan, "u", "k")
        .command
        .ends_with("' --help'"));

    let raw = remote_execution_for_plan(
        &RemoteHarnessPlan::Raw {
            command: "hostname".into(),
        },
        "",
        "",
    );
    assert_eq!(raw.env, None);
    assert_eq!(raw.command, "hostname");
}

#[tokio::test]
async fn boot_key_sweep_removes_old_orphans_and_keeps_new_process_keys() {
    let dir = tempfile::tempdir().unwrap();
    let store = super::super::proxy_keys::ProxyApiKeyStore::new(dir.path().join("keys.json")).await;
    let old_orphan = Uuid::new_v4();
    let old_live = Uuid::new_v4();
    let unrelated = store.create("dashboard-key".into()).await.unwrap();
    store
        .create(remote_launch_key_name(old_orphan))
        .await
        .unwrap();
    store
        .create(remote_launch_key_name(old_live))
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    let boot_cutoff = chrono::Utc::now();
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    // A launch of this process, minted after the cutoff, absent from
    // the (empty) ledger snapshot because its handle is not written yet.
    let fresh = Uuid::new_v4();
    store.create(remote_launch_key_name(fresh)).await.unwrap();
    let live_handle = crate::remote_node::job_ledger::JobHandle {
        mission_id: old_live,
        node_id: "dgx-spark".into(),
        job_id: Uuid::new_v4(),
        started_at: boot_cutoff,
        submission_sequence: 0,
        accepted_at: Some(boot_cutoff),
        heartbeat_at: None,
        disk_reservation_bytes: 0,
        kind: crate::remote_node::job_ledger::JobHandleKind::Mission,
        identity: None,
        wait_for_completion: None,
        wake_on_terminal: false,
    };
    retire_orphaned_remote_launch_keys(&store, std::slice::from_ref(&live_handle), boot_cutoff)
        .await;
    let mut names: Vec<String> = store.list().await.into_iter().map(|k| k.name).collect();
    names.sort();
    let mut expected = vec![
        unrelated.name.clone(),
        remote_launch_key_name(old_live),
        remote_launch_key_name(fresh),
    ];
    expected.sort();
    assert_eq!(names, expected);
    // Empty ledger: only the pre-cutoff orphan goes; the fresh key stays.
    retire_orphaned_remote_launch_keys(&store, &[], boot_cutoff).await;
    let mut names: Vec<String> = store.list().await.into_iter().map(|k| k.name).collect();
    names.sort();
    let mut expected = vec![unrelated.name, remote_launch_key_name(fresh)];
    expected.sort();
    assert_eq!(names, expected);
}

/// Bounded real-CLI resolution proof (no paid inference): the installed
/// OpenCode, configured exactly as a node job is (inline
/// `OPENCODE_CONFIG_CONTENT`, cwd = HOME = scratch dir, key only in env),
/// must send the exact requested model id and the env key to the
/// proxy-shaped endpoint. A local mock answers one canned streamed
/// completion. Skipped when the CLI is not installed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_opencode_execution_resolves_model_against_mock_proxy() {
    if !std::process::Command::new("bash")
        .args(["-lc", "command -v opencode"])
        .output()
        .is_ok_and(|output| output.status.success())
    {
        eprintln!("opencode CLI not installed; skipping mock-proxy fixture");
        return;
    }
    use axum::{routing::post, Json, Router};
    use std::sync::{Arc, Mutex};
    let seen: Arc<Mutex<Vec<(String, String)>>> = Arc::new(Mutex::new(Vec::new()));
    let app = Router::new().route(
            "/v1/chat/completions",
            post({
                let seen = seen.clone();
                move |headers: axum::http::HeaderMap, Json(body): Json<serde_json::Value>| {
                    let seen = seen.clone();
                    async move {
                        let model = body["model"].as_str().unwrap_or_default().to_string();
                        let auth = headers
                            .get(axum::http::header::AUTHORIZATION)
                            .and_then(|v| v.to_str().ok())
                            .unwrap_or_default()
                            .to_string();
                        seen.lock().unwrap().push((model.clone(), auth));
                        let chunk = |delta: serde_json::Value, finish: Option<&str>| {
                            format!(
                                "data: {}\n\n",
                                serde_json::json!({
                                    "id": "c1", "object": "chat.completion.chunk", "created": 1,
                                    "model": model,
                                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
                                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
                                })
                            )
                        };
                        let body = format!(
                            "{}{}data: [DONE]\n\n",
                            chunk(
                                serde_json::json!({"role": "assistant", "content": "ok"}),
                                None
                            ),
                            chunk(serde_json::json!({}), Some("stop"))
                        );
                        (
                            [(axum::http::header::CONTENT_TYPE, "text/event-stream")],
                            body,
                        )
                    }
                }
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let plan = plan_remote_harness(None, "opencode", Some("xai/grok-4.6"), Some("say ok")).unwrap();
    let exec = remote_execution_for_plan(&plan, &base, "sk-proxy-fixture-key");
    let dir = tempfile::tempdir().unwrap();
    let mut command = tokio::process::Command::new("bash");
    // The node runs the command verbatim under `bash -lc`; a `timeout`
    // prefix would turn the leading `command -v` builtin into a program
    // lookup. The tokio timeout below bounds the run instead.
    command
        .arg("-lc")
        .arg(&exec.command)
        .kill_on_drop(true)
        .current_dir(dir.path())
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("HOME", dir.path())
        .env("LANG", "C.UTF-8")
        .envs(exec.env.clone().unwrap());
    let output = tokio::time::timeout(std::time::Duration::from_secs(170), command.output())
        .await
        .expect("opencode run must finish")
        .unwrap();
    server.abort();
    let seen = seen.lock().unwrap().clone();
    assert!(
        output.status.success(),
        "status={:?} stdout={} stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!seen.is_empty(), "the CLI never called the proxy endpoint");
    for (model, auth) in &seen {
        assert_eq!(model, "xai/grok-4.6");
        assert_eq!(auth, "Bearer sk-proxy-fixture-key");
    }
    assert!(String::from_utf8_lossy(&output.stdout).contains("\"ok\""));
}

/// Bounded real-CLI fixture (no inference, no cost): the installed
/// OpenCode must accept the per-job config and list the exact proxy
/// model id under the `builtin` provider from a cwd that is also HOME,
/// the way node jobs run. Skipped when the CLI is not installed.
#[test]
fn remote_opencode_config_is_accepted_by_installed_cli_catalog() {
    let Ok(output) = std::process::Command::new("bash")
        .args(["-lc", "command -v opencode"])
        .output()
    else {
        return;
    };
    if !output.status.success() {
        eprintln!("opencode CLI not installed; skipping catalog fixture");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let listed = std::process::Command::new("bash")
        .args(["-lc", "timeout 120 opencode models builtin"])
        .current_dir(dir.path())
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("HOME", dir.path())
        .env("LANG", "C.UTF-8")
        .env(
            REMOTE_OPENCODE_CONFIG_ENV,
            remote_opencode_config("xai/grok-4.6", "http://127.0.0.1:9").to_string(),
        )
        .env(REMOTE_PROXY_KEY_ENV, "phony-fixture-key")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&listed.stdout);
    assert!(
        listed.status.success()
            && stdout
                .lines()
                .any(|line| line.trim() == "builtin/xai/grok-4.6"),
        "status={:?} stdout={stdout} stderr={}",
        listed.status,
        String::from_utf8_lossy(&listed.stderr)
    );
}

#[test]
fn remote_terminal_result_preserves_operator_selected_status() {
    assert!(should_finalize_remote_job(None));
    assert!(should_finalize_remote_job(Some(MissionStatus::Active)));
    // A durable handle proves this is the narrow crash window after the
    // node accepted the job but before Pending was promoted to Active.
    assert!(should_finalize_remote_job(Some(MissionStatus::Pending)));
    for status in [
        MissionStatus::Interrupted,
        MissionStatus::Paused,
        MissionStatus::Blocked,
        MissionStatus::Failed,
    ] {
        assert!(
            !should_finalize_remote_job(Some(status)),
            "terminal node result must not overwrite {status}"
        );
    }
}

#[tokio::test]
async fn remote_dispatch_starts_observer_before_missing_mission_read() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let observer_started = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let started_for_observer = Arc::clone(&observer_started);
    let missing_id = Uuid::new_v4();

    let error = read_dispatched_mission_after_observer_start(&store, missing_id, move || {
        started_for_observer.store(true, std::sync::atomic::Ordering::SeqCst);
    })
    .await
    .expect_err("missing post-dispatch mission must fail the response read");

    assert!(observer_started.load(std::sync::atomic::Ordering::SeqCst));
    assert!(error.contains(&missing_id.to_string()));
}

#[tokio::test]
async fn offline_remote_owner_finalizes_persisted_mission_without_a_session() {
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(
        mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "github:42")
            .await
            .unwrap(),
    );
    let mission = store
        .create_mission(Some("offline remote"), None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();
    let owner = RemoteMissionOwner::offline(Arc::clone(&store));
    let old_job = Uuid::new_v4();
    store
        .begin_mission_run(mission.id, &remote_job_lease_owner(old_job), None)
        .await
        .unwrap();

    finalize_remote_mission(
        &owner,
        mission.id,
        Some(old_job),
        "node-a",
        true,
        "remote result".to_string(),
        "remote_node_job",
        true,
        Some(crate::cost::TokenUsage {
            input_tokens: 11,
            output_tokens: 3,
            cache_read_input_tokens: Some(7),
            ..Default::default()
        }),
        Some(dir.path()),
    )
    .await
    .unwrap();

    let finalized = store.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(finalized.status, MissionStatus::Completed);
    let events = store
        .get_events(mission.id, Some(&["assistant_message"]), None, None)
        .await
        .unwrap();
    assert_eq!(
        events.len(),
        1,
        "offline native finalization remains durable"
    );
    assert_eq!(events[0].content, "remote result");
    assert_eq!(events[0].metadata["usage"]["input_tokens"], 11);
    assert_eq!(events[0].metadata["usage"]["cache_read_input_tokens"], 7);
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .unwrap();
    let next_job = Uuid::new_v4();
    let next = store
        .begin_mission_run(mission.id, &remote_job_lease_owner(next_job), None)
        .await
        .unwrap();
    finalize_remote_mission(
        &owner,
        mission.id,
        Some(old_job),
        "node-a",
        true,
        "duplicate old receipt".into(),
        "remote_node_job",
        true,
        None,
        Some(dir.path()),
    )
    .await
    .unwrap();
    assert_eq!(
        store.get_mission(mission.id).await.unwrap().unwrap().status,
        MissionStatus::Active
    );
    assert_eq!(
        store
            .get_active_mission_run(mission.id)
            .await
            .unwrap()
            .unwrap()
            .run_id,
        next.run_id
    );
    assert_eq!(
        store
            .get_events(mission.id, Some(&["assistant_message"]), None, None)
            .await
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn remote_dispatch_future_not_before_is_not_immediate() {
    let now = chrono::Utc::now();

    assert!(remote_dispatch_is_scheduled_for_future(
        Some("babylon"),
        Some(now + chrono::Duration::minutes(5)),
        now
    ));
    assert!(!remote_dispatch_is_scheduled_for_future(
        Some("babylon"),
        Some(now - chrono::Duration::minutes(5)),
        now
    ));
    assert!(!remote_dispatch_is_scheduled_for_future(
        None,
        Some(now + chrono::Duration::minutes(5)),
        now
    ));
}

#[tokio::test]
async fn activating_waiting_background_clears_first_viewed_at_and_blocks_ack() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("bg resume race"), None, None, None, None, None, None)
        .await
        .expect("mission should be created");
    // The mission parked awaiting the user, was opened (first_viewed_at set),
    // then a background job promoted it to WaitingBackground.
    let long_ago = (chrono::Utc::now() - chrono::Duration::hours(24)).to_rfc3339();
    store
        .set_mission_first_viewed_at_if_unset(mission.id, &long_ago)
        .await
        .expect("set first_viewed_at");
    store
        .update_mission_status(mission.id, MissionStatus::WaitingBackground)
        .await
        .expect("set waiting_background");

    // The auto-resume dequeue path activates the mission to Active.
    assert!(message_activates_mission(MissionStatus::WaitingBackground));
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("activate to Active");

    // Activation cleared the stale first_viewed_at, so once the resumed turn
    // re-parks in AwaitingUser the ack-promotion sweep must not archive it.
    store
        .update_mission_status(mission.id, MissionStatus::AwaitingUser)
        .await
        .expect("re-park in awaiting_user");
    let after = store
        .get_mission(mission.id)
        .await
        .expect("get mission")
        .expect("mission exists");
    assert_eq!(
        after.first_viewed_at, None,
        "activation must clear first_viewed_at"
    );
    let promoted = store
        .acknowledge_stale_awaiting_user_missions(0)
        .await
        .expect("run ack sweep");
    assert!(
        !promoted.contains(&mission.id),
        "a freshly-resumed mission must not be ack-promoted after demotion"
    );
}

#[tokio::test]
async fn terminal_callback_identity_never_infers_unbound_live_event_from_same_status() {
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(
        mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "unbound")
            .await
            .unwrap(),
    );
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .unwrap();
    for _ in 0..2 {
        store
            .update_mission_status(mission.id, MissionStatus::Active)
            .await
            .unwrap();
        let run = store
            .begin_mission_run(mission.id, "test", None)
            .await
            .unwrap();
        store
            .finish_mission_run(run.run_id, run.generation, None)
            .await
            .unwrap();
        store
            .update_mission_status_with_reason(
                mission.id,
                MissionStatus::Blocked,
                Some("second reason"),
            )
            .await
            .unwrap();
    }
    store
        .update_mission_history(
            mission.id,
            &[MissionHistoryEntry {
                role: "assistant".into(),
                content: "second result".into(),
            }],
        )
        .await
        .unwrap();
    let (execution, completion) = callback_snapshot(
        &store,
        mission.id,
        MissionStatus::Blocked,
        None,
        None,
        false,
    )
    .await;
    assert!(execution.is_none());
    assert!(completion.is_none());
    assert!(
        current_callback_snapshot(&store, mission.id, MissionStatus::Blocked)
            .await
            .is_none(),
        "history text alone is not a generation receipt"
    );
    store
        .update_mission_status_with_reason(
            mission.id,
            MissionStatus::Interrupted,
            Some("server_shutdown"),
        )
        .await
        .unwrap();
    let (outage_run, outage) = callback_snapshot(
        &store,
        mission.id,
        MissionStatus::Interrupted,
        None,
        None,
        true,
    )
    .await;
    assert!(outage_run.is_none());
    assert_eq!(
        outage.unwrap().terminal_reason.as_deref(),
        Some("server_shutdown")
    );
    store
        .update_mission_status_with_reason(
            mission.id,
            MissionStatus::Blocked,
            Some("second reason"),
        )
        .await
        .unwrap();
    store
        .log_event(
            mission.id,
            &AgentEvent::MissionStatusChanged {
                execution: None,
                completion: None,
                mission_id: mission.id,
                status: MissionStatus::Blocked,
                summary: Some("legacy current status".into()),
            },
        )
        .await
        .unwrap();
    let (legacy_run, legacy_outcome) =
        callback_snapshot(&store, mission.id, MissionStatus::Blocked, None, None, true).await;
    assert!(legacy_run.is_none());
    assert_eq!(
        legacy_outcome.unwrap().result_summary.as_deref(),
        Some("legacy current status")
    );
    store
        .log_event(
            mission.id,
            &AgentEvent::MissionStatusChanged {
                execution: store.get_latest_mission_run(mission.id).await.unwrap(),
                completion: Some(MissionCompletionSnapshot {
                    result_summary: Some("second result".into()),
                    terminal_reason: Some("second reason".into()),
                    terminal_evidence: None,
                }),
                mission_id: mission.id,
                status: MissionStatus::Blocked,
                summary: None,
            },
        )
        .await
        .unwrap();
    // Only the explicitly current reconciliation observation may acquire
    // the current generation. It is never treated as the old live event.
    let (execution, completion) =
        callback_snapshot(&store, mission.id, MissionStatus::Blocked, None, None, true).await;
    assert_eq!(execution.unwrap().generation, 2);
    assert_eq!(
        completion.unwrap().result_summary.as_deref(),
        Some("second result")
    );
}

#[tokio::test]
async fn terminal_callback_identity_reaches_http_after_release_and_delayed_successor() {
    for resume_before_delivery in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            mission_store::SqliteMissionStore::new(dir.path().join("db"), "http-callback")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(None, None, None, None, None, None, None)
            .await
            .unwrap();
        let first = store
            .begin_mission_run(mission.id, "test", None)
            .await
            .unwrap();
        store
            .finish_mission_run(first.run_id, first.generation, Some("native_goal_stopped"))
            .await
            .unwrap();
        store
            .update_mission_history(
                mission.id,
                &[MissionHistoryEntry {
                    role: "assistant".into(),
                    content: "first generation result".into(),
                }],
            )
            .await
            .unwrap();
        let (tx, rx) = tokio::sync::broadcast::channel(8);
        let mut persist_rx = tx.subscribe();
        maybe_finalize_terminal_mission(
            &store,
            &tx,
            mission.id,
            0,
            Some(TerminalReason::NativeGoalStopped),
            Some("first evidence"),
            None,
            true,
            Some("first generation result"),
            "http callback test",
        )
        .await;
        store
            .log_event(mission.id, &persist_rx.try_recv().unwrap())
            .await
            .unwrap();
        // Queue the actual finalizer event, then acquire a successor BEFORE
        // starting the forwarder. This deterministically exercises delay.
        if resume_before_delivery {
            store
                .update_mission_status(mission.id, MissionStatus::Active)
                .await
                .unwrap();
            let next = store
                .begin_mission_run(mission.id, "test", None)
                .await
                .unwrap();
            assert_eq!(next.generation, 2);
            store
                .finish_mission_run(next.run_id, next.generation, Some("RateLimited"))
                .await
                .unwrap();
            store
                .update_mission_history(
                    mission.id,
                    &[MissionHistoryEntry {
                        role: "assistant".into(),
                        content: "SECOND generation result".into(),
                    }],
                )
                .await
                .unwrap();
            store
                .set_terminal_evidence(mission.id, "SECOND evidence")
                .await
                .unwrap();
            store
                .update_mission_status_with_reason(
                    mission.id,
                    MissionStatus::Failed,
                    Some("rate_limited"),
                )
                .await
                .unwrap();
        }
        let mut markers = super::super::webhook_markers::MarkerStore::load(dir.path());
        markers.set(
            mission.id,
            if resume_before_delivery {
                MissionStatus::Failed
            } else {
                MissionStatus::Active
            },
        );
        let (body_tx, mut body_rx) = tokio::sync::mpsc::channel(2);
        let app = axum::Router::new().route(
            "/",
            axum::routing::post(move |axum::Json(body): axum::Json<serde_json::Value>| {
                let body_tx = body_tx.clone();
                async move {
                    body_tx.send(body).await.unwrap();
                    axum::http::StatusCode::OK
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let workspaces = Arc::new(workspace::WorkspaceStore::new(dir.path().to_path_buf()).await);
        let forwarder = tokio::spawn(paloma_webhook_forwarder_loop(
            Arc::new(std::sync::OnceLock::new()),
            rx,
            store,
            workspaces,
            dir.path().to_path_buf(),
            url,
            None,
            reqwest::Client::new(),
        ));
        let body = tokio::time::timeout(std::time::Duration::from_secs(5), body_rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(body["mission_id"], mission.id.to_string());
        assert_eq!(body["execution"]["run_id"], first.run_id.to_string());
        assert_eq!(body["execution"]["generation"], 1);
        assert_eq!(body["execution"]["state"], "terminal");
        assert_eq!(body["result_summary"], "first generation result");
        assert_eq!(body["terminal_reason"], "native_goal_stopped");
        assert_eq!(body["terminal_evidence"], "first evidence");
        forwarder.abort();
        server.abort();
    }
}

#[tokio::test]
async fn terminal_callback_identity_persists_in_event_history() {
    let dir = tempfile::tempdir().unwrap();
    let store = mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "callback-event")
        .await
        .unwrap();
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .unwrap();
    let run = store
        .begin_mission_run(mission.id, "test", None)
        .await
        .unwrap();
    store
        .finish_mission_run(run.run_id, run.generation, None)
        .await
        .unwrap();
    let event = AgentEvent::MissionStatusChanged {
        completion: Some(MissionCompletionSnapshot {
            result_summary: Some("original result".into()),
            terminal_reason: Some("native_goal_stopped".into()),
            terminal_evidence: Some("original evidence".into()),
        }),
        execution: store.get_latest_mission_run(mission.id).await.unwrap(),
        mission_id: mission.id,
        status: MissionStatus::Blocked,
        summary: None,
    };
    store.log_event(mission.id, &event).await.unwrap();
    drop(store);
    let reopened =
        mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "callback-event")
            .await
            .unwrap();
    let events = reopened
        .get_events(mission.id, None, Some(10), None)
        .await
        .unwrap();
    let restored = events.iter().find_map(stored_event_to_agent_event).unwrap();
    let AgentEvent::MissionStatusChanged {
        execution: Some(identity),
        completion: Some(completion),
        ..
    } = restored
    else {
        panic!("persisted callback lost execution identity");
    };
    assert_eq!(identity.run_id, run.run_id);
    assert_eq!(identity.generation, 1);
    assert_eq!(
        completion.result_summary.as_deref(),
        Some("original result")
    );
    assert_eq!(
        completion.terminal_reason.as_deref(),
        Some("native_goal_stopped")
    );
    assert_eq!(
        completion.terminal_evidence.as_deref(),
        Some("original evidence")
    );
    assert!(identity.execution_state.is_terminal());
    assert_eq!(
        reopened
            .get_latest_mission_run(mission.id)
            .await
            .unwrap()
            .unwrap()
            .run_id,
        run.run_id
    );
}

#[tokio::test]
async fn terminal_callback_identity_survives_lease_release_and_successor() {
    let dir = tempfile::tempdir().unwrap();
    let stores: Vec<Arc<dyn MissionStore>> = vec![
        Arc::new(mission_store::InMemoryMissionStore::new()),
        Arc::new(
            mission_store::FileMissionStore::new(dir.path().join("file"), "callback")
                .await
                .unwrap(),
        ),
        Arc::new(
            mission_store::SqliteMissionStore::new(dir.path().join("sqlite"), "callback")
                .await
                .unwrap(),
        ),
    ];
    for store in stores {
        let mission = store
            .create_mission(None, None, None, None, None, None, None)
            .await
            .unwrap();
        let first = store
            .begin_mission_run(mission.id, "test", None)
            .await
            .unwrap();
        store
            .finish_mission_run(first.run_id, first.generation, Some("native_goal_stopped"))
            .await
            .unwrap();
        assert!(store
            .get_active_mission_run(mission.id)
            .await
            .unwrap()
            .is_none());
        let (tx, mut rx) = tokio::sync::broadcast::channel(8);
        maybe_finalize_terminal_mission(
            &store,
            &tx,
            mission.id,
            0,
            Some(TerminalReason::NativeGoalStopped),
            None,
            None,
            true,
            Some("phase one stopped"),
            "callback test",
        )
        .await;
        let event = rx.try_recv().unwrap();
        let AgentEvent::MissionStatusChanged {
            execution: Some(ref captured),
            ..
        } = event
        else {
            panic!("terminal transition lost execution identity");
        };
        assert_eq!(captured.run_id, first.run_id);
        assert_eq!(captured.generation, 1);
        assert!(captured.execution_state.is_terminal());
        let projection = mission_execution_projection(captured, MissionStatus::Blocked);
        assert_eq!(projection["health"], "healthy");
        assert!(projection["status_conflict"].is_null());
        assert!(projection["ended_at"].is_string());
        let serialized = serde_json::to_value(&event).unwrap();
        store
            .update_mission_status(mission.id, MissionStatus::Active)
            .await
            .unwrap();
        let second = store
            .begin_mission_run(mission.id, "test", None)
            .await
            .unwrap();
        assert_eq!(second.generation, 2);
        assert_eq!(
            store
                .get_latest_mission_run(mission.id)
                .await
                .unwrap()
                .unwrap()
                .run_id,
            second.run_id
        );
        // The queued event is an immutable first-generation receipt even
        // if a same-mission successor has already acquired a live lease.
        assert_eq!(serialized["execution"]["run_id"], first.run_id.to_string());
        store
            .finish_mission_run(second.run_id, second.generation, None)
            .await
            .unwrap();
        assert_eq!(
            store
                .get_latest_mission_run(mission.id)
                .await
                .unwrap()
                .unwrap()
                .run_id,
            second.run_id
        );
    }
}

#[tokio::test]
async fn maybe_finalize_terminal_mission_preserves_interrupted_status() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Shutdown race"), None, None, None, None, None, None)
        .await
        .expect("mission should be created");
    store
        .update_mission_status(mission.id, MissionStatus::Interrupted)
        .await
        .expect("mission should be interrupted");
    let (events_tx, mut events_rx) = tokio::sync::broadcast::channel(8);

    maybe_finalize_terminal_mission(
        &store,
        &events_tx,
        mission.id,
        0,
        Some(TerminalReason::LlmError),
        None,
        None,
        false,
        None,
        "shutdown race test",
    )
    .await;

    let updated = store
        .get_mission(mission.id)
        .await
        .expect("mission lookup should succeed")
        .expect("mission should exist");
    assert_eq!(updated.status, MissionStatus::Interrupted);
    assert_eq!(updated.terminal_reason, None);
    assert!(updated.resumable);
    assert!(events_rx.try_recv().is_err());
}

#[tokio::test]
async fn terminal_turn_parks_while_background_task_is_live() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Background build"), None, None, None, None, None, None)
        .await
        .expect("mission should be created");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("mission should be active");
    let (events_tx, mut events_rx) = tokio::sync::broadcast::channel(8);

    maybe_finalize_terminal_mission(
        &store,
        &events_tx,
        mission.id,
        1,
        Some(TerminalReason::LlmError),
        None,
        None,
        false,
        Some("Claude Code produced no output after its terminal result"),
        "background task test",
    )
    .await;

    let updated = store
        .get_mission(mission.id)
        .await
        .expect("mission lookup should succeed")
        .expect("mission should exist");
    assert_eq!(updated.status, MissionStatus::WaitingBackground);
    assert_eq!(
        updated.terminal_reason.as_deref(),
        Some("background_jobs_running")
    );
    assert!(matches!(
        events_rx.try_recv(),
        Ok(AgentEvent::MissionStatusChanged {
            status: MissionStatus::WaitingBackground,
            ..
        })
    ));
}

#[tokio::test]
async fn maybe_finalize_terminal_mission_skips_low_confidence_completed() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("Weak completion"), None, None, None, None, None, None)
        .await
        .expect("mission should be created");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("mission should be active");
    let (events_tx, mut events_rx) = tokio::sync::broadcast::channel(8);

    maybe_finalize_terminal_mission(
        &store,
        &events_tx,
        mission.id,
        0,
        Some(TerminalReason::Completed),
        None,
        Some(crate::agents::CompletionConfidence::Low),
        true,
        None,
        "low confidence completion test",
    )
    .await;

    let updated = store
        .get_mission(mission.id)
        .await
        .expect("mission lookup should succeed")
        .expect("mission should exist");
    assert_eq!(updated.status, MissionStatus::Active);
    assert!(events_rx.try_recv().is_err());
}

#[test]
fn completion_evidence_marks_recovered_text_completion_low_confidence() {
    let result = crate::agents::AgentResult::success("substantive output", 0)
        .with_terminal_reason(TerminalReason::TurnComplete)
        .with_data(serde_json::json!({ "native_terminal_seen": false }));

    let evidence = completion_evidence_for_agent_result(&result);

    assert_eq!(evidence.terminal_reason, Some(TerminalReason::TurnComplete));
    assert_eq!(
        evidence.completion_signal,
        crate::agents::CompletionSignal::TextFallback
    );
    assert_eq!(
        evidence.completion_confidence,
        crate::agents::CompletionConfidence::Low
    );
    assert!(!evidence.native_terminal_seen);
    assert_eq!(evidence.classification_source, "text_fallback");
}

#[test]
fn completion_evidence_marks_process_failures_with_failure_class() {
    let result = crate::agents::AgentResult::failure("rate limit", 0)
        .with_terminal_reason(TerminalReason::RateLimited);

    let evidence = completion_evidence_for_agent_result(&result);

    assert_eq!(
        evidence.completion_signal,
        crate::agents::CompletionSignal::ProcessExit
    );
    assert_eq!(
        evidence.failure_class,
        Some(crate::agents::FailureClass::RateLimited)
    );
    assert_eq!(
        evidence.completion_confidence,
        crate::agents::CompletionConfidence::High
    );
}

#[test]
fn only_structured_transport_failures_are_auto_resume_eligible() {
    let transport = crate::agents::AgentResult::failure("disconnected", 0)
        .with_terminal_reason(TerminalReason::LlmError)
        .with_data(serde_json::json!({ "transport_failure_stage": "pending_tools" }));
    let provider = crate::agents::AgentResult::failure("provider error", 0)
        .with_terminal_reason(TerminalReason::LlmError);
    let auth = crate::agents::AgentResult::failure("unauthorized", 0)
        .with_terminal_reason(TerminalReason::AuthError);

    assert!(is_transport_failure_evidence(
        &completion_evidence_for_agent_result(&transport)
    ));
    assert!(!is_transport_failure_evidence(
        &completion_evidence_for_agent_result(&provider)
    ));
    assert!(!is_transport_failure_evidence(
        &completion_evidence_for_agent_result(&auth)
    ));
}

#[tokio::test]
async fn grok_transport_recovery_budget_survives_restart_and_event_pagination() {
    let dir = tempfile::tempdir().unwrap();
    let store = mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "grok-retry")
        .await
        .unwrap();
    let mission = store
        .create_mission(
            Some("grok retry"),
            None,
            None,
            None,
            None,
            Some("grok"),
            None,
        )
        .await
        .unwrap();
    // The reservation must be found beyond an arbitrary first page.
    for _ in 0..110 {
        store
            .log_event(
                mission.id,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content: "checkpoint".to_string(),
                    queued: false,
                    mission_id: Some(mission.id),
                    source: Some("api:test".to_string()),
                },
            )
            .await
            .unwrap();
    }
    let mut attempts = HashMap::new();
    assert!(reserve_transport_auto_resume(&store, &mut attempts, mission.id, true, false).await);
    assert!(!reserve_transport_auto_resume(&store, &mut attempts, mission.id, true, false).await);
    drop(store);
    let reopened = mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "grok-retry")
        .await
        .unwrap();
    let mut restarted_actor = HashMap::new();
    assert!(
        !reserve_transport_auto_resume(&reopened, &mut restarted_actor, mission.id, true, false)
            .await
    );
    let reservations = reopened
        .get_events(mission.id, Some(&["error"]), None, None)
        .await
        .unwrap();
    assert_eq!(
        reservations.len(),
        1,
        "serial/parallel retries must share one durable reservation"
    );
    assert_eq!(reservations[0].content, GROK_TRANSPORT_RECOVERY_RESERVED);
}

#[tokio::test]
async fn grok_transport_recovery_gate_fails_closed_without_changing_other_backends() {
    let dir = tempfile::tempdir().unwrap();
    let store = mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "grok-retry")
        .await
        .unwrap();
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .unwrap();
    let db = rusqlite::Connection::open(dir.path().join("missions-grok-retry.db")).unwrap();
    db.execute("DROP TABLE mission_events", []).unwrap();
    let mut attempts = HashMap::new();
    assert!(!reserve_transport_auto_resume(&store, &mut attempts, mission.id, true, false).await);
    let other = Uuid::new_v4();
    for _ in 0..3 {
        assert!(reserve_transport_auto_resume(&store, &mut attempts, other, false, false).await);
    }
    assert!(!reserve_transport_auto_resume(&store, &mut attempts, other, false, false).await);
}

#[tokio::test]
async fn grok_transport_recovery_respects_preexisting_recovery_messages() {
    let dir = tempfile::tempdir().unwrap();
    let store = mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "grok-retry")
        .await
        .unwrap();
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .log_event(
            mission.id,
            &AgentEvent::UserMessage {
                id: Uuid::new_v4(),
                content: "prior recovery".to_string(),
                queued: false,
                mission_id: Some(mission.id),
                source: Some("transport_auto_resume".to_string()),
            },
        )
        .await
        .unwrap();
    assert!(
        !reserve_transport_auto_resume(&store, &mut HashMap::new(), mission.id, true, false).await
    );
}

#[tokio::test]
async fn grok_transport_recovery_cancelled_completion_does_not_consume_or_queue_retry() {
    let dir = tempfile::tempdir().unwrap();
    let store = mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "grok-retry")
        .await
        .unwrap();
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .unwrap();
    let mut attempts = HashMap::new();
    assert!(!reserve_transport_auto_resume(&store, &mut attempts, mission.id, true, true).await);
    assert!(attempts.is_empty());
    assert!(store
        .get_events(mission.id, Some(&["error"]), None, None)
        .await
        .unwrap()
        .is_empty());
    assert!(reserve_transport_auto_resume(&store, &mut attempts, mission.id, true, false).await);
}

#[test]
fn grok_transport_timeout_cannot_be_promoted_to_success() {
    let mut result = crate::agents::AgentResult::failure(
        "Grok ACP transport-idle timeout after 600s without a protocol event; checkout preserved",
        0,
    )
    .with_terminal_reason(TerminalReason::LlmError)
    .with_data(serde_json::json!({
        "failure_class": "transport_error",
        "transport_failure_stage": "grok_acp_transport_idle",
        "grok_acp_transport_failure": true,
    }));
    maybe_recover_soft_llm_error(&mut result);
    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
    assert!(is_grok_acp_transport_failure(&result));
    assert!(is_transport_failure_evidence(
        &completion_evidence_for_agent_result(&result)
    ));
}

#[test]
fn maybe_recover_soft_llm_error_preserves_pending_tool_transport_failure() {
    let mut result = crate::agents::AgentResult::failure(
        "Codex stopped while tool calls were still pending: remote build".to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::LlmError)
    .with_data(serde_json::json!({
        "transport_failure_stage": "pending_tools",
        "pending_tools": ["remote build"]
    }));

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
    assert!(is_transport_failure_evidence(
        &completion_evidence_for_agent_result(&result)
    ));
    assert_eq!(
        completion_evidence_for_agent_result(&result).pending_tools,
        Some(1)
    );
}

#[test]
fn maybe_recover_soft_llm_error_preserves_structured_provider_failure() {
    let mut result = crate::agents::AgentResult::failure(
        "provider: v2: model check failed at model_selection".to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::LlmError)
    .with_data(serde_json::json!({
        "provider_error_source": "provider_driver",
        "failure_class": crate::agents::FailureClass::ProviderError,
        "classification_source": "structured",
    }));

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
    assert_eq!(
        completion_evidence_for_agent_result(&result).failure_class,
        Some(crate::agents::FailureClass::ProviderError)
    );
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_bare_internal_server_error() {
    let mut result = crate::agents::AgentResult::failure("Internal server error".to_string(), 0)
        .with_terminal_reason(TerminalReason::LlmError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_missing_claude_credentials() {
    let mut result = crate::agents::AgentResult::failure(
            "No Claude Code credentials detected. Either run `claude /login` on the host, or authenticate in Settings → AI Providers / set CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY."
                .to_string(),
            0,
        )
        .with_terminal_reason(TerminalReason::LlmError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_structured_codex_model_error() {
    let mut result = crate::agents::AgentResult::failure(
            r#"{"detail":"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account."}"#
                .to_string(),
            0,
        )
        .with_terminal_reason(TerminalReason::LlmError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_provider_payload_error() {
    let mut result = crate::agents::AgentResult::failure(
            "messages.13.content.88.image.source.base64.data: At least one of the image dimensions exceed max allowed size for many-image requests: 2000 pixels"
                .to_string(),
            0,
        )
        .with_terminal_reason(TerminalReason::LlmError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_claude_cli_401() {
    // Regression: Claude Code CLI prints this exact string when
    // Anthropic 401s mid-turn. It was previously upgraded to
    // TurnComplete because the output exceeded 20 chars and
    // didn't match a known bare-error prefix — users then saw the
    // auth error as a successful assistant reply.
    let mut result = crate::agents::AgentResult::failure(
        "Failed to authenticate. API Error: 401 terminated".to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::AuthError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::AuthError));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_generic_api_error_401() {
    // Any short output whose substantive content is an HTTP 401
    // status from the underlying provider should stay classified
    // as AuthError regardless of the leading prefix.
    let mut result = crate::agents::AgentResult::failure(
        "Anthropic returned an error. API Error: 401 Unauthorized".to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::AuthError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::AuthError));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_codex_process_exit() {
    let mut result = crate::agents::AgentResult::failure(
            "Codex CLI exited before completing the turn (exit_status: signal: 9 (SIGKILL)). Stderr: <empty> | Stdout: <empty>"
                .to_string(),
            0,
        )
        .with_terminal_reason(TerminalReason::LlmError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
}

#[test]
fn maybe_recover_soft_llm_error_recovers_substantive_output() {
    let mut result = crate::agents::AgentResult::failure(
        "I completed the implementation and verified the focused build.".to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::LlmError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::TurnComplete));
}

#[test]
fn maybe_recover_soft_llm_error_recovers_substantive_rate_limited_turn() {
    let mut result = crate::agents::AgentResult::failure(
        "Build is running again. While it compiles, I applied the URL bar polish.".to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::RateLimited);

    maybe_recover_soft_llm_error(&mut result);

    assert!(result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::TurnComplete));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_quota_message() {
    let mut result = crate::agents::AgentResult::failure(
        "You've hit your usage limit. Visit the usage settings page to purchase more credits."
            .to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::RateLimited);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::RateLimited));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_claude_transport_failure() {
    let mut result = crate::agents::AgentResult::failure(
        "Claude Code produced no stream events after startup timeout. \
             The Claude CLI started but did not emit any stream-json events."
            .to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::LlmError)
    .with_data(serde_json::json!({
        "claudecode_transport_failure": {
            "stage": "startup",
            "idle_timeout_triggered": false,
            "process_exited_without_result": false,
            "pending_tool_names": [],
        }
    }));

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
}

#[test]
fn maybe_recover_soft_llm_error_does_not_recover_claude_startup_timeout_message() {
    let mut result = crate::agents::AgentResult::failure(
        "Claude Code produced no stream events after startup timeout. \
             More text that pushes it past the 20 char heuristic."
            .to_string(),
        0,
    )
    .with_terminal_reason(TerminalReason::LlmError);

    maybe_recover_soft_llm_error(&mut result);

    assert!(!result.success);
    assert_eq!(result.terminal_reason, Some(TerminalReason::LlmError));
}

#[tokio::test]
async fn test_stop_policy_matches_consecutive_failures() {
    assert!(
        stop_policy_matches_status(
            &mission_store::StopPolicy::WhenFailingConsecutively { count: 2 },
            MissionStatus::Failed,
            2,
            false,
        )
        .await
    );
    assert!(
        !stop_policy_matches_status(
            &mission_store::StopPolicy::WhenFailingConsecutively { count: 2 },
            MissionStatus::Failed,
            1,
            false,
        )
        .await
    );
    assert!(
        stop_policy_matches_status(
            &mission_store::StopPolicy::WhenFailingConsecutively { count: 3 },
            MissionStatus::Failed,
            3,
            false,
        )
        .await
    );
    assert!(
        !stop_policy_matches_status(
            &mission_store::StopPolicy::WhenFailingConsecutively { count: 3 },
            MissionStatus::Failed,
            2,
            false,
        )
        .await
    );
}

#[tokio::test]
async fn test_stop_policy_never_never_matches() {
    assert!(
        !stop_policy_matches_status(
            &mission_store::StopPolicy::Never,
            MissionStatus::Completed,
            0,
            false,
        )
        .await
    );
    assert!(
        !stop_policy_matches_status(
            &mission_store::StopPolicy::Never,
            MissionStatus::Failed,
            5,
            false,
        )
        .await
    );
}

#[tokio::test]
async fn test_stop_policy_when_mission_terminal() {
    assert!(
        !stop_policy_matches_status(
            &mission_store::StopPolicy::WhenMissionTerminal,
            MissionStatus::Active,
            0,
            false,
        )
        .await
    );
    assert!(
        stop_policy_matches_status(
            &mission_store::StopPolicy::WhenMissionTerminal,
            MissionStatus::Acknowledged,
            0,
            false,
        )
        .await
    );
    assert!(mission_is_terminal_for_goal_loop(
        MissionStatus::Interrupted
    ));
    assert!(!mission_is_terminal_for_goal_loop(MissionStatus::Active));
}

#[tokio::test]
async fn test_stop_policy_after_first_fire() {
    assert!(
        !stop_policy_matches_status(
            &mission_store::StopPolicy::AfterFirstFire,
            MissionStatus::Active,
            0,
            false,
        )
        .await,
        "never-fired one-shot stays armed"
    );
    assert!(
        stop_policy_matches_status(
            &mission_store::StopPolicy::AfterFirstFire,
            MissionStatus::Active,
            0,
            true,
        )
        .await,
        "one-shot disables on the tick after it fires"
    );
}

#[tokio::test]
async fn test_validate_rich_tags_resolves_relative_and_blocks_traversal() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();

    let good_path = root.join("chart.png");
    tokio::fs::write(&good_path, b"pngbytes").await.unwrap();

    // Should resolve ./chart.png within working_dir.
    let tags = parse_rich_tags(r#"<image path="./chart.png" alt="Chart" />"#);
    let files = validate_rich_tags(&tags, root, None, None).await;
    assert_eq!(files.len(), 1);
    assert!(files[0].url.contains("path="));

    // Create a file outside working_dir and ensure traversal is blocked.
    let parent = root.parent().expect("parent dir exists");
    let evil_path = parent.join(format!("evil-{}.txt", Uuid::new_v4()));
    tokio::fs::write(&evil_path, b"nope").await.unwrap();

    let tags = parse_rich_tags(&format!(
        r#"<file path="../{}" name="Evil" />"#,
        evil_path.file_name().unwrap().to_string_lossy()
    ));
    let files = validate_rich_tags(&tags, root, None, None).await;
    assert!(files.is_empty());

    let tags = parse_rich_tags(&format!(
        r#"<file path="{}" name="EvilAbs" />"#,
        evil_path.to_string_lossy()
    ));
    let files = validate_rich_tags(&tags, root, None, None).await;
    assert!(files.is_empty());
}

#[test]
fn transcript_visibility_categorizes_known_event_types() {
    assert_eq!(event_visibility("user_message"), "transcript");
    assert_eq!(event_visibility("assistant_message"), "transcript");
    assert_eq!(event_visibility("mission_status_changed"), "transcript");
    assert_eq!(event_visibility("thinking"), "trace");
    assert_eq!(event_visibility("tool_call"), "trace");
    assert_eq!(event_visibility("tool_result"), "trace");
    assert_eq!(event_visibility("text_delta"), "trace");
    assert_eq!(event_visibility("error"), "trace");
    assert_eq!(event_visibility("raw_backend_packet"), "debug");
}

#[test]
fn inactive_stream_summary_collapses_consecutive_cumulative_rows() {
    let event = |sequence, event_type: &str, content: &str| mission_store::StoredEvent {
        id: sequence,
        mission_id: Uuid::nil(),
        sequence,
        event_type: event_type.to_string(),
        timestamp: "2026-05-19T00:00:00Z".to_string(),
        event_id: Some(format!("{event_type}-{sequence}")),
        tool_call_id: None,
        tool_name: None,
        content: content.to_string(),
        metadata: serde_json::json!({}),
    };

    let events = vec![
        event(1, "user_message", "hello"),
        event(2, "thinking", "a"),
        event(3, "thinking", "ab"),
        event(4, "thinking", "abc"),
        event(5, "tool_call", "{}"),
        event(6, "text_delta", "draft"),
        event(7, "text_delta", "draft final"),
        event(8, "assistant_message", "done"),
    ];

    let summary = summarize_inactive_stream_events(events);

    assert_eq!(summary.original_count, 8);
    assert_eq!(summary.summarized_count, 5);
    assert_eq!(summary.events[1].event_type, "thinking");
    assert_eq!(summary.events[1].sequence, 4);
    assert_eq!(summary.events[1].content, "abc");
    assert_eq!(summary.events[3].event_type, "text_delta");
    assert_eq!(summary.events[3].sequence, 7);
    assert_eq!(summary.events[3].content, "draft final");
    // The kept thinking row must close its block for the frontend.
    assert_eq!(summary.events[1].metadata["done"], serde_json::json!(true));
}

fn thinking_test_event(
    sequence: i64,
    event_type: &str,
    content: &str,
    done: Option<bool>,
) -> mission_store::StoredEvent {
    mission_store::StoredEvent {
        id: sequence,
        mission_id: Uuid::nil(),
        sequence,
        event_type: event_type.to_string(),
        timestamp: "2026-05-19T00:00:00Z".to_string(),
        event_id: Some(format!("{event_type}-{sequence}")),
        tool_call_id: None,
        tool_name: None,
        content: content.to_string(),
        metadata: match done {
            Some(done) => serde_json::json!({ "done": done }),
            None => serde_json::json!({}),
        },
    }
}

#[test]
fn stopping_remote_job_is_polled_fast_so_send_now_hands_off_quickly() {
    // Before: the cancel request waited for the next 3 s status check, the
    // terminal receipt for another, and the queue pump for its 3 s tick:
    // up to ~9 s (observed ~7 s) between "interrupted" and the next turn.
    let before = std::time::Duration::from_secs(3) * 3;
    // After: cancel on the next 500 ms tick, terminal seen within one more
    // tick of the node's confirmation, and the pump woken immediately.
    let after = remote_status_poll_delay(true, 0) * 2;
    assert_eq!(after, std::time::Duration::from_secs(1));
    assert!(after * 7 < before);
    // A running job keeps its 3 s cadence; an unreachable stopping node
    // backs off instead of being hammered every 500 ms.
    assert_eq!(
        remote_status_poll_delay(false, 0),
        std::time::Duration::from_secs(3)
    );
    assert_eq!(
        remote_status_poll_delay(true, 2),
        std::time::Duration::from_secs(3)
    );
    assert_eq!(remote_status_poll_delay(false, 7), remote_poll_delay(7));
}

#[test]
fn should_persist_event_skips_incremental_thinking() {
    let mid = Some(Uuid::nil());
    assert!(!should_persist_event(&AgentEvent::Thinking {
        content: "partial".to_string(),
        done: false,
        mission_id: mid,
    }));
    assert!(should_persist_event(&AgentEvent::Thinking {
        content: "full block".to_string(),
        done: true,
        mission_id: mid,
    }));
    assert!(should_persist_event(&AgentEvent::TextDelta {
        content: "text".to_string(),
        mission_id: mid,
    }));
}

#[test]
fn inactive_stream_summary_recovers_content_from_empty_done_finalizer() {
    // Legacy claudecode pattern: cumulative snapshots followed by an
    // empty done:true finalizer. The collapsed row must carry the last
    // non-empty content, not the empty finalizer.
    let events = vec![
        thinking_test_event(1, "thinking", "a", Some(false)),
        thinking_test_event(2, "thinking", "ab", Some(false)),
        thinking_test_event(3, "thinking", "", Some(true)),
    ];

    let summary = summarize_inactive_stream_events(events);

    assert_eq!(summary.summarized_count, 1);
    assert_eq!(summary.events[0].content, "ab");
    assert_eq!(summary.events[0].metadata["done"], serde_json::json!(true));
}

#[test]
fn inactive_stream_summary_keeps_separate_thinking_blocks() {
    // New block-final format: one done:true row per block. Consecutive
    // blocks must NOT be merged.
    let events = vec![
        thinking_test_event(1, "thinking", "first block", Some(true)),
        thinking_test_event(2, "thinking", "second block", Some(true)),
    ];

    let summary = summarize_inactive_stream_events(events);

    assert_eq!(summary.summarized_count, 2);
    assert_eq!(summary.events[0].content, "first block");
    assert_eq!(summary.events[1].content, "second block");
}

#[test]
fn inactive_stream_summary_collapses_legacy_multi_block_runs() {
    // Legacy data with two blocks, each ending in an empty finalizer.
    let events = vec![
        thinking_test_event(1, "thinking", "a", Some(false)),
        thinking_test_event(2, "thinking", "ab", Some(false)),
        thinking_test_event(3, "thinking", "", Some(true)),
        thinking_test_event(4, "thinking", "x", Some(false)),
        thinking_test_event(5, "thinking", "xy", Some(false)),
        thinking_test_event(6, "thinking", "", Some(true)),
    ];

    let summary = summarize_inactive_stream_events(events);

    assert_eq!(summary.summarized_count, 2);
    assert_eq!(summary.events[0].content, "ab");
    assert_eq!(summary.events[1].content, "xy");
}

#[test]
fn inactive_stream_summary_drops_contentless_thinking_block() {
    // A lone empty finalizer (legacy 5506 bug with no preceding deltas)
    // must not produce an empty thought in history.
    let events = vec![
        thinking_test_event(1, "user_message", "hello", None),
        thinking_test_event(2, "thinking", "", Some(true)),
        thinking_test_event(3, "assistant_message", "done", None),
    ];

    let summary = summarize_inactive_stream_events(events);

    assert_eq!(summary.summarized_count, 2);
    assert!(summary.events.iter().all(|e| e.event_type != "thinking"));
}

#[test]
fn inactive_stream_summary_reduces_large_payload_by_ten_x() {
    let mission_id = Uuid::nil();
    let original: Vec<_> = (1..=100)
        .map(|sequence| mission_store::StoredEvent {
            id: sequence,
            mission_id,
            sequence,
            event_type: "thinking".to_string(),
            timestamp: "2026-05-19T00:00:00Z".to_string(),
            event_id: Some(format!("thinking-{sequence}")),
            tool_call_id: None,
            tool_name: None,
            content: "x".repeat(sequence as usize),
            metadata: serde_json::json!({ "done": sequence == 100 }),
        })
        .collect();
    let before_bytes = serde_json::to_vec(&original).unwrap().len();

    let summary = summarize_inactive_stream_events(original);
    let after_bytes = serde_json::to_vec(&summary.events).unwrap().len();

    assert_eq!(summary.original_count, 100);
    assert_eq!(summary.summarized_count, 1);
    assert!(
        before_bytes >= after_bytes * 10,
        "expected >=10x payload drop, before={before_bytes}, after={after_bytes}"
    );
}

#[tokio::test]
async fn broadcast_two_subscribers_each_get_all_events() {
    // Reproduces the production hypothesis: producer sends N events, one
    // subscriber drains immediately, the other lags behind. Both should
    // receive every event as long as they never fall more than
    // `channel_capacity` behind. Mirrors the event-logger / SSE-stream
    // pair attached to the global events_tx in spawn_control_session.
    const CHANNEL_CAPACITY: usize = 8192;
    const N: u32 = 200;
    let (tx, _rx0) = broadcast::channel::<u32>(CHANNEL_CAPACITY);
    let mut rx_fast = tx.subscribe();
    let mut rx_slow = tx.subscribe();

    let producer_tx = tx.clone();
    let producer = tokio::spawn(async move {
        for i in 0..N {
            let _ = producer_tx.send(i);
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
    });

    let consumer_fast = tokio::spawn(async move {
        let mut got = 0u32;
        while let Ok(_ev) = rx_fast.recv().await {
            got += 1;
        }
        got
    });
    let consumer_slow = tokio::spawn(async move {
        let mut got = 0u32;
        loop {
            match tokio::time::timeout(std::time::Duration::from_millis(50), rx_slow.recv()).await {
                Ok(Ok(_ev)) => got += 1,
                Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(broadcast::error::RecvError::Closed)) => break,
                Err(_) => continue,
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        got
    });

    producer.await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drop(tx);
    let fast_count = consumer_fast.await.unwrap();
    let slow_count = consumer_slow.await.unwrap();
    assert_eq!(
        fast_count, N,
        "fast subscriber should receive all {N} events (got {fast_count})"
    );
    assert_eq!(
        slow_count, N,
        "slow subscriber should still receive all {N} events when within buffer (got {slow_count})"
    );
}

#[tokio::test]
async fn broadcast_slow_subscriber_beyond_buffer_loses_events_with_lagged_warning() {
    // Documents the failure mode the production event logger may have
    // hit during mission ab260b2e. If a subscriber is slow enough to
    // fall more than `channel_capacity` events behind, the next
    // recv() returns `Lagged(n)` and the subscriber loses n events. The
    // Tokio broadcast channel does NOT retry or replay; the missed
    // events are gone for that subscriber. Run with `--nocapture` to
    // see the Lagged print.
    const CHANNEL_CAPACITY: usize = 16;
    const PRODUCER_EVENTS: u32 = 1000;
    let (tx, _rx0) = broadcast::channel::<u32>(CHANNEL_CAPACITY);
    let mut rx_fast = tx.subscribe();
    let mut rx_slow = tx.subscribe();

    let producer_tx = tx.clone();
    let producer = tokio::spawn(async move {
        for i in 0..PRODUCER_EVENTS {
            let _ = producer_tx.send(i);
            // Small sleep lets a fast consumer keep up; the slow consumer
            // (below) deliberately adds a much larger delay so the
            // channel buffer (16) overflows for it specifically.
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
    });

    let consumer_fast = tokio::spawn(async move {
        let mut got = 0u32;
        loop {
            match rx_fast.recv().await {
                Ok(_ev) => got += 1,
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
        got
    });
    let consumer_slow = tokio::spawn(async move {
        let mut got = 0u32;
        let mut lagged = 0u64;
        loop {
            match rx_slow.recv().await {
                Ok(_ev) => {
                    got += 1;
                    // Slow consumer: 50ms per event. With a 16-deep
                    // channel and 2ms producer cadence, this consumer
                    // will fall roughly 25 events behind per recv(),
                    // guaranteeing the buffer overflows.
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    lagged = lagged.saturating_add(n);
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
        eprintln!("slow subscriber got {got} events and was lagged by {lagged}");
        (got, lagged)
    });

    producer.await.unwrap();
    // Give consumers time to drain what they can.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drop(tx);
    let fast_count = consumer_fast.await.unwrap();
    let (slow_count, slow_lagged) = consumer_slow.await.unwrap();
    assert_eq!(
        fast_count, PRODUCER_EVENTS,
        "fast subscriber should drain the producer"
    );
    assert!(
        slow_lagged > 0,
        "slow subscriber MUST report Lagged when capacity is {CHANNEL_CAPACITY} \
             and producer sends {PRODUCER_EVENTS} events back-to-back; \
             got fast={fast_count} slow={slow_count} lagged={slow_lagged}"
    );
    assert!(
            (slow_count as u64) + slow_lagged >= PRODUCER_EVENTS as u64,
            "slow subscriber's got+lost should still account for the producer (got={slow_count} lagged={slow_lagged})"
        );
}

#[test]
fn disk_admission_reservations_are_filesystem_scoped_and_exact_at_boundary() {
    let a = DiskReservation {
        mission_id: Uuid::new_v4(),
        filesystem: "filesystem-a".into(),
        estimated_bytes: 20 << 30,
        free_bytes_at_grant: 0,
        workspace_dir: None,
    };
    let b = DiskReservation {
        mission_id: Uuid::new_v4(),
        filesystem: "filesystem-b".into(),
        estimated_bytes: 20 << 30,
        free_bytes_at_grant: 0,
        workspace_dir: None,
    };
    assert_eq!(disk_reservation_outstanding_bytes(&a), 20 << 30);
    assert_eq!(disk_reservation_outstanding_bytes(&b), 20 << 30);

    let emergency = 64 << 30;
    let first = 20 << 30;
    // Hard gate is emergency + candidate only. Paper reserved is a
    // warning budget, never the refuse line.
    assert_eq!(
        disk_admission_hard_required_bytes(emergency, first),
        84 << 30
    );
    assert_eq!(disk_admission_required_bytes(emergency, 0, first), 84 << 30);
    assert_eq!(
        disk_admission_required_bytes(emergency, first, first),
        104 << 30
    );
}

#[test]
fn paper_reservations_do_not_hard_block_when_disk_is_free() {
    let emergency = 64 << 30;
    let candidate = 64 << 30;
    let paper = 5184u64 << 30;
    let available = 2136u64 << 30;
    assert!(
        available >= disk_admission_hard_required_bytes(emergency, candidate),
        "2 TiB free must admit a 64+64 GiB create"
    );
    assert!(
        available < disk_admission_required_bytes(emergency, paper, candidate),
        "the old paper-inclusive formula is what blocked Verity"
    );
}

#[test]
fn terminal_missions_release_disk_admission_reservations() {
    assert!(mission_holds_disk_reservation(MissionStatus::Pending));
    assert!(mission_holds_disk_reservation(MissionStatus::Active));
    assert!(mission_holds_disk_reservation(
        MissionStatus::WaitingBackground
    ));
    assert!(!mission_holds_disk_reservation(MissionStatus::AwaitingUser));
    assert!(!mission_holds_disk_reservation(MissionStatus::Paused));
    assert!(!mission_holds_disk_reservation(MissionStatus::Completed));
    assert!(!mission_holds_disk_reservation(MissionStatus::Failed));
    assert!(!mission_holds_disk_reservation(MissionStatus::Acknowledged));
}

#[test]
fn restart_reconstruction_excludes_persisted_remote_missions() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions.db");
    let local = Uuid::new_v4();
    let remote = Uuid::new_v4();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection.execute_batch(
            "CREATE TABLE missions (id TEXT PRIMARY KEY, status TEXT, workspace_id TEXT, requires_local_disk INTEGER)",
        ).unwrap();
    connection
        .execute(
            "INSERT INTO missions VALUES (?1, 'pending', NULL, 1)",
            rusqlite::params![local.to_string()],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO missions VALUES (?1, 'active', NULL, 0)",
            rusqlite::params![remote.to_string()],
        )
        .unwrap();
    drop(connection);

    let rows = nonterminal_missions_in_sqlite(&path).unwrap();
    // Placement comes from authoritative mission rows, never from the
    // lease ledger. A mixed restart rebuilds only local missions.
    assert_eq!(rows.get(&local), Some(&(None, true)));
    assert_eq!(rows.get(&remote), Some(&(None, false)));
}

#[test]
fn legacy_ledger_deserializes_requires_local_disk_key() {
    let remote = Uuid::new_v4();
    let json = format!(
        r#"{{"version":2,"reservations":{{}},"requires_local_disk":{{"{remote}":false}}}}"#
    );
    let ledger: DiskReservationLedger = serde_json::from_str(&json).unwrap();
    assert_eq!(ledger.legacy_requires_local_disk.get(&remote), Some(&false));
    let serialized = serde_json::to_value(&ledger).unwrap();
    assert!(serialized.get("requires_local_disk").is_none());
    assert!(serialized.get("legacy_requires_local_disk").is_none());
}

#[cfg(unix)]
#[test]
fn outstanding_reservation_uses_allocated_bytes_not_logical_length() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sparse.bin");
    let file = std::fs::File::create(&path).unwrap();
    file.set_len(64 << 30).unwrap();
    drop(file);
    let reservation = DiskReservation {
        mission_id: Uuid::new_v4(),
        filesystem: "fs".into(),
        estimated_bytes: 64 << 30,
        free_bytes_at_grant: 0,
        workspace_dir: Some(dir.path().to_path_buf()),
    };
    let outstanding = disk_reservation_outstanding_bytes(&reservation);
    assert!(
        outstanding > 32 << 30,
        "a sparse 64 GiB file must not consume the full reservation; outstanding={outstanding}"
    );
}

#[test]
fn running_missions_keep_disk_reservations_after_terminal_status() {
    assert!(mission_holds_disk_reservation(MissionStatus::Active));
    // Presentation status is not enough to release: SetMissionStatus must
    // also observe that no runner is active. The helper below is the
    // status half of that conjunction.
    assert!(!mission_holds_disk_reservation(MissionStatus::Completed));
    assert!(!mission_holds_disk_reservation(MissionStatus::Failed));
}

#[test]
fn legacy_ledger_remote_placement_is_migrated_to_sqlite_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions.db");
    let local = Uuid::new_v4();
    let remote = Uuid::new_v4();
    let connection = rusqlite::Connection::open(&path).unwrap();
    // This is the schema just before placement moved out of the ledger.
    connection
        .execute_batch(
            "CREATE TABLE missions (id TEXT PRIMARY KEY, status TEXT, workspace_id TEXT)",
        )
        .unwrap();
    for id in [local, remote] {
        connection
            .execute(
                "INSERT INTO missions VALUES (?1, 'pending', NULL)",
                rusqlite::params![id.to_string()],
            )
            .unwrap();
    }
    drop(connection);

    migrate_legacy_ledger_placement_in_sqlite(
        &path,
        &HashMap::from([(local, true), (remote, false)]),
    )
    .unwrap();
    let rows = nonterminal_missions_in_sqlite(&path).unwrap();
    assert_eq!(rows.get(&local), Some(&(None, true)));
    assert_eq!(rows.get(&remote), Some(&(None, false)));
}

#[test]
fn restart_reconciliation_reads_workspace_identity_from_offline_mission_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missions.db");
    let mission_id = Uuid::new_v4();
    let workspace_id = Uuid::new_v4();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE missions (id TEXT PRIMARY KEY, status TEXT, workspace_id TEXT)",
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO missions (id, status, workspace_id) VALUES (?1, 'pending', ?2)",
            rusqlite::params![mission_id.to_string(), workspace_id.to_string()],
        )
        .unwrap();
    drop(connection);

    let rows = nonterminal_missions_in_sqlite(&path).unwrap();
    // Legacy schemas do not have placement authority, so migration is
    // deliberately conservative: they are local until explicitly moved.
    assert_eq!(rows.get(&mission_id), Some(&(Some(workspace_id), true)));
}

fn test_summary(needs_operator: bool) -> super::mission_store::MissionSummary {
    super::mission_store::MissionSummary {
        title: Some("ask".into()),
        status: "active".into(),
        workspace_name: None,
        awaiting_kind: None,
        needs_operator,
        origin_session_id: None,
        updated_at: "2026-01-01T00:00:00Z".into(),
    }
}

#[test]
fn live_wait_alert_uses_the_tool_start_not_the_ancient_active_event() {
    let mission_id = uuid::Uuid::new_v4();
    let entry = super::live_wait_alert_entry(
        mission_id,
        test_summary(true),
        Some("2026-08-16T12:00:00Z"),
        "2026-08-16T12:05:00Z",
        None,
    );
    assert_eq!(entry.mission_id, mission_id);
    assert_eq!(entry.status, "active");
    assert_eq!(entry.timestamp, "2026-08-16T12:00:00Z");
    assert_eq!(entry.summary, "Waiting for user input");
    assert!(entry.mission.is_some_and(|m| m.needs_operator));
}

#[test]
fn live_wait_alert_falls_back_to_now_when_tool_start_is_missing() {
    let entry = super::live_wait_alert_entry(
        uuid::Uuid::new_v4(),
        test_summary(true),
        None,
        "2026-08-16T12:05:00Z",
        None,
    );
    assert_eq!(entry.timestamp, "2026-08-16T12:05:00Z");
}

#[tokio::test]
async fn failed_tool_scan_marks_user_wait_inventory_incomplete() {
    let now = chrono::Utc::now().to_rfc3339();
    let waiting = MissionRun {
        run_id: Uuid::new_v4(),
        mission_id: Uuid::new_v4(),
        generation: 1,
        execution_state: MissionExecutionState::WaitingUser,
        owner_actor_id: "actor".into(),
        scope_unit: None,
        started_at: now.clone(),
        heartbeat_at: now.clone(),
        stopping_at: None,
        ended_at: None,
        terminal_reason: None,
    };
    let running = MissionRun {
        run_id: Uuid::new_v4(),
        mission_id: Uuid::new_v4(),
        execution_state: MissionExecutionState::Running,
        ..waiting.clone()
    };
    let store = mission_store::InMemoryMissionStore::new();
    store.test_fail_tool_scans();

    assert!(
        user_wait_tool_started_at_checked(&store, &waiting)
            .await
            .is_err(),
        "a failed scan is an error, not a missing tool row"
    );
    assert_eq!(
        user_wait_tool_started_at_checked(&store, &running).await,
        Ok(None),
        "non-waiting runs never touch the tool table"
    );

    let (waits, complete) = user_wait_starts_for_runs_checked(&store, [&waiting, &running]).await;
    assert!(
        !complete,
        "a failed scan must not report a complete inventory"
    );
    assert!(
        waits.contains_key(&waiting.mission_id),
        "the run is still known to be waiting even without a clock"
    );
    assert_eq!(waits.get(&waiting.mission_id), Some(&None));
    assert!(!waits.contains_key(&running.mission_id));
}

#[test]
fn stream_bounded_commit_gate_caps_open_tail_bytes_with_zero_divergences() {
    let mission_id = Uuid::new_v4();
    let mut buffers = HashMap::new();
    let unclosed_fence = format!("```rust\n{}", "x".repeat(12_000));
    let _ = streaming::text_op_events_for_stream(
        AgentEvent::TextDelta {
            content: unclosed_fence,
            mission_id: Some(mission_id),
        },
        &mut buffers,
    );

    let forced =
        streaming::evaluate_stream_bounded_commit_gate(1_000, 200, 200, 20_000, 200, 4_096);
    assert!(forced.admitted);
    assert!(forced.checkpoint_forced);
    assert_eq!(forced.next_checkpoint, 20_000 - 4_096);

    let non_mono = streaming::evaluate_stream_bounded_commit_gate(500, 200, 100, 600, 250, 4_096);
    assert!(!non_mono.admitted);
    assert_eq!(non_mono.next_checkpoint, 100);

    let snap = streaming::stream_bounded_commit_shadow_counter()
        .snapshot("orb_stream_bounded_commit_step");
    assert!(snap.total_events >= 3);
    assert_eq!(snap.total_divergences, 0);
}
