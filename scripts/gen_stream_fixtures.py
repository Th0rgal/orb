#!/usr/bin/env python3
"""Regenerate (or --check) shared/orb-spec/fixtures/stream-commit.json from lean/Orb/Stream.lean.

Builds the Lean project with turbo-lean (falls back to lake), then runs
scripts/gen_stream_fixtures.lean against the built Orb.Stream olean."""
import os, pathlib, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "shared/orb-spec/fixtures/stream-commit.json"


def main() -> int:
    lean_dir = ROOT / "lean"
    if shutil.which("turbo-lean"):
        subprocess.run(["turbo-lean", "build", "--project-dir", str(lean_dir)], check=True, stdout=subprocess.DEVNULL)
    else:
        subprocess.run(["lake", "build"], cwd=lean_dir, check=True)
    lib = lean_dir / ".lake/build/lib/lean"
    prefix = subprocess.run(["lean", "--print-prefix"], capture_output=True, text=True, check=True).stdout.strip()
    env = dict(os.environ, LEAN_PATH=os.pathsep.join([str(lib), str(pathlib.Path(prefix) / "lib/lean")]))
    out = subprocess.run(["lean", "--run", str(ROOT / "scripts/gen_stream_fixtures.lean")], capture_output=True, text=True, check=True, env=env).stdout
    if "--check" in sys.argv:
        if not OUT.is_file() or OUT.read_text() != out:
            print(f"{OUT.relative_to(ROOT)} is stale: run python3 scripts/gen_stream_fixtures.py", file=sys.stderr)
            return 1
        print(f"{OUT.relative_to(ROOT)} up to date")
        return 0
    OUT.write_text(out)
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
