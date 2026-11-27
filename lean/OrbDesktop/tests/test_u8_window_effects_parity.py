#!/usr/bin/env python3
"""End-to-end U8 window effects verification & side-by-side capture harness.

Drives the compiled `orb-desktop-native` binary (`--leanui`) against a real AF_UNIX
Wayland compositor (`wl_compositor` v4, `wl_shm` v1 `ARGB8888`, `xdg_wm_base` v4,
`wp_viewporter`, `wp_fractional_scale_manager_v1`) and a local disposable HTTP Core
fixture with active, paused, completed, failed, and awaiting_user missions.

Verifies:
1. Wayland `xdg_toplevel.set_app_id` == `"orb-desktop"` (parity with WebKit/hybrid
   and `nix/orb-desktop.hyprland.conf`).
2. `wl_shm_pool.create_buffer` uses premultiplied `WL_SHM_FORMAT_ARGB8888` (`0`).
3. Live premultiplied `ARGB8888` surfaces match WebKit/hybrid Linux alphas:
   - dark: sidebar `199/255` (78%), main canvas/header `255/255` (100% solid)
   - light: sidebar `184/255` (72%), main canvas/header `255/255` (100% solid)
4. 12px squircle rounded window corners have `alpha == 0` at all 4 exterior corners
   and smooth anti-aliased alpha along the corner arc — preserved both in normal view
   and when `Ctrl+K` opens the backdrop-blur search modal.
5. Active mission spinner animates smoothly across frames (accent-tinted), while
   paused mission badge renders crisp stationary muted vertical bars.
6. Produces side-by-side Hyprland vibrancy-composited captures (wallpaper + Kawase/box
   blur + vibrancy) comparing pure `--leanui` against the WebKit/hybrid Linux reference
   when `ORB_U8_CAPTURE_DIR` is set (and validates metrics in every run).
"""

from __future__ import annotations

import contextlib
import hashlib
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

try:
    import numpy as np
    from PIL import Image, ImageFilter
    HAS_IMAGE_DEPS = True
except ModuleNotFoundError:
    np = Image = ImageFilter = None
    HAS_IMAGE_DEPS = False


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_wayland_u6_session as u6  # noqa: E402


def find_bin() -> Path:
    env_bin = os.environ.get("ORB_LEANUI_TEST_BINARY")
    if env_bin and Path(env_bin).is_file():
        return Path(env_bin)
    for cand in (
        ROOT / "target/native/orb-desktop-native",
        ROOT / "lean/OrbDesktop/.lake/build/bin/orb-desktop-native",
    ):
        if cand.is_file():
            return cand
    raise FileNotFoundError("orb-desktop-native binary not found")


class U8WaylandCompositor(u6.WaylandTestCompositor):
    """Real AF_UNIX Wayland compositor recording `app_id`, `wl_shm` format, and ARGB8888 frames."""

    def __init__(self, runtime_dir: Path, display_name: str, width: int = 960, height: int = 640, scale120: int = 120):
        self.app_ids: list[str] = []
        self.titles: list[str] = []
        self.shm_formats: list[int] = []
        self.scale120 = scale120
        self.frame_history: list[bytes] = []
        super().__init__(runtime_dir, display_name, width=width, height=height)

    def _handle_request(self, obj_id: int, opcode: int, body: bytes, fds: list[int]) -> None:
        iface = self._objects.get(obj_id, "")
        if iface == "wl_shm_pool" and opcode == 0:  # create_buffer(..., format)
            _bid, _off, _w, _h, _stride, fmt = struct.unpack_from("=IiiiiI", body, 0)
            self.shm_formats.append(fmt)
        elif iface == "xdg_toplevel":
            if opcode == 2 and len(body) >= 4:  # set_title(s)
                slen = struct.unpack_from("=I", body, 0)[0]
                if slen > 0 and 4 + slen <= len(body):
                    self.titles.append(body[4 : 4 + slen - 1].decode("utf-8", errors="replace"))
            elif opcode == 3 and len(body) >= 4:  # set_app_id(s)
                slen = struct.unpack_from("=I", body, 0)[0]
                if slen > 0 and 4 + slen <= len(body):
                    self.app_ids.append(body[4 : 4 + slen - 1].decode("utf-8", errors="replace"))
                    self._cond.notify_all()
        elif iface == "wp_fractional_scale_manager_v1" and opcode == 1:
            fsid = struct.unpack_from("=I", body, 0)[0]
            self._objects[fsid] = "wp_fractional_scale_v1"
            self._send(u6._wl_msg(fsid, 0, struct.pack("=I", self.scale120)))
            return
        prev_commits = self.commit_count
        super()._handle_request(obj_id, opcode, body, fds)
        if self.commit_count > prev_commits and self.last_frame_bytes:
            self.frame_history.append(self.last_frame_bytes)
            if len(self.frame_history) > 48:
                self.frame_history.pop(0)


def bgra_premul_to_rgba_array(raw: bytes, w: int, h: int) -> "np.ndarray":
    """Convert little-endian premultiplied ARGB8888 (B, G, R, A) to premultiplied RGBA (H, W, 4)."""
    arr = np.frombuffer(raw, dtype=np.uint8).reshape((h, w, 4))
    return arr[:, :, [2, 1, 0, 3]].copy()


def hyprland_vibrancy_composite(fg_premul_rgba: "np.ndarray", pad: int = 36) -> "Image.Image":
    """Composite a premultiplied RGBA window over a colorful wallpaper using Hyprland's blur+vibrancy model.

    Matches `nix/orb-desktop.hyprland.conf`: `size=10, passes=3, vibrancy=0.25, vibrancy_darkness=0.25`.
    """
    h, w, _ = fg_premul_rgba.shape
    cw, ch = w + 2 * pad, h + 2 * pad
    yy, xx = np.mgrid[0:ch, 0:cw].astype(np.float32)
    wp = np.zeros((ch, cw, 3), dtype=np.float32)
    wp[:, :, 0] = 48.0 + 185.0 * (xx / cw) + 35.0 * np.sin(yy / 28.0)
    wp[:, :, 1] = 72.0 + 130.0 * (yy / ch) + 30.0 * np.cos(xx / 36.0)
    wp[:, :, 2] = 165.0 - 70.0 * (xx / cw) + 55.0 * np.sin((xx + yy) / 42.0)
    band = np.exp(-(((xx - yy * 0.45 - 80.0) / 55.0) ** 2))
    wp[:, :, 0] += 110.0 * band
    wp[:, :, 1] += 70.0 * band
    wp[:, :, 2] += 40.0 * band
    wp_u8 = np.clip(wp, 0, 255).astype(np.uint8)

    blurred_img = Image.fromarray(wp_u8, "RGB").filter(ImageFilter.GaussianBlur(radius=14))
    blur_f = np.asarray(blurred_img, dtype=np.float32) / 255.0
    lum = 0.2126 * blur_f[:, :, 0:1] + 0.7152 * blur_f[:, :, 1:2] + 0.0722 * blur_f[:, :, 2:3]
    vibrant = np.clip(lum + (blur_f - lum) * 1.25, 0.0, 1.0)
    vibrant = np.clip((vibrant - 0.5) * 0.85 + 0.5, 0.0, 1.0) * 0.98
    blur_region = vibrant[pad : pad + h, pad : pad + w]

    fg = fg_premul_rgba.astype(np.float32) / 255.0
    alpha = fg[:, :, 3:4]
    wp_region = wp_u8[pad : pad + h, pad : pad + w].astype(np.float32) / 255.0
    bg_under = np.where(alpha > 0.0, blur_region, wp_region)
    comp = np.clip(fg[:, :, :3] + bg_under * (1.0 - alpha), 0.0, 1.0)

    canvas = wp_u8.copy()
    canvas[pad : pad + h, pad : pad + w] = (comp * 255.0 + 0.5).astype(np.uint8)
    return Image.fromarray(canvas, "RGB")


def build_webkit_reference_surface(w: int, h: int, is_dark: bool, sidebar_w: int = 220, radius: int = 12) -> "np.ndarray":
    """Build the exact WebKit/hybrid Linux reference premultiplied RGBA surface mask from `orb/src/styles.css`."""
    sb_rgb = (18, 19, 19) if is_dark else (249, 249, 247)
    sb_a = 199 if is_dark else 184
    main_rgb = (20, 20, 20) if is_dark else (255, 255, 255)
    sep_rgb = (44, 44, 44) if is_dark else (232, 231, 226)
    surf = np.zeros((h, w, 4), dtype=np.uint8)
    surf[:, : sidebar_w - 1, 0] = (sb_rgb[0] * sb_a + 127) // 255
    surf[:, : sidebar_w - 1, 1] = (sb_rgb[1] * sb_a + 127) // 255
    surf[:, : sidebar_w - 1, 2] = (sb_rgb[2] * sb_a + 127) // 255
    surf[:, : sidebar_w - 1, 3] = sb_a
    surf[:, sidebar_w - 1 : sidebar_w, :3] = sep_rgb
    surf[:, sidebar_w - 1 : sidebar_w, 3] = 255
    surf[:, sidebar_w:, :3] = main_rgb
    surf[:, sidebar_w:, 3] = 255
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32) + 0.5
    hx, hy = w / 2.0, h / 2.0
    qx = np.maximum(np.abs(xx - hx) - hx + radius, 0.0)
    qy = np.maximum(np.abs(yy - hy) - hy + radius, 0.0)
    dist = np.power(qx**4 + qy**4, 0.25) - radius
    cov = np.clip(0.5 - dist, 0.0, 1.0)
    for c in range(4):
        surf[:, :, c] = np.clip(surf[:, :, c].astype(np.float32) * cov + 0.5, 0, 255).astype(np.uint8)
    return surf


def make_seeded_core_state() -> u6.DisposableCoreState:
    state = u6.DisposableCoreState()
    state.missions = [
        {
            "id": "u8-m-active",
            "title": "Active badge mission",
            "status": "active",
            "project_slug": "source",
            "backend": "antigravity",
            "model": "gemini-4-neon",
            "updated_at": "2026-11-27T02:00:05Z",
            "created_at": "2026-11-27T02:00:00Z",
        },
        {
            "id": "u8-m-paused",
            "title": "Paused badge mission",
            "status": "paused",
            "project_slug": "source",
            "backend": "antigravity",
            "model": "gemini-4-neon",
            "updated_at": "2026-11-27T02:00:04Z",
            "created_at": "2026-11-27T02:00:00Z",
        },
        {
            "id": "u8-m-done",
            "title": "Completed badge mission",
            "status": "completed",
            "project_slug": "source",
            "backend": "antigravity",
            "model": "gemini-4-neon",
            "updated_at": "2026-11-27T02:00:03Z",
            "created_at": "2026-11-27T02:00:00Z",
        },
        {
            "id": "u8-m-fail",
            "title": "Failed badge mission",
            "status": "failed",
            "project_slug": "source",
            "backend": "antigravity",
            "model": "gemini-4-neon",
            "updated_at": "2026-11-27T02:00:02Z",
            "created_at": "2026-11-27T02:00:00Z",
        },
        {
            "id": "u8-m-wait",
            "title": "Waiting badge mission",
            "status": "awaiting_user",
            "project_slug": "source",
            "backend": "antigravity",
            "model": "gemini-4-neon",
            "updated_at": "2026-11-27T02:00:01Z",
            "created_at": "2026-11-27T02:00:00Z",
        },
    ]
    return state


class U8WindowEffectsParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bin = find_bin()
        cls.capture_dir = Path(os.environ["ORB_U8_CAPTURE_DIR"]) if os.environ.get("ORB_U8_CAPTURE_DIR") else None
        if cls.capture_dir:
            cls.capture_dir.mkdir(parents=True, exist_ok=True)

    def _run_session(self, *, is_dark: bool, width: int = 960, height: int = 640):
        core_state = make_seeded_core_state()

        def count_req(method: str, prefix: str) -> int:
            with core_state.lock:
                return sum(1 for m, p, _ in core_state.requests_log if m == method and p.startswith(prefix))

        with (
            tempfile.TemporaryDirectory(prefix="orb-u8-wl-") as tmp,
            ThreadingHTTPServer(("127.0.0.1", 0), u6.make_core_handler(core_state)) as server,
        ):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            tmp_path = Path(tmp)
            rt_dir = tmp_path / "runtime"
            rt_dir.mkdir(mode=0o700)
            api_url = f"http://127.0.0.1:{server.server_port}"
            (tmp_path / "connection.json").write_text(json.dumps({"api_url": api_url, "token": "u8-fixture-token"}))
            display = "u8-wl"
            comp = U8WaylandCompositor(rt_dir, display, width=width, height=height)
            env = dict(
                os.environ,
                XDG_RUNTIME_DIR=str(rt_dir),
                WAYLAND_DISPLAY=display,
                ORB_STATE_DIR=str(tmp_path),
                ORB_LEANUI_GPU="0",
            )
            args = [
                str(self.bin),
                "--width", str(width),
                "--height", str(height),
                "--dark" if is_dark else "--light",
            ]
            proc = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                comp.wait_ready(timeout=15.0)
                h_boot = comp.last_frame_hash
                u6._wait_until("initial roster /api/auth/me", lambda: count_req("GET", "/api/auth/me") >= 1)
                comp.wait_frame_change(h_boot, timeout=5.0)
                # Collect live 60fps active-spinner frames over ~450ms
                comp.frame_history.clear()
                time.sleep(0.45)
                normal_frames = list(comp.frame_history)
                normal_frame = comp.last_frame_bytes
                w, h = comp.last_frame_w, comp.last_frame_h

                # Open Search modal (Ctrl+K) with backdrop blur + scrim and verify corners remain transparent
                h_before_modal = comp.last_frame_hash
                comp.key_tap("k", u6.MOD_CTRL)
                comp.wait_text_input(True, timeout=5.0)
                comp.wait_frame_change(h_before_modal, timeout=5.0)
                time.sleep(0.1)
                modal_frame = comp.last_frame_bytes
                comp.key_tap("esc", 0)
                time.sleep(0.1)

                comp.send_close()
                rc = proc.wait(timeout=10)
                stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
                self.assertEqual(rc, 0, f"orb-desktop-native exited {rc}: {stderr}")
                return {
                    "app_ids": list(comp.app_ids),
                    "shm_formats": list(comp.shm_formats),
                    "width": w,
                    "height": h,
                    "frame": normal_frame,
                    "frames": normal_frames,
                    "modal_frame": modal_frame,
                    "commits": comp.commit_count,
                }
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        proc.wait(timeout=3)
                if proc.stdout:
                    proc.stdout.close()
                if proc.stderr:
                    proc.stderr.close()
                comp.close()
                server.shutdown()

    @unittest.skipUnless(HAS_IMAGE_DEPS, "requires numpy and Pillow")
    def test_01_live_wayland_dark_light_transparency_corners_badges_and_side_by_side(self) -> None:
        for is_dark in (True, False):
            tag = "dark" if is_dark else "light"
            exp_sb_alpha = 199 if is_dark else 184
            res = self._run_session(is_dark=is_dark, width=960, height=640)
            w, h = res["width"], res["height"]
            self.assertEqual((w, h), (960, 640))
            self.assertEqual(res["app_ids"], ["orb-desktop"])
            self.assertTrue(res["shm_formats"] and all(f == 0 for f in res["shm_formats"]))

            rgba = bgra_premul_to_rgba_array(res["frame"], w, h)
            # 1. All 4 outer window corners must be strictly transparent (0,0,0,0)
            for cx, cy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
                self.assertEqual(tuple(int(v) for v in rgba[cy, cx]), (0, 0, 0, 0),
                                 f"{tag} corner ({cx},{cy}) must be transparent")
            # 2. Anti-aliased 12px corner transition exists
            diag_alphas = [int(rgba[k, k, 3]) for k in range(1, 12)]
            self.assertTrue(any(0 < a < exp_sb_alpha for a in diag_alphas),
                            f"{tag} expected AA corner alpha ramp, got {diag_alphas}")
            # 3. Frosted sidebar alpha (78% dark / 72% light) vs 100% solid main pane
            sb_a = int(rgba[540, 12, 3])
            hdr_a = int(rgba[12, 500, 3])
            main_a = int(rgba[320, 500, 3])
            self.assertEqual(sb_a, exp_sb_alpha, f"{tag} sidebar alpha mismatch")
            self.assertEqual(hdr_a, 255, f"{tag} header must be 100% solid")
            self.assertEqual(main_a, 255, f"{tag} main canvas must be 100% solid")

            # 4. Backdrop-blur search modal (Ctrl+K) preserves transparent 12px window corners!
            modal_rgba = bgra_premul_to_rgba_array(res["modal_frame"], w, h)
            for cx, cy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
                self.assertEqual(tuple(int(v) for v in modal_rgba[cy, cx]), (0, 0, 0, 0),
                                 f"{tag} modal corner ({cx},{cy}) leaked blur/scrim")
            modal_diff = float(np.abs(modal_rgba[80:520, 240:760].astype(int) - rgba[80:520, 240:760].astype(int)).mean())
            self.assertGreater(modal_diff, 5.0, f"{tag} Ctrl+K search modal did not render visibly (mean diff={modal_diff})")

            # 5. Active mission spinner animates across captured Wayland frames while paused row stays stationary!
            self.assertGreaterEqual(len(res["frames"]), 4, f"{tag} expected >=4 animated spinner frames, got {len(res['frames'])}")
            active_band_hashes = {
                hashlib.sha256(bgra_premul_to_rgba_array(f, w, h)[320:346, 14:36].tobytes()).hexdigest()
                for f in res["frames"]
            }
            paused_band_hashes = {
                hashlib.sha256(bgra_premul_to_rgba_array(f, w, h)[351:377, 14:36].tobytes()).hexdigest()
                for f in res["frames"]
            }
            self.assertGreaterEqual(len(active_band_hashes), 4,
                                    f"{tag} active spinner badge did not animate smoothly across frames: {len(active_band_hashes)}")
            self.assertEqual(len(paused_band_hashes), 1,
                             f"{tag} paused badge row should stay stationary, got {len(paused_band_hashes)} variants")
            # Verify the paused badge row visibly renders non-background icon pixels (vertical pause bars)
            paused_patch = rgba[356:372, 16:32, :3].astype(int)
            bg_rgb = rgba[356, 14, :3].astype(int)
            paused_ink = int((np.max(np.abs(paused_patch - bg_rgb), axis=2) > 25).sum())
            self.assertGreater(paused_ink, 10, f"{tag} paused badge ink missing ({paused_ink} px)")

            # 6. Side-by-side Hyprland vibrancy composite vs WebKit/hybrid Linux reference surface
            ref_rgba = build_webkit_reference_surface(w, h, is_dark)
            self.assertEqual(int(rgba[540, 12, 3]), int(ref_rgba[540, 12, 3]))
            self.assertEqual(int(rgba[320, 500, 3]), int(ref_rgba[320, 500, 3]))
            self.assertEqual(int(rgba[0, 0, 3]), int(ref_rgba[0, 0, 3]))
            lean_comp = hyprland_vibrancy_composite(rgba)
            ref_comp = hyprland_vibrancy_composite(ref_rgba)
            lean_np = np.asarray(lean_comp, dtype=np.int16)
            ref_np = np.asarray(ref_comp, dtype=np.int16)
            sb_patch_delta = int(np.max(np.abs(lean_np[555:605, 48:180] - ref_np[555:605, 48:180])))
            main_patch_delta = int(np.max(np.abs(lean_np[80:160, 400:700] - ref_np[80:160, 400:700])))
            self.assertLessEqual(sb_patch_delta, 1, f"{tag} vibrancy-blurred sidebar delta {sb_patch_delta} > 1")
            self.assertLessEqual(main_patch_delta, 1, f"{tag} solid main surface delta {main_patch_delta} > 1")

            if self.capture_dir:
                modal_comp = hyprland_vibrancy_composite(modal_rgba)
                sbs = Image.new("RGB", (lean_comp.width * 2 + 16, lean_comp.height), (24, 24, 28))
                sbs.paste(ref_comp, (0, 0))
                sbs.paste(lean_comp, (lean_comp.width + 16, 0))
                sbs.save(self.capture_dir / f"u8_side_by_side_{tag}.png")
                lean_comp.save(self.capture_dir / f"u8_leanui_{tag}.png")
                modal_comp.save(self.capture_dir / f"u8_leanui_modal_blur_{tag}.png")


if __name__ == "__main__":
    unittest.main()
