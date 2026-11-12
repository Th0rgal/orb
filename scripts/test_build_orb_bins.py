import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BuildOrbBinsTests(unittest.TestCase):
    def run_build(self, turbo=None, skip=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "scripts"
            scripts.mkdir()
            script = scripts / "build_orb_bins.sh"
            shutil.copyfile(Path(__file__).with_name("build_orb_bins.sh"), script)
            dependency = root / "lean/OrbBin/.lake/packages/lean-sys"
            dependency.mkdir(parents=True)
            (dependency / "lakefile.lean").touch()
            tools = root / "tools"
            tools.mkdir()
            for tool in ("bash", "dirname", "uname"):
                (tools / tool).symlink_to(shutil.which(tool))
            marker = root / "raw-lake"
            lean = tools / "lean"
            lean.write_text("#!/bin/bash\nexit 0\n")
            lean.chmod(0o755)
            lake = tools / "lake"
            lake.write_text(f'#!/bin/bash\ntouch "{marker}"\nexit 99\n')
            lake.chmod(0o755)
            if turbo is not None:
                binary = tools / "turbo-lean"
                binary.write_text(f"#!/bin/bash\nexit {turbo}\n")
                binary.chmod(0o755)
            env = dict(os.environ, HOME=str(root), PATH=str(tools), LEAN_BIN_DIR=str(tools),
                       ORB_SKIP_TURBO_LEAN="1" if skip else "0", LEAN_CC="", NIX_CC="")
            result = subprocess.run([str(tools / "bash"), str(script), "--only", "fido-agent-proxy"],
                                    env=env, capture_output=True, text=True)
            self.assertFalse(marker.exists())
            return result

    def test_missing_turbo_fails_closed(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("turbo-lean is required", result.stderr)

    def test_failed_turbo_preserves_failure_without_lake_fallback(self):
        result = self.run_build(turbo=23)
        self.assertEqual(result.returncode, 23, result.stderr)

    def test_skip_turbo_cannot_enable_lake_fallback(self):
        result = self.run_build(turbo=0, skip=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("turbo-lean is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
