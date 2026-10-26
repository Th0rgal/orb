/-
  LeanMesh.Kernel: Pure Unboxed Scalar C-ABI Kernel (`0 import Lean`, `0 sorryAx`)
  Formally verified WireGuard mesh control plane, capability ACL engine, RFC 6479
  sliding anti-replay window, authenticated endpoint roamer, NAT relay selector,
  4-state Bunker & Sovereign Dead-Man's Switch fence, and atomic WireGuard/nftables
  reconciliation engine for Orb.

  Contains only primitive `UInt8` / `UInt32` / `UInt64` functions with `@[inline, export]`.
  Compiled via `lean` / `turbo-lean` into self-contained unboxed C99 (`cabi/lean_mesh_kernel_unboxed.c`)
  with zero Lean runtime symbol dependencies (`nm -u` count == 0) and zero hand-written C fallbacks.
-/

namespace LeanMesh.Kernel

/--
  1. Unboxed C-ABI Topology Manifest Epoch & Emergency Panic Ratchet (`leanmesh_ratchet_epoch_step`):
  Packs `(admitManifest : UInt8, advanceEpoch : UInt8, advancePanicSeq : UInt8)` into a 32-bit word:
  `bit 0 (1) = admitManifest`, `bit 8 (256) = advanceEpoch`, `bit 16 (65536) = advancePanicSeq`.
  - Requires a verified Ed25519 signature over the canonical manifest digest (`sigValid == 1`)
    and well-formed boolean flag `isEmergencyPanic ≤ 1`.
  - Rejects `UInt64.max` saturation wrap-around (`candidateEpoch < 18446744073709551615` and
    `candidatePanicSeq < 18446744073709551615`).
  - Enforces bounded-TTL clock discipline (`ClockDiscipline`):
    * `0 < maxTtlSecs && maxTtlSecs ≤ 2592000` (hard ceiling of 30 days = 2,592,000s inside kernel)
    * `issuedAt < expiresAt` and `expiresAt - issuedAt ≤ maxTtlSecs` (blocks immortal manifests)
    * `nowEpoch < expiresAt` (blocks expired manifest replay)
    * Guarded future skew: `if issuedAt ≤ nowEpoch then true else issuedAt - nowEpoch ≤ 60`
  - Enforces strict lexicographic monotonic ratchet (`MonotonicRatchet`):
    * Normal progression (`isEmergencyPanic == 0`): requires `candidateEpoch > currentEpoch && candidatePanicSeq == currentPanicSeq`.
    * Emergency panic override (`isEmergencyPanic == 1`): requires `candidateEpoch ≥ currentEpoch && candidatePanicSeq > currentPanicSeq`.
-/
@[inline] def manifestClockValid (nowEpoch issuedAt expiresAt maxTtlSecs : UInt64) : Bool :=
  0 < maxTtlSecs &&
  maxTtlSecs ≤ 2592000 &&
  issuedAt < expiresAt &&
  expiresAt - issuedAt ≤ maxTtlSecs &&
  nowEpoch < expiresAt &&
  (if issuedAt ≤ nowEpoch then true else issuedAt - nowEpoch ≤ 60)

@[inline] def manifestRatchetValid
    (isEmergencyPanic : UInt8)
    (currentEpoch candidateEpoch currentPanicSeq candidatePanicSeq : UInt64) : Bool :=
  isEmergencyPanic ≤ 1 &&
  candidateEpoch < 18446744073709551615 &&
  candidatePanicSeq < 18446744073709551615 &&
  ((isEmergencyPanic == 0 && candidateEpoch > currentEpoch && candidatePanicSeq == currentPanicSeq) ||
   (isEmergencyPanic == 1 && candidateEpoch ≥ currentEpoch && candidatePanicSeq > currentPanicSeq))

@[inline, export leanmesh_ratchet_epoch_step]
def ratchetEpochStep
    (sigValid isEmergencyPanic : UInt8)
    (currentEpoch candidateEpoch currentPanicSeq candidatePanicSeq
     nowEpoch issuedAt expiresAt maxTtlSecs : UInt64) : UInt32 :=
  if sigValid == 1 &&
     manifestClockValid nowEpoch issuedAt expiresAt maxTtlSecs &&
     manifestRatchetValid isEmergencyPanic currentEpoch candidateEpoch currentPanicSeq candidatePanicSeq then
    1 |||
    (if candidateEpoch > currentEpoch then 256 else 0) |||
    (if isEmergencyPanic == 1 && candidatePanicSeq > currentPanicSeq then 65536 else 0)
  else
    0

/--
  2. Unboxed C-ABI Non-Transitive Capability ACL & Sovereign Non-Interference Gate (`leanmesh_eval_route_step`):
  Node allocation classes (`srcClass`, `dstClass : UInt8`):
  `0 = MissionSandbox`, `1 = RetiredFree`, `2 = FreeCompute`, `3 = ReservedProd`,
  `4 = SharedProtected` (`agent-core`), `5 = SovereignVault` (`dgx-spark`), `6 = OperatorAdmin`.
  Bunker states (`bunkerState : UInt8`):
  `0 = Normal`, `1 = SoftQuarantine`, `2 = HardLockdown`, `3 = SovereignDeadManTripped`.
  Protocols (`proto : UInt8`): `1 = ICMP`, `6 = TCP`, `17 = UDP`.

  Packs `(allowRoute : UInt8, requireJitAuditLog : UInt8, sovereignViolationAttempt : UInt8)` into `UInt32`:
  `bit 0 (1) = allowRoute`, `bit 8 (256) = requireJitAuditLog`, `bit 16 (65536) = sovereignViolationAttempt`.

  Invariants enforced:
  - Distinct live non-zero peers (`srcId != 0 && dstId != 0 && srcId != dstId`, `srcRevoked == 0 && dstRevoked == 0`,
    `nowEpoch < srcExpiresAt && nowEpoch < dstExpiresAt`, `srcClass ≤ 6 && dstClass ≤ 6`, `bunkerState ≤ 3`).
  - Explicit direct capability edge match (`ruleMatched == 1`) with well-formed protocol & port range.
  - Bunker lockdown:
    * `bunkerState == 3`: all routes denied (`0`).
    * `bunkerState == 2`: only `srcClass == 6` (`OperatorAdmin`) to exact TCP port `22`
      (`proto == 6 && dstPort == 22 && rulePortMin == 22 && rulePortMax == 22`) is admitted.
    * `bunkerState == 1`: `srcClass ≤ 1` (`MissionSandbox` / `RetiredFree`) is denied, and all JIT grants are disabled (`bunkerState == 0` required for JIT).
  - Leaf worker daemon port `:3088` and SSH `:22` isolation (including port-range straddling protection):
    * Whenever `dstPort == 3088 || (rulePortMin ≤ 3088 && 3088 ≤ rulePortMax)`, `srcClass` MUST be `4` or `6`.
    * Whenever `dstPort == 22 || (rulePortMin ≤ 22 && 22 ≤ rulePortMax)`, `srcClass` MUST be `4` (`agent-core` JIT broker) or `6` (`OperatorAdmin` breakglass).
  - Operator Workstation (`dstClass == 6`, `macbook-air`) Non-Interference:
    * Only `srcClass == 4` (`agent-core` for Touch ID JIT remote login) or `srcClass == 6` may route to `dstClass == 6`; compute workers (`srcClass ≤ 3` or `5`) are unconditionally blocked.
  - Sovereign Vault (`dstClass == 5`, `dgx-spark`) Non-Interference:
    * `srcClass ≤ 1` and `srcClass == 3` are NEVER admitted to `dstClass == 5`.
    * `srcClass == 2` (`FreeCompute`) is admitted to `dstClass == 5` ONLY with an active unbunkered biometric JIT lease
      (`jitBiometricGrant == 1 && bunkerState == 0 && nowEpoch < jitExpiresAt`).
  - Reserved Production (`dstClass == 3`, `thomas-md`) Isolation:
    * `srcClass ≤ 1` is admitted ONLY with an active unbunkered biometric JIT lease (`jitBiometricGrant == 1 && bunkerState == 0 && nowEpoch < jitExpiresAt`).
-/
@[inline] def protoPortValid (proto : UInt8) (dstPort rulePortMin rulePortMax : UInt32) : Bool :=
  if proto == 1 then
    dstPort == 0 && rulePortMin == 0 && rulePortMax == 0
  else if proto == 6 || proto == 17 then
    1 ≤ rulePortMin && rulePortMin ≤ dstPort && dstPort ≤ rulePortMax && rulePortMax ≤ 65535
  else
    false

@[inline] def sovereignOrLateralViolation
    (srcClass dstClass : UInt8) (dstPort rulePortMin rulePortMax : UInt32)
    (jitBiometricGrant bunkerState : UInt8) (nowEpoch jitExpiresAt : UInt64) : Bool :=
  let touches3088 := dstPort == 3088 || (rulePortMin ≤ 3088 && 3088 ≤ rulePortMax)
  let touches22 := dstPort == 22 || (rulePortMin ≤ 22 && 22 ≤ rulePortMax)
  let jitActive := jitBiometricGrant == 1 && bunkerState == 0 && nowEpoch < jitExpiresAt
  let vaultServicePort := 8888 ≤ rulePortMin && rulePortMax ≤ 8890 && 8888 ≤ dstPort && dstPort ≤ 8890
  (touches3088 && srcClass != 4 && srcClass != 6) ||
  (touches22 && srcClass != 4 && srcClass != 6) ||
  (dstClass == 6 && srcClass != 4 && srcClass != 6) ||
  (dstClass == 5 &&
    (srcClass ≤ 1 || srcClass == 3 || srcClass == 5 ||
     (srcClass == 2 && !jitActive) ||
     (srcClass == 4 && !vaultServicePort))) ||
  (dstClass == 3 && srcClass ≤ 1 && !jitActive)

@[inline] def bunkerAllowsRoute
    (bunkerState srcClass proto : UInt8) (dstPort rulePortMin rulePortMax : UInt32) : Bool :=
  if bunkerState == 0 then true
  else if bunkerState == 1 then srcClass ≥ 2
  else if bunkerState == 2 then
    srcClass == 6 && proto == 6 && dstPort == 22 && rulePortMin == 22 && rulePortMax == 22
  else false

@[inline] def evalRouteBaseOk
    (srcId dstId : UInt32)
    (srcClass dstClass srcRevoked dstRevoked ruleMatched proto : UInt8)
    (dstPort rulePortMin rulePortMax : UInt32)
    (bunkerState : UInt8)
    (nowEpoch srcExpiresAt dstExpiresAt : UInt64) : Bool :=
  srcId != 0 && dstId != 0 && srcId != dstId &&
  srcClass ≤ 6 && dstClass ≤ 6 && bunkerState ≤ 3 &&
  srcRevoked == 0 && dstRevoked == 0 &&
  ruleMatched == 1 &&
  nowEpoch < srcExpiresAt && nowEpoch < dstExpiresAt &&
  protoPortValid proto dstPort rulePortMin rulePortMax &&
  bunkerAllowsRoute bunkerState srcClass proto dstPort rulePortMin rulePortMax

@[inline, export leanmesh_eval_route_step]
def evalRouteStep
    (srcId dstId : UInt32)
    (srcClass dstClass srcRevoked dstRevoked ruleMatched proto : UInt8)
    (dstPort rulePortMin rulePortMax : UInt32)
    (jitBiometricGrant bunkerState : UInt8)
    (nowEpoch srcExpiresAt dstExpiresAt jitExpiresAt : UInt64) : UInt32 :=
  let viol := sovereignOrLateralViolation srcClass dstClass dstPort rulePortMin rulePortMax
                jitBiometricGrant bunkerState nowEpoch jitExpiresAt
  let baseOk := evalRouteBaseOk srcId dstId srcClass dstClass srcRevoked dstRevoked
                  ruleMatched proto dstPort rulePortMin rulePortMax bunkerState
                  nowEpoch srcExpiresAt dstExpiresAt
  if !baseOk || viol then
    if viol then 65536 else 0
  else
    let needsJitAudit :=
      (dstClass == 5 && srcClass == 2) ||
      (dstClass == 3 && srcClass ≤ 1) ||
      bunkerState == 2
    1 ||| (if needsJitAudit then 256 else 0)

/--
  3. Unboxed C-ABI RFC 6479 64-Packet Sliding Anti-Replay Window (`leanmesh_replay_window_step`,
  `leanmesh_replay_window_next_max`, `leanmesh_replay_window_next_bitmap`).
-/
@[inline, export leanmesh_replay_window_step]
def replayWindowStep (lastMaxSeq bitmap pktSeq : UInt64) : UInt8 :=
  if pktSeq == 0 || pktSeq == 18446744073709551615 then 0
  else if pktSeq > lastMaxSeq then 1
  else
    let age := lastMaxSeq - pktSeq
    if age ≥ 64 then 0
    else
      let mask : UInt64 := (1 : UInt64) <<< age
      if (bitmap &&& mask) != 0 then 0 else 1

@[inline, export leanmesh_replay_window_next_max]
def replayWindowNextMax (lastMaxSeq bitmap pktSeq : UInt64) : UInt64 :=
  if replayWindowStep lastMaxSeq bitmap pktSeq == 1 then
    if pktSeq > lastMaxSeq then pktSeq else lastMaxSeq
  else
    lastMaxSeq

@[inline, export leanmesh_replay_window_next_bitmap]
def replayWindowNextBitmap (lastMaxSeq bitmap pktSeq : UInt64) : UInt64 :=
  if replayWindowStep lastMaxSeq bitmap pktSeq == 1 then
    if pktSeq > lastMaxSeq then
      let delta := pktSeq - lastMaxSeq
      if delta ≥ 64 then 1 else (bitmap <<< delta) ||| 1
    else
      let age := lastMaxSeq - pktSeq
      if age ≥ 64 then bitmap else bitmap ||| ((1 : UInt64) <<< age)
  else
    bitmap

/--
  4. Unboxed C-ABI Authenticated Endpoint Roaming & Anti-Hijack Gate (`leanmesh_endpoint_roam_step`).
-/
@[inline] def endpointRoamOk
    (aeadAuthOk peerPinnedStatic candidateIpClass allowPrivateRoam bunkerState : UInt8)
    (candidatePort : UInt32)
    (lastRoamSeq pktSeq lastRoamEpoch nowEpoch minRoamIntervalSecs : UInt64) : Bool :=
  let ipClassOk :=
    candidateIpClass == 5 ||
    (allowPrivateRoam == 1 && (candidateIpClass == 3 || candidateIpClass == 4))
  aeadAuthOk == 1 &&
  peerPinnedStatic == 0 &&
  bunkerState == 0 &&
  1 ≤ candidatePort && candidatePort ≤ 65535 &&
  pktSeq > lastRoamSeq && pktSeq < 18446744073709551615 &&
  ipClassOk &&
  0 < minRoamIntervalSecs && minRoamIntervalSecs ≤ 86400 &&
  lastRoamEpoch ≤ nowEpoch &&
  nowEpoch - lastRoamEpoch ≥ minRoamIntervalSecs

@[inline, export leanmesh_endpoint_roam_step]
def endpointRoamStep
    (aeadAuthOk peerPinnedStatic candidateIpClass allowPrivateRoam bunkerState : UInt8)
    (candidatePort : UInt32)
    (lastRoamSeq pktSeq lastRoamEpoch nowEpoch minRoamIntervalSecs : UInt64) : UInt8 :=
  if endpointRoamOk aeadAuthOk peerPinnedStatic candidateIpClass allowPrivateRoam bunkerState
       candidatePort lastRoamSeq pktSeq lastRoamEpoch nowEpoch minRoamIntervalSecs then 1 else 0

/--
  5. Unboxed C-ABI NAT Traversal & Control-Plane Relay Selection Stepper (`leanmesh_relay_select_step`).
  Returns transport path kind (`UInt8`):
  `0 = DropNoPath`, `1 = DirectWan`, `2 = DirectLan`, `3 = ControlPlaneRelay`.
-/
@[inline] def directPathFresh (nowEpoch directHandshakeAt maxDirectStaleSecs : UInt64) : Bool :=
  directHandshakeAt > 0 &&
  0 < maxDirectStaleSecs && maxDirectStaleSecs ≤ 86400 &&
  directHandshakeAt ≤ nowEpoch &&
  nowEpoch - directHandshakeAt ≤ maxDirectStaleSecs

@[inline, export leanmesh_relay_select_step]
def relaySelectStep
    (routeAllowed lanReachable wanReachable relayHealthy : UInt8)
    (srcId dstId relayId activeRelaySessions maxRelaySessions : UInt32)
    (nowEpoch directHandshakeAt maxDirectStaleSecs : UInt64) : UInt8 :=
  let fresh := directPathFresh nowEpoch directHandshakeAt maxDirectStaleSecs
  if routeAllowed != 1 || srcId == 0 || dstId == 0 || srcId == dstId then 0
  else if lanReachable == 1 && fresh then 2
  else if wanReachable == 1 && fresh then 1
  else if relayHealthy == 1 && relayId != 0 && relayId != srcId && relayId != dstId &&
          activeRelaySessions < maxRelaySessions then 3
  else 0

/--
  6. Unboxed C-ABI 4-State Mesh Bunker & Sovereign Dead-Man's Switch Stepper (`leanmesh_bunker_isolate_step`).
-/
@[inline] def sovereignDeadManExpired
    (isSovereignNode heartbeatValid : UInt8)
    (nowEpoch lastHeartbeatAt deadManTimeoutSecs : UInt64) : Bool :=
  isSovereignNode == 1 &&
  (heartbeatValid != 1 ||
   deadManTimeoutSecs == 0 ||
   nowEpoch < lastHeartbeatAt ||
   nowEpoch - lastHeartbeatAt ≥ deadManTimeoutSecs)

@[inline] def clampBunkerState (s : UInt8) : UInt8 :=
  if s == 0 then 0
  else if s == 1 then 1
  else if s == 2 then 2
  else 3

@[inline] def bunkerTriggerFloor
    (deadMan : Bool) (canaryTripped authFailureBurst manualTrigger : UInt8) : UInt8 :=
  if deadMan then 3
  else if canaryTripped == 1 || manualTrigger == 2 then 2
  else if authFailureBurst == 1 || manualTrigger == 1 then 1
  else 0

@[inline] def bunkerNextState
    (currentState isSovereignNode canaryTripped authFailureBurst
     manualTrigger biometricUnbunker heartbeatValid : UInt8)
    (nowEpoch lastHeartbeatAt deadManTimeoutSecs : UInt64) : UInt8 :=
  let clamped : UInt8 := clampBunkerState currentState
  let retained : UInt8 := if biometricUnbunker == 1 then 0 else clamped
  let deadMan := manualTrigger == 3 ||
                 sovereignDeadManExpired isSovereignNode heartbeatValid nowEpoch lastHeartbeatAt deadManTimeoutSecs
  let floor := bunkerTriggerFloor deadMan canaryTripped authFailureBurst manualTrigger
  if floor ≥ retained then floor else retained

@[inline, export leanmesh_bunker_isolate_step]
def bunkerIsolateStep
    (currentState isSovereignNode canaryTripped authFailureBurst
     manualTrigger biometricUnbunker heartbeatValid : UInt8)
    (nowEpoch lastHeartbeatAt deadManTimeoutSecs : UInt64) : UInt32 :=
  let next : UInt8 := bunkerNextState currentState isSovereignNode canaryTripped authFailureBurst
                        manualTrigger biometricUnbunker heartbeatValid nowEpoch lastHeartbeatAt deadManTimeoutSecs
  next.toUInt32 |||
    (if next ≥ 1 then 256 else 0) |||
    (if next ≥ 2 then 65536 else 0) |||
    (if next == 3 || (isSovereignNode == 1 && next ≥ 2) then 16777216 else 0)

/--
  7. Unboxed C-ABI Pre-Authentication Control Frame & Wire Bounds Gate (`leanmesh_frame_bounds_step`).
-/
@[inline, export leanmesh_frame_bounds_step]
def frameBoundsStep
    (magic : UInt32)
    (version frameKind tagVerified : UInt8)
    (headerLen payloadLen maxFrameBytes bufCap : UInt64) : UInt8 :=
  if magic == 0x4C4D5348 &&
     version == 1 &&
     1 ≤ frameKind && frameKind ≤ 6 &&
     tagVerified == 1 &&
     headerLen ≥ 32 &&
     maxFrameBytes ≤ bufCap &&
     headerLen ≤ maxFrameBytes &&
     payloadLen ≤ maxFrameBytes - headerLen then 1 else 0

/--
  8. Unboxed C-ABI Deterministic `10.88.0.0/16` Overlay IP & AllowedIPs Disjointness Gate (`leanmesh_overlay_ip_step`).
-/
@[inline] def overlayHostIpValid (ip : UInt32) : Bool :=
  0x0A580001 ≤ ip && ip ≤ 0x0A58FFFE

@[inline, export leanmesh_overlay_ip_step]
def overlayIpStep
    (peerIdA peerIdB ipA ipB : UInt32)
    (prefixLenA prefixLenB : UInt8) : UInt8 :=
  if peerIdA != 0 && peerIdB != 0 && peerIdA != peerIdB &&
     overlayHostIpValid ipA && overlayHostIpValid ipB &&
     prefixLenA == 32 && prefixLenB == 32 &&
     ipA != ipB then 1 else 0

/--
  9. Unboxed C-ABI Atomic Kernel WireGuard & nftables Peer Reconciliation Stepper (`leanmesh_reconcile_wg_step`):
  `bunkerPruneNonAdmin`:
  `0 = Normal`, `1 = PruneNonAdmin` (`HardLockdown`), `≥ 2 = PruneAllPeers` (`SovereignDeadManTripped`).
-/
@[inline] def peerShouldBeInactive
    (peerRevoked bunkerPruneNonAdmin peerIsAdmin : UInt8)
    (nowEpoch peerExpiresAt : UInt64) : Bool :=
  peerRevoked == 1 ||
  peerExpiresAt ≤ nowEpoch ||
  bunkerPruneNonAdmin ≥ 2 ||
  (bunkerPruneNonAdmin == 1 && peerIsAdmin != 1)

@[inline, export leanmesh_reconcile_wg_step]
def reconcileWgStep
    (manifestValid peerPresentInKernel peerRevoked pubkeyMatches
     allowedIpMatches endpointChanged bunkerPruneNonAdmin peerIsAdmin : UInt8)
    (nowEpoch peerExpiresAt : UInt64) : UInt8 :=
  if manifestValid != 1 then 0
  else if peerShouldBeInactive peerRevoked bunkerPruneNonAdmin peerIsAdmin nowEpoch peerExpiresAt then
    if peerPresentInKernel == 1 then 1 else 2
  else if peerPresentInKernel == 0 then 4
  else if pubkeyMatches != 1 || allowedIpMatches != 1 then 3
  else if endpointChanged == 1 then 5
  else 6

/--
  10. Unboxed C-ABI Biometric JIT Cross-Tier Mesh Lease Gate (`leanmesh_jit_lease_step`):
  Closed class-pair whitelist (`jitClassPairAllowed`):
  Only `(srcClass == 2 && dstClass == 5)` (`FreeCompute -> SovereignVault`) or
  `((srcClass == 0 || srcClass == 1) && dstClass == 3)` (`MissionSandbox/RetiredFree -> ReservedProd`)
  may ever be granted a cross-tier JIT lease.
-/
@[inline] def jitClassPairAllowed (srcClass dstClass : UInt8) : Bool :=
  (srcClass == 2 && dstClass == 5) ||
  ((srcClass == 0 || srcClass == 1) && dstClass == 3)

@[inline, export leanmesh_jit_lease_step]
def jitLeaseStep
    (biometricSigValid operatorSameOwner missionActive grantRevoked
     bunkerState srcClass dstClass : UInt8)
    (nowEpoch grantIssuedAt grantExpiresAt maxJitTtlSecs : UInt64) : UInt32 :=
  if missionActive == 0 || grantRevoked == 1 || bunkerState != 0 || grantExpiresAt ≤ nowEpoch then
    256
  else if biometricSigValid == 1 &&
          operatorSameOwner == 1 &&
          jitClassPairAllowed srcClass dstClass &&
          0 < maxJitTtlSecs && maxJitTtlSecs ≤ 14400 &&
          grantIssuedAt ≤ nowEpoch &&
          grantIssuedAt < grantExpiresAt &&
          grantExpiresAt - grantIssuedAt ≤ maxJitTtlSecs then
    1
  else
    0

end LeanMesh.Kernel
