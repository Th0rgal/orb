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
    "ss",
    "ps",
    "df",
    "free",
    "uptime",
    "uname",
    "cat",
    "head",
    "tail",
    "stat",
    "lsblk",
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
    "ORB_NODE_TOKEN",
    "SANDBOXED_NODE_TOKEN",
    "SANDBOXED_SH_TOKEN",
    "ORB_API_TOKEN",
}

RESERVED_UNIX_USERNAMES = {
    "root",
    "daemon",
    "nobody",
    "ubuntu",
    "debian",
    "admin",
    "orb-core",
    "orb-node",
    "sandboxed-node",
    "postgres",
    "systemd-network",
    "systemd-resolve",
    "sshd",
}

PRIVILEGED_UNIX_GROUPS = {
    "root",
    "sudo",
    "wheel",
    "docker",
    "adm",
    "shadow",
    "sandboxed-node",
    "orb-node",
}


TRUSTED_EXEC_DIRS = ("/bin", "/usr/bin", "/sbin", "/usr/sbin")
TRUSTED_RESOLVED_EXEC_PREFIXES = ("/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/", "/usr/lib/", "/lib/")
TRUSTED_EXEC_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"
PUBLIC_DIAGNOSTIC_PATHS = {
    "/proc/cpuinfo",
    "/proc/meminfo",
    "/proc/loadavg",
    "/proc/uptime",
    "/proc/version",
    "/proc/stat",
    "/proc/diskstats",
    "/proc/mdstat",
    "/etc/os-release",
    "/usr/lib/os-release",
}


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
                if hasattr(lib, "orb_privd_user_exec_step"):
                    ufn = lib.orb_privd_user_exec_step
                    ufn.argtypes = [
                        ctypes.c_uint8,
                        ctypes.c_uint8,
                        ctypes.c_uint8,
                        ctypes.c_uint8,
                        ctypes.c_uint8,
                        ctypes.c_uint32,
                        ctypes.c_uint32,
                        ctypes.c_uint8,
                        ctypes.c_uint8,
                        ctypes.c_uint8,
                    ]
                    ufn.restype = ctypes.c_uint32
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


def valid_unix_username(raw: str) -> bool:
    if not raw or len(raw) > 31 or raw in RESERVED_UNIX_USERNAMES:
        return False
    return re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", raw) is not None


def orb_privd_user_exec_step(
    peer_is_node_uid: int,
    lease_verified: int,
    node_admin_only: int,
    caller_role: int,
    username_valid: int,
    target_uid: int,
    target_gid: int,
    gid_disjoint_priv: int,
    home_confined_no_symlink: int,
    elan_root_owned: int,
) -> int:
    """Invoke Lean 4 `Orb.Kernel.privdUserExecStep` (`orb_privd_user_exec_step`) via `liborb_kernel.so` and verified mirror."""
    u8_peer = peer_is_node_uid & 0xFF
    u8_lease = lease_verified & 0xFF
    u8_admin_only = node_admin_only & 0xFF
    u8_role = caller_role & 0xFF
    u8_uvalid = username_valid & 0xFF
    u32_uid = target_uid & 0xFFFFFFFF
    u32_gid = target_gid & 0xFFFFFFFF
    u8_disjoint = gid_disjoint_priv & 0xFF
    u8_home = home_confined_no_symlink & 0xFF
    u8_elan = elan_root_owned & 0xFF
    if u8_peer != 1:
        mirror = 1 << 8
    elif u8_lease != 1:
        mirror = 2 << 8
    elif u8_role > 1:
        mirror = 3 << 8
    elif u8_role == 0 and u8_admin_only != 0:
        mirror = 4 << 8
    elif u8_uvalid != 1:
        mirror = 5 << 8
    elif not (2000 <= u32_uid < 65534 and 2000 <= u32_gid < 65534):
        mirror = 6 << 8
    elif u8_disjoint != 1:
        mirror = 7 << 8
    elif u8_home != 1:
        mirror = 8 << 8
    elif u8_elan != 1:
        mirror = 9 << 8
    else:
        mirror = 1
    if _ORB_KERNEL_SO is not None and hasattr(_ORB_KERNEL_SO, "orb_privd_user_exec_step"):
        native = int(
            _ORB_KERNEL_SO.orb_privd_user_exec_step(
                u8_peer,
                u8_lease,
                u8_admin_only,
                u8_role,
                u8_uvalid,
                u32_uid,
                u32_gid,
                u8_disjoint,
                u8_home,
                u8_elan,
            )
        )
        if native != mirror:
            raise RuntimeError(f"orb_privd_user_exec_step divergence: native={native:#x} mirror={mirror:#x}")
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
            canon_str = str(exe_path.resolve(strict=True))
        except OSError:
            return False
        if not canon_str.startswith(TRUSTED_RESOLVED_EXEC_PREFIXES):
            return False
    return True


def _is_canonical_absolute_path_str(raw: str) -> bool:
    return (
        bool(raw)
        and raw.startswith("/")
        and raw == str(Path(raw))
        and "\\" not in raw
        and not any(part in {".", ".."} for part in raw.split("/"))
    )


def ops_read_command_allowed(prog: str, args: list[str]) -> bool:
    if prog in {"cat", "head", "tail", "stat"}:
        return len(args) == 1 and args[0] in PUBLIC_DIAGNOSTIC_PATHS
    forms = {
        "free": [[], ["-h"], ["-m"]],
        "df": [[], ["-h"], ["-hT"]],
        "uptime": [[]],
        "uname": [[], ["-a"], ["-r"]],
        "lsblk": [[]],
        "ps": [["-eo", "pid,ppid,uid,comm"]],
        "ss": [["-lntu"], ["-s"]],
        "journalctl": [["--disk-usage"]],
    }
    if prog == "systemctl":
        return (len(args) == 2 and args[0] in {"is-active", "is-failed"}
                and not args[1].startswith("-")
                and re.fullmatch(r"[A-Za-z0-9_.@:-]+", args[1]) is not None)
    return args in forms.get(prog, [])


def confined_existing_path(
    raw: str,
    *,
    directory: bool = False,
    allow_symlink_leaf: bool = False,
    trusted_uid: int = 0,
) -> Path:
    import stat
    if not _is_canonical_absolute_path_str(raw):
        raise ValueError("Ambiguous diagnostic path")
    path = Path(raw)
    parents = list(reversed(path.parents))
    for component in parents:
        metadata = component.lstat()
        if (
            stat.S_ISLNK(metadata.st_mode)
            or (metadata.st_uid not in {0, trusted_uid})
            or (metadata.st_mode & 0o002 and not (metadata.st_mode & stat.S_ISVTX))
        ):
            raise ValueError("Untrusted diagnostic path component")
    leaf = path.lstat()
    if leaf.st_uid not in {0, trusted_uid}:
        raise ValueError("Untrusted diagnostic path owner")
    if stat.S_ISLNK(leaf.st_mode):
        if not allow_symlink_leaf or directory:
            raise ValueError("Symlink diagnostic path rejected")
        resolved = path.resolve(strict=True)
        return confined_existing_path(
            str(resolved),
            directory=False,
            allow_symlink_leaf=False,
            trusted_uid=trusted_uid,
        )
    if leaf.st_mode & 0o002:
        raise ValueError("Writable diagnostic path rejected")
    if path.resolve(strict=True) != path:
        raise ValueError("Noncanonical diagnostic path")
    if directory and not path.is_dir():
        raise ValueError("Diagnostic cwd is not a directory")
    if not directory and not path.is_file():
        raise ValueError("Diagnostic path is not a regular file")
    return path


def _resolve_trusted_ops_read_executable(raw_exe: str, prog: str, *, trusted_uid: int = 0) -> Path:
    import stat

    candidates = (
        [Path(raw_exe)]
        if Path(raw_exe).is_absolute()
        else [Path(d) / prog for d in TRUSTED_EXEC_PATH.split(":")]
    )
    if Path(raw_exe).is_absolute() and not _is_canonical_absolute_path_str(raw_exe):
        raise ValueError("Ambiguous diagnostic executable path")
    for candidate in candidates:
        if str(candidate.parent) not in TRUSTED_EXEC_DIRS or candidate.name != prog:
            continue
        try:
            parent_meta = candidate.parent.lstat()
            cand_meta = candidate.lstat()
        except OSError:
            continue
        if (
            (parent_meta.st_uid not in {0, trusted_uid})
            or (parent_meta.st_mode & 0o002)
            or (cand_meta.st_uid not in {0, trusted_uid})
            or (not stat.S_ISLNK(cand_meta.st_mode) and (cand_meta.st_mode & 0o002))
        ):
            continue
        try:
            resolved_exe = candidate.resolve(strict=True)
        except OSError:
            continue
        if not str(resolved_exe).startswith(TRUSTED_RESOLVED_EXEC_PREFIXES):
            continue
        try:
            confined_existing_path(str(resolved_exe), trusted_uid=trusted_uid)
        except ValueError:
            continue
        return candidate
    raise ValueError("Untrusted resolved diagnostic executable")


def prepare_ops_read(
    argv: list[str],
    cwd: str | None,
    *,
    allowed_paths: set[str] | None = None,
    trusted_uid: int = 0,
) -> tuple[list[str], str]:
    if not argv or not _is_trusted_executable_token(argv[0]):
        raise ValueError("Untrusted diagnostic executable")
    prog = Path(argv[0]).name
    public_paths = PUBLIC_DIAGNOSTIC_PATHS if allowed_paths is None else allowed_paths
    if prog in {"cat", "head", "tail", "stat"}:
        if len(argv) != 2 or argv[1] not in public_paths:
            raise ValueError("Diagnostic command is not allowlisted")
    elif not ops_read_command_allowed(prog, argv[1:]):
        raise ValueError("Diagnostic command is not allowlisted")
    executable = _resolve_trusted_ops_read_executable(argv[0], prog, trusted_uid=trusted_uid)
    raw_cwd = (cwd or "/").strip() or "/"
    execution_cwd = str(confined_existing_path(raw_cwd, directory=True, trusted_uid=trusted_uid))
    exec_args = list(argv[1:])
    if prog in {"cat", "head", "tail", "stat"}:
        target = confined_existing_path(
            argv[1],
            allow_symlink_leaf=argv[1] in {"/etc/os-release", "/usr/lib/os-release"},
            trusted_uid=trusted_uid,
        )
        if str(target) not in public_paths:
            raise ValueError("Resolved diagnostic file outside public allowlist")
        exec_args = [str(target)]
    return [str(executable), *exec_args], execution_cwd


def execute_ops_read(argv: list[str], cwd: str | None) -> int:
    exec_argv, execution_cwd = prepare_ops_read(argv, cwd)
    return subprocess.run(exec_argv, cwd=execution_cwd, env={
        "PATH": TRUSTED_EXEC_PATH, "HOME": "/", "LANG": "C.UTF-8",
        "SYSTEMD_PAGER": "cat", "SYSTEMD_PAGERSECURE": "1",
    }, timeout=120).returncode


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
        raw_cwd = str(cwd).strip()
        cwd_path = Path(raw_cwd)
        if not cwd_path.is_absolute() or ".." in cwd_path.parts or cwd_path.is_symlink():
            cwd_bad = True
        elif scope in ("ops_read", "service_deploy"):
            if not _is_canonical_absolute_path_str(raw_cwd):
                cwd_bad = True
            elif cwd_path.exists() or any(p.is_symlink() for p in cwd_path.parents):
                if any(p.is_symlink() for p in cwd_path.parents):
                    cwd_bad = True
    argv_traversal = any(
        tok == ".."
        or tok.startswith("../")
        or tok.endswith("/..")
        or "/../" in tok
        or (
            scope == "ops_read"
            and tok.startswith("/")
            and not _is_canonical_absolute_path_str(tok)
        )
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
    flag_bypass = False
    if scope == "ops_read":
        if not ops_read_command_allowed(prog, argv[1:]):
            flag_bypass = prog in OPS_READ_BINARIES
            packed = orb_privd_command_step(
                1,
                scope_rank,
                4,
                1,
                int(has_metachar or flag_bypass),
                has_path_traversal_or_symlink,
                has_unsafe_env,
                int(require_force_cmd),
            )
            assert (packed & 256) == 0 and (packed & 1536) == 1536
            raise ValueError("ops_read diagnostic command is not allowlisted")
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
    raw_name = str(req.get("name", ""))
    name = "vibe" if raw_name == "vibe-acp" else raw_name
    version = str(req.get("version", ""))
    if name not in {"claude", "codex", "opencode", "grok", "vibe"} or not re.fullmatch(r"\d+\.\d+\.\d+", version):
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
    raw_cwd_opt = req.get("cwd")
    cwd = str(raw_cwd_opt).strip() if raw_cwd_opt is not None and str(raw_cwd_opt).strip() else None
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
            "cwd": cwd or "/",
        }
    )
    if not verdict.get("allow_exec"):
        return {"ok": False, "exit_code": 126, "stderr": "Lease denied by Core"}

    scope = str(verdict.get("scope", "root_exec"))
    allowed_unit = verdict.get("allowed_unit")
    effective_cwd = cwd or ("/" if scope == "ops_read" else "/root")
    check_scope_restrictions(
        scope,
        allowed_unit,
        argv,
        cwd=effective_cwd,
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
    execution_cwd = effective_cwd if Path(effective_cwd).is_dir() else "/root"
    exec_env = {
        "PATH": TRUSTED_EXEC_PATH,
        "HOME": "/root",
        "LANG": "C.UTF-8",
        "ORB_MISSION_ID": mission_id,
        "ORB_JIT_GRANT_ID": str(verdict.get("grant_id", "")),
    }
    if scope == "ops_read":
        exec_argv, execution_cwd = prepare_ops_read(argv, effective_cwd)
        exec_env = {
            "PATH": TRUSTED_EXEC_PATH,
            "HOME": "/",
            "LANG": "C.UTF-8",
            "SYSTEMD_PAGER": "cat",
            "SYSTEMD_PAGERSECURE": "1",
        }
    raw_timeout = int(req.get("timeout_secs", 600))
    bounded_timeout = max(1, min(raw_timeout, 600))
    t0 = time.monotonic()
    proc = subprocess.run(
        exec_argv,
        cwd=execution_cwd,
        capture_output=True,
        timeout=bounded_timeout,
        env=exec_env,
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
                "cwd": effective_cwd,
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


def _peer_is_node_uid(peer_uid: int) -> bool:
    allow_nonroot = os.environ.get("ORB_PRIVD_ALLOW_NONROOT_TEST") == "1"
    if peer_uid == 0 or (allow_nonroot and peer_uid == os.geteuid()):
        return True
    try:
        import pwd
        for candidate in ("sandboxed-node", "orb-node"):
            try:
                if pwd.getpwnam(candidate).pw_uid == peer_uid:
                    return True
            except KeyError:
                continue
    except Exception:
        pass
    return False


def _lookup_or_create_unix_user(u_name: str, home_root: str, create_if_missing: bool) -> tuple[int, int, bool]:
    allow_nonroot = os.environ.get("ORB_PRIVD_ALLOW_NONROOT_TEST") == "1"
    if allow_nonroot and os.geteuid() != 0:
        return 2500, 2500, True
    import grp
    import pwd

    try:
        pw = pwd.getpwnam(u_name)
    except KeyError:
        if not create_if_missing:
            raise ValueError(f"Unix user '{u_name}' is not provisioned")
        subprocess.run(
            ["/usr/sbin/groupadd", "-K", "GID_MIN=2000", "-K", "GID_MAX=60000", u_name],
            capture_output=True,
        )
        add_proc = subprocess.run(
            [
                "/usr/sbin/useradd",
                "--create-home",
                "--home-dir",
                f"{home_root}/{u_name}",
                "--shell",
                "/bin/bash",
                "-g",
                u_name,
                "-G",
                "",
                "-K",
                "UID_MIN=2000",
                "-K",
                "UID_MAX=60000",
                u_name,
            ],
            capture_output=True,
            text=True,
        )
        if add_proc.returncode != 0:
            raise RuntimeError(f"useradd failed for {u_name}: {add_proc.stderr.strip()}")
        pw = pwd.getpwnam(u_name)

    if pw.pw_dir != f"{home_root}/{u_name}":
        raise ValueError(f"Existing unix user {u_name} home '{pw.pw_dir}' != '{home_root}/{u_name}'")
    user_groups = {
        g.gr_name.lower()
        for g in grp.getgrall()
        if g.gr_gid == pw.pw_gid or u_name in g.gr_mem
    }
    disjoint = user_groups.isdisjoint(PRIVILEGED_UNIX_GROUPS)
    return pw.pw_uid, pw.pw_gid, disjoint


def _scrub_user_job_env(raw_env: dict | list | None, home_dir: str) -> dict[str, str]:
    out: dict[str, str] = {}
    items = raw_env.items() if isinstance(raw_env, dict) else (raw_env or [])
    for k_raw, v_raw in items:
        k = str(k_raw).strip()
        v = str(v_raw)
        ku = k.upper()
        if (
            re.fullmatch(r"[A-Za-z0-9_]+", k)
            and ku not in UNSAFE_ENV_KEYS
            and not ku.startswith("LD_")
            and not ku.startswith("DYLD_")
            and "\x00" not in v
        ):
            out[k] = v
    out["HOME"] = home_dir
    out["ELAN_HOME"] = f"{home_dir}/.elan"
    out["PATH"] = f"{home_dir}/.elan/bin:/opt/orb-tools/bin:/opt/sandboxed-tools/bin:/usr/local/bin:/usr/bin:/bin"
    return out


def handle_ensure_mission_user(req: dict, peer_uid: int) -> dict:
    import stat

    peer_ok = int(_peer_is_node_uid(peer_uid))
    u_name = str(req.get("unix_username") or "").strip()
    mission_id = str(req.get("mission_id") or "").strip()
    caller_role = 1 if str(req.get("caller_role") or "member").strip() == "admin" else 0
    node_admin_only = int(bool(req.get("node_admin_only", False)))
    lease_verified = int(bool(req.get("lease_verified", True)))
    if not mission_id or len(mission_id) > 128 or not re.fullmatch(r"[A-Za-z0-9_-]+", mission_id):
        return {"ok": False, "exit_code": 2, "stderr": "Invalid mission_id"}
    u_valid = int(valid_unix_username(u_name))
    if not u_valid:
        orb_privd_user_exec_step(peer_ok, lease_verified, node_admin_only, caller_role, 0, 0, 0, 0, 0, 0)
        return {"ok": False, "exit_code": 2, "stderr": f"Invalid or reserved unix_username '{u_name}'"}
    allow_nonroot = os.environ.get("ORB_PRIVD_ALLOW_NONROOT_TEST") == "1"
    nonroot = allow_nonroot and os.geteuid() != 0
    home_root = (os.environ.get("ORB_PRIVD_HOME_ROOT") or "/home").rstrip("/")
    if nonroot:
        os.makedirs(home_root, exist_ok=True)
    target_uid, target_gid, disjoint = _lookup_or_create_unix_user(u_name, home_root, create_if_missing=True)
    home_dir = f"{home_root}/{u_name}"
    home_no_sym = False
    if os.path.lexists(home_root):
        st_r = os.lstat(home_root)
        if stat.S_ISDIR(st_r.st_mode) and not stat.S_ISLNK(st_r.st_mode):
            if not os.path.lexists(home_dir):
                home_no_sym = True
            else:
                st_h = os.lstat(home_dir)
                home_no_sym = stat.S_ISDIR(st_h.st_mode) and not stat.S_ISLNK(st_h.st_mode)
    shared_elan = os.environ.get("ORB_PRIVD_SHARED_ELAN") or "/opt/orb/elan"
    elan_ok = True
    if os.path.lexists(shared_elan):
        st_e = os.lstat(shared_elan)
        elan_ok = (
            stat.S_ISDIR(st_e.st_mode)
            and not stat.S_ISLNK(st_e.st_mode)
            and (nonroot or (st_e.st_uid == 0 and st_e.st_gid == 0))
        )
    gate = orb_privd_user_exec_step(
        peer_ok,
        lease_verified,
        node_admin_only,
        caller_role,
        u_valid,
        target_uid,
        target_gid,
        int(disjoint),
        int(home_no_sym),
        int(elan_ok),
    )
    if (gate & 1) != 1:
        return {"ok": False, "exit_code": 126, "stderr": f"Rejected by orb_privd_user_exec_step (gate={gate})"}
    if not os.path.lexists(home_dir):
        os.mkdir(home_dir, 0o700)
    if not nonroot:
        os.chown(home_dir, target_uid, target_gid)
    os.chmod(home_dir, 0o700)
    helper = (
        "import json, os, shutil, stat, sys\n"
        "req = json.loads(sys.stdin.read())\n"
        "if not req['nonroot']:\n"
        "  os.setgroups([req['gid']]); os.setgid(req['gid']); os.setuid(req['uid'])\n"
        "os.umask(0o077)\n"
        "hd = req['home_dir']; se = req['shared_elan']\n"
        "if os.path.isdir(se) and not os.path.islink(se):\n"
        "  de = os.path.join(hd, '.elan')\n"
        "  for s in ['', 'bin', 'toolchains']:\n"
        "    p = os.path.join(de, s) if s else de\n"
        "    if not os.path.lexists(p): os.mkdir(p, 0o700)\n"
        "  bs = os.path.join(se, 'bin')\n"
        "  if os.path.isdir(bs):\n"
        "    for fn in os.listdir(bs):\n"
        "      sp = os.path.join(bs, fn); dp = os.path.join(de, 'bin', fn)\n"
        "      if os.path.isfile(sp) and not os.path.islink(dp): shutil.copy2(sp, dp); os.chmod(dp, 0o755)\n"
        "  ts = os.path.join(se, 'toolchains')\n"
        "  if os.path.isdir(ts):\n"
        "    for fn in os.listdir(ts):\n"
        "      sp = os.path.join(ts, fn); dp = os.path.join(de, 'toolchains', fn)\n"
        "      if os.path.isdir(sp) and not os.path.lexists(dp): os.symlink(sp, dp)\n"
        "  st = os.path.join(se, 'settings.toml'); dt = os.path.join(de, 'settings.toml')\n"
        "  if os.path.isfile(st) and not os.path.lexists(dt): shutil.copy2(st, dt); os.chmod(dt, 0o600)\n"
        "mr = os.path.join(hd, '.orb-missions')\n"
        "if not os.path.lexists(mr): os.mkdir(mr, 0o700)\n"
        "mc = os.path.join(mr, req['mission_id'])\n"
        "if not os.path.lexists(mc): os.mkdir(mc, 0o700)\n"
        "os.chmod(mc, 0o700)\n"
        "for item in req.get('files', []):\n"
        "  segs = [s for s in str(item.get('path', '')).strip('/').split('/') if s and s != '.']\n"
        "  if not segs or '..' in segs: raise RuntimeError('unsafe workspace_file path')\n"
        "  cur = mc\n"
        "  for s in segs[:-1]:\n"
        "    cur = os.path.join(cur, s)\n"
        "    if not os.path.lexists(cur): os.mkdir(cur, 0o700)\n"
        "  leaf = os.path.join(cur, segs[-1])\n"
        "  fd = os.open(leaf, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW, 0o600)\n"
        "  os.write(fd, str(item.get('content', '')).encode('utf-8')); os.close(fd)\n"
    )
    proc = subprocess.run(
        [sys.executable, "-c", helper],
        input=json.dumps(
            {
                "nonroot": nonroot,
                "uid": target_uid,
                "gid": target_gid,
                "home_dir": home_dir,
                "shared_elan": shared_elan,
                "mission_id": mission_id,
                "files": req.get("workspace_files") or [],
            }
        ),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {"ok": False, "exit_code": 126, "stderr": proc.stderr.strip()}
    return {
        "ok": True,
        "uid": target_uid,
        "gid": target_gid,
        "home_dir": home_dir,
        "mission_cwd": f"{home_dir}/.orb-missions/{mission_id}",
    }


_SYSTEMD_EXPAND_ENV_CACHE: bool | None = None


def _systemd_supports_expand_environment(systemd_run: str = "/usr/bin/systemd-run") -> bool:
    global _SYSTEMD_EXPAND_ENV_CACHE
    if _SYSTEMD_EXPAND_ENV_CACHE is not None:
        return _SYSTEMD_EXPAND_ENV_CACHE
    try:
        res = subprocess.run([systemd_run, "--help"], capture_output=True, text=True, timeout=5)
        supported = "--expand-environment" in ((res.stdout or "") + (res.stderr or ""))
    except OSError:
        supported = False
    _SYSTEMD_EXPAND_ENV_CACHE = supported
    return supported


def handle_spawn_user_job(req: dict, peer_uid: int, peer_gid: int) -> dict:
    import stat

    peer_ok = int(_peer_is_node_uid(peer_uid))
    if not peer_ok:
        return {"ok": False, "exit_code": 126, "stderr": "Unauthorized peer UID"}
    u_name = str(req.get("unix_username") or "").strip()
    job_id = str(req.get("job_id") or "").strip()
    mission_id = str(req.get("mission_id") or "").strip()
    log_path = str(req.get("log_path") or "").strip()
    argv = [str(x) for x in (req.get("argv") or [])]
    if (
        not valid_unix_username(u_name)
        or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", job_id)
        or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", mission_id)
        or not log_path
        or not argv
    ):
        return {"ok": False, "exit_code": 2, "stderr": "Invalid spawn_user_job parameters"}
    allow_nonroot = os.environ.get("ORB_PRIVD_ALLOW_NONROOT_TEST") == "1"
    nonroot = allow_nonroot and os.geteuid() != 0
    home_root = (os.environ.get("ORB_PRIVD_HOME_ROOT") or "/home").rstrip("/")
    target_uid, target_gid, disjoint = _lookup_or_create_unix_user(u_name, home_root, create_if_missing=False)
    home_dir = f"{home_root}/{u_name}"
    mission_cwd = f"{home_dir}/.orb-missions/{mission_id}"
    home_ok = all(
        os.path.lexists(p) and stat.S_ISDIR(os.lstat(p).st_mode) and not stat.S_ISLNK(os.lstat(p).st_mode)
        for p in (home_root, home_dir, mission_cwd)
    )
    caller_role = 1 if str(req.get("caller_role") or "member").strip() == "admin" else 0
    node_admin_only = int(bool(req.get("node_admin_only", False)))
    gate = orb_privd_user_exec_step(
        peer_ok, 1, node_admin_only, caller_role, 1, target_uid, target_gid, int(disjoint), int(home_ok), 1
    )
    if (gate & 1) != 1:
        return {"ok": False, "exit_code": 126, "stderr": f"Rejected by orb_privd_user_exec_step (gate={gate})"}
    clean_env = _scrub_user_job_env(req.get("env"), home_dir)
    unit = "orb-job-" + "".join(c for c in job_id if c.isalnum())
    state_dir = (os.environ.get("ORB_PRIVD_STATE_DIR") or "/run/orb-privd-jobs").rstrip("/")
    os.makedirs(state_dir, exist_ok=True)
    meta_path = f"{state_dir}/{unit}.json"
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    lfd = os.open(log_path, os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o640)
    if not nonroot:
        try:
            os.fchown(lfd, 0, peer_gid)
        except OSError:
            pass
    if nonroot:
        rc_path = f"{meta_path}.rc"
        runner = (
            "import os, subprocess, sys\n"
            "p = subprocess.run(sys.argv[2:], env=os.environ)\n"
            "open(sys.argv[1], 'w').write(str(p.returncode))\n"
            "sys.exit(p.returncode)\n"
        )
        proc = subprocess.Popen(
            [sys.executable, "-c", runner, rc_path, *argv],
            cwd=mission_cwd,
            env=clean_env,
            stdin=subprocess.DEVNULL,
            stdout=lfd,
            stderr=lfd,
            start_new_session=True,
        )
        child_pid = proc.pid
        proc.returncode = 0  # detached daemon child reaped via os.waitpid in handle_control_user_job
        os.close(lfd)
        Path(meta_path).write_text(
            json.dumps({"unix_username": u_name, "unit": unit, "pid": child_pid, "rc_path": rc_path, "mode": "nonroot"})
        )
        return {"ok": True, "unit": unit, "pid": child_pid}
    os.close(lfd)
    timeout_secs = max(1, int(req.get("timeout_secs") or 14400))
    supports_expand_env = _systemd_supports_expand_environment()
    cmd = ["/usr/bin/systemd-run", "--system"]
    if supports_expand_env:
        cmd.append("--expand-environment=no")
    cmd.extend([
        "--quiet",
        "--collect",
        f"--unit={unit}",
        f"--uid={target_uid}",
        f"--gid={target_gid}",
        f"--working-directory={mission_cwd}",
        "--property=RemainAfterExit=yes",
        "--property=Slice=missions.slice",
        "--property=KillMode=control-group",
        "--property=NoNewPrivileges=yes",
        "--property=SupplementaryGroups=",
        "--property=PrivateTmp=yes",
        "--property=ProtectSystem=strict",
        f"--property=ReadWritePaths={home_dir}",
        f"--property=StandardOutput=file:{log_path}",
        f"--property=StandardError=file:{log_path}",
        f"--property=RuntimeMaxSec={timeout_secs}",
    ])
    if req.get("mem_max"):
        cmd.append(f"--property=MemoryMax={int(req['mem_max'])}")
    if req.get("mem_high"):
        cmd.append(f"--property=MemoryHigh={int(req['mem_high'])}")
    if req.get("cpu_weight"):
        cmd.append(f"--property=CPUWeight={int(req['cpu_weight'])}")
    if req.get("cpu_quota"):
        cmd.append(f"--property=CPUQuota={req['cpu_quota']}")
    for k, v in clean_env.items():
        cmd.append(f"--setenv={k}={v}")
    cmd.append("--")
    cmd.extend(argv if supports_expand_env else [arg.replace("$", "$$") for arg in argv])
    run_proc = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    if run_proc.returncode != 0:
        return {"ok": False, "exit_code": 126, "stderr": run_proc.stderr.strip() or run_proc.stdout.strip()}
    sh = subprocess.run(
        ["/usr/bin/systemctl", "show", "--property=MainPID", "--value", unit],
        capture_output=True,
        text=True,
    )
    mpid = int(sh.stdout.strip() or "0") if sh.returncode == 0 and sh.stdout.strip().isdigit() else 0
    Path(meta_path).write_text(json.dumps({"unix_username": u_name, "unit": unit, "pid": mpid, "mode": "systemd"}))
    return {"ok": True, "unit": unit, "pid": mpid}


def handle_control_user_job(req: dict, peer_uid: int) -> dict:
    import signal

    if not _peer_is_node_uid(peer_uid):
        return {"ok": False, "exit_code": 126, "stderr": "Unauthorized peer UID"}
    op = str(req.get("op") or "status").strip()
    job_id = str(req.get("job_id") or "").strip()
    u_name = str(req.get("unix_username") or "").strip()
    if not valid_unix_username(u_name) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", job_id):
        return {"ok": False, "exit_code": 2, "stderr": "Invalid unix_username or job_id"}
    unit = "orb-job-" + "".join(c for c in job_id if c.isalnum())
    state_dir = (os.environ.get("ORB_PRIVD_STATE_DIR") or "/run/orb-privd-jobs").rstrip("/")
    meta_path = Path(f"{state_dir}/{unit}.json")
    if not meta_path.is_file():
        return {"ok": True, "done": True, "exit_code": -1, "state": "not-found"}
    meta = json.loads(meta_path.read_text())
    if meta.get("unix_username") != u_name:
        return {"ok": False, "exit_code": 126, "stderr": "job belongs to a different unix_username"}
    if meta.get("mode") == "nonroot":
        pid = int(meta.get("pid") or 0)
        rc_path = Path(meta.get("rc_path") or "")
        if op in ("stop", "kill"):
            if pid > 1:
                try:
                    os.killpg(pid, signal.SIGKILL if op == "kill" else signal.SIGTERM)
                except OSError:
                    pass
                try:
                    os.waitpid(pid, os.WNOHANG)
                except OSError:
                    pass
            meta_path.unlink(missing_ok=True)
            return {"ok": True, "done": True, "exit_code": 137, "state": "stopped"}
        if rc_path.is_file():
            if pid > 1:
                try:
                    os.waitpid(pid, os.WNOHANG)
                except OSError:
                    pass
            rc = int((rc_path.read_text().strip() or "0"))
            meta_path.unlink(missing_ok=True)
            rc_path.unlink(missing_ok=True)
            return {"ok": True, "done": True, "exit_code": rc, "state": "exited"}
        alive = False
        if pid > 1:
            try:
                os.kill(pid, 0)
                alive = True
            except OSError:
                alive = False
        return {"ok": True, "done": not alive, "exit_code": 0 if alive else -1, "state": "running" if alive else "exited"}
    if op in ("stop", "kill"):
        subprocess.run(["/usr/bin/systemctl", "kill", "--kill-who=all", "--signal=SIGKILL", unit], capture_output=True)
        subprocess.run(["/usr/bin/systemctl", "stop", unit], capture_output=True)
        subprocess.run(["/usr/bin/systemctl", "reset-failed", unit], capture_output=True)
        meta_path.unlink(missing_ok=True)
        return {"ok": True, "done": True, "exit_code": 137, "state": "stopped"}
    sh = subprocess.run(
        ["/usr/bin/systemctl", "show", "--property=ActiveState,SubState,ExecMainStatus", unit],
        capture_output=True,
        text=True,
    )
    kv = dict(ln.split("=", 1) for ln in sh.stdout.splitlines() if "=" in ln)
    running = kv.get("ActiveState") in ("active", "activating") and kv.get("SubState") == "running"
    rc = int(kv.get("ExecMainStatus", "0") or "0")
    if not running:
        subprocess.run(["/usr/bin/systemctl", "stop", unit], capture_output=True)
        subprocess.run(["/usr/bin/systemctl", "reset-failed", unit], capture_output=True)
        meta_path.unlink(missing_ok=True)
    return {"ok": True, "done": not running, "exit_code": rc, "state": kv.get("SubState") or kv.get("ActiveState", "")}


def handle_user_fs_op(req: dict, peer_uid: int) -> dict:
    import stat

    peer_ok = int(_peer_is_node_uid(peer_uid))
    if not peer_ok:
        return {"ok": False, "exit_code": 126, "stderr": "Unauthorized peer UID"}
    u_name = str(req.get("unix_username") or "").strip()
    mission_id = str(req.get("mission_id") or "").strip()
    if not valid_unix_username(u_name) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", mission_id):
        return {"ok": False, "exit_code": 2, "stderr": "Invalid unix_username or mission_id"}
    allow_nonroot = os.environ.get("ORB_PRIVD_ALLOW_NONROOT_TEST") == "1"
    nonroot = allow_nonroot and os.geteuid() != 0
    home_root = (os.environ.get("ORB_PRIVD_HOME_ROOT") or "/home").rstrip("/")
    target_uid, target_gid, disjoint = _lookup_or_create_unix_user(u_name, home_root, create_if_missing=False)
    home_dir = f"{home_root}/{u_name}"
    mission_cwd = f"{home_dir}/.orb-missions/{mission_id}"
    home_ok = all(
        os.path.lexists(p) and stat.S_ISDIR(os.lstat(p).st_mode) and not stat.S_ISLNK(os.lstat(p).st_mode)
        for p in (home_root, home_dir, mission_cwd)
    )
    gate = orb_privd_user_exec_step(peer_ok, 1, 0, 0, 1, target_uid, target_gid, int(disjoint), int(home_ok), 1)
    if (gate & 1) != 1:
        return {"ok": False, "exit_code": 126, "stderr": f"Rejected by orb_privd_user_exec_step (gate={gate})"}
    fs_script = (
        "import base64, hashlib, json, os, stat, sys\n"
        "req = json.loads(sys.stdin.read())\n"
        "if not req['nonroot']:\n"
        "  os.setgroups([req['gid']]); os.setgid(req['gid']); os.setuid(req['uid'])\n"
        "os.umask(0o077)\n"
        "root = req['mission_cwd']\n"
        "DENIED = {'.env', '.ssh', '.aws', '.gnupg', '.git', 'credentials.json', '.credentials.json', 'auth.json', 'id_rsa', 'id_ed25519', '.git-credentials'}\n"
        "def bad_seg(s):\n"
        "  low = s.lower()\n"
        "  return low in DENIED or low.startswith('.env.') or low.endswith('.pem') or low.endswith('.key')\n"
        "def resolve_rel(raw, allow_missing=False):\n"
        "  r = str(raw or '').strip()\n"
        "  if r.startswith('/'):\n"
        "    rc = r.rstrip('/'); rt = root.rstrip('/')\n"
        "    if rc == rt: r = ''\n"
        "    elif rc.startswith(rt + '/'): r = rc[len(rt)+1:]\n"
        "    else: raise ValueError('File is outside this source')\n"
        "  if '\\\\' in r: raise ValueError('File is not available in this source')\n"
        "  segs = [s for s in r.split('/') if s and s != '.']\n"
        "  if any(s == '..' or bad_seg(s) for s in segs): raise ValueError('File is not available in this source')\n"
        "  cur = root\n"
        "  for i, s in enumerate(segs):\n"
        "    cur = os.path.join(cur, s)\n"
        "    if not os.path.lexists(cur):\n"
        "      if allow_missing and i == len(segs) - 1: return cur, segs\n"
        "      raise ValueError('File is unavailable')\n"
        "    if stat.S_ISLNK(os.lstat(cur).st_mode): raise ValueError('Symbolic links are not exposed')\n"
        "  return cur, segs\n"
        "sub = req['subop']\n"
        "if sub == 'file_browser':\n"
        "  fb = req.get('req_json') or {}; act = fb.get('action', '')\n"
        "  if act == 'roots': res = {'path': root}\n"
        "  elif act == 'list':\n"
        "    d, segs = resolve_rel(fb.get('path', ''))\n"
        "    items = []\n"
        "    for fn in sorted(os.listdir(d)):\n"
        "      if bad_seg(fn): continue\n"
        "      p = os.path.join(d, fn); st = os.lstat(p)\n"
        "      if stat.S_ISLNK(st.st_mode): continue\n"
        "      if stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode):\n"
        "        items.append({'name': fn, 'path': '/'.join(segs + [fn]), 'kind': 'dir' if stat.S_ISDIR(st.st_mode) else 'file', 'size': 0 if stat.S_ISDIR(st.st_mode) else st.st_size, 'modified': int(st.st_mtime)})\n"
        "    res = {'entries': items[:1000], 'truncated': len(items) > 1000}\n"
        "  elif act in ('read', 'download'):\n"
        "    fp, _ = resolve_rel(fb.get('path', ''))\n"
        "    off = max(0, int(fb.get('offset') or 0))\n"
        "    fd = os.open(fp, os.O_RDONLY | os.O_NOFOLLOW); st = os.fstat(fd)\n"
        "    os.lseek(fd, min(off, st.st_size), os.SEEK_SET); chunk = os.read(fd, 1048576); os.close(fd)\n"
        "    nxt = min(off, st.st_size) + len(chunk)\n"
        "    if act == 'download': res = {'bytes': list(chunk), 'next': nxt, 'size': st.st_size}\n"
        "    else:\n"
        "      nul = b'\\x00' in chunk\n"
        "      res = {'content': None if nul else chunk.decode('utf-8', errors='replace'), 'binary': nul, 'size': st.st_size, 'truncated': nxt < st.st_size, 'modified': int(st.st_mtime)}\n"
        "  else: raise ValueError('Unknown file operation')\n"
        "elif sub == 'collect_artifacts':\n"
        "  arts = []\n"
        "  for rel in (req.get('paths') or []):\n"
        "    try:\n"
        "      fp, segs = resolve_rel(rel); fd = os.open(fp, os.O_RDONLY | os.O_NOFOLLOW); st = os.fstat(fd)\n"
        "      if stat.S_ISREG(st.st_mode):\n"
        "        h = hashlib.sha256(); h.update(os.read(fd, st.st_size))\n"
        "        arts.append({'path': '/'.join(segs), 'sha256': h.hexdigest(), 'size_bytes': st.st_size})\n"
        "      os.close(fd)\n"
        "    except Exception: pass\n"
        "  res = {'artifacts': arts}\n"
        "elif sub == 'mkdir':\n"
        "  rel = str(req.get('rel_path') or '').strip('/')\n"
        "  segs = [s for s in rel.split('/') if s and s != '.']\n"
        "  if any(s == '..' or bad_seg(s) for s in segs): raise ValueError('Invalid path')\n"
        "  cur = root\n"
        "  for s in segs:\n"
        "    cur = os.path.join(cur, s)\n"
        "    if not os.path.lexists(cur): os.mkdir(cur, 0o700)\n"
        "    if stat.S_ISLNK(os.lstat(cur).st_mode): raise ValueError('Symlink rejected')\n"
        "  res = {'ok': True, 'path': cur}\n"
        "elif sub == 'write':\n"
        "  fp, _ = resolve_rel(req.get('rel_path', ''), allow_missing=True)\n"
        "  raw = base64.b64decode(req.get('content_b64') or '')\n"
        "  fd = os.open(fp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW, 0o600)\n"
        "  os.write(fd, raw); os.close(fd); res = {'ok': True, 'size': len(raw)}\n"
        "else: raise ValueError(f'Unknown subop: {sub}')\n"
        "print(json.dumps({'ok': True, 'result': res}))\n"
    )
    proc = subprocess.run(
        [sys.executable, "-c", fs_script],
        input=json.dumps(
            {
                "nonroot": nonroot,
                "uid": target_uid,
                "gid": target_gid,
                "mission_cwd": mission_cwd,
                "subop": req.get("subop", "file_browser"),
                "rel_path": req.get("rel_path"),
                "content_b64": req.get("content_b64"),
                "paths": req.get("paths"),
                "req_json": req.get("req_json"),
            }
        ),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {"ok": False, "exit_code": 2, "stderr": proc.stderr.strip()}
    return json.loads(proc.stdout)


def serve_conn(conn: socket.socket) -> None:
    try:
        conn.settimeout(10.0)
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
            lease_tok = str(req.get("lease_token", "")).strip()
            if uid != 0:
                if not lease_tok:
                    resp = {"ok": False, "exit_code": 126, "stderr": "update_harness requires root peer UID or an active Core lease_token"}
                else:
                    verdict = call_core_verify(
                        {
                            "mission_id": str(req.get("mission_id") or "system-harness-update").strip(),
                            "lease_token": lease_tok,
                            "target_host": "self",
                            "executing_host": HOST_LABEL,
                            "command": "[update_harness]",
                            "argv": ["orb-update-harness"],
                            "cwd": "/root",
                        }
                    )
                    if not verdict.get("allow_exec") or str(verdict.get("scope", "")) not in ("service_deploy", "root_exec", "host_admin"):
                        resp = {"ok": False, "exit_code": 126, "stderr": "Lease denied by Core (requires service_deploy or root_exec scope)"}
                    else:
                        resp = handle_update_harness(req)
            else:
                resp = handle_update_harness(req)
        elif action == "exec":
            resp = handle_exec(req)
        elif action == "ensure_mission_user":
            resp = handle_ensure_mission_user(req, uid)
        elif action == "spawn_user_job":
            resp = handle_spawn_user_job(req, uid, gid)
        elif action == "control_user_job":
            resp = handle_control_user_job(req, uid)
        elif action == "user_fs_op":
            resp = handle_user_fs_op(req, uid)
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
    old_umask = os.umask(0o177)
    try:
        srv.bind(str(SOCKET_PATH))
    finally:
        os.umask(old_umask)
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
