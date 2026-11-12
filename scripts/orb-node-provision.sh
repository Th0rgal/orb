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
# Refuse HTML/error pages and non-x86_64 binaries before replacing the live node:
# ELF magic, 64-bit, little-endian, and e_machine 62 (x86_64) at offset 18.
# coreutils only, so a minimal guest image without Python can still enrol.
elf_header=$(od -An -tx1 -N20 "$node_tmp" | tr -d ' \n')
[[ ${#elf_header} == 40 && ${elf_header:0:12} == 7f454c460201 && ${elf_header:36:4} == 3e00 ]] ||
  { printf '%s\n' 'bootstrap node is not Linux x86_64 ELF' >&2; exit 1; }
chmod 0755 "$node_tmp"
mv -f "$node_tmp" /opt/orb/bin/sandboxed-node
trap - EXIT

install -d -m 1777 -o orbnode -g orbnode /tmp/opencode
mkdir -p /etc/tmpfiles.d
printf '%s\n' 'd /tmp/opencode 1777 orbnode orbnode -' > /etc/tmpfiles.d/orb-opencode.conf

# lean.ci guests: the provider writes its cache settings for its own `runner`
# user (public values in /etc/profile.d/boost-vm.sh, the VM-scoped cache token in
# /home/runner/.boost-env; both are the provider's file names). Jobs run as
# `orbnode`, so copy only the LEANCI_* lines to a file that user's login shells
# source. Absent on other providers: this block then does nothing.
rm -f /etc/orb/leanci-env /etc/profile.d/zz-orb-leanci.sh
leanci_env=$(cat /etc/profile.d/boost-vm.sh /home/runner/.boost-env 2>/dev/null |
  grep -E "^export LEANCI_[A-Z0-9_]+='[^']*'$" || true)
if [[ -n $leanci_env ]]; then
  ( umask 027; printf '%s\n' "$leanci_env" > /etc/orb/leanci-env )
  chown root:orbnode /etc/orb/leanci-env
  chmod 0751 /etc/orb
  chmod 0640 /etc/orb/leanci-env
  printf '%s\n' '[ -r /etc/orb/leanci-env ] && . /etc/orb/leanci-env' > /etc/profile.d/zz-orb-leanci.sh
  chmod 0644 /etc/profile.d/zz-orb-leanci.sh
fi

if [[ ! -d /run/systemd/system ]]; then
  # No systemd (a Colab runtime): run the node under a small restart loop,
  # detached from the provider's exec call. The enrolment file stays root-only;
  # the loop reads it without evaluating it and passes a minimal environment.
  cat > /opt/orb/bin/orb-node-supervise <<'SUPERVISE'
#!/usr/bin/env bash
set -u
node_env=(HOME=/var/lib/orb-node PATH=/opt/orb/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  SANDBOXED_NODE_WORK_DIR=/var/lib/orb-node/work SANDBOXED_NODE_CREDENTIAL_FILE=/var/lib/orb-node/node.cred
  SANDBOXED_NODE_BIND=127.0.0.1:3088 OPENCODE_TMPDIR=/tmp/opencode GIT_TERMINAL_PROMPT=0
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_DIR=/etc/ssl/certs)
while IFS= read -r line; do
  [[ $line =~ ^([A-Z0-9_]+)=\"([^\"\\]*)\"$ ]] && node_env+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
done < /etc/orb/enroll.env
# Accelerator settings only; nothing else from the runtime's environment.
while IFS= read -r name; do
  [[ $name =~ ^(NVIDIA_|CUDA_|TPU_|PJRT_|LD_LIBRARY_PATH$|COLAB_GPU$) ]] && node_env+=("$name=${!name}")
done < <(compgen -e)
cd /var/lib/orb-node || exit 1
while :; do
  runuser -u orbnode -- env -i "${node_env[@]}" /opt/orb/bin/sandboxed-node || :
  sleep 2
done
SUPERVISE
  chmod 0755 /opt/orb/bin/orb-node-supervise
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || { printf '%s\n' 'system CA bundle missing' >&2; exit 1; }
  if [[ -r /run/orb-node-supervise.pid ]]; then
    old_pid=$(cat /run/orb-node-supervise.pid)
    [[ $old_pid =~ ^[0-9]+$ ]] && kill -- "-$old_pid" 2>/dev/null || true
  fi
  pkill -u orbnode -x sandboxed-node 2>/dev/null || true
  : > /var/lib/orb-node/orb-node.log
  chown orbnode:orbnode /var/lib/orb-node/orb-node.log
  setsid nohup /opt/orb/bin/orb-node-supervise </dev/null >>/var/lib/orb-node/orb-node.log 2>&1 &
  printf '%s\n' "$!" > /run/orb-node-supervise.pid
  printf '%s\n' 'orb-node started without systemd; readiness requires a Core relay poll'
  exit 0
fi

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
# The node links a static OpenSSL whose built-in CA directory does not exist in the
# guest; without the system bundle it cannot verify Core and never enrols.
Environment=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
Environment=SSL_CERT_DIR=/etc/ssl/certs
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
