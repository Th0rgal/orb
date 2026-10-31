#!/usr/bin/env python3
"""Export settled Core missions and reclaim reconstructible worker build caches across the fleet."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_TARGETS = [
    ("ashur", "/var/lib/sandboxed-node", [
        "/var/lib/sandboxed-node/campaigns/worktrees/*",
        "/var/lib/sandboxed-node/worktrees/*/*",
    ]),
    ("nippur", "/var/lib/sandboxed-node", [
        "/var/lib/sandboxed-node/campaigns/worktrees/*",
        "/var/lib/sandboxed-node/campaigns/*",
    ]),
    ("babylon", "/var/lib/sandboxed-node", [
        "/var/lib/sandboxed-node/worktrees/*",
        "/var/lib/sandboxed-node/worktrees/*/*",
    ]),
    ("uruk", "/var/lib/sandboxed-node/work", [
        "/var/lib/sandboxed-node/campaigns/worktrees/*",
        "/var/lib/sandboxed-node/campaigns/*",
    ]),
    ("nimrud", "/var/lib/sandboxed-node", []),
    ("dgx-spark", "/var/lib/sandboxed-node", []),
    ("agent-core", "/var/lib/sandboxed-node/work", []),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--missions-dir",
        default="/root/.sandboxed-sh/missions",
        help="Core mission store directory used to export status metadata.",
    )
    parser.add_argument(
        "--lib-dir",
        default="/usr/local/lib/sandboxed-sh",
        help="Directory holding storage_inventory.py and reclaim_worker_build_caches.py.",
    )
    parser.add_argument(
        "--ssh-config",
        default="/root/.config/sandboxed-sh/development-identity/current/ssh/config",
        help="SSH config file for connecting to worker nodes.",
    )
    parser.add_argument(
        "--audit-log",
        default="/var/log/sandboxed-sh/worker-cache-reclaim.jsonl",
        help="Audit JSONL log path on each host.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Delete reconstructible caches inside settled/idle worker roots (default: dry-run).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    lib_dir = Path(args.lib_dir)
    inventory_py = lib_dir / "storage_inventory.py"
    reclaim_py = lib_dir / "reclaim_worker_build_caches.py"
    if not inventory_py.is_file() or not reclaim_py.is_file():
        print(f"error: missing {inventory_py} or {reclaim_py}", file=sys.stderr)
        return 2

    with tempfile.NamedTemporaryFile(prefix="missions-snapshot-", suffix=".jsonl", delete=False) as tf:
        snap_path = Path(tf.name)

    try:
        subprocess.run(
            [
                sys.executable,
                str(inventory_py),
                "--missions-dir",
                args.missions_dir,
                "--export-missions",
                str(snap_path),
            ],
            check=True,
        )

        overall_ok = True
        for host, work_dir, extra_globs in DEFAULT_TARGETS:
            mode_flag = "--apply" if args.apply else "--dry-run"
            if host == "agent-core":
                if not Path(work_dir).is_dir():
                    continue
                cmd = [
                    sys.executable,
                    str(reclaim_py),
                    mode_flag,
                    "--node-work-dir",
                    work_dir,
                    "--missions-snapshot",
                    str(snap_path),
                    "--audit-log",
                    args.audit_log,
                ]
                for glob_pat in extra_globs:
                    cmd.extend(["--extra-step-glob", glob_pat])
                res = subprocess.run(cmd, capture_output=True, text=True)
            else:
                scp_res = subprocess.run(
                    [
                        "scp",
                        "-F",
                        args.ssh_config,
                        "-o",
                        "BatchMode=yes",
                        "-o",
                        "ConnectTimeout=10",
                        "-q",
                        str(snap_path),
                        str(inventory_py),
                        str(reclaim_py),
                        f"{host}:/tmp/",
                    ],
                    capture_output=True,
                    text=True,
                )
                if scp_res.returncode != 0:
                    print(
                        json.dumps({
                            "host": host,
                            "ok": False,
                            "error": f"scp failed: {scp_res.stderr.strip()}",
                        }),
                        flush=True,
                    )
                    overall_ok = False
                    continue

                extra_flags = " ".join(f"--extra-step-glob '{g}'" for g in extra_globs)
                remote_sh = (
                    "if [ $(id -u) -ne 0 ]; then S='sudo -n'; else S=''; fi; "
                    "if [ ! -d " + repr(work_dir) + " ]; then rm -f /tmp/missions-snapshot-*.jsonl /tmp/storage_inventory.py /tmp/reclaim_worker_build_caches.py; exit 0; fi; "
                    "$S install -d -m 0755 /usr/local/lib/sandboxed-sh /var/log/sandboxed-sh; "
                    "$S mv /tmp/storage_inventory.py /tmp/reclaim_worker_build_caches.py /usr/local/lib/sandboxed-sh/; "
                    "$S chmod 0755 /usr/local/lib/sandboxed-sh/storage_inventory.py /usr/local/lib/sandboxed-sh/reclaim_worker_build_caches.py; "
                    f"SNAP=/tmp/{snap_path.name}; "
                    f"$S python3 /usr/local/lib/sandboxed-sh/reclaim_worker_build_caches.py "
                    f"{mode_flag} --node-work-dir '{work_dir}' --missions-snapshot \"$SNAP\" "
                    f"--audit-log '{args.audit_log}' {extra_flags}; "
                    "RC=$?; rm -f \"$SNAP\"; exit $RC"
                )
                res = subprocess.run(
                    [
                        "ssh",
                        "-n",
                        "-F",
                        args.ssh_config,
                        "-o",
                        "BatchMode=yes",
                        "-o",
                        "ConnectTimeout=10",
                        host,
                        remote_sh,
                    ],
                    capture_output=True,
                    text=True,
                )

            summary = None
            for line in res.stdout.splitlines():
                s = line.strip()
                if s.startswith("{"):
                    try:
                        rec = json.loads(s)
                    except json.JSONDecodeError:
                        continue
                    if rec.get("action") in ("reclaim_completed", "dry_run_summary"):
                        summary = rec
            ok = res.returncode == 0 and (summary is None or summary.get("ok", True))
            if not ok:
                overall_ok = False
            print(
                json.dumps({
                    "host": host,
                    "work_dir": work_dir,
                    "ok": ok,
                    "returncode": res.returncode,
                    "summary": summary,
                    "stderr": res.stderr.strip()[:400] if res.stderr.strip() else None,
                }),
                flush=True,
            )
        return 0 if overall_ok else 1
    finally:
        try:
            os.unlink(snap_path)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
