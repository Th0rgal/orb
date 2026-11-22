"""Run inside the member job. Only its one-use grant and normal harness events cross this boundary."""
import http.client
import json
import os
import sys
import time
from urllib.parse import urlsplit


def turn():
    base = urlsplit(os.environ["ORB_NATIVE_CORE"])
    if base.scheme != "https" or not base.hostname or base.username or base.password or base.query or base.fragment:
        return False
    # fd 3 points to the exact prompt materialized by the normal remote runner.
    with os.fdopen(3, "rb") as handle:
        raw = handle.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        return False
    job, owner, node, conversation = sys.argv[1:]
    payload = json.dumps(dict(job=job, owner=owner, node=node, prompt=raw.decode(),
                              conversation=conversation or None)).encode()
    headers = {"Content-Type": "application/json", "X-Orb-Job-Grant": os.environ.pop("ORB_NATIVE_ANTIGRAVITY_TOKEN")}
    deadline = time.monotonic() + 20
    while True:
        conn = http.client.HTTPSConnection(base.hostname, base.port, timeout=155)
        try:
            conn.request("POST", base.path.rstrip("/") + "/api/native/antigravity/workspace-turn", payload, headers)
            response = conn.getresponse()
            if response.status == 409 and time.monotonic() < deadline:
                # A real node job can start before Core receives its running state.
                time.sleep(.25)
                continue
            if response.status != 200:
                return False
            completed = False
            while line := response.readline(1024 * 1024 + 1):
                if len(line) > 1024 * 1024 or not line.endswith(b"\n"):
                    return False
                frame = json.loads(line)
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                if frame.get("event") == "result":
                    completed = frame.get("result", {}).get("status") == "SUCCESS"
            return completed
        finally:
            conn.close()


try:
    ok = turn()
except (KeyError, ValueError, OSError, http.client.HTTPException):
    ok = False
if not ok:
    print("The native account or its workspace connection is unavailable.", file=sys.stderr)
sys.exit(0 if ok else 1)
