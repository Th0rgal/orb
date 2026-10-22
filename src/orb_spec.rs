//! Typed bindings to `lean/Orb/Kernel.lean` (`liborb_spec_cabi.a`).

unsafe extern "C" {
    fn orb_verify_writer_reuse(c: u8, t: u8, m: u8, e: u8, w: u8, u: u8) -> u8;
    fn orb_verify_lease_mode(wf: u8, ro_tag: u8, wr_tag: u8, ro_intent: u8) -> u8;
    fn orb_verify_track_hold(unres: u8, queued: u8, live: u8, goal: u8) -> u8;
    fn orb_verify_repo_disjoint(h_known: u8, t_known: u8, same: u8) -> u8;
    fn orb_verify_remote_outbox(
        op: u8,
        ex: u8,
        s: u8,
        c: u8,
        sp: u8,
        r: u8,
        p: u8,
        j: u8,
        a: u8,
    ) -> u8;
    fn orb_verify_board_slots(max_p: u32, boss: u32, running: u32) -> u8;
    fn orb_verify_board_retry(att: u32, max_a: u32, ext: u8, mrg: u8, ui: u8) -> u8;
    fn orb_verify_job_transition(from_state: u8, to_state: u8) -> u8;
    fn orb_verify_bundle_budget(
        comp: u8,
        bytes: u64,
        ov_cap: u64,
        comp_cap: u64,
        max_bytes: u64,
    ) -> u8;
    fn orb_verify_token_rotation(pres: u8, cur: u8, prev_ne: u8, prev: u8, scope: u8) -> u8;
    fn leansys_verify_log_window(
        off: u64,
        req: u64,
        max_c: u64,
        hard_cap: u64,
        fsz: u64,
        act: u64,
    ) -> u8;
    fn leansys_mix64_word(acc: u64, word: u64) -> u64;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WriterReuse {
    pub has_continue: bool,
    pub cont_track_nonempty: bool,
    pub cont_matches_stored: bool,
    pub has_any_edit: bool,
    pub work_changed: bool,
    pub identity_updated: bool,
}

pub fn writer_reuse_allowed(input: WriterReuse) -> bool {
    unsafe {
        orb_verify_writer_reuse(
            u8::from(input.has_continue),
            u8::from(input.cont_track_nonempty),
            u8::from(input.cont_matches_stored),
            u8::from(input.has_any_edit),
            u8::from(input.work_changed),
            u8::from(input.identity_updated),
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LeaseModeInput {
    pub writer_flag: Option<bool>,
    pub has_readonly_tag: bool,
    pub has_writer_tag: bool,
    pub is_readonly_intent: bool,
}

pub fn classify_lease_mode(input: LeaseModeInput) -> &'static str {
    let flag = input.writer_flag.map_or(2, u8::from);
    if unsafe {
        orb_verify_lease_mode(
            flag,
            u8::from(input.has_readonly_tag),
            u8::from(input.has_writer_tag),
            u8::from(input.is_readonly_intent),
        )
    } == 0
    {
        "reader"
    } else {
        "writer"
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrackHold {
    pub in_unresolved: bool,
    pub in_queued: bool,
    pub has_live_owner: bool,
    pub native_goal_holds: bool,
}

pub fn track_hold_active(input: TrackHold) -> bool {
    unsafe {
        orb_verify_track_hold(
            u8::from(input.in_unresolved),
            u8::from(input.in_queued),
            u8::from(input.has_live_owner),
            u8::from(input.native_goal_holds),
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RepoDisjoint {
    pub handle_repo_known: bool,
    pub target_repo_known: bool,
    pub same_repo: bool,
}

pub fn repo_disjoint(input: RepoDisjoint) -> bool {
    unsafe {
        orb_verify_repo_disjoint(
            u8::from(input.handle_repo_known),
            u8::from(input.target_repo_known),
            u8::from(input.same_repo),
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemoteOutboxEnqueue {
    pub already_exists: bool,
    pub same_mission: bool,
    pub is_cancelled: bool,
    pub is_superseded: bool,
    pub session_ready: bool,
    pub pr_unsupported: bool,
}

pub fn remote_outbox_admit_enqueue(input: RemoteOutboxEnqueue) -> bool {
    unsafe {
        orb_verify_remote_outbox(
            0,
            u8::from(input.already_exists),
            u8::from(input.same_mission),
            u8::from(input.is_cancelled),
            u8::from(input.is_superseded),
            u8::from(input.session_ready),
            u8::from(input.pr_unsupported),
            0,
            0,
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemoteOutboxCancel {
    pub has_job_id: bool,
    pub delivery_abandonable: bool,
}

pub fn remote_outbox_admit_cancel(input: RemoteOutboxCancel) -> bool {
    unsafe {
        orb_verify_remote_outbox(
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            u8::from(input.has_job_id),
            u8::from(input.delivery_abandonable),
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoardSlots {
    pub max_parallel: u32,
    pub reserved_boss_slots: u32,
    pub total_running: u32,
}

pub fn board_slots_available(input: BoardSlots) -> bool {
    unsafe {
        orb_verify_board_slots(
            input.max_parallel,
            input.reserved_boss_slots,
            input.total_running,
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoardRetry {
    pub attempts: u32,
    pub max_attempts: u32,
    pub requires_external_recovery: bool,
    pub preflight_merged: bool,
    pub chatgpt_ui_blocked: bool,
}

pub fn board_retry_allowed(input: BoardRetry) -> bool {
    unsafe {
        orb_verify_board_retry(
            input.attempts,
            input.max_attempts,
            u8::from(input.requires_external_recovery),
            u8::from(input.preflight_merged),
            u8::from(input.chatgpt_ui_blocked),
        ) != 0
    }
}

pub fn job_transition_allowed(from_state: u8, to_state: u8) -> bool {
    unsafe { orb_verify_job_transition(from_state, to_state) != 0 }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BundleBudget {
    pub is_complete: bool,
    pub decoded_bytes: u64,
    pub overlay_cap: u64,
    pub complete_cap: u64,
    pub max_bytes: u64,
}

pub fn bundle_budget_ok(input: BundleBudget) -> bool {
    unsafe {
        orb_verify_bundle_budget(
            u8::from(input.is_complete),
            input.decoded_bytes,
            input.overlay_cap,
            input.complete_cap,
            input.max_bytes,
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TokenRotation {
    pub presented_nonempty: bool,
    pub match_current: bool,
    pub prev_nonempty: bool,
    pub match_prev: bool,
    pub scope_and_expiry_ok: bool,
}

pub fn token_rotation_allowed(input: TokenRotation) -> bool {
    unsafe {
        orb_verify_token_rotation(
            u8::from(input.presented_nonempty),
            u8::from(input.match_current),
            u8::from(input.prev_nonempty),
            u8::from(input.match_prev),
            u8::from(input.scope_and_expiry_ok),
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LogWindow {
    pub offset: u64,
    pub req_len: u64,
    pub max_chunk: u64,
    pub hard_cap: u64,
    pub file_size: u64,
    pub actual_len: u64,
}

pub fn log_window_valid(input: LogWindow) -> bool {
    unsafe {
        leansys_verify_log_window(
            input.offset,
            input.req_len,
            input.max_chunk,
            input.hard_cap,
            input.file_size,
            input.actual_len,
        ) != 0
    }
}

#[allow(dead_code)]
pub fn mix64_word(acc: u64, word: u64) -> u64 {
    unsafe { leansys_mix64_word(acc, word) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writer_reuse_gate_enforces_continuation_and_retag_rules() {
        assert!(writer_reuse_allowed(WriterReuse {
            has_continue: true,
            cont_track_nonempty: true,
            cont_matches_stored: true,
            has_any_edit: false,
            work_changed: true,
            identity_updated: false,
        }));
        assert!(!writer_reuse_allowed(WriterReuse {
            has_continue: true,
            cont_track_nonempty: false,
            cont_matches_stored: true,
            has_any_edit: false,
            work_changed: false,
            identity_updated: false,
        }));
        assert!(!writer_reuse_allowed(WriterReuse {
            has_continue: true,
            cont_track_nonempty: true,
            cont_matches_stored: true,
            has_any_edit: true,
            work_changed: false,
            identity_updated: true,
        }));
        assert!(!writer_reuse_allowed(WriterReuse {
            has_continue: false,
            cont_track_nonempty: false,
            cont_matches_stored: false,
            has_any_edit: false,
            work_changed: true,
            identity_updated: false,
        }));
        assert!(writer_reuse_allowed(WriterReuse {
            has_continue: false,
            cont_track_nonempty: false,
            cont_matches_stored: false,
            has_any_edit: true,
            work_changed: true,
            identity_updated: true,
        }));
    }

    #[test]
    fn lease_mode_classifier_respects_precedence() {
        assert_eq!(
            classify_lease_mode(LeaseModeInput {
                writer_flag: Some(false),
                has_readonly_tag: false,
                has_writer_tag: true,
                is_readonly_intent: false,
            }),
            "reader"
        );
        assert_eq!(
            classify_lease_mode(LeaseModeInput {
                writer_flag: None,
                has_readonly_tag: true,
                has_writer_tag: true,
                is_readonly_intent: false,
            }),
            "reader"
        );
        assert_eq!(
            classify_lease_mode(LeaseModeInput {
                writer_flag: Some(true),
                has_readonly_tag: false,
                has_writer_tag: false,
                is_readonly_intent: true,
            }),
            "writer"
        );
        assert_eq!(
            classify_lease_mode(LeaseModeInput {
                writer_flag: None,
                has_readonly_tag: false,
                has_writer_tag: false,
                is_readonly_intent: true,
            }),
            "reader"
        );
        assert_eq!(
            classify_lease_mode(LeaseModeInput {
                writer_flag: None,
                has_readonly_tag: false,
                has_writer_tag: false,
                is_readonly_intent: false,
            }),
            "writer"
        );
    }

    #[test]
    fn board_retry_and_slots_respect_parameterized_caps() {
        assert!(board_retry_allowed(BoardRetry {
            attempts: 3,
            max_attempts: 5,
            requires_external_recovery: false,
            preflight_merged: false,
            chatgpt_ui_blocked: false,
        }));
        assert!(!board_retry_allowed(BoardRetry {
            attempts: 5,
            max_attempts: 5,
            requires_external_recovery: false,
            preflight_merged: false,
            chatgpt_ui_blocked: false,
        }));
        assert!(!board_retry_allowed(BoardRetry {
            attempts: 0,
            max_attempts: 0,
            requires_external_recovery: false,
            preflight_merged: false,
            chatgpt_ui_blocked: false,
        }));
        assert!(board_slots_available(BoardSlots {
            max_parallel: 8,
            reserved_boss_slots: 1,
            total_running: 6,
        }));
        assert!(!board_slots_available(BoardSlots {
            max_parallel: 8,
            reserved_boss_slots: 1,
            total_running: 7,
        }));
        assert!(!board_slots_available(BoardSlots {
            max_parallel: 8,
            reserved_boss_slots: 0,
            total_running: 0,
        }));
    }

    #[test]
    fn bundle_budget_and_log_window_respect_custom_limits() {
        assert!(bundle_budget_ok(BundleBudget {
            is_complete: true,
            decoded_bytes: 64 << 20,
            overlay_cap: 1 << 20,
            complete_cap: 128 << 20,
            max_bytes: 128 << 20,
        }));
        assert!(!bundle_budget_ok(BundleBudget {
            is_complete: true,
            decoded_bytes: 64 << 20,
            overlay_cap: 1 << 20,
            complete_cap: 128 << 20,
            max_bytes: 50 << 20,
        }));
        assert!(log_window_valid(LogWindow {
            offset: 100,
            req_len: 512,
            max_chunk: 1024,
            hard_cap: 2048,
            file_size: 1000,
            actual_len: 512,
        }));
        assert!(!log_window_valid(LogWindow {
            offset: 800,
            req_len: 512,
            max_chunk: 1024,
            hard_cap: 2048,
            file_size: 1000,
            actual_len: 300,
        }));
        assert_ne!(mix64_word(0x9E37_79B9_7F4A_7C15, 0), 0);
    }
}
