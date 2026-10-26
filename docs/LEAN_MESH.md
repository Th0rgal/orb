# Lean-Mesh (`wg-leanmesh0`)

`lean-mesh` ([`Th0rgal/lean-mesh`](https://github.com/Th0rgal/lean-mesh), integrated in `crates/lean-mesh` and `src/api/mesh.rs`) is Paloma's zero-trust WireGuard + `nftables` overlay network (`10.88.0.0/16` on `wg-leanmesh0`). It replaces Tailscale (`tailscaled` / Headscale) with a tiny, self-sovereign Rust + Lean 4 verified mesh that operates in two modes simultaneously:

- **Mode A (Orb-Integrated)**: `agent-core` (`10.88.0.1`) serves `/api/mesh/*`, enforces `LeanMesh.Kernel` C-ABI transitions, and worker nodes (`sandboxed-node`) + `dgx-spark` route all node dispatch (`:3088`), Hindsight memory (`:8888-:8890`), telemetry (`:3000`), and Biometric JIT SSH grants over `wg-leanmesh0`.
- **Mode B (Standalone CLI without Orb)**: Any machine that does **not** run Orb or `sandboxed-node` (`thomas-md`, `polymath`, `maven-repo`, `watchtower`, workstations, or any new VPS/NAS) runs only the standalone `/usr/local/bin/lean-mesh` binary (`Th0rgal/lean-mesh`) + kernel `wireguard-tools` + `nftables`.

---

## 1. Architecture & Formal Kernel (`LeanMesh.Kernel`)

Every manifest update, peer roaming frame, route evaluation, WireGuard/nftables render, and `dgx-spark` heartbeat passes through two layers:

1. **Cryptographic Envelope Verification (Ed25519 + Domain Separation)**:
   - `LEAN_MESH_MANIFEST_V1`: Signed by the authority Ed25519 key (`authority_pubkey_hex`).
   - `LEAN_MESH_ROAM_V1`: Signed by the **peer's own pinned Ed25519 signing key** (`MeshPeer.sign_pubkey_hex`), preventing any compromised peer from hijacking another peer's endpoint (`PeerIdentityHijackFree`).
   - `LEAN_MESH_HEARTBEAT_V1`: Signed by `dgx-spark`'s pinned Ed25519 signing key (`node_id = 2`).
   - `LEAN_MESH_RENDER_V1`: Signed by the requesting node's pinned Ed25519 signing key (`GET /api/mesh/render-wg/:node` and `GET /api/mesh/render-nft/:node`).
2. **Lean 4 Machine-Checked Decision Kernel (`LeanMesh.Kernel` / `LeanMesh.Spec`)**:
   - Compiled to a zero-runtime-reflection C-ABI library (`0 import Lean`, `0 sorryAx`, `0` custom axioms, **278 machine-checked theorems**).
   - Enforces strict epoch monotonicity (`step_manifest_epoch`), mesh subnet containment (`10.88.0.0/16`, `validMeshIp`), capability matrix isolation (workers cannot SSH laterally or initiate reverse connections to `agent-core`), Biometric JIT SSH route opening (`jit_grant_id != 0` with `grant_expires_at > now_epoch`), and the **180-second `dgx-spark` Dead-Man's Switch** (`step_bunker_isolate`).

---

## 2. Fleet Overlay Address Map (`10.88.0.0/16`)

| Node Name | Node ID | Role | Mesh IP (`wg-leanmesh0`) | Public / Endpoint |
| :--- | :---: | :--- | :--- | :--- |
| `agent-core` | `1` | ControlPlane (`orb` / `sandboxed-sh`) | `10.88.0.1/32` | `65.109.98.246:51880` |
| `dgx-spark` | `2` | SovereignBrain (Hindsight, Arbiter, Node) | `10.88.0.2/32` | Dynamic (hub-relayed via `agent-core`) |
| `ashur` | `11` | Worker (`sandboxed-node` `:3088`) | `10.88.0.11/32` | `188.40.69.160:51880` |
| `babylon` | `12` | Worker (`sandboxed-node` `:3088`) | `10.88.0.12/32` | `54.36.175.109:51880` |
| `nippur` | `13` | Worker (`sandboxed-node` `:3088`) | `10.88.0.13/32` | `37.187.92.183:51880` |
| `old-agent` | `14` | Worker (`sandboxed-node` `:3088`) | `10.88.0.14/32` | `95.216.112.253:51880` |
| `thomas-md` | `20` | Production (Standalone — no Orb) | `10.88.0.20/32` | `95.216.244.60:51880` |
| `polymath` | `21` | Production (Standalone — no Orb) | `10.88.0.21/32` | `5.135.152.216:51880` |
| `maven-repo` | `30` | ArtifactEdge (Standalone — no Orb) | `10.88.0.30/32` | `141.94.78.32:51880` |
| `watchtower` | `31` | MediaExit (Standalone — no Orb) | `10.88.0.31/32` | `147.135.137.133:51880` |
| `macbook-air` | `100` | Operator (`Touch ID` P-256 authority) | `10.88.0.100/32` | Dynamic roaming |

---

## 3. Mode A: Orb-Integrated Operation

On `agent-core`, Orb exposes the mesh control plane under `/api/mesh`:

| Endpoint | Method | Purpose |
| :--- | :---: | :--- |
| `/api/mesh/status` | `GET` | Returns manifest epoch, peer count, bunker isolation state, and `dgx-spark` dead-man status |
| `/api/mesh/manifest` | `GET` / `POST` | Fetch or atomically advance the signed `MeshManifest` (`step_manifest_epoch`) |
| `/api/mesh/evaluate-route` | `POST` | Evaluate `(src, dst, proto, port, jit_grant)` against `LeanMesh.Kernel` |
| `/api/mesh/roam` | `POST` | Submit a peer-signed `SignedRoamUpdate` (`step_peer_roam`) |
| `/api/mesh/heartbeat` | `POST` | Submit a `dgx-spark`-signed `SignedHeartbeat` (`step_bunker_isolate`) |
| `/api/mesh/render-wg/:node` | `GET` | Render `wg-leanmesh0.conf` (requires `X-LeanMesh-*` node signature headers) |
| `/api/mesh/render-nft/:node` | `GET` | Render `table inet lean_mesh` (`nftables`) (requires `X-LeanMesh-*` node signature headers) |

### Remote Node & Mission Traffic Routing
- `SANDBOXED_REMOTE_NODES` on `agent-core` addresses all worker nodes over `wg-leanmesh0` (`http://10.88.0.11:3088`, `http://10.88.0.12:3088`, `http://10.88.0.13:3088`, `http://10.88.0.14:3088`, `http://10.88.0.2:3088`).
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
openssl rand -hex 32 > /etc/lean-mesh/node_sign.key
```

### Step 3: Register the Peer in the Signed `MeshManifest`
Add the peer entry (`node_id`, `name`, `role`, `wg_pubkey_hex`, `sign_pubkey_hex`, `mesh_ip: "10.88.0.<id>"`, `endpoint`, `listen_port: 51880`) and any explicit `capabilities` rules to `manifest.json`, then sign it with the authority key:
```bash
lean-mesh sign-manifest \
  --manifest /etc/lean-mesh/manifest.json \
  --signing-key-file /etc/lean-mesh/authority.key \
  --output /etc/lean-mesh/manifest.json
```
*(If `agent-core` is managing the manifest, POST the signed manifest to `POST /api/mesh/manifest`.)*

### Step 4: Render & Reconcile WireGuard + `nftables` Locally
On the standalone host, `lean-mesh` verifies the Ed25519 signature and all `LeanMesh.Kernel` invariants locally before emitting config:
```bash
lean-mesh verify-manifest --manifest /etc/lean-mesh/manifest.json
lean-mesh render-wg \
  --manifest /etc/lean-mesh/manifest.json \
  --node <host-name> \
  --private-key-file /etc/lean-mesh/wg.key > /etc/wireguard/wg-leanmesh0.conf
chmod 600 /etc/wireguard/wg-leanmesh0.conf
systemctl enable --now wg-quick@wg-leanmesh0

lean-mesh render-nft \
  --manifest /etc/lean-mesh/manifest.json \
  --node <host-name> | nft -f -
```

### Step 5: Zero-Downtime Live Reconciliation (`reconcile-wg`)
When the manifest updates (new peer or roamed endpoint), run `reconcile-wg` to compute exact `wg set` commands without bouncing the interface:
```bash
wg show wg-leanmesh0 dump > /run/wg-leanmesh0.dump
lean-mesh reconcile-wg \
  --manifest /etc/lean-mesh/manifest.json \
  --node <host-name> \
  --interface wg-leanmesh0 \
  --dump-file /run/wg-leanmesh0.dump | sh -e
lean-mesh render-nft --manifest /etc/lean-mesh/manifest.json --node <host-name> | nft -f -
```
