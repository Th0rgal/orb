/-
  OrbClient.Spec: Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for Client-Side `OrbWire` Projection, Stream Checkpoint, Mission Sync Cursor &
  Bounded Slice Frame Gates (`OrbClient`).

  Every scalar gate is proved equivalent (`MetaGateSpec`, `ProjectionStability`,
  `ConservedResource`) to an independent domain model over lexicographic cursor orderings
  and natural-number bundle budgets rather than mirroring the gate's boolean formula.
-/
namespace OrbClient.Spec

/-- Sound, complete, non-vacuous, tight decision gate combinator. -/
structure MetaGateSpec (Input : Type) (Safe : Input → Prop) where
  gate       : Input → Bool
  sound      : ∀ x, gate x = true → Safe x
  complete   : ∀ x, Safe x → gate x = true
  posWitness : Input
  negWitness : Input
  nonVacuous : gate posWitness = true
  tight      : gate negWitness = false

theorem MetaGateSpec.rejects_unsafe {Input : Type} {Safe : Input → Prop}
    (M : MetaGateSpec Input Safe) (x : Input) (h_unsafe : ¬ Safe x) :
    M.gate x = false := by
  cases h : M.gate x with
  | false => rfl
  | true => exact False.elim (h_unsafe (M.sound x h))

/-- Layer-I `ConservedResource` meta-specification: admitted assets stay within byte budget. -/
structure ConservedResource (Input : Type) where
  admit        : Input → Bool
  withinBudget : Input → Prop
  conserved    : ∀ x, admit x = true → withinBudget x

/-- Projection stability contract over admissible client inputs (`ProjectionStability`). -/
structure ProjectionStability (Input Out : Type) where
  project     : Input → Out
  validIn     : Input → Bool
  stable      : Input → Out → Bool
  preserves   : ∀ x, validIn x = true → stable x (project x) = true
  posWitness  : Input
  negWitness  : Input
  validPos    : validIn posWitness = true
  invalidNeg  : validIn negWitness = false

/-- Total bounded slice parser contract (`TotalSliceParserSpec`). -/
structure TotalSliceParserSpec (Out : Type) where
  maxCap     : Nat
  parse      : ByteArray → Option Out
  byteLen    : Out → Nat
  bounded    : ∀ raw out, parse raw = some out → byteLen out ≤ maxCap
  posRaw     : ByteArray
  negRaw     : ByteArray
  nonVacuous : (parse posRaw).isSome = true
  tight      : (parse negRaw).isNone = true

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

private theorem bit_gate_eq_zero {c : Bool} (hf : ((if c then (1 : UInt8) else 0) == 1) = false) :
    (if c then (1 : UInt8) else 0) = 0 := by
  cases c <;> simp_all

/-! ### 1. Client Sync Cursor Monotonicity & Epoch Fence Gate -/

/-- Strict lexicographic ordering on `(epoch, seq)` pairs over `Nat`. -/
def LexStrictCursorLt (ep1 sq1 ep2 sq2 : Nat) : Prop :=
  ep1 < ep2 ∨ (ep1 = ep2 ∧ sq1 < sq2)

structure ClientSyncCursorCheck where
  epochs : UInt64 × UInt64
  seqs   : UInt64 × UInt64
  flags  : UInt8 × UInt8
  deriving Repr, DecidableEq

/-- Independent sync-cursor monotonicity specification:
    frame checksum/wire structure is valid (`frameValid = 1`), session auth is verified (`authOk = 1`),
    the incoming epoch is positive (`1 ≤ incomingEpoch`), and `(localEpoch, localSeq)` strictly
    precedes `(incomingEpoch, incomingSeq)` under `LexStrictCursorLt`. -/
def ClientSyncCursorDomainSafe (c : ClientSyncCursorCheck) : Prop :=
  c.flags.1.toNat = 1 ∧
  c.flags.2.toNat = 1 ∧
  1 ≤ c.epochs.2.toNat ∧
  LexStrictCursorLt c.epochs.1.toNat c.seqs.1.toNat c.epochs.2.toNat c.seqs.2.toNat

@[inline, export orb_client_verify_sync_cursor]
def verifyClientSyncCursor
    (localEpoch : UInt64)
    (incomingEpoch : UInt64)
    (localSeq : UInt64)
    (incomingSeq : UInt64)
    (frameValid : UInt8)
    (authOk : UInt8) : UInt8 :=
  if frameValid == 1 &&
     authOk == 1 &&
     incomingEpoch > 0 &&
     (localEpoch < incomingEpoch || (localEpoch == incomingEpoch && localSeq < incomingSeq)) then 1
  else 0

def clientSyncCursorMetaGate : MetaGateSpec ClientSyncCursorCheck ClientSyncCursorDomainSafe where
  gate c :=
    verifyClientSyncCursor
      c.epochs.1 c.epochs.2
      c.seqs.1 c.seqs.2
      c.flags.1 c.flags.2 == 1
  sound c h := by
    rcases c with ⟨⟨le, ie⟩, ⟨ls, isq⟩, ⟨fv, ao⟩⟩
    change (verifyClientSyncCursor le ie ls isq fv ao == 1) = true at h
    dsimp [ClientSyncCursorDomainSafe, LexStrictCursorLt]
    unfold verifyClientSyncCursor at h
    cases hc :
        (fv == 1 &&
         ao == 1 &&
         ie > 0 &&
         (le < ie || (le == ie && ls < isq)))
    · rw [hc] at h; contradiction
    · simp only [Bool.and_eq_true, Bool.or_eq_true, gt_iff_lt,
        decide_eq_true_eq, beq_iff_eq] at hc
      rcases hc with ⟨⟨⟨hfv, hao⟩, hie⟩, hlex⟩
      have hieN : 0 < ie.toNat := UInt64.lt_iff_toNat_lt.mp hie
      refine ⟨by subst hfv; rfl, by subst hao; rfl, by omega, ?_⟩
      rcases hlex with hlt | ⟨heq, hslt⟩
      · exact Or.inl (UInt64.lt_iff_toNat_lt.mp hlt)
      · exact Or.inr ⟨by subst heq; rfl, UInt64.lt_iff_toNat_lt.mp hslt⟩
  complete c h := by
    rcases c with ⟨⟨le, ie⟩, ⟨ls, isq⟩, ⟨fv, ao⟩⟩
    change (verifyClientSyncCursor le ie ls isq fv ao == 1) = true
    dsimp [ClientSyncCursorDomainSafe, LexStrictCursorLt] at h
    rcases h with ⟨hfv, hao, hie, hlex⟩
    unfold verifyClientSyncCursor
    have hfvB : (fv == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat fv 1 (by omega) hfv
    have haoB : (ao == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ao 1 (by omega) hao
    have hieB : ie > 0 := by apply UInt64.lt_iff_toNat_lt.mpr; change 0 < ie.toNat; omega
    rcases hlex with hlt | ⟨heq, hslt⟩
    · have hltB : le < ie := UInt64.lt_iff_toNat_lt.mpr hlt
      simp [hfvB, haoB, hieB, hltB]
    · have heqB : (le == ie) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq le ie heq
      have hsltB : ls < isq := UInt64.lt_iff_toNat_lt.mpr hslt
      simp [hfvB, haoB, hieB, heqB, hsltB]
  posWitness := { epochs := (3, 3), seqs := (41, 42), flags := (1, 1) }
  negWitness := { epochs := (3, 3), seqs := (42, 42), flags := (1, 1) }
  nonVacuous := by decide
  tight := by decide

theorem client_sync_cursor_irreflexive (ep sq : UInt64) (fv ao : UInt8) :
    verifyClientSyncCursor ep ep sq sq fv ao = 0 := by
  have hbad : ¬ ClientSyncCursorDomainSafe ⟨(ep, ep), (sq, sq), (fv, ao)⟩ := by
    rintro ⟨_, _, _, hlex⟩
    dsimp [LexStrictCursorLt] at hlex
    rcases hlex with hlt | ⟨_, hslt⟩ <;> omega
  have hf := clientSyncCursorMetaGate.rejects_unsafe ⟨(ep, ep), (sq, sq), (fv, ao)⟩ hbad
  unfold clientSyncCursorMetaGate at hf; dsimp at hf
  unfold verifyClientSyncCursor at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 2. Live/Replay Transcript Projection Invariance (`ProjectionStability`) -/

structure TranscriptProjInput where
  counts    : UInt32 × UInt32
  metaFlags : UInt8 × UInt8
  deriving Repr, DecidableEq

structure TranscriptProjOut where
  visibleEntries : UInt32
  thinkingActive : UInt8
  deriving Repr, DecidableEq

/-- Replay-invariant projection: `metaFlags.2` (`isReplayFromLog`) never alters visible state. -/
@[inline, export orb_client_project_transcript_counts]
def projectTranscript (inp : TranscriptProjInput) : TranscriptProjOut :=
  let total := inp.counts.1 + inp.counts.2
  let thinking : UInt8 := if inp.metaFlags.1 == 1 then 1 else 0
  { visibleEntries := total, thinkingActive := thinking }

def validTranscriptProjInput (inp : TranscriptProjInput) : Bool :=
  inp.counts.1 ≤ 65536 && inp.counts.2 ≤ 65536 && inp.metaFlags.1 ≤ 1 && inp.metaFlags.2 ≤ 1

def stableTranscriptProj (inp : TranscriptProjInput) (out : TranscriptProjOut) : Bool :=
  let flipped : TranscriptProjInput := { inp with metaFlags := (inp.metaFlags.1, 1 - inp.metaFlags.2) }
  out == projectTranscript flipped && out.thinkingActive ≤ 1

def transcriptProjectionStability : ProjectionStability TranscriptProjInput TranscriptProjOut where
  project := projectTranscript
  validIn := validTranscriptProjInput
  stable := stableTranscriptProj
  preserves x _h := by
    unfold stableTranscriptProj projectTranscript
    cases h_t : x.metaFlags.1 == 1 <;> simp [h_t]
  posWitness := { counts := (12, 4), metaFlags := (1, 0) }
  negWitness := { counts := (90000, 4), metaFlags := (1, 0) }
  validPos := by decide
  invalidNeg := by decide

theorem transcript_projection_replay_invariant
    (inp : TranscriptProjInput) :
    projectTranscript { inp with metaFlags := (inp.metaFlags.1, 0) } =
      projectTranscript { inp with metaFlags := (inp.metaFlags.1, 1) } := by
  rfl

/-! ### 3. Eager Bundle Budget & Lazy Chunk Isolation Gate (`check-bundle.mjs` invariant) -/

structure BundleBudgetCheck where
  sizes : UInt64 × UInt64
  flags : UInt8 × UInt8
  deriving Repr, DecidableEq

/-- Independent `ConservedResource` bundle specification over `Nat` headroom:
    the app builds as a single entry (`singleAppEntry = 1`) with zero eager heavy vendor chunks
    (`hasEagerHeavyVendor = 0`), a strictly positive budget (`1 ≤ budgetBytes`), and a non-negative
    byte slack `slackBytes : Nat` satisfying `eagerBytes + slackBytes = budgetBytes`. -/
def BundleBudgetDomainSafe (b : BundleBudgetCheck) : Prop :=
  b.flags.1.toNat = 1 ∧
  b.flags.2.toNat = 0 ∧
  1 ≤ b.sizes.2.toNat ∧
  ∃ slackBytes : Nat, b.sizes.1.toNat + slackBytes = b.sizes.2.toNat

@[inline, export orb_client_verify_bundle_budget]
def verifyBundleBudget
    (eagerBytes : UInt64)
    (budgetBytes : UInt64)
    (singleAppEntry : UInt8)
    (hasEagerHeavyVendor : UInt8) : UInt8 :=
  if singleAppEntry == 1 &&
     hasEagerHeavyVendor == 0 &&
     budgetBytes > 0 &&
     eagerBytes ≤ budgetBytes then 1
  else 0

def bundleBudgetMetaGate : MetaGateSpec BundleBudgetCheck BundleBudgetDomainSafe where
  gate b :=
    verifyBundleBudget b.sizes.1 b.sizes.2 b.flags.1 b.flags.2 == 1
  sound b h := by
    rcases b with ⟨⟨eB, bB⟩, ⟨se, hv⟩⟩
    change (verifyBundleBudget eB bB se hv == 1) = true at h
    dsimp [BundleBudgetDomainSafe]
    unfold verifyBundleBudget at h
    cases hc : (se == 1 && hv == 0 && bB > 0 && eB ≤ bB)
    · rw [hc] at h; contradiction
    · simp only [Bool.and_eq_true, gt_iff_lt, decide_eq_true_eq, beq_iff_eq] at hc
      rcases hc with ⟨⟨⟨hse, hhv⟩, hbpos⟩, hle⟩
      have hbN : 0 < bB.toNat := UInt64.lt_iff_toNat_lt.mp hbpos
      have hleN : eB.toNat ≤ bB.toNat := UInt64.le_iff_toNat_le.mp hle
      refine ⟨by subst hse; rfl, by subst hhv; rfl, by omega, bB.toNat - eB.toNat, ?_⟩
      omega
  complete b h := by
    rcases b with ⟨⟨eB, bB⟩, ⟨se, hv⟩⟩
    change (verifyBundleBudget eB bB se hv == 1) = true
    dsimp [BundleBudgetDomainSafe] at h
    rcases h with ⟨hse, hhv, hbpos, slack, hslack⟩
    unfold verifyBundleBudget
    have hseB : (se == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat se 1 (by omega) hse
    have hhvB : (hv == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hv 0 (by omega) hhv
    have hbB : bB > 0 := by apply UInt64.lt_iff_toNat_lt.mpr; change 0 < bB.toNat; omega
    have hleB : eB ≤ bB := by apply UInt64.le_iff_toNat_le.mpr; omega
    simp [hseB, hhvB, hbB, hleB]
  posWitness := { sizes := (980000, 1177600), flags := (1, 0) }
  negWitness := { sizes := (980000, 1177600), flags := (1, 1) }
  nonVacuous := by decide
  tight := by decide

def bundleBudgetConserved : ConservedResource BundleBudgetCheck where
  admit := bundleBudgetMetaGate.gate
  withinBudget b := b.sizes.1.toNat ≤ b.sizes.2.toNat
  conserved b h := by
    rcases bundleBudgetMetaGate.sound b h with ⟨_, _, _, slack, hslack⟩
    omega

theorem bundle_budget_rejects_overbudget (eB bB : UInt64) (se hv : UInt8)
    (h_over : bB.toNat < eB.toNat) :
    verifyBundleBudget eB bB se hv = 0 := by
  have hbad : ¬ BundleBudgetDomainSafe ⟨(eB, bB), (se, hv)⟩ := by
    rintro ⟨_, _, _, slack, hslack⟩
    dsimp at hslack
    omega
  have hf := bundleBudgetMetaGate.rejects_unsafe ⟨(eB, bB), (se, hv)⟩ hbad
  unfold bundleBudgetMetaGate at hf; dsimp at hf
  unfold verifyBundleBudget at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 4. Bounded `OrbWire` Client Patch Frame Parser (`TotalSliceParserSpec`, `<= 64 KiB`) -/

/-- Parse an 8-byte `OrbWire` client patch envelope:
    magic `"ORBP"` (`0x4F, 0x52, 0x42, 0x50`), 2-byte schema (`1..255`), 2-byte big-endian payload length (`1..65535`). -/
def parseOrbClientPatch (raw : ByteArray) : Option ByteArray :=
  if raw.size < 9 then none
  else if raw.get! 0 != 0x4F || raw.get! 1 != 0x52 || raw.get! 2 != 0x42 || raw.get! 3 != 0x50 then
    none
  else
    let schema := ((raw.get! 4).toUInt16 <<< 8) ||| (raw.get! 5).toUInt16
    let payLen := (((raw.get! 6).toNat) <<< 8) ||| (raw.get! 7).toNat
    if 1 ≤ schema && schema ≤ 255 && 1 ≤ payLen && payLen ≤ 65535 && 8 + payLen == raw.size then
      let sub := raw.extract 8 (8 + payLen)
      if sub.size ≤ 65535 then some sub else none
    else
      none

def orbClientPatchParserSpec : TotalSliceParserSpec ByteArray where
  maxCap := 65535
  parse := parseOrbClientPatch
  byteLen := ByteArray.size
  bounded raw out h := by
    unfold parseOrbClientPatch at h
    split at h
    · contradiction
    · split at h
      · contradiction
      · dsimp at h
        split at h
        · split at h
          · injection h with h_eq
            subst h_eq
            assumption
          · contradiction
        · contradiction
  posRaw := ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x01, 0x00, 0x02, 0x7B, 0x7D]
  negRaw := ByteArray.mk #[0x4F, 0x52, 0x42, 0x58, 0x00, 0x01, 0x00, 0x02, 0x7B, 0x7D]
  nonVacuous := by decide
  tight := by decide

theorem orb_client_patch_bounded
    (raw out : ByteArray)
    (h : parseOrbClientPatch raw = some out) :
    out.size ≤ 65535 :=
  orbClientPatchParserSpec.bounded raw out h

end OrbClient.Spec
