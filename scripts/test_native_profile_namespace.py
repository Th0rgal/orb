#!/usr/bin/env python3
"""Exercise Core's profile mount and process boundary in a disposable Linux user namespace."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from native_job_relay.profile import start_profile


def run():
    if os.getuid() != 0:
        raise RuntimeError("run in a disposable root user and network namespace")
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        home, ipc, image = (base / name for name in ("home", "ipc", "image"))
        for name in ("bin", "session/.agents", "dev", "proc", "tmp", "home/orb", "ipc"):
            (image / name).mkdir(parents=True)
        (image / "session/.agents/mcp_config.json").touch()
        ipc.mkdir()
        home.mkdir(mode=0o700)
        for name in (".gemini/config/agents/orb-workspace.md", ".gemini/antigravity-cli/settings.json",
                     ".gemini/antigravity-cli/antigravity-oauth-token"):
            dest = home / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.touch()
        uid = 16001
        for p in (home, *home.rglob("*")):
            os.chown(p, uid, uid)
        for exe, name in [(shutil.which("sh"), "sh"), (shutil.which("setpriv"), "setpriv")]:
            shutil.copy2(exe, image / "bin" / name)
            for line in subprocess.check_output(["ldd", exe], text=True).splitlines():
                libs = [word for word in line.split() if word.startswith("/")]
                if libs:
                    lib = Path(libs[0])
                    dest = image / lib.relative_to("/")
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(lib, dest)
        probe = image / "bin/agy"
        probe.write_text("""#!/bin/sh
set -eu
[ "$HOME" = /home/orb ] && [ "$PWD" = /session ] && [ -z "${GEMINI_API_KEY:-}" ]
[ "$HTTPS_PROXY" = socks5://127.0.0.1:23456 ]
[ ! -e /root/.gemini ] && [ ! -e /workspace ]
case "$*" in *fixture-marker*|*access-only-value*) exit 2;; esac
while IFS= read -r line; do case "$line" in Uid:*) set -- $line; [ "$2" = 16001 ];; esac; done </proc/self/status
token=$HOME/.gemini/antigravity-cli/antigravity-oauth-token
[ -r "$token" ] && [ ! -w "$token" ]
IFS= read -r value <"$token" || true
case "$value" in *access-only-value*) :;; *) exit 3;; esac
case "$value" in *refresh_token*) exit 4;; esac
[ -r .agents/mcp_config.json ] && [ ! -w .agents/mcp_config.json ]
IFS= read -r data
case "$data" in *fixture-marker*) :;; *) exit 5;; esac
echo verified
""")
        probe.chmod(0o755)
        fds = [os.open(p, os.O_RDONLY) for p in (image, home, ipc, "/proc/thread-self/ns/net")]
        try:
            proc = start_profile(shutil.which("nsenter"), shutil.which("bwrap"), *fds, 23456, uid, uid,
                                 "access-only-value", "gemini-4-neon-high")
            result, _ = proc.communicate(b'{"event":"user","message":{"role":"user","content":"fixture-marker"}}\n', timeout=8)
            assert (proc.returncode, result) == (0, b"verified\n"), (proc.returncode, result)
        finally:
            for fd in fds:
                os.close(fd)
        assert (home / ".gemini/antigravity-cli/antigravity-oauth-token").stat().st_size == 0
        print("Core profile: isolated UID, read-only access-only credential, assigned proxy, prompt on stdin, no host home or checkout")


if __name__ == "__main__":
    run()
