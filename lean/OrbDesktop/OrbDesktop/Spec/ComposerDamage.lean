import OrbDesktop.Screens
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

-- The New Agent card in a 1000 × 700 window with a 220 px sidebar.
private def editorFrame (buf : Widgets.ComposerBuffer) :=
  let w := pxToSub 780
  let widget := Widgets.buildComposerWidget orbDarkTheme w 0 buf [] none
    (some (WidgetNode.box (BoxStyle.row 0) []))
  let root := layoutNode 120 none 0 0 0 w (pxToSub 700) widget.toLayoutNode
  (root, buildSceneFromLayout 120 {} orbDarkTheme widget root false)

private def checkWindow (buf : Widgets.ComposerBuffer) (atEnd : Bool) : Bool := Id.run do
  let (root, scene) := editorFrame buf
  let [_, card] := root.children | return false
  let [editor, toolbar] := card.children | return false
  let [text] := editor.children | return false
  let some (_, offset) := editor.scrollOffset | return false
  let some (_, limit) := editor.scrollLimitXY | return false
  let rect := editor.contentRectDev
  let last := text.lines.getLast!
  let lineBottom := text.contentRectSub.y + Int.ofNat (last.ySub + last.heightSub)
  return limit > 0 && rect.h == 180 && scene.prims.contains (.clipPush rect) &&
    (if atEnd then offset == limit && lineBottom == editor.rectSub.y + editor.rectSub.h
     else offset == 0 && text.rectSub.y == editor.rectSub.y) &&
    rect.y + rect.h ≤ toolbar.rectDev.y &&
    toolbar.rectDev.y + toolbar.rectDev.h ≤ card.rectDev.y + card.rectDev.h &&
    scene.focusableOrder == [buf.composerWidgetId, 3, 2] &&
    scene.hitTestDev (rect.x + 1).toInt32 (rect.y + 1).toInt32 == some buf.composerWidgetId

private def longDraft (separator : String) (count : Nat) : Widgets.ComposerBuffer :=
  ({} : Widgets.ComposerBuffer).insertText (String.intercalate separator (List.replicate count "draft"))

#guard checkWindow (longDraft "\n" 20) true
#guard checkWindow (longDraft " " 200) true
-- Home on a soft-wrapped paragraph traverses back to its first visual line.
#guard checkWindow (((longDraft " " 200).editKey? 0xff50 0).get!) false

#guard checkWindow ((longDraft "\n" 20).insertText "\n") true
#guard checkWindow ((longDraft "\n" 20).setPreedit "候補") true

-- Walk back eight rows without changing the draft. The insertion line is now
-- the twelfth line, with more content both above and below the editor.
#guard Id.run do
  let draft := longDraft "\n" 20
  let moved := (List.range 48).foldl (fun b _ => (b.editKey? 0xff51 0).get!) draft
  let (root, _) := editorFrame moved
  let [_, card] := root.children | return false
  let [editor, _] := card.children | return false
  let [text] := editor.children | return false
  let some line := text.lines[11]? | return false
  let top := text.contentRectSub.y + line.ySub
  return moved.text == draft.text && text.contentRectSub.y < editor.rectSub.y &&
    editor.rectSub.y ≤ top && top + line.heightSub ≤ editor.rectSub.y + editor.rectSub.h

-- A short row and an empty row clamp the local caret, while a subsequent long
-- row recovers its original horizontal position. Offsets count Unicode scalars.
#guard Id.run do
  let draft := ({} : Widgets.ComposerBuffer).insertText "abcdef\n\n猫\n123456"
  let (root, _) := editorFrame draft
  let [_, card] := root.children | return false
  let [editor, _] := card.children | return false
  let [text] := editor.children | return false
  let rows := editorRows text.lines draft.text.length
  let mut b := draft
  for (key, pos) in [(0xff52, 9), (0xff52, 7), (0xff52, 6), (0xff54, 7), (0xff54, 9), (0xff54, 16)] do
    let some moved := b.editKey? key 0 rows | return false
    if moved.cursorOffset != pos || moved.text != draft.text then return false
    b := moved
  return true

private def newAgent : DesktopState :=
  { DesktopState.liveUnavailable with
    connectionBinding := "fixture", voiceAvailable := true
    composer := longDraft "\n" 20 }

-- Use the full screen to exercise pointer targets alongside the long editor.
#guard Id.run do
  let w := pxToSub 1000
  let h := pxToSub 700
  let tree := buildDesktopScreen newAgent w h
  let box := layoutNode 120 none 0 0 0 w h tree.toLayoutNode
  let scene := buildSceneFromLayout 120 newAgent.initialFocusState newAgent.theme tree box false
  for id in [3, voiceButtonId, 2] do
    let some (_, r) := scene.hitRegionsDev.find? (·.1 == id) | return false
    unless r.y ≥ 0 && r.y + r.h ≤ 700 && scene.focusableOrder.contains id &&
        scene.hitTestDev (r.x + r.w / 2).toInt32 (r.y + r.h / 2).toInt32 == some id do
      return false
  return true

private def submitted := (stepDesktopEvent 120 viewport newAgent (.composerReturn false)).1
#guard submitted.writeRequest == some .create && submitted.composer.text == newAgent.composer.text

end OrbDesktop.Spec
