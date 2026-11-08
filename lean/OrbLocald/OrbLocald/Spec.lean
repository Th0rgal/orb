/-
  OrbLocald.Spec — Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for the desktop daemon (`orb-locald`):
    1. Loopback RPC origin & per-launch bearer token admission (`ScopedAuthority`, ≥ 32-byte entropy)
    2. Transport proxy SSE shard count & unprivileged port bounds (`ConservedResource`)
    3. Transport 3-way failover retry idempotency gate (`RetrySafetyProof` + canonical `{0,1}` flags)
    4. Paloma Touch ID grace reuse gate (`PalomaGraceAction`, `ScopedAuthority`)
    5. Run-scoped interactive tool-slot & tool-bridge admission (`ConservedResource`, `ScopedAuthority`, SM-11)
    6. Scoped `(endpoint, server_build)` client-link capability latch (`ScopedAuthority`, SM-26)
    7. 256-frame outbound client-link journal ring backpressure & reconnect resync (`ConservedResource`, SM-26)
    8. Typed HTTP `409` local-origin conflict disposition gate (`ScopedAuthority`, SM-23 / SM-26)
-/

namespace OrbLocald.Spec

/-- Universal 4-property Meta-Gate specification bundle (`sound`, `complete`,
    `posWitness`, `negWitness`, `nonVacuous`, `tight`). -/
structure MetaGateSpec (Input : Type) (Safe : Input → Prop) where
  gate       : Input → Bool
  sound      : ∀ x, gate x = true → Safe x
  complete   : ∀ x, Safe x → gate x = true
  posWitness : Input
  negWitness : Input
  nonVacuous : gate posWitness = true
  tight      : gate negWitness = false

theorem MetaGateSpec.rejects_unsafe {Input : Type} {Safe : Input → Prop}
    (M : MetaGateSpec Input Safe)
    (x : Input)
    (h_bad : ¬ Safe x) :
    M.gate x = false :=
  Bool.eq_false_iff.mpr (fun h_ok => h_bad (M.sound x h_ok))

/-- Layer-I `ScopedAuthority` meta-specification: admitted desktop IPC & biometric grace ops stay within scope. -/
structure ScopedAuthority (Input : Type) where
  admit      : Input → Bool
  scopeValid : Input → Prop
  sound      : ∀ x, admit x = true → scopeValid x

/-- Layer-I `ConservedResource` meta-specification: admitted shard pools conserve unprivileged port & FD bounds. -/
structure ConservedResource (Input : Type) where
  admit          : Input → Bool
  withinCapacity : Input → Prop
  conserved      : ∀ x, admit x = true → withinCapacity x

private theorem u8_le_one_cases (b : UInt8) (h : b ≤ 1) : b.toNat = 0 ∨ b.toNat = 1 := by
  have hb : b.toNat ≤ 1 := UInt8.le_iff_toNat_le.mp h
  omega

private theorem u8_eq_of_toNat (a : UInt8) (n : Nat) (hn : n < 256) (h : a.toNat = n) :
    a = UInt8.ofNat n := by
  apply UInt8.eq_of_toBitVec_eq
  apply BitVec.eq_of_toNat_eq
  have hm : (UInt8.ofNat n).toBitVec.toNat = n := by
    change n % 256 = n
    omega
  change a.toNat = _
  omega

/-! ### 1. Loopback RPC Origin & Per-Launch Bearer Token Admission -/

inductive PeerAuthority where
  | loopbackVerifiedBearer
  deriving Repr, DecidableEq

def PeerAuthority.decode? (peerCode : Nat) (tokOk : Nat) : Option PeerAuthority :=
  if peerCode = 1 ∧ tokOk = 1 then some .loopbackVerifiedBearer else none

def minLaunchBearerEntropyBytes : Nat := 32
def maxLaunchBearerBytes : Nat := 4096

structure LocaldRpcAuthCheck where
  isLoopback   : UInt8
  tokenMatches : UInt8
  tokenLen     : UInt32
  deriving Repr, DecidableEq

@[inline, export orb_locald_verify_rpc_auth]
def verifyLocaldRpcAuth (isLoopback tokenMatches : UInt8) (tokenLen : UInt32) : UInt8 :=
  if isLoopback == 1 && tokenMatches == 1 && tokenLen ≥ 32 && tokenLen ≤ 4096 then 1 else 0

/-- Independent loopback IPC authority specification over `PeerAuthority` & CSPRNG entropy bounds. -/
def LocaldRpcAuthDomainSafe (c : LocaldRpcAuthCheck) : Prop :=
  PeerAuthority.decode? c.isLoopback.toNat c.tokenMatches.toNat = some .loopbackVerifiedBearer ∧
  minLaunchBearerEntropyBytes ≤ c.tokenLen.toNat ∧
  c.tokenLen.toNat ≤ maxLaunchBearerBytes

def localdRpcAuthMetaGate : MetaGateSpec LocaldRpcAuthCheck LocaldRpcAuthDomainSafe where
  gate c := verifyLocaldRpcAuth c.isLoopback c.tokenMatches c.tokenLen == 1
  sound c h := by
    rcases c with ⟨lb, tm, tL⟩
    change (verifyLocaldRpcAuth lb tm tL == 1) = true at h
    dsimp [LocaldRpcAuthDomainSafe]
    unfold verifyLocaldRpcAuth at h
    have hc : (lb == 1 && tm == 1 && tL ≥ 32 && tL ≤ 4096) = true := by
      cases hb : (lb == 1 && tm == 1 && tL ≥ 32 && tL ≤ 4096)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨hlb, htm⟩, hl1⟩, hl2⟩
    subst hlb; subst htm
    exact ⟨rfl, UInt32.le_iff_toNat_le.mp hl1, UInt32.le_iff_toNat_le.mp hl2⟩
  complete c h := by
    rcases c with ⟨lb, tm, tL⟩
    change (verifyLocaldRpcAuth lb tm tL == 1) = true
    dsimp [LocaldRpcAuthDomainSafe] at h
    rcases h with ⟨hp, hl1, hl2⟩
    unfold PeerAuthority.decode? at hp
    split at hp
    · rename_i hpair
      rcases hpair with ⟨hlb, htm⟩
      unfold verifyLocaldRpcAuth
      have hlbB : (lb == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat lb 1 (by omega) hlb
      have htmB : (tm == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat tm 1 (by omega) htm
      have hlGe : tL ≥ 32 := UInt32.le_iff_toNat_le.mpr hl1
      have hlLe : tL ≤ 4096 := UInt32.le_iff_toNat_le.mpr hl2
      simp [hlbB, htmB, hlGe, hlLe]
    · contradiction
  posWitness := { isLoopback := 1, tokenMatches := 1, tokenLen := 36 }
  negWitness := { isLoopback := 1, tokenMatches := 1, tokenLen := 24 }
  nonVacuous := by decide
  tight := by decide

def localdRpcScopedAuthority : ScopedAuthority LocaldRpcAuthCheck where
  admit := localdRpcAuthMetaGate.gate
  scopeValid c := c.isLoopback.toNat = 1 ∧ c.tokenMatches.toNat = 1 ∧ 32 ≤ c.tokenLen.toNat
  sound c h := by
    rcases localdRpcAuthMetaGate.sound c h with ⟨hp, hl1, _⟩
    unfold PeerAuthority.decode? at hp
    split at hp
    · rename_i hpair; exact ⟨hpair.1, hpair.2, hl1⟩
    · contradiction

theorem verifyLocaldRpcAuth_iff (isLoopback tokenMatches : UInt8) (tokenLen : UInt32) :
    (verifyLocaldRpcAuth isLoopback tokenMatches tokenLen == 1) = true ↔
      LocaldRpcAuthDomainSafe ⟨isLoopback, tokenMatches, tokenLen⟩ :=
  ⟨localdRpcAuthMetaGate.sound ⟨isLoopback, tokenMatches, tokenLen⟩,
   localdRpcAuthMetaGate.complete ⟨isLoopback, tokenMatches, tokenLen⟩⟩

/-! ### 2. Transport Bridge SSE Shard Count & Unprivileged Port Bounds -/

def firstUnprivilegedTcpPort : Nat := 1024
def maxUnprivilegedTcpPort : Nat := 65535
def maxSseShards : Nat := 16

structure SseShardPoolCheck where
  shardCount : UInt8
  proxyPort  : UInt16
  deriving Repr, DecidableEq

@[inline, export orb_locald_verify_sse_shard_config]
def verifySseShardConfig (shardCount : UInt8) (proxyPort : UInt16) : UInt8 :=
  if shardCount ≥ 1 && shardCount ≤ 16 && proxyPort ≥ 1024 &&
     proxyPort.toUInt32 + shardCount.toUInt32 ≤ 65535 then 1 else 0

/-- Independent SSE pool & non-root port range specification (`ConservedResource`):
    `1..16` SSE shards, base `proxyPort ≥ 1024`, and the contiguous port block
    `proxyPort .. proxyPort + shardCount` fits within `1024..65535` without wrapping `UInt16`. -/
def SseShardConfigDomainSafe (c : SseShardPoolCheck) : Prop :=
  1 ≤ c.shardCount.toNat ∧
  c.shardCount.toNat ≤ maxSseShards ∧
  firstUnprivilegedTcpPort ≤ c.proxyPort.toNat ∧
  c.proxyPort.toNat + c.shardCount.toNat ≤ maxUnprivilegedTcpPort

def sseShardConfigMetaGate : MetaGateSpec SseShardPoolCheck SseShardConfigDomainSafe where
  gate c := verifySseShardConfig c.shardCount c.proxyPort == 1
  sound c h := by
    rcases c with ⟨sc, pp⟩
    change (verifySseShardConfig sc pp == 1) = true at h
    dsimp [SseShardConfigDomainSafe]
    unfold verifySseShardConfig at h
    have hc : (sc ≥ 1 && sc ≤ 16 && pp ≥ 1024 && pp.toUInt32 + sc.toUInt32 ≤ 65535) = true := by
      cases hb : (sc ≥ 1 && sc ≤ 16 && pp ≥ 1024 && pp.toUInt32 + sc.toUInt32 ≤ 65535)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨hs1, hs2⟩, hp⟩, htop⟩
    have hsN1 : 1 ≤ sc.toNat := UInt8.le_iff_toNat_le.mp hs1
    have hsN2 : sc.toNat ≤ 16 := UInt8.le_iff_toNat_le.mp hs2
    have hpN : 1024 ≤ pp.toNat := UInt16.le_iff_toNat_le.mp hp
    have hppLt : pp.toNat < 65536 := pp.toNat_lt
    have htopRaw := UInt32.le_iff_toNat_le.mp htop
    simp [UInt32.toNat_add, UInt16.toNat_toUInt32, UInt8.toNat_toUInt32] at htopRaw
    refine ⟨hsN1, hsN2, hpN, ?_⟩
    unfold maxUnprivilegedTcpPort; omega
  complete c h := by
    rcases c with ⟨sc, pp⟩
    change (verifySseShardConfig sc pp == 1) = true
    dsimp [SseShardConfigDomainSafe] at h
    rcases h with ⟨hs1, hs2, hp, htop⟩
    unfold verifySseShardConfig
    have hsGe : sc ≥ 1 := UInt8.le_iff_toNat_le.mpr hs1
    have hsLe : sc ≤ 16 := UInt8.le_iff_toNat_le.mpr hs2
    have hpGe : pp ≥ 1024 := UInt16.le_iff_toNat_le.mpr hp
    have htopB : pp.toUInt32 + sc.toUInt32 ≤ 65535 := by
      apply UInt32.le_iff_toNat_le.mpr
      simp [UInt32.toNat_add, UInt16.toNat_toUInt32, UInt8.toNat_toUInt32]
      unfold maxSseShards at hs2
      unfold maxUnprivilegedTcpPort at htop
      omega
    simp [hsGe, hsLe, hpGe, htopB]
  posWitness := { shardCount := 6, proxyPort := 19480 }
  negWitness := { shardCount := 6, proxyPort := 65532 }
  nonVacuous := by decide
  tight := by decide

def sseShardConservedResource : ConservedResource SseShardPoolCheck where
  admit := sseShardConfigMetaGate.gate
  withinCapacity c := 1024 ≤ c.proxyPort.toNat ∧ c.proxyPort.toNat + c.shardCount.toNat ≤ 65535
  conserved c h := by
    rcases sseShardConfigMetaGate.sound c h with ⟨_, _, hp, htop⟩
    exact ⟨hp, htop⟩

theorem verifySseShardConfig_iff (shardCount : UInt8) (proxyPort : UInt16) :
    (verifySseShardConfig shardCount proxyPort == 1) = true ↔
      SseShardConfigDomainSafe ⟨shardCount, proxyPort⟩ :=
  ⟨sseShardConfigMetaGate.sound ⟨shardCount, proxyPort⟩,
   sseShardConfigMetaGate.complete ⟨shardCount, proxyPort⟩⟩

/-! ### 3. Transport 3-Way Failover Retry Idempotency Gate -/

inductive RetrySafetyProof where
  | rfc9110SafeMethod
  | explicitIdempotencyKey
  deriving Repr, DecidableEq

structure TransportWriteRetryCheck where
  isSafeMethod      : UInt8
  hasIdempotencyKey : UInt8
  nextOriginIdx     : UInt8
  originCount       : UInt8
  deriving Repr, DecidableEq

@[inline, export orb_locald_verify_write_retry]
def verifyTransportWriteRetry (isSafeMethod hasIdempotencyKey nextOriginIdx originCount : UInt8) : UInt8 :=
  if isSafeMethod ≤ 1 && hasIdempotencyKey ≤ 1 &&
     originCount ≥ 1 && originCount ≤ 16 && nextOriginIdx < originCount &&
     (isSafeMethod == 1 || hasIdempotencyKey == 1) then 1 else 0

/-- Independent failover retry safety specification:
    boolean flags are canonical (`0` or `1`), origin pool has `1..16` endpoints,
    `nextOriginIdx + 1 ≤ originCount`, and there exists a `RetrySafetyProof` witnessing
    that replaying the request across origins cannot duplicate writes. -/
def TransportWriteRetryDomainSafe (c : TransportWriteRetryCheck) : Prop :=
  (c.isSafeMethod.toNat = 0 ∨ c.isSafeMethod.toNat = 1) ∧
  (c.hasIdempotencyKey.toNat = 0 ∨ c.hasIdempotencyKey.toNat = 1) ∧
  1 ≤ c.originCount.toNat ∧
  c.originCount.toNat ≤ 16 ∧
  c.nextOriginIdx.toNat + 1 ≤ c.originCount.toNat ∧
  ∃ w : RetrySafetyProof,
    match w with
    | .rfc9110SafeMethod      => c.isSafeMethod.toNat = 1
    | .explicitIdempotencyKey => c.hasIdempotencyKey.toNat = 1

def transportWriteRetryMetaGate :
    MetaGateSpec TransportWriteRetryCheck TransportWriteRetryDomainSafe where
  gate c := verifyTransportWriteRetry c.isSafeMethod c.hasIdempotencyKey c.nextOriginIdx c.originCount == 1
  sound c h := by
    rcases c with ⟨isS, hasIk, nIdx, cnt⟩
    change (verifyTransportWriteRetry isS hasIk nIdx cnt == 1) = true at h
    dsimp [TransportWriteRetryDomainSafe]
    unfold verifyTransportWriteRetry at h
    have hc :
        (isS ≤ 1 && hasIk ≤ 1 && cnt ≥ 1 && cnt ≤ 16 && nIdx < cnt && (isS == 1 || hasIk == 1)) = true := by
      cases hb :
          (isS ≤ 1 && hasIk ≤ 1 && cnt ≥ 1 && cnt ≤ 16 && nIdx < cnt && (isS == 1 || hasIk == 1))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨hsLe, hikLe⟩, hc1⟩, hc2⟩, hlt⟩, hw⟩
    have hltN : nIdx.toNat < cnt.toNat := UInt8.lt_iff_toNat_lt.mp hlt
    refine ⟨u8_le_one_cases isS hsLe, u8_le_one_cases hasIk hikLe,
            UInt8.le_iff_toNat_le.mp hc1, UInt8.le_iff_toNat_le.mp hc2, by omega, ?_⟩
    rcases hw with hs | hik
    · exact ⟨.rfc9110SafeMethod, by subst hs; rfl⟩
    · exact ⟨.explicitIdempotencyKey, by subst hik; rfl⟩
  complete c h := by
    rcases c with ⟨isS, hasIk, nIdx, cnt⟩
    change (verifyTransportWriteRetry isS hasIk nIdx cnt == 1) = true
    dsimp [TransportWriteRetryDomainSafe] at h
    rcases h with ⟨hs1, hik1, hc1, hc2, hlt, w, hw⟩
    unfold verifyTransportWriteRetry
    have hsLe : isS ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change isS.toNat ≤ 1; omega
    have hikLe : hasIk ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change hasIk.toNat ≤ 1; omega
    have hcGe : cnt ≥ 1 := UInt8.le_iff_toNat_le.mpr hc1
    have hcLe : cnt ≤ 16 := UInt8.le_iff_toNat_le.mpr hc2
    have hltB : nIdx < cnt := by apply UInt8.lt_iff_toNat_lt.mpr; omega
    cases w with
    | rfc9110SafeMethod =>
      have hsB : (isS == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat isS 1 (by omega) hw
      simp [hsLe, hikLe, hcGe, hcLe, hltB, hsB]
    | explicitIdempotencyKey =>
      have hikB : (hasIk == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hasIk 1 (by omega) hw
      simp [hsLe, hikLe, hcGe, hcLe, hltB, hikB]
  posWitness := { isSafeMethod := 0, hasIdempotencyKey := 1, nextOriginIdx := 1, originCount := 3 }
  negWitness := { isSafeMethod := 0, hasIdempotencyKey := 0, nextOriginIdx := 1, originCount := 3 }
  nonVacuous := by decide
  tight := by decide

theorem verifyTransportWriteRetry_iff (isSafe hasIdem nextIdx count : UInt8) :
    (verifyTransportWriteRetry isSafe hasIdem nextIdx count == 1) = true ↔
      TransportWriteRetryDomainSafe ⟨isSafe, hasIdem, nextIdx, count⟩ :=
  ⟨transportWriteRetryMetaGate.sound ⟨isSafe, hasIdem, nextIdx, count⟩,
   transportWriteRetryMetaGate.complete ⟨isSafe, hasIdem, nextIdx, count⟩⟩

/-! ### 4. Paloma Touch ID Grace Reuse Gate -/

inductive PalomaGraceAction where
  | bitwardenApprove
  | bitwardenReject
  deriving Repr, DecidableEq

def PalomaGraceAction.decode? (isPost isBw actCode : Nat) : Option PalomaGraceAction :=
  if isPost = 1 ∧ isBw = 1 then
    match actCode with
    | 1 => some .bitwardenApprove
    | 2 => some .bitwardenReject
    | _ => none
  else
    none

def canonicalUuidHyphenatedBytes : Nat := 36

structure PalomaGraceCheck where
  isPost        : UInt8
  isBitwarden   : UInt8
  uuidLen       : UInt32
  actionCode    : UInt8
  deriving Repr, DecidableEq

@[inline, export orb_locald_verify_paloma_grace]
def verifyPalomaGraceEligible (isPost isBitwardenReq : UInt8) (uuidLen : UInt32) (actionCode : UInt8) : UInt8 :=
  if isPost == 1 && isBitwardenReq == 1 && uuidLen == 36 &&
     (actionCode == 1 || actionCode == 2) then 1 else 0

/-- Independent Touch ID grace reuse scope specification (`ScopedAuthority`) over `PalomaGraceAction`. -/
def PalomaGraceDomainSafe (c : PalomaGraceCheck) : Prop :=
  (PalomaGraceAction.decode? c.isPost.toNat c.isBitwarden.toNat c.actionCode.toNat).isSome = true ∧
  c.uuidLen.toNat = canonicalUuidHyphenatedBytes

def palomaGraceMetaGate : MetaGateSpec PalomaGraceCheck PalomaGraceDomainSafe where
  gate c := verifyPalomaGraceEligible c.isPost c.isBitwarden c.uuidLen c.actionCode == 1
  sound c h := by
    rcases c with ⟨ip, ib, uL, ac⟩
    change (verifyPalomaGraceEligible ip ib uL ac == 1) = true at h
    dsimp [PalomaGraceDomainSafe]
    unfold verifyPalomaGraceEligible at h
    have hc : (ip == 1 && ib == 1 && uL == 36 && (ac == 1 || ac == 2)) = true := by
      cases hb : (ip == 1 && ib == 1 && uL == 36 && (ac == 1 || ac == 2))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨hip, hib⟩, huL⟩, (hac1 | hac2)⟩
    · subst hip
      subst hib
      subst huL
      subst hac1
      exact ⟨rfl, rfl⟩
    · subst hip
      subst hib
      subst huL
      subst hac2
      exact ⟨rfl, rfl⟩
  complete c h := by
    rcases c with ⟨ip, ib, uL, ac⟩
    change (verifyPalomaGraceEligible ip ib uL ac == 1) = true
    dsimp [PalomaGraceDomainSafe] at h
    rcases h with ⟨hdec, huL⟩
    unfold PalomaGraceAction.decode? at hdec
    split at hdec
    · rename_i hpb
      rcases hpb with ⟨hip, hib⟩
      unfold verifyPalomaGraceEligible
      have hipB : (ip == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ip 1 (by omega) hip
      have hibB : (ib == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ib 1 (by omega) hib
      have huLB : (uL == 36) = true := by
        rw [beq_iff_eq]
        apply UInt32.eq_of_toBitVec_eq
        apply BitVec.eq_of_toNat_eq
        change uL.toNat = 36
        exact huL
      cases hac : ac.toNat with
      | zero => simp [hac] at hdec
      | succ m =>
        rcases m with _ | _ | _
        · have hacB : (ac == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ac 1 (by omega) hac
          simp [hipB, hibB, huLB, hacB]
        · have hacB : (ac == 2) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ac 2 (by omega) hac
          simp [hipB, hibB, huLB, hacB]
        · simp [hac] at hdec
    · contradiction
  posWitness := { isPost := 1, isBitwarden := 1, uuidLen := 36, actionCode := 1 }
  negWitness := { isPost := 1, isBitwarden := 0, uuidLen := 36, actionCode := 1 }
  nonVacuous := by decide
  tight := by decide

def palomaGraceScopedAuthority : ScopedAuthority PalomaGraceCheck where
  admit := palomaGraceMetaGate.gate
  scopeValid c := c.isPost.toNat = 1 ∧ c.isBitwarden.toNat = 1 ∧ (c.actionCode.toNat = 1 ∨ c.actionCode.toNat = 2)
  sound c h := by
    rcases palomaGraceMetaGate.sound c h with ⟨hdec, _⟩
    unfold PalomaGraceAction.decode? at hdec
    split at hdec
    · rename_i hpb
      refine ⟨hpb.1, hpb.2, ?_⟩
      cases hac : c.actionCode.toNat with
      | zero => simp [hac] at hdec
      | succ m =>
        rcases m with _ | _ | _
        · left; rfl
        · right; rfl
        · simp [hac] at hdec
    · contradiction

theorem verifyPalomaGraceEligible_iff (isPost isBw : UInt8) (uuidLen : UInt32) (actCode : UInt8) :
    (verifyPalomaGraceEligible isPost isBw uuidLen actCode == 1) = true ↔
      PalomaGraceDomainSafe ⟨isPost, isBw, uuidLen, actCode⟩ :=
  ⟨palomaGraceMetaGate.sound ⟨isPost, isBw, uuidLen, actCode⟩,
   palomaGraceMetaGate.complete ⟨isPost, isBw, uuidLen, actCode⟩⟩

/-! ### 5. Run-Scoped Interactive Tool-Slot & Tool-Bridge Admission (`SM-11`) -/

def maxInteractiveToolSlots : Nat := 64
def maxInteractiveToolSlotCapBound : Nat := 256

inductive ToolSlotAdmission where
  | freshWithinCapacity
  | idempotentSamePayload
  deriving Repr, DecidableEq

/-- Explicit duplicate classification, separate from fresh admission:
    identical payload digest replays; a different digest under the same request id conflicts. -/
inductive ToolSlotDuplicateClass where
  | idempotentReplay
  | conflictingDuplicate
  deriving Repr, DecidableEq

structure InteractiveToolSlotCheck where
  activeSlots        : UInt16
  maxCap             : UInt16
  sessionEpoch       : UInt64
  currentEpoch       : UInt64
  hasNonEmptyRunId   : UInt8
  hasNonEmptyRequestId : UInt8
  isDuplicateRequestId : UInt8
  samePayloadReplay  : UInt8
  conflictingDuplicate : UInt8
  deriving Repr, DecidableEq

@[inline, export orb_locald_verify_tool_slot_admit]
def verifyInteractiveToolSlotAdmit
    (activeSlots maxCap : UInt16)
    (sessionEpoch currentEpoch : UInt64)
    (hasNonEmptyRunId hasNonEmptyRequestId isDuplicateRequestId
      samePayloadReplay conflictingDuplicate : UInt8) : UInt8 :=
  if 1 ≤ maxCap && maxCap ≤ 256 &&
     hasNonEmptyRunId == 1 && hasNonEmptyRequestId == 1 &&
     sessionEpoch > 0 && currentEpoch > 0 &&
     sessionEpoch ≥ currentEpoch &&
     isDuplicateRequestId ≤ 1 && samePayloadReplay ≤ 1 && conflictingDuplicate ≤ 1 &&
     ((isDuplicateRequestId == 0 && activeSlots < maxCap) ||
      (isDuplicateRequestId == 1 && samePayloadReplay == 1 && conflictingDuplicate == 0)) then 1 else 0

/-- Independent run-scoped slot specification (`ConservedResource` + `ScopedAuthority`).
    `"native-*"` request ids are ordinary non-empty ids: they do not appear as a bypass.
    Fresh admission requires `activeSlots < maxCap` (explicit backpressure, never eviction).
    Duplicate request ids admit only as an idempotent same-payload replay. -/
def InteractiveToolSlotDomainSafe (c : InteractiveToolSlotCheck) : Prop :=
  1 ≤ c.maxCap.toNat ∧
  c.maxCap.toNat ≤ maxInteractiveToolSlotCapBound ∧
  c.hasNonEmptyRunId.toNat = 1 ∧
  c.hasNonEmptyRequestId.toNat = 1 ∧
  c.currentEpoch.toNat > 0 ∧
  c.sessionEpoch.toNat ≥ c.currentEpoch.toNat ∧
  (c.isDuplicateRequestId.toNat = 0 ∨ c.isDuplicateRequestId.toNat = 1) ∧
  (c.samePayloadReplay.toNat = 0 ∨ c.samePayloadReplay.toNat = 1) ∧
  (c.conflictingDuplicate.toNat = 0 ∨ c.conflictingDuplicate.toNat = 1) ∧
  ∃ w : ToolSlotAdmission,
    match w with
    | .freshWithinCapacity =>
        c.isDuplicateRequestId.toNat = 0 ∧ c.activeSlots.toNat < c.maxCap.toNat
    | .idempotentSamePayload =>
        c.isDuplicateRequestId.toNat = 1 ∧
        c.samePayloadReplay.toNat = 1 ∧
        c.conflictingDuplicate.toNat = 0

def interactiveToolSlotMetaGate :
    MetaGateSpec InteractiveToolSlotCheck InteractiveToolSlotDomainSafe where
  gate c :=
    verifyInteractiveToolSlotAdmit c.activeSlots c.maxCap c.sessionEpoch c.currentEpoch
      c.hasNonEmptyRunId c.hasNonEmptyRequestId c.isDuplicateRequestId
      c.samePayloadReplay c.conflictingDuplicate == 1
  sound c h := by
    rcases c with ⟨active, maxC, sess, cur, runId, reqId, dup, same, conf⟩
    change (verifyInteractiveToolSlotAdmit active maxC sess cur runId reqId dup same conf == 1) = true at h
    dsimp [InteractiveToolSlotDomainSafe]
    unfold verifyInteractiveToolSlotAdmit at h
    have hc :
        (1 ≤ maxC && maxC ≤ 256 && runId == 1 && reqId == 1 &&
          sess > 0 && cur > 0 && sess ≥ cur &&
          dup ≤ 1 && same ≤ 1 && conf ≤ 1 &&
          ((dup == 0 && active < maxC) ||
            (dup == 1 && same == 1 && conf == 0))) = true := by
      cases hb :
          (1 ≤ maxC && maxC ≤ 256 && runId == 1 && reqId == 1 &&
            sess > 0 && cur > 0 && sess ≥ cur &&
            dup ≤ 1 && same ≤ 1 && conf ≤ 1 &&
            ((dup == 0 && active < maxC) ||
              (dup == 1 && same == 1 && conf == 0)))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨hhead, hclass⟩
    rcases hhead with ⟨⟨⟨⟨⟨⟨⟨⟨⟨hmax1, hmax2⟩, hrun⟩, hreq⟩, _hsess⟩, hcur⟩, hge⟩, hdup⟩, hsame⟩, hconf⟩
    refine ⟨UInt16.le_iff_toNat_le.mp hmax1, UInt16.le_iff_toNat_le.mp hmax2,
            by subst hrun; rfl, by subst hreq; rfl,
            (UInt64.lt_iff_toNat_lt.mp hcur),
            UInt64.le_iff_toNat_le.mp hge,
            u8_le_one_cases dup hdup, u8_le_one_cases same hsame, u8_le_one_cases conf hconf, ?_⟩
    rcases hclass with ⟨hdup0, hlt⟩ | ⟨⟨hdup1, hsame1⟩, hconf0⟩
    · refine ⟨.freshWithinCapacity, ?_, UInt16.lt_iff_toNat_lt.mp hlt⟩
      subst hdup0
      rfl
    · refine ⟨.idempotentSamePayload, ?_⟩
      subst hdup1
      subst hsame1
      subst hconf0
      exact ⟨rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨active, maxC, sess, cur, runId, reqId, dup, same, conf⟩
    change (verifyInteractiveToolSlotAdmit active maxC sess cur runId reqId dup same conf == 1) = true
    dsimp [InteractiveToolSlotDomainSafe] at h
    rcases h with ⟨hmax1, hmax2, hrun, hreq, hcurPos, hge, hdup, hsame, hconf, w, hw⟩
    unfold verifyInteractiveToolSlotAdmit
    have hmaxGe : 1 ≤ maxC := UInt16.le_iff_toNat_le.mpr hmax1
    have hmaxLe : maxC ≤ 256 := by
      apply UInt16.le_iff_toNat_le.mpr
      unfold maxInteractiveToolSlotCapBound at hmax2
      exact hmax2
    have hrunB : (runId == 1) = true := by
      rw [beq_iff_eq]
      exact u8_eq_of_toNat runId 1 (by omega) hrun
    have hreqB : (reqId == 1) = true := by
      rw [beq_iff_eq]
      exact u8_eq_of_toNat reqId 1 (by omega) hreq
    have hsessB : sess > 0 := UInt64.lt_iff_toNat_lt.mpr (Nat.lt_of_lt_of_le hcurPos hge)
    have hcurB : cur > 0 := UInt64.lt_iff_toNat_lt.mpr hcurPos
    have hgeB : sess ≥ cur := UInt64.le_iff_toNat_le.mpr hge
    have hdupB : dup ≤ 1 := by
      apply UInt8.le_iff_toNat_le.mpr
      change dup.toNat ≤ 1
      omega
    have hsameB : same ≤ 1 := by
      apply UInt8.le_iff_toNat_le.mpr
      change same.toNat ≤ 1
      omega
    have hconfB : conf ≤ 1 := by
      apply UInt8.le_iff_toNat_le.mpr
      change conf.toNat ≤ 1
      omega
    cases w with
    | freshWithinCapacity =>
      rcases hw with ⟨hd0, hlt⟩
      have hdup0 : (dup == 0) = true := by
        rw [beq_iff_eq]
        exact u8_eq_of_toNat dup 0 (by omega) hd0
      have hltB : active < maxC := UInt16.lt_iff_toNat_lt.mpr hlt
      simp [hmaxGe, hmaxLe, hrunB, hreqB, hsessB, hcurB, hgeB, hdupB, hsameB, hconfB, hdup0, hltB]
    | idempotentSamePayload =>
      rcases hw with ⟨hd1, hs1, hc0⟩
      have hdup1 : (dup == 1) = true := by
        rw [beq_iff_eq]
        exact u8_eq_of_toNat dup 1 (by omega) hd1
      have hsB : (same == 1) = true := by
        rw [beq_iff_eq]
        exact u8_eq_of_toNat same 1 (by omega) hs1
      have hcB : (conf == 0) = true := by
        rw [beq_iff_eq]
        exact u8_eq_of_toNat conf 0 (by omega) hc0
      simp [hmaxGe, hmaxLe, hrunB, hreqB, hsessB, hcurB, hgeB, hdupB, hsameB, hconfB, hdup1, hsB, hcB]
  posWitness := {
    activeSlots := 63, maxCap := 64, sessionEpoch := 2, currentEpoch := 2,
    hasNonEmptyRunId := 1, hasNonEmptyRequestId := 1, isDuplicateRequestId := 0,
    samePayloadReplay := 0, conflictingDuplicate := 0
  }
  negWitness := {
    activeSlots := 64, maxCap := 64, sessionEpoch := 2, currentEpoch := 2,
    hasNonEmptyRunId := 1, hasNonEmptyRequestId := 1, isDuplicateRequestId := 0,
    samePayloadReplay := 0, conflictingDuplicate := 0
  }
  nonVacuous := by decide
  tight := by decide

def interactiveToolSlotConserved : ConservedResource InteractiveToolSlotCheck where
  admit := interactiveToolSlotMetaGate.gate
  withinCapacity c :=
    1 ≤ c.maxCap.toNat ∧ c.maxCap.toNat ≤ 256 ∧
    (c.isDuplicateRequestId.toNat = 1 ∨ c.activeSlots.toNat < c.maxCap.toNat)
  conserved c h := by
    rcases interactiveToolSlotMetaGate.sound c h with
      ⟨hmax1, hmax2, _, _, _, _, _, _, _, w, hw⟩
    refine ⟨hmax1, hmax2, ?_⟩
    cases w with
    | freshWithinCapacity => exact Or.inr hw.2
    | idempotentSamePayload => exact Or.inl hw.1

def interactiveToolSlotScoped : ScopedAuthority InteractiveToolSlotCheck where
  admit := interactiveToolSlotMetaGate.gate
  scopeValid c :=
    c.hasNonEmptyRunId.toNat = 1 ∧ c.hasNonEmptyRequestId.toNat = 1 ∧
    c.currentEpoch.toNat > 0 ∧ c.sessionEpoch.toNat ≥ c.currentEpoch.toNat
  sound c h := by
    rcases interactiveToolSlotMetaGate.sound c h with
      ⟨_, _, hrun, hreq, hcur, hge, _, _, _, _⟩
    exact ⟨hrun, hreq, hcur, hge⟩

def classifyToolSlotDuplicate (samePayloadReplay conflictingDuplicate : UInt8) :
    Option ToolSlotDuplicateClass :=
  if samePayloadReplay == 1 && conflictingDuplicate == 0 then some .idempotentReplay
  else if samePayloadReplay == 0 && conflictingDuplicate == 1 then some .conflictingDuplicate
  else none

theorem verifyInteractiveToolSlotAdmit_iff
    (activeSlots maxCap : UInt16) (sessionEpoch currentEpoch : UInt64)
    (hasRun hasReq isDup same conf : UInt8) :
    (verifyInteractiveToolSlotAdmit activeSlots maxCap sessionEpoch currentEpoch
      hasRun hasReq isDup same conf == 1) = true ↔
      InteractiveToolSlotDomainSafe
        ⟨activeSlots, maxCap, sessionEpoch, currentEpoch, hasRun, hasReq, isDup, same, conf⟩ :=
  ⟨interactiveToolSlotMetaGate.sound
      ⟨activeSlots, maxCap, sessionEpoch, currentEpoch, hasRun, hasReq, isDup, same, conf⟩,
   interactiveToolSlotMetaGate.complete
      ⟨activeSlots, maxCap, sessionEpoch, currentEpoch, hasRun, hasReq, isDup, same, conf⟩⟩

/-! ### 6. Scoped `(endpoint, server_build)` Client-Link Capability Latch (`SM-26`) -/

inductive CapabilityLatchWitness where
  | retainedWithinEpoch
  | newlyUnsupportedHttp
  deriving Repr, DecidableEq

structure CapabilityLatchCheck where
  prevLatched          : UInt8
  sameEndpoint         : UInt8
  sameServerBuild      : UInt8
  observedHttpStatus   : UInt16
  hasObservedBuild     : UInt8
  deriving Repr, DecidableEq

/-- Returns `1` iff the client-link / local-origin capability remains latched as unsupported
    under `(endpoint, server_build)` scoping (`SM-26`).
    Switching endpoints (`sameEndpoint == 0`) or observing a changed `server_build`
    (`hasObservedBuild == 1 && sameServerBuild == 0`) clears any prior latch, and transient
    non-`404`/`501` statuses never create a sticky latch. -/
@[inline, export orb_locald_verify_capability_latch]
def verifyCapabilityLatch
    (prevLatched sameEndpoint sameServerBuild : UInt8)
    (observedHttpStatus : UInt16)
    (hasObservedBuild : UInt8) : UInt8 :=
  if prevLatched ≤ 1 && sameEndpoint ≤ 1 && sameServerBuild ≤ 1 && hasObservedBuild ≤ 1 &&
     sameEndpoint == 1 &&
     (hasObservedBuild == 0 || sameServerBuild == 1) &&
     (prevLatched == 1 || observedHttpStatus == 404 || observedHttpStatus == 501) then 1 else 0

/-- Independent `(endpoint, server_build)` capability-latch specification (`ScopedAuthority`):
    a capability may be treated as unsupported only within the same endpoint and unchanged
    `server_build`, and only when either already latched in that epoch or newly answered with
    explicit HTTP `404` or `501`. -/
def CapabilityLatchDomainSafe (c : CapabilityLatchCheck) : Prop :=
  (c.prevLatched.toNat = 0 ∨ c.prevLatched.toNat = 1) ∧
  (c.sameEndpoint.toNat = 0 ∨ c.sameEndpoint.toNat = 1) ∧
  (c.sameServerBuild.toNat = 0 ∨ c.sameServerBuild.toNat = 1) ∧
  (c.hasObservedBuild.toNat = 0 ∨ c.hasObservedBuild.toNat = 1) ∧
  c.sameEndpoint.toNat = 1 ∧
  (c.hasObservedBuild.toNat = 0 ∨ c.sameServerBuild.toNat = 1) ∧
  ∃ w : CapabilityLatchWitness,
    match w with
    | .retainedWithinEpoch => c.prevLatched.toNat = 1
    | .newlyUnsupportedHttp => c.observedHttpStatus.toNat = 404 ∨ c.observedHttpStatus.toNat = 501

private theorem u16_eq_of_toNat (a : UInt16) (n : Nat) (hn : n < 65536) (h : a.toNat = n) :
    a = UInt16.ofNat n := by
  apply UInt16.eq_of_toBitVec_eq
  apply BitVec.eq_of_toNat_eq
  have hm : (UInt16.ofNat n).toBitVec.toNat = n := by
    change n % 65536 = n
    omega
  change a.toNat = _
  omega

def capabilityLatchMetaGate :
    MetaGateSpec CapabilityLatchCheck CapabilityLatchDomainSafe where
  gate c :=
    verifyCapabilityLatch c.prevLatched c.sameEndpoint c.sameServerBuild
      c.observedHttpStatus c.hasObservedBuild == 1
  sound c h := by
    rcases c with ⟨prevL, sameEp, sameB, status, hasB⟩
    change (verifyCapabilityLatch prevL sameEp sameB status hasB == 1) = true at h
    dsimp [CapabilityLatchDomainSafe]
    unfold verifyCapabilityLatch at h
    have hc :
        (prevL ≤ 1 && sameEp ≤ 1 && sameB ≤ 1 && hasB ≤ 1 &&
          sameEp == 1 && (hasB == 0 || sameB == 1) &&
          (prevL == 1 || status == 404 || status == 501)) = true := by
      cases hb :
          (prevL ≤ 1 && sameEp ≤ 1 && sameB ≤ 1 && hasB ≤ 1 &&
            sameEp == 1 && (hasB == 0 || sameB == 1) &&
            (prevL == 1 || status == 404 || status == 501))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨hpL, hsEp⟩, hsB⟩, hhB⟩, hEp1⟩, hBuildOk⟩, hTrig⟩
    refine ⟨u8_le_one_cases prevL hpL, u8_le_one_cases sameEp hsEp,
            u8_le_one_cases sameB hsB, u8_le_one_cases hasB hhB,
            by subst hEp1; rfl, ?_, ?_⟩
    · rcases hBuildOk with hh0 | hs1
      · exact Or.inl (by subst hh0; rfl)
      · exact Or.inr (by subst hs1; rfl)
    · rcases hTrig with (hp1 | h404) | h501
      · exact ⟨.retainedWithinEpoch, by subst hp1; rfl⟩
      · exact ⟨.newlyUnsupportedHttp, Or.inl (by subst h404; rfl)⟩
      · exact ⟨.newlyUnsupportedHttp, Or.inr (by subst h501; rfl)⟩
  complete c h := by
    rcases c with ⟨prevL, sameEp, sameB, status, hasB⟩
    change (verifyCapabilityLatch prevL sameEp sameB status hasB == 1) = true
    dsimp [CapabilityLatchDomainSafe] at h
    rcases h with ⟨hpL, hsEp, hsB, hhB, hEp1, hBuildOk, w, hw⟩
    unfold verifyCapabilityLatch
    have hpLB : prevL ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change prevL.toNat ≤ 1; omega
    have hsEpB : sameEp ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change sameEp.toNat ≤ 1; omega
    have hsBB : sameB ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change sameB.toNat ≤ 1; omega
    have hhBB : hasB ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change hasB.toNat ≤ 1; omega
    have hEp1B : (sameEp == 1) = true := by
      rw [beq_iff_eq]; exact u8_eq_of_toNat sameEp 1 (by omega) hEp1
    have hBuildDisj : (hasB == 0 || sameB == 1) = true := by
      rcases hBuildOk with hh0 | hs1
      · have hb0 : (hasB == 0) = true := by
          rw [beq_iff_eq]; exact u8_eq_of_toNat hasB 0 (by omega) hh0
        simp [hb0]
      · have hb1 : (sameB == 1) = true := by
          rw [beq_iff_eq]; exact u8_eq_of_toNat sameB 1 (by omega) hs1
        simp [hb1]
    cases w with
    | retainedWithinEpoch =>
      have hp1 : (prevL == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat prevL 1 (by omega) hw
      simp [hpLB, hsEpB, hsBB, hhBB, hEp1B, hBuildDisj, hp1]
    | newlyUnsupportedHttp =>
      rcases hw with h404 | h501
      · have hs404 : (status == 404) = true := by
          rw [beq_iff_eq]; exact u16_eq_of_toNat status 404 (by omega) h404
        simp [hpLB, hsEpB, hsBB, hhBB, hEp1B, hBuildDisj, hs404]
      · have hs501 : (status == 501) = true := by
          rw [beq_iff_eq]; exact u16_eq_of_toNat status 501 (by omega) h501
        simp [hpLB, hsEpB, hsBB, hhBB, hEp1B, hBuildDisj, hs501]
  posWitness := {
    prevLatched := 0, sameEndpoint := 1, sameServerBuild := 1,
    observedHttpStatus := 404, hasObservedBuild := 1
  }
  negWitness := {
    prevLatched := 1, sameEndpoint := 1, sameServerBuild := 0,
    observedHttpStatus := 200, hasObservedBuild := 1
  }
  nonVacuous := by decide
  tight := by decide

def capabilityLatchScoped : ScopedAuthority CapabilityLatchCheck where
  admit := capabilityLatchMetaGate.gate
  scopeValid c :=
    c.sameEndpoint.toNat = 1 ∧ (c.hasObservedBuild.toNat = 0 ∨ c.sameServerBuild.toNat = 1)
  sound c h := by
    rcases capabilityLatchMetaGate.sound c h with ⟨_, _, _, _, hEp, hB, _⟩
    exact ⟨hEp, hB⟩

theorem verifyCapabilityLatch_iff
    (prevLatched sameEndpoint sameServerBuild : UInt8)
    (observedHttpStatus : UInt16) (hasObservedBuild : UInt8) :
    (verifyCapabilityLatch prevLatched sameEndpoint sameServerBuild observedHttpStatus hasObservedBuild == 1) = true ↔
      CapabilityLatchDomainSafe ⟨prevLatched, sameEndpoint, sameServerBuild, observedHttpStatus, hasObservedBuild⟩ :=
  ⟨capabilityLatchMetaGate.sound ⟨prevLatched, sameEndpoint, sameServerBuild, observedHttpStatus, hasObservedBuild⟩,
   capabilityLatchMetaGate.complete ⟨prevLatched, sameEndpoint, sameServerBuild, observedHttpStatus, hasObservedBuild⟩⟩

/-! ### 7. 256-Frame Outbound Client-Link Journal Ring Backpressure & Reconnect Resync (`SM-26`) -/

def maxClientLinkOutboundFrames : Nat := 256

inductive JournalRingAdmission where
  | enqueueWithinRing
  | ackCumulativeSeq
  | reconnectResyncWindow
  deriving Repr, DecidableEq

structure JournalRingStepCheck where
  op            : UInt8
  unackedFrames : UInt16
  maxCap        : UInt16
  lastAckedSeq  : UInt64
  headSeq       : UInt64
  targetSeq     : UInt64
  deriving Repr, DecidableEq

/-- Verifies 256-frame outbound client-link journal ring steps (`SM-26`):
    - `op = 0` (`enqueueWithinRing`): requires `unackedFrames < maxCap` and `targetSeq == headSeq + 1`
      with `headSeq < UInt64.max` (explicit backpressure at 256 unacked frames; NEVER evicts oldest frame).
    - `op = 1` (`ackCumulativeSeq`): requires `lastAckedSeq ≤ targetSeq ≤ headSeq` so cumulative ACKs
      retire only buffered frames in `[lastAckedSeq + 1 .. targetSeq]`.
    - `op = 2` (`reconnectResyncWindow`): requires `targetSeq ≤ headSeq` and `lastAckedSeq ≤ headSeq`
      so reconnect resync replays from `max lastAckedSeq targetSeq` through `headSeq` without dropping tail frames. -/
@[inline, export orb_locald_verify_journal_ring_step]
def verifyJournalRingStep
    (op : UInt8)
    (unackedFrames maxCap : UInt16)
    (lastAckedSeq headSeq targetSeq : UInt64) : UInt8 :=
  if 1 ≤ maxCap && maxCap ≤ 256 &&
     unackedFrames ≤ maxCap &&
     lastAckedSeq ≤ headSeq &&
     headSeq - lastAckedSeq == unackedFrames.toUInt64 &&
     ((op == 0 && unackedFrames < maxCap && headSeq < 0xFFFFFFFFFFFFFFFF && targetSeq == headSeq + 1) ||
      (op == 1 && lastAckedSeq ≤ targetSeq && targetSeq ≤ headSeq) ||
      (op == 2 && targetSeq ≤ headSeq)) then 1 else 0

/-- Independent 256-frame outbound client-link journal specification (`ConservedResource`):
    unacked frame count equals `headSeq - lastAckedSeq ≤ maxCap ≤ 256`, fresh frame admission
    strictly requires `unackedFrames < maxCap` (backpressure rather than ring overwrite),
    and acks / reconnect cursors stay bounded by `headSeq`. -/
def JournalRingStepDomainSafe (c : JournalRingStepCheck) : Prop :=
  1 ≤ c.maxCap.toNat ∧
  c.maxCap.toNat ≤ maxClientLinkOutboundFrames ∧
  c.unackedFrames.toNat ≤ c.maxCap.toNat ∧
  c.lastAckedSeq.toNat ≤ c.headSeq.toNat ∧
  c.headSeq.toNat - c.lastAckedSeq.toNat = c.unackedFrames.toNat ∧
  ∃ w : JournalRingAdmission,
    match w with
    | .enqueueWithinRing =>
        c.op.toNat = 0 ∧
        c.unackedFrames.toNat < c.maxCap.toNat ∧
        c.headSeq.toNat < 18446744073709551615 ∧
        c.targetSeq.toNat = c.headSeq.toNat + 1
    | .ackCumulativeSeq =>
        c.op.toNat = 1 ∧
        c.lastAckedSeq.toNat ≤ c.targetSeq.toNat ∧
        c.targetSeq.toNat ≤ c.headSeq.toNat
    | .reconnectResyncWindow =>
        c.op.toNat = 2 ∧
        c.targetSeq.toNat ≤ c.headSeq.toNat

def journalRingStepMetaGate :
    MetaGateSpec JournalRingStepCheck JournalRingStepDomainSafe where
  gate c :=
    verifyJournalRingStep c.op c.unackedFrames c.maxCap c.lastAckedSeq c.headSeq c.targetSeq == 1
  sound c h := by
    rcases c with ⟨op, unacked, maxC, acked, headS, targetS⟩
    change (verifyJournalRingStep op unacked maxC acked headS targetS == 1) = true at h
    dsimp [JournalRingStepDomainSafe]
    unfold verifyJournalRingStep at h
    have hc :
        (1 ≤ maxC && maxC ≤ 256 && unacked ≤ maxC && acked ≤ headS &&
          headS - acked == unacked.toUInt64 &&
          ((op == 0 && unacked < maxC && headS < 0xFFFFFFFFFFFFFFFF && targetS == headS + 1) ||
            (op == 1 && acked ≤ targetS && targetS ≤ headS) ||
            (op == 2 && targetS ≤ headS))) = true := by
      cases hb :
          (1 ≤ maxC && maxC ≤ 256 && unacked ≤ maxC && acked ≤ headS &&
            headS - acked == unacked.toUInt64 &&
            ((op == 0 && unacked < maxC && headS < 0xFFFFFFFFFFFFFFFF && targetS == headS + 1) ||
              (op == 1 && acked ≤ targetS && targetS ≤ headS) ||
              (op == 2 && targetS ≤ headS)))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨hm1, hm2⟩, huLe⟩, haLe⟩, hdiff⟩, hbranch⟩
    have haLeN : acked.toNat ≤ headS.toNat := UInt64.le_iff_toNat_le.mp haLe
    have hdiffN : headS.toNat - acked.toNat = unacked.toNat := by
      have hd0 : (headS - acked).toNat = unacked.toUInt64.toNat := congrArg UInt64.toNat hdiff
      rw [UInt64.toNat_sub_of_le headS acked haLe, UInt16.toNat_toUInt64] at hd0
      exact hd0
    refine ⟨UInt16.le_iff_toNat_le.mp hm1, UInt16.le_iff_toNat_le.mp hm2,
            UInt16.le_iff_toNat_le.mp huLe, haLeN, hdiffN, ?_⟩
    rcases hbranch with (⟨⟨⟨hop0, hltC⟩, hheadLt⟩, htEq⟩ | ⟨⟨hop1, haT⟩, htH⟩) | ⟨hop2, htH⟩
    · have hheadLtN : headS.toNat < 18446744073709551615 := UInt64.lt_iff_toNat_lt.mp hheadLt
      have htEqN : targetS.toNat = headS.toNat + 1 := by
        subst htEq
        rw [UInt64.toNat_add]
        change (headS.toNat + 1) % 18446744073709551616 = headS.toNat + 1
        omega
      exact ⟨.enqueueWithinRing, by subst hop0; rfl, UInt16.lt_iff_toNat_lt.mp hltC, hheadLtN, htEqN⟩
    · exact ⟨.ackCumulativeSeq, by subst hop1; rfl,
              UInt64.le_iff_toNat_le.mp haT, UInt64.le_iff_toNat_le.mp htH⟩
    · exact ⟨.reconnectResyncWindow, by subst hop2; rfl, UInt64.le_iff_toNat_le.mp htH⟩
  complete c h := by
    rcases c with ⟨op, unacked, maxC, acked, headS, targetS⟩
    change (verifyJournalRingStep op unacked maxC acked headS targetS == 1) = true
    dsimp [JournalRingStepDomainSafe] at h
    rcases h with ⟨hm1, hm2, huLe, haLe, hdiff, w, hw⟩
    unfold verifyJournalRingStep
    have hm1B : 1 ≤ maxC := UInt16.le_iff_toNat_le.mpr hm1
    have hm2B : maxC ≤ 256 := by
      apply UInt16.le_iff_toNat_le.mpr
      unfold maxClientLinkOutboundFrames at hm2
      exact hm2
    have huLeB : unacked ≤ maxC := UInt16.le_iff_toNat_le.mpr huLe
    have haLeB : acked ≤ headS := UInt64.le_iff_toNat_le.mpr haLe
    have hdiffB : (headS - acked == unacked.toUInt64) = true := by
      rw [beq_iff_eq]
      apply UInt64.eq_of_toBitVec_eq
      apply BitVec.eq_of_toNat_eq
      change (headS - acked).toNat = unacked.toUInt64.toNat
      rw [UInt64.toNat_sub_of_le headS acked haLeB, UInt16.toNat_toUInt64]
      exact hdiff
    cases w with
    | enqueueWithinRing =>
      rcases hw with ⟨hop0, hltC, hheadLt, htEq⟩
      have hop0B : (op == 0) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat op 0 (by omega) hop0
      have hltCB : unacked < maxC := UInt16.lt_iff_toNat_lt.mpr hltC
      have hheadLtB : headS < 0xFFFFFFFFFFFFFFFF := UInt64.lt_iff_toNat_lt.mpr hheadLt
      have htEqB : (targetS == headS + 1) = true := by
        rw [beq_iff_eq]
        apply UInt64.eq_of_toBitVec_eq
        apply BitVec.eq_of_toNat_eq
        change targetS.toNat = (headS + 1).toNat
        rw [UInt64.toNat_add]
        change targetS.toNat = (headS.toNat + 1) % 18446744073709551616
        omega
      simp [hm1B, hm2B, huLeB, haLeB, hdiffB, hop0B, hltCB, hheadLtB, htEqB]
    | ackCumulativeSeq =>
      rcases hw with ⟨hop1, haT, htH⟩
      have hop1B : (op == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat op 1 (by omega) hop1
      have haTB : acked ≤ targetS := UInt64.le_iff_toNat_le.mpr haT
      have htHB : targetS ≤ headS := UInt64.le_iff_toNat_le.mpr htH
      simp [hm1B, hm2B, huLeB, haLeB, hdiffB, hop1B, haTB, htHB]
    | reconnectResyncWindow =>
      rcases hw with ⟨hop2, htH⟩
      have hop2B : (op == 2) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat op 2 (by omega) hop2
      have htHB : targetS ≤ headS := UInt64.le_iff_toNat_le.mpr htH
      simp [hm1B, hm2B, huLeB, haLeB, hdiffB, hop2B, htHB]
  posWitness := {
    op := 0, unackedFrames := 255, maxCap := 256,
    lastAckedSeq := 10, headSeq := 265, targetSeq := 266
  }
  negWitness := {
    op := 0, unackedFrames := 256, maxCap := 256,
    lastAckedSeq := 10, headSeq := 266, targetSeq := 267
  }
  nonVacuous := by decide
  tight := by decide

def journalRingConserved : ConservedResource JournalRingStepCheck where
  admit := journalRingStepMetaGate.gate
  withinCapacity c :=
    1 ≤ c.maxCap.toNat ∧ c.maxCap.toNat ≤ 256 ∧
    c.headSeq.toNat - c.lastAckedSeq.toNat = c.unackedFrames.toNat ∧
    (c.op.toNat ≠ 0 ∨ c.unackedFrames.toNat < c.maxCap.toNat)
  conserved c h := by
    rcases journalRingStepMetaGate.sound c h with ⟨hm1, hm2, _, _, hdiff, w, hw⟩
    refine ⟨hm1, hm2, hdiff, ?_⟩
    cases w with
    | enqueueWithinRing => exact Or.inr hw.2.1
    | ackCumulativeSeq => exact Or.inl (by omega)
    | reconnectResyncWindow => exact Or.inl (by omega)

theorem verifyJournalRingStep_iff
    (op : UInt8) (unackedFrames maxCap : UInt16) (lastAckedSeq headSeq targetSeq : UInt64) :
    (verifyJournalRingStep op unackedFrames maxCap lastAckedSeq headSeq targetSeq == 1) = true ↔
      JournalRingStepDomainSafe ⟨op, unackedFrames, maxCap, lastAckedSeq, headSeq, targetSeq⟩ :=
  ⟨journalRingStepMetaGate.sound ⟨op, unackedFrames, maxCap, lastAckedSeq, headSeq, targetSeq⟩,
   journalRingStepMetaGate.complete ⟨op, unackedFrames, maxCap, lastAckedSeq, headSeq, targetSeq⟩⟩

/-! ### 8. Typed HTTP `409` Local-Origin Conflict Disposition Gate (`SM-23` / `SM-26`) -/

/-- Typed `409 Conflict` reason codes shared across `orb-locald` and desktop local-queue callers:
    - `1 = stopping` (retryable transient stop drain)
    - `2 = non_terminal_run` (retryable transient active/claiming run)
    - `3 = already_ended` (terminal local execution closed)
    - `4 = moved` (terminal machine-transfer ownership moved)
    - `5 = stale_receipt` (terminal stale `(run_id, generation)` receipt) -/
inductive LocalConflictDisposition where
  | transientRetryableBackoff
  | terminalRetireFence
  deriving Repr, DecidableEq

structure LocalConflictGateCheck where
  httpStatus  : UInt16
  conflictTag : UInt8
  wantRetry   : UInt8
  deriving Repr, DecidableEq

/-- Verifies typed `409` conflict routing (`SM-23` / `SM-26`):
    only HTTP `409` with an explicit typed conflict tag `1..5` is admitted;
    `wantRetry == 1` admits exclusively for transient tags `{1 (stopping), 2 (non_terminal_run)}`,
    while `wantRetry == 0` admits exclusively for terminal/fenced tags `{3 (already_ended), 4 (moved), 5 (stale_receipt)}`.
    Unknown `conflictTag == 0` or non-`409` statuses fail closed (`0`). -/
@[inline, export orb_locald_verify_conflict_disposition]
def verifyLocalConflictDisposition
    (httpStatus : UInt16) (conflictTag wantRetry : UInt8) : UInt8 :=
  if httpStatus == 409 && wantRetry ≤ 1 &&
     ((wantRetry == 1 && (conflictTag == 1 || conflictTag == 2)) ||
      (wantRetry == 0 && (conflictTag == 3 || conflictTag == 4 || conflictTag == 5))) then 1 else 0

def LocalConflictDispositionDomainSafe (c : LocalConflictGateCheck) : Prop :=
  c.httpStatus.toNat = 409 ∧
  (c.wantRetry.toNat = 0 ∨ c.wantRetry.toNat = 1) ∧
  ∃ d : LocalConflictDisposition,
    match d with
    | .transientRetryableBackoff =>
        c.wantRetry.toNat = 1 ∧ (c.conflictTag.toNat = 1 ∨ c.conflictTag.toNat = 2)
    | .terminalRetireFence =>
        c.wantRetry.toNat = 0 ∧
        (c.conflictTag.toNat = 3 ∨ c.conflictTag.toNat = 4 ∨ c.conflictTag.toNat = 5)

def localConflictDispositionMetaGate :
    MetaGateSpec LocalConflictGateCheck LocalConflictDispositionDomainSafe where
  gate c := verifyLocalConflictDisposition c.httpStatus c.conflictTag c.wantRetry == 1
  sound c h := by
    rcases c with ⟨st, tag, wr⟩
    change (verifyLocalConflictDisposition st tag wr == 1) = true at h
    dsimp [LocalConflictDispositionDomainSafe]
    unfold verifyLocalConflictDisposition at h
    have hc :
        (st == 409 && wr ≤ 1 &&
          ((wr == 1 && (tag == 1 || tag == 2)) ||
            (wr == 0 && (tag == 3 || tag == 4 || tag == 5)))) = true := by
      cases hb :
          (st == 409 && wr ≤ 1 &&
            ((wr == 1 && (tag == 1 || tag == 2)) ||
              (wr == 0 && (tag == 3 || tag == 4 || tag == 5))))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨hst, hwr⟩, hdisp⟩
    refine ⟨by subst hst; rfl, u8_le_one_cases wr hwr, ?_⟩
    rcases hdisp with ⟨hwr1, ht1 | ht2⟩ | ⟨hwr0, (ht3 | ht4) | ht5⟩
    · exact ⟨.transientRetryableBackoff, by subst hwr1; rfl, Or.inl (by subst ht1; rfl)⟩
    · exact ⟨.transientRetryableBackoff, by subst hwr1; rfl, Or.inr (by subst ht2; rfl)⟩
    · exact ⟨.terminalRetireFence, by subst hwr0; rfl, Or.inl (by subst ht3; rfl)⟩
    · exact ⟨.terminalRetireFence, by subst hwr0; rfl, Or.inr (Or.inl (by subst ht4; rfl))⟩
    · exact ⟨.terminalRetireFence, by subst hwr0; rfl, Or.inr (Or.inr (by subst ht5; rfl))⟩
  complete c h := by
    rcases c with ⟨st, tag, wr⟩
    change (verifyLocalConflictDisposition st tag wr == 1) = true
    dsimp [LocalConflictDispositionDomainSafe] at h
    rcases h with ⟨hst, hwr, d, hd⟩
    unfold verifyLocalConflictDisposition
    have hstB : (st == 409) = true := by
      rw [beq_iff_eq]; exact u16_eq_of_toNat st 409 (by omega) hst
    have hwrB : wr ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change wr.toNat ≤ 1; omega
    cases d with
    | transientRetryableBackoff =>
      rcases hd with ⟨hw1, ht1 | ht2⟩
      · have hw1B : (wr == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat wr 1 (by omega) hw1
        have ht1B : (tag == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat tag 1 (by omega) ht1
        simp [hstB, hwrB, hw1B, ht1B]
      · have hw1B : (wr == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat wr 1 (by omega) hw1
        have ht2B : (tag == 2) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat tag 2 (by omega) ht2
        simp [hstB, hwrB, hw1B, ht2B]
    | terminalRetireFence =>
      rcases hd with ⟨hw0, ht3 | ht4 | ht5⟩
      · have hw0B : (wr == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat wr 0 (by omega) hw0
        have ht3B : (tag == 3) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat tag 3 (by omega) ht3
        simp [hstB, hwrB, hw0B, ht3B]
      · have hw0B : (wr == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat wr 0 (by omega) hw0
        have ht4B : (tag == 4) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat tag 4 (by omega) ht4
        simp [hstB, hwrB, hw0B, ht4B]
      · have hw0B : (wr == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat wr 0 (by omega) hw0
        have ht5B : (tag == 5) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat tag 5 (by omega) ht5
        simp [hstB, hwrB, hw0B, ht5B]
  posWitness := { httpStatus := 409, conflictTag := 2, wantRetry := 1 }
  negWitness := { httpStatus := 409, conflictTag := 5, wantRetry := 1 }
  nonVacuous := by decide
  tight := by decide

def localConflictScoped : ScopedAuthority LocalConflictGateCheck where
  admit := localConflictDispositionMetaGate.gate
  scopeValid c := c.httpStatus.toNat = 409 ∧ 1 ≤ c.conflictTag.toNat ∧ c.conflictTag.toNat ≤ 5
  sound c h := by
    rcases localConflictDispositionMetaGate.sound c h with ⟨hst, _, d, hd⟩
    refine ⟨hst, ?_⟩
    cases d with
    | transientRetryableBackoff => rcases hd with ⟨_, h1 | h2⟩ <;> omega
    | terminalRetireFence => rcases hd with ⟨_, h3 | h4 | h5⟩ <;> omega

theorem verifyLocalConflictDisposition_iff
    (httpStatus : UInt16) (conflictTag wantRetry : UInt8) :
    (verifyLocalConflictDisposition httpStatus conflictTag wantRetry == 1) = true ↔
      LocalConflictDispositionDomainSafe ⟨httpStatus, conflictTag, wantRetry⟩ :=
  ⟨localConflictDispositionMetaGate.sound ⟨httpStatus, conflictTag, wantRetry⟩,
   localConflictDispositionMetaGate.complete ⟨httpStatus, conflictTag, wantRetry⟩⟩

end OrbLocald.Spec
