#!/usr/bin/env python3
"""Generate an incomplete ABI inventory with explicit, source-bound partial evidence.

Proof, caller and executed-test evidence remains unresolved until explicitly
reviewed. --check rejects stale output and unsupported evidence or statuses.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "shared/orb-spec/kernel_abi.json"
REGISTRY_PATH = ROOT / "shared/orb-spec/coverage_registry.json"
KERNEL_LEAN = ROOT / "lean/Orb/Kernel.lean"
EVIDENCE_PATH = ROOT / "shared/orb-spec/coverage_evidence.json"


def checked_evidence(names: list[str]) -> dict[str, Any]:
    """Validate reviewed links, not their semantic adequacy or kernel provenance.

    Hashes bind local execution receipts to source files. A source occurrence
    alone never promotes an export to authoritative or accepted coverage.
    """
    evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
    if evidence.get("schema_version") != "orb-partial-evidence-v1":
        raise ValueError("unknown evidence schema")
    entries = evidence["entries"]
    if not isinstance(entries, dict) or not entries.keys() <= set(names):
        raise ValueError("evidence for unknown export")
    for entry in entries.values():
        if (entry["status"] != "partial" or not entry["claim"] or not entry["blockers"]
                or not entry["assumptions"] or not entry["sources"]):
            raise ValueError("partial evidence must state its limits")
        texts = {}
        for source in entry["sources"]:
            path = Path(source["path"])
            if path.is_absolute() or ".." in path.parts or (ROOT / path).is_symlink():
                raise ValueError("evidence path must be repository-local")
            data = (ROOT / path).read_bytes()
            if hashlib.sha256(data).hexdigest() != source["sha256"]:
                raise ValueError(f"stale evidence source: {path}")
            texts[str(path)] = data.decode("utf-8")
        for link in entry["links"]:
            kind, symbol = link["kind"], link["symbol"]
            if kind not in ("theorem", "host_observer", "host_test"):
                raise ValueError("unsupported evidence link kind")
            # Require a declaration, rather than a comment, import or call.
            keyword = "theorem" if kind == "theorem" else "(?:async\\s+)?fn"
            if not re.search(r"^\s*(?:pub(?:\([^)]*\))?\s+)?" + keyword
                             + r"\s+" + re.escape(symbol) + r"(?=\s|\()",
                             texts[link["path"]], re.MULTILINE):
                raise ValueError(f"missing evidence declaration: {symbol}")
        receipt = entry["execution"]
        log = texts[receipt["path"]]
        if (receipt["exit_code"] != 0 or receipt["result"] != "TESTED_LOCAL"
                or "test result: ok." not in log or "0 failed;" not in log):
            raise ValueError("execution receipt is not a successful local test run")
        for link in entry["links"]:
            if link["kind"] == "host_test" and f"::{link['symbol']} ... ok" not in log:
                raise ValueError("linked host test did not execute successfully")
    return entries


def parse_lean_export_map(lean_text: str, module_prefix: str) -> dict[str, str]:
    export_map: dict[str, str] = {}
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


def parse_kernel_export_map(kernel_text: str) -> dict[str, str]:
    return parse_lean_export_map(kernel_text, "Orb.Kernel")


def resolve_local_leansys_spec() -> Path | None:
    import os

    env_dir = os.environ.get("LEAN_SYS_DIR")
    if env_dir and (Path(env_dir) / "LeanSys/Spec.lean").is_file():
        return Path(env_dir) / "LeanSys/Spec.lean"
    sibling = ROOT.parent / "lean-sys/LeanSys/Spec.lean"
    if sibling.is_file():
        return sibling
    return None


def resolve_export_models(manifest: dict[str, Any]) -> dict[str, str]:
    export_map = parse_kernel_export_map(KERNEL_LEAN.read_text(encoding="utf-8"))
    leansys_spec = resolve_local_leansys_spec()
    leansys_map = (
        parse_lean_export_map(leansys_spec.read_text(encoding="utf-8"), "LeanSys.Spec")
        if leansys_spec is not None
        else {}
    )
    for fn in manifest["functions"]:
        sym = fn["name"]
        manifest_model = fn.get("model")
        if manifest_model is not None:
            if not isinstance(manifest_model, str) or not manifest_model.startswith("LeanSys.Spec."):
                raise ValueError(f"unsupported manifest model for {sym}: {manifest_model!r}")
            if sym in export_map:
                raise ValueError(f"manifest model conflicts with Orb.Kernel export {sym}")
            if leansys_map and leansys_map.get(sym) != manifest_model:
                raise ValueError(
                    f"manifest model mismatch for {sym}: {manifest_model!r} != {leansys_map.get(sym)!r}"
                )
            export_map[sym] = manifest_model
        elif sym in leansys_map:
            export_map[sym] = leansys_map[sym]
    return export_map


def build_registry(manifest: dict[str, Any] | None = None) -> dict[str, Any]:
    """Inventory declarations only. Source occurrence does not certify a proof or caller."""
    if manifest is None:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    names = [fn["name"] for fn in manifest["functions"]]
    if len(names) != len(set(names)):
        raise ValueError("duplicate manifest export")
    export_map = resolve_export_models(manifest)
    evidence = checked_evidence(names)
    entries = []
    for sym in names:
        model = export_map.get(sym)
        entry = {
            "export": sym,
            "requirement": f"Inventory ABI declaration {sym}; behavioral acceptance pending",
            "model": model,
            "theorems": [],
            "authoritative_callers": [],
            "adapter_tests": [],
            "status": "unconnected",
            "assumptions": [
                "Scalar inputs are supplied by the host; freshness and enforcement are not established here.",
                "Symbolic cpuFuel annotations do not establish runtime complexity or branch-free execution.",
            ],
            "blockers": [
                "Proof-to-export, authoritative caller and executed adapter-test links require explicit review.",
            ] + ([] if model else ["Source model unresolved (including pinned LeanSys or compiler helper)."]),
        }
        if sym in evidence:
            entry["status"] = "partial"
            entry["evidence"] = evidence[sym]
            entry["blockers"] = evidence[sym]["blockers"]
        entries.append(entry)
    counts = {status: sum(e["status"] == status for e in entries)
              for status in sorted({e["status"] for e in entries})}
    return {
        "schema_version": "orb-coverage-registry-v1",
        "acceptance": "INCOMPLETE",
        "total_exports": len(entries),
        "counts_by_status": counts,
        "entries": entries,
    }


def validate_registry(reg: dict[str, Any], manifest: dict[str, Any] | None = None) -> None:
    """Fail closed against the reviewed inventory schema, including invented links.

    Partial links come only from the explicit evidence file. They never certify
    authoritative callers, full adapter parity, or phase acceptance.
    """
    expected = build_registry(manifest)
    if reg != expected:
        raise ValueError("registry differs from declaration inventory; unsupported links, status or missing exports")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="Verify committed registry matches generated & is valid")
    args = ap.parse_args(argv)

    reg = build_registry()
    validate_registry(reg)
    text = json.dumps(reg, indent=2) + "\n"

    if args.check:
        if not REGISTRY_PATH.is_file():
            print(f"missing {REGISTRY_PATH.relative_to(ROOT)}", file=sys.stderr)
            return 1
        current_text = REGISTRY_PATH.read_text(encoding="utf-8")
        current_reg = json.loads(current_text)
        validate_registry(current_reg)
        if current_text != text:
            print(
                f"stale {REGISTRY_PATH.relative_to(ROOT)} (run python3 scripts/gen_coverage_registry.py)",
                file=sys.stderr,
            )
            return 1
        print(
            f"coverage registry OK: {reg['total_exports']} exports "
            f"({reg['counts_by_status']})"
        )
        return 0

    REGISTRY_PATH.write_text(text, encoding="utf-8")
    print(
        f"wrote {REGISTRY_PATH.relative_to(ROOT)} "
        f"({reg['total_exports']} exports: {reg['counts_by_status']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
