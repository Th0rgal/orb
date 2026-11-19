import LeanUI.Runtime
import OrbDesktop.State

namespace OrbDesktop
open LeanUI

/-- Differential fixtures for invalidations that the stream benchmark does not force. -/
def verifyRepaintEdges : IO Unit := do
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
  let root := WidgetNode.box (BoxStyle.row (pxToSub 16)) [button 1, button 2]
  let view (f : FocusState) := (renderWidgetTree 120 (pxToSub 80) (pxToSub 24) f theme root).2
  let focus : FocusState := { owner := some 1 }
  let first := view focus
  let rt : Runtime.RuntimeState Unit := { app := (), focus, hitRegions := first.hitRegionsSub }
  let some (_, target) := first.hitRegionsSub.find? (·.1 == 2)
    | throw <| IO.userError "focus: missing target"
  let clicked := rt.stepEvent (fun s _ => (s, none))
    (.pointerButton (target.x + target.w/2) (target.y + target.h/2) 1 true)
  unless clicked.focus.owner == some 2 do throw <| IO.userError "focus: transfer failed"
  let base ← Vulkan.renderFrame { width := 80, height := 24 } theme.palette.canvas {} first.prims
  let got ← checkPartial "focus transfer" base clicked.damage {} theme.palette.canvas (view clicked.focus).prims
  for (id, r) in first.hitRegionsDev do
    let differs := (List.range r.h.toNat).any fun y => (List.range r.w.toNat).any fun x =>
      let i := 4 * ((r.y.toNat + y) * base.width + r.x.toNat + x)
      base.framebuffer.extract i (i+4) != got.framebuffer.extract i (i+4)
    unless differs do throw <| IO.userError s!"focus: border {id} did not change"

def verifyDesktopEdges (view : Runtime.RuntimeState DesktopState → IO Runtime.FrameView)
    (shape : Text.GlyphAtlasCache → Text.FontHandle → Nat → TextStyle → String →
      IO (Text.GlyphAtlasCache × List InlineRun)) : IO Unit := do
  verifyFocusTransfer
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

    let label ac := shape ac rt.primaryFont 120 (Theme.bodyText st.theme)
    let mut ac : Text.GlyphAtlasCache := {}
    for i in [:130] do ac := (← label ac s!"label{i}").1
    let boundary := String.ofList (List.replicate 64 'é') -- exactly 128 UTF-8 bytes
    ac := (← label ac boundary).1
    let shaped := ac.shapeCache.map (·.text)
    let resolved := ac.resolved.map (·.text)
    unless shaped.size == 64 && resolved.size == 128 && shaped.back? == some boundary &&
        resolved.back? == some boundary && !shaped.contains "label0" && !resolved.contains "label0" do
      throw <| IO.userError "shape caches: expected bounded short-label retention"
    for text in [boundary ++ "x", String.ofList (List.replicate 4096 'w')] do
      let (next, runs) ← label ac text
      unless runs.any (fun r => !r.glyphs.isEmpty) && next.shapeCache.map (·.text) == shaped &&
          next.resolved.map (·.text) == resolved do
        throw <| IO.userError s!"shape caches: oversized {text.utf8ByteSize}-byte input not shaped or retained keys changed"
      ac := next
  finally Runtime.shutdownRuntime rt

end OrbDesktop
