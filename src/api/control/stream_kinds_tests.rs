use super::{parse_stream_kinds, stream_kind_matches};

#[test]
fn absent_or_empty_kinds_means_everything() {
    assert_eq!(parse_stream_kinds(None), None);
    assert_eq!(parse_stream_kinds(Some(" , ")), None);
}

#[test]
fn fido_kind_selects_only_fido_events() {
    let kinds = parse_stream_kinds(Some("FIDO")).unwrap();
    assert!(stream_kind_matches(&kinds, "fido_sign_request"));
    assert!(!stream_kind_matches(&kinds, "assistant_message"));
    assert!(!stream_kind_matches(&kinds, "status"));
    assert!(!stream_kind_matches(&kinds, "fidoish"));
}

#[test]
fn multiple_kinds_and_exact_names() {
    let kinds = parse_stream_kinds(Some("fido, status")).unwrap();
    assert!(stream_kind_matches(&kinds, "status"));
    assert!(stream_kind_matches(&kinds, "fido_sign_request"));
    assert!(!stream_kind_matches(&kinds, "thinking"));
}
