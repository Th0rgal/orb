"""Adversarial harness checks; fixture rows are not engine execution receipts."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import time
import subprocess
import os

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_shared_kernel_conformance as conformance


class Harness(unittest.TestCase):
    def setUp(self):
        conformance.COMMANDS.clear()
        conformance.EXECUTABLES.clear()
        self.cases = [{"id": 0, "symbol": "fixture", "args": [1]},
                      {"id": 1, "symbol": "fixture", "args": [2]}]
        self.reference = {0: 19, 1: 37}

    def test_missing_extra_duplicate_and_invalid_rows_reject(self):
        for text in ("0:19\n0:37", "-1:19", "0:-1", f"0:{2**64}", "garbage", "0:+19", " 0:19", "0:19 ", "-0:19"):
            with self.assertRaises(ValueError):
                conformance.parse_rows(text)
        for rows in ({0: 19}, {0: 19, 1: 37, 2: 5}, {0: 19, 1: True}):
            with self.assertRaises(ValueError):
                conformance.compare_rows(self.reference, rows, self.cases)

    def test_partial_comparisons_have_receipts_without_claiming_engine_completion(self):
        values, partial = {"stock_lean": self.reference}, {"lnir": {0: 18}}
        report = {"engines": {}, "blockers": []}
        self.assertEqual(conformance.summarize(report, values, partial, self.cases), 1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipts.jsonl"
            conformance.write_case_receipts(path, self.cases, values, partial, "provenance")
            receipts = [json.loads(line) for line in path.read_text().splitlines()]
        self.assertEqual(len(receipts), 3)
        lnir = next(r for r in receipts if r["payload"]["engine"] == "lnir")
        self.assertEqual(lnir["payload"]["case"]["id"], 0)
        self.assertEqual(lnir["payload"]["result_u64"], "18")
        self.assertFalse(lnir["payload"]["engine_complete"])
        self.assertEqual(lnir["sha256"], conformance.canonical_hash(lnir["payload"]))
        self.assertIn("lnir", report["missing_engines"])

    def test_provenance_binds_repository_identity_and_environment(self):
        report = {"sources": {}, "harness_sha256": "harness", "tools": {}, "artifacts": {},
                  "heads": {"lean_sys": "original"}, "repositories": {"lean_sys": {"head": "original", "dirty": ""}},
                  "environment": {"LEAN_PATH": "original"}}
        baseline = conformance.canonical_hash(conformance.build_provenance(report, "commands"))
        for field in ("heads", "repositories", "environment"):
            changed = copy.deepcopy(report)
            changed[field] = {"changed": True}
            self.assertNotEqual(baseline, conformance.canonical_hash(conformance.build_provenance(changed, "commands")))

    def test_mutated_values_and_swapped_case_identity_are_detected(self):
        for rows in ({0: 18, 1: 37}, {0: 37, 1: 19}):
            self.assertTrue(conformance.compare_rows(self.reference, rows, self.cases))

    def test_failed_prerequisite_stdout_is_never_execution_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            conformance.OUT, conformance.ENV = Path(directory), dict(os.environ)
            report, values, partial = {"engines": {}, "blockers": []}, {"stock_lean": self.reference}, {}
            def action():
                return conformance.parse_rows(conformance.run([sys.executable, "-c",
                    "print('0:18');print('1:37');raise SystemExit(7)"]))
            conformance.record_engine(report, values, partial, "fixture", action, self.cases)
            self.assertEqual(partial["fixture"], {})
            self.assertEqual(conformance.summarize(report, values, partial, self.cases), 2)
            self.assertEqual(report["comparisons"], 0)
            self.assertEqual(report["mismatches"], [])
            # The same nonzero process is evidence only when the caller marks
            # it as case execution. Its valid mismatch must still force FAIL.
            def execute():
                return conformance.parse_rows(conformance.run([sys.executable, "-c",
                    "print('0:18');print('1:37');raise SystemExit(7)"], role="execution"))
            conformance.record_engine(report, values, partial, "fixture", execute, self.cases)
            self.assertEqual(partial["fixture"], {0: 18, 1: 37})
            self.assertEqual(conformance.summarize(report, values, partial, self.cases), 1)
            self.assertEqual(conformance.COMMANDS[-1]["role"], "execution")

    def test_failed_lnir_execution_retains_valid_mismatch_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            conformance.OUT, conformance.ENV = Path(directory), dict(os.environ)
            core = Path(directory) / "fixture-core"
            core.write_text(f"#!{sys.executable}\nimport json\n"
                            "print(json.dumps([{'decl':'probe_fixture','ok':True,'value_u64':'18'}]))\n"
                            "raise SystemExit(7)\n")
            core.chmod(0o700)
            report, values, partial = {"engines": {}, "blockers": []}, {"stock_lean": self.reference}, {}
            conformance.record_engine(report, values, partial, "lnir",
                lambda: conformance.run_lnir_cases(core, Path(directory) / "fixture.lnir", self.cases), self.cases)
            self.assertEqual(partial["lnir"], {0: 18, 1: 18})
            self.assertEqual(conformance.summarize(report, values, partial, self.cases), 1)
            self.assertEqual(report["engines"]["lnir"]["status"], "BLOCKED")
            self.assertEqual(len(json.loads((Path(directory) / "lnir-errors.json").read_text())), 2)
            self.assertTrue(all(r["exit_code"] == 7 and r["role"] == "execution" for r in conformance.COMMANDS))

    def test_wasm_baseline_and_mutant_record_execution_role(self):
        with tempfile.TemporaryDirectory() as directory:
            conformance.OUT, conformance.ENV = Path(directory), dict(os.environ)
            node = Path(directory) / "fixture-node"
            node.write_text(f"#!{sys.executable}\nprint('0:18')\nprint('1:37')\n")
            node.chmod(0o700)
            conformance.EXECUTABLES["node"] = str(node)
            for name in ("kernel.wasm", "mutant.wasm"):
                self.assertEqual(conformance.wasm_rows(Path(directory) / name), {0: 18, 1: 37})
                self.assertEqual(conformance.COMMANDS[-1]["role"], "execution")
            conformance.EXECUTABLES.clear()

    def test_failed_lnir_execution_does_not_salvage_bad_json_or_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            conformance.OUT, conformance.ENV = Path(directory), dict(os.environ)
            core = Path(directory) / "fixture-core"
            for response in ("garbage", "{}", "[]", '[{"decl":"probe_other","ok":true,"value_u64":"18"}]',
                             '[{"decl":"probe_fixture","ok":true,"value_u64":18}]'):
                core.write_text(f"#!{sys.executable}\nprint({response!r})\nraise SystemExit(7)\n")
                core.chmod(0o700)
                with self.assertRaises(conformance.RowFailure) as caught:
                    conformance.run_lnir_cases(core, Path(directory) / "fixture.lnir", self.cases)
                self.assertEqual(caught.exception.rows, {})
                errors = json.loads((Path(directory) / "lnir-errors.json").read_text())
                self.assertEqual(len(errors), len(self.cases))

    def test_engine_environment_is_allowlisted(self):
        env = conformance.conformance_environment(Path("evidence"), {
            "PATH": "/toolchain/bin", "HOME": "/home/fixture", "RUSTUP_HOME": "/rustup",
            "OPENAI_API_KEY": "fixture-secret", "LD_PRELOAD": "inject.so", "LEAN_PATH": "untrusted"})
        self.assertEqual(env, {"PATH": "/toolchain/bin", "HOME": "/home/fixture", "RUSTUP_HOME": "/rustup",
                               "LEAN_PATH": "evidence", "LC_ALL": "C", "LANG": "C"})

    def test_bad_output_preserves_unambiguous_mismatches_through_final_aggregation(self):
        for text, mismatch in (("0:18\ngarbage\n1:37", 0), ("0:18\n1:37\n2:5", 0),
                               ("0:18\n1:37\n1:9", 0), ("0:18\n0:19\n1:36", 1)):
            for command_failed in (False, True):
                with self.subTest(text=text, command_failed=command_failed):
                    report, values, partial = {"engines": {}, "blockers": []}, {"stock_lean": self.reference}, {}
                    def action():
                        if command_failed:
                            raise conformance.CommandFailure("fixture command failed", text, role="execution")
                        return conformance.parse_rows(text)
                    conformance.record_engine(report, values, partial, "fixture", action, self.cases)
                    code = conformance.summarize(report, values, partial, self.cases)
                    self.assertEqual(code, 1)
                    self.assertEqual(report["status"], "FAIL")
                    self.assertEqual(report["engines"]["fixture"]["status"], "BLOCKED")
                    self.assertNotIn("fixture", values)
                    self.assertEqual([m["case"]["id"] for m in report["mismatches"]], [mismatch])
                    if "0:19" in text:
                        self.assertNotIn(0, partial["fixture"])
                    if "1:9" in text:
                        self.assertNotIn(1, partial["fixture"])

    def test_bad_executed_mutant_results_force_failure_report_and_exit(self):
        for text in ("0:18", "0:18\n1:36\n2:5", "0:18\n0:18\n1:36", "0:18\ngarbage\n1:36"):
            report = {"engines": {}, "blockers": [], "mutation_checks": {}}
            failed = conformance.record_mutant(report["mutation_checks"], "fixture", self.reference, self.reference,
                lambda: conformance.parse_rows(text), self.cases, "fixture")
            code = conformance.summarize(report, {"stock_lean": self.reference}, {}, self.cases, failed)
            self.assertEqual(code, 1)
            self.assertEqual(report["status"], "FAIL")
            self.assertEqual(report["mutation_checks"]["fixture"]["status"], "FAIL")

    def test_receipt_hash_binds_input_result_engine_and_provenance(self):
        receipt = conformance.case_receipt(self.cases[0], "fixture-engine", 19, "provenance-hash")
        for key, value in (("engine", "different"), ("result_u64", "18"),
                           ("provenance", "different"), ("case", self.cases[1])):
            modified = copy.deepcopy(receipt)
            modified["payload"][key] = value
            self.assertNotEqual(receipt["sha256"], conformance.canonical_hash(modified["payload"]))

    def test_mutant_requires_exact_case_set_and_intended_bit_flip(self):
        cases = [{"id": i, "symbol": "target" if i < 8 else "other", "args": []} for i in range(16)]
        baseline = {i: 100 for i in range(16)}
        right = {i: 101 if i < 8 else 100 for i in range(16)}
        self.assertEqual(conformance.qualify_mutant(baseline, baseline, right, cases, "target"), list(range(8)))
        for mutant in ({i: 101 if i >= 8 else 100 for i in range(16)}, {i: 102 if i < 8 else 100 for i in range(16)}):
            with self.assertRaises(conformance.QualificationFailure):
                conformance.qualify_mutant(baseline, baseline, mutant, cases, "target")

    def test_lnir_rejects_malformed_types_and_wrong_request_identity(self):
        case = {"symbol": "fixture", "id": 0, "args": [1]}
        for value in (True, 1.5, 1, "-1", str(2**64)):
            with self.assertRaises(ValueError):
                conformance.lnir_result({"decl": "probe_fixture", "ok": True, "value_u64": value}, case)
        with self.assertRaises(ValueError):
            conformance.lnir_result({"decl": "probe_other", "ok": True, "value_u64": "1"}, case)

    def test_missing_executable_and_nonzero_exit_preserve_failure_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            conformance.OUT = Path(temp)
            conformance.ENV = {}
            conformance.COMMANDS.clear()
            for argv in ([str(Path(temp) / "missing")], [sys.executable, "-c", "raise SystemExit(7)"]):
                with self.assertRaises(RuntimeError):
                    conformance.run(argv)
            records = json.loads((Path(temp) / "commands.json").read_text())
            self.assertIsNone(records[0]["exit_code"])
            self.assertEqual(records[1]["exit_code"], 7)

    def test_timeout_stops_command_descendants_and_records_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            conformance.OUT = Path(temp)
            conformance.ENV = {}
            conformance.COMMANDS.clear()
            pidfile = Path(temp) / "pid"
            source = ("import subprocess,time; from pathlib import Path; "
                      f"p=subprocess.Popen([{sys.executable!r},'-c','import time;time.sleep(60)']); "
                      f"Path({str(pidfile)!r}).write_text(str(p.pid)); time.sleep(60)")
            with self.assertRaises(RuntimeError):
                conformance.run([sys.executable, "-c", source], timeout=0.2, ready=pidfile)
            pid = int(pidfile.read_text())
            self.assert_stopped(pid)
            record = json.loads((Path(temp) / "commands.json").read_text())[0]
            self.assertEqual(record["exit_code"], -9)
            self.assertIn("timed out", record["error"])

    def assert_stopped(self, pid):
        for _ in range(50):
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
            if state.returncode == 1 or state.stdout.strip().startswith("Z"):
                return
            self.assertEqual(state.returncode, 0, state.stderr)
            time.sleep(0.01)
        self.fail("command left a running descendant")

    def test_sigterm_preserves_interrupted_command_and_stops_descendant(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pidfile = root / "child"
            script = (f"import sys,signal;sys.path.insert(0,{str(Path(conformance.__file__).parent)!r});"
                      "import run_shared_kernel_conformance as c;from pathlib import Path;"
                      f"c.OUT=Path({temp!r});c.ENV={{}};signal.signal(signal.SIGTERM,c.terminate);"
                      f"c.run([sys.executable,'-c',\"import os,time;from pathlib import Path;Path({str(pidfile)!r}).write_text(str(os.getpid()));time.sleep(60)\"])")
            with subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as driver:
                deadline = time.monotonic() + 10
                while not pidfile.exists():
                    if driver.poll() is not None or time.monotonic() > deadline:
                        self.fail("driver did not become ready")
                    time.sleep(0.01)
                driver.terminate()
                driver.communicate(timeout=10)
                self.assertEqual(driver.returncode, 143)
            self.assert_stopped(int(pidfile.read_text()))
            record = json.loads((root / "commands.json").read_text())[0]
            self.assertIn("SystemExit: 143", record["error"])

    def test_real_native_crash_and_hang_are_supervised(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            conformance.OUT, conformance.ENV = root, dict(os.environ)
            source, library = root / "fixture.c", root / "fixture.so"
            source.write_text('#include <stdlib.h>\nvoid crash(void){abort();}\nvoid hang(void){for(;;){}}\n')
            subprocess.run(["cc", "-dynamiclib" if sys.platform == "darwin" else "-shared", "-fPIC", source, "-o", library], check=True, capture_output=True)
            for name in ("crash", "hang"):
                ready = root / ("ready-" + name)
                with self.assertRaises(conformance.CommandFailure):
                    conformance.run([sys.executable, "-c", "import ctypes,resource;from pathlib import Path;"
                                     "resource.setrlimit(resource.RLIMIT_CORE,(0,0));"
                                     f"lib=ctypes.CDLL({str(library)!r});Path({str(ready)!r}).touch();lib.{name}()"],
                                    timeout=5 if name == "crash" else 0.2, ready=ready)
            records = json.loads((root / "commands.json").read_text())
            self.assertEqual(records[-2]["exit_code"], -6)
            self.assertEqual(records[-1]["exit_code"], -9)


if __name__ == "__main__":
    unittest.main()
