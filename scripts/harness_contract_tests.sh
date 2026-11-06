#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== Harness contract tests: building pure-Lean sandboxed-sh =="
./scripts/build_orb_bins.sh --ensure-lean --out-dir target/debug --only sandboxed-sh

echo "== Harness contract tests: shared CLI, OpenCode SSE, event parser & native Vibe ACP =="
./target/debug/sandboxed-sh --harness-contract-tests

echo "== Harness contract tests: Python Vibe ACP bridge =="
python3 -m unittest discover -s tests -p test_vibe_bridge.py

echo "Harness contract tests passed."
