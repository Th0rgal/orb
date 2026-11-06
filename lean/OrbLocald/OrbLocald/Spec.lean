/-
  OrbLocald.Spec — Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for the desktop daemon (`orb-locald`):
    1. Loopback RPC origin & per-launch bearer token admission (`ScopedAuthority`)
    2. Transport proxy SSE shard count & unprivileged port bounds (`ConservedResource`)
    3. Transport 3-way failover retry idempotency gate (`Idempotency-Key` required for mutations)
    4. Paloma Touch ID grace reuse gate (`POST /api/bitwarden/requests/<uuid>/approve|reject`)
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

def minLaunchBearerEntropyBytes : Nat := 16
def maxLaunchBearerBytes : Nat := 4096

def verifyLocaldRpcAuth (isLoopback tokenMatches : UInt8) (tokenLen : UInt32) : UInt8 :=
  if isLoopback == 1 && tokenMatches == 1 && tokenLen ≥ 16 && tokenLen ≤ 4096 then 1 else 0

/-- Independent loopback IPC authority specification over `Nat` entropy bounds. -/
def LocaldRpcAuthDomainSafe (c : UInt8 × UInt8 × UInt32) : Prop :=
  c.1.toNat = 1 ∧
  c.2.1.toNat = 1 ∧
  minLaunchBearerEntropyBytes ≤ c.2.2.toNat ∧
  c.2.2.toNat ≤ maxLaunchBearerBytes

def localdRpcAuthMetaGate : MetaGateSpec (UInt8 × UInt8 × UInt32) LocaldRpcAuthDomainSafe where
  gate c := verifyLocaldRpcAuth c.1 c.2.1 c.2.2 == 1
  sound c h := by
    rcases c with ⟨lb, tm, tL⟩
    change (verifyLocaldRpcAuth lb tm tL == 1) = true at h
    dsimp [LocaldRpcAuthDomainSafe]
    unfold verifyLocaldRpcAuth at h
    have hc : (lb == 1 && tm == 1 && tL ≥ 16 && tL ≤ 4096) = true := by
      cases hb : (lb == 1 && tm == 1 && tL ≥ 16 && tL ≤ 4096)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨hlb, htm⟩, hl1⟩, hl2⟩
    exact ⟨by subst hlb; rfl, by subst htm; rfl,
      UInt32.le_iff_toNat_le.mp hl1, UInt32.le_iff_toNat_le.mp hl2⟩
  complete c h := by
    rcases c with ⟨lb, tm, tL⟩
    change (verifyLocaldRpcAuth lb tm tL == 1) = true
    dsimp [LocaldRpcAuthDomainSafe] at h
    rcases h with ⟨hlb, htm, hl1, hl2⟩
    unfold verifyLocaldRpcAuth
    have hlbB : (lb == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat lb 1 (by omega) hlb
    have htmB : (tm == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat tm 1 (by omega) htm
    have hlGe : tL ≥ 16 := UInt32.le_iff_toNat_le.mpr hl1
    have hlLe : tL ≤ 4096 := UInt32.le_iff_toNat_le.mpr hl2
    simp [hlbB, htmB, hlGe, hlLe]
  posWitness := (1, 1, 32)
  negWitness := (0, 1, 32)
  nonVacuous := by decide
  tight := by decide

theorem verifyLocaldRpcAuth_iff (isLoopback tokenMatches : UInt8) (tokenLen : UInt32) :
    (verifyLocaldRpcAuth isLoopback tokenMatches tokenLen == 1) = true ↔
      LocaldRpcAuthDomainSafe (isLoopback, tokenMatches, tokenLen) :=
  ⟨localdRpcAuthMetaGate.sound (isLoopback, tokenMatches, tokenLen),
   localdRpcAuthMetaGate.complete (isLoopback, tokenMatches, tokenLen)⟩

/-! ### 2. Transport Bridge SSE Shard Count & Unprivileged Port Bounds -/

def firstUnprivilegedTcpPort : Nat := 1024
def maxSseShards : Nat := 16

def verifySseShardConfig (shardCount : UInt8) (proxyPort : UInt16) : UInt8 :=
  if shardCount ≥ 1 && shardCount ≤ 16 && proxyPort ≥ 1024 then 1 else 0

/-- Independent SSE pool & non-root port specification (`ConservedResource`). -/
def SseShardConfigDomainSafe (c : UInt8 × UInt16) : Prop :=
  1 ≤ c.1.toNat ∧
  c.1.toNat ≤ maxSseShards ∧
  firstUnprivilegedTcpPort ≤ c.2.toNat

def sseShardConfigMetaGate : MetaGateSpec (UInt8 × UInt16) SseShardConfigDomainSafe where
  gate c := verifySseShardConfig c.1 c.2 == 1
  sound c h := by
    rcases c with ⟨sc, pp⟩
    change (verifySseShardConfig sc pp == 1) = true at h
    dsimp [SseShardConfigDomainSafe]
    unfold verifySseShardConfig at h
    have hc : (sc ≥ 1 && sc ≤ 16 && pp ≥ 1024) = true := by
      cases hb : (sc ≥ 1 && sc ≤ 16 && pp ≥ 1024)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨hs1, hs2⟩, hp⟩
    exact ⟨UInt8.le_iff_toNat_le.mp hs1, UInt8.le_iff_toNat_le.mp hs2, UInt16.le_iff_toNat_le.mp hp⟩
  complete c h := by
    rcases c with ⟨sc, pp⟩
    change (verifySseShardConfig sc pp == 1) = true
    dsimp [SseShardConfigDomainSafe] at h
    rcases h with ⟨hs1, hs2, hp⟩
    unfold verifySseShardConfig
    have hsGe : sc ≥ 1 := UInt8.le_iff_toNat_le.mpr hs1
    have hsLe : sc ≤ 16 := UInt8.le_iff_toNat_le.mpr hs2
    have hpGe : pp ≥ 1024 := UInt16.le_iff_toNat_le.mpr hp
    simp [hsGe, hsLe, hpGe]
  posWitness := (4, 18080)
  negWitness := (4, 80)
  nonVacuous := by decide
  tight := by decide

theorem verifySseShardConfig_iff (shardCount : UInt8) (proxyPort : UInt16) :
    (verifySseShardConfig shardCount proxyPort == 1) = true ↔
      SseShardConfigDomainSafe (shardCount, proxyPort) :=
  ⟨sseShardConfigMetaGate.sound (shardCount, proxyPort),
   sseShardConfigMetaGate.complete (shardCount, proxyPort)⟩

/-! ### 3. Transport 3-Way Failover Retry Idempotency Gate -/

inductive RetrySafetyProof where
  | rfc9110SafeMethod
  | explicitIdempotencyKey
  deriving Repr, DecidableEq

def verifyTransportWriteRetry (isSafeMethod hasIdempotencyKey nextOriginIdx originCount : UInt8) : UInt8 :=
  if originCount ≥ 1 && originCount ≤ 16 && nextOriginIdx < originCount &&
     (isSafeMethod == 1 || hasIdempotencyKey == 1) then 1 else 0

/-- Independent failover retry safety specification:
    origin pool has `1..16` endpoints, `nextOriginIdx + 1 ≤ originCount`, and there exists a
    `RetrySafetyProof` witnessing that replaying the request across origins cannot duplicate writes. -/
def TransportWriteRetryDomainSafe (c : UInt8 × UInt8 × UInt8 × UInt8) : Prop :=
  1 ≤ c.2.2.2.toNat ∧
  c.2.2.2.toNat ≤ 16 ∧
  c.2.2.1.toNat + 1 ≤ c.2.2.2.toNat ∧
  ∃ w : RetrySafetyProof,
    match w with
    | .rfc9110SafeMethod      => c.1.toNat = 1
    | .explicitIdempotencyKey => c.2.1.toNat = 1

def transportWriteRetryMetaGate :
    MetaGateSpec (UInt8 × UInt8 × UInt8 × UInt8) TransportWriteRetryDomainSafe where
  gate c := verifyTransportWriteRetry c.1 c.2.1 c.2.2.1 c.2.2.2 == 1
  sound c h := by
    rcases c with ⟨isS, hasIk, nIdx, cnt⟩
    change (verifyTransportWriteRetry isS hasIk nIdx cnt == 1) = true at h
    dsimp [TransportWriteRetryDomainSafe]
    unfold verifyTransportWriteRetry at h
    have hc : (cnt ≥ 1 && cnt ≤ 16 && nIdx < cnt && (isS == 1 || hasIk == 1)) = true := by
      cases hb : (cnt ≥ 1 && cnt ≤ 16 && nIdx < cnt && (isS == 1 || hasIk == 1))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨hc1, hc2⟩, hlt⟩, hw⟩
    have hltN : nIdx.toNat < cnt.toNat := UInt8.lt_iff_toNat_lt.mp hlt
    refine ⟨UInt8.le_iff_toNat_le.mp hc1, UInt8.le_iff_toNat_le.mp hc2, by omega, ?_⟩
    rcases hw with hs | hik
    · exact ⟨.rfc9110SafeMethod, by subst hs; rfl⟩
    · exact ⟨.explicitIdempotencyKey, by subst hik; rfl⟩
  complete c h := by
    rcases c with ⟨isS, hasIk, nIdx, cnt⟩
    change (verifyTransportWriteRetry isS hasIk nIdx cnt == 1) = true
    dsimp [TransportWriteRetryDomainSafe] at h
    rcases h with ⟨hc1, hc2, hlt, w, hw⟩
    unfold verifyTransportWriteRetry
    have hcGe : cnt ≥ 1 := UInt8.le_iff_toNat_le.mpr hc1
    have hcLe : cnt ≤ 16 := UInt8.le_iff_toNat_le.mpr hc2
    have hltB : nIdx < cnt := by apply UInt8.lt_iff_toNat_lt.mpr; omega
    cases w with
    | rfc9110SafeMethod =>
      have hsB : (isS == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat isS 1 (by omega) hw
      simp [hcGe, hcLe, hltB, hsB]
    | explicitIdempotencyKey =>
      have hikB : (hasIk == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hasIk 1 (by omega) hw
      simp [hcGe, hcLe, hltB, hikB]
  posWitness := (0, 1, 1, 3)
  negWitness := (0, 0, 1, 3)
  nonVacuous := by decide
  tight := by decide

theorem verifyTransportWriteRetry_iff (isSafe hasIdem nextIdx count : UInt8) :
    (verifyTransportWriteRetry isSafe hasIdem nextIdx count == 1) = true ↔
      TransportWriteRetryDomainSafe (isSafe, hasIdem, nextIdx, count) :=
  ⟨transportWriteRetryMetaGate.sound (isSafe, hasIdem, nextIdx, count),
   transportWriteRetryMetaGate.complete (isSafe, hasIdem, nextIdx, count)⟩

/-! ### 4. Paloma Touch ID Grace Reuse Gate -/

def canonicalUuidHyphenatedBytes : Nat := 36

def verifyPalomaGraceEligible (isPost isBitwardenReq : UInt8) (uuidLen : UInt32) (isApproveOrReject : UInt8) : UInt8 :=
  if isPost == 1 && isBitwardenReq == 1 && uuidLen == 36 && isApproveOrReject == 1 then 1 else 0

/-- Independent Touch ID grace reuse scope specification (`ScopedAuthority`). -/
def PalomaGraceDomainSafe (c : UInt8 × UInt8 × UInt32 × UInt8) : Prop :=
  c.1.toNat = 1 ∧
  c.2.1.toNat = 1 ∧
  c.2.2.1.toNat = canonicalUuidHyphenatedBytes ∧
  c.2.2.2.toNat = 1

def palomaGraceMetaGate : MetaGateSpec (UInt8 × UInt8 × UInt32 × UInt8) PalomaGraceDomainSafe where
  gate c := verifyPalomaGraceEligible c.1 c.2.1 c.2.2.1 c.2.2.2 == 1
  sound c h := by
    rcases c with ⟨ip, ib, uL, ia⟩
    change (verifyPalomaGraceEligible ip ib uL ia == 1) = true at h
    dsimp [PalomaGraceDomainSafe]
    unfold verifyPalomaGraceEligible at h
    have hc : (ip == 1 && ib == 1 && uL == 36 && ia == 1) = true := by
      cases hb : (ip == 1 && ib == 1 && uL == 36 && ia == 1)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨hip, hib⟩, huL⟩, hia⟩
    subst hip; subst hib
    subst huL; subst hia
    exact ⟨rfl, rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨ip, ib, uL, ia⟩
    change (verifyPalomaGraceEligible ip ib uL ia == 1) = true
    dsimp [PalomaGraceDomainSafe] at h
    rcases h with ⟨hip, hib, huL, hia⟩
    unfold verifyPalomaGraceEligible
    have hipB : (ip == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ip 1 (by omega) hip
    have hibB : (ib == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ib 1 (by omega) hib
    have huLB : (uL == 36) = true := by
      rw [beq_iff_eq]
      apply UInt32.eq_of_toBitVec_eq
      apply BitVec.eq_of_toNat_eq
      change uL.toNat = 36
      exact huL
    have hiaB : (ia == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ia 1 (by omega) hia
    simp [hipB, hibB, huLB, hiaB]
  posWitness := (1, 1, 36, 1)
  negWitness := (1, 0, 36, 1)
  nonVacuous := by decide
  tight := by decide

theorem verifyPalomaGraceEligible_iff (isPost isBw : UInt8) (uuidLen : UInt32) (isAct : UInt8) :
    (verifyPalomaGraceEligible isPost isBw uuidLen isAct == 1) = true ↔
      PalomaGraceDomainSafe (isPost, isBw, uuidLen, isAct) :=
  ⟨palomaGraceMetaGate.sound (isPost, isBw, uuidLen, isAct),
   palomaGraceMetaGate.complete (isPost, isBw, uuidLen, isAct)⟩

end OrbLocald.Spec
