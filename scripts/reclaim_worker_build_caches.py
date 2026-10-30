#!/usr/bin/env python3
"""Safe, dry-run-first reclamation of reconstructible build/toolchain caches
inside finished worker mission directories.

Mission source files, .git repositories, logs, and receipts are NEVER deleted.
Only nested reconstructible cache directories (.elan, .lake, target, toolchains,
.rustup, node_modules) inside verified non-active missions with zero open file
descriptors and zero nested mounts are eligible when --apply is explicitly supplied.
"""
import argparse
import datetime as dt
import glob
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import storage_inventory as inv  # noqa: E402

SETTLED_NODE_JOB_STATES = {"succeeded", "failed", "cancelled", "retired", "completed", "lost"}
ELIGIBLE_CORE_STATUSES = inv.TERMINAL | {"acknowledged"}


def _unescape_mountinfo_path(raw):
    return (
        raw.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
    )


def discover_mountpoints(mountinfo_path="/proc/self/mountinfo"):
    """Return active mount-point paths from Linux mountinfo when available.

    Same-filesystem bind mounts share ``st_dev`` with their parent directory, so
    reading ``/proc/self/mountinfo`` ensures bind mounts inside ``target`` or
    ``.lake`` are detected even on Python runtimes where ``os.path.ismount``
    only compares ``st_dev``/``st_ino``.
    """
    info = Path(mountinfo_path)
    if not info.is_file():
        return frozenset()
    points = set()
    try:
        for line in info.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split(" ")
            if len(parts) >= 5:
                mp = _unescape_mountinfo_path(parts[4])
                if mp:
                    points.add(os.path.normpath(mp))
    except OSError:
        return frozenset()
    return frozenset(points)


def is_mount_boundary(path, meta, expected_dev, mountpoints=frozenset()):
    """Return True if ``path`` crosses onto another device or mount point."""
    if meta.st_dev != expected_dev:
        return True
    if stat.S_ISDIR(meta.st_mode):
        if os.path.ismount(path):
            return True
        if mountpoints:
            norm = os.path.normpath(os.path.abspath(str(path)))
            if norm in mountpoints or os.path.realpath(str(path)) in mountpoints:
                return True
    return False


def inspect_reclaimable_subtree(cache_dir, expected_dev, mountpoints=frozenset()):
    """Verify ``cache_dir`` contains no nested mounts, foreign devices, or stat errors."""
    root = Path(cache_dir)
    try:
        root_meta = root.lstat()
    except OSError:
        return False, "subtree_stat_error"
    if not stat.S_ISDIR(root_meta.st_mode):
        return False, "not_a_directory"
    if is_mount_boundary(root, root_meta, expected_dev, mountpoints):
        return False, "nested_mount_protected"

    walk_errors = 0

    def onerror(_err):
        nonlocal walk_errors
        walk_errors += 1

    for current, dirs, files in os.walk(root, followlinks=False, onerror=onerror):
        kept = []
        for name in dirs:
            child = Path(current, name)
            try:
                meta = child.lstat()
            except OSError:
                return False, "subtree_stat_error"
            if is_mount_boundary(child, meta, expected_dev, mountpoints):
                return False, "nested_mount_protected"
            if stat.S_ISDIR(meta.st_mode):
                kept.append(name)
        dirs[:] = kept
        for name in files:
            child = Path(current, name)
            try:
                meta = child.lstat()
            except OSError:
                return False, "subtree_stat_error"
            if meta.st_dev != expected_dev:
                return False, "nested_mount_protected"

    if walk_errors:
        return False, "subtree_stat_error"
    return True, ""


def rmtree_same_device(root_dir, expected_dev, mountpoints=None):
    """Delete ``root_dir`` while enforcing single-device / no-mount boundaries via dir_fd."""
    active_mounts = discover_mountpoints() if mountpoints is None else frozenset(mountpoints)
    root_path = Path(root_dir)
    root_meta = root_path.lstat()
    if not stat.S_ISDIR(root_meta.st_mode):
        raise RuntimeError(f"refusing to rmtree non-directory: {root_path}")
    if is_mount_boundary(root_path, root_meta, expected_dev, active_mounts):
        raise RuntimeError(f"refusing to rmtree mount or foreign-device directory: {root_path}")

    open_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)

    def _empty_dir_fd(dir_fd, dir_path):
        fd_meta = os.fstat(dir_fd)
        if fd_meta.st_dev != expected_dev:
            raise RuntimeError(f"refusing to cross filesystem boundary at {dir_path}")
        if (fd_meta.st_mode & stat.S_IWUSR) == 0:
            os.fchmod(dir_fd, (fd_meta.st_mode & 0o777) | stat.S_IWUSR | stat.S_IXUSR)
        with os.scandir(dir_fd) as it:
            entries = list(it)
        for entry in entries:
            child_path = dir_path / entry.name
            meta = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(meta.st_mode):
                if is_mount_boundary(child_path, meta, expected_dev, active_mounts):
                    raise RuntimeError(f"refusing to cross nested mount: {child_path}")
                child_fd = os.open(entry.name, open_flags, dir_fd=dir_fd)
                try:
                    child_fd_meta = os.fstat(child_fd)
                    if child_fd_meta.st_dev != expected_dev or child_fd_meta.st_ino != meta.st_ino:
                        raise RuntimeError(f"directory identity changed during delete: {child_path}")
                    _empty_dir_fd(child_fd, child_path)
                finally:
                    os.close(child_fd)
                os.rmdir(entry.name, dir_fd=dir_fd)
            else:
                if meta.st_dev != expected_dev:
                    raise RuntimeError(f"refusing to unlink foreign-device entry: {child_path}")
                os.unlink(entry.name, dir_fd=dir_fd)

    root_fd = os.open(str(root_path), open_flags)
    try:
        root_fd_meta = os.fstat(root_fd)
        if root_fd_meta.st_dev != expected_dev or root_fd_meta.st_ino != root_meta.st_ino:
            raise RuntimeError(f"root directory identity changed before delete: {root_path}")
        _empty_dir_fd(root_fd, root_path)
    finally:
        os.close(root_fd)
    os.rmdir(root_path)


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


def find_reclaimable_subdirs(mission_dir, allowed_names=inv.RECLAIMABLE_WORKER_CACHES, mountpoints=frozenset()):
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
            if not stat.S_ISDIR(meta.st_mode) or is_mount_boundary(candidate, meta, root_dev, mountpoints):
                continue
            if name.lower() in allowed:
                yield candidate
            else:
                kept.append(name)
        dirs[:] = kept


def _process_candidate_caches(
    parent_dir,
    expected_dev,
    mountpoints_override,
    apply,
    open_file_probe,
    records,
    context_fields,
):
    """Validate and optionally delete reclaimable cache subdirs under ``parent_dir``."""
    scan_mounts = discover_mountpoints() if mountpoints_override is None else frozenset(mountpoints_override)
    candidates = list(find_reclaimable_subdirs(parent_dir, mountpoints=scan_mounts))
    if not candidates:
        return 0, 0, True

    probe_status, probe_detail = open_file_probe(parent_dir)
    if probe_status != "clear":
        records.append({
            "record_type": "cache_item",
            "action": "skip",
            "detail": probe_detail,
            "path": str(parent_dir),
            "reason": "open_files_protected" if probe_status == "open" else "open_file_probe_failed",
            **context_fields,
        })
        return 0, 0, True

    reclaimed_bytes = 0
    reclaimed_dirs = 0
    all_ok = True
    for cache_dir in candidates:
        live_mounts = discover_mountpoints() if mountpoints_override is None else frozenset(mountpoints_override)
        safe, unsafe_reason = inspect_reclaimable_subtree(cache_dir, expected_dev, mountpoints=live_mounts)
        if not safe:
            records.append({
                "record_type": "cache_item",
                "action": "skip",
                "cache_kind": cache_dir.name,
                "path": str(cache_dir),
                "reason": unsafe_reason,
                **context_fields,
            })
            continue
        usage = inv.usage_under(cache_dir)
        action = "reclaimed" if apply else "would_reclaim"
        if apply:
            try:
                rmtree_same_device(cache_dir, expected_dev, mountpoints=mountpoints_override)
            except (OSError, RuntimeError) as error:
                all_ok = False
                records.append({
                    "record_type": "audit",
                    "action": "reclaim_error",
                    "error": str(error),
                    "path": str(cache_dir),
                    **context_fields,
                })
                continue
        reclaimed_bytes += usage["allocated_bytes"]
        reclaimed_dirs += 1
        records.append({
            "record_type": "cache_item",
            "action": action,
            "cache_kind": cache_dir.name,
            "path": str(cache_dir),
            **context_fields,
            **usage,
        })
    return reclaimed_bytes, reclaimed_dirs, all_ok


def reclaim_worker_caches(
    node_work_dir,
    missions_dir=None,
    missions_snapshot=None,
    apply=False,
    terminal_only=False,
    extra_step_globs=(),
    open_file_probe=default_open_file_probe,
    mountpoints=None,
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

    active_mounts = discover_mountpoints() if mountpoints is None else frozenset(mountpoints)
    work_dev = work_path.lstat().st_dev
    total_allocated = 0
    reclaimed_count = 0
    overall_ok = True

    for entry in sorted(work_path.iterdir(), key=lambda p: p.name):
        try:
            meta = entry.lstat()
        except OSError:
            continue
        if not stat.S_ISDIR(meta.st_mode) or is_mount_boundary(entry, meta, work_dev, active_mounts):
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

        added_bytes, added_dirs, batch_ok = _process_candidate_caches(
            parent_dir=entry,
            expected_dev=work_dev,
            mountpoints_override=mountpoints,
            apply=apply,
            open_file_probe=open_file_probe,
            records=records,
            context_fields={
                "mission_id": core_rec["mission_id"],
                "mission_status": core_rec["status"],
                "owner": core_rec["owner"],
            },
        )
        total_allocated += added_bytes
        reclaimed_count += added_dirs
        overall_ok = overall_ok and batch_ok

    for pattern in extra_step_globs:
        for raw_step in sorted(glob.glob(pattern)):
            step_path = Path(raw_step)
            try:
                meta = step_path.lstat()
            except OSError:
                continue
            if not stat.S_ISDIR(meta.st_mode) or is_mount_boundary(step_path, meta, meta.st_dev, active_mounts):
                continue
            added_bytes, added_dirs, batch_ok = _process_candidate_caches(
                parent_dir=step_path,
                expected_dev=meta.st_dev,
                mountpoints_override=mountpoints,
                apply=apply,
                open_file_probe=open_file_probe,
                records=records,
                context_fields={"owner": "scratch_glob"},
            )
            total_allocated += added_bytes
            reclaimed_count += added_dirs
            overall_ok = overall_ok and batch_ok

    records.append({
        "record_type": "audit",
        "action": "reclaim_completed",
        "apply": bool(apply),
        "cache_dirs": reclaimed_count,
        "ok": overall_ok,
        "total_allocated_bytes": total_allocated,
    })
    return records, overall_ok


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
