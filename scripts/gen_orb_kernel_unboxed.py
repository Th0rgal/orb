#!/usr/bin/env python3
"""Regenerate shared/orb-spec/cabi/orb_kernel_unboxed.c from lean/Orb/Kernel.lean.

The vendored C (Android JNI, iOS, desktop) is the Lean compiler output for
Orb.Kernel with the boxed wrappers, forward declarations and module
initializer removed, and the lean.h scalar primitives replaced by plain C
macros so it compiles without the Lean runtime.

The file holds two kernels: Orb.Kernel (lean/, this repo) followed by
LeanSys.Spec (the `leansys_*` gates from the lean-sys crate at the revision
pinned in crates/orb-spec/Cargo.toml, compiled with its own lean-toolchain).

Usage:
  scripts/gen_orb_kernel_unboxed.py [--check] [--lean-c PATH] [--leansys-c PATH]

Without --lean-c the script runs `lake build Orb.Kernel` in lean/ and reads
lean/.lake/build/ir/Orb/Kernel.c (lake names private helpers with the
package prefix). Without --leansys-c it locates the lean-sys checkout via
`cargo metadata` and compiles LeanSys/Spec.lean the same way lean-sys's
build.rs does.
"""
import argparse
import pathlib
import re
import json
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "shared/orb-spec/cabi/orb_kernel_unboxed.c"

# Only scalar primitives with obvious C semantics are allowed; anything else
# means the kernel started depending on the Lean runtime and must fail.
BIN = {
    "dec_eq": "((uint8_t)((a) == (b)))",
    "dec_lt": "((uint8_t)((a) < (b)))",
    "dec_le": "((uint8_t)((a) <= (b)))",
    "add": "((T)((a) + (b)))",
    "sub": "((T)((a) - (b)))",
    "mul": "((T)((a) * (b)))",
    "div": "((T)((a) / (b)))",
    "mod": "((T)((a) % (b)))",
    "lor": "((T)((a) | (b)))",
    "land": "((T)((a) & (b)))",
    "xor": "((T)((a) ^ (b)))",
    "shift_left": "((T)((a) << (b)))",
    "shift_right": "((T)((a) >> (b)))",
}
# Emitted unconditionally (unused macros are harmless), in this order.
MACROS = [
    ("uint8", ["dec_eq", "dec_lt", "dec_le", "to_uint32", "to_uint64"]),
    ("uint32", ["dec_eq", "dec_lt", "dec_le", "add", "sub", "mul", "lor", "shift_left", "to_uint64"]),
    ("uint64", ["dec_eq", "dec_lt", "dec_le", "add", "sub", "mul", "div", "mod", "lor", "xor",
                "shift_left", "shift_right"]),
]
SUPPORTED = {(w, o) for w, ops in MACROS for o in ops}


def macro(width, op):
    if op.startswith("to_"):
        return f"#define lean_{width}_{op}(a) (({op[3:]}_t)(a))"
    return f"#define lean_{width}_{op}(a, b) " + BIN[op].replace("T", f"{width}_t")


def leansys_c(out_dir):
    meta = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1",
         "--manifest-path", str(ROOT / "crates/orb-spec/Cargo.toml")],
        cwd=ROOT, check=True, capture_output=True, text=True).stdout)
    root = next(pathlib.Path(p["manifest_path"]).parent
                for p in meta["packages"] if p["name"] == "lean-sys-cabi")
    env = {**__import__("os").environ, "LEAN_PATH": str(out_dir)}
    for mod in ["LeanSys/Contracts/MetaGate", "LeanSys/Contracts/SpeculativeGate", "LeanSys/Gate"]:
        olean = out_dir / f"{mod}.olean"
        olean.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["lean", f"{mod}.lean", "-o", str(olean)], cwd=root, env=env, check=True)
    c = out_dir / "LeanSys_Spec.c"
    subprocess.run(["lean", "LeanSys/Spec.lean", "-o", str(out_dir / "LeanSys/Spec.olean"),
                    "-c", str(c)], cwd=root, env=env, check=True)
    return c


def extract(src):
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
            # Scalar-only definitions; boxed wrappers, the module initializer
            # and object-valued (proof/IO) definitions stay in the Lean world.
            if "lean_object" not in text and not name.startswith("initialize_"):
                funcs.append((name, text))
            i = j + 1
        else:
            i += 1
    return funcs


def transform(*sources):
    funcs = [f for src in sources for f in extract(src)]
    # Keep every symbol kernel_abi.json declares plus the helpers they reach.
    texts = dict(funcs)
    manifest = json.loads((ROOT / "shared/orb-spec/kernel_abi.json").read_text())
    keep = {f["name"] for f in manifest["functions"]}
    missing = sorted(keep - texts.keys())
    if missing:
        sys.exit(f"kernel_abi.json symbols not produced by Lean: {missing}")
    todo = list(keep)
    while todo:
        for callee in re.findall(r"\b(l_\w+|lp_\w+)\(", texts[todo.pop()]):
            if callee in texts and callee not in keep:
                keep.add(callee)
                todo.append(callee)
    funcs = [f for f in funcs if f[0] in keep]
    body = "\n\n".join(text for _, text in funcs)
    defined = {name for name, _ in funcs}
    called = set(re.findall(r"\b(l_\w+|lp_\w+)\(", body))
    if called - defined:
        sys.exit(f"kernel calls non-scalar Lean definitions: {sorted(called - defined)}")
    used = set(re.findall(r"\blean_(uint8|uint32|uint64)_(\w+)\(", body))
    unknown = sorted(f"lean_{w}_{o}" for w, o in used if (w, o) not in SUPPORTED)
    if unknown:
        sys.exit(f"unsupported Lean primitives in kernel: {unknown}")
    stray = sorted(set(re.findall(r"\blean_\w+", body)) - {f"lean_{w}_{o}" for w, o in used})
    if stray:
        sys.exit(f"unsupported Lean runtime references in kernel: {stray}")
    head = ['#include "orb_kernel.h"', "#define LEAN_EXPORT"]
    for w, ops in MACROS:
        head += [macro(w, o) for o in ops]
    return "\n".join(head) + "\n" + body + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the committed file is stale")
    ap.add_argument("--lean-c", type=pathlib.Path)
    ap.add_argument("--leansys-c", type=pathlib.Path)
    args = ap.parse_args()
    lean_c = args.lean_c
    if lean_c is None:
        subprocess.run(["lake", "build", "Orb.Kernel"], cwd=ROOT / "lean", check=True)
        lean_c = ROOT / "lean/.lake/build/ir/Orb/Kernel.c"
    with tempfile.TemporaryDirectory() as tmp:
        ls_c = args.leansys_c or leansys_c(pathlib.Path(tmp))
        new = transform(lean_c.read_text(), ls_c.read_text())
    if args.check:
        if OUT.read_text() != new:
            sys.exit(f"{OUT.relative_to(ROOT)} is stale; run scripts/gen_orb_kernel_unboxed.py")
        print(f"{OUT.relative_to(ROOT)} up to date")
    else:
        OUT.write_text(new)
        print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
