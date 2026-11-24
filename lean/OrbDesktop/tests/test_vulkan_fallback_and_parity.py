#!/usr/bin/env python3
"""Automated tests for LeanUI Vulkan 1.3 swapchain, instanced GPU SDF/glyph renderer,
ABI struct verification, shader drift, graceful wl_shm fallback, and Lavapipe differential parity.
"""
import glob
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

try:
    import numpy as np
    from PIL import Image
    from scripts import leanui_parity as parity
    HAS_IMAGE_DEPS = True
except ModuleNotFoundError:
    np = Image = parity = None
    HAS_IMAGE_DEPS = False


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


def find_vulkan_include() -> Path | None:
    if Path("/usr/include/vulkan/vulkan.h").is_file():
        return Path("/usr/include")
    matches = sorted(glob.glob("/nix/store/*vulkan-headers*/include/vulkan/vulkan.h"))
    if matches:
        return Path(matches[-1]).parent.parent
    return None


def has_vulkan_icd() -> bool:
    for env_var in ("VK_ICD_FILENAMES", "VK_DRIVER_FILES"):
        val = os.environ.get(env_var, "")
        for entry in val.split(os.pathsep):
            if entry and Path(entry).is_file():
                return True
    for d in ("/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d", "/run/opengl-driver/share/vulkan/icd.d"):
        p = Path(d)
        if p.is_dir() and any(p.glob("*.json")):
            return True
    return False


def has_vulkan_validation_layers() -> bool:
    for d in (
        "/usr/share/vulkan/explicit_layer.d",
        "/etc/vulkan/explicit_layer.d",
        "/run/opengl-driver/share/vulkan/explicit_layer.d",
    ):
        p = Path(d)
        if p.is_dir() and any("validation" in f.name.lower() for f in p.glob("*.json")):
            return True
    return False


def find_host_cc() -> str:
    """Resolve a system C compiler with standard libc headers (avoiding Lean's bundled clang)."""
    env_cc = os.environ.get("HOST_CC")
    if env_cc:
        return env_cc
    for cand in ("/usr/bin/cc", "/usr/bin/gcc", "/usr/bin/clang"):
        if Path(cand).is_file():
            return cand
    return shutil.which("gcc") or shutil.which("cc") or shutil.which("clang") or "cc"


def assert_no_vk_validation_errors(tc: unittest.TestCase, stderr: str) -> None:
    bad = [
        ln for ln in stderr.splitlines()
        if "Validation Error:" in ln or "VUID-" in ln or "SYNC-HAZARD" in ln
    ]
    tc.assertEqual(bad, [], f"Vulkan validation layer errors detected:\n" + "\n".join(bad))


class LeanUIVulkanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bin = find_bin()

    def test_01_c_shims_under_220_loc(self):
        for cfile in sorted((ROOT / "lean/OrbDesktop/c").glob("*.c")):
            lines = len(cfile.read_text().splitlines())
            self.assertLessEqual(lines, 220, f"{cfile.name} has {lines} LOC > 220")

    def test_02_shader_spirv_drift_check(self):
        res = subprocess.run(
            [sys.executable, str(ROOT / "scripts/gen_leanui_shaders.py"), "--check"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_03_vk_struct_abi_check(self):
        inc = find_vulkan_include()
        if inc is None:
            self.skipTest("vulkan/vulkan.h not installed")
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "vk_abi_check"
            cc = find_host_cc()
            comp = subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 f"-I{inc}", str(ROOT / "lean/OrbDesktop/tests/VkStructAbiCheck.c"), "-o", str(exe)],
                capture_output=True, text=True,
            )
            self.assertEqual(comp.returncode, 0, comp.stdout + comp.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_04_headless_golden_determinism_and_gpu_isolation(self):
        """--headless-golden ignores ORB_LEANUI_GPU=1 and produces bit-identical PNGs."""
        with tempfile.TemporaryDirectory() as tmp:
            p1 = Path(tmp) / "g1.png"
            p2 = Path(tmp) / "g2.png"
            env1 = dict(os.environ, ORB_LEANUI_GPU="0", WAYLAND_DISPLAY="missing-compositor")
            env2 = dict(os.environ, ORB_LEANUI_GPU="1", WAYLAND_DISPLAY="missing-compositor")
            r1 = subprocess.run(
                [str(self.bin), "--headless-golden", str(p1), "--screen", "mission_transcript",
                 "--width", "640", "--height", "400"],
                env=env1, capture_output=True, text=True, timeout=60,
            )
            r2 = subprocess.run(
                [str(self.bin), "--headless-golden", str(p2), "--screen", "mission_transcript",
                 "--width", "640", "--height", "400", "--gpu"],
                env=env2, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(r1.returncode, 0, r1.stdout + r1.stderr)
            self.assertEqual(r2.returncode, 0, r2.stdout + r2.stderr)
            self.assertEqual(p1.read_bytes(), p2.read_bytes(), "headless-golden must be bit-identical regardless of GPU flags")

    @unittest.skipUnless(HAS_IMAGE_DEPS, "requires numpy and Pillow")
    def test_05_gpu_readback_all_primitives_phase1_and_phase2_parity(self):
        """Differential parity across ALL 8 primitive kinds (0..7) on translucent clearColor=0."""
        if not has_vulkan_icd():
            self.skipTest("no Vulkan ICD installed")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cpu_dir = root / "cpu"
            p1_dir = root / "p1"
            p2_dir = root / "p2"
            p2_rep = root / "p2_rep"
            for d in (cpu_dir, p1_dir, p2_dir, p2_rep):
                d.mkdir()
            fname = "all_prims.png"
            r_cpu = subprocess.run(
                [str(self.bin), "--headless-golden-all-prims", str(cpu_dir / fname)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(r_cpu.returncode, 0, r_cpu.stdout + r_cpu.stderr)

            vk_env = dict(os.environ)
            if has_vulkan_validation_layers():
                vk_env["ORB_LEANUI_VK_VALIDATION"] = "1"

            r_p1 = subprocess.run(
                [str(self.bin), "--gpu=present", "--gpu-readback-all-prims", str(p1_dir / fname)],
                env=vk_env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(r_p1.returncode, 0, r_p1.stdout + r_p1.stderr)
            assert_no_vk_validation_errors(self, r_p1.stderr)

            r_p2 = subprocess.run(
                [str(self.bin), "--gpu=instanced", "--gpu-readback-all-prims", str(p2_dir / fname)],
                env=vk_env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(r_p2.returncode, 0, r_p2.stdout + r_p2.stderr)
            assert_no_vk_validation_errors(self, r_p2.stderr)

            r_p2b = subprocess.run(
                [str(self.bin), "--gpu=instanced", "--gpu-readback-all-prims", str(p2_rep / fname)],
                env=vk_env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(r_p2b.returncode, 0, r_p2b.stdout + r_p2b.stderr)
            assert_no_vk_validation_errors(self, r_p2b.stderr)

            # Phase 1 (vkPresent): bit-exact 0 LSB across all 4 RGBA channels
            res_p1 = parity.compare(cpu_dir, p1_dir, tolerance=0, rgba=True, max_delta=0, max_above_tol=0.0, min_ssim=1.0)
            self.assertEqual(res_p1["errors"], [], f"Phase 1 RGBA parity failed: {res_p1}")

            # Phase 2 (vkInstanced): max Δ <= 3, above_tol(2) <= 0.05%, SSIM >= 0.9995, repeat pixel-identical
            res_p2 = parity.compare(
                cpu_dir, p2_dir, tolerance=2, rgba=True,
                native_repeat=p2_rep, max_delta=3, max_above_tol=0.05, min_ssim=0.9995,
            )
            self.assertEqual(res_p2["errors"], [], f"Phase 2 all-prims RGBA parity failed: {res_p2}")

    @unittest.skipUnless(HAS_IMAGE_DEPS, "requires numpy and Pillow")
    def test_06_gpu_readback_canonical_screens_parity(self):
        """Differential parity across all 36 canonical desktop screens (9 screens x dark/light x 1x/2x) on Lavapipe."""
        if not has_vulkan_icd():
            self.skipTest("no Vulkan ICD installed")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cpu_dir = root / "cpu"
            gpu_dir = root / "gpu"
            cpu_dir.mkdir()
            gpu_dir.mkdir()
            vk_env = dict(os.environ)
            if has_vulkan_validation_layers():
                vk_env["ORB_LEANUI_VK_VALIDATION"] = "1"
            rc = subprocess.run(
                [str(self.bin), "--headless-golden-all", str(cpu_dir),
                 "--width", "640", "--height", "400"],
                capture_output=True, text=True, timeout=180,
            )
            self.assertEqual(rc.returncode, 0, rc.stdout + rc.stderr)
            rg = subprocess.run(
                [str(self.bin), "--gpu=instanced", "--gpu-readback", str(gpu_dir),
                 "--width", "640", "--height", "400"],
                env=vk_env, capture_output=True, text=True, timeout=240,
            )
            self.assertEqual(rg.returncode, 0, rg.stdout + rg.stderr)
            assert_no_vk_validation_errors(self, rg.stderr)
            res = parity.compare(
                cpu_dir, gpu_dir, tolerance=2, require=36, rgba=True,
                max_delta=3, max_above_tol=0.05, min_ssim=0.9995,
            )
            self.assertEqual(res["errors"], [], f"All-36 canonical screen GPU readback parity failed: {res}")

    def test_07_weston_wsi_fallback_and_bench_wsi(self):
        """Under headless Weston --renderer=pixman, default auto-GPU cleanly falls back to wl_shm
        and completes --bench-wsi with 0 errors and 0 quiescent redraws."""
        weston = shutil.which("weston")
        if not weston:
            self.skipTest("weston not installed")
        with tempfile.TemporaryDirectory() as tmp:
            rt_dir = Path(tmp) / "runtime"
            rt_dir.mkdir(mode=0o700)
            sock_name = "leanui-vk-test"
            env = dict(os.environ, XDG_RUNTIME_DIR=str(rt_dir))
            comp = subprocess.Popen(
                [weston, "--backend=headless", "--renderer=pixman",
                 "--shell=kiosk-shell.so", f"--socket={sock_name}",
                 "--idle-time=0", "--no-config", f"--log={tmp}/weston.log"],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                sock_path = rt_dir / sock_name
                for _ in range(100):
                    if sock_path.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(sock_path.exists(), "weston failed to create socket")
                run_env = dict(env, WAYLAND_DISPLAY=sock_name)
                # Auto mode on Lavapipe / pixman must fall back cleanly to cpuShm
                res = subprocess.run(
                    [str(self.bin), "--bench-wsi", "5", "--width", "640", "--height", "400"],
                    env=run_env, capture_output=True, text=True, timeout=60,
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                json_lines = [ln.strip() for ln in res.stdout.splitlines() if ln.strip().startswith("{")]
                self.assertTrue(json_lines, f"missing JSON output: {res.stdout}")
                report = json.loads(json_lines[-1])
                self.assertEqual(report["error_count"], 0, report)
                self.assertEqual(report["quiescent_redraws"], 0, report)
                self.assertEqual(report["backend"], "cpuShm", report)
                self.assertTrue(report["fallback_reason"], f"expected non-empty fallback_reason: {report}")

                # Explicit --no-gpu mode must also succeed cleanly
                res_nogpu = subprocess.run(
                    [str(self.bin), "--no-gpu", "--bench-wsi", "3", "--width", "640", "--height", "400"],
                    env=run_env, capture_output=True, text=True, timeout=60,
                )
                self.assertEqual(res_nogpu.returncode, 0, res_nogpu.stdout + res_nogpu.stderr)
                rep2 = json.loads([ln.strip() for ln in res_nogpu.stdout.splitlines() if ln.strip().startswith("{")][-1])
                self.assertEqual(rep2["backend"], "cpuShm", rep2)
                self.assertEqual(rep2["error_count"], 0, rep2)
            finally:
                comp.terminate()
                try:
                    comp.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    comp.kill()

    def test_08_bench_and_verify_repaint_non_regression(self):
        """Headless --verify-repaint --bench 10 passes all repaint & damage invariants."""
        res = subprocess.run(
            [str(self.bin), "--verify-repaint", "--bench", "10", "--width", "1470", "--height", "923"],
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        json_lines = [ln.strip() for ln in res.stdout.splitlines() if ln.strip().startswith("{")]
        self.assertTrue(json_lines, res.stdout)
        rep = json.loads(json_lines[-1])
        self.assertEqual(rep["error_count"], 0, rep)
        self.assertEqual(rep["partial_frames"], 10, rep)
        self.assertEqual(rep["quiescent_skips"], 10, rep)


if __name__ == "__main__":
    unittest.main()
