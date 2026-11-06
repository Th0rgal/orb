#!/usr/bin/env python3
"""Build the macOS Secure Enclave approval signer for the native macos_shell."""
from pathlib import Path
import platform
import subprocess

repo = Path(__file__).resolve().parents[2]
arch = platform.machine()
out = repo / "macos_shell/build/orb-signer"
out.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(
    [
        "swiftc",
        "-O",
        "-framework",
        "Security",
        "-framework",
        "LocalAuthentication",
        str(repo / "macos_shell/signer/main.swift"),
        "-o",
        str(out),
    ],
    check=True,
)
print(f"Staged orb-signer ({arch}) at {out}")
