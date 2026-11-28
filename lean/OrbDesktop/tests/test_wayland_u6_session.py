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
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_BINARY = ROOT / "lean/OrbDesktop/.lake/build/bin/orb-desktop-native"
CURRENT_BUBBLE_SQL = (ROOT / "lean/OrbCore/OrbCore/current_bubble.sql").read_text()


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
        self._pending_frame_cbs: list[int] = []
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
        try:
            if fds:
                anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds).tobytes())]
                self._client.sendmsg([payload], anc)
            else:
                self._client.sendall(payload)
        except OSError:
            pass

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
            elif opcode == 3:  # frame(callback)
                cb = struct.unpack_from("=I", body, 0)[0]
                self._pending_frame_cbs.append(cb)
            elif opcode == 6:  # commit
                if self.xdg_toplevel_id and self.xdg_surface_id and not self.configured_acked and self._attached_buf is None:
                    # Initial commit -> send xdg_toplevel.configure + xdg_surface.configure
                    states = struct.pack("=I", 4)  # activated
                    self._send(_wl_msg(self.xdg_toplevel_id, 0, struct.pack("=ii", self.width, self.height) + _wl_array(states)))
                    self._send(_wl_msg(self.xdg_surface_id, 0, struct.pack("=I", self._next_serial())))
                    self._maybe_send_enter()
                elif self._attached_buf and self._attached_buf in self._buffers:
                    bid = self._attached_buf
                    pid, off, w, h, stride = self._buffers[bid]
                    if pid in self._pools:
                        mm = self._pools[pid][2]
                        frame = mm[off : off + stride * h]
                        self.last_frame_bytes = frame
                        self.last_frame_w = w
                        self.last_frame_h = h
                        self.last_frame_stride = stride
                        self.last_frame_hash = hashlib.sha256(frame).hexdigest()
                    self.commit_count += 1
                    # Release buffer and fire any pending wl_surface.frame callbacks per Wayland spec
                    self._send(_wl_msg(bid, 0, b""))  # wl_buffer.release
                    if self._pending_frame_cbs:
                        ts = int(time.monotonic() * 1000) & 0xFFFFFFFF
                        for cb in self._pending_frame_cbs:
                            self._send(_wl_msg(cb, 0, struct.pack("=I", ts)))  # wl_callback.done
                            self._send(_wl_msg(1, 1, struct.pack("=I", cb)))   # wl_display.delete_id
                        self._pending_frame_cbs.clear()
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

    def _region_hash_locked(self, x0: int, y0: int, x1: int, y1: int) -> str:
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

    def region_hash(self, x0: int, y0: int, x1: int, y1: int) -> str:
        with self._lock:
            return self._region_hash_locked(x0, y0, x1, y1)

    def wait_region_change(self, x0: int, y0: int, x1: int, y1: int, previous_hash: str, timeout: float = 5.0) -> str:
        deadline = time.monotonic() + timeout
        with self._lock:
            while True:
                cur = self._region_hash_locked(x0, y0, x1, y1)
                if cur != previous_hash:
                    return cur
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(f"region ({x0},{y0},{x1},{y1}) hash did not change from {previous_hash[:12]}")
                self._cond.wait(min(0.1, rem))

    def wait_text_input(self, enabled: bool, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        with self._lock:
            while self.text_input_enabled != enabled:
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(f"expected text_input_enabled={enabled}, got {self.text_input_enabled}")
                self._cond.wait(rem)

    def wait_text_input_commit(self, after_count: int, timeout: float = 5.0) -> int:
        deadline = time.monotonic() + timeout
        with self._lock:
            while self.text_input_commit_count <= after_count or not self.text_input_enabled:
                rem = deadline - time.monotonic()
                if rem <= 0:
                    raise TimeoutError(
                        f"expected text_input_commit_count > {after_count} and enabled=True, "
                        f"got count={self.text_input_commit_count} enabled={self.text_input_enabled}"
                    )
                self._cond.wait(rem)
            return self.text_input_commit_count

    def click_and_wait_text_input_cycle(self, x: float, y: float, timeout: float = 5.0) -> int:
        with self._lock:
            before = self.text_input_commit_count
        self.pointer_click(x, y)
        return self.wait_text_input_commit(before, timeout=timeout)

    def _ms(self) -> int:
        return int(time.monotonic() * 1000) & 0xFFFFFFFF

    def pointer_move(self, x: float, y: float) -> None:
        with self._lock:
            assert self.pointer_id is not None
            self._send(
                _wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), int(x * 256), int(y * 256)))
                + _wl_msg(self.pointer_id, 5)
            )

    def pointer_press(self, x: float, y: float, button: int = 0x110) -> None:
        with self._lock:
            assert self.pointer_id is not None
            fx, fy = int(x * 256), int(y * 256)
            self._send(
                _wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), fx, fy))
                + _wl_msg(self.pointer_id, 5)
                + _wl_msg(self.pointer_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), button, 1))
                + _wl_msg(self.pointer_id, 5)
            )

    def pointer_release(self, x: float, y: float, button: int = 0x110) -> None:
        with self._lock:
            assert self.pointer_id is not None
            fx, fy = int(x * 256), int(y * 256)
            self._send(
                _wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), fx, fy))
                + _wl_msg(self.pointer_id, 5)
                + _wl_msg(self.pointer_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), button, 0))
                + _wl_msg(self.pointer_id, 5)
            )

    def pointer_click(self, x: float, y: float, button: int = 0x110) -> None:
        with self._lock:
            assert self.pointer_id is not None
            fx, fy = int(x * 256), int(y * 256)
            self._send(
                _wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), fx, fy))
                + _wl_msg(self.pointer_id, 5)
                + _wl_msg(self.pointer_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), button, 1))
                + _wl_msg(self.pointer_id, 5)
                + _wl_msg(self.pointer_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), button, 0))
                + _wl_msg(self.pointer_id, 5)
            )

    def pointer_scroll(self, x: float, y: float, dy: float) -> None:
        with self._lock:
            assert self.pointer_id is not None
            self._send(
                _wl_msg(self.pointer_id, 2, struct.pack("=Iii", self._ms(), int(x * 256), int(y * 256)))
                + _wl_msg(self.pointer_id, 4, struct.pack("=IIi", self._ms(), 0, int(dy * 256)))
                + _wl_msg(self.pointer_id, 5)
            )

    def key_tap(self, key_name: str, mods: int = 0) -> None:
        code = EV[key_name]
        with self._lock:
            assert self.keyboard_id is not None
            pkt = bytearray()
            if mods:
                pkt += _wl_msg(self.keyboard_id, 4, struct.pack("=IIIII", self._next_serial(), mods, 0, 0, 0))
            pkt += _wl_msg(self.keyboard_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), code, 1))
            pkt += _wl_msg(self.keyboard_id, 3, struct.pack("=IIII", self._next_serial(), self._ms(), code, 0))
            if mods:
                pkt += _wl_msg(self.keyboard_id, 4, struct.pack("=IIIII", self._next_serial(), 0, 0, 0, 0))
            self._send(bytes(pkt))

    def type_ascii(self, text: str) -> None:
        for ch in text:
            if "A" <= ch <= "Z":
                self.key_tap(ch.lower(), MOD_SHIFT)
            else:
                self.key_tap(ch, 0)

    def ime_edit(
        self,
        commit: str = "",
        preedit: str = "",
        del_before: int = 0,
        del_after: int = 0,
        serial: int | None = None,
    ) -> None:
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
            done_serial = self.text_input_commit_count if serial is None else serial
            self._send(_wl_msg(self.text_input_id, 5, struct.pack("=I", done_serial & 0xFFFFFFFF)))

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


def _start_sqlite_core(db_path: Path, token: str):
    """Persistent SQLite-backed local Core HTTP server for U6a end-to-end verification."""
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS missions(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            project TEXT NOT NULL DEFAULT '',
            backend TEXT NOT NULL DEFAULT 'codex',
            owner_user_id TEXT NOT NULL DEFAULT 'owner',
            history_json TEXT NOT NULL DEFAULT '[]',
            stopped_turns INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS mission_shares(
            mission_id TEXT NOT NULL,
            user_id TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS mission_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mission_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            sequence INTEGER NOT NULL,
            event_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            metadata TEXT NOT NULL DEFAULT '{}',
            content TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS seen_messages(
            client_message_id TEXT PRIMARY KEY,
            mission_id TEXT NOT NULL
        );
        """
    )
    conn.commit()
    lock = threading.Lock()
    requests_log: list[tuple[str, str, int]] = []
    state = {"counter": 0, "busy_archive_409": 0}

    def next_seq(mid: str) -> int:
        row = conn.execute(
            "SELECT COALESCE(MAX(sequence), 0) FROM mission_events WHERE mission_id=?",
            (mid,),
        ).fetchone()
        return (row[0] or 0) + 1

    def add_event(mid: str, kind: str, content: str, extra: dict | None = None) -> int:
        seq = next_seq(mid)
        payload = {"content": content, **(extra or {})}
        conn.execute(
            "INSERT INTO mission_events(mission_id,seq,sequence,event_type,payload,metadata,content) VALUES(?,?,?,?,?,?,?)",
            (mid, seq, seq, kind, json.dumps(payload), "{}", content),
        )
        conn.commit()
        return seq

    class Handler(BaseHTTPRequestHandler):
        def _reply(self, body, code: int = 200) -> None:
            raw = json.dumps(body).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            try:
                self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError):
                pass
            requests_log.append((self.command, self.path, code))

        def _read_json(self) -> dict:
            length = int(self.headers.get("Content-Length") or "0")
            return json.loads(self.rfile.read(length)) if length else {}

        def do_GET(self) -> None:
            if self.headers.get("Authorization") != f"Bearer {token}":
                return self._reply({"error": "unauthorized"}, 401)
            base_path = urlsplit(self.path).path
            with lock:
                if base_path == "/api/auth/me":
                    return self._reply({"user": {"id": "owner", "username": "u6a-wayland", "role": "admin"}})
                if base_path == "/api/projects":
                    return self._reply({"projects": [{"slug": "source", "title": "Source", "objective": "", "color": "blue"}]})
                if base_path == "/api/machines":
                    return self._reply([{"id": "core", "name": "orb-core", "state": "online", "status": "online"}])
                if base_path == "/api/backends":
                    return self._reply({"backends": [{"id": "codex", "name": "Codex"}]})
                if base_path == "/api/providers/backend-models":
                    return self._reply({"backends": {"codex": [{"value": "gpt-6.2-astra", "label": "Astra"}]}})
                if base_path == "/api/model-routing/chains":
                    return self._reply([])
                if base_path == "/api/control/inbox-state":
                    return self._reply({"_versions": {}})
                if base_path == "/api/control/missions":
                    rows = conn.execute("SELECT id,title,status,project,backend,stopped_turns FROM missions").fetchall()
                    return self._reply([
                        {
                            "id": r[0],
                            "title": r[1],
                            "status": r[2],
                            "project": r[3] or "source",
                            "backend": r[4],
                            "stopped_turns": r[5],
                            "updated_at": "2026-11-27T10:00:00Z",
                            "created_at": "2026-11-27T10:00:00Z",
                            "tags": [],
                        }
                        for r in rows
                    ])
                if base_path.startswith("/api/control/missions/"):
                    parts = base_path.removeprefix("/api/control/missions/").split("/")
                    mid = parts[0]
                    row = conn.execute(
                        "SELECT id,title,status,project,backend,stopped_turns FROM missions WHERE id=?",
                        (mid,),
                    ).fetchone()
                    if not row:
                        return self._reply({"error": "not_found"}, 404)
                    if len(parts) == 1:
                        return self._reply({
                            "id": row[0],
                            "title": row[1],
                            "status": row[2],
                            "project": row[3] or "source",
                            "backend": row[4],
                            "stopped_turns": row[5],
                            "execution": {"state": "running" if row[2] == "active" else "idle"},
                        })
                    sub = parts[1]
                    if sub == "events":
                        evs = conn.execute(
                            "SELECT id,sequence,event_type,content FROM mission_events WHERE mission_id=? ORDER BY sequence ASC, id ASC",
                            (mid,),
                        ).fetchall()
                        return self._reply([
                            {"id": e[0], "mission_id": mid, "sequence": e[1], "event_type": e[2], "content": e[3]}
                            for e in evs
                        ])
                    if sub == "open":
                        evs = conn.execute(
                            "SELECT id,sequence,event_type,content FROM mission_events WHERE mission_id=? ORDER BY sequence ASC, id ASC",
                            (mid,),
                        ).fetchall()
                        events = [
                            {"id": e[0], "mission_id": mid, "sequence": e[1], "event_type": e[2], "content": e[3]}
                            for e in evs
                        ]
                        return self._reply({
                            "protocol": 1,
                            "mission": {"id": mid},
                            "events": events,
                            "spine": [],
                            "queue": [],
                            "max_seq": events[-1]["sequence"] if events else 0,
                            "has_more": False,
                            "spine_has_more": False,
                            "spine_next_cursor": None,
                            "next_cursor": None,
                            "page_max_seq": None,
                            "reset": False,
                        })
                    if sub == "current-bubble":
                        if row[2] == "active" and not conn.execute(
                            "SELECT 1 FROM mission_events WHERE mission_id=? AND event_type='assistant_message'",
                            (mid,),
                        ).fetchone():
                            add_event(mid, "assistant_message", "Turn 1 reply", {"queued": False})
                            conn.execute("UPDATE missions SET status='awaiting_user' WHERE id=?", (mid,))
                            conn.commit()
                        user_count = conn.execute(
                            "SELECT COUNT(*) FROM mission_events WHERE mission_id=? AND event_type='user_message'",
                            (mid,),
                        ).fetchone()[0]
                        if row[2] == "active" and user_count >= 2 and not conn.execute(
                            "SELECT 1 FROM mission_events WHERE mission_id=? AND event_type='text_delta'",
                            (mid,),
                        ).fetchone():
                            add_event(mid, "text_delta", "Turn 2 streaming...", {"queued": False})
                        qrow = conn.execute(CURRENT_BUBBLE_SQL, {"1": mid, "2": "0", "3": "owner", "4": "0"}).fetchone()
                        if not qrow:
                            return self._reply({"error": "not_found"}, 404)
                        return self._reply({"id": mid, "title": qrow[0], "status": qrow[1], "text": qrow[2]})
                return self._reply({"error": "not_found"}, 404)

        def do_POST(self) -> None:
            if self.headers.get("Authorization") != f"Bearer {token}":
                return self._reply({"error": "unauthorized"}, 401)
            path = urlsplit(self.path).path
            data = self._read_json()
            with lock:
                if path == "/api/control/missions":
                    state["counter"] += 1
                    mid = f"m-u6a-{state['counter']}"
                    prompt = data.get("prompt", "")
                    title = data.get("title") or "New mission"
                    project = data.get("project") or "source"
                    backend = data.get("backend") or "codex"
                    conn.execute(
                        "INSERT INTO missions(id,title,status,project,backend) VALUES(?,?,'active',?,?)",
                        (mid, title, project, backend),
                    )
                    if prompt:
                        add_event(mid, "user_message", prompt, {"queued": False})
                    conn.commit()
                    return self._reply({
                        "id": mid,
                        "title": title,
                        "status": "active",
                        "project": project,
                        "backend": backend,
                        "model_override": data.get("model_override") or "",
                        "model_effort": data.get("model_effort") or "",
                        "permission_mode": data.get("permission_mode") or "supervised",
                    })
                if path == "/api/control/message":
                    mid = data["mission_id"]
                    cid = data["client_message_id"]
                    content = data["content"]
                    if not conn.execute("SELECT 1 FROM seen_messages WHERE client_message_id=?", (cid,)).fetchone():
                        conn.execute("INSERT INTO seen_messages VALUES(?,?)", (cid, mid))
                        add_event(mid, "user_message", content, {"queued": False})
                        conn.execute("UPDATE missions SET status='active' WHERE id=?", (mid,))
                        conn.commit()
                    return self._reply({"id": cid, "message_accepted": True})
                if path.startswith("/api/control/missions/") and path.endswith("/cancel"):
                    mid = path.removeprefix("/api/control/missions/").removesuffix("/cancel")
                    conn.execute(
                        "UPDATE missions SET status='interrupted', stopped_turns=stopped_turns+1 WHERE id=?",
                        (mid,),
                    )
                    add_event(mid, "turn_stopped", "stopped by user", {"queued": False})
                    return self._reply({"ok": True, "status": "interrupted"})
                if path.startswith("/api/control/missions/") and path.endswith("/status"):
                    mid = path.removeprefix("/api/control/missions/").removesuffix("/status")
                    row = conn.execute("SELECT status FROM missions WHERE id=?", (mid,)).fetchone()
                    if not row:
                        return self._reply({"error": "not_found"}, 404)
                    if data.get("status") == "acknowledged" and row[0] == "active":
                        state["busy_archive_409"] += 1
                        return self._reply({"error": "mission_running"}, 409)
                    conn.execute("UPDATE missions SET status=? WHERE id=?", (data["status"], mid))
                    conn.commit()
                    return self._reply({"ok": True, "status": data["status"]})
                return self._reply({"error": "not_found"}, 404)

        def log_message(self, *_args) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, conn, lock, requests_log, state


class WaylandU6SessionTest(unittest.TestCase):
    def _launch(
        self,
        tmp: Path,
        extra_args: list[str],
        extra_env: dict[str, str] | None = None,
        height: int = 923,
        via_leanui_flag: bool = False,
    ):
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
        if via_leanui_flag:
            native_target = (ROOT / "target/native/orb-desktop-native").resolve()
            if binary.resolve() == native_target:
                env["ORB_DESKTOP_SKIP_BUILD"] = "1"
                cmd = [str(ROOT / "scripts/orb_desktop_dev.sh"), "--leanui", "--width", "1470", "--height", str(height), *extra_args]
            else:
                cmd = [str(binary), "--leanui", "--width", "1470", "--height", str(height), *extra_args]
        else:
            cmd = [str(binary), "--width", "1470", "--height", str(height), *extra_args]
        proc = subprocess.Popen(
            cmd,
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
                    # Wait for the FINAL request of initial roster() bootstrap (/api/auth/me) AND
                    # composer text-input enable (which fires only after the connected frame paints).
                    _wait_until("initial roster /api/auth/me", lambda: count_req("GET", "/api/auth/me") >= 1)
                    comp.wait_text_input(True, timeout=10.0)

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

                    # 2. Scroll transcript upward with `Orb.Scroll` policy (wheel + PageUp/PageDown),
                    #    verify unpinned anchor stays put while new assistant text streams in, then re-pin.
                    comp.pointer_scroll(740, 400, -1200)
                    tx_scrolled_up = comp.wait_region_change(240, 45, 1450, 810, tx_bottom, timeout=5.0)
                    self.assertNotEqual(tx_scrolled_up, tx_bottom, "upward wheel scroll must update transcript pixels")
                    # Keyboard PageUp scrolls further upward through the shared Orb.Scroll policy.
                    comp.key_tap("pgup")
                    tx_pgup = comp.wait_region_change(240, 45, 1450, 810, tx_scrolled_up, timeout=5.0)
                    self.assertNotEqual(tx_pgup, tx_scrolled_up, "PageUp must scroll transcript via Orb.Scroll")

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
                        tx_pgup,
                        "Orb.Scroll unpinned viewport must remain stable when new assistant lines arrive",
                    )
                    # Scroll back down via PageDown + wheel to re-pin and reveal the newly appended delta.
                    comp.key_tap("pgdn")
                    tx_pgdn = comp.wait_region_change(240, 45, 1450, 810, tx_pgup, timeout=5.0)
                    comp.pointer_scroll(740, 400, 3600)
                    tx_repinned = comp.wait_region_change(240, 45, 1450, 810, tx_pgdn, timeout=5.0)
                    self.assertNotEqual(tx_repinned, tx_pgup, "scrolling back to bottom must reveal new streamed lines")

                    # 3. Exercise Side Panels (header Diff + every Diff toolbar/chip control, Files, Side-chat,
                    #    Close button, Escape-release guard, and Left Sidebar Ctrl+B).
                    right_pane_no_panel = comp.region_hash(995, 40, 1465, 810)
                    comp.pointer_click(1383, 17)  # Open Diff side panel
                    right_pane_diff = comp.wait_region_change(995, 40, 1465, 810, right_pane_no_panel, timeout=5.0)
                    self.assertNotEqual(right_pane_diff, right_pane_no_panel, "clicking Diff header icon must open side panel")

                    # Exercise every Diff side-panel control in live mode (Unified, Split, Ref, Refresh, File chip).
                    comp.pointer_click(1196, 57)  # diffUnifiedId
                    right_pane_uni = comp.wait_region_change(995, 40, 1465, 810, right_pane_diff, timeout=5.0)
                    comp.pointer_click(1245, 57)  # diffSplitId
                    right_pane_split = comp.wait_region_change(995, 40, 1465, 810, right_pane_uni, timeout=5.0)
                    comp.pointer_click(1081, 57)  # diffRefId
                    right_pane_ref = comp.wait_region_change(995, 40, 1465, 810, right_pane_split, timeout=5.0)
                    comp.pointer_click(1311, 58)  # diffRefreshId
                    right_pane_refresh = comp.wait_region_change(995, 40, 1465, 810, right_pane_ref, timeout=5.0)
                    comp.pointer_click(1116, 98)  # diffFileChipId
                    right_pane_chip = comp.wait_region_change(995, 40, 1465, 810, right_pane_refresh, timeout=5.0)

                    # Open Search (Ctrl+K) while side panel is open, verify IME in Search + Return preedit guard
                    # + interior click does not close, then press Escape and verify Diff side panel stays open!
                    search_card_closed = comp.region_hash(380, 60, 1090, 560)
                    comp.key_tap("k", MOD_CTRL)
                    search_card_open = comp.wait_region_change(380, 60, 1090, 560, search_card_closed, timeout=5.0)
                    comp.wait_text_input(True, timeout=5.0)
                    search_input_pre = comp.region_hash(330, 80, 1090, 115)
                    comp.ime_edit(commit="Hello", preedit="検")
                    h_preedit = comp.wait_region_change(330, 80, 1090, 115, search_input_pre, timeout=5.0)
                    # Return while Search IME preedit is active must NOT dismiss Search.
                    comp.key_tap("return")
                    time.sleep(0.12)
                    self.assertEqual(comp.region_hash(330, 80, 1090, 115), h_preedit, "Return during Search preedit must stay open")
                    comp.ime_edit(commit="", preedit="")
                    comp.wait_region_change(330, 80, 1090, 115, h_preedit, timeout=5.0)
                    search_card_before = comp.region_hash(380, 60, 1090, 560)
                    # Clicking inside the Search modal preview pane (900, 300) must NOT dismiss the modal.
                    comp.pointer_click(900, 300)
                    time.sleep(0.15)
                    self.assertEqual(
                        comp.region_hash(380, 60, 1090, 560),
                        search_card_before,
                        "clicking inside Search card must not close modal",
                    )
                    # Pressing Escape closes Search while leaving Diff side panel intact.
                    comp.key_tap("esc")
                    comp.wait_region_change(380, 60, 1090, 560, search_card_before, timeout=5.0)
                    self.assertEqual(
                        comp.region_hash(995, 40, 1465, 810),
                        right_pane_chip,
                        "Escape closing Search must leave Diff side panel intact",
                    )

                    comp.pointer_click(1415, 17)  # Switch to Files side panel
                    right_pane_files = comp.wait_region_change(995, 40, 1465, 810, right_pane_chip, timeout=5.0)
                    self.assertNotEqual(right_pane_files, right_pane_chip, "switching to Files panel must repaint")

                    comp.pointer_click(1447, 17)  # Switch to Side-chat panel
                    right_pane_chat = comp.wait_region_change(995, 40, 1465, 810, right_pane_files, timeout=5.0)

                    comp.pointer_click(1446, 61)  # Click sidePanelCloseId close button
                    comp.wait_region_change(995, 40, 1465, 810, right_pane_chat, timeout=5.0)

                    # Left sidebar hide/show via Ctrl+B.
                    sb_open = comp.region_hash(0, 0, 220, 400)
                    comp.key_tap("b", MOD_CTRL)
                    sb_hidden = comp.wait_region_change(0, 0, 220, 400, sb_open, timeout=5.0)
                    self.assertNotEqual(sb_hidden, sb_open, "Ctrl+B must hide sidebar")
                    comp.key_tap("b", MOD_CTRL)
                    comp.wait_region_change(0, 0, 220, 400, sb_hidden, timeout=5.0)

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
                    open_pre_fwd = count_req("GET", f"/api/control/missions/{mid}/open")
                    bubble_pre_fwd = count_req("GET", f"/api/control/missions/{mid}/current-bubble")
                    comp.key_tap("]", MOD_CTRL)
                    comp.wait_frame_change(h_back, timeout=5.0)
                    # Let the restarted subscription's /open + /current-bubble settle so background
                    # repaints cannot race with sidebar expansion or context-menu hit regions.
                    _wait_until(
                        "mission /open after Forward",
                        lambda: count_req("GET", f"/api/control/missions/{mid}/open") > open_pre_fwd,
                        timeout=6.0,
                    )
                    _wait_until(
                        "mission /current-bubble after Forward",
                        lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") > bubble_pre_fwd,
                        timeout=6.0,
                    )

                    # 7. Archive the mission: expand Source Project in sidebar, right-click the mission row, click Archive.
                    # Hash the child row slot directly below Source Project (y=288..316), which pointer hover
                    # on Source Project (y=272) never touches, and wait for the restarted project/bubble polls.
                    child_row_pre = comp.region_hash(10, 288, 210, 316)
                    proj_reqs_pre = count_req("GET", "/api/control/missions?project=source")
                    bubble_pre_exp = count_req("GET", f"/api/control/missions/{mid}/current-bubble")
                    comp.pointer_click(100, 272)  # Expand Source Project
                    comp.wait_region_change(10, 288, 210, 316, child_row_pre, timeout=5.0)
                    _wait_until(
                        "project history after Source Project expand",
                        lambda: count_req("GET", "/api/control/missions?project=source") > proj_reqs_pre,
                        timeout=6.0,
                    )
                    _wait_until(
                        "bubble poll after Source Project expand",
                        lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") > bubble_pre_exp,
                        timeout=6.0,
                    )
                    # Hash the right half of the context menu popup (x=225..325, outside the 220px sidebar)
                    # so sidebar hover or unrelated updates cannot satisfy the menu-open wait prematurely.
                    menu_outside_pre = comp.region_hash(225, 310, 325, 430)
                    comp.pointer_click(100, 303, button=0x111)  # Right-click context menu
                    comp.wait_region_change(225, 310, 325, 430, menu_outside_pre, timeout=5.0)
                    # Hash bottom composer dock (present on missionTranscript, blank on controlEmpty) so we wait until archive finishes.
                    dock_pre_arch = comp.region_hash(450, 820, 1220, 915)
                    comp.pointer_click(160, 372)  # Click dead-center of Archive row (712: y=359..385)
                    _wait_until("mission archived on Core", lambda: core_state.missions[0]["status"] == "acknowledged")
                    comp.wait_region_change(450, 820, 1220, 915, dock_pre_arch, timeout=5.0)
                    comp.wait_text_input(True, timeout=5.0)

                    # 8. Exercise Inference VPN & alternative-router controls (`Ctrl+4`).
                    # Row 0 of Inference lives at (525..1165, 35..95); blank during "Loading accounts…" and painted once providers load.
                    row0_pre_inf = comp.region_hash(525, 35, 1165, 95)
                    comp.key_tap("4", MOD_CTRL)
                    _wait_until("GET /api/ai/providers", lambda: count_req("GET", "/api/ai/providers") >= 1)
                    row0_inf = comp.wait_region_change(525, 35, 1165, 95, row0_pre_inf, timeout=5.0)
                    # Settle row 0 hover tint before clicking so a sub-ms partial hover commit
                    # cannot prematurely satisfy `wait_region_change` before the async toggle renders.
                    comp.pointer_move(700, 65)
                    row0_hovered = comp.wait_region_change(525, 35, 1165, 95, row0_inf, timeout=5.0)
                    comp.pointer_click(700, 65)  # Toggle provider user_enabled -> false
                    _wait_until("provider skipped on Core", lambda: core_state.providers[0]["user_enabled"] is False)
                    row0_toggled = comp.wait_region_change(525, 35, 1165, 95, row0_hovered, timeout=5.0)
                    comp.pointer_click(700, 65)  # Toggle provider user_enabled -> true
                    _wait_until("provider re-enabled on Core", lambda: core_state.providers[0]["user_enabled"] is True)
                    comp.wait_region_change(525, 35, 1165, 95, row0_toggled, timeout=5.0)

                    # Open AccountRoutePage (`Settings ›`) for Antigravity account.
                    routes_pre = comp.region_hash(525, 175, 1165, 390)
                    comp.pointer_click(1123, 65)
                    _wait_until("GET /vpn", lambda: count_req("GET", "/api/ai/providers/acct-ag-1/vpn") >= 1)
                    _wait_until("GET /alternative-routers", lambda: count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers") >= 1)
                    routes_init = comp.wait_region_change(525, 175, 1165, 390, routes_pre, timeout=5.0)

                    # Select AirVPN · NL / Direct / Alternative routers / DE: frame A paints pending before
                    # `readSources` spawns `account_routes`, then frame B paints settled after refresh completes.
                    def _click_route_and_wait(x: int, y: int, prev_hash: str, label: str, pred) -> str:
                        alt_before = count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers")
                        comp.pointer_click(x, y)
                        first_hash = comp.wait_region_change(525, 175, 1165, 390, prev_hash, timeout=5.0)
                        captured_before_refresh = (
                            count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers") == alt_before
                        )
                        _wait_until(label, pred)
                        _wait_until(
                            f"refresh after {label}",
                            lambda: count_req("GET", "/api/ai/providers/acct-ag-1/alternative-routers") > alt_before,
                        )
                        if captured_before_refresh:
                            return comp.wait_region_change(525, 175, 1165, 390, first_hash, timeout=5.0)
                        try:
                            return comp.wait_region_change(525, 175, 1165, 390, first_hash, timeout=1.0)
                        except TimeoutError:
                            return first_hash

                    routes_nl = _click_route_and_wait(
                        845, 251, routes_init, "PUT /vpn NL",
                        lambda: core_state.vpn_state["acct-ag-1"]["country"] == "NL",
                    )
                    routes_direct = _click_route_and_wait(
                        845, 199, routes_nl, "PUT /vpn direct",
                        lambda: core_state.vpn_state["acct-ag-1"]["mode"] == "direct",
                    )
                    routes_alt_off = _click_route_and_wait(
                        845, 355, routes_direct, "PUT /alternative-routers false",
                        lambda: core_state.alt_routers["acct-ag-1"]["allowed"] is False,
                    )
                    routes_de = _click_route_and_wait(
                        845, 303, routes_alt_off, "PUT /vpn DE",
                        lambda: core_state.vpn_state["acct-ag-1"]["country"] == "DE",
                    )

                    # Toggle Alternative routers back ON via keyboard Return (focus already on row or click ‹ Inference back).
                    # Click ‹ Inference back button (providersBackId at y=35..77 -> center y=56), then re-open & Escape.
                    hdr_inf_pre = comp.region_hash(525, 35, 1165, 130)
                    comp.pointer_click(700, 56)
                    hdr_inf_list = comp.wait_region_change(525, 35, 1165, 130, hdr_inf_pre, timeout=5.0)
                    # Re-open AccountRoutePage and close via Escape.
                    comp.pointer_click(1123, 65)
                    hdr_inf_reopen = comp.wait_region_change(525, 35, 1165, 130, hdr_inf_list, timeout=5.0)
                    comp.key_tap("esc")
                    comp.wait_region_change(525, 35, 1165, 130, hdr_inf_reopen, timeout=5.0)

                    # 9. Exercise Machines (`Ctrl+3`), Resources (`Ctrl+6` + range filter), Cloud (`Ctrl+2`), Inbox (`Ctrl+I`), Settings (`Ctrl+,`).
                    hdr_pre_m = comp.region_hash(225, 0, 500, 35)
                    comp.key_tap("3", MOD_CTRL)
                    hdr_machines = comp.wait_region_change(225, 0, 500, 35, hdr_pre_m, timeout=5.0)
                    # Click a machine row in live Machines fleet and verify visible selection change.
                    machine_row0_pre = comp.region_hash(525, 35, 1165, 95)
                    comp.pointer_click(845, 65)
                    comp.wait_region_change(525, 35, 1165, 95, machine_row0_pre, timeout=5.0)

                    comp.key_tap("6", MOD_CTRL)
                    _wait_until("GET /api/resources/overview?range=6h", lambda: count_req("GET", "/api/resources/overview?range=6h") >= 1)
                    hdr_res = comp.wait_region_change(225, 0, 500, 35, hdr_machines, timeout=5.0)
                    # Click `30m` range button (id 955, leftmost of 7 slots in 640px centered toolbar at x=525..616, y=35..67).
                    comp.pointer_click(570, 51)
                    _wait_until("GET /api/resources/overview?range=30m", lambda: count_req("GET", "/api/resources/overview?range=30m") >= 1)

                    comp.key_tap("2", MOD_CTRL)
                    _wait_until("GET /api/cloud/accounts", lambda: count_req("GET", "/api/cloud/accounts") >= 1)
                    hdr_cloud = comp.wait_region_change(225, 0, 500, 35, hdr_res, timeout=5.0)

                    comp.key_tap("i", MOD_CTRL)
                    hdr_inbox = comp.wait_region_change(225, 0, 500, 35, hdr_cloud, timeout=5.0)

                    comp.key_tap(",", MOD_CTRL)
                    comp.wait_region_change(225, 0, 500, 35, hdr_inbox, timeout=5.0)
                    # Toggle theme in live Settings (second button below Account/Connected/endpoint/@user/Manage account, y=219..259).
                    canvas_dark = comp.region_hash(700, 500, 900, 700)
                    comp.pointer_click(350, 239)
                    canvas_light = comp.wait_region_change(700, 500, 900, 700, canvas_dark, timeout=5.0)
                    self.assertNotEqual(canvas_light, canvas_dark, "clicking Theme toggle in Settings must switch theme")

                    # Verify cursor shapes were emitted for pointer hover/text transitions.
                    self.assertTrue(len(comp.cursor_shapes) >= 1)
                finally:
                    self._shutdown(comp, proc)
            finally:
                server.shutdown()

    def test_all_nine_screens_wayland_input_sweep(self) -> None:
        """Launch each of the 9 canonical screens under Wayland and exercise EVERY interactive control."""
        # For each screen: (screen_id, height, steps). Every step asserts real framebuffer pixel change (`wait_frame_change`).
        screens = [
            ("01_control_empty", 923, [
                ("click project picker (738)", lambda c: c.pointer_click(575, 390), True),
                ("click machine picker (720)", lambda c: c.pointer_click(696, 390), True),
                ("click folder picker (739)", lambda c: c.pointer_click(817, 390), True),
                ("click attach plus (3)", lambda c: c.pointer_click(566, 489), True),
                ("click model picker (722)", lambda c: c.pointer_click(845, 489), True),
                ("click composer (1)", lambda c: c.pointer_click(845, 447), True),
                ("type text", lambda c: c.type_ascii("hellox"), True),
                ("backspace edit", lambda c: c.key_tap("backspace"), True),
                ("ime preedit visible", lambda c: c.ime_edit(preedit="未確定"), True),
                ("ime commit", lambda c: c.ime_edit(commit="世界", preedit=""), True),
                ("click send (2)", lambda c: c.pointer_click(1124, 489), True),
                ("click sidebar toggle (117)", lambda c: c.pointer_click(19, 17), True),
                ("restore sidebar via header toggle (117)", lambda c: c.pointer_click(27, 17), True),
                ("click sidebar Search (351)", lambda c: c.pointer_click(45, 17), True),
                ("close Search via Escape", lambda c: c.key_tap("esc"), True),
                ("click sidebar Inbox (102)", lambda c: c.pointer_click(109, 81), True),
                ("click sidebar Cloud agent (111)", lambda c: c.pointer_click(109, 112), True),
                ("click sidebar Machines (112)", lambda c: c.pointer_click(109, 143), True),
                ("click sidebar Back (352)", lambda c: c.pointer_click(173, 17), True),
                ("click sidebar Forward (353)", lambda c: c.pointer_click(200, 17), True),
                ("click sidebar Inference (113)", lambda c: c.pointer_click(109, 174), True),
                ("click sidebar Resources (114)", lambda c: c.pointer_click(109, 205), True),
                ("click sidebar Settings (103)", lambda c: c.pointer_click(109, 901), True),
                ("click sidebar Back from Settings (101)", lambda c: c.pointer_click(109, 54), True),
            ]),
            ("02_control_populated", 923, [
                ("tab focus", lambda c: c.key_tap("tab"), True),
                ("shift-tab focus", lambda c: c.key_tap("tab", MOD_SHIFT), True),
                ("ctrl+b sidebar toggle", lambda c: c.key_tap("b", MOD_CTRL), True),
                ("ctrl+b sidebar restore", lambda c: c.key_tap("b", MOD_CTRL), True),
                ("click sidebar project row (130)", lambda c: c.pointer_click(109, 271), True),
                ("click project picker (738)", lambda c: c.pointer_click(575, 390), True),
                ("click machine picker (720)", lambda c: c.pointer_click(696, 390), True),
                ("click folder picker (739)", lambda c: c.pointer_click(817, 390), True),
                ("click attach plus (3)", lambda c: c.pointer_click(566, 489), True),
                ("click model picker (722)", lambda c: c.pointer_click(845, 489), True),
                ("click composer (1)", lambda c: c.pointer_click(845, 447), True),
                ("type text", lambda c: c.type_ascii("populated "), True),
                ("ime commit", lambda c: c.ime_edit(commit="確認", preedit=""), True),
                ("click send (2)", lambda c: c.pointer_click(1124, 489), True),
                ("click sidebar Inbox (102)", lambda c: c.pointer_click(109, 81), True),
                ("click sidebar Cloud agent (111)", lambda c: c.pointer_click(109, 112), True),
            ]),
            ("03_mission_transcript", 600, [
                ("scroll transcript down (Orb.Scroll)", lambda c: c.pointer_scroll(740, 280, 600), True),
                ("scroll transcript up (Orb.Scroll)", lambda c: c.pointer_scroll(740, 280, -300), True),
                ("PageDown keyboard scroll", lambda c: c.key_tap("pgdn"), True),
                ("PageUp keyboard scroll", lambda c: c.key_tap("pgup"), True),
                ("click sidebar Project 0 (104)", lambda c: c.pointer_click(109, 273), True),
                ("click sidebar Mission 80 (120)", lambda c: c.pointer_click(109, 303), True),
                ("click sidebar Mission 60 (121)", lambda c: c.pointer_click(109, 333), True),
                ("click sidebar Long mission (105)", lambda c: c.pointer_click(109, 423), True),
                ("click under-row machine (720)", lambda c: c.pointer_click(556, 565), True),
                ("click under-row backend (721)", lambda c: c.pointer_click(668, 565), True),
                ("click under-row model (722)", lambda c: c.pointer_click(743, 565), True),
                ("click under-row effort (723)", lambda c: c.pointer_click(805, 565), True),
                ("click under-row permission (724)", lambda c: c.pointer_click(886, 565), True),
                ("click attach plus (3)", lambda c: c.pointer_click(495, 527), True),
                ("click Stop running turn (2)", lambda c: c.pointer_click(1197, 527), True),
                ("click composer (1)", lambda c: c.pointer_click(700, 527), True),
                ("type and ime", lambda c: (c.type_ascii("hi "), c.ime_edit(commit="テスト")), True),
                ("click Send message (2)", lambda c: c.pointer_click(1197, 527), True),
                ("open Files side panel (355)", lambda c: c.pointer_click(1413, 17), True),
                ("switch to Side-chat panel (356)", lambda c: c.pointer_click(1441, 17), True),
                ("close side panel via Close button (357)", lambda c: c.pointer_click(1446, 61), True),
                ("open Diff side panel (354)", lambda c: c.pointer_click(1365, 17), True),
            ]),
            ("04_mission_split_diff", 600, [
                ("scroll left transcript (Orb.Scroll)", lambda c: c.pointer_scroll(500, 280, 600), True),
                ("PageUp left transcript", lambda c: c.key_tap("pgup"), True),
                ("switch diff to Unified (402)", lambda c: c.pointer_click(1114, 57), True),
                ("switch diff to Split (403)", lambda c: c.pointer_click(1163, 57), True),
                ("cycle diff ref (401)", lambda c: c.pointer_click(999, 57), True),
                ("click diff Refresh (404)", lambda c: c.pointer_click(1229, 58), True),
                ("click diff file chip (405)", lambda c: c.pointer_click(1034, 98), True),
                ("click under-row machine (720)", lambda c: c.pointer_click(339, 565), True),
                ("click under-row backend (721)", lambda c: c.pointer_click(451, 565), True),
                ("click under-row model (722)", lambda c: c.pointer_click(526, 565), True),
                ("click under-row effort (723)", lambda c: c.pointer_click(588, 565), True),
                ("click under-row permission (724)", lambda c: c.pointer_click(669, 565), True),
                ("click attach plus (3)", lambda c: c.pointer_click(278, 527), True),
                ("click Stop (2)", lambda c: c.pointer_click(852, 527), True),
                ("click composer (1)", lambda c: c.pointer_click(564, 527), True),
                ("type and ime in split diff", lambda c: (c.type_ascii("diff "), c.ime_edit(commit="確認")), True),
                ("click Send (2)", lambda c: c.pointer_click(852, 527), True),
                ("switch to Files panel (355)", lambda c: c.pointer_click(1413, 17), True),
                ("switch to Side-chat panel (356)", lambda c: c.pointer_click(1441, 17), True),
                ("toggle back to Diff panel (354)", lambda c: c.pointer_click(1365, 17), True),
                ("Escape closes split diff panel", lambda c: c.key_tap("esc"), True),
            ]),
            ("05_machines_fleet", 923, [
                ("click local machine (501)", lambda c: c.pointer_click(845, 193), True),
                ("click Core machine (502)", lambda c: c.pointer_click(845, 304), True),
                ("click Primary machine (503)", lambda c: c.pointer_click(845, 365), True),
                ("click Large-A VM (504)", lambda c: c.pointer_click(845, 460), True),
                ("click Default-B VM (505)", lambda c: c.pointer_click(845, 521), True),
                ("click Agent software (506)", lambda c: c.pointer_click(845, 594), True),
                ("click Copy key (507)", lambda c: c.pointer_click(1123, 678), True),
            ]),
            ("06_settings_general", 923, [
                ("click sidebar Models (111)", lambda c: c.pointer_click(109, 125), True),
                ("click sidebar Agents (112)", lambda c: c.pointer_click(109, 156), True),
                ("click sidebar Security (113)", lambda c: c.pointer_click(109, 187), True),
                ("click sidebar Notifications (114)", lambda c: c.pointer_click(109, 218), True),
                ("click sidebar Account (102)", lambda c: c.pointer_click(109, 94), True),
                ("click Users tab (602)", lambda c: c.pointer_click(657, 146), True),
                ("click Telemetry tab (603)", lambda c: c.pointer_click(755, 146), True),
                ("click Account tab (601)", lambda c: c.pointer_click(585, 146), True),
                ("click API URL input (604)", lambda c: c.pointer_click(1003, 245), True),
                ("type in API URL", lambda c: c.type_ascii("/v2"), True),
                ("backspace in API URL", lambda c: c.key_tap("backspace"), True),
                ("ime commit in API URL", lambda c: c.ime_edit(commit="3", preedit=""), True),
                ("click Disconnect (605)", lambda c: c.pointer_click(1083, 308), True),
                ("click Connect GitHub (606)", lambda c: c.pointer_click(1067, 421), True),
                ("click Refresh accounts (607)", lambda c: c.pointer_click(1059, 542), True),
                ("toggle Theme Dark/Light (608)", lambda c: c.pointer_click(1093, 664), True),
                ("toggle Background sync (609)", lambda c: c.pointer_click(1093, 727), True),
                ("click sidebar Back (101)", lambda c: c.pointer_click(109, 54), True),
            ]),
            ("07_search_dialog", 923, [
                ("arrow down result", lambda c: c.key_tap("down"), True),
                ("click Clear query (706)", lambda c: c.click_and_wait_text_input_cycle(1107, 98), True),
                ("type in search input (701)", lambda c: c.type_ascii("w"), True),
                ("ime preedit in search", lambda c: c.ime_edit(preedit="検"), True),
                ("return blocked during search preedit", lambda c: c.key_tap("return"), False),
                ("ime clear preedit in search", lambda c: c.ime_edit(commit="", preedit=""), True),
                ("click Clear query again (706)", lambda c: c.click_and_wait_text_input_cycle(1107, 98), True),
                ("click User filter (732)", lambda c: c.pointer_click(362, 133), True),
                ("type after filter click proves 701 kept focus", lambda c: c.type_ascii("m"), True),
                ("backspace after filter click", lambda c: c.key_tap("backspace"), True),
                ("click Assistant filter (733)", lambda c: c.pointer_click(419, 133), True),
                ("click Titles filter (734)", lambda c: c.pointer_click(478, 133), True),
                ("click Tools filter (735)", lambda c: c.pointer_click(526, 133), True),
                ("click All filter (731)", lambda c: c.pointer_click(321, 133), True),
                ("click Project filter (741)", lambda c: c.pointer_click(957, 133), True),
                ("reset Project filter (741)", lambda c: c.pointer_click(957, 133), True),
                ("click Time filter (742)", lambda c: c.pointer_click(1042, 133), True),
                ("click Sort order (743)", lambda c: c.pointer_click(1122, 133), True),
                ("click second result row", lambda c: c.pointer_click(475, 244), True),
                ("click inside preview pane stays open", lambda c: c.pointer_click(900, 300), False),
                ("click Esc button (707) to close", lambda c: c.pointer_click(1144, 98), True),
                ("post-Escape Tab moves focus", lambda c: c.key_tap("tab"), True),
                ("post-Escape click composer restores focus", lambda c: c.pointer_click(845, 447), True),
                ("post-Escape type proves trap popped", lambda c: c.type_ascii("ok"), True),
                ("reopen Search via Ctrl+K", lambda c: c.key_tap("k", MOD_CTRL), True),
                ("click backdrop (709) closes modal", lambda c: c.pointer_click(20, 20), True),
                ("reopen Search via toolbar (351)", lambda c: c.pointer_click(45, 17), True),
                ("click Open button (708) opens result", lambda c: c.pointer_click(1122, 183), True),
            ]),
            ("08_new_mission_dialog", 923, [
                ("click project picker (738)", lambda c: c.pointer_click(575, 390), True),
                ("click machine picker (720)", lambda c: c.pointer_click(696, 390), True),
                ("click folder picker (739)", lambda c: c.pointer_click(817, 390), True),
                ("click attach plus (3)", lambda c: c.pointer_click(566, 489), True),
                ("click model picker (722)", lambda c: c.pointer_click(845, 489), True),
                ("click composer (1)", lambda c: c.pointer_click(845, 447), True),
                ("type extra text + ime", lambda c: (c.type_ascii(" ok "), c.ime_edit(commit="新規")), True),
                ("click Send (2)", lambda c: c.pointer_click(1124, 489), True),
                ("toggle sidebar (117)", lambda c: c.pointer_click(19, 17), True),
                ("restore sidebar (117)", lambda c: c.pointer_click(27, 17), True),
            ]),
            ("09_toast_notifications", 923, [
                ("dismiss third toast (913)", lambda c: c.pointer_click(1149, 862), True),
                ("dismiss second toast (912)", lambda c: c.pointer_click(1020, 800), True),
                ("dismiss first toast (911)", lambda c: c.pointer_click(1129, 738), True),
                ("click project picker after toasts (738)", lambda c: c.pointer_click(575, 390), True),
                ("click composer after toasts (1)", lambda c: c.pointer_click(845, 447), True),
                ("type after toasts", lambda c: c.type_ascii("clear"), True),
                ("click Send after toasts (2)", lambda c: c.pointer_click(1124, 489), True),
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

    def test_scrollbar_drag_and_quiet_pointer_focus(self) -> None:
        """Verify draggable overlay scrollbar (thumb drag, track jump, live Orb.Scroll unpinning)
        and Cursor-style quiet pointer focus vs keyboard Tab :focus-visible over real Wayland."""
        with tempfile.TemporaryDirectory(prefix="orb-u6-track1b-") as td:
            root = Path(td)

            # 1. Quiet pointer focus vs keyboard Tab :focus-visible on 02_control_populated.
            sub_focus = root / "quiet_focus"
            sub_focus.mkdir()
            comp, proc = self._launch(sub_focus, ["--screen", "02_control_populated"], height=923)
            try:
                comp.wait_ready(timeout=15.0)
                h_init = comp.last_frame_hash
                sidebar_top_init = comp.region_hash(0, 0, 120, 40)
                project_pill_init = comp.region_hash(535, 370, 620, 410)
                machine_pill_init = comp.region_hash(615, 370, 780, 410)
                composer_init = comp.region_hash(535, 415, 1155, 515)

                # Keyboard Tab focuses first focusable button (sidebar toggle) with visible focusRing.
                comp.key_tap("tab")
                comp.wait_frame_change(h_init, timeout=5.0)
                sidebar_top_tabbed = comp.region_hash(0, 0, 120, 40)
                self.assertNotEqual(
                    sidebar_top_tabbed,
                    sidebar_top_init,
                    "Tab navigation must paint keyboard :focus-visible ring on sidebar toggle",
                )

                # Pointer click on Project pill updates the selected project label ("Default" -> "default")
                # and transfers logical focus quietly (clears sidebar toggle's keyboard ring, paints NO
                # focusRing border around the Project pill).
                comp.pointer_click(575, 390)
                comp.wait_region_change(0, 0, 120, 40, sidebar_top_tabbed, timeout=5.0)
                self.assertEqual(
                    comp.region_hash(0, 0, 120, 40),
                    sidebar_top_init,
                    "pointer click must clear previous keyboard focusRing",
                )
                project_pill_pointer = comp.region_hash(535, 370, 620, 410)
                self.assertNotEqual(
                    project_pill_pointer,
                    project_pill_init,
                    "clicking Project pill must visibly update its selected project label",
                )

                # Pressing Tab from the pointer-focused Project pill moves focus to the adjacent
                # machine pill (`720`) AND turns :focus-visible back on. Project pill is now unfocused
                # and must match its pointer-focused pixels identically (proving pointer click painted no focusRing).
                comp.key_tap("tab")
                machine_pill_tabbed = comp.wait_region_change(615, 370, 780, 410, machine_pill_init, timeout=5.0)
                self.assertEqual(
                    comp.region_hash(535, 370, 620, 410),
                    project_pill_pointer,
                    "pointer click on Project pill must stay visually quiet (no focusRing)",
                )

                # Pressing Shift+Tab back onto Project pill with keyboard :focus-visible MUST paint its focusRing.
                comp.key_tap("tab", MOD_SHIFT)
                project_pill_kbd = comp.wait_region_change(535, 370, 620, 410, project_pill_pointer, timeout=5.0)
                self.assertNotEqual(
                    project_pill_kbd,
                    project_pill_pointer,
                    "keyboard Shift+Tab onto Project pill must paint visible :focus-visible ring",
                )

                # Tab back onto machine pill (`720`), then pointer-click composer (`1`) to draw caret
                # cleanly and clear the previous keyboard ring on the machine pill.
                comp.key_tap("tab")
                comp.wait_region_change(615, 370, 780, 410, machine_pill_init, timeout=5.0)
                self.assertEqual(comp.region_hash(615, 370, 780, 410), machine_pill_tabbed)
                comp.pointer_click(845, 435)
                comp.wait_region_change(535, 415, 1155, 515, composer_init, timeout=5.0)
                self.assertEqual(
                    comp.region_hash(615, 370, 780, 410),
                    machine_pill_init,
                    "clicking composer must clear keyboard focusRing on machine pill",
                )
            finally:
                self._shutdown(comp, proc)

            # 2. Scrollbar track jump + thumb drag on overflowing 03_mission_transcript (1470x600).
            sub_scroll = root / "scrollbar_fixture"
            sub_scroll.mkdir()
            comp, proc = self._launch(sub_scroll, ["--screen", "03_mission_transcript"], height=600)
            try:
                comp.wait_ready(timeout=15.0)
                tx_top = comp.region_hash(240, 45, 1450, 485)

                # Track jump: press in right-edge scrollbar gutter (x=1464) below thumb -> jumps immediately.
                comp.pointer_press(1464, 465)
                tx_jumped = comp.wait_region_change(240, 45, 1450, 485, tx_top, timeout=5.0)

                # Continue holding and drag upward toward top -> scrolls smoothly back up.
                comp.pointer_move(1464, 60)
                tx_dragged_up = comp.wait_region_change(240, 45, 1450, 485, tx_jumped, timeout=5.0)
                comp.pointer_release(1464, 60)

                # Direct thumb drag downward from near top -> scrolls back down.
                comp.pointer_press(1464, 90)
                comp.pointer_move(1464, 340)
                tx_thumb_down = comp.wait_region_change(240, 45, 1450, 485, tx_dragged_up, timeout=5.0)
                comp.pointer_release(1464, 340)
                self.assertNotEqual(tx_thumb_down, tx_dragged_up)
            finally:
                self._shutdown(comp, proc)

            # 3. Live mission scrollbar thumb drag upward unpins Orb.Scroll during incoming stream.
            core_state = DisposableCoreState()

            def count_req(method: str, prefix: str) -> int:
                with core_state.lock:
                    return sum(1 for m, p, _ in core_state.requests_log if m == method and p.startswith(prefix))

            sub_live = root / "scrollbar_live"
            sub_live.mkdir()
            with ThreadingHTTPServer(("127.0.0.1", 0), make_core_handler(core_state)) as server:
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    api_url = f"http://127.0.0.1:{server.server_port}"
                    (sub_live / "connection.json").write_text(json.dumps({"api_url": api_url, "token": "u6-sb-token"}))
                    comp, proc = self._launch(sub_live, [], height=923)
                    try:
                        comp.wait_ready(timeout=15.0)
                        _wait_until("roster /api/auth/me", lambda: count_req("GET", "/api/auth/me") >= 1)
                        comp.wait_text_input(True, timeout=10.0)

                        comp.key_tap("n", MOD_CTRL)
                        comp.wait_text_input(True, timeout=5.0)
                        comp.type_ascii("Scrollbar drag test")
                        comp.key_tap("return")

                        created = _wait_until(
                            "POST /api/control/missions",
                            lambda: core_state.missions[0] if core_state.missions else None,
                        )
                        mid = created["id"]
                        tx_before = comp.region_hash(240, 45, 1450, 810)
                        _wait_until("mission /open", lambda: count_req("GET", f"/api/control/missions/{mid}/open") >= 1)
                        _wait_until(
                            "mission /current-bubble settled",
                            lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") >= 2,
                            timeout=6.0,
                        )
                        tx_bottom = comp.wait_region_change(240, 45, 1450, 810, tx_before, timeout=5.0)

                        # Drag right-edge scrollbar thumb upward from bottom (y=790 -> y=120) to unpin Orb.Scroll.
                        comp.pointer_press(1464, 790)
                        comp.pointer_move(1464, 120)
                        tx_dragged = comp.wait_region_change(240, 45, 1450, 810, tx_bottom, timeout=5.0)
                        comp.pointer_release(1464, 120)

                        polls_before = count_req("GET", f"/api/control/missions/{mid}/current-bubble")
                        with core_state.lock:
                            core_state.append_assistant_delta(mid, "Streamed delta 50: arrived after scrollbar drag up.")
                        _wait_until(
                            "current-bubble polls after scrollbar drag",
                            lambda: count_req("GET", f"/api/control/missions/{mid}/current-bubble") >= polls_before + 2,
                            timeout=6.0,
                        )
                        self.assertEqual(
                            comp.region_hash(240, 45, 1450, 810),
                            tx_dragged,
                            "dragging scrollbar upward must unpin Orb.Scroll so incoming deltas do not jump viewport",
                        )

                        # Track jump near bottom re-pins Orb.Scroll and reveals the new streamed delta.
                        comp.pointer_click(1464, 800)
                        tx_repinned = comp.wait_region_change(240, 45, 1450, 810, tx_dragged, timeout=5.0)
                        self.assertNotEqual(tx_repinned, tx_dragged)
                    finally:
                        self._shutdown(comp, proc)
                finally:
                    server.shutdown()

    def test_u6a_live_wayland_writes_and_separate_core_client(self) -> None:
        """Roadmap Row U6a end-to-end verification:
        Launch `--leanui` against a persistent SQLite-backed local Core, type and commit
        Wayland IME text to create a mission, reject stale IME serials, send a follow-up
        with IME text, verify busy Archive is refused while active, stop the running turn,
        archive the mission, restart Core on the same SQLite DB, and verify from a separate
        independent Core HTTP client that the new mission ID, exact submitted texts, stopped
        turn, and persisted archive state all survived."""
        token = "u6a-wayland-e2e-token"
        expected_initial = "Indigo U6a 日本語 🚀"
        expected_followup = "Follow-up café 漢字テスト ✓"

        def http_get_json(base_url: str, path: str) -> dict | list:
            req = urllib.request.Request(
                base_url + path,
                headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                return json.loads(resp.read().decode("utf-8"))

        with tempfile.TemporaryDirectory(prefix="orb-u6a-e2e-") as td:
            tmp = Path(td)
            db_path = tmp / "core.db"
            server1, db1, lock1, reqs1, _state1 = _start_sqlite_core(db_path, token)
            base1 = f"http://127.0.0.1:{server1.server_port}"

            def count_req1(method: str, prefix: str) -> int:
                with lock1:
                    return sum(1 for m, p, _c in reqs1 if m == method and p.startswith(prefix))

            try:
                (tmp / "connection.json").write_text(json.dumps({"api_url": base1, "token": token}))
                comp, proc = self._launch(tmp, [], via_leanui_flag=True)
                try:
                    comp.wait_ready(timeout=15.0)
                    _wait_until("U6a initial /api/auth/me", lambda: count_req1("GET", "/api/auth/me") >= 1)
                    # Initial live connect auto-focuses New Agent composer and enables zwp_text_input_v3.
                    comp.wait_text_input(True, timeout=10.0)

                    # 1. Type ASCII + Wayland IME preedit (Return must be blocked while preedit is active),
                    #    multi-byte UTF-8 commit + delete_surrounding_text replacement, then Create via Return.
                    comp.type_ascii("Indigo U6a ")
                    h_pre_ime = comp.last_frame_hash
                    comp.ime_edit(commit="", preedit="にほん")
                    h_preedit = comp.wait_frame_change(h_pre_ime, timeout=5.0)
                    comp.key_tap("return")
                    time.sleep(0.15)
                    self.assertEqual(
                        count_req1("POST", "/api/control/missions"),
                        0,
                        "Return must not submit Create while IME preedit is active",
                    )
                    comp.ime_edit(commit="日本猫", preedit="")
                    h_cat = comp.wait_frame_change(h_preedit, timeout=5.0)
                    comp.ime_edit(commit="語 🚀", preedit="", del_before=len("猫".encode("utf-8")))
                    comp.wait_frame_change(h_cat, timeout=5.0)
                    # Inject a stale-serial done event (serial - 1); Wayland.lean must drop it cleanly
                    # before the subsequent Return on the same Wayland socket submits the draft.
                    with comp._lock:
                        stale_serial = max(0, comp.text_input_commit_count - 1)
                    comp.ime_edit(commit="STALE_LEAK", preedit="", serial=stale_serial)
                    comp.key_tap("return")

                    _wait_until("U6a POST /api/control/missions", lambda: count_req1("POST", "/api/control/missions") >= 1)
                    missions = http_get_json(base1, "/api/control/missions")
                    self.assertEqual(len(missions), 1, missions)
                    mid = missions[0]["id"]
                    mpath = f"/api/control/missions/{mid}"

                    # Wait for Turn 1 completion so the mission transitions to awaiting_user and composer unlocks.
                    _wait_until("U6a Turn 1 completed", lambda: http_get_json(base1, mpath)["status"] == "awaiting_user")
                    polls_turn1 = count_req1("GET", f"{mpath}/current-bubble")
                    _wait_until(
                        "U6a client observed Turn 1 awaiting_user",
                        lambda: count_req1("GET", f"{mpath}/current-bubble") >= polls_turn1 + 2,
                        timeout=6.0,
                    )

                    # 2. Type + commit IME follow-up text in the Mission Transcript composer and Send via Return.
                    comp.pointer_click(700, 850)
                    comp.wait_text_input(True, timeout=5.0)
                    comp.type_ascii("Follow-up ")
                    comp.ime_edit(commit="café ", preedit="かんじ")
                    comp.key_tap("return")
                    time.sleep(0.15)
                    self.assertEqual(
                        count_req1("POST", "/api/control/message"),
                        0,
                        "Return must not submit Send while IME preedit is active",
                    )
                    comp.ime_edit(commit="漢字仮", preedit="")
                    comp.ime_edit(commit="テスト ✓", preedit="", del_before=len("仮".encode("utf-8")))
                    polls_pre_send = count_req1("GET", f"{mpath}/current-bubble")
                    comp.key_tap("return")

                    _wait_until("U6a POST /api/control/message", lambda: count_req1("POST", "/api/control/message") >= 1)
                    _wait_until("U6a Turn 2 active", lambda: http_get_json(base1, mpath)["status"] == "active")
                    _wait_until(
                        "U6a client observed Turn 2 streaming",
                        lambda: count_req1("GET", f"{mpath}/current-bubble") >= polls_pre_send + 2,
                        timeout=6.0,
                    )

                    # 3. Verify busy Archive is refused while Turn 2 is active (single project `source` is auto-expanded;
                    #    mission row sits at y=287..317, context menu Archive row 1 sits at y=333..359 center 346).
                    menu_out_pre = comp.region_hash(225, 310, 325, 405)
                    comp.pointer_click(100, 303, button=0x111)
                    comp.wait_region_change(225, 310, 325, 405, menu_out_pre, timeout=5.0)
                    status_checks_pre = count_req1("GET", f"{mpath}?include_history=false")
                    toast_pre = comp.region_hash(1020, 770, 1465, 815)
                    comp.pointer_click(160, 346)
                    _wait_until(
                        "U6a busy archive pre-check",
                        lambda: count_req1("GET", f"{mpath}?include_history=false") > status_checks_pre,
                        timeout=6.0,
                    )
                    comp.wait_region_change(1020, 770, 1465, 815, toast_pre, timeout=5.0)
                    self.assertEqual(http_get_json(base1, mpath)["status"], "active")

                    # 4. Stop the running turn via Stop button click (widget 2 at x=1197, y=850).
                    polls_pre_stop = count_req1("GET", f"{mpath}/current-bubble")
                    comp.pointer_click(1197, 850)
                    _wait_until("U6a Turn 2 stopped", lambda: http_get_json(base1, mpath)["status"] == "interrupted")
                    _wait_until(
                        "U6a client observed interrupted",
                        lambda: count_req1("GET", f"{mpath}/current-bubble") >= polls_pre_stop + 2,
                        timeout=6.0,
                    )

                    # 5. Archive the stopped mission via Wayland right-click context menu -> Archive.
                    menu_out_pre2 = comp.region_hash(225, 310, 325, 405)
                    comp.pointer_click(100, 303, button=0x111)
                    comp.wait_region_change(225, 310, 325, 405, menu_out_pre2, timeout=5.0)
                    dock_pre_arch = comp.region_hash(450, 820, 1220, 915)
                    comp.pointer_click(160, 346)
                    _wait_until(
                        "U6a mission archived on Core",
                        lambda: http_get_json(base1, mpath)["status"] == "acknowledged",
                    )
                    comp.wait_region_change(450, 820, 1220, 915, dock_pre_arch, timeout=5.0)
                    comp.wait_text_input(True, timeout=5.0)
                finally:
                    self._shutdown(comp, proc)
            finally:
                server1.shutdown()
                server1.server_close()
                db1.close()

            # 6. Restart Core on the same SQLite DB and verify via a SEPARATE independent Core HTTP client.
            server2, db2, _lock2, _reqs2, _state2 = _start_sqlite_core(db_path, token)
            base2 = f"http://127.0.0.1:{server2.server_port}"
            try:
                all_missions = http_get_json(base2, "/api/control/missions")
                self.assertEqual([m["id"] for m in all_missions], [mid])
                mission = http_get_json(base2, f"/api/control/missions/{mid}")
                events = http_get_json(base2, f"/api/control/missions/{mid}/events")
                user_messages = [e["content"] for e in events if e["event_type"] == "user_message"]
                stopped_events = [e for e in events if e["event_type"] == "turn_stopped"]

                self.assertEqual(mission["id"], mid)
                self.assertEqual(mission["status"], "acknowledged")
                self.assertEqual(mission["stopped_turns"], 1)
                self.assertEqual(user_messages, [expected_initial, expected_followup])
                self.assertEqual(len(stopped_events), 1)
            finally:
                server2.shutdown()
                server2.server_close()
                db2.close()


if __name__ == "__main__":
    unittest.main()
