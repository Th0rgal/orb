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
