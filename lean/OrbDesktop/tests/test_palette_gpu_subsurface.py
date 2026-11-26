"""The Cmd+Shift+F palette on its own Vulkan subsurface, replayed under headless Weston.

`linux_shell/tests/palette_gpu_harness.c` stands in for the hybrid shell: it opens the real
palette over a striped background, moves the selection, types, and closes it, asking Weston for
a screenshot while open and after close. With `ORB_LEANUI_GPU=lavapipe` the palette must present
through Vulkan on a subsurface above the window and look like the CPU palette
(`ORB_LEANUI_GPU=0`); after close no overlay may remain. Needs weston (with
weston-screenshooter), GTK3/WebKitGTK/Wayland development files and a built
`target/native/orb-desktop-native`.
"""
import glob
import os
import shutil
import struct
import subprocess
import tempfile
import time
import unittest
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BINARY = os.environ.get("ORB_LEANUI_TEST_BINARY", os.path.join(ROOT, "target", "native", "orb-desktop-native"))
WESTON = os.environ.get("ORB_TEST_WESTON") or shutil.which("weston")
SHOOTER = os.environ.get("ORB_TEST_SCREENSHOOTER") or shutil.which("weston-screenshooter")
SHELL = os.path.join(ROOT, "linux_shell")


def build_harness(out):
    cflags = os.environ.get("ORB_TEST_HARNESS_CFLAGS")
    libs = os.environ.get("ORB_TEST_HARNESS_LIBS")
    if cflags is None or libs is None:
        pkgs = ["gtk+-3.0", "webkit2gtk-4.1", "wayland-client"]
        cflags = subprocess.check_output(["pkg-config", "--cflags"] + pkgs, text=True)
        libs = subprocess.check_output(["pkg-config", "--libs"] + pkgs, text=True)
    sources = [os.path.join(SHELL, "tests", "palette_gpu_harness.c")] + [
        os.path.join(SHELL, f) for f in ("gtk_leanui_palette.c", "gtk_leanui_palette_rpc.c", "gtk_wayland_subsurface.c")]
    subprocess.check_call(["cc", "-std=gnu11", "-O1", "-fPIC", "-shared", "-Wall", "-Wextra", "-Werror",
                           "-DORB_HAS_WEBKITGTK", "-DORB_HAS_WAYLAND", "-DORB_LEANUI_HOST", "-I", SHELL,
                           *cflags.split(), *sources, "-o", out, *libs.split(), "-lm", "-Wl,-z,defs"])


def load_png(path):
    """Decode an 8-bit RGB/RGBA non-interlaced PNG to (width, height, RGB bytes)."""
    with open(path, "rb") as f:
        data = f.read()
    pos, idat = 8, b""
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and interlace == 0 and ctype in (2, 6), (depth, ctype, interlace)
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride = zlib.decompress(idat), w * bpp
    prev, out = bytearray(stride), bytearray()
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += bytes(line[j] for j in range(stride) if j % bpp < 3)
        prev = line
    return w, h, bytes(out)


def max_delta(a, b):
    assert a[:2] == b[:2]
    return max(abs(x - y) for x, y in zip(a[2], b[2]))


class PaletteGpuSubsurface(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for need in (BINARY, WESTON, SHOOTER):
            if not need or not os.path.exists(need):
                if os.environ.get("ORB_REQUIRE_PALETTE_GPU") == "1":
                    raise AssertionError(f"missing {need}")
                raise unittest.SkipTest(f"missing {need}")
        cls.tmp = tempfile.mkdtemp(prefix="orb-palette-gpu-")
        cls.harness = os.path.join(cls.tmp, "palette_gpu_harness.so")
        build_harness(cls.harness)
        cls.runs = {(mode, light): cls.run_harness(mode, light) for mode in ("lavapipe", "0") for light in (False, True)}

    @classmethod
    def run_harness(cls, mode, light):
        out = os.path.join(cls.tmp, f"{mode}-{'light' if light else 'dark'}")
        runtime = os.path.join(out, "xdg")
        os.makedirs(runtime, mode=0o700)
        env = dict(os.environ, XDG_RUNTIME_DIR=runtime)
        weston = subprocess.Popen([WESTON, "--backend=headless-backend.so", "--socket=wl-palette", "--width=1000",
                                   "--height=700", "--renderer=pixman", "--shell=kiosk-shell.so", "--debug"],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if os.path.exists(os.path.join(runtime, "wl-palette")):
                    break
                time.sleep(0.1)
            env.update(WAYLAND_DISPLAY="wl-palette", GDK_BACKEND="wayland", NO_AT_BRIDGE="1", GTK_A11Y="none",
                       ORB_LEANUI_GPU=mode, HARNESS_OUT=out, HARNESS_SCREENSHOOTER=SHOOTER)
            if light:
                env["HARNESS_LIGHT"] = "1"
            log = subprocess.run([BINARY, "--gtk-sidebar-host", cls.harness], env=env, capture_output=True,
                                 text=True, timeout=120).stdout
        finally:
            weston.terminate()
            weston.wait(timeout=10)
        lines = [l for l in log.splitlines() if l.startswith("harness: shot")]
        shots = [load_png(p) for p in sorted(glob.glob(os.path.join(out, "*.png")))]
        return lines, shots

    def test_gpu_palette_presents_on_subsurface(self):
        for light in (False, True):
            lines, shots = self.runs[("lavapipe", light)]
            self.assertEqual(len(shots), 2, lines)
            self.assertIn("gpu_active=1", lines[0])
            self.assertIn("gpu_active=0", lines[1])

    def test_gpu_palette_matches_cpu_palette(self):
        for light in (False, True):
            gpu, cpu = self.runs[("lavapipe", light)][1], self.runs[("0", light)][1]
            self.assertIn("gpu_active=0", self.runs[("0", light)][0][0])
            self.assertLessEqual(max_delta(gpu[0], cpu[0]), 3)

    def test_closing_leaves_no_overlay(self):
        plain = self.runs[("0", False)][1][1]
        for key, (_, shots) in self.runs.items():
            self.assertEqual(max_delta(shots[1], plain), 0, key)


if __name__ == "__main__":
    unittest.main()
