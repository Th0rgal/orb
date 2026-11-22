"""Drive a disposable sandboxed-node over loopback for the agy egress fixture."""
import base64
from contextlib import contextmanager
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import shlex
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

NODE_ID = "ledger-node"
OWNER = "00000000-0000-4000-8000-000000000001"


def request(port, token, method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, json.dumps(body) if body else None,
                           {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        response = connection.getresponse()
        return response.status, response.read().decode()
    finally:
        connection.close()


def submit(port, token, mission, command, node_id=NODE_ID, owner=OWNER):
    job = str(uuid4())
    claims = dict(mission_id=mission, node_id=node_id, scope="job:submit", expires_at=int(time.time()) + 300,
                  job_id=job, owner_user_id=owner, caller_role="admin")
    if node_id is None:
        del claims["node_id"]
    encoded = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=")
    signature = hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()
    body = dict(job_id=job, mission_id=mission, lease_token=encoded.decode() + "." + signature,
                payload=dict(kind="raw_command", command=command))
    return job, request(port, token, "POST", "/jobs", body)


@contextmanager
def scoped_mcp(mission):
    receipt = Path.cwd() / "node" / mission / "fleet.receipt"

    class Core(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, data):
            wire = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(wire)))
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(wire)

        def do_GET(self):
            if self.path != "/api/mcp/capabilities" or self.headers.get("Authorization") != "Bearer mcp1.fixture":
                self.send_error(403)
                return
            self.respond({"contract_version": "1", "identity": {"role": "executor", "mission_id": mission},
                          "tools": [{"name": "get_compute_fleet", "description": "List fixture nodes",
                                     "inputSchema": {"type": "object", "properties": {}}}], "limits": {"session_expires_at": int(time.time()) + 3600}})

        def do_POST(self):
            if (self.path != "/api/mcp/call" or self.headers.get("Authorization") != "Bearer mcp1.fixture" or
                    json.loads(self.rfile.read(int(self.headers["Content-Length"]))) !=
                    {"name": "get_compute_fleet", "arguments": {}}):
                self.send_error(403)
                return
            receipt.write_text(mission)
            self.respond({"ok": True, "result": {"nodes": []}})

    with ThreadingHTTPServer(("127.0.0.1", 0), Core) as core:
        thread = threading.Thread(target=core.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{core.server_port}"
        finally:
            core.shutdown()
            thread.join()


def turn(port, token, mission, command, mcp_url):
    # The guest contains only synthetic endpoints and identities. Use a clean
    # environment for agy and keep its profile outside the dispatcher's checkout.
    data = Path.cwd()
    (data / "tmp").mkdir(mode=0o700, exist_ok=True)
    result = data / ("result-" + str(uuid4()))
    allowed = ["PATH", "TERM", "SSL_CERT_FILE", "GEMINI_API_KEY", "GOOGLE_GEMINI_BASE_URL", "HTTP_PROXY", "HTTPS_PROXY"]
    invocation = ["env", "-i", "HOME=" + str(data / "profile"), "LEAN_NUM_THREADS=2", "TMPDIR=" + str(data / "tmp"), "NO_PROXY=127.0.0.1",
                  "SANDBOXED_MCP_API_URL=" + mcp_url, "SANDBOXED_SH_MISSION_ID=" + mission,
                  "SANDBOXED_MCP_TOKEN=mcp1.fixture", *[k + "=" + os.environ[k] for k in allowed],
                  "sandboxed-mcp", "launch", "--harness", "antigravity", "--", *command]
    job, (status, reply) = submit(port, token, mission,
                                  shlex.join(invocation) + " >" + shlex.quote(str(result)))
    assert status in (200, 202), (status, reply)
    for _ in range(920):
        status, reply = request(port, token, "GET", "/jobs/" + job)
        record = json.loads(reply)
        assert status == 200 and record["mission_id"] == mission and record["owner_user_id"] == OWNER
        if record["state"] in ("succeeded", "failed", "cancelled", "lost"):
            print(f"node job={job} mission={mission} state={record['state']}", file=sys.stderr, flush=True)
            if not result.exists():
                raise RuntimeError(record.get("error"))
            sys.stdout.write(result.read_text())
            sys.exit(record["exit_code"])
        time.sleep(.1)
    raise TimeoutError("node job did not finish")


if __name__ == "__main__":
    operation, raw_port, mission, *args = sys.argv[1:]
    token = sys.stdin.readline().strip()
    port = int(raw_port)
    if operation == "start":
        env = dict(PATH=os.environ["PATH"], HOME=os.environ["HOME"], SANDBOXED_NODE_ID=NODE_ID,
                   SANDBOXED_NODE_BIND=f"127.0.0.1:{port}", SANDBOXED_NODE_TOKEN=token,
                   SANDBOXED_NODE_WORK_DIR=str(Path.cwd() / "node"), SANDBOXED_NODE_MIN_FREE_GB="0",
                   LEAN_NUM_THREADS="2")
        os.execve(args[0], args, env)
    elif operation == "check":
        for _ in range(100):
            try:
                if request(port, token, "GET", "/health")[0] == 200:
                    break
            except OSError:
                pass
            time.sleep(.1)
        for label, node_id in (("missing", None), ("different", "different-node")):
            denied_job, (status, _) = submit(port, token, mission, "true", node_id)
            assert status == 400, status
            assert request(port, token, "GET", "/jobs/" + denied_job)[0] == 404
            print(f"{label} signed node ID: HTTP 400, job absent")
    elif operation == "turn":
        with scoped_mcp(mission) as url:
            turn(port, token, mission, args, url)
