#![allow(clippy::too_many_arguments)]
//! Typed bindings to `lean/Orb/Kernel.lean` and `LeanSys/Spec.lean` (`liborb_spec_cabi.a`).

pub mod shadow;

pub mod lean_sys_cabi {
    //! Zero-dependency typed Rust bindings to the 33 formally verified unboxed C-ABI
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
        pub fn leansys_verify_fd_bounds(raw_word: u64, fd_out: u32) -> u8;
        pub fn leansys_verify_par_chunk(
            chunk_start: u64,
            chunk_end: u64,
            total_len: u64,
            min_grain: u64,
        ) -> u8;
        pub fn leansys_verify_arena_disjoint(
            off_a: u64,
            len_a: u64,
            off_b: u64,
            len_b: u64,
            arena_cap: u64,
        ) -> u8;
        pub fn leansys_verify_snapshot_visibility(
            entry_seq: u64,
            max_snapshot_seq: u64,
            is_tombstone: u8,
        ) -> u8;
        pub fn leansys_verify_http_route_match(
            method_match: u8,
            path_match: u8,
            route_idx: u32,
            route_count: u32,
        ) -> u8;
        pub fn leansys_verify_counterexample_triage(
            has_violation: u8,
            has_missing_hyp_hint: u8,
            ref_disagrees_with_candidate: u8,
            triage_class: u8,
        ) -> u8;
        pub fn leansys_verify_dag_wave_step(
            in_degree_sum: u64,
            wave_size: u64,
            completed_tasks: u64,
            total_tasks: u64,
            active_workers: u64,
            max_workers: u64,
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

    #[inline]
    pub fn verify_fd_bounds(raw_word: u64, fd_out: u32) -> bool {
        unsafe { leansys_verify_fd_bounds(raw_word, fd_out) == 1 }
    }

    #[inline]
    pub fn verify_par_chunk(
        chunk_start: u64,
        chunk_end: u64,
        total_len: u64,
        min_grain: u64,
    ) -> bool {
        unsafe { leansys_verify_par_chunk(chunk_start, chunk_end, total_len, min_grain) == 1 }
    }

    #[inline]
    pub fn verify_arena_disjoint(
        off_a: u64,
        len_a: u64,
        off_b: u64,
        len_b: u64,
        arena_cap: u64,
    ) -> bool {
        unsafe { leansys_verify_arena_disjoint(off_a, len_a, off_b, len_b, arena_cap) == 1 }
    }

    #[inline]
    pub fn verify_snapshot_visibility(
        entry_seq: u64,
        max_snapshot_seq: u64,
        is_tombstone: bool,
    ) -> bool {
        unsafe {
            leansys_verify_snapshot_visibility(entry_seq, max_snapshot_seq, u8::from(is_tombstone))
                == 1
        }
    }

    #[inline]
    pub fn verify_http_route_match(
        method_match: bool,
        path_match: bool,
        route_idx: u32,
        route_count: u32,
    ) -> bool {
        unsafe {
            leansys_verify_http_route_match(
                u8::from(method_match),
                u8::from(path_match),
                route_idx,
                route_count,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_counterexample_triage(
        has_violation: bool,
        has_missing_hyp_hint: bool,
        ref_disagrees_with_candidate: bool,
        triage_class: u8,
    ) -> bool {
        unsafe {
            leansys_verify_counterexample_triage(
                u8::from(has_violation),
                u8::from(has_missing_hyp_hint),
                u8::from(ref_disagrees_with_candidate),
                triage_class,
            ) == 1
        }
    }

    #[inline]
    pub fn verify_dag_wave_step(
        in_degree_sum: u64,
        wave_size: u64,
        completed_tasks: u64,
        total_tasks: u64,
        active_workers: u64,
        max_workers: u64,
    ) -> bool {
        unsafe {
            leansys_verify_dag_wave_step(
                in_degree_sum,
                wave_size,
                completed_tasks,
                total_tasks,
                active_workers,
                max_workers,
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
    fn orb_verify_approval(
        signed: u8,
        owned: u8,
        pending: u8,
        unexpired: u8,
        unchanged: u8,
        risk: u8,
        confirmed: u8,
    ) -> u8;
    fn orb_vm_lifecycle_step(
        owner_class: u8,
        busy: u8,
        ttl_expired: u8,
        grace_or_idle_elapsed: u8,
        working_idle_enabled: u8,
        supports_free_stop: u8,
        min_delete_pending: u8,
    ) -> u32;
    fn orb_vm_claim_step(is_live: u8, same_tenant: u8, owner_none: u8, owner_in_lineage: u8)
        -> u32;
    fn orb_compute_secret_gate(
        is_core_reserved_compute_key: u8,
        caller_on_managed_node: u8,
        is_allowlisted_managed_secret: u8,
        operator_break_glass: u8,
    ) -> u32;
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
    fn orb_node_gc_step(
        free_bytes: u64,
        floor_bytes: u64,
        emergency_floor_bytes: u64,
        aged_scratch_bytes: u64,
        fresh_scratch_bytes: u64,
        cold_cache_bytes: u64,
        hot_cache_bytes: u64,
    ) -> u64;
    fn orb_node_disk_admission_step(
        free_bytes: u64,
        reserved_bytes: u64,
        node_floor_bytes: u64,
        core_floor_bytes: u64,
        hysteresis_bytes: u64,
        node_pinned_pressure: u8,
    ) -> u64;
    fn orb_scroll_max_top(content: u64, viewport: u64) -> u64;
    fn orb_scroll_clamp_top(content: u64, viewport: u64, top: u64) -> u64;
    fn orb_scroll_gap(content: u64, viewport: u64, top: u64) -> u64;
    fn orb_scroll_layout_step(pinned: u8, content: u64, viewport: u64, top: u64) -> u64;
    fn orb_scroll_user_step(content: u64, viewport: u64, top: u64, threshold: u64) -> u8;
    fn orb_scroll_jump_step(content: u64, viewport: u64) -> u64;
    fn orb_scroll_correct(pinned: u8, content: u64, viewport: u64, top: u64) -> u64;
    fn orb_scroll_shows_jump(
        pinned: u8,
        content: u64,
        viewport: u64,
        top: u64,
        pill_threshold: u64,
    ) -> u8;
    fn orb_stream_coalescer_step(op: u8, shown_len: u32, pending_len: u32, delta_len: u32) -> u64;
    fn orb_stream_fence_step(
        open_kind: u8,
        open_count: u32,
        marker_kind: u8,
        marker_count: u32,
    ) -> u64;
    fn orb_stream_commit_step(
        tick: u8,
        open_kind: u8,
        open_count: u32,
        line_blank: u8,
        line_tick: u8,
        marker_kind: u8,
        marker_count: u32,
        pos: u32,
        commit: u32,
    ) -> u64;
    fn orb_stream_token_cost_step(prev_cost: u64, new_advance: u64, tail_bytes: u64) -> u64;
    fn orb_mission_state_classify(state_id: u8) -> u8;
    fn orb_mission_sort_rank(state_id: u8) -> u8;
    fn orb_mission_flags(state_id: u8) -> u32;
    fn orb_mission_inbox_section(state_id: u8) -> u8;
    fn orb_connection_issue_classify(
        is_unreachable: u8,
        is_using_default: u8,
        is_private_addr: u8,
        default_reachable: u8,
        has_external_proxy: u8,
    ) -> u32;
    fn orb_worked_duration_bucket(seconds: u64) -> u64;
    fn orb_turn_outcome_step(
        prev_outcome: u8,
        prev_failed: u8,
        event_kind: u8,
        is_narration: u8,
        is_success_false: u8,
        is_text_non_empty: u8,
    ) -> u32;
    fn orb_numeric_cell_scan(
        non_empty: u8,
        has_leading_digit_or_sign: u8,
        has_digit: u8,
        all_allowed_chars: u8,
    ) -> u8;
    fn orb_file_ref_line_span(start_line: u32, end_line: u32, total_lines: u32) -> u64;
    fn orb_machine_action_admitted(state_kind: u8, is_busy: u8, is_muted: u8) -> u32;
    fn orb_send_flow_step(
        is_busy: u8,
        has_non_empty_text: u8,
        can_queue: u8,
        awaiting_ack: u8,
        is_draining: u8,
        pending_count: u8,
        http_status: u32,
    ) -> u32;
    // ═══════════════════════════════════════════════════════════════════════════
    // Wave 12 (P4–P6): Compositional OrbWire Patch/Machine Steppers &
    //                  7 Stateful Domain Transition Families (`G-ORB-1..7`)
    // ═══════════════════════════════════════════════════════════════════════════

    fn orb_wire_apply_patch_step(
        current_rev: u64,
        incoming_rev: u64,
        current_has_val: u8,
        current_val: u32,
        presence: u8,
        incoming_val: u32,
    ) -> u64;
    fn orb_wire_machine_step(
        schema_id: u32,
        state_rev: u64,
        event_seq: u64,
        effect_kind: u8,
        effect_admitted: u8,
        out_cap: u32,
        required_out_bytes: u32,
    ) -> u64;
    fn orb_hierarchy_merge_step(
        current_epoch: u64,
        incoming_epoch: u64,
        archive_epoch: u64,
        cur_archived: u8,
        cur_superseded: u8,
        is_partial_patch: u8,
        parent_presence: u8,
        cur_parent_ord: u32,
        inc_parent_ord: u32,
        inc_archive: u8,
        inc_unarchive: u8,
        inc_supersede: u8,
    ) -> u64;
    fn orb_transcript_fold_step(
        last_applied_seq: u64,
        incoming_seq: u64,
        entry_count: u32,
        thinking_open: u8,
        normalized_action: u8,
        is_replay_from_log: u8,
    ) -> u64;
    fn orb_outbox_crash_reconcile_step(
        durable_queued: u32,
        durable_acked: u32,
        volatile_in_flight: u32,
        lease_boot_epoch: u64,
        node_boot_epoch: u64,
        volatile_lease_owner: u32,
        req_owner: u32,
    ) -> u64;
    fn orb_provider_attempt_step(
        pinned_account_id: u32,
        candidate_account_id: u32,
        attempts_used: u32,
        retry_budget: u32,
        first_byte_committed: u8,
        failure_kind: u8,
        upstream_now_epoch: u64,
        cooldown_until_epoch: u64,
        upstream_deadline: u64,
        auth_valid: u8,
    ) -> u64;
    fn orb_auth_toctou_execute_step(
        principal_kind: u8,
        bunker_state: u8,
        observed_target_id: u32,
        exec_target_id: u32,
        observed_lease_epoch: u64,
        live_lease_epoch: u64,
        now_tick: u64,
        expiry_tick: u64,
        observed_digest: u64,
        exec_digest: u64,
    ) -> u32;
    fn orb_resource_ledger_step(
        op_kind: u8,
        reserved_slots: u32,
        active_slots: u32,
        max_slots: u32,
        spent_cents: u64,
        cost_delta_cents: u64,
        budget_cents: u64,
        now_tick: u64,
        ttl_expiry_tick: u64,
    ) -> u64;
    fn orb_stream_bounded_commit_step(
        prev_len: u32,
        prev_commit: u32,
        prev_checkpoint: u32,
        new_len: u32,
        raw_commit: u32,
        max_open_tail_bytes: u32,
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

/// Risk tier of an approval request: what one fingerprint may grant in a batch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ApprovalRisk {
    Routine = 0,
    Elevated = 1,
    /// Root, secret delete or move: never approved without explicit confirmation.
    Critical = 2,
}

/// One request at approval time, as Core checks it (`orb_verify_approval`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ApprovalAdmission {
    pub signed: bool,
    pub owned: bool,
    pub pending: bool,
    pub unexpired: bool,
    pub unchanged: bool,
    pub risk: ApprovalRisk,
    pub confirmed: bool,
}

/// Verified approval gate shared by every approval kind and by batches
/// (a batch is admitted only when every item is).
pub fn approval_admitted(input: ApprovalAdmission) -> bool {
    unsafe {
        orb_verify_approval(
            u8::from(input.signed),
            u8::from(input.owned),
            u8::from(input.pending),
            u8::from(input.unexpired),
            u8::from(input.unchanged),
            input.risk as u8,
            u8::from(input.confirmed),
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
#[repr(u8)]
pub enum VmOwnerClass {
    Unknown = 0,
    Working = 1,
    Waiting = 2,
    TerminalOrMissing = 3,
    UserOrUnowned = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum VmLifecycleAction {
    Keep = 0,
    Schedule = 1,
    Stop = 2,
    Destroy = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VmLifecycleInput {
    pub owner_class: VmOwnerClass,
    pub busy: bool,
    pub ttl_expired: bool,
    pub grace_or_idle_elapsed: bool,
    pub working_idle_enabled: bool,
    pub supports_free_stop: bool,
    pub min_delete_pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VmLifecycleVerdict {
    pub action: VmLifecycleAction,
    pub admitted: bool,
    pub defer_for_min_lease: bool,
}

pub fn vm_lifecycle_step(input: VmLifecycleInput) -> VmLifecycleVerdict {
    let raw = unsafe {
        orb_vm_lifecycle_step(
            input.owner_class as u8,
            u8::from(input.busy),
            u8::from(input.ttl_expired),
            u8::from(input.grace_or_idle_elapsed),
            u8::from(input.working_idle_enabled),
            u8::from(input.supports_free_stop),
            u8::from(input.min_delete_pending),
        )
    };
    let action = match raw & 0xFF {
        1 => VmLifecycleAction::Schedule,
        2 => VmLifecycleAction::Stop,
        3 => VmLifecycleAction::Destroy,
        _ => VmLifecycleAction::Keep,
    };
    VmLifecycleVerdict {
        action,
        admitted: ((raw >> 8) & 1) != 0,
        defer_for_min_lease: ((raw >> 16) & 1) != 0,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VmClaimInput {
    pub is_live: bool,
    pub same_tenant: bool,
    pub owner_none: bool,
    pub owner_in_lineage: bool,
}

pub fn vm_claim_admit(input: VmClaimInput) -> bool {
    let raw = unsafe {
        orb_vm_claim_step(
            u8::from(input.is_live),
            u8::from(input.same_tenant),
            u8::from(input.owner_none),
            u8::from(input.owner_in_lineage),
        )
    };
    ((raw >> 8) & 1) != 0
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ComputeSecretInput {
    pub is_core_reserved_compute_key: bool,
    pub caller_on_managed_node: bool,
    pub is_allowlisted_managed_secret: bool,
    pub operator_break_glass: bool,
}

pub fn compute_secret_admit(input: ComputeSecretInput) -> bool {
    let raw = unsafe {
        orb_compute_secret_gate(
            u8::from(input.is_core_reserved_compute_key),
            u8::from(input.caller_on_managed_node),
            u8::from(input.is_allowlisted_managed_secret),
            u8::from(input.operator_break_glass),
        )
    };
    ((raw >> 8) & 1) != 0
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum NodeGcAction {
    Healthy = 0,
    SweepAgedScratch = 1,
    EvictColdCaches = 2,
    SweepAllRetiredScratch = 3,
    EvictHotCaches = 4,
    PinnedPreserveHot = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeGcStepInput {
    pub free_bytes: u64,
    pub floor_bytes: u64,
    pub emergency_floor_bytes: u64,
    pub aged_scratch_bytes: u64,
    pub fresh_scratch_bytes: u64,
    pub cold_cache_bytes: u64,
    pub hot_cache_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeGcStepVerdict {
    pub action: NodeGcAction,
    pub sweep_aged_scratch: bool,
    pub evict_cold_cache: bool,
    pub sweep_fresh_scratch: bool,
    pub evict_hot_cache: bool,
    pub pinned_pressure: bool,
    pub retired_grace_hours: u32,
    pub raw: u64,
}

#[inline]
pub fn node_gc_step(input: NodeGcStepInput) -> NodeGcStepVerdict {
    let raw = unsafe {
        orb_node_gc_step(
            input.free_bytes,
            input.floor_bytes,
            input.emergency_floor_bytes,
            input.aged_scratch_bytes,
            input.fresh_scratch_bytes,
            input.cold_cache_bytes,
            input.hot_cache_bytes,
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => NodeGcAction::SweepAgedScratch,
        2 => NodeGcAction::EvictColdCaches,
        3 => NodeGcAction::SweepAllRetiredScratch,
        4 => NodeGcAction::EvictHotCaches,
        5 => NodeGcAction::PinnedPreserveHot,
        _ => NodeGcAction::Healthy,
    };
    NodeGcStepVerdict {
        action,
        sweep_aged_scratch: ((raw >> 8) & 1) != 0,
        evict_cold_cache: ((raw >> 9) & 1) != 0,
        sweep_fresh_scratch: ((raw >> 10) & 1) != 0,
        evict_hot_cache: ((raw >> 11) & 1) != 0,
        pinned_pressure: ((raw >> 12) & 1) != 0,
        retired_grace_hours: (raw >> 32) as u32,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum NodeDiskAdmissionAction {
    RejectBelowFloor = 0,
    Admit = 1,
    RejectPinnedPressure = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeDiskAdmissionInput {
    pub free_bytes: u64,
    pub reserved_bytes: u64,
    pub node_floor_bytes: u64,
    pub core_floor_bytes: u64,
    pub hysteresis_bytes: u64,
    pub node_pinned_pressure: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeDiskAdmissionVerdict {
    pub action: NodeDiskAdmissionAction,
    pub admitted: bool,
    pub soft_pressure: bool,
    pub headroom_gib: u32,
    pub raw: u64,
}

#[inline]
pub fn node_disk_admission_step(input: NodeDiskAdmissionInput) -> NodeDiskAdmissionVerdict {
    let raw = unsafe {
        orb_node_disk_admission_step(
            input.free_bytes,
            input.reserved_bytes,
            input.node_floor_bytes,
            input.core_floor_bytes,
            input.hysteresis_bytes,
            u8::from(input.node_pinned_pressure),
        )
    };
    let action = match (raw & 0xFF) as u8 {
        1 => NodeDiskAdmissionAction::Admit,
        2 => NodeDiskAdmissionAction::RejectPinnedPressure,
        _ => NodeDiskAdmissionAction::RejectBelowFloor,
    };
    NodeDiskAdmissionVerdict {
        action,
        admitted: ((raw >> 8) & 1) != 0,
        soft_pressure: ((raw >> 9) & 1) != 0,
        headroom_gib: (raw >> 32) as u32,
        raw,
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

    pub fn with_ring<R>(&self, f: impl FnOnce(&mut shadow::ShadowDivergenceRing<256>) -> R) -> R {
        let mut ring = self
            .ring
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        f(&mut ring)
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

#[inline]
pub fn scroll_max_top(content: u64, viewport: u64) -> u64 {
    unsafe { orb_scroll_max_top(content, viewport) }
}
/// Pure $O(\min(|existing|, |incoming|))$ UTF-8 boundary-preserving KMP suffix-prefix overlap
/// length (`incoming[..overlap] == existing[existing.len() - overlap..]`), paired with
/// incremental fragment merging (`merge_text_stream_fragment`).
pub fn suffix_prefix_overlap_len(existing: &str, incoming: &str) -> usize {
    let eb = existing.as_bytes();
    let ib = incoming.as_bytes();
    let max_b = eb.len().min(ib.len());
    if max_b == 0 {
        return 0;
    }
    let mut start = eb.len() - max_b;
    while !existing.is_char_boundary(start) {
        start += 1;
    }
    let tail = &eb[start..];
    if tail.is_empty() {
        return 0;
    }
    let pat = &ib[..tail.len()];
    let mut pi = vec![0usize; pat.len()];
    let mut j = 0usize;
    for i in 1..pat.len() {
        while j > 0 && pat[i] != pat[j] {
            j = pi[j - 1];
        }
        if pat[i] == pat[j] {
            j += 1;
        }
        pi[i] = j;
    }
    let mut matched = 0usize;
    for &b in tail {
        while matched > 0 && b != pat[matched] {
            matched = pi[matched - 1];
        }
        if b == pat[matched] {
            matched += 1;
            if matched == pat.len() {
                break;
            }
        }
    }
    while matched > 0 && !incoming.is_char_boundary(matched) {
        matched = pi[matched - 1];
    }
    matched
}

/// Pure incremental stream fragment merge used by `src/api/control/streaming.rs`.
pub fn merge_text_stream_fragment(buffer: &mut String, fragment: &str) {
    if fragment.is_empty() {
        return;
    }
    if buffer.is_empty() || fragment.starts_with(buffer.as_str()) {
        *buffer = fragment.to_string();
        return;
    }
    if buffer.starts_with(fragment) {
        return;
    }
    let overlap = suffix_prefix_overlap_len(buffer, fragment);
    buffer.push_str(&fragment[overlap..]);
}

/// Summary produced by the capability-gated stream byte scanner (`stream_simd`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamByteScanSummary {
    pub newlines: usize,
    pub fence_candidates: usize,
    pub pipe_bytes: usize,
    pub last_newline: usize,
}

/// Capability-gated stream delimiter scanner routed through `lean_sys_cabi::select_isa`
/// and `lean_sys_cabi::verify_isa_selection` (`0` = Scalar, `1` = SSE2 / NEON, `2` = AVX2).
pub mod stream_simd {
    use super::{lean_sys_cabi, StreamByteScanSummary};

    pub const VARIANT_SCALAR: u8 = 0;
    pub const VARIANT_SIMD128: u8 = 1;
    pub const VARIANT_AVX2: u8 = 2;
    pub const MAX_VARIANT_ID: u8 = 4;

    pub const MASK_BASELINE: u64 = 263;
    pub const MASK_SIMD128: u64 = 775;
    pub const MASK_AVX2: u64 = 799;

    #[inline]
    pub fn detect_hw_caps() -> u64 {
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            let mut caps = MASK_BASELINE;
            if std::arch::is_x86_feature_detected!("sse2") {
                caps |= MASK_SIMD128;
            }
            if std::arch::is_x86_feature_detected!("avx2") {
                caps |= MASK_AVX2;
            }
            caps
        }
        #[cfg(target_arch = "aarch64")]
        {
            if std::arch::is_aarch64_feature_detected!("neon") {
                MASK_SIMD128
            } else {
                MASK_BASELINE
            }
        }
        #[cfg(not(any(target_arch = "x86", target_arch = "x86_64", target_arch = "aarch64")))]
        {
            MASK_BASELINE
        }
    }

    #[inline]
    pub fn select_verified_stream_isa_with_caps(caps: u64, max_requested: u8) -> u8 {
        if max_requested >= VARIANT_AVX2 {
            let avx2 = lean_sys_cabi::select_isa(caps, MASK_AVX2, VARIANT_AVX2, MAX_VARIANT_ID);
            if avx2 == VARIANT_AVX2
                && lean_sys_cabi::verify_isa_selection(caps, MASK_AVX2, avx2, MAX_VARIANT_ID)
            {
                return VARIANT_AVX2;
            }
        }
        if max_requested >= VARIANT_SIMD128 {
            let simd128 =
                lean_sys_cabi::select_isa(caps, MASK_SIMD128, VARIANT_SIMD128, MAX_VARIANT_ID);
            if simd128 == VARIANT_SIMD128
                && lean_sys_cabi::verify_isa_selection(caps, MASK_SIMD128, simd128, MAX_VARIANT_ID)
            {
                return VARIANT_SIMD128;
            }
        }
        let _ = lean_sys_cabi::verify_isa_selection(
            caps,
            MASK_BASELINE,
            VARIANT_SCALAR,
            MAX_VARIANT_ID,
        );
        VARIANT_SCALAR
    }

    #[inline]
    pub fn select_verified_stream_isa() -> u8 {
        select_verified_stream_isa_with_caps(detect_hw_caps(), VARIANT_AVX2)
    }

    pub fn scan_stream_bytes_scalar(buf: &[u8]) -> StreamByteScanSummary {
        let mut newlines = 0usize;
        let mut fence_candidates = 0usize;
        let mut pipe_bytes = 0usize;
        let mut last_newline = usize::MAX;
        let mut at_line_head = true;
        let mut i = 0usize;
        while i < buf.len() {
            let b = buf[i];
            if b == b'\n' {
                newlines += 1;
                last_newline = i;
                at_line_head = true;
            } else if b == b'|' {
                pipe_bytes += 1;
                at_line_head = false;
            } else if at_line_head && b != b' ' && b != b'\t' {
                if (b == b'`' || b == b'~')
                    && i + 2 < buf.len()
                    && buf[i + 1] == b
                    && buf[i + 2] == b
                {
                    fence_candidates += 1;
                }
                at_line_head = false;
            }
            i += 1;
        }
        StreamByteScanSummary {
            newlines,
            fence_candidates,
            pipe_bytes,
            last_newline,
        }
    }

    #[inline]
    fn check_fence_at_line_start(buf: &[u8], mut p: usize) -> usize {
        let len = buf.len();
        while p < len {
            let b = buf[p];
            if b == b' ' || b == b'\t' {
                p += 1;
            } else {
                if (b == b'`' || b == b'~') && p + 2 < len && buf[p + 1] == b && buf[p + 2] == b {
                    return 1;
                }
                return 0;
            }
        }
        0
    }

    /// # Safety
    /// Caller must ensure the current CPU supports `sse2` (for example via
    /// `select_verified_stream_isa()` or `is_x86_feature_detected!("sse2")`).
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    #[target_feature(enable = "sse2")]
    pub unsafe fn scan_stream_bytes_sse2(buf: &[u8]) -> StreamByteScanSummary {
        #[cfg(target_arch = "x86")]
        use core::arch::x86::*;
        #[cfg(target_arch = "x86_64")]
        use core::arch::x86_64::*;

        let len = buf.len();
        if len == 0 {
            return StreamByteScanSummary {
                newlines: 0,
                fence_candidates: 0,
                pipe_bytes: 0,
                last_newline: usize::MAX,
            };
        }

        let mut fence_candidates = check_fence_at_line_start(buf, 0);
        let mut newlines = 0usize;
        let mut pipe_bytes = 0usize;
        let mut last_newline = usize::MAX;

        let nl_vec = _mm_set1_epi8(b'\n' as i8);
        let pipe_vec = _mm_set1_epi8(b'|' as i8);
        let ptr = buf.as_ptr();
        let mut i = 0usize;

        while i + 16 <= len {
            let chunk = unsafe { _mm_loadu_si128(ptr.add(i) as *const __m128i) };
            let nl_mask = (_mm_movemask_epi8(_mm_cmpeq_epi8(chunk, nl_vec)) as u32) & 0xFFFF;
            let pipe_mask = (_mm_movemask_epi8(_mm_cmpeq_epi8(chunk, pipe_vec)) as u32) & 0xFFFF;
            pipe_bytes += pipe_mask.count_ones() as usize;
            if nl_mask != 0 {
                newlines += nl_mask.count_ones() as usize;
                let highest_bit = 31 - nl_mask.leading_zeros() as usize;
                last_newline = i + highest_bit;
                let mut m = nl_mask;
                while m != 0 {
                    let bit = m.trailing_zeros() as usize;
                    fence_candidates += check_fence_at_line_start(buf, i + bit + 1);
                    m &= m - 1;
                }
            }
            i += 16;
        }

        while i < len {
            let b = buf[i];
            if b == b'\n' {
                newlines += 1;
                last_newline = i;
                fence_candidates += check_fence_at_line_start(buf, i + 1);
            } else if b == b'|' {
                pipe_bytes += 1;
            }
            i += 1;
        }

        StreamByteScanSummary {
            newlines,
            fence_candidates,
            pipe_bytes,
            last_newline,
        }
    }

    /// # Safety
    /// Caller must ensure the current CPU supports `avx2` (for example via
    /// `select_verified_stream_isa()` or `is_x86_feature_detected!("avx2")`).
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    #[target_feature(enable = "avx2")]
    pub unsafe fn scan_stream_bytes_avx2(buf: &[u8]) -> StreamByteScanSummary {
        #[cfg(target_arch = "x86")]
        use core::arch::x86::*;
        #[cfg(target_arch = "x86_64")]
        use core::arch::x86_64::*;

        let len = buf.len();
        if len == 0 {
            return StreamByteScanSummary {
                newlines: 0,
                fence_candidates: 0,
                pipe_bytes: 0,
                last_newline: usize::MAX,
            };
        }

        let mut fence_candidates = check_fence_at_line_start(buf, 0);
        let mut newlines = 0usize;
        let mut pipe_bytes = 0usize;
        let mut last_newline = usize::MAX;

        let nl_vec = _mm256_set1_epi8(b'\n' as i8);
        let pipe_vec = _mm256_set1_epi8(b'|' as i8);
        let ptr = buf.as_ptr();
        let mut i = 0usize;

        while i + 32 <= len {
            let chunk = unsafe { _mm256_loadu_si256(ptr.add(i) as *const __m256i) };
            let nl_mask = _mm256_movemask_epi8(_mm256_cmpeq_epi8(chunk, nl_vec)) as u32;
            let pipe_mask = _mm256_movemask_epi8(_mm256_cmpeq_epi8(chunk, pipe_vec)) as u32;
            pipe_bytes += pipe_mask.count_ones() as usize;
            if nl_mask != 0 {
                newlines += nl_mask.count_ones() as usize;
                let highest_bit = 31 - nl_mask.leading_zeros() as usize;
                last_newline = i + highest_bit;
                let mut m = nl_mask;
                while m != 0 {
                    let bit = m.trailing_zeros() as usize;
                    fence_candidates += check_fence_at_line_start(buf, i + bit + 1);
                    m &= m - 1;
                }
            }
            i += 32;
        }

        while i < len {
            let b = buf[i];
            if b == b'\n' {
                newlines += 1;
                last_newline = i;
                fence_candidates += check_fence_at_line_start(buf, i + 1);
            } else if b == b'|' {
                pipe_bytes += 1;
            }
            i += 1;
        }

        StreamByteScanSummary {
            newlines,
            fence_candidates,
            pipe_bytes,
            last_newline,
        }
    }

    pub fn scan_stream_bytes(buf: &[u8]) -> StreamByteScanSummary {
        match select_verified_stream_isa() {
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            VARIANT_AVX2 => unsafe { scan_stream_bytes_avx2(buf) },
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            VARIANT_SIMD128 => unsafe { scan_stream_bytes_sse2(buf) },
            _ => scan_stream_bytes_scalar(buf),
        }
    }
}

#[inline]
pub fn scroll_clamp_top(content: u64, viewport: u64, top: u64) -> u64 {
    unsafe { orb_scroll_clamp_top(content, viewport, top) }
}

#[inline]
pub fn scroll_gap(content: u64, viewport: u64, top: u64) -> u64 {
    unsafe { orb_scroll_gap(content, viewport, top) }
}

#[inline]
pub fn scroll_layout_step(pinned: bool, content: u64, viewport: u64, top: u64) -> u64 {
    unsafe { orb_scroll_layout_step(u8::from(pinned), content, viewport, top) }
}

#[inline]
pub fn scroll_user_step(content: u64, viewport: u64, top: u64, threshold: u64) -> bool {
    unsafe { orb_scroll_user_step(content, viewport, top, threshold) == 1 }
}

#[inline]
pub fn scroll_jump_step(content: u64, viewport: u64) -> u64 {
    unsafe { orb_scroll_jump_step(content, viewport) }
}

#[inline]
pub fn scroll_correct(pinned: bool, content: u64, viewport: u64, top: u64) -> u64 {
    unsafe { orb_scroll_correct(u8::from(pinned), content, viewport, top) }
}

#[inline]
pub fn scroll_shows_jump(
    pinned: bool,
    content: u64,
    viewport: u64,
    top: u64,
    pill_threshold: u64,
) -> bool {
    unsafe { orb_scroll_shows_jump(u8::from(pinned), content, viewport, top, pill_threshold) == 1 }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamCoalescerVerdict {
    pub next_shown_len: u32,
    pub next_pending_len: u32,
    pub did_render: bool,
    pub raw: u64,
}

#[inline]
pub fn stream_coalescer_step(
    op: u8,
    shown_len: u32,
    pending_len: u32,
    delta_len: u32,
) -> StreamCoalescerVerdict {
    let raw = unsafe { orb_stream_coalescer_step(op, shown_len, pending_len, delta_len) };
    StreamCoalescerVerdict {
        next_shown_len: raw as u32,
        next_pending_len: ((raw >> 32) & 0x7FFF_FFFF) as u32,
        did_render: (raw >> 63) != 0,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamFenceVerdict {
    pub next_fence_kind: u8,
    pub next_fence_count: u32,
    pub raw: u64,
}

#[inline]
pub fn stream_fence_step(
    open_kind: u8,
    open_count: u32,
    marker_kind: u8,
    marker_count: u32,
) -> StreamFenceVerdict {
    let raw = unsafe { orb_stream_fence_step(open_kind, open_count, marker_kind, marker_count) };
    StreamFenceVerdict {
        next_fence_kind: (raw & 0xFF) as u8,
        next_fence_count: (raw >> 32) as u32,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamCommitVerdict {
    pub next_tick: bool,
    pub next_fence_kind: u8,
    pub commits: bool,
    pub next_commit: u32,
    pub raw: u64,
}

#[inline]
pub fn stream_commit_step(
    tick: bool,
    open_kind: u8,
    open_count: u32,
    line_blank: bool,
    line_tick: bool,
    marker_kind: u8,
    marker_count: u32,
    pos: u32,
    commit: u32,
) -> StreamCommitVerdict {
    let raw = unsafe {
        orb_stream_commit_step(
            u8::from(tick),
            open_kind,
            open_count,
            u8::from(line_blank),
            u8::from(line_tick),
            marker_kind,
            marker_count,
            pos,
            commit,
        )
    };
    StreamCommitVerdict {
        next_tick: (raw & 1) != 0,
        next_fence_kind: ((raw >> 8) & 0xFF) as u8,
        commits: ((raw >> 16) & 1) != 0,
        next_commit: (raw >> 32) as u32,
        raw,
    }
}

#[inline]
pub fn stream_token_cost_step(prev_cost: u64, new_advance: u64, tail_bytes: u64) -> u64 {
    unsafe { orb_stream_token_cost_step(prev_cost, new_advance, tail_bytes) }
}

#[inline]
pub fn mission_state_classify(state_id: u8) -> u8 {
    unsafe { orb_mission_state_classify(state_id) }
}

#[inline]
pub fn mission_sort_rank(state_id: u8) -> u8 {
    unsafe { orb_mission_sort_rank(state_id) }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MissionFlagsVerdict {
    pub is_active: bool,
    pub is_terminal: bool,
    pub needs_attention: bool,
    pub awaits_review: bool,
    pub can_retry: bool,
    pub is_problem: bool,
    pub is_success: bool,
    pub can_reopen: bool,
    pub raw: u32,
}

#[inline]
pub fn mission_flags(state_id: u8) -> MissionFlagsVerdict {
    let raw = unsafe { orb_mission_flags(state_id) };
    MissionFlagsVerdict {
        is_active: (raw & 1) != 0,
        is_terminal: (raw & 2) != 0,
        needs_attention: (raw & 4) != 0,
        awaits_review: (raw & 8) != 0,
        can_retry: (raw & 16) != 0,
        is_problem: (raw & 32) != 0,
        is_success: (raw & 64) != 0,
        can_reopen: (raw & 128) != 0,
        raw,
    }
}

#[inline]
pub fn mission_inbox_section(state_id: u8) -> u8 {
    unsafe { orb_mission_inbox_section(state_id) }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionIssueVerdict {
    pub show_issue: bool,
    pub offer_use_default: bool,
    pub recommend_default: bool,
    pub should_probe_default: bool,
    pub message_kind: u8,
    pub raw: u32,
}

#[inline]
pub fn connection_issue_classify(
    is_unreachable: bool,
    is_using_default: bool,
    is_private_addr: bool,
    default_reachable: bool,
    has_external_proxy: bool,
) -> ConnectionIssueVerdict {
    let raw = unsafe {
        orb_connection_issue_classify(
            u8::from(is_unreachable),
            u8::from(is_using_default),
            u8::from(is_private_addr),
            u8::from(default_reachable),
            u8::from(has_external_proxy),
        )
    };
    ConnectionIssueVerdict {
        show_issue: (raw & 1) != 0,
        offer_use_default: (raw & 256) != 0,
        recommend_default: (raw & 65536) != 0,
        should_probe_default: (raw & 16_777_216) != 0,
        message_kind: ((raw >> 28) & 0xF) as u8,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkedDurationVerdict {
    pub unit: u8,
    pub secondary: u8,
    pub primary: u32,
    pub raw: u64,
}

#[inline]
pub fn worked_duration_bucket(seconds: u64) -> WorkedDurationVerdict {
    let raw = unsafe { orb_worked_duration_bucket(seconds) };
    WorkedDurationVerdict {
        unit: (raw & 0xFF) as u8,
        secondary: ((raw >> 8) & 0xFF) as u8,
        primary: (raw >> 32) as u32,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TurnOutcomeVerdict {
    pub next_outcome_finished: bool,
    pub next_todos_failed: bool,
    pub raw: u32,
}

#[inline]
pub fn turn_outcome_step(
    prev_outcome_finished: bool,
    prev_failed: bool,
    event_kind: u8,
    is_narration: bool,
    is_success_false: bool,
    is_text_non_empty: bool,
) -> TurnOutcomeVerdict {
    let raw = unsafe {
        orb_turn_outcome_step(
            u8::from(prev_outcome_finished),
            u8::from(prev_failed),
            event_kind,
            u8::from(is_narration),
            u8::from(is_success_false),
            u8::from(is_text_non_empty),
        )
    };
    TurnOutcomeVerdict {
        next_outcome_finished: (raw & 1) != 0,
        next_todos_failed: (raw & 256) != 0,
        raw,
    }
}

#[inline]
pub fn numeric_cell_scan(
    non_empty: bool,
    has_leading_digit_or_sign: bool,
    has_digit: bool,
    all_allowed_chars: bool,
) -> bool {
    unsafe {
        orb_numeric_cell_scan(
            u8::from(non_empty),
            u8::from(has_leading_digit_or_sign),
            u8::from(has_digit),
            u8::from(all_allowed_chars),
        ) == 1
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileRefLineSpanVerdict {
    pub admitted: bool,
    pub span_line_count: u32,
    pub raw: u64,
}

#[inline]
pub fn file_ref_line_span(
    start_line: u32,
    end_line: u32,
    total_lines: u32,
) -> FileRefLineSpanVerdict {
    let raw = unsafe { orb_file_ref_line_span(start_line, end_line, total_lines) };
    FileRefLineSpanVerdict {
        admitted: (raw & 1) != 0,
        span_line_count: (raw >> 32) as u32,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MachineActionVerdict {
    pub is_live: bool,
    pub can_act: bool,
    pub meter_live_cost: bool,
    pub is_stopped: bool,
    pub can_resume: bool,
    pub raw: u32,
}

#[inline]
pub fn machine_action_admitted(
    state_kind: u8,
    is_busy: bool,
    is_muted: bool,
) -> MachineActionVerdict {
    let raw =
        unsafe { orb_machine_action_admitted(state_kind, u8::from(is_busy), u8::from(is_muted)) };
    MachineActionVerdict {
        is_live: (raw & 1) != 0,
        can_act: (raw & 256) != 0,
        meter_live_cost: (raw & 65536) != 0,
        is_stopped: (raw & 16_777_216) != 0,
        can_resume: (raw & 33_554_432) != 0,
        raw,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SendFlowVerdict {
    pub tap_action: u8,
    pub can_drain: bool,
    pub edit_outcome: u8,
    pub raw: u32,
}

#[inline]
pub fn send_flow_step(
    is_busy: bool,
    has_non_empty_text: bool,
    can_queue: bool,
    awaiting_ack: bool,
    is_draining: bool,
    pending_count: u8,
    http_status: u32,
) -> SendFlowVerdict {
    let raw = unsafe {
        orb_send_flow_step(
            u8::from(is_busy),
            u8::from(has_non_empty_text),
            u8::from(can_queue),
            u8::from(awaiting_ack),
            u8::from(is_draining),
            pending_count,
            http_status,
        )
    };
    SendFlowVerdict {
        tap_action: (raw & 0xFF) as u8,
        can_drain: (raw & 256) != 0,
        edit_outcome: ((raw >> 16) & 0xFF) as u8,
        raw,
    }
}

#[allow(clippy::too_many_arguments, clippy::unnecessary_cast)]
pub mod raw_cabi {
    #[inline]
    pub fn orb_verify_writer_reuse(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8) -> u8 {
        unsafe { super::orb_verify_writer_reuse(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_verify_lease_mode(a0: u8, a1: u8, a2: u8, a3: u8) -> u8 {
        unsafe { super::orb_verify_lease_mode(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_verify_track_hold(a0: u8, a1: u8, a2: u8, a3: u8) -> u8 {
        unsafe { super::orb_verify_track_hold(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_verify_repo_disjoint(a0: u8, a1: u8, a2: u8) -> u8 {
        unsafe { super::orb_verify_repo_disjoint(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_verify_remote_outbox(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u8,
        a8: u8,
    ) -> u8 {
        unsafe { super::orb_verify_remote_outbox(a0, a1, a2, a3, a4, a5, a6, a7, a8) }
    }
    #[inline]
    pub fn orb_verify_board_slots(a0: u32, a1: u32, a2: u32) -> u8 {
        unsafe { super::orb_verify_board_slots(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_verify_board_retry(a0: u32, a1: u32, a2: u8, a3: u8, a4: u8) -> u8 {
        unsafe { super::orb_verify_board_retry(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_verify_job_transition(a0: u8, a1: u8) -> u8 {
        unsafe { super::orb_verify_job_transition(a0, a1) }
    }
    #[inline]
    pub fn orb_verify_bundle_budget(a0: u8, a1: u64, a2: u64, a3: u64, a4: u64) -> u8 {
        unsafe { super::orb_verify_bundle_budget(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_verify_token_rotation(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8) -> u8 {
        unsafe { super::orb_verify_token_rotation(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_verify_approval(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8, a6: u8) -> u8 {
        unsafe { super::orb_verify_approval(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_verify_log_window(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) -> u8 {
        unsafe { super::orb_verify_log_window(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_mix64_word(a0: u64, a1: u64) -> u64 {
        unsafe { super::orb_mix64_word(a0, a1) }
    }
    #[inline]
    pub fn orb_proxy_step(a0: u8, a1: u8, a2: u8, a3: u32, a4: u32) -> u32 {
        unsafe { super::orb_proxy_step(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_stream_deadlines(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u64,
        a4: u64,
        a5: u8,
        a6: u8,
        a7: u8,
    ) -> u32 {
        unsafe { super::orb_stream_deadlines(a0, a1, a2, a3, a4, a5, a6, a7) }
    }
    #[inline]
    pub fn orb_breaker_step(a0: u8, a1: u32, a2: u32) -> u32 {
        unsafe { super::orb_breaker_step(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_mission_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u32,
        a6: u32,
        a7: u32,
        a8: u32,
        a9: u32,
    ) -> u8 {
        unsafe { super::orb_mission_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) }
    }
    #[inline]
    pub fn orb_reconcile_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u8,
        a8: u8,
        a9: u8,
        a10: u8,
        a11: u8,
        a12: u8,
    ) -> u8 {
        unsafe { super::orb_reconcile_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12) }
    }
    #[inline]
    pub fn orb_queue_step(a0: u8, a1: u8) -> u32 {
        unsafe { super::orb_queue_step(a0, a1) }
    }
    #[inline]
    pub fn orb_vm_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u8,
        a8: u32,
        a9: u32,
        a10: u32,
        a11: u32,
        a12: u32,
        a13: u64,
        a14: u64,
    ) -> u8 {
        unsafe {
            super::orb_vm_step(
                a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14,
            )
        }
    }
    #[inline]
    pub fn orb_access_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8) -> u32 {
        unsafe { super::orb_access_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_workfold_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8) -> u32 {
        unsafe { super::orb_workfold_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_taskcard_step(a0: u8, a1: u8, a2: u8) -> u8 {
        unsafe { super::orb_taskcard_step(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_sidebar_visibility(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8) -> u32 {
        unsafe { super::orb_sidebar_visibility(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_admission_step(a0: u8, a1: u8, a2: u8, a3: u64, a4: u64) -> u32 {
        unsafe { super::orb_admission_step(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_account_cooldown_secs(a0: u64, a1: u64, a2: u32) -> u64 {
        unsafe { super::orb_account_cooldown_secs(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_cost_cents_step(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u64,
        a4: u64,
        a5: u64,
        a6: u64,
        a7: u64,
    ) -> u64 {
        unsafe { super::orb_cost_cents_step(a0, a1, a2, a3, a4, a5, a6, a7) }
    }
    #[inline]
    pub fn orb_stream_loop_step(
        a0: u8,
        a1: u8,
        a2: u32,
        a3: u32,
        a4: u32,
        a5: u32,
        a6: u32,
        a7: u64,
        a8: u64,
    ) -> u8 {
        unsafe { super::orb_stream_loop_step(a0, a1, a2, a3, a4, a5, a6, a7, a8) }
    }
    #[inline]
    pub fn orb_job_ledger_step(a0: u8, a1: u8, a2: u8, a3: u8) -> u32 {
        unsafe { super::orb_job_ledger_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_proc_liveness_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u32, a5: u64, a6: u64) -> u8 {
        unsafe { super::orb_proc_liveness_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_pr_gate_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u8,
        a8: u8,
        a9: u8,
    ) -> u8 {
        unsafe { super::orb_pr_gate_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) }
    }
    #[inline]
    pub fn orb_turn_summary_step(a0: u8, a1: u8, a2: u8, a3: u8) -> u32 {
        unsafe { super::orb_turn_summary_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_usage_limit_status(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u64) -> u64 {
        unsafe { super::orb_usage_limit_status(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_relative_time_bucket(a0: u64) -> u64 {
        unsafe { super::orb_relative_time_bucket(a0) }
    }
    #[inline]
    pub fn orb_transcript_patch_step(a0: u32, a1: u32, a2: u8, a3: u32) -> u64 {
        unsafe { super::orb_transcript_patch_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_attribution_step(a0: u8, a1: u8, a2: u8, a3: u8) -> u32 {
        unsafe { super::orb_attribution_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_schedule_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u64,
        a7: u64,
        a8: u64,
    ) -> u8 {
        unsafe { super::orb_schedule_step(a0, a1, a2, a3, a4, a5, a6, a7, a8) }
    }
    #[inline]
    pub fn orb_stats_settle_step(a0: u64, a1: u64, a2: u8) -> u64 {
        unsafe { super::orb_stats_settle_step(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_privilege_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u64,
        a8: u64,
        a9: u64,
    ) -> u32 {
        unsafe { super::orb_privilege_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) }
    }
    #[inline]
    pub fn orb_bunker_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8) -> u32 {
        unsafe { super::orb_bunker_step(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_deploy_gate_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u32,
    ) -> u8 {
        unsafe { super::orb_deploy_gate_step(a0, a1, a2, a3, a4, a5, a6, a7) }
    }
    #[inline]
    pub fn orb_scroll_max_top(a0: u64, a1: u64) -> u64 {
        unsafe { super::orb_scroll_max_top(a0, a1) }
    }
    #[inline]
    pub fn orb_scroll_clamp_top(a0: u64, a1: u64, a2: u64) -> u64 {
        unsafe { super::orb_scroll_clamp_top(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_scroll_gap(a0: u64, a1: u64, a2: u64) -> u64 {
        unsafe { super::orb_scroll_gap(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_scroll_layout_step(a0: u8, a1: u64, a2: u64, a3: u64) -> u64 {
        unsafe { super::orb_scroll_layout_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_scroll_user_step(a0: u64, a1: u64, a2: u64, a3: u64) -> u8 {
        unsafe { super::orb_scroll_user_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_scroll_jump_step(a0: u64, a1: u64) -> u64 {
        unsafe { super::orb_scroll_jump_step(a0, a1) }
    }
    #[inline]
    pub fn orb_scroll_correct(a0: u8, a1: u64, a2: u64, a3: u64) -> u64 {
        unsafe { super::orb_scroll_correct(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_scroll_shows_jump(a0: u8, a1: u64, a2: u64, a3: u64, a4: u64) -> u8 {
        unsafe { super::orb_scroll_shows_jump(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_stream_coalescer_step(a0: u8, a1: u32, a2: u32, a3: u32) -> u64 {
        unsafe { super::orb_stream_coalescer_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_stream_fence_step(a0: u8, a1: u32, a2: u8, a3: u32) -> u64 {
        unsafe { super::orb_stream_fence_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_stream_commit_step(
        a0: u8,
        a1: u8,
        a2: u32,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u32,
        a7: u32,
        a8: u32,
    ) -> u64 {
        unsafe { super::orb_stream_commit_step(a0, a1, a2, a3, a4, a5, a6, a7, a8) }
    }
    #[inline]
    pub fn orb_stream_token_cost_step(a0: u64, a1: u64, a2: u64) -> u64 {
        unsafe { super::orb_stream_token_cost_step(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_mission_state_classify(a0: u8) -> u8 {
        unsafe { super::orb_mission_state_classify(a0) }
    }
    #[inline]
    pub fn orb_mission_sort_rank(a0: u8) -> u8 {
        unsafe { super::orb_mission_sort_rank(a0) }
    }
    #[inline]
    pub fn orb_mission_flags(a0: u8) -> u32 {
        unsafe { super::orb_mission_flags(a0) }
    }
    #[inline]
    pub fn orb_mission_inbox_section(a0: u8) -> u8 {
        unsafe { super::orb_mission_inbox_section(a0) }
    }
    #[inline]
    pub fn orb_connection_issue_classify(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8) -> u32 {
        unsafe { super::orb_connection_issue_classify(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_worked_duration_bucket(a0: u64) -> u64 {
        unsafe { super::orb_worked_duration_bucket(a0) }
    }
    #[inline]
    pub fn orb_turn_outcome_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8) -> u32 {
        unsafe { super::orb_turn_outcome_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_numeric_cell_scan(a0: u8, a1: u8, a2: u8, a3: u8) -> u8 {
        unsafe { super::orb_numeric_cell_scan(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_file_ref_line_span(a0: u32, a1: u32, a2: u32) -> u64 {
        unsafe { super::orb_file_ref_line_span(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_machine_action_admitted(a0: u8, a1: u8, a2: u8) -> u32 {
        unsafe { super::orb_machine_action_admitted(a0, a1, a2) }
    }
    #[inline]
    pub fn orb_send_flow_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8, a6: u32) -> u32 {
        unsafe { super::orb_send_flow_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_wire_validate_frame(
        a0: u32,
        a1: u32,
        a2: u32,
        a3: u32,
        a4: u32,
        a5: u32,
        a6: u32,
        a7: u32,
        a8: u32,
        a9: u32,
        a10: u32,
    ) -> u8 {
        unsafe { super::orb_wire_validate_frame(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10) }
    }
    #[inline]
    pub fn orb_wire_pack_record(a0: u8, a1: u8, a2: u32, a3: u32) -> u64 {
        unsafe { super::orb_wire_pack_record(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_wire_schema_migrate_step(a0: u32, a1: u32, a2: u32, a3: u64, a4: u64) -> u8 {
        unsafe { super::orb_wire_schema_migrate_step(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_effect_admissible(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u8,
        a8: u8,
        a9: u8,
        a10: u8,
        a11: u8,
    ) -> u8 {
        unsafe { super::orb_effect_admissible(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) }
    }
    #[inline]
    pub fn orb_provider_pool_step(
        a0: u8,
        a1: u32,
        a2: u32,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u32,
        a7: u32,
        a8: u64,
        a9: u64,
    ) -> u64 {
        unsafe { super::orb_provider_pool_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) }
    }
    #[inline]
    pub fn orb_route_argmin_step(a0: u8, a1: u32, a2: u64, a3: u32, a4: u64, a5: u8) -> u64 {
        unsafe { super::orb_route_argmin_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_mission_control_step(
        a0: u8,
        a1: u32,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u8,
        a8: u8,
    ) -> u64 {
        unsafe { super::orb_mission_control_step(a0, a1, a2, a3, a4, a5, a6, a7, a8) }
    }
    #[inline]
    pub fn orb_fork_home_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8, a6: u8) -> u64 {
        unsafe { super::orb_fork_home_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_privd_command_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u8,
    ) -> u64 {
        unsafe { super::orb_privd_command_step(a0, a1, a2, a3, a4, a5, a6, a7) }
    }
    #[inline]
    pub fn orb_ssh_identity_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8, a6: u8) -> u64 {
        unsafe { super::orb_ssh_identity_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_agent_event_normalize_step(
        a0: u8,
        a1: u8,
        a2: u8,
        a3: u8,
        a4: u32,
        a5: u32,
        a6: u32,
        a7: u32,
    ) -> u64 {
        unsafe { super::orb_agent_event_normalize_step(a0, a1, a2, a3, a4, a5, a6, a7) }
    }
    #[inline]
    pub fn orb_transcript_reduce_step(a0: u64, a1: u64, a2: u8, a3: u8, a4: u8) -> u64 {
        unsafe { super::orb_transcript_reduce_step(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn orb_cursor_page_step(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u32,
        a4: u32,
        a5: u32,
        a6: u32,
    ) -> u64 {
        unsafe { super::orb_cursor_page_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_sidebar_merge_step(a0: u32, a1: u32, a2: u64, a3: u64, a4: u8, a5: u8) -> u64 {
        unsafe { super::orb_sidebar_merge_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_scroll_epoch_step(
        a0: u32,
        a1: u32,
        a2: u8,
        a3: u8,
        a4: u8,
        a5: u32,
        a6: u32,
    ) -> u64 {
        unsafe { super::orb_scroll_epoch_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_client_parity_step(a0: u8, a1: u32, a2: u32, a3: u32, a4: u32, a5: u8) -> u64 {
        unsafe { super::orb_client_parity_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_vm_lifecycle_step(a0: u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8, a6: u8) -> u32 {
        unsafe { super::orb_vm_lifecycle_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_vm_claim_step(a0: u8, a1: u8, a2: u8, a3: u8) -> u32 {
        unsafe { super::orb_vm_claim_step(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_compute_secret_gate(a0: u8, a1: u8, a2: u8, a3: u8) -> u32 {
        unsafe { super::orb_compute_secret_gate(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn orb_node_gc_step(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64) -> u64 {
        unsafe { super::orb_node_gc_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_node_disk_admission_step(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u64,
        a4: u64,
        a5: u8,
    ) -> u64 {
        unsafe { super::orb_node_disk_admission_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_wire_apply_patch_step(a0: u64, a1: u64, a2: u8, a3: u32, a4: u8, a5: u32) -> u64 {
        unsafe { super::orb_wire_apply_patch_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_wire_machine_step(
        a0: u32,
        a1: u64,
        a2: u64,
        a3: u8,
        a4: u8,
        a5: u32,
        a6: u32,
    ) -> u64 {
        unsafe { super::orb_wire_machine_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_hierarchy_merge_step(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u8,
        a4: u8,
        a5: u8,
        a6: u8,
        a7: u32,
        a8: u32,
        a9: u8,
        a10: u8,
        a11: u8,
    ) -> u64 {
        unsafe { super::orb_hierarchy_merge_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) }
    }
    #[inline]
    pub fn orb_transcript_fold_step(a0: u64, a1: u64, a2: u32, a3: u8, a4: u8, a5: u8) -> u64 {
        unsafe { super::orb_transcript_fold_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn orb_outbox_crash_reconcile_step(
        a0: u32,
        a1: u32,
        a2: u32,
        a3: u64,
        a4: u64,
        a5: u32,
        a6: u32,
    ) -> u64 {
        unsafe { super::orb_outbox_crash_reconcile_step(a0, a1, a2, a3, a4, a5, a6) }
    }
    #[inline]
    pub fn orb_provider_attempt_step(
        a0: u32,
        a1: u32,
        a2: u32,
        a3: u32,
        a4: u8,
        a5: u8,
        a6: u64,
        a7: u64,
        a8: u64,
        a9: u8,
    ) -> u64 {
        unsafe { super::orb_provider_attempt_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) }
    }
    #[inline]
    pub fn orb_auth_toctou_execute_step(
        a0: u8,
        a1: u8,
        a2: u32,
        a3: u32,
        a4: u64,
        a5: u64,
        a6: u64,
        a7: u64,
        a8: u64,
        a9: u64,
    ) -> u32 {
        unsafe { super::orb_auth_toctou_execute_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) }
    }
    #[inline]
    pub fn orb_resource_ledger_step(
        a0: u8,
        a1: u32,
        a2: u32,
        a3: u32,
        a4: u64,
        a5: u64,
        a6: u64,
        a7: u64,
        a8: u64,
    ) -> u64 {
        unsafe { super::orb_resource_ledger_step(a0, a1, a2, a3, a4, a5, a6, a7, a8) }
    }
    #[inline]
    pub fn orb_stream_bounded_commit_step(
        a0: u32,
        a1: u32,
        a2: u32,
        a3: u32,
        a4: u32,
        a5: u32,
    ) -> u64 {
        unsafe { super::orb_stream_bounded_commit_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_verify_slice_bounds(a0: u64, a1: u64, a2: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_slice_bounds(a0, a1, a2) }
    }
    #[inline]
    pub fn leansys_verify_wal_frame(a0: u32, a1: u32, a2: u64, a3: u64, a4: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_wal_frame(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn leansys_verify_cas_digest(a0: u64, a1: u64, a2: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_cas_digest(a0, a1, a2) }
    }
    #[inline]
    pub fn leansys_check_http_bounds(a0: u32, a1: u64, a2: u64, a3: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_check_http_bounds(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_jsonl_tape(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u32) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_jsonl_tape(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_verify_ring_cursor(a0: u64, a1: u64, a2: u64, a3: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_ring_cursor(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_sst_block(a0: u32, a1: u32, a2: u64, a3: u64, a4: u64, a5: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_sst_block(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_verify_poll_interest(
        a0: u32,
        a1: u32,
        a2: u32,
        a3: u32,
        a4: u32,
        a5: u32,
    ) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_poll_interest(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_verify_rlimit_budget(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u64,
        a4: u64,
        a5: u64,
    ) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_rlimit_budget(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_mix64_word(a0: u64, a1: u64) -> u64 {
        unsafe { super::lean_sys_cabi::leansys_mix64_word(a0, a1) }
    }
    #[inline]
    pub fn leansys_verify_composite_key_order(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u64,
        a4: u64,
        a5: u64,
    ) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_composite_key_order(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_verify_token_auth(a0: u8, a1: u8, a2: u8, a3: u8, a4: u64, a5: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_token_auth(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_verify_log_window(a0: u64, a1: u64, a2: u64, a3: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_log_window(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_jsonrpc_frame(a0: u8, a1: u8, a2: u32, a3: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_jsonrpc_frame(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_gate_admit(a0: u8, a1: u8, a2: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_gate_admit(a0, a1, a2) }
    }
    #[inline]
    pub fn leansys_verify_mmap_seqlock(
        a0: u32,
        a1: u32,
        a2: u32,
        a3: u64,
        a4: u64,
        a5: u64,
        a6: u64,
        a7: u64,
        a8: u64,
    ) -> u8 {
        unsafe {
            super::lean_sys_cabi::leansys_verify_mmap_seqlock(a0, a1, a2, a3, a4, a5, a6, a7, a8)
        }
    }
    #[inline]
    pub fn leansys_verify_proc_stat_fields(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_proc_stat_fields(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn leansys_sse_frame_scan(a0: u64, a1: u64, a2: u64, a3: u8, a4: u8, a5: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_sse_frame_scan(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_gfm_pipe_scan(a0: u64, a1: u64, a2: u64, a3: u32, a4: u32, a5: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_gfm_pipe_scan(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_tag_scan(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_tag_scan(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_transcript_index(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) -> u64 {
        unsafe { super::lean_sys_cabi::leansys_transcript_index(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn leansys_verify_par_chunk(a0: u64, a1: u64, a2: u64, a3: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_par_chunk(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_arena_disjoint(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_arena_disjoint(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn leansys_verify_snapshot_visibility(a0: u64, a1: u64, a2: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_snapshot_visibility(a0, a1, a2) }
    }
    #[inline]
    pub fn leansys_verify_http_route_match(a0: u8, a1: u8, a2: u32, a3: u32) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_http_route_match(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_counterexample_triage(a0: u8, a1: u8, a2: u8, a3: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_counterexample_triage(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_dag_wave_step(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u64,
        a4: u64,
        a5: u64,
    ) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_dag_wave_step(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_verify_ios_jetsam_budget(a0: u64, a1: u64, a2: u64, a3: u64, a4: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_ios_jetsam_budget(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn leansys_verify_worker_budget(a0: u64, a1: u64, a2: u64, a3: u64, a4: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_worker_budget(a0, a1, a2, a3, a4) }
    }
    #[inline]
    pub fn leansys_verify_page_aligned_buffer(
        a0: u64,
        a1: u64,
        a2: u64,
        a3: u64,
        a4: u64,
        a5: u64,
    ) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_page_aligned_buffer(a0, a1, a2, a3, a4, a5) }
    }
    #[inline]
    pub fn leansys_select_isa(a0: u64, a1: u64, a2: u8, a3: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_select_isa(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_isa_selection(a0: u64, a1: u64, a2: u8, a3: u8) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_isa_selection(a0, a1, a2, a3) }
    }
    #[inline]
    pub fn leansys_verify_fd_bounds(a0: u64, a1: u32) -> u8 {
        unsafe { super::lean_sys_cabi::leansys_verify_fd_bounds(a0, a1) }
    }
    pub fn call_u64(symbol: &str, args: &[u64]) -> Option<u64> {
        Some(match symbol {
            "orb_verify_writer_reuse" if args.len() == 6 => orb_verify_writer_reuse(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
            ) as u64,
            "orb_verify_lease_mode" if args.len() == 4 => {
                orb_verify_lease_mode(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8)
                    as u64
            }
            "orb_verify_track_hold" if args.len() == 4 => {
                orb_verify_track_hold(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8)
                    as u64
            }
            "orb_verify_repo_disjoint" if args.len() == 3 => {
                orb_verify_repo_disjoint(args[0] as u8, args[1] as u8, args[2] as u8) as u64
            }
            "orb_verify_remote_outbox" if args.len() == 9 => orb_verify_remote_outbox(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
                args[8] as u8,
            ) as u64,
            "orb_verify_board_slots" if args.len() == 3 => {
                orb_verify_board_slots(args[0] as u32, args[1] as u32, args[2] as u32) as u64
            }
            "orb_verify_board_retry" if args.len() == 5 => orb_verify_board_retry(
                args[0] as u32,
                args[1] as u32,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
            ) as u64,
            "orb_verify_job_transition" if args.len() == 2 => {
                orb_verify_job_transition(args[0] as u8, args[1] as u8) as u64
            }
            "orb_verify_bundle_budget" if args.len() == 5 => orb_verify_bundle_budget(
                args[0] as u8,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
            ) as u64,
            "orb_verify_token_rotation" if args.len() == 5 => orb_verify_token_rotation(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
            ) as u64,
            "orb_verify_approval" if args.len() == 7 => orb_verify_approval(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
            ) as u64,
            "orb_verify_log_window" if args.len() == 6 => orb_verify_log_window(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u64,
            ) as u64,
            "orb_mix64_word" if args.len() == 2 => {
                orb_mix64_word(args[0] as u64, args[1] as u64) as u64
            }
            "orb_proxy_step" if args.len() == 5 => orb_proxy_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u32,
                args[4] as u32,
            ) as u64,
            "orb_stream_deadlines" if args.len() == 8 => orb_stream_deadlines(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
            ) as u64,
            "orb_breaker_step" if args.len() == 3 => {
                orb_breaker_step(args[0] as u8, args[1] as u32, args[2] as u32) as u64
            }
            "orb_mission_step" if args.len() == 10 => orb_mission_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u32,
                args[6] as u32,
                args[7] as u32,
                args[8] as u32,
                args[9] as u32,
            ) as u64,
            "orb_reconcile_step" if args.len() == 13 => orb_reconcile_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
                args[8] as u8,
                args[9] as u8,
                args[10] as u8,
                args[11] as u8,
                args[12] as u8,
            ) as u64,
            "orb_queue_step" if args.len() == 2 => {
                orb_queue_step(args[0] as u8, args[1] as u8) as u64
            }
            "orb_vm_step" if args.len() == 15 => orb_vm_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
                args[8] as u32,
                args[9] as u32,
                args[10] as u32,
                args[11] as u32,
                args[12] as u32,
                args[13] as u64,
                args[14] as u64,
            ) as u64,
            "orb_access_step" if args.len() == 6 => orb_access_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
            ) as u64,
            "orb_workfold_step" if args.len() == 6 => orb_workfold_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
            ) as u64,
            "orb_taskcard_step" if args.len() == 3 => {
                orb_taskcard_step(args[0] as u8, args[1] as u8, args[2] as u8) as u64
            }
            "orb_sidebar_visibility" if args.len() == 6 => orb_sidebar_visibility(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
            ) as u64,
            "orb_admission_step" if args.len() == 5 => orb_admission_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u64,
                args[4] as u64,
            ) as u64,
            "orb_account_cooldown_secs" if args.len() == 3 => {
                orb_account_cooldown_secs(args[0] as u64, args[1] as u64, args[2] as u32) as u64
            }
            "orb_cost_cents_step" if args.len() == 8 => orb_cost_cents_step(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u64,
                args[6] as u64,
                args[7] as u64,
            ) as u64,
            "orb_stream_loop_step" if args.len() == 9 => orb_stream_loop_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u32,
                args[3] as u32,
                args[4] as u32,
                args[5] as u32,
                args[6] as u32,
                args[7] as u64,
                args[8] as u64,
            ) as u64,
            "orb_job_ledger_step" if args.len() == 4 => {
                orb_job_ledger_step(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8)
                    as u64
            }
            "orb_proc_liveness_step" if args.len() == 7 => orb_proc_liveness_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u32,
                args[5] as u64,
                args[6] as u64,
            ) as u64,
            "orb_pr_gate_step" if args.len() == 10 => orb_pr_gate_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
                args[8] as u8,
                args[9] as u8,
            ) as u64,
            "orb_turn_summary_step" if args.len() == 4 => {
                orb_turn_summary_step(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8)
                    as u64
            }
            "orb_usage_limit_status" if args.len() == 6 => orb_usage_limit_status(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u64,
            ) as u64,
            "orb_relative_time_bucket" if args.len() == 1 => {
                orb_relative_time_bucket(args[0] as u64) as u64
            }
            "orb_transcript_patch_step" if args.len() == 4 => orb_transcript_patch_step(
                args[0] as u32,
                args[1] as u32,
                args[2] as u8,
                args[3] as u32,
            ) as u64,
            "orb_attribution_step" if args.len() == 4 => {
                orb_attribution_step(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8)
                    as u64
            }
            "orb_schedule_step" if args.len() == 9 => orb_schedule_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u64,
                args[7] as u64,
                args[8] as u64,
            ) as u64,
            "orb_stats_settle_step" if args.len() == 3 => {
                orb_stats_settle_step(args[0] as u64, args[1] as u64, args[2] as u8) as u64
            }
            "orb_privilege_step" if args.len() == 10 => orb_privilege_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u64,
                args[8] as u64,
                args[9] as u64,
            ) as u64,
            "orb_bunker_step" if args.len() == 5 => orb_bunker_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
            ) as u64,
            "orb_deploy_gate_step" if args.len() == 8 => orb_deploy_gate_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u32,
            ) as u64,
            "orb_scroll_max_top" if args.len() == 2 => {
                orb_scroll_max_top(args[0] as u64, args[1] as u64) as u64
            }
            "orb_scroll_clamp_top" if args.len() == 3 => {
                orb_scroll_clamp_top(args[0] as u64, args[1] as u64, args[2] as u64) as u64
            }
            "orb_scroll_gap" if args.len() == 3 => {
                orb_scroll_gap(args[0] as u64, args[1] as u64, args[2] as u64) as u64
            }
            "orb_scroll_layout_step" if args.len() == 4 => orb_scroll_layout_step(
                args[0] as u8,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
            ) as u64,
            "orb_scroll_user_step" if args.len() == 4 => orb_scroll_user_step(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
            ) as u64,
            "orb_scroll_jump_step" if args.len() == 2 => {
                orb_scroll_jump_step(args[0] as u64, args[1] as u64) as u64
            }
            "orb_scroll_correct" if args.len() == 4 => orb_scroll_correct(
                args[0] as u8,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
            ) as u64,
            "orb_scroll_shows_jump" if args.len() == 5 => orb_scroll_shows_jump(
                args[0] as u8,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
            ) as u64,
            "orb_stream_coalescer_step" if args.len() == 4 => orb_stream_coalescer_step(
                args[0] as u8,
                args[1] as u32,
                args[2] as u32,
                args[3] as u32,
            ) as u64,
            "orb_stream_fence_step" if args.len() == 4 => {
                orb_stream_fence_step(args[0] as u8, args[1] as u32, args[2] as u8, args[3] as u32)
                    as u64
            }
            "orb_stream_commit_step" if args.len() == 9 => orb_stream_commit_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u32,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u32,
                args[7] as u32,
                args[8] as u32,
            ) as u64,
            "orb_stream_token_cost_step" if args.len() == 3 => {
                orb_stream_token_cost_step(args[0] as u64, args[1] as u64, args[2] as u64) as u64
            }
            "orb_mission_state_classify" if args.len() == 1 => {
                orb_mission_state_classify(args[0] as u8) as u64
            }
            "orb_mission_sort_rank" if args.len() == 1 => {
                orb_mission_sort_rank(args[0] as u8) as u64
            }
            "orb_mission_flags" if args.len() == 1 => orb_mission_flags(args[0] as u8) as u64,
            "orb_mission_inbox_section" if args.len() == 1 => {
                orb_mission_inbox_section(args[0] as u8) as u64
            }
            "orb_connection_issue_classify" if args.len() == 5 => orb_connection_issue_classify(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
            ) as u64,
            "orb_worked_duration_bucket" if args.len() == 1 => {
                orb_worked_duration_bucket(args[0] as u64) as u64
            }
            "orb_turn_outcome_step" if args.len() == 6 => orb_turn_outcome_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
            ) as u64,
            "orb_numeric_cell_scan" if args.len() == 4 => {
                orb_numeric_cell_scan(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8)
                    as u64
            }
            "orb_file_ref_line_span" if args.len() == 3 => {
                orb_file_ref_line_span(args[0] as u32, args[1] as u32, args[2] as u32) as u64
            }
            "orb_machine_action_admitted" if args.len() == 3 => {
                orb_machine_action_admitted(args[0] as u8, args[1] as u8, args[2] as u8) as u64
            }
            "orb_send_flow_step" if args.len() == 7 => orb_send_flow_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u32,
            ) as u64,
            "orb_wire_validate_frame" if args.len() == 11 => orb_wire_validate_frame(
                args[0] as u32,
                args[1] as u32,
                args[2] as u32,
                args[3] as u32,
                args[4] as u32,
                args[5] as u32,
                args[6] as u32,
                args[7] as u32,
                args[8] as u32,
                args[9] as u32,
                args[10] as u32,
            ) as u64,
            "orb_wire_pack_record" if args.len() == 4 => {
                orb_wire_pack_record(args[0] as u8, args[1] as u8, args[2] as u32, args[3] as u32)
                    as u64
            }
            "orb_wire_schema_migrate_step" if args.len() == 5 => orb_wire_schema_migrate_step(
                args[0] as u32,
                args[1] as u32,
                args[2] as u32,
                args[3] as u64,
                args[4] as u64,
            ) as u64,
            "orb_effect_admissible" if args.len() == 12 => orb_effect_admissible(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
                args[8] as u8,
                args[9] as u8,
                args[10] as u8,
                args[11] as u8,
            ) as u64,
            "orb_provider_pool_step" if args.len() == 10 => orb_provider_pool_step(
                args[0] as u8,
                args[1] as u32,
                args[2] as u32,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u32,
                args[7] as u32,
                args[8] as u64,
                args[9] as u64,
            ) as u64,
            "orb_route_argmin_step" if args.len() == 6 => orb_route_argmin_step(
                args[0] as u8,
                args[1] as u32,
                args[2] as u64,
                args[3] as u32,
                args[4] as u64,
                args[5] as u8,
            ) as u64,
            "orb_mission_control_step" if args.len() == 9 => orb_mission_control_step(
                args[0] as u8,
                args[1] as u32,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
                args[8] as u8,
            ) as u64,
            "orb_fork_home_step" if args.len() == 7 => orb_fork_home_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
            ) as u64,
            "orb_privd_command_step" if args.len() == 8 => orb_privd_command_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u8,
            ) as u64,
            "orb_ssh_identity_step" if args.len() == 7 => orb_ssh_identity_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
            ) as u64,
            "orb_agent_event_normalize_step" if args.len() == 8 => orb_agent_event_normalize_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u32,
                args[5] as u32,
                args[6] as u32,
                args[7] as u32,
            ) as u64,
            "orb_transcript_reduce_step" if args.len() == 5 => orb_transcript_reduce_step(
                args[0] as u64,
                args[1] as u64,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
            ) as u64,
            "orb_cursor_page_step" if args.len() == 7 => orb_cursor_page_step(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u32,
                args[4] as u32,
                args[5] as u32,
                args[6] as u32,
            ) as u64,
            "orb_sidebar_merge_step" if args.len() == 6 => orb_sidebar_merge_step(
                args[0] as u32,
                args[1] as u32,
                args[2] as u64,
                args[3] as u64,
                args[4] as u8,
                args[5] as u8,
            ) as u64,
            "orb_scroll_epoch_step" if args.len() == 7 => orb_scroll_epoch_step(
                args[0] as u32,
                args[1] as u32,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u32,
                args[6] as u32,
            ) as u64,
            "orb_client_parity_step" if args.len() == 6 => orb_client_parity_step(
                args[0] as u8,
                args[1] as u32,
                args[2] as u32,
                args[3] as u32,
                args[4] as u32,
                args[5] as u8,
            ) as u64,
            "orb_vm_lifecycle_step" if args.len() == 7 => orb_vm_lifecycle_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
            ) as u64,
            "orb_vm_claim_step" if args.len() == 4 => {
                orb_vm_claim_step(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8) as u64
            }
            "orb_compute_secret_gate" if args.len() == 4 => {
                orb_compute_secret_gate(args[0] as u8, args[1] as u8, args[2] as u8, args[3] as u8)
                    as u64
            }
            "orb_node_gc_step" if args.len() == 7 => orb_node_gc_step(
                args[0], args[1], args[2], args[3], args[4], args[5], args[6],
            ),
            "orb_node_disk_admission_step" if args.len() == 6 => orb_node_disk_admission_step(
                args[0],
                args[1],
                args[2],
                args[3],
                args[4],
                args[5] as u8,
            ),
            "orb_wire_apply_patch_step" if args.len() == 6 => orb_wire_apply_patch_step(
                args[0],
                args[1],
                args[2] as u8,
                args[3] as u32,
                args[4] as u8,
                args[5] as u32,
            ),
            "orb_wire_machine_step" if args.len() == 7 => orb_wire_machine_step(
                args[0] as u32,
                args[1],
                args[2],
                args[3] as u8,
                args[4] as u8,
                args[5] as u32,
                args[6] as u32,
            ),
            "orb_hierarchy_merge_step" if args.len() == 12 => orb_hierarchy_merge_step(
                args[0],
                args[1],
                args[2],
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
                args[6] as u8,
                args[7] as u32,
                args[8] as u32,
                args[9] as u8,
                args[10] as u8,
                args[11] as u8,
            ),
            "orb_transcript_fold_step" if args.len() == 6 => orb_transcript_fold_step(
                args[0],
                args[1],
                args[2] as u32,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
            ),
            "orb_outbox_crash_reconcile_step" if args.len() == 7 => {
                orb_outbox_crash_reconcile_step(
                    args[0] as u32,
                    args[1] as u32,
                    args[2] as u32,
                    args[3],
                    args[4],
                    args[5] as u32,
                    args[6] as u32,
                )
            }
            "orb_provider_attempt_step" if args.len() == 10 => orb_provider_attempt_step(
                args[0] as u32,
                args[1] as u32,
                args[2] as u32,
                args[3] as u32,
                args[4] as u8,
                args[5] as u8,
                args[6],
                args[7],
                args[8],
                args[9] as u8,
            ),
            "orb_auth_toctou_execute_step" if args.len() == 10 => orb_auth_toctou_execute_step(
                args[0] as u8,
                args[1] as u8,
                args[2] as u32,
                args[3] as u32,
                args[4],
                args[5],
                args[6],
                args[7],
                args[8],
                args[9],
            ) as u64,
            "orb_resource_ledger_step" if args.len() == 9 => orb_resource_ledger_step(
                args[0] as u8,
                args[1] as u32,
                args[2] as u32,
                args[3] as u32,
                args[4],
                args[5],
                args[6],
                args[7],
                args[8],
            ),
            "orb_stream_bounded_commit_step" if args.len() == 6 => orb_stream_bounded_commit_step(
                args[0] as u32,
                args[1] as u32,
                args[2] as u32,
                args[3] as u32,
                args[4] as u32,
                args[5] as u32,
            ),
            "leansys_verify_slice_bounds" if args.len() == 3 => {
                leansys_verify_slice_bounds(args[0] as u64, args[1] as u64, args[2] as u64) as u64
            }
            "leansys_verify_wal_frame" if args.len() == 5 => leansys_verify_wal_frame(
                args[0] as u32,
                args[1] as u32,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
            ) as u64,
            "leansys_verify_cas_digest" if args.len() == 3 => {
                leansys_verify_cas_digest(args[0] as u64, args[1] as u64, args[2] as u8) as u64
            }
            "leansys_check_http_bounds" if args.len() == 4 => leansys_check_http_bounds(
                args[0] as u32,
                args[1] as u64,
                args[2] as u64,
                args[3] as u8,
            ) as u64,
            "leansys_verify_jsonl_tape" if args.len() == 6 => leansys_verify_jsonl_tape(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u32,
            ) as u64,
            "leansys_verify_ring_cursor" if args.len() == 4 => leansys_verify_ring_cursor(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
            ) as u64,
            "leansys_verify_sst_block" if args.len() == 6 => leansys_verify_sst_block(
                args[0] as u32,
                args[1] as u32,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u64,
            ) as u64,
            "leansys_verify_poll_interest" if args.len() == 6 => leansys_verify_poll_interest(
                args[0] as u32,
                args[1] as u32,
                args[2] as u32,
                args[3] as u32,
                args[4] as u32,
                args[5] as u32,
            ) as u64,
            "leansys_verify_rlimit_budget" if args.len() == 6 => leansys_verify_rlimit_budget(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u64,
            ) as u64,
            "leansys_mix64_word" if args.len() == 2 => {
                leansys_mix64_word(args[0] as u64, args[1] as u64) as u64
            }
            "leansys_verify_composite_key_order" if args.len() == 6 => {
                leansys_verify_composite_key_order(
                    args[0] as u64,
                    args[1] as u64,
                    args[2] as u64,
                    args[3] as u64,
                    args[4] as u64,
                    args[5] as u64,
                ) as u64
            }
            "leansys_verify_token_auth" if args.len() == 6 => leansys_verify_token_auth(
                args[0] as u8,
                args[1] as u8,
                args[2] as u8,
                args[3] as u8,
                args[4] as u64,
                args[5] as u64,
            ) as u64,
            "leansys_verify_log_window" if args.len() == 4 => leansys_verify_log_window(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
            ) as u64,
            "leansys_verify_jsonrpc_frame" if args.len() == 4 => leansys_verify_jsonrpc_frame(
                args[0] as u8,
                args[1] as u8,
                args[2] as u32,
                args[3] as u64,
            ) as u64,
            "leansys_gate_admit" if args.len() == 3 => {
                leansys_gate_admit(args[0] as u8, args[1] as u8, args[2] as u8) as u64
            }
            "leansys_verify_mmap_seqlock" if args.len() == 9 => leansys_verify_mmap_seqlock(
                args[0] as u32,
                args[1] as u32,
                args[2] as u32,
                args[3] as u64,
                args[4] as u64,
                args[5] as u64,
                args[6] as u64,
                args[7] as u64,
                args[8] as u64,
            ) as u64,
            "leansys_verify_proc_stat_fields" if args.len() == 5 => {
                leansys_verify_proc_stat_fields(
                    args[0] as u64,
                    args[1] as u64,
                    args[2] as u64,
                    args[3] as u64,
                    args[4] as u64,
                ) as u64
            }
            "leansys_sse_frame_scan" if args.len() == 6 => leansys_sse_frame_scan(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u8,
                args[4] as u8,
                args[5] as u8,
            ) as u64,
            "leansys_gfm_pipe_scan" if args.len() == 6 => leansys_gfm_pipe_scan(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u32,
                args[4] as u32,
                args[5] as u8,
            ) as u64,
            "leansys_tag_scan" if args.len() == 6 => leansys_tag_scan(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u8,
            ) as u64,
            "leansys_transcript_index" if args.len() == 5 => leansys_transcript_index(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
            ) as u64,
            "leansys_verify_par_chunk" if args.len() == 4 => leansys_verify_par_chunk(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
            ) as u64,
            "leansys_verify_arena_disjoint" if args.len() == 5 => leansys_verify_arena_disjoint(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
            ) as u64,
            "leansys_verify_snapshot_visibility" if args.len() == 3 => {
                leansys_verify_snapshot_visibility(args[0] as u64, args[1] as u64, args[2] as u8)
                    as u64
            }
            "leansys_verify_http_route_match" if args.len() == 4 => {
                leansys_verify_http_route_match(
                    args[0] as u8,
                    args[1] as u8,
                    args[2] as u32,
                    args[3] as u32,
                ) as u64
            }
            "leansys_verify_counterexample_triage" if args.len() == 4 => {
                leansys_verify_counterexample_triage(
                    args[0] as u8,
                    args[1] as u8,
                    args[2] as u8,
                    args[3] as u8,
                ) as u64
            }
            "leansys_verify_dag_wave_step" if args.len() == 6 => leansys_verify_dag_wave_step(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u64,
                args[5] as u64,
            ) as u64,
            "leansys_verify_ios_jetsam_budget" if args.len() == 5 => {
                leansys_verify_ios_jetsam_budget(
                    args[0] as u64,
                    args[1] as u64,
                    args[2] as u64,
                    args[3] as u64,
                    args[4] as u8,
                ) as u64
            }
            "leansys_verify_worker_budget" if args.len() == 5 => leansys_verify_worker_budget(
                args[0] as u64,
                args[1] as u64,
                args[2] as u64,
                args[3] as u64,
                args[4] as u8,
            ) as u64,
            "leansys_verify_page_aligned_buffer" if args.len() == 6 => {
                leansys_verify_page_aligned_buffer(
                    args[0] as u64,
                    args[1] as u64,
                    args[2] as u64,
                    args[3] as u64,
                    args[4] as u64,
                    args[5] as u64,
                ) as u64
            }
            "leansys_select_isa" if args.len() == 4 => {
                leansys_select_isa(args[0] as u64, args[1] as u64, args[2] as u8, args[3] as u8)
                    as u64
            }
            "leansys_verify_isa_selection" if args.len() == 4 => leansys_verify_isa_selection(
                args[0] as u64,
                args[1] as u64,
                args[2] as u8,
                args[3] as u8,
            ) as u64,
            "leansys_verify_fd_bounds" if args.len() == 2 => {
                leansys_verify_fd_bounds(args[0] as u64, args[1] as u32) as u64
            }
            _ => return None,
        })
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
    fn approval_gate_needs_every_condition_and_confirms_critical() {
        let ok = ApprovalAdmission {
            signed: true,
            owned: true,
            pending: true,
            unexpired: true,
            unchanged: true,
            risk: ApprovalRisk::Elevated,
            confirmed: false,
        };
        assert!(approval_admitted(ok));
        for bad in [
            ApprovalAdmission {
                signed: false,
                ..ok
            },
            ApprovalAdmission { owned: false, ..ok },
            ApprovalAdmission {
                pending: false,
                ..ok
            },
            ApprovalAdmission {
                unexpired: false,
                ..ok
            },
            ApprovalAdmission {
                unchanged: false,
                ..ok
            },
            ApprovalAdmission {
                risk: ApprovalRisk::Critical,
                ..ok
            },
        ] {
            assert!(!approval_admitted(bad), "{bad:?}");
        }
        assert!(approval_admitted(ApprovalAdmission {
            risk: ApprovalRisk::Critical,
            confirmed: true,
            ..ok
        }));
    }

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

    #[test]
    fn wave12_node_disk_pressure_and_placement_kernels_match_specs() {
        const GIB: u64 = 1 << 30;

        // 1. Healthy node (`free >= floor`) keeps 72h grace and performs zero evictions.
        let healthy = node_gc_step(NodeGcStepInput {
            free_bytes: 95 * GIB,
            floor_bytes: 80 * GIB,
            emergency_floor_bytes: 10 * GIB,
            aged_scratch_bytes: 12 * GIB,
            fresh_scratch_bytes: 4 * GIB,
            cold_cache_bytes: 20 * GIB,
            hot_cache_bytes: 15 * GIB,
        });
        assert_eq!(healthy.action, NodeGcAction::Healthy);
        assert!(!healthy.sweep_aged_scratch);
        assert!(!healthy.evict_cold_cache);
        assert!(!healthy.sweep_fresh_scratch);
        assert!(!healthy.evict_hot_cache);
        assert!(!healthy.pinned_pressure);
        assert_eq!(healthy.retired_grace_hours, 72);

        // 2. Aged retired scratch alone covers deficit -> 6h grace, caches untouched.
        let aged_only = node_gc_step(NodeGcStepInput {
            free_bytes: 72 * GIB,
            floor_bytes: 80 * GIB,
            emergency_floor_bytes: 10 * GIB,
            aged_scratch_bytes: 10 * GIB,
            fresh_scratch_bytes: 4 * GIB,
            cold_cache_bytes: 20 * GIB,
            hot_cache_bytes: 15 * GIB,
        });
        assert_eq!(aged_only.action, NodeGcAction::SweepAgedScratch);
        assert!(aged_only.sweep_aged_scratch);
        assert!(!aged_only.evict_cold_cache);
        assert!(!aged_only.sweep_fresh_scratch);
        assert!(!aged_only.evict_hot_cache);
        assert!(!aged_only.pinned_pressure);
        assert_eq!(aged_only.retired_grace_hours, 6);

        // 3. Aged scratch + cold caches cover deficit -> warm `< 6h` scratch and `< 2h` hot caches untouched.
        let cold_enough = node_gc_step(NodeGcStepInput {
            free_bytes: 60 * GIB,
            floor_bytes: 80 * GIB,
            emergency_floor_bytes: 10 * GIB,
            aged_scratch_bytes: 5 * GIB,
            fresh_scratch_bytes: 8 * GIB,
            cold_cache_bytes: 18 * GIB,
            hot_cache_bytes: 15 * GIB,
        });
        assert_eq!(cold_enough.action, NodeGcAction::EvictColdCaches);
        assert!(cold_enough.sweep_aged_scratch);
        assert!(cold_enough.evict_cold_cache);
        assert!(!cold_enough.sweep_fresh_scratch);
        assert!(!cold_enough.evict_hot_cache);
        assert!(!cold_enough.pinned_pressure);
        assert_eq!(cold_enough.retired_grace_hours, 6);

        // 4. Fresh `< 6h` retired scratch covers remaining deficit BEFORE hot `< 2h` Lake caches!
        let fresh_saves_hot = node_gc_step(NodeGcStepInput {
            free_bytes: 60 * GIB,
            floor_bytes: 80 * GIB,
            emergency_floor_bytes: 10 * GIB,
            aged_scratch_bytes: 5 * GIB,
            fresh_scratch_bytes: 10 * GIB,
            cold_cache_bytes: 8 * GIB,
            hot_cache_bytes: 25 * GIB,
        });
        assert_eq!(fresh_saves_hot.action, NodeGcAction::SweepAllRetiredScratch);
        assert!(fresh_saves_hot.sweep_aged_scratch);
        assert!(fresh_saves_hot.evict_cold_cache);
        assert!(fresh_saves_hot.sweep_fresh_scratch);
        assert!(!fresh_saves_hot.evict_hot_cache);
        assert!(!fresh_saves_hot.pinned_pressure);
        assert_eq!(fresh_saves_hot.retired_grace_hours, 0);

        // 5. Ashur incident (`node_gc_preserves_hot_cache_when_pinned_above_emergency`):
        //    50 GiB free vs 80 GiB floor, only 10 GiB hot cache -> non-cache storage pins node
        //    below floor; hot caches are PRESERVED (`evict_hot_cache == false`) and `pinned_pressure == true`.
        let ashur_pinned = node_gc_step(NodeGcStepInput {
            free_bytes: 50 * GIB,
            floor_bytes: 80 * GIB,
            emergency_floor_bytes: 10 * GIB,
            aged_scratch_bytes: 2 * GIB,
            fresh_scratch_bytes: GIB,
            cold_cache_bytes: 4 * GIB,
            hot_cache_bytes: 10 * GIB,
        });
        assert_eq!(ashur_pinned.action, NodeGcAction::PinnedPreserveHot);
        assert!(ashur_pinned.sweep_aged_scratch);
        assert!(ashur_pinned.evict_cold_cache);
        assert!(ashur_pinned.sweep_fresh_scratch);
        assert!(!ashur_pinned.evict_hot_cache);
        assert!(ashur_pinned.pinned_pressure);
        assert_eq!(ashur_pinned.retired_grace_hours, 0);

        // 6. Emergency survival (`node_gc_emergency_evicts_hot_cache`):
        //    8 GiB free < 10 GiB emergency floor -> hot caches ARE evicted even though pinned.
        let emergency = node_gc_step(NodeGcStepInput {
            free_bytes: 8 * GIB,
            floor_bytes: 80 * GIB,
            emergency_floor_bytes: 10 * GIB,
            aged_scratch_bytes: 0,
            fresh_scratch_bytes: 0,
            cold_cache_bytes: 0,
            hot_cache_bytes: 5 * GIB,
        });
        assert_eq!(emergency.action, NodeGcAction::EvictHotCaches);
        assert!(emergency.evict_hot_cache);
        assert!(emergency.pinned_pressure);
        assert_eq!(emergency.retired_grace_hours, 0);

        // 7. 64-bit overflow safety at `u64::MAX` byte counts.
        let max_safe = node_gc_step(NodeGcStepInput {
            free_bytes: 0,
            floor_bytes: u64::MAX,
            emergency_floor_bytes: 10 * GIB,
            aged_scratch_bytes: u64::MAX / 2,
            fresh_scratch_bytes: u64::MAX / 2,
            cold_cache_bytes: 0,
            hot_cache_bytes: 1,
        });
        assert_eq!(max_safe.action, NodeGcAction::EvictHotCaches);
        assert!(max_safe.evict_hot_cache);

        // 8. Core placement admission (`node_disk_admission_step`):
        //    - Rejects node when `free < node_floor` even if `free >= core_floor` (Ashur 50 GiB < 80 GiB vs 20 GiB).
        let reject_floor = node_disk_admission_step(NodeDiskAdmissionInput {
            free_bytes: 50 * GIB,
            reserved_bytes: 0,
            node_floor_bytes: 80 * GIB,
            core_floor_bytes: 20 * GIB,
            hysteresis_bytes: 20 * GIB,
            node_pinned_pressure: false,
        });
        assert_eq!(
            reject_floor.action,
            NodeDiskAdmissionAction::RejectBelowFloor
        );
        assert!(!reject_floor.admitted);

        //    - Rejects pinned pressure even if nominal bytes look above Core floor.
        let reject_pinned = node_disk_admission_step(NodeDiskAdmissionInput {
            free_bytes: 50 * GIB,
            reserved_bytes: 0,
            node_floor_bytes: 30 * GIB,
            core_floor_bytes: 20 * GIB,
            hysteresis_bytes: 20 * GIB,
            node_pinned_pressure: true,
        });
        assert_eq!(
            reject_pinned.action,
            NodeDiskAdmissionAction::RejectPinnedPressure
        );
        assert!(!reject_pinned.admitted);

        //    - Admits within hysteresis band (`42 GiB - 30 GiB = 12 GiB < 20 GiB`) with `soft_pressure = true`.
        let soft = node_disk_admission_step(NodeDiskAdmissionInput {
            free_bytes: 42 * GIB,
            reserved_bytes: 0,
            node_floor_bytes: 30 * GIB,
            core_floor_bytes: 20 * GIB,
            hysteresis_bytes: 20 * GIB,
            node_pinned_pressure: false,
        });
        assert_eq!(soft.action, NodeDiskAdmissionAction::Admit);
        assert!(soft.admitted);
        assert!(soft.soft_pressure);
        assert_eq!(soft.headroom_gib, 12);

        //    - Admits comfortably (`280 GiB - 30 GiB = 250 GiB >= 20 GiB`) with `soft_pressure = false`.
        let comfortable = node_disk_admission_step(NodeDiskAdmissionInput {
            free_bytes: 280 * GIB,
            reserved_bytes: 0,
            node_floor_bytes: 30 * GIB,
            core_floor_bytes: 20 * GIB,
            hysteresis_bytes: 20 * GIB,
            node_pinned_pressure: false,
        });
        assert_eq!(comfortable.action, NodeDiskAdmissionAction::Admit);
        assert!(comfortable.admitted);
        assert!(!comfortable.soft_pressure);
        assert_eq!(comfortable.headroom_gib, 250);
    }
    #[test]
    fn mobile_and_leansys_extensions_roundtrip_via_cabi() {
        assert_eq!(scroll_max_top(1000, 400), 600);
        assert_eq!(scroll_clamp_top(1000, 400, 900), 600);
        assert_eq!(scroll_gap(1000, 400, 550), 50);
        assert_eq!(scroll_layout_step(true, 1000, 400, 100), 600);
        assert!(scroll_user_step(1000, 400, 580, 24));
        assert_eq!(scroll_jump_step(1000, 400), 600);
        assert_eq!(scroll_correct(false, 1000, 400, 900), 600);
        assert!(scroll_shows_jump(false, 1000, 400, 100, 40));

        let coal = stream_coalescer_step(1, 10, 5, 0);
        assert!(coal.did_render);
        assert_eq!(coal.next_shown_len, 15);
        assert_eq!(coal.next_pending_len, 0);

        let fence = stream_fence_step(0, 0, 1, 3);
        assert_eq!(fence.next_fence_kind, 1);
        assert_eq!(fence.next_fence_count, 3);

        let commit = stream_commit_step(false, 0, 0, true, false, 0, 0, 4, 0);
        assert!(commit.commits);
        assert_eq!(commit.next_commit, 5);
        assert_eq!(stream_token_cost_step(10, 20, 5), 35);

        assert_eq!(mission_state_classify(0), 3);
        assert_eq!(mission_sort_rank(11), 0);
        let flags = mission_flags(17);
        assert!(flags.is_terminal && flags.can_retry && flags.is_problem);
        assert_eq!(mission_inbox_section(25), 2);

        let conn = connection_issue_classify(true, false, true, true, false);
        assert!(conn.show_issue && conn.recommend_default && conn.should_probe_default);
        assert_eq!(conn.message_kind, 2);

        let dur = worked_duration_bucket(3660);
        assert_eq!((dur.unit, dur.primary, dur.secondary), (2, 1, 1));

        let out = turn_outcome_step(false, false, 2, false, false, true);
        assert!(out.next_outcome_finished && !out.next_todos_failed);
        assert!(numeric_cell_scan(true, true, true, true));

        let span = file_ref_line_span(10, 12, 100);
        assert!(span.admitted);
        assert_eq!(span.span_line_count, 3);

        let mach = machine_action_admitted(2, false, false);
        assert!(mach.is_live && mach.can_act && mach.meter_live_cost);

        let send = send_flow_step(false, true, true, false, false, 1, 200);
        assert_eq!(send.tap_action, 1);
        assert!(send.can_drain);
        assert_eq!(send.edit_outcome, 1);

        assert!(lean_sys_cabi::verify_par_chunk(0, 64, 256, 64));
        assert!(lean_sys_cabi::verify_arena_disjoint(0, 128, 128, 128, 256));
        assert!(lean_sys_cabi::verify_snapshot_visibility(2, 5, false));
        assert!(lean_sys_cabi::verify_http_route_match(true, true, 0, 4));
        assert!(lean_sys_cabi::verify_counterexample_triage(
            true, true, false, 1
        ));
        assert!(lean_sys_cabi::verify_dag_wave_step(0, 4, 8, 16, 4, 4));

        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../../../shared/orb-spec/kernel_abi.json")).unwrap();
        let mut count = 0usize;
        for f in manifest["functions"].as_array().unwrap() {
            let name = f["name"].as_str().unwrap();
            if name.starts_with("orb_") || name.starts_with("leansys_") {
                let arity = f["params"].as_array().unwrap().len();
                let args = vec![0u64; arity];
                assert!(raw_cabi::call_u64(name, &args).is_some(), "missing {name}");
                count += 1;
            }
        }
        assert_eq!(count, 127);
    }
}

// Wave 12 (P4–P6): Compositional OrbWire Patch/Machine Steppers &
//                  7 Stateful Domain Transition Families (`G-ORB-1..7`)
// ═══════════════════════════════════════════════════════════════════════════

/// Tri-state field presence tag (`Orb.Spec.FieldPresence`) distinguishing omitted (`None`),
/// explicit update (`Some(val)`), and explicit clear (`Cleared`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FieldPresenceTag {
    Omitted = 0,
    Present = 1,
    Cleared = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireApplyPatchInput {
    pub current_rev: u64,
    pub incoming_rev: u64,
    pub current_val: Option<u32>,
    pub presence: FieldPresenceTag,
    pub incoming_val: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireApplyPatchVerdict {
    pub raw: u64,
    pub action_code: u8,
    pub admitted: bool,
    pub next_val: Option<u32>,
}

/// Typed wrapper over `orb_wire_apply_patch_step`.
#[inline]
pub fn wire_apply_patch_step(input: WireApplyPatchInput) -> WireApplyPatchVerdict {
    let raw = unsafe {
        orb_wire_apply_patch_step(
            input.current_rev,
            input.incoming_rev,
            u8::from(input.current_val.is_some()),
            input.current_val.unwrap_or(0),
            input.presence as u8,
            input.incoming_val,
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    let hi32 = (raw >> 32) as u32;
    let has_val = ((lo32 >> 9) & 1) != 0;
    WireApplyPatchVerdict {
        raw,
        action_code: (lo32 & 0xFF) as u8,
        admitted: ((lo32 >> 8) & 1) != 0,
        next_val: if has_val { Some(hi32) } else { None },
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireMachineStepInput {
    pub schema_id: u32,
    pub state_rev: u64,
    pub event_seq: u64,
    pub effect_kind: u8,
    pub effect_admitted: bool,
    pub out_cap: u32,
    pub required_out_bytes: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireMachineStepVerdict {
    pub raw: u64,
    pub action_code: u8,
    pub admitted: bool,
    pub emit_effect: bool,
    pub next_rev32: u32,
}

/// Typed wrapper over `orb_wire_machine_step`.
#[inline]
pub fn wire_machine_step(input: WireMachineStepInput) -> WireMachineStepVerdict {
    let raw = unsafe {
        orb_wire_machine_step(
            input.schema_id,
            input.state_rev,
            input.event_seq,
            input.effect_kind,
            u8::from(input.effect_admitted),
            input.out_cap,
            input.required_out_bytes,
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    WireMachineStepVerdict {
        raw,
        action_code: (lo32 & 0xFF) as u8,
        admitted: ((lo32 >> 8) & 1) != 0,
        emit_effect: ((lo32 >> 9) & 1) != 0,
        next_rev32: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HierarchyMergeStepInput {
    pub current_epoch: u64,
    pub incoming_epoch: u64,
    pub archive_epoch: u64,
    pub cur_archived: bool,
    pub cur_superseded: bool,
    pub is_partial_patch: bool,
    pub parent_presence: FieldPresenceTag,
    pub cur_parent_ord: u32,
    pub inc_parent_ord: u32,
    pub inc_archive: bool,
    pub inc_unarchive: bool,
    pub inc_supersede: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HierarchyMergeStepVerdict {
    pub raw: u64,
    pub action_code: u8,
    pub admitted: bool,
    pub next_archived: bool,
    pub next_superseded: bool,
    pub unarchived: bool,
    pub next_parent_ord: u32,
}

/// Family 1 (`G-ORB-5`): Typed wrapper over `orb_hierarchy_merge_step`.
#[inline]
pub fn hierarchy_merge_step(input: HierarchyMergeStepInput) -> HierarchyMergeStepVerdict {
    let raw = unsafe {
        orb_hierarchy_merge_step(
            input.current_epoch,
            input.incoming_epoch,
            input.archive_epoch,
            u8::from(input.cur_archived),
            u8::from(input.cur_superseded),
            u8::from(input.is_partial_patch),
            input.parent_presence as u8,
            input.cur_parent_ord,
            input.inc_parent_ord,
            u8::from(input.inc_archive),
            u8::from(input.inc_unarchive),
            u8::from(input.inc_supersede),
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    HierarchyMergeStepVerdict {
        raw,
        action_code: (lo32 & 0xFF) as u8,
        admitted: ((lo32 >> 8) & 1) != 0,
        next_archived: ((lo32 >> 9) & 1) != 0,
        next_superseded: ((lo32 >> 10) & 1) != 0,
        unarchived: ((lo32 >> 11) & 1) != 0,
        next_parent_ord: (raw >> 32) as u32,
    }
}

/// Observe `hierarchy_merge_step` (`orb_hierarchy_merge_step`) against a host merge decision.
pub fn observe_hierarchy_merge_shadow(
    input: HierarchyMergeStepInput,
    host_admitted: bool,
    host_next_parent_ord: u32,
    counter: &ShadowCounter,
) -> HierarchyMergeStepVerdict {
    let verdict = hierarchy_merge_step(input);
    let sim =
        shadow::RefinementSimulation::<(bool, u32), (bool, u32), HierarchyMergeStepInput, u8, u8> {
            subsystem: "orb_hierarchy_merge_step",
            abs_state: |s| *s,
            norm_effects: |effs| effs.to_vec(),
            lean_step: |_s, ev, _ctx| {
                let v = hierarchy_merge_step(*ev);
                ((v.admitted, v.next_parent_ord), vec![v.action_code])
            },
            classify_known_legacy_bug: |_, _, _, _| None,
        };
    let host_eff = vec![if host_admitted { 1u8 } else { 2u8 }];
    let ctx = shadow::EventContext {
        now_ms: input.incoming_epoch,
        fresh_nonce: input.current_epoch,
        idempotency_key: input.incoming_epoch,
        boot_id_matches: true,
        schema_id: 2,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &(false, input.cur_parent_ord),
            &(host_admitted, host_next_parent_ord),
            &input,
            &host_eff,
            ctx,
            &mut ring,
        );
    }
    verdict
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptFoldStepInput {
    pub last_applied_seq: u64,
    pub incoming_seq: u64,
    pub entry_count: u32,
    pub thinking_open: bool,
    pub normalized_action: u8,
    pub is_replay_from_log: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptFoldStepVerdict {
    pub raw: u64,
    pub action_code: u8,
    pub admitted: bool,
    pub thinking_open_next: bool,
    pub closed_previous_thinking: bool,
    pub gap_buffered: bool,
    pub next_entry_count: u32,
}

/// Family 2 (`G-ORB-3`): Typed wrapper over `orb_transcript_fold_step`.
#[inline]
pub fn transcript_fold_step(input: TranscriptFoldStepInput) -> TranscriptFoldStepVerdict {
    let raw = unsafe {
        orb_transcript_fold_step(
            input.last_applied_seq,
            input.incoming_seq,
            input.entry_count,
            u8::from(input.thinking_open),
            input.normalized_action,
            u8::from(input.is_replay_from_log),
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    TranscriptFoldStepVerdict {
        raw,
        action_code: (lo32 & 0xFF) as u8,
        admitted: ((lo32 >> 8) & 1) != 0,
        thinking_open_next: ((lo32 >> 9) & 1) != 0,
        closed_previous_thinking: ((lo32 >> 10) & 1) != 0,
        gap_buffered: ((lo32 >> 11) & 1) != 0,
        next_entry_count: (raw >> 32) as u32,
    }
}

/// Observe `transcript_fold_step` (`orb_transcript_fold_step`) against host fold progression.
pub fn observe_transcript_fold_shadow(
    input: TranscriptFoldStepInput,
    host_admitted: bool,
    host_next_entry_count: u32,
    host_action_code: u8,
    counter: &ShadowCounter,
) -> TranscriptFoldStepVerdict {
    let verdict = transcript_fold_step(input);
    let sim =
        shadow::RefinementSimulation::<(bool, u32), (bool, u32), TranscriptFoldStepInput, u8, u8> {
            subsystem: "orb_transcript_fold_step",
            abs_state: |s| *s,
            norm_effects: |effs| effs.to_vec(),
            lean_step: |_s, ev, _ctx| {
                let v = transcript_fold_step(*ev);
                ((v.admitted, v.next_entry_count), vec![v.action_code])
            },
            classify_known_legacy_bug: |_, _, _, _| None,
        };
    let ctx = shadow::EventContext {
        now_ms: 0,
        fresh_nonce: input.incoming_seq,
        idempotency_key: input.incoming_seq,
        boot_id_matches: true,
        schema_id: 2,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &(false, input.entry_count),
            &(host_admitted, host_next_entry_count),
            &input,
            &[host_action_code],
            ctx,
            &mut ring,
        );
    }
    verdict
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutboxCrashReconcileInput {
    pub durable_queued: u32,
    pub durable_acked: u32,
    pub volatile_in_flight: u32,
    pub lease_boot_epoch: u64,
    pub node_boot_epoch: u64,
    pub volatile_lease_owner: u32,
    pub req_owner: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutboxCrashReconcileVerdict {
    pub raw: u64,
    pub action_code: u8,
    pub admitted: bool,
    pub crash_reconciled: bool,
    pub has_single_writer: bool,
    pub unacked_depth: u32,
}

/// Family 3 (`G-ORB-2`): Typed wrapper over `orb_outbox_crash_reconcile_step`.
#[inline]
pub fn outbox_crash_reconcile_step(
    input: OutboxCrashReconcileInput,
) -> OutboxCrashReconcileVerdict {
    let raw = unsafe {
        orb_outbox_crash_reconcile_step(
            input.durable_queued,
            input.durable_acked,
            input.volatile_in_flight,
            input.lease_boot_epoch,
            input.node_boot_epoch,
            input.volatile_lease_owner,
            input.req_owner,
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    OutboxCrashReconcileVerdict {
        raw,
        action_code: (lo32 & 0xFF) as u8,
        admitted: ((lo32 >> 8) & 1) != 0,
        crash_reconciled: ((lo32 >> 9) & 1) != 0,
        has_single_writer: ((lo32 >> 10) & 1) != 0,
        unacked_depth: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderAttemptStepInput {
    pub pinned_account_id: u32,
    pub candidate_account_id: u32,
    pub attempts_used: u32,
    pub retry_budget: u32,
    pub first_byte_committed: bool,
    pub failure_kind: u8,
    pub upstream_now_epoch: u64,
    pub cooldown_until_epoch: u64,
    pub upstream_deadline: u64,
    pub auth_valid: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderAttemptStepVerdict {
    pub raw: u64,
    pub action_code: u8,
    pub admitted: bool,
    pub first_byte_locked_next: bool,
    pub next_attempts_used: u32,
}

/// Family 4 (`G-ORB-2`): Typed wrapper over `orb_provider_attempt_step`.
#[inline]
pub fn provider_attempt_step(input: ProviderAttemptStepInput) -> ProviderAttemptStepVerdict {
    let raw = unsafe {
        orb_provider_attempt_step(
            input.pinned_account_id,
            input.candidate_account_id,
            input.attempts_used,
            input.retry_budget,
            u8::from(input.first_byte_committed),
            input.failure_kind,
            input.upstream_now_epoch,
            input.cooldown_until_epoch,
            input.upstream_deadline,
            u8::from(input.auth_valid),
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    ProviderAttemptStepVerdict {
        raw,
        action_code: (lo32 & 0xFF) as u8,
        admitted: ((lo32 >> 8) & 1) != 0,
        first_byte_locked_next: ((lo32 >> 9) & 1) != 0,
        next_attempts_used: (raw >> 32) as u32,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthToctouExecuteInput {
    pub principal_kind: u8,
    pub bunker_state: BunkerState,
    pub observed_target_id: u32,
    pub exec_target_id: u32,
    pub observed_lease_epoch: u64,
    pub live_lease_epoch: u64,
    pub now_tick: u64,
    pub expiry_tick: u64,
    pub observed_digest: u64,
    pub exec_digest: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthToctouExecuteVerdict {
    pub raw: u32,
    pub admitted: bool,
    pub fail_closed: bool,
    pub reason_code: u8,
}

/// Family 5 (`G-ORB-7`): Typed wrapper over `orb_auth_toctou_execute_step`.
#[inline]
pub fn auth_toctou_execute_step(input: AuthToctouExecuteInput) -> AuthToctouExecuteVerdict {
    let raw = unsafe {
        orb_auth_toctou_execute_step(
            input.principal_kind,
            input.bunker_state as u8,
            input.observed_target_id,
            input.exec_target_id,
            input.observed_lease_epoch,
            input.live_lease_epoch,
            input.now_tick,
            input.expiry_tick,
            input.observed_digest,
            input.exec_digest,
        )
    };
    AuthToctouExecuteVerdict {
        raw,
        admitted: ((raw >> 8) & 1) != 0,
        fail_closed: ((raw >> 9) & 1) != 0,
        reason_code: (raw & 0xFF) as u8,
    }
}

/// Observe `auth_toctou_execute_step` (`orb_auth_toctou_execute_step`) against host TOCTOU enforcement.
pub fn observe_auth_toctou_shadow(
    input: AuthToctouExecuteInput,
    host_admitted: bool,
    host_reason_code: u8,
    counter: &ShadowCounter,
) -> AuthToctouExecuteVerdict {
    let verdict = auth_toctou_execute_step(input);
    let sim = shadow::RefinementSimulation::<bool, bool, AuthToctouExecuteInput, u8, u8> {
        subsystem: "orb_auth_toctou_execute_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = auth_toctou_execute_step(*ev);
            (v.admitted, vec![v.reason_code])
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let ctx = shadow::EventContext {
        now_ms: input.now_tick,
        fresh_nonce: input.observed_lease_epoch,
        idempotency_key: input.observed_digest,
        boot_id_matches: true,
        schema_id: 2,
    };
    if let Ok(mut ring) = counter.ring.lock() {
        let _ = sim.observe_step(
            &false,
            &host_admitted,
            &input,
            &[host_reason_code],
            ctx,
            &mut ring,
        );
    }
    verdict
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ResourceLedgerOp {
    Reserve = 0,
    ActivateReserved = 1,
    ReleaseActive = 2,
    ReapExpired = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResourceLedgerStepInput {
    pub op_kind: ResourceLedgerOp,
    pub reserved_slots: u32,
    pub active_slots: u32,
    pub max_slots: u32,
    pub spent_cents: u64,
    pub cost_delta_cents: u64,
    pub budget_cents: u64,
    pub now_tick: u64,
    pub ttl_expiry_tick: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResourceLedgerStepVerdict {
    pub raw: u64,
    pub state_valid: bool,
    pub admitted: bool,
    pub next_reserved_slots: u16,
    pub next_active_slots: u16,
}

/// Family 6 (`G-ORB-3`): Typed wrapper over `orb_resource_ledger_step`.
#[inline]
pub fn resource_ledger_step(input: ResourceLedgerStepInput) -> ResourceLedgerStepVerdict {
    let raw = unsafe {
        orb_resource_ledger_step(
            input.op_kind as u8,
            input.reserved_slots,
            input.active_slots,
            input.max_slots,
            input.spent_cents,
            input.cost_delta_cents,
            input.budget_cents,
            input.now_tick,
            input.ttl_expiry_tick,
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    let hi32 = (raw >> 32) as u32;
    ResourceLedgerStepVerdict {
        raw,
        state_valid: lo32 != 0,
        admitted: ((lo32 >> 8) & 1) != 0,
        next_reserved_slots: (hi32 & 0xFFFF) as u16,
        next_active_slots: ((hi32 >> 16) & 0xFFFF) as u16,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamBoundedCommitInput {
    pub prev_len: u32,
    pub prev_commit: u32,
    pub prev_checkpoint: u32,
    pub new_len: u32,
    pub raw_commit: u32,
    pub max_open_tail_bytes: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamBoundedCommitVerdict {
    pub raw: u64,
    pub admitted: bool,
    pub checkpoint_forced: bool,
    pub next_checkpoint: u32,
}

/// Family 7 (`G-ORB-6`): Typed wrapper over `orb_stream_bounded_commit_step`.
#[inline]
pub fn stream_bounded_commit_step(input: StreamBoundedCommitInput) -> StreamBoundedCommitVerdict {
    let raw = unsafe {
        orb_stream_bounded_commit_step(
            input.prev_len,
            input.prev_commit,
            input.prev_checkpoint,
            input.new_len,
            input.raw_commit,
            input.max_open_tail_bytes,
        )
    };
    let lo32 = (raw & 0xFFFF_FFFF) as u32;
    StreamBoundedCommitVerdict {
        raw,
        admitted: ((lo32 >> 8) & 1) != 0,
        checkpoint_forced: ((lo32 >> 9) & 1) != 0,
        next_checkpoint: (raw >> 32) as u32,
    }
}

#[cfg(test)]
mod stateful_tests {
    use super::*;
    use crate::shadow::{
        apply_patch_frame, execute_wire_machine_frame, OrbWireFrame, OrbWireMachine,
        ORB_WIRE_DEFAULT_MAX_BUDGET, ORB_WIRE_HEADER_BYTES,
    };
    #[test]
    fn wave12_orbwire_machine_and_seven_stateful_families_verified() {
        use crate::{
            auth_toctou_execute_step, hierarchy_merge_step, observe_auth_toctou_shadow,
            observe_hierarchy_merge_shadow, observe_transcript_fold_shadow,
            outbox_crash_reconcile_step, provider_attempt_step, resource_ledger_step,
            stream_bounded_commit_step, transcript_fold_step, wire_apply_patch_step,
            wire_machine_step, AuthToctouExecuteInput, BunkerState, FieldPresenceTag,
            HierarchyMergeStepInput, OutboxCrashReconcileInput, ProviderAttemptStepInput,
            ResourceLedgerOp, ResourceLedgerStepInput, ShadowCounter, StreamBoundedCommitInput,
            TranscriptFoldStepInput, WireApplyPatchInput, WireMachineStepInput,
        };

        struct CounterWireMachine;
        impl OrbWireMachine for CounterWireMachine {
            type State = (u64, u32);
            type Effect = u32;

            fn state_rev(state: &Self::State) -> u64 {
                state.0
            }

            fn decode_step(
                state: &Self::State,
                frame: &OrbWireFrame,
                event_seq: u64,
            ) -> Result<(Self::State, Vec<Self::Effect>, u8, bool), OrbWireStatus> {
                let delta = frame.records.first().map_or(0, |r| r.payload32);
                let next_total = state.1.saturating_add(delta);
                Ok(((event_seq, next_total), vec![next_total], 1, true))
            }

            fn encode_effects(
                _next_state: &Self::State,
                effects: &[Self::Effect],
                schema_id: u16,
            ) -> OrbWireFrame {
                OrbWireFrame {
                    schema_id,
                    flags: 0,
                    records: effects
                        .iter()
                        .map(|&v| OrbWireRecordWord {
                            tag: 1,
                            flags: 1,
                            len16: 0,
                            payload32: v,
                        })
                        .collect(),
                    arena: Vec::new(),
                }
            }
        }

        // P4: `OrbWireMachine` capacity fence & replay idempotence + `apply_patch_frame`
        let in_frame = OrbWireFrame {
            schema_id: 2,
            flags: 0,
            records: vec![OrbWireRecordWord {
                tag: 0,
                flags: 1,
                len16: 0,
                payload32: 7,
            }],
            arena: Vec::new(),
        };
        let mut encoded = [0u8; 64];
        let enc_len = in_frame
            .encode_into(&mut encoded, ORB_WIRE_DEFAULT_MAX_BUDGET)
            .unwrap();
        let mut tiny_out = [0xCCu8; 8];
        assert_eq!(
            execute_wire_machine_frame::<CounterWireMachine>(
                &(10, 5),
                &encoded[..enc_len],
                2,
                11,
                &mut tiny_out,
                ORB_WIRE_DEFAULT_MAX_BUDGET
            ),
            Err(5)
        );
        assert_eq!(tiny_out, [0xCCu8; 8]);

        let mut out_buf = [0u8; 64];
        let (next_st, effs, written) = execute_wire_machine_frame::<CounterWireMachine>(
            &(10, 5),
            &encoded[..enc_len],
            2,
            11,
            &mut out_buf,
            ORB_WIRE_DEFAULT_MAX_BUDGET,
        )
        .unwrap();
        assert_eq!(next_st, (11, 12));
        assert_eq!(effs, vec![12]);
        assert!(written >= ORB_WIRE_HEADER_BYTES);
        // Replay at same seq is rejected (`action_code = 3`)
        assert_eq!(
            execute_wire_machine_frame::<CounterWireMachine>(
                &next_st,
                &encoded[..enc_len],
                2,
                11,
                &mut out_buf,
                ORB_WIRE_DEFAULT_MAX_BUDGET
            ),
            Err(3)
        );

        let mut slots = [Some(42), Some(99), None];
        let patch_frame = OrbWireFrame {
            schema_id: 2,
            flags: 0,
            records: vec![
                OrbWireRecordWord {
                    tag: 0,
                    flags: 0,
                    len16: 0,
                    payload32: 0,
                },
                OrbWireRecordWord {
                    tag: 1,
                    flags: 2,
                    len16: 0,
                    payload32: 0,
                },
                OrbWireRecordWord {
                    tag: 2,
                    flags: 1,
                    len16: 0,
                    payload32: 777,
                },
            ],
            arena: Vec::new(),
        };
        let rev = apply_patch_frame(5, 6, &mut slots, &patch_frame).unwrap();
        assert_eq!(rev, 6);
        assert_eq!(slots, [Some(42), None, Some(777)]);
        assert_eq!(apply_patch_frame(6, 6, &mut slots, &patch_frame), Err(2));

        let patch_omit = wire_apply_patch_step(WireApplyPatchInput {
            current_rev: 1,
            incoming_rev: 2,
            current_val: Some(55),
            presence: FieldPresenceTag::Omitted,
            incoming_val: 0,
        });
        assert!(patch_omit.admitted);
        assert_eq!(patch_omit.next_val, Some(55));
        let wm_ok = wire_machine_step(WireMachineStepInput {
            schema_id: 2,
            state_rev: 3,
            event_seq: 4,
            effect_kind: 1,
            effect_admitted: true,
            out_cap: 128,
            required_out_bytes: 32,
        });
        assert!(wm_ok.admitted && wm_ok.emit_effect && wm_ok.next_rev32 == 4);

        // Family 1 (`G-ORB-5`): Partial patch preserves omitted parent; sticky supersede blocks unarchive
        let counter = ShadowCounter::new();
        let h_keep = observe_hierarchy_merge_shadow(
            HierarchyMergeStepInput {
                current_epoch: 10,
                incoming_epoch: 11,
                archive_epoch: 0,
                cur_archived: false,
                cur_superseded: false,
                is_partial_patch: true,
                parent_presence: FieldPresenceTag::Omitted,
                cur_parent_ord: 42,
                inc_parent_ord: 0,
                inc_archive: false,
                inc_unarchive: false,
                inc_supersede: false,
            },
            true,
            42,
            &counter,
        );
        assert!(h_keep.admitted && h_keep.next_parent_ord == 42);
        let h_sup = hierarchy_merge_step(HierarchyMergeStepInput {
            current_epoch: 11,
            incoming_epoch: 12,
            archive_epoch: 5,
            cur_archived: true,
            cur_superseded: true,
            is_partial_patch: true,
            parent_presence: FieldPresenceTag::Omitted,
            cur_parent_ord: 42,
            inc_parent_ord: 0,
            inc_archive: false,
            inc_unarchive: true,
            inc_supersede: false,
        });
        assert!(!h_sup.admitted && h_sup.next_superseded && h_sup.next_archived);

        // Family 2 (`G-ORB-3`): Contiguous seq progression & live/replay equivalence
        let f_live = observe_transcript_fold_shadow(
            TranscriptFoldStepInput {
                last_applied_seq: 10,
                incoming_seq: 11,
                entry_count: 3,
                thinking_open: true,
                normalized_action: 5,
                is_replay_from_log: false,
            },
            true,
            4,
            1,
            &counter,
        );
        let f_replay = transcript_fold_step(TranscriptFoldStepInput {
            last_applied_seq: 10,
            incoming_seq: 11,
            entry_count: 3,
            thinking_open: true,
            normalized_action: 5,
            is_replay_from_log: true,
        });
        assert_eq!(f_live, f_replay);
        assert!(f_live.admitted && f_live.closed_previous_thinking && f_live.next_entry_count == 4);
        let f_gap = transcript_fold_step(TranscriptFoldStepInput {
            last_applied_seq: 10,
            incoming_seq: 13,
            entry_count: 3,
            thinking_open: false,
            normalized_action: 5,
            is_replay_from_log: false,
        });
        assert!(!f_gap.admitted && f_gap.gap_buffered && f_gap.next_entry_count == 3);

        // Family 3 (`G-ORB-2`): Outbox crash resets volatile lease and preserves unacked WAL items
        let ob = outbox_crash_reconcile_step(OutboxCrashReconcileInput {
            durable_queued: 9,
            durable_acked: 4,
            volatile_in_flight: 5,
            lease_boot_epoch: 100,
            node_boot_epoch: 101,
            volatile_lease_owner: 77,
            req_owner: 88,
        });
        assert!(
            ob.admitted && ob.crash_reconciled && ob.has_single_writer && ob.unacked_depth == 5
        );

        // Family 4 (`G-ORB-2`): Provider attempt locks stream after first byte and pins account
        let pa_locked = provider_attempt_step(ProviderAttemptStepInput {
            pinned_account_id: 7,
            candidate_account_id: 7,
            attempts_used: 1,
            retry_budget: 3,
            first_byte_committed: true,
            failure_kind: 1,
            upstream_now_epoch: 50,
            cooldown_until_epoch: 0,
            upstream_deadline: 100,
            auth_valid: true,
        });
        assert!(
            !pa_locked.admitted && pa_locked.action_code == 3 && pa_locked.first_byte_locked_next
        );

        // Family 5 (`G-ORB-7`): `observe -> gate -> execute` TOCTOU binding fails closed on digest drift
        let auth_ok = observe_auth_toctou_shadow(
            AuthToctouExecuteInput {
                principal_kind: 2,
                bunker_state: BunkerState::Normal,
                observed_target_id: 9,
                exec_target_id: 9,
                observed_lease_epoch: 44,
                live_lease_epoch: 44,
                now_tick: 100,
                expiry_tick: 200,
                observed_digest: 0xDEAD_BEEF,
                exec_digest: 0xDEAD_BEEF,
            },
            true,
            1,
            &counter,
        );
        assert!(auth_ok.admitted && !auth_ok.fail_closed);
        let auth_mut = auth_toctou_execute_step(AuthToctouExecuteInput {
            exec_digest: 0xDEAD_BEE0,
            ..AuthToctouExecuteInput {
                principal_kind: 2,
                bunker_state: BunkerState::Normal,
                observed_target_id: 9,
                exec_target_id: 9,
                observed_lease_epoch: 44,
                live_lease_epoch: 44,
                now_tick: 100,
                expiry_tick: 200,
                observed_digest: 0xDEAD_BEEF,
                exec_digest: 0xDEAD_BEEF,
            }
        });
        assert!(!auth_mut.admitted && auth_mut.fail_closed && auth_mut.reason_code == 6);
        assert_eq!(
            counter
                .snapshot("orb_auth_toctou_execute_step")
                .total_divergences,
            0
        );

        // Family 6 (`G-ORB-3`): Conserved resource ledger prevents overspend/wrap and reaps expired TTL
        let rl_ok = resource_ledger_step(ResourceLedgerStepInput {
            op_kind: ResourceLedgerOp::Reserve,
            reserved_slots: 1,
            active_slots: 2,
            max_slots: 4,
            spent_cents: 600,
            cost_delta_cents: 400,
            budget_cents: 1_000,
            now_tick: 10,
            ttl_expiry_tick: 50,
        });
        assert!(rl_ok.admitted && rl_ok.next_reserved_slots == 2 && rl_ok.next_active_slots == 2);
        let rl_wrap = resource_ledger_step(ResourceLedgerStepInput {
            cost_delta_cents: u64::MAX,
            ..ResourceLedgerStepInput {
                op_kind: ResourceLedgerOp::Reserve,
                reserved_slots: 1,
                active_slots: 2,
                max_slots: 4,
                spent_cents: 600,
                cost_delta_cents: 400,
                budget_cents: 1_000,
                now_tick: 10,
                ttl_expiry_tick: 50,
            }
        });
        assert!(!rl_wrap.admitted && rl_wrap.next_reserved_slots == 1);

        // Family 7 (`G-ORB-6`): Bounded-tail checkpoint clamps giant open fence tail <= max_open_tail_bytes
        let sb = stream_bounded_commit_step(StreamBoundedCommitInput {
            prev_len: 1_000,
            prev_commit: 200,
            prev_checkpoint: 200,
            new_len: 20_000,
            raw_commit: 200,
            max_open_tail_bytes: 4_096,
        });
        assert!(sb.admitted && sb.checkpoint_forced && sb.next_checkpoint == 20_000 - 4_096);
        assert!(20_000 - sb.next_checkpoint <= 4_096);
    }

    #[test]
    fn stream_simd_isa_gated_scanner_matches_scalar_across_1024_differential_inputs() {
        let caps = stream_simd::detect_hw_caps();
        let selected = stream_simd::select_verified_stream_isa();
        let req_mask = match selected {
            stream_simd::VARIANT_AVX2 => stream_simd::MASK_AVX2,
            stream_simd::VARIANT_SIMD128 => stream_simd::MASK_SIMD128,
            _ => stream_simd::MASK_BASELINE,
        };
        assert!(lean_sys_cabi::verify_isa_selection(
            caps,
            req_mask,
            selected,
            stream_simd::MAX_VARIANT_ID
        ));
        assert_eq!(
            stream_simd::select_verified_stream_isa_with_caps(
                stream_simd::MASK_BASELINE,
                stream_simd::VARIANT_AVX2
            ),
            stream_simd::VARIANT_SCALAR
        );
        assert_eq!(
            stream_simd::select_verified_stream_isa_with_caps(
                stream_simd::MASK_SIMD128,
                stream_simd::VARIANT_AVX2
            ),
            stream_simd::VARIANT_SIMD128
        );
        assert_eq!(
            stream_simd::select_verified_stream_isa_with_caps(
                stream_simd::MASK_AVX2,
                stream_simd::VARIANT_AVX2
            ),
            stream_simd::VARIANT_AVX2
        );
        assert_eq!(
            stream_simd::select_verified_stream_isa_with_caps(
                stream_simd::MASK_AVX2,
                stream_simd::VARIANT_SCALAR
            ),
            stream_simd::VARIANT_SCALAR
        );

        let mut seed: u64 = 0x517c_c1b7_2722_0a95;
        let mut next = || -> u64 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };

        let tokens: [&[u8]; 16] = [
            b"\n",
            b" ",
            b"\t",
            b"|",
            b" | ",
            b"`",
            b"```",
            b"```rust\n",
            b"~~~",
            b"  ```lean\n",
            b"\t~~~\n",
            b"abc",
            b"\xc3\xa9",
            b"\xe2\x82\xac",
            b"\xf0\x9f\x98\x80",
            b"\n\n",
        ];

        // 1,024 deterministic differential inputs covering alignment offsets 0..63,
        // empty buffers, <16/<32 tails, exact 16/32/64B & 4KB/64KB boundaries,
        // split fences across 16/32B lanes, and multi-byte UTF-8 sequences.
        let mut raw = vec![0u8; 65_536 + 128];
        for case_idx in 0..1_024usize {
            let align_off = case_idx % 64;
            let target_len = match case_idx {
                0 => 0,
                1..=65 => case_idx - 1,
                66 => 4_096,
                67 => 4_097,
                68 => 65_536,
                69 => 65_537,
                _ => ((next() as usize) % 1024) + (case_idx % 33),
            };
            let slice = &mut raw[align_off..align_off + target_len];
            let mut pos = 0usize;
            while pos < target_len {
                let tok = tokens[(next() as usize) % tokens.len()];
                let take = tok.len().min(target_len - pos);
                slice[pos..pos + take].copy_from_slice(&tok[..take]);
                pos += take;
            }

            let expected = stream_simd::scan_stream_bytes_scalar(slice);
            let actual = stream_simd::scan_stream_bytes(slice);
            assert_eq!(
                actual, expected,
                "dispatch mismatch at case {case_idx} (len={target_len}, align={align_off})"
            );

            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                if std::arch::is_x86_feature_detected!("sse2") {
                    let sse2 = unsafe { stream_simd::scan_stream_bytes_sse2(slice) };
                    assert_eq!(sse2, expected, "SSE2 mismatch at case {case_idx}");
                }
                if std::arch::is_x86_feature_detected!("avx2") {
                    let avx2 = unsafe { stream_simd::scan_stream_bytes_avx2(slice) };
                    assert_eq!(avx2, expected, "AVX2 mismatch at case {case_idx}");
                }
            }
        }
    }

    fn naive_suffix_prefix_overlap_len(existing: &str, incoming: &str) -> usize {
        let max_overlap = existing.chars().count().min(incoming.chars().count());
        for overlap_chars in (1..=max_overlap).rev() {
            let existing_start = existing
                .char_indices()
                .nth(existing.chars().count() - overlap_chars)
                .map(|(idx, _)| idx)
                .unwrap_or(0);
            let incoming_end = incoming
                .char_indices()
                .nth(overlap_chars)
                .map(|(idx, _)| idx)
                .unwrap_or(incoming.len());
            if existing[existing_start..] == incoming[..incoming_end] {
                return incoming_end;
            }
        }
        0
    }

    #[test]
    fn kmp_suffix_prefix_overlap_matches_naive_across_1024_multibyte_utf8_cases() {
        let alphabet: [&str; 12] = [
            "a", "b", " ", "\n", "|", "`", "é", "€", "😀", "🧪", "中", "—",
        ];
        let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = || -> u64 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };

        let explicit = [
            ("", ""),
            ("abc", ""),
            ("", "abc"),
            ("hello ", "hello world"),
            ("foo 😀", "🧪 bar"),
            ("é€😀", "€😀!"),
            ("```rust\nlet x = 1 | 2;", "| 2;\n```"),
        ];
        for (ex, inc) in explicit {
            assert_eq!(
                suffix_prefix_overlap_len(ex, inc),
                naive_suffix_prefix_overlap_len(ex, inc),
                "ex={ex:?} inc={inc:?}"
            );
        }

        for case_idx in 0..1_024 {
            let len_a = (next() % 48) as usize;
            let len_b = (next() % 32) as usize;
            let mut a = String::new();
            for _ in 0..len_a {
                a.push_str(alphabet[(next() as usize) % alphabet.len()]);
            }
            let mut b = String::new();
            if next() % 3 == 0 && !a.is_empty() {
                let take_chars = ((next() as usize) % a.chars().count()) + 1;
                let tail_start = a
                    .char_indices()
                    .nth(a.chars().count() - take_chars)
                    .map(|(idx, _)| idx)
                    .unwrap_or(0);
                b.push_str(&a[tail_start..]);
            }
            for _ in 0..len_b {
                b.push_str(alphabet[(next() as usize) % alphabet.len()]);
            }
            assert_eq!(
                suffix_prefix_overlap_len(&a, &b),
                naive_suffix_prefix_overlap_len(&a, &b),
                "case {case_idx}"
            );
        }
    }
}
