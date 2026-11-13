"""Transferred thresholds affect checks, without reading credentials or a live API."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("orb_monitor", str(Path(__file__).parent / "ops/orb-monitor"))
spec = importlib.util.spec_from_loader(loader.name, loader)
monitor = importlib.util.module_from_spec(spec)
loader.exec_module(monitor)


class MonitorSettingsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.db = self.root / "managed.db"
        with sqlite3.connect(self.db) as con:
            con.execute("CREATE TABLE core_monitor_settings(singleton_id INTEGER PRIMARY KEY,data TEXT)")
        self.addCleanup(patch.stopall)
        patch.object(monitor, "COMPUTE_DB", str(self.db)).start()
        patch.object(monitor, "THRESHOLDS", monitor.DEFAULT_THRESHOLDS.copy()).start()

    def put(self, value):
        with sqlite3.connect(self.db) as con:
            con.execute("INSERT OR REPLACE INTO core_monitor_settings VALUES(1,?)", [json.dumps(value)])

    def test_empty_and_legacy_database_use_existing_defaults(self):
        self.assertEqual(monitor.load_thresholds(), monitor.DEFAULT_THRESHOLDS)
        with sqlite3.connect(self.db) as con:
            con.execute("DROP TABLE core_monitor_settings")
        self.assertEqual(monitor.load_thresholds(), monitor.DEFAULT_THRESHOLDS)

    def test_imported_proxy_threshold_and_window_affect_check(self):
        self.put({"proxy_5xx_count": 2, "proxy_window_seconds": 60})
        monitor.THRESHOLDS.update(monitor.load_thresholds())
        log = self.root / "access.log"
        # Prefix is deliberately ignored because the production reader may
        # start at a partial line in its bounded tail.
        stamp = monitor.datetime.datetime.fromtimestamp(monitor.NOW, monitor.datetime.timezone.utc).strftime("%d/%b/%Y:%H:%M:%S %z")
        log.write_text("prefix\n" + (f'127.0.0.1 [{stamp}] "POST /v1/messages HTTP/1.1" 502 0\n' * 2))
        with patch.object(monitor, "NGINX_LOG", str(log)):
            problems = {}
            monitor.check_proxy(problems)
            self.assertIn("proxy:5xx", problems)
            self.assertIn("60s", problems["proxy:5xx"])
            monitor.THRESHOLDS.update(monitor.DEFAULT_THRESHOLDS)
            problems = {}
            monitor.check_proxy(problems)
            self.assertNotIn("proxy:5xx", problems)

    def test_invalid_and_secret_fields_are_rejected_without_echo(self):
        for value in ({"api_key": "do-not-echo"}, {"stall_minutes": 0},
                      {"proxy_window_seconds": -1}, {"long_build_minutes": True},
                      {"proxy_5xx_count": 1_000_001}, [], None):
            with self.subTest(value=value):
                self.put(value)
                with self.assertRaises(ValueError) as caught:
                    monitor.load_thresholds()
                self.assertNotIn("do-not-echo", str(caught.exception))

    def test_imported_build_threshold_affects_check(self):
        self.put({"long_build_minutes": 10})
        monitor.THRESHOLDS.update(monitor.load_thresholds())
        with patch.object(monitor.subprocess, "run") as run:
            run.return_value.stdout = "700 lake\n"
            problems = {}
            monitor.check_builds(problems)
        self.assertIn("build:long", problems)


if __name__ == "__main__":
    unittest.main()
