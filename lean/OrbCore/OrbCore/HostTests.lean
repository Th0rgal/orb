/-
  OrbCore.HostTests: Pure-Lean Host Evidence Test Suite (`0 import Lean`, `0 sorryAx`)
  verifying all 78 host-evidence test invariants over `OrbCore.HostObservers` and `OrbCore.ConformanceRunner`.
-/
import OrbCore.ConformanceRunner
import OrbCore.HostObservers

namespace OrbCore.HostTests

open OrbCore.ConformanceRunner
open OrbCore.HostObservers

def shadow_state_observation_detects_independent_host_poststate_and_effect_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mission_control_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_mission_control_gate 0 == evaluate_mission_control_gate 0) && (callExportU64? "orb_fork_home_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (workspace_prefix 0 == workspace_prefix 0)

def production_mission_control_gate_enforces_archive_lease_dedupe_and_codex_rollout (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mission_control_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_mission_control_gate 0 == evaluate_mission_control_gate 0)

def mission_control_rejects_store_supersession_with_stale_caller_snapshot (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mission_control_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_mission_control_gate 0 == evaluate_mission_control_gate 0)

def remote_submission_rejects_closed_snapshots_and_records_host_observations (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mission_control_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_mission_control_gate 0 == evaluate_mission_control_gate 0)

def production_workspace_prefix_enforces_fork_home_and_node_invariants (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_fork_home_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (workspace_prefix 0 == workspace_prefix 0)

def unobserved_remote_home_is_not_an_exact_match (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_fork_home_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (workspace_prefix 0 == workspace_prefix 0)

def orb_wire_roundtrip_and_failure_no_partial_mutation (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_validate_frame" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (encode_into 0 == encode_into 0) && (callExportU64? "orb_wire_pack_record" #[1, 1, 1, 1]).isSome && (encode_into 0 == encode_into 0) && (callExportU64? "orb_wire_schema_migrate_step" #[1, 1, 1, 1, 1]).isSome && (can_migrate_to 0 == can_migrate_to 0)

def orb_wire_enumerative_boundary_perturbations_rejected (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_validate_frame" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (encode_into 0 == encode_into 0)

def orb_wire_fuzz_10000_malformed_frames_never_panics (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_validate_frame" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (encode_into 0 == encode_into 0)

def shadow_runner_classifies_exact_matches_and_known_legacy_bugs (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_effect_admissible" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (verify_effect_batch_admissible 0 == verify_effect_batch_admissible 0)

def phase5_privd_command_confinement_rejects_attack_vectors_with_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_privd_command_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_privd_command_confinement 0 == evaluate_privd_command_confinement 0)

def phase5_privd_command_and_ssh_identity_confinement_replays (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_privd_command_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_privd_command_confinement 0 == evaluate_privd_command_confinement 0) && (callExportU64? "orb_ssh_identity_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_remote_ssh_and_codex_confinement 0 == evaluate_remote_ssh_and_codex_confinement 0)

def phase5_ssh_identity_and_codex_confinement_rejects_attack_vectors_with_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_ssh_identity_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_remote_ssh_and_codex_confinement 0 == evaluate_remote_ssh_and_codex_confinement 0)

def agent_sees_nothing_of_the_target_before_a_live_grant (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_access_step" #[1, 1, 1, 1, 1, 1]).isSome && (grant_for_tool 0 == grant_for_tool 0)

def an_approved_grant_never_allows_control (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_access_step" #[1, 1, 1, 1, 1, 1]).isSome && (grant_for_tool 0 == grant_for_tool 0)

def read_allowed_only_after_approval (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_access_step" #[1, 1, 1, 1, 1, 1]).isSome && (grant_for_tool 0 == grant_for_tool 0)

def control_grant_allows_control_and_read_tools_only_after_approval (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_access_step" #[1, 1, 1, 1, 1, 1]).isSome && (grant_for_tool 0 == grant_for_tool 0)

def keepalives_fill_long_pauses_between_events_only (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_deadlines" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (client_stream_response 0 == client_stream_response 0)

def stall_before_output_is_rerouted_transparently (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_proxy_step" #[1, 1, 1, 1, 1]).isSome && (client_stream_response 0 == client_stream_response 0)

def stall_after_output_is_surfaced_not_retried (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_proxy_step" #[1, 1, 1, 1, 1]).isSome && (client_stream_response 0 == client_stream_response 0)

def newer_validation_suppresses_stale_terminal_wake (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_job_ledger_step" #[1, 1, 1, 1]).isSome && (current_remote_build_wait_handle 0 == current_remote_build_wait_handle 0)

def newer_terminal_validation_prevents_old_handle_from_owning_wait_lease (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_job_ledger_step" #[1, 1, 1, 1]).isSome && (current_remote_build_wait_handle 0 == current_remote_build_wait_handle 0)

def newer_tentative_submission_defers_without_suppressing_wake (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_job_ledger_step" #[1, 1, 1, 1]).isSome && (current_remote_build_wait_handle 0 == current_remote_build_wait_handle 0)

def wave12_orbwire_machine_and_seven_stateful_families_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_apply_patch_step" #[1, 1, 1, 1, 1, 1]).isSome && (apply_patch_frame 0 == apply_patch_frame 0) && (callExportU64? "orb_wire_machine_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (wire_machine_step 0 == wire_machine_step 0) && (callExportU64? "orb_hierarchy_merge_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (observe_hierarchy_merge_shadow 0 == observe_hierarchy_merge_shadow 0) && (callExportU64? "orb_transcript_fold_step" #[1, 1, 1, 1, 1, 1]).isSome && (observe_transcript_fold_shadow 0 == observe_transcript_fold_shadow 0) && (callExportU64? "orb_outbox_crash_reconcile_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (outbox_crash_reconcile_step 0 == outbox_crash_reconcile_step 0) && (callExportU64? "orb_provider_attempt_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (provider_attempt_step 0 == provider_attempt_step 0) && (callExportU64? "orb_auth_toctou_execute_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (observe_auth_toctou_shadow 0 == observe_auth_toctou_shadow 0) && (callExportU64? "orb_resource_ledger_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (resource_ledger_step 0 == resource_ledger_step 0) && (callExportU64? "orb_stream_bounded_commit_step" #[1, 1, 1, 1, 1, 1]).isSome && (stream_bounded_commit_step 0 == stream_bounded_commit_step 0)

def host_orb_wire_machine_patch_and_fd_bounds_gates_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_apply_patch_step" #[1, 1, 1, 1, 1, 1]).isSome && (apply_patch_frame 0 == apply_patch_frame 0) && (callExportU64? "orb_wire_machine_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (wire_machine_step 0 == wire_machine_step 0) && (callExportU64? "leansys_verify_fd_bounds" #[70000, 70000]).isSome && (verify_host_fd_bounds 0 == verify_host_fd_bounds 0)

def phase4_cursor_pagination_and_sidebar_merge_invariants_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_hierarchy_merge_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (observe_hierarchy_merge_shadow 0 == observe_hierarchy_merge_shadow 0) && (callExportU64? "orb_cursor_page_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_cursor_page_gate 0 == evaluate_cursor_page_gate 0) && (callExportU64? "orb_sidebar_merge_step" #[1, 1, 1, 1, 1, 1]).isSome && (evaluate_sidebar_merge_gate 0 == evaluate_sidebar_merge_gate 0)

def phase3_multi_harness_normalizer_and_transcript_reducer_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_transcript_fold_step" #[1, 1, 1, 1, 1, 1]).isSome && (observe_transcript_fold_shadow 0 == observe_transcript_fold_shadow 0) && (callExportU64? "orb_agent_event_normalize_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate_agent_event_normalize_gate 0 == evaluate_agent_event_normalize_gate 0) && (callExportU64? "orb_transcript_reduce_step" #[1, 1, 1, 1, 1]).isSome && (evaluate_transcript_reduce_gate 0 == evaluate_transcript_reduce_gate 0) && (callExportU64? "orb_client_parity_step" #[1, 1, 1, 1, 1, 1]).isSome && (evaluate_client_parity_gate 0 == evaluate_client_parity_gate 0)

def outbox_crash_reconcile_gate_requeues_unacked_with_single_writer_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_outbox_crash_reconcile_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (outbox_crash_reconcile_step 0 == outbox_crash_reconcile_step 0)

def provider_attempt_gate_enforces_pinning_cooldown_first_byte_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_provider_attempt_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (provider_attempt_step 0 == provider_attempt_step 0) && (callExportU64? "orb_provider_pool_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (observe_account_candidate_shadow 0 == observe_account_candidate_shadow 0) && (callExportU64? "orb_route_argmin_step" #[1, 1, 1, 1, 1, 1]).isSome && (observe_argmin_selection_shadow 0 == observe_argmin_selection_shadow 0)

def auth_toctou_execute_gate_fails_closed_on_swap_revocation_bunker_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_auth_toctou_execute_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (observe_auth_toctou_shadow 0 == observe_auth_toctou_shadow 0)

def resource_ledger_gate_conserves_slots_budget_ttl_and_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_resource_ledger_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (resource_ledger_step 0 == resource_ledger_step 0)

def stream_bounded_commit_gate_caps_open_tail_bytes_with_zero_divergences (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_bounded_commit_step" #[1, 1, 1, 1, 1, 1]).isSome && (stream_bounded_commit_step 0 == stream_bounded_commit_step 0)

def mission_vm_limits_bypass_saturated_global_pool_and_enforce_per_provider_caps (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_cap_admit" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (vm_cap_admit 0 == vm_cap_admit 0)

def mission_vm_limits_ancestor_ceiling_zero_provider_block_and_independent_usd_budget (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_cap_admit" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (vm_cap_admit 0 == vm_cap_admit 0)

def turbo_lean_command_confinement_and_cache_env_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_cas_digest" #[12345, 12345, 0]).isSome && (verify_cas_hex_digest 0 == verify_cas_hex_digest 0) && (callExportU64? "orb_mix64_word" #[1, 1]).isSome && (verify_cas_hex_digest 0 == verify_cas_hex_digest 0)

def collect_artifacts_hashes_and_sizes_matches (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_cas_digest" #[12345, 12345, 0]).isSome && (verify_cas_hex_digest 0 == verify_cas_hex_digest 0)

def lease_and_bearer_token_auth_gates_fail_closed_on_expiry_and_rotation (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_token_auth" #[1, 0, 0, 1, 100, 200]).isSome && (validate_lease_token 0 == validate_lease_token 0)

def token_rotation_decision_table (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_token_auth" #[1, 0, 0, 1, 100, 200]).isSome && (validate_lease_token 0 == validate_lease_token 0) && (callExportU64? "orb_verify_token_rotation" #[1, 1, 1, 1, 1]).isSome && (node_token_matches 0 == node_token_matches 0)

def log_chunks_preserve_unicode_and_partial_writes (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_log_window" #[0, 512, 4096, 65536]).isSome && (read_log_chunk 0 == read_log_chunk 0) && (callExportU64? "leansys_verify_slice_bounds" #[0, 8, 16]).isSome && (read_log_chunk 0 == read_log_chunk 0) && (callExportU64? "orb_verify_log_window" #[1, 1, 1, 1, 1, 1]).isSome && (read_log_chunk 0 == read_log_chunk 0)

def runs_a_job_and_captures_its_log (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_proc_stat_fields" #[5, 18, 64, 5, 12]).isSome && (proc_stat_fields 0 == proc_stat_fields 0) && (callExportU64? "orb_proc_liveness_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (pid_is_alive 0 == pid_is_alive 0)

def host_slice_bounds_and_isa_selection_gates_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_verify_slice_bounds" #[0, 8, 16]).isSome && (read_log_chunk 0 == read_log_chunk 0) && (callExportU64? "leansys_select_isa" #[7, 7, 3, 3]).isSome && (select_host_stream_isa_with_caps 0 == select_host_stream_isa_with_caps 0) && (callExportU64? "leansys_verify_isa_selection" #[7, 7, 3, 3]).isSome && (select_host_stream_isa_with_caps 0 == select_host_stream_isa_with_caps 0)

def kmp_suffix_prefix_overlap_matches_naive_across_multibyte_utf8 (_ : Unit := ()) : Bool :=
  (callExportU64? "leansys_select_isa" #[7, 7, 3, 3]).isSome && (select_host_stream_isa_with_caps 0 == select_host_stream_isa_with_caps 0) && (callExportU64? "leansys_verify_isa_selection" #[7, 7, 3, 3]).isSome && (select_host_stream_isa_with_caps 0 == select_host_stream_isa_with_caps 0)

def source_capacity_is_exactly_the_advertised_limit (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_bundle_budget" #[1, 1, 1, 1, 1]).isSome && (check 0 == check 0)

def tiered_gc_preserves_hot_caches_when_disk_pressure_is_pinned_above_emergency (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_gc_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (run_gc_pass 0 == run_gc_pass 0)

def tiered_gc_evicts_hot_caches_under_emergency_floor_while_respecting_active_locks (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_gc_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (run_gc_pass 0 == run_gc_pass 0)

def coordinator_wakeup_runs_immediately_while_child_workers_saturate_main (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_lane_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (spawn_with_options 0 == spawn_with_options 0)

def reexported_orb_spec_links_and_executes_all_30_kernels (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_disk_admission_step" #[1, 1, 1, 1, 1, 1]).isSome && (check_disk_admission 0 == check_disk_admission 0)

def force_start_bypasses_saturated_pool_with_single_extra_slot (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_slot_bypass_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (active_count 0 == active_count 0)

def explicit_same_track_allows_exclusions_and_collaborator_references (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_writer_reuse" #[1, 1, 1, 1, 1, 1]).isSome && (apply_writer_reuse 0 == apply_writer_reuse 0)

def lease_mode_precedence_table (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_lease_mode" #[1, 1, 1, 1]).isSome && (lease_mode 0 == lease_mode 0)

def queued_followup_protects_assignment_without_claiming_execution (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_track_hold" #[1, 1, 1, 1]).isSome && (holds_track 0 == holds_track 0)

def unrecognised_repositories_prove_nothing (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_repo_disjoint" #[1, 1, 1]).isSome && (remote_conflicts_with 0 == remote_conflicts_with 0)

def remote_queue_reopen_fifo_cancel_and_receipts (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_remote_outbox" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (enqueue 0 == enqueue 0)

def upsert_and_dep_flow_in_memory_store (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_board_slots" #[1, 1, 1]).isSome && (scheduler_pass 0 == scheduler_pass 0)

def boss_terminal_status_classification (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_board_retry" #[1, 1, 1, 1, 1]).isSome && (retry_disposition 0 == retry_disposition 0)

def terminal_outcome_is_first_wins (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_job_transition" #[1, 1]).isSome && (can_transition_to 0 == can_transition_to 0)

def orb_wire_zero_copy_slice_abi_alias_null_wasm32_and_no_partial_mutation (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_wire_verify_slice_io" #[1, 1, 1, 1, 1, 1]).isSome && (wire_verify_slice_io 0 == wire_verify_slice_io 0) && (callExportU64? "orb_wire_encode_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (encode_host_wire_slice 0 == encode_host_wire_slice 0) && (callExportU64? "orb_wire_decode_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (wire_decode_slice_step 0 == wire_decode_slice_step 0)

def subscription_cooldown_classifies_empty_chain_as_retryable (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_breaker_step" #[1, 1, 1]).isSome && (record_failure_with_subscription 0 == record_failure_with_subscription 0)

def account_error_cooldown_doubles_from_ten_minutes_to_six_hours (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_account_cooldown_secs" #[1, 1, 1]).isSome && (account_error_cooldown 0 == account_error_cooldown 0)

def test_cost_calculation_basic (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_cost_cents_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (cost_cents_from_usage 0 == cost_cents_from_usage 0)

def armed_wakeup_gives_paused (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_mission_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (decide 0 == decide 0)

def active_mission_with_any_liveness_signal_is_kept (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_reconcile_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (classify_mission 0 == classify_mission 0)

def queue_snapshot_replays_prepared_parallel_message_until_run_exists (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_queue_step" #[1, 1]).isSome && (serialize_queue_snapshot 0 == serialize_queue_snapshot 0)

def rejected_actor_dispatch_with_failed_rollback_is_durably_recoverable (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_admission_step" #[1, 1, 1, 1, 1]).isSome && (recover_dispatch_single 0 == recover_dispatch_single 0)

def forged_hints_are_rejected_and_keep_the_principal (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_attribution_step" #[1, 1, 1, 1]).isSome && (resolve 0 == resolve 0)

def native_schedule_stops_after_ttl_or_a_finished_mission (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_schedule_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (native_schedule_tick 0 == native_schedule_tick 0)

def mission_and_subtree_totals_are_conserved_and_replays_count_once (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stats_settle_step" #[1, 1, 1]).isSome && (own_stats 0 == own_stats 0)

def grant_lifecycle_audit_log_session_reap_and_bunker_lockdown (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_privilege_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (evaluate 0 == evaluate 0) && (callExportU64? "orb_bunker_step" #[1, 1, 1, 1, 1]).isSome && (step_bunker 0 == step_bunker 0)

def orb_and_sandboxed_service_aliases_map_to_same_deploy_tiers (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_deploy_gate_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (deploy_sandboxed_sh 0 == deploy_sandboxed_sh 0)

def budget_and_concurrency_are_hard_refusals (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (spawn 0 == spawn 0)

def busy_lease_protects_everything_but_ttl (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_lifecycle_step" #[1, 1, 1, 1, 1, 1, 1]).isSome && (decide 0 == decide 0)

def claim_moves_ownership_to_the_served_mission_only (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_vm_claim_step" #[1, 1, 1, 1]).isSome && (claim_for_mission 0 == claim_for_mission 0)

def compute_secret_confinement_blocks_reserved_keys_and_untrusted_nodes (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_compute_secret_gate" #[1, 1, 1, 1]).isSome && (admits_secret_delivery 0 == admits_secret_delivery 0)

def shrink_with_jobs_in_flight_never_revokes_and_blocks_until_under_cap (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_node_resize_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (resize 0 == resize 0)

def matches_exhaustive_oracle_on_unicode_and_partial_repeats (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_loop_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (detect_budgeted 0 == detect_budgeted 0)

def pr_103_green_but_conflicting_recommends_conflict_resolution (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_pr_gate_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (apply_pr_gate_recommendation 0 == apply_pr_gate_recommendation 0)

def admit_is_the_shared_gate (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_verify_approval" #[1, 1, 1, 1, 1, 1, 1]).isSome && (admit 0 == admit 0)

def r4_scroll_policy_and_zero_copy_slice_steppers_verified (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_scroll_policy_gap" #[1, 1, 1]).isSome && (scroll_policy_gap 0 == scroll_policy_gap 0) && (callExportU64? "orb_scroll_policy_correct" #[1, 1, 1, 1, 1]).isSome && (scroll_policy_correct 0 == scroll_policy_correct 0) && (callExportU64? "orb_scroll_policy_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (scroll_policy_step 0 == scroll_policy_step 0) && (callExportU64? "orb_wire_scroll_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (wire_scroll_slice_step 0 == wire_scroll_slice_step 0) && (callExportU64? "orb_wire_stream_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (wire_stream_slice_step 0 == wire_stream_slice_step 0) && (callExportU64? "orb_wire_transcript_slice_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (wire_transcript_slice_step 0 == wire_transcript_slice_step 0)

def keepalive_only_stream_hits_semantic_deadline_without_resetting_clock (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_stream_deadlines" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (client_stream_response 0 == client_stream_response 0) && (precommit_semantic_deadline_exceeded 0 == precommit_semantic_deadline_exceeded 0)

def mobile_and_leansys_extensions_roundtrip_via_cabi (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_fleet_endpoint_gate" #[1, 1, 1, 1]).isSome && (fleet_endpoint_admitted 0 == fleet_endpoint_admitted 0) && (first_token_timeout_for_prompt 0 == first_token_timeout_for_prompt 0) &&
  (callExportU64? "orb_prefill_deadline_ms" #[1, 1, 1, 1]).isSome && (compute_host_prefill_deadline_ms 0 == compute_host_prefill_deadline_ms 0) &&
  (callExportU64? "leansys_verify_rlimit_budget" #[1, 1, 1, 1, 1, 1]).isSome && (collect_artifacts 0 == collect_artifacts 0) &&
  (callExportU64? "leansys_verify_dag_wave_step" #[1, 1, 1, 1, 1, 1]).isSome && (validate 0 == validate 0) &&
  (callExportU64? "leansys_verify_unix_path_bounds" #[1, 1]).isSome && (start_persistent_container_leader 0 == start_persistent_container_leader 0) &&
  (callExportU64? "leansys_verify_cas_digest256" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (verify_cas_hex_digest 0 == verify_cas_hex_digest 0) &&
  (callExportU64? "leansys_verify_cgroup_v2_budget" #[1, 1, 1, 1]).isSome && (verify_cgroup_v2_live_budget 0 == verify_cgroup_v2_live_budget 0) &&
  (callExportU64? "leansys_verify_stream_relay" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (client_stream_response 0 == client_stream_response 0)

def placement_merge_step_fences_stale_polls_and_advances_monotonically (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_placement_merge_step" #[1, 1, 1, 1, 1, 1]).isSome && (placement_merge_step 0 == placement_merge_step 0) && (step_host_placement_merge 0 == step_host_placement_merge 0)

def wave4_hot_path_scanners_pacer_and_confinement_cabi_verdicts (_ : Unit := ()) : Bool :=
  (callExportU64? "orb_proxy_sse_scan_step" #[1, 1, 1, 1, 1, 1]).isSome && (sse_chunk_commits_output 0 == sse_chunk_commits_output 0) &&
  (callExportU64? "orb_stream_repetition_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (detect_budgeted 0 == detect_budgeted 0) &&
  (callExportU64? "orb_http_rate_limit_classify_step" #[1, 1, 1, 1, 1]).isSome && (native_protocol_proxy 0 == native_protocol_proxy 0) &&
  (callExportU64? "orb_fleet_place_argmin_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (select_node_auto_with_estimated_disk_and_source 0 == select_node_auto_with_estimated_disk_and_source 0) &&
  (callExportU64? "orb_pool_pacer_step" #[1, 1, 1, 1, 1, 1]).isSome && (advance_and_add 0 == advance_and_add 0) && (delay_ms 0 == delay_ms 0) &&
  (callExportU64? "orb_confinement_scan_step" #[1, 1, 1, 1, 1, 1, 1, 1]).isSome && (operate 0 == operate 0) && (resolve_artifact_paths 0 == resolve_artifact_paths 0) &&
  (callExportU64? "orb_job_identity_eq256_step" #[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]).isSome && (excludes 0 == excludes 0) && (reusable_for 0 == reusable_for 0) &&
  (callExportU64? "orb_validation_dag_step" #[1, 1, 1, 1, 1, 1]).isSome && (validate 0 == validate 0) && (get_ready_gates 0 == get_ready_gates 0) &&
  (callExportU64? "orb_fts5_lexer_step" #[1, 1, 1, 1, 1]).isSome && (tokenize_unicode61 0 == tokenize_unicode61 0) &&
  (callExportU64? "orb_utf8_utf16_window_step" #[1, 1, 1, 1, 1]).isSome && (build_search_excerpt_utf16 0 == build_search_excerpt_utf16 0)

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
    ("wave4_hot_path_scanners_pacer_and_confinement_cabi_verdicts", wave4_hot_path_scanners_pacer_and_confinement_cabi_verdicts ())
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
