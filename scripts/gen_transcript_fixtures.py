#!/usr/bin/env python3
"""Regenerate (or --check) shared/orb-spec/fixtures/transcript-gates.json from lean/Orb/Transcript.lean.

Builds the Lean project with turbo-lean (falls back to lake), then runs
scripts/gen_transcript_fixtures.lean against the built Orb.Transcript olean."""
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "shared/orb-spec/fixtures/transcript-gates.json"


def _fmt_bool(b: bool) -> str:
    return "true" if b else "false"


def _render_python_reference() -> str:
    key_batches = [
        [],
        [(0, 1), (1, 2), (0, 3)],
        [(1, 0), (1, 0), (1, 0)],
        [(0, 7), (1, 7), (0, 7), (2, 0), (1, 7)],
        [(3, 42), (3, 42), (0, 1), (3, 42)],
    ]
    latex_cases = [
        ("simple_inline", (5, False, False, False, False, False, False, False, True)),
        ("max_bound_exact", (8192, False, False, False, False, False, False, False, False)),
        ("over_max_bound", (8193, False, False, False, False, False, False, False, True)),
        ("empty_span", (0, False, False, False, False, False, False, False, False)),
        ("currency_pair_prose", (6, False, False, False, False, False, True, True, False)),
        ("digit_start_with_operator", (7, False, False, False, False, False, True, True, True)),
        ("digit_only_token", (2, False, False, False, False, False, True, False, False)),
        ("closing_followed_by_digit", (6, False, True, False, False, False, False, True, False)),
        ("escaped_or_alnum_prefix", (3, True, False, False, False, False, False, False, True)),
        ("leading_whitespace", (4, False, False, True, False, False, False, False, True)),
        ("trailing_whitespace", (4, False, False, False, True, False, False, False, True)),
        ("multiline_span", (8, False, False, False, False, True, False, False, True)),
    ]
    rows: list[str] = []
    for cs in key_batches:
        seen: set[tuple[int, int]] = set()
        next_gen = 1
        out = []
        for tag, item in cs:
            if (tag, item) in seen:
                out.append((tag, item, next_gen))
                next_gen += 1
            else:
                seen.add((tag, item))
                out.append((tag, item, 0))
        cand_s = "[" + ", ".join(f'{{"tag": {t}, "item": {i}}}' for t, i in cs) + "]"
        exp_s = "[" + ", ".join(f'{{"tag": {t}, "item": {i}, "gen": {g}}}' for t, i, g in out) + "]"
        rows.append(f'    {{"op": "allocTurnKeys", "candidates": {cand_s}, "expected": {exp_s}}}')

    for label, (ln, pb, nd, ls, ts, nl, fd, isp, mo) in latex_cases:
        ok = (
            0 < ln <= 8192
            and not pb
            and not nd
            and not ls
            and not ts
            and not nl
            and not (fd and isp and not mo)
        )
        rows.append(
            f'    {{"op": "latexSpanAdmitted", "name": "{label}", "len": {ln}, '
            f'"prevBlocked": {_fmt_bool(pb)}, "nextDigit": {_fmt_bool(nd)}, '
            f'"leadSpace": {_fmt_bool(ls)}, "trailSpace": {_fmt_bool(ts)}, '
            f'"hasNewline": {_fmt_bool(nl)}, "firstDigit": {_fmt_bool(fd)}, '
            f'"internalSpace": {_fmt_bool(isp)}, "hasMathOp": {_fmt_bool(mo)}, '
            f'"expected": {_fmt_bool(ok)}}}'
        )

    for total in (0, 10, 24, 25, 80, 481):
        for steps in (0, 1, 2, 5, 20):
            vis = min(total, 24 + steps * 24)
            hid = total - vis
            rows.append(
                f'    {{"op": "windowBudget", "total": {total}, "baseLimit": 24, '
                f'"expandedSteps": {steps}, "stepSize": 24, '
                f'"expectedVisible": {vis}, "expectedHidden": {hid}}}'
            )

    for cap in (0, 4, 8):
        for active in (0, 3, 4, 7, 8, 9):
            admitted = active < cap
            nxt = active + 1 if admitted else active
            rows.append(
                f'    {{"op": "admitMount", "active": {active}, "cap": {cap}, '
                f'"expectedAdmitted": {_fmt_bool(admitted)}, "expectedNextActive": {nxt}}}'
            )

    header = (
        "{\n"
        '  "description": "Generated from lean/Orb/Transcript.lean by scripts/gen_transcript_fixtures.py; do not edit. Cross-client transcript gates: injective turn-key allocation, Pandoc inline LaTeX delimiter admission, turn-window conservation, and active media/diagram mount budgets.",\n'
        '  "cases": [\n'
    )
    return header + ",\n".join(rows) + "\n  ]\n}\n"


def _render_lean() -> str:
    lean_dir = ROOT / "lean"
    if shutil.which("turbo-lean"):
        subprocess.run(["turbo-lean", "build", "--project-dir", str(lean_dir)], check=True, stdout=subprocess.DEVNULL)
    else:
        subprocess.run(["lake", "build"], cwd=lean_dir, check=True)
    lib = lean_dir / ".lake/build/lib/lean"
    prefix = subprocess.run(["lean", "--print-prefix"], capture_output=True, text=True, check=True).stdout.strip()
    env = dict(os.environ, LEAN_PATH=os.pathsep.join([str(lib), str(pathlib.Path(prefix) / "lib/lean")]))
    return subprocess.run(
        ["lean", "--run", str(ROOT / "scripts/gen_transcript_fixtures.lean")],
        capture_output=True,
        text=True,
        check=True,
        env=env,
    ).stdout


def main() -> int:
    out = _render_python_reference() if "--bootstrap-python" in sys.argv else _render_lean()
    if "--check" in sys.argv:
        if not OUT.is_file() or OUT.read_text() != out:
            print(f"{OUT.relative_to(ROOT)} is stale: run python3 scripts/gen_transcript_fixtures.py", file=sys.stderr)
            return 1
        print(f"{OUT.relative_to(ROOT)} up to date")
        return 0
    OUT.write_text(out)
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
