/-
  OrbCore.ConformanceRunner: Pure-Lean Shared Kernel Conformance & Fixture Runner (`orb-spec-runner`)
  covering all 164 C-ABI exports in `shared/orb-spec/kernel_abi.json` and shared projection fixtures.
-/
import Orb.Kernel
import LeanSys.Spec
import OrbBin.Json

namespace OrbCore.ConformanceRunner

open OrbBin.Json

-- Direct `@[extern]` imports to all 164 exported C-ABI symbols of `Orb.Kernel` and `LeanSys.Spec`.
@[extern "orb_verify_writer_reuse"]
private opaque c_fn_0 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt8
@[extern "orb_verify_lease_mode"]
private opaque c_fn_1 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "orb_verify_track_hold"]
private opaque c_fn_2 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "orb_verify_repo_disjoint"]
private opaque c_fn_3 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) : UInt8
@[extern "orb_verify_remote_outbox"]
private opaque c_fn_4 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) (a8 : UInt8) : UInt8
@[extern "orb_verify_board_slots"]
private opaque c_fn_5 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) : UInt8
@[extern "orb_verify_board_retry"]
private opaque c_fn_6 (a0 : UInt32) (a1 : UInt32) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) : UInt8
@[extern "orb_verify_job_transition"]
private opaque c_fn_7 (a0 : UInt8) (a1 : UInt8) : UInt8
@[extern "orb_verify_bundle_budget"]
private opaque c_fn_8 (a0 : UInt8) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) : UInt8
@[extern "orb_verify_token_rotation"]
private opaque c_fn_9 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) : UInt8
@[extern "orb_verify_approval"]
private opaque c_fn_10 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) : UInt8
@[extern "orb_verify_log_window"]
private opaque c_fn_11 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) : UInt8
@[extern "orb_mix64_word"]
private opaque c_fn_12 (a0 : UInt64) (a1 : UInt64) : UInt64
@[extern "orb_proxy_step"]
private opaque c_fn_13 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt32) (a4 : UInt32) : UInt32
@[extern "orb_stream_deadlines"]
private opaque c_fn_14 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) : UInt32
@[extern "orb_breaker_step"]
private opaque c_fn_15 (a0 : UInt8) (a1 : UInt32) (a2 : UInt32) : UInt32
@[extern "orb_mission_step"]
private opaque c_fn_16 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) (a8 : UInt32) (a9 : UInt32) : UInt8
@[extern "orb_reconcile_step"]
private opaque c_fn_17 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) (a8 : UInt8) (a9 : UInt8) (a10 : UInt8) (a11 : UInt8) (a12 : UInt8) : UInt8
@[extern "orb_queue_step"]
private opaque c_fn_18 (a0 : UInt8) (a1 : UInt8) : UInt32
@[extern "orb_vm_step"]
private opaque c_fn_19 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) (a8 : UInt32) (a9 : UInt32) (a10 : UInt32) (a11 : UInt32) (a12 : UInt32) (a13 : UInt64) (a14 : UInt64) : UInt8
@[extern "lp_orb_x2dspec_Orb_Kernel_accessStep___redArg"]
private opaque c_fn_20 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) : UInt32
@[extern "orb_access_step"]
private opaque c_fn_21 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt32
@[extern "orb_workfold_step"]
private opaque c_fn_22 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt32
@[extern "orb_taskcard_step"]
private opaque c_fn_23 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) : UInt8
@[extern "orb_sidebar_visibility"]
private opaque c_fn_24 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt32
@[extern "orb_admission_step"]
private opaque c_fn_25 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt64) (a4 : UInt64) : UInt32
@[extern "orb_account_cooldown_secs"]
private opaque c_fn_26 (a0 : UInt64) (a1 : UInt64) (a2 : UInt32) : UInt64
@[extern "orb_cost_cents_step"]
private opaque c_fn_27 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) : UInt64
@[extern "orb_stream_loop_step"]
private opaque c_fn_28 (a0 : UInt8) (a1 : UInt8) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) (a7 : UInt64) (a8 : UInt64) : UInt8
@[extern "orb_job_ledger_step"]
private opaque c_fn_29 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt32
@[extern "orb_proc_liveness_step"]
private opaque c_fn_30 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt32) (a5 : UInt64) (a6 : UInt64) : UInt8
@[extern "orb_pr_gate_step"]
private opaque c_fn_31 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) (a8 : UInt8) (a9 : UInt8) : UInt8
@[extern "orb_turn_summary_step"]
private opaque c_fn_32 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt32
@[extern "orb_usage_limit_status"]
private opaque c_fn_33 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt64) : UInt64
@[extern "orb_relative_time_bucket"]
private opaque c_fn_34 (a0 : UInt64) : UInt64
@[extern "orb_transcript_patch_step"]
private opaque c_fn_35 (a0 : UInt32) (a1 : UInt32) (a2 : UInt8) (a3 : UInt32) : UInt64
@[extern "orb_attribution_step"]
private opaque c_fn_36 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt32
@[extern "orb_schedule_step"]
private opaque c_fn_37 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt64) (a7 : UInt64) (a8 : UInt64) : UInt8
@[extern "orb_stats_settle_step"]
private opaque c_fn_38 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) : UInt64
@[extern "orb_privilege_step"]
private opaque c_fn_39 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt64) (a8 : UInt64) (a9 : UInt64) : UInt32
@[extern "orb_bunker_step"]
private opaque c_fn_40 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) : UInt32
@[extern "orb_deploy_gate_step"]
private opaque c_fn_41 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt32) : UInt8
@[extern "orb_scroll_max_top"]
private opaque c_fn_42 (a0 : UInt64) (a1 : UInt64) : UInt64
@[extern "orb_scroll_clamp_top"]
private opaque c_fn_43 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) : UInt64
@[extern "orb_scroll_gap"]
private opaque c_fn_44 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) : UInt64
@[extern "orb_scroll_layout_step"]
private opaque c_fn_45 (a0 : UInt8) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt64
@[extern "orb_scroll_user_step"]
private opaque c_fn_46 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt8
@[extern "orb_scroll_jump_step"]
private opaque c_fn_47 (a0 : UInt64) (a1 : UInt64) : UInt64
@[extern "orb_scroll_correct"]
private opaque c_fn_48 (a0 : UInt8) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt64
@[extern "orb_scroll_shows_jump"]
private opaque c_fn_49 (a0 : UInt8) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) : UInt8
@[extern "orb_stream_coalescer_step"]
private opaque c_fn_50 (a0 : UInt8) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) : UInt64
@[extern "orb_stream_fence_step"]
private opaque c_fn_51 (a0 : UInt8) (a1 : UInt32) (a2 : UInt8) (a3 : UInt32) : UInt64
@[extern "orb_stream_commit_step"]
private opaque c_fn_52 (a0 : UInt8) (a1 : UInt8) (a2 : UInt32) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt32) (a7 : UInt32) (a8 : UInt32) : UInt64
@[extern "orb_stream_token_cost_step"]
private opaque c_fn_53 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) : UInt64
@[extern "orb_mission_state_classify"]
private opaque c_fn_54 (a0 : UInt8) : UInt8
@[extern "orb_mission_sort_rank"]
private opaque c_fn_55 (a0 : UInt8) : UInt8
@[extern "orb_mission_flags"]
private opaque c_fn_56 (a0 : UInt8) : UInt32
@[extern "orb_mission_inbox_section"]
private opaque c_fn_57 (a0 : UInt8) : UInt8
@[extern "orb_connection_issue_classify"]
private opaque c_fn_58 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) : UInt32
@[extern "orb_worked_duration_bucket"]
private opaque c_fn_59 (a0 : UInt64) : UInt64
@[extern "orb_turn_outcome_step"]
private opaque c_fn_60 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt32
@[extern "orb_numeric_cell_scan"]
private opaque c_fn_61 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "orb_file_ref_line_span"]
private opaque c_fn_62 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) : UInt64
@[extern "orb_machine_action_admitted"]
private opaque c_fn_63 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) : UInt32
@[extern "orb_send_flow_step"]
private opaque c_fn_64 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt32) : UInt32
@[extern "orb_wire_validate_frame"]
private opaque c_fn_65 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) (a8 : UInt32) (a9 : UInt32) (a10 : UInt32) : UInt8
@[extern "orb_wire_pack_record"]
private opaque c_fn_66 (a0 : UInt8) (a1 : UInt8) (a2 : UInt32) (a3 : UInt32) : UInt64
@[extern "orb_wire_schema_migrate_step"]
private opaque c_fn_67 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt64) (a4 : UInt64) : UInt8
@[extern "orb_effect_admissible"]
private opaque c_fn_68 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) (a8 : UInt8) (a9 : UInt8) (a10 : UInt8) (a11 : UInt8) : UInt8
@[extern "orb_provider_pool_step"]
private opaque c_fn_69 (a0 : UInt8) (a1 : UInt32) (a2 : UInt32) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt32) (a7 : UInt32) (a8 : UInt64) (a9 : UInt64) : UInt64
@[extern "orb_route_argmin_step"]
private opaque c_fn_70 (a0 : UInt8) (a1 : UInt32) (a2 : UInt64) (a3 : UInt32) (a4 : UInt64) (a5 : UInt8) : UInt64
@[extern "orb_mission_control_step"]
private opaque c_fn_71 (a0 : UInt8) (a1 : UInt32) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) (a8 : UInt8) : UInt64
@[extern "orb_fork_home_step"]
private opaque c_fn_72 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) : UInt64
@[extern "orb_privd_command_step"]
private opaque c_fn_73 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) : UInt64
@[extern "orb_ssh_identity_step"]
private opaque c_fn_74 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) : UInt64
@[extern "orb_agent_event_normalize_step"]
private opaque c_fn_75 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) : UInt64
@[extern "orb_transcript_reduce_step"]
private opaque c_fn_76 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) : UInt64
@[extern "orb_cursor_page_step"]
private opaque c_fn_77 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) : UInt64
@[extern "orb_sidebar_merge_step"]
private opaque c_fn_78 (a0 : UInt32) (a1 : UInt32) (a2 : UInt64) (a3 : UInt64) (a4 : UInt8) (a5 : UInt8) : UInt64
@[extern "orb_scroll_epoch_step"]
private opaque c_fn_79 (a0 : UInt32) (a1 : UInt32) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt32) (a6 : UInt32) : UInt64
@[extern "orb_client_parity_step"]
private opaque c_fn_80 (a0 : UInt8) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) (a5 : UInt8) : UInt64
@[extern "orb_wire_apply_patch_step"]
private opaque c_fn_81 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) (a3 : UInt32) (a4 : UInt8) (a5 : UInt32) : UInt64
@[extern "orb_wire_machine_step"]
private opaque c_fn_82 (a0 : UInt32) (a1 : UInt64) (a2 : UInt64) (a3 : UInt8) (a4 : UInt8) (a5 : UInt32) (a6 : UInt32) : UInt64
@[extern "orb_hierarchy_merge_step"]
private opaque c_fn_83 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt32) (a8 : UInt32) (a9 : UInt8) (a10 : UInt8) (a11 : UInt8) : UInt64
@[extern "orb_transcript_fold_step"]
private opaque c_fn_84 (a0 : UInt64) (a1 : UInt64) (a2 : UInt32) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt64
@[extern "orb_outbox_crash_reconcile_step"]
private opaque c_fn_85 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt64) (a4 : UInt64) (a5 : UInt32) (a6 : UInt32) : UInt64
@[extern "orb_provider_attempt_step"]
private opaque c_fn_86 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt8) (a5 : UInt8) (a6 : UInt64) (a7 : UInt64) (a8 : UInt64) (a9 : UInt8) : UInt64
@[extern "orb_auth_toctou_execute_step"]
private opaque c_fn_87 (a0 : UInt8) (a1 : UInt8) (a2 : UInt32) (a3 : UInt32) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) (a8 : UInt64) (a9 : UInt64) : UInt32
@[extern "orb_resource_ledger_step"]
private opaque c_fn_88 (a0 : UInt8) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) (a8 : UInt64) : UInt64
@[extern "orb_stream_bounded_commit_step"]
private opaque c_fn_89 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) : UInt64
@[extern "leansys_verify_slice_bounds"]
private opaque c_fn_90 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) : UInt8
@[extern "leansys_verify_wal_frame"]
private opaque c_fn_91 (a0 : UInt32) (a1 : UInt32) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) : UInt8
@[extern "leansys_verify_cas_digest"]
private opaque c_fn_92 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) : UInt8
@[extern "leansys_check_http_bounds"]
private opaque c_fn_93 (a0 : UInt32) (a1 : UInt64) (a2 : UInt64) (a3 : UInt8) : UInt8
@[extern "leansys_verify_jsonl_tape"]
private opaque c_fn_94 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt32) : UInt8
@[extern "leansys_verify_ring_cursor"]
private opaque c_fn_95 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt8
@[extern "leansys_verify_sst_block"]
private opaque c_fn_96 (a0 : UInt32) (a1 : UInt32) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) : UInt8
@[extern "leansys_verify_poll_interest"]
private opaque c_fn_97 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) : UInt8
@[extern "leansys_verify_rlimit_budget"]
private opaque c_fn_98 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) : UInt8
@[extern "leansys_mix64_word"]
private opaque c_fn_99 (a0 : UInt64) (a1 : UInt64) : UInt64
@[extern "leansys_verify_composite_key_order"]
private opaque c_fn_100 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) : UInt8
@[extern "leansys_verify_token_auth"]
private opaque c_fn_101 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt64) (a5 : UInt64) : UInt8
@[extern "leansys_verify_log_window"]
private opaque c_fn_102 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt8
@[extern "leansys_verify_jsonrpc_frame"]
private opaque c_fn_103 (a0 : UInt8) (a1 : UInt8) (a2 : UInt32) (a3 : UInt64) : UInt8
@[extern "leansys_gate_admit"]
private opaque c_fn_104 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) : UInt8
@[extern "leansys_verify_mmap_seqlock"]
private opaque c_fn_105 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) (a8 : UInt64) : UInt8
@[extern "leansys_verify_proc_stat_fields"]
private opaque c_fn_106 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) : UInt8
@[extern "leansys_sse_frame_scan"]
private opaque c_fn_107 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt8
@[extern "leansys_gfm_pipe_scan"]
private opaque c_fn_108 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt32) (a4 : UInt32) (a5 : UInt8) : UInt8
@[extern "leansys_tag_scan"]
private opaque c_fn_109 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt8) : UInt8
@[extern "leansys_transcript_index"]
private opaque c_fn_110 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) : UInt64
@[extern "leansys_verify_par_chunk"]
private opaque c_fn_111 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt8
@[extern "leansys_verify_arena_disjoint"]
private opaque c_fn_112 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) : UInt8
@[extern "leansys_verify_snapshot_visibility"]
private opaque c_fn_113 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) : UInt8
@[extern "leansys_verify_http_route_match"]
private opaque c_fn_114 (a0 : UInt8) (a1 : UInt8) (a2 : UInt32) (a3 : UInt32) : UInt8
@[extern "leansys_verify_counterexample_triage"]
private opaque c_fn_115 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "leansys_verify_dag_wave_step"]
private opaque c_fn_116 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) : UInt8
@[extern "leansys_verify_ios_jetsam_budget"]
private opaque c_fn_117 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt8) : UInt8
@[extern "leansys_verify_worker_budget"]
private opaque c_fn_118 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt8) : UInt8
@[extern "leansys_verify_page_aligned_buffer"]
private opaque c_fn_119 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) : UInt8
@[extern "leansys_select_isa"]
private opaque c_fn_120 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "leansys_verify_isa_selection"]
private opaque c_fn_121 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "leansys_verify_fd_bounds"]
private opaque c_fn_122 (a0 : UInt64) (a1 : UInt32) : UInt8
@[extern "orb_vm_lifecycle_step"]
private opaque c_fn_123 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) : UInt32
@[extern "orb_vm_claim_step"]
private opaque c_fn_124 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt32
@[extern "orb_compute_secret_gate"]
private opaque c_fn_125 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt32
@[extern "orb_node_gc_step"]
private opaque c_fn_126 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) : UInt64
@[extern "orb_node_disk_admission_step"]
private opaque c_fn_127 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt8) : UInt64
@[extern "orb_vm_cap_admit"]
private opaque c_fn_128 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) (a8 : UInt32) (a9 : UInt32) (a10 : UInt32) : UInt32
@[extern "orb_slot_bypass_step"]
private opaque c_fn_129 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) : UInt32
@[extern "orb_node_resize_step"]
private opaque c_fn_130 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) : UInt64
@[extern "orb_node_lane_step"]
private opaque c_fn_131 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) (a8 : UInt32) (a9 : UInt32) (a10 : UInt32) : UInt32
@[extern "orb_wire_verify_slice_io"]
private opaque c_fn_132 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt8) : UInt8
@[extern "orb_wire_encode_slice_step"]
private opaque c_fn_133 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) (a7 : UInt8) : UInt8
@[extern "orb_wire_decode_slice_step"]
private opaque c_fn_134 (a0 : UInt64) (a1 : UInt64) (a2 : UInt8) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) (a8 : UInt32) (a9 : UInt32) (a10 : UInt32) (a11 : UInt32) : UInt8
@[extern "leansys_verify_unix_path_bounds"]
private opaque c_fn_135 (a0 : UInt64) (a1 : UInt8) : UInt8
@[extern "leansys_verify_cas_digest256"]
private opaque c_fn_136 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) (a8 : UInt8) : UInt8
@[extern "leansys_verify_sigv4_envelope"]
private opaque c_fn_137 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt32) (a4 : UInt8) (a5 : UInt8) : UInt8
@[extern "leansys_verify_cgroup_v2_budget"]
private opaque c_fn_138 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt8) : UInt8
@[extern "leansys_verify_io_uring_ring"]
private opaque c_fn_139 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) : UInt8
@[extern "leansys_verify_borrowed_view"]
private opaque c_fn_140 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt8
@[extern "leansys_verify_step_reactor"]
private opaque c_fn_141 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt32) (a5 : UInt32) (a6 : UInt8) : UInt8
@[extern "leansys_verify_stream_relay"]
private opaque c_fn_142 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) (a8 : UInt64) (a9 : UInt64) (a10 : UInt64) : UInt8
@[extern "orb_fleet_endpoint_gate"]
private opaque c_fn_143 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "orb_prefill_deadline_ms"]
private opaque c_fn_144 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) : UInt64
@[extern "orb_scroll_policy_gap"]
private opaque c_fn_145 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) : UInt64
@[extern "orb_scroll_policy_correct"]
private opaque c_fn_146 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) : UInt64
@[extern "orb_scroll_policy_step"]
private opaque c_fn_147 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) : UInt64
@[extern "orb_wire_scroll_slice_step"]
private opaque c_fn_148 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt8) (a8 : UInt8) (a9 : UInt64) (a10 : UInt64) (a11 : UInt64) (a12 : UInt64) : UInt64
@[extern "orb_wire_stream_slice_step"]
private opaque c_fn_149 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt8) (a5 : UInt32) (a6 : UInt32) (a7 : UInt32) (a8 : UInt32) (a9 : UInt32) (a10 : UInt32) : UInt64
@[extern "orb_wire_transcript_slice_step"]
private opaque c_fn_150 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt8) (a5 : UInt64) (a6 : UInt64) (a7 : UInt32) (a8 : UInt8) (a9 : UInt8) (a10 : UInt8) : UInt64
@[extern "orb_placement_merge_step"]
private opaque c_fn_151 (a0 : UInt64) (a1 : UInt64) (a2 : UInt32) (a3 : UInt32) (a4 : UInt8) (a5 : UInt8) : UInt64
@[extern "orb_proxy_sse_scan_step"]
private opaque c_fn_152 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt32
@[extern "orb_stream_repetition_step"]
private opaque c_fn_153 (a0 : UInt8) (a1 : UInt8) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) (a5 : UInt32) (a6 : UInt32) (a7 : UInt64) (a8 : UInt64) : UInt64
@[extern "orb_http_rate_limit_classify_step"]
private opaque c_fn_154 (a0 : UInt32) (a1 : UInt8) (a2 : UInt8) (a3 : UInt64) (a4 : UInt64) : UInt64
@[extern "orb_fleet_place_argmin_step"]
private opaque c_fn_155 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt8) (a7 : UInt32) (a8 : UInt32) (a9 : UInt32) (a10 : UInt32) (a11 : UInt32) (a12 : UInt32) (a13 : UInt64) (a14 : UInt64) : UInt8
@[extern "orb_pool_pacer_step"]
private opaque c_fn_156 (a0 : UInt8) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) : UInt64
@[extern "orb_confinement_scan_step"]
private opaque c_fn_157 (a0 : UInt8) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) (a6 : UInt32) (a7 : UInt32) : UInt32
@[extern "orb_job_identity_eq256_step"]
private opaque c_fn_158 (a0 : UInt64) (a1 : UInt64) (a2 : UInt64) (a3 : UInt64) (a4 : UInt64) (a5 : UInt64) (a6 : UInt64) (a7 : UInt64) (a8 : UInt8) (a9 : UInt8) : UInt32
@[extern "orb_validation_dag_step"]
private opaque c_fn_159 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt8) (a4 : UInt8) (a5 : UInt8) : UInt32
@[extern "orb_fts5_lexer_step"]
private opaque c_fn_160 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) : UInt64
@[extern "orb_utf8_utf16_window_step"]
private opaque c_fn_161 (a0 : UInt32) (a1 : UInt32) (a2 : UInt32) (a3 : UInt32) (a4 : UInt32) : UInt64
@[extern "orb_model_account_admit"]
private opaque c_fn_162 (a0 : UInt32) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) : UInt8
@[extern "orb_model_account_score"]
private opaque c_fn_163 (a0 : UInt32) (a1 : UInt8) (a2 : UInt8) (a3 : UInt8) (a4 : UInt8) (a5 : UInt32) (a6 : UInt32) : UInt64

private def callExportChunk0? (sym : String) (args : Array UInt64) : Option UInt64 :=
  if sym == "orb_verify_writer_reuse" && args.size == 6 then some ((c_fn_0 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "orb_verify_lease_mode" && args.size == 4 then some ((c_fn_1 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_verify_track_hold" && args.size == 4 then some ((c_fn_2 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_verify_repo_disjoint" && args.size == 3 then some ((c_fn_3 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8).toUInt64)
  else if sym == "orb_verify_remote_outbox" && args.size == 9 then some ((c_fn_4 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8 (args[8]!).toUInt8).toUInt64)
  else if sym == "orb_verify_board_slots" && args.size == 3 then some ((c_fn_5 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32).toUInt64)
  else if sym == "orb_verify_board_retry" && args.size == 5 then some ((c_fn_6 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8).toUInt64)
  else if sym == "orb_verify_job_transition" && args.size == 2 then some ((c_fn_7 (args[0]!).toUInt8 (args[1]!).toUInt8).toUInt64)
  else if sym == "orb_verify_bundle_budget" && args.size == 5 then some ((c_fn_8 (args[0]!).toUInt8 (args[1]!) (args[2]!) (args[3]!) (args[4]!)).toUInt64)
  else if sym == "orb_verify_token_rotation" && args.size == 5 then some ((c_fn_9 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8).toUInt64)
  else if sym == "orb_verify_approval" && args.size == 7 then some ((c_fn_10 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8).toUInt64)
  else if sym == "orb_verify_log_window" && args.size == 6 then some ((c_fn_11 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!)).toUInt64)
  else if sym == "orb_mix64_word" && args.size == 2 then some (c_fn_12 (args[0]!) (args[1]!))
  else if sym == "orb_proxy_step" && args.size == 5 then some ((c_fn_13 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt32 (args[4]!).toUInt32).toUInt64)
  else if sym == "orb_stream_deadlines" && args.size == 8 then some ((c_fn_14 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8).toUInt64)
  else if sym == "orb_breaker_step" && args.size == 3 then some ((c_fn_15 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!).toUInt32).toUInt64)
  else if sym == "orb_mission_step" && args.size == 10 then some ((c_fn_16 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt32).toUInt64)
  else if sym == "orb_reconcile_step" && args.size == 13 then some ((c_fn_17 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8 (args[8]!).toUInt8 (args[9]!).toUInt8 (args[10]!).toUInt8 (args[11]!).toUInt8 (args[12]!).toUInt8).toUInt64)
  else if sym == "orb_queue_step" && args.size == 2 then some ((c_fn_18 (args[0]!).toUInt8 (args[1]!).toUInt8).toUInt64)
  else if sym == "orb_vm_step" && args.size == 15 then some ((c_fn_19 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8 (args[8]!).toUInt32 (args[9]!).toUInt32 (args[10]!).toUInt32 (args[11]!).toUInt32 (args[12]!).toUInt32 (args[13]!) (args[14]!)).toUInt64)
  else if sym == "lp_orb_x2dspec_Orb_Kernel_accessStep___redArg" && args.size == 5 then some ((c_fn_20 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8).toUInt64)
  else if sym == "orb_access_step" && args.size == 6 then some ((c_fn_21 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "orb_workfold_step" && args.size == 6 then some ((c_fn_22 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "orb_taskcard_step" && args.size == 3 then some ((c_fn_23 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8).toUInt64)
  else if sym == "orb_sidebar_visibility" && args.size == 6 then some ((c_fn_24 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else none

private def callExportChunk1? (sym : String) (args : Array UInt64) : Option UInt64 :=
  if sym == "orb_admission_step" && args.size == 5 then some ((c_fn_25 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!) (args[4]!)).toUInt64)
  else if sym == "orb_account_cooldown_secs" && args.size == 3 then some (c_fn_26 (args[0]!) (args[1]!) (args[2]!).toUInt32)
  else if sym == "orb_cost_cents_step" && args.size == 8 then some (c_fn_27 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!) (args[6]!) (args[7]!))
  else if sym == "orb_stream_loop_step" && args.size == 9 then some ((c_fn_28 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!) (args[8]!)).toUInt64)
  else if sym == "orb_job_ledger_step" && args.size == 4 then some ((c_fn_29 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_proc_liveness_step" && args.size == 7 then some ((c_fn_30 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt32 (args[5]!) (args[6]!)).toUInt64)
  else if sym == "orb_pr_gate_step" && args.size == 10 then some ((c_fn_31 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8 (args[8]!).toUInt8 (args[9]!).toUInt8).toUInt64)
  else if sym == "orb_turn_summary_step" && args.size == 4 then some ((c_fn_32 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_usage_limit_status" && args.size == 6 then some (c_fn_33 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!))
  else if sym == "orb_relative_time_bucket" && args.size == 1 then some (c_fn_34 (args[0]!))
  else if sym == "orb_transcript_patch_step" && args.size == 4 then some (c_fn_35 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt8 (args[3]!).toUInt32)
  else if sym == "orb_attribution_step" && args.size == 4 then some ((c_fn_36 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_schedule_step" && args.size == 9 then some ((c_fn_37 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!) (args[7]!) (args[8]!)).toUInt64)
  else if sym == "orb_stats_settle_step" && args.size == 3 then some (c_fn_38 (args[0]!) (args[1]!) (args[2]!).toUInt8)
  else if sym == "orb_privilege_step" && args.size == 10 then some ((c_fn_39 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!) (args[8]!) (args[9]!)).toUInt64)
  else if sym == "orb_bunker_step" && args.size == 5 then some ((c_fn_40 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8).toUInt64)
  else if sym == "orb_deploy_gate_step" && args.size == 8 then some ((c_fn_41 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt32).toUInt64)
  else if sym == "orb_scroll_max_top" && args.size == 2 then some (c_fn_42 (args[0]!) (args[1]!))
  else if sym == "orb_scroll_clamp_top" && args.size == 3 then some (c_fn_43 (args[0]!) (args[1]!) (args[2]!))
  else if sym == "orb_scroll_gap" && args.size == 3 then some (c_fn_44 (args[0]!) (args[1]!) (args[2]!))
  else if sym == "orb_scroll_layout_step" && args.size == 4 then some (c_fn_45 (args[0]!).toUInt8 (args[1]!) (args[2]!) (args[3]!))
  else if sym == "orb_scroll_user_step" && args.size == 4 then some ((c_fn_46 (args[0]!) (args[1]!) (args[2]!) (args[3]!)).toUInt64)
  else if sym == "orb_scroll_jump_step" && args.size == 2 then some (c_fn_47 (args[0]!) (args[1]!))
  else if sym == "orb_scroll_correct" && args.size == 4 then some (c_fn_48 (args[0]!).toUInt8 (args[1]!) (args[2]!) (args[3]!))
  else if sym == "orb_scroll_shows_jump" && args.size == 5 then some ((c_fn_49 (args[0]!).toUInt8 (args[1]!) (args[2]!) (args[3]!) (args[4]!)).toUInt64)
  else none

private def callExportChunk2? (sym : String) (args : Array UInt64) : Option UInt64 :=
  if sym == "orb_stream_coalescer_step" && args.size == 4 then some (c_fn_50 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32)
  else if sym == "orb_stream_fence_step" && args.size == 4 then some (c_fn_51 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!).toUInt8 (args[3]!).toUInt32)
  else if sym == "orb_stream_commit_step" && args.size == 9 then some (c_fn_52 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt32 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!).toUInt32)
  else if sym == "orb_stream_token_cost_step" && args.size == 3 then some (c_fn_53 (args[0]!) (args[1]!) (args[2]!))
  else if sym == "orb_mission_state_classify" && args.size == 1 then some ((c_fn_54 (args[0]!).toUInt8).toUInt64)
  else if sym == "orb_mission_sort_rank" && args.size == 1 then some ((c_fn_55 (args[0]!).toUInt8).toUInt64)
  else if sym == "orb_mission_flags" && args.size == 1 then some ((c_fn_56 (args[0]!).toUInt8).toUInt64)
  else if sym == "orb_mission_inbox_section" && args.size == 1 then some ((c_fn_57 (args[0]!).toUInt8).toUInt64)
  else if sym == "orb_connection_issue_classify" && args.size == 5 then some ((c_fn_58 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8).toUInt64)
  else if sym == "orb_worked_duration_bucket" && args.size == 1 then some (c_fn_59 (args[0]!))
  else if sym == "orb_turn_outcome_step" && args.size == 6 then some ((c_fn_60 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "orb_numeric_cell_scan" && args.size == 4 then some ((c_fn_61 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_file_ref_line_span" && args.size == 3 then some (c_fn_62 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32)
  else if sym == "orb_machine_action_admitted" && args.size == 3 then some ((c_fn_63 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8).toUInt64)
  else if sym == "orb_send_flow_step" && args.size == 7 then some ((c_fn_64 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt32).toUInt64)
  else if sym == "orb_wire_validate_frame" && args.size == 11 then some ((c_fn_65 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt32 (args[10]!).toUInt32).toUInt64)
  else if sym == "orb_wire_pack_record" && args.size == 4 then some (c_fn_66 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt32 (args[3]!).toUInt32)
  else if sym == "orb_wire_schema_migrate_step" && args.size == 5 then some ((c_fn_67 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!) (args[4]!)).toUInt64)
  else if sym == "orb_effect_admissible" && args.size == 12 then some ((c_fn_68 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8 (args[8]!).toUInt8 (args[9]!).toUInt8 (args[10]!).toUInt8 (args[11]!).toUInt8).toUInt64)
  else if sym == "orb_provider_pool_step" && args.size == 10 then some (c_fn_69 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!) (args[9]!))
  else if sym == "orb_route_argmin_step" && args.size == 6 then some (c_fn_70 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!) (args[3]!).toUInt32 (args[4]!) (args[5]!).toUInt8)
  else if sym == "orb_mission_control_step" && args.size == 9 then some (c_fn_71 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8 (args[8]!).toUInt8)
  else if sym == "orb_fork_home_step" && args.size == 7 then some (c_fn_72 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8)
  else if sym == "orb_privd_command_step" && args.size == 8 then some (c_fn_73 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8)
  else if sym == "orb_ssh_identity_step" && args.size == 7 then some (c_fn_74 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8)
  else none

private def callExportChunk3? (sym : String) (args : Array UInt64) : Option UInt64 :=
  if sym == "orb_agent_event_normalize_step" && args.size == 8 then some (c_fn_75 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32)
  else if sym == "orb_transcript_reduce_step" && args.size == 5 then some (c_fn_76 (args[0]!) (args[1]!) (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8)
  else if sym == "orb_cursor_page_step" && args.size == 7 then some (c_fn_77 (args[0]!) (args[1]!) (args[2]!) (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32)
  else if sym == "orb_sidebar_merge_step" && args.size == 6 then some (c_fn_78 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!) (args[3]!) (args[4]!).toUInt8 (args[5]!).toUInt8)
  else if sym == "orb_scroll_epoch_step" && args.size == 7 then some (c_fn_79 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt32 (args[6]!).toUInt32)
  else if sym == "orb_client_parity_step" && args.size == 6 then some (c_fn_80 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt8)
  else if sym == "orb_wire_apply_patch_step" && args.size == 6 then some (c_fn_81 (args[0]!) (args[1]!) (args[2]!).toUInt8 (args[3]!).toUInt32 (args[4]!).toUInt8 (args[5]!).toUInt32)
  else if sym == "orb_wire_machine_step" && args.size == 7 then some (c_fn_82 (args[0]!).toUInt32 (args[1]!) (args[2]!) (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt32 (args[6]!).toUInt32)
  else if sym == "orb_hierarchy_merge_step" && args.size == 12 then some (c_fn_83 (args[0]!) (args[1]!) (args[2]!) (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt8 (args[10]!).toUInt8 (args[11]!).toUInt8)
  else if sym == "orb_transcript_fold_step" && args.size == 6 then some (c_fn_84 (args[0]!) (args[1]!) (args[2]!).toUInt32 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8)
  else if sym == "orb_outbox_crash_reconcile_step" && args.size == 7 then some (c_fn_85 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!) (args[4]!) (args[5]!).toUInt32 (args[6]!).toUInt32)
  else if sym == "orb_provider_attempt_step" && args.size == 10 then some (c_fn_86 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!) (args[7]!) (args[8]!) (args[9]!).toUInt8)
  else if sym == "orb_auth_toctou_execute_step" && args.size == 10 then some ((c_fn_87 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!) (args[5]!) (args[6]!) (args[7]!) (args[8]!) (args[9]!)).toUInt64)
  else if sym == "orb_resource_ledger_step" && args.size == 9 then some (c_fn_88 (args[0]!).toUInt8 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!) (args[5]!) (args[6]!) (args[7]!) (args[8]!))
  else if sym == "orb_stream_bounded_commit_step" && args.size == 6 then some (c_fn_89 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32)
  else if sym == "leansys_verify_slice_bounds" && args.size == 3 then some ((c_fn_90 (args[0]!) (args[1]!) (args[2]!)).toUInt64)
  else if sym == "leansys_verify_wal_frame" && args.size == 5 then some ((c_fn_91 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!) (args[3]!) (args[4]!)).toUInt64)
  else if sym == "leansys_verify_cas_digest" && args.size == 3 then some ((c_fn_92 (args[0]!) (args[1]!) (args[2]!).toUInt8).toUInt64)
  else if sym == "leansys_check_http_bounds" && args.size == 4 then some ((c_fn_93 (args[0]!).toUInt32 (args[1]!) (args[2]!) (args[3]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_jsonl_tape" && args.size == 6 then some ((c_fn_94 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!).toUInt32).toUInt64)
  else if sym == "leansys_verify_ring_cursor" && args.size == 4 then some ((c_fn_95 (args[0]!) (args[1]!) (args[2]!) (args[3]!)).toUInt64)
  else if sym == "leansys_verify_sst_block" && args.size == 6 then some ((c_fn_96 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!) (args[3]!) (args[4]!) (args[5]!)).toUInt64)
  else if sym == "leansys_verify_poll_interest" && args.size == 6 then some ((c_fn_97 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32).toUInt64)
  else if sym == "leansys_verify_rlimit_budget" && args.size == 6 then some ((c_fn_98 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!)).toUInt64)
  else if sym == "leansys_mix64_word" && args.size == 2 then some (c_fn_99 (args[0]!) (args[1]!))
  else none

private def callExportChunk4? (sym : String) (args : Array UInt64) : Option UInt64 :=
  if sym == "leansys_verify_composite_key_order" && args.size == 6 then some ((c_fn_100 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!)).toUInt64)
  else if sym == "leansys_verify_token_auth" && args.size == 6 then some ((c_fn_101 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!) (args[5]!)).toUInt64)
  else if sym == "leansys_verify_log_window" && args.size == 4 then some ((c_fn_102 (args[0]!) (args[1]!) (args[2]!) (args[3]!)).toUInt64)
  else if sym == "leansys_verify_jsonrpc_frame" && args.size == 4 then some ((c_fn_103 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt32 (args[3]!)).toUInt64)
  else if sym == "leansys_gate_admit" && args.size == 3 then some ((c_fn_104 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_mmap_seqlock" && args.size == 9 then some ((c_fn_105 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!) (args[4]!) (args[5]!) (args[6]!) (args[7]!) (args[8]!)).toUInt64)
  else if sym == "leansys_verify_proc_stat_fields" && args.size == 5 then some ((c_fn_106 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!)).toUInt64)
  else if sym == "leansys_sse_frame_scan" && args.size == 6 then some ((c_fn_107 (args[0]!) (args[1]!) (args[2]!) (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "leansys_gfm_pipe_scan" && args.size == 6 then some ((c_fn_108 (args[0]!) (args[1]!) (args[2]!) (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt8).toUInt64)
  else if sym == "leansys_tag_scan" && args.size == 6 then some ((c_fn_109 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!).toUInt8).toUInt64)
  else if sym == "leansys_transcript_index" && args.size == 5 then some (c_fn_110 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!))
  else if sym == "leansys_verify_par_chunk" && args.size == 4 then some ((c_fn_111 (args[0]!) (args[1]!) (args[2]!) (args[3]!)).toUInt64)
  else if sym == "leansys_verify_arena_disjoint" && args.size == 5 then some ((c_fn_112 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!)).toUInt64)
  else if sym == "leansys_verify_snapshot_visibility" && args.size == 3 then some ((c_fn_113 (args[0]!) (args[1]!) (args[2]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_http_route_match" && args.size == 4 then some ((c_fn_114 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt32 (args[3]!).toUInt32).toUInt64)
  else if sym == "leansys_verify_counterexample_triage" && args.size == 4 then some ((c_fn_115 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_dag_wave_step" && args.size == 6 then some ((c_fn_116 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!)).toUInt64)
  else if sym == "leansys_verify_ios_jetsam_budget" && args.size == 5 then some ((c_fn_117 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_worker_budget" && args.size == 5 then some ((c_fn_118 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_page_aligned_buffer" && args.size == 6 then some ((c_fn_119 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!)).toUInt64)
  else if sym == "leansys_select_isa" && args.size == 4 then some ((c_fn_120 (args[0]!) (args[1]!) (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_isa_selection" && args.size == 4 then some ((c_fn_121 (args[0]!) (args[1]!) (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_fd_bounds" && args.size == 2 then some ((c_fn_122 (args[0]!) (args[1]!).toUInt32).toUInt64)
  else if sym == "orb_vm_lifecycle_step" && args.size == 7 then some ((c_fn_123 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8).toUInt64)
  else if sym == "orb_vm_claim_step" && args.size == 4 then some ((c_fn_124 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else none

private def callExportChunk5? (sym : String) (args : Array UInt64) : Option UInt64 :=
  if sym == "orb_compute_secret_gate" && args.size == 4 then some ((c_fn_125 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_node_gc_step" && args.size == 7 then some (c_fn_126 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!) (args[6]!))
  else if sym == "orb_node_disk_admission_step" && args.size == 6 then some (c_fn_127 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!).toUInt8)
  else if sym == "orb_vm_cap_admit" && args.size == 11 then some ((c_fn_128 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt32 (args[10]!).toUInt32).toUInt64)
  else if sym == "orb_slot_bypass_step" && args.size == 7 then some ((c_fn_129 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32).toUInt64)
  else if sym == "orb_node_resize_step" && args.size == 8 then some (c_fn_130 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32)
  else if sym == "orb_node_lane_step" && args.size == 11 then some ((c_fn_131 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt32 (args[10]!).toUInt32).toUInt64)
  else if sym == "orb_wire_verify_slice_io" && args.size == 6 then some ((c_fn_132 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!).toUInt8).toUInt64)
  else if sym == "orb_wire_encode_slice_step" && args.size == 8 then some ((c_fn_133 (args[0]!) (args[1]!) (args[2]!) (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt8).toUInt64)
  else if sym == "orb_wire_decode_slice_step" && args.size == 12 then some ((c_fn_134 (args[0]!) (args[1]!) (args[2]!).toUInt8 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt32 (args[10]!).toUInt32 (args[11]!).toUInt32).toUInt64)
  else if sym == "leansys_verify_unix_path_bounds" && args.size == 2 then some ((c_fn_135 (args[0]!) (args[1]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_cas_digest256" && args.size == 9 then some ((c_fn_136 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!) (args[6]!) (args[7]!) (args[8]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_sigv4_envelope" && args.size == 6 then some ((c_fn_137 (args[0]!) (args[1]!) (args[2]!) (args[3]!).toUInt32 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_cgroup_v2_budget" && args.size == 4 then some ((c_fn_138 (args[0]!) (args[1]!) (args[2]!) (args[3]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_io_uring_ring" && args.size == 5 then some ((c_fn_139 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32).toUInt64)
  else if sym == "leansys_verify_borrowed_view" && args.size == 4 then some ((c_fn_140 (args[0]!) (args[1]!) (args[2]!) (args[3]!)).toUInt64)
  else if sym == "leansys_verify_step_reactor" && args.size == 7 then some ((c_fn_141 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt8).toUInt64)
  else if sym == "leansys_verify_stream_relay" && args.size == 11 then some ((c_fn_142 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!) (args[5]!) (args[6]!) (args[7]!) (args[8]!) (args[9]!) (args[10]!)).toUInt64)
  else if sym == "orb_fleet_endpoint_gate" && args.size == 4 then some ((c_fn_143 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_prefill_deadline_ms" && args.size == 4 then some (c_fn_144 (args[0]!) (args[1]!) (args[2]!) (args[3]!))
  else if sym == "orb_scroll_policy_gap" && args.size == 3 then some (c_fn_145 (args[0]!) (args[1]!) (args[2]!))
  else if sym == "orb_scroll_policy_correct" && args.size == 5 then some (c_fn_146 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!))
  else if sym == "orb_scroll_policy_step" && args.size == 8 then some (c_fn_147 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!) (args[5]!) (args[6]!) (args[7]!))
  else if sym == "orb_wire_scroll_slice_step" && args.size == 13 then some (c_fn_148 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt8 (args[8]!).toUInt8 (args[9]!) (args[10]!) (args[11]!) (args[12]!))
  else if sym == "orb_wire_stream_slice_step" && args.size == 11 then some (c_fn_149 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!).toUInt8 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt32 (args[10]!).toUInt32)
  else none

private def callExportChunk6? (sym : String) (args : Array UInt64) : Option UInt64 :=
  if sym == "orb_wire_transcript_slice_step" && args.size == 11 then some (c_fn_150 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!).toUInt8 (args[5]!) (args[6]!) (args[7]!).toUInt32 (args[8]!).toUInt8 (args[9]!).toUInt8 (args[10]!).toUInt8)
  else if sym == "orb_placement_merge_step" && args.size == 6 then some (c_fn_151 (args[0]!) (args[1]!) (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt8 (args[5]!).toUInt8)
  else if sym == "orb_proxy_sse_scan_step" && args.size == 6 then some ((c_fn_152 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "orb_stream_repetition_step" && args.size == 9 then some (c_fn_153 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32 (args[5]!).toUInt32 (args[6]!).toUInt32 (args[7]!) (args[8]!))
  else if sym == "orb_http_rate_limit_classify_step" && args.size == 5 then some (c_fn_154 (args[0]!).toUInt32 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!) (args[4]!))
  else if sym == "orb_fleet_place_argmin_step" && args.size == 15 then some ((c_fn_155 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt8 (args[7]!).toUInt32 (args[8]!).toUInt32 (args[9]!).toUInt32 (args[10]!).toUInt32 (args[11]!).toUInt32 (args[12]!).toUInt32 (args[13]!) (args[14]!)).toUInt64)
  else if sym == "orb_pool_pacer_step" && args.size == 6 then some (c_fn_156 (args[0]!).toUInt8 (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!))
  else if sym == "orb_confinement_scan_step" && args.size == 8 then some ((c_fn_157 (args[0]!).toUInt8 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8 (args[6]!).toUInt32 (args[7]!).toUInt32).toUInt64)
  else if sym == "orb_job_identity_eq256_step" && args.size == 10 then some ((c_fn_158 (args[0]!) (args[1]!) (args[2]!) (args[3]!) (args[4]!) (args[5]!) (args[6]!) (args[7]!) (args[8]!).toUInt8 (args[9]!).toUInt8).toUInt64)
  else if sym == "orb_validation_dag_step" && args.size == 6 then some ((c_fn_159 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt8).toUInt64)
  else if sym == "orb_fts5_lexer_step" && args.size == 5 then some (c_fn_160 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32)
  else if sym == "orb_utf8_utf16_window_step" && args.size == 5 then some (c_fn_161 (args[0]!).toUInt32 (args[1]!).toUInt32 (args[2]!).toUInt32 (args[3]!).toUInt32 (args[4]!).toUInt32)
  else if sym == "orb_model_account_admit" && args.size == 4 then some ((c_fn_162 (args[0]!).toUInt32 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8).toUInt64)
  else if sym == "orb_model_account_score" && args.size == 7 then some (c_fn_163 (args[0]!).toUInt32 (args[1]!).toUInt8 (args[2]!).toUInt8 (args[3]!).toUInt8 (args[4]!).toUInt8 (args[5]!).toUInt32 (args[6]!).toUInt32)
  else none

/-- Dispatch any of the 164 C-ABI exports by symbol name and `UInt64` argument vector. -/
def callExportU64? (sym : String) (args : Array UInt64) : Option UInt64 :=
  (callExportChunk0? sym args) <|> (callExportChunk1? sym args) <|> (callExportChunk2? sym args) <|> (callExportChunk3? sym args) <|> (callExportChunk4? sym args) <|> (callExportChunk5? sym args) <|> (callExportChunk6? sym args)

private def boolBit (v : JVal) (k : String) : UInt8 :=
  if (v.fieldBool? k).getD false then 1 else 0

private def prGateRecommendation : UInt8 → String
  | 0 => "already_merged"
  | 1 => "wait_for_ready_for_review"
  | 2 => "closed_without_merge"
  | 3 => "head_changed_since_worker"
  | 4 => "action_required_external"
  | 5 => "blocked_by_policy"
  | 6 => "needs_update_with_base"
  | 7 => "needs_conflict_resolution"
  | 8 => "ready_for_review_or_merge"
  | _ => "needs_checks_or_review"

private def taskcardLabel : UInt8 → String
  | 0 => "live"
  | 1 => "done"
  | 2 => "stale"
  | _ => "stopped"

private def formatRelTimeSecs (secs : Int) : String :=
  let elapsed : UInt64 := if secs ≤ 0 then 0 else secs.toNat.toUInt64
  let packed := Orb.Kernel.relativeTimeBucket elapsed
  let unit := (packed &&& 0xFF).toUInt8
  let val := ((packed >>> 8) &&& 0xFFFFFFFF).toUInt32
  match unit with
  | 0 => "now"
  | 1 => s!"{val}m"
  | 2 => s!"{val}h"
  | 3 => s!"{val}d"
  | _ => s!"{val}w"

private def parseRoundedPct? (rawNum : String) : Option UInt8 :=
  -- Parse decimal float `u` (e.g. `0.88`, `0.934`, `1.5`, `0`, `1`) into `round(u * 100.0).clamp(0, 255) : UInt8`
  let s := rawNum.trimAscii.toString
  if s.startsWith "-" then some 0
  else
    match s.splitOn "." with
    | [intPart] =>
      match intPart.toNat? with
      | none => none
      | some iv => some (Nat.min 255 (iv * 100)).toUInt8
    | [intPart, fracPart] =>
      match intPart.toNat? with
      | none => none
      | some iv =>
        let padded := (fracPart ++ "000").take 3
        match padded.toString.toNat? with
        | none => none
        | some milli =>
          let totalMilli := iv * 1000 + milli
          let pct := (totalMilli + 5) / 10
          some (Nat.min 255 pct).toUInt8
    | _ => none

private def evalUsageLimitLabel (usage : JVal) (nowSec : UInt64) : Option (String × String) :=
  let status := ((usage.fieldStr? "unified_status").getD "").toLower
  let statusKind : UInt8 :=
    if status == "" || status == "allowed" || status == "ok" then 0
    else if status == "allowed_warning" then 1
    else if status == "rejected" then 2
    else 3
  let claim := (usage.fieldStr? "unified_representative_claim").getD ""
  let (claimKind, utilKey?) : UInt8 × Option String :=
    if claim == "five_hour" then (1, some "unified_5h_utilization")
    else if claim == "seven_day" then (2, some "unified_7d_utilization")
    else if claim == "seven_day_opus" then (3, none)
    else if claim == "seven_day_sonnet" then (4, none)
    else (0, none)
  let pctOpt : Option UInt8 := do
    let k ← utilKey?
    let fVal ← usage.field? k
    match fVal with
    | .num raw => parseRoundedPct? raw
    | _ => none
  let resetOpt := usage.fieldUInt64? "unified_reset"
  let remSecs : UInt64 := match resetOpt with
    | some r => if r > nowSec then r - nowSec else 0
    | none => 0
  let w := Orb.Kernel.usageLimitStatus
    statusKind
    claimKind
    (if pctOpt.isSome then 1 else 0)
    (pctOpt.getD 0)
    (if resetOpt.isSome then 1 else 0)
    remSecs
  let toneCode := (w &&& 0xFF).toUInt8
  let winKind := ((w >>> 8) &&& 0xFF).toUInt8
  let showPct := ((w >>> 16) &&& 0xFF).toUInt8 != 0
  let pct := ((w >>> 24) &&& 0xFF).toUInt8
  let resetUnit := ((w >>> 32) &&& 0xFF).toUInt8
  let resetVal := ((w >>> 40) &&& 0xFFFFFF).toUInt32
  if toneCode == 0 then none
  else if toneCode ≥ 3 then some ("warning", "Limit status unknown")
  else Id.run do
    let tone := if toneCode == 1 then "warning" else "error"
    let mut label := if toneCode == 1 then "Approaching limit" else "Limit reached"
    let winStr := match winKind with
      | 1 => "5h"
      | 2 => "weekly"
      | 3 => "weekly Opus"
      | 4 => "weekly Sonnet"
      | _ => ""
    if !winStr.isEmpty then
      label := label ++ s!" · {winStr}"
      if showPct then
        label := label ++ s!" {pct}%"
    let unitStr := match resetUnit with
      | 1 => "m"
      | 2 => "h"
      | 3 => "d"
      | _ => ""
    if !unitStr.isEmpty then
      label := label ++ s!" · resets in {resetVal}{unitStr}"
    return some (tone, label)

/-- Replay all `shared/orb-spec/fixtures/{projection-invariants,relative-time,usage-limit-status}.json` cases
    against `Orb.Kernel` exports (`--fixtures <dir>`). -/
def runSharedFixtures (fixturesDir : String) : IO UInt32 := do
  let projRaw ← IO.FS.readFile s!"{fixturesDir}/projection-invariants.json"
  let .ok projDoc := parse projRaw
    | do IO.eprintln "[orb-spec-runner] FAIL: parse projection-invariants.json"; return 1
  let covered := #["workfold_cases", "taskcard_cases", "sidebar_visibility_cases", "pr_gate_cases", "turn_summary_cases", "transcript_patch_cases"]
  for (k, v) in (projDoc.asObj?.getD #[]) do
    if v.asArr?.isSome && !covered.contains k then
      IO.eprintln s!"[orb-spec-runner] FAIL: uncovered fixture list {k}"
      return 1

  for c in (projDoc.fieldArr? "workfold_cases").getD #[] do
    let i := c.fieldOrNull "input"
    let e := c.fieldOrNull "expected"
    let kind : UInt8 := if boolBit i "is_text" == 1 then 2 else 5
    let packed := Orb.Kernel.workfoldStep kind (boolBit i "cumulative") (boolBit i "non_empty")
      (boolBit i "tool_ahead") (boolBit i "next_is_tool") (boolBit i "fold_has_tool")
    let foldItem := (packed &&& 0xFF) == 1
    let foldNext := ((packed >>> 8) &&& 0xFF) == 1
    if foldItem != ((e.fieldBool? "fold").getD false) ||
       foldNext != ((e.fieldBool? "next_fold_has_tool").getD false) then
      let cname := (c.fieldStr? "name").getD ""
      IO.eprintln s!"[orb-spec-runner] FAIL: workfold mismatch {cname}"
      return 1

  for c in (projDoc.fieldArr? "taskcard_cases").getD #[] do
    let i := c.fieldOrNull "input"
    let e := c.fieldOrNull "expected"
    let ended := boolBit i "ended"
    let closed := boolBit i "all_done_or_cancelled"
    let fin := boolBit i "outcome_finished"
    let stCode := Orb.Kernel.taskcardStep ended closed fin
    let stStr := taskcardLabel stCode
    let tsPacked := Orb.Kernel.turnSummaryStep 1 ended closed fin
    let isActive := ((tsPacked >>> 16) &&& 0xFF) == 1
    let clearInProg := ((i.fieldBool? "has_open_tasks").getD false) && !isActive
    if stStr != ((e.fieldStr? "state").getD "") ||
       (stStr == "stale") != ((e.fieldBool? "mark_open_stale").getD false) ||
       clearInProg != ((e.fieldBool? "clear_in_progress").getD false) then
      let cname := (c.fieldStr? "name").getD ""
      IO.eprintln s!"[orb-spec-runner] FAIL: taskcard mismatch {cname}"
      return 1

  for c in (projDoc.fieldArr? "sidebar_visibility_cases").getD #[] do
    let i := c.fieldOrNull "input"
    let e := c.fieldOrNull "expected"
    let isArch := (i.fieldBool? "is_archived").getD false
    let isSup := (i.fieldBool? "is_superseded").getD false
    let isWork := (i.fieldBool? "is_working").getD false
    let isSel := (i.fieldBool? "is_selected").getD false
    let mf : UInt8 := if !isArch && (!isSup || isWork || isSel) then 1 else 0
    let vis := Orb.Kernel.sidebarVisibility mf (boolBit i "has_visible_descendant") (if isArch then 1 else 0) 0 0 0
    let retain := (vis &&& 0xFF) == 1
    let archOnly := ((vis >>> 8) &&& 0xFF) == 1
    if retain != ((e.fieldBool? "show_in_main_tree").getD false) ||
       archOnly != ((e.fieldBool? "show_in_archive_only").getD false) then
      let cname := (c.fieldStr? "name").getD ""
      IO.eprintln s!"[orb-spec-runner] FAIL: sidebar mismatch {cname}"
      return 1

  for c in (projDoc.fieldArr? "pr_gate_cases").getD #[] do
    let i := c.fieldOrNull "input"
    let e := c.fieldOrNull "expected"
    let code := Orb.Kernel.prGateStep
      (boolBit i "merged") (boolBit i "draft") (boolBit i "closed") (boolBit i "exact_head")
      (boolBit i "action_required") (boolBit i "blocked") (boolBit i "behind")
      (boolBit i "conflicting") (boolBit i "checks_green") (boolBit i "workflows_green")
    if code.toUInt64 != ((e.fieldUInt64? "code").getD 999) ||
       prGateRecommendation code != ((e.fieldStr? "recommendation").getD "") then
      let cname := (c.fieldStr? "name").getD ""
      IO.eprintln s!"[orb-spec-runner] FAIL: pr_gate mismatch {cname}"
      return 1

  for c in (projDoc.fieldArr? "turn_summary_cases").getD #[] do
    let i := c.fieldOrNull "input"
    let e := c.fieldOrNull "expected"
    let rawSt := ((i.fieldUInt64? "raw_status").getD 0).toUInt8
    let ts := Orb.Kernel.turnSummaryStep rawSt (boolBit i "turn_ended") (boolBit i "all_closed") (boolBit i "turn_outcome_finished")
    let norm := (ts &&& 0xFF).toUInt8
    let done := ((ts >>> 8) &&& 0xFF) == 1
    let active := ((ts >>> 16) &&& 0xFF) == 1
    let card := ((ts >>> 24) &&& 0xFF).toUInt8
    if norm.toUInt64 != ((e.fieldUInt64? "normalized_status").getD 99) ||
       done != ((e.fieldBool? "is_done").getD false) ||
       active != ((e.fieldBool? "is_active").getD false) ||
       card.toUInt64 != ((e.fieldUInt64? "card_state").getD 99) then
      let cname := (c.fieldStr? "name").getD ""
      IO.eprintln s!"[orb-spec-runner] FAIL: turn_summary mismatch {cname}"
      return 1

  for c in (projDoc.fieldArr? "transcript_patch_cases").getD #[] do
    let e := c.fieldOrNull "expected"
    let mut stLen : UInt32 := 0
    let mut stSeq : UInt32 := 0
    for chKey in #["chunk1", "chunk2"] do
      for ev in (c.fieldArr? chKey).getD #[] do
        let ek := ((ev.fieldUInt64? "event_kind").getD 0).toUInt8
        let dl := ((ev.fieldUInt64? "delta_len").getD 0).toUInt32
        let next := Orb.Kernel.transcriptPatchStep stLen stSeq ek dl
        stLen := (next &&& 0xFFFFFFFF).toUInt32
        stSeq := ((next >>> 32) &&& 0xFFFFFFFF).toUInt32
    if stLen.toUInt64 != ((e.fieldUInt64? "final_len").getD 999999) ||
       stSeq.toUInt64 != ((e.fieldUInt64? "final_seq").getD 999999) then
      let cname := (c.fieldStr? "name").getD ""
      IO.eprintln s!"[orb-spec-runner] FAIL: transcript_patch mismatch {cname}"
      return 1

  let relRaw ← IO.FS.readFile s!"{fixturesDir}/relative-time.json"
  let .ok relDoc := parse relRaw
    | do IO.eprintln "[orb-spec-runner] FAIL: parse relative-time.json"; return 1
  for c in (relDoc.fieldArr? "cases").getD #[] do
    let secs := (c.fieldInt? "secondsAgo").getD 0
    if formatRelTimeSecs secs != ((c.fieldStr? "expected").getD "") then
      IO.eprintln s!"[orb-spec-runner] FAIL: relative-time mismatch {secs}"
      return 1

  let uRaw ← IO.FS.readFile s!"{fixturesDir}/usage-limit-status.json"
  let .ok uDoc := parse uRaw
    | do IO.eprintln "[orb-spec-runner] FAIL: parse usage-limit-status.json"; return 1
  for c in (uDoc.fieldArr? "cases").getD #[] do
    let got := evalUsageLimitLabel (c.fieldOrNull "usage") ((c.fieldUInt64? "nowSec").getD 0)
    let e := c.fieldOrNull "expected"
    let want : Option (String × String) :=
      if e.isNull then none
      else some ((e.fieldStr? "tone").getD "", (e.fieldStr? "label").getD "")
    if got != want then
      let cname := (c.fieldStr? "name").getD ""
      IO.eprintln s!"[orb-spec-runner] FAIL: usage-limit-status mismatch {cname}"
      return 1

  IO.println "test result: ok. 3 passed; 0 failed; 0 ignored"
  return 0

/-- Execute a `cases.txt` batch (`id:symbol:arg0,arg1,...`) and print `id:value`. -/
def runCasesFile (casesPath : String) : IO UInt32 := do
  let raw ← IO.FS.readFile casesPath
  for line in raw.splitOn "\n" do
    let ln := line.trimAscii.toString
    if !ln.isEmpty then
      match ln.splitOn ":" with
      | [idStr, sym, argsPart] =>
        let mut args : Array UInt64 := #[]
        if !argsPart.isEmpty then
          for tok in argsPart.splitOn "," do
            match tok.trimAscii.toString.toNat? with
            | some n => args := args.push n.toUInt64
            | none =>
              IO.eprintln s!"invalid u64 arg in {ln}"
              return 1
        match callExportU64? sym args with
        | some v => IO.println s!"{idStr}:{v}"
        | none =>
          IO.eprintln s!"unknown or arity-mismatched export: {sym}"
          return 1
      | _ =>
        IO.eprintln s!"malformed case line: {ln}"
        return 1
  return 0

end OrbCore.ConformanceRunner
