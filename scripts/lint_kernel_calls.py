#!/usr/bin/env python3
"""Lint client call sites of the verified Orb kernel admission checks.

Rules (each one guards a bug class that shipped before):
  duplicated-count   gfmPipeRowAdmitted(..., colCount, sepCols) passes the same
                     `x.size`/`x.length`/`x.count` twice, so the separator check
                     is vacuous.
  synthetic-length   richTagAdmitted/gfmPipeRowAdmitted gets a fabricated span
                     (`len + 7`, `max(1, n)`, literal 0 offset) instead of the
                     real offsets in the source buffer.
  stale-tag-kind     a tag-kind range still admits kind 4 (`tagKind <= 4`,
                     `1...4`, `1..4`); the kernel only admits kinds 1..3.
  jni-arity          a Kotlin `external fun` disagrees with kernel_abi.json.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "shared/orb-spec/kernel_abi.json"
KOTLIN_KERNEL = ROOT / "android_dashboard/app/src/main/java/sh/sandboxed/dashboard/orb/OrbKernel.kt"
SCAN_DIRS = [
    "orb/src",
    "android_dashboard/app/src/main/java/sh/sandboxed/dashboard/orb",
    "ios_dashboard/SandboxedDashboard/Orb",
]
SUFFIXES = {".ts", ".tsx", ".kt", ".swift"}

PIPE_FNS = ("gfmPipeRowAdmitted", "leansysGfmPipeRowAdmitted")
TAG_FNS = ("richTagAdmitted", "leansysRichTagAdmitted")
CALL = re.compile(r"\b(" + "|".join(PIPE_FNS + TAG_FNS) + r")\s*\(")
DECL_BEFORE = re.compile(r"(?:\bfun|\bfunc|\bfunction)\s+$")
COUNT = re.compile(r"^([\w.\[\]]+)\.(size|length|count)$")
SYNTHETIC = re.compile(r"\+\s*\d+\s*$|\b(?:Math\.max|maxOf|max)\s*\(\s*1\s*,")
STALE_KIND = [
    re.compile(r"\btagKind\s*<=\s*4\b"),
    re.compile(r"\btagKind\s*<\s*5\b"),
    re.compile(r"\b1\s*\.\.\.\s*4\b.*tagKind|tagKind.*\b1\s*\.\.\.\s*4\b"),
    re.compile(r"\btagKind\s+in\s+1\s*\.\.\s*4\b"),
]
JNI_KT = {"uint8_t": "Int", "uint32_t": "Int", "uint64_t": "Long"}
JNI_KT_RET = {"jbyte": "Byte", "jint": "Int", "jlong": "Long"}


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.message}"


def split_args(text: str, start: int) -> tuple[list[str], int]:
    """Split the argument list beginning just after the opening paren at `start`."""
    depth, i, cur, args = 1, start, [], []
    while i < len(text) and depth:
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                break
        if c == "," and depth == 1:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
    tail = "".join(cur).strip()
    if tail:
        args.append(tail)
    return args, i


def strip_label(arg: str) -> str:
    """Drop Swift argument labels (`rowLen: x` -> `x`)."""
    m = re.match(r"^[A-Za-z_]\w*\s*:\s*(?!:)(.*)$", arg, re.S)
    return m.group(1).strip() if m else arg


def lint_source(rel: str, text: str) -> list[Finding]:
    out: list[Finding] = []
    for m in CALL.finditer(text):
        if DECL_BEFORE.search(text[max(0, m.start() - 12):m.start()]):
            continue
        line = text.count("\n", 0, m.start()) + 1
        raw, _ = split_args(text, m.end())
        args = [strip_label(a) for a in raw]
        fn = m.group(1)
        for a in args:
            if SYNTHETIC.search(a):
                out.append(Finding(rel, line, "synthetic-length", f"{fn} argument `{a}` fabricates a span; pass the real offsets"))
        if fn in PIPE_FNS:
            if len(args) < 5:
                out.append(Finding(rel, line, "synthetic-length", f"{fn} needs rowOff, rowLen, bufLen, colCount, sepCols"))
                continue
            col, sep = args[3], args[4]
            cm = COUNT.match(col)
            if col == sep or (cm and COUNT.match(sep) and cm.group(1) == COUNT.match(sep).group(1)):
                out.append(Finding(rel, line, "duplicated-count", f"{fn} passes `{col}` as both colCount and sepCols"))
            if args[0].strip() == "0" and args[1] == args[2]:
                out.append(Finding(rel, line, "synthetic-length", f"{fn} checks a detached row (offset 0, rowLen == bufLen)"))
        else:
            if len(args) < 6:
                out.append(Finding(rel, line, "synthetic-length", f"{fn} needs tagOff, tagLen, attrOff, attrLen, bufLen, tagKind"))
    for no, ln in enumerate(text.splitlines(), 1):
        if any(p.search(ln) for p in STALE_KIND):
            out.append(Finding(rel, no, "stale-tag-kind", "tag kind range admits 4; the kernel admits kinds 1..3"))
    return out


def lint_jni(manifest: dict, kt_rel: str, kt: str) -> list[Finding]:
    out: list[Finding] = []
    decls = {}
    for m in re.finditer(r"external\s+fun\s+(\w+)\s*\(", kt):
        raw, end = split_args(kt, m.end())
        ret = re.match(r"\)\s*:\s*(\w+)", kt[end:])
        decls[m.group(1)] = (raw, ret.group(1) if ret else "Unit", kt.count("\n", 0, m.start()) + 1)
    for fn in manifest["functions"]:
        jni = fn.get("jni")
        if not jni:
            continue
        meth = jni["method"]
        if meth not in decls:
            out.append(Finding(kt_rel, 1, "jni-arity", f"missing `external fun {meth}` for {fn['name']}"))
            continue
        raw, ret, line = decls.pop(meth)
        want = [JNI_KT[p["type"]] for p in fn["params"]]
        got = [a.split(":", 1)[1].strip() if ":" in a else a for a in raw]
        if got != want:
            out.append(Finding(kt_rel, line, "jni-arity", f"{meth}({', '.join(got)}) != manifest {fn['name']}({', '.join(want)})"))
        if ret != JNI_KT_RET[jni["ret"]]:
            out.append(Finding(kt_rel, line, "jni-arity", f"{meth} returns {ret}, manifest says {JNI_KT_RET[jni['ret']]}"))
    for meth, (_, _, line) in decls.items():
        out.append(Finding(kt_rel, line, "jni-arity", f"`external fun {meth}` has no kernel_abi.json entry"))
    return out


def lint_repo(root: Path = ROOT) -> list[Finding]:
    findings: list[Finding] = []
    for d in SCAN_DIRS:
        base = root / d
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if p.suffix in SUFFIXES and p.is_file():
                findings += lint_source(str(p.relative_to(root)), p.read_text())
    manifest = json.loads((root / MANIFEST.relative_to(ROOT)).read_text())
    kt = root / KOTLIN_KERNEL.relative_to(ROOT)
    if kt.exists():
        findings += lint_jni(manifest, str(kt.relative_to(root)), kt.read_text())
    return findings


def main() -> int:
    findings = lint_repo()
    for f in findings:
        print(f, file=sys.stderr)
    if findings:
        print(f"{len(findings)} kernel call-site finding(s)", file=sys.stderr)
        return 1
    print("kernel call sites: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
