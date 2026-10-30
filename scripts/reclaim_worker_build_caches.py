#!/usr/bin/env python3
"""Safe, dry-run-first reclamation of reconstructible build/toolchain caches
inside finished worker mission directories.

Mission source files, .git repositories, logs, and receipts are NEVER deleted.
Only nested reconstructible cache directories (.elan, .lake, target, toolchains,
.rustup, node_modules) inside verified non-active missions with zero open file
descriptors are eligible when --apply is explicitly supplied.
"""
import argparse
import datetime as dt
import glob
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import storage_inventory as inv  # noqa: E402

SETTLED_NODE_JOB_STATES = {"succeeded", "failed", "cancelled", "retired", "completed", "lost"}
ELIGIBLE_CORE_STATUSES = inv.TERMINAL | {"acknowledged"}


def default_open_file_probe(directory, timeout=15):
    """Return (status, detail) where status is 'clear', 'open', or 'error'.

    ``lsof +D <dir>`` returns exit code 1 with empty stdout when no files are
    open, and exit code 0 with non-empty stdout when at least one descriptor is
    open under ``directory``.  Missing ``lsof`` or timeouts fail closed.
    """
    try:
        res = subprocess.run(
            ["lsof", "+D", str(directory)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return "error", "lsof binary is not installed"
    except subprocess.TimeoutExpired:
        return "error", f"lsof timed out after {timeout}s"
    except OSError as error:
        return "error", str(error)

    if res.stdout.strip():
        return "open", "open file descriptors detected"
    if res.returncode not in (0, 1):
        return "error", (res.stderr.strip() or f"lsof exited with status {res.returncode}")
    return "clear", ""


def find_reclaimable_subdirs(mission_dir, allowed_names=inv.RECLAIMABLE_WORKER_CACHES):
    """Yield non-overlapping reconstructible cache subdirectories on the same device."""
    root_path = Path(mission_dir)
    root_dev = root_path.lstat().st_dev
    allowed = {name.lower() for name in allowed_names}
    for current, dirs, _ in os.walk(root_path, followlinks=False):
        kept = []
        for name in sorted(dirs):
            candidate = Path(current, name)
            try:
                meta = candidate.lstat()
            except OSError:
                continue
            if not stat.S_ISDIR(meta.st_mode) or meta.st_dev != root_dev or os.path.ismount(candidate):
                continue
            if name.lower() in allowed:
                yield candidate
            else:
                kept.append(name)
        dirs[:] = kept


def reclaim_worker_caches(
    node_work_dir,
    missions_dir=None,
    missions_snapshot=None,
    apply=False,
    terminal_only=False,
    extra_step_globs=(),
    open_file_probe=default_open_file_probe,
):
    """Run dry-run or live cache reclamation and return (records, ok)."""
    now = dt.datetime.now(dt.timezone.utc)
    records = [{
        "record_type": "audit",
        "action": "reclaim_started",
        "apply": bool(apply),
        "at": now.isoformat(),
        "node_work_dir": str(node_work_dir),
    }]

    if not missions_dir and not missions_snapshot:
        records.append({
            "record_type": "audit",
            "action": "index_error",
            "path": str(node_work_dir),
            "error": "Core mission attribution (--missions-dir or --missions-snapshot) is required",
        })
        return records, False

    core_records = {}
    core_complete = True
    if missions_dir:
        d_rec, d_ok, d_aud = inv.mission_index(missions_dir)
        core_records.update(d_rec)
        core_complete = core_complete and d_ok
        records.extend(d_aud)
    if missions_snapshot:
        s_rec, s_ok, s_aud = inv.snapshot_index(missions_snapshot)
        for k, v in s_rec.items():
            if k not in core_records:
                core_records[k] = v
        core_complete = core_complete and s_ok
        records.extend(s_aud)

    node_records, node_complete, node_audit = inv.node_index(node_work_dir)
    records.extend(node_audit)

    if not core_complete or not node_complete:
        records.append({
            "record_type": "audit",
            "action": "aborted_incomplete_index",
            "core_complete": core_complete,
            "node_complete": node_complete,
        })
        return records, False

    allowed_statuses = inv.TERMINAL if terminal_only else ELIGIBLE_CORE_STATUSES
    work_path = Path(node_work_dir)
    if not work_path.is_dir() or work_path.is_symlink():
        records.append({
            "record_type": "audit",
            "action": "index_error",
            "path": str(work_path),
            "error": "node work directory is missing or a symlink",
        })
        return records, False

    work_dev = work_path.lstat().st_dev
    total_allocated = 0
    reclaimed_count = 0

    for entry in sorted(work_path.iterdir(), key=lambda p: p.name):
        try:
            meta = entry.lstat()
        except OSError:
            continue
        if not stat.S_ISDIR(meta.st_mode) or meta.st_dev != work_dev or os.path.ismount(entry):
            continue

        mid_key = inv.canonical_uuid_or_lower(entry.name)
        if len(mid_key) != 36:
            continue

        core_rec = core_records.get(mid_key)
        if core_rec is None:
            continue
        if core_rec["status"] not in allowed_statuses:
            continue

        node_rec = node_records.get(mid_key)
        if node_rec is not None:
            unset_states = set(node_rec.get("node_job_states", {})) - SETTLED_NODE_JOB_STATES
            if unset_states:
                records.append({
                    "record_type": "cache_item",
                    "action": "skip",
                    "mission_id": core_rec["mission_id"],
                    "mission_status": core_rec["status"],
                    "path": str(entry),
                    "reason": "active_node_job_protected",
                    "unsettled_job_states": sorted(unset_states),
                })
                continue

        candidates = list(find_reclaimable_subdirs(entry))
        if not candidates:
            continue

        probe_status, probe_detail = open_file_probe(entry)
        if probe_status != "clear":
            records.append({
                "record_type": "cache_item",
                "action": "skip",
                "detail": probe_detail,
                "mission_id": core_rec["mission_id"],
                "mission_status": core_rec["status"],
                "path": str(entry),
                "reason": "open_files_protected" if probe_status == "open" else "open_file_probe_failed",
            })
            continue

        for cache_dir in candidates:
            usage = inv.usage_under(cache_dir)
            action = "reclaimed" if apply else "would_reclaim"
            if apply:
                shutil.rmtree(cache_dir)
            total_allocated += usage["allocated_bytes"]
            reclaimed_count += 1
            records.append({
                "record_type": "cache_item",
                "action": action,
                "cache_kind": cache_dir.name,
                "mission_id": core_rec["mission_id"],
                "mission_status": core_rec["status"],
                "owner": core_rec["owner"],
                "path": str(cache_dir),
                **usage,
            })

    for pattern in extra_step_globs:
        for raw_step in sorted(glob.glob(pattern)):
            step_path = Path(raw_step)
            try:
                meta = step_path.lstat()
            except OSError:
                continue
            if not stat.S_ISDIR(meta.st_mode) or os.path.ismount(step_path):
                continue
            candidates = list(find_reclaimable_subdirs(step_path))
            if not candidates:
                continue
            probe_status, probe_detail = open_file_probe(step_path)
            if probe_status != "clear":
                records.append({
                    "record_type": "cache_item",
                    "action": "skip",
                    "detail": probe_detail,
                    "path": str(step_path),
                    "reason": "open_files_protected" if probe_status == "open" else "open_file_probe_failed",
                })
                continue
            for cache_dir in candidates:
                usage = inv.usage_under(cache_dir)
                action = "reclaimed" if apply else "would_reclaim"
                if apply:
                    shutil.rmtree(cache_dir)
                total_allocated += usage["allocated_bytes"]
                reclaimed_count += 1
                records.append({
                    "record_type": "cache_item",
                    "action": action,
                    "cache_kind": cache_dir.name,
                    "owner": "scratch_glob",
                    "path": str(cache_dir),
                    **usage,
                })

    records.append({
        "record_type": "audit",
        "action": "reclaim_completed",
        "apply": bool(apply),
        "cache_dirs": reclaimed_count,
        "total_allocated_bytes": total_allocated,
    })
    return records, True


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Reclaim reconstructible build/toolchain caches inside finished worker missions."
    )
    parser.add_argument("--node-work-dir", required=True, help="Worker directory containing jobs.db and <uuid>/ dirs")
    parser.add_argument("--missions-dir", help="Core directory containing missions-*.db")
    parser.add_argument("--missions-snapshot", help="JSONL snapshot exported via storage_inventory.py --export-missions")
    parser.add_argument("--extra-step-glob", action="append", default=[], help="Optional scratch step glob to prune when lsof-idle")
    parser.add_argument("--terminal-only", action="store_true", help="Exclude archived ('acknowledged') missions")
    parser.add_argument("--audit-log", help="Append JSONL audit records to this file")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Report eligible caches without deleting (default)")
    mode.add_argument("--apply", action="store_true", help="Delete eligible reconstructible cache directories")
    args = parser.parse_args(argv)

    records, ok = reclaim_worker_caches(
        node_work_dir=args.node_work_dir,
        missions_dir=args.missions_dir,
        missions_snapshot=args.missions_snapshot,
        apply=args.apply,
        terminal_only=args.terminal_only,
        extra_step_globs=args.extra_step_glob,
    )
    output = "".join(json.dumps(r, sort_keys=True) + "\n" for r in records)
    sys.stdout.write(output)
    if args.audit_log:
        Path(args.audit_log).parent.mkdir(parents=True, exist_ok=True)
        with open(args.audit_log, "a", encoding="utf-8") as handle:
            handle.write(output)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
