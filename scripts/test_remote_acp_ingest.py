"""Replay a delayed ACP log and legacy event sequences through a disposable Core."""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import tempfile
import threading
import time
from contextlib import ExitStack, closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

from test_native_owner_core import core


def chunk(update):
    return json.dumps({"method": "session/update", "params": {"update": update}}) + "\n"


def replay(binary, historical, fragments, measure_only):
    mission, job = str(uuid4()), str(uuid4())
    first = chunk({"sessionUpdate": "agent_thought_chunk", "content": {"text": "first"}})
    rest = "".join(chunk({"sessionUpdate": "agent_thought_chunk", "content": {"text": str(i)}})
                   for i in range(fragments))
    # OpenCode JSONL and ACP may coexist. The tool's own execution times must survive.
    rest += json.dumps({"type": "tool_use", "part": {"tool": "read", "id": "fixture",
                       "state": {"status": "completed", "time": {"start": 1234000, "end": 1235000}}}}) + "\n"
    log = (first + rest).encode()
    final_line = chunk({"sessionUpdate": "agent_message_chunk", "content": {"text": "done"}}).rstrip().encode()
    finished = threading.Event()
    final_at = []
    page_two_at = []
    first_request = []

    class Node(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            path = urlsplit(self.path)
            if path.path == f"/jobs/{job}/log":
                args = parse_qs(path.query)
                off = int(args["offset"][0])
                source = log + final_line if finished.is_set() else log
                stop = min(len(source), off + int(args["max_bytes"][0]))
                if off == 0:
                    first_request.append(time.monotonic())
                    stop = len(first)
                elif off == len(first):
                    time.sleep(1.1)  # Same Core drain, a later wall-clock second.
                    page_two_at.append(int(time.time()))
                elif off == len(log) and finished.is_set():
                    time.sleep(1.1)
                    final_at.append(int(time.time()))
                data = dict(offset=off, next_offset=stop, log_len=len(source), data=source[off:stop].decode())
            elif path.path == f"/jobs/{job}":
                finished.set()
                data = {"state": "succeeded", "exit_code": 0}
            else:
                data = {}
            wire = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(wire)))
            self.end_headers()
            self.wfile.write(wire)

    with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
        node = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Node))
        node_thread = threading.Thread(target=node.serve_forever, daemon=True)
        node_thread.start()
        stack.callback(node_thread.join)
        stack.callback(node.shutdown)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = dict(PATH=os.defpath, HOME=temp, WORKING_DIR=temp, PORT=str(port), HOST="127.0.0.1",
                   DEV_MODE="false", JWT_SECRET=secrets.token_hex(32), DASHBOARD_PASSWORD=secrets.token_hex(24),
                   SANDBOXED_REMOTE_NODES_ENABLED="true", ORB_QA_NODE_AUTH="fixture-only",
                   SANDBOXED_REMOTE_NODES=f"fixture=http://127.0.0.1:{node.server_port}|ORB_QA_NODE_AUTH")
        path = Path(temp) / ".sandboxed-sh/missions.db"
        path.parent.mkdir()
        with closing(sqlite3.connect(path)) as legacy_db:
            legacy_db.execute("CREATE TABLE mission_events(id INTEGER PRIMARY KEY AUTOINCREMENT, "
                              "mission_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_type TEXT NOT NULL, "
                              "timestamp TEXT NOT NULL, content TEXT)")
            legacy_db.executemany("INSERT INTO mission_events(mission_id,sequence,event_type,timestamp) "
                                  "VALUES(?,?,'legacy','')", ((mission, i) for i in range(1, historical + 1, 2)))
            legacy_db.commit()
        with core(binary, env):
            pass  # Let Core perform its normal schema migration before mixing event formats.
        with closing(sqlite3.connect(path)) as db:
            db.execute("INSERT INTO missions(id,status,backend,placement_job_id) VALUES(?,'active','opencode',?)",
                       (mission, job))
            db.execute("INSERT INTO mission_runs(id,mission_id,execution_state,remote_job_id,scope_unit) "
                       "VALUES(?,?,'running',?,'remote-node:fixture')", (str(uuid4()), mission, job))
            db.execute("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state) VALUES(?,?,'fixture','running')",
                       (job, mission))
            db.executemany("INSERT INTO mission_events(mission_id,seq,sequence,event_type,timestamp) "
                           "VALUES(?,?,0,'native','')", ((mission, i) for i in range(2, historical + 1, 2)))
            db.commit()
            with core(binary, env):
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    if db.execute("SELECT 1 FROM mission_events WHERE mission_id=? AND event_type='assistant_message'",
                                  (mission,)).fetchone():
                        break
                    time.sleep(.025)
                else:
                    raise TimeoutError("Core did not settle the remote log")
                elapsed = time.monotonic() - first_request[0]
                rows = db.execute("SELECT seq,sequence,event_type,unixepoch(created_at),payload FROM mission_events "
                                  "WHERE mission_id=? AND event_type IN ('thinking','tool_result') ORDER BY seq",
                                  (mission,)).fetchall()
                terminal = db.execute("SELECT event_type,unixepoch(created_at),seq FROM mission_events "
                                      "WHERE mission_id=? AND event_type IN ('text_delta','assistant_message') "
                                      "ORDER BY seq", (mission,)).fetchall()
            assert [row[0] for row in terminal] == ["text_delta", "assistant_message"]
            assert [row[2] for row in terminal] == [historical + fragments + 3, historical + fragments + 4]
            assert len(rows) == fragments + 2
            for index, (seq, legacy, kind, _, payload) in enumerate(rows):
                assert seq == legacy == historical + index + 1
                if kind == "thinking":
                    assert json.loads(payload)["content"] == ("first" if index == 0 else str(index - 1))
            tool = json.loads(rows[-1][-1])
            assert (tool["started_at"], tool["updated_at"]) == (1234000, 1235000)
            times = [r[3] for r in rows]
            times.extend(row[1] for row in terminal)
            fresh = min(times[1:]) >= page_two_at[0] and times[-2] >= final_at[0] and times == sorted(times)
            print(json.dumps(dict(history=historical, fragments=fragments, first_seq=rows[0][0],
                                  last_seq=terminal[-1][2], elapsed_seconds=round(elapsed, 3),
                                  fresh_timestamps=fresh)), flush=True)
            assert fresh or measure_only, "events obtained in the second HTTP page were stamped before its arrival"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--history", type=int, default=8000)
    parser.add_argument("--fragments", type=int, default=512)
    parser.add_argument("--measure-only", action="store_true", help="record timing on a pre-fix binary")
    args = parser.parse_args()
    replay(str(args.binary.resolve()), args.history, args.fragments, args.measure_only)
