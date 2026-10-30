#!/usr/bin/env python3
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import reclaim_worker_build_caches as reclaim  # noqa: E402


class ReclaimWorkerBuildCachesTest(unittest.TestCase):
    def _setup_fixture(self, root):
        missions = root / "missions"
        missions.mkdir()
        db = missions / "missions-prod.db"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE missions (id TEXT, status TEXT, updated_at TEXT, workspace_id TEXT)")
        m_done = "11111111-1111-1111-1111-111111111111"
        m_ack = "22222222-2222-2222-2222-222222222222"
        m_active = "33333333-3333-3333-3333-333333333333"
        m_paused = "44444444-4444-4444-4444-444444444444"
        m_running_job = "55555555-5555-5555-5555-555555555555"
        m_open_fd = "66666666-6666-6666-6666-666666666666"
        m_unknown = "77777777-7777-7777-7777-777777777777"

        conn.executemany(
            "INSERT INTO missions VALUES (?, ?, ?, ?)",
            [
                (m_done, "completed", "2026-01-01T00:00:00Z", "ws-1"),
                (m_ack, "acknowledged", "2026-01-01T00:00:00Z", "ws-2"),
                (m_active, "active", "2026-01-01T00:00:00Z", "ws-3"),
                (m_paused, "paused", "2026-01-01T00:00:00Z", "ws-4"),
                (m_running_job, "acknowledged", "2026-01-01T00:00:00Z", "ws-5"),
                (m_open_fd, "completed", "2026-01-01T00:00:00Z", "ws-6"),
            ],
        )
        conn.commit()
        conn.close()

        node = root / "node"
        node.mkdir()
        jconn = sqlite3.connect(node / "jobs.db")
        jconn.execute("CREATE TABLE jobs (mission_id TEXT, state TEXT, finished_at TEXT)")
        jconn.executemany(
            "INSERT INTO jobs VALUES (?, ?, ?)",
            [
                (m_done, "succeeded", "2026-01-01T01:00:00Z"),
                (m_ack, "lost", None),
                (m_active, "running", None),
                (m_running_job, "running", None),
                (m_open_fd, "succeeded", "2026-01-01T01:00:00Z"),
            ],
        )
        jconn.commit()
        jconn.close()

        outside = root / "outside_target"
        outside.mkdir()
        (outside / "keep.txt").write_text("external")

        for mid in (m_done, m_ack, m_active, m_paused, m_running_job, m_open_fd, m_unknown):
            mdir = node / mid
            mdir.mkdir()
            (mdir / "Main.lean").write_text("-- mission source")
            git_dir = mdir / ".git"
            git_dir.mkdir()
            (git_dir / "HEAD").write_text("ref: refs/heads/main\n")
            lake = mdir / "repo" / ".lake"
            lake.mkdir(parents=True)
            (lake / "build.olean").write_bytes(b"o" * 512)
            elan = mdir / ".elan"
            elan.mkdir()
            (elan / "lean").write_bytes(b"e" * 512)
            # Symlink named 'target' must never be traversed or delete external target
            (mdir / "target").symlink_to(outside, target_is_directory=True)

        return {
            "missions": missions,
            "node": node,
            "outside": outside,
            "done": m_done,
            "ack": m_ack,
            "active": m_active,
            "paused": m_paused,
            "running_job": m_running_job,
            "open_fd": m_open_fd,
            "unknown": m_unknown,
        }

    def test_dry_run_and_apply_preserve_sources_and_protect_live_missions(self):
        with tempfile.TemporaryDirectory() as temp:
            fx = self._setup_fixture(Path(temp))

            def fake_probe(path):
                if Path(path).name == fx["open_fd"]:
                    return "open", "opencode cwd"
                return "clear", ""

            # 1. Dry-run never deletes anything
            records, ok = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=False,
                open_file_probe=fake_probe,
            )
            self.assertTrue(ok)
            self.assertTrue((fx["node"] / fx["done"] / ".elan").exists())
            self.assertTrue((fx["node"] / fx["ack"] / "repo" / ".lake").exists())
            would = [r for r in records if r.get("action") == "would_reclaim"]
            self.assertEqual(len(would), 4)

            # 2. --terminal-only skips 'acknowledged' missions
            t_records, t_ok = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=False,
                terminal_only=True,
                open_file_probe=fake_probe,
            )
            self.assertTrue(t_ok)
            self.assertEqual(len([r for r in t_records if r.get("action") == "would_reclaim"]), 2)

            # 3. --apply deletes only reconstructible caches inside done + ack, preserving source/.git/symlinks
            apply_records, apply_ok = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=True,
                open_file_probe=fake_probe,
            )
            self.assertTrue(apply_ok)
            reclaimed = [r for r in apply_records if r.get("action") == "reclaimed"]
            self.assertEqual(len(reclaimed), 4)

            for eligible_id in (fx["done"], fx["ack"]):
                mdir = fx["node"] / eligible_id
                self.assertFalse((mdir / ".elan").exists())
                self.assertFalse((mdir / "repo" / ".lake").exists())
                # Source, .git, and symlink target remain intact
                self.assertTrue((mdir / "Main.lean").exists())
                self.assertTrue((mdir / ".git" / "HEAD").exists())
                self.assertTrue((fx["outside"] / "keep.txt").exists())

            # Protected missions retain all caches untouched
            for protected_id in (fx["active"], fx["paused"], fx["running_job"], fx["open_fd"], fx["unknown"]):
                mdir = fx["node"] / protected_id
                self.assertTrue((mdir / ".elan").exists(), protected_id)
                self.assertTrue((mdir / "repo" / ".lake").exists(), protected_id)

            reasons = {
                (r.get("mission_id"), r.get("reason"))
                for r in apply_records
                if r.get("action") == "skip"
            }
            self.assertIn((fx["running_job"], "active_node_job_protected"), reasons)
            self.assertIn((fx["open_fd"], "open_files_protected"), reasons)

    def test_incomplete_indexes_and_probe_errors_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            fx = self._setup_fixture(Path(temp))

            # Probe error skips fail-closed even under --apply
            records, ok = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=True,
                open_file_probe=lambda _: ("error", "lsof binary is not installed"),
            )
            self.assertTrue(ok)
            self.assertTrue((fx["node"] / fx["done"] / ".elan").exists())
            self.assertTrue(any(r.get("reason") == "open_file_probe_failed" for r in records))

            # Corrupt Core DB aborts with ok=False and deletes nothing
            (fx["missions"] / "missions-corrupt.db").write_text("not-sqlite")
            records2, ok2 = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=True,
                open_file_probe=lambda _: ("clear", ""),
            )
            self.assertFalse(ok2)
            self.assertTrue(any(r.get("action") == "aborted_incomplete_index" for r in records2))
            self.assertTrue((fx["node"] / fx["done"] / ".elan").exists())


if __name__ == "__main__":
    unittest.main()
