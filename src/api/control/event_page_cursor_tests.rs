use super::event_page_cursor;
#[test]
fn forward_progress_uses_raw_page_end() {
    assert_eq!(
        event_page_cursor(Some(1001), Some(2000), 1000, Some(1000), false),
        (Some(2000), true)
    );
}
#[test]
fn backward_progress_uses_raw_page_start() {
    assert_eq!(
        event_page_cursor(Some(1001), Some(2000), 1000, Some(1000), true),
        (Some(1001), true)
    );
}
#[test]
fn empty_page_terminates_without_advancing() {
    assert_eq!(
        event_page_cursor(None, None, 0, Some(1000), false),
        (None, false)
    );
}
