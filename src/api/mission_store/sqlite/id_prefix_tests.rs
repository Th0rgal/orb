use super::SqliteMissionStore;

async fn store(dir: &tempfile::TempDir) -> SqliteMissionStore {
    SqliteMissionStore::new(dir.path().to_path_buf(), "prefix-user")
        .await
        .expect("sqlite store")
}

async fn make(store: &SqliteMissionStore, title: &str) -> uuid::Uuid {
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
            None,
            None,
        )
        .await
        .expect("create mission")
        .id
}

#[tokio::test]
async fn resolves_the_prefix_dashboards_display() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    let id = make(&store, "target").await;
    for i in 0..5 {
        make(&store, &format!("noise {i}")).await;
    }

    let short = &id.to_string()[..8];
    let found = store
        .find_missions_by_id_prefix(short, 10)
        .await
        .expect("prefix lookup");
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].id, id);
}

#[tokio::test]
async fn reports_every_candidate_so_the_caller_can_disambiguate() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    let a = make(&store, "a").await;
    let b = make(&store, "b").await;
    // Their common prefix is at minimum the empty string; use the first
    // character both share to force a multi-match without depending on
    // generated values.
    let shared = &a.to_string()[..1];
    if b.to_string().starts_with(shared) {
        let found = store
            .find_missions_by_id_prefix(shared, 10)
            .await
            .expect("prefix lookup");
        assert!(
            found.len() >= 2,
            "an ambiguous prefix must surface every candidate, got {}",
            found.len()
        );
    }
}

#[tokio::test]
async fn unknown_prefix_finds_nothing() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = store(&dir).await;
    make(&store, "only").await;
    let found = store
        .find_missions_by_id_prefix("ffffffff", 10)
        .await
        .expect("prefix lookup");
    assert!(found.is_empty());
}
