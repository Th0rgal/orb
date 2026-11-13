#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("build_orb_bins.sh").resolve()


class BuildOrbBinsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/build_orb_bins.sh")
        (self.root / "lean/OrbBin/.lake/build/bin").mkdir(parents=True)
        (self.root / "lean/turbo-lean-revision").write_text("fixture-revision\n")
        self.bin = self.root / "tools"
        self.bin.mkdir()
        for name in ("dirname", "uname", "rm", "mkdir", "install", "ln", "grep"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.env = {
            "PATH": str(self.bin), "HOME": str(self.root / "home"),
            "LEAN_BIN_DIR": str(self.bin), "TEST_ROOT": str(self.root),
        }
        self.fake("lake", 'printf "lake\\n" >> "$TEST_ROOT/calls"\nexit 99\n')
        self.fake("curl", 'printf "curl\\n" >> "$TEST_ROOT/calls"\nexit 99\n')
        self.fake("nm", "exit 0\n")
        self.source = self.root / "lean/OrbBin/.lake/build/bin/fido-agent-proxy"
        self.out = self.root / "out"

    def fake(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body)
        p.chmod(0o755)

    def turbo(self, mode="success"):
        p = self.bin / "turbo-lean"
        p.write_text(f'''#!{shutil.which("python3")}
import json, os, pathlib, sys
root = pathlib.Path(os.environ["TEST_ROOT"])
with (root / "argv").open("a") as f:
    f.write(json.dumps([sys.argv[1:], os.environ.get("LEAN_NUM_THREADS")]) + "\\n")
if sys.argv[1:] == ["--no-telemetry", "--help"]:
    sys.exit({2 if mode == "reject" else 0})
if {mode!r} == "fail":
    sys.exit(42)
if {mode!r} == "success":
    p = pathlib.Path(".lake/build/bin/fido-agent-proxy")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("#!/bin/sh\\nexit 0\\n")
    p.chmod(0o755)
''')
        p.chmod(0o755)

    def run_script(self, *args, **env):
        return subprocess.run(
            [shutil.which("bash"), str(self.root / "scripts/build_orb_bins.sh"),
             "--only", "fido-agent-proxy", "--out-dir", str(self.out), *args],
            env={**self.env, **env}, capture_output=True, text=True, timeout=20)

    def assert_no_fallback(self):
        self.assertFalse((self.root / "calls").exists())
        self.assertFalse(self.out.exists())

    def test_no_turbo(self):
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture-revision", result.stderr)
        self.assert_no_fallback()

    def test_rejected_interface(self):
        self.turbo("reject")
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_no_fallback()

    def test_skip_cannot_bypass_failed_build(self):
        self.turbo("fail")
        self.assertEqual(self.run_script(ORB_SKIP_TURBO_LEAN="1").returncode, 42)
        self.assert_no_fallback()

    def test_failed_build_does_not_stage_stale_binary(self):
        self.turbo("fail")
        self.source.write_text("stale")
        self.source.chmod(0o755)
        self.assertEqual(self.run_script().returncode, 42)
        self.assertFalse(self.source.exists())
        self.assert_no_fallback()

    def test_success_without_output_cannot_stage_stale_binary(self):
        self.turbo("noop")
        self.source.write_text("stale")
        self.source.chmod(0o755)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.out / "fido-agent-proxy").exists())
        self.assertIn("expected built binary missing", result.stderr)

    def test_success_argv_and_threads(self):
        self.turbo()
        for threads in (None, "3"):
            with self.subTest(threads=threads):
                env = {} if threads is None else {"LEAN_NUM_THREADS": threads}
                result = self.run_script(TURBO_LEAN_NO_DAEMON="1", **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                records = [json.loads(line) for line in (self.root / "argv").read_text().splitlines()]
                self.assertEqual(records[-1], [["--no-telemetry", "--max-memory-mb", "6144", "--no-daemon", "build", "fido-agent-proxy"], threads])
                self.assertEqual((self.out / "fido-agent-proxy").read_bytes(), self.source.read_bytes())
                self.assertFalse((self.root / "calls").exists())

    def test_ensure_lean_without_turbo_never_downloads(self):
        (self.bin / "lake").unlink()
        result = self.run_script("--ensure-lean")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_fallback()


if __name__ == "__main__":
    unittest.main()
