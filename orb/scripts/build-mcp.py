#!/usr/bin/env python3
"""Build and stage the native Lean 4 MCP companion (`sandboxed-mcp`) for Orb desktop shells."""
import os
from pathlib import Path
import platform
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
target = Path(os.environ.get("CARGO_TARGET_DIR", str(root / "target"))) / "debug"
subprocess.run(
    [str(root / "scripts/build_orb_bins.sh"), "--ensure-lean", "--out-dir", str(target), "--only", "sandboxed-mcp"],
    cwd=root,
    check=True,
)
sys_name = platform.system().lower()
mach = platform.machine().lower()
suffix = ".exe" if "windows" in sys_name else ""
source = target / f"sandboxed-mcp{suffix}"

shell_dir = root / ("macos_shell" if sys_name == "darwin" else "linux_shell") / "build"
shell_dir.mkdir(parents=True, exist_ok=True)
dest = shell_dir / f"sandboxed-mcp{suffix}"
if source.resolve() != dest.resolve():
    shutil.copy2(source, dest)
print(f"Staged sandboxed-mcp ({sys_name}/{mach}) at {dest}")
