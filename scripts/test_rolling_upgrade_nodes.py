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
from unittest.mock import patch

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
    def test_auto_discovery_refuses_core_colocated_host(self):
        from unittest.mock import Mock
        api = Mock()
        api.list_nodes.return_value = [{"id": "core-host", "core_colocated": True}]
        with patch.object(roll, "discover_local_core_auth", return_value=("http://fake", "token")), \
             patch.object(roll, "HttpCoreApi", return_value=api), \
             patch.object(roll, "SshNodeOps") as ssh:
            with self.assertRaisesRegex(RuntimeError, "core-host.*core_colocated"):
                roll.main(["--dry-run"])
            ssh.assert_not_called()

    def test_apply_requires_expected_digests_before_auth(self):
        with patch.object(roll, "discover_local_core_auth", side_effect=AssertionError("auth reached")):
            with self.assertRaises(SystemExit) as raised:
                roll.main(["--apply"])
            self.assertEqual(raised.exception.code, 2)

    def test_lock_contention_is_nonzero_and_names_holder(self):
        import contextlib
        import io
        with tempfile.TemporaryDirectory() as temp:
            lock = Path(temp) / "deploy.lock"
            with lock.open("w+") as holder:
                holder.write("orb-deploy pid=1234\n")
                holder.flush()
                roll.fcntl.flock(holder, roll.fcntl.LOCK_EX | roll.fcntl.LOCK_NB)
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    result = roll.main(["--recover-node", "fake", "--lock-file", str(lock)])
                self.assertNotEqual(result, 0)
                self.assertIn("pid=1234", stderr.getvalue())

    def test_staged_unhealthy_node_is_never_upgraded(self):
        from unittest.mock import Mock
        api = Mock()
        api.list_nodes.return_value = [{"id": "fake", "cordoned": True}]
        ops = FakeNodeOps({"fake": {"staged": True, "healthy": False}})
        events, done = roll.rolling_upgrade_step(api, ops, [("fake", None)], apply=True)
        self.assertFalse(done)
        self.assertEqual(ops.upgraded_remotes, [])
        self.assertTrue(any(e["action"] == "unhealthy_node" for e in events))

    def test_start_guard_is_privileged_and_clean_node_starts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script, conf = roll._install_start_guard(
                binary_path=root / "sandboxed-node",
                build_conf_path=root / "worker.service.d/30-build.conf",
            )
            command = conf.read_text().split("ExecStartPre=", 1)[1].strip()
            self.assertTrue(command.startswith("+"), command)
            result = subprocess.run(command[1:].split(), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_recovery_uncordons_only_healthy_owned_cordon(self):
        from unittest.mock import Mock
        for owner in (None, "other-operator", roll.DEFAULT_CORDON_OWNER):
            for healthy in (False, True, None):
                with self.subTest(owner=owner, healthy=healthy), tempfile.TemporaryDirectory() as temp:
                    ledger = Path(temp) / "cordons.json"
                    if owner is not None:
                        roll.record_cordon_owner("fake", cordoned_by=owner, reason="test", ledger_path=ledger)
                    api = Mock()
                    ops = Mock()
                    ops.recover_remote.return_value = {"healthy": healthy}
                    result = roll.recover_cordoned_node(api, ops, "fake", cordon_ledger_path=ledger)
                    expected = owner == roll.DEFAULT_CORDON_OWNER and healthy is True
                    self.assertEqual(result["uncordoned"], expected)
                    self.assertEqual(api.set_cordon.call_count, int(expected))

    def test_stage_remote_executes_generated_shell_command(self):
        run = subprocess.run
        def shell_ssh(cmd, **kwargs):
            self.assertEqual(cmd[0], "ssh")
            return run(["bash", "-c", 'sudo() { "$@"; }; ' + cmd[-1]], **kwargs)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "artifact"
            source.write_bytes(b"binary\x00payload\n")
            destination = root / "space ' dollar $ and `tick`" / "sandboxed-node"
            digest = roll.compute_file_sha256(source)
            with patch.object(roll.subprocess, "run", side_effect=shell_ssh):
                roll.SshNodeOps().stage_remote("fake-node", {
                    "sandboxed-node": (source, destination),
                }, {"sandboxed-node": digest})
            staged = Path(str(destination) + ".new")
            self.assertEqual(staged.read_bytes(), source.read_bytes())
            self.assertEqual(staged.stat().st_mode & 0o777, 0o755)

    def test_zombie_children_do_not_hold_the_drain(self):
        # A finished child the worker never reaped must not count as running work.
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        deadline = time.time() + 5
        while time.time() < deadline and not roll._is_zombie(str(child.pid)):
            time.sleep(0.05)
        self.assertTrue(roll._is_zombie(str(child.pid)))
        live = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(5)"])
        try:
            self.assertFalse(roll._is_zombie(str(live.pid)))
        finally:
            live.kill()
            live.wait()
        child.wait()
        self.assertTrue(roll._is_zombie("999999999"))

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
                + f"\nprint(json.dumps(probe_worker_state(None, binary_path={str(bin_path)!r}, service_ctl=ctl, runtime_busy_probe=lambda: 0, live_work_dir_probe=lambda: {str(root)!r}, include_metadata=True)))\n"
            )
            proc = subprocess.run([sys.executable, "-"], input=prelude_check, capture_output=True, text=True, check=True)
            parsed = json.loads(proc.stdout.strip())
            self.assertEqual(
                {k: parsed[k] for k in ("staged", "running", "healthy", "quarantined")},
                {"staged": False, "running": 0, "healthy": True, "quarantined": False},
            )
            self.assertEqual(parsed["binary_sha256"]["sandboxed-node"], roll.compute_file_sha256(bin_path))

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
            self.assertEqual(
                {k: probe_busy[k] for k in ("staged", "running", "healthy", "quarantined")},
                {"staged": True, "running": 1, "healthy": True, "quarantined": False},
            )

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

    def test_replay_checksum_mismatch_quarantines_before_swap_without_stopping_services(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db_path = root / "jobs.db"
            con = sqlite3.connect(db_path)
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            con.commit()
            con.close()

            bin_dir = root / "usr/local/bin"
            sbin_dir = root / "usr/local/sbin"
            bin_dir.mkdir(parents=True)
            sbin_dir.mkdir(parents=True)
            node_bin = bin_dir / "sandboxed-node"
            mcp_bin = bin_dir / "sandboxed-mcp"
            privd_bin = sbin_dir / "orb-privd"
            build_conf = root / "30-build.conf"

            node_bin.write_text("node-v1")
            mcp_bin.write_text("mcp-v1")
            privd_bin.write_text("privd-v1")
            build_conf.write_text("[Service]\nEnvironment=ORB_BUILD_SHA=1111111111111111111111111111111111111111\n")

            (bin_dir / "sandboxed-node.new").write_text("node-v2")
            (bin_dir / "sandboxed-mcp.new").write_text("mcp-v2-corrupted")
            (sbin_dir / "orb-privd.new").write_text("privd-v2")

            expected_shas = {
                "sandboxed-node": roll.compute_file_sha256(bin_dir / "sandboxed-node.new"),
                "sandboxed-mcp": "a" * 64,  # mismatch
                "orb-privd": roll.compute_file_sha256(sbin_dir / "orb-privd.new"),
            }
            actions = []

            class RecordingCtl:
                def is_active(self, _u):
                    return True

                def stop(self, u):
                    actions.append(f"stop:{u}")

                def start(self, u):
                    actions.append(f"start:{u}")

                def start_best_effort(self, u):
                    actions.append(f"start_best_effort:{u}")

                def restart_best_effort(self, u):
                    actions.append(f"restart:{u}")

                def daemon_reload(self):
                    actions.append("daemon_reload")

            with self.assertRaisesRegex(RuntimeError, "checksum mismatch for sandboxed-mcp"):
                roll.perform_fenced_upgrade(
                    db_path=str(db_path),
                    binary_path=str(node_bin),
                    verify_delay_secs=0.0,
                    service_ctl=RecordingCtl(),
                    runtime_busy_probe=lambda: 0,
                    live_work_dir_probe=lambda: str(root),
                    mcp_binary_path=str(mcp_bin),
                    privd_binary_path=str(privd_bin),
                    expected_build_sha="2" * 40,
                    expected_sha256=expected_shas,
                    build_conf_path=str(build_conf),
                )

            # Services were never stopped, live binaries & build_conf are untouched, staged files are quarantined
            self.assertEqual(actions, [])
            self.assertEqual(node_bin.read_text(), "node-v1")
            self.assertEqual(mcp_bin.read_text(), "mcp-v1")
            self.assertEqual(privd_bin.read_text(), "privd-v1")
            self.assertIn("1111111111111111111111111111111111111111", build_conf.read_text())
            self.assertTrue((bin_dir / "sandboxed-node.new.failed").exists())
            self.assertTrue((bin_dir / "sandboxed-mcp.new.failed").exists())
            self.assertTrue((sbin_dir / "orb-privd.new.failed").exists())

    def test_replay_failed_health_check_rolls_back_all_three_binaries_and_build_conf(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db_path = root / "jobs.db"
            con = sqlite3.connect(db_path)
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            con.commit()
            con.close()

            bin_dir = root / "usr/local/bin"
            sbin_dir = root / "usr/local/sbin"
            bin_dir.mkdir(parents=True)
            sbin_dir.mkdir(parents=True)
            node_bin = bin_dir / "sandboxed-node"
            mcp_bin = bin_dir / "sandboxed-mcp"
            privd_bin = sbin_dir / "orb-privd"
            build_conf = root / "30-build.conf"

            old_sha = "1" * 40
            new_sha = "2" * 40
            node_bin.write_text("node-v1")
            mcp_bin.write_text("mcp-v1")
            privd_bin.write_text("privd-v1")
            build_conf.write_text(f"[Service]\nEnvironment=ORB_BUILD_SHA={old_sha}\n")

            (bin_dir / "sandboxed-node.new").write_text("node-v2")
            (bin_dir / "sandboxed-mcp.new").write_text("mcp-v2")
            (sbin_dir / "orb-privd.new").write_text("privd-v2")

            expected_shas = {
                "sandboxed-node": roll.compute_file_sha256(bin_dir / "sandboxed-node.new"),
                "sandboxed-mcp": roll.compute_file_sha256(bin_dir / "sandboxed-mcp.new"),
                "orb-privd": roll.compute_file_sha256(sbin_dir / "orb-privd.new"),
            }
            actions = []

            class HealthyUnitCtl:
                def is_active(self, _u):
                    return True

                def stop(self, u):
                    actions.append(f"stop:{u}")

                def start(self, u):
                    actions.append(f"start:{u}:{node_bin.read_text()}:{mcp_bin.read_text()}:{privd_bin.read_text()}")

                def start_best_effort(self, u):
                    actions.append(f"start_best_effort:{u}")

                def restart_best_effort(self, u):
                    actions.append(f"restart_rollback:{u}:{node_bin.read_text()}:{mcp_bin.read_text()}:{privd_bin.read_text()}")

                def daemon_reload(self):
                    actions.append("daemon_reload")

            with self.assertRaisesRegex(RuntimeError, "health check reported build_sha"):
                roll.perform_fenced_upgrade(
                    db_path=str(db_path),
                    binary_path=str(node_bin),
                    verify_delay_secs=0.0,
                    service_ctl=HealthyUnitCtl(),
                    runtime_busy_probe=lambda: 0,
                    live_work_dir_probe=lambda: str(root),
                    mcp_binary_path=str(mcp_bin),
                    privd_binary_path=str(privd_bin),
                    expected_build_sha=new_sha,
                    expected_sha256=expected_shas,
                    build_conf_path=str(build_conf),
                    health_check_probe=lambda exp_sha, _exp_shas: (
                        False,
                        f"health check reported build_sha={old_sha!r} != expected {exp_sha!r}",
                    ),
                )

            # All 3 binaries and 30-build.conf are rolled back to v1, and both sandboxed-node + orb-privd restarted on v1
            self.assertEqual(node_bin.read_text(), "node-v1")
            self.assertEqual(mcp_bin.read_text(), "mcp-v1")
            self.assertEqual(privd_bin.read_text(), "privd-v1")
            self.assertEqual(roll._read_build_conf_sha(build_conf), old_sha)
            self.assertTrue((bin_dir / "sandboxed-node.new.failed").exists())
            self.assertTrue((bin_dir / "sandboxed-mcp.new.failed").exists())
            self.assertTrue((sbin_dir / "orb-privd.new.failed").exists())
            self.assertIn("stop:orb-privd", actions)
            self.assertIn("restart_rollback:orb-privd:node-v1:mcp-v1:privd-v1", actions)
            self.assertIn("restart_rollback:sandboxed-node:node-v1:mcp-v1:privd-v1", actions)

    def test_replay_drain_timeout_leaves_node_cordoned_and_halts_rollout(self):
        cordoned = {"ashur": False, "nippur": False}
        server = _start_core_api_server(cordoned)
        try:
            api = roll.HttpCoreApi(f"http://127.0.0.1:{server.server_port}", roll.mint_hs256_jwt("test-secret"))
            ops = FakeNodeOps(
                {
                    "ashur": {"staged": True, "running": 2},
                    "nippur": {"staged": True, "running": 0},
                }
            )
            fake_now = [100.0]

            def fake_sleep(dt_secs):
                fake_now[0] += dt_secs

            events, done = roll.run_governed_rollout(
                core_api=api,
                node_ops=ops,
                remote_nodes=[("ashur", None), ("nippur", None)],
                max_concurrent_cordons=1,
                apply=True,
                drain_timeout_secs=10.0,
                poll_interval_secs=4.0,
                sleep_fn=fake_sleep,
                clock_fn=lambda: fake_now[0],
            )
            self.assertFalse(done)
            self.assertTrue(cordoned["ashur"])
            self.assertFalse(cordoned["nippur"])
            self.assertEqual(ops.upgraded_remotes, [])
            self.assertTrue(any(ev["action"] == "drain_timeout" and ev["nodes"] == ["ashur"] for ev in events))
        finally:
            server.shutdown()
            server.server_close()

    def test_replay_node_already_on_target_and_interrupted_rollout_resumed(self):
        target_sha = "3" * 40
        target_shas = {
            "sandboxed-node": "a" * 64,
            "sandboxed-mcp": "b" * 64,
            "orb-privd": "c" * 64,
        }
        old_shas = {
            "sandboxed-node": "1" * 64,
            "sandboxed-mcp": "2" * 64,
            "orb-privd": "3" * 64,
        }
        # Simulate an interrupted rollout where ashur was already upgraded, nippur was left cordoned mid-drain,
        # and babylon has not been touched yet.
        cordoned = {"ashur": False, "nippur": True, "babylon": False}
        server = _start_core_api_server(cordoned)
        try:
            api = roll.HttpCoreApi(f"http://127.0.0.1:{server.server_port}", roll.mint_hs256_jwt("test-secret"))
            staged_calls = []

            class ResumableOps(FakeNodeOps):
                def probe_remote(self, host, _db_path):
                    st = self.remote_state[host]
                    return {
                        "staged": bool(st.get("staged", False)),
                        "running": int(st.get("running", 0)),
                        "healthy": bool(st.get("healthy", True)),
                        "quarantined": bool(st.get("quarantined", False)),
                        "build_sha": st.get("build_sha", ""),
                        "binary_sha256": dict(st.get("binary_sha256", {})),
                    }

                def stage_remote(self, host, artifacts, build_sha=None):
                    staged_calls.append(host)
                    self.remote_state[host]["staged"] = True

                def upgrade_remote(self, host, _db_path):
                    res = super().upgrade_remote(host, _db_path)
                    if res == "UPGRADED":
                        self.remote_state[host]["build_sha"] = target_sha
                        self.remote_state[host]["binary_sha256"] = dict(target_shas)
                    return res

            ops = ResumableOps(
                {
                    "ashur": {
                        "staged": False,
                        "running": 0,
                        "healthy": True,
                        "build_sha": target_sha,
                        "binary_sha256": dict(target_shas),
                    },
                    "nippur": {
                        "staged": True,
                        "running": 1,
                        "healthy": True,
                        "build_sha": "1" * 40,
                        "binary_sha256": dict(old_shas),
                    },
                    "babylon": {
                        "staged": False,
                        "running": 0,
                        "healthy": True,
                        "build_sha": "1" * 40,
                        "binary_sha256": dict(old_shas),
                    },
                }
            )
            stage_spec = {
                "sandboxed-node": ("/tmp/node", "/usr/local/bin/sandboxed-node"),
                "sandboxed-mcp": ("/tmp/mcp", "/usr/local/bin/sandboxed-mcp"),
                "orb-privd": ("/tmp/privd", "/usr/local/sbin/orb-privd"),
            }

            # Status view before resume shows ashur on_target=True and nippur/babylon on_target=False
            status_before = roll.collect_fleet_rollout_status(
                core_api=api,
                node_ops=ops,
                remote_nodes=[("ashur", None), ("nippur", None), ("babylon", None)],
                expected_build_sha=target_sha,
                expected_sha256=target_shas,
            )
            by_node = {r["node"]: r for r in status_before}
            self.assertTrue(by_node["ashur"]["on_target"])
            self.assertFalse(by_node["nippur"]["on_target"])
            self.assertFalse(by_node["babylon"]["on_target"])

            # Dry-run reports ashur as already_on_target, nippur as draining, babylon as pending_wave without mutating
            dry_events, dry_done = roll.rolling_upgrade_step(
                core_api=api,
                node_ops=ops,
                remote_nodes=[("ashur", None), ("nippur", None), ("babylon", None)],
                max_concurrent_cordons=1,
                apply=False,
                stage_artifacts=stage_spec,
                expected_build_sha=target_sha,
                expected_sha256=target_shas,
            )
            self.assertFalse(dry_done)
            self.assertEqual(staged_calls, [])
            self.assertTrue(any(e["node"] == "ashur" and e["action"] == "already_on_target" for e in dry_events))
            self.assertTrue(any(e["node"] == "nippur" and e["action"] == "draining" for e in dry_events))
            self.assertTrue(any(e["node"] == "babylon" and e["action"] == "pending_wave" for e in dry_events))

            # Resume rollout: nippur drains on poll tick 2, upgrades & uncordons, then babylon stages, upgrades & uncordons
            tick_count = [0]

            def on_sleep(_dt):
                tick_count[0] += 1
                if tick_count[0] >= 1:
                    ops.remote_state["nippur"]["running"] = 0

            events, done = roll.run_governed_rollout(
                core_api=api,
                node_ops=ops,
                remote_nodes=[("ashur", None), ("nippur", None), ("babylon", None)],
                max_concurrent_cordons=1,
                apply=True,
                stage_artifacts=stage_spec,
                expected_build_sha=target_sha,
                expected_sha256=target_shas,
                drain_timeout_secs=30.0,
                poll_interval_secs=1.0,
                sleep_fn=on_sleep,
            )
            self.assertTrue(done)
            # ashur was already on target -> never re-staged or re-upgraded
            self.assertNotIn("ashur", staged_calls)
            self.assertEqual(ops.upgraded_remotes, ["nippur", "babylon"])
            self.assertTrue(all(not v for v in cordoned.values()))
        finally:
            server.shutdown()
            server.server_close()

    def test_health_check_fails_closed_when_binary_sha256_or_token_missing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db_path = root / "jobs.db"
            con = sqlite3.connect(db_path)
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            con.commit()
            con.close()

            bin_dir = root / "usr/local/bin"
            sbin_dir = root / "usr/local/sbin"
            bin_dir.mkdir(parents=True)
            sbin_dir.mkdir(parents=True)
            node_bin = bin_dir / "sandboxed-node"
            mcp_bin = bin_dir / "sandboxed-mcp"
            privd_bin = sbin_dir / "orb-privd"
            build_conf = root / "30-build.conf"

            new_sha = "2" * 40
            node_bin.write_text("node-v1")
            mcp_bin.write_text("mcp-v1")
            privd_bin.write_text("privd-v1")
            (bin_dir / "sandboxed-node.new").write_text("node-v2")
            (bin_dir / "sandboxed-mcp.new").write_text("mcp-v2")
            (sbin_dir / "orb-privd.new").write_text("privd-v2")
            expected_shas = {
                "sandboxed-node": roll.compute_file_sha256(bin_dir / "sandboxed-node.new"),
                "sandboxed-mcp": roll.compute_file_sha256(bin_dir / "sandboxed-mcp.new"),
                "orb-privd": roll.compute_file_sha256(sbin_dir / "orb-privd.new"),
            }

            # 1. _default_health_check_probe must fail closed when SANDBOXED_NODE_TOKEN is missing
            empty_env = root / "empty.env"
            empty_env.write_text("SANDBOXED_NODE_BIND=127.0.0.1:3088\n")
            with self.assertRaisesRegex(RuntimeError, "SANDBOXED_NODE_TOKEN"):
                roll._default_health_check_probe(
                    unit_name="nonexistent-sandboxed-node-unit",
                    env_file=str(empty_env),
                    expected_build_sha=new_sha,
                    expected_sha256=expected_shas,
                    build_conf_path=str(build_conf),
                )

            # 2. perform_fenced_upgrade must fail closed when health check returns missing binary_sha256 or missing component digest
            class NoopCtl:
                def is_active(self, _u):
                    return True

                def stop(self, _u):
                    pass

                def start(self, _u):
                    pass

                def start_best_effort(self, _u):
                    pass

                def restart_best_effort(self, _u):
                    pass

                def daemon_reload(self):
                    pass

            for bad_hc in [
                {"ok": True, "build_sha": new_sha},
                {"ok": True, "build_sha": new_sha, "binary_sha256": None},
                {
                    "ok": True,
                    "build_sha": new_sha,
                    "binary_sha256": {
                        "sandboxed-node": expected_shas["sandboxed-node"],
                        "sandboxed-mcp": expected_shas["sandboxed-mcp"],
                        # orb-privd missing!
                    },
                },
            ]:
                (bin_dir / "sandboxed-node.new").write_text("node-v2")
                (bin_dir / "sandboxed-mcp.new").write_text("mcp-v2")
                (sbin_dir / "orb-privd.new").write_text("privd-v2")
                with self.assertRaisesRegex(RuntimeError, "sha256|binary_sha256"):
                    roll.perform_fenced_upgrade(
                        db_path=str(db_path),
                        binary_path=str(node_bin),
                        verify_delay_secs=0.0,
                        service_ctl=NoopCtl(),
                        runtime_busy_probe=lambda: 0,
                        live_work_dir_probe=lambda: str(root),
                        mcp_binary_path=str(mcp_bin),
                        privd_binary_path=str(privd_bin),
                        expected_build_sha=new_sha,
                        expected_sha256=expected_shas,
                        build_conf_path=str(build_conf),
                        health_check_probe=lambda _sha, _shas, res=bad_hc: res,
                    )
                self.assertEqual(node_bin.read_text(), "node-v1")

    def test_durable_swap_journal_recovers_interrupted_mixed_build_before_start(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db_path = root / "jobs.db"
            con = sqlite3.connect(db_path)
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            con.commit()
            con.close()

            bin_dir = root / "usr/local/bin"
            sbin_dir = root / "usr/local/sbin"
            bin_dir.mkdir(parents=True)
            sbin_dir.mkdir(parents=True)
            node_bin = bin_dir / "sandboxed-node"
            mcp_bin = bin_dir / "sandboxed-mcp"
            privd_bin = sbin_dir / "orb-privd"
            build_conf = root / "30-build.conf"

            old_sha = "1" * 40
            new_sha = "2" * 40
            node_bin.write_text("node-v1")
            mcp_bin.write_text("mcp-v1")
            privd_bin.write_text("privd-v1")
            build_conf.write_text(f"[Service]\nEnvironment=ORB_BUILD_SHA={old_sha}\n")

            (bin_dir / "sandboxed-node.new").write_text("node-v2")
            (bin_dir / "sandboxed-mcp.new").write_text("mcp-v2")
            (sbin_dir / "orb-privd.new").write_text("privd-v2")

            # Simulate a process death (SIGKILL/power loss) right after sandboxed-node was renamed
            # to v2, before sandboxed-mcp or orb-privd were swapped.
            journal_path = roll._default_swap_journal_path(node_bin)
            roll._write_swap_journal(
                journal_path,
                active_components=[
                    {
                        "name": "sandboxed-node",
                        "bin": node_bin,
                        "backup": Path(str(node_bin) + ".prev"),
                        "installing": Path(str(node_bin) + ".installing"),
                        "restoring": Path(str(node_bin) + ".restoring"),
                        "had_existing": True,
                        "prev_sha256": roll.compute_file_sha256(node_bin),
                    },
                    {
                        "name": "sandboxed-mcp",
                        "bin": mcp_bin,
                        "backup": Path(str(mcp_bin) + ".prev"),
                        "installing": Path(str(mcp_bin) + ".installing"),
                        "restoring": Path(str(mcp_bin) + ".restoring"),
                        "had_existing": True,
                        "prev_sha256": roll.compute_file_sha256(mcp_bin),
                    },
                    {
                        "name": "orb-privd",
                        "bin": privd_bin,
                        "backup": Path(str(privd_bin) + ".prev"),
                        "installing": Path(str(privd_bin) + ".installing"),
                        "restoring": Path(str(privd_bin) + ".restoring"),
                        "had_existing": True,
                        "prev_sha256": roll.compute_file_sha256(privd_bin),
                    },
                ],
                build_conf_path=build_conf,
                prev_build_sha=old_sha,
            )
            # Backups were prepared before any rename, then only sandboxed-node was replaced before crash:
            Path(str(node_bin) + ".prev").write_text("node-v1")
            Path(str(mcp_bin) + ".prev").write_text("mcp-v1")
            Path(str(privd_bin) + ".prev").write_text("privd-v1")
            node_bin.write_text("node-v2")
            build_conf.write_text(f"[Service]\nEnvironment=ORB_BUILD_SHA={new_sha}\n")

            class RecordingCtl:
                def __init__(self):
                    self.events = []

                def is_active(self, _u):
                    return True

                def stop(self, u):
                    self.events.append(f"stop:{u}:{node_bin.read_text()}:{mcp_bin.read_text()}:{privd_bin.read_text()}")

                def start(self, u):
                    self.events.append(f"start:{u}:{node_bin.read_text()}:{mcp_bin.read_text()}:{privd_bin.read_text()}")

                def start_best_effort(self, u):
                    self.events.append(f"start_best_effort:{u}")

                def restart_best_effort(self, u):
                    self.events.append(f"restart_best_effort:{u}")

                def daemon_reload(self):
                    self.events.append("daemon_reload")

            # probe_worker_state flags the node unhealthy while a mid-swap journal is present
            probe_mid = roll.probe_worker_state(
                db_path=str(db_path),
                binary_path=str(node_bin),
                service_ctl=RecordingCtl(),
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(root),
                mcp_binary_path=str(mcp_bin),
                privd_binary_path=str(privd_bin),
                build_conf_path=str(build_conf),
            )
            self.assertFalse(probe_mid["healthy"])
            self.assertTrue(probe_mid.get("swap_journal_pending"))

            # Simulate a reboot before the next tool run: systemd invokes the installed ExecStartPre
            # start guard (`25-swap-guard.conf` -> `sandboxed-node-swap-guard.py`) before starting
            # `sandboxed-node`. The start guard recovers all components to v1 and clears the journal;
            # if recovery cannot complete (e.g. missing backup), the start guard exits non-zero and
            # refuses to start while the journal is open.
            guard_script, guard_conf = roll._install_start_guard(
                binary_path=str(node_bin),
                journal_path=journal_path,
                build_conf_path=str(build_conf),
            )
            self.assertTrue(guard_script.is_file())
            self.assertTrue(guard_conf.is_file())
            self.assertIn(f"ExecStartPre=+/usr/bin/python3 {guard_script}", guard_conf.read_text())

            # Case 1: corrupt/missing backup during boot -> start guard refuses to start
            Path(str(node_bin) + ".prev").unlink()
            with self.assertRaisesRegex(RuntimeError, "refused start"):
                roll.run_start_guard(binary_path=str(node_bin), journal_path=journal_path)
            self.assertTrue(journal_path.is_file())

            # Case 2: intact backup on reboot -> start guard restores v1 and removes journal before service starts
            Path(str(node_bin) + ".prev").write_text("node-v1")
            roll.run_start_guard(binary_path=str(node_bin), journal_path=journal_path)
            self.assertFalse(journal_path.exists())
            self.assertEqual(node_bin.read_text(), "node-v1")
            self.assertEqual(mcp_bin.read_text(), "mcp-v1")
            self.assertEqual(privd_bin.read_text(), "privd-v1")
            self.assertEqual(roll._read_build_conf_sha(build_conf), old_sha)

            # Re-seed mid-swap state to also verify perform_fenced_upgrade direct recovery path:
            roll._write_swap_journal(
                journal_path,
                active_components=[
                    {
                        "name": "sandboxed-node",
                        "bin": node_bin,
                        "backup": Path(str(node_bin) + ".prev"),
                        "installing": Path(str(node_bin) + ".installing"),
                        "restoring": Path(str(node_bin) + ".restoring"),
                        "had_existing": True,
                        "prev_sha256": roll.compute_file_sha256(node_bin),
                    },
                    {
                        "name": "sandboxed-mcp",
                        "bin": mcp_bin,
                        "backup": Path(str(mcp_bin) + ".prev"),
                        "installing": Path(str(mcp_bin) + ".installing"),
                        "restoring": Path(str(mcp_bin) + ".restoring"),
                        "had_existing": True,
                        "prev_sha256": roll.compute_file_sha256(mcp_bin),
                    },
                    {
                        "name": "orb-privd",
                        "bin": privd_bin,
                        "backup": Path(str(privd_bin) + ".prev"),
                        "installing": Path(str(privd_bin) + ".installing"),
                        "restoring": Path(str(privd_bin) + ".restoring"),
                        "had_existing": True,
                        "prev_sha256": roll.compute_file_sha256(privd_bin),
                    },
                ],
                build_conf_path=build_conf,
                prev_build_sha=old_sha,
            )
            node_bin.write_text("node-v2")
            build_conf.write_text(f"[Service]\nEnvironment=ORB_BUILD_SHA={new_sha}\n")

            # Running perform_fenced_upgrade recovers the journal first (restoring node-v1 and old_sha
            # before stopping/swapping), then completes the clean v2 upgrade and removes the journal.
            ctl = RecordingCtl()
            res = roll.perform_fenced_upgrade(
                db_path=str(db_path),
                binary_path=str(node_bin),
                verify_delay_secs=0.0,
                service_ctl=ctl,
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(root),
                mcp_binary_path=str(mcp_bin),
                privd_binary_path=str(privd_bin),
                expected_build_sha=new_sha,
                expected_sha256={
                    "sandboxed-node": roll.compute_file_sha256(bin_dir / "sandboxed-node.new"),
                    "sandboxed-mcp": roll.compute_file_sha256(bin_dir / "sandboxed-mcp.new"),
                    "orb-privd": roll.compute_file_sha256(sbin_dir / "orb-privd.new"),
                },
                build_conf_path=str(build_conf),
                health_check_probe=lambda sha, shas: {"ok": True, "build_sha": sha, "binary_sha256": shas},
            )
            self.assertEqual(res, "UPGRADED")
            self.assertFalse(journal_path.exists())
            # At stop time (before new swap), recovery had restored node-v1 so no mixed build remained
            self.assertIn("stop:sandboxed-node:node-v1:mcp-v1:privd-v1", ctl.events)
            self.assertIn("start:sandboxed-node:node-v2:mcp-v2:privd-v2", ctl.events)

    def test_restore_components_isolates_per_component_errors_verifies_rollback_and_halts_rollout(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db_path = root / "jobs.db"
            con = sqlite3.connect(db_path)
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            con.commit()
            con.close()

            bin_dir = root / "usr/local/bin"
            sbin_dir = root / "usr/local/sbin"
            bin_dir.mkdir(parents=True)
            sbin_dir.mkdir(parents=True)
            node_bin = bin_dir / "sandboxed-node"
            mcp_bin = bin_dir / "sandboxed-mcp"
            privd_bin = sbin_dir / "orb-privd"
            build_conf = root / "30-build.conf"

            old_sha = "1" * 40
            new_sha = "2" * 40
            node_bin.write_text("node-v1")
            mcp_bin.write_text("mcp-v1")
            privd_bin.write_text("privd-v1")
            build_conf.write_text(f"[Service]\nEnvironment=ORB_BUILD_SHA={old_sha}\n")

            (bin_dir / "sandboxed-node.new").write_text("node-v2")
            (bin_dir / "sandboxed-mcp.new").write_text("mcp-v2")
            (sbin_dir / "orb-privd.new").write_text("privd-v2")

            class CorruptedBackupOnStartCtl:
                def is_active(self, _u):
                    return True

                def stop(self, _u):
                    pass

                def start(self, u):
                    # Corrupt orb-privd.prev right before activation fails so orb-privd rollback fails verification
                    if u == "orb-privd":
                        Path(str(privd_bin) + ".prev").unlink(missing_ok=True)

                def start_best_effort(self, _u):
                    pass

                def restart_best_effort(self, _u):
                    pass

                def daemon_reload(self):
                    pass

            outcome = roll.perform_fenced_upgrade(
                db_path=str(db_path),
                binary_path=str(node_bin),
                verify_delay_secs=0.0,
                service_ctl=CorruptedBackupOnStartCtl(),
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(root),
                mcp_binary_path=str(mcp_bin),
                privd_binary_path=str(privd_bin),
                expected_build_sha=new_sha,
                expected_sha256={
                    "sandboxed-node": roll.compute_file_sha256(bin_dir / "sandboxed-node.new"),
                    "sandboxed-mcp": roll.compute_file_sha256(bin_dir / "sandboxed-mcp.new"),
                    "orb-privd": roll.compute_file_sha256(sbin_dir / "orb-privd.new"),
                },
                build_conf_path=str(build_conf),
                health_check_probe=lambda _sha, _shas: (False, "post-start health check failed"),
            )
            # Even though orb-privd.prev was missing/corrupted, _restore_components did not escape early:
            # sandboxed-mcp, sandboxed-node, and 30-build.conf were still restored and verified, and a
            # distinct ROLLBACK_FAILED:... result was returned.
            self.assertTrue(str(outcome).startswith("ROLLBACK_FAILED:"), outcome)
            self.assertEqual(node_bin.read_text(), "node-v1")
            self.assertEqual(mcp_bin.read_text(), "mcp-v1")
            self.assertEqual(roll._read_build_conf_sha(build_conf), old_sha)

            # And rolling_upgrade_step / run_governed_rollout emit rollback_failed and halt the rollout immediately
            cordoned = {"ashur": True, "nippur": False}
            server = _start_core_api_server(cordoned)
            try:
                api = roll.HttpCoreApi(f"http://127.0.0.1:{server.server_port}", roll.mint_hs256_jwt("test-secret"))

                class RollbackFailedOps(FakeNodeOps):
                    def upgrade_remote(self, host, _db_path):
                        if host == "ashur":
                            return outcome
                        return super().upgrade_remote(host, _db_path)

                ops = RollbackFailedOps(
                    {
                        "ashur": {"staged": True, "running": 0, "healthy": True},
                        "nippur": {"staged": True, "running": 0, "healthy": True},
                    }
                )
                events, done = roll.run_governed_rollout(
                    core_api=api,
                    node_ops=ops,
                    remote_nodes=[("ashur", None), ("nippur", None)],
                    max_concurrent_cordons=1,
                    apply=True,
                    drain_timeout_secs=10.0,
                )
                self.assertFalse(done)
                self.assertTrue(cordoned["ashur"])
                self.assertFalse(cordoned["nippur"])
                self.assertTrue(any(e["action"] == "rollback_failed" and e["node"] == "ashur" for e in events))
            finally:
                server.shutdown()
                server.server_close()

    def test_remote_nodes_redacts_build_and_binary_sha256_for_member_but_includes_for_admin(self):
        repo_root = Path(__file__).resolve().parent.parent
        relay_src = (repo_root / "lean/OrbCore/OrbCore/RemoteFleetAndRelay.lean").read_text(encoding="utf-8")
        control_src = (repo_root / "lean/OrbCore/OrbCore/Control.lean").read_text(encoding="utf-8")

        self.assertIn("let isRnAdmin := caller.isLegacyUnscoped || caller.role == \"admin\"", control_src)
        self.assertIn("buildComputeFleetJVal st.relayHub? none mf callerUidOpt (infS + cmpS) caller.dailySpendCapCents? st.store.rootDir nowIsoRn (some st.store) 2500 isRnAdmin", control_src)
        self.assertIn("buildComputeFleetJVal st.relayHub? (some mst) live callerUidOpt (infS + cmpS) caller.dailySpendCapCents? st.store.rootDir nowIsoRn (some st.store) 2500 isRnAdmin", control_src)
        self.assertIn("if isAdmin then\n        fields := fields ++ #[\n          (\"build\",", relay_src)
        self.assertIn("k != \"build\" && k != \"build_sha\" && k != \"binary_sha256\"", relay_src)

        raw_hb = {
            "version": "4.35.0",
            "build": "a" * 40,
            "build_sha": "a" * 40,
            "binary_sha256": {
                "sandboxed-node": "1" * 64,
                "sandboxed-mcp": "2" * 64,
                "orb-privd": "3" * 64,
            },
            "capacity_total": 4,
            "active_jobs": 0,
        }

        def render_remote_node_entry(is_admin: bool):
            sanitized_hb = (
                dict(raw_hb)
                if is_admin
                else {k: v for k, v in raw_hb.items() if k not in ("build", "build_sha", "binary_sha256")}
            )
            node = {
                "id": "ashur",
                "name": "ashur",
                "kind": "static",
                "status": "online",
                "cordoned": False,
                "version": raw_hb["version"],
                "heartbeat": sanitized_hb,
            }
            if is_admin:
                node["build"] = raw_hb["build"]
                node["build_sha"] = raw_hb["build_sha"]
                node["binary_sha256"] = raw_hb["binary_sha256"]
            return node

        member_node = render_remote_node_entry(is_admin=False)
        admin_node = render_remote_node_entry(is_admin=True)

        for secret_field in ("build", "build_sha", "binary_sha256"):
            self.assertNotIn(secret_field, member_node)
            self.assertNotIn(secret_field, member_node["heartbeat"])
            self.assertIn(secret_field, admin_node)
            self.assertIn(secret_field, admin_node["heartbeat"])

    def test_cordon_owner_recorded_and_recover_node_uncordons_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            ledger_path = root / "cordons.json"
            lock_path = root / "rollout.lock"
            cordoned = {"ashur": False, "nippur": False}
            server = _start_core_api_server(cordoned)
            try:
                api_url = f"http://127.0.0.1:{server.server_port}"
                token = roll.mint_hs256_jwt("test-secret")
                api = roll.HttpCoreApi(api_url, token)

                class FailingUpgradeOps(FakeNodeOps):
                    def upgrade_remote(self, host, _db_path):
                        raise RuntimeError(f"simulated SIGTERM/failure on {host}")

                    def recover_remote(self, host):
                        return {
                            "journal_recovered": True,
                            "cleared_artifacts": ["/usr/local/bin/sandboxed-node.new.failed"],
                            "healthy": True,
                        }

                ops = FailingUpgradeOps(
                    {
                        "ashur": {"staged": True, "running": 0, "healthy": True},
                        "nippur": {"staged": True, "running": 0, "healthy": True},
                    }
                )
                events, done = roll.run_governed_rollout(
                    core_api=api,
                    node_ops=ops,
                    remote_nodes=[("ashur", None), ("nippur", None)],
                    max_concurrent_cordons=1,
                    apply=True,
                    expected_build_sha="a" * 40,
                    cordon_owner="rolling_upgrade_nodes",
                    cordon_ledger_path=str(ledger_path),
                )
                self.assertFalse(done)
                self.assertTrue(cordoned["ashur"])
                self.assertFalse(cordoned["nippur"])

                # Verify cordon owner is recorded in the ledger and surfaced in --status
                ledger = roll.load_cordon_ledger(str(ledger_path))
                self.assertIn("ashur", ledger)
                self.assertEqual(ledger["ashur"]["cordoned_by"], "rolling_upgrade_nodes")
                self.assertEqual(ledger["ashur"]["target_build_sha"], "a" * 40)

                status_rows = roll.collect_fleet_rollout_status(
                    core_api=api,
                    node_ops=ops,
                    remote_nodes=[("ashur", None), ("nippur", None)],
                    expected_build_sha="a" * 40,
                    cordon_ledger_path=str(ledger_path),
                )
                ashur_row = next(r for r in status_rows if r["node"] == "ashur")
                self.assertTrue(ashur_row["cordoned"])
                self.assertEqual(ashur_row["cordoned_by"], "rolling_upgrade_nodes")

                # Recover the node left cordoned via recover_cordoned_node / CLI --recover-node
                import os
                from unittest import mock
                with mock.patch.dict(os.environ, {"SANDBOXED_API_TOKEN": token}):
                    with mock.patch.object(roll, "SshNodeOps", return_value=ops):
                        rc = roll.main(
                            [
                                "--api-url",
                                api_url,
                                "--cordon-ledger",
                                str(ledger_path),
                                "--lock-file",
                                str(lock_path),
                                "--recover-node",
                                "ashur",
                            ]
                        )
                self.assertEqual(rc, 0)
                self.assertFalse(cordoned["ashur"])
                self.assertNotIn("ashur", roll.load_cordon_ledger(str(ledger_path)))
            finally:
                server.shutdown()
                server.server_close()

    def test_ping_alive_ssh_api_timeout_skips_with_bounded_timeout_and_old_node_reports_unknown_build_sha(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db_path = root / "jobs.db"
            con = sqlite3.connect(db_path)
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
            con.commit()
            con.close()

            bin_dir = root / "usr/local/bin"
            sbin_dir = root / "usr/local/sbin"
            bin_dir.mkdir(parents=True)
            sbin_dir.mkdir(parents=True)
            node_bin = bin_dir / "sandboxed-node"
            mcp_bin = bin_dir / "sandboxed-mcp"
            privd_bin = sbin_dir / "orb-privd"
            node_bin.write_text("node-old")
            mcp_bin.write_text("mcp-old")
            privd_bin.write_text("privd-old")
            old_shas = {
                "sandboxed-node": roll.compute_file_sha256(node_bin),
                "sandboxed-mcp": roll.compute_file_sha256(mcp_bin),
                "orb-privd": roll.compute_file_sha256(privd_bin),
            }

            class ActiveCtl:
                def is_active(self, _u):
                    return True

            # 1. Old node with no 30-build.conf / no reported build SHA must report "unknown", never "current" or on_target=True
            probe_old = roll.probe_worker_state(
                db_path=str(db_path),
                binary_path=str(node_bin),
                mcp_binary_path=str(mcp_bin),
                privd_binary_path=str(privd_bin),
                build_conf_path=str(root / "missing-30-build.conf"),
                service_ctl=ActiveCtl(),
                runtime_busy_probe=lambda: 0,
                live_work_dir_probe=lambda: str(root),
                sibling_units_probe=lambda: [],
                expected_sha256=old_shas,
                include_metadata=True,
            )
            self.assertEqual(probe_old["build_sha"], "unknown")
            self.assertNotEqual(probe_old["build_sha"], "current")
            self.assertFalse(probe_old["on_target"])

            # 2. SshNodeOps._ssh_python must enforce bounded SSH ConnectTimeout and ServerAliveInterval
            ssh_ops = roll.SshNodeOps(ssh_timeout_secs=4.0)
            from unittest import mock
            with mock.patch.object(
                roll.subprocess,
                "run",
                side_effect=roll.subprocess.TimeoutExpired(cmd=["ssh", "ashur"], timeout=4.0),
            ) as mock_run:
                with self.assertRaisesRegex(RuntimeError, "timed out after 4"):
                    ssh_ops.probe_remote("ashur", "/var/lib/sandboxed-node/work/jobs.db")
                called_cmd = " ".join(mock_run.call_args[0][0])
                self.assertIn("ConnectTimeout=4", called_cmd)
                self.assertIn("ServerAliveInterval=4", called_cmd)
                self.assertIn("ServerAliveCountMax=2", called_cmd)

            # 3. Node answering ping (online in Core) while SSH/API times out is skipped fail-closed and old node shows "unknown"
            cordoned = {"ashur": False, "nippur": False}
            server = _start_core_api_server(cordoned)
            try:
                api_url = f"http://127.0.0.1:{server.server_port}"
                token = roll.mint_hs256_jwt("test-secret")
                api = roll.HttpCoreApi(api_url, token)

                class PingAliveSshTimeoutAndOldNodeOps(FakeNodeOps):
                    def probe_remote(self, host, _db_path, include_metadata=False):
                        if host == "ashur":
                            raise RuntimeError("ssh ashur timed out after 4.0s (ping alive, SSH/API hung)")
                        # nippur is an old node with no build_sha or reporting legacy "current"
                        return {
                            "staged": False,
                            "running": 0,
                            "healthy": True,
                            "quarantined": False,
                            "build_sha": "current",
                            "binary_sha256": dict(old_shas),
                        }

                ops = PingAliveSshTimeoutAndOldNodeOps({})
                status_rows = roll.collect_fleet_rollout_status(
                    core_api=api,
                    node_ops=ops,
                    remote_nodes=[("ashur", None), ("nippur", None)],
                    expected_sha256=old_shas,
                )
                by_node = {r["node"]: r for r in status_rows}
                self.assertEqual(by_node["ashur"]["state"], "probe_error")
                self.assertFalse(by_node["ashur"]["on_target"])
                self.assertEqual(by_node["ashur"]["reported_build_sha"], "unknown")
                self.assertEqual(by_node["nippur"]["reported_build_sha"], "unknown")
                self.assertNotEqual(by_node["nippur"]["reported_build_sha"], "current")
                self.assertFalse(by_node["nippur"]["on_target"])

                events, done = roll.rolling_upgrade_step(
                    core_api=api,
                    node_ops=ops,
                    remote_nodes=[("ashur", None), ("nippur", None)],
                    max_concurrent_cordons=1,
                    apply=True,
                    expected_sha256=old_shas,
                )
                self.assertFalse(done)
                self.assertTrue(any(e["action"] == "probe_error" and e["node"] == "ashur" for e in events))
                self.assertFalse(cordoned["ashur"])
                self.assertFalse(cordoned["nippur"])
            finally:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
