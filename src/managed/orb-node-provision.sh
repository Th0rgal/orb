#!/usr/bin/env bash
# Per-VM provisioning for orb-node-base, run by Core (src/managed/mod.rs,
# `provision`) as root right before orb-node starts. Must stay fast (< 5 s)
# and idempotent: heavy installs belong in orb-node-base.recipe.sh.
# Never writes or prints a secret.
set -euo pipefail
cd /
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

# 1b. Non-systemd supervisor launcher invoked by cloud_bootstrap_script when
#     /run/systemd/system is absent (e.g. Vast.ai containers, boost.ci init).
#     Keeping this helper here preserves Vast.ai's 4 KiB onstart script budget.
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/orb-node-bg <<'ORBBG'
#!/usr/bin/env bash
set -eu
P="${1:-/opt/boost/bin:/opt/elan/bin:/opt/orb/bin:/usr/local/bin:/usr/local/cuda/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/conda/bin}"
E="${2:-OPENCODE_TMPDIR=/tmp/opencode GIT_TERMINAL_PROMPT=0 DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTOUPDATE=1 CODEX_DISABLE_UPDATE_CHECK=1 NO_UPDATE_NOTIFIER=1}"
H=/var/lib/orb-node
O=/home/user/.orb
B=/usr/local/bin
L="${LD_LIBRARY_PATH:-/usr/lib64-nvidia:/usr/local/nvidia/lib:/usr/local/nvidia/lib64}:/usr/lib64-nvidia:/usr/local/cuda/lib64"
# Preserve Colab TPU/GPU runtime env vars (COLAB_*, TPU_*, PJRT_*) when present.
C_ENV=$(env | grep -E '^(COLAB_|TPU_|PJRT_|NVIDIA_|CUDA_)[A-Z0-9_]*=' | tr '\n' ' ' || true)
if pgrep -u orbnode -x sandboxed-node >/dev/null 2>&1; then
  exit 0
fi
nohup bash -c "set -a; . \"$O/enroll.env\"; [ ! -r /etc/orb/boost-env ] || . /etc/orb/boost-env; set +a; cd \"$H\"; while :; do runuser -u orbnode -- env HOME=\"$H\" PATH=\"$P\" LD_LIBRARY_PATH=\"$L\" $C_ENV $E \"$B/sandboxed-node\" || :; sleep 2; done" </dev/null >"$H/orb-node.log" 2>&1 &
ORBBG
chmod 0755 /usr/local/sbin/orb-node-bg

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
  echo "EnvironmentFile=-/etc/orb/boost-env"
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

# 5. Generic CoW git-worktree helper for concurrent Lean/Lake sub-agents sharing
#    one warm VM (`orb-cow-worktree [src-repo] <dest-dir> [branch]`). On boost.ci
#    warm VMs, delegates overlay mounting to `/run/orb-cow-worktree/sock` so
#    unprivileged `orbnode` (`NoNewPrivileges=true`) gets 4 ms kernel CoW isolation
#    over `/opt/boost/warm-orb` without recursive copies or cross-agent `.olean`
#    mutation; falls back to `git worktree add` + `cp --reflink=auto` elsewhere.
install -d -m 0755 /usr/local/bin /usr/local/sbin
cat > /usr/local/bin/orb-cow-worktree <<'COWHELPER'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: orb-cow-worktree [src-repo] <dest-dir> [branch]" >&2
  exit 64
fi
explicit_src=""
if [ "$#" -eq 1 ]; then
  src="${BOOST_WARM_REPO_DIR:-${BOOST_REPO_DIR:-/workspace/boost-cvm/lean-overlay/merged}}"
  dest="$1"
  branch=""
elif [ -d "$1/.git" ] || [ -f "$1/.git" ]; then
  explicit_src="$1"
  src="$1"
  dest="$2"
  branch="${3:-}"
else
  src="${BOOST_WARM_REPO_DIR:-${BOOST_REPO_DIR:-/workspace/boost-cvm/lean-overlay/merged}}"
  dest="$1"
  branch="${2:-}"
fi
mkdir -p "$(dirname "$dest")"
dest_abs="$(cd "$(dirname "$dest")" && pwd)/$(basename "$dest")"
use_overlay=0
if [ -S /run/orb-cow-worktree/sock ]; then
  if [ -z "$explicit_src" ]; then
    use_overlay=1
  else
    src_abs="$(cd "$explicit_src" && pwd)"
    case "$src_abs" in
      /workspace/boost-cvm/lean-overlay/merged|/opt/boost/warm-orb|/opt/boost/warm-lower|/workspace/repo)
        use_overlay=1
        ;;
    esac
  fi
fi
if [ "$use_overlay" = 1 ]; then
  if python3 - "$dest_abs" <<'PY'
import json, socket, sys
dest = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30.0)
s.connect("/run/orb-cow-worktree/sock")
s.sendall((json.dumps({"dest": dest}) + "\n").encode("utf-8"))
buf = b""
while not buf.endswith(b"\n") and len(buf) < 4096:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
s.close()
resp = json.loads(buf.decode("utf-8") or "{}")
if not resp.get("ok"):
    sys.stderr.write(f"orb-cow-worktree overlay helper: {resp.get('error', 'failed')}\n")
    sys.exit(1)
PY
  then
    head_rev=$(git -C "$dest_abs" rev-parse HEAD)
    if [ -n "$branch" ]; then
      git -C "$dest_abs" update-ref "refs/heads/$branch" "$head_rev"
      git -C "$dest_abs" symbolic-ref HEAD "refs/heads/$branch"
    else
      git -C "$dest_abs" update-ref --no-deref HEAD "$head_rev"
    fi
    printf '%s\n' "$dest_abs"
    exit 0
  fi
fi
if [ ! -e "$src/.git" ]; then
  echo "orb-cow-worktree: source git checkout not found at $src" >&2
  exit 66
fi
if [ -n "$branch" ]; then
  git -C "$src" worktree add --force -B "$branch" "$dest_abs" HEAD
else
  git -C "$src" worktree add --force --detach "$dest_abs" HEAD
fi
if [ -d "$src/.lake" ]; then
  mkdir -p "$dest_abs/.lake"
  if [ -d "$src/.lake/packages" ] && [ ! -e "$dest_abs/.lake/packages" ]; then
    cp --reflink=auto -a "$src/.lake/packages" "$dest_abs/.lake/packages" 2>/dev/null \
      || cp -a "$src/.lake/packages" "$dest_abs/.lake/packages"
  fi
  if [ -d "$src/.lake/build" ] && [ ! -e "$dest_abs/.lake/build" ]; then
    cp --reflink=auto -a "$src/.lake/build" "$dest_abs/.lake/build" 2>/dev/null \
      || cp -a "$src/.lake/build" "$dest_abs/.lake/build"
  fi
  rm -f "$dest_abs/.lake/"*.lock "$dest_abs/.lake/build/"*.lock 2>/dev/null || true
fi
printf '%s\n' "$dest_abs"
COWHELPER
chmod 0755 /usr/local/bin/orb-cow-worktree

# 6. boost.ci guest environment & CoW warm checkout permissions: propagate
#    only Boost's guest variables + scoped cache-proxy token to orbnode (wiped
#    by SECRETS_WIPE before snapshots). Rename BOOST_REPO_DIR -> BOOST_WARM_REPO_DIR
#    so `/opt/boost/bin/lake` builds `$PWD` inside sub-agent worktrees instead of
#    forcing `--project-dir /workspace/boost-cvm/lean-overlay/merged`. Never run
#    `chmod -R` across overlayfs (77 GiB metadata copy-up); instead VFS-idmap
#    `/opt/boost/warm-lower` to `orbnode` at `/opt/boost/warm-orb` in O(1) time.
rm -f "$NODE_HOME/.boost-env" /etc/orb/boost-env /etc/profile.d/zz-orb-boost.sh
if [ -f /etc/profile.d/boost-vm.sh ] || [ -n "${BOOST_VM_ID:-}" ]; then
  install -d -m 0750 -o root -g "$NODE_USER" /etc/orb
  (
    set +u
    [ -r /etc/profile.d/boost-vm.sh ] && . /etc/profile.d/boost-vm.sh
    [ -r /home/runner/.boost-env ] && . /home/runner/.boost-env
    for var in BOOST_VM_ID BOOST_LEAN_MODE BOOST_LEAN_SLOTS BOOST_BASE_KEY BOOST_CACHE_URL BOOST_CACHE_TOKEN ELAN_HOME; do
      val="${!var:-}"
      if [ -n "$val" ]; then
        clean=$(printf '%s' "$val" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '%s="%s"\n' "$var" "$clean"
      fi
    done
    if [ -n "${BOOST_REPO_DIR:-}" ]; then
      clean=$(printf '%s' "$BOOST_REPO_DIR" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf 'BOOST_WARM_REPO_DIR="%s"\n' "$clean"
    fi
  ) > /etc/orb/boost-env.tmp
  chown "root:$NODE_USER" /etc/orb/boost-env.tmp
  chmod 0640 /etc/orb/boost-env.tmp
  mv /etc/orb/boost-env.tmp /etc/orb/boost-env
  # sandboxed-node launches remote jobs with env_clear() + HOME=<job-cwd> via
  # `bash -lc`, which sources /etc/profile.d/boost-vm.sh (setting BOOST_REPO_DIR
  # and checking $HOME/.boost-env under the wrong HOME). Run after boost-vm.sh
  # for orbnode shells only, reading root-owned /etc/orb/boost-env so mission
  # processes can never tamper with sourced profile content.
  cat > /etc/profile.d/zz-orb-boost.sh <<'ORBBOOSTPROFILE'
if [ "$(id -un 2>/dev/null)" = "orbnode" ] && [ -r /etc/orb/boost-env ]; then
  set -a
  . /etc/orb/boost-env
  set +a
  unset BOOST_REPO_DIR
fi
ORBBOOSTPROFILE
  chmod 0644 /etc/profile.d/zz-orb-boost.sh

  for p in /workspace /workspace/boost-cvm /workspace/boost-cvm/lean-overlay /workspace/repo /workspace/boost-cvm/lean-overlay/merged /opt/boost /opt/boost/warm-lower; do
    [ -d "$p" ] && chmod a+rx "$p" 2>/dev/null || true
  done
  mkdir -p /workspace/agents 2>/dev/null || true
  chmod 1777 /workspace/agents 2>/dev/null || true

  if [ -d /opt/boost/warm-lower ]; then
    uid_n=$(id -u "$NODE_USER")
    gid_n=$(id -g "$NODE_USER")
    warm_src=$(readlink -f /opt/boost/warm-lower 2>/dev/null || printf '/opt/boost/warm-lower')
    probe_path="$warm_src"
    for cand in "$warm_src/.lake" "$warm_src/.git"; do
      if [ -e "$cand" ]; then
        probe_path="$cand"
        break
      fi
    done
    uid_b=$(stat -Lc '%u' "$probe_path")
    gid_b=$(stat -Lc '%g' "$probe_path")
    mkdir -p /opt/boost/warm-orb
    if ! mountpoint -q /opt/boost/warm-orb 2>/dev/null; then
      if [ "$uid_b" != "$uid_n" ] || [ "$gid_b" != "$gid_n" ]; then
        mount --bind -o "X-mount.idmap=u:${uid_b}:${uid_n}:1 g:${gid_b}:${gid_n}:1" "$warm_src" /opt/boost/warm-orb 2>/dev/null \
          || mount --bind "$warm_src" /opt/boost/warm-orb 2>/dev/null || true
      else
        mount --bind "$warm_src" /opt/boost/warm-orb 2>/dev/null || true
      fi
    fi
    if mountpoint -q /opt/boost/warm-orb 2>/dev/null && [ -d /workspace/boost-cvm/lean-overlay/merged ]; then
      umount -l /workspace/boost-cvm/lean-overlay/merged 2>/dev/null || true
      mkdir -p /workspace/boost-cvm/lean-overlay/orb-upper /workspace/boost-cvm/lean-overlay/orb-work
      chown -R "$NODE_USER:$NODE_USER" /workspace/boost-cvm/lean-overlay/orb-upper /workspace/boost-cvm/lean-overlay/orb-work /workspace/boost-cvm/lean-overlay/merged 2>/dev/null || true
      mount -t overlay overlay -o "nosuid,nodev,lowerdir=/opt/boost/warm-orb,upperdir=/workspace/boost-cvm/lean-overlay/orb-upper,workdir=/workspace/boost-cvm/lean-overlay/orb-work" /workspace/boost-cvm/lean-overlay/merged 2>/dev/null || true
    fi
    if mountpoint -q /opt/boost/warm-orb 2>/dev/null; then
      cat > /usr/local/sbin/orb-cow-worktree-d <<'COWDAEMON'
#!/usr/bin/env python3
import hashlib, json, os, pwd, re, socket, subprocess, sys

SOCK_DIR = "/run/orb-cow-worktree"
SOCK_PATH = "/run/orb-cow-worktree/sock"
LOWER = "/opt/boost/warm-orb"
COW_ROOT = "/workspace/boost-cvm/cow"
ALLOWED_PREFIXES = ("/workspace/agents/", "/var/lib/orb-node/work/")
SAFE_PATH_RE = re.compile(r"^/[A-Za-z0-9._/-]+$")

pw = pwd.getpwnam("orbnode")
ORB_UID, ORB_GID = pw.pw_uid, pw.pw_gid
os.makedirs(SOCK_DIR, mode=0o750, exist_ok=True)
os.chown(SOCK_DIR, 0, ORB_GID)
os.chmod(SOCK_DIR, 0o750)
os.makedirs(COW_ROOT, mode=0o755, exist_ok=True)
try:
    os.unlink(SOCK_PATH)
except FileNotFoundError:
    pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK_PATH)
os.chown(SOCK_PATH, 0, ORB_GID)
os.chmod(SOCK_PATH, 0o660)
srv.listen(16)

if os.fork() > 0:
    os._exit(0)
os.setsid()
if os.fork() > 0:
    os._exit(0)
devnull = os.open("/dev/null", os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(devnull, fd)
if devnull > 2:
    os.close(devnull)

def handle(req_bytes: bytes) -> dict:
    req = json.loads(req_bytes.decode("utf-8"))
    dest = req.get("dest", "")
    if not isinstance(dest, str) or len(dest) > 256 or not SAFE_PATH_RE.match(dest):
        return {"ok": False, "error": "invalid dest path"}
    norm = os.path.normpath(dest)
    if norm != dest or not any(norm.startswith(p) and len(norm) > len(p) for p in ALLOWED_PREFIXES):
        return {"ok": False, "error": "dest must reside under /workspace/agents/ or /var/lib/orb-node/work/"}
    dir_fd = -1
    try:
        os.setegid(ORB_GID)
        os.seteuid(ORB_UID)
        try:
            os.makedirs(norm, mode=0o755, exist_ok=True)
            dir_fd = os.open(norm, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        finally:
            os.seteuid(0)
            os.setegid(0)
        fd_target = f"/proc/self/fd/{dir_fd}"
        resolved = os.readlink(fd_target)
        st = os.fstat(dir_fd)
        parent_st = os.stat(fd_target + "/..")
        if not any(resolved.startswith(p) and len(resolved) > len(p) for p in ALLOWED_PREFIXES):
            return {"ok": False, "error": "resolved path escapes allowed root"}
        if st.st_uid != ORB_UID:
            return {"ok": False, "error": "dest directory must be owned by orbnode"}
        if st.st_dev != parent_st.st_dev or st.st_ino == parent_st.st_ino:
            return {"ok": True, "reused": True}
        slot = hashlib.sha256(resolved.encode("utf-8")).hexdigest()[:16]
        slot_dir = os.path.join(COW_ROOT, slot)
        upper = os.path.join(slot_dir, "upper")
        work = os.path.join(slot_dir, "work")
        os.makedirs(upper, mode=0o755, exist_ok=True)
        os.makedirs(work, mode=0o755, exist_ok=True)
        for d in (slot_dir, upper, work):
            os.chown(d, ORB_UID, ORB_GID)
        opts = f"nosuid,nodev,lowerdir={LOWER},upperdir={upper},workdir={work}"
        res = subprocess.run(
            ["mount", "-t", "overlay", "overlay", "-o", opts, fd_target],
            capture_output=True,
            text=True,
            pass_fds=(dir_fd,),
        )
        if res.returncode != 0:
            return {"ok": False, "error": (res.stderr or "mount failed").strip()}
        return {"ok": True, "reused": False}
    finally:
        if dir_fd >= 0:
            os.close(dir_fd)

while True:
    conn, _ = srv.accept()
    try:
        conn.settimeout(5.0)
        data = conn.recv(1024)
        resp = handle(data)
    except Exception as exc:
        resp = {"ok": False, "error": str(exc)}
    try:
        conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
    except Exception:
        pass
    finally:
        conn.close()
COWDAEMON
      chmod 0700 /usr/local/sbin/orb-cow-worktree-d
      pkill -f '/usr/local/sbin/orb-cow-worktree-d' 2>/dev/null || true
      python3 /usr/local/sbin/orb-cow-worktree-d
    fi
  fi

  for repo_dir in /workspace/repo /workspace/boost-cvm/lean-overlay/merged /opt/boost/warm-orb; do
    if [ -d "$repo_dir" ]; then
      git config --system --add safe.directory "$repo_dir" 2>/dev/null || true
    fi
  done
  # Never mutate /workspace/repo/.git when it backs /opt/boost/warm-orb as an
  # overlayfs lowerdir (kernel overlayfs forbids lowerdir metadata changes).
  if ! mountpoint -q /opt/boost/warm-orb 2>/dev/null && [ -d /workspace/repo/.git ]; then
    git config --system --add safe.directory /workspace/repo/.git 2>/dev/null || true
    mkdir -p /workspace/repo/.git/worktrees /workspace/repo/.git/logs/refs/heads /workspace/repo/.git/refs/heads 2>/dev/null || true
    find /workspace/repo/.git -type d -exec chgrp "$NODE_USER" {} + -exec chmod 2775 {} + 2>/dev/null || true
    find /workspace/repo/.git -path /workspace/repo/.git/objects -prune -o -type f -exec chgrp "$NODE_USER" {} + -exec chmod g+rw {} + 2>/dev/null || true
  fi
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
