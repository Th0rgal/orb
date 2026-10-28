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
        self.assertEqual({e["export"] for e in partial},
                         {"orb_mission_control_step", "orb_fork_home_step"})
        for entry in partial:
            self.assertEqual(entry["authoritative_callers"], [])
            self.assertEqual(entry["adapter_tests"], [])
            self.assertEqual(entry["evidence"]["execution"]["result"], "TESTED_LOCAL")

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


if __name__ == "__main__":
    unittest.main()
