"""Offline ACP and MCP consent binding. No network, account or external subprocess."""
import io
import json
import sqlite3
from copy import deepcopy
from pathlib import Path
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

    for args in ({"path": "docs/plan.md"}, '{"path":"docs/plan.md"}'):
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


def replay_workspace_write():
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
        return {"size": 5}

    broker = Delegation(core_call)
    def request_once():
        return permission_choice(request, "s", lambda _: False, lambda a: broker.ask(a, "write_file"))
    def write(**override):
        frame = {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                 "params": {"name": "write_file", "arguments": {**args, **override}}}
        return respond(frame, {"write_file": definition("write_file")}, broker.write)["result"]
    assert write()["isError"] and not calls
    assert request_once() is None and write()["isError"]
    accepted = True
    assert request_once() == "once"
    assert write(path="other.md")["isError"] and write(content="different")["isError"]
    assert not write()["isError"] and write()["isError"]
    assert [c["action"] for c in calls] == ["ask", "ask", "write_file"]


def main():
    replay_current_goal()
    replay_workspace_read()
    replay_workspace_write()
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
