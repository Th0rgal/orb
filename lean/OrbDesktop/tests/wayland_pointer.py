"""Virtual pointer for tests running on a private wlroots compositor."""
import os
import socket
import struct
import time

from wayland_ime import string


class Pointer:
    def __init__(self, env):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        try:
            self.sock.connect(os.path.join(env['XDG_RUNTIME_DIR'], env['WAYLAND_DISPLAY']))
            self.send(1, 1, struct.pack('=I', 2))  # wl_display.get_registry
            self.send(1, 0, struct.pack('=I', 3))  # wl_display.sync
            name = None
            while True:
                obj, op, body = self.event()
                if obj == 3:
                    break
                if obj == 2 and op == 0:
                    candidate, size = struct.unpack_from('=II', body)
                    if body[8:8+size-1] == b'zwlr_virtual_pointer_manager_v1':
                        name = candidate
            if name is None:
                raise RuntimeError('Compositor does not expose virtual-pointer-v1')
            self.send(2, 0, struct.pack('=I', name) + string('zwlr_virtual_pointer_manager_v1') + struct.pack('=II', 1, 4))
            self.send(4, 0, struct.pack('=II', 0, 5))  # create pointer on default seat
            self.send(1, 0, struct.pack('=I', 6))
            while self.event()[0] != 6:
                pass
        except BaseException:
            self.close()
            raise

    def send(self, obj, op, body=b''):
        self.sock.sendall(struct.pack('=II', obj, ((8 + len(body)) << 16) | op) + body)

    def event(self):
        def read(size):
            data = bytearray()
            while len(data) < size:
                chunk = self.sock.recv(size - len(data))
                if not chunk:
                    raise EOFError('Compositor disconnected')
                data.extend(chunk)
            return data
        obj, header = struct.unpack('=II', read(8))
        body = read((header >> 16) - 8)
        if obj == 1 and header & 0xffff == 0:
            raise RuntimeError('Virtual pointer protocol error')
        return obj, header & 0xffff, body

    def click(self, x, y, button='button1'):
        code = {'button1': 272, 'button3': 273}[button]
        for op, args in ((1, (x, y, 1000, 700)), (2, (code, 1)), (2, (code, 0))):
            ms = int(time.monotonic() * 1000) & 0xffffffff
            self.send(5, op, struct.pack('=' + 'I' * (1 + len(args)), ms, *args))
            self.send(5, 4)  # frame
            time.sleep(.08)

    def close(self):
        self.sock.close()
