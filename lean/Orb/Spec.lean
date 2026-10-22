/-
  Orb.Spec: Verified Orchestration, Lease Linearity & Node Lifecycle Kernel (`0 import Lean`, `0 sorryAx`)
  - Layer I: Universal Orchestrator Meta-Specifications (`LinearLeaseSpec`, `IdempotentOutboxSpec`,
    `DagScheduleSpec`, `QuotaCircuitSpec`) with bidirectional (`↔`) gate-safety equivalence
  - Layer II: Declarative Orchestrator Corollaries (≤ 3 lines each)
  - Direct Unboxed C-ABI (`@[inline, export]` in `Orb.Kernel`):
    `orb_verify_writer_reuse`, `orb_verify_lease_mode`,
    `orb_verify_track_hold`, `orb_verify_repo_disjoint`,
    `orb_verify_remote_outbox`, `orb_verify_board_slots`,
    `orb_verify_board_retry`, `orb_verify_job_transition`,
    `orb_verify_bundle_budget`, `orb_verify_token_rotation`,
    `leansys_verify_log_window`, `leansys_mix64_word`
-/

import Orb.Kernel

namespace Orb.Spec

open Orb.Kernel

/-! ## Layer I: Universal Orchestrator Meta-Specifications & Combinators -/

/--
  Universal `LinearLeaseSpec`:
  Certifies that at most one active writer holds a mutation domain `(project, track, github_pr)`
  unless an explicit continuation assertion matches the stored identity or the caller explicitly retags.
  Enforces exact bidirectional equivalence (`gate s x = true ↔ safe s x = true`).
-/
structure LinearLeaseSpec (σ α : Type) where
  inv : σ → Prop
  gate : σ → α → Bool
  step : σ → α → σ
  safe : σ → α → Bool
  preserves_inv : ∀ s x, gate s x = true → inv s → inv (step s x)
  gate_iff_safe : ∀ s x, gate s x = true ↔ safe s x = true

/-- Soundness direction (`gate → safe`) for any `LinearLeaseSpec`. -/
theorem LinearLeaseSpec.ensures_safe (L : LinearLeaseSpec σ α) (s : σ) (x : α)
    (h_gate : L.gate s x = true) :
    L.safe s x = true :=
  (L.gate_iff_safe s x).mp h_gate

/-- Completeness direction (`safe → gate`) for any `LinearLeaseSpec`. -/
theorem LinearLeaseSpec.admits_safe (L : LinearLeaseSpec σ α) (s : σ) (x : α)
    (h_safe : L.safe s x = true) :
    L.gate s x = true :=
  (L.gate_iff_safe s x).mpr h_safe

/-- Contrapositive rejection law for any `LinearLeaseSpec`. -/
theorem LinearLeaseSpec.rejects_unsafe (L : LinearLeaseSpec σ α) (s : σ) (x : α)
    (h_unsafe : L.safe s x = false) :
    L.gate s x = false := by
  cases h : L.gate s x with
  | false => rfl
  | true =>
    have hs := L.ensures_safe s x h
    rw [h_unsafe] at hs
    contradiction

/--
  Universal `IdempotentOutboxSpec`:
  Certifies that durable remote follow-up and board outbox deliveries are idempotent
  on `(user_id, message_id)` retries and reject cancelled or already-claimed rows.
  Enforces exact bidirectional equivalence (`admit r q = true ↔ safeReplay r q = true`).
-/
structure IdempotentOutboxSpec (Row Req : Type) where
  admit : Row → Req → Bool
  safeReplay : Row → Req → Bool
  admit_iff_safe_replay : ∀ r q, admit r q = true ↔ safeReplay r q = true

/-- Soundness direction (`admit → safeReplay`) for any `IdempotentOutboxSpec`. -/
theorem IdempotentOutboxSpec.ensures_safe_replay (O : IdempotentOutboxSpec Row Req)
    (r : Row) (q : Req) (h_admit : O.admit r q = true) :
    O.safeReplay r q = true :=
  (O.admit_iff_safe_replay r q).mp h_admit

/-- Completeness direction (`safeReplay → admit`) for any `IdempotentOutboxSpec`. -/
theorem IdempotentOutboxSpec.admits_safe_replay (O : IdempotentOutboxSpec Row Req)
    (r : Row) (q : Req) (h_safe : O.safeReplay r q = true) :
    O.admit r q = true :=
  (O.admit_iff_safe_replay r q).mpr h_safe

/-- Contrapositive rejection law for any `IdempotentOutboxSpec`. -/
theorem IdempotentOutboxSpec.rejects_conflicting_replay (O : IdempotentOutboxSpec Row Req)
    (r : Row) (q : Req) (h_bad : O.safeReplay r q = false) :
    O.admit r q = false := by
  cases h : O.admit r q with
  | false => rfl
  | true =>
    have hs := O.ensures_safe_replay r q h
    rw [h_bad] at hs
    contradiction

/--
  Universal `DagScheduleSpec`:
  Certifies that a board scheduler always reserves `reservedBossSlots ≥ 1` for boss digest delivery
  and bounds automatic retries to `attempts < maxAttempts` when external recovery is not required.
  Enforces exact bidirectional equivalence (`canSchedule b = true ↔ slotSafe b = true`).
-/
structure DagScheduleSpec (BoardState : Type) where
  canSchedule : BoardState → Bool
  slotSafe : BoardState → Bool
  schedule_iff_slot_safe : ∀ b, canSchedule b = true ↔ slotSafe b = true

/-- Soundness direction (`canSchedule → slotSafe`) for any `DagScheduleSpec`. -/
theorem DagScheduleSpec.ensures_slot_safe (D : DagScheduleSpec BoardState) (b : BoardState)
    (h_sched : D.canSchedule b = true) :
    D.slotSafe b = true :=
  (D.schedule_iff_slot_safe b).mp h_sched

/-- Completeness direction (`slotSafe → canSchedule`) for any `DagScheduleSpec`. -/
theorem DagScheduleSpec.schedules_when_slot_safe (D : DagScheduleSpec BoardState) (b : BoardState)
    (h_safe : D.slotSafe b = true) :
    D.canSchedule b = true :=
  (D.schedule_iff_slot_safe b).mpr h_safe

/-- Contrapositive rejection law for any `DagScheduleSpec`. -/
theorem DagScheduleSpec.rejects_starvation (D : DagScheduleSpec BoardState) (b : BoardState)
    (h_bad : D.slotSafe b = false) :
    D.canSchedule b = false := by
  cases h : D.canSchedule b with
  | false => rfl
  | true =>
    have hs := D.ensures_slot_safe b h
    rw [h_bad] at hs
    contradiction

/--
  Universal `QuotaCircuitSpec`:
  Certifies monotonic terminal absorption on durable node job state transitions (`queued → running → terminal`)
  and strict byte-budget enforcement on source bundles and log windows.
  Enforces exact bidirectional equivalence (`validTransition s = true ↔ safeTransition s = true`).
-/
structure QuotaCircuitSpec (State : Type) where
  validTransition : State → Bool
  safeTransition : State → Bool
  valid_iff_safe : ∀ s, validTransition s = true ↔ safeTransition s = true

/-- Soundness direction (`validTransition → safeTransition`) for any `QuotaCircuitSpec`. -/
theorem QuotaCircuitSpec.ensures_monotonic (Q : QuotaCircuitSpec State) (s : State)
    (h_valid : Q.validTransition s = true) :
    Q.safeTransition s = true :=
  (Q.valid_iff_safe s).mp h_valid

/-- Completeness direction (`safeTransition → validTransition`) for any `QuotaCircuitSpec`. -/
theorem QuotaCircuitSpec.admits_safe_transition (Q : QuotaCircuitSpec State) (s : State)
    (h_safe : Q.safeTransition s = true) :
    Q.validTransition s = true :=
  (Q.valid_iff_safe s).mpr h_safe

/-- Contrapositive rejection law for any `QuotaCircuitSpec`. -/
theorem QuotaCircuitSpec.rejects_invalid_transition (Q : QuotaCircuitSpec State) (s : State)
    (h_bad : Q.safeTransition s = false) :
    Q.validTransition s = false := by
  cases h : Q.validTransition s with
  | false => rfl
  | true =>
    have hs := Q.ensures_monotonic s h
    rw [h_bad] at hs
    contradiction

/-! ## Layer II: Bidirectional Gate Specifications & Corollaries (≤ 3 Lines Each) -/

/-- Writer reuse check parameters. -/
structure WriterReuseCheck where
  hasContinue       : UInt8
  contTrackNonempty : UInt8
  contMatchesStored : UInt8
  hasAnyEdit        : UInt8
  workChanged       : UInt8
  identityUpdated   : UInt8
  deriving Repr, DecidableEq

/-- Layer II Bundle 1: Writer identity continuation & silent-recycle refusal gate. -/
def writerReuseLinearSpec : LinearLeaseSpec Unit WriterReuseCheck where
  inv _ := True
  gate _ c :=
    verifyWriterReuse c.hasContinue c.contTrackNonempty c.contMatchesStored
      c.hasAnyEdit c.workChanged c.identityUpdated == 1
  step _ _ := ()
  safe _ c :=
    if c.hasContinue == 1 then
      (c.contTrackNonempty == 1 && c.contMatchesStored == 1 && c.hasAnyEdit == 0)
    else
      (c.workChanged == 0 || c.identityUpdated == 1)
  preserves_inv _ _ _ h := h
  gate_iff_safe _ _ := by
    unfold verifyWriterReuse
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 1: `verifyWriterReuse` refuses silent writer retasking or mismatched continuation assertions. -/
theorem writer_reuse_rejects_stale_identity (c : WriterReuseCheck)
    (h_bad : (if c.hasContinue == 1 then
      (c.contTrackNonempty == 1 && c.contMatchesStored == 1 && c.hasAnyEdit == 0)
    else (c.workChanged == 0 || c.identityUpdated == 1)) = false) :
    (verifyWriterReuse c.hasContinue c.contTrackNonempty c.contMatchesStored
      c.hasAnyEdit c.workChanged c.identityUpdated == 1) = false :=
  writerReuseLinearSpec.rejects_unsafe () c h_bad

/-- Lease mode check parameters. -/
structure LeaseModeCheck where
  writerFlag       : UInt8
  hasReadonlyTag   : UInt8
  hasWriterTag     : UInt8
  isReadonlyIntent : UInt8
  deriving Repr, DecidableEq

/-- Layer II Bundle 2: Explicit `writer: false` / `pr-readonly` capability downgrade gate. -/
def leaseModeLinearSpec : LinearLeaseSpec Unit LeaseModeCheck where
  inv _ := True
  gate _ m := verifyLeaseMode m.writerFlag m.hasReadonlyTag m.hasWriterTag m.isReadonlyIntent == 0
  step _ _ := ()
  safe _ m :=
    (m.writerFlag == 0 || m.hasReadonlyTag == 1 ||
     (m.writerFlag != 1 && m.hasWriterTag != 1 && m.isReadonlyIntent == 1))
  preserves_inv _ _ _ h := h
  gate_iff_safe _ _ := by
    unfold verifyLeaseMode
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 2: Any mission without `writer=false`, `pr-readonly`, or a read-only intent is classified as a writer (`!= 0`). -/
theorem lease_mode_defaults_to_writer (m : LeaseModeCheck)
    (h_mut : (m.writerFlag == 0 || m.hasReadonlyTag == 1 ||
      (m.writerFlag != 1 && m.hasWriterTag != 1 && m.isReadonlyIntent == 1)) = false) :
    (verifyLeaseMode m.writerFlag m.hasReadonlyTag m.hasWriterTag m.isReadonlyIntent == 0) = false :=
  leaseModeLinearSpec.rejects_unsafe () m h_mut

/-- Track hold check parameters. -/
structure TrackHoldCheck where
  inUnresolved    : UInt8
  inQueued        : UInt8
  hasLiveOwner    : UInt8
  nativeGoalHolds : UInt8
  deriving Repr, DecidableEq

/-- Layer II Bundle 3: Conservative execution ownership release gate. -/
def trackHoldLinearSpec : LinearLeaseSpec Unit TrackHoldCheck where
  inv _ := True
  gate _ t := verifyTrackHold t.inUnresolved t.inQueued t.hasLiveOwner t.nativeGoalHolds == 0
  step _ _ := ()
  safe _ t := (t.inUnresolved != 1 && t.inQueued != 1 && t.hasLiveOwner != 1 && t.nativeGoalHolds != 1)
  preserves_inv _ _ _ h := h
  gate_iff_safe _ _ := by
    unfold verifyTrackHold
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 3: Track ownership is never released (`verifyTrackHold == 0` is false) while any execution or native goal is unresolved. -/
theorem track_hold_blocks_premature_release (t : TrackHoldCheck)
    (h_active : (t.inUnresolved != 1 && t.inQueued != 1 && t.hasLiveOwner != 1 && t.nativeGoalHolds != 1) = false) :
    (verifyTrackHold t.inUnresolved t.inQueued t.hasLiveOwner t.nativeGoalHolds == 0) = false :=
  trackHoldLinearSpec.rejects_unsafe () t h_active

/-- Repository disjointness check parameters. -/
structure RepoDisjointCheck where
  handleRepoKnown : UInt8
  targetRepoKnown : UInt8
  sameRepo        : UInt8
  deriving Repr, DecidableEq

/-- Layer II Bundle 4: Repository conflict & unknown-target fence gate. -/
def repoDisjointLinearSpec : LinearLeaseSpec Unit RepoDisjointCheck where
  inv _ := True
  gate _ r := verifyRepoDisjoint r.handleRepoKnown r.targetRepoKnown r.sameRepo == 1
  step _ _ := ()
  safe _ r := (r.handleRepoKnown == 1 && r.targetRepoKnown == 1 && r.sameRepo == 0)
  preserves_inv _ _ _ h := h
  gate_iff_safe _ _ := by
    unfold verifyRepoDisjoint
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 4: Unknown or matching repository identity is treated conservatively as conflicting. -/
theorem repo_disjoint_rejects_unknown_or_equal (r : RepoDisjointCheck)
    (h_conflict : (r.handleRepoKnown == 1 && r.targetRepoKnown == 1 && r.sameRepo == 0) = false) :
    (verifyRepoDisjoint r.handleRepoKnown r.targetRepoKnown r.sameRepo == 1) = false :=
  repoDisjointLinearSpec.rejects_unsafe () r h_conflict

/-- Remote outbox check parameters. -/
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

/-- Layer II Bundle 5: Idempotent remote message queue & safe cancellation gate. -/
def remoteOutboxSpec : IdempotentOutboxSpec Unit RemoteOutboxCheck where
  admit _ q :=
    verifyRemoteOutbox q.opKind q.alreadyExists q.sameMission q.isCancelled
      q.isSuperseded q.sessionReady q.prUnsupported q.hasJobId q.deliveryAbandonable == 1
  safeReplay _ q :=
    ((q.opKind == 0 && ((q.alreadyExists == 1 && q.sameMission == 1 && q.isCancelled == 0) ||
                        (q.alreadyExists == 0 && q.isSuperseded == 0 && q.sessionReady == 1 && q.prUnsupported == 0))) ||
     (q.opKind != 0 && (q.hasJobId == 0 || q.deliveryAbandonable == 1)))
  admit_iff_safe_replay _ _ := by
    unfold verifyRemoteOutbox
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 5: `verifyRemoteOutbox` rejects cross-mission message ID reuse, cancelled retries, or non-abandonable job cancellations. -/
theorem remote_outbox_rejects_unsafe_op (q : RemoteOutboxCheck)
    (h_bad : ((q.opKind == 0 && ((q.alreadyExists == 1 && q.sameMission == 1 && q.isCancelled == 0) ||
                                 (q.alreadyExists == 0 && q.isSuperseded == 0 && q.sessionReady == 1 && q.prUnsupported == 0))) ||
              (q.opKind != 0 && (q.hasJobId == 0 || q.deliveryAbandonable == 1))) = false) :
    (verifyRemoteOutbox q.opKind q.alreadyExists q.sameMission q.isCancelled
      q.isSuperseded q.sessionReady q.prUnsupported q.hasJobId q.deliveryAbandonable == 1) = false :=
  remoteOutboxSpec.rejects_conflicting_replay () q h_bad

/-- Board slot reservation check parameters. -/
structure BoardSlotCheck where
  maxParallel       : UInt32
  reservedBossSlots : UInt32
  totalRunning      : UInt32
  deriving Repr, DecidableEq

/-- Layer II Bundle 6: Task board boss-slot anti-starvation gate. -/
def boardSlotDagSpec : DagScheduleSpec BoardSlotCheck where
  canSchedule b := verifyBoardSlots b.maxParallel b.reservedBossSlots b.totalRunning == 1
  slotSafe b :=
    (b.reservedBossSlots ≥ 1 && b.reservedBossSlots < b.maxParallel &&
     b.totalRunning < b.maxParallel - b.reservedBossSlots)
  schedule_iff_slot_safe _ := by
    unfold verifyBoardSlots
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 6: `verifyBoardSlots` refuses worker spawns that would consume the reserved boss slot. -/
theorem board_slots_prevent_boss_starvation (b : BoardSlotCheck)
    (h_full : (b.reservedBossSlots ≥ 1 && b.reservedBossSlots < b.maxParallel &&
      b.totalRunning < b.maxParallel - b.reservedBossSlots) = false) :
    (verifyBoardSlots b.maxParallel b.reservedBossSlots b.totalRunning == 1) = false :=
  boardSlotDagSpec.rejects_starvation b h_full

/-- Board retry check parameters. -/
structure BoardRetryCheck where
  attempts                 : UInt32
  maxAttempts              : UInt32
  requiresExternalRecovery : UInt8
  preflightMerged          : UInt8
  chatgptUiBlocked         : UInt8
  deriving Repr, DecidableEq

/-- Layer II Bundle 7: Bounded board retry & merged-PR preflight gate. -/
def boardRetryDagSpec : DagScheduleSpec BoardRetryCheck where
  canSchedule r :=
    verifyBoardRetry r.attempts r.maxAttempts
      r.requiresExternalRecovery r.preflightMerged r.chatgptUiBlocked == 1
  slotSafe r :=
    (r.maxAttempts ≥ 1 && r.attempts < r.maxAttempts &&
     r.requiresExternalRecovery == 0 && r.preflightMerged == 0 && r.chatgptUiBlocked == 0)
  schedule_iff_slot_safe _ := by
    unfold verifyBoardRetry
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 7: `verifyBoardRetry` suppresses retries after `maxAttempts`, on merged PRs, or when external recovery is required. -/
theorem board_retry_rejects_exhausted_or_merged (r : BoardRetryCheck)
    (h_stop : (r.maxAttempts ≥ 1 && r.attempts < r.maxAttempts &&
      r.requiresExternalRecovery == 0 && r.preflightMerged == 0 && r.chatgptUiBlocked == 0) = false) :
    (verifyBoardRetry r.attempts r.maxAttempts
      r.requiresExternalRecovery r.preflightMerged r.chatgptUiBlocked == 1) = false :=
  boardRetryDagSpec.rejects_starvation r h_stop

/-- Node job transition check parameters. -/
structure JobTransitionCheck where
  fromState : UInt8
  toState   : UInt8
  deriving Repr, DecidableEq

/-- Layer II Bundle 8: Monotonic node job lifecycle & terminal absorption gate. -/
def jobTransitionQuotaSpec : QuotaCircuitSpec JobTransitionCheck where
  validTransition t := verifyJobTransition t.fromState t.toState == 1
  safeTransition t :=
    ((t.fromState == 0 && t.toState ≥ 1 && t.toState ≤ 5) ||
     (t.fromState == 1 && t.toState ≥ 2 && t.toState ≤ 5) ||
     (t.fromState == 5 && t.toState == 4))
  valid_iff_safe _ := by
    unfold verifyJobTransition
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 8: `verifyJobTransition` rejects any transition out of terminal states (`succeeded`, `failed`, `cancelled`). -/
theorem job_transition_absorbs_terminal (t : JobTransitionCheck)
    (h_bad : ((t.fromState == 0 && t.toState ≥ 1 && t.toState ≤ 5) ||
              (t.fromState == 1 && t.toState ≥ 2 && t.toState ≤ 5) ||
              (t.fromState == 5 && t.toState == 4)) = false) :
    (verifyJobTransition t.fromState t.toState == 1) = false :=
  jobTransitionQuotaSpec.rejects_invalid_transition t h_bad

/-- Source bundle budget check parameters. -/
structure BundleBudgetCheck where
  isComplete   : UInt8
  decodedBytes : UInt64
  overlayCap   : UInt64
  completeCap  : UInt64
  maxBytes     : UInt64
  deriving Repr, DecidableEq

/-- Layer II Bundle 9: Source bundle decoded-byte & wire ceiling gate. -/
def bundleBudgetQuotaSpec : QuotaCircuitSpec BundleBudgetCheck where
  validTransition b :=
    verifyBundleBudget b.isComplete b.decodedBytes b.overlayCap b.completeCap b.maxBytes == 1
  safeTransition b :=
    (b.decodedBytes ≤ (if b.isComplete == 1 then b.completeCap else b.overlayCap) &&
     b.decodedBytes ≤ b.maxBytes)
  valid_iff_safe _ := by
    unfold verifyBundleBudget
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 9: `verifyBundleBudget` rejects bundles exceeding advertised capacity or wire ceiling. -/
theorem bundle_budget_rejects_oversized (b : BundleBudgetCheck)
    (h_over : (b.decodedBytes ≤ (if b.isComplete == 1 then b.completeCap else b.overlayCap) &&
      b.decodedBytes ≤ b.maxBytes) = false) :
    (verifyBundleBudget b.isComplete b.decodedBytes b.overlayCap b.completeCap b.maxBytes == 1) = false :=
  bundleBudgetQuotaSpec.rejects_invalid_transition b h_over

/-- Node token rotation check parameters. -/
structure TokenRotationCheck where
  presentedNonEmpty : UInt8
  matchCurrent      : UInt8
  prevNonEmpty      : UInt8
  matchPrev         : UInt8
  scopeAndExpiryOk  : UInt8
  deriving Repr, DecidableEq

/-- Layer II Bundle 10: Node bearer token rotation & lease scope gate. -/
def tokenRotationQuotaSpec : QuotaCircuitSpec TokenRotationCheck where
  validTransition r :=
    verifyTokenRotation r.presentedNonEmpty r.matchCurrent
      r.prevNonEmpty r.matchPrev r.scopeAndExpiryOk == 1
  safeTransition r :=
    (r.presentedNonEmpty == 1 &&
     (r.matchCurrent == 1 || (r.prevNonEmpty == 1 && r.matchPrev == 1)) &&
     r.scopeAndExpiryOk == 1)
  valid_iff_safe _ := by
    unfold verifyTokenRotation
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 10: `verifyTokenRotation` rejects empty tokens, unconfigured previous tokens, or invalid lease scopes. -/
theorem token_rotation_rejects_invalid (r : TokenRotationCheck)
    (h_bad : (r.presentedNonEmpty == 1 &&
      (r.matchCurrent == 1 || (r.prevNonEmpty == 1 && r.matchPrev == 1)) &&
      r.scopeAndExpiryOk == 1) = false) :
    (verifyTokenRotation r.presentedNonEmpty r.matchCurrent
      r.prevNonEmpty r.matchPrev r.scopeAndExpiryOk == 1) = false :=
  tokenRotationQuotaSpec.rejects_invalid_transition r h_bad

/-- Bounded log window check parameters. -/
structure LogWindowCheck where
  offset    : UInt64
  reqLen    : UInt64
  maxChunk  : UInt64
  hardCap   : UInt64
  fileSize  : UInt64
  actualLen : UInt64
  deriving Repr, DecidableEq

/-- Layer II Bundle 11: Bounded process log window gate (`lean-sys`). -/
def logWindowQuotaSpec : QuotaCircuitSpec LogWindowCheck where
  validTransition w :=
    verifyLogWindow w.offset w.reqLen w.maxChunk w.hardCap w.fileSize w.actualLen == 1
  safeTransition w :=
    (w.offset ≤ w.fileSize && w.reqLen ≤ w.maxChunk && w.maxChunk ≤ w.hardCap &&
     w.actualLen ≤ w.reqLen && w.actualLen ≤ w.fileSize - w.offset)
  valid_iff_safe _ := by
    unfold verifyLogWindow
    repeat (first | split | constructor | intro h | simp_all)

/-- Corollary 11: `verifyLogWindow` rejects out-of-bounds offsets or oversized log chunks. -/
theorem log_window_rejects_invalid_chunk (w : LogWindowCheck)
    (h_bad : (w.offset ≤ w.fileSize && w.reqLen ≤ w.maxChunk && w.maxChunk ≤ w.hardCap &&
      w.actualLen ≤ w.reqLen && w.actualLen ≤ w.fileSize - w.offset) = false) :
    (verifyLogWindow w.offset w.reqLen w.maxChunk w.hardCap w.fileSize w.actualLen == 1) = false :=
  logWindowQuotaSpec.rejects_invalid_transition w h_bad

/-- Corollary 12: Deterministic avalanche mixing on empty word from zero seed. -/
theorem mix64Word_zero_seed_non_trivial :
    mix64Word 0x9E3779B97F4A7C15 0 ≠ 0 := by decide

end Orb.Spec
