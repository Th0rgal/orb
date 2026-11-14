#!/usr/bin/env bash
# One compatibility boundary for fleet binaries and the pinned CI release.
set -euo pipefail
export TURBO_LEAN_TELEMETRY=off LEAN_NATIVE_TELEMETRY=off
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-1}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-2}"
cli="${TURBO_LEAN_CLI:-turbo-lean}"
help="$("$cli" --help)"
flags=()
for flag in --no-telemetry; do
  if [[ "$help" == *"$flag"* ]]; then flags+=("$flag"); fi
done
# This flag means read-only Lake recipes in the pinned builder; native builds
# need writable C recipes. Enable it only for callers using prebuilt overlays.
if [[ "${TURBO_LEAN_NO_AUTO_WORKTREE_LINK:-0}" == "1" && "$help" == *--no-auto-worktree-link* ]]; then
  flags+=(--no-auto-worktree-link)
fi
if [[ "${TURBO_LEAN_NO_DAEMON:-${CI:-0}}" =~ ^(1|true)$ && "$help" == *--no-daemon* ]]; then
  flags+=(--no-daemon)
fi
exec "$cli" "${flags[@]}" "$@"
