#!/usr/bin/env python3
"""Integration regression: a warm native build must notice a LeanUI source edit."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    env = dict(os.environ)
    env.pop("ORB_ALLOW_RAW_LAKE_FALLBACK", None)
    env.pop("ORB_SKIP_TURBO_LEAN", None)
    command = [str(ROOT / "scripts/build_orb_bins.sh"), "--only",
               "orb-desktop-native", "--out-dir", str(ROOT / "target/native")]
    subprocess.run(command, cwd=ROOT, env=env, check=True)
    source = ROOT / "lean/OrbDesktop/LeanUI/Style.lean"
    original = source.read_bytes()
    try:
        source.write_bytes(original + b'\n#check native_desktop_cache_probe\n')
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0 or "native_desktop_cache_probe" not in result.stdout:
            raise AssertionError("warm build ignored the LeanUI edit:\n" + result.stdout)
    finally:
        source.write_bytes(original)
    subprocess.run(command, cwd=ROOT, env=env, check=True)
    subprocess.run([str(ROOT / "target/native/orb-desktop-native"), "--self-test"],
                   cwd=ROOT, env=env, check=True)
    print("Native desktop warm-cache edit regression passed")


if __name__ == "__main__":
    main()
