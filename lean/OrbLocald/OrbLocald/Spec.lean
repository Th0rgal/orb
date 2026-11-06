/-
  OrbLocald.Spec — Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for the desktop daemon (`orb-locald`):
    1. Loopback RPC origin & per-launch bearer token admission (`ScopedAuthority`, ≥ 32-byte entropy)
    2. Transport proxy SSE shard count & unprivileged port bounds (`ConservedResource`)
    3. Transport 3-way failover retry idempotency gate (`RetrySafetyProof` + canonical `{0,1}` flags)
    4. Paloma Touch ID grace reuse gate (`PalomaGraceAction`, `ScopedAuthority`)
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

end OrbLocald.Spec
