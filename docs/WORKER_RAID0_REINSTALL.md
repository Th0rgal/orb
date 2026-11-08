# Bare-Metal Worker Reinstall Runbook (Ubuntu 26.04 LTS + RAID0)

This runbook doubles usable SSD/NVMe storage across the three legacy RAID1 bare-metal Lean workers (`babylon`, `ashur`, and `nippur`: `1.31 TiB` -> `2.62 TiB` total) while standardizing them on **Ubuntu 26.04 LTS** and a single read-only `/opt/orb/elan` toolchain layout.

> **Scope boundary**: Stateful storage hosts (`polymath`) remain on **RAID1**. Reimage workers strictly **one host at a time** (`babylon` -> `ashur` -> `nippur`), verifying full mesh + node canary health before moving to the next server.

## Target Hardware & Firmware Matrix

| Host | Firmware | Disks | Profile / Layout | Resulting Capacity | Co-located Services Preserved |
| --- | --- | --- | --- | --- | --- |
| `lagash` (`10.88.0.15`, ex-`media-exit`) | **UEFI** | 2x 419.2G Intel NVMe (`nvme0n1`, `nvme1n1`) | **Profile A** (OVH RAID0 XFS `md4` + RAID1 `/boot`) | **`819 GiB`** (`/` XFS, Ubuntu 26.04.1 LTS) | `sandboxed-node`, `lean-mesh`, `orb-privd` |
| `babylon` (`10.88.0.12`) | **UEFI** | 2x 419.2G Intel NVMe (`nvme0n1`, `nvme1n1`) | **Profile A** (OVH RAID0 XFS `md4` + RAID1 `/boot`) | **`819 GiB`** (`/` XFS, Ubuntu 26.04.1 LTS) | `sandboxed-node`, `lean-mesh`, `orb-privd` |
| `nippur` (`10.88.0.13`) | **Legacy BIOS** | 2x 447.1G Intel SATA (`sda`, `sdb`) | **Profile B** (OVH RAID0 XFS `md4` + RAID1 `/boot`) | **`876 GiB`** (`/` XFS, Ubuntu 26.04.1 LTS) | `sandboxed-node`, `lean-mesh`, `orb-privd`, 3 GitHub runners (`bench`, `verity-build`, `verity-ocr`), `orb-canary-auditd` |
| `ashur` (`10.88.0.11`) | **Legacy BIOS** | 2x 476.9G Micron NVMe (`sda`, `sdb`) | **Online Dual-XFS Split** (`sda3` `/` + `sdb3` `/var/lib/sandboxed-node` + RAID1 `/boot` & `swap`) | **`888 GiB`** (`444 GiB` `/` + `444 GiB` `/var/lib/sandboxed-node`) | `sandboxed-node`, `lean-mesh`, `orb-privd`, 1 GitHub runner (`verity-medium-1`) |

## Rolling Procedure (Per Host)

### 1. Cordon & Drain
1. Cordon the target worker in Orb (or set `SANDBOXED_NODE_CAPACITY=0` and `SANDBOXED_NODE_SIDE_CAPACITY=0` in `/etc/sandboxed-node.env`, which hot-reloads within 5s) and wait for active jobs in `jobs.db` to reach `0`.
2. On `ashur` / `nippur`, stop GitHub Actions `actions.runner.*.service` units once any running CI job finishes.
3. Run `scripts/storage_inventory.py` against `/var/lib/sandboxed-node` and verify zero active missions or unbacked-up repositories remain.

### 2. Preserve Encrypted Host Identity Bundle
Stage an operator-only backup bundle on `agent-core` (`chmod 0700`) containing:
- `/etc/wireguard/wg-leanmesh0.conf` and `/etc/systemd/system/lean-mesh.service`
- `/etc/sandboxed-node.env` and `/etc/systemd/system/sandboxed-node.service` (+ `user-*.slice` cgroup drop-ins)
- `/etc/orb-privd/` + `/usr/local/bin/sandboxed-node` + `/usr/local/bin/turbo-lean`
- GitHub Actions runner `.runner` / `.credentials*` files (`ashur`, `nippur`) and `orb-canary-auditd` rules (`nippur`)

### 3. Reinstall Ubuntu 26.04 LTS with RAID0 `/` + RAID1 `/boot`
1. Apply the matching profile from `deploy/autoinstall/ubuntu-26.04-worker-raid0.yaml` via OVH bare-metal installer / rescue `autoinstall`.
2. Immediately after first boot, update the host's new SSH host key in `/root/.ssh/known_hosts` on `agent-core` so `disk-sentinel.sh` and `run_fleet_worker_cache_reclaim.py` pass strict host-key verification.

### 4. Bootstrap & Restore Resident Services
1. Copy `scripts/bootstrap_baremetal_worker.sh` to the host and execute as `root`:
   ```bash
   NODE_ID=<host> NODE_CAPACITY=8 ./bootstrap_baremetal_worker.sh
   ```
   This installs system packages, provisions `/opt/orb/elan` once as read-only, symlinks `<work>/caches/elan`, `<work>/.elan`, and `/srv/verity-ci-cache/elan` to `/opt/orb/elan`, sets `/etc/tmpfiles.d/sandboxed-worker-tmp.conf` (`2d`), and configures `SANDBOXED_NODE_MIN_FREE_GB` to `>=16%` of the RAID0 volume (`~135-150 GiB`).
2. Restore the host's WireGuard `lean-mesh` config, `sandboxed-node` binary/unit/env, `orb-privd`, and any GitHub runner / canary units from the staging bundle.

### 5. Post-Boot Acceptance Gate (Before Proceeding to Next Host)
- `df -hT /` shows `xfs` at `~820-920 GiB` and `<5%` used.
- `cat /proc/mdstat` shows `md0 : active raid1` (`/boot`) and `md2 : active raid0` (`/`).
- `wg show wg-leanmesh0 latest-handshakes` confirms live mesh peer handshake with `agent-core`.
- `/srv/sandboxed-storage/staging/agent-core/hermes/.hermes/scripts/disk-sentinel.sh --stateless` on `agent-core` exits `0` with empty stdout.
- Uncordon the worker and verify one remote Lean build completes cleanly.
