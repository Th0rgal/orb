"""Replay native parent delegation with packaged Orb binaries in a loopback-only namespace."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
import uuid


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_listening(port, process):
    for _ in range(150):
        if process.poll() is not None:
            raise RuntimeError("Private service exited before listening")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as peer:
                peer.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                if peer.recv(20).startswith(b"HTTP/1."):
                    return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError("Private service did not start")


@contextlib.contextmanager
def service(command, root, env, **pipes):
    with subprocess.Popen([str(command)], cwd=root, env=env, stderr=subprocess.DEVNULL, **pipes) as process:
        try:
            yield process
        finally:
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()


def replay(bins, root):
    interfaces = {line.split(":")[0].strip() for line in Path("/proc/net/dev").read_text().splitlines()[2:]}
    if interfaces != {"lo"}:
        raise RuntimeError("Run in a private network namespace with only loopback enabled")
    env = {"PATH": os.environ["PATH"], "HOME": str(root)}
    node_port = unused_port()
    key = secrets.token_urlsafe(32)
    node_env = dict(env, SANDBOXED_NODE_ID="fixture", SANDBOXED_NODE_TOKEN=key,
                    SANDBOXED_NODE_BIND=f"127.0.0.1:{node_port}", SANDBOXED_NODE_WORK_DIR=str(root / "node"),
                    SANDBOXED_NODE_ENV_FILE=str(root / "empty-node.env"))
    with contextlib.ExitStack() as stack:
        node = stack.enter_context(service(bins / "sandboxed-node", root, node_env, stdout=subprocess.DEVNULL))
        wait_listening(node_port, node)
        port = unused_port()
        origin = f"http://127.0.0.1:{port}"
        core_env = dict(env, PORT=str(port), HOST="127.0.0.1", DEV_MODE="true", WORKING_DIR=str(root),
                        SANDBOXED_REMOTE_NODES_ENABLED="true", ORB_FIXTURE_TOKEN=key,
                        SANDBOXED_REMOTE_NODES=f"fixture=http://127.0.0.1:{node_port}|ORB_FIXTURE_TOKEN")
        core = stack.enter_context(service(bins / "orb-core", root, core_env, stdout=subprocess.DEVNULL))
        wait_listening(port, core)

        def post(path, body, token=None):
            headers = {"Content-Type": "application/json"}
            if token:
                headers["Authorization"] = "Bearer " + token
            req = urllib.request.Request(origin + path, data=json.dumps(body).encode(), headers=headers)
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.load(response)

        admin = post("/api/auth/login", {"password": ""})["token"]
        parent = post("/api/control/missions", {"backend": "antigravity", "title": "Test parent", "placement": "client"}, admin)["id"]
        scoped = post("/api/mcp/session", {"mission_id": parent, "role": "executor"}, admin)["token"]
        mcp_env = dict(env, SANDBOXED_MCP_API_URL=origin, SANDBOXED_MCP_TOKEN=scoped, SANDBOXED_SH_MISSION_ID=parent)
        mcp = stack.enter_context(service(bins / "sandboxed-mcp", root, mcp_env,
                                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True))

        def send(frame):
            mcp.stdin.write(json.dumps({"jsonrpc": "2.0", **frame}) + "\n")
            mcp.stdin.flush()

        def request(request_id, method, params):
            send({"id": request_id, "method": method, "params": params})
            for line in mcp.stdout:
                frame = json.loads(line)
                if frame.get("id") == request_id:
                    return frame["result"]
            raise RuntimeError("MCP closed before replying")

        request(1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                  "clientInfo": {"name": "offline-replay", "version": "1"}})
        send({"method": "notifications/initialized"})
        assert "start_mission" in [tool["name"] for tool in request(2, "tools/list", {})["tools"]]
        args = {"title": "Direct proof", "prompt": "Reply OK", "backend": "codex", "model_override": "gpt-6.2-astra",
                "remote_node_id": "fixture", "idempotency_key": str(uuid.uuid4())}
        for request_id in (3, 4):
            reply = request(request_id, "tools/call", {"name": "start_mission", "arguments": args})
            assert not reply.get("isError"), "Core rejected child creation or its idempotent replay"

        db = next(root.rglob("missions.db"), None) or next(root.rglob("missions.sqlite"))
        with contextlib.closing(sqlite3.connect(db)) as conn:
            children = conn.execute("SELECT parent_mission_id, backend, model_override FROM missions WHERE id!=?", (parent,)).fetchall()
        assert children == [(parent, "codex", "gpt-6.2-astra")]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin_dir", type=Path, help="Directory containing orb-core, sandboxed-node and sandboxed-mcp")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        replay(args.bin_dir.resolve(), Path(tmp))
    print("One Astra child linked to the authorized parent after two calls with the same idempotency key.")
