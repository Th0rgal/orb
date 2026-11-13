/-
  Orb.ManagedNodeSpec: Phase R5-A Non-Tautological Specifications & Composition Proofs
  (`0 import Lean`, `0 sorryAx`).

  Proves for the five R5-A coordinated slices (`VmLifecycle`, `VmClaim`, `RemoteJobLedger`,
  `ProcessLiveness`, `RelayCommand`):
    1. Two-layer `MetaGateSpec` equivalence (`sound`, `complete`, `posWitness`, `negWitness`,
       `nonVacuous`, `tight`) over decoded protocol ADTs and natural-number invariants.
    2. Layer-I meta-specifications (`StickyFence`, `ClockDiscipline`, `ScopedAuthority`,
       `ReplayIdempotence`).
    3. All `plan.md` §Phase R5-A (`SM-19` / `SM-20`) obligations:
       - `node_boot_epoch` increments on `stop -> resume` and `replace` (from `running` or
         `stopped`), and is monotone across all steps and traces; stale boot epochs never mutate.
       - `deletable_at` retention vs. `activeComputeEligible`: a VM inside its minimum lease or
         with a live owner cannot be destroyed, a `stopped` VM retained under `deletable_at` is
         not `activeComputeEligible`, and an idle-expired VM past `deletable_at` is admitted.
       - Reservation uniqueness, lineage, compute eligibility, and boot fencing: duplicate claims
         of the same `reservation_id`, superseded/orphaned owners, stale boot epochs, and claims
         against non-eligible (`stopped`) VMs are rejected, while `release` on a `stopped` VM with
         matching `node_boot_epoch` succeeds.
       - Remote job ledger: `operation_id` is fenced by `node_boot_epoch`, ambiguous delivery
         stays `Uncertain` with no fresh retry, and the first terminal transition wins.
       - Process liveness: `(pid, start_ticks)` mismatch, missing `/proc`, or zombie state never
         counts as the same alive leader, and `SIGTERM` / `SIGKILL` require matching ticks.
       - Relay command (`SM-19`): leased delivery never pops before explicit guest ack (`retired = 0`
         while `Leased` or `Uncertain`), `Uncertain` forbids fresh replay/retry and reconciles
         exclusively to `Accepted` (`retired = 1`), and stale-boot operations are rejected.
       - Kernel C-ABI refinement bridges linking `Orb.ManagedNode` to `Orb.Kernel.vmLifecycleStep`,
         `Orb.Kernel.vmClaimStep`, `Orb.Kernel.verifyRemoteOutbox`, `Orb.Kernel.jobLedgerStep`, and
         `Orb.Kernel.procLivenessStep`.
    4. Pairwise footprint disjointness and orthogonal `SpecBlock.liftStep` commutativity across
       all five slices (10 pairs) over `R5WorldState`.
-/
import Orb.ManagedNode

namespace Orb.ManagedNodeSpec

open Orb.Kernel
open Orb.Spec
open Orb.ManagedNode

theorem retainedArchive_unobserved (s : VmSliceState) (boot : UInt64) :
    observeVmRetainedArchive s false boot = s := by
  simp [observeVmRetainedArchive]

theorem retainedArchive_preservesBoot (s : VmSliceState) (confirmed : Bool) (boot : UInt64) :
    (observeVmRetainedArchive s confirmed boot).nodeBootEpoch = s.nodeBootEpoch := by
  simp only [observeVmRetainedArchive]
  split <;> rfl

theorem retainedArchive_neverEnablesCompute (s : VmSliceState) (confirmed : Bool) (boot : UInt64)
    (h : s.activeComputeEligible = 0) :
    (observeVmRetainedArchive s confirmed boot).activeComputeEligible = 0 := by
  simp only [observeVmRetainedArchive]
  split
  · rfl
  · exact h

private theorem u8_eq_of_toNat (a : UInt8) (n : Nat) (hn : n < 256) (h : a.toNat = n) :
    a = UInt8.ofNat n := by
  apply UInt8.eq_of_toBitVec_eq
  apply BitVec.eq_of_toNat_eq
  have hm : (UInt8.ofNat n).toBitVec.toNat = n := by
    change n % 256 = n
    omega
  change a.toNat = _
  omega

private theorem u32_eq_of_toNat_eq (a b : UInt32) (h : a.toNat = b.toNat) : a = b :=
  UInt32.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)

private theorem u64_eq_of_toNat_eq (a b : UInt64) (h : a.toNat = b.toNat) : a = b :=
  UInt64.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)

private theorem bit_cond_true {b : Bool} (h : ((if b then (1 : UInt8) else 0) == 1) = true) : b = true := by
  cases b
  · contradiction
  · rfl

private theorem u64_succ_of_lt_eq (a b : UInt64)
    (h : a < b ∧ b = a + 1) : b.toNat = a.toNat + 1 := by
  have hltN : a.toNat < b.toNat := UInt64.lt_iff_toNat_lt.mp h.1
  have hmod : b.toNat = (a.toNat + 1) % UInt64.size := by
    rw [h.2]
    exact UInt64.toNat_add a 1
  have hltSz : a.toNat + 1 < UInt64.size := by
    have hbSz : b.toNat < UInt64.size := b.toBitVec.isLt
    by_cases hwrap : a.toNat + 1 < UInt64.size
    · exact hwrap
    · have haSz : a.toNat < UInt64.size := a.toBitVec.isLt
      have heqSz : a.toNat + 1 = UInt64.size := by omega
      rw [heqSz, Nat.mod_self] at hmod
      omega
  rw [Nat.mod_eq_of_lt hltSz] at hmod
  exact hmod

private theorem u64_lt_and_eq_of_succ (a b : UInt64)
    (h : b.toNat = a.toNat + 1) : a < b ∧ b = a + 1 := by
  have hlt : a < b := UInt64.lt_iff_toNat_lt.mpr (by omega)
  have hbSz : b.toNat < UInt64.size := b.toBitVec.isLt
  have hadd : (a + 1).toNat = a.toNat + 1 := by
    rw [UInt64.toNat_add]
    change (a.toNat + 1) % UInt64.size = a.toNat + 1
    exact Nat.mod_eq_of_lt (by omega)
  exact ⟨hlt, u64_eq_of_toNat_eq b (a + 1) (by omega)⟩

/-! ## 1. `VmLifecycle` (`SM-19`) -/

structure VmAdmitCheck where
  codes  : UInt8 × UInt8
  guards : UInt8 × UInt8
  boots  : UInt64 × UInt64
  clocks : UInt64 × UInt64
  deriving Repr, DecidableEq

def VmAdmitDomainSafe (c : VmAdmitCheck) : Prop :=
  0 < c.boots.1.toNat ∧
  ∃ ph, VmPhase.decode? c.codes.1.toNat = some ph ∧ ph ≠ .destroyed ∧
    ∃ op, VmOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .provision => ph = .absent ∧ c.boots.2.toNat = c.boots.1.toNat
      | .stop => ph = .running ∧ c.boots.2.toNat = c.boots.1.toNat
      | .resume => ph = .stopped ∧ c.boots.2.toNat = c.boots.1.toNat + 1
      | .replace => (ph = .running ∨ ph = .stopped) ∧ c.boots.2.toNat = c.boots.1.toNat + 1
      | .destroy =>
          (ph = .absent ∨ ph = .running ∨ ph = .stopped) ∧
          c.boots.2.toNat = c.boots.1.toNat ∧
          c.guards.1.toNat = 0 ∧ c.guards.2.toNat = 1 ∧
          c.clocks.2.toNat ≤ c.clocks.1.toNat

private theorem vmPhase_code_of_decode {x : UInt8} {ph : VmPhase}
    (h : VmPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [VmPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | k4 <;>
        simp [VmPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [VmPhase.encode] using hcode

private theorem vmOp_code_of_decode {x : UInt8} {op : VmOp}
    (h : VmOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [VmOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | k5 <;>
        simp [VmOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [VmOp.encode] using hcode

def vmLifecycleMetaGate : MetaGateSpec VmAdmitCheck VmAdmitDomainSafe where
  gate c :=
    verifyVmLifecycleAdmit
      c.codes.1 c.codes.2 c.guards.1 c.guards.2
      c.boots.1 c.boots.2 c.clocks.1 c.clocks.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨ownL, idleE⟩, ⟨lBoot, pBoot⟩, ⟨nowEp, delAt⟩⟩
    change (verifyVmLifecycleAdmit phC opC ownL idleE lBoot pBoot nowEp delAt == 1) = true at h
    dsimp [VmAdmitDomainSafe]
    unfold verifyVmLifecycleAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨_, _⟩, hb0⟩, hbr⟩
    have hbPos : 0 < lBoot.toNat := by
      have hne : lBoot.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq lBoot 0 hz)
      omega
    refine ⟨hbPos, ?_⟩
    rcases hbr with (((h0 | h1) | h2) | h3) | h4
    · rcases h0 with ⟨⟨hop, hph⟩, hbeq⟩
      subst hop; subst hph; subst hbeq
      exact ⟨.absent, rfl, by decide, .provision, rfl, rfl, rfl⟩
    · rcases h1 with ⟨⟨hop, hph⟩, hbeq⟩
      subst hop; subst hph; subst hbeq
      exact ⟨.running, rfl, by decide, .stop, rfl, rfl, rfl⟩
    · rcases h2 with ⟨⟨⟨hop, hph⟩, hlt⟩, hsucc⟩
      subst hop; subst hph
      have hn := u64_succ_of_lt_eq lBoot pBoot ⟨hlt, hsucc⟩
      exact ⟨.stopped, rfl, by decide, .resume, rfl, rfl, hn⟩
    · rcases h3 with ⟨⟨⟨hop, hph⟩, hlt⟩, hsucc⟩
      subst hop
      have hn := u64_succ_of_lt_eq lBoot pBoot ⟨hlt, hsucc⟩
      rcases hph with hph | hph <;> subst hph
      · exact ⟨.running, rfl, by decide, .replace, rfl, Or.inl rfl, hn⟩
      · exact ⟨.stopped, rfl, by decide, .replace, rfl, Or.inr rfl, hn⟩
    · rcases h4 with ⟨⟨⟨⟨⟨hop, hph⟩, hbeq⟩, hown⟩, hidle⟩, hdel⟩
      subst hop hbeq hown hidle
      have hle := UInt64.le_iff_toNat_le.mp hdel
      rcases hph with (hph | hph) | hph <;> subst hph
      · exact ⟨.absent, rfl, by decide, .destroy, rfl, Or.inl rfl, rfl, rfl, rfl, hle⟩
      · exact ⟨.running, rfl, by decide, .destroy, rfl, Or.inr (Or.inl rfl), rfl, rfl, rfl, hle⟩
      · exact ⟨.stopped, rfl, by decide, .destroy, rfl, Or.inr (Or.inr rfl), rfl, rfl, rfl, hle⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨ownL, idleE⟩, ⟨lBoot, pBoot⟩, ⟨nowEp, delAt⟩⟩
    change (verifyVmLifecycleAdmit phC opC ownL idleE lBoot pBoot nowEp delAt == 1) = true
    dsimp [VmAdmitDomainSafe] at h
    rcases h with ⟨hbPos, ph, hphDec, _, op, hopDec, hbr⟩
    have hbNe : (lBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hbPos
    have hphC := vmPhase_code_of_decode hphDec
    have hopC := vmOp_code_of_decode hopDec
    subst hphC; subst hopC
    unfold verifyVmLifecycleAdmit
    cases op with
    | provision =>
      rcases hbr with ⟨rfl, hbeq⟩
      have heq := u64_eq_of_toNat_eq pBoot lBoot hbeq
      subst heq; simp [VmPhase.encode, VmOp.encode, hbNe]
    | stop =>
      rcases hbr with ⟨rfl, hbeq⟩
      have heq := u64_eq_of_toNat_eq pBoot lBoot hbeq
      subst heq; simp [VmPhase.encode, VmOp.encode, hbNe]
    | resume =>
      rcases hbr with ⟨rfl, hsucc⟩
      rcases u64_lt_and_eq_of_succ lBoot pBoot hsucc with ⟨hlt, heq⟩
      have hlt1 : lBoot < lBoot + 1 := by rwa [heq] at hlt
      subst heq; simp [VmPhase.encode, VmOp.encode, hbNe, hlt1]
    | replace =>
      rcases hbr with ⟨hph, hsucc⟩
      rcases u64_lt_and_eq_of_succ lBoot pBoot hsucc with ⟨hlt, heq⟩
      have hlt1 : lBoot < lBoot + 1 := by rwa [heq] at hlt
      subst heq
      rcases hph with rfl | rfl <;> simp [VmPhase.encode, VmOp.encode, hbNe, hlt1]
    | destroy =>
      rcases hbr with ⟨hph, hbeq, hown, hidle, hle⟩
      have heq := u64_eq_of_toNat_eq pBoot lBoot hbeq
      have hown0 := u8_eq_of_toNat ownL 0 (by omega) hown
      have hidle1 := u8_eq_of_toNat idleE 1 (by omega) hidle
      have hleB : delAt ≤ nowEp := UInt64.le_iff_toNat_le.mpr hle
      subst heq; subst hown0; subst hidle1
      rcases hph with rfl | rfl | rfl <;> simp [VmPhase.encode, VmOp.encode, hbNe, hleB]
  posWitness := { codes := (1, 3), guards := (0, 0), boots := (4, 5), clocks := (10, 10) }
  negWitness := { codes := (1, 4), guards := (1, 1), boots := (4, 4), clocks := (5, 10) }
  nonVacuous := by decide
  tight := by decide

private theorem vm_destroyed_step_id (s : VmSliceState) (ev : VmSliceEvent)
    (hd : (s.phaseCode == 3) = true) :
    stepVmSlice s ev = (s, []) := by
  unfold stepVmSlice
  have hadmFalse :
      ¬ (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
           s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true := by
    intro hc
    have hs := vmLifecycleMetaGate.sound
      { codes := (s.phaseCode, ev.opCode)
        guards := (ev.ownerLive, ev.idleElapsed)
        boots := (s.nodeBootEpoch, ev.presentedBootEpoch)
        clocks := (ev.nowEpoch, s.deletableAt) } hc
    dsimp [VmAdmitDomainSafe] at hs
    rcases hs with ⟨_, ph, hphDec, hnd, _⟩
    have hpc := vmPhase_code_of_decode hphDec
    have hs3 : s.phaseCode = 3 := by rwa [beq_iff_eq] at hd
    rw [hs3] at hpc
    cases ph <;> simp [VmPhase.encode] at hpc <;> exact hnd rfl
  by_cases h1 : (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
       s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true
  · exact absurd h1 hadmFalse
  · simp [h1]

def vmDestroyedStickyFence : StickyFence VmSliceState VmSliceEvent where
  fenced s := s.phaseCode == 3
  preFenceAct s := s.phaseCode == 1 || s.phaseCode == 2
  step s ev := (stepVmSlice s ev).1
  sticky s ev hf := by rw [vm_destroyed_step_id s ev hf]; exact hf
  forbids_post s ev hf := by
    rw [vm_destroyed_step_id s ev hf]
    have hs3 : s.phaseCode = 3 := by rwa [beq_iff_eq] at hf
    rw [hs3]; decide

def vmDestroyClockDiscipline : ClockDiscipline VmAdmitCheck where
  eval c :=
    if vmLifecycleMetaGate.gate c && c.codes.2 == 4 && c.clocks.2 ≤ c.clocks.1 then 1 else 0
  clockMask := 1
  guardOk c := c.guards.1 == 0 && c.guards.2 == 1 && c.boots.2 == c.boots.1 && c.boots.1 != 0
  isolated c h := by
    have hg : vmLifecycleMetaGate.gate c = true ∧ (c.codes.2 == 4) = true := by
      by_cases h1 : vmLifecycleMetaGate.gate c = true
      · by_cases h2 : (c.codes.2 == 4) = true
        · exact ⟨h1, h2⟩
        · simp [h1, h2] at h
      · simp [h1] at h
    have hs := vmLifecycleMetaGate.sound c hg.1
    rcases c with ⟨⟨phC, opC⟩, ⟨ownL, idleE⟩, ⟨lBoot, pBoot⟩, ⟨_, _⟩⟩
    rcases hs with ⟨hbPos, _, _, _, op, hopDec, hbr⟩
    have hop4 : opC = 4 := by rw [beq_iff_eq] at hg; exact hg.2
    have hop : op = .destroy := by
      have hdec : VmOp.decode? opC.toNat = some op := hopDec
      rw [hop4] at hdec; simp [VmOp.decode?] at hdec; exact hdec.symm
    subst hop
    rcases hbr with ⟨_, hbeq, hown, hidle, _⟩
    have hbNe : (lBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hbPos
    have heq : pBoot = lBoot := u64_eq_of_toNat_eq pBoot lBoot hbeq
    have hown0 := u8_eq_of_toNat ownL 0 (by omega) hown
    have hidle1 := u8_eq_of_toNat idleE 1 (by omega) hidle
    subst heq; subst hown0; subst hidle1
    simp [hbNe]

def vmBootEpochScopedAuthority : ScopedAuthority VmAdmitCheck where
  admit := vmLifecycleMetaGate.gate
  scopeValid c :=
    c.boots.1 != 0 &&
    (c.boots.2 == c.boots.1 ||
     ((c.codes.2 == 2 || c.codes.2 == 3) && c.boots.1 < c.boots.2 && c.boots.2 == c.boots.1 + 1))
  sound c h := by
    have hs := vmLifecycleMetaGate.sound c h
    rcases c with ⟨⟨phC, opC⟩, ⟨_, _⟩, ⟨lBoot, pBoot⟩, ⟨_, _⟩⟩
    rcases hs with ⟨hbPos, _, _, _, op, hopDec, hbr⟩
    have hbNe : (lBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hbPos
    have hopC := vmOp_code_of_decode hopDec
    subst hopC
    cases op with
    | provision =>
      have heq := u64_eq_of_toNat_eq pBoot lBoot hbr.2
      subst heq; simp [hbNe]
    | stop =>
      have heq := u64_eq_of_toNat_eq pBoot lBoot hbr.2
      subst heq; simp [hbNe]
    | resume =>
      rcases u64_lt_and_eq_of_succ lBoot pBoot hbr.2 with ⟨hlt, heq⟩
      have hlt1 : lBoot < lBoot + 1 := by rwa [heq] at hlt
      subst heq; simp [VmOp.encode, hbNe, hlt1]
    | replace =>
      rcases u64_lt_and_eq_of_succ lBoot pBoot hbr.2 with ⟨hlt, heq⟩
      have hlt1 : lBoot < lBoot + 1 := by rwa [heq] at hlt
      subst heq; simp [VmOp.encode, hbNe, hlt1]
    | destroy =>
      have heq := u64_eq_of_toNat_eq pBoot lBoot hbr.2.1
      subst heq; simp [hbNe]

/-- `node_boot_epoch` increments on every admitted `resume` or `replace`, and stays equal on all
    other steps. -/
theorem vm_step_boot_epoch_discipline (s : VmSliceState) (ev : VmSliceEvent) :
    (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
       s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt = 1 ∧
     (ev.opCode = 2 ∨ ev.opCode = 3) →
       (stepVmSlice s ev).1.nodeBootEpoch.toNat = s.nodeBootEpoch.toNat + 1) ∧
    (¬ (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
          s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt = 1 ∧
        (ev.opCode = 2 ∨ ev.opCode = 3)) →
       (stepVmSlice s ev).1.nodeBootEpoch = s.nodeBootEpoch) := by
  constructor
  · rintro ⟨hadm, hop⟩
    have hadmB : (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
        s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true := by
      simpa using hadm
    have hs := vmLifecycleMetaGate.sound
      { codes := (s.phaseCode, ev.opCode)
        guards := (ev.ownerLive, ev.idleElapsed)
        boots := (s.nodeBootEpoch, ev.presentedBootEpoch)
        clocks := (ev.nowEpoch, s.deletableAt) } hadmB
    dsimp [VmAdmitDomainSafe] at hs
    rcases hs with ⟨_, _, _, _, op, hopDec, hbr⟩
    unfold stepVmSlice vmLifecycleNextBoot
    rw [ite_eq_left_iff.mpr (fun h => absurd hadmB h)]
    rcases hop with h2 | h3
    · rw [h2] at hopDec ⊢
      simp [VmOp.decode?] at hopDec
      subst hopDec
      simpa using hbr.2
    · rw [h3] at hopDec ⊢
      simp [VmOp.decode?] at hopDec
      subst hopDec
      simpa using hbr.2
  · intro hnot
    unfold stepVmSlice vmLifecycleNextBoot
    by_cases hadm : (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
        s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true
    · rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
      have hadm1 : verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
          s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt = 1 := by
        rwa [beq_iff_eq] at hadm
      have hno23 : (ev.opCode == 2 || ev.opCode == 3) = false := by
        apply Bool.eq_false_iff.mpr
        intro h23
        simp only [Bool.or_eq_true, beq_iff_eq] at h23
        exact hnot ⟨hadm1, h23⟩
      simp [hno23]
    · rw [ite_eq_right_iff.mpr (fun h => absurd h hadm)]

theorem vm_step_boot_epoch_monotone (s : VmSliceState) (ev : VmSliceEvent) :
    s.nodeBootEpoch.toNat ≤ (stepVmSlice s ev).1.nodeBootEpoch.toNat := by
  by_cases hc : verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
      s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt = 1 ∧
      (ev.opCode = 2 ∨ ev.opCode = 3)
  · have h := (vm_step_boot_epoch_discipline s ev).1 hc
    omega
  · have h := (vm_step_boot_epoch_discipline s ev).2 hc
    rw [h]
    exact Nat.le_refl _

theorem vm_fold_boot_epoch_monotone (s : VmSliceState) (evs : List VmSliceEvent) :
    s.nodeBootEpoch.toNat ≤ (foldVmSlice s evs).nodeBootEpoch.toNat := by
  induction evs generalizing s with
  | nil => exact Nat.le_refl _
  | cons ev rest ih =>
    have h1 := vm_step_boot_epoch_monotone s ev
    have h2 := ih (stepVmSlice s ev).1
    change s.nodeBootEpoch.toNat ≤ (foldVmSlice (stepVmSlice s ev).1 rest).nodeBootEpoch.toNat
    omega

/-- Any stale presented boot epoch (`presentedBootEpoch < nodeBootEpoch`) is rejected and leaves
    the VM slice unchanged. -/
theorem vm_stale_boot_epoch_rejected (s : VmSliceState) (ev : VmSliceEvent)
    (hstale : ev.presentedBootEpoch.toNat < s.nodeBootEpoch.toNat) :
    stepVmSlice s ev = (s, []) := by
  unfold stepVmSlice
  have hfalse : ¬ (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
      s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true := by
    intro hadm
    have hsc := vmBootEpochScopedAuthority.sound
      { codes := (s.phaseCode, ev.opCode)
        guards := (ev.ownerLive, ev.idleElapsed)
        boots := (s.nodeBootEpoch, ev.presentedBootEpoch)
        clocks := (ev.nowEpoch, s.deletableAt) } hadm
    dsimp [vmBootEpochScopedAuthority] at hsc
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq] at hsc
    rcases hsc with ⟨_, heq | ⟨⟨_, hlt⟩, _⟩⟩
    · rw [heq] at hstale; omega
    · have hltN := UInt64.lt_iff_toNat_lt.mp hlt
      omega
  by_cases h1 : (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
      s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true
  · exact absurd h1 hfalse
  · simp [h1]

/-- `replace` (`opCode = 3`) is admitted from both `running (1)` and `stopped (2)` when
    `presentedBootEpoch = nodeBootEpoch + 1` without wrapping, advancing `nodeBootEpoch` and
    producing `running (1)` with `activeComputeEligible = 1`. Also, any `stop` transition produces
    `stopped (2)` with `activeComputeEligible = 0`, separating retention under `deletableAt` from
    active-compute eligibility. -/
theorem vm_replace_and_compute_eligibility_separation
    (s : VmSliceState) (ev : VmSliceEvent) :
    ((s.phaseCode = 1 ∨ s.phaseCode = 2) ∧ s.nodeBootEpoch ≠ 0 ∧
     ev.opCode = 3 ∧ s.nodeBootEpoch < ev.presentedBootEpoch ∧
     ev.presentedBootEpoch = s.nodeBootEpoch + 1 →
       (stepVmSlice s ev).1.phaseCode = 1 ∧
       (stepVmSlice s ev).1.activeComputeEligible = 1 ∧
       (stepVmSlice s ev).1.nodeBootEpoch = ev.presentedBootEpoch) ∧
    (s.phaseCode = 1 ∧ s.nodeBootEpoch ≠ 0 ∧
     ev.opCode = 1 ∧ ev.presentedBootEpoch = s.nodeBootEpoch →
       (stepVmSlice s ev).1.phaseCode = 2 ∧
       (stepVmSlice s ev).1.activeComputeEligible = 0) := by
  constructor
  · rintro ⟨hph, hb0, hop3, hlt, hsucc⟩
    have hbPos : 0 < s.nodeBootEpoch.toNat := by
      have hne : s.nodeBootEpoch.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hn := u64_succ_of_lt_eq s.nodeBootEpoch ev.presentedBootEpoch ⟨hlt, hsucc⟩
    have hadm : vmLifecycleMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          guards := (ev.ownerLive, ev.idleElapsed)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch)
          clocks := (ev.nowEpoch, s.deletableAt) } = true := by
      apply vmLifecycleMetaGate.complete
      refine ⟨hbPos, ?_⟩
      rcases hph with h1 | h2
      · exact ⟨.running, by rw [h1]; rfl, by decide, .replace, by rw [hop3]; rfl, Or.inl rfl, hn⟩
      · exact ⟨.stopped, by rw [h2]; rfl, by decide, .replace, by rw [hop3]; rfl, Or.inr rfl, hn⟩
    unfold stepVmSlice vmLifecycleTargetPhase vmLifecycleNextBoot vmPhaseComputeEligible
    dsimp [vmLifecycleMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop3]
  · rintro ⟨hph1, hb0, hop1, hboot⟩
    have hbPos : 0 < s.nodeBootEpoch.toNat := by
      have hne : s.nodeBootEpoch.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : vmLifecycleMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          guards := (ev.ownerLive, ev.idleElapsed)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch)
          clocks := (ev.nowEpoch, s.deletableAt) } = true := by
      apply vmLifecycleMetaGate.complete
      exact ⟨hbPos, .running, by rw [hph1]; rfl, by decide, .stop, by rw [hop1]; rfl, rfl, by rw [hboot]⟩
    unfold stepVmSlice vmLifecycleTargetPhase vmPhaseComputeEligible
    dsimp [vmLifecycleMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop1]

/-- `deletable_at` retention vs reap eligibility:
    1. A VM inside its minimum lease (`nowEpoch < deletableAt`) or with a live owner (`ownerLive = 1`)
       is never destroyed.
    2. A phase 0 provisioning reservation or running or stopped VM whose owner has ended
       (`ownerLive = 0`), whose idle timer has elapsed
       (`idleElapsed = 1`), and whose clock is past `deletableAt` is admitted for `destroy` (`phaseCode = 3`,
       `activeComputeEligible = 0`). -/
theorem vm_deletable_at_protects_min_lease_and_admits_expired_idle
    (s : VmSliceState) (ev : VmSliceEvent) :
    ((ev.nowEpoch < s.deletableAt ∨ ev.ownerLive = 1) ∧ ev.opCode = 4 →
      stepVmSlice s ev = (s, [])) ∧
    ((s.phaseCode = 0 ∨ s.phaseCode = 1 ∨ s.phaseCode = 2) ∧ s.nodeBootEpoch ≠ 0 ∧
     ev.opCode = 4 ∧ ev.presentedBootEpoch = s.nodeBootEpoch ∧
     ev.ownerLive = 0 ∧ ev.idleElapsed = 1 ∧ s.deletableAt ≤ ev.nowEpoch →
      (stepVmSlice s ev).1.phaseCode = 3 ∧
      (stepVmSlice s ev).1.activeComputeEligible = 0) := by
  constructor
  · rintro ⟨hguard, hop4⟩
    unfold stepVmSlice
    have hfalse : ¬ (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
        s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true := by
      intro hadm
      have hs := vmLifecycleMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          guards := (ev.ownerLive, ev.idleElapsed)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch)
          clocks := (ev.nowEpoch, s.deletableAt) } hadm
      dsimp [VmAdmitDomainSafe] at hs
      rcases hs with ⟨_, _, _, _, op, hopDec, hbr⟩
      rw [hop4] at hopDec
      simp [VmOp.decode?] at hopDec
      subst hopDec
      rcases hbr with ⟨_, _, hown0, _, hle⟩
      rcases hguard with hlt | hown1
      · have hltN := UInt64.lt_iff_toNat_lt.mp hlt
        omega
      · rw [hown1] at hown0; simp at hown0
    by_cases h1 : (verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
        s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1) = true
    · exact absurd h1 hfalse
    · simp [h1]
  · rintro ⟨hph, hb0, hop4, hboot, hown0, hidle1, hle⟩
    have hbPos : 0 < s.nodeBootEpoch.toNat := by
      have hne : s.nodeBootEpoch.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : vmLifecycleMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          guards := (ev.ownerLive, ev.idleElapsed)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch)
          clocks := (ev.nowEpoch, s.deletableAt) } = true := by
      apply vmLifecycleMetaGate.complete
      refine ⟨hbPos, ?_⟩
      rcases hph with h0 | h1 | h2
      · refine ⟨.absent, by rw [h0]; rfl, by decide, .destroy, by rw [hop4]; rfl,
          Or.inl rfl, by rw [hboot], by rw [hown0]; rfl, by rw [hidle1]; rfl,
          UInt64.le_iff_toNat_le.mp hle⟩
      · refine ⟨.running, by rw [h1]; rfl, by decide, .destroy, by rw [hop4]; rfl,
          Or.inr (Or.inl rfl), by rw [hboot], by rw [hown0]; rfl, by rw [hidle1]; rfl,
          UInt64.le_iff_toNat_le.mp hle⟩
      · refine ⟨.stopped, by rw [h2]; rfl, by decide, .destroy, by rw [hop4]; rfl,
          Or.inr (Or.inr rfl), by rw [hboot], by rw [hown0]; rfl, by rw [hidle1]; rfl,
          UInt64.le_iff_toNat_le.mp hle⟩
    unfold stepVmSlice vmLifecycleTargetPhase vmPhaseComputeEligible
    dsimp [vmLifecycleMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop4]

/-- A timed-out phase 0 provisioning reservation uses the ordinary destroy reducer: it keeps
    its boot and lease, disables compute, persists destruction, and closes the cost ledger. -/
theorem vm_phase0_bootstrap_timeout_destroy
    (s : VmSliceState) (ev : VmSliceEvent)
    (hph : s.phaseCode = 0) (hb0 : s.nodeBootEpoch ≠ 0)
    (hop : ev.opCode = 4) (hboot : ev.presentedBootEpoch = s.nodeBootEpoch)
    (howner : ev.ownerLive = 0) (hidle : ev.idleElapsed = 1)
    (hlease : s.deletableAt ≤ ev.nowEpoch) :
    stepVmSlice s ev =
      ({ s with phaseCode := 3, activeComputeEligible := 0 },
       [.persistVmPhase 3 0 s.nodeBootEpoch, .closeCostLedger s.nodeBootEpoch]) := by
  simp [stepVmSlice, verifyVmLifecycleAdmit, vmLifecycleTargetPhase,
    vmLifecycleNextBoot, vmPhaseComputeEligible, hph, hb0, hop, hboot, howner, hidle, hlease]

/-! ## 2. `VmClaim` (`SM-19`) -/

structure ClaimAdmitCheck where
  codes        : UInt8 × UInt8
  lineageFlags : UInt8 × UInt8
  vmFlags      : UInt8 × UInt8
  reservations : UInt64 × UInt64
  boots        : UInt64 × UInt64
  deriving Repr, DecidableEq

def ClaimAdmitDomainSafe (c : ClaimAdmitCheck) : Prop :=
  c.lineageFlags.1.toNat = 1 ∧
  c.lineageFlags.2.toNat = 0 ∧
  c.vmFlags.1.toNat ≤ 1 ∧
  c.vmFlags.2.toNat ≤ 1 ∧
  0 < c.boots.1.toNat ∧
  c.boots.2.toNat = c.boots.1.toNat ∧
  0 < c.reservations.2.toNat ∧
  ∃ ph, ClaimPhase.decode? c.codes.1.toNat = some ph ∧
    ∃ op, ClaimOp.decode? c.codes.2.toNat = some op ∧
       match op with
      | .claim =>
          ph = .unowned ∧ c.vmFlags.1.toNat = 1 ∧ c.vmFlags.2.toNat = 1 ∧
          c.reservations.1.toNat < c.reservations.2.toNat
      | .release =>
          ph = .claimed ∧ 0 < c.reservations.1.toNat ∧
          c.reservations.2.toNat = c.reservations.1.toNat ∧
          c.vmFlags.1.toNat = c.vmFlags.2.toNat
      | .reclaim =>
          ph = .released ∧ c.vmFlags.1.toNat = 1 ∧ c.vmFlags.2.toNat = 1 ∧
          c.reservations.1.toNat < c.reservations.2.toNat

private theorem claimPhase_code_of_decode {x : UInt8} {ph : ClaimPhase}
    (h : ClaimPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [ClaimPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | k3 <;>
        simp [ClaimPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [ClaimPhase.encode] using hcode

private theorem claimOp_code_of_decode {x : UInt8} {op : ClaimOp}
    (h : ClaimOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [ClaimOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | k3 <;>
        simp [ClaimOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [ClaimOp.encode] using hcode

def vmClaimMetaGate : MetaGateSpec ClaimAdmitCheck ClaimAdmitDomainSafe where
  gate c :=
    verifyVmClaimAdmit
      c.codes.1 c.codes.2 c.lineageFlags.1 c.lineageFlags.2
      c.vmFlags.1 c.vmFlags.2
      c.reservations.1 c.reservations.2 c.boots.1 c.boots.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨inLin, sup⟩, ⟨vLive, vElig⟩, ⟨hRes, pRes⟩, ⟨nBoot, pBoot⟩⟩
    change (verifyVmClaimAdmit phC opC inLin sup vLive vElig hRes pRes nBoot pBoot == 1) = true at h
    dsimp [ClaimAdmitDomainSafe]
    unfold verifyVmClaimAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨⟨⟨⟨_, _⟩, hlin⟩, hsup⟩, hvL⟩, hvE⟩, hb0⟩, hbEq⟩, hp0⟩, hbr⟩
    have hbPos : 0 < nBoot.toNat := by
      have hne : nBoot.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq nBoot 0 hz)
      omega
    have hpPos : 0 < pRes.toNat := by
      have hne : pRes.toNat ≠ 0 := fun hz => hp0 (u64_eq_of_toNat_eq pRes 0 hz)
      omega
    subst hlin; subst hsup; subst hbEq
    refine ⟨rfl, rfl, UInt8.le_iff_toNat_le.mp hvL, UInt8.le_iff_toNat_le.mp hvE, hbPos, rfl, hpPos, ?_⟩
    rcases hbr with (h0 | h1) | h2
    · rcases h0 with ⟨⟨⟨⟨hop, hph⟩, hv1⟩, he1⟩, hlt⟩
      subst hop hph hv1 he1
      exact ⟨.unowned, rfl, .claim, rfl, rfl, rfl, rfl, UInt64.lt_iff_toNat_lt.mp hlt⟩
    · rcases h1 with ⟨⟨⟨⟨hop, hph⟩, heq⟩, hh0⟩, hveEq⟩
      subst hop; subst hph
      have hhPos : 0 < hRes.toNat := by
        have hne : hRes.toNat ≠ 0 := fun hz => hh0 (u64_eq_of_toNat_eq hRes 0 hz)
        omega
      exact ⟨.claimed, rfl, .release, rfl, rfl, hhPos, by rw [heq], by rw [hveEq]⟩
    · rcases h2 with ⟨⟨⟨⟨hop, hph⟩, hv1⟩, he1⟩, hlt⟩
      subst hop hph hv1 he1
      exact ⟨.released, rfl, .reclaim, rfl, rfl, rfl, rfl, UInt64.lt_iff_toNat_lt.mp hlt⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨inLin, sup⟩, ⟨vLive, vElig⟩, ⟨hRes, pRes⟩, ⟨nBoot, pBoot⟩⟩
    change (verifyVmClaimAdmit phC opC inLin sup vLive vElig hRes pRes nBoot pBoot == 1) = true
    dsimp [ClaimAdmitDomainSafe] at h
    rcases h with ⟨hlin, hsup, hvL, hvE, hbPos, hbEq, hpPos, ph, hphDec, op, hopDec, hbr⟩
    have hlin1 := u8_eq_of_toNat inLin 1 (by omega) hlin
    have hsup0 := u8_eq_of_toNat sup 0 (by omega) hsup
    have hvLB : vLive ≤ 1 := UInt8.le_iff_toNat_le.mpr hvL
    have hvEB : vElig ≤ 1 := UInt8.le_iff_toNat_le.mpr hvE
    have hbNe : (nBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hbPos
    have hbEqB := u64_eq_of_toNat_eq pBoot nBoot hbEq
    have hpNe : (pRes != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hpPos
    have hphC := claimPhase_code_of_decode hphDec
    have hopC := claimOp_code_of_decode hopDec
    subst hlin1 hsup0 hbEqB hphC hopC
    unfold verifyVmClaimAdmit
    cases op with
    | claim =>
      rcases hbr with ⟨rfl, hv1, he1, hlt⟩
      have hv1B := u8_eq_of_toNat vLive 1 (by omega) hv1
      have he1B := u8_eq_of_toNat vElig 1 (by omega) he1
      have hltB : hRes < pRes := UInt64.lt_iff_toNat_lt.mpr hlt
      subst hv1B; subst he1B
      simp [ClaimPhase.encode, ClaimOp.encode, hbNe, hpNe, hltB]
    | release =>
      rcases hbr with ⟨rfl, _, heq, hveEq⟩
      have heqB := u64_eq_of_toNat_eq pRes hRes heq
      have hveB : vLive = vElig := by
        have hvEligEq := u8_eq_of_toNat vElig vElig.toNat (by omega) rfl
        have hvLiveEq := u8_eq_of_toNat vLive vElig.toNat (by omega) hveEq
        exact hvLiveEq.trans hvEligEq.symm
      subst heqB; subst hveB
      simp [ClaimPhase.encode, ClaimOp.encode, hvEB, hbNe, hpNe]
    | reclaim =>
      rcases hbr with ⟨rfl, hv1, he1, hlt⟩
      have hv1B := u8_eq_of_toNat vLive 1 (by omega) hv1
      have he1B := u8_eq_of_toNat vElig 1 (by omega) he1
      have hltB : hRes < pRes := UInt64.lt_iff_toNat_lt.mpr hlt
      subst hv1B; subst he1B
      simp [ClaimPhase.encode, ClaimOp.encode, hbNe, hpNe, hltB]
  posWitness := { codes := (0, 0), lineageFlags := (1, 0), vmFlags := (1, 1), reservations := (0, 7), boots := (4, 4) }
  negWitness := { codes := (1, 0), lineageFlags := (1, 0), vmFlags := (1, 1), reservations := (7, 7), boots := (4, 4) }
  nonVacuous := by decide
  tight := by decide

def vmClaimScopedAuthority : ScopedAuthority ClaimAdmitCheck where
  admit := vmClaimMetaGate.gate
  scopeValid c :=
    c.lineageFlags.1 == 1 && c.lineageFlags.2 == 0 &&
    c.boots.1 != 0 && c.boots.2 == c.boots.1 &&
    ((c.codes.2 == 1 && c.vmFlags.1 == c.vmFlags.2) ||
     (c.vmFlags.1 == 1 && c.vmFlags.2 == 1))
  sound c h := by
    have hs := vmClaimMetaGate.sound c h
    rcases c with ⟨⟨phC, opC⟩, ⟨inLin, sup⟩, ⟨vLive, vElig⟩, _, ⟨nBoot, pBoot⟩⟩
    dsimp [ClaimAdmitDomainSafe] at hs
    rcases hs with ⟨hlin, hsup, _, hvE, hbPos, hbEq, _, _, _, op, hopDec, hbr⟩
    have hlin1 := u8_eq_of_toNat inLin 1 (by omega) hlin
    have hsup0 := u8_eq_of_toNat sup 0 (by omega) hsup
    have hbNe : (nBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hbPos
    have hbEqB := u64_eq_of_toNat_eq pBoot nBoot hbEq
    have hopC := claimOp_code_of_decode hopDec
    subst hlin1 hsup0 hbEqB hopC
    cases op with
    | claim =>
      rcases hbr with ⟨_, hv1, he1, _⟩
      have hv1B := u8_eq_of_toNat vLive 1 (by omega) hv1
      have he1B := u8_eq_of_toNat vElig 1 (by omega) he1
      subst hv1B; subst he1B
      simp [ClaimOp.encode, hbNe]
    | release =>
      rcases hbr with ⟨_, _, _, hveEq⟩
      have hveB : vLive = vElig := by
        have hvEligEq := u8_eq_of_toNat vElig vElig.toNat (by omega) rfl
        have hvLiveEq := u8_eq_of_toNat vLive vElig.toNat (by omega) hveEq
        exact hvLiveEq.trans hvEligEq.symm
      subst hveB
      simp [ClaimOp.encode, hbNe]
    | reclaim =>
      rcases hbr with ⟨_, hv1, he1, _⟩
      have hv1B := u8_eq_of_toNat vLive 1 (by omega) hv1
      have he1B := u8_eq_of_toNat vElig 1 (by omega) he1
      subst hv1B; subst he1B
      simp [ClaimOp.encode, hbNe]

def vmClaimDuplicateReplayIdempotence : ReplayIdempotence ClaimSliceState ClaimSliceEvent ClaimEffect where
  step := stepClaimSlice
  alreadyAcked s ev :=
    (s.phaseCode == 1 || s.phaseCode == 2) &&
    (ev.opCode == 0 || ev.opCode == 2) &&
    ev.presentedReservation == s.reservationId
  idempotent s ev hf := by
    unfold stepClaimSlice
    dsimp only
    let effPhase : UInt8 :=
      if (s.phaseCode == 1 || s.phaseCode == 2) &&
         s.claimBoot != 0 && s.claimBoot < s.nodeBootEpoch && ev.opCode == 0
      then 0
      else s.phaseCode
    have hfalse : ¬ ((s.phaseCode == 0 || s.claimBoot == 0 ||
        (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
        ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) &&
        verifyVmClaimAdmit effPhase ev.opCode ev.ownerInLineage ev.ownerSuperseded
          ev.vmLive ev.activeComputeEligible
          s.reservationId ev.presentedReservation s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
      intro hcond
      have hadm : (verifyVmClaimAdmit effPhase ev.opCode ev.ownerInLineage ev.ownerSuperseded
          ev.vmLive ev.activeComputeEligible
          s.reservationId ev.presentedReservation s.nodeBootEpoch ev.presentedBootEpoch == 1) = true :=
        (Bool.and_eq_true _ _ |>.mp hcond).2
      have hs := vmClaimMetaGate.sound
        { codes := (effPhase, ev.opCode)
          lineageFlags := (ev.ownerInLineage, ev.ownerSuperseded)
          vmFlags := (ev.vmLive, ev.activeComputeEligible)
          reservations := (s.reservationId, ev.presentedReservation)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
      dsimp [ClaimAdmitDomainSafe] at hs
      rcases hs with ⟨_, _, _, _, _, _, _, _, _, op, hopDec, hbr⟩
      have hopC := claimOp_code_of_decode hopDec
      simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at hf
      rcases hf with ⟨⟨_, hop02⟩, hresEq⟩
      rcases hop02 with hop0 | hop2
      · rw [hop0] at hopC
        cases op <;> simp [ClaimOp.encode] at hopC
        rcases hbr with ⟨_, _, _, hlt⟩
        rw [hresEq] at hlt
        omega
      · rw [hop2] at hopC
        cases op <;> simp [ClaimOp.encode] at hopC
        rcases hbr with ⟨_, _, _, hlt⟩
        rw [hresEq] at hlt
        omega
    exact ite_eq_right_iff.mpr (fun h => absurd h hfalse)

/-- Reservation uniqueness, lineage, boot-epoch fencing, stopped-VM compute eligibility, and
    cross-`stop -> resume` (`nodeBootEpoch` advance) claim recovery:
    1. A second claim of the same `reservation_id` is rejected.
    2. Any claim/reclaim/release from a superseded/orphaned owner or stale boot epoch is rejected.
    3. `claim`/`reclaim` against a non-eligible (`activeComputeEligible ≠ 1` or `vmLive ≠ 1`) VM
       is rejected, whereas `release` (`opCode = 1`) on a stopped VM (`vmLive = 0, activeComputeEligible = 0`)
       with matching `nodeBootEpoch` succeeds (`phaseCode = 2`).
    4. After `stop -> resume` advances `nodeBootEpoch` past a prior boot's `released` or
       boot-orphaned `claimed` row (`0 < claimBoot < nodeBootEpoch`), a fresh `claim` (`opCode = 0`)
       with `reservationId < presentedReservation` on the live compute-eligible VM succeeds (`phaseCode = 1`). -/
theorem duplicate_reservation_superseded_stale_and_ineligible_rejected
    (s : ClaimSliceState) (ev : ClaimSliceEvent) :
    ((s.phaseCode = 1 ∨ s.phaseCode = 2) ∧
     (ev.opCode = 0 ∨ ev.opCode = 2) ∧
     ev.presentedReservation = s.reservationId →
       stepClaimSlice s ev = (s, [])) ∧
    ((ev.ownerInLineage ≠ 1 ∨ ev.ownerSuperseded ≠ 0 ∨
      s.nodeBootEpoch = 0 ∨ ev.presentedBootEpoch ≠ s.nodeBootEpoch) →
       stepClaimSlice s ev = (s, [])) ∧
    (((ev.opCode = 0 ∨ ev.opCode = 2) ∧ (ev.vmLive ≠ 1 ∨ ev.activeComputeEligible ≠ 1)) →
       stepClaimSlice s ev = (s, [])) ∧
    (s.phaseCode = 1 ∧ s.reservationId ≠ 0 ∧ s.nodeBootEpoch ≠ 0 ∧
     (s.claimBoot = 0 ∨ s.claimBoot = s.nodeBootEpoch) ∧
     ev.opCode = 1 ∧ ev.ownerInLineage = 1 ∧ ev.ownerSuperseded = 0 ∧
     ev.vmLive = 0 ∧ ev.activeComputeEligible = 0 ∧
     ev.presentedReservation = s.reservationId ∧ ev.presentedBootEpoch = s.nodeBootEpoch →
       (stepClaimSlice s ev).1.phaseCode = 2) ∧
    ((s.phaseCode = 1 ∨ s.phaseCode = 2) ∧ s.claimBoot ≠ 0 ∧ s.claimBoot < s.nodeBootEpoch ∧
     ev.opCode = 0 ∧ ev.ownerInLineage = 1 ∧ ev.ownerSuperseded = 0 ∧
     ev.vmLive = 1 ∧ ev.activeComputeEligible = 1 ∧
     s.reservationId < ev.presentedReservation ∧ ev.presentedBootEpoch = s.nodeBootEpoch →
       (stepClaimSlice s ev).1.phaseCode = 1 ∧
       (stepClaimSlice s ev).1.reservationId = ev.presentedReservation ∧
       (stepClaimSlice s ev).1.claimBoot = s.nodeBootEpoch) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · rintro ⟨hph, hop, hres⟩
    refine vmClaimDuplicateReplayIdempotence.idempotent s ev ?_
    rcases hph with h1 | h2 <;> rcases hop with o0 | o2 <;>
      simp [vmClaimDuplicateReplayIdempotence, *]
  · intro hbad
    unfold stepClaimSlice
    dsimp only
    let effPhase : UInt8 :=
      if (s.phaseCode == 1 || s.phaseCode == 2) &&
         s.claimBoot != 0 && s.claimBoot < s.nodeBootEpoch && ev.opCode == 0
      then 0
      else s.phaseCode
    have hfalse : ¬ ((s.phaseCode == 0 || s.claimBoot == 0 ||
        (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
        ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) &&
        verifyVmClaimAdmit effPhase ev.opCode ev.ownerInLineage ev.ownerSuperseded
          ev.vmLive ev.activeComputeEligible
          s.reservationId ev.presentedReservation s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
      intro hcond
      have hadm := (Bool.and_eq_true _ _ |>.mp hcond).2
      have hsc := vmClaimScopedAuthority.sound
        { codes := (effPhase, ev.opCode)
          lineageFlags := (ev.ownerInLineage, ev.ownerSuperseded)
          vmFlags := (ev.vmLive, ev.activeComputeEligible)
          reservations := (s.reservationId, ev.presentedReservation)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
      dsimp [vmClaimScopedAuthority] at hsc
      simp only [Bool.and_eq_true, bne_iff_ne, beq_iff_eq] at hsc
      rcases hsc with ⟨⟨⟨⟨hlin, hsup⟩, hb0⟩, hbEq⟩, _⟩
      rcases hbad with hnlin | hnsup | hbz | hbne
      · exact hnlin hlin
      · exact hnsup hsup
      · exact hb0 hbz
      · exact hbne hbEq
    exact ite_eq_right_iff.mpr (fun h => absurd h hfalse)
  · rintro ⟨hop02, hinelig⟩
    unfold stepClaimSlice
    dsimp only
    let effPhase : UInt8 :=
      if (s.phaseCode == 1 || s.phaseCode == 2) &&
         s.claimBoot != 0 && s.claimBoot < s.nodeBootEpoch && ev.opCode == 0
      then 0
      else s.phaseCode
    have hfalse : ¬ ((s.phaseCode == 0 || s.claimBoot == 0 ||
        (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
        ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) &&
        verifyVmClaimAdmit effPhase ev.opCode ev.ownerInLineage ev.ownerSuperseded
          ev.vmLive ev.activeComputeEligible
          s.reservationId ev.presentedReservation s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
      intro hcond
      have hadm := (Bool.and_eq_true _ _ |>.mp hcond).2
      have hsc := vmClaimScopedAuthority.sound
        { codes := (effPhase, ev.opCode)
          lineageFlags := (ev.ownerInLineage, ev.ownerSuperseded)
          vmFlags := (ev.vmLive, ev.activeComputeEligible)
          reservations := (s.reservationId, ev.presentedReservation)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
      dsimp [vmClaimScopedAuthority] at hsc
      simp only [Bool.and_eq_true, Bool.or_eq_true, bne_iff_ne, beq_iff_eq] at hsc
      rcases hsc with ⟨_, ⟨hop1, _⟩ | ⟨hv1, he1⟩⟩
      · rcases hop02 with o0 | o2
        · rw [o0] at hop1; simp at hop1
        · rw [o2] at hop1; simp at hop1
      · rcases hinelig with hnv | hne
        · exact hnv hv1
        · exact hne he1
    exact ite_eq_right_iff.mpr (fun h => absurd h hfalse)
  · rintro ⟨hph1, hr0, hb0, hcb, hop1, hlin, hsup, hvl0, hel0, hresEq, hbootEq⟩
    have hrPos : 0 < s.reservationId.toNat := by
      have hne : s.reservationId.toNat ≠ 0 := fun hz => hr0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hbPos : 0 < s.nodeBootEpoch.toNat := by
      have hne : s.nodeBootEpoch.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : vmClaimMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          lineageFlags := (ev.ownerInLineage, ev.ownerSuperseded)
          vmFlags := (ev.vmLive, ev.activeComputeEligible)
          reservations := (s.reservationId, ev.presentedReservation)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } = true := by
      apply vmClaimMetaGate.complete
      refine ⟨by rw [hlin]; rfl, by rw [hsup]; rfl,
        show ev.vmLive.toNat ≤ 1 by rw [hvl0]; decide,
        show ev.activeComputeEligible.toNat ≤ 1 by rw [hel0]; decide,
        hbPos, by rw [hbootEq], by rw [hresEq]; exact hrPos,
        .claimed, by rw [hph1]; rfl, .release, by rw [hop1]; rfl,
        rfl, hrPos, by rw [hresEq], by rw [hvl0]; rw [hel0]⟩
    have hcbOk : (s.phaseCode == 0 || s.claimBoot == 0 ||
        (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
        ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) = true := by
      rcases hcb with hcb0 | hcbEq
      · simp [hcb0]
      · simp [hop1, hcbEq]
    unfold stepClaimSlice vmClaimTargetPhase
    dsimp [vmClaimMetaGate] at hadm
    have heff : (if (s.phaseCode == 1 || s.phaseCode == 2) &&
        s.claimBoot != 0 && s.claimBoot < s.nodeBootEpoch && ev.opCode == 0
        then (0 : UInt8) else s.phaseCode) = s.phaseCode := by
      simp [hop1]
    dsimp only
    rw [heff]
    have hboth : ((s.phaseCode == 0 || s.claimBoot == 0 ||
        (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
        ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) &&
        verifyVmClaimAdmit s.phaseCode ev.opCode ev.ownerInLineage ev.ownerSuperseded
          ev.vmLive ev.activeComputeEligible
          s.reservationId ev.presentedReservation s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
      simp [hcbOk, hadm]
    rw [ite_eq_left_iff.mpr (fun h => absurd hboth h)]
    simp [hop1]
  · rintro ⟨hph12, hcb0, hcbLt, hop0, hlin, hsup, hvl1, hel1, hresLt, hbootEq⟩
    have hcbLtN := UInt64.lt_iff_toNat_lt.mp hcbLt
    have hbPos : 0 < s.nodeBootEpoch.toNat := by omega
    have hresLtN := UInt64.lt_iff_toNat_lt.mp hresLt
    have hpPos : 0 < ev.presentedReservation.toNat := by omega
    have hadm : vmClaimMetaGate.gate
        { codes := (0, ev.opCode)
          lineageFlags := (ev.ownerInLineage, ev.ownerSuperseded)
          vmFlags := (ev.vmLive, ev.activeComputeEligible)
          reservations := (s.reservationId, ev.presentedReservation)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } = true := by
      apply vmClaimMetaGate.complete
      refine ⟨by rw [hlin]; rfl, by rw [hsup]; rfl,
        show ev.vmLive.toNat ≤ 1 by rw [hvl1]; decide,
        show ev.activeComputeEligible.toNat ≤ 1 by rw [hel1]; decide,
        hbPos, by rw [hbootEq], hpPos,
        .unowned, rfl, .claim, by rw [hop0]; rfl,
        rfl, by rw [hvl1]; rfl, by rw [hel1]; rfl, hresLtN⟩
    have hcbLe : s.claimBoot ≤ s.nodeBootEpoch := UInt64.le_iff_toNat_le.mpr (by omega)
    have hcbNe : (s.claimBoot != 0) = true := bne_iff_ne.mpr hcb0
    have hphB : (s.phaseCode == 1 || s.phaseCode == 2) = true := by
      rcases hph12 with h1 | h2 <;> simp [*]
    unfold stepClaimSlice vmClaimTargetPhase
    dsimp [vmClaimMetaGate] at hadm
    have heff : (if (s.phaseCode == 1 || s.phaseCode == 2) &&
        s.claimBoot != 0 && s.claimBoot < s.nodeBootEpoch && ev.opCode == 0
        then (0 : UInt8) else s.phaseCode) = 0 := by
      simp [hphB, hcbNe, hcbLt, hop0]
    dsimp only
    rw [heff]
    have hcbOk : (s.phaseCode == 0 || s.claimBoot == 0 ||
        (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
        ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) = true := by
      simp [hop0, hcbLe]
    have hboth : ((s.phaseCode == 0 || s.claimBoot == 0 ||
        (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
        ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) &&
        verifyVmClaimAdmit 0 ev.opCode ev.ownerInLineage ev.ownerSuperseded
          ev.vmLive ev.activeComputeEligible
          s.reservationId ev.presentedReservation s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
      simp [hcbOk, hadm]
    rw [ite_eq_left_iff.mpr (fun h => absurd hboth h)]
    simp [hop0]

/-! ## 3. `RemoteJobLedger` (`SM-20`) -/

structure JobAdmitCheck where
  codes : UInt8 × UInt8
  ops   : UInt64 × UInt64
  boots : UInt64 × UInt64
  deriving Repr, DecidableEq

def JobAdmitDomainSafe (c : JobAdmitCheck) : Prop :=
  0 < c.boots.2.toNat ∧
  0 < c.ops.2.toNat ∧
  c.boots.1.toNat = c.boots.2.toNat ∧
  ∃ ph, JobPhase.decode? c.codes.1.toNat = some ph ∧ ph.isTerminal = false ∧
    ∃ op, JobOp.decode? c.codes.2.toNat = some op ∧ op ≠ .retry ∧
      match op with
      | .accept => ph = .absent ∧ c.ops.1.toNat = 0
      | .markUncertain => ph = .accepted ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .succeed => ph = .accepted ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .fail => ph = .accepted ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .cancel => ph = .accepted ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .retry => False
      | .bindReconciledAccepted => ph = .uncertain ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .reconcileSucceeded => ph = .uncertain ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .reconcileFailed => ph = .uncertain ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .reconcileCancelled => ph = .uncertain ∧ 0 < c.ops.1.toNat ∧ c.ops.2.toNat = c.ops.1.toNat
      | .confirmNotDeliveredRetry => ph = .uncertain ∧ 0 < c.ops.1.toNat ∧ c.ops.1.toNat < c.ops.2.toNat

private theorem jobPhase_code_of_decode {x : UInt8} {ph : JobPhase}
    (h : JobPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [JobPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | k6 <;>
        simp [JobPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [JobPhase.encode] using hcode

private theorem jobOp_code_of_decode {x : UInt8} {op : JobOp}
    (h : JobOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [JobOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | _ | _ | _ | _ | _ | _ | k11 <;>
        simp [JobOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [JobOp.encode] using hcode

def remoteJobMetaGate : MetaGateSpec JobAdmitCheck JobAdmitDomainSafe where
  gate c :=
    verifyRemoteJobAdmit c.codes.1 c.codes.2 c.ops.1 c.ops.2 c.boots.1 c.boots.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨hOp, pOp⟩, ⟨oBoot, nBoot⟩⟩
    change (verifyRemoteJobAdmit phC opC hOp pOp oBoot nBoot == 1) = true at h
    dsimp [JobAdmitDomainSafe]
    unfold verifyRemoteJobAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨_, _⟩, hnb0⟩, hp0⟩, hbootEq⟩, hbr⟩
    have hnbPos : 0 < nBoot.toNat := by
      have hne : nBoot.toNat ≠ 0 := fun hz => hnb0 (u64_eq_of_toNat_eq nBoot 0 hz)
      omega
    have hpPos : 0 < pOp.toNat := by
      have hne : pOp.toNat ≠ 0 := fun hz => hp0 (u64_eq_of_toNat_eq pOp 0 hz)
      omega
    refine ⟨hnbPos, hpPos, by rw [hbootEq], ?_⟩
    rcases hbr with ((h0 | h14) | h6789) | h10
    · rcases h0 with ⟨⟨hop, hph⟩, hh0⟩
      subst hop; subst hph; subst hh0
      exact ⟨.absent, rfl, rfl, .accept, rfl, by decide, rfl, rfl⟩
    · rcases h14 with ⟨⟨⟨hop, hph⟩, hh0⟩, heq⟩; subst hph
      have hhPos : 0 < hOp.toNat := by
        have hne : hOp.toNat ≠ 0 := fun hz => hh0 (u64_eq_of_toNat_eq hOp 0 hz)
        omega
      rcases hop with ((hop | hop) | hop) | hop <;> subst hop
      · exact ⟨.accepted, rfl, rfl, .markUncertain, rfl, by decide, rfl, hhPos, by rw [heq]⟩
      · exact ⟨.accepted, rfl, rfl, .succeed, rfl, by decide, rfl, hhPos, by rw [heq]⟩
      · exact ⟨.accepted, rfl, rfl, .fail, rfl, by decide, rfl, hhPos, by rw [heq]⟩
      · exact ⟨.accepted, rfl, rfl, .cancel, rfl, by decide, rfl, hhPos, by rw [heq]⟩
    · rcases h6789 with ⟨⟨⟨hop, hph⟩, hh0⟩, heq⟩; subst hph
      have hhPos : 0 < hOp.toNat := by
        have hne : hOp.toNat ≠ 0 := fun hz => hh0 (u64_eq_of_toNat_eq hOp 0 hz)
        omega
      rcases hop with ((hop | hop) | hop) | hop <;> subst hop
      · exact ⟨.uncertain, rfl, rfl, .bindReconciledAccepted, rfl, by decide, rfl, hhPos, by rw [heq]⟩
      · exact ⟨.uncertain, rfl, rfl, .reconcileSucceeded, rfl, by decide, rfl, hhPos, by rw [heq]⟩
      · exact ⟨.uncertain, rfl, rfl, .reconcileFailed, rfl, by decide, rfl, hhPos, by rw [heq]⟩
      · exact ⟨.uncertain, rfl, rfl, .reconcileCancelled, rfl, by decide, rfl, hhPos, by rw [heq]⟩
    · rcases h10 with ⟨⟨⟨hop, hph⟩, hh0⟩, hlt⟩; subst hop; subst hph
      have hhPos : 0 < hOp.toNat := by
        have hne : hOp.toNat ≠ 0 := fun hz => hh0 (u64_eq_of_toNat_eq hOp 0 hz)
        omega
      exact ⟨.uncertain, rfl, rfl, .confirmNotDeliveredRetry, rfl, by decide, rfl, hhPos,
        UInt64.lt_iff_toNat_lt.mp hlt⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨hOp, pOp⟩, ⟨oBoot, nBoot⟩⟩
    change (verifyRemoteJobAdmit phC opC hOp pOp oBoot nBoot == 1) = true
    dsimp [JobAdmitDomainSafe] at h
    rcases h with ⟨hnbPos, hpPos, hbootEq, ph, hphDec, _, op, hopDec, _, hbr⟩
    have hnbNe : (nBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hnbPos
    have hpNe : (pOp != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hpPos
    have hbEq := u64_eq_of_toNat_eq oBoot nBoot hbootEq
    have hphC := jobPhase_code_of_decode hphDec
    have hopC := jobOp_code_of_decode hopDec
    subst hbEq; subst hphC; subst hopC
    unfold verifyRemoteJobAdmit
    cases op with
    | accept =>
      rcases hbr with ⟨rfl, hh0⟩
      have hhEq := u64_eq_of_toNat_eq hOp 0 hh0
      subst hhEq; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | markUncertain =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | succeed =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | fail =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | cancel =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | retry => exact False.elim hbr
    | bindReconciledAccepted =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | reconcileSucceeded =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | reconcileFailed =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | reconcileCancelled =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pOp hOp heq
      subst heqB; simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe]
    | confirmNotDeliveredRetry =>
      rcases hbr with ⟨rfl, hhPos, hlt⟩
      have hltB : hOp < pOp := UInt64.lt_iff_toNat_lt.mpr hlt
      have hhNe : (hOp != 0) = true := by
        rw [bne_iff_ne]; intro hz
        subst hz; simp at hhPos
      simp [JobPhase.encode, JobOp.encode, hnbNe, hpNe, hltB, hhNe]
  posWitness := { codes := (1, 2), ops := (9, 9), boots := (4, 4) }
  negWitness := { codes := (2, 5), ops := (9, 9), boots := (4, 4) }
  nonVacuous := by decide
  tight := by decide

private theorem job_terminal_step_id (s : JobSliceState) (ev : JobSliceEvent)
    (hf : (decide (3 ≤ s.phaseCode) && decide (s.phaseCode ≤ 5)) = true) :
    stepJobSlice s ev = (s, []) := by
  unfold stepJobSlice
  dsimp only
  have hfalse : ¬ (ev.operationBootEpoch == ev.nodeBootEpoch &&
      (s.phaseCode == 0 || ev.operationBootEpoch == s.operationBoot) &&
      verifyRemoteJobAdmit s.phaseCode ev.opCode s.operationId ev.presentedOperation
        ev.operationBootEpoch ev.nodeBootEpoch == 1) = true := by
    intro hcond
    have hadm := ((Bool.and_eq_true _ _ |>.mp hcond).2)
    have hs := remoteJobMetaGate.sound
      { codes := (s.phaseCode, ev.opCode)
        ops := (s.operationId, ev.presentedOperation)
        boots := (ev.operationBootEpoch, ev.nodeBootEpoch) } hadm
    dsimp [JobAdmitDomainSafe] at hs
    rcases hs with ⟨_, _, _, ph, hphDec, hnt, _⟩
    have hpc := jobPhase_code_of_decode hphDec
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hf
    have hge3 := UInt8.le_iff_toNat_le.mp hf.1
    rw [hpc] at hge3
    cases ph <;> simp [JobPhase.encode] at hge3 <;> simp [JobPhase.isTerminal] at hnt
  rw [ite_eq_right_iff.mpr (fun h => absurd h hfalse)]

def remoteJobTerminalStickyFence : StickyFence JobSliceState JobSliceEvent where
  fenced s := decide (3 ≤ s.phaseCode) && decide (s.phaseCode ≤ 5)
  preFenceAct s := s.phaseCode == 0 || s.phaseCode == 1
  step s ev := (stepJobSlice s ev).1
  sticky s ev hf := by rw [job_terminal_step_id s ev hf]; exact hf
  forbids_post s ev hf := by
    rw [job_terminal_step_id s ev hf]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hf
    have hge3 := UInt8.le_iff_toNat_le.mp hf.1
    apply Bool.eq_false_iff.mpr
    intro h01
    simp only [Bool.or_eq_true, beq_iff_eq] at h01
    rcases h01 with h0 | h1
    · rw [h0] at hge3; simp at hge3
    · rw [h1] at hge3; simp at hge3

private theorem job_uncertain_below6_step_id (s : JobSliceState) (ev : JobSliceEvent)
    (hph2 : s.phaseCode = 2) (hnoRec : ev.opCode < 6) :
    stepJobSlice s ev = (s, []) := by
  unfold stepJobSlice
  have hadmFalse : ¬ (ev.operationBootEpoch == ev.nodeBootEpoch &&
      (s.phaseCode == 0 || ev.operationBootEpoch == s.operationBoot) &&
      verifyRemoteJobAdmit s.phaseCode ev.opCode s.operationId ev.presentedOperation
        ev.operationBootEpoch ev.nodeBootEpoch == 1) = true := by
    intro hcond
    have hadm := (Bool.and_eq_true _ _ |>.mp hcond).2
    have hs := remoteJobMetaGate.sound
      { codes := (s.phaseCode, ev.opCode)
        ops := (s.operationId, ev.presentedOperation)
        boots := (ev.operationBootEpoch, ev.nodeBootEpoch) } hadm
    dsimp [JobAdmitDomainSafe] at hs
    rcases hs with ⟨_, _, _, ph, hphDec, _, op, hopDec, _, hbr⟩
    rw [hph2] at hphDec
    simp [JobPhase.decode?] at hphDec
    subst hphDec
    have hopC := jobOp_code_of_decode hopDec
    have hlt6 : ev.opCode.toNat < 6 := UInt8.lt_iff_toNat_lt.mp hnoRec
    cases op
    · exact nomatch hbr.1
    · exact nomatch hbr.1
    · exact nomatch hbr.1
    · exact nomatch hbr.1
    · exact nomatch hbr.1
    · exact hbr
    · rw [hopC] at hlt6
      simp [JobOp.encode] at hlt6
    · rw [hopC] at hlt6
      simp [JobOp.encode] at hlt6
    · rw [hopC] at hlt6
      simp [JobOp.encode] at hlt6
    · rw [hopC] at hlt6
      simp [JobOp.encode] at hlt6
    · rw [hopC] at hlt6
      simp [JobOp.encode] at hlt6
  dsimp only
  exact ite_eq_right_iff.mpr (fun h => absurd h hadmFalse)

/-- `Uncertain (2)` stays `Uncertain` for every event that is not an explicit reconciliation
    (`opCode` `6..10`). A blind `retry` (`5`) and every pre-reconcile opcode are included. -/
def remoteJobUncertainNoFreshRetryFence :
    StickyFence JobSliceState { ev : JobSliceEvent // ev.opCode < 6 } where
  fenced s := s.phaseCode == 2
  preFenceAct s := s.phaseCode == 1
  step s ev := (stepJobSlice s ev.val).1
  sticky s ev hf := by
    rcases ev with ⟨ev, hnoRec⟩
    have hph2 : s.phaseCode = 2 := by rwa [beq_iff_eq] at hf
    rw [job_uncertain_below6_step_id s ev hph2 hnoRec]
    exact hf
  forbids_post s ev hf := by
    rcases ev with ⟨ev, hnoRec⟩
    have hph2 : s.phaseCode = 2 := by rwa [beq_iff_eq] at hf
    rw [job_uncertain_below6_step_id s ev hph2 hnoRec]
    simp [hph2]

def remoteJobBootScopedAuthority : ScopedAuthority JobAdmitCheck where
  admit := remoteJobMetaGate.gate
  scopeValid c := c.boots.2 != 0 && c.boots.1 == c.boots.2
  sound c h := by
    have hs := remoteJobMetaGate.sound c h
    rcases c with ⟨_, _, ⟨oBoot, nBoot⟩⟩
    rcases hs with ⟨hnbPos, _, heq, _⟩
    have hnbNe : (nBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hnbPos
    have heqB := u64_eq_of_toNat_eq oBoot nBoot heq
    subst heqB; simp [hnbNe]

/-- Boot fencing, sticky uncertainty outside explicit reconciliation, and first-terminal-wins:
    1. A step is rejected unless the event presents `operationBootEpoch = nodeBootEpoch` and, once
       a phase is held, that boot equals the recorded `operationBoot` (no stored-boot substitution).
    2. From `Uncertain (2)`, opcodes below `6` (including blind `retry = 5`) leave the slice unchanged.
       Same-operation reconciliation (`6..9`) and a strictly fresher not-delivered retry (`10`) exit.
    3. `succeeded` / `failed` / `cancelled` (`3..5`) stay terminal for every later event. -/
theorem remote_job_boot_fenced_uncertain_sticky_and_first_terminal_wins
    (s : JobSliceState) (ev : JobSliceEvent) :
    ((ev.operationBootEpoch ≠ ev.nodeBootEpoch ∨
      (s.phaseCode ≠ 0 ∧ ev.operationBootEpoch ≠ s.operationBoot)) →
       stepJobSlice s ev = (s, [])) ∧
    (s.phaseCode = 2 ∧ ev.opCode < 6 → stepJobSlice s ev = (s, [])) ∧
    ((s.phaseCode = 3 ∨ s.phaseCode = 4 ∨ s.phaseCode = 5) → stepJobSlice s ev = (s, [])) ∧
    (s.phaseCode = 2 ∧ s.operationId ≠ 0 ∧ s.operationBoot ≠ 0 ∧
     ev.operationBootEpoch = s.operationBoot ∧ ev.nodeBootEpoch = s.operationBoot ∧
     ev.presentedOperation = s.operationId ∧
     (ev.opCode = 6 ∨ ev.opCode = 7 ∨ ev.opCode = 8 ∨ ev.opCode = 9) →
       (stepJobSlice s ev).1.phaseCode = remoteJobTargetPhase ev.opCode) ∧
    (s.phaseCode = 2 ∧ s.operationId ≠ 0 ∧ s.operationBoot ≠ 0 ∧
     ev.opCode = 10 ∧ ev.operationBootEpoch = s.operationBoot ∧ ev.nodeBootEpoch = s.operationBoot ∧
     s.operationId < ev.presentedOperation →
       (stepJobSlice s ev).1.phaseCode = 1 ∧
       (stepJobSlice s ev).1.operationId = ev.presentedOperation) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro hbad
    unfold stepJobSlice
    dsimp only
    have hfalse : ¬ (ev.operationBootEpoch == ev.nodeBootEpoch &&
        (s.phaseCode == 0 || ev.operationBootEpoch == s.operationBoot) &&
        verifyRemoteJobAdmit s.phaseCode ev.opCode s.operationId ev.presentedOperation
          ev.operationBootEpoch ev.nodeBootEpoch == 1) = true := by
      intro hcond
      simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at hcond
      rcases hcond with ⟨⟨hbootEq, hheld⟩, _⟩
      rcases hbad with hneBoot | ⟨hph, hneOp⟩
      · exact hneBoot hbootEq
      · rcases hheld with h0 | heq
        · exact hph h0
        · exact hneOp heq
    rw [ite_eq_right_iff.mpr (fun h => absurd h hfalse)]
  · rintro ⟨h2, hlt⟩
    exact job_uncertain_below6_step_id s ev h2 hlt
  · intro hterm
    refine job_terminal_step_id s ev ?_
    rcases hterm with h3 | h4 | h5
    · rw [h3]; decide
    · rw [h4]; decide
    · rw [h5]; decide
  · rintro ⟨hph2, hid0, hboot0, hbootEq, hnodeEq, hpresEq, hop⟩
    have hidPos : 0 < s.operationId.toNat := by
      have hne : s.operationId.toNat ≠ 0 := fun hz => hid0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hbPos : 0 < s.operationBoot.toNat := by
      have hne : s.operationBoot.toNat ≠ 0 := fun hz => hboot0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hopOne : ev.opCode = 6 ∨ ev.opCode = 7 ∨ ev.opCode = 8 ∨ ev.opCode = 9 := hop
    have hadm : remoteJobMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          ops := (s.operationId, ev.presentedOperation)
          boots := (ev.operationBootEpoch, ev.nodeBootEpoch) } = true := by
      apply remoteJobMetaGate.complete
      refine ⟨by rw [hnodeEq]; exact hbPos, by rw [hpresEq]; exact hidPos,
        by rw [hbootEq, hnodeEq], .uncertain, by rw [hph2]; rfl, rfl, ?_⟩
      rcases hopOne with h6 | h7 | h8 | h9
      · exact ⟨.bindReconciledAccepted, by rw [h6]; rfl, by decide, rfl, hidPos, by rw [hpresEq]⟩
      · exact ⟨.reconcileSucceeded, by rw [h7]; rfl, by decide, rfl, hidPos, by rw [hpresEq]⟩
      · exact ⟨.reconcileFailed, by rw [h8]; rfl, by decide, rfl, hidPos, by rw [hpresEq]⟩
      · exact ⟨.reconcileCancelled, by rw [h9]; rfl, by decide, rfl, hidPos, by rw [hpresEq]⟩
    unfold stepJobSlice
    dsimp [remoteJobMetaGate] at hadm
    have hgate : (ev.operationBootEpoch == ev.nodeBootEpoch &&
        (s.phaseCode == 0 || ev.operationBootEpoch == s.operationBoot) &&
        verifyRemoteJobAdmit s.phaseCode ev.opCode s.operationId ev.presentedOperation
          ev.operationBootEpoch ev.nodeBootEpoch == 1) = true := by
      rw [hadm]; simp [hbootEq, hnodeEq]
    dsimp only
    rw [ite_eq_left_iff.mpr (fun h => absurd hgate h)]
  · rintro ⟨hph2, hid0, hboot0, hop10, hbootEq, hnodeEq, hlt⟩
    have hidPos : 0 < s.operationId.toNat := by
      have hne : s.operationId.toNat ≠ 0 := fun hz => hid0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hbPos : 0 < s.operationBoot.toNat := by
      have hne : s.operationBoot.toNat ≠ 0 := fun hz => hboot0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hltN := UInt64.lt_iff_toNat_lt.mp hlt
    have hpPos : 0 < ev.presentedOperation.toNat := Nat.lt_trans hidPos hltN
    have hadm : remoteJobMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          ops := (s.operationId, ev.presentedOperation)
          boots := (ev.operationBootEpoch, ev.nodeBootEpoch) } = true := by
      apply remoteJobMetaGate.complete
      exact ⟨by rw [hnodeEq]; exact hbPos, hpPos, by rw [hbootEq, hnodeEq],
        .uncertain, by rw [hph2]; rfl, rfl,
        .confirmNotDeliveredRetry, by rw [hop10]; rfl, by decide, rfl, hidPos, hltN⟩
    unfold stepJobSlice remoteJobTargetPhase
    dsimp [remoteJobMetaGate] at hadm
    have hgate : (ev.operationBootEpoch == ev.nodeBootEpoch &&
        (s.phaseCode == 0 || ev.operationBootEpoch == s.operationBoot) &&
        verifyRemoteJobAdmit s.phaseCode ev.opCode s.operationId ev.presentedOperation
          ev.operationBootEpoch ev.nodeBootEpoch == 1) = true := by
      rw [hadm]; simp [hbootEq, hnodeEq]
    dsimp only
    rw [ite_eq_left_iff.mpr (fun h => absurd hgate h)]
    simp [hop10]

/-! ## 4. `ProcessLiveness` (`SM-20`) -/

structure ProcAdmitCheck where
  codes : UInt8 × UInt8
  proc  : UInt8 × UInt8
  pids  : UInt32 × UInt32
  ticks : UInt64 × UInt64
  deriving Repr, DecidableEq

def ProcAdmitDomainSafe (c : ProcAdmitCheck) : Prop :=
  0 < c.pids.1.toNat ∧
  0 < c.ticks.1.toNat ∧
  ∃ ph, ProcPhase.decode? c.codes.1.toNat = some ph ∧ ph ≠ .dead ∧
    ∃ op, ProcOp.decode? c.codes.2.toNat = some op ∧
      match op with
      | .observeAlive =>
          (ph = .unknown ∨ ph = .alive) ∧
          c.proc.1.toNat = 0 ∧ c.proc.2.toNat = 0 ∧
          c.pids.2.toNat = c.pids.1.toNat ∧ c.ticks.2.toNat = c.ticks.1.toNat
      | .observeDead =>
          (ph = .unknown ∨ ph = .alive ∨ ph = .termSent ∨ ph = .killSent) ∧
          (c.proc.1.toNat = 1 ∨ c.proc.2.toNat = 1 ∨
           c.pids.2.toNat ≠ c.pids.1.toNat ∨ c.ticks.2.toNat ≠ c.ticks.1.toNat)
      | .sigterm =>
          ph = .alive ∧ c.proc.1.toNat = 0 ∧ c.proc.2.toNat = 0 ∧
          c.pids.2.toNat = c.pids.1.toNat ∧ c.ticks.2.toNat = c.ticks.1.toNat
      | .sigkill =>
          ph = .termSent ∧ c.proc.1.toNat = 0 ∧ c.proc.2.toNat = 0 ∧
          c.pids.2.toNat = c.pids.1.toNat ∧ c.ticks.2.toNat = c.ticks.1.toNat

private theorem procPhase_code_of_decode {x : UInt8} {ph : ProcPhase}
    (h : ProcPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [ProcPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | k5 <;>
        simp [ProcPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [ProcPhase.encode] using hcode

private theorem procOp_code_of_decode {x : UInt8} {op : ProcOp}
    (h : ProcOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [ProcOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | k4 <;>
        simp [ProcOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [ProcOp.encode] using hcode

def processLivenessMetaGate : MetaGateSpec ProcAdmitCheck ProcAdmitDomainSafe where
  gate c :=
    verifyProcLivenessAdmit
      c.codes.1 c.codes.2 c.proc.1 c.proc.2
      c.pids.1 c.pids.2 c.ticks.1 c.ticks.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨miss, zmb⟩, ⟨ePid, aPid⟩, ⟨eTk, aTk⟩⟩
    change (verifyProcLivenessAdmit phC opC miss zmb ePid aPid eTk aTk == 1) = true at h
    dsimp [ProcAdmitDomainSafe]
    unfold verifyProcLivenessAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨_, _⟩, hp0⟩, ht0⟩, hbr⟩
    have hpPos : 0 < ePid.toNat := by
      have hne : ePid.toNat ≠ 0 := fun hz => hp0 (u32_eq_of_toNat_eq ePid 0 hz)
      omega
    have htPos : 0 < eTk.toNat := by
      have hne : eTk.toNat ≠ 0 := fun hz => ht0 (u64_eq_of_toNat_eq eTk 0 hz)
      omega
    refine ⟨hpPos, htPos, ?_⟩
    rcases hbr with ((h0 | h1) | h2) | h3
    · rcases h0 with ⟨⟨⟨⟨⟨hop, hph⟩, hmiss⟩, hzmb⟩, hpeq⟩, hteq⟩
      subst hop hmiss hzmb hpeq hteq
      rcases hph with hph | hph <;> subst hph
      · exact ⟨.unknown, rfl, by decide, .observeAlive, rfl, Or.inl rfl, rfl, rfl, rfl, rfl⟩
      · exact ⟨.alive, rfl, by decide, .observeAlive, rfl, Or.inr rfl, rfl, rfl, rfl, rfl⟩
    · rcases h1 with ⟨⟨hop, hph⟩, hwhy⟩
      subst hop
      have hdead : miss.toNat = 1 ∨ zmb.toNat = 1 ∨ aPid.toNat ≠ ePid.toNat ∨ aTk.toNat ≠ eTk.toNat := by
        rcases hwhy with ((hm | hz) | hp) | ht
        · subst hm; exact Or.inl rfl
        · subst hz; exact Or.inr (Or.inl rfl)
        · exact Or.inr (Or.inr (Or.inl (fun h => hp (u32_eq_of_toNat_eq aPid ePid h))))
        · exact Or.inr (Or.inr (Or.inr (fun h => ht (u64_eq_of_toNat_eq aTk eTk h))))
      rcases hph with ((hph | hph) | hph) | hph <;> subst hph
      · exact ⟨.unknown, rfl, by decide, .observeDead, rfl, Or.inl rfl, hdead⟩
      · exact ⟨.alive, rfl, by decide, .observeDead, rfl, Or.inr (Or.inl rfl), hdead⟩
      · exact ⟨.termSent, rfl, by decide, .observeDead, rfl, Or.inr (Or.inr (Or.inl rfl)), hdead⟩
      · exact ⟨.killSent, rfl, by decide, .observeDead, rfl, Or.inr (Or.inr (Or.inr rfl)), hdead⟩
    · rcases h2 with ⟨⟨⟨⟨⟨hop, hph⟩, hmiss⟩, hzmb⟩, hpeq⟩, hteq⟩
      subst hop hph hmiss hzmb hpeq hteq
      exact ⟨.alive, rfl, by decide, .sigterm, rfl, rfl, rfl, rfl, rfl, rfl⟩
    · rcases h3 with ⟨⟨⟨⟨⟨hop, hph⟩, hmiss⟩, hzmb⟩, hpeq⟩, hteq⟩
      subst hop hph hmiss hzmb hpeq hteq
      exact ⟨.termSent, rfl, by decide, .sigkill, rfl, rfl, rfl, rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨miss, zmb⟩, ⟨ePid, aPid⟩, ⟨eTk, aTk⟩⟩
    change (verifyProcLivenessAdmit phC opC miss zmb ePid aPid eTk aTk == 1) = true
    dsimp [ProcAdmitDomainSafe] at h
    rcases h with ⟨hpPos, htPos, ph, hphDec, _, op, hopDec, hbr⟩
    have hpNe : (ePid != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hpPos
    have htNe : (eTk != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at htPos
    have hphC := procPhase_code_of_decode hphDec
    have hopC := procOp_code_of_decode hopDec
    subst hphC; subst hopC
    unfold verifyProcLivenessAdmit
    cases op with
    | observeAlive =>
      rcases hbr with ⟨hph, hm, hz, hpeq, hteq⟩
      have hm0 := u8_eq_of_toNat miss 0 (by omega) hm
      have hz0 := u8_eq_of_toNat zmb 0 (by omega) hz
      have hpB := u32_eq_of_toNat_eq aPid ePid hpeq
      have htB := u64_eq_of_toNat_eq aTk eTk hteq
      subst hm0 hz0 hpB htB
      rcases hph with rfl | rfl <;> simp [ProcPhase.encode, ProcOp.encode, hpNe, htNe]
    | observeDead =>
      rcases hbr with ⟨hph, hwhy⟩
      have hwB : (miss == 1 || zmb == 1 || aPid != ePid || aTk != eTk) = true := by
        rcases hwhy with hm | hz | hp | ht
        · have hm1 := u8_eq_of_toNat miss 1 (by omega) hm; subst hm1; simp
        · have hz1 := u8_eq_of_toNat zmb 1 (by omega) hz; subst hz1; simp
        · have hpN : (aPid != ePid) = true := by rw [bne_iff_ne]; intro heq; exact hp (by rw [heq])
          simp [hpN]
        · have htN : (aTk != eTk) = true := by rw [bne_iff_ne]; intro heq; exact ht (by rw [heq])
          simp [htN]
      rcases hph with rfl | rfl | rfl | rfl <;>
        simp [ProcPhase.encode, ProcOp.encode, hpNe, htNe, hwB]
    | sigterm =>
      rcases hbr with ⟨rfl, hm, hz, hpeq, hteq⟩
      have hm0 := u8_eq_of_toNat miss 0 (by omega) hm
      have hz0 := u8_eq_of_toNat zmb 0 (by omega) hz
      have hpB := u32_eq_of_toNat_eq aPid ePid hpeq
      have htB := u64_eq_of_toNat_eq aTk eTk hteq
      subst hm0 hz0 hpB htB
      simp [ProcPhase.encode, ProcOp.encode, hpNe, htNe]
    | sigkill =>
      rcases hbr with ⟨rfl, hm, hz, hpeq, hteq⟩
      have hm0 := u8_eq_of_toNat miss 0 (by omega) hm
      have hz0 := u8_eq_of_toNat zmb 0 (by omega) hz
      have hpB := u32_eq_of_toNat_eq aPid ePid hpeq
      have htB := u64_eq_of_toNat_eq aTk eTk hteq
      subst hm0 hz0 hpB htB
      simp [ProcPhase.encode, ProcOp.encode, hpNe, htNe]
  posWitness := { codes := (1, 2), proc := (0, 0), pids := (42, 42), ticks := (1000, 1000) }
  negWitness := { codes := (1, 2), proc := (0, 0), pids := (42, 42), ticks := (1000, 1001) }
  nonVacuous := by decide
  tight := by decide

def procSignalTicksClockDiscipline : ClockDiscipline ProcAdmitCheck where
  eval c :=
    if processLivenessMetaGate.gate c && (c.codes.2 == 2 || c.codes.2 == 3) then 1 else 0
  clockMask := 1
  guardOk c :=
    ((c.codes.2 == 2 && c.codes.1 == 1) || (c.codes.2 == 3 && c.codes.1 == 3)) &&
    c.proc.1 == 0 && c.proc.2 == 0 &&
    c.pids.1 != 0 && c.ticks.1 != 0 &&
    c.pids.2 == c.pids.1 && c.ticks.2 == c.ticks.1
  isolated c h := by
    have hg : processLivenessMetaGate.gate c = true ∧ (c.codes.2 == 2 || c.codes.2 == 3) = true := by
      by_cases h1 : processLivenessMetaGate.gate c = true
      · by_cases h2 : (c.codes.2 == 2 || c.codes.2 == 3) = true
        · exact ⟨h1, h2⟩
        · simp [h1, h2] at h
      · simp [h1] at h
    have hs := processLivenessMetaGate.sound c hg.1
    rcases c with ⟨⟨phC, opC⟩, ⟨miss, zmb⟩, ⟨ePid, aPid⟩, ⟨eTk, aTk⟩⟩
    rcases hs with ⟨hpPos, htPos, ph, hphDec, _, op, hopDec, hbr⟩
    have hpNe : (ePid != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hpPos
    have htNe : (eTk != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at htPos
    have hphC := procPhase_code_of_decode hphDec
    simp only [Bool.or_eq_true, beq_iff_eq] at hg
    rcases hg.2 with hop2 | hop3
    · have hop : op = .sigterm := by
        have hdec : ProcOp.decode? opC.toNat = some op := hopDec
        rw [hop2] at hdec; simp [ProcOp.decode?] at hdec; exact hdec.symm
      subst hop
      rcases hbr with ⟨rfl, hm, hz, hpeq, hteq⟩
      have hm0 := u8_eq_of_toNat miss 0 (by omega) hm
      have hz0 := u8_eq_of_toNat zmb 0 (by omega) hz
      have hpB := u32_eq_of_toNat_eq aPid ePid hpeq
      have htB := u64_eq_of_toNat_eq aTk eTk hteq
      subst hphC hm0 hz0 hpB htB hop2
      simp [ProcPhase.encode, hpNe, htNe]
    · have hop : op = .sigkill := by
        have hdec : ProcOp.decode? opC.toNat = some op := hopDec
        rw [hop3] at hdec; simp [ProcOp.decode?] at hdec; exact hdec.symm
      subst hop
      rcases hbr with ⟨rfl, hm, hz, hpeq, hteq⟩
      have hm0 := u8_eq_of_toNat miss 0 (by omega) hm
      have hz0 := u8_eq_of_toNat zmb 0 (by omega) hz
      have hpB := u32_eq_of_toNat_eq aPid ePid hpeq
      have htB := u64_eq_of_toNat_eq aTk eTk hteq
      subst hphC hm0 hz0 hpB htB hop3
      simp [ProcPhase.encode, hpNe, htNe]

def procDeadStickyFence : StickyFence ProcSliceState ProcSliceEvent where
  fenced s := s.phaseCode == 2
  preFenceAct s := s.phaseCode == 1 || s.phaseCode == 3 || s.phaseCode == 4
  step s ev := (stepProcSlice s ev).1
  sticky s ev hf := by
    have hph2 : s.phaseCode = 2 := by rwa [beq_iff_eq] at hf
    unfold stepProcSlice
    have hfalse : ¬ (verifyProcLivenessAdmit s.phaseCode ev.opCode ev.procMissing ev.isZombie
        s.leaderPid ev.actualPid s.leaderTicks ev.actualTicks == 1) = true := by
      intro hadm
      have hs := processLivenessMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } hadm
      rcases hs with ⟨_, _, ph, hphDec, hnd, _⟩
      rw [hph2] at hphDec
      simp [ProcPhase.decode?] at hphDec
      exact hnd hphDec.symm
    rw [ite_eq_right_iff.mpr (fun h => absurd h hfalse)]
    exact hf
  forbids_post s ev hf := by
    have hph2 : s.phaseCode = 2 := by rwa [beq_iff_eq] at hf
    unfold stepProcSlice
    have hfalse : ¬ (verifyProcLivenessAdmit s.phaseCode ev.opCode ev.procMissing ev.isZombie
        s.leaderPid ev.actualPid s.leaderTicks ev.actualTicks == 1) = true := by
      intro hadm
      have hs := processLivenessMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } hadm
      rcases hs with ⟨_, _, ph, hphDec, hnd, _⟩
      rw [hph2] at hphDec
      simp [ProcPhase.decode?] at hphDec
      exact hnd hphDec.symm
    rw [ite_eq_right_iff.mpr (fun h => absurd h hfalse)]
    simp [hph2]

/-- Process identity, `alive -> termSent -> killSent -> dead` escalation, and terminal `dead`:
    1. A mismatched `(pid, start_ticks)`, missing `/proc`, or zombie never confirms liveness or
       admits `SIGTERM`/`SIGKILL`.
    2. `SIGTERM` (`2`) is admitted only from `alive (1)` (landing in `termSent (3)`), and `SIGKILL`
       (`3`) only from `termSent (3)` (landing in `killSent (4)`), so duplicate `SIGTERM`/`SIGKILL`
       and `SIGKILL` before `SIGTERM` are rejected.
    3. `observeDead` (`1`) settles `termSent (3)` or `killSent (4)` to `dead (2)`, and `dead` is terminal. -/
theorem proc_mismatch_or_zombie_never_alive_or_signalled
    (s : ProcSliceState) (ev : ProcSliceEvent) :
    ((ev.actualPid ≠ s.leaderPid ∨ ev.actualTicks ≠ s.leaderTicks ∨
      ev.procMissing ≠ 0 ∨ ev.isZombie ≠ 0) ∧
     (ev.opCode = 0 ∨ ev.opCode = 2 ∨ ev.opCode = 3) →
       stepProcSlice s ev = (s, [])) ∧
    ((ev.opCode = 2 ∧ s.phaseCode ≠ 1) ∨ (ev.opCode = 3 ∧ s.phaseCode ≠ 3) →
       stepProcSlice s ev = (s, [])) ∧
    (s.phaseCode = 2 → stepProcSlice s ev = (s, [])) ∧
    (s.phaseCode = 1 ∧ s.leaderPid ≠ 0 ∧ s.leaderTicks ≠ 0 ∧
     ev.opCode = 2 ∧ ev.procMissing = 0 ∧ ev.isZombie = 0 ∧
     ev.actualPid = s.leaderPid ∧ ev.actualTicks = s.leaderTicks →
       (stepProcSlice s ev).1.phaseCode = 3) ∧
    (s.phaseCode = 3 ∧ s.leaderPid ≠ 0 ∧ s.leaderTicks ≠ 0 ∧
     ev.opCode = 3 ∧ ev.procMissing = 0 ∧ ev.isZombie = 0 ∧
     ev.actualPid = s.leaderPid ∧ ev.actualTicks = s.leaderTicks →
       (stepProcSlice s ev).1.phaseCode = 4) ∧
    ((s.phaseCode = 3 ∨ s.phaseCode = 4) ∧ s.leaderPid ≠ 0 ∧ s.leaderTicks ≠ 0 ∧
     ev.opCode = 1 ∧ ev.procMissing = 1 →
       (stepProcSlice s ev).1.phaseCode = 2) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · rintro ⟨hbad, hop⟩
    unfold stepProcSlice
    have hfalse : ¬ (verifyProcLivenessAdmit s.phaseCode ev.opCode ev.procMissing ev.isZombie
        s.leaderPid ev.actualPid s.leaderTicks ev.actualTicks == 1) = true := by
      intro hadm
      have hs := processLivenessMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } hadm
      rcases hs with ⟨_, _, _, _, _, op, hopDec, hbr⟩
      have checkEq : ev.procMissing.toNat = 0 ∧ ev.isZombie.toNat = 0 ∧
          ev.actualPid.toNat = s.leaderPid.toNat ∧ ev.actualTicks.toNat = s.leaderTicks.toNat := by
        rcases hop with h0 | h2 | h3
        · rw [h0] at hopDec
          simp [ProcOp.decode?] at hopDec
          subst hopDec
          exact hbr.2
        · rw [h2] at hopDec
          simp [ProcOp.decode?] at hopDec
          subst hopDec
          exact hbr.2
        · rw [h3] at hopDec
          simp [ProcOp.decode?] at hopDec
          subst hopDec
          exact hbr.2
      rcases checkEq with ⟨hm, hz, hpeq, hteq⟩
      rcases hbad with hp | ht | hmn | hzn
      · exact hp (u32_eq_of_toNat_eq _ _ hpeq)
      · exact ht (u64_eq_of_toNat_eq _ _ hteq)
      · exact hmn (u8_eq_of_toNat _ 0 (by omega) hm)
      · exact hzn (u8_eq_of_toNat _ 0 (by omega) hz)
    exact ite_eq_right_iff.mpr (fun h => absurd h hfalse)
  · intro hwrong
    unfold stepProcSlice
    have hfalse : ¬ (verifyProcLivenessAdmit s.phaseCode ev.opCode ev.procMissing ev.isZombie
        s.leaderPid ev.actualPid s.leaderTicks ev.actualTicks == 1) = true := by
      intro hadm
      have hs := processLivenessMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } hadm
      rcases hs with ⟨_, _, ph, hphDec, _, op, hopDec, hbr⟩
      have hphC := procPhase_code_of_decode hphDec
      rcases hwrong with ⟨hop2, hne1⟩ | ⟨hop3, hne3⟩
      · rw [hop2] at hopDec; simp [ProcOp.decode?] at hopDec; subst hopDec
        rcases hbr with ⟨rfl, _⟩
        exact hne1 hphC
      · rw [hop3] at hopDec; simp [ProcOp.decode?] at hopDec; subst hopDec
        rcases hbr with ⟨rfl, _⟩
        exact hne3 hphC
    exact ite_eq_right_iff.mpr (fun h => absurd h hfalse)
  · intro hdead
    unfold stepProcSlice
    have hfalse : ¬ (verifyProcLivenessAdmit s.phaseCode ev.opCode ev.procMissing ev.isZombie
        s.leaderPid ev.actualPid s.leaderTicks ev.actualTicks == 1) = true := by
      intro hadm
      have hs := processLivenessMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } hadm
      rcases hs with ⟨_, _, ph, hphDec, hnd, _⟩
      rw [hdead] at hphDec; simp [ProcPhase.decode?] at hphDec
      exact hnd hphDec.symm
    exact ite_eq_right_iff.mpr (fun h => absurd h hfalse)
  · rintro ⟨hph1, hp0, ht0, hop2, hm0, hz0, hpEq, htEq⟩
    have hpPos : 0 < s.leaderPid.toNat := by
      have hne : s.leaderPid.toNat ≠ 0 := fun hz => hp0 (u32_eq_of_toNat_eq _ 0 hz)
      omega
    have htPos : 0 < s.leaderTicks.toNat := by
      have hne : s.leaderTicks.toNat ≠ 0 := fun hz => ht0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : processLivenessMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } = true := by
      apply processLivenessMetaGate.complete
      have hphDec : ProcPhase.decode? s.phaseCode.toNat = some .alive := by
        rw [hph1]
        rfl
      have hopDec : ProcOp.decode? ev.opCode.toNat = some .sigterm := by
        rw [hop2]
        rfl
      have hmZ : ev.procMissing.toNat = 0 := by
        rw [hm0]
        rfl
      have hzZ : ev.isZombie.toNat = 0 := by
        rw [hz0]
        rfl
      exact ⟨hpPos, htPos, .alive, hphDec, by decide,
        .sigterm, hopDec, rfl, hmZ, hzZ,
        by rw [hpEq], by rw [htEq]⟩
    unfold stepProcSlice procLivenessTargetPhase
    dsimp [processLivenessMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop2]
  · rintro ⟨hph3, hp0, ht0, hop3, hm0, hz0, hpEq, htEq⟩
    have hpPos : 0 < s.leaderPid.toNat := by
      have hne : s.leaderPid.toNat ≠ 0 := fun hz => hp0 (u32_eq_of_toNat_eq _ 0 hz)
      omega
    have htPos : 0 < s.leaderTicks.toNat := by
      have hne : s.leaderTicks.toNat ≠ 0 := fun hz => ht0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : processLivenessMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } = true := by
      apply processLivenessMetaGate.complete
      have hphDec : ProcPhase.decode? s.phaseCode.toNat = some .termSent := by
        rw [hph3]
        rfl
      have hopDec : ProcOp.decode? ev.opCode.toNat = some .sigkill := by
        rw [hop3]
        rfl
      have hmZ : ev.procMissing.toNat = 0 := by
        rw [hm0]
        rfl
      have hzZ : ev.isZombie.toNat = 0 := by
        rw [hz0]
        rfl
      exact ⟨hpPos, htPos, .termSent, hphDec, by decide,
        .sigkill, hopDec, rfl, hmZ, hzZ,
        by rw [hpEq], by rw [htEq]⟩
    unfold stepProcSlice procLivenessTargetPhase
    dsimp [processLivenessMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop3]
  · rintro ⟨hph34, hp0, ht0, hop1, hm1⟩
    have hpPos : 0 < s.leaderPid.toNat := by
      have hne : s.leaderPid.toNat ≠ 0 := fun hz => hp0 (u32_eq_of_toNat_eq _ 0 hz)
      omega
    have htPos : 0 < s.leaderTicks.toNat := by
      have hne : s.leaderTicks.toNat ≠ 0 := fun hz => ht0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : processLivenessMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          proc := (ev.procMissing, ev.isZombie)
          pids := (s.leaderPid, ev.actualPid)
          ticks := (s.leaderTicks, ev.actualTicks) } = true := by
      apply processLivenessMetaGate.complete
      rcases hph34 with h3 | h4
      · exact ⟨hpPos, htPos, .termSent, by rw [h3]; rfl, by decide,
          .observeDead, by rw [hop1]; rfl, Or.inr (Or.inr (Or.inl rfl)),
          Or.inl (by rw [hm1]; rfl)⟩
      · exact ⟨hpPos, htPos, .killSent, by rw [h4]; rfl, by decide,
          .observeDead, by rw [hop1]; rfl, Or.inr (Or.inr (Or.inr rfl)),
          Or.inl (by rw [hm1]; rfl)⟩
    unfold stepProcSlice procLivenessTargetPhase
    dsimp [processLivenessMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop1]

/-! ## 5. `RelayCommand` (`SM-19`) -/

structure RelayAdmitCheck where
  codes  : UInt8 × UInt8
  leases : UInt64 × UInt64
  boots  : UInt64 × UInt64
  deriving Repr, DecidableEq

def RelayAdmitDomainSafe (c : RelayAdmitCheck) : Prop :=
  0 < c.boots.1.toNat ∧
  c.boots.2.toNat = c.boots.1.toNat ∧
  0 < c.leases.2.toNat ∧
  ∃ ph, RelayPhase.decode? c.codes.1.toNat = some ph ∧ ph.isRetired = false ∧
    ∃ op, RelayOp.decode? c.codes.2.toNat = some op ∧ op ≠ .retry ∧
      match op with
      | .lease => ph = .pending ∧ c.leases.1.toNat = 0
      | .ack => ph = .leased ∧ 0 < c.leases.1.toNat ∧ c.leases.2.toNat = c.leases.1.toNat
      | .markUncertain => ph = .leased ∧ 0 < c.leases.1.toNat ∧ c.leases.2.toNat = c.leases.1.toNat
      | .reconcile => ph = .uncertain ∧ 0 < c.leases.1.toNat ∧ c.leases.2.toNat = c.leases.1.toNat
      | .retry => False

private theorem relayPhase_code_of_decode {x : UInt8} {ph : RelayPhase}
    (h : RelayPhase.decode? x.toNat = some ph) : x = ph.encode := by
  have hcode : x = UInt8.ofNat ph.encode.toNat := by
    refine u8_eq_of_toNat x ph.encode.toNat (by cases ph <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [RelayPhase.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | k4 <;>
        simp [RelayPhase.decode?, hn] at h <;> subst h <;> rfl
  cases ph <;> simpa [RelayPhase.encode] using hcode

private theorem relayOp_code_of_decode {x : UInt8} {op : RelayOp}
    (h : RelayOp.decode? x.toNat = some op) : x = op.encode := by
  have hcode : x = UInt8.ofNat op.encode.toNat := by
    refine u8_eq_of_toNat x op.encode.toNat (by cases op <;> decide) ?_
    cases hn : x.toNat with
    | zero => simp [RelayOp.decode?, hn] at h; subst h; rfl
    | succ k =>
      rcases k with _ | _ | _ | _ | k5 <;>
        simp [RelayOp.decode?, hn] at h <;> subst h <;> rfl
  cases op <;> simpa [RelayOp.encode] using hcode

def relayCommandMetaGate : MetaGateSpec RelayAdmitCheck RelayAdmitDomainSafe where
  gate c :=
    verifyRelayCommandAdmit c.codes.1 c.codes.2 c.leases.1 c.leases.2 c.boots.1 c.boots.2 == 1
  sound c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨hLease, pLease⟩, ⟨lBoot, pBoot⟩⟩
    change (verifyRelayCommandAdmit phC opC hLease pLease lBoot pBoot == 1) = true at h
    dsimp [RelayAdmitDomainSafe]
    unfold verifyRelayCommandAdmit at h
    have hc := bit_cond_true h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨_, _⟩, hb0⟩, hbEq⟩, hp0⟩, hbr⟩
    have hbPos : 0 < lBoot.toNat := by
      have hne : lBoot.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq lBoot 0 hz)
      omega
    have hpPos : 0 < pLease.toNat := by
      have hne : pLease.toNat ≠ 0 := fun hz => hp0 (u64_eq_of_toNat_eq pLease 0 hz)
      omega
    refine ⟨hbPos, by rw [hbEq], hpPos, ?_⟩
    rcases hbr with ((h0 | h1) | h2) | h3
    · rcases h0 with ⟨⟨hop, hph⟩, hh0⟩
      subst hop; subst hph; subst hh0
      exact ⟨.pending, rfl, rfl, .lease, rfl, by decide, rfl, rfl⟩
    · rcases h1 with ⟨⟨⟨hop, hph⟩, hh0⟩, heq⟩; subst hop; subst hph
      have hhPos : 0 < hLease.toNat := by
        have hne : hLease.toNat ≠ 0 := fun hz => hh0 (u64_eq_of_toNat_eq hLease 0 hz)
        omega
      exact ⟨.leased, rfl, rfl, .ack, rfl, by decide, rfl, hhPos, by rw [heq]⟩
    · rcases h2 with ⟨⟨⟨hop, hph⟩, hh0⟩, heq⟩; subst hop; subst hph
      have hhPos : 0 < hLease.toNat := by
        have hne : hLease.toNat ≠ 0 := fun hz => hh0 (u64_eq_of_toNat_eq hLease 0 hz)
        omega
      exact ⟨.leased, rfl, rfl, .markUncertain, rfl, by decide, rfl, hhPos, by rw [heq]⟩
    · rcases h3 with ⟨⟨⟨hop, hph⟩, hh0⟩, heq⟩; subst hop; subst hph
      have hhPos : 0 < hLease.toNat := by
        have hne : hLease.toNat ≠ 0 := fun hz => hh0 (u64_eq_of_toNat_eq hLease 0 hz)
        omega
      exact ⟨.uncertain, rfl, rfl, .reconcile, rfl, by decide, rfl, hhPos, by rw [heq]⟩
  complete c h := by
    rcases c with ⟨⟨phC, opC⟩, ⟨hLease, pLease⟩, ⟨lBoot, pBoot⟩⟩
    change (verifyRelayCommandAdmit phC opC hLease pLease lBoot pBoot == 1) = true
    dsimp [RelayAdmitDomainSafe] at h
    rcases h with ⟨hbPos, hbEq, hpPos, ph, hphDec, _, op, hopDec, _, hbr⟩
    have hbNe : (lBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hbPos
    have hpNe : (pLease != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hpPos
    have hbEqB := u64_eq_of_toNat_eq pBoot lBoot hbEq
    have hphC := relayPhase_code_of_decode hphDec
    have hopC := relayOp_code_of_decode hopDec
    subst hbEqB; subst hphC; subst hopC
    unfold verifyRelayCommandAdmit
    cases op with
    | lease =>
      rcases hbr with ⟨rfl, hh0⟩
      have hhEq := u64_eq_of_toNat_eq hLease 0 hh0
      subst hhEq; simp [RelayPhase.encode, RelayOp.encode, hbNe, hpNe]
    | ack =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pLease hLease heq
      subst heqB; simp [RelayPhase.encode, RelayOp.encode, hbNe, hpNe]
    | markUncertain =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pLease hLease heq
      subst heqB; simp [RelayPhase.encode, RelayOp.encode, hbNe, hpNe]
    | reconcile =>
      rcases hbr with ⟨rfl, _, heq⟩
      have heqB := u64_eq_of_toNat_eq pLease hLease heq
      subst heqB; simp [RelayPhase.encode, RelayOp.encode, hbNe, hpNe]
    | retry => exact False.elim hbr
  posWitness := { codes := (1, 1), leases := (11, 11), boots := (4, 4) }
  negWitness := { codes := (3, 0), leases := (11, 12), boots := (4, 4) }
  nonVacuous := by decide
  tight := by decide

private theorem relay_accepted_step_id (s : RelaySliceState) (ev : RelaySliceEvent)
    (ha : (s.phaseCode == 2) = true) :
    stepRelaySlice s ev = (s, []) := by
  unfold stepRelaySlice
  have hfalse : ¬ (verifyRelayCommandAdmit s.phaseCode ev.opCode
      s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
    intro hadm
    have hs := relayCommandMetaGate.sound
      { codes := (s.phaseCode, ev.opCode)
        leases := (s.heldLeaseId, ev.presentedLeaseId)
        boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
    rcases hs with ⟨_, _, _, ph, hphDec, hnr, _⟩
    have hpc := relayPhase_code_of_decode hphDec
    have hs2 : s.phaseCode = 2 := by rwa [beq_iff_eq] at ha
    rw [hs2] at hpc
    cases ph <;> simp [RelayPhase.encode] at hpc <;> simp [RelayPhase.isRetired] at hnr
  by_cases h1 : (verifyRelayCommandAdmit s.phaseCode ev.opCode
      s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true
  · exact absurd h1 hfalse
  · simp [h1]

/-- Once a relay command enters `Accepted (2)` or `Uncertain (3)`, it never returns to `Pending (0)`
    or `Leased (1)` (`StickyFence`), forbidding fresh replay/lease after uncertain or accepted delivery. -/
def relayUncertainOrAcceptedStickyFence : StickyFence RelaySliceState RelaySliceEvent where
  fenced s := s.phaseCode == 2 || s.phaseCode == 3
  preFenceAct s := s.phaseCode == 0 || s.phaseCode == 1
  step s ev := (stepRelaySlice s ev).1
  sticky s ev hf := by
    simp only [Bool.or_eq_true] at hf
    rcases hf with h2 | h3
    · rw [relay_accepted_step_id s ev h2, h2]; rfl
    · unfold stepRelaySlice relayCommandTargetPhase
      by_cases hadm : (verifyRelayCommandAdmit s.phaseCode ev.opCode
          s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true
      · have hs := relayCommandMetaGate.sound
          { codes := (s.phaseCode, ev.opCode)
            leases := (s.heldLeaseId, ev.presentedLeaseId)
            boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
        rcases hs with ⟨_, _, _, ph, hphDec, _, op, hopDec, _, hbr⟩
        have hs3 : s.phaseCode = 3 := by rwa [beq_iff_eq] at h3
        rw [hs3] at hphDec; simp [RelayPhase.decode?] at hphDec; subst hphDec
        have hop3 : ev.opCode = 3 := by
          have hopC := relayOp_code_of_decode hopDec
          cases op <;> simp [RelayOp.encode] at hbr hopC <;> exact hopC
        rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
        simp [hop3]
      · rw [ite_eq_right_iff.mpr (fun h => absurd h hadm), h3]; simp
  forbids_post s ev hf := by
    have hst : ((stepRelaySlice s ev).1.phaseCode == 2 || (stepRelaySlice s ev).1.phaseCode == 3) = true := by
      simp only [Bool.or_eq_true] at hf
      rcases hf with h2 | h3
      · rw [relay_accepted_step_id s ev h2, h2]; rfl
      · unfold stepRelaySlice relayCommandTargetPhase
        by_cases hadm : (verifyRelayCommandAdmit s.phaseCode ev.opCode
            s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true
        · have hs := relayCommandMetaGate.sound
            { codes := (s.phaseCode, ev.opCode)
              leases := (s.heldLeaseId, ev.presentedLeaseId)
              boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
          rcases hs with ⟨_, _, _, ph, hphDec, _, op, hopDec, _, hbr⟩
          have hs3 : s.phaseCode = 3 := by rwa [beq_iff_eq] at h3
          rw [hs3] at hphDec; simp [RelayPhase.decode?] at hphDec; subst hphDec
          have hop3 : ev.opCode = 3 := by
            have hopC := relayOp_code_of_decode hopDec
            cases op <;> simp [RelayOp.encode] at hbr hopC <;> exact hopC
          rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
          simp [hop3]
        · rw [ite_eq_right_iff.mpr (fun h => absurd h hadm), h3]; simp
    simp only [Bool.or_eq_true, beq_iff_eq] at hst
    rcases hst with hp2 | hp3
    · simp [hp2]
    · simp [hp3]

def relayBootScopedAuthority : ScopedAuthority RelayAdmitCheck where
  admit := relayCommandMetaGate.gate
  scopeValid c := c.boots.1 != 0 && c.boots.2 == c.boots.1 && c.leases.2 != 0
  sound c h := by
    have hs := relayCommandMetaGate.sound c h
    rcases c with ⟨_, ⟨_, pLease⟩, ⟨lBoot, pBoot⟩⟩
    rcases hs with ⟨hbPos, hbEq, hpPos, _⟩
    have hbNe : (lBoot != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hbPos
    have hpNe : (pLease != 0) = true := by
      rw [bne_iff_ne]; intro hz
      subst hz; simp at hpPos
    have hbEqB := u64_eq_of_toNat_eq pBoot lBoot hbEq
    subst hbEqB; simp [hbNe, hpNe]

def relayAcceptedReplayIdempotence : ReplayIdempotence RelaySliceState RelaySliceEvent RelayEffect where
  step := stepRelaySlice
  alreadyAcked s _ := s.phaseCode == 2
  idempotent s ev hf := relay_accepted_step_id s ev hf

/-- `RelayCommand` (`SM-19`) leased-delivery, no-pop-before-ack, sticky-uncertain, and stale-boot invariants:
    1. Leased delivery (`lease`, `opCode = 0`) transitions `Pending (0) -> Leased (1)` with
       `retired = 0` (the command is retained, never popped before guest ack).
    2. Explicit guest `ack` (`opCode = 1`) with matching lease & boot epoch transitions
       `Leased (1) -> Accepted (2)` and sets `retired = 1`.
    3. From `Uncertain (3)`, every fresh `lease` (`0`), `ack` (`1`), `markUncertain` (`2`), or
       `retry` (`4`) is rejected (`stepRelaySlice s ev = (s, [])`); only explicit `reconcile` (`3`)
       with matching lease & boot epoch settles to `Accepted (2)` (`retired = 1`).
    4. Stale or mismatched boot epochs (`presentedBootEpoch ≠ nodeBootEpoch` or `nodeBootEpoch = 0`)
       never mutate the relay slice. -/
theorem relay_no_pop_before_ack_uncertain_reconcile_only_and_boot_fenced
    (s : RelaySliceState) (ev : RelaySliceEvent) :
    (s.phaseCode = 0 ∧ s.heldLeaseId = 0 ∧ s.nodeBootEpoch ≠ 0 ∧
     ev.opCode = 0 ∧ ev.presentedLeaseId ≠ 0 ∧ ev.presentedBootEpoch = s.nodeBootEpoch →
       (stepRelaySlice s ev).1.phaseCode = 1 ∧ (stepRelaySlice s ev).1.retired = 0) ∧
    (s.phaseCode = 1 ∧ s.heldLeaseId ≠ 0 ∧ s.nodeBootEpoch ≠ 0 ∧
     ev.opCode = 1 ∧ ev.presentedLeaseId = s.heldLeaseId ∧ ev.presentedBootEpoch = s.nodeBootEpoch →
       (stepRelaySlice s ev).1.phaseCode = 2 ∧ (stepRelaySlice s ev).1.retired = 1) ∧
    (s.phaseCode = 3 ∧ ev.opCode ≠ 3 → stepRelaySlice s ev = (s, [])) ∧
    ((s.nodeBootEpoch = 0 ∨ ev.presentedBootEpoch ≠ s.nodeBootEpoch) →
       stepRelaySlice s ev = (s, [])) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · rintro ⟨hph0, hhl0, hb0, hop0, hpl0, hbEq⟩
    have hbPos : 0 < s.nodeBootEpoch.toNat := by
      have hne : s.nodeBootEpoch.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hpPos : 0 < ev.presentedLeaseId.toNat := by
      have hne : ev.presentedLeaseId.toNat ≠ 0 := fun hz => hpl0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : relayCommandMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          leases := (s.heldLeaseId, ev.presentedLeaseId)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } = true := by
      apply relayCommandMetaGate.complete
      exact ⟨hbPos, by rw [hbEq], hpPos, .pending, by rw [hph0]; rfl, rfl,
        .lease, by rw [hop0]; rfl, by decide, rfl, by rw [hhl0]; rfl⟩
    unfold stepRelaySlice relayCommandTargetPhase relayPhaseRetired
    dsimp [relayCommandMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop0]
  · rintro ⟨hph1, hhl0, hb0, hop1, hplEq, hbEq⟩
    have hbPos : 0 < s.nodeBootEpoch.toNat := by
      have hne : s.nodeBootEpoch.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hhPos : 0 < s.heldLeaseId.toNat := by
      have hne : s.heldLeaseId.toNat ≠ 0 := fun hz => hhl0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hadm : relayCommandMetaGate.gate
        { codes := (s.phaseCode, ev.opCode)
          leases := (s.heldLeaseId, ev.presentedLeaseId)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } = true := by
      apply relayCommandMetaGate.complete
      exact ⟨hbPos, by rw [hbEq], by rw [hplEq]; exact hhPos,
        .leased, by rw [hph1]; rfl, rfl, .ack, by rw [hop1]; rfl, by decide,
        rfl, hhPos, by rw [hplEq]⟩
    unfold stepRelaySlice relayCommandTargetPhase relayPhaseRetired
    dsimp [relayCommandMetaGate] at hadm
    rw [ite_eq_left_iff.mpr (fun h => absurd hadm h)]
    simp [hop1]
  · rintro ⟨hph3, hne3⟩
    unfold stepRelaySlice
    have hfalse : ¬ (verifyRelayCommandAdmit s.phaseCode ev.opCode
        s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
      intro hadm
      have hs := relayCommandMetaGate.sound
        { codes := (s.phaseCode, ev.opCode)
          leases := (s.heldLeaseId, ev.presentedLeaseId)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
      rcases hs with ⟨_, _, _, ph, hphDec, _, op, hopDec, _, hbr⟩
      rw [hph3] at hphDec; simp [RelayPhase.decode?] at hphDec; subst hphDec
      have hopC := relayOp_code_of_decode hopDec
      cases op <;> simp [RelayOp.encode] at hbr hopC <;> exact hne3 hopC
    by_cases h1 : (verifyRelayCommandAdmit s.phaseCode ev.opCode
        s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true
    · exact absurd h1 hfalse
    · simp [h1]
  · intro hbad
    unfold stepRelaySlice
    have hfalse : ¬ (verifyRelayCommandAdmit s.phaseCode ev.opCode
        s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true := by
      intro hadm
      have hsc := relayBootScopedAuthority.sound
        { codes := (s.phaseCode, ev.opCode)
          leases := (s.heldLeaseId, ev.presentedLeaseId)
          boots := (s.nodeBootEpoch, ev.presentedBootEpoch) } hadm
      dsimp [relayBootScopedAuthority] at hsc
      simp only [Bool.and_eq_true, bne_iff_ne, beq_iff_eq] at hsc
      rcases hbad with hbz | hbne
      · exact hsc.1.1 hbz
      · exact hbne hsc.1.2
    by_cases h1 : (verifyRelayCommandAdmit s.phaseCode ev.opCode
        s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1) = true
    · exact absurd h1 hfalse
    · simp [h1]

/-! ## 6. Kernel C-ABI Gate Refinement Bridges (`plan.md:316`) -/

/-- `verifyVmLifecycleAdmit` (`destroy`) refines `Orb.Kernel.vmLifecycleStep` (`orb_vm_lifecycle_step`):
    whenever R5-A admits `destroy` (`opCode = 4`), `nowEpoch >= deletableAt` and `idleElapsed = 1`
    with `ownerLive = 0`, so `minDeletePending` (`decide (nowEpoch < deletableAt)`) is `0` and
    `vmLifecycleStep 3 0 ttlExpired idleElapsed workEn freeStop minDeletePending` emits `259` (`destroy`).
    Conversely, whenever `nowEpoch < deletableAt`, `vmLifecycleStep` never emits action `3` (`destroy`)
    and `verifyVmLifecycleAdmit` rejects `destroy`. -/
theorem r5_vm_destroy_refines_kernel_vmLifecycleStep
    (phaseCode ownerLive idleElapsed ttlExpired workEn freeStop : UInt8)
    (lBoot pBoot nowEp delAt : UInt64) :
    (verifyVmLifecycleAdmit phaseCode 4 ownerLive idleElapsed lBoot pBoot nowEp delAt = 1 →
      vmLifecycleStep 3 ownerLive ttlExpired idleElapsed workEn freeStop
        (if nowEp < delAt then 1 else 0) = 259) ∧
    (nowEp < delAt →
      verifyVmLifecycleAdmit phaseCode 4 ownerLive idleElapsed lBoot pBoot nowEp delAt = 0 ∧
      (vmLifecycleStep 3 ownerLive ttlExpired idleElapsed workEn freeStop
        (if nowEp < delAt then 1 else 0) &&& 0xFF) ≠ 3) := by
  constructor
  · intro hadm
    have hadmB : (verifyVmLifecycleAdmit phaseCode 4 ownerLive idleElapsed lBoot pBoot nowEp delAt == 1) = true := by
      simpa using hadm
    have hs := vmLifecycleMetaGate.sound
      { codes := (phaseCode, 4), guards := (ownerLive, idleElapsed),
        boots := (lBoot, pBoot), clocks := (nowEp, delAt) } hadmB
    dsimp [VmAdmitDomainSafe] at hs
    rcases hs with ⟨_, _, _, _, op, hopDec, hbr⟩
    simp [VmOp.decode?] at hopDec; subst hopDec
    rcases hbr with ⟨_, _, hown, hidle, hle⟩
    have hown0 := u8_eq_of_toNat ownerLive 0 (by omega) hown
    have hidle1 := u8_eq_of_toNat idleElapsed 1 (by omega) hidle
    have hpend : (if nowEp < delAt then (1 : UInt8) else 0) = 0 :=
      ite_eq_right_iff.mpr fun hlt => by
        have hltN := UInt64.lt_iff_toNat_lt.mp hlt
        omega
    subst hown0; subst hidle1
    rw [hpend]
    unfold vmLifecycleStep
    by_cases httl : (ttlExpired == 1) = true <;> simp [httl]
  · intro hlt
    constructor
    · have hnotLe : ¬ delAt ≤ nowEp := by
        intro hle
        have hltN := UInt64.lt_iff_toNat_lt.mp hlt
        have hleN := UInt64.le_iff_toNat_le.mp hle
        omega
      simp [verifyVmLifecycleAdmit, hnotLe]
    · have hpend : (if nowEp < delAt then (1 : UInt8) else 0) = 1 :=
        ite_eq_left_iff.mpr (fun h => absurd hlt h)
      rw [hpend]
      unfold vmLifecycleStep
      by_cases httl : (ttlExpired == 1) = true
      · simp [httl]; decide
      · by_cases hown : (ownerLive == 1) = true
        · simp [httl, hown]
        · by_cases hidle : (idleElapsed == 0) = true
          · simp [httl, hown, hidle]; decide
          · simp [httl, hown, hidle]; decide

 /-- `verifyVmClaimAdmit` (`claim` / `reclaim`) refines `Orb.Kernel.vmClaimStep` (`orb_vm_claim_step`)
    in both directions for the live same-tenant case (`sameTenant = 1`):
    - an admitted `claim` (`0`) or `reclaim` (`2`) forces `vmLive = 1`, `activeComputeEligible = 1`,
      and `ownerInLineage = 1`, so `vmClaimStep vmLive 1 ownerNone ownerInLineage = 257`;
    - conversely, `vmClaimStep vmLive 1 ownerNone inLin = 257` with a live matching boot and a fresh
      reservation admits `claim` from `unowned` (`ownerNone = 1`) and `reclaim` from `released`
      (`ownerNone = 0`). A stale `presentedBootEpoch` is rejected even when the kernel would admit. -/
theorem r5_vm_claim_refines_kernel_vmClaimStep
    (phaseCode opCode inLin sup vmLive elig ownerNone : UInt8)
    (hRes pRes nBoot pBoot : UInt64)
    (hop : opCode = 0 ∨ opCode = 2) :
    (verifyVmClaimAdmit phaseCode opCode inLin sup vmLive elig hRes pRes nBoot pBoot = 1 →
      elig = 1 ∧ vmLive = 1 ∧ inLin = 1 ∧
      vmClaimStep vmLive 1 ownerNone inLin = 257) ∧
    (vmClaimStep vmLive 1 ownerNone inLin = 257 ∧
     vmLive = 1 ∧ elig = 1 ∧ inLin = 1 ∧ sup = 0 ∧
     nBoot ≠ 0 ∧ pBoot = nBoot ∧ pRes ≠ 0 ∧ hRes < pRes →
      (ownerNone = 1 ∧ phaseCode = 0 →
        verifyVmClaimAdmit phaseCode 0 inLin sup vmLive elig hRes pRes nBoot pBoot = 1) ∧
      (ownerNone = 0 ∧ phaseCode = 2 →
        verifyVmClaimAdmit phaseCode 2 inLin sup vmLive elig hRes pRes nBoot pBoot = 1)) ∧
    (pBoot ≠ nBoot →
      verifyVmClaimAdmit phaseCode opCode inLin sup vmLive elig hRes pRes nBoot pBoot = 0) := by
  refine ⟨?_, ?_, ?_⟩
  · intro hadm
    have hadmB : (verifyVmClaimAdmit phaseCode opCode inLin sup vmLive elig hRes pRes nBoot pBoot == 1) = true := by
      simpa using hadm
    have hsc := vmClaimScopedAuthority.sound
      { codes := (phaseCode, opCode)
        lineageFlags := (inLin, sup)
        vmFlags := (vmLive, elig)
        reservations := (hRes, pRes)
        boots := (nBoot, pBoot) } hadmB
    dsimp [vmClaimScopedAuthority] at hsc
    simp only [Bool.and_eq_true, Bool.or_eq_true, bne_iff_ne, beq_iff_eq] at hsc
    rcases hsc with ⟨⟨⟨⟨hlin, _⟩, _⟩, _⟩, ⟨hop1, _⟩ | ⟨hv1, he1⟩⟩
    · rcases hop with o0 | o2
      · rw [o0] at hop1; simp at hop1
      · rw [o2] at hop1; simp at hop1
    · subst hlin; subst hv1; subst he1
      refine ⟨rfl, rfl, rfl, ?_⟩
      unfold vmClaimStep
      cases ownerNone == 1 <;> rfl
  · rintro ⟨_, hv1, he1, hlin, hsup, hb0, hbEq, hp0, hlt⟩
    have hbNe : (nBoot != 0) = true := bne_iff_ne.mpr hb0
    have hpNe : (pRes != 0) = true := bne_iff_ne.mpr hp0
    refine ⟨?_, ?_⟩
    · intro ⟨hown, hph⟩
      unfold verifyVmClaimAdmit
      rw [hph, hv1, he1, hlin, hsup, hbEq]
      simp [hbNe, hpNe, hlt]
    · intro ⟨hown, hph⟩
      unfold verifyVmClaimAdmit
      rw [hph, hv1, he1, hlin, hsup, hbEq]
      simp [hbNe, hpNe, hlt]
  · intro hne
    have hneB : (pBoot == nBoot) = false := beq_eq_false_iff_ne.mpr hne
    simp [verifyVmClaimAdmit, hneB]

/-- `RemoteJobLedger` refines `Orb.Kernel.verifyRemoteOutbox`, `Orb.Kernel.jobLedgerStep`, and
    `Orb.Kernel.effectOutboxStep`:
    1. A fresh `accept` (`opCode = 0`, `phaseCode = 0`, `held = 0`) on a live boot is exactly the
       outbox enqueue of a new ready unsuperseded session:
       `verifyRemoteJobAdmit 0 0 0 presented boot boot = 1 ↔ presented ≠ 0 ∧ boot ≠ 0`,
       and that enqueue satisfies `verifyRemoteOutbox 0 0 1 0 0 1 0 0 0 = 1`.
    2. `uncertain (2)` is the ambiguous-tentative fence and a terminal phase (`3..5`) is the
       newer-terminal fence: `jobLedgerStep` drops the older wait handle (`bit 0 = 0`) exactly then,
       and keeps it only while the ledger is still `accepted (1)`.
    3. A blind `retry` (`opCode = 5`) from `uncertain` is the effect-outbox fresh retry
       (`Claim`/`Accept` while `phase = 4`), rejected by both gates; explicit `reconcile`
       (`opCode = 7`) is the effect-outbox `Reconcile` (`op = 5`) and both advance. -/
theorem r5_remote_job_refines_kernel_outbox_and_ledger_gates
    (presented boot : UInt64) (isAcc expectsCont : UInt8) :
    ((verifyRemoteJobAdmit 0 0 0 presented boot boot = 1) ↔
      (presented ≠ 0 ∧ boot ≠ 0)) ∧
    (verifyRemoteJobAdmit 0 0 0 presented boot boot = 1 →
      verifyRemoteOutbox 0 0 1 0 0 1 0 0 0 = 1) ∧
    ((jobLedgerStep isAcc expectsCont (if 3 ≤ (2 : UInt8) then 1 else 0)
        (if (2 : UInt8) = 2 then 1 else 0) &&& 1) = 0) ∧
    ((isAcc = 1 ∧ expectsCont = 1) ↔ (jobLedgerStep isAcc expectsCont 0 0 &&& 1) = 1) ∧
    (boot ≠ 0 →
      verifyRemoteJobAdmit 2 5 presented presented boot boot = 0 ∧
      (effectOutboxStep 4 0 1 1 boot boot &&& 0xFF) = 3) ∧
    (presented ≠ 0 ∧ boot ≠ 0 →
      verifyRemoteJobAdmit 2 7 presented presented boot boot = 1 ∧
      (effectOutboxStep 4 0 5 1 boot boot &&& 0xFF) = 1) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · constructor
    · intro hadm
      have hadmB : (verifyRemoteJobAdmit 0 0 0 presented boot boot == 1) = true := by simpa using hadm
      have hs := remoteJobMetaGate.sound
        { codes := (0, 0), ops := (0, presented), boots := (boot, boot) } hadmB
      dsimp [JobAdmitDomainSafe] at hs
      rcases hs with ⟨hbPos, hpPos, _⟩
      refine ⟨?_, ?_⟩
      · intro hz; simp [hz] at hpPos
      · intro hz; simp [hz] at hbPos
    · rintro ⟨hp0, hb0⟩
      have hbPos : 0 < boot.toNat := by
        have hne : boot.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
        omega
      have hpPos : 0 < presented.toNat := by
        have hne : presented.toNat ≠ 0 := fun hz => hp0 (u64_eq_of_toNat_eq _ 0 hz)
        omega
      have hadm : remoteJobMetaGate.gate
          { codes := (0, 0), ops := (0, presented), boots := (boot, boot) } = true := by
        apply remoteJobMetaGate.complete
        exact ⟨hbPos, hpPos, rfl, .absent, rfl, rfl, .accept, rfl, by decide, rfl, rfl⟩
      simpa [remoteJobMetaGate] using hadm
  · intro _
    exact rfl
  · unfold jobLedgerStep
    have hcond : (if 3 ≤ (2 : UInt8) then (1 : UInt8) else 0) = 0 := by decide
    have htent : (if (2 : UInt8) = 2 then (1 : UInt8) else 0) = 1 := by decide
    rw [hcond, htent]
    by_cases hc : (isAcc == 1 && expectsCont == 1) = true
    · simp [hc]; decide
    · simp [hc]; decide
  · constructor
    · rintro ⟨ha, he⟩
      unfold jobLedgerStep
      subst ha; subst he
      decide
    · intro hbit
      unfold jobLedgerStep at hbit
      by_cases hc : (isAcc == 1 && expectsCont == 1) = true
      · simp only [Bool.and_eq_true, beq_iff_eq] at hc
        exact hc
      · simp [hc] at hbit
  · intro hb0
    refine ⟨?_, ?_⟩
    · simp [verifyRemoteJobAdmit]
    · unfold effectOutboxStep
      have hbNe : (boot != 0) = true := bne_iff_ne.mpr hb0
      simp [hbNe]
      decide
  · rintro ⟨hp0, hb0⟩
    have hbPos : 0 < boot.toNat := by
      have hne : boot.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    have hpPos : 0 < presented.toNat := by
      have hne : presented.toNat ≠ 0 := fun hz => hp0 (u64_eq_of_toNat_eq _ 0 hz)
      omega
    refine ⟨?_, ?_⟩
    · have hadm : remoteJobMetaGate.gate
          { codes := (2, 7), ops := (presented, presented), boots := (boot, boot) } = true := by
        apply remoteJobMetaGate.complete
        exact ⟨hbPos, hpPos, rfl, .uncertain, rfl, rfl, .reconcileSucceeded, rfl, by decide, rfl, hpPos, rfl⟩
      simpa [remoteJobMetaGate] using hadm
    · unfold effectOutboxStep
      have hbNe : (boot != 0) = true := bne_iff_ne.mpr hb0
      simp [hbNe]
      decide

/-- `verifyProcLivenessAdmit` refines `Orb.Kernel.procLivenessStep` (`orb_proc_liveness_step`)
    on a clean `/proc` sample (`procReadError = 0`, `fieldsAfterComm ≥ 20`, `hasExpectedTicks = 1`):
    - an admitted `observeAlive` (`0`), `SIGTERM` (`2`), or `SIGKILL` (`3`) forces a matching live
      sample, so `procLivenessStep = 1` (`alive`);
    - `procLivenessStep = 0` (`dead`) because `procMissing = 1` admits `observeDead` from `alive`,
      `termSent`, or `killSent` and forbids every liveness/signal opcode;
    - `actualTicks ≠ expectedTicks` makes `procLivenessStep = 0` and rejects `SIGTERM`/`SIGKILL`,
      including the post-`SIGTERM` recheck on `termSent`. -/
theorem r5_proc_liveness_refines_kernel_procLivenessStep
    (phaseCode opCode miss zmb : UInt8) (fields : UInt32) (ePid aPid : UInt32) (eTk aTk : UInt64)
    (hfields : 20 ≤ fields) :
    ((opCode = 0 ∨ opCode = 2 ∨ opCode = 3) ∧
     verifyProcLivenessAdmit phaseCode opCode miss zmb ePid aPid eTk aTk = 1 →
       procLivenessStep miss 0 zmb 1 fields eTk aTk = 1 ∧
       miss = 0 ∧ zmb = 0 ∧ aPid = ePid ∧ aTk = eTk) ∧
    (procLivenessStep 1 0 zmb 1 fields eTk aTk = 0 ∧
     (phaseCode = 1 ∨ phaseCode = 3 ∨ phaseCode = 4) ∧ ePid ≠ 0 ∧ eTk ≠ 0 →
       verifyProcLivenessAdmit phaseCode 1 1 zmb ePid aPid eTk aTk = 1 ∧
       verifyProcLivenessAdmit phaseCode 2 1 zmb ePid aPid eTk aTk = 0 ∧
       verifyProcLivenessAdmit phaseCode 3 1 zmb ePid aPid eTk aTk = 0) ∧
    (aTk ≠ eTk →
      procLivenessStep 0 0 zmb 1 fields eTk aTk = 0 ∧
      verifyProcLivenessAdmit phaseCode 2 0 0 ePid aPid eTk aTk = 0 ∧
      verifyProcLivenessAdmit phaseCode 3 0 0 ePid aPid eTk aTk = 0) := by
  have hnotLt20 : ¬ fields < 20 := fun hlt => by
    have h1 := UInt32.le_iff_toNat_le.mp hfields
    have h2 := UInt32.lt_iff_toNat_lt.mp hlt
    omega
  refine ⟨?_, ?_, ?_⟩
  · rintro ⟨hop, hadm⟩
    have hadmB : (verifyProcLivenessAdmit phaseCode opCode miss zmb ePid aPid eTk aTk == 1) = true := by
      simpa using hadm
    have hs := processLivenessMetaGate.sound
      { codes := (phaseCode, opCode), proc := (miss, zmb),
        pids := (ePid, aPid), ticks := (eTk, aTk) } hadmB
    rcases hs with ⟨_, _, _, _, _, op, hopDec, hbr⟩
    have checkEq : miss.toNat = 0 ∧ zmb.toNat = 0 ∧
        aPid.toNat = ePid.toNat ∧ aTk.toNat = eTk.toNat := by
      rcases hop with h0 | h2 | h3
      · rw [h0] at hopDec
        simp [ProcOp.decode?] at hopDec
        subst hopDec
        exact hbr.2
      · rw [h2] at hopDec
        simp [ProcOp.decode?] at hopDec
        subst hopDec
        exact hbr.2
      · rw [h3] at hopDec
        simp [ProcOp.decode?] at hopDec
        subst hopDec
        exact hbr.2
    have hm0 := u8_eq_of_toNat miss 0 (by omega) checkEq.1
    have hz0 := u8_eq_of_toNat zmb 0 (by omega) checkEq.2.1
    have hpEq := u32_eq_of_toNat_eq aPid ePid checkEq.2.2.1
    have htEq := u64_eq_of_toNat_eq aTk eTk checkEq.2.2.2
    subst hm0; subst hz0; subst htEq
    refine ⟨?_, rfl, rfl, hpEq, rfl⟩
    unfold procLivenessStep
    simp [hnotLt20]
  · rintro ⟨_, hph, hp0, ht0⟩
    have hpPos : 0 < ePid.toNat := by
      have hne : ePid.toNat ≠ 0 := fun hz => hp0 (u32_eq_of_toNat_eq _ 0 hz); omega
    have htPos : 0 < eTk.toNat := by
      have hne : eTk.toNat ≠ 0 := fun hz => ht0 (u64_eq_of_toNat_eq _ 0 hz); omega
    refine ⟨?_, ?_, ?_⟩
    · have hadm : processLivenessMetaGate.gate
          { codes := (phaseCode, 1), proc := (1, zmb), pids := (ePid, aPid), ticks := (eTk, aTk) } = true := by
        apply processLivenessMetaGate.complete
        rcases hph with h1 | h3 | h4
        · exact ⟨hpPos, htPos, .alive, by rw [h1]; rfl, by decide, .observeDead, rfl,
            Or.inr (Or.inl rfl), Or.inl rfl⟩
        · exact ⟨hpPos, htPos, .termSent, by rw [h3]; rfl, by decide, .observeDead, rfl,
            Or.inr (Or.inr (Or.inl rfl)), Or.inl rfl⟩
        · exact ⟨hpPos, htPos, .killSent, by rw [h4]; rfl, by decide, .observeDead, rfl,
            Or.inr (Or.inr (Or.inr rfl)), Or.inl rfl⟩
      simpa [processLivenessMetaGate] using hadm
    · simp [verifyProcLivenessAdmit]
    · simp [verifyProcLivenessAdmit]
  · intro hne
    have hneEq : (aTk == eTk) = false := beq_eq_false_iff_ne.mpr hne
    refine ⟨?_, ?_, ?_⟩
    · unfold procLivenessStep
      have hneB : (aTk != eTk) = true := bne_iff_ne.mpr hne
      by_cases hz : zmb == 1 <;> simp [hz, hnotLt20, hneB]
    · simp [verifyProcLivenessAdmit, hneEq]
    · simp [verifyProcLivenessAdmit, hneEq]

/-- `RelayCommand` refines `Orb.Kernel.effectOutboxStep` (`orb_effect_outbox_step`) on the shared
    `pending/leased/accepted/uncertain` delivery ladder (`fenceMatches = 1`, matching boot epoch):
    `lease` (`0`), `ack` (`1`), `markUncertain` (`2`), and `reconcile` (`3`) move both steppers, and
    the kernel `Claim`/`Accept` opcodes issued against relay `uncertain` (`phase = 4` in
    `effectOutboxStep`, `phaseCode = 3` in `RelayCommand`) are the fresh retry both gates reject
    (`lo32 = 3`, `verifyRelayCommandAdmit = 0`). -/
theorem r5_relay_refines_kernel_effectOutboxStep
    (lease boot : UInt64) :
    (lease ≠ 0 ∧ boot ≠ 0 →
      verifyRelayCommandAdmit 0 0 0 lease boot boot = 1 ∧
      (effectOutboxStep 0 0 1 1 boot boot &&& 0xFF) = 1 ∧
      verifyRelayCommandAdmit 1 1 lease lease boot boot = 1 ∧
      (effectOutboxStep 1 0 2 1 boot boot &&& 0xFF) = 1 ∧
      verifyRelayCommandAdmit 1 2 lease lease boot boot = 1 ∧
      (effectOutboxStep 1 0 4 1 boot boot &&& 0xFF) = 1 ∧
      verifyRelayCommandAdmit 3 3 lease lease boot boot = 1 ∧
      (effectOutboxStep 4 0 5 1 boot boot &&& 0xFF) = 1) ∧
    (boot ≠ 0 →
      verifyRelayCommandAdmit 3 4 lease lease boot boot = 0 ∧
      verifyRelayCommandAdmit 3 0 lease lease boot boot = 0 ∧
      (effectOutboxStep 4 0 1 1 boot boot &&& 0xFF) = 3 ∧
      (effectOutboxStep 4 0 2 1 boot boot &&& 0xFF) = 3 ∧
      ((effectOutboxStep 4 0 1 1 boot boot >>> 16) &&& 0xFF) = 0 ∧
      ((effectOutboxStep 4 0 2 1 boot boot >>> 16) &&& 0xFF) = 0) := by
  refine ⟨?_, ?_⟩
  · rintro ⟨hl0, hb0⟩
    have hbPos : 0 < boot.toNat := by
      have hne : boot.toNat ≠ 0 := fun hz => hb0 (u64_eq_of_toNat_eq _ 0 hz); omega
    have hlPos : 0 < lease.toNat := by
      have hne : lease.toNat ≠ 0 := fun hz => hl0 (u64_eq_of_toNat_eq _ 0 hz); omega
    have hbNe : (boot != 0) = true := bne_iff_ne.mpr hb0
    have hlease : relayCommandMetaGate.gate
        { codes := (0, 0), leases := (0, lease), boots := (boot, boot) } = true := by
      apply relayCommandMetaGate.complete
      exact ⟨hbPos, rfl, hlPos, .pending, rfl, rfl, .lease, rfl, by decide, rfl, rfl⟩
    have hack : relayCommandMetaGate.gate
        { codes := (1, 1), leases := (lease, lease), boots := (boot, boot) } = true := by
      apply relayCommandMetaGate.complete
      exact ⟨hbPos, rfl, hlPos, .leased, rfl, rfl, .ack, rfl, by decide, rfl, hlPos, rfl⟩
    have hunc : relayCommandMetaGate.gate
        { codes := (1, 2), leases := (lease, lease), boots := (boot, boot) } = true := by
      apply relayCommandMetaGate.complete
      exact ⟨hbPos, rfl, hlPos, .leased, rfl, rfl, .markUncertain, rfl, by decide, rfl, hlPos, rfl⟩
    have hrec : relayCommandMetaGate.gate
        { codes := (3, 3), leases := (lease, lease), boots := (boot, boot) } = true := by
      apply relayCommandMetaGate.complete
      exact ⟨hbPos, rfl, hlPos, .uncertain, rfl, rfl, .reconcile, rfl, by decide, rfl, hlPos, rfl⟩
    refine ⟨by simpa [relayCommandMetaGate] using hlease, ?_, by simpa [relayCommandMetaGate] using hack, ?_,
      by simpa [relayCommandMetaGate] using hunc, ?_, by simpa [relayCommandMetaGate] using hrec, ?_⟩
    · unfold effectOutboxStep; simp [hbNe]; decide
    · unfold effectOutboxStep; simp [hbNe]; decide
    · unfold effectOutboxStep; simp [hbNe]; decide
    · unfold effectOutboxStep; simp [hbNe]; decide
  · intro hb0
    have hbNe : (boot != 0) = true := bne_iff_ne.mpr hb0
    refine ⟨by simp [verifyRelayCommandAdmit], by simp [verifyRelayCommandAdmit], ?_, ?_, ?_, ?_⟩
    · unfold effectOutboxStep; simp [hbNe]; decide
    · unfold effectOutboxStep; simp [hbNe]; decide
    · unfold effectOutboxStep; simp [hbNe]; decide
    · unfold effectOutboxStep; simp [hbNe]; decide

/-! ## 7. Orthogonal `R5WorldState` Footprint Disjointness & 10-Pair Commutativity -/

theorem r5_specBlocks_all_footprints_disjoint :
    Footprint.Disjoint vmLifecycleSpecBlock.footprint vmClaimSpecBlock.footprint = true ∧
    Footprint.Disjoint vmLifecycleSpecBlock.footprint remoteJobSpecBlock.footprint = true ∧
    Footprint.Disjoint vmLifecycleSpecBlock.footprint processLivenessSpecBlock.footprint = true ∧
    Footprint.Disjoint vmLifecycleSpecBlock.footprint relayCommandSpecBlock.footprint = true ∧
    Footprint.Disjoint vmClaimSpecBlock.footprint remoteJobSpecBlock.footprint = true ∧
    Footprint.Disjoint vmClaimSpecBlock.footprint processLivenessSpecBlock.footprint = true ∧
    Footprint.Disjoint vmClaimSpecBlock.footprint relayCommandSpecBlock.footprint = true ∧
    Footprint.Disjoint remoteJobSpecBlock.footprint processLivenessSpecBlock.footprint = true ∧
    Footprint.Disjoint remoteJobSpecBlock.footprint relayCommandSpecBlock.footprint = true ∧
    Footprint.Disjoint processLivenessSpecBlock.footprint relayCommandSpecBlock.footprint = true := by
  decide

theorem r5_specBlocks_pairwise_commute
    (w : R5WorldState)
    (ev : VmSliceEvent) (ec : ClaimSliceEvent) (ej : JobSliceEvent)
    (ep : ProcSliceEvent) (er : RelaySliceEvent) :
    (vmClaimSpecBlock.liftStep (vmLifecycleSpecBlock.liftStep w ev).1 ec).1 =
      (vmLifecycleSpecBlock.liftStep (vmClaimSpecBlock.liftStep w ec).1 ev).1 ∧
    (remoteJobSpecBlock.liftStep (vmLifecycleSpecBlock.liftStep w ev).1 ej).1 =
      (vmLifecycleSpecBlock.liftStep (remoteJobSpecBlock.liftStep w ej).1 ev).1 ∧
    (processLivenessSpecBlock.liftStep (vmLifecycleSpecBlock.liftStep w ev).1 ep).1 =
      (vmLifecycleSpecBlock.liftStep (processLivenessSpecBlock.liftStep w ep).1 ev).1 ∧
    (relayCommandSpecBlock.liftStep (vmLifecycleSpecBlock.liftStep w ev).1 er).1 =
      (vmLifecycleSpecBlock.liftStep (relayCommandSpecBlock.liftStep w er).1 ev).1 ∧
    (remoteJobSpecBlock.liftStep (vmClaimSpecBlock.liftStep w ec).1 ej).1 =
      (vmClaimSpecBlock.liftStep (remoteJobSpecBlock.liftStep w ej).1 ec).1 ∧
    (processLivenessSpecBlock.liftStep (vmClaimSpecBlock.liftStep w ec).1 ep).1 =
      (vmClaimSpecBlock.liftStep (processLivenessSpecBlock.liftStep w ep).1 ec).1 ∧
    (relayCommandSpecBlock.liftStep (vmClaimSpecBlock.liftStep w ec).1 er).1 =
      (vmClaimSpecBlock.liftStep (relayCommandSpecBlock.liftStep w er).1 ec).1 ∧
    (processLivenessSpecBlock.liftStep (remoteJobSpecBlock.liftStep w ej).1 ep).1 =
      (remoteJobSpecBlock.liftStep (processLivenessSpecBlock.liftStep w ep).1 ej).1 ∧
    (relayCommandSpecBlock.liftStep (remoteJobSpecBlock.liftStep w ej).1 er).1 =
      (remoteJobSpecBlock.liftStep (relayCommandSpecBlock.liftStep w er).1 ej).1 ∧
    (relayCommandSpecBlock.liftStep (processLivenessSpecBlock.liftStep w ep).1 er).1 =
      (processLivenessSpecBlock.liftStep (relayCommandSpecBlock.liftStep w er).1 ep).1 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · refine specBlock_orthogonal_commutes vmLifecycleSpecBlock vmClaimSpecBlock ?_ ?_ ?_ w ev ec
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes vmLifecycleSpecBlock remoteJobSpecBlock ?_ ?_ ?_ w ev ej
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes vmLifecycleSpecBlock processLivenessSpecBlock ?_ ?_ ?_ w ev ep
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes vmLifecycleSpecBlock relayCommandSpecBlock ?_ ?_ ?_ w ev er
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes vmClaimSpecBlock remoteJobSpecBlock ?_ ?_ ?_ w ec ej
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes vmClaimSpecBlock processLivenessSpecBlock ?_ ?_ ?_ w ec ep
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes vmClaimSpecBlock relayCommandSpecBlock ?_ ?_ ?_ w ec er
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes remoteJobSpecBlock processLivenessSpecBlock ?_ ?_ ?_ w ej ep
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes remoteJobSpecBlock relayCommandSpecBlock ?_ ?_ ?_ w ej er
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl
  · refine specBlock_orthogonal_commutes processLivenessSpecBlock relayCommandSpecBlock ?_ ?_ ?_ w ep er
    · intro w0 _; cases w0; rfl
    · intro w0 _; cases w0; rfl
    · intro w0 _ _; cases w0; rfl

end Orb.ManagedNodeSpec
