"""Adversarial metadata fixtures, not shared-kernel execution receipts."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_orb_kernel_wasm import verify_abi

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
            self.assertEqual(json.loads(receipt.read_text())["status"], "INCOMPLETE")

    def test_artifact_and_receipt_cannot_alias(self):
        with tempfile.TemporaryDirectory() as temp:
            artifact = Path(temp) / "kernel.wasm"
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("build_orb_kernel_wasm.py")),
                                     "--lean-bin-dir", temp, "--out", str(artifact),
                                     "--receipt", str(artifact)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(artifact.exists())


if __name__ == "__main__":
    unittest.main()
