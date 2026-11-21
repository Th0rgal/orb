"""Test owner enrollment over loopback against an isolated authenticated Core."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
from uuid import uuid4
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

from antigravity_fixture_node import NODE_ID, request


@contextmanager
def core(binary, env):
    proc = subprocess.Popen([binary], env=env, cwd=env["HOME"])
    try:
        port = int(env["PORT"])
        for _ in range(200):
            if proc.poll() is not None:
                raise RuntimeError(f"Core exited with {proc.returncode}")
            try:
                if request(port, "", "GET", "/api/auth/me")[0] == 401:
                    break
            except OSError:
                pass
            time.sleep(.1)
        yield
    finally:
        proc.terminate()
        proc.wait(timeout=20)


def run(binary, root):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    password = secrets.token_hex(20)
    env = dict(PATH=os.defpath, HOME=root, WORKING_DIR=root, HOST="127.0.0.1",
               PORT=str(port), DASHBOARD_PASSWORD=password, JWT_SECRET=secrets.token_hex(32),
               DEV_MODE="false", ORB_INSTANCE="dev", LEAN_NUM_THREADS="2")

    def login(name):
        status, body = request(port, "", "POST", "/api/auth/login", dict(username=name, password=password))
        assert status == 200, status
        return json.loads(body)["token"]

    with core(binary, env):
        admin = login("admin")
        users = {}
        for username in ("alice", "bob"):
            status, body = request(port, admin, "POST", "/api/admin/users",
                                   dict(username=username, password=password, role="member"))
            assert status == 201, status
            users[username] = json.loads(body)["id"]
    env["SANDBOXED_REMOTE_NODES"] = json.dumps([dict(id=NODE_ID, base_url="http://127.0.0.2:1",
                                                     dedicated_owner_id=users["alice"])])
    with core(binary, env), sqlite3.connect(Path(root) / ".sandboxed-sh/missions.db") as db:
        for name, owner in users.items():
            db.execute("INSERT INTO ai_providers(id,name,provider_type,created_by_user_id) VALUES(?,?,'antigravity',?)",
                       (name, name, owner))
        db.execute("INSERT INTO ai_providers(id,name,provider_type,created_by_user_id) VALUES('second','Second','antigravity',?)",
                   (users["alice"],))
        db.commit()
        alice, bob = login("alice"), login("bob")

        def enroll(token, account, revision, expected):
            status, body = request(port, token, "PUT", "/api/native-owner-enrollments/" + NODE_ID,
                                   dict(account_id=account, expected_revision=revision))
            assert status == expected, (status, body)
            return json.loads(body)

        path = "/api/native-owner-enrollments/" + NODE_ID
        assert request(port, bob, "GET", path)[0] == 403
        status, body = request(port, alice, "GET", path)
        assert status == 200 and json.loads(body) == {"account_id": "", "revision": 0,
                                                     "launch_block": "native_owner_enrollment_required"}
        status, body = request(port, alice, "POST", "/api/control/missions", {
            "backend": "antigravity", "remote_node_id": NODE_ID, "project": "tests",
            "prompt": "Read the disposable ledger.", "writer": False
        })
        assert (status, json.loads(body).get("error")) == (502, "native_owner_enrollment_required"), (status, body)
        enroll(bob, "bob", 0, 403)
        enroll(alice, "bob", 0, 403)
        assert enroll(alice, "alice", 0, 200)["revision"] == 1
        assert enroll(alice, "alice", 1, 200)["revision"] == 1
        assert json.loads(request(port, alice, "GET", path)[1])["launch_block"] == "native_owner_executor_unavailable"
        for token in (alice, bob):
            status, body = request(port, token, "GET", "/api/remote-nodes")
            assert status == 200
            node, = json.loads(body)["nodes"]
            assert node.get("launch_block") == ("native_owner_executor_unavailable" if token == alice else None)
        native_route = "/api/native/antigravity/v1internal:fetchUserInfo"
        grants = {}
        for token, expected in ((alice, 503), (bob, 403), (login("admin"), 403)):
            assert request(port, token, "GET", "/api/providers/antigravity-models?node_id=" + NODE_ID)[0] == expected
        for token, reason in ((alice, "native_owner_executor_unavailable"), (bob, "node_owner_required")):
            status, body = request(port, token, "POST", "/api/control/missions", {
                "backend": "antigravity", "remote_node_id": NODE_ID, "project": "tests",
                "prompt": "Read the disposable ledger.", "writer": False,
                "model_override": "gemini-4-carbon",
            })
            assert (status, json.loads(body).get("error")) == (502, reason), (status, body)
        status, body = request(port, alice, "POST", "/api/control/missions", {
            "backend": "antigravity", "remote_node_id": NODE_ID, "project": "tests", "writer": False
        })
        assert status in (200, 201), (status, body)
        mission = json.loads(body)["id"]
        db.execute("UPDATE missions SET session_id=? WHERE id=?", (str(uuid4()), mission))
        db.commit()
        status, body = request(port, alice, "POST", "/api/control/message", {
            "mission_id": mission, "content": "Read the disposable ledger again."
        })
        assert (status, json.loads(body).get("error")) == (502, "native_owner_executor_unavailable"), (status, body)
        assert db.execute("SELECT count(*) FROM remote_node_jobs").fetchone() == (0,)
        for node in (NODE_ID, "ordinary"):
            grants[node] = "orb-agy-v1_" + secrets.token_hex(24)
            digest = hashlib.sha256(grants[node].encode()).hexdigest()
            db.execute("INSERT INTO remote_node_jobs(job_id,node_id,mission_id,state) VALUES(?,?,?,'running')",
                       (node, node, node))
            db.execute("INSERT INTO mission_proxy_tokens VALUES(?,?,?,2147483647,0)", (digest, node, users["alice"]))
            db.execute("INSERT INTO native_antigravity_grants VALUES(?,?,?,?)", (digest, node, "alice", "fixture"))
        db.commit()
        # Both fixture grants resolve, then the missing mission stops the RPC locally.
        for token in grants.values():
            status, body = request(port, token, "POST", native_route)
            assert (status, json.loads(body)["error"]) == (403, "native_mission_unavailable")
        enroll(alice, "", 0, 409)
        assert enroll(alice, "second", 1, 200)["revision"] == 2
        status, body = request(port, grants[NODE_ID], "POST", native_route)
        assert (status, json.loads(body)["error"]) == (401, "invalid_native_grant")
        status, body = request(port, grants["ordinary"], "POST", native_route)
        assert (status, json.loads(body)["error"]) == (403, "native_mission_unavailable")
        enroll(alice, "alice", 1, 409)
        assert enroll(alice, "", 2, 200)["revision"] == 3
        assert enroll(alice, "alice", 3, 200)["revision"] == 4
        assert request(port, grants[NODE_ID], "POST", native_route)[0] == 401
        print("initial and resumed mission dispatch denied; zero node jobs")
        print("targeted catalog: owner 503, other user and admin 403")
        print("other node owner 403; other account owner 403; owner revision 1; stale revision 409")
        print("rebind revision 2; old grant 401; unrelated grant active; restore original account at revision 4: old grant 401")
    env["SANDBOXED_REMOTE_NODES"] = json.dumps([dict(id=NODE_ID, base_url="http://127.0.0.2:1")])
    with core(binary, env):
        alice = login("alice")
        status, body = request(port, alice, "GET", "/api/providers/antigravity-models?node_id=" + NODE_ID)
        assert (status, json.loads(body)["error"]) == (403, "node_owner_required")
        print("restart without roster owner: persisted reservation refused catalog access")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as root:
        run(Path(sys.argv[1]).resolve(), root)
