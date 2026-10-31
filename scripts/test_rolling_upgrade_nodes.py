#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import rolling_upgrade_nodes as roll  # noqa: E402


class FakeNodeOps:
    def __init__(self, remote_state, local_state=None):
        self.remote_state = remote_state
        self.local_state = dict(
            local_state or {"staged": False, "running": 0, "healthy": True, "quarantined": False}
        )
        self.upgraded_remotes = []
        self.upgraded_local = False
        self.stopped_timers = []

    def probe_remote(self, host, _db_path):
        st = self.remote_state[host]
        if st.get("fail_probe"):
            raise RuntimeError(f"simulated ssh error on {host}")
        return {
            "staged": bool(st.get("staged", False)),
            "running": int(st.get("running", 0)),
            "healthy": bool(st.get("healthy", True)),
            "quarantined": bool(st.get("quarantined", False)),
        }

    def upgrade_remote(self, host, _db_path):
        st = self.remote_state[host]
        if st.get("fail_upgrade"):
            st["staged"] = False
            st["quarantined"] = True
            raise RuntimeError(f"activation failed on {host}")
        if st.get("busy_on_upgrade") or st.get("running", 0) != 0:
            return "BUSY:1"
        st["staged"] = False
        st["quarantined"] = False
        st["healthy"] = True
        self.upgraded_remotes.append(host)
        return "UPGRADED"

    def probe_local(self, _db_path):
        return {
            "staged": bool(self.local_state.get("staged", False)),
            "running": int(self.local_state.get("running", 0)),
            "healthy": bool(self.local_state.get("healthy", True)),
            "quarantined": bool(self.local_state.get("quarantined", False)),
        }

    def upgrade_local(self, _db_path):
        if self.local_state.get("fail_upgrade"):
            self.local_state["staged"] = False
            self.local_state["quarantined"] = True
            raise RuntimeError("local activation failed")
        if self.local_state.get("running", 0) != 0:
            return f"BUSY:{self.local_state['running']}"
        self.local_state["staged"] = False
        self.local_state["quarantined"] = False
        self.local_state["healthy"] = True
        self.upgraded_local = True
        return "UPGRADED"

    def stop_timer(self, unit_name):
        self.stopped_timers.append(unit_name)


def _start_core_api_server(cordoned):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            if self.path == "/api/remote-nodes":
                body = json.dumps({"nodes": [{"id": k, "cordoned": v} for k, v in cordoned.items()]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            content_len = int(self.headers.get("Content-Length", "0") or "0")
            if content_len > 0:
                self.rfile.read(content_len)
            parts = self.path.strip("/").split("/")
            if len(parts) == 4 and parts[0] == "api" and parts[1] == "nodes" and parts[3] in ("cordon", "uncordon"):
                node = parts[2]
                cordoned[node] = parts[3] == "cordon"
                body = json.dumps({"node": node, "cordoned": cordoned[node], "changed": True}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class RollingUpgradeNodesTest(unittest.TestCase):
    def test_wave_cordon_cap_probe_error_fail_closed_and_completion(self):
        cordoned = {"ashur": True, "nippur": True, "babylon": True, "old-agent": True}
        server = _start_core_api_server(cordoned)
        try:
            api = roll.HttpCoreApi(f"http://127.0.0.1:{server.server_port}", roll.mint_hs256_jwt("test-secret"))
            remote_nodes = [
                ("ashur", "/var/lib/sandboxed-node/jobs.db"),
                ("nippur", "/var/lib/sandboxed-node/jobs.db"),
                ("babylon", "/var/lib/sandboxed-node/jobs.db"),
                ("old-agent", "/var/lib/sandboxed-node/work/jobs.db"),
            ]
            ops = FakeNodeOps(
                {
                    "ashur": {"staged": True, "running": 1},
                    "nippur": {"staged": True, "running": 2},
                    "babylon": {"staged": True, "running": 3},
                    "old-agent": {"staged": True, "running": 4},
                },
                local_state={"staged": True, "running": 2, "healthy": True},
            )

            # Tick 1: uncordons excess Wave 2 nodes so max_concurrent_cordons=2 is respected
            events1, done1 = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=remote_nodes,
                local_jobs_db="/local/jobs.db",
                max_concurrent_cordons=2,
                apply=True,
                stop_timer_unit="sandboxed-node-rolling-upgrade.timer",
            )
            self.assertFalse(done1)
            self.assertTrue(cordoned["ashur"])
            self.assertTrue(cordoned["nippur"])
            self.assertFalse(cordoned["babylon"])
            self.assertFalse(cordoned["old-agent"])
            self.assertEqual(len([e for e in events1 if e["action"] == "uncordoned_excess_wave"]), 2)

            # Tick 2: transient SSH error on ashur must NOT cordon Wave 2 nodes
            ops.remote_state["ashur"]["fail_probe"] = True
            ops.remote_state["nippur"]["running"] = 0
            events2, done2 = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=remote_nodes,
                local_jobs_db="/local/jobs.db",
                max_concurrent_cordons=2,
                apply=True,
                stop_timer_unit="sandboxed-node-rolling-upgrade.timer",
            )
            self.assertFalse(done2)
            self.assertIn("nippur", ops.upgraded_remotes)
            self.assertFalse(cordoned["nippur"])
            self.assertFalse(cordoned["babylon"])
            self.assertTrue(any(e["action"] == "probe_error" for e in events2))

            # Tick 3: SSH recovers, ashur hits TOCTOU BUSY race -> deferred safely without uncordoning
            ops.remote_state["ashur"]["fail_probe"] = False
            ops.remote_state["ashur"]["running"] = 0
            ops.remote_state["ashur"]["busy_on_upgrade"] = True
            events3, done3 = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=remote_nodes,
                local_jobs_db="/local/jobs.db",
                max_concurrent_cordons=2,
                apply=True,
                stop_timer_unit="sandboxed-node-rolling-upgrade.timer",
            )
            self.assertFalse(done3)
            self.assertTrue(any(e["action"] == "upgrade_deferred" for e in events3))
            self.assertTrue(cordoned["ashur"])
            self.assertTrue(cordoned["babylon"])

            # Tick 4: all remaining jobs drain -> upgrades complete, uncordoned, timer stopped
            ops.remote_state["ashur"]["busy_on_upgrade"] = False
            for host in ("ashur", "babylon", "old-agent"):
                ops.remote_state[host]["running"] = 0
            ops.local_state["running"] = 0

            _, done4 = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=remote_nodes,
                local_jobs_db="/local/jobs.db",
                max_concurrent_cordons=2,
                apply=True,
                stop_timer_unit="sandboxed-node-rolling-upgrade.timer",
            )
            self.assertTrue(done4)
            self.assertTrue(ops.upgraded_local)
            self.assertEqual(set(ops.upgraded_remotes), {"ashur", "nippur", "babylon", "old-agent"})
            self.assertTrue(all(not v for v in cordoned.values()))
            self.assertEqual(ops.stopped_timers, ["sandboxed-node-rolling-upgrade.timer"])
        finally:
            server.shutdown()
            server.server_close()

    def test_failed_or_unhealthy_upgrade_never_uncordons_or_declares_complete(self):
        cordoned = {"ashur": True, "nippur": False}
        server = _start_core_api_server(cordoned)
        try:
            api = roll.HttpCoreApi(f"http://127.0.0.1:{server.server_port}", roll.mint_hs256_jwt("test-secret"))
            remote_nodes = [("ashur", "/jobs.db"), ("nippur", "/jobs.db")]
            ops = FakeNodeOps(
                {
                    "ashur": {"staged": True, "running": 0, "fail_upgrade": True},
                    "nippur": {"staged": True, "running": 0},
                },
                local_state={"staged": False, "running": 0, "healthy": False},
            )

            # Tick 1: ashur fails activation -> quarantined, stays cordoned, nippur NOT cordoned, timer NOT stopped
            ev1, done1 = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=remote_nodes,
                local_jobs_db="/local/jobs.db",
                max_concurrent_cordons=2,
                apply=True,
                stop_timer_unit="upgrade.timer",
            )
            self.assertFalse(done1)
            self.assertTrue(cordoned["ashur"])
            self.assertFalse(cordoned["nippur"])
            self.assertEqual(ops.stopped_timers, [])
            self.assertTrue(any(e["action"] == "upgrade_failed" and e["node"] == "ashur" for e in ev1))
            self.assertTrue(any(e["action"] == "unhealthy_local" for e in ev1))

            # Tick 2: ashur has staged=False & healthy=True (rolled back), but quarantined=True -> STILL incomplete!
            ev2, done2 = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=remote_nodes,
                local_jobs_db="/local/jobs.db",
                max_concurrent_cordons=2,
                apply=True,
                stop_timer_unit="upgrade.timer",
            )
            self.assertFalse(done2)
            self.assertTrue(cordoned["ashur"])
            self.assertEqual(ops.stopped_timers, [])
            self.assertTrue(any(e["action"] == "upgrade_quarantined" and e["node"] == "ashur" for e in ev2))
        finally:
            server.shutdown()
            server.server_close()

    def test_perform_fenced_upgrade_rollback_and_admission_fence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db_path = root / "jobs.db"
            con = sqlite3.connect(db_path)
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            con.commit()
            con.close()

            bin_path = root / "sandboxed-node"
            staged_path = root / "sandboxed-node.new"
            failed_path = root / "sandboxed-node.new.failed"
            backup_path = root / "sandboxed-node.prev"
            bin_path.write_text("v1-good")
            staged_path.write_text("v2-broken")

            # 1. Activation failure rolls back binary, quarantines .new -> .new.failed, and restarts v1
            events = []

            class FailingStartCtl:
                def is_active(self, _unit):
                    return False

                def stop(self, _unit):
                    events.append("stop")

                def start(self, _unit):
                    events.append("start_v2")
                    raise RuntimeError("v2 crashed on start")

                def start_best_effort(self, _unit):
                    events.append("start_best_effort")

                def restart_best_effort(self, _unit):
                    events.append(f"restart_rollback:{bin_path.read_text()}")

            with self.assertRaises(RuntimeError):
                roll.perform_fenced_upgrade(
                    db_path=str(db_path),
                    binary_path=str(bin_path),
                    verify_delay_secs=0.0,
                    service_ctl=FailingStartCtl(),
                    runtime_busy_probe=lambda: 0,
                    live_work_dir_probe=lambda: str(root),
                )

            self.assertEqual(bin_path.read_text(), "v1-good")
            self.assertEqual(backup_path.read_text(), "v1-good")
            self.assertFalse(staged_path.exists())
            self.assertTrue(failed_path.exists())
            self.assertIn("restart_rollback:v1-good", events)

            probe_after_fail = roll.probe_worker_state(
                str(db_path),
                binary_path=str(bin_path),
                service_ctl=type("HealthyCtl", (), {"is_active": lambda self, _u: True})(),
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(root),
            )
            self.assertFalse(probe_after_fail["staged"])
            self.assertTrue(probe_after_fail["quarantined"])

            # 2. Admission fence blocks concurrent job INSERT arriving before stop completes
            staged_path.write_text("v2-fixed")
            daemon_alive = threading.Event()
            daemon_alive.set()
            writer_attempted = threading.Event()
            writer_outcomes = []

            def late_job_submission():
                writer_attempted.wait(timeout=5.0)
                wcon = sqlite3.connect(db_path, timeout=0.15, isolation_level=None)
                try:
                    wcon.execute("BEGIN IMMEDIATE")
                    if not daemon_alive.is_set():
                        wcon.execute("ROLLBACK")
                        writer_outcomes.append("daemon_already_stopped")
                        return
                    wcon.execute("INSERT INTO jobs VALUES ('late-1', 'queued')")
                    wcon.execute("COMMIT")
                    writer_outcomes.append("inserted")
                except sqlite3.OperationalError:
                    writer_outcomes.append("blocked_by_fence")
                finally:
                    wcon.close()

            t = threading.Thread(target=late_job_submission)
            t.start()

            class FencedSuccessCtl:
                def is_active(self, _unit):
                    return True

                def stop(self, _unit):
                    # Trigger concurrent submission while fence is held and daemon is stopping
                    writer_attempted.set()
                    time.sleep(0.25)
                    daemon_alive.clear()

                def start(self, _unit):
                    pass

                def start_best_effort(self, _unit):
                    pass

                def restart_best_effort(self, _unit):
                    pass

            res = roll.perform_fenced_upgrade(
                db_path=str(db_path),
                binary_path=str(bin_path),
                verify_delay_secs=0.01,
                service_ctl=FencedSuccessCtl(),
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(root),
            )
            t.join(timeout=5.0)

            self.assertEqual(res, "UPGRADED")
            self.assertEqual(writer_outcomes, ["blocked_by_fence"])
            self.assertEqual(bin_path.read_text(), "v2-fixed")
            self.assertFalse(staged_path.exists())
            self.assertFalse(failed_path.exists())

            verify_con = sqlite3.connect(db_path)
            queued_rows = verify_con.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]
            verify_con.close()
            self.assertEqual(queued_rows, 0)

            # 3. Verify _remote_worker_prelude() executes cleanly in a standalone Python process
            prelude_check = (
                roll._remote_worker_prelude()
                + "\nctl = type('C', (), {'is_active': lambda s, u: True})()"
                + f"\nprint(json.dumps(probe_worker_state(None, binary_path={str(bin_path)!r}, service_ctl=ctl, runtime_busy_probe=lambda: 0, live_work_dir_probe=lambda: {str(root)!r})))\n"
            )
            proc = subprocess.run([sys.executable, "-"], input=prelude_check, capture_output=True, text=True, check=True)
            parsed = json.loads(proc.stdout.strip())
            self.assertEqual(parsed, {"staged": False, "running": 0, "healthy": True, "quarantined": False})

    def test_missing_schemaless_or_mismatched_ledgers_fail_closed_and_wave_halts(self):
        self.assertEqual(roll.parse_node_spec("ashur"), ("ashur", None))
        self.assertEqual(
            roll.parse_node_spec("ashur:/var/lib/sandboxed-node/jobs.db"),
            ("ashur", "/var/lib/sandboxed-node/jobs.db"),
        )

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            missing_db = root / "nonexistent" / "jobs.db"
            bin_path = root / "sandboxed-node"
            staged_path = root / "sandboxed-node.new"
            bin_path.write_text("v1")
            staged_path.write_text("v2")

            noop_ctl = type(
                "NoopCtl",
                (),
                {
                    "is_active": lambda s, _u: True,
                    "stop": lambda s, _u: None,
                    "start": lambda s, _u: None,
                    "start_best_effort": lambda s, _u: None,
                    "restart_best_effort": lambda s, _u: None,
                },
            )()

            # Missing DB raises and NEVER creates a phantom empty jobs.db
            with self.assertRaises(RuntimeError):
                roll.perform_fenced_upgrade(
                    db_path=str(missing_db),
                    binary_path=str(bin_path),
                    verify_delay_secs=0.0,
                    service_ctl=noop_ctl,
                    runtime_busy_probe=lambda: 0,
                    live_work_dir_probe=lambda: None,
                )
            self.assertFalse(missing_db.exists())

            # Schema-less SQLite file (no 'jobs' table) fails closed
            empty_db = root / "empty.db"
            sqlite3.connect(empty_db).close()
            with self.assertRaises(RuntimeError):
                roll.probe_worker_state(
                    db_path=str(empty_db),
                    binary_path=str(bin_path),
                    service_ctl=noop_ctl,
                    runtime_busy_probe=lambda: 0,
                    live_work_dir_probe=lambda: None,
                )

            # Explicit db_path mismatching live worker SANDBOXED_NODE_WORK_DIR fails closed
            live_dir = root / "work"
            live_dir.mkdir()
            real_db = live_dir / "jobs.db"
            c = sqlite3.connect(real_db)
            c.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            c.commit()
            c.close()

            wrong_db = root / "jobs.db"
            c2 = sqlite3.connect(wrong_db)
            c2.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            c2.commit()
            c2.close()

            with self.assertRaises(RuntimeError):
                roll.perform_fenced_upgrade(
                    db_path=str(wrong_db),
                    binary_path=str(bin_path),
                    verify_delay_secs=0.0,
                    service_ctl=noop_ctl,
                    runtime_busy_probe=lambda: 0,
                    live_work_dir_probe=lambda: str(live_dir),
                )

        # Mid-wave failure on first candidate stops before cordoning/upgrading second candidate
        cordoned = {"ashur": False, "nippur": False}
        server = _start_core_api_server(cordoned)
        try:
            api = roll.HttpCoreApi(f"http://127.0.0.1:{server.server_port}", roll.mint_hs256_jwt("test-secret"))
            ops = FakeNodeOps(
                {
                    "ashur": {"staged": True, "running": 0, "fail_upgrade": True},
                    "nippur": {"staged": True, "running": 0},
                }
            )
            evs, done = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=[("ashur", None), ("nippur", None)],
                max_concurrent_cordons=2,
                apply=True,
            )
            self.assertFalse(done)
            self.assertTrue(cordoned["ashur"])
            self.assertFalse(cordoned["nippur"])
            self.assertEqual(ops.upgraded_remotes, [])
            self.assertTrue(any(e["action"] == "upgrade_failed" and e["node"] == "ashur" for e in evs))
        finally:
            server.shutdown()
            server.server_close()

    def test_sibling_worker_units_sharing_binary_are_fenced_and_restarted_together(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            primary_dir = root / "primary"
            admin_dir = root / "admin"
            primary_dir.mkdir()
            admin_dir.mkdir()
            primary_db = primary_dir / "jobs.db"
            admin_db = admin_dir / "jobs.db"
            for db in (primary_db, admin_db):
                con = sqlite3.connect(db)
                con.execute("PRAGMA journal_mode=WAL")
                con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
                con.commit()
                con.close()

            bin_path = root / "sandboxed-node"
            staged_path = root / "sandboxed-node.new"
            bin_path.write_text("v1")
            staged_path.write_text("v2")

            # Active job on sibling unit (sandboxed-node-admin) blocks both probe and upgrade
            con = sqlite3.connect(admin_db)
            con.execute("INSERT INTO jobs VALUES ('admin-job-1', 'running')")
            con.commit()
            con.close()

            actions = []

            class MultiUnitCtl:
                def __init__(self, fail_sibling_start=False):
                    self.fail_sibling_start = fail_sibling_start
                    self.active = {"sandboxed-node": True, "sandboxed-node-admin": True}

                def is_active(self, unit):
                    return self.active.get(unit, False)

                def stop(self, unit):
                    actions.append(f"stop:{unit}")
                    self.active[unit] = False

                def start(self, unit):
                    actions.append(f"start:{unit}:{bin_path.read_text()}")
                    if self.fail_sibling_start and unit == "sandboxed-node-admin":
                        raise RuntimeError("admin unit failed to start")
                    self.active[unit] = True

                def start_best_effort(self, unit):
                    actions.append(f"start_best_effort:{unit}")
                    self.active[unit] = True

                def restart_best_effort(self, unit):
                    actions.append(f"restart_rollback:{unit}:{bin_path.read_text()}")
                    self.active[unit] = True

            sibling_probe = lambda: [("sandboxed-node-admin", str(admin_db), lambda: 0)]
            ctl = MultiUnitCtl()
            probe_busy = roll.probe_worker_state(
                db_path=str(primary_db),
                binary_path=str(bin_path),
                service_ctl=ctl,
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(primary_dir),
                sibling_units_probe=sibling_probe,
            )
            self.assertEqual(probe_busy, {"staged": True, "running": 1, "healthy": True, "quarantined": False})

            busy_res = roll.perform_fenced_upgrade(
                db_path=str(primary_db),
                binary_path=str(bin_path),
                verify_delay_secs=0.0,
                service_ctl=ctl,
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(primary_dir),
                sibling_units_probe=sibling_probe,
            )
            self.assertEqual(busy_res, "BUSY:1")
            self.assertEqual(actions, [])

            # Settle sibling job -> upgrade stops and restarts BOTH units cleanly
            con = sqlite3.connect(admin_db)
            con.execute("UPDATE jobs SET state = 'succeeded'")
            con.commit()
            con.close()

            ok_res = roll.perform_fenced_upgrade(
                db_path=str(primary_db),
                binary_path=str(bin_path),
                verify_delay_secs=0.0,
                service_ctl=ctl,
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(primary_dir),
                sibling_units_probe=sibling_probe,
            )
            self.assertEqual(ok_res, "UPGRADED")
            self.assertEqual(
                actions,
                [
                    "stop:sandboxed-node",
                    "stop:sandboxed-node-admin",
                    "start:sandboxed-node:v2",
                    "start:sandboxed-node-admin:v2",
                ],
            )
            self.assertEqual(bin_path.read_text(), "v2")

            # Sibling start failure rolls back binary and restarts BOTH units on previous binary
            actions.clear()
            staged_path.write_text("v3-bad")
            fail_ctl = MultiUnitCtl(fail_sibling_start=True)
            with self.assertRaises(RuntimeError):
                roll.perform_fenced_upgrade(
                    db_path=str(primary_db),
                    binary_path=str(bin_path),
                    verify_delay_secs=0.0,
                    service_ctl=fail_ctl,
                    runtime_busy_probe=lambda: 0,
                    live_work_dir_probe=lambda: str(primary_dir),
                    sibling_units_probe=sibling_probe,
                )
            self.assertEqual(bin_path.read_text(), "v2")
            self.assertIn("restart_rollback:sandboxed-node:v2", actions)
            self.assertIn("restart_rollback:sandboxed-node-admin:v2", actions)


if __name__ == "__main__":
    unittest.main()
