"""Antigravity ACP on the private holder. Core owns consent and tool execution."""
import json
import uuid


def delegated_call(params, session):
    """Return only an explicit start_mission request for this ACP session."""
    if params.get("sessionId") != session:
        return None
    call = params.get("toolCall", {})
    raw = call.get("rawInput", {})
    if raw.get("ServerName") != "sandboxed" or raw.get("ToolName") != "start_mission":
        return None
    args = raw.get("Arguments")
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            return None
    if not isinstance(args, dict) or not isinstance(args.get("prompt"), str):
        return None
    choices = [option.get("optionId") for option in params.get("options", [])
               if option.get("kind") == "allow_once" and isinstance(option.get("optionId"), str)]
    if len(choices) != 1:
        return None
    return choices[0], args


def turn(child, packet, ask, emit):
    """The outer supervisor bounds lifetime and kills the process on revocation."""
    session = ""
    next_id = 0

    def send(value):
        child.stdin.write(json.dumps({"jsonrpc": "2.0", **value}).encode() + b"\n")
        child.stdin.flush()

    def call(method, params):
        nonlocal next_id
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
                candidate = delegated_call(request, session) if session else None
                outcome = {"outcome": "cancelled"}
                if candidate and ask(candidate[1]):
                    outcome = {"outcome": "selected", "optionId": candidate[0]}
                send({"id": msg["id"], "result": {"outcome": outcome}})
            elif msg["method"] == "session/update" and request.get("sessionId") == session:
                update = request.get("update", {})
                content = update.get("content", {})
                if update.get("sessionUpdate") == "agent_message_chunk" and content.get("type") == "text":
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
    emit({"event": "result", "result": {"status": "SUCCESS"}})
