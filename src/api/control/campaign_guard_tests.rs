use super::*;

async fn mk_campaign(store: &Arc<dyn MissionStore>, project: &str) -> Uuid {
    let mission = store
        .create_mission(Some("campaign"), None, None, None, None, None, None)
        .await
        .expect("create");
    store
        .update_mission_project(
            mission.id,
            mission_store::MissionProjectPatch {
                project: Some(Some(project.to_string())),
                track: Some(Some("campaign".to_string())),
                ..Default::default()
            },
        )
        .await
        .expect("tag");
    mission.id
}

async fn mk_tracked(store: &Arc<dyn MissionStore>, project: &str, track: &str) -> Uuid {
    let mission = store
        .create_mission(Some(track), None, None, None, None, None, None)
        .await
        .expect("create");
    store
        .update_mission_project(
            mission.id,
            mission_store::MissionProjectPatch {
                project: Some(Some(project.to_string())),
                track: Some(Some(track.to_string())),
                ..Default::default()
            },
        )
        .await
        .expect("tag");
    mission.id
}

/// A mission with an explicit model selection and a live native session,
/// as it exists on disk before any turn is dispatched.
async fn mk_selected(store: &Arc<dyn MissionStore>, backend: &str, model: Option<&str>) -> Mission {
    let mission = store
        .create_mission(Some("selected"), None, None, None, None, None, None)
        .await
        .expect("create");
    store
        .update_mission_run_settings(
            mission.id,
            Some(backend),
            Some(Some("writer")),
            Some(model.map(|m| m).map(Some).unwrap_or(None)),
            Some(Some("high")),
            Some(true),
            None,
            Some(Some("telegram")),
            "native-session-1",
        )
        .await
        .expect("settings");
    store
        .get_mission(mission.id)
        .await
        .expect("load")
        .expect("present")
}

#[tokio::test]
async fn dispatch_never_drops_a_model_this_deployment_still_runs() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    // The regression this guards: returning None here silently erased the
    // user's selection and fell back to the harness default.
    for (backend, model) in [
        ("codex", "gpt-6-astra"),
        ("codex", "gpt-5.6-sol"),
        ("claudecode", crate::model_policy::CURRENT_CLAUDE_FABLE),
        ("claudecode", crate::model_policy::CURRENT_CLAUDE_OPUS),
        ("claudecode", "claude-sonnet-4-6"),
        ("grok", "grok-4.6"),
        ("opencode", "xai/grok-4.6"),
        ("opencode", "anthropic/claude-opus-5"),
    ] {
        let mission = mk_selected(&store, backend, Some(model)).await;
        assert_eq!(
            model_for_dispatch(&store, &mission).await.as_deref(),
            Some(model),
            "{backend}/{model} must reach the runner unchanged"
        );
        let reloaded = store.get_mission(mission.id).await.unwrap().unwrap();
        assert_eq!(reloaded.model_override.as_deref(), Some(model));
    }
}

#[tokio::test]
async fn dispatch_leaves_an_unset_model_unset() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = mk_selected(&store, "claudecode", None).await;
    assert_eq!(mission.model_override, None);
    assert_eq!(model_for_dispatch(&store, &mission).await, None);
    let reloaded = store.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(reloaded.model_override, None, "no override was invented");
}

#[tokio::test]
async fn dispatch_upgrades_a_retired_model_and_records_it() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = mk_selected(&store, "claudecode", Some("claude-opus-4-1")).await;
    let before = store.get_mission(mission.id).await.unwrap().unwrap();

    let effective = model_for_dispatch(&store, &mission).await;
    assert_eq!(
        effective.as_deref(),
        Some(crate::model_policy::CURRENT_CLAUDE_OPUS)
    );

    // What clients read must match what the turn will run — the whole point
    // of persisting the upgrade rather than only applying it in the runner.
    let after = store.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(after.model_override.as_deref(), effective.as_deref());

    // A model change must not cost the conversation its native session, its
    // history, or any other run setting.
    assert_eq!(after.session_id, before.session_id);
    assert!(
        after.session_id.is_some(),
        "session was preserved, not cleared"
    );
    assert_eq!(after.backend, before.backend);
    assert_eq!(after.agent, before.agent);
    assert_eq!(after.model_effort, before.model_effort);
    assert_eq!(after.fast_mode, before.fast_mode);
    assert_eq!(after.config_profile, before.config_profile);
    assert_eq!(after.history.len(), before.history.len());
    assert_eq!(after.created_at, before.created_at);
}

#[tokio::test]
async fn dispatch_keeps_the_provider_prefix_when_upgrading() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    // OpenCode addresses models as provider/model; dropping the prefix
    // would produce an id it cannot resolve.
    let mission = mk_selected(&store, "opencode", Some("anthropic/claude-opus-4-8")).await;
    assert_eq!(
        model_for_dispatch(&store, &mission).await.as_deref(),
        Some("anthropic/claude-opus-5")
    );
    let after = store.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(
        after.model_override.as_deref(),
        Some("anthropic/claude-opus-5")
    );
}

#[tokio::test]
async fn a_turn_is_refused_rather_than_run_on_a_retired_model() {
    use crate::api::mission_runner::refuse_retired_model;

    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = mk_selected(&store, "claudecode", Some("claude-opus-4-1")).await;

    // Make the upgrade unrecordable: the write `model_for_dispatch` needs
    // now fails, exactly as it would against an unavailable store.
    assert!(store.delete_mission(mission.id).await.expect("delete"));

    // Dispatch hands back the stored id rather than a model nothing reports.
    let dispatched = model_for_dispatch(&store, &mission)
        .await
        .expect("a model is still resolved");
    assert_eq!(dispatched, "claude-opus-4-1");

    // The pre-harness guard then refuses the turn. This is the fail-closed
    // half: no harness is spawned, locally or remotely, and the retired
    // model never runs.
    let refusal = refuse_retired_model(mission.id, &dispatched)
        .expect("a retired model must not reach a harness");
    assert!(!refusal.success);
    assert_eq!(refusal.cost_cents, 0);
    assert!(refusal.output.contains("claude-opus-4-1"));
    assert!(refusal
        .output
        .contains(crate::model_policy::CURRENT_CLAUDE_OPUS));
    assert!(
        refusal.output.contains("Nothing was started"),
        "the refusal must say no work began: {}",
        refusal.output
    );
}

#[tokio::test]
async fn the_guard_never_refuses_a_model_this_deployment_runs() {
    use crate::api::mission_runner::refuse_retired_model;

    let id = Uuid::new_v4();
    for allowed in [
        crate::model_policy::CURRENT_CLAUDE_OPUS,
        crate::model_policy::CURRENT_CLAUDE_FABLE,
        "claude-opus-6",
        "claude-opus-5-20260101",
        "claude-sonnet-4-6",
        "gpt-6-astra",
        "grok-4.6",
        "anthropic/claude-opus-5",
    ] {
        assert!(
            refuse_retired_model(id, allowed).is_none(),
            "{allowed} must be allowed to run"
        );
    }
}

#[tokio::test]
async fn dispatch_does_not_downgrade_a_newer_model() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    for newer in [
        "claude-opus-6",
        "claude-fable-6-1",
        "claude-opus-5-20260101",
    ] {
        let mission = mk_selected(&store, "claudecode", Some(newer)).await;
        assert_eq!(
            model_for_dispatch(&store, &mission).await.as_deref(),
            Some(newer),
            "{newer} must not be rewritten"
        );
    }
}

#[tokio::test]
async fn nonterminal_missions_for_project_counts_the_live_footprint() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    assert!(nonterminal_missions_for_project(&store, "proj")
        .await
        .is_empty());

    let a = mk_tracked(&store, "proj", "alpha").await;
    mk_tracked(&store, "proj", "beta").await;
    mk_tracked(&store, "other", "alpha").await; // different project — excluded

    let live = nonterminal_missions_for_project(&store, "proj").await;
    assert_eq!(
        live.len(),
        2,
        "counts only this project's non-terminal missions"
    );
    // The (project, track) dedup key: track 'alpha' is present exactly once.
    assert_eq!(
        live.iter()
            .filter(|m| m.project.track.as_deref() == Some("alpha"))
            .count(),
        1
    );

    // A terminal mission drops out of the footprint (frees the cap slot).
    store
        .update_mission_status(a, MissionStatus::Completed)
        .await
        .expect("complete");
    assert_eq!(
        nonterminal_missions_for_project(&store, "proj").await.len(),
        1
    );
}

#[tokio::test]
async fn goal_digest_reads_durable_goal_independently_of_mission_mode() {
    let dir = tempfile::tempdir().unwrap();
    let store =
        mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "goal-digest-test")
            .await
            .unwrap();
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .unwrap();
    let objective = "🦀".repeat(1500);
    store
        .update_mission_goal(mission.id, true, Some(&objective))
        .await
        .unwrap();
    drop(store);
    let reopened =
        mission_store::SqliteMissionStore::new(dir.path().to_path_buf(), "goal-digest-test")
            .await
            .unwrap();
    let loaded = reopened.get_mission(mission.id).await.unwrap().unwrap();
    let digest = mission_goal_digest(&loaded);
    assert_eq!(digest["mission_mode"], "task");
    assert_eq!(digest["goal_mode"], true);
    assert_eq!(
        digest["goal_objective"].as_str().unwrap().chars().count(),
        1001
    );
    assert!(digest["goal_objective"].as_str().unwrap().ends_with('…'));
    let listed = reopened.list_missions(10, 0).await.unwrap();
    assert_eq!(mission_goal_digest(&listed[0]), digest);
    reopened
        .update_mission_goal(mission.id, false, None)
        .await
        .unwrap();
    let cleared = reopened.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(
        mission_goal_digest(&cleared),
        serde_json::json!({
            "mission_mode": "task", "goal_mode": false, "goal_objective": null,
        })
    );
}

#[tokio::test]
async fn control_continuation_validates_against_stored_identity_without_mutation() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(Some("RESERVE-1"), None, None, None, None, None, None)
        .await
        .unwrap();
    store
        .update_mission_project(
            mission.id,
            mission_store::MissionProjectPatch {
                track: Some(Some("trio-reserve1".into())),
                tags: Some(vec!["pr-readonly".into()]),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let loaded = store.get_mission(mission.id).await.unwrap().unwrap();
    let request: ControlMessageRequest = serde_json::from_value(serde_json::json!({
        "mission_id": mission.id, "content": "Continue RESERVE-1 on PR 244; exclude PR #230.",
        "continue_identity": {"project": null, "track": "trio-reserve1", "github_pr": null}
    }))
    .unwrap();
    assert!(request.extra.is_empty());
    let patch = dispatch_identity_patch(
        request.github_pr,
        request.track,
        request.title,
        Some(request.content),
        request.continue_identity,
    );
    let next = writer_reuse_or_conflict(&loaded, &patch).unwrap();
    assert_eq!(next.track, loaded.project.track);
    assert_eq!(next.github_pr, None);
    let unchanged = store.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(unchanged.project.tags, vec!["pr-readonly"]);
    let resume: ResumeMissionRequest = serde_json::from_value(serde_json::json!({
            "content": "Different work PR #90", "continue_identity": {"project": null, "track": "different", "github_pr": null}
        })).unwrap();
    let err = writer_reuse_or_conflict(
        &loaded,
        &dispatch_identity_patch(
            resume.github_pr,
            resume.track,
            resume.title,
            resume.content,
            resume.continue_identity,
        ),
    )
    .unwrap_err();
    assert_eq!(err.0, StatusCode::CONFLICT);
}

#[tokio::test]
async fn silent_recycle_of_pr88_writer_as_reserve_is_rejected() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("Repair Lido PR #88"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create");
    store
        .update_mission_project(
            mission.id,
            mission_store::MissionProjectPatch {
                github_pr: Some(Some("lfglabs-dev/lido-srv3-proof-closure#88".to_string())),
                track: Some(Some("pr-88-repair".to_string())),
                ..Default::default()
            },
        )
        .await
        .expect("tag");
    let loaded = store.get_mission(mission.id).await.unwrap().unwrap();
    let err = writer_reuse_or_conflict(
        &loaded,
        &dispatch_identity_patch(
            None,
            None,
            None,
            Some("Implement P-RESERVE-RELATIONAL first slice".into()),
            None,
        ),
    )
    .expect_err("silent recycle");
    assert_eq!(err.0, StatusCode::CONFLICT);
    assert!(err.1.contains("writer_identity_stale"));

    let updated = writer_reuse_or_conflict(
        &loaded,
        &dispatch_identity_patch(
            Some(String::new()),
            Some("p-reserve-relational".into()),
            Some("P-RESERVE-RELATIONAL first slice".into()),
            Some("Implement P-RESERVE-RELATIONAL first slice".into()),
            None,
        ),
    )
    .expect("explicit retag");
    assert_eq!(updated.github_pr.as_deref(), None);
    assert_eq!(updated.track.as_deref(), Some("p-reserve-relational"));
}

#[tokio::test]
async fn same_work_followup_without_pr_mention_is_accepted() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("Repair Lido PR #88"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create");
    store
        .update_mission_project(
            mission.id,
            mission_store::MissionProjectPatch {
                github_pr: Some(Some("lfglabs-dev/lido-srv3-proof-closure#88".to_string())),
                track: Some(Some("pr-88-repair".to_string())),
                ..Default::default()
            },
        )
        .await
        .expect("tag");
    let loaded = store.get_mission(mission.id).await.unwrap().unwrap();
    writer_reuse_or_conflict(
        &loaded,
        &dispatch_identity_patch(None, None, None, Some("fix the failing test".into()), None),
    )
    .expect("same-work chat must not 409");
    let updated = store.get_mission(mission.id).await.unwrap().unwrap();
    assert_eq!(
        updated.project.github_pr.as_deref(),
        Some("lfglabs-dev/lido-srv3-proof-closure#88")
    );
    assert_eq!(updated.project.track.as_deref(), Some("pr-88-repair"));
    assert_eq!(updated.title.as_deref(), Some("Repair Lido PR #88"));
}

#[tokio::test]
async fn untagged_new_mission_opening_message_is_accepted() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(None, None, None, None, None, None, None)
        .await
        .expect("create");
    let loaded = store.get_mission(mission.id).await.unwrap().unwrap();
    writer_reuse_or_conflict(
        &loaded,
        &dispatch_identity_patch(
            None,
            None,
            None,
            Some("Continue from PR #105. Launch P-TOPUP-2 and P-ALLOC-1.".into()),
            None,
        ),
    )
    .expect("blank writer first message must not 409");
}

#[test]
fn dispatch_gate_blocks_paused_and_archived_only() {
    // paused → 423 Locked; archived → 409 Conflict.
    assert_eq!(
        dispatch_gate_for_status("paused"),
        Some((StatusCode::LOCKED, "project_paused"))
    );
    assert_eq!(
        dispatch_gate_for_status("archived"),
        Some((StatusCode::CONFLICT, "project_archived"))
    );
    // Active (and any unknown/legacy status) permits dispatch.
    assert_eq!(dispatch_gate_for_status("active"), None);
    assert_eq!(dispatch_gate_for_status(""), None);
    assert_eq!(dispatch_gate_for_status("blocked"), None);
}

#[tokio::test]
async fn second_campaign_is_blocked_until_the_first_terminates() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    // No campaign yet: the slot is free (first create would succeed).
    assert!(find_open_campaign_mission(&store, "verity").await.is_none());

    let first = mk_campaign(&store, "verity").await;
    // Second create for the same project sees the open campaign → 409.
    let existing = find_open_campaign_mission(&store, "verity")
        .await
        .expect("open campaign found");
    assert_eq!(existing.id, first);
    // A different project is unaffected.
    assert!(find_open_campaign_mission(&store, "other").await.is_none());

    // Every listed non-terminal status holds the slot.
    for status in [
        MissionStatus::Active,
        MissionStatus::AwaitingUser,
        MissionStatus::WaitingBackground,
        MissionStatus::Paused,
    ] {
        store
            .update_mission_status(first, status)
            .await
            .expect("status");
        assert!(
            find_open_campaign_mission(&store, "verity").await.is_some(),
            "{status} should hold the campaign slot"
        );
    }

    // Once the first completes, a new campaign is allowed.
    store
        .update_mission_status(first, MissionStatus::Completed)
        .await
        .expect("status");
    assert!(find_open_campaign_mission(&store, "verity").await.is_none());
    let second = mk_campaign(&store, "verity").await;
    assert_ne!(first, second);
    assert_eq!(
        find_open_campaign_mission(&store, "verity")
            .await
            .expect("new open campaign")
            .id,
        second
    );
}

#[tokio::test]
async fn live_mission_on_workspace_is_the_unique_occupant() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let writer = store
        .create_mission(
            Some("writer"),
            Some(Uuid::new_v4()),
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create");
    store
        .update_mission_status(writer.id, MissionStatus::Active)
        .await
        .expect("active");
    let occupant = live_mission_on_workspace(&store, writer.workspace_id, None, None)
        .await
        .expect("occupant");
    assert_eq!(occupant.id, writer.id);
    store
        .update_mission_status(writer.id, MissionStatus::Completed)
        .await
        .expect("complete");
    assert!(
        live_mission_on_workspace(&store, writer.workspace_id, None, None)
            .await
            .is_none(),
        "a finished writer frees the worktree"
    );
}

#[tokio::test]
async fn cloud_conversations_do_not_occupy_native_workspaces() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let workspace = Uuid::new_v4();
    for backend in ["cloud_chatgpt", "cloud_grok_bot", "cloud_cursor"] {
        let mission = store
            .create_mission(
                Some("cloud"),
                Some(workspace),
                None,
                None,
                None,
                Some(backend),
                None,
            )
            .await
            .unwrap();
        store
            .update_mission_status(mission.id, MissionStatus::AwaitingUser)
            .await
            .unwrap();
    }
    assert!(live_mission_on_workspace(&store, workspace, None, None)
        .await
        .is_none());
    let native = store
        .create_mission(
            Some("native"),
            Some(workspace),
            None,
            None,
            None,
            Some("codex"),
            None,
        )
        .await
        .unwrap();
    store
        .update_mission_status(native.id, MissionStatus::Active)
        .await
        .unwrap();
    assert_eq!(
        live_mission_on_workspace(&store, workspace, None, None)
            .await
            .unwrap()
            .id,
        native.id
    );
}

#[tokio::test]
async fn default_workspace_is_occupied_only_through_the_same_directory() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let host = workspace::DEFAULT_WORKSPACE_ID;
    let mut ids = Vec::new();
    for backend in ["claudecode", "codex"] {
        let mission = store
            .create_mission(
                Some(backend),
                Some(host),
                None,
                None,
                None,
                Some(backend),
                None,
            )
            .await
            .unwrap();
        ids.push(mission.id);
    }
    // An idle Claude chat elsewhere on the host; the Codex source is blocked.
    store
        .update_mission_status(ids[0], MissionStatus::AwaitingUser)
        .await
        .unwrap();
    store
        .update_mission_status(ids[1], MissionStatus::Blocked)
        .await
        .unwrap();
    let source_dir = format!("/root/workspaces/mission-{}", &ids[1].to_string()[..8]);
    assert!(live_mission_on_workspace(&store, host, None, None)
        .await
        .is_none());
    assert!(
        live_mission_on_workspace(&store, host, Some(&source_dir), None)
            .await
            .is_none(),
        "forking a blocked mission must not collide with unrelated host chats"
    );
    store
        .update_mission_status(ids[1], MissionStatus::Active)
        .await
        .unwrap();
    assert_eq!(
        live_mission_on_workspace(&store, host, Some(&source_dir), None)
            .await
            .unwrap()
            .id,
        ids[1],
        "a live source still owns its directory"
    );
    assert_eq!(
        live_mission_on_workspace(&store, host, Some(&format!("{source_dir}/repo")), None)
            .await
            .unwrap()
            .id,
        ids[1],
        "a directory below the mission root is the same worktree"
    );
}

#[tokio::test]
async fn child_directory_occupancy_excludes_only_its_parent() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let host = workspace::DEFAULT_WORKSPACE_ID;
    let parent = store
        .create_mission_with_parent(
            Some("parent"),
            Some(host),
            None,
            None,
            None,
            false,
            None,
            None,
            None,
            Some("/repo"),
        )
        .await
        .unwrap();
    assert!(
        live_mission_on_workspace(&store, host, Some("/repo"), Some(parent.id))
            .await
            .is_none()
    );
    let unrelated = store
        .create_mission_with_parent(
            Some("unrelated"),
            Some(host),
            None,
            None,
            None,
            false,
            None,
            None,
            None,
            Some("/repo"),
        )
        .await
        .unwrap();
    assert_eq!(
        live_mission_on_workspace(&store, host, Some("/repo"), Some(parent.id))
            .await
            .unwrap()
            .id,
        unrelated.id
    );
    assert!(
        live_mission_on_workspace(&store, host, Some("/other-worktree"), Some(parent.id))
            .await
            .is_none()
    );
}

#[test]
fn one_directory_written_differently_is_the_same_directory() {
    use std::path::Path;
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().join("repo");
    std::fs::create_dir(&repo).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&repo, root.path().join("alias")).unwrap();
    assert!(same_directory(&repo, &root.path().join("repo/../repo/.")));
    #[cfg(unix)]
    assert!(same_directory(&repo, &root.path().join("alias")));
    assert!(same_directory(Path::new("repo"), &repo));
    assert!(same_directory(
        Path::new("/gone/work/./a/../repo"),
        Path::new("/gone/work/repo")
    ));
    assert!(same_directory(&repo, &repo.join("src/deep")));
    #[cfg(unix)]
    {
        // link -> repo/src: link/../docs is repo/docs, not <root>/docs.
        std::fs::create_dir(repo.join("src")).unwrap();
        std::os::unix::fs::symlink(repo.join("src"), root.path().join("link")).unwrap();
        assert!(same_directory(
            &root.path().join("link/../docs"),
            &repo.join("docs")
        ));
        assert!(!same_directory(
            &root.path().join("link/../docs"),
            &root.path().join("docs")
        ));
    }
    assert!(!same_directory(&repo, &root.path().join("other")));
    assert!(!same_directory(&repo, &root.path().join("repo-two")));
    assert!(!same_directory(Path::new("po"), &repo));
    assert!(!same_directory(Path::new(""), &repo));
}

#[tokio::test]
async fn recent_codex_oauth_invalidation_detects_chatgpt_refresh_death() {
    let store: Arc<dyn MissionStore> = Arc::new(mission_store::InMemoryMissionStore::new());
    let mission = store
        .create_mission(
            Some("E1 parallel"),
            None,
            None,
            None,
            None,
            Some("codex"),
            None,
        )
        .await
        .expect("create");
    store
        .update_mission_status(mission.id, MissionStatus::Failed)
        .await
        .expect("fail");
    store
            .update_mission_metadata(
                mission.id,
                None,
                Some(Some(
                    "auth refresh request failed: ChatGPT OAuth refresh failed: OpenAI OAuth refresh failed (401 Unauthorized): refresh_token_invalidated",
                )),
                None,
                None,
                None,
            )
            .await
            .expect("desc");
    assert!(chatgpt_oauth_refresh_invalidated(
        "sandboxed-sh: ChatGPT OAuth refresh failed: refresh_token_invalidated"
    ));
    assert!(
        recent_codex_oauth_invalidation(&store).await.is_some(),
        "a fresh Codex OAuth death must trip the gate"
    );
}

#[test]
fn terminal_and_archived_statuses_do_not_hold_the_slot() {
    for status in [
        MissionStatus::Completed,
        MissionStatus::Failed,
        MissionStatus::Interrupted,
        MissionStatus::Blocked,
        MissionStatus::NotFeasible,
        MissionStatus::Acknowledged,
    ] {
        assert!(!campaign_slot_held_by(status), "{status}");
    }
}
