"""Verify the packaged native holder file catalog and its per-mode call admission."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def replay(binary, mode, expected):
    with tempfile.TemporaryDirectory() as tmp:
        frames = [
            {"id": 1, "method": "initialize", "params": {"rootUri": Path(tmp).as_uri()}},
            {"id": 2, "method": "tools/list", "params": {}},
            {"id": 3, "method": "tools/call", "params": {"name": "list_directory", "arguments": {"path": "."}}},
        ]
        if mode == "readonly":
            frames.append({"id": 4, "method": "tools/call",
                           "params": {"name": "write_file", "arguments": {"path": "unexpected", "content": "fixture"}}})
        request = "".join(json.dumps({"jsonrpc": "2.0", **frame}) + "\n" for frame in frames)
        run = subprocess.run([str(binary), "--bound-files", mode], input=request, capture_output=True,
                             cwd=tmp, env={"HOME": tmp, "SANDBOXED_SH_WORKSPACE": tmp}, check=True, timeout=5, text=True)
        responses = {message["id"]: message for message in map(json.loads, run.stdout.splitlines())}
        names = [t["name"] for t in responses[2]["result"]["tools"]]
        assert names == expected, (mode, names)
        assert responses[3]["error"]["code"] == -32602
        if mode == "readonly":
            assert responses[4]["error"]["code"] == -32602
            assert not (Path(tmp) / "unexpected").exists()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    binary = parser.parse_args().binary.resolve()
    replay(binary, "readonly", ["read_file"])
    replay(binary, "writer", ["read_file", "write_file"])
    print("Both native workspace modes expose and admit only their declared file tools.")
