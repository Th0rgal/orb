#!/usr/bin/env bash
# Verify normal mode maps a Wayland window and stays alive, then close it via
# the compositor; golden and benchmark modes must finish without a compositor.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN=${1:-"$ROOT/target/native/orb-desktop-native"}
WESTON=${WESTON:-weston}
work=$(mktemp -d)
compositor_pid=
app_pid=
proxy_pid=
cleanup() {
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$compositor_pid" ]]; then kill "$compositor_pid" 2>/dev/null || true; wait "$compositor_pid" 2>/dev/null || true; fi
  if [[ -n "$proxy_pid" ]]; then kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
export XDG_RUNTIME_DIR="$work/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY=leanui-smoke
"$WESTON" --backend=headless --renderer=pixman --shell=kiosk-shell.so --socket="$WAYLAND_DISPLAY" --idle-time=0 --no-config --log="$work/weston.log" >"$work/compositor.log" 2>&1 &
compositor_pid=$!
for ((i=0;i<100;i++)); do
  [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break
  if ! kill -0 "$compositor_pid" 2>/dev/null; then cat "$work/compositor.log" "$work/weston.log"; exit 1; fi
  sleep .1
done
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]
# Relay the real compositor protocol, preserving SCM_RIGHTS shared-memory FDs.
# Once the window maps, inject the actual xdg_toplevel.close event. Weston has
# no standard command to close a kiosk window without keyboard hardware.
python3 - "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/leanui-proxy" <<'PYPROXY' &
import array
import os
import select
import signal
import socket
import struct
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[2])
server.listen(1)
client, _ = server.accept()
upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
upstream.connect(sys.argv[1])
base, surfaces, toplevel = set(), set(), None
pending = b''
close_requested = False

def request_close(*_):
    global close_requested
    close_requested = True

signal.signal(signal.SIGUSR1, request_close)
while True:
    if close_requested and toplevel:
        client.sendall(struct.pack('II', toplevel, (8 << 16) | 1))
        close_requested = False
    ready, _, _ = select.select([client, upstream], [], [], .05)
    for src in ready:
        data, ancillary, flags, _ = src.recvmsg(65536, socket.CMSG_SPACE(256))
        if not data:
            sys.exit(0)
        if src is client:
            pending += data
            while len(pending) >= 8:
                obj, header = struct.unpack_from('II', pending)
                size, opcode = header >> 16, header & 65535
                if size < 8:
                    raise RuntimeError('invalid Wayland packet')
                if len(pending) < size:
                    break
                packet, pending = pending[:size], pending[size:]
                # wl_registry.bind: name, interface string, version, new_id.
                if opcode == 0 and len(packet) >= 24:
                    length = struct.unpack_from('I', packet, 12)[0]
                    if 0 < length < size-16 and packet[16:16+length] == b'xdg_wm_base\0':
                        base.add(struct.unpack_from('I', packet, size-4)[0])
                if obj in base and opcode == 2:
                    surfaces.add(struct.unpack_from('I', packet, 8)[0])
                if obj in surfaces and opcode == 1:
                    toplevel = struct.unpack_from('I', packet, 8)[0]
        dst = upstream if src is client else client
        sent = dst.sendmsg([data], ancillary)
        if sent < len(data):
            dst.sendall(data[sent:])
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                descriptors = array.array('i')
                descriptors.frombytes(payload[:len(payload)-len(payload)%descriptors.itemsize])
                for fd in descriptors:
                    os.close(fd)
PYPROXY
proxy_pid=$!
for ((i=0;i<100;i++)); do [[ -S "$XDG_RUNTIME_DIR/leanui-proxy" ]] && break; sleep .1; done
WAYLAND_DISPLAY=leanui-proxy WAYLAND_DEBUG=1 "$BIN" --width 640 --height 480 >"$work/window.log" 2>&1 &
app_pid=$!
for ((i=0;i<100;i++)); do
  if ! kill -0 "$app_pid" 2>/dev/null; then cat "$work/window.log"; exit 1; fi
  if rg -q 'wl_surface@[0-9]+\.attach\(wl_buffer@' "$work/window.log"; then break; fi
  sleep .1
done
rg -q 'wl_surface@[0-9]+\.attach\(wl_buffer@' "$work/window.log"
sleep 1
kill -0 "$app_pid"
kill -USR1 "$proxy_pid"
for ((i=0;i<100;i++)); do
  kill -0 "$app_pid" 2>/dev/null || break
  sleep .1
done
if kill -0 "$app_pid" 2>/dev/null; then echo 'window remained alive after xdg_toplevel.close' >&2; cat "$work/window.log"; exit 1; fi
wait "$app_pid"
app_pid=
wait "$proxy_pid"
proxy_pid=
export WAYLAND_DISPLAY=missing-compositor
for mode in single all bench; do
  case "$mode" in
    single) timeout 60 "$BIN" --headless-golden "$work/single.png" --width 320 --height 240 ;;
    all) timeout 60 "$BIN" --headless-golden-all "$work/all" --width 320 --height 240 ;;
    bench) timeout 60 "$BIN" --bench 2 --width 320 --height 240 ;;
  esac
done
[[ -s "$work/single.png" && $(find "$work/all" -name '*.png' | wc -l) -eq 36 ]]
echo 'LeanUI window and headless lifecycle smoke passed'
