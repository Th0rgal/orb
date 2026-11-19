"""Exercise per-login egress against a real CLIProxyAPI v8 binary in an isolated Linux netns."""
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
import sys
import tempfile
import time
import urllib.error
import urllib.request

from test_account_vpn_transport import exact, serve


def run(binary):
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
                if (host, port) == ("127.0.0.1", receiver):
                    destination = receiver
                else:
                    assert (host, port) == ("chatgpt.com", 443)
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
                        "-subj", "/CN=chatgpt.com", "-addext", "subjectAltName=DNS:chatgpt.com",
                        "-out", cert, "-keyout", tls_key], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, tls_key)
        model_hits = []
        class Model(Receiver):
            def setup(self):
                self.request = tls.wrap_socket(self.request, server_side=True)
                super().setup()
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
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
            (auth / f"{name}.json").write_text(json.dumps({"type": "codex", "access_token": "fixture-" + name, "prefix": name, "email": name + "@example.invalid"}))
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
        proc = subprocess.Popen([binary, "-config", str(config)], cwd=root,
                                env={"HOME": temp, "PATH": os.defpath, "SSL_CERT_FILE": str(cert)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
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
            def request(name):
                return api("POST", "requests/api-call", {"auth_index": ids[name + ".json"], "method": "GET",
                           "url": f"http://127.0.0.1:{receiver}/source"})
            for name, proxy in (("a", a), ("b", b)):
                api("PATCH", "credentials/fields", {"name": name + ".json", "proxy_url": f"socks5://127.0.0.1:{proxy}"})
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
                    payload = json.dumps({"model": choices[0], "stream": stream, "input": "synthetic"}).encode()
                    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/responses", data=payload,
                                                 headers={"Authorization": "Bearer fixture-client", "Content-Type": "application/json"})
                    try:
                        with urllib.request.urlopen(req, timeout=12) as response:
                            assert response.status == 200 and b"resp_fixture" in response.read()
                    except urllib.error.HTTPError as e:
                        raise AssertionError((name, e.code, e.read(2048))) from e
                assert model_hits == [("127.0.0.2", "Bearer fixture-a"), ("127.0.0.3", "Bearer fixture-b")], model_hits
            with socket.socket() as unavailable:
                unavailable.bind(("127.0.0.1", 0))
                api("PATCH", "credentials/fields", {"name": "a.json", "proxy_url": f"socks5://127.0.0.1:{unavailable.getsockname()[1]}"})
                try:
                    result = request("a")
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
            assert hits == ["127.0.0.2", "127.0.0.3", "127.0.0.1"], hits
            print("CLIProxyAPI v8 fixture passed: separate credential exits for buffered and streaming inference, Direct management request, proxy outage blocked")
        finally:
            proc.terminate()
            proc.wait(timeout=8)


if __name__ == "__main__":
    run(sys.argv[1])
