import LeanUI.Kernel
/-!
# DamageSpec — dirty-rect union soundness and zero-redraw quiescence
-/
namespace LeanUI.Spec

private theorem contains_iff (r : Rect) (px py : Int) :
    r.contains px py = true ↔ r.x ≤ px ∧ px < r.x + r.w ∧ r.y ≤ py ∧ py < r.y + r.h := by
  unfold Rect.contains Rect.right Rect.bottom
  constructor
  · intro h
    simp only [Bool.and_eq_true] at h
    obtain ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩ := h
    exact ⟨of_decide_eq_true h1, of_decide_eq_true h2, of_decide_eq_true h3, of_decide_eq_true h4⟩
  · rintro ⟨h1, h2, h3, h4⟩
    simp only [Bool.and_eq_true]
    exact ⟨⟨⟨decide_eq_true h1, decide_eq_true h2⟩, decide_eq_true h3⟩, decide_eq_true h4⟩

private theorem union_contains (a r : Rect) (px py : Int)
    (h : a.contains px py = true ∨ r.contains px py = true) :
    (a.union r).contains px py = true := by
  rw [contains_iff] at h ⊢
  rw [contains_iff] at h
  simp only [Rect.union, Rect.right, Rect.bottom]; omega

/-- Soundness: every point of an added rect is covered afterwards. -/
theorem damage_add_sound (d : Damage) (r : Rect) (px py : Int)
    (h : r.contains px py = true) : (d.add r).covers px py = true := by
  have hne : r.isEmpty = false := by
    have h' := (contains_iff r px py).1 h
    simp [Rect.isEmpty]; omega
  cases d with
  | none => rw [show Damage.add none r = some r by simp [Damage.add, hne]]; exact h
  | some a =>
    rw [show Damage.add (some a) r = some (a.union r) by simp [Damage.add, hne]]
    exact union_contains a r px py (Or.inr h)

/-- Monotonicity: adding a rect never uncovers a point. -/
theorem damage_add_mono (d : Damage) (r : Rect) (px py : Int)
    (h : d.covers px py = true) : (d.add r).covers px py = true := by
  cases d with
  | none => simp [Damage.covers] at h
  | some a =>
    cases hr : r.isEmpty
    · rw [show Damage.add (some a) r = some (a.union r) by simp [Damage.add, hr]]
      exact union_contains a r px py (Or.inl h)
    · rw [show Damage.add (some a) r = some a by simp [Damage.add, hr]]; exact h

/-- Empty rects are a no-op (explicit frame). -/
theorem damage_add_empty (d : Damage) (r : Rect) (h : r.isEmpty = true) : d.add r = d := by
  simp [Damage.add, h]

private theorem foldl_add_isSome (rects : List Rect) (d : Damage) :
    needsRedraw (rects.foldl Damage.add d) = true
      ↔ (needsRedraw d = true ∨ ∃ r, r ∈ rects ∧ r.isEmpty = false) := by
  induction rects generalizing d with
  | nil => simp
  | cons r rs ih =>
    rw [List.foldl_cons, ih]
    cases hr : r.isEmpty <;> cases d <;> simp [Damage.add, needsRedraw, hr]

/-- Quiescence, both directions: a frame is submitted iff some non-empty rect was dirtied. -/
theorem redraw_iff_dirty (rects : List Rect) :
    needsRedraw (rects.foldl Damage.add none) = true ↔ ∃ r, r ∈ rects ∧ r.isEmpty = false := by
  rw [foldl_add_isSome]; simp [needsRedraw]

/-- Tightness: the union is the least box — any box enclosing both inputs encloses it. -/
theorem union_least (a r q : Rect)
    (hax : q.x ≤ a.x) (hrx : q.x ≤ r.x) (har : a.right ≤ q.right) (hrr : r.right ≤ q.right)
    (hay : q.y ≤ a.y) (hry : q.y ≤ r.y) (hab : a.bottom ≤ q.bottom) (hrb : r.bottom ≤ q.bottom) :
    q.x ≤ (a.union r).x ∧ (a.union r).right ≤ q.right ∧
      q.y ≤ (a.union r).y ∧ (a.union r).bottom ≤ q.bottom := by
  simp only [Rect.union, Rect.right, Rect.bottom] at *; omega

/-- Well-formed damage never stores an empty rect (an empty one would inflate later unions). -/
def DamageWF (d : Damage) : Prop := ∀ a, d = some a → a.isEmpty = false

theorem damage_add_wf (d : Damage) (r : Rect) (h : DamageWF d) : DamageWF (d.add r) := by
  intro a ha
  cases hr : r.isEmpty
  · cases d with
    | none =>
      simp [Damage.add, hr] at ha
      subst ha; exact hr
    | some b =>
      simp [Damage.add, hr] at ha
      subst ha
      have hb := h b rfl
      simp [Rect.isEmpty] at hr hb ⊢
      simp only [Rect.union, Rect.right, Rect.bottom]; omega
  · rw [damage_add_empty d r hr] at ha; exact h a ha

end LeanUI.Spec
