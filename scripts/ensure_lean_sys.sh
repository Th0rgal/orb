#!/usr/bin/env bash
# Materialize the pinned `lean-sys` package before an offline-aware builder runs.
#
# turbo-lean validates a package in a sandbox that forbids network transport, so
# Lake cannot fetch `lean-sys` itself there (`fatal: transport 'https' not allowed`).
# Seeding `.lake/packages/lean-sys` from a local checkout (or one pinned clone)
# keeps turbo-lean's Lake materialization offline and deterministic.
#
# Usage: source this file, then call `ensure_lean_sys_pkg <package-dir> <repo-root>`.
set -euo pipefail

ensure_lean_sys_pkg() {
  local pkg_parent="$1"
  local root_dir="${2:-$pkg_parent}"
  local manifest="$pkg_parent/lake-manifest.json"
  local pkg_dir="$pkg_parent/.lake/packages/lean-sys"
  if [[ -f "$pkg_dir/lakefile.lean" ]]; then
    return 0
  fi
  if [[ ! -f "$manifest" ]]; then
    return 0
  fi
  local rev
  rev="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(next((p.get("rev","") for p in m.get("packages",[]) if p.get("name","").strip("«»")=="lean-sys"), ""))' "$manifest" 2>/dev/null || true)"
  if [[ -z "$rev" ]]; then
    return 0
  fi
  mkdir -p "$pkg_parent/.lake/packages"
  rm -rf "$pkg_dir"
  local common_root=""
  if command -v git >/dev/null 2>&1; then
    local git_common
    git_common="$(git -C "$root_dir" rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$git_common" ]]; then
      common_root="$(cd "$root_dir" && cd "$git_common/.." 2>/dev/null && pwd || true)"
    fi
  fi
  local seed=""
  local cand
  for cand in \
    "$root_dir/lean/.lake/packages/lean-sys" \
    "$root_dir/lean/OrbBin/.lake/packages/lean-sys" \
    "$root_dir/lean/OrbNode/.lake/packages/lean-sys" \
    "$root_dir/lean/OrbCore/.lake/packages/lean-sys" \
    "$root_dir/lean/OrbLocald/.lake/packages/lean-sys" \
    "$root_dir/lean/OrbNetLeaf/.lake/packages/lean-sys" \
    "${common_root:+$common_root/lean/.lake/packages/lean-sys}" \
    "${common_root:+$common_root/lean/OrbCore/.lake/packages/lean-sys}"; do
    if [[ -n "$cand" && -d "$cand/.git" ]]; then
      seed="$cand"
      break
    fi
  done
  if [[ -n "$seed" ]]; then
    git clone --quiet "$seed" "$pkg_dir"
  else
    git clone --quiet https://github.com/Th0rgal/lean-sys.git "$pkg_dir"
  fi
  (cd "$pkg_dir" && git checkout --quiet "$rev")
}
