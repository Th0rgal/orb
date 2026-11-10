#!/usr/bin/env python3
"""Build or stage the approval signer for macOS (Secure Enclave) or Linux (fprintd/Polkit)."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import sys

repo = Path(__file__).resolve().parents[2]
sys_name = platform.system()
arch = platform.machine()

if sys_name == "Darwin":
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
elif sys_name == "Linux":
    src = repo / "linux_shell/signer/orb-signer.py"
    out = repo / "linux_shell/build/orb-signer"
    out.parent.mkdir(parents=True, exist_ok=True)
    text = src.read_text(encoding="utf-8")
    py_exe = sys.executable if sys.executable and os.path.isfile(sys.executable) else "/usr/bin/env python3"
    if text.startswith("#!"):
        text = f"#!{py_exe}\n" + text.split("\n", 1)[1]
    openssl_bin = shutil.which("openssl") or ""
    if openssl_bin:
        text = text.replace(
            'os.environ.get("ORB_OPENSSL_BIN", "")',
            f'os.environ.get("ORB_OPENSSL_BIN", {openssl_bin!r})',
            1,
        )
    out.write_text(text, encoding="utf-8")
    out.chmod(0o755)
    print(f"Staged orb-signer ({arch}) at {out}")
else:
    raise SystemExit(f"Unsupported OS for orb-signer: {sys_name}")
