"""Serve one small UTF-8 workspace file after orb-privd has dropped privileges."""
import contextlib
import ctypes
import os
import secrets
import stat

MAX_BYTES = 256 * 1024
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def restrict_checkout(fd, writer):
    """Constrain this one-shot UID-dropped helper even if a directory moves."""
    if os.uname().machine not in ("aarch64", "x86_64"):
        raise OSError("Unsupported workspace isolation")
    libc = ctypes.CDLL(None, use_errno=True)
    create, add, restrict = 444, 445, 446  # Linux Landlock UAPI on both supported architectures.
    if libc.syscall(create, None, 0, 1) < 3:
        raise OSError("Workspace isolation unavailable")
    handled = ctypes.c_uint64((1 << 15) - 1)  # ABI 3 handles filesystem rights through TRUNCATE.
    ruleset = libc.syscall(create, ctypes.byref(handled), ctypes.sizeof(handled), 0)
    if ruleset < 0:
        raise OSError("Workspace isolation unavailable")

    class PathBeneath(ctypes.Structure):
        _pack_ = 1
        _fields_ = [("access", ctypes.c_uint64), ("parent_fd", ctypes.c_int32)]

    read = (1 << 2) | (1 << 3)  # READ_FILE, READ_DIR
    modify = (1 << 1) | (1 << 5) | (1 << 8) | (1 << 13) | (1 << 14)
    rule = PathBeneath(read | (modify if writer else 0), fd)
    try:
        if libc.syscall(add, ruleset, 1, ctypes.byref(rule), 0) < 0:
            raise OSError("Invalid workspace rule")
        if libc.prctl(38, 1, 0, 0, 0) < 0 or libc.syscall(restrict, ruleset, 0) < 0:
            raise OSError("Could not enter workspace")
    finally:
        os.close(ruleset)


def job_file(root, request, private_name):
    op = request.get("action")
    path = request.get("path")
    if not isinstance(path, str) or not path or len(path) > 4096 or "\\" in path:
        raise ValueError("Invalid workspace path")
    components = path.split("/")
    if any(c in ("", ".", "..") or private_name(c) for c in components):
        raise ValueError("Invalid workspace path")
    if op not in ("read_file", "write_file"):
        raise ValueError("Invalid workspace operation")
    with contextlib.ExitStack() as stack:
        parent = os.open("/", DIR_FLAGS)
        stack.callback(os.close, parent)
        for component in root.strip("/").split("/"):
            parent = os.open(component, DIR_FLAGS, dir_fd=parent)
            stack.callback(os.close, parent)
        restrict_checkout(parent, op == "write_file")
        for component in components[:-1]:
            parent = os.open(component, DIR_FLAGS, dir_fd=parent)
            stack.callback(os.close, parent)
        name = components[-1]
        if op == "read_file":
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            with os.fdopen(fd, "rb") as src:
                info = os.fstat(src.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError("Expected a private regular file")
                data = src.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise ValueError("Workspace file too large")
            return {"content": data.decode("utf-8")}
        content = request.get("content")
        if not isinstance(content, str) or len(content.encode("utf-8")) > MAX_BYTES:
            raise ValueError("Invalid workspace contents")
        try:
            info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError("Expected a private regular file")
        temp = ".orb-write-" + secrets.token_hex(16)
        fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=parent)
        try:
            with os.fdopen(fd, "wb") as dst:
                size = dst.write(content.encode("utf-8"))
            os.replace(temp, name, src_dir_fd=parent, dst_dir_fd=parent)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temp, dir_fd=parent)
        return {"size": size}
