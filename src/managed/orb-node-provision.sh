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
install -d -m 1777 -o "$NODE_USER" -g "$NODE_USER" /tmp/opencode
if [ "$(stat -c '%U:%G' /tmp/opencode 2>/dev/null)" != "$NODE_USER:$NODE_USER" ]; then
  chown -R "$NODE_USER:$NODE_USER" /tmp/opencode
fi
mkdir -p /etc/tmpfiles.d
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

# 3. User-writable Rust toolchains & Boost guest env drop-in (systemd merges
#    orb-node.service.d/*.conf after orb-node.service).
mkdir -p /etc/systemd/system/orb-node.service.d
{
  echo "[Service]"
  echo "EnvironmentFile=-$NODE_HOME/.boost-env"
  echo "Environment=GIT_TERMINAL_PROMPT=0"
  echo "Environment=OPENCODE_TMPDIR=/tmp/opencode"
  if [ -x "$CACHES/cargo/bin/rustup" ]; then
    for d in "$CACHES/rustup" "$CACHES/cargo"; do
      if [ -d "$d" ] && [ "$(stat -c '%U:%G' "$d" 2>/dev/null)" != "$NODE_USER:$NODE_USER" ]; then
        chown -R "$NODE_USER:$NODE_USER" "$d"
      fi
    done
    echo "Environment=RUSTUP_HOME=$CACHES/rustup"
    echo "Environment=CARGO_HOME=$CACHES/cargo"
    echo "Environment=PATH=/opt/boost/bin:/opt/elan/bin:$CACHES/cargo/bin:$CACHES/elan/bin:$ORB_BIN:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  elif [ -d /opt/boost/bin ] || [ -f /etc/profile.d/boost-vm.sh ]; then
    echo "Environment=PATH=/opt/boost/bin:/opt/elan/bin:$ORB_BIN:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  fi
} > /etc/systemd/system/orb-node.service.d/10-orb-provision.conf
# 4. Ensure orb-node's job database schema is up to date before starting the
#    daemon (older snapshots / base images may hold a pre-cancellation_json
#    jobs.db or run a pre-baked binary whose open() ignored SQLITE_BUSY).
systemctl stop orb-node.service 2>/dev/null || true
for g in kvm video render; do usermod -aG "$g" "$NODE_USER" >/dev/null 2>&1 || true; done
install -d -m 0750 -o "$NODE_USER" -g "$NODE_USER" "$NODE_HOME" "$NODE_HOME/work"

# 5. Generic CoW/hardlink git-worktree helper for concurrent Lean/Lake sub-agents
#    sharing one warm VM (`orb-cow-worktree [src-repo] <dest-dir> [branch]`).
install -d -m 0755 /usr/local/bin
cat > /usr/local/bin/orb-cow-worktree <<'COWHELPER'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: orb-cow-worktree [src-repo] <dest-dir> [branch]" >&2
  exit 64
fi
if [ "$#" -eq 1 ]; then
  src="${BOOST_REPO_DIR:-/workspace/boost-cvm/lean-overlay/merged}"
  dest="$1"
  branch=""
elif [ -d "$1/.git" ] || [ -f "$1/.git" ]; then
  src="$1"
  dest="$2"
  branch="${3:-}"
else
  src="${BOOST_REPO_DIR:-/workspace/boost-cvm/lean-overlay/merged}"
  dest="$1"
  branch="${2:-}"
fi
if [ ! -e "$src/.git" ]; then
  echo "orb-cow-worktree: source git checkout not found at $src" >&2
  exit 66
fi
mkdir -p "$(dirname "$dest")"
if [ -n "$branch" ]; then
  git -C "$src" worktree add --force -B "$branch" "$dest" HEAD
else
  git -C "$src" worktree add --force --detach "$dest" HEAD
fi
if [ -d "$src/.lake" ]; then
  mkdir -p "$dest/.lake"
  if [ -d "$src/.lake/packages" ] && [ ! -e "$dest/.lake/packages" ]; then
    cp --reflink=auto -a "$src/.lake/packages" "$dest/.lake/packages" 2>/dev/null \
      || cp -a "$src/.lake/packages" "$dest/.lake/packages"
  fi
  if [ -d "$src/.lake/build" ] && [ ! -e "$dest/.lake/build" ]; then
    cp --reflink=auto -a "$src/.lake/build" "$dest/.lake/build" 2>/dev/null \
      || cp -al "$src/.lake/build" "$dest/.lake/build"
  fi
fi
printf '%s\n' "$dest"
COWHELPER
chmod 0755 /usr/local/bin/orb-cow-worktree

# 6. boost.ci guest environment & CoW warm checkout permissions: propagate
#    only Boost's guest variables + scoped cache-proxy token to orbnode (wiped
#    by SECRETS_WIPE before snapshots) and ensure warm overlay paths are readable.
rm -f "$NODE_HOME/.boost-env"
if [ -f /etc/profile.d/boost-vm.sh ] || [ -n "${BOOST_VM_ID:-}" ]; then
  (
    set +u
    [ -r /etc/profile.d/boost-vm.sh ] && . /etc/profile.d/boost-vm.sh
    [ -r /home/runner/.boost-env ] && . /home/runner/.boost-env
    for var in BOOST_VM_ID BOOST_LEAN_MODE BOOST_LEAN_SLOTS BOOST_REPO_DIR BOOST_BASE_KEY BOOST_CACHE_URL BOOST_CACHE_TOKEN ELAN_HOME; do
      val="${!var:-}"
      if [ -n "$val" ]; then
        clean=$(printf '%s' "$val" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '%s="%s"\n' "$var" "$clean"
      fi
    done
  ) > "$NODE_HOME/.boost-env.tmp"
  chmod 0600 "$NODE_HOME/.boost-env.tmp"
  chown "$NODE_USER:$NODE_USER" "$NODE_HOME/.boost-env.tmp"
  mv "$NODE_HOME/.boost-env.tmp" "$NODE_HOME/.boost-env"
  for p in /workspace /workspace/boost-cvm /workspace/boost-cvm/lean-overlay; do
    [ -d "$p" ] && chmod a+rx "$p" 2>/dev/null || true
  done
  for repo_dir in /workspace/repo /workspace/boost-cvm/lean-overlay/merged; do
    if [ -d "$repo_dir" ]; then
      chmod -R a+rX "$repo_dir" 2>/dev/null || true
      git config --system --add safe.directory "$repo_dir" 2>/dev/null || true
    fi
  done
  if [ -d /workspace/repo/.git ]; then
    # Allow orbnode to register detached git worktrees against the warm checkout.
    mkdir -p /workspace/repo/.git/worktrees 2>/dev/null || true
    chmod 1777 /workspace/repo/.git/worktrees 2>/dev/null || true
  fi
  if [ -d /workspace/boost-cvm/lean-overlay/merged/.git ]; then
    mkdir -p /workspace/boost-cvm/lean-overlay/merged/.git/worktrees 2>/dev/null || true
    chmod 1777 /workspace/boost-cvm/lean-overlay/merged/.git/worktrees 2>/dev/null || true
  fi
  mkdir -p /workspace/agents 2>/dev/null || true
  chmod 1777 /workspace/agents 2>/dev/null || true
fi

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

systemctl daemon-reload 2>/dev/null || true
echo "orb-provision ok ms=$(ms) rustup=$([ -x "$CACHES/cargo/bin/rustup" ] && echo yes || echo no)"
