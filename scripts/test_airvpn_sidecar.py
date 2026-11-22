"""Exercise per-login egress against a real CLIProxyAPI v8 binary in an isolated Linux netns."""
import argparse
import base64
import contextlib
import http.server
import json
import os
from pathlib import Path
import secrets
import select
import ssl
import socket
import socketserver
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import urllib.parse

from native_job_relay.transport import Destination
from test_account_vpn_transport import exact, serve


def check_stale_registry(driver):
    class StaleRegistry(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            fixtures = {
                "/v8/management/credentials/download?name=selected.json":
                    {"type": "antigravity", "excluded_models": ["*"]},
                "/v8/management/credentials/models?name=selected.json":
                    {"models": [{"id": "still-available"}]},
            }
            if self.path not in fixtures:
                self.send_error(404)
                return
            data = json.dumps(fixtures[self.path]).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    with serve(StaleRegistry) as port:
        result = subprocess.run([driver, "routers", f"http://127.0.0.1:{port}", "selected.json", "restrict"],
                                input="fixture-management-key\n", text=True, capture_output=True, timeout=10)
        assert result.returncode == 1, "a stored wildcard was reported as enforced despite a live model"


def run(binary, reconnect=False, orb_configure=None):
    interfaces = {line.split(":")[0].strip() for line in Path("/proc/net/dev").read_text().splitlines()[2:]}
    if interfaces != {"lo"}:
        raise RuntimeError("Run in a fresh network namespace with only loopback enabled")
    if orb_configure:
        check_stale_registry(orb_configure)
    hits = []
    kimi_hosts = {"auth.kimi.com", "api.kimi.com"}
    google_hosts = {destination.value for destination in Destination}

    class Receiver(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            hits.append(self.client_address[0])
            body = self.client_address[0].encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    def relay(source_ip):
        class Relay(socketserver.BaseRequestHandler):
            def handle(self):
                sock = self.request
                sock.settimeout(4)
                version, count = exact(sock, 2)
                assert version == 5 and 0 in exact(sock, count)
                sock.sendall(bytes([5, 0]))
                version, cmd, _, family = exact(sock, 4)
                assert (version, cmd) == (5, 1)
                if family == 1:
                    host = socket.inet_ntoa(exact(sock, 4))
                else:
                    assert family == 3
                    host = exact(sock, exact(sock, 1)[0]).decode()
                port = int.from_bytes(exact(sock, 2), "big")
                if host in {"127.0.0.1", "receiver.example.invalid"} and port == receiver:
                    destination = receiver
                else:
                    assert host in {"chatgpt.com", "auth.openai.com", "api.anthropic.com", "platform.claude.com"} | google_hosts | kimi_hosts and port == 443
                    destination = model_port
                with socket.create_connection(("127.0.0.1", destination), 4, (source_ip, 0)) as dest:
                    sock.sendall(bytes([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]))
                    while True:
                        readable, _, _ = select.select([sock, dest], [], [], 8)
                        if not readable:
                            return
                        for source in readable:
                            try:
                                chunk = source.recv(65536)
                                if not chunk:
                                    return
                                (sock if source is dest else dest).sendall(chunk)
                            except (ConnectionResetError, BrokenPipeError):
                                return
        return Relay

    with tempfile.TemporaryDirectory() as temp, serve(Receiver) as receiver, serve(relay("127.0.0.2")) as a, serve(relay("127.0.0.3")) as b, contextlib.ExitStack() as services:
        root = Path(temp)
        cert, tls_key = root / "cert.pem", root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "1",
                        "-subj", "/CN=chatgpt.com", "-addext", "subjectAltName=DNS:chatgpt.com,DNS:auth.openai.com,DNS:api.anthropic.com,DNS:platform.claude.com," + ",".join("DNS:" + h for h in sorted(google_hosts | kimi_hosts)),
                        "-out", cert, "-keyout", tls_key], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, tls_key)
        model_hits = []
        claude_hits = []
        claude_oauth = []
        google_hits = []
        kimi_hits = []
        refresh_hits = []
        reconnect_hits = []
        class Model(Receiver):
            def setup(self):
                self.request = tls.wrap_socket(self.request, server_side=True)
                super().setup()
            def send_json(self, payload):
                data = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path.startswith("/oauth2/v2/userinfo"):
                    google_hits.append(("userinfo", self.client_address[0]))
                    self.send_json({"email": "d@example.invalid"})
                    return
                claude_oauth.append((self.path, self.client_address[0]))
                self.send_json({"account": {"uuid": "acct-c", "email": "c@example.invalid"},
                                "organization": {"uuid": "org-c", "name": "Fixture"}})
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                host = self.headers.get("Host", "").split(":")[0]
                if host in kimi_hosts:
                    if self.path == "/api/oauth/device_authorization":
                        kimi_hits.append(("authorize", self.client_address[0]))
                        self.send_json({"device_code": "fixture-device", "user_code": "fixture-user", "expires_in": 90,
                                        "verification_uri": "https://example.invalid/verify", "interval": 5})
                    elif self.path == "/api/oauth/token":
                        grant, = urllib.parse.parse_qs(body.decode())["grant_type"]
                        kimi_hits.append((grant, self.client_address[0]))
                        self.send_json({"access_token": "fixture-e", "refresh_token": "rotated-e", "expires_in": 3600, "token_type": "Bearer"})
                    else:
                        assert self.path.endswith("/chat/completions"), self.path
                        assert self.headers.get("Authorization") == "Bearer fixture-e"
                        stream = json.loads(body).get("stream", False)
                        kimi_hits.append(("stream" if stream else "inference", self.client_address[0]))
                        message = {"role": "assistant", "content": "fixture-kimi"}
                        frame = {"id": "kimi-fixture", "object": "chat.completion.chunk" if stream else "chat.completion",
                                 "model": "kimi-k2", "choices": [{"index": 0, "delta" if stream else "message": message, "finish_reason": "stop"}]}
                        if stream:
                            data = ("data: " + json.dumps(frame) + "\n\ndata: [DONE]\n\n").encode()
                            self.send_response(200)
                            self.send_header("Content-Type", "text/event-stream")
                            self.send_header("Content-Length", str(len(data)))
                            self.end_headers()
                            self.wfile.write(data)
                        else:
                            self.send_json(frame)
                    return
                method = self.path.split("?")[0].split(":")[-1]
                if method == "fetchAvailableModels":
                    google_hits.append((method, self.client_address[0]))
                    self.send_json({"models": {"gemini-3-flash": {"displayName": "Gemini fixture"}}})
                    return
                if method in ("generateContent", "streamGenerateContent"):
                    assert self.headers.get("Authorization") == "Bearer fixture-d"
                    google_hits.append((method, self.client_address[0]))
                    frame = {"response": {"candidates": [{"content": {"role": "model", "parts": [{"text": "fixture-google"}]},
                                                        "finishReason": "STOP"}]}}
                    if method == "generateContent":
                        self.send_json(frame)
                    else:
                        data = ("data: " + json.dumps(frame) + "\n\n").encode()
                        self.send_response(200)
                        self.send_header("Content-Type", "text/event-stream")
                        self.send_header("Content-Length", str(len(data)))
                        self.end_headers()
                        self.wfile.write(data)
                    return
                if self.path == "/token":
                    grant, = urllib.parse.parse_qs(body.decode())["grant_type"]
                    google_hits.append((grant, self.client_address[0]))
                    self.send_json({"access_token": "fixture-d", "refresh_token": "rotated-d", "expires_in": 3600, "token_type": "Bearer"})
                    return
                if self.path.endswith(":loadCodeAssist"):
                    google_hits.append(("project", self.client_address[0]))
                    self.send_json({"cloudaicompanionProject": "fixture-project", "currentTier": {"id": "standard-tier"}})
                    return
                if self.path == "/v1/oauth/token":
                    fields = json.loads(body)
                    grant = fields["grant_type"]
                    assert grant in ("refresh_token", "authorization_code")
                    claude_oauth.append((grant, self.client_address[0]))
                    self.send_json({"access_token": "fixture-c", "refresh_token": "rotated-c" if grant == "authorization_code" else fields["refresh_token"],
                                    "expires_in": 3600, "account": {"uuid": "acct-c", "email_address": "c@example.invalid"},
                                    "organization": {"uuid": "org-c"}})
                    return
                if self.path.split("?")[0] == "/v1/messages":
                    token = self.headers.get("Authorization") or self.headers.get("X-Api-Key")
                    claude_hits.append((self.client_address[0], token))
                    data = json.dumps({"id": "msg_fixture", "type": "message", "role": "assistant",
                                       "model": json.loads(body)["model"], "content": [{"type": "text", "text": "fixture"}],
                                       "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if self.path == "/oauth/token":
                    fields = urllib.parse.parse_qs(body.decode())
                    if fields["grant_type"] == ["authorization_code"]:
                        code, = fields["code"]
                        reconnect_hits.append((self.client_address[0], code))
                        identity = {"email": code + "@example.invalid",
                                    "https://api.openai.com/auth": {"chatgpt_account_id": "acct-" + code}}
                        claims = base64.urlsafe_b64encode(json.dumps(identity).encode()).rstrip(b"=").decode()
                        reply = {"access_token": "reconnected-" + code, "refresh_token": "rotated-" + code,
                                 "id_token": "e30." + claims + ".fixture"}
                    else:
                        assert fields["grant_type"] == ["refresh_token"]
                        token, = fields["refresh_token"]
                        refresh_hits.append((self.client_address[0], token))
                        reply = {"access_token": "renewed-" + token, "refresh_token": token}
                    # Codex refreshes credentials four days before expiry. Keep freshly
                    # issued grants outside that window so only the explicit refresh under
                    # test rotates them while we check targeted OAuth adoption.
                    data = json.dumps(dict(reply, token_type="Bearer", expires_in=7 * 24 * 3600)).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                model_hits.append((self.client_address[0], self.headers.get("Authorization")))
                event = {"type": "response.completed", "response": {"id": "resp_fixture", "object": "response",
                         "status": "completed", "model": "gpt-5", "output": []}}
                data = ("event: response.completed\ndata: " + json.dumps(event) + "\n\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        model_port = services.enter_context(serve(Model))
        auth = root / "auth"
        auth.mkdir()
        for name in ("a", "b", "direct"):
            (auth / f"{name}.json").write_text(json.dumps({"type": "codex", "access_token": "fixture-" + name, "prefix": "" if orb_configure and name == "a" else name, "account_id": "acct-" + name, "expired": "2099-01-01T00:00:00Z", "email": name + "@example.invalid"}))
        (auth / "c.json").write_text(json.dumps({"type": "claude", "access_token": "fixture-c", "prefix": "c",
                                                "email": "c@example.invalid", "account_uuid": "acct-c", "expired": "2099-01-01T00:00:00Z"}))
        (auth / "e.json").write_text(json.dumps({"type": "kimi", "access_token": "fixture-e", "prefix": "e",
                                                "domain": "kimi.com", "expired": "2099-01-01T00:00:00Z"}))
        (auth / "d.json").write_text(json.dumps({"type": "antigravity", "access_token": "fixture-d", "prefix": "d",
                                                "project_id": "fixture-project", "excluded_models": ["fixture-retired-*"], "email": "d@example.invalid", "expired": "2099-01-01T00:00:00Z"}))
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        key = secrets.token_hex(24)
        config = root / "config.yaml"
        config.write_text(f"server:\n  host: 127.0.0.1\n  port: {port}\naccess:\n  api-keys: [fixture-client]\nmanagement:\n  secret-key: {key}\n  disable-control-panel: true\noauth:\n  auth-dir: {auth}\n")
        def api(method, path, payload=None):
            data = None if payload is None else json.dumps(payload).encode()
            request = urllib.request.Request(f"http://127.0.0.1:{port}/v8/management/{path}", data=data, method=method,
                                             headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=8) as response:
                return json.load(response)
        routes = {"a": f"socks5://127.0.0.1:{a}", "b": f"socks5://127.0.0.1:{b}", "c": f"socks5://127.0.0.1:{a}", "d": f"socks5://127.0.0.1:{b}", "e": f"socks5://127.0.0.1:{a}"}
        orb_relay = None
        proc = subprocess.Popen([binary, "-config", str(config)], cwd=root,
                                env={"HOME": temp, "PATH": os.defpath, "SSL_CERT_FILE": str(cert)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            if orb_configure:
                orb_relay = subprocess.Popen([orb_configure, "relay", str(a), str(b)], stdin=subprocess.PIPE,
                                             stdout=subprocess.PIPE, text=True)
                orb_relay.stdin.write(secrets.token_hex(32) + "\n")
                orb_relay.stdin.flush()
                for name in routes:
                    routes[name] = orb_relay.stdout.readline().strip()
                    assert routes[name].startswith("socks5://"), "Orb fixture relay startup failed"
            for _ in range(100):
                try:
                    files = api("GET", "credentials")["files"]
                    if len(files) == 6:
                        break
                except urllib.error.URLError:
                    pass
                if proc.poll() is not None:
                    raise RuntimeError("fixture sidecar exited")
                time.sleep(.1)
            else:
                raise RuntimeError("fixture credentials unavailable")
            ids = {f["name"]: f["auth_index"] for f in files}
            def request(name, via_vpn=True):
                host = "receiver.example.invalid" if via_vpn and name != "direct" else "127.0.0.1"
                return api("POST", "requests/api-call", {"auth_index": ids[name + ".json"], "method": "GET",
                           "url": f"http://{host}:{receiver}/source"})
            def configure(name, url, mode):
                if orb_configure:
                    return subprocess.run([orb_configure, f"http://127.0.0.1:{port}", name + ".json", url, mode],
                                          input=key + "\n", text=True, capture_output=True, timeout=15)
                api("PATCH", "credentials/fields", {"name": name + ".json", "proxy_url": url if mode == "enable" else ""})

            for name, url in routes.items():
                changed = configure(name, url, "enable")
                if orb_configure:
                    assert changed.returncode == 0, changed.stderr
            prefixes = {name: api("GET", "credentials/download?name=" + name + ".json")["prefix"] for name in routes}
            if orb_configure:
                assert prefixes["a"].startswith("orb-vpn-") and prefixes["b"] == "b"
                def confirm(name, url, prefix):
                    return subprocess.run([orb_configure, "confirm", f"http://127.0.0.1:{port}", name + ".json", url, prefix],
                                          input=key + "\n", text=True, capture_output=True, timeout=15).returncode
                assert confirm("a", routes["a"], prefixes["a"]) == 0
                assert confirm("a", routes["b"], prefixes["a"]) == 1
                assert confirm("a", routes["a"], prefixes["b"]) == 1
            if orb_configure:
                conflict = configure("a", routes["b"], "enable")
                assert conflict.returncode == 1 and conflict.stderr.strip() == "vpn_sidecar_proxy_conflict"
            for name, expected in (("a", "127.0.0.2"), ("b", "127.0.0.3"), ("direct", "127.0.0.1")):
                result = request(name)
                assert result["status_code"] == 200 and result["body"] == expected, (name, result)
            listing = urllib.request.Request(f"http://127.0.0.1:{port}/v1/models", headers={"Authorization": "Bearer fixture-client"})
            with urllib.request.urlopen(listing, timeout=3) as response:
                models = [item["id"] for item in json.load(response)["data"]]
            def exercise_routed_accounts():
                for name, stream in (("a", False), ("b", True)):
                    choices = [m for m in models if m.startswith(prefixes[name] + "/gpt-5")]
                    assert choices, models[:25]
                    payload = json.dumps({"model": choices[0], "stream": stream, "input": "synthetic",
                                          "proxy_url": f"socks5://127.0.0.1:{b if name == 'a' else a}"}).encode()
                    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/responses", data=payload,
                                                 headers={"Authorization": "Bearer fixture-client", "Content-Type": "application/json"})
                    try:
                        with urllib.request.urlopen(req, timeout=12) as response:
                            assert response.status == 200 and b"resp_fixture" in response.read()
                    except urllib.error.HTTPError as e:
                        raise AssertionError((name, e.code, e.read(2048))) from e
                assert model_hits == [("127.0.0.2", "Bearer fixture-a"), ("127.0.0.3", "Bearer fixture-b")], model_hits
                def claude_inference():
                    model = next(m for m in models if m.startswith("c/claude-"))
                    wire = json.dumps({"model": model, "max_tokens": 8, "messages": [{"role": "user", "content": "synthetic"}]}).encode()
                    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/messages", data=wire,
                                                 headers={"Authorization": "Bearer fixture-client", "Content-Type": "application/json",
                                                          "Anthropic-Version": "2023-06-01"})
                    with urllib.request.urlopen(req, timeout=12) as response:
                        assert json.load(response)["id"] == "msg_fixture"
                    assert claude_hits[-1] == ("127.0.0.2", "Bearer fixture-c"), claude_hits
                claude_inference()
                google_models = [model for model in models if model.startswith("d/gemini-")]
                assert google_models, [model for model in models if model.startswith("d/")]
                def chat_inference(model, stream, expected):
                    wire = json.dumps({"model": model, "stream": stream,
                                       "messages": [{"role": "user", "content": "synthetic"}]}).encode()
                    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=wire,
                                                 headers={"Authorization": "Bearer fixture-client", "Content-Type": "application/json"})
                    with urllib.request.urlopen(req, timeout=15) as response:
                        assert expected in response.read()
                for stream in (False, True):
                    count = len([kind for kind, _ in google_hits if kind in ("generateContent", "streamGenerateContent")])
                    chat_inference(google_models[0], stream, b"fixture-google")
                    assert len([kind for kind, _ in google_hits if kind in ("generateContent", "streamGenerateContent")]) > count
                # A native-only account must also disappear from the sidecar's
                # unqualified model pool. Exercise the released binary and a
                # real HTTP inference request before and after the restriction.
                def set_google_exclusions(exclusions, visible):
                    if orb_configure:
                        action = "allow" if visible else "restrict"
                        subprocess.run([orb_configure, "routers", f"http://127.0.0.1:{port}", "d.json", action],
                                       input=key + "\n", text=True, check=True, timeout=15)
                    else:
                        api("PATCH", "credentials/fields", {"name": "d.json", "excluded_models": exclusions})
                    saved = api("GET", "credentials/download?name=d.json")
                    assert saved.get("excluded_models", []) == exclusions
                    for _ in range(60):
                        with urllib.request.urlopen(listing, timeout=3) as response:
                            advertised = {m["id"] for m in json.load(response)["data"]}
                        if (google_models[0] in advertised) == visible:
                            return
                        time.sleep(.2)
                    raise AssertionError("sidecar catalog did not apply the Antigravity account policy")

                assert api("GET", "credentials/models?name=d.json")["models"]
                set_google_exclusions(["fixture-retired-*", "*"], False)
                assert api("GET", "credentials/models?name=d.json")["models"] == []
                def generation_hits():
                    return sum(k in ("generateContent", "streamGenerateContent") for k, _ in google_hits)
                before = generation_hits()
                for model in (google_models[0], google_models[0].split("/", 1)[1]):
                    try:
                        chat_inference(model, False, b"fixture-google")
                    except urllib.error.HTTPError as error:
                        assert 400 <= error.code < 600
                    else:
                        raise AssertionError("native-only account served alternative-router inference")
                assert generation_hits() == before
                claude_inference()  # another provider remains available during the restriction
                kimi_model = next(m for m in models if m.startswith("e/kimi-"))
                for stream in (False, True):
                    chat_inference(kimi_model, stream, b"fixture-kimi")
                for name in ("a", "b", "c", "d", "e"):
                    api("PATCH", "credentials/fields", {"name": name + ".json", "refresh_token": "refresh-" + name})
                    api("POST", "credentials/refresh", {"name": name + ".json"})
                assert set(refresh_hits) == {("127.0.0.2", "refresh-a"), ("127.0.0.3", "refresh-b")}, refresh_hits
                if reconnect:
                    for name, url in routes.items():
                        provider = {"a": "codex", "b": "codex", "c": "claude", "d": "antigravity", "e": "kimi"}[name]
                        filename = name + ".json"
                        session = api("POST", "oauth/auth-url", {"provider": provider, "name": filename, "proxy_url": url})
                        assert session["target_auth_id"] == filename
                        state = session["state"]
                        if provider != "kimi":
                            api("POST", "oauth/callback", {"provider": provider, "code": name, "state": state})
                        for _ in range(80):
                            status = api("GET", "oauth/status?state=" + urllib.parse.quote(state))
                            if status["status"] != "wait":
                                break
                            time.sleep(.1)
                        assert status.get("adopted") and status.get("auth_id") == filename, status
                        saved = api("GET", "credentials/download?name=" + filename)
                        assert saved.get("prefix") == prefixes[name]
                        assert saved["refresh_token"] == "rotated-" + name and saved["proxy_url"] == url
                    assert {"inference", "stream", "refresh_token", "authorize", "urn:ietf:params:oauth:grant-type:device_code"} <= {kind for kind, _ in kimi_hits}, kimi_hits
                    assert all(ip == "127.0.0.2" for _, ip in kimi_hits), kimi_hits
                    assert {"authorization_code", "refresh_token", "userinfo", "project", "fetchAvailableModels"} <= {kind for kind, _ in google_hits}, google_hits
                    assert all(ip == "127.0.0.3" for _, ip in google_hits), google_hits
                    assert reconnect_hits == [("127.0.0.2", "a"), ("127.0.0.3", "b")], reconnect_hits
                    assert ("authorization_code", "127.0.0.2") in claude_oauth, claude_oauth
                    print("Targeted OAuth reconnect passed for two ChatGPT fixtures, Claude, Google Antigravity and Kimi.")
                saved_google = api("GET", "credentials/download?name=d.json")
                assert saved_google.get("excluded_models") == ["fixture-retired-*", "*"], "refresh or reconnect lost router restriction"
                if reconnect:
                    # Direct reconnects also have to adopt the restricted credential.
                    api("PATCH", "credentials/fields", {"name": "d.json", "proxy_url": ""})
                    direct = api("POST", "oauth/auth-url", {"provider": "antigravity", "name": "d.json"})
                    assert direct["target_auth_id"] == "d.json"
                    api("DELETE", "oauth/session?state=" + urllib.parse.quote(direct["state"]))
                    saved = api("GET", "credentials/download?name=d.json")
                    assert not saved.get("proxy_url") and saved["excluded_models"] == ["fixture-retired-*", "*"]
                    api("PATCH", "credentials/fields", {"name": "d.json", "proxy_url": routes["d"]})
                set_google_exclusions(["fixture-retired-*"], True)
                chat_inference(google_models[0], False, b"fixture-google")
                assert ("refresh_token", "127.0.0.2") in claude_oauth, claude_oauth
                assert all(ip == "127.0.0.2" for _, ip in claude_oauth), claude_oauth
                with socket.socket() as unavailable:
                    unavailable.bind(("127.0.0.1", 0))
                    if orb_relay:
                        orb_relay.stdin.write("drop-a-d-e\n")
                        orb_relay.stdin.flush()
                        assert orb_relay.stdout.readline().strip() == "blocked"
                        assert request("b")["body"] == "127.0.0.3"
                        claude_inference()
                        for model, content, recorded in [(google_models[0], b"fixture-google", google_hits),
                                                         (kimi_model, b"fixture-kimi", kimi_hits)]:
                            before = len(recorded)
                            try:
                                chat_inference(model, False, content)
                                raise AssertionError("inference used an unavailable account route")
                            except urllib.error.HTTPError as e:
                                assert 400 <= e.code <= 599
                            assert len(recorded) == before
                        if reconnect:
                            before = list(kimi_hits)
                            try:
                                api("POST", "oauth/auth-url", {"provider": "kimi", "name": "e.json", "proxy_url": routes["e"]})
                                raise AssertionError("device authorization used an unavailable account route")
                            except urllib.error.HTTPError as e:
                                assert 400 <= e.code <= 599
                            assert kimi_hits == before
                    else:
                        api("PATCH", "credentials/fields", {"name": "a.json", "proxy_url": f"socks5://127.0.0.1:{unavailable.getsockname()[1]}"})
                    try:
                        result = request("a", via_vpn=False)
                        assert result.get("status_code") != 200
                    except urllib.error.HTTPError as e:
                        assert 400 <= e.code <= 599
                    model = next(m for m in models if m.startswith(prefixes["a"] + "/gpt-5"))
                    wire = json.dumps({"model": model, "input": "synthetic"}).encode()
                    broken = urllib.request.Request(f"http://127.0.0.1:{port}/v1/responses", data=wire,
                                                    headers={"Authorization": "Bearer fixture-client", "Content-Type": "application/json"})
                    try:
                        urllib.request.urlopen(broken, timeout=12).close()
                        raise AssertionError("inference unexpectedly succeeded with unavailable proxy")
                    except urllib.error.HTTPError as e:
                        assert 400 <= e.code <= 599

            exercise_routed_accounts()
            if orb_configure:
                disabled = configure("b", routes["b"], "disable")
                assert disabled.returncode == 0, disabled.stderr
                assert request("b", via_vpn=False)["body"] == "127.0.0.1"
                disabled_a = configure("a", routes["a"], "disable")
                assert disabled_a.returncode == 0, disabled_a.stderr
                assert not api("GET", "credentials/download?name=a.json").get("prefix")
                assert api("GET", "credentials/download?name=b.json")["prefix"] == "b"
            expected_hits = ["127.0.0.2", "127.0.0.3", "127.0.0.1"]
            if orb_configure:
                expected_hits.extend(["127.0.0.3", "127.0.0.1"])
            assert hits == expected_hits, hits
            print("CLIProxyAPI v8 fixture passed: separate credential exits for buffered and streaming inference and token refresh, Direct management request, proxy outage blocked")
        finally:
            proc.terminate()
            proc.wait(timeout=8)
            if orb_relay:
                orb_relay.stdin.close()
                orb_relay.wait(timeout=12)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--reconnect", action="store_true")
    parser.add_argument("--orb-configure", type=Path, help="Path to the orb-airvpn-sidecar-test executable")
    opts = parser.parse_args()
    run(str(opts.binary.resolve()), opts.reconnect, str(opts.orb_configure.resolve()) if opts.orb_configure else None)
