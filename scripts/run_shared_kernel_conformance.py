#!/usr/bin/env python3
"""Full public-export scalar, host-adapter, loop/alias/RC and mutation-kill conformance.

Missing/failed engines, adapters or qualifications yield INCOMPLETE/FAIL, never PASS.
This harness executes inputs through actual imported Lean definitions, compiled
C/WASM, the production `crates/orb-spec` Rust wrappers, and the shipped Android JNI
`.so`. Receipts are hashes, not signatures. Physical iPhone/Pixel devices remain
`BLOCKED_PHYSICAL_DEVICE`.
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
import sys
import platform
import time
from gen_kernel_bindings import load_manifest
from gen_orb_kernel_unboxed import extract

ROOT = Path(__file__).resolve().parents[1]
ORB = ROOT
COMMANDS = []
EXECUTABLES = {}
REQUIRED_ENGINES = ("stock_lean", "stock_extracted_c", "vendored_native_c", "rust_abi", "wasm", "lnir")
REQUIRED_ADAPTERS = ("rust_orb_spec", "jni_x86_64", "projection_invariants")
MUTATION_FAMILIES = (
    "mission_merge_hierarchy", "transcript_reducer_streaming", "durable_outbox_queue_leases",
    "provider_attempt_lifecycle", "authorization", "scheduling_resources", "incremental_parsing_scroll",
)


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class RowFailure(ValueError):
    def __init__(self, errors, rows):
        super().__init__("; ".join(errors))
        self.rows = rows


def parse_rows(text):
    result, seen, ambiguous, errors = {}, set(), set(), []
    for line_number, line in enumerate(text.splitlines(), 1):
        try:
            a, b = line.split(":")
            if not re.fullmatch(r"[0-9]+", a):
                raise ValueError("execution identity must be unsigned decimal")
            key = int(a)
            if key in seen:
                ambiguous.add(key)
                result.pop(key, None)
                raise ValueError("duplicate execution identity")
            seen.add(key)
            if not re.fullmatch(r"[0-9]+", b):
                raise ValueError("execution value must be unsigned decimal")
            value = int(b)
            if key < 0 or not 0 <= value < 2**64:
                raise ValueError("invalid execution row")
            if key not in ambiguous:
                result[key] = value
        except ValueError as error:
            errors.append(f"line {line_number}: {error}")
    if errors:
        raise RowFailure(errors, result)
    return result


def validate_rows(rows, cases):
    if set(rows) != {c["id"] for c in cases}:
        raise ValueError("missing/extra execution rows")
    if any(type(k) is not int or type(v) is not int or not 0 <= v < 2**64 for k, v in rows.items()):
        raise ValueError("invalid execution result")


def compare_rows(reference, actual, cases):
    validate_rows(reference, cases)
    validate_rows(actual, cases)
    return [c["id"] for c in cases if reference[c["id"]] != actual[c["id"]]]


def case_receipt(case, engine, result, provenance, complete=True):
    payload = {"schema": "orb.conformance.case.v2", "case": case, "engine": engine,
               "result_u64": str(result), "provenance": provenance, "engine_complete": complete}
    return {"payload": payload, "sha256": canonical_hash(payload)}


def write_case_receipts(path, cases, values, partial_values, provenance):
    with path.open("w") as receipts:
        for name, rows in {**partial_values, **values}.items():
            for case in cases:
                if case["id"] in rows:
                    receipt = case_receipt(case, name, rows[case["id"]], provenance, name in values)
                    receipts.write(json.dumps(receipt, sort_keys=True) + "\n")


def build_provenance(report, commands_sha256):
    return {**{k: report[k] for k in ("sources", "harness_sha256", "tools", "artifacts",
                                    "heads", "repositories", "environment")},
            "commands_sha256": commands_sha256}


def record_engine(report, values, partial_values, name, action, cases):
    result = {}
    try:
        result = action()
        validate_rows(result, cases)
        values[name] = result
        report["engines"][name] = {"status": "EXECUTED", "rows": len(result)}
    except Exception as error:
        if isinstance(error, CommandFailure) and error.role == "execution":
            try:
                result = parse_rows(error.stdout)
            except RowFailure as failure:
                result = failure.rows
        elif isinstance(error, RowFailure):
            result = error.rows
        expected = {c["id"] for c in cases}
        observed = {k: v for k, v in result.items() if type(k) is int and k in expected
                    and type(v) is int and 0 <= v < 2**64} if isinstance(result, dict) else {}
        partial_values[name] = observed
        report["engines"][name] = {"status": "BLOCKED", "reason": str(error), "observed_rows": len(observed)}


def qualifications_complete(report):
    adapters = report.get("host_adapters")
    if not isinstance(adapters, dict) or any(
        adapters.get(name, {}).get("status") != "PASS" for name in REQUIRED_ADAPTERS
    ):
        return False
    lar = report.get("loop_alias_rc")
    if not isinstance(lar, dict) or lar.get("status") != "PASS" or lar.get("live_objects") != 0:
        return False
    families = report.get("mutation_families")
    if not isinstance(families, dict) or any(
        families.get(fam, {}).get("killed", 0) < 3 or families.get(fam, {}).get("status") != "PASS"
        for fam in MUTATION_FAMILIES
    ):
        return False
    checks = report.get("mutation_checks")
    if not isinstance(checks, dict) or any(
        not isinstance(v, dict) or v.get("status") != "KILLED" for v in checks.values()
    ):
        return False
    return report.get("total_domain_mutants_killed", 0) >= 21


def summarize(report, values, partial_values, cases, qualification_failed=False):
    report["mismatches"] = []
    if "stock_lean" in values:
        for name, rows in {**partial_values, **values}.items():
            for case in cases:
                key = case["id"]
                if key in rows and rows[key] != values["stock_lean"][key]:
                    report["mismatches"].append({"case": case, "engine": name,
                        "stock": str(values["stock_lean"][key]), "actual": str(rows[key])})
    else:
        report["blockers"].append("Stock Lean oracle unavailable; comparisons unqualified")
    report["missing_engines"] = [name for name in REQUIRED_ENGINES if name not in values]
    report["comparisons"] = sum(len(rows) for name, rows in {**partial_values, **values}.items()
                                if name != "stock_lean") if "stock_lean" in values else 0
    if report["mismatches"] or qualification_failed:
        report["status"] = "FAIL"
        return 1
    if not report["missing_engines"] and not partial_values and qualifications_complete(report):
        report["status"] = "PASS"
        return 0
    report["status"] = "INCOMPLETE"
    return 2


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def conformance_environment(out, inherited):
    # Toolchain/home/temp paths only; credentials and runtime injection variables
    # are neither inherited by engines nor copied into provenance.
    allowed = ("PATH", "HOME", "RUSTUP_HOME", "CARGO_HOME", "TMPDIR", "TEMP", "TMP", "SYSTEMROOT")
    return {**{k: inherited[k] for k in allowed if k in inherited},
            "LEAN_PATH": str(out), "LC_ALL": "C", "LANG": "C"}


class CommandFailure(RuntimeError):
    def __init__(self, message, stdout="", role="prerequisite"):
        super().__init__(message)
        self.stdout = stdout
        self.role = role


def run(argv, cwd=None, env=None, timeout=240, context=None, ready=None, role="prerequisite"):
    if role not in ("prerequisite", "execution"):
        raise ValueError("unknown command evidence role")
    argv = list(map(str, argv))
    argv[0] = EXECUTABLES.get(argv[0], argv[0])
    record = {"argv": argv, "cwd": str(cwd or OUT), "exit_code": None,
              "stdout": "", "stderr": "", "context": context, "role": role}
    try:
        with subprocess.Popen(argv, cwd=cwd or OUT, env=env or ENV, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True) as process:
            try:
                if ready is not None:
                    deadline = time.monotonic() + 10
                    while not ready.exists():
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError("command did not signal readiness")
                        time.sleep(0.01)
                record["stdout"], record["stderr"] = process.communicate(timeout=timeout)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                record["stdout"], record["stderr"] = process.communicate()
                record["exit_code"] = process.returncode
                raise
            record["exit_code"] = process.returncode
    except BaseException as error:
        record["error"] = type(error).__name__ + ": " + str(error)
        if isinstance(error, (OSError, subprocess.TimeoutExpired)):
            raise CommandFailure(record["error"], record["stdout"], role) from error
        raise
    finally:
        COMMANDS.append(record)
        (OUT / "commands.json").write_text(json.dumps(COMMANDS, indent=2) + "\n")
    if record["exit_code"]:
        raise CommandFailure(f"command {len(COMMANDS)} failed (exit {record['exit_code']}); see commands.json", record["stdout"], role)
    return record["stdout"]


def lnir_result(row, case):
    if row.get("decl") != "probe_" + case["symbol"] or row.get("ok") is not True:
        raise ValueError("LNIR result identity/status mismatch")
    value = row.get("value_u64")
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+", value) or int(value) >= 2**64:
        raise ValueError("LNIR result must be an unsigned decimal u64 string")
    return int(value)


def wasm_rows(module):
    return parse_rows(run(["node", OUT / "run-wasm.cjs", module,
                           ORB / "shared/orb-spec/kernel_abi.json", OUT / "js-cases.json"], role="execution"))


def run_lnir_cases(core, module, cases):
    result, errors = {}, []
    for c in cases:
        # One request per process binds this response to one input/case. No
        # positional identity within repeated-declaration batches is trusted.
        binding = "probe_" + c["symbol"] + ":" + ",".join(map(str, c["args"]))
        context = {"case_id": c["id"], "input_sha256": canonical_hash(c)}
        request_errors, raw = [], None
        try:
            raw = run([core, "eval-lnir", "--lnir", module,
                       "--args", binding, "--batch-json"], context=context, role="execution")
        except CommandFailure as error:
            request_errors.append(str(error))
            if error.role == "execution":
                raw = error.stdout
        except Exception as error:
            request_errors.append(str(error))
        if raw is not None:
            try:
                rows = json.loads(raw)
                if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
                    raise ValueError("LNIR request must return exactly one object row")
                result[c["id"]] = lnir_result(rows[0], c)
            except Exception as error:
                request_errors.append(type(error).__name__ + ": " + str(error))
        if request_errors:
            errors.append({"case": c, "error": "; ".join(request_errors)})
    (OUT / "lnir-errors.json").write_text(json.dumps(errors, indent=2) + "\n")
    (OUT / "lnir-observations.json").write_text(json.dumps(result, sort_keys=True) + "\n")
    if errors:
        raise RowFailure([f"{len(errors)} LNIR requests failed; see lnir-errors.json and commands.json"], result)
    return result


class QualificationFailure(ValueError):
    pass


def qualify_mutant(reference, baseline, mutant, cases, target, witness_case_ids=None):
    target_ids = {c["id"] for c in cases if c["symbol"] == target}
    try:
        if not target_ids or compare_rows(reference, baseline, cases):
            raise QualificationFailure("mutation baseline is missing or disagrees with stock")
        actual = set(compare_rows(baseline, mutant, cases))
    except ValueError as error:
        raise QualificationFailure(str(error)) from error
    if witness_case_ids is None:
        if actual != target_ids or any(mutant[i] != baseline[i] ^ 1 for i in target_ids):
            raise QualificationFailure("mutation effect escaped or differs from its intended case set/bit flip")
    else:
        required = set(witness_case_ids)
        if not required or not actual or not (actual <= target_ids) or not (required <= actual):
            raise QualificationFailure("domain mutant survived witness or escaped target export")
    return sorted(actual)


def record_mutant(checks, name, reference, baseline, action, cases, target, witness_case_ids=None, meta=None):
    """Called only after build/reference prerequisites; any bad result fails qualification."""
    try:
        killed = qualify_mutant(reference, baseline, action(), cases, target, witness_case_ids)
        checks[name] = {"status": "KILLED", "case_ids": killed, **(meta or {})}
        return False
    except Exception as error:
        checks[name] = {"status": "FAIL", "reason": str(error), **(meta or {})}
        return True


DOMAIN_MUTANTS = (
    ("m01", "orb_mut_m01", "mission_merge_hierarchy", "orb_mission_control_step",
     "Orb.MutantSuite.kill_m01_missionControl_archivedRevive", [1, 0, 1, 0, 0, 0, 0, 0, 0]),
    ("m02", "orb_mut_m02", "mission_merge_hierarchy", "orb_sidebar_merge_step",
     "Orb.MutantSuite.kill_m02_sidebarMerge_duplicateRow", [7, 7, 100, 200, 0, 0]),
    ("m03", "orb_mut_m03", "mission_merge_hierarchy", "orb_fork_home_step",
     "Orb.MutantSuite.kill_m03_forkHome_overrideHomeLeak", [1, 1, 0, 1, 1, 0, 1]),
    ("m04", "orb_mut_m04", "transcript_reducer_streaming", "orb_transcript_reduce_step",
     "Orb.MutantSuite.kill_m04_transcriptReduce_staleSeqAccepted", [42, 42, 0, 5, 0]),
    ("m05", "orb_mut_m05", "transcript_reducer_streaming", "orb_cursor_page_step",
     "Orb.MutantSuite.kill_m05_cursorPage_inclusiveBoundary", [10, 20, 10, 1, 1, 0, 5]),
    ("m06", "orb_mut_m06", "transcript_reducer_streaming", "orb_agent_event_normalize_step",
     "Orb.MutantSuite.kill_m06_agentEventNormalize_duplicateAdmitted", [0, 3, 1, 1, 1, 1, 64, 1024]),
    ("m07", "orb_mut_m07", "durable_outbox_queue_leases", "orb_queue_step",
     "Orb.MutantSuite.kill_m07_queueStep_prematureConsume", [0, 0]),
    ("m08", "orb_mut_m08", "durable_outbox_queue_leases", "orb_verify_remote_outbox",
     "Orb.MutantSuite.kill_m08_verifyRemoteOutbox_supersededAdmitted", [0, 0, 1, 0, 1, 1, 0, 0, 0]),
    ("m09", "orb_mut_m09", "durable_outbox_queue_leases", "orb_verify_lease_mode",
     "Orb.MutantSuite.kill_m09_verifyLeaseMode_readonlyOverridden", [1, 1, 0, 1]),
    ("m10", "orb_mut_m10", "provider_attempt_lifecycle", "orb_provider_pool_step",
     "Orb.MutantSuite.kill_m10_providerPool_firstByteFailover", [0, 0, 7, 0, 1, 1, 0, 3, 100, 0]),
    ("m11", "orb_mut_m11", "provider_attempt_lifecycle", "orb_proxy_step",
     "Orb.MutantSuite.kill_m11_proxyStep_retryAfterCommit", [1, 0, 1, 0, 3]),
    ("m12", "orb_mut_m12", "provider_attempt_lifecycle", "orb_breaker_step",
     "Orb.MutantSuite.kill_m12_breakerStep_transientPoisonsSub", [4, 1, 3]),
    ("m13", "orb_mut_m13", "authorization", "orb_privilege_step",
     "Orb.MutantSuite.kill_m13_privilegeStep_scopeEscalation", [1, 1, 1, 2, 0, 0, 0, 100, 200, 200]),
    ("m14", "orb_mut_m14", "authorization", "orb_privd_command_step",
     "Orb.MutantSuite.kill_m14_privdCommand_metacharBypass", [1, 0, 1, 0, 1, 0, 0, 0]),
    ("m15", "orb_mut_m15", "authorization", "orb_verify_approval",
     "Orb.MutantSuite.kill_m15_verifyApproval_criticalUnconfirmed", [1, 1, 1, 1, 1, 2, 0]),
    ("m16", "orb_mut_m16", "scheduling_resources", "orb_verify_board_slots",
     "Orb.MutantSuite.kill_m16_verifyBoardSlots_stealsBossSlot", [4, 1, 3]),
    ("m17", "orb_mut_m17", "scheduling_resources", "orb_schedule_step",
     "Orb.MutantSuite.kill_m17_scheduleStep_fireWhileBusy", [1, 1, 0, 0, 1, 1, 10, 20, 30]),
    ("m18", "orb_mut_m18", "scheduling_resources", "orb_route_argmin_step",
     "Orb.MutantSuite.kill_m18_routeArgmin_inadmissibleSelected", [1, 2, 50, 9, 10, 0]),
    ("m19", "orb_mut_m19", "incremental_parsing_scroll", "orb_stream_fence_step",
     "Orb.MutantSuite.kill_m19_streamFence_mismatchedMarkerCloses", [1, 3, 2, 3]),
    ("m20", "orb_mut_m20", "incremental_parsing_scroll", "orb_stream_commit_step",
     "Orb.MutantSuite.kill_m20_streamCommit_commitsInsideOpenFence", [0, 1, 3, 1, 0, 0, 0, 10, 4]),
    ("m21", "orb_mut_m21", "incremental_parsing_scroll", "orb_scroll_epoch_step",
     "Orb.MutantSuite.kill_m21_scrollEpoch_doubleCorrectionInEpoch", [5, 5, 1, 1, 0, 480, 320]),
)


LOOP_ALIAS_RC_PROBES = (
    ("lar_bounded_loop8", 3), ("lar_tuple_loop8", 3), ("lar_rc_exclusive_reuse", 2),
    ("lar_rc_shared_alias", 2), ("lar_rc_branch_drop", 3), ("lar_ite_tuple_proj", 4),
    ("lar_loop_rc_hybrid", 3),
)
LOOP_ALIAS_RC_VECTORS = (
    [0, 0, 0, 0], [1, 1, 1, 1], [4, 42, 7, 19],
    [8, 0xFFFFFFFFFFFFFFFF, 0x123456789ABCDEF0, 0x0F0F0F0F0F0F0F0F],
    [3, 17, 255, 65535], [7, 999999937, 2654435761, 13],
)


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
    ap.add_argument("--expected-orb-head", required=True)
    ap.add_argument("--expected-turbo-head", required=True)
    ap.add_argument("--out", required=True, type=Path, help="new evidence directory; never overwrite a prior run")
    settings = ap.parse_args(argv)
    TURBO, SYS, TOOLS = (p.resolve() for p in (settings.turbo_root, settings.lean_sys_root, settings.lean_bin_dir))
    OUT = settings.out.resolve()
    OUT.mkdir(parents=True, exist_ok=False)
    ENV = conformance_environment(OUT, os.environ)
    COMMANDS.clear()
    EXECUTABLES.clear()
    for name in ("cc", "node", "rustc", "cargo", "ar", "git"):
        candidate = shutil.which(name)
        if candidate:
            EXECUTABLES[name] = str(Path(candidate).resolve())
    # Proxy shims are not the compiler binary named by their symlink.
    for rust_tool in ("rustc", "cargo"):
        if Path(EXECUTABLES.get(rust_tool, "")).name == "rustup":
            EXECUTABLES[rust_tool] = run([EXECUTABLES[rust_tool], "which", rust_tool]).strip()
    # Unwind subprocess ownership on durable-job termination as well as timeout.
    signal.signal(signal.SIGTERM, terminate)
    manifest = load_manifest(ORB / "shared/orb-spec/kernel_abi.json")
    # `internal` also marks six public-prefix steppers not exposed to mobile.
    # The roadmap includes those steppers; exclude only the compiler helper.
    functions = [f for f in manifest["functions"] if f["name"].startswith(("orb_", "leansys_"))]
    if len(functions) != 117 or len(manifest["functions"]) != 118:
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
    witness_cases = {}
    for mut_id, _, _, target_sym, _, witness_args in DOMAIN_MUTANTS:
        existing = [c["id"] for c in cases if c["symbol"] == target_sym and c["args"] == witness_args]
        if not existing:
            cid = len(cases)
            cases.append({"id": cid, "symbol": target_sym, "args": list(witness_args)})
            existing = [cid]
        witness_cases[mut_id] = existing
    (OUT / "cases.json").write_text(json.dumps(cases) + "\n")
    (OUT / "cases.txt").write_text("".join(f"{c['id']}:{c['symbol']}:" + ",".join(map(str, c['args'])) + "\n" for c in cases))
    report = {"status": "INCOMPLETE", "public_exports": 117, "cases": len(cases),
              "heads": {"orb": run(["git", "rev-parse", "HEAD"], ORB).strip(),
                        "turbo": run(["git", "rev-parse", "HEAD"], TURBO).strip()},
              "sources": {str(p): digest(p) for p, _ in sources},
              "engines": {}, "host_adapters": {}, "loop_alias_rc": {},
              "mutation_families": {}, "total_domain_mutants_killed": 0,
              "device_status": {
                  "iphone_13_mini_physical": "BLOCKED_PHYSICAL_DEVICE",
                  "pixel_8_physical": "BLOCKED_PHYSICAL_DEVICE",
              },
              "blockers": ["Physical iPhone13 mini and Pixel8 BLOCKED_PHYSICAL_DEVICE"]}
    for tracked in (
        ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c",
        ORB / "shared/orb-spec/kernel_abi.json",
        ORB / "lean/Orb/MutantSuite.lean",
        ORB / "scripts/conformance_loop_alias_rc.lean",
        ORB / "crates/orb-spec/src/lib.rs",
        ORB / "crates/orb-spec/examples/conformance_runner.rs",
        ORB / "crates/orb-spec/tests/shared_fixtures.rs",
        ORB / "shared/orb-spec/fixtures/projection-invariants.json",
        ORB / "android_dashboard/app/src/main/jniLibs/x86_64/liborb_kernel.so",
        Path(__file__),
        Path(__file__).with_name("gen_kernel_bindings.py"),
        Path(__file__).with_name("gen_orb_kernel_unboxed.py"),
    ):
        report["sources"][str(tracked)] = digest(tracked)
    report["repositories"] = {}
    for name, path in (("orb", ORB), ("turbo", TURBO), ("lean_sys", SYS)):
        dirty = run(["git", "status", "--porcelain=v1", "--untracked-files=all"], path)
        report["repositories"][name] = {"head": run(["git", "rev-parse", "HEAD"], path).strip(), "dirty": dirty}
        if dirty:
            (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            raise ValueError(f"dirty {name} inputs; commit/preserve them explicitly before conformance")
    for name, expected in (("orb", settings.expected_orb_head), ("turbo", settings.expected_turbo_head)):
        if not re.fullmatch(r"[0-9a-f]{40}", expected) or report["repositories"][name]["head"] != expected:
            raise ValueError(f"unexpected {name} revision")
    report["heads"] = {name: state["head"] for name, state in report["repositories"].items()}
    report["environment"] = {**ENV,
                             "platform": platform.platform(), "machine": platform.machine()}
    report["harness_sha256"] = digest(__file__)
    report["tools"] = {}
    for name, path in [(n, TOOLS / n) for n in ("lean", "leanc", "clang", "ld.lld")] + [
        (n, TURBO / "lean/.lake/build/bin" / n) for n in ("lean-native", "lean-native-core")
    ] + [("python", Path(sys.executable))] + [(n, Path(shutil.which(n) or n)) for n in ("cc", "node", "rustc", "cargo", "ar")]:
        path = Path(EXECUTABLES.get(name, str(path))).resolve()
        report["tools"][name] = {"path": str(path), "sha256": digest(path) if path.is_file() else None}
        if path.is_file():
            try:
                version = run([path, "--version"])
                report["tools"][name]["version"] = version
            except CommandFailure as error:
                report["tools"][name]["version_unavailable"] = str(error)
    values, partial_values = {}, {}

    def engine(name, action):
        record_engine(report, values, partial_values, name, action, cases)
        (OUT / "values.json").write_text(json.dumps({"complete": values, "partial": partial_values}, sort_keys=True) + "\n")
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
        return parse_rows(run([TOOLS / "lean", "--run", "Oracle.lean", OUT / "cases.txt"], role="execution"))

    def stock_c():
        run([TOOLS / "lean", "Oracle.lean", "-c", "Oracle.c"])
        run([TOOLS / "leanc", "-O2", "Oracle.c", "Wrappers.c", "Orb.Kernel.c", "LeanSys.Spec.c", "-o", "stock-c"])
        return parse_rows(run([OUT / "stock-c", OUT / "cases.txt"], role="execution"))

    def native_library(path):
        script = OUT / "native-runner.py"
        script.write_text('''import ctypes,json,sys
import resource
from pathlib import Path
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
lib=ctypes.CDLL(sys.argv[1])
manifest=json.loads(Path(sys.argv[2]).read_text())
types={"uint8_t":ctypes.c_uint8,"uint32_t":ctypes.c_uint32,"uint64_t":ctypes.c_uint64}
for f in manifest["functions"]:
    fun=getattr(lib,f["name"])
    fun.argtypes=[types[p["type"]] for p in f["params"]]
    fun.restype=types[f["ret"]]
for c in json.loads(Path(sys.argv[3]).read_text()):
    print("active-case:"+str(c["id"]),file=sys.stderr,flush=True)
    value=getattr(lib,c["symbol"])(*c["args"])
    print(str(c["id"])+":"+str(value),flush=True)
''')
        return parse_rows(run([sys.executable, script, path, ORB / "shared/orb-spec/kernel_abi.json", OUT / "cases.json"], role="execution"))

    def native():
        source = ORB / "shared/orb-spec/cabi/orb_kernel_unboxed.c"
        run(["cc", "-O2", "-dynamiclib" if sys.platform == "darwin" else "-shared", "-fPIC", source, "-o", OUT / "kernel.so"])
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
        run(["rustc", "--edition=2024", OUT / "rust-abi.rs", "-C", "linker=" + EXECUTABLES["cc"],
             "-C", "link-arg=" + str(OUT / "kernel.native.o"), "-o", OUT / "rust-abi"])
        return parse_rows(run([OUT / "rust-abi", OUT / "cases.txt"], role="execution"))

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
        return wasm_rows(OUT / "kernel.wasm")

    def lnir():
        run([TURBO / "lean/.lake/build/bin/lean-native", "emit-lnir", "--wire", OUT / "Wrappers.lean", "-o", OUT / "module.lnir"])
        return run_lnir_cases(TURBO / "lean/.lake/build/bin/lean-native-core", OUT / "module.lnir", cases)

    for name, action in [("stock_lean", stock), ("stock_extracted_c", stock_c),
                         ("vendored_native_c", native), ("rust_abi", rust_abi), ("wasm", wasm), ("lnir", lnir)]:
        engine(name, action)
    qualification_failed = False

    # 1. Production host-adapter conformance: crates/orb-spec, shared fixtures & Android JNI x86_64.
    try:
        if "stock_lean" not in values:
            raise RuntimeError("stock_lean unavailable for host-adapter conformance")
        cargo_target = OUT / "cargo-target"
        run(["cargo", "build", "--locked", "--manifest-path", ORB / "crates/orb-spec/Cargo.toml",
             "--target-dir", cargo_target, "--example", "conformance_runner"])
        runner_bin = cargo_target / "debug/examples/conformance_runner"
        rust_host_rows = parse_rows(run([runner_bin, OUT / "cases.txt"], role="execution"))
        rust_mismatches = compare_rows(values["stock_lean"], rust_host_rows, cases)
        if rust_mismatches:
            qualification_failed = True
            report["host_adapters"]["rust_orb_spec"] = {"status": "FAIL", "mismatches": rust_mismatches}
        else:
            report["host_adapters"]["rust_orb_spec"] = {"status": "PASS", "rows": len(rust_host_rows), "exports": 117}
    except Exception as error:
        report["host_adapters"]["rust_orb_spec"] = {"status": "BLOCKED", "reason": str(error)}
        qualification_failed |= isinstance(error, (RowFailure, ValueError))

    try:
        cargo_target = OUT / "cargo-target"
        fixture_out = run(["cargo", "test", "--locked", "--manifest-path", ORB / "crates/orb-spec/Cargo.toml",
                           "--target-dir", cargo_target, "--test", "shared_fixtures"], role="execution")
        proj_json = json.loads((ORB / "shared/orb-spec/fixtures/projection-invariants.json").read_text())
        fixture_total = sum(len(v) for v in proj_json.values() if isinstance(v, list))
        report["host_adapters"]["projection_invariants"] = {
            "status": "PASS", "fixture_cases": fixture_total, "summary": fixture_out.strip().splitlines()[-1]
        }
    except Exception as error:
        report["host_adapters"]["projection_invariants"] = {"status": "FAIL", "reason": str(error)}
        qualification_failed = True

    try:
        if "stock_lean" not in values:
            raise RuntimeError("stock_lean unavailable for JNI conformance")
        jni_so = ORB / "android_dashboard/app/src/main/jniLibs/x86_64/liborb_kernel.so"
        jni_funcs = [f for f in functions if f.get("jni")]
        jni_cases = [c for c in cases if any(f["name"] == c["symbol"] for f in jni_funcs)]
        (OUT / "jni-cases.json").write_text(json.dumps(jni_cases) + "\n")
        jni_script = OUT / "jni-runner.py"
        jni_script.write_text('''import ctypes, json, resource, sys
from pathlib import Path
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
lib = ctypes.CDLL(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text())
prefix = "Java_" + manifest["jni"]["class"].replace(".", "_") + "_"
arg_t = {"uint8_t": ctypes.c_int32, "uint32_t": ctypes.c_int32, "uint64_t": ctypes.c_int64}
ret_t = {"jbyte": ctypes.c_int8, "jint": ctypes.c_int32, "jlong": ctypes.c_int64}
masks = {"uint8_t": 0xFF, "uint32_t": 0xFFFFFFFF, "uint64_t": 0xFFFFFFFFFFFFFFFF}
def s_val(v, b):
    m = (1 << b) - 1
    x = v & m
    return x - (1 << b) if x >= (1 << (b - 1)) else x
specs = {}
for f in manifest["functions"]:
    j = f.get("jni")
    if not j:
        continue
    fn = getattr(lib, prefix + j["method"])
    fn.argtypes = [ctypes.c_void_p, ctypes.c_void_p] + [arg_t[p["type"]] for p in f["params"]]
    fn.restype = ret_t[j["ret"]]
    specs[f["name"]] = (f, fn)
for c in json.loads(Path(sys.argv[3]).read_text()):
    f, fn = specs[c["symbol"]]
    jargs = [s_val(v, 64 if p["type"] == "uint64_t" else 32) for v, p in zip(c["args"], f["params"])]
    res = fn(None, None, *jargs) & masks[f["ret"]]
    print(f"{c['id']}:{res}", flush=True)
''')
        jni_rows = parse_rows(run([sys.executable, jni_script, jni_so,
                                   ORB / "shared/orb-spec/kernel_abi.json", OUT / "jni-cases.json"], role="execution"))
        jni_ref = {c["id"]: values["stock_lean"][c["id"]] for c in jni_cases}
        jni_mismatches = compare_rows(jni_ref, jni_rows, jni_cases)
        if jni_mismatches:
            qualification_failed = True
            report["host_adapters"]["jni_x86_64"] = {"status": "FAIL", "mismatches": jni_mismatches}
        else:
            report["host_adapters"]["jni_x86_64"] = {
                "status": "PASS", "jni_exports": len(jni_funcs), "rows": len(jni_rows)
            }
    except Exception as error:
        report["host_adapters"]["jni_x86_64"] = {"status": "BLOCKED", "reason": str(error)}
        qualification_failed |= isinstance(error, (RowFailure, ValueError))

    # 2. Loop, tuple-projection, branch-join & reference-counting 3-way conformance.
    try:
        lar_dir = OUT / "loop_alias_rc"
        lar_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ORB / "scripts/conformance_loop_alias_rc.lean", lar_dir / "LoopAliasRc.lean")
        lar_cases = []
        for sym, arity in LOOP_ALIAS_RC_PROBES:
            for vec in LOOP_ALIAS_RC_VECTORS:
                lar_cases.append({"id": len(lar_cases), "symbol": sym, "args": vec[:arity]})
        (lar_dir / "lar_cases.txt").write_text(
            "".join(f"{c['id']}:{c['symbol']}:" + ",".join(map(str, c["args"])) + "\n" for c in lar_cases)
        )
        lar_dispatch = ["import LoopAliasRc", "def dispatch (name : String) (args : List UInt64) : UInt64 :=", "  match name with"]
        for sym, arity in LOOP_ALIAS_RC_PROBES:
            lar_dispatch.append(f'  | "{sym}" => probe_{sym} ' + " ".join(f"args[{i}]!" for i in range(arity)))
        lar_dispatch.append('  | _ => panic! "unknown lar export"')
        lar_runner = '''\ndef main (args : List String) : IO Unit := do
  let contents ← IO.FS.readFile args[0]!
  for line in contents.splitOn "\\n" do
    if !line.isEmpty then
      let fields := line.splitOn ":"
      let xs := (fields[2]!.splitOn ",").map (fun s => UInt64.ofNat s.toNat!)
      IO.println s!"{fields[0]!}:{(dispatch fields[1]! xs).toNat}"
'''
        (lar_dir / "LarOracle.lean").write_text("\n".join(lar_dispatch) + lar_runner)
        lar_env = {**ENV, "LEAN_PATH": str(lar_dir)}
        run([TOOLS / "lean", "-DwarningAsError=true", "LoopAliasRc.lean", "-o", "LoopAliasRc.olean", "-c", "LoopAliasRc.c"],
            lar_dir, env=lar_env)
        lar_stock = parse_rows(run([TOOLS / "lean", "--run", "LarOracle.lean", "lar_cases.txt"],
                                   lar_dir, env=lar_env, role="execution"))
        run([TOOLS / "lean", "LarOracle.lean", "-c", "LarOracle.c"], lar_dir, env=lar_env)
        run([TOOLS / "leanc", "-O2", "LarOracle.c", "LoopAliasRc.c", "-o", "lar-stock-c"], lar_dir, env=lar_env)
        lar_c = parse_rows(run([lar_dir / "lar-stock-c", "lar_cases.txt"], lar_dir, env=lar_env, role="execution"))
        run([TURBO / "lean/.lake/build/bin/lean-native", "emit-lnir", "--wire", lar_dir / "LoopAliasRc.lean",
             "-o", lar_dir / "lar.lnir"], lar_dir, env=lar_env)
        lar_lnir, lar_lnir_opt, max_live_objects = {}, {}, 0
        core_bin = TURBO / "lean/.lake/build/bin/lean-native-core"
        for c in lar_cases:
            binding = f"probe_{c['symbol']}:" + ",".join(map(str, c["args"]))
            for dest, extra in ((lar_lnir, []), (lar_lnir_opt, ["--opt"])):
                raw = run([core_bin, "eval-lnir", "--lnir", lar_dir / "lar.lnir",
                           "--args", binding, "--batch-json", *extra], lar_dir, env=lar_env, role="execution")
                rows = json.loads(raw)
                if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
                    raise ValueError("LAR LNIR request must return exactly one object row")
                dest[c["id"]] = lnir_result(rows[0], c)
                live = rows[0].get("live_objects")
                if type(live) is not int or live < 0:
                    raise ValueError(f"invalid live_objects in LAR LNIR receipt: {live!r}")
                max_live_objects = max(max_live_objects, live)
        tv_json = json.loads(run([core_bin, "validate-tv", "--lnir", lar_dir / "lar.lnir", "--json"], lar_dir, env=lar_env))
        lar_mismatches = (
            compare_rows(lar_stock, lar_c, lar_cases)
            + compare_rows(lar_stock, lar_lnir, lar_cases)
            + compare_rows(lar_stock, lar_lnir_opt, lar_cases)
        )
        wire_text = (lar_dir / "lar.lnir").read_text()
        ir_ops = {op: wire_text.count(op) for op in ("C_inc", "C_dec", "E_ctor", "E_cgeto", "E_isexcl", "E_mktup", "E_projtup", "C_ite")}
        if lar_mismatches or max_live_objects != 0 or not tv_json.get("allPassed") or any(v == 0 for v in ir_ops.values()):
            qualification_failed = True
            report["loop_alias_rc"] = {
                "status": "FAIL", "mismatches": lar_mismatches, "live_objects": max_live_objects,
                "tv_all_passed": tv_json.get("allPassed"), "ir_ops": ir_ops,
            }
        else:
            report["loop_alias_rc"] = {
                "status": "PASS", "probes": len(LOOP_ALIAS_RC_PROBES), "cases": len(lar_cases),
                "engines": ["stock_lean", "stock_extracted_c", "lnir", "lnir_opt"],
                "live_objects": max_live_objects, "tv_all_passed": True, "ir_ops": ir_ops,
            }
    except Exception as error:
        report["loop_alias_rc"] = {"status": "BLOCKED", "reason": str(error)}
        qualification_failed |= isinstance(error, (RowFailure, ValueError))

    # 3. Scalar bit-flip & 21 Lean-witnessed domain mutants across all 7 roadmap families.
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
        run(["cc", "-dynamiclib" if sys.platform == "darwin" else "-shared", "-fPIC", OUT / "mutant.o", shim, "-o", OUT / "mutant.so"])
        if any(name not in values for name in ("stock_lean", "vendored_native_c", "wasm")):
            raise RuntimeError("no complete stock/native/WASM baseline for mutation qualification")
        qualification_failed |= record_mutant(report["mutation_checks"], "native_scalar", values["stock_lean"],
            values["vendored_native_c"], lambda: native_library(OUT / "mutant.so"), cases, target["name"])
        for src, obj, flags in [(source, "mutant.wasm.o", ["-Dorb_mix64_word=original_mix"]), (shim, "shim.wasm.o", [])]:
            run([TOOLS / "clang", "--target=wasm32", "-O2", "-ffreestanding", "-isystem", TOOLS.parent / "include/clang",
                 *flags, "-c", src, "-o", OUT / obj])
        run([TOOLS / "ld.lld", "-flavor", "wasm", "--no-entry", "--export-all", OUT / "mutant.wasm.o", OUT / "shim.wasm.o", "-o", OUT / "mutant.wasm"])
        qualification_failed |= record_mutant(report["mutation_checks"], "wasm_scalar", values["stock_lean"], values["wasm"],
            lambda: wasm_rows(OUT / "mutant.wasm"), cases, target["name"])

        # Compile Lean-verified domain mutants (`Orb.MutantSuite`, 0 sorryAx) to unboxed C/WASM shims.
        mut_dir = OUT / "domain_mutants"
        mut_dir.mkdir(parents=True, exist_ok=True)
        (OUT / "Orb").mkdir(parents=True, exist_ok=True)
        run([TOOLS / "lean", "-DwarningAsError=true", "-DautoImplicit=false", "Orb/MutantSuite.lean",
             "-o", OUT / "Orb/MutantSuite.olean", "-c", mut_dir / "MutantSuite.c"], ORB / "lean")
        extracted_mutants = dict(extract((mut_dir / "MutantSuite.c").read_text()))
        header_lines = [line for line in source.read_text().splitlines()
                        if line.startswith("#include ") or line.startswith("#define ")]
        include_dir = str(ORB / "shared/orb-spec/cabi")
        family_counts = {fam: {"total": 0, "killed": 0, "mutants": []} for fam in MUTATION_FAMILIES}
        total_domain_killed = 0
        for mut_id, mut_export, family, target_sym, theorem_ref, _ in DOMAIN_MUTANTS:
            family_counts[family]["total"] += 1
            if mut_export not in extracted_mutants:
                raise QualificationFailure(f"missing extracted C body for {mut_export}")
            mut_body = re.sub(r"\b" + re.escape(mut_export) + r"\b", target_sym, extracted_mutants[mut_export], count=1)
            mut_shim = mut_dir / f"{mut_id}.c"
            mut_shim.write_text("\n".join(header_lines) + "\n" + mut_body + "\n")
            redefine = f"-D{target_sym}=__orig_{mut_id}_{target_sym}"
            run(["cc", "-O2", "-fPIC", "-I", include_dir, redefine, "-c", source, "-o", mut_dir / f"{mut_id}.base.o"])
            run(["cc", "-O2", "-fPIC", "-I", include_dir, "-c", mut_shim, "-o", mut_dir / f"{mut_id}.shim.o"])
            mut_so = mut_dir / f"{mut_id}.so"
            run(["cc", "-dynamiclib" if sys.platform == "darwin" else "-shared", "-fPIC",
                 mut_dir / f"{mut_id}.base.o", mut_dir / f"{mut_id}.shim.o", "-o", mut_so])
            meta = {"family": family, "target": target_sym, "lean_theorem": theorem_ref}
            c_fail = record_mutant(
                report["mutation_checks"], f"{mut_id}_native", values["stock_lean"], values["vendored_native_c"],
                lambda p=mut_so: native_library(p), cases, target_sym, witness_cases[mut_id], meta
            )
            run([TOOLS / "clang", "--target=wasm32", "-O2", "-ffreestanding", "-isystem", TOOLS.parent / "include/clang",
                 "-I", include_dir, redefine, "-c", source, "-o", mut_dir / f"{mut_id}.base.wasm.o"])
            run([TOOLS / "clang", "--target=wasm32", "-O2", "-ffreestanding", "-isystem", TOOLS.parent / "include/clang",
                 "-I", include_dir, "-c", mut_shim, "-o", mut_dir / f"{mut_id}.shim.wasm.o"])
            mut_wasm = mut_dir / f"{mut_id}.wasm"
            run([TOOLS / "ld.lld", "-flavor", "wasm", "--no-entry", "--export-all",
                 mut_dir / f"{mut_id}.base.wasm.o", mut_dir / f"{mut_id}.shim.wasm.o", "-o", mut_wasm])
            w_fail = record_mutant(
                report["mutation_checks"], f"{mut_id}_wasm", values["stock_lean"], values["wasm"],
                lambda p=mut_wasm: wasm_rows(p), cases, target_sym, witness_cases[mut_id], meta
            )
            qualification_failed |= (c_fail or w_fail)
            if not (c_fail or w_fail):
                family_counts[family]["killed"] += 1
                family_counts[family]["mutants"].append(mut_id)
                total_domain_killed += 1
        for fam, info in family_counts.items():
            info["status"] = "PASS" if info["killed"] >= 3 and info["killed"] == info["total"] else "FAIL"
        report["mutation_families"] = family_counts
        report["total_domain_mutants_killed"] = total_domain_killed
    except Exception as e:
        report["mutation_checks"]["failure"] = str(e)
        qualification_failed |= isinstance(e, QualificationFailure)
    exit_code = summarize(report, values, partial_values, cases, qualification_failed)
    (OUT / "values.json").write_text(json.dumps({"complete": values, "partial": partial_values}, sort_keys=True) + "\n")
    report["artifacts"] = {str(p.relative_to(OUT)): digest(p) for p in OUT.rglob("*")
                           if p.is_file() and p.name not in ("report.json", "commands.json")}
    provenance = build_provenance(report, digest(OUT / "commands.json"))
    (OUT / "provenance.json").write_text(json.dumps(provenance, sort_keys=True) + "\n")
    report["provenance_sha256"] = canonical_hash(provenance)
    write_case_receipts(OUT / "case-receipts.jsonl", cases, values, partial_values, report["provenance_sha256"])
    report["case_receipts_sha256"] = digest(OUT / "case-receipts.jsonl")
    report["case_receipts_signed"] = False
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in (
        "status", "public_exports", "cases", "engines", "host_adapters",
        "loop_alias_rc", "total_domain_mutants_killed", "device_status", "blockers"
    )}, indent=2))
    print("comparisons:", report["comparisons"], "observed mismatches:", len(report["mismatches"]))
    return exit_code  # Unqualified coverage never yields acceptance.


if __name__ == "__main__":
    raise SystemExit(main())
