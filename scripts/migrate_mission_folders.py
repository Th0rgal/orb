#!/usr/bin/env python3
"""Idempotent clean-cut migration for Orb mission folders and family placement.

1. Ensures `missions.folder` (`TEXT NOT NULL DEFAULT ''`),
   `missions.placement_revision` (`INTEGER NOT NULL DEFAULT 0`), and
   `idx_missions_project_folder` exist.
2. Backfills `missions.folder` from legacy `orb-folder:<path>` tags and strips
   every `orb-folder:*` tag from `missions.tags` (preserving `updated_at`).
3. Clears `folder = ''` on all nested child workers (`parent_mission_id IS NOT NULL`
   without `fork-of:<parent>` or ` · fork`) and `/btw` side sessions
   (`btw-parent:*` / `btw-subagent`).
4. Heals split cross-project child workers and `/btw` side sessions whose
   `project` disagrees with their root/target conversation's `project`
   (updating `project`, clearing `folder = ''`, incrementing
   `placement_revision = placement_revision + 1`, preserving `updated_at`).
5. Prints a structured JSON receipt to stdout (never logging prompts or secrets).
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any

LEGACY_ORB_FOLDER_TAG_PREFIX = "orb-folder:"
BTW_PARENT_PREFIX = "btw-parent:"
FORK_OF_PREFIX = "fork-of:"


def normalize_mission_folder(raw: str | None) -> str:
    if not raw:
        return ""
    segments: list[str] = []
    for seg in raw.strip().split("/"):
        s = seg.strip()
        if not s or s == "." or s == "..":
            continue
        if any(ord(ch) < 32 or ord(ch) == 127 for ch in s):
            continue
        segments.append(s)
    return "/".join(segments)


def parse_tags(raw_tags: str | None) -> list[str] | None:
    if raw_tags is None:
        return []
    stripped = raw_tags.strip()
    if not stripped:
        return []
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, list):
        return None
    return [str(item) for item in parsed if isinstance(item, str)]


def strip_legacy_orb_folder_tags(tags: list[str]) -> tuple[list[str], str | None]:
    extracted: str | None = None
    kept: list[str] = []
    for tag in tags:
        if tag.startswith(LEGACY_ORB_FOLDER_TAG_PREFIX):
            norm = normalize_mission_folder(tag[len(LEGACY_ORB_FOLDER_TAG_PREFIX) :])
            if norm:
                extracted = norm
        else:
            kept.append(tag)
    return kept, extracted


def is_fork_of_parent(tags: list[str], title: str | None, parent_id: str | None) -> bool:
    if not parent_id:
        return False
    expected = f"{FORK_OF_PREFIX}{parent_id}"
    if any(t == expected for t in tags):
        return True
    if title and title.lower().endswith(" · fork"):
        return True
    return False


def btw_parent_target(tags: list[str]) -> str | None:
    for tag in tags:
        if tag.startswith(BTW_PARENT_PREFIX):
            target = tag[len(BTW_PARENT_PREFIX) :].strip()
            if target:
                return target
    return None


def is_btw_side_mission(tags: list[str]) -> bool:
    return any(
        t.startswith(BTW_PARENT_PREFIX) or t == "btw-subagent" for t in tags
    )


def ensure_schema(conn: sqlite3.Connection, dry_run: bool) -> dict[str, bool]:
    cols = {
        row[1]
        for row in conn.execute("PRAGMA table_info('missions')").fetchall()
    }
    indexes = {
        row[1]
        for row in conn.execute("PRAGMA index_list('missions')").fetchall()
    }
    added_folder = "folder" not in cols
    added_revision = "placement_revision" not in cols
    added_index = "idx_missions_project_folder" not in indexes

    if not dry_run:
        if added_folder:
            conn.execute(
                "ALTER TABLE missions ADD COLUMN folder TEXT NOT NULL DEFAULT ''"
            )
        if added_revision:
            conn.execute(
                "ALTER TABLE missions ADD COLUMN placement_revision INTEGER NOT NULL DEFAULT 0"
            )
        if added_index:
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_missions_project_folder ON missions(project, folder)"
            )
    return {
        "added_folder_column": added_folder,
        "added_placement_revision_column": added_revision,
        "added_project_folder_index": added_index,
    }


def migrate_db(db_path: Path, dry_run: bool) -> dict[str, Any]:
    if not db_path.exists():
        raise FileNotFoundError(f"Database file not found: {db_path}")

    uri = f"file:{db_path}?mode={'ro' if dry_run else 'rw'}"
    conn = sqlite3.connect(uri, uri=True, timeout=30.0)
    conn.isolation_level = None
    try:
        if not dry_run:
            conn.execute("PRAGMA busy_timeout = 30000")
            conn.execute("BEGIN IMMEDIATE")

        schema_info = ensure_schema(conn, dry_run=dry_run)

        cols = {
            row[1]
            for row in conn.execute("PRAGMA table_info('missions')").fetchall()
        }
        folder_expr = "COALESCE(folder, '')" if "folder" in cols else "''"
        rev_expr = (
            "COALESCE(placement_revision, 0)"
            if "placement_revision" in cols
            else "0"
        )
        parent_expr = (
            "parent_mission_id" if "parent_mission_id" in cols else "NULL"
        )

        rows = conn.execute(
            f"""
            SELECT id, {parent_expr}, project, {folder_expr}, {rev_expr}, tags, title
            FROM missions
            ORDER BY id ASC
            """
        ).fetchall()

        records: dict[str, dict[str, Any]] = {}
        unparseable_tags_ids: list[str] = []
        for mid, parent_id, project, folder, rev, raw_tags, title in rows:
            parsed_tags = parse_tags(raw_tags)
            if parsed_tags is None:
                unparseable_tags_ids.append(mid)
                parsed_tags = []
            norm_project = (
                project.strip()
                if isinstance(project, str) and project.strip()
                else None
            )
            records[mid] = {
                "id": mid,
                "parent_id": parent_id,
                "orig_project": project,
                "project": norm_project,
                "orig_folder": folder or "",
                "folder": normalize_mission_folder(folder),
                "orig_rev": int(rev or 0),
                "rev": int(rev or 0),
                "orig_raw_tags": raw_tags,
                "tags": parsed_tags,
                "tags_unparseable": mid in unparseable_tags_ids,
                "title": title,
            }

        backfilled_folder_ids: list[str] = []
        stripped_tag_ids: list[str] = []
        cleared_nested_folder_ids: list[str] = []

        # Pass 1 & 2: backfill `folder` from `orb-folder:*`, strip `orb-folder:*`,
        # and clear `folder = ''` on nested children & `/btw` rows.
        for mid, rec in records.items():
            if rec["tags_unparseable"]:
                continue
            clean_tags, extracted_folder = strip_legacy_orb_folder_tags(rec["tags"])
            tags_changed = clean_tags != rec["tags"]
            rec["tags"] = clean_tags
            if tags_changed:
                stripped_tag_ids.append(mid)

            is_fork = is_fork_of_parent(clean_tags, rec["title"], rec["parent_id"])
            is_nested = (bool(rec["parent_id"]) and not is_fork) or is_btw_side_mission(
                clean_tags
            )

            if is_nested:
                if rec["folder"] != "" or rec["orig_folder"] != "":
                    cleared_nested_folder_ids.append(mid)
                rec["folder"] = ""
            else:
                if not rec["folder"] and extracted_folder:
                    rec["folder"] = extracted_folder
                    backfilled_folder_ids.append(mid)

        # Pass 3: heal split cross-project nested children & `/btw` side sessions
        # so every child/`btw` lives in the exact `project` of its root/target conversation.
        def non_fork_parent_or_btw_link(rec: dict[str, Any]) -> str | None:
            pid = rec["parent_id"]
            if pid and not is_fork_of_parent(rec["tags"], rec["title"], pid):
                return pid
            return btw_parent_target(rec["tags"])

        def resolve_anchor_project(start_id: str) -> tuple[str | None, bool]:
            seen: set[str] = {start_id}
            cur = records[start_id]
            found_anchor = False
            while True:
                nxt_id = non_fork_parent_or_btw_link(cur)
                if not nxt_id or nxt_id in seen or nxt_id not in records:
                    break
                seen.add(nxt_id)
                cur = records[nxt_id]
                found_anchor = True
            return cur["project"], found_anchor

        healed_split_children: list[dict[str, Any]] = []
        for mid, rec in records.items():
            link = non_fork_parent_or_btw_link(rec)
            if not link or link not in records:
                continue
            target_project, found = resolve_anchor_project(mid)
            if not found:
                continue
            if rec["project"] != target_project:
                before_project = rec["project"]
                rec["project"] = target_project
                rec["folder"] = ""
                rec["rev"] = rec["orig_rev"] + 1
                healed_split_children.append(
                    {
                        "mission_id": mid,
                        "from_project": before_project,
                        "to_project": target_project,
                        "new_placement_revision": rec["rev"],
                    }
                )

        updated_row_count = 0
        for mid, rec in records.items():
            if rec["tags_unparseable"]:
                next_raw_tags = rec["orig_raw_tags"]
            else:
                next_raw_tags = (
                    json.dumps(rec["tags"], separators=(",", ":"))
                    if rec["tags"]
                    else None
                )
            orig_tags_parsed = (
                None if rec["tags_unparseable"] else parse_tags(rec["orig_raw_tags"])
            )
            tags_semantic_changed = (
                not rec["tags_unparseable"] and orig_tags_parsed != rec["tags"]
            )
            next_raw_tags_to_write = (
                next_raw_tags if tags_semantic_changed else rec["orig_raw_tags"]
            )

            project_changed = rec["project"] != (
                rec["orig_project"].strip()
                if isinstance(rec["orig_project"], str)
                and rec["orig_project"].strip()
                else None
            )
            folder_changed = rec["folder"] != rec["orig_folder"]
            rev_changed = rec["rev"] != rec["orig_rev"]

            if not (
                project_changed
                or folder_changed
                or rev_changed
                or tags_semantic_changed
            ):
                continue

            updated_row_count += 1
            if not dry_run:
                conn.execute(
                    """
                    UPDATE missions
                    SET project = ?1,
                        folder = ?2,
                        placement_revision = ?3,
                        tags = ?4
                    WHERE id = ?5
                    """,
                    (
                        rec["project"],
                        rec["folder"],
                        rec["rev"],
                        next_raw_tags_to_write,
                        mid,
                    ),
                )

        if not dry_run:
            conn.execute("COMMIT")

        remaining_orb_folder_rows = (
            conn.execute(
                "SELECT COUNT(*) FROM missions WHERE tags LIKE '%\"orb-folder:%'"
            ).fetchone()[0]
            if not dry_run
            else 0
        )

        return {
            "db": str(db_path),
            "dry_run": dry_run,
            "total_missions_scanned": len(records),
            "schema": schema_info,
            "updated_rows": updated_row_count,
            "backfilled_folder_count": len(backfilled_folder_ids),
            "stripped_orb_folder_tag_count": len(stripped_tag_ids),
            "cleared_nested_child_folder_count": len(cleared_nested_folder_ids),
            "healed_split_family_count": len(healed_split_children),
            "healed_split_family": healed_split_children,
            "unparseable_tags_skipped": unparseable_tags_ids,
            "remaining_orb_folder_tag_rows": remaining_orb_folder_rows,
        }
    except Exception:
        if not dry_run and conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Migrate legacy orb-folder:* mission tags to missions.folder and heal split child/btw placement."
    )
    parser.add_argument(
        "--db",
        required=True,
        type=Path,
        help="Path to missions SQLite database (e.g. /root/.sandboxed-sh/missions/missions-prod.db)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Inspect and report planned updates in read-only mode without modifying the database.",
    )
    args = parser.parse_args(argv)

    receipt = migrate_db(args.db, dry_run=args.dry_run)
    json.dump(receipt, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
