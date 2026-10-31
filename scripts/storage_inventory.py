#!/usr/bin/env python3
"""Read-only, dry-run-first storage attribution for sandboxed.sh.

This tool never removes data.  It inventories supplied roots, attributes
mission directories to persisted mission stores where possible, protects active
missions, and emits JSON Lines suitable for an operator audit trail.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import uuid

ACTIVE = {"active", "pending", "waiting_background"}
TERMINAL = {"completed", "failed", "interrupted", "blocked", "not_feasible"}
RECLAIMABLE_WORKER_CACHES = {
    ".elan",
    ".lake",
    "target",
    "toolchains",
    ".rustup",
    "node_modules",
    "conecache",
}


def iso_time(value):
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.replace(tzinfo=dt.timezone.utc) if parsed.tzinfo is None else parsed
    except (AttributeError, ValueError):
        return None


def canonical_uuid_or_lower(raw):
    try:
        return str(uuid.UUID(str(raw))).lower()
    except (ValueError, TypeError, AttributeError):
        return str(raw).lower()


def _should_replace_core_record(previous, candidate):
    cand_active = candidate["status"] in ACTIVE
    prev_active = previous["status"] in ACTIVE
    if cand_active != prev_active:
        return cand_active
    if candidate["owner"] == "prod" and previous["owner"] != "prod":
        return True
    return False


def _insert_core_record(records, full_records, mission_id, status, updated_at, workspace_id, owner):
    full_key = canonical_uuid_or_lower(mission_id)
    prefix = full_key[:8]
    base = {
        "mission_id": mission_id,
        "status": str(status).lower(),
        "updated_at": updated_at,
        "workspace_id": workspace_id,
        "owner": owner,
        "short_id_collision": False,
    }
    prev_full = full_records.get(full_key)
    if prev_full is None or _should_replace_core_record(prev_full, base):
        full_entry = dict(base)
        full_records[full_key] = full_entry
        records[full_key] = full_entry

    prefix_entry = dict(full_records[full_key])
    prev_prefix = records.get(prefix)
    if prev_prefix is not None:
        collision = prev_prefix["short_id_collision"] or (
            canonical_uuid_or_lower(prev_prefix["mission_id"]) != full_key
        )
        prefix_entry["short_id_collision"] = collision
        prev_prefix["short_id_collision"] = collision
        if _should_replace_core_record(prev_prefix, prefix_entry):
            records[prefix] = prefix_entry
    else:
        records[prefix] = prefix_entry


def mission_index(missions_dir):
    """Return (key -> record, complete, audit records) from persisted stores.

    Populates both 8-char prefix keys (for ``mission-<shortid>`` directories)
    and full lowercase UUID keys (for worker ``<uuid>`` directories).
    ``complete`` is false if any discovered store could not be read.  Callers
    must then retain every unowned directory: absence from a partial index is
    not evidence that a directory is stale.
    """
    records = {}
    full_records = {}
    audit_records = []
    complete = True
    missions_path = Path(missions_dir)
    if not missions_path.is_dir():
        audit_records.append({
            "record_type": "audit",
            "action": "index_error",
            "path": str(missions_path),
            "error": "missions directory is missing or unreadable",
        })
        return records, False, audit_records
    for legacy_store in missions_path.glob("missions-*.json"):
        audit_records.append({
            "record_type": "audit",
            "action": "index_error",
            "path": str(legacy_store),
            "error": "legacy JSON mission store is not indexed",
        })
        complete = False
    for db in sorted(missions_path.glob("missions-*.db")):
        try:
            conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            try:
                rows = conn.execute("SELECT id, status, updated_at, workspace_id FROM missions")
                owner = db.stem.removeprefix("missions-")
                for mission_id, status, updated_at, workspace_id in rows:
                    if not mission_id or not status:
                        raise sqlite3.DatabaseError("mission row missing id or status")
                    _insert_core_record(
                        records, full_records, mission_id, status, updated_at, workspace_id, owner
                    )
            finally:
                conn.close()
        except (sqlite3.Error, OSError) as error:
            # Fail closed: an unreadable store does not create a cleanup
            # candidate; the corresponding directory remains unattributed.
            audit_records.append({
                "record_type": "audit",
                "action": "index_error",
                "path": str(db),
                "error": str(error),
            })
            complete = False
    return records, complete, audit_records


def snapshot_index(snapshot_path):
    """Load an exported JSONL mission metadata snapshot (fail-closed on error)."""
    records = {}
    full_records = {}
    path = Path(snapshot_path)
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line_no, line in enumerate(handle, 1):
                stripped = line.strip()
                if not stripped:
                    continue
                row = json.loads(stripped)
                if not isinstance(row, dict):
                    raise ValueError(f"line {line_no}: expected JSON object")
                mission_id = row.get("mission_id")
                status = row.get("status")
                owner = row.get("owner") or "snapshot"
                if not isinstance(mission_id, str) or not mission_id or not isinstance(status, str) or not status:
                    raise ValueError(f"line {line_no}: missing mission_id or status")
                _insert_core_record(
                    records,
                    full_records,
                    mission_id,
                    status,
                    row.get("updated_at"),
                    row.get("workspace_id"),
                    str(owner),
                )
    except (OSError, ValueError) as error:
        return {}, False, [{
            "record_type": "audit",
            "action": "index_error",
            "path": str(path),
            "error": str(error),
        }]
    return records, True, []


def export_missions_snapshot(missions_dir, output_path):
    """Export non-secret Core mission status metadata as JSONL for worker attribution."""
    records, complete, audit_records = mission_index(missions_dir)
    if not complete:
        errors = "; ".join(r.get("error", "index error") for r in audit_records)
        raise RuntimeError(f"refusing to export incomplete mission index: {errors}")
    seen = set()
    lines = []
    for key in sorted(records):
        rec = records[key]
        full_key = canonical_uuid_or_lower(rec["mission_id"])
        if key != full_key or full_key in seen:
            continue
        seen.add(full_key)
        lines.append(json.dumps({
            "mission_id": rec["mission_id"],
            "owner": rec["owner"],
            "status": rec["status"],
            "updated_at": rec["updated_at"],
            "workspace_id": rec["workspace_id"],
        }, sort_keys=True) + "\n")
    dest = Path(output_path)
    tmp = dest.with_name(f".{dest.name}.tmp-{os.getpid()}")
    tmp.write_text("".join(lines), encoding="utf-8")
    os.replace(tmp, dest)


def merge_mission_and_node_records(core_records, node_records):
    """Enrich node job records with Core status/owner when available."""
    merged = dict(core_records)
    for mid, node_rec in node_records.items():
        existing = merged.get(mid)
        if existing is not None:
            combined = dict(existing)
            combined["node_job_states"] = node_rec["node_job_states"]
            combined["last_job_finished_at"] = node_rec["last_job_finished_at"]
            merged[mid] = combined
        else:
            merged[mid] = node_rec
    return merged


def usage_under(path):
    """Allocated blocks are not exclusive/reclaimable bytes on reflink filesystems."""
    apparent = allocated = errors = 0
    seen = set()
    device = path.lstat().st_dev

    def onerror(_):
        nonlocal errors
        errors += 1

    for root, dirs, files in os.walk(path, followlinks=False, onerror=onerror):
        kept = []
        for name in dirs:
            child = Path(root, name)
            try:
                meta = child.lstat()
                if stat.S_ISDIR(meta.st_mode) and meta.st_dev == device and not os.path.ismount(child):
                    kept.append(name)
            except OSError:
                errors += 1
        dirs[:] = kept
        for filename in files:
            try:
                meta = os.lstat(os.path.join(root, filename))
                key = (meta.st_dev, meta.st_ino)
                if key in seen:
                    continue
                seen.add(key)
                apparent += meta.st_size
                allocated += meta.st_blocks * 512
            except OSError:
                errors += 1
    return {
        "size_bytes": apparent,
        "allocated_bytes": allocated,
        "measurement_errors": errors,
        "reclaimable_bytes": None,
    }


def node_index(work_dir):
    """Job receipts attribute storage, never authorize deleting mission source."""
    db = Path(work_dir).absolute() / "jobs.db"
    records = {}
    try:
        conn = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True)
        try:
            for mid, state, count, finished in conn.execute(
                "SELECT mission_id,state,COUNT(*),MAX(finished_at) FROM jobs GROUP BY mission_id,state"
            ):
                mid = str(uuid.UUID(mid)).lower()
                record = records.setdefault(mid, {
                    "mission_id": mid,
                    "status": "node_jobs_only",
                    "updated_at": None,
                    "workspace_id": None,
                    "owner": "node:" + str(Path(work_dir).absolute()),
                    "short_id_collision": False,
                    "node_job_states": {},
                    "last_job_finished_at": None,
                })
                record["node_job_states"][state] = count
                if finished and (not record["last_job_finished_at"] or finished > record["last_job_finished_at"]):
                    record["last_job_finished_at"] = finished
        finally:
            conn.close()
    except (sqlite3.Error, OSError, ValueError) as error:
        return {}, False, [{
            "record_type": "audit",
            "action": "index_error",
            "path": str(db),
            "error": str(error),
        }]
    return records, True, []


def kind_for(path):
    name = path.name.lower()
    if name.startswith("mission-"):
        return "mission_dir"
    if name in {
        "target", ".cache", ".lean", ".lake", "cache", "caches",
        ".elan", "toolchains", ".rustup", "node_modules", "conecache",
    }:
        return "build_cache"
    if "image" in name or name in {"machines", "containers"}:
        return "container_image"
    if name in {"worktrees", ".git"} or (path / ".git").exists():
        return "git_worktree"
    return "unclassified"


def paths_to_inventory(root):
    """Yield direct children plus nested build-cache directories, once each.

    Direct children make roots such as workspace/container/image directories
    visible.  The targeted recursive walk captures `.lake`, `target`, and
    other nested build caches without producing a record for every source
    directory or following symlinks.
    """
    if root.name.startswith("mission-"):
        yield root
        return
    seen = set()
    for path in root.iterdir():
        if path.is_dir() and not path.is_symlink() and not os.path.ismount(path) and path not in seen:
            seen.add(path)
            yield path
    for current, dirs, _ in os.walk(root, followlinks=False):
        dirs[:] = [
            name for name in dirs
            if not os.path.islink(os.path.join(current, name))
            and not os.path.ismount(os.path.join(current, name))
        ]
        for name in dirs:
            path = Path(current, name)
            if kind_for(path) == "build_cache" and path not in seen:
                seen.add(path)
                yield path


def mission_for_path(path, root, index):
    """Find a mission owner from this path or one of its ancestors."""
    current = path
    while True:
        lower_name = current.name.lower()
        if lower_name.startswith("mission-"):
            found = index.get(lower_name.removeprefix("mission-"))
            if found is not None:
                return found
        else:
            key = canonical_uuid_or_lower(current.name)
            if len(key) > 8 and key in index:
                return index[key]
        if current == root:
            return None
        parent = current.parent
        if parent == current:
            return None
        current = parent


def inventory(root, index, index_complete, cutoff, node_work_root=None):
    root = Path(root)
    if not root.is_dir() or root.is_symlink():
        yield {"record_type": "audit", "action": "root_missing", "path": str(root)}
        return
    in_node_work_root = node_work_root is not None and root.resolve() == node_work_root
    for path in paths_to_inventory(root):
        kind = kind_for(path)
        mission = mission_for_path(path, root, index)
        try:
            mtime = dt.datetime.fromtimestamp(path.lstat().st_mtime, tz=dt.timezone.utc)
            usage = usage_under(path)
        except OSError as error:
            yield {"record_type": "audit", "action": "measurement_error", "path": str(path), "error": str(error)}
            continue
        has_node_jobs = bool(mission and "node_job_states" in mission)
        node_owned = has_node_jobs or (in_node_work_root and mission is not None)
        if mission and canonical_uuid_or_lower(path.name) == canonical_uuid_or_lower(mission["mission_id"]):
            kind = "mission_dir"
        active = bool(mission and mission["status"] in ACTIVE)
        terminal = bool(mission and mission["status"] in TERMINAL)
        mission_updated_at = iso_time(mission["updated_at"]) if mission else None
        short_id_collision = bool(mission and mission["short_id_collision"])
        # Only a terminal, attributed local mission directory is ever proposed.
        # Node work directories, caches, worktrees, images, and unattributed
        # directories remain inventory-only even when old: an operator must
        # establish ownership before any separate cleanup action can be approved.
        eligible = bool(
            not node_owned
            and not in_node_work_root
            and kind == "mission_dir"
            and index_complete
            and mission
            and not short_id_collision
            and terminal
            and mission_updated_at is not None
            and mission_updated_at < cutoff
        )
        if node_owned:
            reason = "node_job_history_is_not_discard_authorization"
        elif active:
            reason = "active_mission_protected"
        elif kind != "mission_dir":
            reason = "unattributed_requires_owner_approval"
        elif not index_complete:
            reason = "mission_attribution_incomplete"
        elif not mission:
            reason = "unattributed_requires_owner_approval"
        elif short_id_collision:
            reason = "short_id_collision_protected"
        elif not terminal:
            reason = "non_terminal_mission_protected"
        elif mission_updated_at is None:
            reason = "mission_timestamp_invalid"
        elif eligible:
            reason = "terminal_mission_past_retention"
        else:
            reason = "within_retention"
        yield {
            "record_type": "storage_item",
            "action": "would_remove" if eligible else "keep",
            "path": str(path),
            "kind": kind,
            "owner": mission["owner"] if mission else "unattributed",
            "mission_id": mission["mission_id"] if mission else None,
            "workspace_id": mission["workspace_id"] if mission else None,
            "mission_status": mission["status"] if mission else None,
            "age_days": round((dt.datetime.now(dt.timezone.utc) - mtime).total_seconds() / 86400, 2),
            **usage,
            "reason": reason,
            **({
                "node_job_states": mission["node_job_states"],
                "last_job_finished_at": mission["last_job_finished_at"],
            } if has_node_jobs else {}),
        }


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read-only sandboxed.sh storage inventory (never deletes).")
    parser.add_argument("--missions-dir", help="Directory containing missions-*.db")
    parser.add_argument("--missions-snapshot", help="Exported JSONL snapshot of Core mission statuses")
    parser.add_argument(
        "--export-missions",
        help="Write a non-secret JSONL snapshot of --missions-dir to this path (exits if no roots supplied)",
    )
    parser.add_argument(
        "--root",
        action="append",
        default=[],
        help="Root to inventory; repeat for workspaces, caches, images, or worktrees",
    )
    parser.add_argument("--node-work-dir", help="Node work directory containing jobs.db; automatically inventoried, never deleted")
    parser.add_argument("--retention-days", type=int, default=7)
    parser.add_argument("--audit-log", help="Append JSONL audit records to this file")
    parser.add_argument("--apply", action="store_true", help="Rejected: this tool is inventory-only")
    args = parser.parse_args(argv)
    if args.apply:
        parser.error("--apply is intentionally unsupported; inventory never deletes data")
    if args.export_missions:
        if not args.missions_dir:
            parser.error("--export-missions requires --missions-dir")
        export_missions_snapshot(args.missions_dir, args.export_missions)
        if not args.root and not args.node_work_dir:
            return 0
    if not args.missions_dir and not args.missions_snapshot and not args.node_work_dir:
        parser.error("provide --missions-dir, --missions-snapshot, or --node-work-dir")
    if not args.root and not args.node_work_dir:
        parser.error("provide --root or --node-work-dir")

    now = dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(days=args.retention_days)
    indexed = {}
    index_complete = True
    index_audit_records = []

    if args.missions_dir:
        dir_records, dir_complete, dir_audit = mission_index(args.missions_dir)
        indexed.update(dir_records)
        index_complete = index_complete and dir_complete
        index_audit_records.extend(dir_audit)
    if args.missions_snapshot:
        snap_records, snap_complete, snap_audit = snapshot_index(args.missions_snapshot)
        for k, v in snap_records.items():
            if k not in indexed:
                indexed[k] = v
        index_complete = index_complete and snap_complete
        index_audit_records.extend(snap_audit)

    node_work_root = None
    if args.node_work_dir:
        node_work_root = Path(args.node_work_dir).resolve() if Path(args.node_work_dir).exists() else None
        node_records, node_complete, node_audit = node_index(args.node_work_dir)
        indexed = merge_mission_and_node_records(indexed, node_records)
        index_complete = index_complete and node_complete
        index_audit_records.extend(node_audit)
        args.root = list(dict.fromkeys([args.node_work_dir, *args.root]))

    records = [{
        "record_type": "audit",
        "action": "inventory_started",
        "dry_run": True,
        "retention_days": args.retention_days,
        "at": now.isoformat(),
        "size_note": "Nested records overlap; allocated bytes include shared extents and are not reclaimable bytes.",
    }]
    records.extend(index_audit_records)
    for root in args.root:
        records.extend(inventory(root, indexed, index_complete, cutoff, node_work_root=node_work_root))
    output = "".join(json.dumps(record, sort_keys=True) + "\n" for record in records)
    sys.stdout.write(output)
    if args.audit_log:
        with open(args.audit_log, "a", encoding="utf-8") as handle:
            handle.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
