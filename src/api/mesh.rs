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
//!   Sovereign Dead-Man's Switch (`leanmesh_bunker_isolate_step`), and renders
//!   deterministic WireGuard (`wg-leanmesh0.conf`) and `nftables` (`table inet lean_mesh`)
//!   configurations.

use std::collections::BTreeMap;
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
    verify_jit_lease, BunkerState as MeshBunkerState, BunkerTransition, MeshManifest, MeshProto,
    RelayPathKind, ReplayWindow64, RouteDecision, LEAN_MESH_DEFAULT_WG_PORT,
    LEAN_MESH_FRAME_MAGIC, LEAN_MESH_INTERFACE_NAME, LEAN_MESH_PROTOCOL_VERSION,
    LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
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
    pub manifest: MeshManifest,
    pub peer_roam: BTreeMap<String, PeerRoamState>,
    pub last_heartbeat_at: u64,
    pub is_sovereign_node: bool,
    #[serde(default = "default_bunker_normal")]
    pub bunker_state: MeshBunkerState,
    pub active_relay_sessions: u32,
    pub max_relay_sessions: u32,
}

impl PersistedMeshState {
    fn signing_key(&self) -> SigningKey {
        let bytes = hex::decode(&self.coordinator_seed_hex)
            .ok()
            .and_then(|v| <[u8; 32]>::try_from(v).ok())
            .unwrap_or([0x42; 32]);
        SigningKey::from_bytes(&bytes)
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

fn derive_default_seed(working_dir: &std::path::Path) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"orb-lean-mesh-coordinator-seed-v1:");
    h.update(working_dir.to_string_lossy().as_bytes());
    h.finalize().into()
}

impl MeshStore {
    pub fn open(working_dir: PathBuf) -> Arc<Self> {
        let dir = working_dir.join(".sandboxed-sh");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("lean_mesh_state.json");
        let now = unix_now();

        let state = std::fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<PersistedMeshState>(&raw).ok())
            .unwrap_or_else(|| {
                let seed = derive_default_seed(&working_dir);
                let sk = SigningKey::from_bytes(&seed);
                let manifest = MeshManifest::paloma_fleet_default(now, &sk);
                PersistedMeshState {
                    coordinator_seed_hex: hex::encode(seed),
                    manifest,
                    peer_roam: BTreeMap::new(),
                    last_heartbeat_at: now,
                    is_sovereign_node: false,
                    bunker_state: MeshBunkerState::Normal,
                    active_relay_sessions: 0,
                    max_relay_sessions: 128,
                }
            });

        Arc::new(Self {
            path,
            inner: Mutex::new(state),
        })
    }

    async fn save(&self, state: &PersistedMeshState) {
        if let Ok(json) = serde_json::to_string_pretty(state) {
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
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
    step_bunker_isolate(
        base,
        mesh_state.is_sovereign_node,
        orb_bunker == OrbBunkerState::HardLockdown,
        orb_bunker == OrbBunkerState::SoftQuarantine,
        0,
        false,
        true,
        now_epoch,
        mesh_state.last_heartbeat_at,
        LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
    )
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
    #[serde(default)]
    pub is_sovereign_node: Option<bool>,
    #[serde(default)]
    pub canary_tripped: bool,
    #[serde(default)]
    pub auth_failure_burst: bool,
    #[serde(default)]
    pub biometric_unbunker: bool,
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
        "coordinator_pubkey_hex": guard.manifest.coordinator_pubkey_hex,
        "peers_count": guard.manifest.peers.len(),
        "rules_count": guard.manifest.rules.len(),
        "bunker": bunker,
        "persisted_bunker_state": guard.bunker_state,
        "last_heartbeat_at": guard.last_heartbeat_at,
        "sovereign_deadman_timeout_secs": LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
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

    if candidate.coordinator_pubkey_hex != guard.manifest.coordinator_pubkey_hex {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({
                "error": "coordinator_pubkey_hex mismatch against pinned mesh coordinator key",
                "expected_coordinator_pubkey_hex": guard.manifest.coordinator_pubkey_hex,
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
    store.save(&guard).await;

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
        store.save(&guard).await;
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
    let sk = guard.signing_key();
    guard.manifest.sign(&sk);
    store.save(&guard).await;

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
                StatusCode::NOT_FOUND,
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
                StatusCode::NOT_FOUND,
                Json(json!({ "error": e.to_string() })),
            )
        })
}

async fn post_heartbeat(
    State(app_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(req): Json<HeartbeatRequest>,
) -> Json<Value> {
    let store = store(&app_state);
    let now = unix_now();
    let mut guard = store.inner.lock().await;
    if let Some(sov) = req.is_sovereign_node {
        guard.is_sovereign_node = sov;
    }
    guard.last_heartbeat_at = now;
    let orb_bunker = super::privilege_broker::store(&app_state).bunker_state().await;
    let base = guard.bunker_state.max(map_orb_bunker_to_mesh(orb_bunker));
    let transition = step_bunker_isolate(
        base,
        guard.is_sovereign_node,
        req.canary_tripped || orb_bunker == OrbBunkerState::HardLockdown,
        req.auth_failure_burst || orb_bunker == OrbBunkerState::SoftQuarantine,
        0,
        req.biometric_unbunker,
        true,
        now,
        guard.last_heartbeat_at,
        LEAN_MESH_SOVEREIGN_DEADMAN_SECS,
    );
    guard.bunker_state = transition.next_state;
    store.save(&guard).await;
    Json(json!({
        "last_heartbeat_at": guard.last_heartbeat_at,
        "bunker": transition,
    }))
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

    #[test]
    fn mesh_store_initializes_and_enforces_sovereign_isolation() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let ms = MeshStore::open(tmp.path().to_path_buf());
        let rt = tokio::runtime::Runtime::new().expect("rt");
        rt.block_on(async {
            let guard = ms.inner.lock().await;
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
            let sk = guard.signing_key();
            guard.manifest.sign(&sk);
            assert!(guard.manifest.verify_ed25519());
            assert!(guard
                .manifest
                .verify_formal(initial_epoch, 0, now + 1)
                .is_ok());
        });
    }
}
