"""Executable integration tests with a local Core fixture, never live accounts."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import unittest

BINARY = Path(os.environ.get("SANDBOXED_MCP_TEST_BINARY", Path(__file__).resolve().parents[1] / "target/debug/sandboxed-mcp"))
MISSION = "00000000-0000-0000-0000-000000000001"


@contextlib.contextmanager
def core(expiring=False):
    state = {"renewals": 0, "sessions": 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def respond(self, value):
            body = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.respond({"contract_version": "1", "identity": {"role": "executor", "mission_id": MISSION, "project": None},
                          "tools": [], "limits": {"session_expires_at": int(time.time()) +
                          (60 if expiring and self.headers.get("Authorization") == "Bearer mcp1.initial" else 3600)}})

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.path == "/api/mcp/session":
                if (self.headers.get("Authorization") != "Bearer owner-login" or
                        json.loads(body) != {"role": "executor", "mission_id": MISSION, "project": None}):
                    self.send_error(403)
                    return
                state["sessions"] += 1
                self.respond({"token": "mcp1.initial", "expires_at": int(time.time()) + 3600})
                return
            if self.path != "/api/mcp/renew":
                self.send_error(404)
                return
            state["renewals"] += 1
            self.respond({"token": "mcp1.renewed", "expires_at": int(time.time()) + 3600})

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", state
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


@unittest.skipUnless(BINARY.is_file(), "build sandboxed-mcp first")
class RuntimeTests(unittest.TestCase):
    def test_grok_headless_profile_preserves_native_session_and_auth_home(self):
        with core() as (url, _), tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "grok"
            cli.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
profile = pathlib.Path(sys.argv[sys.argv.index('--agent') + 1])
value = json.loads(profile.read_text().split('---')[1])
assert value['promptMode'] == 'extend'
server = value['mcpServers'][0]
credential = pathlib.Path(server['args'][server['args'].index('--token-file') + 1])
assert credential.read_text() == 'mcp1.initial'
assert os.environ['GROK_HOME'] == '/unchanged/grok'
assert os.environ['GROK_AUTH_PATH'] == '/unchanged/auth.json'
assert 'SANDBOXED_MCP_TOKEN' not in os.environ
assert sys.argv[sys.argv.index('--session-id') + 1] == 'fixed-native-session'
print(json.dumps({'profile': str(profile), 'credential': str(credential)}))
""")
            cli.chmod(0o700)
            env = dict(os.environ, SANDBOXED_MCP_API_URL=url, SANDBOXED_MCP_TOKEN="mcp1.initial",
                       SANDBOXED_SH_MISSION_ID=MISSION, GROK_HOME="/unchanged/grok", GROK_AUTH_PATH="/unchanged/auth.json")
            result = subprocess.run([str(BINARY), "launch", "--harness", "grok", "--", str(cli),
                                     "--session-id", "fixed-native-session", "-p", "hello"],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            for path in json.loads(result.stdout).values():
                self.assertFalse(Path(path).exists())

    def test_grok_acp_injection_and_exit_with_parent_stdin_still_open(self):
        with core() as (url, _), tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "grok"
            cli.write_text("""#!/usr/bin/env python3
import json, sys
request=json.loads(sys.stdin.readline())
print(json.dumps(request), flush=True)
""")
            cli.chmod(0o700)
            env = dict(os.environ, SANDBOXED_MCP_API_URL=url, SANDBOXED_MCP_TOKEN="mcp1.initial",
                       SANDBOXED_SH_MISSION_ID=MISSION)
            process = subprocess.Popen([str(BINARY), "launch", "--harness", "grok", "--", str(cli), "agent", "stdio"],
                                       env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                process.stdin.write(json.dumps({"id":1,"method":"session/load","params":{"sessionId":"existing","cwd":directory,"mcpServers":[]}})+"\n")
                process.stdin.flush()
                # A live ACP controller keeps this pipe open across requests.
                process.wait(timeout=10)
                self.assertEqual(process.returncode, 0, process.stderr.read())
                request = json.loads(process.stdout.read())
                self.assertEqual(request["params"]["sessionId"], "existing")
                server = request["params"]["mcpServers"][0]
                self.assertEqual(server["name"], "sandboxed")
                credential = Path(server["args"][server["args"].index("--token-file") + 1])
                self.assertFalse(credential.exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                for stream in [process.stdin, process.stdout, process.stderr]:
                    stream.close()

    def test_standalone_launcher_exchanges_login_without_exposing_it(self):
        with core() as (url, state), tempfile.TemporaryDirectory() as directory:
            owner = Path(directory) / "owner-login"
            owner.write_text("owner-login")
            owner.chmod(0o600)
            cli = Path(directory) / "gemini"
            cli.write_text("""#!/usr/bin/env python3
import json, os, pathlib
config=pathlib.Path(os.environ['GEMINI_CLI_SYSTEM_SETTINGS_PATH'])
server=json.loads(config.read_text())['mcpServers']['sandboxed']
credential=pathlib.Path(server['args'][server['args'].index('--token-file')+1])
assert credential.read_text().strip() == 'mcp1.initial'
assert 'owner-login' not in json.dumps(server)
assert 'SANDBOXED_MCP_TOKEN' not in os.environ
assert 'SANDBOXED_MCP_TOKEN_FILE' not in os.environ
print(str(credential))
""")
            cli.chmod(0o700)
            env = {k: v for k, v in os.environ.items() if not k.startswith('SANDBOXED_MCP_')}
            result = subprocess.run([str(BINARY), "launch", "--harness", "gemini", "--api-url", url,
                                     "--token-file", str(owner), "--mission-id", MISSION, "--", str(cli)],
                                    capture_output=True, text=True, env=env, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(state["sessions"], 1)
            self.assertEqual(owner.read_text(), "owner-login")
            self.assertFalse(Path(result.stdout.strip()).exists())

    def test_scoped_renewal_survives_client_restart(self):
        with core(expiring=True) as (url, state), tempfile.TemporaryDirectory() as directory:
            credential = Path(directory) / "credential"
            credential.write_text("mcp1.initial")
            command = [str(BINARY), "--api-url", url, "--token-file", str(credential), "--profile", "executor", "--mission-id", MISSION, "--check"]
            for _ in range(2):
                result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["identity"]["mission_id"], MISSION)
            self.assertEqual(state["renewals"], 1)
            self.assertEqual(credential.stat().st_mode & 0o777, 0o600)

    def test_launcher_injects_only_scoped_private_config_and_cleans_it(self):
        with core() as (url, _), tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "claude"
            cli.write_text("""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
assert 'JWT_SECRET' not in os.environ
assert 'HERMES_SANDBOXED_API_TOKEN' not in os.environ
assert 'SANDBOXED_MCP_TOKEN' not in os.environ
settings=pathlib.Path(sys.argv[sys.argv.index('--mcp-config')+1])
server=json.loads(settings.read_text())['mcpServers']['sandboxed']
credential=pathlib.Path(server['args'][server['args'].index('--token-file')+1])
assert credential.stat().st_mode & 0o777 == 0o600
assert credential.read_text().startswith('mcp1.')
subprocess.run([server['command'], *server['args'], '--check'], check=True, stdout=subprocess.DEVNULL)
print(json.dumps({'settings':str(settings),'credential':str(credential)}))
""")
            cli.chmod(0o700)
            env = dict(os.environ, SANDBOXED_MCP_API_URL=url, SANDBOXED_MCP_TOKEN="mcp1.initial",
                       SANDBOXED_SH_MISSION_ID=MISSION, JWT_SECRET="fixture-owner-secret", HERMES_SANDBOXED_API_TOKEN="fixture-owner-login")
            result = subprocess.run([str(BINARY), "launch", "--harness", "claudecode", "--", str(cli)], env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            paths = json.loads(result.stdout)
            self.assertFalse(Path(paths["credential"]).exists())
            self.assertFalse(Path(paths["settings"]).exists())

    @unittest.skipUnless(os.name == "posix", "Unix process groups")
    def test_terminating_launcher_reaps_harness(self):
        with core() as (url, _), tempfile.TemporaryDirectory() as directory:
            cli, pidfile = Path(directory) / "claude", Path(directory) / "child.pid"
            cli.write_text("#!/usr/bin/env python3\nimport os,time,pathlib\npathlib.Path(os.environ['TEST_PID_FILE']).write_text(str(os.getpid()))\ntime.sleep(120)\n")
            cli.chmod(0o700)
            env = dict(os.environ, SANDBOXED_MCP_API_URL=url, SANDBOXED_MCP_TOKEN="mcp1.initial",
                       SANDBOXED_SH_MISSION_ID=MISSION, TEST_PID_FILE=str(pidfile))
            process = subprocess.Popen([str(BINARY), "launch", "--harness", "claudecode", "--", str(cli)], env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while not pidfile.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(pidfile.exists())
                pid = int(pidfile.read_text())
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=8)
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
