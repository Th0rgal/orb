#!/usr/bin/env python3
"""Orb Local Privileged Execution & Harness Broker (`orb-privd`).

Listens on `/run/orb-privd.sock` (`0660 root:sandboxed-node` / `root:orb-node`)
outside `sandboxed-node.service`'s `NoNewPrivileges=true` cgroup:
1. `update_harness`: Executes `/usr/local/sbin/orb-update-harness <name> <version>`
   for official fleet harnesses (`claude`, `codex`, `opencode`, `grok`) without
   requiring `sudo` or `NoNewPrivileges=false` inside `sandboxed-node.service`.
2. `exec`: Verifies a Touch-ID / Face-ID approved session lease token against Core
   (`POST /api/privilege-access/verify-and-log` -> `orb_privilege_step`), enforces
   `ops_read` / `service_deploy` / `root_exec` command restrictions, executes the
   command as `root`, and records the structured per-command JSON audit entry
   (`command`, `argv`, `cwd`, `exit_code`, `duration_ms`, `stdout_sha256`) in Core.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

SOCKET_PATH = Path(os.environ.get("ORB_PRIVD_SOCKET", "/run/orb-privd.sock"))
TRUSTED_API_URL = (
    os.environ.get("ORB_CORE_API_URL")
    or os.environ.get("ORB_MCP_API_URL")
    or os.environ.get("SANDBOXED_MCP_API_URL")
    or "https://agent-backend.thomas.md"
).strip()
TRUSTED_API_TOKEN = (
    os.environ.get("ORB_CORE_API_TOKEN")
    or os.environ.get("ORB_API_TOKEN")
    or os.environ.get("SANDBOXED_SH_TOKEN")
    or ""
).strip()
HOST_LABEL = os.environ.get("ORB_NODE_NAME") or socket.gethostname()

OPS_READ_BINARIES = {
    "journalctl",
    "systemctl",
    "docker",
    "nft",
    "ss",
    "ps",
    "df",
    "du",
    "free",
    "uptime",
    "uname",
    "cat",
    "head",
    "tail",
    "ls",
    "stat",
    "grep",
    "mdadm",
    "lsblk",
    "smartctl",
}


# Allowlists, not denylists: anything not listed (abbreviated long options,
# --cursor-file, --stop, -t ...) is refused.
READ_ONLY_OPTIONS = {
    "journalctl": {"-u", "--unit", "-n", "--lines", "--since", "--until", "-p", "--priority",
                   "-b", "--boot", "--no-pager", "-o", "--output", "-k", "--dmesg", "-r", "--reverse",
                   "-x", "--catalog", "-e", "--pager-end", "--list-boots", "--disk-usage", "-g", "--grep"},
    "mdadm": {"--detail", "-D", "--examine", "-E", "--query", "-Q", "--scan", "-s", "--verbose", "-v", "--brief", "-b"},
    "smartctl": {"-a", "--all", "-x", "--xall", "-i", "--info", "-H", "--health", "-A", "--attributes",
                 "-l", "--log", "-d", "--device", "-j", "--json"},
}


def _read_only_arg(prog: str, arg: str) -> bool:
    if not arg.startswith("-"):
        # journalctl values (unit names, times, counts); mdadm/smartctl device paths or option values.
        return prog == "journalctl" or arg.startswith("/dev/") or re.fullmatch(r"[A-Za-z0-9_.,=-]+", arg) is not None
    return arg.split("=", 1)[0] in READ_ONLY_OPTIONS[prog]


def check_scope_restrictions(scope: str, allowed_unit: str | None, argv: list[str]) -> None:
    if not argv:
        raise ValueError("Empty command argv")
    prog = Path(argv[0]).name
    if scope == "ops_read":
        if prog not in OPS_READ_BINARIES:
            raise ValueError(f"ops_read grant does not allow binary '{prog}'")
        if prog == "systemctl" and len(argv) >= 2 and argv[1] not in {"status", "show", "list-units", "is-active", "is-failed"}:
            raise ValueError("ops_read grant only allows read-only systemctl subcommands")
        if prog == "docker" and len(argv) >= 2 and argv[1] not in {"ps", "logs", "inspect", "stats", "info", "version"}:
            raise ValueError("ops_read grant only allows read-only docker subcommands")
        if prog == "nft" and argv[1:] != ["list", "ruleset"]:
            raise ValueError("ops_read grant only allows 'nft list ruleset'")
        if prog in READ_ONLY_OPTIONS and not all(_read_only_arg(prog, a) for a in argv[1:]):
            raise ValueError(f"ops_read grant only allows read-only {prog} options")
    elif scope == "service_deploy":
        if prog == "systemctl":
            if len(argv) < 2 or argv[1] not in {"restart", "reload", "status", "start", "stop", "daemon-reload"}:
                raise ValueError("service_deploy grant only allows systemctl service lifecycle subcommands")
            if any(arg.startswith("-") for arg in argv[1:]):
                raise ValueError("service_deploy grant does not allow systemctl option flags")
            if argv[1] == "daemon-reload":
                if len(argv) != 2:
                    raise ValueError("systemctl daemon-reload does not take target unit arguments")
            else:
                targets = argv[2:]
                if not targets:
                    raise ValueError(f"systemctl {argv[1]} requires a target unit")
                if allowed_unit:
                    allowed_names = {allowed_unit, f"{allowed_unit}.service"}
                    for target in targets:
                        if target not in allowed_names:
                            raise ValueError(
                                f"service_deploy grant is restricted to unit '{allowed_unit}' (rejected '{target}')"
                            )
        elif prog == "nginx":
            if argv[1:] not in (["-t"], ["-s", "reload"]):
                raise ValueError("service_deploy grant only allows 'nginx -t' or 'nginx -s reload'")
        else:
            raise ValueError(f"service_deploy grant does not allow arbitrary binary '{prog}'; request root_exec if needed")


def call_core_verify(payload: dict) -> dict:
    url = TRUSTED_API_URL.rstrip("/") + "/api/privilege-access/verify-and-log"
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json", "User-Agent": "orb-privd/1.0"}
    if TRUSTED_API_TOKEN:
        headers["Authorization"] = f"Bearer {TRUSTED_API_TOKEN}"
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Core rejected privilege lease ({err.code}): {detail}") from err


def handle_update_harness(req: dict) -> dict:
    name = str(req.get("name", ""))
    version = str(req.get("version", ""))
    if name not in {"claude", "codex", "opencode", "grok"} or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        return {"ok": False, "exit_code": 2, "stderr": "Invalid harness name or semantic version"}
    helper = "/usr/local/sbin/orb-update-harness"
    if not Path(helper).is_file():
        return {"ok": False, "exit_code": 127, "stderr": f"{helper} is not installed"}
    proc = subprocess.run(
        ["/usr/bin/python3", helper, name, version],
        capture_output=True,
        text=True,
        timeout=300,
        env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "LANG": "C.UTF-8"},
    )
    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def handle_exec(req: dict) -> dict:
    if "api_url" in req or "api_token" in req:
        return {
            "ok": False,
            "exit_code": 2,
            "stderr": "Client-supplied api_url/api_token are forbidden; orb-privd uses its pinned Core endpoint",
        }
    mission_id = str(req.get("mission_id", "")).strip()
    lease_token = str(req.get("lease_token", "")).strip()
    argv = [str(x) for x in req.get("argv", [])]
    cwd = str(req.get("cwd") or "/root")
    target_host = str(req.get("target_host") or "self")

    if not mission_id or not lease_token or not argv:
        return {"ok": False, "exit_code": 2, "stderr": "mission_id, lease_token, and argv are required"}

    command_str = " ".join(argv)
    # 1. Pre-execution admission check via Core's pinned `orb_privilege_step` endpoint
    verdict = call_core_verify(
        {
            "mission_id": mission_id,
            "lease_token": lease_token,
            "target_host": target_host,
            "command": f"[pre-exec] {command_str}",
            "argv": argv,
            "cwd": cwd,
        }
    )
    if not verdict.get("allow_exec"):
        return {"ok": False, "exit_code": 126, "stderr": "Lease denied by Core"}

    scope = str(verdict.get("scope", "root_exec"))
    allowed_unit = verdict.get("allowed_unit")
    if scope != "root_exec" or verdict.get("require_force_cmd"):
        check_scope_restrictions(scope, allowed_unit, argv)

    # 2. Execute command in clean root environment
    t0 = time.monotonic()
    proc = subprocess.run(
        argv,
        cwd=cwd if Path(cwd).is_dir() else "/root",
        capture_output=True,
        timeout=int(req.get("timeout_secs", 600)),
        env={
            "PATH": "/opt/orb-tools/bin:/opt/sandboxed-tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "LANG": "C.UTF-8",
            "ORB_MISSION_ID": mission_id,
            "ORB_JIT_GRANT_ID": str(verdict.get("grant_id", "")),
        },
    )
    duration_ms = int((time.monotonic() - t0) * 1000)
    stdout_bytes = proc.stdout or b""
    stderr_bytes = proc.stderr or b""
    stdout_sha256 = hashlib.sha256(stdout_bytes).hexdigest()

    # 3. Record structured completion audit entry in Core
    try:
        call_core_verify(
            {
                "mission_id": mission_id,
                "lease_token": lease_token,
                "target_host": target_host,
                "command": command_str,
                "argv": argv,
                "cwd": cwd,
                "exit_code": proc.returncode,
                "duration_ms": duration_ms,
                "stdout_sha256": stdout_sha256,
            }
        )
    except Exception as audit_err:
        sys.stderr.write(f"orb-privd: audit completion post warning: {audit_err}\n")

    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "duration_ms": duration_ms,
        "stdout_sha256": stdout_sha256,
        "stdout": stdout_bytes.decode("utf-8", errors="replace"),
        "stderr": stderr_bytes.decode("utf-8", errors="replace"),
    }


def serve_conn(conn: socket.socket) -> None:
    try:
        # SO_PEERCRED on Linux: struct ucred { pid_t pid; uid_t uid; gid_t gid; }
        creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        pid, uid, gid = struct.unpack("3i", creds)
        raw = b""
        while len(raw) < 256 * 1024:
            chunk = conn.recv(16384)
            if not chunk:
                break
            raw += chunk
        req = json.loads(raw.decode("utf-8"))
        action = req.get("action", "exec")
        if action == "update_harness":
            resp = handle_update_harness(req)
        elif action == "exec":
            resp = handle_exec(req)
        elif action == "ping":
            resp = {"ok": True, "pid": pid, "uid": uid, "gid": gid, "host": HOST_LABEL}
        else:
            resp = {"ok": False, "exit_code": 2, "stderr": f"Unknown action: {action}"}
    except Exception as exc:
        resp = {"ok": False, "exit_code": 1, "stderr": str(exc)}
    try:
        conn.sendall(json.dumps(resp).encode("utf-8"))
    except Exception:
        pass
    finally:
        conn.close()


def main() -> None:
    if os.geteuid() != 0:
        raise SystemExit("orb-privd must run as root")
    SOCKET_PATH.parent.mkdir(parents=True, exist_ok=True)
    SOCKET_PATH.unlink(missing_ok=True)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(SOCKET_PATH))
    os.chmod(SOCKET_PATH, 0o660)
    try:
        import grp
        for group_name in ("orb-node", "sandboxed-node"):
            try:
                gid = grp.getgrnam(group_name).gr_gid
                os.chown(SOCKET_PATH, 0, gid)
                break
            except KeyError:
                continue
    except Exception:
        pass
    srv.listen(16)
    while True:
        conn, _ = srv.accept()
        serve_conn(conn)


if __name__ == "__main__":
    main()
