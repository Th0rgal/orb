"""Creates a private Linux network and mount namespace. Requires ip, wg, wireproxy, openssl and the Orb sidecar test executable."""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import select
import time
import ssl
import struct
import sys
import subprocess
import tempfile
import threading


def command(*args, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True, check=True).stdout.strip()


def proxy_pids():
    live = []
    for stat in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = stat.read_text().split()
        except (ProcessLookupError, FileNotFoundError):
            continue
        if fields[1:2] == ["(wireproxy)"] and fields[2] != "Z":
            live.append(stat.parent.name)
    return live


def run(driver, parent_mount):
    if os.readlink("/proc/self/ns/mnt") == parent_mount or socket.if_nameindex() != [(1, "lo")]:
        raise RuntimeError("Run inside a fresh mount and network namespace")
    command("mount", "--make-rprivate", "/")
    command("ip", "link", "set", "lo", "up")
    receiver = "192.0.2.80"
    command("ip", "addr", "add", receiver + "/32", "dev", "lo")
    with tempfile.TemporaryDirectory() as path:
        root = Path(path)
        hosts = root / "hosts"
        hosts.write_text("127.0.0.1 localhost airvpn.org provider.test\n")
        command("mount", "--bind", str(hosts), "/etc/hosts")
        if Path("/run/nscd/socket").exists():
            command("mount", "-t", "tmpfs", "tmpfs", "/run/nscd")
        assert socket.gethostbyname("airvpn.org") == "127.0.0.1"
        cert, tls_key = root / "cert.pem", root / "tls.key"
        command("openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "1",
                "-subj", "/CN=provider.test", "-addext", "subjectAltName=DNS:airvpn.org,DNS:api.ipify.org,DNS:provider.test",
                "-out", str(cert), "-keyout", str(tls_key))
        settings = [{"api_key": "fixture-only"}]
        peers = {}
        for idx in range(1, 4):
            name = f"wg{idx}"
            server_ip, client_ip = f"10.77.{idx}.1", f"10.77.{idx}.2"
            port = 51000 + idx
            server_key, client_key = command("wg", "genkey"), command("wg", "genkey")
            server_pub = command("wg", "pubkey", data=server_key + "\n")
            client_pub = command("wg", "pubkey", data=client_key + "\n")
            command("ip", "link", "add", name, "type", "wireguard")
            command("wg", "set", name, "listen-port", str(port), "private-key", "/dev/stdin",
                    "peer", client_pub, "allowed-ips", client_ip + "/32", data=server_key + "\n")
            command("ip", "addr", "add", server_ip + "/24", "dev", name)
            command("ip", "link", "set", name, "up")
            peers[name] = client_ip
            settings.append({"device_id": name, "country": "NL", "server": name,
                             "profile": f"[Interface]\nAddress = {client_ip}/32\nDNS = {receiver}\nPrivateKey = {client_key}\n"
                                        f"[Peer]\nPublicKey = {server_pub}\nEndpoint = 127.0.0.1:{port}\nAllowedIPs = 0.0.0.0/0\n"})
        class DNS(socketserver.BaseRequestHandler):
            def handle(self):
                packet, sock = self.request
                end = packet.index(b"\x00", 12) + 1
                qtype, = struct.unpack_from("!H", packet, end)
                answer = (b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton(receiver)) if qtype == 1 else b""
                sock.sendto(packet[:2] + struct.pack("!HHHHH", 0x8180, 1, int(bool(answer)), 0, 0) + packet[12:end+4] + answer, self.client_address)

        observed = []
        max_sessions = []
        exit_probes = []
        translated = {}
        class Receiver(http.server.BaseHTTPRequestHandler):
            def reply(self, body):
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == "/source":
                    observed.append(self.client_address[0])
                elif self.headers.get("Host", "").split(":")[0] == "api.ipify.org":
                    exit_probes.append(self.client_address[0])
                self.reply(self.client_address[0].encode())

            def do_POST(self):
                assert self.path == "/api/userinfo/"
                assert json.loads(self.rfile.read(int(self.headers["Content-Length"])))["key"] == "fixture-only"
                sessions = [{"vpn_ip": f"10.200.0.{i}"} for i in (1, 2, 3)]
                # A stopped wireproxy releases its UDP socket. WireGuard keeps the
                # previous handshake timestamp until the server peer is removed.
                sockets = set()
                for table in ("/proc/net/udp", "/proc/net/udp6"):
                    for line in Path(table).read_text().splitlines()[1:]:
                        sockets.add(int(line.split()[1].split(":")[1], 16))
                for name, ip in peers.items():
                    endpoint = command("wg", "show", name, "endpoints").split()[-1]
                    if endpoint != "(none)" and int(endpoint.rsplit(":", 1)[-1]) in sockets:
                        sessions.append({"vpn_ip": ip, "exit_ip": translated.get(ip, ip), "server_name": name, "server_country_code": "NL"})
                max_sessions.append(len(sessions))
                self.reply(json.dumps({"result": "ok", "sessions": sessions}).encode())

            def log_message(self, *_):
                pass

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, tls_key)
        with socketserver.UDPServer((receiver, 53), DNS) as dns, http.server.ThreadingHTTPServer(("0.0.0.0", 443), Receiver) as receiver_server:
            receiver_server.socket = context.wrap_socket(receiver_server.socket, server_side=True)
            for service in (dns, receiver_server):
                threading.Thread(target=service.serve_forever, daemon=True).start()
            result = subprocess.run([driver, "wireguard", str(root / "store")], text=True, capture_output=True,
                                    input="".join(json.dumps(item) + "\n" for item in settings),
                                    env={**os.environ, "SSL_CERT_FILE": str(cert)}, timeout=90)
            if result.returncode:
                raise RuntimeError(f"session snapshots {max_sessions}, observed {observed}: {result.stderr}")
            routes = json.loads(result.stdout)
            assert {routes["a"], routes["b"]} <= set(peers.values())
            assert routes["a"] != routes["b"]
            assert routes["c"] in (routes["a"], routes["b"])
            assert routes["direct"] == "127.0.0.1"
            assert observed[:2] == [routes["a"], routes["b"]] or observed[:2] == [routes["b"], routes["a"]]
            assert observed[2:] == [routes["c"], routes["direct"], routes["a"], routes["b"]]
            assert max(max_sessions) == 5
            driver_env = {**os.environ, "SSL_CERT_FILE": str(cert)}
            with subprocess.Popen([driver, "wireguard-hold", str(root / "store")], text=True, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, env=driver_env) as held:
                try:
                    if not select.select([held.stdout], [], [], 90)[0]:
                        raise RuntimeError("Timed out waiting for crash fixture tunnels")
                    assert json.loads(held.stdout.readline()) == {"a": routes["a"], "b": routes["b"]}
                    assert len(proxy_pids()) == 2
                    queries, probes = len(max_sessions), len(exit_probes)
                    def repeat():
                        held.stdin.write("repeat\n")
                        held.stdin.flush()
                        assert select.select([held.stdout], [], [], 15)[0]
                        assert held.stdout.readline().strip() == routes["a"]
                    repeat()
                    assert len(max_sessions) == queries, "repeated request polled AirVPN again"
                    assert exit_probes[probes:] == [routes["a"]], "repeat must independently verify its exit"
                    time.sleep(10.1)
                    repeat()
                    assert len(max_sessions) == queries + 1, "expired session evidence must be refreshed"
                    assert exit_probes[probes:] == [routes["a"], routes["a"]]
                finally:
                    held.kill()
                    held.wait(timeout=5)
            for _ in range(50):
                if not proxy_pids():
                    break
                time.sleep(.1)
            assert not proxy_pids(), "wireproxy survived Core SIGKILL"
            with subprocess.Popen([driver, "wireguard-hold", str(root / "store")], text=True, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, env=driver_env) as resumed:
                try:
                    assert select.select([resumed.stdout], [], [], 90)[0]
                    assert json.loads(resumed.stdout.readline()) == {"a": routes["a"], "b": routes["b"]}
                    assert observed[-2:] == [routes["b"], routes["a"]]

                    def change_exit(source, new_exit):
                        command("iptables", "-t", "nat", "-A", "INPUT", "-s", source, "-d", receiver,
                                "-p", "tcp", "--dport", "443", "-j", "SNAT", "--to-source", new_exit)
                        translated[source] = new_exit

                    def request(action):
                        resumed.stdin.write(action + "\n")
                        resumed.stdin.flush()
                        assert select.select([resumed.stdout], [], [], 60)[0]
                        return resumed.stdout.readline().strip()

                    original = routes["a"]
                    other = routes["b"]
                    replacement, = set(peers.values()) - {original, other}
                    before = len(observed)
                    probes = len(exit_probes)
                    change_exit(original, other)
                    assert request("repeat") == replacement
                    assert exit_probes[probes] == other and exit_probes[-1] == replacement
                    assert observed[before:] == [replacement], "provider reached before replacement verification"
                    change_exit(replacement, other)
                    assert request("expect-blocked") == "blocked"
                    assert observed[before:] == [replacement], "provider reached during exit collision"
                    assert request("other") == other
                    assert observed[before:] == [replacement, other]
                    resumed.stdin.close()
                    assert resumed.wait(timeout=10) == 0
                finally:
                    if resumed.poll() is None:
                        resumed.kill()
                        resumed.wait()
            assert max(max_sessions) == 5
            print(json.dumps(routes), "maximum sessions:", max(max_sessions), "both exits restored after SIGKILL; verified replacement:", replacement, "all-collision request blocked")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("driver", type=Path)
    parser.add_argument("--parent-mount", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.parent_mount:
        run(str(args.driver.resolve()), args.parent_mount)
    else:
        subprocess.run(["unshare", "-Urmn", "--pid", "--fork", "--mount-proc", sys.executable, __file__, str(args.driver.resolve()),
                        "--parent-mount", os.readlink("/proc/self/ns/mnt")], check=True)
