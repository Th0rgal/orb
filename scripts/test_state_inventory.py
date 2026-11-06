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
PLAN_PATH = ROOT / "plan.md"


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
                "capability-matrix",
                "lean-workspace-tests",
                "harness-contract",
                "orb-client-unit",
            }.issubset(gate_ids)
        )
        expected_plan_cols = f"({', '.join(checker.SM_COLUMNS)})"
        self.assertIn(expected_plan_cols, PLAN_PATH.read_text(encoding="utf-8"))

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
            "lean/OrbCore/OrbCore/Store.lean",
            "lean/OrbCore/OrbCore/DoesNotExistStore.lean",
            1,
        )
        with self.assertRaisesRegex(ValueError, "file does not exist"):
            checker.validate_inventory_markdown(stale_file, ROOT)

        traversal = self.inventory_text.replace(
            "lean/OrbCore/OrbCore/Store.lean",
            "../outside_repo.lean",
            1,
        )
        with self.assertRaisesRegex(ValueError, "repository-relative"):
            checker.validate_inventory_markdown(traversal, ROOT)

    def test_completed_status_requires_concrete_pr_and_existing_reproducer(self) -> None:
        invalid_closing_prs = (
            "TBD",
            "-",
            "N/A",
            "none",
            "#0",
            "Th0rgal/orb#0",
            "#01501",
            "abc123",
            "09405d1",
            "deadbee",
            "09405d18b34cf7a49acad061b55d803a27218fe4",
            "Other/repository#123",
            "th0rgal/orb#123",
            "#1501, none",
            "#1501, 09405d1",
            "#1501, Other/repository#123",
        )
        for placeholder in invalid_closing_prs:
            with self.subTest(placeholder=placeholder):
                completed_placeholder = self.inventory_text.replace(
                    "| R1, R2 | OPEN | `lean/OrbCore/OrbCore/Store.lean` | TBD |",
                    f"| R1, R2 | COMPLETED | `lean/OrbCore/OrbCore/Store.lean` | {placeholder} |",
                    1,
                )
                with self.assertRaisesRegex(
                    ValueError,
                    "COMPLETED row must specify concrete closing_pr",
                ):
                    checker.validate_inventory_markdown(completed_placeholder, ROOT)

                all_completed_placeholder = self.inventory_text.replace(
                    "| OPEN |", "| COMPLETED |"
                ).replace("| TBD |", f"| {placeholder} |")
                with self.assertRaisesRegex(
                    ValueError,
                    "COMPLETED row must specify concrete closing_pr",
                ):
                    checker.validate_inventory_markdown(
                        all_completed_placeholder,
                        ROOT,
                        require_all_completed=True,
                    )

        for duplicate_ref in ("#1578, #1578", "#1578, Th0rgal/orb#1578"):
            with self.subTest(duplicate_ref=duplicate_ref):
                completed_duplicate = self.inventory_text.replace(
                    "| R1, R2 | OPEN | `lean/OrbCore/OrbCore/Store.lean` | TBD |",
                    f"| R1, R2 | COMPLETED | `lean/OrbCore/OrbCore/Store.lean` | {duplicate_ref} |",
                    1,
                )
                with self.assertRaisesRegex(
                    ValueError,
                    "duplicate closing_pr reference",
                ):
                    checker.validate_inventory_markdown(completed_duplicate, ROOT)

        completed_missing_gate = self.inventory_text.replace(
            "| R1, R2 | OPEN | `lean/OrbCore/OrbCore/Store.lean` | TBD |",
            "| R1, R2 | COMPLETED | `lean/OrbCore/OrbCore/MissingGateTest.lean` | #1501 |",
            1,
        )
        with self.assertRaisesRegex(ValueError, "file does not exist"):
            checker.validate_inventory_markdown(completed_missing_gate, ROOT)

        valid_tokens = (
            "#1578",
            "Th0rgal/orb#1578",
            "#1578, Th0rgal/orb#1582",
            "`#1501`; `Th0rgal/orb#1576`",
        )
        for token in valid_tokens:
            with self.subTest(token=token):
                valid_single_completed = self.inventory_text.replace(
                    "| R1, R2 | OPEN | `lean/OrbCore/OrbCore/Store.lean` | TBD |",
                    f"| R1, R2 | COMPLETED | `lean/OrbCore/OrbCore/Store.lean` | {token} |",
                    1,
                )
                sm_rows, _ = checker.validate_inventory_markdown(valid_single_completed, ROOT)
                sm12 = next(row for row in sm_rows if row["id"] == "SM-12")
                self.assertEqual(sm12["status"], "COMPLETED")

    def test_parse_semicolon_paths_handles_multi_span_backticks(self) -> None:
        self.assertEqual(
            checker.parse_semicolon_paths(
                "`lean/OrbCore/OrbCore/Store.lean`; `lean/OrbCore/OrbCore/Control.lean`",
                "SM-12.current_files",
            ),
            ["lean/OrbCore/OrbCore/Store.lean", "lean/OrbCore/OrbCore/Control.lean"],
        )
        self.assertEqual(
            checker.parse_semicolon_paths(
                "`lean/OrbCore/OrbCore/Store.lean`; `lean/OrbCore/OrbCore/Control.lean`; `lean/OrbCore/OrbCore/Proxy.lean`",
                "SM-21.current_files",
            ),
            ["lean/OrbCore/OrbCore/Store.lean", "lean/OrbCore/OrbCore/Control.lean", "lean/OrbCore/OrbCore/Proxy.lean"],
        )
        self.assertEqual(
            checker.parse_semicolon_paths(
                "`lean/OrbCore/OrbCore/Store.lean; lean/OrbCore/OrbCore/Control.lean`",
                "SM-12.current_files",
            ),
            ["lean/OrbCore/OrbCore/Store.lean", "lean/OrbCore/OrbCore/Control.lean"],
        )
        with self.assertRaisesRegex(ValueError, "expected non-empty ';'-separated file list"):
            checker.parse_semicolon_paths("`lean/OrbCore/OrbCore/Store.lean; `lean/OrbCore/OrbCore/Control.lean`", "broken")

        multi_span_inventory = self.inventory_text.replace(
            "`lean/OrbCore/OrbCore/Control.lean; lean/OrbCore/OrbCore/Spec.lean`",
            "`lean/OrbCore/OrbCore/Control.lean`; `lean/OrbCore/OrbCore/Spec.lean`",
            1,
        )
        sm_rows, _ = checker.validate_inventory_markdown(multi_span_inventory, ROOT)
        self.assertEqual(len(sm_rows), 27)

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
                gate["dependencies"] = ["lean-workspace-tests"]
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
            if gate["id"] == "lean-workspace-tests":
                gate["dependencies"] = list(gate.get("dependencies", [])) + ["optional-smoke"]
        with self.assertRaisesRegex(ValueError, "depends on optional gate"):
            checker.validate_validation_matrix(optional_dep, ROOT)

        unknown_field = copy.deepcopy(self.validation_matrix)
        unknown_field["gates"][0]["unexpected_key"] = True
        with self.assertRaisesRegex(ValueError, "unknown gate keys"):
            checker.validate_validation_matrix(unknown_field, ROOT)

    def test_validation_toml_enforces_repo_confinement_for_cwd_and_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            repo = base / "repo"
            outside = base / "outside"
            (repo / "subdir").mkdir(parents=True)
            outside.mkdir(parents=True)
            (outside / "secret.txt").write_text("secret\n", encoding="utf-8")
            (repo / "subdir" / "existing.txt").write_text("ok\n", encoding="utf-8")
            (repo / "escape_dir").symlink_to(outside)
            (repo / "subdir" / "rel_escape_dir").symlink_to(Path("../../outside"))
            (repo / "subdir" / "escape_file.txt").symlink_to(outside / "secret.txt")
            (repo / "subdir" / "dangling_escape.txt").symlink_to(outside / "missing.txt")
            (repo / "subdir" / "internal_dir").symlink_to(Path("."))
            (outside / "hop_back").symlink_to(repo / "subdir")
            (repo / "trampoline").symlink_to(Path("../outside/hop_back"))

            def make_matrix(
                *,
                cwd: str | None = None,
                artifacts: list[str] | None = None,
            ) -> dict[str, object]:
                gate: dict[str, object] = {
                    "id": "cert-gate",
                    "command": ["python3", "-V"],
                    "required": True,
                    "mode": "clean",
                    "reuse": False,
                }
                if cwd is not None:
                    gate["cwd"] = cwd
                if artifacts is not None:
                    gate["artifacts"] = artifacts
                return {
                    "version": 1,
                    "project": "orb",
                    "gates": [gate],
                }

            normalized = checker.validate_validation_matrix(
                make_matrix(
                    cwd="subdir",
                    artifacts=[
                        "subdir/existing.txt",
                        "subdir/nonexistent_leaf.json",
                        "subdir/internal_dir/nonexistent_leaf.json",
                        "build/out/future_report.json",
                    ],
                ),
                repo,
            )
            self.assertEqual(len(normalized), 1)

            for bad_cwd in ("escape_dir", "subdir/rel_escape_dir", "trampoline", "../outside", "/etc"):
                with self.subTest(bad_cwd=bad_cwd):
                    with self.assertRaisesRegex(
                        ValueError,
                        "escapes repository root|repository-relative",
                    ):
                        checker.validate_validation_matrix(make_matrix(cwd=bad_cwd), repo)

            for bad_artifact in (
                "../../../etc/passwd",
                "subdir/../../outside/secret.txt",
                "/etc/passwd",
                "escape_dir/secret.txt",
                "escape_dir/nonexistent_leaf.json",
                "subdir/rel_escape_dir/nonexistent_leaf.json",
                "subdir/escape_file.txt",
                "subdir/dangling_escape.txt",
                "trampoline/existing.txt",
            ):
                with self.subTest(bad_artifact=bad_artifact):
                    with self.assertRaisesRegex(
                        ValueError,
                        "escapes repository root|repository-relative",
                    ):
                        checker.validate_validation_matrix(
                            make_matrix(artifacts=[bad_artifact]),
                            repo,
                        )

            with self.assertRaisesRegex(ValueError, "must not be an existing directory"):
                checker.validate_validation_matrix(make_matrix(artifacts=["subdir"]), repo)

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
