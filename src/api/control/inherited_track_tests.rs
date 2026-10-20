use super::*;
#[test]
fn replacements_drop_generated_tracks_along_the_chain_only() {
    let prior = Uuid::parse_str("2b26c1a2-0000-4000-8000-000000000000").unwrap();
    assert!(replacement_drops_track(
        prior,
        Some("mission-2b26c1a2"),
        "mission-2b26c1a2"
    ));
    // An older ancestor's generated track carried by the prior mission.
    assert!(replacement_drops_track(
        prior,
        Some("mission-0aa11b22"),
        "mission-0aa11b22"
    ));
    // Real project tracks are writer identities and stay.
    assert!(!replacement_drops_track(
        prior,
        Some("import-dynamic-event-abi"),
        "import-dynamic-event-abi"
    ));
    // A generated-looking track the prior mission does not carry stays.
    assert!(!replacement_drops_track(
        prior,
        Some("other"),
        "mission-0aa11b22"
    ));
}
#[test]
fn clones_drop_only_the_sources_generated_track() {
    let id = Uuid::parse_str("9888cd20-6191-45a5-b1cb-cea8b24a9eec").unwrap();
    assert_eq!(inherited_track(id, Some("mission-9888cd20")), None);
    assert_eq!(
        inherited_track(id, Some("verity-family-a")).as_deref(),
        Some("verity-family-a")
    );
    assert_eq!(
        inherited_track(id, Some("mission-deadbeef")).as_deref(),
        Some("mission-deadbeef")
    );
    assert_eq!(inherited_track(id, None), None);
}
