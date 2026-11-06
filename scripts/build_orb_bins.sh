#!/usr/bin/env bash
# Build all Wave 1 native Lean 4 companion binaries (`lean/OrbBin`) and stage
# them into `--out-dir <dir>` (repeatable) or by default into Cargo's
# `target/debug` and `target/release` directories.
#
# Usage:
#   ./scripts/build_orb_bins.sh [--ensure-lean] [--out-dir <dir>]... [--only <bin>]...
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENSURE_LEAN=0
OUT_DIRS=()
ONLY_BINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ensure-lean)
      ENSURE_LEAN=1
      shift
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || { echo "error: --out-dir requires an argument" >&2; exit 2; }
      OUT_DIRS+=("$2")
      shift 2
      ;;
    --only)
      [[ $# -ge 2 ]] || { echo "error: --only requires a binary name" >&2; exit 2; }
      ONLY_BINS+=("$2")
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Discover `lake` on common toolchain paths before optionally bootstrapping.
for candidate_dir in \
  "${LEAN_BIN_DIR:-}" \
  "$HOME/.local/lean-4.35.0/bin" \
  "/opt/lean-4.35.0/bin" \
  "$HOME/.elan/bin" \
  "/root/.local/lean-4.35.0/bin" \
  "/root/.elan/bin"
do
  if [[ -n "$candidate_dir" && -x "$candidate_dir/lake" ]]; then
    export PATH="$candidate_dir:$PATH"
    break
  fi
done

if ! command -v lake >/dev/null 2>&1; then
  if [[ "$ENSURE_LEAN" == "1" ]]; then
    os_name="$(uname -s)"
    arch_name="$(uname -m)"
    if [[ "$os_name" != "Linux" || "$arch_name" != "x86_64" ]]; then
      echo "error: --ensure-lean automatic bootstrap only supports Linux x86_64 (got $os_name/$arch_name)" >&2
      exit 1
    fi
    lean_dest="${HOME:-/tmp}/.local/lean-4.35.0"
    if [[ ! -x "$lean_dest/bin/lake" ]]; then
      lean_archive="$(mktemp /tmp/lean-4.35.0-XXXXXX.tar.zst)"
      lean_sha256="7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d"
      curl --retry 5 --retry-all-errors -fsSL \
        "https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-linux.tar.zst" \
        -o "$lean_archive"
      echo "${lean_sha256}  ${lean_archive}" | sha256sum -c -
      mkdir -p "$lean_dest"
      tar --zstd -xf "$lean_archive" --strip-components=1 -C "$lean_dest"
      rm -f "$lean_archive"
    fi
    export PATH="$lean_dest/bin:$PATH"
  else
    echo "error: Lean 4 'lake' not found on PATH (pass --ensure-lean to bootstrap v4.35.0)" >&2
    exit 1
  fi
fi

ALL_BINS=(
  "fido-agent-proxy"
  "orb-privd"
  "orb-sudo"
  "lean-mesh"
  "palomactl"
  "sandboxed-mcp"
  "workspace-mcp"
  "desktop-mcp"
  "automation-manager-mcp"
)

if [[ ${#ONLY_BINS[@]} -gt 0 ]]; then
  BINS_TO_STAGE=("${ONLY_BINS[@]}")
else
  BINS_TO_STAGE=("${ALL_BINS[@]}")
fi

BUILD_TARGETS=()
for bin in "${BINS_TO_STAGE[@]}"; do
  if [[ "$bin" == "lean-mesh" ]]; then
    BUILD_TARGETS+=("lean-mesh-cli")
  else
    BUILD_TARGETS+=("$bin")
  fi
done

(
  cd "$ROOT_DIR/lean/OrbBin"
  SANDBOXED_ALLOW_RAW_LAKE=1 lake build "${BUILD_TARGETS[@]}" -- -DwarningAsError=true
)

if [[ ${#OUT_DIRS[@]} -eq 0 ]]; then
  target_base="${CARGO_TARGET_DIR:-$ROOT_DIR/target}"
  OUT_DIRS=("$target_base/debug" "$target_base/release")
fi

LAKE_BIN_DIR="$ROOT_DIR/lean/OrbBin/.lake/build/bin"
for out_dir in "${OUT_DIRS[@]}"; do
  mkdir -p "$out_dir"
  for bin in "${BINS_TO_STAGE[@]}"; do
    src="$LAKE_BIN_DIR/$bin"
    if [[ ! -x "$src" ]]; then
      echo "error: expected built binary missing at $src" >&2
      exit 1
    fi
    install -m 0755 "$src" "$out_dir/$bin"
  done
done
