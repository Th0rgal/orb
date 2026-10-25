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
