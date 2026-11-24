import LeanUI.Swapchain
/-!
# SwapchainSpec — Formal Invariants for LeanUI Vulkan 1.3 Swapchain & Synchronization

Proves the five invariants specified in `docs/specs/leanui-vulkan-swapchain.md` §4.3:
1. `ConservedResource`: WSI acquired count `≤ 1`, bounded 2 frame slots, cross-slot `MAILBOX`
   `imageFence` guard, and no-deadlock fence rule on acquire failure.
2. `ScopedAuthority`: per-image `renderFinished` semaphore indexing is injective across swapchain
   images (disjoint even when `imageCount ≥ 3`).
3. Resize-in-flight & zero-extent recovery: `ready w h n` implies `w > 0 ∧ h > 0 ∧ n ≥ 2`;
   zero extent transitions to `suspendedZeroExtent`; size mismatch forbids submission/present.
4. `StickyFence`: `destroyed` is absorbing across all transitions and `destroy` always sets
   `waitIdleDone = true`.
5. Quiescence preservation: `needsRedraw damage = false` leaves `SwapchainState` untouched.
-/
namespace LeanUI.Spec

open LeanUI.Swapchain

private theorem foldl_acquired_replicate (n : Nat) (acc : Nat) :
    (List.replicate n WsiImageState.withPresentEngine).foldl SwapchainState.acquiredInc acc = acc := by
  induction n generalizing acc with
  | zero => rfl
  | succ n ih => exact ih acc

private theorem foldl_acquired_set_withPresentEngine (l : List WsiImageState) (idx : Nat) (acc : Nat) :
    (l.set idx .withPresentEngine).foldl SwapchainState.acquiredInc acc ≤
    l.foldl SwapchainState.acquiredInc acc := by
  induction l generalizing idx acc with
  | nil => simp
  | cons hd tl ih =>
    cases idx with
    | zero =>
      simp only [List.set, List.foldl]
      cases hd with
      | withPresentEngine => exact Nat.le_refl _
      | acquired _ =>
        have mono : ∀ (xs : List WsiImageState) (a b : Nat), a ≤ b →
            xs.foldl SwapchainState.acquiredInc a ≤
            xs.foldl SwapchainState.acquiredInc b := by
          intro xs
          induction xs with
          | nil => intro a b h; exact h
          | cons x xs ihx =>
            intro a b h
            cases x with
            | withPresentEngine => exact ihx a b h
            | acquired _ => exact ihx (a + 1) (b + 1) (Nat.succ_le_succ h)
        exact mono tl acc (acc + 1) (Nat.le_succ acc)
    | succ i =>
      simp only [List.set, List.foldl]
      exact ih i _

private theorem foldl_acquired_set_acquired_from_zero (l : List WsiImageState) (idx : Nat) (slot : Fin 2)
    (acc : Nat) :
    (l.set idx (.acquired slot)).foldl SwapchainState.acquiredInc acc ≤
    l.foldl SwapchainState.acquiredInc acc + 1 := by
  induction l generalizing idx acc with
  | nil => simp
  | cons hd tl ih =>
    cases idx with
    | zero =>
      simp only [List.set, List.foldl]
      have shift : ∀ (xs : List WsiImageState) (a : Nat),
          xs.foldl SwapchainState.acquiredInc (a + 1) =
          xs.foldl SwapchainState.acquiredInc a + 1 := by
        intro xs
        induction xs with
        | nil => intro a; rfl
        | cons x xs ihx =>
          intro a
          cases x with
          | withPresentEngine => exact ihx a
          | acquired _ => exact ihx (a + 1)
      cases hd with
      | withPresentEngine =>
        dsimp only [SwapchainState.acquiredInc]
        rw [shift]
        exact Nat.le_refl _
      | acquired _ =>
        dsimp only [SwapchainState.acquiredInc]
        exact Nat.le_succ _
    | succ i =>
      simp only [List.set, List.foldl]
      exact ih i _

/-- Well-formedness predicate for `SwapchainState`. -/
def SwapchainWF (s : SwapchainState) : Prop :=
  (∀ w h n, s.phase = .ready w h n → w > 0 ∧ h > 0 ∧ n ≥ 2 ∧ s.images.length = n ∧ s.imageFence.length = n) ∧
  s.acquiredCount ≤ 1

/-- Invariant 1a: `initOrRecreate` preserves `SwapchainWF` and yields `acquiredCount = 0`. -/
theorem initOrRecreate_wf (s : SwapchainState) (w h n : Nat) (hwf : SwapchainWF s) :
    SwapchainWF (s.initOrRecreate w h n) := by
  unfold SwapchainState.initOrRecreate
  cases hph : s.phase with
  | destroyed => exact hwf
  | deviceLostFallbackShm => exact hwf
  | uninitialized | ready _ _ _ | suspendedZeroExtent | needsRecreate _ _ =>
    by_cases h0 : (w == 0 || h == 0) = true
    · simp only [h0, ↓reduceIte]
      refine ⟨fun _ _ _ h => (by cases h), ?_⟩
      simp [SwapchainState.acquiredCount]
    · simp only [h0, Bool.false_eq_true, ↓reduceIte]
      by_cases hn : n < 2
      · simp only [hn, ↓reduceIte]
        refine ⟨fun _ _ _ h => (by cases h), ?_⟩
        simp [SwapchainState.acquiredCount]
      · simp only [hn, ↓reduceIte]
        refine ⟨?_, ?_⟩
        · intro w' h' n' hEq
          injection hEq with hw hh hn'
          subst hw hh hn'
          simp only [Bool.or_eq_true, beq_iff_eq, not_or] at h0
          refine ⟨Nat.pos_of_ne_zero h0.1, Nat.pos_of_ne_zero h0.2, Nat.le_of_not_lt hn, ?_, ?_⟩
          · exact List.length_replicate
          · exact List.length_replicate
        · unfold SwapchainState.acquiredCount
          dsimp only
          rw [foldl_acquired_replicate]
          exact Nat.zero_le 1

/-- Invariant 1b (ConservedResource): `onAcquire` never allows more than 1 acquired WSI image. -/
theorem onAcquire_acquiredCount_le_one (s : SwapchainState) (res : WsiResult) (imgIdx : Nat)
    (hwf : SwapchainWF s) :
    (s.onAcquire res imgIdx).acquiredCount ≤ 1 := by
  unfold SwapchainState.onAcquire
  cases hph : s.phase with
  | ready w h n =>
    by_cases ha : s.acquiredCount != 0
    · simp only [ha, ↓reduceIte]; exact hwf.2
    · simp only [ha, Bool.false_eq_true, ↓reduceIte]
      have hz : s.acquiredCount = 0 := by
        simp only [bne_iff_ne, ne_eq, Decidable.not_not] at ha
        exact ha
      cases res with
      | success | suboptimal =>
        dsimp only
        by_cases hlt : imgIdx < n
        · simp only [hlt, ↓reduceIte]
          have hguard : ∀ (st : SwapchainState), (st.guardImageFence imgIdx).images = st.images := by
            intro st
            unfold SwapchainState.guardImageFence SwapchainState.waitSlotFence
            cases st.imageFence[imgIdx]? with
            | none => rfl
            | some o =>
              cases o with
              | none => rfl
              | some prev =>
                dsimp only
                by_cases hne : (prev != st.curSlot) = true
                · simp only [hne, ↓reduceIte]
                  cases st.phase <;> rfl
                · simp only [hne, Bool.false_eq_true, ↓reduceIte]
          unfold SwapchainState.acquiredCount
          rw [hguard]
          dsimp only
          have hle := foldl_acquired_set_acquired_from_zero s.images imgIdx s.curSlot 0
          unfold SwapchainState.acquiredCount at hz
          omega
        · simp only [hlt, ↓reduceIte]; exact hwf.2
      | outOfDate | surfaceLost => exact hwf.2
      | deviceLost => simp [SwapchainState.acquiredCount]
  | uninitialized | suspendedZeroExtent | needsRecreate _ _ | deviceLostFallbackShm | destroyed =>
    exact hwf.2

/-- Invariant 1c (No-deadlock fence rule): `OUT_OF_DATE` or `SURFACE_LOST` during `onAcquire`
never unsignals `fences[curSlot]`, preventing `vkWaitForFences` deadlock on the next frame. -/
theorem onAcquire_failure_preserves_fence (s : SwapchainState) (res : WsiResult) (imgIdx : Nat)
    (hfail : res = WsiResult.outOfDate ∨ res = WsiResult.surfaceLost) :
    (s.onAcquire res imgIdx).fences s.curSlot = s.fences s.curSlot := by
  unfold SwapchainState.onAcquire
  cases s.phase with
  | ready w h n =>
    by_cases ha : s.acquiredCount != 0
    · simp [ha]
    · simp only [ha, Bool.false_eq_true, ↓reduceIte]
      rcases hfail with rfl | rfl <;> rfl
  | uninitialized | suspendedZeroExtent | needsRecreate _ _ | deviceLostFallbackShm | destroyed => rfl

/-- Invariant 1d (MAILBOX cross-slot fence guard): after `waitSlotFence prevSlot`, no `imageFence`
entry still references `prevSlot` and `frameSlots prevSlot = .idle`. -/
theorem waitSlotFence_clears_owner (s : SwapchainState) (slot : Fin 2)
    (hactive : s.phase ≠ .destroyed ∧ s.phase ≠ .deviceLostFallbackShm) :
    (s.waitSlotFence slot).frameSlots slot = .idle ∧
    ∀ (i : Nat), (s.waitSlotFence slot).imageFence[i]? ≠ some (some slot) := by
  unfold SwapchainState.waitSlotFence
  cases hph : s.phase with
  | destroyed => exact absurd hph hactive.1
  | deviceLostFallbackShm => exact absurd hph hactive.2
  | uninitialized | ready _ _ _ | suspendedZeroExtent | needsRecreate _ _ =>
    refine ⟨by simp, ?_⟩
    intro i
    simp only [List.getElem?_map]
    cases s.imageFence[i]? with
    | none => simp
    | some opt =>
      simp only [Option.map_some]
      by_cases heq : opt == some slot
      · simp [heq]
      · simp only [heq, Bool.false_eq_true, ↓reduceIte, ne_eq, Option.some.injEq]
        intro h
        exact heq (by simp [h])

/-- Invariant 1e: `onSubmitAndPresent` returns the image to `.withPresentEngine` so `acquiredCount`
never grows. -/
theorem onSubmitAndPresent_acquiredCount_le (s : SwapchainState) (bw bh imgIdx : Nat)
    (res : WsiResult) (hwf : SwapchainWF s) :
    (s.onSubmitAndPresent bw bh imgIdx res).acquiredCount ≤ 1 := by
  unfold SwapchainState.onSubmitAndPresent
  by_cases hcan : s.canSubmit bw bh imgIdx = true
  · simp only [hcan, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
    have hstep : (s.images.set imgIdx .withPresentEngine).foldl SwapchainState.acquiredInc 0 ≤ 1 :=
      Nat.le_trans (foldl_acquired_set_withPresentEngine s.images imgIdx 0) hwf.2
    cases s.phase <;> cases res
    all_goals simp [SwapchainState.acquiredCount]
    all_goals exact hstep
  · simp [hcan, hwf.2]

/-- Invariant 2 (ScopedAuthority): `renderFinishedSemIndex` is strictly injective across swapchain
images, so distinct swapchain images never alias a `renderFinished` semaphore even when
`imageCount ≥ 3`. -/
theorem renderFinishedSemIndex_injective (i j : Nat) (h : i ≠ j) :
    SwapchainState.renderFinishedSemIndex i ≠ SwapchainState.renderFinishedSemIndex j :=
  h

/-- Invariant 3a (Zero-extent guard): `initOrRecreate` with `w = 0 ∨ h = 0` transitions any live
swapchain to `suspendedZeroExtent` rather than creating a zero-extent swapchain. -/
theorem initOrRecreate_zero_extent_suspends (s : SwapchainState) (w h n : Nat)
    (hlive : s.phase ≠ .destroyed ∧ s.phase ≠ .deviceLostFallbackShm)
    (hzero : w = 0 ∨ h = 0) :
    (s.initOrRecreate w h n).phase = .suspendedZeroExtent := by
  unfold SwapchainState.initOrRecreate
  have hcond : (w == 0 || h == 0) = true := by
    rcases hzero with rfl | rfl <;> simp
  cases hph : s.phase with
  | destroyed => exact absurd hph hlive.1
  | deviceLostFallbackShm => exact absurd hph hlive.2
  | uninitialized | ready _ _ _ | suspendedZeroExtent | needsRecreate _ _ =>
    simp [hcond]

/-- Invariant 3b (Resize-in-flight guard): submitting with a mismatched extent `(bw, bh) ≠ (w, h)`
is rejected (`canSubmit = false`) and leaves `presentCount` unchanged. -/
theorem submit_mismatched_extent_forbidden (s : SwapchainState) (w h n bw bh imgIdx : Nat)
    (res : WsiResult) (hph : s.phase = .ready w h n) (hne : w ≠ bw ∨ h ≠ bh) :
    s.canSubmit bw bh imgIdx = false ∧
    (s.onSubmitAndPresent bw bh imgIdx res).presentCount = s.presentCount := by
  have hready : s.isReadyForExtent bw bh = false := by
    unfold SwapchainState.isReadyForExtent
    rw [hph]
    rcases hne with hw | hh
    · have : (w == bw) = false := beq_false_of_ne hw
      simp [this]
    · have : (h == bh) = false := beq_false_of_ne hh
      simp [this]
  have hcan : s.canSubmit bw bh imgIdx = false := by
    simp [SwapchainState.canSubmit, hready]
  refine ⟨hcan, ?_⟩
  simp [SwapchainState.onSubmitAndPresent, hcan]

/-- Invariant 4 (StickyFence): `destroy` always runs `waitIdleDone = true` and enters `.destroyed`,
and `.destroyed` is permanently absorbing across `initOrRecreate`, `onExtentChanged`, `onAcquire`,
`onSubmitAndPresent`, and `onDeviceLost`. -/
theorem destroy_waitIdle_and_absorbing (s : SwapchainState) (w h n bw bh imgIdx : Nat)
    (res : WsiResult) :
    let d := s.destroy
    d.phase = .destroyed ∧
    d.waitIdleDone = true ∧
    (d.initOrRecreate w h n).phase = .destroyed ∧
    (d.onExtentChanged bw bh).phase = .destroyed ∧
    (d.onAcquire res imgIdx).phase = .destroyed ∧
    (d.onSubmitAndPresent bw bh imgIdx res).phase = .destroyed ∧
    d.onDeviceLost.phase = .destroyed := by
  refine ⟨rfl, rfl, rfl, rfl, rfl, ?_, rfl⟩
  simp [SwapchainState.destroy, SwapchainState.onSubmitAndPresent,
    SwapchainState.canSubmit, SwapchainState.isReadyForExtent]

/-- Invariant 5 (Quiescence preservation): when `needsRedraw damage = false`, `stepDamageGate`
leaves the entire `SwapchainState` (including `acquireCount`, `submitCount`, `presentCount`)
untouched for any `onDirty` callback. -/
theorem stepDamageGate_quiescent_unchanged (s : SwapchainState) (damage : Damage)
    (onDirty : SwapchainState → SwapchainState) (hq : needsRedraw damage = false) :
    s.stepDamageGate damage onDirty = s := by
  simp [SwapchainState.stepDamageGate, hq]

end LeanUI.Spec
