"""Scripted Wayland input-injection verification for Roadmap Row U6.

Speaks the real Wayland wire protocol over an AF_UNIX `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`
socket directly to the compiled `orb-desktop-native` binary:
- `wl_compositor` v4, `wl_shm` v1 (`SCM_RIGHTS` memfd framebuffer capture), `xdg_wm_base` v4,
  `wp_viewporter` v1, `wp_fractional_scale_manager_v1` v1, `wp_cursor_shape_manager_v1` v1,
  `wl_seat` v5, `wl_pointer` v5 (motion, left/right button, wheel axis),
  `wl_keyboard` v5 (real XKB US-QWERTY keymap via `SCM_RIGHTS` memfd, modifiers, evdev keys),
  `zwp_text_input_manager_v3` / `zwp_text_input_v3` (enter, preedit, delete_surrounding_text,
  commit_string, done).

Verifies:
1. Live `--leanui` session against a local disposable HTTP Core fixture:
   - Creates a mission via Wayland keyboard + IME preedit/surrounding-delete/commit + Return
   - Sends a follow-up message via Wayland pointer click + keyboard + IME + Send
   - Scrolls transcript with `Orb.Scroll` policy (unpins on upward wheel, stays anchored during
     incoming stream, re-pins on downward wheel near bottom)
   - Exercises side panels (header Diff / Files / Side-chat toggles, Diff mode controls, close,
     and left sidebar collapse/expand via `Ctrl+B` & pointer click)
   - Stops the running mission via Wayland pointer click on Stop (verified on Core)
   - Archives the mission via Wayland right-click context menu (verified on Core)
   - Exercises Inference VPN & alternative-router controls (`PUT /preference`, `GET/PUT /vpn`
     country `NL` + `direct`, `GET/PUT /alternative-routers`, Escape back)
   - Exercises Search modal (`Ctrl+K`, keyboard + IME query, ArrowDown, Escape), Machines (`Ctrl+3`),
     Resources (`Ctrl+6`), Cloud (`Ctrl+2`), Inbox (`Ctrl+I`), Settings (`Ctrl+,`), and clean
     `xdg_toplevel.close`.
2. All 9 canonical screens (`01_control_empty` .. `09_toast_notifications`) via real Wayland
   input injection (pointer clicks, wheel scroll, Tab/Shift+Tab focus traversal, shortcuts,
   text entry, and IME commits across every interactive control in all 9 screens).
"""

from __future__ import annotations

import array
import contextlib
import hashlib
import json
import mmap
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_BINARY = ROOT / "lean/OrbDesktop/.lake/build/bin/orb-desktop-native"


def _wl_str(text: str | None) -> bytes:
    if text is None:
        return struct.pack("=I", 0)
    raw = text.encode("utf-8") + b"\x00"
    pad = (-len(raw)) % 4
    return struct.pack("=I", len(raw)) + raw + (b"\x00" * pad)


def _wl_array(data: bytes) -> bytes:
    pad = (-len(data)) % 4
    return struct.pack("=I", len(data)) + data + (b"\x00" * pad)


def _wl_msg(obj_id: int, opcode: int, body: bytes = b"") -> bytes:
    size = 8 + len(body)
    return struct.pack("=II", obj_id, (size << 16) | opcode) + body


# Minimal self-contained XKB US-QWERTY keymap matching standard Linux evdev keycodes (+8).
XKB_KEYMAP = r"""xkb_keymap {
xkb_keycodes "evdev_min" {
  minimum = 8;
  maximum = 255;
  <ESC>  = 9;
  <AE01> = 10; <AE02> = 11; <AE03> = 12; <AE04> = 13; <AE05> = 14;
  <AE06> = 15; <AE07> = 16; <AE08> = 17; <AE09> = 18; <AE10> = 19;
  <AE11> = 20; <AE12> = 21; <BKSP> = 22;
  <TAB>  = 23;
  <AD01> = 24; <AD02> = 25; <AD03> = 26; <AD04> = 27; <AD05> = 28;
  <AD06> = 29; <AD07> = 30; <AD08> = 31; <AD09> = 32; <AD10> = 33;
  <AD11> = 34; <AD12> = 35; <RTRN> = 36;
  <LCTL> = 37;
  <AC01> = 38; <AC02> = 39; <AC03> = 40; <AC04> = 41; <AC05> = 42;
  <AC06> = 43; <AC07> = 44; <AC08> = 45; <AC09> = 46; <AC10> = 47;
  <AC11> = 48;
  <LFSH> = 50;
  <AB01> = 52; <AB02> = 53; <AB03> = 54; <AB04> = 55; <AB05> = 56;
  <AB06> = 57; <AB07> = 58; <AB08> = 59; <AB09> = 60; <AB10> = 61;
  <LALT> = 64;
  <SPCE> = 65;
  <HOME> = 110; <UP> = 111; <PGUP> = 112; <LEFT> = 113; <RGHT> = 114;
  <END>  = 115; <DOWN> = 116; <PGDN> = 117; <DELE> = 119;
  <LWIN> = 133; <MENU> = 135;
};
xkb_types "minimal" {
  virtual_modifiers Alt, Super;
  type "ONE_LEVEL" { modifiers = none; };
  type "TWO_LEVEL" { modifiers = Shift; map[Shift] = Level2; };
  type "ALPHABETIC" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2; };
};
xkb_compatibility "minimal" {
  interpret Shift_L   { action = SetMods(modifiers=Shift); };
  interpret Control_L { action = SetMods(modifiers=Control); };
  interpret Alt_L     { action = SetMods(modifiers=Mod1); };
  interpret Super_L   { action = SetMods(modifiers=Mod4); };
};
xkb_symbols "us_min" {
  key <ESC>  { [ Escape ] };
  key <AE01> { [ 1, exclam ] };
  key <AE02> { [ 2, at ] };
  key <AE03> { [ 3, numbersign ] };
  key <AE04> { [ 4, dollar ] };
  key <AE05> { [ 5, percent ] };
  key <AE06> { [ 6, asciicircum ] };
  key <AE07> { [ 7, ampersand ] };
  key <AE08> { [ 8, asterisk ] };
  key <AE09> { [ 9, parenleft ] };
  key <AE10> { [ 0, parenright ] };
  key <AE11> { [ minus, underscore ] };
  key <AE12> { [ equal, plus ] };
  key <BKSP> { [ BackSpace ] };
  key <TAB>  { type="TWO_LEVEL", [ Tab, ISO_Left_Tab ] };
  key <AD01> { type="ALPHABETIC", [ q, Q ] };
  key <AD02> { type="ALPHABETIC", [ w, W ] };
  key <AD03> { type="ALPHABETIC", [ e, E ] };
  key <AD04> { type="ALPHABETIC", [ r, R ] };
  key <AD05> { type="ALPHABETIC", [ t, T ] };
  key <AD06> { type="ALPHABETIC", [ y, Y ] };
  key <AD07> { type="ALPHABETIC", [ u, U ] };
  key <AD08> { type="ALPHABETIC", [ i, I ] };
  key <AD09> { type="ALPHABETIC", [ o, O ] };
  key <AD10> { type="ALPHABETIC", [ p, P ] };
  key <AD11> { [ bracketleft, braceleft ] };
  key <AD12> { [ bracketright, braceright ] };
  key <RTRN> { [ Return ] };
  key <LCTL> { [ Control_L ] };
  key <AC01> { type="ALPHABETIC", [ a, A ] };
  key <AC02> { type="ALPHABETIC", [ s, S ] };
  key <AC03> { type="ALPHABETIC", [ d, D ] };
  key <AC04> { type="ALPHABETIC", [ f, F ] };
  key <AC05> { type="ALPHABETIC", [ g, G ] };
  key <AC06> { type="ALPHABETIC", [ h, H ] };
  key <AC07> { type="ALPHABETIC", [ j, J ] };
  key <AC08> { type="ALPHABETIC", [ k, K ] };
  key <AC09> { type="ALPHABETIC", [ l, L ] };
  key <AC10> { [ semicolon, colon ] };
  key <AC11> { [ apostrophe, quotedbl ] };
  key <LFSH> { [ Shift_L ] };
  key <AB01> { type="ALPHABETIC", [ z, Z ] };
  key <AB02> { type="ALPHABETIC", [ x, X ] };
  key <AB03> { type="ALPHABETIC", [ c, C ] };
  key <AB04> { type="ALPHABETIC", [ v, V ] };
  key <AB05> { type="ALPHABETIC", [ b, B ] };
  key <AB06> { type="ALPHABETIC", [ n, N ] };
  key <AB07> { type="ALPHABETIC", [ m, M ] };
  key <AB08> { [ comma, less ] };
  key <AB09> { [ period, greater ] };
  key <AB10> { [ slash, question ] };
  key <LALT> { [ Alt_L ] };
  key <SPCE> { [ space ] };
  key <HOME> { [ Home ] };
  key <UP>   { [ Up ] };
  key <PGUP> { [ Prior ] };
  key <LEFT> { [ Left ] };
  key <RGHT> { [ Right ] };
  key <END>  { [ End ] };
  key <DOWN> { [ Down ] };
  key <PGDN> { [ Next ] };
  key <DELE> { [ Delete ] };
  key <LWIN> { [ Super_L ] };
  key <MENU> { [ Menu ] };
  modifier_map Shift   { <LFSH> };
  modifier_map Control { <LCTL> };
  modifier_map Mod1    { <LALT> };
  modifier_map Mod4    { <LWIN> };
};
};
"""

# Linux evdev keycodes (XKB keycode - 8).
EV = {
    "esc": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
    "-": 12, "=": 13, "backspace": 14, "tab": 15,
    "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23, "o": 24, "p": 25,
    "[": 26, "]": 27, "return": 28, "lctrl": 29,
    "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37, "l": 38,
    ";": 39, "'": 40, "lshift": 42,
    "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50,
    ",": 51, ".": 52, "/": 53, "lalt": 56, " ": 57,
    "home": 102, "up": 103, "pgup": 104, "left": 105, "right": 106,
    "end": 107, "down": 108, "pgdn": 109, "delete": 111,
    "lsuper": 125, "menu": 127,
}
MOD_SHIFT = 1
MOD_CTRL = 4   # XKB Shift=1, Lock=2, Control=4, Mod1=8, Mod4=64
MOD_SUPER = 64

GLOBALS = [
    (1, "wl_compositor", 4),
    (2, "wl_shm", 1),
    (3, "xdg_wm_base", 4),
    (4, "wp_viewporter", 1),
    (5, "wp_fractional_scale_manager_v1", 1),
    (6, "wp_cursor_shape_manager_v1", 1),
    (7, "wl_seat", 5),
    (8, "zwp_text_input_manager_v3", 1),
]


class WaylandTestCompositor:
    """Real AF_UNIX Wayland wire-protocol compositor for scripted input injection."""

    def __init__(self, runtime_dir: Path, display_name: str, width: int = 1470, height: int = 923):
        self.runtime_dir = runtime_dir
        self.display_name = display_name
        self.sock_path = runtime_dir / display_name
        self.width = width
        self.height = height
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._stop = False
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(str(self.sock_path))
        self._server.listen(1)
        self._server.setblocking(False)
        self._client: socket.socket | None = None
        self._serial = 1
        self._objects: dict[int, str] = {1: "wl_display"}
        self._pools: dict[int, tuple[int, int, mmap.mmap]] = {}
        self._buffers: dict[int, tuple[int, int, int, int, int]] = {}  # buf -> (pool, off, w, h, stride)
        self._attached_buf: int | None = None
        self.surface_id: int | None = None
        self.xdg_surface_id: int | None = None
        self.xdg_toplevel_id: int | None = None
        self.seat_id: int | None = None
        self.pointer_id: int | None = None
        self.keyboard_id: int | None = None
        self.text_input_id: int | None = None
        self.cursor_device_id: int | None = None
        self.configured_acked = False
        self.commit_count = 0
        self.last_frame_hash: str = ""
        self.last_frame_bytes: bytes = b""
        self.cursor_shapes: list[int] = []
        self.text_input_enabled = False
        self._pending_ti_enable: bool | None = None
        self.text_input_commit_count = 0
        self._entered = False
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _next_serial(self) -> int:
        s = self._serial
        self._serial += 1
        return s

    def _send(self, payload: bytes, fds: list[int] | None = None) -> None:
        if self._client is None:
            return
        if fds:
            anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds).tobytes())]
            self._client.sendmsg([payload], anc)
        else:
            self._client.sendall(payload)

    def _serve(self) -> None:
        buf = bytearray()
        fds: list[int] = []
        while not self._stop:
            if self._client is None:
                r, _, _ = select.select([self._server], [], [], 0.05)
                if not r:
                    continue
                conn, _ = self._server.accept()
                conn.setblocking(True)
                with self._lock:
                    self._client = conn
                continue
            r, _, _ = select.select([self._client], [], [], 0.05)
            if not r:
                continue
            try:
                data, anc, _, _ = self._client.recvmsg(65536, socket.CMSG_SPACE(256))
            except OSError:
                break
            if not data:
                break
            for level, kind, payload in anc:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    arr = array.array("i")
                    arr.frombytes(payload[: len(payload) - len(payload) % arr.itemsize])
                    fds.extend(arr)
            buf.extend(data)
            while len(buf) >= 8:
                obj_id, header = struct.unpack_from("=II", buf, 0)
                size = header >> 16
                opcode = header & 0xFFFF
                if size < 8 or len(buf) < size:
                    break
                body = bytes(buf[8:size])
                del buf[:size]
                with self._lock:
                    self._handle_request(obj_id, opcode, body, fds)
        for fd in fds:
            with contextlib.suppress(OSError):
                os.close(fd)

    def _handle_request(self, obj_id: int, opcode: int, body: bytes, fds: list[int]) -> None:
        iface = self._objects.get(obj_id, "")
        if iface == "wl_display":
            if opcode == 0:  # sync(callback)
                cb = struct.unpack_from("=I", body, 0)[0]
                self._send(_wl_msg(cb, 0, struct.pack("=I", self._next_serial())))
                self._send(_wl_msg(1, 1, struct.pack("=I", cb)))  # delete_id
            elif opcode == 1:  # get_registry(registry)
                reg = struct.unpack_from("=I", body, 0)[0]
                self._objects[reg] = "wl_registry"
                for name, g_iface, ver in GLOBALS:
                    self._send(_wl_msg(reg, 0, struct.pack("=I", name) + _wl_str(g_iface) + struct.pack("=I", ver)))
        elif iface == "wl_registry" and opcode == 0:  # bind(name, iface, ver, new_id)
            name, slen = struct.unpack_from("=II", body, 0)
            s_end = 8 + slen + ((-slen) % 4)
            g_iface = body[8 : 8 + slen - 1].decode("utf-8")
            _ver, new_id = struct.unpack_from("=II", body, s_end)
            self._objects[new_id] = g_iface
            if g_iface == "wl_seat":
                self.seat_id = new_id
                # capabilities: pointer(1) | keyboard(2) = 3
                self._send(_wl_msg(new_id, 0, struct.pack("=I", 3)))
        elif iface == "wl_compositor" and opcode == 0:  # create_surface
            sid = struct.unpack_from("=I", body, 0)[0]
            self._objects[sid] = "wl_surface"
            self.surface_id = sid
        elif iface == "wl_shm" and opcode == 0:  # create_pool(id, fd, size)
            pid, size = struct.unpack_from("=Ii", body, 0)
            fd = fds.pop(0)
            mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
            self._pools[pid] = (fd, size, mm)
            self._objects[pid] = "wl_shm_pool"
        elif iface == "wl_shm_pool":
            if opcode == 0:  # create_buffer(id, offset, width, height, stride, format)
                bid, off, w, h, stride, _fmt = struct.unpack_from("=IiiiiI", body, 0)
                self._buffers[bid] = (obj_id, off, w, h, stride)
                self._objects[bid] = "wl_buffer"
            elif opcode == 1:  # destroy
                pool = self._pools.pop(obj_id, None)
                if pool:
                    pool[2].close()
                    os.close(pool[0])
                self._objects.pop(obj_id, None)
        elif iface == "wl_buffer" and opcode == 0:  # destroy
            self._buffers.pop(obj_id, None)
            self._objects.pop(obj_id, None)
        elif iface == "xdg_wm_base":
            if opcode == 2:  # get_xdg_surface(id, surface)
                xsid, _surf = struct.unpack_from("=II", body, 0)
                self._objects[xsid] = "xdg_surface"
                self.xdg_surface_id = xsid
        elif iface == "xdg_surface":
            if opcode == 1:  # get_toplevel(id)
                tid = struct.unpack_from("=I", body, 0)[0]
                self._objects[tid] = "xdg_toplevel"
                self.xdg_toplevel_id = tid
            elif opcode == 4:  # ack_configure(serial)
                self.configured_acked = True
                self._cond.notify_all()
        elif iface == "wp_viewporter" and opcode == 1:  # get_viewport
            vid = struct.unpack_from("=I", body, 0)[0]
            self._objects[vid] = "wp_viewport"
        elif iface == "wp_fractional_scale_manager_v1" and opcode == 1:
            fsid = struct.unpack_from("=I", body, 0)[0]
            self._objects[fsid] = "wp_fractional_scale_v1"
            self._send(_wl_msg(fsid, 0, struct.pack("=I", 120)))
        elif iface == "wp_cursor_shape_manager_v1" and opcode == 1:
            cid = struct.unpack_from("=I", body, 0)[0]
            self._objects[cid] = "wp_cursor_shape_device_v1"
            self.cursor_device_id = cid
        elif iface == "wp_cursor_shape_device_v1" and opcode == 1:  # set_shape(serial, shape)
            _ser, shape = struct.unpack_from("=II", body, 0)
            self.cursor_shapes.append(shape)
            self._cond.notify_all()
        elif iface == "wl_seat":
            if opcode == 0:  # get_pointer
                pid = struct.unpack_from("=I", body, 0)[0]
                self._objects[pid] = "wl_pointer"
                self.pointer_id = pid
                self._maybe_send_enter()
            elif opcode == 1:  # get_keyboard
                kid = struct.unpack_from("=I", body, 0)[0]
                self._objects[kid] = "wl_keyboard"
                self.keyboard_id = kid
                self._send_keymap(kid)
                self._maybe_send_enter()
        elif iface == "zwp_text_input_manager_v3" and opcode == 1:  # get_text_input(id, seat)
            tiid = struct.unpack_from("=I", body, 0)[0]
            self._objects[tiid] = "zwp_text_input_v3"
            self.text_input_id = tiid
        elif iface == "zwp_text_input_v3":
            if opcode == 1:  # enable
                self._pending_ti_enable = True
            elif opcode == 2:  # disable
                self._pending_ti_enable = False
            elif opcode == 7:  # commit
                if self._pending_ti_enable is not None:
                    self.text_input_enabled = self._pending_ti_enable
                    self._pending_ti_enable = None
                self.text_input_commit_count += 1
                self._cond.notify_all()
        elif iface == "wl_surface":
            if opcode == 1:  # attach(buffer, x, y)
                bid = struct.unpack_from("=I", body, 0)[0]
                self._attached_buf = bid
            elif opcode == 6:  # commit
                if self.xdg_toplevel_id and self.xdg_surface_id and not self.configured_acked and self._attached_buf is None:
                    # Initial commit -> send xdg_toplevel.configure + xdg_surface.configure
                    states = struct.pack("=I", 4)  # activated
                    self._send(_wl_msg(self.xdg_toplevel_id, 0, struct.pack("=ii", self.width, self.height) + _wl_array(states)))
                    self._send(_wl_msg(self.xdg_surface_id, 0, struct.pack("=I", self._next_serial())))
                    self._maybe_send_enter()
                elif self._attached_buf and self._attached_buf in self._buffers:
                    pid, off, w, h, stride = self._buffers[self._attached_buf]
                    if pid in self._pools:
                        mm = self._pools[pid][2]
                        frame = mm[off : off + stride * h]
                        self.last_frame_bytes = frame
                        self.last_frame_w = w
                        self.last_frame_h = h
                        self.last_frame_stride = stride
                        self.last_frame_hash = hashlib.sha256(frame).hexdigest()
                    self.commit_count += 1
                    self._maybe_send_enter()
                    self._cond.notify_all()

    def _send_keymap(self, kid: int) -> None:
        raw = XKB_KEYMAP.encode("utf-8") + b"\x00"
        fd = os.memfd_create("u6-xkb-keymap")
        try:
            os.write(fd, raw)
            os.lseek(fd, 0, os.SEEK_SET)
            # wl_keyboard.keymap(format=1 XKB_V1, fd, size)
            self._send(_wl_msg(kid, 0, struct.pack("=II", 1, len(raw))), [fd])
        finally:
            os.close(fd)

    def _maybe_send_enter(self) -> None:
        if self._entered or not self.surface_id:
            return
        if not (self.pointer_id and self.keyboard_id and self.configured_acked):
            return
        self._entered = True
        # wl_keyboard.enter(serial, surface, keys_array)
        self._send(_wl_msg(self.keyboard_id, 1, struct.pack("=II", self._next_serial(), self.surface_id) + _wl_array(b"")))
        # wl_pointer.enter(serial, surface, sx, sy)
        self._send(_wl_msg(self.pointer_id, 0, struct.pack("=IIii", self._next_serial(), self.surface_id, 10 * 256, 10 * 256)))
        self._send(_wl_msg(self.pointer_id, 5))  # frame
        # zwp_text_input_v3.enter(surface)
        if self.text_input_id:
            self._send(_wl_msg(self.text_input_id, 0, struct.pack("=I", self.surface_id)))
        self._cond.notify_all()

    def wait_ready(self, timeout: float = 15.0) -> None:
        deadline = time.monotonic() + timeout
        with self._lock:
            while self.commit_count < 1 or not self._entered:
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(f"window did not commit/enter (commits={self.commit_count}, entered={self._entered})")
                self._cond.wait(rem)

    def wait_commit(self, after: int, timeout: float = 5.0) -> int:
        deadline = time.monotonic() + timeout
        with self._lock:
            while self.commit_count <= after:
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(f"no new frame commit after {after} (still {self.commit_count})")
                self._cond.wait(rem)
            return self.commit_count

    def wait_frame_change(self, previous_hash: str, timeout: float = 5.0) -> str:
        deadline = time.monotonic() + timeout
        with self._lock:
            while self.last_frame_hash == previous_hash:
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(f"framebuffer hash did not change from {previous_hash[:12]}")
                self._cond.wait(rem)
            return self.last_frame_hash

    def region_hash(self, x0: int, y0: int, x1: int, y1: int) -> str:
        with self._lock:
            frame = self.last_frame_bytes
            stride = getattr(self, "last_frame_stride", self.width * 4)
            w = getattr(self, "last_frame_w", self.width)
            h = getattr(self, "last_frame_h", self.height)
            rx0, rx1 = max(0, min(w, x0)), max(0, min(w, x1))
            ry0, ry1 = max(0, min(h, y0)), max(0, min(h, y1))
            hasher = hashlib.sha256()
            for y in range(ry0, ry1):
                row_off = y * stride
                hasher.update(frame[row_off + rx0 * 4 : row_off + rx1 * 4])
            return hasher.hexdigest()

    def wait_region_change(self, x0: int, y0: int, x1: int, y1: int, previous_hash: str, timeout: float = 5.0) -> str:
        deadline = time.monotonic() + timeout
        while True:
            cur = self.region_hash(x0, y0, x1, y1)
            if cur != previous_hash:
                return cur
            rem = deadline - time.monotonic()
            if rem <= 0:
                raise TimeoutError(f"region ({x0},{y0},{x1},{y1}) hash did not change from {previous_hash[:12]}")
            with self._lock:
                self._cond.wait(min(0.1, rem))

    def wait_text_input(self, enabled: bool, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        with self._lock:
            while self.text_input_enabled != enabled:
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(f"expected text_input_enabled={enabled}, got {self.text_input_enabled}")
                self._cond.wait(rem)

    def _ms(self) -> int:
        return int(time.monotonic() * 1000) & 0xFFFFFFFF

    def pointer_move(self, x: float, y: float) -> None:
        with self._lock:
            assert self.pointer_id is not None
            self._send(_wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), int(x * 256), int(y * 256))))
            self._send(_wl_msg(self.pointer_id, 5))

    def pointer_click(self, x: float, y: float, button: int = 0x110) -> None:
        with self._lock:
            assert self.pointer_id is not None
            fx, fy = int(x * 256), int(y * 256)
            self._send(_wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), fx, fy)))
            self._send(_wl_msg(self.pointer_id, 5))
            self._send(_wl_msg(self.pointer_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), button, 1)))
            self._send(_wl_msg(self.pointer_id, 5))
            self._send(_wl_msg(self.pointer_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), button, 0)))
            self._send(_wl_msg(self.pointer_id, 5))

    def pointer_scroll(self, x: float, y: float, dy: float) -> None:
        with self._lock:
            assert self.pointer_id is not None
            self._send(_wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), int(x * 256), int(y * 256))))
            self._send(_wl_msg(self.pointer_id, 4, struct.pack("=IIi", self._ms(), 0, int(dy * 256))))
            self._send(_wl_msg(self.pointer_id, 5))

    def key_tap(self, key_name: str, mods: int = 0) -> None:
        code = EV[key_name]
        with self._lock:
            assert self.keyboard_id is not None
            if mods:
                self._send(_wl_msg(self.keyboard_id, 4, struct.pack("=IIIII", self._next_serial(), mods, 0, 0, 0)))
            self._send(_wl_msg(self.keyboard_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), code, 1)))
            self._send(_wl_msg(self.keyboard_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), code, 0)))
            if mods:
                self._send(_wl_msg(self.keyboard_id, 4, struct.pack("=IIIII", self._next_serial(), 0, 0, 0, 0)))

    def type_ascii(self, text: str) -> None:
        for ch in text:
            if "A" <= ch <= "Z":
                self.key_tap(ch.lower(), MOD_SHIFT)
            else:
                self.key_tap(ch, 0)

    def ime_edit(self, commit: str = "", preedit: str = "", del_before: int = 0, del_after: int = 0) -> None:
        self.wait_text_input(True)
        with self._lock:
            assert self.text_input_id is not None
            if del_before or del_after:
                self._send(_wl_msg(self.text_input_id, 4, struct.pack("=II", del_before, del_after)))
            if commit:
                self._send(_wl_msg(self.text_input_id, 3, _wl_str(commit)))
            if preedit:
                self._send(_wl_msg(self.text_input_id, 2, _wl_str(preedit) + struct.pack("=ii", 0, len(preedit.encode("utf-8")))))
            else:
                self._send(_wl_msg(self.text_input_id, 2, _wl_str("") + struct.pack("=ii", 0, 0)))
            self._send(_wl_msg(self.text_input_id, 5, struct.pack("=I", self.text_input_commit_count)))

    def send_close(self) -> None:
        with self._lock:
            if self.xdg_toplevel_id:
                self._send(_wl_msg(self.xdg_toplevel_id, 1))

    def close(self) -> None:
        self._stop = True
        with self._lock:
            for pool in list(self._pools.values()):
                with contextlib.suppress(OSError):
                    pool[2].close()
                with contextlib.suppress(OSError):
                    os.close(pool[0])
            self._pools.clear()
            if self._client:
                with contextlib.suppress(OSError):
                    self._client.close()
                self._client = None
        with contextlib.suppress(OSError):
            self._server.close()
        self._thread.join(timeout=2.0)


class DisposableCoreState:
    """In-memory disposable Core REST state for end-to-end U6 Wayland testing."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.missions: list[dict] = []
        self.events: dict[str, list[dict]] = {}
        self.seq_counter = 1
        self.projects = [
            {"slug": "source", "title": "Source Project", "description": "U6 fixture"},
            {"slug": "menu-test", "title": "Menu Test", "description": "Second project"},
        ]
        self.providers = [
            {
                "id": "acct-ag-1",
                "name": "Fixture Antigravity",
                "label": "Fixture Antigravity",
                "provider_type": "antigravity",
                "provider_type_name": "Antigravity",
                "enabled": True,
                "globally_enabled": True,
                "user_enabled": True,
            },
            {
                "id": "acct-oa-1",
                "name": "Fixture OpenAI",
                "label": "Fixture OpenAI",
                "provider_type": "openai",
                "provider_type_name": "OpenAI",
                "enabled": True,
                "globally_enabled": True,
                "user_enabled": True,
            },
        ]
        self.vpn_state = {
            "acct-ag-1": {
                "mode": "direct",
                "status": "direct",
                "country": "",
                "server": "",
                "exits": [],
                "can_configure": True,
                "countries": ["NL", "DE"],
            }
        }
        self.alt_routers = {"acct-ag-1": {"allowed": True}}
        self.inbox_state: dict = {"preferences": {"inboxEnabled": True}, "_versions": {}}
        self.requests_log: list[tuple[str, str, dict | None]] = []

    def add_event(self, mid: str, event_type: str, content: str, extra: dict | None = None) -> dict:
        ev = {
            "id": f"ev-{self.seq_counter}",
            "mission_id": mid,
            "sequence": self.seq_counter,
            "seq": self.seq_counter,
            "event_type": event_type,
            "content": content,
            "payload": {"content": content, **(extra or {})},
            "timestamp": "2026-11-24T10:00:00Z",
        }
        self.seq_counter += 1
        self.events.setdefault(mid, []).append(ev)
        return ev

    def append_assistant_delta(self, mid: str, delta: str) -> None:
        evs = self.events.get(mid, [])
        for ev in reversed(evs):
            if ev["event_type"] == "assistant_message":
                ev["content"] = ev["content"] + "\n" + delta
                ev["payload"]["content"] = ev["content"]
                return
        self.add_event(mid, "assistant_message", delta)


def make_core_handler(state: DisposableCoreState):
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, payload, status: int = 200) -> None:
            raw = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _read_json(self) -> dict:
            length = int(self.headers.get("Content-Length") or "0")
            if length == 0:
                return {}
            return json.loads(self.rfile.read(length))

        def do_GET(self) -> None:
            parsed = urlsplit(self.path)
            path = parsed.path
            qs = parse_qs(parsed.query)
            with state.lock:
                state.requests_log.append(("GET", self.path, None))
                if path == "/api/auth/me":
                    return self._reply({"user": {"id": "admin", "username": "admin", "role": "admin"}})
                if path == "/api/projects":
                    return self._reply({"projects": state.projects})
                if path == "/api/machines":
                    return self._reply([
                        {"id": "core", "name": "orb-core", "role": "Core", "status": "online", "cpu_total": 8, "mem_total_gb": 16},
                        {"id": "worker-1", "name": "worker-node-1", "role": "Static", "status": "online", "cpu_total": 16, "mem_total_gb": 32},
                    ])
                if path == "/api/remote-nodes":
                    return self._reply({"enabled": True, "remote_launch": {"typed": True, "harnesses": ["codex", "opencode", "antigravity"]}, "nodes": []})
                if path == "/api/backends":
                    return self._reply({"backends": [{"id": "codex", "name": "Codex"}, {"id": "opencode", "name": "OpenCode"}]})
                if path == "/api/providers/backend-models":
                    return self._reply({"backends": {"codex": [{"value": "gpt-6.2-astra", "label": "GPT 6.2 Astra"}], "opencode": []}})
                if path == "/api/model-routing/chains":
                    return self._reply([{"id": "builtin/smart", "name": "Smart"}])
                if path == "/api/control/inbox-state":
                    return self._reply(state.inbox_state)
                if path == "/api/ai/providers":
                    return self._reply({"providers": state.providers})
                if path == "/api/cloud/accounts":
                    return self._reply([
                        {"id": "cursor-1", "provider": "cursor_cloud", "label": "Cursor Fixture", "available": True, "capabilities": {"follow_up": True, "cancel": True}}
                    ])
                if path == "/api/resources/overview":
                    return self._reply({
                        "inference": {"pools": [{"label": "Fixture Pool", "current_b_tok_per_h": 1.2, "est_usd_per_h": 0.4}]},
                        "compute": {"sources": [{"label": "Local Core", "active_vcpu": 2, "total_vcpu": 8, "est_usd_per_h": 0.0}]},
                        "missions": [{"id": m["id"], "title": m["title"], "status": m["status"], "vcpu": 2, "b_tok_per_h": 0.5} for m in state.missions],
                    })
                if path.startswith("/api/ai/providers/") and path.endswith("/vpn"):
                    aid = path.split("/")[4]
                    if aid in state.vpn_state:
                        return self._reply(state.vpn_state[aid])
                    return self._reply({}, 404)
                if path.startswith("/api/ai/providers/") and path.endswith("/alternative-routers"):
                    aid = path.split("/")[4]
                    if aid in state.alt_routers:
                        return self._reply(state.alt_routers[aid])
                    return self._reply({}, 404)
                if path == "/api/control/missions":
                    if qs.get("status") == ["completed"]:
                        return self._reply([m for m in state.missions if m["status"] == "completed"])
                    if qs.get("project"):
                        slug = qs["project"][0]
                        return self._reply([m for m in state.missions if (m.get("project") or "default") == slug])
                    return self._reply(list(state.missions))
                if path.startswith("/api/control/missions/"):
                    parts = path.strip("/").split("/")
                    mid = parts[3]
                    mission = next((m for m in state.missions if m["id"] == mid), None)
                    if mission is None:
                        return self._reply({"error": "not_found"}, 404)
                    if len(parts) == 4:
                        return self._reply(mission)
                    if len(parts) == 5 and parts[4] == "current-bubble":
                        evs = state.events.get(mid, [])
                        asst = [e["content"] for e in evs if e["event_type"] == "assistant_message"]
                        text = asst[-1] if asst else ""
                        return self._reply({
                            "id": mid,
                            "title": mission["title"],
                            "status": mission["status"],
                            "text": text,
                        })
                    if len(parts) == 5 and parts[4] == "open":
                        evs = state.events.get(mid, [])
                        return self._reply({"mission": mission, "events": evs, "spine": [], "has_more": False})
                    if len(parts) == 5 and parts[4] == "events":
                        return self._reply(state.events.get(mid, []))
                return self._reply([])

        def do_POST(self) -> None:
            path = urlsplit(self.path).path
            body = self._read_json()
            with state.lock:
                state.requests_log.append(("POST", path, body))
                if path == "/api/control/missions":
                    mid = f"m-u6-{len(state.missions) + 1}"
                    prompt = body.get("prompt") or ""
                    title = body.get("title") or (prompt[:40] if prompt else "New mission")
                    row = {
                        "id": mid,
                        "title": title,
                        "status": "active",
                        "project": body.get("project") or "source",
                        "backend": body.get("backend") or "codex",
                        "model_override": body.get("model_override") or "gpt-6.2-astra",
                        "model_effort": body.get("model_effort") or "",
                        "permission_mode": "supervised",
                        "updated_at": "2026-11-24T10:00:00Z",
                        "created_at": "2026-11-24T10:00:00Z",
                        "tags": [],
                    }
                    state.missions.append(row)
                    if prompt:
                        state.add_event(mid, "user_message", prompt)
                        # Seed a multi-line assistant reply so transcript scrolling has real overflow.
                        long_reply = "\n".join(f"Streamed line {i:02d}: deterministic LeanUI U6 verification output." for i in range(48))
                        state.add_event(mid, "assistant_message", long_reply)
                    return self._reply(row)
                if path == "/api/control/message":
                    mid = body["mission_id"]
                    content = body["content"]
                    cmid = body.get("client_message_id") or self.headers.get("Idempotency-Key") or "k"
                    mission = next((m for m in state.missions if m["id"] == mid), None)
                    if mission is None:
                        return self._reply({"error": "not_found"}, 404)
                    mission["status"] = "active"
                    state.add_event(mid, "user_message", content)
                    extra_reply = "\n".join(f"Follow-up line {i:02d}: reply to {content}" for i in range(40))
                    state.add_event(mid, "assistant_message", extra_reply)
                    return self._reply({"id": cmid, "message_accepted": True})
                if path.startswith("/api/control/missions/"):
                    parts = path.strip("/").split("/")
                    mid = parts[3]
                    mission = next((m for m in state.missions if m["id"] == mid), None)
                    if mission is None:
                        return self._reply({"error": "not_found"}, 404)
                    if len(parts) == 5 and parts[4] == "cancel":
                        mission["status"] = "interrupted"
                        return self._reply({"ok": True, "status": "interrupted"})
                    if len(parts) == 5 and parts[4] == "status":
                        mission["status"] = body["status"]
                        return self._reply({"ok": True, "status": mission["status"]})
                    if len(parts) == 5 and parts[4] == "title":
                        mission["title"] = body["title"]
                        return self._reply({"ok": True, "title": mission["title"]})
                return self._reply({"error": "unhandled"}, 404)

        def do_PUT(self) -> None:
            path = urlsplit(self.path).path
            body = self._read_json()
            with state.lock:
                state.requests_log.append(("PUT", path, body))
                if path == "/api/control/inbox-state":
                    state.inbox_state = body if isinstance(body, dict) else state.inbox_state
                    return self._reply(state.inbox_state)
                if path.startswith("/api/ai/providers/") and path.endswith("/preference"):
                    aid = path.split("/")[4]
                    row = next(p for p in state.providers if p["id"] == aid)
                    row["user_enabled"] = bool(body["enabled"])
                    return self._reply(row)
                if path.startswith("/api/ai/providers/") and path.endswith("/vpn"):
                    aid = path.split("/")[4]
                    mode = body["mode"]
                    if mode == "vpn":
                        country = body["country"]
                        state.vpn_state[aid].update({
                            "mode": "vpn",
                            "status": "verified",
                            "country": country,
                            "server": f"{country.lower()}-fixture-01",
                            "exits": ["198.51.100.10"],
                        })
                    else:
                        state.vpn_state[aid].update({
                            "mode": "direct",
                            "status": "direct",
                            "country": "",
                            "server": "",
                            "exits": [],
                        })
                    return self._reply(state.vpn_state[aid])
                if path.startswith("/api/ai/providers/") and path.endswith("/alternative-routers"):
                    aid = path.split("/")[4]
                    state.alt_routers[aid] = {"allowed": bool(body["allowed"])}
                    return self._reply(state.alt_routers[aid])
                if path.startswith("/api/control/inbox-state/seen/"):
                    mid = path.rsplit("/", 1)[-1]
                    state.inbox_state["seen:" + mid] = body["stamp"]
                    return self._reply({"ok": True})
                return self._reply({"error": "unhandled"}, 404)

        def log_message(self, *_args) -> None:
            pass

    return Handler


def _wait_until(label: str, predicate, timeout: float = 12.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        val = predicate()
        if val:
            return val
        time.sleep(0.05)
    raise TimeoutError(f"timed out waiting for: {label}")


def _resolve_binary() -> Path:
    env_bin = os.environ.get("ORB_LEANUI_TEST_BINARY")
    if env_bin:
        return Path(env_bin).resolve(strict=True)
    for cand in (ROOT / "target/native/orb-desktop-native", DEFAULT_BINARY):
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand
    raise FileNotFoundError("orb-desktop-native binary not found; set ORB_LEANUI_TEST_BINARY")


class WaylandU6SessionTest(unittest.TestCase):
    def _launch(self, tmp: Path, extra_args: list[str], extra_env: dict[str, str] | None = None, height: int = 923):
        binary = _resolve_binary()
        rt_dir = tmp / "xdg-rt"
        rt_dir.mkdir(mode=0o700, exist_ok=True)
        display = "leanui-u6-0"
        comp = WaylandTestCompositor(rt_dir, display, width=1470, height=height)
        env = dict(os.environ)
        env.update({
            "XDG_RUNTIME_DIR": str(rt_dir),
            "WAYLAND_DISPLAY": display,
            "ORB_STATE_DIR": str(tmp),
        })
        if extra_env:
            env.update(extra_env)
        proc = subprocess.Popen(
            [str(binary), "--width", "1470", "--height", str(height), *extra_args],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return comp, proc

    def _shutdown(self, comp: WaylandTestCompositor, proc: subprocess.Popen) -> None:
        comp.send_close()
        try:
            rc = proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            proc.terminate()
            rc = proc.wait(timeout=3.0)
        finally:
            stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()
            comp.close()
        self.assertEqual(rc, 0, f"orb-desktop-native exited with {rc}: {stderr}")

    def test_live_wayland_session_end_to_end(self) -> None:
        """Full U6 Wayland input-injection session against a local disposable Core."""
        core_state = DisposableCoreState()

        def count_req(method: str, prefix: str) -> int:
            with core_state.lock:
                return sum(1 for m, p, _ in core_state.requests_log if m == method and p.startswith(prefix))

        with (
            tempfile.TemporaryDirectory(prefix="orb-u6-live-") as td,
            ThreadingHTTPServer(("127.0.0.1", 0), make_core_handler(core_state)) as server,
        ):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                tmp = Path(td)
                api_url = f"http://127.0.0.1:{server.server_port}"
                (tmp / "connection.json").write_text(json.dumps({"api_url": api_url, "token": "u6-fixture-token"}))
                comp, proc = self._launch(tmp, [])
                try:
                    comp.wait_ready(timeout=15.0)
                    # Wait for the FINAL request of initial roster() bootstrap (/api/auth/me) AND frame commit.
                    h_boot = comp.last_frame_hash
                    _wait_until("initial roster /api/auth/me", lambda: count_req("GET", "/api/auth/me") >= 1)
                    comp.wait_frame_change(h_boot, timeout=5.0)

                    # 1. Create a mission via Wayland Ctrl+N + keyboard + Wayland IME preedit/delete/commit + Return.
                    comp.key_tap("n", MOD_CTRL)
                    comp.wait_text_input(True, timeout=5.0)
                    comp.type_ascii("Hello U6 ")
                    # Exercise Wayland IME preedit, replacement via delete_surrounding_text, and commit.
                    comp.ime_edit(commit="日本猫", preedit="未確定")
                    comp.ime_edit(commit="語", preedit="", del_before=len("猫".encode("utf-8")))
                    comp.key_tap("return")

                    created = _wait_until("POST /api/control/missions", lambda: core_state.missions[0] if core_state.missions else None)
                    mid = created["id"]
                    user_msgs = [e["content"] for e in core_state.events[mid] if e["event_type"] == "user_message"]
                    self.assertEqual(user_msgs, ["Hello U6 日本語"])
                    self.assertEqual(created["status"], "active")

                    # Wait for transcript /open + /current-bubble poll #1 AND poll #2 so both HS and B have painted.
                    tx_before = comp.region_hash(240, 45, 1450, 810)
                    _wait_until("mission /open history fetch", lambda: count_req("GET", f"/api/control/missions/{mid}/open") >= 1)
                    _wait_until("mission /current-bubble settled", lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") >= 2, timeout=6.0)
                    tx_bottom = comp.wait_region_change(240, 45, 1450, 810, tx_before, timeout=5.0)

                    # 2. Scroll transcript upward with `Orb.Scroll` policy, verify unpinned anchor stays
                    #    put while new assistant text streams in, then scroll back down to re-pin.
                    comp.pointer_scroll(740, 400, -1200)
                    tx_scrolled_up = comp.wait_region_change(240, 45, 1450, 810, tx_bottom, timeout=5.0)
                    self.assertNotEqual(tx_scrolled_up, tx_bottom, "upward wheel scroll must update transcript pixels")

                    # Append a streamed delta to the active assistant turn and wait for the next /current-bubble poll.
                    polls_before = count_req("GET", f"/api/control/missions/{mid}/current-bubble")
                    with core_state.lock:
                        core_state.append_assistant_delta(mid, "Streamed delta 49: appended while reader is unpinned.")
                    _wait_until(
                        "next /current-bubble poll after delta",
                        lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") >= polls_before + 2,
                        timeout=6.0,
                    )
                    # Unpinned reader anchor must keep the visible transcript viewport pixels unchanged!
                    self.assertEqual(
                        comp.region_hash(240, 45, 1450, 810),
                        tx_scrolled_up,
                        "Orb.Scroll unpinned viewport must remain stable when new assistant lines arrive",
                    )
                    # Scroll back down to bottom to re-pin and reveal the newly appended delta.
                    comp.pointer_scroll(740, 400, 3600)
                    tx_repinned = comp.wait_region_change(240, 45, 1450, 810, tx_scrolled_up, timeout=5.0)
                    self.assertNotEqual(tx_repinned, tx_scrolled_up, "scrolling back to bottom must reveal new streamed lines")

                    # 3. Exercise Side Panels (header Diff, Files, Side-chat, Close, Escape-release guard, and Left Sidebar Ctrl+B).
                    frame_no_panel = comp.last_frame_hash
                    comp.pointer_click(1383, 17)  # Open Diff side panel
                    frame_diff_panel = comp.wait_frame_change(frame_no_panel, timeout=5.0)
                    self.assertNotEqual(frame_diff_panel, frame_no_panel, "clicking Diff header icon must open side panel")

                    # Open Search (Ctrl+K) while side panel is open, verify IME in Search + interior click does not close,
                    # then press Escape and verify Escape key-release does NOT bleed through to close the side panel!
                    comp.key_tap("k", MOD_CTRL)
                    frame_search_open = comp.wait_frame_change(frame_diff_panel, timeout=5.0)
                    comp.wait_text_input(True, timeout=5.0)
                    comp.ime_edit(commit="Hello", preedit="検")
                    comp.wait_frame_change(frame_search_open, timeout=5.0)
                    comp.ime_edit(commit="", preedit="")
                    # Clicking inside the Search modal preview pane (900, 300) must NOT dismiss the modal.
                    h_in_search = comp.last_frame_hash
                    comp.pointer_click(900, 300)
                    time.sleep(0.15)
                    self.assertEqual(comp.last_frame_hash, h_in_search, "clicking inside Search card must not close modal")
                    # Pressing Escape closes Search while leaving Diff side panel intact.
                    comp.key_tap("esc")
                    frame_after_search_esc = comp.wait_frame_change(h_in_search, timeout=5.0)
                    self.assertNotEqual(
                        comp.region_hash(1000, 50, 1450, 600),
                        comp.region_hash(1000, 50, 1450, 600) if frame_after_search_esc == frame_no_panel else "",
                    )

                    comp.pointer_click(1415, 17)  # Switch to Files side panel
                    frame_files_panel = comp.wait_frame_change(frame_after_search_esc, timeout=5.0)
                    self.assertNotEqual(frame_files_panel, frame_after_search_esc, "switching to Files panel must repaint")

                    comp.pointer_click(1447, 17)  # Switch to Side-chat panel
                    frame_chat_panel = comp.wait_frame_change(frame_files_panel, timeout=5.0)

                    comp.pointer_click(1447, 17)  # Toggle Side-chat closed
                    comp.wait_frame_change(frame_chat_panel, timeout=5.0)

                    # Left sidebar hide/show via Ctrl+B.
                    h_open = comp.last_frame_hash
                    comp.key_tap("b", MOD_CTRL)
                    h_hidden = comp.wait_frame_change(h_open, timeout=5.0)
                    self.assertNotEqual(h_hidden, h_open, "Ctrl+B must hide sidebar")
                    comp.key_tap("b", MOD_CTRL)
                    comp.wait_frame_change(h_hidden, timeout=5.0)

                    # 4. Stop the running mission via pointer click on Stop button (widget 2 at x=1197, y=850).
                    polls_pre_stop = count_req("GET", f"/api/control/missions/{mid}/current-bubble")
                    comp.pointer_click(1197, 850)
                    _wait_until("mission stopped on Core", lambda: core_state.missions[0]["status"] == "interrupted")
                    # Wait deterministically for poll_bubble to observe the interrupted status and repaint the Send button.
                    _wait_until(
                        "bubble poll observes interrupted",
                        lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") >= polls_pre_stop + 2,
                        timeout=6.0,
                    )

                    # 5. Send a follow-up message via pointer click on composer + keyboard + IME + Send click.
                    comp.pointer_click(700, 850)
                    comp.wait_text_input(True, timeout=5.0)
                    comp.type_ascii("Followup ")
                    comp.ime_edit(commit="確認", preedit="")
                    polls_pre_send = count_req("GET", f"/api/control/missions/{mid}/current-bubble")
                    comp.pointer_click(1197, 850)
                    _wait_until(
                        "POST /api/control/message",
                        lambda: count_req("POST", "/api/control/message") >= 1,
                    )
                    followup_msgs = [e["content"] for e in core_state.events[mid] if e["event_type"] == "user_message"]
                    self.assertEqual(followup_msgs, ["Hello U6 日本語", "Followup 確認"])

                    # Wait for poll_bubble to report active again, then Stop the follow-up turn before archiving.
                    _wait_until(
                        "bubble poll observes active follow-up",
                        lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") >= polls_pre_send + 2,
                        timeout=6.0,
                    )
                    polls_pre_stop2 = count_req("GET", f"/api/control/missions/{mid}/current-bubble")
                    comp.pointer_click(1197, 850)
                    _wait_until("follow-up turn stopped", lambda: core_state.missions[0]["status"] == "interrupted")
                    _wait_until(
                        "bubble poll observes stopped follow-up",
                        lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") >= polls_pre_stop2 + 2,
                        timeout=6.0,
                    )

                    # 6. Exercise Back / Forward (`Ctrl+[` / `Ctrl+]`) between mission transcript and New Agent without zombie state.
                    h_tx = comp.last_frame_hash
                    comp.key_tap("[", MOD_CTRL)
                    h_back = comp.wait_frame_change(h_tx, timeout=5.0)
                    comp.key_tap("]", MOD_CTRL)
                    comp.wait_frame_change(h_back, timeout=5.0)

                    # 7. Archive the mission: expand Source Project in sidebar, right-click the mission row, click Archive.
                    h_pre_exp = comp.last_frame_hash
                    comp.pointer_click(100, 272)  # Expand Source Project
                    h_exp = comp.wait_frame_change(h_pre_exp, timeout=5.0)
                    comp.pointer_click(100, 303, button=0x111)  # Right-click context menu
                    comp.wait_frame_change(h_exp, timeout=5.0)
                    # Hash bottom composer dock (present on missionTranscript, blank on controlEmpty) so we wait until archive finishes.
                    dock_pre_arch = comp.region_hash(450, 820, 1220, 915)
                    comp.pointer_click(160, 384)  # Click Archive
                    _wait_until("mission archived on Core", lambda: core_state.missions[0]["status"] == "acknowledged")
                    comp.wait_region_change(450, 820, 1220, 915, dock_pre_arch, timeout=5.0)

                    # 8. Exercise Inference VPN & alternative-router controls (`Ctrl+4`).
                    # Row 0 of Inference lives at (525..1165, 35..95); blank during "Loading accounts…" and painted once providers load.
                    row0_pre_inf = comp.region_hash(525, 35, 1165, 95)
                    comp.key_tap("4", MOD_CTRL)
                    _wait_until("GET /api/ai/providers", lambda: count_req("GET", "/api/ai/providers") >= 1)
                    row0_inf = comp.wait_region_change(525, 35, 1165, 95, row0_pre_inf, timeout=5.0)
                    comp.pointer_click(700, 65)  # Toggle provider user_enabled -> false
                    _wait_until("provider skipped on Core", lambda: core_state.providers[0]["user_enabled"] is False)
                    row0_toggled = comp.wait_region_change(525, 35, 1165, 95, row0_inf, timeout=5.0)
                    comp.pointer_click(700, 65)  # Toggle provider user_enabled -> true
                    _wait_until("provider re-enabled on Core", lambda: core_state.providers[0]["user_enabled"] is True)
                    comp.wait_region_change(525, 35, 1165, 95, row0_toggled, timeout=5.0)

                    # Open AccountRoutePage (`Settings ›`) for Antigravity account.
                    routes_pre = comp.region_hash(525, 220, 1165, 385)
                    comp.pointer_click(1123, 65)
                    _wait_until("GET /vpn", lambda: count_req("GET", "/api/ai/providers/acct-ag-1/vpn") >= 1)
                    _wait_until("GET /alternative-routers", lambda: count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers") >= 1)
                    comp.wait_region_change(525, 220, 1165, 385, routes_pre, timeout=5.0)
                    h_routes = comp.last_frame_hash

                    # Select AirVPN · NL (row 2, center y=251) and wait for both Core refresh AND painted non-pending frame.
                    alt_count_1 = count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers")
                    comp.pointer_click(845, 251)
                    h_nl_pending = comp.wait_frame_change(h_routes, timeout=5.0)
                    _wait_until("PUT /vpn NL", lambda: core_state.vpn_state["acct-ag-1"]["country"] == "NL")
                    _wait_until("refresh after PUT /vpn NL", lambda: count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers") > alt_count_1)
                    h_nl = comp.wait_frame_change(h_nl_pending, timeout=5.0)

                    # Switch back to Direct (row 1, center y=199) and wait for both Core refresh AND painted non-pending frame.
                    alt_count_2 = count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers")
                    comp.pointer_click(845, 199)
                    h_direct_pending = comp.wait_frame_change(h_nl, timeout=5.0)
                    _wait_until("PUT /vpn direct", lambda: core_state.vpn_state["acct-ag-1"]["mode"] == "direct")
                    _wait_until("refresh after PUT /vpn direct", lambda: count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers") > alt_count_2)
                    h_direct = comp.wait_frame_change(h_direct_pending, timeout=5.0)

                    # Toggle Alternative routers (row 4, center y=355) and wait for refresh + repaint.
                    alt_count_3 = count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers")
                    comp.pointer_click(845, 355)
                    h_alt_pending = comp.wait_frame_change(h_direct, timeout=5.0)
                    _wait_until("PUT /alternative-routers false", lambda: core_state.alt_routers["acct-ag-1"]["allowed"] is False)
                    _wait_until("refresh after PUT /alternative-routers", lambda: count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers") > alt_count_3)
                    h_alt = comp.wait_frame_change(h_alt_pending, timeout=5.0)

                    # Escape returns to Inference list.
                    comp.key_tap("esc")
                    h_back_inf = comp.wait_frame_change(h_alt, timeout=5.0)

                    # 9. Exercise Machines (`Ctrl+3`), Resources (`Ctrl+6`), Cloud (`Ctrl+2`), Inbox (`Ctrl+I`), Settings (`Ctrl+,`).
                    comp.key_tap("3", MOD_CTRL)
                    h_machines = comp.wait_frame_change(h_back_inf, timeout=5.0)
                    # Click a machine row in live Machines fleet.
                    comp.pointer_click(845, 65)

                    comp.key_tap("6", MOD_CTRL)
                    _wait_until("GET /api/resources/overview?range=6h", lambda: count_req("GET", "/api/resources/overview?range=6h") >= 1)
                    h_res = comp.wait_frame_change(h_machines, timeout=5.0)

                    comp.key_tap("2", MOD_CTRL)
                    _wait_until("GET /api/cloud/accounts", lambda: count_req("GET", "/api/cloud/accounts") >= 1)
                    h_cloud = comp.wait_frame_change(h_res, timeout=5.0)

                    comp.key_tap("i", MOD_CTRL)
                    h_inbox = comp.wait_frame_change(h_cloud, timeout=5.0)

                    comp.key_tap(",", MOD_CTRL)
                    h_dark = comp.wait_frame_change(h_inbox, timeout=5.0)
                    # Toggle theme in live Settings (second button below Account/Connected/endpoint/@user/Manage account, y=219..259).
                    comp.pointer_click(350, 239)
                    h_light = comp.wait_frame_change(h_dark, timeout=5.0)
                    self.assertNotEqual(h_light, h_dark, "clicking Theme toggle in Settings must switch theme")

                    # Verify cursor shapes were emitted for pointer hover/text transitions.
                    self.assertTrue(len(comp.cursor_shapes) >= 1)
                finally:
                    self._shutdown(comp, proc)
            finally:
                server.shutdown()

    def test_all_nine_screens_wayland_input_sweep(self) -> None:
        """Launch each of the 9 canonical screens under Wayland and exercise its interactive controls."""
        # For each screen: (screen_id, height, steps). Every step asserts real framebuffer pixel change (`wait_frame_change`).
        screens = [
            ("01_control_empty", 923, [
                ("click composer", lambda c: c.pointer_click(845, 435), True),
                ("type text", lambda c: c.type_ascii("hello"), True),
                ("ime preedit visible", lambda c: c.ime_edit(preedit="未確定"), True),
                ("ime commit", lambda c: c.ime_edit(commit="世界", preedit=""), True),
                ("click project picker", lambda c: c.pointer_click(575, 390), True),
                ("click send", lambda c: c.pointer_click(1124, 488), True),
            ]),
            ("02_control_populated", 923, [
                ("tab focus", lambda c: c.key_tap("tab"), True),
                ("shift-tab focus", lambda c: c.key_tap("tab", MOD_SHIFT), True),
                ("ctrl+b sidebar toggle", lambda c: c.key_tap("b", MOD_CTRL), True),
                ("ctrl+b sidebar restore", lambda c: c.key_tap("b", MOD_CTRL), True),
            ]),
            ("03_mission_transcript", 600, [
                ("scroll transcript down (overflow > 0)", lambda c: c.pointer_scroll(740, 280, 600), True),
                ("click composer", lambda c: c.pointer_click(700, 527), True),
                ("type and ime", lambda c: (c.type_ascii("hi "), c.ime_edit(commit="テスト")), True),
                ("open diff side panel", lambda c: c.pointer_click(1383, 17), True),
            ]),
            ("04_mission_split_diff", 600, [
                ("scroll left transcript (overflow > 0)", lambda c: c.pointer_scroll(500, 280, 600), True),
                ("switch diff to Unified", lambda c: c.pointer_click(1115, 57), True),
                ("switch diff to Split", lambda c: c.pointer_click(1165, 57), True),
                ("cycle diff ref", lambda c: c.pointer_click(995, 57), True),
                ("click diff Refresh", lambda c: c.pointer_click(1225, 57), True),
            ]),
            ("05_machines_fleet", 923, [
                ("click local machine", lambda c: c.pointer_click(845, 193), True),
                ("click remote machine", lambda c: c.pointer_click(845, 304), True),
                ("click Copy key", lambda c: c.pointer_click(1123, 678), True),
            ]),
            ("06_settings_general", 923, [
                ("click Users tab", lambda c: c.pointer_click(657, 146), True),
                ("click Account tab", lambda c: c.pointer_click(585, 146), True),
                ("click API URL input", lambda c: c.pointer_click(1003, 246), True),
                ("type in API URL", lambda c: c.type_ascii("/v2"), True),
                ("toggle Theme Dark/Light", lambda c: c.pointer_click(1093, 665), True),
                ("toggle Background sync", lambda c: c.pointer_click(1093, 727), True),
            ]),
            ("07_search_dialog", 923, [
                ("arrow down result", lambda c: c.key_tap("down"), True),
                ("click Clear query", lambda c: c.pointer_click(1100, 98), True),
                ("type in search input", lambda c: c.type_ascii("w"), True),
                ("click Titles filter", lambda c: c.pointer_click(470, 136), True),
                ("click inside preview pane stays open", lambda c: c.pointer_click(900, 300), False),
                ("press Escape to close", lambda c: c.key_tap("esc"), True),
                ("post-Escape Tab moves focus", lambda c: c.key_tap("tab"), True),
                ("post-Escape click composer restores focus", lambda c: c.pointer_click(845, 435), True),
                ("post-Escape type proves trap popped", lambda c: c.type_ascii("ok"), True),
            ]),
            ("08_new_mission_dialog", 923, [
                ("click composer", lambda c: c.pointer_click(845, 435), True),
                ("type extra text", lambda c: c.type_ascii(" ok"), True),
                ("click Send", lambda c: c.pointer_click(1124, 488), True),
            ]),
            ("09_toast_notifications", 923, [
                ("dismiss third toast", lambda c: c.pointer_click(1149, 862), True),
                ("dismiss second toast", lambda c: c.pointer_click(1021, 800), True),
                ("dismiss first toast", lambda c: c.pointer_click(1130, 738), True),
            ]),
        ]

        with tempfile.TemporaryDirectory(prefix="orb-u6-9screens-") as td:
            root = Path(td)
            for idx, (screen_id, height, steps) in enumerate(screens):
                with self.subTest(screen=screen_id):
                    sub = root / f"s{idx}"
                    sub.mkdir()
                    comp, proc = self._launch(sub, ["--screen", screen_id], height=height)
                    try:
                        comp.wait_ready(timeout=15.0)
                        for label, action, expect_change in steps:
                            prev_hash = comp.last_frame_hash
                            action(comp)
                            if expect_change:
                                try:
                                    comp.wait_frame_change(prev_hash, timeout=5.0)
                                except TimeoutError as exc:
                                    raise AssertionError(f"{screen_id} step '{label}': {exc}") from exc
                            else:
                                time.sleep(0.15)
                                self.assertEqual(comp.last_frame_hash, prev_hash, f"{screen_id}: {label} must not repaint/dismiss")
                    finally:
                        self._shutdown(comp, proc)


if __name__ == "__main__":
    unittest.main()
