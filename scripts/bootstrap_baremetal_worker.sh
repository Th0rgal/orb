#!/usr/bin/env bash
# Idempotent post-install bootstrap for bare-metal Ubuntu 26.04 LTS RAID0 workers
# (babylon, ashur, nippur, and future dedicated Lean/compute nodes).
#
# Modeled on deploy/managed-images/orb-node-base.recipe.sh so bare-metal workers
# and managed Boat images share one Lean toolchain/cache layout:
#   - Single root-owned, read-only Lean installation at /opt/orb/elan
#   - Symlinked into <work>/caches/elan, <work>/.elan, and /srv/verity-ci-cache/elan
#     (prevents 3-4 duplicate 15-20 GiB .elan directories per server)
#   - SANDBOXED_NODE_MIN_FREE_GB sized to >=15% of root filesystem (>=65 GiB)
#     so admission control and pressure GC act BEFORE disk-sentinel's 85% WARN
#   - systemd-tmpfiles 48h age cap on /tmp to prevent multi-week scratch buildup
#
# Usage (as root on freshly installed Ubuntu 26.04 LTS worker):
#   NODE_ID=babylon NODE_CAPACITY=8 ./bootstrap_baremetal_worker.sh [--check-only]
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check-only" ]; then
  CHECK_ONLY=1
fi

NODE_ID="${NODE_ID:-$(hostname -s)}"
NODE_USER="${NODE_USER:-sandboxed-node}"
NODE_WORK_DIR="${NODE_WORK_DIR:-/var/lib/sandboxed-node}"
NODE_CAPACITY="${NODE_CAPACITY:-8}"
NODE_SIDE_CAPACITY="${NODE_SIDE_CAPACITY:-4}"
NODE_LABELS="${NODE_LABELS:-lean}"
NODE_JOB_MEMORY_BYTES="${NODE_JOB_MEMORY_BYTES:-8589934592}"
LEAN_VERSION="${LEAN_VERSION:-4.35.0}"
ELAN_VERSION="${ELAN_VERSION:-4.2.4}"
ELAN_SHA256="${ELAN_SHA256:-42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63}"
SHARED_ELAN="/opt/orb/elan"

total_bytes="$(df -B1 --output=size / | tail -1 | tr -dc '0-9')"
total_gib=$(( total_bytes / 1073741824 ))
# Keep >=16% free floor (minimum 65 GiB) so admission halts before 85% WARN.
default_min_free_gb=$(( (total_gib * 16 + 99) / 100 ))
if [ "$default_min_free_gb" -lt 65 ]; then
  default_min_free_gb=65
fi
MIN_FREE_GB="${SANDBOXED_NODE_MIN_FREE_GB:-$default_min_free_gb}"

echo "== Worker storage & OS audit ($NODE_ID) =="
echo "  OS:        $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
echo "  Kernel:    $(uname -r)"
echo "  Root size: ${total_gib} GiB (target SANDBOXED_NODE_MIN_FREE_GB=${MIN_FREE_GB})"
if [ -r /proc/mdstat ]; then
  grep -E '^md[0-9]+' /proc/mdstat || true
fi

if [ "$CHECK_ONLY" = "1" ]; then
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "error: bootstrap_baremetal_worker.sh must run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl git jq lsof mdadm rsync sqlite3 wireguard-tools xz-utils zstd build-essential pkg-config

# 1. Dedicated unprivileged service user
if ! id -u "$NODE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$NODE_WORK_DIR" --create-home --shell /usr/sbin/nologin "$NODE_USER"
fi

install -d -m 0700 -o "$NODE_USER" -g "$NODE_USER" \
  "$NODE_WORK_DIR" \
  "$NODE_WORK_DIR/caches" \
  "$NODE_WORK_DIR/caches/turbo-lean" \
  "$NODE_WORK_DIR/caches/cargo" \
  "$NODE_WORK_DIR/caches/git-mirrors" \
  "$NODE_WORK_DIR/checkouts" \
  "$NODE_WORK_DIR/.scratch"
install -d -m 0755 /opt/orb/bin /usr/local/lib/sandboxed-sh /var/log/sandboxed-sh

# 2. Single read-only shared Lean toolchain at /opt/orb/elan
if [ ! -x "$SHARED_ELAN/toolchains/leanprover--lean4---v${LEAN_VERSION}/bin/lean" ]; then
  install -d -m 0755 "$SHARED_ELAN"
  tmp_elan="$(mktemp -d)"
  trap 'rm -rf "$tmp_elan"' EXIT
  curl -fsSL "https://github.com/leanprover/elan/releases/download/v${ELAN_VERSION}/elan-x86_64-unknown-linux-gnu.tar.gz" \
    -o "$tmp_elan/elan.tar.gz"
  echo "${ELAN_SHA256}  $tmp_elan/elan.tar.gz" | sha256sum -c -
  tar -xzf "$tmp_elan/elan.tar.gz" -C "$tmp_elan"
  ELAN_HOME="$SHARED_ELAN" "$tmp_elan/elan-init" -y --no-modify-path --default-toolchain "leanprover/lean4:v${LEAN_VERSION}"
  chmod -R a+rX,go-w "$SHARED_ELAN"
  rm -rf "$tmp_elan"
  trap - EXIT
fi

link_elan_home() {
  local dest="$1" owner="$2"
  install -d -m 0755 -o "$owner" -g "$owner" "$dest" "$dest/toolchains" "$dest/bin"
  for b in "$SHARED_ELAN"/bin/*; do
    [ -e "$b" ] || continue
    install -m 0755 -o "$owner" -g "$owner" "$b" "$dest/bin/$(basename "$b")"
  done
  for tc in "$SHARED_ELAN"/toolchains/*; do
    [ -d "$tc" ] || continue
    ln -sfn "$tc" "$dest/toolchains/$(basename "$tc")"
    chown -h "$owner:$owner" "$dest/toolchains/$(basename "$tc")"
  done
  if [ -f "$SHARED_ELAN/settings.toml" ] && [ ! -f "$dest/settings.toml" ]; then
    install -m 0644 -o "$owner" -g "$owner" "$SHARED_ELAN/settings.toml" "$dest/settings.toml"
  fi
}

link_elan_home "$NODE_WORK_DIR/caches/elan" "$NODE_USER"
link_elan_home "$NODE_WORK_DIR/.elan" "$NODE_USER"
if id -u ubuntu >/dev/null 2>&1; then
  install -d -m 0755 -o ubuntu -g ubuntu /srv/verity-ci-cache
  link_elan_home "/srv/verity-ci-cache/elan" "ubuntu"
fi

# 3. Bound /tmp age via systemd-tmpfiles so orphaned /tmp scratch expires automatically
cat >/etc/tmpfiles.d/sandboxed-worker-tmp.conf <<'EOF'
# Clean unaccessed files in /tmp older than 48h on compute workers
e /tmp 1777 root root 2d
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/sandboxed-worker-tmp.conf

# 4. Seed /etc/sandboxed-node.env if absent (never overwrite existing SANDBOXED_NODE_TOKEN)
if [ ! -f /etc/sandboxed-node.env ]; then
  umask 0077
  cat >/etc/sandboxed-node.env <<EOF
SANDBOXED_NODE_ID=${NODE_ID}
SANDBOXED_NODE_BIND=0.0.0.0:3088
SANDBOXED_NODE_WORK_DIR=${NODE_WORK_DIR}
SANDBOXED_NODE_CAPACITY=${NODE_CAPACITY}
SANDBOXED_NODE_SIDE_CAPACITY=${NODE_SIDE_CAPACITY}
SANDBOXED_NODE_LABELS=${NODE_LABELS}
SANDBOXED_NODE_MIN_FREE_GB=${MIN_FREE_GB}
SANDBOXED_NODE_JOB_MEMORY_BYTES=${NODE_JOB_MEMORY_BYTES}
CARGO_BUILD_JOBS=2
LEAN_NUM_THREADS=2
LAKE_JOBS=2
SANDBOXED_NODE_ENV_ALLOWLIST=LEAN_NUM_THREADS,LAKE_JOBS,CARGO_BUILD_JOBS
# Provision SANDBOXED_NODE_TOKEN from encrypted identity bundle before starting sandboxed-node.service
EOF
fi

echo "== Bootstrap complete for ${NODE_ID} (${total_gib} GiB root, MIN_FREE_GB=${MIN_FREE_GB}) =="
