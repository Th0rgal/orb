#!/usr/bin/env python3
"""Build scalar shared-kernel WASM; reject imports and ABI drift before publication.

This validates artifact metadata, not compiler correctness or device behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil

from gen_kernel_bindings import load_manifest

ROOT = Path(__file__).resolve().parents[1]


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, size):
        end = self.pos + size
        if end > len(self.data):
            raise ValueError("truncated WASM metadata")
        value, self.pos = self.data[self.pos:end], end
        return value

    def uint(self):
        value = 0
        for i in range(5):
            byte = self.take(1)[0]
            value |= (byte & 127) << (7 * i)
            if not byte & 128:
                if value >= 2**32:
                    break
                return value
        raise ValueError("invalid WASM u32 LEB")

    def vector(self, read):
        return [read() for _ in range(self.uint())]

    def name(self):
        return self.take(self.uint()).decode("utf-8")

    def done(self):
        if self.pos != len(self.data):
            raise ValueError("trailing WASM metadata")


def verify_abi(data, manifest):
    """Parse only ABI sections; a real WebAssembly engine validates the full module."""
    reader = Reader(data)
    if reader.take(8) != b"\0asm\x01\0\0\0":
        raise ValueError("expected WASM version 1")
    sections = {}
    while reader.pos < len(data):
        kind = reader.take(1)[0]
        payload = reader.take(reader.uint())
        if kind:
            if kind in sections:
                raise ValueError("duplicate WASM section")
            sections[kind] = payload
    if 2 in sections:
        imports = Reader(sections[2])
        if imports.uint() != 0:
            raise ValueError("shared scalar kernel must have no imports")
        imports.done()
    types_reader = Reader(sections.get(1, b"\0"))

    def function_type():
        if types_reader.take(1) != b"\x60":
            raise ValueError("unsupported WASM function type")
        return (types_reader.vector(lambda: types_reader.take(1)[0]),
                types_reader.vector(lambda: types_reader.take(1)[0]))

    types = types_reader.vector(function_type)
    types_reader.done()
    functions_reader = Reader(sections.get(3, b"\0"))
    functions = functions_reader.vector(functions_reader.uint)
    functions_reader.done()
    exports_reader = Reader(sections.get(7, b"\0"))
    exports = exports_reader.vector(lambda: (exports_reader.name(), exports_reader.take(1)[0], exports_reader.uint()))
    exports_reader.done()
    names = set()
    signatures = {}
    for name, kind, index in exports:
        if name in names:
            raise ValueError("duplicate WASM export")
        names.add(name)
        if kind == 0:
            if index >= len(functions) or functions[index] >= len(types):
                raise ValueError("invalid WASM function/type index")
            signatures[name] = types[functions[index]]
        elif (name, kind, index) != ("memory", 2, 0):
            raise ValueError("unexpected non-function WASM export")
    wasm_type = {"uint8_t": 0x7f, "uint32_t": 0x7f, "uint64_t": 0x7e}
    expected = {f["name"]: ([wasm_type[p["type"]] for p in f["params"]], [wasm_type[f["ret"]]])
                for f in manifest["functions"]}
    if signatures != expected:
        missing = sorted(expected.keys() - signatures.keys())
        extra = sorted(signatures.keys() - expected.keys())
        wrong = sorted(k for k in signatures.keys() & expected.keys() if signatures[k] != expected[k])
        raise ValueError(f"WASM ABI mismatch: missing={missing}, extra={extra}, wrong_types={wrong}")
    return {"function_exports": len(signatures), "imports": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-bin-dir", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path, help="new raw receipt path")
    parser.add_argument("--check", action="store_true", help="compare the rebuilt bytes without publishing")
    args = parser.parse_args()
    tools = args.lean_bin_dir.resolve()
    source = ROOT / "shared/orb-spec/cabi/orb_kernel_unboxed.c"
    manifest_path = ROOT / "shared/orb-spec/kernel_abi.json"
    manifest = load_manifest(manifest_path)
    receipt = {"status": "INCOMPLETE", "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
               "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(), "commands": []}
    # Reserve the receipt before compiling; never overwrite a previous attempt.
    with args.receipt.open("x") as record:
        def run(argv):
            result = subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=120)
            receipt["commands"].append({"argv": result.args, "exit_code": result.returncode,
                                        "stdout": result.stdout, "stderr": result.stderr})
            if result.returncode:
                raise ValueError(f"command failed: {result.args[0]} (exit {result.returncode})")

        try:
            receipt["tools"] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
                                for path in (tools / "clang", tools / "ld.lld", Path(shutil.which("node") or "node"))}
            args.out.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="orb-wasm-", dir=args.out.parent) as temporary:
                obj, binary = Path(temporary) / "kernel.o", Path(temporary) / "kernel.wasm"
                run([tools / "clang", "--target=wasm32", "-mcpu=mvp", "-mno-simd128", "-mno-relaxed-simd",
                     "-O2", "-ffreestanding", "-isystem", tools.parent / "include/clang", "-c", source, "-o", obj])
                run([tools / "ld.lld", "-flavor", "wasm", "--no-entry", "--strip-all",
                     *["--export=" + f["name"] for f in manifest["functions"]], obj, "-o", binary])
                data = binary.read_bytes()
                receipt["abi"] = verify_abi(data, manifest)
                run(["node", "-e", "const fs=require('fs');const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));"
                     "if(WebAssembly.Module.imports(m).length)throw Error('imports');new WebAssembly.Instance(m);", binary])
                receipt["artifact_sha256"] = hashlib.sha256(data).hexdigest()
                if args.check:
                    if args.out.read_bytes() != data:
                        raise ValueError("checked-in WASM bytes differ from the rebuilt artifact")
                else:
                    os.replace(binary, args.out)
                receipt["status"] = "ARTIFACT_VALIDATED_LOCAL"
                receipt["limitations"] = ["Not a compiler correctness proof", "No native/mobile qualification",
                                           "P2 frontend adapters/bootstrap and phase acceptance remain open"]
        except Exception as error:
            receipt["error"] = str(error)
            raise
        finally:
            json.dump(receipt, record, indent=2)
            record.write("\n")
    print(json.dumps({k: receipt[k] for k in ("status", "abi", "artifact_sha256")}))


if __name__ == "__main__":
    main()
