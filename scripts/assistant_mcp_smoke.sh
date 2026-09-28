#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${HERMES_SANDBOXED_API_URL:-${SANDBOXED_SH_DEV_URL:-https://agent-backend-dev.thomas.md}}"
TOKEN="${HERMES_SANDBOXED_API_TOKEN:-${SANDBOXED_SH_TOKEN:-}}"
MCP_COMMAND="${HERMES_ASSISTANT_MCP_COMMAND:-$ROOT_DIR/target/debug/sandboxed-mcp}"
LIMIT="3"
REQUIRE_HERMES_RUNTIME=0

usage() {
  cat <<USAGE
Usage:
  scripts/assistant_mcp_smoke.sh [options]

Runs a sandboxed.sh-side Hermes bridge smoke:
1) /api/system/components reports assistant_mcp installed and ok
2) initialize sandboxed-mcp over stdio
3) tools/call list_active_missions

Options:
  --base-url URL             Sandboxed.sh backend URL (env: HERMES_SANDBOXED_API_URL, SANDBOXED_SH_DEV_URL)
  --token TOKEN              Optional control API bearer token (env: HERMES_SANDBOXED_API_TOKEN, SANDBOXED_SH_TOKEN)
  --command PATH             sandboxed-mcp command (env: HERMES_ASSISTANT_MCP_COMMAND)
  --limit N                  list_active_missions limit (default: 3)
  --require-hermes-runtime   Fail unless hermes_assistant is installed and ok
  -h, --help                 Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --command)
      MCP_COMMAND="${2:-}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-}"
      shift 2
      ;;
    --require-hermes-runtime)
      REQUIRE_HERMES_RUNTIME=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "Missing backend URL. Pass --base-url or set HERMES_SANDBOXED_API_URL." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for assistant_mcp_smoke.sh" >&2
  exit 2
fi

if [[ "$MCP_COMMAND" == "$ROOT_DIR/target/debug/sandboxed-mcp" && ! -x "$MCP_COMMAND" ]]; then
  echo "Building sandboxed-mcp debug binary..."
  cargo build --bin sandboxed-mcp --manifest-path "$ROOT_DIR/Cargo.toml"
fi

if [[ ! -x "$MCP_COMMAND" && -z "$(command -v "$MCP_COMMAND" 2>/dev/null)" ]]; then
  echo "sandboxed-mcp command is not executable or on PATH: $MCP_COMMAND" >&2
  exit 2
fi

tmp_components="$(mktemp)"
tmp_output="$(mktemp)"
trap 'rm -f "$tmp_components" "$tmp_output"' EXIT

curl_args=(-fsS "$BASE_URL/api/system/components")
if [[ -n "$TOKEN" ]]; then
  curl_args=(-fsS -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/system/components")
fi
curl "${curl_args[@]}" >"$tmp_components"

jq -e '
  .components[]
  | select(.name == "assistant_mcp")
  | .installed == true and .status == "ok"
' "$tmp_components" >/dev/null

hermes_runtime_status="$(
  jq -r '
    [.components[] | select(.name == "hermes_assistant") | .status][0] // "not_reported"
  ' "$tmp_components"
)"
hermes_runtime_installed="$(
  jq -r '
    [.components[] | select(.name == "hermes_assistant") | .installed][0] // false
  ' "$tmp_components"
)"
hermes_runtime_path="$(
  jq -r '
    [.components[] | select(.name == "hermes_assistant") | .path][0] // ""
  ' "$tmp_components"
)"

if [[ "$REQUIRE_HERMES_RUNTIME" == "1" ]]; then
  if ! jq -e '
    .components[]
    | select(.name == "hermes_assistant")
    | .installed == true and .status == "ok"
  ' "$tmp_components" >/dev/null; then
    echo "hermes_assistant is not ready: installed=$hermes_runtime_installed status=$hermes_runtime_status path=${hermes_runtime_path:-none}" >&2
    echo "Install and start hermes-assistant-dev.service, then rerun with --require-hermes-runtime." >&2
    exit 1
  fi
fi

echo "component assistant_mcp=ok"
echo "component hermes_assistant=$hermes_runtime_status"


printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sandboxed-mcp-smoke","version":"0"}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_active_missions\",\"arguments\":{\"limit\":$LIMIT}}}" \
  | HERMES_SANDBOXED_API_URL="$BASE_URL" \
    HERMES_SANDBOXED_API_TOKEN="$TOKEN" \
    "$MCP_COMMAND" --profile coordinator >"$tmp_output"

jq -e '
  select(.id == 1)
  | .result.serverInfo.name == "sandboxed-mcp"
  and (.result.serverInfo.version | type == "string")
' "$tmp_output" >/dev/null

jq -e '
  select(.id == 2)
  | .result.content[0].text
  | fromjson
  | (.result.missions | type == "array")
' "$tmp_output" >/dev/null

echo "sandboxed-mcp smoke passed against $BASE_URL"
jq -r '
  select(.id == 2)
  | .result.content[0].text
  | fromjson
  | "missions_returned=\(.result.missions | length)"
' "$tmp_output"
