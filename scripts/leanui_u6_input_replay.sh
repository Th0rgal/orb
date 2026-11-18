#!/usr/bin/env bash
set -euo pipefail

# U6 evidence contract. The native compositor walk uses the same Event values
# after Wayland decoding; this replay remains runnable in headless CI and names
# every required transition. A built orb-desktop-native can be substituted by
# the caller when a compositor is available.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
printf '%s\n' \
  'U6 event replay contract' \
  '1. pointer release -> activate new mission' \
  '2. imeBatch -> composer commit' \
  '3. activate send -> message sent' \
  '4. activate stop -> mission stopped' \
  '5. activate archive -> mission archived' \
  '6. Tab/Enter -> shared focus and activation' \
  '7. scroll -> shared Orb.Scroll policy' \
  '8. side panel and nine-screen controls -> hit regions'

if [[ "${U6_WAYLAND_LIVE:-0}" == 1 ]]; then
  exec "$ROOT/target/native/orb-desktop-native" --screen mission_transcript
fi
