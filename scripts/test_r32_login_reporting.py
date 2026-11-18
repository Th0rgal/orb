"""R32 fixture replay: one alert, repeat-poll deduplication and fresh login."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("orb_monitor", str(ROOT / "scripts/ops/orb-monitor"))
spec = importlib.util.spec_from_loader(loader.name, loader)
monitor = importlib.util.module_from_spec(spec)
loader.exec_module(monitor)


class R32LoginReporting(unittest.TestCase):
    def test_r32_one_monitor_alert_repeat_poll_and_fresh_login(self):
        fixture = json.loads((ROOT / "shared/orb-spec/fixtures/provider-login-health.json").read_text())
        files = fixture["files"]
        with tempfile.TemporaryDirectory() as tmp, patch.object(monitor, "STATE", tmp + "/state.json"), \
                patch.object(monitor, "sidecar_logins", side_effect=lambda: files), \
                patch.object(monitor, "load_thresholds", return_value=monitor.DEFAULT_THRESHOLDS), \
                patch.object(monitor, "notify") as notify:
            from contextlib import ExitStack
            with ExitStack() as stack:
                for name in ("check_health", "check_proxy", "check_missions", "check_machines", "check_units", "check_builds"):
                    stack.enter_context(patch.object(monitor, name, return_value=None))
                stack.enter_context(patch.object(monitor, "check_cut_rates", return_value=None))
                stack.enter_context(patch.object(monitor, "ro", side_effect=Exception("unused sqlite")))
                stack.enter_context(patch.object(monitor, "subprocess", run=lambda *args, **kwargs: type("R", (), {"stdout": ""})()))
                Path(monitor.STATE).write_text('{"problems":{},"info":{}}')
                monitor.main()
                monitor.main()
                self.assertEqual(notify.call_count, 1)
                self.assertIn(fixture["expected_label"], notify.call_args.args[0])
                self.assertEqual(list(json.loads(Path(monitor.STATE).read_text())["problems"]),
                                 [fixture["expected_monitor_key"]])
                files = [{"name": "fresh.json", "provider": "claude", "status": "ok"}]
                monitor.main()
                self.assertEqual(json.loads(Path(monitor.STATE).read_text())["problems"], {})

    def test_r32_partial_provider_login_failure_does_not_alert(self):
        fixture = json.loads((ROOT / "shared/orb-spec/fixtures/provider-login-health.json").read_text())
        files = fixture["files"] + [{"name": "healthy.json", "provider": "claude", "status": "ok"}]
        with tempfile.TemporaryDirectory() as tmp, patch.object(monitor, "STATE", tmp + "/state.json"), \
                patch.object(monitor, "sidecar_logins", return_value=files), \
                patch.object(monitor, "load_thresholds", return_value=monitor.DEFAULT_THRESHOLDS), \
                patch.object(monitor, "notify") as notify:
            Path(monitor.STATE).write_text('{"problems":{},"info":{}}')
            for name in ("check_health", "check_proxy", "check_missions", "check_machines", "check_units", "check_builds", "check_cut_rates"):
                patch.object(monitor, name, return_value=None).start()
            try:
                monitor.main()
            finally:
                patch.stopall()
            self.assertEqual(notify.call_count, 0)
            self.assertNotIn(fixture["expected_monitor_key"], json.loads(Path(monitor.STATE).read_text())["problems"])


if __name__ == "__main__":
    unittest.main()
