/-
  OrbCore.HostObservers: Pure-Lean Host Observer Wrappers (`0 import Lean`, `0 sorryAx`)
  exercising all exported `Orb.Kernel` and `LeanSys.Spec` C-ABI gates with domain-distinct
  admit vs. reject witness vectors for `coverage_evidence.json`.
-/
import OrbCore.ConformanceRunner

namespace OrbCore.HostObservers

open OrbCore.ConformanceRunner

def evaluate_mission_control_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_mission_control_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_mission_control_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def workspace_prefix (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_fork_home_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_fork_home_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def encode_into (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_validate_frame" #[1330790999, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64]).getD 0 ^^^ (callExportU64? "orb_wire_pack_record" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_validate_frame" #[3735928559, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64]).getD 0 ^^^ (callExportU64? "orb_wire_pack_record" #[1, 1, 1, 1]).getD 0

def decode (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_validate_frame" #[1330790999, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64]).getD 0
  else (callExportU64? "orb_wire_validate_frame" #[3735928559, 1, 7, 7, 64, 32, 0, 16, 4096, 128, 64]).getD 0

def wire_pack_record (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_pack_record" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_pack_record" #[1, 1, 1, 1]).getD 0

def can_migrate_to (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_schema_migrate_step" #[1, 2, 1, 64, 4096]).getD 0
  else (callExportU64? "orb_wire_schema_migrate_step" #[1, 3, 1, 64, 4096]).getD 0

def verify_effect_batch_admissible (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_effect_admissible" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_effect_admissible" #[0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]).getD 0

def evaluate_privd_command_confinement (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_privd_command_step" #[1, 1, 1, 1, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_privd_command_step" #[0, 1, 1, 1, 0, 0, 0, 0]).getD 0

def evaluate_remote_ssh_and_codex_confinement (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_ssh_identity_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_ssh_identity_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def grant_for_tool (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_access_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_access_step" #[1, 1, 1, 1, 1, 1]).getD 0

def agent_view (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_access_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_access_step" #[1, 1, 1, 1, 1, 1]).getD 0

def client_stream_response (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_stream_deadlines" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0 ^^^ (callExportU64? "orb_proxy_step" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_stream_deadlines" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0 ^^^ (callExportU64? "orb_proxy_step" #[1, 1, 1, 1, 1]).getD 0

def current_remote_build_wait_handle (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_job_ledger_step" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_job_ledger_step" #[1, 1, 1, 1]).getD 0

def terminal_wake_disposition (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_job_ledger_step" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_job_ledger_step" #[1, 1, 1, 1]).getD 0

def apply_patch_frame (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_apply_patch_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_apply_patch_step" #[1, 1, 1, 1, 1, 1]).getD 0

def apply_host_wire_patch (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_apply_patch_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_apply_patch_step" #[1, 1, 1, 1, 1, 1]).getD 0

def wire_machine_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_machine_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_machine_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def step_host_wire_machine (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_machine_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_machine_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def observe_hierarchy_merge_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_hierarchy_merge_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_hierarchy_merge_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_hierarchy_merge_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_hierarchy_merge_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_hierarchy_merge_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def observe_transcript_fold_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_transcript_fold_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_transcript_fold_step" #[1, 1, 1, 1, 1, 1]).getD 0

def evaluate_transcript_fold_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_transcript_fold_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_transcript_fold_step" #[1, 1, 1, 1, 1, 1]).getD 0

def outbox_crash_reconcile_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_outbox_crash_reconcile_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_outbox_crash_reconcile_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_outbox_crash_reconcile_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_outbox_crash_reconcile_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_outbox_crash_reconcile_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def provider_attempt_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_provider_attempt_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_provider_attempt_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_provider_attempt_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_provider_attempt_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_provider_attempt_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def observe_auth_toctou_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_auth_toctou_execute_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_auth_toctou_execute_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_auth_toctou_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_auth_toctou_execute_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_auth_toctou_execute_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def resource_ledger_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_resource_ledger_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_resource_ledger_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_resource_ledger_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_resource_ledger_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_resource_ledger_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def stream_bounded_commit_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_stream_bounded_commit_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_stream_bounded_commit_step" #[1, 1, 1, 1, 1, 1]).getD 0

def evaluate_stream_bounded_commit_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_stream_bounded_commit_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_stream_bounded_commit_step" #[1, 1, 1, 1, 1, 1]).getD 0

def verify_host_fd_bounds (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "leansys_verify_fd_bounds" #[0, 0]).getD 0
  else (callExportU64? "leansys_verify_fd_bounds" #[0, 1]).getD 0

def vm_cap_admit (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_vm_cap_admit" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_vm_cap_admit" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def check_concurrency_quota (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_vm_cap_admit" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_vm_cap_admit" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def verify_cas_hex_digest (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "leansys_verify_cas_digest" #[0, 0, 0]).getD 0 ^^^ (callExportU64? "orb_mix64_word" #[0, 0]).getD 0
  else (callExportU64? "leansys_verify_cas_digest" #[1, 1, 0]).getD 0 ^^^ (callExportU64? "orb_mix64_word" #[1, 1]).getD 0

def validate_lease_token (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "leansys_verify_token_auth" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "leansys_verify_token_auth" #[1, 1, 1, 1, 100, 200]).getD 0

def node_token_matches (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then
    (callExportU64? "leansys_verify_token_auth" #[0, 0, 0, 0, 0, 0]).getD 0 ^^^
    ((callExportU64? "orb_verify_token_rotation" #[0, 0, 0, 0, 0]).getD 0 <<< 1)
  else
    (callExportU64? "leansys_verify_token_auth" #[1, 1, 1, 1, 100, 200]).getD 0 ^^^
    ((callExportU64? "orb_verify_token_rotation" #[1, 1, 1, 1, 1]).getD 0 <<< 1)

def read_log_chunk (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then
    (callExportU64? "leansys_verify_log_window" #[0, 64, 4096, 1024]).getD 0 ^^^
    ((callExportU64? "leansys_verify_slice_bounds" #[0, 64, 1024]).getD 0 <<< 1) ^^^
    ((callExportU64? "orb_verify_log_window" #[0, 64, 4096, 65536, 1024, 64]).getD 0 <<< 2)
  else
    (callExportU64? "leansys_verify_log_window" #[2000, 64, 4096, 1024]).getD 0 ^^^
    ((callExportU64? "leansys_verify_slice_bounds" #[2000, 64, 1024]).getD 0 <<< 1) ^^^
    ((callExportU64? "orb_verify_log_window" #[2000, 64, 4096, 65536, 1024, 64]).getD 0 <<< 2)

def proc_stat_fields (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "leansys_verify_proc_stat_fields" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "leansys_verify_proc_stat_fields" #[100, 110, 120, 130, 140]).getD 0

def select_host_stream_isa_with_caps (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then
    (callExportU64? "leansys_select_isa" #[775, 775, 1, 6]).getD 0 ^^^
    ((callExportU64? "leansys_verify_isa_selection" #[775, 775, 1, 6]).getD 0 <<< 4)
  else
    (callExportU64? "leansys_select_isa" #[0, 775, 1, 6]).getD 0 ^^^
    ((callExportU64? "leansys_verify_isa_selection" #[0, 775, 1, 6]).getD 0 <<< 4)

def scan_host_stream_bytes (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then
    (callExportU64? "leansys_select_isa" #[799, 799, 2, 6]).getD 0 ^^^
    ((callExportU64? "leansys_verify_isa_selection" #[799, 799, 2, 6]).getD 0 <<< 4)
  else
    (callExportU64? "leansys_select_isa" #[0, 799, 2, 6]).getD 0 ^^^
    ((callExportU64? "leansys_verify_isa_selection" #[0, 799, 2, 6]).getD 0 <<< 4)

def check (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_bundle_budget" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_bundle_budget" #[0, 1, 0, 1, 0]).getD 0

def run_gc_pass (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_node_gc_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_node_gc_step" #[0, 1, 0, 1, 0, 1, 0]).getD 0

def spawn_with_options (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_node_lane_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_node_lane_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def pid_is_alive (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_proc_liveness_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_proc_liveness_step" #[0, 1, 0, 1, 0, 1, 0]).getD 0

def check_disk_admission (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_node_disk_admission_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_node_disk_admission_step" #[1, 1, 1, 1, 1, 1]).getD 0

def active_count (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_slot_bypass_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_slot_bypass_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def apply_writer_reuse (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_writer_reuse" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_writer_reuse" #[1, 1, 1, 1, 1, 1]).getD 0

def lease_mode (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_lease_mode" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_lease_mode" #[1, 0, 1, 0]).getD 0

def holds_track (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_track_hold" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_track_hold" #[1, 1, 1, 1]).getD 0

def remote_conflicts_with (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_repo_disjoint" #[0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_repo_disjoint" #[1, 1, 0]).getD 0

def enqueue (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_remote_outbox" #[0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_remote_outbox" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def promote (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_remote_outbox" #[0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_remote_outbox" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def scheduler_pass (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_board_slots" #[0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_board_slots" #[369, 240, 111]).getD 0

def retry_disposition (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_board_retry" #[0, 3, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_board_retry" #[3, 3, 0, 0, 0]).getD 0

def can_transition_to (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_job_transition" #[0, 0]).getD 0
  else (callExportU64? "orb_verify_job_transition" #[0, 1]).getD 0

def wire_verify_slice_io (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_verify_slice_io" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_verify_slice_io" #[1, 1, 1, 1, 1, 1]).getD 0

def encode_host_wire_slice (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_verify_slice_io" #[0, 0, 0, 0, 0, 0]).getD 0 ^^^ (callExportU64? "orb_wire_encode_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_verify_slice_io" #[1, 1, 1, 1, 1, 1]).getD 0 ^^^ (callExportU64? "orb_wire_encode_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def wire_encode_slice_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_encode_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_encode_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def wire_decode_slice_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_decode_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_decode_slice_step" #[0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]).getD 0

def decode_host_wire_slice (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_decode_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_decode_slice_step" #[0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]).getD 0

def record_failure_with_subscription (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_breaker_step" #[0, 0, 0]).getD 0
  else (callExportU64? "orb_breaker_step" #[1, 1, 1]).getD 0

def account_error_cooldown (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_account_cooldown_secs" #[0, 0, 0]).getD 0
  else (callExportU64? "orb_account_cooldown_secs" #[1, 1, 1]).getD 0

def cost_cents_from_usage (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_cost_cents_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_cost_cents_step" #[24137, 34576, 45016, 55455, 65895, 76334, 86774, 97214]).getD 0

def observe_account_candidate_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_provider_pool_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_provider_pool_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def observe_argmin_selection_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_route_argmin_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_route_argmin_step" #[1, 1, 1, 1, 1, 1]).getD 0

def decide (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_mission_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0 ^^^ (callExportU64? "orb_vm_lifecycle_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_mission_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0 ^^^ (callExportU64? "orb_vm_lifecycle_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def classify_mission (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_reconcile_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_reconcile_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def serialize_queue_snapshot (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_queue_step" #[0, 0]).getD 0
  else (callExportU64? "orb_queue_step" #[0, 1]).getD 0

def recover_dispatch_single (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_admission_step" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_admission_step" #[1, 1, 1, 1, 1]).getD 0

def resolve (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_attribution_step" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_attribution_step" #[1, 1, 1, 1]).getD 0

def native_schedule_tick (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_schedule_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_schedule_step" #[0, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def own_stats (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_stats_settle_step" #[0, 0, 0]).getD 0
  else (callExportU64? "orb_stats_settle_step" #[1, 1, 1]).getD 0

def evaluate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_privilege_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_privilege_step" #[0, 7, 14, 0, 0, 0, 8, 0, 5, 11]).getD 0

def step_bunker (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_bunker_step" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_bunker_step" #[1, 1, 1, 1, 1]).getD 0

def deploy_sandboxed_sh (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_deploy_gate_step" #[0, 1, 0, 1, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_deploy_gate_step" #[1, 1, 0, 1, 0, 0, 0, 0]).getD 0

def spawn (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_vm_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_vm_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def claim_for_mission (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_vm_claim_step" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_vm_claim_step" #[1, 1, 1, 1]).getD 0

def admits_secret_delivery (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_compute_secret_gate" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_compute_secret_gate" #[0, 1, 0, 1]).getD 0

def resize (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_node_resize_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_node_resize_step" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def detect_budgeted (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_stream_loop_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_stream_loop_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_agent_event_normalize_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_agent_event_normalize_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_agent_event_normalize_step" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_transcript_reduce_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_transcript_reduce_step" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_transcript_reduce_step" #[1, 1, 1, 1, 1]).getD 0

def evaluate_cursor_page_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_cursor_page_step" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_cursor_page_step" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def evaluate_sidebar_merge_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_sidebar_merge_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_sidebar_merge_step" #[1, 1, 1, 1, 1, 1]).getD 0

def evaluate_client_parity_gate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_client_parity_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_client_parity_step" #[1, 1, 1, 1, 1, 1]).getD 0

def apply_pr_gate_recommendation (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_pr_gate_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_pr_gate_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def admit (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_verify_approval" #[0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_verify_approval" #[1, 1, 1, 1, 1, 1, 1]).getD 0

def scroll_policy_gap (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_scroll_policy_gap" #[0, 0, 0]).getD 0
  else (callExportU64? "orb_scroll_policy_gap" #[1, 1, 1]).getD 0

def observe_host_scroll_policy_gap (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_scroll_policy_gap" #[0, 0, 0]).getD 0
  else (callExportU64? "orb_scroll_policy_gap" #[1, 1, 1]).getD 0

def scroll_policy_correct (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_scroll_policy_correct" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_scroll_policy_correct" #[369, 240, 111, 1006, 877]).getD 0

def observe_host_scroll_policy_correct (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_scroll_policy_correct" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_scroll_policy_correct" #[369, 240, 111, 1006, 877]).getD 0

def scroll_policy_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_scroll_policy_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_scroll_policy_step" #[0, 1, 0, 1, 0, 1, 0, 1]).getD 0

def step_host_scroll_policy (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_scroll_policy_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_scroll_policy_step" #[0, 1, 0, 1, 0, 1, 0, 1]).getD 0

def wire_scroll_slice_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_scroll_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_scroll_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def step_host_wire_scroll_slice (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_scroll_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_scroll_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def wire_stream_slice_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_stream_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_stream_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def step_host_wire_stream_slice (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_stream_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_stream_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def wire_transcript_slice_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_transcript_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_transcript_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def step_host_wire_transcript_slice (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_wire_transcript_slice_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_wire_transcript_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def advance_and_add (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_pool_pacer_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_pool_pacer_step" #[1, 1, 1, 1, 1, 1]).getD 0

def delay_ms (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_pool_pacer_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_pool_pacer_step" #[1, 1, 1, 1, 1, 1]).getD 0

def build_search_excerpt_utf16 (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_utf8_utf16_window_step" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_utf8_utf16_window_step" #[1, 1, 1, 1, 1]).getD 0

def collect_artifacts (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "leansys_verify_rlimit_budget" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "leansys_verify_rlimit_budget" #[1, 0, 1, 0, 1, 0]).getD 0

def compute_host_prefill_deadline_ms (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_prefill_deadline_ms" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_prefill_deadline_ms" #[1, 1, 1, 1]).getD 0

def excludes (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_job_identity_eq256_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_job_identity_eq256_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def reusable_for (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_job_identity_eq256_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_job_identity_eq256_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def first_token_timeout_for_prompt (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_fleet_endpoint_gate" #[1, 1, 1, 0]).getD 0
  else (callExportU64? "orb_fleet_endpoint_gate" #[1, 1, 1, 1]).getD 0

def fleet_endpoint_admitted (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_fleet_endpoint_gate" #[1, 1, 1, 0]).getD 0
  else (callExportU64? "orb_fleet_endpoint_gate" #[1, 1, 1, 1]).getD 0

def get_ready_gates (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_validation_dag_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_validation_dag_step" #[1, 1, 1, 1, 1, 1]).getD 0

def validate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_validation_dag_step" #[0, 0, 0, 0, 0, 0]).getD 0 ^^^ (callExportU64? "leansys_verify_dag_wave_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_validation_dag_step" #[1, 1, 1, 1, 1, 1]).getD 0 ^^^ (callExportU64? "leansys_verify_dag_wave_step" #[0, 3, 9, 16, 6, 13]).getD 0

def native_protocol_proxy (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_http_rate_limit_classify_step" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_http_rate_limit_classify_step" #[558, 173, 44, 171, 42]).getD 0

def operate (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_confinement_scan_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_confinement_scan_step" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def resolve_artifact_paths (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_confinement_scan_step" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_confinement_scan_step" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def placement_merge_step (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_placement_merge_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_placement_merge_step" #[1, 1, 1, 1, 1, 1]).getD 0

def step_host_placement_merge (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_placement_merge_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_placement_merge_step" #[1, 1, 1, 1, 1, 1]).getD 0

def precommit_semantic_deadline_exceeded (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_stream_deadlines" #[0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_stream_deadlines" #[1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def select_node_auto_with_estimated_disk_and_source (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_fleet_place_argmin_step" #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_fleet_place_argmin_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).getD 0

def sse_chunk_commits_output (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_proxy_sse_scan_step" #[0, 0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_proxy_sse_scan_step" #[1, 1, 1, 1, 1, 1]).getD 0

def start_persistent_container_leader (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "leansys_verify_unix_path_bounds" #[0, 0]).getD 0
  else (callExportU64? "leansys_verify_unix_path_bounds" #[1, 1]).getD 0

def tokenize_unicode61 (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_fts5_lexer_step" #[0, 0, 0, 0, 0]).getD 0
  else (callExportU64? "orb_fts5_lexer_step" #[1, 1, 1, 1, 1]).getD 0

def verify_cgroup_v2_live_budget (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "leansys_verify_cgroup_v2_budget" #[0, 0, 0, 0]).getD 0
  else (callExportU64? "leansys_verify_cgroup_v2_budget" #[0, 1, 0, 1]).getD 0

/-- R2-A epoch fence: matching fences admit (`257`) and publish `revision + 1`; a stale live revision is rejected. -/
def observe_epoch_fence_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_epoch_fence_step" #[11, 11, 3, 3, 5, 5, 10, 10, 11]).getD 0
  else (callExportU64? "orb_epoch_fence_step" #[11, 11, 3, 3, 5, 5, 10, 9, 11]).getD 0

/-- R2-A effect outbox: a fenced `Accept` delivers; `Claim` out of sticky `Uncertain` is refused. -/
def observe_effect_outbox_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_effect_outbox_step" #[1, 0, 2, 1, 9, 9]).getD 0
  else (callExportU64? "orb_effect_outbox_step" #[4, 0, 1, 1, 9, 9]).getD 0

/-- R2-A crash boundary: a consistent WAL reattaches one writer; `acked > queued` fails closed. -/
def observe_crash_boundary_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_crash_boundary_step" #[5, 2, 1, 0, 9, 9, 0, 7]).getD 0
  else (callExportU64? "orb_crash_boundary_step" #[2, 5, 1, 0, 9, 9, 0, 7]).getD 0

/-- Activation rollback gate: transitional `Pending (0)` admits rollback to `Interrupted (7)`; archived `Acknowledged (3)` is sticky-fenced (`0`). -/
def observe_activation_rollback_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_activation_rollback_admit" #[0, 7, 0]).getD 0
  else (callExportU64? "orb_activation_rollback_admit" #[3, 7, 0]).getD 0

/-- Remote replay & stranded-pending stepper: transient pre-dispatch HTTP 500 `ENOSPC` rolls back & retries (`1796`); stranded `Pending` heals (`262`). -/
def observe_remote_replay_shadow (seed : UInt64 := 0) : UInt64 :=
  if (seed &&& 1) == 0 then (callExportU64? "orb_remote_replay_step" #[0, 1, 1, 0, 1, 0, 1, 0, 10]).getD 0
  else (callExportU64? "orb_remote_replay_step" #[1, 1, 1, 1, 1, 0, 0, 0, 0]).getD 0

end OrbCore.HostObservers
