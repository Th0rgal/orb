# Paloma Fleet — SOC 2 Type I System Description & Security Policy Suite

**Version**: `2026.10.26`  
**Formal Verification Anchor**:
- `crates/lean-mesh/lean/LeanMesh/Kernel.lean` & `crates/lean-mesh/lean/LeanMesh/Spec.lean` (`0 sorryAx`, 282 theorems checked, 12/12 C-ABI exports covered)
- `lean/Orb/Kernel.lean` & `lean/Orb/Spec.lean` (`0 sorryAx`, Wave 11 SOC 2 Type I Gates: `soc2SshHostKeyPolicyStep`, `soc2AuditShipperStep`, `soc2HostScopeStep`)

---

## 1. System Boundary & Scope Definition (CC6.6 / A1.1)

### 1.1 In-Scope `lean-mesh` (`10.88.0.0/24`) Fleet (14 Nodes)

All in-scope production, control-plane, compute, and operator endpoints communicate over the Curve25519/ChaCha20-Poly1305 authenticated `lean-mesh` (`10.88.0.0/24`) overlay and enforce both `chain mesh_input` and `chain mesh_output` (`nftables` `table inet lean_mesh`).

| ID | Hostname | Mesh IP | Class | Role | OS Baseline | SSH Key Policy |
|---|---|---|---|---|---|---|
| `1` | `agent-core` | `10.88.0.1` | `ControlPlane` (`4`) | Orb Control Plane & JIT Privilege Broker (`orb-privd`) | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `2` | `dgx-spark` | `10.88.0.2` | `SovereignPii` (`0`) | Sovereign Memory (`spark-memory`), Signal CLI, GPU | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `3` | `ashur` | `10.88.0.11` | `UntrustedCompute` (`1`) | Worker Pool (`sandboxed-node`) | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `4` | `babylon` | `10.88.0.12` | `UntrustedCompute` (`1`) | Worker Pool (`sandboxed-node`) | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `5` | `nippur` | `10.88.0.13` | `UntrustedCompute` (`1`) | Worker Pool (`sandboxed-node`) | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `6` | `old-agent` | `10.88.0.14` | `UntrustedCompute` (`1`) | Worker Pool (`sandboxed-node`) | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `7` | `thomas-md` | `10.88.0.21` | `PublicGateway` (`2`) | Public Web Gateway (`thomas.md`) | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `8` | `polymath` | `10.88.0.22` | `PublicGateway` (`2`) | Polymath Web / API | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `9` | `maven-repo` | `10.88.0.31` | `ArtifactBuild` (`3`) | Artifact Repository | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `14` | `watchtower` | `10.88.0.50` | `CanaryBunker` (`5`) | Out-of-Band Canary & Audit Bunker | Debian 12 (Bookworm) | 3-Key Policy |
| `16` | `rpc-starknet-id` | `10.88.0.16` | `UntrustedCompute` (`1`) | Compute / RPC Node | Debian 12 (Bookworm) | 3-Key Policy |
| `17` | `utu-lfglabs` | `10.88.0.17` | `UntrustedCompute` (`1`) | Compute / UTU Node | Debian 13 (Trixie) | 3-Key Policy |
| `18` | `agent-starknet-id` | `10.88.0.18` | `UntrustedCompute` (`1`) | Compute / Agent Node | Ubuntu 24.04.4 LTS | 3-Key Policy |
| `100` | `macbook-air` | `10.88.0.100` | `OperatorAdmin` (`6`) | Operator Admin Workstation (macOS Orb Client) | macOS (Darwin arm64) | 3-Key + Touch ID JIT |

### 1.2 Out-of-Scope Scheduled Decommission Hosts (Fenced Legacy Perimeter)

The following legacy single-purpose VPS instances are formally excluded from the Paloma / Orb SOC 2 Type I boundary (`inScope = 0`, `soc2HostScopeStep == 1`):
- `signer.starknet.id` (`141.94.26.62`) — Scheduled automatic expiration `2026-11-02`
- `api.starknet.id` (`5.39.72.91`) — Out-of-scope legacy Starknet ID API
- `sepolia.api.starknet.id` (`5.39.73.3`) — Out-of-scope legacy Starknet ID Sepolia API
- `api.federation.lfg.rs` (`141.94.207.48`) — Out-of-scope legacy Federation API

**Isolation Controls (Formally Verified by `Orb.Spec.soc2_host_scope_rejects_eol_os_missing_egress_or_unfenced_legacy`)**:
1. Zero `lean-mesh` peer keys or `10.88.0.0/24` routing (`meshEnrolled == 0`).
2. Zero access to `agent-core`, `dgx-spark`, or any Paloma secrets (`hasMeshOrCoreCredentials == 0`).
3. Tracked on the decommission register until billing termination.

---

## 2. Logical Access & Cryptographic SSH Policy (CC6.1 / CC6.2 / CC6.3)

Formally specified and proved in `Orb.Kernel.soc2SshHostKeyPolicyStep` and `LeanMesh.Kernel.leanmesh_eval_route_step`:

1. **Strict 3-Key SSH `authorized_keys` Policy**:
   Every in-scope host (`root` and admin user) permits at most 3 public keys:
   - `thomas-yubikey-admin` (Hardware-backed operator key)
   - `thomas-breakglass` (Offline cold-storage recovery key)
   - `paloma-<host>@10.88.0.X` (Unique per-host Ed25519 key held exclusively in `/etc/paloma/ssh/` (`0600 root:root`) on `agent-core` for JIT `orb-privd` brokered operations)
2. **Zero Shared Keys & Zero Worker Private Keys**:
   - Legacy shared `paloma` keys and `ssh-rsa` provider provisioning keys are revoked fleet-wide (`legacyOrSharedKeyCount == 0`).
   - Worker nodes hold zero fleet private SSH keys (`workerPrivateKeyCount == 0`).
3. **Key-Only Authentication (`sshd_config`)**:
   - `PasswordAuthentication no`
   - `KbdInteractiveAuthentication no`
   - `PermitRootLogin prohibit-password` (or `no` on `macbook-air`)
4. **Operator Workstation (`macbook-air`, `10.88.0.100`) & Lateral SSH Prohibition**:
   - By `LeanMesh.Spec.eval_route_blocks_worker_to_operator_macbook_and_lateral_ssh`, only `ControlPlane` (`4`, `agent-core`) and `OperatorAdmin` (`6`, `macbook-air`) may ever initiate `:22` or route to `dstClass == 6` (`macbook-air`).
   - Every Linux node enforces `chain mesh_output` in `/etc/lean-mesh/lean-mesh.nft`, dropping outbound packets from worker nodes to `10.88.0.100` or `:22` at the kernel netfilter hook before leaving the source host.
   - macOS Remote Login on `macbook-air` remains enabled for `agent-core` JIT brokered commands (gated by Touch ID / Secure Enclave approval) and outbound admin use, with password and keyboard-interactive authentication disabled.

---

## 3. Immutable Off-Host Audit Logging & Secret Redaction (CC7.2 / CC7.3 / C1.1)

Formally specified and proved in `Orb.Kernel.soc2AuditShipperStep`:

1. **Tamper-Evident Off-Host Shipping (`orb-audit-shipper`)**:
   - `agent-core` and `watchtower` ship `/var/log/orb-privd/audit.jsonl`, `sshd` authentication journals, and Canary/Bunker alerts every 5 minutes (`orb-audit-shipper.timer`) to Backblaze B2 (`BACKBLAZE_KEY_ID` / `BACKBLAZE_APP_KEY`) with SHA-256 content-addressed manifests.
2. **Pre-Ship Secret & Token Redaction**:
   - All log entries are scrubbed of `orb-jit-*` lease tokens, Bearer tokens, API keys, and credentials prior to upload (`redactionEnabled == 1`).
3. **Real-Time Signal Alerting**:
   - Every Canary tripwire event, privilege broker revocation, or SSH authentication anomaly triggers an immediate alert via `dispatch_bunker_alert` to Signal (`http://10.88.0.2:8890/api/signal/send`) and `watchtower` (`http://10.88.0.50:9988/api/bunker/alert`).

---

## 4. Change Management, Vulnerability Management & Availability (CC8.1 / CC7.1 / A1.2)

1. **Change Management (CC8.1)**:
   - All changes to `Th0rgal/orb` require pull requests, automated CI/test verification, and Lean 4 formal proof verification (`0 sorryAx`) when modifying `lean/` or `crates/lean-mesh/lean/`.
2. **Automated OS Security Patching (CC7.1)**:
   - Every in-scope Linux node runs a supported LTS distribution (`Ubuntu 24.04 LTS` or `Debian 12/13`) with `unattended-upgrades` enabled (`osEol == 0 && unattendedUpgrades == 1`).
3. **Capacity & Workspace Garbage Collection (A1.2)**:
   - Compute worker nodes (`ashur`, `babylon`, `nippur`, `old-agent`) run `sandboxed-node-gc.timer` daily to prune inactive mission `target/` and `.lake/build/` artifacts and maintain disk utilization below 80%.
   - Backblaze B2 encrypted backups (`rclone` + age/restic) protect stateful services (`agent-core` SQLite + `/etc/paloma`, `dgx-spark` Hindsight memory, `thomas-md`, `polymath`, `maven-repo`) with monthly restore verification drills.
