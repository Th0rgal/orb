#![allow(clippy::too_many_arguments)]
//! Typed bindings to `lean/Orb/Kernel.lean` and `LeanSys/Spec.lean` (`liborb_spec_cabi.a`).

pub mod shadow;

pub mod lean_sys_cabi {
    //! Zero-dependency typed Rust bindings to the 21 formally verified unboxed C-ABI
    //! safety gates in `LeanSys/Spec.lean` (`0 import Lean`, `0 sorryAx`), linked from
    //! `shared/orb-spec/cabi/orb_kernel_unboxed.c`.

    unsafe extern "C" {
        pub fn leansys_verify_slice_bounds(off: u64, len: u64, cap: u64) -> u8;
        pub fn leansys_verify_wal_frame(
            magic: u32,
            payload_len: u32,
            actual_bytes: u64,
            expected_hash: u64,
            computed_hash: u64,
        ) -> u8;
        pub fn leansys_verify_cas_digest(
            expected_digest: u64,
            computed_digest: u64,
            has_path_sep: u8,
        ) -> u8;
        pub fn leansys_check_http_bounds(
            num_headers: u32,
            content_len: u64,
            actual_body_len: u64,
            auth_ok: u8,
        ) -> u8;
        pub fn leansys_verify_jsonl_tape(
            key_off: u64,
            key_len: u64,
            val_off: u64,
            val_len: u64,
            buf_cap: u64,
            depth: u32,
        ) -> u8;
        pub fn leansys_verify_ring_cursor(head: u64, tail: u64, cap: u64, msg_len: u64) -> u8;
        pub fn leansys_verify_sst_block(
            magic: u32,
            num_entries: u32,
            index_off: u64,
            footer_off: u64,
            file_size: u64,
            bloom_mask: u64,
        ) -> u8;
        pub fn leansys_verify_poll_interest(
            active_conns: u32,
            max_conns: u32,
            keep_alive_reqs: u32,
            max_keep_alive: u32,
            idle_ms: u32,
            max_idle_ms: u32,
        ) -> u8;
        pub fn leansys_verify_rlimit_budget(
            rss_bytes: u64,
            max_rss_bytes: u64,
            elapsed_ms: u64,
            timeout_ms: u64,
            pipe_bytes: u64,
            max_pipe_bytes: u64,
        ) -> u8;
        pub fn leansys_mix64_word(acc: u64, word: u64) -> u64;
        pub fn leansys_verify_composite_key_order(
            hi_a: u64,
            lo_a: u64,
            seq_a: u64,
            hi_b: u64,
            lo_b: u64,
            seq_b: u64,
        ) -> u8;
        pub fn leansys_verify_token_auth(
            match_current: u8,
            has_prev: u8,
            match_prev: u8,
            scope_ok: u8,
            now_epoch: u64,
            expires_at: u64,
        ) -> u8;
        pub fn leansys_verify_log_window(
            start_off: u64,
            next_off: u64,
            file_len: u64,
            max_bytes: u64,
        ) -> u8;
        pub fn leansys_verify_jsonrpc_frame(
            has_v2: u8,
            has_id: u8,
            method_len: u32,
            payload_len: u64,
        ) -> u8;
        pub fn leansys_gate_admit(no_sorry_ax: u8, statement_pinned: u8, cert_verified: u8) -> u8;
        pub fn leansys_verify_mmap_seqlock(
            magic: u32,
            schema_version: u32,
            expected_version: u32,
            seq_before: u64,
            seq_after: u64,
            writer_epoch: u64,
            min_epoch: u64,
            payload_len: u64,
            ring_cap: u64,
        ) -> u8;
        pub fn leansys_verify_proc_stat_fields(
            comm_open_idx: u64,
            comm_close_idx: u64,
            total_len: u64,
            min_fields_after_comm: u64,
            actual_fields: u64,
        ) -> u8;
        pub fn leansys_sse_frame_scan(
            frame_off: u64,
            frame_len: u64,
            chunk_len: u64,
            field_kind: u8,
            next_byte: u8,
            last_byte: u8,
        ) -> u8;
        pub fn leansys_gfm_pipe_scan(
            row_off: u64,
            row_len: u64,
            buf_len: u64,
            col_count: u32,
            sep_cols: u32,
            unterminated_escape: u8,
        ) -> u8;
        pub fn leansys_tag_scan(
            tag_off: u64,
            tag_len: u64,
            attr_off: u64,
            attr_len: u64,
            buf_len: u64,
            tag_kind: u8,
        ) -> u8;
        pub fn leansys_transcript_index(
            turn_off: u64,
            turn_len: u64,
            buf_len: u64,
            prev_digest: u64,
            block_hash: u64,
        ) -> u64;
        pub fn leansys_verify_ios_jetsam_budget(
            dirty_rss_bytes: u64,
            alloc_bytes: u64,
            max_jetsam_bytes: u64,
            page_align_mask: u64,
            is_app_extension: u8,
        ) -> u8;
        pub fn leansys_verify_worker_budget(
            active_workers: u64,
            max_workers: u64,
            micro_chunks: u64,
            total_len: u64,
            topology_kind: u8,
        ) -> u8;
        pub fn leansys_verify_page_aligned_buffer(
            addr: u64,
            alloc_bytes: u64,
            capacity_bytes: u64,
            dirty_rss_bytes: u64,
            max_budget_bytes: u64,
            page_align_mask: u64,
        ) -> u8;
        pub fn leansys_select_isa(
            detected_hw_caps: u64,
            required_mask: u64,
            requested_variant_id: u8,
            max_variant_id: u8,
        ) -> u8;
        pub fn leansys_verify_isa_selection(
            detected_hw_caps: u64,
            required_mask: u64,
            selected_variant_id: u8,
            max_variant_id: u8,
        ) -> u8;
    }

    pub const WAL_MAGIC: u32 = 0x4C53_5953;
    pub const SST_MAGIC: u32 = 0x4C53_5354;
    pub const MMAP_SEQLOCK_MAGIC: u32 = 0x4C53_4D4D;

    #[inline]
    pub fn verify_slice_bounds(off: u64, len: u64, cap: u64) -> bool {
        unsafe { leansys_verify_slice_bounds(off, len, cap) == 1 }
    }

    #[inline]
    pub fn verify_wal_frame(
        magic: u32,
        payload_len: u32,
        actual_bytes: u64,
        expected_hash: u64,
        computed_hash: u64,
    ) -> bool {
        unsafe {
            leansys_verify_wal_frame(
                magic,
                payload_len,
                actual_bytes,
                expected_hash,
                computed_hash,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_cas_digest(
        expected_digest: u64,
        computed_digest: u64,
        has_path_sep: bool,
    ) -> bool {
        unsafe {
            leansys_verify_cas_digest(expected_digest, computed_digest, u8::from(has_path_sep)) == 1
        }
    }

    #[inline]
    pub fn check_http_bounds(
        num_headers: u32,
        content_len: u64,
        actual_body_len: u64,
        auth_ok: bool,
    ) -> bool {
        unsafe {
            leansys_check_http_bounds(num_headers, content_len, actual_body_len, u8::from(auth_ok))
                == 1
        }
    }

    #[inline]
    pub fn verify_jsonl_tape(
        key_off: u64,
        key_len: u64,
        val_off: u64,
        val_len: u64,
        buf_cap: u64,
        depth: u32,
    ) -> bool {
        unsafe {
            leansys_verify_jsonl_tape(key_off, key_len, val_off, val_len, buf_cap, depth) == 1
        }
    }

    #[inline]
    pub fn verify_ring_cursor(head: u64, tail: u64, cap: u64, msg_len: u64) -> bool {
        unsafe { leansys_verify_ring_cursor(head, tail, cap, msg_len) == 1 }
    }

    #[inline]
    pub fn verify_sst_block(
        magic: u32,
        num_entries: u32,
        index_off: u64,
        footer_off: u64,
        file_size: u64,
        bloom_mask: u64,
    ) -> bool {
        unsafe {
            leansys_verify_sst_block(
                magic,
                num_entries,
                index_off,
                footer_off,
                file_size,
                bloom_mask,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_poll_interest(
        active_conns: u32,
        max_conns: u32,
        keep_alive_reqs: u32,
        max_keep_alive: u32,
        idle_ms: u32,
        max_idle_ms: u32,
    ) -> bool {
        unsafe {
            leansys_verify_poll_interest(
                active_conns,
                max_conns,
                keep_alive_reqs,
                max_keep_alive,
                idle_ms,
                max_idle_ms,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_rlimit_budget(
        rss_bytes: u64,
        max_rss_bytes: u64,
        elapsed_ms: u64,
        timeout_ms: u64,
        pipe_bytes: u64,
        max_pipe_bytes: u64,
    ) -> bool {
        unsafe {
            leansys_verify_rlimit_budget(
                rss_bytes,
                max_rss_bytes,
                elapsed_ms,
                timeout_ms,
                pipe_bytes,
                max_pipe_bytes,
            ) == 1
        }
    }

    #[inline]
    pub fn mix64_word(acc: u64, word: u64) -> u64 {
        unsafe { leansys_mix64_word(acc, word) }
    }

    #[inline]
    pub fn verify_composite_key_order(
        hi_a: u64,
        lo_a: u64,
        seq_a: u64,
        hi_b: u64,
        lo_b: u64,
        seq_b: u64,
    ) -> bool {
        unsafe { leansys_verify_composite_key_order(hi_a, lo_a, seq_a, hi_b, lo_b, seq_b) == 1 }
    }

    #[inline]
    pub fn verify_token_auth(
        match_current: bool,
        has_prev: bool,
        match_prev: bool,
        scope_ok: bool,
        now_epoch: u64,
        expires_at: u64,
    ) -> bool {
        unsafe {
            leansys_verify_token_auth(
                u8::from(match_current),
                u8::from(has_prev),
                u8::from(match_prev),
                u8::from(scope_ok),
                now_epoch,
                expires_at,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_log_window(start_off: u64, next_off: u64, file_len: u64, max_bytes: u64) -> bool {
        unsafe { leansys_verify_log_window(start_off, next_off, file_len, max_bytes) == 1 }
    }

    #[inline]
    pub fn verify_jsonrpc_frame(
        has_v2: bool,
        has_id: bool,
        method_len: u32,
        payload_len: u64,
    ) -> bool {
        unsafe {
            leansys_verify_jsonrpc_frame(
                u8::from(has_v2),
                u8::from(has_id),
                method_len,
                payload_len,
            ) == 1
        }
    }

    #[inline]
    pub fn gate_admit(no_sorry_ax: bool, statement_pinned: bool, cert_verified: bool) -> bool {
        unsafe {
            leansys_gate_admit(
                u8::from(no_sorry_ax),
                u8::from(statement_pinned),
                u8::from(cert_verified),
            ) == 1
        }
    }

    #[inline]
    pub fn verify_mmap_seqlock(
        magic: u32,
        schema_version: u32,
        expected_version: u32,
        seq_before: u64,
        seq_after: u64,
        writer_epoch: u64,
        min_epoch: u64,
        payload_len: u64,
        ring_cap: u64,
    ) -> bool {
        unsafe {
            leansys_verify_mmap_seqlock(
                magic,
                schema_version,
                expected_version,
                seq_before,
                seq_after,
                writer_epoch,
                min_epoch,
                payload_len,
                ring_cap,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_proc_stat_fields(
        comm_open_idx: u64,
        comm_close_idx: u64,
        total_len: u64,
        min_fields_after_comm: u64,
        actual_fields: u64,
    ) -> bool {
        unsafe {
            leansys_verify_proc_stat_fields(
                comm_open_idx,
                comm_close_idx,
                total_len,
                min_fields_after_comm,
                actual_fields,
            ) == 1
        }
    }

    #[inline]
    pub fn sse_frame_scan(
        frame_off: u64,
        frame_len: u64,
        chunk_len: u64,
        field_kind: u8,
        next_byte: u8,
        last_byte: u8,
    ) -> bool {
        unsafe {
            leansys_sse_frame_scan(
                frame_off, frame_len, chunk_len, field_kind, next_byte, last_byte,
            ) == 1
        }
    }

    #[inline]
    pub fn gfm_pipe_scan(
        row_off: u64,
        row_len: u64,
        buf_len: u64,
        col_count: u32,
        sep_cols: u32,
        unterminated_escape: bool,
    ) -> bool {
        unsafe {
            leansys_gfm_pipe_scan(
                row_off,
                row_len,
                buf_len,
                col_count,
                sep_cols,
                u8::from(unterminated_escape),
            ) == 1
        }
    }

    #[inline]
    pub fn tag_scan(
        tag_off: u64,
        tag_len: u64,
        attr_off: u64,
        attr_len: u64,
        buf_len: u64,
        tag_kind: u8,
    ) -> bool {
        unsafe { leansys_tag_scan(tag_off, tag_len, attr_off, attr_len, buf_len, tag_kind) == 1 }
    }

    #[inline]
    pub fn transcript_index(
        turn_off: u64,
        turn_len: u64,
        buf_len: u64,
        prev_digest: u64,
        block_hash: u64,
    ) -> u64 {
        unsafe { leansys_transcript_index(turn_off, turn_len, buf_len, prev_digest, block_hash) }
    }

    #[inline]
    pub fn verify_ios_jetsam_budget(
        dirty_rss_bytes: u64,
        alloc_bytes: u64,
        max_jetsam_bytes: u64,
        page_align_mask: u64,
        is_app_extension: bool,
    ) -> bool {
        unsafe {
            leansys_verify_ios_jetsam_budget(
                dirty_rss_bytes,
                alloc_bytes,
                max_jetsam_bytes,
                page_align_mask,
                u8::from(is_app_extension),
            ) == 1
        }
    }

    #[inline]
    pub fn verify_worker_budget(
        active_workers: u64,
        max_workers: u64,
        micro_chunks: u64,
        total_len: u64,
        topology_kind: u8,
    ) -> bool {
        unsafe {
            leansys_verify_worker_budget(
                active_workers,
                max_workers,
                micro_chunks,
                total_len,
                topology_kind,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_page_aligned_buffer(
        addr: u64,
        alloc_bytes: u64,
        capacity_bytes: u64,
        dirty_rss_bytes: u64,
        max_budget_bytes: u64,
        page_align_mask: u64,
    ) -> bool {
        unsafe {
            leansys_verify_page_aligned_buffer(
                addr,
                alloc_bytes,
                capacity_bytes,
                dirty_rss_bytes,
                max_budget_bytes,
                page_align_mask,
            ) == 1
        }
    }

    #[inline]
    pub fn select_isa(
        detected_hw_caps: u64,
        required_mask: u64,
        requested_variant_id: u8,
        max_variant_id: u8,
    ) -> u8 {
        unsafe {
            leansys_select_isa(
                detected_hw_caps,
                required_mask,
                requested_variant_id,
                max_variant_id,
            )
        }
    }

    #[inline]
    pub fn verify_isa_selection(
        detected_hw_caps: u64,
        required_mask: u64,
        selected_variant_id: u8,
        max_variant_id: u8,
    ) -> bool {
        unsafe {
            leansys_verify_isa_selection(
                detected_hw_caps,
                required_mask,
                selected_variant_id,
                max_variant_id,
            ) == 1
        }
    }
}

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
    fn orb_stats_settle_step(acc: u64, cost: u64, seen: u8) -> u64;
    fn orb_privilege_step(
        same_owner: u8,
        mission_active: u8,
        biometric_signed: u8,
        scope_rank: u8,
        max_granted_scope: u8,
        bunker_state: u8,
        revoked: u8,
        now_epoch: u64,
        grant_expires_at: u64,
        session_expires_at: u64,
    ) -> u32;
    fn orb_bunker_step(
        current_state: u8,
        canary_tripped: u8,
        auth_failure_burst: u8,
        manual_trigger: u8,
        biometric_unbunker: u8,
    ) -> u32;
    fn orb_deploy_gate_step(
        is_prod_service: u8,
        service_matches: u8,
        calling_on_self: u8,
        debounce_ok: u8,
        force_flag: u8,
        biometric_approved: u8,
        bunker_state: u8,
        live_writers: u32,
    ) -> u8;
    fn orb_wire_validate_frame(
        magic: u32,
        abi_version: u32,
        schema_id: u32,
        expected_schema_id: u32,
        total_len: u32,
        payload_len: u32,
        arena_off: u32,
        arena_len: u32,
        max_budget_bytes: u32,
        out_cap: u32,
        required_out_bytes: u32,
    ) -> u8;
    fn orb_wire_pack_record(tag: u8, flags: u8, len16: u32, payload32: u32) -> u64;
    fn orb_wire_schema_migrate_step(
        from_schema: u32,
        to_schema: u32,
        current_schema: u32,
        payload_bytes: u64,
        max_bytes: u64,
    ) -> u8;
    fn orb_effect_admissible(
        effect_kind: u8,
        has_valid_lease: u8,
        session_created: u8,
        lineage_verified: u8,
        is_archived: u8,
        idempotency_fresh: u8,
        account_bound: u8,
        account_rejected: u8,
        first_byte_locked: u8,
        grammar_allowed: u8,
        env_scrubbed: u8,
        budget_ok: u8,
    ) -> u8;
    fn orb_provider_pool_step(
        has_bound_account: u8,
        bound_account_id: u32,
        candidate_account_id: u32,
        is_rejected: u8,
        first_byte_sent: u8,
        is_failover_attempt: u8,
        attempts: u32,
        max_attempts: u32,
        now_epoch: u64,
        reset_epoch: u64,
    ) -> u64;
    fn orb_route_argmin_step(
        has_best: u8,
        best_id: u32,
        best_score: u64,
        cand_id: u32,
        cand_score: u64,
        cand_admissible: u8,
    ) -> u64;
    fn orb_mission_control_step(
        is_archived: u8,
        active_track_writers: u32,
        has_lease: u8,
        msg_already_delivered: u8,
        is_resume: u8,
        session_created: u8,
        lineage_verified: u8,
        rollout_exists: u8,
        has_fallback_prompt: u8,
    ) -> u64;
    fn orb_fork_home_step(
        is_fork_or_side: u8,
        source_exists: u8,
        source_is_symlink: u8,
        same_workspace: u8,
        same_node: u8,
        has_committed_transfer: u8,
        requested_override_home: u8,
    ) -> u64;
    fn orb_privd_command_step(
        lease_valid: u8,
        grant_scope: u8,
        command_class: u8,
        unit_matches_allowed: u8,
        has_shell_metachar_or_flag_bypass: u8,
        has_path_traversal_or_symlink: u8,
        has_unsafe_env_var: u8,
        require_force_cmd: u8,
    ) -> u64;
    fn orb_ssh_identity_step(
        is_worker_or_container_target: u8,
        bundle_has_control_plane_key: u8,
        parent_dir_is_symlink: u8,
        pub_key_is_ed25519_without_private: u8,
        proxy_jump_valid: u8,
        codex_cyber_program_valid: u8,
        codex_goal_budget_exhausted: u8,
    ) -> u64;
    fn orb_agent_event_normalize_step(
        harness_kind: u8,
        raw_event_kind: u8,
        is_completed: u8,
        has_non_empty_text: u8,
        session_matches_exp: u32,
        is_duplicate_turn_tool: u32,
        payload_bytes: u32,
        max_payload_bytes: u32,
    ) -> u64;
    fn orb_transcript_reduce_step(
        last_applied_seq: u64,
        incoming_seq: u64,
        thinking_open: u8,
        normalized_action: u8,
        is_replay_from_log: u8,
    ) -> u64;
    fn orb_cursor_page_step(
        since_seq: u64,
        before_seq: u64,
        item_seq: u64,
        has_since_cursor: u32,
        has_before_cursor: u32,
        is_partial_response: u32,
        existing_count: u32,
    ) -> u64;
    fn orb_sidebar_merge_step(
        existing_id_ord: u32,
        incoming_id_ord: u32,
        existing_updated_at_ms: u64,
        incoming_updated_at_ms: u64,
        incoming_superseded_or_archived: u8,
        is_partial_page: u8,
    ) -> u64;
    fn orb_scroll_epoch_step(
        layout_epoch: u32,
        last_corrected_epoch: u32,
        corrections_in_epoch: u8,
        is_pinned_to_bottom: u8,
        user_is_dragging: u8,
        target_scroll_top_px: u32,
        current_scroll_top_px: u32,
    ) -> u64;
    fn orb_client_parity_step(
        client_target: u8,
        wire_schema_id: u32,
        transcript_seq: u32,
        markdown_blocks_count: u32,
        send_queue_depth: u32,
        scroll_corrected_in_epoch: u8,
    ) -> u64;
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

/// Verified spend-statistics settle step (`orb_stats_settle_step`): adds
/// `cost` to `acc` once; a replayed request (`seen`) adds nothing; the total
/// saturates. Conservation of the grouping it feeds is proved in
/// `lean/Orb/Spec.lean` (`statBuckets_conserve`, `statsOutbox`).
pub fn stats_settle_step(acc: u64, cost: u64, seen: bool) -> u64 {
    unsafe { orb_stats_settle_step(acc, cost, u8::from(seen)) }
}

/// Scope ranks for the Biometric JIT Privilege Broker (`orb_privilege_step`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum PrivilegeScopeRank {
    OpsRead = 0,
    ServiceDeploy = 1,
    RootExec = 2,
}

impl PrivilegeScopeRank {
    pub fn from_u8(raw: u8) -> Self {
        match raw {
            0 => Self::OpsRead,
            1 => Self::ServiceDeploy,
            _ => Self::RootExec,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::OpsRead => "ops_read",
            Self::ServiceDeploy => "service_deploy",
            Self::RootExec => "root_exec",
        }
    }
}

/// Fleet/Node Bunker Mode states (`orb_bunker_step`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum BunkerState {
    #[default]
    Normal = 0,
    SoftQuarantine = 1,
    HardLockdown = 2,
}

impl BunkerState {
    pub fn from_u8(raw: u8) -> Self {
        match raw {
            0 => Self::Normal,
            1 => Self::SoftQuarantine,
            _ => Self::HardLockdown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrivilegeStepInput {
    pub same_owner: bool,
    pub mission_active: bool,
    pub biometric_signed: bool,
    pub requested_scope: PrivilegeScopeRank,
    pub max_granted_scope: PrivilegeScopeRank,
    pub bunker_state: BunkerState,
    pub revoked: bool,
    pub now_epoch: u64,
    pub grant_expires_at: u64,
    pub session_expires_at: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrivilegeStepVerdict {
    pub allow_exec: bool,
    pub require_force_cmd: bool,
    pub reap_grant: bool,
}

/// Verified Biometric JIT Privilege Broker gate (`orb_privilege_step`):
/// admits execution iff hardware biometric signature is valid, owner matches,
/// mission is active, bunker state is normal, and neither the grant TTL nor
/// the mission session clock has expired (`privilege_bounded_by_session_clock`).
pub fn privilege_step(input: PrivilegeStepInput) -> PrivilegeStepVerdict {
    let raw = unsafe {
        orb_privilege_step(
            u8::from(input.same_owner),
            u8::from(input.mission_active),
            u8::from(input.biometric_signed),
            input.requested_scope as u8,
            input.max_granted_scope as u8,
            input.bunker_state as u8,
            u8::from(input.revoked),
            input.now_epoch,
            input.grant_expires_at,
            input.session_expires_at,
        )
    };
    PrivilegeStepVerdict {
        allow_exec: (raw & 1) == 1,
        require_force_cmd: ((raw >> 8) & 1) == 1,
        reap_grant: ((raw >> 16) & 1) == 1,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BunkerStepVerdict {
    pub next_state: BunkerState,
    pub revoke_all_jit_grants: bool,
    pub isolate_node_mesh: bool,
}

/// Verified Bunker Mode & Canary Tripwire stepper (`orb_bunker_step`):
/// sticky fence that revokes all active JIT privilege grants and never returns
/// to `Normal` without a hardware biometric operator reset (`bunker_sticky_without_biometric_reset`).
pub fn bunker_step(
    current_state: BunkerState,
    canary_tripped: bool,
    auth_failure_burst: bool,
    manual_trigger: u8,
    biometric_unbunker: bool,
) -> BunkerStepVerdict {
    let raw = unsafe {
        orb_bunker_step(
            current_state as u8,
            u8::from(canary_tripped),
            u8::from(auth_failure_burst),
            manual_trigger,
            u8::from(biometric_unbunker),
        )
    };
    BunkerStepVerdict {
        next_state: BunkerState::from_u8((raw & 0xFF) as u8),
        revoke_all_jit_grants: ((raw >> 8) & 1) == 1,
        isolate_node_mesh: ((raw >> 16) & 1) == 1,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeployGateInput {
    pub is_prod_service: bool,
    pub service_matches: bool,
    pub calling_on_self: bool,
    pub debounce_ok: bool,
    pub force_flag: bool,
    pub biometric_approved: bool,
    pub bunker_state: BunkerState,
    pub live_writers: u32,
}

/// Verified Guarded Deploy Gate (`orb_deploy_gate_step`):
/// dev/staging deploys remain zero-touch for agents, while production deploys
/// require an active session-scoped `service_deploy` grant or direct biometric signature.
pub fn deploy_gate_step(input: DeployGateInput) -> bool {
    let raw = unsafe {
        orb_deploy_gate_step(
            u8::from(input.is_prod_service),
            u8::from(input.service_matches),
            u8::from(input.calling_on_self),
            u8::from(input.debounce_ok),
            u8::from(input.force_flag),
            u8::from(input.biometric_approved),
            input.bunker_state as u8,
            input.live_writers,
        )
    };
    raw == 1
}

/// Status code returned by `orb_wire_validate_frame`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum OrbWireStatus {
    Ok = 0,
    BadMagicOrVersion = 1,
    UnsupportedSchema = 2,
    TruncatedOrOutOfBounds = 3,
    BudgetExceeded = 4,
    OutputTooSmall = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireFrameInput {
    pub magic: u32,
    pub abi_version: u32,
    pub schema_id: u32,
    pub expected_schema_id: u32,
    pub total_len: u32,
    pub payload_len: u32,
    pub arena_off: u32,
    pub arena_len: u32,
    pub max_budget_bytes: u32,
    pub out_cap: u32,
    pub required_out_bytes: u32,
}

#[inline]
pub fn wire_validate_frame(input: WireFrameInput) -> OrbWireStatus {
    let raw = unsafe {
        orb_wire_validate_frame(
            input.magic,
            input.abi_version,
            input.schema_id,
            input.expected_schema_id,
            input.total_len,
            input.payload_len,
            input.arena_off,
            input.arena_len,
            input.max_budget_bytes,
            input.out_cap,
            input.required_out_bytes,
        )
    };
    match raw {
        0 => OrbWireStatus::Ok,
        1 => OrbWireStatus::BadMagicOrVersion,
        2 => OrbWireStatus::UnsupportedSchema,
        4 => OrbWireStatus::BudgetExceeded,
        5 => OrbWireStatus::OutputTooSmall,
        _ => OrbWireStatus::TruncatedOrOutOfBounds,
    }
}

/// Canonical 64-bit `OrbWire` record word (`tag: u8`, `flags: u8`, `len16: u16`, `payload32: u32`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OrbWireRecordWord {
    pub tag: u8,
    pub flags: u8,
    pub len16: u16,
    pub payload32: u32,
}

#[inline]
pub fn wire_pack_record(rec: OrbWireRecordWord) -> u64 {
    unsafe { orb_wire_pack_record(rec.tag, rec.flags, u32::from(rec.len16), rec.payload32) }
}

#[inline]
pub const fn wire_unpack_record(word: u64) -> OrbWireRecordWord {
    OrbWireRecordWord {
        tag: (word & 0xFF) as u8,
        flags: ((word >> 8) & 0xFF) as u8,
        len16: ((word >> 16) & 0xFFFF) as u16,
        payload32: (word >> 32) as u32,
    }
}

#[inline]
pub fn wire_schema_migrate_step(
    from_schema: u32,
    to_schema: u32,
    current_schema: u32,
    payload_bytes: u64,
    max_bytes: u64,
) -> bool {
    unsafe {
        orb_wire_schema_migrate_step(
            from_schema,
            to_schema,
            current_schema,
            payload_bytes,
            max_bytes,
        ) == 1
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EffectKind {
    Observe = 0,
    LaunchJob = 1,
    ResumeSession = 2,
    DispatchProvider = 3,
    ExecPrivCommand = 4,
    MutateStore = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EffectAdmissibleInput {
    pub effect_kind: EffectKind,
    pub has_valid_lease: bool,
    pub session_created: bool,
    pub lineage_verified: bool,
    pub is_archived: bool,
    pub idempotency_fresh: bool,
    pub account_bound: bool,
    pub account_rejected: bool,
    pub first_byte_locked: bool,
    pub grammar_allowed: bool,
    pub env_scrubbed: bool,
    pub budget_ok: bool,
}

#[inline]
pub fn effect_admissible(input: EffectAdmissibleInput) -> bool {
    unsafe {
        orb_effect_admissible(
            input.effect_kind as u8,
            u8::from(input.has_valid_lease),
            u8::from(input.session_created),
            u8::from(input.lineage_verified),
            u8::from(input.is_archived),
            u8::from(input.idempotency_fresh),
            u8::from(input.account_bound),
            u8::from(input.account_rejected),
            u8::from(input.first_byte_locked),
            u8::from(input.grammar_allowed),
            u8::from(input.env_scrubbed),
            u8::from(input.budget_ok),
        ) == 1
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ProviderPoolAction {
    RejectCandidate = 0,
    DispatchBoundAccount = 1,
    DispatchPoolCandidate = 2,
    AbortLockedStream = 3,
    ExhaustedFailover = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderPoolStepInput {
    pub bound_account_id: Option<u32>,
    pub candidate_account_id: u32,
    pub is_rejected: bool,
    pub first_byte_sent: bool,
    pub is_failover_attempt: bool,
    pub attempts: u32,
    pub max_attempts: u32,
    pub now_epoch: u64,
    pub reset_epoch: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderPoolStepVerdict {
    pub action: ProviderPoolAction,
    pub emit_dispatch_effect: bool,
    pub first_byte_locked_next: bool,
    pub dispatched_account_id: u32,
}

#[inline]
pub fn provider_pool_step(input: ProviderPoolStepInput) -> ProviderPoolStepVerdict {
    let raw = unsafe {
        orb_provider_pool_step(
            u8::from(input.bound_account_id.is_some()),
            input.bound_account_id.unwrap_or(0),
            input.candidate_account_id,
            u8::from(input.is_rejected),
            u8::from(input.first_byte_sent),
            u8::from(input.is_failover_attempt),
            input.attempts,
            input.max_attempts,
            input.now_epoch,
            input.reset_epoch,
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => ProviderPoolAction::DispatchBoundAccount,
        2 => ProviderPoolAction::DispatchPoolCandidate,
        3 => ProviderPoolAction::AbortLockedStream,
        4 => ProviderPoolAction::ExhaustedFailover,
        _ => ProviderPoolAction::RejectCandidate,
    };
    ProviderPoolStepVerdict {
        action,
        emit_dispatch_effect: ((raw >> 8) & 1) != 0,
        first_byte_locked_next: ((raw >> 16) & 1) != 0,
        dispatched_account_id: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteCandidate {
    pub account_id: u32,
    pub score: u64,
    pub is_rejected: bool,
    pub reset_epoch: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteArgminVerdict {
    pub has_best: bool,
    pub took_candidate: bool,
    pub best_id: u32,
}

#[inline]
pub fn route_argmin_step(
    has_best: bool,
    best_id: u32,
    best_score: u64,
    cand_id: u32,
    cand_score: u64,
    cand_admissible: bool,
) -> RouteArgminVerdict {
    let raw = unsafe {
        orb_route_argmin_step(
            u8::from(has_best),
            best_id,
            best_score,
            cand_id,
            cand_score,
            u8::from(cand_admissible),
        )
    };
    RouteArgminVerdict {
        has_best: (raw & 1) != 0,
        took_candidate: ((raw >> 8) & 1) != 0,
        best_id: (raw >> 32) as u32,
    }
}

/// Pure `ArgminRouteFold` over a slice of candidate accounts backed by `orb_provider_pool_step`
/// and `orb_route_argmin_step`. Guarantees `antigravity_dispatch_matches_bound_account` and
/// `rejected_account_never_routed_before_reset`.
pub fn select_best_provider_account(
    bound_account_id: Option<u32>,
    first_byte_sent: bool,
    is_failover_attempt: bool,
    attempts: u32,
    max_attempts: u32,
    now_epoch: u64,
    candidates: &[RouteCandidate],
) -> Option<u32> {
    let mut has_best = false;
    let mut best_id = 0u32;
    let mut best_score = u64::MAX;

    for cand in candidates {
        let pool_verdict = provider_pool_step(ProviderPoolStepInput {
            bound_account_id,
            candidate_account_id: cand.account_id,
            is_rejected: cand.is_rejected,
            first_byte_sent,
            is_failover_attempt,
            attempts,
            max_attempts,
            now_epoch,
            reset_epoch: cand.reset_epoch,
        });
        let step = route_argmin_step(
            has_best,
            best_id,
            best_score,
            cand.account_id,
            cand.score,
            pool_verdict.emit_dispatch_effect,
        );
        if step.took_candidate {
            has_best = true;
            best_id = step.best_id;
            best_score = cand.score;
        }
    }
    if has_best {
        Some(best_id)
    } else {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MissionControlAction {
    RejectArchived = 0,
    DispatchFreshTurn = 1,
    ResumeVerifiedSession = 2,
    SeedFallbackFreshSession = 3,
    DedupeDeliveredMessage = 4,
    RejectTrackWriterConflict = 5,
    RejectUnverifiedResume = 6,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MissionControlStepInput {
    pub is_archived: bool,
    pub active_track_writers: u32,
    pub has_lease: bool,
    pub msg_already_delivered: bool,
    pub is_resume: bool,
    pub session_created: bool,
    pub lineage_verified: bool,
    pub rollout_exists: bool,
    pub has_fallback_prompt: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MissionControlStepVerdict {
    pub action: MissionControlAction,
    pub emit_dispatch_effect: bool,
    pub seed_fallback_session: bool,
    pub archived_next: bool,
    pub track_writers_next: u32,
}

#[inline]
pub fn mission_control_step(input: MissionControlStepInput) -> MissionControlStepVerdict {
    let raw = unsafe {
        orb_mission_control_step(
            u8::from(input.is_archived),
            input.active_track_writers,
            u8::from(input.has_lease),
            u8::from(input.msg_already_delivered),
            u8::from(input.is_resume),
            u8::from(input.session_created),
            u8::from(input.lineage_verified),
            u8::from(input.rollout_exists),
            u8::from(input.has_fallback_prompt),
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => MissionControlAction::DispatchFreshTurn,
        2 => MissionControlAction::ResumeVerifiedSession,
        3 => MissionControlAction::SeedFallbackFreshSession,
        4 => MissionControlAction::DedupeDeliveredMessage,
        5 => MissionControlAction::RejectTrackWriterConflict,
        6 => MissionControlAction::RejectUnverifiedResume,
        _ => MissionControlAction::RejectArchived,
    };
    MissionControlStepVerdict {
        action,
        emit_dispatch_effect: ((raw >> 8) & 1) != 0,
        seed_fallback_session: ((raw >> 9) & 1) != 0,
        archived_next: ((raw >> 16) & 1) != 0,
        track_writers_next: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ForkHomeAction {
    RejectForkWorkspace = 0,
    StandardJobWorkspace = 1,
    UseSiblingSourceCwdKeepJobHome = 2,
    UseTransferredRootCwdKeepJobHome = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ForkHomeStepInput {
    pub is_fork_or_side: bool,
    pub source_exists: bool,
    pub source_is_symlink: bool,
    pub same_workspace: bool,
    pub same_node: bool,
    pub has_committed_transfer: bool,
    pub requested_override_home: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ForkHomeStepVerdict {
    pub action: ForkHomeAction,
    pub admit_launch: bool,
    pub use_source_cwd: bool,
    pub override_home: bool,
    pub job_home_preserved: bool,
    pub exit_code: u32,
}

#[inline]
pub fn fork_home_step(input: ForkHomeStepInput) -> ForkHomeStepVerdict {
    let raw = unsafe {
        orb_fork_home_step(
            u8::from(input.is_fork_or_side),
            u8::from(input.source_exists),
            u8::from(input.source_is_symlink),
            u8::from(input.same_workspace),
            u8::from(input.same_node),
            u8::from(input.has_committed_transfer),
            u8::from(input.requested_override_home),
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => ForkHomeAction::StandardJobWorkspace,
        2 => ForkHomeAction::UseSiblingSourceCwdKeepJobHome,
        3 => ForkHomeAction::UseTransferredRootCwdKeepJobHome,
        _ => ForkHomeAction::RejectForkWorkspace,
    };
    ForkHomeStepVerdict {
        action,
        admit_launch: ((raw >> 8) & 1) != 0,
        use_source_cwd: ((raw >> 9) & 1) != 0,
        override_home: ((raw >> 16) & 1) != 0,
        job_home_preserved: ((raw >> 17) & 1) != 0,
        exit_code: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PrivdGrantScope {
    OpsRead = 0,
    ServiceDeploy = 1,
    RootExec = 2,
}

impl From<u8> for PrivdGrantScope {
    #[inline]
    fn from(raw: u8) -> Self {
        match raw {
            0 => Self::OpsRead,
            1 => Self::ServiceDeploy,
            _ => Self::RootExec,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PrivdCommandClass {
    UnknownOrForbidden = 0,
    OpsReadSafe = 1,
    ServiceDeployUnit = 2,
    ServiceDeployReload = 3,
    RootExecCommand = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PrivdCommandAction {
    Reject = 0,
    AdmitOpsRead = 1,
    AdmitServiceDeploy = 2,
    AdmitRootExec = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrivdCommandStepInput {
    pub lease_valid: bool,
    pub grant_scope: PrivdGrantScope,
    pub command_class: PrivdCommandClass,
    pub unit_matches_allowed: bool,
    pub has_shell_metachar_or_flag_bypass: bool,
    pub has_path_traversal_or_symlink: bool,
    pub has_unsafe_env_var: bool,
    pub require_force_cmd: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrivdCommandStepVerdict {
    pub action: PrivdCommandAction,
    pub allow_exec: bool,
    pub scrub_env: bool,
    pub audit_required: bool,
    pub exit_code: u32,
    pub exit_code_on_reject: u32,
}

pub type PrivdCommandVerdict = PrivdCommandStepVerdict;

#[inline]
pub fn privd_command_step(input: PrivdCommandStepInput) -> PrivdCommandStepVerdict {
    let raw = unsafe {
        orb_privd_command_step(
            u8::from(input.lease_valid),
            input.grant_scope as u8,
            input.command_class as u8,
            u8::from(input.unit_matches_allowed),
            u8::from(input.has_shell_metachar_or_flag_bypass),
            u8::from(input.has_path_traversal_or_symlink),
            u8::from(input.has_unsafe_env_var),
            u8::from(input.require_force_cmd),
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => PrivdCommandAction::AdmitOpsRead,
        2 => PrivdCommandAction::AdmitServiceDeploy,
        3 => PrivdCommandAction::AdmitRootExec,
        _ => PrivdCommandAction::Reject,
    };
    let exit_code = (raw >> 32) as u32;
    PrivdCommandStepVerdict {
        action,
        allow_exec: ((raw >> 8) & 1) != 0,
        scrub_env: ((raw >> 9) & 1) != 0,
        audit_required: ((raw >> 10) & 1) != 0,
        exit_code,
        exit_code_on_reject: exit_code,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SshIdentityAction {
    Reject = 0,
    AdmitCodingOnlyIdentity = 1,
    AdmitFleetIdentity = 2,
}

impl SshIdentityAction {
    #[allow(non_upper_case_globals)]
    pub const RejectSshOrCodexConfig: Self = Self::Reject;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SshIdentityStepInput {
    pub is_worker_or_container_target: bool,
    pub bundle_has_control_plane_key: bool,
    pub parent_dir_is_symlink: bool,
    pub pub_key_is_ed25519_without_private: bool,
    pub proxy_jump_valid: bool,
    pub codex_cyber_program_valid: bool,
    pub codex_goal_budget_exhausted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SshIdentityStepVerdict {
    pub action: SshIdentityAction,
    pub admit: bool,
    pub strip_control_plane_secrets: bool,
    pub no_secret_leak: bool,
    pub exit_code: u32,
    pub exit_code_on_reject: u32,
}

pub type SshIdentityVerdict = SshIdentityStepVerdict;

#[inline]
pub fn ssh_identity_step(input: SshIdentityStepInput) -> SshIdentityStepVerdict {
    let raw = unsafe {
        orb_ssh_identity_step(
            u8::from(input.is_worker_or_container_target),
            u8::from(input.bundle_has_control_plane_key),
            u8::from(input.parent_dir_is_symlink),
            u8::from(input.pub_key_is_ed25519_without_private),
            u8::from(input.proxy_jump_valid),
            u8::from(input.codex_cyber_program_valid),
            u8::from(input.codex_goal_budget_exhausted),
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => SshIdentityAction::AdmitCodingOnlyIdentity,
        2 => SshIdentityAction::AdmitFleetIdentity,
        _ => SshIdentityAction::Reject,
    };
    let exit_code = (raw >> 32) as u32;
    SshIdentityStepVerdict {
        action,
        admit: ((raw >> 8) & 1) != 0,
        strip_control_plane_secrets: ((raw >> 9) & 1) != 0,
        no_secret_leak: ((raw >> 10) & 1) != 0,
        exit_code,
        exit_code_on_reject: exit_code,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum AgentHarnessKind {
    Codex = 0,
    ClaudeCode = 1,
    Antigravity = 2,
    OpenCode = 3,
    Grok = 4,
    Vibe = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RawAgentEventKind {
    DiagnosticLine = 0,
    SessionIdUpdate = 1,
    ThinkingUpdate = 2,
    AssistantText = 3,
    ToolCall = 4,
    GoalProgress = 5,
    TurnCompleted = 6,
    ErrorOrAuth = 7,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum AgentEventNormalizeAction {
    RejectOverBudget = 0,
    SkipDuplicateOrEmpty = 1,
    EmitDiagnostic = 2,
    EmitSessionId = 3,
    EmitThinking = 4,
    EmitAssistantText = 5,
    EmitToolCompleted = 6,
    EmitToolRunning = 7,
    EmitGoalProgress = 8,
    EmitTurnCompleted = 9,
    EmitErrorOrAuth = 10,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AgentEventNormalizeStepInput {
    pub harness_kind: AgentHarnessKind,
    pub raw_event_kind: RawAgentEventKind,
    pub is_completed: bool,
    pub has_non_empty_text: bool,
    pub session_matches_expected: bool,
    pub is_duplicate_turn_or_tool: bool,
    pub payload_bytes: u32,
    pub max_payload_bytes: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AgentEventNormalizeStepVerdict {
    pub action: AgentEventNormalizeAction,
    pub emit_event: bool,
    pub thinking_open_next: bool,
    pub close_thinking: bool,
    pub total_transducer: bool,
    pub bounded_bytes: u32,
}

#[inline]
pub fn agent_event_normalize_step(
    input: AgentEventNormalizeStepInput,
) -> AgentEventNormalizeStepVerdict {
    let raw = unsafe {
        orb_agent_event_normalize_step(
            input.harness_kind as u8,
            input.raw_event_kind as u8,
            u8::from(input.is_completed),
            u8::from(input.has_non_empty_text),
            u32::from(input.session_matches_expected),
            u32::from(input.is_duplicate_turn_or_tool),
            input.payload_bytes,
            input.max_payload_bytes,
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => AgentEventNormalizeAction::SkipDuplicateOrEmpty,
        2 => AgentEventNormalizeAction::EmitDiagnostic,
        3 => AgentEventNormalizeAction::EmitSessionId,
        4 => AgentEventNormalizeAction::EmitThinking,
        5 => AgentEventNormalizeAction::EmitAssistantText,
        6 => AgentEventNormalizeAction::EmitToolCompleted,
        7 => AgentEventNormalizeAction::EmitToolRunning,
        8 => AgentEventNormalizeAction::EmitGoalProgress,
        9 => AgentEventNormalizeAction::EmitTurnCompleted,
        10 => AgentEventNormalizeAction::EmitErrorOrAuth,
        _ => AgentEventNormalizeAction::RejectOverBudget,
    };
    AgentEventNormalizeStepVerdict {
        action,
        emit_event: ((raw >> 8) & 1) != 0,
        thinking_open_next: ((raw >> 9) & 1) != 0,
        close_thinking: ((raw >> 10) & 1) != 0,
        total_transducer: ((raw >> 11) & 1) != 0,
        bounded_bytes: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TranscriptReduceAction {
    DedupeOrSkip = 0,
    AppendOrUpdateThinking = 1,
    AppendTranscriptEntry = 2,
    UpdateMetadata = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptReduceStepInput {
    pub last_applied_seq: u64,
    pub incoming_seq: u64,
    pub thinking_open: bool,
    pub normalized_action: AgentEventNormalizeAction,
    pub is_replay_from_log: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptReduceStepVerdict {
    pub action: TranscriptReduceAction,
    pub emit_entry: bool,
    pub thinking_open_next: bool,
    pub closed_previous_thinking: bool,
    pub next_applied_seq_lo32: u32,
}

#[inline]
pub fn transcript_reduce_step(input: TranscriptReduceStepInput) -> TranscriptReduceStepVerdict {
    let raw = unsafe {
        orb_transcript_reduce_step(
            input.last_applied_seq,
            input.incoming_seq,
            u8::from(input.thinking_open),
            input.normalized_action as u8,
            u8::from(input.is_replay_from_log),
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => TranscriptReduceAction::AppendOrUpdateThinking,
        2 => TranscriptReduceAction::AppendTranscriptEntry,
        3 => TranscriptReduceAction::UpdateMetadata,
        _ => TranscriptReduceAction::DedupeOrSkip,
    };
    TranscriptReduceStepVerdict {
        action,
        emit_entry: ((raw >> 8) & 1) != 0,
        thinking_open_next: ((raw >> 9) & 1) != 0,
        closed_previous_thinking: ((raw >> 10) & 1) != 0,
        next_applied_seq_lo32: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CursorPageAction {
    RejectInvalidWindow = 0,
    IncludeItem = 1,
    ExcludeOutOfWindow = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorPageStepInput {
    pub since_seq: Option<u64>,
    pub before_seq: Option<u64>,
    pub item_seq: u64,
    pub is_partial_response: bool,
    pub existing_count: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorPageStepVerdict {
    pub action: CursorPageAction,
    pub include_item: bool,
    pub preserve_existing: bool,
    pub partial_safe: bool,
    pub next_count: u32,
}

#[inline]
pub fn cursor_page_step(input: CursorPageStepInput) -> CursorPageStepVerdict {
    let raw = unsafe {
        orb_cursor_page_step(
            input.since_seq.unwrap_or(0),
            input.before_seq.unwrap_or(0),
            input.item_seq,
            u32::from(input.since_seq.is_some()),
            u32::from(input.before_seq.is_some()),
            u32::from(input.is_partial_response),
            input.existing_count,
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => CursorPageAction::IncludeItem,
        2 => CursorPageAction::ExcludeOutOfWindow,
        _ => CursorPageAction::RejectInvalidWindow,
    };
    CursorPageStepVerdict {
        action,
        include_item: ((raw >> 8) & 1) != 0,
        preserve_existing: ((raw >> 9) & 1) != 0,
        partial_safe: ((raw >> 10) & 1) != 0,
        next_count: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SidebarMergeAction {
    SkipArchivedOrSuperseded = 0,
    UpdateExistingInPlace = 1,
    RetainExistingNewer = 2,
    InsertNewUnique = 3,
    RemoveSuperseded = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SidebarMergeStepInput {
    pub existing_id_ord: u32,
    pub incoming_id_ord: u32,
    pub existing_updated_at_ms: u64,
    pub incoming_updated_at_ms: u64,
    pub incoming_superseded_or_archived: bool,
    pub is_partial_page: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SidebarMergeStepVerdict {
    pub action: SidebarMergeAction,
    pub retain_or_upsert: bool,
    pub insert_new: bool,
    pub unique_sidebar: bool,
    pub preserve_unmentioned: bool,
    pub net_new_rows: u32,
}

#[inline]
pub fn sidebar_merge_step(input: SidebarMergeStepInput) -> SidebarMergeStepVerdict {
    let raw = unsafe {
        orb_sidebar_merge_step(
            input.existing_id_ord,
            input.incoming_id_ord,
            input.existing_updated_at_ms,
            input.incoming_updated_at_ms,
            u8::from(input.incoming_superseded_or_archived),
            u8::from(input.is_partial_page),
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => SidebarMergeAction::UpdateExistingInPlace,
        2 => SidebarMergeAction::RetainExistingNewer,
        3 => SidebarMergeAction::InsertNewUnique,
        4 => SidebarMergeAction::RemoveSuperseded,
        _ => SidebarMergeAction::SkipArchivedOrSuperseded,
    };
    SidebarMergeStepVerdict {
        action,
        retain_or_upsert: ((raw >> 8) & 1) != 0,
        insert_new: ((raw >> 9) & 1) != 0,
        unique_sidebar: ((raw >> 10) & 1) != 0,
        preserve_unmentioned: ((raw >> 11) & 1) != 0,
        net_new_rows: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ScrollEpochAction {
    KeepCurrentScroll = 0,
    ApplyEpochCorrection = 1,
    SuppressDuplicateEpochCorrection = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScrollEpochStepInput {
    pub layout_epoch: u32,
    pub last_corrected_epoch: u32,
    pub corrections_in_epoch: u8,
    pub is_pinned_to_bottom: bool,
    pub user_is_dragging: bool,
    pub target_scroll_top_px: u32,
    pub current_scroll_top_px: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScrollEpochStepVerdict {
    pub action: ScrollEpochAction,
    pub apply_scroll: bool,
    pub epoch_fence_set: bool,
    pub effective_scroll_top_px: u32,
}

#[inline]
pub fn scroll_epoch_step(input: ScrollEpochStepInput) -> ScrollEpochStepVerdict {
    let raw = unsafe {
        orb_scroll_epoch_step(
            input.layout_epoch,
            input.last_corrected_epoch,
            input.corrections_in_epoch,
            u8::from(input.is_pinned_to_bottom),
            u8::from(input.user_is_dragging),
            input.target_scroll_top_px,
            input.current_scroll_top_px,
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => ScrollEpochAction::ApplyEpochCorrection,
        2 => ScrollEpochAction::SuppressDuplicateEpochCorrection,
        _ => ScrollEpochAction::KeepCurrentScroll,
    };
    ScrollEpochStepVerdict {
        action,
        apply_scroll: ((raw >> 8) & 1) != 0,
        epoch_fence_set: ((raw >> 10) & 1) != 0,
        effective_scroll_top_px: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ClientProjectionTarget {
    Core = 0,
    Ios = 1,
    Android = 2,
    DesktopWasm32 = 3,
}

#[inline]
pub fn client_parity_step(
    target: ClientProjectionTarget,
    wire_schema_id: u32,
    transcript_seq: u32,
    markdown_blocks_count: u32,
    send_queue_depth: u32,
    scroll_corrected_in_epoch: bool,
) -> u64 {
    unsafe {
        orb_client_parity_step(
            target as u8,
            wire_schema_id,
            transcript_seq,
            markdown_blocks_count,
            send_queue_depth,
            u8::from(scroll_corrected_in_epoch),
        )
    }
}

/// Snapshot of a subsystem's bounded shadow divergence counter (`ShadowDivergenceRing<256>`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShadowSnapshot {
    pub subsystem: &'static str,
    pub total_events: u64,
    pub total_divergences: u64,
    pub recent_divergences: usize,
}

/// Thread-safe bounded shadow counter backed by [`shadow::ShadowDivergenceRing<256>`] and
/// [`shadow::RefinementSimulation::observe_step`].
pub struct ShadowCounter {
    ring: std::sync::Mutex<shadow::ShadowDivergenceRing<256>>,
}

impl Default for ShadowCounter {
    fn default() -> Self {
        Self::new()
    }
}

impl ShadowCounter {
    pub fn new() -> Self {
        Self {
            ring: std::sync::Mutex::new(shadow::ShadowDivergenceRing::<256>::new()),
        }
    }

    pub fn snapshot(&self, subsystem: &'static str) -> ShadowSnapshot {
        let ring = self
            .ring
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        ShadowSnapshot {
            subsystem,
            total_events: ring.total_events,
            total_divergences: ring.unexpected_divergences,
            recent_divergences: ring.entries().len(),
        }
    }
}

/// Observe `privd_command_step` (`orb_privd_command_step`) against the host admission decision.
pub fn observe_privd_command_shadow(
    input: PrivdCommandStepInput,
    host_allow_exec: bool,
    counter: &ShadowCounter,
) -> PrivdCommandStepVerdict {
    let verdict = privd_command_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, PrivdCommandStepInput, u8, u8> {
        subsystem: "orb_privd_command_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = privd_command_step(*ev);
            let effs = if v.allow_exec {
                vec![v.action as u8]
            } else {
                vec![0u8]
            };
            (v.allow_exec, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_allow_exec {
        vec![verdict.action as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: u64::from(input.grant_scope as u8),
        idempotency_key: u64::from(input.command_class as u8),
        boot_id_matches: true,
        schema_id: 5,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &input.lease_valid,
            &host_allow_exec,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

/// Observe `ssh_identity_step` (`orb_ssh_identity_step`) against the host admission decision.
pub fn observe_ssh_identity_shadow(
    input: SshIdentityStepInput,
    host_admits: bool,
    counter: &ShadowCounter,
) -> SshIdentityStepVerdict {
    let verdict = ssh_identity_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, SshIdentityStepInput, u8, u8> {
        subsystem: "orb_ssh_identity_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = ssh_identity_step(*ev);
            let effs = if v.admit {
                vec![v.action as u8]
            } else {
                vec![0u8]
            };
            (v.admit, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_admits {
        vec![verdict.action as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: u64::from(input.is_worker_or_container_target),
        idempotency_key: u64::from(input.bundle_has_control_plane_key),
        boot_id_matches: true,
        schema_id: 5,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &input.is_worker_or_container_target,
            &host_admits,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

/// Observe `agent_event_normalize_step` (`orb_agent_event_normalize_step`) against the host transducer.
pub fn observe_agent_event_normalize_shadow(
    input: AgentEventNormalizeStepInput,
    host_emits: bool,
    counter: &ShadowCounter,
) -> AgentEventNormalizeStepVerdict {
    let verdict = agent_event_normalize_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, AgentEventNormalizeStepInput, u8, u8> {
        subsystem: "orb_agent_event_normalize_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = agent_event_normalize_step(*ev);
            let effs = if v.emit_event {
                vec![v.action as u8]
            } else {
                vec![0u8]
            };
            (v.emit_event, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_emits {
        vec![verdict.action as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: u64::from(input.harness_kind as u8),
        idempotency_key: u64::from(input.raw_event_kind as u8),
        boot_id_matches: true,
        schema_id: 3,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &input.is_completed,
            &host_emits,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

/// Observe `transcript_reduce_step` (`orb_transcript_reduce_step`) against the host reducer.
pub fn observe_transcript_reduce_shadow(
    input: TranscriptReduceStepInput,
    host_emits: bool,
    counter: &ShadowCounter,
) -> TranscriptReduceStepVerdict {
    let verdict = transcript_reduce_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, TranscriptReduceStepInput, u8, u8> {
        subsystem: "orb_transcript_reduce_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = transcript_reduce_step(*ev);
            let effs = if v.emit_entry {
                vec![v.action as u8]
            } else {
                vec![0u8]
            };
            (v.emit_entry, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_emits {
        vec![verdict.action as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: input.last_applied_seq,
        idempotency_key: input.incoming_seq,
        boot_id_matches: true,
        schema_id: 3,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &input.thinking_open,
            &host_emits,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

/// Observe `cursor_page_step` (`orb_cursor_page_step`) against the host pagination filter.
pub fn observe_cursor_page_shadow(
    input: CursorPageStepInput,
    host_includes: bool,
    counter: &ShadowCounter,
) -> CursorPageStepVerdict {
    let verdict = cursor_page_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, CursorPageStepInput, u8, u8> {
        subsystem: "orb_cursor_page_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = cursor_page_step(*ev);
            let effs = if v.include_item {
                vec![v.action as u8]
            } else {
                vec![0u8]
            };
            (v.include_item, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_includes {
        vec![verdict.action as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: input.item_seq,
        idempotency_key: u64::from(input.existing_count),
        boot_id_matches: true,
        schema_id: 4,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &input.is_partial_response,
            &host_includes,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

/// Observe `sidebar_merge_step` (`orb_sidebar_merge_step`) against the host sidebar reconciliation.
pub fn observe_sidebar_merge_shadow(
    input: SidebarMergeStepInput,
    host_retains_or_upserts: bool,
    counter: &ShadowCounter,
) -> SidebarMergeStepVerdict {
    let verdict = sidebar_merge_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, SidebarMergeStepInput, u8, u8> {
        subsystem: "orb_sidebar_merge_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = sidebar_merge_step(*ev);
            let effs = if v.retain_or_upsert {
                vec![v.action as u8]
            } else {
                vec![0u8]
            };
            (v.retain_or_upsert, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_retains_or_upserts {
        vec![verdict.action as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: input.incoming_updated_at_ms,
        fresh_nonce: u64::from(input.existing_id_ord),
        idempotency_key: u64::from(input.incoming_id_ord),
        boot_id_matches: true,
        schema_id: 4,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &input.is_partial_page,
            &host_retains_or_upserts,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

/// Observe `scroll_epoch_step` (`orb_scroll_epoch_step`) against the host scroll correction policy.
pub fn observe_scroll_epoch_shadow(
    input: ScrollEpochStepInput,
    host_applies_correction: bool,
    counter: &ShadowCounter,
) -> ScrollEpochStepVerdict {
    let verdict = scroll_epoch_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, ScrollEpochStepInput, u8, u8> {
        subsystem: "orb_scroll_epoch_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = scroll_epoch_step(*ev);
            let effs = if v.apply_scroll {
                vec![v.action as u8]
            } else {
                vec![0u8]
            };
            (v.apply_scroll, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_applies_correction {
        vec![verdict.action as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: u64::from(input.layout_epoch),
        idempotency_key: u64::from(input.last_corrected_epoch),
        boot_id_matches: true,
        schema_id: 6,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &input.is_pinned_to_bottom,
            &host_applies_correction,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClientParityStepInput {
    pub client_target: ClientProjectionTarget,
    pub wire_schema_id: u32,
    pub transcript_seq: u32,
    pub markdown_blocks_count: u32,
    pub send_queue_depth: u32,
    pub scroll_corrected_in_epoch: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClientParityStepVerdict {
    pub raw: u64,
    pub parity_admitted: bool,
    pub digest32: u32,
}

/// Observe `client_parity_step` (`orb_client_parity_step`) against the host cross-client parity check.
pub fn observe_client_parity_shadow(
    input: ClientParityStepInput,
    host_admits_parity: bool,
    counter: &ShadowCounter,
) -> ClientParityStepVerdict {
    let raw = client_parity_step(
        input.client_target,
        input.wire_schema_id,
        input.transcript_seq,
        input.markdown_blocks_count,
        input.send_queue_depth,
        input.scroll_corrected_in_epoch,
    );
    let verdict = ClientParityStepVerdict {
        raw,
        parity_admitted: ((raw >> 8) & 1) != 0,
        digest32: (raw >> 32) as u32,
    };
    let sim = shadow::RefinementSimulation::<bool, bool, ClientParityStepInput, u8, u8> {
        subsystem: "orb_client_parity_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let r = client_parity_step(
                ev.client_target,
                ev.wire_schema_id,
                ev.transcript_seq,
                ev.markdown_blocks_count,
                ev.send_queue_depth,
                ev.scroll_corrected_in_epoch,
            );
            let admitted = ((r >> 8) & 1) != 0;
            let effs = if admitted {
                vec![(r & 0xFF) as u8]
            } else {
                vec![0u8]
            };
            (admitted, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_admits_parity {
        vec![(raw & 0xFF) as u8]
    } else {
        vec![0u8]
    };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: u64::from(input.transcript_seq),
        idempotency_key: u64::from(input.wire_schema_id),
        boot_id_matches: true,
        schema_id: 6,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &true,
            &host_admits_parity,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

// ═══════════════════════════════════════════════════════════════════════════
// Wave 10: Fleet Security — Canary Blast-Radius Isolation, Process Whitelist,
//          High-Signal Attacker Bait, Enforcer Convergence & Biometric/Mesh Gates
// ═══════════════════════════════════════════════════════════════════════════

/// Classification of a canary tripwire sensor (`Orb.Kernel.canaryTripwireStep`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CanaryClass {
    /// Ambient filesystem or socket decoy (`.env.production.canary`, `.vault-recovery.age`, `mongo_27017`).
    AmbientDecoy = 0,
    /// High-signal attacker-only bait (e.g., fake Bitcoin WIF / BIP-39 wallet seed `btc_wallet_canary`
    /// or `ssh_exfil_canary`) that legitimate agents never touch; a hit even from an agent process
    /// implies process or inference compromise and escalates to fleet `HardLockdown`.
    HighSignalBait = 1,
}

/// Classification of the process that triggered a canary (`Orb.Kernel.canaryTripwireStep`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ActorTrust {
    /// Known agent/mission process performing a routine file/directory walk (`rg`, `fd`, `find`, `ls`, `git`).
    WhitelistedAgentWalk = 0,
    /// Mission job process directly reading or probing an ambient decoy.
    MissionProcess = 1,
    /// Non-agent, unknown, root, or external process.
    UntrustedOrSystem = 2,
}

/// Blast-radius action returned by [`canary_tripwire_step`] (`Orb.Kernel.canaryTripwireStep`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CanaryTripwireAction {
    /// Whitelisted agent walk or synthetic `--dry-run`: do not quarantine node or lock down fleet.
    IgnoreWhitelisted = 0,
    /// Single mission process reading an ambient decoy: quarantine ONLY the reporting node;
    /// keep global fleet `bunker_state` unchanged (`Normal`).
    QuarantineNodeOnly = 1,
    /// High-signal attacker bait (even from our own agent process) or untrusted system process:
    /// quarantine node AND escalate global fleet `bunker_state` to `HardLockdown (2)`.
    EscalateFleetLockdown = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CanaryTripwireStepInput {
    pub canary_class: CanaryClass,
    pub actor_trust: ActorTrust,
    pub is_dry_run: bool,
    pub current_fleet_bunker: BunkerState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CanaryTripwireStepVerdict {
    pub action: CanaryTripwireAction,
    pub quarantine_reporting_node: bool,
    pub escalate_fleet_lockdown: bool,
    pub alert_operator: bool,
    pub next_fleet_bunker: BunkerState,
    pub raw: u64,
}

/// Pure implementation of `Orb.Kernel.canaryTripwireStep` verified by
/// `canary_whitelisted_ambient_no_bunker`, `canary_mission_ambient_node_only`, and
/// `canary_high_signal_bait_always_locks_down` in `lean/Orb/Spec.lean`.
#[inline]
pub fn canary_tripwire_step(input: CanaryTripwireStepInput) -> CanaryTripwireStepVerdict {
    let clamped_bunker = (input.current_fleet_bunker as u8).min(2);
    let is_high_signal = (input.canary_class as u8) >= 1;
    let action_code: u8 = if input.is_dry_run {
        0
    } else if is_high_signal {
        2
    } else if input.actor_trust == ActorTrust::WhitelistedAgentWalk {
        0
    } else if input.actor_trust == ActorTrust::MissionProcess {
        1
    } else {
        2
    };
    let next_bunker_code: u8 = if action_code == 2 { 2 } else { clamped_bunker };
    let quarantine_bit: u32 = if action_code >= 1 { 256 } else { 0 };
    let lockdown_bit: u32 = if action_code == 2 { 512 } else { 0 };
    let alert_bit: u32 = if action_code >= 1 || input.is_dry_run {
        1024
    } else {
        0
    };
    let lo32 = u32::from(action_code) | quarantine_bit | lockdown_bit | alert_bit;
    let hi32 = u32::from(next_bunker_code);
    let raw = u64::from(lo32) | (u64::from(hi32) << 32);
    let action = match action_code {
        1 => CanaryTripwireAction::QuarantineNodeOnly,
        2 => CanaryTripwireAction::EscalateFleetLockdown,
        _ => CanaryTripwireAction::IgnoreWhitelisted,
    };
    let next_fleet_bunker = match next_bunker_code {
        0 => BunkerState::Normal,
        1 => BunkerState::SoftQuarantine,
        _ => BunkerState::HardLockdown,
    };
    CanaryTripwireStepVerdict {
        action,
        quarantine_reporting_node: (lo32 & 256) != 0,
        escalate_fleet_lockdown: (lo32 & 512) != 0,
        alert_operator: (lo32 & 1024) != 0,
        next_fleet_bunker,
        raw,
    }
}

/// Classifies a `canary_kind` identifier into [`CanaryClass::AmbientDecoy`] vs
/// [`CanaryClass::HighSignalBait`].
pub fn classify_canary_class(canary_kind: &str) -> CanaryClass {
    let k = canary_kind.trim().to_ascii_lowercase();
    if k.contains("btc")
        || k.contains("bitcoin")
        || k.contains("wallet")
        || k.contains("mnemonic")
        || k.contains("seed")
        || k.contains("ssh_exfil")
        || k.contains("high_signal")
        || k.contains("attacker_bait")
    {
        CanaryClass::HighSignalBait
    } else {
        CanaryClass::AmbientDecoy
    }
}

/// Whitelisted agent file-search / directory-traversal binaries that may walk workspace trees
/// during normal coding missions without intending to exfiltrate ambient decoys.
pub const WHITELISTED_AGENT_WALK_BINARIES: &[&str] = &[
    "rg", "ripgrep", "grep", "egrep", "fgrep", "find", "fd", "fdfind", "ls", "stat", "file", "du",
    "tree", "git",
];

/// Numeric uid of the `sandboxed-node` service user that runs agent and mission processes.
pub const AGENT_UID: u32 = 999;

/// Whether a cgroup v2 path (`/proc/<pid>/cgroup`, either the raw `0::<path>` line or the
/// bare path) is exactly a managed agent context: the node service itself
/// (`orb-node.service`, alias `sandboxed-node.service`) or one mission scope directly under
/// `missions.slice`. Substring matches are not accepted.
pub fn is_agent_cgroup(cgroup: &str) -> bool {
    let path = cgroup
        .lines()
        .find_map(|line| line.trim().strip_prefix("0::"))
        .unwrap_or(cgroup)
        .trim();
    matches!(
        path,
        "/system.slice/orb-node.service" | "/system.slice/sandboxed-node.service"
    ) || path.strip_prefix("/missions.slice/").is_some_and(|unit| {
        unit.ends_with(".scope") && unit.len() > ".scope".len() && !unit.contains('/')
    })
}

/// Classifies the process that tripped a canary into [`ActorTrust`] from kernel-attested
/// facts only:
/// - The audit record's numeric `uid` must be [`AGENT_UID`]; an unknown uid is untrusted.
/// - When the cgroup could be read, it must be exactly an agent cgroup ([`is_agent_cgroup`]);
///   a process that already exited (no cgroup) is judged by its uid alone.
/// - The first `cmdline` token is the audit record's `exe` (the watcher substitutes it for the
///   attacker-controlled `argv[0]`). A passive search/traversal tool in
///   [`WHITELISTED_AGENT_WALK_BINARIES`] is [`ActorTrust::WhitelistedAgentWalk`]; anything else
///   is [`ActorTrust::MissionProcess`].
/// - Everything else is [`ActorTrust::UntrustedOrSystem`]. Argument text never grants trust.
pub fn classify_actor_trust(
    uid: Option<u32>,
    cgroup: Option<&str>,
    cmdline: Option<&str>,
) -> ActorTrust {
    let cgroup = cgroup.map(str::trim).filter(|cg| !cg.is_empty());
    if uid != Some(AGENT_UID) || cgroup.is_some_and(|cg| !is_agent_cgroup(cg)) {
        return ActorTrust::UntrustedOrSystem;
    }

    let cmd = cmdline.unwrap_or("").trim();
    let first_token = cmd.split_whitespace().next().unwrap_or("");
    let exe_name = first_token
        .rsplit('/')
        .next()
        .unwrap_or(first_token)
        .to_ascii_lowercase();

    if WHITELISTED_AGENT_WALK_BINARIES.contains(&exe_name.as_str()) {
        ActorTrust::WhitelistedAgentWalk
    } else {
        ActorTrust::MissionProcess
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum BunkerEnforcerAction {
    ReleaseQuarantine = 0,
    ApplyOrKeepQuarantine = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BunkerEnforcerStepInput {
    pub status_reachable: bool,
    pub fleet_bunker: u8,
    pub node_quarantined_by_core: bool,
    pub has_local_trip_marker: bool,
    pub local_trip_epoch: u64,
    pub last_unbunker_epoch: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BunkerEnforcerStepVerdict {
    pub action: BunkerEnforcerAction,
    pub apply_or_keep_quarantine: bool,
    pub clear_local_marker: bool,
    pub raw: u32,
}

/// Pure implementation of `Orb.Kernel.bunkerEnforcerStep` verified by
/// `bunker_enforcer_converges_on_unbunker` in `lean/Orb/Spec.lean`.
#[inline]
pub fn bunker_enforcer_step(input: BunkerEnforcerStepInput) -> BunkerEnforcerStepVerdict {
    let fleet_lockdown = input.fleet_bunker >= 2;
    let marker_cleared =
        !input.has_local_trip_marker || input.last_unbunker_epoch >= input.local_trip_epoch;
    let raw: u32 = if !input.status_reachable {
        if input.has_local_trip_marker {
            257
        } else {
            0
        }
    } else if fleet_lockdown || input.node_quarantined_by_core || !marker_cleared {
        257
    } else if input.has_local_trip_marker {
        512
    } else {
        0
    };
    let apply_or_keep = (raw & 256) != 0;
    BunkerEnforcerStepVerdict {
        action: if apply_or_keep {
            BunkerEnforcerAction::ApplyOrKeepQuarantine
        } else {
            BunkerEnforcerAction::ReleaseQuarantine
        },
        apply_or_keep_quarantine: apply_or_keep,
        clear_local_marker: (raw & 512) != 0,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BiometricGateVerdict {
    pub admitted: bool,
    pub surface_error: bool,
    pub raw: u32,
}

/// Pure implementation of `Orb.Kernel.biometricGateStep` verified by
/// `biometric_gate_never_fails_open` in `lean/Orb/Spec.lean`.
#[inline]
pub fn biometric_gate_step(
    surface_requires_bio: bool,
    hardware_enrolled: bool,
    eval_succeeded: bool,
    passcode_fallback_succeeded: bool,
) -> BiometricGateVerdict {
    let raw: u32 = if !surface_requires_bio
        || (hardware_enrolled && eval_succeeded)
        || (!hardware_enrolled && passcode_fallback_succeeded)
    {
        257
    } else {
        512
    };
    BiometricGateVerdict {
        admitted: (raw & 256) != 0,
        surface_error: (raw & 512) != 0,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshServiceRouteVerdict {
    pub admitted: bool,
    pub rejected_retired_tailnet: bool,
    pub raw: u32,
}

/// Pure implementation of `Orb.Kernel.meshServiceRouteStep` verified by
/// `mesh_service_route_rejects_retired_tailnet` in `lean/Orb/Spec.lean`.
#[inline]
pub fn mesh_service_route_step(
    endpoint_in_mesh_overlay: bool,
    endpoint_in_retired_tailnet: bool,
    has_mesh_auth_or_bearer: bool,
    is_loopback: bool,
) -> MeshServiceRouteVerdict {
    let raw: u32 = if endpoint_in_retired_tailnet {
        512
    } else if is_loopback || endpoint_in_mesh_overlay || has_mesh_auth_or_bearer {
        257
    } else {
        512
    };
    MeshServiceRouteVerdict {
        admitted: (raw & 256) != 0,
        rejected_retired_tailnet: endpoint_in_retired_tailnet,
        raw,
    }
}

#[cfg(test)]
mod privilege_bunker_deploy_tests {
    use super::*;

    #[test]
    fn privilege_step_enforces_biometric_session_clock_and_bunker_fence() {
        let base = PrivilegeStepInput {
            same_owner: true,
            mission_active: true,
            biometric_signed: true,
            requested_scope: PrivilegeScopeRank::RootExec,
            max_granted_scope: PrivilegeScopeRank::RootExec,
            bunker_state: BunkerState::Normal,
            revoked: false,
            now_epoch: 1_000,
            grant_expires_at: 2_000,
            session_expires_at: 1_500,
        };
        assert_eq!(
            privilege_step(base),
            PrivilegeStepVerdict {
                allow_exec: true,
                require_force_cmd: false,
                reap_grant: false,
            }
        );
        // Scoped service_deploy sets require_force_cmd = true
        assert_eq!(
            privilege_step(PrivilegeStepInput {
                requested_scope: PrivilegeScopeRank::ServiceDeploy,
                max_granted_scope: PrivilegeScopeRank::ServiceDeploy,
                ..base
            }),
            PrivilegeStepVerdict {
                allow_exec: true,
                require_force_cmd: true,
                reap_grant: false,
            }
        );
        // Session clock bounds grant clock (now = 1_500 == session_expires_at < grant_expires_at)
        assert_eq!(
            privilege_step(PrivilegeStepInput {
                now_epoch: 1_500,
                ..base
            }),
            PrivilegeStepVerdict {
                allow_exec: false,
                require_force_cmd: false,
                reap_grant: true,
            }
        );
        // Bunker state blocks execution and reaps grant
        assert_eq!(
            privilege_step(PrivilegeStepInput {
                bunker_state: BunkerState::SoftQuarantine,
                ..base
            }),
            PrivilegeStepVerdict {
                allow_exec: false,
                require_force_cmd: false,
                reap_grant: true,
            }
        );
    }

    #[test]
    fn bunker_step_is_sticky_until_biometric_unbunker() {
        let tripped = bunker_step(BunkerState::Normal, true, false, 0, false);
        assert_eq!(
            tripped,
            BunkerStepVerdict {
                next_state: BunkerState::HardLockdown,
                revoke_all_jit_grants: true,
                isolate_node_mesh: true,
            }
        );
        // Stays in HardLockdown without biometric_unbunker
        let still_locked = bunker_step(BunkerState::HardLockdown, false, false, 0, false);
        assert_eq!(still_locked.next_state, BunkerState::HardLockdown);
        assert!(still_locked.revoke_all_jit_grants);
        // Biometric reset when canary is cleared returns to Normal
        let reset = bunker_step(BunkerState::HardLockdown, false, false, 0, true);
        assert_eq!(reset.next_state, BunkerState::Normal);
        assert!(!reset.revoke_all_jit_grants);
    }

    #[test]
    fn deploy_gate_allows_dev_zero_touch_and_requires_session_grant_on_prod() {
        let dev = DeployGateInput {
            is_prod_service: false,
            service_matches: true,
            calling_on_self: false,
            debounce_ok: true,
            force_flag: false,
            biometric_approved: false,
            bunker_state: BunkerState::Normal,
            live_writers: 0,
        };
        assert!(deploy_gate_step(dev));
        assert!(!deploy_gate_step(DeployGateInput {
            is_prod_service: true,
            ..dev
        }));
        assert!(deploy_gate_step(DeployGateInput {
            is_prod_service: true,
            biometric_approved: true,
            ..dev
        }));
    }
}

#[cfg(test)]
mod stats_settle_tests {
    use super::*;

    #[test]
    fn settle_adds_once_ignores_replays_and_saturates() {
        assert_eq!(stats_settle_step(10, 5, false), 15);
        assert_eq!(stats_settle_step(10, 5, true), 10);
        assert_eq!(stats_settle_step(u64::MAX - 3, 10, false), u64::MAX);
    }
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
        assert!(lean_sys_cabi::verify_page_aligned_buffer(
            0x10000,
            12_000,
            16_384,
            100_000_000,
            1_400_000_000,
            16_383
        ));
        assert!(!lean_sys_cabi::verify_page_aligned_buffer(
            0x10004,
            12_000,
            16_384,
            100_000_000,
            1_400_000_000,
            16_383
        ));
        assert!(lean_sys_cabi::verify_worker_budget(6, 9, 12, 4096, 2));
        assert!(!lean_sys_cabi::verify_worker_budget(6, 10, 12, 4096, 2));
        assert_eq!(lean_sys_cabi::select_isa(927, 927, 4, 4), 4);
        assert_eq!(lean_sys_cabi::select_isa(775, 927, 4, 4), 0);
        assert!(lean_sys_cabi::verify_isa_selection(927, 927, 4, 4));
        assert!(!lean_sys_cabi::verify_isa_selection(775, 927, 4, 4));
    }

    #[test]
    fn phase6_scroll_epoch_and_client_parity_zero_divergences() {
        let scroll_counter = ShadowCounter::new();
        let parity_counter = ShadowCounter::new();

        // 1. First scroll correction in layout epoch 12 is admitted
        let first = observe_scroll_epoch_shadow(
            ScrollEpochStepInput {
                layout_epoch: 12,
                last_corrected_epoch: 11,
                corrections_in_epoch: 0,
                is_pinned_to_bottom: true,
                user_is_dragging: false,
                target_scroll_top_px: 3817,
                current_scroll_top_px: 3600,
            },
            true,
            &scroll_counter,
        );
        assert_eq!(first.action, ScrollEpochAction::ApplyEpochCorrection);
        assert!(first.apply_scroll);
        assert!(first.epoch_fence_set);
        assert_eq!(first.effective_scroll_top_px, 3817);

        // 2. Duplicate correction in the same layout epoch 12 is suppressed (`scroll_single_correction_per_epoch`)
        let second = observe_scroll_epoch_shadow(
            ScrollEpochStepInput {
                layout_epoch: 12,
                last_corrected_epoch: 12,
                corrections_in_epoch: 1,
                is_pinned_to_bottom: true,
                user_is_dragging: false,
                target_scroll_top_px: 3817,
                current_scroll_top_px: 3700,
            },
            false,
            &scroll_counter,
        );
        assert_eq!(
            second.action,
            ScrollEpochAction::SuppressDuplicateEpochCorrection
        );
        assert!(!second.apply_scroll);
        assert!(second.epoch_fence_set);
        assert_eq!(second.effective_scroll_top_px, 3700);

        // 3. Cross-client parity across Core (0), iOS (1), Android (2), and Desktop wasm32 (3)
        let targets = [
            ClientProjectionTarget::Core,
            ClientProjectionTarget::Ios,
            ClientProjectionTarget::Android,
            ClientProjectionTarget::DesktopWasm32,
        ];
        let mut ref_digest = None;
        for target in targets {
            let v = observe_client_parity_shadow(
                ClientParityStepInput {
                    client_target: target,
                    wire_schema_id: 1,
                    transcript_seq: 42,
                    markdown_blocks_count: 7,
                    send_queue_depth: 1,
                    scroll_corrected_in_epoch: true,
                },
                true,
                &parity_counter,
            );
            assert!(v.parity_admitted);
            if let Some(d) = ref_digest {
                assert_eq!(
                    v.digest32, d,
                    "all 4 client targets must produce identical parity digest"
                );
            } else {
                ref_digest = Some(v.digest32);
            }
        }

        let scroll_snap = scroll_counter.snapshot("orb_scroll_epoch_step");
        let parity_snap = parity_counter.snapshot("orb_client_parity_step");
        assert_eq!(scroll_snap.total_events, 2);
        assert_eq!(scroll_snap.total_divergences, 0);
        assert_eq!(parity_snap.total_events, 4);
        assert_eq!(parity_snap.total_divergences, 0);
    }

    /// Argument text is attacker-controlled; only the audit uid and an exact cgroup count.
    #[test]
    fn canary_actor_trust_ignores_argv_and_unknown_uid() {
        // Spoofed argv markers from a non-agent uid/cgroup.
        for cmd in [
            "rg /var/lib/sandboxed-node/ .env.production.canary",
            "fast_9024_scanner cat .env.production.canary",
        ] {
            assert_eq!(
                classify_actor_trust(
                    Some(1000),
                    Some("0::/user.slice/user-1000.slice/session-3.scope"),
                    Some(cmd)
                ),
                ActorTrust::UntrustedOrSystem
            );
            assert_eq!(
                classify_actor_trust(None, None, Some(cmd)),
                ActorTrust::UntrustedOrSystem
            );
        }
        // An unresolvable uid is never the trusted agent uid.
        assert_eq!(
            classify_actor_trust(
                None,
                Some("0::/system.slice/orb-node.service"),
                Some("rg x")
            ),
            ActorTrust::UntrustedOrSystem
        );
        // Agent uid in a cgroup that only contains an agent name as a substring.
        for cg in [
            "0::/user.slice/opencode-evil.scope",
            "0::/system.slice/sandboxed-node.service.d/evil",
            "0::/missions.slice/a.scope/nested",
            "0::/missions.slice/.scope",
        ] {
            assert_eq!(
                classify_actor_trust(Some(999), Some(cg), Some("rg x")),
                ActorTrust::UntrustedOrSystem,
                "{cg}"
            );
        }
    }

    #[test]
    fn wave10_canary_whitelist_high_signal_bait_enforcer_and_biometric_gates() {
        // 1. Whitelisted agent walk (`rg --hidden` by sandboxed-node) on an ambient decoy
        //    is ignored: no node quarantine, no fleet bunker escalation (`canary_whitelisted_ambient_no_bunker`).
        let actor = classify_actor_trust(
            Some(999),
            Some("/system.slice/sandboxed-node.service"),
            Some("rg --hidden --no-ignore CANT_MATCH ."),
        );
        assert_eq!(actor, ActorTrust::WhitelistedAgentWalk);
        let class = classify_canary_class("env_honeytoken");
        assert_eq!(class, CanaryClass::AmbientDecoy);

        let v_walk = canary_tripwire_step(CanaryTripwireStepInput {
            canary_class: class,
            actor_trust: actor,
            is_dry_run: false,
            current_fleet_bunker: BunkerState::Normal,
        });
        assert_eq!(v_walk.action, CanaryTripwireAction::IgnoreWhitelisted);
        assert!(!v_walk.quarantine_reporting_node);
        assert!(!v_walk.escalate_fleet_lockdown);
        assert!(!v_walk.alert_operator);
        assert_eq!(v_walk.next_fleet_bunker, BunkerState::Normal);

        // Today's false positive: the node runs as `orb-node.service`, and a short-lived `rg`
        // exits before its cgroup is read. Both stay a whitelisted walk via the attested uid.
        for cg in [
            Some("0::/system.slice/orb-node.service\n"),
            Some("0::/missions.slice/sandboxed-exec-host-mf0fbffbb-81226671.scope"),
            None,
        ] {
            assert_eq!(
                classify_actor_trust(Some(999), cg, Some("/usr/bin/rg --hidden x .")),
                ActorTrust::WhitelistedAgentWalk
            );
        }

        // 2. Single mission process reading `.env.production.canary` (`cat`) quarantines ONLY that node
        //    and leaves global fleet bunker at `Normal` (`canary_mission_ambient_node_only`).
        let actor_cat = classify_actor_trust(
            Some(999),
            Some("/system.slice/sandboxed-node.service"),
            Some("cat /opt/paloma-canary/.env.production.canary"),
        );
        assert_eq!(actor_cat, ActorTrust::MissionProcess);
        let v_mission = canary_tripwire_step(CanaryTripwireStepInput {
            canary_class: CanaryClass::AmbientDecoy,
            actor_trust: actor_cat,
            is_dry_run: false,
            current_fleet_bunker: BunkerState::Normal,
        });
        assert_eq!(v_mission.action, CanaryTripwireAction::QuarantineNodeOnly);
        assert!(v_mission.quarantine_reporting_node);
        assert!(!v_mission.escalate_fleet_lockdown);
        assert!(v_mission.alert_operator);
        assert_eq!(v_mission.next_fleet_bunker, BunkerState::Normal);

        // 3. High-signal attacker bait (`btc_wallet_canary` / fake Bitcoin private key) ALWAYS escalates
        //    to fleet `HardLockdown (2)` EVEN when accessed by a whitelisted agent process
        //    (`canary_high_signal_bait_always_locks_down`).
        let btc_class = classify_canary_class("btc_wallet_canary");
        assert_eq!(btc_class, CanaryClass::HighSignalBait);
        for trust in [
            ActorTrust::WhitelistedAgentWalk,
            ActorTrust::MissionProcess,
            ActorTrust::UntrustedOrSystem,
        ] {
            let v_btc = canary_tripwire_step(CanaryTripwireStepInput {
                canary_class: btc_class,
                actor_trust: trust,
                is_dry_run: false,
                current_fleet_bunker: BunkerState::Normal,
            });
            assert_eq!(v_btc.action, CanaryTripwireAction::EscalateFleetLockdown);
            assert!(v_btc.quarantine_reporting_node);
            assert!(v_btc.escalate_fleet_lockdown);
            assert!(v_btc.alert_operator);
            assert_eq!(v_btc.next_fleet_bunker, BunkerState::HardLockdown);
        }

        // 4. Worker node bunker enforcer converges to `ReleaseQuarantine` and clears local marker
        //    once `last_unbunker_epoch >= local_trip_epoch` and `fleet_bunker == Normal`
        //    (`bunker_enforcer_converges_on_unbunker`).
        let enf_keep = bunker_enforcer_step(BunkerEnforcerStepInput {
            status_reachable: true,
            fleet_bunker: 0,
            node_quarantined_by_core: false,
            has_local_trip_marker: true,
            local_trip_epoch: 200,
            last_unbunker_epoch: 150,
        });
        assert_eq!(enf_keep.action, BunkerEnforcerAction::ApplyOrKeepQuarantine);
        assert!(enf_keep.apply_or_keep_quarantine);

        let enf_release = bunker_enforcer_step(BunkerEnforcerStepInput {
            status_reachable: true,
            fleet_bunker: 0,
            node_quarantined_by_core: false,
            has_local_trip_marker: true,
            local_trip_epoch: 200,
            last_unbunker_epoch: 205,
        });
        assert_eq!(enf_release.action, BunkerEnforcerAction::ReleaseQuarantine);
        assert!(!enf_release.apply_or_keep_quarantine);
        assert!(enf_release.clear_local_marker);

        // 5. Biometric gate never fails open (`biometric_gate_never_fails_open`).
        let bio_fail = biometric_gate_step(true, true, false, false);
        assert!(!bio_fail.admitted);
        assert!(bio_fail.surface_error);
        let bio_ok = biometric_gate_step(true, true, true, false);
        assert!(bio_ok.admitted);
        assert!(!bio_ok.surface_error);

        // 6. Mesh service route rejects retired Tailscale CGNAT (`mesh_service_route_rejects_retired_tailnet`).
        let route_retired = mesh_service_route_step(true, true, true, false);
        assert!(!route_retired.admitted);
        assert!(route_retired.rejected_retired_tailnet);
        let route_mesh = mesh_service_route_step(true, false, false, false);
        assert!(route_mesh.admitted);
        assert!(!route_mesh.rejected_retired_tailnet);
    }
}
