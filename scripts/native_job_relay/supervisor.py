"""Trusted Linux supervisor primitives. Call from a dedicated supervisor thread."""
import contextlib
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys

TRANSPORT = Path(__file__).with_name("transport.py")


@contextlib.contextmanager
def private_listener():
    """Return an anonymous job namespace and a listener bound inside it."""
    with contextlib.ExitStack() as resources:
        outer = os.open("/proc/thread-self/ns/net", os.O_RDONLY)
        resources.callback(os.close, outer)
        os.unshare(os.CLONE_NEWNET)
        try:
            ip = shutil.which("ip")
            if not ip:
                raise RuntimeError("iproute2 is required for a private profile namespace")
            subprocess.run([ip, "link", "set", "lo", "up"], check=True, env={})
            namespace = os.open("/proc/thread-self/ns/net", os.O_RDONLY)
            resources.callback(os.close, namespace)
            listener = resources.enter_context(socket.socket())
            listener.bind(("127.0.0.1", 0))
            listener.listen()
        finally:
            os.setns(outer, os.CLONE_NEWNET)
        yield namespace, listener


@contextlib.contextmanager
def _private_transport(role, config):
    """Project one inherited SOCKS listener into a fresh loopback-only namespace.

    The trusted caller owns the running placement and stops its workload before
    exiting this context. Only the launcher receives the namespace descriptor.
    """
    with private_listener() as (namespace, listener), contextlib.ExitStack() as resources:
        read_fd, write_fd = os.pipe()
        lifetime = resources.enter_context(os.fdopen(write_fd, "wb"))
        watcher = resources.enter_context(os.fdopen(read_fd, "rb"))
        descriptor = os.memfd_create("orb-job-route")
        with os.fdopen(descriptor, "w+") as handle:
            json.dump(config, handle)
            handle.seek(0)
            pid = subprocess.Popen(
                [sys.executable, "-I", str(TRANSPORT), role, "--listen-fd", str(listener.fileno()),
                 "--config-fd", str(descriptor), "--lifetime-fd", str(read_fd)],
                pass_fds=(listener.fileno(), descriptor, read_fd), env={"PATH": os.defpath})
        watcher.close()
        port = listener.getsockname()[1]
        listener.close()
        try:
            yield namespace, port
        finally:
            lifetime.close()
            try:
                pid.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pid.kill()
                pid.wait()


def node_transport(config):
    return _private_transport("node", config)


def profile_transport(verified_port, *, direct=False, relay_account=None, relay_password=None):
    """The caller holds an admitted placement and closes this context on revocation."""
    if direct is True:
        if verified_port is not None or relay_account is not None or relay_password is not None:
            raise ValueError("Direct cannot use a tunnel or relay credential")
        return _private_transport("profile", {"direct": True})
    if direct is not False or type(verified_port) is not int or not 0 < verified_port <= 65535:
        raise ValueError("a verified account tunnel is required")
    config = {"verified_port": verified_port}
    if relay_account is not None or relay_password is not None:
        if not isinstance(relay_account, str) or not relay_account or not isinstance(relay_password, str) or not relay_password:
            raise ValueError("account relay requires its scoped credential")
        config.update(account=relay_account, password=relay_password)
    return _private_transport("profile", config)
