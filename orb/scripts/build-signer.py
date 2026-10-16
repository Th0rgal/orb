#!/usr/bin/env python3
"""Build the macOS Secure Enclave approval signer and stage it as a Tauri sidecar."""
from pathlib import Path
import subprocess

orb = Path(__file__).resolve().parents[1]
host = next(line.removeprefix("host: ") for line in subprocess.check_output(
    ["rustc", "-vV"], text=True).splitlines() if line.startswith("host: "))
out = orb / "src-tauri/binaries" / f"orb-signer-{host}"
out.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(["swiftc", "-O", str(orb / "src-tauri/signer/main.swift"), "-o", str(out)], check=True)
print(f"Staged orb-signer for {host}")
