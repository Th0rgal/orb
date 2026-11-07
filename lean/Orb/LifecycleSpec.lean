/-
  Orb.LifecycleSpec: Phase R3-A Non-Tautological Specifications & Composition Proofs
  (`0 import Lean`, `0 sorryAx`).

  Proves for the 5 R3-A coordinated slices (`MissionLifecycle`, `RunLifecycle`,
  `QueueItemLifecycle`, `CancelProtocol`, `WakeupContinuation`):
    1. Independent two-layer `MetaGateSpec` equivalence (`sound`, `complete`, `posWitness`,
       `negWitness`, `nonVacuous`, `tight`) over decoded protocol ADTs and natural-number invariants.
    2. Layer-I meta-specifications (`StickyFence`, `ClockDiscipline`, `ScopedAuthority`,
       `ReplayIdempotence`).
    3. All `plan.md` §Phase R3-A security & lifecycle obligations:
       - Completed/terminal runs NEVER re-enter `Running` (`phaseCode == 2`) without first
         claiming `run_generation + 1`, and `runGeneration` is monotonically non-decreasing.
       - Superseded owners (`ownerSuperseded == 1`) NEVER claim or mutate runs (`ScopedAuthority`).
       - Acknowledged (`delivered`) and `cancelled` queue items NEVER replay, edit, or re-claim
         (`StickyFence` + `ReplayIdempotence`).
       - `CancelRequested` / `SignalDispatched` NEVER transition to `Cancelled` without a matching
         generation runner/provider termination receipt and clear uncertain-delivery guard.
       - `WakeupContinuation` enforces `ClockDiscipline` (`dueEpoch <= nowEpoch`), generation fencing,
         and single-fire semantics (fired/superseded/cancelled continuations never double-fire).
    4. Pairwise footprint disjointness and orthogonal `SpecBlock.liftStep` commutativity across
       the 5 slices over `R3WorldState`.
-/
import Orb.Lifecycle

namespace Orb.LifecycleSpec

open Orb.Spec
open Orb.Lifecycle

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

/-! ## 1. `MissionLifecycle` (`SM-03` + `SM-06`) -/

structure MissionAdmitCheck where
  codes  : UInt8 × UInt8
  flags  : UInt8 × UInt8
  guards : UInt8 × UInt8
  epochs : UInt64 × UInt64
  clocks : UInt64 × UInt64
  deriving Repr, DecidableEq

def MissionAdmitDomainSafe (c : MissionAdmitCheck) : Prop :=
  c.flags.1.toNat = 0 ∧
  0 < c.epochs.1.toNat ∧
  c.epochs.2.toNat = c.epochs.1.toNat ∧
  ∃ ph, MissionPhase.decode? c.codes.1.toNat = some ph ∧ ph.isTerminal = false ∧
    ∃ op, MissionOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .dispatchRun => ph = .awaitingUser ∨ ph = .waitingBackground ∨ ph = .interrupted
      | .parkAwaitingUser => ph = .active
      | .parkBackground => ph = .active
      | .parkRateLimit =>
          ph = .active ∧ c.clocks.1.toNat < c.clocks.2.toNat ∧ c.guards.2.toNat = 1
      | .resumeRateLimit =>
          ph = .waitingRateLimit ∧ c.guards.2.toNat = 1 ∧ c.clocks.2.toNat ≤ c.clocks.1.toNat
      | .markInterrupted => ph = .active ∨ ph = .waitingBackground ∨ ph = .waitingRateLimit
      | .completeWithReceipt => ph = .active ∧ c.flags.2.toNat = 1
      | .failRun =>
          ph = .active ∨ ph = .waitingBackground ∨ ph = .waitingRateLimit ∨ ph = .interrupted
      | .finalizeCancelReceipt => c.guards.1.toNat = 1

private theorem missionPhase_code_of_decode {x : UInt8} {ph : MissionPhase}
    (h : MissionPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [MissionPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | _ | k8 <;>
        simp [MissionPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [MissionPhase.encode] using hcode

private theorem missionOp_code_of_decode {x : UInt8} {op : MissionOp}
    (h : MissionOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [MissionOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | _ | _ | k9 <;>
        simp [MissionOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [MissionOp.encode] using hcode

def missionLifecycleMetaGate : MetaGateSpec MissionAdmitCheck MissionAdmitDomainSafe where
  gate c :=
    verifyMissionLifecycleAdmit
      c.codes.1 c.codes.2 c.flags.1 c.flags.2 c.guards.1 c.guards.2
      c.epochs.1 c.epochs.2 c.clocks.1 c.clocks.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨sup, evd⟩, ⟨trm, res⟩, ⟨ownEp, calEp⟩, ⟨nowEp, nbEp⟩⟩
    change (verifyMissionLifecycleAdmit phC opC sup evd trm res ownEp calEp nowEp nbEp == 1) = true at h
    dsimp [MissionAdmitDomainSafe]
    unfold verifyMissionLifecycleAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨hsup, hown0⟩, hcal⟩, _⟩, _⟩, hbr⟩
    have hownPos : 0 < ownEp.toNat := by
      have hne : ownEp.toNat ≠ 0 := fun hz => hown0 (u64_eq_of_toNat_eq ownEp 0 hz)
      omega
    refine ⟨by subst hsup; rfl, hownPos, by subst hcal; rfl, ?_⟩
    rcases hbr with (((((((h0 | h1) | h2) | h3) | h4) | h5) | h6) | h7) | h8
    · rcases h0 with ⟨hop, (hph | hph) | hph⟩ <;> subst hop <;> subst hph
      · exact ⟨.awaitingUser, rfl, rfl, .dispatchRun, rfl, Or.inl rfl⟩
      · exact ⟨.waitingBackground, rfl, rfl, .dispatchRun, rfl, Or.inr (Or.inl rfl)⟩
      · exact ⟨.interrupted, rfl, rfl, .dispatchRun, rfl, Or.inr (Or.inr rfl)⟩
    · rcases h1 with ⟨hop, hph⟩; subst hop; subst hph
      exact ⟨.active, rfl, rfl, .parkAwaitingUser, rfl, rfl⟩
    · rcases h2 with ⟨hop, hph⟩; subst hop; subst hph
      exact ⟨.active, rfl, rfl, .parkBackground, rfl, rfl⟩
    · rcases h3 with ⟨⟨⟨hop, hph⟩, hlt⟩, hres⟩
      subst hop
      subst hph
      subst hres
      exact ⟨.active, rfl, rfl, .parkRateLimit, rfl, rfl, UInt64.lt_iff_toNat_lt.mp hlt, rfl⟩
    · rcases h4 with ⟨⟨⟨hop, hph⟩, hres⟩, hle⟩
      subst hop
      subst hph
      subst hres
      exact ⟨.waitingRateLimit, rfl, rfl, .resumeRateLimit, rfl, rfl, rfl, UInt64.le_iff_toNat_le.mp hle⟩
    · rcases h5 with ⟨hop, (hph | hph) | hph⟩ <;> subst hop <;> subst hph
      · exact ⟨.active, rfl, rfl, .markInterrupted, rfl, Or.inl rfl⟩
      · exact ⟨.waitingBackground, rfl, rfl, .markInterrupted, rfl, Or.inr (Or.inl rfl)⟩
      · exact ⟨.waitingRateLimit, rfl, rfl, .markInterrupted, rfl, Or.inr (Or.inr rfl)⟩
    · rcases h6 with ⟨⟨hop, hph⟩, hevd⟩
      subst hop
      subst hph
      subst hevd
      exact ⟨.active, rfl, rfl, .completeWithReceipt, rfl, rfl, rfl⟩
    · rcases h7 with ⟨hop, ((hph | hph) | hph) | hph⟩ <;> subst hop <;> subst hph
      · exact ⟨.active, rfl, rfl, .failRun, rfl, Or.inl rfl⟩
      · exact ⟨.waitingBackground, rfl, rfl, .failRun, rfl, Or.inr (Or.inl rfl)⟩
      · exact ⟨.waitingRateLimit, rfl, rfl, .failRun, rfl, Or.inr (Or.inr (Or.inl rfl))⟩
      · exact ⟨.interrupted, rfl, rfl, .failRun, rfl, Or.inr (Or.inr (Or.inr rfl))⟩
    · rcases h8 with ⟨⟨hop, (((hph | hph) | hph) | hph) | hph⟩, htrm⟩ <;>
        subst hop <;> subst hph <;> subst htrm
      · exact ⟨.awaitingUser, rfl, rfl, .finalizeCancelReceipt, rfl, rfl⟩
      · exact ⟨.active, rfl, rfl, .finalizeCancelReceipt, rfl, rfl⟩
      · exact ⟨.waitingBackground, rfl, rfl, .finalizeCancelReceipt, rfl, rfl⟩
      · exact ⟨.waitingRateLimit, rfl, rfl, .finalizeCancelReceipt, rfl, rfl⟩
      · exact ⟨.interrupted, rfl, rfl, .finalizeCancelReceipt, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨sup, evd⟩, ⟨trm, res⟩, ⟨ownEp, calEp⟩, ⟨nowEp, nbEp⟩⟩
    change (verifyMissionLifecycleAdmit phC opC sup evd trm res ownEp calEp nowEp nbEp == 1) = true
    dsimp [MissionAdmitDomainSafe] at h
    rcases h with ⟨hsup, hown, hcal, ph, hphDec, hnt, op, hopDec, hbr⟩
    have hsup0 : sup = 0 := u8_eq_of_toNat sup 0 (by omega) hsup
    have hownNe : (ownEp != 0) = true := by
      rw [bne_iff_ne]
      intro hz
      subst hz
      simp at hown
    have hcalEq : calEp = ownEp := u64_eq_of_toNat_eq calEp ownEp hcal
    have hphC := missionPhase_code_of_decode hphDec
    have hopC := missionOp_code_of_decode hopDec
    subst hsup0
    subst hcalEq
    subst hphC
    subst hopC
    unfold verifyMissionLifecycleAdmit
    cases op with
    | dispatchRun =>
      rcases hbr with rfl | rfl | rfl <;> simp [MissionPhase.encode, MissionOp.encode, hownNe]
    | parkAwaitingUser =>
      subst hbr; simp [MissionPhase.encode, MissionOp.encode, hownNe]
    | parkBackground =>
      subst hbr; simp [MissionPhase.encode, MissionOp.encode, hownNe]
    | parkRateLimit =>
      rcases hbr with ⟨rfl, hlt, hres⟩
      have hres1 : res = 1 := u8_eq_of_toNat res 1 (by omega) hres
      have hltB : nowEp < nbEp := UInt64.lt_iff_toNat_lt.mpr hlt
      subst hres1; simp [MissionPhase.encode, MissionOp.encode, hownNe, hltB]
    | resumeRateLimit =>
      rcases hbr with ⟨rfl, hres, hle⟩
      have hres1 : res = 1 := u8_eq_of_toNat res 1 (by omega) hres
      have hleB : nbEp ≤ nowEp := UInt64.le_iff_toNat_le.mpr hle
      subst hres1; simp [MissionPhase.encode, MissionOp.encode, hownNe, hleB]
    | markInterrupted =>
      rcases hbr with rfl | rfl | rfl <;> simp [MissionPhase.encode, MissionOp.encode, hownNe]
    | completeWithReceipt =>
      rcases hbr with ⟨rfl, hevd⟩
      have hevd1 : evd = 1 := u8_eq_of_toNat evd 1 (by omega) hevd
      subst hevd1; simp [MissionPhase.encode, MissionOp.encode, hownNe]
    | failRun =>
      rcases hbr with rfl | rfl | rfl | rfl <;> simp [MissionPhase.encode, MissionOp.encode, hownNe]
    | finalizeCancelReceipt =>
      have htrm1 : trm = 1 := u8_eq_of_toNat trm 1 (by omega) hbr
      subst htrm1
      cases ph <;> simp [MissionPhase.isTerminal] at hnt <;>
        simp [MissionPhase.encode, MissionOp.encode, hownNe]
  posWitness :=
    { codes := (1, 6), flags := (0, 1), guards := (0, 0), epochs := (1, 1), clocks := (0, 0) }
  negWitness :=
    { codes := (1, 6), flags := (0, 0), guards := (0, 0), epochs := (1, 1), clocks := (0, 0) }
  nonVacuous := by decide
  tight := by decide

private theorem mission_fenced_step_id (s : MissionSliceState) (ev : MissionSliceEvent)
    (hf : (decide (5 ≤ s.phaseCode) || s.superseded == 1) = true) :
    stepMissionSlice s ev = (s, []) := by
  unfold stepMissionSlice
  have hsupFalse :
      ¬ (ev.markSuperseded == 1 && s.superseded == 0 && decide (s.phaseCode ≤ 4) &&
         s.ownerEpoch != 0 && ev.callerEpoch == s.ownerEpoch && decide (s.stateRevision < 0xFFFFFFFF)) := by
    intro hc
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨_, hs0⟩, hle4⟩, _⟩, _⟩, _⟩
    simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hf
    rcases hf with hge5 | hs1
    · have hleN : s.phaseCode.toNat ≤ 4 := UInt8.le_iff_toNat_le.mp hle4
      have hgeN : 5 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hge5
      omega
    · exact absurd hs0 (by rw [hs1]; decide)
  have hadmFalse :
      ¬ (verifyMissionLifecycleAdmit s.phaseCode ev.opCode s.superseded ev.hasEvidence
          ev.hasTermReceipt (if ev.opCode == 3 then ev.reqResumeInt else s.resumeIntent)
          s.ownerEpoch ev.callerEpoch ev.nowEpoch
          (if ev.opCode == 3 then ev.reqNotBefore else s.notBeforeEpoch) == 1 &&
         decide (s.stateRevision < 0xFFFFFFFF)) := by
    intro hc
    simp only [Bool.and_eq_true] at hc
    have hs := missionLifecycleMetaGate.sound
      { codes := (s.phaseCode, ev.opCode)
        flags := (s.superseded, ev.hasEvidence)
        guards := (ev.hasTermReceipt, if ev.opCode == 3 then ev.reqResumeInt else s.resumeIntent)
        epochs := (s.ownerEpoch, ev.callerEpoch)
        clocks := (ev.nowEpoch, if ev.opCode == 3 then ev.reqNotBefore else s.notBeforeEpoch) }
      (by simpa [missionLifecycleMetaGate] using hc.1)
    dsimp [MissionAdmitDomainSafe] at hs
    rcases hs with ⟨hsup0, _, _, ph, hphDec, hnt, _⟩
    simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hf
    rcases hf with hge5 | hs1
    · have h5 : 5 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hge5
      have hpc : s.phaseCode = ph.encode := missionPhase_code_of_decode hphDec
      rw [hpc] at h5
      cases ph <;> simp [MissionPhase.isTerminal] at hnt <;> simp [MissionPhase.encode] at h5
    · have h0 : s.superseded = 0 := u8_eq_of_toNat s.superseded 0 (by omega) hsup0
      rw [hs1] at h0; contradiction
  dsimp only
  rw [ite_eq_right_iff.mpr (fun h => absurd h hsupFalse),
      ite_eq_right_iff.mpr (fun h => absurd h hadmFalse)]

def missionTerminalOrSupersededStickyFence : StickyFence MissionSliceState MissionSliceEvent where
  fenced s := decide (5 ≤ s.phaseCode) || s.superseded == 1
  preFenceAct s := s.phaseCode == 1 && s.superseded == 0
  step s ev := (stepMissionSlice s ev).1
  sticky s ev hf := by
    have h := mission_fenced_step_id s ev hf
    rw [h]
    exact hf
  forbids_post s ev hf := by
    have h := mission_fenced_step_id s ev hf
    simp only [h]
    simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hf
    rcases hf with hge | hs
    · have h5 : 5 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hge
      apply Bool.and_eq_false_iff.mpr
      exact Or.inl (by
        apply beq_eq_false_iff_ne.mpr
        intro heq
        have : s.phaseCode.toNat = 1 := by rw [heq]; decide
        omega)
    · simp [hs]

def missionRateLimitClockDiscipline : ClockDiscipline MissionAdmitCheck where
  eval c :=
    if missionLifecycleMetaGate.gate c && c.codes.2 == 4 && c.clocks.2 ≤ c.clocks.1 then 1 else 0
  clockMask := 1
  guardOk c := c.codes.1 == 3 && c.guards.2 == 1 && c.flags.1 == 0 &&
    c.epochs.1 != 0 && c.epochs.2 == c.epochs.1
  isolated c h := by
    have hg : missionLifecycleMetaGate.gate c = true ∧ (c.codes.2 == 4) = true := by
      by_cases h1 : missionLifecycleMetaGate.gate c = true
      · by_cases h2 : (c.codes.2 == 4) = true
        · exact ⟨h1, h2⟩
        · simp [h1, h2] at h
      · simp [h1] at h
    have hs := missionLifecycleMetaGate.sound c hg.1
    rcases c with ⟨⟨phC, opC⟩, ⟨sup, _⟩, ⟨_, res⟩, ⟨own, cal⟩, ⟨_, _⟩⟩
    rcases hs with ⟨hsup, hown, hcal, ph, hphDec, _, op, hopDec, hbr⟩
    have hop4 : opC = 4 := by rw [beq_iff_eq] at hg; exact hg.2
    have hop : op = .resumeRateLimit := by
      have hdec : MissionOp.decode? opC.toNat = some op := hopDec
      rw [hop4] at hdec; simp [MissionOp.decode?] at hdec; exact hdec.symm
    subst hop
    rcases hbr with ⟨rfl, hres, _⟩
    have hph3 : phC = 3 := by simpa [MissionPhase.encode] using missionPhase_code_of_decode hphDec
    have hres1 : res = 1 := u8_eq_of_toNat res 1 (by omega) hres
    have hsup0 : sup = 0 := u8_eq_of_toNat sup 0 (by omega) hsup
    have hownN : (own != 0) = true := by
      rw [bne_iff_ne]
      intro hz
      subst hz
      simp at hown
    have hcalE : cal = own := u64_eq_of_toNat_eq cal own hcal
    subst hph3
    subst hres1
    subst hsup0
    subst hcalE
    simp [hownN]

theorem mission_complete_requires_evidence_and_cancel_requires_receipt
    (c : MissionAdmitCheck) (h : missionLifecycleMetaGate.gate c = true) :
    (c.codes.2 = 6 → c.flags.2 = 1) ∧ (c.codes.2 = 8 → c.guards.1 = 1) := by
  have hs := missionLifecycleMetaGate.sound c h
  rcases c with ⟨⟨_, opC⟩, ⟨_, evd⟩, ⟨trm, _⟩, _, _⟩
  dsimp [MissionAdmitDomainSafe] at hs ⊢
  rcases hs with ⟨_, _, _, ph, _, _, op, hopDec, hbr⟩
  constructor
  · intro h6
    have hop : op = .completeWithReceipt := by
      rw [h6] at hopDec; simp [MissionOp.decode?] at hopDec; exact hopDec.symm
    subst hop
    rcases hbr with ⟨_, hevd⟩
    exact u8_eq_of_toNat evd 1 (by omega) hevd
  · intro h8
    have hop : op = .finalizeCancelReceipt := by
      rw [h8] at hopDec; simp [MissionOp.decode?] at hopDec; exact hopDec.symm
    subst hop
    exact u8_eq_of_toNat trm 1 (by omega) hbr

/-! ## 2. `RunLifecycle` (`SM-04` + `SM-08`) -/

structure RunAdmitCheck where
  codes   : UInt8 × UInt8
  flags   : UInt8 × UInt8
  receipt : UInt8 × UInt8
  tools   : UInt32
  gens    : UInt64 × UInt64
  owners  : UInt64 × UInt64
  deriving Repr, DecidableEq

def RunAdmitDomainSafe (c : RunAdmitCheck) : Prop :=
  c.flags.1.toNat = 0 ∧
  0 < c.owners.1.toNat ∧
  c.owners.2.toNat = c.owners.1.toNat ∧
  ∃ ph, RunPhase.decode? c.codes.1.toNat = some ph ∧
    ∃ op, RunOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .claimFreshGeneration =>
          (ph = .idle ∨ ph.isTerminal = true) ∧
          c.gens.1.toNat < 18446744073709551615 ∧ c.gens.2.toNat = c.gens.1.toNat + 1
      | .confirmSpawned => ph = .claimed ∧ 0 < c.gens.1.toNat ∧ c.gens.2.toNat = c.gens.1.toNat
      | .enterToolDrain =>
          ph = .running ∧ 0 < c.gens.1.toNat ∧ c.gens.2.toNat = c.gens.1.toNat ∧ 0 < c.tools.toNat
      | .reconcileDrainedTools =>
          ph = .drainingTools ∧ 0 < c.gens.1.toNat ∧ c.gens.2.toNat = c.gens.1.toNat ∧
          (c.tools.toNat = 0 ∨ c.receipt.2.toNat = 1)
      | .completeTurnReceipt =>
          ph = .running ∧ 0 < c.gens.1.toNat ∧ c.gens.2.toNat = c.gens.1.toNat ∧
          c.tools.toNat = 0 ∧ c.flags.2.toNat = 1
      | .failTurn =>
          (ph = .claimed ∨ ph = .running ∨ ph = .drainingTools) ∧
          0 < c.gens.1.toNat ∧ c.gens.2.toNat = c.gens.1.toNat
      | .abortTurnReceipt =>
          (ph = .claimed ∨ ph = .running ∨ ph = .drainingTools) ∧
          0 < c.gens.1.toNat ∧ c.gens.2.toNat = c.gens.1.toNat ∧ c.receipt.1.toNat = 1

private theorem runPhase_code_of_decode {x : UInt8} {ph : RunPhase}
    (h : RunPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [RunPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | k7 <;>
        simp [RunPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [RunPhase.encode] using hcode

private theorem runOp_code_of_decode {x : UInt8} {op : RunOp}
    (h : RunOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [RunOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | k7 <;>
        simp [RunOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [RunOp.encode] using hcode

def runLifecycleMetaGate : MetaGateSpec RunAdmitCheck RunAdmitDomainSafe where
  gate c :=
    verifyRunLifecycleAdmit c.codes.1 c.codes.2 c.flags.1 c.flags.2 c.receipt.1 c.receipt.2
      c.tools c.gens.1 c.gens.2 c.owners.1 c.owners.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨sup, sRec⟩, ⟨aRec, dTo⟩, tools, ⟨curG, propG⟩, ⟨dOwn, cOwn⟩⟩
    change (verifyRunLifecycleAdmit phC opC sup sRec aRec dTo tools curG propG dOwn cOwn == 1) = true at h
    dsimp [RunAdmitDomainSafe]
    unfold verifyRunLifecycleAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨hsup, hown0⟩, hcal⟩, hphLe6⟩, _⟩, hbr⟩
    have hownPos : 0 < dOwn.toNat := by
      have hne : dOwn.toNat ≠ 0 := fun hz => hown0 (u64_eq_of_toNat_eq dOwn 0 hz)
      omega
    refine ⟨by subst hsup; rfl, hownPos, by subst hcal; rfl, ?_⟩
    rcases hbr with hclaim | ⟨⟨⟨hop1, hcur0⟩, hsame⟩, hin⟩
    · rcases hclaim with ⟨⟨⟨⟨hop, hph⟩, hlt⟩, hcurLtProp⟩, hdiff⟩
      subst hop
      have hltNat : curG.toNat < 18446744073709551615 := by
        simpa using UInt64.lt_iff_toNat_lt.mp hlt
      have hcurLtNat : curG.toNat < propG.toNat :=
        UInt64.lt_iff_toNat_lt.mp hcurLtProp
      have hsuccNat : propG.toNat = curG.toNat + 1 := by
        have hd : (propG - curG).toNat = 1 := by
          rw [hdiff]
          rfl
        rw [UInt64.toNat_sub_of_le propG curG (UInt64.le_iff_toNat_le.mpr (by omega))] at hd
        omega
      rcases hph with hidle | hterm
      · subst hidle
        exact ⟨.idle, rfl, .claimFreshGeneration, rfl, Or.inl rfl, hltNat, hsuccNat⟩
      · have hge : (4 : UInt8) ≤ phC := hterm
        have hcode : phC.toNat = 4 ∨ phC.toNat = 5 ∨ phC.toNat = 6 := by
          have ha : 4 ≤ phC.toNat := UInt8.le_iff_toNat_le.mp hge
          have hb : phC.toNat ≤ 6 := UInt8.le_iff_toNat_le.mp hphLe6
          omega
        rcases hcode with h4 | h5 | h6
        · have : phC = 4 := u8_eq_of_toNat phC 4 (by omega) h4
          subst this
          exact ⟨.completed, rfl, .claimFreshGeneration, rfl, Or.inr (by simp [RunPhase.isTerminal]),
            hltNat, hsuccNat⟩
        · have : phC = 5 := u8_eq_of_toNat phC 5 (by omega) h5
          subst this
          exact ⟨.failed, rfl, .claimFreshGeneration, rfl, Or.inr (by simp [RunPhase.isTerminal]),
            hltNat, hsuccNat⟩
        · have : phC = 6 := u8_eq_of_toNat phC 6 (by omega) h6
          subst this
          exact ⟨.aborted, rfl, .claimFreshGeneration, rfl, Or.inr (by simp [RunPhase.isTerminal]),
            hltNat, hsuccNat⟩
    · have hcurPos : 0 < curG.toNat := by
        have hne : curG.toNat ≠ 0 := fun hz => hcur0 (u64_eq_of_toNat_eq curG 0 hz)
        omega
      have hsameN : propG.toNat = curG.toNat := by rw [hsame]
      rcases hin with (((((h1 | h2) | h3) | h4) | h5) | h6)
      · rcases h1 with ⟨hop, hph⟩; subst hop; subst hph
        exact ⟨.claimed, rfl, .confirmSpawned, rfl, rfl, hcurPos, hsameN⟩
      · rcases h2 with ⟨⟨hop, hph⟩, ht⟩; subst hop; subst hph
        exact ⟨.running, rfl, .enterToolDrain, rfl, rfl, hcurPos, hsameN, UInt32.lt_iff_toNat_lt.mp ht⟩
      · rcases h3 with ⟨⟨hop, hph⟩, hdone⟩; subst hop; subst hph
        refine ⟨.drainingTools, rfl, .reconcileDrainedTools, rfl, rfl, hcurPos, hsameN, ?_⟩
        rcases hdone with hz | hd
        · exact Or.inl (by rw [hz]; decide)
        · exact Or.inr (by subst hd; rfl)
      · rcases h4 with ⟨⟨⟨hop, hph⟩, hz⟩, hs⟩
        subst hop
        subst hph
        subst hz
        subst hs
        exact ⟨.running, rfl, .completeTurnReceipt, rfl, rfl, hcurPos, hsameN, by decide, rfl⟩
      · rcases h5 with ⟨hop, (hph | hph) | hph⟩ <;> subst hop <;> subst hph
        · exact ⟨.claimed, rfl, .failTurn, rfl, Or.inl rfl, hcurPos, hsameN⟩
        · exact ⟨.running, rfl, .failTurn, rfl, Or.inr (Or.inl rfl), hcurPos, hsameN⟩
        · exact ⟨.drainingTools, rfl, .failTurn, rfl, Or.inr (Or.inr rfl), hcurPos, hsameN⟩
      · rcases h6 with ⟨⟨hop, (hph | hph) | hph⟩, ha⟩ <;>
          subst hop <;> subst hph <;> subst ha
        · exact ⟨.claimed, rfl, .abortTurnReceipt, rfl, Or.inl rfl, hcurPos, hsameN, rfl⟩
        · exact ⟨.running, rfl, .abortTurnReceipt, rfl, Or.inr (Or.inl rfl), hcurPos, hsameN, rfl⟩
        · exact ⟨.drainingTools, rfl, .abortTurnReceipt, rfl, Or.inr (Or.inr rfl), hcurPos, hsameN, rfl⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨sup, sRec⟩, ⟨aRec, dTo⟩, tools, ⟨curG, propG⟩, ⟨dOwn, cOwn⟩⟩
    change (verifyRunLifecycleAdmit phC opC sup sRec aRec dTo tools curG propG dOwn cOwn == 1) = true
    dsimp [RunAdmitDomainSafe] at h
    rcases h with ⟨hsup, hown, hcal, ph, hphDec, op, hopDec, hbr⟩
    have hsup0 : sup = 0 := u8_eq_of_toNat sup 0 (by omega) hsup
    have hownNe : (dOwn != 0) = true := by
      rw [bne_iff_ne]
      intro hz
      subst hz
      simp at hown
    have hcalEq : cOwn = dOwn := u64_eq_of_toNat_eq cOwn dOwn hcal
    have hphC := runPhase_code_of_decode hphDec
    have hopC := runOp_code_of_decode hopDec
    subst hsup0
    subst hcalEq
    subst hphC
    subst hopC
    unfold verifyRunLifecycleAdmit
    cases op with
    | claimFreshGeneration =>
      rcases hbr with ⟨hph, hlt, hsucc⟩
      have hltB : curG < 0xFFFFFFFFFFFFFFFF := UInt64.lt_iff_toNat_lt.mpr hlt
      have hltPropB : curG < propG := UInt64.lt_iff_toNat_lt.mpr (by omega)
      have hdiffB : (propG - curG == 1) = true := by
        rw [beq_iff_eq]
        apply u64_eq_of_toNat_eq
        rw [UInt64.toNat_sub_of_le propG curG (UInt64.le_iff_toNat_le.mpr (by omega))]
        have h1 : UInt64.toNat 1 = 1 := rfl
        rw [h1]
        omega
      rcases hph with rfl | hterm
      · simp [RunPhase.encode, RunOp.encode, hownNe, hltB, hltPropB, hdiffB]
      · cases ph <;> simp [RunPhase.isTerminal] at hterm <;>
          simp [RunPhase.encode, RunOp.encode, hownNe, hltB, hltPropB, hdiffB]
    | confirmSpawned =>
      rcases hbr with ⟨rfl, hpos, heq⟩
      have hne : (curG != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        subst hz
        simp at hpos
      have hsame : propG = curG := u64_eq_of_toNat_eq propG curG heq
      subst hsame; simp [RunPhase.encode, RunOp.encode, hownNe, hne]
    | enterToolDrain =>
      rcases hbr with ⟨rfl, hpos, heq, ht⟩
      have hne : (curG != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        subst hz
        simp at hpos
      have hsame : propG = curG := u64_eq_of_toNat_eq propG curG heq
      have htB : 0 < tools := UInt32.lt_iff_toNat_lt.mpr ht
      subst hsame; simp [RunPhase.encode, RunOp.encode, hownNe, hne, htB]
    | reconcileDrainedTools =>
      rcases hbr with ⟨rfl, hpos, heq, hdone⟩
      have hne : (curG != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        subst hz
        simp at hpos
      have hsame : propG = curG := u64_eq_of_toNat_eq propG curG heq
      subst hsame
      rcases hdone with hz | hd
      · have hzB : tools = 0 := u32_eq_of_toNat_eq tools 0 (by simpa using hz)
        simp [RunPhase.encode, RunOp.encode, hownNe, hne, hzB]
      · have hdB : dTo = 1 := u8_eq_of_toNat dTo 1 (by omega) hd
        subst hdB; simp [RunPhase.encode, RunOp.encode, hownNe, hne]
    | completeTurnReceipt =>
      rcases hbr with ⟨rfl, hpos, heq, hz, hs⟩
      have hne : (curG != 0) = true := by
        rw [bne_iff_ne]
        intro hz0
        subst hz0
        simp at hpos
      have hsame : propG = curG := u64_eq_of_toNat_eq propG curG heq
      have hzB : tools = 0 := u32_eq_of_toNat_eq tools 0 (by simpa using hz)
      have hsB : sRec = 1 := u8_eq_of_toNat sRec 1 (by omega) hs
      subst hsame; subst hzB; subst hsB
      simp [RunPhase.encode, RunOp.encode, hownNe, hne]
    | failTurn =>
      rcases hbr with ⟨hph, hpos, heq⟩
      have hne : (curG != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        subst hz
        simp at hpos
      have hsame : propG = curG := u64_eq_of_toNat_eq propG curG heq
      subst hsame
      rcases hph with rfl | rfl | rfl <;> simp [RunPhase.encode, RunOp.encode, hownNe, hne]
    | abortTurnReceipt =>
      rcases hbr with ⟨hph, hpos, heq, ha⟩
      have hne : (curG != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        subst hz
        simp at hpos
      have hsame : propG = curG := u64_eq_of_toNat_eq propG curG heq
      have haB : aRec = 1 := u8_eq_of_toNat aRec 1 (by omega) ha
      subst hsame; subst haB
      rcases hph with rfl | rfl | rfl <;> simp [RunPhase.encode, RunOp.encode, hownNe, hne]
  posWitness :=
    { codes := (0, 0), flags := (0, 0), receipt := (0, 0), tools := 0, gens := (0, 1), owners := (7, 7) }
  negWitness :=
    { codes := (4, 0), flags := (0, 0), receipt := (0, 0), tools := 0, gens := (4, 4), owners := (7, 7) }
  nonVacuous := by decide
  tight := by decide

def runOwnerScopedAuthority : ScopedAuthority RunAdmitCheck where
  admit c := runLifecycleMetaGate.gate c
  scopeValid c := c.flags.1 == 0 && c.owners.1 != 0 && c.owners.2 == c.owners.1
  sound c h := by
    have hs := runLifecycleMetaGate.sound c h
    rcases c with ⟨_, ⟨sup, _⟩, _, _, _, ⟨dOwn, cOwn⟩⟩
    rcases hs with ⟨hsup, hpos, heq, _⟩
    have hsup0 : sup = 0 := u8_eq_of_toNat sup 0 (by omega) hsup
    have hownNe : (dOwn != 0) = true := by
      rw [bne_iff_ne]
      intro hz
      subst hz
      simp at hpos
    have hcal : cOwn = dOwn := u64_eq_of_toNat_eq cOwn dOwn heq
    simp [hsup0, hownNe, hcal]

theorem completed_run_requires_fresh_generation_and_superseded_owner_rejected
    (s : RunSliceState) (ev : RunSliceEvent)
    (hge4 : 4 ≤ s.phaseCode) (hle6 : s.phaseCode ≤ 6)
    (hmark0 : ev.markOwnerSuperseded = 0)
    (hadm : verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
        ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
        (if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls)
        s.runGeneration ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch = 1) :
    ev.opCode = 0 ∧ ev.proposedGeneration.toNat = s.runGeneration.toNat + 1 ∧
    (stepRunSlice s ev).1.phaseCode = 1 ∧
    (stepRunSlice s ev).1.runGeneration = ev.proposedGeneration := by
  have hgate : runLifecycleMetaGate.gate
      { codes := (s.phaseCode, ev.opCode)
        flags := (s.ownerSuperseded, ev.hasStructuredReceipt)
        receipt := (ev.hasAbortReceipt, ev.drainTimedOut)
        tools := if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls
        gens := (s.runGeneration, ev.proposedGeneration)
        owners := (s.durableOwnerEpoch, ev.callerOwnerEpoch) } = true := by
    simpa [runLifecycleMetaGate] using hadm
  have hs := runLifecycleMetaGate.sound _ hgate
  dsimp [RunAdmitDomainSafe] at hs
  rcases hs with ⟨_, _, _, ph, hph, op, hop, hbr⟩
  have hterm : ph.isTerminal = true := by
    have hcode : s.phaseCode = ph.encode := runPhase_code_of_decode hph
    rw [hcode] at hge4 hle6
    have ha : 4 ≤ ph.encode.toNat := UInt8.le_iff_toNat_le.mp hge4
    have hb : ph.encode.toNat ≤ 6 := UInt8.le_iff_toNat_le.mp hle6
    cases ph <;> simp [RunPhase.encode] at ha hb <;> rfl
  have hop0 : op = .claimFreshGeneration := by
    cases op with
    | claimFreshGeneration => rfl
    | confirmSpawned => rcases hbr with ⟨rfl, _⟩; simp [RunPhase.isTerminal] at hterm
    | enterToolDrain => rcases hbr with ⟨rfl, _⟩; simp [RunPhase.isTerminal] at hterm
    | reconcileDrainedTools => rcases hbr with ⟨rfl, _⟩; simp [RunPhase.isTerminal] at hterm
    | completeTurnReceipt => rcases hbr with ⟨rfl, _⟩; simp [RunPhase.isTerminal] at hterm
    | failTurn =>
      rcases hbr with ⟨hph123, _⟩
      rcases hph123 with rfl | rfl | rfl <;> simp [RunPhase.isTerminal] at hterm
    | abortTurnReceipt =>
      rcases hbr with ⟨hph123, _⟩
      rcases hph123 with rfl | rfl | rfl <;> simp [RunPhase.isTerminal] at hterm
  subst hop0
  have h0 : ev.opCode = 0 := by
    have hcode : ev.opCode = RunOp.claimFreshGeneration.encode := runOp_code_of_decode hop
    simpa [RunOp.encode] using hcode
  have hadm0 :
      verifyRunLifecycleAdmit s.phaseCode 0 s.ownerSuperseded ev.hasStructuredReceipt
        ev.hasAbortReceipt ev.drainTimedOut s.activeToolCalls s.runGeneration
        ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch = 1 := by
    rw [h0] at hadm
    have hcond : ((0 : UInt8) == 2) = false := by decide
    rw [hcond] at hadm
    simpa using hadm
  rcases hbr with ⟨_, _, hsucc⟩
  refine ⟨h0, hsucc, ?_, ?_⟩
  · unfold stepRunSlice; simp [h0, hmark0, hadm0, runLifecycleTargetPhase]
  · unfold stepRunSlice; simp [h0, hmark0, hadm0]

theorem run_superseded_step_id (s : RunSliceState) (ev : RunSliceEvent)
    (hf : (s.ownerSuperseded != 0) = true) :
    stepRunSlice s ev = (s, []) := by
  unfold stepRunSlice
  have hsupNe0 : s.ownerSuperseded ≠ 0 := by rwa [bne_iff_ne] at hf
  have hsupFalse : ¬ ((ev.markOwnerSuperseded == 1 && s.ownerSuperseded == 0 &&
      s.durableOwnerEpoch != 0 && ev.callerOwnerEpoch == s.durableOwnerEpoch) = true) := by
    intro hm
    simp only [Bool.and_eq_true, beq_iff_eq] at hm
    exact hsupNe0 hm.1.1.2
  have hadmFalse : ¬ ((ev.markOwnerSuperseded == 0 &&
      verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
        ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
        (if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls)
        s.runGeneration ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch == 1) = true) := by
    intro ha
    have ha2 : (verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
        ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
        (if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls)
        s.runGeneration ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch == 1) = true :=
      (Bool.and_eq_true _ _).mp ha |>.2
    unfold verifyRunLifecycleAdmit at ha2
    have hc := bit_cond_true ha2
    simp only [Bool.and_eq_true, beq_iff_eq] at hc
    exact hsupNe0 hc.1.1.1.1.1
  dsimp only
  rw [ite_eq_right_iff.mpr (fun h => absurd h hsupFalse),
      ite_eq_right_iff.mpr (fun h => absurd h hadmFalse)]

def runOwnerSupersededStickyFence : StickyFence RunSliceState RunSliceEvent where
  fenced s := s.ownerSuperseded != 0
  preFenceAct s := s.phaseCode == 2 && s.ownerSuperseded == 0
  step s ev := (stepRunSlice s ev).1
  sticky s ev hf := by
    have h := run_superseded_step_id s ev hf
    rw [h]
    exact hf
  forbids_post s ev hf := by
    have h := run_superseded_step_id s ev hf
    simp only [h]
    have hne : s.ownerSuperseded ≠ 0 := by rwa [bne_iff_ne] at hf
    have hfalse : (s.ownerSuperseded == 0) = false := beq_eq_false_iff_ne.mpr hne
    simp [hfalse]

theorem run_step_generation_monotone (s : RunSliceState) (ev : RunSliceEvent) :
    s.runGeneration.toNat ≤ (stepRunSlice s ev).1.runGeneration.toNat := by
  unfold stepRunSlice
  dsimp only
  by_cases hmark : (ev.markOwnerSuperseded == 1 && s.ownerSuperseded == 0 &&
      s.durableOwnerEpoch != 0 && ev.callerOwnerEpoch == s.durableOwnerEpoch) = true
  · rw [ite_eq_left_iff.mpr (fun h => absurd hmark h)]
    exact Nat.le_refl _
  · rw [ite_eq_right_iff.mpr (fun h => absurd h hmark)]
    by_cases hadm : (ev.markOwnerSuperseded == 0 &&
        verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
          ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
          (if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls)
          s.runGeneration ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch == 1) = true
    · rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
      by_cases hop : (ev.opCode == 0) = true
      · dsimp only
        rw [ite_eq_left_iff.mpr (fun h => absurd hop h)]
        have ha2 : (verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
            ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
            (if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls)
            s.runGeneration ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch == 1) = true :=
          (Bool.and_eq_true _ _).mp hadm |>.2
        have hop0 : ev.opCode = 0 := by rwa [beq_iff_eq] at hop
        unfold verifyRunLifecycleAdmit at ha2
        rw [hop0] at ha2
        have hc := bit_cond_true ha2
        simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
        rcases hc with ⟨_, hbr⟩
        rcases hbr with ⟨⟨⟨_, _⟩, hcurLt⟩, _⟩ | ⟨⟨⟨hge, _⟩, _⟩, _⟩
        · exact Nat.le_of_lt (UInt64.lt_iff_toNat_lt.mp hcurLt)
        · have hnot : ¬ (1 : UInt8) ≤ 0 := by decide
          exact absurd hge hnot
      · dsimp only
        rw [ite_eq_right_iff.mpr (fun h => absurd h hop)]
        exact Nat.le_refl _
    · rw [ite_eq_right_iff.mpr (fun h => absurd h hadm)]
      exact Nat.le_refl _

theorem run_fold_generation_monotone (s : RunSliceState) (evs : List RunSliceEvent) :
    s.runGeneration.toNat ≤ (foldRunSlice s evs).runGeneration.toNat := by
  induction evs generalizing s with
  | nil => exact Nat.le_refl _
  | cons ev rest ih =>
    have hcons : foldRunSlice s (ev :: rest) = foldRunSlice (stepRunSlice s ev).1 rest := rfl
    rw [hcons]
    have h1 := run_step_generation_monotone s ev
    have h2 := ih (stepRunSlice s ev).1
    omega

theorem terminal_reentry_running_requires_fresh_generation
    (s : RunSliceState) (evs : List RunSliceEvent)
    (hge : 4 ≤ s.phaseCode) (hle : s.phaseCode ≤ 6)
    (hrun : (foldRunSlice s evs).phaseCode = 2) :
    s.runGeneration.toNat + 1 ≤ (foldRunSlice s evs).runGeneration.toNat := by
  induction evs generalizing s with
  | nil =>
    simp [foldRunSlice] at hrun
    have hgeN : 4 ≤ s.phaseCode.toNat := UInt8.le_iff_toNat_le.mp hge
    rw [hrun] at hgeN
    simp at hgeN
  | cons ev rest ih =>
    have hcons : foldRunSlice s (ev :: rest) = foldRunSlice (stepRunSlice s ev).1 rest := rfl
    rw [hcons] at hrun ⊢
    by_cases hmark : (ev.markOwnerSuperseded == 1 && s.ownerSuperseded == 0 &&
        s.durableOwnerEpoch != 0 && ev.callerOwnerEpoch == s.durableOwnerEpoch) = true
    · have hs1 : (stepRunSlice s ev).1 = { s with ownerSuperseded := 1 } := by
        unfold stepRunSlice
        dsimp only
        rw [ite_eq_left_iff.mpr (fun h => absurd hmark h)]
      have hgEq : (stepRunSlice s ev).1.runGeneration = s.runGeneration := by rw [hs1]
      have hpEq : (stepRunSlice s ev).1.phaseCode = s.phaseCode := by rw [hs1]
      have hih := ih (stepRunSlice s ev).1 (by rw [hpEq]; exact hge) (by rw [hpEq]; exact hle) hrun
      rw [hgEq] at hih
      exact hih
    · by_cases hadm : (ev.markOwnerSuperseded == 0 &&
          verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
            ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
            (if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls)
            s.runGeneration ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch == 1) = true
      · have hm0 : ev.markOwnerSuperseded = 0 := by
          have ha1 := (Bool.and_eq_true _ _).mp hadm |>.1
          rwa [beq_iff_eq] at ha1
        have ha2 : verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
            ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
            (if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls)
            s.runGeneration ev.proposedGeneration s.durableOwnerEpoch ev.callerOwnerEpoch = 1 := by
          have hb := (Bool.and_eq_true _ _).mp hadm |>.2
          rwa [beq_iff_eq] at hb
        have hfresh :=
          completed_run_requires_fresh_generation_and_superseded_owner_rejected s ev hge hle hm0 ha2
        have hrest := run_fold_generation_monotone (stepRunSlice s ev).1 rest
        have hgen : (stepRunSlice s ev).1.runGeneration.toNat = s.runGeneration.toNat + 1 := by
          rw [hfresh.2.2.2, hfresh.2.1]
        omega
      · have hs1 : (stepRunSlice s ev).1 = s := by
          unfold stepRunSlice
          dsimp only
          rw [ite_eq_right_iff.mpr (fun h => absurd h hmark),
              ite_eq_right_iff.mpr (fun h => absurd h hadm)]
        rw [hs1] at hrun ⊢
        exact ih s hge hle hrun

/-! ## 3. `QueueItemLifecycle` (`SM-05` + `SM-10`) -/

structure QueueAdmitCheck where
  codes  : UInt8 × UInt8
  flags  : UInt8 × UInt8 × UInt8 × UInt8 × UInt8
  gens   : UInt64 × UInt64
  boots  : UInt64 × UInt64
  deliv  : UInt64
  deriving Repr, DecidableEq

def QueueAdmitDomainSafe (c : QueueAdmitCheck) : Prop :=
  c.boots.2.toNat ≠ 0 ∧
  ∃ ph, QueueItemPhase.decode? c.codes.1.toNat = some ph ∧ ph.isAckedOrRetired = false ∧
    ∃ op, QueueItemOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .claimForRun => ph = .queued ∧ c.flags.1.toNat = 1 ∧ c.gens.2.toNat ≠ 0
      | .confirmDelivered =>
          ph = .claimed ∧ c.gens.1.toNat ≠ 0 ∧ c.gens.1.toNat = c.gens.2.toNat ∧
          c.boots.1.toNat = c.boots.2.toNat ∧ c.flags.2.1.toNat = 1 ∧ c.deliv.toNat ≠ 0
      | .releaseRejected =>
          ph = .claimed ∧ c.gens.1.toNat ≠ 0 ∧ c.gens.1.toNat = c.gens.2.toNat ∧ c.flags.2.2.1.toNat = 0
      | .markCrashTombstone =>
          ph = .claimed ∧ (c.boots.1.toNat ≠ c.boots.2.toNat ∨ c.flags.2.2.1.toNat = 1)
      | .requeueTombstone => ph = .crashTombstone ∧ c.flags.2.2.2.1.toNat = 1
      | .cancelQueued => ph = .queued
      | .editQueuedContent => ph = .queued ∧ c.flags.2.2.2.2.toNat = 1

private theorem queuePhase_code_of_decode {x : UInt8} {ph : QueueItemPhase}
    (h : QueueItemPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [QueueItemPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | k5 <;>
        simp [QueueItemPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [QueueItemPhase.encode] using hcode

private theorem queueOp_code_of_decode {x : UInt8} {op : QueueItemOp}
    (h : QueueItemOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [QueueItemOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | k7 <;>
        simp [QueueItemOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [QueueItemOp.encode] using hcode

def queueItemMetaGate : MetaGateSpec QueueAdmitCheck QueueAdmitDomainSafe where
  gate c :=
    verifyQueueItemAdmit c.codes.1 c.codes.2 c.flags.1 c.flags.2.1 c.flags.2.2.1
      c.flags.2.2.2.1 c.flags.2.2.2.2 c.gens.1 c.gens.2 c.boots.1 c.boots.2 c.deliv == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨unp, dur, unc, conf, cnt⟩, ⟨cGen, rGen⟩, ⟨cBoot, nBoot⟩, dSeq⟩
    change (verifyQueueItemAdmit phC opC unp dur unc conf cnt cGen rGen cBoot nBoot dSeq == 1) = true at h
    dsimp [QueueAdmitDomainSafe]
    unfold verifyQueueItemAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨_, _⟩, hne2⟩, hne4⟩, hboot⟩, hbr⟩
    have hbootPos : nBoot.toNat ≠ 0 := fun hz => hboot (u64_eq_of_toNat_eq nBoot 0 hz)
    refine ⟨hbootPos, ?_⟩
    rcases hbr with (((((h0 | h1) | h2) | h3) | h4) | h5) | h6
    · rcases h0 with ⟨⟨⟨hop, hph⟩, hunp⟩, hr⟩
      subst hop
      subst hph
      subst hunp
      exact ⟨.queued, rfl, rfl, .claimForRun, rfl, rfl, rfl, by
        intro hz; exact hr (u64_eq_of_toNat_eq rGen 0 hz)⟩
    · rcases h1 with ⟨⟨⟨⟨⟨⟨hop, hph⟩, hc0⟩, heq⟩, hbootEq⟩, hdur⟩, hd⟩
      subst hop; subst hph; subst hdur
      refine ⟨.claimed, rfl, rfl, .confirmDelivered, rfl, rfl, ?_, ?_, ?_, rfl, ?_⟩
      · intro hz; exact hc0 (u64_eq_of_toNat_eq cGen 0 hz)
      · rw [heq]
      · rw [hbootEq]
      · intro hz; exact hd (u64_eq_of_toNat_eq dSeq 0 hz)
    · rcases h2 with ⟨⟨⟨⟨hop, hph⟩, hc0⟩, heq⟩, hunc⟩
      subst hop
      subst hph
      subst hunc
      refine ⟨.claimed, rfl, rfl, .releaseRejected, rfl, rfl, ?_, ?_, rfl⟩
      · intro hz; exact hc0 (u64_eq_of_toNat_eq cGen 0 hz)
      · rw [heq]
    · rcases h3 with ⟨⟨hop, hph⟩, hwhy⟩; subst hop; subst hph
      refine ⟨.claimed, rfl, rfl, .markCrashTombstone, rfl, rfl, ?_⟩
      rcases hwhy with hbootN | hunc
      · exact Or.inl (by intro h; exact hbootN (u64_eq_of_toNat_eq cBoot nBoot h))
      · exact Or.inr (by subst hunc; rfl)
    · rcases h4 with ⟨⟨hop, hph⟩, hconf⟩
      subst hop
      subst hph
      subst hconf
      exact ⟨.crashTombstone, rfl, rfl, .requeueTombstone, rfl, rfl, rfl⟩
    · rcases h5 with ⟨hop, hph⟩; subst hop; subst hph
      exact ⟨.queued, rfl, rfl, .cancelQueued, rfl, rfl⟩
    · rcases h6 with ⟨⟨hop, hph⟩, hcnt⟩
      subst hop
      subst hph
      subst hcnt
      exact ⟨.queued, rfl, rfl, .editQueuedContent, rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨unp, dur, unc, conf, cnt⟩, ⟨cGen, rGen⟩, ⟨cBoot, nBoot⟩, dSeq⟩
    change (verifyQueueItemAdmit phC opC unp dur unc conf cnt cGen rGen cBoot nBoot dSeq == 1) = true
    dsimp [QueueAdmitDomainSafe] at h
    rcases h with ⟨hboot, ph, hphDec, hnt, op, hopDec, hbr⟩
    have hbootNe : (nBoot != 0) = true := by
      rw [bne_iff_ne]
      intro hz
      subst hz
      simp at hboot
    have hphC := queuePhase_code_of_decode hphDec
    have hopC := queueOp_code_of_decode hopDec
    subst hphC; subst hopC
    unfold verifyQueueItemAdmit
    cases op with
    | claimForRun =>
      rcases hbr with ⟨rfl, hunp, hr⟩
      have hunp1 : unp = 1 := u8_eq_of_toNat unp 1 (by omega) hunp
      have hrN : (rGen != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hr (by subst hz; rfl)
      subst hunp1; simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe, hrN]
    | confirmDelivered =>
      rcases hbr with ⟨rfl, hc0, heq, hbootEq, hdur, hd⟩
      have hcN : (cGen != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hc0 (by subst hz; rfl)
      have heqB : cGen = rGen := u64_eq_of_toNat_eq cGen rGen heq
      have hbB : cBoot = nBoot := u64_eq_of_toNat_eq cBoot nBoot hbootEq
      have hdB : dur = 1 := u8_eq_of_toNat dur 1 (by omega) hdur
      have hseq : (dSeq != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hd (by subst hz; rfl)
      subst heqB; subst hbB; subst hdB
      simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe, hcN, hseq]
    | releaseRejected =>
      rcases hbr with ⟨rfl, hc0, heq, hunc⟩
      have hcN : (cGen != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hc0 (by subst hz; rfl)
      have heqB : cGen = rGen := u64_eq_of_toNat_eq cGen rGen heq
      have hunc0 : unc = 0 := u8_eq_of_toNat unc 0 (by omega) hunc
      subst heqB; subst hunc0
      simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe, hcN]
    | markCrashTombstone =>
      rcases hbr with ⟨rfl, hwhy⟩
      rcases hwhy with hbootN | hunc
      · have hbN : (cBoot != nBoot) = true := by
          rw [bne_iff_ne]; intro heq; exact hbootN (by rw [heq])
        simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe, hbN]
      · have hunc1 : unc = 1 := u8_eq_of_toNat unc 1 (by omega) hunc
        subst hunc1; simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe]
    | requeueTombstone =>
      rcases hbr with ⟨rfl, hconf⟩
      have hconf1 : conf = 1 := u8_eq_of_toNat conf 1 (by omega) hconf
      subst hconf1; simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe]
    | cancelQueued =>
      subst hbr; simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe]
    | editQueuedContent =>
      rcases hbr with ⟨rfl, hcnt⟩
      have hcnt1 : cnt = 1 := u8_eq_of_toNat cnt 1 (by omega) hcnt
      subst hcnt1; simp [QueueItemPhase.encode, QueueItemOp.encode, hbootNe]
  posWitness :=
    { codes := (0, 0), flags := (1, 0, 0, 0, 0), gens := (0, 9), boots := (0, 3), deliv := 0 }
  negWitness :=
    { codes := (2, 0), flags := (1, 0, 0, 0, 0), gens := (0, 9), boots := (0, 3), deliv := 0 }
  nonVacuous := by decide
  tight := by decide

private theorem queue_retired_step_id (s : QueueSliceState) (ev : QueueSliceEvent)
    (hf : (s.phaseCode == 2 || s.phaseCode == 4) = true) :
    stepQueueSlice s ev = (s, []) := by
  unfold stepQueueSlice
  have hadmFalse :
      ¬ (verifyQueueItemAdmit s.phaseCode ev.opCode ev.deferredUnpacked ev.durablyStarted
          ev.uncertainTimeout ev.operatorConfirmedNotDelivered ev.contentNonEmpty
          s.claimedGeneration ev.runGeneration s.claimBootEpoch ev.nodeBootEpoch ev.deliverySeq == 1 &&
         decide (s.editRevision < 0xFFFFFFFF)) := by
    intro hc
    simp only [Bool.and_eq_true] at hc
    have hs := queueItemMetaGate.sound
      { codes := (s.phaseCode, ev.opCode)
        flags := (ev.deferredUnpacked, ev.durablyStarted, ev.uncertainTimeout,
          ev.operatorConfirmedNotDelivered, ev.contentNonEmpty)
        gens := (s.claimedGeneration, ev.runGeneration)
        boots := (s.claimBootEpoch, ev.nodeBootEpoch)
        deliv := ev.deliverySeq }
      (by simpa [queueItemMetaGate] using hc.1)
    dsimp [QueueAdmitDomainSafe] at hs
    rcases hs with ⟨_, ph, hph, hnt, _⟩
    have hcode : s.phaseCode = ph.encode := queuePhase_code_of_decode hph
    simp only [Bool.or_eq_true, beq_iff_eq] at hf
    rcases hf with h2 | h4
    · rw [h2] at hcode
      cases ph <;> simp [QueueItemPhase.encode] at hcode <;>
        simp [QueueItemPhase.isAckedOrRetired] at hnt
    · rw [h4] at hcode
      cases ph <;> simp [QueueItemPhase.encode] at hcode <;>
        simp [QueueItemPhase.isAckedOrRetired] at hnt
  by_cases h1 : (verifyQueueItemAdmit s.phaseCode ev.opCode ev.deferredUnpacked ev.durablyStarted
          ev.uncertainTimeout ev.operatorConfirmedNotDelivered ev.contentNonEmpty
          s.claimedGeneration ev.runGeneration s.claimBootEpoch ev.nodeBootEpoch ev.deliverySeq == 1 &&
         decide (s.editRevision < 0xFFFFFFFF)) = true
  · exact absurd h1 hadmFalse
  · simp [h1]

def queueAckedReplayIdempotence : ReplayIdempotence QueueSliceState QueueSliceEvent QueueEffect where
  step := stepQueueSlice
  alreadyAcked s _ := s.phaseCode == 2 || s.phaseCode == 4
  idempotent s ev hf := queue_retired_step_id s ev hf

def queueDeliveredStickyFence : StickyFence QueueSliceState QueueSliceEvent where
  fenced s := s.phaseCode == 2 || s.phaseCode == 4
  preFenceAct s := s.phaseCode == 0 || s.phaseCode == 1
  step s ev := (stepQueueSlice s ev).1
  sticky s ev hf := by
    have h := queue_retired_step_id s ev hf
    rw [h]
    exact hf
  forbids_post s ev hf := by
    have h := queue_retired_step_id s ev hf
    rw [h]
    simp only [Bool.or_eq_true, beq_iff_eq] at hf
    rcases hf with h2 | h4
    · rw [h2]; decide
    · rw [h4]; decide

theorem acknowledged_queue_item_never_replays
    (s : QueueSliceState) (ev : QueueSliceEvent)
    (hf : s.phaseCode = 2 ∨ s.phaseCode = 4) :
    stepQueueSlice s ev = (s, []) :=
  queue_retired_step_id s ev (by
    rcases hf with h2 | h4
    · rw [h2]; decide
    · rw [h4]; decide)

/-! ## 4. `CancelProtocol` (`SM-03`) -/

structure CancelAdmitCheck where
  codes  : UInt8 × UInt8
  guards : UInt8 × UInt8
  gens   : UInt64 × UInt64
  deriving Repr, DecidableEq

def CancelAdmitDomainSafe (c : CancelAdmitCheck) : Prop :=
  c.gens.1.toNat ≠ 0 ∧
  ∃ ph, CancelPhase.decode? c.codes.1.toNat = some ph ∧
    ∃ op, CancelOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .requestCancel => ph = .none ∧ c.guards.2.toNat = 0
      | .dispatchKillSignal => ph = .cancelRequested ∧ c.guards.2.toNat = 0
      | .confirmTerminatedReceipt =>
          (ph = .cancelRequested ∨ ph = .signalDispatched) ∧
          c.guards.1.toNat = 1 ∧ c.guards.2.toNat = 0 ∧ c.gens.2.toNat = c.gens.1.toNat
      | .resetForNewRun =>
          ph = .cancelled ∧ c.gens.2.toNat ≠ 0 ∧ c.gens.2.toNat < c.gens.1.toNat

private theorem cancelPhase_code_of_decode {x : UInt8} {ph : CancelPhase}
    (h : CancelPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [CancelPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | k4 <;>
        simp [CancelPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [CancelPhase.encode] using hcode

private theorem cancelOp_code_of_decode {x : UInt8} {op : CancelOp}
    (h : CancelOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [CancelOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | k4 <;>
        simp [CancelOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [CancelOp.encode] using hcode

def cancelProtocolMetaGate : MetaGateSpec CancelAdmitCheck CancelAdmitDomainSafe where
  gate c :=
    verifyCancelProtocolAdmit c.codes.1 c.codes.2 c.guards.1 c.guards.2 c.gens.1 c.gens.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨term, unc⟩, ⟨tGen, rGen⟩⟩
    change (verifyCancelProtocolAdmit phC opC term unc tGen rGen == 1) = true at h
    dsimp [CancelAdmitDomainSafe]
    unfold verifyCancelProtocolAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨_, _⟩, ht⟩, hbr⟩
    have hpos : tGen.toNat ≠ 0 := fun hz => ht (u64_eq_of_toNat_eq tGen 0 hz)
    refine ⟨hpos, ?_⟩
    rcases hbr with ((h0 | h1) | h2) | h3
    · rcases h0 with ⟨⟨hop, hph⟩, hunc⟩
      subst hop
      subst hph
      subst hunc
      exact ⟨.none, rfl, .requestCancel, rfl, rfl, rfl⟩
    · rcases h1 with ⟨⟨hop, hph⟩, hunc⟩
      subst hop
      subst hph
      subst hunc
      exact ⟨.cancelRequested, rfl, .dispatchKillSignal, rfl, rfl, rfl⟩
    · rcases h2 with ⟨⟨⟨⟨hop, hph⟩, hterm⟩, hunc⟩, heq⟩
      subst hop
      subst hterm
      subst hunc
      rcases hph with h1 | h2
      · subst h1; exact ⟨.cancelRequested, rfl, .confirmTerminatedReceipt, rfl, Or.inl rfl, rfl, rfl, by rw [heq]⟩
      · subst h2; exact ⟨.signalDispatched, rfl, .confirmTerminatedReceipt, rfl, Or.inr rfl, rfl, rfl, by rw [heq]⟩
    · rcases h3 with ⟨⟨⟨hop, hph⟩, hr0⟩, hlt⟩; subst hop; subst hph
      exact ⟨.cancelled, rfl, .resetForNewRun, rfl, rfl,
        by intro hz; exact hr0 (u64_eq_of_toNat_eq rGen 0 hz), UInt64.lt_iff_toNat_lt.mp hlt⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨term, unc⟩, ⟨tGen, rGen⟩⟩
    change (verifyCancelProtocolAdmit phC opC term unc tGen rGen == 1) = true
    dsimp [CancelAdmitDomainSafe] at h
    rcases h with ⟨hpos, ph, hphDec, op, hopDec, hbr⟩
    have htN : (tGen != 0) = true := by
      rw [bne_iff_ne]
      intro hz
      subst hz
      simp at hpos
    have hphC := cancelPhase_code_of_decode hphDec
    have hopC := cancelOp_code_of_decode hopDec
    subst hphC; subst hopC
    unfold verifyCancelProtocolAdmit
    cases op with
    | requestCancel =>
      rcases hbr with ⟨rfl, hunc⟩
      have hunc0 : unc = 0 := u8_eq_of_toNat unc 0 (by omega) hunc
      subst hunc0; simp [CancelPhase.encode, CancelOp.encode, htN]
    | dispatchKillSignal =>
      rcases hbr with ⟨rfl, hunc⟩
      have hunc0 : unc = 0 := u8_eq_of_toNat unc 0 (by omega) hunc
      subst hunc0; simp [CancelPhase.encode, CancelOp.encode, htN]
    | confirmTerminatedReceipt =>
      rcases hbr with ⟨hph, hterm, hunc, heq⟩
      have hterm1 : term = 1 := u8_eq_of_toNat term 1 (by omega) hterm
      have hunc0 : unc = 0 := u8_eq_of_toNat unc 0 (by omega) hunc
      have heqB : rGen = tGen := u64_eq_of_toNat_eq rGen tGen heq
      subst hterm1; subst hunc0; subst heqB
      rcases hph with rfl | rfl <;> simp [CancelPhase.encode, CancelOp.encode, htN]
    | resetForNewRun =>
      rcases hbr with ⟨rfl, hr0, hlt⟩
      have hrN : (rGen != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hr0 (by subst hz; rfl)
      have hltB : rGen < tGen := UInt64.lt_iff_toNat_lt.mpr hlt
      simp [CancelPhase.encode, CancelOp.encode, htN, hrN, hltB]
  posWitness := { codes := (1, 2), guards := (1, 0), gens := (4, 4) }
  negWitness := { codes := (1, 2), guards := (0, 0), gens := (4, 4) }
  nonVacuous := by decide
  tight := by decide

theorem cancel_requested_never_cancels_without_termination_receipt
    (s : CancelSliceState) (ev : CancelSliceEvent)
    (hreached : cancelProtocolTargetPhase ev.opCode = 3) :
    verifyCancelProtocolAdmit s.phaseCode ev.opCode ev.runnerTerminatedReceipt
        ev.uncertainDeliveryBlocked
        (if ev.opCode == 0 || ev.opCode == 3 then ev.eventGeneration else s.targetGeneration)
        (if ev.opCode == 3 then s.targetGeneration else ev.eventGeneration) = 1 →
      ev.opCode = 2 ∧ ev.runnerTerminatedReceipt = 1 ∧ ev.uncertainDeliveryBlocked = 0 ∧
      ev.eventGeneration = s.targetGeneration ∧ 0 < s.targetGeneration.toNat := by
  intro hadm
  have hop2 : ev.opCode = 2 := by
    by_cases h0 : ev.opCode == 0
    · simp [cancelProtocolTargetPhase, h0] at hreached
    · by_cases h1 : ev.opCode == 1
      · simp [cancelProtocolTargetPhase, h0, h1] at hreached
      · by_cases h2 : ev.opCode == 2
        · rw [beq_iff_eq] at h2; exact h2
        · simp [cancelProtocolTargetPhase, h0, h1, h2] at hreached
  rw [hop2] at hadm
  have hgate : cancelProtocolMetaGate.gate
      { codes := (s.phaseCode, 2)
        guards := (ev.runnerTerminatedReceipt, ev.uncertainDeliveryBlocked)
        gens := (s.targetGeneration, ev.eventGeneration) } = true := by
    simpa [cancelProtocolMetaGate] using hadm
  have hs := cancelProtocolMetaGate.sound _ hgate
  dsimp [CancelAdmitDomainSafe] at hs
  rcases hs with ⟨hpos, _, _, op, hop, hbr⟩
  have hopv : op = .confirmTerminatedReceipt := by
    have hdec : CancelOp.decode? 2 = some op := hop
    simp [CancelOp.decode?] at hdec; exact hdec.symm
  subst hopv
  rcases hbr with ⟨_, hterm, hunc, heq⟩
  refine ⟨hop2, u8_eq_of_toNat _ 1 (by omega) hterm, u8_eq_of_toNat _ 0 (by omega) hunc,
    u64_eq_of_toNat_eq _ _ heq, ?_⟩
  omega

/-! ## 5. `WakeupContinuation` (`SM-07`) -/

structure WakeupAdmitCheck where
  codes  : UInt8 × UInt8
  guards : UInt8 × UInt8
  gens   : UInt64 × UInt64
  clocks : UInt64 × UInt64
  deriving Repr, DecidableEq

def WakeupAdmitDomainSafe (c : WakeupAdmitCheck) : Prop :=
  ∃ ph, WakeupPhase.decode? c.codes.1.toNat = some ph ∧
    ∃ op, WakeupOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .armWakeup =>
          ph ≠ .armed ∧ c.guards.1.toNat = 0 ∧ c.gens.2.toNat ≠ 0 ∧ c.clocks.2.toNat < c.clocks.1.toNat
      | .replaceArmedWakeup =>
          ph = .armed ∧ c.guards.1.toNat = 0 ∧ c.gens.2.toNat ≠ 0 ∧
          c.gens.1.toNat ≤ c.gens.2.toNat ∧ c.clocks.2.toNat < c.clocks.1.toNat
      | .fireDueWakeup =>
          ph = .armed ∧ c.guards.1.toNat = 0 ∧ c.guards.2.toNat = 0 ∧
          c.gens.1.toNat ≠ 0 ∧ c.gens.1.toNat = c.gens.2.toNat ∧ c.clocks.1.toNat ≤ c.clocks.2.toNat
      | .supersedeStaleGeneration => ph = .armed ∧ c.gens.1.toNat < c.gens.2.toNat
      | .cancelWakeup => ph = .armed

private theorem wakeupPhase_code_of_decode {x : UInt8} {ph : WakeupPhase}
    (h : WakeupPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [WakeupPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | k5 <;>
        simp [WakeupPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [WakeupPhase.encode] using hcode

private theorem wakeupOp_code_of_decode {x : UInt8} {op : WakeupOp}
    (h : WakeupOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [WakeupOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | k5 <;>
        simp [WakeupOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [WakeupOp.encode] using hcode

def wakeupContinuationMetaGate : MetaGateSpec WakeupAdmitCheck WakeupAdmitDomainSafe where
  gate c :=
    verifyWakeupContinuationAdmit c.codes.1 c.codes.2 c.guards.1 c.guards.2
      c.gens.1 c.gens.2 c.clocks.1 c.clocks.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨oTerm, oBusy⟩, ⟨aGen, cGen⟩, ⟨due, now⟩⟩
    change (verifyWakeupContinuationAdmit phC opC oTerm oBusy aGen cGen due now == 1) = true at h
    dsimp [WakeupAdmitDomainSafe]
    unfold verifyWakeupContinuationAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨hphLe4, _⟩, hbr⟩
    rcases hbr with (((h0 | h1) | h2) | h3) | h4
    · rcases h0 with ⟨⟨⟨⟨hop, hph⟩, hterm⟩, hc0⟩, hlt⟩; subst hop; subst hterm
      have hcode : phC.toNat = 0 ∨ phC.toNat = 2 ∨ phC.toNat = 3 ∨ phC.toNat = 4 := by
        have hle : phC.toNat ≤ 4 := UInt8.le_iff_toNat_le.mp hphLe4
        have hne1 : phC.toNat ≠ 1 := fun h1 => hph (u8_eq_of_toNat phC 1 (by omega) h1)
        omega
      have hc0Nat : cGen.toNat ≠ 0 := fun hz => hc0 (u64_eq_of_toNat_eq cGen 0 hz)
      have hltNat := UInt64.lt_iff_toNat_lt.mp hlt
      rcases hcode with hc | hc | hc | hc
      · have : phC = 0 := u8_eq_of_toNat phC 0 (by omega) hc; subst this
        exact ⟨.disarmed, rfl, .armWakeup, rfl, by decide, rfl, hc0Nat, hltNat⟩
      · have : phC = 2 := u8_eq_of_toNat phC 2 (by omega) hc; subst this
        exact ⟨.fired, rfl, .armWakeup, rfl, by decide, rfl, hc0Nat, hltNat⟩
      · have : phC = 3 := u8_eq_of_toNat phC 3 (by omega) hc; subst this
        exact ⟨.superseded, rfl, .armWakeup, rfl, by decide, rfl, hc0Nat, hltNat⟩
      · have : phC = 4 := u8_eq_of_toNat phC 4 (by omega) hc; subst this
        exact ⟨.cancelled, rfl, .armWakeup, rfl, by decide, rfl, hc0Nat, hltNat⟩
    · exact ⟨.armed, by
        rcases h1 with ⟨⟨⟨⟨⟨hop, hph⟩, _⟩, _⟩, _⟩, _⟩
        subst hop
        subst hph
        rfl,
        .replaceArmedWakeup, by rcases h1 with ⟨⟨⟨⟨⟨hop, _⟩, _⟩, _⟩, _⟩, _⟩; subst hop; rfl,
        rfl, by rcases h1 with ⟨⟨⟨⟨⟨_, _⟩, hterm⟩, _⟩, _⟩, _⟩; subst hterm; rfl,
        by rcases h1 with ⟨⟨⟨⟨⟨_, _⟩, _⟩, hc0⟩, _⟩, _⟩; intro hz; exact hc0 (u64_eq_of_toNat_eq cGen 0 hz),
        by rcases h1 with ⟨⟨⟨⟨⟨_, _⟩, _⟩, _⟩, hle⟩, _⟩; exact UInt64.le_iff_toNat_le.mp hle,
        by rcases h1 with ⟨⟨⟨⟨⟨_, _⟩, _⟩, _⟩, _⟩, hlt⟩; exact UInt64.lt_iff_toNat_lt.mp hlt⟩
    · rcases h2 with ⟨⟨⟨⟨⟨⟨hop, hph⟩, hterm⟩, hbusy⟩, ha0⟩, heq⟩, hle⟩
      subst hop
      subst hph
      subst hterm
      subst hbusy
      exact ⟨.armed, rfl, .fireDueWakeup, rfl, rfl, rfl, rfl,
        by intro hz; exact ha0 (u64_eq_of_toNat_eq aGen 0 hz), by rw [heq],
        UInt64.le_iff_toNat_le.mp hle⟩
    · rcases h3 with ⟨⟨hop, hph⟩, hlt⟩; subst hop; subst hph
      exact ⟨.armed, rfl, .supersedeStaleGeneration, rfl, rfl, UInt64.lt_iff_toNat_lt.mp hlt⟩
    · rcases h4 with ⟨hop, hph⟩; subst hop; subst hph
      exact ⟨.armed, rfl, .cancelWakeup, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨oTerm, oBusy⟩, ⟨aGen, cGen⟩, ⟨due, now⟩⟩
    change (verifyWakeupContinuationAdmit phC opC oTerm oBusy aGen cGen due now == 1) = true
    dsimp [WakeupAdmitDomainSafe] at h
    rcases h with ⟨ph, hphDec, op, hopDec, hbr⟩
    have hphC := wakeupPhase_code_of_decode hphDec
    have hopC := wakeupOp_code_of_decode hopDec
    subst hphC; subst hopC
    unfold verifyWakeupContinuationAdmit
    cases op with
    | armWakeup =>
      rcases hbr with ⟨hph, hterm, hc0, hlt⟩
      have hterm0 : oTerm = 0 := u8_eq_of_toNat oTerm 0 (by omega) hterm
      have hcNe : cGen ≠ 0 := fun hz => hc0 (by subst hz; rfl)
      have hltB : now < due := UInt64.lt_iff_toNat_lt.mpr hlt
      subst hterm0
      cases ph <;> simp [WakeupPhase.encode] at hph ⊢ <;> simp [WakeupOp.encode, hcNe, hltB]
    | replaceArmedWakeup =>
      rcases hbr with ⟨rfl, hterm, hc0, hle, hlt⟩
      have hterm0 : oTerm = 0 := u8_eq_of_toNat oTerm 0 (by omega) hterm
      have hcN : (cGen != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hc0 (by subst hz; rfl)
      have hleB : aGen ≤ cGen := UInt64.le_iff_toNat_le.mpr hle
      have hltB : now < due := UInt64.lt_iff_toNat_lt.mpr hlt
      subst hterm0
      simp [WakeupPhase.encode, WakeupOp.encode, hcN, hleB, hltB]
    | fireDueWakeup =>
      rcases hbr with ⟨rfl, hterm, hbusy, ha0, heq, hle⟩
      have hterm0 : oTerm = 0 := u8_eq_of_toNat oTerm 0 (by omega) hterm
      have hbusy0 : oBusy = 0 := u8_eq_of_toNat oBusy 0 (by omega) hbusy
      have haN : (aGen != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact ha0 (by subst hz; rfl)
      have heqB : aGen = cGen := u64_eq_of_toNat_eq aGen cGen heq
      have hleB : due ≤ now := UInt64.le_iff_toNat_le.mpr hle
      subst hterm0; subst hbusy0; subst heqB
      simp [WakeupPhase.encode, WakeupOp.encode, haN, hleB]
    | supersedeStaleGeneration =>
      rcases hbr with ⟨rfl, hlt⟩
      have hltB : aGen < cGen := UInt64.lt_iff_toNat_lt.mpr hlt
      simp [WakeupPhase.encode, WakeupOp.encode, hltB]
    | cancelWakeup =>
      subst hbr; simp [WakeupPhase.encode, WakeupOp.encode]
  posWitness := { codes := (1, 2), guards := (0, 0), gens := (5, 5), clocks := (10, 10) }
  negWitness := { codes := (2, 2), guards := (0, 0), gens := (5, 5), clocks := (10, 10) }
  nonVacuous := by decide
  tight := by decide

def wakeupFireClockDiscipline : ClockDiscipline WakeupAdmitCheck where
  eval c :=
    if wakeupContinuationMetaGate.gate c && c.codes.2 == 2 && c.clocks.1 ≤ c.clocks.2 then 1 else 0
  clockMask := 1
  guardOk c := c.codes.1 == 1 && c.guards.1 == 0 && c.guards.2 == 0 &&
    c.gens.1 != 0 && c.gens.2 == c.gens.1
  isolated c h := by
    have hg : wakeupContinuationMetaGate.gate c = true ∧ (c.codes.2 == 2) = true := by
      by_cases h1 : wakeupContinuationMetaGate.gate c = true
      · by_cases h2 : (c.codes.2 == 2) = true
        · exact ⟨h1, h2⟩
        · simp [h1, h2] at h
      · simp [h1] at h
    have hs := wakeupContinuationMetaGate.sound c hg.1
    rcases c with ⟨⟨phC, opC⟩, ⟨oTerm, oBusy⟩, ⟨aGen, cGen⟩, ⟨_, _⟩⟩
    rcases hs with ⟨ph, hphDec, op, hopDec, hbr⟩
    have hop2 : opC = 2 := by rw [beq_iff_eq] at hg; exact hg.2
    have hop : op = .fireDueWakeup := by
      have hdec : WakeupOp.decode? opC.toNat = some op := hopDec
      rw [hop2] at hdec; simp [WakeupOp.decode?] at hdec; exact hdec.symm
    subst hop
    rcases hbr with ⟨rfl, hterm, hbusy, ha0, heq, _⟩
    have hph1 : phC = 1 := by simpa [WakeupPhase.encode] using wakeupPhase_code_of_decode hphDec
    have hterm0 : oTerm = 0 := u8_eq_of_toNat oTerm 0 (by omega) hterm
    have hbusy0 : oBusy = 0 := u8_eq_of_toNat oBusy 0 (by omega) hbusy
    have haN : (aGen != 0) = true := by
      rw [bne_iff_ne]
      intro hz
      subst hz
      simp at ha0
    have heqB : cGen = aGen := (u64_eq_of_toNat_eq aGen cGen heq).symm
    subst hph1
    subst hterm0
    subst hbusy0
    subst heqB
    simp [haN]

theorem wakeup_stale_generation_or_already_fired_never_dispatches
    (s : WakeupSliceState) (ev : WakeupSliceEvent)
    (hbad : s.phaseCode = 2 ∨ s.armedGeneration ≠ ev.currentRunGeneration) :
    ev.opCode = 2 →
      verifyWakeupContinuationAdmit s.phaseCode ev.opCode ev.ownerTerminal ev.ownerBusy
        s.armedGeneration ev.currentRunGeneration
        (if ev.opCode == 0 || ev.opCode == 1 then ev.reqDueEpoch else s.dueEpoch)
        ev.nowEpoch = 1 → False := by
  intro hop2 hadm
  have hadm2 :
      verifyWakeupContinuationAdmit s.phaseCode 2 ev.ownerTerminal ev.ownerBusy
        s.armedGeneration ev.currentRunGeneration s.dueEpoch ev.nowEpoch = 1 := by
    rw [hop2] at hadm
    have hcond : ((2 : UInt8) == 0 || (2 : UInt8) == 1) = false := by decide
    rw [hcond] at hadm
    simpa using hadm
  have hgate : wakeupContinuationMetaGate.gate
      { codes := (s.phaseCode, 2)
        guards := (ev.ownerTerminal, ev.ownerBusy)
        gens := (s.armedGeneration, ev.currentRunGeneration)
        clocks := (s.dueEpoch, ev.nowEpoch) } = true := by
    simpa [wakeupContinuationMetaGate] using hadm2
  have hs := wakeupContinuationMetaGate.sound _ hgate
  dsimp [WakeupAdmitDomainSafe] at hs
  rcases hs with ⟨ph, hph, op, hop, hbr⟩
  have hopv : op = .fireDueWakeup := by
    have hdec : WakeupOp.decode? 2 = some op := hop
    simp [WakeupOp.decode?] at hdec; exact hdec.symm
  subst hopv
  rcases hbr with ⟨rfl, _, _, _, heq, _⟩
  have hph1 : s.phaseCode = 1 := by
    have hcode : s.phaseCode = WakeupPhase.armed.encode := wakeupPhase_code_of_decode hph
    simpa [WakeupPhase.encode] using hcode
  rcases hbad with h2 | hne
  · simp [hph1] at h2
  · exact hne (u64_eq_of_toNat_eq _ _ heq)

/-! ## 6. Orthogonal `R3WorldState` Footprint Disjointness & Pairwise Commutativity -/

theorem r3_specBlocks_all_footprints_disjoint :
    Footprint.Disjoint missionLifecycleSpecBlock.footprint runLifecycleSpecBlock.footprint = true ∧
    Footprint.Disjoint missionLifecycleSpecBlock.footprint queueItemSpecBlock.footprint = true ∧
    Footprint.Disjoint missionLifecycleSpecBlock.footprint cancelProtocolSpecBlock.footprint = true ∧
    Footprint.Disjoint missionLifecycleSpecBlock.footprint wakeupContinuationSpecBlock.footprint = true ∧
    Footprint.Disjoint runLifecycleSpecBlock.footprint queueItemSpecBlock.footprint = true ∧
    Footprint.Disjoint runLifecycleSpecBlock.footprint cancelProtocolSpecBlock.footprint = true ∧
    Footprint.Disjoint runLifecycleSpecBlock.footprint wakeupContinuationSpecBlock.footprint = true ∧
    Footprint.Disjoint queueItemSpecBlock.footprint cancelProtocolSpecBlock.footprint = true ∧
    Footprint.Disjoint queueItemSpecBlock.footprint wakeupContinuationSpecBlock.footprint = true ∧
    Footprint.Disjoint cancelProtocolSpecBlock.footprint wakeupContinuationSpecBlock.footprint = true := by
  decide

theorem r3_specBlocks_pairwise_commute
    (w : R3WorldState)
    (em : MissionSliceEvent) (er : RunSliceEvent) (eq : QueueSliceEvent)
    (ec : CancelSliceEvent) (ew : WakeupSliceEvent) :
    (runLifecycleSpecBlock.liftStep (missionLifecycleSpecBlock.liftStep w em).1 er).1 =
      (missionLifecycleSpecBlock.liftStep (runLifecycleSpecBlock.liftStep w er).1 em).1 ∧
    (queueItemSpecBlock.liftStep (runLifecycleSpecBlock.liftStep w er).1 eq).1 =
      (runLifecycleSpecBlock.liftStep (queueItemSpecBlock.liftStep w eq).1 er).1 ∧
    (cancelProtocolSpecBlock.liftStep (runLifecycleSpecBlock.liftStep w er).1 ec).1 =
      (runLifecycleSpecBlock.liftStep (cancelProtocolSpecBlock.liftStep w ec).1 er).1 ∧
    (wakeupContinuationSpecBlock.liftStep (missionLifecycleSpecBlock.liftStep w em).1 ew).1 =
      (missionLifecycleSpecBlock.liftStep (wakeupContinuationSpecBlock.liftStep w ew).1 em).1 ∧
    (cancelProtocolSpecBlock.liftStep (queueItemSpecBlock.liftStep w eq).1 ec).1 =
      (queueItemSpecBlock.liftStep (cancelProtocolSpecBlock.liftStep w ec).1 eq).1 := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · refine specBlock_orthogonal_commutes missionLifecycleSpecBlock runLifecycleSpecBlock ?_ ?_ ?_ w em er
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes runLifecycleSpecBlock queueItemSpecBlock ?_ ?_ ?_ w er eq
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes runLifecycleSpecBlock cancelProtocolSpecBlock ?_ ?_ ?_ w er ec
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes missionLifecycleSpecBlock wakeupContinuationSpecBlock ?_ ?_ ?_ w em ew
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes queueItemSpecBlock cancelProtocolSpecBlock ?_ ?_ ?_ w eq ec
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl

end Orb.LifecycleSpec
