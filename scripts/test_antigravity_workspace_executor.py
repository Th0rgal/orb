"""Exercise a restricted native main agent and Orb's separate workspace MCP in a disposable Linux namespace."""

import argparse
import gzip
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import threading

from native_job_relay.workspace import start_file_executor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PROFILE, WORKSPACE = 16001, 16002


def run(agy, workspace_mcp, model):
    interfaces = {line.split(":")[0].strip() for line in Path("/proc/net/dev").read_text().splitlines()[2:]}
    if os.getuid() != 0 or interfaces != {"lo"}:
        raise RuntimeError("Run as root in a disposable Linux namespace with only loopback")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        root.chmod(0o711)
        work = root / "checkout"
        home = root / "profile"
        work.mkdir(mode=0o700)
        home.mkdir(mode=0o700)
        os.chown(work, WORKSPACE, WORKSPACE)
        os.chown(home, PROFILE, PROFILE)
        image = root / "image"
        (image / "bin").mkdir(parents=True)
        (image / "workspace").mkdir()
        (image / "dev").mkdir()
        shutil.copy2(workspace_mcp, image / "bin/workspace-mcp")
        # Build the disposable image from this trusted binary's exact runtime.
        for line in subprocess.check_output(["ldd", workspace_mcp], text=True).splitlines():
            paths = [word for word in line.split() if word.startswith("/")]
            if paths:
                lib = Path(paths[0])
                dest = image / lib.relative_to("/")
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(lib, dest)
        check_readonly_executor(image, work, root)
        # The account profile and the checkout are not readable across principals.
        for uid, directory in ((PROFILE, work), (WORKSPACE, home)):
            assert subprocess.run(["test", "-r", str(directory)], user=uid, group=uid, extra_groups=[]).returncode == 1

        settings = home / ".gemini/antigravity-cli/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"modelProvider": "gemini",
            "permissions": {"allow": ["mcp(workspace/write_file)"]}}))
        agent = home / ".gemini/config/agents/orb-workspace.md"
        agent.parent.mkdir(parents=True)
        agent.write_text("---\nname: orb-workspace\ndescription: Workspace fixture\nmainAgent: true\n"
                         "subagent: false\ntools: []\ncommandExecutionPolicy: off\n---\nUse the workspace MCP.")
        # Only supervisor-defined configuration is visible to the harness.
        endpoint = root / "workspace.sock"
        cwd = home / "session"
        cfg = cwd / ".agents/mcp_config.json"
        cfg.parent.mkdir(parents=True)
        cfg.write_text(json.dumps({"mcpServers": {"workspace": {"command": shutil.which("socat"),
            "args": ["STDIO", "UNIX-CONNECT:" + str(endpoint)]}}}))
        for path in home.rglob("*"):
            os.chown(path, PROFILE, PROFILE)

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(endpoint))
            os.chown(endpoint, PROFILE, PROFILE)
            endpoint.chmod(0o600)
            listener.listen()
            listener.settimeout(0.2)
            stop = threading.Event()

            def serve_workspace():
                children = []
                try:
                    while not stop.is_set():
                        try:
                            conn, _ = listener.accept()
                        except TimeoutError:
                            continue
                        with conn:
                            _, uid, _ = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                            assert uid == PROFILE
                            rootfd = os.open(image, os.O_DIRECTORY | os.O_NOFOLLOW)
                            workfd = os.open(work, os.O_DIRECTORY | os.O_NOFOLLOW)
                            try:
                                proc = start_file_executor(shutil.which("bwrap"), rootfd, workfd, WORKSPACE, WORKSPACE,
                                                           conn, readonly=False)
                            finally:
                                os.close(workfd)
                                os.close(rootfd)
                            children.append(proc)
                finally:
                    for proc in children:
                        if proc.poll() is None:
                            proc.terminate()
                        proc.wait()

            worker = threading.Thread(target=serve_workspace)
            worker.start()
            try:
                turns(agy, model, home, cwd, work, endpoint)
            finally:
                stop.set()
                worker.join()


def check_readonly_executor(image, work, root):
    sentinel = root / "outside.txt"
    sentinel.write_text("ordinary public test fixture")
    sentinel.chmod(0o644)
    rd = os.open(image, os.O_DIRECTORY)
    wd = os.open(work, os.O_DIRECTORY)
    try:
        client, child = socket.socketpair()
        with client, child:
            proc = start_file_executor(shutil.which("bwrap"), rd, wd, WORKSPACE, WORKSPACE, child, readonly=True)
            child.close()
            try:
                with client.makefile("rwb", buffering=0) as pipe:
                    for name, args in (("read_file", {"path": str(sentinel)}),
                                       ("write_file", {"path": "readonly-receipt", "content": "fixture"})):
                        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": {"name": name, "arguments": args}}
                        pipe.write(json.dumps(request).encode() + b"\n")
                        assert json.loads(pipe.readline())["result"]["isError"]
            finally:
                proc.terminate()
                proc.wait(timeout=5)
        assert not (work / "readonly-receipt").exists()
        print("confined executor: outside fixture invisible; read-only checkout rejected write", flush=True)
    finally:
        os.close(wd)
        os.close(rd)


def turns(agy, model, home, cwd, work, endpoint):
    ledger = work / "ledger"
    advertised = []
    value = "first"

    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            req = json.loads(body)
            tools = {f["name"] for item in req.get("tools", [])
                     for f in item.get("functionDeclarations", item.get("function_declarations", []))}
            if tools:
                advertised.append(tools)
            if "call_mcp_tool" in tools and (not ledger.exists() or ledger.read_text() != value) and len(advertised) == 1:
                part = {"functionCall": {"name": "call_mcp_tool", "args": {"ServerName": "workspace",
                    "ToolName": "write_file", "Arguments": {"path": "ledger", "content": value}}}}
            else:
                part = {"text": "fixture complete"}
            data = {"candidates": [{"index": 0, "finishReason": "STOP",
                "content": {"role": "model", "parts": [part]}}]}
            wire = ("data: " + json.dumps(data) + "\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(wire)))
            self.end_headers()
            self.wfile.write(wire)

    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as upstream:
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        try:
            env = {"PATH": os.environ["PATH"], "HOME": str(home), "TERM": "dumb", "GEMINI_API_KEY": "fixture",
                   "GOOGLE_GEMINI_BASE_URL": f"http://127.0.0.1:{upstream.server_port}"}
            sid = None
            for value in ("first", "offline", "resumed"):
                if value == "offline":
                    endpoint.rename(endpoint.with_suffix(".offline"))
                elif value == "resumed":
                    endpoint.with_suffix(".offline").rename(endpoint)
                advertised.clear()
                cmd = [agy, "--agent", "orb-workspace", "--model", model, "--output-format", "stream-json"]
                if sid:
                    cmd += ["--conversation", sid]
                proc = subprocess.run([*cmd, "--print=Update the workspace ledger"], env=env, cwd=cwd,
                    user=PROFILE, group=PROFILE, extra_groups=[], timeout=40, stdin=subprocess.DEVNULL,
                    capture_output=True, text=True, check=True)
                events = [json.loads(line) for line in proc.stdout.splitlines() if line]
                result = next(event["result"] for event in events if "result" in event)
                assert result["status"] == "SUCCESS" and (sid is None or sid == result["conversation_id"])
                sid = result["conversation_id"]
                assert advertised and all(tools <= {"call_mcp_tool", "list_resources", "read_resource", "manage_task"}
                                          for tools in advertised), advertised
                if value == "offline":
                    assert ledger.read_text() == "first" and not (cwd / "ledger").exists()
                    print(f"{model} disconnected: CLI status={result['status']}; ledger unchanged", flush=True)
                    continue
                assert ledger.read_text() == value and ledger.stat().st_uid == WORKSPACE
                print(f"{model} {value}: ledger owner={WORKSPACE}; profile uid={PROFILE}; restricted MCP tool set", flush=True)
        finally:
            upstream.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agy", required=True)
    parser.add_argument("--workspace-mcp", type=Path, required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    run(args.agy, args.workspace_mcp, args.model)
