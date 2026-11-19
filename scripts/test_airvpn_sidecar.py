"""Exercise per-login egress against a real CLIProxyAPI v8 binary in an isolated Linux netns."""
import argparse
import base64
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

from test_account_vpn_transport import exact, serve


def run(binary, reconnect=False, orb_configure=None):
    interfaces = {line.split(":")[0].strip() for line in Path("/proc/net/dev").read_text().splitlines()[2:]}
    if interfaces != {"lo"}:
        raise RuntimeError("Run in a fresh network namespace with only loopback enabled")
    hits = []

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
                    assert host in {"chatgpt.com", "auth.openai.com"} and port == 443
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

    with tempfile.TemporaryDirectory() as temp, serve(Receiver) as receiver, serve(relay("127.0.0.2")) as a, serve(relay("127.0.0.3")) as b:
        root = Path(temp)
        cert, tls_key = root / "cert.pem", root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "1",
                        "-subj", "/CN=chatgpt.com", "-addext", "subjectAltName=DNS:chatgpt.com,DNS:auth.openai.com",
                        "-out", cert, "-keyout", tls_key], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, tls_key)
        model_hits = []
        refresh_hits = []
        reconnect_hits = []
        class Model(Receiver):
            def setup(self):
                self.request = tls.wrap_socket(self.request, server_side=True)
                super().setup()
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
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
                    data = json.dumps(dict(reply, token_type="Bearer", expires_in=3600)).encode()
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
        auth = root / "auth"
        auth.mkdir()
        for name in ("a", "b", "direct"):
            (auth / f"{name}.json").write_text(json.dumps({"type": "codex", "access_token": "fixture-" + name, "prefix": name, "account_id": "acct-" + name, "expired": "2099-01-01T00:00:00Z", "email": name + "@example.invalid"}))
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
        routes = {"a": f"socks5://127.0.0.1:{a}", "b": f"socks5://127.0.0.1:{b}"}
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
                    if len(files) == 3:
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
            if orb_configure:
                conflict = configure("a", routes["b"], "enable")
                assert conflict.returncode == 1 and conflict.stderr.strip() == "vpn_sidecar_proxy_conflict"
            for name, expected in (("a", "127.0.0.2"), ("b", "127.0.0.3"), ("direct", "127.0.0.1")):
                result = request(name)
                assert result["status_code"] == 200 and result["body"] == expected, (name, result)
            listing = urllib.request.Request(f"http://127.0.0.1:{port}/v1/models", headers={"Authorization": "Bearer fixture-client"})
            with urllib.request.urlopen(listing, timeout=3) as response:
                models = [item["id"] for item in json.load(response)["data"]]
            with serve(Model) as model_port:
                for name, stream in (("a", False), ("b", True)):
                    choices = [m for m in models if m.startswith(name + "/gpt-5")]
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
                for name in ("a", "b"):
                    api("PATCH", "credentials/fields", {"name": name + ".json", "refresh_token": "refresh-" + name})
                    api("POST", "credentials/refresh", {"name": name + ".json"})
                assert set(refresh_hits) == {("127.0.0.2", "refresh-a"), ("127.0.0.3", "refresh-b")}, refresh_hits
                if reconnect:
                    for name, url in routes.items():
                        filename = name + ".json"
                        session = api("POST", "oauth/auth-url", {"provider": "codex", "name": filename, "proxy_url": url})
                        assert session["target_auth_id"] == filename
                        state = session["state"]
                        api("POST", "oauth/callback", {"provider": "codex", "code": name, "state": state})
                        for _ in range(80):
                            status = api("GET", "oauth/status?state=" + urllib.parse.quote(state))
                            if status["status"] != "wait":
                                break
                            time.sleep(.1)
                        assert status.get("adopted") and status.get("auth_id") == filename, status
                        saved = api("GET", "credentials/download?name=" + filename)
                        assert saved["refresh_token"] == "rotated-" + name and saved["proxy_url"] == url
                    assert reconnect_hits == [("127.0.0.2", "a"), ("127.0.0.3", "b")], reconnect_hits
                    print("Targeted OAuth reconnect passed for both credential exits.")
                with socket.socket() as unavailable:
                    unavailable.bind(("127.0.0.1", 0))
                    if orb_relay:
                        orb_relay.stdin.write("drop-a\n")
                        orb_relay.stdin.flush()
                        assert orb_relay.stdout.readline().strip() == "blocked"
                        assert request("b")["body"] == "127.0.0.3"
                    else:
                        api("PATCH", "credentials/fields", {"name": "a.json", "proxy_url": f"socks5://127.0.0.1:{unavailable.getsockname()[1]}"})
                    try:
                        result = request("a", via_vpn=False)
                        assert result.get("status_code") != 200
                    except urllib.error.HTTPError as e:
                        assert 400 <= e.code <= 599
                    model = next(m for m in models if m.startswith("a/gpt-5"))
                    wire = json.dumps({"model": model, "input": "synthetic"}).encode()
                    broken = urllib.request.Request(f"http://127.0.0.1:{port}/v1/responses", data=wire,
                                                    headers={"Authorization": "Bearer fixture-client", "Content-Type": "application/json"})
                    try:
                        urllib.request.urlopen(broken, timeout=12).close()
                        raise AssertionError("inference unexpectedly succeeded with unavailable proxy")
                    except urllib.error.HTTPError as e:
                        assert 400 <= e.code <= 599
            if orb_configure:
                disabled = configure("b", routes["b"], "disable")
                assert disabled.returncode == 0, disabled.stderr
                assert request("b", via_vpn=False)["body"] == "127.0.0.1"
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
