"""Exercise a Direct Codex reconnect against a loopback-only Core and sidecar."""
from contextlib import ExitStack, closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import sys
import tempfile
import threading
from uuid import uuid4

from test_native_owner_core import core, request


def replay(binary):
    seen = []
    targeted_supported = False
    name = "original-account.json"
    calls = "/api/ai/providers/cli-proxy-login"

    class Sidecar(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self):
            size = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(size)) if size else None
            seen.append((self.command, self.path, body))
            result = {"status": "ok"}
            if self.path.endswith("auth-url"):
                result = dict(url="https://fixture.invalid/consent", state="fixture", target_auth_id=name)
            wire = json.dumps(result).encode()
            unsupported = self.path == "/v8/management/oauth/auth-url" and not targeted_supported
            self.send_response(404 if unsupported else 200)
            self.send_header("Content-Length", str(len(wire)))
            self.end_headers()
            self.wfile.write(wire)

        do_GET = do_POST = respond

    with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
        sidecar = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Sidecar))
        thread = threading.Thread(target=sidecar.serve_forever)
        thread.start()
        stack.callback(thread.join)
        stack.callback(sidecar.shutdown)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        directory = Path(temp) / "auth"
        directory.mkdir()
        password = secrets.token_hex(24)
        env = dict(PATH=os.defpath, HOME=temp, WORKING_DIR=temp, PORT=str(port), HOST="127.0.0.1",
                   DEV_MODE="false", JWT_SECRET=secrets.token_hex(32), DASHBOARD_PASSWORD=password,
                   CLI_PROXY_AUTH_DIR=str(directory), CLI_PROXY_MANAGEMENT_KEY="fixture-only",
                   CLAUDE_CODE_PROXY_BASE_URL=f"http://127.0.0.1:{sidecar.server_port}")
        account, peer = str(uuid4()), "cliproxyapi:openai:another-account"
        email = "shared@fixture.invalid"
        credential = dict(type="codex", access_token="fixture-before", email=email, account_id="upstream-A")
        other = directory / "different-account.json"
        other.write_text(json.dumps({**credential, "account_id": "upstream-B"}))
        state = Path(temp) / ".sandboxed-sh"
        state.mkdir()
        (state / "ai_providers.json").write_text(json.dumps([dict(
            id=account, provider_type="openai", account_email=email, cli_proxy_auth_file=name,
            oauth={"access_token": "legacy-fixture"})]))
        with core(binary, env):
            code, raw = request(port, "", "POST", "/api/auth/login", dict(username="admin", password=password))
            assert code == 200, code
            token = json.loads(raw)["token"]
            with closing(sqlite3.connect(state / "missions.db")) as db:
                db.execute("INSERT OR IGNORE INTO ai_providers(id, provider_type, name) VALUES(?,'openai','reserved')", (account,))
                db.execute("INSERT INTO provider_auth_health(account_key,code,observed_at) VALUES(?,'auth_unavailable','t0')", (peer,))
                db.commit()
                def start():
                    return request(port, token, "POST", calls, dict(provider="openai", provider_id=account))

                code, raw = start()
                assert code == 409 and "Add subscription account" in raw, (code, raw)
                assert not any(path.endswith("auth-url") for _, path, _ in seen), seen
                original = directory / name
                original.write_text(json.dumps(credential))
                code, raw = start()
                assert code == 502 and "targeted OAuth" in raw, (code, raw)
                assert not any(path.endswith("codex-auth-url") for _, path, _ in seen), seen
                targeted_supported = True
                code, raw = start()
                assert code == 200, (code, raw)
                sid = json.loads(raw)["session_id"]
                assert ("POST", "/v8/management/oauth/auth-url", {"name": name, "provider": "codex"}) in seen
                def status():
                    code, raw = request(port, token, "GET", f"{calls}/{sid}")
                    assert code == 200, (code, raw)
                    return json.loads(raw)["status"]
                other.write_text(json.dumps({**credential, "account_id": "upstream-B", "access_token": "changed-other"}))
                assert status() == "completing"
                original.write_text(json.dumps({**credential, "access_token": "changed-target"}))
                assert status() == "completed"
                assert db.execute("SELECT code FROM provider_auth_health WHERE account_key=?", (peer,)).fetchone() == ("auth_unavailable",)
                assert db.execute("SELECT enabled FROM ai_providers WHERE id=?", (account,)).fetchone() == (1,)
                print("Stale target rejected before consent. Only the original file completed the bound Direct session; peer health retained.")


if __name__ == "__main__":
    replay(str(Path(sys.argv[1]).resolve()))
