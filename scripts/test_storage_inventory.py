#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name("storage_inventory.py")


class StorageInventoryTest(unittest.TestCase):
    def test_local_workspace_inventory_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            missions = root / "missions"
            missions.mkdir()
            db = missions / "missions-thomas.db"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE missions (id TEXT, status TEXT, updated_at TEXT, workspace_id TEXT)")
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "active", "2026-01-01T00:00:00Z", "ws-a"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "completed", "2025-01-01T00:00:00Z", "ws-b"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("cccccccc-cccc-cccc-cccc-cccccccccccc", "completed", "2999-01-01T00:00:00Z", "ws-c"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("dddddddd-dddd-dddd-dddd-dddddddddddd", "paused", "2025-01-01T00:00:00Z", "ws-d"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "awaiting_user", "2025-01-01T00:00:00Z", "ws-e"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("abababab-abab-abab-abab-abababababab", "acknowledged", "2025-01-01T00:00:00Z", "ws-ack"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("ffffffff-ffff-ffff-ffff-ffffffffffff", "failed", "not-a-timestamp", "ws-f"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("99999999-0000-0000-0000-000000000001", "completed", "2025-01-01T00:00:00Z", "ws-g"))
            conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", ("99999999-0000-0000-0000-000000000002", "paused", "2025-01-01T00:00:00Z", "ws-g"))
            conn.commit()
            conn.close()

            workspaces = root / "workspaces"
            workspaces.mkdir()
            active = workspaces / "mission-aaaaaaaa"
            active.mkdir()
            (active / "live").write_text("x")
            old = workspaces / "mission-bbbbbbbb"
            old.mkdir()
            (old / "old").write_text("x" * 32)
            recently_updated = workspaces / "mission-cccccccc"
            recently_updated.mkdir()
            paused = workspaces / "mission-dddddddd"
            paused.mkdir()
            awaiting_user = workspaces / "mission-eeeeeeee"
            awaiting_user.mkdir()
            acknowledged = workspaces / "mission-abababab"
            acknowledged.mkdir()
            invalid_timestamp = workspaces / "mission-ffffffff"
            invalid_timestamp.mkdir()
            collided = workspaces / "mission-99999999"
            collided.mkdir()
            cache = workspaces / "cache"
            cache.mkdir()
            (cache / "artifact").write_text("x" * 32)
            lean_cache = old / ".lake"
            lean_cache.mkdir()
            (lean_cache / "olean").write_text("x" * 32)

            old_time = time.time() - 20 * 86400
            for path in (old, recently_updated, paused, awaiting_user, acknowledged, invalid_timestamp, collided, cache, lean_cache):
                os.utime(path, (old_time, old_time))

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--missions-dir", str(missions), "--root", str(workspaces), "--retention-days", "7"],
                check=True,
                capture_output=True,
                text=True,
            )
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            items = {Path(row["path"]).name: row for row in rows if row["record_type"] == "storage_item"}
            self.assertEqual(items["mission-aaaaaaaa"]["action"], "keep")
            self.assertEqual(items["mission-aaaaaaaa"]["owner"], "thomas")
            self.assertEqual(items["mission-bbbbbbbb"]["action"], "would_remove")
            self.assertEqual(items["mission-cccccccc"]["action"], "keep")
            self.assertEqual(items["mission-cccccccc"]["reason"], "within_retention")
            self.assertEqual(items["mission-dddddddd"]["action"], "keep")
            self.assertEqual(items["mission-dddddddd"]["reason"], "non_terminal_mission_protected")
            self.assertEqual(items["mission-eeeeeeee"]["action"], "keep")
            self.assertEqual(items["mission-eeeeeeee"]["reason"], "non_terminal_mission_protected")
            self.assertEqual(items["mission-abababab"]["action"], "keep")
            self.assertEqual(items["mission-abababab"]["reason"], "non_terminal_mission_protected")
            self.assertEqual(items["mission-ffffffff"]["action"], "keep")
            self.assertEqual(items["mission-ffffffff"]["reason"], "mission_timestamp_invalid")
            self.assertEqual(items["mission-99999999"]["action"], "keep")
            self.assertEqual(items["mission-99999999"]["reason"], "short_id_collision_protected")
            self.assertEqual(items["cache"]["action"], "keep")
            self.assertEqual(items["cache"]["reason"], "unattributed_requires_owner_approval")
            self.assertEqual(items[".lake"]["kind"], "build_cache")
            self.assertEqual(items[".lake"]["owner"], "thomas")
            self.assertEqual(items[".lake"]["action"], "keep")

            worktree = workspaces / "worktrees"
            worktree.mkdir()
            (worktree / ".git").write_text("gitdir: elsewhere")
            image = workspaces / "images"
            image.mkdir()
            unknown = workspaces / "unattributed-old"
            unknown.mkdir()
            for path in (worktree, image, unknown):
                os.utime(path, (old_time, old_time))
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--missions-dir", str(missions), "--root", str(workspaces), "--retention-days", "7"],
                check=True,
                capture_output=True,
                text=True,
            )
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            items = {Path(row["path"]).name: row for row in rows if row["record_type"] == "storage_item"}
            for name in (".lake", "worktrees", "images", "unattributed-old"):
                self.assertEqual(items[name]["action"], "keep", name)

            legacy = missions / "missions-legacy.json"
            legacy.write_text('{"missions": {}}')
            audit_log = root / "storage-audit.jsonl"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--missions-dir",
                    str(missions),
                    "--root",
                    str(workspaces),
                    "--retention-days",
                    "7",
                    "--audit-log",
                    str(audit_log),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            audit_rows = [json.loads(line) for line in audit_log.read_text().splitlines()]
            self.assertTrue(any(row.get("action") == "index_error" and row.get("path") == str(legacy) for row in rows))
            self.assertEqual(audit_rows, rows)
            items = {Path(row["path"]).name: row for row in rows if row["record_type"] == "storage_item"}
            self.assertEqual(items["mission-bbbbbbbb"]["action"], "keep")
            self.assertEqual(items["mission-bbbbbbbb"]["reason"], "mission_attribution_incomplete")
            legacy.unlink()

            broken = missions / "missions-broken.db"
            broken.write_text("not sqlite")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--missions-dir", str(missions), "--root", str(workspaces), "--retention-days", "7"],
                check=True,
                capture_output=True,
                text=True,
            )
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            items = {Path(row["path"]).name: row for row in rows if row["record_type"] == "storage_item"}
            self.assertEqual(items["mission-bbbbbbbb"]["action"], "keep")
            self.assertEqual(items["mission-bbbbbbbb"]["reason"], "mission_attribution_incomplete")

    def test_node_work_dir_attribution_without_core_db(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            node = root / "node"
            node.mkdir()
            mid = "12345678-1234-1234-1234-123456789abc"
            mission = node / mid
            mission.mkdir()
            lake = mission / ".lake"
            lake.mkdir()
            (lake / "artifact").write_bytes(b"x" * 1024)
            outside = root / "outside"
            outside.mkdir()
            (outside / "secret").write_bytes(b"x" * 4096)
            (node / "external").symlink_to(outside, target_is_directory=True)
            conn = sqlite3.connect(node / "jobs.db")
            conn.execute("CREATE TABLE jobs (mission_id TEXT, state TEXT, finished_at TEXT)")
            conn.executemany(
                "INSERT INTO jobs VALUES (?, ?, ?)",
                [(mid, "succeeded", "2020-01-01T00:00:00Z"), (mid, "running", None)],
            )
            conn.commit()
            conn.close()

            command = [sys.executable, str(SCRIPT), "--node-work-dir", str(node)]
            result = subprocess.run(command, check=True, capture_output=True, text=True)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            items = {Path(row["path"]).name: row for row in rows if row["record_type"] == "storage_item"}
            self.assertNotIn("external", items)
            for name in [mid, ".lake"]:
                self.assertEqual(items[name]["action"], "keep")
                self.assertEqual(items[name]["mission_id"], mid)
                self.assertEqual(items[name]["node_job_states"], {"running": 1, "succeeded": 1})
                self.assertEqual(items[name]["reason"], "node_job_history_is_not_discard_authorization")
                self.assertEqual(items[name]["size_bytes"], 1024)
                self.assertGreaterEqual(items[name]["allocated_bytes"], 0)
                self.assertIsNone(items[name]["reclaimable_bytes"])

            (node / "jobs.db").unlink()
            result = subprocess.run(command, check=True, capture_output=True, text=True)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertTrue(any(row.get("action") == "index_error" for row in rows))
            self.assertTrue(all(row["action"] == "keep" for row in rows if row["record_type"] == "storage_item"))
            self.assertFalse((node / "jobs.db").exists())
            self.assertNotEqual(subprocess.run(command + ["--apply"], capture_output=True).returncode, 0)
            self.assertTrue((lake / "artifact").exists())

    def test_core_plus_node_enrichment_and_snapshot_export(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            missions = root / "missions"
            missions.mkdir()
            mid_ack = "042f7c05-9d89-4e7f-a5c1-0616a529c605"
            mid_comp = "bcbd2c6f-968b-4eca-ad7d-1199ee6e9a45"

            # Same mission ID across prod and dev DBs must NOT trigger short_id_collision, and prod wins
            for db_name, status_val in (("missions-dev.db", "completed"), ("missions-prod.db", "acknowledged")):
                conn = sqlite3.connect(missions / db_name)
                conn.execute("CREATE TABLE missions (id TEXT, status TEXT, updated_at TEXT, workspace_id TEXT)")
                conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", (mid_ack, status_val, "2020-01-01T00:00:00Z", "ws-ffmpeg"))
                conn.execute("INSERT INTO missions VALUES (?, ?, ?, ?)", (mid_comp, "completed", "2020-01-01T00:00:00Z", "ws-bench"))
                conn.commit()
                conn.close()

            snapshot = root / "missions-snapshot.jsonl"
            subprocess.run(
                [sys.executable, str(SCRIPT), "--missions-dir", str(missions), "--export-missions", str(snapshot)],
                check=True,
                capture_output=True,
                text=True,
            )
            snap_lines = [json.loads(line) for line in snapshot.read_text().splitlines()]
            self.assertEqual(len(snap_lines), 2)

            node = root / "node"
            node.mkdir()
            ack_dir = node / mid_ack
            ack_dir.mkdir()
            (ack_dir / ".elan").mkdir()
            (ack_dir / ".elan" / "bin").write_bytes(b"y" * 512)
            comp_dir = node / mid_comp
            comp_dir.mkdir()
            (comp_dir / ".rustup").mkdir()
            (comp_dir / ".rustup" / "tc").write_bytes(b"z" * 256)

            conn = sqlite3.connect(node / "jobs.db")
            conn.execute("CREATE TABLE jobs (mission_id TEXT, state TEXT, finished_at TEXT)")
            conn.execute("INSERT INTO jobs VALUES (?, ?, ?)", (mid_ack, "succeeded", "2020-01-02T00:00:00Z"))
            conn.commit()
            conn.close()

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--missions-snapshot", str(snapshot), "--node-work-dir", str(node), "--retention-days", "7"],
                check=True,
                capture_output=True,
                text=True,
            )
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            items = {Path(row["path"]).name: row for row in rows if row["record_type"] == "storage_item"}

            # Enriched with Core status/owner/workspace, while keeping remote source protected
            self.assertEqual(items[mid_ack]["action"], "keep")
            self.assertEqual(items[mid_ack]["reason"], "node_job_history_is_not_discard_authorization")
            self.assertEqual(items[mid_ack]["mission_status"], "acknowledged")
            self.assertEqual(items[mid_ack]["owner"], "prod")
            self.assertEqual(items[mid_ack]["workspace_id"], "ws-ffmpeg")
            self.assertEqual(items[mid_ack]["node_job_states"], {"succeeded": 1})

            # UUID directory in node_work_dir without jobs.db rows is also attributed via Core snapshot and kept
            self.assertEqual(items[mid_comp]["action"], "keep")
            self.assertEqual(items[mid_comp]["reason"], "node_job_history_is_not_discard_authorization")
            self.assertEqual(items[mid_comp]["mission_status"], "completed")
            self.assertEqual(items[mid_comp]["owner"], "prod")
            self.assertEqual(items[".elan"]["kind"], "build_cache")
            self.assertEqual(items[".rustup"]["kind"], "build_cache")

            # Corrupt snapshot fails closed
            bad_snap = root / "bad.jsonl"
            bad_snap.write_text("{not-json\n")
            local_ws = root / "local_ws"
            local_ws.mkdir()
            m_dir = local_ws / f"mission-{mid_comp[:8]}"
            m_dir.mkdir()
            old_time = time.time() - 20 * 86400
            os.utime(m_dir, (old_time, old_time))
            bad_res = subprocess.run(
                [sys.executable, str(SCRIPT), "--missions-snapshot", str(bad_snap), "--root", str(local_ws), "--retention-days", "7"],
                check=True,
                capture_output=True,
                text=True,
            )
            bad_rows = [json.loads(line) for line in bad_res.stdout.splitlines()]
            self.assertTrue(any(r.get("action") == "index_error" for r in bad_rows))
            bad_items = {Path(r["path"]).name: r for r in bad_rows if r["record_type"] == "storage_item"}
            self.assertEqual(bad_items[f"mission-{mid_comp[:8]}"]["action"], "keep")
            self.assertEqual(bad_items[f"mission-{mid_comp[:8]}"]["reason"], "mission_attribution_incomplete")


if __name__ == "__main__":
    unittest.main()
