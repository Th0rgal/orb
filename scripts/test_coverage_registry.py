#!/usr/bin/env python3
"""Adversarial checks: unsupported coverage evidence must never be accepted."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import gen_coverage_registry as registry


class CoverageRegistryTests(unittest.TestCase):
    def setUp(self):
        self.value = registry.build_registry()

    def test_inventory_roundtrip(self):
        registry.validate_registry(self.value)
        self.assertEqual(self.value["acceptance"], "INCOMPLETE")
        self.assertEqual(self.value["total_exports"], 181)
        self.assertEqual(self.value["counts_by_status"], {"partial": 110, "unconnected": 71})
        self.assertTrue(all(e["blockers"] for e in self.value["entries"]))

    def test_reject_unsupported_links_and_claims(self):
        for field, value in {
            "theorems": ["LeanSys.Spec.invented_sound"],
            "model": "Orb.Kernel.invented",
            "authoritative_callers": ["src/comment_only.rs"],
            "adapter_tests": ["generated_wrapper.swift"],
            "status": "authoritative",
            "blockers": [],
        }.items():
            with self.subTest(field=field):
                changed = copy.deepcopy(self.value)
                changed["entries"][0][field] = value
                with self.assertRaises(ValueError):
                    registry.validate_registry(changed)

    def test_missing_duplicate_and_reordered_exports(self):
        for mode in ("missing", "duplicate", "reordered"):
            changed = copy.deepcopy(self.value)
            if mode == "missing":
                changed["entries"].pop()
            elif mode == "duplicate":
                changed["entries"].append(changed["entries"][0])
            else:
                changed["entries"].reverse()
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                registry.validate_registry(changed)

    def test_bad_status_and_completed_claim(self):
        for field, value in (("schema_version", "unknown"), ("acceptance", "COMPLETE"),
                             ("total_exports", 0)):
            changed = copy.deepcopy(self.value)
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                registry.validate_registry(changed)

    def test_partial_evidence_never_implies_acceptance(self):
        partial = [e for e in self.value["entries"] if e["status"] == "partial"]
        self.assertEqual(
            {e["export"] for e in partial},
            {
                "orb_mission_control_step",
                "orb_fork_home_step",
                "orb_wire_validate_frame",
                "orb_wire_pack_record",
                "orb_wire_schema_migrate_step",
                "orb_effect_admissible",
                "orb_privd_command_step",
                "orb_ssh_identity_step",
                "orb_access_step",
                "orb_stream_deadlines",
                "orb_proxy_step",
                "orb_job_ledger_step",
                "orb_wire_apply_patch_step",
                "orb_wire_machine_step",
                "orb_hierarchy_merge_step",
                "orb_transcript_fold_step",
                "orb_outbox_crash_reconcile_step",
                "orb_provider_attempt_step",
                "orb_auth_toctou_execute_step",
                "orb_resource_ledger_step",
                "orb_stream_bounded_commit_step",
                "leansys_verify_fd_bounds",
                "orb_vm_cap_admit",
                "leansys_verify_cas_digest",
                "leansys_verify_token_auth",
                "leansys_verify_log_window",
                "leansys_verify_proc_stat_fields",
                "leansys_verify_slice_bounds",
                "leansys_select_isa",
                "leansys_verify_isa_selection",
                "orb_verify_log_window",
                "orb_verify_bundle_budget",
                "orb_verify_token_rotation",
                "orb_node_gc_step",
                "orb_node_lane_step",
                "orb_proc_liveness_step",
                "orb_node_disk_admission_step",
                "orb_slot_bypass_step",
                "orb_verify_writer_reuse",
                "orb_verify_lease_mode",
                "orb_verify_track_hold",
                "orb_verify_repo_disjoint",
                "orb_verify_remote_outbox",
                "orb_verify_board_slots",
                "orb_verify_board_retry",
                "orb_verify_job_transition",
                "orb_wire_verify_slice_io",
                "orb_wire_encode_slice_step",
                "orb_wire_decode_slice_step",
                "orb_scroll_policy_gap",
                "orb_scroll_policy_correct",
                "orb_scroll_policy_step",
                "orb_wire_scroll_slice_step",
                "orb_wire_stream_slice_step",
                "orb_wire_transcript_slice_step",
                "orb_breaker_step",
                "orb_account_cooldown_secs",
                "orb_provider_pool_step",
                "orb_route_argmin_step",
                "orb_cost_cents_step",
                "orb_mission_step",
                "orb_reconcile_step",
                "orb_queue_step",
                "orb_admission_step",
                "orb_attribution_step",
                "orb_schedule_step",
                "orb_stats_settle_step",
                "orb_privilege_step",
                "orb_bunker_step",
                "orb_deploy_gate_step",
                "orb_vm_step",
                "orb_vm_lifecycle_step",
                "orb_vm_claim_step",
                "orb_compute_secret_gate",
                "orb_node_resize_step",
                "orb_stream_loop_step",
                "orb_agent_event_normalize_step",
                "orb_transcript_reduce_step",
                "orb_cursor_page_step",
                "orb_sidebar_merge_step",
                "orb_client_parity_step",
                "orb_verify_approval",
                "orb_mix64_word",
                "orb_pr_gate_step",
                "orb_placement_merge_step",
                "orb_fleet_endpoint_gate",
                "orb_prefill_deadline_ms",
                "orb_proxy_sse_scan_step",
                "orb_stream_repetition_step",
                "orb_http_rate_limit_classify_step",
                "orb_fleet_place_argmin_step",
                "orb_pool_pacer_step",
                "orb_confinement_scan_step",
                "orb_job_identity_eq256_step",
                "orb_validation_dag_step",
                "orb_fts5_lexer_step",
                "orb_utf8_utf16_window_step",
                "leansys_verify_rlimit_budget",
                "leansys_verify_dag_wave_step",
                "leansys_verify_unix_path_bounds",
                "leansys_verify_cas_digest256",
                "leansys_verify_cgroup_v2_budget",
                "leansys_verify_stream_relay",
                "orb_activation_rollback_admit",
                "orb_remote_replay_step",
                "orb_codex_goal_launch_step",
                "orb_codex_goal_preact_filter",
                "orb_skill_slash_step",
                "orb_worktree_decision_step",
                "orb_repo_diff_budget_step",
            },
        )
        for entry in partial:
            self.assertEqual(entry["authoritative_callers"], [])
            self.assertEqual(entry["adapter_tests"], [])
            self.assertEqual(entry["evidence"]["execution"]["result"], "TESTED_LOCAL")

    def test_leansys_models_resolved_and_compiler_helper_remains_null(self):
        by_name = {e["export"]: e for e in self.value["entries"]}
        leansys = [e for name, e in by_name.items() if name.startswith("leansys_")]
        self.assertEqual(len(leansys), 41)
        self.assertTrue(all(e["model"] and e["model"].startswith("LeanSys.Spec.") for e in leansys))
        self.assertIsNone(by_name["lp_orb_x2dspec_Orb_Kernel_accessStep___redArg"]["model"])
        for mode in ("bad_prefix", "orb_conflict"):
            bad_manifest = json.loads(registry.MANIFEST_PATH.read_text())
            if mode == "bad_prefix":
                next(f for f in bad_manifest["functions"] if f["name"].startswith("leansys_"))["model"] = "Orb.Kernel.fake"
            else:
                bad_manifest["functions"][0]["model"] = "LeanSys.Spec.fake"
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                registry.build_registry(bad_manifest)

    def test_reject_stale_fabricated_or_failed_partial_evidence(self):
        evidence = json.loads(registry.EVIDENCE_PATH.read_text())
        for mode in ("hash", "declaration", "path", "receipt", "status", "export"):
            changed = copy.deepcopy(evidence)
            entry = changed["entries"]["orb_mission_control_step"]
            if mode == "hash":
                entry["sources"][0]["sha256"] = "0" * 64
            elif mode == "declaration":
                entry["links"][0]["symbol"] = "invented_theorem_in_a_comment"
            elif mode == "path":
                entry["sources"][0]["path"] = "../outside"
            elif mode == "receipt":
                entry["execution"]["exit_code"] = -1
            elif mode == "status":
                entry["status"] = "authoritative"
            else:
                changed["entries"]["invented_export"] = entry
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "evidence.json"
                path.write_text(json.dumps(changed))
                with patch.object(registry, "EVIDENCE_PATH", path), self.assertRaises(ValueError):
                    registry.build_registry()


    def test_governance_docs_stay_aligned_with_pin_and_incomplete_coverage(self):
        root = registry.ROOT
        pin = (root / "lean/turbo-lean-revision").read_text(encoding="utf-8").strip()
        self.assertEqual(len(pin), 40)
        formal_audit = (root / "docs/FORMAL_AUDIT.md").read_text(encoding="utf-8")
        self.assertIn(pin, formal_audit)
        self.assertNotIn("2aedbc0207ccf866c41d0392b82c7187c3941ee6", formal_audit)
        roadmap = (root / "docs/TRUSTWORTHY_SHARED_LEAN_ROADMAP.md").read_text(encoding="utf-8")
        self.assertIn("P0–P7 remain unaccepted.", roadmap)
        self.assertIn("110 partial / 71 unconnected", roadmap)
        self.assertIn("BLOCKED_PHYSICAL_DEVICE", roadmap)
        self.assertIn("BLOCKED_HOST_UNREACHABLE", roadmap)
        self.assertIn(pin, roadmap)
        p1_doc = (root / "docs/P1_SHARED_KERNEL_CONFORMANCE.md").read_text(encoding="utf-8")
        self.assertIn("139 Orb exports and 41 LeanSys exports", p1_doc)
        self.assertIn("1440 base cases", p1_doc)
        self.assertIn("1469 cases", p1_doc)
        self.assertIn("110 partial / 71", p1_doc)
        self.assertIn("3c70e5ada278a4e37e0180255f360aa2ff5fe86c", p1_doc)
        p2_doc = (root / "docs/P2_SHARED_WASM_ARTIFACT.md").read_text(encoding="utf-8")
        self.assertIn("all 181 exported function names", p2_doc)
        self.assertIn("180 public-prefix exports and one compiler helper", p2_doc)
        p3_doc = (root / "docs/P3_TARGET_QUALIFICATION_REPORT.md").read_text(encoding="utf-8")
        self.assertIn("QUALIFIED_WITH_HONEST_DEVICE_BLOCKERS", p3_doc)
        self.assertIn("110 partial / 71 unconnected", p3_doc)
        self.assertIn("181 manifest entries / 180", p3_doc)


if __name__ == "__main__":
    unittest.main()
