use super::*;

#[test]
fn active_missions_go_working_quiet_stalled() {
    assert_eq!(
        mission_health_verdict(MissionStatus::Active, 10),
        Some("working")
    );
    assert_eq!(
        mission_health_verdict(MissionStatus::Active, 600),
        Some("quiet")
    );
    assert_eq!(
        mission_health_verdict(MissionStatus::Active, 7200),
        Some("stalled")
    );
}

#[test]
fn parked_missions_stall_after_threshold() {
    assert_eq!(
        mission_health_verdict(MissionStatus::AwaitingUser, 60),
        Some("parked")
    );
    // The A.3 incident shape: a worker sitting acknowledged for 16h must
    // not read as healthy.
    assert_eq!(
        mission_health_verdict(MissionStatus::Acknowledged, 16 * 3600),
        Some("stalled_parked")
    );
}

#[test]
fn terminal_missions_have_no_verdict() {
    assert_eq!(
        mission_health_verdict(MissionStatus::Completed, 999_999),
        None
    );
    assert_eq!(mission_health_verdict(MissionStatus::Failed, 0), None);
}

#[test]
fn pending_missions_flag_a_stuck_queue() {
    assert_eq!(
        mission_health_verdict(MissionStatus::Pending, 60),
        Some("queued")
    );
    assert_eq!(
        mission_health_verdict(MissionStatus::Pending, 3600),
        Some("stuck_queued")
    );
}

#[test]
fn idle_durations_render_compactly() {
    assert_eq!(humanize_idle(45), "45s");
    assert_eq!(humanize_idle(12 * 60), "12m");
    assert_eq!(humanize_idle(2 * 3600 + 30 * 60), "2h30m");
    assert_eq!(humanize_idle(16 * 3600), "16h");
    assert_eq!(humanize_idle(3 * 86_400), "3d");
}
