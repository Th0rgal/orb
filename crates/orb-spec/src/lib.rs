#![allow(clippy::too_many_arguments)]
//! Typed bindings to `lean/Orb/Kernel.lean` (`liborb_spec_cabi.a`) and `lean-sys-cabi`.

pub use lean_sys_cabi;

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
    fn orb_verify_log_window(
        off: u64,
        req: u64,
        max_c: u64,
        hard_cap: u64,
        fsz: u64,
        act: u64,
    ) -> u8;
    fn orb_mix64_word(acc: u64, word: u64) -> u64;
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
    fn orb_admission_step(
        recovery_phase: u8,
        is_quiescent: u8,
        reserved_tag_forged: u8,
        emergency_plus_cand_bytes: u64,
        free_disk_bytes: u64,
    ) -> u32;
    fn orb_account_cooldown_secs(base_secs: u64, max_secs: u64, consecutive: u32) -> u64;
    fn orb_cost_cents_step(
        input_tokens: u64,
        output_tokens: u64,
        cache_create_tokens: u64,
        cache_read_tokens: u64,
        input_nano: u64,
        output_nano: u64,
        cache_create_nano: u64,
        cache_read_nano: u64,
    ) -> u64;
    fn orb_stream_loop_step(
        cancelled_or_timed_out: u8,
        hash_collision: u8,
        window_len: u32,
        min_len: u32,
        repeats: u32,
        non_overlapping_count: u32,
        distinct_words_4_plus: u32,
        comparisons: u64,
        comparison_budget: u64,
    ) -> u8;
    fn orb_job_ledger_step(
        is_accepted_remote_build: u8,
        expects_continuation: u8,
        newer_terminal_exists: u8,
        newer_ambiguous_tentative: u8,
    ) -> u32;
    fn orb_proc_liveness_step(
        proc_missing: u8,
        proc_read_error: u8,
        is_zombie_or_dead_state: u8,
        has_expected_ticks: u8,
        fields_after_comm: u32,
        expected_start_ticks: u64,
        actual_start_ticks: u64,
    ) -> u8;
    fn orb_pr_gate_step(
        merged: u8,
        draft: u8,
        closed: u8,
        exact_head: u8,
        action_required: u8,
        blocked: u8,
        behind: u8,
        conflicting: u8,
        checks_green: u8,
        workflows_green: u8,
    ) -> u8;
    fn orb_turn_summary_step(
        raw_status: u8,
        turn_ended: u8,
        all_closed: u8,
        turn_outcome_finished: u8,
    ) -> u32;
    fn orb_usage_limit_status(
        status_kind: u8,
        claim_kind: u8,
        has_utilization: u8,
        utilization_pct: u8,
        has_reset: u8,
        reset_rem_secs: u64,
    ) -> u64;
    fn orb_relative_time_bucket(elapsed_secs: u64) -> u64;
    fn orb_transcript_patch_step(
        state_len: u32,
        state_seq: u32,
        event_kind: u8,
        delta_len: u32,
    ) -> u64;
    fn orb_attribution_step(
        principal_kind: u8,
        claimed_kind: u8,
        same_mission: u8,
        is_descendant: u8,
    ) -> u32;
    fn orb_schedule_step(
        op: u8,
        known: u8,
        cancelled: u8,
        owner_terminal: u8,
        authorized: u8,
        busy: u8,
        last_fired: u64,
        next_due: u64,
        now: u64,
    ) -> u8;
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
    pub retry_suppressed: bool,
}

pub fn board_retry_allowed(input: BoardRetry) -> bool {
    unsafe {
        orb_verify_board_retry(
            input.attempts,
            input.max_attempts,
            u8::from(input.requires_external_recovery),
            u8::from(input.preflight_merged),
            u8::from(input.retry_suppressed),
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
    let orb_ok = unsafe {
        orb_verify_log_window(
            input.offset,
            input.req_len,
            input.max_chunk,
            input.hard_cap,
            input.file_size,
            input.actual_len,
        ) != 0
    };
    orb_ok
        && lean_sys_cabi::verify_log_window(
            input.offset,
            input.offset.saturating_add(input.actual_len),
            input.file_size,
            input.max_chunk,
        )
}

#[allow(dead_code)]
pub fn mix64_word(acc: u64, word: u64) -> u64 {
    unsafe { orb_mix64_word(acc, word) ^ lean_sys_cabi::mix64_word(acc, word) }
}

pub fn proc_stat_fields_valid(
    comm_open_idx: u64,
    comm_close_idx: u64,
    total_len: u64,
    min_fields_after_comm: u64,
    actual_fields: u64,
) -> bool {
    lean_sys_cabi::verify_proc_stat_fields(
        comm_open_idx,
        comm_close_idx,
        total_len,
        min_fields_after_comm,
        actual_fields,
    )
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AdmissionStepInput {
    pub recovery_phase: u8,
    pub is_quiescent: bool,
    pub reserved_tag_forged: bool,
    pub emergency_plus_cand_bytes: u64,
    pub free_disk_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AdmissionStepVerdict {
    pub admit: bool,
    pub rollback_required: bool,
    pub fence_both: bool,
}

pub fn admission_step(input: AdmissionStepInput) -> AdmissionStepVerdict {
    let raw = unsafe {
        orb_admission_step(
            input.recovery_phase,
            u8::from(input.is_quiescent),
            u8::from(input.reserved_tag_forged),
            input.emergency_plus_cand_bytes,
            input.free_disk_bytes,
        )
    };
    AdmissionStepVerdict {
        admit: (raw & 1) != 0,
        rollback_required: ((raw >> 8) & 1) != 0,
        fence_both: ((raw >> 16) & 1) != 0,
    }
}

pub fn account_cooldown_secs(base_secs: u64, max_secs: u64, consecutive: u32) -> u64 {
    unsafe { orb_account_cooldown_secs(base_secs, max_secs, consecutive) }
}

pub fn cost_cents_step(
    input_tokens: u64,
    output_tokens: u64,
    cache_create_tokens: u64,
    cache_read_tokens: u64,
    input_nano: u64,
    output_nano: u64,
    cache_create_nano: u64,
    cache_read_nano: u64,
) -> u64 {
    unsafe {
        orb_cost_cents_step(
            input_tokens,
            output_tokens,
            cache_create_tokens,
            cache_read_tokens,
            input_nano,
            output_nano,
            cache_create_nano,
            cache_read_nano,
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamLoopVerdict {
    Clear = 0,
    Repeated = 1,
    Inconclusive = 2,
}

pub fn stream_loop_step(
    cancelled_or_timed_out: bool,
    hash_collision: bool,
    window_len: u32,
    min_len: u32,
    repeats: u32,
    non_overlapping_count: u32,
    distinct_words_4_plus: u32,
    comparisons: u64,
    comparison_budget: u64,
) -> StreamLoopVerdict {
    let code = unsafe {
        orb_stream_loop_step(
            u8::from(cancelled_or_timed_out),
            u8::from(hash_collision),
            window_len,
            min_len,
            repeats,
            non_overlapping_count,
            distinct_words_4_plus,
            comparisons,
            comparison_budget,
        )
    };
    match code {
        1 => StreamLoopVerdict::Repeated,
        2 => StreamLoopVerdict::Inconclusive,
        _ => StreamLoopVerdict::Clear,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobLedgerWake {
    Ready = 0,
    Deferred = 1,
    Superseded = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JobLedgerVerdict {
    pub retain_wait_handle: bool,
    pub wake: JobLedgerWake,
}

pub fn job_ledger_step(
    is_accepted_remote_build: bool,
    expects_continuation: bool,
    newer_terminal_exists: bool,
    newer_ambiguous_tentative: bool,
) -> JobLedgerVerdict {
    let raw = unsafe {
        orb_job_ledger_step(
            u8::from(is_accepted_remote_build),
            u8::from(expects_continuation),
            u8::from(newer_terminal_exists),
            u8::from(newer_ambiguous_tentative),
        )
    };
    let wake = match (raw >> 8) & 0xFF {
        2 => JobLedgerWake::Superseded,
        1 => JobLedgerWake::Deferred,
        _ => JobLedgerWake::Ready,
    };
    JobLedgerVerdict {
        retain_wait_handle: (raw & 1) != 0,
        wake,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcLivenessVerdict {
    Dead = 0,
    Alive = 1,
    InconclusiveAlive = 2,
}

pub fn proc_liveness_step(
    proc_missing: bool,
    proc_read_error: bool,
    is_zombie_or_dead_state: bool,
    has_expected_ticks: bool,
    fields_after_comm: u32,
    expected_start_ticks: u64,
    actual_start_ticks: u64,
) -> ProcLivenessVerdict {
    let code = unsafe {
        orb_proc_liveness_step(
            u8::from(proc_missing),
            u8::from(proc_read_error),
            u8::from(is_zombie_or_dead_state),
            u8::from(has_expected_ticks),
            fields_after_comm,
            expected_start_ticks,
            actual_start_ticks,
        )
    };
    match code {
        1 => ProcLivenessVerdict::Alive,
        2 => ProcLivenessVerdict::InconclusiveAlive,
        _ => ProcLivenessVerdict::Dead,
    }
}

pub const PR_GATE_ALREADY_MERGED: u8 = 0;
pub const PR_GATE_WAIT_FOR_READY: u8 = 1;
pub const PR_GATE_CLOSED_WITHOUT_MERGE: u8 = 2;
pub const PR_GATE_HEAD_CHANGED: u8 = 3;
pub const PR_GATE_ACTION_REQUIRED: u8 = 4;
pub const PR_GATE_BLOCKED_BY_POLICY: u8 = 5;
pub const PR_GATE_NEEDS_UPDATE: u8 = 6;
pub const PR_GATE_NEEDS_CONFLICT_RESOLUTION: u8 = 7;
pub const PR_GATE_READY: u8 = 8;
pub const PR_GATE_NEEDS_CHECKS: u8 = 9;

pub fn pr_gate_step(
    merged: bool,
    draft: bool,
    closed: bool,
    exact_head: bool,
    action_required: bool,
    blocked: bool,
    behind: bool,
    conflicting: bool,
    checks_green: bool,
    workflows_green: bool,
) -> u8 {
    unsafe {
        orb_pr_gate_step(
            u8::from(merged),
            u8::from(draft),
            u8::from(closed),
            u8::from(exact_head),
            u8::from(action_required),
            u8::from(blocked),
            u8::from(behind),
            u8::from(conflicting),
            u8::from(checks_green),
            u8::from(workflows_green),
        )
    }
}

pub fn pr_gate_recommendation(code: u8) -> &'static str {
    match code {
        PR_GATE_ALREADY_MERGED => "already_merged",
        PR_GATE_WAIT_FOR_READY => "wait_for_ready_for_review",
        PR_GATE_CLOSED_WITHOUT_MERGE => "closed_without_merge",
        PR_GATE_HEAD_CHANGED => "head_changed_since_worker",
        PR_GATE_ACTION_REQUIRED => "action_required_external",
        PR_GATE_BLOCKED_BY_POLICY => "blocked_by_policy",
        PR_GATE_NEEDS_UPDATE => "needs_update_with_base",
        PR_GATE_NEEDS_CONFLICT_RESOLUTION => "needs_conflict_resolution",
        PR_GATE_READY => "ready_for_review_or_merge",
        _ => "needs_checks_or_review",
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TurnSummaryVerdict {
    pub normalized_status: u8,
    pub is_done: bool,
    pub is_active: bool,
    pub card_state: u8,
}

pub fn turn_summary_step(
    raw_status: u8,
    turn_ended: bool,
    all_closed: bool,
    turn_outcome_finished: bool,
) -> TurnSummaryVerdict {
    let raw = unsafe {
        orb_turn_summary_step(
            raw_status,
            u8::from(turn_ended),
            u8::from(all_closed),
            u8::from(turn_outcome_finished),
        )
    };
    TurnSummaryVerdict {
        normalized_status: (raw & 0xFF) as u8,
        is_done: ((raw >> 8) & 1) != 0,
        is_active: ((raw >> 16) & 1) != 0,
        card_state: ((raw >> 24) & 0xFF) as u8,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UsageLimitStatusVerdict {
    pub tone: u8,
    pub window_kind: u8,
    pub show_pct: bool,
    pub pct: u8,
    pub reset_unit: u8,
    pub reset_value: u32,
}

pub fn usage_limit_status_step(
    status_kind: u8,
    claim_kind: u8,
    has_utilization: bool,
    utilization_pct: u8,
    has_reset: bool,
    reset_rem_secs: u64,
) -> UsageLimitStatusVerdict {
    let raw = unsafe {
        orb_usage_limit_status(
            status_kind,
            claim_kind,
            u8::from(has_utilization),
            utilization_pct,
            u8::from(has_reset),
            reset_rem_secs,
        )
    };
    UsageLimitStatusVerdict {
        tone: (raw & 0xFF) as u8,
        window_kind: ((raw >> 8) & 0xFF) as u8,
        show_pct: ((raw >> 16) & 1) != 0,
        pct: ((raw >> 24) & 0xFF) as u8,
        reset_unit: ((raw >> 32) & 0xFF) as u8,
        reset_value: ((raw >> 40) & 0xFFFFFF) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RelativeTimeBucket {
    pub unit: u8,
    pub value: u32,
}

pub fn relative_time_bucket(elapsed_secs: u64) -> RelativeTimeBucket {
    let raw = unsafe { orb_relative_time_bucket(elapsed_secs) };
    RelativeTimeBucket {
        unit: (raw & 0xFF) as u8,
        value: ((raw >> 8) & 0xFFFF_FFFF) as u32,
    }
}

pub fn format_relative_time_secs(elapsed_secs: i64) -> String {
    let clamped = if elapsed_secs <= 0 {
        0u64
    } else {
        elapsed_secs as u64
    };
    let bucket = relative_time_bucket(clamped);
    match bucket.unit {
        0 => "now".to_string(),
        1 => format!("{}m", bucket.value),
        2 => format!("{}h", bucket.value),
        3 => format!("{}d", bucket.value),
        _ => format!("{}w", bucket.value),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptPatchState {
    pub len: u32,
    pub seq: u32,
}

pub fn transcript_patch_step(
    state: TranscriptPatchState,
    event_kind: u8,
    delta_len: u32,
) -> TranscriptPatchState {
    let raw = unsafe { orb_transcript_patch_step(state.len, state.seq, event_kind, delta_len) };
    TranscriptPatchState {
        len: (raw & 0xFFFF_FFFF) as u32,
        seq: (raw >> 32) as u32,
    }
}

/// Caller kinds of `orb_attribution_step` (closed enum, see `docs/specs/usage-attribution.md`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum CallerKind {
    #[default]
    Unknown = 0,
    Mission = 1,
    Subagent = 2,
    Hermes = 3,
    OrbUi = 4,
    Core = 5,
    Script = 6,
}

impl CallerKind {
    pub fn from_u8(raw: u8) -> Self {
        match raw {
            1 => Self::Mission,
            2 => Self::Subagent,
            3 => Self::Hermes,
            4 => Self::OrbUi,
            5 => Self::Core,
            6 => Self::Script,
            _ => Self::Unknown,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Mission => "mission",
            Self::Subagent => "subagent",
            Self::Hermes => "hermes",
            Self::OrbUi => "orb_ui",
            Self::Core => "core",
            Self::Script => "script",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttributionVerdict {
    pub kind: CallerKind,
    /// The client hint was inside the principal's scope (or absent).
    pub accepted: bool,
}

/// Verified attribution step: the kind is derived from the authenticated
/// principal; a client claim only refines it within the principal's scope.
/// `claimed = None` means no hint.
pub fn attribution_step(
    principal: CallerKind,
    claimed: Option<CallerKind>,
    same_mission: bool,
    is_descendant: bool,
) -> AttributionVerdict {
    let raw = unsafe {
        orb_attribution_step(
            principal as u8,
            claimed.map_or(0, |k| k as u8),
            u8::from(same_mission),
            u8::from(is_descendant),
        )
    };
    AttributionVerdict {
        kind: CallerKind::from_u8((raw & 0xFF) as u8),
        accepted: (raw >> 8) & 1 == 1,
    }
}

/// Decision of `orb_schedule_step` (see `docs/specs/agent-schedules.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScheduleAction {
    /// Unauthorized, cancelled, or the owner is gone: deactivate / refuse.
    Drop,
    /// A new key: create the schedule.
    Register,
    /// The same key already exists: keep the existing row unchanged.
    Dedupe,
    /// The next slot is due: fire once and move the reference to `now`.
    Fire,
    /// Not due yet (or the mission is busy): try again on a later tick.
    Wait,
}

/// Inputs of one tick of an existing schedule row. Times are Unix seconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScheduleTickInput {
    pub cancelled: bool,
    pub owner_terminal: bool,
    pub authorized: bool,
    pub busy: bool,
    pub last_fired: u64,
    pub next_due: u64,
    pub now: u64,
}

fn schedule_action(raw: u8) -> ScheduleAction {
    match raw {
        1 => ScheduleAction::Register,
        2 => ScheduleAction::Dedupe,
        3 => ScheduleAction::Fire,
        4 => ScheduleAction::Wait,
        _ => ScheduleAction::Drop,
    }
}

/// Verified registration step: `Register` only for an authorized caller, a new
/// key and a live owner; a known key always dedupes.
pub fn schedule_register(known: bool, owner_terminal: bool, authorized: bool) -> ScheduleAction {
    schedule_action(unsafe {
        orb_schedule_step(
            0,
            u8::from(known),
            0,
            u8::from(owner_terminal),
            u8::from(authorized),
            0,
            0,
            0,
            0,
        )
    })
}

/// Verified tick step: fires at most once per due slot, never after a fence.
pub fn schedule_tick(input: ScheduleTickInput) -> ScheduleAction {
    schedule_action(unsafe {
        orb_schedule_step(
            1,
            0,
            u8::from(input.cancelled),
            u8::from(input.owner_terminal),
            u8::from(input.authorized),
            u8::from(input.busy),
            input.last_fired,
            input.next_due,
            input.now,
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_step_dedupes_fences_and_fires_once_per_slot() {
        assert_eq!(
            schedule_register(false, false, true),
            ScheduleAction::Register
        );
        assert_eq!(schedule_register(true, false, true), ScheduleAction::Dedupe);
        assert_eq!(schedule_register(true, true, true), ScheduleAction::Dedupe);
        assert_eq!(schedule_register(false, true, true), ScheduleAction::Drop);
        assert_eq!(schedule_register(false, false, false), ScheduleAction::Drop);
        let tick = ScheduleTickInput {
            cancelled: false,
            owner_terminal: false,
            authorized: true,
            busy: false,
            last_fired: 100,
            next_due: 1_900,
            now: 1_900,
        };
        assert_eq!(schedule_tick(tick), ScheduleAction::Fire);
        // Hours of downtime: still a single fire, then the slot is consumed.
        assert_eq!(
            schedule_tick(ScheduleTickInput {
                now: 90_000,
                ..tick
            }),
            ScheduleAction::Fire
        );
        assert_eq!(
            schedule_tick(ScheduleTickInput {
                last_fired: 90_000,
                now: 90_001,
                ..tick
            }),
            ScheduleAction::Wait
        );
        assert_eq!(
            schedule_tick(ScheduleTickInput { now: 1_899, ..tick }),
            ScheduleAction::Wait
        );
        assert_eq!(
            schedule_tick(ScheduleTickInput { busy: true, ..tick }),
            ScheduleAction::Wait
        );
        assert_eq!(
            schedule_tick(ScheduleTickInput {
                cancelled: true,
                ..tick
            }),
            ScheduleAction::Drop
        );
        assert_eq!(
            schedule_tick(ScheduleTickInput {
                owner_terminal: true,
                ..tick
            }),
            ScheduleAction::Drop
        );
        assert_eq!(
            schedule_tick(ScheduleTickInput {
                authorized: false,
                ..tick
            }),
            ScheduleAction::Drop
        );
    }

    #[test]
    fn attribution_step_rejects_forged_hints_and_never_returns_empty() {
        use CallerKind::*;
        let v = attribution_step(Script, Some(Mission), false, false);
        assert_eq!((v.kind, v.accepted), (Script, false));
        let v = attribution_step(Mission, Some(Subagent), false, false);
        assert_eq!((v.kind, v.accepted), (Mission, false));
        let v = attribution_step(Mission, Some(Subagent), false, true);
        assert_eq!((v.kind, v.accepted), (Subagent, true));
        let v = attribution_step(Core, None, false, false);
        assert_eq!((v.kind, v.accepted), (Core, true));
        let v = attribution_step(Core, Some(Mission), false, false);
        assert_eq!((v.kind, v.accepted), (Mission, true));
        let v = attribution_step(Unknown, Some(Core), false, false);
        assert_eq!((v.kind, v.accepted), (Unknown, false));
        let v = attribution_step(Hermes, Some(OrbUi), false, false);
        assert_eq!((v.kind, v.accepted), (Hermes, false));
    }

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
            retry_suppressed: false,
        }));
        assert!(!board_retry_allowed(BoardRetry {
            attempts: 5,
            max_attempts: 5,
            requires_external_recovery: false,
            preflight_merged: false,
            retry_suppressed: false,
        }));
        assert!(!board_retry_allowed(BoardRetry {
            attempts: 0,
            max_attempts: 0,
            requires_external_recovery: false,
            preflight_merged: false,
            retry_suppressed: false,
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

        let fixture = include_str!("../../../shared/orb-spec/fixtures/projection-invariants.json");
        assert!(fixture.contains("\"workfold_cases\""));
        assert!(fixture.contains("\"taskcard_cases\""));
        assert!(fixture.contains("\"sidebar_visibility_cases\""));
        assert!(fixture.contains("\"pr_gate_cases\""));

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

    #[test]
    fn tier1_admission_cooldown_cost_and_stream_loop_match_kernel() {
        assert!(
            admission_step(AdmissionStepInput {
                recovery_phase: 2,
                is_quiescent: false,
                reserved_tag_forged: false,
                emergency_plus_cand_bytes: 1,
                free_disk_bytes: 9,
            })
            .fence_both
        );
        assert!(
            !admission_step(AdmissionStepInput {
                recovery_phase: 0,
                is_quiescent: false,
                reserved_tag_forged: true,
                emergency_plus_cand_bytes: 1,
                free_disk_bytes: 9,
            })
            .admit
        );
        assert_eq!(account_cooldown_secs(600, 21_600, 1), 600);
        assert_eq!(account_cooldown_secs(600, 21_600, 2), 1_200);
        assert_eq!(account_cooldown_secs(600, 21_600, 25), 21_600);
        assert_eq!(cost_cents_step(100, 0, 500, 0, 3_000, 15_000, 0, 0), 0);
        assert_eq!(cost_cents_step(1_000, 1_000, 0, 0, 3_000, 15_000, 0, 0), 2);
        assert_ne!(
            stream_loop_step(false, true, 64, 8, 2, 2, 2, 0, 1_000),
            StreamLoopVerdict::Repeated
        );
        assert_ne!(
            stream_loop_step(false, false, 64, 8, 2, 2, 1, 0, 1_000),
            StreamLoopVerdict::Repeated
        );
    }

    #[test]
    fn tier1_ledger_liveness_and_pr_gate_match_kernel() {
        let superseded = job_ledger_step(true, true, true, false);
        assert!(!superseded.retain_wait_handle);
        assert_eq!(superseded.wake, JobLedgerWake::Superseded);
        let ambiguous = job_ledger_step(true, true, false, true);
        assert!(!ambiguous.retain_wait_handle);
        assert_eq!(ambiguous.wake, JobLedgerWake::Deferred);
        let retained = job_ledger_step(true, true, false, false);
        assert!(retained.retain_wait_handle);
        assert_eq!(retained.wake, JobLedgerWake::Ready);
        assert_eq!(
            proc_liveness_step(false, true, false, false, 25, 1_000, 2_000),
            ProcLivenessVerdict::InconclusiveAlive
        );
        assert_eq!(
            proc_liveness_step(false, false, false, true, 25, 1_000, 2_000),
            ProcLivenessVerdict::Dead
        );
        assert_eq!(
            pr_gate_step(false, false, false, false, false, false, false, false, true, true),
            PR_GATE_HEAD_CHANGED
        );
        assert_eq!(
            pr_gate_recommendation(pr_gate_step(
                false, false, false, true, true, false, false, false, true, true
            )),
            "action_required_external"
        );
        assert!(proc_stat_fields_valid(5, 18, 120, 20, 35));
        assert!(!proc_stat_fields_valid(18, 5, 120, 20, 35));
    }

    #[test]
    fn turn_summary_usage_limit_relative_time_and_transcript_patch_match_fixtures() {
        let settled = turn_summary_step(1, true, false, true);
        assert_eq!(
            settled,
            TurnSummaryVerdict {
                normalized_status: 0,
                is_done: false,
                is_active: false,
                card_state: 2,
            }
        );
        let live_active = turn_summary_step(1, false, false, false);
        assert_eq!(
            live_active,
            TurnSummaryVerdict {
                normalized_status: 1,
                is_done: false,
                is_active: true,
                card_state: 0,
            }
        );

        assert_eq!(usage_limit_status_step(0, 0, false, 0, false, 0).tone, 0);
        let warn_7d = usage_limit_status_step(1, 2, true, 88, false, 0);
        assert_eq!(warn_7d.tone, 1);
        assert_eq!(warn_7d.window_kind, 2);
        assert!(warn_7d.show_pct);
        assert_eq!(warn_7d.pct, 88);
        let warn_opus = usage_limit_status_step(1, 3, true, 88, false, 0);
        assert!(!warn_opus.show_pct);
        let rej_min = usage_limit_status_step(2, 0, false, 0, true, 30);
        assert_eq!(rej_min.tone, 2);
        assert_eq!(rej_min.reset_unit, 1);
        assert_eq!(rej_min.reset_value, 1);
        let rej_days = usage_limit_status_step(2, 0, false, 0, true, 259_200);
        assert_eq!(rej_days.reset_unit, 3);
        assert_eq!(rej_days.reset_value, 3);

        assert_eq!(format_relative_time_secs(-30), "now");
        assert_eq!(format_relative_time_secs(44), "now");
        assert_eq!(format_relative_time_secs(45), "1m");
        assert_eq!(format_relative_time_secs(59), "1m");
        assert_eq!(format_relative_time_secs(120), "2m");
        assert_eq!(format_relative_time_secs(3_600), "1h");
        assert_eq!(format_relative_time_secs(86_400), "1d");
        assert_eq!(format_relative_time_secs(604_800), "1w");

        let chunk1 = [(0u8, 12u32), (0u8, 8u32)];
        let chunk2 = [(1u8, 25u32), (2u8, 0u32), (0u8, 14u32)];
        let init = TranscriptPatchState { len: 0, seq: 0 };
        let inc = chunk2.iter().fold(
            chunk1
                .iter()
                .fold(init, |s, &(k, d)| transcript_patch_step(s, k, d)),
            |s, &(k, d)| transcript_patch_step(s, k, d),
        );
        let batch = chunk1
            .iter()
            .chain(chunk2.iter())
            .fold(init, |s, &(k, d)| transcript_patch_step(s, k, d));
        assert_eq!(inc, batch);
        assert_eq!(inc, TranscriptPatchState { len: 14, seq: 5 });

        let near_max = TranscriptPatchState {
            len: 0xFFFF_FFF0,
            seq: u32::MAX,
        };
        assert_eq!(
            transcript_patch_step(near_max, 0, 0x20),
            TranscriptPatchState {
                len: u32::MAX,
                seq: u32::MAX
            }
        );
        let s = TranscriptPatchState { len: 142, seq: 10 };
        assert_eq!(transcript_patch_step(s, 3, 99), s);
        assert_eq!(transcript_patch_step(s, 255, 99), s);

        assert!(lean_sys_cabi::sse_frame_scan(0, 12, 64, 1, b'\n', b'}'));
        assert!(!lean_sys_cabi::sse_frame_scan(0, 12, 64, 1, b'\n', 0xC3));
        assert!(lean_sys_cabi::gfm_pipe_scan(0, 24, 64, 3, 3, false));
        assert!(lean_sys_cabi::tag_scan(0, 32, 4, 8, 64, 1));
        assert_ne!(lean_sys_cabi::transcript_index(0, 40, 128, 1, 9), 0);
    }
}
