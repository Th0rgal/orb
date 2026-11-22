"""Crash the supervisor in a disposable loopback-only Linux guest."""
import errno
import os
import socket
import subprocess
import sys

from native_job_relay.supervisor import node_transport


def start(control_fd):
    # A SOCKS greeting is local. No grant or TLS upstream is needed for it.
    config = {"host": "127.0.0.1", "port": 1, "claim": {}}
    with socket.socket(fileno=control_fd) as channel, node_transport(config) as (namespace, port):
        socket.send_fds(channel, [port.to_bytes(2, "big")], [namespace])
        assert channel.recv(1) == b"!"
        os._exit(42)


def run():
    assert set(os.listdir("/sys/class/net")) == {"lo"}
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    with subprocess.Popen([sys.executable, __file__, str(child.fileno())],
                          pass_fds=(child.fileno(),)) as supervisor, parent, child:
        child.close()
        parent.settimeout(5)
        data, descriptors, _, _ = socket.recv_fds(parent, 2, 1)
        namespace, = descriptors
        os.setns(namespace, os.CLONE_NEWNET)
        os.close(namespace)
        address = ("127.0.0.1", int.from_bytes(data, "big"))
        with socket.create_connection(address, timeout=5) as active:
            active.sendall(bytes([5, 1, 0]))
            assert active.recv(2, socket.MSG_WAITALL) == bytes([5, 0])
            parent.sendall(b"!")
            assert supervisor.wait(timeout=5) == 42
            assert active.recv(1) == b""
        with socket.socket() as retry:
            assert retry.connect_ex(address) == errno.ECONNREFUSED
    print("supervisor process loss: active SOCKS connection closed; listener refused reconnect")


if __name__ == "__main__":
    if len(sys.argv) == 2:
        start(int(sys.argv[1]))
    else:
        run()
