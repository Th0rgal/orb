/-
  OrbCore.MacTether: MacBook tether broker (`/api/mac-tether/*`, MCP tools `request_macbook_tether`,
  `list_macbook_tethers`, `revoke_macbook_tether`) and blind WireGuard UDP relay.
  - Core never holds coordinator seeds or WireGuard PSKs: the PSK is sealed end to end
    (`X25519 + ChaCha20-Poly1305`) between the laptop and the mission's `/dev/shm` directory.
  - Only the server owner's missions may request a tether, and every `/api/mac-tether/*` route is admin-only.
  - Lease tokens are returned only to the owning mission and are never logged.
  - Approval, overlay addresses and relayed frames go through `LeanMesh.Kernel.jitLeaseStep`,
    `overlayIpStep` and `frameBoundsStep`.
  - The relay is off unless `ORB_WG_RELAY_PUBLIC_ENDPOINT` is set, so two Cores on one host never share the port.
-/
import Std.Sync.Mutex
import LeanSys
import LeanMesh.Kernel
import OrbBin.Json
import OrbBin.PosixExt
import OrbNetLeaf.Crypto
import OrbCore.Store

namespace OrbCore.MacTether

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store

/-- Maximum tether lease TTL (`4 hours = 14400 s`), matching `LeanMesh.Kernel.jitLeaseStep` ceiling. -/
def maxTetherTtlSecs : UInt64 := 14400

/-- Pending approval request expiry (`15 minutes = 900 s`). -/
def pendingRequestTtlSecs : UInt64 := 900

/-- Default UDP listen port for the blind WireGuard relay on `orb-core`. -/
def defaultWgRelayPort : UInt16 := 51890

structure MacTetherRequestRecord where
  id                  : String
  missionId           : String
  requesterLabel      : String
  hostId              : String
  isManagedVm         : Bool
  requestedScope      : String
  effectiveScope      : String
  effectiveTarget     : String
  agentPorts          : Array Nat
  macPorts            : Array Nat
  ttlMinutes          : Nat
  sessionScoped       : Bool
  reason              : String
  agentWgPubkey       : String
  agentKemPubkey      : String
  agentSignPubkeyHex  : String
  agentSshPubkey      : String
  agentDirectEndpoint : String
  macWgPubkey         : String
  macKemPubkey        : String
  macDirectEndpoint   : String
  relayEndpoint       : String
  sealedPskB64        : String
  overlayIp           : String
  leaseToken          : String
  state               : String
  denyReason          : String
  createdAt           : UInt64
  updatedAt           : UInt64
  expiresAt           : UInt64
  revokedAt           : UInt64
  deriving Repr, BEq

structure WgRelayPairRecord where
  pairId        : String
  label         : String
  peerAWgPubkey : String
  peerBWgPubkey : String
  enabled       : Bool
  createdAt     : UInt64
  updatedAt     : UInt64
  deriving Repr, BEq

def isValidTetherScope (s : String) : Bool :=
  s == "preview" || s == "sandbox_ssh" || s == "host_ssh"

def isValidTetherTarget (s : String) : Bool :=
  s == "sandbox" || s == "thomas"

def decodeWgPub32? (b64 : String) : Option ByteArray := do
  let raw ← base64Decode? b64.trimAscii.toString
  if raw.size == 32 then some raw else none

def parsePortsJson (raw : String) : Array Nat :=
  match OrbBin.Json.parse raw with
  | .ok (.arr xs) =>
    xs.filterMap (fun v => v.asNat?.filter (fun p => 1 ≤ p && p ≤ 65535))
  | _ => #[]

def validateUserPortList (xs : Array JVal) : Except String (Array Nat) := Id.run do
  if xs.size > 16 then
    return .error "At most 16 forwarded ports may be requested per tether"
  let mut out : Array Nat := #[]
  for item in xs do
    let some p := item.asNat?
      | return .error "Port entries must be integers"
    if p < 1024 || p > 65535 then
      return .error s!"Port {p} is outside unprivileged range 1024..65535"
    if !out.contains p then
      out := out.push p
  return .ok out

def encodePortsJson (ps : Array Nat) : String :=
  "[" ++ String.intercalate "," (ps.toList.map toString) ++ "]"

def renderMacTetherRequestJson (r : MacTetherRequestRecord) (includeLeaseToken : Bool := false) : JVal :=
  let base : Array (String × JVal) := #[
    ("id", .str r.id),
    ("mission_id", if r.missionId.isEmpty then .null else .str r.missionId),
    ("requester_label", .str r.requesterLabel),
    ("host_id", .str r.hostId),
    ("is_managed_vm", .bool r.isManagedVm),
    ("requested_scope", .str r.requestedScope),
    ("effective_scope", if r.effectiveScope.isEmpty then .null else .str r.effectiveScope),
    ("effective_target", .str r.effectiveTarget),
    ("agent_ports", .arr (r.agentPorts.map JVal.nat)),
    ("mac_ports", .arr (r.macPorts.map JVal.nat)),
    ("ttl_minutes", .nat r.ttlMinutes),
    ("session_scoped", .bool r.sessionScoped),
    ("reason", .str r.reason),
    ("agent_wg_pubkey", .str r.agentWgPubkey),
    ("agent_kem_pubkey", if r.agentKemPubkey.isEmpty then .null else .str r.agentKemPubkey),
    ("agent_sign_pubkey_hex", if r.agentSignPubkeyHex.isEmpty then .null else .str r.agentSignPubkeyHex),
    ("agent_ssh_pubkey", if r.agentSshPubkey.isEmpty then .null else .str r.agentSshPubkey),
    ("agent_direct_endpoint", if r.agentDirectEndpoint.isEmpty then .null else .str r.agentDirectEndpoint),
    ("mac_wg_pubkey", if r.macWgPubkey.isEmpty then .null else .str r.macWgPubkey),
    ("mac_kem_pubkey", if r.macKemPubkey.isEmpty then .null else .str r.macKemPubkey),
    ("mac_direct_endpoint", if r.macDirectEndpoint.isEmpty then .null else .str r.macDirectEndpoint),
    ("relay_endpoint", if r.relayEndpoint.isEmpty then .null else .str r.relayEndpoint),
    ("sealed_psk_b64", if r.sealedPskB64.isEmpty then .null else .str r.sealedPskB64),
    ("overlay_ip", if r.overlayIp.isEmpty then .null else .str r.overlayIp),
    ("mac_overlay_ip", .str "10.88.200.1"),
    ("mac_ssh_port", .nat 2224),
    ("state", .str r.state),
    ("deny_reason", if r.denyReason.isEmpty then .null else .str r.denyReason),
    ("created_at", .nat r.createdAt.toNat),
    ("updated_at", .nat r.updatedAt.toNat),
    ("expires_at", if r.expiresAt > 0 then .nat r.expiresAt.toNat else .null),
    ("revoked_at", if r.revokedAt > 0 then .nat r.revokedAt.toNat else .null)
  ]
  let fields :=
    if includeLeaseToken && !r.leaseToken.isEmpty then
      base.push ("lease_token", .str r.leaseToken)
    else
      base
  JVal.obj fields

def renderWgRelayPairJson (p : WgRelayPairRecord) : JVal :=
  JVal.obj #[
    ("pair_id", .str p.pairId),
    ("label", .str p.label),
    ("peer_a_wg_pubkey", .str p.peerAWgPubkey),
    ("peer_b_wg_pubkey", .str p.peerBWgPubkey),
    ("enabled", .bool p.enabled),
    ("created_at", .nat p.createdAt.toNat),
    ("updated_at", .nat p.updatedAt.toNat)
  ]

/-! ### Blind WireGuard UDP Relay (`:51890`) -/

structure UdpEndpoint where
  ipHostOrder : UInt32
  port        : UInt16
  deriving Repr, BEq, DecidableEq

structure RelayPairSlot where
  slotId     : String
  peerAPub32 : ByteArray
  peerBPub32 : ByteArray
  expiresAt  : UInt64 := 0  -- `0` = standing pair (`homemesh-umbrel`)
  deriving BEq

structure PendingWgHandshake where
  senderIdx      : UInt32
  slotId         : String
  initiatorPub32 : ByteArray
  srcEp          : UdpEndpoint
  rxSec          : UInt64
  deriving BEq

structure WgSessionRoute where
  receiverIdx : UInt32
  slotId      : String
  dstPub32    : ByteArray
  dstEp       : UdpEndpoint
  expiresAt   : UInt64
  lastSeenSec : UInt64
  deriving BEq

structure RelayForwardState where
  establishedEp : Array (ByteArray × UdpEndpoint × UInt64) := #[]
  candidateEp   : Array (ByteArray × UdpEndpoint × UInt64) := #[]
  pendingInit   : Array PendingWgHandshake := #[]
  sessions      : Array WgSessionRoute := #[]

structure MacTetherRuntime where
  gen            : Std.Mutex UInt64
  stoppedRef     : IO.Ref Bool
  relayEndpoint  : String
  relayPort      : UInt16
  relayFd?       : Option Int32
  slotsMu        : Std.Mutex (Array RelayPairSlot)
  fwdMu          : Std.Mutex RelayForwardState

private def readU32LEAt (b : ByteArray) (off : Nat) : UInt32 :=
  if off + 4 > b.size then 0
  else
    (b.get! off).toUInt32 |||
    ((b.get! (off + 1)).toUInt32 <<< 8) |||
    ((b.get! (off + 2)).toUInt32 <<< 16) |||
    ((b.get! (off + 3)).toUInt32 <<< 24)

private def upsertEndpointMap
    (xs : Array (ByteArray × UdpEndpoint × UInt64))
    (pub32 : ByteArray) (ep : UdpEndpoint) (ts : UInt64) : Array (ByteArray × UdpEndpoint × UInt64) := Id.run do
  let mut found := false
  let mut out : Array (ByteArray × UdpEndpoint × UInt64) := Array.mkEmpty (xs.size + 1)
  for (k, v, t) in xs do
    if k == pub32 then
      out := out.push (pub32, ep, ts)
      found := true
    else
      out := out.push (k, v, t)
  if !found then
    if out.size ≥ 256 then
      out := out.extract 1 out.size
    out := out.push (pub32, ep, ts)
  return out

private def lookupEndpoint?
    (xs : Array (ByteArray × UdpEndpoint × UInt64))
    (pub32 : ByteArray) : Option (UdpEndpoint × UInt64) :=
  (xs.find? (fun (k, _, _) => k == pub32)).map (fun (_, ep, ts) => (ep, ts))

/-- Evaluate one inbound WireGuard UDP datagram against active relay pair slots and return `(dstEndpoint, bytes)` forwards.
    Never decrypts WireGuard payloads and never promotes an endpoint without a Noise_IK + PSK Type 2 response. -/
def stepBlindRelayDatagram
    (slots : Array RelayPairSlot)
    (fwdMu : Std.Mutex RelayForwardState)
    (pkt : UdpPacket)
    (nowSec : UInt64) : IO (Array UdpEndpoint) := do
  let pay := pkt.payload
  if pay.size < 32 || pay.size > 1500 then
    return #[]
  let msgType := pay.get! 0
  if (pay.get! 1) != 0 || (pay.get! 2) != 0 || (pay.get! 3) != 0 then
    return #[]
  if msgType < 1 || msgType > 4 then
    return #[]
  let activeSlots := slots.filter (fun s => s.expiresAt == 0 || nowSec < s.expiresAt)
  if activeSlots.isEmpty then
    return #[]
  let srcEp : UdpEndpoint := { ipHostOrder := pkt.srcIpHostOrder, port := pkt.srcPort }

  -- Type 1: Handshake Initiation (`148` bytes; `mac1` at `116..132` over `pay[0..116]`)
  if msgType == 1 then
    if pay.size != 148 then return #[]
    let prefix116 := pay.extract 0 116
    let pktMac1 := pay.extract 116 132
    let senderIdx := readU32LEAt pay 4
    let mut matched : Array (RelayPairSlot × ByteArray × ByteArray) := #[]
    for sl in activeSlots do
      let macB ← wgMac1 sl.peerBPub32 prefix116
      if macB == pktMac1 then
        matched := matched.push (sl, sl.peerAPub32, sl.peerBPub32)
      else
        let macA ← wgMac1 sl.peerAPub32 prefix116
        if macA == pktMac1 then
          matched := matched.push (sl, sl.peerBPub32, sl.peerAPub32)
    if matched.isEmpty then
      return #[]
    if LeanMesh.Kernel.frameBoundsStep 0x4C4D5348 1 1 1 32 116 1500 2048 != 1 then
      return #[]
    return ← fwdMu.atomically do
      let st ← get
      let mut cand := st.candidateEp
      let mut pend := st.pendingInit.filter (fun p => nowSec ≤ p.rxSec + 20)
      let mut dsts : Array UdpEndpoint := #[]
      for (sl, initPub, respPub) in matched do
        cand := upsertEndpointMap cand initPub srcEp nowSec
        pend := pend.filter (fun p => !(p.senderIdx == senderIdx && p.slotId == sl.slotId))
        if pend.size ≥ 128 then
          pend := pend.extract 1 pend.size
        pend := pend.push {
          senderIdx      := senderIdx
          slotId         := sl.slotId
          initiatorPub32 := initPub
          srcEp          := srcEp
          rxSec          := nowSec
        }
        match lookupEndpoint? st.establishedEp respPub with
        | some (estEp, lastVer) =>
          if estEp != srcEp && !dsts.contains estEp then
            dsts := dsts.push estEp
          if nowSec > lastVer + 20 then
            if let some (candEp, _) := lookupEndpoint? cand respPub then
              if candEp != srcEp && !dsts.contains candEp then
                dsts := dsts.push candEp
        | none =>
          if let some (candEp, _) := lookupEndpoint? cand respPub then
            if candEp != srcEp && !dsts.contains candEp then
              dsts := dsts.push candEp
      set { st with candidateEp := cand, pendingInit := pend }
      return dsts

  -- Type 2: Handshake Response (`92` bytes; `sender_index` at `4..8`, `receiver_index` at `8..12`, `mac1` at `60..76`)
  if msgType == 2 then
    if pay.size != 92 then return #[]
    let senderIdx := readU32LEAt pay 4
    let receiverIdx := readU32LEAt pay 8
    let prefix60 := pay.extract 0 60
    let pktMac1 := pay.extract 60 76
    let candInit? ← fwdMu.atomically do
      let st ← get
      return st.pendingInit.find? (fun p => p.senderIdx == receiverIdx && nowSec ≤ p.rxSec + 20)
    let some initRec := candInit? | return #[]
    let some sl := activeSlots.find? (fun s => s.slotId == initRec.slotId) | return #[]
    let expMac1 ← wgMac1 initRec.initiatorPub32 prefix60
    if expMac1 != pktMac1 then
      return #[]
    if LeanMesh.Kernel.frameBoundsStep 0x4C4D5348 1 2 1 32 60 1500 2048 != 1 then
      return #[]
    let respPub := if sl.peerAPub32 == initRec.initiatorPub32 then sl.peerBPub32 else sl.peerAPub32
    return ← fwdMu.atomically do
      let st ← get
      let est1 := upsertEndpointMap st.establishedEp initRec.initiatorPub32 initRec.srcEp nowSec
      let est2 := upsertEndpointMap est1 respPub srcEp nowSec
      let pend := st.pendingInit.filter (fun p => !(p.senderIdx == receiverIdx && p.slotId == sl.slotId))
      let mut sess := st.sessions.filter (fun r =>
        (r.expiresAt == 0 || nowSec < r.expiresAt) && nowSec ≤ r.lastSeenSec + 240 &&
        r.receiverIdx != senderIdx && r.receiverIdx != receiverIdx)
      if sess.size + 2 > 512 then
        sess := sess.extract 2 sess.size
      -- Packets addressed to `receiver_index = senderIdx` go to responder (`srcEp`);
      -- packets addressed to `receiver_index = receiverIdx` go to initiator (`initRec.srcEp`).
      sess := sess.push {
        receiverIdx := senderIdx
        slotId      := sl.slotId
        dstPub32    := respPub
        dstEp       := srcEp
        expiresAt   := sl.expiresAt
        lastSeenSec := nowSec
      }
      sess := sess.push {
        receiverIdx := receiverIdx
        slotId      := sl.slotId
        dstPub32    := initRec.initiatorPub32
        dstEp       := initRec.srcEp
        expiresAt   := sl.expiresAt
        lastSeenSec := nowSec
      }
      set { st with establishedEp := est2, pendingInit := pend, sessions := sess }
      return if initRec.srcEp != srcEp then #[initRec.srcEp] else #[]

  -- Type 3 (`64` bytes Cookie Reply) or Type 4 (`≥ 32` bytes Transport Data): `receiver_index` at `4..8`
  if msgType == 3 && pay.size != 64 then
    return #[]
  let receiverIdx := readU32LEAt pay 4
  let activeSlotIds := activeSlots.map (·.slotId)
  if LeanMesh.Kernel.frameBoundsStep 0x4C4D5348 1 msgType 1 32 (pay.size - 32).toUInt64 1500 2048 != 1 then
    return #[]
  fwdMu.atomically do
    let st ← get
    let mut updated : Array WgSessionRoute := Array.mkEmpty st.sessions.size
    let mut dst? : Option UdpEndpoint := none
    for r in st.sessions do
      let slotAlive := activeSlotIds.contains r.slotId && (r.expiresAt == 0 || nowSec < r.expiresAt)
      if slotAlive && nowSec ≤ r.lastSeenSec + 240 then
        if r.receiverIdx == receiverIdx then
          dst? := some r.dstEp
          updated := updated.push { r with lastSeenSec := nowSec }
        else
          updated := updated.push r
    set { st with sessions := updated }
    match dst? with
    | some ep => return if ep != srcEp then #[ep] else #[]
    | none => return #[]

/-! ### SQLite Persistence & Relay Slot Synchronization -/

private def queryMissionsDb (st : CoreStore) (sql : String) (params : Array String := #[]) : IO (Except String (Array (Array String))) :=
  execParamQuery st.missionsDb sql params

private def bumpTetherGen (rt? : Option MacTetherRuntime) : IO UInt64 := do
  match rt? with
  | none => return 0
  | some rt =>
    rt.gen.atomically do
      let g ← get
      let next := g + 1
      set next
      return next

/-- Wait until `rt.gen` advances past `seenGen` or `maxWaitMs` elapses. -/
def waitForMacTetherGen (rt : MacTetherRuntime) (seenGen : UInt64) (maxWaitMs : UInt32 := 20000) : IO UInt64 := do
  let cur0 ← rt.gen.atomically get
  if cur0 != seenGen || maxWaitMs == 0 then
    return cur0
  let clamped := Nat.min maxWaitMs.toNat 25000
  let mut waited : Nat := 0
  while waited < clamped do
    IO.sleep 50
    waited := waited + 50
    let cur ← rt.gen.atomically get
    if cur != seenGen then
      return cur
  rt.gen.atomically get

private def rowToMacTetherRecord (r : Array String) : MacTetherRequestRecord := {
  id                  := (r[0]?).getD ""
  missionId           := (r[1]?).getD ""
  requesterLabel      := (r[2]?).getD ""
  hostId              := (r[3]?).getD ""
  isManagedVm         := (((r[4]?).bind String.toNat?).getD 0) != 0
  requestedScope      := (r[5]?).getD "sandbox_ssh"
  effectiveScope      := (r[6]?).getD ""
  effectiveTarget     := (r[7]?).getD "sandbox"
  agentPorts          := parsePortsJson ((r[8]?).getD "[]")
  macPorts            := parsePortsJson ((r[9]?).getD "[]")
  ttlMinutes          := ((r[10]?).bind String.toNat?).getD 60
  sessionScoped       := (((r[11]?).bind String.toNat?).getD 0) != 0
  reason              := (r[12]?).getD ""
  agentWgPubkey       := (r[13]?).getD ""
  agentKemPubkey      := (r[14]?).getD ""
  agentSignPubkeyHex  := (r[15]?).getD ""
  agentSshPubkey      := (r[16]?).getD ""
  agentDirectEndpoint := (r[17]?).getD ""
  macWgPubkey         := (r[18]?).getD ""
  macKemPubkey        := (r[19]?).getD ""
  macDirectEndpoint   := (r[20]?).getD ""
  relayEndpoint       := (r[21]?).getD ""
  sealedPskB64        := (r[22]?).getD ""
  overlayIp           := (r[23]?).getD ""
  leaseToken          := (r[24]?).getD ""
  state               := (r[25]?).getD "pending"
  denyReason          := (r[26]?).getD ""
  createdAt           := (((r[27]?).bind String.toNat?).getD 0).toUInt64
  updatedAt           := (((r[28]?).bind String.toNat?).getD 0).toUInt64
  expiresAt           := (((r[29]?).bind String.toNat?).getD 0).toUInt64
  revokedAt           := (((r[30]?).bind String.toNat?).getD 0).toUInt64
}

private def macTetherSelectCols : String :=
  "id,mission_id,requester_label,host_id,is_managed_vm,requested_scope,effective_scope,effective_target," ++
  "agent_ports_json,mac_ports_json,ttl_minutes,session_scoped,reason,agent_wg_pubkey,agent_kem_pubkey," ++
  "agent_sign_pubkey_hex,agent_ssh_pubkey,agent_direct_endpoint,mac_wg_pubkey,mac_kem_pubkey," ++
  "mac_direct_endpoint,relay_endpoint,sealed_psk_b64,overlay_ip,lease_token,state,deny_reason," ++
  "created_at,updated_at,expires_at,revoked_at"

/-- Transition expired `pending` and `approved` tether leases in SQLite and return `true` if any row changed. -/
def expireStaleMacTethers (st : CoreStore) (nowSec : UInt64) : IO Bool := do
  let pendCutoff := if nowSec > pendingRequestTtlSecs then nowSec - pendingRequestTtlSecs else 0
  let chk ← queryMissionsDb st
    ("SELECT id FROM mac_tether_requests WHERE " ++
     "(state='pending' AND created_at > 0 AND created_at <= ?1) OR " ++
     "(state='approved' AND expires_at > 0 AND expires_at <= ?2) LIMIT 1;")
    #[toString pendCutoff, toString nowSec]
  let anyStale := match chk with | .ok rs => rs.size > 1 | .error _ => false
  if !anyStale then
    return false
  let _ ← queryMissionsDb st
    ("UPDATE mac_tether_requests SET state='expired', updated_at=?3 " ++
     "WHERE (state='pending' AND created_at > 0 AND created_at <= ?1) OR " ++
     "(state='approved' AND expires_at > 0 AND expires_at <= ?2);")
    #[toString pendCutoff, toString nowSec, toString nowSec]
  return true

/-- Synchronize active `wg_relay_pairs` + active `approved` `mac_tether_requests` into the live UDP relay table. -/
def syncMacTetherRelaySlots (st : CoreStore) (rt? : Option MacTetherRuntime) (nowSec : UInt64) : IO Unit := do
  let some rt := rt? | return
  let _ ← expireStaleMacTethers st nowSec
  let mut nextSlots : Array RelayPairSlot := #[]
  if let .ok prs ← queryMissionsDb st
      "SELECT pair_id, peer_a_wg_pubkey, peer_b_wg_pubkey FROM wg_relay_pairs WHERE enabled=1;" #[] then
    for i in [1:prs.size] do
      let r := prs[i]!
      let pid := (r[0]?).getD ""
      if let (some pa, some pb) := (decodeWgPub32? ((r[1]?).getD ""), decodeWgPub32? ((r[2]?).getD "")) then
        if pa != pb then
          nextSlots := nextSlots.push { slotId := s!"pair:{pid}", peerAPub32 := pa, peerBPub32 := pb, expiresAt := 0 }
  if let .ok trs ← queryMissionsDb st
      ("SELECT id, mac_wg_pubkey, agent_wg_pubkey, expires_at FROM mac_tether_requests " ++
       "WHERE state='approved' AND revoked_at=0 AND expires_at>?1;")
      #[toString nowSec] then
    for i in [1:trs.size] do
      let r := trs[i]!
      let tid := (r[0]?).getD ""
      let exp := (((r[3]?).bind String.toNat?).getD 0).toUInt64
      if let (some pm, some pa) := (decodeWgPub32? ((r[1]?).getD ""), decodeWgPub32? ((r[2]?).getD "")) then
        if pm != pa then
          nextSlots := nextSlots.push { slotId := s!"tether:{tid}", peerAPub32 := pm, peerBPub32 := pa, expiresAt := exp }
  rt.slotsMu.atomically (set nextSlots)

/-- Start the tether runtime. The blind WireGuard UDP relay listens only when
    `ORB_WG_RELAY_PUBLIC_ENDPOINT` (`host:port`, the address peers are told to use) is set; it then binds
    `ORB_WG_RELAY_BIND` (default `0.0.0.0`) on `ORB_WG_RELAY_PORT` (default `51890`, `0` = ephemeral).
    Unset means no socket and no advertised relay endpoint. -/
def startMacTetherRuntime (st : CoreStore) : IO MacTetherRuntime := do
  let gen ← Std.Mutex.new (1 : UInt64)
  let stoppedRef ← IO.mkRef false
  let slotsMu ← Std.Mutex.new #[]
  let fwdMu ← Std.Mutex.new ({} : RelayForwardState)
  let relay : Option Int32 × UInt16 × String ←
    match ← getEnvNonEmpty "ORB_WG_RELAY_PUBLIC_ENDPOINT" with
    | none => pure (none, 0, "")
    | some advertised =>
      let reqPort : UInt16 :=
        ((((← getEnvNonEmpty "ORB_WG_RELAY_PORT").bind String.toNat?).filter (· ≤ 65535)).getD
          defaultWgRelayPort.toNat).toUInt16
      let bindHost := (← getEnvNonEmpty "ORB_WG_RELAY_BIND").getD "0.0.0.0"
      match ← udpBind bindHost reqPort with
      | .ok (fd, boundPort) =>
        IO.eprintln s!"[sandboxed-sh] blind WireGuard UDP relay listening on {bindHost}:{boundPort} (advertised={advertised})"
        pure (some fd, boundPort, advertised)
      | .error err =>
        IO.eprintln s!"[sandboxed-sh] WARN: blind WireGuard UDP relay bind on {bindHost}:{reqPort} failed ({err}); relay disabled"
        pure (none, 0, "")
  let (fd?, actualPort, relayEndpoint) := relay
  let rt : MacTetherRuntime := {
    gen, stoppedRef, relayEndpoint, relayPort := actualPort, relayFd? := fd?, slotsMu, fwdMu
  }
  syncMacTetherRelaySlots st (some rt) (← coreEpochSec)
  if let some fd := fd? then
    let _ ← IO.asTask (prio := .dedicated) do
      while !(← rt.stoppedRef.get) do
        if let some pkt ← udpRecvFromPoll fd 250 2048 then
          let nowSec ← coreEpochSec
          let slots ← rt.slotsMu.atomically get
          let dsts ← stepBlindRelayDatagram slots rt.fwdMu pkt nowSec
          for dst in dsts do
            let _ ← udpSendTo fd dst.ipHostOrder dst.port pkt.payload
      -- The loop owns the socket: closing it elsewhere could hand a reused descriptor to `recvfrom`.
      closeFdRaw fd
  return rt

/-- Ask the relay loop to stop; it closes its own socket within one poll interval. -/
def stopMacTetherRuntime (rt : MacTetherRuntime) : IO Unit :=
  rt.stoppedRef.set true

def getMacTetherRequest? (st : CoreStore) (reqId : String) (nowSec : UInt64) : IO (Option MacTetherRequestRecord) := do
  let _ ← expireStaleMacTethers st nowSec
  match ← queryMissionsDb st
      s!"SELECT {macTetherSelectCols} FROM mac_tether_requests WHERE id=?1;" #[reqId] with
  | .ok rs =>
    if rs.size ≤ 1 then return none
    return some (rowToMacTetherRecord rs[1]!)
  | .error _ => return none

def listMacTetherRequests
    (st : CoreStore)
    (missionId? : Option String := none)
    (state? : Option String := none)
    (nowSec : UInt64) : IO (Array MacTetherRequestRecord) := do
  let _ ← expireStaleMacTethers st nowSec
  let (whereSql, params) : String × Array String :=
    match missionId?, state? with
    | some mid, some stVal => ("WHERE mission_id=?1 AND state=?2", #[mid, stVal])
    | some mid, none       => ("WHERE mission_id=?1", #[mid])
    | none, some stVal     => ("WHERE state=?1", #[stVal])
    | none, none           => ("", #[])
  match ← queryMissionsDb st
      s!"SELECT {macTetherSelectCols} FROM mac_tether_requests {whereSql} ORDER BY created_at DESC LIMIT 100;"
      params with
  | .error _ => return #[]
  | .ok rs =>
    let mut out : Array MacTetherRequestRecord := Array.mkEmpty (rs.size - 1)
    for i in [1:rs.size] do
      out := out.push (rowToMacTetherRecord rs[i]!)
    return out

/-- Allocate the lowest unused `10.88.200.X` (`10 ≤ X ≤ 250`) verified by `LeanMesh.Kernel.overlayIpStep`. -/
def allocateMacMeshOverlayIp? (st : CoreStore) (nowSec : UInt64) : IO (Option String) := do
  let active ← listMacTetherRequests st none (some "approved") nowSec
  let usedIps := active.map (·.overlayIp)
  let macHubIp : UInt32 := 0x0A58C801 -- 10.88.200.1
  for hostOctet in [10:251] do
    let candIpU32 : UInt32 := 0x0A58C800 ||| hostOctet.toUInt32
    let candStr := formatIpv4U32 candIpU32
    if !usedIps.contains candStr then
      if LeanMesh.Kernel.overlayIpStep 1 hostOctet.toUInt32 macHubIp candIpU32 32 32 == 1 then
        return some candStr
  return none

/-- Only the server owner's missions may ask for the laptop: the mission must exist and be owned by an enabled
    administrator (an empty owner is pre-multi-user operator data, which no member can own).
    An empty `missionId` is the administrator acting directly (callers authenticate that). -/
def missionMayRequestMacTether (st : CoreStore) (missionId : String) : IO Bool := do
  if missionId.isEmpty then return true
  let some m ← getMission? st missionId | return false
  if m.ownerUserId.isEmpty then return true
  return ((← getUserById? st m.ownerUserId).map (fun u => !u.disabled && u.role == "admin")).getD false

def createMacTetherRequest
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (bunkerState : UInt8)
    (missionId requesterLabel hostId : String)
    (isManagedVm : Bool)
    (body : JVal)
    (nowSec : UInt64) : IO (Except String MacTetherRequestRecord) := do
  if bunkerState != 0 then
    return .error "Bunker mode is active; MacBook tether requests are denied"
  if !(← missionMayRequestMacTether st missionId) then
    return .error "MacBook tether requests are limited to the server owner's missions"
  let reqScope := ((body.fieldStr? "scope").orElse (fun _ => body.fieldStr? "requested_scope")).getD "sandbox_ssh"
  if !isValidTetherScope reqScope then
    return .error s!"Invalid tether scope `{reqScope}` (expected preview, sandbox_ssh, or host_ssh)"
  let reason := ((body.fieldStr? "reason").getD "").trimAscii.toString
  if reason.isEmpty || reason.length > 500 then
    return .error "Tether `reason` is required (1..500 chars)"
  let agentPorts ← match validateUserPortList ((body.fieldArr? "agent_ports").getD #[]) with
    | .ok ps => pure ps
    | .error e => return .error e
  let macPorts ← match validateUserPortList ((body.fieldArr? "mac_ports").getD #[]) with
    | .ok ps => pure ps
    | .error e => return .error e
  if reqScope == "preview" && agentPorts.isEmpty && macPorts.isEmpty then
    return .error "Preview scope requires at least one port in `agent_ports` or `mac_ports`"
  let ttlMinutes := (body.fieldNat? "ttl_minutes").getD 60
  if ttlMinutes < 1 || ttlMinutes > 240 then
    return .error "ttl_minutes must be between 1 and 240"
  let sessionScoped := (body.fieldBool? "session_scoped").getD true
  let wgPub := ((body.fieldStr? "agent_wg_pubkey").getD "").trimAscii.toString
  if (decodeWgPub32? wgPub).isNone then
    return .error "Valid 32-byte Base64 `agent_wg_pubkey` is required"
  let kemPub := ((body.fieldStr? "agent_kem_pubkey").getD "").trimAscii.toString
  if !kemPub.isEmpty && (decodeWgPub32? kemPub).isNone then
    return .error "Invalid `agent_kem_pubkey` (expected 32-byte Base64 X25519 key)"
  let sshPub := ((body.fieldStr? "agent_ssh_pubkey").getD "").trimAscii.toString
  if (reqScope == "sandbox_ssh" || reqScope == "host_ssh") && !sshPub.startsWith "ssh-ed25519 " then
    return .error "SSH tether scopes require an `ssh-ed25519` public key in `agent_ssh_pubkey`"
  let signHex := ((body.fieldStr? "agent_sign_pubkey_hex").getD "").trimAscii.toString
  let directEp := ((body.fieldStr? "agent_direct_endpoint").getD "").trimAscii.toString
  let reqId ← newUuidV4
  let defTarget := if reqScope == "host_ssh" then "thomas" else "sandbox"
  let relayEp := match rt? with | some rt => rt.relayEndpoint | none => ""
  let ins ← queryMissionsDb st
    ("INSERT INTO mac_tether_requests(" ++
     "id,mission_id,requester_label,host_id,is_managed_vm,requested_scope,effective_scope,effective_target," ++
     "agent_ports_json,mac_ports_json,ttl_minutes,session_scoped,reason,agent_wg_pubkey,agent_kem_pubkey," ++
     "agent_sign_pubkey_hex,agent_ssh_pubkey,agent_direct_endpoint,relay_endpoint,state,created_at,updated_at" ++
     ") VALUES(?1,?2,?3,?4,?5,?6,'',?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,'pending',?19,?19);")
    #[
      reqId, missionId, requesterLabel, hostId, if isManagedVm then "1" else "0",
      reqScope, defTarget, encodePortsJson agentPorts, encodePortsJson macPorts,
      toString ttlMinutes, if sessionScoped then "1" else "0", reason,
      wgPub, kemPub, signHex, sshPub, directEp, relayEp, toString nowSec
    ]
  if let .error e := ins then
    return .error s!"Failed persisting tether request: {e}"
  let _ ← bumpTetherGen rt?
  match ← getMacTetherRequest? st reqId nowSec with
  | some r => return .ok r
  | none => return .error "Persisted tether request not found"

def approveMacTetherRequest
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (bunkerState : UInt8)
    (reqId : String)
    (body : JVal)
    (nowSec : UInt64) : IO (Except String MacTetherRequestRecord) := do
  let some cur ← getMacTetherRequest? st reqId nowSec
    | return .error "not_found"
  if cur.state != "pending" then
    return .error s!"Request is already in `{cur.state}` state"
  let bioOk : UInt8 := if (body.fieldBool? "biometric_verified") == some true then 1 else 0
  let effScope := ((body.fieldStr? "effective_scope").filter (!·.isEmpty)).getD cur.requestedScope
  if !isValidTetherScope effScope then
    return .error s!"Invalid effective_scope `{effScope}`"
  let effTarget :=
    let rawT := ((body.fieldStr? "effective_target").filter (!·.isEmpty)).getD
      (if effScope == "host_ssh" then "thomas" else "sandbox")
    if effScope == "preview" then "sandbox" else rawT
  if !isValidTetherTarget effTarget then
    return .error s!"Invalid effective_target `{effTarget}`"
  let ttlMins := (body.fieldNat? "ttl_minutes").getD cur.ttlMinutes
  if ttlMins < 1 || ttlMins > 240 then
    return .error "ttl_minutes must be between 1 and 240"
  let sessScoped := (body.fieldBool? "session_scoped").getD cur.sessionScoped
  let expiresAt := nowSec + (ttlMins * 60).toUInt64
  -- Formal kernel gate (`LeanMesh.Kernel.jitLeaseStep`: MissionSandbox=0 -> ReservedProd=3, maxJitTtlSecs=14400)
  let jitVerdict :=
    LeanMesh.Kernel.jitLeaseStep bioOk 1 1 0 bunkerState 0 3 nowSec nowSec expiresAt maxTetherTtlSecs
  if jitVerdict != 1 then
    return .error s!"Biometric JIT lease gate rejected approval (verdict={jitVerdict}, bunker={bunkerState})"
  let macWgPub := ((body.fieldStr? "mac_wg_pubkey").getD "").trimAscii.toString
  if (decodeWgPub32? macWgPub).isNone then
    return .error "Valid 32-byte Base64 `mac_wg_pubkey` is required on approval"
  let macKemPub := ((body.fieldStr? "mac_kem_pubkey").getD "").trimAscii.toString
  if !cur.agentKemPubkey.isEmpty && (decodeWgPub32? macKemPub).isNone then
    return .error "`mac_kem_pubkey` is required to seal per-lease WireGuard PSK"
  let sealedPsk := ((body.fieldStr? "sealed_psk_b64").getD "").trimAscii.toString
  if !cur.agentKemPubkey.isEmpty && sealedPsk.isEmpty then
    return .error "`sealed_psk_b64` is required when `agent_kem_pubkey` is present"
  let macDirectEp := ((body.fieldStr? "mac_direct_endpoint").getD "").trimAscii.toString
  let reqOverlay := ((body.fieldStr? "overlay_ip").getD "").trimAscii.toString
  let overlayIp ←
    if !reqOverlay.isEmpty then
      let some candU32 := parseIpv4U32? reqOverlay
        | return .error s!"Invalid overlay_ip `{reqOverlay}`"
      if LeanMesh.Kernel.overlayIpStep 1 2 0x0A58C801 candU32 32 32 != 1 then
        return .error s!"overlay_ip `{reqOverlay}` rejected by LeanMesh.Kernel.overlayIpStep"
      pure reqOverlay
    else
      match ← allocateMacMeshOverlayIp? st nowSec with
      | some ip => pure ip
      | none => return .error "No free overlay IPs remaining in 10.88.200.10..250"
  let tokBytes ← match ← OrbNetLeaf.Crypto.randBytes 24 with
    | .ok b => pure b
    | .error e => return .error e
  let leaseToken := "tether1." ++ bytesToHexLower tokBytes
  let relayEp := match rt? with | some rt => rt.relayEndpoint | none => cur.relayEndpoint
  let upd ← queryMissionsDb st
    ("UPDATE mac_tether_requests SET " ++
     "effective_scope=?2, effective_target=?3, ttl_minutes=?4, session_scoped=?5, " ++
     "mac_wg_pubkey=?6, mac_kem_pubkey=?7, mac_direct_endpoint=?8, relay_endpoint=?9, " ++
     "sealed_psk_b64=?10, overlay_ip=?11, lease_token=?12, state='approved', " ++
     "updated_at=?13, expires_at=?14 " ++
     "WHERE id=?1 AND state='pending';")
    #[
      reqId, effScope, effTarget, toString ttlMins, if sessScoped then "1" else "0",
      macWgPub, macKemPub, macDirectEp, relayEp, sealedPsk, overlayIp, leaseToken,
      toString nowSec, toString expiresAt
    ]
  if let .error e := upd then
    return .error e
  syncMacTetherRelaySlots st rt? nowSec
  let _ ← bumpTetherGen rt?
  match ← getMacTetherRequest? st reqId nowSec with
  | some r => return .ok r
  | none => return .error "not_found"

def denyMacTetherRequest
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (reqId denyReason : String)
    (nowSec : UInt64) : IO (Except String MacTetherRequestRecord) := do
  let some cur ← getMacTetherRequest? st reqId nowSec
    | return .error "not_found"
  if cur.state != "pending" then
    return .error s!"Request is already in `{cur.state}` state"
  let cleanReason := if denyReason.trimAscii.toString.isEmpty then "Denied by operator" else denyReason.trimAscii.toString
  let _ ← queryMissionsDb st
    "UPDATE mac_tether_requests SET state='denied', deny_reason=?2, updated_at=?3 WHERE id=?1 AND state='pending';"
    #[reqId, cleanReason, toString nowSec]
  let _ ← bumpTetherGen rt?
  match ← getMacTetherRequest? st reqId nowSec with
  | some r => return .ok r
  | none => return .error "not_found"

def revokeMacTetherRequest
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (reqId : String)
    (callerMissionId? : Option String)
    (isAdmin : Bool)
    (nowSec : UInt64) : IO (Except String MacTetherRequestRecord) := do
  let some cur ← getMacTetherRequest? st reqId nowSec
    | return .error "not_found"
  if !isAdmin && callerMissionId? != some cur.missionId then
    return .error "forbidden"
  if cur.state == "revoked" then
    return .ok cur
  let _ ← queryMissionsDb st
    ("UPDATE mac_tether_requests SET state='revoked', lease_token='', revoked_at=?2, updated_at=?2 " ++
     "WHERE id=?1 AND state IN ('pending','approved');")
    #[reqId, toString nowSec]
  syncMacTetherRelaySlots st rt? nowSec
  let _ ← bumpTetherGen rt?
  match ← getMacTetherRequest? st reqId nowSec with
  | some r => return .ok r
  | none => return .error "not_found"

/-- Auto-revoke active `session_scoped` MacBook tether leases owned by `missionId` when the mission terminates. -/
def revokeSessionScopedMacTethersForMission
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (missionId : String)
    (nowSec : UInt64) : IO Unit := do
  if missionId.isEmpty then return
  let chk ← queryMissionsDb st
    ("SELECT id FROM mac_tether_requests WHERE mission_id=?1 AND session_scoped=1 " ++
     "AND state IN ('pending','approved') LIMIT 1;")
    #[missionId]
  let hasActive := match chk with | .ok rs => rs.size > 1 | .error _ => false
  if !hasActive then return
  let _ ← queryMissionsDb st
    ("UPDATE mac_tether_requests SET state='revoked', lease_token='', revoked_at=?2, updated_at=?2 " ++
     "WHERE mission_id=?1 AND session_scoped=1 AND state IN ('pending','approved');")
    #[missionId, toString nowSec]
  syncMacTetherRelaySlots st rt? nowSec
  let _ ← bumpTetherGen rt?

/-- Verify an approved tether lease for `orb-privd` (`mac_tether_up`). Fails closed on bunker, expiry, or revocation. -/
def verifyMacTetherLease
    (st : CoreStore)
    (bunkerState : UInt8)
    (reqId leaseToken missionId : String)
    (nowSec : UInt64) : IO (Except String MacTetherRequestRecord) := do
  if bunkerState != 0 then
    return .error "bunker_active"
  if reqId.isEmpty || leaseToken.isEmpty then
    return .error "missing_lease_fields"
  let some rec ← getMacTetherRequest? st reqId nowSec
    | return .error "unknown_tether"
  if rec.state != "approved" || rec.revokedAt != 0 || rec.expiresAt ≤ nowSec then
    return .error "tether_inactive_or_expired"
  if rec.leaseToken.isEmpty || rec.leaseToken != leaseToken then
    return .error "invalid_lease_token"
  if !rec.missionId.isEmpty && !missionId.isEmpty && rec.missionId != missionId then
    return .error "mission_mismatch"
  return .ok rec

def upsertWgRelayPair
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (pairId label peerAWgPub peerBWgPub : String)
    (enabled : Bool)
    (nowSec : UInt64) : IO (Except String WgRelayPairRecord) := do
  let pid := pairId.trimAscii.toString
  if pid.isEmpty || pid.length > 64 then
    return .error "pair_id must be 1..64 chars"
  let pa := peerAWgPub.trimAscii.toString
  let pb := peerBWgPub.trimAscii.toString
  let some bA := decodeWgPub32? pa | return .error "Invalid 32-byte Base64 peer_a_wg_pubkey"
  let some bB := decodeWgPub32? pb | return .error "Invalid 32-byte Base64 peer_b_wg_pubkey"
  if bA == bB then
    return .error "peer_a_wg_pubkey and peer_b_wg_pubkey must be distinct"
  let q ← queryMissionsDb st
    ("INSERT INTO wg_relay_pairs(pair_id,label,peer_a_wg_pubkey,peer_b_wg_pubkey,enabled,created_at,updated_at) " ++
     "VALUES(?1,?2,?3,?4,?5,?6,?6) " ++
     "ON CONFLICT(pair_id) DO UPDATE SET label=excluded.label, peer_a_wg_pubkey=excluded.peer_a_wg_pubkey, " ++
     "peer_b_wg_pubkey=excluded.peer_b_wg_pubkey, enabled=excluded.enabled, updated_at=excluded.updated_at;")
    #[pid, label.trimAscii.toString, pa, pb, if enabled then "1" else "0", toString nowSec]
  if let .error e := q then
    return .error e
  syncMacTetherRelaySlots st rt? nowSec
  return .ok {
    pairId := pid, label := label.trimAscii.toString,
    peerAWgPubkey := pa, peerBWgPubkey := pb,
    enabled := enabled, createdAt := nowSec, updatedAt := nowSec
  }

def listWgRelayPairs (st : CoreStore) : IO (Array WgRelayPairRecord) := do
  match ← queryMissionsDb st
      "SELECT pair_id,label,peer_a_wg_pubkey,peer_b_wg_pubkey,enabled,created_at,updated_at FROM wg_relay_pairs ORDER BY pair_id ASC;"
      #[] with
  | .error _ => return #[]
  | .ok rs =>
    let mut out : Array WgRelayPairRecord := Array.mkEmpty (rs.size - 1)
    for i in [1:rs.size] do
      let r := rs[i]!
      out := out.push {
        pairId        := (r[0]?).getD ""
        label         := (r[1]?).getD ""
        peerAWgPubkey := (r[2]?).getD ""
        peerBWgPubkey := (r[3]?).getD ""
        enabled       := (((r[4]?).bind String.toNat?).getD 0) != 0
        createdAt     := (((r[5]?).bind String.toNat?).getD 0).toUInt64
        updatedAt     := (((r[6]?).bind String.toNat?).getD 0).toUInt64
      }
    return out

def deleteWgRelayPair
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (pairId : String)
    (nowSec : UInt64) : IO Bool := do
  let _ ← queryMissionsDb st "DELETE FROM wg_relay_pairs WHERE pair_id=?1;" #[pairId]
  syncMacTetherRelaySlots st rt? nowSec
  return true

/-! ### MCP tools (`request_macbook_tether`, `list_macbook_tethers`, `revoke_macbook_tether`) -/

def isMacTetherToolName (name : String) : Bool :=
  name == "request_macbook_tether" ||
  name == "list_macbook_tethers" ||
  name == "revoke_macbook_tether"

/-- Label, host and managed-VM flag shown to the approver, taken from the mission row rather than the caller. -/
private def resolveMissionTetherMeta
    (st : CoreStore)
    (managedDb? : Option SqliteDb)
    (missionId hostHint : String) : IO (String × String × Bool) := do
  let mut label := if missionId.isEmpty then "operator" else s!"mission:{missionId.take 8}"
  let mut hostId := hostHint
  let mut isManaged := false
  if !missionId.isEmpty then
    if let .ok mRs ← queryMissionsDb st
        "SELECT COALESCE(title,''), COALESCE(project,''), COALESCE(placement_kind,'') FROM missions WHERE id=?1;" #[missionId] then
      if mRs.size > 1 then
        let title := ((mRs[1]?.bind (·[0]?)).getD "").trimAscii.toString
        let proj := ((mRs[1]?.bind (·[1]?)).getD "").trimAscii.toString
        let pk := ((mRs[1]?.bind (·[2]?)).getD "").trimAscii.toString
        if !title.isEmpty && !proj.isEmpty then label := s!"[{proj}] {title}"
        else if !title.isEmpty then label := title
        else if !proj.isEmpty then label := s!"[{proj}] {missionId.take 8}"
        if hostId.isEmpty && !pk.isEmpty then hostId := pk
        if pk == "managed_vm" || pk.startsWith "managed-" then isManaged := true
    if !isManaged then
      if let some db := managedDb? then
        if let .ok vmRs ← execParamQuery db
            "SELECT name FROM managed_machines WHERE owner_mission=?1 AND status<>'destroyed' LIMIT 1;" #[missionId] then
          if vmRs.size > 1 then
            isManaged := true
            if hostId.isEmpty then hostId := s!"managed-{(vmRs[1]?.bind (·[0]?)).getD "vm"}"
  if hostId.isEmpty then hostId := "unknown"
  return (label, hostId, isManaged)

/-- Return the request once it leaves `pending` or after `waitSecs` (at most 25 s). -/
private def waitTetherDecision
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (reqId : String)
    (waitSecs : Nat) : IO (Option MacTetherRequestRecord) := do
  let deadline := (← coreEpochSec) + (Nat.min waitSecs 25).toUInt64
  let mut result : Option MacTetherRequestRecord := none
  let mut done := false
  while !done do
    let nowSec ← coreEpochSec
    result ← getMacTetherRequest? st reqId nowSec
    match result with
    | none => done := true
    | some cur =>
      if cur.state != "pending" || nowSec ≥ deadline then
        done := true
      else
        match rt? with
        | some rt => discard <| waitForMacTetherGen rt (← rt.gen.atomically get) 1000
        | none => IO.sleep 200
  return result

/-- Run one tether tool for an already authorized caller. `callerMissionId` comes from the session token,
    never from the arguments. A mission sees, polls and revokes only its own requests and is the only
    one to receive their lease token. An operator session without a mission is the administrator acting
    directly: it may name a mission and sees every request. Other sessions without a mission are refused. -/
def executeMacTetherMcpTool
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (managedDb? : Option SqliteDb)
    (bunkerState : UInt8)
    (isOperator : Bool)
    (callerMissionId : String)
    (toolName : String)
    (args : JVal)
    (nowEpochSec : UInt64) : IO (Except String JVal) := do
  let direct := isOperator && callerMissionId.isEmpty
  if callerMissionId.isEmpty && !direct then
    return .error "MacBook tether tools need a mission session"
  let effMid := if direct then ((args.fieldStr? "mission_id").getD "").trimAscii.toString else callerMissionId
  let owns (r : MacTetherRequestRecord) : Bool := direct || r.missionId == effMid
  let reply (r : MacTetherRequestRecord) : JVal := .obj #[
    ("status", .str r.state),
    ("request_id", .str r.id),
    ("tether", renderMacTetherRequestJson r (r.state == "approved"))
  ]
  if toolName == "request_macbook_tether" then
    let waitSecs := (args.fieldNat? "wait_secs").getD 20
    if let some existingId := ((args.fieldStr? "request_id").map (·.trimAscii.toString)).filter (!·.isEmpty) then
      let some cur ← getMacTetherRequest? st existingId nowEpochSec
        | return .error "Unknown tether request_id"
      if !owns cur then
        return .error "Unknown tether request_id"
      let settled := (← waitTetherDecision st rt? existingId waitSecs).getD cur
      return .ok (reply settled)
    let hostHint := ((args.fieldStr? "host_id").getD "").trimAscii.toString
    let (reqLabel, resolvedHost, isManaged) ← resolveMissionTetherMeta st managedDb? effMid hostHint
    let created ← match ← createMacTetherRequest st rt? bunkerState effMid reqLabel resolvedHost isManaged args nowEpochSec with
      | .ok r => pure r
      | .error e => return .error e
    let settled := (← waitTetherDecision st rt? created.id waitSecs).getD created
    return .ok (reply settled)
  else if toolName == "list_macbook_tethers" then
    let stateFilter? := ((args.fieldStr? "state").map (·.trimAscii.toString)).filter (!·.isEmpty)
    let midFilter? : Option String := if effMid.isEmpty then none else some effMid
    let rows ← listMacTetherRequests st midFilter? stateFilter? nowEpochSec
    return .ok (.obj #[("tethers", .arr (rows.map fun r => renderMacTetherRequestJson r (r.state == "approved" && owns r)))])
  else if toolName == "revoke_macbook_tether" then
    let reqId := (((args.fieldStr? "request_id").orElse (fun _ => args.fieldStr? "id")).getD "").trimAscii.toString
    if reqId.isEmpty then
      return .error "request_id is required"
    match ← revokeMacTetherRequest st rt? reqId (some callerMissionId) direct nowEpochSec with
    | .ok r =>
      return .ok (.obj #[
        ("status", .str r.state),
        ("request_id", .str r.id),
        ("revoked", .bool (r.state == "revoked")),
        ("tether", renderMacTetherRequestJson r false)
      ])
    | .error "forbidden" | .error "not_found" => return .error "MacBook tether request not found"
    | .error e => return .error e
  else
    return .error s!"Unsupported MacBook tether tool `{toolName}`"

/-! ### HTTP routes (`/api/mac-tether/*`): the laptop daemon, `orb-privd` and the operator; all admin-only -/

private def queryParam? (rawTarget key : String) : Option String :=
  match rawTarget.splitOn "?" with
  | _ :: qs :: _ =>
    (qs.splitOn "&").findSome? fun pair =>
      match pair.splitOn "=" with
      | k :: v :: _ => if k == key then some v else none
      | _ => none
  | _ => none

/-- Returns `some (status, jsonBody)` for every `/api/mac-tether` path, `none` otherwise.
    Responses never include a lease token. -/
def dispatchMacTetherRoutes?
    (st : CoreStore)
    (rt? : Option MacTetherRuntime)
    (managedDb? : Option SqliteDb)
    (bunkerState : UInt8)
    (isAdmin : Bool)
    (method rawTarget cleanPath : String)
    (bodyBytes : ByteArray)
    (nowEpochSec : UInt64) : IO (Option (Nat × String)) := do
  if cleanPath != "/api/mac-tether" && !cleanPath.startsWith "/api/mac-tether/" then
    return none
  if !isAdmin then
    return some (403, "{\"error\":\"admin_required\"}")
  let body? := (OrbBin.Json.parseBytes bodyBytes).toOption
  let body := body?.getD (.obj #[])
  let err (code : Nat) (msg : String) : Option (Nat × String) :=
    some (code, renderCompact (.obj #[("error", .str msg)]))
  let tetherOk (code : Nat) (r : MacTetherRequestRecord) : Option (Nat × String) :=
    some (code, renderCompact (.obj #[("ok", .bool true), ("tether", renderMacTetherRequestJson r)]))
  let relayEndpoint := (rt?.map (·.relayEndpoint)).getD ""
  match method, ((cleanPath.splitOn "/").filter (!·.isEmpty)).drop 2 with
  -- Long-poll for the laptop daemon: returns when the generation passes `since_gen` or after `wait_secs`.
  | "GET", ["events"] =>
    let waitSecs := Nat.min 25 (((queryParam? rawTarget "wait_secs").bind String.toNat?).getD 0)
    let curGen ← match rt?, (queryParam? rawTarget "since_gen").bind String.toNat? with
      | some rt, some since => waitForMacTetherGen rt since.toUInt64 (waitSecs * 1000).toUInt32
      | some rt, none => rt.gen.atomically get
      | none, _ => pure 0
    let liveNow ← coreEpochSec
    let rows ← listMacTetherRequests st none none liveNow
    return some (200, renderCompact (.obj #[
      ("generation", .nat curGen.toNat),
      ("server_epoch", .nat liveNow.toNat),
      ("bunker_state", .nat bunkerState.toNat),
      ("relay_endpoint", if relayEndpoint.isEmpty then .null else .str relayEndpoint),
      ("requests", .arr (rows.map (renderMacTetherRequestJson ·)))
    ]))
  | "GET", ["requests"] =>
    let rows ← listMacTetherRequests st
      ((queryParam? rawTarget "mission_id").filter (!·.isEmpty))
      ((queryParam? rawTarget "state").filter (!·.isEmpty)) nowEpochSec
    return some (200, renderCompact (.obj #[("requests", .arr (rows.map (renderMacTetherRequestJson ·)))]))
  | "POST", ["requests"] =>
    if body?.isNone then return err 400 "invalid_json"
    let mid := ((body.fieldStr? "mission_id").getD "").trimAscii.toString
    let hostHint := ((body.fieldStr? "host_id").getD "").trimAscii.toString
    let (label, host, isManaged) ← resolveMissionTetherMeta st managedDb? mid hostHint
    match ← createMacTetherRequest st rt? bunkerState mid label host isManaged body nowEpochSec with
    | .ok r => return tetherOk 201 r
    | .error e => return err 400 e
  | "GET", ["requests", rid] =>
    match ← getMacTetherRequest? st rid nowEpochSec with
    | some r => return some (200, renderCompact (.obj #[("tether", renderMacTetherRequestJson r)]))
    | none => return err 404 "not_found"
  | "POST", ["requests", rid, "approve"] =>
    match ← approveMacTetherRequest st rt? bunkerState rid body nowEpochSec with
    | .ok r => return tetherOk 200 r
    | .error "not_found" => return err 404 "not_found"
    | .error e =>
      return err (if e.startsWith "Request is already" then 409 else if e.startsWith "Biometric JIT" then 403 else 400) e
  | "POST", ["requests", rid, "deny"] =>
    match ← denyMacTetherRequest st rt? rid ((body.fieldStr? "reason").getD "") nowEpochSec with
    | .ok r => return tetherOk 200 r
    | .error "not_found" => return err 404 "not_found"
    | .error e => return err 409 e
  | "POST", ["requests", rid, "revoke"] =>
    match ← revokeMacTetherRequest st rt? rid none true nowEpochSec with
    | .ok r => return tetherOk 200 r
    | .error "not_found" => return err 404 "not_found"
    | .error e => return err 400 e
  -- `orb-privd` checks a lease before bringing the interface up.
  | "POST", ["verify-lease"] =>
    if body?.isNone then return some (400, "{\"allowed\":false,\"error\":\"invalid_json\"}")
    match ← verifyMacTetherLease st bunkerState ((body.fieldStr? "request_id").getD "")
        ((body.fieldStr? "lease_token").getD "") ((body.fieldStr? "mission_id").getD "") nowEpochSec with
    | .error e =>
      return some (403, renderCompact (.obj #[("allowed", .bool false), ("bunker_state", .nat bunkerState.toNat), ("error", .str e)]))
    | .ok r =>
      return some (200, renderCompact (.obj #[("allowed", .bool true), ("bunker_state", .nat bunkerState.toNat),
        ("tether", renderMacTetherRequestJson r)]))
  | "GET", ["relay-pairs"] =>
    return some (200, renderCompact (.obj #[("pairs", .arr ((← listWgRelayPairs st).map renderWgRelayPairJson))]))
  | "POST", ["relay-pairs"] =>
    if body?.isNone then return err 400 "invalid_json"
    match ← upsertWgRelayPair st rt? ((body.fieldStr? "pair_id").getD "") ((body.fieldStr? "label").getD "")
        ((body.fieldStr? "peer_a_wg_pubkey").getD "") ((body.fieldStr? "peer_b_wg_pubkey").getD "")
        ((body.fieldBool? "enabled").getD true) nowEpochSec with
    | .ok p => return some (200, renderCompact (.obj #[("ok", .bool true), ("pair", renderWgRelayPairJson p)]))
    | .error e => return err 400 e
  | "DELETE", ["relay-pairs", pid] =>
    discard <| deleteWgRelayPair st rt? pid nowEpochSec
    return some (200, renderCompact (.obj #[("ok", .bool true), ("pair_id", .str pid)]))
  | _, _ => return err 404 "unknown_mac_tether_endpoint"

end OrbCore.MacTether
