#!/usr/bin/env bash
# orb-node-base image recipe (boat.dev managed machines).
#
# Runs INSIDE a fresh boat sandbox (Ubuntu 24.04 x86_64) as user `user` with
# passwordless sudo. Idempotent: re-running converges to the same state.
# Binding contract: ~/work/paloma/boat/CONTRACT.md ("Image orb-node-base").
#
# Inputs staged by scripts/managed_image.py (boat files API) in $ORB_STAGE:
#   sandboxed-node                Linux x86_64 binary (built in a boat sandbox)
#   fleet-tools-x86_64.tar.gz     agy turbo-lean lean-native lean-native-core
#                                 research-governor research-governor-core
#                                 (x86_64 builds copied read-only from a fleet host)
#   certified-search.tar.gz       GitHub tarball of Th0rgal/certified-search (private)
#   build-info.json               {"node_version", "recipe_sha", "tools": {...provenance}}
# The sandbox is created with noEnv: it has no GitHub or boat credentials, and
# this recipe must never write any secret into the image.
set -euo pipefail

ORB_STAGE=${ORB_STAGE:-/home/user/.orb-stage}
CLAUDE_VERSION=${CLAUDE_VERSION:-2.1.306}
CODEX_VERSION=${CODEX_VERSION:-0.163.0}
OPENCODE_VERSION=${OPENCODE_VERSION:-1.19.3}
GEMINI_VERSION=${GEMINI_VERSION:-0.65.0}
NODEJS_VERSION=${NODEJS_VERSION:-22.20.0}
LEAN_TOOLCHAIN=${LEAN_TOOLCHAIN:-leanprover/lean4:v4.35.0}
TOOLS=/opt/sandboxed-tools
USER_NAME=user
USER_HOME=/home/user

log() { printf '[recipe %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
as_user() { sudo -u "$USER_NAME" -H env HOME="$USER_HOME" PATH="$USER_HOME/.elan/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
[ "$(uname -m)" = x86_64 ] || { echo "x86_64 only" >&2; exit 1; }
for f in sandboxed-node fleet-tools-x86_64.tar.gz certified-search.tar.gz build-info.json; do
  [ -s "$ORB_STAGE/$f" ] || { echo "missing staged input $ORB_STAGE/$f" >&2; exit 1; }
done

log "apt base packages"
export DEBIAN_FRONTEND=noninteractive
need=()
for p in curl ca-certificates git jq xz-utils tar gzip python3 build-essential libssl3 dbus-user-session systemd-container; do
  dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ ${#need[@]} -gt 0 ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq --no-install-recommends "${need[@]}"
fi

log "node.js $NODEJS_VERSION (runtime for npm-based harnesses)"
NODE_DIR=$TOOLS/node/$NODEJS_VERSION
if [ ! -x "$NODE_DIR/bin/node" ]; then
  tmp=$(mktemp -d)
  curl -fsSL "https://nodejs.org/dist/v$NODEJS_VERSION/node-v$NODEJS_VERSION-linux-x64.tar.xz" -o "$tmp/node.tar.xz"
  curl -fsSL "https://nodejs.org/dist/v$NODEJS_VERSION/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
  (cd "$tmp" && grep " node-v$NODEJS_VERSION-linux-x64.tar.xz\$" SHASUMS256.txt | sed 's/node-v.*/node.tar.xz/' | sha256sum -c -)
  sudo mkdir -p "$NODE_DIR"
  sudo tar -xJf "$tmp/node.tar.xz" -C "$NODE_DIR" --strip-components=1
  rm -rf "$tmp"
fi
for b in node npm npx; do sudo ln -sfn "$NODE_DIR/bin/$b" /usr/local/bin/$b; done
NPM="$NODE_DIR/bin/npm"

npm_tool() { # name package version bin
  local name=$1 pkg=$2 ver=$3 bin=$4 prefix=$TOOLS/$1/$3
  if [ ! -x "$prefix/bin/$bin" ]; then
    sudo mkdir -p "$prefix"
    sudo env PATH="$NODE_DIR/bin:/usr/bin:/bin" npm_config_update_notifier=false npm_config_fund=false \
      "$NPM" install -g --prefix "$prefix" --no-audit --loglevel=error "$pkg@$ver"
  fi
  sudo ln -sfn "$prefix/bin/$bin" "/usr/local/bin/$name"
}
log "harness: claude $CLAUDE_VERSION";  npm_tool claude @anthropic-ai/claude-code "$CLAUDE_VERSION" claude
log "harness: codex $CODEX_VERSION";    npm_tool codex @openai/codex "$CODEX_VERSION" codex
log "harness: gemini $GEMINI_VERSION";  npm_tool gemini @google/gemini-cli "$GEMINI_VERSION" gemini

log "harness: opencode $OPENCODE_VERSION"
OC_DIR=$TOOLS/opencode/$OPENCODE_VERSION
if [ ! -x "$OC_DIR/opencode" ]; then
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/anomalyco/opencode/releases/download/v$OPENCODE_VERSION/opencode-linux-x64-baseline.tar.gz" -o "$tmp/oc.tgz"
  sudo mkdir -p "$OC_DIR"
  sudo tar -xzf "$tmp/oc.tgz" -C "$OC_DIR" opencode
  sudo chmod 755 "$OC_DIR/opencode"
  rm -rf "$tmp"
fi
sudo ln -sfn "$OC_DIR/opencode" /usr/local/bin/opencode

log "fleet tools: agy, turbo-lean, lean-native, research-governor"
tmp=$(mktemp -d)
tar -xzf "$ORB_STAGE/fleet-tools-x86_64.tar.gz" -C "$tmp"
for b in agy turbo-lean lean-native lean-native-core research-governor research-governor-core; do
  sudo install -m 0755 -o root -g root "$tmp/$b" "/usr/local/bin/$b"
done
rm -rf "$tmp"
# Antigravity ships its own verified self-updater (see scripts/update-node-harnesses.py).
# Try to move to the newest release; keep the fleet binary if the update fails.
sudo cp /usr/local/bin/agy /usr/local/bin/agy.previous
if sudo env HOME=/root timeout 300 /usr/local/bin/agy update >/tmp/agy-update.log 2>&1 \
   && /usr/local/bin/agy --version >/dev/null 2>&1; then
  log "agy updated: $(/usr/local/bin/agy --version | head -1)"
else
  log "agy update failed or unavailable; keeping fleet binary"; sudo cp /usr/local/bin/agy.previous /usr/local/bin/agy
fi
sudo rm -f /usr/local/bin/agy.previous /tmp/agy-update.log
sudo rm -rf /root/.config/agy /root/.antigravity* 2>/dev/null || true

log "certified-search source + CLI"
sudo rm -rf /opt/certified-search.new && sudo mkdir -p /opt/certified-search.new
sudo tar -xzf "$ORB_STAGE/certified-search.tar.gz" -C /opt/certified-search.new --strip-components=1
sudo rm -rf /opt/certified-search && sudo mv /opt/certified-search.new /opt/certified-search
sudo chmod -R a+rX /opt/certified-search
# certified-search is the repo that builds research-governor; expose it under the repo name too.
sudo tee /usr/local/bin/certified-search >/dev/null <<'EOF'
#!/bin/sh
# certified-search (Th0rgal/certified-search) CLI: the research-governor sidecar.
exec /usr/local/bin/research-governor "$@"
EOF
sudo chmod 755 /usr/local/bin/certified-search

log "elan + $LEAN_TOOLCHAIN (user $USER_NAME)"
if [ ! -x "$USER_HOME/.elan/bin/elan" ]; then
  curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -o /tmp/elan-init.sh
  as_user sh /tmp/elan-init.sh -y --no-modify-path --default-toolchain none
  rm -f /tmp/elan-init.sh
fi
as_user elan toolchain install "$LEAN_TOOLCHAIN"
as_user elan default "$LEAN_TOOLCHAIN"
grep -q '.elan/bin' "$USER_HOME/.profile" 2>/dev/null || echo 'export PATH="$HOME/.elan/bin:$PATH"' | sudo -u $USER_NAME tee -a "$USER_HOME/.profile" >/dev/null
grep -q '.elan/bin' "$USER_HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.elan/bin:$PATH"' | sudo -u $USER_NAME tee -a "$USER_HOME/.bashrc" >/dev/null

log "sandboxed-node"
sudo install -m 0755 -o root -g root "$ORB_STAGE/sandboxed-node" /usr/local/bin/sandboxed-node
as_user mkdir -p "$USER_HOME/.orb/work"
chmod 700 "$USER_HOME/.orb"

log "orb-node.service (installed, not enabled)"
UID_N=$(id -u $USER_NAME)
sudo tee /etc/systemd/system/orb-node.service >/dev/null <<EOF
[Unit]
Description=Orb managed machine node (sandboxed-node, dial-out)
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Group=$USER_NAME
EnvironmentFile=$USER_HOME/.orb/enroll.env
WorkingDirectory=$USER_HOME
Environment=SANDBOXED_NODE_WORK_DIR=$USER_HOME/.orb/work
Environment=SANDBOXED_NODE_BIND=127.0.0.1:3088
Environment=PATH=$USER_HOME/.elan/bin:/usr/local/bin:$NODE_DIR/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=$USER_HOME
Environment=XDG_RUNTIME_DIR=/run/user/$UID_N
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_N/bus
Environment=DISABLE_AUTOUPDATER=1
ExecStart=/usr/local/bin/sandboxed-node
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl disable orb-node.service >/dev/null 2>&1 || true
sudo loginctl enable-linger $USER_NAME

log "manifest"
ver() { "$@" 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?' | head -1; }
sudo mkdir -p /etc/orb
python3 - "$ORB_STAGE/build-info.json" <<EOF | sudo tee /etc/orb/image-manifest.json >/dev/null
import json, sys, datetime
info = json.load(open(sys.argv[1]))
m = {
  "image": "orb-node-base",
  "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "recipe_sha": info.get("recipe_sha"),
  "node_version": info.get("node_version"),
  "harnesses": {
    "claude": "$(ver /usr/local/bin/claude --version)",
    "codex": "$(ver /usr/local/bin/codex --version)",
    "opencode": "$(ver /usr/local/bin/opencode --version)",
    "gemini": "$(ver /usr/local/bin/gemini --version)",
    "agy": "$(ver /usr/local/bin/agy --version)",
  },
  "lean": {"default_toolchain": "$LEAN_TOOLCHAIN", "lean": "$(as_user lean --version | head -1)",
           "lake": "$(as_user lake --version | head -1)", "elan": "$(ver as_user elan --version)"},
  "nodejs": "$NODEJS_VERSION",
  "tools": {
    "turbo-lean": "$(ver /usr/local/bin/turbo-lean --version)",
    "lean-native": "$(ver /usr/local/bin/lean-native --version)",
    "certified-search": (info.get("tools", {}).get("certified-search") or {}).get("commit"),
  },
  "tool_provenance": info.get("tools", {}),
  "os": "$(. /etc/os-release; echo "$PRETTY_NAME")",
  "arch": "x86_64",
}
print(json.dumps(m, indent=2, sort_keys=True))
EOF
sudo chmod 644 /etc/orb/image-manifest.json

log "cleanup (no secrets, no caches)"
sudo rm -rf /root/.npm "$USER_HOME/.npm" /root/.cache/* /tmp/npm-* 2>/dev/null || true
sudo apt-get clean
rm -rf "$ORB_STAGE"
log "done"
cat /etc/orb/image-manifest.json
