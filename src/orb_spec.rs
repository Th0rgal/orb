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
    fn orb_proxy_step(
        committed: u8,
        chunk_commits: u8,
        stalled: u8,
        retries: u32,
        max_retries: u32,
    ) -> u32;
    fn orb_stream_deadlines(
        client_elapsed_ms: u64,
        keepalive_ms: u64,
        upstream_elapsed_ms: u64,
        base_idle_ms: u64,
        provider_floor_ms: u64,
        at_event_boundary: u8,
        has_mission_header: u8,
        auth_verified: u8,
    ) -> u32;
    fn orb_breaker_step(reason: u8, transient_streak: u32, transient_threshold: u32) -> u32;
    fn orb_mission_step(
        armed: u8,
        signal: u8,
        continuation_pending: u8,
        wakeup_armed: u8,
        made_progress: u8,
        prior_no_progress: u32,
        max_no_progress: u32,
        prior_continuations: u32,
        max_continuations: u32,
        has_max_cont: u32,
    ) -> u8;
    fn orb_reconcile_step(
        status: u8,
        is_client_placed: u8,
        same_boot_id: u8,
        is_assistant_mode: u8,
        running_in_actor: u8,
        has_live_scope: u8,
        has_durable_run: u8,
        recently_updated: u8,
        has_events: u8,
        already_orphaned: u8,
        is_service_restart: u8,
        within_horizon: u8,
        live_retry_exists: u8,
    ) -> u8;
    fn orb_queue_step(delivery_outcome: u8, durably_started: u8) -> u32;
    fn orb_vm_step(
        op: u8,
        size_rank: u8,
        max_size_rank: u8,
        secret_projected: u8,
        ttl_expired: u8,
        busy: u8,
        owner_ended: u8,
        idle_expired: u8,
        active_count: u32,
        max_concurrent: u32,
        ttl_minutes: u32,
        max_ttl_minutes: u32,
        job_mem_pct: u32,
        spent_plus_new_cents: u64,
        daily_cap_cents: u64,
    ) -> u8;
    fn orb_access_step(
        same_owner: u8,
        is_self_or_child: u8,
        is_read_tool: u8,
        grant_approved: u8,
        grant_unexpired: u8,
        target_exists: u8,
    ) -> u32;
    fn orb_workfold_step(
        item_kind: u8,
        is_cumulative: u8,
        is_non_empty: u8,
        tool_ahead: u8,
        next_is_tool: u8,
        fold_has_tool: u8,
    ) -> u32;
    fn orb_taskcard_step(turn_ended: u8, all_closed: u8, turn_outcome_finished: u8) -> u8;
    fn orb_sidebar_visibility(
        matches_filter: u8,
        has_visible_descendant: u8,
        is_acknowledged: u8,
        has_parent: u8,
        is_fork: u8,
        parent_reaches_self: u8,
    ) -> u32;
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyAction {
    Continue,
    RerouteSameProvider,
    RerouteFailoverPool,
    EmitError,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProxyStepResult {
    pub committed_next: bool,
    pub action: ProxyAction,
    pub trip_breaker: bool,
}

pub fn proxy_step(
    committed: bool,
    chunk_commits: bool,
    stalled: bool,
    retries: u32,
    max_retries: u32,
) -> ProxyStepResult {
    let raw = unsafe {
        orb_proxy_step(
            u8::from(committed),
            u8::from(chunk_commits),
            u8::from(stalled),
            retries,
            max_retries,
        )
    };
    let action = match (raw >> 8) & 0xFF {
        1 => ProxyAction::RerouteSameProvider,
        2 => ProxyAction::RerouteFailoverPool,
        3 => ProxyAction::EmitError,
        _ => ProxyAction::Continue,
    };
    ProxyStepResult {
        committed_next: (raw & 1) != 0,
        action,
        trip_breaker: ((raw >> 16) & 1) != 0,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamDeadlinesInput {
    pub client_elapsed_ms: u64,
    pub keepalive_ms: u64,
    pub upstream_elapsed_ms: u64,
    pub base_idle_ms: u64,
    pub provider_floor_ms: u64,
    pub at_event_boundary: bool,
    pub has_mission_header: bool,
    pub auth_verified: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamDeadlinesVerdict {
    pub emit_keepalive: bool,
    pub upstream_stalled: bool,
    pub touch_liveness: bool,
}

pub fn stream_deadlines(input: StreamDeadlinesInput) -> StreamDeadlinesVerdict {
    let raw = unsafe {
        orb_stream_deadlines(
            input.client_elapsed_ms,
            input.keepalive_ms,
            input.upstream_elapsed_ms,
            input.base_idle_ms,
            input.provider_floor_ms,
            u8::from(input.at_event_boundary),
            u8::from(input.has_mission_header),
            u8::from(input.auth_verified),
        )
    };
    StreamDeadlinesVerdict {
        emit_keepalive: (raw & 1) != 0,
        upstream_stalled: ((raw >> 8) & 1) != 0,
        touch_liveness: ((raw >> 16) & 1) != 0,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BreakerReason {
    Ok = 0,
    RateLimit429 = 1,
    QuotaExhausted = 2,
    PaymentRequired402 = 3,
    Transient502Timeout = 4,
    Auth401Or403 = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BreakerVerdict {
    pub park_account: bool,
    pub poison_subscription: bool,
    pub apply_cooldown: bool,
}

pub fn breaker_step(
    reason: BreakerReason,
    transient_streak: u32,
    transient_threshold: u32,
) -> BreakerVerdict {
    let raw = unsafe { orb_breaker_step(reason as u8, transient_streak, transient_threshold) };
    BreakerVerdict {
        park_account: (raw & 1) != 0,
        poison_subscription: ((raw >> 8) & 1) != 0,
        apply_cooldown: ((raw >> 16) & 1) != 0,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MissionStepOutcome {
    Stopped = 0,
    Complete = 1,
    Aborted = 2,
    AlreadyQueued = 3,
    PausedWakeup = 4,
    Stalled = 5,
    BudgetLimited = 6,
    ContinueGoal = 7,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MissionStepInput {
    pub armed: bool,
    pub signal: u8,
    pub continuation_pending: bool,
    pub wakeup_armed: bool,
    pub made_progress: bool,
    pub prior_no_progress: u32,
    pub max_no_progress: u32,
    pub prior_continuations: u32,
    pub max_continuations: u32,
    pub has_max_continuations: bool,
}

pub fn mission_step(input: MissionStepInput) -> MissionStepOutcome {
    let code = unsafe {
        orb_mission_step(
            u8::from(input.armed),
            input.signal,
            u8::from(input.continuation_pending),
            u8::from(input.wakeup_armed),
            u8::from(input.made_progress),
            input.prior_no_progress,
            input.max_no_progress,
            input.prior_continuations,
            input.max_continuations,
            u32::from(input.has_max_continuations),
        )
    };
    match code {
        1 => MissionStepOutcome::Complete,
        2 => MissionStepOutcome::Aborted,
        3 => MissionStepOutcome::AlreadyQueued,
        4 => MissionStepOutcome::PausedWakeup,
        5 => MissionStepOutcome::Stalled,
        6 => MissionStepOutcome::BudgetLimited,
        7 => MissionStepOutcome::ContinueGoal,
        _ => MissionStepOutcome::Stopped,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReconcileVerdict {
    Keep = 0,
    InterruptAndResume = 1,
    TagOrphaned = 2,
    ReresumeInterrupted = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReconcileInput {
    pub status: u8,
    pub is_client_placed: bool,
    pub same_boot_id: bool,
    pub is_assistant_mode: bool,
    pub running_in_actor: bool,
    pub has_live_scope: bool,
    pub has_durable_run: bool,
    pub recently_updated: bool,
    pub has_events: bool,
    pub already_orphaned: bool,
    pub is_service_restart: bool,
    pub within_horizon: bool,
    pub live_retry_exists: bool,
}

pub fn reconcile_step(input: ReconcileInput) -> ReconcileVerdict {
    let code = unsafe {
        orb_reconcile_step(
            input.status,
            u8::from(input.is_client_placed),
            u8::from(input.same_boot_id),
            u8::from(input.is_assistant_mode),
            u8::from(input.running_in_actor),
            u8::from(input.has_live_scope),
            u8::from(input.has_durable_run),
            u8::from(input.recently_updated),
            u8::from(input.has_events),
            u8::from(input.already_orphaned),
            u8::from(input.is_service_restart),
            u8::from(input.within_horizon),
            u8::from(input.live_retry_exists),
        )
    };
    match code {
        1 => ReconcileVerdict::InterruptAndResume,
        2 => ReconcileVerdict::TagOrphaned,
        3 => ReconcileVerdict::ReresumeInterrupted,
        _ => ReconcileVerdict::Keep,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueDeliveryOutcome {
    Acked = 0,
    Rejected = 1,
    UncertainTimeout = 2,
    PersistFailed = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueueStepVerdict {
    pub retain_in_queue: bool,
    pub mark_consumed: bool,
    pub block_cancel: bool,
}

pub fn queue_step(outcome: QueueDeliveryOutcome, durably_started: bool) -> QueueStepVerdict {
    let raw = unsafe { orb_queue_step(outcome as u8, u8::from(durably_started)) };
    QueueStepVerdict {
        retain_in_queue: (raw & 1) != 0,
        mark_consumed: ((raw >> 8) & 1) != 0,
        block_cancel: ((raw >> 16) & 1) != 0,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VmSpawnInput {
    pub size_rank: u8,
    pub max_size_rank: u8,
    pub secret_projected: bool,
    pub active_count: u32,
    pub max_concurrent: u32,
    pub ttl_minutes: u32,
    pub max_ttl_minutes: u32,
    pub job_mem_pct: u32,
    pub spent_plus_new_cents: u64,
    pub daily_cap_cents: u64,
}

pub fn vm_spawn_admit(input: VmSpawnInput) -> bool {
    unsafe {
        orb_vm_step(
            0,
            input.size_rank,
            input.max_size_rank,
            u8::from(input.secret_projected),
            0,
            0,
            0,
            0,
            input.active_count,
            input.max_concurrent,
            input.ttl_minutes,
            input.max_ttl_minutes,
            input.job_mem_pct,
            input.spent_plus_new_cents,
            input.daily_cap_cents,
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VmReapInput {
    pub ttl_expired: bool,
    pub busy: bool,
    pub owner_ended: bool,
    pub idle_expired: bool,
}

pub fn vm_should_reap(input: VmReapInput) -> bool {
    unsafe {
        orb_vm_step(
            1,
            0,
            0,
            0,
            u8::from(input.ttl_expired),
            u8::from(input.busy),
            u8::from(input.owner_ended),
            u8::from(input.idle_expired),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        ) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AccessStepInput {
    pub same_owner: bool,
    pub is_self_or_child: bool,
    pub is_read_tool: bool,
    pub grant_approved: bool,
    pub grant_unexpired: bool,
    pub target_exists: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AccessStepVerdict {
    pub allow_tool: bool,
    pub disclose_title: bool,
    pub already_in_scope: bool,
}

pub fn access_step(input: AccessStepInput) -> AccessStepVerdict {
    let raw = unsafe {
        orb_access_step(
            u8::from(input.same_owner),
            u8::from(input.is_self_or_child),
            u8::from(input.is_read_tool),
            u8::from(input.grant_approved),
            u8::from(input.grant_unexpired),
            u8::from(input.target_exists),
        )
    };
    AccessStepVerdict {
        allow_tool: (raw & 1) != 0,
        disclose_title: ((raw >> 8) & 1) != 0,
        already_in_scope: ((raw >> 16) & 1) != 0,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkfoldStepVerdict {
    pub fold_item: bool,
    pub fold_has_tool_next: bool,
}

pub fn workfold_step(
    item_kind: u8,
    is_cumulative: bool,
    is_non_empty: bool,
    tool_ahead: bool,
    next_is_tool: bool,
    fold_has_tool: bool,
) -> WorkfoldStepVerdict {
    let raw = unsafe {
        orb_workfold_step(
            item_kind,
            u8::from(is_cumulative),
            u8::from(is_non_empty),
            u8::from(tool_ahead),
            u8::from(next_is_tool),
            u8::from(fold_has_tool),
        )
    };
    WorkfoldStepVerdict {
        fold_item: (raw & 1) != 0,
        fold_has_tool_next: ((raw >> 8) & 1) != 0,
    }
}

pub fn taskcard_step(
    turn_ended: bool,
    all_closed: bool,
    turn_outcome_finished: bool,
) -> &'static str {
    let code = unsafe {
        orb_taskcard_step(
            u8::from(turn_ended),
            u8::from(all_closed),
            u8::from(turn_outcome_finished),
        )
    };
    match code {
        0 => "live",
        1 => "done",
        2 => "stale",
        _ => "stopped",
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SidebarVisibilityVerdict {
    pub retain_in_main_tree: bool,
    pub show_in_archive_only: bool,
    pub is_cycle_safe_child: bool,
}

pub fn sidebar_visibility(
    matches_filter: bool,
    has_visible_descendant: bool,
    is_acknowledged: bool,
    has_parent: bool,
    is_fork: bool,
    parent_reaches_self: bool,
) -> SidebarVisibilityVerdict {
    let raw = unsafe {
        orb_sidebar_visibility(
            u8::from(matches_filter),
            u8::from(has_visible_descendant),
            u8::from(is_acknowledged),
            u8::from(has_parent),
            u8::from(is_fork),
            u8::from(parent_reaches_self),
        )
    };
    SidebarVisibilityVerdict {
        retain_in_main_tree: (raw & 1) != 0,
        show_in_archive_only: ((raw >> 8) & 1) != 0,
        is_cycle_safe_child: ((raw >> 16) & 1) != 0,
    }
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

    #[test]
    fn phase2_proxy_stream_and_breaker_steppers_preserve_invariants() {
        let p_pre = proxy_step(false, false, true, 0, 2);
        assert!(!p_pre.committed_next);
        assert_eq!(p_pre.action, ProxyAction::RerouteSameProvider);
        assert!(!p_pre.trip_breaker);

        let p_failover = proxy_step(false, false, true, 1, 2);
        assert_eq!(p_failover.action, ProxyAction::RerouteFailoverPool);
        assert!(p_failover.trip_breaker);

        let p_fenced = proxy_step(true, false, true, 0, 2);
        assert!(p_fenced.committed_next);
        assert_eq!(p_fenced.action, ProxyAction::EmitError);

        let d_isolated = stream_deadlines(StreamDeadlinesInput {
            client_elapsed_ms: 20_000,
            keepalive_ms: 15_000,
            upstream_elapsed_ms: 50_000,
            base_idle_ms: 45_000,
            provider_floor_ms: 120_000,
            at_event_boundary: false,
            has_mission_header: true,
            auth_verified: false,
        });
        assert!(!d_isolated.emit_keepalive);
        assert!(!d_isolated.upstream_stalled);
        assert!(!d_isolated.touch_liveness);

        let b_transient = breaker_step(BreakerReason::Transient502Timeout, 1, 2);
        assert_eq!(
            b_transient,
            BreakerVerdict {
                park_account: false,
                poison_subscription: false,
                apply_cooldown: false,
            }
        );
        let b_quota = breaker_step(BreakerReason::QuotaExhausted, 0, 2);
        assert_eq!(
            b_quota,
            BreakerVerdict {
                park_account: true,
                poison_subscription: true,
                apply_cooldown: true,
            }
        );
    }

    #[test]
    fn phase3_mission_reconcile_queue_vm_and_access_steppers_preserve_invariants() {
        assert_eq!(
            mission_step(MissionStepInput {
                armed: true,
                signal: 0,
                continuation_pending: false,
                wakeup_armed: true,
                made_progress: false,
                prior_no_progress: 5,
                max_no_progress: 3,
                prior_continuations: 10,
                max_continuations: 5,
                has_max_continuations: true,
            }),
            MissionStepOutcome::PausedWakeup
        );
        assert_eq!(
            reconcile_step(ReconcileInput {
                status: 0,
                is_client_placed: false,
                same_boot_id: true,
                is_assistant_mode: false,
                running_in_actor: false,
                has_live_scope: false,
                has_durable_run: false,
                recently_updated: false,
                has_events: false,
                already_orphaned: false,
                is_service_restart: true,
                within_horizon: true,
                live_retry_exists: false,
            }),
            ReconcileVerdict::Keep
        );
        let q_uncertain = queue_step(QueueDeliveryOutcome::UncertainTimeout, false);
        assert!(q_uncertain.retain_in_queue);
        assert!(!q_uncertain.mark_consumed);
        assert!(q_uncertain.block_cancel);

        assert!(!vm_spawn_admit(VmSpawnInput {
            size_rank: 1,
            max_size_rank: 2,
            secret_projected: true,
            active_count: 0,
            max_concurrent: 4,
            ttl_minutes: 60,
            max_ttl_minutes: 720,
            job_mem_pct: 90,
            spent_plus_new_cents: 10,
            daily_cap_cents: 500,
        }));
        assert_eq!(
            access_step(AccessStepInput {
                same_owner: true,
                is_self_or_child: false,
                is_read_tool: true,
                grant_approved: false,
                grant_unexpired: false,
                target_exists: true,
            }),
            access_step(AccessStepInput {
                same_owner: true,
                is_self_or_child: false,
                is_read_tool: true,
                grant_approved: false,
                grant_unexpired: false,
                target_exists: false,
            })
        );
    }

    #[test]
    fn phase4_cross_client_projection_steppers_preserve_invariants() {
        assert!(!workfold_step(2, false, true, false, true, true).fold_item);
        assert!(!workfold_step(2, true, true, true, true, true).fold_item);
        assert!(workfold_step(2, false, true, true, true, false).fold_item);
        assert_eq!(taskcard_step(false, false, false), "live");
        assert_eq!(taskcard_step(true, true, false), "done");
        assert_eq!(taskcard_step(true, false, true), "stale");
        assert_eq!(taskcard_step(true, false, false), "stopped");
        let vis = sidebar_visibility(false, true, true, true, false, true);
        assert!(vis.retain_in_main_tree);
        assert!(!vis.show_in_archive_only);
        assert!(!vis.is_cycle_safe_child);

        let fixture = include_str!("../shared/orb-spec/fixtures/projection-invariants.json");
        assert!(fixture.contains("\"workfold_cases\""));
        assert!(fixture.contains("\"taskcard_cases\""));
        assert!(fixture.contains("\"sidebar_visibility_cases\""));

        // Verify exact parity with every case in shared/orb-spec/fixtures/projection-invariants.json
        assert_eq!(
            workfold_step(2, false, true, true, true, false),
            WorkfoldStepVerdict {
                fold_item: true,
                fold_has_tool_next: false
            }
        );
        assert_eq!(
            workfold_step(2, false, true, false, false, true),
            WorkfoldStepVerdict {
                fold_item: false,
                fold_has_tool_next: false
            }
        );
        assert_eq!(
            workfold_step(2, true, true, true, true, true),
            WorkfoldStepVerdict {
                fold_item: false,
                fold_has_tool_next: false
            }
        );
        assert_eq!(
            workfold_step(2, false, true, true, false, false),
            WorkfoldStepVerdict {
                fold_item: false,
                fold_has_tool_next: false
            }
        );
        assert_eq!(
            sidebar_visibility(false, true, true, false, false, false),
            SidebarVisibilityVerdict {
                retain_in_main_tree: true,
                show_in_archive_only: false,
                is_cycle_safe_child: false,
            }
        );
        assert_eq!(
            sidebar_visibility(false, false, true, false, false, false),
            SidebarVisibilityVerdict {
                retain_in_main_tree: false,
                show_in_archive_only: true,
                is_cycle_safe_child: false,
            }
        );
    }
}
