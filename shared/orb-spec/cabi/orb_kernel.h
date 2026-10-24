#ifndef ORB_KERNEL_H
#define ORB_KERNEL_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint8_t orb_verify_writer_reuse(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_verify_lease_mode(uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_verify_track_hold(uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_verify_repo_disjoint(uint8_t, uint8_t, uint8_t);
uint8_t orb_verify_remote_outbox(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_verify_board_slots(uint32_t, uint32_t, uint32_t);
uint8_t orb_verify_board_retry(uint32_t, uint32_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_verify_job_transition(uint8_t, uint8_t);
uint8_t orb_verify_bundle_budget(uint8_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t orb_verify_token_rotation(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_verify_log_window(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint64_t orb_mix64_word(uint64_t, uint64_t);
uint32_t orb_proxy_step(uint8_t, uint8_t, uint8_t, uint32_t, uint32_t);
uint32_t orb_stream_deadlines(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint8_t, uint8_t, uint8_t);
uint32_t orb_breaker_step(uint8_t, uint32_t, uint32_t);
uint8_t orb_mission_step(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
uint8_t orb_reconcile_step(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint32_t orb_queue_step(uint8_t, uint8_t);
uint8_t orb_vm_step(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, uint64_t);
uint32_t lp_orb_x2dspec_Orb_Kernel_accessStep___redArg(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint32_t orb_access_step(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint32_t orb_workfold_step(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_taskcard_step(uint8_t, uint8_t, uint8_t);
uint32_t orb_sidebar_visibility(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint32_t orb_admission_step(uint8_t, uint8_t, uint8_t, uint64_t, uint64_t);
uint64_t orb_account_cooldown_secs(uint64_t, uint64_t, uint32_t);
uint64_t orb_cost_cents_step(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t orb_stream_loop_step(uint8_t, uint8_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, uint64_t);
uint32_t orb_job_ledger_step(uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t orb_proc_liveness_step(uint8_t, uint8_t, uint8_t, uint8_t, uint32_t, uint64_t, uint64_t);
uint8_t orb_pr_gate_step(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
uint32_t orb_turn_summary_step(uint8_t, uint8_t, uint8_t, uint8_t);
uint64_t orb_usage_limit_status(uint8_t, uint8_t, uint8_t, uint8_t, uint8_t, uint64_t);
uint64_t orb_relative_time_bucket(uint64_t);
uint64_t orb_transcript_patch_step(uint32_t, uint32_t, uint8_t, uint32_t);
uint32_t orb_attribution_step(uint8_t, uint8_t, uint8_t, uint8_t);
uint8_t leansys_verify_slice_bounds(uint64_t, uint64_t, uint64_t);
uint8_t leansys_verify_wal_frame(uint32_t, uint32_t, uint64_t, uint64_t, uint64_t);
uint8_t leansys_verify_cas_digest(uint64_t, uint64_t, uint8_t);
uint8_t leansys_check_http_bounds(uint32_t, uint64_t, uint64_t, uint8_t);
uint8_t leansys_verify_jsonl_tape(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t);
uint8_t leansys_verify_ring_cursor(uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t leansys_verify_sst_block(uint32_t, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t leansys_verify_poll_interest(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
uint8_t leansys_verify_rlimit_budget(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint64_t leansys_mix64_word(uint64_t, uint64_t);
uint8_t leansys_verify_composite_key_order(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t leansys_verify_token_auth(uint8_t, uint8_t, uint8_t, uint8_t, uint64_t, uint64_t);
uint8_t leansys_verify_log_window(uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t leansys_verify_jsonrpc_frame(uint8_t, uint8_t, uint32_t, uint64_t);
uint8_t leansys_gate_admit(uint8_t, uint8_t, uint8_t);
uint8_t leansys_verify_mmap_seqlock(uint32_t, uint32_t, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t leansys_verify_proc_stat_fields(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint8_t leansys_sse_frame_scan(uint64_t, uint64_t, uint64_t, uint8_t, uint8_t, uint8_t);
uint8_t leansys_gfm_pipe_scan(uint64_t, uint64_t, uint64_t, uint32_t, uint32_t, uint8_t);
uint8_t leansys_tag_scan(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint8_t);
uint64_t leansys_transcript_index(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
#ifdef __cplusplus
}
#endif
#endif
