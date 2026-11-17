#!/usr/bin/env python3
"""M3: Scripted REST and MCP isolation matrix for member account `ben`.

Covers all nine required multi-user isolation surfaces across REST and MCP:
  1. missions
  2. projects
  3. files
  4. secrets
  5. machines
  6. settings
  7. Inbox
  8. search
  9. providers

Safety invariants:
- Never prints or logs tokens, passwords, secret values, or raw response bodies.
- Local/dev runs verify full two-actor (admin + `ben`) isolation against an
  explicit disposable or dev endpoint.
- `prod-readonly` walks production (`https://orbcore.thomas.md`) with an
  existing member bearer: non-GET/non-read requests are refused before network
  dispatch, and missing credentials report `BLOCKED` without claiming source
  tests prove prod.
- `prod-full` is the same two-actor matrix as `dev` against production. It is
  refused unless the caller also passes `--confirm-prod-mutations` and the
  exact 40-character `--sha`; the bearer must be an admin. It creates only
  zero-spend temporary fixtures, never touches an existing member, and removes
  every fixture in `finally`.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import stat
import urllib.error
import urllib.parse
import urllib.request
import uuid

SURFACES = (
    "missions",
    "projects",
    "files",
    "secrets",
    "machines",
    "settings",
    "Inbox",
    "search",
    "providers",
)

PROD_URL = "https://orbcore.thomas.md"
DEV_URLS = {
    "https://agent-backend-dev.thomas.md",
    "http://127.0.0.1:3002",
}

READONLY_MCP_TOOLS = {
    "get_capabilities",
    "get_budget",
    "list_missions",
    "get_mission",
    "get_mission_events",
    "get_mission_health",
    "get_mission_diagnostics",
    "list_mission_shared_files",
    "list_mission_access",
    "search_missions",
    "list_projects",
    "get_project",
    "get_project_board",
    "read_project_board",
    "list_project_files",
    "read_project_file",
    "secret_list",
    "list_privileged_access",
    "list_fleet_nodes",
    "get_fleet_node",
    "get_compute_fleet",
    "list_managed_vms",
    "list_managed_machines",
    "list_managed_snapshots",
    "list_macbook_tethers",
    "memory_get_knowledge_tree",
    "memory_search_knowledge",
    "memory_get_knowledge_page",
    "memory_recall",
    "list_cloud_accounts",
    "list_cloud_models",
}


class IsolationError(Exception):
    pass


def validate_url(value, mode="dev"):
    value = value.rstrip("/")
    if mode in ("prod-readonly", "prod-full"):
        if value != PROD_URL:
            raise IsolationError(mode + " mode only allows https://orbcore.thomas.md")
        return value
    if mode == "dev":
        if value in DEV_URLS:
            return value
        parsed = urllib.parse.urlparse(value)
        if (parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
                and parsed.port is not None and not parsed.path and not parsed.username):
            return value
        raise IsolationError("only explicit dev or local 127.0.0.1 endpoints are allowed")
    raise IsolationError("unknown mode")


def private_token(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.geteuid()
                or meta.st_mode & 0o077 or meta.st_size > 8192):
            raise IsolationError("bearer file must be owned by this user and private (0600)")
        value = os.read(fd, 8193).decode("utf-8").strip()
        if not value or len(value) > 8192 or any(c.isspace() for c in value):
            raise IsolationError("invalid bearer file")
        return value
    finally:
        os.close(fd)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class Api:
    def __init__(self, url, mode="dev"):
        self.mode = mode
        self.url = validate_url(url, mode=mode)
        self.opener = urllib.request.build_opener(NoRedirect)

    def call(self, method, path, token="", body=None):
        if not path.startswith("/api/") or "\r" in path or "\n" in path:
            raise IsolationError("invalid API path")
        if self.mode == "prod-readonly":
            if method == "GET":
                pass
            elif method == "POST" and path == "/api/mcp/call":
                tool = body.get("name", "") if isinstance(body, dict) else ""
                if tool not in READONLY_MCP_TOOLS:
                    raise IsolationError("non-readonly MCP tool refused in prod-readonly mode: " + str(tool))
            else:
                raise IsolationError("mutating HTTP method refused in prod-readonly mode: " + method + " " + path)
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            response = self.opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        except (OSError, ValueError) as error:
            raise IsolationError("API request failed: " + method + " " + path + " (" + type(error).__name__ + ")") from error
        with response:
            raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise IsolationError("response exceeded probe limit")
            try:
                doc = json.loads(raw)
            except (ValueError, UnicodeError):
                doc = None
            return response.code, doc

    def mcp(self, token, name, arguments=None):
        return self.call(
            "POST",
            "/api/mcp/call",
            token,
            {"name": name, "arguments": arguments or {}},
        )


def _no_markers(doc, markers):
    serialized = json.dumps(doc, sort_keys=True)
    return all(m not in serialized for m in markers if m)


def _mcp_denied(doc):
    return isinstance(doc, dict) and doc.get("ok") is False


def _mcp_ok(doc):
    return isinstance(doc, dict) and doc.get("ok") is True


def _providers_redacted(doc, admin_markers=()):
    if not _no_markers(doc, admin_markers):
        return False
    rows = doc.get("providers", []) if isinstance(doc, dict) else (doc if isinstance(doc, list) else [])
    if not isinstance(rows, list):
        return False
    for row in rows:
        if not isinstance(row, dict):
            continue
        for forbidden in ("api_key", "oauth", "refresh_token", "access_token", "proxy_auth_files"):
            if row.get(forbidden):
                return False
        if not row.get("added_by_me"):
            for private_field in ("account_email", "organization", "base_url", "google_project_id"):
                if row.get(private_field):
                    return False
    return True


def summarize_matrix(results):
    by_surface = {s: {"total": 0, "passed": 0, "failed": 0} for s in SURFACES}
    for row in results:
        surface = row["surface"]
        if surface not in by_surface:
            by_surface[surface] = {"total": 0, "passed": 0, "failed": 0}
        by_surface[surface]["total"] += 1
        if row["passed"]:
            by_surface[surface]["passed"] += 1
        else:
            by_surface[surface]["failed"] += 1
    return by_surface


def run_full_matrix(api, admin_token, expected_sha=None):
    status, health = api.call("GET", "/api/health")
    build = health.get("build", "") if isinstance(health, dict) else ""
    if expected_sha is not None:
        if status != 200 or not re.fullmatch(r"[0-9a-f]{9,40}", build) or not expected_sha.startswith(build):
            raise IsolationError("target is not running the expected commit")
    elif status != 200:
        raise IsolationError("target health check failed")

    suffix = secrets.token_hex(5)
    ben_username = "ben_" + suffix
    ben_password = secrets.token_urlsafe(32)
    admin_slug = "admin-proj-" + suffix
    ben_slug = "ben-proj-" + suffix
    admin_secret_marker = "admin-secret-marker-" + suffix
    admin_board_marker = "admin-board-marker-" + suffix
    admin_file_marker = "admin-file-marker-" + suffix
    admin_provider_marker = "admin-provider-marker-" + suffix
    admin_mid = str(uuid.uuid4())
    ben_mid = str(uuid.uuid4())

    ben_uid = ""
    ben_token = ""
    created_missions = []
    created_projects = []
    minted_sessions = []
    shared_sessions = []
    results = []
    cleanup = {
        "user_disabled": False,
        "missions_deleted": True,
        "projects_deleted": True,
    }

    markers = (
        admin_slug,
        admin_secret_marker,
        admin_board_marker,
        admin_file_marker,
        admin_provider_marker,
        admin_mid,
    )

    def expect(surface, case, response, allowed, predicate=lambda _doc: True):
        if surface not in SURFACES:
            raise IsolationError("unknown surface: " + str(surface))
        code, doc = response
        passed = (code in allowed) and bool(predicate(doc))
        results.append({
            "surface": surface,
            "case": case,
            "status": code,
            "passed": passed,
        })
        return passed

    try:
        status, user = api.call(
            "POST",
            "/api/admin/users",
            admin_token,
            {
                "username": ben_username,
                "password": ben_password,
                "role": "member",
                "daily_spend_cap_cents": 0,
            },
        )
        if status != 201 or not isinstance(user, dict) or not user.get("id"):
            raise IsolationError("could not create temporary ben member fixture")
        ben_uid = user["id"]

        status, login = api.call(
            "POST",
            "/api/auth/login",
            body={"username": ben_username, "password": ben_password},
        )
        if status != 200 or not isinstance(login, dict) or not login.get("token"):
            raise IsolationError("ben member fixture login failed")
        ben_token = login["token"]

        for bearer, slug, obj in [
            (admin_token, admin_slug, admin_secret_marker),
            (ben_token, ben_slug, "ben-objective-" + suffix),
        ]:
            resp = api.call("PUT", "/api/projects", bearer, {"slug": slug, "title": slug, "objective": obj})
            if resp[0] != 200:
                raise IsolationError("could not create project fixture")
            created_projects.append((bearer, slug))

        api.call("PUT", "/api/projects/" + admin_slug + "/board", admin_token, {"text": admin_board_marker})
        api.call(
            "PUT",
            "/api/projects/" + admin_slug + "/file",
            admin_token,
            {"path": "secret.txt", "content": admin_file_marker},
        )

        for bearer, mid, slug in [
            (admin_token, admin_mid, admin_slug),
            (ben_token, ben_mid, ben_slug),
        ]:
            resp = api.call(
                "POST",
                "/api/control/missions",
                bearer,
                {"id": mid, "title": slug, "project": slug, "placement": "client"},
            )
            if resp[0] != 201:
                raise IsolationError("could not create idle client mission fixture")
            created_missions.append((bearer, mid))

        # 1. MISSIONS (REST + MCP)
        expect("missions", "rest_own_mission_get", api.call("GET", "/api/control/missions/" + ben_mid, ben_token), {200})
        expect(
            "missions",
            "rest_mission_list_excludes_admin",
            api.call("GET", "/api/control/missions", ben_token),
            {200},
            lambda doc: _no_markers(doc, markers),
        )
        for method, tail, body in [
            ("GET", "", None),
            ("GET", "/events", None),
            ("GET", "/tree", None),
            ("GET", "/files", None),
            ("GET", "/shares", None),
            ("PATCH", "", {"title": "hijack"}),
            ("POST", "/message", {"content": "probe"}),
            ("POST", "/cancel", {}),
            ("POST", "/resume", {}),
            ("POST", "/pause", {}),
            ("POST", "/settings", {"title": "hijack"}),
            ("POST", "/project", {"project": ben_slug}),
            ("DELETE", "", None),
        ]:
            expect(
                "missions",
                "rest_foreign_mission_" + method + (tail.replace("/", "_") or "_root"),
                api.call(method, "/api/control/missions/" + admin_mid + tail, ben_token, body),
                {403, 404},
            )
        expect(
            "missions",
            "mcp_list_missions_excludes_admin",
            api.mcp(ben_token, "list_missions"),
            {200},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "missions",
            "mcp_own_mission_get",
            api.mcp(ben_token, "get_mission", {"mission_id": ben_mid}),
            {200},
            _mcp_ok,
        )
        foreign_args = {
            "mission_id": admin_mid,
            "content": "probe",
            "message": "probe",
            "prompt": "probe",
            "delay_seconds": 60,
            "project": ben_slug,
            "title": "hijack",
        }
        for tool in [
            "get_mission",
            "get_mission_events",
            "get_mission_health",
            "get_mission_diagnostics",
            "send_message_to_mission",
            "cancel_mission",
            "resume_mission",
            "update_mission_settings",
            "delete_mission",
            "move_mission",
            "schedule_wakeup",
        ]:
            expect(
                "missions",
                "mcp_foreign_" + tool,
                api.mcp(ben_token, tool, foreign_args),
                {200},
                _mcp_denied,
            )

        # 2. PROJECTS (REST + MCP)
        expect(
            "projects",
            "rest_projects_list_excludes_admin",
            api.call("GET", "/api/projects", ben_token),
            {200},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "projects",
            "rest_own_project_get",
            api.call("GET", "/api/projects/" + ben_slug, ben_token),
            {200},
        )
        expect(
            "projects",
            "rest_foreign_project_get_no_leak",
            api.call("GET", "/api/projects/" + admin_slug, ben_token),
            {200, 403, 404},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "projects",
            "rest_foreign_project_board_read_no_leak",
            api.call("GET", "/api/projects/" + admin_slug + "/board", ben_token),
            {200, 403, 404},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "projects",
            "rest_foreign_project_controller_no_leak",
            api.call("GET", "/api/projects/" + admin_slug + "/controller", ben_token),
            {200, 403, 404},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "projects",
            "mcp_list_projects_excludes_admin",
            api.mcp(ben_token, "list_projects"),
            {200},
            lambda doc: _no_markers(doc, markers),
        )
        for tool in [
            "get_project",
            "get_project_board",
            "read_project_board",
            "put_project_board",
            "write_project_board",
            "update_project_status",
            "delete_project",
            "ensure_project_controller",
            "poke_project_controller",
        ]:
            expect(
                "projects",
                "mcp_foreign_" + tool,
                api.mcp(ben_token, tool, {"project": admin_slug, "slug": admin_slug, "text": "hijack", "status": "archived"}),
                {200},
                lambda doc: _mcp_denied(doc) or _no_markers(doc, markers),
            )

        # 3. FILES (REST + MCP)
        expect(
            "files",
            "rest_foreign_project_files_list",
            api.call("GET", "/api/projects/" + admin_slug + "/files", ben_token),
            {200, 403, 404},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "files",
            "rest_foreign_project_file_read",
            api.call("GET", "/api/projects/" + admin_slug + "/file?path=secret.txt", ben_token),
            {403, 404},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "files",
            "rest_foreign_project_file_write",
            api.call("PUT", "/api/projects/" + admin_slug + "/file", ben_token, {"path": "pwn.txt", "content": "x"}),
            {403, 404},
        )
        expect(
            "files",
            "rest_host_fs_denied",
            api.call("GET", "/api/fs/list?path=/root", ben_token),
            {403, 404},
        )
        expect(
            "files",
            "rest_library_skill_delivery_scoped",
            api.call("GET", "/api/library/skills", ben_token),
            {200, 403, 404},
            lambda doc: _no_markers(doc, markers),
        )
        for tool in [
            "list_project_files",
            "read_project_file",
            "write_project_file",
            "create_project_folder",
            "transfer_project_file",
            "delete_project_file",
        ]:
            expect(
                "files",
                "mcp_foreign_" + tool,
                api.mcp(ben_token, tool, {"project": admin_slug, "path": "secret.txt", "content": "x"}),
                {200},
                lambda doc: _mcp_denied(doc) and _no_markers(doc, markers),
            )

        # 4. SECRETS (REST + MCP)
        for method, path, body in [
            ("GET", "/api/secrets", None),
            ("POST", "/api/secrets", {"name": "X", "value": "Y"}),
            ("GET", "/api/bitwarden/status", None),
            ("POST", "/api/bitwarden/unlock", {"password": "x"}),
            ("GET", "/api/privileged-access/requests", None),
            ("POST", "/api/privileged-access/requests", {"scope": "dev_operator"}),
            ("GET", "/api/approvals", None),
            ("POST", "/api/control/auth/rotation/rotate", {}),
        ]:
            expect(
                "secrets",
                "rest_owner_only_" + method + "_" + path.strip("/").replace("/", "_"),
                api.call(method, path, ben_token, body),
                {403, 404},
            )
        for tool, args in [
            ("secret_list", {}),
            ("secret_get", {"name": "OPENAI_API_KEY"}),
            ("secret_put", {"name": "X", "value": "Y", "bitwarden_project": "orb", "reason": "probe"}),
            ("secret_delete", {"name": "X", "reason": "probe"}),
            ("secret_move", {"name": "X", "bitwarden_project": "orb", "reason": "probe"}),
            ("secret_request", {"bitwarden_project": "all", "reason": "probe"}),
            ("list_privileged_access", {}),
            ("request_dev_access", {"reason": "probe"}),
            ("get_dev_access", {"grant_id": "fake"}),
            ("revoke_privileged_access", {"grant_id": "fake"}),
        ]:
            expect(
                "secrets",
                "mcp_owner_only_" + tool,
                api.mcp(ben_token, tool, args),
                {200},
                _mcp_denied,
            )

        # 5. MACHINES (REST + MCP)
        for path in [
            "/api/workspaces",
            "/api/managed-machines",
            "/api/nodes",
            "/api/control/client-computers",
        ]:
            expect(
                "machines",
                "rest_list_" + path.strip("/").replace("/", "_"),
                api.call("GET", path, ben_token),
                {200, 403},
                lambda doc: _no_markers(doc, markers),
            )
        for method, path, body in [
            ("POST", "/api/nodes/core/exec", {"command": "id"}),
            ("POST", "/api/remote/hosts", {"name": "evil"}),
            ("POST", "/api/tether/requests", {"scope": "host_ssh", "reason": "probe"}),
            ("POST", "/api/control/missions", {"title": "core-attempt", "placement": "core"}),
        ]:
            expect(
                "machines",
                "rest_denied_" + method + "_" + path.strip("/").replace("/", "_"),
                api.call(method, path, ben_token, body),
                {400, 403, 404},
            )
        for tool, args in [
            ("exec_on_host", {"node_id": "core", "command": "id"}),
            ("request_macbook_tether", {"reason": "probe"}),
            ("deploy_dev", {"grant_id": "fake", "sha": "a" * 40}),
            ("read_dev_logs", {"grant_id": "fake"}),
        ]:
            expect(
                "machines",
                "mcp_denied_" + tool,
                api.mcp(ben_token, tool, args),
                {200},
                _mcp_denied,
            )
        expect(
            "machines",
            "mcp_list_managed_machines_scoped",
            api.mcp(ben_token, "list_managed_machines"),
            {200},
            lambda doc: _no_markers(doc, markers),
        )

        # 6. SETTINGS (REST + MCP)
        for method, path, body in [
            ("GET", "/api/settings", None),
            ("PUT", "/api/settings", {"default_provider": "openai"}),
            ("PATCH", "/api/settings", {"default_provider": "openai"}),
            ("GET", "/api/admin/users", None),
            ("POST", "/api/admin/users", {"username": "x", "password": "y"}),
            ("POST", "/api/system/deploy", {"sha": "a" * 40}),
            ("GET", "/api/backups", None),
            ("GET", "/api/integrations/github/status", None),
        ]:
            expect(
                "settings",
                "rest_admin_only_" + method + "_" + path.strip("/").replace("/", "_"),
                api.call(method, path, ben_token, body),
                {400, 403, 404},
            )
        expect(
            "settings",
            "rest_member_library_remote_stays_scoped",
            api.call("PUT", "/api/settings/library-remote", ben_token, {"library_remote": "https://invalid.example/m3.git"}),
            {200, 400},
            lambda doc: _no_markers(doc, markers),
        )
        for tool, args in [
            ("memory_get_knowledge_tree", {}),
            ("memory_search_knowledge", {"query": "thomas"}),
            ("memory_get_knowledge_page", {"path": "index.md"}),
            ("memory_recall", {"query": "secret"}),
        ]:
            expect(
                "settings",
                "mcp_admin_only_" + tool,
                api.mcp(ben_token, tool, args),
                {200},
                _mcp_denied,
            )

        # 7. INBOX (REST + MCP)
        expect(
            "Inbox",
            "rest_inbox_state_scoped",
            api.call("GET", "/api/control/inbox-state", ben_token),
            {200},
            lambda doc: _no_markers(doc, markers),
        )
        expect(
            "Inbox",
            "rest_inbox_preferences_update_own",
            api.call(
                "PUT",
                "/api/control/inbox-state/preferences",
                ben_token,
                {
                    "clientId": "m3-matrix",
                    "mutationSeq": 1,
                    "expectedVersion": 0,
                    "aiSummary": True,
                    "includeAutonomous": False,
                    "model": "m3",
                    "inboxEnabled": True,
                },
            ),
            {200},
        )
        expect(
            "Inbox",
            "rest_foreign_mission_inbox_digest_denied",
            api.call("POST", "/api/control/missions/" + admin_mid + "/inbox-digest", ben_token, {}),
            {403, 404},
        )
        expect(
            "Inbox",
            "rest_foreign_mission_seen_does_not_leak",
            api.call(
                "PUT",
                "/api/control/inbox-state/seen/" + admin_mid,
                ben_token,
                {"clientId": "m3-matrix", "mutationSeq": 2, "expectedVersion": 1, "stamp": 9},
            ),
            {200, 403, 404},
            lambda doc: _no_markers(doc, markers),
        )

        # 8. SEARCH (REST + MCP)
        for path in [
            "/api/control/missions/search?q=" + urllib.parse.quote(admin_slug),
            "/api/control/missions/search/messages?q=" + urllib.parse.quote(admin_slug),
        ]:
            expect(
                "search",
                "rest_" + path.split("?")[0].strip("/").replace("/", "_"),
                api.call("GET", path, ben_token),
                {200},
                lambda doc: _no_markers(doc, markers),
            )
        expect(
            "search",
            "mcp_search_missions_excludes_admin",
            api.mcp(ben_token, "search_missions", {"query": admin_slug}),
            {200},
            lambda doc: _no_markers(doc, markers),
        )

        # 9. PROVIDERS (REST + MCP)
        expect(
            "providers",
            "rest_ai_providers_redacted",
            api.call("GET", "/api/ai/providers", ben_token),
            {200},
            lambda doc: _providers_redacted(doc, markers),
        )
        for method, path, body in [
            ("GET", "/api/ai/providers/audit", None),
            ("DELETE", "/api/ai/providers/anthropic-default", None),
            ("PUT", "/api/ai/providers/anthropic-default", {"api_key": "sk-hijack"}),
            ("PUT", "/api/ai/providers/anthropic-default", {"base_url": "http://127.0.0.1:9999"}),
            ("PUT", "/api/managed-machines/providers/boat", {}),
            ("PUT", "/api/managed-machines/settings", {}),
            ("POST", "/api/ai/routing/test", {}),
            ("POST", "/api/ai/health/default/clear", {}),
        ]:
            expect(
                "providers",
                "rest_provider_guard_" + method + "_" + path.strip("/").replace("/", "_"),
                api.call(method, path, ben_token, body),
                {400, 403, 404},
            )
        expect(
            "providers",
            "mcp_list_cloud_accounts_no_owner_leak",
            api.mcp(ben_token, "list_cloud_accounts"),
            {200},
            lambda doc: _mcp_denied(doc) or _no_markers(doc, markers),
        )
        expect(
            "providers",
            "mcp_member_budget_zero",
            api.mcp(ben_token, "get_budget"),
            {200},
            lambda doc: isinstance(doc, dict)
            and isinstance(doc.get("result"), dict)
            and doc["result"].get("spent_today_cents") == 0,
        )

        # Shared mission participant boundary + revocation check
        if expect(
            "missions",
            "rest_share_admin_mission_with_ben",
            api.call("POST", "/api/control/missions/" + admin_mid + "/shares", admin_token, {"username": ben_username}),
            {201},
        ):
            for role in ["executor", "coordinator", "operator"]:
                code, sess = api.call(
                    "POST",
                    "/api/mcp/session",
                    ben_token,
                    {"mission_id": admin_mid, "role": role},
                )
                if code != 200 or not isinstance(sess, dict) or not sess.get("token"):
                    raise IsolationError("shared member session mint failed")
                sb = sess["token"]
                minted_sessions.append(sb)
                shared_sessions.append(sb)
                expect(
                    "missions",
                    "mcp_shared_" + role + "_read_allowed",
                    api.mcp(sb, "get_mission", {"mission_id": admin_mid}),
                    {200},
                    _mcp_ok,
                )
                for surface, tool, targs in [
                    ("missions", "update_mission_settings", {"mission_id": admin_mid, "title": "hijack"}),
                    ("projects", "get_project", {"project": admin_slug}),
                    ("files", "read_project_file", {"project": admin_slug, "path": "secret.txt"}),
                    ("secrets", "secret_list", {}),
                    ("settings", "memory_get_knowledge_tree", {}),
                ]:
                    expect(
                        surface,
                        "mcp_shared_" + role + "_denied_" + tool,
                        api.mcp(sb, tool, targs),
                        {200},
                        _mcp_denied,
                    )
            expect(
                "missions",
                "rest_unshare_admin_mission",
                api.call("DELETE", "/api/control/missions/" + admin_mid + "/shares/" + ben_uid, admin_token),
                {200},
            )
            expect(
                "missions",
                "rest_revoked_share_denied",
                api.call("GET", "/api/control/missions/" + admin_mid, ben_token),
                {404},
            )
            for idx, sb in enumerate(shared_sessions):
                expect(
                    "missions",
                    "mcp_revoked_share_denied_" + str(idx),
                    api.mcp(sb, "get_mission", {"mission_id": admin_mid}),
                    {200, 401, 403},
                    lambda doc: not _mcp_ok(doc),
                )

        expect(
            "missions",
            "rest_admin_mission_intact",
            api.call("GET", "/api/control/missions/" + admin_mid, admin_token),
            {200},
            lambda doc: isinstance(doc, dict) and doc.get("title") == admin_slug,
        )
        expect(
            "projects",
            "rest_admin_project_intact",
            api.call("GET", "/api/projects/" + admin_slug, admin_token),
            {200},
            lambda doc: isinstance(doc, dict)
            and isinstance(doc.get("project"), dict)
            and doc["project"].get("objective") == admin_secret_marker,
        )
    finally:
        for bearer, mid in reversed(created_missions):
            try:
                code, _ = api.call("DELETE", "/api/control/missions/" + mid, bearer)
                cleanup["missions_deleted"] &= code in {200, 204, 404}
            except IsolationError:
                cleanup["missions_deleted"] = False
        for bearer, slug in reversed(created_projects):
            try:
                code, _ = api.call("DELETE", "/api/projects/" + slug, bearer)
                cleanup["projects_deleted"] &= code in {200, 204, 404}
            except IsolationError:
                cleanup["projects_deleted"] = False
        if ben_uid:
            try:
                code, _ = api.call("PATCH", "/api/admin/users/" + ben_uid, admin_token, {"disabled": True})
                cleanup["user_disabled"] = code == 200
                if cleanup["user_disabled"] and ben_token:
                    for idx, bearer in enumerate([ben_token] + minted_sessions):
                        expect(
                            "missions",
                            "disabled_session_revoked_" + str(idx),
                            api.mcp(bearer, "get_budget"),
                            {200, 401, 403},
                            lambda doc: not _mcp_ok(doc),
                        )
            except IsolationError:
                cleanup["user_disabled"] = False

    summary = summarize_matrix(results)
    report = {
        "mode": api.mode,
        "live_evidence": "VERIFIED",
        "target": api.url,
        "build": build,
        "surfaces": summary,
        "results": results,
        "cleanup": cleanup,
    }
    print(json.dumps(report))
    return (
        all(row["passed"] for row in results)
        and all(cleanup.values())
        and all(summary[s]["total"] > 0 and summary[s]["failed"] == 0 for s in SURFACES)
    )


def run_prod_readonly(api, ben_token, forbidden_markers=()):
    status, health = api.call("GET", "/api/health")
    build = health.get("build", "") if isinstance(health, dict) else ""
    if status != 200:
        raise IsolationError("prod health check failed")

    status, me = api.call("GET", "/api/auth/me", ben_token)
    if status != 200 or not isinstance(me, dict) or me.get("role") != "member":
        raise IsolationError("prod token is not an active member session")

    results = []
    probe_mission_id = "00000000-0000-0000-0000-000000000001"
    probe_project_slug = "orb"
    markers = tuple(forbidden_markers)

    def expect(surface, case, response, allowed, predicate=lambda _doc: True):
        code, doc = response
        passed = (code in allowed) and bool(predicate(doc))
        results.append({
            "surface": surface,
            "case": case,
            "status": code,
            "passed": passed,
        })
        return passed

    # 1. missions
    expect(
        "missions",
        "prod_rest_missions_list",
        api.call("GET", "/api/control/missions", ben_token),
        {200},
        lambda doc: _no_markers(doc, markers)
        and isinstance(doc, list)
        and all(isinstance(m, dict) and m.get("owner_user_id") != "admin" for m in doc),
    )
    expect(
        "missions",
        "prod_rest_unowned_mission_404",
        api.call("GET", "/api/control/missions/" + probe_mission_id, ben_token),
        {404},
    )
    expect(
        "missions",
        "prod_mcp_list_missions",
        api.mcp(ben_token, "list_missions"),
        {200},
        lambda doc: _no_markers(doc, markers),
    )
    expect(
        "missions",
        "prod_mcp_unowned_mission_denied",
        api.mcp(ben_token, "get_mission", {"mission_id": probe_mission_id}),
        {200},
        _mcp_denied,
    )

    # 2. projects
    expect(
        "projects",
        "prod_rest_projects_list",
        api.call("GET", "/api/projects", ben_token),
        {200},
        lambda doc: _no_markers(doc, markers),
    )
    expect(
        "projects",
        "prod_rest_foreign_project_board_isolated",
        api.call("GET", "/api/projects/" + probe_project_slug + "/board", ben_token),
        {200, 403, 404},
        lambda doc: _no_markers(doc, markers)
        and (not isinstance(doc, dict) or not doc.get("text")),
    )
    expect(
        "projects",
        "prod_mcp_foreign_project_denied",
        api.mcp(ben_token, "get_project", {"project": probe_project_slug}),
        {200},
        _mcp_denied,
    )

    # 3. files
    expect(
        "files",
        "prod_rest_foreign_project_files_isolated",
        api.call("GET", "/api/projects/" + probe_project_slug + "/files", ben_token),
        {200, 403, 404},
        lambda doc: _no_markers(doc, markers)
        and (not isinstance(doc, dict) or not doc.get("files")),
    )
    expect(
        "files",
        "prod_rest_host_fs_denied",
        api.call("GET", "/api/fs/list?path=/root", ben_token),
        {403, 404},
    )
    expect(
        "files",
        "prod_mcp_read_project_file_denied",
        api.mcp(ben_token, "read_project_file", {"project": probe_project_slug, "path": "README.md"}),
        {200},
        _mcp_denied,
    )

    # 4. secrets
    for path in ["/api/secrets", "/api/bitwarden/status", "/api/privileged-access/requests"]:
        expect(
            "secrets",
            "prod_rest_" + path.strip("/").replace("/", "_"),
            api.call("GET", path, ben_token),
            {403, 404},
        )
    for tool in ["secret_list", "list_privileged_access"]:
        expect(
            "secrets",
            "prod_mcp_" + tool,
            api.mcp(ben_token, tool),
            {200},
            _mcp_denied,
        )

    # 5. machines
    for path in ["/api/workspaces", "/api/managed-machines", "/api/nodes"]:
        expect(
            "machines",
            "prod_rest_" + path.strip("/").replace("/", "_"),
            api.call("GET", path, ben_token),
            {200, 403},
            lambda doc: _no_markers(doc, markers),
        )
    expect(
        "machines",
        "prod_mcp_list_managed_machines",
        api.mcp(ben_token, "list_managed_machines"),
        {200},
        lambda doc: _no_markers(doc, markers),
    )

    # 6. settings
    for path in ["/api/settings", "/api/admin/users", "/api/backups"]:
        expect(
            "settings",
            "prod_rest_" + path.strip("/").replace("/", "_"),
            api.call("GET", path, ben_token),
            {403, 404},
        )
    expect(
        "settings",
        "prod_mcp_memory_denied",
        api.mcp(ben_token, "memory_get_knowledge_tree"),
        {200},
        _mcp_denied,
    )

    # 7. Inbox
    expect(
        "Inbox",
        "prod_rest_inbox_state",
        api.call("GET", "/api/control/inbox-state", ben_token),
        {200},
        lambda doc: _no_markers(doc, markers),
    )

    # 8. search
    expect(
        "search",
        "prod_rest_missions_search",
        api.call("GET", "/api/control/missions/search?q=orb", ben_token),
        {200},
        lambda doc: _no_markers(doc, markers),
    )
    expect(
        "search",
        "prod_mcp_search_missions",
        api.mcp(ben_token, "search_missions", {"query": "orb"}),
        {200},
        lambda doc: _no_markers(doc, markers),
    )

    # 9. providers
    expect(
        "providers",
        "prod_rest_ai_providers_redacted",
        api.call("GET", "/api/ai/providers", ben_token),
        {200},
        lambda doc: _providers_redacted(doc, markers),
    )
    expect(
        "providers",
        "prod_rest_ai_providers_audit_denied",
        api.call("GET", "/api/ai/providers/audit", ben_token),
        {403, 404},
    )
    expect(
        "providers",
        "prod_mcp_budget_readable",
        api.mcp(ben_token, "get_budget"),
        {200},
        _mcp_ok,
    )

    summary = summarize_matrix(results)
    print(json.dumps({
        "mode": "prod-readonly",
        "live_evidence": "VERIFIED",
        "build": build,
        "surfaces": summary,
        "results": results,
    }))
    return (
        all(row["passed"] for row in results)
        and all(summary[s]["total"] > 0 and summary[s]["failed"] == 0 for s in SURFACES)
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["dev", "prod-readonly", "prod-full"], default="dev")
    parser.add_argument("--url", default="")
    parser.add_argument("--token-file", type=Path, default=None)
    parser.add_argument("--sha", default=None)
    parser.add_argument("--confirm-prod-mutations", action="store_true")
    args = parser.parse_args(argv)

    if args.mode in ("prod-readonly", "prod-full"):
        target_url = args.url or PROD_URL
    else:
        target_url = args.url or "https://agent-backend-dev.thomas.md"
    try:
        api = Api(target_url, mode=args.mode)
        if args.token_file is None:
            print(json.dumps({
                "mode": args.mode,
                "live_evidence": "BLOCKED",
                "reason": "governed bearer token-file not provided",
                "surfaces": list(SURFACES),
            }))
            return 3
        token = private_token(args.token_file)
        if args.mode == "prod-readonly":
            return 0 if run_prod_readonly(api, token) else 1
        if args.mode == "prod-full":
            if not args.confirm_prod_mutations:
                raise IsolationError("prod-full requires --confirm-prod-mutations")
            if args.sha is None:
                raise IsolationError("prod-full requires the exact 40-char --sha")
        if args.sha is not None and not re.fullmatch(r"[0-9a-f]{40}", args.sha):
            raise IsolationError("a full 40-char commit SHA is required when --sha is set")
        return 0 if run_full_matrix(api, token, expected_sha=args.sha) else 1
    except (IsolationError, OSError, UnicodeError) as error:
        print(json.dumps({
            "mode": args.mode,
            "live_evidence": "ERROR",
            "reason": str(error) if isinstance(error, IsolationError) else "credential file unavailable",
        }))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
