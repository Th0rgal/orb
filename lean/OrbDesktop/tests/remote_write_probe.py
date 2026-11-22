"""Observe the remote job submission independently of Core's HTTP receipt."""
import contextlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sqlite3
import threading
import urllib.error


def observe_node(stack, env):
    submissions = []

    class Node(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, body):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            submissions.append(self.path)
            self.reply({"accepted": True})

        def do_GET(self):
            self.reply({"state": "running"})

    node = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Node))
    threading.Thread(target=node.serve_forever, daemon=True).start()
    stack.callback(node.shutdown)
    env.update(SANDBOXED_REMOTE_NODES_ENABLED="true",
               SANDBOXED_REMOTE_NODES=f"fixture=http://127.0.0.1:{node.server_port}|ORB_FIXTURE_NODE_TOKEN",
               ORB_FIXTURE_NODE_TOKEN="synthetic-node-token")
    return submissions


def check_remote_append(tmp, api, mid, submissions):
    with contextlib.closing(sqlite3.connect(next(tmp.rglob("missions.db")))) as db:
        for route in ("/api/control/message", f"/api/control/missions/{mid}/message"):
            key = f"remote-append-{len(submissions)}"
            body = {"mission_id": mid, "client_message_id": key, "content": "fixture"}
            db.execute("UPDATE missions SET tags=?,status='awaiting_user' WHERE id=?",
                       (json.dumps(["remote-node:fixture"]), mid))
            db.execute("CREATE TRIGGER refuse_event BEFORE INSERT ON mission_events WHEN NEW.event_type='user_message' "
                       "BEGIN SELECT RAISE(ABORT,'fixture storage failure'); END;")
            db.commit()
            prior = len(submissions)
            try:
                api(route, body)
            except urllib.error.HTTPError as error:
                assert error.code == 500 and json.load(error)["error"] == "message_append_failed"
            else:
                raise AssertionError("Core accepted the follow-up after its event write failed")
            assert len(submissions) == prior
            db.execute("DROP TRIGGER refuse_event")
            db.commit()
            api(route, body)
            assert len(submissions) == prior + 1
            count, = db.execute("SELECT count(*) FROM mission_events WHERE mission_id=? AND event_type='user_message' "
                                "AND json_extract(payload,'$.id')=?", (mid, key)).fetchone()
            assert count == 1


def check_scoped_queue_replay(tmp, api, mid, submissions, restart):
    route = f"/api/control/missions/{mid}/message"
    body = {"mission_id": mid, "client_message_id": "scoped-retry", "content": "fixture"}
    db_path = next(tmp.rglob("missions.db"))
    with contextlib.closing(sqlite3.connect(db_path)) as db:
        # The original worker cannot contact the replay observer on startup.
        db.execute("UPDATE missions SET tags=?,status='active' WHERE id=?", (json.dumps(["remote-node:queue-origin"]), mid))
        db.commit()
    first = api(route, body)
    assert first["queued"] and first["mission_id"] == mid

    def finish_original_turn():
        with contextlib.closing(sqlite3.connect(db_path)) as db:
            db.execute("UPDATE missions SET tags=?,status='awaiting_user' WHERE id=?", (json.dumps(["remote-node:fixture"]), mid))
            db.execute("DELETE FROM remote_message_queue WHERE mission_id=? AND message_id=?", (mid, body["client_message_id"]))
            db.commit()

    restart(finish_original_turn)
    assert api(route, body) == first
    assert not submissions
