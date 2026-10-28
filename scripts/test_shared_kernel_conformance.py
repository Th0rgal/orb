"""Adversarial harness checks; fixture rows are not engine execution receipts."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import time

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
                conformance.run([sys.executable, "-c", source], timeout=0.5)
            pid = int(pidfile.read_text())
            stat = Path(f"/proc/{pid}/stat")
            for _ in range(50):
                if not stat.exists() or stat.read_text().split(")")[-1].split()[0] == "Z":
                    break
                time.sleep(0.01)
            else:
                self.fail("timed-out command left a running descendant")
            record = json.loads((Path(temp) / "commands.json").read_text())[0]
            self.assertIsNone(record["exit_code"])
            self.assertIn("timed out", record["error"])


if __name__ == "__main__":
    unittest.main()
