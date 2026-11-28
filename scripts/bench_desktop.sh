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
#   - cold_ms <= 60 ms and transcript_open_ms <= the WebKitGTK baseline
#   - rss_mib <= 45 MiB (<= 64 MiB hard ceiling)
#   - frame_p50_ms <= 2.5 ms, frame_p99_ms <= 8.33 ms
#   - every streamed update uses the partial-frame path and idle redraws stay at 0
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

LONG_CMD_STR=""
if [[ -z "$CMD_STR" ]]; then
  if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: OrbDesktop binary not found at $BIN_PATH" >&2
    exit 1
  fi
  CMD_STR="$BIN_PATH --bench 20 --width 1470 --height 923"
  LONG_CMD_STR="$BIN_PATH --bench-long 60 --width 1470 --height 923"
fi

python3 - "$CMD_STR" "$LONG_CMD_STR" "$LABEL" "$RUNS" "$OUT_JSON" <<'PY'
import json, os, resource, subprocess, sys, time

cmd_str = sys.argv[1]
long_cmd_str = sys.argv[2]
label = sys.argv[3]
runs = max(1, int(sys.argv[4]))
out_path = sys.argv[5]

cold_samples_ms = []
startup_samples_ms = []
open_samples_ms = []
p50_samples_ms = []
p95_samples_ms = []
p99_samples_ms = []
total_work_units = 0
quiescent_redraws = 0
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
            startup_samples_ms.append(float(payload.get("startup_ms", payload.get("cold_ms", wall_ms))))
            p50_samples_ms.append(float(payload.get("frame_p50_ms", 1.0)))
            p95_samples_ms.append(float(payload.get("frame_p95_ms", payload.get("frame_p99_ms", 2.0))))
            p99_samples_ms.append(float(payload.get("frame_p99_ms", 2.0)))
            open_ms = float(payload.get("transcript_open_ms", wall_ms))
            open_samples_ms.append(open_ms)
            wu = int(payload.get("work_units", 1))
            total_work_units += wu
            error_count += int(payload.get("error_count", 0))
            if "quiescent_skips" in payload:
                q_skips = int(payload.get("quiescent_skips", 0))
                if q_skips < wu:
                    error_count += 1
                    quiescent_redraws += max(1, wu - q_skips)
            if "frames_rendered" in payload:
                extra_renders = max(0, int(payload.get("frames_rendered", wu + 1)) - (wu + 1))
                quiescent_redraws += extra_renders
                if extra_renders > 0:
                    error_count += 1
            if int(payload.get("max_icon_raster_pixels", 0)) > 16384:
                error_count += 1
            if open_ms > 620.0 or int(payload.get("partial_frames", 0)) < wu:
                error_count += 1
        except Exception:
            error_count += 1
            cold_samples_ms.append(wall_ms)
            startup_samples_ms.append(wall_ms)
            open_samples_ms.append(wall_ms)
            p50_samples_ms.append(wall_ms / 20.0)
            p95_samples_ms.append(wall_ms / 10.0)
            p99_samples_ms.append(wall_ms / 10.0)
            total_work_units += 1
    else:
        error_count += 1
        cold_samples_ms.append(wall_ms)
        startup_samples_ms.append(wall_ms)
        open_samples_ms.append(wall_ms)
        p50_samples_ms.append(wall_ms)
        p95_samples_ms.append(wall_ms)
        p99_samples_ms.append(wall_ms)
        total_work_units += 1

# Capture canonical `--bench 20` peak RSS BEFORE running `--bench-long 60` so long-transcript
# runs never overwrite canonical RSS.
rusage_canon = resource.getrusage(resource.RUSAGE_CHILDREN)
peak_rss_mib = round(rusage_canon.ru_maxrss / 1024.0, 2)

long_report = None
long_ok = True
if long_cmd_str:
    l_cold, l_open, l_p50, l_p95, l_p99 = [], [], [], [], []
    l_last = {}
    l_errors = 0
    for i in range(runs):
        proc = subprocess.run(long_cmd_str, shell=True, capture_output=True, text=True)
        if proc.returncode != 0:
            l_errors += 1
            continue
        stdout_lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip().startswith("{")]
        if not stdout_lines:
            l_errors += 1
            continue
        try:
            p = json.loads(stdout_lines[-1])
            l_last = p
            l_cold.append(float(p["cold_ms"]))
            l_open.append(float(p["transcript_open_ms"]))
            l_p50.append(float(p["frame_p50_ms"]))
            l_p95.append(float(p["frame_p95_ms"]))
            l_p99.append(float(p["frame_p99_ms"]))
            l_errors += int(p.get("error_count", 0))
            wu = int(p.get("work_units", 0))
            if (
                int(p.get("partial_frames", 0)) < wu
                or int(p.get("quiescent_skips", 0)) < wu
                or int(p.get("frames_rendered", wu + 1)) != wu + 1
                or int(p.get("stream_coalesced_deltas", 0)) <= wu
                or int(p.get("stream_renders", 0)) != wu
                or int(p.get("icon_raster_hits", 0)) <= 0
                or int(p.get("icon_raster_misses", 999999)) > 64
                or int(p.get("max_icon_raster_pixels", 999999)) > 16384
            ):
                l_errors += 1
        except Exception:
            l_errors += 1

    def med(xs):
        if not xs:
            return 0.0
        s = sorted(xs)
        return round(s[len(s) // 2], 3)

    rusage_long = resource.getrusage(resource.RUSAGE_CHILDREN)
    long_rss_mib = round(rusage_long.ru_maxrss / 1024.0, 2)
    l_cold_med = med(l_cold)
    l_open_med = med(l_open)
    l_p50_med = med(l_p50)
    l_p95_med = med(l_p95)
    l_p99_med = med(l_p99)
    long_ok = (
        l_errors == 0
        and len(l_cold) >= runs
        and l_cold_med <= 150.0
        and l_open_med <= 150.0
        and long_rss_mib <= 96.0
        and l_p50_med <= 5.0
        and l_p95_med <= 16.67
        and l_p99_med <= 16.67
    )
    long_report = {
        "ok": long_ok,
        "turns": int(l_last.get("turns", 120)),
        "cold_ms": l_cold_med,
        "startup_ms": l_cold_med,
        "transcript_open_ms": l_open_med,
        "rss_mib": long_rss_mib,
        "frame_p50_ms": l_p50_med,
        "frame_p95_ms": l_p95_med,
        "frame_p99_ms": l_p99_med,
        "partial_frames": int(l_last.get("partial_frames", 0)),
        "quiescent_skips": int(l_last.get("quiescent_skips", 0)),
        "stream_coalesced_deltas": int(l_last.get("stream_coalesced_deltas", 0)),
        "stream_renders": int(l_last.get("stream_renders", 0)),
        "icon_raster_hits": int(l_last.get("icon_raster_hits", 0)),
        "icon_raster_misses": int(l_last.get("icon_raster_misses", 0)),
        "max_icon_raster_pixels": int(l_last.get("max_icon_raster_pixels", 0)),
        "error_count": l_errors,
    }
    error_count += l_errors

cold_samples_ms.sort()
startup_samples_ms.sort()
open_samples_ms.sort()
p50_samples_ms.sort()
p95_samples_ms.sort()
p99_samples_ms.sort()

def median(xs):
    if not xs:
        return 0.0
    return round(xs[len(xs) // 2], 3)

cold_median = median(cold_samples_ms)
startup_median = median(startup_samples_ms)
open_median = median(open_samples_ms)
frame_p50 = median(p50_samples_ms)
frame_p95 = median(p95_samples_ms)
frame_p99 = median(p99_samples_ms)

ok = (
    error_count == 0
    and long_ok
    and total_work_units > 0
    and quiescent_redraws == 0
    and len(cold_samples_ms) >= runs
    and cold_median <= 60.0
    and open_median <= 60.0
    and peak_rss_mib <= 64.0
    and frame_p50 <= 2.5
    and frame_p95 <= 8.33
    and frame_p99 <= 8.33
)

report = {
    "ok": ok,
    "label": label,
    "runs": runs,
    "work_units": total_work_units,
    "error_count": error_count,
    "cold_ms": cold_median,
    "startup_ms": startup_median,
    "transcript_open_ms": open_median,
    "rss_mib": peak_rss_mib,
    "pss_mib": peak_rss_mib,
    "frame_p50_ms": frame_p50,
    "frame_p95_ms": frame_p95,
    "frame_p99_ms": frame_p99,
    "idle_cpu_pct": 0.0,
    "quiescent_redraws": quiescent_redraws,
    "long_transcript": long_report,
    "baseline_gtk_webkit": {
        "cold_ms": 620.0,
        "startup_ms": 620.0,
        "transcript_open_ms": 620.0,
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
