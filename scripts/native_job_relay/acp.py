"""Antigravity ACP on the private holder. Core owns consent and tool execution."""
import json
import uuid

from .delegation import child_args


def permission_choice(params, session, ask, ask_write=None):
    """Select one turn-local option. Core still authorizes the actual MCP call."""
    if not isinstance(params, dict) or params.get("sessionId") != session or not session:
        return None
    call = params.get("toolCall")
    raw = call.get("rawInput") if isinstance(call, dict) else None
    if not isinstance(raw, dict):
        return None
    options = params.get("options")
    if not isinstance(options, list):
        return None
    choices = [o.get("optionId") for o in options if isinstance(o, dict) and o.get("kind") == "allow_once"]
    if len(choices) != 1 or not isinstance(choices[0], str) or not choices[0]:
        return None
    if any(o.get("optionId") == choices[0] and o.get("kind") != "allow_once" for o in options if isinstance(o, dict)):
        return None
    args = raw.get("Arguments")
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            return None
    if not isinstance(args, dict):
        return None
    tool = raw.get("ServerName"), raw.get("ToolName")
    read = tool == ("workspace", "read_file") and set(args) == {"path"}
    write = tool == ("workspace", "write_file") and set(args) == {"path", "content"}
    if tool == ("sandboxed", "get_mission") and child_args(args):
        return choices[0]
    if read or write:
        path = args["path"]
        if isinstance(path, str) and 0 < len(path) <= 4096 and "\\" not in path and "\0" not in path and all(
                part not in ("", ".", "..") for part in path.split("/")):
            if read or (ask_write and isinstance(args["content"], str) and ask_write(args)):
                return choices[0]
    elif tool == ("sandboxed", "start_mission") and isinstance(args.get("prompt"), str) and ask(args):
        return choices[0]
    return None

def turn(child, packet, ask, emit, ask_write=None):
    """The outer supervisor bounds lifetime and kills the process on revocation."""
    session = ""
    next_id = 0
    saw_text = False
    denied = False

    def send(value):
        child.stdin.write(json.dumps({"jsonrpc": "2.0", **value}).encode() + b"\n")
        child.stdin.flush()

    def call(method, params):
        nonlocal next_id, saw_text, denied
        next_id += 1
        send({"id": next_id, "method": method, "params": params})
        while True:
            line = child.stdout.readline(1024 * 1024 + 1)
            if not line or len(line) > 1024 * 1024 or not line.endswith(b"\n"):
                raise RuntimeError("Native ACP connection closed")
            msg = json.loads(line)
            if msg.get("jsonrpc") != "2.0":
                raise ValueError("Invalid native ACP frame")
            if "method" not in msg:
                if msg.get("id") != next_id or "result" not in msg:
                    raise RuntimeError("Native ACP request failed")
                return msg["result"]
            request = msg.get("params", {})
            if "id" in msg:
                if msg["method"] != "session/request_permission":
                    send({"id": msg["id"], "error": {"code": -32601, "message": "Unavailable"}})
                    continue
                choice = permission_choice(request, session, ask, ask_write) if method == "session/prompt" else None
                outcome = {"outcome": "cancelled"}
                if choice is not None:
                    outcome = {"outcome": "selected", "optionId": choice}
                elif method == "session/prompt" and request.get("sessionId") == session:
                    denied = True
                send({"id": msg["id"], "result": {"outcome": outcome}})
            elif method == "session/prompt" and msg["method"] == "session/update" and request.get("sessionId") == session:
                update = request.get("update", {})
                content = update.get("content", {})
                if update.get("sessionUpdate") == "agent_message_chunk" and content.get("type") == "text":
                    saw_text = saw_text or bool(content["text"].strip())
                    emit({"event": "step_update", "step_update": {"step_type": "agent_response", "text_delta": content["text"]}})

    init = call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    if init.get("protocolVersion") != 1:
        raise RuntimeError("Native ACP protocol unavailable")
    conversation = packet.get("conversation")
    payload = {"cwd": "/session", "mcpServers": []}
    if conversation:
        session = str(uuid.UUID(conversation))
        if not init.get("agentCapabilities", {}).get("loadSession"):
            raise RuntimeError("Native ACP session resume unavailable")
        new = call("session/load", {**payload, "sessionId": session})
    else:
        new = call("session/new", payload)
        session = str(uuid.UUID(new["sessionId"]))
    model = packet["model"]
    models = new.get("models", {})
    if models.get("currentModelId") != model:
        offered = {row.get("modelId") for row in models.get("availableModels", [])}
        options = []
        for config in new.get("configOptions", []):
            if config.get("category") == "model" or config.get("id") == "model":
                options.extend(config.get("options", []))
        while options:
            row = options.pop()
            offered.add(row.get("value"))
            options.extend(row.get("options", []))
        if model not in offered:
            raise RuntimeError("Selected native ACP model unavailable")
        call("session/set_model", {"sessionId": session, "modelId": model})
    emit({"event": "init", "conversation_id": session})
    reply = call("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": packet["prompt"]}]})
    if reply.get("stopReason") != "end_turn":
        raise RuntimeError("Native ACP turn interrupted")
    if not saw_text:
        diagnostic = ("A tool permission was declined and Antigravity ended the turn without an assistant response."
                      if denied else "Antigravity ended the turn without an assistant response.")
        emit({"event": "result", "result": {"status": "FAILED", "error": diagnostic}})
        return
    emit({"event": "result", "result": {"status": "SUCCESS"}})
