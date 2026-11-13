"""The guard releases only over-long Claude bans, and stops when the limit is real."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

loader = importlib.machinery.SourceFileLoader("orb_sidecar_guard", str(Path(__file__).parent / "ops/orb-sidecar-guard"))
spec = importlib.util.spec_from_loader(loader.name, loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)

NOW = 1_794_570_000


def login(name, seconds, provider="claude", disabled=False):
    cooldowns = [{"scope": "credential", "reason": "credential_quota", "remaining_seconds": seconds}] if seconds else []
    return {"name": name, "provider": provider, "disabled": disabled, "cooldowns": cooldowns}


class SidecarGuardTest(unittest.TestCase):
    def decide(self, files, lifts=None):
        return guard.decide(files, lifts or {}, NOW, max_ban=21600, max_lifts=3, window=21600)

    def test_replays_the_13_november_ban(self):
        # 131 h credential ban after one 429, account at 8% weekly use.
        release, real, _ = self.decide([login("claude-a.json", 471_600), login("claude-b.json", 0)])
        self.assertEqual((release, real), (["claude-a.json"], []))

    def test_short_bans_and_other_providers_are_left_alone(self):
        files = [login("claude-a.json", 18_000), login("antigravity-x.json", 430_000, provider="antigravity"),
                 login("claude-off.json", 471_600, disabled=True)]
        self.assertEqual(self.decide(files)[:2], ([], []))

    def test_a_ban_that_keeps_coming_back_is_treated_as_real(self):
        lifts = {"claude-a.json": [NOW - 600, NOW - 1200, NOW - 1800]}
        release, real, kept = self.decide([login("claude-a.json", 471_600)], lifts)
        self.assertEqual((release, real), ([], ["claude-a.json"]))
        self.assertEqual(len(kept["claude-a.json"]), 3)

    def test_old_releases_stop_counting(self):
        lifts = {"claude-a.json": [NOW - 30_000, NOW - 40_000, NOW - 50_000]}
        release, _, kept = self.decide([login("claude-a.json", 471_600)], lifts)
        self.assertEqual(release, ["claude-a.json"])
        self.assertNotIn("claude-a.json", kept)


monitor_loader = importlib.machinery.SourceFileLoader("orb_monitor_sidecar", str(Path(__file__).parent / "ops/orb-monitor"))
monitor = importlib.util.module_from_spec(importlib.util.spec_from_loader(monitor_loader.name, monitor_loader))
monitor_loader.exec_module(monitor)


class MonitorSidecarCheckTest(unittest.TestCase):
    def problems(self, files):
        found = {}
        monitor.sidecar_logins = lambda: files
        monitor.check_sidecar(found)
        return found

    def test_reports_the_long_ban_and_that_no_login_is_left(self):
        found = self.problems([dict(login("claude-a.json", 471_600), email="a@example.test")])
        self.assertEqual(sorted(found), ["claude-banned:a@example.test", "claude:none"])

    def test_one_working_login_and_short_bans_are_not_an_outage(self):
        files = [dict(login("claude-a.json", 900), email="a@example.test"), login("claude-b.json", 0),
                 login("antigravity-x.json", 430_000, provider="antigravity")]
        self.assertEqual(self.problems(files), {})


if __name__ == "__main__":
    unittest.main()
