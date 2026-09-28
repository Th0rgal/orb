#!/usr/bin/env python3
"""Build and stage the native MCP companion for Tauri (always a debug build)."""
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
subprocess.run(["cargo", "build", "-j1", "--bin", "sandboxed-mcp"], cwd=root, check=True)
metadata = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--format-version", "1", "--no-deps"], cwd=root))
target = Path(metadata["target_directory"])
host = next(line.removeprefix("host: ") for line in subprocess.check_output(
    ["rustc", "-vV"], text=True).splitlines() if line.startswith("host: "))
suffix = ".exe" if "windows" in host else ""
source = target / "debug" / f"sandboxed-mcp{suffix}"
destination = root / "orb/src-tauri/binaries" / f"sandboxed-mcp-{host}{suffix}"
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, destination)
# In development the native app is unbundled. Resolve the same companion next
# to its executable, without relying on a repository-controlled PATH entry.
native_metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--format-version", "1", "--no-deps",
    "--manifest-path", str(root / "orb/src-tauri/Cargo.toml")], cwd=root))
native_target = Path(native_metadata["target_directory"]) / "debug"
native_target.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, native_target / f"sandboxed-mcp{suffix}")
print(f"Staged sandboxed-mcp for {host}")
