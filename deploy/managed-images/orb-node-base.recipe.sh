#!/usr/bin/env bash
# orb-node-base image recipe (boat.dev managed machines).
#
# Runs INSIDE a fresh boat sandbox (Ubuntu 24.04 x86_64) as user `user` with
# passwordless sudo. Idempotent: re-running converges to the same state.
# Binding contract: ~/work/paloma/boat/CONTRACT.md ("Image orb-node-base").
#
# Security properties:
# - The node runs as the dedicated, unprivileged system account `orbnode`
#   (no sudo, not in sudo/adm). `user` keeps sudo for Core's boat exec calls.
# - Every downloaded or staged artifact is pinned by sha256 below and verified
#   before it is unpacked; any mismatch aborts the build. No self-updaters run.
#
# Inputs staged by scripts/managed_image.py (boat files API) in $ORB_STAGE:
#   sandboxed-node                Linux x86_64 binary (built in a boat sandbox);
#                                 its sha256 is passed in build-info.json
#   fleet-tools-x86_64.tar.gz     agy turbo-lean lean-native lean-native-core
#                                 research-governor research-governor-core
#                                 (x86_64 builds copied read-only from fleet host ashur)
#   certified-search.tar.gz       GitHub tarball of Th0rgal/certified-search (private)
#   build-info.json               {"node_version","node_sha256","recipe_sha","tools":{...}}
# The sandbox is created with noEnv: no GitHub or boat credentials, and this
# recipe never writes a secret into the image.
set -euo pipefail

ORB_STAGE=${ORB_STAGE:-/home/user/.orb-stage}
TOOLS=/opt/sandboxed-tools
NODE_USER=orbnode
NODE_HOME=/var/lib/orb-node
NODE_WORK=$NODE_HOME/work
# Shared Lean toolchain: root-owned, read-only for everyone (never on a writable path).
SHARED_ELAN=/opt/orb/elan
# sandboxed-node's Lean runner uses <work>/caches/elan as ELAN_HOME (src/node/lean.rs).
# It is orbnode-writable and appears ONLY in orb-node.service / orbnode's own env; its
# toolchain entry is a symlink into the read-only $SHARED_ELAN, so no download is needed.
ELAN_HOME_DIR=$NODE_WORK/caches/elan
# Boat's platform layer re-provisions some /usr/local/bin names (claude, ...) at every
# boot, so the image's pinned tools live in /opt/orb/bin, first on every PATH we control.
ORB_BIN=/opt/orb/bin

# ---------------------------------------------------------------- pins
CLAUDE_VERSION=2.1.306
CLAUDE_URL=https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-$CLAUDE_VERSION.tgz
CLAUDE_SHA256=20d4bced0c1cab2b608d5431188cbd0c141cf7074dafb49afbdac8c13006bb75
CODEX_VERSION=0.166.0
CODEX_URL=https://registry.npmjs.org/@openai/codex/-/codex-$CODEX_VERSION-linux-x64.tgz
CODEX_SHA256=cbc00a26d3d0e2ceefc4be8891f8a81ef1e349b3b175bc0ae308762bc001fd93
GEMINI_VERSION=0.65.0
GEMINI_URL=https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-$GEMINI_VERSION.tgz
GEMINI_SHA256=97f1f7f1e7e189054d27edfb9c62c6a45cec15b678840dfdde3c0ccd87fab376
OPENCODE_VERSION=1.19.3
OPENCODE_URL=https://github.com/anomalyco/opencode/releases/download/v$OPENCODE_VERSION/opencode-linux-x64-baseline.tar.gz
OPENCODE_SHA256=531cff2441129c30f0edd5878af494108ad07f5feb46d7ee29a2a5b830a5765d
NODEJS_VERSION=22.20.0
NODEJS_URL=https://nodejs.org/dist/v$NODEJS_VERSION/node-v$NODEJS_VERSION-linux-x64.tar.xz
NODEJS_SHA256=00bbd05e306ea68b6e13e17360d0e2f680b493ef95f2fea1c4296ff7437530bc
ELAN_VERSION=4.2.4
ELAN_URL=https://github.com/leanprover/elan/releases/download/v$ELAN_VERSION/elan-x86_64-unknown-linux-gnu.tar.gz
ELAN_SHA256=42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63
LEAN_VERSION=4.35.0
LEAN_TOOLCHAIN=leanprover/lean4:v$LEAN_VERSION
LEAN_URL=https://github.com/leanprover/lean4/releases/download/v$LEAN_VERSION/lean-$LEAN_VERSION-linux.tar.zst
LEAN_SHA256=7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d
RUSTUP_VERSION=1.28.2
RUSTUP_URL=https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu/rustup-init
RUSTUP_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
# Preinstalled toolchains (projects pin 1.93.0, e.g. ecdsafail-challenge).
RUST_TOOLCHAINS="stable 1.93.0"
CERTIFIED_SEARCH_COMMIT=967325bc3cd42ac20581e6140390a93e6877b03e
CERTIFIED_SEARCH_SHA256=f000c7a8fc5e240747511be546582a3b62335daccfb03a202b08dcd9aead717a
# Fleet builds copied from ashur:/usr/local/bin (agy 1.4.3; others built 2026-10-21).
declare -A FLEET_SHA256=(
  [agy]=d003c9d47e12f689d3448cad0f614289ccde5fb4c58bf8b4b543a9b514c097bc
  [turbo-lean]=bca7599edf07f545e7ca1e70779242124fe40ba237fa9141ea2fb6e4306e3dbf
  [lean-native]=d63e583a5bc70f0288ad3857a531c2bb29ac957c9363b8a1903a5d0a2aa36e28
  [lean-native-core]=ef83beae76e57df01a1ac6e9ee9cd8e2c6ad7dbc4bc7cc5117330ad9cdbcf4ac
  [research-governor]=8549b164ae5f9ae5c86c66cff0c99a2fdcdf96a2a3a963b043a8a8cd38e85b68
  [research-governor-core]=04f82545ea543317a72244dc3470bf26b8acf314c38fa9db48f8e43218e0c7d7
)

log() { printf '[recipe %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { echo "RECIPE ERROR: $*" >&2; exit 1; }
verify() { # file sha256
  local got; got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$2" ] || die "sha256 mismatch for $1: expected $2, got $got"
}
fetch() { # url sha256 dest  (download unprivileged, verify, then use)
  curl -fsSL --proto '=https' --retry 3 "$1" -o "$3"
  verify "$3" "$2"
}
as_node() { sudo -u "$NODE_USER" -H env HOME="$NODE_HOME" ELAN_HOME="$ELAN_HOME_DIR" \
  PATH="$ELAN_HOME_DIR/bin:$ORB_BIN:/usr/local/bin:/usr/bin:/bin" "$@"; }

[ "$(uname -m)" = x86_64 ] || die "x86_64 only"
for f in sandboxed-node sandboxed-mcp fleet-tools-x86_64.tar.gz certified-search.tar.gz build-info.json; do
  [ -s "$ORB_STAGE/$f" ] || die "missing staged input $ORB_STAGE/$f"
done
NODE_BIN_SHA256=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["node_sha256"])' "$ORB_STAGE/build-info.json")
verify "$ORB_STAGE/sandboxed-node" "$NODE_BIN_SHA256"
MCP_BIN_SHA256=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mcp_sha256"])' "$ORB_STAGE/build-info.json")
verify "$ORB_STAGE/sandboxed-mcp" "$MCP_BIN_SHA256"
verify "$ORB_STAGE/certified-search.tar.gz" "$CERTIFIED_SEARCH_SHA256"
DL=$(mktemp -d)   # owned by user; root only reads verified files from it
trap 'rm -rf "$DL"' EXIT

log "apt base packages (signed Ubuntu archive)"
export DEBIAN_FRONTEND=noninteractive
need=()
# gh, ripgrep, fd, clang/llvm/lld: used by most missions (boat review 2026-10-24).
for p in curl ca-certificates git jq xz-utils zstd tar gzip python3 build-essential libssl3 dbus-user-session \
         gh ripgrep fd-find clang llvm lld pkg-config libssl-dev; do
  dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ ${#need[@]} -gt 0 ]; then
  sudo apt-get update -qq || true
  sudo apt-get install -y -qq --no-install-recommends "${need[@]}"
fi

log "system PATH dirs root-owned (boat's base image ships /usr/local/* owned by user)"
PATH_DIRS="/usr/local/bin /usr/local/sbin /usr/local/games /usr/local/cargo/bin"
for d in $PATH_DIRS; do [ -d "$d" ] && sudo chown root:root "$d" && sudo chmod go-w "$d"; done

log "service account $NODE_USER"
if ! id "$NODE_USER" >/dev/null 2>&1; then
  sudo useradd --system --home-dir "$NODE_HOME" --create-home --shell /bin/bash "$NODE_USER"
fi
for g in sudo adm admin wheel docker lxd; do sudo gpasswd -d "$NODE_USER" "$g" >/dev/null 2>&1 || true; done
sudo rm -f "/etc/sudoers.d/$NODE_USER"
sudo install -d -m 0750 -o "$NODE_USER" -g "$NODE_USER" "$NODE_HOME" "$NODE_WORK" "$NODE_WORK/caches"
sudo loginctl enable-linger "$NODE_USER"
# Core writes enroll.env here; PID1 (root) reads it for EnvironmentFile=, orbnode must not.
install -d -m 0700 /home/user/.orb
chmod 0700 /home/user/.orb
sudo chmod 0750 /home/user

sudo install -d -m 0755 "$ORB_BIN"

log "node.js $NODEJS_VERSION (runtime for gemini)"
NODE_DIR=$TOOLS/node/$NODEJS_VERSION
if [ ! -x "$NODE_DIR/bin/node" ]; then
  fetch "$NODEJS_URL" "$NODEJS_SHA256" "$DL/node.tar.xz"
  sudo mkdir -p "$NODE_DIR"
  sudo tar -xJf "$DL/node.tar.xz" -C "$NODE_DIR" --strip-components=1 --no-same-owner
fi
for b in node npm npx; do sudo ln -sfn "$NODE_DIR/bin/$b" $ORB_BIN/$b; done

log "harness: claude $CLAUDE_VERSION (native binary from npm platform package)"
d=$TOOLS/claude/$CLAUDE_VERSION
if [ ! -x "$d/claude" ]; then
  fetch "$CLAUDE_URL" "$CLAUDE_SHA256" "$DL/claude.tgz"
  sudo mkdir -p "$d"
  sudo tar -xzf "$DL/claude.tgz" -C "$d" --strip-components=1 --no-same-owner package/claude
  sudo chmod 755 "$d/claude"
fi
sudo ln -sfn "$d/claude" $ORB_BIN/claude

log "harness: codex $CODEX_VERSION (native binary from npm platform package)"
d=$TOOLS/codex/$CODEX_VERSION
if [ ! -x "$d/vendor/x86_64-unknown-linux-musl/bin/codex" ]; then
  fetch "$CODEX_URL" "$CODEX_SHA256" "$DL/codex.tgz"
  sudo mkdir -p "$d"
  sudo tar -xzf "$DL/codex.tgz" -C "$d" --strip-components=1 --no-same-owner
fi
sudo tee $ORB_BIN/codex >/dev/null <<EOF
#!/bin/sh
# codex $CODEX_VERSION: same layout bin/codex.js uses (vendored rg on PATH).
V=$d/vendor/x86_64-unknown-linux-musl
PATH="\$V/codex-path:\$PATH" CODEX_MANAGED_BY_NPM=1 exec "\$V/bin/codex" "\$@"
EOF
sudo chmod 755 $ORB_BIN/codex

log "harness: gemini $GEMINI_VERSION (self-contained bundle)"
d=$TOOLS/gemini/$GEMINI_VERSION
if [ ! -f "$d/bundle/gemini.js" ]; then
  fetch "$GEMINI_URL" "$GEMINI_SHA256" "$DL/gemini.tgz"
  sudo mkdir -p "$d"
  sudo tar -xzf "$DL/gemini.tgz" -C "$d" --strip-components=1 --no-same-owner
fi
sudo tee $ORB_BIN/gemini >/dev/null <<EOF
#!/bin/sh
exec $NODE_DIR/bin/node --no-warnings=DEP0040 $d/bundle/gemini.js "\$@"
EOF
sudo chmod 755 $ORB_BIN/gemini

log "harness: opencode $OPENCODE_VERSION"
d=$TOOLS/opencode/$OPENCODE_VERSION
if [ ! -x "$d/opencode" ]; then
  fetch "$OPENCODE_URL" "$OPENCODE_SHA256" "$DL/oc.tgz"
  sudo mkdir -p "$d"
  sudo tar -xzf "$DL/oc.tgz" -C "$d" --no-same-owner opencode
  sudo chmod 755 "$d/opencode"
fi
sudo ln -sfn "$d/opencode" $ORB_BIN/opencode

log "fleet tools: agy, turbo-lean, lean-native, research-governor (pinned sha256)"
mkdir -p "$DL/fleet"
tar -xzf "$ORB_STAGE/fleet-tools-x86_64.tar.gz" -C "$DL/fleet" --no-same-owner
for b in "${!FLEET_SHA256[@]}"; do
  verify "$DL/fleet/$b" "${FLEET_SHA256[$b]}"
done
for b in "${!FLEET_SHA256[@]}"; do
  sudo install -m 0755 -o root -g root "$DL/fleet/$b" "$ORB_BIN/$b"
done
# No `agy update`: self-updaters never run in the image build.

log "certified-search $CERTIFIED_SEARCH_COMMIT source + CLI"
sudo rm -rf /opt/certified-search.new && sudo mkdir -p /opt/certified-search.new
sudo tar -xzf "$ORB_STAGE/certified-search.tar.gz" -C /opt/certified-search.new --strip-components=1 --no-same-owner
echo "$CERTIFIED_SEARCH_COMMIT" | sudo tee /opt/certified-search.new/COMMIT >/dev/null
sudo rm -rf /opt/certified-search && sudo mv /opt/certified-search.new /opt/certified-search
sudo chmod -R a+rX,go-w /opt/certified-search
sudo tee $ORB_BIN/certified-search >/dev/null <<'EOF'
#!/bin/sh
# certified-search (Th0rgal/certified-search) CLI: the research-governor sidecar.
exec /opt/orb/bin/research-governor "$@"
EOF
sudo chmod 755 $ORB_BIN/certified-search

log "elan $ELAN_VERSION + Lean $LEAN_VERSION, shared read-only at $SHARED_ELAN (root)"
fetch "$ELAN_URL" "$ELAN_SHA256" "$DL/elan.tgz"
mkdir -p "$DL/elan" && tar -xzf "$DL/elan.tgz" -C "$DL/elan"
chmod 0755 "$DL" "$DL/elan" && chmod 0755 "$DL/elan/elan-init"
if [ ! -x "$SHARED_ELAN/bin/elan" ]; then
  sudo env ELAN_HOME="$SHARED_ELAN" HOME=/root "$DL/elan/elan-init" -y --no-modify-path --default-toolchain none
fi
TC_NAME=leanprover--lean4---v$LEAN_VERSION
TC_DIR=$SHARED_ELAN/toolchains/$TC_NAME
if [ ! -x "$TC_DIR/bin/lean" ]; then
  fetch "$LEAN_URL" "$LEAN_SHA256" "$DL/lean.tar.zst"
  sudo rm -rf "$TC_DIR.tmp" && sudo mkdir -p "$TC_DIR.tmp"
  sudo tar --zstd -xf "$DL/lean.tar.zst" -C "$TC_DIR.tmp" --strip-components=1 --no-same-owner
  sudo mv "$TC_DIR.tmp" "$TC_DIR"
fi
sudo env ELAN_HOME="$SHARED_ELAN" HOME=/root "$SHARED_ELAN/bin/elan" default "$LEAN_TOOLCHAIN"
sudo chown -R root:root "$SHARED_ELAN"
sudo chmod -R u+rwX,go+rX,go-w "$SHARED_ELAN"
# Wrappers on the global PATH pin ELAN_HOME to the read-only tree (no env export needed).
for b in "$SHARED_ELAN"/bin/*; do
  n=$(basename "$b")
  printf '#!/bin/sh\nELAN_HOME=%s exec %s "$@"\n' "$SHARED_ELAN" "$b" | sudo tee "$ORB_BIN/$n" >/dev/null
  sudo chmod 755 "$ORB_BIN/$n"
done
"$ORB_BIN/lean" --version | grep -qF "version $LEAN_VERSION" || die "shared lean toolchain not active"

log "orbnode job ELAN_HOME $ELAN_HOME_DIR (toolchain symlinked read-only)"
if ! as_node test -x "$ELAN_HOME_DIR/bin/elan"; then
  as_node "$DL/elan/elan-init" -y --no-modify-path --default-toolchain none
fi
as_node mkdir -p "$ELAN_HOME_DIR/toolchains"
as_node ln -sfn "$TC_DIR" "$ELAN_HOME_DIR/toolchains/$TC_NAME"
as_node elan default "$LEAN_TOOLCHAIN"
as_node lean --version | grep -qF "version $LEAN_VERSION" || die "orbnode lean toolchain not active"
log "rustup $RUSTUP_VERSION, orbnode-writable under $NODE_WORK/caches ($RUST_TOOLCHAINS)"
# fd-find ships as fdfind on Ubuntu.
[ -x /usr/bin/fdfind ] && sudo ln -sfn /usr/bin/fdfind "$ORB_BIN/fd"
RUSTUP_HOME_DIR=$NODE_WORK/caches/rustup
CARGO_HOME_DIR=$NODE_WORK/caches/cargo
fetch "$RUSTUP_URL" "$RUSTUP_SHA256" "$DL/rustup-init"
chmod 0755 "$DL/rustup-init"
as_rust() { as_node env RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" \
  PATH="$CARGO_HOME_DIR/bin:$ORB_BIN:/usr/local/bin:/usr/bin:/bin" "$@"; }
if ! as_rust test -x "$CARGO_HOME_DIR/bin/rustup"; then
  as_rust "$DL/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
fi
for tc in $RUST_TOOLCHAINS; do
  as_rust rustup toolchain install "$tc" --profile minimal -c clippy -c rustfmt
done
as_rust rustup default stable
as_rust cargo --version >/dev/null || die "orbnode cargo not usable"

sudo rm -f /etc/profile.d/orb-elan.sh
sudo tee /etc/profile.d/orb-path.sh >/dev/null <<EOF
# Pinned image tools (root-owned, not group/other-writable).
case ":\$PATH:" in *":$ORB_BIN:"*) ;; *) export PATH="$ORB_BIN:\$PATH";; esac
EOF
sudo chmod 644 /etc/profile.d/orb-path.sh

log "auto-update off (global)"
sudo tee /etc/profile.d/orb-no-autoupdate.sh >/dev/null <<'EOF'
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTOUPDATE=1 CODEX_DISABLE_UPDATE_CHECK=1 NO_UPDATE_NOTIFIER=1
EOF
sudo chmod 644 /etc/profile.d/orb-no-autoupdate.sh
for kv in DISABLE_AUTOUPDATER=1 NO_UPDATE_NOTIFIER=1; do
  grep -qx "$kv" /etc/environment 2>/dev/null || echo "$kv" | sudo tee -a /etc/environment >/dev/null
done

log "sandboxed-node + sandboxed-mcp"
sudo install -m 0755 -o root -g root "$ORB_STAGE/sandboxed-node" $ORB_BIN/sandboxed-node
sudo install -m 0755 -o root -g root "$ORB_STAGE/sandboxed-mcp" $ORB_BIN/sandboxed-mcp
# Core hard-codes /usr/local/bin/sandboxed-mcp for remote harness jobs; boat rewrites
# /usr/local/bin at boot, so orb-boot.service and orb-node's ExecStartPre recreate the link.
sudo ln -sfn $ORB_BIN/sandboxed-mcp /usr/local/bin/sandboxed-mcp

log "orb-node.service (installed, not enabled)"
UID_N=$(id -u $NODE_USER)
sudo tee /etc/systemd/system/orb-node.service >/dev/null <<EOF
[Unit]
Description=Orb managed machine node (sandboxed-node, dial-out)
After=network-online.target
Wants=network-online.target

[Service]
User=$NODE_USER
Group=$NODE_USER
# Read by PID1 as root; /home/user/.orb is 0700 user so $NODE_USER cannot read it.
EnvironmentFile=/home/user/.orb/enroll.env
WorkingDirectory=$NODE_HOME
Environment=SANDBOXED_NODE_WORK_DIR=$NODE_WORK
Environment=SANDBOXED_NODE_BIND=127.0.0.1:3088
Environment=PATH=$CARGO_HOME_DIR/bin:$ELAN_HOME_DIR/bin:$ORB_BIN:$NODE_DIR/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=RUSTUP_HOME=$RUSTUP_HOME_DIR
Environment=CARGO_HOME=$CARGO_HOME_DIR
Environment=GIT_TERMINAL_PROMPT=0
Environment=HOME=$NODE_HOME
Environment=ELAN_HOME=$ELAN_HOME_DIR
Environment=XDG_RUNTIME_DIR=/run/user/$UID_N
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_N/bus
Environment=DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTOUPDATE=1 CODEX_DISABLE_UPDATE_CHECK=1 NO_UPDATE_NOTIFIER=1
NoNewPrivileges=true
# Boat resets /var/lib/systemd/linger on boot: re-enable linger and wait for the user bus.
ExecStartPre=+/bin/ln -sfn $ORB_BIN/sandboxed-mcp /usr/local/bin/sandboxed-mcp
ExecStartPre=+/bin/sh -c 'loginctl enable-linger $NODE_USER; for i in \$\$(seq 100); do [ -S /run/user/$UID_N/bus ] && exit 0; sleep 0.2; done; echo user bus missing >&2; exit 1'
ExecStart=$ORB_BIN/sandboxed-node
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl disable orb-linger.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/orb-linger.service
sudo tee /etc/systemd/system/orb-boot.service >/dev/null <<EOF
[Unit]
Description=Orb image boot fixups (boat resets linger and parts of /usr/local/bin at boot)
After=systemd-logind.service local-fs.target
Before=orb-node.service
[Service]
Type=oneshot
ExecStart=/usr/bin/loginctl enable-linger $NODE_USER
ExecStart=/bin/sh -c 'for d in $PATH_DIRS; do [ -d "\$\$d" ] && chown root:root "\$\$d" && chmod go-w "\$\$d"; done; true'
ExecStart=/bin/ln -sfn $ORB_BIN/sandboxed-mcp /usr/local/bin/sandboxed-mcp
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable orb-boot.service >/dev/null 2>&1
sudo systemctl disable orb-node.service >/dev/null 2>&1 || true

log "convenience links in /usr/local/bin (boat may override platform names at boot)"
for b in "$ORB_BIN"/*; do
  n=$(basename "$b"); if [ -e "/usr/local/bin/$n" ] && [ ! -L "/usr/local/bin/$n" ]; then continue; fi
  sudo ln -sfn "$b" "/usr/local/bin/$n"
done

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
  "node_sha256": info.get("node_sha256"),
  "mcp_sha256": info.get("mcp_sha256"),
  "node_user": "$NODE_USER",
  "harnesses": {
    "claude": "$(ver as_node $ORB_BIN/claude --version)",
    "codex": "$(ver as_node $ORB_BIN/codex --version)",
    "opencode": "$(ver as_node $ORB_BIN/opencode --version)",
    "gemini": "$(ver as_node $ORB_BIN/gemini --version)",
    "agy": "$(ver as_node $ORB_BIN/agy --version)",
  },
  "lean": {"default_toolchain": "$LEAN_TOOLCHAIN", "elan_home": "$SHARED_ELAN", "node_job_elan_home": "$ELAN_HOME_DIR",
           "lean": "$(as_node lean --version | head -1)", "lake": "$(as_node lake --version | head -1)",
           "elan": "$(ver as_node elan --version)"},
  "nodejs": "$NODEJS_VERSION",
  "tools": {
    "turbo-lean": "$(ver $ORB_BIN/turbo-lean --version)",
    "lean-native": "$(ver $ORB_BIN/lean-native --version)",
    "certified-search": "$CERTIFIED_SEARCH_COMMIT",
    "rustup": "$(ver as_rust rustup --version)",
    "rust_toolchains": "$RUST_TOOLCHAINS",
    "gh": "$(ver gh --version)", "rg": "$(ver rg --version)", "clang": "$(ver clang --version)",
  },
  "pins_sha256": {
    "claude": "$CLAUDE_SHA256", "codex": "$CODEX_SHA256", "gemini": "$GEMINI_SHA256",
    "opencode": "$OPENCODE_SHA256", "nodejs": "$NODEJS_SHA256", "elan": "$ELAN_SHA256",
    "lean": "$LEAN_SHA256", "rustup-init": "$RUSTUP_SHA256", "certified-search": "$CERTIFIED_SEARCH_SHA256",
    $(for b in "${!FLEET_SHA256[@]}"; do printf '"%s": "%s", ' "$b" "${FLEET_SHA256[$b]}"; done)
  },
  "tool_provenance": info.get("tools", {}),
  "os": "$(. /etc/os-release; echo "$PRETTY_NAME")",
  "arch": "x86_64",
}
print(json.dumps(m, indent=2, sort_keys=True))
EOF
sudo chmod 644 /etc/orb/image-manifest.json

log "cleanup (no secrets, no caches)"
sudo rm -rf /root/.npm /home/user/.npm "$NODE_HOME/.cache" /root/.cache/* 2>/dev/null || true
sudo apt-get clean
rm -rf "$ORB_STAGE"
log "done"
cat /etc/orb/image-manifest.json
