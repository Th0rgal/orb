/-
  Orb.Spec: Verified Orchestration, Proxy Streaming, Mission Lifecycle & Cross-Client Projection Kernel (`0 import Lean`, `0 sorryAx`)
  - Layer 0: Universal `MetaGateSpec` contract (soundness, completeness, `posWitness`, `negWitness`, non-vacuity, tightness)
  - Layer I: 5 Universal Non-Tautological Meta-Specifications (`StickyFence`, `ClockDiscipline`,
    `ScopedAuthority`, `ConservedResource`, `ProjectionStability`) + compatibility combinators
    (`LinearLeaseSpec`, `IdempotentOutboxSpec`, `DagScheduleSpec`, `QuotaCircuitSpec`)
  - Layer II: Declarative Corollaries (≤ 3 lines each, Mathlib4 algebraic proof style)
  - Direct Unboxed C-ABI (`@[inline, export]` in `Orb.Kernel`, 36 exports):
    `orb_verify_writer_reuse`, `orb_verify_lease_mode`, `orb_verify_track_hold`, `orb_verify_repo_disjoint`,
    `orb_verify_remote_outbox`, `orb_verify_board_slots`, `orb_verify_board_retry`, `orb_verify_job_transition`,
    `orb_verify_bundle_budget`, `orb_verify_token_rotation`, `orb_verify_log_window`, `orb_mix64_word`,
    `orb_proxy_step`, `orb_stream_deadlines`, `orb_breaker_step`, `orb_mission_step`, `orb_reconcile_step`,
    `orb_queue_step`, `orb_vm_step`, `orb_access_step`, `orb_workfold_step`, `orb_taskcard_step`,
    `orb_sidebar_visibility`, `orb_admission_step`, `orb_account_cooldown_secs`, `orb_cost_cents_step`,
    `orb_stream_loop_step`, `orb_job_ledger_step`, `orb_proc_liveness_step`, `orb_pr_gate_step`,
    `orb_turn_summary_step`, `orb_usage_limit_status`, `orb_relative_time_bucket`, `orb_transcript_patch_step`,
    `orb_attribution_step`, `orb_schedule_step`, `orb_stats_settle_step`
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

theorem StickyFence.fence_blocks_act {State Event : Type} (F : StickyFence State Event) (s : State) (e : Event)
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

theorem ClockDiscipline.rejects_cross_clock {Input : Type} (C : ClockDiscipline Input) (x : Input)
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

theorem ScopedAuthority.rejects_out_of_scope {Input : Type} (A : ScopedAuthority Input) (x : Input)
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

theorem ConservedResource.rejects_overflow {Input : Type} (R : ConservedResource Input) (x : Input)
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

theorem ProjectionStability.ensures_stable {Input Out : Type} (P : ProjectionStability Input Out) (x : Input)
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

theorem LinearLeaseSpec.rejects_unsafe {σ α : Type} (L : LinearLeaseSpec σ α) (s : σ) (x : α)
    (h_unsafe : L.safe s x = false) : L.gate s x = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_unsafe] using (L.gate_iff_safe s x).mp h)

structure IdempotentOutboxSpec (Row Req : Type) where
  admit : Row → Req → Bool
  safeReplay : Row → Req → Bool
  admit_iff_safe_replay : ∀ r q, admit r q = true ↔ safeReplay r q = true

theorem IdempotentOutboxSpec.rejects_conflicting_replay {Row Req : Type} (O : IdempotentOutboxSpec Row Req)
    (r : Row) (q : Req) (h_bad : O.safeReplay r q = false) : O.admit r q = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_bad] using (O.admit_iff_safe_replay r q).mp h)

structure DagScheduleSpec (BoardState : Type) where
  canSchedule : BoardState → Bool
  slotSafe : BoardState → Bool
  schedule_iff_slot_safe : ∀ b, canSchedule b = true ↔ slotSafe b = true

theorem DagScheduleSpec.rejects_starvation {BoardState : Type} (D : DagScheduleSpec BoardState) (b : BoardState)
    (h_bad : D.slotSafe b = false) : D.canSchedule b = false :=
  Bool.eq_false_iff.mpr (fun h => by simpa [h_bad] using (D.schedule_iff_slot_safe b).mp h)

structure QuotaCircuitSpec (State : Type) where
  validTransition : State → Bool
  safeTransition : State → Bool
  valid_iff_safe : ∀ s, validTransition s = true ↔ safeTransition s = true

theorem QuotaCircuitSpec.rejects_invalid_transition {State : Type} (Q : QuotaCircuitSpec State) (s : State)
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
  retrySuppressed          : UInt8
  deriving Repr, DecidableEq

def boardRetryMetaGate : MetaGateSpec BoardRetryCheck
    (fun r => (r.maxAttempts ≥ 1 && r.attempts < r.maxAttempts &&
      r.requiresExternalRecovery == 0 && r.preflightMerged == 0 && r.retrySuppressed == 0) = true) where
  gate r := verifyBoardRetry r.attempts r.maxAttempts r.requiresExternalRecovery r.preflightMerged r.retrySuppressed == 1
  sound _ h := by unfold verifyBoardRetry at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold verifyBoardRetry; repeat (first | split | simp_all)
  posWitness := ⟨1, 3, 0, 0, 0⟩
  negWitness := ⟨1, 3, 0, 1, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 7: `verifyBoardRetry` suppresses retries after `maxAttempts`, on merged PRs, or when external recovery is required. -/
theorem board_retry_rejects_exhausted_or_merged (r : BoardRetryCheck)
    (h_stop : (r.maxAttempts ≥ 1 && r.attempts < r.maxAttempts &&
      r.requiresExternalRecovery == 0 && r.preflightMerged == 0 && r.retrySuppressed == 0) = false) :
    (verifyBoardRetry r.attempts r.maxAttempts
      r.requiresExternalRecovery r.preflightMerged r.retrySuppressed == 1) = false :=
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

/-- Corollary 24 (`ScopedAuthority` & `ConservedResource` — `orb_admission_step`): Ambiguous recovery (`recoveryPhase == 2`)
    fences both assignments (`bit 16 == 1`, `admit == 0`), and forged disk tags (`reservedTagForged == 1`) are always rejected. -/
theorem admission_fences_ambiguous_and_rejects_forged_tag
    (isQuiescent : UInt8) (reqBytes freeBytes : UInt64) :
    admissionStep 2 isQuiescent 0 reqBytes freeBytes = 65536 ∧
    admissionStep 0 isQuiescent 1 reqBytes freeBytes = 0 := by
  unfold admissionStep; constructor <;> (repeat (first | split | decide | simp_all))

/-- Corollary 25 (`ClockDiscipline` — `orb_account_cooldown_secs`): Account circuit-breaker cooldowns
    double from 600s on the first error (`1 -> 600`, `2 -> 1200`) and saturate at `maxSecs` (`21 -> 21600`). -/
theorem account_cooldown_exponential_and_capped :
    accountCooldownSecs 600 21600 1 = 600 ∧
    accountCooldownSecs 600 21600 2 = 1200 ∧
    accountCooldownSecs 600 21600 25 = 21600 := by decide

/-- Corollary 26 (`ConservedResource` — `orb_cost_cents_step`): Cache-creation tokens are deducted from
    regular input tokens without underflow (`inputTokens < cacheCreateTokens` saturates regular input to `0`). -/
theorem cost_cents_no_underflow_and_rounds_nearest :
    costCentsStep 100 0 500 0 3000 15000 0 0 = 0 ∧
    costCentsStep 1000 1000 0 0 3000 15000 0 0 = 2 := by decide

/-- Corollary 27 (`ConservedResource` — `orb_stream_loop_step`): Hash collisions (`hashCollision == 1`)
    or comparison budget exhaustion (`comparisons > comparisonBudget`) fail open to `2 (inconclusive)`, never `1 (repeated)`. -/
theorem stream_loop_collision_or_single_word_never_triggers
    (win minL rep cnt words : UInt32) (cmp bud : UInt64) :
    streamLoopStep 0 1 win minL rep cnt words cmp bud ≠ 1 ∧
    streamLoopStep 0 0 win minL rep cnt 1 cmp bud ≠ 1 := by
  unfold streamLoopStep; constructor <;> (repeat (first | split | decide | simp_all))

/-- Corollary 28 (`StickyFence` — `orb_job_ledger_step`): Once a newer terminal receipt (`newerTerminalExists == 1`)
    or newer tentative submission (`newerAmbiguousTentative == 1`) exists, the older wait lease is dropped (`bit 0 == 0`). -/
theorem job_ledger_newer_supersedes_wait_lease
    (isAcc expectsCont ambig : UInt8) :
    (jobLedgerStep isAcc expectsCont 1 ambig &&& 1) = 0 ∧
    (jobLedgerStep isAcc expectsCont 0 1 &&& 1) = 0 := by
  unfold jobLedgerStep; constructor <;> (repeat (first | split | decide | simp_all))

/-- Corollary 29 (`ScopedAuthority` — `orb_proc_liveness_step`): A reused PID with mismatched `start_ticks`
    is classified as `0 (dead)`, while a transient `/proc/<pid>/stat` read error returns `2 (inconclusive_alive)`. -/
theorem proc_liveness_rejects_pid_reuse_and_keeps_read_err
    (isZomb hasTicks : UInt8) (fields : UInt32) (t1 t2 : UInt64) :
    procLivenessStep 0 1 isZomb hasTicks fields t1 t2 = 2 ∧
    procLivenessStep 0 0 0 1 25 1000 2000 = 0 := by
  unfold procLivenessStep; constructor <;> (repeat (first | split | decide | simp_all))

/-- Corollary 30 (`ProjectionStability` — `orb_pr_gate_step`): Head SHA drift (`exactHead == 0`) or external
    `action_required` (`actionRequired == 1`) always blocks `8 (ready_for_review_or_merge)`, even when checks are green. -/
theorem pr_gate_head_drift_or_action_required_blocks_merge
    (actReq blk beh conf : UInt8) :
    prGateStep 0 0 0 0 actReq blk beh conf 1 1 = 3 ∧
    prGateStep 0 0 0 1 1 blk beh conf 1 1 = 4 := by
  unfold prGateStep; constructor <;> rfl

/-- Corollary 31 (`ProjectionStability` — `orb_turn_summary_step`): Once a turn ends (`turnEnded == 1`),
    an `in_progress (1)` task settles to `pending (0)` (`isActive == 0`), and `completed (2)` stays done (`bit 8`). -/
theorem turn_summary_settles_in_progress_on_turn_end
    (allClosed outcomeFinished : UInt8) :
    (turnSummaryStep 1 1 allClosed outcomeFinished &&& 0xFF) = 0 ∧
    (turnSummaryStep 1 1 allClosed outcomeFinished &&& 65536) = 0 ∧
    (turnSummaryStep 2 1 allClosed outcomeFinished &&& 256) = 256 := by
  unfold turnSummaryStep taskcardStep; repeat (first | split | decide | simp_all)

/-- Corollary 32 (`ProjectionStability` — `orb_usage_limit_status`): Allowed/ok/missing status (`0`) is hidden (`0`),
    `seven_day_opus (3)` suppresses percentage (`bit 16 == 0`), and `rejected (2)` at 30s clamps reset to `1m`. -/
theorem usage_limit_status_matches_cross_client_invariants
    (claim hasUtil pct hasReset : UInt8) (rem : UInt64) :
    usageLimitStatus 0 claim hasUtil pct hasReset rem = 0 ∧
    (usageLimitStatus 1 3 1 88 0 0 &&& 65536) = 0 ∧
    ((usageLimitStatus 2 0 0 0 1 30 >>> 32) &&& 0xFF) = 1 ∧
    (usageLimitStatus 2 0 0 0 1 30 >>> 40) = 1 := by
  unfold usageLimitStatus; repeat (first | constructor | rfl | decide)

/-- Corollary 33 (`ProjectionStability` — `orb_relative_time_bucket`): Elapsed times `< 45s` return `0 ("now")`,
    and `45..59s` clamp to `1m` (`unit = 1`, `value = 1`), never `"0m"`. -/
theorem relative_time_bucket_never_zero_minutes :
    relativeTimeBucket 44 = 0 ∧
    relativeTimeBucket 45 = 257 ∧
    relativeTimeBucket 59 = 257 ∧
    relativeTimeBucket 3600 = 258 := by decide

/-- Bit `i` of the low-32 mask `0xFFFFFFFF` is set exactly below bit 32. -/
theorem mask32_getLsbD : ∀ i, i < 64 → (UInt64.toBitVec 4294967295).getLsbD i = decide (i < 32) := by decide

theorem shiftLeft32_bv (x : BitVec 64) : x <<< (UInt64.toBitVec 32 % 64) = x <<< 32 := by
  rw [show UInt64.toBitVec 32 % 64 = 32#64 from rfl, BitVec.shiftLeft_eq']; rfl

theorem shiftRight32_bv (x : BitVec 64) : x >>> (UInt64.toBitVec 32 % 64) = x >>> 32 := by
  rw [show UInt64.toBitVec 32 % 64 = 32#64 from rfl, BitVec.ushiftRight_eq']; rfl

/-- The low word of a `(lo, hi)` 32/32 packing decodes back to `lo`. -/
theorem pack32_lo (a b : UInt32) : ((a.toUInt64 ||| (b.toUInt64 <<< 32)) &&& 0xFFFFFFFF) = a.toUInt64 := by
  apply UInt64.toBitVec_inj.mp
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  have hm := mask32_getLsbD i hi
  have ha := BitVec.getLsbD_of_ge a.toBitVec i
  simp only [UInt64.toBitVec_and, UInt64.toBitVec_or, UInt64.toBitVec_shiftLeft, UInt32.toBitVec_toUInt64,
    BitVec.getLsbD_and, BitVec.getLsbD_or, shiftLeft32_bv, BitVec.getLsbD_shiftLeft, BitVec.getLsbD_setWidth, hm]
  by_cases h : i < 32 <;> simp_all

/-- The high word of a `(lo, hi)` 32/32 packing decodes back to `hi`. -/
theorem pack32_hi (a b : UInt32) : ((a.toUInt64 ||| (b.toUInt64 <<< 32)) >>> 32) = b.toUInt64 := by
  apply UInt64.toBitVec_inj.mp
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  have ha := BitVec.getLsbD_of_ge a.toBitVec (32 + i)
  have hb := BitVec.getLsbD_of_ge b.toBitVec i
  simp only [UInt64.toBitVec_or, UInt64.toBitVec_shiftLeft, UInt64.toBitVec_shiftRight, UInt32.toBitVec_toUInt64,
    BitVec.getLsbD_or, shiftLeft32_bv, shiftRight32_bv, BitVec.getLsbD_ushiftRight, BitVec.getLsbD_shiftLeft,
    BitVec.getLsbD_setWidth]
  by_cases h : i < 32 <;> simp_all <;> omega

/-- Saturating addition never decreases its left operand (no `UInt32` wrap-around). -/
theorem satAdd32_ge (a b : UInt32) : a ≤ satAdd32 a b := by
  unfold satAdd32; split
  · next h =>
    have hb := UInt32.toNat_lt b
    rw [UInt32.le_iff_toNat_le] at h ⊢
    rw [UInt32.toNat_sub_of_le _ _ (by rw [UInt32.le_iff_toNat_le]; simp; omega)] at h
    rw [UInt32.toNat_add, Nat.mod_eq_of_lt (by simp at h ⊢; omega)]; omega
  · exact UInt32.le_iff_toNat_le.mpr (by have := UInt32.toNat_lt a; simp; omega)

/-- Corollary 34 (`ProjectionStability` — `orb_transcript_patch_step`): a `message_delta` never shrinks the
    live buffer (saturating, no wrap), a `turn_boundary` resets it to `0`, and the sequence counter advances
    saturatingly on known event kinds (`≤ 2`) while unknown kinds leave it unchanged. -/
theorem transcript_patch_step_monotone_absorbing (l s d : UInt32) (k : UInt8) :
    l ≤ (transcriptPatchStep l s 0 d &&& 0xFFFFFFFF).toUInt32 ∧
    (transcriptPatchStep l s 2 d &&& 0xFFFFFFFF) = 0 ∧
    (transcriptPatchStep l s k d >>> 32) = (if k ≤ 2 then (satAdd32 s 1).toUInt64 else s.toUInt64) := by
  refine ⟨by simpa [transcriptPatchStep, pack32_lo] using satAdd32_ge l d,
    by simpa [transcriptPatchStep] using pack32_lo 0 (satAdd32 s 1), ?_⟩
  unfold transcriptPatchStep; split <;> simp_all [pack32_hi]

/-- Corollary 35 (`ProjectionStability` — `orb_transcript_patch_step`): unknown event kinds (`> 2`) return the
    packed input state unchanged, and a wrapping delta saturates the live length at `0xFFFFFFFF`. -/
theorem transcript_patch_step_unknown_kind_identity_and_saturates (l s d : UInt32) :
    transcriptPatchStep l s 3 d = (l.toUInt64 ||| (s.toUInt64 <<< 32)) ∧
    (transcriptPatchStep 0xFFFFFFF0 7 0 0x20 &&& 0xFFFFFFFF) = 0xFFFFFFFF := by
  constructor <;> simp [transcriptPatchStep] <;> decide

/-! ## Layer II: Usage Attribution (`orb_attribution_step`, `ScopedAuthority` + `ProjectionStability`) -/

/-- The clamped principal is always inside the closed caller-kind enum. -/
theorem attributionPrincipal_le_six (p : UInt8) : attributionPrincipal p ≤ 6 := by
  unfold attributionPrincipal; split
  · assumption
  · decide

/-- A non-empty in-scope claim is a valid kind and requires a credential binding. -/
theorem attributionInScope_claim (p c s d : UInt8)
    (h : attributionInScope (attributionPrincipal p) c s d = true) (hc : c ≠ 0) :
    c ≤ 6 ∧ attributionPrincipal p ≠ 0 := by
  have hp := attributionPrincipal_le_six p
  generalize attributionPrincipal p = q at h hp ⊢
  simp only [attributionInScope, Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq] at h
  simp only [UInt8.le_iff_toNat_le, ← UInt8.toNat_inj, UInt8.reduceToNat, ne_eq] at *
  omega

/-- Totality: every usage event maps to exactly one kind of the closed enum `0..6`. -/
theorem attribution_kind_le_six (p c s d : UInt8) : attributionKind p c s d ≤ 6 := by
  unfold attributionKind; split
  · split
    · exact attributionPrincipal_le_six p
    · next h hc => exact (attributionInScope_claim p c s d h (by simpa using hc)).1
  · exact attributionPrincipal_le_six p

/-- `unknown` (`0`) is returned iff no credential binding exists, whatever the client claims. -/
theorem attribution_kind_unknown_iff (p c s d : UInt8) :
    attributionKind p c s d = 0 ↔ attributionPrincipal p = 0 := by
  unfold attributionKind; split
  · split
    · exact Iff.rfl
    · next h hc =>
      have := attributionInScope_claim p c s d h (by simpa using hc)
      exact ⟨fun h0 => absurd h0 (by simpa using hc), fun h0 => absurd h0 this.2⟩
  · exact Iff.rfl

/-- The packed C-ABI word decodes to `(kind, accepted)` exactly as `src/api/usage_attribution.rs` reads it. -/
theorem attribution_step_decodes (p c s d : UInt8) :
    (attributionStep p c s d &&& 0xFF) = (attributionKind p c s d).toUInt32 ∧
    ((attributionStep p c s d >>> 8) &&& 1) =
      (if attributionInScope (attributionPrincipal p) c s d then 1 else 0) := by
  have hk := attribution_kind_le_six p c s d
  unfold attributionStep
  generalize attributionKind p c s d = k at hk ⊢
  have hn : k.toNat ≤ 6 := by simpa [UInt8.le_iff_toNat_le] using hk
  have hk' : k = k.toNat.toUInt8 := by simp
  rw [hk']
  generalize k.toNat = n at hn
  split <;> (match n, hn with
    | 0, _ | 1, _ | 2, _ | 3, _ | 4, _ | 5, _ | 6, _ => decide)

structure AttributionClaim where
  principalKind : UInt8
  claimedKind   : UInt8
  sameMission   : UInt8
  isDescendant  : UInt8
  deriving Repr, DecidableEq

/-- Semantic scope of a client attribution hint, stated independently of the kernel's boolean formula. -/
def AttributionClaim.InScope (x : AttributionClaim) : Prop :=
  let p := attributionPrincipal x.principalKind
  x.claimedKind = 0 ∨
  (p = 5 ∧ (x.claimedKind = 1 ∨ x.claimedKind = 2 ∨ x.claimedKind = 5)) ∨
  ((p = 1 ∨ p = 2) ∧ ((x.claimedKind = 1 ∧ x.sameMission = 1) ∨ (x.claimedKind = 2 ∧ x.isDescendant = 1))) ∨
  ((p = 3 ∨ p = 4 ∨ p = 6) ∧ x.claimedKind = p)

theorem attributionInScope_iff (x : AttributionClaim) :
    attributionInScope (attributionPrincipal x.principalKind) x.claimedKind x.sameMission x.isDescendant = true ↔
      x.InScope := by
  simp [attributionInScope, AttributionClaim.InScope, or_assoc]

/-- `MetaGateSpec` for the acceptance bit: a hint is accepted iff it stays inside the principal's scope. -/
def attributionMetaGate : MetaGateSpec AttributionClaim AttributionClaim.InScope where
  gate x := ((attributionStep x.principalKind x.claimedKind x.sameMission x.isDescendant >>> 8) &&& 1) == 1
  sound x h := by
    rw [(attribution_step_decodes _ _ _ _).2] at h
    exact (attributionInScope_iff x).mp (by split at h <;> simp_all)
  complete x h := by
    have hin := (attributionInScope_iff x).mpr h
    simp [(attribution_step_decodes _ _ _ _).2, hin]
  posWitness := ⟨1, 2, 0, 1⟩
  negWitness := ⟨6, 1, 0, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- `ScopedAuthority` instance: an accepted attribution hint never escapes the credential's scope. -/
def attributionScopedAuthority : ScopedAuthority AttributionClaim where
  admit x := attributionMetaGate.gate x
  scopeValid x := attributionInScope (attributionPrincipal x.principalKind) x.claimedKind x.sameMission x.isDescendant
  sound x h := (attributionInScope_iff x).mpr (attributionMetaGate.sound x h)

/-- `ProjectionStability` instance (`TotalAttribution`): the projected kind is in the closed enum and is
    `unknown` exactly when the credential has no binding. -/
def attributionTotal : ProjectionStability AttributionClaim UInt8 where
  project x := attributionKind x.principalKind x.claimedKind x.sameMission x.isDescendant
  validIn _ := true
  stable x k := decide (k ≤ 6) && (k == 0) == (attributionPrincipal x.principalKind == 0)
  preserves x _ := by
    have h1 := attribution_kind_le_six x.principalKind x.claimedKind x.sameMission x.isDescendant
    have h2 := attribution_kind_unknown_iff x.principalKind x.claimedKind x.sameMission x.isDescendant
    cases hk : (attributionKind x.principalKind x.claimedKind x.sameMission x.isDescendant == 0) <;>
      cases hp : (attributionPrincipal x.principalKind == 0) <;> simp_all

/-- Corollary 36 (`ScopedAuthority` — `orb_attribution_step`): forged hints are rejected and keep the
    principal's kind (a script key cannot claim a mission, a mission key cannot claim a foreign subagent,
    no binding stays `unknown`), while in-scope hints refine it. -/
theorem attribution_forged_hint_rejected_keeps_principal :
    attributionStep 6 1 0 0 = 6 ∧ attributionStep 1 2 0 0 = 1 ∧ attributionStep 0 5 0 0 = 0 ∧
    attributionStep 1 2 0 1 = 258 ∧ attributionStep 5 0 0 0 = 261 := by decide

/-! ## Layer II: Native Recurring Schedules (`orb_schedule_step`, `IdempotentOutboxSpec` + `ClockDiscipline`
    + `StickyFence` + `ScopedAuthority`) -/

/-- Inputs of one schedule decision, named as in `docs/specs/agent-schedules.md`. -/
structure ScheduleInput where
  op            : UInt8
  known         : UInt8
  cancelled     : UInt8
  ownerTerminal : UInt8
  authorized    : UInt8
  busy          : UInt8
  lastFired     : UInt64
  nextDue       : UInt64
  now           : UInt64
  deriving Repr, DecidableEq

def ScheduleInput.action (x : ScheduleInput) : UInt8 :=
  scheduleStep x.op x.known x.cancelled x.ownerTerminal x.authorized x.busy x.lastFired x.nextDue x.now

/-- Registration is admitted (a new row) iff the caller is authorized, the key is new and the
    owner is live. -/
theorem schedule_register_iff (k c t a b : UInt8) (l d n : UInt64) :
    scheduleStep 0 k c t a b l d n = 1 ↔ a = 1 ∧ k ≠ 1 ∧ t ≠ 1 := by
  unfold scheduleStep scheduleAction
  by_cases ha : a = 1 <;>
    by_cases hk : k = 1 <;>
    by_cases ht : t = 1 <;>
    simp [ha, hk, ht]

/-- `IdempotentOutboxSpec` instance: the outbox row is the `known` bit of the key. Replaying a
    registration (same mission, cron and prompt, e.g. after a restart) is never admitted again. -/
def scheduleOutbox : IdempotentOutboxSpec UInt8 ScheduleInput where
  admit known q := scheduleStep 0 known q.cancelled q.ownerTerminal q.authorized q.busy
    q.lastFired q.nextDue q.now == 1
  safeReplay known q := q.authorized == 1 && known != 1 && q.ownerTerminal != 1
  admit_iff_safe_replay known q := by
    simp only [beq_iff_eq, schedule_register_iff, Bool.and_eq_true, bne_iff_ne, ne_eq, and_assoc]

/-- Corollary 37 (`IdempotentOutboxSpec`): re-registering a known key is a no-op — it dedupes
    for an authorized caller and is dropped otherwise, whatever the other inputs. -/
theorem schedule_reregister_is_noop (c t a b : UInt8) (l d n : UInt64) :
    scheduleStep 0 1 c t a b l d n = (if a = 1 then 2 else 0) := by
  unfold scheduleStep scheduleAction
  by_cases ha : a = 1 <;> simp [ha]

/-- A tick fires exactly when the next slot is due, not yet consumed and the mission is idle. -/
theorem schedule_fire_iff (c t a b : UInt8) (l d n : UInt64) :
    scheduleStep 1 0 c t a b l d n = 3 ↔
      a = 1 ∧ c ≠ 1 ∧ t ≠ 1 ∧ l < d ∧ d ≤ n ∧ b ≠ 1 := by
  unfold scheduleStep scheduleAction
  by_cases ha : a = 1 <;>
    by_cases hc : c = 1 <;>
    by_cases ht : t = 1 <;>
    by_cases hl : l < d <;>
    by_cases hd : d ≤ n <;>
    by_cases hb : b = 1 <;>
    simp [ha, hc, ht, hl, hd, hb]

/-- `ClockDiscipline` instance: the fire bit is only ever set by the schedule's own due-slot guard. -/
def scheduleClock : ClockDiscipline ScheduleInput where
  eval x := if scheduleStep 1 0 x.cancelled x.ownerTerminal x.authorized x.busy x.lastFired x.nextDue x.now = 3
    then 1 else 0
  clockMask := 1
  guardOk x := decide (x.lastFired < x.nextDue) && decide (x.nextDue ≤ x.now)
  isolated x h := by
    by_cases hf : scheduleStep 1 0 x.cancelled x.ownerTerminal x.authorized x.busy x.lastFired x.nextDue x.now = 3
    · have := (schedule_fire_iff _ _ _ _ _ _ _).mp hf; simp [this.2.2.2.1, this.2.2.2.2.1]
    · simp [hf] at h

/-- Corollary 38 (`ClockDiscipline`): a fire strictly advances the reference, and the advanced
    reference consumes the slot — the same slot never fires twice, at any later time. After any
    downtime the scheduler therefore fires at most once for all the slots it missed. -/
theorem schedule_fires_once_per_slot (c t a b c' t' a' b' : UInt8) (l d n n' : UInt64)
    (h : scheduleStep 1 0 c t a b l d n = 3) :
    l < scheduleNextRef 3 l n ∧ scheduleStep 1 0 c' t' a' b' (scheduleNextRef 3 l n) d n' ≠ 3 := by
  have ⟨_, _, _, hl, hd, _⟩ := (schedule_fire_iff _ _ _ _ _ _ _).mp h
  simp only [scheduleNextRef, beq_self_eq_true, ite_true]
  refine ⟨?_, fun h' => ?_⟩
  · simp only [UInt64.lt_iff_toNat_lt, UInt64.le_iff_toNat_le] at *; omega
  · have := ((schedule_fire_iff _ _ _ _ _ _ _).mp h').2.2.2.1
    simp only [UInt64.lt_iff_toNat_lt, UInt64.le_iff_toNat_le] at *; omega

/-- Corollary 39 (`ClockDiscipline`): without a fire the reference never moves, so the next due
    slot is stable while the scheduler waits (busy or early ticks never shift the cadence). -/
theorem schedule_ref_monotone (act : UInt8) (l n : UInt64) (h : l ≤ n) :
    l ≤ scheduleNextRef act l n ∧ (act ≠ 3 → scheduleNextRef act l n = l) := by
  unfold scheduleNextRef; by_cases ha : act = 3 <;> simp [ha, h]

/-- Durable state of one schedule row between scheduler ticks. -/
structure ScheduleState where
  cancelled     : UInt8
  ownerTerminal : UInt8
  lastFired     : UInt64
  deriving Repr, DecidableEq

/-- A scheduler tick observed by a row: `(nextDue, now, busy)`. -/
structure ScheduleTick where
  nextDue : UInt64
  now     : UInt64
  busy    : UInt8
  deriving Repr, DecidableEq

def ScheduleState.tick (s : ScheduleState) (e : ScheduleTick) : ScheduleState :=
  let act := scheduleStep 1 0 s.cancelled s.ownerTerminal 1 e.busy s.lastFired e.nextDue e.now
  { s with lastFired := scheduleNextRef act s.lastFired e.now }

/-- `StickyFence` instance: once cancelled (by the user or a mission Stop) or orphaned, a schedule
    stays fenced across every later tick and can never fire, even for the most permissive tick. -/
def scheduleFence : StickyFence ScheduleState ScheduleTick where
  fenced s := s.cancelled == 1 || s.ownerTerminal == 1
  preFenceAct s := scheduleStep 1 0 s.cancelled s.ownerTerminal 1 0 0 1 0xFFFFFFFFFFFFFFFF == 3
  step := ScheduleState.tick
  sticky s e h := by simpa [ScheduleState.tick] using h
  forbids_post s e h := by
    simp only [ScheduleState.tick, beq_iff_eq, Bool.or_eq_true] at h ⊢
    rcases h with h | h <;> simp [h, scheduleStep, scheduleAction]

/-- Corollary 40 (`StickyFence`): a cancelled schedule or a terminal owner drops every tick,
    for every clock value and busy state. -/
theorem schedule_fenced_drops (k a b : UInt8) (l d n : UInt64) (c t : UInt8) (h : c = 1 ∨ t = 1) :
    scheduleStep 1 k c t a b l d n ≠ 3 ∧ scheduleStep 1 k c t a b l d n ≠ 1 := by
  unfold scheduleStep scheduleAction
  rcases h with h | h <;> by_cases ha : a = 1 <;> simp [h, ha]

/-- `ScopedAuthority` instance: only the owning mission/user can register a schedule or make it fire. -/
def scheduleAuthority : ScopedAuthority ScheduleInput where
  admit x := x.action == 1 || x.action == 3
  scopeValid x := x.authorized == 1
  sound x h := by
    unfold ScheduleInput.action scheduleStep scheduleAction at h
    by_cases ha : x.authorized = 1
    · simp [ha]
    · simp [ha] at h

/-- Corollary 41 (`ScopedAuthority`): an unauthorized caller is dropped for every operation. -/
theorem schedule_unauthorized_drops (op k c t a b : UInt8) (l d n : UInt64) (h : a ≠ 1) :
    scheduleStep op k c t a b l d n = 0 := by
  unfold scheduleStep scheduleAction; simp [h]

/-! ## Spend statistics (`orb_stats_settle_step`, `docs/specs/mission-stats.md`)

A settled spend row: request id, the bucket it is grouped in (served `(provider, model)`, or the VM
bucket; or a mission id for subtree totals), and its cost. Statistics are pure aggregation, so
conservation is a property of the grouping, stated over `Nat`. -/

structure StatRow where
  id    : Nat
  key   : Nat
  cents : Nat
  deriving Repr, DecidableEq

/-- Total cost of rows. -/
def statTotal : List StatRow → Nat
  | [] => 0
  | r :: rs => r.cents + statTotal rs

/-- Grouping by an ordered list of buckets: bucket `k` takes the rows with key `k`, the rest go on. -/
def statBuckets : List Nat → List StatRow → Nat
  | [], _ => 0
  | k :: ks, rows => statTotal (rows.filter (·.key == k)) + statBuckets ks (rows.filter (·.key != k))

theorem statTotal_split (p : StatRow → Bool) (rows : List StatRow) :
    statTotal rows = statTotal (rows.filter p) + statTotal (rows.filter (fun r => !p r)) := by
  induction rows with
  | nil => rfl
  | cons r rs ih => cases h : p r <;> simp [statTotal, List.filter, h, ih] <;> omega

/-- Conservation (`ConservedResource` for statistics): when every row's key is listed, the bucket
    totals sum to the total. Instances: per-mission total = Σ served models + VM bucket; subtree total
    = own + Σ children (keys = mission ids). -/
theorem statBuckets_conserve (keys : List Nat) (rows : List StatRow)
    (h : ∀ r ∈ rows, r.key ∈ keys) : statBuckets keys rows = statTotal rows := by
  induction keys generalizing rows with
  | nil =>
    cases rows with
    | nil => rfl
    | cons r rs => exact absurd (h r (List.mem_cons_self ..)) (List.not_mem_nil)
  | cons k ks ih =>
    have hrest : ∀ r ∈ rows.filter (·.key != k), r.key ∈ ks := by
      intro r hr
      have ⟨hm, hk⟩ := List.mem_filter.mp hr
      have := h r hm
      simp at hk this
      rcases this with h1 | h1 <;> simp_all
    rw [statBuckets, ih _ hrest, statTotal_split (·.key == k) rows]
    rfl

/-- Settle with replay protection: a row whose id was already settled adds nothing. -/
def statSettle : List Nat → List StatRow → Nat
  | _, [] => 0
  | seen, r :: rs =>
    if r.id ∈ seen then statSettle seen rs else r.cents + statSettle (r.id :: seen) rs

/-- Idempotency (`IdempotentOutboxSpec` instance): the kernel step admits a request's cost iff its id
    was not settled yet; a replay is rejected. -/
def statsOutbox : IdempotentOutboxSpec (List Nat) Nat where
  admit seen id := statsSettle 0 1 (if id ∈ seen then 1 else 0) == 1
  safeReplay seen id := !(decide (id ∈ seen))
  admit_iff_safe_replay seen id := by
    by_cases h : id ∈ seen <;> simp [statsSettle, h] <;> decide

/-- Replaying an already-settled request changes no total. -/
theorem statSettle_replay (seen : List Nat) (r : StatRow) (rs : List StatRow) (h : r.id ∈ seen) :
    statSettle seen (r :: rs) = statSettle seen rs := by
  simp [statSettle, h]

/-- Without replays (all ids fresh and distinct), settling is the plain total. -/
theorem statSettle_fresh (seen : List Nat) (rows : List StatRow)
    (h : ∀ r ∈ rows, r.id ∉ seen) (hd : (rows.map (·.id)).Nodup) :
    statSettle seen rows = statTotal rows := by
  induction rows generalizing seen with
  | nil => rfl
  | cons r rs ih =>
    have hr : r.id ∉ seen := h r (List.mem_cons_self ..)
    have hd' := List.nodup_cons.mp (by simpa only [List.map_cons] using hd)
    simp only [statSettle, hr, ite_false, statTotal]
    congr 1
    apply ih
    · intro x hx hmem
      rcases List.mem_cons.mp hmem with h1 | h1
      · exact hd'.1 (h1 ▸ List.mem_map.mpr ⟨x, hx, rfl⟩)
      · exact h x (List.mem_cons_of_mem _ hx) h1
    · exact hd'.2

/-- Corollary 40 (`orb_stats_settle_step`): a fresh request adds its cost, a replay adds nothing, and
    the total saturates instead of wrapping. -/
theorem stats_settle_fresh_replay_saturate :
    statsSettleStep 10 5 0 = 15 ∧ statsSettleStep 10 5 1 = 10 ∧
    statsSettleStep 18446744073709551610 10 0 = 18446744073709551615 := by decide

/-! ## Layer II: Biometric JIT Privilege Broker, Bunker Mode & Production Deploy Gate
    (`orb_privilege_step`, `orb_bunker_step`, `orb_deploy_gate_step`) -/

/-- Corollary 41 (`ScopedAuthority` — `orb_privilege_step`): Without a hardware biometric signature
    (`biometricSigned == 0`) or outside normal Bunker state (`bunkerState != 0`), privileged execution
    (`bit 0`) is strictly `0`. -/
theorem privilege_requires_biometric_and_unbunkered
    (owner active scope maxScope revoked : UInt8) (now gExp sExp : UInt64) :
    (privilegeStep owner active 0 scope maxScope 0 revoked now gExp sExp &&& 1) = 0 ∧
    (privilegeStep owner active 1 scope maxScope 1 revoked now gExp sExp &&& 1) = 0 ∧
    (privilegeStep owner active 1 scope maxScope 2 revoked now gExp sExp &&& 1) = 0 := by
  unfold privilegeStep; repeat (first | constructor | split | decide | simp_all)

/-- Corollary 42 (`ClockDiscipline` — `orb_privilege_step`): Session termination or session expiry strictly
    bounds the grant clock: when `missionActive == 0` or `sessionExpiresAt ≤ nowEpoch`, execution (`bit 0`)
    is `0` and `reapGrant` (`bit 16`) is `65536` even if `nowEpoch < grantExpiresAt`. -/
theorem privilege_bounded_by_session_clock
    (owner bio scope maxScope bunker rev : UInt8) (now gExp sExp : UInt64) :
    (privilegeStep owner 0 bio scope maxScope bunker rev now gExp sExp &&& 1) = 0 ∧
    (privilegeStep owner 0 bio scope maxScope bunker rev now gExp sExp &&& 65536) = 65536 ∧
    (privilegeStep owner 1 bio scope maxScope bunker rev now gExp now &&& 1) = 0 ∧
    (privilegeStep owner 1 bio scope maxScope bunker rev now gExp now &&& 65536) = 65536 := by
  unfold privilegeStep; repeat (first | constructor | split | decide | simp_all)

/-- Corollary 43 (`StickyFence` — `orb_bunker_step`): Once in Bunker Mode (`currentState == 1` or `2`),
    without a hardware-signed operator reset (`biometricUnbunker == 0`), the node never returns to normal
    (`nextState != 0`) and always revokes all JIT root grants (`bit 8 == 256`), and any canary trip
    (`canaryTripped == 1`) forces hard lockdown (`2`, `bit 16 == 65536`). -/
theorem bunker_sticky_without_biometric_reset
    (canary burst manual unbunker : UInt8) :
    (bunkerStep 1 canary burst manual 0 &&& 255) ≥ 1 ∧
    (bunkerStep 1 canary burst manual 0 &&& 256) = 256 ∧
    (bunkerStep 2 canary burst manual 0 &&& 255) = 2 ∧
    (bunkerStep 0 1 burst manual unbunker &&& 65536) = 65536 := by
  unfold bunkerStep; repeat (first | constructor | split | decide | simp_all)

/-- Corollary 44 (`ScopedAuthority` & `ConservedResource` — `orb_deploy_gate_step`): Production deploys
    (`isProdService == 1`) always reject unapproved requests (`biometricApproved == 0`) or bunkered states
    (`bunkerState != 0`), while dev/staging deploys (`isProdService == 0`) succeed without biometric prompt
    when base safety invariants hold. -/
theorem prod_deploy_requires_biometric_approval
    (svcMatch selfCall debounce force bunker : UInt8) (writers : UInt32) :
    deployGateStep 1 svcMatch selfCall debounce force 0 bunker writers = 0 ∧
    deployGateStep 1 svcMatch selfCall debounce force 1 1 writers = 0 ∧
    deployGateStep 0 1 0 1 0 0 0 0 = 1 ∧
    deployGateStep 1 1 0 1 0 1 0 0 = 1 := by
  unfold deployGateStep; repeat (first | constructor | split | decide | simp_all)

end Orb.Spec
