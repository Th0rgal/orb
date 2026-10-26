# Biometric JIT Privilege Broker, Deploy Gate & Bunker Mode

This document describes Orb's formally verified security subsystems implemented in `crates/orb-spec` (`Lean/OrbSpec/Kernel.lean`), `crates/lean-mesh` (`lean/LeanMesh/Kernel.lean`), `src/api/privilege_broker.rs`, `src/api/bunker.rs`, `src/api/mesh.rs`, `src/bin/orb-privd.rs`, and `src/bin/orb-sudo.rs`.

---

## 1. Biometric JIT Privilege Broker (`/api/privilege/*` & `orb-privd`)

Workers (`sandboxed-node`) run under systemd with `NoNewPrivileges=true` and `ReadOnlyPaths=/usr/local/bin` (`deploy/systemd/orb-node-hardening.conf`). Agents inside missions never hold ambient `sudo` or fleet-wide SSH keys.

When a mission requires root execution on a worker node, a fleet harness update, or temporary SSH access to a protected host:

1. **Request**: The agent calls `POST /api/privilege/request` (or runs `orb-sudo <argv...>`), specifying:
   - `mission_id`, `node_id`, `scope` (`HostCommand`, `HarnessUpdate`, `FleetSsh`, or `DeployProd`),
   - Exact `argv` array (canonicalized and SHA-256 hashed into `argv_sha256`),
   - Requested `ttl_secs` (bounded to `[1, 900]` seconds by `orb_priv_step`),
   - Human-readable `reason`.
2. **Biometric Approval & Cryptographic Verification Boundary**:
   - The request pushes an alert to the Orb iOS / macOS companion app.
   - Approval requires a fresh hardware **Secure Enclave P-256 ECDSA-SHA256 signature** (`always_signed`) over the canonical payload (`ORB_PRIV_V1` domain separator + `request_id`, `mission_id`, `node_id`, `scope`, `argv_sha256`, `ttl_secs`, `nonce`, `expires_at`).
   - **Verifier & Key-Pinning Boundary**: `src/api/privilege_broker.rs` verifies the P-256 signature against the operator's pinned public key (`ORB_OPERATOR_P256_PUBKEY_HEX`) and checks the replay-cache nonce before setting `sig_ok = true` and `nonce_fresh = true`. If `ORB_OPERATOR_P256_PUBKEY_HEX` is unset or signature verification fails, `sig_ok` is `false` and the request fails closed.
3. **Formal Kernel Gate (`orb_priv_step`)**:
   - `crates/orb-spec` invokes the Lean 4 C-ABI transition `orb_priv_step`, proving:
     - `Pending -> Approved` only if `sig_ok == true`, `nonce_fresh == true`, `ttl_secs in [1, 900]`, and `now_epoch < request_expires_at`.
     - `Approved -> Consumed` (single-use lease) only if `argv_hash_matches == true` and `now_epoch < grant_expires_at`.
     - Terminal states (`Denied`, `Expired`, `Consumed`, `Revoked`) are absorbing (`priv_terminal_absorbing`).
4. **Local Execution (`orb-privd` + `orb-sudo`)**:
   - `orb-privd` listens on `/run/orb-privd.sock` (`0660 root:sandboxed-node`), verifies `SO_PEERCRED` caller UID, re-hashes the requested `argv`, verifies the signed grant against `orb_priv_step`, executes the binary directly via `Command::new(&argv[0]).args(&argv[1..])` (never `sh -c`), and logs an immutable receipt.

---

## 2. Cryptographic Production Deploy Gate (`orb_deploy_gate_step`)

Production deployments on `agent-core` (`POST /api/system/deploy`) are protected by `orb_deploy_gate_step`:

- A deployment to `target_environment = "prod"` is permitted if and only if:
  1. The git commit has a verified OpenPGP signature from a trusted fingerprint (`commit_gpg_valid`),
  2. No live writer mission is mid-turn (`!has_live_writers`) unless overridden by a verified P-256 Touch ID `DeployProd` grant (`biometric_override_valid`),
  3. The caller is not executing inside the target service (`!caller_is_self`),
  4. The deploy debounce window has elapsed (`!debounce_active`).

---

## 3. Bunker Mode Lattice & 180s `dgx-spark` Dead-Man's Switch

Orb's host bunker controller (`src/api/bunker.rs`, `orb_bunker_step`) and `lean-mesh`'s overlay bunker controller (`src/api/mesh.rs`, `leanmesh_bunker_isolate_step`) enforce a monotonic severity lattice:

| Severity Code | `OrbBunkerState` (`orb-spec`) | `BunkerState` (`lean-mesh`) | Behavior |
| :---: | :--- | :--- | :--- |
| **`0`** | `Normal` | `Normal` | Standard operation; all capability-authorized mesh routes and missions active. |
| **`1`** | `SoftQuarantine` | `SoftQuarantine` | Heightened quarantine: blocks worker-to-worker/vault routes (`RetainControlAndOperator`); non-essential external webhooks restricted. |
| **`2`** | `HardLockdown` | `HardLockdown` | Full lockdown: freezes non-essential missions, rotates tokens, and prunes worker WireGuard peers (`PruneComputeWorkers`), keeping only `ControlPlane`, `SovereignVault`, and `OperatorAdmin` peers. |
| **`3`** | *(mapped via mesh)* | `SovereignDeadManTripped` | **Most severe state** (auto-entered when `dgx-spark` dead-man expires): `bunkerAllowsRoute 3 = false` for **all** routes (`PruneAllPeers` + `lockSovereignVault = true`). Recovery back to `Normal` (`0`) requires an authenticated biometric `unbunker` command on `POST /api/mesh/heartbeat` accompanied by a fresh `dgx-spark` signed heartbeat. |

`src/api/mesh.rs` synchronizes the two via `map_orb_bunker_to_mesh` (`Normal -> 0`, `SoftQuarantine -> 1`, `HardLockdown -> 2`) and takes the lattice join (`effective_bunker_state = max(mesh.bunker_state, map_orb_bunker_to_mesh(orb.bunker))`).

### Automatic Triggers
1. **Zero-Noise Canary / Tripwire Alert (`POST /api/bunker/tripwire`)**:
   - Triggered immediately if any internal decoy socket (`127.0.0.1:27017` Mongo, `:5432` Postgres, `:6379` Redis), `.env.production.canary` honeytoken file, or Hindsight canary document is accessed, escalating both `OrbBunkerState` and `lean-mesh` (`canary_tripped = true` $\rightarrow$ `HardLockdown`).
2. **180-Second Sovereign Brain Dead-Man's Switch (`POST /api/mesh/heartbeat`)**:
   - `dgx-spark` (`10.88.0.2`) sends an Ed25519-signed `lean-mesh-heartbeat-v1:` frame every 30 seconds.
   - If no valid signed heartbeat is received within **180 seconds** (`sovereignDeadManExpired`), `leanmesh_bunker_isolate_step` automatically transitions the mesh into state **`3` (`SovereignDeadManTripped`)** (`PruneAllPeers` + `lock_sovereign_vault = true`).
   - Forged or unauthenticated heartbeat packets are rejected before updating `last_heartbeat_at` and cannot prematurely trip or reset the dead-man window.
