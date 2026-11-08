#!/usr/bin/env bash
# Build all native Lean 4 binaries (`lean/OrbBin`, `lean/OrbNode`, `lean/OrbCore`, `lean/OrbLocald`)
# and stage them into `--out-dir <dir>` (repeatable) or by default into
# `target/debug` and `target/release` directories.
#
# Usage:
#   ./scripts/build_orb_bins.sh [--ensure-lean] [--with-tests] [--out-dir <dir>]... [--only <bin>]...
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENSURE_LEAN=0
WITH_TESTS=0
OUT_DIRS=()
ONLY_BINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ensure-lean)
      ENSURE_LEAN=1
      shift
      ;;
    --with-tests)
      WITH_TESTS=1
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

if [[ "$(uname -s)" == "Darwin" ]]; then
  for ossl_dir in "/opt/homebrew/opt/openssl@3" "/usr/local/opt/openssl@3"; do
    if [[ -d "$ossl_dir/include" && -d "$ossl_dir/lib" ]]; then
      export CPATH="${CPATH:+$CPATH:}$ossl_dir/include"
      export LIBRARY_PATH="${LIBRARY_PATH:+$LIBRARY_PATH:}$ossl_dir/lib"
      break
    fi
  done
fi

if ! command -v lake >/dev/null 2>&1; then
  if [[ "$ENSURE_LEAN" == "1" ]]; then
    os_name="$(uname -s)"
    arch_name="$(uname -m)"
    lean_dest="${HOME:-/tmp}/.local/lean-4.35.0"
    if [[ ! -x "$lean_dest/bin/lake" ]]; then
      if [[ "$os_name" == "Linux" && "$arch_name" == "x86_64" ]]; then
        lean_url="https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-linux.tar.zst"
        lean_sha256="7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d"
        lean_ext=".tar.zst"
      elif [[ "$os_name" == "Darwin" && "$arch_name" == "arm64" ]]; then
        lean_url="https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-darwin_aarch64.tar.zst"
        lean_sha256="c0c6f34f35ba1dcc5c4a5fd106fefab9eb5e8469712624dd2c868d51b63177c2"
        lean_ext=".tar.zst"
      elif [[ "$os_name" == "Darwin" && "$arch_name" == "x86_64" ]]; then
        lean_url="https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-darwin.tar.zst"
        lean_sha256="0b43be5c7ecfb36016566a41005ab62bdb04743e6bfd5837e45f796ef4750b4e"
        lean_ext=".tar.zst"
      else
        echo "error: --ensure-lean automatic bootstrap unsupported on $os_name/$arch_name" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$lean_dest")"
      lean_archive="$(mktemp "/tmp/lean-4.35.0-XXXXXX${lean_ext}")"
      lean_stage="$(mktemp -d "${lean_dest}.stage.XXXXXX")"
      cleanup_bootstrap() {
        rm -f "$lean_archive"
        rm -rf "$lean_stage"
      }
      trap cleanup_bootstrap EXIT
      curl --retry 5 --retry-all-errors -fsSL "$lean_url" -o "$lean_archive"
      if command -v sha256sum >/dev/null 2>&1; then
        echo "${lean_sha256}  ${lean_archive}" | sha256sum -c -
      else
        echo "${lean_sha256}  ${lean_archive}" | shasum -a 256 -c -
      fi
      tar --zstd -xf "$lean_archive" --strip-components=1 -C "$lean_stage"
      rm -rf "$lean_dest"
      mv "$lean_stage" "$lean_dest"
      rm -f "$lean_archive"
      trap - EXIT
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
  "sandboxed-node"
  "sandboxed-sh"
  "orb-locald"
)

if [[ ${#ONLY_BINS[@]} -gt 0 ]]; then
  BINS_TO_STAGE=("${ONLY_BINS[@]}")
else
  BINS_TO_STAGE=("${ALL_BINS[@]}")
fi

ORB_BIN_TARGETS=()
ORB_NODE_TARGETS=()
ORB_CORE_TARGETS=()
ORB_LOCALD_TARGETS=()
for bin in "${BINS_TO_STAGE[@]}"; do
  if [[ "$bin" == "sandboxed-node" ]]; then
    ORB_NODE_TARGETS+=("orb-node")
  elif [[ "$bin" == "orb-node-test" ]]; then
    ORB_NODE_TARGETS+=("orb-node-test")
  elif [[ "$bin" == "sandboxed-sh" || "$bin" == "orb-core-test" || "$bin" == "orb-spec-runner" ]]; then
    ORB_CORE_TARGETS+=("$bin")
  elif [[ "$bin" == "orb-locald" || "$bin" == "orb-locald-test" ]]; then
    ORB_LOCALD_TARGETS+=("$bin")
  elif [[ "$bin" == "lean-mesh" ]]; then
    ORB_BIN_TARGETS+=("lean-mesh-cli")
  else
    ORB_BIN_TARGETS+=("$bin")
  fi
done

ensure_lean_sys_pkg() {
  local pkg_parent="$1"
  local manifest="$pkg_parent/lake-manifest.json"
  local pkg_dir="$pkg_parent/.lake/packages/lean-sys"
  if [[ -f "$pkg_dir/lakefile.lean" ]]; then
    return 0
  fi
  if [[ ! -f "$manifest" ]]; then
    return 0
  fi
  local rev
  rev="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(next((p.get("rev","") for p in m.get("packages",[]) if p.get("name")=="lean-sys"), ""))' "$manifest" 2>/dev/null || true)"
  if [[ -z "$rev" ]]; then
    return 0
  fi
  mkdir -p "$pkg_parent/.lake/packages"
  rm -rf "$pkg_dir"
  local seed=""
  for cand in "$ROOT_DIR/lean/.lake/packages/lean-sys" "$ROOT_DIR/lean/OrbCore/.lake/packages/lean-sys"; do
    if [[ -d "$cand/.git" ]]; then
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

run_lean_pkg_build() {
  local pkg_dir="$1"
  shift
  ensure_lean_sys_pkg "$pkg_dir"
  (
    cd "$pkg_dir"
    if [[ "${ORB_SKIP_TURBO_LEAN:-0}" != "1" ]] && command -v turbo-lean >/dev/null 2>&1; then
      turbo-lean build --max-memory-mb "${ORB_TURBO_LEAN_MAX_MB:-6144}" || true
    fi
    SANDBOXED_ALLOW_RAW_LAKE=1 lake build "$@" -- -DwarningAsError=true
  )
}

if [[ ${#ORB_BIN_TARGETS[@]} -gt 0 ]]; then
  run_lean_pkg_build "$ROOT_DIR/lean/OrbBin" "${ORB_BIN_TARGETS[@]}"
fi

if [[ ${#ORB_NODE_TARGETS[@]} -gt 0 ]]; then
  run_lean_pkg_build "$ROOT_DIR/lean/OrbNode" "${ORB_NODE_TARGETS[@]}"
fi

if [[ ${#ORB_CORE_TARGETS[@]} -gt 0 ]]; then
  run_lean_pkg_build "$ROOT_DIR/lean/OrbCore" "${ORB_CORE_TARGETS[@]}"
fi

if [[ ${#ORB_LOCALD_TARGETS[@]} -gt 0 ]]; then
  run_lean_pkg_build "$ROOT_DIR/lean/OrbLocald" "${ORB_LOCALD_TARGETS[@]}"
fi

if [[ ${#OUT_DIRS[@]} -eq 0 ]]; then
  target_base="${CARGO_TARGET_DIR:-$ROOT_DIR/target}"
  OUT_DIRS=("$target_base/debug" "$target_base/release")
fi

LAKE_BIN_DIR="$ROOT_DIR/lean/OrbBin/.lake/build/bin"
LAKE_NODE_BIN_DIR="$ROOT_DIR/lean/OrbNode/.lake/build/bin"
LAKE_CORE_BIN_DIR="$ROOT_DIR/lean/OrbCore/.lake/build/bin"
LAKE_LOCALD_BIN_DIR="$ROOT_DIR/lean/OrbLocald/.lake/build/bin"
for out_dir in "${OUT_DIRS[@]}"; do
  mkdir -p "$out_dir"
  for bin in "${BINS_TO_STAGE[@]}"; do
    if [[ "$bin" == "sandboxed-node" || "$bin" == "orb-node-test" ]]; then
      src="$LAKE_NODE_BIN_DIR/$bin"
    elif [[ "$bin" == "sandboxed-sh" || "$bin" == "orb-core-test" || "$bin" == "orb-spec-runner" ]]; then
      src="$LAKE_CORE_BIN_DIR/$bin"
    elif [[ "$bin" == "orb-locald" || "$bin" == "orb-locald-test" ]]; then
      src="$LAKE_LOCALD_BIN_DIR/$bin"
    else
      src="$LAKE_BIN_DIR/$bin"
    fi
    if [[ ! -x "$src" ]]; then
      echo "error: expected built binary missing at $src" >&2
      exit 1
    fi
    elab_syms="$(nm -u "$src" 2>/dev/null | grep -c lean_elab || true)"
    if [[ "$elab_syms" -ne 0 ]]; then
      echo "error: production binary $src links lean_elab ($elab_syms symbols)" >&2
      exit 1
    fi
    install -m 0755 "$src" "$out_dir/$bin"
  done
done

if [[ "$WITH_TESTS" == "1" ]]; then
  (cd "$ROOT_DIR/lean/OrbNetLeaf" && SANDBOXED_ALLOW_RAW_LAKE=1 lake build -- -DwarningAsError=true && ./.lake/build/bin/orb-net-leaf-test)
  (cd "$ROOT_DIR/lean/OrbBin" && SANDBOXED_ALLOW_RAW_LAKE=1 lake build orb-bin-test -- -DwarningAsError=true && ./.lake/build/bin/orb-bin-test)
  (cd "$ROOT_DIR/lean/OrbNode" && SANDBOXED_ALLOW_RAW_LAKE=1 lake build orb-node-test -- -DwarningAsError=true && ./.lake/build/bin/orb-node-test)
  (cd "$ROOT_DIR/lean/OrbClient" && SANDBOXED_ALLOW_RAW_LAKE=1 lake build -- -DwarningAsError=true && ./.lake/build/bin/orb-client-test)
  (cd "$ROOT_DIR/lean/OrbCore" && SANDBOXED_ALLOW_RAW_LAKE=1 lake build orb-core-test orb-spec-runner -- -DwarningAsError=true)
  "$ROOT_DIR/lean/OrbCore/.lake/build/bin/orb-core-test"
  "$ROOT_DIR/lean/OrbCore/.lake/build/bin/orb-spec-runner" --fixtures "$ROOT_DIR/shared/orb-spec/fixtures"
  (cd "$ROOT_DIR/lean/OrbLocald" && SANDBOXED_ALLOW_RAW_LAKE=1 lake build orb-locald-test -- -DwarningAsError=true && ./.lake/build/bin/orb-locald-test)
fi
