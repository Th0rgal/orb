"""Trusted stdin/NDJSON entry point for a co-located development worker."""
import json
import os
from pathlib import Path
import pwd
import sys
import threading

# Installed under the root-owned private runtime; -I disables user imports.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_job_relay.holder import run


def main():
    runtime = Path(sys.argv[1])
    account = pwd.getpwnam(sys.argv[2])
    if account.pw_uid == 0 or account.pw_gid == 0:
        return 1
    try:
        # Leave the descriptor open after the packet. EOF signals Core cancellation.
        raw = sys.stdin.buffer.readline(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024 or not raw.endswith(b"\n"):
            return 1
        packet = json.loads(raw)
        lock = threading.Lock()

        def send(frame):
            line = json.dumps(frame, separators=(",", ":"))
            if packet["access_token"] in line:
                raise ValueError("credential present in native frame")
            with lock:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()

        def exchange(file):
            send({"file": file})
            line = sys.stdin.buffer.readline(2 * 1024 * 1024 + 1)
            if len(line) > 2 * 1024 * 1024 or not line.endswith(b"\n"):
                raise ValueError("invalid Core response")
            return json.loads(line)

        run(runtime, account.pw_uid, account.pw_gid, packet, sys.stdin.fileno(),
            lambda event: send({"agent": event}), exchange)
        return 0
    except (KeyError, ValueError, OSError, RuntimeError):
        print('{"agent":{"event":"error","message":"Native profile or bound workspace unavailable"}}', flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
