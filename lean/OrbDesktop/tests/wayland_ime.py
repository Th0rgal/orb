"""Persistent input-method-v2 client for the private headless Sway session.

Wait for compositor activation before committing; wtype's Unicode keysyms do
not exercise text-input-v3. No connection to Core or to the Orb process.
"""
from contextlib import contextmanager
import os
import socket
import struct


def string(text):
    data = text.encode() + b'\0'
    return struct.pack('=I', len(data)) + data + bytes(-len(data) % 4)


@contextmanager
def session(env):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(os.path.join(env['XDG_RUNTIME_DIR'], env['WAYLAND_DISPLAY']))

        def send(obj, op, body=b''):
            sock.sendall(struct.pack('=II', obj, ((8 + len(body)) << 16) | op) + body)

        def read(n):
            data = b''
            while len(data) < n:
                chunk = sock.recv(n - len(data))
                if not chunk:
                    raise EOFError('Wayland disconnected')
                data += chunk
            return data

        send(1, 1, struct.pack('=I', 2))  # wl_display.get_registry
        globals_seen = {}
        active = False
        serial = 0
        callback = 5

        def receive():
            nonlocal active, serial
            obj, header = struct.unpack('=II', read(8))
            op = header & 65535
            body = read((header >> 16) - 8)
            if obj == 1 and op == 0:
                raise RuntimeError('Wayland protocol error')
            if obj == 2 and op == 0:
                name, length = struct.unpack_from('=II', body)
                iface = body[8:8+length-1].decode()
                if iface in ('wl_seat', 'zwp_input_method_manager_v2') and iface not in globals_seen:
                    ident = 3 + len(globals_seen)
                    send(2, 0, struct.pack('=I', name) + string(iface) + struct.pack('=II', 1, ident))
                    globals_seen[iface] = ident
                    if len(globals_seen) == 2:
                        send(globals_seen['zwp_input_method_manager_v2'], 0, struct.pack('=II', globals_seen['wl_seat'], 5))
            if obj == 5:
                if op in (0, 1):
                    active = op == 0
                elif op == 5:  # done
                    serial += 1
                elif op == 6:
                    raise RuntimeError('input method unavailable')
            return obj

        def sync():
            nonlocal callback
            callback += 1
            send(1, 0, struct.pack('=I', callback))
            while receive() != callback:
                pass

        def edit(batches, preedit=''):
            # Drain focus changes from the previous field before editing this one.
            sync()
            while not active:
                receive()
            for text, before, after in batches:
                if before or after:
                    send(5, 2, struct.pack('=II', before, after))
                send(5, 0, string(text))
                if preedit:
                    send(5, 1, string(preedit) + struct.pack('=ii', 0, 0))
                send(5, 3, struct.pack('=I', serial))
                sync()

        while len(globals_seen) != 2:
            receive()
        yield edit
