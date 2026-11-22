"""Offline ACP and MCP consent binding. No network, account or external subprocess."""
from copy import deepcopy
from native_job_relay.acp import delegated_call
from native_job_relay.delegation import Delegation


def main():
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
