#!/usr/bin/env python3
"""Unit tests for scripts/lint_kernel_calls.py (including Lean `try ... finally` + `IO.Promise` rules)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lint_kernel_calls as lkc  # noqa: E402


class LintLeanHygieneTests(unittest.TestCase):
    def test_catches_let_mut_read_inside_finally(self) -> None:
        buggy = """\
def runWorker : IO Unit := do
  let mut streams : Array Nat := #[]
  let mut fatalErr? : Option String := none
  try
    streams := streams.push 1
    fatalErr? := some "eof"
  finally
    let msg := fatalErr?.getD "closed"
    drainAll streams msg
"""
        findings = lkc.lint_lean("lean/Example.lean", buggy)
        rules = [(f.line, f.rule) for f in findings]
        self.assertIn((8, "lean-finally-let-mut"), rules)
        self.assertIn((9, "lean-finally-let-mut"), rules)

    def test_allows_io_ref_across_try_finally_and_local_mut_inside_finally(self) -> None:
        clean = """\
def runWorker : IO Unit := do
  let streamsRef ← IO.mkRef (#[] : Array Nat)
  try
    streamsRef.modify (·.push 1)
  finally
    let cur ← streamsRef.get
    let mut idx := 0
    idx := idx + cur.size
    pure ()
"""
        self.assertEqual(lkc.lint_lean("lean/Example.lean", clean), [])

    def test_catches_promise_result_bang_and_ignores_comments(self) -> None:
        src = """\
-- Note: never call prom.result!.get
/- Nested /- prom.result! -/ comment -/
def waitSafe (p : IO.Promise Nat) : IO (Option Nat) := do
  let ok := p.result?.get
  let bad := p.result!.get
  return ok.orElse (fun _ => some bad)
"""
        findings = lkc.lint_lean("lean/Example.lean", src)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].line, 5)
        self.assertEqual(findings[0].rule, "lean-promise-result-bang")

    def test_repo_is_clean(self) -> None:
        self.assertEqual(lkc.lint_repo(), [])


if __name__ == "__main__":
    unittest.main()
