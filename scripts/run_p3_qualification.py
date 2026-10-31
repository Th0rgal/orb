#!/usr/bin/env python3
"""Repo-owned P3 driver: stock C vs LeanNative scalar C-ABI, signed receipts, honest blockers.

This compares scalar C-ABI results and verifies archive symbol hygiene.
It does not accept P0-P7, qualify devices, or prove the compiler.
"""
import argparse
import ctypes
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
from pathlib import Path

from p3_receipts import SCHEMA, load_private, sign_receipt, verify_receipt, write_keypair

ROOT = Path(__file__).resolve().parents[1]
MASK = {"uint8_t": 0xFF, "uint32_t": 0xFFFFFFFF, "uint64_t": 0xFFFFFFFFFFFFFFFF}
CTYPES = {"uint8_t": ctypes.c_uint8, "uint32_t": ctypes.c_uint32, "uint64_t": ctypes.c_uint64}
DEVICE_STATUS = {
    "iphone_13_mini": "BLOCKED_PHYSICAL_DEVICE",
    "pixel_8": "BLOCKED_PHYSICAL_DEVICE",
    "macbook_air": "BLOCKED_HOST_UNREACHABLE",
}


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def load_manifest():
    manifest = json.loads((ROOT / "shared/orb-spec/kernel_abi.json").read_text())
    functions = manifest["functions"]
    public = [item for item in functions if item["name"].startswith(("orb_", "leansys_"))]
    if len(public) != 129 or len(functions) != 130:
        raise ValueError("kernel ABI export inventory changed")
    return functions


def load_coverage_summary():
    registry = json.loads((ROOT / "shared/orb-spec/coverage_registry.json").read_text())
    counts = registry.get("counts_by_status") or {}
    if registry.get("acceptance") != "INCOMPLETE":
        raise ValueError("coverage registry must remain INCOMPLETE")
    return {
        "partial": int(counts.get("partial", 0)),
        "unconnected": int(counts.get("unconnected", 0)),
        "acceptance": registry["acceptance"],
    }


def corpus(functions):
    rows = []
    for function in functions:
        for index, value in enumerate((0, 1)):
            rows.append({
                "id": len(rows),
                "symbol": function["name"],
                "args": [value] * len(function["params"]),
                "kind": f"boundary-{index}",
            })
    for symbol, args in (
        ("orb_access_step", [1, 1, 1, 0, 0, 0]),
        ("lp_orb_x2dspec_Orb_Kernel_accessStep___redArg", [1, 1, 1, 0, 0]),
    ):
        row = next(item for item in rows if item["symbol"] == symbol and item["args"][0] == 1)
        row["args"] = args
        row["kind"] = "in-scope"
    return rows


def verify_cabi_symbols(path, expected_names):
    proc = subprocess.run(["nm", "-g", "-P", path], capture_output=True, text=True, check=True)
    expected = set(expected_names)
    seen = set()
    macos = platform.system() == "Darwin"
    for line in proc.stdout.splitlines():
        if not line.strip() or line.endswith(("]:", "):", ".o:")):
            continue
        fields = line.split()
        if len(fields) < 2:
            raise ValueError(f"unrecognized nm row: {line}")
        name = fields[0][1:] if macos and fields[0].startswith("_") else fields[0]
        if fields[1] != "T" or name not in expected or name in seen:
            raise ValueError(f"unexpected, imported, non-text or duplicate symbol: {line}")
        seen.add(name)
    if seen != expected:
        raise ValueError(f"missing manifest exports: {sorted(expected - seen)}")


def scalar_call(library, spec_by_name, case):
    spec = spec_by_name[case["symbol"]]
    function = getattr(library, case["symbol"])
    function.argtypes = [CTYPES[param["type"]] for param in spec["params"]]
    function.restype = CTYPES[spec["ret"]]
    return int(function(*case["args"])) & MASK[spec["ret"]]


def compare(functions, stock, candidate, cases):
    spec_by_name = {item["name"]: item for item in functions}
    mismatches = []
    for case in cases:
        expected = scalar_call(stock, spec_by_name, case)
        actual = scalar_call(candidate, spec_by_name, case)
        if actual != expected:
            mismatches.append({
                "id": case["id"],
                "symbol": case["symbol"],
                "expected": expected,
                "actual": actual,
            })
    return mismatches


def build_stock(out, expected_names):
    out = Path(out).resolve()
    source = ROOT / "shared/orb-spec/cabi/orb_kernel_unboxed.c"
    cabi_dir = ROOT / "shared/orb-spec/cabi"
    obj = out / "stock_orb_kernel.o"
    archive = out / "liborb_spec_cabi_stock.a"
    binary = out / "stock.so"
    subprocess.run(
        [
            "cc",
            "-O3",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-unused-label",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
            f"-I{cabi_dir}",
            "-c",
            source,
            "-o",
            obj,
        ],
        check=True,
    )
    verify_cabi_symbols(obj, expected_names)
    subprocess.run(["ar", "rcs", archive, obj], check=True)
    verify_cabi_symbols(archive, expected_names)
    subprocess.run(
        ["cc", "-shared", "-fPIC", "-Wl,--whole-archive", archive, "-Wl,--no-whole-archive", "-o", binary],
        check=True,
    )
    return ctypes.CDLL(binary), archive


def export_map(path, namespace):
    text = path.read_text()
    return {
        symbol: f"{namespace}.{decl}"
        for symbol, decl in re.findall(r"@\[[^\]]*\bexport\s+(\w+)[^\]]*\]\s*def\s+(\w+)", text)
    }


def compile_leannative_from_turbo(out, functions, turbo_root, lean_sys_root, lean_bin_dir):
    out = Path(out).resolve()
    turbo_root = Path(turbo_root).resolve()
    lean_sys_root = Path(lean_sys_root).resolve()
    lean_bin_dir = Path(lean_bin_dir).resolve()
    sources = [(ROOT / "lean/Orb/Kernel.lean", "Orb.Kernel"), (lean_sys_root / "LeanSys/Spec.lean", "LeanSys.Spec")]
    exports = {}
    for path, namespace in sources:
        exports.update(export_map(path, namespace))
    public = [item for item in functions if item["name"].startswith(("orb_", "leansys_"))]
    if not {item["name"] for item in public} <= exports.keys():
        raise ValueError("unresolved Lean export for Wrappers.lean")
    stage = out / "leannative-from-turbo"
    stage.mkdir(parents=True, exist_ok=False)
    env = {**os.environ, "LEAN_PATH": str(stage), "LEAN_NATIVE_TELEMETRY": "off"}
    for path, namespace in sources:
        olean = stage / (namespace.replace(".", "/") + ".olean")
        olean.parent.mkdir(parents=True, exist_ok=True)
        base = ROOT / "lean" if namespace.startswith("Orb") else lean_sys_root
        subprocess.run(
            [lean_bin_dir / "lean", "-DwarningAsError=true", path.relative_to(base), "-o", olean],
            cwd=base,
            env=env,
            check=True,
        )
    bits = {"uint8_t": 8, "uint32_t": 32, "uint64_t": 64}
    wrappers = ["import Orb.Kernel", "import LeanSys.Spec"]
    for item in public:
        params = " ".join(f"(a{i} : UInt64)" for i in range(len(item["params"])))
        args = " ".join(
            f"a{i}" if param["type"] == "uint64_t" else f"a{i}.toUInt{bits[param['type']]}"
            for i, param in enumerate(item["params"])
        )
        call = f"({exports[item['name']]} {args})"
        if item["ret"] != "uint64_t":
            call += ".toUInt64"
        probe = "probe_" + item["name"]
        wrappers.append(f"@[export {probe}] def {probe} {params} : UInt64 := {call}")
    wrappers_lean = stage / "Wrappers.lean"
    wrappers_lean.write_text("\n".join(wrappers) + "\n")
    subprocess.run(
        [lean_bin_dir / "lean", "Wrappers.lean", "-o", "Wrappers.olean"],
        cwd=stage,
        env=env,
        check=True,
    )
    module_lnir = stage / "module.lnir"
    subprocess.run(
        [turbo_root / "lean/.lake/build/bin/lean-native", "emit-lnir", "--wire", wrappers_lean, "-o", module_lnir],
        cwd=stage,
        env=env,
        check=True,
    )
    raw_archive = stage / "libleannative_raw.a"
    raw_header = stage / "libleannative_raw.h"
    clang_bin = lean_bin_dir / "clang" if (lean_bin_dir / "clang").is_file() else (shutil.which("clang") or shutil.which("cc"))
    ar_bin = lean_bin_dir / "llvm-ar" if (lean_bin_dir / "llvm-ar").is_file() else (shutil.which("llvm-ar") or shutil.which("ar"))
    subprocess.run(
        [
            turbo_root / "lean/.lake/build/bin/lean-native-core",
            "compile-static-lib",
            "--arch",
            "aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64",
            "--clang-bin",
            clang_bin,
            "--ar-bin",
            ar_bin,
            "--input",
            module_lnir,
            "-o",
            raw_archive,
            "--header",
            raw_header,
            "--json",
        ],
        cwd=stage,
        env=env,
        check=True,
    )
    return raw_archive


def build_native(out, raw_archive, expected_names):
    out = Path(out).resolve()
    members = out / "leannative-members"
    if members.exists():
        shutil.rmtree(members)
    members.mkdir()
    subprocess.run(["ar", "x", Path(raw_archive).resolve()], cwd=members, check=True)
    objects = sorted(members.glob("*.o"))
    if len(objects) != 1:
        raise ValueError("LeanNative archive must contain exactly one object")
    shim_c = ROOT / "shared/orb-spec/cabi/orb_kernel_leannative_shim.c"
    cabi_dir = ROOT / "shared/orb-spec/cabi"
    shim_o = out / "orb_kernel_leannative_shim.o"
    rebound_o = out / "orb_kernel_leannative_rebound.o"
    merged_o = out / "orb_kernel_leannative.o"
    archive = out / "liborb_spec_cabi_leannative.a"
    binary = out / "leannative.so"
    subprocess.run(
        ["cc", "-O3", "-fPIC", "-Wall", "-Wextra", "-Werror", f"-I{cabi_dir}", "-c", shim_c, "-o", shim_o],
        check=True,
    )
    subprocess.run(
        [
            "objcopy",
            "--redefine-sym",
            "malloc=__orb_leannative_unreachable_malloc",
            "--redefine-sym",
            "memcpy=__orb_leannative_unreachable_memcpy",
            objects[0],
            rebound_o,
        ],
        check=True,
    )
    subprocess.run(["ld", "-r", shim_o, rebound_o, "-o", merged_o], check=True)
    subprocess.run(
        ["objcopy", *[f"--keep-global-symbol={name}" for name in expected_names], merged_o],
        check=True,
    )
    verify_cabi_symbols(merged_o, expected_names)
    subprocess.run(["ar", "rcs", archive, merged_o], check=True)
    verify_cabi_symbols(archive, expected_names)
    subprocess.run(
        ["cc", "-shared", "-fPIC", "-Wl,--whole-archive", archive, "-Wl,--no-whole-archive", "-o", binary],
        check=True,
    )
    return ctypes.CDLL(binary), archive


def select_backend(requested, built):
    if requested not in ("stock-c", "leannative", "auto"):
        raise ValueError("unknown ORB_KERNEL_BACKEND")
    if requested == "auto":
        requested = "leannative" if "leannative" in built else "stock-c"
    if requested not in built:
        raise ValueError(f"requested backend unavailable: {requested}")
    return requested


def archive_sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def receipt_payload(
    backend,
    compared_backend,
    cases,
    mismatches,
    artifact,
    stock_artifact,
    compared_artifact,
    leannative_artifact,
    rollback,
):
    return {
        "schema": SCHEMA,
        "backend": backend,
        "compared_backend": compared_backend,
        "rollback": bool(rollback),
        "artifact_sha256": archive_sha256(artifact),
        "stock_artifact_sha256": archive_sha256(stock_artifact),
        "compared_artifact_sha256": archive_sha256(compared_artifact),
        "leannative_artifact_sha256": archive_sha256(leannative_artifact) if leannative_artifact else None,
        "cases": len(cases),
        "mismatches": len(mismatches),
        "corpus_sha256": canonical_hash(cases),
        "machine": platform.machine(),
        "device_status": DEVICE_STATUS,
        "coverage": "INCOMPLETE",
        "phase_acceptance": False,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument(
        "--leannative-archive",
        type=Path,
        default=Path(os.environ["ORB_LEANNATIVE_ARCHIVE"]) if os.environ.get("ORB_LEANNATIVE_ARCHIVE") else None,
    )
    parser.add_argument("--turbo-root", type=Path)
    parser.add_argument("--lean-sys-root", type=Path)
    parser.add_argument("--lean-bin-dir", type=Path)
    parser.add_argument(
        "--backend",
        default=os.environ.get("ORB_KERNEL_BACKEND", "auto"),
        choices=("auto", "stock-c", "leannative"),
    )
    parser.add_argument("--key", type=Path)
    parser.add_argument("--rollback-stock", action="store_true")
    args = parser.parse_args(argv)
    if args.leannative_archive and args.turbo_root:
        raise ValueError("pass either --leannative-archive or --turbo-root, not both")
    if args.turbo_root and (not args.lean_sys_root or not args.lean_bin_dir):
        raise ValueError("--turbo-root requires --lean-sys-root and --lean-bin-dir")
    out_dir = args.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=False)
    functions = load_manifest()
    coverage_summary = load_coverage_summary()
    expected_names = [item["name"] for item in functions]
    cases = corpus(functions)
    private = load_private(args.key.resolve()) if args.key else write_keypair(out_dir)
    built = {}
    stock, stock_archive = build_stock(out_dir, expected_names)
    built["stock-c"] = (stock, stock_archive)
    raw_archive = args.leannative_archive.resolve() if args.leannative_archive else None
    if args.turbo_root:
        raw_archive = compile_leannative_from_turbo(
            out_dir, functions, args.turbo_root, args.lean_sys_root, args.lean_bin_dir
        )
    if raw_archive:
        built["leannative"] = build_native(out_dir, raw_archive, expected_names)
    chosen = "stock-c" if args.rollback_stock else select_backend(args.backend, built)
    library, artifact = built[chosen]
    if "leannative" in built:
        compared_backend = "leannative"
        compared_library, compared_artifact = built["leannative"]
        leannative_artifact = compared_artifact
    else:
        compared_backend = chosen
        compared_library, compared_artifact = library, artifact
        leannative_artifact = None
    mismatches = compare(functions, stock, compared_library, cases)
    payload = receipt_payload(
        chosen,
        compared_backend,
        cases,
        mismatches,
        artifact,
        stock_archive,
        compared_artifact,
        leannative_artifact,
        args.rollback_stock,
    )
    receipt = sign_receipt(payload, private)
    verify_receipt(receipt, private.public_key())
    (out_dir / "p3-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    report = {
        "status": "FAIL" if mismatches else "EXECUTED_LOCAL",
        "backend": chosen,
        "compared_backend": compared_backend,
        "rollback": bool(args.rollback_stock),
        "artifact_sha256": payload["artifact_sha256"],
        "stock_artifact_sha256": payload["stock_artifact_sha256"],
        "compared_artifact_sha256": payload["compared_artifact_sha256"],
        "leannative_artifact_sha256": payload["leannative_artifact_sha256"],
        "cases": len(cases),
        "mismatches": mismatches,
        "phase_acceptance": False,
        "device_status": DEVICE_STATUS,
        "coverage": coverage_summary,
    }
    (out_dir / "p3-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("status", "backend", "cases", "phase_acceptance")}))
    return 1 if mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
