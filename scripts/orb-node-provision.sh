#!/usr/bin/env bash
# Core delivers this script and enroll.env through the provider file API. Run as
# root inside a disposable guest, never on Core. Heavy tools belong in the image.
# Credentials are read by systemd from a private file, never passed in argv/logs.
set -euo pipefail
cd /
umask 077
[[ $(id -u) == 0 ]] || { printf '%s\n' 'guest provisioning requires root' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { printf '%s\n' 'unsupported managed guest architecture' >&2; exit 1; }
[[ -r /home/user/.orb/enroll.env ]] || { printf '%s\n' 'missing enrollment file' >&2; exit 1; }

# The provider base image is intentionally not trusted to contain a current node.
# Core must set these two non-secret arguments; shell metacharacters remain data.
core_url=${1:?Core public HTTPS URL required}
machine_id=${2:?managed machine id required}
[[ $core_url == https://* && $core_url != *$'\n'* && $core_url != *$'\r'* ]] || exit 1
[[ $machine_id =~ ^[A-Za-z0-9_-]+$ ]] || exit 1

systemctl stop orb-node.service 2>/dev/null || true
id orbnode >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/orb-node --shell /bin/bash orbnode
install -d -m 0750 -o orbnode -g orbnode /var/lib/orb-node /var/lib/orb-node/work
install -d -m 0755 /opt/orb/bin
install -d -m 0700 /etc/orb
install -m 0600 -o root -g root /home/user/.orb/enroll.env /etc/orb/enroll.env

# Forks and restored snapshots must not reuse the parent's cached node identity.
rm -f /var/lib/orb-node/node.cred
rm -rf /var/lib/orb-node/work/managed-auth /var/lib/orb-node/.paloma-secrets \
  /var/lib/orb-node/work/caches/home/.paloma-secrets /run/user/*/paloma-secrets
find /var/lib/orb-node /home -maxdepth 6 \
  \( -path '/var/lib/orb-node/work/caches/elan' \
     -o -path '/var/lib/orb-node/work/caches/rustup' \
     -o -path '/var/lib/orb-node/work/caches/cargo' \
     -o -path '/var/lib/orb-node/work/caches/lake' \
     -o -path '/var/lib/orb-node/work/caches/xdg' \
     -o -name .git -o -name .lake -o -name target -o -name node_modules \) -prune \
  -o -name .paloma-secrets -prune -exec rm -rf -- {} +
node_tmp=$(mktemp /opt/orb/bin/.sandboxed-node.XXXXXX)
trap 'rm -f "$node_tmp"' EXIT
curl --fail --silent --show-error --proto '=https' --tlsv1.2 --max-time 60 \
  "${core_url%/}/api/managed-machines/bootstrap-binary/$machine_id" -o "$node_tmp"
# Refuse HTML/error pages and non-x86_64 binaries before replacing the live node.
python3 -I - "$node_tmp" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    header = f.read(20)
if len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 62:
    raise SystemExit('bootstrap node is not Linux x86_64 ELF')
PY
chmod 0755 "$node_tmp"
mv -f "$node_tmp" /opt/orb/bin/sandboxed-node
trap - EXIT

install -d -m 1777 -o orbnode -g orbnode /tmp/opencode
mkdir -p /etc/tmpfiles.d
printf '%s\n' 'd /tmp/opencode 1777 orbnode orbnode -' > /etc/tmpfiles.d/orb-opencode.conf

# Preserve the image's PATH/toolchain/resource settings, while replacing only
# identity and executable settings. Bare provider images get a minimal unit.
if ! systemctl cat orb-node.service >/dev/null 2>&1; then
  cat > /etc/systemd/system/orb-node.service <<'UNIT'
[Unit]
Description=Orb managed worker (reverse relay)
After=network-online.target
Wants=network-online.target
[Service]
User=orbnode
Group=orbnode
WorkingDirectory=/var/lib/orb-node
Environment=HOME=/var/lib/orb-node
Environment=PATH=/opt/orb/bin:/usr/local/bin:/usr/bin:/bin
NoNewPrivileges=true
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
fi
mkdir -p /etc/systemd/system/orb-node.service.d
cat > /etc/systemd/system/orb-node.service.d/20-core-enrollment.conf <<'UNIT'
[Service]
EnvironmentFile=
EnvironmentFile=/etc/orb/enroll.env
Environment=SANDBOXED_NODE_WORK_DIR=/var/lib/orb-node/work
Environment=SANDBOXED_NODE_CREDENTIAL_FILE=/var/lib/orb-node/node.cred
Environment=SANDBOXED_NODE_BIND=127.0.0.1:3088
Environment=OPENCODE_TMPDIR=/tmp/opencode
Environment=GIT_TERMINAL_PROMPT=0
ExecStart=
ExecStart=/opt/orb/bin/sandboxed-node
UNIT
uid_n=$(id -u orbnode)
printf 'Environment=XDG_RUNTIME_DIR=/run/user/%s\nEnvironment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus\n' \
  "$uid_n" "$uid_n" >> /etc/systemd/system/orb-node.service.d/20-core-enrollment.conf
loginctl enable-linger orbnode
systemctl start "user@$uid_n.service"
for _ in $(seq 100); do
  [[ ! -S /run/user/$uid_n/bus ]] || break
  sleep 0.2
done
[[ -S /run/user/$uid_n/bus ]] || { printf '%s\n' 'managed user bus unavailable' >&2; exit 1; }
systemctl daemon-reload
systemctl enable --now orb-node.service >/dev/null
printf '%s\n' 'orb-node provisioning started; readiness requires a Core relay poll'
