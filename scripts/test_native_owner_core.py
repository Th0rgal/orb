"""Test owner enrollment over loopback against an isolated authenticated Core."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
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
    env["SANDBOXED_REMOTE_NODES"] = json.dumps([dict(id=NODE_ID, base_url="http://127.0.0.1:1",
                                                     dedicated_owner_id=users["alice"])])
    with core(binary, env), sqlite3.connect(Path(root) / ".sandboxed-sh/missions.db") as db:
        for name, owner in users.items():
            db.execute("INSERT INTO ai_providers(id,name,provider_type,created_by_user_id) VALUES(?,?,'antigravity',?)",
                       (name, name, owner))
        db.commit()
        alice, bob = login("alice"), login("bob")

        def enroll(token, account, revision, expected):
            status, body = request(port, token, "PUT", "/api/native-owner-enrollments/" + NODE_ID,
                                   dict(account_id=account, expected_revision=revision))
            assert status == expected, (status, body)
            return json.loads(body)

        enroll(bob, "bob", 0, 403)
        enroll(alice, "bob", 0, 403)
        assert enroll(alice, "alice", 0, 200)["revision"] == 1
        assert enroll(alice, "alice", 1, 200)["revision"] == 1
        for node in (NODE_ID, "ordinary"):
            db.execute("INSERT INTO remote_node_jobs(job_id,node_id,mission_id,state) VALUES(?,?,?,'running')",
                       (node, node, node))
            db.execute("INSERT INTO mission_proxy_tokens VALUES(?,?,?,2147483647,0)", (node, node, users["alice"]))
            db.execute("INSERT INTO native_antigravity_grants VALUES(?,?,?,?)", (node, node, "alice", "fixture"))
        db.commit()
        enroll(alice, "", 0, 409)
        assert enroll(alice, "", 1, 200)["revision"] == 2
        assert dict(db.execute("SELECT token_sha256,revoked FROM mission_proxy_tokens")) == {NODE_ID: 1, "ordinary": 0}
        enroll(alice, "alice", 1, 409)
        print("other node owner 403; other account owner 403; owner revision 1; stale revision 409")
        print("unbind revision 2; dedicated grant revoked; unrelated grant active")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as root:
        run(Path(sys.argv[1]).resolve(), root)
