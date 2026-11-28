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
  for (colored, rgb) in [(true, #[40,97,155]), (false, #[50,63,75])] do
    -- Effective alpha 64; colored=true uses premultiplied source-over (s*sa + d*(255-a)).
    let expected : ByteArray := ⟨(#[1,2,3,4] ++ rgb ++ #[214,5,6,7,8]).map Nat.toUInt8⟩
    unless FFI.blitGlyph dest src 1 0 3 1 1 1 0xC8640080 colored == expected do
      throw <| IO.userError "native glyph blend differs from reference pixel"
  for n in [0, 7, 16, 31] do
    let paths := [[(-4,2),(90,156),(90,156)],[(160,0),(0,160)]]
    if (Text.rasterizeIcon paths n).pixels != (Text.rasterizeIconReference paths n).pixels then
      throw <| IO.userError "native icon coverage differs from reference"
  -- Verify rectangular thin-stroke vector icons (Mermaid diamonds & non-adjacent routing lanes)
  -- match the pure-Lean reference bit-for-bit and stay bounded/cached in the atlas.
  let lanePaths : List (List (Int × Int)) := [[(1, 0), (1, 1), (159, 1), (159, 0)]]
  let diamondPaths : List (List (Int × Int)) := [[(80, 0), (160, 24), (80, 47), (0, 24), (80, 0)]]
  for (ps, w, h, st) in [(diamondPaths, 136, 40, 12), (lanePaths, 542, 8, 4), (lanePaths, 8, 8, 200)] do
    let fast := Text.rasterizeIcon ps w st h
    let ref := Text.rasterizeIconReference ps w st h
    unless fast.width == w && fast.height == h && fast.pixels == ref.pixels do
      throw <| IO.userError s!"native rectangular icon ({w}x{h} stroke={st}) differs from reference"
  let (acIcon0, eLane1) := ({} : Text.GlyphAtlasCache).getOrRasterizeIcon lanePaths 1400 16 4
  let (acIcon1, eLane2) := acIcon0.getOrRasterizeIcon lanePaths 1400 16 4
  unless eLane1 == eLane2 && eLane1.uv.w == Text.maxIconRasterDim && eLane1.uv.h == 16 &&
      acIcon1.iconRasterMisses == 1 && acIcon1.iconRasterHits == 1 &&
      acIcon1.maxIconRasterPixels == Text.maxIconRasterDim * 16 do
    throw <| IO.userError "bounded vector-icon lane caching or clamping mismatch"
  -- Scaled CPU `.mask` rendering must map the clamped 1022x16 lane across the full 1400x16
  -- destination (matching GPU VK_FILTER_NEAREST) so the right stub lands at x≈1390..1399,
  -- and a tall 8x24 icon clamped to 8x8 must never read unrelated lower atlas shelves.
  let (laneFb, _) := Vulkan.rasterizeScene 1400 16 0 acIcon1 #[.mask eLane1.page eLane1.uv ⟨0, 0, 1400, 16⟩ 0xFFFFFFFF]
  let mut rightStubInk := false
  for x in [1385 : 1400] do
    if laneFb.get! (x * 4 + 3) > 0 then rightStubInk := true
  unless rightStubInk do
    throw <| IO.userError "scaled CPU .mask did not stretch clamped lane stub to right destination edge"
  let (acTall0, eTall) := ({} : Text.GlyphAtlasCache).getOrRasterizeIcon [[(80, 0), (80, 0)]] 8 24 0
  -- Place a solid opaque icon on a lower shelf of the same page; tall 8x24 blit must never sample it.
  let (acTall1, _) := acTall0.getOrRasterizeIcon [[(0, 0), (160, 160)]] 16 16 200
  let (tallFb, _) := Vulkan.rasterizeScene 8 24 0 acTall1 #[.mask eTall.page eTall.uv ⟨0, 0, 8, 24⟩ 0xFFFFFFFF]
  for y in [8 : 24] do
    for x in [0 : 8] do
      if tallFb.get! ((y * 8 + x) * 4 + 3) > 0 then
        throw <| IO.userError s!"tall .mask leaked lower atlas shelf pixel at ({x},{y})"
  -- Mixed externally-populated `ac.cache` + `insertRasterized` must retain pre-existing cache keys.
  let preKey : GlyphKey := { font := 1, glyph := 42, sizeSub := 12, subpx := 0 }
  let preEntry : Text.AtlasGlyphEntry := { page := 0, uv := ⟨1, 2, 3, 4⟩, bearingX := 0, bearingY := 0, isColor := false }
  let mixed0 : Text.GlyphAtlasCache := { cache := ({} : HashCache Text.AtlasGlyphEntry).insert Text.hashGlyphKey preKey preEntry }
  let otherKey : GlyphKey := { font := 1, glyph := 99, sizeSub := 12, subpx := 0 }
  let (mixed1, _) := mixed0.insertRasterized otherKey { width := 0, height := 0, bearingX := 0, bearingY := 0, format := 1, isColor := false, pixels := ByteArray.empty }
  unless mixed1.lookupGlyph preKey == some preEntry && (mixed1.lookupGlyph otherKey).isSome do
    throw <| IO.userError "GlyphAtlasCache.lookupGlyph dropped externally-populated cache entry after insertRasterized"
  -- Verify dirty-rect ARGB presentation matches full-frame conversion on the updated sub-rect
  -- without disturbing pixels outside the sub-rect, and check double-buffer dirty-rect tracking.
  let (pw, ph) := (8, 6)
  let srcFb := ByteArray.mk ((Array.range (pw * ph * 4)).map fun i => ((i * 37 + 11) % 256).toUInt8)
  let cap := pw * ph * 4
  let ptrFull ← FFI.memAlloc cap.toUSize
  let ptrPart ← FFI.memAlloc cap.toUSize
  if ptrFull == 0 || ptrPart == 0 then
    if ptrFull != 0 then FFI.memFree ptrFull
    if ptrPart != 0 then FFI.memFree ptrPart
    throw <| IO.userError "cannot allocate presentArgbRect test buffers"
  try
    FFI.presentArgb ptrFull srcFb
    FFI.presentArgbRect ptrPart cap.toUSize srcFb 2 1 4 3 pw.toUSize
    let fullBytes ← FFI.memRead ptrFull cap.toUSize
    let partBytes ← FFI.memRead ptrPart cap.toUSize
    for y in [0:ph] do
      for x in [0:pw] do
        let off := (y * pw + x) * 4
        let inside := x >= 2 && x < 6 && y >= 1 && y < 4
        let gotPx := partBytes.extract off (off + 4)
        let expPx := if inside then fullBytes.extract off (off + 4) else ⟨#[0, 0, 0, 0]⟩
        unless gotPx == expPx do
          throw <| IO.userError s!"presentArgbRect mismatch at ({x},{y}) inside={inside}"
  finally
    FFI.memFree ptrFull
    FFI.memFree ptrPart
  let shmVp : Rect := ⟨0, 0, 100, 80⟩
  let r1 : Rect := ⟨10, 10, 20, 15⟩
  let r2 : Rect := ⟨50, 40, 15, 10⟩
  let (c1, d1, a1, b1) := Wayland.computeShmDamageStep shmVp false (some shmVp) (some shmVp) (some r1)
  let (c2, d2, a2, b2) := Wayland.computeShmDamageStep shmVp true a1 b1 (some r2)
  let (c3, d3, _, _) := Wayland.computeShmDamageStep shmVp false a2 b2 (some r1)
  let expUnion : Rect := ⟨10, 10, 55, 40⟩
  unless c1 == shmVp && d1 == r1 && c2 == shmVp && d2 == r2 &&
      c3 == expUnion && d3 == r1 do
    throw <| IO.userError s!"computeShmDamageStep mismatch: c3={repr c3} d3={repr d3}"
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
  -- 5. SceneOutput.diff invalidates when focusVisible flips true -> false on a focused button (same owner).
  let sceneVisTrue := view { owner := some 10 } true
  let sceneVisFalse := view { owner := some 10 } false
  let visDiff := sceneVisTrue.diff sceneVisFalse
  unless visDiff.damage.isSome && visDiff.changed.contains 10 do
    throw <| IO.userError s!"focus: SceneOutput.diff missed focusVisible true -> false on button 10: {repr visDiff}"
  -- 6. Right-click press clears focusVisible and damages the previously visible keyboard ring.
  let rightPressed := ({ tabbed with damage := none }).stepEvent (fun s _ => (s, none))
    (.pointerButton (btn20Sub.x + 1) (btn20Sub.y + 1) 0x111 true)
  unless !rightPressed.focusVisible && rightPressed.damage.isSome do
    throw <| IO.userError "focus: right-click press must clear focusVisible and damage visible ring"
  -- 7. effectiveEvent applies the shared isTextInputEntity predicate to inputs 1, 701, and 604.
  for tid in ([1, 701, 604] : List EntityId) do
    let rtIn : Runtime.RuntimeState Unit := { app := (), focus := { owner := some tid }, focusableOrder := [tid] }
    match rtIn.effectiveEvent (.key 0xff0d 0 .pressed) with
    | .composerReturn false => pure ()
    | other => throw <| IO.userError s!"effectiveEvent: Return on input {tid} expected composerReturn false, got {repr other}"
    match rtIn.effectiveEvent (.key 0x20 0 .pressed) with
    | .key 0x20 0 .pressed => pure ()
    | other => throw <| IO.userError s!"effectiveEvent: Space on input {tid} must not activate, got {repr other}"
  let rtBtn : Runtime.RuntimeState Unit := { app := (), focus := { owner := some 10 }, focusableOrder := [10] }
  match rtBtn.effectiveEvent (.key 0x20 0 .pressed) with
  | .activate 10 => pure ()
  | other => throw <| IO.userError s!"effectiveEvent: Space on button 10 expected activate 10, got {repr other}"

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
  -- Stationary thumb press / horizontal jitter at lim - 10px (< nearBottomSub) must not re-pin.
  let nearTop := limitY - pxToSub 10
  let unpinnedNear : ScrollPolicyState := { pinned := false, topSub := nearTop }
  let sameTarget := unpinnedNear.onUserScrollTo (limitY + vpBounds.h.toNat) vpBounds.h.toNat nearTop
  unless !sameTarget.pinned && sameTarget.topSub == nearTop do
    throw <| IO.userError s!"scrollbar: stationary onUserScrollTo at lim-10px re-pinned ({repr sameTarget})"
  let some gNear := scrollbarGeometry vpBounds limitY nearTop
    | throw <| IO.userError "scrollbar: missing geometry at lim-10px"
  let regionNear : Runtime.ScrollRegion := { id := transcriptViewportId, bounds := vpBounds, limitY, offsetY := nearTop }
  let reduceNear (st : DesktopState) (ev : Event) : DesktopState × Damage :=
    match ev with
    | .scrollTo rid off => applyScrollRegionTo 120 rid regionNear.bounds regionNear.limitY regionNear.offsetY off st
    | _ => (st, none)
  let rtNear : Runtime.RuntimeState DesktopState := {
    app := { txInit with scroll := unpinnedNear }
    scrollRegions := [regionNear]
  }
  let nearGx := gNear.thumbHitRectSub.x + gNear.thumbHitRectSub.w / 2
  let nearGy := gNear.thumbHitRectSub.y + gNear.thumbHitRectSub.h / 2
  let pressNear := rtNear.stepEvent reduceNear (.pointerButton nearGx nearGy 0x110 true)
  let jitterNear := pressNear.stepEvent reduceNear (.pointerMove (nearGx + pxToSub 4) nearGy)
  unless !pressNear.app.scroll.pinned && pressNear.app.scroll.topSub == nearTop &&
      !jitterNear.app.scroll.pinned && jitterNear.app.scroll.topSub == nearTop do
    throw <| IO.userError s!"scrollbar: stationary thumb press or horizontal jitter at lim-10px re-pinned ({repr jitterNear.app.scroll})"
  -- Modal-open trap change cancels active scrollbar drag and pressedEntity so subsequent moves do not scroll.
  let modalSt := (stepDesktopEvent 120 { x := 0, y := 0, w := 1280, h := 800 } draggedUp.app (.key 0x6b 2 .pressed)).1
  let trapped := ({ draggedUp with app := modalSt, pressedEntity := some 105 }).applyFocusTraps (desktopFocusTraps modalSt)
  unless trapped.activeScrollbarDrag.isNone && trapped.pressedEntity.isNone do
    throw <| IO.userError "scrollbar: modal focus trap change must cancel active drag and pressedEntity"
  let afterTrapMove := trapped.stepEvent reduce (.pointerMove gx (vpBounds.y - pxToSub 100))
  unless afterTrapMove.app.scroll == trapped.app.scroll do
    throw <| IO.userError "scrollbar: pointerMove after modal drag cancellation must not scroll"
  -- Fresh scrollRegions reconcile updates drag.geom on limitY growth and clears drag when non-scrollable/absent.
  let grownLimitY : SubPx := pxToSub 2400
  let grownRegion : Runtime.ScrollRegion :=
    { id := transcriptViewportId, bounds := vpBounds, limitY := grownLimitY, offsetY := draggedUp.app.scroll.topSub }
  let grownDrag := Runtime.reconcileScrollbarDrag draggedUp.activeScrollbarDrag [grownRegion]
  unless grownDrag.any (fun d => d.geom.limitY == grownLimitY) do
    throw <| IO.userError s!"scrollbar: reconcileScrollbarDrag did not refresh limitY ({repr grownDrag})"
  let reduceGrown (st : DesktopState) (ev : Event) : DesktopState × Damage :=
    match ev with
    | .scrollTo rid off => applyScrollRegionTo 120 rid grownRegion.bounds grownRegion.limitY grownRegion.offsetY off st
    | _ => (st, none)
  let rtGrown := { draggedUp with scrollRegions := [grownRegion], activeScrollbarDrag := grownDrag }
  let draggedGrownBot := rtGrown.stepEvent reduceGrown (.pointerMove gx (vpBounds.bottom + pxToSub 200))
  unless draggedGrownBot.app.scroll.topSub == grownLimitY && draggedGrownBot.app.scroll.pinned do
    throw <| IO.userError s!"scrollbar: drag after limitY growth remained clamped to stale limit ({repr draggedGrownBot.app.scroll})"
  if (Runtime.reconcileScrollbarDrag grownDrag []).isSome then
    throw <| IO.userError "scrollbar: reconcileScrollbarDrag must clear drag when region disappears"
  if (Runtime.reconcileScrollbarDrag grownDrag [{ grownRegion with limitY := 0 }]).isSome then
    throw <| IO.userError "scrollbar: reconcileScrollbarDrag must clear drag when limitY becomes 0"

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
    -- Verify stepFrameWithRegions refreshes activeScrollbarDrag geometry when limitY grows mid-drag
    -- and clears activeScrollbarDrag when the scroll region becomes non-scrollable.
    let dragBounds : Rect := { x := pxToSub 220, y := pxToSub 35, w := pxToSub 740, h := pxToSub 400 }
    let lim1 : SubPx := pxToSub 1000
    let lim2 : SubPx := pxToSub 2200
    let some g1 := scrollbarGeometry dragBounds lim1 lim1
      | throw <| IO.userError "stepFrameWithRegions: missing initial scrollbar geometry"
    let dragInit : Runtime.ScrollbarDragState := { regionId := transcriptViewportId, grabOffsetSub := pxToSub 10, lastPy := g1.thumbRectSub.y + pxToSub 10, geom := g1 }
    let rtDrag0 := { rt with
      atlas := atlas'
      activeScrollbarDrag := some dragInit
      scrollRegions := [{ id := transcriptViewportId, bounds := dragBounds, limitY := lim1, offsetY := lim1 }]
      damage := some rt.viewportDeviceRect }
    let rtDragGrown ← Runtime.stepFrameWithRegions rtDrag0
      (fun _ s _ => (s, none))
      (fun r => do
        let fv ← view r
        return (fv, [{ id := transcriptViewportId, bounds := dragBounds, limitY := lim2, offsetY := lim1 }]))
    unless rtDragGrown.activeScrollbarDrag.any (fun d => d.geom.limitY == lim2) do
      throw <| IO.userError "stepFrameWithRegions: activeScrollbarDrag geometry was not refreshed on limitY growth"
    let rtDragCleared ← Runtime.stepFrameWithRegions { rtDragGrown with damage := some rtDragGrown.viewportDeviceRect }
      (fun _ s _ => (s, none))
      (fun r => do
        let fv ← view r
        return (fv, [{ id := transcriptViewportId, bounds := dragBounds, limitY := 0, offsetY := 0 }]))
    unless rtDragCleared.activeScrollbarDrag.isNone do
      throw <| IO.userError "stepFrameWithRegions: activeScrollbarDrag was not cleared when limitY became 0"
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
