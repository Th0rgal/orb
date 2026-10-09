"""Vibe ACP transport used by Core, nodes and Orb. Python standard library only.

The native session is journalled before a prompt can execute. --ack additionally
requires the parent to persist that identity before admitting the prompt.
No model output or stderr can substitute for an ACP prompt result.
"""
import argparse
import fcntl
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile


def emit(kind, **values):
    print(json.dumps(dict(type=kind, **values)), flush=True)


def save(path, value):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(args):
    cwd = str(Path.cwd().resolve())
    args.mission = os.environ.get("SANDBOXED_SH_MISSION_ID", args.mission)
    if args.prompt == "/plan" or args.prompt.startswith("/plan ") or args.prompt.startswith("/plan\n"):
        args.mode = "plan"
        args.prompt = args.prompt[5:].strip()
    root = Path.home() / ".local/state/sandboxed-vibe"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = hashlib.sha256((cwd + "\0" + args.mission).encode()).hexdigest()
    lock = (root / (key + ".lock")).open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    journal = root / (key + ".json")
    previous = json.loads(journal.read_text()) if journal.exists() else {}
    session = args.resume or previous.get("session")
    if args.resume and previous.get("session") not in (None, args.resume):
        raise RuntimeError("Vibe native identity differs from the mission journal")
    if previous and not session:
        raise RuntimeError("Vibe has an unresolved launch; reconcile its native session before retrying")

    env = dict(os.environ)
    if env.get("SANDBOXED_VIBE_PROXY_URL") and not args.model:
        args.model = "mistral/mistral-vibe-cli-latest"
    # Environment configuration takes precedence without rewriting native auth.
    if args.model:
        model = args.model if env.get("SANDBOXED_VIBE_PROXY_URL") else args.model.removeprefix("mistral/")
        provider = "sandboxed" if env.get("SANDBOXED_VIBE_PROXY_URL") else "mistral"
        env["VIBE_MODELS"] = json.dumps([dict(name=model, alias="sandboxed-selected", provider=provider)])
        env["VIBE_ACTIVE_MODEL"] = "sandboxed-selected"
    if env.get("SANDBOXED_VIBE_PROXY_URL"):
        env["VIBE_PROVIDERS"] = json.dumps([dict(
            name="sandboxed", api_base=env["SANDBOXED_VIBE_PROXY_URL"],
            api_key_env_var="SANDBOXED_VIBE_PROXY_KEY", backend="generic")])
        # Vibe 2.19 bootstraps then migrates its default config before applying
        # env overrides. Seed a private proxy config so that migration never
        # requires (or writes to) the execution user's native Mistral account.
        home = root / (key + ".vibe")
        home.mkdir(exist_ok=True, mode=0o700)
        env["VIBE_HOME"] = str(home)
        config = home / "config.toml"
        config.write_text(
            'active_model = "sandboxed-selected"\n'
            '[[providers]]\nname = "sandboxed"\nbackend = "generic"\n'
            'api_key_env_var = "SANDBOXED_VIBE_PROXY_KEY"\napi_base = '
            + json.dumps(env["SANDBOXED_VIBE_PROXY_URL"]) + '\n'
            '[[models]]\nprovider = "sandboxed"\nalias = "sandboxed-selected"\nname = '
            + json.dumps(args.model) + '\n'
        )
        os.chmod(config, 0o600)
    # Save in the native HOME, which is persistent across turns on every lane.
    env["VIBE_SESSION_LOGGING__ENABLED"] = "true"
    command = [args.cli]
    wrapper = env.get("SANDBOXED_MCP_WRAPPER")
    if wrapper:
        command = [wrapper, "launch", "--harness", "vibe", "--", *command]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, env=env)
    sequence = 0
    active = False

    def send(value):
        child.stdin.write(json.dumps(value) + "\n")
        child.stdin.flush()

    def call(method, params):
        nonlocal sequence
        sequence += 1
        request = sequence
        send(dict(jsonrpc="2.0", id=request, method=method, params=params))
        while True:
            line = child.stdout.readline()
            if not line:
                raise RuntimeError("Vibe ACP closed before returning " + method)
            message = json.loads(line)
            if message.get("id") == request and "method" not in message:
                if "error" in message:
                    # Error text may contain provider diagnostics; do not echo credentials.
                    raise RuntimeError("Vibe ACP rejected " + method + " (" + str(message["error"].get("code")) + ")")
                return message.get("result") or {}
            if message.get("method") == "session/request_permission":
                options = message.get("params", {}).get("options", [])
                allowed = next((o for o in options if o.get("kind") == "allow_once"), None)
                result = {"outcome": {"outcome": "cancelled"}}
                kind = message.get("params", {}).get("toolCall", {}).get("kind")
                if allowed and (args.mode != "plan" or kind in ("read", "search", "think", "fetch")):
                    result = {"outcome": {"outcome": "selected", "optionId": allowed["optionId"]}}
                send(dict(jsonrpc="2.0", id=message["id"], result=result))
            elif "method" in message and "id" in message:
                send(dict(jsonrpc="2.0", id=message["id"], error=dict(code=-32601, message="Unsupported client method")))
            elif active and message.get("method") == "session/update":
                params = message.get("params", {})
                if params.get("sessionId") == session:
                    emit("update", update=params.get("update", {}))

    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    try:
        info = call("initialize", dict(protocolVersion=1, clientCapabilities={},
                    clientInfo=dict(name="sandboxed.sh", version="1")))
        if session and not info.get("agentCapabilities", {}).get("loadSession"):
            raise RuntimeError("This Vibe version cannot resume native sessions")
        # Explicitly trust only the mission directory, through Vibe's own API.
        trust = call("_trust/status", dict(cwd=cwd))
        if "trust_cwd" in (trust.get("details") or {}).get("availableDecisions", []):
            call("_trust/decision", dict(cwd=cwd, decision="trust_cwd"))
        if not session:
            save(journal, dict(cwd=cwd, session=None))
        state = call("session/load" if session else "session/new", dict(
            cwd=cwd, mcpServers=[], **({"sessionId": session} if session else {})))
        session = session or state.get("sessionId")
        if not session:
            raise RuntimeError("Vibe did not return a native session identity")
        save(journal, dict(cwd=cwd, session=session))
        emit("session", session_id=session)
        if args.ack and json.loads(sys.stdin.readline()).get("continue") is not True:
            raise RuntimeError("Parent did not persist the Vibe native identity")
        modes = state.get("modes", {}).get("availableModes", [])
        desired = "plan" if args.mode == "plan" else "auto-approve"
        if not any(mode.get("id") == desired for mode in modes):
            raise RuntimeError("Vibe does not advertise the requested mode: " + desired)
        call("session/set_mode", dict(sessionId=session, modeId=desired))
        if args.model:
            call("session/set_model", dict(sessionId=session, modelId="sandboxed-selected"))
        active = True
        result = call("session/prompt", dict(sessionId=session, prompt=[dict(type="text", text=args.prompt)]))
        emit("result", stop_reason=result.get("stopReason"))
        return 0 if result.get("stopReason") == "end_turn" else 1
    finally:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", default="vibe-acp")
    parser.add_argument("--mission", required=True)
    parser.add_argument("--resume")
    parser.add_argument("--model")
    parser.add_argument("--mode", choices=["build", "plan"], default="build")
    parser.add_argument("--ack", action="store_true")
    parser.add_argument("--prompt", required=True)
    try:
        sys.exit(run(parser.parse_args()))
    except Exception as error:
        emit("error", message=str(error))
        sys.exit(1)
