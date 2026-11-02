#!/usr/bin/env python3
"""Unit tests for scripts/disk_sentinel.sh hysteresis, escalation, and cooldown."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "disk_sentinel.sh"
GIB = 1073741824


class DiskSentinelTest(unittest.TestCase):
    def _run_sentinel(self, samples: dict[str, str], state_file: Path, now: int, stateless: bool = False) -> list[str]:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tf:
            for host, val in samples.items():
                tf.write(f"{host}\t{val}\n")
            input_path = Path(tf.name)
        try:
            env = os.environ.copy()
            env["DISK_SENTINEL_INPUT_FILE"] = str(input_path)
            env["DISK_SENTINEL_STATE_FILE"] = str(state_file)
            env["DISK_SENTINEL_NOW"] = str(now)
            cmd = ["bash", str(SCRIPT)]
            if stateless:
                cmd.append("--stateless")
            res = subprocess.run(cmd, env=env, capture_output=True, text=True, check=True)
            return [line for line in res.stdout.splitlines() if line.strip()]
        finally:
            input_path.unlink(missing_ok=True)

    def test_hysteresis_escalation_cooldown_and_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"

            # 1. All healthy -> completely silent
            out = self._run_sentinel({"nippur": f"70% {130 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=1000)
            self.assertEqual(out, [])

            # 2. nippur crosses WARN (85%) -> alerts once
            out = self._run_sentinel({"nippur": f"86% {62 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=2800)
            self.assertEqual(out, ["DISK WARN nippur: 86% used, 62 GiB free"])

            # 3. 30m later still at 88% -> suppressed within 12h cooldown!
            out = self._run_sentinel({"nippur": f"88% {53 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=4600)
            self.assertEqual(out, [])

            # 4. Escalates to CRITICAL (94%, 29 GiB free) -> alerts immediately despite cooldown!
            out = self._run_sentinel({"nippur": f"94% {29 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=6400)
            self.assertEqual(out, ["DISK CRITICAL nippur: 94% used, 29 GiB free"])

            # 5. Drops slightly to 90% (WARN) or 84% (inside 3% hysteresis margin >82%) -> stays silent, no bounce!
            out = self._run_sentinel({"nippur": f"90% {44 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=8200)
            self.assertEqual(out, [])
            out = self._run_sentinel({"nippur": f"84% {71 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=10000)
            self.assertEqual(out, [])

            # 6. 12h after the CRITICAL alert, still at 86% -> emits periodic 12h reminder at current WARN tier
            out = self._run_sentinel({"nippur": f"86% {62 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=6400 + 43200)
            self.assertEqual(out, ["DISK WARN nippur: 86% used, 62 GiB free"])

            # 7. --stateless always prints current degraded state without altering cooldown
            stateless_out = self._run_sentinel(
                {"nippur": f"86% {62 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=6400 + 43300, stateless=True
            )
            self.assertEqual(stateless_out, ["DISK WARN nippur: 86% used, 62 GiB free"])

            # 8. Drops to <=82% (recover_pct = 85 - 3 = 82) -> emits single DISK RECOVERED notice, then silent
            out = self._run_sentinel({"nippur": f"82% {80 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=6400 + 45000)
            self.assertEqual(out, ["DISK RECOVERED nippur: 82% used, 80 GiB free"])
            out = self._run_sentinel({"nippur": f"82% {80 * GIB}", "ashur": f"60% {180 * GIB}"}, state, now=6400 + 46800)
            self.assertEqual(out, [])

    def test_unreachable_cooldown_and_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"

            out = self._run_sentinel({"dgx-spark": ""}, state, now=1000)
            self.assertEqual(out, ["DISK UNKNOWN dgx-spark: unreachable"])

            # Suppressed 30m later
            out = self._run_sentinel({"dgx-spark": ""}, state, now=2800)
            self.assertEqual(out, [])

            # Repeats after 6h (21600s)
            out = self._run_sentinel({"dgx-spark": ""}, state, now=1000 + 21600)
            self.assertEqual(out, ["DISK UNKNOWN dgx-spark: unreachable"])

            # Comes back healthy -> emits DISK RECOVERED
            out = self._run_sentinel({"dgx-spark": f"59% {1500 * GIB}"}, state, now=1000 + 23400)
            self.assertEqual(out, ["DISK RECOVERED dgx-spark: 59% used, 1500 GiB free"])


if __name__ == "__main__":
    unittest.main()
