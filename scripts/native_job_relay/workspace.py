"""Start a file MCP for one authenticated job using supervisor-held directory descriptors."""

import os
import stat
import subprocess


def start_file_executor(bwrap, rootfs, workspace, uid, gid, stream, *, readonly):
    """rootfs is a trusted image containing /bin/setpriv, /bin/workspace-mcp and /workspace.

    Both descriptors must come from the placement supervisor. Neither authority
    nor host paths are accepted from MCP requests. Only stdio reaches the tool.
    """
    if os.geteuid() != 0 or uid <= 0 or gid <= 0:
        raise ValueError("expected an unprivileged workspace identity")
    image = os.fstat(rootfs)
    checkout = os.fstat(workspace)
    if not stat.S_ISDIR(image.st_mode) or image.st_uid != 0 or image.st_mode & 0o022:
        raise ValueError("untrusted workspace image")
    if not stat.S_ISDIR(checkout.st_mode) or checkout.st_uid != uid:
        raise ValueError("workspace owner differs from placement")
    return subprocess.Popen([
        bwrap, "--unshare-pid", "--unshare-ipc", "--unshare-net", "--unshare-uts", "--new-session", "--die-with-parent",
        "--cap-drop", "ALL", "--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID",
        "--ro-bind-fd", str(rootfs), "/", "--ro-bind-fd" if readonly else "--bind-fd", str(workspace), "/workspace",
        "--dev", "/dev", "--clearenv", "--setenv", "HOME", "/nonexistent", "--setenv", "SANDBOXED_SH_WORKSPACE", "/workspace", "--chdir", "/",
        "--", "/bin/setpriv", "--clear-groups", "--reuid", str(uid), "--regid", str(gid), "--no-new-privs",
        "--", "/bin/workspace-mcp", "--bound-files", "readonly" if readonly else "writer",
    ], stdin=stream, stdout=stream, stderr=subprocess.DEVNULL, env={}, cwd="/", pass_fds=(rootfs, workspace),
       extra_groups=[])
