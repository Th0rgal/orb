"""Replay native agy stream events and resume with an isolated loopback Gemini fixture."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import UUID


def serve_mcp(receipt):
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request.get("method")
        if method == "initialize":
            result = {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "get_compute_fleet", "description": "List fixture nodes",
                                 "inputSchema": {"type": "object", "properties": {}}}]}
        elif method == "tools/call" and request["params"]["name"] == "get_compute_fleet":
            receipt.write_text("fleet listed")
            result = {"content": [{"type": "text", "text": "One fixture node"}]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                              "error": {"code": -32601, "message": "Method not found"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def run(model):
    interfaces = {line.split(":")[0].strip() for line in Path("/proc/net/dev").read_text().splitlines()[2:]}
    if interfaces != {"lo"}:
        raise SystemExit("Run in a Linux network namespace with only loopback enabled")
    binary = shutil.which("agy")
    if not binary:
        raise SystemExit("agy is required")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        output = root / "proof.txt"
        settings = root / ".gemini/antigravity-cli/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"modelProvider": "gemini"}))
        receipt = root / "fleet-receipt"
        mcp = root / ".agents/mcp_config.json"
        mcp.parent.mkdir()
        mcp.write_text(json.dumps({"mcpServers": {"sandboxed": {"command": sys.executable,
            "args": [str(Path(__file__).resolve()), "--serve-mcp", str(receipt)]}}}))
        goal_settings = Path(__file__).resolve().parents[1] / "lean/OrbCore/OrbCore/antigravity_goal_settings.json"
        requests = []

        class Endpoint(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                if ":streamGenerateContent" not in self.path:
                    self.send_error(404)
                    return
                can_write = any(
                    function.get("name") == "write_file"
                    for tool in body.get("tools", [])
                    for function in tool.get("functionDeclarations", tool.get("function_declarations", []))
                )
                if can_write:
                    requests.append(self.path.split("?")[0])
                if not can_write:
                    # Some agy versions run a lightweight auxiliary model first.
                    part = {"text": "fixture"}
                elif len(requests) == 1:
                    part = {"functionCall": {"name": "call_mcp_tool", "args": {
                        "ServerName": "sandboxed", "ToolName": "get_compute_fleet", "Arguments": {}}}}
                elif len(requests) == 2:
                    part = {"functionCall": {"name": "write_file", "args": {
                        "Path": str(output), "Content": "fixture proof"}}}
                else:
                    part = {"text": "fixture reply" if len(requests) == 3 else "<!-- GOAL_COMPLETE -->"}
                candidate = {"index": 0, "finishReason": "STOP", "content": {"role": "model", "parts": [part]}}
                wire = ("data: " + json.dumps({"candidates": [candidate]}) + "\n\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(wire)))
                self.end_headers()
                self.wfile.write(wire)

        with ThreadingHTTPServer(("127.0.0.1", 0), Endpoint) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = {"PATH": os.environ["PATH"], "HOME": directory, "TERM": "dumb",
                   "GEMINI_API_KEY": "local-fixture", "GOOGLE_GEMINI_BASE_URL": f"http://127.0.0.1:{server.server_port}"}

            def turn(*options):
                model_flags = ["--model", model] if model else []
                proc = subprocess.run([binary, "--settings", goal_settings.read_text(), *model_flags, "--mode", "accept-edits", "--output-format", "stream-json",
                                       *options, "--print=Perform the next fixture step"], cwd=root, env=env,
                                      capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=40)
                assert proc.returncode == 0, f"agy exited with status {proc.returncode}"
                events = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
                start = next(e for e in events if e["event"] == "init")
                end = next(e["result"] for e in events if e["event"] == "result")
                sid = start["conversation_id"]
                assert str(UUID(sid)) == sid == end["conversation_id"]
                assert end["status"] == "SUCCESS"
                return sid, end["response"].strip(), [e["step_update"] for e in events if e["event"] == "step_update"]

            try:
                sid, first, steps = turn()
                assert first == "fixture reply" and output.read_text().strip() == "fixture proof"
                writes = [(s["step_index"], s["state"]) for s in steps if s.get("tool_name") == "write_file"]
                assert writes and writes[0][1] == "ACTIVE" and writes[-1] == (writes[0][0], "DONE")
                resumed, final, _ = turn("--conversation", sid)
                assert resumed == sid and final == "<!-- GOAL_COMPLETE -->"
                assert receipt.read_text() == "fleet listed"
                assert len(requests) == 4
                if model:
                    upstream = "gemini-4-carbon" if model == "gemini-4-carbon-high" else model
                    expected_path = f"/v1beta/models/{upstream}:streamGenerateContent"
                    assert requests == [expected_path] * 4, requests

                # A user policy still wins over the mission-scoped approval.
                receipt.unlink()
                requests.clear()
                settings.write_text(json.dumps({"modelProvider": "gemini", "permissions": {
                    "deny": ["mcp(sandboxed/get_compute_fleet)"]}}))
                _, _, denied_steps = turn()
                assert not receipt.exists()
                assert any(step.get("tool_name") == "call_mcp_tool" for step in denied_steps)
            finally:
                server.shutdown()
                thread.join()
    print("Native Antigravity called the scoped fleet tool, wrote the workspace file and resumed the same conversation to completion.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=["gemini-4-carbon-high", "gemini-4-neon"])
    parser.add_argument("--serve-mcp", type=Path)
    args = parser.parse_args()
    if args.serve_mcp:
        serve_mcp(args.serve_mcp)
    else:
        run(args.model)
