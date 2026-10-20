use super::SqliteMissionStore;
use crate::api::mission_store::{MissionFilter, MissionProjectPatch, MissionStatus, MissionStore};

async fn store(dir: &tempfile::TempDir) -> SqliteMissionStore {
    SqliteMissionStore::new(dir.path().to_path_buf(), "filter-user")
        .await
        .expect("sqlite store")
}

async fn seed(
    store: &SqliteMissionStore,
    title: &str,
    project: Option<&str>,
    track: Option<&str>,
    origin_session: Option<&str>,
) -> uuid::Uuid {
    let mission = store
        .create_mission_with_parent(
            Some(title),
            None,
            None,
            None,
            None,
            false,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("create mission");
    if project.is_some() || track.is_some() {
        store
            .update_mission_project(
                mission.id,
                MissionProjectPatch {
                    project: Some(project.map(str::to_string)),
                    track: Some(track.map(str::to_string)),
                    ..Default::default()
                },
            )
            .await
            .expect("tag mission");
    }
    if let Some(session) = origin_session {
        store
            .set_mission_origin(mission.id, "hermes", Some(session))
            .await
            .expect("set origin");
    }
    mission.id
}

/// The regression that motivated the pushdown: the in-memory scan gave up
/// after 5 000 rows, so a conversation whose missions had scrolled past it
/// silently showed zero workers. SQL has no such horizon.
#[tokio::test]
async fn finds_a_match_buried_under_a_large_fleet() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;

    let needle = seed(&store, "needle", Some("verity"), None, Some("sess-old")).await;
    for i in 0..250 {
        seed(&store, &format!("noise {i}"), Some("other"), None, None).await;
    }

    let found = store
        .list_missions_filtered(
            &MissionFilter {
                origin_session_id: Some("sess-old".into()),
                ..Default::default()
            },
            50,
            0,
        )
        .await
        .expect("filtered list");
    assert_eq!(found.len(), 1, "the buried match must still be returned");
    assert_eq!(found[0].id, needle);
}

#[tokio::test]
async fn project_prefix_matches_the_family_and_nothing_adjacent() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;

    seed(&store, "family root", Some("verity"), None, None).await;
    seed(&store, "phase", Some("verity-phase1d"), None, None).await;
    seed(&store, "lookalike", Some("verityx"), None, None).await;
    seed(&store, "reversed", Some("x-verity"), None, None).await;

    let found = store
        .list_missions_filtered(
            &MissionFilter {
                project_prefix: Some("verity".into()),
                ..Default::default()
            },
            50,
            0,
        )
        .await
        .expect("filtered list");
    let projects: Vec<String> = found
        .iter()
        .filter_map(|m| m.project.project.clone())
        .collect();
    assert_eq!(projects.len(), 2, "got {projects:?}");
    assert!(projects.contains(&"verity".to_string()));
    assert!(projects.contains(&"verity-phase1d".to_string()));
}

/// `project` must stay EXACT — widening it would silently change what
/// every existing caller (dashboard, iOS, Paloma) gets back.
#[tokio::test]
async fn project_filter_stays_exact() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    seed(&store, "root", Some("verity"), None, None).await;
    seed(&store, "phase", Some("verity-phase1d"), None, None).await;

    let found = store
        .list_missions_filtered(
            &MissionFilter {
                project: Some("verity".into()),
                ..Default::default()
            },
            50,
            0,
        )
        .await
        .expect("filtered list");
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].project.project.as_deref(), Some("verity"));
}

#[tokio::test]
async fn attention_only_hides_acknowledged_completed_and_superseded() {
    use crate::api::control::events::MissionStatus;
    use crate::api::mission_store::{MissionStore, SUPERSEDED_TAG};

    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    let live = seed(&store, "live", Some("verity"), Some("core"), None).await;
    let acked = seed(&store, "acked", Some("verity"), Some("old"), None).await;
    let done = seed(&store, "done", Some("verity"), Some("old"), None).await;
    let absorbed = seed(&store, "absorbed", Some("verity"), Some("core"), None).await;
    store
        .update_mission_status(acked, MissionStatus::Acknowledged)
        .await
        .expect("ack");
    store
        .update_mission_status(done, MissionStatus::Completed)
        .await
        .expect("complete");
    store
        .update_mission_project(
            absorbed,
            MissionProjectPatch {
                tags: Some(vec![SUPERSEDED_TAG.to_string()]),
                ..Default::default()
            },
        )
        .await
        .expect("tag superseded");

    let found = store
        .list_missions_filtered(
            &MissionFilter {
                project: Some("verity".into()),
                attention_only: true,
                ..Default::default()
            },
            50,
            0,
        )
        .await
        .expect("filtered list");
    let ids: Vec<_> = found.iter().map(|m| m.id).collect();
    assert!(ids.contains(&live));
    assert!(!ids.contains(&acked));
    assert!(!ids.contains(&done));
    assert!(!ids.contains(&absorbed));
}

#[tokio::test]
async fn track_filter_and_offset_count_matches_not_rows() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    for i in 0..3 {
        seed(
            &store,
            &format!("t{i}"),
            Some("verity"),
            Some("core-c3"),
            None,
        )
        .await;
        seed(
            &store,
            &format!("n{i}"),
            Some("verity"),
            Some("other"),
            None,
        )
        .await;
    }

    let filter = MissionFilter {
        track: Some("core-c3".into()),
        ..Default::default()
    };
    let first = store
        .list_missions_filtered(&filter, 2, 0)
        .await
        .expect("page 1");
    let second = store
        .list_missions_filtered(&filter, 2, 2)
        .await
        .expect("page 2");
    assert_eq!(first.len(), 2);
    assert_eq!(second.len(), 1, "offset skips MATCHES, not raw rows");
    assert!(first
        .iter()
        .chain(second.iter())
        .all(|m| m.project.track.as_deref() == Some("core-c3")));
}

/// The family predicate must stay indexable. `LIKE ?n || '-%'` looked
/// right but is a concatenation expression, which SQLite never optimises
/// into an index seek — every family lookup became a full table scan under
/// the connection mutex. Assert the plan, not just the rows: a regression
/// here is invisible in behaviour and only shows up as latency.
#[tokio::test]
async fn project_family_lookup_uses_an_index() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    seed(&store, "m", Some("verity-core"), None, None).await;

    let plan: Vec<String> = {
        let conn = store.conn.lock().await;
        let mut stmt = conn
            .prepare(
                "EXPLAIN QUERY PLAN SELECT id FROM missions \
                     WHERE (project = ?1 OR (project >= ?2 AND project < ?3)) \
                     ORDER BY updated_at DESC LIMIT 200 OFFSET 0",
            )
            .expect("prepare plan");
        stmt.query_map(rusqlite::params!["verity", "verity-", "verity."], |row| {
            row.get::<_, String>(3)
        })
        .expect("plan rows")
        .collect::<Result<Vec<_>, _>>()
        .expect("plan detail")
    };

    let detail = plan.join(" | ");
    assert!(
        detail.contains("idx_missions_project_track") || detail.contains("SEARCH"),
        "family lookup should seek an index, got: {detail}"
    );
    assert!(
        !detail.contains("SCAN missions"),
        "family lookup must not scan the table, got: {detail}"
    );
}

/// A `track` filter with no project must seek too. The composite index
/// starts with `project`, and SQLite can only seek an index by a prefix of
/// its columns — so track-alone fell back to `SCAN missions`, once per
/// page, with the connection mutex held. Both client APIs and the control
/// endpoint permit that combination, so it is a reachable path and not a
/// theoretical one.
#[tokio::test]
async fn track_only_lookup_uses_an_index() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    seed(&store, "m", Some("verity"), Some("core-c3"), None).await;

    let plan: Vec<String> = {
        let conn = store.conn.lock().await;
        let mut stmt = conn
            .prepare(
                "EXPLAIN QUERY PLAN SELECT id FROM missions \
                     WHERE track = ?1 ORDER BY updated_at DESC LIMIT 200 OFFSET 0",
            )
            .expect("prepare plan");
        stmt.query_map(rusqlite::params!["core-c3"], |row| row.get::<_, String>(3))
            .expect("plan rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("plan detail")
    };

    let detail = plan.join(" | ");
    assert!(
        !detail.contains("SCAN missions"),
        "track-only lookup must not scan the table, got: {detail}"
    );
    assert!(
        detail.contains("idx_missions_track_updated"),
        "track-only lookup should seek the track index, got: {detail}"
    );
}

/// LIKE wildcards inside a free-form tag must not widen the prefilter:
/// `?tag=%` would otherwise select nearly every row and make the loop page
/// through them while holding the connection lock.
#[tokio::test]
async fn tag_filter_treats_like_wildcards_as_literals() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;

    let literal = seed(&store, "literal", Some("verity"), None, None).await;
    store
        .update_mission_project(
            literal,
            MissionProjectPatch {
                tags: Some(vec!["100%".into()]),
                ..Default::default()
            },
        )
        .await
        .expect("tag");
    let other = seed(&store, "other", Some("verity"), None, None).await;
    store
        .update_mission_project(
            other,
            MissionProjectPatch {
                tags: Some(vec!["unrelated".into()]),
                ..Default::default()
            },
        )
        .await
        .expect("tag");

    // A bare wildcard matches nothing: it is a literal, not "everything".
    let wild = store
        .list_missions_filtered(
            &MissionFilter {
                tag: Some("%".into()),
                ..Default::default()
            },
            50,
            0,
        )
        .await
        .expect("filtered list");
    assert!(wild.is_empty(), "'%' must not behave as a wildcard");

    // And a tag that genuinely contains '%' is still found.
    let exact = store
        .list_missions_filtered(
            &MissionFilter {
                tag: Some("100%".into()),
                ..Default::default()
            },
            50,
            0,
        )
        .await
        .expect("filtered list");
    assert_eq!(exact.len(), 1);
    assert_eq!(exact[0].id, literal);
}

/// A tag holding a JSON-escaped character is stored escaped in the column,
/// so the prefilter has to match its SERIALIZATION, not its raw text —
/// otherwise SQL drops it before the Rust re-check can rescue it.
#[tokio::test]
async fn tag_filter_matches_json_escaped_tags() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    for tag in [r#"quote"inside"#, r"back\slash", "new\nline"] {
        let id = seed(&store, tag, Some("verity"), None, None).await;
        store
            .update_mission_project(
                id,
                MissionProjectPatch {
                    tags: Some(vec![tag.to_string()]),
                    ..Default::default()
                },
            )
            .await
            .expect("tag");

        let found = store
            .list_missions_filtered(
                &MissionFilter {
                    tag: Some(tag.to_string()),
                    ..Default::default()
                },
                50,
                0,
            )
            .await
            .expect("filtered list");
        assert_eq!(found.len(), 1, "tag {tag:?} must be findable");
        assert_eq!(found[0].id, id);
    }
}

/// `tags` is JSON TEXT and some rows hold malformed blobs, which is why
/// the tag filter is a SQL prefilter plus a Rust re-check rather than
/// `json_each` (that would fail the whole query on the bad row).
#[tokio::test]
async fn tag_filter_survives_a_malformed_tags_blob() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    let tagged = seed(&store, "tagged", Some("verity"), None, None).await;
    store
        .update_mission_project(
            tagged,
            MissionProjectPatch {
                tags: Some(vec!["origin:hermes-assistant".into()]),
                ..Default::default()
            },
        )
        .await
        .expect("tag");
    let broken = seed(&store, "broken", Some("verity"), None, None).await;
    {
        let conn = store.conn.lock().await;
        conn.execute(
            "UPDATE missions SET tags = '{not json' WHERE id = ?1",
            rusqlite::params![broken.to_string()],
        )
        .expect("corrupt tags");
    }

    let found = store
        .list_missions_filtered(
            &MissionFilter {
                tag: Some("origin:hermes-assistant".into()),
                ..Default::default()
            },
            50,
            0,
        )
        .await
        .expect("filtered list");
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].id, tagged);
}

#[tokio::test]
async fn stale_active_scan_keeps_hermes_ownership_tags() {
    // Prod 2026-08-15: the short stale SELECT dropped origin/tags, so
    // cleanup treated Hermes writers as untagged and Completed them.
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    let mission = store
        .create_mission(Some("Grok repair"), None, None, None, None, None, None)
        .await
        .expect("create");
    store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
        .expect("active");
    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                tags: Some(vec!["origin:hermes-assistant".into()]),
                ..Default::default()
            },
        )
        .await
        .expect("tags");
    store
        .force_backdate_for_test(mission.id, "2026-08-15T00:00:00+00:00")
        .await
        .expect("backdate");

    let stale = store
        .get_stale_active_missions(2)
        .await
        .expect("stale scan");
    let found = stale
        .iter()
        .find(|row| row.id == mission.id)
        .expect("mission should be in the stale set");
    assert!(
        found
            .project
            .tags
            .iter()
            .any(|tag| tag == "origin:hermes-assistant"),
        "stale scan must keep Hermes tags, got {:?}",
        found.project.tags
    );
}
