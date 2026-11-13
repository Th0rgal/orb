#!/usr/bin/env python3
"""Exercise dev with a new zero-budget member; never emit credentials or bodies.

An operator-approved dev bearer is read from a private file. This tool does not
obtain credentials, rent machines, run harnesses, or contact production.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import stat
import urllib.error
import urllib.request
import uuid


class IsolationError(Exception):
    pass


def dev_url(value):
    value = value.rstrip("/")
    if value not in {"https://agent-backend-dev.thomas.md", "http://127.0.0.1:3002"}:
        raise IsolationError("only the explicit dev endpoints are allowed")
    return value


def private_token(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.geteuid() or
                meta.st_mode & 0o077 or meta.st_size > 8192):
            raise IsolationError("bearer file must be owned by this user and private")
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
    def __init__(self, url):
        self.url = dev_url(url)
        self.opener = urllib.request.build_opener(NoRedirect)

    def call(self, method, path, token="", body=None):
        if not path.startswith("/api/") or "\r" in path or "\n" in path:
            raise IsolationError("invalid API path")
        data = None if body is None else json.dumps(body).encode()
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            response = self.opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        except (OSError, ValueError) as error:
            raise IsolationError("dev request failed") from error
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
        return self.call("POST", "/api/mcp/call", token,
                         {"name": name, "arguments": arguments or {}})


def run(api, admin, expected_sha):
    status, health = api.call("GET", "/api/health")
    build = health.get("build", "") if isinstance(health, dict) else ""
    if status != 200 or not re.fullmatch(r"[0-9a-f]{9,40}", build) or not expected_sha.startswith(build):
        raise IsolationError("dev is not running the expected commit")
    suffix = secrets.token_hex(5)
    username = "isolation_" + suffix
    password = secrets.token_urlsafe(32)
    marker = "isolation-admin-" + suffix
    member_marker = "isolation-member-" + suffix
    project_objective = "private-project-objective-" + suffix
    admin_mid, member_mid = str(uuid.uuid4()), str(uuid.uuid4())
    uid, member = "", ""
    created = []
    projects = []
    results = []
    cleanup = {"user_disabled": False, "missions_deleted": True, "projects_deleted": True}

    def expect(case, response, allowed, predicate=lambda _doc: True):
        code, doc = response
        passed = code in allowed and predicate(doc)
        results.append({"case": case, "status": code, "passed": passed})
        return passed

    try:
        status, user = api.call("POST", "/api/admin/users", admin,
                               {"username": username, "password": password,
                                "role": "member", "daily_spend_cap_cents": 0})
        if status != 201 or not isinstance(user, dict) or not user.get("id"):
            raise IsolationError("could not create the temporary capped member")
        uid = user["id"]
        status, login = api.call("POST", "/api/auth/login", body={"username": username, "password": password})
        if status != 200 or not isinstance(login, dict) or not login.get("token"):
            raise IsolationError("temporary member login failed")
        member = login["token"]
        for bearer, slug in [(admin, marker), (member, member_marker)]:
            response = api.call("PUT", "/api/projects", bearer,
                                {"slug": slug, "title": slug, "objective": project_objective})
            if not expect("create_project_fixture", response, {200}):
                raise IsolationError("could not create a synthetic project fixture")
            projects.append((bearer, slug))
        for bearer, mid, title in [(admin, admin_mid, marker), (member, member_mid, member_marker)]:
            response = api.call("POST", "/api/control/missions", bearer,
                                {"id": mid, "title": title, "project": title, "placement": "client"})
            if not expect("create_idle_client_fixture", response, {201},
                          lambda doc: isinstance(doc, dict) and doc.get("id") == mid):
                raise IsolationError("could not create an inert mission fixture")
            created.append((bearer, mid))
        expect("own_mission_positive_control", api.call("GET", "/api/control/missions/" + member_mid, member), {200})
        for method, tail, body in [("GET", "", None), ("GET", "/events", None),
                                   ("PATCH", "", {"title": "isolation-attempt"}),
                                   ("POST", "/cancel", {}), ("DELETE", "", None)]:
            expect("foreign_mission_" + method + tail,
                   api.call(method, "/api/control/missions/" + admin_mid + tail, member, body), {404})
        for path in ["/api/control/missions", "/api/projects", "/api/workspaces", "/api/managed-machines"]:
            expect("member_list_" + path, api.call("GET", path, member), {200},
                   lambda doc: marker not in json.dumps(doc) and admin_mid not in json.dumps(doc))
        for path in ["/api/bitwarden/status", "/api/secrets", "/api/admin/users"]:
            expect("owner_only_" + path, api.call("GET", path, member), {403})
        for path in ["/api/managed-machines/providers/boat", "/api/managed-machines/settings"]:
            expect("provider_mutation_" + path, api.call("PUT", path, member, {}), {403})
        expect("own_project_positive_control", api.call("GET", "/api/projects/" + member_marker, member), {200},
               lambda doc: isinstance(doc, dict) and isinstance(doc.get("project"), dict)
               and doc["project"].get("objective") == project_objective)
        expect("foreign_project_read", api.call("GET", "/api/projects/" + marker, member), {200, 404},
               lambda doc: project_objective not in json.dumps(doc))
        # A foreign raw slug may name the member's own empty namespace. Verify
        # the owner's fixture afterwards instead of treating a 200 as authority.
        expect("foreign_project_mutation", api.call("POST", "/api/projects/" + marker + "/status", member,
                                                    {"status": "archived"}), {200, 403, 404})
        projects.append((member, marker))  # Remove any harmless namespaced alias created by that probe.
        for tail in ["controller", "crons", "crons/synthetic-absent-job"]:
            expect("owner_scheduler_" + tail, api.call("GET", "/api/projects/" + marker + "/" + tail, member), {403})
        foreign = {"mission_id": admin_mid, "message": "isolation probe", "prompt": "isolation probe",
                   "delay_seconds": 60, "role": "operator", "owner_user_id": "admin"}
        for role in [None, "executor", "coordinator", "operator"]:
            bearer = member
            if role:
                code, session = api.call("POST", "/api/mcp/session", member,
                                         {"mission_id": member_mid, "role": role})
                if code != 200 or not isinstance(session, dict) or not session.get("token"):
                    raise IsolationError("member scoped-session mint failed")
                bearer = session["token"]
            for tool in ["get_mission", "get_mission_events", "get_budget", "send_message_to_mission",
                         "cancel_mission", "resume_mission", "schedule_wakeup"]:
                expect("mcp_" + (role or "dashboard") + "_" + tool, api.mcp(bearer, tool, foreign), {200},
                       lambda doc: isinstance(doc, dict) and doc.get("ok") is False)
            for tool in ["get_project", "update_project_status", "add_project_steer"]:
                expect("mcp_" + (role or "dashboard") + "_" + tool,
                       api.mcp(bearer, tool, {"project": marker, "status": "archived", "body": "isolation probe"}), {200},
                       lambda doc: isinstance(doc, dict) and doc.get("ok") is False)
        code, external = api.call("POST", "/api/mcp/external-sessions", member, {"role": "coordinator"})
        if code != 200 or not isinstance(external, dict) or not external.get("token"):
            raise IsolationError("member external-session mint failed")
        external_bearer = external["token"]
        expect("external_own_mission_positive_control",
               api.mcp(external_bearer, "get_mission", {"mission_id": member_mid}), {200},
               lambda doc: isinstance(doc, dict) and doc.get("ok") is True)
        for tool in ["get_mission", "get_mission_events", "get_budget", "cancel_mission", "schedule_wakeup"]:
            expect("mcp_external_" + tool, api.mcp(external_bearer, tool, foreign), {200},
                   lambda doc: isinstance(doc, dict) and doc.get("ok") is False)
        expect("member_usage_is_zero", api.mcp(member, "get_budget"), {200},
               lambda doc: isinstance(doc, dict) and isinstance(doc.get("result"), dict)
               and doc["result"].get("spent_today_cents") == 0)
        for tool in ["secret_list", "list_privileged_access", "memory_get_knowledge_tree"]:
            expect("mcp_owner_only_" + tool, api.mcp(member, tool), {200},
                   lambda doc: isinstance(doc, dict) and doc.get("ok") is False)
        expect("owner_fixture_unchanged", api.call("GET", "/api/control/missions/" + admin_mid, admin), {200},
               lambda doc: isinstance(doc, dict) and doc.get("title") == marker and doc.get("status") == "awaiting_user")
        expect("owner_project_unchanged", api.call("GET", "/api/projects/" + marker, admin), {200},
               lambda doc: isinstance(doc, dict) and isinstance(doc.get("project"), dict)
               and doc["project"].get("objective") == project_objective and doc["project"].get("status") == "active")
    finally:
        for bearer, mid in reversed(created):
            try:
                code, _ = api.call("DELETE", "/api/control/missions/" + mid, bearer)
                cleanup["missions_deleted"] &= code in {200, 204, 404}
            except IsolationError:
                cleanup["missions_deleted"] = False
        for bearer, slug in reversed(projects):
            try:
                code, _ = api.call("DELETE", "/api/projects/" + slug, bearer)
                cleanup["projects_deleted"] &= code in {200, 204, 404}
            except IsolationError:
                cleanup["projects_deleted"] = False
        if uid:
            try:
                code, _ = api.call("PATCH", "/api/admin/users/" + uid, admin, {"disabled": True})
                cleanup["user_disabled"] = code == 200
            except IsolationError:
                pass
        # No response bodies, passwords, tokens, transcripts or provider values.
        print(json.dumps({"build": build, "results": results, "cleanup": cleanup,
                          "coverage_pending": ["live machine lifecycle", "desktop", "shared mission sessions"]}))
    return all(row["passed"] for row in results) and all(cleanup.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://agent-backend-dev.thomas.md")
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
            raise IsolationError("a full tested commit SHA is required")
        api = Api(args.url)  # Validate dev before reading any credential.
        return 0 if run(api, private_token(args.token_file), args.sha) else 1
    except (IsolationError, OSError, UnicodeError) as error:
        print("isolation probe failed: " + (str(error) if isinstance(error, IsolationError) else "local credential file unavailable"))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
