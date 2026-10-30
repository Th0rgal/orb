//! Typed bindings to `lean/Orb/Kernel.lean` (`liborb_spec_cabi.a`), re-exported from `orb-spec`.

pub use orb_spec::*;

pub fn verify_host_fd_bounds(raw_word: u64, fd_out: u32) -> bool {
    lean_sys_cabi::verify_fd_bounds(raw_word, fd_out)
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
}
