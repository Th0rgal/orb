#![allow(clippy::too_many_arguments)]
//! `lean-mesh`: Formally verified WireGuard mesh control plane, capability ACL engine,
//! RFC 6479 anti-replay window, authenticated endpoint roamer, NAT relay selector,
//! 4-state Bunker & Sovereign Dead-Man's Switch fence, and atomic WireGuard/`nftables`
//! reconciliation library for Orb.
//!
//! Backed by `lean/LeanMesh/Kernel.lean` and `lean/LeanMesh/Spec.lean` (`0 import Lean`,
//! `0 sorryAx`), compiled to standalone unboxed C99 (`cabi/lean_mesh_kernel_unboxed.c`).

use std::collections::BTreeMap;
use std::fmt;
use std::net::Ipv4Addr;

use base64::Engine as _;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

pub const LEAN_MESH_FRAME_MAGIC: u32 = 0x4C4D_5348; // "LMSH"
pub const LEAN_MESH_PROTOCOL_VERSION: u8 = 1;
pub const LEAN_MESH_OVERLAY_NET_U32: u32 = 0x0A58_0000; // 10.88.0.0/16
pub const LEAN_MESH_INTERFACE_NAME: &str = "wg-leanmesh0";
pub const LEAN_MESH_DEFAULT_WG_PORT: u16 = 51888;
pub const LEAN_MESH_SOVEREIGN_DEADMAN_SECS: u64 = 180;

pub mod cabi {
    //! Raw FFI bindings to the 12 formally verified C-ABI functions in `LeanMesh.Kernel`.
    extern "C" {
        pub fn leanmesh_ratchet_epoch_step(
            sig_valid: u8,
            is_emergency_panic: u8,
            current_epoch: u64,
            candidate_epoch: u64,
            current_panic_seq: u64,
            candidate_panic_seq: u64,
            now_epoch: u64,
            issued_at: u64,
            expires_at: u64,
            max_ttl_secs: u64,
        ) -> u32;

        pub fn leanmesh_eval_route_step(
            src_id: u32,
            dst_id: u32,
            src_class: u8,
            dst_class: u8,
            src_revoked: u8,
            dst_revoked: u8,
            rule_matched: u8,
            proto: u8,
            dst_port: u32,
            rule_port_min: u32,
            rule_port_max: u32,
            jit_biometric_grant: u8,
            bunker_state: u8,
            now_epoch: u64,
            src_expires_at: u64,
            dst_expires_at: u64,
            jit_expires_at: u64,
        ) -> u32;

        pub fn leanmesh_replay_window_step(last_max_seq: u64, bitmap: u64, pkt_seq: u64) -> u8;

        pub fn leanmesh_replay_window_next_max(
            last_max_seq: u64,
            bitmap: u64,
            pkt_seq: u64,
        ) -> u64;

        pub fn leanmesh_replay_window_next_bitmap(
            last_max_seq: u64,
            bitmap: u64,
            pkt_seq: u64,
        ) -> u64;

        pub fn leanmesh_endpoint_roam_step(
            aead_auth_ok: u8,
            peer_pinned_static: u8,
            candidate_ip_class: u8,
            allow_private_roam: u8,
            bunker_state: u8,
            candidate_port: u32,
            last_roam_seq: u64,
            pkt_seq: u64,
            last_roam_epoch: u64,
            now_epoch: u64,
            min_roam_interval_secs: u64,
        ) -> u8;

        pub fn leanmesh_relay_select_step(
            route_allowed: u8,
            lan_reachable: u8,
            wan_reachable: u8,
            relay_healthy: u8,
            src_id: u32,
            dst_id: u32,
            relay_id: u32,
            active_relay_sessions: u32,
            max_relay_sessions: u32,
            now_epoch: u64,
            direct_handshake_at: u64,
            max_direct_stale_secs: u64,
        ) -> u8;

        pub fn leanmesh_bunker_isolate_step(
            current_state: u8,
            is_sovereign_node: u8,
            canary_tripped: u8,
            auth_failure_burst: u8,
            manual_trigger: u8,
            biometric_unbunker: u8,
            heartbeat_valid: u8,
            now_epoch: u64,
            last_heartbeat_at: u64,
            dead_man_timeout_secs: u64,
        ) -> u32;

        pub fn leanmesh_frame_bounds_step(
            magic: u32,
            version: u8,
            frame_kind: u8,
            tag_verified: u8,
            header_len: u64,
            payload_len: u64,
            max_frame_bytes: u64,
            buf_cap: u64,
        ) -> u8;

        pub fn leanmesh_overlay_ip_step(
            peer_id_a: u32,
            peer_id_b: u32,
            ip_a: u32,
            ip_b: u32,
            prefix_len_a: u8,
            prefix_len_b: u8,
        ) -> u8;

        pub fn leanmesh_reconcile_wg_step(
            manifest_valid: u8,
            peer_present_in_kernel: u8,
            peer_revoked: u8,
            pubkey_matches: u8,
            allowed_ip_matches: u8,
            endpoint_changed: u8,
            bunker_prune_non_admin: u8,
            peer_is_admin: u8,
            now_epoch: u64,
            peer_expires_at: u64,
        ) -> u8;

        pub fn leanmesh_jit_lease_step(
            biometric_sig_valid: u8,
            operator_same_owner: u8,
            mission_active: u8,
            grant_revoked: u8,
            bunker_state: u8,
            src_class: u8,
            dst_class: u8,
            now_epoch: u64,
            grant_issued_at: u64,
            grant_expires_at: u64,
            max_jit_ttl_secs: u64,
        ) -> u32;
    }
}

#[derive(Debug, Error)]
pub enum MeshError {
    #[error("unsupported manifest protocol version `{0}` (expected 1)")]
    UnsupportedManifestVersion(u8),
    #[error("manifest peer list cannot be empty")]
    EmptyPeerList,
    #[error("invalid peer or rule metadata: {0}")]
    InvalidPeerMetadata(String),
    #[error("manifest epoch ratchet or clock check rejected by LeanMesh.Kernel")]
    ManifestRatchetRejected,
    #[error("manifest Ed25519 signature verification failed")]
    InvalidSignature,
    #[error("overlay IP disjointness or /32 subnet check rejected between peers `{0}` and `{1}`")]
    OverlayIpConflict(String, String),
    #[error("unknown peer `{0}`")]
    UnknownPeer(String),
    #[error("invalid IPv4 overlay address `{0}`")]
    InvalidOverlayIp(String),
}

/// Paloma node allocation & sovereignty class (`0..=6`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum NodeClass {
    MissionSandbox = 0,
    RetiredFree = 1,
    FreeCompute = 2,
    ReservedProd = 3,
    SharedProtected = 4,
    SovereignVault = 5,
    OperatorAdmin = 6,
}

impl NodeClass {
    pub const fn as_u8(self) -> u8 {
        self as u8
    }

    pub const fn is_admin(self) -> bool {
        matches!(self, Self::OperatorAdmin)
    }
}

/// 4-State Mesh Bunker & Sovereign Dead-Man's Switch state (`0..=3`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum BunkerState {
    Normal = 0,
    SoftQuarantine = 1,
    HardLockdown = 2,
    SovereignDeadManTripped = 3,
}

impl BunkerState {
    pub const fn as_u8(self) -> u8 {
        self as u8
    }

    pub const fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Normal,
            1 => Self::SoftQuarantine,
            2 => Self::HardLockdown,
            _ => Self::SovereignDeadManTripped,
        }
    }
}

impl fmt::Display for BunkerState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Normal => write!(f, "normal"),
            Self::SoftQuarantine => write!(f, "soft_quarantine"),
            Self::HardLockdown => write!(f, "hard_lockdown"),
            Self::SovereignDeadManTripped => write!(f, "sovereign_deadman_tripped"),
        }
    }
}

/// Supported L4/L3 protocols in capability rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[repr(u8)]
pub enum MeshProto {
    Icmp = 1,
    Tcp = 6,
    Udp = 17,
}

impl MeshProto {
    pub const fn as_u8(self) -> u8 {
        self as u8
    }
}

/// Endpoint IPv4 address classification for `leanmesh_endpoint_roam_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum IpClass {
    InvalidOrUnspecified = 0,
    LoopbackOrLinkLocal = 1,
    MulticastOrBroadcast = 2,
    PrivateRfc1918 = 3,
    CarrierGradeNat = 4,
    GlobalUnicast = 5,
}

impl IpClass {
    pub fn classify_ipv4(ip: Ipv4Addr) -> Self {
        let octets = ip.octets();
        let is_overlay_subnet = octets[0] == 10 && octets[1] == 88;
        let is_rfc5737_or_benchmark = (octets[0] == 192 && octets[1] == 0 && octets[2] == 2)
            || (octets[0] == 198 && octets[1] == 51 && octets[2] == 100)
            || (octets[0] == 203 && octets[1] == 0 && octets[2] == 113)
            || (octets[0] == 198 && (octets[1] == 18 || octets[1] == 19));
        if ip.is_unspecified()
            || octets[0] == 0
            || is_overlay_subnet
            || is_rfc5737_or_benchmark
        {
            Self::InvalidOrUnspecified
        } else if ip.is_loopback() || ip.is_link_local() {
            Self::LoopbackOrLinkLocal
        } else if ip.is_multicast() || ip.is_broadcast() || (octets[0] & 0xF0) == 240 {
            Self::MulticastOrBroadcast
        } else if ip.is_private() {
            Self::PrivateRfc1918
        } else if octets[0] == 100 && (octets[1] & 0xC0) == 64 {
            Self::CarrierGradeNat
        } else {
            Self::GlobalUnicast
        }
    }
}

/// Selected transport path from `leanmesh_relay_select_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum RelayPathKind {
    DropNoPath = 0,
    DirectWan = 1,
    DirectLan = 2,
    ControlPlaneRelay = 3,
}

impl RelayPathKind {
    pub const fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::DirectWan,
            2 => Self::DirectLan,
            3 => Self::ControlPlaneRelay,
            _ => Self::DropNoPath,
        }
    }
}

/// Atomic reconciliation action from `leanmesh_reconcile_wg_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum ReconcileAction {
    AbortInvalidManifest = 0,
    RemovePeer = 1,
    NoopSkipInactive = 2,
    ReplacePeerKeyOrIp = 3,
    AddPeer = 4,
    UpdateEndpointOnly = 5,
    NoopInSync = 6,
}

impl ReconcileAction {
    pub const fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::RemovePeer,
            2 => Self::NoopSkipInactive,
            3 => Self::ReplacePeerKeyOrIp,
            4 => Self::AddPeer,
            5 => Self::UpdateEndpointOnly,
            6 => Self::NoopInSync,
            _ => Self::AbortInvalidManifest,
        }
    }
}

/// Unpacked decision from `leanmesh_ratchet_epoch_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RatchetDecision {
    pub admitted: bool,
    pub advance_epoch: bool,
    pub advance_panic_seq: bool,
}

pub fn verify_manifest_ratchet(
    sig_valid: bool,
    is_emergency_panic: bool,
    current_epoch: u64,
    candidate_epoch: u64,
    current_panic_seq: u64,
    candidate_panic_seq: u64,
    now_epoch: u64,
    issued_at: u64,
    expires_at: u64,
    max_ttl_secs: u64,
) -> RatchetDecision {
    let raw = unsafe {
        cabi::leanmesh_ratchet_epoch_step(
            u8::from(sig_valid),
            u8::from(is_emergency_panic),
            current_epoch,
            candidate_epoch,
            current_panic_seq,
            candidate_panic_seq,
            now_epoch,
            issued_at,
            expires_at,
            max_ttl_secs,
        )
    };
    RatchetDecision {
        admitted: (raw & 1) == 1,
        advance_epoch: (raw & 256) != 0,
        advance_panic_seq: (raw & 65536) != 0,
    }
}

/// Unpacked decision from `leanmesh_eval_route_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteDecision {
    pub allowed: bool,
    pub require_jit_audit_log: bool,
    pub sovereign_violation_attempt: bool,
}

pub fn evaluate_route_kernel(
    src_id: u32,
    dst_id: u32,
    src_class: NodeClass,
    dst_class: NodeClass,
    src_revoked: bool,
    dst_revoked: bool,
    rule_matched: bool,
    proto: MeshProto,
    dst_port: u32,
    rule_port_min: u32,
    rule_port_max: u32,
    jit_biometric_grant: bool,
    bunker_state: BunkerState,
    now_epoch: u64,
    src_expires_at: u64,
    dst_expires_at: u64,
    jit_expires_at: u64,
) -> RouteDecision {
    let raw = unsafe {
        cabi::leanmesh_eval_route_step(
            src_id,
            dst_id,
            src_class.as_u8(),
            dst_class.as_u8(),
            u8::from(src_revoked),
            u8::from(dst_revoked),
            u8::from(rule_matched),
            proto.as_u8(),
            dst_port,
            rule_port_min,
            rule_port_max,
            u8::from(jit_biometric_grant),
            bunker_state.as_u8(),
            now_epoch,
            src_expires_at,
            dst_expires_at,
            jit_expires_at,
        )
    };
    RouteDecision {
        allowed: (raw & 1) == 1,
        require_jit_audit_log: (raw & 256) != 0,
        sovereign_violation_attempt: (raw & 65536) != 0,
    }
}

/// Stateful RFC 6479 64-packet sliding anti-replay window backed by `LeanMesh.Kernel`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplayWindow64 {
    pub last_max_seq: u64,
    pub bitmap: u64,
}

impl ReplayWindow64 {
    pub const fn new() -> Self {
        Self {
            last_max_seq: 0,
            bitmap: 0,
        }
    }

    pub fn check_and_advance(&mut self, pkt_seq: u64) -> bool {
        let accepted = unsafe {
            cabi::leanmesh_replay_window_step(self.last_max_seq, self.bitmap, pkt_seq) == 1
        };
        if accepted {
            let next_max = unsafe {
                cabi::leanmesh_replay_window_next_max(self.last_max_seq, self.bitmap, pkt_seq)
            };
            let next_bitmap = unsafe {
                cabi::leanmesh_replay_window_next_bitmap(self.last_max_seq, self.bitmap, pkt_seq)
            };
            self.last_max_seq = next_max;
            self.bitmap = next_bitmap;
        }
        accepted
    }
}

/// Unpacked transition from `leanmesh_bunker_isolate_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BunkerTransition {
    pub next_state: BunkerState,
    pub revoke_jit_grants: bool,
    pub prune_non_admin_wg_peers: bool,
    pub lock_sovereign_vault: bool,
}

pub fn step_bunker_isolate(
    current_state: BunkerState,
    is_sovereign_node: bool,
    canary_tripped: bool,
    auth_failure_burst: bool,
    manual_trigger: u8,
    biometric_unbunker: bool,
    heartbeat_valid: bool,
    now_epoch: u64,
    last_heartbeat_at: u64,
    dead_man_timeout_secs: u64,
) -> BunkerTransition {
    let raw = unsafe {
        cabi::leanmesh_bunker_isolate_step(
            current_state.as_u8(),
            u8::from(is_sovereign_node),
            u8::from(canary_tripped),
            u8::from(auth_failure_burst),
            manual_trigger,
            u8::from(biometric_unbunker),
            u8::from(heartbeat_valid),
            now_epoch,
            last_heartbeat_at,
            dead_man_timeout_secs,
        )
    };
    BunkerTransition {
        next_state: BunkerState::from_u8((raw & 0xFF) as u8),
        revoke_jit_grants: (raw & 256) != 0,
        prune_non_admin_wg_peers: (raw & 65536) != 0,
        lock_sovereign_vault: (raw & 16777216) != 0,
    }
}

/// Safe wrapper over `leanmesh_endpoint_roam_step`.
pub fn check_endpoint_roam(
    aead_auth_ok: bool,
    peer_pinned_static: bool,
    candidate_ip: Ipv4Addr,
    allow_private_roam: bool,
    bunker_state: BunkerState,
    candidate_port: u16,
    last_roam_seq: u64,
    pkt_seq: u64,
    last_roam_epoch: u64,
    now_epoch: u64,
    min_roam_interval_secs: u64,
) -> bool {
    let ip_class = IpClass::classify_ipv4(candidate_ip);
    unsafe {
        cabi::leanmesh_endpoint_roam_step(
            u8::from(aead_auth_ok),
            u8::from(peer_pinned_static),
            ip_class as u8,
            u8::from(allow_private_roam),
            bunker_state.as_u8(),
            u32::from(candidate_port),
            last_roam_seq,
            pkt_seq,
            last_roam_epoch,
            now_epoch,
            min_roam_interval_secs,
        ) == 1
    }
}

/// Safe wrapper over `leanmesh_relay_select_step`.
pub fn select_relay_path(
    route_allowed: bool,
    lan_reachable: bool,
    wan_reachable: bool,
    relay_healthy: bool,
    src_id: u32,
    dst_id: u32,
    relay_id: u32,
    active_relay_sessions: u32,
    max_relay_sessions: u32,
    now_epoch: u64,
    direct_handshake_at: u64,
    max_direct_stale_secs: u64,
) -> RelayPathKind {
    let raw = unsafe {
        cabi::leanmesh_relay_select_step(
            u8::from(route_allowed),
            u8::from(lan_reachable),
            u8::from(wan_reachable),
            u8::from(relay_healthy),
            src_id,
            dst_id,
            relay_id,
            active_relay_sessions,
            max_relay_sessions,
            now_epoch,
            direct_handshake_at,
            max_direct_stale_secs,
        )
    };
    RelayPathKind::from_u8(raw)
}

/// Safe wrapper over `leanmesh_frame_bounds_step`.
pub fn verify_frame_bounds(
    magic: u32,
    version: u8,
    frame_kind: u8,
    tag_verified: bool,
    header_len: u64,
    payload_len: u64,
    max_frame_bytes: u64,
    buf_cap: u64,
) -> bool {
    unsafe {
        cabi::leanmesh_frame_bounds_step(
            magic,
            version,
            frame_kind,
            u8::from(tag_verified),
            header_len,
            payload_len,
            max_frame_bytes,
            buf_cap,
        ) == 1
    }
}

/// Unpacked JIT lease evaluation from `leanmesh_jit_lease_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct JitLeaseDecision {
    pub admitted: bool,
    pub reap_grant: bool,
}

pub fn verify_jit_lease(
    biometric_sig_valid: bool,
    operator_same_owner: bool,
    mission_active: bool,
    grant_revoked: bool,
    bunker_state: BunkerState,
    src_class: NodeClass,
    dst_class: NodeClass,
    now_epoch: u64,
    grant_issued_at: u64,
    grant_expires_at: u64,
    max_jit_ttl_secs: u64,
) -> JitLeaseDecision {
    let raw = unsafe {
        cabi::leanmesh_jit_lease_step(
            u8::from(biometric_sig_valid),
            u8::from(operator_same_owner),
            u8::from(mission_active),
            u8::from(grant_revoked),
            bunker_state.as_u8(),
            src_class.as_u8(),
            dst_class.as_u8(),
            now_epoch,
            grant_issued_at,
            grant_expires_at,
            max_jit_ttl_secs,
        )
    };
    JitLeaseDecision {
        admitted: (raw & 1) == 1,
        reap_grant: (raw & 256) != 0,
    }
}

/// Peer descriptor in a signed `MeshManifest`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MeshPeer {
    pub id: u32,
    pub name: String,
    pub node_class: NodeClass,
    pub overlay_ip: String,
    pub prefix_len: u8,
    pub wg_pubkey: String,
    pub sign_pubkey_hex: String,
    pub endpoint: Option<String>,
    pub pinned_static: bool,
    pub revoked: bool,
    pub expires_at: u64,
}

impl MeshPeer {
    pub fn overlay_ipv4_u32(&self) -> Result<u32, MeshError> {
        let addr: Ipv4Addr = self
            .overlay_ip
            .parse()
            .map_err(|_| MeshError::InvalidOverlayIp(self.overlay_ip.clone()))?;
        Ok(u32::from(addr))
    }
}

/// Explicit non-transitive capability rule `(src_peer -> dst_peer, proto, port_min..=port_max)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityRule {
    pub src_peer: String,
    pub dst_peer: String,
    pub proto: MeshProto,
    pub port_min: u32,
    pub port_max: u32,
    pub description: String,
}

/// Signed topology & capability manifest for the `lean-mesh` overlay.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MeshManifest {
    pub version: u8,
    pub epoch: u64,
    pub panic_seq: u64,
    pub is_emergency_panic: bool,
    pub issued_at: u64,
    pub expires_at: u64,
    pub max_ttl_secs: u64,
    pub coordinator_pubkey_hex: String,
    pub peers: Vec<MeshPeer>,
    pub rules: Vec<CapabilityRule>,
    pub signature_hex: String,
}

impl MeshManifest {
    /// Deterministic SHA-256 digest over all manifest fields except `signature_hex`.
    pub fn canonical_signing_bytes(&self) -> Vec<u8> {
        #[derive(Serialize)]
        struct UnsignedView<'a> {
            version: u8,
            epoch: u64,
            panic_seq: u64,
            is_emergency_panic: bool,
            issued_at: u64,
            expires_at: u64,
            max_ttl_secs: u64,
            coordinator_pubkey_hex: &'a str,
            peers: &'a [MeshPeer],
            rules: &'a [CapabilityRule],
        }
        let view = UnsignedView {
            version: self.version,
            epoch: self.epoch,
            panic_seq: self.panic_seq,
            is_emergency_panic: self.is_emergency_panic,
            issued_at: self.issued_at,
            expires_at: self.expires_at,
            max_ttl_secs: self.max_ttl_secs,
            coordinator_pubkey_hex: &self.coordinator_pubkey_hex,
            peers: &self.peers,
            rules: &self.rules,
        };
        let mut hasher = Sha256::new();
        hasher.update(b"lean-mesh-manifest-v1:");
        hasher.update(serde_json::to_vec(&view).expect("serialize UnsignedView"));
        hasher.finalize().to_vec()
    }

    pub fn sign(&mut self, signing_key: &SigningKey) {
        self.coordinator_pubkey_hex = hex::encode(signing_key.verifying_key().to_bytes());
        let digest = self.canonical_signing_bytes();
        let sig: Signature = signing_key.sign(&digest);
        self.signature_hex = hex::encode(sig.to_bytes());
    }

    pub fn verify_ed25519(&self) -> bool {
        let Ok(pk_bytes) = hex::decode(&self.coordinator_pubkey_hex) else {
            return false;
        };
        let Ok(pk_arr): Result<[u8; 32], _> = pk_bytes.try_into() else {
            return false;
        };
        let Ok(verifying_key) = VerifyingKey::from_bytes(&pk_arr) else {
            return false;
        };
        let Ok(sig_bytes) = hex::decode(&self.signature_hex) else {
            return false;
        };
        let Ok(sig_arr): Result<[u8; 64], _> = sig_bytes.try_into() else {
            return false;
        };
        let signature = Signature::from_bytes(&sig_arr);
        let digest = self.canonical_signing_bytes();
        verifying_key.verify(&digest, &signature).is_ok()
    }

    /// Full formal verification of a manifest using `leanmesh_ratchet_epoch_step` and
    /// unary + pairwise `leanmesh_overlay_ip_step`.
    pub fn verify_formal(
        &self,
        current_epoch: u64,
        current_panic_seq: u64,
        now_epoch: u64,
    ) -> Result<RatchetDecision, MeshError> {
        if self.version != LEAN_MESH_PROTOCOL_VERSION {
            return Err(MeshError::UnsupportedManifestVersion(self.version));
        }
        if self.peers.is_empty() {
            return Err(MeshError::EmptyPeerList);
        }

        let has_unsafe_chars = |s: &str| -> bool {
            s.is_empty()
                || s.chars().any(|c| {
                    c.is_control() || matches!(c, '\n' | '\r' | '\0' | '"' | ';' | '{' | '}' | '#')
                })
        };

        let sig_ok = self.verify_ed25519();
        let ratchet = verify_manifest_ratchet(
            sig_ok,
            self.is_emergency_panic,
            current_epoch,
            self.epoch,
            current_panic_seq,
            self.panic_seq,
            now_epoch,
            self.issued_at,
            self.expires_at,
            self.max_ttl_secs,
        );
        if !ratchet.admitted {
            if !sig_ok {
                return Err(MeshError::InvalidSignature);
            }
            return Err(MeshError::ManifestRatchetRejected);
        }

        for rule in &self.rules {
            if has_unsafe_chars(&rule.src_peer)
                || has_unsafe_chars(&rule.dst_peer)
                || has_unsafe_chars(&rule.description)
            {
                return Err(MeshError::InvalidPeerMetadata(
                    "capability rule contains forbidden control or syntax characters".into(),
                ));
            }
        }

        for i in 0..self.peers.len() {
            let p_a = &self.peers[i];
            if has_unsafe_chars(&p_a.name)
                || has_unsafe_chars(&p_a.wg_pubkey)
                || has_unsafe_chars(&p_a.sign_pubkey_hex)
            {
                return Err(MeshError::InvalidPeerMetadata(format!(
                    "peer `{}` contains forbidden characters",
                    p_a.name
                )));
            }
            if let Some(ep) = &p_a.endpoint {
                if has_unsafe_chars(ep) {
                    return Err(MeshError::InvalidPeerMetadata(format!(
                        "peer `{}` endpoint contains forbidden characters",
                        p_a.name
                    )));
                }
            }
            let decoded_key = base64::engine::general_purpose::STANDARD
                .decode(&p_a.wg_pubkey)
                .map_err(|_| {
                    MeshError::InvalidPeerMetadata(format!(
                        "peer `{}` wg_pubkey is not valid base64",
                        p_a.name
                    ))
                })?;
            if decoded_key.len() != 32 {
                return Err(MeshError::InvalidPeerMetadata(format!(
                    "peer `{}` wg_pubkey must decode to 32 bytes (got {})",
                    p_a.name,
                    decoded_key.len()
                )));
            }
            let decoded_sign_pk = hex::decode(&p_a.sign_pubkey_hex).map_err(|_| {
                MeshError::InvalidPeerMetadata(format!(
                    "peer `{}` sign_pubkey_hex is not valid hex",
                    p_a.name
                ))
            })?;
            let sign_pk_arr: [u8; 32] = decoded_sign_pk.try_into().map_err(|_| {
                MeshError::InvalidPeerMetadata(format!(
                    "peer `{}` sign_pubkey_hex must decode to 32 bytes",
                    p_a.name
                ))
            })?;
            if VerifyingKey::from_bytes(&sign_pk_arr).is_err() {
                return Err(MeshError::InvalidPeerMetadata(format!(
                    "peer `{}` sign_pubkey_hex is not a valid Ed25519 verifying key",
                    p_a.name
                )));
            }
            if p_a.sign_pubkey_hex.eq_ignore_ascii_case(&self.coordinator_pubkey_hex) {
                return Err(MeshError::InvalidPeerMetadata(format!(
                    "peer `{}` sign_pubkey_hex must be distinct from coordinator_pubkey_hex",
                    p_a.name
                )));
            }

            let ip_a = p_a.overlay_ipv4_u32()?;
            // Unary validation of `p_a` via `leanmesh_overlay_ip_step` so 1-peer manifests
            // still undergo the full kernel `/32` and `10.88.0.1..=10.88.255.254` bounds check.
            let probe_id = if p_a.id == u32::MAX {
                u32::MAX - 1
            } else {
                u32::MAX
            };
            let probe_ip = if ip_a == 0x0A58_FFFE {
                0x0A58_0001
            } else {
                0x0A58_FFFE
            };
            let unary_ok = unsafe {
                cabi::leanmesh_overlay_ip_step(p_a.id, probe_id, ip_a, probe_ip, p_a.prefix_len, 32)
                    == 1
            };
            if !unary_ok {
                return Err(MeshError::OverlayIpConflict(
                    p_a.name.clone(),
                    p_a.name.clone(),
                ));
            }

            for j in (i + 1)..self.peers.len() {
                let p_b = &self.peers[j];
                if p_a.name == p_b.name
                    || p_a.wg_pubkey == p_b.wg_pubkey
                    || p_a.sign_pubkey_hex.eq_ignore_ascii_case(&p_b.sign_pubkey_hex)
                {
                    return Err(MeshError::InvalidPeerMetadata(format!(
                        "duplicate peer name, WireGuard public key, or Ed25519 sign_pubkey_hex between `{}` and `{}`",
                        p_a.name, p_b.name
                    )));
                }
                let ip_b = p_b.overlay_ipv4_u32()?;
                let ok = unsafe {
                    cabi::leanmesh_overlay_ip_step(
                        p_a.id,
                        p_b.id,
                        ip_a,
                        ip_b,
                        p_a.prefix_len,
                        p_b.prefix_len,
                    ) == 1
                };
                if !ok {
                    return Err(MeshError::OverlayIpConflict(
                        p_a.name.clone(),
                        p_b.name.clone(),
                    ));
                }
            }
        }
        Ok(ratchet)
    }

    pub fn find_peer(&self, name: &str) -> Result<&MeshPeer, MeshError> {
        self.peers
            .iter()
            .find(|p| p.name == name)
            .ok_or_else(|| MeshError::UnknownPeer(name.to_string()))
    }

    /// Evaluates whether `src_name -> dst_name` on `(proto, dst_port)` is admitted by `LeanMesh.Kernel`.
    pub fn evaluate_route(
        &self,
        src_name: &str,
        dst_name: &str,
        proto: MeshProto,
        dst_port: u32,
        jit_biometric_grant: bool,
        jit_expires_at: u64,
        bunker_state: BunkerState,
        now_epoch: u64,
    ) -> Result<RouteDecision, MeshError> {
        let src = self.find_peer(src_name)?;
        let dst = self.find_peer(dst_name)?;

        let matched_rule = self.rules.iter().find(|r| {
            r.src_peer == src_name
                && r.dst_peer == dst_name
                && r.proto == proto
                && ((proto == MeshProto::Icmp && dst_port == 0 && r.port_min == 0 && r.port_max == 0)
                    || (r.port_min <= dst_port && dst_port <= r.port_max))
        });

        let (rule_matched, p_min, p_max) = match matched_rule {
            Some(r) => (true, r.port_min, r.port_max),
            None => (false, dst_port, dst_port),
        };

        Ok(evaluate_route_kernel(
            src.id,
            dst.id,
            src.node_class,
            dst.node_class,
            src.revoked,
            dst.revoked,
            rule_matched,
            proto,
            dst_port,
            p_min,
            p_max,
            jit_biometric_grant,
            bunker_state,
            now_epoch,
            src.expires_at,
            dst.expires_at,
            jit_expires_at,
        ))
    }

    /// Renders a deterministic kernel WireGuard configuration (`wg-leanmesh0.conf`) for `node_name`.
    /// Fails closed if the manifest fails `verify_formal(0, 0, now_epoch)`.
    pub fn render_wireguard_config(
        &self,
        node_name: &str,
        private_key_placeholder: &str,
        bunker_state: BunkerState,
        now_epoch: u64,
    ) -> Result<String, MeshError> {
        self.verify_formal(0, 0, now_epoch)?;
        let self_peer = self.find_peer(node_name)?;
        let bunker_prune_mode: u8 = match bunker_state {
            BunkerState::Normal | BunkerState::SoftQuarantine => 0,
            BunkerState::HardLockdown => 1,
            BunkerState::SovereignDeadManTripped => 2,
        };

        let listen_port = self_peer
            .endpoint
            .as_deref()
            .and_then(|ep| ep.rsplit_once(':'))
            .and_then(|(_, p)| p.parse::<u16>().ok())
            .unwrap_or(LEAN_MESH_DEFAULT_WG_PORT);

        let mut out = String::new();
        out.push_str(&format!(
            "# Autogenerated by lean-mesh (epoch={}, bunker={})\n",
            self.epoch, bunker_state
        ));
        out.push_str("[Interface]\n");
        out.push_str(&format!("PrivateKey = {private_key_placeholder}\n"));
        out.push_str(&format!("ListenPort = {listen_port}\n"));
        out.push_str(&format!(
            "# Overlay Address: {}/{}\n\n",
            self_peer.overlay_ip, self_peer.prefix_len
        ));

        if bunker_state == BunkerState::SovereignDeadManTripped {
            out.push_str("# SOVEREIGN DEAD-MAN SWITCH TRIPPED: all mesh peers severed.\n");
        }

        for peer in &self.peers {
            if peer.id == self_peer.id {
                continue;
            }
            let act = ReconcileAction::from_u8(unsafe {
                cabi::leanmesh_reconcile_wg_step(
                    1,
                    0,
                    u8::from(peer.revoked),
                    1,
                    1,
                    0,
                    bunker_prune_mode,
                    u8::from(peer.node_class.is_admin()),
                    now_epoch,
                    peer.expires_at,
                )
            });
            if act != ReconcileAction::AddPeer {
                continue;
            }
            out.push_str(&format!(
                "# Peer: {} (id={}, class={:?})\n",
                peer.name, peer.id, peer.node_class
            ));
            out.push_str("[Peer]\n");
            out.push_str(&format!("PublicKey = {}\n", peer.wg_pubkey));
            out.push_str(&format!("AllowedIPs = {}/{}\n", peer.overlay_ip, peer.prefix_len));
            if let Some(ep) = &peer.endpoint {
                out.push_str(&format!("Endpoint = {ep}\n"));
            }
            out.push_str("PersistentKeepalive = 25\n\n");
        }
        Ok(out)
    }

    /// Renders a deterministic `nftables` capability enforcement policy for `node_name`.
    /// Fails closed if the manifest fails `verify_formal(0, 0, now_epoch)`.
    pub fn render_nftables_policy(
        &self,
        node_name: &str,
        bunker_state: BunkerState,
        now_epoch: u64,
    ) -> Result<String, MeshError> {
        self.verify_formal(0, 0, now_epoch)?;
        let self_peer = self.find_peer(node_name)?;
        let peer_by_name: BTreeMap<&str, &MeshPeer> =
            self.peers.iter().map(|p| (p.name.as_str(), p)).collect();

        let mut out = String::new();
        out.push_str("#!/usr/sbin/nft -f\n");
        out.push_str(&format!(
            "# Autogenerated by lean-mesh for node `{}` (class={:?}, epoch={}, bunker={})\n",
            self_peer.name, self_peer.node_class, self.epoch, bunker_state
        ));
        out.push_str("table inet lean_mesh {\n");
        out.push_str("  chain mesh_forward {\n");
        out.push_str("    type filter hook forward priority -5; policy accept;\n");
        out.push_str(&format!(
            "    iifname \"{}\" counter drop\n",
            LEAN_MESH_INTERFACE_NAME
        ));
        out.push_str(&format!(
            "    oifname \"{}\" counter drop\n",
            LEAN_MESH_INTERFACE_NAME
        ));
        out.push_str("  }\n\n");
        out.push_str("  chain mesh_input {\n");
        out.push_str("    type filter hook input priority -5; policy accept;\n");
        out.push_str(&format!(
            "    iifname != \"{}\" accept\n",
            LEAN_MESH_INTERFACE_NAME
        ));
        out.push_str("    meta nfproto ipv6 counter drop\n");
        out.push_str("    ct state established,related accept\n");

        if bunker_state == BunkerState::SovereignDeadManTripped {
            out.push_str("    # Sovereign Dead-Man Switch tripped: drop all wg-leanmesh0 traffic\n");
            out.push_str("    counter drop\n");
            out.push_str("  }\n}\n");
            return Ok(out);
        }

        for rule in &self.rules {
            if rule.dst_peer != node_name {
                continue;
            }
            let Some(src_peer) = peer_by_name.get(rule.src_peer.as_str()) else {
                continue;
            };
            let decision = evaluate_route_kernel(
                src_peer.id,
                self_peer.id,
                src_peer.node_class,
                self_peer.node_class,
                src_peer.revoked,
                self_peer.revoked,
                true,
                rule.proto,
                rule.port_min,
                rule.port_min,
                rule.port_max,
                false,
                bunker_state,
                now_epoch,
                src_peer.expires_at,
                self_peer.expires_at,
                0,
            );
            if !decision.allowed {
                continue;
            }
            match rule.proto {
                MeshProto::Icmp => {
                    out.push_str(&format!(
                        "    ip saddr {} ip daddr {} ip protocol icmp accept # {}\n",
                        src_peer.overlay_ip, self_peer.overlay_ip, rule.description
                    ));
                }
                MeshProto::Tcp | MeshProto::Udp => {
                    let l4 = if rule.proto == MeshProto::Tcp {
                        "tcp"
                    } else {
                        "udp"
                    };
                    let port_expr = if rule.port_min == rule.port_max {
                        format!("{}", rule.port_min)
                    } else {
                        format!("{}-{}", rule.port_min, rule.port_max)
                    };
                    out.push_str(&format!(
                        "    ip saddr {} ip daddr {} {} dport {} accept # {}\n",
                        src_peer.overlay_ip, self_peer.overlay_ip, l4, port_expr, rule.description
                    ));
                }
            }
        }

        out.push_str("    counter drop\n");
        out.push_str("  }\n}\n");
        Ok(out)
    }

    /// Reconciles live kernel WireGuard state (`wg show <iface> dump` output) against this
    /// formally verified `MeshManifest` using `leanmesh_reconcile_wg_step`.
    ///
    /// Evaluates every manifest peer (`peerPresentInKernel`, `pubkeyMatches`, `allowedIpMatches`,
    /// `endpointChanged`) as well as any unknown peer currently present in the kernel (`peerRevoked = 1`),
    /// returning the deterministic reconciliation plan (`AddPeer`, `UpdateEndpoint`, `ReplacePeer`,
    /// `RemovePeer`, `NoopInSync`, `NoopAbsent`).
    pub fn reconcile_wireguard_dump(
        &self,
        node_name: &str,
        wg_dump: &str,
        bunker_state: BunkerState,
        now_epoch: u64,
    ) -> Result<Vec<PeerReconcilePlan>, MeshError> {
        self.verify_formal(0, 0, now_epoch)?;
        let self_peer = self.find_peer(node_name)?;
        let bunker_prune_mode: u8 = match bunker_state {
            BunkerState::Normal | BunkerState::SoftQuarantine => 0,
            BunkerState::HardLockdown => 1,
            BunkerState::SovereignDeadManTripped => 2,
        };

        // Parse `wg show <iface> dump` peer lines:
        // `<public-key>\t<preshared-key>\t<endpoint>\t<allowed-ips>\t<latest-handshake>\t<rx>\t<tx>\t<persistent-keepalive>`
        let mut kernel_peers: BTreeMap<String, (Option<String>, String)> = BTreeMap::new();
        for raw_line in wg_dump.lines() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let cols: Vec<&str> = line.split('\t').collect();
            if cols.len() >= 8 {
                let pubkey = cols[0].trim().to_string();
                let ep = match cols[2].trim() {
                    "(none)" | "" => None,
                    other => Some(other.to_string()),
                };
                let allowed_ips = cols[3].trim().to_string();
                kernel_peers.insert(pubkey, (ep, allowed_ips));
            }
        }

        let mut plans = Vec::new();
        let mut manifest_pubkeys = BTreeMap::new();

        for peer in &self.peers {
            if peer.id == self_peer.id {
                continue;
            }
            manifest_pubkeys.insert(peer.wg_pubkey.as_str(), peer);
            let expected_allowed_ip = format!("{}/{}", peer.overlay_ip, peer.prefix_len);
            let (present, pubkey_matches, allowed_ip_matches, endpoint_changed) =
                match kernel_peers.get(&peer.wg_pubkey) {
                    Some((kern_ep, kern_allowed)) => {
                        let ip_ok = kern_allowed == &expected_allowed_ip;
                        let ep_changed = kern_ep != &peer.endpoint;
                        (1u8, 1u8, u8::from(ip_ok), u8::from(ep_changed))
                    }
                    None => (0u8, 1u8, 1u8, 0u8),
                };

            let action = ReconcileAction::from_u8(unsafe {
                cabi::leanmesh_reconcile_wg_step(
                    1,
                    present,
                    u8::from(peer.revoked),
                    pubkey_matches,
                    allowed_ip_matches,
                    endpoint_changed,
                    bunker_prune_mode,
                    u8::from(peer.node_class.is_admin()),
                    now_epoch,
                    peer.expires_at,
                )
            });

            let wg_set_args = match action {
                ReconcileAction::AddPeer | ReconcileAction::ReplacePeerKeyOrIp => {
                    let mut args = vec![
                        "set".into(),
                        LEAN_MESH_INTERFACE_NAME.into(),
                        "peer".into(),
                        peer.wg_pubkey.clone(),
                        "allowed-ips".into(),
                        expected_allowed_ip,
                        "persistent-keepalive".into(),
                        "25".into(),
                    ];
                    if let Some(ep) = &peer.endpoint {
                        args.push("endpoint".into());
                        args.push(ep.clone());
                    }
                    Some(args)
                }
                ReconcileAction::UpdateEndpointOnly => peer.endpoint.as_ref().map(|ep| {
                    vec![
                        "set".into(),
                        LEAN_MESH_INTERFACE_NAME.into(),
                        "peer".into(),
                        peer.wg_pubkey.clone(),
                        "endpoint".into(),
                        ep.clone(),
                    ]
                }),
                ReconcileAction::RemovePeer => Some(vec![
                    "set".into(),
                    LEAN_MESH_INTERFACE_NAME.into(),
                    "peer".into(),
                    peer.wg_pubkey.clone(),
                    "remove".into(),
                ]),
                ReconcileAction::AbortInvalidManifest
                | ReconcileAction::NoopSkipInactive
                | ReconcileAction::NoopInSync => None,
            };

            plans.push(PeerReconcilePlan {
                peer_name: peer.name.clone(),
                wg_pubkey: peer.wg_pubkey.clone(),
                action,
                wg_set_args,
            });
        }

        // Any unknown peer present in the kernel that is NOT in the verified manifest is pruned (`peerRevoked = 1`).
        for kern_pubkey in kernel_peers.keys() {
            if !manifest_pubkeys.contains_key(kern_pubkey.as_str()) {
                let action = ReconcileAction::from_u8(unsafe {
                    cabi::leanmesh_reconcile_wg_step(
                        1,
                        1,
                        1,
                        0,
                        0,
                        0,
                        bunker_prune_mode,
                        0,
                        now_epoch,
                        0,
                    )
                });
                plans.push(PeerReconcilePlan {
                    peer_name: "<unlisted-kernel-peer>".into(),
                    wg_pubkey: kern_pubkey.clone(),
                    action,
                    wg_set_args: Some(vec![
                        "set".into(),
                        LEAN_MESH_INTERFACE_NAME.into(),
                        "peer".into(),
                        kern_pubkey.clone(),
                        "remove".into(),
                    ]),
                });
            }
        }

        Ok(plans)
    }

    /// Generates the canonical Paloma fleet topology manifest (`10.88.0.0/16`) signed by `signing_key`.
    pub fn paloma_fleet_default(now_epoch: u64, signing_key: &SigningKey) -> Self {
        let expires_at = now_epoch + 86_400;
        let det_wg_pub = |label: &str| -> String {
            let mut h = Sha256::new();
            h.update(b"lean-mesh-wg-pub:");
            h.update(label.as_bytes());
            base64::engine::general_purpose::STANDARD.encode(h.finalize())
        };
        let det_sign_pub = |label: &str| -> String {
            hex::encode(default_peer_signing_key(label).verifying_key().to_bytes())
        };

        let peers = vec![
            MeshPeer {
                id: 1,
                name: "agent-core".into(),
                node_class: NodeClass::SharedProtected,
                overlay_ip: "10.88.0.1".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("agent-core"),
                sign_pubkey_hex: det_sign_pub("agent-core"),
                endpoint: Some("95.216.173.237:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 2,
                name: "dgx-spark".into(),
                node_class: NodeClass::SovereignVault,
                overlay_ip: "10.88.0.2".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("dgx-spark"),
                sign_pubkey_hex: det_sign_pub("dgx-spark"),
                endpoint: None,
                pinned_static: false,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 3,
                name: "thomas-md".into(),
                node_class: NodeClass::ReservedProd,
                overlay_ip: "10.88.0.3".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("thomas-md"),
                sign_pubkey_hex: det_sign_pub("thomas-md"),
                endpoint: Some("46.225.188.198:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 4,
                name: "polymath".into(),
                node_class: NodeClass::SharedProtected,
                overlay_ip: "10.88.0.4".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("polymath"),
                sign_pubkey_hex: det_sign_pub("polymath"),
                endpoint: Some("51.83.45.146:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 5,
                name: "maven-repo".into(),
                node_class: NodeClass::SharedProtected,
                overlay_ip: "10.88.0.5".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("maven-repo"),
                sign_pubkey_hex: det_sign_pub("maven-repo"),
                endpoint: Some("54.36.110.220:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 11,
                name: "ashur".into(),
                node_class: NodeClass::FreeCompute,
                overlay_ip: "10.88.0.11".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("ashur"),
                sign_pubkey_hex: det_sign_pub("ashur"),
                endpoint: Some("65.108.230.229:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 12,
                name: "babylon".into(),
                node_class: NodeClass::FreeCompute,
                overlay_ip: "10.88.0.12".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("babylon"),
                sign_pubkey_hex: det_sign_pub("babylon"),
                endpoint: Some("15.235.226.153:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 13,
                name: "nippur".into(),
                node_class: NodeClass::FreeCompute,
                overlay_ip: "10.88.0.13".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("nippur"),
                sign_pubkey_hex: det_sign_pub("nippur"),
                endpoint: Some("37.187.143.36:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 14,
                name: "old-agent".into(),
                node_class: NodeClass::FreeCompute,
                overlay_ip: "10.88.0.14".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("old-agent"),
                sign_pubkey_hex: det_sign_pub("old-agent"),
                endpoint: Some("46.225.95.157:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 15,
                name: "watchtower".into(),
                node_class: NodeClass::FreeCompute,
                overlay_ip: "10.88.0.15".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("watchtower"),
                sign_pubkey_hex: det_sign_pub("watchtower"),
                endpoint: Some("51.75.66.161:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 21,
                name: "api-starknet-id".into(),
                node_class: NodeClass::RetiredFree,
                overlay_ip: "10.88.0.21".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("api-starknet-id"),
                sign_pubkey_hex: det_sign_pub("api-starknet-id"),
                endpoint: Some("5.39.72.91:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 22,
                name: "sepolia-starknet-id".into(),
                node_class: NodeClass::RetiredFree,
                overlay_ip: "10.88.0.22".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("sepolia-starknet-id"),
                sign_pubkey_hex: det_sign_pub("sepolia-starknet-id"),
                endpoint: Some("5.39.73.3:51888".into()),
                pinned_static: true,
                revoked: false,
                expires_at,
            },
            MeshPeer {
                id: 100,
                name: "macbook-air".into(),
                node_class: NodeClass::OperatorAdmin,
                overlay_ip: "10.88.0.100".into(),
                prefix_len: 32,
                wg_pubkey: det_wg_pub("macbook-air"),
                sign_pubkey_hex: det_sign_pub("macbook-air"),
                endpoint: None,
                pinned_static: false,
                revoked: false,
                expires_at,
            },
        ];

        let mut rules = Vec::new();
        for worker in ["ashur", "babylon", "nippur", "old-agent", "watchtower"] {
            rules.push(CapabilityRule {
                src_peer: "agent-core".into(),
                dst_peer: worker.into(),
                proto: MeshProto::Tcp,
                port_min: 3088,
                port_max: 3088,
                description: format!("Orb control-plane dispatch agent-core -> {worker}:3088"),
            });
            rules.push(CapabilityRule {
                src_peer: worker.into(),
                dst_peer: "agent-core".into(),
                proto: MeshProto::Tcp,
                port_min: 3000,
                port_max: 3000,
                description: format!("Worker telemetry & LLM proxy {worker} -> agent-core:3000"),
            });
        }
        rules.push(CapabilityRule {
            src_peer: "agent-core".into(),
            dst_peer: "dgx-spark".into(),
            proto: MeshProto::Tcp,
            port_min: 8888,
            port_max: 8890,
            description: "Orb control-plane -> dgx-spark Hindsight memory & remarkablesync".into(),
        });
        for peer in &peers {
            if peer.name != "macbook-air" {
                rules.push(CapabilityRule {
                    src_peer: "macbook-air".into(),
                    dst_peer: peer.name.clone(),
                    proto: MeshProto::Tcp,
                    port_min: 22,
                    port_max: 22,
                    description: format!("Operator break-glass SSH macbook-air -> {}:22", peer.name),
                });
            }
        }

        let mut manifest = Self {
            version: 1,
            epoch: 1,
            panic_seq: 0,
            is_emergency_panic: false,
            issued_at: now_epoch,
            expires_at,
            max_ttl_secs: 86_400,
            coordinator_pubkey_hex: String::new(),
            peers,
            rules,
            signature_hex: String::new(),
        };
        manifest.sign(signing_key);
        manifest
    }
}

/// Deterministic per-peer WireGuard reconciliation action produced by `reconcile_wireguard_dump`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerReconcilePlan {
    pub peer_name: String,
    pub wg_pubkey: String,
    pub action: ReconcileAction,
    pub wg_set_args: Option<Vec<String>>,
}

/// Derives the default initial per-peer Ed25519 signing key used in `paloma_fleet_default`
/// before a node's hardware-generated Ed25519 public key is enrolled in the manifest.
pub fn default_peer_signing_key(peer_name: &str) -> SigningKey {
    let mut h = Sha256::new();
    h.update(b"lean-mesh-peer-ed25519-v1:");
    h.update(peer_name.as_bytes());
    let digest: [u8; 32] = h.finalize().into();
    SigningKey::from_bytes(&digest)
}

/// Canonical domain-separated SHA-256 digest for authenticated node configuration render requests.
pub fn canonical_render_auth_bytes(peer_name: &str, seq: u64, timestamp: u64) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(b"lean-mesh-render-v1:");
    hasher.update(peer_name.as_bytes());
    hasher.update(b":");
    hasher.update(seq.to_be_bytes());
    hasher.update(b":");
    hasher.update(timestamp.to_be_bytes());
    hasher.finalize().to_vec()
}

/// Signs a canonical node configuration render request `(peer_name, seq, timestamp)` with `signing_key`.
pub fn sign_render_auth(
    signing_key: &SigningKey,
    peer_name: &str,
    seq: u64,
    timestamp: u64,
) -> String {
    let digest = canonical_render_auth_bytes(peer_name, seq, timestamp);
    let sig: Signature = signing_key.sign(&digest);
    hex::encode(sig.to_bytes())
}

/// Verifies an Ed25519 signature over a canonical node configuration render request `(peer_name, seq, timestamp)`.
pub fn verify_render_auth_signature(
    pubkey_hex: &str,
    peer_name: &str,
    seq: u64,
    timestamp: u64,
    signature_hex: &str,
) -> bool {
    let Ok(pk_bytes) = hex::decode(pubkey_hex) else {
        return false;
    };
    let Ok(pk_arr): Result<[u8; 32], _> = pk_bytes.try_into() else {
        return false;
    };
    let Ok(verifying_key) = VerifyingKey::from_bytes(&pk_arr) else {
        return false;
    };
    let Ok(sig_bytes) = hex::decode(signature_hex) else {
        return false;
    };
    let Ok(sig_arr): Result<[u8; 64], _> = sig_bytes.try_into() else {
        return false;
    };
    let signature = Signature::from_bytes(&sig_arr);
    let digest = canonical_render_auth_bytes(peer_name, seq, timestamp);
    verifying_key.verify(&digest, &signature).is_ok()
}

/// Canonical domain-separated SHA-256 digest for authenticated mesh heartbeats.
pub fn canonical_heartbeat_bytes(peer_name: &str, heartbeat_seq: u64, timestamp: u64) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(b"lean-mesh-heartbeat-v1:");
    hasher.update(peer_name.as_bytes());
    hasher.update(b":");
    hasher.update(heartbeat_seq.to_be_bytes());
    hasher.update(b":");
    hasher.update(timestamp.to_be_bytes());
    hasher.finalize().to_vec()
}

/// Signs a canonical mesh heartbeat `(peer_name, heartbeat_seq, timestamp)` with `signing_key`.
pub fn sign_heartbeat(
    signing_key: &SigningKey,
    peer_name: &str,
    heartbeat_seq: u64,
    timestamp: u64,
) -> String {
    let digest = canonical_heartbeat_bytes(peer_name, heartbeat_seq, timestamp);
    let sig: Signature = signing_key.sign(&digest);
    hex::encode(sig.to_bytes())
}

/// Verifies an Ed25519 signature over a canonical mesh heartbeat `(peer_name, heartbeat_seq, timestamp)`.
pub fn verify_heartbeat_signature(
    pubkey_hex: &str,
    peer_name: &str,
    heartbeat_seq: u64,
    timestamp: u64,
    signature_hex: &str,
) -> bool {
    let Ok(pk_bytes) = hex::decode(pubkey_hex) else {
        return false;
    };
    let Ok(pk_arr): Result<[u8; 32], _> = pk_bytes.try_into() else {
        return false;
    };
    let Ok(verifying_key) = VerifyingKey::from_bytes(&pk_arr) else {
        return false;
    };
    let Ok(sig_bytes) = hex::decode(signature_hex) else {
        return false;
    };
    let Ok(sig_arr): Result<[u8; 64], _> = sig_bytes.try_into() else {
        return false;
    };
    let signature = Signature::from_bytes(&sig_arr);
    let digest = canonical_heartbeat_bytes(peer_name, heartbeat_seq, timestamp);
    verifying_key.verify(&digest, &signature).is_ok()
}

/// Canonical domain-separated SHA-256 digest for authenticated endpoint roam control frames.
pub fn canonical_roam_bytes(
    peer_name: &str,
    candidate_ip: Ipv4Addr,
    candidate_port: u16,
    pkt_seq: u64,
    timestamp: u64,
) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(b"lean-mesh-roam-v1:");
    hasher.update(peer_name.as_bytes());
    hasher.update(b":");
    hasher.update(candidate_ip.octets());
    hasher.update(b":");
    hasher.update(candidate_port.to_be_bytes());
    hasher.update(b":");
    hasher.update(pkt_seq.to_be_bytes());
    hasher.update(b":");
    hasher.update(timestamp.to_be_bytes());
    hasher.finalize().to_vec()
}

/// Signs a canonical endpoint roam frame `(peer_name, candidate_ip, candidate_port, pkt_seq, timestamp)`.
pub fn sign_roam(
    signing_key: &SigningKey,
    peer_name: &str,
    candidate_ip: Ipv4Addr,
    candidate_port: u16,
    pkt_seq: u64,
    timestamp: u64,
) -> String {
    let digest = canonical_roam_bytes(peer_name, candidate_ip, candidate_port, pkt_seq, timestamp);
    let sig: Signature = signing_key.sign(&digest);
    hex::encode(sig.to_bytes())
}

/// Verifies an Ed25519 signature + `leanmesh_frame_bounds_step` wire bounds over an endpoint roam frame.
pub fn verify_roam_signature(
    pubkey_hex: &str,
    peer_name: &str,
    candidate_ip: Ipv4Addr,
    candidate_port: u16,
    pkt_seq: u64,
    timestamp: u64,
    signature_hex: &str,
) -> bool {
    let Ok(pk_bytes) = hex::decode(pubkey_hex) else {
        return false;
    };
    let Ok(pk_arr): Result<[u8; 32], _> = pk_bytes.try_into() else {
        return false;
    };
    let Ok(verifying_key) = VerifyingKey::from_bytes(&pk_arr) else {
        return false;
    };
    let Ok(sig_bytes) = hex::decode(signature_hex) else {
        return false;
    };
    let Ok(sig_arr): Result<[u8; 64], _> = sig_bytes.try_into() else {
        return false;
    };
    let signature = Signature::from_bytes(&sig_arr);
    let digest = canonical_roam_bytes(peer_name, candidate_ip, candidate_port, pkt_seq, timestamp);
    let tag_ok = verifying_key.verify(&digest, &signature).is_ok();
    verify_frame_bounds(
        LEAN_MESH_FRAME_MAGIC,
        LEAN_MESH_PROTOCOL_VERSION,
        2,
        tag_ok,
        64,
        (peer_name.len() as u64) + 32,
        4096,
        4096,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_signing_key() -> SigningKey {
        SigningKey::from_bytes(&[7u8; 32])
    }

    #[test]
    fn paloma_fleet_manifest_verifies_and_enforces_invariants() {
        let sk = test_signing_key();
        let now = 1_760_000_000;
        let manifest = MeshManifest::paloma_fleet_default(now, &sk);

        let ratchet = manifest
            .verify_formal(0, 0, now + 10)
            .expect("valid manifest must pass LeanMesh.Kernel verification");
        assert!(ratchet.admitted);
        assert!(ratchet.advance_epoch);
        assert!(!ratchet.advance_panic_seq);

        // Stale epoch rollback is rejected.
        assert!(manifest.verify_formal(1, 0, now + 10).is_err());

        // 1. Control plane -> worker :3088 is allowed.
        let cp_to_ashur = manifest
            .evaluate_route(
                "agent-core",
                "ashur",
                MeshProto::Tcp,
                3088,
                false,
                0,
                BunkerState::Normal,
                now + 10,
            )
            .unwrap();
        assert!(cp_to_ashur.allowed);
        assert!(!cp_to_ashur.sovereign_violation_attempt);

        // 2. Lateral worker -> worker :3088 is strictly forbidden and raises sovereign_violation_attempt.
        let lateral = manifest
            .evaluate_route(
                "ashur",
                "babylon",
                MeshProto::Tcp,
                3088,
                true,
                now + 300,
                BunkerState::Normal,
                now + 10,
            )
            .unwrap();
        assert!(!lateral.allowed);
        assert!(lateral.sovereign_violation_attempt);

        // 3. RetiredFree / MissionSandbox -> SovereignVault (`dgx-spark`) is unconditionally blocked.
        let retired_to_vault = manifest
            .evaluate_route(
                "api-starknet-id",
                "dgx-spark",
                MeshProto::Tcp,
                8888,
                true,
                now + 300,
                BunkerState::Normal,
                now + 10,
            )
            .unwrap();
        assert!(!retired_to_vault.allowed);
        assert!(retired_to_vault.sovereign_violation_attempt);

        // 4. In HardLockdown, only OperatorAdmin (`macbook-air`) SSH :22 is allowed.
        let cp_in_lockdown = manifest
            .evaluate_route(
                "agent-core",
                "ashur",
                MeshProto::Tcp,
                3088,
                false,
                0,
                BunkerState::HardLockdown,
                now + 10,
            )
            .unwrap();
        assert!(!cp_in_lockdown.allowed);

        let admin_ssh_in_lockdown = manifest
            .evaluate_route(
                "macbook-air",
                "ashur",
                MeshProto::Tcp,
                22,
                false,
                0,
                BunkerState::HardLockdown,
                now + 10,
            )
            .unwrap();
        assert!(admin_ssh_in_lockdown.allowed);
        assert!(admin_ssh_in_lockdown.require_jit_audit_log);
    }

    #[test]
    fn replay_window_64_enforces_rfc6479_and_rejects_zero_and_max() {
        let mut win = ReplayWindow64::new();
        assert!(!win.check_and_advance(0));
        assert!(!win.check_and_advance(u64::MAX));
        assert!(win.check_and_advance(100));
        assert!(!win.check_and_advance(100)); // duplicate replay
        assert!(win.check_and_advance(105));
        assert!(!win.check_and_advance(105));
        assert!(win.check_and_advance(102)); // out-of-order within 64-slot window
        assert!(!win.check_and_advance(102)); // duplicate of out-of-order packet
        assert!(!win.check_and_advance(40)); // expired (105 - 40 = 65 >= 64)
        assert!(win.check_and_advance(250)); // large jump (> 64) resets bitmap cleanly
        assert_eq!(win.last_max_seq, 250);
        assert_eq!(win.bitmap, 1);
    }

    #[test]
    fn endpoint_roam_and_bunker_deadman_switch_behave_exact() {
        // Bogon/loopback IP (127.0.0.1) is rejected even with valid AEAD tag.
        assert!(!check_endpoint_roam(
            true,
            false,
            Ipv4Addr::new(127, 0, 0, 1),
            true,
            BunkerState::Normal,
            51888,
            10,
            11,
            1000,
            1005,
            2
        ));
        // Valid global unicast with newer pkt_seq is accepted.
        assert!(check_endpoint_roam(
            true,
            false,
            Ipv4Addr::new(95, 216, 173, 237),
            false,
            BunkerState::Normal,
            51888,
            10,
            11,
            1000,
            1005,
            2
        ));

        // Sovereign Dead-Man's Switch trips on dgx-spark when heartbeat age >= 180s.
        let b = step_bunker_isolate(
            BunkerState::Normal,
            true,
            false,
            false,
            0,
            false,
            true,
            1200,
            1000,
            180,
        );
        assert_eq!(b.next_state, BunkerState::SovereignDeadManTripped);
        assert!(b.revoke_jit_grants);
        assert!(b.prune_non_admin_wg_peers);
        assert!(b.lock_sovereign_vault);

        // Overlay subnet (10.88.0.0/16) and RFC 5737 documentation IPs cannot be roamed to.
        assert!(!check_endpoint_roam(
            true,
            false,
            Ipv4Addr::new(10, 88, 0, 11),
            true,
            BunkerState::Normal,
            51888,
            10,
            11,
            1000,
            1005,
            2
        ));
        assert!(!check_endpoint_roam(
            true,
            false,
            Ipv4Addr::new(192, 0, 2, 1),
            true,
            BunkerState::Normal,
            51888,
            10,
            11,
            1000,
            1005,
            2
        ));
    }

    #[test]
    fn single_peer_manifest_and_nft_wg_rendering_enforce_kernel_specs() {
        let sk = test_signing_key();
        let now = 1_760_000_000;
        let mut manifest = MeshManifest::paloma_fleet_default(now, &sk);

        // 1. Render nftables and WireGuard in HardLockdown: only `macbook-air` (OperatorAdmin) remains in WG,
        // and nftables includes `chain mesh_forward` drop + `meta nfproto ipv6 counter drop`.
        let wg_lockdown = manifest
            .render_wireguard_config("ashur", "<KEY>", BunkerState::HardLockdown, now + 10)
            .unwrap();
        assert!(wg_lockdown.contains("Peer: macbook-air"));
        assert!(!wg_lockdown.contains("Peer: agent-core"));
        assert!(!wg_lockdown.contains("Peer: babylon"));

        let nft_normal = manifest
            .render_nftables_policy("ashur", BunkerState::Normal, now + 10)
            .unwrap();
        assert!(nft_normal.contains("chain mesh_forward"));
        assert!(nft_normal.contains("meta nfproto ipv6 counter drop"));
        assert!(nft_normal.contains("ip saddr 10.88.0.1 ip daddr 10.88.0.11 tcp dport 3088 accept"));
        assert!(nft_normal.contains("ip saddr 10.88.0.100 ip daddr 10.88.0.11 tcp dport 22 accept"));

        let nft_lockdown = manifest
            .render_nftables_policy("ashur", BunkerState::HardLockdown, now + 10)
            .unwrap();
        assert!(!nft_lockdown.contains("tcp dport 3088 accept"));
        assert!(nft_lockdown.contains("ip saddr 10.88.0.100 ip daddr 10.88.0.11 tcp dport 22 accept"));

        // 2. Single-peer manifest with invalid /16 prefix or network IP 10.88.0.0 is rejected by unary `leanmesh_overlay_ip_step`.
        manifest.peers.truncate(1);
        manifest.peers[0].prefix_len = 16;
        manifest.epoch += 1;
        manifest.sign(&sk);
        assert!(manifest.verify_formal(1, 0, now + 10).is_err());
    }

    #[test]
    fn render_refuses_invalid_manifest_and_nftables_matches_eval_route() {
        let sk = test_signing_key();
        let now = 1_760_000_000;
        let manifest = MeshManifest::paloma_fleet_default(now, &sk);

        // 1. Forged signature or expired manifest is rejected by both `render_wireguard_config`
        // and `render_nftables_policy` (no "render-anyway").
        let mut forged = manifest.clone();
        forged.signature_hex = "00".repeat(64);
        assert!(forged
            .render_wireguard_config("ashur", "<KEY>", BunkerState::Normal, now + 10)
            .is_err());
        assert!(forged
            .render_nftables_policy("ashur", BunkerState::Normal, now + 10)
            .is_err());
        assert!(manifest
            .render_wireguard_config(
                "ashur",
                "<KEY>",
                BunkerState::Normal,
                manifest.expires_at + 1
            )
            .is_err());
        assert!(manifest
            .render_nftables_policy("ashur", BunkerState::Normal, manifest.expires_at + 1)
            .is_err());

        // 2. Bijective coherence between `render_nftables_policy` and `evaluate_route`
        // across every destination node and every source peer on key ports `[22, 3000, 3088, 8888]`.
        for dst in &manifest.peers {
            let nft = manifest
                .render_nftables_policy(&dst.name, BunkerState::Normal, now + 10)
                .unwrap();
            for src in &manifest.peers {
                if src.id == dst.id {
                    continue;
                }
                for port in [22u32, 3000, 3088, 8888] {
                    let decision = manifest
                        .evaluate_route(
                            &src.name,
                            &dst.name,
                            MeshProto::Tcp,
                            port,
                            false,
                            0,
                            BunkerState::Normal,
                            now + 10,
                        )
                        .unwrap();
                    let prefix = format!(
                        "ip saddr {} ip daddr {} tcp dport ",
                        src.overlay_ip, dst.overlay_ip
                    );
                    let emitted_in_nft = nft.lines().any(|line| {
                        let trimmed = line.trim();
                        if !trimmed.starts_with(&prefix) || !trimmed.contains(" accept") {
                            return false;
                        }
                        let rest = &trimmed[prefix.len()..];
                        let port_tok = rest.split_whitespace().next().unwrap_or("");
                        if let Some((lo, hi)) = port_tok.split_once('-') {
                            let lo_u = lo.parse::<u32>().unwrap_or(0);
                            let hi_u = hi.parse::<u32>().unwrap_or(0);
                            lo_u <= port && port <= hi_u
                        } else {
                            port_tok.parse::<u32>().ok() == Some(port)
                        }
                    });
                    assert_eq!(
                        decision.allowed, emitted_in_nft,
                        "mismatch between evaluate_route and render_nftables_policy for {} -> {}:{}",
                        src.name, dst.name, port
                    );
                }
            }
        }

        // 3. Authenticated heartbeat signature verification succeeds only for matching parameters
        // and is domain-separated from `sign_render_auth`.
        let peer_sk = default_peer_signing_key("dgx-spark");
        let pub_hex = hex::encode(peer_sk.verifying_key().to_bytes());
        let sig_hex = sign_heartbeat(&peer_sk, "dgx-spark", 1, now + 5);
        assert!(verify_heartbeat_signature(
            &pub_hex,
            "dgx-spark",
            1,
            now + 5,
            &sig_hex
        ));
        assert!(!verify_heartbeat_signature(
            &pub_hex,
            "dgx-spark",
            2,
            now + 5,
            &sig_hex
        ));
        assert!(!verify_heartbeat_signature(
            &pub_hex,
            "ashur",
            1,
            now + 5,
            &sig_hex
        ));
        let render_sig_hex = sign_render_auth(&peer_sk, "dgx-spark", 1, now + 5);
        assert!(verify_render_auth_signature(
            &pub_hex,
            "dgx-spark",
            1,
            now + 5,
            &render_sig_hex
        ));
        assert!(!verify_render_auth_signature(
            &pub_hex,
            "dgx-spark",
            1,
            now + 5,
            &sig_hex
        ));
        assert!(!verify_heartbeat_signature(
            &pub_hex,
            "dgx-spark",
            1,
            now + 5,
            &render_sig_hex
        ));

        // 4. Authenticated roam frame signature + bounds check.
        let mac_sk = default_peer_signing_key("macbook-air");
        let mac_pub_hex = hex::encode(mac_sk.verifying_key().to_bytes());
        let roam_sig = sign_roam(
            &mac_sk,
            "macbook-air",
            Ipv4Addr::new(95, 216, 173, 237),
            51888,
            10,
            now + 5,
        );
        assert!(verify_roam_signature(
            &mac_pub_hex,
            "macbook-air",
            Ipv4Addr::new(95, 216, 173, 237),
            51888,
            10,
            now + 5,
            &roam_sig
        ));
        assert!(!verify_roam_signature(
            &pub_hex,
            "macbook-air",
            Ipv4Addr::new(95, 216, 173, 237),
            51888,
            10,
            now + 5,
            &roam_sig
        ));
        assert!(!verify_roam_signature(
            &mac_pub_hex,
            "macbook-air",
            Ipv4Addr::new(95, 216, 173, 238),
            51888,
            10,
            now + 5,
            &roam_sig
        ));

        // 5. `reconcile_wireguard_dump` computes `NoopInSync`, `UpdateEndpoint`, `AddPeer`, and `RemovePeer`.
        let agent_core_peer = manifest.find_peer("agent-core").unwrap();
        let babylon_peer = manifest.find_peer("babylon").unwrap();
        let wg_dump = format!(
            "{}\t(none)\t95.216.173.237:51888\t10.88.0.1/32\t1760000000\t100\t200\t25\n\
             {}\t(none)\t1.2.3.4:51888\t10.88.0.12/32\t1760000000\t100\t200\t25\n\
             roguepubkey00000000000000000000000000000000=\t(none)\t9.9.9.9:51888\t10.88.0.99/32\t0\t0\t0\t25\n",
            agent_core_peer.wg_pubkey, babylon_peer.wg_pubkey
        );
        let plans = manifest
            .reconcile_wireguard_dump("ashur", &wg_dump, BunkerState::Normal, now + 10)
            .unwrap();
        let ac_plan = plans.iter().find(|p| p.peer_name == "agent-core").unwrap();
        assert_eq!(ac_plan.action, ReconcileAction::NoopInSync);
        let bab_plan = plans.iter().find(|p| p.peer_name == "babylon").unwrap();
        assert_eq!(bab_plan.action, ReconcileAction::UpdateEndpointOnly);
        let nip_plan = plans.iter().find(|p| p.peer_name == "nippur").unwrap();
        assert_eq!(nip_plan.action, ReconcileAction::AddPeer);
        let rogue_plan = plans
            .iter()
            .find(|p| p.peer_name == "<unlisted-kernel-peer>")
            .unwrap();
        assert_eq!(rogue_plan.action, ReconcileAction::RemovePeer);

        // 6. Source-wide audit: production `lib.rs` and `bin/lean-mesh.rs` contain zero deterministic seed fallbacks.
        let lib_src = include_str!("lib.rs")
            .split("#[cfg(test)]")
            .next()
            .unwrap();
        let bin_src = include_str!("bin/lean-mesh.rs");
        for forbidden in ["[0x42", "[0x99", "unwrap_or([", "derive_default_seed"] {
            assert!(
                !lib_src.contains(forbidden) && !bin_src.contains(forbidden),
                "production source must not contain forbidden fallback `{forbidden}`"
            );
        }
    }
}
