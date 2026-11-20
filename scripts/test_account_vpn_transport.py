"""Probe the native Orb TLS transport using two independent loopback sources."""
import contextlib
import os
from pathlib import Path
import select
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading


@contextlib.contextmanager
def serve(handler):
    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler) as server:
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            server.shutdown()
            thread.join()


def exact(sock, size):
    result = bytearray()
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise EOFError()
        result.extend(chunk)
    return bytes(result)


def run(probe, discovery=False):
    with tempfile.TemporaryDirectory() as temp:
        cert = str(Path(temp) / "cert.pem")
        key = str(Path(temp) / "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=vpn-probe.invalid",
                        "-addext", "subjectAltName=DNS:vpn-probe.invalid,IP:127.0.0.1"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        hits = []

        class Receiver(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    with ctx.wrap_socket(self.request, server_side=True) as conn:
                        conn.settimeout(5)
                        with conn.makefile("rb") as req:
                            request_line = req.readline(4096)
                            headers = []
                            while (line := req.readline(4096)) and line != b"\r\n":
                                headers.append(line.strip().lower())
                            if discovery:
                                assert request_line.startswith(b"GET /v1/models ")
                                assert b"authorization: bearer fixture-only" in headers
                        hits.append(self.client_address[0])
                        body = b'{"data":[{"id":"fixture-model"}]}' if discovery else self.client_address[0].encode()
                        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " +
                                     str(len(body)).encode() + b"\r\n\r\n" + body)
                except ssl.SSLError:
                    pass  # The wrong-certificate case ends before any HTTP request.

        class Proxy(socketserver.BaseRequestHandler):
            def handle(self):
                local = self.request
                local.settimeout(5)
                assert exact(local, 3) == bytes([5, 1, 0])
                local.sendall(bytes([5, 0]))
                assert exact(local, 4) == bytes([5, 1, 0, 3])
                name = exact(local, exact(local, 1)[0])
                assert name in ((b"127.0.0.1",) if discovery else (b"vpn-probe.invalid", b"wrong-name.invalid"))
                assert int.from_bytes(exact(local, 2), "big") == destination
                with socket.socket() as upstream:
                    upstream.bind(("127.0.0.2", 0))
                    upstream.connect(("127.0.0.1", destination))
                    local.sendall(bytes([5, 0, 0, 1, 127, 0, 0, 2, 0, 0]))
                    while True:
                        sockets, _, _ = select.select([local, upstream], [], [], 5)
                        if not sockets:
                            return
                        for source in sockets:
                            try:
                                data = source.recv(65536)
                                if not data:
                                    return
                                (upstream if source is local else local).sendall(data)
                            except (ConnectionResetError, BrokenPipeError):
                                return  # A TLS peer can abort on certificate rejection.

        def request(host, port, expect):
            result = subprocess.run([*probe, host, str(destination), str(port)],
                                    env={**os.environ, "SSL_CERT_FILE": cert},
                                    capture_output=True, text=True, timeout=10)
            if result.returncode or result.stdout.strip() != expect:
                raise AssertionError((host, port, expect, result.stdout, result.stderr))

        with serve(Receiver) as destination, serve(Proxy) as proxy:
            if discovery:
                subprocess.run([*probe, temp, f"https://127.0.0.1:{destination}/v1", str(proxy)],
                               env={**os.environ, "SSL_CERT_FILE": cert}, check=True, timeout=30)
                assert hits == ["127.0.0.1", "127.0.0.2"], hits
                return
            request("127.0.0.1", 0, "127.0.0.1")
            request("vpn-probe.invalid", proxy, "127.0.0.2")
            request("wrong-name.invalid", proxy, "failed")
            with socket.socket() as unavailable:
                unavailable.bind(("127.0.0.1", 0))
                request("127.0.0.1", unavailable.getsockname()[1], "failed")
            assert hits == ["127.0.0.1", "127.0.0.2"], hits


if __name__ == "__main__":
    discovery = sys.argv[1:2] == ["--discovery"]
    run(sys.argv[2:] if discovery else sys.argv[1:], discovery=discovery)
