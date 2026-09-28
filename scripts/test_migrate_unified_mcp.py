"""Cutover tests use HTTP and subprocess fixtures, never production state."""
import http.server
import json
from pathlib import Path
import tempfile
import threading
import unittest

from ruamel.yaml import YAML
from migrate_unified_mcp import migrate


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config.yaml"
        self.original = b"model: original-model\nmcp_servers:\n  sandboxed_assistant:\n    command: /old/assistant-mcp\n    env:\n      JWT_SECRET: old-secret\n  unrelated:\n    command: /other/tool\n"
        self.config.write_bytes(self.original)
        self.binary = self.root / "sandboxed-mcp"
        self.binary.write_text("""#!/usr/bin/env python3
import json, pathlib, sys
if '--print-catalog' in sys.argv:
    print(json.dumps([{'name':'get_action'}]))
else:
    token=pathlib.Path(sys.argv[sys.argv.index('--token-file')+1]).read_text()
    assert token == 'mcp1.fixture'
    sys.exit(1 if pathlib.Path(__file__).with_name('fail-check').exists() else 0)
""")
        self.binary.chmod(0o700)

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, body):
                data = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.path == "/api/mcp/session"
                assert self.headers["Authorization"] == "Bearer owner"
                assert body == {"role": "coordinator"}
                self.reply({"token": "mcp1.fixture"})

            def do_GET(self):
                assert self.path == "/api/mcp/capabilities"
                assert self.headers["Authorization"] == "Bearer mcp1.fixture"
                self.reply({"identity": {"role": "coordinator"}, "tools": [{"name": "get_action"}]})

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        def stop():
            self.server.shutdown()
            self.server.server_close()
            thread.join()
        self.addCleanup(stop)
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def test_cutover_preserves_other_servers_and_removes_owner_credentials(self):
        self.assertEqual(migrate(self.config, self.binary, self.url, "owner"), 1)
        config = YAML().load(self.config.read_text())
        self.assertEqual(config["model"], "original-model")
        self.assertEqual(config["mcp_servers"]["unrelated"]["command"], "/other/tool")
        server = config["mcp_servers"]["sandboxed_assistant"]
        self.assertEqual(server["command"], str(self.binary))
        self.assertEqual(server["tools"]["include"], ["get_action"])
        self.assertNotIn("JWT_SECRET", server["env"])
        credential = Path(server["env"]["SANDBOXED_MCP_TOKEN_FILE"])
        self.assertEqual(credential.read_text(), "mcp1.fixture")
        self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.with_name("config.yaml.pre-unified-mcp").read_bytes(), self.original)

    def test_failed_readiness_restores_config_and_existing_credential(self):
        (self.root / "fail-check").touch()
        credential = self.root / "mcp-credential"
        credential.write_text("previous-token")
        with self.assertRaisesRegex(RuntimeError, "readiness"):
            migrate(self.config, self.binary, self.url, "owner")
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(credential.read_text(), "previous-token")

    def test_failed_first_cutover_removes_new_credential(self):
        (self.root / "fail-check").touch()
        with self.assertRaises(RuntimeError):
            migrate(self.config, self.binary, self.url, "owner")
        self.assertFalse((self.root / "mcp-credential").exists())
        self.assertEqual(self.config.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
