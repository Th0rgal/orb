"""Bridge Core's restricted native profile to a checkout's isolated file executor."""
import contextlib
import os
import socket
import subprocess
import threading

from .workspace import start_file_executor


@contextlib.contextmanager
def workspace_socket(directory, profile_uid, profile_gid, bwrap, image, checkout, uid, gid, *, readonly):
    """The supervisor pins all paths and principals before entering this context.

    Unexpected executor loss sets failed, including after the model reports success.
    The supervisor may cancel a run as soon as this is observed.
    """
    connected = threading.Event()
    failed = threading.Event()
    stop = threading.Event()
    children = []
    sockpath = os.path.join(directory, "workspace.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(sockpath)
        os.chown(sockpath, profile_uid, profile_gid)
        os.chmod(sockpath, 0o600)
        server.listen(1)
        server.settimeout(.1)

        def serve():
            try:
                while not stop.is_set():
                    if any(p.poll() not in (None, 0) for p in children):
                        failed.set()
                        break
                    children[:] = [p for p in children if p.returncode is None]
                    try:
                        conn, _ = server.accept()
                    except TimeoutError:
                        continue
                    with conn:
                        # A profile may reconnect during the same turn. Bound the
                        # number of simultaneous executors and reap closed clients.
                        if len(children) >= 2:
                            failed.set()
                            break
                        child = start_file_executor(bwrap, image, checkout, uid, gid, conn, readonly=readonly)
                        children.append(child)
                        connected.set()
            except (ValueError, RuntimeError, OSError):
                failed.set()

        thread = threading.Thread(target=serve)
        thread.start()
        try:
            yield connected, failed
        finally:
            stop.set()
            thread.join(2)
            for child in children:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        child.kill()
                child.wait()
            os.unlink(sockpath)
