"""Bind an individual ACP decision to the subsequent start_mission MCP invocation."""
import json
import threading


class Delegation:
    def __init__(self, exchange):
        self.exchange = exchange
        self.lock = threading.Lock()
        self.pending = {}

    @staticmethod
    def key(args):
        return json.dumps(args, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

    def ask(self, args):
        reply = self.exchange({"action": "ask", "arguments": json.loads(self.key(args))})
        ticket = reply.get("ticket") if isinstance(reply, dict) else None
        if not isinstance(ticket, str) or not ticket:
            return False
        with self.lock:
            self.pending[self.key(args)] = ticket
        return True

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
        if method == "tools/call" and params.get("name") == "start_mission" and isinstance(params.get("arguments"), dict):
            args = params["arguments"]
            with self.lock:
                ticket = self.pending.pop(self.key(args), None)
            if ticket:
                result = self.exchange({"action": "dispatch", "arguments": json.loads(self.key(args)), "ticket": ticket})
                if isinstance(result, dict) and result.get("ok") is True:
                    return {**response, "result": {"content": [{"type": "text", "text": json.dumps(result["result"])}]}}
        return {**response, "error": {"code": -32602, "message": "No active permission for this operation"}}
