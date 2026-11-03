#!/bin/bash
# Multi-host disk sentinel with per-host hysteresis and repeat cooldown.
#
# Prints NOTHING when every host is healthy or within its repeat cooldown.
# Emits one line per host on:
#   - upward severity transitions: >=85% (WARN), >=92% (CRITICAL), >=95% (EMERGENCY)
#   - periodic reminders every REPEAT_SECS (default 12h) while still degraded
#   - recovery once usage drops to <= WARN - RECOVERY_MARGIN (default <=82%)
#   - reachability loss (DISK UNKNOWN, repeated every UNKNOWN_REPEAT_SECS = 6h)
#
# Pass --stateless (or DISK_SENTINEL_STATELESS=1) for a one-off operator check
# that prints all currently degraded/unreachable hosts without reading or
# updating cooldown state.
#
# Uses the SOC 2 Type I per-host SSH keys and lean-mesh (10.88.0.0/16) config.
set -u

STATELESS="${DISK_SENTINEL_STATELESS:-0}"
if [ "${1:-}" = "--stateless" ]; then
  STATELESS=1
fi

WARN="${WARN:-85}"
CRIT="${CRIT:-92}"
EMERG="${EMERG:-95}"
RECOVERY_MARGIN="${RECOVERY_MARGIN:-3}"
REPEAT_SECS="${REPEAT_SECS:-43200}"
UNKNOWN_REPEAT_SECS="${UNKNOWN_REPEAT_SECS:-21600}"
STATE_FILE="${DISK_SENTINEL_STATE_FILE:-/var/lib/hermes-assistant/cron/state/disk-sentinel.json}"
SSH_CONFIG="${SSH_CONFIG:-/root/.config/sandboxed-sh/development-identity/current/ssh/config}"

DF='df -B1 --output=pcent,avail "$0" | tail -1'

local_df() {
  bash -c "$DF" "$1" 2>/dev/null
}

remote_df() {
  local target="$1"
  timeout 12 ssh \
    -F "$SSH_CONFIG" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    "$target" \
    "df -B1 --output=pcent,avail / | tail -1" 2>/dev/null
}

collect_samples() {
  if [ -n "${DISK_SENTINEL_INPUT_FILE:-}" ]; then
    cat "$DISK_SENTINEL_INPUT_FILE"
    return
  fi
  printf '%s\t%s\n' "agent-core(65.109.98.246)" "$(local_df /)"
  printf '%s\t%s\n' "agent-core-storage" "$(local_df /srv/sandboxed-storage)"
  printf '%s\t%s\n' "ashur" "$(remote_df ashur)"
  printf '%s\t%s\n' "babylon" "$(remote_df babylon)"
  printf '%s\t%s\n' "nippur" "$(remote_df nippur)"
  printf '%s\t%s\n' "dgx-spark" "$(remote_df dgx-spark)"
  printf '%s\t%s\n' "uruk" "$(remote_df uruk)"
  printf '%s\t%s\n' "nimrud" "$(remote_df nimrud)"
}

SAMPLES="$(collect_samples)"

SAMPLES_ENV="$SAMPLES" \
STATELESS_ENV="$STATELESS" \
WARN_ENV="$WARN" \
CRIT_ENV="$CRIT" \
EMERG_ENV="$EMERG" \
RECOVERY_MARGIN_ENV="$RECOVERY_MARGIN" \
REPEAT_SECS_ENV="$REPEAT_SECS" \
UNKNOWN_REPEAT_SECS_ENV="$UNKNOWN_REPEAT_SECS" \
STATE_FILE_ENV="$STATE_FILE" \
NOW_ENV="${DISK_SENTINEL_NOW:-}" \
python3 - <<'PY'
import fcntl
import json
import os
from pathlib import Path
import re
import time

samples_raw = os.environ.get("SAMPLES_ENV", "")
stateless = os.environ.get("STATELESS_ENV", "0") == "1"
warn_pct = int(os.environ["WARN_ENV"])
crit_pct = int(os.environ["CRIT_ENV"])
emerg_pct = int(os.environ["EMERG_ENV"])
recovery_margin = int(os.environ["RECOVERY_MARGIN_ENV"])
repeat_secs = int(os.environ["REPEAT_SECS_ENV"])
unknown_repeat_secs = int(os.environ["UNKNOWN_REPEAT_SECS_ENV"])
state_path = Path(os.environ["STATE_FILE_ENV"])
now_raw = os.environ.get("NOW_ENV", "").strip()
now = int(now_raw) if now_raw else int(time.time())
recover_pct = max(0, warn_pct - recovery_margin)

LEVEL_NAMES = {1: "WARN", 2: "CRITICAL", 3: "EMERGENCY"}


def raw_level(pct: int) -> int:
    if pct >= emerg_pct:
        return 3
    if pct >= crit_pct:
        return 2
    if pct >= warn_pct:
        return 1
    return 0


def format_alert(level, name, pct, avail):
    free = f", {avail // 1073741824} GiB free" if avail is not None else ""
    suffix = " - missions on this host will stall" if level == 3 else ""
    return f"DISK {LEVEL_NAMES[level]} {name}: {pct}% used{free}{suffix}"


def format_recovered(name, pct, avail):
    free = f", {avail // 1073741824} GiB free" if avail is not None else ""
    return f"DISK RECOVERED {name}: {pct}% used{free}"


def parse_sample(rest):
    tokens = rest.strip().split()
    if not tokens:
        return None, None
    pct_digits = re.sub(r"[^0-9]", "", tokens[0])
    avail_digits = re.sub(r"[^0-9]", "", tokens[1]) if len(tokens) > 1 else ""
    if not pct_digits:
        return None, None
    return int(pct_digits), (int(avail_digits) if avail_digits else None)


def evaluate(hosts_state):
    out = []
    for line in samples_raw.splitlines():
        if "\t" not in line:
            continue
        name, rest = line.split("\t", 1)
        pct, avail = parse_sample(rest)

        if stateless:
            if pct is None:
                out.append(f"DISK UNKNOWN {name}: unreachable")
            else:
                lvl = raw_level(pct)
                if lvl > 0:
                    out.append(format_alert(lvl, name, pct, avail))
            continue

        entry = dict(hosts_state.get(name) or {})
        prev_lvl = int(entry.get("level", 0))
        prev_unknown = bool(entry.get("unknown", False))
        last_alert_ts = int(entry.get("last_alert_ts", 0))

        if pct is None:
            if not prev_unknown or (now - last_alert_ts) >= unknown_repeat_secs:
                out.append(f"DISK UNKNOWN {name}: unreachable")
                entry["last_alert_ts"] = now
            entry["unknown"] = True
            entry["last_seen_ts"] = now
            hosts_state[name] = entry
            continue

        lvl = raw_level(pct)
        # Hysteresis: keep host armed at WARN (1) when between recover_pct+1 and warn_pct-1
        if lvl == 0 and prev_lvl > 0 and pct > recover_pct:
            effective_lvl = 1
        else:
            effective_lvl = lvl

        if effective_lvl == 0:
            if prev_lvl > 0 or prev_unknown:
                out.append(format_recovered(name, pct, avail))
            hosts_state[name] = {
                "level": 0,
                "unknown": False,
                "last_alert_ts": 0,
                "last_pct": pct,
                "last_seen_ts": now,
            }
        else:
            # Alert immediately on upward severity escalation or first transition from OK/UNKNOWN;
            # otherwise suppress repeats until repeat_secs elapses.
            should_alert = (
                effective_lvl > prev_lvl
                or prev_unknown
                or (now - last_alert_ts) >= repeat_secs
            )
            if should_alert:
                # Report the highest of current threshold or armed WARN hysteresis band
                report_lvl = lvl if lvl > 0 else 1
                out.append(format_alert(report_lvl, name, pct, avail))
                last_alert_ts = now
            # Track peak alerted severity until recovery or a periodic reminder resets it to current
            new_tracked_lvl = report_lvl if should_alert else max(prev_lvl, effective_lvl)
            hosts_state[name] = {
                "level": new_tracked_lvl,
                "unknown": False,
                "last_alert_ts": last_alert_ts,
                "last_pct": pct,
                "last_seen_ts": now,
            }
    return out


if stateless:
    for msg in evaluate({}):
        print(msg)
else:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = state_path.with_suffix(state_path.suffix + ".lock")
    with open(lock_path, "w", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        state_data = {"hosts": {}}
        if state_path.is_file():
            try:
                loaded = json.loads(state_path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict) and isinstance(loaded.get("hosts"), dict):
                    state_data = loaded
            except (OSError, ValueError):
                state_data = {"hosts": {}}
        messages = evaluate(state_data["hosts"])
        tmp_path = state_path.with_suffix(f"{state_path.suffix}.tmp.{os.getpid()}")
        tmp_path.write_text(json.dumps(state_data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp_path, state_path)
    for msg in messages:
        print(msg)
PY
chmod_rc=$?
exit $chmod_rc
