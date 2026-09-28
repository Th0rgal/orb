#!/usr/bin/env python3
"""Apply the Hermes-side reliability boundary without rewriting secrets."""

from __future__ import annotations

import argparse
import os
import shutil
import tempfile
from pathlib import Path

from ruamel.yaml import YAML


def coordinator_tools(binary: str) -> list[str]:
    """The installed binary owns the catalogue, including its permission profile."""
    import json
    import subprocess
    result = subprocess.run(
        [binary, "--profile", "coordinator", "--print-catalog"],
        check=True, capture_output=True, text=True, timeout=30,
    )
    return [tool["name"] for tool in json.loads(result.stdout)]


def configure(config: dict, mcp_binary: str, credential_file: Path) -> None:
    config.setdefault("kanban", {}).update(
        {
            "dispatch_in_gateway": False,
            "auto_decompose": False,
            "auto_decompose_per_tick": 0,
        }
    )
    server = config.setdefault("mcp_servers", {}).setdefault("sandboxed_assistant", {})
    server["command"] = mcp_binary
    server_env = server.setdefault("env", {})
    for key in ("JWT_SECRET", "HERMES_SANDBOXED_API_TOKEN", "SANDBOXED_API_TOKEN", "API_TOKEN"):
        server_env.pop(key, None)
    server_env["SANDBOXED_MCP_TOKEN_FILE"] = str(credential_file)
    # Mutations return durable receipts; long work runs on Core.
    server["timeout"] = 60
    server["args"] = ["--profile", "coordinator"]
    tools = server.setdefault("tools", {})
    tools["include"] = coordinator_tools(mcp_binary)
    tools["prompts"] = False
    tools["resources"] = False

    # Proton currently fails its production startup self-test because its
    # optional Python dependencies are not installed. Keep it explicitly
    # disabled until that probe passes instead of paying the failure cost on
    # every gateway start.
    plugins = config.setdefault("plugins", {})
    enabled = plugins.setdefault("enabled", [])
    disabled = plugins.setdefault("disabled", [])
    plugins["enabled"] = [name for name in enabled if name != "proton-platform"]
    if "proton-platform" not in disabled:
        disabled.append("proton-platform")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--mcp-binary", required=True)
    parser.add_argument("--credential-file", type=Path, required=True)
    args = parser.parse_args()

    if not args.credential_file.is_absolute() or not args.credential_file.is_file():
        raise SystemExit("A provisioned absolute scoped credential file is required")
    if not args.credential_file.read_text().strip().startswith("mcp1."):
        raise SystemExit("Credential file must contain a scoped MCP session")
    if args.credential_file.stat().st_mode & 0o077:
        raise SystemExit("Scoped credential file must not be readable by other users")
    path = args.home / "config.yaml"
    if not path.is_file():
        raise SystemExit(f"Hermes config not found: {path}")
    backup = path.with_name(f"{path.name}.pre-reliability")
    if not backup.exists():
        shutil.copy2(path, backup)

    yaml = YAML()
    yaml.preserve_quotes = True
    with path.open() as stream:
        config = yaml.load(stream) or {}
    configure(config, args.mcp_binary, args.credential_file)

    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as stream:
        temp = Path(stream.name)
        yaml.dump(config, stream)
    os.chmod(temp, mode)
    os.replace(temp, path)

    print(
        f"Configured {path}: native Kanban disabled, "
        f"sandboxed-MCP timeout=60s, tools={len(coordinator_tools(args.mcp_binary))}, "
        "Proton disabled"
    )


if __name__ == "__main__":
    main()
