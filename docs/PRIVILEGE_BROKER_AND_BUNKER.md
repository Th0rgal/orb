# Biometric JIT Privilege Broker, Deploy Gate & Bunker Mode

This document describes Orb's formally verified security subsystems implemented in `crates/orb-spec` (`Lean/OrbSpec/Kernel.lean`), `src/api/privilege_broker.rs`, `src/api/bunker.rs`, `src/bin/orb-privd.rs`, and `src/bin/orb-sudo.rs`.

---

## 1. Biometric JIT Privilege Broker (`/api/privilege/*` & `orb-privd`)

Workers (`sandboxed-node`) run under systemd with `NoNewPrivileges=true` and `ReadOnlyPaths=/usr/local/bin` (`deploy/systemd/orb-node-hardening.conf`). Agents inside missions never hold ambient `sudo` or fleet-wide SSH keys.

When a mission requires root execution on a worker node, a fleet harness update, or temporary SSH access to a protected host:

1. **Request**: The agent calls `POST /api/privilege/request` (or runs `orb-sudo <argv...>`), specifying:
   - `mission_id`, `node_id`, `scope` (`HostCommand`, `HarnessUpdate`, `FleetSsh`, or `DeployProd`),
   - Exact `argv` array (canonicalized and SHA-256 hashed into `argv_sha256`),
   - Requested `ttl_secs` (bounded to `[1, 900]` seconds by `orb_priv_step`),
   - Human-readable `reason`.
2. **Biometric Approval (`always_signed`)**:
   - The request pushes an APNs alert to the Orb iOS / macOS companion app.
   - Approval requires a fresh hardware **Secure Enclave P-256 signature** (`always_signed`) over the canonical payload (`ORB_PRIV_V1` domain separator + `request_id`, `mission_id`, `node_id`, `scope`, `argv_sha256`, `ttl_secs`, `nonce`, `expires_at`).
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
  2. No live writer mission is mid-turn (`!has_live_writers`) unless overridden by a hardware-signed Touch ID `DeployProd` grant (`biometric_override_valid`),
  3. The caller is not executing inside the target service (`!caller_is_self`),
  4. The deploy debounce window has elapsed (`!debounce_active`).

---

## 3. 4-State Bunker Mode & 180s `dgx-spark` Dead-Man's Switch (`/api/bunker/*`)

Orb and `lean-mesh` implement a 4-state security posture governed by `orb_bunker_step` (`crates/orb-spec`) and `leanmesh_bunker_isolate_step` (`crates/lean-mesh`):

| State | Code | Behavior |
| :--- | :---: | :--- |
| **`Normal`** | `0` | Standard operation; all capability-authorized mesh routes and missions active. |
| **`Elevated`** | `1` | Heightened monitoring; non-essential external webhooks and unverified routes restricted. |
| **`Bunker`** | `2` | Full lockdown: freezes non-essential missions, rotates tokens, and drops all non-operator `wg-leanmesh0` paths except `agent-core` (`1`) $\leftrightarrow$ `dgx-spark` (`2`) and operator (`100`). |
| **`Recovery`** | `3` | Controlled recovery state entered **only** with a hardware-signed Touch ID P-256 recovery envelope (`sig_ok && nonce_fresh`). |

### Automatic Triggers into `Bunker` Mode
1. **Zero-Noise Canary / Tripwire Alert (`POST /api/bunker/tripwire`)**:
   - Triggered immediately if any internal decoy socket (`127.0.0.1:27017` Mongo, `:5432` Postgres, `:6379` Redis), `.env.production.canary` honeytoken file, or Hindsight canary document is accessed.
2. **180-Second Sovereign Brain Dead-Man's Switch (`POST /api/mesh/heartbeat`)**:
   - `dgx-spark` (`10.88.0.2`) sends an Ed25519-signed `LEAN_MESH_HEARTBEAT_V1` frame every 30 seconds.
   - If no valid signed heartbeat is received within **180 seconds** (`sovereignDeadManExpired`), `step_bunker_isolate` automatically transitions the mesh into `Bunker` isolation (`bunker_active = true`), severing worker lateral/reverse paths while preserving operator recovery access.
   - Forged or unauthenticated heartbeat packets are rejected before updating `last_heartbeat_at` and cannot prematurely trip or reset the dead-man window.
