/-
  Orb.HarnessCloudSpec: Phase R4-A Non-Tautological Specifications & Composition Proofs
  (`0 import Lean`, `0 sorryAx`).

  Proves for the 4 Phase R4-A slices (`CloudTurn`, `HarnessSession`, `ProviderAttempt`, `AuthRefresh`):
    1. Independent two-layer `MetaGateSpec` equivalence (`sound`, `complete`, `posWitness`,
       `negWitness`, `nonVacuous`, `tight`) over decoded protocol ADTs and natural-number invariants.
    2. Layer-I meta-specifications (`StickyFence`, `ClockDiscipline`, `ScopedAuthority`,
       `ReplayIdempotence`).
    3. All `plan.md` §Phase R4-A security & lifecycle obligations:
       - `CloudTurn` (`SM-14`): admits only legal edges across `Queued`, `Submitting`, `Running`,
         `WaitingApproval`, `Uncertain`, `CancelRequested`, `Terminal`; `Uncertain` NEVER starts a
         fresh submission (`StickyFence`); `CancelRequested` reaches `Terminal` ONLY with an
         explicit termination receipt; duplicate `attempt_id` (`proposedAttemptId <= lastAttemptId`)
         is rejected (`ReplayIdempotence`).
       - `HarnessSession` (`SM-15`, `SM-16`, `SM-17`): `Dead` is strictly sticky (`StickyFence`);
         `toolDepth` cannot underflow (`exitToolCall` requires `0 < toolDepth`); `Terminating -> Dead`
         requires a process-termination receipt; generation mismatch fails closed (`ScopedAuthority`).
       - `ProviderAttempt` (`SM-21`): fails closed (`0`) on stale generation (`attemptGeneration != routeGeneration`),
         account-pin mismatch, or active cooldown (`ClockDiscipline`), and forbids transparent reroute
         once `firstByteCommitted == 1` (`StickyFence`).
       - `AuthRefresh` (`SM-21`): fails closed on stale generation, `Revoked` phase (`StickyFence`),
         mismatched CLIProxy login nonce, or missing `fsync` / `flock`.
    4. Pairwise footprint disjointness (both within `R4WorldState` and against R3's `0x01..0x10`
       footprints) and orthogonal `SpecBlock.liftStep` commutativity across `R4WorldState`.
-/
import Orb.HarnessCloud

namespace Orb.HarnessCloudSpec

open Orb.Spec
open Orb.HarnessCloud

private theorem u8_eq_of_toNat (a : UInt8) (n : Nat) (hn : n < 256) (h : a.toNat = n) :
    a = UInt8.ofNat n := by
  apply UInt8.eq_of_toBitVec_eq
  apply BitVec.eq_of_toNat_eq
  have hm : (UInt8.ofNat n).toBitVec.toNat = n := by
    change n % 256 = n
    omega
  change a.toNat = _
  omega

private theorem u64_eq_of_toNat_eq (a b : UInt64) (h : a.toNat = b.toNat) : a = b :=
  UInt64.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)

private theorem u32_eq_of_toNat_eq (a b : UInt32) (h : a.toNat = b.toNat) : a = b :=
  UInt32.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)

private theorem bit_cond_true {b : Bool} (h : ((if b then (1 : UInt8) else 0) == 1) = true) : b = true := by
  cases b
  · contradiction
  · rfl

/-! ## 1. `CloudTurn` (`SM-14`) -/

structure CloudTurnAdmitCheck where
  codes    : UInt8 × UInt8
  receipts : UInt8 × UInt8
  guards   : UInt8 × UInt8
  attempts : UInt64 × UInt64
  handles  : UInt64 × UInt64
  clocks   : UInt64 × UInt64
  deriving Repr, DecidableEq

def CloudTurnAdmitDomainSafe (c : CloudTurnAdmitCheck) : Prop :=
  ∃ ph, CloudTurnPhase.decode? c.codes.1.toNat = some ph ∧ ph.isTerminal = false ∧
    ∃ op, CloudTurnOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .beginSubmit =>
          ph = .queued ∧ 0 < c.attempts.2.toNat ∧ c.attempts.1.toNat < c.attempts.2.toNat ∧
          0 < c.clocks.1.toNat
      | .confirmAccepted =>
          ph = .submitting ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat ∧
          0 < c.handles.1.toNat ∧ c.clocks.1.toNat ≤ c.clocks.2.toNat
      | .rejectPreCommit =>
          ph = .submitting ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat
      | .markUncertain =>
          ph = .submitting ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat
      | .awaitApproval =>
          ph = .running ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat ∧
          0 < c.handles.2.toNat
      | .resolveApproval =>
          ph = .waitingApproval ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat ∧
          c.guards.2.toNat = 1 ∧ 0 < c.handles.2.toNat
      | .bindReconciledTurn =>
          ph = .uncertain ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat ∧
          0 < c.handles.1.toNat
      | .confirmNotDeliveredRetry =>
          ph = .uncertain ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat ∧
          c.guards.1.toNat = 1
      | .requestCancel =>
          (ph = .queued ∨ ph = .running ∨ ph = .waitingApproval) ∧
          0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat
      | .finalizeCancelReceipt =>
          ph = .cancelRequested ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat ∧
          c.receipts.1.toNat = 1
      | .completeTurnReceipt =>
          ph = .running ∧ 0 < c.attempts.1.toNat ∧ c.attempts.2.toNat = c.attempts.1.toNat ∧
          c.receipts.2.toNat = 1

private theorem cloudTurnPhase_code_of_decode {x : UInt8} {ph : CloudTurnPhase}
    (h : CloudTurnPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [CloudTurnPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | k7 <;>
        simp [CloudTurnPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [CloudTurnPhase.encode] using hcode

private theorem cloudTurnOp_code_of_decode {x : UInt8} {op : CloudTurnOp}
    (h : CloudTurnOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [CloudTurnOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | _ | _ | _ | _ | k11 <;>
        simp [CloudTurnOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [CloudTurnOp.encode] using hcode

private theorem u64_pos_of_ne_zero {x : UInt64} (h : x ≠ 0) : 0 < x.toNat := by
  have hne : x.toNat ≠ 0 := fun hz => h (u64_eq_of_toNat_eq x 0 hz)
  omega

private theorem u64_bne_zero_iff_pos (x : UInt64) : ((x != 0) = true) ↔ 0 < x.toNat := by
  rw [bne_iff_ne]
  constructor
  · exact u64_pos_of_ne_zero
  · intro h hz
    subst hz
    simp at h

def cloudTurnMetaGate : MetaGateSpec CloudTurnAdmitCheck CloudTurnAdmitDomainSafe where
  gate c :=
    verifyCloudTurnAdmit
      c.codes.1 c.codes.2 c.receipts.1 c.receipts.2 c.guards.1 c.guards.2
      c.attempts.1 c.attempts.2 c.handles.1 c.handles.2 c.clocks.1 c.clocks.2 == 1
  sound c h := by
    rcases c with
      ⟨⟨phC, opC⟩, ⟨termRec, compRec⟩, ⟨opConf, appRes⟩,
       ⟨lastA, propA⟩, ⟨provId, appId⟩, ⟨subMs, nowMs⟩⟩
    change
      (verifyCloudTurnAdmit phC opC termRec compRec opConf appRes
        lastA propA provId appId subMs nowMs == 1) = true at h
    dsimp [CloudTurnAdmitDomainSafe]
    unfold verifyCloudTurnAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨_, _⟩, hmain⟩
    rcases hmain with h0 | hrest
    · rcases h0 with ⟨⟨⟨⟨hop, hph⟩, hp0⟩, hlt⟩, hs0⟩
      subst hop
      subst hph
      exact ⟨.queued, rfl, rfl, .beginSubmit, rfl, rfl,
        u64_pos_of_ne_zero hp0, UInt64.lt_iff_toNat_lt.mp hlt, u64_pos_of_ne_zero hs0⟩
    · rcases hrest with ⟨⟨⟨_, hl0⟩, hpeq⟩, hbr⟩
      have hlPos := u64_pos_of_ne_zero hl0
      have hpeqN : propA.toNat = lastA.toNat := by rw [hpeq]
      rcases hbr with ((((((((h1 | h2) | h3) | h4) | h5) | h6) | h7) | h8) | h9) | h10
      · rcases h1 with ⟨⟨⟨hop, hph⟩, hpr0⟩, hle⟩
        subst hop
        subst hph
        exact ⟨.submitting, rfl, rfl, .confirmAccepted, rfl, rfl, hlPos, hpeqN,
          u64_pos_of_ne_zero hpr0, UInt64.le_iff_toNat_le.mp hle⟩
      · rcases h2 with ⟨hop, hph⟩
        subst hop
        subst hph
        exact ⟨.submitting, rfl, rfl, .rejectPreCommit, rfl, rfl, hlPos, hpeqN⟩
      · rcases h3 with ⟨hop, hph⟩
        subst hop
        subst hph
        exact ⟨.submitting, rfl, rfl, .markUncertain, rfl, rfl, hlPos, hpeqN⟩
      · rcases h4 with ⟨⟨hop, hph⟩, hap0⟩
        subst hop
        subst hph
        exact ⟨.running, rfl, rfl, .awaitApproval, rfl, rfl, hlPos, hpeqN, u64_pos_of_ne_zero hap0⟩
      · rcases h5 with ⟨⟨⟨hop, hph⟩, har⟩, hap0⟩
        subst hop
        subst hph
        subst har
        exact ⟨.waitingApproval, rfl, rfl, .resolveApproval, rfl, rfl,
          hlPos, hpeqN, rfl, u64_pos_of_ne_zero hap0⟩
      · rcases h6 with ⟨⟨hop, hph⟩, hpr0⟩
        subst hop
        subst hph
        exact ⟨.uncertain, rfl, rfl, .bindReconciledTurn, rfl, rfl, hlPos, hpeqN, u64_pos_of_ne_zero hpr0⟩
      · rcases h7 with ⟨⟨hop, hph⟩, hoc⟩
        subst hop
        subst hph
        subst hoc
        exact ⟨.uncertain, rfl, rfl, .confirmNotDeliveredRetry, rfl, rfl, hlPos, hpeqN, rfl⟩
      · rcases h8 with ⟨hop, (hph | hph) | hph⟩ <;> subst hop <;> subst hph
        · exact ⟨.queued, rfl, rfl, .requestCancel, rfl, Or.inl rfl, hlPos, hpeqN⟩
        · exact ⟨.running, rfl, rfl, .requestCancel, rfl, Or.inr (Or.inl rfl), hlPos, hpeqN⟩
        · exact ⟨.waitingApproval, rfl, rfl, .requestCancel, rfl, Or.inr (Or.inr rfl), hlPos, hpeqN⟩
      · rcases h9 with ⟨⟨hop, hph⟩, htr⟩
        subst hop
        subst hph
        subst htr
        exact ⟨.cancelRequested, rfl, rfl, .finalizeCancelReceipt, rfl, rfl, hlPos, hpeqN, rfl⟩
      · rcases h10 with ⟨⟨hop, hph⟩, hcr⟩
        subst hop
        subst hph
        subst hcr
        exact ⟨.running, rfl, rfl, .completeTurnReceipt, rfl, rfl, hlPos, hpeqN, rfl⟩
  complete c h := by
    rcases c with
      ⟨⟨phC, opC⟩, ⟨termRec, compRec⟩, ⟨opConf, appRes⟩,
       ⟨lastA, propA⟩, ⟨provId, appId⟩, ⟨subMs, nowMs⟩⟩
    change
      (verifyCloudTurnAdmit phC opC termRec compRec opConf appRes
        lastA propA provId appId subMs nowMs == 1) = true
    dsimp [CloudTurnAdmitDomainSafe] at h
    rcases h with ⟨ph, hphDec, _, op, hopDec, hbr⟩
    have hphC := cloudTurnPhase_code_of_decode hphDec
    have hopC := cloudTurnOp_code_of_decode hopDec
    subst hphC; subst hopC
    unfold verifyCloudTurnAdmit
    cases op with
    | beginSubmit =>
      rcases hbr with ⟨rfl, hpPos, hlt, hsPos⟩
      have hpN := (u64_bne_zero_iff_pos _).mpr hpPos
      have hsN := (u64_bne_zero_iff_pos _).mpr hsPos
      have hltB : lastA < propA := UInt64.lt_iff_toNat_lt.mpr hlt
      simp [CloudTurnPhase.encode, CloudTurnOp.encode, hpN, hsN, hltB]
    | confirmAccepted =>
      rcases hbr with ⟨rfl, hlPos, heq, hprPos, hle⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have hprN := (u64_bne_zero_iff_pos _).mpr hprPos
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      have hleB : subMs ≤ nowMs := UInt64.le_iff_toNat_le.mpr hle
      subst heqB; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN, hprN, hleB]
    | rejectPreCommit =>
      rcases hbr with ⟨rfl, hlPos, heq⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN]
    | markUncertain =>
      rcases hbr with ⟨rfl, hlPos, heq⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN]
    | awaitApproval =>
      rcases hbr with ⟨rfl, hlPos, heq, hapPos⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have hapN := (u64_bne_zero_iff_pos _).mpr hapPos
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN, hapN]
    | resolveApproval =>
      rcases hbr with ⟨rfl, hlPos, heq, har, hapPos⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have hapN := (u64_bne_zero_iff_pos _).mpr hapPos
      have har1 : appRes = 1 := u8_eq_of_toNat appRes 1 (by omega) har
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; subst har1; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN, hapN]
    | bindReconciledTurn =>
      rcases hbr with ⟨rfl, hlPos, heq, hprPos⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have hprN := (u64_bne_zero_iff_pos _).mpr hprPos
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN, hprN]
    | confirmNotDeliveredRetry =>
      rcases hbr with ⟨rfl, hlPos, heq, hoc⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have hoc1 : opConf = 1 := u8_eq_of_toNat opConf 1 (by omega) hoc
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; subst hoc1; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN]
    | requestCancel =>
      rcases hbr with ⟨hph, hlPos, heq⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB
      rcases hph with rfl | rfl | rfl <;> simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN]
    | finalizeCancelReceipt =>
      rcases hbr with ⟨rfl, hlPos, heq, htr⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have htr1 : termRec = 1 := u8_eq_of_toNat termRec 1 (by omega) htr
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; subst htr1; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN]
    | completeTurnReceipt =>
      rcases hbr with ⟨rfl, hlPos, heq, hcr⟩
      have hlN := (u64_bne_zero_iff_pos _).mpr hlPos
      have hcr1 : compRec = 1 := u8_eq_of_toNat compRec 1 (by omega) hcr
      have heqB : propA = lastA := u64_eq_of_toNat_eq propA lastA heq
      subst heqB; subst hcr1; simp [CloudTurnPhase.encode, CloudTurnOp.encode, hlN]
  posWitness :=
    { codes := (0, 0), receipts := (0, 0), guards := (0, 0)
      attempts := (0, 1), handles := (0, 0), clocks := (100, 100) }
  negWitness :=
    { codes := (4, 0), receipts := (0, 0), guards := (0, 0)
      attempts := (1, 2), handles := (0, 0), clocks := (100, 100) }
  nonVacuous := by decide
  tight := by decide

private theorem cloudTurn_terminal_step_id (s : CloudTurnSliceState) (ev : CloudTurnSliceEvent)
    (hf : decide (6 ≤ s.phaseCode) = true) :
    stepCloudTurnSlice s ev = (s, []) := by
  unfold stepCloudTurnSlice
  have hadmFalse :
      ¬ (verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
          ev.operatorConfirmedNotDelivered ev.approvalResolved
          s.lastAttemptId ev.proposedAttemptId
          (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
          (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs)
          ev.nowMs == 1) := by
    intro hc
    unfold verifyCloudTurnAdmit at hc
    have hb := bit_cond_true hc
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hb hf
    have hle5 : s.phaseCode.toNat ≤ 5 := UInt8.le_iff_toNat_le.mp hb.1.1
    have hge6 : 6 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hf
    omega
  dsimp only
  exact ite_eq_right_iff.mpr (fun hc => absurd hc hadmFalse)

def cloudTurnTerminalStickyFence : StickyFence CloudTurnSliceState CloudTurnSliceEvent where
  fenced s := decide (6 ≤ s.phaseCode)
  preFenceAct s := s.phaseCode == 1
  step s ev := (stepCloudTurnSlice s ev).1
  sticky s ev hf := by
    rw [cloudTurn_terminal_step_id s ev hf]
    exact hf
  forbids_post s ev hf := by
    rw [cloudTurn_terminal_step_id s ev hf]
    simp only [decide_eq_true_eq] at hf
    have hge6 : 6 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hf
    apply beq_eq_false_iff_ne.mpr
    intro heq
    have : s.phaseCode.toNat = 1 := by rw [heq]; decide
    omega

/-- `StickyFence` over unreconciled cloud submission uncertainty (`SM-14`):
    until operator reconciliation (`opCode == 6` or `7`), `Uncertain` (`phaseCode == 4`) stays
    `Uncertain` and NEVER enters `Submitting` (`phaseCode == 1`). Even on reconciliation events,
    one step from `Uncertain` NEVER enters `Submitting` (`phaseCode == 1`). -/
def cloudTurnUncertainNoFreshSubmitFence :
    StickyFence CloudTurnSliceState { ev : CloudTurnSliceEvent // ev.opCode != 6 && ev.opCode != 7 } where
  fenced s := s.phaseCode == 4
  preFenceAct s := s.phaseCode == 1
  step s ev := (stepCloudTurnSlice s ev.val).1
  sticky s ev hf := by
    rcases ev with ⟨ev, hnoRec⟩
    have hph4 : s.phaseCode = 4 := by rw [beq_iff_eq] at hf; exact hf
    unfold stepCloudTurnSlice
    have hadmFalse :
        ¬ (verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
            ev.operatorConfirmedNotDelivered ev.approvalResolved
            s.lastAttemptId ev.proposedAttemptId
            (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
            (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
            (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs)
            ev.nowMs == 1) := by
      intro hc
      have hs := cloudTurnMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          receipts := (ev.hasTerminationReceipt, ev.hasCompletionReceipt)
          guards := (ev.operatorConfirmedNotDelivered, ev.approvalResolved)
          attempts := (s.lastAttemptId, ev.proposedAttemptId)
          handles := (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId,
                      if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          clocks := (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs, ev.nowMs) }
        (by simpa [cloudTurnMetaGate] using hc)
      dsimp [CloudTurnAdmitDomainSafe] at hs
      rcases hs with ⟨ph, hphDec, _, op, hopDec, hbr⟩
      rw [hph4] at hphDec
      simp [CloudTurnPhase.decode?] at hphDec
      subst hphDec
      simp only [Bool.and_eq_true, bne_iff_ne] at hnoRec
      have hopCode := cloudTurnOp_code_of_decode hopDec
      cases op <;> simp [CloudTurnOp.encode] at hbr hopCode
      · exact hnoRec.1 hopCode
      · exact hnoRec.2 hopCode
    dsimp only
    rw [ite_eq_right_iff.mpr (fun hc => absurd hc hadmFalse)]
    exact hf
  forbids_post s ev hf := by
    rcases ev with ⟨ev, hnoRec⟩
    have hph4 : s.phaseCode = 4 := by rw [beq_iff_eq] at hf; exact hf
    unfold stepCloudTurnSlice
    have hadmFalse :
        ¬ (verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
            ev.operatorConfirmedNotDelivered ev.approvalResolved
            s.lastAttemptId ev.proposedAttemptId
            (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
            (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
            (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs)
            ev.nowMs == 1) := by
      intro hc
      have hs := cloudTurnMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          receipts := (ev.hasTerminationReceipt, ev.hasCompletionReceipt)
          guards := (ev.operatorConfirmedNotDelivered, ev.approvalResolved)
          attempts := (s.lastAttemptId, ev.proposedAttemptId)
          handles := (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId,
                      if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          clocks := (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs, ev.nowMs) }
        (by simpa [cloudTurnMetaGate] using hc)
      dsimp [CloudTurnAdmitDomainSafe] at hs
      rcases hs with ⟨ph, hphDec, _, op, hopDec, hbr⟩
      rw [hph4] at hphDec
      simp [CloudTurnPhase.decode?] at hphDec
      subst hphDec
      simp only [Bool.and_eq_true, bne_iff_ne] at hnoRec
      have hopCode := cloudTurnOp_code_of_decode hopDec
      cases op <;> simp [CloudTurnOp.encode] at hbr hopCode
      · exact hnoRec.1 hopCode
      · exact hnoRec.2 hopCode
    dsimp only
    rw [ite_eq_right_iff.mpr (fun hc => absurd hc hadmFalse), hph4]
    decide

def cloudTurnDuplicateAttemptReplayIdempotence :
    ReplayIdempotence CloudTurnSliceState CloudTurnSliceEvent CloudTurnEffect where
  step := stepCloudTurnSlice
  alreadyAcked s ev := ev.opCode == 0 && decide (ev.proposedAttemptId ≤ s.lastAttemptId)
  idempotent s ev h := by
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at h
    rcases h with ⟨hop0, hle⟩
    unfold stepCloudTurnSlice
    have hadmFalse :
        ¬ (verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
            ev.operatorConfirmedNotDelivered ev.approvalResolved
            s.lastAttemptId ev.proposedAttemptId
            (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
            (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
            (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs)
            ev.nowMs == 1) := by
      intro hc
      have hs := cloudTurnMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          receipts := (ev.hasTerminationReceipt, ev.hasCompletionReceipt)
          guards := (ev.operatorConfirmedNotDelivered, ev.approvalResolved)
          attempts := (s.lastAttemptId, ev.proposedAttemptId)
          handles := (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId,
                      if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          clocks := (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs, ev.nowMs) }
        (by simpa [cloudTurnMetaGate] using hc)
      dsimp [CloudTurnAdmitDomainSafe] at hs
      rcases hs with ⟨_, _, _, op, hopDec, hbr⟩
      rw [hop0] at hopDec
      simp [CloudTurnOp.decode?] at hopDec
      subst hopDec
      rcases hbr with ⟨_, _, hlt, _⟩
      have hleN : ev.proposedAttemptId.toNat ≤ s.lastAttemptId.toNat := UInt64.le_iff_toNat_le.mp hle
      omega
    dsimp only
    exact ite_eq_right_iff.mpr (fun hc => absurd hc hadmFalse)

/-- Deductive R4-A theorem (`SM-14`):
    1. From `Uncertain` (`phaseCode = 4`), NO single event ever transitions to `Submitting` (`phaseCode = 1`)
       or emits `dispatchProviderSubmit`.
    2. From `CancelRequested` (`phaseCode = 5`), ANY admitted transition reaches `Terminal` (`6`)
       via `finalizeCancelReceipt` (`opCode = 9`) and requires `hasTerminationReceipt = 1`.
    3. `beginSubmit` (`opCode = 0`) with a duplicate/stale `attempt_id` (`proposedAttemptId <= lastAttemptId`)
       is unconditionally rejected (`0`). -/
theorem cloudTurn_uncertain_no_submit_cancel_requires_receipt_and_dup_rejected
    (s : CloudTurnSliceState) (ev : CloudTurnSliceEvent) :
    (s.phaseCode = 4 →
      (stepCloudTurnSlice s ev).1.phaseCode ≠ 1 ∧
      ∀ a ts, CloudTurnEffect.dispatchProviderSubmit a ts ∉ (stepCloudTurnSlice s ev).2) ∧
    (s.phaseCode = 5 →
      verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
        ev.operatorConfirmedNotDelivered ev.approvalResolved
        s.lastAttemptId ev.proposedAttemptId
        (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
        (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
        (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs)
        ev.nowMs = 1 →
      ev.opCode = 9 ∧ ev.hasTerminationReceipt = 1 ∧ (stepCloudTurnSlice s ev).1.phaseCode = 6) ∧
    (ev.opCode = 0 → ev.proposedAttemptId ≤ s.lastAttemptId →
      verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
        ev.operatorConfirmedNotDelivered ev.approvalResolved
        s.lastAttemptId ev.proposedAttemptId ev.reqProviderTurnId s.approvalReqId
        ev.reqSubmittedAtMs ev.nowMs = 0) := by
  refine ⟨?_, ?_, ?_⟩
  · intro hph4
    unfold stepCloudTurnSlice
    dsimp only
    by_cases hadm :
        (verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
          ev.operatorConfirmedNotDelivered ev.approvalResolved
          s.lastAttemptId ev.proposedAttemptId
          (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
          (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs)
          ev.nowMs == 1) = true
    · have hs := cloudTurnMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          receipts := (ev.hasTerminationReceipt, ev.hasCompletionReceipt)
          guards := (ev.operatorConfirmedNotDelivered, ev.approvalResolved)
          attempts := (s.lastAttemptId, ev.proposedAttemptId)
          handles := (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId,
                      if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          clocks := (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs, ev.nowMs) }
        (by simpa [cloudTurnMetaGate] using hadm)
      dsimp [CloudTurnAdmitDomainSafe] at hs
      rcases hs with ⟨ph, hphDec, _, op, hopDec, hbr⟩
      rw [hph4] at hphDec
      simp [CloudTurnPhase.decode?] at hphDec
      subst hphDec
      have hopC := cloudTurnOp_code_of_decode hopDec
      cases op <;> simp [CloudTurnOp.encode] at hbr hopC
      · rw [ite_eq_left_of_eq_true _ _ (eq_true hadm), hopC]; simp [cloudTurnTargetPhase]
      · rw [ite_eq_left_of_eq_true _ _ (eq_true hadm), hopC]; simp [cloudTurnTargetPhase]
    · rw [ite_eq_right_of_eq_false _ _ (eq_false hadm), hph4]
      exact ⟨by decide, fun _ _ hm => List.not_mem_nil hm⟩
  · intro hph5 hadm1
    have hgate : cloudTurnMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          receipts := (ev.hasTerminationReceipt, ev.hasCompletionReceipt)
          guards := (ev.operatorConfirmedNotDelivered, ev.approvalResolved)
          attempts := (s.lastAttemptId, ev.proposedAttemptId)
          handles := (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId,
                      if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          clocks := (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs, ev.nowMs) } = true := by
      simpa [cloudTurnMetaGate] using hadm1
    have hs := cloudTurnMetaGate.sound _ hgate
    dsimp [CloudTurnAdmitDomainSafe] at hs
    rcases hs with ⟨ph, hphDec, _, op, hopDec, hbr⟩
    rw [hph5] at hphDec
    simp [CloudTurnPhase.decode?] at hphDec
    subst hphDec
    have hopC := cloudTurnOp_code_of_decode hopDec
    cases op <;> simp [CloudTurnOp.encode] at hbr hopC
    rcases hbr with ⟨_, _, htr⟩
    have htr1 : ev.hasTerminationReceipt = 1 := u8_eq_of_toNat _ 1 (by omega) htr
    refine ⟨hopC, htr1, ?_⟩
    unfold stepCloudTurnSlice
    dsimp only
    have hadmB :
        (verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
          ev.operatorConfirmedNotDelivered ev.approvalResolved
          s.lastAttemptId ev.proposedAttemptId
          (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
          (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
          (if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs)
          ev.nowMs == 1) = true := by rw [hadm1]; rfl
    rw [ite_eq_left_of_eq_true _ _ (eq_true hadmB), hopC]
    rfl
  · intro hop0 hle
    unfold verifyCloudTurnAdmit
    rw [hop0]
    have hnotLt : ¬ (s.lastAttemptId < ev.proposedAttemptId) := by
      intro hlt
      have a := UInt64.le_iff_toNat_le.mp hle
      have b := UInt64.lt_iff_toNat_lt.mp hlt
      omega
    simp [hnotLt]

/-! ## 2. `HarnessSession` (`SM-15`, `SM-16`, `SM-17`) -/

structure HarnessSessionAdmitCheck where
  codes   : UInt8 × UInt8
  steer   : UInt8
  receipt : UInt8 × UInt8
  depth   : UInt32
  gens    : UInt64 × UInt64
  deriving Repr, DecidableEq

def HarnessSessionAdmitDomainSafe (c : HarnessSessionAdmitCheck) : Prop :=
  c.steer.toNat ≤ 1 ∧
  0 < c.gens.1.toNat ∧
  c.gens.2.toNat = c.gens.1.toNat ∧
  ∃ ph, HarnessSessionPhase.decode? c.codes.1.toNat = some ph ∧ ph.isDead = false ∧
    ∃ op, HarnessSessionOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .confirmReady => ph = .starting
      | .beginTurn => ph = .ready ∧ c.depth.toNat = 0 ∧ c.steer.toNat = 0
      | .enterToolCall => ph = .inTurn ∧ c.depth.toNat < 4294967295
      | .exitToolCall => ph = .inTurn ∧ 0 < c.depth.toNat
      | .queueSteer => ph = .inTurn ∧ c.steer.toNat = 0
      | .flushSteerBetweenTools => ph = .inTurn ∧ c.depth.toNat = 0 ∧ c.steer.toNat = 1
      | .finishTurnToReady =>
          ph = .inTurn ∧ c.depth.toNat = 0 ∧ c.steer.toNat = 0 ∧ c.receipt.1.toNat = 1
      | .parkSession => ph = .ready ∧ c.depth.toNat = 0 ∧ c.steer.toNat = 0
      | .wakeParkedSession => ph = .parked ∧ c.depth.toNat = 0 ∧ c.steer.toNat = 0
      | .beginTerminate => ph = .starting ∨ ph = .ready ∨ ph = .inTurn ∨ ph = .parked
      | .confirmProcessDead => ph = .terminating ∧ c.receipt.2.toNat = 1

private theorem harnessPhase_code_of_decode {x : UInt8} {ph : HarnessSessionPhase}
    (h : HarnessSessionPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [HarnessSessionPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | k6 <;>
        simp [HarnessSessionPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [HarnessSessionPhase.encode] using hcode

private theorem harnessOp_code_of_decode {x : UInt8} {op : HarnessSessionOp}
    (h : HarnessSessionOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [HarnessSessionOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | _ | _ | _ | _ | k11 <;>
        simp [HarnessSessionOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [HarnessSessionOp.encode] using hcode

def harnessSessionMetaGate : MetaGateSpec HarnessSessionAdmitCheck HarnessSessionAdmitDomainSafe where
  gate c :=
    verifyHarnessSessionAdmit
      c.codes.1 c.codes.2 c.steer c.receipt.1 c.receipt.2 c.depth c.gens.1 c.gens.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, st, ⟨idleR, exitR⟩, dep, ⟨sGen, eGen⟩⟩
    change (verifyHarnessSessionAdmit phC opC st idleR exitR dep sGen eGen == 1) = true at h
    dsimp [HarnessSessionAdmitDomainSafe]
    unfold verifyHarnessSessionAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨_, _⟩, hstLe1⟩, hs0⟩, heq⟩, hbr⟩
    have hsPos := u64_pos_of_ne_zero hs0
    have heqN : eGen.toNat = sGen.toNat := by rw [heq]
    refine ⟨UInt8.le_iff_toNat_le.mp hstLe1, hsPos, heqN, ?_⟩
    rcases hbr with (((((((((h0 | h1) | h2) | h3) | h4) | h5) | h6) | h7) | h8) | h9) | h10
    · rcases h0 with ⟨hop, hph⟩
      subst hop
      subst hph
      exact ⟨.starting, rfl, rfl, .confirmReady, rfl, rfl⟩
    · rcases h1 with ⟨⟨⟨hop, hph⟩, hd0⟩, hst0⟩
      subst hop
      subst hph
      subst hd0
      subst hst0
      exact ⟨.ready, rfl, rfl, .beginTurn, rfl, rfl, rfl, rfl⟩
    · rcases h2 with ⟨⟨hop, hph⟩, hdLt⟩
      subst hop
      subst hph
      exact ⟨.inTurn, rfl, rfl, .enterToolCall, rfl, rfl, UInt32.lt_iff_toNat_lt.mp hdLt⟩
    · rcases h3 with ⟨⟨hop, hph⟩, hdPos⟩
      subst hop
      subst hph
      exact ⟨.inTurn, rfl, rfl, .exitToolCall, rfl, rfl, UInt32.lt_iff_toNat_lt.mp hdPos⟩
    · rcases h4 with ⟨⟨hop, hph⟩, hst0⟩
      subst hop
      subst hph
      subst hst0
      exact ⟨.inTurn, rfl, rfl, .queueSteer, rfl, rfl, rfl⟩
    · rcases h5 with ⟨⟨⟨hop, hph⟩, hd0⟩, hst1⟩
      subst hop
      subst hph
      subst hd0
      subst hst1
      exact ⟨.inTurn, rfl, rfl, .flushSteerBetweenTools, rfl, rfl, rfl, rfl⟩
    · rcases h6 with ⟨⟨⟨⟨hop, hph⟩, hd0⟩, hst0⟩, hidle⟩
      subst hop
      subst hph
      subst hd0
      subst hst0
      subst hidle
      exact ⟨.inTurn, rfl, rfl, .finishTurnToReady, rfl, rfl, rfl, rfl, rfl⟩
    · rcases h7 with ⟨⟨⟨hop, hph⟩, hd0⟩, hst0⟩
      subst hop
      subst hph
      subst hd0
      subst hst0
      exact ⟨.ready, rfl, rfl, .parkSession, rfl, rfl, rfl, rfl⟩
    · rcases h8 with ⟨⟨⟨hop, hph⟩, hd0⟩, hst0⟩
      subst hop
      subst hph
      subst hd0
      subst hst0
      exact ⟨.parked, rfl, rfl, .wakeParkedSession, rfl, rfl, rfl, rfl⟩
    · rcases h9 with ⟨hop, ((hph | hph) | hph) | hph⟩ <;> subst hop <;> subst hph
      · exact ⟨.starting, rfl, rfl, .beginTerminate, rfl, Or.inl rfl⟩
      · exact ⟨.ready, rfl, rfl, .beginTerminate, rfl, Or.inr (Or.inl rfl)⟩
      · exact ⟨.inTurn, rfl, rfl, .beginTerminate, rfl, Or.inr (Or.inr (Or.inl rfl))⟩
      · exact ⟨.parked, rfl, rfl, .beginTerminate, rfl, Or.inr (Or.inr (Or.inr rfl))⟩
    · rcases h10 with ⟨⟨hop, hph⟩, hexit⟩
      subst hop
      subst hph
      subst hexit
      exact ⟨.terminating, rfl, rfl, .confirmProcessDead, rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, st, ⟨idleR, exitR⟩, dep, ⟨sGen, eGen⟩⟩
    change (verifyHarnessSessionAdmit phC opC st idleR exitR dep sGen eGen == 1) = true
    dsimp [HarnessSessionAdmitDomainSafe] at h
    rcases h with ⟨hstLe, hsPos, heq, ph, hphDec, _, op, hopDec, hbr⟩
    have hstB : st ≤ 1 := UInt8.le_iff_toNat_le.mpr hstLe
    have hsN := (u64_bne_zero_iff_pos _).mpr hsPos
    have heqB : eGen = sGen := u64_eq_of_toNat_eq eGen sGen heq
    have hphC := harnessPhase_code_of_decode hphDec
    have hopC := harnessOp_code_of_decode hopDec
    subst heqB; subst hphC; subst hopC
    unfold verifyHarnessSessionAdmit
    cases op with
    | confirmReady =>
      subst hbr; simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hstB, hsN]
    | beginTurn =>
      rcases hbr with ⟨rfl, hd0, hst0⟩
      have hd0B : dep = 0 := u32_eq_of_toNat_eq dep 0 hd0
      have hst0B : st = 0 := u8_eq_of_toNat st 0 (by omega) hst0
      subst hd0B; subst hst0B
      simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hsN]
    | enterToolCall =>
      rcases hbr with ⟨rfl, hdLt⟩
      have hdLtB : dep < 0xFFFFFFFF := UInt32.lt_iff_toNat_lt.mpr hdLt
      simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hstB, hsN, hdLtB]
    | exitToolCall =>
      rcases hbr with ⟨rfl, hdPos⟩
      have hdPosB : 0 < dep := UInt32.lt_iff_toNat_lt.mpr hdPos
      simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hstB, hsN, hdPosB]
    | queueSteer =>
      rcases hbr with ⟨rfl, hst0⟩
      have hst0B : st = 0 := u8_eq_of_toNat st 0 (by omega) hst0
      subst hst0B; simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hsN]
    | flushSteerBetweenTools =>
      rcases hbr with ⟨rfl, hd0, hst1⟩
      have hd0B : dep = 0 := u32_eq_of_toNat_eq dep 0 hd0
      have hst1B : st = 1 := u8_eq_of_toNat st 1 (by omega) hst1
      subst hd0B; subst hst1B
      simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hsN]
    | finishTurnToReady =>
      rcases hbr with ⟨rfl, hd0, hst0, hidle⟩
      have hd0B : dep = 0 := u32_eq_of_toNat_eq dep 0 hd0
      have hst0B : st = 0 := u8_eq_of_toNat st 0 (by omega) hst0
      have hidleB : idleR = 1 := u8_eq_of_toNat idleR 1 (by omega) hidle
      subst hd0B; subst hst0B; subst hidleB
      simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hsN]
    | parkSession =>
      rcases hbr with ⟨rfl, hd0, hst0⟩
      have hd0B : dep = 0 := u32_eq_of_toNat_eq dep 0 hd0
      have hst0B : st = 0 := u8_eq_of_toNat st 0 (by omega) hst0
      subst hd0B; subst hst0B
      simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hsN]
    | wakeParkedSession =>
      rcases hbr with ⟨rfl, hd0, hst0⟩
      have hd0B : dep = 0 := u32_eq_of_toNat_eq dep 0 hd0
      have hst0B : st = 0 := u8_eq_of_toNat st 0 (by omega) hst0
      subst hd0B; subst hst0B
      simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hsN]
    | beginTerminate =>
      rcases hbr with rfl | rfl | rfl | rfl <;>
        simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hstB, hsN]
    | confirmProcessDead =>
      rcases hbr with ⟨rfl, hexit⟩
      have hexitB : exitR = 1 := u8_eq_of_toNat exitR 1 (by omega) hexit
      subst hexitB; simp [HarnessSessionPhase.encode, HarnessSessionOp.encode, hstB, hsN]
  posWitness :=
    { codes := (4, 10), steer := 0, receipt := (0, 1), depth := 0, gens := (3, 3) }
  negWitness :=
    { codes := (4, 10), steer := 0, receipt := (0, 0), depth := 0, gens := (3, 3) }
  nonVacuous := by decide
  tight := by decide

private theorem harnessSession_dead_step_id (s : HarnessSessionSliceState) (ev : HarnessSessionSliceEvent)
    (hf : decide (5 ≤ s.phaseCode) = true) :
    stepHarnessSessionSlice s ev = (s, []) := by
  unfold stepHarnessSessionSlice
  have hadmFalse :
      ¬ (verifyHarnessSessionAdmit s.phaseCode ev.opCode s.steerPending
          ev.hasTurnIdleReceipt ev.hasProcExitReceipt
          s.toolDepth s.sessionGeneration ev.eventGeneration == 1) := by
    intro hc
    unfold verifyHarnessSessionAdmit at hc
    have hb := bit_cond_true hc
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hb hf
    have hle4 : s.phaseCode.toNat ≤ 4 := UInt8.le_iff_toNat_le.mp hb.1.1.1.1.1
    have hge5 : 5 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hf
    omega
  exact ite_eq_right_iff.mpr (fun hc => absurd hc hadmFalse)

def harnessSessionDeadStickyFence : StickyFence HarnessSessionSliceState HarnessSessionSliceEvent where
  fenced s := decide (5 ≤ s.phaseCode)
  preFenceAct s := decide (s.phaseCode ≤ 3)
  step s ev := (stepHarnessSessionSlice s ev).1
  sticky s ev hf := by
    rw [harnessSession_dead_step_id s ev hf]
    exact hf
  forbids_post s ev hf := by
    rw [harnessSession_dead_step_id s ev hf]
    simp only [decide_eq_true_eq] at hf
    have hge5 : 5 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hf
    apply decide_eq_false_iff_not.mpr
    intro hle3
    have hleN : s.phaseCode.toNat ≤ 3 := UInt8.le_iff_toNat_le.mp hle3
    omega

def harnessSessionGenerationAuthority : ScopedAuthority HarnessSessionAdmitCheck where
  admit c := harnessSessionMetaGate.gate c
  scopeValid c := c.gens.1 != 0 && c.gens.2 == c.gens.1
  sound c h := by
    have hs := harnessSessionMetaGate.sound c h
    rcases c with ⟨_, _, _, _, ⟨sGen, eGen⟩⟩
    rcases hs with ⟨_, hsPos, heq, _⟩
    have hsN := (u64_bne_zero_iff_pos _).mpr hsPos
    have heqB : eGen = sGen := u64_eq_of_toNat_eq eGen sGen heq
    simp [hsN, heqB]

/-- Deductive R4-A theorem (`SM-15`, `SM-16`, `SM-17`):
    1. `exitToolCall` (`opCode = 3`) is rejected when `toolDepth = 0` and decrements by exact `1`
       without `UInt32` underflow when admitted.
    2. Reaching `Dead` (`phaseCode = 5`) from `Terminating` (`phaseCode = 4`) requires
       `opCode = 10` (`confirmProcessDead`) and `hasProcExitReceipt = 1`.
    3. Any generation mismatch (`eventGeneration ≠ sessionGeneration`) fails closed (`(s, [])`). -/
theorem harnessSession_tool_depth_no_underflow_dead_requires_receipt_and_gen_fenced
    (s : HarnessSessionSliceState) (ev : HarnessSessionSliceEvent) :
    (ev.opCode = 3 → s.toolDepth = 0 →
      verifyHarnessSessionAdmit s.phaseCode ev.opCode s.steerPending
        ev.hasTurnIdleReceipt ev.hasProcExitReceipt
        s.toolDepth s.sessionGeneration ev.eventGeneration = 0) ∧
    (ev.opCode = 3 →
      verifyHarnessSessionAdmit s.phaseCode ev.opCode s.steerPending
        ev.hasTurnIdleReceipt ev.hasProcExitReceipt
        s.toolDepth s.sessionGeneration ev.eventGeneration = 1 →
      0 < s.toolDepth.toNat ∧
      (stepHarnessSessionSlice s ev).1.toolDepth.toNat + 1 = s.toolDepth.toNat) ∧
    (s.phaseCode = 4 →
      verifyHarnessSessionAdmit s.phaseCode ev.opCode s.steerPending
        ev.hasTurnIdleReceipt ev.hasProcExitReceipt
        s.toolDepth s.sessionGeneration ev.eventGeneration = 1 →
      ev.opCode = 10 ∧ ev.hasProcExitReceipt = 1 ∧ (stepHarnessSessionSlice s ev).1.phaseCode = 5) ∧
    (ev.eventGeneration ≠ s.sessionGeneration → stepHarnessSessionSlice s ev = (s, [])) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro hop3 hd0
    unfold verifyHarnessSessionAdmit
    rw [hop3, hd0]
    simp
  · intro hop3 hadm1
    have hgate : harnessSessionMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          steer := s.steerPending
          receipt := (ev.hasTurnIdleReceipt, ev.hasProcExitReceipt)
          depth := s.toolDepth
          gens := (s.sessionGeneration, ev.eventGeneration) } = true := by
      simpa [harnessSessionMetaGate] using hadm1
    have hs := harnessSessionMetaGate.sound _ hgate
    dsimp [HarnessSessionAdmitDomainSafe] at hs
    rcases hs with ⟨_, _, _, _, _, _, op, hopDec, hbr⟩
    rw [hop3] at hopDec
    simp [HarnessSessionOp.decode?] at hopDec
    subst hopDec
    rcases hbr with ⟨_, hdPos⟩
    refine ⟨hdPos, ?_⟩
    unfold stepHarnessSessionSlice
    have hadmB :
        (verifyHarnessSessionAdmit s.phaseCode ev.opCode s.steerPending
          ev.hasTurnIdleReceipt ev.hasProcExitReceipt
          s.toolDepth s.sessionGeneration ev.eventGeneration == 1) = true := by rw [hadm1]; rfl
    rw [ite_eq_left_of_eq_true _ _ (eq_true hadmB), hop3]
    have h1 : (1 : UInt32).toNat = 1 := rfl
    have hge1 : (1 : UInt32) ≤ s.toolDepth := UInt32.le_iff_toNat_le.mpr (by rw [h1]; omega)
    have hsub : (s.toolDepth - 1).toNat = s.toolDepth.toNat - 1 := by
      simpa [h1] using UInt32.toNat_sub_of_le s.toolDepth 1 hge1
    change (if ((3 : UInt8) == 2) = true then s.toolDepth + 1
            else if ((3 : UInt8) == 3) = true then s.toolDepth - 1
            else if ((3 : UInt8) == 9 || (3 : UInt8) == 10) = true then 0 else s.toolDepth).toNat + 1 =
           s.toolDepth.toNat
    have heval :
        (if ((3 : UInt8) == 2) = true then s.toolDepth + 1
         else if ((3 : UInt8) == 3) = true then s.toolDepth - 1
         else if ((3 : UInt8) == 9 || (3 : UInt8) == 10) = true then 0 else s.toolDepth) =
        s.toolDepth - 1 := by simp
    rw [heval, hsub]
    omega
  · intro hph4 hadm1
    have hgate : harnessSessionMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          steer := s.steerPending
          receipt := (ev.hasTurnIdleReceipt, ev.hasProcExitReceipt)
          depth := s.toolDepth
          gens := (s.sessionGeneration, ev.eventGeneration) } = true := by
      simpa [harnessSessionMetaGate] using hadm1
    have hs := harnessSessionMetaGate.sound _ hgate
    dsimp [HarnessSessionAdmitDomainSafe] at hs
    rcases hs with ⟨_, _, _, ph, hphDec, _, op, hopDec, hbr⟩
    rw [hph4] at hphDec
    simp [HarnessSessionPhase.decode?] at hphDec
    subst hphDec
    have hopC := harnessOp_code_of_decode hopDec
    cases op <;> simp [HarnessSessionOp.encode] at hbr hopC
    have hexit1 : ev.hasProcExitReceipt = 1 := u8_eq_of_toNat _ 1 (by omega) hbr
    refine ⟨hopC, hexit1, ?_⟩
    unfold stepHarnessSessionSlice
    have hadmB :
        (verifyHarnessSessionAdmit s.phaseCode ev.opCode s.steerPending
          ev.hasTurnIdleReceipt ev.hasProcExitReceipt
          s.toolDepth s.sessionGeneration ev.eventGeneration == 1) = true := by rw [hadm1]; rfl
    rw [ite_eq_left_of_eq_true _ _ (eq_true hadmB), hopC]
    rfl
  · intro hne
    unfold stepHarnessSessionSlice verifyHarnessSessionAdmit
    have hbeqF : (ev.eventGeneration == s.sessionGeneration) = false := beq_eq_false_iff_ne.mpr hne
    simp [hbeqF]

/-! ## 3. `ProviderAttempt` (`SM-21`) — Generation-Fenced Provider Attempt Classifier -/

structure ProviderAttemptCheck where
  flags   : UInt8 × UInt8
  pins    : UInt32 × UInt32
  retries : UInt32 × UInt32
  streaks : UInt32 × UInt32
  gens    : UInt64 × UInt64
  clocks  : UInt64 × UInt64
  deriving Repr, DecidableEq

def ProviderAttemptDomainSafe (c : ProviderAttemptCheck) : Prop :=
  0 < c.gens.1.toNat ∧
  c.gens.2.toNat = c.gens.1.toNat ∧
  0 < c.pins.2.toNat ∧
  (c.pins.1.toNat = 0 ∨ c.pins.2.toNat = c.pins.1.toNat) ∧
  c.clocks.2.toNat ≤ c.clocks.1.toNat ∧
  c.flags.1.toNat ≠ 1 ∧
  ((c.flags.2.toNat = 0 ∧ c.retries.1.toNat ≤ c.retries.2.toNat) ∨
   (c.flags.2.toNat = 4 ∧
    c.retries.1.toNat < c.retries.2.toNat ∧
    (c.streaks.1.toNat < c.streaks.2.toNat ∨ c.streaks.2.toNat = 0)))

private theorem u32_pos_of_ne_zero {x : UInt32} (h : x ≠ 0) : 0 < x.toNat := by
  have hne : x.toNat ≠ 0 := fun hz => h (u32_eq_of_toNat_eq x 0 hz)
  omega

def providerAttemptMetaGate : MetaGateSpec ProviderAttemptCheck ProviderAttemptDomainSafe where
  gate c :=
    verifyProviderAttemptAdmit
      c.flags.1 c.flags.2 c.pins.1 c.pins.2 c.retries.1 c.retries.2
      c.streaks.1 c.streaks.2 c.gens.1 c.gens.2 c.clocks.1 c.clocks.2 == 1
  sound c h := by
    rcases c with ⟨⟨fb, fr⟩, ⟨pinId, candId⟩, ⟨used, maxR⟩, ⟨strk, thr⟩, ⟨rGen, aGen⟩, ⟨nowEp, coolEp⟩⟩
    change (verifyProviderAttemptAdmit fb fr pinId candId used maxR strk thr rGen aGen nowEp coolEp == 1) = true at h
    dsimp [ProviderAttemptDomainSafe]
    unfold verifyProviderAttemptAdmit classifyProviderAttempt at h
    dsimp only at h
    by_cases hguard :
        (rGen == 0 || aGen != rGen || candId == 0 ||
         (pinId != 0 && candId != pinId) || (fb == 1 && pinId == 0) ||
         decide (nowEp < coolEp) || decide (fr > 5)) = true
    · rw [ite_eq_left_of_eq_true _ _ (eq_true hguard)] at h; contradiction
    · rw [ite_eq_right_of_eq_false _ _ (eq_false hguard)] at h
      simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, bne_iff_ne,
        decide_eq_true_eq, not_or, not_and, Classical.not_not] at hguard
      rcases hguard with ⟨⟨⟨⟨⟨⟨hr0, haeq⟩, hc0⟩, hpinImp⟩, _⟩, hnotLt⟩, hnotGt5⟩
      have hrPos := u64_pos_of_ne_zero hr0
      have haEqN : aGen.toNat = rGen.toNat := by rw [haeq]
      have hcPos := u32_pos_of_ne_zero hc0
      have hpinOk : pinId.toNat = 0 ∨ candId.toNat = pinId.toNat := by
        by_cases hpz : pinId = 0
        · exact Or.inl (by subst hpz; rfl)
        · exact Or.inr (by rw [hpinImp hpz])
      have hcoolOk : coolEp.toNat ≤ nowEp.toNat := by
        have h1 : ¬ (nowEp.toNat < coolEp.toNat) := fun hlt => hnotLt (UInt64.lt_iff_toNat_lt.mpr hlt)
        omega
      by_cases hfb : (fb == 1) = true
      · rw [ite_eq_left_of_eq_true _ _ (eq_true hfb)] at h
        by_cases hfr0 : (fr == 0) = true <;> simp [hfr0] at h
      · rw [ite_eq_right_of_eq_false _ _ (eq_false hfb)] at h
        have hfbNe1 : fb.toNat ≠ 1 := by
          intro h1
          exact hfb (by rw [u8_eq_of_toNat fb 1 (by omega) h1]; rfl)
        refine ⟨hrPos, haEqN, hcPos, hpinOk, hcoolOk, hfbNe1, ?_⟩
        by_cases hfr0 : (fr == 0) = true
        · rw [ite_eq_left_of_eq_true _ _ (eq_true hfr0)] at h
          by_cases hle : used ≤ maxR
          · rw [beq_iff_eq] at hfr0
            exact Or.inl ⟨by subst hfr0; rfl, UInt32.le_iff_toNat_le.mp hle⟩
          · simp [hle] at h
        · rw [ite_eq_right_of_eq_false _ _ (eq_false hfr0)] at h
          by_cases hfr23 : (fr == 2 || fr == 3) = true
          · rw [ite_eq_left_of_eq_true _ _ (eq_true hfr23)] at h; contradiction
          · rw [ite_eq_right_of_eq_false _ _ (eq_false hfr23)] at h
            by_cases hfr1 : (fr == 1) = true
            · rw [ite_eq_left_of_eq_true _ _ (eq_true hfr1)] at h; contradiction
            · rw [ite_eq_right_of_eq_false _ _ (eq_false hfr1)] at h
              by_cases hfr5 : (fr == 5) = true
              · rw [ite_eq_left_of_eq_true _ _ (eq_true hfr5)] at h; contradiction
              · rw [ite_eq_right_of_eq_false _ _ (eq_false hfr5)] at h
                have hfr4 : fr.toNat = 4 := by
                  have hle5 : fr.toNat ≤ 5 := by
                    have h1 : ¬ (5 < fr.toNat) := fun hg => hnotGt5 (UInt8.lt_iff_toNat_lt.mpr hg)
                    omega
                  have hne0 : fr.toNat ≠ 0 := fun hz => hfr0 (by rw [u8_eq_of_toNat fr 0 (by omega) hz]; rfl)
                  have hne1 : fr.toNat ≠ 1 := fun hz => hfr1 (by rw [u8_eq_of_toNat fr 1 (by omega) hz]; rfl)
                  have hne2 : fr.toNat ≠ 2 := fun hz => hfr23 (by rw [u8_eq_of_toNat fr 2 (by omega) hz]; decide)
                  have hne3 : fr.toNat ≠ 3 := fun hz => hfr23 (by rw [u8_eq_of_toNat fr 3 (by omega) hz]; decide)
                  have hne5 : fr.toNat ≠ 5 := fun hz => hfr5 (by rw [u8_eq_of_toNat fr 5 (by omega) hz]; rfl)
                  omega
                by_cases htrip : ((decide (strk ≥ thr) && decide (thr ≥ 1)) || !decide (used < maxR)) = true
                · rw [ite_eq_left_of_eq_true _ _ (eq_true htrip)] at h; contradiction
                · simp only [Bool.or_eq_true, Bool.and_eq_true, Bool.not_eq_true',
                    decide_eq_true_eq, decide_eq_false_iff_not, not_or, not_and, Classical.not_not] at htrip
                  rcases htrip with ⟨hnotStrk, hltR⟩
                  have hstrkCond : strk.toNat < thr.toNat ∨ thr.toNat = 0 := by
                    by_cases hge : thr ≤ strk
                    · have hnot1 := hnotStrk hge
                      have hlt1 : ¬ (1 ≤ thr.toNat) := fun h1 => hnot1 (UInt32.le_iff_toNat_le.mpr h1)
                      exact Or.inr (by omega)
                    · have hnotGe : ¬ (thr.toNat ≤ strk.toNat) := fun hg => hge (UInt32.le_iff_toNat_le.mpr hg)
                      exact Or.inl (by omega)
                  exact Or.inr ⟨hfr4, UInt32.lt_iff_toNat_lt.mp hltR, hstrkCond⟩
  complete c h := by
    rcases c with ⟨⟨fb, fr⟩, ⟨pinId, candId⟩, ⟨used, maxR⟩, ⟨strk, thr⟩, ⟨rGen, aGen⟩, ⟨nowEp, coolEp⟩⟩
    change (verifyProviderAttemptAdmit fb fr pinId candId used maxR strk thr rGen aGen nowEp coolEp == 1) = true
    dsimp [ProviderAttemptDomainSafe] at h
    rcases h with ⟨hrPos, haEq, hcPos, hpin, hcool, hfbNe1, hmode⟩
    unfold verifyProviderAttemptAdmit classifyProviderAttempt
    have hr0F : (rGen == 0) = false := beq_eq_false_iff_ne.mpr (fun hz => by subst hz; simp at hrPos)
    have haEqB : aGen = rGen := u64_eq_of_toNat_eq aGen rGen haEq
    rw [haEqB]
    have hc0F : (candId == 0) = false := beq_eq_false_iff_ne.mpr (fun hz => by subst hz; simp at hcPos)
    have hfb1F : (fb == 1) = false := by
      apply beq_eq_false_iff_ne.mpr
      intro h1
      exact hfbNe1 (by rw [h1]; decide)
    have hpinF : (pinId != 0 && candId != pinId) = false := by
      rcases hpin with hp0 | hpeq
      · have hp0B : pinId = 0 := u32_eq_of_toNat_eq pinId 0 hp0
        rw [hp0B]; simp
      · have hpeqB : candId = pinId := u32_eq_of_toNat_eq candId pinId hpeq
        rw [hpeqB]; simp
    have hcoolF : decide (nowEp < coolEp) = false := by
      apply decide_eq_false_iff_not.mpr
      intro hlt
      have hltN := UInt64.lt_iff_toNat_lt.mp hlt
      omega
    rcases hmode with ⟨hfr0, hle⟩ | ⟨hfr4, hltR, hstrk⟩
    · have hfr0B : fr = 0 := u8_eq_of_toNat fr 0 (by omega) hfr0
      have hleR : used ≤ maxR := UInt32.le_iff_toNat_le.mpr hle
      rw [hfr0B]
      have hguardN :
          ¬ ((rGen == 0 || (rGen != rGen) || candId == 0 ||
              (pinId != 0 && candId != pinId) || (fb == 1 && pinId == 0) ||
              decide (nowEp < coolEp) || decide ((0 : UInt8) > 5)) = true) := by
        simp [hr0F, hc0F, hpinF, hfb1F, hcoolF]
      dsimp only
      rw [ite_eq_right_of_eq_false _ _ (eq_false hguardN)]
      simp [hfb1F, hleR]
    · have hfr4B : fr = 4 := u8_eq_of_toNat fr 4 (by omega) hfr4
      rw [hfr4B]
      have hguardN :
          ¬ ((rGen == 0 || (rGen != rGen) || candId == 0 ||
              (pinId != 0 && candId != pinId) || (fb == 1 && pinId == 0) ||
              decide (nowEp < coolEp) || decide ((4 : UInt8) > 5)) = true) := by
        simp [hr0F, hc0F, hpinF, hfb1F, hcoolF]
      have hltRB : decide (used < maxR) = true := decide_eq_true (UInt32.lt_iff_toNat_lt.mpr hltR)
      have hstrkF : (decide (strk ≥ thr) && decide (thr ≥ 1)) = false := by
        rcases hstrk with hltS | hthr0
        · have hnotGe : decide (strk ≥ thr) = false := by
            apply decide_eq_false_iff_not.mpr
            intro hge
            have hgeN := UInt32.le_iff_toNat_le.mp hge
            omega
          simp [hnotGe]
        · have hthr0B : thr = 0 := u32_eq_of_toNat_eq thr 0 hthr0
          rw [hthr0B]; simp
      dsimp only
      rw [ite_eq_right_of_eq_false _ _ (eq_false hguardN)]
      simp only [hfb1F, hltRB, hstrkF]
      by_cases h2 : used + 1 ≥ 2 <;> simp [h2]
  posWitness :=
    { flags := (0, 4), pins := (0, 7), retries := (0, 2), streaks := (0, 3), gens := (5, 5), clocks := (20, 10) }
  negWitness :=
    { flags := (1, 4), pins := (7, 7), retries := (0, 2), streaks := (0, 3), gens := (5, 5), clocks := (20, 10) }
  nonVacuous := by decide
  tight := by decide

/-- Pre-fence transparent reroute capability for `ProviderAttemptSliceState`:
    probes whether a transient fault (`failureReason == 4`) on the state's pinned/default
    candidate under permissive retry & threshold budgets (`0xFFFFFFFF`, `0`) at `0xFFFFFFFFFFFFFFFF`
    yields a transparent reroute verdict (`2 = rerouteSameAccount` or `3 = rerouteExcludeCurrent`). -/
def providerAttemptCanTransparentReroute (s : ProviderAttemptSliceState) : Bool :=
  let cand : UInt32 := if s.pinnedAccountId != 0 then s.pinnedAccountId else 1
  let v := classifyProviderAttempt s.firstByteCommitted 4
    s.pinnedAccountId cand s.attemptsUsed 0xFFFFFFFF
    s.transientStreak 0 s.routeGeneration s.routeGeneration
    0xFFFFFFFFFFFFFFFF s.cooldownUntilEpoch
  v == 2 || v == 3

def providerAttemptCommittedStickyFence :
    StickyFence ProviderAttemptSliceState ProviderAttemptSliceEvent where
  fenced s := s.firstByteCommitted == 1
  preFenceAct := providerAttemptCanTransparentReroute
  step s ev := (stepProviderAttemptSlice s ev).1
  sticky s ev hf := by
    unfold stepProviderAttemptSlice
    dsimp only
    by_cases hv :
        (let v := classifyProviderAttempt s.firstByteCommitted ev.failureReason
          s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
          s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
          ev.nowEpoch s.cooldownUntilEpoch
         v == 0 || v == 8) = true
    · rw [ite_eq_left_of_eq_true _ _ (eq_true hv)]; exact hf
    · rw [ite_eq_right_of_eq_false _ _ (eq_false hv)]; simp [hf]
  forbids_post s ev hf := by
    have hst : (stepProviderAttemptSlice s ev).1.firstByteCommitted = 1 := by
      have hbeq : ((stepProviderAttemptSlice s ev).1.firstByteCommitted == 1) = true := by
        unfold stepProviderAttemptSlice
        dsimp only
        by_cases hv :
            (let v := classifyProviderAttempt s.firstByteCommitted ev.failureReason
              s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
              s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
              ev.nowEpoch s.cooldownUntilEpoch
             v == 0 || v == 8) = true
        · rw [ite_eq_left_of_eq_true _ _ (eq_true hv)]; exact hf
        · rw [ite_eq_right_of_eq_false _ _ (eq_false hv)]; simp [hf]
      exact beq_iff_eq.mp hbeq
    unfold providerAttemptCanTransparentReroute classifyProviderAttempt
    rw [hst]
    dsimp only
    by_cases hg :
        ((stepProviderAttemptSlice s ev).1.routeGeneration == 0 ||
         ((stepProviderAttemptSlice s ev).1.routeGeneration != (stepProviderAttemptSlice s ev).1.routeGeneration) ||
         ((if (stepProviderAttemptSlice s ev).1.pinnedAccountId != 0 then (stepProviderAttemptSlice s ev).1.pinnedAccountId else 1) == 0) ||
         ((stepProviderAttemptSlice s ev).1.pinnedAccountId != 0 &&
          (if (stepProviderAttemptSlice s ev).1.pinnedAccountId != 0 then (stepProviderAttemptSlice s ev).1.pinnedAccountId else 1) !=
            (stepProviderAttemptSlice s ev).1.pinnedAccountId) ||
         (((1 : UInt8) == 1) && (stepProviderAttemptSlice s ev).1.pinnedAccountId == 0) ||
         decide ((0xFFFFFFFFFFFFFFFF : UInt64) < (stepProviderAttemptSlice s ev).1.cooldownUntilEpoch) ||
         decide ((4 : UInt8) > 5)) = true
    · rw [ite_eq_left_of_eq_true _ _ (eq_true hg)]; simp
    · rw [ite_eq_right_of_eq_false _ _ (eq_false hg)]; simp

theorem providerAttemptCommittedStickyFence_preFence_reachable :
    providerAttemptCommittedStickyFence.preFenceAct
      { firstByteCommitted := 0
        pinnedAccountId := 0
        attemptsUsed := 0
        transientStreak := 0
        routeGeneration := 1
        cooldownUntilEpoch := 0 } = true := by
  decide

def providerAttemptCooldownClockDiscipline : ClockDiscipline ProviderAttemptCheck where
  eval c :=
    if providerAttemptMetaGate.gate c then 1 else 0
  clockMask := 1
  guardOk c := decide (c.clocks.2 ≤ c.clocks.1) && c.gens.1 != 0 && c.gens.2 == c.gens.1
  isolated c h := by
    have hg : providerAttemptMetaGate.gate c = true := by
      by_cases h1 : providerAttemptMetaGate.gate c = true
      · exact h1
      · simp [h1] at h
    have hs := providerAttemptMetaGate.sound c hg
    rcases c with ⟨_, _, _, _, ⟨rGen, aGen⟩, ⟨nowEp, coolEp⟩⟩
    rcases hs with ⟨hrPos, haEq, _, _, hcool, _⟩
    have hcoolB : decide (coolEp ≤ nowEp) = true := decide_eq_true (UInt64.le_iff_toNat_le.mpr hcool)
    have hrN := (u64_bne_zero_iff_pos _).mpr hrPos
    have haEqB : aGen = rGen := u64_eq_of_toNat_eq aGen rGen haEq
    simp [hcoolB, hrN, haEqB]

/-- Deductive R4-A theorem (`SM-21` — Provider attempt classifier):
    1. Stale generation (`attemptGeneration ≠ routeGeneration`) fails closed (`verdict = 0` and `(s, [])`).
    2. Once `firstByteCommitted = 1`:
       - `pinnedAccountId = 0` fails closed (`verdict = 0`),
       - `failureReason = 0` never dispatches a duplicate upstream attempt, never resets `transientStreak`,
         and never trips breaker `7` (`stepProviderAttemptSlice s ev = (s, [])`),
       - any non-zero `failureReason ≠ 0` returns `0` (on guard failure) or `4` (`abortCommittedLock`)
         only, and never reroutes (`verdict ≠ 2 ∧ verdict ≠ 3`). -/
theorem providerAttempt_stale_generation_fails_closed_and_committed_never_reroutes
    (s : ProviderAttemptSliceState) (ev : ProviderAttemptSliceEvent) :
    (ev.attemptGeneration ≠ s.routeGeneration →
      classifyProviderAttempt s.firstByteCommitted ev.failureReason
        s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
        s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
        ev.nowEpoch s.cooldownUntilEpoch = 0 ∧
      stepProviderAttemptSlice s ev = (s, [])) ∧
    (s.firstByteCommitted = 1 →
      (s.pinnedAccountId = 0 →
        classifyProviderAttempt s.firstByteCommitted ev.failureReason
          s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
          s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
          ev.nowEpoch s.cooldownUntilEpoch = 0) ∧
      (ev.failureReason = 0 → stepProviderAttemptSlice s ev = (s, [])) ∧
      (ev.failureReason ≠ 0 →
        let v := classifyProviderAttempt s.firstByteCommitted ev.failureReason
          s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
          s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
          ev.nowEpoch s.cooldownUntilEpoch
        (v = 0 ∨ v = 4) ∧ v ≠ 2 ∧ v ≠ 3)) := by
  refine ⟨?_, ?_⟩
  · intro hne
    have hbn : (ev.attemptGeneration != s.routeGeneration) = true := bne_iff_ne.mpr hne
    have hv0 : classifyProviderAttempt s.firstByteCommitted ev.failureReason
        s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
        s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
        ev.nowEpoch s.cooldownUntilEpoch = 0 := by
      unfold classifyProviderAttempt
      simp [hbn]
    refine ⟨hv0, ?_⟩
    unfold stepProviderAttemptSlice
    dsimp only
    rw [hv0]
    rfl
  · intro hfb1
    refine ⟨?_, ?_, ?_⟩
    · intro hpin0
      unfold classifyProviderAttempt
      simp [hfb1, hpin0]
    · intro hfr0
      unfold stepProviderAttemptSlice
      dsimp only
      have hv08 :
          (let v := classifyProviderAttempt s.firstByteCommitted ev.failureReason
            s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
            s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
            ev.nowEpoch s.cooldownUntilEpoch
           v == 0 || v == 8) = true := by
        dsimp only
        unfold classifyProviderAttempt
        rw [hfb1, hfr0]
        by_cases hg :
            (s.routeGeneration == 0 || ev.attemptGeneration != s.routeGeneration ||
             ev.candidateAccountId == 0 ||
             (s.pinnedAccountId != 0 && ev.candidateAccountId != s.pinnedAccountId) ||
             ((1 : UInt8) == 1 && s.pinnedAccountId == 0) ||
             decide (ev.nowEpoch < s.cooldownUntilEpoch) || decide ((0 : UInt8) > 5)) = true
        · rw [ite_eq_left_of_eq_true _ _ (eq_true hg)]; simp
        · rw [ite_eq_right_of_eq_false _ _ (eq_false hg)]; simp
      rw [ite_eq_left_of_eq_true _ _ (eq_true hv08)]
    · intro hfrNe
      dsimp only
      unfold classifyProviderAttempt
      rw [hfb1]
      have hfrNe0 : (ev.failureReason == 0) = false := beq_eq_false_iff_ne.mpr hfrNe
      by_cases hg :
          (s.routeGeneration == 0 || ev.attemptGeneration != s.routeGeneration ||
           ev.candidateAccountId == 0 ||
           (s.pinnedAccountId != 0 && ev.candidateAccountId != s.pinnedAccountId) ||
           ((1 : UInt8) == 1 && s.pinnedAccountId == 0) ||
           decide (ev.nowEpoch < s.cooldownUntilEpoch) || decide (ev.failureReason > 5)) = true
      · rw [ite_eq_left_of_eq_true _ _ (eq_true hg)]
        exact ⟨Or.inl rfl, by decide, by decide⟩
      · rw [ite_eq_right_of_eq_false _ _ (eq_false hg)]
        simp [hfrNe0]

/-! ## 4. `AuthRefresh` (`SM-21`) — Generation-Fenced Auth Refresh & Rotation -/

structure AuthRefreshAdmitCheck where
  codes  : UInt8 × UInt8
  guards : UInt8 × UInt8
  gens   : UInt64 × UInt64
  nonces : UInt64 × UInt64
  clocks : UInt64 × UInt64
  deriving Repr, DecidableEq

def AuthRefreshAdmitDomainSafe (c : AuthRefreshAdmitCheck) : Prop :=
  0 < c.gens.1.toNat ∧
  ∃ ph, AuthRefreshPhase.decode? c.codes.1.toNat = some ph ∧ ph.isRevoked = false ∧
    ∃ op, AuthRefreshOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .claimRefresh =>
          ph = .valid ∧ c.gens.1.toNat < 18446744073709551615 ∧
          c.gens.2.toNat = c.gens.1.toNat + 1 ∧ 0 < c.nonces.1.toNat
      | .stageRotatedSecret =>
          ph = .refreshClaimed ∧ c.gens.2.toNat = c.gens.1.toNat ∧
          0 < c.nonces.1.toNat ∧ c.nonces.2.toNat = c.nonces.1.toNat
      | .commitFsyncAndDrain =>
          ph = .pendingFsync ∧ c.gens.2.toNat = c.gens.1.toNat ∧
          c.guards.1.toNat = 1 ∧ c.guards.2.toNat = 1 ∧ c.clocks.1.toNat < c.clocks.2.toNat
      | .abortRefreshTransient =>
          (ph = .refreshClaimed ∨ ph = .pendingFsync) ∧ c.gens.2.toNat = c.gens.1.toNat
      | .revokeCredential =>
          (ph = .valid ∨ ph = .refreshClaimed ∨ ph = .pendingFsync) ∧ c.gens.2.toNat = c.gens.1.toNat

private theorem authPhase_code_of_decode {x : UInt8} {ph : AuthRefreshPhase}
    (h : AuthRefreshPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [AuthRefreshPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | k4 <;>
        simp [AuthRefreshPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [AuthRefreshPhase.encode] using hcode

private theorem authOp_code_of_decode {x : UInt8} {op : AuthRefreshOp}
    (h : AuthRefreshOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [AuthRefreshOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | k5 <;>
        simp [AuthRefreshOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [AuthRefreshOp.encode] using hcode

def authRefreshMetaGate : MetaGateSpec AuthRefreshAdmitCheck AuthRefreshAdmitDomainSafe where
  gate c :=
    verifyAuthRefreshAdmit
      c.codes.1 c.codes.2 c.guards.1 c.guards.2
      c.gens.1 c.gens.2 c.nonces.1 c.nonces.2 c.clocks.1 c.clocks.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨fsyncC, flockH⟩, ⟨dGen, cGen⟩, ⟨expN, presN⟩, ⟨nowEp, expEp⟩⟩
    change (verifyAuthRefreshAdmit phC opC fsyncC flockH dGen cGen expN presN nowEp expEp == 1) = true at h
    dsimp [AuthRefreshAdmitDomainSafe]
    unfold verifyAuthRefreshAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨_, _⟩, hd0⟩, hmain⟩
    have hdPos := u64_pos_of_ne_zero hd0
    refine ⟨hdPos, ?_⟩
    rcases hmain with h0 | hrest
    · rcases h0 with ⟨⟨⟨⟨⟨hop, hph⟩, hdMax⟩, hlt⟩, hdiff⟩, hn0⟩
      subst hop; subst hph
      have hltN := UInt64.lt_iff_toNat_lt.mp hlt
      have hsub := UInt64.toNat_sub_of_le cGen dGen (UInt64.le_iff_toNat_le.mpr (by omega))
      have hdiffN : (cGen - dGen).toNat = 1 := by rw [hdiff]; rfl
      exact ⟨.valid, rfl, rfl, .claimRefresh, rfl, rfl,
        UInt64.lt_iff_toNat_lt.mp hdMax, by omega, u64_pos_of_ne_zero hn0⟩
    · rcases hrest with ⟨⟨_, hceq⟩, hbr⟩
      have hceqN : cGen.toNat = dGen.toNat := by rw [hceq]
      rcases hbr with ((h1 | h2) | h3) | h4
      · rcases h1 with ⟨⟨⟨hop, hph⟩, hn0⟩, hneq⟩; subst hop; subst hph
        exact ⟨.refreshClaimed, rfl, rfl, .stageRotatedSecret, rfl, rfl, hceqN,
          u64_pos_of_ne_zero hn0, by rw [hneq]⟩
      · rcases h2 with ⟨⟨⟨⟨hop, hph⟩, hfs⟩, hfl⟩, hlt⟩
        subst hop
        subst hph
        subst hfs
        subst hfl
        exact ⟨.pendingFsync, rfl, rfl, .commitFsyncAndDrain, rfl, rfl, hceqN, rfl, rfl,
          UInt64.lt_iff_toNat_lt.mp hlt⟩
      · rcases h3 with ⟨hop, hph | hph⟩ <;> subst hop <;> subst hph
        · exact ⟨.refreshClaimed, rfl, rfl, .abortRefreshTransient, rfl, Or.inl rfl, hceqN⟩
        · exact ⟨.pendingFsync, rfl, rfl, .abortRefreshTransient, rfl, Or.inr rfl, hceqN⟩
      · rcases h4 with ⟨hop, (hph | hph) | hph⟩ <;> subst hop <;> subst hph
        · exact ⟨.valid, rfl, rfl, .revokeCredential, rfl, Or.inl rfl, hceqN⟩
        · exact ⟨.refreshClaimed, rfl, rfl, .revokeCredential, rfl, Or.inr (Or.inl rfl), hceqN⟩
        · exact ⟨.pendingFsync, rfl, rfl, .revokeCredential, rfl, Or.inr (Or.inr rfl), hceqN⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨fsyncC, flockH⟩, ⟨dGen, cGen⟩, ⟨expN, presN⟩, ⟨nowEp, expEp⟩⟩
    change (verifyAuthRefreshAdmit phC opC fsyncC flockH dGen cGen expN presN nowEp expEp == 1) = true
    dsimp [AuthRefreshAdmitDomainSafe] at h
    rcases h with ⟨hdPos, ph, hphDec, _, op, hopDec, hbr⟩
    have hdN := (u64_bne_zero_iff_pos _).mpr hdPos
    have hphC := authPhase_code_of_decode hphDec
    have hopC := authOp_code_of_decode hopDec
    subst hphC; subst hopC
    unfold verifyAuthRefreshAdmit
    cases op with
    | claimRefresh =>
      rcases hbr with ⟨rfl, hdMax, hsucc, hnPos⟩
      have hdMaxB : dGen < 0xFFFFFFFFFFFFFFFF := UInt64.lt_iff_toNat_lt.mpr hdMax
      have hltB : dGen < cGen := UInt64.lt_iff_toNat_lt.mpr (by omega)
      have hdiffB : (cGen - dGen == 1) = true := by
        rw [beq_iff_eq]
        apply u64_eq_of_toNat_eq
        rw [UInt64.toNat_sub_of_le cGen dGen (UInt64.le_iff_toNat_le.mpr (by omega))]
        have h1 : (1 : UInt64).toNat = 1 := rfl
        rw [h1]
        omega
      have hnN := (u64_bne_zero_iff_pos _).mpr hnPos
      simp [AuthRefreshPhase.encode, AuthRefreshOp.encode, hdN, hdMaxB, hltB, hdiffB, hnN]
    | stageRotatedSecret =>
      rcases hbr with ⟨rfl, hceq, hnPos, hneq⟩
      have hceqB : cGen = dGen := u64_eq_of_toNat_eq cGen dGen hceq
      have hnN := (u64_bne_zero_iff_pos _).mpr hnPos
      have hneqB : presN = expN := u64_eq_of_toNat_eq presN expN hneq
      subst hceqB; subst hneqB
      simp [AuthRefreshPhase.encode, AuthRefreshOp.encode, hdN, hnN]
    | commitFsyncAndDrain =>
      rcases hbr with ⟨rfl, hceq, hfs, hfl, hlt⟩
      have hceqB : cGen = dGen := u64_eq_of_toNat_eq cGen dGen hceq
      have hfs1 : fsyncC = 1 := u8_eq_of_toNat fsyncC 1 (by omega) hfs
      have hfl1 : flockH = 1 := u8_eq_of_toNat flockH 1 (by omega) hfl
      have hltB : nowEp < expEp := UInt64.lt_iff_toNat_lt.mpr hlt
      subst hceqB; subst hfs1; subst hfl1
      simp [AuthRefreshPhase.encode, AuthRefreshOp.encode, hdN, hltB]
    | abortRefreshTransient =>
      rcases hbr with ⟨hph, hceq⟩
      have hceqB : cGen = dGen := u64_eq_of_toNat_eq cGen dGen hceq
      subst hceqB
      rcases hph with rfl | rfl <;> simp [AuthRefreshPhase.encode, AuthRefreshOp.encode, hdN]
    | revokeCredential =>
      rcases hbr with ⟨hph, hceq⟩
      have hceqB : cGen = dGen := u64_eq_of_toNat_eq cGen dGen hceq
      subst hceqB
      rcases hph with rfl | rfl | rfl <;> simp [AuthRefreshPhase.encode, AuthRefreshOp.encode, hdN]
  posWitness :=
    { codes := (2, 2), guards := (1, 1), gens := (4, 4), nonces := (0, 0), clocks := (10, 20) }
  negWitness :=
    { codes := (2, 2), guards := (1, 1), gens := (4, 3), nonces := (0, 0), clocks := (10, 20) }
  nonVacuous := by decide
  tight := by decide

private theorem authRefresh_revoked_step_id (s : AuthRefreshSliceState) (ev : AuthRefreshSliceEvent)
    (hf : decide (3 ≤ s.phaseCode) = true) :
    stepAuthRefreshSlice s ev = (s, []) := by
  unfold stepAuthRefreshSlice
  have hadmFalse :
      ¬ (verifyAuthRefreshAdmit s.phaseCode ev.opCode ev.fsyncCompleted ev.flockHeld
          s.durableAuthGeneration ev.candidateGeneration
          (if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce)
          ev.reqLoginNonce ev.nowEpoch ev.newExpiryEpoch == 1) := by
    intro hc
    unfold verifyAuthRefreshAdmit at hc
    have hb := bit_cond_true hc
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hb hf
    have hle2 : s.phaseCode.toNat ≤ 2 := UInt8.le_iff_toNat_le.mp hb.1.1.1
    have hge3 : 3 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hf
    omega
  dsimp only
  exact ite_eq_right_iff.mpr (fun hc => absurd hc hadmFalse)

def authRefreshRevokedStickyFence : StickyFence AuthRefreshSliceState AuthRefreshSliceEvent where
  fenced s := decide (3 ≤ s.phaseCode)
  preFenceAct s := decide (s.phaseCode ≤ 2)
  step s ev := (stepAuthRefreshSlice s ev).1
  sticky s ev hf := by
    rw [authRefresh_revoked_step_id s ev hf]
    exact hf
  forbids_post s ev hf := by
    rw [authRefresh_revoked_step_id s ev hf]
    simp only [decide_eq_true_eq] at hf
    have hge3 : 3 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hf
    apply decide_eq_false_iff_not.mpr
    intro hle2
    have hleN : s.phaseCode.toNat ≤ 2 := UInt8.le_iff_toNat_le.mp hle2
    omega

/-- Deductive R4-A theorem (`SM-21` — Auth refresh & rotation):
    1. Any stale generation (`candidateGeneration < durableAuthGeneration`,
       or `candidateGeneration == durableAuthGeneration` on `claimRefresh`)
       fails closed (`0` and `(s, [])`).
    2. `commitFsyncAndDrain` (`opCode = 2`) clears `dirtyPending` ONLY when
       `fsyncCompleted = 1 ∧ flockHeld = 1 ∧ candidateGeneration = durableAuthGeneration`.
    3. `durableAuthGeneration` is monotonically non-decreasing across every step. -/
theorem authRefresh_stale_generation_fails_closed_and_generation_monotone
    (s : AuthRefreshSliceState) (ev : AuthRefreshSliceEvent) :
    (ev.candidateGeneration < s.durableAuthGeneration →
      verifyAuthRefreshAdmit s.phaseCode ev.opCode ev.fsyncCompleted ev.flockHeld
        s.durableAuthGeneration ev.candidateGeneration
        (if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce)
        ev.reqLoginNonce ev.nowEpoch ev.newExpiryEpoch = 0 ∧
      stepAuthRefreshSlice s ev = (s, [])) ∧
    (ev.opCode = 2 →
      verifyAuthRefreshAdmit s.phaseCode ev.opCode ev.fsyncCompleted ev.flockHeld
        s.durableAuthGeneration ev.candidateGeneration
        (if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce)
        ev.reqLoginNonce ev.nowEpoch ev.newExpiryEpoch = 1 →
      ev.fsyncCompleted = 1 ∧ ev.flockHeld = 1 ∧ ev.candidateGeneration = s.durableAuthGeneration) ∧
    s.durableAuthGeneration.toNat ≤ (stepAuthRefreshSlice s ev).1.durableAuthGeneration.toNat := by
  refine ⟨?_, ?_, ?_⟩
  · intro hlt
    have hltN := UInt64.lt_iff_toNat_lt.mp hlt
    have hnotGt : ¬ (s.durableAuthGeneration < ev.candidateGeneration) := by
      intro hg; have hgN := UInt64.lt_iff_toNat_lt.mp hg; omega
    have hne : (ev.candidateGeneration == s.durableAuthGeneration) = false := by
      apply beq_eq_false_iff_ne.mpr
      intro heq; rw [heq] at hltN; omega
    have hadm0 :
        verifyAuthRefreshAdmit s.phaseCode ev.opCode ev.fsyncCompleted ev.flockHeld
          s.durableAuthGeneration ev.candidateGeneration
          (if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce)
          ev.reqLoginNonce ev.nowEpoch ev.newExpiryEpoch = 0 := by
      unfold verifyAuthRefreshAdmit
      simp [hnotGt, hne]
    refine ⟨hadm0, ?_⟩
    unfold stepAuthRefreshSlice
    dsimp only
    rw [hadm0]
    rfl
  · intro hop2 hadm1
    have hgate : authRefreshMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          guards := (ev.fsyncCompleted, ev.flockHeld)
          gens := (s.durableAuthGeneration, ev.candidateGeneration)
          nonces := (if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce, ev.reqLoginNonce)
          clocks := (ev.nowEpoch, ev.newExpiryEpoch) } = true := by
      simpa [authRefreshMetaGate] using hadm1
    have hs := authRefreshMetaGate.sound _ hgate
    dsimp [AuthRefreshAdmitDomainSafe] at hs
    rcases hs with ⟨_, _, _, _, op, hopDec, hbr⟩
    rw [hop2] at hopDec
    simp [AuthRefreshOp.decode?] at hopDec
    subst hopDec
    rcases hbr with ⟨_, hceq, hfs, hfl, _⟩
    exact ⟨u8_eq_of_toNat _ 1 (by omega) hfs,
           u8_eq_of_toNat _ 1 (by omega) hfl,
           u64_eq_of_toNat_eq _ _ hceq⟩
  · unfold stepAuthRefreshSlice
    dsimp only
    by_cases hadm :
        (verifyAuthRefreshAdmit s.phaseCode ev.opCode ev.fsyncCompleted ev.flockHeld
          s.durableAuthGeneration ev.candidateGeneration
          (if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce)
          ev.reqLoginNonce ev.nowEpoch ev.newExpiryEpoch == 1) = true
    · rw [ite_eq_left_of_eq_true _ _ (eq_true hadm)]
      dsimp only
      by_cases hop0 : (ev.opCode == 0) = true
      · rw [ite_eq_left_of_eq_true _ _ (eq_true hop0)]
        have hs := authRefreshMetaGate.sound
          { codes := (s.phaseCode, ev.opCode)
            guards := (ev.fsyncCompleted, ev.flockHeld)
            gens := (s.durableAuthGeneration, ev.candidateGeneration)
            nonces := (if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce, ev.reqLoginNonce)
            clocks := (ev.nowEpoch, ev.newExpiryEpoch) }
          (by simpa [authRefreshMetaGate] using hadm)
        dsimp [AuthRefreshAdmitDomainSafe] at hs
        rcases hs with ⟨_, _, _, _, op, hopDec, hbr⟩
        rw [beq_iff_eq] at hop0
        rw [hop0] at hopDec
        simp [AuthRefreshOp.decode?] at hopDec
        subst hopDec
        rcases hbr with ⟨_, _, hsucc, _⟩
        omega
      · rw [ite_eq_right_of_eq_false _ _ (eq_false hop0)]; exact Nat.le_refl _
    · rw [ite_eq_right_of_eq_false _ _ (eq_false hadm)]; exact Nat.le_refl _

/-! ## 5. Orthogonal `R4WorldState` Footprint Disjointness & Pairwise Commutativity -/

theorem r4_specBlocks_all_footprints_disjoint :
    Footprint.Disjoint cloudTurnSpecBlock.footprint harnessSessionSpecBlock.footprint = true ∧
    Footprint.Disjoint cloudTurnSpecBlock.footprint providerAttemptSpecBlock.footprint = true ∧
    Footprint.Disjoint cloudTurnSpecBlock.footprint authRefreshSpecBlock.footprint = true ∧
    Footprint.Disjoint harnessSessionSpecBlock.footprint providerAttemptSpecBlock.footprint = true ∧
    Footprint.Disjoint harnessSessionSpecBlock.footprint authRefreshSpecBlock.footprint = true ∧
    Footprint.Disjoint providerAttemptSpecBlock.footprint authRefreshSpecBlock.footprint = true ∧
    Footprint.Disjoint ⟨0x1F, 0x1F⟩ cloudTurnSpecBlock.footprint = true ∧
    Footprint.Disjoint ⟨0x1F, 0x1F⟩ harnessSessionSpecBlock.footprint = true ∧
    Footprint.Disjoint ⟨0x1F, 0x1F⟩ providerAttemptSpecBlock.footprint = true ∧
    Footprint.Disjoint ⟨0x1F, 0x1F⟩ authRefreshSpecBlock.footprint = true := by
  decide

theorem r4_specBlocks_pairwise_commute
    (w : R4WorldState)
    (ec : CloudTurnSliceEvent) (eh : HarnessSessionSliceEvent)
    (ep : ProviderAttemptSliceEvent) (ea : AuthRefreshSliceEvent) :
    (harnessSessionSpecBlock.liftStep (cloudTurnSpecBlock.liftStep w ec).1 eh).1 =
      (cloudTurnSpecBlock.liftStep (harnessSessionSpecBlock.liftStep w eh).1 ec).1 ∧
    (providerAttemptSpecBlock.liftStep (cloudTurnSpecBlock.liftStep w ec).1 ep).1 =
      (cloudTurnSpecBlock.liftStep (providerAttemptSpecBlock.liftStep w ep).1 ec).1 ∧
    (authRefreshSpecBlock.liftStep (cloudTurnSpecBlock.liftStep w ec).1 ea).1 =
      (cloudTurnSpecBlock.liftStep (authRefreshSpecBlock.liftStep w ea).1 ec).1 ∧
    (providerAttemptSpecBlock.liftStep (harnessSessionSpecBlock.liftStep w eh).1 ep).1 =
      (harnessSessionSpecBlock.liftStep (providerAttemptSpecBlock.liftStep w ep).1 eh).1 ∧
    (authRefreshSpecBlock.liftStep (harnessSessionSpecBlock.liftStep w eh).1 ea).1 =
      (harnessSessionSpecBlock.liftStep (authRefreshSpecBlock.liftStep w ea).1 eh).1 ∧
    (authRefreshSpecBlock.liftStep (providerAttemptSpecBlock.liftStep w ep).1 ea).1 =
      (providerAttemptSpecBlock.liftStep (authRefreshSpecBlock.liftStep w ea).1 ep).1 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · refine specBlock_orthogonal_commutes cloudTurnSpecBlock harnessSessionSpecBlock ?_ ?_ ?_ w ec eh
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes cloudTurnSpecBlock providerAttemptSpecBlock ?_ ?_ ?_ w ec ep
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes cloudTurnSpecBlock authRefreshSpecBlock ?_ ?_ ?_ w ec ea
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes harnessSessionSpecBlock providerAttemptSpecBlock ?_ ?_ ?_ w eh ep
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes harnessSessionSpecBlock authRefreshSpecBlock ?_ ?_ ?_ w eh ea
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes providerAttemptSpecBlock authRefreshSpecBlock ?_ ?_ ?_ w ep ea
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl

end Orb.HarnessCloudSpec
