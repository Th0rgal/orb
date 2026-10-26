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
    extract::{Path as AxumPath, Query, State},
    http::StatusCode,
    routing::{get, post},
    Extension, Json, Router,
};
use chrono::Utc;
use ed25519_dalek::SigningKey;
use lean_mesh::{
    check_endpoint_roam, select_relay_path, step_bunker_isolate, verify_frame_bounds,
    verify_heartbeat_signature, verify_jit_lease, verify_render_auth_signature,
    verify_roam_signature, BunkerState as MeshBunkerState, BunkerTransition, MeshManifest,
    MeshProto, NodeClass, RelayPathKind, ReplayWindow64, RouteDecision, LEAN_MESH_DEFAULT_WG_PORT,
    LEAN_MESH_FRAME_MAGIC, LEAN_MESH_INTERFACE_NAME, LEAN_MESH_PROTOCOL_VERSION,
    LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
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
    /// Constructs an explicit non-signing fail-closed lockdown state without ever
    /// instantiating a `SigningKey` or synthetic signed manifest.
    pub fn lockdown_store_without_signing_key(now_epoch: u64) -> Self {
        Self {
            coordinator_seed_hex: String::new(),
            pinned_coordinator_pubkey_hex: String::new(),
            manifest: MeshManifest {
                version: 0,
                epoch: 0,
                panic_seq: 0,
                is_emergency_panic: true,
                issued_at: 0,
                expires_at: 0,
                max_ttl_secs: 0,
                coordinator_pubkey_hex: String::new(),
                peers: Vec::new(),
                rules: Vec::new(),
                signature_hex: String::new(),
            },
            peer_roam: BTreeMap::new(),
            heartbeat_replay: BTreeMap::new(),
            last_heartbeat_at: now_epoch,
            is_sovereign_node: true,
            bunker_state: MeshBunkerState::HardLockdown,
            active_relay_sessions: 0,
            max_relay_sessions: 128,
            corrupted_state: true,
        }
    }

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

fn ensure_secure_state_dir(dir: &std::path::Path) -> Result<(), String> {
    if let Ok(meta) = std::fs::symlink_metadata(dir) {
        if meta.file_type().is_symlink() || !meta.is_dir() {
            return Err("state directory path is a symlink or non-directory".into());
        }
    } else {
        std::fs::create_dir_all(dir).map_err(|e| format!("failed to create state dir: {e}"))?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("failed to set 0700 permissions on state dir: {e}"))?;
    }
    Ok(())
}

fn verify_persisted_file_on_disk(
    path: &std::path::Path,
    expected_pubkey_hex: Option<&str>,
) -> Result<PersistedMeshState, String> {
    let meta =
        std::fs::symlink_metadata(path).map_err(|e| format!("failed to stat state file: {e}"))?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        return Err("state file is a symlink or non-regular file".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if (meta.permissions().mode() & 0o777) != 0o600 {
            return Err("state file permissions must be 0600".into());
        }
    }
    let raw = std::fs::read_to_string(path).map_err(|e| format!("failed to read state: {e}"))?;
    let loaded: PersistedMeshState =
        serde_json::from_str(&raw).map_err(|e| format!("failed to parse state JSON: {e}"))?;
    if loaded.signing_key().is_err() || !loaded.manifest.verify_ed25519() {
        return Err("loaded state failed signing_key() or verify_ed25519()".into());
    }
    if let Some(exp) = expected_pubkey_hex {
        if loaded.pinned_coordinator_pubkey_hex != exp {
            return Err("re-read state coordinator pubkey mismatch after write".into());
        }
    }
    Ok(loaded)
}

fn write_and_verify_initial_private_sync(
    path: &std::path::Path,
    state: &PersistedMeshState,
) -> Result<PersistedMeshState, String> {
    let json = serde_json::to_string_pretty(state).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    if let Ok(meta) = std::fs::symlink_metadata(&tmp) {
        if meta.file_type().is_symlink() {
            return Err("temporary state path is a symlink".into());
        }
    }
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(e) = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
    }
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.to_string());
    }
    verify_persisted_file_on_disk(path, Some(&state.pinned_coordinator_pubkey_hex))
}

fn write_and_verify_peer_keystore_sync(
    keystore_path: &std::path::Path,
    peer_seeds_hex: &BTreeMap<String, String>,
) -> Result<(), String> {
    let json = serde_json::to_string_pretty(peer_seeds_hex).map_err(|e| e.to_string())?;
    let tmp = keystore_path.with_extension("json.tmp");
    if let Ok(meta) = std::fs::symlink_metadata(&tmp) {
        if meta.file_type().is_symlink() {
            return Err("temporary peer keystore path is a symlink".into());
        }
    }
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(e) = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
    }
    if let Err(e) = std::fs::rename(&tmp, keystore_path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.to_string());
    }
    let meta = std::fs::symlink_metadata(keystore_path)
        .map_err(|e| format!("failed to stat peer keystore: {e}"))?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        return Err("peer keystore is a symlink or non-regular file".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if (meta.permissions().mode() & 0o777) != 0o600 {
            return Err("peer keystore permissions must be 0600".into());
        }
    }
    let raw = std::fs::read_to_string(keystore_path)
        .map_err(|e| format!("failed to re-read peer keystore: {e}"))?;
    let loaded: BTreeMap<String, String> =
        serde_json::from_str(&raw).map_err(|e| format!("failed to parse peer keystore: {e}"))?;
    if loaded != *peer_seeds_hex {
        return Err("re-read peer keystore mismatch after write".into());
    }
    Ok(())
}

impl MeshStore {
    pub fn open_with_rng<R: std::io::Read>(working_dir: PathBuf, rng: &mut R) -> Arc<Self> {
        let dir = working_dir.join(".sandboxed-sh");
        let path = dir.join("lean_mesh_state.json");
        let keystore_path = dir.join("lean_mesh_peer_keys.json");
        let now = unix_now();

        let state = match ensure_secure_state_dir(&dir) {
            Err(_) => PersistedMeshState::lockdown_store_without_signing_key(now),
            Ok(()) => match std::fs::symlink_metadata(&path) {
                Ok(_) => verify_persisted_file_on_disk(&path, None)
                    .unwrap_or_else(|_| PersistedMeshState::lockdown_store_without_signing_key(now)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    let mut coord_seed = [0u8; 32];
                    let coord_ok = rng.read_exact(&mut coord_seed).is_ok() && coord_seed != [0u8; 32];
                    if !coord_ok {
                        PersistedMeshState::lockdown_store_without_signing_key(now)
                    } else {
                        let sk = SigningKey::from_bytes(&coord_seed);
                        match MeshManifest::paloma_fleet_with_csprng_peers_from(now, &sk, rng) {
                            Ok((manifest, peer_seeds_hex)) => {
                                if write_and_verify_peer_keystore_sync(&keystore_path, &peer_seeds_hex)
                                    .is_err()
                                {
                                    PersistedMeshState::lockdown_store_without_signing_key(now)
                                } else {
                                    let pubkey_hex = manifest.coordinator_pubkey_hex.clone();
                                    let fresh = PersistedMeshState {
                                        coordinator_seed_hex: hex::encode(coord_seed),
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
                                    write_and_verify_initial_private_sync(&path, &fresh)
                                        .unwrap_or_else(|_| {
                                            PersistedMeshState::lockdown_store_without_signing_key(
                                                now,
                                            )
                                        })
                                }
                            }
                            Err(_) => PersistedMeshState::lockdown_store_without_signing_key(now),
                        }
                    }
                }
                Err(_) => PersistedMeshState::lockdown_store_without_signing_key(now),
            },
        };

        Arc::new(Self {
            path,
            inner: Mutex::new(state),
        })
    }

    pub fn open(working_dir: PathBuf) -> Arc<Self> {
        let now = unix_now();
        let Ok(mut urandom) = std::fs::File::open("/dev/urandom") else {
            let path = working_dir.join(".sandboxed-sh/lean_mesh_state.json");
            return Arc::new(Self {
                path,
                inner: Mutex::new(PersistedMeshState::lockdown_store_without_signing_key(now)),
            });
        };
        Self::open_with_rng(working_dir, &mut urandom)
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
/// 1. `effective_sovereign` combines the manifest-derived `peer.node_class == NodeClass::SovereignVault`
///    with the store-wide fail-safe `state.is_sovereign_node` flag, never trusting a client boolean.
/// 2. `canary_tripped` and `auth_failure_burst` are derived strictly from server-side `orb_bunker`.
/// 3. Ed25519 signature over `("lean-mesh-heartbeat-v1", peer_name, heartbeat_seq, timestamp)`
///    is verified against the peer's own manifest-pinned `peer.sign_pubkey_hex` (NOT the coordinator key!),
///    along with timestamp freshness and `ReplayWindow64` anti-replay, **before** updating
///    `last_heartbeat_at`.
/// 4. If heartbeat verification fails, `last_heartbeat_at` is NOT updated and `step_bunker_isolate`
///    is evaluated against the previously persisted `last_heartbeat_at` (`hb_fresh` derived from
///    `state.last_heartbeat_at` and `now_epoch`), so a forged, stale, or replayed heartbeat can
///    neither prematurely trip `SovereignDeadManTripped` when a recent legitimate heartbeat exists
///    nor delay/clear `SovereignDeadManTripped` once `now_epoch - state.last_heartbeat_at > 180s`.
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
    let peer_sign_pubkey_hex = peer.sign_pubkey_hex.clone();

    let canary_tripped = orb_bunker == OrbBunkerState::HardLockdown;
    let auth_failure_burst = orb_bunker == OrbBunkerState::SoftQuarantine;
    let base = state.bunker_state.max(map_orb_bunker_to_mesh(orb_bunker));

    let sig_ok = peer_active
        && verify_heartbeat_signature(
            &peer_sign_pubkey_hex,
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
        // Leave `state.last_heartbeat_at` untouched and evaluate `step_bunker_isolate`
        // purely from the persisted `state.last_heartbeat_at` freshness (`hb_fresh`),
        // with `biometric_unbunker = false`.
        let hb_fresh = state.last_heartbeat_at <= now_epoch
            && now_epoch.saturating_sub(state.last_heartbeat_at) <= LEAN_MESH_SOVEREIGN_DEADMAN_SECS;
        let transition = step_bunker_isolate(
            base,
            effective_sovereign,
            canary_tripped,
            auth_failure_burst,
            0,
            false,
            hb_fresh,
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
    pub timestamp: u64,
    pub signature_hex: String,
    #[serde(default)]
    pub allow_private_roam: bool,
}

#[derive(Debug, Default, Deserialize)]
pub struct RenderNodeAuthQuery {
    pub seq: Option<u64>,
    pub timestamp: Option<u64>,
    pub signature_hex: Option<String>,
    pub grant_id: Option<Uuid>,
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
) -> Result<Json<MeshManifest>, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let guard = store.inner.lock().await;
    if guard.corrupted_state {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "mesh store is in fail-closed corrupted state" })),
        ));
    }
    Ok(Json(guard.manifest.clone()))
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
    if guard.corrupted_state {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "mesh store is in fail-closed corrupted state" })),
        ));
    }
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
    // Rejects wildcard `target_host == "all"` grants and requires an explicit `decided_at` approval timestamp.
    let (jit_admitted, jit_expires_at) = if let Some(grant_id) = req.jit_grant_id {
        if let Some(grant) = super::privilege_broker::store(&app_state)
            .get(&user.id, grant_id)
            .await
        {
            let bio_ok = grant.state == ApprovalState::Approved
                && grant.decided_at.is_some()
                && grant.target_host == req.dst_peer;
            let same_owner = grant.owner == user.id;
            let revoked = grant.revoked_at.is_some() || grant.state == ApprovalState::Revoked;
            let issued_at = grant
                .decided_at
                .map(|t| t.timestamp().max(0) as u64)
                .unwrap_or(0);
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

/// Pure server-side endpoint roam verification, anti-replay, and manifest re-signing step.
///
/// Computes `aead_auth_ok` server-side from `verify_roam_signature` (Ed25519 signature +
/// `leanmesh_frame_bounds_step` + timestamp freshness), evaluates `leanmesh_endpoint_roam_step`
/// BEFORE mutating the RFC 6479 64-packet `ReplayWindow64`, and ratchets + re-signs the manifest.
pub fn process_endpoint_roam_step(
    state: &mut PersistedMeshState,
    req: &EndpointRoamRequest,
    effective_bunker: MeshBunkerState,
    now_epoch: u64,
) -> Result<String, (StatusCode, String)> {
    if state.corrupted_state {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "mesh store is in fail-closed corrupted state".into(),
        ));
    }

    let ip: Ipv4Addr = req.candidate_ip.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            "invalid candidate IPv4 address".into(),
        )
    })?;

    let sk = state
        .signing_key()
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    let peer_idx = state
        .manifest
        .peers
        .iter()
        .position(|p| p.name == req.peer_name)
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("unknown peer `{}`", req.peer_name),
            )
        })?;
    let peer = &state.manifest.peers[peer_idx];
    let peer_active = !peer.revoked && now_epoch < peer.expires_at;
    let pinned_static = peer.pinned_static;
    let peer_sign_pubkey_hex = peer.sign_pubkey_hex.clone();

    let ts_fresh = req.timestamp <= now_epoch.saturating_add(30)
        && now_epoch.saturating_sub(req.timestamp) <= 120;
    let aead_auth_ok = peer_active
        && ts_fresh
        && verify_roam_signature(
            &peer_sign_pubkey_hex,
            &req.peer_name,
            ip,
            req.candidate_port,
            req.pkt_seq,
            req.timestamp,
            &req.signature_hex,
        );

    let roam_state = state
        .peer_roam
        .entry(req.peer_name.clone())
        .or_default();

    // 1. Verify server-derived `aead_auth_ok`, static pinning, bogon/overlay IP classification,
    //    bunker state, and roam rate-limit BEFORE mutating the anti-replay window!
    let roam_ok = check_endpoint_roam(
        aead_auth_ok,
        pinned_static,
        ip,
        req.allow_private_roam,
        effective_bunker,
        req.candidate_port,
        roam_state.last_roam_seq,
        req.pkt_seq,
        roam_state.last_roam_epoch,
        now_epoch,
        2,
    );

    if !roam_ok {
        return Err((
            StatusCode::FORBIDDEN,
            "rejected_by_leanmesh_endpoint_roam_step".into(),
        ));
    }

    // 2. Advance RFC 6479 64-packet anti-replay window only after `leanmesh_endpoint_roam_step` succeeds.
    if !roam_state.replay_window.check_and_advance(req.pkt_seq) {
        return Err((
            StatusCode::CONFLICT,
            "rejected_by_leanmesh_replay_window_step".into(),
        ));
    }

    roam_state.last_roam_seq = req.pkt_seq;
    roam_state.last_roam_epoch = now_epoch;
    let new_ep = format!("{}:{}", ip, req.candidate_port);
    state.manifest.peers[peer_idx].endpoint = Some(new_ep.clone());
    state.manifest.epoch = state.manifest.epoch.saturating_add(1);
    state.manifest.issued_at = now_epoch;
    state.manifest.expires_at = now_epoch.saturating_add(state.manifest.max_ttl_secs);
    state.manifest.sign(&sk);
    Ok(new_ep)
}

async fn post_endpoint_roam(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(req): Json<EndpointRoamRequest>,
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

    let bunker = effective_mesh_bunker(&app_state, &guard, now).await;
    if bunker.next_state > guard.bunker_state {
        guard.bunker_state = bunker.next_state;
        let _ = store.save(&guard).await;
    }

    let new_ep = process_endpoint_roam_step(&mut guard, &req, bunker.next_state, now).map_err(
        |(status, reason)| {
            (
                status,
                Json(json!({
                    "admitted": false,
                    "reason": reason,
                })),
            )
        },
    )?;

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

async fn authorize_node_render(
    app_state: &AppState,
    user: &AuthUser,
    mesh_state: &PersistedMeshState,
    node: &str,
    auth: &RenderNodeAuthQuery,
    now_epoch: u64,
) -> Result<(), (StatusCode, Json<Value>)> {
    if mesh_state.corrupted_state {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "mesh store is in fail-closed corrupted state" })),
        ));
    }
    if let (Some(seq), Some(ts), Some(sig)) = (auth.seq, auth.timestamp, auth.signature_hex.as_deref()) {
        if let Ok(peer) = mesh_state.manifest.find_peer(node) {
            let peer_active = !peer.revoked && now_epoch < peer.expires_at;
            let ts_fresh = ts <= now_epoch.saturating_add(30) && now_epoch.saturating_sub(ts) <= 120;
            if peer_active
                && ts_fresh
                && verify_render_auth_signature(&peer.sign_pubkey_hex, node, seq, ts, sig)
            {
                return Ok(());
            }
        }
    }
    if let Some(grant_id) = auth.grant_id {
        let orb_bunker = super::privilege_broker::store(app_state).bunker_state().await;
        if let Some(grant) = super::privilege_broker::store(app_state)
            .get(&user.id, grant_id)
            .await
        {
            if grant.state == ApprovalState::Approved
                && grant.owner == user.id
                && grant.target_host == node
                && grant.live_grant(Utc::now(), orb_bunker)
            {
                return Ok(());
            }
        }
    }
    Err((
        StatusCode::FORBIDDEN,
        Json(json!({
            "error": "node configuration rendering requires a valid Ed25519 node signature or active PrivilegeBroker grant for the target node",
        })),
    ))
}

async fn render_wg_handler(
    State(app_state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    AxumPath(node): AxumPath<String>,
    Query(auth): Query<RenderNodeAuthQuery>,
) -> Result<String, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let now = unix_now();
    let guard = store.inner.lock().await;
    authorize_node_render(&app_state, &user, &guard, &node, &auth, now).await?;
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
    Extension(user): Extension<AuthUser>,
    AxumPath(node): AxumPath<String>,
    Query(auth): Query<RenderNodeAuthQuery>,
) -> Result<String, (StatusCode, Json<Value>)> {
    let store = store(&app_state);
    let now = unix_now();
    let guard = store.inner.lock().await;
    authorize_node_render(&app_state, &user, &guard, &node, &auth, now).await?;
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
            && grant.decided_at.is_some()
            && grant.owner == user.id
            && grant.scope == super::privilege_broker::PrivilegeScope::RootExec
            && grant.revoked_at.is_none()
            && grant.target_host == req.peer_name
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
    use lean_mesh::{is_name_derived_peer_signing_pubkey, sign_heartbeat, sign_render_auth};
    use sha2::{Digest, Sha256};

    fn enroll_test_peer_key(state: &mut PersistedMeshState, peer_name: &str, seed_byte: u8) -> SigningKey {
        let coord_sk = state.signing_key().expect("valid coordinator signing key");
        let peer_sk = SigningKey::from_bytes(&[seed_byte; 32]);
        let pub_hex = hex::encode(peer_sk.verifying_key().to_bytes());
        let peer = state
            .manifest
            .peers
            .iter_mut()
            .find(|p| p.name == peer_name)
            .expect("peer must exist");
        peer.sign_pubkey_hex = pub_hex;
        state.manifest.sign(&coord_sk);
        peer_sk
    }

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
            for peer in &guard.manifest.peers {
                assert!(
                    !is_name_derived_peer_signing_pubkey(&peer.name, &peer.sign_pubkey_hex),
                    "peer `{}` signing key must be CSPRNG-provisioned, never derived from peer name",
                    peer.name
                );
            }

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
        use lean_mesh::sign_roam;
        let tmp = tempfile::tempdir().expect("tempdir");
        let ms = MeshStore::open(tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let mut guard = ms.inner.lock().await;
            let coord_sk = guard.signing_key().expect("valid coordinator signing key");
            let peer_sk = enroll_test_peer_key(&mut guard, "macbook-air", 0x61);
            let now = guard.manifest.issued_at + 10;
            let initial_epoch = guard.manifest.epoch;

            // 0. Roam frame signed by a deterministic name-derived key is rejected before touching `replay_window`.
            let mut det_h = Sha256::new();
            det_h.update(b"lean-mesh-peer-ed25519-v1:macbook-air");
            let det_seed: [u8; 32] = det_h.finalize().into();
            let det_sk = SigningKey::from_bytes(&det_seed);
            let det_roam_sig = sign_roam(
                &det_sk,
                "macbook-air",
                Ipv4Addr::new(95, 216, 173, 237),
                51888,
                77,
                now,
            );
            let det_roam = EndpointRoamRequest {
                peer_name: "macbook-air".into(),
                candidate_ip: "95.216.173.237".into(),
                candidate_port: 51888,
                pkt_seq: 77,
                timestamp: now,
                signature_hex: det_roam_sig,
                allow_private_roam: false,
            };
            assert_eq!(
                process_endpoint_roam_step(&mut guard, &det_roam, MeshBunkerState::Normal, now)
                    .unwrap_err()
                    .0,
                StatusCode::FORBIDDEN
            );

            // 1. Roam frame signed by the COORDINATOR key (or forged) for `macbook-air` with `pkt_seq = 77`
            // is rejected by `process_endpoint_roam_step` BEFORE touching `replay_window`.
            let coord_roam_sig = sign_roam(
                &coord_sk,
                "macbook-air",
                Ipv4Addr::new(95, 216, 173, 237),
                51888,
                77,
                now,
            );
            let forged_roam = EndpointRoamRequest {
                peer_name: "macbook-air".into(),
                candidate_ip: "95.216.173.237".into(),
                candidate_port: 51888,
                pkt_seq: 77,
                timestamp: now,
                signature_hex: coord_roam_sig,
                allow_private_roam: false,
            };
            let err_unauth = process_endpoint_roam_step(
                &mut guard,
                &forged_roam,
                MeshBunkerState::Normal,
                now,
            )
            .unwrap_err();
            assert_eq!(err_unauth.0, StatusCode::FORBIDDEN);

            // 2. Legitimate Ed25519 roam frame signed by `macbook-air`'s own node signing key
            // with the same `pkt_seq = 77` succeeds, advances the replay window, and re-signs + ratchets the manifest epoch.
            let valid_sig = sign_roam(
                &peer_sk,
                "macbook-air",
                Ipv4Addr::new(95, 216, 173, 237),
                51888,
                77,
                now,
            );
            let valid_roam = EndpointRoamRequest {
                peer_name: "macbook-air".into(),
                candidate_ip: "95.216.173.237".into(),
                candidate_port: 51888,
                pkt_seq: 77,
                timestamp: now,
                signature_hex: valid_sig,
                allow_private_roam: false,
            };
            let new_ep = process_endpoint_roam_step(
                &mut guard,
                &valid_roam,
                MeshBunkerState::Normal,
                now,
            )
            .expect("signed roam frame must succeed");
            assert_eq!(new_ep, "95.216.173.237:51888");
            assert_eq!(guard.manifest.epoch, initial_epoch + 1);
            assert!(guard.manifest.verify_ed25519());
            assert!(guard
                .manifest
                .verify_formal(initial_epoch, 0, now + 1)
                .is_ok());

            // 3. Replaying the same signed roam frame (`pkt_seq = 77`) is rejected by `ReplayWindow64`.
            let replay_sig = sign_roam(
                &peer_sk,
                "macbook-air",
                Ipv4Addr::new(95, 216, 173, 238),
                51888,
                77,
                now + 5,
            );
            let replay_roam = EndpointRoamRequest {
                peer_name: "macbook-air".into(),
                candidate_ip: "95.216.173.238".into(),
                candidate_port: 51888,
                pkt_seq: 77,
                timestamp: now + 5,
                signature_hex: replay_sig,
                allow_private_roam: false,
            };
            let err_replay = process_endpoint_roam_step(
                &mut guard,
                &replay_roam,
                MeshBunkerState::Normal,
                now + 5,
            )
            .unwrap_err();
            assert_eq!(err_replay.0, StatusCode::FORBIDDEN);
        });
    }

    #[test]
    fn heartbeat_verifies_ed25519_before_updating_last_heartbeat_and_trips_deadman_on_forgery() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let ms = MeshStore::open(tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let mut guard = ms.inner.lock().await;
            let coord_sk = guard.signing_key().expect("valid coordinator signing key");
            let spark_sk = enroll_test_peer_key(&mut guard, "dgx-spark", 0x71);
            let ashur_sk = enroll_test_peer_key(&mut guard, "ashur", 0x72);
            let t0 = guard.manifest.issued_at;
            guard.last_heartbeat_at = t0;

            // 0a. Heartbeat signed by a deterministic name-derived key is rejected (`401`).
            let mut det_h = Sha256::new();
            det_h.update(b"lean-mesh-peer-ed25519-v1:dgx-spark");
            let det_seed: [u8; 32] = det_h.finalize().into();
            let det_sk = SigningKey::from_bytes(&det_seed);
            let det_hb_sig = sign_heartbeat(&det_sk, "dgx-spark", 1, t0 + 10);
            let det_hb_req = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 1,
                timestamp: t0 + 10,
                signature_hex: det_hb_sig,
                unbunker_grant_id: None,
            };
            assert_eq!(
                process_heartbeat_step(
                    &mut guard,
                    &det_hb_req,
                    OrbBunkerState::Normal,
                    false,
                    t0 + 10,
                )
                .unwrap_err()
                .0,
                StatusCode::UNAUTHORIZED
            );
            assert_eq!(guard.bunker_state, MeshBunkerState::Normal);

            // 0b. A heartbeat signed by the COORDINATOR key (or by another node's key) is REJECTED,
            // does NOT advance `last_heartbeat_at` or consume `heartbeat_seq = 1`, and does NOT
            // prematurely trip `SovereignDeadManTripped` while `last_heartbeat_at` is still fresh!
            let coord_sig = sign_heartbeat(&coord_sk, "dgx-spark", 1, t0 + 10);
            let coord_hb_req = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 1,
                timestamp: t0 + 10,
                signature_hex: coord_sig,
                unbunker_grant_id: None,
            };
            let coord_err = process_heartbeat_step(
                &mut guard,
                &coord_hb_req,
                OrbBunkerState::Normal,
                false,
                t0 + 10,
            )
            .unwrap_err();
            assert_eq!(coord_err.0, StatusCode::UNAUTHORIZED);
            assert_eq!(guard.last_heartbeat_at, t0);
            assert_eq!(guard.bunker_state, MeshBunkerState::Normal);

            let cross_node_sig = sign_heartbeat(&ashur_sk, "dgx-spark", 1, t0 + 10);
            let cross_node_req = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 1,
                timestamp: t0 + 10,
                signature_hex: cross_node_sig,
                unbunker_grant_id: None,
            };
            let cross_err = process_heartbeat_step(
                &mut guard,
                &cross_node_req,
                OrbBunkerState::Normal,
                false,
                t0 + 10,
            )
            .unwrap_err();
            assert_eq!(cross_err.0, StatusCode::UNAUTHORIZED);
            assert_eq!(guard.last_heartbeat_at, t0);
            assert_eq!(guard.bunker_state, MeshBunkerState::Normal);

            // Also verify domain separation: a render-auth token signed by `dgx-spark` is rejected as a heartbeat!
            let render_tok = sign_render_auth(&spark_sk, "dgx-spark", 1, t0 + 10);
            let render_as_hb = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 1,
                timestamp: t0 + 10,
                signature_hex: render_tok,
                unbunker_grant_id: None,
            };
            assert!(process_heartbeat_step(
                &mut guard,
                &render_as_hb,
                OrbBunkerState::Normal,
                false,
                t0 + 10,
            )
            .is_err());
            assert_eq!(guard.bunker_state, MeshBunkerState::Normal);

            // 1. Valid heartbeat signed by `dgx-spark`'s own pinned Ed25519 key at `t0 + 10`
            // advances `last_heartbeat_at` and keeps Normal state.
            let sig1 = sign_heartbeat(&spark_sk, "dgx-spark", 1, t0 + 10);
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
            .expect("valid node-signed heartbeat must succeed");
            assert_eq!(tr1.next_state, MeshBunkerState::Normal);
            assert_eq!(guard.last_heartbeat_at, t0 + 10);

            // 2. Replaying the same heartbeat (`heartbeat_seq = 1`) is rejected by `ReplayWindow64`
            // and does NOT advance `last_heartbeat_at` or trip dead-man while `t0 + 10` is fresh.
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
            assert_eq!(guard.bunker_state, MeshBunkerState::Normal);

            // 3. Heartbeat signed by the coordinator key after 200s (`> 180s` dead-man timeout)
            // is rejected, does NOT overwrite `last_heartbeat_at`, and trips `SovereignDeadManTripped` (State 3)!
            let coord_late_sig = sign_heartbeat(&coord_sk, "dgx-spark", 2, t0 + 215);
            let forged_req = HeartbeatRequest {
                peer_name: "dgx-spark".into(),
                heartbeat_seq: 2,
                timestamp: t0 + 215,
                signature_hex: coord_late_sig,
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

            // 4. Even a valid node-signed heartbeat WITHOUT a verified server-side biometric unbunker grant
            // cannot exit `SovereignDeadManTripped` (sticky fence).
            let sig2 = sign_heartbeat(&spark_sk, "dgx-spark", 2, t0 + 220);
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

            // 5. Valid node-signed heartbeat WITH verified server-side biometric `RootExec` grant unbunkers back to Normal.
            let sig3 = sign_heartbeat(&spark_sk, "dgx-spark", 3, t0 + 225);
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
            assert!(guard.pinned_coordinator_pubkey_hex.is_empty());
            assert!(guard.manifest.peers.is_empty());
            assert!(!guard.manifest.verify_ed25519());
        });
    }

    #[test]
    fn source_code_contains_no_deterministic_signing_key_fallbacks() {
        let mesh_src = include_str!("mesh.rs");
        let prod_part = mesh_src
            .split("#[cfg(test)]")
            .next()
            .expect("production section of mesh.rs");
        for forbidden in ["0x42", "0x99", "unwrap_or([", "derive_default_seed"] {
            assert!(
                !prod_part.contains(forbidden),
                "production mesh.rs must not contain forbidden fallback pattern `{forbidden}`"
            );
        }
    }

    #[test]
    fn first_init_persistence_failure_enters_non_signing_lockdown_and_valid_init_persists_0600() {
        // 1. Place a regular file at `.sandboxed-sh` so directory creation / persistence fails on first init.
        let blocked_tmp = tempfile::tempdir().expect("tempdir");
        std::fs::write(blocked_tmp.path().join(".sandboxed-sh"), b"blocker file").unwrap();
        let blocked_store = MeshStore::open(blocked_tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let guard = blocked_store.inner.lock().await;
            assert!(guard.corrupted_state);
            assert_eq!(guard.bunker_state, MeshBunkerState::HardLockdown);
            assert!(guard.signing_key().is_err());
            assert!(guard.pinned_coordinator_pubkey_hex.is_empty());
        });

        // 1b. Per-peer CSPRNG failure injection: coordinator seed (32 bytes) succeeds, but per-peer
        // CSPRNG runs out of bytes mid-fleet -> `open_with_rng` enters non-signing `HardLockdown` without panicking!
        let partial_rng_tmp = tempfile::tempdir().expect("tempdir");
        let mut partial_rng = std::io::Cursor::new(vec![0x5Au8; 48]); // 32-byte coord seed + only 16 bytes for first peer
        let partial_store =
            MeshStore::open_with_rng(partial_rng_tmp.path().to_path_buf(), &mut partial_rng);
        rt.block_on(async {
            let guard = partial_store.inner.lock().await;
            assert!(guard.corrupted_state);
            assert_eq!(guard.bunker_state, MeshBunkerState::HardLockdown);
            assert!(guard.signing_key().is_err());
            assert!(guard.pinned_coordinator_pubkey_hex.is_empty());
        });

        // 2. Two independent initializations generate distinct CSPRNG coordinator identities,
        // persist both `lean_mesh_state.json` and `lean_mesh_peer_keys.json` with `0o600` permissions,
        // and preserve the exact coordinator identity across restarts.
        let tmp1 = tempfile::tempdir().expect("tempdir 1");
        let tmp2 = tempfile::tempdir().expect("tempdir 2");
        let ms1 = MeshStore::open(tmp1.path().to_path_buf());
        let ms2 = MeshStore::open(tmp2.path().to_path_buf());
        let ms1_reopened = MeshStore::open(tmp1.path().to_path_buf());
        rt.block_on(async {
            let g1 = ms1.inner.lock().await;
            let g2 = ms2.inner.lock().await;
            let g1_re = ms1_reopened.inner.lock().await;
            assert!(!g1.corrupted_state);
            assert!(!g2.corrupted_state);
            assert_ne!(
                g1.pinned_coordinator_pubkey_hex,
                g2.pinned_coordinator_pubkey_hex
            );
            assert_eq!(
                g1.pinned_coordinator_pubkey_hex,
                g1_re.pinned_coordinator_pubkey_hex
            );
            let keystore_raw = std::fs::read_to_string(
                tmp1.path().join(".sandboxed-sh/lean_mesh_peer_keys.json"),
            )
            .expect("peer keystore must be persisted");
            let peer_keys: BTreeMap<String, String> =
                serde_json::from_str(&keystore_raw).expect("valid peer keystore JSON");
            assert_eq!(peer_keys.len(), g1.manifest.peers.len());
            for peer in &g1.manifest.peers {
                let seed_hex = peer_keys.get(&peer.name).expect("peer seed present");
                let seed_bytes: [u8; 32] = hex::decode(seed_hex).unwrap().try_into().unwrap();
                let derived_pub =
                    hex::encode(SigningKey::from_bytes(&seed_bytes).verifying_key().to_bytes());
                assert_eq!(derived_pub, peer.sign_pubkey_hex);
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let meta = std::fs::symlink_metadata(
                    tmp1.path().join(".sandboxed-sh/lean_mesh_state.json"),
                )
                .unwrap();
                assert_eq!(meta.permissions().mode() & 0o777, 0o600);
                let ks_meta = std::fs::symlink_metadata(
                    tmp1.path().join(".sandboxed-sh/lean_mesh_peer_keys.json"),
                )
                .unwrap();
                assert_eq!(ks_meta.permissions().mode() & 0o777, 0o600);
            }
        });
    }
}
