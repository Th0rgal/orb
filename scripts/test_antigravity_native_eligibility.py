"""Trace a rejected OAuth identity request from the released Linux CLI.

Run in a disposable loopback-only guest. Map www.googleapis.com to 127.0.0.1
and supply a disposable TLS certificate and key for that name. Port 443 must
be free. The identity endpoint always rejects and generation is an error.
"""
import argparse
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading

from test_antigravity_native_gateway import LAUNCHER, NATIVE_PATH

HOST = "www.googleapis.com"
GRANT = "orb-agy-v1_negative-fixture"


class Endpoint(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass


def run(agy, cert, key, model):
    interfaces = {row.split(":")[0].strip() for row in Path("/proc/net/dev").read_text().splitlines()[2:]}
    if interfaces != {"lo"} or socket.gethostbyname(HOST) != "127.0.0.1":
        raise SystemExit("Requires loopback-only networking and a local www.googleapis.com mapping")
    identity = []
    gateway = []

    class Identity(Endpoint):
        def do_GET(self):
            bearer = self.headers.get("Authorization", "")
            identity.append((self.headers.get("Host"), self.path, bearer.startswith("Bearer ") and
                             len(bearer) > 7 and bearer != "Bearer " + GRANT))
            self.send_error(401)

    class Gateway(Endpoint):
        def do_POST(self):
            if self.headers.get("Authorization") != "Bearer " + GRANT:
                self.send_error(403)
                return
            method = self.path.split("?")[0].removeprefix(NATIVE_PATH + "/v1internal:")
            gateway.append(method)
            if method == "streamGenerateContent":
                self.send_error(403)
                return
            data = {}
            if method == "loadCodeAssist":
                data = {"cloudaicompanionProject": "fixture-project", "currentTier": {"id": "standard-tier"}}
            if method == "fetchAvailableModels":
                data = {"models": {model: {"displayName": model, "model": "MODEL_PLACEHOLDER_M1"}},
                        "defaultAgentModelId": model, "agentModelSorts": [{"displayName": "Models",
                        "groups": [{"displayName": "Google", "modelIds": [model]}]}]}
            wire = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(wire)))
            self.end_headers()
            self.wfile.write(wire)

    with tempfile.TemporaryDirectory() as home, ExitStack() as stack:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        oauth = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 443), Identity))
        oauth.socket = tls.wrap_socket(oauth.socket, server_side=True)
        core = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Gateway))
        for server in (oauth, core):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            stack.callback(server.shutdown)
        env = dict(PATH=os.environ["PATH"], HOME=home, TERM="dumb", SSL_CERT_FILE=str(cert),
                   CLOUD_CODE_URL=f"http://127.0.0.1:{core.server_port}{NATIVE_PATH}",
                   ORB_NATIVE_ANTIGRAVITY_HOME=home, ORB_NATIVE_ANTIGRAVITY_TOKEN=GRANT)
        result = subprocess.run([sys.executable, "-I", str(LAUNCHER), str(agy), "--model", model,
                                 "--output-format", "stream-json", "--print=Read the fixture ledger"],
                                env=env, cwd=home, capture_output=True, text=True, timeout=60)
        assert identity and all(item == (HOST, "/oauth2/v2/userinfo", True) for item in identity), identity
        assert {"fetchUserInfo", "fetchAvailableModels"} <= set(gateway), gateway
        assert "streamGenerateContent" not in gateway
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        terminal = next(e["result"] for e in events if e.get("event") == "result")
        assert result.returncode and terminal["status"] == "ERROR"
        assert "failed to fetch user info: 401 Unauthorized" in json.dumps(terminal)
        print(f"{model}: gateway discovery 200, GET {HOST}/oauth2/v2/userinfo 401, terminal ERROR, zero generation")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("agy", "cert", "key"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    for model in ("gemini-4-carbon", "gemini-4-neon-high"):
        run(args.agy.resolve(strict=True), args.cert.resolve(strict=True), args.key.resolve(strict=True), model)
