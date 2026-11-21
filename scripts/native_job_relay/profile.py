"""Launch an access-only agy profile using descriptors held by Core's trusted supervisor."""
import contextlib
import json
import os
import stat
import subprocess
import uuid


def start_profile(nsenter, bwrap, rootfs, home, ipc, namespace, port, uid, gid,
                  access_token, model, conversation=None):
    """The private image supplies an empty /session and the CLI, setpriv and socat.

    home is a dedicated per-owner/mission/account directory for conversation state.
    The access token lives only in a read-only mount in this invocation's namespace.
    The caller owns the verified route and terminates the process on invalidation.
    """
    if os.geteuid() != 0 or uid <= 0 or gid <= 0 or not access_token or not 0 < port <= 65535:
        raise ValueError("expected a verified unprivileged native placement")
    for directory in (rootfs, ipc):
        info = os.fstat(directory)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("untrusted native runtime")
    info = os.fstat(home)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077:
        raise ValueError("invalid native session owner")
    if not model or len(model) > 128 or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-." for c in model):
        raise ValueError("invalid native model")
    args = ["/bin/agy", "--agent", "orb-workspace", "--disable-slash-commands",
            "--model", model, "--output-format", "stream-json", "--print-timeout", "120s"]
    if conversation:
        args.extend(("--conversation", str(uuid.UUID(conversation))))
    # The caller sends {"event":"user","message":{"role":"user","content":...}} on stdin.
    args.extend(("--input-format", "stream-json"))
    token = {"auth_method": "consumer", "token": {"access_token": access_token, "token_type": "Bearer"}}
    proxy = f"socks5://127.0.0.1:{port}"
    agent = ("---\nname: orb-workspace\ndescription: Isolated Orb workspace\nmainAgent: true\n"
             "subagent: false\ntools: []\ncommandExecutionPolicy: off\n---\nUse the workspace MCP.")
    settings = {"permissions": {"allow": ["mcp(workspace/write_file)"]}}
    config = {"mcpServers": {"workspace": {"command": "/bin/socat", "args": ["STDIO", "UNIX-CONNECT:/ipc/workspace.sock"]}}}
    files = [
        ("/home/orb/.gemini/antigravity-cli/antigravity-oauth-token", json.dumps(token)),
        ("/home/orb/.gemini/config/agents/orb-workspace.md", agent),
        ("/home/orb/.gemini/antigravity-cli/settings.json", json.dumps(settings)),
        ("/session/.agents/mcp_config.json", json.dumps(config)),
    ]
    with contextlib.ExitStack() as stack:
        mounts = []
        fds = []
        for path, value in files:
            handle = stack.enter_context(os.fdopen(os.memfd_create("orb-native-config"), "w+"))
            handle.write(value)
            handle.seek(0)
            fds.append(handle.fileno())
            mounts.extend(("--perms", "0444", "--ro-bind-data", str(handle.fileno()), path))
        return subprocess.Popen([
            nsenter, f"--net=/proc/self/fd/{namespace}", "--", bwrap, "--unshare-pid", "--unshare-ipc",
            "--unshare-uts", "--new-session", "--die-with-parent", "--cap-drop", "ALL",
            "--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID", "--ro-bind-fd", str(rootfs), "/",
            "--bind-fd", str(home), "/home/orb", "--ro-bind-fd", str(ipc), "/ipc",
            *mounts,
            "--tmpfs", "/tmp", "--dev", "/dev", "--proc", "/proc", "--clearenv",
            "--setenv", "PATH", "/bin", "--setenv", "HOME", "/home/orb", "--setenv", "TERM", "dumb",
            "--setenv", "HTTPS_PROXY", proxy, "--setenv", "HTTP_PROXY", proxy,
            "--setenv", "ALL_PROXY", proxy, "--chdir", "/session", "--",
            "/bin/setpriv", "--clear-groups", "--reuid", str(uid), "--regid", str(gid), "--no-new-privs",
            "--", *args], env={}, cwd="/", pass_fds=(rootfs, home, ipc, namespace, *fds),
            extra_groups=[], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
