"""Exercise agy -> mission relay -> Core -> a TLS subscription fixture.

Run as root inside a disposable Linux container with only loopback, with
daily-cloudcode-pa.googleapis.com mapped to 127.0.0.1. Pass paths to orb-core
and agy. The test uses a new database, account, mission and disposable HOME.
"""
import argparse
import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid


VENDOR = "daily-cloudcode-pa.googleapis.com"
NATIVE_PATH = "/api/native/antigravity"
ACCOUNT = "fixture-account"
MODELS = {"gemini-4-neon": "MODEL_PLACEHOLDER_M1", "gemini-4-carbon-high": "MODEL_PLACEHOLDER_M2"}
LAUNCHER = Path(__file__).resolve().parents[1] / "lean/OrbCore/OrbCore/antigravity_native_launch.py"


class Subscription(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer fixture-vendor-token":
            self.send_error(401)
            return
        self.server.calls += 1
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method = self.path.split("?", 1)[0].split(":")[-1]
        content_type = "application/json"
        if method == "loadCodeAssist":
            result = {"cloudaicompanionProject": "fixture-project", "currentTier": {"id": "standard-tier"}}
        elif method == "fetchUserInfo":
            result = {
                "regionCode": "PT", "userTags": ["private fixture tag"],
                "userSettings": {"consumerTermsAccepted": True, "telemetryEnabled": False, "marketingEmailsEnabled": True},
            }
        elif method == "fetchAdminControls":
            result = self.server.admin_controls
        elif method == "fetchAvailableModels":
            result = {
                "models": {m: {"displayName": m, "model": enum, "maxTokens": 1048576,
                               "maxOutputTokens": 32768} for m, enum in MODELS.items()},
                "defaultAgentModelId": next(iter(MODELS)),
                "agentModelSorts": [{"displayName": "Models", "groups": [{"displayName": "Google", "modelIds": list(MODELS)}]}],
            }
        elif method == "streamGenerateContent":
            model = body["model"]
            assert model in MODELS
            declarations = {f["name"] for t in body["request"].get("tools", [])
                            for f in t.get("functionDeclarations", t.get("function_declarations", []))}
            part = {"text": "fixture reply"}
            if "write_file" in declarations:
                self.server.requests[model] += 1
                if self.server.requests[model] == 1:
                    part = {"functionCall": {"name": "write_file", "args": {
                        "Path": str(self.server.workspace / model), "Content": "native receipt"}}}
            result = {"response": {
                "candidates": [{"index": 0, "finishReason": "STOP", "content": {"role": "model", "parts": [part]}}],
                "usageMetadata": {"promptTokenCount": 12, "cachedContentTokenCount": 3,
                                  "candidatesTokenCount": 4, "thoughtsTokenCount": 2},
            }}
            content_type = "text/event-stream"
        else:
            result = {}
        wire = json.dumps(result).encode()
        if content_type == "text/event-stream":
            wire = b"data: " + wire + b"\n\n"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(wire)))
        self.end_headers()
        self.wfile.write(wire)


def start_subscription(stack, root, workspace):
    cert, key = root / "cert.pem", root / "cert-key.pem"
    subprocess.run(["openssl", "req", "-config", "/dev/null", "-x509", "-newkey", "rsa:2048",
                    "-nodes", "-days", "1", "-subj", f"/CN={VENDOR}", "-addext", f"subjectAltName=DNS:{VENDOR}",
                    "-out", cert, "-keyout", key], check=True, capture_output=True)
    server = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 443), Subscription))
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    server.workspace = workspace
    server.requests = dict.fromkeys(MODELS, 0)
    server.admin_controls = {}
    server.calls = 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    stack.callback(server.shutdown)
    return server, cert


def http(base, path, token=None):
    data = b"{}" if token else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(base + path, data, headers)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, None


def start_core(stack, root, binary, cert):
    auth = root / "auth"
    auth.mkdir()
    (auth / "antigravity-fixture.json").write_text(json.dumps({
        "type": "antigravity", "prefix": ACCOUNT, "access_token": "fixture-vendor-token",
    }))
    home = root / "core-home"
    home.mkdir()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    env = dict(HOME=str(home), PATH=os.environ["PATH"], WORKING_DIR=str(root), DEV_MODE="true",
               HOST="127.0.0.1", PORT=str(port), CLI_PROXY_AUTH_DIR=str(auth), SSL_CERT_FILE=str(cert))
    core = stack.enter_context(subprocess.Popen([binary], env=env, cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    stack.callback(core.terminate)
    for _ in range(60):
        try:
            if http(base, "/api/health")[0] == 200:
                return base
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("The disposable Core failed to start")


def seed_job(db, model, owner):
    mission, job = str(uuid.uuid4()), str(uuid.uuid4())
    grant = "orb-agy-v1_" + uuid.uuid4().hex
    with db:
        db.execute("INSERT INTO missions(id,owner_user_id,status,backend,model_override) VALUES(?,?,'active','antigravity',?)",
                   (mission, owner, model))
        db.execute("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) "
                   "VALUES(?,?,'fixture','running','{}','','')", (job, mission))
        digest = hashlib.sha256(grant.encode()).hexdigest()
        db.execute("INSERT INTO mission_proxy_tokens VALUES(?,?,?,?,0)", (digest, mission, owner, int(time.time()) + 600))
        db.execute("INSERT INTO native_antigravity_grants(token_sha256,job_id,account_id,model) VALUES(?,?,?,?)",
                   (digest, job, ACCOUNT, model))
    return mission, job, grant


def native_turn(agy, workspace, base, grant, model, conversation=None):
    env = dict(PATH=os.environ["PATH"], HOME=str(workspace), CLOUD_CODE_URL=base + NATIVE_PATH,
               ORB_NATIVE_ANTIGRAVITY_HOME=str(workspace), ORB_NATIVE_ANTIGRAVITY_TOKEN=grant, TERM="dumb")
    args = [sys.executable, "-I", str(LAUNCHER), agy, "--mode", "accept-edits", "--output-format", "stream-json",
            "--model", model]
    if conversation:
        args += ["--conversation", conversation]
    proc = subprocess.run([*args, "--print=Perform the next fixture check"], env=env, cwd=workspace,
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=45)
    events = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{")]
    end = next((e["result"] for e in events if e.get("event") == "result"), {})
    assert proc.returncode == 0 and end.get("status") == "SUCCESS", (model, proc.returncode, end.get("status"))
    return end["conversation_id"]


def run(core, agy):
    interfaces = {line.split(":")[0].strip() for line in Path("/proc/net/dev").read_text().splitlines()[2:]}
    if interfaces != {"lo"} or socket.gethostbyname(VENDOR) != "127.0.0.1":
        raise SystemExit("This fixture requires isolated loopback and a local Google hostname mapping")
    with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
        root = Path(tmp)
        workspace = root / "workspace"
        workspace.mkdir(mode=0o700)
        vendor, cert = start_subscription(stack, root, workspace)
        base = start_core(stack, root, core, cert)
        db = stack.enter_context(contextlib.closing(sqlite3.connect(next(root.rglob("missions.db")))))
        owner = str(uuid.uuid4())
        with db:
            db.execute("INSERT INTO users(id,username,password_hash,role,created_at,updated_at) VALUES(?,'fixture','unused','member','','')", (owner,))
            db.execute("INSERT INTO ai_providers(id,provider_type,name) VALUES(?,'antigravity','Shared fixture account')", (ACCOUNT,))
        for selected in MODELS:
            group = selected.removesuffix("-high")
            mission, job, grant = seed_job(db, group, owner)
            def rpc(name):
                return http(base, NATIVE_PATH + "/v1internal:" + name, grant)
            assert rpc("fetchUserInfo") == (200, {"regionCode": "PT", "userSettings": {
                "consumerTermsAccepted": True, "telemetryEnabled": False}})
            vendor.admin_controls = {"mcpSetting": {"mcpConfigJson": "private-fixture-config"}}
            assert rpc("fetchAdminControls")[0] == 403
            vendor.admin_controls = {}
            # A reachable Direct upstream must receive nothing when this account
            # requires a VPN and no verified tunnel can be established.
            before = vendor.calls
            with db:
                db.execute("INSERT INTO account_vpn_routes(account_id,country) VALUES(?,'NL') "
                           "ON CONFLICT(account_id) DO UPDATE SET country='NL',generation=generation+1", (ACCOUNT,))
            assert rpc("fetchAvailableModels")[0] == 503
            assert vendor.calls == before
            with db:
                db.execute("UPDATE account_vpn_routes SET country='',generation=generation+1 WHERE account_id=?", (ACCOUNT,))
            conversation = native_turn(agy, workspace, base, grant, selected)
            assert (workspace / selected).read_text().strip() == "native receipt"
            assert native_turn(agy, workspace, base, grant, selected, conversation) == conversation
            assert vendor.requests[selected] >= 3
            usage = db.execute("SELECT input_tokens,cache_read_tokens,output_tokens FROM proxy_usage "
                               "WHERE account_id=? AND mission_id=? AND model=? LIMIT 1", (ACCOUNT, mission, group)).fetchone()
            assert usage == (9, 3, 6), usage
            with db:
                db.execute("UPDATE remote_node_jobs SET state='succeeded' WHERE job_id=?", (job,))
            assert rpc("fetchAvailableModels")[0] == 401
            print(json.dumps({"model": selected, "conversation": conversation, "workspace_write": True,
                              "resume": True, "usage": usage, "unavailable_vpn_http": 503, "direct_fallback_calls": 0, "terminal_http": 401}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--agy", type=Path, required=True)
    args = parser.parse_args()
    run(args.core.resolve(strict=True), args.agy.resolve(strict=True))
