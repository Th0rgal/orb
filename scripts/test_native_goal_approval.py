"""Offline ACP and MCP consent binding. No network, account or external subprocess."""
import io
import json
import sqlite3
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from native_job_relay.acp import permission_choice, turn
from native_job_relay.delegation import Delegation


def replay_current_goal():
    query = (Path(__file__).resolve().parents[1] / "lean/OrbCore/OrbCore/native_goal_placement.sql").read_text()
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE missions(id, placement_job_id, owner_user_id, goal_mode, status, run_generation INTEGER);
        CREATE TABLE remote_node_jobs(job_id, mission_id, state, payload_json);
        CREATE TABLE mission_runs(mission_id, remote_job_id, generation INTEGER, execution_state);
        INSERT INTO missions VALUES ('parent', NULL, 'ben', 1, 'active', 1);
    """)

    def matches(job, run, owner="ben"):
        return db.execute(query, ("parent", job, owner, str(run))).fetchall() == [(1,)]

    def accept(job, run, generation, claim):
        data = json.dumps({"goal_generation": generation, "goal_claim": claim})
        db.execute("INSERT INTO remote_node_jobs VALUES (?, 'parent', 'uncertain', ?)", (job, data))
        assert not matches(job, run)
        db.execute("UPDATE mission_runs SET execution_state='terminal'")
        db.execute("INSERT INTO mission_runs VALUES ('parent', ?, ?, 'running')", (job, run))
        db.execute("UPDATE missions SET placement_job_id=?, run_generation=?", (job, run))
        assert not matches(job, run)
        db.execute("UPDATE remote_node_jobs SET state='running' WHERE job_id=?", (job,))

    accept("initial", 1, 1, "")
    assert matches("initial", 1)
    accept("ordinary", 2, None, None)
    assert not matches("ordinary", 2) and not matches("initial", 1)
    for run in range(3, 7):
        job = f"continuation-{run}"
        accept(job, run, run - 1, f"claim-{run - 1}")
        assert matches(job, run) and not matches(job, run - 1)
        assert not matches(job, run, "other") and not matches("initial", run)
    for mutation in (
        "UPDATE mission_runs SET remote_job_id='other' WHERE generation=6",
        "UPDATE mission_runs SET execution_state='terminal' WHERE generation=6",
        "UPDATE mission_runs SET mission_id='other' WHERE generation=6",
        "UPDATE missions SET status='interrupted'",
        "UPDATE missions SET goal_mode=0",
        "UPDATE remote_node_jobs SET payload_json='{}'",
        "UPDATE remote_node_jobs SET payload_json=json_set(payload_json, '$.goal_generation', 7)",
        "UPDATE remote_node_jobs SET payload_json=json_set(payload_json, '$.goal_claim', NULL)",
    ):
        db.execute("SAVEPOINT current_job")
        db.execute(mutation)
        assert not matches(job, run), mutation
        db.execute("ROLLBACK TO current_job")
        db.execute("RELEASE current_job")
    db.close()


def replay_workspace_read():
    session = "025004a4-8502-4d30-b7b2-43f1da2f1490"
    model = "fixture"
    def run(args, text="", tool="read_file", same_session=True, options=None):
        raw = {"ServerName": "workspace", "ToolName": tool, "Arguments": args}
        updates = [
            {"id": 1, "result": {"protocolVersion": 1}},
            {"id": 2, "result": {"sessionId": session, "models": {"currentModelId": model}}},
            {"id": 17, "method": "session/request_permission", "params": {
                "sessionId": session if same_session else "other", "toolCall": {"rawInput": raw},
                "options": options if options is not None else [{"kind": "allow_once", "optionId": "one"}]}},
            {"method": "session/update", "params": {"sessionId": session, "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}},
            {"id": 3, "result": {"stopReason": "end_turn"}},
        ]
        wire = b"".join(json.dumps({"jsonrpc": "2.0", **msg}).encode() + b"\n" for msg in updates)
        child = SimpleNamespace(stdin=io.BytesIO(), stdout=io.BytesIO(wire))
        events = []
        asked = []
        turn(child, {"prompt": "fixture", "model": model}, asked.append, events.append)
        replies = [json.loads(line) for line in child.stdin.getvalue().splitlines()]
        assert not asked
        return next(r["result"]["outcome"] for r in replies if r["id"] == 17), events[-1]["result"]

    for args in ({"path": "notes/plan.md"}, '{"path":"notes/plan.md"}'):
        choice, result = run(args, "Read complete")
        assert choice == {"outcome": "selected", "optionId": "one"} and result["status"] == "SUCCESS"
    for args in ({"path": "/etc/passwd"}, {"path": "../file"}, {"path": "file", "content": "x"}, {}):
        choice, result = run(args)
        assert choice == {"outcome": "cancelled"} and result["status"] == "FAILED" and "declined" in result["error"]
    for extra in (dict(tool="write_file"), dict(same_session=False), dict(options=[]),
                  dict(options=[{"kind": "allow_always", "optionId": "always"}]),
                  dict(options=[{"kind": "allow_once", "optionId": "same"}, {"kind": "allow_always", "optionId": "same"}])):
        assert run({"path": "file"}, **extra)[0] == {"outcome": "cancelled"}
    assert run({"path": "file"}, "   ")[1] == {
        "status": "FAILED", "error": "Antigravity ended the turn without an assistant response."}


def replay_workspace_write(checkout):
    from native_job_relay.remote import definition, respond
    request = {"sessionId": "s", "toolCall": {"rawInput": {"ServerName": "workspace", "ToolName": "write_file",
               "Arguments": {"path": "summary.md", "content": "exact"}}},
               "options": [{"kind": "allow_once", "optionId": "once"}]}
    args = request["toolCall"]["rawInput"]["Arguments"]
    calls = []
    accepted = False
    def core_call(op):
        calls.append(op)
        if op["action"] == "ask":
            assert op["tool"] == "write_file" and op["arguments"] == args
            return {"ticket": "approved"} if accepted else None
        assert op == {"action": "write_file", "arguments": args, "ticket": "approved"}
        written = (checkout / args["path"]).write_bytes(args["content"].encode("utf-8"))
        return {"size": written}

    broker = Delegation(core_call)
    def request_once():
        return permission_choice(request, "s", lambda _: False, lambda a: broker.ask(a, "write_file"))
    def write(**override):
        frame = {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                 "params": {"name": "write_file", "arguments": {**args, **override}}}
        return respond(frame, {"write_file": definition("write_file")}, broker.write)["result"]
    assert write()["isError"] and not calls
    assert request_once() is None and write()["isError"]
    assert list(checkout.iterdir()) == []
    accepted = True
    assert request_once() == "once"
    assert write(path="other.md")["isError"] and write(content="different")["isError"]
    assert list(checkout.iterdir()) == []
    assert not write()["isError"] and write()["isError"]
    assert list(checkout.iterdir()) == [checkout / "summary.md"]
    assert (checkout / "summary.md").read_bytes() == b"exact"
    assert [c["action"] for c in calls] == ["ask", "ask", "write_file"]


def replay_child_result():
    from uuid import uuid4
    query = (Path(__file__).resolve().parents[1] / "lean/OrbCore/OrbCore/native_direct_child.sql").read_text()
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE missions(id TEXT PRIMARY KEY, parent_mission_id, owner_user_id, status, model_override);
        CREATE TABLE mission_events(id INTEGER PRIMARY KEY, mission_id, seq, sequence, event_type, payload);
    """)
    parent, child, peer, grandchild, foreign, missing = [str(uuid4()) for _ in range(6)]
    db.executemany("INSERT INTO missions VALUES(?,?,?,'awaiting_user','fixture-model')",
                   [(parent, None, "ben"), (child, parent, "ben"), (peer, None, "ben"),
                    (grandchild, child, "ben"), (foreign, parent, "other")])
    def event(seq, kind, payload):
        db.execute("INSERT INTO mission_events(mission_id,seq,sequence,event_type,payload) VALUES(?,?,0,?,?)",
                   (child, seq, kind, json.dumps(payload)))
    event(1, "user_message", {"content": "private prompt"})
    event(3, "assistant_message", {"content": "17", "access_token": "private token"})
    event(2, "user_message", {"content": "late insertion"})
    event(4, "tool_result", {"content": "private log"})
    def exchange(op):
        assert op["action"] == "get_mission"
        mid = op["arguments"]["mission_id"]
        row = db.execute(query, (parent, "ben", mid)).fetchone()
        return None if row is None else dict(status=row[0], model_override=row[1], final_response=row[2])
    broker = Delegation(exchange)
    def read(mid):
        return broker.respond({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                               "params": {"name": "get_mission", "arguments": {"mission_id": mid}}})
    assert json.loads(read(child)["result"]["content"][0]["text"]) == {
        "status": "awaiting_user", "model_override": "fixture-model", "final_response": "17"}
    denied = read(missing)
    for mid in (parent, peer, foreign, grandchild, "not-a-uuid"):
        assert read(mid) == denied and "error" in denied
    assert db.execute(query, (parent, "other", child)).fetchone() is None
    event(5, "user_message", {"content": "new prompt"})
    assert db.execute(query, (parent, "ben", child)).fetchone()[2] is None
    event(6, "assistant_message", {"content": "é" * 4096})
    assert len(db.execute(query, (parent, "ben", child)).fetchone()[2]) == 2049
    db.execute("UPDATE missions SET status='active' WHERE id=?", (child,))
    assert db.execute(query, (parent, "ben", child)).fetchone()[2] is None
    db.execute("UPDATE missions SET parent_mission_id=? WHERE id=?", (peer, child))
    assert read(child) == denied
    db.close()


def main():
    replay_child_result()
    replay_current_goal()
    replay_workspace_read()
    with TemporaryDirectory() as scratch:
        replay_workspace_write(Path(scratch))
    session = "s"
    args = {"title": "Proof", "backend": "codex", "model_override": "fixture", "prompt": "Reply OK"}
    request = {
        "sessionId": session,
        "toolCall": {"rawInput": {"ServerName": "sandboxed", "ToolName": "start_mission", "Arguments": args}},
        "options": [{"kind": "allow_always", "optionId": "always"}, {"kind": "allow_once", "optionId": "once"}],
    }
    assert permission_choice(request, session, lambda requested: requested == args) == "once"
    for key, value in (("ServerName", "other"), ("ToolName", "other"), ("Arguments", {})):
        bad = deepcopy(request)
        bad["toolCall"]["rawInput"][key] = value
        assert permission_choice(bad, session, lambda _: True) is None
    assert permission_choice(request, "different", lambda _: True) is None
    assert permission_choice({**request, "options": request["options"][:1]}, session, lambda _: True) is None

    dispatched = []
    decision = None

    def exchange(packet):
        if packet["action"] == "ask":
            return {"ticket": decision}
        assert packet["action"] == "dispatch" and packet["ticket"] == "once"
        dispatched.append(packet["arguments"])
        return {"ok": True, "result": {"accepted": True}}

    broker = Delegation(exchange)
    def attempt(params):
        return broker.respond({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                               "params": {"name": "start_mission", "arguments": params}})
    assert "error" in attempt(args)
    assert not broker.ask(args)
    assert "error" in attempt(args) and not dispatched
    decision = "once"
    assert broker.ask(args)
    assert "error" in attempt({**args, "model_override": "different"}) and not dispatched
    assert "result" in attempt(dict(reversed(list(args.items()))))
    assert "error" in attempt(args) and dispatched == [args]
    print("Session, server, tool, single-use choice and exact arguments accepted once; cancellation and replay refused.")


if __name__ == "__main__":
    main()
