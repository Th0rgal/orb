#!/usr/bin/env python3
"""Generate the Orb kernel C header and JNI wrapper from shared/orb-spec/kernel_abi.json.

The manifest is the single source of truth for every exported kernel symbol:
its return type, the order/name/C type of each argument and (optionally) the
JNI method that wraps it. Run without flags to rewrite the generated files,
or with --check to fail when they are out of date (used by CI).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "shared/orb-spec/kernel_abi.json"

C_TYPES = {"uint8_t", "uint32_t", "uint64_t"}
JNI_ARG = {"uint8_t": "jint", "uint32_t": "jint", "uint64_t": "jlong"}
JNI_RET = {"jbyte", "jint", "jlong"}
IDENT = re.compile(r"[A-Za-z_]\w*$")


class ManifestError(ValueError):
    pass


def load_manifest(path: Path = MANIFEST) -> dict:
    data = json.loads(path.read_text())
    validate(data)
    return data


def validate(data: dict) -> None:
    seen: set[str] = set()
    methods: set[str] = set()
    for fn in data["functions"]:
        name = fn["name"]
        if not IDENT.match(name):
            raise ManifestError(f"bad symbol name {name!r}")
        if name in seen:
            raise ManifestError(f"duplicate symbol {name}")
        seen.add(name)
        if fn["ret"] not in C_TYPES:
            raise ManifestError(f"{name}: unsupported return type {fn['ret']}")
        pnames = [p["name"] for p in fn["params"]]
        if len(set(pnames)) != len(pnames):
            raise ManifestError(f"{name}: duplicate parameter names {pnames}")
        for p in fn["params"]:
            if p["type"] not in C_TYPES:
                raise ManifestError(f"{name}.{p['name']}: unsupported type {p['type']}")
            if not IDENT.match(p["name"]):
                raise ManifestError(f"{name}: bad parameter name {p['name']!r}")
            if p.get("jni") not in (None, "sat_u8"):
                raise ManifestError(f"{name}.{p['name']}: unknown jni conversion {p['jni']}")
            if p.get("jni") == "sat_u8" and p["type"] != "uint8_t":
                raise ManifestError(f"{name}.{p['name']}: sat_u8 requires uint8_t")
        jni = fn.get("jni")
        if jni:
            if fn.get("internal"):
                raise ManifestError(f"{name}: internal symbols cannot be JNI-exported")
            if jni["ret"] not in JNI_RET:
                raise ManifestError(f"{name}: unsupported JNI return {jni['ret']}")
            if jni["method"] in methods:
                raise ManifestError(f"duplicate JNI method {jni['method']}")
            methods.add(jni["method"])


def render_header(data: dict) -> str:
    protos = [f"{fn['ret']} {fn['name']}({', '.join(p['type'] for p in fn['params'])});" for fn in data["functions"]]
    return "\n".join([
        "#ifndef ORB_KERNEL_H",
        "#define ORB_KERNEL_H",
        "#include <stdint.h>",
        "#ifdef __cplusplus",
        'extern "C" {',
        "#endif",
        *protos,
        "#ifdef __cplusplus",
        "}",
        "#endif",
        "#endif",
    ]) + "\n"


def jni_arg(p: dict) -> str:
    if p.get("jni") == "sat_u8":
        return f"sat_u8({p['name']})"
    return f"({p['type']}){p['name']}"


def render_jni(data: dict) -> str:
    cfg = data["jni"]
    prefix = "Java_" + cfg["class"].replace(".", "_") + "_"
    out = [
        "#include <jni.h>",
        "#include <stdint.h>",
        f'#include "{cfg["include"]}"',
        "",
        "static uint8_t sat_u8(jint v) {",
        "    return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v);",
        "}",
    ]
    for fn in data["functions"]:
        jni = fn.get("jni")
        if not jni:
            continue
        params = "".join(f", {JNI_ARG[p['type']]} {p['name']}" for p in fn["params"])
        args = ", ".join(jni_arg(p) for p in fn["params"])
        out += [
            "",
            f"JNIEXPORT {jni['ret']} JNICALL",
            f"{prefix}{jni['method']}(JNIEnv *env, jclass clazz{params}) {{",
            f"    return ({jni['ret']}){fn['name']}({args});",
            "}",
        ]
    return "\n".join(out) + "\n"


def outputs(data: dict) -> dict[Path, str]:
    return {
        ROOT / data["header"]: render_header(data),
        ROOT / data["jni"]["path"]: render_jni(data),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="fail if generated files are stale")
    args = ap.parse_args(argv)
    try:
        data = load_manifest()
    except (ManifestError, KeyError) as e:
        print(f"kernel_abi.json: {e}", file=sys.stderr)
        return 2
    stale = []
    for path, text in outputs(data).items():
        rel = path.relative_to(ROOT)
        current = path.read_text() if path.exists() else None
        if current == text:
            continue
        if args.check:
            stale.append(str(rel))
        else:
            path.write_text(text)
            print(f"wrote {rel}")
    if stale:
        print("stale generated kernel bindings (run scripts/gen_kernel_bindings.py):", *stale, sep="\n  ", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
