#!/usr/bin/env bash
# Smoke test for the orb-node-base image. Run INSIDE a sandbox started from the
# snapshot, as user `user` (passwordless sudo). Node-facing checks run as the
# unprivileged service account `orbnode`. Exit 0 only if every check passes.
set -uo pipefail
M=/etc/orb/image-manifest.json
NU=orbnode
NH=/var/lib/orb-node
EH=$NH/work/caches/elan
NUID=$(id -u $NU 2>/dev/null || echo 0)
fails=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails+1)); }
check() { local name=$1; shift; if out=$("$@" 2>&1); then pass "$name: $(echo "$out" | head -1 | cut -c1-120)"; else fail "$name: $(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)"; fi; }
as_node() { sudo -u $NU -H env HOME=$NH ELAN_HOME=$EH XDG_RUNTIME_DIR=/run/user/$NUID \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$NUID/bus DISABLE_AUTOUPDATER=1 NO_COLOR=1 \
  PATH=$EH/bin:/opt/orb/bin:/usr/local/bin:/usr/bin:/bin "$@"; }

[ "$(id -un)" = user ] || fail "must run as user (is $(id -un))"
[ -r "$M" ] && jq -e '.image=="orb-node-base"' "$M" >/dev/null && pass "manifest present" || fail "manifest missing/invalid"

# --- service account isolation
id $NU >/dev/null 2>&1 && pass "account $NU exists (uid $NUID)" || fail "account $NU missing"
groups=$(id -nG $NU 2>/dev/null)
grep -qwE 'sudo|adm|admin|wheel|docker|lxd' <<<"$groups" && fail "$NU in privileged group: $groups" || pass "$NU groups: $groups"
if as_node sudo -n true >/dev/null 2>&1; then fail "$NU can sudo"; else pass "$NU cannot sudo"; fi
sudo install -m 600 -o user -g user /dev/null /home/user/.orb/enroll.env.smoke
echo canary | sudo tee /home/user/.orb/enroll.env.smoke >/dev/null
if as_node cat /home/user/.orb/enroll.env.smoke >/dev/null 2>&1; then fail "$NU can read /home/user/.orb"; else pass "$NU cannot read /home/user/.orb/*"; fi
sudo rm -f /home/user/.orb/enroll.env.smoke
[ "$(stat -c '%U %a' /home/user/.orb)" = "user 700" ] && pass "/home/user/.orb is user 700" || fail "/home/user/.orb perms $(stat -c '%U %a' /home/user/.orb)"
check "unit runs as $NU" grep -qx "User=$NU" /etc/systemd/system/orb-node.service
check "unit work dir" grep -qx "Environment=SANDBOXED_NODE_WORK_DIR=$NH/work" /etc/systemd/system/orb-node.service
check "orb-node.service not enabled" sh -c "! systemctl is-enabled orb-node.service 2>/dev/null | grep -qx enabled"
check "orb-boot.service enabled" sh -c "systemctl is-enabled orb-boot.service | grep -qx enabled"
for _ in $(seq 1 30); do [ -S /run/user/$NUID/bus ] && break; sleep 0.5; done
check "linger enabled for $NU (after boot)" sh -c "loginctl show-user $NU -p Linger | grep -q yes"
check "user bus /run/user/$NUID/bus" test -S /run/user/$NUID/bus
check "systemd-run --user --scope true (as $NU)" as_node timeout 30 systemd-run --user --scope --quiet true

# --- harnesses and tools, as orbnode
for h in claude codex opencode gemini agy; do
  want=$(jq -r ".harnesses[\"$h\"] // empty" "$M")
  got=$(as_node timeout 60 "$h" --version 2>&1 | head -3)
  if [ -n "$want" ] && grep -qF -- "$want" <<<"$got"; then pass "$h --version $want (as $NU)"
  else fail "$h --version: want '$want' got '$(echo "$got" | head -1 | cut -c1-100)'"; fi
done
for t in claude codex opencode gemini agy lake lean elan turbo-lean lean-native certified-search research-governor sandboxed-node node; do
  as_node sh -c "command -v $t" >/dev/null || fail "$t not on PATH for $NU"
done
check "lake --version" as_node lake --version
check "lean default v4.35.0" as_node sh -c "lean --version | grep -F 'version 4.35.0'"
check "turbo-lean --version" as_node turbo-lean --version
check "lean-native --version" as_node lean-native --version
check "certified-search --help" as_node certified-search --help
check "sandboxed-mcp link after boot" sh -c "[ \"\$(readlink /usr/local/bin/sandboxed-mcp)\" = /opt/orb/bin/sandboxed-mcp ] && [ \"\$(stat -L -c %U /usr/local/bin/sandboxed-mcp)\" = root ]"
mcp_out=$(as_node timeout 3 /usr/local/bin/sandboxed-mcp </dev/null 2>&1); mcp_rc=$?
if grep -q 'No such file' <<<"$mcp_out" || [ $mcp_rc -eq 126 ] || [ $mcp_rc -eq 127 ]; then fail "sandboxed-mcp as $NU (rc $mcp_rc): $(echo "$mcp_out" | head -2 | tr '\n' ' ' | cut -c1-200)"
else pass "sandboxed-mcp runs as $NU (rc $mcp_rc)"; fi
check "shared elan root-owned, read-only" sh -c "[ -z \"\$(sudo find /opt/orb -not -user root -o -perm /022 -not -type l | head -1)\" ]"
check "lake --version as user (shared toolchain)" sh -c "PATH=/opt/orb/bin:/usr/bin:/bin lake --version"
check "no global ELAN_HOME" sh -c "! grep -rqs ELAN_HOME /etc/environment /etc/profile /etc/profile.d /etc/bash.bashrc"
check "research-governor-core present" test -x /opt/orb/bin/research-governor-core

proj=$(as_node mktemp -d -p $NH)
as_node sh -c "cat >'$proj/lakefile.lean'" <<'EOF'
import Lake
open Lake DSL
package smoke
@[default_target] lean_lib Smoke
EOF
as_node sh -c "echo 'leanprover/lean4:v4.35.0' >'$proj/lean-toolchain'; printf 'theorem smoke_add : 2 + 2 = 4 := rfl\ndef hello : String := \"orb\"\n' >'$proj/Smoke.lean'"
check "lake build tiny project (as $NU)" as_node sh -c "cd '$proj' && timeout 300 lake build"
check "no extra toolchain downloaded" sh -c "[ \"\$(sudo ls $EH/toolchains)\" = leanprover--lean4---v4.35.0 ]"
sudo rm -rf "$proj"

# --- sandboxed-node as orbnode: authenticated heartbeat
sudo pkill -u $NU -f '^/opt/orb/bin/sandboxed-node' 2>/dev/null; sleep 0.5
wd=$(as_node mktemp -d -p $NH)
as_node env -u SANDBOXED_NODE_ALLOW_ROOT SANDBOXED_NODE_TOKEN=smoke SANDBOXED_NODE_BIND=127.0.0.1:3088 \
  SANDBOXED_NODE_WORK_DIR="$wd/work" SANDBOXED_NODE_ID=smoke /opt/orb/bin/sandboxed-node >/tmp/smoke-node.log 2>&1 &
hb=""
for _ in $(seq 1 40); do
  hb=$(curl -fsS -m 3 -H 'Authorization: Bearer smoke' http://127.0.0.1:3088/heartbeat 2>/dev/null) && break
  sleep 0.5
done
if [ -n "$hb" ] && jq -e '.node_id=="smoke"' >/dev/null <<<"$hb"; then
  pass "sandboxed-node heartbeat (as $NU): $(jq -c '{node_id,online,version,protocol_version,lean_runtime_ready}' <<<"$hb")"
  want=$(jq -r '.node_version // empty' "$M"); got=$(jq -r '.version // empty' <<<"$hb")
  case "$want" in *"$got"*) pass "node version $got in manifest '$want'";; *) fail "node version $got not in manifest '$want'";; esac
  owner=$(ps -o user= -p "$(pgrep -f '^/opt/orb/bin/sandboxed-node' | head -1)" 2>/dev/null)
  [ "$owner" = $NU ] && pass "node process user $owner" || fail "node process user '$owner'"
else
  fail "sandboxed-node heartbeat: $(tail -5 /tmp/smoke-node.log | tr '\n' ' ' | cut -c1-400)"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:3088/heartbeat)
[ "$code" = 401 ] && pass "heartbeat without token -> 401" || fail "heartbeat without token -> $code"
sudo pkill -u $NU -f '^/opt/orb/bin/sandboxed-node' 2>/dev/null; sleep 0.5
sudo rm -rf "$wd" /tmp/smoke-node.log

# --- PATH hygiene: root's and user's login PATH dirs must be root-owned (user's may also be
# owned by user itself) and not group/other-writable.
path_ok() { # label owner-allowed path
  local bad="" d
  IFS=: read -ra ds <<<"$3"
  for d in "${ds[@]}"; do
    [ -n "$d" ] && sudo test -e "$d" || continue
    o=$(sudo stat -L -c %U "$d"); m=$(sudo stat -L -c %a "$d")
    if ! grep -qwx -- "$o" <<<"$(tr ' ' '\n' <<<"$2")" || [ $(( 8#$m & 8#022 )) -ne 0 ]; then bad="$bad $d($o,$m)"; fi
  done
  [ -z "$bad" ] && pass "PATH hygiene $1" || fail "PATH hygiene $1:$bad"
}
path_ok "root login" root "$(sudo -i sh -c 'echo $PATH')"
path_ok "/etc/environment" root "$(sudo sh -c '. /etc/environment 2>/dev/null; echo ${PATH:-}')"
path_ok "user login" "root user" "$(sudo -iu user sh -c 'echo $PATH')"
path_ok "orb-node.service (non-orbnode dirs)" root "$(grep -oP '^Environment=PATH=\K.*' /etc/systemd/system/orb-node.service | tr ':' '\n' | grep -v '^/var/lib/orb-node' | paste -sd:)"

# --- secrets scan
# Boat writes ~/.config/ascii/boat/config.json at every boot; on a noEnv sandbox it holds
# only {api_url, channel}. Anything more (an API key) is a leak.
for f in /home/user/.config/ascii/boat/config.json /root/.config/ascii/boat/config.json; do
  sudo test -e "$f" || continue
  extra=$(sudo jq -r 'keys - ["api_url","channel"] | join(",")' "$f" 2>/dev/null || echo unparsable)
  [ -z "$extra" ] && pass "boat config $f has no credentials" || fail "boat config $f has extra keys: $extra"
done
for f in /home/user/.config/gh/hosts.yml /root/.config/gh/hosts.yml $NH/.config/gh/hosts.yml /home/user/.orb/enroll.env \
         $NH/node.cred $NH/work/node.cred /home/user/.git-credentials; do
  sudo test -e "$f" && fail "secret file present: $f"
done
# /opt/sandboxed-tools holds sha256-pinned upstream harness bundles whose secret-redaction
# code contains these regexes; it is verified by hash, not scanned.
hits=$(sudo grep -rIlE --exclude-dir=proc --exclude-dir=toolchains --exclude-dir=node_modules --exclude-dir=sandboxed-tools \
  '(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|gho_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{20,}|boat_[A-Za-z0-9]{24,}|sk-proj-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})' \
  /home /etc /opt /root /var/lib/orb-node 2>/dev/null | head -20)
[ -z "$hits" ] && pass "secrets scan (home, etc, opt, root, /var/lib/orb-node)" || fail "secrets scan hits: $(echo $hits)"
env | grep -qE '^(GH_TOKEN|GITHUB_TOKEN|BOAT_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)=' && fail "secret env var present" || pass "no secret env vars"

echo "SMOKE SUMMARY: $fails failure(s)"
[ $fails -eq 0 ]
