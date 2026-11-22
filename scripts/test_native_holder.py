"""Disposable private network. Neither the mock subscription nor its CA leaves this test."""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler
import gzip
import json
import os
from pathlib import Path
import shutil
import socketserver
import ssl
import subprocess
import tempfile
import threading
from unittest.mock import patch
from uuid import uuid4

from native_job_relay.holder import directory, run
from native_job_relay.images import prepared_images
from native_job_relay.transport import Destination


class Subscription(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, data, stream=False):
        wire = json.dumps(data).encode()
        if stream:
            wire = b"data: " + wire + b"\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if stream else "application/json")
        self.send_header("Content-Length", str(len(wire)))
        self.end_headers()
        self.wfile.write(wire)

    def do_GET(self):
        self.server.paths.add(self.path.split("?")[0])
        self.reply({"id": "fixture-user", "email": "fixture@example.invalid", "verified_email": True})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            body = bytearray()
            while length := int(self.rfile.readline().split(b";", 1)[0].strip(), 16):
                body.extend(self.rfile.read(length))
                assert self.rfile.read(2) == b"\r\n"
            self.rfile.readline()
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        payload = json.loads(body) if body else {}
        method = self.path.split("?")[0].split(":")[-1]
        self.server.paths.add(method)
        if method == "loadCodeAssist":
            self.reply({"cloudaicompanionProject": "fixture-project", "currentTier": {"id": "standard-tier"}})
        elif method == "fetchUserInfo":
            self.reply({"userSettings":{"consumerTermsAccepted": True}})
        elif method == "fetchAvailableModels":
            m = self.server.model
            self.reply({"models": {m: {"displayName": m, "model": "MODEL_PLACEHOLDER_M2", "maxTokens": 1048576,
                                      "maxOutputTokens": 32768}}, "defaultAgentModelId": m,
                        "agentModelSorts": [{"displayName":"Models","groups":[{"displayName":"Google","modelIds":[m]}]}]})
        elif method == "streamGenerateContent":
            assert self.headers.get("Authorization") == "Bearer fixture-access-only"
            assert payload["model"] == self.server.model
            tools = {f["name"] for row in payload["request"].get("tools", [])
                     for f in row.get("functionDeclarations", row.get("function_declarations", []))}
            assert tools <= {"call_mcp_tool", "list_resources", "read_resource", "manage_task"}
            self.server.offered.append(tools)
            self.server.generations += 1
            if self.server.generations > 2 and "call_mcp_tool" not in tools:
                self.reply({"response":{"candidates":[{"index":0,"finishReason":"STOP","content":{"role":"model","parts":[{"text":"no MCP"}]}}]}}, True)
                return
            if self.server.ledger.exists() and self.server.ledger.read_text() == self.server.value:
                part = {"text":"fixture complete"}
            else:
                part = {"functionCall":{"name":"call_mcp_tool","args":{"ServerName":"workspace","ToolName":"write_file",
                        "Arguments":{"path":"ledger","content":self.server.value}}}}
            self.reply({"response":{"candidates":[{"index":0,"finishReason":"STOP","content":{"role":"model","parts":[part]}}]}}, True)
        else:
            self.reply({})


@contextmanager
def gateway(root, model, ledger):
    cert, key = root / "ca.pem", root / "fixture.key"
    names = ",".join("DNS:" + dst.value for dst in Destination)
    subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-keyout",key,"-out",cert,"-days","1",
                    "-subj","/CN=isolated-native-fixture","-addext","subjectAltName=" + names],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)

    class Socks(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(5)
            with self.request.makefile("rb", buffering=0) as incoming:
                if incoming.read(3) != b"\x05\x01\x00":
                    return
                self.request.sendall(b"\x05\x00")
                assert incoming.read(4) == b"\x05\x01\x00\x03"
                n = incoming.read(1)[0]
                dest = Destination(incoming.read(n).decode())
                self.server.hosts.add(dest)
                assert incoming.read(2) == b"\x01\xbb"
                self.request.sendall(bytes([5, 0, 0, 1]) + bytes(6))
            with ctx.wrap_socket(self.request, server_side=True) as channel:
                Subscription(channel, self.client_address, self.server)

    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Socks) as server:
        server.paths, server.hosts, server.generations, server.offered = set(), set(), 0, []
        server.model, server.ledger = model, ledger
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            yield server, cert
        finally:
            server.shutdown()


def exercise(agy, mcp, model):
    if os.getuid() or set(i.split(":")[0].strip() for i in Path("/proc/net/dev").read_text().splitlines()[2:]) != {"lo"}:
        raise RuntimeError("use an isolated root user and network namespace with only loopback")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        runtime = root / "runtime"
        runtime.mkdir(mode=0o700)
        work = root / "checkout"
        work.mkdir(mode=0o700)
        os.chown(work, 16002, 16002)
        mission = str(uuid4())
        def fixture_checkout(stack, user, mid):
            assert user == "orb-ledger" and mid == mission
            return directory(stack, work), 16002, 16002
        with gateway(root, model, work / "ledger") as (server, ca), patch(
                "native_job_relay.holder.member_checkout", fixture_checkout):
            prepared_images(runtime, agy, mcp, shutil.which("socat"), ca)
            r, w = os.pipe()
            try:
                packet = dict(unix_user="orb-ledger", exec_uid=16002, mission=mission, owner="member", account="shared",
                              port=server.server_address[1], model=model, readonly=False, access_token="fixture-access-only",
                              prompt="Update the ledger.")
                for value in ("first", "resumed"):
                    server.value = value
                    events = []
                    run(runtime, 16001, 16001, packet, r, events.append)
                    leaked = []
                    for file in (runtime / "sessions").rglob("*"):
                        if file.is_file() and b"fixture-access-only" in file.read_bytes():
                            leaked.append(file.name)
                    assert not leaked, ("mutable session contains probe credential", leaked)
                    result = events[-1]["result"]
                    assert result["status"] == "SUCCESS"
                    assert packet.get("conversation", result["conversation_id"]) == result["conversation_id"]
                    packet["conversation"] = result["conversation_id"]
                    if not server.offered or not all("call_mcp_tool" in call for call in server.offered):
                        assert not (work / "ledger").exists()
                        assert Destination.USERINFO in server.hosts and Destination.DAILY_CLOUD_CODE in server.hosts
                        raise AssertionError(f"{model}: native subscriber returned a terminal response but "
                                             "omitted workspace MCP tools. No file receipt.")
                    assert (work / "ledger").read_text() == value and (work / "ledger").stat().st_uid == 16002
                assert server.generations >= 4
                print(f"{model}: consumer profile, TLS through selected gateway, real agy and workspace-mcp, file and resume verified")
            finally:
                os.close(r)
                os.close(w)


if __name__ == "__main__":
    app = argparse.ArgumentParser()
    app.add_argument("--agy", required=True)
    app.add_argument("--workspace-mcp", required=True)
    app.add_argument("--model", required=True)
    args = app.parse_args()
    exercise(args.agy, args.workspace_mcp, args.model)
