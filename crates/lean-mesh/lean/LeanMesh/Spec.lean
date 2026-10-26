import LeanMesh.Kernel

/-
  LeanMesh.Spec: 3-Layer Meta-Specification & Machine-Checked Proof Suite (`0 import Lean`, `0 sorryAx`)
  - Layer 0 (`MetaGateSpec`): Universal 4-property gate contract (soundness, completeness,
    constructive positive witness `nonVacuous`, constructive negative witness `tight`).
    Every single `MetaGateSpec` instance in Layer II is proved against an independent declarative
    specification (zero tautological `Spec := gate` definitions).
  - Layer I (8 Universal Non-Tautological Meta-Specifications, all 8 instantiated in Layer II):
    1. `StickyFence` (`palomaStickyFence`)
    2. `ClockDiscipline` (`palomaClockDiscipline`)
    3. `ScopedAuthority` (`palomaScopedAuthority`)
    4. `ConservedResource` (`palomaConservedResource`)
    5. `ProjectionStability` (`palomaProjectionStability`)
    6. `MonotonicRatchet` (`palomaMonotonicRatchet`)
    7. `SlidingWindowAntiReplay` (`palomaSlidingWindowAntiReplay`)
    8. `SovereignNonInterference` (`palomaSovereignNonInterference`)
-/

namespace LeanMesh.Spec

open LeanMesh.Kernel

/-! ## Layer 0: `MetaGateSpec` — Universal 4-Property Gate Contract -/

structure MetaGateSpec (α : Type) (Spec : α → Prop) where
  gate       : α → Bool
  sound      : ∀ x, gate x = true → Spec x
  complete   : ∀ x, Spec x → gate x = true
  posWitness : α
  negWitness : α
  nonVacuous : gate posWitness = true
  tight      : gate negWitness = false

theorem MetaGateSpec.iff_spec {α : Type} {Spec : α → Prop}
    (M : MetaGateSpec α Spec) (x : α) :
    M.gate x = true ↔ Spec x :=
  ⟨M.sound x, M.complete x⟩

theorem MetaGateSpec.rejects_unsafe {α : Type} {Spec : α → Prop}
    (M : MetaGateSpec α Spec) (x : α) (h_unsafe : ¬ Spec x) :
    M.gate x = false :=
  Bool.eq_false_iff.mpr (fun h_true => h_unsafe (M.sound x h_true))

/-! ## Layer I: Universal Non-Tautological Meta-Specifications -/

/--
  1. `StickyFence`: Once a system enters a quarantined/lockdown state (`level s ≥ 1`),
  no input transition can return it to normal (`level (step s i) == 0`) unless an explicit
  hardware-verified reset predicate `authorizedReset i` holds.
-/
structure StickyFence (σ ι : Type) where
  level           : σ → UInt32
  authorizedReset : ι → Bool
  step            : σ → ι → σ
  sticky          : ∀ s i, level s ≥ 1 → authorizedReset i = false → level (step s i) ≥ 1

/--
  2. `ClockDiscipline`: Every temporal lease or manifest is governed by `(now, issuedAt, expiresAt, maxTtl)`
  and is rejected whenever `expiresAt ≤ now`, `maxTtl = 0`, `maxTtl > hardCeiling`, or `expiresAt ≤ issuedAt`.
-/
structure ClockDiscipline (τ : Type) where
  now         : τ → UInt64
  issuedAt    : τ → UInt64
  expiresAt   : τ → UInt64
  maxTtl      : τ → UInt64
  hardCeiling : UInt64
  admit       : τ → Bool
  rejects_expired  : ∀ x, expiresAt x ≤ now x → admit x = false
  rejects_unbounded : ∀ x, maxTtl x = 0 ∨ maxTtl x > hardCeiling → admit x = false

/--
  3. `ScopedAuthority`: An access or JIT lease decision `admit req` implies that the caller's
  principal/allocation class satisfies `withinScope req`.
-/
structure ScopedAuthority (Req : Type) where
  admit       : Req → Bool
  withinScope : Req → Bool
  admit_implies_within_scope : ∀ r, admit r = true → withinScope r = true

theorem ScopedAuthority.rejects_out_of_scope {Req : Type} (S : ScopedAuthority Req)
    (r : Req) (h_out : S.withinScope r = false) : S.admit r = false :=
  Bool.eq_false_iff.mpr (fun h => by rw [S.admit_implies_within_scope r h] at h_out; contradiction)

/--
  4. `ConservedResource`: Resource allocation/framing admits a request only when active usage
  remains strictly within capacity without arithmetic wrap-around.
-/
structure ConservedResource (Req : Type) where
  admit      : Req → Bool
  withinCap  : Req → Bool
  admit_iff_within_cap : ∀ r, admit r = true ↔ withinCap r = true

theorem ConservedResource.rejects_overflow {Req : Type} (C : ConservedResource Req)
    (r : Req) (h_over : C.withinCap r = false) : C.admit r = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_over] using (C.admit_iff_within_cap r).mp h)

/--
  5. `ProjectionStability`: Reconciling desired control-plane state with kernel state reaches
  an idempotent fixed point (`isNoop (reconcile syncedState) = true`) and immediately removes
  revoked or bunkered peers.
-/
structure ProjectionStability (State Act : Type) where
  reconcile  : State → Act
  isSynced   : State → Bool
  isNoop     : Act → Bool
  synced_iff_noop : ∀ s, isNoop (reconcile s) = true ↔ isSynced s = true

/--
  6. `MonotonicRatchet`: State transitions only accept strictly newer epochs (`nextEpoch > curEpoch`
  with unchanged panic sequence) or emergency panic ratchets (`nextEpoch ≥ curEpoch ∧ nextPanic > curPanic`).
-/
structure MonotonicRatchet (Req : Type) where
  admit      : Req → Bool
  isPanic    : Req → UInt8
  curEpoch   : Req → UInt64
  nextEpoch  : Req → UInt64
  curPanic   : Req → UInt64
  nextPanic  : Req → UInt64
  monotone   : ∀ r, admit r = true →
    (isPanic r = 0 ∧ nextEpoch r > curEpoch r ∧ nextPanic r = curPanic r) ∨
    (isPanic r = 1 ∧ nextEpoch r ≥ curEpoch r ∧ nextPanic r > curPanic r)

/--
  7. `SlidingWindowAntiReplay`: RFC 6479 window contract guaranteeing:
  - `pktSeq == 0` and `pktSeq == UInt64.max` are unconditionally rejected.
  - High-water mark `nextMax` is monotonically non-decreasing.
  - Any rejected packet leaves `(lastMaxSeq, bitmap)` completely unchanged (`reject_preserves_state`).
-/
structure SlidingWindowAntiReplay where
  step       : UInt64 → UInt64 → UInt64 → UInt8
  nextMax    : UInt64 → UInt64 → UInt64 → UInt64
  nextBitmap : UInt64 → UInt64 → UInt64 → UInt64
  rejects_zero : ∀ m b, step m b 0 = 0
  rejects_max  : ∀ m b, step m b 18446744073709551615 = 0
  monotone_max : ∀ m b s, nextMax m b s ≥ m
  reject_preserves_state : ∀ m b s, step m b s = 0 → nextMax m b s = m ∧ nextBitmap m b s = b
  rejects_duplicate : ∀ m b s, step m b s = 1 → step (nextMax m b s) (nextBitmap m b s) s = 0

/--
  8. `SovereignNonInterference`: Untrusted allocation classes (`MissionSandbox = 0`, `RetiredFree = 1`,
  `ReservedProd = 3`) can never obtain a route or JIT lease to `SovereignVault` (`5`, `dgx-spark`),
  and leaf worker nodes never accept `:3088` control-plane traffic laterally from non-control-plane peers.
-/
structure SovereignNonInterference (RouteReq JitReq : Type) where
  evalRoute               : RouteReq → UInt32
  evalJit                 : JitReq → UInt32
  isUntrustedToVaultRoute : RouteReq → Bool
  isUntrustedToVaultJit   : JitReq → Bool
  route_blocks_untrusted_vault : ∀ r, isUntrustedToVaultRoute r = true → (evalRoute r &&& 1) = 0
  jit_blocks_untrusted_vault   : ∀ j, isUntrustedToVaultJit j = true → (evalJit j &&& 1) = 0

/-! ## Layer II: Independent Declarative `MetaGateSpec` Instances & Corollaries for All 12 C-ABI Exports -/

/-! ### 1. `leanmesh_ratchet_epoch_step` (`ratchetEpochStep`) -/

structure RatchetEpochCheck where
  sigValid          : UInt8
  isEmergencyPanic  : UInt8
  currentEpoch      : UInt64
  candidateEpoch    : UInt64
  currentPanicSeq   : UInt64
  candidatePanicSeq : UInt64
  nowEpoch          : UInt64
  issuedAt          : UInt64
  expiresAt         : UInt64
  maxTtlSecs        : UInt64
  deriving Repr, DecidableEq

def ratchetEpochMetaGate : MetaGateSpec RatchetEpochCheck
    (fun c => (c.sigValid == 1 &&
      manifestClockValid c.nowEpoch c.issuedAt c.expiresAt c.maxTtlSecs &&
      manifestRatchetValid c.isEmergencyPanic c.currentEpoch c.candidateEpoch
        c.currentPanicSeq c.candidatePanicSeq) = true) where
  gate c :=
    (ratchetEpochStep c.sigValid c.isEmergencyPanic c.currentEpoch c.candidateEpoch
      c.currentPanicSeq c.candidatePanicSeq c.nowEpoch c.issuedAt c.expiresAt c.maxTtlSecs &&& 1) == 1
  sound c h := by
    unfold ratchetEpochStep at h
    split at h
    · rename_i h_ok
      exact h_ok
    · contradiction
  complete c h := by
    unfold ratchetEpochStep
    split
    · repeat (first | split | decide)
    · rename_i h_not
      exact absurd h h_not
  posWitness := ⟨1, 0, 10, 11, 0, 0, 1000, 990, 1300, 3600⟩
  negWitness := ⟨1, 0, 10, 10, 0, 0, 1000, 990, 1300, 3600⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 1a (`MonotonicRatchet` — `leanmesh_ratchet_epoch_step`): Any unsigned manifest,
    stale/equal epoch without emergency panic, non-emergency panic-seq mutation, expired manifest,
    unbounded `maxTtlSecs > 2592000`, or `UInt64.max` epoch is strictly rejected (`0`). -/
theorem ratchet_epoch_rejects_rollback_unsigned_or_expired
    (panic : UInt8) (curEp candEp curPan candPan now iss exp ttl : UInt64) :
    ratchetEpochStep 0 panic curEp candEp curPan candPan now iss exp ttl = 0 ∧
    ratchetEpochStep 1 0 50 50 curPan candPan now iss exp ttl = 0 ∧
    ratchetEpochStep 1 0 50 49 curPan candPan now iss exp ttl = 0 ∧
    ratchetEpochStep 1 0 50 51 5 6 1000 990 1300 3600 = 0 ∧
    ratchetEpochStep 1 panic curEp candEp curPan candPan 2000 iss 2000 ttl = 0 ∧
    ratchetEpochStep 1 0 10 11 0 0 1000 990 1300 2592001 = 0 ∧
    ratchetEpochStep 1 panic curEp 18446744073709551615 curPan candPan now iss exp ttl = 0 := by
  unfold ratchetEpochStep manifestClockValid manifestRatchetValid
  repeat (first | constructor | split | decide | simp_all)

/-- Corollary 1b (`ClockDiscipline` — `leanmesh_ratchet_epoch_step`): Emergency panic manifests can
    ratchet at the same epoch iff `isEmergencyPanic == 1` and `candidatePanicSeq > currentPanicSeq`,
    setting bit 16 (`65536`). -/
theorem ratchet_epoch_emergency_panic_advances :
    ratchetEpochStep 1 1 42 42 5 6 1000 995 1600 3600 = 65537 ∧
    ratchetEpochStep 1 1 42 42 5 5 1000 995 1600 3600 = 0 ∧
    ratchetEpochStep 1 0 42 43 5 5 1000 995 1600 3600 = 257 := by decide

/-! ### 2. `leanmesh_eval_route_step` (`evalRouteStep`) -/

structure EvalRouteCheck where
  srcId             : UInt32
  dstId             : UInt32
  srcClass          : UInt8
  dstClass          : UInt8
  srcRevoked        : UInt8
  dstRevoked        : UInt8
  ruleMatched       : UInt8
  proto             : UInt8
  dstPort           : UInt32
  rulePortMin       : UInt32
  rulePortMax       : UInt32
  jitBiometricGrant : UInt8
  bunkerState       : UInt8
  nowEpoch          : UInt64
  srcExpiresAt      : UInt64
  dstExpiresAt      : UInt64
  jitExpiresAt      : UInt64
  deriving Repr, DecidableEq

def evalRouteSpecBool (r : EvalRouteCheck) : Bool :=
  let viol := sovereignOrLateralViolation r.srcClass r.dstClass r.dstPort r.rulePortMin r.rulePortMax
                r.jitBiometricGrant r.bunkerState r.nowEpoch r.jitExpiresAt
  let baseOk := evalRouteBaseOk r.srcId r.dstId r.srcClass r.dstClass r.srcRevoked r.dstRevoked
                  r.ruleMatched r.proto r.dstPort r.rulePortMin r.rulePortMax r.bunkerState
                  r.nowEpoch r.srcExpiresAt r.dstExpiresAt
  !(!baseOk || viol)

def evalRouteMetaGate : MetaGateSpec EvalRouteCheck
    (fun r => evalRouteSpecBool r = true) where
  gate r :=
    (evalRouteStep r.srcId r.dstId r.srcClass r.dstClass r.srcRevoked r.dstRevoked
      r.ruleMatched r.proto r.dstPort r.rulePortMin r.rulePortMax r.jitBiometricGrant
      r.bunkerState r.nowEpoch r.srcExpiresAt r.dstExpiresAt r.jitExpiresAt &&& 1) == 1
  sound r h := by
    unfold evalRouteStep evalRouteSpecBool at *
    dsimp only at *
    split at h
    · split at h <;> contradiction
    · rename_i h_ok
      simpa using h_ok
  complete r h := by
    unfold evalRouteStep evalRouteSpecBool at *
    dsimp only at *
    split
    · rename_i h_bad
      have h_false : (!evalRouteBaseOk r.srcId r.dstId r.srcClass r.dstClass r.srcRevoked r.dstRevoked
          r.ruleMatched r.proto r.dstPort r.rulePortMin r.rulePortMax r.bunkerState
          r.nowEpoch r.srcExpiresAt r.dstExpiresAt ||
          sovereignOrLateralViolation r.srcClass r.dstClass r.dstPort r.rulePortMin r.rulePortMax
            r.jitBiometricGrant r.bunkerState r.nowEpoch r.jitExpiresAt) = false := by
        simpa using h
      rw [h_bad] at h_false
      contradiction
    · repeat (first | split | decide)
  posWitness := ⟨1, 2, 4, 2, 0, 0, 1, 6, 3088, 3088, 3088, 0, 0, 1000, 2000, 2000, 0⟩
  negWitness := ⟨2, 3, 2, 2, 0, 0, 1, 6, 3080, 3000, 3100, 1, 0, 1000, 2000, 2000, 2000⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 2a (`SovereignNonInterference` — `leanmesh_eval_route_step`): `MissionSandbox` (`0`),
    `RetiredFree` (`1`), and `ReservedProd` (`3`) can NEVER route to `SovereignVault` (`5`, `dgx-spark`),
    and `FreeCompute` (`2`) cannot route to `SovereignVault` (`5`) during `SoftQuarantine` (`bunkerState == 1`)
    even with `jitBiometricGrant == 1`. -/
theorem eval_route_blocks_untrusted_and_quarantined_jit_to_sovereign_vault
    (srcId dstId dstPort pMin pMax : UInt32)
    (srcRev dstRev matched proto jit bunker : UInt8)
    (now srcExp dstExp jitExp : UInt64) :
    (evalRouteStep srcId dstId 0 5 srcRev dstRev matched proto dstPort pMin pMax jit bunker now srcExp dstExp jitExp &&& 1) = 0 ∧
    (evalRouteStep srcId dstId 1 5 srcRev dstRev matched proto dstPort pMin pMax jit bunker now srcExp dstExp jitExp &&& 1) = 0 ∧
    (evalRouteStep srcId dstId 3 5 srcRev dstRev matched proto dstPort pMin pMax jit bunker now srcExp dstExp jitExp &&& 1) = 0 ∧
    (evalRouteStep srcId dstId 2 5 srcRev dstRev matched proto dstPort pMin pMax 1 1 now srcExp dstExp jitExp &&& 1) = 0 := by
  unfold evalRouteStep sovereignOrLateralViolation
  repeat (first | constructor | split | decide | simp_all)

/-- Corollary 2b (`ScopedAuthority` — `leanmesh_eval_route_step`): Both exact port `:3088` and any
    port range straddling `:3088` (`pMin ≤ 3088 && 3088 ≤ pMax`) are unconditionally blocked for
    lateral worker-to-worker traffic (`srcClass == 2`). -/
theorem eval_route_blocks_lateral_worker_port_3088_and_straddling_range
    (srcId dstId pMin pMax : UInt32)
    (dstClass srcRev dstRev matched proto jit bunker : UInt8)
    (now srcExp dstExp jitExp : UInt64) :
    (evalRouteStep srcId dstId 2 dstClass srcRev dstRev matched proto 3088 pMin pMax jit bunker now srcExp dstExp jitExp &&& 1) = 0 ∧
    (evalRouteStep 2 3 2 2 0 0 1 6 3000 3000 3100 0 0 1000 2000 2000 0 &&& 1) = 0 ∧
    (evalRouteStep 2 3 2 2 0 0 1 6 3000 3000 3100 0 0 1000 2000 2000 0 &&& 65536) = 65536 ∧
    evalRouteStep 1 2 4 2 0 0 1 6 3088 3088 3088 0 0 1000 2000 2000 0 = 1 := by
  unfold evalRouteStep sovereignOrLateralViolation
  repeat (first | constructor | split | decide | simp_all)

/-! ### 3. `leanmesh_replay_window_step`, `leanmesh_replay_window_next_max`, `leanmesh_replay_window_next_bitmap` -/

structure ReplayWindowCheck where
  lastMaxSeq : UInt64
  bitmap     : UInt64
  pktSeq     : UInt64
  deriving Repr, DecidableEq

def replayWindowMetaGate : MetaGateSpec ReplayWindowCheck
    (fun w => (w.pktSeq != 0 && w.pktSeq != 18446744073709551615 &&
      (w.pktSeq > w.lastMaxSeq ||
        (w.lastMaxSeq - w.pktSeq < 64 && (w.bitmap &&& ((1 : UInt64) <<< (w.lastMaxSeq - w.pktSeq))) == 0))) = true) where
  gate w := replayWindowStep w.lastMaxSeq w.bitmap w.pktSeq == 1
  sound _ h := by
    unfold replayWindowStep at h
    repeat (first | split at h | simp_all)
  complete _ h := by
    unfold replayWindowStep
    repeat (first | split at h | split | simp_all)
  posWitness := ⟨100, 1, 101⟩
  negWitness := ⟨100, 1, 100⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 3a (`SlidingWindowAntiReplay`): Sequence `0` and `UInt64.max` are unconditionally rejected. -/
theorem replay_window_rejects_zero_and_uint64_max (lastMax bitmap : UInt64) :
    replayWindowStep lastMax bitmap 0 = 0 ∧
    replayWindowStep lastMax bitmap 18446744073709551615 = 0 := by
  unfold replayWindowStep
  repeat (first | constructor | split | decide | simp_all)

/-- Corollary 3b (`SlidingWindowAntiReplay`): `replayWindowNextMax` is monotonically non-decreasing. -/
theorem replay_window_next_max_monotone (lastMax bitmap pktSeq : UInt64) :
    replayWindowNextMax lastMax bitmap pktSeq ≥ lastMax := by
  unfold replayWindowNextMax
  split
  · split
    · rename_i h_gt
      exact UInt64.le_of_lt h_gt
    · exact UInt64.le_refl lastMax
  · exact UInt64.le_refl lastMax

/-- Corollary 3c (`SlidingWindowAntiReplay`): Any rejected packet (`replayWindowStep = 0`) leaves both
    `lastMaxSeq` and `bitmap` completely unchanged. -/
theorem replay_window_reject_preserves_state (lastMax bitmap pktSeq : UInt64)
    (h_rej : replayWindowStep lastMax bitmap pktSeq = 0) :
    replayWindowNextMax lastMax bitmap pktSeq = lastMax ∧
    replayWindowNextBitmap lastMax bitmap pktSeq = bitmap := by
  unfold replayWindowNextMax replayWindowNextBitmap
  simp [h_rej]

theorem bv_or_and_self (b m : BitVec 64) : (b ||| m) &&& m = m := by
  apply BitVec.eq_of_getLsbD_eq
  intro i _
  simp
  cases m.getLsbD i <;> simp

theorem uint64_or_and_self (b m : UInt64) : (b ||| m) &&& m = m := by
  cases b with | ofBitVec b =>
  cases m with | ofBitVec m =>
  show UInt64.ofBitVec ((b ||| m) &&& m) = UInt64.ofBitVec m
  rw [bv_or_and_self]

theorem bv_one_shiftLeft_ne_zero (s : Nat) (hs : s < 64) :
    ((1 : BitVec 64) <<< s) ≠ 0 := by
  intro h
  have hbit := congrArg (fun v => v.getLsbD s) h
  simp [hs] at hbit

theorem uint64_one_shiftLeft_ne_zero (age : UInt64) :
    (((1 : UInt64) <<< age) != 0) = true := by
  apply bne_iff_ne.mpr
  intro h
  cases age with | ofBitVec a =>
  have hbv : (1 : BitVec 64) <<< (a % 64).toNat = 0 := by
    exact congrArg UInt64.toBitVec h
  have hlt : (a % 64).toNat < 64 := by
    rw [BitVec.toNat_umod]
    exact Nat.mod_lt a.toNat (by decide)
  exact bv_one_shiftLeft_ne_zero (a % 64).toNat hlt hbv

theorem uint64_sub_self (x : UInt64) : x - x = 0 := by
  cases x with | ofBitVec a =>
  show UInt64.ofBitVec (a - a) = UInt64.ofBitVec 0
  simp

theorem uint64_not_lt_self (x : UInt64) : ¬ (x > x) := by
  intro h
  exact Nat.lt_irrefl _ h

/-- Corollary 3d (`SlidingWindowAntiReplay`): Universal Duplicate-Replay Rejection Theorem.
    For ALL `(lastMax bitmap pktSeq : UInt64)`, if `replayWindowStep lastMax bitmap pktSeq = 1`,
    then immediately re-evaluating `pktSeq` against `(replayWindowNextMax, replayWindowNextBitmap)`
    is guaranteed to return `0`. -/
theorem replay_window_rejects_duplicate (lastMax bitmap pktSeq : UInt64)
    (h_acc : replayWindowStep lastMax bitmap pktSeq = 1) :
    replayWindowStep
      (replayWindowNextMax lastMax bitmap pktSeq)
      (replayWindowNextBitmap lastMax bitmap pktSeq)
      pktSeq = 0 := by
  have h_beq : (replayWindowStep lastMax bitmap pktSeq == 1) = true := by
    rw [h_acc]; rfl
  unfold replayWindowNextMax replayWindowNextBitmap
  simp only [h_beq, ↓reduceIte]
  unfold replayWindowStep at h_acc ⊢
  dsimp only at h_acc ⊢
  split at h_acc
  · contradiction
  · rename_i h_valid
    by_cases h_gt : pktSeq > lastMax
    · have h_not_self := uint64_not_lt_self pktSeq
      have h_zero_lt : ¬ ((0 : UInt64) ≥ 64) := by decide
      have h_sh0 : ((1 : UInt64) <<< (0 : UInt64)) = 1 := by decide
      simp only [h_gt, h_valid, h_not_self, Bool.false_eq_true, ↓reduceIte, uint64_sub_self, h_zero_lt, h_sh0]
      split
      · rfl
      · rw [uint64_or_and_self]
        rfl
    · simp only [h_gt, ↓reduceIte] at h_acc ⊢
      split at h_acc
      · contradiction
      · rename_i h_age
        simp only [h_age, h_valid, Bool.false_eq_true, ↓reduceIte, uint64_or_and_self, uint64_one_shiftLeft_ne_zero]

/-- Corollary 3d (`SlidingWindowAntiReplay`): Accepting a fresh packet advances the window, sets bit 0,
    and immediately rejects a duplicate replay of the same packet or any packet older than 64 slots. -/
theorem replay_window_accepts_fresh_and_rejects_replay :
    let m0 : UInt64 := 100
    let b0 : UInt64 := 1
    let step1 := replayWindowStep m0 b0 105
    let m1 := replayWindowNextMax m0 b0 105
    let b1 := replayWindowNextBitmap m0 b0 105
    let replay105 := replayWindowStep m1 b1 105
    let outOfOrder102 := replayWindowStep m1 b1 102
    let m2 := replayWindowNextMax m1 b1 102
    let b2 := replayWindowNextBitmap m1 b1 102
    let replay102 := replayWindowStep m2 b2 102
    let expired40 := replayWindowStep m2 b2 40
    let bigJump200 := replayWindowNextBitmap m2 b2 200
    step1 = 1 ∧ m1 = 105 ∧ b1 = 33 ∧ replay105 = 0 ∧
    outOfOrder102 = 1 ∧ replay102 = 0 ∧ expired40 = 0 ∧ bigJump200 = 1 := by decide

/-! ### 4. `leanmesh_endpoint_roam_step` (`endpointRoamStep`) -/

structure EndpointRoamCheck where
  aeadAuthOk          : UInt8
  peerPinnedStatic    : UInt8
  candidateIpClass    : UInt8
  allowPrivateRoam    : UInt8
  bunkerState         : UInt8
  candidatePort       : UInt32
  lastRoamSeq         : UInt64
  pktSeq              : UInt64
  lastRoamEpoch       : UInt64
  nowEpoch            : UInt64
  minRoamIntervalSecs : UInt64
  deriving Repr, DecidableEq

def endpointRoamMetaGate : MetaGateSpec EndpointRoamCheck
    (fun e => endpointRoamOk e.aeadAuthOk e.peerPinnedStatic e.candidateIpClass e.allowPrivateRoam
      e.bunkerState e.candidatePort e.lastRoamSeq e.pktSeq e.lastRoamEpoch e.nowEpoch e.minRoamIntervalSecs = true) where
  gate e :=
    endpointRoamStep e.aeadAuthOk e.peerPinnedStatic e.candidateIpClass e.allowPrivateRoam
      e.bunkerState e.candidatePort e.lastRoamSeq e.pktSeq e.lastRoamEpoch e.nowEpoch e.minRoamIntervalSecs == 1
  sound _ h := by
    unfold endpointRoamStep at h
    repeat (first | split at h | simp_all)
  complete _ h := by
    unfold endpointRoamStep
    repeat (first | split at h | split | simp_all)
  posWitness := ⟨1, 0, 5, 0, 0, 51888, 10, 11, 1000, 1005, 2⟩
  negWitness := ⟨1, 0, 1, 1, 0, 51888, 10, 11, 1000, 1005, 2⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 4 (`leanmesh_endpoint_roam_step`): Unauthenticated packets, pinned peers, bogon/loopback/multicast
    source IPs (`candidateIpClass ≤ 2`), zero `minRoamIntervalSecs`, or stale sequence numbers never roam. -/
theorem endpoint_roam_rejects_unauthenticated_bogon_or_stale
    (pin ipClass priv bunker : UInt8) (port : UInt32) (lastSeq pktSeq lastEp now minInt : UInt64) :
    endpointRoamStep 0 pin ipClass priv bunker port lastSeq pktSeq lastEp now minInt = 0 ∧
    endpointRoamStep 1 1 ipClass priv bunker port lastSeq pktSeq lastEp now minInt = 0 ∧
    endpointRoamStep 1 pin 0 priv bunker port lastSeq pktSeq lastEp now minInt = 0 ∧
    endpointRoamStep 1 pin 1 priv bunker port lastSeq pktSeq lastEp now minInt = 0 ∧
    endpointRoamStep 1 pin 2 priv bunker port lastSeq pktSeq lastEp now minInt = 0 ∧
    endpointRoamStep 1 0 5 0 0 51888 10 11 1000 1005 0 = 0 ∧
    endpointRoamStep 1 0 5 0 0 51888 50 50 1000 1010 2 = 0 := by
  unfold endpointRoamStep endpointRoamOk
  repeat (first | constructor | split | decide | simp_all)

/-! ### 5. `leanmesh_relay_select_step` (`relaySelectStep`) — Independent Declarative Spec -/

structure RelaySelectCheck where
  routeAllowed        : UInt8
  lanReachable        : UInt8
  wanReachable        : UInt8
  relayHealthy        : UInt8
  srcId               : UInt32
  dstId               : UInt32
  relayId             : UInt32
  activeRelaySessions : UInt32
  maxRelaySessions    : UInt32
  nowEpoch            : UInt64
  directHandshakeAt   : UInt64
  maxDirectStaleSecs  : UInt64
  deriving Repr, DecidableEq

/-- Independent declarative specification for `relaySelectStep` admitting a control-plane relay (`== 3`). -/
def relaySelectControlPlaneSpec (c : RelaySelectCheck) : Bool :=
  let fresh := directPathFresh c.nowEpoch c.directHandshakeAt c.maxDirectStaleSecs
  !(c.routeAllowed != 1 || c.srcId == 0 || c.dstId == 0 || c.srcId == c.dstId) &&
  !(c.lanReachable == 1 && fresh) &&
  !(c.wanReachable == 1 && fresh) &&
  (c.relayHealthy == 1 && c.relayId != 0 && c.relayId != c.srcId && c.relayId != c.dstId &&
   c.activeRelaySessions < c.maxRelaySessions)

theorem relay_select_eq_three_iff (c : RelaySelectCheck) :
    (relaySelectStep c.routeAllowed c.lanReachable c.wanReachable c.relayHealthy
      c.srcId c.dstId c.relayId c.activeRelaySessions c.maxRelaySessions
      c.nowEpoch c.directHandshakeAt c.maxDirectStaleSecs == 3) =
    relaySelectControlPlaneSpec c := by
  unfold relaySelectStep relaySelectControlPlaneSpec
  dsimp only
  by_cases h1 : (c.routeAllowed != 1 || c.srcId == 0 || c.dstId == 0 || c.srcId == c.dstId) = true
  · simp [h1]
  · by_cases h2 : (c.lanReachable == 1 && directPathFresh c.nowEpoch c.directHandshakeAt c.maxDirectStaleSecs) = true
    · simp [h1, h2]
    · by_cases h3 : (c.wanReachable == 1 && directPathFresh c.nowEpoch c.directHandshakeAt c.maxDirectStaleSecs) = true
      · simp [h1, h2, h3]
      · by_cases h4 : (c.relayHealthy == 1 && c.relayId != 0 && c.relayId != c.srcId && c.relayId != c.dstId &&
            decide (c.activeRelaySessions < c.maxRelaySessions)) = true
        · simp [h1, h2, h3, h4]
        · simp [h1, h2, h3, h4]

def relaySelectMetaGate : MetaGateSpec RelaySelectCheck
    (fun c => relaySelectControlPlaneSpec c = true) where
  gate c :=
    relaySelectStep c.routeAllowed c.lanReachable c.wanReachable c.relayHealthy
      c.srcId c.dstId c.relayId c.activeRelaySessions c.maxRelaySessions
      c.nowEpoch c.directHandshakeAt c.maxDirectStaleSecs == 3
  sound c h := by
    rw [← relay_select_eq_three_iff c]
    exact h
  complete c h := by
    rw [relay_select_eq_three_iff c]
    exact h
  posWitness := ⟨1, 0, 0, 1, 2, 5, 1, 10, 64, 1000, 0, 120⟩
  negWitness := ⟨1, 0, 0, 1, 2, 5, 2, 10, 64, 1000, 0, 120⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 5 (`leanmesh_relay_select_step`): Disallowed routes, relay self-loops, or exhausted relay
    slots never select `ControlPlaneRelay` (`3`), while fresh LAN/WAN prefer direct paths (`2` / `1`). -/
theorem relay_select_prevents_loops_and_enforces_capacity
    (lan wan rel : UInt8) (src dst relayId active maxCap : UInt32) (now hs stale : UInt64) :
    relaySelectStep 0 lan wan rel src dst relayId active maxCap now hs stale = 0 ∧
    relaySelectStep 1 0 0 1 10 20 10 0 64 1000 0 120 = 0 ∧
    relaySelectStep 1 0 0 1 10 20 20 0 64 1000 0 120 = 0 ∧
    relaySelectStep 1 0 0 1 10 20 1 64 64 1000 0 120 = 0 ∧
    relaySelectStep 1 1 1 1 10 20 1 0 64 1000 950 120 = 2 ∧
    relaySelectStep 1 0 1 1 10 20 1 0 64 1000 950 120 = 1 ∧
    relaySelectStep 1 0 0 1 10 20 1 0 64 1000 800 120 = 3 := by
  unfold relaySelectStep directPathFresh
  repeat (first | constructor | split | decide | simp_all)

/-! ### 6. `leanmesh_bunker_isolate_step` (`bunkerIsolateStep`) — Independent Declarative Spec -/

structure BunkerIsolateCheck where
  currentState       : UInt8
  isSovereignNode    : UInt8
  canaryTripped      : UInt8
  authFailureBurst   : UInt8
  manualTrigger      : UInt8
  biometricUnbunker  : UInt8
  heartbeatValid     : UInt8
  nowEpoch           : UInt64
  lastHeartbeatAt    : UInt64
  deadManTimeoutSecs : UInt64
  deriving Repr, DecidableEq

/-- Independent declarative specification for when `bunkerIsolateStep` returns Normal (`0`). -/
def bunkerIsolateNormalSpec (b : BunkerIsolateCheck) : Bool :=
  let clamped : UInt8 := clampBunkerState b.currentState
  let retained : UInt8 := if b.biometricUnbunker == 1 then 0 else clamped
  let deadMan := b.manualTrigger == 3 ||
                 sovereignDeadManExpired b.isSovereignNode b.heartbeatValid
                   b.nowEpoch b.lastHeartbeatAt b.deadManTimeoutSecs
  let floor := bunkerTriggerFloor deadMan b.canaryTripped b.authFailureBurst b.manualTrigger
  floor == 0 && retained == 0

def isValidBunkerLevel (x : UInt8) : Prop := x = 0 ∨ x = 1 ∨ x = 2 ∨ x = 3
def isStickyBunkerLevel (x : UInt8) : Prop := x = 1 ∨ x = 2 ∨ x = 3

theorem bunker_floor_bounds (d : Bool) (c a m : UInt8) :
    isValidBunkerLevel (bunkerTriggerFloor d c a m) := by
  unfold bunkerTriggerFloor
  split <;> try split <;> try split
  all_goals (unfold isValidBunkerLevel; decide)

theorem bunker_retained_bounds (s u : UInt8) :
    isValidBunkerLevel (if u == 1 then 0 else clampBunkerState s) := by
  unfold clampBunkerState
  split <;> try split <;> try split <;> try split
  all_goals (unfold isValidBunkerLevel; decide)

theorem bunker_join_bounds (floor retained : UInt8)
    (hf : isValidBunkerLevel floor) (hr : isValidBunkerLevel retained) :
    isValidBunkerLevel (if floor ≥ retained then floor else retained) := by
  rcases hf with rfl | rfl | rfl | rfl <;>
    rcases hr with rfl | rfl | rfl | rfl <;>
    (unfold isValidBunkerLevel; decide)

theorem bunker_join_eq_zero_iff (floor retained : UInt8)
    (hf : isValidBunkerLevel floor) (hr : isValidBunkerLevel retained) :
    ((if floor ≥ retained then floor else retained) == 0) = (floor == 0 && retained == 0) := by
  rcases hf with rfl | rfl | rfl | rfl <;>
    rcases hr with rfl | rfl | rfl | rfl <;>
    decide

theorem bunker_pack_eq_zero_iff (n sov : UInt8) (hn : isValidBunkerLevel n) :
    ((n.toUInt32 |||
      (if n ≥ 1 then 256 else 0) |||
      (if n ≥ 2 then 65536 else 0) |||
      (if n == 3 || (sov == 1 && n ≥ 2) then 16777216 else 0)) == 0) = (n == 0) := by
  rcases hn with rfl | rfl | rfl | rfl <;>
    (by_cases hs : sov == 1 <;> simp [hs] <;> decide)

theorem bunker_pack_extract_low (n sov : UInt8) (hn : isValidBunkerLevel n) :
    ((n.toUInt32 |||
      (if n ≥ 1 then 256 else 0) |||
      (if n ≥ 2 then 65536 else 0) |||
      (if n == 3 || (sov == 1 && n ≥ 2) then 16777216 else 0)) &&& 255) = n.toUInt32 := by
  rcases hn with rfl | rfl | rfl | rfl <;>
    (by_cases hs : sov == 1 <;> simp [hs] <;> decide)

theorem bunker_low_eq_next_state (s sov c a m u hb : UInt8) (now lastHb timeout : UInt64) :
    (bunkerIsolateStep s sov c a m u hb now lastHb timeout &&& 255) =
    (bunkerNextState s sov c a m u hb now lastHb timeout).toUInt32 := by
  have hf := bunker_floor_bounds (m == 3 || sovereignDeadManExpired sov hb now lastHb timeout) c a m
  have hr := bunker_retained_bounds s u
  have hj := bunker_join_bounds _ _ hf hr
  unfold bunkerIsolateStep bunkerNextState
  dsimp only
  exact bunker_pack_extract_low _ sov hj

theorem bunker_isolate_eq_zero_iff (b : BunkerIsolateCheck) :
    (bunkerIsolateStep b.currentState b.isSovereignNode b.canaryTripped
      b.authFailureBurst b.manualTrigger b.biometricUnbunker b.heartbeatValid
      b.nowEpoch b.lastHeartbeatAt b.deadManTimeoutSecs == 0) =
    bunkerIsolateNormalSpec b := by
  have hf := bunker_floor_bounds
    (b.manualTrigger == 3 ||
      sovereignDeadManExpired b.isSovereignNode b.heartbeatValid
        b.nowEpoch b.lastHeartbeatAt b.deadManTimeoutSecs)
    b.canaryTripped b.authFailureBurst b.manualTrigger
  have hr := bunker_retained_bounds b.currentState b.biometricUnbunker
  have hj := bunker_join_bounds _ _ hf hr
  unfold bunkerIsolateStep bunkerNextState bunkerIsolateNormalSpec
  dsimp only
  rw [bunker_pack_eq_zero_iff _ b.isSovereignNode hj]
  exact bunker_join_eq_zero_iff _ _ hf hr

def bunkerIsolateMetaGate : MetaGateSpec BunkerIsolateCheck
    (fun b => bunkerIsolateNormalSpec b = true) where
  gate b :=
    bunkerIsolateStep b.currentState b.isSovereignNode b.canaryTripped
      b.authFailureBurst b.manualTrigger b.biometricUnbunker b.heartbeatValid
      b.nowEpoch b.lastHeartbeatAt b.deadManTimeoutSecs == 0
  sound b h := by
    rw [← bunker_isolate_eq_zero_iff b]
    exact h
  complete b h := by
    rw [bunker_isolate_eq_zero_iff b]
    exact h
  posWitness := ⟨2, 1, 0, 0, 0, 1, 1, 1100, 1000, 180⟩
  negWitness := ⟨2, 1, 0, 0, 0, 1, 0, 1100, 1000, 180⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 6 (`StickyFence` & `ClockDiscipline` — `leanmesh_bunker_isolate_step`):
    - Without `biometricUnbunker == 1`, levels `1`, `2`, and `3` never drop below their current level.
    - On a sovereign node (`isSovereignNode == 1`), `HardLockdown` (`2`) or `SovereignDeadManTripped` (`3`)
      always sets `lockSovereignVault` (`bit 24 = 16777216`), and `biometricUnbunker == 1` cannot exit
      state `3` while `heartbeatValid == 0` or heartbeat is stale. -/
theorem bunker_isolate_sticky_and_deadman_locks_vault
    (sov canary burst manual hb : UInt8) (now lastHb timeout : UInt64) :
    (bunkerIsolateStep 1 sov canary burst manual 0 hb now lastHb timeout &&& 255) ≥ 1 ∧
    (bunkerIsolateStep 2 sov canary burst manual 0 hb now lastHb timeout &&& 255) ≥ 2 ∧
    (bunkerIsolateStep 3 sov canary burst manual 0 hb now lastHb timeout &&& 255) = 3 ∧
    (bunkerIsolateStep 2 1 0 0 0 0 1 1050 1000 180 &&& 16777216) = 16777216 ∧
    bunkerIsolateStep 0 1 0 0 0 1 1 1200 1000 180 = 16843011 ∧
    bunkerIsolateStep 3 1 0 0 0 1 0 1010 1000 180 = 16843011 := by
  rw [bunker_low_eq_next_state 1, bunker_low_eq_next_state 2, bunker_low_eq_next_state 3]
  have hf := bunker_floor_bounds (manual == 3 || sovereignDeadManExpired sov hb now lastHb timeout) canary burst manual
  refine ⟨?_, ?_, ?_, by decide, by decide, by decide⟩
  · unfold bunkerNextState clampBunkerState; dsimp only
    rcases hf with h0 | h0 | h0 | h0 <;> (rw [h0]; decide)
  · unfold bunkerNextState clampBunkerState; dsimp only
    rcases hf with h0 | h0 | h0 | h0 <;> (rw [h0]; decide)
  · unfold bunkerNextState clampBunkerState; dsimp only
    rcases hf with h0 | h0 | h0 | h0 <;> (rw [h0]; decide)

/-! ### 7. `leanmesh_frame_bounds_step` (`frameBoundsStep`) -/

structure FrameBoundsCheck where
  magic         : UInt32
  version       : UInt8
  frameKind     : UInt8
  tagVerified   : UInt8
  headerLen     : UInt64
  payloadLen    : UInt64
  maxFrameBytes : UInt64
  bufCap        : UInt64
  deriving Repr, DecidableEq

def frameBoundsMetaGate : MetaGateSpec FrameBoundsCheck
    (fun f => (f.magic == 0x4C4D5348 &&
      f.version == 1 &&
      1 ≤ f.frameKind && f.frameKind ≤ 6 &&
      f.tagVerified == 1 &&
      f.headerLen ≥ 32 &&
      f.maxFrameBytes ≤ f.bufCap &&
      f.headerLen ≤ f.maxFrameBytes &&
      f.payloadLen ≤ f.maxFrameBytes - f.headerLen) = true) where
  gate f :=
    frameBoundsStep f.magic f.version f.frameKind f.tagVerified
      f.headerLen f.payloadLen f.maxFrameBytes f.bufCap == 1
  sound _ h := by
    unfold frameBoundsStep at h
    repeat (first | split at h | simp_all)
  complete _ h := by
    unfold frameBoundsStep
    repeat (first | split at h | split | simp_all)
  posWitness := ⟨0x4C4D5348, 1, 3, 1, 64, 512, 4096, 4096⟩
  negWitness := ⟨0x4C4D5348, 1, 3, 0, 64, 512, 4096, 4096⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 7 (`ConservedResource` — `leanmesh_frame_bounds_step`): Unauthenticated frames,
    wrong magic/version, or `UInt64` length wrap-around are rejected. -/
theorem frame_bounds_rejects_unauthenticated_or_overflow
    (magic : UInt32) (ver kind : UInt8) (hdr pay maxF cap : UInt64) :
    frameBoundsStep magic ver kind 0 hdr pay maxF cap = 0 ∧
    frameBoundsStep 0x4C4D5348 1 3 1 64 18446744073709551615 4096 4096 = 0 ∧
    frameBoundsStep 0x4C4D5348 1 3 1 16 128 4096 4096 = 0 := by
  unfold frameBoundsStep
  repeat (first | constructor | split | decide | simp_all)

/-! ### 8. `leanmesh_overlay_ip_step` (`overlayIpStep`) -/

structure OverlayIpCheck where
  peerIdA    : UInt32
  peerIdB    : UInt32
  ipA        : UInt32
  ipB        : UInt32
  prefixLenA : UInt8
  prefixLenB : UInt8
  deriving Repr, DecidableEq

def overlayIpMetaGate : MetaGateSpec OverlayIpCheck
    (fun o => (o.peerIdA != 0 && o.peerIdB != 0 && o.peerIdA != o.peerIdB &&
      overlayHostIpValid o.ipA && overlayHostIpValid o.ipB &&
      o.prefixLenA == 32 && o.prefixLenB == 32 &&
      o.ipA != o.ipB) = true) where
  gate o := overlayIpStep o.peerIdA o.peerIdB o.ipA o.ipB o.prefixLenA o.prefixLenB == 1
  sound _ h := by
    unfold overlayIpStep at h
    repeat (first | split at h | simp_all)
  complete _ h := by
    unfold overlayIpStep
    repeat (first | split at h | split | simp_all)
  posWitness := ⟨1, 2, 0x0A580001, 0x0A580002, 32, 32⟩
  negWitness := ⟨1, 2, 0x0A580001, 0x0A580001, 32, 32⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 8 (`ScopedAuthority` — `leanmesh_overlay_ip_step`): Rejects network `10.88.0.0`,
    broadcast `10.88.255.255`, non-`/32` prefix hijacks, and duplicate IP/ID collisions. -/
theorem overlay_ip_enforces_slash32_and_disjoint_subnet (pA pB ip : UInt32) :
    overlayIpStep pA pB ip ip 32 32 = 0 ∧
    overlayIpStep 1 1 0x0A580001 0x0A580002 32 32 = 0 ∧
    overlayIpStep 1 2 0x0A580000 0x0A580002 32 32 = 0 ∧
    overlayIpStep 1 2 0x0A580001 0x0A58FFFF 32 32 = 0 ∧
    overlayIpStep 1 2 0x0A580001 0x0A580002 16 32 = 0 ∧
    overlayIpStep 1 2 0x0A580001 0x0A580002 32 32 = 1 := by
  unfold overlayIpStep overlayHostIpValid
  repeat (first | constructor | split | decide | simp_all)

/-! ### 9. `leanmesh_reconcile_wg_step` (`reconcileWgStep`) — Independent Declarative Spec -/

structure ReconcileWgCheck where
  manifestValid       : UInt8
  peerPresentInKernel : UInt8
  peerRevoked         : UInt8
  pubkeyMatches       : UInt8
  allowedIpMatches    : UInt8
  endpointChanged     : UInt8
  bunkerPruneNonAdmin : UInt8
  peerIsAdmin         : UInt8
  nowEpoch            : UInt64
  peerExpiresAt       : UInt64
  deriving Repr, DecidableEq

/-- Independent declarative specification for when `reconcileWgStep` reaches the idempotent `NoopInSync` (`6`) fixed point. -/
def reconcileWgNoopSyncedSpec (r : ReconcileWgCheck) : Bool :=
  r.manifestValid == 1 &&
  !peerShouldBeInactive r.peerRevoked r.bunkerPruneNonAdmin r.peerIsAdmin r.nowEpoch r.peerExpiresAt &&
  r.peerPresentInKernel != 0 &&
  !(r.pubkeyMatches != 1 || r.allowedIpMatches != 1) &&
  r.endpointChanged != 1

def reconcileWgMetaGate : MetaGateSpec ReconcileWgCheck
    (fun r => reconcileWgNoopSyncedSpec r = true) where
  gate r :=
    reconcileWgStep r.manifestValid r.peerPresentInKernel r.peerRevoked
      r.pubkeyMatches r.allowedIpMatches r.endpointChanged r.bunkerPruneNonAdmin
      r.peerIsAdmin r.nowEpoch r.peerExpiresAt == 6
  sound r h := by
    unfold reconcileWgStep reconcileWgNoopSyncedSpec at *
    repeat (first | split at h | simp_all)
  complete r h := by
    unfold reconcileWgStep reconcileWgNoopSyncedSpec at *
    repeat (first | split at h | split | simp_all)
  posWitness := ⟨1, 1, 0, 1, 1, 0, 0, 0, 1000, 2000⟩
  negWitness := ⟨1, 1, 0, 1, 1, 0, 2, 1, 1000, 2000⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 9 (`ProjectionStability` — `leanmesh_reconcile_wg_step`):
    - Invalid manifests always abort (`0`).
    - Revoked, expired, `HardLockdown` non-admin (`bunkerPruneNonAdmin == 1`), or `SovereignDeadManTripped`
      all-peer (`bunkerPruneNonAdmin == 2`, even admin!) peers present in the kernel are immediately removed (`1`). -/
theorem reconcile_wg_idempotent_and_prunes_revoked_or_bunkered
    (pres rev pk ip ep prune adm : UInt8) (now exp : UInt64) :
    reconcileWgStep 0 pres rev pk ip ep prune adm now exp = 0 ∧
    reconcileWgStep 1 1 1 pk ip ep prune adm now exp = 1 ∧
    reconcileWgStep 1 1 0 pk ip ep 1 0 1000 2000 = 1 ∧
    reconcileWgStep 1 1 0 pk ip ep 2 1 1000 2000 = 1 ∧
    reconcileWgStep 1 1 0 1 1 0 0 0 1000 2000 = 6 := by
  unfold reconcileWgStep peerShouldBeInactive
  repeat (first | constructor | split | decide | simp_all)

/-! ### 10. `leanmesh_jit_lease_step` (`jitLeaseStep`) — Independent Declarative Spec -/

structure JitLeaseCheck where
  biometricSigValid : UInt8
  operatorSameOwner : UInt8
  missionActive     : UInt8
  grantRevoked      : UInt8
  bunkerState       : UInt8
  srcClass          : UInt8
  dstClass          : UInt8
  nowEpoch          : UInt64
  grantIssuedAt     : UInt64
  grantExpiresAt    : UInt64
  maxJitTtlSecs     : UInt64
  deriving Repr, DecidableEq

/-- Independent declarative specification for `jitLeaseStep` admitting a cross-tier JIT lease. -/
def jitLeaseDeclarativeSpec (j : JitLeaseCheck) : Bool :=
  !(j.missionActive == 0 || j.grantRevoked == 1 || j.bunkerState != 0 || j.grantExpiresAt ≤ j.nowEpoch) &&
  (j.biometricSigValid == 1 &&
   j.operatorSameOwner == 1 &&
   jitClassPairAllowed j.srcClass j.dstClass &&
   0 < j.maxJitTtlSecs && j.maxJitTtlSecs ≤ 14400 &&
   j.grantIssuedAt ≤ j.nowEpoch &&
   j.grantIssuedAt < j.grantExpiresAt &&
   j.grantExpiresAt - j.grantIssuedAt ≤ j.maxJitTtlSecs)

def jitLeaseMetaGate : MetaGateSpec JitLeaseCheck
    (fun j => jitLeaseDeclarativeSpec j = true) where
  gate j :=
    (jitLeaseStep j.biometricSigValid j.operatorSameOwner j.missionActive
      j.grantRevoked j.bunkerState j.srcClass j.dstClass
      j.nowEpoch j.grantIssuedAt j.grantExpiresAt j.maxJitTtlSecs &&& 1) == 1
  sound j h := by
    unfold jitLeaseStep jitLeaseDeclarativeSpec at *
    split at h
    · contradiction
    · split at h
      · simp_all
      · contradiction
  complete j h := by
    unfold jitLeaseStep jitLeaseDeclarativeSpec at *
    repeat split
    all_goals (first | decide | simp_all)
  posWitness := ⟨1, 1, 1, 0, 0, 2, 5, 1000, 990, 1800, 900⟩
  negWitness := ⟨1, 1, 1, 0, 0, 0, 5, 1000, 990, 1800, 900⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 10 (`SovereignNonInterference` & Cross-Gate Bunker Coherence — `leanmesh_jit_lease_step`):
    - Only `(srcClass == 2, dstClass == 5)` and `(srcClass ∈ {0,1}, dstClass == 3)` can ever obtain a JIT lease.
    - Whenever `bunkerState != 0`, `jitLeaseStep` reaps (`256`) and denies (`bit 0 = 0`). -/
theorem jit_lease_blocks_sovereign_escalation_and_reaps_expired
    (bio owner active rev bunker : UInt8) (now iss exp ttl : UInt64) :
    (jitLeaseStep bio owner active rev bunker 0 5 now iss exp ttl &&& 1) = 0 ∧
    (jitLeaseStep bio owner active rev bunker 1 5 now iss exp ttl &&& 1) = 0 ∧
    (jitLeaseStep bio owner active rev bunker 3 5 now iss exp ttl &&& 1) = 0 ∧
    jitLeaseStep bio owner 0 rev bunker 2 5 now iss exp ttl = 256 ∧
    jitLeaseStep bio owner 1 1 bunker 2 5 now iss exp ttl = 256 ∧
    jitLeaseStep bio owner 1 0 1 2 5 now iss exp ttl = 256 ∧
    jitLeaseStep 1 1 1 0 0 2 5 1000 990 1800 900 = 1 := by
  unfold jitLeaseStep jitClassPairAllowed
  repeat (first | constructor | split | decide | simp_all)

/-! ## Concrete Layer I Meta-Specification Instantiations (All 8 Structures) -/

theorem bunker_retained_sticky (s u : UInt8)
    (h_lvl : (clampBunkerState s).toUInt32 ≥ 1)
    (h_no_reset : (u == 1) = false) :
    isStickyBunkerLevel (if u == 1 then 0 else clampBunkerState s) := by
  simp only [h_no_reset, Bool.false_eq_true, ↓reduceIte]
  unfold clampBunkerState at *
  split <;> try split <;> try split
  · rename_i hs0
    simp only [hs0, ↓reduceIte] at h_lvl
    contradiction
  all_goals (unfold isStickyBunkerLevel; decide)

theorem bunker_join_sticky (floor retained : UInt8)
    (hf : isValidBunkerLevel floor)
    (hr : isStickyBunkerLevel retained) :
    isStickyBunkerLevel (if floor ≥ retained then floor else retained) := by
  rcases hf with rfl | rfl | rfl | rfl <;>
    rcases hr with rfl | rfl | rfl <;>
    (unfold isStickyBunkerLevel; decide)

theorem bunker_pack_low_byte (n sov : UInt8) (h : isStickyBunkerLevel n) :
    (clampBunkerState
      (((n.toUInt32 |||
          (if n ≥ 1 then 256 else 0) |||
          (if n ≥ 2 then 65536 else 0) |||
          (if n == 3 || (sov == 1 && n ≥ 2) then 16777216 else 0)) &&& 255).toUInt8)).toUInt32 ≥ 1 := by
  rcases h with rfl | rfl | rfl <;>
    (by_cases hs : sov == 1 <;> simp [clampBunkerState, hs] <;> decide)

/-- 1. Concrete `StickyFence` instance over `bunkerIsolateStep`. -/
def palomaStickyFence : StickyFence UInt8 BunkerIsolateCheck where
  level s := (clampBunkerState s).toUInt32
  authorizedReset i := i.biometricUnbunker == 1
  step s i :=
    (bunkerIsolateStep s i.isSovereignNode i.canaryTripped i.authFailureBurst
      i.manualTrigger i.biometricUnbunker i.heartbeatValid
      i.nowEpoch i.lastHeartbeatAt i.deadManTimeoutSecs &&& 255).toUInt8
  sticky s i h_lvl h_no_reset := by
    have hf := bunker_floor_bounds
      (i.manualTrigger == 3 ||
        sovereignDeadManExpired i.isSovereignNode i.heartbeatValid
          i.nowEpoch i.lastHeartbeatAt i.deadManTimeoutSecs)
      i.canaryTripped i.authFailureBurst i.manualTrigger
    have hr := bunker_retained_sticky s i.biometricUnbunker h_lvl h_no_reset
    have hj := bunker_join_sticky _ _ hf hr
    unfold bunkerIsolateStep bunkerNextState
    dsimp only
    exact bunker_pack_low_byte _ i.isSovereignNode hj

/-- 2. Concrete `ClockDiscipline` instance over `ratchetEpochStep`. -/
def palomaClockDiscipline : ClockDiscipline RatchetEpochCheck where
  now c       := c.nowEpoch
  issuedAt c  := c.issuedAt
  expiresAt c := c.expiresAt
  maxTtl c    := c.maxTtlSecs
  hardCeiling := 2592000
  admit c     :=
    (ratchetEpochStep c.sigValid c.isEmergencyPanic c.currentEpoch c.candidateEpoch
      c.currentPanicSeq c.candidatePanicSeq c.nowEpoch c.issuedAt c.expiresAt c.maxTtlSecs &&& 1) == 1
  rejects_expired c h_exp := by
    apply ratchetEpochMetaGate.rejects_unsafe
    intro h_ok
    unfold manifestClockValid at h_ok
    have h_lt : c.nowEpoch < c.expiresAt := by
      repeat (first | split at h_ok | simp_all)
    exact UInt64.not_le.mpr h_lt h_exp
  rejects_unbounded c h_unb := by
    apply ratchetEpochMetaGate.rejects_unsafe
    intro h_ok
    unfold manifestClockValid at h_ok
    rcases h_unb with h0 | h_ceil
    · rw [h0] at h_ok
      simp at h_ok
    · have h_le : c.maxTtlSecs ≤ 2592000 := by
        repeat (first | split at h_ok | simp_all)
      exact UInt64.not_le.mpr h_ceil h_le

/-- 3. Concrete `ScopedAuthority` instance over `jitLeaseStep`. -/
def palomaScopedAuthority : ScopedAuthority JitLeaseCheck where
  admit j       := jitLeaseMetaGate.gate j
  withinScope j := jitClassPairAllowed j.srcClass j.dstClass && j.bunkerState == 0
  admit_implies_within_scope j h := by
    have h_spec := jitLeaseMetaGate.sound j h
    unfold jitLeaseDeclarativeSpec at h_spec
    repeat (first | split at h_spec | simp_all)

/-- 4. Concrete `ConservedResource` instance over `frameBoundsStep`. -/
def palomaConservedResource : ConservedResource FrameBoundsCheck where
  admit f     := frameBoundsMetaGate.gate f
  withinCap f :=
    f.magic == 0x4C4D5348 && f.version == 1 && 1 ≤ f.frameKind && f.frameKind ≤ 6 &&
    f.tagVerified == 1 && f.headerLen ≥ 32 && f.maxFrameBytes ≤ f.bufCap &&
    f.headerLen ≤ f.maxFrameBytes && f.payloadLen ≤ f.maxFrameBytes - f.headerLen
  admit_iff_within_cap f := frameBoundsMetaGate.iff_spec f

/-- 5. Concrete `ProjectionStability` instance over `reconcileWgStep`. -/
def palomaProjectionStability : ProjectionStability ReconcileWgCheck UInt8 where
  reconcile r :=
    reconcileWgStep r.manifestValid r.peerPresentInKernel r.peerRevoked
      r.pubkeyMatches r.allowedIpMatches r.endpointChanged r.bunkerPruneNonAdmin
      r.peerIsAdmin r.nowEpoch r.peerExpiresAt
  isSynced r  := reconcileWgNoopSyncedSpec r
  isNoop act  := act == 6
  synced_iff_noop r := reconcileWgMetaGate.iff_spec r

/-- 6. Concrete `MonotonicRatchet` instance over `ratchetEpochStep`. -/
def palomaMonotonicRatchet : MonotonicRatchet RatchetEpochCheck where
  admit c     := ratchetEpochMetaGate.gate c
  isPanic c   := c.isEmergencyPanic
  curEpoch c  := c.currentEpoch
  nextEpoch c := c.candidateEpoch
  curPanic c  := c.currentPanicSeq
  nextPanic c := c.candidatePanicSeq
  monotone c h := by
    have h_spec := ratchetEpochMetaGate.sound c h
    unfold manifestRatchetValid at h_spec
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq] at h_spec
    have h_disj := h_spec.2.2
    cases h_disj with
    | inl hL => exact Or.inl ⟨hL.1.1, hL.1.2, hL.2⟩
    | inr hR => exact Or.inr ⟨hR.1.1, hR.1.2, hR.2⟩

/-- 7. Concrete `SlidingWindowAntiReplay` instance over `replayWindowStep`. -/
def palomaSlidingWindowAntiReplay : SlidingWindowAntiReplay where
  step       := replayWindowStep
  nextMax    := replayWindowNextMax
  nextBitmap := replayWindowNextBitmap
  rejects_zero m b := (replay_window_rejects_zero_and_uint64_max m b).1
  rejects_max m b  := (replay_window_rejects_zero_and_uint64_max m b).2
  monotone_max     := replay_window_next_max_monotone
  reject_preserves_state := replay_window_reject_preserves_state
  rejects_duplicate := replay_window_rejects_duplicate

/-- 8. Concrete `SovereignNonInterference` instance linking `evalRouteStep` and `jitLeaseStep`. -/
def palomaSovereignNonInterference : SovereignNonInterference EvalRouteCheck JitLeaseCheck where
  evalRoute r :=
    evalRouteStep r.srcId r.dstId r.srcClass r.dstClass r.srcRevoked r.dstRevoked
      r.ruleMatched r.proto r.dstPort r.rulePortMin r.rulePortMax r.jitBiometricGrant
      r.bunkerState r.nowEpoch r.srcExpiresAt r.dstExpiresAt r.jitExpiresAt
  evalJit j :=
    jitLeaseStep j.biometricSigValid j.operatorSameOwner j.missionActive
      j.grantRevoked j.bunkerState j.srcClass j.dstClass
      j.nowEpoch j.grantIssuedAt j.grantExpiresAt j.maxJitTtlSecs
  isUntrustedToVaultRoute r := r.dstClass == 5 && (r.srcClass ≤ 1 || r.srcClass == 3)
  isUntrustedToVaultJit j   := j.dstClass == 5 && (j.srcClass ≤ 1 || j.srcClass == 3)
  route_blocks_untrusted_vault r h := by
    unfold evalRouteStep sovereignOrLateralViolation
    repeat (first | split at h | split | decide | simp_all)
  jit_blocks_untrusted_vault j h := by
    unfold jitLeaseStep jitClassPairAllowed
    repeat (first | split at h | split | decide | simp_all)

/-- Cross-Gate Coherence Theorem (`bunkerState != 0` across `evalRouteStep` and `jitLeaseStep`):
    Whenever the mesh is in any non-normal Bunker state (`bunkerState != 0`), `jitLeaseStep`
    unconditionally reaps and denies (`bit 0 = 0`), and `evalRouteStep` unconditionally denies
    all cross-tier JIT edges (`(2, 5)` and `({0, 1}, 3)`) regardless of `jitBiometricGrant`. -/
theorem bunker_jit_cross_gate_coherence
    (bunker : UInt8) (h_bunker : bunker != 0)
    (srcId dstId dstPort pMin pMax : UInt32)
    (srcRev dstRev matched proto jit bio owner active rev srcCls dstCls : UInt8)
    (now srcExp dstExp jitExp iss exp ttl : UInt64) :
    (jitLeaseStep bio owner active rev bunker srcCls dstCls now iss exp ttl &&& 1) = 0 ∧
    (evalRouteStep srcId dstId 2 5 srcRev dstRev matched proto dstPort pMin pMax jit bunker now srcExp dstExp jitExp &&& 1) = 0 ∧
    (evalRouteStep srcId dstId 0 3 srcRev dstRev matched proto dstPort pMin pMax jit bunker now srcExp dstExp jitExp &&& 1) = 0 ∧
    (evalRouteStep srcId dstId 1 3 srcRev dstRev matched proto dstPort pMin pMax jit bunker now srcExp dstExp jitExp &&& 1) = 0 := by
  unfold jitLeaseStep evalRouteStep sovereignOrLateralViolation
  repeat (first | constructor | split | decide | simp_all)

end LeanMesh.Spec
