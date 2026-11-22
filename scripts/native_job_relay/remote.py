"""Single-session workspace MCP attached to a private Core file callback."""
import contextlib
import json
import os
import socket
import threading


def definition(name):
    fields = {"path": {"type": "string", "description": "Relative to this mission workspace"}}
    if name == "write_file":
        fields["content"] = {"type": "string"}
    return {"name": name, "description": "Read a UTF-8 workspace file" if name == "read_file" else "Write a UTF-8 workspace file",
            "inputSchema": {"type": "object", "properties": fields, "required": list(fields), "additionalProperties": False}}


def respond(frame, tools, exchange):
    if frame.get("jsonrpc") != "2.0" or "id" not in frame:
        return None
    envelope = {"jsonrpc": "2.0", "id": frame["id"]}
    method = frame.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "workspace", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": list(tools.values())}
    elif method == "tools/call":
        params = frame.get("params", {})
        name, args = params.get("name"), params.get("arguments")
        if name not in tools or not isinstance(args, dict) or set(args) != set(tools[name]["inputSchema"]["required"]):
            return {**envelope, "error": {"code": -32602, "message": "Invalid workspace tool or arguments"}}
        data = exchange({"action": name, **args})
        error = not isinstance(data, dict) or ("content" if name == "read_file" else "size") not in data
        text = "Workspace operation unavailable" if error else data["content"] if name == "read_file" else f"Wrote {data['size']} bytes"
        result = {"content": [{"type": "text", "text": text}], "isError": error}
    else:
        return {**envelope, "error": {"code": -32601, "message": "Method unavailable"}}
    return {**envelope, "result": result}


def remote_socket(directory, uid, gid, readonly, exchange):
    tools = {name: definition(name) for name in (["read_file"] if readonly else ["read_file", "write_file"])}
    return rpc_socket(directory, "workspace.sock", uid, gid, lambda frame: respond(frame, tools, exchange))


@contextlib.contextmanager
def rpc_socket(directory, socket_name, uid, gid, handle):
    connected, failed, stop = threading.Event(), threading.Event(), threading.Event()
    path = os.path.join(directory, socket_name)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(path)
        os.chown(path, uid, gid)
        os.chmod(path, 0o600)
        server.listen(1)
        server.settimeout(.2)

        def serve():
            try:
                while not stop.is_set():
                    try:
                        peer, _ = server.accept()
                    except TimeoutError:
                        continue
                    with peer, peer.makefile("rwb") as stream:
                        connected.set()
                        while not stop.is_set():
                            line = stream.readline(2 * 1024 * 1024 + 1)
                            if not line:
                                break
                            if len(line) > 2 * 1024 * 1024 or not line.endswith(b"\n"):
                                raise ValueError("Workspace frame too large")
                            reply = handle(json.loads(line))
                            if reply is not None:
                                stream.write(json.dumps(reply).encode() + b"\n")
                                stream.flush()
            except (ValueError, OSError, TypeError, AttributeError):
                failed.set()

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        try:
            yield connected, failed
        finally:
            stop.set()
            worker.join(1)
            os.unlink(path)
