"""Trusted Linux supervisor primitives. Call from a dedicated supervisor thread."""
import contextlib
import json
import os
from pathlib import Path
import socket
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
            subprocess.run(["ip", "link", "set", "lo", "up"], check=True, env={"PATH": os.defpath + ":/sbin:/usr/sbin"})
            namespace = os.open("/proc/thread-self/ns/net", os.O_RDONLY)
            resources.callback(os.close, namespace)
            listener = resources.enter_context(socket.socket())
            listener.bind(("127.0.0.1", 0))
            listener.listen()
        finally:
            os.setns(outer, os.CLONE_NEWNET)
        yield namespace, listener


@contextlib.contextmanager
def node_transport(config):
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
                [sys.executable, "-I", str(TRANSPORT), "node", "--listen-fd", str(listener.fileno()),
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
