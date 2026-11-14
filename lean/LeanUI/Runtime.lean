import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.FFI
import LeanUI.Wayland
import LeanUI.Text
import LeanUI.Vulkan
/-!
# LeanUI.Runtime — Single-owner UI state store, damage-gated event loop & `--headless-golden`

Composes `LeanUI.Wayland`, `LeanUI.Text`, `LeanUI.Vulkan`, and the kernel-verified `LeanUI.Kernel`
functions (`Damage.add`, `needsRedraw`, `hitTest`, `FocusState`, `scrollStep`, `focusBorder`,
`focusBorderDamage`, `resizeSub`, `bufferSize`) into a damage-gated runtime with `0` redraws
when quiescent (`needsRedraw damage == false`) and a deterministic `--headless-golden <output.png>`
runner.
-/
namespace LeanUI.Runtime

/-- CLI options parsed by `parseRuntimeArgs`. -/
structure RuntimeConfig where
  headlessGolden : Option System.FilePath := none
  /-- Render offscreen without connecting to a compositor. -/
  headless : Bool := false
  width : Nat := 1280
  height : Nat := 800
  scale120 : Nat := 120
  darkTheme : Bool := true
  maxFrames : Nat := 1
  fontPattern : String := "Inter"
  title : String := "Orb Desktop"
  deriving Repr, Inhabited

/-- Parse CLI arguments (`--headless-golden <path>`, `--width <px>`, `--height <px>`,
`--scale120 <n>`, `--light`, `--dark`, `--frames <n>`). -/
def parseRuntimeArgs (args : List String) : RuntimeConfig :=
  let rec loop (rem : List String) (cfg : RuntimeConfig) : RuntimeConfig :=
    match rem with
    | [] => cfg
    | "--headless-golden" :: path :: rest =>
      loop rest { cfg with headlessGolden := some path }
    | "--width" :: w :: rest =>
      loop rest { cfg with width := w.toNat?.getD cfg.width }
    | "--height" :: h :: rest =>
      loop rest { cfg with height := h.toNat?.getD cfg.height }
    | "--scale120" :: s :: rest =>
      loop rest { cfg with scale120 := s.toNat?.getD cfg.scale120 }
    | "--light" :: rest =>
      loop rest { cfg with darkTheme := false }
    | "--dark" :: rest =>
      loop rest { cfg with darkTheme := true }
    | "--frames" :: n :: rest =>
      loop rest { cfg with maxFrames := n.toNat?.getD cfg.maxFrames }
    | _ :: rest =>
      loop rest cfg
  loop args {}

/-- Single-owner UI state store driving layout, focus, scroll, damage, text atlas, and Vulkan. -/
structure RuntimeState (σ : Type) where
  app : σ
  wayland : Wayland.WaylandClient := {}
  vulkan : Vulkan.VulkanContext := {}
  atlas : Text.GlyphAtlasCache := {}
  primaryFont : Text.FontHandle := { fontId := 1, facePtr := 0, pattern := "sans-serif" }
  focus : FocusState := {}
  windowFocused : Bool := true
  hoveredEntity : Option EntityId := none
  hitRegions : List (EntityId × Rect) := []
  scrollOffsetSub : Nat := 0
  contentHeightSub : Nat := 64000
  damage : Damage := none
  framesRendered : Nat := 0
  quiescentSkips : Nat := 0
  running : Bool := true

namespace RuntimeState

variable {σ : Type}

/-- Full viewport rectangle in device pixels. -/
def viewportDeviceRect (rt : RuntimeState σ) : Rect :=
  let (bw, bh) := rt.wayland.deviceBufferSize
  { x := 0, y := 0, w := (bw : Int), h := (bh : Int) }

/-- Mark a device-pixel `rect` dirty using `Damage.add`. -/
@[inline] def markDirty (rt : RuntimeState σ) (rect : Rect) : RuntimeState σ :=
  { rt with damage := Damage.add rt.damage rect }

/-- Mark the entire viewport dirty. -/
@[inline] def markFullDamage (rt : RuntimeState σ) : RuntimeState σ :=
  rt.markDirty rt.viewportDeviceRect

/-- Request focus for `entityId` via `FocusState.request` and accumulate `focusBorderDamage`
over `focusRect` when focus ownership changes. -/
def requestFocus (rt : RuntimeState σ) (entityId : EntityId) (focusRect : Rect) : RuntimeState σ :=
  let wasFocused := rt.focus.owner == some entityId
  let focus' := rt.focus.request entityId
  let nowFocused := focus'.owner == some entityId
  let borderDmg := focusBorderDamage wasFocused nowFocused focusRect
  let dmg' := match borderDmg with
    | none => rt.damage
    | some r => Damage.add rt.damage r
  { rt with focus := focus', damage := dmg' }

/-- Apply one `Event` to the runtime state and invoke the application's event reducer `onEvent`. -/
def stepEvent (rt : RuntimeState σ) (onEvent : σ → Event → σ × Damage) (ev : Event) :
    RuntimeState σ :=
  let rt1 : RuntimeState σ :=
    match ev with
    | .resize w h =>
      let w1 := if w > 0 then w else rt.wayland.pendingW
      let h1 := if h > 0 then h else rt.wayland.pendingH
      let wl' := { rt.wayland with pendingW := w1, pendingH := h1 }
      let (bw, bh) := wl'.deviceBufferSize
      { rt with wayland := wl', damage := Damage.add rt.damage { x := 0, y := 0, w := (bw : Int), h := (bh : Int) } }
    | .scale s120 =>
      let sc := if s120 > 0 then s120 else 120
      let wl' := { rt.wayland with scale120 := sc }
      let (bw, bh) := wl'.deviceBufferSize
      { rt with wayland := wl', damage := Damage.add rt.damage { x := 0, y := 0, w := (bw : Int), h := (bh : Int) } }
    | .windowFocus f =>
      let dmg := focusBorderDamage rt.windowFocused f rt.viewportDeviceRect
      let d' := match dmg with | none => rt.damage | some r => Damage.add rt.damage r
      { rt with windowFocused := f, damage := d' }
    | .pointerMove px py =>
      let hit := hitTest rt.hitRegions px py
      { rt with hoveredEntity := hit }
    | .pointerLeave =>
      { rt with hoveredEntity := none }
    | .pointerButton px py _btn down =>
      if down then
        match hitTest rt.hitRegions px py with
        | some id =>
          let r := (rt.hitRegions.find? (·.1 == id)).map (·.2) |>.getD rt.viewportDeviceRect
          let devR := roundRectOut rt.wayland.scale120 r
          rt.requestFocus id devR
        | none => rt
      else rt
    | .scroll _px _py _dx dy =>
      let (_, vhSub) := rt.wayland.logicalSubSize
      let nextOff := scrollStep rt.contentHeightSub vhSub rt.scrollOffsetSub dy
      if nextOff == rt.scrollOffsetSub then rt
      else { (rt.markFullDamage) with scrollOffsetSub := nextOff }
    | .closeRequested =>
      { rt with running := false }
    | _ => rt
  let (app', appDmg) := onEvent rt1.app ev
  let finalDmg := match appDmg with
    | none => rt1.damage
    | some r => Damage.add rt1.damage r
  { rt1 with app := app', damage := finalDmg }

end RuntimeState

/-- Execute one frame tick:
1. Pump Wayland events (`Wayland.pumpEvents`) and reduce them through `stepEvent`.
2. Check `needsRedraw rt.damage`: if `false`, skip rendering completely (`quiescentSkips + 1`).
3. If `needsRedraw rt.damage == true`, build the `Scene`, render via `Vulkan.renderFrame`, and
   clear `rt.damage` to `none`. -/
def stepFrame {σ : Type} (rt : RuntimeState σ)
    (onEvent : σ → Event → σ × Damage)
    (view : RuntimeState σ → IO (Text.GlyphAtlasCache × Color × Scene × List (EntityId × Rect))) :
    IO (RuntimeState σ) := do
  let (wl1, evs) ← Wayland.pumpEvents rt.wayland
  let mut st := { rt with wayland := wl1 }
  for ev in evs do
    st := st.stepEvent onEvent ev
  if !needsRedraw st.damage then
    return { st with quiescentSkips := st.quiescentSkips + 1 }
  let (bw, bh) := st.wayland.deviceBufferSize
  let vk0 :=
    if st.vulkan.width != bw || st.vulkan.height != bh then
      { st.vulkan with
        width := bw
        height := bh
        framebuffer := ByteArray.mk (Array.replicate (bw * bh * 4) 0) }
    else st.vulkan
  let (atlas', clearColor, scene, regions) ← view { st with vulkan := vk0 }
  let vk' ← Vulkan.renderFrame vk0 clearColor atlas' scene
  return {
    st with
    vulkan := vk'
    atlas := atlas'
    hitRegions := regions
    damage := none
    framesRendered := st.framesRendered + 1
  }

/-- Build the canonical Orb Desktop canary scene (sidebar, header bar, transcript cards,
code block, focus border, and shaped text labels) at the current scale factor and theme. -/
def buildCanaryScene (rt : RuntimeState Unit) :
    IO (Text.GlyphAtlasCache × Color × Scene × List (EntityId × Rect)) := do
  let (bw, bh) := rt.wayland.deviceBufferSize
  let sc := rt.wayland.scale120
  let px (n : Int) : Int := (n * (sc : Int)) / (scaleDen : Int)
  let pxNat (n : Nat) : Nat := (n * sc) / scaleDen

  let bgClear : Color := 0x0D1117FF
  let sidebarBg : Color := 0x161B22FF
  let headerBg : Color := 0x161B22FF
  let cardBg : Color := 0x1F242DFF
  let codeBg : Color := 0x090D13FF
  let borderCol : Color := 0x30363DFF
  let accentCol : Color := 0x58A6FFFF
  let textPrimary : Color := 0xE6EDF3FF
  let textMuted : Color := 0x8B949EFF

  let sidebarW := px 260
  let headerH := px 48
  let pad := px 20
  let cardW := max 120 ((bw : Int) - sidebarW - 2 * pad)

  let mut prims : Scene := #[]
  -- 1. Left navigation sidebar + 1px right border
  let sidebarRect : Rect := { x := 0, y := 0, w := sidebarW, h := (bh : Int) }
  prims := prims.push (.rrect sidebarRect sidebarBg (0, 0, 0, 0) (0, max 1 (pxNat 1), 0, 0) borderCol)

  -- 2. Active mission pill in sidebar
  let pillRect : Rect := { x := px 12, y := px 60, w := sidebarW - px 24, h := px 36 }
  prims := prims.push (.quad pillRect 0x1F6FEB33 (pxNat 8) (max 1 (pxNat 1)) accentCol)

  -- 3. Top header bar
  let headerRect : Rect := { x := sidebarW, y := 0, w := (bw : Int) - sidebarW, h := headerH }
  prims := prims.push (.rrect headerRect headerBg (0, 0, 0, 0) (0, 0, max 1 (pxNat 1), 0) borderCol)

  -- 4. Transcript card with SDF drop shadow + rounded border
  let cardRect : Rect := { x := sidebarW + pad, y := headerH + pad, w := cardW, h := px 220 }
  prims := prims.push (.shadow cardRect 0x00000066 (pxNat 10) (max 2 (pxNat 6)))
  prims := prims.push (.quad cardRect cardBg (pxNat 10) (max 1 (pxNat 1)) borderCol)

  -- 5. Code block container inside transcript card
  let codeRect : Rect :=
    { x := cardRect.x + px 16
      y := cardRect.y + px 64
      w := max 60 (cardRect.w - px 32)
      h := px 120 }
  prims := prims.push (.quad codeRect codeBg (pxNat 6) (max 1 (pxNat 1)) borderCol)

  -- 6. Bottom composer input box with kernel `focusBorder`
  let compRect : Rect :=
    { x := sidebarW + pad
      y := max (cardRect.bottom + pad) ((bh : Int) - px 84)
      w := cardW
      h := px 56 }
  prims := prims.push (.quad compRect cardBg (pxNat 10) (max 1 (pxNat 1)) borderCol)
  let focused := rt.focus.owner == some 1
  prims := prims.push (focusBorder focused compRect accentCol)

  -- 7. Shape & rasterize UI text runs into the shelf-packed glyph atlas if a font face is open
  let mut ac := rt.atlas
  if rt.primaryFont.facePtr != 0 then
    let (ac1, _, titleGlyphs) ←
      Text.layoutTextRun ac rt.primaryFont (15 * subPerPx) sc
        ((sidebarW + pad) * (subPerPx : Int) * (scaleDen : Int) / (sc : Int))
        ((px 30) * (subPerPx : Int) * (scaleDen : Int) / (sc : Int))
        textPrimary "LeanUI Wayland + Vulkan 1.3 Native Runtime"
    let (ac2, _, codeGlyphs) ←
      Text.layoutTextRun ac1 rt.primaryFont (13 * subPerPx) sc
        ((codeRect.x + px 14) * (subPerPx : Int) * (scaleDen : Int) / (sc : Int))
        ((codeRect.y + px 32) * (subPerPx : Int) * (scaleDen : Int) / (sc : Int))
        textMuted "theorem needsRedraw_none : needsRedraw none = false := rfl"
    ac := ac2
    prims := prims ++ titleGlyphs ++ codeGlyphs

  let subScale (v : Int) : Int := (v * (subPerPx : Int) * (scaleDen : Int)) / (max 1 (sc : Int))
  let compSubRect : Rect :=
    { x := subScale compRect.x, y := subScale compRect.y
      w := subScale compRect.w, h := subScale compRect.h }
  return (ac, bgClear, prims, [(1, compSubRect)])

/-- `RuntimeState` for the Wayland session `wl`, with the whole viewport damaged. -/
def initRuntimeOn {σ : Type} (cfg : RuntimeConfig) (wl : Wayland.WaylandClient) (initialApp : σ) :
    IO (RuntimeState σ) := do
  let (bw, bh) := wl.deviceBufferSize
  let vk ← Vulkan.initVulkan bw bh
  let font ← Text.openFont 1 cfg.fontPattern
  let focus0 : FocusState := { owner := some 1, traps := [] }
  let initDmg : Damage := some { x := 0, y := 0, w := (bw : Int), h := (bh : Int) }
  return {
    app := initialApp
    wayland := wl
    vulkan := vk
    atlas := { pageWidth := 1024, pageHeight := 1024, pad := 1 }
    primaryFont := font
    focus := focus0
    windowFocused := true
    damage := initDmg
  }

/-- Initialize `RuntimeState` from `RuntimeConfig`. -/
def initRuntime {σ : Type} (cfg : RuntimeConfig) (initialApp : σ) : IO (RuntimeState σ) := do
  let wl ← Wayland.connectOrHeadless (cfg.headless || cfg.headlessGolden.isSome) cfg.width cfg.height cfg.scale120
  initRuntimeOn cfg wl initialApp

/-- Open the application window. Fails when no Wayland compositor can show it. -/
def openWindowRuntime {σ : Type} (cfg : RuntimeConfig) (appId : String) (initialApp : σ) :
    IO (RuntimeState σ) := do
  let wl ← Wayland.openWindow cfg.title appId cfg.width cfg.height cfg.scale120
  initRuntimeOn cfg wl initialApp

/-- Run the window until it is closed: render and present when there is damage, otherwise
block on the compositor. Nothing is drawn before the first `xdg_surface.configure`. -/
def runWindow {σ : Type} (rt0 : RuntimeState σ)
    (onEvent : RuntimeState σ → σ → Event → σ × Damage)
    (view : RuntimeState σ → IO (Text.GlyphAtlasCache × Color × Scene × List (EntityId × Rect))) :
    IO (RuntimeState σ) := do
  let mut rt := rt0
  while rt.running do
    if !rt.wayland.configured then
      Wayland.waitEvents rt.wayland
      let (wl, evs) ← Wayland.pumpEvents rt.wayland
      rt := { rt with wayland := wl }
      for ev in evs do
        rt := rt.stepEvent (onEvent rt) ev
    else
      let rendered := rt.framesRendered
      rt ← stepFrame rt (onEvent rt) view
      if rt.framesRendered != rendered then
        let wl ← Wayland.present rt.wayland rt.vulkan.framebuffer
        rt := { rt with wayland := wl }
      else if rt.running then
        Wayland.waitEvents rt.wayland
  return rt

/-- Cleanly release font and Vulkan scratch resources owned by `RuntimeState`. -/
def shutdownRuntime {σ : Type} (rt : RuntimeState σ) : IO Unit := do
  if rt.wayland.xkbState != 0 then
    FFI.xkbFree rt.wayland.xkbState
  Text.closeFont rt.primaryFont
  Vulkan.shutdownVulkan rt.vulkan
  Wayland.closeWindow rt.wayland

/-- Run the canonical Orb Desktop runtime or `--headless-golden <output.png>` verification pass. -/
def runMain (args : List String) : IO UInt32 := do
  let cfg := parseRuntimeArgs args
  let rt0 ← initRuntime cfg ()
  let onEv : Unit → Event → Unit × Damage := fun (_ : Unit) (_ : Event) => ((), none)
  let mut rt ← stepFrame rt0 onEv buildCanaryScene
  let extraFrames := if cfg.maxFrames > 1 then cfg.maxFrames - 1 else 1
  for _ in [0:extraFrames] do
    if rt.running then
      rt ← stepFrame rt onEv buildCanaryScene
  if let some outPath := cfg.headlessGolden then
    if let some parent := outPath.parent then
      IO.FS.createDirAll parent
    Vulkan.writeFramebufferPNG rt.vulkan outPath
  shutdownRuntime rt
  return 0

/-- Alias for `runMain` accepting CLI argument lists. -/
abbrev main (args : List String) : IO UInt32 := runMain args

end LeanUI.Runtime
