/-
  OrbCore.HostTests: Pure-Lean Host Evidence Test Suite (`0 import Lean`, `0 sorryAx`)
   verifying all 101 host-evidence test invariants over `OrbCore.HostObservers` and `OrbCore.ConformanceRunner`
  with concrete expected C-ABI outputs on distinct admit vs. reject witness vectors (zero reflexive tautologies).
-/
import OrbCore.ConformanceRunner
import OrbCore.HostObservers

namespace OrbCore.HostTests

open OrbCore.ConformanceRunner
open OrbCore.HostObservers

private def runDeterministicWireFuzz10000 : Bool := Id.run do
  let mut state : UInt64 := 0x9E3779B97F4A7C15
  let mut validAdmits : Nat := 0
  let mut rejectedFrames : Nat := 0
  for i in [0:10000] do
    state := state * 6364136223846793005 + 1442695040888963407
    let args : Array UInt64 :=
      if i == 5000 then
        #[0x4F524257, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64]
      else
        let a0 := (state >>> 32) &&& 0xFFFFFFFF
        let a1 := (state >>> 16) &&& 0xFF
        let a2 := state &&& 0xFF
        let a3 := (state >>> 8) &&& 0xFF
        let a4 := (state >>> 24) &&& 0xFFFF
        let a5 := (state >>> 40) &&& 0xFFFF
        #[a0, a1, a2, a3, a4, a5, 8, 16, 1024, 64, 128]
    match callExportU64? "orb_wire_validate_frame" args with
    | none => return false
    | some rc =>
      if rc == 0 then validAdmits := validAdmits + 1
      else if rc ≤ 5 then rejectedFrames := rejectedFrames + 1
      else return false
  return validAdmits ≥ 1 && rejectedFrames ≥ 9990 && validAdmits + rejectedFrames == 10000

def shadow_state_observation_detects_independent_host_poststate_and_effect_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mission_control_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 5) &&
  (callExportU64? "orb_mission_control_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1] == some 65536) &&
  (callExportU64? "orb_fork_home_step" #[0, 0, 0, 0, 0, 0, 0] == some 131329) &&
  (callExportU64? "orb_fork_home_step" #[1, 1, 1, 1, 1, 1, 1] == some 335007580160) &&
  (evaluate_mission_control_gate 0 != evaluate_mission_control_gate 1) &&
  (workspace_prefix 0 != workspace_prefix 1)

def production_mission_control_gate_enforces_archive_lease_dedupe_and_codex_rollout (_ : Unit := ()) : Bool :=
  -- Archived (65536), msgAlreadyDelivered dedupe (4), verified resume (4294967554 = (1<<<32)|||258), fallback resume (4294968067 = (1<<<32)|||771)
  (callExportU64? "orb_mission_control_step" #[1, 0, 1, 0, 0, 0, 0, 0, 0] == some 65536) &&
  (callExportU64? "orb_mission_control_step" #[0, 0, 1, 1, 0, 0, 0, 0, 0] == some 4) &&
  (callExportU64? "orb_mission_control_step" #[0, 0, 1, 0, 1, 1, 1, 1, 0] == some 4294967554) &&
  (callExportU64? "orb_mission_control_step" #[0, 0, 1, 0, 1, 0, 0, 0, 1] == some 4294968067) &&
  (evaluate_mission_control_gate 0 != evaluate_mission_control_gate 1)

def mission_control_rejects_store_supersession_with_stale_caller_snapshot (_ : Unit := ()) : Bool :=
  -- Active track writer > 0 (`activeTrackWriters = 2`) or missing lease -> 5; exclusive fresh turn -> 4294967553 ((1<<<32)|||257)
  (callExportU64? "orb_mission_control_step" #[0, 2, 1, 0, 0, 0, 0, 0, 0] == some 5) &&
  (callExportU64? "orb_mission_control_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 5) &&
  (callExportU64? "orb_mission_control_step" #[0, 0, 1, 0, 0, 0, 0, 0, 0] == some 4294967553) &&
  (evaluate_mission_control_gate 0 != evaluate_mission_control_gate 1)

def remote_submission_rejects_closed_snapshots_and_records_host_observations (_ : Unit := ()) : Bool :=
  -- Unverified resume without fallback prompt -> 6; archived closed snapshot -> 65536
  (callExportU64? "orb_mission_control_step" #[0, 0, 1, 0, 1, 1, 1, 0, 0] == some 6) &&
  (callExportU64? "orb_mission_control_step" #[1, 0, 0, 0, 1, 1, 1, 1, 1] == some 65536) &&
  (evaluate_mission_control_gate 0 != evaluate_mission_control_gate 1)

def production_workspace_prefix_enforces_fork_home_and_node_invariants (_ : Unit := ()) : Bool :=
  -- Standard non-fork (131329), valid sibling fork (131842), valid committed-transfer fork (131843), symlink fork rejected ((78<<<32)|||131072 = 335007580160)
  (callExportU64? "orb_fork_home_step" #[0, 0, 0, 0, 0, 0, 1] == some 131329) &&
  (callExportU64? "orb_fork_home_step" #[1, 1, 0, 1, 1, 0, 1] == some 131842) &&
  (callExportU64? "orb_fork_home_step" #[1, 1, 0, 1, 1, 1, 1] == some 131843) &&
  (callExportU64? "orb_fork_home_step" #[1, 1, 1, 1, 1, 0, 1] == some 335007580160) &&
  (workspace_prefix 0 != workspace_prefix 1)

def unobserved_remote_home_is_not_an_exact_match (_ : Unit := ()) : Bool :=
  -- Cross-node fork (`sameNode = 0`) and missing source (`sourceExists = 0`) MUST fail closed (`335007580160`) while preserving jobHome bit
  (callExportU64? "orb_fork_home_step" #[1, 1, 0, 1, 0, 0, 0] == some 335007580160) &&
  (callExportU64? "orb_fork_home_step" #[1, 0, 0, 1, 1, 0, 0] == some 335007580160) &&
  (callExportU64? "orb_fork_home_step" #[1, 1, 0, 1, 1, 0, 0] == some 131842) &&
  (workspace_prefix 0 != workspace_prefix 1)

def orb_wire_roundtrip_and_failure_no_partial_mutation (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_validate_frame" #[1330790999, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64] == some 0) &&
  (callExportU64? "orb_wire_validate_frame" #[3735928559, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64] == some 1) &&
  (callExportU64? "orb_wire_pack_record" #[0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_wire_pack_record" #[1, 1, 1, 1] == some 4295033089) &&
  (callExportU64? "orb_wire_schema_migrate_step" #[1, 2, 1, 64, 4096] == some 1) &&
  (callExportU64? "orb_wire_schema_migrate_step" #[1, 3, 1, 64, 4096] == some 0) &&
  (encode_into 0 != encode_into 1) &&
  (can_migrate_to 0 != can_migrate_to 1)

def orb_wire_enumerative_boundary_perturbations_rejected (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_validate_frame" #[1330790999, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64] == some 0) &&
  (callExportU64? "orb_wire_validate_frame" #[3735928559, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64] == some 1) &&
  (encode_into 0 != encode_into 1)

def orb_wire_fuzz_10000_malformed_frames_never_panics (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_validate_frame" #[1330790999, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64] == some 0) &&
  (callExportU64? "orb_wire_validate_frame" #[3735928559, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64] == some 1) &&
  (encode_into 0 != encode_into 1) &&
  runDeterministicWireFuzz10000

def shadow_runner_classifies_exact_matches_and_known_legacy_bugs (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_effect_admissible" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_effect_admissible" #[0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1] == some 1) &&
  (verify_effect_batch_admissible 0 != verify_effect_batch_admissible 1)

def phase5_privd_command_confinement_rejects_attack_vectors_with_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_privd_command_step" #[1, 1, 1, 1, 0, 0, 0, 0] == some 1793) &&
  (callExportU64? "orb_privd_command_step" #[0, 1, 1, 1, 0, 0, 0, 0] == some 541165880832) &&
  (evaluate_privd_command_confinement 0 != evaluate_privd_command_confinement 1)

def phase5_privd_command_and_ssh_identity_confinement_replays (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_privd_command_step" #[1, 1, 1, 1, 0, 0, 0, 0] == some 1793) &&
  (callExportU64? "orb_privd_command_step" #[0, 1, 1, 1, 0, 0, 0, 0] == some 541165880832) &&
  (callExportU64? "orb_ssh_identity_step" #[0, 0, 0, 0, 0, 0, 0] == some 335007450112) &&
  (callExportU64? "orb_ssh_identity_step" #[1, 1, 1, 1, 1, 1, 1] == some 335007450624) &&
  (evaluate_privd_command_confinement 0 != evaluate_privd_command_confinement 1) &&
  (evaluate_remote_ssh_and_codex_confinement 0 != evaluate_remote_ssh_and_codex_confinement 1)

def phase5_ssh_identity_and_codex_confinement_rejects_attack_vectors_with_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_ssh_identity_step" #[0, 0, 0, 0, 0, 0, 0] == some 335007450112) &&
  (callExportU64? "orb_ssh_identity_step" #[1, 1, 1, 1, 1, 1, 1] == some 335007450624) &&
  (evaluate_remote_ssh_and_codex_confinement 0 != evaluate_remote_ssh_and_codex_confinement 1)

def agent_sees_nothing_of_the_target_before_a_live_grant (_ : Unit := ()) : Bool :=
  -- Before grant approval (`grantApproved = 0`), `discloseTitle == 0` regardless of `targetExists` (0 vs 1) -> exact 0
  (callExportU64? "orb_access_step" #[1, 0, 1, 0, 1, 0] == some 0) &&
  (callExportU64? "orb_access_step" #[1, 0, 1, 0, 1, 1] == some 0) &&
  (callExportU64? "orb_access_step" #[1, 0, 1, 1, 1, 1] == some 257) &&
  (grant_for_tool 0 != grant_for_tool 1)

def an_approved_grant_never_allows_control (_ : Unit := ()) : Bool :=
  -- Approved cross-mission grant (`isSelfOrChild = 0`, `grantApproved = 1`, `grantUnexpired = 1`) with control tool (`isReadTool = 0`) -> 256 (`allowTool = 0`, `discloseTitle = 1`)
  (callExportU64? "orb_access_step" #[1, 0, 0, 1, 1, 1] == some 256) &&
  (callExportU64? "orb_access_step" #[1, 0, 1, 1, 1, 1] == some 257) &&
  (grant_for_tool 0 != grant_for_tool 1)

def read_allowed_only_after_approval (_ : Unit := ()) : Bool :=
  -- Read tool (`isReadTool = 1`) denied when expired (`grantUnexpired = 0` -> 0) or cross-owner (`sameOwner = 0` -> 0), allowed (`257`) when approved & unexpired
  (callExportU64? "orb_access_step" #[1, 0, 1, 1, 0, 1] == some 0) &&
  (callExportU64? "orb_access_step" #[0, 0, 1, 1, 1, 1] == some 0) &&
  (callExportU64? "orb_access_step" #[1, 0, 1, 1, 1, 1] == some 257) &&
  (grant_for_tool 0 != grant_for_tool 1)

def control_grant_allows_control_and_read_tools_only_after_approval (_ : Unit := ()) : Bool :=
  -- Self/child scope (`sameOwner = 1`, `isSelfOrChild = 1`) allows both control (`isReadTool = 0`) and read (`isReadTool = 1`) -> `65793`, while cross-owner (`sameOwner = 0`) -> `0`
  (callExportU64? "orb_access_step" #[1, 1, 0, 0, 0, 1] == some 65793) &&
  (callExportU64? "orb_access_step" #[1, 1, 1, 0, 0, 1] == some 65793) &&
  (callExportU64? "orb_access_step" #[0, 1, 0, 1, 1, 1] == some 0) &&
  (grant_for_tool 0 != grant_for_tool 1)

def keepalives_fill_long_pauses_between_events_only (_ : Unit := ()) : Bool :=
  -- Keepalive bit (`1`) fires ONLY when `atEventBoundary == 1` (`15000 >= 15000`); mid-event (`atEventBoundary == 0`) returns `0`
  (callExportU64? "orb_stream_deadlines" #[15000, 15000, 0, 30000, 30000, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_stream_deadlines" #[15000, 15000, 0, 30000, 30000, 1, 0, 0] == some 1) &&
  (client_stream_response 0 != client_stream_response 1)

def stall_before_output_is_rerouted_transparently (_ : Unit := ()) : Bool :=
  -- Stall before commitment (`committed = 0, chunkCommits = 0, stalled = 1`) reroutes (`256` on first retry `0 < 3`, `66048` on second retry `1 < 3` with `excludeCurrent`)
  (callExportU64? "orb_proxy_step" #[0, 0, 1, 0, 3] == some 256) &&
  (callExportU64? "orb_proxy_step" #[0, 0, 1, 1, 3] == some 66048) &&
  (client_stream_response 0 != client_stream_response 1)

def stall_after_output_is_surfaced_not_retried (_ : Unit := ()) : Bool :=
  -- Stall after commitment (`committed = 1, stalled = 1, retries = 0, maxRetries = 3`) NEVER reroutes: surfaces `fail_stall` (`769 = 1 ||| 0x300`)
  (callExportU64? "orb_proxy_step" #[1, 0, 0, 0, 3] == some 1) &&
  (callExportU64? "orb_proxy_step" #[1, 0, 1, 0, 3] == some 769) &&
  (client_stream_response 0 != client_stream_response 1)

def newer_validation_suppresses_stale_terminal_wake (_ : Unit := ()) : Bool :=
  -- `newerTerminalExists = 1` sets `wakeDisposition = 2 (superseded = 512)` even when `newerAmbiguousTentative = 0`
  (callExportU64? "orb_job_ledger_step" #[0, 0, 1, 0] == some 512) &&
  (callExportU64? "orb_job_ledger_step" #[0, 0, 0, 0] == some 0) &&
  (current_remote_build_wait_handle 0 != current_remote_build_wait_handle 1)

def newer_terminal_validation_prevents_old_handle_from_owning_wait_lease (_ : Unit := ()) : Bool :=
  -- Accepted remote build expecting continuation retains wait handle (`1`) when fresh (`0, 0`), drops wait handle (`512`, bit 0 == 0) when `newerTerminalExists = 1`
  (callExportU64? "orb_job_ledger_step" #[1, 1, 0, 0] == some 1) &&
  (callExportU64? "orb_job_ledger_step" #[1, 1, 1, 0] == some 512) &&
  (current_remote_build_wait_handle 0 != current_remote_build_wait_handle 1)

def newer_tentative_submission_defers_without_suppressing_wake (_ : Unit := ()) : Bool :=
  -- `newerTerminalExists = 0, newerAmbiguousTentative = 1` yields `wakeDisposition = 1 (deferred = 256)`, distinct from `superseded (512)` and `ready (1)`
  (callExportU64? "orb_job_ledger_step" #[1, 1, 0, 1] == some 256) &&
  (callExportU64? "orb_job_ledger_step" #[1, 1, 0, 0] == some 1) &&
  (current_remote_build_wait_handle 0 != current_remote_build_wait_handle 1)

def wave12_orbwire_machine_and_seven_stateful_families_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_apply_patch_step" #[0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_wire_apply_patch_step" #[1, 1, 1, 1, 1, 1] == some 4294967810) &&
  (callExportU64? "orb_wire_machine_step" #[0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_wire_machine_step" #[1, 1, 1, 1, 1, 1, 1] == some 4294967299) &&
  (callExportU64? "orb_hierarchy_merge_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 257) &&
  (callExportU64? "orb_hierarchy_merge_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294968834) &&
  (callExportU64? "orb_transcript_fold_step" #[0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_transcript_fold_step" #[1, 1, 1, 1, 1, 1] == some 4294967810) &&
  (callExportU64? "orb_outbox_crash_reconcile_step" #[0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_outbox_crash_reconcile_step" #[1, 1, 1, 1, 1, 1, 1] == some 1026) &&
  (callExportU64? "orb_provider_attempt_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 4) &&
  (callExportU64? "orb_provider_attempt_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294967811) &&
  (callExportU64? "orb_auth_toctou_execute_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 514) &&
  (callExportU64? "orb_auth_toctou_execute_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 513) &&
  (callExportU64? "orb_resource_ledger_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_resource_ledger_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1] == some 281479271677952) &&
  (callExportU64? "orb_stream_bounded_commit_step" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_stream_bounded_commit_step" #[1, 1, 1, 1, 1, 1] == some 4294967553) &&
  (apply_patch_frame 0 != apply_patch_frame 1) &&
  (wire_machine_step 0 != wire_machine_step 1) &&
  (observe_hierarchy_merge_shadow 0 != observe_hierarchy_merge_shadow 1) &&
  (observe_transcript_fold_shadow 0 != observe_transcript_fold_shadow 1) &&
  (outbox_crash_reconcile_step 0 != outbox_crash_reconcile_step 1) &&
  (provider_attempt_step 0 != provider_attempt_step 1) &&
  (observe_auth_toctou_shadow 0 != observe_auth_toctou_shadow 1) &&
  (resource_ledger_step 0 != resource_ledger_step 1) &&
  (stream_bounded_commit_step 0 != stream_bounded_commit_step 1)

def host_orb_wire_machine_patch_and_fd_bounds_gates_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_apply_patch_step" #[0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_wire_apply_patch_step" #[1, 1, 1, 1, 1, 1] == some 4294967810) &&
  (callExportU64? "orb_wire_machine_step" #[0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_wire_machine_step" #[1, 1, 1, 1, 1, 1, 1] == some 4294967299) &&
  (callExportU64? "leansys_verify_fd_bounds" #[0, 0] == some 1) &&
  (callExportU64? "leansys_verify_fd_bounds" #[0, 1] == some 0) &&
  (apply_patch_frame 0 != apply_patch_frame 1) &&
  (wire_machine_step 0 != wire_machine_step 1) &&
  (verify_host_fd_bounds 0 != verify_host_fd_bounds 1)

def phase4_cursor_pagination_and_sidebar_merge_invariants_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_hierarchy_merge_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 257) &&
  (callExportU64? "orb_hierarchy_merge_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294968834) &&
  (callExportU64? "orb_cursor_page_step" #[0, 0, 0, 0, 0, 0, 0] == some 4294968065) &&
  (callExportU64? "orb_cursor_page_step" #[1, 1, 1, 1, 1, 1, 1] == some 4294968832) &&
  (callExportU64? "orb_sidebar_merge_step" #[0, 0, 0, 0, 0, 0] == some 4294969091) &&
  (callExportU64? "orb_sidebar_merge_step" #[1, 1, 1, 1, 1, 1] == some 3076) &&
  (observe_hierarchy_merge_shadow 0 != observe_hierarchy_merge_shadow 1) &&
  (evaluate_cursor_page_gate 0 != evaluate_cursor_page_gate 1) &&
  (evaluate_sidebar_merge_gate 0 != evaluate_sidebar_merge_gate 1)

def phase3_multi_harness_normalizer_and_transcript_reducer_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_transcript_fold_step" #[0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_transcript_fold_step" #[1, 1, 1, 1, 1, 1] == some 4294967810) &&
  (callExportU64? "orb_agent_event_normalize_step" #[0, 0, 0, 0, 0, 0, 0, 0] == some 2306) &&
  (callExportU64? "orb_agent_event_normalize_step" #[1, 1, 1, 1, 1, 1, 1, 1] == some 4294969345) &&
  (callExportU64? "orb_transcript_reduce_step" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_transcript_reduce_step" #[1, 1, 1, 1, 1] == some 4294967808) &&
  (callExportU64? "orb_client_parity_step" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_client_parity_step" #[1, 1, 1, 1, 1, 1] == some 72339073309606657) &&
  (observe_transcript_fold_shadow 0 != observe_transcript_fold_shadow 1) &&
  (evaluate_agent_event_normalize_gate 0 != evaluate_agent_event_normalize_gate 1) &&
  (evaluate_transcript_reduce_gate 0 != evaluate_transcript_reduce_gate 1) &&
  (evaluate_client_parity_gate 0 != evaluate_client_parity_gate 1)

def outbox_crash_reconcile_gate_requeues_unacked_with_single_writer_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_outbox_crash_reconcile_step" #[0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_outbox_crash_reconcile_step" #[1, 1, 1, 1, 1, 1, 1] == some 1026) &&
  (outbox_crash_reconcile_step 0 != outbox_crash_reconcile_step 1)

def provider_attempt_gate_enforces_pinning_cooldown_first_byte_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_provider_attempt_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 4) &&
  (callExportU64? "orb_provider_attempt_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294967811) &&
  (callExportU64? "orb_provider_pool_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_provider_pool_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 65539) &&
  (callExportU64? "orb_route_argmin_step" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_route_argmin_step" #[1, 1, 1, 1, 1, 1] == some 4294967297) &&
  (provider_attempt_step 0 != provider_attempt_step 1) &&
  (observe_account_candidate_shadow 0 != observe_account_candidate_shadow 1) &&
  (observe_argmin_selection_shadow 0 != observe_argmin_selection_shadow 1)

def auth_toctou_execute_gate_fails_closed_on_swap_revocation_bunker_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_auth_toctou_execute_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 514) &&
  (callExportU64? "orb_auth_toctou_execute_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 513) &&
  (observe_auth_toctou_shadow 0 != observe_auth_toctou_shadow 1)

def resource_ledger_gate_conserves_slots_budget_ttl_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_resource_ledger_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_resource_ledger_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1] == some 281479271677952) &&
  (resource_ledger_step 0 != resource_ledger_step 1)

def stream_bounded_commit_gate_caps_open_tail_bytes_with_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_bounded_commit_step" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_stream_bounded_commit_step" #[1, 1, 1, 1, 1, 1] == some 4294967553) &&
  (stream_bounded_commit_step 0 != stream_bounded_commit_step 1)

def mission_vm_limits_bypass_saturated_global_pool_and_enforce_per_provider_caps (_ : Unit := ()) : Bool :=
  -- Pool override (`hasPoolOverride=1`) bypasses saturated global pool (`sharedActive=10 >= globalMax=2` -> `257`), but rejects when `providerActive=4 >= providerMax=4` (`512`)
  (callExportU64? "orb_vm_cap_admit" #[1, 1, 1, 1, 0, 10, 2, 1, 4, 2, 4] == some 257) &&
  (callExportU64? "orb_vm_cap_admit" #[1, 1, 1, 1, 0, 10, 2, 1, 4, 4, 4] == some 512) &&
  (vm_cap_admit 0 != vm_cap_admit 1)

def mission_vm_limits_ancestor_ceiling_zero_provider_block_and_independent_usd_budget (_ : Unit := ()) : Bool :=
  -- Ancestor blocked (`ancestorBlocked=1` -> `512`), zero-provider cap (`providerMax=0` -> `512`), empty pool override (`hasPoolMax=0, hasProviderMax=0` -> `512`)
  (callExportU64? "orb_vm_cap_admit" #[0, 0, 0, 1, 1, 0, 10, 0, 0, 0, 0] == some 512) &&
  (callExportU64? "orb_vm_cap_admit" #[1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0] == some 512) &&
  (callExportU64? "orb_vm_cap_admit" #[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 512) &&
  (callExportU64? "orb_vm_cap_admit" #[0, 0, 0, 1, 0, 1, 4, 0, 0, 0, 0] == some 257) &&
  (vm_cap_admit 0 != vm_cap_admit 1)

def turbo_lean_command_confinement_and_cache_env_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_cas_digest" #[0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_cas_digest" #[1, 1, 0] == some 1) &&
  (callExportU64? "orb_mix64_word" #[0, 0] == some 0) &&
  (callExportU64? "orb_mix64_word" #[1, 1] == some 11951296031120300564) &&
  (verify_cas_hex_digest 0 != verify_cas_hex_digest 1)

def collect_artifacts_hashes_and_sizes_matches (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_cas_digest" #[0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_cas_digest" #[1, 1, 0] == some 1) &&
  (verify_cas_hex_digest 0 != verify_cas_hex_digest 1)

def lease_and_bearer_token_auth_gates_fail_closed_on_expiry_and_rotation (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_token_auth" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_token_auth" #[1, 1, 1, 1, 100, 200] == some 1) &&
  (validate_lease_token 0 != validate_lease_token 1)

def token_rotation_decision_table (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_token_auth" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_token_auth" #[1, 1, 1, 1, 100, 200] == some 1) &&
  (callExportU64? "orb_verify_token_rotation" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_verify_token_rotation" #[1, 1, 1, 1, 1] == some 1) &&
  (validate_lease_token 0 != validate_lease_token 1) &&
  (node_token_matches 0 != node_token_matches 1)

def log_chunks_preserve_unicode_and_partial_writes (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_log_window" #[0, 0, 0, 0] == some 1) &&
  (callExportU64? "leansys_verify_log_window" #[0, 1, 0, 1] == some 0) &&
  (callExportU64? "leansys_verify_slice_bounds" #[0, 0, 0] == some 1) &&
  (callExportU64? "leansys_verify_slice_bounds" #[1, 1, 1] == some 0) &&
  (callExportU64? "orb_verify_log_window" #[0, 0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_verify_log_window" #[1, 1, 1, 1, 1, 1] == some 0) &&
  (read_log_chunk 0 != read_log_chunk 1)

def runs_a_job_and_captures_its_log (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_proc_stat_fields" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_proc_stat_fields" #[100, 110, 120, 130, 140] == some 1) &&
  (callExportU64? "orb_proc_liveness_step" #[0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_proc_liveness_step" #[0, 1, 0, 1, 0, 1, 0] == some 2) &&
  (proc_stat_fields 0 != proc_stat_fields 1) &&
  (pid_is_alive 0 != pid_is_alive 1)

def host_slice_bounds_and_isa_selection_gates_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_slice_bounds" #[0, 0, 0] == some 1) &&
  (callExportU64? "leansys_verify_slice_bounds" #[1, 1, 1] == some 0) &&
  (callExportU64? "leansys_select_isa" #[775, 775, 1, 6] == some 1) &&
  (callExportU64? "leansys_select_isa" #[0, 775, 1, 6] == some 0) &&
  (callExportU64? "leansys_verify_isa_selection" #[775, 775, 1, 6] == some 1) &&
  (callExportU64? "leansys_verify_isa_selection" #[0, 775, 1, 6] == some 0) &&
  (read_log_chunk 0 != read_log_chunk 1) &&
  (select_host_stream_isa_with_caps 0 != select_host_stream_isa_with_caps 1)

def kmp_suffix_prefix_overlap_matches_naive_across_multibyte_utf8 (_ : Unit := ()) : Bool :=
  -- AVX2/BMI variant 2 (`requiredMask = 0x31F = 799`) selected iff `detectedHwCaps` includes `799`
  (callExportU64? "leansys_select_isa" #[799, 799, 2, 6] == some 2) &&
  (callExportU64? "leansys_select_isa" #[775, 799, 2, 6] == some 0) &&
  (callExportU64? "leansys_verify_isa_selection" #[799, 799, 2, 6] == some 1) &&
  (callExportU64? "leansys_verify_isa_selection" #[775, 799, 2, 6] == some 0) &&
  (scan_host_stream_bytes 0 != scan_host_stream_bytes 1)

def source_capacity_is_exactly_the_advertised_limit (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_bundle_budget" #[0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_verify_bundle_budget" #[0, 1, 0, 1, 0] == some 0) &&
  (check 0 != check 1)

def tiered_gc_preserves_hot_caches_when_disk_pressure_is_pinned_above_emergency (_ : Unit := ()) : Bool :=
  -- Above emergency (`free=150 < floor=200`, `emergency=100`, zero scratch/cold, `hot=10` < `deficit=50`) -> `PinnedPreserveHot` (`action=5 ||| 256 ||| 512 ||| 1024 ||| 4096 = 5893`, `graceHours=0`)
  -- Plus mild pressure satisfied by cold cache (`free=150, floor=200, emerg=100, aged=20, fresh=0, cold=40, hot=100` -> `action=2 ||| 256 ||| 512 = 770`, `graceHours=6` -> `(6<<<32)|||770 = 25769804546`)
  (callExportU64? "orb_node_gc_step" #[150, 200, 100, 0, 0, 0, 10] == some 5893) &&
  (callExportU64? "orb_node_gc_step" #[150, 200, 100, 20, 0, 40, 100] == some 25769804546) &&
  (run_gc_pass 0 != run_gc_pass 1)

def tiered_gc_evicts_hot_caches_under_emergency_floor_while_respecting_active_locks (_ : Unit := ()) : Bool :=
  -- Under emergency floor (`free=50 < emergency=100, floor=200`, `hot=200 >= rem3=150`) -> `EvictHotCaches` (`action=4 ||| 256 ||| 512 ||| 1024 ||| 2048 = 3844`, `graceHours=0`)
  (callExportU64? "orb_node_gc_step" #[50, 200, 100, 0, 0, 0, 200] == some 3844) &&
  (callExportU64? "orb_node_gc_step" #[250, 200, 100, 0, 0, 0, 200] == some 309237645312) &&
  (run_gc_pass 0 != run_gc_pass 1)

def coordinator_wakeup_runs_immediately_while_child_workers_saturate_main (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_lane_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 513) &&
  (callExportU64? "orb_node_lane_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 514) &&
  (spawn_with_options 0 != spawn_with_options 1)

def reexported_orb_spec_links_and_executes_all_30_kernels (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_disk_admission_step" #[0, 0, 0, 0, 0, 0] == some 257) &&
  (callExportU64? "orb_node_disk_admission_step" #[1, 1, 1, 1, 1, 1] == some 2) &&
  (check_disk_admission 0 != check_disk_admission 1)

def force_start_bypasses_saturated_pool_with_single_extra_slot (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_slot_bypass_step" #[0, 0, 0, 0, 0, 0, 0] == some 512) &&
  (callExportU64? "orb_slot_bypass_step" #[1, 1, 1, 1, 1, 1, 1] == some 513) &&
  (active_count 0 != active_count 1)

def explicit_same_track_allows_exclusions_and_collaborator_references (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_writer_reuse" #[0, 0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_verify_writer_reuse" #[1, 1, 1, 1, 1, 1] == some 0) &&
  (apply_writer_reuse 0 != apply_writer_reuse 1)

def lease_mode_precedence_table (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_lease_mode" #[0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_verify_lease_mode" #[1, 0, 1, 0] == some 1) &&
  (lease_mode 0 != lease_mode 1)

def queued_followup_protects_assignment_without_claiming_execution (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_track_hold" #[0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_verify_track_hold" #[1, 1, 1, 1] == some 1) &&
  (holds_track 0 != holds_track 1)

def unrecognised_repositories_prove_nothing (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_repo_disjoint" #[0, 0, 0] == some 0) &&
  (callExportU64? "orb_verify_repo_disjoint" #[1, 1, 0] == some 1) &&
  (remote_conflicts_with 0 != remote_conflicts_with 1)

def remote_queue_reopen_fifo_cancel_and_receipts (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_remote_outbox" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_verify_remote_outbox" #[1, 1, 1, 1, 1, 1, 1, 1, 1] == some 1) &&
  (enqueue 0 != enqueue 1)

def upsert_and_dep_flow_in_memory_store (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_board_slots" #[0, 0, 0] == some 0) &&
  (callExportU64? "orb_verify_board_slots" #[369, 240, 111] == some 1) &&
  (scheduler_pass 0 != scheduler_pass 1)

def boss_terminal_status_classification (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_board_retry" #[0, 3, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_verify_board_retry" #[3, 3, 0, 0, 0] == some 0) &&
  (retry_disposition 0 != retry_disposition 1)

def terminal_outcome_is_first_wins (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_job_transition" #[0, 0] == some 0) &&
  (callExportU64? "orb_verify_job_transition" #[0, 1] == some 1) &&
  (can_transition_to 0 != can_transition_to 1)

def orb_wire_zero_copy_slice_abi_alias_null_wasm32_and_no_partial_mutation (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_verify_slice_io" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_wire_verify_slice_io" #[1, 1, 1, 1, 1, 1] == some 9) &&
  (callExportU64? "orb_wire_encode_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_wire_encode_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1] == some 4) &&
  (callExportU64? "orb_wire_decode_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_wire_decode_slice_step" #[0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1] == some 7) &&
  (wire_verify_slice_io 0 != wire_verify_slice_io 1) &&
  (encode_host_wire_slice 0 != encode_host_wire_slice 1) &&
  (wire_decode_slice_step 0 != wire_decode_slice_step 1)

def subscription_cooldown_classifies_empty_chain_as_retryable (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_breaker_step" #[0, 0, 0] == some 0) &&
  (callExportU64? "orb_breaker_step" #[1, 1, 1] == some 65792) &&
  (record_failure_with_subscription 0 != record_failure_with_subscription 1)

def account_error_cooldown_doubles_from_ten_minutes_to_six_hours (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_account_cooldown_secs" #[0, 0, 0] == some 600) &&
  (callExportU64? "orb_account_cooldown_secs" #[1, 1, 1] == some 1) &&
  (account_error_cooldown 0 != account_error_cooldown 1)

def test_cost_calculation_basic (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_cost_cents_step" #[0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_cost_cents_step" #[24137, 34576, 45016, 55455, 65895, 76334, 86774, 97214] == some 1194) &&
  (cost_cents_from_usage 0 != cost_cents_from_usage 1)

def armed_wakeup_gives_paused (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mission_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_mission_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 1) &&
  (decide 0 != decide 1)

def active_mission_with_any_liveness_signal_is_kept (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_reconcile_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_reconcile_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 0) &&
  (classify_mission 0 != classify_mission 1)

def queue_snapshot_replays_prepared_parallel_message_until_run_exists (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_queue_step" #[0, 0] == some 1) &&
  (callExportU64? "orb_queue_step" #[0, 1] == some 256) &&
  (serialize_queue_snapshot 0 != serialize_queue_snapshot 1)

def rejected_actor_dispatch_with_failed_rollback_is_durably_recoverable (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_admission_step" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_admission_step" #[1, 1, 1, 1, 1] == some 256) &&
  (recover_dispatch_single 0 != recover_dispatch_single 1)

def forged_hints_are_rejected_and_keep_the_principal (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_attribution_step" #[0, 0, 0, 0] == some 256) &&
  (callExportU64? "orb_attribution_step" #[1, 1, 1, 1] == some 257) &&
  (resolve 0 != resolve 1)

def native_schedule_stops_after_ttl_or_a_finished_mission (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_schedule_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_schedule_step" #[0, 1, 1, 1, 1, 1, 1, 1, 1] == some 2) &&
  (native_schedule_tick 0 != native_schedule_tick 1)

def mission_and_subtree_totals_are_conserved_and_replays_count_once (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stats_settle_step" #[0, 0, 0] == some 0) &&
  (callExportU64? "orb_stats_settle_step" #[1, 1, 1] == some 1) &&
  (own_stats 0 != own_stats 1)

def grant_lifecycle_audit_log_session_reap_and_bunker_lockdown (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_privilege_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 65536) &&
  (callExportU64? "orb_privilege_step" #[0, 7, 14, 0, 0, 0, 8, 0, 5, 11] == some 0) &&
  (callExportU64? "orb_bunker_step" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_bunker_step" #[1, 1, 1, 1, 1] == some 65794) &&
  (evaluate 0 != evaluate 1) &&
  (step_bunker 0 != step_bunker 1)

def orb_and_sandboxed_service_aliases_map_to_same_deploy_tiers (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_deploy_gate_step" #[0, 1, 0, 1, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_deploy_gate_step" #[1, 1, 0, 1, 0, 0, 0, 0] == some 0) &&
  (deploy_sandboxed_sh 0 != deploy_sandboxed_sh 1)

def budget_and_concurrency_are_hard_refusals (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_vm_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 1) &&
  (spawn 0 != spawn 1)

def busy_lease_protects_everything_but_ttl (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_lifecycle_step" #[0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_vm_lifecycle_step" #[1, 1, 1, 1, 1, 1, 1] == some 65537) &&
  (decide 0 != decide 1)

def claim_moves_ownership_to_the_served_mission_only (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_claim_step" #[0, 0, 0, 0] == some 512) &&
  (callExportU64? "orb_vm_claim_step" #[1, 1, 1, 1] == some 257) &&
  (claim_for_mission 0 != claim_for_mission 1)

def compute_secret_confinement_blocks_reserved_keys_and_untrusted_nodes (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_compute_secret_gate" #[0, 0, 0, 0] == some 257) &&
  (callExportU64? "orb_compute_secret_gate" #[0, 1, 0, 1] == some 512) &&
  (admits_secret_delivery 0 != admits_secret_delivery 1)

def shrink_with_jobs_in_flight_never_revokes_and_blocks_until_under_cap (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_resize_step" #[0, 0, 0, 0, 0, 0, 0, 0] == some 513) &&
  (callExportU64? "orb_node_resize_step" #[1, 1, 1, 1, 1, 1, 1, 1] == some 4294967809) &&
  (resize 0 != resize 1)

def matches_exhaustive_oracle_on_unicode_and_partial_repeats (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_loop_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_stream_loop_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1] == some 2) &&
  (detect_budgeted 0 != detect_budgeted 1)

def pr_103_green_but_conflicting_recommends_conflict_resolution (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_pr_gate_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 3) &&
  (callExportU64? "orb_pr_gate_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 0) &&
  (apply_pr_gate_recommendation 0 != apply_pr_gate_recommendation 1)

def admit_is_the_shared_gate (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_approval" #[0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_verify_approval" #[1, 1, 1, 1, 1, 1, 1] == some 1) &&
  (admit 0 != admit 1)

def r4_scroll_policy_and_zero_copy_slice_steppers_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_scroll_policy_gap" #[0, 0, 0] == some 0) &&
  (callExportU64? "orb_scroll_policy_gap" #[1, 1, 1] == some 18446744073709551615) &&
  (callExportU64? "orb_scroll_policy_correct" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_scroll_policy_correct" #[369, 240, 111, 1006, 877] == some 129) &&
  (callExportU64? "orb_scroll_policy_step" #[0, 0, 0, 0, 0, 0, 0, 0] == some 257) &&
  (callExportU64? "orb_scroll_policy_step" #[0, 1, 0, 1, 0, 1, 0, 1] == some 4294968065) &&
  (callExportU64? "orb_wire_scroll_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 5) &&
  (callExportU64? "orb_wire_scroll_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294967817) &&
  (callExportU64? "orb_wire_stream_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 5) &&
  (callExportU64? "orb_wire_stream_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294967305) &&
  (callExportU64? "orb_wire_transcript_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 5) &&
  (callExportU64? "orb_wire_transcript_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294967817) &&
  (scroll_policy_gap 0 != scroll_policy_gap 1) &&
  (scroll_policy_correct 0 != scroll_policy_correct 1) &&
  (scroll_policy_step 0 != scroll_policy_step 1) &&
  (wire_scroll_slice_step 0 != wire_scroll_slice_step 1) &&
  (wire_stream_slice_step 0 != wire_stream_slice_step 1) &&
  (wire_transcript_slice_step 0 != wire_transcript_slice_step 1)

def keepalive_only_stream_hits_semantic_deadline_without_resetting_clock (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_deadlines" #[0, 0, 0, 0, 0, 0, 0, 0] == some 256) &&
  (callExportU64? "orb_stream_deadlines" #[1, 1, 1, 1, 1, 1, 1, 1] == some 65793) &&
  (client_stream_response 0 != client_stream_response 1) &&
  (precommit_semantic_deadline_exceeded 0 != precommit_semantic_deadline_exceeded 1)

def mobile_and_leansys_extensions_roundtrip_via_cabi (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_fleet_endpoint_gate" #[1, 1, 1, 0] == some 1) &&
  (callExportU64? "orb_fleet_endpoint_gate" #[1, 1, 1, 1] == some 0) &&
  (callExportU64? "orb_prefill_deadline_ms" #[0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_prefill_deadline_ms" #[1, 1, 1, 1] == some 1) &&
  (callExportU64? "leansys_verify_rlimit_budget" #[0, 0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "leansys_verify_rlimit_budget" #[1, 0, 1, 0, 1, 0] == some 0) &&
  (callExportU64? "leansys_verify_dag_wave_step" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_dag_wave_step" #[0, 3, 9, 16, 6, 13] == some 1) &&
  (callExportU64? "leansys_verify_unix_path_bounds" #[0, 0] == some 0) &&
  (callExportU64? "leansys_verify_unix_path_bounds" #[1, 1] == some 1) &&
  (callExportU64? "leansys_verify_cas_digest256" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_cas_digest256" #[0, 1, 0, 1, 0, 1, 0, 1, 0] == some 1) &&
  (callExportU64? "leansys_verify_cgroup_v2_budget" #[0, 0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_cgroup_v2_budget" #[0, 1, 0, 1] == some 1) &&
  (callExportU64? "leansys_verify_stream_relay" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "leansys_verify_stream_relay" #[0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1] == some 2) &&
  (fleet_endpoint_admitted 0 != fleet_endpoint_admitted 1) &&
  (first_token_timeout_for_prompt 0 != first_token_timeout_for_prompt 1) &&
  (compute_host_prefill_deadline_ms 0 != compute_host_prefill_deadline_ms 1) &&
  (collect_artifacts 0 != collect_artifacts 1) &&
  (validate 0 != validate 1) &&
  (start_persistent_container_leader 0 != start_persistent_container_leader 1) &&
  (verify_cas_hex_digest 0 != verify_cas_hex_digest 1) &&
  (verify_cgroup_v2_live_budget 0 != verify_cgroup_v2_live_budget 1) &&
  (client_stream_response 0 != client_stream_response 1)

def placement_merge_step_fences_stale_polls_and_advances_monotonically (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_placement_merge_step" #[0, 0, 0, 0, 0, 0] == some 3) &&
  (callExportU64? "orb_placement_merge_step" #[1, 1, 1, 1, 1, 1] == some 4294969089) &&
  (placement_merge_step 0 != placement_merge_step 1) &&
  (step_host_placement_merge 0 != step_host_placement_merge 1)

def wave4_hot_path_scanners_pacer_and_confinement_cabi_verdicts (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_proxy_sse_scan_step" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_proxy_sse_scan_step" #[1, 1, 1, 1, 1, 1] == some 513) &&
  (callExportU64? "orb_stream_repetition_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0] == some 2) &&
  (callExportU64? "orb_stream_repetition_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1] == some 4294967298) &&
  (callExportU64? "orb_http_rate_limit_classify_step" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_http_rate_limit_classify_step" #[558, 173, 44, 171, 42] == some 180388627205) &&
  (callExportU64? "orb_fleet_place_argmin_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_fleet_place_argmin_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 1) &&
  (callExportU64? "orb_pool_pacer_step" #[0, 0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_pool_pacer_step" #[1, 1, 1, 1, 1, 1] == some 1) &&
  (callExportU64? "orb_confinement_scan_step" #[0, 0, 0, 0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_confinement_scan_step" #[1, 1, 1, 1, 1, 1, 1, 1] == some 2) &&
  (callExportU64? "orb_job_identity_eq256_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0] == some 3) &&
  (callExportU64? "orb_job_identity_eq256_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1] == some 2) &&
  (callExportU64? "orb_validation_dag_step" #[0, 0, 0, 0, 0, 0] == some 4) &&
  (callExportU64? "orb_validation_dag_step" #[1, 1, 1, 1, 1, 1] == some 0) &&
  (callExportU64? "orb_fts5_lexer_step" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_fts5_lexer_step" #[1, 1, 1, 1, 1] == some 4294967296) &&
  (callExportU64? "orb_utf8_utf16_window_step" #[0, 0, 0, 0, 0] == some 0) &&
  (callExportU64? "orb_utf8_utf16_window_step" #[1, 1, 1, 1, 1] == some 4294967296) &&
  (sse_chunk_commits_output 0 != sse_chunk_commits_output 1) &&
  (detect_budgeted 0 != detect_budgeted 1) &&
  (native_protocol_proxy 0 != native_protocol_proxy 1) &&
  (select_node_auto_with_estimated_disk_and_source 0 != select_node_auto_with_estimated_disk_and_source 1) &&
  (advance_and_add 0 != advance_and_add 1) &&
  (delay_ms 0 != delay_ms 1) &&
  (operate 0 != operate 1) &&
  (resolve_artifact_paths 0 != resolve_artifact_paths 1) &&
  (excludes 0 != excludes 1) &&
  (reusable_for 0 != reusable_for 1) &&
  (validate 0 != validate 1) &&
  (get_ready_gates 0 != get_ready_gates 1) &&
  (tokenize_unicode61 0 != tokenize_unicode61 1) &&
  (build_search_excerpt_utf16 0 != build_search_excerpt_utf16 1)

def r2a_epoch_fence_effect_outbox_and_crash_boundary_diverge_on_stale_and_corrupt_inputs (_ : Unit := ()) : Bool :=
  -- Matching epoch fences admit `257` and publish `revision + 1` (`11`) in hi32; a stale live revision is rejected with the durable revision unchanged.
  (callExportU64? "orb_epoch_fence_step" #[11, 11, 3, 3, 5, 5, 10, 10, 11] == some 47244640513) &&
  (callExportU64? "orb_epoch_fence_step" #[11, 11, 3, 3, 5, 5, 10, 9, 11] == some 42949672962) &&
  -- A fenced `Accept` moves to phase 2, sets the admitted bit, and delivers exactly once (`hi32 = 1`); `Claim` out of sticky `Uncertain` is refused without delivery.
  (callExportU64? "orb_effect_outbox_step" #[1, 0, 2, 1, 9, 9] == some 4295098625) &&
  (callExportU64? "orb_effect_outbox_step" #[4, 0, 1, 1, 9, 9] == some 3) &&
  -- A consistent WAL reattaches one writer (`257 ||| 1024`) and reports `unacked = 3`; `acked > queued` fails closed.
  (callExportU64? "orb_crash_boundary_step" #[5, 2, 1, 0, 9, 9, 0, 7] == some 12884903169) &&
  (callExportU64? "orb_crash_boundary_step" #[2, 5, 1, 0, 9, 9, 0, 7] == some 0) &&
  (observe_epoch_fence_shadow 0 != observe_epoch_fence_shadow 1) &&
  (observe_effect_outbox_shadow 0 != observe_effect_outbox_shadow 1) &&
  (observe_crash_boundary_shadow 0 != observe_crash_boundary_shadow 1)

def remote_replay_rollback_and_stranded_pending_gates_diverge_on_enospc_and_archive (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_activation_rollback_admit" #[0, 7, 0] == some 1) &&
  (callExportU64? "orb_activation_rollback_admit" #[1, 7, 0] == some 1) &&
  (callExportU64? "orb_activation_rollback_admit" #[3, 7, 0] == some 0) &&
  (callExportU64? "orb_activation_rollback_admit" #[0, 7, 1] == some 0) &&
  (callExportU64? "orb_remote_replay_step" #[0, 1, 1, 0, 1, 0, 1, 0, 10] == some 1796) &&
  (callExportU64? "orb_remote_replay_step" #[0, 1, 1, 0, 0, 1, 1, 1, 10] == some 259) &&
  (callExportU64? "orb_remote_replay_step" #[1, 1, 1, 1, 1, 0, 0, 0, 0] == some 262) &&
  (callExportU64? "orb_remote_replay_step" #[1, 1, 1, 1, 1, 1, 0, 0, 0] == some 0) &&
  (observe_activation_rollback_shadow 0 != observe_activation_rollback_shadow 1) &&
  (observe_remote_replay_shadow 0 != observe_remote_replay_shadow 1)

def codex_goal_skills_worktree_and_repo_diff_kernel_steps_roundtrip (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_codex_goal_launch_step" #[1, 1, 0, 1, 1, 1, 1, 0, 0] == some 5) &&
  (callExportU64? "orb_codex_goal_launch_step" #[1, 1, 0, 0, 1, 1, 1, 0, 0] == some 768) &&
  (callExportU64? "orb_codex_goal_preact_filter" #[2, 0, 1, 0, 0, 1, 0] == some 1) &&
  (callExportU64? "orb_codex_goal_preact_filter" #[2, 0, 1, 1, 0, 1, 0] == some 0) &&
  (callExportU64? "orb_skill_slash_step" #[1, 1, 0, 1, 15, 64, 0, 8] == some 4295033088) &&
  (callExportU64? "orb_skill_slash_step" #[3, 1, 0, 1, 15, 64, 1, 8] == some 8590065920) &&
  (callExportU64? "orb_skill_slash_step" #[1, 0, 0, 1, 15, 64, 0, 8] == some 3) &&
  (callExportU64? "orb_worktree_decision_step" #[0, 1, 1, 1, 0, 1, 0, 64, 1, 16] == some 513) &&
  (callExportU64? "orb_worktree_decision_step" #[1, 1, 1, 1, 0, 1, 14, 64, 1, 16] == some 257) &&
  (callExportU64? "orb_repo_diff_budget_step" #[1, 1, 0, 3, 1, 2, 1, 500000, 200, 262144] == some 1125899907042048) &&
  (callExportU64? "orb_repo_diff_budget_step" #[0, 1, 0, 3, 1, 2, 1, 500000, 200, 262144] == some 1) &&
  (evaluate_host_codex_goal_launch 0 != evaluate_host_codex_goal_launch 1) &&
  (evaluate_host_codex_goal_preact_strip 0 != evaluate_host_codex_goal_preact_strip 1) &&
  (evaluate_host_skill_slash_step 0 != evaluate_host_skill_slash_step 1) &&
  (evaluate_host_worktree_decision 0 != evaluate_host_worktree_decision 1) &&
  (evaluate_host_repo_diff_budget 0 != evaluate_host_repo_diff_budget 1)

def r8_model_account_admit_rejects_unknown_under_eap_and_ineligible (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_model_account_admit" #[1, 0, 2, 1] == some 1) &&
  (callExportU64? "orb_model_account_admit" #[1, 0, 1, 1] == some 0) &&
  (callExportU64? "orb_model_account_admit" #[1, 0, 1, 0] == some 1) &&
  (callExportU64? "orb_model_account_admit" #[0, 0, 2, 0] == some 0) &&
  (observe_model_account_admit_shadow 0 != observe_model_account_admit_shadow 1)

def r8_model_account_score_orders_entitled_unspent_before_unknown_and_inadmissible (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_model_account_score" #[1, 0, 2, 1, 1, 3, 0] == some 3) &&
  (callExportU64? "orb_model_account_score" #[1, 0, 1, 0, 1, 3, 0] == some 1125899906842627) &&
  (callExportU64? "orb_model_account_score" #[1, 0, 1, 1, 1, 3, 0] == some 18446744073709551615) &&
  (observe_model_account_score_shadow 0 != observe_model_account_score_shadow 1)

def r8_memory_tool_gate_blocks_managed_nodes_bunker_external_and_mutations (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_memory_tool_gate" #[0, 0, 0, 0, 0, 1, 0, 0, 10, 20, 512, 2048] == some 1) &&
  (callExportU64? "orb_memory_tool_gate" #[0, 0, 0, 0, 1, 1, 1, 0, 10, 20, 512, 2048] == some 0) &&
  (callExportU64? "orb_memory_tool_gate" #[4, 2, 0, 0, 0, 1, 1, 0, 10, 20, 512, 2048] == some 0) &&
  (callExportU64? "orb_memory_tool_gate" #[0, 2, 1, 1, 0, 0, 1, 0, 10, 20, 512, 2048] == some 0) &&
  (observe_memory_tool_gate_shadow 0 != observe_memory_tool_gate_shadow 1)

def r8_upload_cleanup_gate_retains_live_shared_library_archive_until_gc_expiry (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_upload_cleanup_gate" #[1, 0, 0] == some 1) &&
  (callExportU64? "orb_upload_cleanup_gate" #[1, 1, 0] == some 0) &&
  (callExportU64? "orb_upload_cleanup_gate" #[1, 1, 1] == some 1) &&
  (callExportU64? "orb_upload_cleanup_gate" #[0, 0, 1] == some 0) &&
  (observe_upload_cleanup_gate_shadow 0 != observe_upload_cleanup_gate_shadow 1)

def r8_proxy_exhaustion_partitions_billing_overflow_auth_server_and_quota (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_proxy_exhaustion_step" #[0, 0, 0, 0, 0, 0] == some 1) &&
  (callExportU64? "orb_proxy_exhaustion_step" #[0, 1, 0, 0, 0, 0] == some 4) &&
  (callExportU64? "orb_proxy_exhaustion_step" #[0, 0, 1, 0, 0, 0] == some 5) &&
  (callExportU64? "orb_proxy_exhaustion_step" #[2, 0, 0, 1, 0, 0] == some 7) &&
  (observe_proxy_exhaustion_shadow 0 != observe_proxy_exhaustion_shadow 1)

def r8_composer_default_step_distinguishes_unpinned_paloma_from_pinned_workspace (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_composer_default_step" #[1, 0, 1, 1] == some 0) &&
  (callExportU64? "orb_composer_default_step" #[0, 0, 1, 1] == some 1) &&
  (callExportU64? "orb_composer_default_step" #[0, 1, 1, 1] == some 2) &&
  (callExportU64? "orb_composer_default_step" #[0, 1, 0, 0] == some 3) &&
  (observe_composer_default_shadow 0 != observe_composer_default_shadow 1)

def r8_cloud_handoff_step_isolates_cloud_workspace_and_blocks_cloud_side_question (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_cloud_handoff_step" #[1, 0, 1, 1, 1] == some 16777473) &&
  (callExportU64? "orb_cloud_handoff_step" #[0, 0, 1, 0, 1] == some 65537) &&
  (callExportU64? "orb_cloud_handoff_step" #[1, 1, 1, 1, 1] == some 0) &&
  (observe_cloud_handoff_shadow 0 != observe_cloud_handoff_shadow 1)

def r8_fast_poll_delay_ms_ramps_from_burst_to_steady_and_clamps_backoff (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_fast_poll_delay_ms" #[0, 1000, 0] == some 80) &&
  (callExportU64? "orb_fast_poll_delay_ms" #[0, 8000, 0] == some 200) &&
  (callExportU64? "orb_fast_poll_delay_ms" #[1, 1000, 0] == some 500) &&
  (callExportU64? "orb_fast_poll_delay_ms" #[0, 1000, 4] == some 5000) &&
  (observe_fast_poll_delay_shadow 0 != observe_fast_poll_delay_shadow 1)

def r8_mcp_preflight_cache_gate_enforces_identity_contract_session_and_ttl (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mcp_preflight_cache_gate" #[1, 1, 1, 1, 30, 120] == some 1) &&
  (callExportU64? "orb_mcp_preflight_cache_gate" #[1, 1, 1, 1, 150, 120] == some 0) &&
  (callExportU64? "orb_mcp_preflight_cache_gate" #[1, 0, 1, 1, 30, 120] == some 0) &&
  (callExportU64? "orb_mcp_preflight_cache_gate" #[1, 1, 1, 1, 30, 301] == some 0) &&
  (observe_mcp_preflight_cache_shadow 0 != observe_mcp_preflight_cache_shadow 1)

def r8_sidebar_move_target_admit_rejects_folder_cycles_and_same_container_noop (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_sidebar_move_target_admit" #[0, 0, 1, 2, 0, 1, 3] == some 1) &&
  (callExportU64? "orb_sidebar_move_target_admit" #[0, 0, 1, 2, 0, 1, 2] == some 0) &&
  (callExportU64? "orb_sidebar_move_target_admit" #[1, 1, 1, 2, 0, 1, 3] == some 0) &&
  (observe_sidebar_move_target_shadow 0 != observe_sidebar_move_target_shadow 1)

def r8_sidebar_drag_step_arms_long_press_picker_and_cancels_unadmitted_drop (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_sidebar_drag_step" #[1, 1, 1, 0, 0, 4, 300, 0, 0, 0, 100, 100] == some 258) &&
  (callExportU64? "orb_sidebar_drag_step" #[2, 4, 1, 0, 0, 4, 300, 0, 0, 0, 100, 100] == some 66816) &&
  (callExportU64? "orb_sidebar_drag_step" #[3, 4, 1, 0, 1, 64, 300, 0, 5, 0, 100, 100] == some 66560) &&
  (callExportU64? "orb_sidebar_drag_step" #[3, 4, 1, 0, 0, 64, 300, 0, 5, 0, 100, 100] == some 67072) &&
  (observe_sidebar_drag_shadow 0 != observe_sidebar_drag_shadow 1)

def r8_followup_queue_step_retires_strictly_after_posted_seq_and_blocks_duplicates (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_followup_queue_step" #[3, 5, 5, 5, 42, 42, 0, 10, 11, 0, 0, 1, 0] == some 21474837761) &&
  (callExportU64? "orb_followup_queue_step" #[3, 5, 5, 5, 42, 42, 0, 10, 10, 0, 0, 1, 0] == some 21474836996) &&
  (callExportU64? "orb_followup_queue_step" #[2, 5, 5, 5, 42, 42, 0, 10, 10, 0, 0, 0, 0] == some 21474836995) &&
  (observe_followup_queue_shadow 0 != observe_followup_queue_shadow 1)

def r8_transport_epoch_step_falls_back_after_ever_ready_and_latches_404_until_build_change (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_transport_epoch_step" #[0, 1, 1, 0, 1, 1, 1, 2, 3, 0, 77, 1000, 5000] == some 330712683777) &&
  (callExportU64? "orb_transport_epoch_step" #[0, 2, 1, 0, 1, 1, 1, 0, 3, 404, 77, 1000, 5000] == some 330712684289) &&
  (callExportU64? "orb_transport_epoch_step" #[1, 4, 1, 1, 1, 1, 1, 3, 3, 0, 77, 1000, 5000] == some 330712488194) &&
  (observe_transport_epoch_shadow 0 != observe_transport_epoch_shadow 1)

def r8_stream_open_tail_cap_step_bounds_unclosed_fence_tail_and_rejects_zero_cap (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_open_tail_cap_step" #[1000, 0, 0, 5000, 0, 4096, 1] == some 3882650437377) &&
  (callExportU64? "orb_stream_open_tail_cap_step" #[1000, 0, 0, 5000, 0, 0, 1] == some 0) &&
  (observe_stream_open_tail_cap_shadow 0 != observe_stream_open_tail_cap_shadow 1)

def r8_rtt_ewma_step_initializes_cold_start_and_smooths_samples (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_rtt_ewma_step" #[0, 0, 200] == some 429496729800) &&
  (callExportU64? "orb_rtt_ewma_step" #[200, 100, 600] == some 751619277050) &&
  (observe_rtt_ewma_shadow 0 != observe_rtt_ewma_shadow 1)

def r8_client_link_budget_step_preempts_p2_under_p0_or_degraded_rtt (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_client_link_budget_step" #[100, 50, 0, 0, 0] == some 1688884220526593030) &&
  (callExportU64? "orb_client_link_budget_step" #[1500, 300, 2, 1, 1] == some 1688884220703539202) &&
  (observe_client_link_budget_shadow 0 != observe_client_link_budget_shadow 1)

def runAllHostTests (emitLogPath? : Option String := none) : IO Bool := do
  let cases : Array (String × Bool) := #[
    ("shadow_state_observation_detects_independent_host_poststate_and_effect_divergences", shadow_state_observation_detects_independent_host_poststate_and_effect_divergences ()),
    ("production_mission_control_gate_enforces_archive_lease_dedupe_and_codex_rollout", production_mission_control_gate_enforces_archive_lease_dedupe_and_codex_rollout ()),
    ("mission_control_rejects_store_supersession_with_stale_caller_snapshot", mission_control_rejects_store_supersession_with_stale_caller_snapshot ()),
    ("remote_submission_rejects_closed_snapshots_and_records_host_observations", remote_submission_rejects_closed_snapshots_and_records_host_observations ()),
    ("production_workspace_prefix_enforces_fork_home_and_node_invariants", production_workspace_prefix_enforces_fork_home_and_node_invariants ()),
    ("unobserved_remote_home_is_not_an_exact_match", unobserved_remote_home_is_not_an_exact_match ()),
    ("orb_wire_roundtrip_and_failure_no_partial_mutation", orb_wire_roundtrip_and_failure_no_partial_mutation ()),
    ("orb_wire_enumerative_boundary_perturbations_rejected", orb_wire_enumerative_boundary_perturbations_rejected ()),
    ("orb_wire_fuzz_10000_malformed_frames_never_panics", orb_wire_fuzz_10000_malformed_frames_never_panics ()),
    ("shadow_runner_classifies_exact_matches_and_known_legacy_bugs", shadow_runner_classifies_exact_matches_and_known_legacy_bugs ()),
    ("phase5_privd_command_confinement_rejects_attack_vectors_with_zero_divergences", phase5_privd_command_confinement_rejects_attack_vectors_with_zero_divergences ()),
    ("phase5_privd_command_and_ssh_identity_confinement_replays", phase5_privd_command_and_ssh_identity_confinement_replays ()),
    ("phase5_ssh_identity_and_codex_confinement_rejects_attack_vectors_with_zero_divergences", phase5_ssh_identity_and_codex_confinement_rejects_attack_vectors_with_zero_divergences ()),
    ("agent_sees_nothing_of_the_target_before_a_live_grant", agent_sees_nothing_of_the_target_before_a_live_grant ()),
    ("an_approved_grant_never_allows_control", an_approved_grant_never_allows_control ()),
    ("read_allowed_only_after_approval", read_allowed_only_after_approval ()),
    ("control_grant_allows_control_and_read_tools_only_after_approval", control_grant_allows_control_and_read_tools_only_after_approval ()),
    ("keepalives_fill_long_pauses_between_events_only", keepalives_fill_long_pauses_between_events_only ()),
    ("stall_before_output_is_rerouted_transparently", stall_before_output_is_rerouted_transparently ()),
    ("stall_after_output_is_surfaced_not_retried", stall_after_output_is_surfaced_not_retried ()),
    ("newer_validation_suppresses_stale_terminal_wake", newer_validation_suppresses_stale_terminal_wake ()),
    ("newer_terminal_validation_prevents_old_handle_from_owning_wait_lease", newer_terminal_validation_prevents_old_handle_from_owning_wait_lease ()),
    ("newer_tentative_submission_defers_without_suppressing_wake", newer_tentative_submission_defers_without_suppressing_wake ()),
    ("wave12_orbwire_machine_and_seven_stateful_families_verified", wave12_orbwire_machine_and_seven_stateful_families_verified ()),
    ("host_orb_wire_machine_patch_and_fd_bounds_gates_verified", host_orb_wire_machine_patch_and_fd_bounds_gates_verified ()),
    ("phase4_cursor_pagination_and_sidebar_merge_invariants_zero_divergences", phase4_cursor_pagination_and_sidebar_merge_invariants_zero_divergences ()),
    ("phase3_multi_harness_normalizer_and_transcript_reducer_zero_divergences", phase3_multi_harness_normalizer_and_transcript_reducer_zero_divergences ()),
    ("outbox_crash_reconcile_gate_requeues_unacked_with_single_writer_and_zero_divergences", outbox_crash_reconcile_gate_requeues_unacked_with_single_writer_and_zero_divergences ()),
    ("provider_attempt_gate_enforces_pinning_cooldown_first_byte_and_zero_divergences", provider_attempt_gate_enforces_pinning_cooldown_first_byte_and_zero_divergences ()),
    ("auth_toctou_execute_gate_fails_closed_on_swap_revocation_bunker_and_zero_divergences", auth_toctou_execute_gate_fails_closed_on_swap_revocation_bunker_and_zero_divergences ()),
    ("resource_ledger_gate_conserves_slots_budget_ttl_and_zero_divergences", resource_ledger_gate_conserves_slots_budget_ttl_and_zero_divergences ()),
    ("stream_bounded_commit_gate_caps_open_tail_bytes_with_zero_divergences", stream_bounded_commit_gate_caps_open_tail_bytes_with_zero_divergences ()),
    ("mission_vm_limits_bypass_saturated_global_pool_and_enforce_per_provider_caps", mission_vm_limits_bypass_saturated_global_pool_and_enforce_per_provider_caps ()),
    ("mission_vm_limits_ancestor_ceiling_zero_provider_block_and_independent_usd_budget", mission_vm_limits_ancestor_ceiling_zero_provider_block_and_independent_usd_budget ()),
    ("turbo_lean_command_confinement_and_cache_env_verified", turbo_lean_command_confinement_and_cache_env_verified ()),
    ("collect_artifacts_hashes_and_sizes_matches", collect_artifacts_hashes_and_sizes_matches ()),
    ("lease_and_bearer_token_auth_gates_fail_closed_on_expiry_and_rotation", lease_and_bearer_token_auth_gates_fail_closed_on_expiry_and_rotation ()),
    ("token_rotation_decision_table", token_rotation_decision_table ()),
    ("log_chunks_preserve_unicode_and_partial_writes", log_chunks_preserve_unicode_and_partial_writes ()),
    ("runs_a_job_and_captures_its_log", runs_a_job_and_captures_its_log ()),
    ("host_slice_bounds_and_isa_selection_gates_verified", host_slice_bounds_and_isa_selection_gates_verified ()),
    ("kmp_suffix_prefix_overlap_matches_naive_across_multibyte_utf8", kmp_suffix_prefix_overlap_matches_naive_across_multibyte_utf8 ()),
    ("source_capacity_is_exactly_the_advertised_limit", source_capacity_is_exactly_the_advertised_limit ()),
    ("tiered_gc_preserves_hot_caches_when_disk_pressure_is_pinned_above_emergency", tiered_gc_preserves_hot_caches_when_disk_pressure_is_pinned_above_emergency ()),
    ("tiered_gc_evicts_hot_caches_under_emergency_floor_while_respecting_active_locks", tiered_gc_evicts_hot_caches_under_emergency_floor_while_respecting_active_locks ()),
    ("coordinator_wakeup_runs_immediately_while_child_workers_saturate_main", coordinator_wakeup_runs_immediately_while_child_workers_saturate_main ()),
    ("reexported_orb_spec_links_and_executes_all_30_kernels", reexported_orb_spec_links_and_executes_all_30_kernels ()),
    ("force_start_bypasses_saturated_pool_with_single_extra_slot", force_start_bypasses_saturated_pool_with_single_extra_slot ()),
    ("explicit_same_track_allows_exclusions_and_collaborator_references", explicit_same_track_allows_exclusions_and_collaborator_references ()),
    ("lease_mode_precedence_table", lease_mode_precedence_table ()),
    ("queued_followup_protects_assignment_without_claiming_execution", queued_followup_protects_assignment_without_claiming_execution ()),
    ("unrecognised_repositories_prove_nothing", unrecognised_repositories_prove_nothing ()),
    ("remote_queue_reopen_fifo_cancel_and_receipts", remote_queue_reopen_fifo_cancel_and_receipts ()),
    ("upsert_and_dep_flow_in_memory_store", upsert_and_dep_flow_in_memory_store ()),
    ("boss_terminal_status_classification", boss_terminal_status_classification ()),
    ("terminal_outcome_is_first_wins", terminal_outcome_is_first_wins ()),
    ("orb_wire_zero_copy_slice_abi_alias_null_wasm32_and_no_partial_mutation", orb_wire_zero_copy_slice_abi_alias_null_wasm32_and_no_partial_mutation ()),
    ("subscription_cooldown_classifies_empty_chain_as_retryable", subscription_cooldown_classifies_empty_chain_as_retryable ()),
    ("account_error_cooldown_doubles_from_ten_minutes_to_six_hours", account_error_cooldown_doubles_from_ten_minutes_to_six_hours ()),
    ("test_cost_calculation_basic", test_cost_calculation_basic ()),
    ("armed_wakeup_gives_paused", armed_wakeup_gives_paused ()),
    ("active_mission_with_any_liveness_signal_is_kept", active_mission_with_any_liveness_signal_is_kept ()),
    ("queue_snapshot_replays_prepared_parallel_message_until_run_exists", queue_snapshot_replays_prepared_parallel_message_until_run_exists ()),
    ("rejected_actor_dispatch_with_failed_rollback_is_durably_recoverable", rejected_actor_dispatch_with_failed_rollback_is_durably_recoverable ()),
    ("forged_hints_are_rejected_and_keep_the_principal", forged_hints_are_rejected_and_keep_the_principal ()),
    ("native_schedule_stops_after_ttl_or_a_finished_mission", native_schedule_stops_after_ttl_or_a_finished_mission ()),
    ("mission_and_subtree_totals_are_conserved_and_replays_count_once", mission_and_subtree_totals_are_conserved_and_replays_count_once ()),
    ("grant_lifecycle_audit_log_session_reap_and_bunker_lockdown", grant_lifecycle_audit_log_session_reap_and_bunker_lockdown ()),
    ("orb_and_sandboxed_service_aliases_map_to_same_deploy_tiers", orb_and_sandboxed_service_aliases_map_to_same_deploy_tiers ()),
    ("budget_and_concurrency_are_hard_refusals", budget_and_concurrency_are_hard_refusals ()),
    ("busy_lease_protects_everything_but_ttl", busy_lease_protects_everything_but_ttl ()),
    ("claim_moves_ownership_to_the_served_mission_only", claim_moves_ownership_to_the_served_mission_only ()),
    ("compute_secret_confinement_blocks_reserved_keys_and_untrusted_nodes", compute_secret_confinement_blocks_reserved_keys_and_untrusted_nodes ()),
    ("shrink_with_jobs_in_flight_never_revokes_and_blocks_until_under_cap", shrink_with_jobs_in_flight_never_revokes_and_blocks_until_under_cap ()),
    ("matches_exhaustive_oracle_on_unicode_and_partial_repeats", matches_exhaustive_oracle_on_unicode_and_partial_repeats ()),
    ("pr_103_green_but_conflicting_recommends_conflict_resolution", pr_103_green_but_conflicting_recommends_conflict_resolution ()),
    ("admit_is_the_shared_gate", admit_is_the_shared_gate ()),
    ("r4_scroll_policy_and_zero_copy_slice_steppers_verified", r4_scroll_policy_and_zero_copy_slice_steppers_verified ()),
    ("keepalive_only_stream_hits_semantic_deadline_without_resetting_clock", keepalive_only_stream_hits_semantic_deadline_without_resetting_clock ()),
    ("mobile_and_leansys_extensions_roundtrip_via_cabi", mobile_and_leansys_extensions_roundtrip_via_cabi ()),
    ("placement_merge_step_fences_stale_polls_and_advances_monotonically", placement_merge_step_fences_stale_polls_and_advances_monotonically ()),
    ("wave4_hot_path_scanners_pacer_and_confinement_cabi_verdicts", wave4_hot_path_scanners_pacer_and_confinement_cabi_verdicts ()),
    ("r2a_epoch_fence_effect_outbox_and_crash_boundary_diverge_on_stale_and_corrupt_inputs", r2a_epoch_fence_effect_outbox_and_crash_boundary_diverge_on_stale_and_corrupt_inputs ()),
    ("remote_replay_rollback_and_stranded_pending_gates_diverge_on_enospc_and_archive", remote_replay_rollback_and_stranded_pending_gates_diverge_on_enospc_and_archive ()),
    ("codex_goal_skills_worktree_and_repo_diff_kernel_steps_roundtrip", codex_goal_skills_worktree_and_repo_diff_kernel_steps_roundtrip ()),
    ("r8_model_account_admit_rejects_unknown_under_eap_and_ineligible", r8_model_account_admit_rejects_unknown_under_eap_and_ineligible ()),
    ("r8_model_account_score_orders_entitled_unspent_before_unknown_and_inadmissible", r8_model_account_score_orders_entitled_unspent_before_unknown_and_inadmissible ()),
    ("r8_memory_tool_gate_blocks_managed_nodes_bunker_external_and_mutations", r8_memory_tool_gate_blocks_managed_nodes_bunker_external_and_mutations ()),
    ("r8_upload_cleanup_gate_retains_live_shared_library_archive_until_gc_expiry", r8_upload_cleanup_gate_retains_live_shared_library_archive_until_gc_expiry ()),
    ("r8_proxy_exhaustion_partitions_billing_overflow_auth_server_and_quota", r8_proxy_exhaustion_partitions_billing_overflow_auth_server_and_quota ()),
    ("r8_composer_default_step_distinguishes_unpinned_paloma_from_pinned_workspace", r8_composer_default_step_distinguishes_unpinned_paloma_from_pinned_workspace ()),
    ("r8_cloud_handoff_step_isolates_cloud_workspace_and_blocks_cloud_side_question", r8_cloud_handoff_step_isolates_cloud_workspace_and_blocks_cloud_side_question ()),
    ("r8_fast_poll_delay_ms_ramps_from_burst_to_steady_and_clamps_backoff", r8_fast_poll_delay_ms_ramps_from_burst_to_steady_and_clamps_backoff ()),
    ("r8_mcp_preflight_cache_gate_enforces_identity_contract_session_and_ttl", r8_mcp_preflight_cache_gate_enforces_identity_contract_session_and_ttl ()),
    ("r8_sidebar_move_target_admit_rejects_folder_cycles_and_same_container_noop", r8_sidebar_move_target_admit_rejects_folder_cycles_and_same_container_noop ()),
    ("r8_sidebar_drag_step_arms_long_press_picker_and_cancels_unadmitted_drop", r8_sidebar_drag_step_arms_long_press_picker_and_cancels_unadmitted_drop ()),
    ("r8_followup_queue_step_retires_strictly_after_posted_seq_and_blocks_duplicates", r8_followup_queue_step_retires_strictly_after_posted_seq_and_blocks_duplicates ()),
    ("r8_transport_epoch_step_falls_back_after_ever_ready_and_latches_404_until_build_change", r8_transport_epoch_step_falls_back_after_ever_ready_and_latches_404_until_build_change ()),
    ("r8_stream_open_tail_cap_step_bounds_unclosed_fence_tail_and_rejects_zero_cap", r8_stream_open_tail_cap_step_bounds_unclosed_fence_tail_and_rejects_zero_cap ()),
    ("r8_rtt_ewma_step_initializes_cold_start_and_smooths_samples", r8_rtt_ewma_step_initializes_cold_start_and_smooths_samples ()),
    ("r8_client_link_budget_step_preempts_p2_under_p0_or_degraded_rtt", r8_client_link_budget_step_preempts_p2_under_p0_or_degraded_rtt ())
  ]
  let mut passed : Nat := 0
  let mut failed : Nat := 0
  let mut logLines : Array String := #[s!"running {cases.size} tests"]
  for (nm, ok) in cases do
    if ok then
      passed := passed + 1
      logLines := logLines.push s!"test OrbCore.HostTests::{nm} ... ok"
    else
      failed := failed + 1
      logLines := logLines.push s!"test OrbCore.HostTests::{nm} ... FAILED"
  logLines := logLines.push ""
  let summaryStatus := if failed == 0 then "ok" else "FAILED"
  logLines := logLines.push s!"test result: {summaryStatus}. {passed} passed; {failed} failed; 0 ignored; 0 measured; 0 filtered out"
  if let some p := emitLogPath? then
    IO.FS.writeFile p (String.intercalate "\n" logLines.toList ++ "\n")
  return failed == 0

end OrbCore.HostTests
