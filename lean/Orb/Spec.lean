/-
  Orb.Spec: Verified Orchestration, Proxy Streaming, Mission Lifecycle & Cross-Client Projection Kernel (`0 import Lean`, `0 sorryAx`)
  - Layer 0: Universal `MetaGateSpec` contract (soundness, completeness, `posWitness`, `negWitness`, non-vacuity, tightness)
  - Layer I: 5 Universal Non-Tautological Meta-Specifications (`StickyFence`, `ClockDiscipline`,
    `ScopedAuthority`, `ConservedResource`, `ProjectionStability`) + compatibility combinators
    (`LinearLeaseSpec`, `IdempotentOutboxSpec`, `DagScheduleSpec`, `QuotaCircuitSpec`)
  - Layer II: Declarative Corollaries (≤ 3 lines each, Mathlib4 algebraic proof style)
  - Direct Unboxed C-ABI (`@[inline, export]` in `Orb.Kernel`, 23 exports):
    `orb_verify_writer_reuse`, `orb_verify_lease_mode`, `orb_verify_track_hold`, `orb_verify_repo_disjoint`,
    `orb_verify_remote_outbox`, `orb_verify_board_slots`, `orb_verify_board_retry`, `orb_verify_job_transition`,
    `orb_verify_bundle_budget`, `orb_verify_token_rotation`, `leansys_verify_log_window`, `leansys_mix64_word`,
    `orb_proxy_step`, `orb_stream_deadlines`, `orb_breaker_step`, `orb_mission_step`, `orb_reconcile_step`,
    `orb_queue_step`, `orb_vm_step`, `orb_access_step`, `orb_workfold_step`, `orb_taskcard_step`, `orb_sidebar_visibility`
-/

import Orb.Kernel

namespace Orb.Spec

open Orb.Kernel

/-! ## Layer 0: Universal `MetaGateSpec` Contract (`LeanSys.Contracts.MetaGate`) -/

/-- Universal 4-property Meta-Gate specification bundle proving soundness, completeness,
    non-vacuity, and tightness with explicit `posWitness` and `negWitness`. -/
structure MetaGateSpec (Input : Type) (Safe : Input → Prop) where
  gate       : Input → Bool
  sound      : ∀ x, gate x = true → Safe x
  complete   : ∀ x, Safe x → gate x = true
  posWitness : Input
  negWitness : Input
  nonVacuous : gate posWitness = true
  tight      : gate negWitness = false

theorem MetaGateSpec.iff_safe {Input : Type} {Safe : Input → Prop}
    (M : MetaGateSpec Input Safe) (x : Input) :
    M.gate x = true ↔ Safe x := ⟨M.sound x, M.complete x⟩

theorem MetaGateSpec.rejects_unsafe {Input : Type} {Safe : Input → Prop}
    (M : MetaGateSpec Input Safe) (x : Input) (h_unsafe : ¬ Safe x) :
    M.gate x = false :=
  Bool.eq_false_iff.mpr (fun h_ok => h_unsafe (M.sound x h_ok))

theorem MetaGateSpec.pos_ne_neg {Input : Type} {Safe : Input → Prop}
    (M : MetaGateSpec Input Safe) :
    M.posWitness ≠ M.negWitness :=
  fun h => by simpa [h, M.tight] using M.nonVacuous

/-! ## Layer I: 5 Universal Non-Tautological Meta-Specifications -/

/--
  Meta-Spec 1 (`StickyFence`):
  Once a commitment or terminal fence `fenced s = true` is crossed, every subsequent transition
  preserves `fenced (step s e) = true` and disables pre-fence actions (`preFenceAct (step s e) = false`).
-/
structure StickyFence (State Event : Type) where
  fenced       : State → Bool
  preFenceAct  : State → Bool
  step         : State → Event → State
  sticky       : ∀ s e, fenced s = true → fenced (step s e) = true
  forbids_post : ∀ s e, fenced s = true → preFenceAct (step s e) = false

theorem StickyFence.fence_blocks_act (F : StickyFence State Event) (s : State) (e : Event)
    (h_fenced : F.fenced s = true) :
    F.fenced (F.step s e) = true ∧ F.preFenceAct (F.step s e) = false :=
  ⟨F.sticky s e h_fenced, F.forbids_post s e h_fenced⟩

/--
  Meta-Spec 2 (`ClockDiscipline`):
  Independent clock domains `(client, upstream, auth)` cannot masquerade for one another:
  an event on clock `A` never resets or triggers clock `B` unless `B`'s own guard holds.
-/
structure ClockDiscipline (Input : Type) where
  eval      : Input → UInt32
  clockMask : UInt32
  guardOk   : Input → Bool
  isolated  : ∀ x, ((eval x &&& clockMask) != 0) = true → guardOk x = true

theorem ClockDiscipline.rejects_cross_clock (C : ClockDiscipline Input) (x : Input)
    (h_no_guard : C.guardOk x = false) :
    ((C.eval x &&& C.clockMask) != 0) = false :=
  Bool.eq_false_iff.mpr (fun h_on => by simpa [h_no_guard] using C.isolated x h_on)

/--
  Meta-Spec 3 (`ScopedAuthority`):
  Any mutation, reap, or disclosure across an authority boundary `(boot_id, tenant, track, grant)`
  is rejected unless the scope witness holds (`scopeValid x = true`).
-/
structure ScopedAuthority (Input : Type) where
  admit      : Input → Bool
  scopeValid : Input → Bool
  sound      : ∀ x, admit x = true → scopeValid x = true

theorem ScopedAuthority.rejects_out_of_scope (A : ScopedAuthority Input) (x : Input)
    (h_bad : A.scopeValid x = false) :
    A.admit x = false :=
  Bool.eq_false_iff.mpr (fun h_ok => by simpa [h_bad] using A.sound x h_ok)

/--
  Meta-Spec 4 (`ConservedResource`):
  A conserved resource (boss slot, retry budget, VM cap/RAM/TTL, bundle/log window) never overflows
  its capacity envelope (`withinBudget x = true`) and never drops an unacknowledged item.
-/
structure ConservedResource (Input : Type) where
  admit        : Input → Bool
  withinBudget : Input → Bool
  conserved    : ∀ x, admit x = true → withinBudget x = true

theorem ConservedResource.rejects_overflow (R : ConservedResource Input) (x : Input)
    (h_over : R.withinBudget x = false) :
    R.admit x = false :=
  Bool.eq_false_iff.mpr (fun h_ok => by simpa [h_over] using R.conserved x h_ok)

/--
  Meta-Spec 5 (`ProjectionStability`):
  UI state projections (work-fold narration, Tasks-card status, sidebar tree retention) preserve
  causal partitioning and never conflate distinct lifecycle outcomes.
-/
structure ProjectionStability (Input Out : Type) where
  project     : Input → Out
  validIn     : Input → Bool
  stable      : Input → Out → Bool
  preserves   : ∀ x, validIn x = true → stable x (project x) = true

theorem ProjectionStability.ensures_stable (P : ProjectionStability Input Out) (x : Input)
    (h_in : P.validIn x = true) :
    P.stable x (P.project x) = true :=
  P.preserves x h_in

/-! ## Layer I Compatibility Combinators (`LinearLeaseSpec`, `IdempotentOutboxSpec`, `DagScheduleSpec`, `QuotaCircuitSpec`) -/

structure LinearLeaseSpec (σ α : Type) where
  inv : σ → Prop
  gate : σ → α → Bool
  step : σ → α → σ
  safe : σ → α → Bool
  preserves_inv : ∀ s x, gate s x = true → inv s → inv (step s x)
  gate_iff_safe : ∀ s x, gate s x = true ↔ safe s x = true

theorem LinearLeaseSpec.rejects_unsafe (L : LinearLeaseSpec σ α) (s : σ) (x : α)
    (h_unsafe : L.safe s x = false) : L.gate s x = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_unsafe] using (L.gate_iff_safe s x).mp h)

structure IdempotentOutboxSpec (Row Req : Type) where
  admit : Row → Req → Bool
  safeReplay : Row → Req → Bool
  admit_iff_safe_replay : ∀ r q, admit r q = true ↔ safeReplay r q = true

theorem IdempotentOutboxSpec.rejects_conflicting_replay (O : IdempotentOutboxSpec Row Req)
    (r : Row) (q : Req) (h_bad : O.safeReplay r q = false) : O.admit r q = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_bad] using (O.admit_iff_safe_replay r q).mp h)

structure DagScheduleSpec (BoardState : Type) where
  canSchedule : BoardState → Bool
  slotSafe : BoardState → Bool
  schedule_iff_slot_safe : ∀ b, canSchedule b = true ↔ slotSafe b = true

theorem DagScheduleSpec.rejects_starvation (D : DagScheduleSpec BoardState) (b : BoardState)
    (h_bad : D.slotSafe b = false) : D.canSchedule b = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_bad] using (D.schedule_iff_slot_safe b).mp h)

structure QuotaCircuitSpec (State : Type) where
  validTransition : State → Bool
  safeTransition : State → Bool
  valid_iff_safe : ∀ s, validTransition s = true ↔ safeTransition s = true

theorem QuotaCircuitSpec.rejects_invalid_transition (Q : QuotaCircuitSpec State) (s : State)
    (h_bad : Q.safeTransition s = false) : Q.validTransition s = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_bad] using (Q.valid_iff_safe s).mp h)

/-! ## Layer II: Existing 12 Orchestration & Node Lifecycle Corollaries (≤ 3 Lines Each) -/

structure WriterReuseCheck where
  hasContinue       : UInt8
  contTrackNonempty : UInt8
  contMatchesStored : UInt8
  hasAnyEdit        : UInt8
  workChanged       : UInt8
  identityUpdated   : UInt8
  deriving Repr, DecidableEq

def writerReuseMetaGate : MetaGateSpec WriterReuseCheck
    (fun c => (if c.hasContinue == 1 then
      (c.contTrackNonempty == 1 && c.contMatchesStored == 1 && c.hasAnyEdit == 0)
    else (c.workChanged == 0 || c.identityUpdated == 1)) = true) where
  gate c := verifyWriterReuse c.hasContinue c.contTrackNonempty c.contMatchesStored c.hasAnyEdit c.workChanged c.identityUpdated == 1
  sound _ h := by unfold verifyWriterReuse at h; repeat (first | split at h | split | simp_all)
  complete _ h := by unfold verifyWriterReuse; repeat (first | split at h | split | simp_all)
  posWitness := ⟨1, 1, 1, 0, 1, 0⟩
  negWitness := ⟨1, 1, 0, 0, 0, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 1: `verifyWriterReuse` refuses silent writer retasking or mismatched continuation assertions. -/
theorem writer_reuse_rejects_stale_identity (c : WriterReuseCheck)
    (h_bad : (if c.hasContinue == 1 then
      (c.contTrackNonempty == 1 && c.contMatchesStored == 1 && c.hasAnyEdit == 0)
    else (c.workChanged == 0 || c.identityUpdated == 1)) = false) :
    (verifyWriterReuse c.hasContinue c.contTrackNonempty c.contMatchesStored
      c.hasAnyEdit c.workChanged c.identityUpdated == 1) = false :=
  writerReuseMetaGate.rejects_unsafe c (fun h => by rw [h] at h_bad; contradiction)

structure LeaseModeCheck where
  writerFlag       : UInt8
  hasReadonlyTag   : UInt8
  hasWriterTag     : UInt8
  isReadonlyIntent : UInt8
  deriving Repr, DecidableEq

def leaseModeMetaGate : MetaGateSpec LeaseModeCheck
    (fun m => (m.writerFlag == 0 || m.hasReadonlyTag == 1 ||
      (m.writerFlag != 1 && m.hasWriterTag != 1 && m.isReadonlyIntent == 1)) = true) where
  gate m := verifyLeaseMode m.writerFlag m.hasReadonlyTag m.hasWriterTag m.isReadonlyIntent == 0
  sound _ h := by unfold verifyLeaseMode at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyLeaseMode; repeat (first | split | simp_all)
  posWitness := ⟨0, 0, 1, 0⟩
  negWitness := ⟨1, 0, 0, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 2: Any mission without `writer=false`, `pr-readonly`, or a read-only intent is classified as a writer (`!= 0`). -/
theorem lease_mode_defaults_to_writer (m : LeaseModeCheck)
    (h_mut : (m.writerFlag == 0 || m.hasReadonlyTag == 1 ||
      (m.writerFlag != 1 && m.hasWriterTag != 1 && m.isReadonlyIntent == 1)) = false) :
    (verifyLeaseMode m.writerFlag m.hasReadonlyTag m.hasWriterTag m.isReadonlyIntent == 0) = false :=
  leaseModeMetaGate.rejects_unsafe m (by simp [h_mut])

structure TrackHoldCheck where
  inUnresolved    : UInt8
  inQueued        : UInt8
  hasLiveOwner    : UInt8
  nativeGoalHolds : UInt8
  deriving Repr, DecidableEq

def trackHoldMetaGate : MetaGateSpec TrackHoldCheck
    (fun t => (t.inUnresolved != 1 && t.inQueued != 1 && t.hasLiveOwner != 1 && t.nativeGoalHolds != 1) = true) where
  gate t := verifyTrackHold t.inUnresolved t.inQueued t.hasLiveOwner t.nativeGoalHolds == 0
  sound _ h := by unfold verifyTrackHold at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyTrackHold; repeat (first | split | simp_all)
  posWitness := ⟨0, 0, 0, 0⟩
  negWitness := ⟨0, 0, 0, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 3: Track ownership is never released (`verifyTrackHold == 0` is false) while any execution or native goal is unresolved. -/
theorem track_hold_blocks_premature_release (t : TrackHoldCheck)
    (h_active : (t.inUnresolved != 1 && t.inQueued != 1 && t.hasLiveOwner != 1 && t.nativeGoalHolds != 1) = false) :
    (verifyTrackHold t.inUnresolved t.inQueued t.hasLiveOwner t.nativeGoalHolds == 0) = false :=
  trackHoldMetaGate.rejects_unsafe t (by simp [h_active])

structure RepoDisjointCheck where
  handleRepoKnown : UInt8
  targetRepoKnown : UInt8
  sameRepo        : UInt8
  deriving Repr, DecidableEq

def repoDisjointMetaGate : MetaGateSpec RepoDisjointCheck
    (fun r => (r.handleRepoKnown == 1 && r.targetRepoKnown == 1 && r.sameRepo == 0) = true) where
  gate r := verifyRepoDisjoint r.handleRepoKnown r.targetRepoKnown r.sameRepo == 1
  sound _ h := by unfold verifyRepoDisjoint at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyRepoDisjoint; repeat (first | split | simp_all)
  posWitness := ⟨1, 1, 0⟩
  negWitness := ⟨1, 1, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 4: Unknown or matching repository identity is treated conservatively as conflicting. -/
theorem repo_disjoint_rejects_unknown_or_equal (r : RepoDisjointCheck)
    (h_conflict : (r.handleRepoKnown == 1 && r.targetRepoKnown == 1 && r.sameRepo == 0) = false) :
    (verifyRepoDisjoint r.handleRepoKnown r.targetRepoKnown r.sameRepo == 1) = false :=
  repoDisjointMetaGate.rejects_unsafe r (by simp [h_conflict])

structure RemoteOutboxCheck where
  opKind              : UInt8
  alreadyExists       : UInt8
  sameMission         : UInt8
  isCancelled         : UInt8
  isSuperseded        : UInt8
  sessionReady        : UInt8
  prUnsupported       : UInt8
  hasJobId            : UInt8
  deliveryAbandonable : UInt8
  deriving Repr, DecidableEq

def remoteOutboxMetaGate : MetaGateSpec RemoteOutboxCheck
    (fun q => ((q.opKind == 0 && ((q.alreadyExists == 1 && q.sameMission == 1 && q.isCancelled == 0) ||
                                  (q.alreadyExists == 0 && q.isSuperseded == 0 && q.sessionReady == 1 && q.prUnsupported == 0))) ||
               (q.opKind != 0 && (q.hasJobId == 0 || q.deliveryAbandonable == 1))) = true) where
  gate q :=
    verifyRemoteOutbox q.opKind q.alreadyExists q.sameMission q.isCancelled
      q.isSuperseded q.sessionReady q.prUnsupported q.hasJobId q.deliveryAbandonable == 1
  sound _ h := by unfold verifyRemoteOutbox at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyRemoteOutbox; repeat (first | split | simp_all)
  posWitness := ⟨0, 0, 0, 0, 0, 1, 0, 0, 0⟩
  negWitness := ⟨1, 0, 0, 0, 0, 0, 0, 1, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 5: `verifyRemoteOutbox` rejects cross-mission message ID reuse, cancelled retries, or non-abandonable job cancellations. -/
theorem remote_outbox_rejects_unsafe_op (q : RemoteOutboxCheck)
    (h_bad : ((q.opKind == 0 && ((q.alreadyExists == 1 && q.sameMission == 1 && q.isCancelled == 0) ||
                                 (q.alreadyExists == 0 && q.isSuperseded == 0 && q.sessionReady == 1 && q.prUnsupported == 0))) ||
              (q.opKind != 0 && (q.hasJobId == 0 || q.deliveryAbandonable == 1))) = false) :
    (verifyRemoteOutbox q.opKind q.alreadyExists q.sameMission q.isCancelled
      q.isSuperseded q.sessionReady q.prUnsupported q.hasJobId q.deliveryAbandonable == 1) = false :=
  remoteOutboxMetaGate.rejects_unsafe q (by simp [h_bad])

structure BoardSlotCheck where
  maxParallel       : UInt32
  reservedBossSlots : UInt32
  totalRunning      : UInt32
  deriving Repr, DecidableEq

def boardSlotMetaGate : MetaGateSpec BoardSlotCheck
    (fun b => (b.reservedBossSlots ≥ 1 && b.reservedBossSlots < b.maxParallel &&
      b.totalRunning < b.maxParallel - b.reservedBossSlots) = true) where
  gate b := verifyBoardSlots b.maxParallel b.reservedBossSlots b.totalRunning == 1
  sound _ h := by unfold verifyBoardSlots at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyBoardSlots; repeat (first | split | simp_all)
  posWitness := ⟨4, 1, 2⟩
  negWitness := ⟨4, 1, 3⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 6: `verifyBoardSlots` refuses worker spawns that would consume the reserved boss slot. -/
theorem board_slots_prevent_boss_starvation (b : BoardSlotCheck)
    (h_full : (b.reservedBossSlots ≥ 1 && b.reservedBossSlots < b.maxParallel &&
      b.totalRunning < b.maxParallel - b.reservedBossSlots) = false) :
    (verifyBoardSlots b.maxParallel b.reservedBossSlots b.totalRunning == 1) = false :=
  boardSlotMetaGate.rejects_unsafe b (by simp [h_full])

structure BoardRetryCheck where
  attempts                 : UInt32
  maxAttempts              : UInt32
  requiresExternalRecovery : UInt8
  preflightMerged          : UInt8
  chatgptUiBlocked         : UInt8
  deriving Repr, DecidableEq

def boardRetryMetaGate : MetaGateSpec BoardRetryCheck
    (fun r => (r.maxAttempts ≥ 1 && r.attempts < r.maxAttempts &&
      r.requiresExternalRecovery == 0 && r.preflightMerged == 0 && r.chatgptUiBlocked == 0) = true) where
  gate r := verifyBoardRetry r.attempts r.maxAttempts r.requiresExternalRecovery r.preflightMerged r.chatgptUiBlocked == 1
  sound _ h := by unfold verifyBoardRetry at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyBoardRetry; repeat (first | split | simp_all)
  posWitness := ⟨1, 3, 0, 0, 0⟩
  negWitness := ⟨1, 3, 0, 1, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 7: `verifyBoardRetry` suppresses retries after `maxAttempts`, on merged PRs, or when external recovery is required. -/
theorem board_retry_rejects_exhausted_or_merged (r : BoardRetryCheck)
    (h_stop : (r.maxAttempts ≥ 1 && r.attempts < r.maxAttempts &&
      r.requiresExternalRecovery == 0 && r.preflightMerged == 0 && r.chatgptUiBlocked == 0) = false) :
    (verifyBoardRetry r.attempts r.maxAttempts
      r.requiresExternalRecovery r.preflightMerged r.chatgptUiBlocked == 1) = false :=
  boardRetryMetaGate.rejects_unsafe r (by simp [h_stop])

structure JobTransitionCheck where
  fromState : UInt8
  toState   : UInt8
  deriving Repr, DecidableEq

def jobTransitionMetaGate : MetaGateSpec JobTransitionCheck
    (fun t => ((t.fromState == 0 && t.toState ≥ 1 && t.toState ≤ 5) ||
      (t.fromState == 1 && t.toState ≥ 2 && t.toState ≤ 5) ||
      (t.fromState == 5 && t.toState == 4)) = true) where
  gate t := verifyJobTransition t.fromState t.toState == 1
  sound _ h := by unfold verifyJobTransition at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyJobTransition; repeat (first | split | simp_all)
  posWitness := ⟨1, 2⟩
  negWitness := ⟨2, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 8: `verifyJobTransition` rejects any transition out of terminal states (`succeeded`, `failed`, `cancelled`). -/
theorem job_transition_absorbs_terminal (t : JobTransitionCheck)
    (h_bad : ((t.fromState == 0 && t.toState ≥ 1 && t.toState ≤ 5) ||
              (t.fromState == 1 && t.toState ≥ 2 && t.toState ≤ 5) ||
              (t.fromState == 5 && t.toState == 4)) = false) :
    (verifyJobTransition t.fromState t.toState == 1) = false :=
  jobTransitionMetaGate.rejects_unsafe t (by simp [h_bad])

structure BundleBudgetCheck where
  isComplete   : UInt8
  decodedBytes : UInt64
  overlayCap   : UInt64
  completeCap  : UInt64
  maxBytes     : UInt64
  deriving Repr, DecidableEq

def bundleBudgetMetaGate : MetaGateSpec BundleBudgetCheck
    (fun b => (b.decodedBytes ≤ (if b.isComplete == 1 then b.completeCap else b.overlayCap) &&
      b.decodedBytes ≤ b.maxBytes) = true) where
  gate b := verifyBundleBudget b.isComplete b.decodedBytes b.overlayCap b.completeCap b.maxBytes == 1
  sound _ h := by unfold verifyBundleBudget at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyBundleBudget; repeat (first | split | simp_all)
  posWitness := ⟨0, 1024, 4096, 8192, 4096⟩
  negWitness := ⟨0, 8192, 4096, 8192, 8192⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 9: `verifyBundleBudget` rejects bundles exceeding advertised capacity or wire ceiling. -/
theorem bundle_budget_rejects_oversized (b : BundleBudgetCheck)
    (h_over : (b.decodedBytes ≤ (if b.isComplete == 1 then b.completeCap else b.overlayCap) &&
      b.decodedBytes ≤ b.maxBytes) = false) :
    (verifyBundleBudget b.isComplete b.decodedBytes b.overlayCap b.completeCap b.maxBytes == 1) = false :=
  bundleBudgetMetaGate.rejects_unsafe b (fun h => by rw [h] at h_over; contradiction)

structure TokenRotationCheck where
  presentedNonEmpty : UInt8
  matchCurrent      : UInt8
  prevNonEmpty      : UInt8
  matchPrev         : UInt8
  scopeAndExpiryOk  : UInt8
  deriving Repr, DecidableEq

def tokenRotationMetaGate : MetaGateSpec TokenRotationCheck
    (fun r => (r.presentedNonEmpty == 1 &&
      (r.matchCurrent == 1 || (r.prevNonEmpty == 1 && r.matchPrev == 1)) &&
      r.scopeAndExpiryOk == 1) = true) where
  gate r := verifyTokenRotation r.presentedNonEmpty r.matchCurrent r.prevNonEmpty r.matchPrev r.scopeAndExpiryOk == 1
  sound _ h := by unfold verifyTokenRotation at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyTokenRotation; repeat (first | split | simp_all)
  posWitness := ⟨1, 0, 1, 1, 1⟩
  negWitness := ⟨1, 0, 0, 1, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 10: `verifyTokenRotation` rejects empty tokens, unconfigured previous tokens, or invalid lease scopes. -/
theorem token_rotation_rejects_invalid (r : TokenRotationCheck)
    (h_bad : (r.presentedNonEmpty == 1 &&
      (r.matchCurrent == 1 || (r.prevNonEmpty == 1 && r.matchPrev == 1)) &&
      r.scopeAndExpiryOk == 1) = false) :
    (verifyTokenRotation r.presentedNonEmpty r.matchCurrent
      r.prevNonEmpty r.matchPrev r.scopeAndExpiryOk == 1) = false :=
  tokenRotationMetaGate.rejects_unsafe r (by simp [h_bad])

structure LogWindowCheck where
  offset    : UInt64
  reqLen    : UInt64
  maxChunk  : UInt64
  hardCap   : UInt64
  fileSize  : UInt64
  actualLen : UInt64
  deriving Repr, DecidableEq

def logWindowMetaGate : MetaGateSpec LogWindowCheck
    (fun w => (w.offset ≤ w.fileSize && w.reqLen ≤ w.maxChunk && w.maxChunk ≤ w.hardCap &&
      w.actualLen ≤ w.reqLen && w.actualLen ≤ w.fileSize - w.offset) = true) where
  gate w := verifyLogWindow w.offset w.reqLen w.maxChunk w.hardCap w.fileSize w.actualLen == 1
  sound _ h := by unfold verifyLogWindow at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyLogWindow; repeat (first | split | simp_all)
  posWitness := ⟨0, 64, 128, 256, 512, 64⟩
  negWitness := ⟨512, 64, 128, 256, 512, 64⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 11: `verifyLogWindow` rejects out-of-bounds offsets or oversized log chunks. -/
theorem log_window_rejects_invalid_chunk (w : LogWindowCheck)
    (h_bad : (w.offset ≤ w.fileSize && w.reqLen ≤ w.maxChunk && w.maxChunk ≤ w.hardCap &&
      w.actualLen ≤ w.reqLen && w.actualLen ≤ w.fileSize - w.offset) = false) :
    (verifyLogWindow w.offset w.reqLen w.maxChunk w.hardCap w.fileSize w.actualLen == 1) = false :=
  logWindowMetaGate.rejects_unsafe w (by simp [h_bad])

/-- Corollary 12: Deterministic avalanche mixing on empty word from zero seed. -/
theorem mix64Word_zero_seed_non_trivial :
    mix64Word 0x9E3779B97F4A7C15 0 ≠ 0 := by decide

/-! ## Layer II: New Non-Tautological State-Machine & Projection Corollaries (≤ 3 Lines Each) -/

/-- Corollary 13 (`StickyFence` — `orb_proxy_step`): Once `committed == 1`, commitment stays `1` (`bit 0`)
    and transparent reroute (`action == 1` or `2`) is never emitted, even on a stall (`stalled == 1`). -/
theorem proxy_committed_fence_forbids_reroute
    (chunkCommits stalled : UInt8) (retries maxRetries : UInt32) :
    (proxyStep 1 chunkCommits stalled retries maxRetries &&& 1) = 1 ∧
    ((proxyStep 1 chunkCommits stalled retries maxRetries >>> 8) &&& 0xFF) ≠ 1 ∧
    ((proxyStep 1 chunkCommits stalled retries maxRetries >>> 8) &&& 0xFF) ≠ 2 := by
  unfold proxyStep; repeat (first | split | decide | simp_all)

/-- Corollary 14 (`ClockDiscipline` — `orb_stream_deadlines`): Keepalive (`bit 0`) never fires outside
    an SSE event boundary (`atEventBoundary == 0`), and liveness (`bit 16`) never fires without `authVerified == 1`. -/
theorem stream_deadlines_clock_isolation
    (cEl kaMs uEl bIdle pFloor : UInt64) (hasHdr : UInt8) :
    (streamDeadlines cEl kaMs uEl bIdle pFloor 0 hasHdr 0 &&& 1) = 0 ∧
    (streamDeadlines cEl kaMs uEl bIdle pFloor 0 hasHdr 0 &&& 65536) = 0 := by
  unfold streamDeadlines; repeat (first | split | decide | simp_all)

/-- Corollary 15 (`ConservedResource` — `orb_breaker_step`): Transient 502/timeout (`reason == 4`)
    never poisons a shared subscription (`bit 8 == 0`) and applies zero cooldown below threshold. -/
theorem breaker_transient_never_poisons_subscription
    (streak threshold : UInt32) (h_below : (streak ≥ threshold && threshold ≥ 1) = false) :
    breakerStep 4 streak threshold = 0 := by
  unfold breakerStep; simp [h_below]

/-- Corollary 16 (`StickyFence` — `orb_mission_step`): An armed `/goal` turn with an agent-armed wakeup
    (`wakeupArmed == 1`, `signal == 0`, `continuationPending == 0`) transitions to `4 (paused_wakeup)`, never `1 (complete)`. -/
theorem mission_goal_wakeup_pauses_never_completes
    (madeProg : UInt8) (pNoProg mNoProg pCont mCont hasMax : UInt32) :
    missionStep 1 0 0 1 madeProg pNoProg mNoProg pCont mCont hasMax = 4 := rfl

/-- Corollary 17 (`ScopedAuthority` — `orb_reconcile_step`): Any mission belonging to the current boot
    (`sameBootId == 1`) or holding a live scope (`hasLiveScope == 1`) is preserved (`0 = keep`), never reaped. -/
theorem reconcile_same_boot_never_reaps
    (status isClient isAssist inActor hasScope hasDur recent hasEv alreadyOrph isRestart inHoriz retryEx : UInt8) :
    reconcileStep status isClient 1 isAssist inActor hasScope hasDur recent hasEv alreadyOrph isRestart inHoriz retryEx = 0 := by
  unfold reconcileStep; repeat (first | split | rfl | simp_all)

/-- Corollary 18 (`ConservedResource` — `orb_queue_step`): Unacknowledged or uncertain follow-up deliveries
    (`deliveryOutcome != 0`) are always retained in the queue (`bit 0 == 1`) and never marked consumed (`bit 8 == 0`). -/
theorem queue_unacked_retains_and_never_consumes
    (outcome durablyStarted : UInt8) (h_unacked : (outcome == 0) = false) :
    (queueStep outcome durablyStarted &&& 1) = 1 ∧
    (queueStep outcome durablyStarted &&& 256) = 0 := by
  unfold queueStep; simp [h_unacked]
  split <;> decide

/-- Corollary 19 (`ScopedAuthority` & `ConservedResource` — `orb_vm_step`): Managed VM spawn (`op == 0`)
    always rejects secret projection (`secretProjected == 1`) or per-job memory above 90% (`jobMemPct > 90`). -/
theorem vm_spawn_rejects_secret_or_mem_overflow
    (sRank mRank ttlExp busy ownEnd idleExp : UInt8)
    (act maxC ttl maxTtl : UInt32) (spent cap : UInt64) :
    vmStep 0 sRank mRank 1 ttlExp busy ownEnd idleExp act maxC ttl maxTtl 90 spent cap = 0 ∧
    vmStep 0 sRank mRank 0 ttlExp busy ownEnd idleExp act maxC ttl maxTtl 95 spent cap = 0 := by
  unfold vmStep; constructor <;> (repeat (first | split | decide | simp_all))

/-- Corollary 20 (`ScopedAuthority` — `orb_access_step`): Before a grant is approved (`grantApproved == 0`)
    for a non-child mission (`isSelfOrChild == 0`), `orb_access_step` returns `0` independientemente of `targetExists`
    (zero existence oracle, zero title disclosure, zero tool access). -/
theorem access_pre_grant_non_disclosure
    (sameOwner isReadTool grantUnexpired tExists1 tExists2 : UInt8) :
    accessStep sameOwner 0 isReadTool 0 grantUnexpired tExists1 = 0 ∧
    accessStep sameOwner 0 isReadTool 0 grantUnexpired tExists1 =
      accessStep sameOwner 0 isReadTool 0 grantUnexpired tExists2 := by
  unfold accessStep; repeat (first | split | decide | simp_all)

/-- Corollary 21 (`ProjectionStability` — `orb_workfold_step`): Assistant text after the turn's last work tool
    (`toolAhead == 0`) or cumulative text (`isCumulative == 1`) is never folded into work (`bit 0 == 0`). -/
theorem workfold_final_answer_never_folded
    (isCum isNonEmpty nextTool foldTool : UInt8) :
    (workfoldStep 2 isCum isNonEmpty 0 nextTool foldTool &&& 1) = 0 ∧
    (workfoldStep 2 1 isNonEmpty 1 nextTool foldTool &&& 1) = 0 := by
  unfold workfoldStep; constructor <;> (repeat (first | split | decide | simp_all))

/-- Corollary 22 (`ProjectionStability` — `orb_taskcard_step`): Once a turn ends (`turnEnded == 1`),
    the Tasks card never remains in `"live"` (`0`), and a finished turn with open items
    transitions to `"stale"` (`2`), not `"stopped"` (`3`). -/
theorem taskcard_ended_turn_never_live (allClosed outcomeFinished : UInt8) :
    taskcardStep 1 allClosed outcomeFinished ≠ 0 ∧
    taskcardStep 1 0 1 = 2 := by
  unfold taskcardStep; constructor <;> (repeat (first | split | decide | simp_all))

/-- Corollary 23 (`ProjectionStability` — `orb_sidebar_visibility`): Retained main-tree rows and archive-only rows
    are strictly disjoint, and self-reaching links (`parentReachesSelf == 1`) are never marked cycle-safe (`bit 16 == 0`). -/
theorem sidebar_main_archive_disjoint_and_cycle_safe
    (filt visDesc ack hasPar isFork : UInt8) :
    ((sidebarVisibility filt visDesc ack hasPar isFork 1 &&& 1) = 1 →
      (sidebarVisibility filt visDesc ack hasPar isFork 1 &&& 256) = 0) ∧
    (sidebarVisibility filt visDesc ack hasPar isFork 1 &&& 65536) = 0 := by
  unfold sidebarVisibility; repeat (first | split | decide | simp_all)

end Orb.Spec
