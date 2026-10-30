# Lean-Mesh (`wg-leanmesh0`)

`lean-mesh` ([`Th0rgal/lean-mesh`](https://github.com/Th0rgal/lean-mesh), integrated in `crates/lean-mesh` and `src/api/mesh.rs`) is Paloma's zero-trust WireGuard + `nftables` overlay network (`10.88.0.0/16` on `wg-leanmesh0`, default UDP port `51888`). It replaces Tailscale (`tailscaled` / Headscale) with a tiny, self-sovereign Rust + Lean 4 verified mesh that operates in two modes simultaneously:

- **Orb Compute Enrollment (`sandboxed-node` `:3088`)**: `agent-core` (`10.88.0.1`), `dgx-spark` (`10.88.0.2`), and the compute worker nodes (`ashur` `10.88.0.11`, `babylon` `10.88.0.12`, `nippur` `10.88.0.13`, `uruk` `10.88.0.14`, `nimrud` `10.88.0.18`) run `sandboxed-node` on `:3088` to execute coding/Lean missions.
- **Full-Fleet Orb Security Enrollment (`lean-mesh` + Biometric JIT Privilege Broker + Canary/Bunker)**: Every machine in the fleet — including `RESERVED` / `SHARED_PROTECTED` production & storage boxes that do **not** run `sandboxed-node` `:3088` (`thomas-md` `10.88.0.3`, `polymath` `10.88.0.4`, `maven-repo` `10.88.0.5`, `watchtower` `10.88.0.15`) — is enrolled in the signed `MeshManifest`, protected from lateral worker access by `table inet lean_mesh` (`nftables`), reachable from `agent-core` (`10.88.0.1:22`) for Touch ID / Face ID–approved `request_privileged_access` + `execute_privileged_command`, and authorized to report Canary tripwires and poll Bunker convergence on `agent-core` (`10.88.0.1:3000-3002`).

---

## 1. Architecture & Formal Kernel (`LeanMesh.Kernel`)

Every manifest update, peer roaming frame, route evaluation, WireGuard/nftables render, and `dgx-spark` heartbeat passes through two layers:

1. **Cryptographic Envelope Verification (Ed25519 + Domain Separation)**:
   - `lean-mesh-manifest-v1:`: Signed by the coordinator Ed25519 key (`MeshManifest.coordinator_pubkey_hex`).
   - `lean-mesh-roam-v1:`: Signed by the **peer's own pinned Ed25519 signing key** (`MeshPeer.sign_pubkey_hex`), preventing any compromised peer from hijacking another peer's endpoint (`roam_rejects_unauthenticated`).
   - `lean-mesh-heartbeat-v1:`: Signed by `dgx-spark`'s pinned Ed25519 signing key (`id = "dgx-spark"`).
   - `lean-mesh-render-v1:`: Signed by the requesting node's pinned Ed25519 signing key (`GET /api/mesh/render-wg/:node` and `GET /api/mesh/render-nft/:node`).
2. **Lean 4 Machine-Checked Decision Kernel (`LeanMesh.Kernel` / `LeanMesh.Spec`)**:
   - Compiled to a zero-runtime-reflection C-ABI library (`0 import Lean`, `0 sorryAx`, `0` custom axioms, **278 machine-checked theorems** across 12 C-ABI exports).
   - Enforces strict epoch monotonicity (`leanmesh_ratchet_epoch_step`), mesh subnet containment (`10.88.0.0/16`, `overlayHostIpValid`), capability matrix isolation (`leanmesh_eval_route_step`: workers cannot SSH laterally or initiate reverse connections to `agent-core`), Biometric JIT SSH route opening (`jitBiometricGrant == 1 && bunkerState == 0 && nowEpoch < jitExpiresAt`), and the **180-second `dgx-spark` Dead-Man's Switch** (`leanmesh_bunker_isolate_step`).

---

## 2. Fleet Overlay Address Map (`10.88.0.0/16`, UDP `51888`)

| Node ID (`id`) | Node Class (`node_class`) | Mesh IP (`overlay_ip/prefix_len`) | Default Endpoint (`:51888`) | Orb Compute (`:3088`) | Orb Security (`lean-mesh` + JIT + Bunker) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `agent-core` | `ControlPlane` | `10.88.0.1/32` | `65.109.98.246:51888` | Yes (`:3088` colocated) | Control Plane (`:3000/:3002`) |
| `dgx-spark` | `SovereignVault` | `10.88.0.2/32` | Dynamic (hub-relayed via `agent-core`) | Yes (`:3088` + `:3089`) | Enrolled (30s signed heartbeat + JIT + Bunker) |
| `thomas-md` | `ReservedProd` | `10.88.0.3/32` | `95.216.244.60:51888` | **No** (no mission scheduling) | Enrolled (`lean-mesh` + JIT + Bunker) |
| `polymath` | `ReservedProd` | `10.88.0.4/32` | `5.135.152.216:51888` | **No** (no mission scheduling) | Enrolled (`lean-mesh` + JIT + Bunker) |
| `maven-repo` | `ReservedProd` | `10.88.0.5/32` | `141.94.78.32:51888` | **No** (no mission scheduling) | Enrolled (`lean-mesh` + JIT + Bunker) |
| `ashur` | `ComputeWorker` | `10.88.0.11/32` | `188.40.69.160:51888` | Yes (`sandboxed-node` `:3088`) | Enrolled (`lean-mesh` + JIT + Canary/Bunker) |
| `babylon` | `ComputeWorker` | `10.88.0.12/32` | `54.36.175.109:51888` | Yes (`sandboxed-node` `:3088`) | Enrolled (`lean-mesh` + JIT + Canary/Bunker) |
| `nippur` | `ComputeWorker` | `10.88.0.13/32` | `37.187.92.183:51888` | Yes (`sandboxed-node` `:3088`) | Enrolled (`lean-mesh` + JIT + Canary/Bunker) |
| `uruk` | `ComputeWorker` | `10.88.0.14/32` | `95.216.112.253:51888` | Yes (`sandboxed-node` `:3088`) | Enrolled (`lean-mesh` + JIT + Canary/Bunker) |
| `watchtower` | `MediaGateway` | `10.88.0.15/32` | `147.135.137.133:51888` | **No** (no mission scheduling) | Enrolled (`lean-mesh` + JIT + Bunker) |
| `nimrud` | `ComputeWorker` | `10.88.0.18/32` | `51.195.100.33:51888` | Yes (`sandboxed-node` `:3088`) | Enrolled (`lean-mesh` + JIT + Canary/Bunker) |
| `macbook-air` | `OperatorAdmin` | `10.88.0.100/32` | Dynamic roaming | Operator Client | Enrolled (`Touch ID` + breakglass `:22`) |

*(Retiring hosts `utu-deposit-signer` `10.88.0.21/32` and `api-federation` `10.88.0.22/32` are classified as `RetiredReadOnly`.)*

---

## 3. Mode A: Orb-Integrated Operation

On `agent-core`, Orb exposes the mesh control plane under `/api/mesh`:

| Endpoint | Method | Purpose |
| :--- | :---: | :--- |
| `/api/mesh/status` | `GET` | Returns manifest epoch, peer count, `bunker_state`, and `dgx-spark` dead-man status |
| `/api/mesh/manifest` | `GET` / `POST` | Fetch or atomically advance the signed `MeshManifest` (`leanmesh_ratchet_epoch_step`) |
| `/api/mesh/evaluate-route` | `POST` | Evaluate `(src, dst, proto, port, jit_biometric)` against `leanmesh_eval_route_step` |
| `/api/mesh/roam` | `POST` | Submit a peer-signed `RoamRequest` (`leanmesh_endpoint_roam_ok`) |
| `/api/mesh/heartbeat` | `POST` | Submit a `dgx-spark`-signed `HeartbeatRequest` (`leanmesh_bunker_isolate_step`) |
| `/api/mesh/render-wg/:node` | `GET` | Render `wg-leanmesh0.conf` (requires `X-LeanMesh-*` node signature headers) |
| `/api/mesh/render-nft/:node` | `GET` | Render `table inet lean_mesh` (`nftables`) (requires `X-LeanMesh-*` node signature headers) |

### Remote Node & Mission Traffic Routing
- `SANDBOXED_REMOTE_NODES` on `agent-core` addresses all worker nodes over `wg-leanmesh0` (`http://10.88.0.11:3088`, `http://10.88.0.12:3088`, `http://10.88.0.13:3088`, `http://10.88.0.14:3088`, `http://10.88.0.18:3088`, `http://10.88.0.2:3088`, `http://10.88.0.2:3089`).
- Each worker node enforces `table inet lean_mesh` (`nftables`) + `sandboxed-node-firewall.sh` so port `3088` is reachable only from `agent-core` (`10.88.0.1`) and loopback.
- Missions running on worker nodes reach `dgx-spark` (`10.88.0.2:8888-8890` for Hindsight memory) over `wg-leanmesh0`, while lateral worker-to-worker SSH (`:22`) is dropped by default unless opened by a Biometric JIT grant (`request_privileged_access`).

---

## 4. Mode B: Standalone Operation (Adding a Machine *Without* Orb)

You do **not** need Orb or `sandboxed-node` installed on a machine to join `wg-leanmesh0`.

### Step 1: Install the standalone `lean-mesh` binary
Copy `/usr/local/bin/lean-mesh` (built from `Th0rgal/lean-mesh`) to the target host and ensure `wireguard-tools` and `nftables` are installed:
```bash
apt-get install -y wireguard-tools nftables
install -m 0755 lean-mesh /usr/local/bin/lean-mesh
install -d -m 0700 /etc/lean-mesh
```

### Step 2: Generate WireGuard & Ed25519 Node Keys on the Target Host
```bash
umask 077
wg genkey | tee /etc/lean-mesh/wg.key | wg pubkey > /etc/lean-mesh/wg.pub
lean-mesh node-keygen --out-seed /etc/lean-mesh/node_sign.key > /etc/lean-mesh/node_sign.pub
```

### Step 3: Register the Peer in the Signed `MeshManifest`
Add the `MeshPeer` entry (`id`, `node_class`, `wg_pubkey` base64 from `wg.pub`, `sign_pubkey_hex` 64-hex from `node_sign.pub`, `overlay_ip: "10.88.0.<id>"`, `prefix_len: 32`, `endpoint: "<public_ip>:51888"`, `persistent_keepalive: 25`, `roam_generation: 1`, `key_epoch: 1`, `is_hub: false`) and any explicit `rules` to `manifest.json`, bump `epoch`, and sign it with the coordinator signing seed:
```bash
lean-mesh sign-manifest \
  --manifest /etc/lean-mesh/manifest.json \
  --signing-key-file /etc/lean-mesh/coordinator.seed \
  --output /etc/lean-mesh/manifest.json
```
*(If `agent-core` is managing the manifest, POST the signed manifest to `POST /api/mesh/manifest`.)*

### Step 4: Render & Apply WireGuard + `nftables` Locally
On the standalone host, `lean-mesh` verifies the Ed25519 signature and all `LeanMesh.Kernel` invariants locally before emitting config:
```bash
lean-mesh verify-manifest /etc/lean-mesh/manifest.json
lean-mesh render-wg \
  --manifest /etc/lean-mesh/manifest.json \
  --node <node-id> \
  --private-key-file /etc/lean-mesh/wg.key > /etc/wireguard/wg-leanmesh0.conf
chmod 600 /etc/wireguard/wg-leanmesh0.conf
systemctl enable --now wg-quick@wg-leanmesh0

lean-mesh render-nft \
  --manifest /etc/lean-mesh/manifest.json \
  --node <node-id> | nft -f -
```

### Step 5: Live WireGuard Dump Reconciliation (`reconcile-wg`)
To inspect the formal reconciliation plan (`Keep`, `AddOrUpdate`, `RemoveStale`) between `wg show wg-leanmesh0 dump` and the verified manifest:
```bash
wg show wg-leanmesh0 dump > /run/wg-leanmesh0.dump
lean-mesh reconcile-wg \
  --manifest /etc/lean-mesh/manifest.json \
  --node <node-id> \
  --wg-dump /run/wg-leanmesh0.dump
```
