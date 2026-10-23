//! Typed bindings to `lean/Orb/Kernel.lean` (`liborb_spec_cabi.a`), re-exported from `orb-spec`.

pub use orb_spec::*;

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
    }
}
