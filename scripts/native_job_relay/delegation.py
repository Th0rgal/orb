"""Bind an individual ACP decision to the subsequent start_mission MCP invocation."""
import json
import threading
import uuid


def child_args(args):
    if not isinstance(args, dict) or set(args) != {"mission_id"} or not isinstance(args["mission_id"], str):
        return False
    try:
        return str(uuid.UUID(args["mission_id"])) == args["mission_id"]
    except ValueError:
        return False


class Delegation:
    def __init__(self, exchange):
        self.exchange = exchange
        self.lock = threading.Lock()
        self.pending = {}

    @staticmethod
    def key(args):
        return json.dumps(args, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

    def ask(self, args, tool="start_mission"):
        request = {"action": "ask", "arguments": json.loads(self.key(args))}
        if tool == "write_file":
            request["tool"] = tool
        reply = self.exchange(request)
        ticket = reply.get("ticket") if isinstance(reply, dict) else None
        if not isinstance(ticket, str) or not ticket:
            return False
        with self.lock:
            self.pending[tool, self.key(args)] = ticket
        return True

    def consume(self, tool, args):
        with self.lock:
            return self.pending.pop((tool, self.key(args)), None)

    def write(self, file):
        args = {k: v for k, v in file.items() if k != "action"}
        ticket = self.consume("write_file", args)
        if ticket:
            return self.exchange({"action": "write_file", "arguments": json.loads(self.key(args)), "ticket": ticket})
        return None

    def respond(self, frame):
        if frame.get("jsonrpc") != "2.0" or "id" not in frame:
            return None
        method, params = frame.get("method"), frame.get("params", {})
        response = {"jsonrpc": "2.0", "id": frame["id"]}
        if method == "initialize":
            return {**response, "result": {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                                          "serverInfo": {"name": "sandboxed", "version": "1"}}}
        if method == "tools/list":
            allowed = self.exchange({"action": "catalog"})
            return {**response, "result": {"tools": allowed if isinstance(allowed, list) else []}}
        if method == "tools/call" and params.get("name") == "get_mission" and child_args(params.get("arguments")):
            result = self.exchange({"action": "get_mission", "arguments": params["arguments"]})
            if isinstance(result, dict):
                return {**response, "result": {"content": [{"type": "text", "text": json.dumps(result)}]}}
        if method == "tools/call" and params.get("name") == "start_mission" and isinstance(params.get("arguments"), dict):
            args = params["arguments"]
            ticket = self.consume("start_mission", args)
            if ticket:
                result = self.exchange({"action": "dispatch", "arguments": json.loads(self.key(args)), "ticket": ticket})
                if isinstance(result, dict) and result.get("ok") is True:
                    return {**response, "result": {"content": [{"type": "text", "text": json.dumps(result["result"])}]}}
        return {**response, "error": {"code": -32602, "message": "No active permission for this operation"}}
