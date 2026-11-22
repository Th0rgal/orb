"""Offline ACP and MCP consent binding. No network, account or external subprocess."""
import json
import sqlite3
from copy import deepcopy
from pathlib import Path
from native_job_relay.acp import delegated_call
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


def main():
    replay_current_goal()
    session = "s"
    args = {"title": "Proof", "backend": "codex", "model_override": "fixture", "prompt": "Reply OK"}
    request = {
        "sessionId": session,
        "toolCall": {"rawInput": {"ServerName": "sandboxed", "ToolName": "start_mission", "Arguments": args}},
        "options": [{"kind": "allow_always", "optionId": "always"}, {"kind": "allow_once", "optionId": "once"}],
    }
    assert delegated_call(request, session) == ("once", args)
    for key, value in (("ServerName", "other"), ("ToolName", "other"), ("Arguments", {})):
        bad = deepcopy(request)
        bad["toolCall"]["rawInput"][key] = value
        assert delegated_call(bad, session) is None
    assert delegated_call(request, "different") is None
    assert delegated_call({**request, "options": request["options"][:1]}, session) is None

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
