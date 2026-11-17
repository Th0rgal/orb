import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "ben_isolation_matrix",
    Path(__file__).with_name("ben_isolation_matrix.py"),
)
matrix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matrix)


class SyntheticCoreApi:
    """In-memory two-tenant REST + MCP fixture modeling Core's isolation gates."""

    def __init__(self, leak_surface=None):
        self.mode = "dev"
        self.url = "synthetic://core"
        self.leak_surface = leak_surface
        self.missions = {}
        self.projects = {}
        self.project_boards = {}
        self.project_files = {}
        self.shared = False
        self.disabled = False
        self.shared_tokens = set()
        self.admin_mid = None

    def call(self, method, path, token="", body=None):
        if path == "/api/health":
            return 200, {"build": "a" * 40}
        if path == "/api/auth/me":
            return 200, {"id": "ben-id", "username": "ben", "role": "member"}
        if path == "/api/admin/users":
            if method == "POST" and token == "synthetic-admin":
                return 201, {"id": "ben-user-id"}
            if self.leak_surface == "settings":
                return 200, [{"id": "admin", "secret": "sensitive-body-marker"}]
            return 403, {"error": "admin_required"}
        if path == "/api/admin/users/ben-user-id" and method == "PATCH":
            self.disabled = bool(body and body.get("disabled"))
            return 200, {}
        if path == "/api/auth/login":
            return 200, {"token": "synthetic-ben"}
        if path == "/api/mcp/session":
            is_shared = body["mission_id"] == self.admin_mid
            bearer = ("shared-" if is_shared else "own-") + body["role"]
            if is_shared:
                self.shared_tokens.add(bearer)
            return 200, {"token": bearer}

        # 1. Missions
        if path == "/api/control/missions":
            if method == "POST":
                if body.get("placement") == "core" and token != "synthetic-admin":
                    if self.leak_surface == "machines":
                        return 201, {"id": "leaked-core"}
                    return 403, {"error": "core_placement_forbidden"}
                self.missions[body["id"]] = {
                    **body,
                    "status": "awaiting_user",
                    "owner": token,
                    "owner_user_id": "admin" if token == "synthetic-admin" else "ben-user-id",
                }
                if token == "synthetic-admin":
                    self.admin_mid = body["id"]
                return 201, body
            rows = [
                m for m in self.missions.values()
                if m.get("owner") == token or (self.leak_surface == "missions")
            ]
            return 200, rows

        if path.startswith("/api/control/missions/search"):
            if self.leak_surface == "search":
                return 200, list(self.missions.values())
            return 200, [m for m in self.missions.values() if m.get("owner") == token]

        if path.startswith("/api/control/missions/"):
            parts = path.split("/")
            mid = parts[4]
            tail = "/" + "/".join(parts[5:]) if len(parts) > 5 else ""
            mission = self.missions.get(mid)
            if tail.startswith("/shares") and token == "synthetic-admin":
                self.shared = method == "POST"
                return (201 if self.shared else 200), {}
            if tail == "/inbox-digest":
                if not mission or mission.get("owner") != token:
                    if self.leak_surface == "Inbox":
                        return 200, {"digest": "sensitive-body-marker"}
                    return 404, {}
                return 200, {}
            if not mission or mission.get("owner") != token:
                if self.leak_surface == "missions":
                    return 200, mission or {"leaked": "sensitive-body-marker"}
                return 404, {}
            return 200, mission

        # 2. Projects & 3. Files
        if path == "/api/projects":
            if method == "PUT":
                self.projects[(token, body["slug"])] = {**body, "status": "active"}
                return 200, {"project": self.projects[(token, body["slug"])]}
            if self.leak_surface == "projects":
                return 200, [p for p in self.projects.values()]
            return 200, [p for (tok, _), p in self.projects.items() if tok == token]

        if path.startswith("/api/projects/"):
            parts = path.split("?")[0].split("/")
            slug = parts[3]
            tail = "/" + "/".join(parts[4:]) if len(parts) > 4 else ""
            owned = (token, slug) in self.projects
            if tail == "/board":
                if method == "PUT":
                    self.project_boards[(token, slug)] = body.get("text", "")
                    return 200, {}
                if not owned:
                    if self.leak_surface == "projects":
                        return 200, {"text": self.project_boards.get(("synthetic-admin", slug), "")}
                    return 404, {}
                return 200, {"text": self.project_boards.get((token, slug), "")}
            if tail in {"/files", "/file"}:
                if method == "PUT" and owned:
                    self.project_files[(token, slug, body["path"])] = body["content"]
                    return 200, {}
                if not owned:
                    if self.leak_surface == "files":
                        return 200, {"content": self.project_files.get(("synthetic-admin", slug, "secret.txt"), "leaked")}
                    return 404, {}
                return 200, {"files": []}
            if tail in {"/missions", "/controller"}:
                if not owned:
                    return 200, ([] if tail == "/missions" else {"job": None})
                return 200, []
            if method == "DELETE":
                self.projects.pop((token, slug), None)
                return 200, {}
            if not owned:
                if self.leak_surface == "projects":
                    return 200, {"project": self.projects.get(("synthetic-admin", slug), {})}
                return 404, {}
            return 200, {"project": self.projects[(token, slug)]}

        if path.startswith("/api/fs/"):
            if self.leak_surface == "files":
                return 200, {"entries": ["/root/.ssh"]}
            return 403, {"error": "forbidden"}

        if path.startswith("/api/library/"):
            return 200, {"skills": []}

        # 4. Secrets
        if path.startswith(("/api/secrets", "/api/bitwarden", "/api/privileged-access", "/api/approvals", "/api/control/auth/rotation")):
            if self.leak_surface == "secrets":
                return 200, {"secret": "sensitive-body-marker"}
            return 403, {"error": "admin_required"}

        # 5. Machines
        if path in {"/api/workspaces", "/api/managed-machines", "/api/nodes", "/api/control/client-computers"}:
            return 200, []
        if path.startswith(("/api/nodes/", "/api/remote/hosts", "/api/tether/")):
            if self.leak_surface == "machines":
                return 200, {"ok": True}
            return 403, {"error": "admin_required"}

        # 6. Settings
        if path == "/api/settings/library-remote" and method == "PUT":
            return 200, {"library_remote": (body or {}).get("library_remote")}
        if path.startswith(("/api/settings", "/api/system/", "/api/backups", "/api/integrations/")):
            if self.leak_surface == "settings":
                return 200, {"ok": True}
            return 403, {"error": "admin_required"}

        # 7. Inbox
        if path == "/api/control/inbox-state":
            if self.leak_surface == "Inbox":
                return 200, {"seen": {self.admin_mid: True}}
            return 200, {"seen": {}, "done": {}, "snoozed": {}, "preferences": {}}
        if path.startswith("/api/control/inbox-state/"):
            return 200, {"ok": True}

        # 9. Providers
        if path == "/api/ai/providers":
            if self.leak_surface == "providers":
                return 200, {"providers": [{"id": "p1", "api_key": "sk-secret", "account_email": "owner@example.com"}]}
            return 200, {
                "providers": [
                    {
                        "id": "anthropic-default",
                        "provider_type": "anthropic",
                        "name": "Anthropic 1",
                        "has_credentials": True,
                        "added_by_me": False,
                    }
                ]
            }
        if path.startswith(("/api/ai/", "/api/managed-machines/")):
            if self.leak_surface == "providers":
                return 200, {"ok": True}
            return 403, {"error": "not_account_owner"}

        return 403, {}

    def mcp(self, bearer, tool, arguments=None):
        arguments = arguments or {}
        if self.disabled:
            return 401, {"ok": False, "error": "disabled"}

        if bearer in self.shared_tokens:
            if tool == "get_mission" and self.shared:
                return 200, {"ok": True, "result": {"id": self.admin_mid}}
            return 200, {"ok": False, "error": "denied"}

        if tool == "get_budget":
            return 200, {"ok": True, "result": {"spent_today_cents": 0}}
        if tool == "get_mission":
            mid = arguments.get("mission_id")
            mission = self.missions.get(mid)
            if mission and mission.get("owner") == bearer:
                return 200, {"ok": True, "result": {"id": mid}}
            if self.leak_surface == "missions":
                return 200, {"ok": True, "result": {"id": mid, "leak": "sensitive-body-marker"}}
            return 200, {"ok": False, "error": "not_found"}
        if tool in {"list_missions", "list_projects", "list_managed_machines", "search_missions"}:
            if self.leak_surface == "search" and tool == "search_missions":
                return 200, {"ok": True, "result": list(self.missions.values())}
            return 200, {"ok": True, "result": []}
        return 200, {"ok": False, "error": "denied"}


class BenIsolationMatrixTests(unittest.TestCase):
    def test_all_nine_surfaces_covered_and_pass_on_clean_fixture(self):
        api = SyntheticCoreApi()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            passed = matrix.run_full_matrix(api, "synthetic-admin", "a" * 40)
        self.assertTrue(passed)
        report = json.loads(out.getvalue())
        self.assertEqual(set(report["surfaces"].keys()), set(matrix.SURFACES))
        for surface in matrix.SURFACES:
            self.assertGreater(report["surfaces"][surface]["total"], 0, f"missing surface {surface}")
            self.assertEqual(report["surfaces"][surface]["failed"], 0, f"failed surface {surface}")
        self.assertTrue(all(report["cleanup"].values()))
        self.assertNotIn("synthetic-admin", out.getvalue())
        self.assertNotIn("sensitive-body-marker", out.getvalue())

    def test_each_surface_leak_is_detected_without_emitting_sensitive_bodies(self):
        for surface in matrix.SURFACES:
            with self.subTest(surface=surface):
                api = SyntheticCoreApi(leak_surface=surface)
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    passed = matrix.run_full_matrix(api, "synthetic-admin", "a" * 40)
                self.assertFalse(passed, f"leak on {surface} was not caught")
                report = json.loads(out.getvalue())
                self.assertGreater(report["surfaces"][surface]["failed"], 0)
                self.assertNotIn("sensitive-body-marker", out.getvalue())
                self.assertNotIn("sk-secret", out.getvalue())

    def test_prod_readonly_mode_blocks_all_mutations_and_verifies_surfaces(self):
        api = SyntheticCoreApi()
        api.mode = "prod-readonly"
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            passed = matrix.run_prod_readonly(api, "synthetic-ben")
        self.assertTrue(passed)
        report = json.loads(out.getvalue())
        self.assertEqual(report["mode"], "prod-readonly")
        self.assertEqual(report["live_evidence"], "VERIFIED")
        for surface in matrix.SURFACES:
            self.assertGreater(report["surfaces"][surface]["total"], 0)
            self.assertEqual(report["surfaces"][surface]["failed"], 0)

    def test_prod_readonly_api_guard_rejects_mutating_http_and_mcp_calls(self):
        api = matrix.Api("https://orbcore.thomas.md/", mode="prod-readonly")
        for method, path, body in [
            ("POST", "/api/control/missions", {}),
            ("PUT", "/api/projects", {}),
            ("PATCH", "/api/settings", {}),
            ("DELETE", "/api/control/missions/123", None),
            ("POST", "/api/mcp/call", {"name": "start_mission", "arguments": {}}),
            ("POST", "/api/mcp/call", {"name": "secret_put", "arguments": {}}),
            ("POST", "/api/mcp/call", {"name": "write_project_file", "arguments": {}}),
        ]:
            with self.subTest(method=method, path=path, body=body):
                with self.assertRaises(matrix.IsolationError):
                    api.call(method, path, "tok", body)

    def test_url_validation_and_redirect_blocking(self):
        self.assertEqual(
            matrix.validate_url("https://orbcore.thomas.md/", mode="prod-readonly"),
            "https://orbcore.thomas.md",
        )
        self.assertEqual(
            matrix.validate_url("http://127.0.0.1:41234/", mode="dev"),
            "http://127.0.0.1:41234",
        )
        self.assertEqual(
            matrix.validate_url("https://orbcore.thomas.md/", mode="prod-full"),
            "https://orbcore.thomas.md",
        )
        with self.assertRaises(matrix.IsolationError):
            matrix.validate_url("https://agent-backend-dev.thomas.md", mode="prod-readonly")
        with self.assertRaises(matrix.IsolationError):
            matrix.validate_url("https://agent-backend-dev.thomas.md", mode="prod-full")
        with self.assertRaises(matrix.IsolationError):
            matrix.validate_url("https://orbcore.thomas.md", mode="dev")
        with self.assertRaises(matrix.IsolationError):
            matrix.validate_url("http://evil.example.com:3002", mode="dev")
        self.assertIsNone(
            matrix.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example.com")
        )

    def test_prod_full_requires_explicit_confirmation_and_exact_sha(self):
        with tempfile.TemporaryDirectory() as tmp:
            token_path = Path(tmp) / "admin.token"
            token_path.write_text("orb-jwt-v2-test\n", encoding="utf-8")
            token_path.chmod(0o600)
            base = ["--mode", "prod-full", "--token-file", str(token_path)]
            for extra in ([], ["--confirm-prod-mutations"]):
                with self.subTest(extra=extra):
                    out = io.StringIO()
                    with contextlib.redirect_stdout(out):
                        rc = matrix.main(base + extra)
                    self.assertEqual(rc, 2)
                    payload = json.loads(out.getvalue())
                    self.assertEqual(payload["live_evidence"], "ERROR")
                    self.assertIn("prod-full", payload["reason"])
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = matrix.main(base + ["--confirm-prod-mutations", "--sha", "a" * 39])
            self.assertEqual(rc, 2)
            self.assertEqual(json.loads(out.getvalue())["live_evidence"], "ERROR")

    def test_missing_token_file_reports_blocked_honestly(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = matrix.main(["--mode", "prod-readonly"])
        self.assertEqual(rc, 3)
        payload = json.loads(out.getvalue())
        self.assertEqual(payload["live_evidence"], "BLOCKED")
        self.assertEqual(payload["surfaces"], list(matrix.SURFACES))

    def test_private_token_enforces_permissions_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            token_path = Path(tmp) / "ben.token"
            token_path.write_text("orb-jwt-v2-test\n", encoding="utf-8")
            token_path.chmod(0o600)
            self.assertEqual(matrix.private_token(token_path), "orb-jwt-v2-test")
            token_path.chmod(0o644)
            with self.assertRaises(matrix.IsolationError):
                matrix.private_token(token_path)
            token_path.chmod(0o600)
            symlink_path = Path(tmp) / "link.token"
            symlink_path.symlink_to(token_path)
            with self.assertRaises(OSError):
                matrix.private_token(symlink_path)


if __name__ == "__main__":
    unittest.main()
