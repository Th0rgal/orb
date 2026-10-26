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

import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
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
    or os.environ.get("ORB_NODE_TOKEN")
    or os.environ.get("SANDBOXED_NODE_TOKEN")
    or ""
).strip()
SOCKET_GROUP = (os.environ.get("ORB_PRIVD_SOCKET_GROUP") or "").strip()
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
                 "-d", "--device", "-j", "--json"},
}


UNSAFE_ENV_KEYS = {
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
    "LD_AUDIT",
    "BASH_ENV",
    "ENV",
    "PROMPT_COMMAND",
    "PYTHONPATH",
    "PERL5LIB",
    "RUBYLIB",
    "NODE_OPTIONS",
    "DYLD_INSERT_LIBRARIES",
    "ORB_CORE_API_URL",
    "ORB_CORE_API_TOKEN",
}


TRUSTED_EXEC_DIRS = ("/bin", "/usr/bin", "/sbin", "/usr/sbin")
TRUSTED_EXEC_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"


def _load_orb_kernel_so():
    candidates = [
        os.environ.get("ORB_KERNEL_SO_PATH", "").strip(),
        "/usr/lib/orb/liborb_kernel.so",
        "/usr/local/lib/liborb_kernel.so",
    ]
    # Core embeds some of these scripts and runs them with `python3 -c`,
    # where `__file__` does not exist: the repo copies only apply on disk.
    if "__file__" in globals():
        repo_root = Path(__file__).resolve().parent.parent
        candidates += [
            str(repo_root / "android_dashboard/app/src/test/resources/jni/liborb_kernel.so"),
            str(repo_root / "android_dashboard/app/src/main/jniLibs/x86_64/liborb_kernel.so"),
            str(repo_root / "android_dashboard/app/build/host-jni/liborb_kernel.so"),
        ]
    for cand in candidates:
        if not cand:
            continue
        p = Path(cand)
        if p.is_file():
            try:
                lib = ctypes.CDLL(str(p))
                fn = lib.orb_privd_command_step
                fn.argtypes = [ctypes.c_uint8] * 8
                fn.restype = ctypes.c_uint64
                return lib
            except OSError:
                continue
    if os.environ.get("ORB_PRIVD_REQUIRE_NATIVE_SO") == "1":
        raise RuntimeError("liborb_kernel.so with orb_privd_command_step is required")
    return None


_ORB_KERNEL_SO = _load_orb_kernel_so()


def orb_privd_command_step(
    lease_valid: int,
    grant_scope: int,
    command_class: int,
    unit_matches_allowed: int,
    has_shell_metachar_or_flag_bypass: int,
    has_path_traversal_or_symlink: int,
    has_unsafe_env_var: int,
    require_force_cmd: int,
) -> int:
    """Invoke Lean 4 `Orb.Kernel.privdCommandStep` (`orb_privd_command_step`) via `liborb_kernel.so` and verified mirror."""
    safe_input = (
        lease_valid == 1
        and has_shell_metachar_or_flag_bypass == 0
        and has_path_traversal_or_symlink == 0
        and has_unsafe_env_var == 0
    )
    if not safe_input or not (0 <= grant_scope <= 2):
        lo32 = 1536
    elif command_class == 1:
        lo32 = 1793
    elif command_class == 2 and 1 <= grant_scope and unit_matches_allowed == 1:
        lo32 = 1794
    elif command_class == 3 and 1 <= grant_scope:
        lo32 = 1794
    elif command_class == 4 and grant_scope == 2 and require_force_cmd == 0:
        lo32 = 1795
    else:
        lo32 = 1536
    hi32 = 126 if lo32 == 1536 else 0
    mirror = lo32 | (hi32 << 32)
    if _ORB_KERNEL_SO is not None:
        native = int(
            _ORB_KERNEL_SO.orb_privd_command_step(
                lease_valid & 0xFF,
                grant_scope & 0xFF,
                command_class & 0xFF,
                unit_matches_allowed & 0xFF,
                has_shell_metachar_or_flag_bypass & 0xFF,
                has_path_traversal_or_symlink & 0xFF,
                has_unsafe_env_var & 0xFF,
                require_force_cmd & 0xFF,
            )
        )
        if native != mirror:
            raise RuntimeError(f"orb_privd_command_step divergence: native={native:#x} mirror={mirror:#x}")
        return native
    return mirror


def _is_trusted_executable_token(raw_exe: str) -> bool:
    if not raw_exe or raw_exe in (".", ".."):
        return False
    if "/" not in raw_exe and "\\" not in raw_exe:
        return True
    if (
        "\\" in raw_exe
        or raw_exe.startswith("./")
        or raw_exe.startswith("../")
        or "/./" in raw_exe
        or "/../" in raw_exe
    ):
        return False
    exe_path = Path(raw_exe)
    if not exe_path.is_absolute() or str(exe_path.parent) not in TRUSTED_EXEC_DIRS:
        return False
    if exe_path.is_symlink():
        try:
            canon_parent = str(exe_path.resolve().parent)
        except OSError:
            return False
        if canon_parent not in TRUSTED_EXEC_DIRS:
            return False
    return True


def _read_only_arg(prog: str, arg: str) -> bool:
    if not arg.startswith("-"):
        # journalctl values (unit names, times, counts); mdadm/smartctl device paths or option values.
        return prog == "journalctl" or arg.startswith("/dev/") or re.fullmatch(r"[A-Za-z0-9_.,=-]+", arg) is not None
    return arg.split("=", 1)[0] in READ_ONLY_OPTIONS[prog]


def check_scope_restrictions(
    scope: str,
    allowed_unit: str | None,
    argv: list[str],
    *,
    cwd: str | None = None,
    env: dict[str, str] | None = None,
    require_force_cmd: bool = False,
) -> int:
    if not argv:
        raise ValueError("Empty command argv")
    scope_rank = {"ops_read": 0, "service_deploy": 1, "root_exec": 2}.get(scope, 255)
    has_unsafe_env = int(
        bool(env and any(str(k).strip().upper() in UNSAFE_ENV_KEYS for k in env))
        or any(
            "=" in tok and tok.split("=", 1)[0].strip().upper() in UNSAFE_ENV_KEYS
            for tok in argv
        )
    )
    cwd_bad = False
    if cwd is not None and str(cwd).strip():
        cwd_path = Path(str(cwd).strip())
        if not cwd_path.is_absolute() or ".." in cwd_path.parts or cwd_path.is_symlink():
            cwd_bad = True
    argv_traversal = any(
        tok == ".." or tok.startswith("../") or tok.endswith("/..") or "/../" in tok
        for tok in argv
    )
    exe_trusted = _is_trusted_executable_token(argv[0])
    has_path_traversal_or_symlink = int(cwd_bad or argv_traversal or not exe_trusted)
    has_metachar = any(
        not tok
        or "\x00" in tok
        or "\n" in tok
        or "\r" in tok
        or ";" in tok
        or "|" in tok
        or "&" in tok
        or "`" in tok
        or "$(" in tok
        or (scope != "root_exec" and (">" in tok or "<" in tok))
        for tok in argv
    )
    if not exe_trusted:
        packed = orb_privd_command_step(
            1,
            scope_rank,
            5,
            0,
            int(has_metachar),
            1,
            has_unsafe_env,
            int(require_force_cmd),
        )
        assert (packed & 256) == 0 and (packed & 1536) == 1536
        raise ValueError(f"Untrusted executable path '{argv[0]}' rejected by orb_privd_command_step confinement gate")
    prog = Path(argv[0]).name
    if scope == "ops_read":
        if prog not in OPS_READ_BINARIES:
            raise ValueError(f"ops_read grant does not allow binary '{prog}'")
        if prog == "systemctl" and (len(argv) < 2 or argv[1] not in {"status", "show", "list-units", "is-active", "is-failed"}):
            raise ValueError("ops_read grant only allows read-only systemctl subcommands")
        if prog == "docker" and (len(argv) < 2 or argv[1] not in {"ps", "logs", "inspect", "stats", "info", "version"}):
            raise ValueError("ops_read grant only allows read-only docker subcommands")
        if prog == "nft" and argv[1:] != ["list", "ruleset"]:
            raise ValueError("ops_read grant only allows 'nft list ruleset'")
        if prog == "mdadm" and argv[1:2] not in (["--detail"], ["-D"], ["--examine"], ["-E"], ["--query"], ["-Q"]):
            raise ValueError("ops_read grant only allows 'mdadm --detail/--examine/--query'")
        if prog in READ_ONLY_OPTIONS and not all(_read_only_arg(prog, a) for a in argv[1:]):
            raise ValueError(f"ops_read grant only allows read-only {prog} options")
        command_class = 1
        unit_matches = 1
    elif scope == "service_deploy":
        if prog == "systemctl":
            if len(argv) < 2 or argv[1] not in {"restart", "reload", "status", "start", "stop", "daemon-reload"}:
                raise ValueError("service_deploy grant only allows systemctl service lifecycle subcommands")
            if any(arg.startswith("-") for arg in argv[1:]):
                raise ValueError("service_deploy grant does not allow systemctl option flags")
            if argv[1] == "daemon-reload":
                if len(argv) != 2:
                    raise ValueError("systemctl daemon-reload does not take target unit arguments")
                command_class = 3
                unit_matches = 1
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
                command_class = 2
                unit_matches = 1
        elif prog == "nginx":
            if argv[1:] not in (["-t"], ["-s", "reload"]):
                raise ValueError("service_deploy grant only allows 'nginx -t' or 'nginx -s reload'")
            command_class = 3
            unit_matches = 1
        else:
            raise ValueError(f"service_deploy grant does not allow arbitrary binary '{prog}'; request root_exec if needed")
    else:
        command_class = 4
        unit_matches = 1

    packed = orb_privd_command_step(
        1,
        scope_rank,
        command_class,
        unit_matches,
        int(has_metachar),
        has_path_traversal_or_symlink,
        has_unsafe_env,
        int(require_force_cmd),
    )
    lo32 = packed & 0xFFFFFFFF
    if (lo32 & 256) == 0 or (lo32 & 1536) != 1536:
        raise ValueError("Rejected by orb_privd_command_step confinement gate")
    return packed


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
    # This daemon only runs commands on its own machine; the caller's
    # target_host is not trusted to send them anywhere else.
    if target_host.strip().lower() not in ("self", "local", "localhost", HOST_LABEL.strip().lower()):
        return {
            "ok": False,
            "exit_code": 2,
            "stderr": f"orb-sudo runs only on this machine ({HOST_LABEL}); for {target_host} use the execute_privileged_command tool",
        }

    command_str = " ".join(argv)
    # 1. Pre-execution admission check via Core's pinned `orb_privilege_step` endpoint
    verdict = call_core_verify(
        {
            "mission_id": mission_id,
            "lease_token": lease_token,
            "target_host": target_host,
            "executing_host": HOST_LABEL,
            "command": f"[pre-exec] {command_str}",
            "argv": argv,
            "cwd": cwd,
        }
    )
    if not verdict.get("allow_exec"):
        return {"ok": False, "exit_code": 126, "stderr": "Lease denied by Core"}

    scope = str(verdict.get("scope", "root_exec"))
    allowed_unit = verdict.get("allowed_unit")
    check_scope_restrictions(
        scope,
        allowed_unit,
        argv,
        cwd=cwd,
        env=req.get("env") if isinstance(req.get("env"), dict) else None,
        require_force_cmd=bool(verdict.get("require_force_cmd")),
    )

    # 2. Execute command in clean root environment using resolved trusted executable path
    resolved_exe = (
        argv[0]
        if Path(argv[0]).is_absolute()
        else (shutil.which(Path(argv[0]).name, path=TRUSTED_EXEC_PATH) or argv[0])
    )
    exec_argv = [resolved_exe, *argv[1:]]
    t0 = time.monotonic()
    proc = subprocess.run(
        exec_argv,
        cwd=cwd if Path(cwd).is_dir() else "/root",
        capture_output=True,
        timeout=int(req.get("timeout_secs", 600)),
        env={
            "PATH": TRUSTED_EXEC_PATH,
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
            "executing_host": HOST_LABEL,
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
        candidates = (
            (SOCKET_GROUP, "sandboxed-node", "orb-node")
            if SOCKET_GROUP
            else ("sandboxed-node", "orb-node")
        )
        for group_name in candidates:
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
