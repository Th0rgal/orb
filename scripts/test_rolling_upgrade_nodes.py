#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import unittest

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import rolling_upgrade_nodes as roll  # noqa: E402


class FakeNodeOps:
    def __init__(self, remote_state, local_state=(False, 0)):
        # host -> {"staged": bool, "running": int, "fail_probe": bool, "busy_on_upgrade": bool}
        self.remote_state = remote_state
        self.local_staged, self.local_running = local_state
        self.upgraded_remotes = []
        self.upgraded_local = False
        self.stopped_timers = []

    def probe_remote(self, host, _db_path):
        st = self.remote_state[host]
        if st.get("fail_probe"):
            raise RuntimeError(f"simulated ssh error on {host}")
        return bool(st["staged"]), int(st["running"])

    def upgrade_remote(self, host, _db_path):
        st = self.remote_state[host]
        if st.get("busy_on_upgrade") or st["running"] != 0:
            return "BUSY:1"
        st["staged"] = False
        self.upgraded_remotes.append(host)
        return "UPGRADED"

    def probe_local(self, _db_path):
        return bool(self.local_staged), int(self.local_running)

    def upgrade_local(self, _db_path):
        if self.local_running != 0:
            return f"BUSY:{self.local_running}"
        self.local_staged = False
        self.upgraded_local = True
        return "UPGRADED"

    def stop_timer(self, unit_name):
        self.stopped_timers.append(unit_name)


class RollingUpgradeNodesTest(unittest.TestCase):
    def test_wave_cordon_cap_probe_error_fail_closed_and_completion(self):
        cordoned = {"ashur": True, "nippur": True, "babylon": True, "old-agent": True}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                if self.path == "/api/remote-nodes":
                    body = json.dumps({"nodes": [{"id": k, "cordoned": v} for k, v in cordoned.items()]}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(404)
                    self.end_headers()

            def do_POST(self):
                parts = self.path.strip("/").split("/")
                if len(parts) == 4 and parts[0] == "api" and parts[1] == "nodes" and parts[3] in ("cordon", "uncordon"):
                    node = parts[2]
                    cordoned[node] = parts[3] == "cordon"
                    body = json.dumps({"node": node, "cordoned": cordoned[node], "changed": True}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(404)
                    self.end_headers()

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
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
                local_state=(True, 2),
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
            # nippur drained to 0 -> upgraded and uncordoned; babylon/old-agent stay uncordoned due to probe error
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
            # 1 cordon slot opened after nippur finished -> babylon cordoned next
            self.assertTrue(cordoned["babylon"])

            # Tick 4 & 5: all remaining jobs drain -> upgrades complete, uncordoned, timer stopped
            ops.remote_state["ashur"]["busy_on_upgrade"] = False
            for host in ("ashur", "babylon", "old-agent"):
                ops.remote_state[host]["running"] = 0
            ops.local_running = 0

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


if __name__ == "__main__":
    unittest.main()
