import OrbDesktop.State
/-!
# OrbDesktop.Spec.ComposerDamage — composer edits must repaint

Replays the PR #1711 review finding: text, preedit and IME batches edited the composer buffer
but returned no damage, so the damage-gated frame loop never repainted what was typed.
-/
namespace OrbDesktop.Spec

open LeanUI OrbDesktop

private def fixture : DesktopState := DesktopState.forScreen .missionTranscript
private def viewport : Rect := { x := 0, y := 0, w := 1470, h := 923 }
private def step (ev : Event) : DesktopState × Damage := stepDesktopEvent 120 viewport fixture ev

/-- A point inside the composer text box and one in the transcript above it. -/
private def inComposer (d : Damage) : Bool := d.covers 300 890
private def inTranscript (d : Damage) : Bool := d.covers 300 400

-- Every edit that changes the buffer repaints the composer, and only the composer.
#guard inComposer (step (.text "x")).2 && !inTranscript (step (.text "x")).2
#guard inComposer (step (.preedit "ni" 0 2)).2 && !inTranscript (step (.preedit "ni" 0 2)).2
#guard inComposer (step (.imeBatch 1 0 "你" "" 0 0)).2
#guard (step (.text "x")).1.composer.text == fixture.composer.text ++ "x"
#guard (step (.text "x")).2 == some { x := 220, y := 819, w := 1250, h := 104 }
#guard (stepDesktopEvent 240 { viewport with w := 2940, h := 1846 } fixture (.text "x")).2
  == some { x := 440, y := 1638, w := 2500, h := 208 }

-- Events that leave the buffer unchanged cause no redraw.
#guard !needsRedraw (step (.text "")).2
#guard !needsRedraw (step (.preedit "" 0 0)).2
#guard !needsRedraw (step (.imeBatch 0 0 "" "" 0 0)).2
#guard !needsRedraw (step (.pointerMove 300 890)).2

end OrbDesktop.Spec
