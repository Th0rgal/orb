"""Adversarial metadata fixtures, not shared-kernel execution receipts."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_orb_kernel_wasm as builder
from build_orb_kernel_wasm import verify_abi, stage_artifact

MANIFEST = {"functions": [{"name": "fixture", "params": [{"type": "uint64_t"}], "ret": "uint64_t"}]}


def module(name="fixture", param=0x7e, result=0x7e, imports=False, duplicate=False):
    def section(kind, data):
        return bytes([kind, len(data)]) + data

    data = b"\0asm\1\0\0\0" + section(1, bytes([1, 0x60, 1, param, 1, result]))
    if imports:
        data += section(2, b"\1\3env\1f\0\0")
    data += section(3, b"\1\0")
    export = bytes([len(name)]) + name.encode() + bytes([0, int(imports)])
    data += section(7, bytes([2 if duplicate else 1]) + export * (2 if duplicate else 1))
    return data + section(10, b"\1\4\0\x20\0\x0b")


class WasmAbi(unittest.TestCase):
    def test_expected_metadata_and_wrong_signature(self):
        self.assertEqual(verify_abi(module(), MANIFEST), {"function_exports": 1, "imports": 0})
        for data in (module(param=0x7f), module(result=0x7f)):
            with self.assertRaisesRegex(ValueError, "wrong_types"):
                verify_abi(data, MANIFEST)

    def test_imported_missing_extra_and_duplicate_exports_reject(self):
        for data in (module(imports=True), module(name="other"), module(duplicate=True)):
            with self.assertRaises(ValueError):
                verify_abi(data, MANIFEST)
        with self.assertRaises(ValueError):
            verify_abi(module(), {"functions": []})

    def test_truncation_bad_magic_and_duplicate_sections_reject(self):
        for data in (b"textual IR", module()[:-2], module() + b"\3\1\0", module()[:8] + b"\1\x80"):
            with self.assertRaises(ValueError):
                verify_abi(data, MANIFEST)

    def test_missing_compiler_keeps_previous_output_and_failed_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            artifact, receipt = root / "previous.wasm", root / "receipt.json"
            artifact.write_bytes(b"previous artifact")
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("build_orb_kernel_wasm.py")),
                                     "--lean-bin-dir", str(root / "missing"), "--out", str(artifact),
                                     "--receipt", str(receipt)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(artifact.read_bytes(), b"previous artifact")
            self.assertEqual(json.loads(receipt.read_text())["status"], "FAILED")

    def test_artifact_and_receipt_cannot_alias(self):
        with tempfile.TemporaryDirectory() as temp:
            artifact = Path(temp) / "kernel.wasm"
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("build_orb_kernel_wasm.py")),
                                     "--lean-bin-dir", temp, "--out", str(artifact),
                                     "--receipt", str(artifact)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(artifact.exists())

    def test_full_engine_rejects_invalid_body_before_publication(self):
        # ABI metadata is valid; an i32 body cannot return the declared i64.
        malformed = module().replace(b"\x20\0\x0b", b"\x41\0\x0b")
        self.assertEqual(verify_abi(malformed, MANIFEST)["function_exports"], 1)
        with tempfile.TemporaryDirectory() as temp:
            binary, output = Path(temp) / "new.wasm", Path(temp) / "existing.wasm"
            binary.write_bytes(malformed)
            output.write_bytes(b"previous")
            def real_node(argv):
                subprocess.run(list(map(str, argv)), capture_output=True, check=True)
            with self.assertRaises(subprocess.CalledProcessError):
                stage_artifact(binary, output, MANIFEST, False, real_node)
            self.assertEqual(output.read_bytes(), b"previous")

    def test_check_mismatch_and_rename_failure_preserve_previous_output(self):
        with tempfile.TemporaryDirectory() as temp:
            binary, output = Path(temp) / "new.wasm", Path(temp) / "existing.wasm"
            binary.write_bytes(module())
            output.write_bytes(b"previous")
            def real_node(argv):
                subprocess.run(list(map(str, argv)), capture_output=True, check=True)
            with self.assertRaisesRegex(ValueError, "differ"):
                stage_artifact(binary, output, MANIFEST, True, real_node)
            with patch.object(builder.os, "replace", side_effect=OSError("injected rename failure")):
                with self.assertRaises(OSError):
                    stage_artifact(binary, output, MANIFEST, False, real_node)
            self.assertEqual(output.read_bytes(), b"previous")

    def test_bad_input_and_existing_receipt_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            receipt, output = root / "receipt.json", root / "old.wasm"
            output.write_bytes(b"previous")
            argv = ["builder", "--lean-bin-dir", temp, "--out", str(output), "--receipt", str(receipt)]
            with patch.object(builder, "load_manifest", side_effect=ValueError("injected malformed manifest")), patch.object(sys, "argv", argv):
                with self.assertRaisesRegex(ValueError, "malformed manifest"):
                    builder.main()
            self.assertEqual(json.loads(receipt.read_text())["status"], "FAILED")
            before = receipt.read_bytes()
            with patch.object(sys, "argv", argv):
                with self.assertRaises(FileExistsError):
                    builder.main()
            self.assertEqual(receipt.read_bytes(), before)
            self.assertEqual(output.read_bytes(), b"previous")

    def test_instantiation_trap_prevents_publication(self):
        def section(kind, data):
            return bytes([kind, len(data)]) + data
        data = b"\0asm\1\0\0\0"
        data += section(1, b"\2\x60\1\x7e\1\x7e\x60\0\0")
        data += section(3, b"\2\0\1")
        data += section(7, b"\1\7fixture\0\0")
        data += section(8, b"\1")
        data += section(10, b"\2\4\0\x20\0\x0b\3\0\0\x0b")
        self.assertEqual(verify_abi(data, MANIFEST)["function_exports"], 1)
        with tempfile.TemporaryDirectory() as temp:
            binary, output = Path(temp) / "trap.wasm", Path(temp) / "old.wasm"
            binary.write_bytes(data)
            output.write_bytes(b"previous")
            def real_node(argv):
                subprocess.run(list(map(str, argv)), capture_output=True, check=True)
            with self.assertRaises(subprocess.CalledProcessError):
                stage_artifact(binary, output, MANIFEST, False, real_node)
            self.assertEqual(output.read_bytes(), b"previous")


if __name__ == "__main__":
    unittest.main()
