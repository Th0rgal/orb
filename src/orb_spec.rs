//! Typed bindings to `lean/Orb/Kernel.lean` (`liborb_spec_cabi.a`), re-exported from `orb-spec`.

pub use orb_spec::*;

pub fn verify_host_fd_bounds(raw_word: u64, fd_out: u32) -> bool {
    lean_sys_cabi::verify_fd_bounds(raw_word, fd_out)
}

pub fn verify_host_fleet_endpoint(
    mesh_reachable: bool,
    router_ready: bool,
    model_loaded: bool,
    breaker_open: bool,
) -> bool {
    fleet_endpoint_admitted(mesh_reachable, router_ready, model_loaded, breaker_open)
}

pub fn compute_host_prefill_deadline_ms(
    prompt_tokens: u64,
    base_ms: u64,
    per_k_tokens_ms: u64,
    max_prefill_ms: u64,
) -> u64 {
    prefill_deadline_ms(prompt_tokens, base_ms, per_k_tokens_ms, max_prefill_ms)
}

pub fn verify_host_model_account_admit(
    cand_id: u32,
    ineligible: bool,
    entitlement: ModelAccountEntitlement,
    require_entitled: bool,
) -> bool {
    model_account_admitted(cand_id, ineligible, entitlement, require_entitled)
}

pub fn select_host_model_account(
    model_is_eap_gated: bool,
    candidates: &[ModelAccountCandidate],
) -> Option<u32> {
    select_best_model_account(model_is_eap_gated, candidates)
}

pub fn select_host_stream_isa_with_caps(caps: u64, max_requested: u8) -> u8 {
    stream_simd::select_verified_stream_isa_with_caps(caps, max_requested)
}

pub fn scan_host_stream_bytes(buf: &[u8]) -> StreamByteScanSummary {
    stream_simd::scan_stream_bytes(buf)
}

pub fn apply_host_wire_patch(
    slots: &mut [Option<u32>],
    current_rev: u64,
    incoming_rev: u64,
    frame: &shadow::OrbWireFrame,
) -> Result<u64, u8> {
    shadow::apply_patch_frame(current_rev, incoming_rev, slots, frame)
}

pub fn step_host_wire_machine(
    step_fn: impl FnOnce() -> Result<(usize, Vec<u32>), u8>,
) -> Result<(usize, Vec<u32>), u8> {
    step_fn()
}

pub fn execute_host_wire_machine<M: shadow::OrbWireMachine>(
    state: &mut M::State,
    raw_in: &[u8],
    expected_schema_id: u16,
    event_seq: u64,
    out_buf: &mut [u8],
    max_budget: u32,
) -> Result<(usize, Vec<M::Effect>), u8> {
    let (next_state, effects, written) = shadow::execute_wire_machine_frame::<M>(
        state,
        raw_in,
        expected_schema_id,
        event_seq,
        out_buf,
        max_budget,
    )?;
    *state = next_state;
    Ok((written, effects))
}

pub fn encode_host_wire_slice(
    schema_id: u16,
    flags: u32,
    records: &[OrbWireRecordWord],
    arena: &[u8],
    out_buf: &mut [u8],
    max_budget: u32,
) -> Result<usize, OrbWireStatus> {
    shadow::OrbWireFrame::encode_slice_into(schema_id, flags, records, arena, out_buf, max_budget)
}

pub fn decode_host_wire_slice(
    bytes: &[u8],
    expected_schema_id: u16,
    max_budget: u32,
) -> Result<shadow::OrbWireSliceView<'_>, OrbWireStatus> {
    shadow::OrbWireSliceView::decode_slice(bytes, expected_schema_id, max_budget)
}

pub fn observe_host_scroll_policy_gap(height: i64, client: i64, top: i64) -> Option<i64> {
    scroll_policy_gap(height, client, top)
}

pub fn observe_host_scroll_policy_correct(
    height: i64,
    client: i64,
    top: i64,
    anchor_doc: i64,
    y0: i64,
) -> Option<i64> {
    scroll_policy_correct(height, client, top, anchor_doc, y0)
}

pub fn step_host_scroll_policy(input: ScrollPolicyInput) -> ScrollPolicyVerdict {
    scroll_policy_step(input)
}

pub fn step_host_wire_scroll_slice(
    in_slice: &[u8],
    out_buf: &mut [u8],
    input: ScrollPolicyInput,
) -> Result<(ScrollPolicyVerdict, usize), OrbWireStatus> {
    wire_scroll_slice_step(in_slice, out_buf, input)
}

pub fn step_host_wire_stream_slice(
    in_tail: &[u8],
    out_buf: &mut [u8],
    input: StreamBoundedCommitInput,
) -> Result<(WireStreamSliceVerdict, usize), OrbWireStatus> {
    wire_stream_slice_step(in_tail, out_buf, input)
}

pub fn step_host_wire_transcript_slice(
    in_event: &[u8],
    out_buf: &mut [u8],
    input: TranscriptFoldStepInput,
) -> Result<(TranscriptFoldStepVerdict, usize), WireTranscriptSliceError> {
    wire_transcript_slice_step(in_event, out_buf, input)
}

pub fn step_host_placement_merge(input: PlacementMergeInput) -> PlacementMergeVerdict {
    placement_merge_step(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reexported_orb_spec_links_and_executes_all_30_kernels() {
        assert_eq!(account_cooldown_secs(600, 21_600, 2), 1_200);
        assert_eq!(cost_cents_step(1_000, 1_000, 0, 0, 3_000, 15_000, 0, 0), 2);
        assert!(
            admission_step(AdmissionStepInput {
                recovery_phase: 0,
                is_quiescent: true,
                reserved_tag_forged: false,
                emergency_plus_cand_bytes: 100,
                free_disk_bytes: 200,
            })
            .admit
        );
        assert_eq!(
            pr_gate_recommendation(pr_gate_step(
                false, false, false, true, false, false, false, false, true, true
            )),
            "ready_for_review_or_merge"
        );
        assert_eq!(turn_summary_step(1, true, false, true).normalized_status, 0);
        assert_eq!(usage_limit_status_step(1, 2, true, 88, false, 0).pct, 88);
        assert_eq!(format_relative_time_secs(45), "1m");
        assert_eq!(
            transcript_patch_step(TranscriptPatchState { len: 10, seq: 1 }, 0, 5),
            TranscriptPatchState { len: 15, seq: 2 }
        );
        assert_eq!(
            node_gc_step(NodeGcStepInput {
                free_bytes: 50 << 30,
                floor_bytes: 80 << 30,
                emergency_floor_bytes: 10 << 30,
                aged_scratch_bytes: 0,
                fresh_scratch_bytes: 0,
                cold_cache_bytes: 0,
                hot_cache_bytes: 10 << 30,
            })
            .action,
            NodeGcAction::PinnedPreserveHot
        );
        assert!(
            !node_disk_admission_step(NodeDiskAdmissionInput {
                free_bytes: 50 << 30,
                reserved_bytes: 0,
                node_floor_bytes: 80 << 30,
                core_floor_bytes: 20 << 30,
                hysteresis_bytes: 20 << 30,
                node_pinned_pressure: false,
            })
            .admitted
        );
    }

    #[test]
    fn host_orb_wire_machine_patch_and_fd_bounds_gates_verified() {
        assert!(verify_host_fd_bounds(70_000, 70_000));
        assert!(!verify_host_fd_bounds(70_000, 4464));
        assert!(!verify_host_fd_bounds(0x8000_0000, 0x8000_0000));

        let mut slots = [Some(10u32), Some(20u32)];
        let patch = shadow::OrbWireFrame {
            schema_id: 2,
            flags: 0,
            records: vec![
                OrbWireRecordWord {
                    tag: 0,
                    flags: FieldPresenceTag::Omitted as u8,
                    len16: 0,
                    payload32: 99,
                },
                OrbWireRecordWord {
                    tag: 1,
                    flags: FieldPresenceTag::Present as u8,
                    len16: 0,
                    payload32: 42,
                },
            ],
            arena: Vec::new(),
        };
        let next_rev = apply_host_wire_patch(&mut slots, 1, 2, &patch).unwrap();
        assert_eq!(next_rev, 2);
        assert_eq!(slots, [Some(10), Some(42)]);
        assert!(apply_host_wire_patch(&mut slots, 2, 1, &patch).is_err());

        struct HostCounterMachine;
        impl shadow::OrbWireMachine for HostCounterMachine {
            type State = (u64, u32);
            type Effect = u32;
            fn state_rev(state: &Self::State) -> u64 {
                state.0
            }
            fn decode_step(
                state: &Self::State,
                frame: &shadow::OrbWireFrame,
                event_seq: u64,
            ) -> shadow::DecodedWireStep<Self::State, Self::Effect> {
                let delta = frame.records.first().map(|r| r.payload32).unwrap_or(0);
                let next_val = state.1.saturating_add(delta);
                Ok(((event_seq, next_val), vec![next_val], 1, true))
            }
            fn encode_effects(
                _next_state: &Self::State,
                effects: &[Self::Effect],
                schema_id: u16,
            ) -> shadow::OrbWireFrame {
                let next_val = effects.first().copied().unwrap_or(0);
                shadow::OrbWireFrame {
                    schema_id,
                    flags: 0,
                    records: vec![OrbWireRecordWord {
                        tag: 1,
                        flags: 0,
                        len16: 0,
                        payload32: next_val,
                    }],
                    arena: Vec::new(),
                }
            }
        }

        let in_frame = shadow::OrbWireFrame {
            schema_id: 2,
            flags: 0,
            records: vec![OrbWireRecordWord {
                tag: 1,
                flags: 0,
                len16: 0,
                payload32: 7,
            }],
            arena: Vec::new(),
        };
        let mut raw_in = [0u8; 64];
        let in_len = in_frame
            .encode_into(&mut raw_in, shadow::ORB_WIRE_DEFAULT_MAX_BUDGET)
            .unwrap();
        let mut state = (0u64, 5u32);
        let mut small_out = [0xAAu8; 8];
        assert!(step_host_wire_machine(|| {
            execute_host_wire_machine::<HostCounterMachine>(
                &mut state,
                &raw_in[..in_len],
                2,
                1,
                &mut small_out,
                shadow::ORB_WIRE_DEFAULT_MAX_BUDGET,
            )
        })
        .is_err());
        assert_eq!(state, (0, 5));
        assert_eq!(small_out, [0xAAu8; 8]);

        let mut out_buf = [0u8; 64];
        let (written, effects) = step_host_wire_machine(|| {
            execute_host_wire_machine::<HostCounterMachine>(
                &mut state,
                &raw_in[..in_len],
                2,
                1,
                &mut out_buf,
                shadow::ORB_WIRE_DEFAULT_MAX_BUDGET,
            )
        })
        .unwrap();
        assert!(written > 0);
        assert_eq!(state, (1, 12));
        assert_eq!(effects, vec![12]);
    }

    #[test]
    fn host_slice_bounds_and_isa_selection_gates_verified() {
        assert!(lean_sys_cabi::verify_slice_bounds(0, 64, 64));
        assert!(lean_sys_cabi::verify_slice_bounds(64, 0, 64));
        assert!(!lean_sys_cabi::verify_slice_bounds(64, 1, 64));
        assert!(!lean_sys_cabi::verify_slice_bounds(u64::MAX, 1, u64::MAX));

        assert_eq!(
            select_host_stream_isa_with_caps(stream_simd::MASK_BASELINE, stream_simd::VARIANT_AVX2),
            stream_simd::VARIANT_SCALAR
        );
        assert_eq!(
            select_host_stream_isa_with_caps(stream_simd::MASK_SIMD128, stream_simd::VARIANT_AVX2),
            stream_simd::VARIANT_SIMD128
        );
        assert_eq!(
            select_host_stream_isa_with_caps(stream_simd::MASK_AVX2, stream_simd::VARIANT_AVX2),
            stream_simd::VARIANT_AVX2
        );
        assert_eq!(
            select_host_stream_isa_with_caps(stream_simd::MASK_AVX2, stream_simd::VARIANT_SIMD128),
            stream_simd::VARIANT_SIMD128
        );
        let summary = scan_host_stream_bytes(b"hello\n```lean\n| a | b |\n```\n");
        assert_eq!(summary.newlines, 4);
        assert_eq!(summary.fence_candidates, 2);
        assert_eq!(summary.pipe_bytes, 3);

        let mut slice_out = [0xEEu8; 64];
        let recs = [OrbWireRecordWord {
            tag: 2,
            flags: 1,
            len16: 4,
            payload32: 0,
        }];
        let written = encode_host_wire_slice(
            5,
            0x11,
            &recs,
            b"host",
            &mut slice_out,
            shadow::ORB_WIRE_DEFAULT_MAX_BUDGET,
        )
        .unwrap();
        let view = decode_host_wire_slice(
            &slice_out[..written],
            5,
            shadow::ORB_WIRE_DEFAULT_MAX_BUDGET,
        )
        .unwrap();
        assert_eq!(view.record_count(), 1);
        assert_eq!(view.arena_slice(0, 4), Some(&b"host"[..]));

        assert_eq!(observe_host_scroll_policy_gap(1_000, 400, 700), Some(-100));
        assert_eq!(observe_host_scroll_policy_gap(1 << 30, 400, 700), None);
        assert_eq!(
            observe_host_scroll_policy_correct(2_000, 600, 500, 1_200, 100),
            Some(1_100)
        );
        assert_eq!(
            observe_host_scroll_policy_correct(2_000, 600, 500, -(1 << 30) - 1, 100),
            None
        );
        let sp = step_host_scroll_policy(ScrollPolicyInput {
            op_kind: ScrollPolicyOp::Layout as u8,
            pinned: false,
            intent: false,
            resized: false,
            cur_top: 800,
            height: 2_000,
            client: 600,
            arg: -700,
        });
        assert!(sp.admitted);
        assert_eq!(sp.top, 100);

        let mut r4_out = [0xAAu8; 64];
        let (ws, ws_len) = step_host_wire_scroll_slice(
            b"scroll",
            &mut r4_out,
            ScrollPolicyInput {
                op_kind: ScrollPolicyOp::UserScroll as u8,
                pinned: false,
                intent: true,
                resized: false,
                cur_top: 100,
                height: 2_000,
                client: 600,
                arg: 1_400,
            },
        )
        .unwrap();
        assert_eq!(ws_len, ORB_WIRE_FIXED_SLICE_FRAME_BYTES);
        assert!(ws.pinned);

        let (stm, stm_len) = step_host_wire_stream_slice(
            b"```lean\nopen tail",
            &mut r4_out,
            StreamBoundedCommitInput {
                prev_len: 20,
                prev_commit: 5,
                prev_checkpoint: 12,
                new_len: 40,
                raw_commit: 5,
                max_open_tail_bytes: 8,
            },
        )
        .unwrap();
        assert_eq!(stm_len, ORB_WIRE_FIXED_SLICE_FRAME_BYTES);
        assert_eq!(stm.next_checkpoint, 32);

        let (tr, tr_len) = step_host_wire_transcript_slice(
            b"delta",
            &mut r4_out,
            TranscriptFoldStepInput {
                last_applied_seq: 10,
                incoming_seq: 11,
                entry_count: 3,
                thinking_open: true,
                normalized_action: 5,
                is_replay_from_log: false,
            },
        )
        .unwrap();
        assert_eq!(tr_len, ORB_WIRE_FIXED_SLICE_FRAME_BYTES);
        assert_eq!(tr.next_entry_count, 4);

        let gap_err = step_host_wire_transcript_slice(
            b"delta",
            &mut r4_out,
            TranscriptFoldStepInput {
                last_applied_seq: 10,
                incoming_seq: 13,
                entry_count: 3,
                thinking_open: true,
                normalized_action: 5,
                is_replay_from_log: false,
            },
        )
        .unwrap_err();
        assert!(matches!(
            gap_err,
            WireTranscriptSliceError::FoldRejected(v)
                if !v.admitted && v.action_code == 3 && v.gap_buffered
        ));

        let pm = step_host_placement_merge(PlacementMergeInput {
            cur_rev: 2,
            inc_rev: 3,
            pending_op_id: 9,
            ack_op_id: 9,
            source_kind: 1,
            has_placement: true,
        });
        assert!(pm.admitted && pm.clear_pending && pm.evict_other_projects);
        assert_eq!(pm.next_rev32, 3);
    }

    #[test]
    fn host_model_account_selection_binds_to_lean_kernel() {
        let lacks = ModelAccountCandidate {
            cand_id: 1,
            ineligible: false,
            entitlement: ModelAccountEntitlement::LacksModel,
            has_pool_quota: true,
            priority_rank: 0,
            usable_in_secs: 0,
        };
        let entitled = ModelAccountCandidate {
            cand_id: 2,
            ineligible: false,
            entitlement: ModelAccountEntitlement::Entitled,
            has_pool_quota: true,
            priority_rank: 3,
            usable_in_secs: 0,
        };
        assert!(!verify_host_model_account_admit(
            1,
            false,
            ModelAccountEntitlement::LacksModel,
            true
        ));
        assert!(verify_host_model_account_admit(
            2,
            false,
            ModelAccountEntitlement::Entitled,
            true
        ));
        assert_eq!(select_host_model_account(true, &[lacks, entitled]), Some(2));
    }
}
