#!/usr/bin/env python3
"""Unit and differential regression tests for scripts/gen_orb_kernel_leannative_ll.py."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import gen_orb_kernel_leannative_ll as gen_ll  # noqa: E402


class TestLeanNativeLl(unittest.TestCase):
    def test_committed_ll_check_passes(self) -> None:
        self.assertEqual(gen_ll.check_ir_files(), 0)

    def test_zero_heap_or_external_runtime_declarations_in_committed_ll(self) -> None:
        for ll_path in (gen_ll.OUT_X86_64, gen_ll.OUT_AARCH64):
            text = ll_path.read_text()
            self.assertNotIn("declare noalias ptr @malloc", text)
            self.assertNotIn("declare void @free", text)
            self.assertNotIn("declare void @llvm.memcpy", text)
            self.assertNotIn('"target-cpu"=', text)
            self.assertNotIn('"target-features"=', text)

    def test_negative_symbol_hygiene_rejects_undefined_and_extra_exports(self) -> None:
        clang = shutil.which("clang")
        self.assertIsNotNone(clang)
        expected = {fn["name"] for fn in gen_ll.load_manifest()}
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            bad_ll = tmp_dir / "bad_extra.ll"
            bad_ll.write_text(
                gen_ll.OUT_X86_64.read_text()
                + "\ndefine dso_local i64 @unexpected_rogue_export() {\n  ret i64 42\n}\n"
            )
            bad_obj = tmp_dir / "bad_extra.o"
            subprocess.run(
                [
                    clang,
                    "--target=x86_64-unknown-linux-gnu",
                    "-Wno-override-module",
                    "-O2",
                    "-fPIC",
                    "-c",
                    str(bad_ll),
                    "-o",
                    str(bad_obj),
                ],
                check=True,
            )
            with self.assertRaises(AssertionError):
                gen_ll.verify_object_symbols(bad_obj, expected, macos=False)

            undef_ll = tmp_dir / "bad_undef.ll"
            undef_ll.write_text(
                gen_ll.OUT_X86_64.read_text()
                + "\ndeclare i64 @rogue_external_import()\n"
                + "define dso_local i64 @rogue_caller() {\n"
                + "  %v = call i64 @rogue_external_import()\n"
                + "  ret i64 %v\n}\n"
            )
            undef_obj = tmp_dir / "bad_undef.o"
            subprocess.run(
                [
                    clang,
                    "--target=x86_64-unknown-linux-gnu",
                    "-Wno-override-module",
                    "-O0",
                    "-fPIC",
                    "-c",
                    str(undef_ll),
                    "-o",
                    str(undef_obj),
                ],
                check=True,
            )
            with self.assertRaises(AssertionError):
                gen_ll.verify_object_symbols(undef_obj, expected, macos=False)

    def test_stamp_matches_sources(self) -> None:
        stamp = json.loads(gen_ll.STAMP_JSON.read_text())
        self.assertEqual(stamp, gen_ll.compute_stamp_payload())


if __name__ == "__main__":
    unittest.main()
