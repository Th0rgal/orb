//! Formally Verified WireGuard Mesh Control Plane (`lean-mesh` integration for Orb).
//!
//! Bridges `LeanMesh.Kernel` (`leanmesh_*` C-ABI gates) with Orb's control plane and
//! Biometric JIT Privilege Broker (`super::privilege_broker`):
//! - Maintains the signed `MeshManifest` (`10.88.0.0/16` overlay) with monotonic epoch
//!   and emergency panic ratcheting (`leanmesh_ratchet_epoch_step`), pinned coordinator
//!   Ed25519 identity, and unary + pairwise `/32` disjointness (`leanmesh_overlay_ip_step`).
//! - Evaluates non-transitive capability routes (`leanmesh_eval_route_step`) and NAT
//!   relay path selection (`leanmesh_relay_select_step`), enforcing `dgx-spark`
//!   `SovereignVault` non-interference and leaf-worker `:3088` isolation.
//! - Protects endpoint roaming with pre-window AEAD/bogon verification
//!   (`leanmesh_endpoint_roam_step`) followed by per-peer RFC 6479 64-packet anti-replay
//!   windows (`leanmesh_replay_window_step`) and automatic manifest re-signing.
//! - Synchronizes Orb's Bunker Mode with the persistent 4-state Mesh Bunker & 180s
//!   Sovereign Dead-Man's Switch (`leanmesh_bunker_isolate_step`), verifying Ed25519
//!   heartbeat signatures, anti-replay sequence numbers, and server-side biometric
//!   `PrivilegeBroker` unbunker grants BEFORE updating `last_heartbeat_at`.
//! - Renders deterministic WireGuard (`wg-leanmesh0.conf`) and `nftables`
//!   (`table inet lean_mesh`) configurations only when the manifest passes
//!   `verify_formal(0, 0, now)`.

use std::collections::BTreeMap;
use std::io::Read;
use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    routing::{get, post},
    Extension, Json, Router,
};
use chrono::Utc;
use ed25519_dalek::SigningKey;
use lean_mesh::{
    check_endpoint_roam, select_relay_path, step_bunker_isolate, verify_frame_bounds,
    verify_heartbeat_signature, verify_jit_lease, BunkerState as MeshBunkerState,
    BunkerTransition, MeshManifest, MeshProto, NodeClass, RelayPathKind, ReplayWindow64,
    RouteDecision, LEAN_MESH_DEFAULT_WG_PORT, LEAN_MESH_FRAME_MAGIC, LEAN_MESH_INTERFACE_NAME,
    LEAN_MESH_PROTOCOL_VERSION, LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::approval_flow::ApprovalState;
use super::auth::AuthUser;
use super::routes::AppState;
use crate::orb_spec::BunkerState as OrbBunkerState;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PeerRoamState {
    pub replay_window: ReplayWindow64,
    pub last_roam_seq: u64,
    pub last_roam_epoch: u64,
}

fn default_bunker_normal() -> MeshBunkerState {
    MeshBunkerState::Normal
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersistedMeshState {
    pub coordinator_seed_hex: String,
    pub pinned_coordinator_pubkey_hex: String,
    pub manifest: MeshManifest,
    pub peer_roam: BTreeMap<String, PeerRoamState>,
    #[serde(default)]
    pub heartbeat_replay: BTreeMap<String, ReplayWindow64>,
    pub last_heartbeat_at: u64,
    pub is_sovereign_node: bool,
    #[serde(default = "default_bunker_normal")]
    pub bunker_state: MeshBunkerState,
    pub active_relay_sessions: u32,
    pub max_relay_sessions: u32,
    #[serde(skip)]
    pub corrupted_state: bool,
}

impl PersistedMeshState {
    /// Decodes the coordinator Ed25519 signing key and verifies it matches the pinned
    /// coordinator public key. Fails closed (`Err`) on any corruption — never falls back
    /// to a hardcoded or predictable key.
    pub fn signing_key(&self) -> Result<SigningKey, String> {
        if self.corrupted_state {
            return Err("mesh store is in fail-closed corrupted state".into());
        }
        let raw = hex::decode(self.coordinator_seed_hex.trim())
            .map_err(|_| "corrupted coordinator_seed_hex in PersistedMeshState".to_string())?;
        let bytes: [u8; 32] = raw
            .try_into()
            .map_err(|_| "coordinator_seed_hex must decode to exactly 32 bytes".to_string())?;
        if bytes == [0u8; 32] {
            return Err("all-zero coordinator seed rejected".into());
        }
        let sk = SigningKey::from_bytes(&bytes);
        let derived_pub = hex::encode(sk.verifying_key().to_bytes());
        if derived_pub != self.pinned_coordinator_pubkey_hex
            || derived_pub != self.manifest.coordinator_pubkey_hex
        {
            return Err(
                "coordinator signing key does not match pinned_coordinator_pubkey_hex".into(),
            );
        }
        Ok(sk)
    }
}

pub struct MeshStore {
    path: PathBuf,
    inner: Mutex<PersistedMeshState>,
}

static MESH_STORE: OnceLock<Arc<MeshStore>> = OnceLock::new();

fn unix_now() -> u64 {
    Utc::now().timestamp().max(1) as u64
}

fn generate_csprng_seed() -> Result<[u8; 32], String> {
    let mut f = std::fs::File::open("/dev/urandom")
        .map_err(|e| format!("failed to open /dev/urandom: {e}"))?;
    let mut seed = [0u8; 32];
    f.read_exact(&mut seed)
        .map_err(|e| format!("failed to read 32 bytes from /dev/urandom: {e}"))?;
    if seed == [0u8; 32] {
        return Err("CSPRNG returned all-zero seed".into());
    }
    Ok(seed)
}

fn write_initial_private_sync(path: &std::path::Path, state: &PersistedMeshState) -> Result<(), String> {
    let json = serde_json::to_string_pretty(state).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

impl MeshStore {
    pub fn open(working_dir: PathBuf) -> Arc<Self> {
        let dir = working_dir.join(".sandboxed-sh");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("lean_mesh_state.json");
        let now = unix_now();

        let state = match std::fs::read_to_string(&path) {
            Ok(raw) => match serde_json::from_str::<PersistedMeshState>(&raw) {
                Ok(loaded)
                    if loaded.signing_key().is_ok() && loaded.manifest.verify_ed25519() =>
                {
                    loaded
                }
                _ => {
                    // Existing state file on disk is corrupted or tampered: fail closed in
                    // `HardLockdown` with `corrupted_state = true` rather than overwriting
                    // with a new or predictable key.
                    let fallback_seed = generate_csprng_seed().unwrap_or([0x99; 32]);
                    let sk = SigningKey::from_bytes(&fallback_seed);
                    let manifest = MeshManifest::paloma_fleet_default(now, &sk);
                    PersistedMeshState {
                        coordinator_seed_hex: String::new(),
                        pinned_coordinator_pubkey_hex: manifest.coordinator_pubkey_hex.clone(),
                        manifest,
                        peer_roam: BTreeMap::new(),
                        heartbeat_replay: BTreeMap::new(),
                        last_heartbeat_at: now,
                        is_sovereign_node: true,
                        bunker_state: MeshBunkerState::HardLockdown,
                        active_relay_sessions: 0,
                        max_relay_sessions: 128,
                        corrupted_state: true,
                    }
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                match generate_csprng_seed() {
                    Ok(seed) => {
                        let sk = SigningKey::from_bytes(&seed);
                        let manifest = MeshManifest::paloma_fleet_default(now, &sk);
                        let pubkey_hex = manifest.coordinator_pubkey_hex.clone();
                        let fresh = PersistedMeshState {
                            coordinator_seed_hex: hex::encode(seed),
                            pinned_coordinator_pubkey_hex: pubkey_hex,
                            manifest,
                            peer_roam: BTreeMap::new(),
                            heartbeat_replay: BTreeMap::new(),
                            last_heartbeat_at: now,
                            is_sovereign_node: true,
                            bunker_state: MeshBunkerState::Normal,
                            active_relay_sessions: 0,
                            max_relay_sessions: 128,
                            corrupted_state: false,
                        };
                        let _ = write_initial_private_sync(&path, &fresh);
                        fresh
                    }
                    Err(_) => {
                        let sk = SigningKey::from_bytes(&[0x99; 32]);
                        let manifest = MeshManifest::paloma_fleet_default(now, &sk);
                        PersistedMeshState {
                            coordinator_seed_hex: String::new(),
                            pinned_coordinator_pubkey_hex: manifest.coordinator_pubkey_hex.clone(),
                            manifest,
                            peer_roam: BTreeMap::new(),
                            heartbeat_replay: BTreeMap::new(),
                            last_heartbeat_at: now,
                            is_sovereign_node: true,
                            bunker_state: MeshBunkerState::HardLockdown,
                            active_relay_sessions: 0,
                            max_relay_sessions: 128,
                            corrupted_state: true,
                        }
                    }
                }
            }
            Err(_) => {
                let fallback_seed = generate_csprng_seed().unwrap_or([0x99; 32]);
                let sk = SigningKey::from_bytes(&fallback_seed);
                let manifest = MeshManifest::paloma_fleet_default(now, &sk);
                PersistedMeshState {
                    coordinator_seed_hex: String::new(),
                    pinned_coordinator_pubkey_hex: manifest.coordinator_pubkey_hex.clone(),
                    manifest,
                    peer_roam: BTreeMap::new(),
                    heartbeat_replay: BTreeMap::new(),
                    last_heartbeat_at: now,
                    is_sovereign_node: true,
                    bunker_state: MeshBunkerState::HardLockdown,
                    active_relay_sessions: 0,
                    max_relay_sessions: 128,
                    corrupted_state: true,
                }
            }
        };

        Arc::new(Self {
            path,
            inner: Mutex::new(state),
        })
    }

    async fn save(&self, state: &PersistedMeshState) -> Result<(), String> {
        if state.corrupted_state {
            return Err("refusing to overwrite corrupted mesh state file".into());
        }
        super::approval_flow::persist_private(&self.path, state).await
    }
}

pub fn store(app_state: &AppState) -> Arc<MeshStore> {
    MESH_STORE
        .get_or_init(|| MeshStore::open(app_state.config.working_dir.clone()))
        .clone()
}

fn map_orb_bunker_to_mesh(orb_bunker: OrbBunkerState) -> MeshBunkerState {
    match orb_bunker {
        OrbBunkerState::Normal => MeshBunkerState::Normal,
        OrbBunkerState::SoftQuarantine => MeshBunkerState::SoftQuarantine,
        OrbBunkerState::HardLockdown => MeshBunkerState::HardLockdown,
    }
}

async fn effective_mesh_bunker(
    app_state: &AppState,
    mesh_state: &PersistedMeshState,
    now_epoch: u64,
) -> BunkerTransition {
    let orb_bunker = super::privilege_broker::store(app_state).bunker_state().await;
    let base = mesh_state.bunker_state.max(map_orb_bunker_to_mesh(orb_bunker));
    let hb_fresh = mesh_state.last_heartbeat_at <= now_epoch
        && now_epoch.saturating_sub(mesh_state.last_heartbeat_at) <= LEAN_MESH_SOVEREIGN_DEADMAN_SECS;
    step_bunker_isolate(
        base,
        mesh_state.is_sovereign_node,
        mesh_state.corrupted_state || orb_bunker == OrbBunkerState::HardLockdown,
        orb_bunker == OrbBunkerState::SoftQuarantine,
        0,
        false,
        hb_fresh,
        now_epoch,
        mesh_state.last_heartbeat_at,
        LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
    )
}

/// Pure server-side heartbeat verification & bunker state transition step.
///
/// Enforces:
/// 1. `is_sovereign_node` is derived strictly from the pinned manifest (`NodeClass::SovereignVault`),
///    never from a client boolean.
/// 2. `canary_tripped` and `auth_failure_burst` are derived strictly from server-side `orb_bunker`.
/// 3. Ed25519 signature over `("lean-mesh-heartbeat-v1", peer_name, heartbeat_seq, timestamp)`,
///    timestamp freshness, and `ReplayWindow64` anti-replay are verified **before** updating
///    `last_heartbeat_at`.
/// 4. If heartbeat verification fails, `last_heartbeat_at` is NOT updated and `step_bunker_isolate`
///    is evaluated with `heartbeat_valid = false` against the previously persisted `last_heartbeat_at`,
///    so a forged, stale, or replayed heartbeat cannot delay or clear `SovereignDeadManTripped`.
pub fn process_heartbeat_step(
    state: &mut PersistedMeshState,
    req: &HeartbeatRequest,
    orb_bunker: OrbBunkerState,
    biometric_unbunker_verified: bool,
    now_epoch: u64,
) -> Result<BunkerTransition, (StatusCode, String, Option<BunkerTransition>)> {
    if state.corrupted_state {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "mesh store is in fail-closed corrupted state".into(),
            None,
        ));
    }

    let peer = state.manifest.find_peer(&req.peer_name).map_err(|e| {
        (StatusCode::NOT_FOUND, e.to_string(), None)
    })?;
    let peer_active = !peer.revoked && now_epoch < peer.expires_at;
    let is_sovereign_peer = peer.node_class == NodeClass::SovereignVault;
    let effective_sovereign = state.is_sovereign_node || is_sovereign_peer;

    let canary_tripped = orb_bunker == OrbBunkerState::HardLockdown;
    let auth_failure_burst = orb_bunker == OrbBunkerState::SoftQuarantine;
    let base = state.bunker_state.max(map_orb_bunker_to_mesh(orb_bunker));

    let sig_ok = peer_active
        && verify_heartbeat_signature(
            &state.pinned_coordinator_pubkey_hex,
            &req.peer_name,
            req.heartbeat_seq,
            req.timestamp,
            &req.signature_hex,
        );
    let ts_fresh = req.timestamp <= now_epoch.saturating_add(30)
        && now_epoch.saturating_sub(req.timestamp) <= LEAN_MESH_SOVEREIGN_DEADMAN_SECS;

    let replay_ok = if sig_ok && ts_fresh {
        state
            .heartbeat_replay
            .entry(req.peer_name.clone())
            .or_default()
            .check_and_advance(req.heartbeat_seq)
    } else {
        false
    };

    let heartbeat_valid = sig_ok && ts_fresh && replay_ok;
    if !heartbeat_valid {
        // Evaluate `step_bunker_isolate` against the OLD `state.last_heartbeat_at` with
        // `heartbeat_valid = false` and `biometric_unbunker = false`.
        let transition = step_bunker_isolate(
            base,
            effective_sovereign,
            canary_tripped,
            auth_failure_burst,
            0,
            false,
            false,
            now_epoch,
            state.last_heartbeat_at,
            LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
        );
        if transition.next_state > state.bunker_state {
            state.bunker_state = transition.next_state;
        }
        let reason = if !sig_ok {
            "invalid Ed25519 heartbeat signature or inactive peer"
        } else if !ts_fresh {
            "stale or future heartbeat timestamp"
        } else {
            "replayed heartbeat_seq rejected by ReplayWindow64"
        };
        return Err((StatusCode::UNAUTHORIZED, reason.into(), Some(transition)));
    }

    // Only update `last_heartbeat_at` after cryptographic + freshness + anti-replay checks succeed.
    state.last_heartbeat_at = req.timestamp.min(now_epoch);
    state.is_sovereign_node = effective_sovereign;
    let transition = step_bunker_isolate(
        base,
        effective_sovereign,
        canary_tripped,
        auth_failure_burst,
        0,
        biometric_unbunker_verified,
        true,
        now_epoch,
        state.last_heartbeat_at,
        LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
    );
    state.bunker_state = transition.next_state;
    Ok(transition)
}

#[derive(Debug, Deserialize)]
pub struct EvaluateRouteRequest {
    pub src_peer: String,
    pub dst_peer: String,
    #[serde(default = "default_proto")]
    pub proto: MeshProto,
    pub dst_port: u32,
    #[serde(default)]
    pub jit_grant_id: Option<Uuid>,
    #[serde(default)]
    pub lan_reachable: bool,
    #[serde(default = "default_true")]
    pub wan_reachable: bool,
    #[serde(default = "default_true")]
    pub relay_healthy: bool,
    pub direct_handshake_at: Option<u64>,
}

fn default_proto() -> MeshProto {
    MeshProto::Tcp
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Serialize)]
pub struct EvaluateRouteResponse {
    pub decision: RouteDecision,
    pub relay_path: RelayPathKind,
    pub effective_bunker_state: MeshBunkerState,
    pub epoch: u64,
}

#[derive(Debug, Deserialize)]
pub struct EndpointRoamRequest {
    pub peer_name: String,
    pub candidate_ip: String,
    pub candidate_port: u16,
    pub pkt_seq: u64,
    pub aead_auth_ok: bool,
    #[serde(default)]
    pub allow_private_roam: bool,
}

#[derive(Debug, Deserialize)]
pub struct HeartbeatRequest {
    pub peer_name: String,
    pub heartbeat_seq: u64,
    pub timestamp: u64,
    pub signature_hex: String,
    #[serde(default)]
    pub unbunker_grant_id: Option<Uuid>,
}

async fn get_mesh_status(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
) -> Json<Value> {
    let store = store(&app_state);
    let now = unix_now();
    let guard = store.inner.lock().await;
    let bunker = effective_mesh_bunker(&app_state, &guard, now).await;
    let frame_gate_ok = verify_frame_bounds(
        LEAN_MESH_FRAME_MAGIC,
        LEAN_MESH_PROTOCOL_VERSION,
        1,
        true,
        64,
        512,
        4096,
        4096,
    );

    Json(json!({
        "interface": LEAN_MESH_INTERFACE_NAME,
        "default_wg_port": LEAN_MESH_DEFAULT_WG_PORT,
        "epoch": guard.manifest.epoch,
        "panic_seq": guard.manifest.panic_seq,
        "issued_at": guard.manifest.issued_at,
        "expires_at": guard.manifest.expires_at,
        "coordinator_pubkey_hex": guard.pinned_coordinator_pubkey_hex,
        "peers_count": guard.manifest.peers.len(),
        "rules_count": guard.manifest.rules.len(),
        "bunker": bunker,
        "persisted_bunker_state": guard.bunker_state,
        "last_heartbeat_at": guard.last_heartbeat_at,
        "sovereign_deadman_timeout_secs": LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
        "corrupted_state": guard.corrupted_state,
        "cabi_self_test_ok": frame_gate_ok,
    }))
}

async fn get_mesh_manifest(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
) -> Json<MeshManifest> {
    let store = store(&app_state);
    let guard = store.inner.lock().await;
    Json(guard.manifest.clone())
}

async fn post_mesh_manifest(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(candidate): Json<MeshManifest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let now = unix_now();
    let mut guard = store.inner.lock().await;

    if guard.corrupted_state {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "mesh store is in fail-closed corrupted state" })),
        ));
    }

    if candidate.coordinator_pubkey_hex != guard.pinned_coordinator_pubkey_hex {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({
                "error": "coordinator_pubkey_hex mismatch against pinned mesh coordinator key",
                "expected_coordinator_pubkey_hex": guard.pinned_coordinator_pubkey_hex,
            })),
        ));
    }

    let ratchet = candidate
        .verify_formal(guard.manifest.epoch, guard.manifest.panic_seq, now)
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": e.to_string(),
                    "current_epoch": guard.manifest.epoch,
                    "current_panic_seq": guard.manifest.panic_seq,
                })),
            )
        })?;

    guard.manifest = candidate;
    store.save(&guard).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e })),
        )
    })?;

    Ok(Json(json!({
        "admitted": ratchet.admitted,
        "advance_epoch": ratchet.advance_epoch,
        "advance_panic_seq": ratchet.advance_panic_seq,
        "new_epoch": guard.manifest.epoch,
        "new_panic_seq": guard.manifest.panic_seq,
    })))
}

async fn post_evaluate_route(
    State(app_state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<EvaluateRouteRequest>,
) -> Result<Json<EvaluateRouteResponse>, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let now = unix_now();
    let mut guard = store.inner.lock().await;
    let bunker = effective_mesh_bunker(&app_state, &guard, now).await;
    if bunker.next_state > guard.bunker_state {
        guard.bunker_state = bunker.next_state;
        let _ = store.save(&guard).await;
    }

    let src = guard.manifest.find_peer(&req.src_peer).map_err(|e| {
        (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": e.to_string() })),
        )
    })?;
    let dst = guard.manifest.find_peer(&req.dst_peer).map_err(|e| {
        (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": e.to_string() })),
        )
    })?;

    // Verify JIT lease via server-side `PrivilegeBroker` + `leanmesh_jit_lease_step`.
    let (jit_admitted, jit_expires_at) = if let Some(grant_id) = req.jit_grant_id {
        if let Some(grant) = super::privilege_broker::store(&app_state)
            .get(&user.id, grant_id)
            .await
        {
            let bio_ok = grant.state == ApprovalState::Approved
                && (grant.target_host == req.dst_peer || grant.target_host == "all");
            let same_owner = grant.owner == user.id;
            let revoked = grant.revoked_at.is_some() || grant.state == ApprovalState::Revoked;
            let issued_at = grant
                .decided_at
                .unwrap_or(grant.created_at)
                .timestamp()
                .max(0) as u64;
            let expires_at = grant
                .expires_at
                .map(|t| t.timestamp().max(0) as u64)
                .unwrap_or(0);
            let max_ttl_secs = (grant.ttl_minutes.clamp(1, 240) as u64) * 60;
            let jit_check = verify_jit_lease(
                bio_ok,
                same_owner,
                true,
                revoked,
                bunker.next_state,
                src.node_class,
                dst.node_class,
                now,
                issued_at,
                expires_at,
                max_ttl_secs,
            );
            (
                jit_check.admitted,
                if jit_check.admitted { expires_at } else { 0 },
            )
        } else {
            (false, 0)
        }
    } else {
        (false, 0)
    };

    let decision = guard
        .manifest
        .evaluate_route(
            &req.src_peer,
            &req.dst_peer,
            req.proto,
            req.dst_port,
            jit_admitted,
            jit_expires_at,
            bunker.next_state,
            now,
        )
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": e.to_string() })),
            )
        })?;

    let hs_at = req.direct_handshake_at.unwrap_or(now.saturating_sub(15));
    let relay_path = select_relay_path(
        decision.allowed,
        req.lan_reachable,
        req.wan_reachable,
        req.relay_healthy,
        src.id,
        dst.id,
        1, // `agent-core` (peer ID 1) is the canonical control-plane relay
        guard.active_relay_sessions,
        guard.max_relay_sessions,
        now,
        hs_at,
        120,
    );

    Ok(Json(EvaluateRouteResponse {
        decision,
        relay_path,
        effective_bunker_state: bunker.next_state,
        epoch: guard.manifest.epoch,
    }))
}

async fn post_endpoint_roam(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(req): Json<EndpointRoamRequest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let ip: Ipv4Addr = req.candidate_ip.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "invalid candidate IPv4 address" })),
        )
    })?;

    let store = store(&app_state);
    let now = unix_now();
    let mut guard = store.inner.lock().await;
    if guard.corrupted_state {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "mesh store is in fail-closed corrupted state" })),
        ));
    }

    let sk = guard.signing_key().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e })),
        )
    })?;

    let bunker = effective_mesh_bunker(&app_state, &guard, now).await;
    if bunker.next_state > guard.bunker_state {
        guard.bunker_state = bunker.next_state;
    }

    let peer_idx = guard
        .manifest
        .peers
        .iter()
        .position(|p| p.name == req.peer_name)
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": format!("unknown peer `{}`", req.peer_name) })),
            )
        })?;
    let pinned_static = guard.manifest.peers[peer_idx].pinned_static;

    let roam_state = guard
        .peer_roam
        .entry(req.peer_name.clone())
        .or_default();

    // 1. Verify AEAD authentication, static pinning, bogon/overlay IP classification,
    //    bunker state, and roam rate-limit BEFORE mutating the anti-replay window!
    let roam_ok = check_endpoint_roam(
        req.aead_auth_ok,
        pinned_static,
        ip,
        req.allow_private_roam,
        bunker.next_state,
        req.candidate_port,
        roam_state.last_roam_seq,
        req.pkt_seq,
        roam_state.last_roam_epoch,
        now,
        2,
    );

    if !roam_ok {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({
                "admitted": false,
                "reason": "rejected_by_leanmesh_endpoint_roam_step",
            })),
        ));
    }

    // 2. Advance RFC 6479 64-packet anti-replay window only after `leanmesh_endpoint_roam_step` succeeds.
    if !roam_state.replay_window.check_and_advance(req.pkt_seq) {
        return Err((
            StatusCode::CONFLICT,
            Json(json!({
                "admitted": false,
                "reason": "rejected_by_leanmesh_replay_window_step",
                "last_max_seq": roam_state.replay_window.last_max_seq,
            })),
        ));
    }

    roam_state.last_roam_seq = req.pkt_seq;
    roam_state.last_roam_epoch = now;
    let new_ep = format!("{}:{}", ip, req.candidate_port);
    guard.manifest.peers[peer_idx].endpoint = Some(new_ep.clone());
    guard.manifest.epoch = guard.manifest.epoch.saturating_add(1);
    guard.manifest.issued_at = now;
    guard.manifest.expires_at = now.saturating_add(guard.manifest.max_ttl_secs);
    guard.manifest.sign(&sk);
    store.save(&guard).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e })),
        )
    })?;

    Ok(Json(json!({
        "admitted": true,
        "peer": req.peer_name,
        "new_endpoint": new_ep,
        "pkt_seq": req.pkt_seq,
        "new_epoch": guard.manifest.epoch,
    })))
}

async fn render_wg_handler(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    AxumPath(node): AxumPath<String>,
) -> Result<String, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let now = unix_now();
    let guard = store.inner.lock().await;
    let bunker = effective_mesh_bunker(&app_state, &guard, now).await;

    guard
        .manifest
        .render_wireguard_config(&node, "<NODE_WG_PRIVATE_KEY>", bunker.next_state, now)
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": e.to_string() })),
            )
        })
}

async fn render_nft_handler(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    AxumPath(node): AxumPath<String>,
) -> Result<String, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let now = unix_now();
    let guard = store.inner.lock().await;
    let bunker = effective_mesh_bunker(&app_state, &guard, now).await;

    guard
        .manifest
        .render_nftables_policy(&node, bunker.next_state, now)
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": e.to_string() })),
            )
        })
}

async fn post_heartbeat(
    State(app_state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<HeartbeatRequest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let now = unix_now();
    let orb_bunker = super::privilege_broker::store(&app_state).bunker_state().await;

    // Verify optional `unbunker_grant_id` server-side via `PrivilegeBroker` (`RootExec` scope).
    let biometric_unbunker_verified = if let Some(grant_id) = req.unbunker_grant_id {
        let Some(grant) = super::privilege_broker::store(&app_state)
            .get(&user.id, grant_id)
            .await
        else {
            return Err((
                StatusCode::FORBIDDEN,
                Json(json!({
                    "error": "unknown or unauthorized unbunker_grant_id",
                })),
            ));
        };
        let valid_unbunker = grant.state == ApprovalState::Approved
            && grant.owner == user.id
            && grant.scope == super::privilege_broker::PrivilegeScope::RootExec
            && grant.revoked_at.is_none()
            && (grant.target_host == req.peer_name || grant.target_host == "all")
            && grant.live_grant(Utc::now(), orb_bunker);
        if !valid_unbunker {
            return Err((
                StatusCode::FORBIDDEN,
                Json(json!({
                    "error": "unbunker_grant_id is not an active biometric RootExec grant for this peer",
                })),
            ));
        }
        true
    } else {
        false
    };

    let mut guard = store.inner.lock().await;
    match process_heartbeat_step(
        &mut guard,
        &req,
        orb_bunker,
        biometric_unbunker_verified,
        now,
    ) {
        Ok(transition) => {
            store.save(&guard).await.map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": e })),
                )
            })?;
            Ok(Json(json!({
                "admitted": true,
                "peer": req.peer_name,
                "heartbeat_seq": req.heartbeat_seq,
                "last_heartbeat_at": guard.last_heartbeat_at,
                "bunker": transition,
            })))
        }
        Err((status, reason, maybe_transition)) => {
            if maybe_transition.is_some() && !guard.corrupted_state {
                let _ = store.save(&guard).await;
            }
            Err((
                status,
                Json(json!({
                    "admitted": false,
                    "error": reason,
                    "last_heartbeat_at": guard.last_heartbeat_at,
                    "bunker": maybe_transition,
                })),
            ))
        }
    }
}

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/status", get(get_mesh_status))
        .route("/manifest", get(get_mesh_manifest).post(post_mesh_manifest))
        .route("/evaluate-route", post(post_evaluate_route))
        .route("/roam", post(post_endpoint_roam))
        .route("/render-wg/:node", get(render_wg_handler))
        .route("/render-nft/:node", get(render_nft_handler))
        .route("/heartbeat", post(post_heartbeat))
}

#[cfg(test)]
mod tests {
    use super::*;
    use lean_mesh::sign_heartbeat;

    #[test]
    fn mesh_store_initializes_and_enforces_sovereign_isolation() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let ms = MeshStore::open(tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let guard = ms.inner.lock().await;
            assert!(!guard.corrupted_state);
            assert!(guard.signing_key().is_ok());
            let now = guard.manifest.issued_at + 5;
            assert!(guard.manifest.verify_formal(0, 0, now).is_ok());

            // Control plane -> worker :3088 is permitted.
            let ok_route = guard
                .manifest
                .evaluate_route(
                    "agent-core",
                    "ashur",
                    MeshProto::Tcp,
                    3088,
                    false,
                    0,
                    MeshBunkerState::Normal,
                    now,
                )
                .unwrap();
            assert!(ok_route.allowed);

            // Worker -> dgx-spark without biometric JIT grant is blocked.
            let blocked_vault = guard
                .manifest
                .evaluate_route(
                    "ashur",
                    "dgx-spark",
                    MeshProto::Tcp,
                    8888,
                    false,
                    0,
                    MeshBunkerState::Normal,
                    now,
                )
                .unwrap();
            assert!(!blocked_vault.allowed);
            assert!(blocked_vault.sovereign_violation_attempt);
        });
    }

    #[test]
    fn endpoint_roam_rejects_unauthenticated_before_replay_window_and_resigns_manifest() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let ms = MeshStore::open(tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let mut guard = ms.inner.lock().await;
            let now = guard.manifest.issued_at + 10;
            let initial_epoch = guard.manifest.epoch;

            // 1. Unauthenticated roam attempt for `macbook-air` (non-pinned) with pkt_seq = 77
            // is rejected by `check_endpoint_roam` BEFORE touching `replay_window`.
            let roam_unauth = check_endpoint_roam(
                false,
                false,
                Ipv4Addr::new(95, 216, 173, 237),
                false,
                MeshBunkerState::Normal,
                51888,
                0,
                77,
                0,
                now,
                2,
            );
            assert!(!roam_unauth);

            // 2. Legitimate authenticated packet with the same pkt_seq = 77 succeeds and advances window.
            let roam_auth = check_endpoint_roam(
                true,
                false,
                Ipv4Addr::new(95, 216, 173, 237),
                false,
                MeshBunkerState::Normal,
                51888,
                0,
                77,
                0,
                now,
                2,
            );
            assert!(roam_auth);
            let rs = guard.peer_roam.entry("macbook-air".into()).or_default();
            assert!(rs.replay_window.check_and_advance(77));
            assert!(!rs.replay_window.check_and_advance(77));

            // 3. Updating endpoint and re-signing preserves Ed25519 signature and ratchets epoch.
            let peer_idx = guard
                .manifest
                .peers
                .iter()
                .position(|p| p.name == "macbook-air")
                .unwrap();
            guard.manifest.peers[peer_idx].endpoint = Some("95.216.173.237:51888".into());
            guard.manifest.epoch = initial_epoch + 1;
            guard.manifest.issued_at = now;
            guard.manifest.expires_at = now + guard.manifest.max_ttl_secs;
            let sk = guard.signing_key().expect("valid coordinator signing key");
            guard.manifest.sign(&sk);
            assert!(guard.manifest.verify_ed25519());
            assert!(guard
                .manifest
                .verify_formal(initial_epoch, 0, now + 1)
                .is_ok());
        });
    }

    #[test]
    fn heartbeat_verifies_ed25519_before_updating_last_heartbeat_and_trips_deadman_on_forgery() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let ms = MeshStore::open(tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let mut guard = ms.inner.lock().await;
            let sk = guard.signing_key().expect("valid signing key");
            let t0 = guard.manifest.issued_at;
            guard.last_heartbeat_at = t0;

            // 1. Valid signed heartbeat at `t0 + 10` advances `last_heartbeat_at` and keeps Normal state.
            let sig1 = sign_heartbeat(&sk, "dgx-spark", 1, t0 + 10);
            let req1 = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 1,
                timestamp: t0 + 10,
                signature_hex: sig1.clone(),
                unbunker_grant_id: None,
            };
            let tr1 = process_heartbeat_step(
                &mut guard,
                &req1,
                OrbBunkerState::Normal,
                false,
                t0 + 10,
            )
            .expect("valid signed heartbeat must succeed");
            assert_eq!(tr1.next_state, MeshBunkerState::Normal);
            assert_eq!(guard.last_heartbeat_at, t0 + 10);

            // 2. Replaying the same heartbeat (`heartbeat_seq = 1`) is rejected by `ReplayWindow64`
            // and does NOT advance `last_heartbeat_at`.
            let replay_err = process_heartbeat_step(
                &mut guard,
                &req1,
                OrbBunkerState::Normal,
                false,
                t0 + 15,
            )
            .unwrap_err();
            assert_eq!(replay_err.0, StatusCode::UNAUTHORIZED);
            assert_eq!(guard.last_heartbeat_at, t0 + 10);

            // 3. Forged heartbeat after 200s (`> 180s` dead-man timeout) does NOT overwrite
            // `last_heartbeat_at` and trips `SovereignDeadManTripped` (State 3)!
            let forged_req = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 2,
                timestamp: t0 + 215,
                signature_hex: "00".repeat(64),
                unbunker_grant_id: None,
            };
            let forged_err = process_heartbeat_step(
                &mut guard,
                &forged_req,
                OrbBunkerState::Normal,
                false,
                t0 + 215,
            )
            .unwrap_err();
            assert_eq!(forged_err.0, StatusCode::UNAUTHORIZED);
            assert_eq!(guard.last_heartbeat_at, t0 + 10);
            assert_eq!(
                guard.bunker_state,
                MeshBunkerState::SovereignDeadManTripped
            );

            // 4. Even a valid heartbeat WITHOUT a verified server-side biometric unbunker grant
            // cannot exit `SovereignDeadManTripped` (sticky fence).
            let sig2 = sign_heartbeat(&sk, "dgx-spark", 2, t0 + 220);
            let req2 = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 2,
                timestamp: t0 + 220,
                signature_hex: sig2,
                unbunker_grant_id: None,
            };
            let tr2 = process_heartbeat_step(
                &mut guard,
                &req2,
                OrbBunkerState::Normal,
                false,
                t0 + 220,
            )
            .expect("valid heartbeat accepted");
            assert_eq!(tr2.next_state, MeshBunkerState::SovereignDeadManTripped);

            // 5. Valid heartbeat WITH verified server-side biometric `RootExec` grant unbunkers back to Normal.
            let sig3 = sign_heartbeat(&sk, "dgx-spark", 3, t0 + 225);
            let req3 = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 3,
                timestamp: t0 + 225,
                signature_hex: sig3,
                unbunker_grant_id: None,
            };
            let tr3 = process_heartbeat_step(
                &mut guard,
                &req3,
                OrbBunkerState::Normal,
                true,
                t0 + 225,
            )
            .expect("biometric unbunker with valid heartbeat must succeed");
            assert_eq!(tr3.next_state, MeshBunkerState::Normal);
            assert_eq!(guard.bunker_state, MeshBunkerState::Normal);
        });
    }

    #[test]
    fn corrupted_mesh_state_fails_closed_into_hard_lockdown_without_fallback_key() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let dir = tmp.path().join(".sandboxed-sh");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("lean_mesh_state.json"), "{ invalid json").unwrap();

        let ms = MeshStore::open(tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let guard = ms.inner.lock().await;
            assert!(guard.corrupted_state);
            assert_eq!(guard.bunker_state, MeshBunkerState::HardLockdown);
            assert!(guard.signing_key().is_err());
        });
    }
}
