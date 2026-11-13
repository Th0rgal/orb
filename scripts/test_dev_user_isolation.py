import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("dev_isolation", Path(__file__).with_name("dev_user_isolation.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class DevProbeSafetyTests(unittest.TestCase):
    def test_shared_session_leaks_and_revocation_are_reported_without_bodies(self):
        class SharedApi:
            def __init__(self, leak):
                self.leak = leak
                self.missions = {}
                self.projects = {}
                self.shared = False
                self.disabled = False
                self.shared_tokens = set()

            def call(self, method, path, token="", body=None):
                if path == "/api/health":
                    return 200, {"build": "a" * 40}
                if path == "/api/admin/users":
                    if method == "POST":
                        return 201, {"id": "test-user"}
                    return 403, {}
                if path == "/api/auth/login":
                    return 200, {"token": "synthetic-member"}
                if path == "/api/admin/users/test-user":
                    self.disabled = True
                    return 200, {}
                if path == "/api/mcp/session":
                    shared = body["mission_id"] == self.admin_mid
                    bearer = ("shared-" if shared else "own-") + body["role"]
                    if shared:
                        self.shared_tokens.add(bearer)
                    return 200, {"token": bearer}
                if path == "/api/mcp/external-sessions":
                    return 200, {"token": "synthetic-external"}
                if path == "/api/projects":
                    if method == "PUT":
                        self.projects[(token, body["slug"])] = {**body, "status": "active"}
                    return 200, {}
                if path.startswith("/api/projects/"):
                    slug = path.split("/")[3]
                    if path.endswith("/status"):
                        return 404, {}
                    if len(path.split("/")) > 4:
                        return 403, {}
                    return 200, {"project": self.projects.get((token, slug), {})}
                if path == "/api/control/missions":
                    if method == "POST":
                        self.missions[body["id"]] = {**body, "status": "awaiting_user", "owner": token}
                        if token == "synthetic-admin":
                            self.admin_mid = body["id"]
                        return 201, body
                    return 200, []
                if path.startswith("/api/control/missions/"):
                    if "/shares" in path:
                        self.shared = method == "POST"
                        return (201 if self.shared else 200), {}
                    mission = self.missions.get(path.split("/")[4], {})
                    if mission.get("owner") != token:
                        return 404, {}
                    return 200, mission
                if path in {"/api/workspaces", "/api/managed-machines"}:
                    return 200, []
                return 403, {}

            def mcp(self, bearer, tool, arguments=None):
                arguments = arguments or {}
                if self.disabled:
                    return 401, {"error": "disabled"}
                if bearer in self.shared_tokens:
                    if tool == "get_mission" and self.shared:
                        return 200, {"ok": True}
                    if tool == self.leak and self.shared:
                        return 200, {"ok": True, "result": "sensitive-body-marker"}
                    if tool == "get_mission" and self.leak == "revocation":
                        return 200, {"ok": True, "result": "sensitive-body-marker"}
                elif tool == "get_budget" and not arguments:
                    return 200, {"ok": True, "result": {"spent_today_cents": 0}}
                elif tool == "get_mission" and arguments.get("mission_id") != self.admin_mid:
                    return 200, {"ok": True}
                return 200, {"ok": False}

        for leak in [None, "secret_list", "revocation"]:
            with self.subTest(leak=leak):
                output = io.StringIO()
                api = SharedApi(leak)
                with contextlib.redirect_stdout(output):
                    passed = probe.run(api, "synthetic-admin", "a" * 40)
                report = json.loads(output.getvalue())
                self.assertEqual(passed, leak is None)
                self.assertTrue(all(report["cleanup"].values()))
                self.assertEqual(len(api.shared_tokens), 3)
                self.assertTrue(any(row["case"].startswith("disabled_member_session_") for row in report["results"]))
                self.assertNotIn("sensitive-body-marker", output.getvalue())
                self.assertNotIn("synthetic-admin", output.getvalue())

    def test_only_exact_dev_targets(self):
        self.assertEqual(probe.dev_url("https://agent-backend-dev.thomas.md/"),
                         "https://agent-backend-dev.thomas.md")
        self.assertEqual(probe.dev_url("http://127.0.0.1:3002"), "http://127.0.0.1:3002")
        for url in ["https://orbcore.thomas.md", "http://127.0.0.1:3000", "http://localhost:3002",
                    "https://agent-backend-dev.thomas.md.evil.test", "https://agent-backend-dev.thomas.md@evil.test",
                    "https://agent-backend-dev.thomas.md/api", "http://agent-backend-dev.thomas.md"]:
            with self.subTest(url=url), self.assertRaises(probe.IsolationError):
                probe.Api(url)

    def test_private_file_and_no_symlinks(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "bearer"
            path.write_text("synthetic-test-bearer\n")
            path.chmod(0o600)
            self.assertEqual(probe.private_token(path), "synthetic-test-bearer")
            path.chmod(0o644)
            with self.assertRaises(probe.IsolationError):
                probe.private_token(path)
            path.chmod(0o600)
            link = Path(root) / "link"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                probe.private_token(link)

    def test_credential_redirects_are_disabled(self):
        self.assertIsNone(probe.NoRedirect().redirect_request(None, None, 302, "", {}, "https://orbcore.thomas.md"))

    def test_wrong_build_does_not_create_user(self):
        class WrongBuild:
            calls = []

            def call(self, method, path, *args, **kwargs):
                self.calls.append((method, path))
                return 200, {"build": "b" * 40}

        api = WrongBuild()
        with self.assertRaises(probe.IsolationError):
            probe.run(api, "synthetic-admin-bearer", "a" * 40)
        self.assertEqual(api.calls, [("GET", "/api/health")])

    def test_user_disabled_after_failure_and_no_sensitive_output(self):
        class FailedLogin:
            calls = []

            def call(self, method, path, *args, **kwargs):
                self.calls.append((method, path))
                if path == "/api/health":
                    return 200, {"build": "a" * 40}
                if path == "/api/admin/users":
                    self.created_password = args[1]["password"]
                    return 201, {"id": "test-user"}
                if path == "/api/auth/login":
                    return 500, {"error": "sensitive-response-marker"}
                if method == "PATCH" and path == "/api/admin/users/test-user":
                    return 200, {}
                raise AssertionError("unexpected request")

        api = FailedLogin()
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(probe.IsolationError):
            probe.run(api, "synthetic-admin-bearer", "a" * 40)
        report = output.getvalue()
        self.assertTrue(json.loads(report)["cleanup"]["user_disabled"])
        for value in [api.created_password, "synthetic-admin-bearer", "sensitive-response-marker"]:
            self.assertNotIn(value, report)
        self.assertIn(("PATCH", "/api/admin/users/test-user"), api.calls)


if __name__ == "__main__":
    unittest.main()
