#!/usr/bin/env python3
"""OPS-04 packaging contract: the privd unit executes the installed native artifact."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
UNIT = ROOT / "deploy/systemd/orb-privd.service"
DEPLOY = ROOT / "scripts/ops/orb-deploy"
BUILD = ROOT / "scripts/build_orb_bins.sh"


def exec_start_values(unit_text):
    values = []
    for line in unit_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("ExecStart="):
            values.append(stripped.split("=", 1)[1].strip())
    return values


class OrbPrivdUnitPackagingTests(unittest.TestCase):
    def test_execstart_runs_installed_native_artifact_directly(self):
        values = exec_start_values(UNIT.read_text())
        self.assertEqual(values, ["/usr/local/sbin/orb-privd"])
        self.assertNotIn("python", UNIT.read_text().lower())

    def test_installed_path_matches_deploy_and_build_targets(self):
        deploy = DEPLOY.read_text()
        build = BUILD.read_text()
        self.assertIn('install -m 755 "$PRIVD_BIN" /usr/local/sbin/orb-privd', deploy)
        self.assertIn('"orb-privd"', build)
        self.assertIn("refusing to stage", build)


if __name__ == "__main__":
    unittest.main()
