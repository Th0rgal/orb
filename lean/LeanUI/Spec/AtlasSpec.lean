import LeanUI.Kernel
/-!
# AtlasSpec — shelf allocator non-overlap and per-trace cache soundness

Shelf occupancy is shared state: it is specified by an ownership relation that only
grows (`owns_mono`) and that every new slot is fresh against (`alloc_fresh`).
-/
namespace LeanUI.Spec

/-- Texel `(px, py)` is already handed out (or shadowed by a shelf's used prefix). -/
def Owns (a : Atlas) (px py : Nat) : Prop :=
  ∃ s, s ∈ a.shelves ∧ s.y ≤ py ∧ py < s.y + s.h ∧ px < s.used

/-- Shelves are stacked top to bottom without gaps, starting at row `y0`. -/
def Stacked : Nat → List Shelf → Nat → Prop
  | y0, [], y1 => y0 = y1
  | y0, s :: rest, y1 => s.y = y0 ∧ Stacked (y0 + s.h) rest y1

/-- Well-formed atlas: stacked shelves ending at `nextY`, all inside the texture. -/
def WF (a : Atlas) : Prop :=
  Stacked 0 a.shelves a.nextY ∧ a.nextY ≤ a.height ∧ ∀ s, s ∈ a.shelves → s.used ≤ a.width

private theorem stacked_append (l : List Shelf) : ∀ (pre : List Shelf) (y0 y1 : Nat),
    Stacked y0 (pre ++ l) y1 ↔ ∃ ym, Stacked y0 pre ym ∧ Stacked ym l y1 := by
  intro pre
  induction pre with
  | nil => intro y0 y1; simp [Stacked]
  | cons s pre ih =>
    intro y0 y1
    simp only [List.cons_append, Stacked, ih]
    constructor
    · rintro ⟨h0, ym, h1, h2⟩; exact ⟨ym, ⟨h0, h1⟩, h2⟩
    · rintro ⟨ym, ⟨h0, h1⟩, h2⟩; exact ⟨h0, ym, h1, h2⟩

private theorem stacked_bounds : ∀ (l : List Shelf) (y0 y1 : Nat), Stacked y0 l y1 →
    y0 ≤ y1 ∧ ∀ t, t ∈ l → y0 ≤ t.y ∧ t.y + t.h ≤ y1 := by
  intro l
  induction l with
  | nil => intro y0 y1 h; simp [Stacked] at h; simp [h]
  | cons s l ih =>
    intro y0 y1 h
    obtain ⟨h0, h1⟩ := h
    obtain ⟨h2, h3⟩ := ih _ _ h1
    refine ⟨by omega, ?_⟩
    intro t ht
    rcases List.mem_cons.mp ht with rfl | ht
    · omega
    · have := h3 t ht; omega

private theorem fitShelf_some (width w h : Nat) : ∀ (l l' : List Shelf) (r : Rect),
    Atlas.fitShelf width w h l = some (r, l') →
    ∃ pre s post, l = pre ++ s :: post ∧ l' = pre ++ { s with used := s.used + w } :: post ∧
      r = Atlas.slot s w h ∧ h ≤ s.h ∧ s.used + w ≤ width := by
  intro l
  induction l with
  | nil => intro l' r hf; simp [Atlas.fitShelf] at hf
  | cons s rest ih =>
    intro l' r hf
    unfold Atlas.fitShelf at hf
    by_cases hc : h ≤ s.h ∧ s.used + w ≤ width
    · simp only [hc, and_self, ite_true] at hf
      injection hf with hf
      injection hf with hr hl
      exact ⟨[], s, rest, rfl, hl.symm, hr.symm, hc.1, hc.2⟩
    · simp only [hc, ite_false] at hf
      cases hfit : Atlas.fitShelf width w h rest with
      | none => simp [hfit] at hf
      | some p =>
        obtain ⟨r0, rest'⟩ := p
        simp [hfit] at hf
        obtain ⟨hr, hl⟩ := hf
        obtain ⟨pre, s0, post, e1, e2, e3, e4, e5⟩ := ih rest' r0 hfit
        exact ⟨s :: pre, s0, post, by simp [e1], by simp [← hl, e2], by rw [← hr]; exact e3, e4, e5⟩

private theorem alloc_cases (a a' : Atlas) (w h : Nat) (r : Rect)
    (h₁ : a.alloc w h = some (r, a')) :
    w ≤ a.width ∧
    ((∃ pre s post, a.shelves = pre ++ s :: post ∧
        a' = { a with shelves := pre ++ { s with used := s.used + w } :: post } ∧
        r = Atlas.slot s w h ∧ h ≤ s.h ∧ s.used + w ≤ a.width) ∨
     (a.nextY + h ≤ a.height ∧ r = { x := 0, y := a.nextY, w := w, h := h } ∧
        a' = { a with shelves := a.shelves ++ [{ y := a.nextY, h := h, used := w }],
                      nextY := a.nextY + h })) := by
  unfold Atlas.alloc at h₁
  by_cases hg : w = 0 ∨ h = 0 ∨ w > a.width
  · simp [hg] at h₁
  · simp only [hg, ite_false] at h₁
    refine ⟨by omega, ?_⟩
    cases hfit : Atlas.fitShelf a.width w h a.shelves with
    | some p =>
      obtain ⟨r0, l'⟩ := p
      simp [hfit] at h₁
      obtain ⟨hr, ha⟩ := h₁
      obtain ⟨pre, s, post, e1, e2, e3, e4, e5⟩ := fitShelf_some _ _ _ _ _ _ hfit
      exact Or.inl ⟨pre, s, post, e1, by rw [← ha, e2], by rw [← hr]; exact e3, e4, e5⟩
    | none =>
      simp [hfit] at h₁
      obtain ⟨hy, hr, ha⟩ := h₁
      exact Or.inr ⟨hy, hr.symm, ha.symm⟩

private theorem contains_nat (x y w h px py : Nat)
    (hin : Rect.contains { x := x, y := y, w := w, h := h } px py = true) :
    x ≤ px ∧ px < x + w ∧ y ≤ py ∧ py < y + h := by
  simp only [Rect.contains, Rect.right, Rect.bottom, Bool.and_eq_true] at hin
  obtain ⟨⟨⟨a, b⟩, c⟩, d⟩ := hin
  have := of_decide_eq_true a
  have := of_decide_eq_true b
  have := of_decide_eq_true c
  have := of_decide_eq_true d
  omega

theorem wf_empty (w h : Nat) : WF { width := w, height := h } := by
  exact ⟨rfl, Nat.zero_le _, by intro s hs; cases hs⟩

theorem alloc_wf (a a' : Atlas) (w h : Nat) (r : Rect) (hwf : WF a)
    (h₁ : a.alloc w h = some (r, a')) : WF a' := by
  obtain ⟨hst, hny, hu⟩ := hwf
  obtain ⟨hw, ⟨pre, s, post, e1, e2, e3, e4, e5⟩ | ⟨hy, hr, ha⟩⟩ := alloc_cases a a' w h r h₁
  · subst e2
    rw [e1] at hst hu
    refine ⟨?_, hny, ?_⟩
    · obtain ⟨ym, hp, hs⟩ := (stacked_append _ _ _ _).mp hst
      exact (stacked_append _ _ _ _).mpr ⟨ym, hp, hs⟩
    · intro t ht
      rcases List.mem_append.mp ht with ht | ht
      · exact hu t (List.mem_append_left _ ht)
      · rcases List.mem_cons.mp ht with rfl | ht
        · exact e5
        · exact hu t (List.mem_append_right _ (List.mem_cons_of_mem _ ht))
  · subst ha
    refine ⟨?_, hy, ?_⟩
    · exact (stacked_append _ _ _ _).mpr ⟨a.nextY, hst, rfl, rfl⟩
    · intro t ht
      rcases List.mem_append.mp ht with ht | ht
      · exact hu t ht
      · simp at ht
        subst ht
        exact hw

/-- The slot has exactly the requested size. -/
theorem alloc_size (a a' : Atlas) (w h : Nat) (r : Rect)
    (h₁ : a.alloc w h = some (r, a')) : r.w = w ∧ r.h = h := by
  obtain ⟨_, ⟨pre, s, post, e1, e2, e3, e4, e5⟩ | ⟨hy, hr, ha⟩⟩ := alloc_cases a a' w h r h₁
  · subst e3
    exact ⟨rfl, rfl⟩
  · subst hr
    exact ⟨rfl, rfl⟩

/-- The slot lies inside the texture. -/
theorem alloc_in_bounds (a a' : Atlas) (w h : Nat) (r : Rect) (hwf : WF a)
    (h₁ : a.alloc w h = some (r, a')) :
    r.right ≤ a.width ∧ r.bottom ≤ a.height := by
  obtain ⟨hst, hny, hu⟩ := hwf
  obtain ⟨hw, ⟨pre, s, post, e1, e2, e3, e4, e5⟩ | ⟨hy, hr, ha⟩⟩ := alloc_cases a a' w h r h₁
  · have hb := (stacked_bounds _ _ _ hst).2 s (by rw [e1]; simp)
    subst e3
    simp only [Atlas.slot, Rect.right, Rect.bottom]
    omega
  · subst hr
    simp only [Rect.right, Rect.bottom]
    omega

/-- Freshness: no texel of the new slot was owned before. -/
theorem alloc_fresh (a a' : Atlas) (w h : Nat) (r : Rect) (hwf : WF a)
    (h₁ : a.alloc w h = some (r, a')) (px py : Nat)
    (hin : r.contains px py = true) : ¬ Owns a px py := by
  obtain ⟨hst, hny, hu⟩ := hwf
  rintro ⟨t, ht, ht1, ht2, ht3⟩
  obtain ⟨hw, ⟨pre, s, post, e1, e2, e3, e4, e5⟩ | ⟨hy, hr, ha⟩⟩ := alloc_cases a a' w h r h₁
  · subst e3
    have hin := contains_nat s.used s.y w h px py hin
    rw [e1] at hst ht
    obtain ⟨ym, hpre, hsy, hpost⟩ := (stacked_append _ _ _ _).mp hst
    rcases List.mem_append.mp ht with ht | ht
    · have := (stacked_bounds _ _ _ hpre).2 t ht
      omega
    · rcases List.mem_cons.mp ht with rfl | ht
      · omega
      · have := (stacked_bounds _ _ _ hpost).2 t ht
        omega
  · subst hr
    have hin := contains_nat 0 a.nextY w h px py hin
    have := (stacked_bounds _ _ _ hst).2 t ht
    omega

/-- The new slot is owned afterwards. -/
theorem alloc_owns (a a' : Atlas) (w h : Nat) (r : Rect) (hwf : WF a)
    (h₁ : a.alloc w h = some (r, a')) (px py : Nat)
    (hin : r.contains px py = true) : Owns a' px py := by
  have _ := hwf
  obtain ⟨hw, ⟨pre, s, post, e1, e2, e3, e4, e5⟩ | ⟨hy, hr, ha⟩⟩ := alloc_cases a a' w h r h₁
  · subst e3 e2
    have hin := contains_nat s.used s.y w h px py hin
    refine ⟨{ s with used := s.used + w }, by simp, ?_, ?_, ?_⟩ <;> simp only <;> omega
  · subst hr ha
    have hin := contains_nat 0 a.nextY w h px py hin
    refine ⟨{ y := a.nextY, h := h, used := w }, by simp, ?_, ?_, ?_⟩ <;> simp only <;> omega

/-- Ownership only grows: earlier glyphs are never handed out again. -/
theorem owns_mono (a a' : Atlas) (w h : Nat) (r : Rect)
    (h₁ : a.alloc w h = some (r, a')) (px py : Nat) (ho : Owns a px py) : Owns a' px py := by
  obtain ⟨t, ht, ht1, ht2, ht3⟩ := ho
  obtain ⟨hw, ⟨pre, s, post, e1, e2, e3, e4, e5⟩ | ⟨hy, hr, ha⟩⟩ := alloc_cases a a' w h r h₁
  · subst e2
    rw [e1] at ht
    rcases List.mem_append.mp ht with ht | ht
    · exact ⟨t, by simp [ht], ht1, ht2, ht3⟩
    · rcases List.mem_cons.mp ht with rfl | ht
      · exact ⟨{ t with used := t.used + w }, by simp, ht1, ht2, Nat.lt_add_right _ ht3⟩
      · exact ⟨t, by simp [ht], ht1, ht2, ht3⟩
  · subst ha
    exact ⟨t, List.mem_append_left _ ht, ht1, ht2, ht3⟩

/-- Corollary: two successive allocations never share a texel. -/
theorem alloc_disjoint (a a₁ a₂ : Atlas) (w₁ h₁ w₂ h₂ : Nat) (r₁ r₂ : Rect) (hwf : WF a)
    (e₁ : a.alloc w₁ h₁ = some (r₁, a₁)) (e₂ : a₁.alloc w₂ h₂ = some (r₂, a₂)) (px py : Nat) :
    ¬ (r₁.contains px py = true ∧ r₂.contains px py = true) := by
  rintro ⟨c1, c2⟩
  exact alloc_fresh a₁ a₂ w₂ h₂ r₂ (alloc_wf a a₁ w₁ h₁ r₁ hwf e₁) e₂ px py c2
    (alloc_owns a a₁ w₁ h₁ r₁ hwf e₁ px py c1)

/-- Liveness: a glyph that fits the width and the remaining rows is always placed. -/
theorem alloc_live (a : Atlas) (w h : Nat) (hw0 : 0 < w) (hw : w ≤ a.width)
    (hh0 : 0 < h) (hroom : a.nextY + h ≤ a.height) : (a.alloc w h).isSome = true := by
  unfold Atlas.alloc
  have hg : ¬ (w = 0 ∨ h = 0 ∨ w > a.width) := by omega
  simp only [hg, ite_false]
  cases hf : Atlas.fitShelf a.width w h a.shelves with
  | some p => rfl
  | none => simp [hroom]

theorem reset_wf (a : Atlas) : WF a.reset := by
  exact wf_empty a.width a.height

theorem reset_clears_owns (a : Atlas) (px py : Nat) : ¬ Owns a.reset px py := by
  rintro ⟨s, hs, _⟩
  cases hs

theorem reset_preserves_dims (a b : Atlas) :
    a.reset = b.reset ↔ a.width = b.width ∧ a.height = b.height := by
  simp [Atlas.reset]

private theorem allocPadded_unfold (a a' : Atlas) (pad w h : Nat) (r : Rect)
    (h₁ : a.allocPadded pad w h = some (r, a')) :
    0 < w ∧ 0 < h ∧ ∃ r0, a.alloc (w + pad) (h + pad) = some (r0, a') ∧
      r = { x := r0.x, y := r0.y, w := w, h := h } := by
  unfold Atlas.allocPadded at h₁
  by_cases hg : w = 0 ∨ h = 0
  · simp [hg] at h₁
  · simp only [hg, ite_false] at h₁
    cases ha : a.alloc (w + pad) (h + pad) with
    | none => simp [ha] at h₁
    | some p =>
      obtain ⟨r0, a0⟩ := p
      simp [ha] at h₁
      obtain ⟨hr, ha'⟩ := h₁
      exact ⟨by omega, by omega, r0, by rw [← ha'], hr.symm⟩

theorem allocPadded_wf (a a' : Atlas) (pad w h : Nat) (r : Rect) (hwf : WF a)
    (h₁ : a.allocPadded pad w h = some (r, a')) : WF a' := by
  obtain ⟨_, _, r0, ha, _⟩ := allocPadded_unfold a a' pad w h r h₁
  exact alloc_wf a a' (w + pad) (h + pad) r0 hwf ha

theorem allocPadded_size (a a' : Atlas) (pad w h : Nat) (r : Rect)
    (h₁ : a.allocPadded pad w h = some (r, a')) : r.w = w ∧ r.h = h := by
  obtain ⟨_, _, r0, _, hr⟩ := allocPadded_unfold a a' pad w h r h₁
  subst hr
  exact ⟨rfl, rfl⟩

/-- Padded allocation reserves the `pad` guard band around the returned glyph rect, so no later
allocation can place a texel inside `(w + pad) × (h + pad)`. -/
theorem allocPadded_guard_owns (a a' : Atlas) (pad w h : Nat) (r : Rect) (hwf : WF a)
    (h₁ : a.allocPadded pad w h = some (r, a')) (px py : Nat)
    (hin : Rect.contains { x := r.x, y := r.y, w := (w + pad : Nat), h := (h + pad : Nat) } px py = true) :
    Owns a' px py := by
  obtain ⟨_, _, r0, ha, hr⟩ := allocPadded_unfold a a' pad w h r h₁
  obtain ⟨hw0, hh0⟩ := alloc_size a a' (w + pad) (h + pad) r0 ha
  have hrx : r.x = r0.x := by rw [hr]
  have hry : r.y = r0.y := by rw [hr]
  have heq : ({ x := r.x, y := r.y, w := (w + pad : Nat), h := (h + pad : Nat) } : Rect) = r0 := by
    cases r0
    simp only [Rect.mk.injEq] at hw0 hh0 hrx hry ⊢
    exact ⟨hrx, hry, hw0.symm, hh0.symm⟩
  rw [heq] at hin
  exact alloc_owns a a' (w + pad) (h + pad) r0 hwf ha px py hin

theorem allocPadded_disjoint_guard (a a₁ a₂ : Atlas) (pad w₁ h₁ w₂ h₂ : Nat) (r₁ r₂ : Rect)
    (hwf : WF a)
    (e₁ : a.allocPadded pad w₁ h₁ = some (r₁, a₁))
    (e₂ : a₁.allocPadded pad w₂ h₂ = some (r₂, a₂)) (px py : Nat) :
    ¬ (Rect.contains { x := r₁.x, y := r₁.y, w := (w₁ + pad : Nat), h := (h₁ + pad : Nat) } px py = true ∧
       Rect.contains { x := r₂.x, y := r₂.y, w := (w₂ + pad : Nat), h := (h₂ + pad : Nat) } px py = true) := by
  rintro ⟨c1, c2⟩
  obtain ⟨_, _, r20, ha2, hr2⟩ := allocPadded_unfold a₁ a₂ pad w₂ h₂ r₂ e₂
  obtain ⟨hw20, hh20⟩ := alloc_size a₁ a₂ (w₂ + pad) (h₂ + pad) r20 ha2
  have hrx : r₂.x = r20.x := by rw [hr2]
  have hry : r₂.y = r20.y := by rw [hr2]
  have heq : ({ x := r₂.x, y := r₂.y, w := (w₂ + pad : Nat), h := (h₂ + pad : Nat) } : Rect) = r20 := by
    cases r20
    simp only [Rect.mk.injEq] at hw20 hh20 hrx hry ⊢
    exact ⟨hrx, hry, hw20.symm, hh20.symm⟩
  rw [heq] at c2
  exact alloc_fresh a₁ a₂ (w₂ + pad) (h₂ + pad) r20 (allocPadded_wf a a₁ pad w₁ h₁ r₁ hwf e₁) ha2 px py c2
    (allocPadded_guard_owns a a₁ pad w₁ h₁ r₁ hwf e₁ px py c1)

/-- Multi-page liveness: a glyph fitting page dimensions `pw × ph` always succeeds on any page list. -/
theorem allocPages_live (pw ph w h : Nat) (pages : List Atlas)
    (hw0 : 0 < w) (hw : w ≤ pw) (hh0 : 0 < h) (hh : h ≤ ph) :
    (Atlas.allocPages pw ph w h pages).isSome = true := by
  induction pages with
  | nil =>
    unfold Atlas.allocPages
    have hl := alloc_live { width := pw, height := ph } w h hw0 hw hh0 (by simp [hh])
    cases ha : ({ width := pw, height := ph } : Atlas).alloc w h with
    | none => simp [ha] at hl
    | some p => rfl
  | cons a rest ih =>
    unfold Atlas.allocPages
    cases ha : a.alloc w h with
    | some p => rfl
    | none =>
      cases hp : Atlas.allocPages pw ph w h rest with
      | none => simp [hp] at ih
      | some q => rfl

/-- Multi-page soundness: the returned page index points to a page in the updated list that owns the slot. -/
theorem allocPages_sound (pw ph w h : Nat) (pages pages' : List Atlas) (idx : Nat) (r : Rect)
    (hwf : ∀ a, a ∈ pages → WF a)
    (hp : Atlas.allocPages pw ph w h pages = some (idx, r, pages')) :
    idx < pages'.length ∧ r.w = w ∧ r.h = h ∧ (∀ a, a ∈ pages' → WF a) ∧
      ∀ (px py : Nat), r.contains px py = true → ∃ a', pages'[idx]? = some a' ∧ Owns a' px py := by
  induction pages generalizing pages' idx with
  | nil =>
    unfold Atlas.allocPages at hp
    cases ha : ({ width := pw, height := ph } : Atlas).alloc w h with
    | none => simp [ha] at hp
    | some p =>
      obtain ⟨r0, a'⟩ := p
      simp [ha] at hp
      obtain ⟨rfl, rfl, rfl⟩ := hp
      have hwf' := alloc_wf _ _ w h r0 (wf_empty pw ph) ha
      have hsz := alloc_size _ _ w h r0 ha
      refine ⟨by simp, hsz.1, hsz.2, ?_, ?_⟩
      · intro x hx
        simp at hx
        subst hx
        exact hwf'
      · intro px py hin
        exact ⟨a', rfl, alloc_owns _ _ w h r0 (wf_empty pw ph) ha px py hin⟩
  | cons a rest ih =>
    unfold Atlas.allocPages at hp
    cases ha : a.alloc w h with
    | some p =>
      obtain ⟨r0, a'⟩ := p
      simp [ha] at hp
      obtain ⟨rfl, rfl, rfl⟩ := hp
      have hwfa := hwf a (List.mem_cons_self ..)
      have hwf' := alloc_wf _ _ w h r0 hwfa ha
      have hsz := alloc_size _ _ w h r0 ha
      refine ⟨by simp, hsz.1, hsz.2, ?_, ?_⟩
      · intro x hx
        rcases List.mem_cons.mp hx with rfl | hx
        · exact hwf'
        · exact hwf x (List.mem_cons_of_mem _ hx)
      · intro px py hin
        exact ⟨a', rfl, alloc_owns _ _ w h r0 hwfa ha px py hin⟩
    | none =>
      cases hrest : Atlas.allocPages pw ph w h rest with
      | none => simp [ha, hrest] at hp
      | some q =>
        obtain ⟨idx0, r0, rest'⟩ := q
        simp [ha, hrest] at hp
        obtain ⟨hidx, hr, hpages⟩ := hp
        subst hidx hr hpages
        obtain ⟨hlt, hrw, hrh, hwfr, hown⟩ :=
          ih rest' idx0 (fun x hx => hwf x (List.mem_cons_of_mem _ hx)) hrest
        refine ⟨by simp [hlt], hrw, hrh, ?_, ?_⟩
        · intro x hx
          rcases List.mem_cons.mp hx with rfl | hx
          · exact hwf x (List.mem_cons_self ..)
          · exact hwfr x hx
        · intro px py hin
          simpa using hown px py hin

/-- Cache soundness on a trace: if every entry was produced by `f` on a key of the trace,
and the hash is collision-free on that trace, a hit returns `f k`. -/
theorem cache_lookup_sound {α β : Type} (hash : α → UInt64) (f : α → β) (keys : List α)
    (c : HashCache β) (hcf : CollisionFreeOn hash keys)
    (hent : ∀ e, e ∈ c.entries → ∃ k', k' ∈ keys ∧ e = (hash k', f k'))
    (k : α) (hk : k ∈ keys) (v : β) (hl : c.lookup hash k = some v) : v = f k := by
  unfold HashCache.lookup at hl
  cases hf : c.entries.find? (·.1 == hash k) with
  | none => simp [hf] at hl
  | some e =>
    simp [hf] at hl
    have hp := List.find?_some hf
    obtain ⟨k', hk', he⟩ := hent e (List.mem_of_find?_eq_some hf)
    subst he
    simp at hp
    have := hcf k' hk' k hk hp
    subst this
    exact hl.symm

/-- A freshly inserted key is found. -/
theorem cache_lookup_insert {α β : Type} (hash : α → UInt64) (c : HashCache β) (k : α) (v : β) :
    (c.insert hash k v).lookup hash k = some v := by
  simp [HashCache.insert, HashCache.lookup]

end LeanUI.Spec
