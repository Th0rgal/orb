/-
  Orb.Scroll: the conversation scroll contract (`0 import Lean`, `0 sorryAx`).

  Mirrored by `orb/src/mission/scrollPolicy.ts` (the only code that decides a
  conversation's scroll position) and checked against it through
  `shared/orb-spec/fixtures/scroll-policy.json` (`orb/tests/scroll-policy.test.ts`
  runs the TypeScript side; `ScrollFixtures.lean` the Lean side).

  Coordinates are integer CSS pixels. `top` is the scroller's `scrollTop`,
  `height` its `scrollHeight`, `client` its `clientHeight`. The anchor is the
  element the reader sees at the top of the viewport; `anchorDoc` is its offset
  in the content, so its position on screen is `anchorDoc - top`.

  The contract:
  1. Following (pinned) at the bottom: any layout change (streaming, new turns,
     a side panel narrowing the column, the dock growing) ends at the bottom.
  2. Not following: any layout change leaves the anchor at the same screen
     position, unless the content became too short to allow it (then clamped).
  3. Only the reader's own scrolling changes whether they follow; layout never does.
  4. The anchor correction is measured from where the anchor is, not from a
     delta of what changed, so applying it again is a no-op. (Two observers
     each adding the same growth delta moved the reader by twice the growth.)
-/

namespace Orb.Scroll

/-- Within this many pixels of the bottom, a downward scroll by the reader follows again. -/
def near : Int := 24

def maxTop (height client : Int) : Int := max 0 (height - client)

def clampTop (height client t : Int) : Int := max 0 (min t (maxTop height client))

def gap (height client top : Int) : Int := height - top - client

structure State where
  pinned : Bool
  top : Int
  deriving Repr, DecidableEq

/-- A layout change: the content is now `height` tall in a `client`-tall viewport,
    and the anchor's content offset moved by `shift` (growth or folding above it). -/
def layout (s : State) (height client shift : Int) : State :=
  if s.pinned then { s with top := maxTop height client }
  else { s with top := clampTop height client (s.top + shift) }

/-- The reader scrolled to `top'`. Moving up stops following; reaching the bottom follows again. -/
def userScroll (s : State) (height client top' : Int) : State :=
  let t := clampTop height client top'
  if t < s.top then { pinned := false, top := t }
  else if gap height client t < near then { pinned := true, top := t }
  else { s with top := t }

/-- A browser `scroll` event at `top'`.
    - Reader input (`intent = true`) delegates to `userScroll`.
    - When geometry changed since `s.top` was recorded (`resized = true` and `intent = false`),
      the event is a layout consequence (an earlier bottom scroll arriving after narrowing or
      streaming, or browser clamping when widening/shrinking): layout never changes `pinned`.
    - At unchanged geometry (`intent = false`, `resized = false`), corrective bottom scrolls
      (`s.top ≤ t`) and clamps (`gap < near`) also preserve `pinned`; only an explicit upward
      programmatic jump away from the bottom (`t < s.top` and `near ≤ gap`) stops following. -/
def scrollEvent (s : State) (intent resized : Bool) (height client top' : Int) : State :=
  if intent then userScroll s height client top'
  else
    let t := clampTop height client top'
    if !resized && s.pinned && t < s.top && near ≤ gap height client t then { pinned := false, top := t }
    else { s with top := t }

/-- A send or "Jump to latest". -/
def jump (_ : State) (height client : Int) : State := { pinned := true, top := maxTop height client }

/-- The idempotent correction: move so the anchor (now at `anchorDoc`) is back at screen `y0`. -/
def correct (height client top anchorDoc y0 : Int) : Int := clampTop height client (top + (anchorDoc - top - y0))

/-- The broken one: add the change's delta to whatever `top` already is. -/
def addDelta (top delta : Int) : Int := top + delta

/-! ### 1. Following stays at the bottom -/

theorem pinned_layout_at_bottom (s : State) (h c d : Int) (hp : s.pinned = true) (hc : c ≤ h) :
    gap h c (layout s h c d).top = 0 := by
  simp [layout, hp, gap, maxTop]; omega

/-! ### 2. Not following: the anchor does not move on screen -/

theorem unpinned_anchor_still (s : State) (h c d anchorDoc : Int) (hp : s.pinned = false)
    (lo : 0 ≤ s.top + d) (hi : s.top + d ≤ h - c) :
    (anchorDoc + d) - (layout s h c d).top = anchorDoc - s.top := by
  simp [layout, hp, clampTop, maxTop]; omega

/-- Clamped or not, the result is always a reachable scroll position. -/
theorem layout_in_range (s : State) (h c d : Int) :
    0 ≤ (layout s h c d).top ∧ (layout s h c d).top ≤ maxTop h c := by
  unfold layout clampTop maxTop; split <;> simp <;> omega

/-! ### 3. Layout never changes whether the reader follows -/

theorem layout_keeps_pinned (s : State) (h c d : Int) : (layout s h c d).pinned = s.pinned := by
  unfold layout; split <;> rfl

theorem layouts_keep_pinned (s : State) (changes : List (Int × Int × Int)) :
    (changes.foldl (fun s x => layout s x.1 x.2.1 x.2.2) s).pinned = s.pinned := by
  induction changes generalizing s with
  | nil => rfl
  | cons x xs ih => simp only [List.foldl_cons]; rw [ih, layout_keeps_pinned]

theorem scroll_up_unpins (s : State) (h c t : Int) (up : clampTop h c t < s.top) :
    (userScroll s h c t).pinned = false := by
  simp [userScroll, up]

theorem scroll_to_bottom_pins (s : State) (h c t : Int) (down : s.top ≤ clampTop h c t)
    (bottom : gap h c (clampTop h c t) < near) : (userScroll s h c t).pinned = true := by
  have : ¬ clampTop h c t < s.top := by omega
  simp [userScroll, this, bottom]

theorem jump_pins_at_bottom (s : State) (h c : Int) (hc : c ≤ h) :
    (jump s h c).pinned = true ∧ gap h c (jump s h c).top = 0 := by
  simp [jump, gap, maxTop]; omega

theorem scrollEvent_intent (s : State) (resized : Bool) (h c t : Int) :
    scrollEvent s true resized h c t = userScroll s h c t := rfl

/-- Any passive `scroll` event during a geometry change (`intent = false`, `resized = true` —
    narrowing, widening, viewport-height shrink, dock resize, or narration folding) preserves
    whether the reader is following. -/
theorem resize_scroll_keeps_pinned (s : State) (h c t : Int) :
    (scrollEvent s false true h c t).pinned = s.pinned := by
  simp [scrollEvent]

/-- An earlier corrective bottom scroll arriving after narrowing, streaming or
    viewport-height shrink (`s.top ≤ clampTop h c t`) never unpins a following reader. -/
theorem growth_scroll_keeps_pinned (s : State) (resized : Bool) (h c t : Int)
    (hp : s.pinned = true) (mono : s.top ≤ clampTop h c t) :
    (scrollEvent s false resized h c t).pinned = true := by
  have : ¬ clampTop h c t < s.top := by omega
  simp [scrollEvent, hp, this]

/-- Browser clamping to `maxTop` when content shrinks or the column widens lands at
    `gap ≤ 0 < near`, so the clamped scroll event never unpins a following reader. -/
theorem clamp_scroll_keeps_pinned (s : State) (resized : Bool) (h c : Int) (hp : s.pinned = true) :
    (scrollEvent s false resized h c (maxTop h c)).pinned = true := by
  have hcl : clampTop h c (maxTop h c) = maxTop h c := by simp [clampTop, maxTop]
  have hgap : ¬ near ≤ gap h c (maxTop h c) := by simp [near, gap, maxTop]; omega
  simp [scrollEvent, hp, hcl, hgap]

/-- Multi-step resize (narrowing, widening, or viewport-height shrink in any order):
    Frame 0 settles `layout` at `(h₀, c₀)`, Frame 1 changes geometry to `(h₁, c₁)` before
    a queued `scroll` event at any `t` runs (`resized = true`), and Frame 1's `ResizeObserver`
    settles `layout` back at `gap = 0`. -/
theorem resize_sequence_keeps_bottom (s : State) (h₀ c₀ d₀ h₁ c₁ d₁ t : Int)
    (hp : s.pinned = true) (hc : c₁ ≤ h₁) :
    let s₁ := layout s h₀ c₀ d₀
    let s₂ := scrollEvent s₁ false true h₁ c₁ t
    let s₃ := layout s₂ h₁ c₁ d₁
    s₂.pinned = true ∧ s₃.pinned = true ∧ gap h₁ c₁ s₃.top = 0 := by
  dsimp only
  have hp₁ : (layout s h₀ c₀ d₀).pinned = true := by rw [layout_keeps_pinned]; exact hp
  have hp₂ : (scrollEvent (layout s h₀ c₀ d₀) false true h₁ c₁ t).pinned = true := by
    rw [resize_scroll_keeps_pinned]; exact hp₁
  have hp₃ : (layout (scrollEvent (layout s h₀ c₀ d₀) false true h₁ c₁ t) h₁ c₁ d₁).pinned = true := by
    rw [layout_keeps_pinned]; exact hp₂
  exact ⟨hp₂, hp₃, pinned_layout_at_bottom _ h₁ c₁ d₁ hp₂ hc⟩

/-- Consecutive narrowing frames even before geometry tracking notices (`resized = false`):
    Frame 0 pins to `maxTop h₀ c₀`, Frame 1 grows `maxTop h₀ c₀ ≤ maxTop h₁ c₁` before
    Frame 0's queued `scroll` event runs, and Frame 1's `ResizeObserver` settles at `gap = 0`. -/
theorem resize_narrow_keeps_bottom (s : State) (h₀ c₀ d₀ h₁ c₁ d₁ : Int)
    (hp : s.pinned = true) (narrow : maxTop h₀ c₀ ≤ maxTop h₁ c₁) (hc : c₁ ≤ h₁) :
    let s₁ := layout s h₀ c₀ d₀
    let s₂ := scrollEvent s₁ false false h₁ c₁ s₁.top
    let s₃ := layout s₂ h₁ c₁ d₁
    s₂.pinned = true ∧ s₃.pinned = true ∧ gap h₁ c₁ s₃.top = 0 := by
  dsimp only
  have hp₁ : (layout s h₀ c₀ d₀).pinned = true := by rw [layout_keeps_pinned]; exact hp
  have htop₁ : (layout s h₀ c₀ d₀).top = maxTop h₀ c₀ := by simp [layout, hp]
  have hmono : (layout s h₀ c₀ d₀).top ≤ clampTop h₁ c₁ (layout s h₀ c₀ d₀).top := by
    rw [htop₁]; simp [clampTop, maxTop] at narrow ⊢; omega
  have hp₂ : (scrollEvent (layout s h₀ c₀ d₀) false false h₁ c₁ (layout s h₀ c₀ d₀).top).pinned = true :=
    growth_scroll_keeps_pinned _ false h₁ c₁ _ hp₁ hmono
  have hp₃ : (layout (scrollEvent (layout s h₀ c₀ d₀) false false h₁ c₁ (layout s h₀ c₀ d₀).top) h₁ c₁ d₁).pinned = true := by
    rw [layout_keeps_pinned]; exact hp₂
  exact ⟨hp₂, hp₃, pinned_layout_at_bottom _ h₁ c₁ d₁ hp₂ hc⟩

/-- An upward programmatic jump away from the bottom at unchanged geometry unpins. -/
theorem programmatic_jump_unpins (s : State) (h c t : Int)
    (up : clampTop h c t < s.top) (away : near ≤ gap h c (clampTop h c t)) :
    (scrollEvent s false false h c t).pinned = false := by
  cases hp : s.pinned <;> simp [scrollEvent, hp, up, away]

/-! ### 4. The correction is idempotent; adding deltas is not -/

/-- After a correction the anchor is where the reader saw it (when reachable). -/
theorem correct_restores (h c top a y0 : Int) (lo : 0 ≤ a - y0) (hi : a - y0 ≤ h - c) :
    a - correct h c top a y0 = y0 := by
  simp [correct, clampTop, maxTop]; omega

/-- A second owner running the same correction changes nothing. -/
theorem correct_idempotent (h c top a y0 : Int) :
    correct h c (correct h c top a y0) a y0 = correct h c top a y0 := by
  simp [correct, clampTop, maxTop]; omega

/-- Two owners each adding the same nonzero growth delta land `delta` px off. -/
theorem add_delta_twice_overshoots (top delta : Int) (hd : delta ≠ 0) :
    addDelta (addDelta top delta) delta ≠ top + delta := by
  simp [addDelta]; omega

end Orb.Scroll
