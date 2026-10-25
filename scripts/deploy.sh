#!/usr/bin/env bash
#
# Orb Control Plane Guarded Deployment Script (formerly sandboxed.sh deploy.sh)
# Usage:
#   ./scripts/deploy.sh [--dev | --prod] [--git-ref REF] [--skip-build] [--force] [--mission-id UUID]
#
# Calls the guarded `/api/system/deploy` SSE endpoint (which enforces
# `orb_deploy_gate_step`, live-writer quiescence, self-target protection,
# debounce, and automatic binary rollback).
#
# Note: Production deploys (`--prod`, port 3000) from a mission require an
# active session-scoped `service_deploy` grant approved via Touch ID / Face ID:
#   request_privileged_access(target_host="agent-core", scope="service_deploy", session_scoped=true, reason="...")

set -euo pipefail

TARGET="dev"
GIT_REF=""
SKIP_BUILD="false"
FORCE="false"
MISSION_ID="${ORB_MISSION_ID:-${SANDBOXED_SH_MISSION_ID:-}}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod|prod)
      TARGET="prod"
      shift
      ;;
    --dev|dev)
      TARGET="dev"
      shift
      ;;
    --git-ref)
      GIT_REF="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD="true"
      shift
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --mission-id)
      MISSION_ID="$2"
      shift 2
      ;;
    *)
      GIT_REF="$1"
      shift
      ;;
  esac
done

if [[ "$TARGET" == "prod" ]]; then
  API_URL="${ORB_PROD_API_URL:-http://127.0.0.1:3000}"
  EXPECTED_SERVICE="sandboxed-sh-prod.service"
else
  API_URL="${ORB_DEV_API_URL:-http://127.0.0.1:3001}"
  EXPECTED_SERVICE="sandboxed-sh-dev.service"
fi

PAYLOAD=$(python3 - "$MISSION_ID" "$FORCE" "$GIT_REF" "$SKIP_BUILD" "$REPO_DIR" "$EXPECTED_SERVICE" <<'PY'
import json, sys
mid, force, git_ref, skip_build, repo_dir, expected = sys.argv[1:7]
body = {
    "force": force == "true",
    "skip_build": skip_build == "true",
    "repo_path": repo_dir,
    "expected_service": expected,
}
if mid:
    body["calling_mission_id"] = mid
if git_ref:
    body["git_ref"] = git_ref
print(json.dumps(body))
PY
)

echo "[orb-deploy] Target: ${TARGET} (${API_URL}, expected=${EXPECTED_SERVICE})"
curl -sS -N -X POST "${API_URL}/api/system/deploy" \
  -H "Content-Type: application/json" \
  ${ORB_AUTH_TOKEN:+-H "Authorization: Bearer ${ORB_AUTH_TOKEN}"} \
  -d "$PAYLOAD"
