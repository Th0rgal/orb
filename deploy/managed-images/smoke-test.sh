#!/usr/bin/env bash
# Smoke test for the orb-node-base image. Run INSIDE a sandbox started from the
# snapshot, as user `user` (passwordless sudo available). Exit 0 only if every
# check passes. Prints one PASS/FAIL line per check and a final summary.
set -uo pipefail
export PATH="$HOME/.elan/bin:/usr/local/bin:$PATH" DISABLE_AUTOUPDATER=1 NO_COLOR=1
M=/etc/orb/image-manifest.json
fails=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails+1)); }
check() { local name=$1; shift; if out=$("$@" 2>&1); then pass "$name: $(echo "$out" | head -1 | cut -c1-120)"; else fail "$name: $(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)"; fi; }

[ "$(id -un)" = user ] || fail "must run as user (is $(id -un))"
[ -r "$M" ] && jq -e '.image=="orb-node-base"' "$M" >/dev/null && pass "manifest present" || fail "manifest missing/invalid"

for h in claude codex opencode gemini agy; do
  want=$(jq -r ".harnesses[\"$h\"] // empty" "$M")
  got=$(timeout 60 "$h" --version 2>&1 | head -3)
  if [ -n "$want" ] && grep -qF -- "$want" <<<"$got"; then pass "$h --version $want"
  else fail "$h --version: want '$want' got '$(echo "$got" | head -1 | cut -c1-100)'"; fi
done
for t in claude codex opencode gemini agy lake lean elan turbo-lean lean-native certified-search research-governor sandboxed-node node; do
  command -v "$t" >/dev/null || fail "$t not on PATH"
done

check "lake --version" lake --version
check "lean default" sh -c "elan show | grep -q 'v4.35.0' && lean --version | grep -F 4.35.0"
check "turbo-lean --version" turbo-lean --version
check "lean-native --version" lean-native --version
check "certified-search --help" certified-search --help
check "research-governor-core present" test -x /usr/local/bin/research-governor-core

proj=$(mktemp -d)/smoke
mkdir -p "$proj"
cat >"$proj/lakefile.lean" <<'EOF'
import Lake
open Lake DSL
package smoke
@[default_target] lean_lib Smoke
EOF
echo "leanprover/lean4:v4.35.0" >"$proj/lean-toolchain"
echo 'theorem smoke_add : 2 + 2 = 4 := rfl
def hello : String := "orb"' >"$proj/Smoke.lean"
check "lake build tiny project" sh -c "cd '$proj' && timeout 300 lake build"
rm -rf "$(dirname "$proj")"

check "systemd-run --user --scope true" timeout 30 systemd-run --user --scope --quiet true
check "linger enabled" sh -c "loginctl show-user user -p Linger | grep -q yes"
check "orb-node.service installed" sh -c "systemctl cat orb-node.service >/dev/null && grep -q '^User=user' /etc/systemd/system/orb-node.service"
check "orb-node.service not enabled" sh -c "! systemctl is-enabled orb-node.service 2>/dev/null | grep -qx enabled"

# sandboxed-node: starts as user, answers an authenticated heartbeat.
pkill -u user -f '^/usr/local/bin/sandboxed-node' 2>/dev/null; sleep 0.5
wd=$(mktemp -d)
env -u SANDBOXED_NODE_ALLOW_ROOT SANDBOXED_NODE_TOKEN=smoke SANDBOXED_NODE_BIND=127.0.0.1:3088 \
  SANDBOXED_NODE_WORK_DIR="$wd" SANDBOXED_NODE_ID=smoke /usr/local/bin/sandboxed-node >"$wd.log" 2>&1 &
npid=$!
hb=""
for _ in $(seq 1 40); do
  hb=$(curl -fsS -m 3 -H 'Authorization: Bearer smoke' http://127.0.0.1:3088/heartbeat 2>/dev/null) && break
  kill -0 $npid 2>/dev/null || break; sleep 0.5
done
if [ -n "$hb" ] && jq -e '.node_id=="smoke"' >/dev/null <<<"$hb"; then
  pass "sandboxed-node heartbeat: $(jq -c '{node_id,online,version,protocol_version,lean_runtime_ready}' <<<"$hb")"
  want=$(jq -r '.node_version // empty' "$M"); got=$(jq -r '.version // empty' <<<"$hb")
  case "$want" in *"$got"*) pass "node version $got in manifest '$want'";; *) fail "node version $got not in manifest '$want'";; esac
else
  fail "sandboxed-node heartbeat: $(tail -5 "$wd.log" | tr '\n' ' ' | cut -c1-400)"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:3088/heartbeat)
[ "$code" = 401 ] && pass "heartbeat without token -> 401" || fail "heartbeat without token -> $code"
kill $npid 2>/dev/null; wait $npid 2>/dev/null; rm -rf "$wd" "$wd.log"

# Secrets scan.
# Boat writes ~/.config/ascii/boat/config.json at every boot; on a noEnv sandbox it holds
# only {api_url, channel}. Anything more (an API key) is a leak.
for f in "$HOME/.config/ascii/boat/config.json" /root/.config/ascii/boat/config.json; do
  sudo test -e "$f" || continue
  extra=$(sudo jq -r 'keys - ["api_url","channel"] | join(",")' "$f" 2>/dev/null || echo unparsable)
  [ -z "$extra" ] && pass "boat config $f has no credentials" || fail "boat config $f has extra keys: $extra"
done
for f in "$HOME/.config/gh/hosts.yml" /root/.config/gh/hosts.yml "$HOME/.orb/enroll.env" "$HOME/.orb/node.cred" "$HOME/.git-credentials"; do
  sudo test -e "$f" && fail "secret file present: $f"
done
hits=$(sudo grep -rIlE --exclude-dir=proc --exclude-dir=.elan --exclude-dir=node_modules \
  '(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|gho_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{20,}|boat_[A-Za-z0-9]{24,}|sk-proj-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})' \
  /home /etc /opt /root 2>/dev/null | head -20)
[ -z "$hits" ] && pass "secrets scan (home, etc, opt, root)" || fail "secrets scan hits: $(echo $hits)"
env | grep -qE '^(GH_TOKEN|GITHUB_TOKEN|BOAT_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)=' && fail "secret env var present" || pass "no secret env vars"

echo "SMOKE SUMMARY: $fails failure(s)"
[ $fails -eq 0 ]
