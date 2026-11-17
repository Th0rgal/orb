"""R29 standing cut-rate report and jump alert."""
import importlib.machinery
import importlib.util
import io
import json
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader(
    "orb_monitor_cuts", str(Path(__file__).parent / "ops/orb-monitor")
)
spec = importlib.util.spec_from_loader(loader.name, loader)
monitor = importlib.util.module_from_spec(spec)
loader.exec_module(monitor)


class MonitorCutsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = Path(self.tmp.name) / "missions.db"
        self.state = Path(self.tmp.name) / "state.json"
        with sqlite3.connect(self.db) as con:
            con.executescript(
                """
                CREATE TABLE proxy_usage(
                  id INTEGER PRIMARY KEY, timestamp TEXT, provider TEXT,
                  model TEXT, requested_model TEXT, mission_id TEXT
                );
                CREATE TABLE proxy_outcomes(
                  id INTEGER PRIMARY KEY, timestamp TEXT, provider TEXT,
                  model TEXT, requested_model TEXT, status TEXT
                );
                CREATE TABLE mission_events(
                  id INTEGER PRIMARY KEY, mission_id TEXT, event_type TEXT,
                  payload TEXT, content TEXT, created_at TEXT, timestamp TEXT
                );
                """
            )
            for i in range(9):
                con.execute(
                    "INSERT INTO proxy_usage VALUES(?,?,?,?,?,?)",
                    (i + 1, "2026-11-17T12:00:00+00:00", "google", "gemini-4-argon", "", "m1"),
                )
            con.executemany(
                "INSERT INTO proxy_outcomes VALUES(?,?,?,?,?,?)",
                [
                    (i + 1, f"2026-11-17T12:{i:02d}:00+00:00", "google", "gemini-4-argon", "",
                     "stream_incomplete" if i == 9 else "ok")
                    for i in range(10)
                ],
            )
            con.execute(
                "INSERT INTO mission_events VALUES(?,?,?,?,?,?,?)",
                (1, "m1", "error", '{"message":"stream_incomplete"}', "", "2026-11-17T12:02:00+00:00", "2026-11-17T12:02:00+00:00"),
            )
        self.patches = [
            patch.object(monitor, "MISSIONS_DB", str(self.db)),
            patch.object(monitor, "NOW", 1794916800),  # 2026-11-17T12:00:00Z + 48h window
            patch.object(monitor, "STATE", str(self.state)),
        ]
        for item in self.patches:
            item.start()
        self.addCleanup(patch.stopall)

    def test_report_has_rate_and_killed_turns(self):
        report = monitor.cut_rates()
        row = report["google/gemini-4-argon"]
        self.assertEqual(row["requests"], 10)
        self.assertEqual(row["cuts"], 1)
        self.assertEqual(row["killed_turns"], 1)
        self.assertEqual(row["cuts_per_1000"], 100.0)

    def test_injected_spike_alerts_and_prints_report(self):
        previous = {
            "cut_rates": {
                "google/gemini-4-argon": {
                    "requests": 100, "cuts": 1, "killed_turns": 0,
                    "cuts_per_1000": 10.0,
                }
            }
        }
        problems, info = {}, {}
        monitor.check_cut_rates(problems, info, previous)
        self.assertIn("cut-rate:google/gemini-4-argon", problems)
        self.assertIn("100.00/1,000", problems["cut-rate:google/gemini-4-argon"])
        with patch.object(monitor, "check_health", lambda problems, info: None), \
             patch.object(monitor, "check_proxy", lambda problems: None), \
             patch.object(monitor, "check_missions", lambda problems: None), \
             patch.object(monitor, "check_machines", lambda problems: None), \
             patch.object(monitor, "check_units", lambda problems: None), \
             patch.object(monitor, "check_builds", lambda problems: None), \
             patch.object(monitor, "check_sidecar", lambda problems: None), \
             patch.object(monitor, "notify"):
            self.state.write_text(json.dumps({"problems": {}, "info": previous}))
            output = io.StringIO()
            with patch.object(monitor.sys, "argv", ["orb-monitor", "--print"]), redirect_stdout(output):
                self.assertEqual(monitor.main(), 0)
        printed = json.loads(output.getvalue())
        self.assertEqual(printed["info"]["cut_rates"]["google/gemini-4-argon"]["cuts"], 1)
        self.assertIn("cut-rate:google/gemini-4-argon", printed["problems"])


if __name__ == "__main__":
    unittest.main()
