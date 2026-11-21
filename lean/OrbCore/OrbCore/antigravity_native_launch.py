"""Install a mission-only native CLI login and exec its existing launcher."""
import ctypes
import fcntl
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import secrets
import signal
from contextlib import suppress
from urllib.parse import urlsplit


MAX_BODY = 16 * 1024 * 1024


def read_body(request):
    encoding = request.headers.get("Transfer-Encoding", "").lower()
    if encoding == "chunked" and "Content-Length" not in request.headers:
        body = bytearray()
        while True:
            line = request.rfile.readline(128)
            if not line.endswith(b"\r\n"):
                raise ValueError("invalid chunk header")
            size = int(line.split(b";", 1)[0].strip(), 16)
            if not 0 <= size <= MAX_BODY - len(body):
                raise ValueError("invalid chunk size")
            part = request.rfile.read(size)
            if len(part) != size or request.rfile.read(2) != b"\r\n":
                raise ValueError("invalid chunk")
            if size == 0:
                return bytes(body)
            body.extend(part)
    length = int(request.headers.get("Content-Length", "0"))
    if encoding or not 0 <= length <= MAX_BODY:
        raise ValueError("invalid request size")
    body = request.rfile.read(length)
    if len(body) != length:
        raise ValueError("incomplete request")
    return body


def start_relay(core, grant):
    # Vendor auxiliary clients may present the CLI's login elsewhere. They only
    # receive a local nonce. The real grant can only reach the fixed Core origin.
    nonce = secrets.token_urlsafe(32)

    class Relay(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            if (not self.path.startswith("/v1internal:") or
                    not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + nonce)):
                self.send_error(403)
                return
            try:
                body = read_body(self)
            except (OSError, ValueError):
                self.send_error(400)
                return
            connection = http.client.HTTPSConnection if core.scheme == "https" else http.client.HTTPConnection
            upstream = connection(core.hostname, core.port, timeout=180)
            started = False
            try:
                headers = {k: v for k, v in self.headers.items() if k.lower() in {
                    "accept", "content-type", "content-encoding", "user-agent", "x-goog-api-client", "x-client-version"}}
                headers["Authorization"] = "Bearer " + grant
                upstream.request("POST", core.path.rstrip("/") + self.path, body=body, headers=headers)
                response = upstream.getresponse()
                self.send_response(response.status)
                self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
                self.end_headers()
                started = True
                while chunk := response.read1(65536):
                    self.wfile.write(chunk)
            except (OSError, http.client.HTTPException):
                if not started:
                    self.send_error(502)
            finally:
                upstream.close()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Relay)
    owner_pid = os.getpid()
    if os.fork() == 0:
        # Remote workers run Linux. Scope this helper to the exec'd harness,
        # including abrupt cancellation. Do not retain job pipes or job secrets.
        if ctypes.CDLL(None).prctl(1, signal.SIGTERM, 0, 0, 0) or os.getppid() != owner_pid:
            os._exit(1)
        keep = server.fileno()
        for name in os.listdir("/proc/self/fd"):
            fd = int(name)
            if fd != keep:
                with suppress(OSError):
                    os.close(fd)
        server.serve_forever()
        os._exit(0)
    port = server.server_port
    server.server_close()
    os.environ["CLOUD_CODE_URL"] = f"http://127.0.0.1:{port}"
    return nonce


def launch(argv):
    token = os.environ.pop("ORB_NATIVE_ANTIGRAVITY_TOKEN")
    if not token.startswith("orb-agy-v1_") or not argv:
        raise ValueError("invalid native grant")
    core = urlsplit(os.environ["CLOUD_CODE_URL"])
    if not core.hostname or core.username or core.password or not (
            core.scheme == "https" or (core.scheme == "http" and core.hostname == "127.0.0.1")):
        raise ValueError("invalid native Core URL")
    token = start_relay(core, token)
    for key in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_GENAI_USE_VERTEXAI",
                "GOOGLE_GEMINI_BASE_URL"):
        os.environ.pop(key, None)
    root = Path(os.environ.pop("ORB_NATIVE_ANTIGRAVITY_HOME"))
    uid = os.geteuid()
    # Open each component relative to its parent, refusing links and shared homes.
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if os.fstat(directory).st_uid != uid:
            raise PermissionError("mission workspace owner differs")
        for name in (".gemini", "antigravity-cli"):
            try:
                os.mkdir(name, 0o700, dir_fd=directory)
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
            stat = os.fstat(directory)
            if stat.st_uid != uid or stat.st_mode & 0o022:
                raise PermissionError("shared native home")
        os.fchmod(directory, 0o700)
        fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # The directory descriptor also holds the conversation lock through exec.
        os.set_inheritable(directory, True)
        name = ".token-" + secrets.token_hex(12)
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory)
        try:
            with os.fdopen(fd, "w") as tmp:
                json.dump({"auth_method": "consumer", "token": {"access_token": token, "token_type": "Bearer"}}, tmp)
            os.replace(name, "antigravity-oauth-token", src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            with suppress(FileNotFoundError):
                os.unlink(name, dir_fd=directory)
        os.environ["HOME"] = str(root)
        os.execvp(argv[0], argv)
    finally:
        os.close(directory)


try:
    launch(sys.argv[1:])
except (OSError, ValueError, KeyError):
    sys.exit("Could not start the private Antigravity conversation.")
