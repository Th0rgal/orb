"""Exercise the reserved node's HTTP boundary using disposable identities."""
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

from antigravity_fixture_node import NODE_ID, OWNER, request, submit


def run(binary, dedicated):
    with tempfile.TemporaryDirectory() as root:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        token = secrets.token_hex(32)
        env = dict(PATH=os.defpath, HOME=root, SANDBOXED_NODE_ID=NODE_ID,
                   SANDBOXED_NODE_BIND=f"127.0.0.1:{port}", SANDBOXED_NODE_TOKEN=token,
                   SANDBOXED_NODE_WORK_DIR=root + "/work", SANDBOXED_NODE_MIN_FREE_GB="0",
                   SANDBOXED_NODE_ALLOW_ROOT="1", LEAN_NUM_THREADS="2")
        if dedicated:
            env["ORB_NODE_DEDICATED_OWNER_ID"] = OWNER
        proc = subprocess.Popen([binary], env=env, cwd=root)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    raise RuntimeError(f"node exited with {proc.returncode}")
                try:
                    if request(port, token, "GET", "/heartbeat")[0] == 200:
                        break
                except OSError:
                    pass
                time.sleep(.1)
            mission = str(uuid4())
            job, (status, body) = submit(port, token, mission, "true")
            if dedicated:
                assert (status, body.strip()) == (403, "native_owner_executor_unavailable"), (status, body)
                _, (other_status, reason) = submit(port, token, mission, "true", owner=str(uuid4()))
                assert (other_status, reason.strip()) == (403, "node_owner_required")
                _, (wrong_node, _) = submit(port, token, mission, "true", node_id="other-node")
                assert wrong_node == 400, wrong_node
                assert request(port, "invalid", "POST", "/jobs")[0] == 401
                assert not (Path(root) / "work" / mission).exists()
                print("reserved node: signed owner and other-user jobs 403; unauthenticated job 401; workspace absent")
            else:
                assert status in (200, 202), (status, body)
                for _ in range(100):
                    status, body = request(port, token, "GET", "/jobs/" + job)
                    if '"succeeded"' in body:
                        break
                    time.sleep(.1)
                assert status == 200 and '"succeeded"' in body, (status, body)
                print("ordinary node: valid signed job admitted and succeeded")
        finally:
            proc.terminate()
            proc.wait(timeout=10)


if __name__ == "__main__":
    executable = Path(sys.argv[1]).resolve()
    run(executable, True)
    run(executable, False)
