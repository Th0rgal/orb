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
        self.cases = [{"id": 0, "symbol": "fixture", "args": [1]},
                      {"id": 1, "symbol": "fixture", "args": [2]}]
        self.reference = {0: 19, 1: 37}

    def test_missing_extra_duplicate_and_invalid_rows_reject(self):
        for text in ("0:19\n0:37", "-1:19", "0:-1", f"0:{2**64}", "garbage"):
            with self.assertRaises(ValueError):
                conformance.parse_rows(text)
        for rows in ({0: 19}, {0: 19, 1: 37, 2: 5}, {0: 19, 1: True}):
            with self.assertRaises(ValueError):
                conformance.compare_rows(self.reference, rows, self.cases)

    def test_mutated_values_and_swapped_case_identity_are_detected(self):
        for rows in ({0: 18, 1: 37}, {0: 37, 1: 19}):
            self.assertTrue(conformance.compare_rows(self.reference, rows, self.cases))

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
