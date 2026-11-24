import LeanUI.Runtime
import OrbDesktop.State

namespace OrbDesktop
open LeanUI

/-- Differential fixtures for invalidations that the stream benchmark does not force. -/
def verifyRepaintEdges : IO Unit := do
  -- A half-transparent colored pixel reaches wl_shm premultiplied exactly once.
  let clear : ByteArray := ⟨#[0,0,0,0]⟩
  let rgba := FFI.blendRect clear 0 1 1 1 0xF0783C80
  let ptr ← FFI.memAlloc 4
  if ptr == 0 then throw <| IO.userError "cannot allocate Wayland test pixel"
  try
    FFI.presentArgb ptr rgba
    unless (← FFI.memRead ptr 4).data == #[30,60,120,128] do
      throw <| IO.userError "Wayland presentation changed premultiplied color or alpha"
  finally FFI.memFree ptr
  let dest : ByteArray := ⟨#[1,2,3,4, 0,50,100,200, 5,6,7,8]⟩
  let src : ByteArray := ⟨#[80,120,160,128]⟩
  for (colored, rgb) in [(true, #[20,68,115]), (false, #[50,63,75])] do
    -- Effective alpha 64; check both color sources and unchanged guard pixels.
    let expected : ByteArray := ⟨(#[1,2,3,4] ++ rgb ++ #[214,5,6,7,8]).map Nat.toUInt8⟩
    unless FFI.blitGlyph dest src 1 0 3 1 1 1 0xC8640080 colored == expected do
      throw <| IO.userError "native glyph blend differs from reference pixel"
  for n in [0, 7, 16, 31] do
    let paths := [[(-4,2),(90,156),(90,156)],[(160,0),(0,160)]]
    if (Text.rasterizeIcon paths n).pixels != (Text.rasterizeIconReference paths n).pixels then
      throw <| IO.userError "native icon coverage differs from reference"
  for (w,h) in [(1,5),(7,1),(9,4)] do
    let pixels := ByteArray.mk ((Array.range (w*h*4)).map fun i => ((i*i+13*i)%251).toUInt8)
    for r in [0,1,2,12] do
      for axis in [false,true] do
        if FFI.boxAxis pixels w.toUSize h.toUSize r.toUSize axis != Vulkan.blurAxis pixels w h r axis then
          throw <| IO.userError "native box filter differs from reference"
  let ctx : Vulkan.VulkanContext := { width := 16, height := 12 }
  let page : Text.AtlasPageBuffer := { atlas := { width := 2, height := 1 }, rgba := ⟨#[255,255,255,255, 0,0,0,0]⟩ }
  let atlas : Text.GlyphAtlasCache := { pages := #[page] }
  let scene (x clipX : Int) : Scene := #[.clipPush ⟨clipX,2,4,4⟩,
    .quad ⟨x,0,8,8⟩ 0xAA33FFFF 0 0 0, .clipPop,
    .glyph ⟨0,0,1,1⟩ ⟨14,10,1,1⟩ 0xFFFFFFFF false]
  let base ← Vulkan.renderFrame ctx 0 atlas (scene 0 2)
  let check (a : Text.GlyphAtlasCache) (s : Scene) (expectPartial : Bool) := do
    let got ← Vulkan.renderFrameDamage base 0 a ⟨0,0,1,1⟩ s
    let ref ← Vulkan.renderFrame ctx 0 a s
    if got.framebuffer != ref.framebuffer || (got.partialFrames > 0) != expectPartial then
      throw <| IO.userError "clip/atlas repaint differs from full repaint or unexpected fallback"
    return got.lastDamagePixels
  let area ← check atlas (scene 4 2) true
  if area != 16 then throw <| IO.userError s!"expected clipped 4×4 repaint, got {area} pixels"
  discard <| check atlas (scene 0 6) false
  let withByte (i : Nat) : Text.GlyphAtlasCache := { atlas with pages := #[{ page with rgba := page.rgba.set! i 0 }] }
  discard <| check (withByte 3) (scene 4 2) false
  let unused := { page with rgba := page.rgba.set! 7 255 }
  discard <| check { atlas with pages := #[unused] } (scene 4 2) true

private def checkPartial (label : String) (base : Vulkan.VulkanContext) (dirty : Damage)
    (atlas : Text.GlyphAtlasCache) (clear : Color) (scene : Scene) : IO Vulkan.VulkanContext := do
  let some rect := dirty | throw <| IO.userError s!"{label}: missing invalidation"
  let got ← Vulkan.renderFrameDamage base clear atlas rect scene
  let ref ← Vulkan.renderFrame base clear atlas scene
  unless got.partialFrames == base.partialFrames + 1 && got.lastDamagePixels > 0 &&
      got.lastDamagePixels < base.width * base.height do
    throw <| IO.userError s!"{label}: expected a nonempty partial repaint"
  unless base.framebuffer != ref.framebuffer && got.framebuffer == ref.framebuffer do
    throw <| IO.userError s!"{label}: expected changed pixels matching full repaint"
  return got

private def verifyFocusTransfer : IO Unit := do
  let theme := orbDarkTheme
  let button (id : Nat) := WidgetNode.focusable id <| WidgetNode.box
    (BoxStyle.row 0 |>.withFixedSize (pxToSub 18) (pxToSub 12)) []
  let borderedInput := WidgetNode.focusable 1 <| WidgetNode.rrect
    (BoxStyle.row 0 |>.withFixedSize (pxToSub 22) (pxToSub 12))
    theme.palette.elevatedSurface (CornerRadii.uniform (pxToSub 4))
    (BorderStyle.uniform theme.borderWidth theme.palette.border) []
  let borderlessSearch := WidgetNode.focusable 701 <|
    WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 22) (pxToSub 12)) (pxToSub 12)
      [Widgets.overlaySynthRun (Theme.bodyText theme) "ab"] none
      (some { owner := 701, pos := 1, length := 2, color := theme.palette.textPrimary })
  let root := WidgetNode.box (BoxStyle.row (pxToSub 8)) [button 10, button 20, borderedInput, borderlessSearch]
  let view (f : FocusState) (fv : Bool) :=
    (renderWidgetTree 120 (pxToSub 120) (pxToSub 24) f theme root (focusVisible := fv)).2
  let regionDiffers (a b : ByteArray) (w : Nat) (r : Rect) : Bool :=
    (List.range r.h.toNat).any fun y => (List.range r.w.toNat).any fun x =>
      let i := 4 * ((r.y.toNat + y) * w + r.x.toNat + x)
      a.extract i (i + 4) != b.extract i (i + 4)
  let focus0 : FocusState := { owner := some 10 }
  let first := view focus0 true
  let unfocusedScene := view {} false
  let baseUnfocused ← Vulkan.renderFrame { width := 120, height := 24 } theme.palette.canvas {} unfocusedScene.prims
  let base ← Vulkan.renderFrame { width := 120, height := 24 } theme.palette.canvas {} first.prims
  let rt0 : Runtime.RuntimeState Unit :=
    { app := (), focus := focus0, focusVisible := true,
      hitRegions := first.hitRegionsSub, focusableOrder := first.focusableOrder }
  let some (_, btn10Dev) := first.hitRegionsDev.find? (·.1 == 10)
    | throw <| IO.userError "focus: missing button 10"
  let some (_, btn20Dev) := first.hitRegionsDev.find? (·.1 == 20)
    | throw <| IO.userError "focus: missing button 20"
  let some (_, btn10Sub) := first.hitRegionsSub.find? (·.1 == 10)
    | throw <| IO.userError "focus: missing button 10 sub"
  let some (_, btn20Sub) := first.hitRegionsSub.find? (·.1 == 20)
    | throw <| IO.userError "focus: missing button 20 sub"
  -- 1. Keyboard Tab transfers focus 10 -> 20, sets focusVisible = true, and repaints focusRing on 20.
  let tabbed := rt0.stepEvent (fun s _ => (s, none)) (.key 0xff09 0 .pressed)
  unless tabbed.focus.owner == some 20 && tabbed.focusVisible do
    throw <| IO.userError "focus: Tab transfer failed or cleared focusVisible"
  let afterTab ← checkPartial "keyboard Tab focus transfer" base tabbed.damage {} theme.palette.canvas
    (view tabbed.focus tabbed.focusVisible).prims
  for (id, r) in [(10, btn10Dev), (20, btn20Dev)] do
    unless tabbed.damage.any (fun d => d.x ≤ r.x && d.y ≤ r.y && d.right ≥ r.right && d.bottom ≥ r.bottom) do
      throw <| IO.userError s!"focus: Tab damage missed button {id}"
    unless regionDiffers base.framebuffer afterTab.framebuffer base.width r do
      throw <| IO.userError s!"focus: Tab border {id} did not change"
  -- 2. Pointer click on button 10 transfers logical focus, sets focusVisible = false, clears 20's ring,
  --    and stays visually quiet (no focusRing painted on clicked button 10).
  let clicked := ({ tabbed with damage := none }).stepEvent (fun s _ => (s, none))
    (.pointerButton (btn10Sub.x + btn10Sub.w / 2) (btn10Sub.y + btn10Sub.h / 2) 0x110 true)
  unless clicked.focus.owner == some 10 && !clicked.focusVisible do
    throw <| IO.userError "focus: pointer click did not transfer focus quietly"
  let afterClick ← checkPartial "pointer quiet focus click" afterTab clicked.damage {} theme.palette.canvas
    (view clicked.focus clicked.focusVisible).prims
  unless regionDiffers afterTab.framebuffer afterClick.framebuffer base.width btn20Dev do
    throw <| IO.userError "focus: pointer click did not clear previous keyboard focusRing on 20"
  if regionDiffers baseUnfocused.framebuffer afterClick.framebuffer base.width btn10Dev then
    throw <| IO.userError "focus: pointer click painted harsh focusRing on clicked button 10"
  -- 3. Subsequent pointer click from quiet button 10 -> button 20 transfers logical focus with zero visual noise.
  let clicked2 := ({ clicked with damage := none }).stepEvent (fun s _ => (s, none))
    (.pointerButton (btn20Sub.x + btn20Sub.w / 2) (btn20Sub.y + btn20Sub.h / 2) 0x110 true)
  unless clicked2.focus.owner == some 20 && !clicked2.focusVisible && clicked2.damage.isNone do
    throw <| IO.userError "focus: quiet-to-quiet pointer click should stay silent with no focus damage"
  -- 4. Pointer click on bordered text input 1 still steps its 1px border; borderless search 701 draws caret with no box outline.
  let some (_, in1Sub) := first.hitRegionsSub.find? (·.1 == 1)
    | throw <| IO.userError "focus: missing input 1"
  let some (_, in1Dev) := first.hitRegionsDev.find? (·.1 == 1)
    | throw <| IO.userError "focus: missing input 1 dev"
  let clickIn1 := ({ clicked2 with damage := none }).stepEvent (fun s _ => (s, none))
    (.pointerButton (in1Sub.x + in1Sub.w / 2) (in1Sub.y + in1Sub.h / 2) 0x110 true)
  unless clickIn1.focus.owner == some 1 && !clickIn1.focusVisible && clickIn1.damage.isSome do
    throw <| IO.userError "focus: clicking bordered text input 1 did not focus/damage border step"
  let in1Fb ← Vulkan.renderFrame baseUnfocused theme.palette.canvas {} (view clickIn1.focus clickIn1.focusVisible).prims
  unless regionDiffers baseUnfocused.framebuffer in1Fb.framebuffer base.width in1Dev do
    throw <| IO.userError "focus: bordered text input 1 must step its border on pointer click"
  let searchScene := view { owner := some 701 } false
  let hasBorderOutline701 := searchScene.prims.any fun p => match p with
    | .quad _ 0 _ bw col => bw > 0 && col == theme.palette.focusRing
    | _ => false
  let hasCaret701 := searchScene.prims.any fun p => match p with
    | .quad r col 0 0 0 => col == theme.palette.textPrimary && r.w >= 1 && r.h >= 1
    | _ => false
  if hasBorderOutline701 then
    throw <| IO.userError "focus: borderless search input 701 must not draw a box focus outline"
  unless hasCaret701 do
    throw <| IO.userError "focus: borderless search input 701 must still draw its vertical text caret"

private def verifyCaretAndScrollbar : IO Unit := do
  let theme := orbDarkTheme
  -- 1. Caret positioning: empty, mid-string, multi-byte UTF-8, and IME preedit.
  let makeCaretScene (txt : String) (pos : Nat) (focused : Bool) :=
    let st : TextStyle := Theme.bodyText theme
    let run := { Widgets.overlaySynthRun st txt with editorStart := if txt.isEmpty then none else some 0 }
    let node := WidgetNode.focusable 1 <|
      WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 200) (pxToSub 20)) (pxToSub 20)
        [run] none (some { owner := 1, pos, length := txt.length, color := theme.palette.textPrimary })
    (renderWidgetTree 120 (pxToSub 200) (pxToSub 20) { owner := if focused then some 1 else none } theme node (focusVisible := false)).2
  let caretRect? (s : SceneOutput) : Option Rect :=
    s.prims.toList.findSome? fun p => match p with
      | .quad r col 0 0 0 => if col == theme.palette.textPrimary then some r else none
      | _ => none
  let some rEmpty := caretRect? (makeCaretScene "" 0 true)
    | throw <| IO.userError "caret: missing on empty focused input"
  unless rEmpty.x == 0 && rEmpty.w >= 1 && rEmpty.h == 18 do
    throw <| IO.userError s!"caret: unexpected empty rect {repr rEmpty}"
  if (caretRect? (makeCaretScene "abc" 1 false)).isSome then
    throw <| IO.userError "caret: must not draw when unfocused"
  let some rMid := caretRect? (makeCaretScene "leftRIGHT" 4 true)
    | throw <| IO.userError "caret: missing on mid-string"
  let some rEnd := caretRect? (makeCaretScene "leftRIGHT" 9 true)
    | throw <| IO.userError "caret: missing on end-string"
  unless rEmpty.x < rMid.x && rMid.x < rEnd.x do
    throw <| IO.userError s!"caret: non-monotone ASCII x ({rEmpty.x}, {rMid.x}, {rEnd.x})"
  let utf8Str := "a你🙂z"
  let mut prevX : Int := -1
  for i in [0 : utf8Str.length + 1] do
    let some r := caretRect? (makeCaretScene utf8Str i true)
      | throw <| IO.userError s!"caret: missing for UTF-8 scalar index {i}"
    unless r.x > prevX do
      throw <| IO.userError s!"caret: non-increasing x at UTF-8 scalar {i}: {r.x} <= {prevX}"
    prevX := r.x
  let preBuf := ({ text := "hi", cursorOffset := 1 } : Widgets.ComposerBuffer).setPreedit "未確定"
  let prePos := Widgets.ComposerBuffer.clampCursor preBuf.text preBuf.cursorOffset + preBuf.imePreeditText.length
  let some rPre := caretRect? (makeCaretScene preBuf.displayText prePos true)
    | throw <| IO.userError "caret: missing during IME preedit"
  let some rPreStart := caretRect? (makeCaretScene preBuf.displayText 1 true)
    | throw <| IO.userError "caret: missing before IME preedit"
  unless preBuf.displayText == "h未確定i" && prePos == 4 && rPre.x > rPreStart.x do
    throw <| IO.userError "caret: IME preedit caret did not advance past preedit span"
  -- 2. Scrollbar geometry, thumb drag, track jump, clamping, and Orb.Scroll unpinning.
  let vpBounds : Rect := { x := pxToSub 220, y := pxToSub 35, w := pxToSub 1000, h := pxToSub 400 }
  let limitY : SubPx := pxToSub 1200
  if (scrollbarGeometry vpBounds 0 0).isSome then
    throw <| IO.userError "scrollbar: limitY == 0 must return none"
  let some gBot := scrollbarGeometry vpBounds limitY limitY
    | throw <| IO.userError "scrollbar: expected geometry for limitY > 0"
  unless gBot.trackRectSub.w == pxToSub 12 && gBot.thumbRectSub.w == pxToSub 6 &&
      gBot.thumbRectSub.h >= pxToSub 28 &&
      gBot.thumbRectSub.y == gBot.trackTopSub + gBot.travelSub do
    throw <| IO.userError s!"scrollbar: unexpected bottom geometry {repr gBot}"
  unless gBot.offsetForThumbTop (gBot.trackTopSub - pxToSub 50) == 0 &&
      gBot.offsetForThumbTop (gBot.trackTopSub + gBot.travelSub + pxToSub 50) == limitY do
    throw <| IO.userError "scrollbar: offsetForThumbTop did not clamp cleanly to [0, limitY]"
  let txInit : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .missionTranscript
    connectionBinding := "test"
    openMission := some "m1"
    scroll := { pinned := true, topSub := limitY }
  }
  let region : Runtime.ScrollRegion := { id := transcriptViewportId, bounds := vpBounds, limitY, offsetY := limitY }
  let reduce (st : DesktopState) (ev : Event) : DesktopState × Damage :=
    match ev with
    | .scrollTo rid off => applyScrollRegionTo 120 rid region.bounds region.limitY region.offsetY off st
    | _ => (st, none)
  let rt0 : Runtime.RuntimeState DesktopState := {
    app := txInit
    scrollRegions := [region]
    hitRegions := [(105, vpBounds)]
    focusableOrder := [105]
    focus := { owner := some 105 }
    focusVisible := true
  }
  -- Press on thumb -> starts drag, consumes press (no pressedEntity), clears focusVisible.
  let gx := gBot.thumbHitRectSub.x + gBot.thumbHitRectSub.w / 2
  let gy := gBot.thumbHitRectSub.y + gBot.thumbHitRectSub.h / 2
  let pressed := rt0.stepEvent reduce (.pointerButton gx gy 0x110 true)
  unless pressed.activeScrollbarDrag.isSome && pressed.pressedEntity.isNone && !pressed.focusVisible do
    throw <| IO.userError "scrollbar: thumb press did not start drag or leaked pressedEntity"
  -- Drag upward -> unpins Orb.Scroll and moves topSub upward.
  let draggedUp := pressed.stepEvent reduce (.pointerMove gx (gy - pxToSub 120))
  unless !draggedUp.app.scroll.pinned && draggedUp.app.scroll.topSub < limitY && draggedUp.damage.isSome do
    throw <| IO.userError s!"scrollbar: upward thumb drag failed to unpin ({repr draggedUp.app.scroll})"
  -- Drag past top -> clamps to 0.
  let clampedTop := draggedUp.stepEvent reduce (.pointerMove gx (vpBounds.y - pxToSub 200))
  unless clampedTop.app.scroll.topSub == 0 && !clampedTop.app.scroll.pinned do
    throw <| IO.userError s!"scrollbar: top clamp failed ({repr clampedTop.app.scroll})"
  -- Drag past bottom -> clamps to limitY and re-pins Orb.Scroll.
  let clampedBot := clampedTop.stepEvent reduce (.pointerMove gx (vpBounds.bottom + pxToSub 200))
  unless clampedBot.app.scroll.topSub == limitY && clampedBot.app.scroll.pinned do
    throw <| IO.userError s!"scrollbar: bottom clamp/re-pin failed ({repr clampedBot.app.scroll})"
  -- Release ends drag cleanly without activating underlying widget.
  let released := clampedBot.stepEvent reduce (.pointerButton gx gy 0x110 false)
  unless released.activeScrollbarDrag.isNone && released.pressedEntity.isNone do
    throw <| IO.userError "scrollbar: release did not end drag cleanly"
  -- Track jump above thumb immediately jumps upward, unpins, and starts drag; windowFocus false ends drag.
  let jumpY := vpBounds.y + pxToSub 40
  let jumped := rt0.stepEvent reduce (.pointerButton gx jumpY 0x110 true)
  unless jumped.activeScrollbarDrag.isSome && !jumped.app.scroll.pinned && jumped.app.scroll.topSub < limitY / 2 do
    throw <| IO.userError s!"scrollbar: track jump failed ({repr jumped.app.scroll})"
  let unfocused := jumped.stepEvent reduce (.windowFocus false)
  unless unfocused.activeScrollbarDrag.isNone do
    throw <| IO.userError "scrollbar: windowFocus false must end active drag"

def verifyDesktopEdges (view : Runtime.RuntimeState DesktopState → IO Runtime.FrameView)
    (shape : Text.GlyphAtlasCache → Text.FontHandle → Nat → TextStyle → String →
      IO (Text.GlyphAtlasCache × List InlineRun)) : IO Unit := do
  verifyFocusTransfer
  verifyCaretAndScrollbar
  let st := DesktopState.forScreen .missionTranscript
  let st := { st with composer := { st.composer with text := "leftRIGHT", cursorOffset := 4 } }
  let rt ← Runtime.initRuntime { headless := true, width := 960, height := 720, scale120 := 120 } st
  try
    let (atlas, clear, scene, _, _) ← view rt
    let base ← Vulkan.renderFrame rt.vulkan clear atlas scene
    let edited := ({ rt with atlas, damage := none }).stepEvent
      (stepDesktopEvent 120 rt.viewportDeviceRect) (.text "W")
    unless edited.app.composer.text == "leftWRIGHT" do throw <| IO.userError "composer: middle insert failed"
    let (atlas', clear', scene', _, _) ← view edited
    let got ← checkPartial "composer middle insert" base edited.damage atlas' clear' scene'
    -- Scene diffing can repair an undersized reducer hint. Independently replay just
    -- that hint over the old pixels so a clipped suffix cannot hide behind the diff.
    let (hinted, _) := Vulkan.rasterizeSceneInto base.width base.height clear' atlas'
      (some base.framebuffer) edited.damage scene'
    unless hinted == got.framebuffer do throw <| IO.userError "composer: damage missed edited pixels"

    let center := { rt with app := DesktopState.forScreen .controlEmpty, atlas := atlas', damage := none }
    let (ca, cc, cs, _, _) ← view center
    let before ← Vulkan.renderFrame center.vulkan cc ca cs
    let edit := ({ center with atlas := ca }).stepEvent (stepDesktopEvent 120 center.viewportDeviceRect) (.text "W")
    let (ea, ec, es, _, _) ← view edit
    let after ← Vulkan.renderFrame before ec ea es
    let (replayed, _) := Vulkan.rasterizeSceneInto before.width before.height ec ea (some before.framebuffer) edit.damage es
    unless edit.damage == some center.viewportDeviceRect && before.framebuffer != after.framebuffer && replayed == after.framebuffer do
      throw <| IO.userError "centered composer: damage missed edited pixels"

    let label ac := shape ac rt.primaryFont 120 (Theme.bodyText st.theme)
    let mut ac : Text.GlyphAtlasCache := {}
    for i in [:(Text.maxResolvedRuns + 2)] do ac := (← label ac s!"label{i}").1
    let boundary := String.ofList (List.replicate (Text.maxShapeCacheBytes / 2) 'é') -- exactly maxShapeCacheBytes UTF-8 bytes
    ac := (← label ac boundary).1
    let shaped := ac.shapeCache.map (·.text)
    let resolved := ac.resolved.map (·.text)
    unless shaped.size == 64 && resolved.size == Text.maxResolvedRuns && ac.resolvedMap.size == Text.maxResolvedRuns &&
        shaped.back? == some boundary && resolved.back? == some boundary &&
        !shaped.contains "label0" && !resolved.contains "label0" do
      throw <| IO.userError "shape caches: expected bounded short-label retention"
    for text in [boundary ++ "x", String.ofList (List.replicate 4096 'w')] do
      let (next, runs) ← label ac text
      unless runs.any (fun r => !r.glyphs.isEmpty) && next.shapeCache.map (·.text) == shaped &&
          next.resolved.map (·.text) == resolved && next.resolvedMap.size == Text.maxResolvedRuns do
        throw <| IO.userError s!"shape caches: oversized {text.utf8ByteSize}-byte input not shaped or retained keys changed"
      ac := next
    -- Verify scroll event coalescing handles interleaved Wayland `.time` events safely.
    let coalesced := Runtime.coalesceScrollEvents #[
      .time 10, .scroll 100 200 0 12, .time 11, .scroll 100 200 0 18,
      .time 12, .scroll 100 200 0 (-5),
      .time 13, .scroll 400 200 0 9,
      .pointerMove 400 200, .scroll 400 200 0 9,
      .scroll 400 200 0 0]
    let expected : Array Event := #[
      .time 11, .scroll 100 200 0 30,
      .time 12, .scroll 100 200 0 (-5),
      .time 13, .scroll 400 200 0 9,
      .pointerMove 400 200, .scroll 400 200 0 9]
    unless reprStr coalesced == reprStr expected do
      throw <| IO.userError s!"coalesceScrollEvents mismatch: got {reprStr coalesced}"
  finally Runtime.shutdownRuntime rt

end OrbDesktop
