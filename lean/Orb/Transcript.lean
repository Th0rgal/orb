/-
  Orb.Transcript: the cross-client transcript safety contract (`0 import Lean`, `0 sorryAx`).

  Three pure invariants keep long, rich transcripts crash-free and bounded across
  Orb Desktop (`orb/src/transcriptGates.ts`), iOS (`OrbPipeTables.swift` /
  `OrbTranscriptModel.swift`), and Android (`OrbTranscriptGates.kt` / `OrbConversation.kt`):

  1. Injective turn-key allocation (`allocTurnKeys`). Arbitrary upstream turn/bubble
     candidates `(tag, item)` — including empty cloud keys, retried canonical bubbles,
     or repeated optimistic rows — map to strictly unique `(tag, item, gen)` UI keys
     (`List.Nodup`), preserving `(tag, item)` order and keeping `gen = 0` whenever
     candidates are already distinct.
  2. Pandoc-aligned inline `$` LaTeX delimiter gate (`latexSpanAdmitted`). Admits inline
     math spans iff non-empty, bounded (`len ≤ 8192`), unescaped/unblocked at both ends,
     single-line, and not prose currency (`$15 and $20` without math operators).
  3. Bounded transcript window & heavy-mount conservation (`visibleTurnCount`, `admitMount`).
     Partitioning `total` turns into `hiddenTurnCount + visibleTurnCount` conserves `total`
     exactly, grows monotonically as older history is expanded, and caps concurrent heavy
     media/diagram mounts at `cap`.

  Checked against `shared/orb-spec/fixtures/transcript-gates.json` via
  `scripts/gen_transcript_fixtures.lean` (`--check` in CI).
-/

namespace Orb.Transcript

/-! ## 1. Injective Turn-Key Allocation -/

structure CandidateKey where
  tag : Nat
  item : Nat
  deriving Repr, DecidableEq

structure TurnKey where
  tag : Nat
  item : Nat
  gen : Nat
  deriving Repr, DecidableEq

structure KeyAlloc where
  seen : List CandidateKey
  nextGen : Nat
  deriving Repr, DecidableEq

def KeyAlloc.init : KeyAlloc :=
  { seen := [], nextGen := 1 }

def turnKeyCandidate (k : TurnKey) : CandidateKey :=
  { tag := k.tag, item := k.item }

def allocTurnKey (s : KeyAlloc) (c : CandidateKey) : KeyAlloc × TurnKey :=
  if c ∈ s.seen then
    ({ seen := s.seen, nextGen := s.nextGen + 1 },
     { tag := c.tag, item := c.item, gen := s.nextGen })
  else
    ({ seen := c :: s.seen, nextGen := s.nextGen },
     { tag := c.tag, item := c.item, gen := 0 })

def allocTurnKeysAux : KeyAlloc → List CandidateKey → List TurnKey
  | _, [] => []
  | s, c :: cs =>
    let step := allocTurnKey s c
    step.2 :: allocTurnKeysAux step.1 cs

def allocTurnKeys (cs : List CandidateKey) : List TurnKey :=
  allocTurnKeysAux KeyAlloc.init cs

theorem allocTurnKeysAux_candidates (s : KeyAlloc) (cs : List CandidateKey) :
    (allocTurnKeysAux s cs).map turnKeyCandidate = cs := by
  induction cs generalizing s with
  | nil =>
    rfl
  | cons c rest ih =>
    simp only [allocTurnKeysAux, List.map_cons]
    rw [ih]
    rcases c with ⟨tag, item⟩
    by_cases hc : ({ tag := tag, item := item } : CandidateKey) ∈ s.seen
    · simp [allocTurnKey, hc, turnKeyCandidate]
    · simp [allocTurnKey, hc, turnKeyCandidate]

/-- Every emitted turn key preserves its original `(tag, item)` candidate in order. -/
theorem allocTurnKeys_candidates (cs : List CandidateKey) :
    (allocTurnKeys cs).map turnKeyCandidate = cs := by
  exact allocTurnKeysAux_candidates KeyAlloc.init cs

theorem allocTurnKeysAux_future (s : KeyAlloc) (cs : List CandidateKey) (k : TurnKey)
    (hk : k ∈ allocTurnKeysAux s cs) :
    (k.gen = 0 ∧ turnKeyCandidate k ∉ s.seen) ∨ s.nextGen ≤ k.gen := by
  induction cs generalizing s with
  | nil =>
    simp [allocTurnKeysAux] at hk
  | cons c rest ih =>
    simp only [allocTurnKeysAux, List.mem_cons] at hk
    rcases hk with rfl | hrest
    · by_cases hc : c ∈ s.seen
      · right
        simp [allocTurnKey, hc]
      · left
        rcases c with ⟨tag, item⟩
        simp [allocTurnKey, hc, turnKeyCandidate]
    · by_cases hc : c ∈ s.seen
      · have hs1 : (allocTurnKey s c).1 = { seen := s.seen, nextGen := s.nextGen + 1 } := by
          simp [allocTurnKey, hc]
        rw [hs1] at hrest
        have hsub := ih { seen := s.seen, nextGen := s.nextGen + 1 } hrest
        rcases hsub with ⟨hg, hnot⟩ | hge
        · exact Or.inl ⟨hg, hnot⟩
        · exact Or.inr (by omega)
      · have hs1 : (allocTurnKey s c).1 = { seen := c :: s.seen, nextGen := s.nextGen } := by
          simp [allocTurnKey, hc]
        rw [hs1] at hrest
        have hsub := ih { seen := c :: s.seen, nextGen := s.nextGen } hrest
        rcases hsub with ⟨hg, hnot⟩ | hge
        · left
          refine ⟨hg, ?_⟩
          intro hm
          exact hnot (List.mem_cons_of_mem c hm)
        · exact Or.inr hge

theorem allocTurnKeysAux_nodup (s : KeyAlloc) (cs : List CandidateKey)
    (hgen : 1 ≤ s.nextGen) :
    (allocTurnKeysAux s cs).Nodup := by
  induction cs generalizing s with
  | nil =>
    simp [allocTurnKeysAux]
  | cons c rest ih =>
    simp only [allocTurnKeysAux]
    refine List.nodup_cons.mpr ⟨?_, ?_⟩
    · intro hm
      have hfut := allocTurnKeysAux_future (allocTurnKey s c).1 rest (allocTurnKey s c).2 hm
      by_cases hc : c ∈ s.seen
      · have hs1 : (allocTurnKey s c).1 = { seen := s.seen, nextGen := s.nextGen + 1 } := by
          simp [allocTurnKey, hc]
        have hs2 : (allocTurnKey s c).2 = { tag := c.tag, item := c.item, gen := s.nextGen } := by
          simp [allocTurnKey, hc]
        rw [hs1, hs2] at hfut
        rcases hfut with ⟨hg, _⟩ | hge
        · simp at hg
          omega
        · simp at hge
          omega
      · have hs1 : (allocTurnKey s c).1 = { seen := c :: s.seen, nextGen := s.nextGen } := by
          simp [allocTurnKey, hc]
        have hs2 : (allocTurnKey s c).2 = { tag := c.tag, item := c.item, gen := 0 } := by
          simp [allocTurnKey, hc]
        rw [hs1, hs2] at hfut
        rcases hfut with ⟨_, hnot⟩ | hge
        · apply hnot
          rcases c with ⟨tag, item⟩
          simp [turnKeyCandidate]
        · simp at hge
          omega
    · apply ih
      by_cases hc : c ∈ s.seen
      · simp [allocTurnKey, hc]
        omega
      · simp [allocTurnKey, hc]
        omega

/-- Unconditional key uniqueness: `allocTurnKeys` never emits duplicate keys for any
    candidate list, eliminating `LazyColumn` / `ForEach` duplicate-key crashes. -/
theorem allocTurnKeys_nodup (cs : List CandidateKey) :
    (allocTurnKeys cs).Nodup := by
  exact allocTurnKeysAux_nodup KeyAlloc.init cs (by decide)

theorem allocTurnKeysAux_fresh_gen_zero (s : KeyAlloc) (cs : List CandidateKey)
    (hfresh : ∀ c ∈ cs, c ∉ s.seen) (hd : cs.Nodup) (k : TurnKey)
    (hk : k ∈ allocTurnKeysAux s cs) :
    k.gen = 0 := by
  induction cs generalizing s with
  | nil =>
    simp [allocTurnKeysAux] at hk
  | cons c rest ih =>
    have hc : c ∉ s.seen := hfresh c (by simp)
    have hd' := List.nodup_cons.mp hd
    simp only [allocTurnKeysAux, List.mem_cons] at hk
    rcases hk with rfl | hrest
    · simp [allocTurnKey, hc]
    · have hs1 : (allocTurnKey s c).1 = { seen := c :: s.seen, nextGen := s.nextGen } := by
        simp [allocTurnKey, hc]
      rw [hs1] at hrest
      refine ih { seen := c :: s.seen, nextGen := s.nextGen } ?_ hd'.2 hrest
      intro x hx hmem
      simp only [List.mem_cons] at hmem
      rcases hmem with rfl | hseen
      · exact hd'.1 hx
      · exact hfresh x (by simp [hx]) hseen

/-- Zero-churn stability: when candidate keys are already distinct, every emitted key
    keeps `gen = 0` without synthetic suffixes. -/
theorem allocTurnKeys_fresh_gen_zero (cs : List CandidateKey) (hd : cs.Nodup)
    (k : TurnKey) (hk : k ∈ allocTurnKeys cs) :
    k.gen = 0 := by
  refine allocTurnKeysAux_fresh_gen_zero KeyAlloc.init cs ?_ hd k hk
  intro c _ hmem
  simp [KeyAlloc.init] at hmem

/-- Non-vacuity witness: three identical `(1, 0)` candidates receive distinct generations `0, 1, 2`. -/
example :
    allocTurnKeys [{ tag := 1, item := 0 }, { tag := 1, item := 0 }, { tag := 1, item := 0 }] =
      [{ tag := 1, item := 0, gen := 0 },
       { tag := 1, item := 0, gen := 1 },
       { tag := 1, item := 0, gen := 2 }] := by
  decide

/-! ## 2. Pandoc-Aligned Inline `$` LaTeX Delimiter Gate -/

def maxLatexSpanChars : Nat := 8192

structure LatexSpan where
  len : Nat
  prevBlocked : Bool
  nextDigit : Bool
  leadSpace : Bool
  trailSpace : Bool
  hasNewline : Bool
  firstDigit : Bool
  internalSpace : Bool
  hasMathOp : Bool
  deriving Repr, DecidableEq

def latexSpanAdmitted (x : LatexSpan) : Bool :=
  decide (0 < x.len) &&
  decide (x.len ≤ maxLatexSpanChars) &&
  !x.prevBlocked &&
  !x.nextDigit &&
  !x.leadSpace &&
  !x.trailSpace &&
  !x.hasNewline &&
  !(x.firstDigit && x.internalSpace && !x.hasMathOp)

def LatexSpanSafe (x : LatexSpan) : Prop :=
  0 < x.len ∧
  x.len ≤ maxLatexSpanChars ∧
  x.prevBlocked = false ∧
  x.nextDigit = false ∧
  x.leadSpace = false ∧
  x.trailSpace = false ∧
  x.hasNewline = false ∧
  (x.firstDigit = true → x.internalSpace = true → x.hasMathOp = true)

theorem latexSpanAdmitted_sound (x : LatexSpan) (h : latexSpanAdmitted x = true) :
    LatexSpanSafe x := by
  rcases x with ⟨len, pb, nd, ls, ts, nl, fd, isp, mo⟩
  unfold latexSpanAdmitted LatexSpanSafe at *
  cases pb
  · cases nd
    · cases ls
      · cases ts
        · cases nl
          · cases fd
            · simp at h ⊢
              omega
            · cases isp
              · simp at h ⊢
                omega
              · cases mo
                · simp at h
                · simp at h ⊢
                  omega
          · simp at h
        · simp at h
      · simp at h
    · simp at h
  · simp at h

theorem latexSpanAdmitted_complete (x : LatexSpan) (h : LatexSpanSafe x) :
    latexSpanAdmitted x = true := by
  rcases x with ⟨len, pb, nd, ls, ts, nl, fd, isp, mo⟩
  rcases h with ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩
  dsimp at h1 h2 h3 h4 h5 h6 h7 h8
  subst h3 h4 h5 h6 h7
  cases fd
  · simp [latexSpanAdmitted, h1, h2]
  · cases isp
    · simp [latexSpanAdmitted, h1, h2]
    · have hmo : mo = true := h8 rfl rfl
      subst hmo
      simp [latexSpanAdmitted, h1, h2]

/-- Exact soundness and completeness of the inline `$` delimiter gate. -/
theorem latexSpanAdmitted_iff (x : LatexSpan) :
    latexSpanAdmitted x = true ↔ LatexSpanSafe x := by
  exact ⟨latexSpanAdmitted_sound x, latexSpanAdmitted_complete x⟩

/-- Prose currency pairs (`$15 and $20`, where `firstDigit` and `internalSpace` hold
    without math operators) are unconditionally rejected. -/
theorem currency_span_rejected (x : LatexSpan)
    (hd : x.firstDigit = true) (hs : x.internalSpace = true) (hm : x.hasMathOp = false) :
    latexSpanAdmitted x = false := by
  simp [latexSpanAdmitted, hd, hs, hm]

/-- Pathological inline spans exceeding `maxLatexSpanChars` (`8192`) are rejected. -/
theorem oversized_latex_span_rejected (x : LatexSpan) (h : maxLatexSpanChars < x.len) :
    latexSpanAdmitted x = false := by
  have hnot : ¬ (x.len ≤ maxLatexSpanChars) := by omega
  simp [latexSpanAdmitted, hnot]

/-- Closing `$` followed immediately by an ASCII digit is rejected. -/
theorem adjacent_digit_closing_rejected (x : LatexSpan) (h : x.nextDigit = true) :
    latexSpanAdmitted x = false := by
  simp [latexSpanAdmitted, h]

example :
    latexSpanAdmitted {
      len := 5, prevBlocked := false, nextDigit := false,
      leadSpace := false, trailSpace := false, hasNewline := false,
      firstDigit := false, internalSpace := false, hasMathOp := true
    } = true ∧
    latexSpanAdmitted {
      len := 6, prevBlocked := false, nextDigit := false,
      leadSpace := false, trailSpace := false, hasNewline := false,
      firstDigit := true, internalSpace := true, hasMathOp := false
    } = false := by
  decide

/-! ## 3. Transcript Window & Active Heavy-Mount Budget -/

def visibleTurnCount (total baseLimit expandedSteps stepSize : Nat) : Nat :=
  min total (baseLimit + expandedSteps * stepSize)

def hiddenTurnCount (total baseLimit expandedSteps stepSize : Nat) : Nat :=
  total - visibleTurnCount total baseLimit expandedSteps stepSize

def admitMount (active cap : Nat) : Bool × Nat :=
  if active < cap then (true, active + 1) else (false, active)

/-- Partition conservation: hidden older turns plus visible suffix turns always equal `total`. -/
theorem visible_plus_hidden_conserved (total baseLimit expandedSteps stepSize : Nat) :
    visibleTurnCount total baseLimit expandedSteps stepSize +
      hiddenTurnCount total baseLimit expandedSteps stepSize = total := by
  unfold hiddenTurnCount visibleTurnCount
  omega

/-- Expanding older turns monotonically grows the visible window without jumps. -/
theorem visibleTurnCount_monotone_steps (total baseLimit s1 s2 stepSize : Nat) (h : s1 ≤ s2) :
    visibleTurnCount total baseLimit s1 stepSize ≤
      visibleTurnCount total baseLimit s2 stepSize := by
  have hmul : s1 * stepSize ≤ s2 * stepSize := Nat.mul_le_mul_right stepSize h
  unfold visibleTurnCount
  omega

/-- Concurrent heavy diagram/media mounts never exceed `cap`. -/
theorem admitMount_bounded (active cap : Nat) (h : active ≤ cap) :
    (admitMount active cap).2 ≤ cap ∧ ((admitMount active cap).1 = true ↔ active < cap) := by
  by_cases hlt : active < cap
  · simp [admitMount, hlt]
    omega
  · simp [admitMount, hlt]
    exact h

example :
    visibleTurnCount 481 24 0 24 = 24 ∧
    hiddenTurnCount 481 24 0 24 = 457 ∧
    admitMount 7 8 = (true, 8) ∧
    admitMount 8 8 = (false, 8) := by
  decide

end Orb.Transcript
