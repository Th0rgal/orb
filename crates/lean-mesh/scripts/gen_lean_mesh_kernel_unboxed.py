#!/usr/bin/env python3
"""Generate cabi/lean_mesh_kernel.h and cabi/lean_mesh_kernel_unboxed.c from lean/LeanMesh/Kernel.lean."""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "cabi/kernel_abi.json"
OUT_H = ROOT / "cabi/lean_mesh_kernel.h"
OUT_C = ROOT / "cabi/lean_mesh_kernel_unboxed.c"

BIN = {
    "dec_eq": "((uint8_t)(((T)(a)) == ((T)(b))))",
    "dec_lt": "((uint8_t)(((T)(a)) < ((T)(b))))",
    "dec_le": "((uint8_t)(((T)(a)) <= ((T)(b))))",
    "add": "((T)(((T)(a)) + ((T)(b))))",
    "sub": "((T)(((T)(a)) - ((T)(b))))",
    "mul": "((T)(((T)(a)) * ((T)(b))))",
    "div": "((((T)(b)) == 0) ? (T)(0) : (T)(((T)(a)) / ((T)(b))))",
    "mod": "((((T)(b)) == 0) ? (T)(a) : (T)(((T)(a)) % ((T)(b))))",
    "lor": "((T)(((T)(a)) | ((T)(b))))",
    "land": "((T)(((T)(a)) & ((T)(b))))",
    "xor": "((T)(((T)(a)) ^ ((T)(b))))",
    "shift_left_32": "((uint32_t)(((uint32_t)(a)) << (((uint32_t)(b)) & 31u)))",
    "shift_right_32": "((uint32_t)(((uint32_t)(a)) >> (((uint32_t)(b)) & 31u)))",
    "shift_left_64": "((uint64_t)(((uint64_t)(a)) << (((uint64_t)(b)) & 63u)))",
    "shift_right_64": "((uint64_t)(((uint64_t)(a)) >> (((uint64_t)(b)) & 63u)))",
}

MACROS = [
    ("uint8", ["dec_eq", "dec_lt", "dec_le", "to_uint32", "to_uint64"]),
    ("uint32", ["dec_eq", "dec_lt", "dec_le", "add", "sub", "mul", "lor", "land", "shift_left", "shift_right", "to_uint64"]),
    ("uint64", ["dec_eq", "dec_lt", "dec_le", "add", "sub", "mul", "div", "mod", "lor", "land", "xor", "shift_left", "shift_right"]),
]
SUPPORTED = {(w, o) for w, ops in MACROS for o in ops}


def macro(width, op):
    if op.startswith("to_"):
        return f"#define lean_{width}_{op}(a) (({op[3:]}_t)(a))"
    if op in ("shift_left", "shift_right"):
        bits = "32" if width == "uint32" else "64"
        return f"#define lean_{width}_{op}(a, b) " + BIN[f"{op}_{bits}"]
    return f"#define lean_{width}_{op}(a, b) " + BIN[op].replace("T", f"{width}_t")


def render_header(manifest):
    lines = [
        "#ifndef LEAN_MESH_KERNEL_H",
        "#define LEAN_MESH_KERNEL_H",
        "#include <stdint.h>",
        "#ifdef __cplusplus",
        'extern "C" {',
        "#endif",
    ]
    for fn in manifest["functions"]:
        params = ", ".join(f"{p['type']} {p['name']}" for p in fn["params"])
        lines.append(f"{fn['ret']} {fn['name']}({params});")
    lines += [
        "#ifdef __cplusplus",
        "}",
        "#endif",
        "#endif",
        "",
    ]
    return "\n".join(lines)


def compile_kernel_c(tmp_dir):
    setup_file = tmp_dir / "LeanMesh_Kernel.setup.json"
    setup_file.write_text(json.dumps({
        "name": "LeanMesh.Kernel",
        "isModule": False,
        "importArts": {},
        "dynlibs": [],
        "plugins": [],
        "options": {"autoImplicit": False, "warningAsError": True},
        "package": "lean-mesh",
    }))
    c_path = tmp_dir / "LeanMesh_Kernel.c"
    subprocess.run([
        "lean", "-DwarningAsError=true", "-DautoImplicit=false",
        f"--setup={setup_file}", str(ROOT / "lean/LeanMesh/Kernel.lean"), "-c", str(c_path),
    ], check=True)
    return c_path.read_text()


def extract_scalar_functions(src):
    lines = src.splitlines()
    funcs, i = [], 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("LEAN_EXPORT ") and line.endswith("{"):
            j, depth = i, 0
            while True:
                depth += lines[j].count("{") - lines[j].count("}")
                if depth == 0:
                    break
                j += 1
            name = line.split("(")[0].split()[-1]
            text = "\n".join(lines[i:j + 1])
            if "lean_object" not in text and not name.startswith("initialize_"):
                if "goto _start;" not in text:
                    text = text.replace("\n_start:\n", "\n")
                funcs.append((name, text))
            i = j + 1
        else:
            i += 1
    return funcs


def render_unboxed_c(manifest, raw_c):
    funcs = extract_scalar_functions(raw_c)
    texts = dict(funcs)
    manifest_names = {f["name"] for f in manifest["functions"]}
    keep = set(manifest_names)
    missing = sorted(keep - texts.keys())
    if missing:
        sys.exit(f"FATAL: kernel_abi.json symbols not produced by Lean: {missing}")
    todo = list(keep)
    while todo:
        for callee in re.findall(r"\b(l_\w+|lp_\w+)\(", texts[todo.pop()]):
            if callee in texts and callee not in keep:
                keep.add(callee)
                todo.append(callee)
    funcs = [
        (
            name,
            text if name in manifest_names else text.replace("LEAN_EXPORT ", "static inline ", 1),
        )
        for name, text in funcs
        if name in keep
    ]
    body = "\n\n".join(text for _, text in funcs)
    defined = {name for name, _ in funcs}
    called = set(re.findall(r"\b(l_\w+|lp_\w+)\(", body))
    if called - defined:
        sys.exit(f"FATAL: kernel calls non-scalar Lean definitions: {sorted(called - defined)}")
    used = set(re.findall(r"\blean_(uint8|uint32|uint64)_(\w+)\(", body))
    unknown = sorted(f"lean_{w}_{o}" for w, o in used if (w, o) not in SUPPORTED)
    if unknown:
        sys.exit(f"FATAL: unsupported Lean primitives in kernel: {unknown}")
    stray = sorted(set(re.findall(r"\blean_\w+", body)) - {f"lean_{w}_{o}" for w, o in used})
    if stray:
        sys.exit(f"FATAL: unsupported Lean runtime references in kernel: {stray}")
    head = ['#include "lean_mesh_kernel.h"', "#define LEAN_EXPORT"]
    for w, ops in MACROS:
        head += [macro(w, o) for o in ops]
    return "\n".join(head) + "\n\n" + body + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text())
    header_text = render_header(manifest)
    with tempfile.TemporaryDirectory() as td:
        raw_c = compile_kernel_c(pathlib.Path(td))
    c_text = render_unboxed_c(manifest, raw_c)

    if args.check:
        if not OUT_H.is_file() or OUT_H.read_text() != header_text:
            sys.exit("FATAL: cabi/lean_mesh_kernel.h is stale")
        if not OUT_C.is_file() or OUT_C.read_text() != c_text:
            sys.exit("FATAL: cabi/lean_mesh_kernel_unboxed.c is stale")
        print("[CABI CHECK PASS] cabi/lean_mesh_kernel.h and cabi/lean_mesh_kernel_unboxed.c are in sync.")
        return

    OUT_H.write_text(header_text)
    OUT_C.write_text(c_text)
    print(f"[CABI GENERATED] {OUT_H.relative_to(ROOT)} and {OUT_C.relative_to(ROOT)} ({len(manifest['functions'])} exports).")


if __name__ == "__main__":
    main()
