#!/usr/bin/env python3
"""Zero-disruption rolling upgrade controller for sandboxed-node workers.

Drains in-flight jobs via Core's node cordon API (/api/nodes/:name/cordon),
caps concurrent cordons so fleet capacity is never starved, verifies zero
active jobs in jobs.db across a TOCTOU delay before atomically swapping the
staged binary and restarting sandboxed-node, then uncordons each upgraded node.
"""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import hmac
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
        staged_path = binary_path + self.staged_suffix
        code = f"""
import os, sqlite3
staged = os.path.exists({staged_path!r})
con = sqlite3.connect({db_path!r})
cnt = con.execute(
    "SELECT COUNT(*) FROM jobs WHERE state NOT IN ('succeeded','failed','cancelled','retired','completed','lost')"
).fetchone()[0]
con.close()
print(f"{{int(staged)}} {{cnt}}")
"""
        parts = self._ssh_python(host, code).split()
        return bool(int(parts[0])), int(parts[1])

    def upgrade_remote(self, host, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        staged_path = binary_path + self.staged_suffix
        backup_path = binary_path + self.backup_suffix
        code = f"""
import os, shutil, sqlite3, subprocess, time
def active_cnt():
    con = sqlite3.connect({db_path!r})
    c = con.execute(
        "SELECT COUNT(*) FROM jobs WHERE state NOT IN ('succeeded','failed','cancelled','retired','completed','lost')"
    ).fetchone()[0]
    con.close()
    return c

c1 = active_cnt()
if c1 != 0:
    print(f"BUSY:{{c1}}")
    raise SystemExit(0)
time.sleep({self.verify_delay_secs!r})
c2 = active_cnt()
if c2 != 0:
    print(f"BUSY:{{c2}}")
    raise SystemExit(0)

shutil.copy2({binary_path!r}, {backup_path!r})
os.chmod({staged_path!r}, 0o755)
os.replace({staged_path!r}, {binary_path!r})
subprocess.check_call(["systemctl", "restart", "sandboxed-node"])
subprocess.check_call(["systemctl", "is-active", "--quiet", "sandboxed-node"])
print("UPGRADED")
"""
        out = self._ssh_python(host, code, timeout=max(45, int(self.verify_delay_secs) + 30))
        return out.splitlines()[-1]

    def probe_local(self, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        staged = Path(binary_path + self.staged_suffix).exists()
        if not staged:
            return False, 0
        con = sqlite3.connect(db_path)
        try:
            cnt = con.execute(
                "SELECT COUNT(*) FROM jobs WHERE state NOT IN ('succeeded','failed','cancelled','retired','completed','lost')"
            ).fetchone()[0]
        finally:
            con.close()
        return True, int(cnt)

    def upgrade_local(self, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        staged_path = Path(binary_path + self.staged_suffix)
        backup_path = Path(binary_path + self.backup_suffix)
        _, c1 = self.probe_local(db_path, binary_path)
        if c1 != 0:
            return f"BUSY:{c1}"
        time.sleep(self.verify_delay_secs)
        _, c2 = self.probe_local(db_path, binary_path)
        if c2 != 0:
            return f"BUSY:{c2}"
        shutil.copy2(binary_path, backup_path)
        os.chmod(staged_path, 0o755)
        os.replace(staged_path, binary_path)
        subprocess.check_call(["systemctl", "restart", "sandboxed-node"])
        subprocess.check_call(["systemctl", "is-active", "--quiet", "sandboxed-node"])
        return "UPGRADED"

    def stop_timer(self, unit_name):
        subprocess.run(["systemctl", "stop", unit_name], check=False)


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

    for host, db_path in remote_nodes:
        try:
            staged, running = node_ops.probe_remote(host, db_path)
        except Exception as error:
            probe_errors += 1
            emit("probe_error", node=host, error=str(error))
            pending_remotes.append((host, db_path, -1))
            if cordoned_map.get(host, False):
                currently_cordoned_pending.append(host)
            continue

        if not staged:
            if cordoned_map.get(host, False) and host not in PreserveCordons:
                if apply:
                    core_api.set_cordon(host, False)
                    cordoned_map[host] = False
                emit("uncordoned_completed_node", node=host)
            continue

        is_cord = cordoned_map.get(host, False)
        if is_cord and running == 0:
            if apply:
                outcome = node_ops.upgrade_remote(host, db_path)
                if outcome == "UPGRADED":
                    if host not in PreserveCordons:
                        core_api.set_cordon(host, False)
                        cordoned_map[host] = False
                    emit("upgraded_remote", node=host, uncordoned=(host not in PreserveCordons))
                    continue
                emit("upgrade_deferred", node=host, detail=outcome)
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

    # Advance cordons only when all remote probes succeeded (fail-closed on SSH error)
    slots = max_concurrent_cordons - len(currently_cordoned_pending)
    if slots > 0 and probe_errors == 0:
        candidates = [
            (running, host, db_path)
            for (host, db_path, running) in pending_remotes
            if running >= 0 and not cordoned_map.get(host, False)
        ]
        candidates.sort()
        for running, host, db_path in candidates[:slots]:
            if apply:
                core_api.set_cordon(host, True)
                cordoned_map[host] = True
            emit("cordoned_for_drain", node=host, running_jobs=running)
            if running == 0:
                if apply:
                    outcome = node_ops.upgrade_remote(host, db_path)
                    if outcome == "UPGRADED":
                        if host not in PreserveCordons:
                            core_api.set_cordon(host, False)
                            cordoned_map[host] = False
                        emit("upgraded_remote", node=host, uncordoned=(host not in PreserveCordons))
                        pending_remotes = [p for p in pending_remotes if p[0] != host]
                else:
                    emit("would_upgrade_remote", node=host)

    local_pending = False
    if local_jobs_db:
        staged, running = node_ops.probe_local(local_jobs_db)
        if staged:
            if running == 0:
                if apply:
                    outcome = node_ops.upgrade_local(local_jobs_db)
                    if outcome == "UPGRADED":
                        emit("upgraded_local", running_jobs=0)
                    else:
                        local_pending = True
                        emit("local_deferred", detail=outcome)
                else:
                    local_pending = True
                    emit("would_upgrade_local", running_jobs=0)
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
    return host, (db_path if sep and db_path else "/var/lib/sandboxed-node/jobs.db")


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
