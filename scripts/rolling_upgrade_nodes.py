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
import shlex
import sqlite3
import subprocess
import sys
import time
import urllib.request

SETTLED_JOB_STATES = ("succeeded", "failed", "cancelled", "retired", "completed", "lost")
DEFAULT_ROLLOUT_BINARIES = (
    ("sandboxed-node", "/usr/local/bin/sandboxed-node"),
    ("sandboxed-mcp", "/usr/local/bin/sandboxed-mcp"),
    ("orb-privd", "/usr/local/sbin/orb-privd"),
)
DEFAULT_CORDON_OWNER = "rolling_upgrade_nodes"
DEFAULT_CORDON_LEDGER_PATH = "/run/sandboxed-node-rolling-upgrade.cordons.json"


def load_cordon_ledger(ledger_path=DEFAULT_CORDON_LEDGER_PATH):
    if not ledger_path:
        return {}
    p = Path(ledger_path)
    if not p.is_file():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        nodes = data.get("nodes") if isinstance(data, dict) else None
        return dict(nodes) if isinstance(nodes, dict) else {}
    except Exception:
        return {}


def save_cordon_ledger(entries, ledger_path=DEFAULT_CORDON_LEDGER_PATH):
    if not ledger_path:
        return
    p = Path(ledger_path)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = Path(str(p) + ".tmp")
        payload = {"version": 1, "nodes": dict(entries)}
        tmp.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, p)
    except OSError:
        if ledger_path != DEFAULT_CORDON_LEDGER_PATH:
            raise


def record_cordon_owner(
    node_id,
    cordoned_by=DEFAULT_CORDON_OWNER,
    reason="rolling_upgrade_drain",
    target_build_sha=None,
    ledger_path=DEFAULT_CORDON_LEDGER_PATH,
):
    entries = load_cordon_ledger(ledger_path)
    entries[node_id] = {
        "node": node_id,
        "cordoned_by": cordoned_by,
        "reason": reason,
        "target_build_sha": target_build_sha,
        "cordoned_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "pid": os.getpid(),
    }
    save_cordon_ledger(entries, ledger_path)
    return entries[node_id]


def clear_cordon_owner(node_id, ledger_path=DEFAULT_CORDON_LEDGER_PATH):
    entries = load_cordon_ledger(ledger_path)
    removed = entries.pop(node_id, None)
    save_cordon_ledger(entries, ledger_path)
    return removed


def compute_file_sha256(path):
    p = Path(path)
    if not p.is_file():
        return None
    h = hashlib.sha256()
    with open(p, "rb") as handle:
        while True:
            chunk = handle.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _resolve_companion_paths(
    binary_path="/usr/local/bin/sandboxed-node",
    mcp_binary_path=None,
    privd_binary_path=None,
):
    node_path = Path(binary_path)
    mcp_path = Path(mcp_binary_path) if mcp_binary_path else None
    privd_path = Path(privd_binary_path) if privd_binary_path else None
    if mcp_path is None:
        cand = node_path.parent / "sandboxed-mcp"
        if str(node_path) == "/usr/local/bin/sandboxed-node":
            mcp_path = Path("/usr/local/bin/sandboxed-mcp")
        elif cand.exists() or Path(str(cand) + ".new").exists():
            mcp_path = cand
    if privd_path is None:
        cand_same = node_path.parent / "orb-privd"
        cand_sbin = node_path.parent.parent / "sbin" / "orb-privd"
        if str(node_path) == "/usr/local/bin/sandboxed-node":
            privd_path = Path("/usr/local/sbin/orb-privd")
        elif cand_same.exists() or Path(str(cand_same) + ".new").exists():
            privd_path = cand_same
        elif cand_sbin.exists() or Path(str(cand_sbin) + ".new").exists():
            privd_path = cand_sbin
    return node_path, mcp_path, privd_path


def _normalize_reported_build_sha(raw_sha):
    if not raw_sha or not isinstance(raw_sha, str):
        return "unknown"
    val = raw_sha.strip()
    if not val or val.lower() in ("unknown", "current", "none", "null"):
        return "unknown"
    return val


def _read_build_conf_sha(build_conf_path):
    if not build_conf_path:
        return None
    p = Path(build_conf_path)
    if not p.is_file():
        return None
    try:
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if line.startswith("Environment=ORB_BUILD_SHA="):
                val = line[len("Environment=ORB_BUILD_SHA="):].strip().strip('"').strip("'")
                if val:
                    return val
    except OSError:
        return None
    return None


def _write_build_conf_sha(build_conf_path, build_sha):
    p = Path(build_conf_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(p) + ".tmp")
    tmp.write_text(f"[Service]\nEnvironment=ORB_BUILD_SHA={build_sha}\n", encoding="utf-8")
    os.chmod(tmp, 0o644)
    os.replace(tmp, p)


def _default_swap_journal_path(binary_path="/usr/local/bin/sandboxed-node"):
    return Path(str(binary_path) + ".swap-journal.json")


def _fsync_file_and_dir(path):
    p = Path(path)
    try:
        with open(p, "rb") as handle:
            os.fsync(handle.fileno())
    except OSError:
        pass
    try:
        dir_fd = os.open(str(p.parent), os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError:
        pass


def _write_swap_journal(journal_path, active_components, build_conf_path=None, prev_build_sha=None):
    jp = Path(journal_path)
    jp.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(jp) + ".tmp")
    payload = {
        "version": 1,
        "components": [
            {
                "name": c["name"],
                "bin": str(c["bin"]),
                "backup": str(c["backup"]),
                "installing": str(c.get("installing") or (str(c["bin"]) + ".installing")),
                "restoring": str(c.get("restoring") or (str(c["bin"]) + ".restoring")),
                "had_existing": bool(c.get("had_existing", True)),
                "prev_sha256": c.get("prev_sha256"),
            }
            for c in active_components
        ],
        "build_conf_path": str(build_conf_path) if build_conf_path else None,
        "prev_build_sha": prev_build_sha,
    }
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    _fsync_file_and_dir(tmp)
    os.replace(tmp, jp)
    _fsync_file_and_dir(jp)


def _recover_swap_journal(journal_path, service_ctl=None):
    jp = Path(journal_path)
    if not jp.is_file():
        return False
    try:
        data = json.loads(jp.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError(f"corrupt swap journal {jp}: {exc}") from exc
    errors = []
    for entry in reversed(data.get("components", [])):
        bin_p = Path(entry["bin"])
        backup_p = Path(entry["backup"])
        inst_p = Path(entry.get("installing") or (str(bin_p) + ".installing"))
        rest_p = Path(entry.get("restoring") or (str(bin_p) + ".restoring"))
        had_existing = bool(entry.get("had_existing", True))
        prev_sha = entry.get("prev_sha256")
        try:
            inst_p.unlink(missing_ok=True)
        except OSError:
            pass
        try:
            if had_existing:
                if not backup_p.is_file():
                    errors.append(f"missing backup {backup_p} for {entry.get('name')}")
                    continue
                shutil.copy2(backup_p, rest_p)
                os.chmod(rest_p, 0o755)
                os.replace(rest_p, bin_p)
                if prev_sha:
                    got_sha = compute_file_sha256(bin_p)
                    if got_sha != prev_sha.lower():
                        errors.append(
                            f"recovered {bin_p} sha256 {got_sha} != expected {prev_sha}"
                        )
            else:
                bin_p.unlink(missing_ok=True)
        except Exception as exc:
            errors.append(f"failed recovering {bin_p}: {exc}")
        finally:
            try:
                rest_p.unlink(missing_ok=True)
            except OSError:
                pass
    conf_raw = data.get("build_conf_path")
    if conf_raw:
        conf_p = Path(conf_raw)
        prev_sha = data.get("prev_build_sha")
        try:
            if prev_sha is not None:
                _write_build_conf_sha(conf_p, prev_sha)
            else:
                conf_p.unlink(missing_ok=True)
            if service_ctl is not None and hasattr(service_ctl, "daemon_reload"):
                service_ctl.daemon_reload()
        except Exception as exc:
            errors.append(f"failed recovering build_conf {conf_p}: {exc}")
    if errors:
        raise RuntimeError(f"swap journal recovery failed ({jp}): " + "; ".join(errors))
    jp.unlink(missing_ok=True)
    return True


def _default_start_guard_script_path(binary_path="/usr/local/bin/sandboxed-node"):
    return Path(str(binary_path) + "-swap-guard.py")


def _default_start_guard_conf_path(build_conf_path=None, unit_name="sandboxed-node", binary_path="/usr/local/bin/sandboxed-node"):
    if build_conf_path is not None:
        return Path(build_conf_path).parent / "25-swap-guard.conf"
    if str(binary_path) == "/usr/local/bin/sandboxed-node":
        return Path(f"/etc/systemd/system/{_normalize_service_unit_name(unit_name)}.service.d/25-swap-guard.conf")
    return None


def _render_start_guard_script(journal_path):
    jp_str = str(Path(journal_path))
    return (
        "#!/usr/bin/env python3\n"
        "import hashlib, json, os, pathlib, shutil, sys\n"
        f"jp = pathlib.Path({jp_str!r})\n"
        "if not jp.is_file():\n"
        "    raise SystemExit(0)\n"
        "try:\n"
        "    data = json.loads(jp.read_text(encoding='utf-8'))\n"
        "except Exception as exc:\n"
        "    sys.stderr.write(f'corrupt swap journal {jp}: {exc}\\n')\n"
        "    raise SystemExit(1)\n"
        "errors = []\n"
        "for entry in reversed(data.get('components', [])):\n"
        "    bin_p = pathlib.Path(entry['bin'])\n"
        "    backup_p = pathlib.Path(entry['backup'])\n"
        "    inst_p = pathlib.Path(entry.get('installing') or (str(bin_p) + '.installing'))\n"
        "    rest_p = pathlib.Path(entry.get('restoring') or (str(bin_p) + '.restoring'))\n"
        "    had_existing = bool(entry.get('had_existing', True))\n"
        "    prev_sha = entry.get('prev_sha256')\n"
        "    try:\n"
        "        inst_p.unlink(missing_ok=True)\n"
        "    except OSError:\n"
        "        pass\n"
        "    try:\n"
        "        if had_existing:\n"
        "            if not backup_p.is_file():\n"
        "                errors.append(f'missing backup {backup_p} for {entry.get(\"name\")}')\n"
        "                continue\n"
        "            shutil.copy2(backup_p, rest_p)\n"
        "            os.chmod(rest_p, 0o755)\n"
        "            os.replace(rest_p, bin_p)\n"
        "            if prev_sha:\n"
        "                got_sha = hashlib.sha256(bin_p.read_bytes()).hexdigest()\n"
        "                if got_sha != prev_sha.lower():\n"
        "                    errors.append(f'recovered {bin_p} sha256 {got_sha} != expected {prev_sha}')\n"
        "        else:\n"
        "            bin_p.unlink(missing_ok=True)\n"
        "    except Exception as exc:\n"
        "        errors.append(f'failed recovering {bin_p}: {exc}')\n"
        "    finally:\n"
        "        try:\n"
        "            rest_p.unlink(missing_ok=True)\n"
        "        except OSError:\n"
        "            pass\n"
        "conf_raw = data.get('build_conf_path')\n"
        "if conf_raw:\n"
        "    conf_p = pathlib.Path(conf_raw)\n"
        "    prev_sha = data.get('prev_build_sha')\n"
        "    try:\n"
        "        if prev_sha is not None:\n"
        "            conf_p.parent.mkdir(parents=True, exist_ok=True)\n"
        "            tmp = pathlib.Path(str(conf_p) + '.tmp')\n"
        "            tmp.write_text(f'[Service]\\nEnvironment=ORB_BUILD_SHA={prev_sha}\\n', encoding='utf-8')\n"
        "            os.chmod(tmp, 0o644)\n"
        "            os.replace(tmp, conf_p)\n"
        "        else:\n"
        "            conf_p.unlink(missing_ok=True)\n"
        "    except Exception as exc:\n"
        "        errors.append(f'failed recovering build_conf {conf_p}: {exc}')\n"
        "if errors:\n"
        "    sys.stderr.write('swap journal recovery failed: ' + '; '.join(errors) + '\\n')\n"
        "    raise SystemExit(1)\n"
        "jp.unlink(missing_ok=True)\n"
        "if jp.exists():\n"
        "    sys.stderr.write(f'swap journal still open: {jp}\\n')\n"
        "    raise SystemExit(1)\n"
    )


def _install_start_guard(
    binary_path="/usr/local/bin/sandboxed-node",
    journal_path=None,
    build_conf_path=None,
    unit_name="sandboxed-node",
    service_ctl=None,
):
    jp = Path(journal_path) if journal_path is not None else _default_swap_journal_path(binary_path)
    guard_script = _default_start_guard_script_path(binary_path)
    guard_script.parent.mkdir(parents=True, exist_ok=True)
    tmp_script = Path(str(guard_script) + ".tmp")
    tmp_script.write_text(_render_start_guard_script(jp), encoding="utf-8")
    os.chmod(tmp_script, 0o755)
    _fsync_file_and_dir(tmp_script)
    os.replace(tmp_script, guard_script)
    _fsync_file_and_dir(guard_script)

    guard_conf = _default_start_guard_conf_path(
        build_conf_path=build_conf_path, unit_name=unit_name, binary_path=binary_path
    )
    if guard_conf is not None:
        guard_conf.parent.mkdir(parents=True, exist_ok=True)
        tmp_conf = Path(str(guard_conf) + ".tmp")
        tmp_conf.write_text(
            f"[Service]\nExecStartPre=+/usr/bin/python3 {guard_script}\n",
            encoding="utf-8",
        )
        os.chmod(tmp_conf, 0o644)
        _fsync_file_and_dir(tmp_conf)
        os.replace(tmp_conf, guard_conf)
        _fsync_file_and_dir(guard_conf)
        if service_ctl is not None and hasattr(service_ctl, "daemon_reload"):
            service_ctl.daemon_reload()
    return guard_script, guard_conf


def run_start_guard(binary_path="/usr/local/bin/sandboxed-node", journal_path=None):
    guard_script = _default_start_guard_script_path(binary_path)
    if guard_script.is_file():
        res = subprocess.run(
            [sys.executable, str(guard_script)],
            capture_output=True,
            text=True,
            check=False,
        )
        if res.returncode != 0:
            raise RuntimeError(
                f"start guard {guard_script} refused start: {(res.stderr or res.stdout).strip()}"
            )
        return True
    jp = Path(journal_path) if journal_path is not None else _default_swap_journal_path(binary_path)
    if jp.is_file():
        _recover_swap_journal(jp)
        if jp.is_file():
            raise RuntimeError(f"refusing to start while swap journal is open: {jp}")
        return True
    return False


def _default_health_check_probe(
    unit_name="sandboxed-node",
    env_file=None,
    expected_build_sha=None,
    expected_sha256=None,
    build_conf_path=None,
):
    env_vars = _load_unit_env_files(unit_name, env_file=env_file)
    pid_res = subprocess.run(
        ["systemctl", "show", "--property=MainPID", "--value", unit_name],
        capture_output=True,
        text=True,
        check=False,
    )
    main_pid = pid_res.stdout.strip()
    if pid_res.returncode == 0 and main_pid.isdigit() and int(main_pid) > 0:
        env_vars.update(_read_proc_environ(main_pid))
    token = env_vars.get("SANDBOXED_NODE_TOKEN")
    if not token:
        raise RuntimeError(
            f"post-start /heartbeat health check failed: SANDBOXED_NODE_TOKEN missing for {unit_name}"
        )
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
    except Exception as exc:
        raise RuntimeError(f"post-start /heartbeat health check failed: {exc}") from exc
    if not hb.get("online", False):
        raise RuntimeError("post-start /heartbeat reported online=false")
    reported_build = hb.get("build_sha") or hb.get("build")
    if expected_build_sha and reported_build != expected_build_sha:
        raise RuntimeError(
            f"node reported build {reported_build!r} != expected {expected_build_sha!r}"
        )
    reported_bins = hb.get("binary_sha256")
    if expected_sha256:
        if not isinstance(reported_bins, dict):
            raise RuntimeError("post-start /heartbeat missing binary_sha256 map")
        for comp, exp_hash in expected_sha256.items():
            if not exp_hash:
                continue
            rep_hash = reported_bins.get(comp)
            if not rep_hash or not isinstance(rep_hash, str):
                raise RuntimeError(
                    f"node reported missing {comp} sha256 in binary_sha256 (expected {exp_hash})"
                )
            if rep_hash.lower() != exp_hash.lower():
                raise RuntimeError(
                    f"node reported {comp} sha256 {rep_hash} != expected {exp_hash}"
                )
    return {"ok": True, "build_sha": reported_build, "binary_sha256": reported_bins}


def mint_hs256_jwt(secret, subject="admin", ttl_secs=300):
    def b64u(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

    now = int(time.time())
    hdr = b64u(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    pay = b64u(json.dumps({"sub": subject, "iat": now, "exp": now + ttl_secs}, separators=(",", ":")).encode("utf-8"))
    sig = b64u(hmac.new(secret.encode("utf-8"), f"{hdr}.{pay}".encode("ascii"), hashlib.sha256).digest())
    return f"{hdr}.{pay}.{sig}"


def discover_local_core_auth(service_binary="/usr/local/bin/orb-core", default_port="3000"):
    out = subprocess.run(["pgrep", "-f", service_binary], text=True, capture_output=True)
    pids = out.stdout.split()
    if not pids and service_binary == "/usr/local/bin/orb-core":
        pids = subprocess.check_output(["pgrep", "-f", "/usr/local/bin/sandboxed-sh-prod"], text=True).split()
    pid = pids[0]
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
    def __init__(self, base_url, bearer_token, timeout_secs=10.0):
        self.base_url = base_url.rstrip("/")
        self.bearer_token = bearer_token
        self.timeout_secs = max(1.0, float(timeout_secs))

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
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_secs) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as exc:
            if isinstance(exc, TimeoutError) or "timed out" in str(exc).lower():
                raise RuntimeError(
                    f"core API {method} {path} timed out after {self.timeout_secs}s: {exc}"
                ) from exc
            raise

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

    def daemon_reload(self):
        subprocess.run(["systemctl", "daemon-reload"], check=False)


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


def _is_zombie(pid):
    """True when /proc/<pid>/stat reports state Z (exited, not yet reaped)."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return True  # already gone
    return stat[stat.rfind(")") + 2:].startswith("Z")


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
            # A defunct (zombie) child has finished; it only waits to be reaped and would
            # otherwise hold the drain open until the worker restarts.
            busy += len([ln for ln in child_res.stdout.split() if ln.strip() and not _is_zombie(ln.strip())])

    privd_pid_res = subprocess.run(
        ["systemctl", "show", "--property=MainPID", "--value", "orb-privd"],
        capture_output=True,
        text=True,
        check=False,
    )
    privd_pid = privd_pid_res.stdout.strip()
    if privd_pid_res.returncode == 0 and privd_pid.isdigit() and int(privd_pid) > 0:
        privd_children = subprocess.run(["pgrep", "-P", privd_pid], capture_output=True, text=True, check=False)
        if privd_children.returncode == 0 and privd_children.stdout.strip():
            busy += len([ln for ln in privd_children.stdout.split() if ln.strip() and not _is_zombie(ln.strip())])

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
    mcp_binary_path=None,
    privd_binary_path=None,
    build_conf_path=None,
    expected_build_sha=None,
    expected_sha256=None,
    include_metadata=False,
):
    """Return dict with keys staged, running, healthy, quarantined (plus optional build/sha256 metadata)."""
    ctl = service_ctl or SystemdServiceCtl()
    targets = _build_worker_unit_targets(
        db_path=db_path,
        binary_path=binary_path,
        unit_name=unit_name,
        runtime_busy_probe=runtime_busy_probe,
        live_work_dir_probe=live_work_dir_probe,
        sibling_units_probe=sibling_units_probe,
    )
    node_path, mcp_path, privd_path = _resolve_companion_paths(
        binary_path=binary_path,
        mcp_binary_path=mcp_binary_path,
        privd_binary_path=privd_binary_path,
    )
    comp_paths = [("sandboxed-node", node_path)]
    if mcp_path is not None:
        comp_paths.append(("sandboxed-mcp", mcp_path))
    if privd_path is not None:
        comp_paths.append(("orb-privd", privd_path))

    staged = any(Path(str(p) + staged_suffix).exists() for (_name, p) in comp_paths)
    quarantined = (not staged) and any(
        Path(str(p) + staged_suffix + ".failed").exists() for (_name, p) in comp_paths
    )
    swap_journal = _default_swap_journal_path(node_path)
    swap_journal_pending = swap_journal.is_file()
    healthy = (not swap_journal_pending) and all(bool(ctl.is_active(u)) for (u, _db, _bp) in targets)

    db_running = 0
    runtime_running = 0
    for _u, target_db, target_busy in targets:
        if target_db is not None:
            con = sqlite3.connect(_sqlite_uri(target_db, "ro"), uri=True, timeout=5.0)
            try:
                db_running += _count_active_db_jobs(con)
            finally:
                con.close()
        if staged or include_metadata:
            runtime_running += int(target_busy())
    res = {
        "staged": staged,
        "running": max(db_running, runtime_running),
        "healthy": healthy,
        "quarantined": quarantined,
    }
    if swap_journal_pending:
        res["swap_journal_pending"] = True
    if include_metadata or expected_build_sha is not None or expected_sha256 is not None:
        resolved_conf = build_conf_path
        if resolved_conf is None and str(node_path) == "/usr/local/bin/sandboxed-node":
            resolved_conf = f"/etc/systemd/system/{_normalize_service_unit_name(unit_name)}.service.d/30-build.conf"
        binary_shas = {}
        staged_shas = {}
        for comp_name, comp_p in comp_paths:
            cur_sha = compute_file_sha256(comp_p)
            if cur_sha:
                binary_shas[comp_name] = cur_sha
            stg_sha = compute_file_sha256(str(comp_p) + staged_suffix)
            if stg_sha:
                staged_shas[comp_name] = stg_sha
        build_sha = _normalize_reported_build_sha(_read_build_conf_sha(resolved_conf))
        res["build_sha"] = build_sha
        res["binary_sha256"] = binary_shas
        if staged_shas:
            res["staged_sha256"] = staged_shas
        if expected_build_sha is not None or expected_sha256 is not None:
            sha_ok = (build_sha != "unknown") and (
                (expected_build_sha is None) or (build_sha == expected_build_sha)
            )
            bins_ok = True
            if expected_sha256:
                for comp_name, exp_hash in expected_sha256.items():
                    if exp_hash and binary_shas.get(comp_name, "").lower() != exp_hash.lower():
                        bins_ok = False
                        break
            res["on_target"] = bool(sha_ok and bins_ok and not staged and healthy and not quarantined)
    return res


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
    mcp_binary_path=None,
    privd_binary_path=None,
    privd_unit_name="orb-privd",
    build_conf_path=None,
    expected_build_sha=None,
    expected_sha256=None,
    health_check_probe=None,
):
    """Drain-verified, write-fenced atomic worker upgrade with automatic rollback.

    Verifies staged artifact SHA-256 checksums before stopping services, acquires
    an exclusive SQLite ``BEGIN IMMEDIATE`` transaction on ``jobs.db`` for the
    primary worker unit and any sibling worker units sharing ``binary_path``
    *before* the final zero-job / zero-lease check, swaps ``sandboxed-node``,
    ``sandboxed-mcp``, and ``orb-privd`` (plus ``30-build.conf`` when
    ``expected_build_sha`` is provided) atomically with ``.prev`` backups,
    verifies service activation and expected build health, and rolls back all
    components automatically on any failure.
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

    node_path, mcp_path, privd_path = _resolve_companion_paths(
        binary_path=binary_path,
        mcp_binary_path=mcp_binary_path,
        privd_binary_path=privd_binary_path,
    )
    swap_journal_path = _default_swap_journal_path(node_path)
    if swap_journal_path.is_file():
        _recover_swap_journal(swap_journal_path, service_ctl=ctl)

    comp_specs = [("sandboxed-node", node_path, True)]
    if mcp_path is not None:
        comp_specs.append(("sandboxed-mcp", mcp_path, False))
    if privd_path is not None:
        comp_specs.append(("orb-privd", privd_path, False))

    active_components = []
    mismatch_errors = []
    for comp_name, comp_bin, is_required in comp_specs:
        stg = Path(str(comp_bin) + staged_suffix)
        req_by_hash = bool(expected_sha256 and expected_sha256.get(comp_name))
        if stg.is_file() or is_required or req_by_hash:
            if not stg.is_file():
                raise RuntimeError(f"staged binary for {comp_name} does not exist: {stg}")
            if expected_sha256 and expected_sha256.get(comp_name):
                exp_hash = expected_sha256[comp_name].lower()
                actual_hash = compute_file_sha256(stg)
                if actual_hash != exp_hash:
                    mismatch_errors.append(
                        f"checksum mismatch for {comp_name} ({stg}): expected {exp_hash}, got {actual_hash}"
                    )
            active_components.append(
                {
                    "name": comp_name,
                    "bin": Path(comp_bin),
                    "staged": stg,
                    "failed": Path(str(comp_bin) + staged_suffix + ".failed"),
                    "backup": Path(str(comp_bin) + backup_suffix),
                    "installing": Path(str(comp_bin) + ".installing"),
                    "restoring": Path(str(comp_bin) + ".restoring"),
                    "had_existing": Path(comp_bin).is_file(),
                    "prev_sha256": compute_file_sha256(comp_bin) if Path(comp_bin).is_file() else None,
                    "staged_sha256": compute_file_sha256(stg),
                }
            )
    if mismatch_errors:
        for comp in active_components:
            try:
                if comp["staged"].exists():
                    os.replace(comp["staged"], comp["failed"])
            except OSError:
                pass
        raise RuntimeError("; ".join(mismatch_errors))

    resolved_build_conf = None
    if build_conf_path is not None:
        resolved_build_conf = Path(build_conf_path)
    elif expected_build_sha and str(node_path) == "/usr/local/bin/sandboxed-node":
        resolved_build_conf = Path(
            f"/etc/systemd/system/{_normalize_service_unit_name(unit_name)}.service.d/30-build.conf"
        )
    prev_build_sha = _read_build_conf_sha(resolved_build_conf) if resolved_build_conf else None
    manage_privd_unit = any(c["name"] == "orb-privd" for c in active_components) and bool(privd_unit_name)
    privd_was_active = bool(ctl.is_active(privd_unit_name)) if manage_privd_unit else False
    units_were_active = {target_unit: bool(ctl.is_active(target_unit)) for (target_unit, _db, _bp) in targets}

    def _restore_components(comps, quarantine=False):
        restore_errors = []
        for comp in reversed(comps):
            cname = comp.get("name", str(comp.get("bin")))
            try:
                if comp.get("had_existing", True):
                    if not comp["backup"].is_file():
                        restore_errors.append(
                            f"{cname}: missing backup {comp['backup']}"
                        )
                    else:
                        shutil.copy2(comp["backup"], comp["restoring"])
                        os.chmod(comp["restoring"], 0o755)
                        os.replace(comp["restoring"], comp["bin"])
                        exp_prev = comp.get("prev_sha256")
                        got_prev = compute_file_sha256(comp["bin"])
                        if exp_prev and got_prev != exp_prev.lower():
                            restore_errors.append(
                                f"{cname}: restored sha256 {got_prev} != expected {exp_prev}"
                            )
                        elif not comp["bin"].is_file():
                            restore_errors.append(
                                f"{cname}: restored binary {comp['bin']} missing after replace"
                            )
                else:
                    comp["bin"].unlink(missing_ok=True)
                    if comp["bin"].exists():
                        restore_errors.append(
                            f"{cname}: failed removing newly-installed {comp['bin']}"
                        )
            except Exception as err:
                restore_errors.append(f"{cname}: {err}")
            finally:
                try:
                    comp["restoring"].unlink(missing_ok=True)
                except OSError:
                    pass
            if quarantine:
                try:
                    if comp["staged"].exists():
                        os.replace(comp["staged"], comp["failed"])
                except Exception as q_err:
                    restore_errors.append(f"{cname} quarantine: {q_err}")
        if resolved_build_conf and expected_build_sha:
            try:
                if prev_build_sha is not None:
                    _write_build_conf_sha(resolved_build_conf, prev_build_sha)
                    if _read_build_conf_sha(resolved_build_conf) != prev_build_sha:
                        restore_errors.append(
                            f"build_conf {resolved_build_conf}: restored sha mismatch"
                        )
                else:
                    resolved_build_conf.unlink(missing_ok=True)
                    if resolved_build_conf.exists():
                        restore_errors.append(
                            f"build_conf {resolved_build_conf}: failed unlinking"
                        )
                if hasattr(ctl, "daemon_reload"):
                    ctl.daemon_reload()
            except Exception as conf_err:
                restore_errors.append(f"build_conf {resolved_build_conf}: {conf_err}")
        return restore_errors

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
            if privd_was_active:
                ctl.stop(privd_unit_name)
                stopped_units.append(privd_unit_name)
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
            for u in reversed(stopped_units):
                ctl.start_best_effort(u)
            raise RuntimeError(f"failed stopping worker service before binary swap: {stop_err}") from stop_err

        # Copy staged binaries and backups first, record a durable swap journal, and only then
        # perform the renames so any crash mid-swap is deterministically recovered before start.
        replaced_comps = []
        try:
            for comp in active_components:
                comp["bin"].parent.mkdir(parents=True, exist_ok=True)
                if comp["bin"].is_file():
                    shutil.copy2(comp["bin"], comp["backup"])
                    _fsync_file_and_dir(comp["backup"])
                shutil.copy2(comp["staged"], comp["installing"])
                os.chmod(comp["installing"], 0o755)
                _fsync_file_and_dir(comp["installing"])
            guard_units = [u for u, _db, _bp in targets]
            if manage_privd_unit:
                guard_units.append(privd_unit_name)
            for guard_unit in guard_units:
                guard_build_conf = resolved_build_conf
                if guard_unit != unit_name and resolved_build_conf is not None:
                    guard_build_conf = (resolved_build_conf.parent.parent /
                        f"{_normalize_service_unit_name(guard_unit)}.service.d/30-build.conf")
                _install_start_guard(
                    binary_path=node_path,
                    journal_path=swap_journal_path,
                    build_conf_path=guard_build_conf,
                    unit_name=guard_unit,
                    service_ctl=ctl,
                )
            _write_swap_journal(
                swap_journal_path,
                active_components=active_components,
                build_conf_path=resolved_build_conf if (resolved_build_conf and expected_build_sha) else None,
                prev_build_sha=prev_build_sha,
            )
            for comp in active_components:
                os.replace(comp["installing"], comp["bin"])
                replaced_comps.append(comp)
            if resolved_build_conf and expected_build_sha:
                _write_build_conf_sha(resolved_build_conf, expected_build_sha)
                if hasattr(ctl, "daemon_reload"):
                    ctl.daemon_reload()
            swap_journal_path.unlink(missing_ok=True)
            _fsync_file_and_dir(swap_journal_path)
        except Exception as swap_err:
            for comp in active_components:
                try:
                    comp["installing"].unlink(missing_ok=True)
                except OSError:
                    pass
            for entry in reversed(fences):
                if entry[3]:
                    try:
                        entry[2].execute("ROLLBACK")
                    except Exception:
                        pass
                    entry[3] = False
                try:
                    entry[2].close()
                except Exception:
                    pass
                _restore_db_ownership(entry[0], entry[1])
            fences.clear()
            restore_errors = _restore_components(replaced_comps, quarantine=False)
            if not restore_errors:
                swap_journal_path.unlink(missing_ok=True)
            if privd_was_active:
                ctl.start_best_effort(privd_unit_name)
                if not ctl.is_active(privd_unit_name):
                    restore_errors.append(f"{privd_unit_name}: inactive after rollback start")
            for target_unit, _db, _bp in targets:
                ctl.start_best_effort(target_unit)
                if units_were_active.get(target_unit, True) and not ctl.is_active(target_unit):
                    restore_errors.append(f"{target_unit}: inactive after rollback start")
            if restore_errors:
                return f"ROLLBACK_FAILED:swap error ({swap_err}); rollback errors: {'; '.join(restore_errors)}"
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
        if privd_was_active:
            ctl.start(privd_unit_name)
            if not ctl.is_active(privd_unit_name):
                raise RuntimeError(f"{privd_unit_name} failed post-start is-active check")
        for target_unit, _db, _bp in targets:
            ctl.start(target_unit)
            if not ctl.is_active(target_unit):
                raise RuntimeError(f"{target_unit} failed post-start is-active check")
        hc_fn = health_check_probe
        if hc_fn is None and (expected_build_sha is not None or expected_sha256 is not None):
            hc_fn = lambda: _default_health_check_probe(
                unit_name=unit_name,
                expected_build_sha=expected_build_sha,
                expected_sha256=expected_sha256,
                build_conf_path=resolved_build_conf,
            )
        if hc_fn is not None:
            sig = inspect.signature(hc_fn).parameters
            if len(sig) >= 2:
                hc_res = hc_fn(expected_build_sha, expected_sha256)
            elif len(sig) == 1:
                hc_res = hc_fn(expected_build_sha)
            else:
                hc_res = hc_fn()
            if isinstance(hc_res, tuple) and len(hc_res) == 2:
                ok, msg = hc_res
                if not ok:
                    raise RuntimeError(msg or "post-start health check failed")
            elif isinstance(hc_res, bool) and not hc_res:
                raise RuntimeError("post-start health check probe returned False")
            elif isinstance(hc_res, dict):
                if not hc_res.get("ok", True):
                    raise RuntimeError(f"post-start health check failed: {hc_res}")
                rep_sha = hc_res.get("build_sha") or hc_res.get("build")
                if expected_build_sha and rep_sha != expected_build_sha:
                    raise RuntimeError(
                        f"post-start build mismatch: reported {rep_sha!r} != expected {expected_build_sha!r}"
                    )
                rep_bins = hc_res.get("binary_sha256")
                if expected_sha256:
                    if not isinstance(rep_bins, dict):
                        raise RuntimeError("post-start health check missing binary_sha256 map")
                    for c_name, exp_h in expected_sha256.items():
                        if not exp_h:
                            continue
                        got_h = rep_bins.get(c_name)
                        if not got_h or not isinstance(got_h, str):
                            raise RuntimeError(
                                f"post-start {c_name} sha256 missing in binary_sha256 (expected {exp_h})"
                            )
                        if got_h.lower() != exp_h.lower():
                            raise RuntimeError(
                                f"post-start {c_name} sha256 mismatch: reported {got_h} != expected {exp_h}"
                            )
            elif expected_build_sha is not None or expected_sha256:
                raise RuntimeError("post-start health check returned no build_sha/binary_sha256 metadata")
    except Exception as act_err:
        restore_errors = _restore_components(active_components, quarantine=True)
        if not restore_errors:
            swap_journal_path.unlink(missing_ok=True)
        if privd_was_active:
            ctl.restart_best_effort(privd_unit_name)
            if not ctl.is_active(privd_unit_name):
                restore_errors.append(f"{privd_unit_name}: inactive after rollback restart")
        for target_unit, _db, _bp in targets:
            ctl.restart_best_effort(target_unit)
            if units_were_active.get(target_unit, True) and not ctl.is_active(target_unit):
                restore_errors.append(f"{target_unit}: inactive after rollback restart")
        if restore_errors:
            return f"ROLLBACK_FAILED:activation error ({act_err}); rollback errors: {'; '.join(restore_errors)}"
        primary_backup = active_components[0]["backup"]
        primary_failed = active_components[0]["failed"]
        raise RuntimeError(
            f"activation failed; rolled back to {primary_backup} and quarantined {primary_failed}: {act_err}"
        ) from act_err

    # 4. Verified active! Consume staged artifacts, clear any prior failure markers, and remove swap journal.
    swap_journal_path.unlink(missing_ok=True)
    for comp in active_components:
        comp["staged"].unlink(missing_ok=True)
        comp["failed"].unlink(missing_ok=True)
    return "UPGRADED"


def recover_worker_state(
    binary_path="/usr/local/bin/sandboxed-node",
    staged_suffix=".new",
    unit_name="sandboxed-node",
    service_ctl=None,
    mcp_binary_path=None,
    privd_binary_path=None,
):
    ctl = service_ctl or SystemdServiceCtl()
    node_path, mcp_path, privd_path = _resolve_companion_paths(
        binary_path=binary_path,
        mcp_binary_path=mcp_binary_path,
        privd_binary_path=privd_binary_path,
    )
    swap_journal_path = _default_swap_journal_path(node_path)
    journal_recovered = False
    if swap_journal_path.is_file():
        journal_recovered = bool(_recover_swap_journal(swap_journal_path, service_ctl=ctl))
    cleared = []
    for comp_bin in (node_path, mcp_path, privd_path):
        if comp_bin is None:
            continue
        for suffix in (staged_suffix, staged_suffix + ".failed", ".installing", ".restoring"):
            cand = Path(str(comp_bin) + suffix)
            if cand.exists():
                cand.unlink(missing_ok=True)
                cleared.append(str(cand))
    if not ctl.is_active(unit_name):
        ctl.restart_best_effort(unit_name)
    return {
        "journal_recovered": journal_recovered,
        "cleared_artifacts": cleared,
        "healthy": bool(ctl.is_active(unit_name)),
    }


def _remote_worker_prelude():
    parts = [
        "import hashlib, inspect, json, os, pathlib, shutil, sqlite3, subprocess, sys, time, urllib.request",
        "from pathlib import Path",
        inspect.getsource(compute_file_sha256),
        inspect.getsource(_resolve_companion_paths),
        inspect.getsource(_normalize_reported_build_sha),
        inspect.getsource(_read_build_conf_sha),
        inspect.getsource(_write_build_conf_sha),
        inspect.getsource(_default_swap_journal_path),
        inspect.getsource(_fsync_file_and_dir),
        inspect.getsource(_write_swap_journal),
        inspect.getsource(_recover_swap_journal),
        inspect.getsource(_default_start_guard_script_path),
        inspect.getsource(_default_start_guard_conf_path),
        inspect.getsource(_render_start_guard_script),
        inspect.getsource(_install_start_guard),
        inspect.getsource(run_start_guard),
        inspect.getsource(SystemdServiceCtl),
        inspect.getsource(_parse_simple_env_file),
        inspect.getsource(_read_proc_environ),
        inspect.getsource(_restore_db_ownership),
        inspect.getsource(_normalize_service_unit_name),
        inspect.getsource(_discover_unit_env_files),
        inspect.getsource(_load_unit_env_files),
        inspect.getsource(_is_zombie),
        inspect.getsource(_default_health_check_probe),
        inspect.getsource(default_runtime_busy_probe),
        inspect.getsource(_discover_live_work_dir),
        inspect.getsource(_discover_sibling_units),
        inspect.getsource(_resolve_worker_ledger),
        inspect.getsource(_sqlite_uri),
        inspect.getsource(_count_active_db_jobs),
        inspect.getsource(_build_worker_unit_targets),
        inspect.getsource(probe_worker_state),
        inspect.getsource(perform_fenced_upgrade),
        inspect.getsource(recover_worker_state),
    ]
    return "\n\n".join(parts)


class SshNodeOps:
    def __init__(
        self,
        ssh_config=None,
        staged_suffix=".new",
        backup_suffix=".prev",
        verify_delay_secs=2.0,
        expected_build_sha=None,
        expected_sha256=None,
        ssh_timeout_secs=30.0,
    ):
        self.ssh_config = ssh_config
        self.staged_suffix = staged_suffix
        self.backup_suffix = backup_suffix
        self.verify_delay_secs = float(verify_delay_secs)
        self.expected_build_sha = expected_build_sha
        self.expected_sha256 = dict(expected_sha256) if expected_sha256 else None
        self.ssh_timeout_secs = max(1.0, float(ssh_timeout_secs))

    def _ssh_base_cmd(self, host):
        connect_timeout = max(1, min(8, int(self.ssh_timeout_secs)))
        alive_interval = max(1, min(5, int(self.ssh_timeout_secs)))
        cmd = ["ssh"]
        if self.ssh_config:
            cmd.extend(["-F", str(self.ssh_config)])
        cmd.extend(
            [
                "-o",
                "BatchMode=yes",
                "-o",
                f"ConnectTimeout={connect_timeout}",
                "-o",
                f"ServerAliveInterval={alive_interval}",
                "-o",
                "ServerAliveCountMax=2",
                host,
            ]
        )
        return cmd

    def _ssh_python(self, host, code, timeout=None):
        eff_timeout = float(timeout) if timeout is not None else self.ssh_timeout_secs
        cmd = self._ssh_base_cmd(host) + ["sudo python3 -"]
        try:
            res = subprocess.run(cmd, input=code, capture_output=True, text=True, timeout=eff_timeout)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                f"ssh {host} timed out after {eff_timeout:g}s (host may answer ping while SSH/API is hung)"
            ) from exc
        if res.returncode != 0:
            raise RuntimeError(f"ssh {host} failed: {res.stderr.strip()}")
        return res.stdout.strip()

    def stage_remote(self, host, artifact_paths, expected_sha256=None):
        """Copy local artifacts to <remote_path>.new on host and verify SHA-256 on the node."""
        exp_map = dict(expected_sha256 or self.expected_sha256 or {})
        for comp_name, (local_src, remote_dst) in artifact_paths.items():
            src_p = Path(local_src)
            if not src_p.is_file():
                raise RuntimeError(f"local artifact for {comp_name} does not exist: {src_p}")
            local_hash = compute_file_sha256(src_p)
            exp_hash = exp_map.get(comp_name) or local_hash
            if local_hash != exp_hash.lower():
                raise RuntimeError(
                    f"local {comp_name} sha256 mismatch before staging: expected {exp_hash}, got {local_hash}"
                )
            staged_remote = f"{remote_dst}{self.staged_suffix}"
            install_script = (
                "import hashlib, os, pathlib, sys\n"
                f"dst = pathlib.Path({staged_remote!r})\n"
                "tmp = pathlib.Path(str(dst) + '.uploading')\n"
                "dst.parent.mkdir(parents=True, exist_ok=True)\n"
                "data = sys.stdin.buffer.read()\n"
                "got = hashlib.sha256(data).hexdigest()\n"
                f"exp = {exp_hash.lower()!r}\n"
                "if got != exp:\n"
                "    raise SystemExit(f'sha256 mismatch on remote stage: expected {exp}, got {got}')\n"
                "tmp.write_bytes(data)\n"
                "os.chmod(tmp, 0o755)\n"
                "os.replace(tmp, dst)\n"
                "print(got)\n"
            )
            cmd = self._ssh_base_cmd(host) + [f"sudo python3 -c {shlex.quote(install_script)}"]
            stage_timeout = max(30.0, self.ssh_timeout_secs * 4.0)
            try:
                with open(src_p, "rb") as handle:
                    res = subprocess.run(cmd, stdin=handle, capture_output=True, timeout=stage_timeout)
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError(
                    f"staging {comp_name} on {host} timed out after {stage_timeout:g}s"
                ) from exc
            if res.returncode != 0:
                err = res.stderr.decode("utf-8", "replace").strip()
                raise RuntimeError(f"staging {comp_name} on {host} failed: {err}")

    def probe_remote(self, host, db_path, binary_path="/usr/local/bin/sandboxed-node", include_metadata=False):
        inc = bool(include_metadata or self.expected_build_sha or self.expected_sha256)
        code = (
            _remote_worker_prelude()
            + "\nprint(json.dumps(probe_worker_state("
            + f"{db_path!r}, binary_path={binary_path!r}, staged_suffix={self.staged_suffix!r}, "
            + f"expected_build_sha={self.expected_build_sha!r}, expected_sha256={self.expected_sha256!r}, "
            + f"include_metadata={inc!r}"
            + ")))\n"
        )
        out = self._ssh_python(host, code)
        return json.loads(out.splitlines()[-1])

    def upgrade_remote(self, host, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        code = (
            _remote_worker_prelude()
            + "\nprint(perform_fenced_upgrade("
            + f"{db_path!r}, binary_path={binary_path!r}, staged_suffix={self.staged_suffix!r}, "
            + f"backup_suffix={self.backup_suffix!r}, verify_delay_secs={self.verify_delay_secs!r}, "
            + f"expected_build_sha={self.expected_build_sha!r}, expected_sha256={self.expected_sha256!r}"
            + "))\n"
        )
        out = self._ssh_python(host, code, timeout=max(45, int(self.verify_delay_secs) + 30))
        return out.splitlines()[-1]

    def recover_remote(self, host, binary_path="/usr/local/bin/sandboxed-node"):
        code = (
            _remote_worker_prelude()
            + "\nprint(json.dumps(recover_worker_state("
            + f"binary_path={binary_path!r}, staged_suffix={self.staged_suffix!r}"
            + ")))\n"
        )
        out = self._ssh_python(host, code, timeout=45)
        return json.loads(out.splitlines()[-1])

    def probe_local(self, db_path, binary_path="/usr/local/bin/sandboxed-node", include_metadata=False):
        inc = bool(include_metadata or self.expected_build_sha or self.expected_sha256)
        return probe_worker_state(
            db_path=db_path,
            binary_path=binary_path,
            staged_suffix=self.staged_suffix,
            expected_build_sha=self.expected_build_sha,
            expected_sha256=self.expected_sha256,
            include_metadata=inc,
        )

    def upgrade_local(self, db_path, binary_path="/usr/local/bin/sandboxed-node"):
        return perform_fenced_upgrade(
            db_path=db_path,
            binary_path=binary_path,
            staged_suffix=self.staged_suffix,
            backup_suffix=self.backup_suffix,
            verify_delay_secs=self.verify_delay_secs,
            expected_build_sha=self.expected_build_sha,
            expected_sha256=self.expected_sha256,
        )

    def stop_timer(self, unit_name):
        subprocess.run(["systemctl", "stop", unit_name], check=False)


def _normalize_probe_result(raw, expected_build_sha=None, expected_sha256=None):
    """Accept dict or legacy (staged, running[, healthy[, quarantined]]) tuple."""
    if isinstance(raw, dict):
        staged = bool(raw["staged"])
        running = int(raw["running"])
        healthy = bool(raw.get("healthy", True))
        quarantined = bool(raw.get("quarantined", False))
        if "on_target" in raw:
            on_target = bool(raw["on_target"])
        elif expected_build_sha is not None or expected_sha256 is not None:
            rep_sha = _normalize_reported_build_sha(raw.get("build_sha") or raw.get("build"))
            sha_ok = (rep_sha != "unknown") and (
                (expected_build_sha is None) or (rep_sha == expected_build_sha)
            )
            bins_ok = True
            rep_bins = raw.get("binary_sha256")
            if expected_sha256:
                if not isinstance(rep_bins, dict):
                    bins_ok = False
                else:
                    for comp_name, exp_h in expected_sha256.items():
                        if exp_h and rep_bins.get(comp_name, "").lower() != exp_h.lower():
                            bins_ok = False
                            break
            on_target = bool(sha_ok and bins_ok and healthy and not quarantined and not staged)
        else:
            on_target = False
        return staged, running, healthy, quarantined, on_target
    staged = bool(raw[0])
    running = int(raw[1])
    healthy = bool(raw[2]) if len(raw) > 2 else True
    quarantined = bool(raw[3]) if len(raw) > 3 else False
    on_target = bool(raw[4]) if len(raw) > 4 else False
    return staged, running, healthy, quarantined, on_target


def collect_fleet_rollout_status(
    core_api,
    node_ops,
    remote_nodes=(),
    local_jobs_db=None,
    expected_build_sha=None,
    expected_sha256=None,
    cordon_ledger_path=DEFAULT_CORDON_LEDGER_PATH,
):
    """Return per-node reported build/checksums vs target build/checksums."""
    nodes_list = core_api.list_nodes()
    core_by_id = {n["id"]: n for n in nodes_list}
    cordon_ledger = load_cordon_ledger(cordon_ledger_path)
    rows = []

    target_hosts = list(remote_nodes)
    if not target_hosts:
        target_hosts = [(n["id"], None) for n in nodes_list if not n.get("ephemeral", False)]

    for host, db_path in target_hosts:
        core_info = core_by_id.get(host, {})
        hb = core_info.get("heartbeat") if isinstance(core_info.get("heartbeat"), dict) else {}
        probe_data = {}
        probe_err = None
        if node_ops is not None:
            try:
                if "include_metadata" in inspect.signature(node_ops.probe_remote).parameters:
                    probe_data = node_ops.probe_remote(host, db_path, include_metadata=True)
                else:
                    probe_data = node_ops.probe_remote(host, db_path)
                if not isinstance(probe_data, dict):
                    s, r, h, q, ot = _normalize_probe_result(probe_data)
                    probe_data = {"staged": s, "running": r, "healthy": h, "quarantined": q, "on_target": ot}
            except Exception as exc:
                probe_err = str(exc)

        raw_reported_build = None
        for cand_build in (
            probe_data.get("build_sha"),
            hb.get("build_sha"),
            hb.get("build"),
            core_info.get("build_sha"),
            core_info.get("build"),
        ):
            norm_b = _normalize_reported_build_sha(cand_build)
            if norm_b != "unknown":
                raw_reported_build = norm_b
                break
        reported_build = raw_reported_build or "unknown"
        reported_bins = (
            probe_data.get("binary_sha256")
            or hb.get("binary_sha256")
            or core_info.get("binary_sha256")
            or {}
        )
        staged = bool(probe_data.get("staged", False))
        quarantined = bool(probe_data.get("quarantined", False))
        healthy = False if probe_err is not None else bool(probe_data.get("healthy", core_info.get("status") == "online"))
        running = int(probe_data.get("running", hb.get("active_jobs", 0)))
        cordoned = bool(core_info.get("cordoned", False))
        cordon_meta = cordon_ledger.get(host) if isinstance(cordon_ledger, dict) else None
        cordoned_by = (
            (cordon_meta.get("cordoned_by") if isinstance(cordon_meta, dict) else None)
            or core_info.get("cordoned_by")
        )

        sha_matches = (reported_build != "unknown") and (
            (expected_build_sha is None) or (reported_build == expected_build_sha)
        )
        bins_match = True
        mismatched_components = []
        if expected_sha256:
            for comp_name, exp_h in expected_sha256.items():
                if not exp_h:
                    continue
                got_h = reported_bins.get(comp_name) if isinstance(reported_bins, dict) else None
                if not got_h or got_h.lower() != exp_h.lower():
                    bins_match = False
                    mismatched_components.append(comp_name)

        on_target = bool(
            probe_err is None
            and (expected_build_sha is not None or expected_sha256 is not None)
            and sha_matches
            and bins_match
            and healthy
            and not quarantined
            and not staged
        )
        if probe_err is not None:
            state = "probe_error"
        elif quarantined:
            state = "quarantined"
        elif not healthy:
            state = "unhealthy"
        elif on_target:
            state = "on_target"
        elif staged and cordoned:
            state = "draining"
        elif staged:
            state = "staged"
        elif expected_build_sha is not None or expected_sha256 is not None:
            state = "outdated"
        else:
            state = "healthy"

        row = {
            "node": host,
            "state": state,
            "cordoned": cordoned,
            "cordoned_by": cordoned_by if cordoned else None,
            "healthy": healthy,
            "quarantined": quarantined,
            "staged": staged,
            "running_jobs": running,
            "reported_build_sha": reported_build,
            "target_build_sha": expected_build_sha,
            "reported_binary_sha256": reported_bins,
            "target_binary_sha256": expected_sha256 or {},
            "mismatched_components": mismatched_components,
            "on_target": on_target,
        }
        if probe_err is not None:
            row["error"] = probe_err
        rows.append(row)

    if local_jobs_db and node_ops is not None:
        try:
            if "include_metadata" in inspect.signature(node_ops.probe_local).parameters:
                lp = node_ops.probe_local(local_jobs_db, include_metadata=True)
            else:
                lp = node_ops.probe_local(local_jobs_db)
            if not isinstance(lp, dict):
                s, r, h, q, ot = _normalize_probe_result(lp)
                lp = {"staged": s, "running": r, "healthy": h, "quarantined": q, "on_target": ot}
            rep_b = _normalize_reported_build_sha(lp.get("build_sha"))
            rep_bins = lp.get("binary_sha256") or {}
            sha_ok = (rep_b != "unknown") and (
                (expected_build_sha is None) or (rep_b == expected_build_sha)
            )
            bins_ok = True
            mm = []
            if expected_sha256:
                for comp_name, exp_h in expected_sha256.items():
                    if exp_h and rep_bins.get(comp_name, "").lower() != exp_h.lower():
                        bins_ok = False
                        mm.append(comp_name)
            on_t = bool(
                (expected_build_sha is not None or expected_sha256 is not None)
                and sha_ok
                and bins_ok
                and lp.get("healthy", True)
                and not lp.get("quarantined", False)
                and not lp.get("staged", False)
            )
            rows.append(
                {
                    "node": "local",
                    "state": "on_target" if on_t else ("staged" if lp.get("staged") else "healthy"),
                    "cordoned": False,
                    "healthy": bool(lp.get("healthy", True)),
                    "quarantined": bool(lp.get("quarantined", False)),
                    "staged": bool(lp.get("staged", False)),
                    "running_jobs": int(lp.get("running", 0)),
                    "reported_build_sha": rep_b,
                    "target_build_sha": expected_build_sha,
                    "reported_binary_sha256": rep_bins,
                    "target_binary_sha256": expected_sha256 or {},
                    "mismatched_components": mm,
                    "on_target": on_t,
                }
            )
        except Exception as exc:
            rows.append({"node": "local", "state": "probe_error", "error": str(exc), "on_target": False})

    return rows


def rolling_upgrade_step(
    core_api,
    node_ops,
    remote_nodes,
    local_jobs_db=None,
    max_concurrent_cordons=1,
    apply=False,
    stop_timer_unit=None,
    PreserveCordons=frozenset(),
    stage_artifacts=None,
    expected_build_sha=None,
    expected_sha256=None,
    cordon_owner=DEFAULT_CORDON_OWNER,
    cordon_ledger_path=DEFAULT_CORDON_LEDGER_PATH,
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
                clear_cordon_owner(host, cordon_ledger_path)
            emit("upgraded_remote", node=host, uncordoned=(host not in PreserveCordons))
            return True
        if str(outcome).startswith("ROLLBACK_FAILED"):
            upgrade_failures += 1
            emit("rollback_failed", node=host, error=str(outcome))
            return False
        emit("upgrade_deferred", node=host, detail=outcome)
        return False

    for host, db_path in remote_nodes:
        try:
            raw_probe = node_ops.probe_remote(host, db_path)
            staged, running, healthy, quarantined, on_target = _normalize_probe_result(
                raw_probe, expected_build_sha=expected_build_sha, expected_sha256=expected_sha256
            )
        except Exception as error:
            probe_errors += 1
            emit("probe_error", node=host, error=str(error))
            pending_remotes.append((host, db_path, -1))
            if cordoned_map.get(host, False):
                currently_cordoned_pending.append(host)
            continue

        if not staged and on_target and not quarantined and healthy:
            if cordoned_map.get(host, False) and host not in PreserveCordons:
                if apply:
                    core_api.set_cordon(host, False)
                    cordoned_map[host] = False
                    clear_cordon_owner(host, cordon_ledger_path)
                emit("uncordoned_completed_node", node=host)
            else:
                emit(
                    "already_on_target",
                    node=host,
                    build_sha=(raw_probe.get("build_sha") if isinstance(raw_probe, dict) else expected_build_sha),
                )
            continue

        if not healthy:
            upgrade_failures += 1
            pending_remotes.append((host, db_path, -1))
            if cordoned_map.get(host, False):
                currently_cordoned_pending.append(host)
            emit("unhealthy_node", node=host, healthy=False)
            continue

        if (
            not staged
            and stage_artifacts
            and not quarantined
            and healthy
            and upgrade_failures == 0
            and probe_errors == 0
            and len(pending_remotes) < max_concurrent_cordons
        ):
            if apply and hasattr(node_ops, "stage_remote"):
                try:
                    sig = inspect.signature(node_ops.stage_remote).parameters
                    if "expected_sha256" in sig:
                        node_ops.stage_remote(host, stage_artifacts, expected_sha256=expected_sha256)
                    else:
                        node_ops.stage_remote(host, stage_artifacts)
                    staged = True
                    emit("staged_remote", node=host, components=sorted(stage_artifacts.keys()))
                except Exception as stage_err:
                    upgrade_failures += 1
                    pending_remotes.append((host, db_path, -1))
                    emit("stage_failed", node=host, error=str(stage_err))
                    continue
            elif not apply:
                staged = True
                emit("would_stage_remote", node=host, components=sorted(stage_artifacts.keys()))
        elif not staged and stage_artifacts and not quarantined and healthy:
            pending_remotes.append((host, db_path, running))
            emit("pending_wave", node=host, running_jobs=running)
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
                    clear_cordon_owner(host, cordon_ledger_path)
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
            clear_cordon_owner(excess, cordon_ledger_path)
        emit("uncordoned_excess_wave", node=excess)

    # Advance cordons only when all remote probes and prior upgrades succeeded (fail-closed)
    slots = max_concurrent_cordons - len(currently_cordoned_pending)
    if slots > 0 and probe_errors == 0 and upgrade_failures == 0:
        if max_concurrent_cordons == 1:
            candidates = [
                (running, host, db_path)
                for (host, db_path, running) in pending_remotes
                if running >= 0 and not cordoned_map.get(host, False)
            ]
        else:
            candidates = sorted(
                (running, host, db_path)
                for (host, db_path, running) in pending_remotes
                if running >= 0 and not cordoned_map.get(host, False)
            )
        for running, host, db_path in candidates[:slots]:
            if upgrade_failures > 0:
                break
            if apply:
                core_api.set_cordon(host, True)
                cordoned_map[host] = True
                record_cordon_owner(
                    host,
                    cordoned_by=cordon_owner,
                    reason="rolling_upgrade_drain",
                    target_build_sha=expected_build_sha,
                    ledger_path=cordon_ledger_path,
                )
            emit("cordoned_for_drain", node=host, running_jobs=running, cordoned_by=cordon_owner)
            if running == 0:
                if apply:
                    if try_upgrade_remote(host, db_path):
                        pending_remotes = [p for p in pending_remotes if p[0] != host]
                else:
                    emit("would_upgrade_remote", node=host)

    local_pending = False
    if local_jobs_db:
        try:
            raw_local = node_ops.probe_local(local_jobs_db)
            staged, running, healthy, quarantined, on_target = _normalize_probe_result(
                raw_local, expected_build_sha=expected_build_sha, expected_sha256=expected_sha256
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
                elif on_target:
                    emit("already_on_target", node="local", build_sha=expected_build_sha)
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
                            elif str(outcome).startswith("ROLLBACK_FAILED"):
                                local_pending = True
                                emit("local_rollback_failed", error=str(outcome))
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


def recover_cordoned_node(
    core_api,
    node_ops,
    node_id,
    cordon_ledger_path=DEFAULT_CORDON_LEDGER_PATH,
    preserve_cordons=frozenset(),
    force_uncordon=False,
):
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    ledger = load_cordon_ledger(cordon_ledger_path)
    meta = ledger.get(node_id) if isinstance(ledger, dict) else None
    cordoned_by = meta.get("cordoned_by") if isinstance(meta, dict) else None
    worker_recovery = {}
    if node_ops is not None and hasattr(node_ops, "recover_remote"):
        worker_recovery = node_ops.recover_remote(node_id)
    uncordoned = False
    healthy = bool(worker_recovery.get("healthy", False))
    owns_cordon = cordoned_by == DEFAULT_CORDON_OWNER
    if node_id not in preserve_cordons and healthy and owns_cordon:
        core_api.set_cordon(node_id, False)
        clear_cordon_owner(node_id, cordon_ledger_path)
        uncordoned = True
    return {
        "at": now,
        "action": "recovered_node",
        "node": node_id,
        "cordoned_by": cordoned_by or DEFAULT_CORDON_OWNER,
        "uncordoned": uncordoned,
        "journal_recovered": bool(worker_recovery.get("journal_recovered", False)),
        "cleared_artifacts": list(worker_recovery.get("cleared_artifacts", [])),
        "healthy": healthy,
    }


def run_governed_rollout(
    core_api,
    node_ops,
    remote_nodes,
    local_jobs_db=None,
    max_concurrent_cordons=1,
    apply=False,
    stop_timer_unit=None,
    PreserveCordons=frozenset(),
    stage_artifacts=None,
    expected_build_sha=None,
    expected_sha256=None,
    drain_timeout_secs=0.0,
    poll_interval_secs=2.0,
    sleep_fn=time.sleep,
    clock_fn=time.monotonic,
    cordon_owner=DEFAULT_CORDON_OWNER,
    cordon_ledger_path=DEFAULT_CORDON_LEDGER_PATH,
):
    """Run rolling_upgrade_step (looping up to drain_timeout_secs while nodes drain)."""
    start_ts = clock_fn()
    all_events = []
    while True:
        step_events, done = rolling_upgrade_step(
            core_api=core_api,
            node_ops=node_ops,
            remote_nodes=remote_nodes,
            local_jobs_db=local_jobs_db,
            max_concurrent_cordons=max_concurrent_cordons,
            apply=apply,
            stop_timer_unit=stop_timer_unit,
            PreserveCordons=PreserveCordons,
            stage_artifacts=stage_artifacts,
            expected_build_sha=expected_build_sha,
            expected_sha256=expected_sha256,
            cordon_owner=cordon_owner,
            cordon_ledger_path=cordon_ledger_path,
        )
        all_events.extend(step_events)
        if done or not apply:
            return all_events, done
        failure_actions = {
            "probe_error",
            "stage_failed",
            "upgrade_failed",
            "rollback_failed",
            "upgrade_quarantined",
            "unhealthy_node",
            "local_probe_error",
            "local_upgrade_failed",
            "local_rollback_failed",
            "local_upgrade_quarantined",
            "unhealthy_local",
        }
        if any(ev["action"] in failure_actions for ev in step_events):
            return all_events, False
        if drain_timeout_secs <= 0:
            return all_events, done
        elapsed = clock_fn() - start_ts
        if elapsed >= drain_timeout_secs:
            draining_nodes = [ev["node"] for ev in step_events if ev["action"] == "draining"]
            now = dt.datetime.now(dt.timezone.utc).isoformat()
            all_events.append(
                {
                    "at": now,
                    "action": "drain_timeout",
                    "apply": bool(apply),
                    "nodes": draining_nodes,
                    "timeout_secs": drain_timeout_secs,
                }
            )
            return all_events, False
        sleep_fn(min(poll_interval_secs, max(0.01, drain_timeout_secs - elapsed)))


def parse_node_spec(raw):
    host, sep, db_path = raw.partition(":")
    if not host:
        raise ValueError(f"invalid --node spec: {raw!r}")
    return host, (db_path if sep and db_path else None)


def parse_sha256_spec(raw):
    name, sep, digest = str(raw).partition("=")
    name = name.strip()
    digest = digest.strip().lower()
    if not sep or not name or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError(f"invalid --expect-sha256 spec (expected NAME=64_HEX): {raw!r}")
    return name, digest


def build_stage_artifacts_from_dir(stage_dir, expected_sha256=None):
    base = Path(stage_dir)
    artifacts = {}
    computed = {}
    for comp_name, remote_dst in DEFAULT_ROLLOUT_BINARIES:
        src = base / comp_name
        if comp_name == "sandboxed-node" and not src.is_file():
            alt = base / "orb-node"
            if alt.is_file():
                src = alt
        if src.is_file():
            artifacts[comp_name] = (str(src), remote_dst)
            digest = compute_file_sha256(src)
            if digest:
                computed[comp_name] = digest
                if expected_sha256 and expected_sha256.get(comp_name):
                    if expected_sha256[comp_name].lower() != digest.lower():
                        raise RuntimeError(
                            f"local staged artifact {src} sha256 {digest} != expected {expected_sha256[comp_name]}"
                        )
    if "sandboxed-node" not in artifacts:
        raise RuntimeError(f"stage directory {base} is missing sandboxed-node (or orb-node)")
    return artifacts, computed


def main(argv=None):
    parser = argparse.ArgumentParser(description="Zero-disruption rolling upgrade for sandboxed-node fleet.")
    parser.add_argument(
        "--node",
        action="append",
        default=[],
        help="Remote worker as HOST or HOST:/path/to/jobs.db (repeatable; auto-discovered from Core if omitted)",
    )
    parser.add_argument("--local-jobs-db", help="Optional local runner jobs.db path on Core host")
    parser.add_argument("--ssh-config", default="/root/.config/sandboxed-sh/development-identity/current/ssh/config")
    parser.add_argument("--api-url", help="Core API base URL (auto-discovered from local process if omitted)")
    parser.add_argument("--token-env", default="SANDBOXED_API_TOKEN", help="Env var holding Core API bearer token")
    parser.add_argument("--staged-suffix", default=".new", help="Suffix of staged binary (default: .new)")
    parser.add_argument("--backup-suffix", default=".prev", help="Suffix for backup binary (default: .prev)")
    parser.add_argument("--max-concurrent-cordons", type=int, default=1)
    parser.add_argument("--verify-delay-secs", type=float, default=2.0)
    parser.add_argument("--ssh-timeout-secs", type=float, default=30.0, help="Bounded timeout in seconds for per-node SSH probes/commands")
    parser.add_argument("--api-timeout-secs", type=float, default=10.0, help="Bounded timeout in seconds for Core API requests")
    parser.add_argument("--drain-timeout-secs", type=float, default=0.0, help="Wait up to N seconds for cordoned nodes to drain")
    parser.add_argument("--poll-interval-secs", type=float, default=5.0, help="Seconds between drain poll ticks")
    parser.add_argument("--expected-build-sha", help="Expected 40-char ORB_BUILD_SHA after upgrade")
    parser.add_argument(
        "--expect-sha256",
        action="append",
        default=[],
        help="Expected binary digest as COMPONENT=SHA256 (repeatable)",
    )
    parser.add_argument(
        "--stage-from-dir",
        help="Directory holding built sandboxed-node, sandboxed-mcp, and orb-privd binaries to stage",
    )
    parser.add_argument("--preserve-cordon", action="append", default=[], help="Node IDs to keep cordoned after upgrade")
    parser.add_argument(
        "--recover-node",
        "--uncordon",
        dest="recover_nodes",
        action="append",
        default=[],
        help="Recover a node left cordoned or mid-swap after failure/SIGTERM (replays swap journal, clears quarantined/staged artifacts, and uncordons)",
    )
    parser.add_argument("--cordon-owner", default=DEFAULT_CORDON_OWNER, help="Owner label recorded when cordoning nodes")
    parser.add_argument("--cordon-ledger", default=DEFAULT_CORDON_LEDGER_PATH, help="Path to local cordon ownership ledger")
    parser.add_argument("--stop-timer-on-complete", help="Systemd timer unit to stop when all nodes finish")
    parser.add_argument("--lock-file", default="/run/sandboxed-node-rolling-upgrade.lock")
    parser.add_argument("--audit-log", help="Append JSONL events to this file")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Inspect and report planned actions only (default)")
    mode.add_argument("--apply", action="store_true", help="Execute cordons, swaps, restarts, and uncordons")
    mode.add_argument("--status", action="store_true", help="List each node's reported build and sha256 vs target")
    args = parser.parse_args(argv)

    if args.max_concurrent_cordons < 1:
        parser.error("--max-concurrent-cordons must be >= 1")

    expected_sha256 = {}
    for item in args.expect_sha256:
        try:
            k, v = parse_sha256_spec(item)
        except ValueError as err:
            parser.error(str(err))
        expected_sha256[k] = v

    stage_artifacts = None
    if args.stage_from_dir:
        stage_artifacts, computed_shas = build_stage_artifacts_from_dir(args.stage_from_dir, expected_sha256)
        for k, v in computed_shas.items():
            expected_sha256.setdefault(k, v)

    remote_nodes = [parse_node_spec(item) for item in args.node]

    lock_handle = None
    if (args.apply or args.recover_nodes) and args.lock_file:
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

        core_api = HttpCoreApi(base_url, bearer, timeout_secs=args.api_timeout_secs)
        if not remote_nodes and not args.local_jobs_db and not args.recover_nodes:
            discovered = [
                (n["id"], None)
                for n in core_api.list_nodes()
                if n.get("id") and not n.get("ephemeral", False)
            ]
            remote_nodes = discovered
            if not remote_nodes and not args.status:
                parser.error("provide at least one --node or --local-jobs-db (no static nodes discovered)")

        ssh_cfg = args.ssh_config if args.ssh_config and Path(args.ssh_config).exists() else None
        node_ops = SshNodeOps(
            ssh_config=ssh_cfg,
            staged_suffix=args.staged_suffix,
            backup_suffix=args.backup_suffix,
            verify_delay_secs=args.verify_delay_secs,
            expected_build_sha=args.expected_build_sha,
            expected_sha256=expected_sha256 or None,
            ssh_timeout_secs=args.ssh_timeout_secs,
        )
        if args.recover_nodes:
            rec_events = []
            for target_node in args.recover_nodes:
                host, _ = parse_node_spec(target_node)
                rec_events.append(
                    recover_cordoned_node(
                        core_api=core_api,
                        node_ops=node_ops,
                        node_id=host,
                        cordon_ledger_path=args.cordon_ledger,
                        preserve_cordons=frozenset(args.preserve_cordon),
                        force_uncordon=False,
                    )
                )
            output = "".join(json.dumps(ev, sort_keys=True) + "\n" for ev in rec_events)
            sys.stdout.write(output)
            if args.audit_log:
                Path(args.audit_log).parent.mkdir(parents=True, exist_ok=True)
                with open(args.audit_log, "a", encoding="utf-8") as handle:
                    handle.write(output)
            return 0

        if args.status:
            status_rows = collect_fleet_rollout_status(
                core_api=core_api,
                node_ops=node_ops,
                remote_nodes=remote_nodes,
                local_jobs_db=args.local_jobs_db,
                expected_build_sha=args.expected_build_sha,
                expected_sha256=expected_sha256 or None,
                cordon_ledger_path=args.cordon_ledger,
            )
            output = "".join(json.dumps(row, sort_keys=True) + "\n" for row in status_rows)
            sys.stdout.write(output)
            return 0

        events, done = run_governed_rollout(
            core_api=core_api,
            node_ops=node_ops,
            remote_nodes=remote_nodes,
            local_jobs_db=args.local_jobs_db,
            max_concurrent_cordons=args.max_concurrent_cordons,
            apply=args.apply,
            stop_timer_unit=args.stop_timer_on_complete,
            PreserveCordons=frozenset(args.preserve_cordon),
            stage_artifacts=stage_artifacts,
            expected_build_sha=args.expected_build_sha,
            expected_sha256=expected_sha256 or None,
            drain_timeout_secs=args.drain_timeout_secs,
            poll_interval_secs=args.poll_interval_secs,
            cordon_owner=args.cordon_owner,
            cordon_ledger_path=args.cordon_ledger,
        )
        output = "".join(json.dumps(ev, sort_keys=True) + "\n" for ev in events)
        sys.stdout.write(output)
        if args.audit_log:
            Path(args.audit_log).parent.mkdir(parents=True, exist_ok=True)
            with open(args.audit_log, "a", encoding="utf-8") as handle:
                handle.write(output)
        failure_actions = {
            "probe_error",
            "stage_failed",
            "upgrade_failed",
            "rollback_failed",
            "upgrade_quarantined",
            "unhealthy_node",
            "local_probe_error",
            "local_upgrade_failed",
            "local_rollback_failed",
            "local_upgrade_quarantined",
            "unhealthy_local",
            "drain_timeout",
        }
        if args.apply and any(ev["action"] in failure_actions for ev in events):
            return 1
        return 0
    finally:
        if lock_handle is not None:
            lock_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
