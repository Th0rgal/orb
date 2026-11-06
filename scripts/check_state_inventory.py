#!/usr/bin/env python3
"""Validate docs/specs/state-machine-inventory.md and .sandboxed/validation.toml."""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INVENTORY_REL = Path("docs/specs/state-machine-inventory.md")
DEFAULT_VALIDATION_REL = Path(".sandboxed/validation.toml")

EXPECTED_SM_IDS = [f"SM-{index:02d}" for index in range(1, 28)]
EXPECTED_GAP_IDS = [f"G-ORB-{index}" for index in range(1, 9)]

SM_COLUMNS = [
    "id",
    "title",
    "canonical_owner",
    "current_files",
    "current_encoding",
    "primary_hazard",
    "lean_target_or_adapter_rationale",
    "target_phase",
    "status",
    "reproducer_or_gate",
    "closing_pr",
]

GAP_COLUMNS = [
    "gap_id",
    "summary",
    "current_files",
    "linked_sm_ids",
    "target_phase",
    "status",
]

VALID_STATUSES = {"OPEN", "IN_PROGRESS", "COMPLETED"}
VALID_PHASES = {f"R{index}" for index in range(1, 9)}
VALID_MODES = {"incremental", "clean"}
GATE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
CLOSING_PR_TOKEN_RE = re.compile(r"^(?:Th0rgal/orb)?#([1-9][0-9]*)$")

MATRIX_KEYS = {"version", "project", "profile", "gates"}
GATE_KEYS = {
    "id",
    "description",
    "command",
    "cwd",
    "dependencies",
    "depends_on",
    "required",
    "mode",
    "reuse",
    "toolchain",
    "timeout_secs",
    "artifacts",
}


def strip_code(cell: str) -> str:
    value = cell.strip()
    if (
        len(value) >= 2
        and value.startswith("`")
        and value.endswith("`")
        and "`" not in value[1:-1]
    ):
        return value[1:-1].strip()
    return value


def split_table_row(line: str) -> list[str]:
    stripped = line.strip()
    if not (stripped.startswith("|") and stripped.endswith("|")):
        raise ValueError(f"malformed markdown table row: {line!r}")
    inner = stripped[1:-1]
    cells: list[str] = []
    current: list[str] = []
    in_code = False
    escaped = False
    for ch in inner:
        if escaped:
            current.append(ch)
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if ch == "`":
            in_code = not in_code
            current.append(ch)
            continue
        if ch == "|" and not in_code:
            cells.append("".join(current).strip())
            current = []
            continue
        current.append(ch)
    cells.append("".join(current).strip())
    return cells


def is_separator_row(cells: list[str]) -> bool:
    return bool(cells) and all(bool(re.fullmatch(r":?-{3,}:?", cell.strip())) for cell in cells)


def parse_markdown_tables(markdown: str) -> list[tuple[list[str], list[dict[str, str]]]]:
    lines = markdown.splitlines()
    tables: list[tuple[list[str], list[dict[str, str]]]] = []
    idx = 0
    while idx + 1 < len(lines):
        if lines[idx].lstrip().startswith("|") and lines[idx + 1].lstrip().startswith("|"):
            header = [strip_code(cell) for cell in split_table_row(lines[idx])]
            separator = split_table_row(lines[idx + 1])
            if len(header) == len(separator) and is_separator_row(separator):
                idx += 2
                rows: list[dict[str, str]] = []
                while idx < len(lines) and lines[idx].lstrip().startswith("|"):
                    values = split_table_row(lines[idx])
                    if len(values) != len(header):
                        raise ValueError(
                            f"table column count mismatch at line {idx + 1}: "
                            f"expected {len(header)}, got {len(values)}"
                        )
                    rows.append(dict(zip(header, values, strict=True)))
                    idx += 1
                tables.append((header, rows))
                continue
        idx += 1
    return tables


def _walk_confined(
    repo_root: Path,
    resolved_root: Path,
    base: Path,
    parts: tuple[str, ...],
    raw_path: str,
    context: str,
    *,
    remaining_symlinks: int = 40,
) -> Path:
    current = base
    abs_root = repo_root.absolute()
    for idx, part in enumerate(parts):
        if part in {"", "."}:
            continue
        if part == "..":
            parent = current.parent
            if current == resolved_root or not parent.is_relative_to(resolved_root):
                raise ValueError(f"{context}: path escapes repository root ({raw_path!r})")
            current = parent
            continue
        candidate = current / part
        try:
            is_link = candidate.is_symlink()
        except OSError as exc:
            raise ValueError(f"{context}: invalid path ({raw_path!r})") from exc
        if is_link:
            if remaining_symlinks <= 0:
                raise ValueError(f"{context}: symlink loop in path ({raw_path!r})")
            try:
                target = candidate.readlink()
            except OSError as exc:
                raise ValueError(f"{context}: unreadable symlink in path ({raw_path!r})") from exc
            if target.is_absolute():
                if target.is_relative_to(resolved_root):
                    rel_target = target.relative_to(resolved_root)
                elif target.is_relative_to(abs_root):
                    rel_target = target.relative_to(abs_root)
                else:
                    raise ValueError(f"{context}: path escapes repository root ({raw_path!r})")
                current = _walk_confined(
                    repo_root,
                    resolved_root,
                    resolved_root,
                    rel_target.parts,
                    raw_path,
                    context,
                    remaining_symlinks=remaining_symlinks - 1,
                )
            else:
                current = _walk_confined(
                    repo_root,
                    resolved_root,
                    current,
                    target.parts,
                    raw_path,
                    context,
                    remaining_symlinks=remaining_symlinks - 1,
                )
        else:
            current = candidate
        if not current.is_relative_to(resolved_root):
            raise ValueError(f"{context}: path escapes repository root ({raw_path!r})")
        if idx < len(parts) - 1 and current.exists() and not current.is_dir():
            raise ValueError(f"{context}: non-directory parent component in path ({raw_path!r})")
    return current


def resolve_repo_confined_path(
    repo_root: Path,
    raw_path: str,
    context: str,
    *,
    allow_root: bool = False,
) -> Path:
    if (
        not isinstance(raw_path, str)
        or not raw_path.strip()
        or raw_path != raw_path.strip()
        or "\x00" in raw_path
        or "\\" in raw_path
    ):
        raise ValueError(f"{context}: path must be repository-relative ({raw_path!r})")
    rel = Path(raw_path)
    if rel.is_absolute():
        raise ValueError(f"{context}: path must be repository-relative ({raw_path!r})")
    if allow_root and raw_path == ".":
        segments: list[str] = []
    else:
        segments = raw_path.split("/")
        if not segments or any(seg in {"", ".", ".."} for seg in segments):
            raise ValueError(f"{context}: path must be repository-relative ({raw_path!r})")
    try:
        resolved_root = repo_root.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ValueError(f"{context}: repository root does not exist ({repo_root!r})") from exc
    if not resolved_root.is_dir():
        raise ValueError(f"{context}: repository root is not a directory ({repo_root!r})")
    return _walk_confined(
        repo_root,
        resolved_root,
        resolved_root,
        tuple(segments),
        raw_path,
        context,
    )


def ensure_repo_file(repo_root: Path, raw_path: str, context: str) -> None:
    cleaned = strip_code(raw_path)
    if not cleaned:
        raise ValueError(f"{context}: empty file path")
    resolved = resolve_repo_confined_path(repo_root, cleaned, context, allow_root=False)
    if not resolved.is_file():
        raise ValueError(f"{context}: file does not exist ({cleaned!r})")


def parse_semicolon_paths(raw: str, context: str) -> list[str]:
    parts = [strip_code(part) for part in strip_code(raw).split(";")]
    paths = [part for part in parts if part]
    if not paths or len(paths) != len(parts) or any("`" in path for path in paths):
        raise ValueError(f"{context}: expected non-empty ';'-separated file list, got {raw!r}")
    if len(set(paths)) != len(paths):
        raise ValueError(f"{context}: duplicate path in {paths!r}")
    return paths


def parse_closing_pr_refs(raw: str, context: str) -> list[str]:
    parts = [strip_code(part) for part in re.split(r"[;,]", strip_code(raw))]
    tokens = [part for part in parts if part]
    normalized: list[str] = []
    for token in tokens:
        match = CLOSING_PR_TOKEN_RE.fullmatch(token) if "`" not in token else None
        if match is None:
            normalized = []
            break
        normalized.append(f"#{int(match.group(1))}")
    if not tokens or len(tokens) != len(parts) or len(normalized) != len(tokens):
        raise ValueError(
            f"{context}: COMPLETED row must specify concrete closing_pr PR reference "
            f"('#<positive_int>' or 'Th0rgal/orb#<positive_int>'), got {raw!r}"
        )
    if len(set(normalized)) != len(normalized):
        raise ValueError(f"{context}: duplicate closing_pr reference in {tokens!r}")
    return tokens


def parse_target_phases(raw: str, context: str) -> list[str]:
    tokens = [strip_code(part) for part in strip_code(raw).split(",")]
    if not tokens or any(not token for token in tokens):
        raise ValueError(f"{context}: empty target_phase {raw!r}")
    invalid = [token for token in tokens if token not in VALID_PHASES]
    if invalid:
        raise ValueError(f"{context}: invalid target_phase {invalid!r}; expected subset of R1..R8")
    if len(set(tokens)) != len(tokens):
        raise ValueError(f"{context}: duplicate phase in {tokens!r}")
    return tokens


def validate_inventory_markdown(
    markdown: str,
    repo_root: Path,
    *,
    require_all_completed: bool = False,
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    tables = parse_markdown_tables(markdown)
    sm_tables = [rows for header, rows in tables if header == SM_COLUMNS]
    if len(sm_tables) != 1:
        raise ValueError(
            f"expected exactly 1 SM inventory table with columns {SM_COLUMNS}, found {len(sm_tables)}"
        )
    gap_tables = [rows for header, rows in tables if header == GAP_COLUMNS]
    if len(gap_tables) != 1:
        raise ValueError(
            f"expected exactly 1 G-ORB cross-reference table with columns {GAP_COLUMNS}, found {len(gap_tables)}"
        )

    sm_rows = sm_tables[0]
    seen_sm_ids: list[str] = []
    for row in sm_rows:
        sm_id = strip_code(row["id"])
        seen_sm_ids.append(sm_id)
        for col in SM_COLUMNS:
            if not strip_code(row[col]):
                raise ValueError(f"{sm_id or '<missing-id>'}: column {col!r} must be non-empty")
        for file_path in parse_semicolon_paths(row["current_files"], f"{sm_id}.current_files"):
            ensure_repo_file(repo_root, file_path, f"{sm_id}.current_files")
        parse_target_phases(row["target_phase"], f"{sm_id}.target_phase")
        status = strip_code(row["status"])
        if status not in VALID_STATUSES:
            raise ValueError(f"{sm_id}.status: invalid status {status!r}")
        reproducer = strip_code(row["reproducer_or_gate"])
        if status == "COMPLETED":
            parse_closing_pr_refs(row["closing_pr"], sm_id)
            if reproducer.upper() == "TBD":
                raise ValueError(f"{sm_id}: COMPLETED row must specify concrete reproducer_or_gate")
            for gate_path in parse_semicolon_paths(row["reproducer_or_gate"], f"{sm_id}.reproducer_or_gate"):
                ensure_repo_file(repo_root, gate_path, f"{sm_id}.reproducer_or_gate")
        elif reproducer.upper() != "TBD":
            for gate_path in parse_semicolon_paths(row["reproducer_or_gate"], f"{sm_id}.reproducer_or_gate"):
                ensure_repo_file(repo_root, gate_path, f"{sm_id}.reproducer_or_gate")
        if require_all_completed and status != "COMPLETED":
            raise ValueError(f"{sm_id}: status is {status!r}, expected 'COMPLETED'")

    if len(seen_sm_ids) != len(set(seen_sm_ids)):
        duplicates = sorted({item for item in seen_sm_ids if seen_sm_ids.count(item) > 1})
        raise ValueError(f"duplicate SM IDs: {duplicates}")
    if seen_sm_ids != EXPECTED_SM_IDS:
        missing = [item for item in EXPECTED_SM_IDS if item not in seen_sm_ids]
        extra = [item for item in seen_sm_ids if item not in EXPECTED_SM_IDS]
        raise ValueError(
            f"SM inventory mismatch: missing={missing}, extra={extra}, order_ok={sorted(seen_sm_ids) == EXPECTED_SM_IDS}"
        )

    gap_rows = gap_tables[0]
    seen_gap_ids: list[str] = []
    valid_sm_set = set(EXPECTED_SM_IDS)
    for row in gap_rows:
        gap_id = strip_code(row["gap_id"])
        seen_gap_ids.append(gap_id)
        for col in GAP_COLUMNS:
            if not strip_code(row[col]):
                raise ValueError(f"{gap_id or '<missing-gap>'}: column {col!r} must be non-empty")
        for file_path in parse_semicolon_paths(row["current_files"], f"{gap_id}.current_files"):
            ensure_repo_file(repo_root, file_path, f"{gap_id}.current_files")
        linked = [strip_code(token) for token in strip_code(row["linked_sm_ids"]).split(",")]
        if not linked or any(token not in valid_sm_set for token in linked):
            raise ValueError(f"{gap_id}.linked_sm_ids: invalid SM references {linked!r}")
        if len(set(linked)) != len(linked):
            raise ValueError(f"{gap_id}.linked_sm_ids: duplicate SM references {linked!r}")
        parse_target_phases(row["target_phase"], f"{gap_id}.target_phase")
        status = strip_code(row["status"])
        if status not in VALID_STATUSES:
            raise ValueError(f"{gap_id}.status: invalid status {status!r}")
        if require_all_completed and status != "COMPLETED":
            raise ValueError(f"{gap_id}: status is {status!r}, expected 'COMPLETED'")

    if len(seen_gap_ids) != len(set(seen_gap_ids)):
        duplicates = sorted({item for item in seen_gap_ids if seen_gap_ids.count(item) > 1})
        raise ValueError(f"duplicate G-ORB IDs: {duplicates}")
    if seen_gap_ids != EXPECTED_GAP_IDS:
        missing = [item for item in EXPECTED_GAP_IDS if item not in seen_gap_ids]
        extra = [item for item in seen_gap_ids if item not in EXPECTED_GAP_IDS]
        raise ValueError(
            f"G-ORB table mismatch: missing={missing}, extra={extra}, order_ok={sorted(seen_gap_ids) == EXPECTED_GAP_IDS}"
        )

    return sm_rows, gap_rows


def validate_validation_matrix(matrix: dict[str, Any], repo_root: Path) -> list[dict[str, Any]]:
    if not isinstance(matrix, dict):
        raise ValueError("validation matrix root must be a TOML table")
    unknown_root = set(matrix) - MATRIX_KEYS
    if unknown_root:
        raise ValueError(f"unknown top-level validation.toml keys: {sorted(unknown_root)}")

    version = matrix.get("version", 1)
    if type(version) is not int or version != 1:
        raise ValueError(f"unsupported validation matrix version {version!r}")

    project = matrix.get("project")
    if not isinstance(project, str) or not project.strip():
        raise ValueError("matrix.project is required")

    profile = matrix.get("profile")
    if profile is not None and (not isinstance(profile, str) or not profile.strip()):
        raise ValueError("matrix.profile must be a non-empty string when set")

    gates = matrix.get("gates")
    if not isinstance(gates, list) or not gates:
        raise ValueError("matrix.gates must be a non-empty array of tables")

    by_id: dict[str, dict[str, Any]] = {}
    normalized: list[dict[str, Any]] = []
    for raw_gate in gates:
        if not isinstance(raw_gate, dict):
            raise ValueError("each [[gates]] entry must be a table")
        unknown_gate = set(raw_gate) - GATE_KEYS
        if unknown_gate:
            raise ValueError(f"unknown gate keys {sorted(unknown_gate)} in {raw_gate!r}")
        if "dependencies" in raw_gate and "depends_on" in raw_gate:
            raise ValueError("gate cannot specify both 'dependencies' and 'depends_on'")

        gate_id = raw_gate.get("id")
        if not isinstance(gate_id, str) or not GATE_ID_RE.fullmatch(gate_id):
            raise ValueError(f"invalid gate id {gate_id!r}")
        if gate_id in by_id:
            raise ValueError(f"duplicate gate id '{gate_id}'")

        command = raw_gate.get("command")
        if (
            not isinstance(command, list)
            or not command
            or not all(isinstance(arg, str) and arg and "\x00" not in arg for arg in command)
        ):
            raise ValueError(f"gate '{gate_id}' requires a safe, non-empty argv")

        description = raw_gate.get("description")
        if description is not None and not isinstance(description, str):
            raise ValueError(f"gate '{gate_id}' description must be a string")

        cwd = raw_gate.get("cwd")
        if cwd is not None:
            if not isinstance(cwd, str) or not cwd.strip():
                raise ValueError(f"gate '{gate_id}' cwd must be a non-empty string")
            resolved_cwd = resolve_repo_confined_path(
                repo_root,
                cwd,
                f"gate '{gate_id}' cwd",
                allow_root=True,
            )
            if not resolved_cwd.is_dir():
                raise ValueError(f"gate '{gate_id}' cwd must be an existing repo-relative directory")

        deps = raw_gate.get("dependencies", raw_gate.get("depends_on", []))
        if not isinstance(deps, list) or not all(isinstance(dep, str) for dep in deps):
            raise ValueError(f"gate '{gate_id}' dependencies must be a list of gate IDs")

        required = raw_gate.get("required", True)
        if type(required) is not bool:
            raise ValueError(f"gate '{gate_id}' required must be a boolean")

        mode = raw_gate.get("mode", "incremental")
        if not isinstance(mode, str) or mode not in VALID_MODES:
            raise ValueError(f"gate '{gate_id}' mode must be one of {sorted(VALID_MODES)}")

        reuse = raw_gate.get("reuse", True)
        if type(reuse) is not bool:
            raise ValueError(f"gate '{gate_id}' reuse must be a boolean")

        toolchain = raw_gate.get("toolchain")
        if toolchain is not None and (not isinstance(toolchain, str) or not toolchain.strip()):
            raise ValueError(f"gate '{gate_id}' toolchain must be a non-empty string")

        timeout_secs = raw_gate.get("timeout_secs")
        if timeout_secs is not None and (type(timeout_secs) is not int or timeout_secs <= 0):
            raise ValueError(f"gate '{gate_id}' timeout_secs must be a positive integer")

        artifacts = raw_gate.get("artifacts", [])
        if not isinstance(artifacts, list) or not all(
            isinstance(item, str) and item.strip() for item in artifacts
        ):
            raise ValueError(f"gate '{gate_id}' artifacts must be a list of non-empty strings")
        for artifact in artifacts:
            resolved_artifact = resolve_repo_confined_path(
                repo_root,
                artifact,
                f"gate '{gate_id}' artifact",
                allow_root=False,
            )
            if resolved_artifact.is_dir():
                raise ValueError(
                    f"gate '{gate_id}' artifact must not be an existing directory ({artifact!r})"
                )

        entry = {
            "id": gate_id,
            "command": command,
            "dependencies": deps,
            "required": required,
            "mode": mode,
            "reuse": reuse,
        }
        by_id[gate_id] = entry
        normalized.append(entry)

    for gate in normalized:
        gate_id = gate["id"]
        for dep in gate["dependencies"]:
            dep_gate = by_id.get(dep)
            if dep_gate is None or dep == gate_id:
                raise ValueError(f"gate '{gate_id}' has invalid dependency '{dep}'")
            if gate["required"] and not dep_gate["required"]:
                raise ValueError(f"required gate '{gate_id}' depends on optional gate '{dep}'")

    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(gate_id: str) -> None:
        if gate_id in visited:
            return
        if gate_id in visiting:
            raise ValueError(f"validation gate dependency cycle contains '{gate_id}'")
        visiting.add(gate_id)
        for dep in by_id[gate_id]["dependencies"]:
            visit(dep)
        visiting.remove(gate_id)
        visited.add(gate_id)

    for gate in normalized:
        visit(gate["id"])

    if not any(not gate["dependencies"] for gate in normalized):
        raise ValueError("validation matrix has no executable root wave")
    if not any(gate["required"] and gate["mode"] == "clean" for gate in normalized):
        raise ValueError("validation matrix must define at least one required clean certifying gate")

    return normalized


def check_repository(
    repo_root: Path = ROOT,
    *,
    inventory_path: Path | None = None,
    validation_path: Path | None = None,
    require_all_completed: bool = False,
) -> dict[str, int]:
    inv_file = inventory_path if inventory_path is not None else repo_root / DEFAULT_INVENTORY_REL
    val_file = validation_path if validation_path is not None else repo_root / DEFAULT_VALIDATION_REL

    if not inv_file.is_file():
        raise ValueError(f"missing inventory file: {inv_file}")
    if not val_file.is_file():
        raise ValueError(f"missing validation matrix file: {val_file}")

    sm_rows, gap_rows = validate_inventory_markdown(
        inv_file.read_text(encoding="utf-8"),
        repo_root,
        require_all_completed=require_all_completed,
    )
    with val_file.open("rb") as handle:
        matrix = tomllib.load(handle)
    gates = validate_validation_matrix(matrix, repo_root)

    completed = sum(1 for row in sm_rows if strip_code(row["status"]) == "COMPLETED")
    return {
        "sm_total": len(sm_rows),
        "sm_completed": completed,
        "gaps_total": len(gap_rows),
        "gates_total": len(gates),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=ROOT,
        help="Repository root directory (default: parent of scripts/).",
    )
    parser.add_argument(
        "--inventory",
        type=Path,
        default=None,
        help="Optional override path to state-machine-inventory.md.",
    )
    parser.add_argument(
        "--validation-toml",
        type=Path,
        default=None,
        help="Optional override path to .sandboxed/validation.toml.",
    )
    parser.add_argument(
        "--require-all-completed",
        action="store_true",
        help="Require every SM-01..SM-27 and G-ORB-1..G-ORB-8 row to have status COMPLETED.",
    )
    args = parser.parse_args(argv)
    try:
        summary = check_repository(
            args.repo_root,
            inventory_path=args.inventory,
            validation_path=args.validation_toml,
            require_all_completed=args.require_all_completed,
        )
    except (ValueError, OSError, tomllib.TOMLDecodeError) as error:
        sys.exit(f"State inventory check rejected: {error}")

    print(
        f"State inventory OK: {summary['sm_total']} SM rows "
        f"({summary['sm_completed']} completed), {summary['gaps_total']} G-ORB gaps, "
        f"{summary['gates_total']} validation gates."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
