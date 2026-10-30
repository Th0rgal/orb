#!/usr/bin/env python3
"""Provision and validate a scoped Hermes MCP session before replacing config.

Run after the new Core gateway and sandboxed-mcp binary are installed. No
service is restarted here: the operator rolls Hermes only after this succeeds.
The old binary is not used as a fallback. Credentials never appear in argv or
stdout. Requires ruamel.yaml, already installed with Hermes.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from ruamel.yaml import YAML


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(base: str, path: str, token: str, body=None):
    parsed = urllib.parse.urlsplit(base)
    if (parsed.scheme != "https" and not (
            parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "::1", "localhost"})):
        raise ValueError("Core requires HTTPS except on loopback")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Invalid Core URL")
    req = urllib.request.Request(base.rstrip("/") + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, ValueError) as error:
        # Do not include a response body: upstream errors may contain secrets.
        raise RuntimeError("Core MCP provisioning request failed") from None


def atomic_private(path: Path, data: bytes):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


MISSION_ONLY_TOOLS = {"schedule_wakeup", "schedule_job_wakeup"}


def migrate(config_path: Path, binary: Path, base: str, scoped_token: str):
    if not binary.is_absolute() or not binary.is_file():
        raise ValueError("An installed absolute sandboxed-mcp binary is required")
    if not scoped_token.startswith("mcp1."):
        raise ValueError(
            "Missionless coordinator cutover requires a pre-issued mcp1.* credential "
            "(mint via Orb Settings -> Security -> External MCP Sessions or adopt_hermes_assistant)"
        )
    # The exact installed build supplies its catalogue; no copied allowlist.
    catalog = subprocess.run([str(binary), "--profile", "coordinator", "--print-catalog"],
        capture_output=True, text=True, timeout=30, check=True)
    names = [tool["name"] for tool in json.loads(catalog.stdout)]
    original = config_path.read_bytes()
    yaml = YAML()
    yaml.preserve_quotes = True
    config = yaml.load(original) or {}
    servers = config.setdefault("mcp_servers", {})
    # A different custom server is not a legacy installation we own.
    for name, server in servers.items():
        command = Path(str(server.get("command", ""))).name
        if name != "sandboxed_assistant" and command in {
                "assistant-mcp", "assistant-mcp-dev", "orchestrator-mcp", "orchestrator-mcp-dev"}:
            raise ValueError("Remove the duplicate legacy MCP server in the reviewed configuration first")
    credential = config_path.parent / "mcp-credential"
    old_credential = credential.read_bytes() if credential.exists() else None
    token = scoped_token
    caps = request(base, "/api/mcp/capabilities", token)
    identity = caps.get("identity", {})
    cap_names = {tool["name"] for tool in caps.get("tools", [])}
    valid_catalog = (
        cap_names in (set(names), set(names) - MISSION_ONLY_TOOLS)
        if identity.get("mission_id")
        else cap_names == (set(names) - MISSION_ONLY_TOOLS)
    )
    if identity.get("role") != "coordinator" or not valid_catalog:
        raise RuntimeError("Core and installed MCP catalogue do not match")
    included = [name for name in names if name in cap_names]
    # Replace only this owned server, preserving other Hermes integrations.
    servers["sandboxed_assistant"] = {
        "command": str(binary), "args": ["--profile", "coordinator"], "timeout": 60,
        "env": {"SANDBOXED_MCP_API_URL": base, "SANDBOXED_MCP_TOKEN_FILE": str(credential)},
        "tools": {"include": included, "prompts": False, "resources": False},
    }
    output = io.StringIO()
    yaml.dump(config, output)
    backup = config_path.with_name(config_path.name + ".pre-unified-mcp")
    if not backup.exists():
        atomic_private(backup, original)
    try:
        atomic_private(credential, token.encode())
        # Validate the stdio client against the actual Core before switching.
        result = subprocess.run([str(binary), "--api-url", base, "--token-file", str(credential),
                                 "--profile", "coordinator", "--check"],
                                capture_output=True, timeout=40)
        if result.returncode:
            raise RuntimeError("Installed MCP failed its Core readiness check")
        atomic_private(config_path, output.getvalue().encode())
    except BaseException:
        atomic_private(config_path, original)
        if old_credential is None:
            credential.unlink(missing_ok=True)
        else:
            atomic_private(credential, old_credential)
        raise
    return len(included)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--mcp-token-file", "--owner-token-file", dest="mcp_token_file", required=True, type=Path)
    args = parser.parse_args()
    if args.mcp_token_file.stat().st_mode & 0o077:
        raise SystemExit("Scoped MCP credential file must be private")
    try:
        count = migrate(args.config.resolve(), args.binary, args.api_url,
                        args.mcp_token_file.read_text().strip())
    except Exception:
        raise SystemExit("MCP migration failed; configuration was not switched. Inspect readiness and retry.") from None
    print(f"Scoped coordinator MCP configured and verified ({count} tools). Restart Hermes to activate.")


if __name__ == "__main__":
    main()
