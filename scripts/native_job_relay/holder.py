"""One dev-only native turn on a trusted worker co-located with Core."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import select
import shutil
import stat
import tempfile
import threading
import uuid

from .profile import start_profile
from .remote import remote_socket, rpc_socket
from .delegation import Delegation
from .acp import turn as acp_turn
from .session import workspace_socket
from .supervisor import profile_transport


def directory(stack, path, parent=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY, dir_fd=parent)
    stack.callback(os.close, fd)
    return fd


def private_state(stack, runtime, session, uid, gid):
    """Persistent conversation data is unreachable from workspace tools."""
    root = directory(stack, runtime)
    info = os.fstat(root)
    if info.st_uid != 0 or info.st_mode & 0o077:
        raise PermissionError("private runtime required")
    sessions = directory(stack, "sessions", root)
    try:
        os.mkdir(session, mode=0o700, dir_fd=sessions)
    except FileExistsError:
        pass
    owner = directory(stack, session, sessions)
    info = os.fstat(owner)
    if info.st_uid != 0 or info.st_mode & 0o077:
        raise PermissionError("invalid session owner")
    fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        os.mkdir("home", mode=0o700, dir_fd=owner)
    except FileExistsError:
        pass
    home = directory(stack, "home", owner)
    info = os.fstat(home)
    if info.st_uid not in (0, uid) or info.st_mode & 0o077:
        raise PermissionError("invalid profile owner")
    os.fchown(home, uid, gid)
    # bubblewrap mounts read-only files onto existing targets, including on resume.
    for names in [(".gemini", "config", "agents", "orb-workspace.md"), (".gemini", "config", "mcp_config.json"),
                  (".gemini", "antigravity-cli", "settings.json"),
                  (".gemini", "antigravity-cli", "antigravity-oauth-token")]:
        parent = home
        for name in names[:-1]:
            try:
                os.mkdir(name, 0o700, dir_fd=parent)
            except FileExistsError:
                pass
            parent = directory(stack, name, parent)
            os.fchown(parent, uid, gid)
        try:
            fd = os.open(names[-1], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=parent)
        except FileExistsError:
            pass
        else:
            os.close(fd)
        leaf = os.stat(names[-1], dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(leaf.st_mode) or leaf.st_size:
            raise PermissionError("invalid private mount target")
    return home


def member_checkout(stack, username, mission):
    user = pwd.getpwnam(username)
    if user.pw_uid <= 0 or user.pw_gid <= 0 or user.pw_dir != "/home/" + username or "/" in username:
        raise PermissionError("invalid member workspace principal")
    fd = directory(stack, "/home")
    for leaf in (username, ".orb-missions", str(uuid.UUID(mission))):
        fd = directory(stack, leaf, fd)
        if os.fstat(fd).st_uid != user.pw_uid:
            raise PermissionError("workspace differs from member placement")
    return fd, user.pw_uid, user.pw_gid


def run(runtime, profile_uid, profile_gid, packet, lifetime, emit, exchange=None):
    """Core closes lifetime on revoke. The socket and private namespace die with this turn."""
    if os.geteuid() != 0:
        raise PermissionError("trusted profile holder required")
    with contextlib.ExitStack() as stack:
        remote = packet.get("remote") is True
        if remote:
            if exchange is None or not packet["exec_uid"]:
                raise PermissionError("verified remote worker required")
        else:
            checkout, uid, gid = member_checkout(stack, packet["unix_user"], packet["mission"])
            if uid != packet["exec_uid"] or profile_uid == uid or profile_gid == gid:
                raise PermissionError("invalid workspace principal")
        if profile_uid <= 0 or profile_gid <= 0:
            raise PermissionError("invalid profile principal")
        identity = [packet[k] for k in ("owner", "mission", "account")]
        key = hashlib.sha256(json.dumps(identity, separators=(",", ":")).encode()).hexdigest()
        home = private_state(stack, runtime, key, profile_uid, profile_gid)
        base = Path(runtime)
        image = directory(stack, base / "profile-image")
        tmp = stack.enter_context(tempfile.TemporaryDirectory(dir=base))
        os.chmod(tmp, 0o711)
        ipc = directory(stack, tmp)
        bwrap = shutil.which("bwrap")
        nsenter = shutil.which("nsenter")
        if not bwrap or not nsenter:
            raise RuntimeError("native isolation unavailable")
        goal = packet.get("goal") is True
        if goal and not remote:
            raise PermissionError("Goal requires an enrolled remote workspace")
        if remote:
            listener = remote_socket(tmp, profile_uid, profile_gid, packet["readonly"], lambda file: exchange({"file": file}))
        else:
            files = directory(stack, base / "workspace-image")
            listener = workspace_socket(tmp, profile_uid, profile_gid, bwrap, files, checkout, uid, gid,
                                        readonly=packet["readonly"], goal=goal)
        connected, failed = stack.enter_context(listener)
        if goal:
            delegate = Delegation(lambda request: exchange({"delegate": request}))
            stack.enter_context(rpc_socket(tmp, "delegate.sock", profile_uid, profile_gid, delegate.respond))
        namespace, port = stack.enter_context(profile_transport(packet["port"], direct=packet.get("direct", False)))
        child = start_profile(nsenter, bwrap, image, home, ipc, namespace, port, profile_uid, profile_gid,
                              packet["access_token"], packet["model"], packet.get("conversation"), readonly=packet["readonly"], goal=goal)
        stop = threading.Event()
        invalid = threading.Event()

        def revoke():
            poller = select.poll()
            poller.register(lifetime, select.POLLERR | select.POLLHUP)
            while not stop.is_set():
                if poller.poll(150) or failed.is_set():
                    invalid.set()
                    child.kill()
                    return

        monitor = threading.Thread(target=revoke)
        monitor.start()
        try:
            if goal:
                acp_turn(child, packet, delegate.ask, emit)
                return
            message = {"event": "user", "message": {"role": "user", "content": packet["prompt"]}}
            child.stdin.write(json.dumps(message).encode() + b"\n")
            child.stdin.close()
            terminal = None
            for line in iter(lambda: child.stdout.readline(1024 * 1024 + 1), b""):
                if len(line) > 1024 * 1024:
                    raise ValueError("native frame too large")
                frame = json.loads(line)
                if frame.get("event") == "result":
                    terminal = frame
                else:
                    emit(frame)
            if child.wait(timeout=3) or invalid.is_set() or failed.is_set() or not connected.is_set() or not terminal:
                raise RuntimeError("native turn failed")
            emit(terminal)
        finally:
            stop.set()
            if child.poll() is None:
                child.kill()
            child.wait()
            monitor.join(2)
