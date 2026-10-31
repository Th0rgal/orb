#!/usr/bin/env python3
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

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

    def test_nested_mounts_inside_mission_and_scratch_caches_are_protected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fx = self._setup_fixture(root)

            # Nested bind mount inside a completed mission's .lake directory
            mounted_in_lake = fx["node"] / fx["done"] / "repo" / ".lake" / "shared_mount"
            mounted_in_lake.mkdir(parents=True)
            (mounted_in_lake / "precious.txt").write_text("do not erase")

            # Scratch step glob containing both a clean .elan and a target/ with nested mount
            scratch_step = root / "scratch" / "step-01"
            (scratch_step / ".elan").mkdir(parents=True)
            (scratch_step / ".elan" / "toolchain").write_bytes(b"t" * 256)
            mounted_in_scratch = scratch_step / "target" / "bind_src"
            mounted_in_scratch.mkdir(parents=True)
            (mounted_in_scratch / "lib.rs").write_text("pub fn keep() {}")

            mount_set = {
                os.path.normpath(os.path.abspath(str(mounted_in_lake))),
                os.path.normpath(os.path.abspath(str(mounted_in_scratch))),
            }

            records, ok = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=True,
                terminal_only=True,
                extra_step_globs=[str(root / "scratch" / "step-*")],
                open_file_probe=lambda _: ("clear", ""),
                mountpoints=mount_set,
            )
            self.assertTrue(ok)

            # Both nested-mount cache trees were skipped intact (including sibling build.olean)
            self.assertTrue((mounted_in_lake / "precious.txt").exists())
            self.assertTrue((fx["node"] / fx["done"] / "repo" / ".lake" / "build.olean").exists())
            self.assertTrue((mounted_in_scratch / "lib.rs").exists())

            # Sibling clean caches (.elan) in both mission and scratch were reclaimed
            self.assertFalse((fx["node"] / fx["done"] / ".elan").exists())
            self.assertFalse((scratch_step / ".elan").exists())

            skipped_mounts = [
                r for r in records
                if r.get("action") == "skip" and r.get("reason") == "nested_mount_protected"
            ]
            self.assertEqual(len(skipped_mounts), 2)

            # Direct rmtree_same_device also refuses a late/TOCTOU mount via os.path.ismount
            expected_dev = (fx["node"] / fx["done"]).lstat().st_dev
            with mock.patch("os.path.ismount", side_effect=lambda p: Path(p) == mounted_in_lake):
                with self.assertRaises(RuntimeError):
                    reclaim.rmtree_same_device(
                        fx["node"] / fx["done"] / "repo" / ".lake",
                        expected_dev,
                        mountpoints=frozenset(),
                    )
            self.assertTrue((mounted_in_lake / "precious.txt").exists())

    def test_nested_dot_cache_reclaimed_while_git_repos_with_cache_names_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fx = self._setup_fixture(root)
            done_dir = fx["node"] / fx["done"]

            # .cache/turbo-lean, .cache/mathlib, .cargo/registry, and conecache inside settled mission are reclaimed
            (done_dir / ".cache" / "turbo-lean").mkdir(parents=True)
            (done_dir / ".cache" / "turbo-lean" / "cas.db").write_bytes(b"c" * 512)
            (done_dir / ".cache" / "mathlib").mkdir(parents=True)
            (done_dir / ".cache" / "mathlib" / "blob").write_bytes(b"m" * 512)
            (done_dir / ".cargo" / "registry").mkdir(parents=True)
            (done_dir / ".cargo" / "registry" / "crate").write_bytes(b"r" * 512)
            (done_dir / ".cargo" / "config.toml").write_text("[net]\n")
            (done_dir / "conecache").mkdir(parents=True)
            (done_dir / "conecache" / "cone.bin").write_bytes(b"k" * 512)
            # Non-cache sibling under .cache (e.g. custom auth/state) stays untouched
            (done_dir / ".cache" / "custom-keep").mkdir(parents=True)
            (done_dir / ".cache" / "custom-keep" / "note.txt").write_text("keep")

            # A git checkout named 'turbo-lean' or 'toolchains' must NEVER be deleted
            (done_dir / "turbo-lean" / ".git").mkdir(parents=True)
            (done_dir / "turbo-lean" / "Cargo.toml").write_text("[package]\nname='turbo-lean'\n")
            (done_dir / "toolchains" / ".git").mkdir(parents=True)
            (done_dir / "toolchains" / "README.md").write_text("repo")

            records, ok = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=True,
                terminal_only=True,
                open_file_probe=lambda _: ("clear", ""),
            )
            self.assertTrue(ok)
            self.assertFalse((done_dir / ".cache" / "turbo-lean").exists())
            self.assertFalse((done_dir / ".cache" / "mathlib").exists())
            self.assertFalse((done_dir / ".cargo" / "registry").exists())
            self.assertTrue((done_dir / ".cargo" / "config.toml").exists())
            self.assertFalse((done_dir / "conecache").exists())
            self.assertTrue((done_dir / ".cache" / "custom-keep" / "note.txt").exists())
            self.assertTrue((done_dir / "turbo-lean" / "Cargo.toml").exists())
            self.assertTrue((done_dir / "toolchains" / "README.md").exists())
            reclaimed_kinds = {r["cache_kind"] for r in records if r.get("action") == "reclaimed"}
            self.assertIn("turbo-lean", reclaimed_kinds)
            self.assertIn("mathlib", reclaimed_kinds)
            self.assertIn("registry", reclaimed_kinds)
            self.assertIn("conecache", reclaimed_kinds)

    def test_idle_non_terminal_and_settled_orphan_caches_reclaimed_safely(self):
        import datetime as dt

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fx = self._setup_fixture(root)
            now = dt.datetime(2026, 1, 2, 12, 0, 0, tzinfo=dt.timezone.utc)

            # Add a recent awaiting_user mission (updated 30m ago -> must be protected)
            # and a settled job row for unknown/orphan mission (finished >24h ago -> eligible when orphan_idle_hours=6)
            m_recent_await = "88888888-8888-8888-8888-888888888888"
            conn = sqlite3.connect(fx["missions"] / "missions-prod.db")
            conn.execute(
                "INSERT INTO missions VALUES (?, ?, ?, ?)",
                (m_recent_await, "awaiting_user", "2026-01-02T11:30:00Z", "ws-8"),
            )
            conn.commit()
            conn.close()

            rdir = fx["node"] / m_recent_await
            (rdir / "repo" / ".lake").mkdir(parents=True)
            (rdir / "repo" / ".lake" / "build.olean").write_bytes(b"o" * 256)
            (rdir / "Main.lean").write_text("-- recent")

            jconn = sqlite3.connect(fx["node"] / "jobs.db")
            jconn.execute(
                "INSERT INTO jobs VALUES (?, ?, ?)",
                (fx["unknown"], "succeeded", "2026-01-01T02:00:00Z"),
            )
            jconn.commit()
            jconn.close()

            records, ok = reclaim.reclaim_worker_caches(
                node_work_dir=fx["node"],
                missions_dir=fx["missions"],
                apply=True,
                idle_hours=3.0,
                orphan_idle_hours=6.0,
                now_override=now,
                open_file_probe=lambda _: ("clear", ""),
            )
            self.assertTrue(ok)

            # Idle paused mission (updated >24h ago) & settled orphan had caches reclaimed, while source/.git stayed intact
            for reclaimed_id in (fx["paused"], fx["unknown"]):
                mdir = fx["node"] / reclaimed_id
                self.assertFalse((mdir / ".elan").exists(), reclaimed_id)
                self.assertFalse((mdir / "repo" / ".lake").exists(), reclaimed_id)
                self.assertTrue((mdir / "Main.lean").exists(), reclaimed_id)
                self.assertTrue((mdir / ".git" / "HEAD").exists(), reclaimed_id)

            # Active mission and recently-updated awaiting_user mission remain untouched
            self.assertTrue((fx["node"] / fx["active"] / "repo" / ".lake").exists())
            self.assertTrue((rdir / "repo" / ".lake").exists())
            statuses = {r.get("mission_status") for r in records if r.get("action") == "reclaimed"}
            self.assertIn("paused", statuses)
            self.assertIn("orphan_settled_jobs", statuses)

    def test_proc_open_file_probe_detects_fd_and_maps(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake_proc = root / "proc"
            pid_dir = fake_proc / "1234"
            (pid_dir / "fd").mkdir(parents=True)
            busy_dir = root / "node" / "busy-mission"
            idle_dir = root / "node" / "idle-mission"
            busy_file = busy_dir / "repo" / "Main.lean"
            mmap_file = root / "node" / "mmap-mission" / ".lake" / "mod.olean"
            busy_file.parent.mkdir(parents=True)
            mmap_file.parent.mkdir(parents=True)
            idle_dir.mkdir(parents=True)
            busy_file.write_text("-- busy")
            mmap_file.write_bytes(b"o" * 64)

            (pid_dir / "cwd").symlink_to(idle_dir.parent)
            (pid_dir / "fd" / "3").symlink_to(busy_file)
            (pid_dir / "maps").write_text(
                f"7f0000000000-7f0000001000 r--p 00000000 08:01 42 {mmap_file}\n"
            )

            probe = reclaim.build_proc_open_file_probe(proc_root=fake_proc, ttl_secs=60.0)
            self.assertIsNotNone(probe)
            self.assertEqual(probe(busy_dir)[0], "open")
            self.assertEqual(probe(mmap_file.parent.parent)[0], "open")
            self.assertEqual(probe(idle_dir), ("clear", ""))


if __name__ == "__main__":
    unittest.main()
