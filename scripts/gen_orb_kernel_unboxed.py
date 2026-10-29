#!/usr/bin/env python3
"""Regenerate shared/orb-spec/cabi/orb_kernel_unboxed.c from lean/Orb/Kernel.lean.

The vendored C (Android JNI, iOS, desktop) is the Lean compiler output for
Orb.Kernel with the boxed wrappers, forward declarations and module
initializer removed, and the lean.h scalar primitives replaced by plain C
macros so it compiles without the Lean runtime.

The file holds two kernels: Orb.Kernel (lean/, this repo) followed by
LeanSys.Spec (the `leansys_*` gates from the lean-sys repository at the pinned
revision `LEANSYS_REV`, compiled with Lean 4.35.0).

Usage:
  scripts/gen_orb_kernel_unboxed.py [--check] [--lean-c PATH] [--leansys-c PATH]

Without --lean-c the script runs `turbo-lean build --project-dir lean` when
`turbo-lean` is available on PATH (or `TURBO_LEAN_BIN`), falling back to direct
`lean --setup` compilation of `lean/Orb/Kernel.lean` without invoking `lake`.
Without --leansys-c it locates `lean-sys` via `LEAN_SYS_DIR`, `../lean-sys`,
cargo's git cache, or a shallow fetch of `Th0rgal/lean-sys` at `LEANSYS_REV`.
"""
import argparse
import os
import pathlib
import re
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "shared/orb-spec/cabi/orb_kernel_unboxed.c"
LEANSYS_REPO = "https://github.com/Th0rgal/lean-sys.git"
LEANSYS_REV = "077775ba387f1eeb2976cb8763b4633b8d5ce313"

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
    ("uint32", ["dec_eq", "dec_lt", "dec_le", "add", "sub", "mul", "lor", "land", "xor", "shift_left", "shift_right", "to_uint64"]),
    ("uint64", ["dec_eq", "dec_lt", "dec_le", "add", "sub", "mul", "div", "mod", "lor", "land", "xor",
                "shift_left", "shift_right", "to_uint32"]),
]
SUPPORTED = {(w, o) for w, ops in MACROS for o in ops}


def macro(width, op):
    if op.startswith("to_"):
        return f"#define lean_{width}_{op}(a) (({op[3:]}_t)(a))"
    return f"#define lean_{width}_{op}(a, b) " + BIN[op].replace("T", f"{width}_t")


def orb_c(out_dir):
    turbo_bin = os.environ.get("TURBO_LEAN_BIN") or shutil.which("turbo-lean")
    if turbo_bin and pathlib.Path(turbo_bin).is_file():
        subprocess.run([turbo_bin, "build", "--project-dir", str(ROOT / "lean"), "Orb.Kernel"],
                       cwd=ROOT, check=True)
        ir_c = ROOT / "lean/.lake/build/ir/Orb/Kernel.c"
        if ir_c.is_file():
            return ir_c
    setup_file = out_dir / "Orb_Kernel.setup.json"
    setup_file.write_text(json.dumps({
        "name": "Orb.Kernel",
        "isModule": False,
        "importArts": {},
        "dynlibs": [],
        "plugins": [],
        "options": {"autoImplicit": False, "warningAsError": True},
        "package": "orb-spec",
    }))
    c = out_dir / "Orb_Kernel.c"
    subprocess.run([
        "lean", "-DwarningAsError=true", "-DautoImplicit=false",
        f"--setup={setup_file}", str(ROOT / "lean/Orb/Kernel.lean"), "-c", str(c),
    ], cwd=ROOT / "lean", check=True)
    return c


def resolve_leansys_root(out_dir):
    env_dir = os.environ.get("LEAN_SYS_DIR")
    if env_dir and (pathlib.Path(env_dir) / "LeanSys/Spec.lean").is_file():
        return pathlib.Path(env_dir)
    sibling = ROOT.parent / "lean-sys"
    if (sibling / "LeanSys/Spec.lean").is_file():
        return sibling
    cargo_home = pathlib.Path(os.environ.get("CARGO_HOME", pathlib.Path.home() / ".cargo"))
    checkouts = cargo_home / "git/checkouts"
    if checkouts.is_dir():
        for cand in checkouts.glob(f"lean-sys-*/{LEANSYS_REV[:7]}*"):
            if (cand / "LeanSys/Spec.lean").is_file():
                return cand
    clone_dir = out_dir / "lean-sys"
    subprocess.run(["git", "init", "-q", str(clone_dir)], check=True)
    subprocess.run(["git", "-C", str(clone_dir), "fetch", "-q", "--depth", "1",
                    LEANSYS_REPO, LEANSYS_REV], check=True)
    subprocess.run(["git", "-C", str(clone_dir), "checkout", "-q", "FETCH_HEAD"], check=True)
    return clone_dir


def parse_lean_exports(lean_text, module_prefix):
    export_map = {}
    lines = lean_text.splitlines()
    for i, ln in enumerate(lines):
        m = re.search(r"@\[(?:inline,\s*)?export\s+(\w+)\]", ln)
        if m:
            sym = m.group(1)
            for j in range(i + 1, min(i + 6, len(lines))):
                dm = re.match(r"\s*def\s+(\w+)", lines[j])
                if dm:
                    export_map[sym] = f"{module_prefix}.{dm.group(1)}"
                    break
    return export_map


def leansys_c_and_models(out_dir):
    root = resolve_leansys_root(out_dir)
    env = {**os.environ, "LEAN_PATH": str(out_dir)}
    for mod in ["LeanSys/Contracts/MetaGate", "LeanSys/Contracts/SpeculativeGate", "LeanSys/Gate"]:
        olean = out_dir / f"{mod}.olean"
        olean.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["lean", "-DwarningAsError=true", f"{mod}.lean", "-o", str(olean)],
                       cwd=root, env=env, check=True)
    spec_path = root / "LeanSys/Spec.lean"
    models = parse_lean_exports(spec_path.read_text(encoding="utf-8"), "LeanSys.Spec")
    c = out_dir / "LeanSys_Spec.c"
    subprocess.run(["lean", "-DwarningAsError=true", "LeanSys/Spec.lean",
                    "-o", str(out_dir / "LeanSys/Spec.olean"), "-c", str(c)],
                   cwd=root, env=env, check=True)
    return c, models


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
            text = "\n".join(l.rstrip() for l in lines[i:j + 1])
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
    manifest_names = {f["name"] for f in manifest["functions"]}
    keep = set(manifest_names)
    missing = sorted(keep - texts.keys())
    if missing:
        sys.exit(f"kernel_abi.json symbols not produced by Lean: {missing}")
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
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        lean_c = args.lean_c or orb_c(tmp_path)
        if args.leansys_c:
            ls_c = args.leansys_c
            ls_models = None
        else:
            ls_c, ls_models = leansys_c_and_models(tmp_path)
        new = transform(lean_c.read_text(), ls_c.read_text())
        if ls_models is not None:
            manifest = json.loads((ROOT / "shared/orb-spec/kernel_abi.json").read_text())
            for fn in manifest["functions"]:
                if fn["name"].startswith("leansys_"):
                    expected_model = ls_models.get(fn["name"])
                    if fn.get("model") != expected_model:
                        sys.exit(
                            f"kernel_abi.json model mismatch for {fn['name']}: "
                            f"got {fn.get('model')!r}, expected {expected_model!r}"
                        )
    if args.check:
        if OUT.read_text() != new:
            sys.exit(f"{OUT.relative_to(ROOT)} is stale; run scripts/gen_orb_kernel_unboxed.py")
        print(f"{OUT.relative_to(ROOT)} up to date")
    else:
        OUT.write_text(new)
        print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
