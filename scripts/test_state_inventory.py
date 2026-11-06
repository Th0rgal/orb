#!/usr/bin/env python3
"""Unit and adversarial mutation tests for scripts/check_state_inventory.py."""

from __future__ import annotations

import copy
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_state_inventory as checker

ROOT = Path(__file__).resolve().parent.parent
INVENTORY_PATH = ROOT / "docs/specs/state-machine-inventory.md"
VALIDATION_PATH = ROOT / ".sandboxed/validation.toml"


class StateInventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.inventory_text = INVENTORY_PATH.read_text(encoding="utf-8")
        with VALIDATION_PATH.open("rb") as handle:
            self.validation_matrix = tomllib.load(handle)

    def test_live_repository_inventory_and_validation_dag_pass(self) -> None:
        summary = checker.check_repository(ROOT)
        self.assertEqual(summary["sm_total"], 27)
        self.assertEqual(summary["gaps_total"], 8)
        self.assertGreaterEqual(summary["gates_total"], 7)

        gate_ids = {gate["id"] for gate in self.validation_matrix["gates"]}
        self.assertTrue(
            {
                "state-inventory",
                "fmt",
                "policy-scripts",
                "kernel-abi-check",
                "rust-workspace-tests",
                "orb-client-unit",
                "dashboard-unit",
            }.issubset(gate_ids)
        )

    def test_rejects_missing_or_duplicate_sm_and_gap_rows(self) -> None:
        missing_sm = "\n".join(
            line for line in self.inventory_text.splitlines() if not line.startswith("| SM-14 |")
        )
        with self.assertRaisesRegex(ValueError, "SM inventory mismatch"):
            checker.validate_inventory_markdown(missing_sm, ROOT)

        sm01_line = next(
            line for line in self.inventory_text.splitlines() if line.startswith("| SM-01 |")
        )
        duplicated_sm = self.inventory_text.replace(sm01_line, f"{sm01_line}\n{sm01_line}", 1)
        with self.assertRaisesRegex(ValueError, "duplicate SM IDs"):
            checker.validate_inventory_markdown(duplicated_sm, ROOT)

        missing_gap = "\n".join(
            line for line in self.inventory_text.splitlines() if not line.startswith("| G-ORB-5 |")
        )
        with self.assertRaisesRegex(ValueError, "G-ORB table mismatch"):
            checker.validate_inventory_markdown(missing_gap, ROOT)

    def test_rejects_nonexistent_or_unsafe_file_paths(self) -> None:
        stale_file = self.inventory_text.replace(
            "src/api/idempotency.rs",
            "src/api/does_not_exist_idempotency.rs",
            1,
        )
        with self.assertRaisesRegex(ValueError, "file does not exist"):
            checker.validate_inventory_markdown(stale_file, ROOT)

        traversal = self.inventory_text.replace(
            "src/api/idempotency.rs",
            "../outside_repo.rs",
            1,
        )
        with self.assertRaisesRegex(ValueError, "repository-relative"):
            checker.validate_inventory_markdown(traversal, ROOT)

    def test_completed_status_requires_concrete_pr_and_existing_reproducer(self) -> None:
        completed_with_tbd = self.inventory_text.replace(
            "| R1, R2 | OPEN | `src/api/idempotency.rs` | TBD |",
            "| R1, R2 | COMPLETED | `src/api/idempotency.rs` | TBD |",
            1,
        )
        with self.assertRaisesRegex(ValueError, "COMPLETED row must specify non-TBD closing_pr"):
            checker.validate_inventory_markdown(completed_with_tbd, ROOT)

        completed_missing_gate = self.inventory_text.replace(
            "| R1, R2 | OPEN | `src/api/idempotency.rs` | TBD |",
            "| R1, R2 | COMPLETED | `src/api/missing_gate_test.rs` | #1501 |",
            1,
        )
        with self.assertRaisesRegex(ValueError, "file does not exist"):
            checker.validate_inventory_markdown(completed_missing_gate, ROOT)

        valid_single_completed = self.inventory_text.replace(
            "| R1, R2 | OPEN | `src/api/idempotency.rs` | TBD |",
            "| R1, R2 | COMPLETED | `src/api/idempotency.rs` | #1501 |",
            1,
        )
        sm_rows, _ = checker.validate_inventory_markdown(valid_single_completed, ROOT)
        sm12 = next(row for row in sm_rows if row["id"] == "SM-12")
        self.assertEqual(sm12["status"], "COMPLETED")

    def test_require_all_completed_flag_enforces_r8_exit_gate(self) -> None:
        with self.assertRaisesRegex(ValueError, "expected 'COMPLETED'"):
            checker.validate_inventory_markdown(
                self.inventory_text,
                ROOT,
                require_all_completed=True,
            )

        all_completed = self.inventory_text.replace("| OPEN |", "| COMPLETED |").replace(
            "| TBD |",
            "| #1599 |",
        )
        sm_rows, gap_rows = checker.validate_inventory_markdown(
            all_completed,
            ROOT,
            require_all_completed=True,
        )
        self.assertEqual(len(sm_rows), 27)
        self.assertEqual(len(gap_rows), 8)

    def test_validation_toml_rejects_cycles_duplicates_and_optional_dependencies(self) -> None:
        cyclic = copy.deepcopy(self.validation_matrix)
        for gate in cyclic["gates"]:
            if gate["id"] == "state-inventory":
                gate["dependencies"] = ["rust-workspace-tests"]
        with self.assertRaisesRegex(ValueError, "dependency cycle"):
            checker.validate_validation_matrix(cyclic, ROOT)

        dup = copy.deepcopy(self.validation_matrix)
        dup["gates"].append(copy.deepcopy(dup["gates"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate gate id"):
            checker.validate_validation_matrix(dup, ROOT)

        optional_dep = copy.deepcopy(self.validation_matrix)
        optional_dep["gates"].append(
            {
                "id": "optional-smoke",
                "command": ["python3", "-V"],
                "required": False,
                "mode": "incremental",
            }
        )
        for gate in optional_dep["gates"]:
            if gate["id"] == "rust-workspace-tests":
                gate["dependencies"] = list(gate.get("dependencies", [])) + ["optional-smoke"]
        with self.assertRaisesRegex(ValueError, "depends on optional gate"):
            checker.validate_validation_matrix(optional_dep, ROOT)

        unknown_field = copy.deepcopy(self.validation_matrix)
        unknown_field["gates"][0]["unexpected_key"] = True
        with self.assertRaisesRegex(ValueError, "unknown gate keys"):
            checker.validate_validation_matrix(unknown_field, ROOT)

    def test_cli_entry_point_accepts_override_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            inv_copy = Path(tmp) / "inventory.md"
            val_copy = Path(tmp) / "validation.toml"
            inv_copy.write_text(self.inventory_text, encoding="utf-8")
            val_copy.write_text(VALIDATION_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            rc = checker.main(
                [
                    "--repo-root",
                    str(ROOT),
                    "--inventory",
                    str(inv_copy),
                    "--validation-toml",
                    str(val_copy),
                ]
            )
            self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
