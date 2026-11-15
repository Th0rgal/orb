import LeanUI.Kernel
/-!
# FocusSpec — single focus owner, modal trap confinement, hit-test routing

"At most one owner" holds by construction (`owner : Option EntityId`) and is not restated.
-/
namespace LeanUI.Spec
open FocusState

/-- Granted branch: the owner changes, the trap stack is framed. -/
theorem request_granted (s : FocusState) (id : EntityId) (h : s.admits id = true) :
    (s.request id).owner = some id ∧ (s.request id).traps = s.traps := by
  simp [request, h]

/-- Refused branch: explicit rollback. -/
theorem request_refused (s : FocusState) (id : EntityId) (h : s.admits id = false) :
    s.request id = s := by
  simp [request, h]

theorem request_confined (s : FocusState) (id : EntityId) (h : Confined s) :
    Confined (s.request id) := by
  intro id' h'
  by_cases hadm : s.admits id = true
  · have e : s.request id = { s with owner := some id } := by simp [request, hadm]
    rw [e] at h' ⊢
    simp at h'
    subst h'
    exact hadm
  · have e : s.request id = s := by simp [request, hadm]
    rw [e] at h' ⊢
    exact h id' h'

/-- Opening a modal always establishes confinement, whatever held focus before. -/
theorem pushTrap_confined (s : FocusState) (ids : List EntityId) : Confined (s.pushTrap ids) := by
  intro id h
  simp [pushTrap, Option.filter_eq_some_iff] at h
  simp [pushTrap, admits, h.2]

theorem popTrap_confined (s : FocusState) : Confined s.popTrap := by
  intro id h
  simp [popTrap] at h

theorem blur_confined (s : FocusState) : Confined s.blur := by
  intro id h
  simp [blur] at h

private theorem foldl_hit_sound (px py : Int) (id : EntityId) :
    ∀ (regions : List (EntityId × Rect)) (acc : Option EntityId),
      regions.foldl (fun acc (p : EntityId × Rect) =>
        if p.2.contains px py then some p.1 else acc) acc = some id →
      acc = some id ∨ ∃ r, (id, r) ∈ regions ∧ r.contains px py = true := by
  intro regions
  induction regions with
  | nil => intro acc h; exact Or.inl h
  | cons e rest ih =>
    intro acc h
    rw [List.foldl_cons] at h
    rcases ih _ h with h' | ⟨r, hm, hc⟩
    · by_cases hc : e.2.contains px py = true
      · simp [hc] at h'
        exact Or.inr ⟨e.2, by rw [← h']; exact List.mem_cons_self, hc⟩
      · simp [hc] at h'
        exact Or.inl h'
    · exact Or.inr ⟨r, List.mem_cons_of_mem _ hm, hc⟩

private theorem foldl_hit_none (px py : Int) :
    ∀ (regions : List (EntityId × Rect)) (acc : Option EntityId),
      regions.foldl (fun acc (p : EntityId × Rect) =>
        if p.2.contains px py then some p.1 else acc) acc = none ↔
      (acc = none ∧ ∀ e, e ∈ regions → e.2.contains px py = false) := by
  intro regions
  induction regions with
  | nil => intro acc; simp
  | cons e rest ih =>
    intro acc
    rw [List.foldl_cons, ih]
    by_cases hc : e.2.contains px py = true
    · simp [hc]
    · simp [hc]

/-- A hit is always a region that contains the point. -/
theorem hitTest_sound (regions : List (EntityId × Rect)) (px py : Int) (id : EntityId)
    (h : hitTest regions px py = some id) :
    ∃ r, (id, r) ∈ regions ∧ r.contains px py = true := by
  rcases foldl_hit_sound px py id regions none h with h' | h'
  · cases h'
  · exact h' 

/-- A miss means no region contains the point. -/
theorem hitTest_none_iff (regions : List (EntityId × Rect)) (px py : Int) :
    hitTest regions px py = none ↔ ∀ e, e ∈ regions → e.2.contains px py = false := by
  have := foldl_hit_none px py regions none
  simpa [hitTest] using this

private theorem foldl_hit_skip (px py : Int) :
    ∀ (regions : List (EntityId × Rect)) (acc : Option EntityId),
      (∀ e, e ∈ regions → e.2.contains px py = false) →
      regions.foldl (fun acc (p : EntityId × Rect) =>
        if p.2.contains px py then some p.1 else acc) acc = acc := by
  intro regions
  induction regions with
  | nil => intro acc _; rfl
  | cons e rest ih =>
    intro acc h
    rw [List.foldl_cons, ih _ (fun e' he' => h e' (List.mem_cons_of_mem _ he'))]
    simp [h e List.mem_cons_self]

/-- Paint order decides: the last-painted containing region wins, wherever it sits. -/
theorem hitTest_last_containing (pre post : List (EntityId × Rect)) (id : EntityId) (r : Rect)
    (px py : Int) (h : r.contains px py = true)
    (hpost : ∀ e, e ∈ post → e.2.contains px py = false) :
    hitTest (pre ++ (id, r) :: post) px py = some id := by
  have e : hitTest (pre ++ (id, r) :: post) px py
      = (pre ++ (id, r) :: post).foldl (fun acc (p : EntityId × Rect) =>
        if p.2.contains px py then some p.1 else acc) none := rfl
  rw [e, List.foldl_append, List.foldl_cons, foldl_hit_skip px py post _ hpost]
  simp [h]

/-- An open modal refuses focus to anything outside it. -/
theorem pushTrap_refuses (s : FocusState) (ids : List EntityId) (id : EntityId)
    (h : ids.contains id = false) : ((s.pushTrap ids).request id).owner ≠ some id := by
  have h' : id ∉ ids := by simpa using h
  simp [pushTrap, request, admits, h', Option.filter_eq_some_iff]

/-- Opening a modal keeps focus that is already inside it. -/
theorem pushTrap_keeps (s : FocusState) (ids : List EntityId) (o : EntityId)
    (ho : s.owner = some o) (hin : ids.contains o = true) : (s.pushTrap ids).owner = some o := by
  have h' : o ∈ ids := by simpa using hin
  simp [pushTrap, ho, h']

/-- Closing a modal restores exactly the traps that were there before it opened. -/
theorem popTrap_pushTrap (s : FocusState) (ids : List EntityId) :
    (s.pushTrap ids).popTrap.traps = s.traps := by
  simp [popTrap, pushTrap]

theorem focusBorder_geometry (focused otherFocused : Bool) (rect otherRect : Rect)
    (color otherColor : Color) :
    focusBorder focused rect color = focusBorder otherFocused otherRect otherColor ↔
      focused = otherFocused ∧ rect = otherRect ∧ color = otherColor := by
  cases focused <;> cases otherFocused <;> simp [focusBorder]

theorem focusBorder_step (rect : Rect) (color : Color) :
    focusBorder true rect color = .quad rect 0 0 1 color ∧
    focusBorder false rect color = .quad rect 0 0 0 color := by
  exact ⟨rfl, rfl⟩

theorem focusBorderDamage_quiet (focused : Bool) (rect : Rect) :
    focusBorderDamage focused focused rect = none := by
  simp [focusBorderDamage]

theorem focusBorderDamage_changed (before after : Bool) (rect : Rect)
    (hchange : before ≠ after) (hrect : rect.isEmpty = false) :
    focusBorderDamage before after rect = some rect := by
  simp [focusBorderDamage, hchange, Damage.add, hrect]

theorem focusBorderDamage_empty (before after : Bool) (rect : Rect)
    (hrect : rect.isEmpty = true) : focusBorderDamage before after rect = none := by
  simp [focusBorderDamage, Damage.add, hrect]

end LeanUI.Spec
