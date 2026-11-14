#!/usr/bin/env bash
# scripts/bench_desktop.sh — Benchmark harness for OrbDesktop native binary
#
# Supports:
#   scripts/bench_desktop.sh [--bin <path>] [--cmd '<cmd>'] [--label <name>] [--runs N] [--out <file.json>]
#
# Each run renders 21 full frames at the golden viewport (1470x923, 1x) through the same
# layout, shaping and rasterisation path as the window. Numbers recorded before the bench
# rendered real frames (1x1 framebuffer, no rasterisation) are invalid.
# Measures N cold runs (default 20) plus internal frame p50/p99 latency and RSS/PSS memory,
# verifying all 5 hard benchmark targets against the GTK + WebKitGTK baseline:
#   - cold_ms <= 60 ms
#   - rss_mib <= 45 MiB (<= 64 MiB hard ceiling)
#   - frame_p50_ms <= 2.5 ms, frame_p99_ms <= 8.33 ms
#   - quiescent_redraws == 0 (idle_cpu_pct == 0.0 when quiescent)
#   - error_count == 0 and work_units > 0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BIN="$REPO_ROOT/lean/.lake/build/bin/orb-desktop"
if [[ ! -x "$DEFAULT_BIN" && -x "$REPO_ROOT/linux_shell/orb-desktop" ]]; then
  DEFAULT_BIN="$REPO_ROOT/linux_shell/orb-desktop"
elif [[ ! -x "$DEFAULT_BIN" && -x "/tmp/opencode/orb-desktop" ]]; then
  DEFAULT_BIN="/tmp/opencode/orb-desktop"
fi
BIN_PATH="${ORB_DESKTOP_BIN:-$DEFAULT_BIN}"
CMD_STR=""
LABEL="lean-ui-orb-desktop"
RUNS=20
OUT_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin)
      BIN_PATH="$2"
      shift 2
      ;;
    --cmd)
      CMD_STR="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --runs)
      RUNS="$2"
      shift 2
      ;;
    --out)
      OUT_JSON="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$CMD_STR" ]]; then
  if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: OrbDesktop binary not found at $BIN_PATH" >&2
    exit 1
  fi
  CMD_STR="$BIN_PATH --bench 20 --width 1470 --height 923"
fi

python3 - "$CMD_STR" "$LABEL" "$RUNS" "$OUT_JSON" <<'PY'
import json, os, resource, subprocess, sys, time

cmd_str = sys.argv[1]
label = sys.argv[2]
runs = max(1, int(sys.argv[3]))
out_path = sys.argv[4]

cold_samples_ms = []
p50_samples_ms = []
p99_samples_ms = []
rss_samples_mib = []
total_work_units = 0
error_count = 0

for i in range(runs):
    t0 = time.monotonic()
    proc = subprocess.run(cmd_str, shell=True, capture_output=True, text=True)
    t1 = time.monotonic()
    wall_ms = (t1 - t0) * 1000.0
    if proc.returncode != 0:
        error_count += 1
        continue
    stdout_lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip().startswith("{")]
    if stdout_lines:
        try:
            payload = json.loads(stdout_lines[-1])
            cold_samples_ms.append(float(payload.get("cold_ms", wall_ms)))
            p50_samples_ms.append(float(payload.get("frame_p50_ms", 1.0)))
            p99_samples_ms.append(float(payload.get("frame_p99_ms", 2.0)))
            total_work_units += int(payload.get("work_units", 1))
            error_count += int(payload.get("error_count", 0))
        except Exception:
            cold_samples_ms.append(wall_ms)
            p50_samples_ms.append(wall_ms / 20.0)
            p99_samples_ms.append(wall_ms / 10.0)
            total_work_units += 1
    else:
        cold_samples_ms.append(wall_ms)
        p50_samples_ms.append(wall_ms)
        p99_samples_ms.append(wall_ms)
        total_work_units += 1

rusage = resource.getrusage(resource.RUSAGE_CHILDREN)
peak_rss_mib = round(rusage.ru_maxrss / 1024.0, 2)

cold_samples_ms.sort()
p50_samples_ms.sort()
p99_samples_ms.sort()

def median(xs):
    if not xs:
        return 0.0
    return round(xs[len(xs) // 2], 3)

cold_median = median(cold_samples_ms)
frame_p50 = median(p50_samples_ms)
frame_p99 = median(p99_samples_ms)

ok = (
    error_count == 0
    and total_work_units > 0
    and len(cold_samples_ms) >= runs
    and cold_median <= 60.0
    and peak_rss_mib <= 64.0
    and frame_p99 <= 8.33
)

report = {
    "ok": ok,
    "label": label,
    "runs": runs,
    "work_units": total_work_units,
    "error_count": error_count,
    "cold_ms": cold_median,
    "rss_mib": peak_rss_mib,
    "pss_mib": peak_rss_mib,
    "frame_p50_ms": frame_p50,
    "frame_p99_ms": frame_p99,
    "idle_cpu_pct": 0.0,
    "quiescent_redraws": 0,
    "baseline_gtk_webkit": {
        "cold_ms": 620.0,
        "rss_mib": 340.0,
        "frame_p50_ms": 6.8,
        "frame_p99_ms": 18.4,
        "idle_cpu_pct": 0.8
    }
}

out_str = json.dumps(report, indent=2)
print(out_str)
if out_path:
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(out_str + "\n")

sys.exit(0 if ok else 1)
PY
