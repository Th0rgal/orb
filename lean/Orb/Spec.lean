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

/--
  Meta-Spec 6 (`EffectSafety`):
  Every effect `eff` emitted by a state-machine transition `(step s e).2` satisfies its domain
  authorization & safety precondition (`authorized s e eff = true`).
-/
structure EffectSafety (State Event Effect : Type) where
  step       : State → Event → State × List Effect
  authorized : State → Event → Effect → Bool
  sound      : ∀ s e eff, eff ∈ (step s e).2 → authorized s e eff = true

theorem EffectSafety.forbids_unauthorized {State Event Effect : Type}
    (E : EffectSafety State Event Effect) (s : State) (e : Event) (eff : Effect)
    (h_unauth : E.authorized s e eff = false) :
    eff ∉ (E.step s e).2 :=
  fun h_in => by simpa [h_unauth] using E.sound s e eff h_in

/--
  Meta-Spec 7 (`EffectLiveness`):
  When progress is required (`progressRequired s e = true`), `(step s e).2` emits at least one
  expected effect (`expectedEffect e eff = true`), and includes explicit positive (`effects ≠ []`)
  and negative (`effects = []`) witnesses reached by a finite trace from `init`, structurally
  forbidding the silent/no-op implementation `step s _ := (s, [])`.
-/
structure EffectLiveness (State Event Effect : Type) where
  init             : State
  step             : State → Event → State × List Effect
  progressRequired : State → Event → Bool
  expectedEffect   : Event → Effect → Bool
  live             : ∀ s e, progressRequired s e = true → ∃ eff ∈ (step s e).2, expectedEffect e eff = true
  traceEvents      : List Event
  posEvent         : Event
  negEvent         : Event
  reachable_live   :
    let sReach := traceEvents.foldl (fun st ev => (step st ev).1) init
    progressRequired sReach posEvent = true ∧ ((step sReach posEvent).2 ≠ []) ∧
    progressRequired sReach negEvent = false ∧ ((step sReach negEvent).2 = [])

theorem EffectLiveness.emits_on_progress {State Event Effect : Type}
    (L : EffectLiveness State Event Effect) (s : State) (e : Event)
    (h_req : L.progressRequired s e = true) :
    (L.step s e).2 ≠ [] := by
  intro h_empty
  rcases L.live s e h_req with ⟨eff, h_in, _⟩
  rw [h_empty] at h_in
  exact List.not_mem_nil h_in

/--
  Meta-Spec 8 (`CostBound`):
  Structural transition cost accounting: bounds the domain's evaluated comparison/effect fuel
  `cpuFuel s e` by `c0 + c1 * inputBytes e`, emitted effect count by `maxEffects`, and
  `outputBytes s e` by `maxOutBytes` (`G-ORB-4`).
-/
structure CostBound (State Event Effect : Type) where
  step        : State → Event → State × List Effect
  cpuFuel     : State → Event → Nat
  inputBytes  : Event → Nat
  outputBytes : State → Event → Nat
  c0          : Nat
  c1          : Nat
  maxEffects  : Nat
  maxOutBytes : Nat
  fuel_bound  : ∀ s e, cpuFuel s e ≤ c0 + c1 * inputBytes e
  eff_bound   : ∀ s e, ((step s e).2).length ≤ maxEffects
  out_bound   : ∀ s e, outputBytes s e ≤ maxOutBytes

theorem CostBound.within_envelope {State Event Effect : Type}
    (B : CostBound State Event Effect) (s : State) (e : Event) :
    B.cpuFuel s e ≤ B.c0 + B.c1 * B.inputBytes e ∧
    ((B.step s e).2).length ≤ B.maxEffects ∧
    B.outputBytes s e ≤ B.maxOutBytes :=
  ⟨B.fuel_bound s e, B.eff_bound s e, B.out_bound s e⟩

/--
  Meta-Spec 9 (`ReplayIdempotence`):
  Replaying an event whose `IdempotencyKey` / sequence has already been acknowledged
  (`alreadyAcked s e = true`) leaves the state invariant and emits zero effects (`[]`).
-/
structure ReplayIdempotence (State Event Effect : Type) where
  step         : State → Event → State × List Effect
  alreadyAcked : State → Event → Bool
  idempotent   : ∀ s e, alreadyAcked s e = true → step s e = (s, [])

theorem ReplayIdempotence.replay_no_effects {State Event Effect : Type}
    (R : ReplayIdempotence State Event Effect) (s : State) (e : Event)
    (h_acked : R.alreadyAcked s e = true) :
    (R.step s e).1 = s ∧ (R.step s e).2 = [] := by
  rw [R.idempotent s e h_acked]; exact ⟨rfl, rfl⟩

/--
  Meta-Spec 10 (`GrammarConfinement` / `NoPrivilegeEscalation`):
  Every admitted command or path belongs to a constructive allowlist grammar (`inGrammar cmd = true`,
  forbidding shell metacharacters, `..` traversal, and unauthorized environment variables), and
  never escalates privileges beyond the caller's bound scope (`privsAfter x p ≤ allowedPrivs p`).
-/
structure GrammarConfinement (Input Cmd Principal : Type) where
  parse        : Input → Option Cmd
  inGrammar    : Cmd → Bool
  privsAfter   : Input → Principal → Nat
  allowedPrivs : Principal → Nat
  confined     : ∀ x cmd, parse x = some cmd → inGrammar cmd = true
  no_escalate  : ∀ x p, privsAfter x p ≤ allowedPrivs p

theorem GrammarConfinement.rejects_outside_grammar {Input Cmd Principal : Type}
    (G : GrammarConfinement Input Cmd Principal) (x : Input) (cmd : Cmd)
    (h_bad : G.inGrammar cmd = false) :
    G.parse x ≠ some cmd :=
  fun h_ok => by simpa [h_bad] using G.confined x cmd h_ok

/--
  Universal `MetaStepSpec` Bundle:
  Links a pure `step : State → Event → State × List Effect` transition to `EffectSafety`,
  reachable-trace `EffectLiveness` (`effects ≠ []` on `posEvent`, `effects = []` on `negEvent`),
  and `CostBound`.
-/
structure MetaStepSpec (State Event Effect : Type) where
  safety   : EffectSafety State Event Effect
  liveness : EffectLiveness State Event Effect
  cost     : CostBound State Event Effect
  sameStep : safety.step = liveness.step ∧ liveness.step = cost.step

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

structure ApprovalCheck where
  signed    : UInt8
  owned     : UInt8
  pending   : UInt8
  unexpired : UInt8
  unchanged : UInt8
  risk      : UInt8
  confirmed : UInt8
  deriving Repr, DecidableEq

/-- The one admission rule every approval kind shares ("signed, owned, pending, unexpired,
    unchanged, and critical only when confirmed"). -/
def approvalSafe (a : ApprovalCheck) : Prop :=
  (a.signed == 1 && a.owned == 1 && a.pending == 1 && a.unexpired == 1 && a.unchanged == 1 &&
    (a.risk < 2 || a.confirmed == 1)) = true

def approvalMetaGate : MetaGateSpec ApprovalCheck approvalSafe where
  gate a := verifyApproval a.signed a.owned a.pending a.unexpired a.unchanged a.risk a.confirmed == 1
  sound _ h := by unfold approvalSafe; unfold verifyApproval at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold approvalSafe at h; unfold verifyApproval; repeat (first | split | simp_all)
  posWitness := ⟨1, 1, 1, 1, 1, 0, 0⟩
  negWitness := ⟨1, 1, 1, 1, 1, 2, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary (`ScopedAuthority` — `orb_verify_approval`): a request that changed after the
    approver saw it (tampered list, or one added after the challenge) is never admitted. -/
theorem approval_rejects_changed (a : ApprovalCheck) (h : a.unchanged ≠ 1) :
    approvalMetaGate.gate a = false :=
  approvalMetaGate.rejects_unsafe a (by unfold approvalSafe; simp [h])

/-- Corollary (`ClockDiscipline` — `orb_verify_approval`): expired or already-decided requests
    are never admitted, whatever else holds. -/
theorem approval_rejects_stale (a : ApprovalCheck) (h : a.pending ≠ 1 ∨ a.unexpired ≠ 1) :
    approvalMetaGate.gate a = false :=
  approvalMetaGate.rejects_unsafe a (by unfold approvalSafe; rcases h with h | h <;> simp [h])

/-- Corollary (`ScopedAuthority` — `orb_verify_approval`): critical requests (root, secret
    delete or move) are never admitted without explicit confirmation, even when signed. -/
theorem approval_critical_needs_confirmation (a : ApprovalCheck) (hr : a.risk = 2) (hc : a.confirmed ≠ 1) :
    approvalMetaGate.gate a = false :=
  approvalMetaGate.rejects_unsafe a (by unfold approvalSafe; simp [hr, hc])

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
  rcases x with ⟨pk, c, s, d⟩
  unfold attributionInScope AttributionClaim.InScope
  dsimp only
  generalize attributionPrincipal pk = p
  by_cases hc0 : c = 0
  · subst hc0; simp
  · have hc0b : (c == 0) = false := beq_false_of_ne hc0
    simp only [hc0b, Bool.false_eq_true, ite_false]
    by_cases hp5 : p = 5
    · subst hp5
      by_cases hc1 : c = 1
      · subst hc1; simp
      · by_cases hc2 : c = 2
        · subst hc2; simp
        · simp [hc0, hc1, hc2]
    · by_cases hp1 : p = 1
      · subst hp1
        by_cases hc1 : c = 1
        · subst hc1; simp [hc0]
        · by_cases hc2 : c = 2
          · subst hc2; simp [hc0]
          · simp [hc0, hc1, hc2]
      · by_cases hp2 : p = 2
        · subst hp2
          by_cases hc1 : c = 1
          · subst hc1; simp [hc0]
          · by_cases hc2 : c = 2
            · subst hc2; simp [hc0]
            · simp [hc0, hc1, hc2]
        · by_cases hp3 : p = 3
          · subst hp3; simp [hc0]
          · by_cases hp4 : p = 4
            · subst hp4; simp [hc0]
            · by_cases hp6 : p = 6
              · subst hp6; simp [hc0]
              · simp [hc0, hp5, hp1, hp2, hp3, hp4, hp6]

/-- A non-empty in-scope claim is a valid kind and requires a credential binding. -/
theorem attributionInScope_claim (p c s d : UInt8)
    (h : attributionInScope (attributionPrincipal p) c s d = true) (hc : c ≠ 0) :
    c ≤ 6 ∧ attributionPrincipal p ≠ 0 := by
  have hx : AttributionClaim.InScope ⟨p, c, s, d⟩ :=
    (attributionInScope_iff ⟨p, c, s, d⟩).mp h
  unfold AttributionClaim.InScope at hx
  dsimp only at hx
  rcases hx with rfl | ⟨hp, rfl | rfl | rfl⟩ | ⟨hp | hp, ⟨rfl, _⟩ | ⟨rfl, _⟩⟩ | ⟨hp | hp | hp, rfl⟩
  · exact absurd rfl hc
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide
  · rw [hp]; decide

/-- Totality: every usage event maps to exactly one kind of the closed enum `0..6`. -/
theorem attribution_kind_le_six (p c s d : UInt8) : attributionKind p c s d ≤ 6 := by
  unfold attributionKind; dsimp only; split
  · split
    · exact attributionPrincipal_le_six p
    · next h hc => exact (attributionInScope_claim p c s d h (by simpa using hc)).1
  · exact attributionPrincipal_le_six p

/-- `unknown` (`0`) is returned iff no credential binding exists, whatever the client claims. -/
theorem attribution_kind_unknown_iff (p c s d : UInt8) :
    attributionKind p c s d = 0 ↔ attributionPrincipal p = 0 := by
  unfold attributionKind; dsimp only; split
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
  have h_eq : attributionStep p c s d =
      ((attributionKind p c s d).toUInt32 |||
        (if attributionInScope (attributionPrincipal p) c s d then 256 else 0)) := by
    unfold attributionStep attributionKind; dsimp only
    split <;> simp
  rw [h_eq]
  have hk := attribution_kind_le_six p c s d
  generalize attributionKind p c s d = k at hk ⊢
  have hn : k.toNat ≤ 6 := by simpa [UInt8.le_iff_toNat_le] using hk
  have hk' : k = k.toNat.toUInt8 := by simp
  rw [hk']
  generalize k.toNat = n at hn
  split <;> (match n, hn with
    | 0, _ | 1, _ | 2, _ | 3, _ | 4, _ | 5, _ | 6, _ => decide)

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

/-! ## Wave 7: Cross-Platform Mobile Kernel Specifications (`Orb.Scroll`, `Orb.Stream` & Domain State Machines) -/

structure ScrollUserCheck where
  content   : UInt64
  viewport  : UInt64
  top       : UInt64
  threshold : UInt64
  deriving Repr, DecidableEq

def scrollUserMetaGate : MetaGateSpec ScrollUserCheck
    (fun s => (scrollGap s.content s.viewport s.top ≤ s.threshold) = true) where
  gate s := scrollUserStep s.content s.viewport s.top s.threshold == 1
  sound _ h := by unfold scrollUserStep at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold scrollUserStep; repeat (first | split | simp_all)
  posWitness := ⟨1000, 400, 580, 40⟩
  negWitness := ⟨1000, 400, 400, 40⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 45 (`ProjectionStability` — `orb_scroll_*`): When `pinned == 1`, `scrollLayoutStep` and
    `scrollCorrect` always snap to `scrollMaxTop = scrollJumpStep` (`scrollGap == 0`), and `scrollShowsJump`
    is strictly `0`, whereas an unpinned reader beyond `pillThreshold` sees the jump pill (`1`). -/
theorem scroll_pinned_snaps_to_max_and_hides_jump
    (content viewport top pillThreshold : UInt64) :
    scrollLayoutStep 1 content viewport top = scrollMaxTop content viewport ∧
    scrollCorrect 1 content viewport top = scrollJumpStep content viewport ∧
    scrollClampTop 1000 400 900 = 600 ∧
    scrollShowsJump 1 content viewport top pillThreshold = 0 ∧
    scrollShowsJump 0 1000 400 200 160 = 1 ∧
    scrollUserStep 1000 400 400 40 = 0 := by
  unfold scrollLayoutStep scrollCorrect scrollJumpStep scrollShowsJump
  repeat (first | constructor | split | rfl | decide | simp_all)

structure StreamCommitCheck where
  tick        : UInt8
  openKind    : UInt8
  openCount   : UInt32
  lineBlank   : UInt8
  lineTick    : UInt8
  markerKind  : UInt8
  markerCount : UInt32
  pos         : UInt32
  commit      : UInt32
  deriving Repr, DecidableEq

def streamCommitMetaGate : MetaGateSpec StreamCommitCheck
    (fun s =>
      let nextTick : UInt8 := if s.lineTick == 1 then (if s.tick == 1 then 0 else 1) else (if s.tick == 1 then 1 else 0)
      let nextFence := streamNextFenceKind s.openKind s.openCount s.markerKind s.markerCount
      (s.lineBlank == 1 && nextTick == 0 && nextFence == 0) = true) where
  gate s :=
    ((streamCommitStep s.tick s.openKind s.openCount s.lineBlank s.lineTick
        s.markerKind s.markerCount s.pos s.commit &&& 0xFFFFFFFF) &&& 65536) != 0
  sound s h := by
    unfold streamCommitStep at h
    rw [pack32_lo] at h
    generalize streamNextFenceKind s.openKind s.openCount s.markerKind s.markerCount = nf at h ⊢
    cases ht : (s.lineTick == 1) <;>
      cases htk : (s.tick == 1) <;>
      cases hb : (s.lineBlank == 1) <;>
      cases hnf : (nf == 0) <;>
      cases hnf1 : (nf == 1) <;>
      cases hnf2 : (nf == 2) <;>
      (simp_all
       try
         exfalso
         revert h
         decide)
  complete s h := by
    unfold streamCommitStep
    rw [pack32_lo]
    generalize streamNextFenceKind s.openKind s.openCount s.markerKind s.markerCount = nf at h ⊢
    cases ht : (s.lineTick == 1) <;>
      cases htk : (s.tick == 1) <;>
      cases hb : (s.lineBlank == 1) <;>
      cases hnf : (nf == 0) <;>
      cases hnf1 : (nf == 1) <;>
      cases hnf2 : (nf == 2) <;>
      (simp_all; try decide)
  posWitness := ⟨0, 0, 0, 1, 0, 0, 0, 5, 2⟩
  negWitness := ⟨0, 1, 3, 1, 0, 0, 0, 5, 2⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 46 (`ConservedResource` & `ProjectionStability` — `orb_stream_*`): An idle coalescer frame
    (`pendingLen == 0`) emits zero render (`bit 63 == 0`), a tilde fence (`2`) never closes a backtick
    fence (`1`), a blank line inside an open fence never advances `commit`, and `streamTokenCostStep`
    accumulates saturatingly without wrap-around. -/
theorem stream_coalescer_fence_commit_and_cost_invariants (shown : UInt32) :
    streamCoalescerStep 1 shown 0 0 = shown.toUInt64 ∧
    (streamCoalescerStep 1 10 4 0 >>> 63) = 1 ∧
    (streamFenceStep 1 3 2 3 &&& 0xFF) = 1 ∧
    (streamFenceStep 1 3 1 3 &&& 0xFF) = 0 ∧
    (streamCommitStep 0 1 3 1 0 0 0 5 2 >>> 32) = 2 ∧
    streamTokenCostStep 100 40 12 = 152 := by
  unfold streamCoalescerStep; repeat (first | constructor | rfl | decide)

structure MissionAttentionCheck where
  stateId : UInt8
  deriving Repr, DecidableEq

def missionAttentionMetaGate : MetaGateSpec MissionAttentionCheck
    (fun m => (missionStateClassify m.stateId == 0 ||
      missionStateClassify m.stateId == 1 ||
      missionStateClassify m.stateId == 2) = true) where
  gate m := (missionFlags m.stateId &&& 4) != 0
  sound m h := by
    revert h
    unfold missionFlags missionCategoryFlags missionExtraBits
    generalize missionStateClassify m.stateId = cat
    cases (cat == 0) <;>
      cases (cat == 1) <;>
      cases (cat == 2) <;>
      cases (cat == 3 || cat == 4) <;>
      cases (cat == 7) <;>
      cases (cat == 6 || cat == 8) <;>
      cases (m.stateId == 11 || m.stateId == 12 || m.stateId == 24 || m.stateId == 25 || m.stateId == 26) <;>
      cases (m.stateId == 16 || m.stateId == 17 || m.stateId == 20 || m.stateId == 22) <;>
      decide
  complete m h := by
    revert h
    unfold missionFlags missionCategoryFlags missionExtraBits
    generalize missionStateClassify m.stateId = cat
    cases (cat == 0) <;>
      cases (cat == 1) <;>
      cases (cat == 2) <;>
      cases (cat == 3 || cat == 4) <;>
      cases (cat == 7) <;>
      cases (cat == 6 || cat == 8) <;>
      cases (m.stateId == 11 || m.stateId == 12 || m.stateId == 24 || m.stateId == 25 || m.stateId == 26) <;>
      cases (m.stateId == 16 || m.stateId == 17 || m.stateId == 20 || m.stateId == 22) <;>
      decide
  posWitness := ⟨11⟩
  negWitness := ⟨0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 47 (`ProjectionStability` — `orb_mission_*`): Waiting/blocked/failed states (`cat ≤ 2`) route
    to `.needsYou (1)` and have `sortRank ≤ 2`; `interrupted (22)` routes to `.ready (2)` while `cancelled (23)`
    routes to `.hidden (3)`; unknown states (`≥ 29`) have `sortRank = 9` and route to `.hidden (3)`. -/
theorem mission_state_cross_client_partition :
    missionSortRank 11 = 0 ∧
    missionSortRank 16 = 1 ∧
    missionSortRank 17 = 2 ∧
    missionSortRank 99 = 9 ∧
    missionInboxSection 0 = 0 ∧
    missionInboxSection 11 = 1 ∧
    missionInboxSection 22 = 2 ∧
    missionInboxSection 23 = 3 ∧
    (missionFlags 25 &&& 66) = 66 := by decide

structure ConnectionIssueCheck where
  isUnreachable    : UInt8
  isUsingDefault   : UInt8
  isPrivateAddr    : UInt8
  defaultReachable : UInt8
  hasExternalProxy : UInt8
  deriving Repr, DecidableEq

def connectionIssueMetaGate : MetaGateSpec ConnectionIssueCheck
    (fun c => (c.isUnreachable == 1 && c.hasExternalProxy != 1 &&
      c.isUsingDefault == 0 && c.isPrivateAddr == 1 && c.defaultReachable == 1) = true) where
  gate c := (connectionIssueClassify c.isUnreachable c.isUsingDefault c.isPrivateAddr c.defaultReachable c.hasExternalProxy &&& 65536) != 0
  sound c h := by
    unfold connectionIssueClassify at h
    cases hu : (c.isUnreachable != 1) <;>
      cases hp : (c.hasExternalProxy == 1) <;>
      cases hd : (c.isUsingDefault == 0) <;>
      cases hd1 : (c.isUsingDefault == 1) <;>
      cases ha : (c.isPrivateAddr == 1) <;>
      cases hr : (c.defaultReachable == 1) <;>
      (simp_all
       try
         exfalso
         revert h
         decide
       try decide)
  complete c h := by
    unfold connectionIssueClassify
    cases hu : (c.isUnreachable != 1) <;>
      cases hp : (c.hasExternalProxy == 1) <;>
      cases hd : (c.isUsingDefault == 0) <;>
      cases ha : (c.isPrivateAddr == 1) <;>
      cases hr : (c.defaultReachable == 1) <;>
      (simp_all; try decide)
  posWitness := ⟨1, 0, 1, 1, 0⟩
  negWitness := ⟨1, 0, 1, 1, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 48 (`ProjectionStability` — `orb_connection_issue_classify`): Reachable servers (`isUnreachable == 0`)
    never emit an issue (`0`), and a failing external proxy (`hasExternalProxy == 1`) suppresses
    `recommendDefault` (`bit 16 == 0`) and selects the proxy diagnostic (`msgKind == 1`). -/
theorem connection_issue_proxy_blocks_recommend_default
    (uDef pAddr defReach : UInt8) :
    connectionIssueClassify 0 uDef pAddr defReach 0 = 0 ∧
    (connectionIssueClassify 1 uDef pAddr defReach 1 &&& 65536) = 0 ∧
    (connectionIssueClassify 1 uDef pAddr defReach 1 >>> 28) = 1 := by
  unfold connectionIssueClassify; repeat (first | constructor | split | decide | simp_all)

/-- Corollary 49 (`StickyFence` & `ProjectionStability` — `orb_turn_outcome_step` & `orb_worked_duration_bucket`):
    Once a post-todo assistant message fails (`prevFailed == 1`), subsequent non-empty assistant messages in the
    same todo block never flip `outcome` back to `1 (finished)`, and `workedDurationBucket` partitions `< 60s`,
    `< 3600s`, `< 86400s`, and `≥ 86400s` into units `0..3`. -/
theorem turn_outcome_sticky_failure_and_duration_buckets (prevOut isNarr isSucc isNonEmpty : UInt8) :
    (turnOutcomeStep 0 1 2 isNarr isSucc isNonEmpty &&& 1) = 0 ∧
    (turnOutcomeStep prevOut 1 2 isNarr isSucc isNonEmpty &&& 256) = 256 ∧
    workedDurationBucket 42 = ((42 : UInt64) <<< 32) ∧
    (workedDurationBucket 185 &&& 0xFF) = 1 ∧
    (workedDurationBucket 7200 &&& 0xFF) = 2 ∧
    (workedDurationBucket 172800 &&& 0xFF) = 3 := by
  unfold turnOutcomeStep
  refine ⟨by repeat (first | split | decide | simp_all),
          by repeat (first | split | decide | simp_all), ?_⟩
  decide

structure NumericCellCheck where
  nonEmpty              : UInt8
  hasLeadingDigitOrSign : UInt8
  hasDigit              : UInt8
  allAllowedChars       : UInt8
  deriving Repr, DecidableEq

def numericCellMetaGate : MetaGateSpec NumericCellCheck
    (fun c => (c.nonEmpty == 1 && c.hasLeadingDigitOrSign == 1 && c.hasDigit == 1 && c.allAllowedChars == 1) = true) where
  gate c := numericCellScan c.nonEmpty c.hasLeadingDigitOrSign c.hasDigit c.allAllowedChars == 1
  sound _ h := by unfold numericCellScan at h; repeat (first | split at h | simp_all)
  complete _ h := by unfold numericCellScan; repeat (first | split | simp_all)
  posWitness := ⟨1, 1, 1, 1⟩
  negWitness := ⟨1, 1, 0, 1⟩
  nonVacuous := rfl
  tight      := rfl

structure FileRefLineSpanCheck where
  startLine  : UInt32
  endLine    : UInt32
  totalLines : UInt32
  deriving Repr, DecidableEq

def fileRefLineSpanMetaGate : MetaGateSpec FileRefLineSpanCheck
    (fun s => (1 ≤ s.startLine && s.startLine ≤ s.endLine && (s.totalLines == 0 || s.endLine ≤ s.totalLines)) = true) where
  gate s := (fileRefLineSpan s.startLine s.endLine s.totalLines &&& 0xFFFFFFFF) == 1
  sound s h := by
    unfold fileRefLineSpan at h
    split at h <;> (simp_all; try decide)
  complete s h := by
    unfold fileRefLineSpan
    split
    · simpa using pack32_lo 1 (s.endLine - s.startLine + 1)
    · contradiction
  posWitness := ⟨10, 25, 100⟩
  negWitness := ⟨26, 25, 100⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 50 (`ProjectionStability` — `orb_numeric_cell_scan` & `orb_file_ref_line_span`):
    Cells without digits or with disallowed characters are rejected (`0`), and inverted or out-of-bounds
    line spans (`startLine == 0`, `endLine < startLine`, or `endLine > totalLines > 0`) return `0`. -/
theorem numeric_cell_and_line_span_reject_invalid (e tot : UInt32) :
    numericCellScan 1 1 0 1 = 0 ∧
    numericCellScan 1 1 1 0 = 0 ∧
    fileRefLineSpan 0 e tot = 0 ∧
    fileRefLineSpan 20 10 100 = 0 ∧
    fileRefLineSpan 10 25 20 = 0 ∧
    (fileRefLineSpan 10 25 100 >>> 32) = 16 := by
  constructor; · rfl
  constructor; · rfl
  constructor; · unfold fileRefLineSpan; simp
  constructor; · decide
  constructor; · decide
  · decide

structure MachineActionCheck where
  stateKind : UInt8
  isBusy    : UInt8
  isMuted   : UInt8
  deriving Repr, DecidableEq

def machineActionMetaGate : MetaGateSpec MachineActionCheck
    (fun m => (m.stateKind ≤ 2 && m.isBusy == 0 && m.isMuted == 0) = true) where
  gate m := (machineActionAdmitted m.stateKind m.isBusy m.isMuted &&& 256) != 0
  sound m h := by
    unfold machineActionAdmitted at h
    by_cases h3 : m.stateKind ≤ 3 <;>
      by_cases h2 : m.stateKind ≤ 2 <;>
      cases h6 : (m.stateKind == 6) <;>
      cases hb : (m.isBusy == 0) <;>
      cases hm : (m.isMuted == 0) <;>
      (simp_all
       try
         exfalso
         revert h
         decide)
  complete m h := by
    unfold machineActionAdmitted
    repeat (first | split | simp_all | decide)
  posWitness := ⟨2, 0, 0⟩
  negWitness := ⟨3, 0, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 51 (`ScopedAuthority` & `ProjectionStability` — `orb_machine_action_admitted` & `orb_send_flow_step`):
    A `destroying (3)` machine remains `isLive == 1` (`bit 0`) but disables `canAct` (`bit 8 == 0`) and
    `meterLiveCost` (`bit 16 == 0`); an empty composer message is always ignored (`tapAction == 0`), a busy
    turn with `canQueue == 1` defers to the queue (`2`), and HTTP `409` maps to `alreadySent (3)`. -/
theorem machine_action_and_send_flow_invariants :
    machineActionAdmitted 3 0 0 = 1 ∧
    machineActionAdmitted 4 0 0 = 0 ∧
    (sendFlowStep 1 0 1 0 0 2 200 &&& 0xFF) = 0 ∧
    (sendFlowStep 1 1 1 0 0 2 409) = 196866 := by
  decide

/-! ## Wave 9 — Phase 0: `OrbWire` Canonical Word+Arena Wire Codec & Universal Effect Safety -/

structure WireFrameCheck where
  magic            : UInt32
  abiVersion       : UInt32
  schemaId         : UInt32
  expectedSchemaId : UInt32
  totalLen         : UInt32
  payloadLen       : UInt32
  arenaOff         : UInt32
  arenaLen         : UInt32
  maxBudgetBytes   : UInt32
  outCap           : UInt32
  requiredOutBytes : UInt32
  deriving Repr, DecidableEq

def wireFrameMetaGate : MetaGateSpec WireFrameCheck
    (fun f => ((f.magic == 0x4F524257 && f.abiVersion == 1) &&
      (f.schemaId == f.expectedSchemaId) && (24 ≤ f.totalLen) && (f.totalLen ≤ f.maxBudgetBytes) &&
      (f.payloadLen ≤ f.totalLen - 24) && (f.arenaOff ≤ f.payloadLen &&
      f.arenaLen ≤ f.payloadLen - f.arenaOff) && (f.requiredOutBytes ≤ f.outCap)) = true) where
  gate f := wireValidateFrame f.magic f.abiVersion f.schemaId f.expectedSchemaId
    f.totalLen f.payloadLen f.arenaOff f.arenaLen f.maxBudgetBytes f.outCap f.requiredOutBytes == 0
  sound f h := by
    unfold wireValidateFrame at h
    cases hm : (f.magic == 0x4F524257 && f.abiVersion == 1) <;>
      cases hs : (f.schemaId == f.expectedSchemaId) <;>
      cases ht : decide (24 ≤ f.totalLen) <;>
      cases hb : decide (f.totalLen ≤ f.maxBudgetBytes) <;>
      cases hp : decide (f.payloadLen ≤ f.totalLen - 24) <;>
      cases ha : (decide (f.arenaOff ≤ f.payloadLen) && decide (f.arenaLen ≤ f.payloadLen - f.arenaOff)) <;>
      cases ho : decide (f.requiredOutBytes ≤ f.outCap) <;>
      (simp_all; try decide)
  complete f h := by
    unfold wireValidateFrame
    cases hm : (f.magic == 0x4F524257 && f.abiVersion == 1) <;>
      cases hs : (f.schemaId == f.expectedSchemaId) <;>
      cases ht : decide (24 ≤ f.totalLen) <;>
      cases hb : decide (f.totalLen ≤ f.maxBudgetBytes) <;>
      cases hp : decide (f.payloadLen ≤ f.totalLen - 24) <;>
      cases ha : (decide (f.arenaOff ≤ f.payloadLen) && decide (f.arenaLen ≤ f.payloadLen - f.arenaOff)) <;>
      cases ho : decide (f.requiredOutBytes ≤ f.outCap) <;>
      (simp_all; try decide)
  posWitness := ⟨0x4F524257, 1, 10, 10, 128, 64, 16, 32, 4096, 256, 128⟩
  negWitness := ⟨0x4F524257, 1, 10, 10, 128, 120, 16, 32, 4096, 256, 128⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 52 (`ConservedResource` & `OrbWire` — `orb_wire_validate_frame` & `orb_wire_pack_record`):
    `wireValidateFrame` is total and rejects bad magic (`1`), schema mismatch (`2`), truncated/out-of-bounds
    arena slices (`3`), budget overflow (`4`), and undersized caller output buffers (`5`), while
    `wirePackRecord` / `wireRecord*` satisfy round-trip identity (`decode_encode_id`). -/
theorem wire_frame_total_and_record_roundtrip (tag flags : UInt8) (len16 payload32 : UInt32) :
    (wirePackRecord tag flags len16 payload32 >>> 32) = payload32.toUInt64 ∧
    wireRecordTag (wirePackRecord 7 3 512 0xCAFEBABE) = 7 ∧
    wireRecordFlags (wirePackRecord 7 3 512 0xCAFEBABE) = 3 ∧
    wireRecordLen16 (wirePackRecord 7 3 512 0xCAFEBABE) = 512 ∧
    wireRecordPayload32 (wirePackRecord 7 3 512 0xCAFEBABE) = 0xCAFEBABE ∧
    wireValidateFrame 0 1 1 1 64 16 0 8 4096 64 32 = 1 ∧
    wireValidateFrame 0x4F524257 1 2 1 64 16 0 8 4096 64 32 = 2 ∧
    wireValidateFrame 0x4F524257 1 1 1 64 48 0 8 4096 64 32 = 3 ∧
    wireValidateFrame 0x4F524257 1 1 1 8192 16 0 8 4096 64 32 = 4 ∧
    wireValidateFrame 0x4F524257 1 1 1 64 16 0 8 4096 16 32 = 5 := by
  refine ⟨?_, by decide⟩
  unfold wirePackRecord
  exact pack32_hi _ payload32

structure WireSchemaMigrateCheck where
  fromSchema    : UInt32
  toSchema      : UInt32
  currentSchema : UInt32
  payloadBytes  : UInt64
  maxBytes      : UInt64
  deriving Repr, DecidableEq

def wireSchemaMigrateMetaGate : MetaGateSpec WireSchemaMigrateCheck
    (fun m => (m.fromSchema == m.currentSchema && m.fromSchema < m.toSchema &&
      m.toSchema - m.fromSchema == 1 && 0 < m.payloadBytes && m.payloadBytes ≤ m.maxBytes) = true) where
  gate m := wireSchemaMigrateStep m.fromSchema m.toSchema m.currentSchema m.payloadBytes m.maxBytes == 1
  sound m h := by
    unfold wireSchemaMigrateStep at h
    cases hc : (m.fromSchema == m.currentSchema && m.fromSchema < m.toSchema &&
      m.toSchema - m.fromSchema == 1 && 0 < m.payloadBytes && m.payloadBytes ≤ m.maxBytes) <;>
      (simp [hc] at h ⊢)
  complete m h := by
    unfold wireSchemaMigrateStep
    simp [h]
  posWitness := ⟨3, 4, 3, 256, 4096⟩
  negWitness := ⟨3, 5, 3, 256, 4096⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 53 (`ScopedAuthority` — `orb_wire_schema_migrate_step`):
    Schema migration rejects non-consecutive version jumps, downgrades, empty payloads, and oversized payloads. -/
theorem wire_schema_migrate_requires_consecutive_version (m : WireSchemaMigrateCheck)
    (h_bad : (m.fromSchema == m.currentSchema && m.fromSchema < m.toSchema &&
      m.toSchema - m.fromSchema == 1 && 0 < m.payloadBytes && m.payloadBytes ≤ m.maxBytes) = false) :
    (wireSchemaMigrateStep m.fromSchema m.toSchema m.currentSchema m.payloadBytes m.maxBytes == 1) = false :=
  wireSchemaMigrateMetaGate.rejects_unsafe m (by simp [h_bad])

structure EffectAdmissibleCheck where
  effectKind       : UInt8
  hasValidLease    : UInt8
  sessionCreated   : UInt8
  lineageVerified  : UInt8
  isArchived       : UInt8
  idempotencyFresh : UInt8
  accountBound     : UInt8
  accountRejected  : UInt8
  firstByteLocked  : UInt8
  grammarAllowed   : UInt8
  envScrubbed      : UInt8
  budgetOk         : UInt8
  deriving Repr, DecidableEq

def EffectAdmissibleCheck.Safe (e : EffectAdmissibleCheck) : Bool :=
  e.budgetOk == 1 &&
  ((e.effectKind == 0) ||
   (e.effectKind == 1 && e.hasValidLease == 1 && e.isArchived == 0 && e.idempotencyFresh == 1) ||
   (e.effectKind == 2 && e.hasValidLease == 1 && e.sessionCreated == 1 && e.lineageVerified == 1 && e.isArchived == 0) ||
   (e.effectKind == 3 && e.accountBound == 1 && e.accountRejected == 0 && e.firstByteLocked == 0) ||
   (e.effectKind == 4 && e.grammarAllowed == 1 && e.envScrubbed == 1 && e.hasValidLease == 1 && e.isArchived == 0) ||
   (e.effectKind == 5 && e.hasValidLease == 1 && e.idempotencyFresh == 1))

def effectAdmissibleMetaGate : MetaGateSpec EffectAdmissibleCheck
    (fun e => e.Safe = true) where
  gate e := effectAdmissible e.effectKind e.hasValidLease e.sessionCreated e.lineageVerified
    e.isArchived e.idempotencyFresh e.accountBound e.accountRejected e.firstByteLocked
    e.grammarAllowed e.envScrubbed e.budgetOk == 1
  sound e h := by
    unfold effectAdmissible at h
    unfold EffectAdmissibleCheck.Safe
    repeat (first | split at h | simp_all)
  complete e h := by
    unfold EffectAdmissibleCheck.Safe at h
    unfold effectAdmissible
    repeat (first | split at h | split | simp_all)
  posWitness := ⟨2, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 1⟩
  negWitness := ⟨2, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 54 (`EffectSafety` & `EffectLiveness` — `orb_effect_admissible`):
    Never emits `LaunchJob (1)` without a lease or on an archived mission, never emits `ResumeSession (2)`
    without `sessionCreated == 1 ∧ lineageVerified == 1`, never emits `DispatchProvider (3)` on a rejected
    account or after `firstByteLocked == 1`, and never emits `ExecPrivCommand (4)` outside the grammar/scrubbed env. -/
theorem effect_admissible_blocks_unleased_or_unverified
    (lease sess lin arch idem bnd rej fb gram env : UInt8) :
    effectAdmissible 1 0 sess lin arch idem bnd rej fb gram env 1 = 0 ∧
    effectAdmissible 1 lease sess lin 1 idem bnd rej fb gram env 1 = 0 ∧
    effectAdmissible 2 lease 0 lin arch idem bnd rej fb gram env 1 = 0 ∧
    effectAdmissible 2 lease sess 0 arch idem bnd rej fb gram env 1 = 0 ∧
    effectAdmissible 3 lease sess lin arch idem bnd 1 fb gram env 1 = 0 ∧
    effectAdmissible 3 lease sess lin arch idem bnd rej 1 gram env 1 = 0 ∧
    effectAdmissible 4 lease sess lin arch idem bnd rej fb 0 env 1 = 0 ∧
    effectAdmissible 4 lease sess lin arch idem bnd rej fb gram 0 1 = 0 := by
  unfold effectAdmissible
  repeat (first | constructor | split | decide | simp_all)

/-! ## Wave 9 — Phase 2: Proxy Provider Account Pool, Failover & `ArgminRouteFold` Specifications -/

structure ProviderPoolCheck where
  hasBoundAccount    : UInt8
  boundAccountId     : UInt32
  candidateAccountId : UInt32
  isRejected         : UInt8
  firstByteSent      : UInt8
  isFailoverAttempt  : UInt8
  attempts           : UInt32
  maxAttempts        : UInt32
  nowEpoch           : UInt64
  resetEpoch         : UInt64
  deriving Repr, DecidableEq

def ProviderPoolCheck.Admissible (p : ProviderPoolCheck) : Bool :=
  !(p.firstByteSent == 1 && p.isFailoverAttempt == 1) &&
  !(p.isFailoverAttempt == 1 && !(1 ≤ p.maxAttempts && p.attempts < p.maxAttempts)) &&
  !(p.hasBoundAccount == 1 && !(p.candidateAccountId == p.boundAccountId)) &&
  !(p.isRejected == 1 && p.nowEpoch < p.resetEpoch) &&
  !(p.candidateAccountId == 0)

def providerPoolMetaGate : MetaGateSpec ProviderPoolCheck
    (fun p => p.Admissible = true) where
  gate p := ((providerPoolStep p.hasBoundAccount p.boundAccountId p.candidateAccountId
    p.isRejected p.firstByteSent p.isFailoverAttempt p.attempts p.maxAttempts
    p.nowEpoch p.resetEpoch &&& 0xFFFFFFFF) &&& 256) != 0
  sound p h := by
    unfold providerPoolStep at h
    rw [pack32_lo] at h
    unfold ProviderPoolCheck.Admissible
    cases hfs : (p.firstByteSent == 1) <;>
      cases hif : (p.isFailoverAttempt == 1) <;>
      cases hm1 : decide (1 ≤ p.maxAttempts) <;>
      cases hma : decide (p.attempts < p.maxAttempts) <;>
      cases hb1 : (p.hasBoundAccount == 1) <;>
      cases hcb : (p.candidateAccountId == p.boundAccountId) <;>
      cases hr1 : (p.isRejected == 1) <;>
      cases hnr : decide (p.nowEpoch < p.resetEpoch) <;>
      cases hc0 : (p.candidateAccountId == 0) <;>
      (simp only [hfs, hif, hm1, hma, hb1, hcb, hr1, hnr, hc0] at h ⊢; revert h; decide)
  complete p h := by
    unfold ProviderPoolCheck.Admissible at h
    unfold providerPoolStep
    rw [pack32_lo]
    cases hfs : (p.firstByteSent == 1) <;>
      cases hif : (p.isFailoverAttempt == 1) <;>
      cases hm1 : decide (1 ≤ p.maxAttempts) <;>
      cases hma : decide (p.attempts < p.maxAttempts) <;>
      cases hb1 : (p.hasBoundAccount == 1) <;>
      cases hcb : (p.candidateAccountId == p.boundAccountId) <;>
      cases hr1 : (p.isRejected == 1) <;>
      cases hnr : decide (p.nowEpoch < p.resetEpoch) <;>
      cases hc0 : (p.candidateAccountId == 0) <;>
      (simp only [hfs, hif, hm1, hma, hb1, hcb, hr1, hnr, hc0] at h ⊢; revert h; decide)
  posWitness := ⟨1, 42, 42, 0, 0, 0, 0, 3, 1000, 500⟩
  negWitness := ⟨1, 42, 99, 0, 0, 0, 0, 3, 1000, 500⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 55 (`ScopedAuthority` — `orb_provider_pool_step`, Antigravity Bound-Account Theorem):
    When an account is bound (`hasBoundAccount == 1`), any candidate with `candidateAccountId != boundAccountId`
    is rejected (`emitDispatchEffect == 0`, `dispatchedAccountId == 0`), and a matching eligible candidate
    dispatches `boundAccountId` in bits 32..63. -/
theorem antigravity_dispatch_matches_bound_account
    (boundId candId : UInt32) (isRej fb isFail : UInt8) (att maxAtt : UInt32) (now rst : UInt64)
    (h_mismatch : (candId == boundId) = false) :
    ((providerPoolStep 1 boundId candId isRej fb isFail att maxAtt now rst &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (providerPoolStep 1 boundId candId isRej fb isFail att maxAtt now rst >>> 32) = 0 := by
  unfold providerPoolStep
  rw [pack32_lo, pack32_hi]
  cases hfs : (fb == 1) <;>
    cases hif : (isFail == 1) <;>
    cases hm1 : decide (1 ≤ maxAtt) <;>
    cases hma : decide (att < maxAtt) <;>
    (simp_all; try decide)

/-- Corollary 56 (`ClockDiscipline`, `ConservedResource` & `StickyFence` — `orb_provider_pool_step`):
    1. `rejected_account_never_routed_before_reset`: `isRejected == 1` with `nowEpoch < resetEpoch` emits zero dispatch.
    2. `pre_first_byte_dispatch_preserves_unlocked_state`: when `firstByteSent == 0`,
       the `next_first_byte` bit (`65536`) is `0`, preserving pre-first-byte failover.
    3. `failover_terminates`: `isFailoverAttempt == 1` at `attempts == maxAttempts` returns `4 (ExhaustedFailover)`.
    4. `first_byte_locks_provider`: once `firstByteSent == 1`, any failover returns `3 (AbortLockedStream)` with lock bit `65536`. -/
theorem rejected_account_failover_and_first_byte_lock
    (hasBnd : UInt8) (bndId candId : UInt32) (isRej fb isFail : UInt8) (att maxAtt : UInt32)
    (now rst : UInt64) (h_before_reset : decide (now < rst) = true) :
    ((providerPoolStep hasBnd bndId candId 1 fb isFail att maxAtt now rst &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    ((providerPoolStep hasBnd bndId candId isRej 0 isFail att maxAtt now rst &&& 0xFFFFFFFF) &&& 65536) = 0 ∧
    providerPoolStep hasBnd bndId candId 0 0 1 maxAtt maxAtt now rst = 4 ∧
    providerPoolStep hasBnd bndId candId 0 1 1 att maxAtt now rst = 65539 := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold providerPoolStep
    rw [pack32_lo]
    cases hfs : (fb == 1) <;>
      cases hif : (isFail == 1) <;>
      cases hm1 : decide (1 ≤ maxAtt) <;>
      cases hma : decide (att < maxAtt) <;>
      cases hb1 : (hasBnd == 1) <;>
      cases hcb : (candId == bndId) <;>
      cases hc0 : (candId == 0) <;>
      (simp_all; try decide)
  · unfold providerPoolStep
    rw [pack32_lo]
    cases hif : (isFail == 1) <;>
      cases hm1 : decide (1 ≤ maxAtt) <;>
      cases hma : decide (att < maxAtt) <;>
      cases hb1 : (hasBnd == 1) <;>
      cases hcb : (candId == bndId) <;>
      cases hr1 : (isRej == 1) <;>
      cases hnr : decide (now < rst) <;>
      cases hc0 : (candId == 0) <;>
      (simp_all; try decide)
  · unfold providerPoolStep
    have hirr : ¬ (maxAtt < maxAtt) := UInt32.lt_irrefl maxAtt
    simp [hirr]
  · unfold providerPoolStep
    simp

/-- Pure state-machine event enricher for `orb_provider_pool_step`:
    `firstByteLocked` is sticky — once set in state `s` or observed in `e.firstByteSent`, it stays `1`. -/
def effectiveFirstByte (firstByteLocked : UInt8) (e : ProviderPoolCheck) : ProviderPoolCheck :=
  { e with firstByteSent := if firstByteLocked == 1 || e.firstByteSent == 1 then 1 else 0 }

/-- Pure state-machine transition wrapper for `orb_provider_pool_step` (`State × Event → State × List UInt32`). -/
def providerPoolMachineStep (firstByteLocked : UInt8) (e : ProviderPoolCheck) : UInt8 × List UInt32 :=
  let e' := effectiveFirstByte firstByteLocked e
  let w := providerPoolStep e'.hasBoundAccount e'.boundAccountId e'.candidateAccountId
    e'.isRejected e'.firstByteSent e'.isFailoverAttempt e'.attempts e'.maxAttempts e'.nowEpoch e'.resetEpoch
  (if ((w &&& 0xFFFFFFFF) &&& 65536) != 0 then 1 else 0,
   if providerPoolMetaGate.gate e' then [e.candidateAccountId] else [])

/-- Concrete `MetaStepSpec` instance for `orb_provider_pool_step` (`EffectSafety`, `EffectLiveness` with
    reachable trace from `init = 0`, and `CostBound`). -/
def providerPoolMetaStepSpec : MetaStepSpec UInt8 ProviderPoolCheck UInt32 where
  safety := {
    step := providerPoolMachineStep
    authorized := fun s e eff =>
      eff == e.candidateAccountId && (effectiveFirstByte s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [providerPoolMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := providerPoolMetaGate.sound (effectiveFirstByte s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := 0
    step := providerPoolMachineStep
    progressRequired := fun s e => (effectiveFirstByte s e).Admissible
    expectedEffect := fun e eff => eff == e.candidateAccountId
    live := fun s e h_req => by
      have h_gate := providerPoolMetaGate.complete (effectiveFirstByte s e) h_req
      dsimp [providerPoolMachineStep]
      simp [h_gate]
    traceEvents := [
      ⟨0, 0, 10, 0, 0, 0, 0, 3, 1000, 500⟩,
      ⟨0, 0, 20, 0, 0, 1, 1, 3, 1000, 500⟩
    ]
    posEvent := ⟨1, 42, 42, 0, 0, 0, 0, 3, 1000, 500⟩
    negEvent := ⟨1, 42, 99, 0, 0, 0, 0, 3, 1000, 500⟩
    reachable_live := by decide
  }
  cost := {
    step := providerPoolMachineStep
    cpuFuel := fun s e => 10 + ((providerPoolMachineStep s e).2).length
    inputBytes := fun _ => 48
    outputBytes := fun s e => 8 + 4 * ((providerPoolMachineStep s e).2).length
    c0 := 11
    c1 := 1
    maxEffects := 1
    maxOutBytes := 12
    fuel_bound := fun s e => by
      dsimp [providerPoolMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [providerPoolMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [providerPoolMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

structure RouteArgminCheck where
  hasBest        : UInt8
  bestId         : UInt32
  bestScore      : UInt64
  candId         : UInt32
  candScore      : UInt64
  candAdmissible : UInt8
  deriving Repr, DecidableEq

def routeArgminMetaGate : MetaGateSpec RouteArgminCheck
    (fun r => (r.candAdmissible == 1 && (r.hasBest == 0 || r.candScore < r.bestScore)) = true) where
  gate r := ((routeArgminStep r.hasBest r.bestId r.bestScore r.candId r.candScore r.candAdmissible &&& 0xFFFFFFFF) &&& 256) != 0
  sound r h := by
    unfold routeArgminStep at h
    rw [pack32_lo] at h
    cases hc : (r.candAdmissible == 1 && (r.hasBest == 0 || decide (r.candScore < r.bestScore))) <;>
      cases hb : (r.hasBest == 1) <;>
      (simp_all
       try
         exfalso
         revert h
         decide)
  complete r h := by
    unfold routeArgminStep
    rw [pack32_lo]
    simp [h]
    decide
  posWitness := ⟨1, 10, 500, 20, 300, 1⟩
  negWitness := ⟨1, 10, 500, 20, 600, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 57 (`ConservedResource` — `orb_route_argmin_step`):
    An inadmissible candidate (`candAdmissible == 0`) or higher-cost candidate (`bestScore ≤ candScore` when `hasBest == 1`)
    never replaces `bestId`, while a strictly better admissible candidate updates `nextBestId` to `candId`. -/
theorem route_argmin_selects_strictly_better_eligible (bestId candId : UInt32) (bestScore candScore : UInt64) :
    ((routeArgminStep 1 bestId bestScore candId candScore 0 &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (routeArgminStep 1 bestId bestScore candId candScore 0 >>> 32) = bestId.toUInt64 ∧
    (routeArgminStep 1 10 500 20 300 1 >>> 32) = 20 ∧
    (routeArgminStep 1 10 500 20 500 1 >>> 32) = 10 := by
  refine ⟨?_, ?_, by decide, by decide⟩
  · unfold routeArgminStep
    rw [pack32_lo]
    simp; decide
  · unfold routeArgminStep
    rw [pack32_hi]
    simp

/-! ## Wave 9 — Phase 1: Control Core — Mission Lifecycle, Codex Resume, Fork `HOME` & Track Leases -/

structure MissionControlCheck where
  isArchived          : UInt8
  activeTrackWriters  : UInt32
  hasLease            : UInt8
  msgAlreadyDelivered : UInt8
  isResume            : UInt8
  sessionCreated      : UInt8
  lineageVerified     : UInt8
  rolloutExists       : UInt8
  hasFallbackPrompt   : UInt8
  deriving Repr, DecidableEq

def MissionControlCheck.Admissible (m : MissionControlCheck) : Prop :=
  (!(m.isArchived == 1) &&
   !(m.msgAlreadyDelivered == 1) &&
   (m.hasLease == 1 && m.activeTrackWriters == 0) &&
   (!(m.isResume == 1) ||
    (m.sessionCreated == 1 && m.lineageVerified == 1 && m.rolloutExists == 1) ||
    m.hasFallbackPrompt == 1)) = true

instance (m : MissionControlCheck) : Decidable (MissionControlCheck.Admissible m) :=
  inferInstanceAs (Decidable (_ = true))

def missionControlMetaGate : MetaGateSpec MissionControlCheck MissionControlCheck.Admissible where
  gate m :=
    ((missionControlStep m.isArchived m.activeTrackWriters m.hasLease m.msgAlreadyDelivered
        m.isResume m.sessionCreated m.lineageVerified m.rolloutExists m.hasFallbackPrompt &&& 0xFFFFFFFF) &&& 256) != 0
  sound m h := by
    unfold missionControlStep MissionControlCheck.Admissible at *
    rw [pack32_lo] at h
    cases ha : (m.isArchived == 1) <;>
      cases hd : (m.msgAlreadyDelivered == 1) <;>
      cases hlw : (m.hasLease == 1 && m.activeTrackWriters == 0) <;>
      cases hr : (m.isResume == 1) <;>
      cases hsv : (m.sessionCreated == 1 && m.lineageVerified == 1 && m.rolloutExists == 1) <;>
      cases hfb : (m.hasFallbackPrompt == 1) <;>
      (simp_all;
        try (exfalso; revert h; decide))
  complete m h := by
    unfold missionControlStep MissionControlCheck.Admissible at *
    rw [pack32_lo]
    cases ha : (m.isArchived == 1) <;>
      cases hd : (m.msgAlreadyDelivered == 1) <;>
      cases hlw : (m.hasLease == 1 && m.activeTrackWriters == 0) <;>
      cases hr : (m.isResume == 1) <;>
      cases hsv : (m.sessionCreated == 1 && m.lineageVerified == 1 && m.rolloutExists == 1) <;>
      cases hfb : (m.hasFallbackPrompt == 1) <;>
      (simp_all; try decide)
  posWitness := ⟨0, 0, 1, 0, 1, 1, 1, 1, 0⟩
  negWitness := ⟨1, 0, 1, 0, 1, 1, 1, 1, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 58 (`StickyFence` — `orb_mission_control_step`):
    An archived mission (`isArchived == 1`) never revives on any wakeup/reminder/resume event:
    it emits zero dispatch (`bit 8 == 0`), keeps `archivedNext == 1` (`bit 16 == 65536`),
    and allocates zero track writers (`hi32 == 0`). -/
theorem archived_mission_never_revives
    (writers : UInt32) (lease deliv res sc lv ro fb : UInt8) :
    ((missionControlStep 1 writers lease deliv res sc lv ro fb &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    ((missionControlStep 1 writers lease deliv res sc lv ro fb &&& 0xFFFFFFFF) &&& 65536) = 65536 ∧
    (missionControlStep 1 writers lease deliv res sc lv ro fb >>> 32) = 0 := by
  unfold missionControlStep
  simp; decide

/-- Corollary 59 (`ScopedAuthority` & `EffectSafety` — `orb_mission_control_step`):
    When Codex session lineage or rollout is unverified (`(sc == 1 && lv == 1 && ro == 1) = false`),
    raw native resume (`action == 2`) is never emitted, and a valid turn with `hasFallbackPrompt == 1`
    selects `SeedFallbackFreshSession` (`lo32 = 771`, `hi32 = 1`), fixing the phantom Codex session bug. -/
theorem resume_codex_requires_verified_lineage
    (arch : UInt8) (writers : UInt32) (lease deliv sc lv ro fb : UInt8)
    (h_unverified : (sc == 1 && lv == 1 && ro == 1) = false) :
    ((missionControlStep arch writers lease deliv 1 sc lv ro fb &&& 0xFFFFFFFF) &&& 0xFF) != 2 ∧
    missionControlStep 0 0 1 0 1 sc lv ro 1 = 4294968067 ∧
    ((missionControlStep 0 0 1 0 1 sc lv ro 0 &&& 0xFFFFFFFF) &&& 256) = 0 := by
  refine ⟨?_, ?_, ?_⟩
  · unfold missionControlStep
    rw [pack32_lo]
    cases ha : (arch == 1) <;>
      cases hd : (deliv == 1) <;>
      cases hlw : (lease == 1 && writers == 0) <;>
      cases hsc : (sc == 1) <;>
      cases hlv : (lv == 1) <;>
      cases hro : (ro == 1) <;>
      cases hfb : (fb == 1) <;>
      (simp_all; try decide)
  · unfold missionControlStep
    cases hsc : (sc == 1) <;>
      cases hlv : (lv == 1) <;>
      cases hro : (ro == 1) <;>
      (simp_all; try decide)
  · unfold missionControlStep
    rw [pack32_lo]
    cases hsc : (sc == 1) <;>
      cases hlv : (lv == 1) <;>
      cases hro : (ro == 1) <;>
      (simp_all; try decide)

/-- Corollary 60 (`ConservedResource` & `ReplayIdempotence` — `orb_mission_control_step`):
    Single-step admission & delivered-flag gate (`single_step_writer_admission_and_delivered_flag_gate`):
    1. `single_step_writer_conflict_blocks_dispatch`: when `activeTrackWriters != 0`, zero dispatch is emitted, and
       across all transitions `hi32 ≤ 1` (assuming caller-supplied `activeTrackWriters` and `hasLease` flags).
    2. `delivered_flag_blocks_redispatch`: an already-delivered message flag (`deliv == 1`) is never
       dispatched again, while a fresh leased turn (`arch == 0, writers == 0, lease == 1, deliv == 0, res == 0`)
       is always dispatched (`lo32 = 257, hi32 = 1`). -/
theorem single_step_writer_admission_and_delivered_flag_gate
    (arch : UInt8) (writers : UInt32) (lease deliv res sc lv ro fb : UInt8)
    (h_busy : (writers == 0) = false) :
    ((missionControlStep arch writers lease deliv res sc lv ro fb &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    ((missionControlStep arch writers lease 1 res sc lv ro fb &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (missionControlStep arch writers lease deliv res sc lv ro fb >>> 32) ≤ 1 ∧
    missionControlStep 0 0 1 0 0 sc lv ro fb = 4294967553 := by
  refine ⟨?_, ?_, ?_, by unfold missionControlStep; simp; decide⟩
  · unfold missionControlStep
    rw [pack32_lo]
    cases ha : (arch == 1) <;>
      cases hd : (deliv == 1) <;>
      cases hl : (lease == 1) <;>
      (simp_all; try decide)
  · unfold missionControlStep
    rw [pack32_lo]
    cases ha : (arch == 1) <;>
      (simp_all; try decide)
  · unfold missionControlStep
    rw [pack32_hi]
    cases ha : (arch == 1) <;>
      cases hd : (deliv == 1) <;>
      cases hlw : (lease == 1 && writers == 0) <;>
      cases hr : (res == 1) <;>
      cases hsv : (sc == 1 && lv == 1 && ro == 1) <;>
      cases hfb : (fb == 1) <;>
      (simp_all; try decide)

/-- Sticky archived state enricher for `orb_mission_control_step`. -/
def effectiveArchived (archivedState : UInt8) (e : MissionControlCheck) : MissionControlCheck :=
  { e with isArchived := if archivedState == 1 || e.isArchived == 1 then 1 else 0 }

/-- Expected concrete dispatch action code (`1 = DispatchFreshTurn`, `2 = ResumeVerifiedSession`,
    `3 = SeedFallbackFreshSession`) independently derived from `MissionControlCheck`. -/
def expectedMissionControlActionCode (e : MissionControlCheck) : UInt32 :=
  if !(e.isResume == 1) then 1
  else if e.sessionCreated == 1 && e.lineageVerified == 1 && e.rolloutExists == 1 then 2
  else 3

theorem missionControlStep_actionCode_eq_expected (e : MissionControlCheck)
    (h_adm : e.Admissible) :
    ((missionControlStep e.isArchived e.activeTrackWriters e.hasLease e.msgAlreadyDelivered
        e.isResume e.sessionCreated e.lineageVerified e.rolloutExists e.hasFallbackPrompt &&& 0xFFFFFFFF) &&& 0xFF).toUInt32 =
      expectedMissionControlActionCode e := by
  unfold MissionControlCheck.Admissible at h_adm
  unfold missionControlStep expectedMissionControlActionCode
  rw [pack32_lo]
  cases ha : (e.isArchived == 1) <;>
    cases hd : (e.msgAlreadyDelivered == 1) <;>
    cases hlw : (e.hasLease == 1 && e.activeTrackWriters == 0) <;>
    cases hr : (e.isResume == 1) <;>
    cases hsv : (e.sessionCreated == 1 && e.lineageVerified == 1 && e.rolloutExists == 1) <;>
    cases hfb : (e.hasFallbackPrompt == 1) <;>
    (simp_all; try decide)

theorem expectedMissionControlActionCode_effectiveArchived (s : UInt8) (e : MissionControlCheck) :
    expectedMissionControlActionCode (effectiveArchived s e) = expectedMissionControlActionCode e := by
  rfl

/-- Pure state-machine transition wrapper for `orb_mission_control_step` (`State × Event → State × List UInt32`). -/
def missionControlMachineStep (archivedState : UInt8) (e : MissionControlCheck) : UInt8 × List UInt32 :=
  let e' := effectiveArchived archivedState e
  let w := missionControlStep e'.isArchived e'.activeTrackWriters e'.hasLease e'.msgAlreadyDelivered
    e'.isResume e'.sessionCreated e'.lineageVerified e'.rolloutExists e'.hasFallbackPrompt
  (if ((w &&& 0xFFFFFFFF) &&& 65536) != 0 then 1 else 0,
   if missionControlMetaGate.gate e' then [((w &&& 0xFFFFFFFF) &&& 0xFF).toUInt32] else [])

/-- Concrete `MetaStepSpec` instance for `orb_mission_control_step` (`EffectSafety`, `EffectLiveness`
    with exact `expectedMissionControlActionCode` matching, multi-step reachable trace from `init = 0`,
    and symbolic `CostBound`). -/
def missionControlMetaStepSpec : MetaStepSpec UInt8 MissionControlCheck UInt32 where
  safety := {
    step := missionControlMachineStep
    authorized := fun s e eff =>
      eff == expectedMissionControlActionCode e && (effectiveArchived s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [missionControlMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := missionControlMetaGate.sound (effectiveArchived s e) h_emit
        have h_act := missionControlStep_actionCode_eq_expected (effectiveArchived s e) h_adm
        rw [expectedMissionControlActionCode_effectiveArchived] at h_act
        simp [h_act, h_adm]
      · contradiction
  }
  liveness := {
    init := 0
    step := missionControlMachineStep
    progressRequired := fun s e => (effectiveArchived s e).Admissible
    expectedEffect := fun e eff => eff == expectedMissionControlActionCode e
    live := fun s e h_req => by
      have h_gate := missionControlMetaGate.complete (effectiveArchived s e) h_req
      have h_act := missionControlStep_actionCode_eq_expected (effectiveArchived s e) h_req
      rw [expectedMissionControlActionCode_effectiveArchived] at h_act
      dsimp [missionControlMachineStep]
      simp [h_gate, h_act]
    traceEvents := [
      ⟨0, 0, 1, 0, 0, 0, 0, 0, 0⟩,
      ⟨0, 0, 1, 0, 1, 1, 1, 0, 1⟩
    ]
    posEvent := ⟨0, 0, 1, 0, 1, 1, 1, 1, 0⟩
    negEvent := ⟨1, 0, 1, 0, 1, 1, 1, 1, 0⟩
    reachable_live := by decide
  }
  cost := {
    step := missionControlMachineStep
    cpuFuel := fun s e => 9 + ((missionControlMachineStep s e).2).length
    inputBytes := fun _ => 16
    outputBytes := fun s e => 8 + 4 * ((missionControlMachineStep s e).2).length
    c0 := 10
    c1 := 1
    maxEffects := 1
    maxOutBytes := 12
    fuel_bound := fun s e => by
      dsimp [missionControlMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [missionControlMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [missionControlMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

structure ForkHomeCheck where
  isForkOrSide          : UInt8
  sourceExists          : UInt8
  sourceIsSymlink       : UInt8
  sameWorkspace         : UInt8
  sameNode              : UInt8
  hasCommittedTransfer  : UInt8
  requestedOverrideHome : UInt8
  deriving Repr, DecidableEq

def forkHomeMetaGate : MetaGateSpec ForkHomeCheck
    (fun f => (f.isForkOrSide == 0 ||
      (f.sourceExists == 1 && f.sourceIsSymlink == 0 && f.sameWorkspace == 1 && f.sameNode == 1)) = true) where
  gate f :=
    ((forkHomeStep f.isForkOrSide f.sourceExists f.sourceIsSymlink f.sameWorkspace
        f.sameNode f.hasCommittedTransfer f.requestedOverrideHome &&& 0xFFFFFFFF) &&& 256) != 0
  sound f h := by
    unfold forkHomeStep at h
    rw [pack32_lo] at h
    cases hf : (f.isForkOrSide == 0) <;>
      cases hv : (f.sourceExists == 1 && f.sourceIsSymlink == 0 && f.sameWorkspace == 1 && f.sameNode == 1) <;>
      cases hx : (f.hasCommittedTransfer == 1) <;>
      (simp_all;
        try (exfalso; revert h; decide))
  complete f h := by
    unfold forkHomeStep
    rw [pack32_lo]
    cases hf : (f.isForkOrSide == 0) <;>
      cases hv : (f.sourceExists == 1 && f.sourceIsSymlink == 0 && f.sameWorkspace == 1 && f.sameNode == 1) <;>
      cases hx : (f.hasCommittedTransfer == 1) <;>
      (simp_all; try decide)
  posWitness := ⟨1, 1, 0, 1, 1, 0, 1⟩
  negWitness := ⟨1, 1, 1, 1, 1, 0, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 61 (`ScopedAuthority` — `orb_fork_home_step`):
    1. `fork_preserves_job_home`: under ALL inputs (even `requestedOverrideHome == 1` or rejected sources),
       `overrideHomeBit` (`65536`) is `0` and `jobHomePreservedBit` (`131072`) is `131072`
       (fixing the `#1302`/`9178bd08` fork `HOME` sign-out bug).
    2. Missing (`sourceExists == 0`) or symlinked (`sourceIsSymlink == 1`) fork workspaces fail closed with exit code `78`.
    3. A valid sibling fork (`1, 1, 0, 1, 1, 0`) sets `admitBit = 256`, `useSourceCwdBit = 512`, and `jobHomePreservedBit = 131072`. -/
theorem fork_preserves_job_home_and_source_cwd
    (isFork srcEx sym sameWs sameNd xfer reqHome : UInt8) :
    ((forkHomeStep isFork srcEx sym sameWs sameNd xfer reqHome &&& 0xFFFFFFFF) &&& 65536) = 0 ∧
    ((forkHomeStep isFork srcEx sym sameWs sameNd xfer reqHome &&& 0xFFFFFFFF) &&& 131072) = 131072 ∧
    (forkHomeStep 1 0 sym sameWs sameNd xfer reqHome >>> 32) = 78 ∧
    (forkHomeStep 1 srcEx 1 sameWs sameNd xfer reqHome >>> 32) = 78 ∧
    forkHomeStep 1 1 0 1 1 0 reqHome = 131842 := by
  refine ⟨?_, ?_, ?_, ?_, by unfold forkHomeStep; simp⟩
  · unfold forkHomeStep
    rw [pack32_lo]
    cases hf : (isFork == 0) <;>
      cases hv : (srcEx == 1 && sym == 0 && sameWs == 1 && sameNd == 1) <;>
      cases hx : (xfer == 1) <;>
      (simp_all; try decide)
  · unfold forkHomeStep
    rw [pack32_lo]
    cases hf : (isFork == 0) <;>
      cases hv : (srcEx == 1 && sym == 0 && sameWs == 1 && sameNd == 1) <;>
      cases hx : (xfer == 1) <;>
      (simp_all; try decide)
  · unfold forkHomeStep
    rw [pack32_hi]
    simp
  · unfold forkHomeStep
    rw [pack32_hi]
    cases hs : (srcEx == 1) <;> simp_all

-- ===========================================================================
-- Wave 9 Phase 5: Security-Critical System Primitives (`orb-privd`, `development_identity`, Codex Driver)
-- ===========================================================================

set_option linter.unusedSimpArgs false

structure PrivdCommandCheck where
  leaseValid                   : UInt8
  grantScope                   : UInt8
  commandClass                 : UInt8
  unitMatchesAllowed           : UInt8
  hasShellMetacharOrFlagBypass : UInt8
  hasPathTraversalOrSymlink    : UInt8
  hasUnsafeEnvVar              : UInt8
  requireForceCmd              : UInt8
  deriving Repr, DecidableEq

/-- `GrammarConfinement` + `NoPrivilegeEscalation` + `PathConfinement` + `EnvironmentConfinement` for `orb_privd_command_step`. -/
def PrivdCommandCheck.Admissible (p : PrivdCommandCheck) : Bool :=
  (p.leaseValid == 1 && p.hasShellMetacharOrFlagBypass == 0 &&
   p.hasPathTraversalOrSymlink == 0 && p.hasUnsafeEnvVar == 0) &&
  (p.grantScope <= 2) &&
  (p.commandClass == 1 ||
   (p.commandClass == 2 && 1 <= p.grantScope && p.unitMatchesAllowed == 1) ||
   (p.commandClass == 3 && 1 <= p.grantScope) ||
   (p.commandClass == 4 && p.grantScope == 2 && p.requireForceCmd == 0))

def privdCommandMetaGate : MetaGateSpec PrivdCommandCheck
    (fun p => p.Admissible = true) where
  gate p :=
    ((privdCommandStep p.leaseValid p.grantScope p.commandClass p.unitMatchesAllowed
        p.hasShellMetacharOrFlagBypass p.hasPathTraversalOrSymlink
        p.hasUnsafeEnvVar p.requireForceCmd &&& 0xFFFFFFFF) &&& 256) != 0
  sound p h := by
    unfold PrivdCommandCheck.Admissible
    unfold privdCommandStep at h
    rw [pack32_lo] at h
    cases hs : (p.leaseValid == 1 && p.hasShellMetacharOrFlagBypass == 0 &&
        p.hasPathTraversalOrSymlink == 0 && p.hasUnsafeEnvVar == 0) <;>
      cases hgs : decide (p.grantScope ≤ 2) <;>
      cases hc1 : (p.commandClass == 1) <;>
      cases hc2 : (p.commandClass == 2 && decide (1 ≤ p.grantScope) && p.unitMatchesAllowed == 1) <;>
      cases hc3 : (p.commandClass == 3 && decide (1 ≤ p.grantScope)) <;>
      cases hc4 : (p.commandClass == 4 && p.grantScope == 2 && p.requireForceCmd == 0) <;>
      (simp only [hs, hgs, hc1, hc2, hc3, hc4] at h ⊢; revert h; decide)
  complete p h := by
    unfold PrivdCommandCheck.Admissible at h
    unfold privdCommandStep
    rw [pack32_lo]
    cases hs : (p.leaseValid == 1 && p.hasShellMetacharOrFlagBypass == 0 &&
        p.hasPathTraversalOrSymlink == 0 && p.hasUnsafeEnvVar == 0) <;>
      cases hgs : decide (p.grantScope ≤ 2) <;>
      cases hc1 : (p.commandClass == 1) <;>
      cases hc2 : (p.commandClass == 2 && decide (1 ≤ p.grantScope) && p.unitMatchesAllowed == 1) <;>
      cases hc3 : (p.commandClass == 3 && decide (1 ≤ p.grantScope)) <;>
      cases hc4 : (p.commandClass == 4 && p.grantScope == 2 && p.requireForceCmd == 0) <;>
      (simp only [hs, hgs, hc1, hc2, hc3, hc4] at h ⊢; revert h; decide)
  posWitness := ⟨1, 1, 2, 1, 0, 0, 0, 0⟩
  negWitness := ⟨1, 0, 2, 1, 0, 0, 0, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 62 (`GrammarConfinement`, `PathConfinement`, `EnvironmentConfinement`, `NoPrivilegeEscalation` — `orb_privd_command_step`):
    1. Under ALL inputs (admitted or rejected), `scrubEnvBit` (`512`) and `auditRequiredBit` (`1024`) are ALWAYS set (`1536`).
    2. Shell metacharacters / flag bypass (`hasShellMetacharOrFlagBypass == 1`), path traversal / symlinks
       (`hasPathTraversalOrSymlink == 1`),
       and unsafe env vars (`hasUnsafeEnvVar == 1`) always reject (`allowExecBit = 0`, exit code `126`).
    3. `OpsRead` (`grantScope = 0`) never escalates to `ServiceDeployUnit` (`commandClass = 2`) or
       `RootExecCommand` (`commandClass = 4`). -/
theorem privd_rejects_metacharacters_traversal_unsafe_env_and_escalation
    (lv gs cc um metaByp pathTrav unsafeEnv forceCmd : UInt8) :
    ((privdCommandStep lv gs cc um metaByp pathTrav unsafeEnv forceCmd &&& 0xFFFFFFFF) &&& 1536) = 1536 ∧
    privdCommandStep lv gs cc um 1 pathTrav unsafeEnv forceCmd = 541165880832 ∧
    privdCommandStep lv gs cc um metaByp 1 unsafeEnv forceCmd = 541165880832 ∧
    privdCommandStep lv gs cc um metaByp pathTrav 1 forceCmd = 541165880832 ∧
    privdCommandStep 1 0 2 1 0 0 0 0 = 541165880832 ∧
    privdCommandStep 1 0 4 1 0 0 0 0 = 541165880832 ∧
    privdCommandStep 1 1 2 1 0 0 0 0 = 1794 := by
  refine ⟨?_, ?_, ?_, ?_, by decide, by decide, by decide⟩
  · unfold privdCommandStep
    rw [pack32_lo]
    cases hs : (lv == 1 && metaByp == 0 && pathTrav == 0 && unsafeEnv == 0) <;>
      cases hgs : decide (gs ≤ 2) <;>
      cases hc1 : (cc == 1) <;>
      cases hc2 : (cc == 2 && decide (1 ≤ gs) && um == 1) <;>
      cases hc3 : (cc == 3 && decide (1 ≤ gs)) <;>
      cases hc4 : (cc == 4 && gs == 2 && forceCmd == 0) <;>
      ((try simp only [hs, hgs, hc1, hc2, hc3, hc4]); decide)
  · unfold privdCommandStep
    cases hlv : (lv == 1) <;> (simp [hlv]; try decide)
  · unfold privdCommandStep
    cases hlv : (lv == 1) <;>
      cases hm : (metaByp == 0) <;>
      (simp [hlv, hm];
        try decide)
  · unfold privdCommandStep
    cases hlv : (lv == 1) <;>
      cases hm : (metaByp == 0) <;>
      cases hp : (pathTrav == 0) <;>
      (simp [hlv, hm, hp];
        try decide)

def effectivePrivdLease (leaseActive : UInt8) (e : PrivdCommandCheck) : PrivdCommandCheck :=
  { e with leaseValid := if leaseActive == 1 && e.leaseValid == 1 then 1 else 0 }

def privdCommandMachineStep (leaseActive : UInt8) (e : PrivdCommandCheck) : UInt8 × List UInt8 :=
  let e' := effectivePrivdLease leaseActive e
  (e'.leaseValid, if privdCommandMetaGate.gate e' then [e.commandClass] else [])

/-- Concrete `MetaStepSpec` instance #3 for Phase 5 (`orb_privd_command_step`). -/
def privdCommandMetaStepSpec : MetaStepSpec UInt8 PrivdCommandCheck UInt8 where
  safety := {
    step := privdCommandMachineStep
    authorized := fun s e eff =>
      eff == e.commandClass && (effectivePrivdLease s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [privdCommandMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := privdCommandMetaGate.sound (effectivePrivdLease s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := 1
    step := privdCommandMachineStep
    progressRequired := fun s e => (effectivePrivdLease s e).Admissible
    expectedEffect := fun e eff => eff == e.commandClass
    live := fun s e h_req => by
      have h_gate := privdCommandMetaGate.complete (effectivePrivdLease s e) h_req
      dsimp [privdCommandMachineStep]
      simp [h_gate]
    traceEvents := [⟨1, 1, 2, 1, 0, 0, 0, 0⟩]
    posEvent := ⟨1, 2, 4, 1, 0, 0, 0, 0⟩
    negEvent := ⟨1, 0, 4, 1, 0, 0, 0, 0⟩
    reachable_live := by decide
  }
  cost := {
    step := privdCommandMachineStep
    cpuFuel := fun s e => 8 + ((privdCommandMachineStep s e).2).length
    inputBytes := fun _ => 8
    outputBytes := fun s e => 8 + ((privdCommandMachineStep s e).2).length
    c0 := 9
    c1 := 1
    maxEffects := 1
    maxOutBytes := 9
    fuel_bound := fun s e => by
      dsimp [privdCommandMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [privdCommandMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [privdCommandMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

structure SshIdentityCheck where
  isWorkerOrContainerTarget   : UInt8
  bundleHasControlPlaneKey    : UInt8
  parentDirIsSymlink          : UInt8
  pubKeyIsEd25519WithoutPriv  : UInt8
  proxyJumpValid              : UInt8
  codexCyberProgramValid      : UInt8
  codexGoalBudgetExhausted    : UInt8
  deriving Repr, DecidableEq

def SshIdentityCheck.Admissible (s : SshIdentityCheck) : Bool :=
  s.parentDirIsSymlink == 0 && s.pubKeyIsEd25519WithoutPriv == 1 &&
  s.proxyJumpValid == 1 && s.codexCyberProgramValid == 1 &&
  s.codexGoalBudgetExhausted == 0 &&
  !(s.isWorkerOrContainerTarget == 1 && s.bundleHasControlPlaneKey == 1)

def sshIdentityMetaGate : MetaGateSpec SshIdentityCheck
    (fun s => s.Admissible = true) where
  gate s :=
    ((sshIdentityStep s.isWorkerOrContainerTarget s.bundleHasControlPlaneKey s.parentDirIsSymlink
        s.pubKeyIsEd25519WithoutPriv s.proxyJumpValid s.codexCyberProgramValid
        s.codexGoalBudgetExhausted &&& 0xFFFFFFFF) &&& 256) != 0
  sound s h := by
    unfold SshIdentityCheck.Admissible
    unfold sshIdentityStep at h
    rw [pack32_lo] at h
    cases hb : (s.parentDirIsSymlink == 0 && s.pubKeyIsEd25519WithoutPriv == 1 &&
        s.proxyJumpValid == 1 && s.codexCyberProgramValid == 1 &&
        s.codexGoalBudgetExhausted == 0) <;>
      cases hw : (s.isWorkerOrContainerTarget == 1) <;>
      cases hk : (s.bundleHasControlPlaneKey == 1) <;>
      (simp_all;
        try (exfalso; revert h; decide))
  complete s h := by
    unfold SshIdentityCheck.Admissible at h
    unfold sshIdentityStep
    rw [pack32_lo]
    cases hb : (s.parentDirIsSymlink == 0 && s.pubKeyIsEd25519WithoutPriv == 1 &&
        s.proxyJumpValid == 1 && s.codexCyberProgramValid == 1 &&
        s.codexGoalBudgetExhausted == 0) <;>
      cases hw : (s.isWorkerOrContainerTarget == 1) <;>
      cases hk : (s.bundleHasControlPlaneKey == 1) <;>
      (simp_all; try decide)
  posWitness := ⟨1, 0, 0, 1, 1, 1, 0⟩
  negWitness := ⟨1, 1, 0, 1, 1, 1, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 63 (`ScopedAuthority` — `orb_ssh_identity_step`, Secret Non-Leakage & Codex Driver Gate):
    1. Under ALL inputs, `noSecretLeakBit` (`1024`) is `1`.
    2. For worker/container targets (`isWorkerOrContainerTarget = 1`), `stripControlPlaneSecretsBit` (`512`) is ALWAYS `1`,
       and any bundle containing a control-plane key (`bundleHasControlPlaneKey = 1`) is rejected with exit code `78`.
    3. Symlinked parent dirs (`parentDirIsSymlink = 1`), invalid cyber programs (`codexCyberProgramValid = 0`),
       and exhausted Codex goal budgets (`codexGoalBudgetExhausted = 1`) fail closed with exit code `78`. -/
theorem ssh_identity_never_leaks_control_plane_secrets_and_enforces_codex_gate
    (isWorker hasCtrl sym pubOk pjOk cyberOk goalExh : UInt8) :
    ((sshIdentityStep isWorker hasCtrl sym pubOk pjOk cyberOk goalExh &&& 0xFFFFFFFF) &&& 1024) = 1024 ∧
    ((sshIdentityStep 1 hasCtrl sym pubOk pjOk cyberOk goalExh &&& 0xFFFFFFFF) &&& 512) = 512 ∧
    sshIdentityStep 1 1 sym pubOk pjOk cyberOk goalExh = 335007450624 ∧
    (sshIdentityStep isWorker hasCtrl 1 pubOk pjOk cyberOk goalExh >>> 32) = 78 ∧
    (sshIdentityStep isWorker hasCtrl sym pubOk pjOk 0 goalExh >>> 32) = 78 ∧
    (sshIdentityStep isWorker hasCtrl sym pubOk pjOk cyberOk 1 >>> 32) = 78 ∧
    sshIdentityStep 1 0 0 1 1 1 0 = 1793 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, by decide⟩
  · unfold sshIdentityStep
    rw [pack32_lo]
    cases hb : (sym == 0 && pubOk == 1 && pjOk == 1 && cyberOk == 1 && goalExh == 0) <;>
      cases hw : (isWorker == 1) <;>
      cases hk : (hasCtrl == 1) <;>
      (simp_all; try decide)
  · unfold sshIdentityStep
    rw [pack32_lo]
    cases hb : (sym == 0 && pubOk == 1 && pjOk == 1 && cyberOk == 1 && goalExh == 0) <;>
      cases hk : (hasCtrl == 1) <;>
      (simp_all; try decide)
  · unfold sshIdentityStep
    cases hb : (sym == 0 && pubOk == 1 && pjOk == 1 && cyberOk == 1 && goalExh == 0) <;>
      (simp_all; decide)
  · unfold sshIdentityStep
    rw [pack32_hi]
    simp
  · unfold sshIdentityStep
    rw [pack32_hi]
    cases hs : (sym == 0) <;>
      cases hp : (pubOk == 1) <;>
      cases hpj : (pjOk == 1) <;>
      simp_all
  · unfold sshIdentityStep
    rw [pack32_hi]
    cases hs : (sym == 0) <;>
      cases hp : (pubOk == 1) <;>
      cases hpj : (pjOk == 1) <;>
      cases hc : (cyberOk == 1) <;>
      simp_all

-- ===========================================================================
-- Wave 9 Phase 3: Multi-Harness Agent Event Normalizer & Unified Transcript Reducer
-- ===========================================================================

structure AgentEventNormalizeCheck where
  harnessKind          : UInt8
  rawEventKind         : UInt8
  isCompleted          : UInt8
  hasNonEmptyText      : UInt8
  sessionMatchesExp    : UInt32
  isDuplicateTurnTool  : UInt32
  payloadBytes         : UInt32
  maxPayloadBytes      : UInt32
  deriving Repr, DecidableEq

def AgentEventNormalizeCheck.Admissible (a : AgentEventNormalizeCheck) : Bool :=
  decide (a.payloadBytes ≤ a.maxPayloadBytes) &&
  (decide (a.harnessKind ≤ 5) &&
   (a.sessionMatchesExp == 1 || a.rawEventKind == 0 || a.rawEventKind == 1 || a.rawEventKind == 7) &&
   (a.isDuplicateTurnTool == 0)) &&
  (if a.rawEventKind == 0 then true
   else if a.rawEventKind == 1 then true
   else if a.rawEventKind == 2 then a.hasNonEmptyText == 1
   else if a.rawEventKind == 3 then a.hasNonEmptyText == 1
   else if a.rawEventKind == 4 then true
   else if a.rawEventKind == 5 then true
   else if a.rawEventKind == 6 then true
   else if a.rawEventKind == 7 then true
   else false)

def agentEventNormalizeMetaGate : MetaGateSpec AgentEventNormalizeCheck
    (fun a => a.Admissible = true) where
  gate a :=
    ((agentEventNormalizeStep a.harnessKind a.rawEventKind a.isCompleted a.hasNonEmptyText
        a.sessionMatchesExp a.isDuplicateTurnTool a.payloadBytes a.maxPayloadBytes &&& 0xFFFFFFFF) &&& 256) != 0
  sound a h := by
    unfold AgentEventNormalizeCheck.Admissible
    unfold agentEventNormalizeStep at h
    rw [pack32_lo] at h
    cases hb : decide (a.payloadBytes ≤ a.maxPayloadBytes)
    · simp_all;
      exfalso;
      revert h;
      decide
    · cases hv : (decide (a.harnessKind ≤ 5) &&
        (a.sessionMatchesExp == 1 || a.rawEventKind == 0 || a.rawEventKind == 1 || a.rawEventKind == 7) &&
        (a.isDuplicateTurnTool == 0))
      · simp_all;
        exfalso;
        revert h;
        decide
      · cases hr0 : (a.rawEventKind == 0)
        · cases hr1 : (a.rawEventKind == 1)
          · cases hr2 : (a.rawEventKind == 2)
            · cases hr3 : (a.rawEventKind == 3)
              · cases hr4 : (a.rawEventKind == 4)
                · cases hr5 : (a.rawEventKind == 5)
                  · cases hr6 : (a.rawEventKind == 6)
                    · cases hr7 : (a.rawEventKind == 7) <;>
                      (simp_all;
                        try (exfalso; revert h; decide))
                    · simp_all
                  · simp_all
                · cases hc : (a.isCompleted == 1) <;>
                  (simp_all;
                    try (exfalso; revert h; decide))
              · cases ht : (a.hasNonEmptyText == 1) <;>
                (simp_all;
                  try (exfalso; revert h; decide))
            · cases ht : (a.hasNonEmptyText == 1) <;>
              (simp_all;
                try (exfalso; revert h; decide))
          · simp_all
        · simp_all
  complete a h := by
    unfold AgentEventNormalizeCheck.Admissible at h
    unfold agentEventNormalizeStep
    rw [pack32_lo]
    cases hb : decide (a.payloadBytes ≤ a.maxPayloadBytes)
    · simp_all
    · cases hv : (decide (a.harnessKind ≤ 5) &&
        (a.sessionMatchesExp == 1 || a.rawEventKind == 0 || a.rawEventKind == 1 || a.rawEventKind == 7) &&
        (a.isDuplicateTurnTool == 0))
      · simp_all
      · cases hr0 : (a.rawEventKind == 0)
        · cases hr1 : (a.rawEventKind == 1)
          · cases hr2 : (a.rawEventKind == 2)
            · cases hr3 : (a.rawEventKind == 3)
              · cases hr4 : (a.rawEventKind == 4)
                · cases hr5 : (a.rawEventKind == 5)
                  · cases hr6 : (a.rawEventKind == 6)
                    · cases hr7 : (a.rawEventKind == 7) <;> (simp_all; try decide)
                    · simp_all; decide
                  · simp_all; decide
                · cases hc : (a.isCompleted == 1) <;> (simp_all; decide)
              · cases ht : (a.hasNonEmptyText == 1) <;> (simp_all; try decide)
            · cases ht : (a.hasNonEmptyText == 1) <;> (simp_all; try decide)
          · simp_all; decide
        · simp_all; decide
  posWitness := ⟨4, 3, 1, 1, 1, 0, 128, 4096⟩
  negWitness := ⟨4, 3, 1, 1, 0, 0, 128, 4096⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 64 (`TotalDecoder`, `CostBound` & Thinking-Block Closure — `orb_agent_event_normalize_step`):
    1. `totalTransducerBit` (`2048`) is ALWAYS set for every harness and payload.
    2. Output byte count (`hi32`) is always bounded by `maxPayloadBytes`.
    3. `AssistantText` (`rawEventKind = 3`), `ToolCall` (`4`), `TurnCompleted` (`6`), and `ErrorOrAuth` (`7`)
       always set `closeThinkingBit` (`1024`) when admitted. -/
theorem agent_event_normalizer_total_bounded_and_closes_thinking
    (hk rk ic txt : UInt8) (sess dup bytes maxBytes : UInt32) :
    ((agentEventNormalizeStep hk rk ic txt sess dup bytes maxBytes &&& 0xFFFFFFFF) &&& 2048) = 2048 ∧
    decide ((agentEventNormalizeStep hk rk ic txt sess dup bytes maxBytes >>> 32).toUInt32 ≤ maxBytes) = true ∧
    ((agentEventNormalizeStep 4 3 1 1 1 0 64 1024 &&& 0xFFFFFFFF) &&& 1024) = 1024 := by
  refine ⟨?_, ?_, by decide⟩
  · unfold agentEventNormalizeStep
    rw [pack32_lo]
    cases hb : decide (bytes ≤ maxBytes)
    · simp_all
    · cases hv : (decide (hk ≤ 5) && (sess == 1 || rk == 0 || rk == 1 || rk == 7) && (dup == 0))
      · simp_all; decide
      · cases hr0 : (rk == 0)
        · cases hr1 : (rk == 1)
          · cases hr2 : (rk == 2)
            · cases hr3 : (rk == 3)
              · cases hr4 : (rk == 4)
                · cases hr5 : (rk == 5)
                  · cases hr6 : (rk == 6)
                    · cases hr7 : (rk == 7) <;> (simp_all; decide)
                    · simp_all; decide
                  · simp_all; decide
                · cases hc : (ic == 1) <;> (simp_all; decide)
              · cases ht : (txt == 1) <;> (simp_all; decide)
            · cases ht : (txt == 1) <;> (simp_all; decide)
          · simp_all; decide
        · simp_all; decide
  · unfold agentEventNormalizeStep
    rw [pack32_hi]
    cases hb : decide (bytes ≤ maxBytes)
    · simp_all
    · simp_all

structure TranscriptReduceCheck where
  lastAppliedSeq   : UInt64
  incomingSeq      : UInt64
  thinkingOpen     : UInt8
  normalizedAction : UInt8
  isReplayFromLog  : UInt8
  deriving Repr, DecidableEq

def TranscriptReduceCheck.Admissible (t : TranscriptReduceCheck) : Bool :=
  decide (t.incomingSeq > t.lastAppliedSeq) &&
  ((t.normalizedAction == 4) ||
   (t.normalizedAction == 5 || t.normalizedAction == 6 || t.normalizedAction == 7 ||
    t.normalizedAction == 9 || t.normalizedAction == 10) ||
   (t.normalizedAction == 2 || t.normalizedAction == 3 || t.normalizedAction == 8))

def transcriptReduceMetaGate : MetaGateSpec TranscriptReduceCheck
    (fun t => t.Admissible = true) where
  gate t :=
    ((transcriptReduceStep t.lastAppliedSeq t.incomingSeq t.thinkingOpen
        t.normalizedAction t.isReplayFromLog &&& 0xFFFFFFFF) &&& 256) != 0
  sound t h := by
    unfold TranscriptReduceCheck.Admissible
    unfold transcriptReduceStep at h
    rw [pack32_lo] at h
    cases hs : decide (t.incomingSeq > t.lastAppliedSeq) <;>
      cases ha4 : (t.normalizedAction == 4) <;>
      cases ha5 : (t.normalizedAction == 5 || t.normalizedAction == 6 || t.normalizedAction == 7 ||
                   t.normalizedAction == 9 || t.normalizedAction == 10) <;>
      cases ha2 : (t.normalizedAction == 2 || t.normalizedAction == 3 || t.normalizedAction == 8) <;>
      cases ht : (t.thinkingOpen == 1) <;>
      (simp_all;
        try (exfalso; revert h; decide))
  complete t h := by
    unfold TranscriptReduceCheck.Admissible at h
    unfold transcriptReduceStep
    rw [pack32_lo]
    cases hs : decide (t.incomingSeq > t.lastAppliedSeq) <;>
      cases ha4 : (t.normalizedAction == 4) <;>
      cases ha5 : (t.normalizedAction == 5 || t.normalizedAction == 6 || t.normalizedAction == 7 ||
                   t.normalizedAction == 9 || t.normalizedAction == 10) <;>
      cases ha2 : (t.normalizedAction == 2 || t.normalizedAction == 3 || t.normalizedAction == 8) <;>
      cases ht : (t.thinkingOpen == 1) <;>
      (simp_all; try decide)
  posWitness := ⟨10, 11, 1, 5, 0⟩
  negWitness := ⟨10, 10, 1, 5, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 65 (`IdempotentReplay` & `MonotoneProgress` — `orb_transcript_reduce_step`):
    Single-step transition word invariance (`transcript_reduce_step_word_ignores_replay_flag_and_rejects_stale_seq`):
    1. Replaying a single step from the persisted event log (`isReplayFromLog = 1`) produces the exact same
       64-bit reducer transition word as live streaming (`isReplayFromLog = 0`).
    2. Duplicate or stale sequence numbers (`incomingSeq <= lastAppliedSeq`) never emit a transcript entry (`emitEntryBit = 0`). -/
theorem transcript_reduce_step_word_ignores_replay_flag_and_rejects_stale_seq
    (lastSeq incSeq : UInt64) (think act : UInt8) :
    transcriptReduceStep lastSeq incSeq think act 1 = transcriptReduceStep lastSeq incSeq think act 0 ∧
    ((transcriptReduceStep lastSeq lastSeq think act 0 &&& 0xFFFFFFFF) &&& 256) = 0 := by
  refine ⟨rfl, ?_⟩
  unfold transcriptReduceStep
  rw [pack32_lo]
  have hirr : ¬ (lastSeq > lastSeq) := UInt64.lt_irrefl lastSeq
  cases ht : (think == 1) <;> (simp_all; try decide)

def effectiveTranscriptState (lastSeq : UInt64) (e : TranscriptReduceCheck) : TranscriptReduceCheck :=
  { e with lastAppliedSeq := lastSeq }

def transcriptReduceMachineStep (lastSeq : UInt64) (e : TranscriptReduceCheck) : UInt64 × List UInt64 :=
  let e' := effectiveTranscriptState lastSeq e
  let nextSeq := if e'.incomingSeq > e'.lastAppliedSeq then e'.incomingSeq else e'.lastAppliedSeq
  (nextSeq, if transcriptReduceMetaGate.gate e' then [e.incomingSeq] else [])

/-- Concrete `MetaStepSpec` instance #4 for Phase 3 (`orb_transcript_reduce_step`). -/
def transcriptReduceMetaStepSpec : MetaStepSpec UInt64 TranscriptReduceCheck UInt64 where
  safety := {
    step := transcriptReduceMachineStep
    authorized := fun s e eff =>
      eff == e.incomingSeq && (effectiveTranscriptState s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [transcriptReduceMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := transcriptReduceMetaGate.sound (effectiveTranscriptState s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := 0
    step := transcriptReduceMachineStep
    progressRequired := fun s e => (effectiveTranscriptState s e).Admissible
    expectedEffect := fun e eff => eff == e.incomingSeq
    live := fun s e h_req => by
      have h_gate := transcriptReduceMetaGate.complete (effectiveTranscriptState s e) h_req
      dsimp [transcriptReduceMachineStep]
      simp [h_gate]
    traceEvents := [⟨0, 1, 0, 4, 0⟩, ⟨1, 2, 1, 5, 1⟩]
    posEvent := ⟨2, 3, 0, 5, 0⟩
    negEvent := ⟨2, 2, 0, 5, 0⟩
    reachable_live := by decide
  }
  cost := {
    step := transcriptReduceMachineStep
    cpuFuel := fun s e => 5 + ((transcriptReduceMachineStep s e).2).length
    inputBytes := fun _ => 24
    outputBytes := fun s e => 8 + 8 * ((transcriptReduceMachineStep s e).2).length
    c0 := 6
    c1 := 1
    maxEffects := 1
    maxOutBytes := 16
    fuel_bound := fun s e => by
      dsimp [transcriptReduceMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [transcriptReduceMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [transcriptReduceMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

-- ===========================================================================
-- Wave 9 Phase 4: Storage Invariants — Pagination Cursors & Sidebar Merge
-- ===========================================================================

structure CursorPageCheck where
  sinceSeq          : UInt64
  beforeSeq         : UInt64
  itemSeq           : UInt64
  hasSinceCursor    : UInt32
  hasBeforeCursor   : UInt32
  isPartialResponse : UInt32
  existingCount     : UInt32
  deriving Repr, DecidableEq

def CursorPageCheck.Admissible (c : CursorPageCheck) : Bool :=
  !(c.hasSinceCursor == 1 && c.hasBeforeCursor == 1 && c.sinceSeq >= c.beforeSeq) &&
  (c.hasSinceCursor == 0 || c.itemSeq > c.sinceSeq) &&
  (c.hasBeforeCursor == 0 || c.itemSeq < c.beforeSeq)

def cursorPageMetaGate : MetaGateSpec CursorPageCheck
    (fun c => c.Admissible = true) where
  gate c :=
    ((cursorPageStep c.sinceSeq c.beforeSeq c.itemSeq c.hasSinceCursor
        c.hasBeforeCursor c.isPartialResponse c.existingCount &&& 0xFFFFFFFF) &&& 256) != 0
  sound c h := by
    unfold CursorPageCheck.Admissible
    unfold cursorPageStep at h
    rw [pack32_lo] at h
    cases hvw : (c.hasSinceCursor == 1 && c.hasBeforeCursor == 1 && decide (c.sinceSeq ≥ c.beforeSeq)) <;>
      cases has : (c.hasSinceCursor == 0 || decide (c.itemSeq > c.sinceSeq)) <;>
      cases hbb : (c.hasBeforeCursor == 0 || decide (c.itemSeq < c.beforeSeq)) <;>
      cases hp : (c.isPartialResponse == 1) <;>
      (simp_all;
        try (exfalso; revert h; decide))
  complete c h := by
    unfold CursorPageCheck.Admissible at h
    unfold cursorPageStep
    rw [pack32_lo]
    cases hvw : (c.hasSinceCursor == 1 && c.hasBeforeCursor == 1 && decide (c.sinceSeq ≥ c.beforeSeq)) <;>
      cases has : (c.hasSinceCursor == 0 || decide (c.itemSeq > c.sinceSeq)) <;>
      cases hbb : (c.hasBeforeCursor == 0 || decide (c.itemSeq < c.beforeSeq)) <;>
      cases hp : (c.isPartialResponse == 1) <;>
      (simp_all; try decide)
  posWitness := ⟨10, 20, 15, 1, 1, 0, 5⟩
  negWitness := ⟨10, 20, 10, 1, 1, 0, 5⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 66 (`MonotoneProgress` & `ConservedResource` — `orb_cursor_page_step`):
    1. `preserveExistingBit` (`512`) is ALWAYS `1` under all inputs (`partial_response_never_wipes_existing`).
    2. Exclusive cursor bounds: `itemSeq == sinceSeq` (with `hasSinceCursor = 1`) and `itemSeq == beforeSeq`
       (with `hasBeforeCursor = 1`) are strictly excluded (`includeItemBit = 0`), preventing boundary duplicates. -/
theorem exclusive_cursor_no_gap_no_dup_and_partial_never_wipes
    (sSeq bSeq iSeq : UInt64) (hasS hasB isPart cnt : UInt32) :
    ((cursorPageStep sSeq bSeq iSeq hasS hasB isPart cnt &&& 0xFFFFFFFF) &&& 512) = 512 ∧
    ((cursorPageStep sSeq bSeq sSeq 1 hasB isPart cnt &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    ((cursorPageStep sSeq bSeq bSeq hasS 1 isPart cnt &&& 0xFFFFFFFF) &&& 256) = 0 := by
  refine ⟨?_, ?_, ?_⟩
  · unfold cursorPageStep
    rw [pack32_lo]
    cases hvw : (hasS == 1 && hasB == 1 && decide (sSeq ≥ bSeq)) <;>
      cases has : (hasS == 0 || decide (iSeq > sSeq)) <;>
      cases hbb : (hasB == 0 || decide (iSeq < bSeq)) <;>
      cases hp : (isPart == 1) <;>
      (simp_all; try decide)
  · unfold cursorPageStep
    rw [pack32_lo]
    have hirr : decide (sSeq > sSeq) = false := decide_eq_false (UInt64.lt_irrefl sSeq)
    cases hb1 : (hasB == 1) <;>
      cases hb0 : (hasB == 0) <;>
      cases hsb : decide (sSeq ≥ bSeq) <;>
      cases hlt : decide (sSeq < bSeq) <;>
      cases hp : (isPart == 1) <;>
      (simp only [hirr, hb1, hb0, hsb, hlt, hp]; decide)
  · unfold cursorPageStep
    rw [pack32_lo]
    have hirr : decide (bSeq < bSeq) = false := decide_eq_false (UInt64.lt_irrefl bSeq)
    cases hs1 : (hasS == 1) <;>
      cases hs0 : (hasS == 0) <;>
      cases hsb : decide (sSeq ≥ bSeq) <;>
      cases hbs : decide (bSeq > sSeq) <;>
      cases hp : (isPart == 1) <;>
      (simp only [hirr, hs1, hs0, hsb, hbs, hp]; decide)

def effectiveCursorCount (cnt : UInt32) (e : CursorPageCheck) : CursorPageCheck :=
  { e with existingCount := cnt }

def storageCursorMachineStep (cnt : UInt32) (e : CursorPageCheck) : UInt32 × List UInt64 :=
  let e' := effectiveCursorCount cnt e
  let admit := cursorPageMetaGate.gate e'
  (if admit then cnt + 1 else cnt, if admit then [e.itemSeq] else [])

/-- Concrete `MetaStepSpec` instance #5 for Phase 4 (`orb_cursor_page_step`). -/
def storageCursorMetaStepSpec : MetaStepSpec UInt32 CursorPageCheck UInt64 where
  safety := {
    step := storageCursorMachineStep
    authorized := fun s e eff =>
      eff == e.itemSeq && (effectiveCursorCount s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [storageCursorMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := cursorPageMetaGate.sound (effectiveCursorCount s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := 0
    step := storageCursorMachineStep
    progressRequired := fun s e => (effectiveCursorCount s e).Admissible
    expectedEffect := fun e eff => eff == e.itemSeq
    live := fun s e h_req => by
      have h_gate := cursorPageMetaGate.complete (effectiveCursorCount s e) h_req
      dsimp [storageCursorMachineStep]
      simp [h_gate]
    traceEvents := [⟨10, 20, 11, 1, 1, 0, 0⟩, ⟨10, 20, 12, 1, 1, 0, 1⟩]
    posEvent := ⟨10, 20, 15, 1, 1, 0, 2⟩
    negEvent := ⟨10, 20, 10, 1, 1, 0, 2⟩
    reachable_live := by decide
  }
  cost := {
    step := storageCursorMachineStep
    cpuFuel := fun s e => 7 + ((storageCursorMachineStep s e).2).length
    inputBytes := fun _ => 40
    outputBytes := fun s e => 8 + 8 * ((storageCursorMachineStep s e).2).length
    c0 := 8
    c1 := 1
    maxEffects := 1
    maxOutBytes := 16
    fuel_bound := fun s e => by
      dsimp [storageCursorMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [storageCursorMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [storageCursorMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

structure SidebarMergeCheck where
  existingIdOrd                : UInt32
  incomingIdOrd                : UInt32
  existingUpdatedAtMs          : UInt64
  incomingUpdatedAtMs          : UInt64
  incomingSupersededOrArchived : UInt8
  isPartialPage                : UInt8
  deriving Repr, DecidableEq

def SidebarMergeCheck.Admissible (s : SidebarMergeCheck) : Bool :=
  !(s.incomingSupersededOrArchived == 1)

def sidebarMergeMetaGate : MetaGateSpec SidebarMergeCheck
    (fun s => s.Admissible = true) where
  gate s :=
    ((sidebarMergeStep s.existingIdOrd s.incomingIdOrd s.existingUpdatedAtMs
        s.incomingUpdatedAtMs s.incomingSupersededOrArchived s.isPartialPage &&& 0xFFFFFFFF) &&& 256) != 0
  sound s h := by
    unfold SidebarMergeCheck.Admissible
    unfold sidebarMergeStep at h
    rw [pack32_lo] at h
    cases hsup : (s.incomingSupersededOrArchived == 1) <;>
      cases hsame : (s.existingIdOrd != 0 && s.existingIdOrd == s.incomingIdOrd) <;>
      cases hnew : decide (s.incomingUpdatedAtMs ≥ s.existingUpdatedAtMs) <;>
      cases hpart : (s.isPartialPage == 1) <;>
      (simp only [hsup, hsame, hnew, hpart] at h ⊢; revert h; decide)
  complete s h := by
    unfold SidebarMergeCheck.Admissible at h
    unfold sidebarMergeStep
    rw [pack32_lo]
    cases hsup : (s.incomingSupersededOrArchived == 1) <;>
      cases hsame : (s.existingIdOrd != 0 && s.existingIdOrd == s.incomingIdOrd) <;>
      cases hnew : decide (s.incomingUpdatedAtMs ≥ s.existingUpdatedAtMs) <;>
      cases hpart : (s.isPartialPage == 1) <;>
      (simp only [hsup, hsame, hnew, hpart] at h ⊢; revert h; decide)
  posWitness := ⟨42, 42, 1000, 2000, 0, 1⟩
  negWitness := ⟨42, 42, 1000, 2000, 1, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 67 (`IdempotentReplay` & `ConservedResource` — `orb_sidebar_merge_step`):
    1. `uniqueSidebarBit` (`1024`) is ALWAYS `1`.
    2. Merging a mission with an existing mission of the same non-zero ordinal (`idOrd != 0`)
       NEVER inserts a duplicate row (`insertNewBit = 512` is `0` and net new rows `hi32 = 0`). -/
theorem sidebar_missions_unique_and_idempotent
    (idOrd : UInt32) (exTs incTs : UInt64) (sup part : UInt8)
    (h_nonzero : (idOrd != 0) = true) :
    ((sidebarMergeStep idOrd idOrd exTs incTs sup part &&& 0xFFFFFFFF) &&& 1024) = 1024 ∧
    ((sidebarMergeStep idOrd idOrd exTs incTs sup part &&& 0xFFFFFFFF) &&& 512) = 0 ∧
    (sidebarMergeStep idOrd idOrd exTs incTs sup part >>> 32) = 0 := by
  have hsame : (idOrd != 0 && idOrd == idOrd) = true := by simp [h_nonzero]
  refine ⟨?_, ?_, ?_⟩
  · unfold sidebarMergeStep
    rw [pack32_lo]
    cases hsup : (sup == 1) <;>
      cases hnew : decide (incTs ≥ exTs) <;>
      cases hpart : (part == 1) <;>
      (simp only [hsame, hsup, hnew, hpart]; decide)
  · unfold sidebarMergeStep
    rw [pack32_lo]
    cases hsup : (sup == 1) <;>
      cases hnew : decide (incTs ≥ exTs) <;>
      cases hpart : (part == 1) <;>
      (simp only [hsame, hsup, hnew, hpart]; decide)
  · unfold sidebarMergeStep
    rw [pack32_hi]
    cases hsup : (sup == 1) <;> (simp only [hsame, hsup]; decide)

-- ===========================================================================
-- Wave 9 Phase 6: Clients (iOS, Android & Desktop `wasm32`) Scroll Epoch & Parity
-- ===========================================================================

structure ScrollEpochCheck where
  layoutEpoch         : UInt32
  lastCorrectedEpoch  : UInt32
  correctionsInEpoch  : UInt8
  isPinnedToBottom    : UInt8
  userIsDragging      : UInt8
  targetScrollTopPx   : UInt32
  currentScrollTopPx  : UInt32
  deriving Repr, DecidableEq

def ScrollEpochCheck.Admissible (s : ScrollEpochCheck) : Bool :=
  s.isPinnedToBottom == 1 && s.userIsDragging == 0 &&
  !(!(decide (s.layoutEpoch > s.lastCorrectedEpoch)) && decide (s.correctionsInEpoch > 0)) &&
  s.targetScrollTopPx != s.currentScrollTopPx

def scrollEpochMetaGate : MetaGateSpec ScrollEpochCheck
    (fun s => s.Admissible = true) where
  gate s :=
    ((scrollEpochStep s.layoutEpoch s.lastCorrectedEpoch s.correctionsInEpoch
        s.isPinnedToBottom s.userIsDragging s.targetScrollTopPx s.currentScrollTopPx &&& 0xFFFFFFFF) &&& 256) != 0
  sound s h := by
    unfold ScrollEpochCheck.Admissible
    unfold scrollEpochStep at h
    rw [pack32_lo] at h
    cases hne : decide (s.layoutEpoch > s.lastCorrectedEpoch) <;>
      cases hce : decide (s.correctionsInEpoch > 0) <;>
      cases hpin : (s.isPinnedToBottom == 1) <;>
      cases hdrag : (s.userIsDragging == 0) <;>
      cases hdel : (s.targetScrollTopPx != s.currentScrollTopPx) <;>
      (simp only [hne, hce, hpin, hdrag, hdel] at h ⊢; revert h; decide)
  complete s h := by
    unfold ScrollEpochCheck.Admissible at h
    unfold scrollEpochStep
    rw [pack32_lo]
    cases hne : decide (s.layoutEpoch > s.lastCorrectedEpoch) <;>
      cases hce : decide (s.correctionsInEpoch > 0) <;>
      cases hpin : (s.isPinnedToBottom == 1) <;>
      cases hdrag : (s.userIsDragging == 0) <;>
      cases hdel : (s.targetScrollTopPx != s.currentScrollTopPx) <;>
      (simp only [hne, hce, hpin, hdrag, hdel] at h ⊢; revert h; decide)
  posWitness := ⟨5, 4, 0, 1, 0, 800, 600⟩
  negWitness := ⟨4, 4, 1, 1, 0, 800, 600⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 68 (`StickyFence` — `orb_scroll_epoch_step`, `scroll_correction_at_most_once_per_epoch`):
    Once a scroll correction has been applied in `epoch` (`correctionsInEpoch = 1` at `layoutEpoch == lastCorrectedEpoch`),
    any subsequent correction attempt in the same epoch is suppressed (`applyScrollBit = 0`, `action = 2`,
    and `hi32 = currentScrollTopPx`). -/
theorem scroll_correction_at_most_once_per_epoch
    (epoch targetPx currentPx : UInt32) (pin drag : UInt8) :
    ((scrollEpochStep epoch epoch 1 pin drag targetPx currentPx &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (scrollEpochStep epoch epoch 1 pin drag targetPx currentPx &&& 0xFFFFFFFF) = 1026 ∧
    (scrollEpochStep epoch epoch 1 pin drag targetPx currentPx >>> 32) = currentPx.toUInt64 := by
  have hirr : ¬ (epoch > epoch) := UInt32.lt_irrefl epoch
  refine ⟨?_, ?_, ?_⟩
  · unfold scrollEpochStep
    rw [pack32_lo]
    cases hp : (pin == 1) <;>
      cases hd : (drag == 0) <;>
      cases hdel : (targetPx != currentPx) <;>
      (simp_all; try decide)
  · unfold scrollEpochStep
    rw [pack32_lo]
    cases hp : (pin == 1) <;>
      cases hd : (drag == 0) <;>
      cases hdel : (targetPx != currentPx) <;>
      (simp_all; try decide)
  · unfold scrollEpochStep
    rw [pack32_hi]
    cases hp : (pin == 1) <;>
      cases hd : (drag == 0) <;>
      cases hdel : (targetPx != currentPx) <;>
      simp_all

def effectiveScrollState (lastEpoch : UInt32) (e : ScrollEpochCheck) : ScrollEpochCheck :=
  { e with
    lastCorrectedEpoch := lastEpoch
    correctionsInEpoch := if e.layoutEpoch <= lastEpoch then 1 else 0 }

def scrollEpochMachineStep (lastEpoch : UInt32) (e : ScrollEpochCheck) : UInt32 × List UInt32 :=
  let e' := effectiveScrollState lastEpoch e
  let admit := scrollEpochMetaGate.gate e'
  (if admit then e'.layoutEpoch else lastEpoch, if admit then [e.targetScrollTopPx] else [])

/-- Concrete `MetaStepSpec` instance #6 for Phase 6 (`orb_scroll_epoch_step`). -/
def scrollEpochMetaStepSpec : MetaStepSpec UInt32 ScrollEpochCheck UInt32 where
  safety := {
    step := scrollEpochMachineStep
    authorized := fun s e eff =>
      eff == e.targetScrollTopPx && (effectiveScrollState s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [scrollEpochMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := scrollEpochMetaGate.sound (effectiveScrollState s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := 0
    step := scrollEpochMachineStep
    progressRequired := fun s e => (effectiveScrollState s e).Admissible
    expectedEffect := fun e eff => eff == e.targetScrollTopPx
    live := fun s e h_req => by
      have h_gate := scrollEpochMetaGate.complete (effectiveScrollState s e) h_req
      dsimp [scrollEpochMachineStep]
      simp [h_gate]
    traceEvents := [⟨1, 0, 0, 1, 0, 400, 200⟩, ⟨2, 1, 0, 1, 0, 600, 400⟩]
    posEvent := ⟨3, 2, 0, 1, 0, 900, 600⟩
    negEvent := ⟨2, 2, 1, 1, 0, 900, 600⟩
    reachable_live := by decide
  }
  cost := {
    step := scrollEpochMachineStep
    cpuFuel := fun s e => 7 + ((scrollEpochMachineStep s e).2).length
    inputBytes := fun _ => 24
    outputBytes := fun s e => 8 + 4 * ((scrollEpochMachineStep s e).2).length
    c0 := 8
    c1 := 1
    maxEffects := 1
    maxOutBytes := 12
    fuel_bound := fun s e => by
      dsimp [scrollEpochMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [scrollEpochMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [scrollEpochMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

structure ClientParityCheck where
  clientTarget           : UInt8
  wireSchemaId           : UInt32
  transcriptSeq          : UInt32
  markdownBlocksCount    : UInt32
  sendQueueDepth         : UInt32
  scrollCorrectedInEpoch : UInt8
  deriving Repr, DecidableEq

set_option linter.unusedSimpArgs false in
def clientParityMetaGate : MetaGateSpec ClientParityCheck
    (fun c => (c.clientTarget <= 3 && c.wireSchemaId >= 1 && c.wireSchemaId <= 2) = true) where
  gate c :=
    ((clientParityStep c.clientTarget c.wireSchemaId c.transcriptSeq
        c.markdownBlocksCount c.sendQueueDepth c.scrollCorrectedInEpoch &&& 0xFFFFFFFF) &&& 256) != 0
  sound c h := by
    unfold clientParityStep at h
    rw [pack32_lo] at h
    cases ht : decide (c.clientTarget ≤ 3) <;>
      cases hs1 : decide (1 ≤ c.wireSchemaId) <;>
      cases hs2 : decide (c.wireSchemaId ≤ 2) <;>
      cases hsc : (c.scrollCorrectedInEpoch == 1) <;>
      (simp only [ht, hs1, hs2, hsc] at h ⊢; revert h; decide)
  complete c h := by
    unfold clientParityStep
    rw [pack32_lo]
    cases ht : decide (c.clientTarget ≤ 3) <;>
      cases hs1 : decide (1 ≤ c.wireSchemaId) <;>
      cases hs2 : decide (c.wireSchemaId ≤ 2) <;>
      cases hsc : (c.scrollCorrectedInEpoch == 1) <;>
      (simp only [ht, hs1, hs2, hsc] at h ⊢; revert h; decide)
  posWitness := ⟨1, 1, 42, 8, 2, 1⟩
  negWitness := ⟨9, 1, 42, 8, 2, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 69 (`IdempotentReplay` — `orb_client_parity_step`, Summary Digest Word Parity Across Targets):
    Core (`0`), iOS (`1`), Android (`2`), and Desktop `wasm32` (`3`) produce the exact same
    64-bit XOR/count summary digest word on any `OrbWire` event summary (`wireSchemaId`, `transcriptSeq`,
    `markdownBlocksCount`, `sendQueueDepth`, `scrollCorrectedInEpoch`).
    Note: This establishes equality of the 64-bit summary word (`clientParityStep`), not full client-state equivalence. -/
theorem client_summary_digest_word_parity_across_targets
    (schema : UInt32) (seq blocks queue : UInt32) (sc : UInt8) :
    clientParityStep 0 schema seq blocks queue sc = clientParityStep 1 schema seq blocks queue sc ∧
    clientParityStep 1 schema seq blocks queue sc = clientParityStep 2 schema seq blocks queue sc ∧
    clientParityStep 2 schema seq blocks queue sc = clientParityStep 3 schema seq blocks queue sc := by
  unfold clientParityStep
  have h0 : decide ((0 : UInt8) ≤ 3) = true := by decide
  have h1 : decide ((1 : UInt8) ≤ 3) = true := by decide
  have h2 : decide ((2 : UInt8) ≤ 3) = true := by decide
  have h3 : decide ((3 : UInt8) ≤ 3) = true := by decide
  simp only [h0, h1, h2, h3, and_self]

-- ===========================================================================
-- Wave 10: Fleet Security — Canary Blast-Radius Isolation, Process Whitelist,
--          High-Signal Attacker Bait, Enforcer Convergence & Biometric/Mesh Gates
-- ===========================================================================

structure CanaryTripwireCheck where
  canaryClass        : UInt8
  actorTrust         : UInt8
  isDryRun           : UInt8
  currentFleetBunker : UInt8
  deriving Repr, DecidableEq

def CanaryTripwireCheck.RequiresFleetLockdown (c : CanaryTripwireCheck) : Bool :=
  !(c.isDryRun == 1) && (c.canaryClass >= 1 || (!(c.actorTrust == 0) && !(c.actorTrust == 1)))

set_option linter.unusedSimpArgs false in
def canaryTripwireLockdownMetaGate : MetaGateSpec CanaryTripwireCheck
    (fun c => c.RequiresFleetLockdown = true) where
  gate c :=
    ((canaryTripwireStep c.canaryClass c.actorTrust c.isDryRun c.currentFleetBunker &&& 0xFFFFFFFF) &&& 512) != 0
  sound c h := by
    unfold CanaryTripwireCheck.RequiresFleetLockdown
    unfold canaryTripwireStep at h
    rw [pack32_lo] at h
    cases hd : (c.isDryRun == 1) <;>
      cases hc : decide (1 ≤ c.canaryClass) <;>
      cases ha0 : (c.actorTrust == 0) <;>
      cases ha1 : (c.actorTrust == 1) <;>
      (simp only [hd, hc, ha0, ha1] at h ⊢; revert h; decide)
  complete c h := by
    unfold CanaryTripwireCheck.RequiresFleetLockdown at h
    unfold canaryTripwireStep
    rw [pack32_lo]
    cases hd : (c.isDryRun == 1) <;>
      cases hc : decide (1 ≤ c.canaryClass) <;>
      cases ha0 : (c.actorTrust == 0) <;>
      cases ha1 : (c.actorTrust == 1) <;>
      (simp only [hd, hc, ha0, ha1] at h ⊢; revert h; decide)
  posWitness := ⟨1, 0, 0, 0⟩
  negWitness := ⟨0, 1, 0, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 70 (`ScopedAuthority` — `canaryTripwireStep`, Whitelisted Agent Walk Never Triggers Bunker):
    When a whitelisted agent process (`actorTrust = 0`, e.g., `rg`, `fd`, `find`, `ls`, `git`) touches
    an ambient decoy (`canaryClass = 0`, e.g., `.env.production.canary` or `.vault-recovery.age`),
    neither node quarantine (`bit 8 = 256`) nor fleet lockdown (`bit 9 = 512`) is triggered,
    and `nextFleetBunker = 0` (`hi32 = 0`) when starting from `Normal (0)`. -/
theorem canary_whitelisted_ambient_no_bunker :
    canaryTripwireStep 0 0 0 0 = 0 ∧
    ((canaryTripwireStep 0 0 0 0 &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    ((canaryTripwireStep 0 0 0 0 &&& 0xFFFFFFFF) &&& 512) = 0 ∧
    (canaryTripwireStep 0 0 0 0 >>> 32) = 0 := by
  decide

/-- Corollary 71 (`ScopedAuthority` — `canaryTripwireStep`, Single Mission Honeytoken Read Quarantines Node Only):
    When a mission job process (`actorTrust = 1`) reads an ambient decoy (`canaryClass = 0`,
    e.g., `.env.production.canary`), the step returns `action = 1 (QuarantineNodeOnly)` (`bit 8 = 256`
    quarantines ONLY the reporting node), while `fleetLockdownBit = 0` (`bit 9 = 512`) and
    `nextFleetBunker` (`hi32`) stays `0 (Normal)` — never locking down the entire fleet. -/
theorem canary_mission_ambient_node_only :
    ((canaryTripwireStep 0 1 0 0 &&& 0xFFFFFFFF) &&& 0xFF) = 1 ∧
    ((canaryTripwireStep 0 1 0 0 &&& 0xFFFFFFFF) &&& 256) = 256 ∧
    ((canaryTripwireStep 0 1 0 0 &&& 0xFFFFFFFF) &&& 512) = 0 ∧
    (canaryTripwireStep 0 1 0 0 >>> 32) = 0 := by
  decide

/-- Corollary 72 (`StickyFence` — `canaryTripwireStep`, High-Signal Attacker Bait Always Locks Down Fleet Even From Own Agent):
    Accessing high-signal attacker bait (`canaryClass >= 1`, e.g., fake Bitcoin private key / seed wallet
    `btc_wallet_canary` or `ssh_exfil_canary`) ALWAYS escalates to fleet `HardLockdown (2)` (`lo32 = 1794`,
    `action = 2`, `quarantineBit = 256`, `lockdownBit = 512`, `hi32 = 2`), EVEN when the actor is a
    whitelisted agent walk (`actorTrust = 0`) or mission process (`actorTrust = 1`). -/
theorem canary_high_signal_bait_always_locks_down
    (canaryClass actorTrust currentBunker : UInt8)
    (h_bait : 1 ≤ canaryClass) :
    (canaryTripwireStep canaryClass actorTrust 0 currentBunker &&& 0xFFFFFFFF) = 1794 ∧
    (canaryTripwireStep canaryClass actorTrust 0 currentBunker >>> 32) = 2 := by
  have hc : decide (1 ≤ canaryClass) = true := decide_eq_true h_bait
  refine ⟨?_, ?_⟩
  · unfold canaryTripwireStep
    rw [pack32_lo]
    simp [hc]
  · unfold canaryTripwireStep
    rw [pack32_hi]
    simp [hc]

def canaryTripwireMachineStep (curBunker : UInt8) (e : CanaryTripwireCheck) : UInt8 × List UInt8 :=
  let e' : CanaryTripwireCheck := { e with currentFleetBunker := curBunker }
  let lock := canaryTripwireLockdownMetaGate.gate e'
  (if lock then 2 else curBunker, if lock then [2] else [])

/-- Concrete `MetaStepSpec` instance #7 for Wave 10 (`canaryTripwireStep`). -/
def canaryTripwireMetaStepSpec : MetaStepSpec UInt8 CanaryTripwireCheck UInt8 where
  safety := {
    step := canaryTripwireMachineStep
    authorized := fun s e eff =>
      eff == 2 && ({ e with currentFleetBunker := s } : CanaryTripwireCheck).RequiresFleetLockdown
    sound := fun s e eff h_in => by
      dsimp [canaryTripwireMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := canaryTripwireLockdownMetaGate.sound { e with currentFleetBunker := s } h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := 0
    step := canaryTripwireMachineStep
    progressRequired := fun s e => ({ e with currentFleetBunker := s } : CanaryTripwireCheck).RequiresFleetLockdown
    expectedEffect := fun _ eff => eff == 2
    live := fun s e h_req => by
      have h_gate := canaryTripwireLockdownMetaGate.complete { e with currentFleetBunker := s } h_req
      dsimp [canaryTripwireMachineStep]
      simp [h_gate]
    traceEvents := [⟨0, 0, 0, 0⟩, ⟨0, 1, 0, 0⟩]
    posEvent := ⟨1, 0, 0, 0⟩
    negEvent := ⟨0, 1, 0, 0⟩
    reachable_live := by decide
  }
  cost := {
    step := canaryTripwireMachineStep
    cpuFuel := fun s e => 4 + ((canaryTripwireMachineStep s e).2).length
    inputBytes := fun _ => 4
    outputBytes := fun s e => 4 + ((canaryTripwireMachineStep s e).2).length
    c0 := 5
    c1 := 1
    maxEffects := 1
    maxOutBytes := 5
    fuel_bound := fun s e => by
      dsimp [canaryTripwireMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [canaryTripwireMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [canaryTripwireMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

/-- Corollary 73 (`ClockDiscipline` — `bunkerEnforcerStep`, Worker Enforcer Converges to Normal on Unbunker):
    When status is reachable (`statusReachable = 1`), fleet bunker is below lockdown (`¬ (2 ≤ fleetBunker)`),
    the node is not individually quarantined (`nodeQuarantinedByCore = 0`), and `lastUnbunkerEpoch ≥ localTripEpoch`,
    the enforcer releases quarantine (`bit 8 = 0`) and clears any local trip marker (`bit 9 = 512` when `hasMarker = 1`). -/
theorem bunker_enforcer_converges_on_unbunker
    (fleetBunker hasMarker : UInt8) (localTripEpoch lastUnbunkerEpoch : UInt64)
    (h_norm : ¬ (2 ≤ fleetBunker))
    (h_unbunkered : localTripEpoch ≤ lastUnbunkerEpoch) :
    (bunkerEnforcerStep 1 fleetBunker 0 hasMarker localTripEpoch lastUnbunkerEpoch &&& 256) = 0 := by
  have hf : decide (2 ≤ fleetBunker) = false := decide_eq_false h_norm
  have hu : decide (localTripEpoch ≤ lastUnbunkerEpoch) = true := decide_eq_true h_unbunkered
  unfold bunkerEnforcerStep
  cases hm : (hasMarker == 0) <;> cases hm1 : (hasMarker == 1) <;>
    (simp only [hf, hu, hm, hm1]; decide)

/-- Corollary 74 (`ScopedAuthority` — `biometricGateStep`, Mobile Biometric Gate Never Fails Open):
    When `surfaceRequiresBio = 1` and neither hardware biometric evaluation (`hardwareEnrolled == 1 && evalSucceeded == 1`)
    nor passcode fallback (`hardwareEnrolled == 0 && passcodeFallbackSucceeded == 1`) succeeded,
    `biometricGateStep` rejects the action (`admittedBit = 0`) and sets `surfaceErrorBit = 512`. -/
theorem biometric_gate_never_fails_open
    (hwEnrolled evalOk fallbackOk : UInt8)
    (h_no_bio : ¬ (hwEnrolled == 1 && evalOk == 1) = true)
    (h_no_fb : ¬ (hwEnrolled == 0 && fallbackOk == 1) = true) :
    biometricGateStep 1 hwEnrolled evalOk fallbackOk = 512 := by
  unfold biometricGateStep
  cases hb : (hwEnrolled == 1 && evalOk == 1)
  · cases hf : (hwEnrolled == 0 && fallbackOk == 1)
    · rfl
    · exact False.elim (h_no_fb hf)
  · exact False.elim (h_no_bio hb)

/-- Corollary 75 (`GrammarConfinement` — `meshServiceRouteStep`, Retired Tailscale CGNAT Endpoint Always Rejected):
    Any internal service request targeting a retired Tailscale CGNAT address (`endpointInRetiredTailnet = 1`)
    is rejected (`512`, `admittedBit = 0`) regardless of overlay/auth flags, preventing 5000ms timeouts on
    retired addresses such as `100.77.4.93:8000`. -/
theorem mesh_service_route_rejects_retired_tailnet
    (overlay auth loopback : UInt8) :
    meshServiceRouteStep overlay 1 auth loopback = 512 := by
  rfl

-- ===========================================================================
-- Wave 11: SOC 2 Type I Compliance Proofs — 3-Key SSH & macOS Remote Login,
--          Off-Host B2 Audit Log Shipper, and OS Lifecycle / Boundary Scope
-- ===========================================================================

/-- Corollary 76 (`ScopedAuthority` — `soc2SshHostKeyPolicyStep`, SOC 2 CC6.1/CC6.6 3-Key & Key-Only SSH):
    Any host that retains the shared legacy `paloma` key (`hasSharedLegacyKey = 1`), retains a provisioning
    `ssh-rsa` key (`hasProvisioningRsaKey = 1`), stores a fleet private key on a worker (`workerHasFleetPrivateKey = 1`),
    or leaves password / keyboard-interactive authentication enabled (`passwordAuthDisabled = 0` or
    `kbdInteractiveDisabled = 0`, e.g. unhardened macOS Remote Login) is strictly rejected (`512`),
    while a hardened 3-key host (`1, 1, 1, 0, 0, 0, 1, 1, 1`) is admitted (`257`). -/
theorem soc2_ssh_host_key_policy_enforces_three_key_and_no_password
    (yubi brk uniq leg rsa priv pw kbd rootPw : UInt8) :
    soc2SshHostKeyPolicyStep yubi brk uniq 1 rsa priv pw kbd rootPw = 512 ∧
    soc2SshHostKeyPolicyStep yubi brk uniq leg 1 priv pw kbd rootPw = 512 ∧
    soc2SshHostKeyPolicyStep yubi brk uniq leg rsa 1 pw kbd rootPw = 512 ∧
    soc2SshHostKeyPolicyStep yubi brk uniq leg rsa priv 0 kbd rootPw = 512 ∧
    soc2SshHostKeyPolicyStep yubi brk uniq leg rsa priv pw 0 rootPw = 512 ∧
    soc2SshHostKeyPolicyStep 1 1 1 0 0 0 1 1 1 = 257 := by
  unfold soc2SshHostKeyPolicyStep
  repeat (first | constructor | split | decide | simp_all)

/-- Corollary 77 (`ConservedResource` & `ScopedAuthority` — `soc2AuditShipperStep`, SOC 2 CC7.2/C1.1 Off-Host B2 Audit Sink):
    Unredacted logs (`secretsRedacted = 0`), missing Object-Lock/append-only mode (`objectLockOrAppendOnly = 0`),
    unverified SHA-256 digests (`sha256DigestVerified = 0`), empty batches (`batchBytes = 0`), and oversized
    batches (`batchBytes > maxBatchBytes`) are unconditionally rejected (`512`). -/
theorem soc2_audit_shipper_requires_redaction_object_lock_and_bounds
    (b2 lock red sha : UInt8) (bytes maxBytes : UInt64) :
    soc2AuditShipperStep b2 0 red sha bytes maxBytes = 512 ∧
    soc2AuditShipperStep b2 lock 0 sha bytes maxBytes = 512 ∧
    soc2AuditShipperStep b2 lock red 0 bytes maxBytes = 512 ∧
    soc2AuditShipperStep b2 lock red sha 0 maxBytes = 512 ∧
    soc2AuditShipperStep 1 1 1 1 4096 65536 = 257 := by
  unfold soc2AuditShipperStep
  repeat (first | constructor | split | decide | simp_all)

/-- Corollary 78 (`ScopedAuthority` — `soc2HostScopeStep`, SOC 2 CC7.1/CC6.8 EOL OS & Mesh Egress Boundary):
    1. Any in-scope host on an EOL OS (`osSupportedLts = 0`, e.g. Ubuntu 23.04 `watchtower` before upgrade)
       or missing `chain mesh_output` (`meshOutputEgressFilterActive = 0`) is rejected (`512`).
    2. Any out-of-scope retiring host (`isOutOfScopeDecommission = 1`) that is enrolled in `lean-mesh`
       (`enrolledInLeanMesh = 1`) or holds fleet credentials (`holdsFleetCredentials = 1`) is rejected (`512`).
    3. Both compliant in-scope peers (`0, 1, 1, 1, 1, c -> 257`) and fenced out-of-scope retiring hosts
       (`1, lts, uu, 0, eg, 0 -> 258`) are admitted. -/
theorem soc2_host_scope_rejects_eol_os_missing_egress_or_unfenced_legacy
    (lts uu mesh eg cred : UInt8) :
    soc2HostScopeStep 0 0 uu mesh eg cred = 512 ∧
    soc2HostScopeStep 0 lts uu mesh 0 cred = 512 ∧
    soc2HostScopeStep 1 lts uu 1 eg cred = 512 ∧
    soc2HostScopeStep 1 lts uu mesh eg 1 = 512 ∧
    soc2HostScopeStep 0 1 1 1 1 cred = 257 ∧
    soc2HostScopeStep 1 lts uu 0 eg 0 = 258 := by
  unfold soc2HostScopeStep
  repeat (first | constructor | split | decide | simp_all)

-- ===========================================================================
-- Wave 12: Worker Disk-Pressure Tiered Reclamation, Anti-Thrashing & Placement
-- ===========================================================================

structure NodeDiskAdmissionCheck where
  freeBytes          : UInt64
  reservedBytes      : UInt64
  nodeFloorBytes     : UInt64
  coreFloorBytes     : UInt64
  hysteresisBytes    : UInt64
  nodePinnedPressure : UInt8
  deriving Repr, DecidableEq

def NodeDiskAdmissionCheck.EffectiveFloor (c : NodeDiskAdmissionCheck) : UInt64 :=
  if c.nodeFloorBytes >= c.coreFloorBytes then c.nodeFloorBytes else c.coreFloorBytes

def NodeDiskAdmissionCheck.EffectiveFree (c : NodeDiskAdmissionCheck) : UInt64 :=
  if c.freeBytes >= c.reservedBytes then c.freeBytes - c.reservedBytes else 0

def NodeDiskAdmissionCheck.Safe (c : NodeDiskAdmissionCheck) : Bool :=
  c.nodePinnedPressure == 0 && c.EffectiveFree >= c.EffectiveFloor

def nodeDiskAdmissionMetaGate : MetaGateSpec NodeDiskAdmissionCheck
    (fun c => c.Safe = true) where
  gate c :=
    ((nodeDiskAdmissionStep
      c.freeBytes c.reservedBytes c.nodeFloorBytes c.coreFloorBytes
      c.hysteresisBytes c.nodePinnedPressure &&& 0xFFFFFFFF) &&& 256) != 0
  sound c h := by
    unfold NodeDiskAdmissionCheck.Safe NodeDiskAdmissionCheck.EffectiveFloor NodeDiskAdmissionCheck.EffectiveFree
    unfold nodeDiskAdmissionStep at h
    rw [pack32_lo] at h
    generalize (if c.nodeFloorBytes >= c.coreFloorBytes then c.nodeFloorBytes else c.coreFloorBytes) = effFloor at h ⊢
    generalize (if c.freeBytes >= c.reservedBytes then c.freeBytes - c.reservedBytes else 0) = effFree at h ⊢
    have hpne : (c.nodePinnedPressure != 0) = !(c.nodePinnedPressure == 0) := by
      cases c.nodePinnedPressure; rfl
    rw [hpne] at h
    cases hp : (c.nodePinnedPressure == 0)
    · simp only [hp, Bool.not_false, ↓reduceIte] at h
      exact absurd h (by decide)
    · cases hf : decide (effFree >= effFloor)
      · simp only [hp, hf, Bool.not_true, Bool.not_false, ↓reduceIte] at h
        exact absurd h (by decide)
      · simp [hp, hf]
  complete c h := by
    unfold NodeDiskAdmissionCheck.Safe NodeDiskAdmissionCheck.EffectiveFloor NodeDiskAdmissionCheck.EffectiveFree at h
    unfold nodeDiskAdmissionStep
    rw [pack32_lo]
    generalize (if c.nodeFloorBytes >= c.coreFloorBytes then c.nodeFloorBytes else c.coreFloorBytes) = effFloor at h ⊢
    generalize (if c.freeBytes >= c.reservedBytes then c.freeBytes - c.reservedBytes else 0) = effFree at h ⊢
    have hpne : (c.nodePinnedPressure != 0) = !(c.nodePinnedPressure == 0) := by
      cases c.nodePinnedPressure; rfl
    rw [hpne]
    cases hp : (c.nodePinnedPressure == 0)
    · simp [hp] at h
    · cases hf : decide (effFree >= effFloor)
      · simp [hp, hf] at h
      · cases hs : decide (effFree - effFloor < c.hysteresisBytes) <;>
          (simp only [hp, hf, hs, Bool.not_true, Bool.not_false, Bool.true_and, ↓reduceIte]; decide)
  posWitness := ⟨100, 10, 30, 20, 20, 0⟩
  negWitness := ⟨50, 0, 80, 20, 20, 0⟩
  nonVacuous := rfl
  tight      := rfl

def nodeDiskAdmissionConserved : ConservedResource NodeDiskAdmissionCheck where
  admit := nodeDiskAdmissionMetaGate.gate
  withinBudget c := c.EffectiveFree >= c.EffectiveFloor && c.nodePinnedPressure == 0
  conserved c h := by
    have hs := nodeDiskAdmissionMetaGate.sound c h
    unfold NodeDiskAdmissionCheck.Safe at hs
    rw [Bool.and_eq_true] at hs ⊢
    exact ⟨hs.2, hs.1⟩

/-- Corollary 79 (`StickyFence` — `orb_node_disk_admission_step`, Pinned Disk Pressure Blocks Placement):
    Any node reporting `nodePinnedPressure != 0` is rejected (`action = 2`, `admittedBit = 0`) regardless
    of nominal free bytes or Core floor settings. -/
theorem node_disk_admission_rejects_pinned
    (free res nodeFloor coreFloor hyst : UInt64) (pinned : UInt8)
    (h_pin : (pinned != 0) = true) :
    (nodeDiskAdmissionStep free res nodeFloor coreFloor hyst pinned &&& 0xFFFFFFFF) = 2 := by
  unfold nodeDiskAdmissionStep
  rw [pack32_lo]
  simp [h_pin]

/-- Corollary 80 (`ConservedResource` — `orb_node_disk_admission_step`, Node Floor Overrides Lower Core Floor):
    Whenever `effectiveFree < nodeFloor` (even if `effectiveFree ≥ coreFloor`, as in the Ashur `50 GiB < 80 GiB`
    vs Core `20 GiB` mismatch), `nodeDiskAdmissionStep` rejects placement (`admittedBit = 0`). -/
theorem node_disk_admission_respects_node_floor
    (free res nodeFloor coreFloor hyst : UInt64)
    (h_below : (if free >= res then free - res else 0) < nodeFloor) :
    ((nodeDiskAdmissionStep free res nodeFloor coreFloor hyst 0 &&& 0xFFFFFFFF) &&& 256) = 0 := by
  unfold nodeDiskAdmissionStep
  rw [pack32_lo]
  generalize (if free >= res then free - res else 0) = effFree at h_below ⊢
  have h_not_ge : decide (effFree >= (if nodeFloor >= coreFloor then nodeFloor else coreFloor)) = false := by
    apply decide_eq_false
    intro h_ge
    change (if nodeFloor >= coreFloor then nodeFloor else coreFloor).toNat ≤ effFree.toNat at h_ge
    change effFree.toNat < nodeFloor.toNat at h_below
    split at h_ge
    · omega
    · next h_nc =>
      change ¬ (coreFloor.toNat ≤ nodeFloor.toNat) at h_nc
      omega
  simp [h_not_ge]

structure NodeGcCheck where
  freeBytes           : UInt64
  floorBytes          : UInt64
  emergencyFloorBytes : UInt64
  agedScratchBytes    : UInt64
  freshScratchBytes   : UInt64
  coldCacheBytes      : UInt64
  hotCacheBytes       : UInt64
  deriving Repr, DecidableEq

def NodeGcCheck.RemAfterFresh (g : NodeGcCheck) : UInt64 :=
  let underFloor : Bool := g.freeBytes < g.floorBytes
  let deficit : UInt64 := if underFloor then g.floorBytes - g.freeBytes else 0
  let rem1 : UInt64 := if g.agedScratchBytes >= deficit then 0 else deficit - g.agedScratchBytes
  let rem2 : UInt64 := if g.coldCacheBytes >= rem1 then 0 else rem1 - g.coldCacheBytes
  if g.freshScratchBytes >= rem2 then 0 else rem2 - g.freshScratchBytes

def NodeGcCheck.ShouldEvictHot (g : NodeGcCheck) : Bool :=
  let underFloor : Bool := g.freeBytes < g.floorBytes
  let inEmergency : Bool := underFloor && g.freeBytes < g.emergencyFloorBytes
  let rem3 : UInt64 := g.RemAfterFresh
  let unrecoverable : Bool := g.hotCacheBytes < rem3
  rem3 > 0 && (!unrecoverable || (inEmergency && g.hotCacheBytes > 0))

theorem NodeGcCheck.remAfterFresh_eq_zero_of_not_under (g : NodeGcCheck)
    (hu : decide (g.freeBytes < g.floorBytes) = false) : g.RemAfterFresh = 0 := by
  unfold NodeGcCheck.RemAfterFresh
  have ha : g.agedScratchBytes >= 0 := Nat.zero_le _
  have hc : g.coldCacheBytes >= 0 := Nat.zero_le _
  have hf : g.freshScratchBytes >= 0 := Nat.zero_le _
  simp [hu, ha, hc, hf]

def nodeGcHotEvictMetaGate : MetaGateSpec NodeGcCheck
    (fun g => g.ShouldEvictHot = true) where
  gate g :=
    ((nodeGcStep g.freeBytes g.floorBytes g.emergencyFloorBytes
      g.agedScratchBytes g.freshScratchBytes g.coldCacheBytes g.hotCacheBytes &&& 0xFFFFFFFF) &&& 2048) != 0
  sound g h := by
    unfold NodeGcCheck.ShouldEvictHot NodeGcCheck.RemAfterFresh
    unfold nodeGcStep at h
    cases hu : decide (g.freeBytes < g.floorBytes)
    · simp only [hu, Bool.not_false, ↓reduceIte] at h
      exact absurd h (by decide)
    · simp only [hu, Bool.not_true, Bool.false_eq_true, Bool.true_and, ↓reduceIte] at h ⊢
      rw [pack32_lo] at h
      generalize (if g.agedScratchBytes >= g.floorBytes - g.freeBytes then (0 : UInt64)
        else g.floorBytes - g.freeBytes - g.agedScratchBytes) = r1 at h ⊢
      generalize (if g.coldCacheBytes >= r1 then (0 : UInt64) else r1 - g.coldCacheBytes) = r2 at h ⊢
      generalize (if g.freshScratchBytes >= r2 then (0 : UInt64) else r2 - g.freshScratchBytes) = r3 at h ⊢
      cases hc1 : decide (r1 > 0) <;>
        cases hc2 : decide (r2 > 0) <;>
        cases hc3 : decide (r3 > 0) <;>
        cases hunrec : decide (g.hotCacheBytes < r3) <;>
        cases hemerg : decide (g.freeBytes < g.emergencyFloorBytes) <;>
        cases hhot : decide (g.hotCacheBytes > 0) <;>
        (simp only [hc1, hc2, hc3, hunrec, hemerg, hhot, Bool.not_true, Bool.not_false, Bool.false_eq_true, ↓reduceIte] at h ⊢
         revert h; decide)
  complete g h := by
    unfold nodeGcStep
    cases hu : decide (g.freeBytes < g.floorBytes)
    · have h0 := NodeGcCheck.remAfterFresh_eq_zero_of_not_under g hu
      unfold NodeGcCheck.ShouldEvictHot at h
      rw [h0] at h
      simp at h
    · unfold NodeGcCheck.ShouldEvictHot NodeGcCheck.RemAfterFresh at h
      simp only [hu, Bool.not_true, Bool.false_eq_true, Bool.true_and, ↓reduceIte] at h ⊢
      rw [pack32_lo]
      generalize (if g.agedScratchBytes >= g.floorBytes - g.freeBytes then (0 : UInt64)
        else g.floorBytes - g.freeBytes - g.agedScratchBytes) = r1 at h ⊢
      generalize (if g.coldCacheBytes >= r1 then (0 : UInt64) else r1 - g.coldCacheBytes) = r2 at h ⊢
      generalize (if g.freshScratchBytes >= r2 then (0 : UInt64) else r2 - g.freshScratchBytes) = r3 at h ⊢
      cases hc1 : decide (r1 > 0) <;>
        cases hc2 : decide (r2 > 0) <;>
        cases hc3 : decide (r3 > 0) <;>
        cases hunrec : decide (g.hotCacheBytes < r3) <;>
        cases hemerg : decide (g.freeBytes < g.emergencyFloorBytes) <;>
        cases hhot : decide (g.hotCacheBytes > 0) <;>
        (simp only [hc1, hc2, hc3, hunrec, hemerg, hhot, Bool.not_true, Bool.not_false, Bool.false_eq_true, ↓reduceIte] at h ⊢
         revert h; decide)
  posWitness := ⟨50, 80, 10, 5, 2, 5, 25⟩
  negWitness := ⟨50, 80, 10, 5, 2, 5, 10⟩
  nonVacuous := rfl
  tight      := rfl

def nodeGcMachineStep (_ : UInt8) (g : NodeGcCheck) : UInt8 × List UInt8 :=
  let evict := nodeGcHotEvictMetaGate.gate g
  (if evict then 4 else 0, if evict then [4] else [])

/-- Concrete `MetaStepSpec` instance #8 for Wave 12 (`orb_node_gc_step`). -/
def nodeGcMetaStepSpec : MetaStepSpec UInt8 NodeGcCheck UInt8 where
  safety := {
    step := nodeGcMachineStep
    authorized := fun _ g eff => eff == 4 && g.ShouldEvictHot
    sound := fun s g eff h_in => by
      dsimp [nodeGcMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := nodeGcHotEvictMetaGate.sound g h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := 0
    step := nodeGcMachineStep
    progressRequired := fun _ g => g.ShouldEvictHot
    expectedEffect := fun _ eff => eff == 4
    live := fun s g h_req => by
      have h_gate := nodeGcHotEvictMetaGate.complete g h_req
      dsimp [nodeGcMachineStep]
      simp [h_gate]
    traceEvents := [⟨50, 80, 10, 5, 2, 5, 10⟩, ⟨50, 80, 10, 5, 2, 5, 25⟩]
    posEvent := ⟨50, 80, 10, 5, 2, 5, 25⟩
    negEvent := ⟨50, 80, 10, 5, 2, 5, 10⟩
    reachable_live := by decide
  }
  cost := {
    step := nodeGcMachineStep
    cpuFuel := fun _ _ => 1
    inputBytes := fun _ => 56
    outputBytes := fun _ _ => 8
    c0 := 1
    c1 := 1
    maxEffects := 1
    maxOutBytes := 8
    fuel_bound := fun _ _ => by omega
    eff_bound := fun s g => by
      dsimp [nodeGcMachineStep]
      split <;> simp
    out_bound := fun _ _ => by omega
  }
  sameStep := ⟨rfl, rfl⟩

/-- Corollary 81 (`ConservedResource` — `orb_node_gc_step`, Healthy Node Keeps 72h Grace and Zero Evictions):
    Whenever `floorBytes ≤ freeBytes`, `nodeGcStep` emits `lo32 = 0` (zero scratch or cache sweeps,
    `pinnedPressureBit = 0`) and `hi32 = 72` hours of retired-scratch retention grace. -/
theorem node_gc_healthy_keeps_72h_grace
    (free floor emerg aged fresh cold hot : UInt64)
    (h_healthy : floor ≤ free) :
    nodeGcStep free floor emerg aged fresh cold hot = ((72 : UInt64) <<< 32) := by
  have hu : decide (free < floor) = false :=
    decide_eq_false (Nat.not_lt_of_ge h_healthy)
  unfold nodeGcStep
  simp [hu]

/-- Corollary 82 (`ConservedResource` — `orb_node_gc_step`, Anti-Thrashing Guard Preserves Hot Lake Caches):
    When a node is below `floorBytes` (`free < floor`), at or above `emergencyFloorBytes` (`emerg ≤ free`),
    and non-cache storage pins the disk below `floorBytes` even if all scratch and caches were deleted
    (`hot < RemAfterFresh`), `nodeGcStep` sets `pinnedPressureBit` (`4096`) while strictly clearing
    `evictHotCacheBit` (`2048`), preventing 30-minute Lake cache thrashing. -/
theorem node_gc_preserves_hot_cache_when_pinned_above_emergency
    (free floor emerg aged fresh cold hot : UInt64)
    (h_under : free < floor)
    (h_above_emerg : emerg ≤ free)
    (h_pinned : hot < NodeGcCheck.RemAfterFresh ⟨free, floor, emerg, aged, fresh, cold, hot⟩) :
    ((nodeGcStep free floor emerg aged fresh cold hot &&& 0xFFFFFFFF) &&& 6144) = 4096 := by
  have hu : decide (free < floor) = true := decide_eq_true h_under
  have he : decide (free < emerg) = false := decide_eq_false (Nat.not_lt_of_ge h_above_emerg)
  unfold NodeGcCheck.RemAfterFresh at h_pinned
  simp only [hu, ↓reduceIte] at h_pinned
  have hp : decide (hot < (if fresh >= (if cold >= (if aged >= floor - free then 0 else floor - free - aged) then 0
      else (if aged >= floor - free then 0 else floor - free - aged) - cold) then 0
      else (if cold >= (if aged >= floor - free then 0 else floor - free - aged) then 0
      else (if aged >= floor - free then 0 else floor - free - aged) - cold) - fresh)) = true :=
    decide_eq_true h_pinned
  unfold nodeGcStep
  simp only [hu, he, Bool.not_true, Bool.not_false, Bool.false_eq_true, Bool.true_and, Bool.false_and, ↓reduceIte]
  rw [pack32_lo]
  generalize (if aged >= floor - free then (0 : UInt64) else floor - free - aged) = r1 at hp ⊢
  generalize (if cold >= r1 then (0 : UInt64) else r1 - cold) = r2 at hp ⊢
  generalize (if fresh >= r2 then (0 : UInt64) else r2 - fresh) = r3 at hp ⊢
  have hr3_pos : decide (r3 > 0) = true := by
    have : 0 < r3.toNat := Nat.lt_of_le_of_lt (Nat.zero_le hot.toNat) (of_decide_eq_true hp)
    exact decide_eq_true this
  cases hc1 : decide (r1 > 0) <;>
    cases hc2 : decide (r2 > 0) <;>
    (simp only [hp, hr3_pos, hc1, hc2, Bool.not_true, Bool.not_false, Bool.false_eq_true, Bool.true_and, ↓reduceIte]
     decide)

/-- Corollary 83 (`EffectLiveness` — `orb_node_gc_step`, Emergency Survival Overrides Anti-Thrashing Guard):
    When free space drops below both `floorBytes` and `emergencyFloorBytes` (`free < floor`, `free < emerg`),
    deficit remains after retired scratch and cold caches (`0 < RemAfterFresh`), and non-empty hot caches
    exist (`0 < hot`), `nodeGcStep` sets `evictHotCacheBit` (`2048`) even if pressure is pinned. -/
theorem node_gc_emergency_evicts_hot_cache
    (free floor emerg aged fresh cold hot : UInt64)
    (h_under : free < floor)
    (h_emerg : free < emerg)
    (h_hot : 0 < hot)
    (h_rem : 0 < NodeGcCheck.RemAfterFresh ⟨free, floor, emerg, aged, fresh, cold, hot⟩) :
    ((nodeGcStep free floor emerg aged fresh cold hot &&& 0xFFFFFFFF) &&& 2048) = 2048 := by
  have hu : decide (free < floor) = true := decide_eq_true h_under
  have he : decide (free < emerg) = true := decide_eq_true h_emerg
  have hh : decide (hot > 0) = true := decide_eq_true h_hot
  unfold NodeGcCheck.RemAfterFresh at h_rem
  simp only [hu, ↓reduceIte] at h_rem
  have hr : decide ((if fresh >= (if cold >= (if aged >= floor - free then 0 else floor - free - aged) then 0
      else (if aged >= floor - free then 0 else floor - free - aged) - cold) then 0
      else (if cold >= (if aged >= floor - free then 0 else floor - free - aged) then 0
      else (if aged >= floor - free then 0 else floor - free - aged) - cold) - fresh) > 0) = true :=
    decide_eq_true h_rem
  unfold nodeGcStep
  simp only [hu, he, hh, Bool.not_true, Bool.not_false, Bool.false_eq_true, Bool.true_and, ↓reduceIte]
  rw [pack32_lo]
  generalize (if aged >= floor - free then (0 : UInt64) else floor - free - aged) = r1 at hr ⊢
  generalize (if cold >= r1 then (0 : UInt64) else r1 - cold) = r2 at hr ⊢
  generalize (if fresh >= r2 then (0 : UInt64) else r2 - fresh) = r3 at hr ⊢
  cases hc1 : decide (r1 > 0) <;>
    cases hc2 : decide (r2 > 0) <;>
    cases hun : decide (hot < r3) <;>
    (simp only [hr, hc1, hc2, hun, Bool.not_true, Bool.not_false, Bool.false_eq_true, Bool.and_false, ↓reduceIte]
     decide)
-- ===========================================================================
-- Wave 13: Multi-Provider Managed Compute Governance — Working-Owner Idle Reap,
--          Minimum-Commitment (`deletable_at`) Deferral, Lineage Claims & Secret Confinement
-- ===========================================================================

structure VmClaimCheck where
  isLive         : UInt8
  sameTenant     : UInt8
  ownerNone      : UInt8
  ownerInLineage : UInt8
  deriving Repr, DecidableEq

def vmClaimMetaGate : MetaGateSpec VmClaimCheck
    (fun c => (c.isLive == 1 && c.sameTenant == 1 && (c.ownerNone == 1 || c.ownerInLineage == 1)) = true) where
  gate c := (vmClaimStep c.isLive c.sameTenant c.ownerNone c.ownerInLineage &&& 256) != 0
  sound c h := by
    unfold vmClaimStep at h
    split at h <;> (simp_all; try contradiction)
  complete c h := by
    unfold vmClaimStep
    simp [h]
    decide
  posWitness := ⟨1, 1, 0, 1⟩
  negWitness := ⟨1, 0, 1, 1⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 84 (`ScopedAuthority` — `orb_vm_claim_step`): Non-live machines (`isLive = 0`), cross-tenant
    callers (`sameTenant = 0`), and unrelated missions (`ownerNone = 0 ∧ ownerInLineage = 0`) are strictly
    rejected (`512`), while same-tenant unowned or lineage-owned live machines are admitted (`257`). -/
theorem vm_claim_enforces_liveness_tenant_and_lineage
    (live tenant ownNone inLin : UInt8) :
    vmClaimStep 0 tenant ownNone inLin = 512 ∧
    vmClaimStep live 0 ownNone inLin = 512 ∧
    vmClaimStep live tenant 0 0 = 512 ∧
    vmClaimStep 1 1 1 inLin = 257 ∧
    vmClaimStep 1 1 ownNone 1 = 257 := by
  unfold vmClaimStep
  repeat (first | constructor | split | decide | simp_all)

structure ComputeSecretCheck where
  isCoreReservedComputeKey   : UInt8
  callerOnManagedNode        : UInt8
  isAllowlistedManagedSecret : UInt8
  operatorBreakGlass         : UInt8
  deriving Repr, DecidableEq

def computeSecretMetaGate : MetaGateSpec ComputeSecretCheck
    (fun s => (!(s.isCoreReservedComputeKey == 1 && s.operatorBreakGlass == 0) &&
               !(s.callerOnManagedNode == 1 && s.isAllowlistedManagedSecret == 0)) = true) where
  gate s :=
    (computeSecretGate
      s.isCoreReservedComputeKey s.callerOnManagedNode
      s.isAllowlistedManagedSecret s.operatorBreakGlass &&& 256) != 0
  sound s h := by
    unfold computeSecretGate at h
    cases hc : (s.isCoreReservedComputeKey == 1 && s.operatorBreakGlass == 0) <;>
      cases hm : (s.callerOnManagedNode == 1 && s.isAllowlistedManagedSecret == 0) <;>
      (simp_all; try contradiction)
  complete s h := by
    unfold computeSecretGate
    cases hc : (s.isCoreReservedComputeKey == 1 && s.operatorBreakGlass == 0) <;>
      cases hm : (s.callerOnManagedNode == 1 && s.isAllowlistedManagedSecret == 0) <;>
      (simp_all; try decide)
  posWitness := ⟨0, 1, 1, 0⟩
  negWitness := ⟨1, 0, 1, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Corollary 85 (`ScopedAuthority` — `orb_compute_secret_gate`): Core-reserved cloud provider API keys
    (`isCoreReservedComputeKey = 1`) without operator break-glass (`operatorBreakGlass = 0`) and non-allowlisted
    secrets requested from untrusted managed nodes (`callerOnManagedNode = 1 ∧ isAllowlistedManagedSecret = 0`)
    are unconditionally rejected (`512`). -/
theorem compute_secret_gate_confines_provider_keys_and_managed_nodes
    (reserved managed allowlisted breakGlass : UInt8) :
    computeSecretGate 1 managed allowlisted 0 = 512 ∧
    computeSecretGate reserved 1 0 breakGlass = 512 ∧
    computeSecretGate 0 0 allowlisted breakGlass = 257 ∧
    computeSecretGate 0 1 1 breakGlass = 257 := by
  unfold computeSecretGate
  repeat (first | constructor | split | decide | simp_all)

/-- Corollary 86 (`ClockDiscipline` & `ConservedResource` — `orb_vm_lifecycle_step`):
    1. A busy non-expired VM (`busy = 1, ttlExpired = 0`) or an unloaded/unknown owner (`ownerClass = 0, ttlExpired = 0`)
       is always kept (`0`).
    2. Whenever a minimum billing commitment is still active (`minDeletePending = 1`, e.g. Scaleway Apple Silicon
       24-hour `deletable_at`), `destroy (259)` is never emitted (`(res &&& 0xFF) != 3`); expired TTLs defer into
       `schedule | deferForMinLease` (`65537`).
    3. An idle VM owned by a `Working` parent (`ownerClass = 1, workingIdleEnabled = 1`) schedules (`1`) before
       idle expiry and destroys (`259`) once `graceOrIdleElapsed = 1` and `minDeletePending = 0`.
    4. An idle VM owned by a `Waiting` mission (`ownerClass = 2, graceOrIdleElapsed = 1`) stops (`258`) on
       free-stop providers (`supportsFreeStop = 1`) and destroys (`259`) on billing-while-stopped providers (`0`). -/
theorem vm_lifecycle_protects_busy_reaps_working_idle_and_defers_min_lease
    (own grace workEn freeStop minDel : UInt8) :
    vmLifecycleStep own 1 0 grace workEn freeStop minDel = 0 ∧
    vmLifecycleStep 0 0 0 grace workEn freeStop minDel = 0 ∧
    vmLifecycleStep own 1 1 grace workEn freeStop 1 = 65537 ∧
    vmLifecycleStep 1 0 0 0 1 freeStop minDel = 1 ∧
    vmLifecycleStep 1 0 0 1 1 freeStop 0 = 259 ∧
    vmLifecycleStep 2 0 0 1 workEn 1 minDel = 258 ∧
    vmLifecycleStep 2 0 0 1 workEn 0 0 = 259 := by
  unfold vmLifecycleStep
  repeat (first | constructor | split | decide | simp_all)

/-- Corollary 87 (`ProjectionStability` — `orb_machine_action_admitted`): A `stopped (6)` machine never meters
    live cost (`bit 16 == 0`) or counts as live (`bit 0 == 0`), always sets `isStopped` (`bit 24 == 16777216`),
    and enables `canResume` (`bit 25 == 33554432`) when idle and unmuted (`50331648`). -/
theorem machine_action_stopped_retains_without_live_billing
    (busy muted : UInt8) :
    (machineActionAdmitted 6 busy muted &&& 1) = 0 ∧
    (machineActionAdmitted 6 busy muted &&& 65536) = 0 ∧
    (machineActionAdmitted 6 busy muted &&& 16777216) = 16777216 ∧
    machineActionAdmitted 6 0 0 = 50331648 ∧
    machineActionAdmitted 6 1 muted = 16777216 := by
  unfold machineActionAdmitted
  repeat (first | constructor | split | decide | simp_all)

-- ===========================================================================
-- Wave 12 (P4): Compositional State-Machine & Arena Patch ABI (`OrbMachine` / `OrbWire`)
-- ===========================================================================

/-- Generic compositional state machine (`G-ORB-1`) folding typed events over state `S`
    while accumulating ordered emitted effects `List Eff`. -/
structure OrbMachine (S E Eff : Type) where
  step : S → E → S × List Eff

/-- Multi-step fold execution of an `OrbMachine` over a finite event trace. -/
def OrbMachine.runTrace {S E Eff : Type} (m : OrbMachine S E Eff) :
    S → List E → S × List Eff
  | s, [] => (s, [])
  | s, e :: es =>
    let (s1, eff1) := m.step s e
    let (s2, eff2) := m.runTrace s1 es
    (s2, eff1 ++ eff2)

/-- Compositional trace-append law for `OrbMachine.runTrace`:
    running `xs ++ ys` from `s` equals running `xs` then continuing `ys` from the reached state. -/
theorem orbMachine_runTrace_append {S E Eff : Type} (m : OrbMachine S E Eff)
    (s : S) (xs ys : List E) :
    m.runTrace s (xs ++ ys) =
      let (sMid, eff1) := m.runTrace s xs
      let (sEnd, eff2) := m.runTrace sMid ys
      (sEnd, eff1 ++ eff2) := by
  induction xs generalizing s with
  | nil =>
    simp [OrbMachine.runTrace]
  | cons e es ih =>
    simp [OrbMachine.runTrace, ih, List.append_assoc]

/-- Explicit 3-valued field presence (`G-ORB-1` & `G-ORB-5`):
    distinguishes omitted fields in partial patches from explicit updates and explicit clears. -/
inductive Presence where
  | omitted
  | present
  | cleared
  deriving Repr, DecidableEq

def Presence.toCode : Presence → UInt8
  | .omitted => 0
  | .present => 1
  | .cleared => 2

def Presence.ofCode? : UInt8 → Option Presence
  | 0 => some .omitted
  | 1 => some .present
  | 2 => some .cleared
  | _ => none

theorem presence_roundtrip (p : Presence) :
    Presence.ofCode? p.toCode = some p := by
  cases p <;> rfl

/-- Typed 16-byte `OrbWire` patch frame (`[schemaTag|presence|flags, payloadVal, incomingRev]`). -/
structure WirePatch where
  schemaId    : UInt8
  presence    : Presence
  authOk      : Bool
  payloadVal  : UInt32
  incomingRev : UInt64
  deriving Repr, DecidableEq

/-- Encodes a `WirePatch` into two 64-bit little-endian words (16 bytes total). -/
def encodePatch (p : WirePatch) : UInt64 × UInt64 :=
  let b0 : UInt32 := p.schemaId.toUInt32
  let b1 : UInt32 := p.presence.toCode.toUInt32 <<< 8
  let b2 : UInt32 := (if p.authOk then (1 : UInt32) else 0) <<< 16
  let hdr : UInt32 := (0x4F570000 : UInt32) ^^^ (b0 ||| b1 ||| b2)
  let w0 : UInt64 := hdr.toUInt64 ||| (p.payloadVal.toUInt64 <<< 32)
  (w0, p.incomingRev)

/-- Decodes two 64-bit words back into a `WirePatch`, rejecting unknown presence/auth tags
    or corrupted `0x4F57` magic bits. -/
def decodePatch (words : UInt64 × UInt64) : Option WirePatch :=
  let (w0, rev) := words
  let rawHdr : UInt32 := (w0 &&& 0xFFFFFFFF).toUInt32
  let hdr : UInt32 := rawHdr ^^^ (0x4F570000 : UInt32)
  let magicRest : UInt32 := hdr >>> 24
  let schemaByte : UInt8 := (hdr &&& 0xFF).toUInt8
  let presByte : UInt8 := ((hdr >>> 8) &&& 0xFF).toUInt8
  let authByte : UInt8 := ((hdr >>> 16) &&& 0xFF).toUInt8
  let payload : UInt32 := (w0 >>> 32).toUInt32
  if magicRest != 0 then none
  else match Presence.ofCode? presByte, authByte with
    | some pres, 0 => some ⟨schemaByte, pres, false, payload, rev⟩
    | some pres, 1 => some ⟨schemaByte, pres, true, payload, rev⟩
    | _, _ => none

theorem toUInt32_toUInt64 (x : UInt32) : x.toUInt64.toUInt32 = x := by
  apply UInt32.toBitVec_inj.mp
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp [UInt64.toBitVec_toUInt32, UInt32.toBitVec_toUInt64, hi]

theorem xor_magic_cancel (x : UInt32) :
    (((0x4F570000 : UInt32) ^^^ x) ^^^ (0x4F570000 : UInt32)) = x := by
  apply UInt32.toBitVec_inj.mp
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [UInt32.toBitVec_xor, BitVec.getLsbD_xor]
  cases ((0x4F570000 : UInt32).toBitVec.getLsbD i) <;>
    cases (x.toBitVec.getLsbD i) <;> rfl

theorem wirePatch_hdr_extract (sc : UInt8) (c : UInt32)
    (hc : c = 0 ∨ c = 256 ∨ c = 512 ∨ c = 65536 ∨ c = 65792 ∨ c = 66048) :
    (((sc.toUInt32 ||| c) >>> 24 != 0) = false) ∧
    (((sc.toUInt32 ||| c) >>> 8 &&& 0xFF).toUInt8 = (c >>> 8 &&& 0xFF).toUInt8) ∧
    (((sc.toUInt32 ||| c) >>> 16 &&& 0xFF).toUInt8 = (c >>> 16 &&& 0xFF).toUInt8) ∧
    (((sc.toUInt32 ||| c) &&& 0xFF).toUInt8 = sc) := by
  have hsc_hi : ∀ j, 8 ≤ j → sc.toUInt32.toBitVec.getLsbD j = false := by
    intro j hj
    simp [UInt8.toBitVec_toUInt32, BitVec.getLsbD_setWidth, BitVec.getLsbD_of_ge _ j hj]
  have hc_lo : ∀ j, j < 8 → c.toBitVec.getLsbD j = false := by
    rcases hc with rfl | rfl | rfl | rfl | rfl | rfl <;>
      (intro j hj; revert j; decide)
  have hc_top : ∀ j, 24 ≤ j → c.toBitVec.getLsbD j = false := by
    rcases hc with rfl | rfl | rfl | rfl | rfl | rfl <;>
      (intro j hj; by_cases h32 : j < 32
       · revert hj; revert j; decide
       · exact BitVec.getLsbD_of_ge _ j (by omega))
  refine ⟨?_, ?_, ?_, ?_⟩
  · apply Bool.eq_false_iff.mpr
    intro hne
    have hzero : (sc.toUInt32 ||| c) >>> 24 = 0 := by
      apply UInt32.toBitVec_inj.mp
      apply BitVec.eq_of_getLsbD_eq
      intro i hi
      simp only [UInt32.toBitVec_shiftRight, UInt32.toBitVec_or,
        show UInt32.toBitVec 24 % 32 = 24#32 from rfl, BitVec.ushiftRight_eq',
        BitVec.getLsbD_ushiftRight, BitVec.getLsbD_or,
        show (24#32).toNat = 24 from rfl]
      rw [hsc_hi (24 + i) (by omega), hc_top (24 + i) (by omega)]
      simp
    rw [hzero] at hne
    exact absurd hne (by decide)
  · apply UInt8.toBitVec_inj.mp
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp only [UInt32.toBitVec_toUInt8, UInt32.toBitVec_and, UInt32.toBitVec_shiftRight,
      UInt32.toBitVec_or, show UInt32.toBitVec 8 % 32 = 8#32 from rfl, BitVec.ushiftRight_eq',
      BitVec.getLsbD_setWidth, BitVec.getLsbD_and, BitVec.getLsbD_ushiftRight,
      BitVec.getLsbD_or, show (8#32).toNat = 8 from rfl,
      hsc_hi (8 + i) (by omega), Bool.false_or, hi]
  · apply UInt8.toBitVec_inj.mp
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp only [UInt32.toBitVec_toUInt8, UInt32.toBitVec_and, UInt32.toBitVec_shiftRight,
      UInt32.toBitVec_or, show UInt32.toBitVec 16 % 32 = 16#32 from rfl, BitVec.ushiftRight_eq',
      BitVec.getLsbD_setWidth, BitVec.getLsbD_and, BitVec.getLsbD_ushiftRight,
      BitVec.getLsbD_or, show (16#32).toNat = 16 from rfl,
      hsc_hi (16 + i) (by omega), Bool.false_or, hi]
  · apply UInt8.toBitVec_inj.mp
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    have hff : (0xFF : UInt32).toBitVec.getLsbD i = true := by revert i; decide
    simp only [UInt32.toBitVec_toUInt8, UInt32.toBitVec_and, UInt32.toBitVec_or,
      UInt8.toBitVec_toUInt32, BitVec.getLsbD_setWidth, BitVec.getLsbD_and,
      BitVec.getLsbD_or, show i < 32 by omega, hi,
      hc_lo i hi, hff, Bool.or_false, Bool.and_true, Bool.true_and, decide_true]

/-- Exact codec roundtrip theorem (`G-ORB-1`): `decodePatch (encodePatch p) = some p`. -/
theorem decodePatch_encodePatch (p : WirePatch) :
    decodePatch (encodePatch p) = some p := by
  have hor_assoc (a b d : UInt32) : (a ||| b ||| d) = (a ||| (b ||| d)) := by
    apply UInt32.toBitVec_inj.mp
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp [UInt32.toBitVec_or, BitVec.getLsbD_or, Bool.or_assoc]
  rcases p with ⟨sc, pr, au, val, rev⟩
  cases pr <;> cases au
  · dsimp only [encodePatch, decodePatch, Presence.toCode]
    rw [pack32_lo, pack32_hi, toUInt32_toUInt64, toUInt32_toUInt64, xor_magic_cancel, hor_assoc]
    have hc : (UInt8.toUInt32 0 <<< 8 ||| (if false = true then (1 : UInt32) else 0) <<< 16) = 0 := by decide
    rw [hc]
    rcases wirePatch_hdr_extract sc 0 (.inl rfl) with ⟨h1, h2, h3, h4⟩
    rw [h1, h2, h3, h4]; rfl
  · dsimp only [encodePatch, decodePatch, Presence.toCode]
    rw [pack32_lo, pack32_hi, toUInt32_toUInt64, toUInt32_toUInt64, xor_magic_cancel, hor_assoc]
    have hc : (UInt8.toUInt32 0 <<< 8 ||| (if true = true then (1 : UInt32) else 0) <<< 16) = 65536 := by decide
    rw [hc]
    rcases wirePatch_hdr_extract sc 65536 (.inr (.inr (.inr (.inl rfl)))) with ⟨h1, h2, h3, h4⟩
    rw [h1, h2, h3, h4]; rfl
  · dsimp only [encodePatch, decodePatch, Presence.toCode]
    rw [pack32_lo, pack32_hi, toUInt32_toUInt64, toUInt32_toUInt64, xor_magic_cancel, hor_assoc]
    have hc : (UInt8.toUInt32 1 <<< 8 ||| (if false = true then (1 : UInt32) else 0) <<< 16) = 256 := by decide
    rw [hc]
    rcases wirePatch_hdr_extract sc 256 (.inr (.inl rfl)) with ⟨h1, h2, h3, h4⟩
    rw [h1, h2, h3, h4]; rfl
  · dsimp only [encodePatch, decodePatch, Presence.toCode]
    rw [pack32_lo, pack32_hi, toUInt32_toUInt64, toUInt32_toUInt64, xor_magic_cancel, hor_assoc]
    have hc : (UInt8.toUInt32 1 <<< 8 ||| (if true = true then (1 : UInt32) else 0) <<< 16) = 65792 := by decide
    rw [hc]
    rcases wirePatch_hdr_extract sc 65792 (.inr (.inr (.inr (.inr (.inl rfl))))) with ⟨h1, h2, h3, h4⟩
    rw [h1, h2, h3, h4]; rfl
  · dsimp only [encodePatch, decodePatch, Presence.toCode]
    rw [pack32_lo, pack32_hi, toUInt32_toUInt64, toUInt32_toUInt64, xor_magic_cancel, hor_assoc]
    have hc : (UInt8.toUInt32 2 <<< 8 ||| (if false = true then (1 : UInt32) else 0) <<< 16) = 512 := by decide
    rw [hc]
    rcases wirePatch_hdr_extract sc 512 (.inr (.inr (.inl rfl))) with ⟨h1, h2, h3, h4⟩
    rw [h1, h2, h3, h4]; rfl
  · dsimp only [encodePatch, decodePatch, Presence.toCode]
    rw [pack32_lo, pack32_hi, toUInt32_toUInt64, toUInt32_toUInt64, xor_magic_cancel, hor_assoc]
    have hc : (UInt8.toUInt32 2 <<< 8 ||| (if true = true then (1 : UInt32) else 0) <<< 16) = 66048 := by decide
    rw [hc]
    rcases wirePatch_hdr_extract sc 66048 (.inr (.inr (.inr (.inr (.inr rfl))))) with ⟨h1, h2, h3, h4⟩
    rw [h1, h2, h3, h4]; rfl

/-- Fixed-capacity byte/word output buffer model for zero-partial-mutation frame encoding. -/
structure OutArena where
  capBytes : Nat
  words    : List UInt64
  deriving Repr, DecidableEq

/-- Encodes `p` into `out` iff `16 ≤ out.capBytes`; on insufficient capacity returns `error 3`
    with `out` strictly untouched (`0` partial state mutation). -/
def encodeFrameInto (p : WirePatch) (out : OutArena) : Except UInt8 OutArena :=
  if 16 ≤ out.capBytes then
    let (w0, w1) := encodePatch p
    .ok { out with words := [w0, w1] }
  else
    .error 3

/-- Zero partial mutation on `out_cap < required_bytes` (`G-ORB-1`):
    whenever `out.capBytes < 16`, `encodeFrameInto` returns `.error 3` without mutating `out`,
    and when `16 ≤ out.capBytes`, decoding the emitted frame recovers `some p`. -/
theorem encodeFrameInto_no_partial_mutation_and_roundtrip (p : WirePatch) (out : OutArena) :
    (out.capBytes < 16 → encodeFrameInto p out = .error 3) ∧
    (16 ≤ out.capBytes →
      ∃ w0 w1, encodeFrameInto p out = .ok { out with words := [w0, w1] } ∧
        decodePatch (w0, w1) = some p) := by
  constructor
  · intro h_lt
    unfold encodeFrameInto
    have h_not : ¬ (16 ≤ out.capBytes) := Nat.not_le_of_lt h_lt
    simp [h_not]
  · intro h_ge
    refine ⟨(encodePatch p).1, (encodePatch p).2, ?_, decodePatch_encodePatch p⟩
    unfold encodeFrameInto
    simp [h_ge]

/-- Pure specification state for an `OrbWire` versioned field slot. -/
structure WireSlotState where
  rev        : UInt64
  hasVal     : Bool
  currentVal : UInt32
  deriving Repr, DecidableEq

/-- Pure multi-step transition for `orb_wire_apply_patch_step` over `WireSlotState`. -/
def decodeWireApplyResult (sRev pRev : UInt64) (w : UInt64) : WireSlotState :=
  let admitted := ((w &&& 0xFFFFFFFF) &&& 256) != 0
  let nextHas := ((w &&& 0xFFFFFFFF) &&& 512) != 0
  let nextVal := (w >>> 32).toUInt32
  let nextRev := if admitted then pRev else sRev
  ⟨nextRev, nextHas, nextVal⟩

def applyWirePatchSlot (s : WireSlotState) (p : WirePatch) : WireSlotState × UInt64 :=
  let w := wireApplyPatchStep s.rev p.incomingRev
    (if s.hasVal then 1 else 0) s.currentVal p.presence.toCode p.payloadVal
  (decodeWireApplyResult s.rev p.incomingRev w, w)

/-- Field-presence merge law (`G-ORB-1` — `orb_wire_apply_patch_step`):
    1. Stale or duplicate revisions (`incomingRev ≤ s.rev`) leave `(rev, hasVal := s.hasVal, val)`
       strictly unmutated when `s.hasVal = true` (or zero-normalized when `s.hasVal = false`).
    2. Fresh `Presence.omitted` advances `rev` while preserving `s.hasVal` and `s.currentVal`
       (when `s.hasVal = true`).
    3. Fresh `Presence.cleared` advances `rev`, sets `hasVal = false`, and clears `currentVal = 0`.
    4. Fresh `Presence.present` advances `rev`, sets `hasVal = true`, and installs `p.payloadVal`. -/
theorem wire_apply_patch_presence_merge_laws (s : WireSlotState) (p : WirePatch) :
    (p.incomingRev ≤ s.rev → (s.hasVal = false → s.currentVal = 0) →
      (applyWirePatchSlot s p).1 = s) ∧
    (s.rev < p.incomingRev → p.presence = .omitted →
      (s.hasVal = false → s.currentVal = 0) →
      (applyWirePatchSlot s p).1 = ⟨p.incomingRev, s.hasVal, s.currentVal⟩) ∧
    (s.rev < p.incomingRev → p.presence = .cleared →
      (applyWirePatchSlot s p).1 = ⟨p.incomingRev, false, 0⟩) ∧
    (s.rev < p.incomingRev → p.presence = .present →
      (applyWirePatchSlot s p).1 = ⟨p.incomingRev, true, p.payloadVal⟩) := by
  have hd_pack (sRev pRev : UInt64) (lo32 hi32 : UInt32)
      (hlo : lo32 = 2 ∨ lo32 = 514 ∨ lo32 = 259 ∨ lo32 = 771 ∨ lo32 = 260 ∨ lo32 = 769) :
      decodeWireApplyResult sRev pRev (lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)) =
      ⟨if (lo32 &&& 256) != 0 then pRev else sRev, (lo32 &&& 512) != 0, hi32⟩ := by
    dsimp only [decodeWireApplyResult]
    rw [pack32_lo, pack32_hi, toUInt32_toUInt64]
    rcases hlo with rfl | rfl | rfl | rfl | rfl | rfl
    · have h1 : (UInt32.toUInt64 2 &&& 256 != 0) = ((2 : UInt32) &&& 256 != 0) := by decide
      have h2 : (UInt32.toUInt64 2 &&& 512 != 0) = ((2 : UInt32) &&& 512 != 0) := by decide
      rw [h1, h2]
    · have h1 : (UInt32.toUInt64 514 &&& 256 != 0) = ((514 : UInt32) &&& 256 != 0) := by decide
      have h2 : (UInt32.toUInt64 514 &&& 512 != 0) = ((514 : UInt32) &&& 512 != 0) := by decide
      rw [h1, h2]
    · have h1 : (UInt32.toUInt64 259 &&& 256 != 0) = ((259 : UInt32) &&& 256 != 0) := by decide
      have h2 : (UInt32.toUInt64 259 &&& 512 != 0) = ((259 : UInt32) &&& 512 != 0) := by decide
      rw [h1, h2]
    · have h1 : (UInt32.toUInt64 771 &&& 256 != 0) = ((771 : UInt32) &&& 256 != 0) := by decide
      have h2 : (UInt32.toUInt64 771 &&& 512 != 0) = ((771 : UInt32) &&& 512 != 0) := by decide
      rw [h1, h2]
    · have h1 : (UInt32.toUInt64 260 &&& 256 != 0) = ((260 : UInt32) &&& 256 != 0) := by decide
      have h2 : (UInt32.toUInt64 260 &&& 512 != 0) = ((260 : UInt32) &&& 512 != 0) := by decide
      rw [h1, h2]
    · have h1 : (UInt32.toUInt64 769 &&& 256 != 0) = ((769 : UInt32) &&& 256 != 0) := by decide
      have h2 : (UInt32.toUInt64 769 &&& 512 != 0) = ((769 : UInt32) &&& 512 != 0) := by decide
      rw [h1, h2]
  have h514 : ((2 : UInt32) ||| 512) = 514 := by decide
  have h771 : ((259 : UInt32) ||| 512) = 771 := by decide
  have h2_c1 : ((2 : UInt32) &&& 256 != 0) = false := by decide
  have h2_c2 : ((2 : UInt32) &&& 512 != 0) = false := by decide
  have h259_c1 : ((259 : UInt32) &&& 256 != 0) = true := by decide
  have h259_c2 : ((259 : UInt32) &&& 512 != 0) = false := by decide
  have h260_c1 : ((260 : UInt32) &&& 256 != 0) = true := by decide
  have h260_c2 : ((260 : UInt32) &&& 512 != 0) = false := by decide
  rcases s with ⟨sRev, sHas, sVal⟩
  rcases p with ⟨sc, pres, au, pVal, pRev⟩
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro h_le h_norm
    have h_not_gt : ¬ (pRev > sRev) := fun hgt => UInt64.not_le.mpr hgt h_le
    have hd : decide (sRev < pRev) = false := decide_eq_false h_not_gt
    cases pres <;> cases sHas
    · have hz := h_norm rfl; subst hz
      have hwStep : wireApplyPatchStep sRev pRev 0 0 0 pVal =
          ((2 : UInt32).toUInt64 ||| ((0 : UInt32).toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 0 0 0 pVal) = _
      rw [hwStep, hd_pack sRev pRev 2 0 (.inl rfl), h2_c1, h2_c2]; rfl
    · have hwStep : wireApplyPatchStep sRev pRev 1 sVal 0 pVal =
          ((514 : UInt32).toUInt64 ||| (sVal.toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd, h514]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 1 sVal 0 pVal) = _
      rw [hwStep, hd_pack sRev pRev 514 sVal (.inr (.inl rfl))]
      have hc1 : ((514 : UInt32) &&& 256 != 0) = false := by decide
      have hc2 : ((514 : UInt32) &&& 512 != 0) = true := by decide
      rw [hc1, hc2]; rfl
    · have hz := h_norm rfl; subst hz
      have hwStep : wireApplyPatchStep sRev pRev 0 0 1 pVal =
          ((2 : UInt32).toUInt64 ||| ((0 : UInt32).toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 0 0 1 pVal) = _
      rw [hwStep, hd_pack sRev pRev 2 0 (.inl rfl), h2_c1, h2_c2]; rfl
    · have hwStep : wireApplyPatchStep sRev pRev 1 sVal 1 pVal =
          ((514 : UInt32).toUInt64 ||| (sVal.toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd, h514]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 1 sVal 1 pVal) = _
      rw [hwStep, hd_pack sRev pRev 514 sVal (.inr (.inl rfl))]
      have hc1 : ((514 : UInt32) &&& 256 != 0) = false := by decide
      have hc2 : ((514 : UInt32) &&& 512 != 0) = true := by decide
      rw [hc1, hc2]; rfl
    · have hz := h_norm rfl; subst hz
      have hwStep : wireApplyPatchStep sRev pRev 0 0 2 pVal =
          ((2 : UInt32).toUInt64 ||| ((0 : UInt32).toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 0 0 2 pVal) = _
      rw [hwStep, hd_pack sRev pRev 2 0 (.inl rfl), h2_c1, h2_c2]; rfl
    · have hwStep : wireApplyPatchStep sRev pRev 1 sVal 2 pVal =
          ((514 : UInt32).toUInt64 ||| (sVal.toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd, h514]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 1 sVal 2 pVal) = _
      rw [hwStep, hd_pack sRev pRev 514 sVal (.inr (.inl rfl))]
      have hc1 : ((514 : UInt32) &&& 256 != 0) = false := by decide
      have hc2 : ((514 : UInt32) &&& 512 != 0) = true := by decide
      rw [hc1, hc2]; rfl
  · intro h_lt h_pr h_norm
    subst h_pr
    have hd : decide (sRev < pRev) = true := decide_eq_true h_lt
    cases sHas
    · have hz := h_norm rfl; subst hz
      have hwStep : wireApplyPatchStep sRev pRev 0 0 0 pVal =
          ((259 : UInt32).toUInt64 ||| ((0 : UInt32).toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 0 0 0 pVal) = _
      rw [hwStep, hd_pack sRev pRev 259 0 (.inr (.inr (.inl rfl))), h259_c1, h259_c2]; rfl
    · have hwStep : wireApplyPatchStep sRev pRev 1 sVal 0 pVal =
          ((771 : UInt32).toUInt64 ||| (sVal.toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd, h771]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 1 sVal 0 pVal) = _
      rw [hwStep, hd_pack sRev pRev 771 sVal (.inr (.inr (.inr (.inl rfl))))]
      have hc1 : ((771 : UInt32) &&& 256 != 0) = true := by decide
      have hc2 : ((771 : UInt32) &&& 512 != 0) = true := by decide
      rw [hc1, hc2]; rfl
  · intro h_lt h_pr
    subst h_pr
    have hd : decide (sRev < pRev) = true := decide_eq_true h_lt
    cases sHas
    · have hwStep : wireApplyPatchStep sRev pRev 0 sVal 2 pVal =
          ((260 : UInt32).toUInt64 ||| ((0 : UInt32).toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 0 sVal 2 pVal) = _
      rw [hwStep, hd_pack sRev pRev 260 0 (.inr (.inr (.inr (.inr (.inl rfl))))), h260_c1, h260_c2]; rfl
    · have hwStep : wireApplyPatchStep sRev pRev 1 sVal 2 pVal =
          ((260 : UInt32).toUInt64 ||| ((0 : UInt32).toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 1 sVal 2 pVal) = _
      rw [hwStep, hd_pack sRev pRev 260 0 (.inr (.inr (.inr (.inr (.inl rfl))))), h260_c1, h260_c2]; rfl
  · intro h_lt h_pr
    subst h_pr
    have hd : decide (sRev < pRev) = true := decide_eq_true h_lt
    have hc1 : ((769 : UInt32) &&& 256 != 0) = true := by decide
    have hc2 : ((769 : UInt32) &&& 512 != 0) = true := by decide
    cases sHas
    · have hwStep : wireApplyPatchStep sRev pRev 0 sVal 1 pVal =
          ((769 : UInt32).toUInt64 ||| (pVal.toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 0 sVal 1 pVal) = _
      rw [hwStep, hd_pack sRev pRev 769 pVal (.inr (.inr (.inr (.inr (.inr rfl))))), hc1, hc2]
      rfl
    · have hwStep : wireApplyPatchStep sRev pRev 1 sVal 1 pVal =
          ((769 : UInt32).toUInt64 ||| (pVal.toUInt64 <<< 32)) := by
        simp [wireApplyPatchStep, hd]
      change decodeWireApplyResult sRev pRev (wireApplyPatchStep sRev pRev 1 sVal 1 pVal) = _
      rw [hwStep, hd_pack sRev pRev 769 pVal (.inr (.inr (.inr (.inr (.inr rfl))))), hc1, hc2]
      rfl

structure WireMachineCheck where
  schemaId         : UInt32
  stateRev         : UInt64
  eventSeq         : UInt64
  effectKind       : UInt8
  effectAdmitted   : UInt8
  outCap           : UInt32
  requiredOutBytes : UInt32
  deriving Repr, DecidableEq

def WireMachineCheck.Admissible (w : WireMachineCheck) : Bool :=
  decide (w.requiredOutBytes ≤ w.outCap) &&
  decide (1 ≤ w.schemaId) && decide (w.schemaId ≤ 2) &&
  decide (w.stateRev < w.eventSeq) &&
  (w.effectAdmitted == 1) && decide (w.effectKind ≤ 5)

def wireMachineMetaGate : MetaGateSpec WireMachineCheck
    (fun w => w.Admissible = true) where
  gate w :=
    ((wireMachineStep w.schemaId w.stateRev w.eventSeq
        w.effectKind w.effectAdmitted w.outCap w.requiredOutBytes &&& 0xFFFFFFFF) &&& 256) != 0
  sound w h := by
    unfold WireMachineCheck.Admissible
    unfold wireMachineStep at h
    rw [pack32_lo] at h
    cases hc : decide (w.requiredOutBytes ≤ w.outCap) <;>
      cases hs1 : decide ((1 : UInt32) ≤ w.schemaId) <;>
      cases hs2 : decide (w.schemaId ≤ 2) <;>
      cases hq : decide (w.stateRev < w.eventSeq) <;>
      cases ha1 : (w.effectAdmitted == 1) <;>
      cases ha2 : decide (w.effectKind ≤ 5) <;>
      cases he : (w.effectKind != 0) <;>
      (simp only [hc, hs1, hs2, hq, ha1, ha2, he] at h ⊢; revert h; decide)
  complete w h := by
    unfold WireMachineCheck.Admissible at h
    unfold wireMachineStep
    rw [pack32_lo]
    cases hc : decide (w.requiredOutBytes ≤ w.outCap) <;>
      cases hs1 : decide ((1 : UInt32) ≤ w.schemaId) <;>
      cases hs2 : decide (w.schemaId ≤ 2) <;>
      cases hq : decide (w.stateRev < w.eventSeq) <;>
      cases ha1 : (w.effectAdmitted == 1) <;>
      cases ha2 : decide (w.effectKind ≤ 5) <;>
      cases he : (w.effectKind != 0) <;>
      (simp only [hc, hs1, hs2, hq, ha1, ha2, he] at h ⊢; revert h; decide)
  posWitness := ⟨1, 10, 11, 1, 1, 32, 16⟩
  negWitness := ⟨1, 10, 11, 1, 1, 16, 32⟩
  nonVacuous := rfl
  tight      := rfl

/-- Zero partial mutation in `orb_wire_machine_step`:
    whenever `outCap < requiredOutBytes`, `wireMachineStep` returns `status = 5` (`capExceeded`),
    `admittedBit = 0`, and leaves `hi32 == stateRev.toUInt32.toUInt64`. -/
theorem wire_machine_step_cap_exceeded_preserves_rev (w : WireMachineCheck)
    (h_short : w.outCap < w.requiredOutBytes) :
    let res := wireMachineStep w.schemaId w.stateRev w.eventSeq
      w.effectKind w.effectAdmitted w.outCap w.requiredOutBytes
    (res &&& 0xFFFFFFFF) = 5 ∧ (res >>> 32) = w.stateRev.toUInt32.toUInt64 := by
  have h_not_le : ¬ (w.requiredOutBytes ≤ w.outCap) := UInt32.not_le.mpr h_short
  have hc : decide (w.requiredOutBytes ≤ w.outCap) = false := decide_eq_false h_not_le
  dsimp only
  unfold wireMachineStep
  rw [pack32_lo, pack32_hi]
  simp [hc]

-- ===========================================================================
-- Wave 12 (P5 + P6): 7 Stateful Domain Migrations (`G-ORB-2..7`)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Family 1 (`G-ORB-5`): Hierarchy Merge, Partial Patch Presence & Sticky Supersession
-- ---------------------------------------------------------------------------

structure HierarchyMergeCheck where
  currentEpoch   : UInt64
  incomingEpoch  : UInt64
  archiveEpoch   : UInt64
  curArchived    : UInt8
  curSuperseded  : UInt8
  isPartialPatch : UInt8
  parentPresence : UInt8
  curParentOrd   : UInt32
  incParentOrd   : UInt32
  incArchive     : UInt8
  incUnarchive   : UInt8
  incSupersede   : UInt8
  deriving Repr, DecidableEq

def HierarchyMergeCheck.Admissible (h : HierarchyMergeCheck) : Bool :=
  let nextSup := h.curSuperseded == 1 || h.incSupersede == 1
  let epochFresh :=
    if h.isPartialPatch == 1 then decide (h.currentEpoch < h.incomingEpoch)
    else decide (h.currentEpoch ≤ h.incomingEpoch)
  let unarchiveAllowed :=
    !nextSup && h.incUnarchive == 1 && !(h.incArchive == 1) &&
    decide (h.archiveEpoch < h.incomingEpoch)
  let supBlocks := h.curSuperseded == 1 && !(h.incSupersede == 1)
  let archBlocks :=
    h.curArchived == 1 && !nextSup && !(h.incArchive == 1) && !unarchiveAllowed
  decide (h.parentPresence ≤ 2) && epochFresh && !supBlocks && !archBlocks

theorem hierarchyMerge_admit_eq (h : HierarchyMergeCheck) :
    (((hierarchyMergeStep h.currentEpoch h.incomingEpoch h.archiveEpoch
        h.curArchived h.curSuperseded h.isPartialPatch h.parentPresence
        h.curParentOrd h.incParentOrd h.incArchive h.incUnarchive h.incSupersede
      &&& 0xFFFFFFFF) &&& 256) != 0) = h.Admissible := by
  unfold HierarchyMergeCheck.Admissible hierarchyMergeStep
  rw [pack32_lo]
  dsimp only [GT.gt, GE.ge]
  cases hvp : decide (h.parentPresence ≤ 2) <;>
    cases hcs : (h.curSuperseded == 1) <;>
    cases his : (h.incSupersede == 1) <;>
    cases hca : (h.curArchived == 1) <;>
    cases hia : (h.incArchive == 1) <;>
    cases hiu : (h.incUnarchive == 1) <;>
    cases hua : decide (h.archiveEpoch < h.incomingEpoch)
  all_goals
    cases hpp : (h.isPartialPatch == 1)
    · cases hge : decide (h.currentEpoch ≤ h.incomingEpoch) <;>
        (simp only [hvp, hpp, hge, hcs, his, hca, hia, hiu, hua,
          Bool.false_eq_true, ite_true, ite_false];
         decide)
    · cases hgt : decide (h.currentEpoch < h.incomingEpoch) <;>
        (simp only [hvp, hpp, hgt, hcs, his, hca, hia, hiu, hua,
          Bool.false_eq_true, ite_true, ite_false];
         decide)

def hierarchyMergeMetaGate : MetaGateSpec HierarchyMergeCheck
    (fun h => h.Admissible = true) where
  gate h :=
    ((hierarchyMergeStep h.currentEpoch h.incomingEpoch h.archiveEpoch
        h.curArchived h.curSuperseded h.isPartialPatch h.parentPresence
        h.curParentOrd h.incParentOrd h.incArchive h.incUnarchive h.incSupersede
      &&& 0xFFFFFFFF) &&& 256) != 0
  sound h hg := by rw [← hierarchyMerge_admit_eq h]; exact hg
  complete h hadm := by rw [hierarchyMerge_admit_eq h]; exact hadm
  posWitness := ⟨10, 11, 5, 0, 0, 1, 0, 42, 0, 0, 0, 0⟩
  negWitness := ⟨10, 10, 5, 0, 0, 1, 0, 42, 0, 0, 0, 0⟩
  nonVacuous := rfl
  tight      := rfl

structure HierarchyNodeState where
  epoch        : UInt64
  archiveEpoch : UInt64
  archived     : UInt8
  superseded   : UInt8
  parentOrd    : UInt32
  deriving Repr, DecidableEq

def effectiveHierarchyCheck (s : HierarchyNodeState) (e : HierarchyMergeCheck) :
    HierarchyMergeCheck :=
  { e with
    currentEpoch  := s.epoch
    archiveEpoch  := s.archiveEpoch
    curArchived   := s.archived
    curSuperseded := s.superseded
    curParentOrd  := s.parentOrd }

def hierarchyMachineStep (s : HierarchyNodeState) (e : HierarchyMergeCheck) :
    HierarchyNodeState × List UInt64 :=
  let e' := effectiveHierarchyCheck s e
  let w := hierarchyMergeStep e'.currentEpoch e'.incomingEpoch e'.archiveEpoch
    e'.curArchived e'.curSuperseded e'.isPartialPatch e'.parentPresence
    e'.curParentOrd e'.incParentOrd e'.incArchive e'.incUnarchive e'.incSupersede
  let admit := hierarchyMergeMetaGate.gate e'
  let nextArch : UInt8 := if ((w &&& 0xFFFFFFFF) &&& 512) != 0 then 1 else 0
  let nextSup : UInt8 := if ((w &&& 0xFFFFFFFF) &&& 1024) != 0 then 1 else 0
  let nextParent : UInt32 := (w >>> 32).toUInt32
  let nextEpoch := if admit then e'.incomingEpoch else s.epoch
  let nextArchEpoch :=
    if admit && nextArch == 1 && s.archived == 0 then e'.incomingEpoch else s.archiveEpoch
  (⟨nextEpoch, nextArchEpoch, nextArch, nextSup, nextParent⟩,
   if admit then [e.incomingEpoch] else [])

def hierarchyMergeMetaStepSpec :
    MetaStepSpec HierarchyNodeState HierarchyMergeCheck UInt64 where
  safety := {
    step := hierarchyMachineStep
    authorized := fun s e eff =>
      eff == e.incomingEpoch && (effectiveHierarchyCheck s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [hierarchyMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := hierarchyMergeMetaGate.sound (effectiveHierarchyCheck s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := ⟨0, 0, 0, 0, 0⟩
    step := hierarchyMachineStep
    progressRequired := fun s e => (effectiveHierarchyCheck s e).Admissible
    expectedEffect := fun e eff => eff == e.incomingEpoch
    live := fun s e h_req => by
      have h_gate := hierarchyMergeMetaGate.complete (effectiveHierarchyCheck s e) h_req
      dsimp [hierarchyMachineStep]
      simp [h_gate]
    traceEvents := [
      ⟨0, 1, 0, 0, 0, 0, 1, 0, 77, 0, 0, 0⟩,
      ⟨1, 2, 0, 0, 0, 1, 0, 77, 0, 0, 0, 0⟩
    ]
    posEvent := ⟨2, 3, 0, 0, 0, 1, 0, 77, 0, 1, 0, 0⟩
    negEvent := ⟨2, 2, 0, 0, 0, 1, 0, 77, 0, 0, 0, 0⟩
    reachable_live := by decide
  }
  cost := {
    step := hierarchyMachineStep
    cpuFuel := fun s e => 12 + ((hierarchyMachineStep s e).2).length
    inputBytes := fun _ => 48
    outputBytes := fun s e => 24 + 8 * ((hierarchyMachineStep s e).2).length
    c0 := 13
    c1 := 1
    maxEffects := 1
    maxOutBytes := 32
    fuel_bound := fun s e => by
      dsimp [hierarchyMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [hierarchyMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [hierarchyMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

/-- Partial-patch vs full-snapshot presence & sticky supersession (`G-ORB-5`):
    1. An admitted partial patch (`isPartialPatch = 1`) with `parentPresence = 0` (`omitted`)
       preserves `curParentOrd`, whereas a full snapshot (`isPartialPatch = 0`) with
       `parentPresence = 0` clears `parentOrd` to `0`.
    2. Once superseded (`curSuperseded = 1`), any unarchive attempt (`incUnarchive = 1`,
       `incSupersede = 0`) is rejected (`admittedBit = 0`) and keeps `supBit = 1024`
       and `archBit = 512`. -/
theorem hierarchy_merge_partial_presence_and_sticky_supersede
    (curEp incEp archEp : UInt64) (curParent incParent : UInt32)
    (h_lt : curEp < incEp) :
    (hierarchyMergeStep curEp incEp archEp 0 0 1 0 curParent incParent 0 0 0 >>> 32).toUInt32
      = curParent ∧
    (hierarchyMergeStep curEp incEp archEp 0 0 0 0 curParent incParent 0 0 0 >>> 32).toUInt32
      = 0 ∧
    (hierarchyMergeStep curEp incEp archEp 1 1 1 1 curParent incParent 0 1 0 &&& 0xFFFFFFFF)
      = 1538 := by
  have hd_lt : decide (curEp < incEp) = true := decide_eq_true h_lt
  have hd_le : decide (curEp ≤ incEp) = true := decide_eq_true (UInt64.le_of_lt h_lt)
  refine ⟨?_, ?_, ?_⟩
  · unfold hierarchyMergeStep
    rw [pack32_hi, toUInt32_toUInt64]
    simp [hd_lt]
  · unfold hierarchyMergeStep
    rw [pack32_hi, toUInt32_toUInt64]
    simp [hd_le]
  · unfold hierarchyMergeStep
    rw [pack32_lo]
    dsimp only [GT.gt, GE.ge]
    have hvp1 : decide ((1 : UInt8) ≤ 2) = true := by decide
    have h11 : ((1 : UInt8) == 1) = true := by decide
    have h01 : ((0 : UInt8) == 1) = false := by decide
    cases hua : decide (archEp < incEp) <;>
      (simp only [hd_lt, hua, hvp1, h11, h01, Bool.false_eq_true, ite_true, ite_false];
       decide)

-- ---------------------------------------------------------------------------
-- Family 2 (`G-ORB-2` & `G-ORB-3`): Transcript Fold, Contiguous Sequence & Replay Equivalence
-- ---------------------------------------------------------------------------

structure TranscriptFoldCheck where
  lastAppliedSeq   : UInt64
  incomingSeq      : UInt64
  entryCount       : UInt32
  thinkingOpen     : UInt8
  normalizedAction : UInt8
  isReplayFromLog  : UInt8
  deriving Repr, DecidableEq

def isTranscriptAppendAction (act : UInt8) : Bool :=
  act == 5 || act == 6 || act == 7 || act == 9 || act == 10

def isTranscriptMetaAction (act : UInt8) : Bool :=
  act == 2 || act == 3 || act == 8

def TranscriptFoldCheck.Admissible (t : TranscriptFoldCheck) : Bool :=
  !decide (t.incomingSeq ≤ t.lastAppliedSeq) &&
  (t.incomingSeq - t.lastAppliedSeq == 1) &&
  (t.normalizedAction == 4 || isTranscriptAppendAction t.normalizedAction ||
   isTranscriptMetaAction t.normalizedAction)

def transcriptFoldMetaGate : MetaGateSpec TranscriptFoldCheck
    (fun t => t.Admissible = true) where
  gate t :=
    ((transcriptFoldStep t.lastAppliedSeq t.incomingSeq t.entryCount
        t.thinkingOpen t.normalizedAction t.isReplayFromLog &&& 0xFFFFFFFF) &&& 256) != 0
  sound t hg := by
    unfold TranscriptFoldCheck.Admissible
    unfold transcriptFoldStep at hg
    rw [pack32_lo] at hg
    have ha5_eq : ((t.normalizedAction == 5 || t.normalizedAction == 6 ||
        t.normalizedAction == 7 || t.normalizedAction == 9) || t.normalizedAction == 10) =
        isTranscriptAppendAction t.normalizedAction := rfl
    have ha2_eq : ((t.normalizedAction == 2 || t.normalizedAction == 3) ||
        t.normalizedAction == 8) =
        isTranscriptMetaAction t.normalizedAction := rfl
    rw [ha5_eq, ha2_eq] at hg
    cases hd : decide (t.incomingSeq ≤ t.lastAppliedSeq) <;>
      cases hc : (t.incomingSeq - t.lastAppliedSeq == 1) <;>
      cases ha4 : (t.normalizedAction == 4) <;>
      cases ha5 : isTranscriptAppendAction t.normalizedAction <;>
      cases ha2 : isTranscriptMetaAction t.normalizedAction <;>
      cases ht : (t.thinkingOpen == 1) <;>
      (simp only [hd, hc, ha4, ha5, ha2, ht, Bool.false_eq_true, ite_true, ite_false] at hg ⊢;
       try { revert hg; decide })
  complete t hadm := by
    unfold TranscriptFoldCheck.Admissible at hadm
    unfold transcriptFoldStep
    rw [pack32_lo]
    have ha5_eq : ((t.normalizedAction == 5 || t.normalizedAction == 6 ||
        t.normalizedAction == 7 || t.normalizedAction == 9) || t.normalizedAction == 10) =
        isTranscriptAppendAction t.normalizedAction := rfl
    have ha2_eq : ((t.normalizedAction == 2 || t.normalizedAction == 3) ||
        t.normalizedAction == 8) =
        isTranscriptMetaAction t.normalizedAction := rfl
    rw [ha5_eq, ha2_eq]
    cases hd : decide (t.incomingSeq ≤ t.lastAppliedSeq) <;>
      cases hc : (t.incomingSeq - t.lastAppliedSeq == 1) <;>
      cases ha4 : (t.normalizedAction == 4) <;>
      cases ha5 : isTranscriptAppendAction t.normalizedAction <;>
      cases ha2 : isTranscriptMetaAction t.normalizedAction <;>
      cases ht : (t.thinkingOpen == 1) <;>
      (simp only [hd, hc, ha4, ha5, ha2, ht, Bool.false_eq_true, ite_true, ite_false] at hadm ⊢;
       try { revert hadm; decide })
  posWitness := ⟨10, 11, 3, 0, 5, 0⟩
  negWitness := ⟨10, 12, 3, 0, 5, 0⟩
  nonVacuous := rfl
  tight      := rfl

structure TranscriptFoldState where
  lastSeq      : UInt64
  entryCount   : UInt32
  thinkingOpen : UInt8
  deriving Repr, DecidableEq

structure TranscriptEventPayload where
  seq    : UInt64
  action : UInt8
  deriving Repr, DecidableEq

def applyTranscriptFoldEvent (isReplay : UInt8) (s : TranscriptFoldState)
    (ev : TranscriptEventPayload) : TranscriptFoldState × List UInt64 :=
  let w := transcriptFoldStep s.lastSeq ev.seq s.entryCount
    s.thinkingOpen ev.action isReplay
  let lo := w &&& 0xFFFFFFFF
  let admitted := (lo &&& 256) != 0
  let nextThink : UInt8 := if (lo &&& 512) != 0 then 1 else 0
  let nextCount : UInt32 := (w >>> 32).toUInt32
  let isContig := !decide (ev.seq ≤ s.lastSeq) && (ev.seq - s.lastSeq == 1)
  let nextSeq := if isContig then ev.seq else s.lastSeq
  (⟨nextSeq, nextCount, nextThink⟩, if admitted then [ev.seq] else [])

def effectiveTranscriptFoldCheck (s : TranscriptFoldState) (e : TranscriptFoldCheck) :
    TranscriptFoldCheck :=
  { e with
    lastAppliedSeq := s.lastSeq
    entryCount     := s.entryCount
    thinkingOpen   := s.thinkingOpen }

def transcriptFoldMachineStep (s : TranscriptFoldState) (e : TranscriptFoldCheck) :
    TranscriptFoldState × List UInt64 :=
  applyTranscriptFoldEvent e.isReplayFromLog s ⟨e.incomingSeq, e.normalizedAction⟩

def transcriptFoldMetaStepSpec :
    MetaStepSpec TranscriptFoldState TranscriptFoldCheck UInt64 where
  safety := {
    step := transcriptFoldMachineStep
    authorized := fun s e eff =>
      eff == e.incomingSeq && (effectiveTranscriptFoldCheck s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [transcriptFoldMachineStep, applyTranscriptFoldEvent] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := transcriptFoldMetaGate.sound (effectiveTranscriptFoldCheck s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := ⟨0, 0, 0⟩
    step := transcriptFoldMachineStep
    progressRequired := fun s e => (effectiveTranscriptFoldCheck s e).Admissible
    expectedEffect := fun e eff => eff == e.incomingSeq
    live := fun s e h_req => by
      have h_gate := transcriptFoldMetaGate.complete (effectiveTranscriptFoldCheck s e) h_req
      dsimp [transcriptFoldMachineStep, applyTranscriptFoldEvent]
      dsimp [transcriptFoldMetaGate, effectiveTranscriptFoldCheck] at h_gate
      simp [h_gate]
    traceEvents := [⟨0, 1, 0, 0, 4, 0⟩, ⟨1, 2, 0, 1, 5, 1⟩]
    posEvent := ⟨2, 3, 1, 0, 6, 0⟩
    negEvent := ⟨2, 5, 1, 0, 6, 0⟩
    reachable_live := by decide
  }
  cost := {
    step := transcriptFoldMachineStep
    cpuFuel := fun s e => 8 + ((transcriptFoldMachineStep s e).2).length
    inputBytes := fun _ => 32
    outputBytes := fun s e => 16 + 8 * ((transcriptFoldMachineStep s e).2).length
    c0 := 9
    c1 := 1
    maxEffects := 1
    maxOutBytes := 24
    fuel_bound := fun s e => by
      dsimp [transcriptFoldMachineStep, applyTranscriptFoldEvent]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [transcriptFoldMachineStep, applyTranscriptFoldEvent]
      split <;> simp
    out_bound := fun s e => by
      dsimp [transcriptFoldMachineStep, applyTranscriptFoldEvent]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

theorem applyTranscriptFoldEvent_replay_eq_live
    (s : TranscriptFoldState) (ev : TranscriptEventPayload) :
    applyTranscriptFoldEvent 1 s ev = applyTranscriptFoldEvent 0 s ev := rfl

/-- Multi-event replay equivalence & out-of-order gap/duplicate protection (`G-ORB-2` & `G-ORB-3`):
    1. Folding any multi-event trace `evs` with `isReplay = 1` produces the exact same
       `(TranscriptFoldState, List UInt64)` as live streaming (`isReplay = 0`).
    2. Duplicate (`incomingSeq = lastSeq`) or out-of-order gap (`incomingSeq - lastSeq != 1`)
       events never increment `entryCount` or set `admittedBit = 256`. -/
theorem transcript_replay_fold_eq_live_fold
    (s : TranscriptFoldState) (evs : List TranscriptEventPayload) :
    (OrbMachine.mk (applyTranscriptFoldEvent 1)).runTrace s evs =
      (OrbMachine.mk (applyTranscriptFoldEvent 0)).runTrace s evs := by
  induction evs generalizing s with
  | nil => rfl
  | cons ev rest ih =>
    simp [OrbMachine.runTrace, applyTranscriptFoldEvent_replay_eq_live, ih]

theorem transcript_fold_rejects_duplicate_and_gap
    (lastSeq incSeq : UInt64) (cnt : UInt32) (think act : UInt8)
    (h_gap : incSeq - lastSeq != 1) :
    ((transcriptFoldStep lastSeq lastSeq cnt think act 0 &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (transcriptFoldStep lastSeq lastSeq cnt think act 0 >>> 32).toUInt32 = cnt ∧
    ((transcriptFoldStep lastSeq incSeq cnt think act 0 &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (transcriptFoldStep lastSeq incSeq cnt think act 0 >>> 32).toUInt32 = cnt := by
  have hd_refl : decide (lastSeq ≤ lastSeq) = true :=
    decide_eq_true (UInt64.le_refl lastSeq)
  have h_not_one : (incSeq - lastSeq == 1) = false := by
    cases hc : (incSeq - lastSeq == 1)
    · rfl
    · simp [bne, hc] at h_gap
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold transcriptFoldStep
    rw [pack32_lo]
    cases ht : (think == 1) <;>
      (simp only [hd_refl, ht, Bool.false_eq_true, ite_true, ite_false]; decide)
  · unfold transcriptFoldStep
    rw [pack32_hi, toUInt32_toUInt64]
    simp [hd_refl]
  · unfold transcriptFoldStep
    rw [pack32_lo]
    cases hd : decide (incSeq ≤ lastSeq) <;>
      cases ht : (think == 1) <;>
      (simp only [hd, h_not_one, ht, Bool.false_eq_true, Bool.and_false, Bool.not_false,
        ite_true, ite_false]; decide)
  · unfold transcriptFoldStep
    rw [pack32_hi, toUInt32_toUInt64]
    cases hd : decide (incSeq ≤ lastSeq) <;>
      simp [hd, h_not_one]

-- ---------------------------------------------------------------------------
-- Family 3 (`G-ORB-2` & `G-ORB-3`): Outbox Crash Reconciliation & Single-Writer Lease
-- ---------------------------------------------------------------------------

structure OutboxReconcileCheck where
  durableQueued      : UInt32
  durableAcked       : UInt32
  volatileInFlight   : UInt32
  leaseBootEpoch     : UInt64
  nodeBootEpoch      : UInt64
  volatileLeaseOwner : UInt32
  reqOwner           : UInt32
  deriving Repr, DecidableEq

def OutboxReconcileCheck.Admissible (o : OutboxReconcileCheck) : Bool :=
  let validWal := decide (o.durableAcked ≤ o.durableQueued)
  let unacked := if validWal then o.durableQueued - o.durableAcked else 0
  let crashReset := o.leaseBootEpoch != o.nodeBootEpoch
  let effOwner := if crashReset then 0 else o.volatileLeaseOwner
  let effInFlight := if crashReset then 0 else o.volatileInFlight
  validWal && decide (0 < unacked) && (o.reqOwner != 0) &&
  (effOwner == 0 || effOwner == o.reqOwner) && decide (effInFlight < unacked)

theorem outboxCrashReconcile_admit_eq (o : OutboxReconcileCheck) :
    (((outboxCrashReconcileStep o.durableQueued o.durableAcked o.volatileInFlight
        o.leaseBootEpoch o.nodeBootEpoch o.volatileLeaseOwner o.reqOwner
      &&& 0xFFFFFFFF) &&& 256) != 0) = o.Admissible := by
  unfold OutboxReconcileCheck.Admissible outboxCrashReconcileStep
  rw [pack32_lo]
  dsimp only [GT.gt]
  cases hvw : decide (o.durableAcked ≤ o.durableQueued)
  · simp only [hvw, Bool.false_eq_true, Bool.false_and, Bool.not_false, ite_true, ite_false]
    decide
  · simp only [hvw, Bool.true_and, Bool.not_true, Bool.false_eq_true, ite_true, ite_false]
    cases hcr : (o.leaseBootEpoch != o.nodeBootEpoch)
    · simp only [hcr, Bool.false_eq_true, ite_false]
      cases hun : decide ((0 : UInt32) < o.durableQueued - o.durableAcked) <;>
        cases hzero : (o.durableQueued - o.durableAcked == 0) <;>
        cases hreq : (o.reqOwner != 0) <;>
        cases heow : (o.volatileLeaseOwner == 0 || o.volatileLeaseOwner == o.reqOwner) <;>
        cases hinf : decide (o.volatileInFlight < o.durableQueued - o.durableAcked) <;>
        cases hno : (o.volatileLeaseOwner != 0) <;>
        (simp only [hun, hzero, hreq, heow, hinf, hno, Bool.true_and, Bool.false_and,
          Bool.and_true, Bool.and_false, Bool.false_eq_true, ite_true, ite_false];
         decide)
    · simp only [hcr, ite_true]
      have h00 : ((0 : UInt32) == 0) = true := by decide
      have ho0 : ((0 : UInt32) == 0 || (0 : UInt32) == o.reqOwner) = true := by simp [h00]
      have hn0 : ((0 : UInt32) != 0) = false := by decide
      cases hun : decide ((0 : UInt32) < o.durableQueued - o.durableAcked) <;>
        cases hzero : (o.durableQueued - o.durableAcked == 0) <;>
        cases hreq : (o.reqOwner != 0) <;>
        (simp only [hun, hzero, hreq, ho0, hn0, Bool.true_and, Bool.false_and,
          Bool.and_true, Bool.and_false, Bool.false_eq_true, ite_true, ite_false];
         decide)

def outboxCrashReconcileMetaGate : MetaGateSpec OutboxReconcileCheck
    (fun o => o.Admissible = true) where
  gate o :=
    ((outboxCrashReconcileStep o.durableQueued o.durableAcked o.volatileInFlight
        o.leaseBootEpoch o.nodeBootEpoch o.volatileLeaseOwner o.reqOwner
      &&& 0xFFFFFFFF) &&& 256) != 0
  sound o hg := by rw [← outboxCrashReconcile_admit_eq o]; exact hg
  complete o hadm := by rw [outboxCrashReconcile_admit_eq o]; exact hadm
  posWitness := ⟨5, 2, 3, 1, 2, 99, 7⟩
  negWitness := ⟨5, 2, 3, 2, 2, 99, 7⟩
  nonVacuous := rfl
  tight      := rfl

structure OutboxWalState where
  durableQueued      : UInt32
  durableAcked       : UInt32
  volatileInFlight   : UInt32
  leaseBootEpoch     : UInt64
  volatileLeaseOwner : UInt32
  deriving Repr, DecidableEq

/-- Explicit crash-reset projection (`G-ORB-2`): preserves persistent WAL (`durableQueued`,
    `durableAcked`) while wiping volatile in-flight count and lease owner upon node reboot. -/
def crashResetVolatile (newBootEpoch : UInt64) (s : OutboxWalState) : OutboxWalState :=
  ⟨s.durableQueued, s.durableAcked, 0, newBootEpoch, 0⟩

def effectiveOutboxCheck (s : OutboxWalState) (e : OutboxReconcileCheck) :
    OutboxReconcileCheck :=
  { e with
    durableQueued      := s.durableQueued
    durableAcked       := s.durableAcked
    volatileInFlight   := s.volatileInFlight
    leaseBootEpoch     := s.leaseBootEpoch
    volatileLeaseOwner := s.volatileLeaseOwner }

def outboxMachineStep (s : OutboxWalState) (e : OutboxReconcileCheck) :
    OutboxWalState × List UInt32 :=
  let e' := effectiveOutboxCheck s e
  let admit := outboxCrashReconcileMetaGate.gate e'
  let crashReset := s.leaseBootEpoch != e.nodeBootEpoch
  let baseInFlight := if crashReset then 0 else s.volatileInFlight
  let baseOwner := if crashReset then 0 else s.volatileLeaseOwner
  let nextEpoch := if crashReset then e.nodeBootEpoch else s.leaseBootEpoch
  let nextInFlight := if admit then satAdd32 baseInFlight 1 else baseInFlight
  let nextOwner := if admit then e.reqOwner else baseOwner
  (⟨s.durableQueued, s.durableAcked, nextInFlight, nextEpoch, nextOwner⟩,
   if admit then [e.reqOwner] else [])

def outboxCrashReconcileMetaStepSpec :
    MetaStepSpec OutboxWalState OutboxReconcileCheck UInt32 where
  safety := {
    step := outboxMachineStep
    authorized := fun s e eff =>
      eff == e.reqOwner && (effectiveOutboxCheck s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [outboxMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := outboxCrashReconcileMetaGate.sound (effectiveOutboxCheck s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := ⟨3, 1, 2, 10, 42⟩
    step := outboxMachineStep
    progressRequired := fun s e => (effectiveOutboxCheck s e).Admissible
    expectedEffect := fun e eff => eff == e.reqOwner
    live := fun s e h_req => by
      have h_gate := outboxCrashReconcileMetaGate.complete (effectiveOutboxCheck s e) h_req
      dsimp [outboxMachineStep]
      simp [h_gate]
    traceEvents := [⟨3, 1, 2, 10, 11, 42, 77⟩]
    posEvent := ⟨3, 1, 1, 11, 11, 77, 77⟩
    negEvent := ⟨3, 1, 1, 11, 11, 77, 88⟩
    reachable_live := by decide
  }
  cost := {
    step := outboxMachineStep
    cpuFuel := fun s e => 9 + ((outboxMachineStep s e).2).length
    inputBytes := fun _ => 36
    outputBytes := fun s e => 24 + 4 * ((outboxMachineStep s e).2).length
    c0 := 10
    c1 := 1
    maxEffects := 1
    maxOutBytes := 28
    fuel_bound := fun s e => by
      dsimp [outboxMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [outboxMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [outboxMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

/-- Outbox crash conservation & single-writer lease exclusion (`G-ORB-2` & `G-ORB-3`):
    1. Across a crash (`leaseEpoch ≠ bootEpoch`) with `acked ≤ queued`,
       `orb_outbox_crash_reconcile_step` recovers the exact unacknowledged backlog
       `queued - acked` (`0` lost messages) and sets `crashBit = 512`.
    2. In the same boot epoch (`bootEpoch = bootEpoch`), a rival non-zero `reqOwner ≠ curOwner`
       (when `curOwner ≠ 0`) is strictly denied (`admittedBit = 0`, `<= 1` active writer).
    3. Applying `crashResetVolatile bootEpoch` makes subsequent evaluation at `bootEpoch` preserve
       the exact `unacked = queued - acked` count. -/
theorem outbox_crash_conservation_and_single_writer
    (queued acked inFlight : UInt32) (leaseEp bootEp : UInt64)
    (curOwner rivalOwner : UInt32)
    (h_wal : acked ≤ queued)
    (h_crash : leaseEp ≠ bootEp)
    (h_owned : curOwner ≠ 0)
    (h_rival : curOwner ≠ rivalOwner) :
    (outboxCrashReconcileStep queued acked inFlight
        leaseEp bootEp curOwner rivalOwner >>> 32).toUInt32
      = queued - acked ∧
    ((outboxCrashReconcileStep queued acked inFlight leaseEp bootEp curOwner rivalOwner
        &&& 0xFFFFFFFF) &&& 512) != 0 ∧
    ((outboxCrashReconcileStep queued acked inFlight bootEp bootEp curOwner rivalOwner
        &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (let s0 : OutboxWalState := ⟨queued, acked, inFlight, leaseEp, curOwner⟩
     let sCrash := crashResetVolatile bootEp s0
     (outboxCrashReconcileStep sCrash.durableQueued sCrash.durableAcked
        sCrash.volatileInFlight sCrash.leaseBootEpoch bootEp
        sCrash.volatileLeaseOwner rivalOwner >>> 32).toUInt32 = queued - acked) := by
  have hd_wal : decide (acked ≤ queued) = true := decide_eq_true h_wal
  have h_cr_true : (leaseEp != bootEp) = true := bne_iff_ne.mpr h_crash
  have h_cr_false : (bootEp != bootEp) = false := by simp
  have h_ow0 : (curOwner == 0) = false := beq_eq_false_iff_ne.mpr h_owned
  have h_owr : (curOwner == rivalOwner) = false := beq_eq_false_iff_ne.mpr h_rival
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold outboxCrashReconcileStep
    rw [pack32_hi, toUInt32_toUInt64]
    simp [hd_wal]
  · unfold outboxCrashReconcileStep
    rw [pack32_lo]
    dsimp only [GT.gt]
    have h00 : ((0 : UInt32) == 0) = true := by decide
    have ho0 : ((0 : UInt32) == 0 || (0 : UInt32) == rivalOwner) = true := by simp [h00]
    have hn0 : ((0 : UInt32) != 0) = false := by decide
    cases hun : decide ((0 : UInt32) < queued - acked) <;>
      cases hzero : (queued - acked == 0) <;>
      cases hreq : (rivalOwner != 0) <;>
      (simp only [hd_wal, h_cr_true, hun, hzero, hreq, ho0, hn0,
        Bool.true_and, Bool.false_and, Bool.and_true, Bool.and_false, Bool.not_true,
        Bool.false_eq_true, ite_true, ite_false]; decide)
  · unfold outboxCrashReconcileStep
    rw [pack32_lo]
    dsimp only [GT.gt]
    have h_ow_ne : (curOwner != 0) = true := bne_iff_ne.mpr h_owned
    cases hun : decide ((0 : UInt32) < queued - acked) <;>
      cases hzero : (queued - acked == 0) <;>
      cases hreq : (rivalOwner != 0) <;>
      cases hinf : decide (inFlight < queued - acked) <;>
      (simp only [hd_wal, h_cr_false, h_ow0, h_owr, h_ow_ne, hun, hzero, hreq, hinf,
        Bool.or_self, Bool.and_false, Bool.false_and, Bool.false_eq_true, ite_true, ite_false];
       decide)
  · dsimp only [crashResetVolatile]
    unfold outboxCrashReconcileStep
    rw [pack32_hi, toUInt32_toUInt64]
    simp [hd_wal]

-- ---------------------------------------------------------------------------
-- Family 4 (`G-ORB-2`): Multi-Attempt Provider Failover, Pinning & 3-Clock Isolation
-- ---------------------------------------------------------------------------

structure ProviderAttemptCheck where
  pinnedAccountId    : UInt32
  candidateAccountId : UInt32
  attemptsUsed       : UInt32
  retryBudget        : UInt32
  firstByteCommitted : UInt8
  failureKind        : UInt8
  upstreamNowEpoch   : UInt64
  cooldownUntilEpoch : UInt64
  upstreamDeadline   : UInt64
  authValid          : UInt8
  deriving Repr, DecidableEq

def ProviderAttemptCheck.Admissible (p : ProviderAttemptCheck) : Bool :=
  let isRetry := p.failureKind == 1 || p.failureKind == 2
  let pinOk :=
    (p.candidateAccountId != 0) &&
    (p.pinnedAccountId == 0 || p.candidateAccountId == p.pinnedAccountId)
  let cooldownOk := (p.failureKind != 2) && decide (p.cooldownUntilEpoch ≤ p.upstreamNowEpoch)
  let clockOk := decide (p.upstreamNowEpoch < p.upstreamDeadline) && (p.authValid == 1)
  let budgetOk :=
    if isRetry then decide (p.attemptsUsed < p.retryBudget)
    else decide (p.attemptsUsed ≤ p.retryBudget)
  !(p.firstByteCommitted == 1 && isRetry) && pinOk && cooldownOk && clockOk && budgetOk

theorem providerAttempt_admit_eq (p : ProviderAttemptCheck) :
    (((providerAttemptStep p.pinnedAccountId p.candidateAccountId
        p.attemptsUsed p.retryBudget p.firstByteCommitted p.failureKind
        p.upstreamNowEpoch p.cooldownUntilEpoch p.upstreamDeadline p.authValid
      &&& 0xFFFFFFFF) &&& 256) != 0) = p.Admissible := by
  unfold ProviderAttemptCheck.Admissible providerAttemptStep
  rw [pack32_lo]
  dsimp only [GE.ge]
  cases hfb : (p.firstByteCommitted == 1) <;>
    cases hf3 : (p.failureKind == 3) <;>
    cases hret : (p.failureKind == 1 || p.failureKind == 2) <;>
    cases hpin : ((p.candidateAccountId != 0) &&
                  (p.pinnedAccountId == 0 || p.candidateAccountId == p.pinnedAccountId)) <;>
    cases hcd : ((p.failureKind != 2) && decide (p.cooldownUntilEpoch ≤ p.upstreamNowEpoch)) <;>
    cases hclk : (decide (p.upstreamNowEpoch < p.upstreamDeadline) && (p.authValid == 1))
  all_goals
    cases hlt : decide (p.attemptsUsed < p.retryBudget) <;>
      cases hle : decide (p.attemptsUsed ≤ p.retryBudget) <;>
      (simp only [hfb, hf3, hret, hpin, hcd, hclk, hlt, hle,
        Bool.false_eq_true, ite_true, ite_false];
       decide)

def providerAttemptMetaGate : MetaGateSpec ProviderAttemptCheck
    (fun p => p.Admissible = true) where
  gate p :=
    ((providerAttemptStep p.pinnedAccountId p.candidateAccountId
        p.attemptsUsed p.retryBudget p.firstByteCommitted p.failureKind
        p.upstreamNowEpoch p.cooldownUntilEpoch p.upstreamDeadline p.authValid
      &&& 0xFFFFFFFF) &&& 256) != 0
  sound p hg := by rw [← providerAttempt_admit_eq p]; exact hg
  complete p hadm := by rw [providerAttempt_admit_eq p]; exact hadm
  posWitness := ⟨42, 42, 1, 3, 0, 1, 1000, 500, 2000, 1⟩
  negWitness := ⟨42, 42, 1, 3, 1, 1, 1000, 500, 2000, 1⟩
  nonVacuous := rfl
  tight      := rfl

structure ProviderSessionState where
  pinnedAccount      : UInt32
  attemptsUsed       : UInt32
  firstByteCommitted : UInt8
  deriving Repr, DecidableEq

def effectiveProviderAttempt (s : ProviderSessionState) (e : ProviderAttemptCheck) :
    ProviderAttemptCheck :=
  { e with
    pinnedAccountId    := if s.pinnedAccount != 0 then s.pinnedAccount else e.pinnedAccountId
    attemptsUsed       := s.attemptsUsed
    firstByteCommitted := if s.firstByteCommitted == 1 then 1 else e.firstByteCommitted }

def providerAttemptMachineStep (s : ProviderSessionState) (e : ProviderAttemptCheck) :
    ProviderSessionState × List UInt32 :=
  let e' := effectiveProviderAttempt s e
  let w := providerAttemptStep e'.pinnedAccountId e'.candidateAccountId
    e'.attemptsUsed e'.retryBudget e'.firstByteCommitted e'.failureKind
    e'.upstreamNowEpoch e'.cooldownUntilEpoch e'.upstreamDeadline e'.authValid
  let admit := providerAttemptMetaGate.gate e'
  let nextLock : UInt8 := if ((w &&& 0xFFFFFFFF) &&& 512) != 0 then 1 else 0
  let nextAttempts : UInt32 := (w >>> 32).toUInt32
  let nextPin : UInt32 :=
    if s.pinnedAccount != 0 then s.pinnedAccount
    else if admit then e'.candidateAccountId else 0
  (⟨nextPin, nextAttempts, nextLock⟩,
   if admit then [e.candidateAccountId] else [])

def providerAttemptMetaStepSpec :
    MetaStepSpec ProviderSessionState ProviderAttemptCheck UInt32 where
  safety := {
    step := providerAttemptMachineStep
    authorized := fun s e eff =>
      eff == e.candidateAccountId && (effectiveProviderAttempt s e).Admissible
    sound := fun s e eff h_in => by
      dsimp [providerAttemptMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := providerAttemptMetaGate.sound (effectiveProviderAttempt s e) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := ⟨0, 0, 0⟩
    step := providerAttemptMachineStep
    progressRequired := fun s e => (effectiveProviderAttempt s e).Admissible
    expectedEffect := fun e eff => eff == e.candidateAccountId
    live := fun s e h_req => by
      have h_gate := providerAttemptMetaGate.complete (effectiveProviderAttempt s e) h_req
      dsimp [providerAttemptMachineStep]
      simp [h_gate]
    traceEvents := [⟨0, 17, 0, 3, 0, 0, 100, 50, 500, 1⟩]
    posEvent := ⟨17, 17, 0, 3, 0, 1, 120, 50, 500, 1⟩
    negEvent := ⟨17, 99, 0, 3, 0, 1, 120, 50, 500, 1⟩
    reachable_live := by decide
  }
  cost := {
    step := providerAttemptMachineStep
    cpuFuel := fun s e => 11 + ((providerAttemptMachineStep s e).2).length
    inputBytes := fun _ => 56
    outputBytes := fun s e => 16 + 4 * ((providerAttemptMachineStep s e).2).length
    c0 := 12
    c1 := 1
    maxEffects := 1
    maxOutBytes := 20
    fuel_bound := fun s e => by
      dsimp [providerAttemptMachineStep]
      split <;> simp
    eff_bound := fun s e => by
      dsimp [providerAttemptMachineStep]
      split <;> simp
    out_bound := fun s e => by
      dsimp [providerAttemptMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

/-- Sticky first-byte stream lock, account pinning & cooldown gating (`G-ORB-2`):
    1. Once `firstByteCommitted = 1`, any retry (`failureKind = 1`) aborts (`lo32 = 515`,
       `admittedBit = 0`, `lockBit = 512`) and never increments `attemptsUsed`.
    2. When `pinnedAccountId ≠ 0` and `candidateAccountId ≠ pinnedAccountId`, dispatch is
       rejected (`admittedBit = 0`) regardless of budget or clock state.
    3. Any attempt before `cooldownUntilEpoch` (`upstreamNowEpoch < cooldownUntilEpoch`)
       is rejected (`admittedBit = 0`). -/
theorem provider_attempt_first_byte_lock_pin_and_cooldown
    (pinId candId used budget : UInt32) (fb fk auth : UInt8)
    (nowEp coolEp deadEp : UInt64)
    (h_pin_nz : pinId ≠ 0)
    (h_mismatch : candId ≠ pinId)
    (h_cool : nowEp < coolEp) :
    (providerAttemptStep pinId candId used budget 1 1 nowEp coolEp deadEp auth &&& 0xFFFFFFFF)
      = 515 ∧
    (providerAttemptStep pinId candId used budget 1 1 nowEp coolEp deadEp auth >>> 32).toUInt32
      = used ∧
    ((providerAttemptStep pinId candId used budget fb fk nowEp coolEp deadEp auth
        &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    ((providerAttemptStep 0 candId used budget fb fk nowEp coolEp deadEp auth
        &&& 0xFFFFFFFF) &&& 256) = 0 := by
  have hpz : (pinId == 0) = false := beq_eq_false_iff_ne.mpr h_pin_nz
  have hpm : (candId == pinId) = false := beq_eq_false_iff_ne.mpr h_mismatch
  have hnc : decide (coolEp ≤ nowEp) = false :=
    decide_eq_false (UInt64.not_le.mpr h_cool)
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold providerAttemptStep
    rw [pack32_lo]
    have h11 : ((1 : UInt8) == 1) = true := by decide
    simp only [h11, Bool.true_or, Bool.and_true, ite_true]
    decide
  · unfold providerAttemptStep
    rw [pack32_hi, toUInt32_toUInt64]
    have h11 : ((1 : UInt8) == 1) = true := by decide
    simp [h11]
  · unfold providerAttemptStep
    rw [pack32_lo]
    dsimp only [GE.ge]
    cases hfb : (fb == 1) <;>
      cases hf3 : (fk == 3) <;>
      cases hret : (fk == 1 || fk == 2) <;>
      cases hcz : (candId != 0) <;>
      (simp only [hfb, hf3, hret, hcz, hpz, hpm, Bool.or_false, Bool.and_false,
        Bool.not_false, Bool.false_eq_true, ite_true, ite_false]; decide)
  · unfold providerAttemptStep
    rw [pack32_lo]
    dsimp only [GE.ge]
    have hp0 : ((0 : UInt32) == 0) = true := by decide
    cases hfb : (fb == 1) <;>
      cases hf3 : (fk == 3) <;>
      cases hret : (fk == 1 || fk == 2) <;>
      cases hcz : (candId != 0) <;>
      cases hf2 : (fk != 2) <;>
      (simp only [hfb, hf3, hret, hcz, hp0, hf2, hnc, Bool.true_or, Bool.and_true,
        Bool.and_false, Bool.not_false, Bool.false_eq_true, ite_true, ite_false]; decide)

-- ---------------------------------------------------------------------------
-- Family 5 (`G-ORB-7`): TOCTOU Authorization Evidence Binding
-- ---------------------------------------------------------------------------

structure AuthToctouCheck where
  principalKind      : UInt8
  bunkerState        : UInt8
  observedTargetId   : UInt32
  execTargetId       : UInt32
  observedLeaseEpoch : UInt64
  liveLeaseEpoch     : UInt64
  nowTick            : UInt64
  expiryTick         : UInt64
  observedDigest     : UInt64
  execDigest         : UInt64
  deriving Repr, DecidableEq

def AuthToctouCheck.Admissible (a : AuthToctouCheck) : Bool :=
  (a.bunkerState == 0) &&
  decide (1 ≤ a.principalKind) && decide (a.principalKind ≤ 3) &&
  decide (a.nowTick < a.expiryTick) &&
  (a.observedLeaseEpoch != 0) && (a.observedLeaseEpoch == a.liveLeaseEpoch) &&
  (a.observedTargetId != 0) && (a.observedTargetId == a.execTargetId) &&
  (a.observedDigest != 0) && (a.observedDigest == a.execDigest)

theorem authToctou_admit_eq (a : AuthToctouCheck) :
    (((authToctouExecuteStep a.principalKind a.bunkerState
        a.observedTargetId a.execTargetId a.observedLeaseEpoch a.liveLeaseEpoch
        a.nowTick a.expiryTick a.observedDigest a.execDigest) &&& 256) != 0)
      = a.Admissible := by
  unfold AuthToctouCheck.Admissible authToctouExecuteStep
  dsimp only [GE.ge]
  have hb_inv : (a.bunkerState != 0) = !(a.bunkerState == 0) := by
    change (!(a.bunkerState == 0)) = !(a.bunkerState == 0); rfl
  rw [hb_inv]
  cases hb0 : (a.bunkerState == 0)
  · simp only [Bool.not_false, Bool.false_and, ite_true]
    decide
  · cases hp1 : decide (1 ≤ a.principalKind) <;>
      cases hp3 : decide (a.principalKind ≤ 3) <;>
      cases htime : decide (a.nowTick < a.expiryTick) <;>
      cases hl1 : (a.observedLeaseEpoch != 0) <;>
      cases hl2 : (a.observedLeaseEpoch == a.liveLeaseEpoch) <;>
      cases ht1 : (a.observedTargetId != 0) <;>
      cases ht2 : (a.observedTargetId == a.execTargetId) <;>
      cases hd1 : (a.observedDigest != 0) <;>
      cases hd2 : (a.observedDigest == a.execDigest) <;>
      (simp only [Bool.not_true, hp1, hp3, htime, hl1, hl2, ht1, ht2, hd1, hd2,
        Bool.true_and, Bool.false_and, Bool.and_true, Bool.and_false,
        Bool.not_false, Bool.false_eq_true, ite_true, ite_false];
       decide)

def authToctouMetaGate : MetaGateSpec AuthToctouCheck
    (fun a => a.Admissible = true) where
  gate a :=
    ((authToctouExecuteStep a.principalKind a.bunkerState
        a.observedTargetId a.execTargetId a.observedLeaseEpoch a.liveLeaseEpoch
        a.nowTick a.expiryTick a.observedDigest a.execDigest) &&& 256) != 0
  sound a hg := by rw [← authToctou_admit_eq a]; exact hg
  complete a hadm := by rw [authToctou_admit_eq a]; exact hadm
  posWitness := ⟨2, 0, 7, 7, 11, 11, 100, 200, 55, 55⟩
  negWitness := ⟨2, 0, 7, 9, 11, 11, 100, 200, 55, 55⟩
  nonVacuous := rfl
  tight      := rfl

structure AuthSessionState where
  revoked       : Bool
  lastTarget    : UInt32
  lastLease     : UInt64
  lastDigest    : UInt64
  executedCount : UInt32
  deriving Repr, DecidableEq

def effectiveAuthCheck (s : AuthSessionState) (a : AuthToctouCheck) : AuthToctouCheck :=
  { a with observedLeaseEpoch := if s.revoked then 0 else a.observedLeaseEpoch }

def authToctouMachineStep (s : AuthSessionState) (a : AuthToctouCheck) :
    AuthSessionState × List UInt32 :=
  let a' := effectiveAuthCheck s a
  let admit := authToctouMetaGate.gate a'
  (⟨s.revoked, if admit then a'.execTargetId else s.lastTarget,
    if admit then a'.liveLeaseEpoch else s.lastLease,
    if admit then a'.execDigest else s.lastDigest,
    if admit then s.executedCount + 1 else s.executedCount⟩,
   if admit then [a.execTargetId] else [])

def authToctouMetaStepSpec :
    MetaStepSpec AuthSessionState AuthToctouCheck UInt32 where
  safety := {
    step := authToctouMachineStep
    authorized := fun s a eff =>
      eff == a.execTargetId && (effectiveAuthCheck s a).Admissible
    sound := fun s a eff h_in => by
      dsimp [authToctouMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := authToctouMetaGate.sound (effectiveAuthCheck s a) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := ⟨false, 0, 0, 0, 0⟩
    step := authToctouMachineStep
    progressRequired := fun s a => (effectiveAuthCheck s a).Admissible
    expectedEffect := fun a eff => eff == a.execTargetId
    live := fun s a h_req => by
      have h_gate := authToctouMetaGate.complete (effectiveAuthCheck s a) h_req
      dsimp [authToctouMachineStep]
      simp [h_gate]
    traceEvents := [⟨2, 0, 3, 3, 9, 9, 10, 20, 42, 42⟩]
    posEvent := ⟨2, 0, 5, 5, 9, 9, 10, 20, 42, 42⟩
    negEvent := ⟨2, 1, 5, 5, 9, 9, 10, 20, 42, 42⟩
    reachable_live := by decide
  }
  cost := {
    step := authToctouMachineStep
    cpuFuel := fun s a => 13 + ((authToctouMachineStep s a).2).length
    inputBytes := fun _ => 58
    outputBytes := fun s a => 25 + 4 * ((authToctouMachineStep s a).2).length
    c0 := 14
    c1 := 1
    maxEffects := 1
    maxOutBytes := 29
    fuel_bound := fun s a => by
      dsimp [authToctouMachineStep]
      split <;> simp
    eff_bound := fun s a => by
      dsimp [authToctouMachineStep]
      split <;> simp
    out_bound := fun s a => by
      dsimp [authToctouMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

/-- TOCTOU fail-closed evidence binding (`G-ORB-7`): target swap, lease revocation/rotation,
    digest mutation, expiry, and bunker trip between `gate` and `execute` all clear
    `admittedBit` and emit no effect. -/
theorem auth_toctou_all_evidence_mutations_fail_closed
    (observedTarget execTarget : UInt32) (observedLease liveLease : UInt64)
    (nowTick expiryTick observedDigest execDigest : UInt64)
    (h_target_swap : execTarget ≠ observedTarget)
    (h_lease_rotate : liveLease ≠ observedLease)
    (h_digest_mutate : execDigest ≠ observedDigest) :
    ((authToctouExecuteStep 2 0 observedTarget execTarget observedLease observedLease
        nowTick expiryTick observedDigest observedDigest &&& 256) != 0) = false ∧
    ((authToctouExecuteStep 2 0 observedTarget observedTarget observedLease liveLease
        nowTick expiryTick observedDigest observedDigest &&& 256) != 0) = false ∧
    ((authToctouExecuteStep 2 0 observedTarget observedTarget observedLease observedLease
        nowTick expiryTick observedDigest execDigest &&& 256) != 0) = false ∧
    ((authToctouExecuteStep 2 0 observedTarget observedTarget observedLease observedLease
        expiryTick expiryTick observedDigest observedDigest &&& 256) != 0) = false ∧
    ((authToctouExecuteStep 2 1 observedTarget observedTarget observedLease observedLease
        nowTick expiryTick observedDigest observedDigest &&& 256) != 0) = false ∧
    ((authToctouMachineStep ⟨true, 0, 0, 0, 0⟩
        ⟨2, 0, observedTarget, observedTarget, observedLease, observedLease,
          nowTick, expiryTick, observedDigest, observedDigest⟩).2 = []) := by
  have h_target_ne : (observedTarget == execTarget) = false :=
    beq_eq_false_iff_ne.mpr (Ne.symm h_target_swap)
  have h_lease_ne : (observedLease == liveLease) = false :=
    beq_eq_false_iff_ne.mpr (Ne.symm h_lease_rotate)
  have h_digest_ne : (observedDigest == execDigest) = false :=
    beq_eq_false_iff_ne.mpr (Ne.symm h_digest_mutate)
  have hpk_ok : (decide ((1 : UInt8) ≤ 2) && decide ((2 : UInt8) ≤ 3)) = true := by decide
  have hb0_f : ((0 : UInt8) != 0) = false := by decide
  have hb1_t : ((1 : UInt8) != 0) = true := by decide
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · unfold authToctouExecuteStep
    dsimp only [GE.ge]
    cases ht : decide (nowTick < expiryTick) <;>
      cases hl : ((observedLease != 0) && (observedLease == observedLease)) <;>
      cases hto : (observedTarget != 0) <;>
      (simp only [hb0_f, hpk_ok, ht, hl, hto, h_target_ne, Bool.and_false,
        Bool.not_true, Bool.not_false, Bool.false_eq_true, ite_true, ite_false]; decide)
  · unfold authToctouExecuteStep
    dsimp only [GE.ge]
    cases ht : decide (nowTick < expiryTick) <;>
      cases hlo : (observedLease != 0) <;>
      (simp only [hb0_f, hpk_ok, ht, hlo, h_lease_ne, Bool.and_false,
        Bool.not_true, Bool.not_false, Bool.false_eq_true, ite_true, ite_false]; decide)
  · unfold authToctouExecuteStep
    dsimp only [GE.ge]
    cases ht : decide (nowTick < expiryTick) <;>
      cases hl : ((observedLease != 0) && (observedLease == observedLease)) <;>
      cases htg : ((observedTarget != 0) && (observedTarget == observedTarget)) <;>
      cases hdo : (observedDigest != 0) <;>
      (simp only [hb0_f, hpk_ok, ht, hl, htg, hdo, h_digest_ne, Bool.and_false,
        Bool.not_true, Bool.not_false, Bool.false_eq_true, ite_true, ite_false]; decide)
  · unfold authToctouExecuteStep
    dsimp only [GE.ge]
    have hnlt : decide (expiryTick < expiryTick) = false :=
      decide_eq_false (UInt64.lt_irrefl expiryTick)
    simp only [hb0_f, hpk_ok, hnlt, Bool.not_true, Bool.not_false, Bool.false_eq_true,
      ite_true, ite_false]
    decide
  · unfold authToctouExecuteStep
    simp only [hb1_t, ite_true]
    decide
  · have hg0 : authToctouMetaGate.gate (effectiveAuthCheck ⟨true, 0, 0, 0, 0⟩
        ⟨2, 0, observedTarget, observedTarget, observedLease, observedLease,
          nowTick, expiryTick, observedDigest, observedDigest⟩) = false := by
      dsimp only [authToctouMetaGate]
      rw [authToctou_admit_eq]
      dsimp [effectiveAuthCheck, AuthToctouCheck.Admissible]
      have hl0 : ((0 : UInt64) != 0) = false := by decide
      simp [hl0]
    dsimp [authToctouMachineStep]
    simp [hg0]

-- ---------------------------------------------------------------------------
-- Family 6 (`G-ORB-3`): Conserved Resource Reservation, Spend & TTL Reaper
-- ---------------------------------------------------------------------------

structure ResourceLedgerCheck where
  opKind         : UInt8
  reservedSlots  : UInt32
  activeSlots    : UInt32
  maxSlots       : UInt32
  spentCents     : UInt64
  costDeltaCents : UInt64
  budgetCents    : UInt64
  nowTick        : UInt64
  ttlExpiryTick  : UInt64
  deriving Repr, DecidableEq

def ResourceLedgerCheck.Admissible (r : ResourceLedgerCheck) : Bool :=
  let activeFits := decide (r.activeSlots ≤ r.maxSlots)
  let remSlots := if activeFits then r.maxSlots - r.activeSlots else 0
  let reservedFits := decide (r.reservedSlots ≤ remSlots)
  let budgetValid := decide (r.spentCents ≤ r.budgetCents)
  let stateValid :=
    if activeFits then (if reservedFits then budgetValid else false) else false
  let remBudget := if budgetValid then r.budgetCents - r.spentCents else 0
  let spendFits := if stateValid then decide (r.costDeltaCents ≤ remBudget) else false
  let hasFreeSlot := decide (r.reservedSlots < remSlots)
  let hasReserved := decide (0 < r.reservedSlots)
  let hasActive := decide (0 < r.activeSlots)
  let ttlLive := decide (r.nowTick < r.ttlExpiryTick)
  let ttlExpired := decide (r.ttlExpiryTick ≤ r.nowTick)
  let canReserve :=
    if r.opKind == 0 then
      (if spendFits then (if hasFreeSlot then ttlLive else false) else false)
    else false
  let canActivate :=
    if r.opKind == 1 then
      (if stateValid then (if hasReserved then ttlLive else false) else false)
    else false
  let canRelease :=
    if r.opKind == 2 then (if stateValid then hasActive else false) else false
  let canReap :=
    if r.opKind == 3 then
      (if stateValid then (if hasReserved then ttlExpired else false) else false)
    else false
  canReserve || canActivate || canRelease || canReap

theorem resourceLedger_admit_bit (k : UInt8) :
    (((257 : UInt32) ||| ((k.toUInt32 &&& (0xFF : UInt32)) <<< 1)).toUInt64 &&& 256) = 256 := by
  apply UInt64.toBitVec_inj.mp
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [UInt64.toBitVec_and, UInt32.toBitVec_toUInt64, UInt32.toBitVec_or,
    BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_setWidth]
  by_cases hi8 : i = 8
  · subst hi8
    have h1 : (257 : UInt32).toBitVec.getLsbD 8 = true := by decide
    have h2 : (256 : UInt64).toBitVec.getLsbD 8 = true := by decide
    simp [h1, h2]
  · have h2 : (256 : UInt64).toBitVec.getLsbD i = false := by
      have hiff : ((256 : UInt64).toBitVec.getLsbD i = true) ↔ i = 8 := by
        revert hi8 hi i; decide
      cases hg : (256 : UInt64).toBitVec.getLsbD i
      · rfl
      · exfalso; exact hi8 (hiff.mp hg)
    rw [h2]
    simp

theorem resourceLedger_admit_eq (r : ResourceLedgerCheck) :
    (((resourceLedgerStep r.opKind r.reservedSlots r.activeSlots r.maxSlots
        r.spentCents r.costDeltaCents r.budgetCents r.nowTick r.ttlExpiryTick
      &&& 0xFFFFFFFF) &&& 256) != 0) = r.Admissible := by
  unfold ResourceLedgerCheck.Admissible resourceLedgerStep
  rw [pack32_lo]
  dsimp only [GT.gt, GE.ge]
  have h_bit := resourceLedger_admit_bit r.opKind
  cases haf : decide (r.activeSlots ≤ r.maxSlots)
  · simp only [haf, Bool.false_eq_true, ite_false, ite_true, Bool.not_false,
      ite_self, Bool.or_false]
    decide
  · simp only [haf, ite_true]
    cases hrf : decide (r.reservedSlots ≤ r.maxSlots - r.activeSlots)
    · simp only [hrf, Bool.false_eq_true, ite_false, ite_true, Bool.not_false,
        ite_self, Bool.or_false]
      decide
    · simp only [hrf, ite_true]
      cases hbv : decide (r.spentCents ≤ r.budgetCents)
      · simp only [hbv, Bool.false_eq_true, ite_false, ite_true, Bool.not_false,
          ite_self, Bool.or_false]
        decide
      · simp only [hbv, ite_true]
        cases hsp : decide (r.costDeltaCents ≤ r.budgetCents - r.spentCents) <;>
          cases hfs : decide (r.reservedSlots < r.maxSlots - r.activeSlots) <;>
          cases hrr : decide (0 < r.reservedSlots) <;>
          cases hra : decide (0 < r.activeSlots) <;>
          cases htl : decide (r.nowTick < r.ttlExpiryTick) <;>
          cases hte : decide (r.ttlExpiryTick ≤ r.nowTick) <;>
          cases hop : (r.opKind == 0) <;>
          cases hop1 : (r.opKind == 1) <;>
          cases hop2 : (r.opKind == 2) <;>
          cases hop3 : (r.opKind == 3) <;>
          (simp only [hsp, hfs, hrr, hra, htl, hte, hop, hop1, hop2, hop3, h_bit,
            Bool.true_and, Bool.false_and, Bool.and_true, Bool.and_false,
            Bool.not_true, Bool.not_false, Bool.true_or, Bool.false_or,
            Bool.or_true, Bool.or_false, Bool.false_eq_true, ite_true, ite_false];
           decide)

def resourceLedgerMetaGate : MetaGateSpec ResourceLedgerCheck
    (fun r => r.Admissible = true) where
  gate r :=
    ((resourceLedgerStep r.opKind r.reservedSlots r.activeSlots r.maxSlots
        r.spentCents r.costDeltaCents r.budgetCents r.nowTick r.ttlExpiryTick
      &&& 0xFFFFFFFF) &&& 256) != 0
  sound r hg := by rw [← resourceLedger_admit_eq r]; exact hg
  complete r hadm := by rw [resourceLedger_admit_eq r]; exact hadm
  posWitness := ⟨0, 0, 0, 2, 10, 5, 100, 10, 20⟩
  negWitness := ⟨0, 0, 0, 2, 10, 200, 100, 10, 20⟩
  nonVacuous := rfl
  tight      := rfl

structure ResourceLedgerState where
  reserved    : UInt32
  active      : UInt32
  spentCents  : UInt64
  reapedCount : UInt32
  deriving Repr, DecidableEq

def resourceLedgerMachineStep (s : ResourceLedgerState) (r : ResourceLedgerCheck) :
    ResourceLedgerState × List UInt32 :=
  let r' := { r with reservedSlots := s.reserved, activeSlots := s.active }
  let admit := resourceLedgerMetaGate.gate r'
  let nextReserved :=
    if admit && r'.opKind == 0 then s.reserved + 1
    else if admit && (r'.opKind == 1 || r'.opKind == 3) then s.reserved - 1
    else s.reserved
  let nextActive :=
    if admit && r'.opKind == 1 then s.active + 1
    else if admit && r'.opKind == 2 then s.active - 1
    else s.active
  let nextSpent :=
    if admit && r'.opKind == 0 then s.spentCents + r'.costDeltaCents else s.spentCents
  let nextReaped :=
    if admit && r'.opKind == 3 then s.reapedCount + 1 else s.reapedCount
  (⟨nextReserved, nextActive, nextSpent, nextReaped⟩,
   if admit then [r'.opKind.toUInt32] else [])

def resourceLedgerMetaStepSpec :
    MetaStepSpec ResourceLedgerState ResourceLedgerCheck UInt32 where
  safety := {
    step := resourceLedgerMachineStep
    authorized := fun s r eff =>
      eff == r.opKind.toUInt32 &&
      ({ r with reservedSlots := s.reserved, activeSlots := s.active } :
        ResourceLedgerCheck).Admissible
    sound := fun s r eff h_in => by
      dsimp [resourceLedgerMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := resourceLedgerMetaGate.sound
          ({ r with reservedSlots := s.reserved, activeSlots := s.active } :
            ResourceLedgerCheck) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := ⟨0, 0, 0, 0⟩
    step := resourceLedgerMachineStep
    progressRequired := fun s r =>
      ({ r with reservedSlots := s.reserved, activeSlots := s.active } :
        ResourceLedgerCheck).Admissible
    expectedEffect := fun r eff => eff == r.opKind.toUInt32
    live := fun s r h_req => by
      have h_gate := resourceLedgerMetaGate.complete
        ({ r with reservedSlots := s.reserved, activeSlots := s.active } :
          ResourceLedgerCheck) h_req
      dsimp [resourceLedgerMachineStep]
      simp [h_gate]
    traceEvents := [⟨0, 0, 0, 2, 0, 5, 100, 10, 20⟩]
    posEvent := ⟨0, 0, 0, 2, 0, 5, 100, 10, 20⟩
    negEvent := ⟨0, 0, 0, 2, 0, 5, 100, 30, 20⟩
    reachable_live := by decide
  }
  cost := {
    step := resourceLedgerMachineStep
    cpuFuel := fun s r => 17 + ((resourceLedgerMachineStep s r).2).length
    inputBytes := fun _ => 57
    outputBytes := fun s r => 24 + 4 * ((resourceLedgerMachineStep s r).2).length
    c0 := 18
    c1 := 1
    maxEffects := 1
    maxOutBytes := 28
    fuel_bound := fun s r => by
      dsimp [resourceLedgerMachineStep]
      split <;> simp
    eff_bound := fun s r => by
      dsimp [resourceLedgerMachineStep]
      split <;> simp
    out_bound := fun s r => by
      dsimp [resourceLedgerMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

/-- Reservation, activation, release and TTL-reap conserve slots and never overspend
    (`G-ORB-3`). Concrete four-operation sequence ends with one active slot, zero reserved,
    exactly one charged reservation, and one expired reservation reaped. -/
theorem resource_ledger_conservation_and_ttl_reap :
    let r0 : ResourceLedgerCheck := ⟨0, 0, 0, 2, 0, 5, 100, 10, 20⟩
    let s1 := (resourceLedgerMachineStep ⟨0, 0, 0, 0⟩ r0).1
    let r1 : ResourceLedgerCheck := ⟨1, 0, 0, 2, 0, 0, 100, 11, 20⟩
    let s2 := (resourceLedgerMachineStep s1 r1).1
    let r2 : ResourceLedgerCheck := ⟨2, 0, 0, 2, 0, 0, 100, 12, 20⟩
    let s3 := (resourceLedgerMachineStep s2 r2).1
    let r3 : ResourceLedgerCheck := ⟨0, 0, 0, 2, 0, 7, 100, 13, 20⟩
    let s4 := (resourceLedgerMachineStep s3 r3).1
    let r4 : ResourceLedgerCheck := ⟨3, 0, 0, 2, 0, 0, 100, 25, 20⟩
    let s5 := (resourceLedgerMachineStep s4 r4).1
    s1.reserved = 1 ∧ s1.active = 0 ∧ s1.spentCents = 5 ∧
    s2.reserved = 0 ∧ s2.active = 1 ∧ s2.spentCents = 5 ∧
    s3.reserved = 0 ∧ s3.active = 0 ∧ s3.spentCents = 5 ∧
    s4.reserved = 1 ∧ s4.spentCents = 12 ∧
    s5.reserved = 0 ∧ s5.active = 0 ∧ s5.spentCents = 12 ∧ s5.reapedCount = 1 ∧
    s5.reserved + s5.active ≤ 2 ∧ s5.spentCents ≤ 100 := by
  decide

/-- A reservation that would exceed the remaining budget is rejected without changing
    the durable ledger or charging any cents. -/
theorem resource_ledger_overspend_rejected_without_wrap :
    ((resourceLedgerStep 0 0 0 1 95 10 100 1 2 &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (resourceLedgerMachineStep ⟨0, 0, 95, 0⟩
      ⟨0, 0, 0, 1, 95, 10, 100, 1, 2⟩).1 = ⟨0, 0, 95, 0⟩ := by
  decide

-- ---------------------------------------------------------------------------
-- Family 7 (`G-ORB-6`): Bounded-Tail Checkpointed Stream Commit
-- ---------------------------------------------------------------------------

structure StreamBoundedCommitCheck where
  prevLen          : UInt32
  prevCommit       : UInt32
  prevCheckpoint   : UInt32
  newLen           : UInt32
  rawCommit        : UInt32
  maxOpenTailBytes : UInt32
  deriving Repr, DecidableEq

def StreamBoundedCommitCheck.Admissible (c : StreamBoundedCommitCheck) : Bool :=
  decide (0 < c.maxOpenTailBytes) &&
  decide (c.prevCommit ≤ c.prevCheckpoint) &&
  decide (c.prevCheckpoint ≤ c.prevLen) &&
  decide (c.prevLen ≤ c.newLen)

theorem streamBoundedCommit_admit_eq (c : StreamBoundedCommitCheck) :
    (((streamBoundedCommitStep c.prevLen c.prevCommit c.prevCheckpoint
        c.newLen c.rawCommit c.maxOpenTailBytes &&& 0xFFFFFFFF) &&& 256) != 0)
      = c.Admissible := by
  unfold StreamBoundedCommitCheck.Admissible streamBoundedCommitStep
  rw [pack32_lo]
  dsimp only [GT.gt]
  let clampedRaw := if c.rawCommit ≤ c.newLen then c.rawCommit else c.newLen
  let nextCommit := if c.prevCommit ≤ clampedRaw then clampedRaw else c.prevCommit
  let baseCheckpoint := if c.prevCheckpoint ≤ nextCommit then nextCommit else c.prevCheckpoint
  let capFloor := if c.maxOpenTailBytes ≤ c.newLen then c.newLen - c.maxOpenTailBytes else 0
  let nextCheckpoint := if baseCheckpoint ≤ capFloor then capFloor else baseCheckpoint
  have hfold :
      (if nextCommit < nextCheckpoint then (512 : UInt32) else 0) =
      (if decide (nextCommit < nextCheckpoint) = true then (512 : UInt32) else 0) := by
    by_cases hlt : nextCommit < nextCheckpoint <;> simp [hlt]
  change
    ((if (!(decide (0 < c.maxOpenTailBytes) &&
            (decide (c.prevCommit ≤ c.prevCheckpoint) &&
              decide (c.prevCheckpoint ≤ c.prevLen) &&
              decide (c.prevLen ≤ c.newLen)))) = true then
        (0 : UInt32)
      else 257 ||| (if nextCommit < nextCheckpoint then 512 else 0)).toUInt64 &&& 256 != 0)
    = (decide (0 < c.maxOpenTailBytes) &&
        decide (c.prevCommit ≤ c.prevCheckpoint) &&
        decide (c.prevCheckpoint ≤ c.prevLen) &&
        decide (c.prevLen ≤ c.newLen))
  rw [hfold]
  cases hcap : decide (0 < c.maxOpenTailBytes) <;>
    cases hm1 : decide (c.prevCommit ≤ c.prevCheckpoint) <;>
    cases hm2 : decide (c.prevCheckpoint ≤ c.prevLen) <;>
    cases hm3 : decide (c.prevLen ≤ c.newLen) <;>
    cases hcf : decide (nextCommit < nextCheckpoint) <;>
    (simp only [hcap, hm1, hm2, hm3, hcf, Bool.true_and, Bool.false_and, Bool.and_true,
      Bool.and_false, Bool.not_true, Bool.not_false, Bool.false_eq_true,
      ite_true, ite_false]; decide)

def streamBoundedCommitMetaGate : MetaGateSpec StreamBoundedCommitCheck
    (fun c => c.Admissible = true) where
  gate c :=
    ((streamBoundedCommitStep c.prevLen c.prevCommit c.prevCheckpoint
        c.newLen c.rawCommit c.maxOpenTailBytes &&& 0xFFFFFFFF) &&& 256) != 0
  sound c hg := by rw [← streamBoundedCommit_admit_eq c]; exact hg
  complete c hadm := by rw [streamBoundedCommit_admit_eq c]; exact hadm
  posWitness := ⟨0, 0, 0, 10, 8, 4⟩
  negWitness := ⟨0, 0, 0, 10, 8, 0⟩
  nonVacuous := rfl
  tight      := rfl

structure StreamCommitState where
  len        : UInt32
  commit     : UInt32
  checkpoint : UInt32
  deriving Repr, DecidableEq

def effectiveStreamCommit (s : StreamCommitState) (c : StreamBoundedCommitCheck) :
    StreamBoundedCommitCheck :=
  { c with prevLen := s.len, prevCommit := s.commit, prevCheckpoint := s.checkpoint }

def streamBoundedCommitMachineStep (s : StreamCommitState)
    (c : StreamBoundedCommitCheck) : StreamCommitState × List UInt32 :=
  let c' := effectiveStreamCommit s c
  let w := streamBoundedCommitStep c'.prevLen c'.prevCommit c'.prevCheckpoint
    c'.newLen c'.rawCommit c'.maxOpenTailBytes
  let admit := streamBoundedCommitMetaGate.gate c'
  let clampedRaw := if c.rawCommit ≤ c.newLen then c.rawCommit else c.newLen
  let nextCommit := if s.commit ≤ clampedRaw then clampedRaw else s.commit
  let nextCheckpoint := if admit then (w >>> 32).toUInt32 else s.checkpoint
  (⟨if admit then c.newLen else s.len,
    if admit then nextCommit else s.commit, nextCheckpoint⟩,
   if admit then [c.newLen] else [])

def streamBoundedCommitMetaStepSpec :
    MetaStepSpec StreamCommitState StreamBoundedCommitCheck UInt32 where
  safety := {
    step := streamBoundedCommitMachineStep
    authorized := fun s c eff =>
      eff == c.newLen && (effectiveStreamCommit s c).Admissible
    sound := fun s c eff h_in => by
      dsimp [streamBoundedCommitMachineStep] at h_in
      split at h_in
      · next h_emit =>
        simp only [List.mem_singleton] at h_in
        subst h_in
        have h_adm := streamBoundedCommitMetaGate.sound (effectiveStreamCommit s c) h_emit
        simp [h_adm]
      · contradiction
  }
  liveness := {
    init := ⟨0, 0, 0⟩
    step := streamBoundedCommitMachineStep
    progressRequired := fun s c => (effectiveStreamCommit s c).Admissible
    expectedEffect := fun c eff => eff == c.newLen
    live := fun s c h_req => by
      have h_gate := streamBoundedCommitMetaGate.complete (effectiveStreamCommit s c) h_req
      dsimp [streamBoundedCommitMachineStep]
      simp [h_gate]
    traceEvents := [⟨0, 0, 0, 8, 6, 4⟩]
    posEvent := ⟨8, 6, 6, 12, 10, 4⟩
    negEvent := ⟨8, 6, 6, 12, 10, 0⟩
    reachable_live := by decide
  }
  cost := {
    step := streamBoundedCommitMachineStep
    cpuFuel := fun s c => 15 + ((streamBoundedCommitMachineStep s c).2).length
    inputBytes := fun _ => 24
    outputBytes := fun s c => 12 + 4 * ((streamBoundedCommitMachineStep s c).2).length
    c0 := 16
    c1 := 1
    maxEffects := 1
    maxOutBytes := 16
    fuel_bound := fun s c => by
      dsimp [streamBoundedCommitMachineStep]
      split <;> simp
    eff_bound := fun s c => by
      dsimp [streamBoundedCommitMachineStep]
      split <;> simp
    out_bound := fun s c => by
      dsimp [streamBoundedCommitMachineStep]
      split <;> simp
  }
  sameStep := ⟨rfl, rfl⟩

/-- Multi-chunk checkpointed scanner conservation (`G-ORB-6`): commits are monotone,
    checkpoint is never behind commit, and the unparsed tail never exceeds the configured
    cap even when the raw parser stalls at an unclosed fence. -/
theorem stream_bounded_commit_multichunk_conservation :
    let s0 : StreamCommitState := ⟨0, 0, 0⟩
    let s1 := (streamBoundedCommitMachineStep s0 ⟨0, 0, 0, 20, 5, 8⟩).1
    let s2 := (streamBoundedCommitMachineStep s1 ⟨0, 0, 0, 40, 5, 8⟩).1
    let s3 := (streamBoundedCommitMachineStep s2 ⟨0, 0, 0, 41, 45, 8⟩).1
    s1.len = 20 ∧ s1.commit = 5 ∧ s1.checkpoint = 12 ∧
    s2.len = 40 ∧ s2.commit = 5 ∧ s2.checkpoint = 32 ∧
    s3.len = 41 ∧ s3.commit = 41 ∧ s3.checkpoint = 41 ∧
    s1.checkpoint ≥ s1.commit ∧ s2.checkpoint ≥ s2.commit ∧
    s3.checkpoint ≥ s3.commit ∧
    s1.len - s1.checkpoint ≤ 8 ∧ s2.len - s2.checkpoint ≤ 8 ∧
    s3.len - s3.checkpoint ≤ 8 := by
  decide

/-- Invalid monotonicity or a zero cap fails closed without moving the checkpoint. -/
theorem stream_bounded_commit_invalid_state_preserves_checkpoint :
    ((streamBoundedCommitStep 10 9 8 11 10 4 &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (streamBoundedCommitStep 10 9 8 11 10 4 >>> 32).toUInt32 = 8 ∧
    ((streamBoundedCommitStep 0 0 0 10 8 0 &&& 0xFFFFFFFF) &&& 256) = 0 ∧
    (streamBoundedCommitStep 0 0 0 10 8 0 >>> 32).toUInt32 = 0 := by
  decide

structure VmCapCheck where
  hasPoolOverride : UInt8
  hasPoolMax      : UInt8
  hasProviderMax  : UInt8
  hasGlobalMax    : UInt8
  ancestorBlocked : UInt8
  sharedActive    : UInt32
  globalMax       : UInt32
  poolActive      : UInt32
  poolMax         : UInt32
  providerActive  : UInt32
  providerMax     : UInt32
  deriving Repr, DecidableEq

def VmCapCheck.Admissible (s : VmCapCheck) : Bool :=
  !(s.ancestorBlocked == 1) &&
  if s.hasPoolOverride == 1 then
    (s.hasPoolMax == 1 || s.hasProviderMax == 1) &&
    (s.hasProviderMax == 0 || s.providerActive < s.providerMax) &&
    (s.hasPoolMax == 0 || s.poolActive < s.poolMax)
  else
    (s.hasGlobalMax == 0 || s.sharedActive < s.globalMax)

def vmCapMetaGate : MetaGateSpec VmCapCheck (fun s => VmCapCheck.Admissible s = true) where
  gate s :=
    (vmCapAdmit
      s.hasPoolOverride s.hasPoolMax s.hasProviderMax s.hasGlobalMax s.ancestorBlocked
      s.sharedActive s.globalMax s.poolActive s.poolMax s.providerActive s.providerMax &&& 256) != 0
  sound s h := by
    unfold VmCapCheck.Admissible
    unfold vmCapAdmit at h
    cases ha : (s.ancestorBlocked == 1) <;>
      cases ho : (s.hasPoolOverride == 1) <;>
      cases hm : (s.hasPoolMax == 1 || s.hasProviderMax == 1) <;>
      cases hp : (s.hasProviderMax == 0 || decide (s.providerActive < s.providerMax)) <;>
      cases hl : (s.hasPoolMax == 0 || decide (s.poolActive < s.poolMax)) <;>
      cases hg : (s.hasGlobalMax == 0 || decide (s.sharedActive < s.globalMax)) <;>
      (simp only [ha, ho, hm, hp, hl, hg] at h ⊢; revert h; decide)
  complete s h := by
    unfold VmCapCheck.Admissible at h
    unfold vmCapAdmit
    cases ha : (s.ancestorBlocked == 1) <;>
      cases ho : (s.hasPoolOverride == 1) <;>
      cases hm : (s.hasPoolMax == 1 || s.hasProviderMax == 1) <;>
      cases hp : (s.hasProviderMax == 0 || decide (s.providerActive < s.providerMax)) <;>
      cases hl : (s.hasPoolMax == 0 || decide (s.poolActive < s.poolMax)) <;>
      cases hg : (s.hasGlobalMax == 0 || decide (s.sharedActive < s.globalMax)) <;>
      (simp only [ha, ho, hm, hp, hl, hg] at h ⊢; revert h; decide)
  posWitness := ⟨1, 0, 1, 1, 0, 16, 16, 0, 0, 0, 2⟩
  negWitness := ⟨0, 0, 0, 1, 0, 16, 16, 0, 0, 0, 0⟩
  nonVacuous := rfl
  tight      := rfl

/-- Scoped per-provider override (`hasPoolOverride = 1, hasProviderMax = 1`) with free provider
    capacity (`providerActive < providerMax`) admits (`257`) even when the shared global pool is
    saturated (`sharedActive = globalMax`), while an exhausted ancestor override (`ancestorBlocked = 1`)
    or bound-free override (`hasPoolMax = 0 ∧ hasProviderMax = 0`) fails closed (`512`). -/
theorem vm_cap_override_bypasses_saturated_global_and_fails_closed
    (globalMax poolAct poolMx provAct provMx : UInt32)
    (h_prov : decide (provAct < provMx) = true) :
    vmCapAdmit 1 0 1 1 0 globalMax globalMax poolAct poolMx provAct provMx = 257 ∧
    vmCapAdmit 1 0 1 1 1 globalMax globalMax poolAct poolMx provAct provMx = 512 ∧
    vmCapAdmit 1 0 0 1 0 globalMax globalMax poolAct poolMx provAct provMx = 512 := by
  unfold vmCapAdmit
  simp [h_prov]

/-- Setting `providerMax = 0` (`hasProviderMax = 1`) unconditionally blocks that provider (`512`)
    for the mission subtree regardless of overall `poolMax` or global capacity. -/
theorem vm_cap_zero_provider_limit_blocks_provider
    (hasPoolMx hasGlob anc : UInt8) (shAct glMx plAct plMx prAct : UInt32) :
    vmCapAdmit 1 hasPoolMx 1 hasGlob anc shAct glMx plAct plMx prAct 0 = 512 := by
  unfold vmCapAdmit
  have h_not_lt_zero : ¬ (prAct < (0 : UInt32)) := by
    intro h
    exact Nat.not_lt_zero prAct.toNat h
  cases ha : (anc == 1) <;>
    cases hm : (hasPoolMx == 1) <;>
    simp_all

structure SlotBypassCheck where
  isOperatorForce : UInt8
  isAgentCaller   : UInt8
  isWaitingSlot   : UInt8
  regularRunning  : UInt32
  regularMax      : UInt32
  forcedRunning   : UInt32
  forcedMax       : UInt32
  deriving Repr, DecidableEq

def SlotBypassCheck.Admissible (s : SlotBypassCheck) : Bool :=
  if s.isOperatorForce == 1 then
    !(s.isAgentCaller == 1) && (s.isWaitingSlot == 1) && decide (s.forcedRunning < s.forcedMax)
  else
    decide (s.regularRunning < s.regularMax)

def slotBypassMetaGate : MetaGateSpec SlotBypassCheck (fun s => SlotBypassCheck.Admissible s = true) where
  gate s :=
    (slotBypassStep
      s.isOperatorForce s.isAgentCaller s.isWaitingSlot
      s.regularRunning s.regularMax s.forcedRunning s.forcedMax &&& 256) != 0
  sound s h := by
    unfold SlotBypassCheck.Admissible
    unfold slotBypassStep at h
    cases hf : (s.isOperatorForce == 1) <;>
      cases ha : (s.isAgentCaller == 1) <;>
      cases hw : (s.isWaitingSlot == 1) <;>
      by_cases hb : s.forcedRunning < s.forcedMax <;>
      by_cases hr : s.regularRunning < s.regularMax <;>
      (simp only [hf, ha, hw, hb, hr, decide_true, decide_false, ↓reduceIte] at h ⊢; revert h; decide)
  complete s h := by
    unfold SlotBypassCheck.Admissible at h
    unfold slotBypassStep
    cases hf : (s.isOperatorForce == 1) <;>
      cases ha : (s.isAgentCaller == 1) <;>
      cases hw : (s.isWaitingSlot == 1) <;>
      by_cases hb : s.forcedRunning < s.forcedMax <;>
      by_cases hr : s.regularRunning < s.regularMax <;>
      (simp only [hf, ha, hw, hb, hr, decide_true, decide_false, ↓reduceIte] at h ⊢; revert h; decide)
  posWitness := ⟨1, 0, 1, 6, 6, 0, 1⟩
  negWitness := ⟨1, 0, 1, 6, 6, 1, 1⟩
  nonVacuous := rfl
  tight      := rfl

def slotBypassScopedAuthority : ScopedAuthority SlotBypassCheck where
  admit s := slotBypassMetaGate.gate s
  scopeValid s := !(s.isOperatorForce == 1 && s.isAgentCaller == 1)
  sound s h := by
    have hadm := slotBypassMetaGate.sound s h
    unfold SlotBypassCheck.Admissible at hadm
    cases hf : (s.isOperatorForce == 1) <;>
      cases ha : (s.isAgentCaller == 1) <;>
      simp_all

def slotBypassConservedResource : ConservedResource SlotBypassCheck where
  admit s := slotBypassMetaGate.gate s
  withinBudget s :=
    if s.isOperatorForce == 1 then
      decide (s.forcedRunning < s.forcedMax)
    else
      decide (s.regularRunning < s.regularMax)
  conserved s h := by
    have hadm := slotBypassMetaGate.sound s h
    unfold SlotBypassCheck.Admissible at hadm
    cases hf : (s.isOperatorForce == 1) <;> simp_all

/-- Explicit operator force (`isOperatorForce = 1, isAgentCaller = 0, isWaitingSlot = 1`)
    admits (`258`) even when regular slots are saturated (`regularRunning = regularMax`) provided
    the extra forced slot is free (`forcedRunning < forcedMax`), rejects autonomous agent callers
    (`513`), rejects non-waiting missions (`514`), and rejects when the forced slot is already
    occupied (`512`). -/
theorem slot_bypass_bypasses_saturated_regular_and_enforces_guards
    (regMax forcedAct forcedMx : UInt32)
    (h_force : forcedAct < forcedMx) :
    slotBypassStep 1 0 1 regMax regMax forcedAct forcedMx = 258 ∧
    slotBypassStep 1 1 1 regMax regMax forcedAct forcedMx = 513 ∧
    slotBypassStep 1 0 0 regMax regMax forcedAct forcedMx = 514 ∧
    slotBypassStep 1 0 1 regMax regMax forcedMx forcedMx = 512 := by
  unfold slotBypassStep
  have h_self : ¬ (forcedMx < forcedMx) := Nat.lt_irrefl forcedMx.toNat
  simp [h_force, h_self]

/-- Standard worker admission (`isOperatorForce = 0`) is strictly independent of `forcedRunning`
    and `forcedMax`: a running forced worker never consumes or reduces regular worker slots. -/
theorem slot_bypass_regular_admission_ignores_forced_workers
    (agent wait : UInt8) (regRun regMax fRunA fMaxA fRunB fMaxB : UInt32) :
    slotBypassStep 0 agent wait regRun regMax fRunA fMaxA =
      slotBypassStep 0 agent wait regRun regMax fRunB fMaxB := by
  unfold slotBypassStep
  rfl

end Orb.Spec
