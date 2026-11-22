"""Linux-only, disposable VM fixture. See docs/specs/antigravity-model-account-selection.md."""
import argparse
import contextlib
import ctypes
import errno
import json
import os
from pathlib import Path
import select
import secrets
import shlex
import socket
import socketserver
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import UUID, uuid4

from test_account_vpn_transport import exact

HOST = "ledger.test"
DIRECT = "127.0.0.2"
RELAY = "127.0.0.3"
JOB_UID = 16001
SCRIPT = str(Path(__file__).resolve())


@contextlib.contextmanager
def job_namespace():
    # Create the boundary before starting threads. Only the supervisor retains
    # the outer namespace fd. The job receives no listening or uplink socket.
    outer = os.open("/proc/self/ns/net", os.O_RDONLY)
    try:
        os.unshare(os.CLONE_NEWNET)
        try:
            subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
            fd = os.open("/proc/self/ns/net", os.O_RDONLY)
        finally:
            os.setns(outer, os.CLONE_NEWNET)
        try:
            yield fd
        finally:
            os.close(fd)
    finally:
        os.close(outer)


def exec_job(fd, command):
    os.setns(fd, os.CLONE_NEWNET)
    os.close(fd)
    os.setgroups([])
    os.setgid(JOB_UID)
    os.setuid(JOB_UID)
    pr_set_no_new_privs = 38
    if ctypes.CDLL(None).prctl(pr_set_no_new_privs, 1, 0, 0, 0):
        raise RuntimeError("could not set no_new_privs")
    os.execvp(command[0], command)


def pump(left, right):
    while True:
        ready, _, _ = select.select([left, right], [], [], 120)
        if not ready:
            return
        for src in ready:
            data = src.recv(65536)
            if not data:
                return
            (right if src is left else left).sendall(data)


class Listener(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def project_relay(fd, account_port):
    """Expose only one supervisor-selected, outer loopback TCP socket to the job."""
    class Forward(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                with socket.create_connection(("127.0.0.1", account_port), timeout=10) as upstream:
                    pump(self.request, upstream)
            except (ConnectionError, TimeoutError):
                return

    outer = os.open("/proc/self/ns/net", os.O_RDONLY)
    os.setns(fd, os.CLONE_NEWNET)
    os.close(fd)
    with Listener(("127.0.0.1", 0), Forward) as listener:
        os.setns(outer, os.CLONE_NEWNET)
        os.close(outer)
        print(listener.server_address[1], flush=True)
        listener.serve_forever()


def serve_fixture_account(port, upstream_port):
    class Tunnel(socketserver.BaseRequestHandler):
        def handle(self):
            conn = self.request
            conn.settimeout(10)
            try:
                self.forward(conn)
            except (ConnectionError, EOFError, TimeoutError):
                return

        def forward(self, conn):
            # Same SOCKS5 username/password + domain CONNECT wire contract as
            # OrbCore.AccountVpnRelay. This stand-in accepts one synthetic
            # account and one destination. Orb owns real route verification.
            version, count = exact(conn, 2)
            if version != 5 or 2 not in exact(conn, count):
                conn.sendall(b"\x05\xff")
                return
            conn.sendall(b"\x05\x02")
            version, size = exact(conn, 2)
            user = exact(conn, size)
            password = exact(conn, exact(conn, 1)[0])
            if (version, user, password) != (1, b"antigravity/ledger", b"fixture"):
                conn.sendall(b"\x01\x01")
                return
            conn.sendall(b"\x01\x00")
            if exact(conn, 4) != b"\x05\x01\x00\x03":
                return
            host = exact(conn, exact(conn, 1)[0]).decode("ascii")
            port_requested = int.from_bytes(exact(conn, 2), "big")
            if (host, port_requested) != (HOST, upstream_port):
                conn.sendall(bytes([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]))
                return
            with socket.create_connection((DIRECT, upstream_port), timeout=10,
                                          source_address=(RELAY, 0)) as peer:
                conn.sendall(bytes([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
                pump(conn, peer)

    with Listener(("127.0.0.1", port), Tunnel) as server:
        print(server.server_address[1], flush=True)
        server.serve_forever()


@contextlib.contextmanager
def service(*args, pass_fds=()):
    with subprocess.Popen([sys.executable, SCRIPT, *map(str, args)], pass_fds=pass_fds,
                          stdout=subprocess.PIPE, text=True) as proc:
        try:
            assert select.select([proc.stdout], [], [], 10)[0], "relay startup timed out"
            yield int(proc.stdout.readline())
        finally:
            proc.kill()
            proc.wait(timeout=5)


def hold_tunnel(proxy_port, upstream_port):
    context = ssl.create_default_context(cafile=os.environ["SSL_CERT_FILE"])
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=10) as raw:
        raw.sendall(bytes([5, 1, 2]))
        assert exact(raw, 2) == bytes([5, 2])
        user = b"antigravity/ledger"
        raw.sendall(bytes([1, len(user)]) + user + b"\x07fixture")
        assert exact(raw, 2) == bytes([1, 0])
        raw.sendall(bytes([5, 1, 0, 3, len(HOST)]) + HOST.encode() + upstream_port.to_bytes(2, "big"))
        assert exact(raw, 10)[:2] == bytes([5, 0])
        with context.wrap_socket(raw, server_hostname=HOST) as tls:
            print("TLS connected", flush=True)
            # Timeout fails the test. Only EOF/reset proves active revocation.
            try:
                assert tls.recv(1) == b""
            except ConnectionResetError:
                pass


def dns_query(sock, port):
    # An ordinary A query for ledger.test; only a receipt is needed.
    query = bytes.fromhex("123401000001000000000000") + b"\x06ledger\x04test\0\0\x01\0\x01"
    sock.settimeout(0.4)
    sock.sendto(query, (DIRECT, port))
    return sock.recv(512)


def probe(upstream_port, dns_port):
    assert socket.if_nameindex() == [(1, "lo")]
    assert os.geteuid() == JOB_UID
    for family, address in [(socket.AF_INET, (DIRECT, upstream_port)),
                            (socket.AF_INET6, ("::1", upstream_port))]:
        try:
            conn = socket.socket(family, socket.SOCK_STREAM)
        except OSError as error:
            if family == socket.AF_INET6 and error.errno == errno.EAFNOSUPPORT:
                continue
            raise
        with conn as sock:
            sock.settimeout(1)
            assert sock.connect_ex(address) in (errno.ECONNREFUSED, errno.ENETUNREACH,
                                               errno.EADDRNOTAVAIL), "unexpected direct TCP route"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            dns_query(sock, dns_port)
        except (TimeoutError, ConnectionRefusedError):
            pass
        else:
            raise AssertionError("direct DNS answered")
    try:
        socket.getaddrinfo("direct-dns-check.test.", 443, socket.AF_INET)
    except socket.gaierror as error:
        assert error.errno == socket.EAI_AGAIN, error
    else:
        raise AssertionError("job resolver reached the outer namespace")
    return os.readlink("/proc/self/ns/net")


def run(agy, cert, key, node=None):
    if os.geteuid() or socket.if_nameindex() != [(1, "lo")] or socket.gethostbyname(HOST) != DIRECT:
        raise SystemExit("Requires root in a disposable loopback-only guest mapping ledger.test to 127.0.0.2")
    dns_calls = []
    deliveries = []
    if stat.S_IMODE(key.stat().st_mode) & 0o077 or key.stat().st_uid != 0:
        raise SystemExit("The TLS server key must be root-owned and private")
    if Path("/etc/resolv.conf").read_text().splitlines() != [f"nameserver {DIRECT}", "options timeout:1 attempts:1"]:
        raise SystemExit("Configure the disposable guest resolver as documented")
    shell_requested = threading.Event()
    fleet_requested = threading.Event()

    class DNS(socketserver.BaseRequestHandler):
        def handle(self):
            query, sock = self.request
            dns_calls.append(self.client_address[0])
            sock.sendto(query[:2] + b"\x81\x83" + query[4:], self.client_address)

    class Vendor(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            deliveries.append((self.client_address[0], "control"))
            self.send_response(204)
            self.end_headers()

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert ":streamGenerateContent" in self.path
            deliveries.append((self.client_address[0], "model"))
            names = [f["name"] for t in body.get("tools", [])
                     for f in t.get("functionDeclarations", t.get("function_declarations", []))]
            part = {"text": "ledger complete"}
            if "run_command" in names and not shell_requested.is_set():
                shell_requested.set()
                part = {"functionCall": {"name": "run_command", "args": {
                    "CommandLine": probe_command, "WaitMsBeforeAsync": 5000, "toolSummary": "Check ledger network"}}}
            elif node and "call_mcp_tool" in names and not fleet_requested.is_set():
                fleet_requested.set()
                part = {"functionCall": {"name": "call_mcp_tool", "args": {
                    "ServerName": "sandboxed", "ToolName": "get_compute_fleet", "Arguments": {}}}}
            wire = ("data: " + json.dumps({"candidates": [{"index": 0, "finishReason": "STOP",
                    "content": {"role": "model", "parts": [part]}}]}) + "\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(wire)))
            self.end_headers()
            self.wfile.write(wire)

    with job_namespace() as fd, tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
        workspace = Path(tmp)
        os.chown(workspace, JOB_UID, JOB_UID)
        dns = stack.enter_context(socketserver.UDPServer((DIRECT, 53), DNS))
        vendor = stack.enter_context(ThreadingHTTPServer((DIRECT, 0), Vendor))
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        vendor.socket = tls.wrap_socket(vendor.socket, server_side=True)
        for srv in (dns, vendor):
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            stack.callback(srv.shutdown)
        port = vendor.server_port
        probe_command = shlex.join([sys.executable, SCRIPT, "ledger", str(port), "53"])
        # Positive controls prove both direct-route detectors are reachable.
        with socket.create_connection((DIRECT, port)) as raw:
            with ssl.create_default_context(cafile=cert).wrap_socket(raw, server_hostname=HOST) as conn:
                conn.sendall(b"GET /control HTTP/1.0\r\n\r\n")
                assert b"204" in conn.recv(1024)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            assert dns_query(sock, 53)[:4] == bytes.fromhex("12348183")
        try:
            socket.getaddrinfo("direct-dns-check.test.", 443, socket.AF_INET)
        except socket.gaierror as error:
            assert error.errno == socket.EAI_NONAME, error
        else:
            raise AssertionError("expected fixture DNS NXDOMAIN")
        control_dns_count = len(dns_calls)
        assert control_dns_count >= 2
        print("direct controls: TLS=204 DNS=NXDOMAIN", flush=True)
        env = dict(PATH=os.environ["PATH"], HOME=tmp, TERM="dumb", SSL_CERT_FILE=str(cert),
                   GEMINI_API_KEY="fixture-only", GOOGLE_GEMINI_BASE_URL=f"https://{HOST}:{port}")
        def job_args(command):
            return [sys.executable, SCRIPT, "job", str(fd), *command]

        def job(command, data=None):
            return subprocess.run(job_args(command), pass_fds=(fd,),
                                  env=env, cwd=tmp, input=data, stdin=subprocess.DEVNULL if data is None else None,
                                  capture_output=True, text=True, timeout=100)

        def write_config(path, data):
            target = workspace / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(data))
            for node in (target, *target.parents):
                if node == workspace:
                    break
                os.chown(node, JOB_UID, JOB_UID)

        profile = "profile/" if node else ""
        write_config(profile + ".gemini/antigravity-cli/settings.json", {"modelProvider": "gemini"})
        mission = str(uuid4())
        ledger = workspace / "node" / mission / "ledger.receipt" if node else workspace / "ledger.receipt"
        if node:
            driver = str(Path(SCRIPT).with_name("antigravity_fixture_node.py"))
            token = secrets.token_hex(32) + "\n"
            # A fresh namespace with only loopback makes this a guest-local control port.
            control = [sys.executable, driver]
            server = stack.enter_context(subprocess.Popen(job_args([*control, "start", "3088", mission, str(node)]),
                pass_fds=(fd,), env=env, cwd=tmp, stdin=subprocess.PIPE, text=True))
            stack.callback(server.kill)
            server.stdin.write(token)
            server.stdin.close()
            check = job([*control, "check", "3088", mission], token)
            assert check.returncode == 0, check.stderr
            print(check.stdout.strip(), flush=True)
        allow = [f"command({probe_command})"]
        if node:
            allow.append("mcp(sandboxed/get_compute_fleet)")

        def turn(sid=None):
            cmd = [str(agy), "--mode", "accept-edits", "--settings",
                   json.dumps({"permissions": {"allow": allow}}),
                   "--model", "gemini-4-carbon-high", "--output-format", "stream-json", "--print-timeout", "75s"]
            if sid:
                cmd += ["--conversation", sid]
            invocation = [*cmd, "--print=Check the fixture ledger"]
            if node:
                proc = job([*control, "turn", "3088", mission, *invocation], token)
                print(proc.stderr.strip(), flush=True)
            else:
                proc = job(invocation)
            events = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{")]
            terminal = next((e["result"] for e in events if e.get("event") == "result"), None)
            assert terminal, (proc.returncode, proc.stderr[-500:])
            return proc.returncode, terminal

        with service("account", 0, port) as account_port:
            proxy_port = stack.enter_context(service("project", fd, account_port, pass_fds=(fd,)))
            env["HTTPS_PROXY"] = env["HTTP_PROXY"] = f"socks5://antigravity%2Fledger:fixture@127.0.0.1:{proxy_port}"
            code, result = turn()
            assert code == 0 and result["status"] == "SUCCESS" and result["response"].strip() == "ledger complete", result
            sid = str(UUID(result["conversation_id"]))
            assert ledger.read_text() == f"net:[{os.fstat(fd).st_ino}]"
            if node:
                assert ledger.with_name("fleet.receipt").read_text() == mission
                print("native MCP get_compute_fleet: same mission receipt", flush=True)
            held = stack.enter_context(subprocess.Popen(job_args(
                [sys.executable, SCRIPT, "hold", str(proxy_port), str(port)]), pass_fds=(fd,),
                cwd=tmp, env=env, stdout=subprocess.PIPE, text=True))
            stack.callback(held.kill)
            assert select.select([held.stdout], [], [], 10)[0] and held.stdout.readline().strip() == "TLS connected"
            print("relay up: native turn=SUCCESS shell namespace=job direct TCP/DNS=blocked", flush=True)
        assert held.wait(timeout=5) == 0, "established tunnel survived relay loss"
        before = len(deliveries)
        plain = job([sys.executable, SCRIPT, "probe", str(port), "53"])
        assert plain.returncode == 0, plain.stderr
        code, result = turn(sid)
        assert code != 0 and result["status"] == "ERROR" and result["conversation_id"] == sid, result
        assert len(deliveries) == before and "socks" in result["error"].lower(), result
        print("relay down: established TLS closed native resume=ERROR upstream delta=0 direct TCP/DNS=blocked", flush=True)
        with service("account", account_port, port):
            code, result = turn(sid)
            assert code == 0 and result["status"] == "SUCCESS" and result["conversation_id"] == sid, result
            assert result["response"].strip() == "ledger complete" and len(deliveries) > before
        assert deliveries[0] == ("127.0.0.1", "control")
        assert all(address == RELAY for address, _ in deliveries[1:]) and len(dns_calls) == control_dns_count
        print("relay restored: native resume=SUCCESS same conversation=true direct model calls=0 job DNS packets=0")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "job":
        exec_job(int(sys.argv[2]), sys.argv[3:])
    elif mode == "hold":
        hold_tunnel(*map(int, sys.argv[2:]))
    elif mode == "project":
        project_relay(*map(int, sys.argv[2:]))
    elif mode == "account":
        serve_fixture_account(*map(int, sys.argv[2:]))
    elif mode in ("ledger", "probe"):
        namespace = probe(*map(int, sys.argv[2:]))
        if mode == "ledger":
            Path("ledger.receipt").write_text(namespace)
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        for name in ("agy", "cert", "key"):
            parser.add_argument("--" + name, type=Path, required=True)
        parser.add_argument("--node", type=Path, help="Run native turns through a disposable sandboxed-node")
        args = parser.parse_args()
        run(args.agy.resolve(strict=True), args.cert.resolve(strict=True), args.key.resolve(strict=True),
            args.node.resolve(strict=True) if args.node else None)
