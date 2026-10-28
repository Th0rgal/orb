#!/usr/bin/env python3
"""Full public-export scalar conformance. Missing/failed engines yield INCOMPLETE, never PASS.

This harness does not establish P1 acceptance. Receipts are hashes, not signatures.
It executes inputs through actual imported Lean definitions and compiled C/WASM.
Host-adapter, loop/alias/RC and device coverage remain unestablished.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import random
import re
import subprocess
import shutil
import signal
from gen_kernel_bindings import load_manifest

ROOT = Path(__file__).resolve().parents[1]
ORB = ROOT
COMMANDS = []
REQUIRED_ENGINES = ("stock_lean", "stock_extracted_c", "vendored_native_c", "rust_abi", "wasm", "lnir")


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def parse_rows(text):
    result = {}
    for line in text.splitlines():
        a, b = line.split(":")
        key, value = int(a), int(b)
        if key in result or key < 0 or not 0 <= value < 2**64:
            raise ValueError("duplicate/invalid execution row")
        result[key] = value
    return result


def validate_rows(rows, cases):
    if set(rows) != {c["id"] for c in cases}:
        raise ValueError("missing/extra execution rows")
    if any(type(v) is not int or not 0 <= v < 2**64 for v in rows.values()):
        raise ValueError("invalid execution result")


def compare_rows(reference, actual, cases):
    validate_rows(reference, cases)
    validate_rows(actual, cases)
    return [c["id"] for c in cases if reference[c["id"]] != actual[c["id"]]]


def case_receipt(case, engine, result, provenance):
    payload = {"schema": "orb.conformance.case.v1", "case": case, "engine": engine,
               "result_u64": str(result), "provenance": provenance}
    return {"payload": payload, "sha256": canonical_hash(payload)}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(argv, cwd=None, env=None, timeout=240):
    argv = list(map(str, argv))
    cwd, env = cwd or OUT, env or ENV
    try:
        with subprocess.Popen(argv, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                raise
            r = subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
    except (subprocess.TimeoutExpired, OSError) as e:
        def decode(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else (value or "")
        COMMANDS.append({"argv": argv, "cwd": str(cwd), "exit_code": None,
                         "error": str(e), "stdout": decode(getattr(e, "stdout", "")),
                         "stderr": decode(getattr(e, "stderr", ""))})
        (OUT / "commands.json").write_text(json.dumps(COMMANDS, indent=2) + "\n")
        raise RuntimeError(f"command {len(COMMANDS)} did not complete; see commands.json") from e
    rec = {"argv": r.args, "cwd": str(cwd), "exit_code": r.returncode,
           "stdout": r.stdout, "stderr": r.stderr}
    COMMANDS.append(rec)
    (OUT / "commands.json").write_text(json.dumps(COMMANDS, indent=2) + "\n")
    if r.returncode:
        raise RuntimeError(f"command {len(COMMANDS)} failed (exit {r.returncode}); see commands.json")
    return r.stdout


def export_map(path, namespace):
    text = path.read_text()
    # A declaration must follow its own explicit export attribute.
    return {a: f"{namespace}.{b}" for a, b in re.findall(
        r"@\[[^\]]*\bexport\s+(\w+)[^\]]*\]\s*def\s+(\w+)", text)}


def terminate(*_):
    raise SystemExit(143)


def main(argv=None):
    global OUT, ENV, TURBO, SYS, TOOLS
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--turbo-root", required=True, type=Path)
    ap.add_argument("--lean-sys-root", required=True, type=Path)
    ap.add_argument("--lean-bin-dir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path, help="new evidence directory; never overwrite a prior run")
    args = ap.parse_args(argv)
    TURBO, SYS, TOOLS = (p.resolve() for p in (args.turbo_root, args.lean_sys_root, args.lean_bin_dir))
    OUT = args.out.resolve()
    OUT.mkdir(parents=True, exist_ok=False)
    ENV = dict(os.environ, LEAN_PATH=str(OUT))
    COMMANDS.clear()
    # Unwind subprocess ownership on durable-job termination as well as timeout.
    signal.signal(signal.SIGTERM, terminate)
    manifest = load_manifest(ORB / "shared/orb-spec/kernel_abi.json")
    functions = [f for f in manifest["functions"] if not f.get("internal")]
    if len(functions) != 112 or any(not f["name"].startswith(("orb_", "leansys_")) for f in functions):
        raise ValueError("public export inventory changed; qualify the new surface explicitly")
    if run(["git", "rev-parse", "HEAD"], SYS).strip() != "077775ba387f1eeb2976cb8763b4633b8d5ce313":
        raise ValueError("unexpected LeanSys revision")
    sources = [(ORB / "lean/Orb/Kernel.lean", "Orb.Kernel"),
               (SYS / "LeanSys/Spec.lean", "LeanSys.Spec")]
    exports = {}
    for path, ns in sources:
        exports.update(export_map(path, ns))
    if not {f["name"] for f in functions} <= exports.keys():
        raise ValueError("unresolved Lean export")
    bits = {"uint8_t": 8, "uint32_t": 32, "uint64_t": 64}
    rng = random.Random(20261028)
    cases = []
    for f in functions:
        for kind in range(8):
            args = []
            for p in f["params"]:
                cap = (1 << bits[p["type"]]) - 1
                args.append([0, 1, 2, 3, cap, cap - 1, rng.randrange(cap + 1), rng.randrange(cap + 1)][kind])
            cases.append({"id": len(cases), "symbol": f["name"], "args": args})
    (OUT / "cases.json").write_text(json.dumps(cases) + "\n")
    (OUT / "cases.txt").write_text("".join(f"{c['id']}:{c['symbol']}:" + ",".join(map(str, c['args'])) + "\n" for c in cases))
    report = {"status": "INCOMPLETE", "public_exports": 112, "cases": len(cases),
              "heads": {"orb": run(["git", "rev-parse", "HEAD"], ORB).strip(),
                        "turbo": run(["git", "rev-parse", "HEAD"], TURBO).strip()},
              "sources": {str(p): digest(p) for p, _ in sources},
              "engines": {}, "blockers": ["Host-adapter and loop/alias/RC conformance unestablished",
                  "Physical iPhone13 mini and Pixel8 BLOCKED_PHYSICAL_DEVICE",
                  "Only two scalar backend mutations are exercised; full engine/harness and per-family mutation qualification remains open"]}
    report["sources"][str(ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c")] = digest(ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c")
    report["sources"][str(ORB / "shared/orb-spec/kernel_abi.json")] = digest(ORB / "shared/orb-spec/kernel_abi.json")
    report["harness_sha256"] = digest(__file__)
    report["tools"] = {}
    for name, path in [(n, TOOLS / n) for n in ("lean", "leanc", "clang", "ld.lld")] + [
        (n, TURBO / "lean/.lake/build/bin" / n) for n in ("lean-native", "lean-native-core")
    ] + [(n, Path(shutil.which(n) or n)) for n in ("cc", "node", "rustc", "ar")]:
        report["tools"][name] = {"path": str(path), "sha256": digest(path) if path.is_file() else None}
    values = {}

    def engine(name, action):
        try:
            result = action()
            validate_rows(result, cases)
            values[name] = result
            report["engines"][name] = {"status": "EXECUTED", "rows": len(result)}
        except Exception as e:
            report["engines"][name] = {"status": "BLOCKED", "reason": str(e)}
        (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def stock():
        for path, ns in sources:
            olean = OUT / (ns.replace(".", "/") + ".olean")
            olean.parent.mkdir(parents=True, exist_ok=True)
            base = ORB / "lean" if ns.startswith("Orb") else SYS
            run([TOOLS / "lean", "-DwarningAsError=true", path.relative_to(base),
                 "-o", olean, "-c", OUT / (ns + ".c")], base)
        wrappers = ["import Orb.Kernel", "import LeanSys.Spec"]
        dispatch = ["def dispatch (name : String) (args : List UInt64) : UInt64 :=", "  match name with"]
        for f in functions:
            params = " ".join(f"(a{i} : UInt64)" for i in range(len(f["params"])))
            arguments = " ".join(f"a{i}" if p["type"] == "uint64_t" else f"a{i}.toUInt{bits[p['type']]}"
                                 for i, p in enumerate(f["params"]))
            call = f"({exports[f['name']]} {arguments})"
            if f["ret"] != "uint64_t":
                call += ".toUInt64"
            name = "probe_" + f["name"]
            wrappers.append(f"@[export {name}] def {name} {params} : UInt64 := {call}")
            dispatch.append(f'  | "{f["name"]}" => {name} ' + " ".join(f"args[{i}]!" for i in range(len(f["params"]))))
        (OUT / "Wrappers.lean").write_text("\n".join(wrappers) + "\n")
        run([TOOLS / "lean", "Wrappers.lean", "-o", "Wrappers.olean", "-c", "Wrappers.c"])
        dispatch.append('  | _ => panic! "unknown export"')
        runner = '''\ndef main (args : List String) : IO Unit := do
  let contents ← IO.FS.readFile args[0]!
  for line in contents.splitOn "\\n" do
    if !line.isEmpty then
      let fields := line.splitOn ":"
      let xs := (fields[2]!.splitOn ",").map (fun s => UInt64.ofNat s.toNat!)
      IO.println s!"{fields[0]!}:{(dispatch fields[1]! xs).toNat}"
'''
        (OUT / "Oracle.lean").write_text("import Wrappers\n" + "\n".join(dispatch) + runner)
        return parse_rows(run([TOOLS / "lean", "--run", "Oracle.lean", OUT / "cases.txt"]))

    def stock_c():
        run([TOOLS / "lean", "Oracle.lean", "-c", "Oracle.c"])
        run([TOOLS / "leanc", "-O2", "Oracle.c", "Wrappers.c", "Orb.Kernel.c", "LeanSys.Spec.c", "-o", "stock-c"])
        return parse_rows(run([OUT / "stock-c", OUT / "cases.txt"]))

    def native_library(path):
        lib = ctypes.CDLL(str(path))
        types = {"uint8_t": ctypes.c_uint8, "uint32_t": ctypes.c_uint32, "uint64_t": ctypes.c_uint64}
        for f in functions:
            fun = getattr(lib, f["name"])
            fun.argtypes = [types[p["type"]] for p in f["params"]]
            fun.restype = types[f["ret"]]
        return {c["id"]: getattr(lib, c["symbol"])(*c["args"]) for c in cases}

    def native():
        source = ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c"
        run(["cc", "-O2", "-shared", "-fPIC", source, "-o", OUT / "kernel.so"])
        return native_library(OUT / "kernel.so")

    def rust_abi():
        types = {"uint8_t": "u8", "uint32_t": "u32", "uint64_t": "u64"}
        lines = ['use std::{env, fs};', 'unsafe extern "C" {']
        for f in functions:
            params = ", ".join(f'a{i}: {types[p["type"]]}' for i, p in enumerate(f["params"]))
            lines.append(f'fn {f["name"]}({params}) -> {types[f["ret"]]};')
        lines += ['}', 'fn main() {', 'for line in fs::read_to_string(env::args().nth(1).unwrap()).unwrap().lines() {',
                  "let v: Vec<_> = line.split(':').collect();",
                  "let a: Vec<u64> = v[2].split(',').map(|s| s.parse().unwrap()).collect();",
                  'let value = unsafe { match v[1] {']
        for f in functions:
            call_args = ", ".join(f'a[{i}] as {types[p["type"]]}' for i, p in enumerate(f["params"]))
            lines.append(f'"{f["name"]}" => {f["name"]}({call_args}) as u64,')
        lines += ['_ => panic!("unknown symbol"),', '}};', 'println!("{}:{}", v[0], value);', '}}']
        (OUT / "rust-abi.rs").write_text("\n".join(lines) + "\n")
        run(["cc", "-O2", "-c", ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c", "-o", OUT / "kernel.native.o"])
        run(["rustc", "--edition=2024", OUT / "rust-abi.rs", "-C", "link-arg=" + str(OUT / "kernel.native.o"), "-o", OUT / "rust-abi"])
        return parse_rows(run([OUT / "rust-abi", OUT / "cases.txt"]))

    def wasm():
        run([TOOLS / "clang", "--target=wasm32", "-O2", "-nostdlib", "-ffreestanding",
             "-isystem", TOOLS.parent / "include/clang",
             "-c", ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c", "-o", OUT / "kernel.wasm.o"])
        run([TOOLS / "ld.lld", "-flavor", "wasm", "--no-entry", "--export-all",
             OUT / "kernel.wasm.o", "-o", OUT / "kernel.wasm"])
        script = '''const fs = require("fs");
const mod = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
if (WebAssembly.Module.imports(mod).length) throw Error("unexpected imports");
const exp = new WebAssembly.Instance(mod).exports;
const manifest = JSON.parse(fs.readFileSync(process.argv[3]));
const funcs = Object.fromEntries(manifest.functions.map(f => [f.name, f]));
const cases = JSON.parse(fs.readFileSync(process.argv[4]));
for (const c of cases) {
  const f = funcs[c.symbol];
  const args = c.args.map((v, i) => f.params[i].type === "uint64_t" ? BigInt(v) : Number(v));
  let result = exp[c.symbol](...args);
  result = f.ret === "uint64_t" ? BigInt.asUintN(64, result) : result >>> 0;
  console.log(`${c.id}:${result}`);
}
'''
        # Preserve all 64 input bits across JSON's JS number boundary.
        js_cases = [{**c, "args": list(map(str, c["args"]))} for c in cases]
        (OUT / "js-cases.json").write_text(json.dumps(js_cases))
        (OUT / "run-wasm.cjs").write_text(script)
        return parse_rows(run(["node", OUT / "run-wasm.cjs", OUT / "kernel.wasm",
                               ORB / "shared/orb-spec/kernel_abi.json", OUT / "js-cases.json"]))

    def lnir():
        run([TURBO / "lean/.lake/build/bin/lean-native", "emit-lnir", "--wire", OUT / "Wrappers.lean", "-o", OUT / "module.lnir"])
        args = ";".join("probe_" + c["symbol"] + ":" + ",".join(map(str, c["args"])) for c in cases)
        rows = json.loads(run([TURBO / "lean/.lake/build/bin/lean-native-core", "eval-lnir",
                              "--lnir", OUT / "module.lnir", "--args", args, "--batch-json"]))
        if len(rows) != len(cases) or not all(r.get("ok") is True for r in rows):
            raise ValueError("failed/missing LNIR execution rows")
        if not all(r["decl"] == "probe_" + c["symbol"] for r, c in zip(rows, cases)):
            raise ValueError("LNIR declaration identity mismatch")
        return {c["id"]: int(row["value_u64"]) for c, row in zip(cases, rows)}

    for name, action in [("stock_lean", stock), ("stock_extracted_c", stock_c),
                         ("vendored_native_c", native), ("rust_abi", rust_abi), ("wasm", wasm), ("lnir", lnir)]:
        engine(name, action)
    report["mismatches"] = []
    if "stock_lean" in values:
        for name, rows in values.items():
            for c in cases:
                if rows[c["id"]] != values["stock_lean"][c["id"]]:
                    report["mismatches"].append({"case": c, "engine": name,
                        "stock": str(values['stock_lean'][c['id']]), "actual": str(rows[c['id']])})
    else:
        report["blockers"].append("Stock Lean oracle unavailable; comparisons unqualified")
    report["missing_engines"] = [name for name in REQUIRED_ENGINES if name not in values]
    report["mutation_checks"] = {}
    try:
        # Rename the real target, then interpose a bit-flipping forwarding shim.
        # This mutates executed backend code, never an expected answer.
        target = next(f for f in functions if f["name"] == "orb_mix64_word")
        if target["ret"] != "uint64_t" or [p["type"] for p in target["params"]] != ["uint64_t", "uint64_t"]:
            raise ValueError("mutation target signature changed")
        shim = OUT / "mutant.c"
        shim.write_text('#include <stdint.h>\nuint64_t original_mix(uint64_t, uint64_t);\n'
                        'uint64_t orb_mix64_word(uint64_t a, uint64_t b) { return original_mix(a,b) ^ UINT64_C(1); }\n')
        source = ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c"
        run(["cc", "-O2", "-fPIC", "-Dorb_mix64_word=original_mix", "-c", source, "-o", OUT / "mutant.o"])
        run(["cc", "-shared", "-fPIC", OUT / "mutant.o", shim, "-o", OUT / "mutant.so"])
        if "stock_lean" not in values:
            raise RuntimeError("no executed stock reference for mutation qualification")
        mutant_rows = native_library(OUT / "mutant.so")
        killed = compare_rows(values["stock_lean"], mutant_rows, cases)
        if len(killed) != 8:
            raise RuntimeError("native scalar mutant escaped")
        report["mutation_checks"]["native_scalar"] = {"status": "KILLED", "case_ids": killed}
        for src, obj, flags in [(source, "mutant.wasm.o", ["-Dorb_mix64_word=original_mix"]), (shim, "shim.wasm.o", [])]:
            run([TOOLS / "clang", "--target=wasm32", "-O2", "-ffreestanding", "-isystem", TOOLS.parent / "include/clang",
                 *flags, "-c", src, "-o", OUT / obj])
        run([TOOLS / "ld.lld", "-flavor", "wasm", "--no-entry", "--export-all", OUT / "mutant.wasm.o", OUT / "shim.wasm.o", "-o", OUT / "mutant.wasm"])
        rows = parse_rows(run(["node", OUT / "run-wasm.cjs", OUT / "mutant.wasm", ORB / "shared/orb-spec/kernel_abi.json", OUT / "js-cases.json"]))
        killed = compare_rows(values["stock_lean"], rows, cases)
        if len(killed) != 8:
            raise RuntimeError("WASM scalar mutant escaped")
        report["mutation_checks"]["wasm_scalar"] = {"status": "KILLED", "case_ids": killed}
    except Exception as e:
        report["mutation_checks"]["failure"] = str(e)
    (OUT / "values.json").write_text(json.dumps(values, sort_keys=True) + "\n")
    report["artifacts"] = {p.name: digest(p) for p in OUT.iterdir()
                           if p.is_file() and p.name not in ("report.json", "commands.json")}
    provenance = {"sources": report["sources"], "harness_sha256": report["harness_sha256"],
                  "tools": report["tools"], "artifacts": report["artifacts"], "commands_sha256": digest(OUT / "commands.json")}
    (OUT / "provenance.json").write_text(json.dumps(provenance, sort_keys=True) + "\n")
    report["provenance_sha256"] = canonical_hash(provenance)
    with (OUT / "case-receipts.jsonl").open("w") as receipts:
        for name, rows in values.items():
            for c in cases:
                receipts.write(json.dumps(case_receipt(c, name, rows[c["id"]], report["provenance_sha256"]), sort_keys=True) + "\n")
    report["case_receipts_sha256"] = digest(OUT / "case-receipts.jsonl")
    report["case_receipts_signed"] = False
    if report["mismatches"]:
        report["status"] = "FAIL"
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("status", "public_exports", "cases", "engines", "blockers")}, indent=2))
    print("mismatches:", len(report["mismatches"]))
    return 1 if report["mismatches"] else 2  # Unqualified coverage never yields acceptance.


if __name__ == "__main__":
    raise SystemExit(main())
