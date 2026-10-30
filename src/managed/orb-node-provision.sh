#!/usr/bin/env bash
# Per-VM provisioning for orb-node-base, run by Core (src/managed/mod.rs,
# `provision`) as root right before orb-node starts. Must stay fast (< 5 s)
# and idempotent: heavy installs belong in orb-node-base.recipe.sh.
# Never writes or prints a secret.
set -euo pipefail
NODE_USER=orbnode
NODE_HOME=/var/lib/orb-node
CACHES=$NODE_HOME/work/caches
ORB_BIN=/opt/orb/bin
t0=$(date +%s%N)
ms() { echo $(( ($(date +%s%N) - t0) / 1000000 )); }

# 1. opencode's scratch dir must be writable by the node user (boat's base
#    creates it as user:user 0775, so every first clone failed).
install -d -m 1777 /tmp/opencode
chown -R "$NODE_USER:$NODE_USER" /tmp/opencode
echo "d /tmp/opencode 1777 $NODE_USER $NODE_USER -" > /etc/tmpfiles.d/orb-opencode.conf

# 2. GitHub over https with the token Core delivers to the mission (never
#    stored by this script). Scoped to github.com; ssh URLs are rewritten.
install -d -m 0755 "$ORB_BIN"
cat > "$ORB_BIN/git-credential-orb" <<'HELPER'
#!/bin/sh
# git credential helper: answers only `get` for https://github.com with the
# mission's GitHub token (paloma-secrets file Core delivered, else
# GITHUB_TOKEN / GH_TOKEN). Prints nothing for any other host.
[ "$1" = get ] || exit 0
proto= host=
while IFS='=' read -r k v; do
  [ -z "$k" ] && break
  case "$k" in protocol) proto=$v;; host) host=$v;; esac
done
[ "$proto" = https ] && [ "$host" = github.com ] || exit 0
mission=$(printf %s "${SANDBOXED_SH_MISSION_ID:-${MISSION_ID:-session}}" | tr '/.' '__')
token=
for f in "${SANDBOXED_SECRETS_DIR:+$SANDBOXED_SECRETS_DIR/GITHUB_TOKEN}" \
         "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/paloma-secrets/$mission/GITHUB_TOKEN}" \
         "${HOME:+$HOME/.paloma-secrets/$mission/GITHUB_TOKEN}"; do
  [ -n "$f" ] && [ -r "$f" ] && token=$(head -n1 "$f") && [ -n "$token" ] && break
done
[ -n "$token" ] || token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
[ -n "$token" ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$token"
HELPER
chmod 0755 "$ORB_BIN/git-credential-orb"
git config --system --replace-all credential.https://github.com.helper "$ORB_BIN/git-credential-orb"
git config --system --unset-all url.https://github.com/.insteadOf 2>/dev/null || true
git config --system --add url.https://github.com/.insteadOf git@github.com:
git config --system --add url.https://github.com/.insteadOf ssh://git@github.com/

# 3. User-writable Rust toolchains (the image installs them under $CACHES;
#    boat's root-owned /usr/local/rustup made `rustup toolchain install` fail).
mkdir -p /etc/systemd/system/orb-node.service.d
{
  echo "[Service]"
  echo "Environment=GIT_TERMINAL_PROMPT=0"
  echo "Environment=OPENCODE_TMPDIR=/tmp/opencode"
  if [ -x "$CACHES/cargo/bin/rustup" ]; then
    chown -R "$NODE_USER:$NODE_USER" "$CACHES/rustup" "$CACHES/cargo"
    echo "Environment=RUSTUP_HOME=$CACHES/rustup"
    echo "Environment=CARGO_HOME=$CACHES/cargo"
    echo "Environment=PATH=$CACHES/cargo/bin:$CACHES/elan/bin:$ORB_BIN:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  fi
} > /etc/systemd/system/orb-node.service.d/10-orb-provision.conf
# 4. Ensure orb-node's job database schema is up to date before starting the
#    daemon (older snapshots / base images may hold a pre-cancellation_json
#    jobs.db or run a pre-baked binary whose open() ignored SQLITE_BUSY).
systemctl stop orb-node.service 2>/dev/null || true
install -d -m 0750 -o "$NODE_USER" -g "$NODE_USER" "$NODE_HOME" "$NODE_HOME/work"
python3 - "$NODE_HOME/work/jobs.db" <<'PY'
import sqlite3, sys
db_path = sys.argv[1]
conn = sqlite3.connect(db_path, timeout=10.0)
conn.execute("PRAGMA journal_mode = WAL")
conn.execute(
    "CREATE TABLE IF NOT EXISTS jobs ("
    "id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, payload_json TEXT NOT NULL, "
    "state TEXT NOT NULL, exit_code INTEGER, created_at TEXT NOT NULL, "
    "started_at TEXT, finished_at TEXT, log_path TEXT, error TEXT, "
    "artifacts_json TEXT, cancellation_json TEXT)"
)
cols = {r[1] for r in conn.execute("PRAGMA table_info(jobs)")}
for col in ("artifacts_json", "cancellation_json"):
    if col not in cols:
        conn.execute(f"ALTER TABLE jobs ADD COLUMN {col} TEXT")
conn.commit()
conn.close()
PY
chown "$NODE_USER:$NODE_USER" "$NODE_HOME/work/jobs.db"* 2>/dev/null || true

systemctl daemon-reload
echo "orb-provision ok ms=$(ms) rustup=$([ -x "$CACHES/cargo/bin/rustup" ] && echo yes || echo no)"
