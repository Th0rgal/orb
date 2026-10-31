#!/usr/bin/env python3
"""Zero-disruption rolling upgrade controller for sandboxed-node workers.

Drains in-flight jobs via Core's node cordon API (/api/nodes/:name/cordon),
caps concurrent cordons so fleet capacity is never starved, fences worker-side
job/lease admission via an exclusive SQLite BEGIN IMMEDIATE lock on jobs.db
before the final zero-work check and holds that fence across service stop and
atomic binary installation, verifies post-start service health (rolling back to
the backup binary and quarantining the broken staged artifact on failure), and
only then uncordons each verified upgraded node.
"""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import hmac
import inspect
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.request

SETTLED_JOB_STATES = ("succeeded", "failed", "cancelled", "retired", "completed", "lost")


def mint_hs256_jwt(secret, subject="admin", ttl_secs=300):
    def b64u(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

    now = int(time.time())
    hdr = b64u(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    pay = b64u(json.dumps({"sub": subject, "iat": now, "exp": now + ttl_secs}, separators=(",", ":")).encode("utf-8"))
    sig = b64u(hmac.new(secret.encode("utf-8"), f"{hdr}.{pay}".encode("ascii"), hashlib.sha256).digest())
    return f"{hdr}.{pay}.{sig}"


def discover_local_core_auth(service_binary="/usr/local/bin/sandboxed-sh-prod", default_port="3000"):
    pid = subprocess.check_output(["pgrep", "-f", service_binary], text=True).split()[0]
    jwt_secret = None
    port = default_port
    for raw in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
        key_b, sep, val_b = raw.partition(b"=")
        if not sep:
            continue
        key = key_b.decode("utf-8", "ignore")
        val = val_b.decode("utf-8", "ignore")
        if key in ("JWT_SECRET", "DASHBOARD_JWT_SECRET") and val:
            jwt_secret = val
        elif key == "PORT" and val:
            port = val
    if not jwt_secret:
        raise RuntimeError("could not locate JWT secret in Core process environment")
    return f"http://127.0.0.1:{port}", mint_hs256_jwt(jwt_secret)


class HttpCoreApi:
    def __init__(self, base_url, bearer_token):
        self.base_url = base_url.rstrip("/")
        self.bearer_token = bearer_token

    def _request(self, path, method="GET"):
        req = urllib.request.Request(
            f"{self.base_url}{path}",
            data=b"{}" if method == "POST" else None,
            headers={
                "Authorization": f"Bearer {self.bearer_token}",
                "Content-Type": "application/json",
            },
            method=method,
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def list_nodes(self):
        payload = self._request("/api/remote-nodes", method="GET")
        return payload if isinstance(payload, list) else payload.get("nodes", [])

    def set_cordon(self, node_id, cordoned):
        verb = "cordon" if cordoned else "uncordon"
        return self._request(f"/api/nodes/{node_id}/{verb}", method="POST")


# --- Shared worker-side state probe & fenced atomic upgrade helpers ---


class SystemdServiceCtl:
    def is_active(self, unit_name):
        res = subprocess.run(["systemctl", "is-active", "--quiet", unit_name], check=False)
        return res.returncode == 0

    def stop(self, unit_name):
        subprocess.check_call(["systemctl", "stop", unit_name])

    def start(self, unit_name):
        subprocess.check_call(["systemctl", "start", unit_name])

    def start_best_effort(self, unit_name):
        subprocess.run(["systemctl", "start", unit_name], check=False)

    def restart_best_effort(self, unit_name):
        subprocess.run(["systemctl", "restart", unit_name], check=False)


def _parse_simple_env_file(env_path):
    values = {}
    path = Path(env_path)
    if not path.is_file():
        return values
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        key, sep, val = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key:
            values[key] = val
    return values


def _read_proc_environ(pid):
    values = {}
    try:
        raw_bytes = Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return values
    for item in raw_bytes.split(b"\0"):
        key_b, sep, val_b = item.partition(b"=")
        if sep:
            values[key_b.decode("utf-8", "ignore")] = val_b.decode("utf-8", "ignore")
    return values


def _restore_db_ownership(db_path, owner_uid_gid):
    if owner_uid_gid is None or os.geteuid() != 0:
        return
    uid, gid = owner_uid_gid
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(str(db_path) + suffix)
        if candidate.exists() and not candidate.is_symlink():
            try:
                os.chown(candidate, uid, gid)
            except OSError:
                pass


def _normalize_service_unit_name(unit_name):
    name = str(unit_name).strip()
    return name[:-len(".service")] if name.endswith(".service") else name


def _discover_unit_env_files(unit_name):
    """Return EnvironmentFiles paths configured on a systemd unit, falling back to /etc/<unit>.env."""
    norm = _normalize_service_unit_name(unit_name)
    res = subprocess.run(
        ["systemctl", "show", "--property=EnvironmentFiles", "--value", unit_name],
        capture_output=True,
        text=True,
        check=False,
    )
    paths = []
    if res.returncode == 0 and res.stdout.strip():
        for line in res.stdout.splitlines():
            # systemd formats entries as `/etc/foo.env (ignore_errors=no)` or `-/etc/foo.env (...)`
            token = line.strip().split(" (", 1)[0].strip()
            if token.startswith("-"):
                token = token[1:].strip()
            if token:
                paths.append(token)
    if not paths:
        paths.append(f"/etc/{norm}.env")
    return paths


def _load_unit_env_files(unit_name, env_file=None):
    values = {}
    candidates = [env_file] if env_file else _discover_unit_env_files(unit_name)
    for candidate in candidates:
        if candidate:
            values.update(_parse_simple_env_file(candidate))
    return values


def default_runtime_busy_probe(unit_name="sandboxed-node", env_file=None):
    """Count live transient scopes, child processes, or in-memory leases/jobs."""
    busy = 0
    scope_res = subprocess.run(
        ["systemctl", "list-units", "--type=scope", "--state=running", "--plain", "--no-legend", "sandboxed-node-*"],
        capture_output=True,
        text=True,
        check=False,
    )
    if scope_res.returncode == 0 and scope_res.stdout.strip():
        busy += len([ln for ln in scope_res.stdout.splitlines() if ln.strip()])

    pid_res = subprocess.run(
        ["systemctl", "show", "--property=MainPID", "--value", unit_name],
        capture_output=True,
        text=True,
        check=False,
    )
    main_pid = pid_res.stdout.strip()
    proc_env = {}
    if pid_res.returncode == 0 and main_pid.isdigit() and int(main_pid) > 0:
        proc_env = _read_proc_environ(main_pid)
        child_res = subprocess.run(["pgrep", "-P", main_pid], capture_output=True, text=True, check=False)
        if child_res.returncode == 0 and child_res.stdout.strip():
            busy += len([ln for ln in child_res.stdout.splitlines() if ln.strip()])

    active_res = subprocess.run(["systemctl", "is-active", "--quiet", unit_name], check=False)
    env_vars = _load_unit_env_files(unit_name, env_file=env_file)
    env_vars.update(proc_env)
    token = env_vars.get("SANDBOXED_NODE_TOKEN")
    if active_res.returncode == 0 and token:
        bind = env_vars.get("SANDBOXED_NODE_BIND", "127.0.0.1:3088").strip()
        host, sep, port = bind.rpartition(":")
        if not sep:
            host, port = "127.0.0.1", "3088"
        if host in ("0.0.0.0", ""):
            host = "127.0.0.1"
        elif host in ("::", "[::]"):
            host = "[::1]"
        req = urllib.request.Request(
            f"http://{host}:{port}/heartbeat",
            headers={"Authorization": f"Bearer {token}"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=3) as resp:
                hb = json.loads(resp.read().decode("utf-8"))
            busy += int(hb.get("active_leases", 0))
            busy += int(hb.get("active_jobs", 0))
            busy += int(hb.get("queued_jobs", 0))
            busy += int(hb.get("side_jobs", 0))
        except Exception:
            # Fail closed if an active node with configured auth fails heartbeat
            busy += 1
    return busy


def _discover_live_work_dir(unit_name="sandboxed-node", env_file=None):
    """Discover the running worker's SANDBOXED_NODE_WORK_DIR when observable."""
    pid_res = subprocess.run(
        ["systemctl", "show", "--property=MainPID", "--value", unit_name],
        capture_output=True,
        text=True,
        check=False,
    )
    main_pid = pid_res.stdout.strip()
    if pid_res.returncode == 0 and main_pid.isdigit() and int(main_pid) > 0:
        proc_env = _read_proc_environ(main_pid)
        if proc_env:
            env_vars = _load_unit_env_files(unit_name, env_file=env_file)
            env_vars.update(proc_env)
            return env_vars.get("SANDBOXED_NODE_WORK_DIR") or "/var/lib/sandboxed-node/work"
    env_vars = _load_unit_env_files(unit_name, env_file=env_file)
    if "SANDBOXED_NODE_WORK_DIR" in env_vars and env_vars["SANDBOXED_NODE_WORK_DIR"]:
        return env_vars["SANDBOXED_NODE_WORK_DIR"]
    return None


def _discover_sibling_units(binary_path="/usr/local/bin/sandboxed-node", primary_unit="sandboxed-node"):
    """Discover additional active worker units on the same host sharing ``binary_path``.

    Hosts such as DGX Spark run both ``sandboxed-node.service`` and
    ``sandboxed-node-admin.service`` backed by ``/usr/local/bin/sandboxed-node``.
    Replacing the shared binary without fencing and restarting sibling units
    leaves them executing ``/usr/local/bin/sandboxed-node (deleted)``.
    """
    primary_norm = _normalize_service_unit_name(primary_unit)
    res = subprocess.run(
        [
            "systemctl",
            "list-units",
            "--type=service",
            "--state=active",
            "--plain",
            "--no-legend",
            "sandboxed-node*.service",
            "orb-node*.service",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0 or not res.stdout.strip():
        return []
    target_real = os.path.realpath(str(binary_path))
    siblings = []
    for raw in res.stdout.splitlines():
        cols = raw.split()
        if not cols:
            continue
        candidate = _normalize_service_unit_name(cols[0])
        if not candidate or candidate == primary_norm or candidate in siblings:
            continue
        show_res = subprocess.run(
            ["systemctl", "show", "--property=ExecStart", "--value", candidate],
            capture_output=True,
            text=True,
            check=False,
        )
        if show_res.returncode != 0:
            continue
        matched = False
        for part in show_res.stdout.replace("{", " ").replace("}", " ").split(";"):
            key, sep, val = part.strip().partition("=")
            if sep and key.strip() == "path":
                exec_path = val.strip()
                if exec_path == str(binary_path) or os.path.realpath(exec_path) == target_real:
                    matched = True
                    break
        if matched:
            siblings.append(candidate)
    return siblings


def _resolve_worker_ledger(
    db_path=None,
    unit_name="sandboxed-node",
    env_file=None,
    live_work_dir_probe=None,
):
    """Resolve and cross-check the worker's SQLite job ledger path (fail-closed)."""
    probe = live_work_dir_probe or (lambda: _discover_live_work_dir(unit_name=unit_name, env_file=env_file))
    live_work_dir = probe()
    live_db = (Path(live_work_dir) / "jobs.db") if live_work_dir else None

    if db_path:
        supplied = Path(db_path)
        if live_db is not None and os.path.realpath(str(supplied)) != os.path.realpath(str(live_db)):
            raise RuntimeError(
                f"supplied ledger {supplied} does not match running worker ledger {live_db}"
            )
        resolved = supplied
    else:
        resolved = live_db if live_db is not None else Path("/var/lib/sandboxed-node/work/jobs.db")

    if not resolved.is_file() or resolved.is_symlink():
        raise RuntimeError(f"node job ledger is missing or a symlink: {resolved}")
    return resolved


def _sqlite_uri(path, mode):
    return f"{Path(path).resolve().as_uri()}?mode={mode}"


def _count_active_db_jobs(conn):
    has_jobs = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='jobs'"
    ).fetchone()
    if not has_jobs:
        raise RuntimeError("node job ledger is missing required 'jobs' table")
    return int(
        conn.execute(
            "SELECT COUNT(*) FROM jobs WHERE state NOT IN ('succeeded','failed','cancelled','retired','completed','lost')"
        ).fetchone()[0]
    )


def _build_worker_unit_targets(
    db_path=None,
    binary_path="/usr/local/bin/sandboxed-node",
    unit_name="sandboxed-node",
    runtime_busy_probe=None,
    live_work_dir_probe=None,
    sibling_units_probe=None,
):
    """Return ordered list of (unit_name, ledger_path, busy_probe_fn) sharing ``binary_path``."""
    primary_busy = runtime_busy_probe or (lambda: default_runtime_busy_probe(unit_name))
    primary_db = _resolve_worker_ledger(
        db_path=db_path,
        unit_name=unit_name,
        live_work_dir_probe=live_work_dir_probe,
    )
    targets = [(unit_name, primary_db, primary_busy)]
    seen_ledgers = {os.path.realpath(str(primary_db))}

    discover_siblings = sibling_units_probe
    if discover_siblings is None and runtime_busy_probe is None and live_work_dir_probe is None:
        discover_siblings = lambda: _discover_sibling_units(binary_path=binary_path, primary_unit=unit_name)
    for sib in (discover_siblings() if discover_siblings else []):
        if isinstance(sib, tuple):
            sib_unit, sib_db_hint = sib[0], sib[1]
            sib_busy = sib[2] if len(sib) > 2 and sib[2] is not None else (
                lambda u=sib_unit: default_runtime_busy_probe(u)
            )
            sib_db = _resolve_worker_ledger(
                db_path=sib_db_hint,
                unit_name=sib_unit,
                live_work_dir_probe=(lambda p=str(Path(sib_db_hint).parent): p) if sib_db_hint else None,
            )
        else:
            sib_unit = str(sib)
            sib_busy = lambda u=sib_unit: default_runtime_busy_probe(u)
            sib_db = _resolve_worker_ledger(db_path=None, unit_name=sib_unit)
        real_sib_db = os.path.realpath(str(sib_db))
        if real_sib_db in seen_ledgers:
            targets.append((sib_unit, None, sib_busy))
        else:
            seen_ledgers.add(real_sib_db)
            targets.append((sib_unit, sib_db, sib_busy))
    return targets


def probe_worker_state(
    db_path=None,
    binary_path="/usr/local/bin/sandboxed-node",
    staged_suffix=".new",
    unit_name="sandboxed-node",
    service_ctl=None,
    runtime_busy_probe=None,
    live_work_dir_probe=None,
    sibling_units_probe=None,
):
    """Return dict with keys staged, running, healthy, quarantined."""
    ctl = service_ctl or SystemdServiceCtl()
    targets = _build_worker_unit_targets(
        db_path=db_path,
        binary_path=binary_path,
        unit_name=unit_name,
        runtime_busy_probe=runtime_busy_probe,
        live_work_dir_probe=live_work_dir_probe,
        sibling_units_probe=sibling_units_probe,
    )
    staged_path = Path(binary_path + staged_suffix)
    failed_path = Path(binary_path + staged_suffix + ".failed")
    staged = staged_path.exists()
    quarantined = (not staged) and failed_path.exists()
    healthy = all(bool(ctl.is_active(u)) for (u, _db, _bp) in targets)

    db_running = 0
    runtime_running = 0
    for _u, target_db, target_busy in targets:
        if target_db is not None:
            con = sqlite3.connect(_sqlite_uri(target_db, "ro"), uri=True, timeout=5.0)
            try:
                db_running += _count_active_db_jobs(con)
            finally:
                con.close()
        if staged:
            runtime_running += int(target_busy())
    return {
        "staged": staged,
        "running": max(db_running, runtime_running),
        "healthy": healthy,
        "quarantined": quarantined,
    }


def perform_fenced_upgrade(
    db_path=None,
    binary_path="/usr/local/bin/sandboxed-node",
    staged_suffix=".new",
    backup_suffix=".prev",
    verify_delay_secs=2.0,
    unit_name="sandboxed-node",
    service_ctl=None,
    runtime_busy_probe=None,
    live_work_dir_probe=None,
    sibling_units_probe=None,
):
    """Drain-verified, write-fenced atomic worker upgrade with automatic rollback.

    Acquires an exclusive SQLite ``BEGIN IMMEDIATE`` transaction on ``jobs.db``
    for the primary worker unit and any sibling worker units sharing
    ``binary_path`` *before* the final zero-job / zero-lease check and holds
    those locks across ``systemctl stop`` and the atomic binary installation.
    Because ``sandboxed-node`` persists every ``POST /jobs`` admission
    (``JobStore::create``) and ``POST /execute`` scratch receipt
    (``scratch::prepare``) into ``jobs.db`` before enqueueing or spawning work —
    and opens ``jobs.db`` on startup before binding its TCP listener — no job
    can be accepted in the post-check window and marked ``lost`` on restart, and
    no sibling worker is left executing a ``(deleted)`` binary.
    """
    ctl = service_ctl or SystemdServiceCtl()
    targets = _build_worker_unit_targets(
        db_path=db_path,
        binary_path=binary_path,
        unit_name=unit_name,
        runtime_busy_probe=runtime_busy_probe,
        live_work_dir_probe=live_work_dir_probe,
        sibling_units_probe=sibling_units_probe,
    )

    bin_path = Path(binary_path)
    staged_path = Path(binary_path + staged_suffix)
    failed_path = Path(binary_path + staged_suffix + ".failed")
    backup_path = Path(binary_path + backup_suffix)
    installing_path = Path(binary_path + ".installing")
    restoring_path = Path(binary_path + ".restoring")

    if not staged_path.is_file():
        raise RuntimeError(f"staged binary does not exist: {staged_path}")

    # 1. Unlocked pre-check on verified existing ledgers so busy nodes never contend on jobs.db
    db_c1 = 0
    rt_c1 = 0
    for _u, target_db, target_busy in targets:
        if target_db is not None:
            ro_con = sqlite3.connect(_sqlite_uri(target_db, "ro"), uri=True, timeout=5.0)
            try:
                db_c1 += _count_active_db_jobs(ro_con)
            finally:
                ro_con.close()
        rt_c1 += int(target_busy())
    c1 = max(db_c1, rt_c1)
    if c1 != 0:
        return f"BUSY:{c1}"

    if verify_delay_secs > 0:
        time.sleep(verify_delay_secs)

    # 2. Acquire worker-side admission fences BEFORE final zero-work verification
    #    (?mode=rw refuses to create a missing DB file; schema is re-verified inside the lock)
    ledger_owners = []
    for _u, target_db, _bp in targets:
        if target_db is None:
            continue
        try:
            st = target_db.lstat()
            ledger_owners.append((target_db, (st.st_uid, st.st_gid)))
        except OSError as error:
            raise RuntimeError(f"cannot stat node ledger {target_db}: {error}") from error

    fences = []
    try:
        for target_db, owner_uid_gid in ledger_owners:
            con = sqlite3.connect(_sqlite_uri(target_db, "rw"), uri=True, timeout=2.0, isolation_level=None)
            fences.append([target_db, owner_uid_gid, con, False])
            try:
                con.execute("BEGIN IMMEDIATE")
                fences[-1][3] = True
            except sqlite3.OperationalError:
                return "BUSY:db_locked"

        db_c2 = sum(_count_active_db_jobs(entry[2]) for entry in fences)
        rt_c2 = sum(int(target_busy()) for (_u, _db, target_busy) in targets)
        c2 = max(db_c2, rt_c2)
        if c2 != 0:
            return f"BUSY:{c2}"

        # Stop outgoing worker(s) while admission fences are held so listeners close
        # before any blocked submit_job/execute caller can commit to jobs.db.
        stopped_units = []
        try:
            for target_unit, _db, _bp in targets:
                ctl.stop(target_unit)
                stopped_units.append(target_unit)
        except Exception as stop_err:
            for entry in reversed(fences):
                if entry[3]:
                    try:
                        entry[2].execute("ROLLBACK")
                    except Exception:
                        pass
                    entry[3] = False
                entry[2].close()
                _restore_db_ownership(entry[0], entry[1])
            fences.clear()
            for u in stopped_units:
                ctl.start_best_effort(u)
            raise RuntimeError(f"failed stopping worker service before binary swap: {stop_err}") from stop_err

        # Copy staged binary via temporary path so staged_path (.new) is preserved
        # until post-start activation and health checks succeed.
        replaced_binary = False
        try:
            shutil.copy2(bin_path, backup_path)
            shutil.copy2(staged_path, installing_path)
            os.chmod(installing_path, 0o755)
            os.replace(installing_path, bin_path)
            replaced_binary = True
        except Exception as swap_err:
            installing_path.unlink(missing_ok=True)
            for entry in reversed(fences):
                if entry[3]:
                    entry[2].execute("ROLLBACK")
                    entry[3] = False
                entry[2].close()
                _restore_db_ownership(entry[0], entry[1])
            fences.clear()
            if replaced_binary and backup_path.is_file():
                shutil.copy2(backup_path, restoring_path)
                os.chmod(restoring_path, 0o755)
                os.replace(restoring_path, bin_path)
                restoring_path.unlink(missing_ok=True)
            for target_unit, _db, _bp in targets:
                ctl.start_best_effort(target_unit)
            raise RuntimeError(f"binary swap failed; restored previous service: {swap_err}") from swap_err

        # Release SQLite write fences right before starting the new process(es) so
        # startup JobStore::open / recover_on_start succeeds without contention.
        for entry in reversed(fences):
            if entry[3]:
                entry[2].execute("ROLLBACK")
                entry[3] = False
    finally:
        for entry in reversed(fences):
            if entry[3]:
                try:
                    entry[2].execute("ROLLBACK")
                except Exception:
                    pass
            try:
                entry[2].close()
            except Exception:
                pass
            _restore_db_ownership(entry[0], entry[1])

    # 3. Activate new binary and verify health across all units; roll back and quarantine on failure
    try:
        for target_unit, _db, _bp in targets:
            ctl.start(target_unit)
            if not ctl.is_active(target_unit):
                raise RuntimeError(f"{target_unit} failed post-start is-active check")
    except Exception as act_err:
        try:
            if backup_path.is_file():
                shutil.copy2(backup_path, restoring_path)
                os.chmod(restoring_path, 0o755)
                os.replace(restoring_path, bin_path)
        finally:
            restoring_path.unlink(missing_ok=True)
        try:
            if staged_path.exists():
                os.replace(staged_path, failed_path)
        except OSError:
            pass
        for target_unit, _db, _bp in targets:
            ctl.restart_best_effort(target_unit)
        raise RuntimeError(
            f"activation failed; rolled back to {backup_path} and quarantined {failed_path}: {act_err}"
        ) from act_err

    # 4. Verified active! Consume staged artifact and clear any prior failure marker.
    staged_path.unlink(missing_ok=True)
    failed_path.unlink(missing_ok=True)
    return "UPGRADED"


def _remote_worker_prelude():
    parts = [
        "import json, os, pathlib, shutil, sqlite3, subprocess, time, urllib.request",
        "from pathlib import Path",
        inspect.getsource(SystemdServiceCtl),
        inspect.getsource(_parse_simple_env_file),
        inspect.getsource(_read_proc_environ),
        inspect.getsource(_restore_db_ownership),
        inspect.getsource(_normalize_service_unit_name),
        inspect.getsource(_discover_unit_env_files),
        inspect.getsource(_load_unit_env_files),
        inspect.getsource(default_runtime_busy_probe),
        inspect.getsource(_discover_live_work_dir),
        inspect.getsource(_discover_sibling_units),
        inspect.getsource(_resolve_worker_ledger),
        inspect.getsource(_sqlite_uri),
        inspect.getsource(_count_active_db_jobs),
        inspect.getsource(_build_worker_unit_targets),
        inspect.getsource(probe_worker_state),
        inspect.getsource(perform_fenced_upgrade),
    ]
    return "\n\n".join(parts)


class SshNodeOps:
    def __init__(self, ssh_config=None, staged_suffix=".new", backup_suffix=".prev", verify_delay_secs=2.0):
        self.ssh_config = ssh_config
        self.staged_suffix = staged_suffix
        self.backup_suffix = backup_suffix
        self.verify_delay_secs = float(verify_delay_secs)

    def _ssh_python(self, host, code, timeout=30):
        cmd = ["ssh"]
        if self.ssh_config:
            cmd.extend(["-F", str(self.ssh_config)])
        cmd.extend(["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, "sudo python3 -"])
        res = subprocess.run(cmd, input=code, capture_output=True, text=True, timeout=timeout)
        if res.returncode != 0:
            raise RuntimeError(f"ssh {host} failed: {res.stderr.strip()}")
        return res.stdout.strip()

    def probe_remote(self, host, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        code = (
            _remote_worker_prelude()
            + f"\nprint(json.dumps(probe_worker_state({db_path!r}, binary_path={binary_path!r}, staged_suffix={self.staged_suffix!r})))\n"
        )
        out = self._ssh_python(host, code)
        return json.loads(out.splitlines()[-1])

    def upgrade_remote(self, host, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        code = (
            _remote_worker_prelude()
            + "\nprint(perform_fenced_upgrade("
            + f"{db_path!r}, binary_path={binary_path!r}, staged_suffix={self.staged_suffix!r}, "
            + f"backup_suffix={self.backup_suffix!r}, verify_delay_secs={self.verify_delay_secs!r}"
            + "))\n"
        )
        out = self._ssh_python(host, code, timeout=max(45, int(self.verify_delay_secs) + 30))
        return out.splitlines()[-1]

    def probe_local(self, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        return probe_worker_state(
            db_path=db_path,
            binary_path=binary_path,
            staged_suffix=self.staged_suffix,
        )

    def upgrade_local(self, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        return perform_fenced_upgrade(
            db_path=db_path,
            binary_path=binary_path,
            staged_suffix=self.staged_suffix,
            backup_suffix=self.backup_suffix,
            verify_delay_secs=self.verify_delay_secs,
        )

    def stop_timer(self, unit_name):
        subprocess.run(["systemctl", "stop", unit_name], check=False)


def _normalize_probe_result(raw):
    """Accept dict or legacy (staged, running[, healthy[, quarantined]]) tuple."""
    if isinstance(raw, dict):
        return (
            bool(raw["staged"]),
            int(raw["running"]),
            bool(raw.get("healthy", True)),
            bool(raw.get("quarantined", False)),
        )
    staged = bool(raw[0])
    running = int(raw[1])
    healthy = bool(raw[2]) if len(raw) > 2 else True
    quarantined = bool(raw[3]) if len(raw) > 3 else False
    return staged, running, healthy, quarantined


def rolling_upgrade_step(
    core_api,
    node_ops,
    remote_nodes,
    local_jobs_db=None,
    max_concurrent_cordons=2,
    apply=False,
    stop_timer_unit=None,
    PreserveCordons=frozenset(),
):
    """Execute one idempotent rolling-upgrade reconciliation tick."""
    events = []
    now = dt.datetime.now(dt.timezone.utc).isoformat()

    def emit(action, **fields):
        events.append({"at": now, "action": action, "apply": bool(apply), **fields})

    nodes_list = core_api.list_nodes()
    cordoned_map = {n["id"]: bool(n.get("cordoned")) for n in nodes_list}

    pending_remotes = []
    currently_cordoned_pending = []
    probe_errors = 0
    upgrade_failures = 0

    def try_upgrade_remote(host, db_path):
        nonlocal upgrade_failures
        try:
            outcome = node_ops.upgrade_remote(host, db_path)
        except Exception as error:
            upgrade_failures += 1
            emit("upgrade_failed", node=host, error=str(error))
            return False
        if outcome == "UPGRADED":
            if host not in PreserveCordons:
                core_api.set_cordon(host, False)
                cordoned_map[host] = False
            emit("upgraded_remote", node=host, uncordoned=(host not in PreserveCordons))
            return True
        emit("upgrade_deferred", node=host, detail=outcome)
        return False

    for host, db_path in remote_nodes:
        try:
            staged, running, healthy, quarantined = _normalize_probe_result(
                node_ops.probe_remote(host, db_path)
            )
        except Exception as error:
            probe_errors += 1
            emit("probe_error", node=host, error=str(error))
            pending_remotes.append((host, db_path, -1))
            if cordoned_map.get(host, False):
                currently_cordoned_pending.append(host)
            continue

        if not staged:
            if quarantined or not healthy:
                upgrade_failures += 1
                pending_remotes.append((host, db_path, -1))
                if cordoned_map.get(host, False):
                    currently_cordoned_pending.append(host)
                emit(
                    "upgrade_quarantined" if quarantined else "unhealthy_node",
                    node=host,
                    healthy=healthy,
                )
                continue
            if cordoned_map.get(host, False) and host not in PreserveCordons:
                if apply:
                    core_api.set_cordon(host, False)
                    cordoned_map[host] = False
                emit("uncordoned_completed_node", node=host)
            continue

        is_cord = cordoned_map.get(host, False)
        if is_cord and running == 0 and upgrade_failures == 0:
            if apply:
                if try_upgrade_remote(host, db_path):
                    continue
            else:
                emit("would_upgrade_remote", node=host)

        pending_remotes.append((host, db_path, running))
        if is_cord:
            currently_cordoned_pending.append(host)
            emit("draining", node=host, running_jobs=running)
        else:
            emit("pending_uncordoned", node=host, running_jobs=running)

    # Never leave more than max_concurrent_cordons pending nodes cordoned
    while len(currently_cordoned_pending) > max_concurrent_cordons:
        excess = currently_cordoned_pending.pop()
        if excess in PreserveCordons:
            continue
        if apply:
            core_api.set_cordon(excess, False)
            cordoned_map[excess] = False
        emit("uncordoned_excess_wave", node=excess)

    # Advance cordons only when all remote probes and prior upgrades succeeded (fail-closed)
    slots = max_concurrent_cordons - len(currently_cordoned_pending)
    if slots > 0 and probe_errors == 0 and upgrade_failures == 0:
        candidates = [
            (running, host, db_path)
            for (host, db_path, running) in pending_remotes
            if running >= 0 and not cordoned_map.get(host, False)
        ]
        candidates.sort()
        for running, host, db_path in candidates[:slots]:
            if upgrade_failures > 0:
                break
            if apply:
                core_api.set_cordon(host, True)
                cordoned_map[host] = True
            emit("cordoned_for_drain", node=host, running_jobs=running)
            if running == 0:
                if apply:
                    if try_upgrade_remote(host, db_path):
                        pending_remotes = [p for p in pending_remotes if p[0] != host]
                else:
                    emit("would_upgrade_remote", node=host)

    local_pending = False
    if local_jobs_db:
        try:
            staged, running, healthy, quarantined = _normalize_probe_result(
                node_ops.probe_local(local_jobs_db)
            )
        except Exception as error:
            local_pending = True
            emit("local_probe_error", error=str(error))
        else:
            if not staged:
                if quarantined or not healthy:
                    local_pending = True
                    emit(
                        "local_upgrade_quarantined" if quarantined else "unhealthy_local",
                        healthy=healthy,
                    )
            else:
                if running == 0 and upgrade_failures == 0:
                    if apply:
                        try:
                            outcome = node_ops.upgrade_local(local_jobs_db)
                        except Exception as error:
                            local_pending = True
                            emit("local_upgrade_failed", error=str(error))
                        else:
                            if outcome == "UPGRADED":
                                emit("upgraded_local", running_jobs=0)
                            else:
                                local_pending = True
                                emit("local_deferred", detail=outcome)
                    else:
                        local_pending = True
                        emit("would_upgrade_local", running_jobs=0)
                elif running == 0:
                    local_pending = True
                    emit("local_blocked_by_remote_error", running_jobs=0)
                else:
                    local_pending = True
                    emit("local_waiting", running_jobs=running)

    all_complete = not pending_remotes and not local_pending
    if all_complete:
        emit("all_nodes_upgraded")
        if apply and stop_timer_unit:
            node_ops.stop_timer(stop_timer_unit)
            emit("stopped_timer", unit=stop_timer_unit)

    return events, all_complete


def parse_node_spec(raw):
    host, sep, db_path = raw.partition(":")
    if not host:
        raise ValueError(f"invalid --node spec: {raw!r}")
    return host, (db_path if sep and db_path else None)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Zero-disruption rolling upgrade for sandboxed-node.")
    parser.add_argument(
        "--node",
        action="append",
        default=[],
        help="Remote worker as HOST or HOST:/path/to/jobs.db (repeatable)",
    )
    parser.add_argument("--local-jobs-db", help="Optional local runner jobs.db path on Core host")
    parser.add_argument("--ssh-config", default="/root/.config/sandboxed-sh/development-identity/current/ssh/config")
    parser.add_argument("--api-url", help="Core API base URL (auto-discovered from local process if omitted)")
    parser.add_argument("--token-env", default="SANDBOXED_API_TOKEN", help="Env var holding Core API bearer token")
    parser.add_argument("--staged-suffix", default=".new", help="Suffix of staged binary (default: .new)")
    parser.add_argument("--backup-suffix", default=".prev", help="Suffix for backup binary (default: .prev)")
    parser.add_argument("--max-concurrent-cordons", type=int, default=2)
    parser.add_argument("--verify-delay-secs", type=float, default=2.0)
    parser.add_argument("--preserve-cordon", action="append", default=[], help="Node IDs to keep cordoned after upgrade")
    parser.add_argument("--stop-timer-on-complete", help="Systemd timer unit to stop when all nodes finish")
    parser.add_argument("--lock-file", default="/run/sandboxed-node-rolling-upgrade.lock")
    parser.add_argument("--audit-log", help="Append JSONL events to this file")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Inspect and report planned actions only (default)")
    mode.add_argument("--apply", action="store_true", help="Execute cordons, swaps, restarts, and uncordons")
    args = parser.parse_args(argv)

    if not args.node and not args.local_jobs_db:
        parser.error("provide at least one --node or --local-jobs-db")
    if args.max_concurrent_cordons < 1:
        parser.error("--max-concurrent-cordons must be >= 1")

    remote_nodes = [parse_node_spec(item) for item in args.node]

    lock_handle = None
    if args.apply and args.lock_file:
        Path(args.lock_file).parent.mkdir(parents=True, exist_ok=True)
        lock_handle = open(args.lock_file, "w")
        try:
            fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0

    try:
        token = os.environ.get(args.token_env)
        if args.api_url and token:
            base_url, bearer = args.api_url, token
        else:
            base_url, bearer = discover_local_core_auth()

        core_api = HttpCoreApi(base_url, bearer)
        ssh_cfg = args.ssh_config if args.ssh_config and Path(args.ssh_config).exists() else None
        node_ops = SshNodeOps(
            ssh_config=ssh_cfg,
            staged_suffix=args.staged_suffix,
            backup_suffix=args.backup_suffix,
            verify_delay_secs=args.verify_delay_secs,
        )
        events, _ = rolling_upgrade_step(
            core_api=core_api,
            node_ops=node_ops,
            remote_nodes=remote_nodes,
            local_jobs_db=args.local_jobs_db,
            max_concurrent_cordons=args.max_concurrent_cordons,
            apply=args.apply,
            stop_timer_unit=args.stop_timer_on_complete,
            PreserveCordons=frozenset(args.preserve_cordon),
        )
        output = "".join(json.dumps(ev, sort_keys=True) + "\n" for ev in events)
        sys.stdout.write(output)
        if args.audit_log:
            Path(args.audit_log).parent.mkdir(parents=True, exist_ok=True)
            with open(args.audit_log, "a", encoding="utf-8") as handle:
                handle.write(output)
        return 0
    finally:
        if lock_handle is not None:
            lock_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
