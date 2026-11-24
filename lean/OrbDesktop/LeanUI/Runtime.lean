import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Scene
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

/-- Re-export shared text-input entity predicate from `LeanUI.Defs`. -/
@[inline] abbrev isTextInputEntity := LeanUI.isTextInputEntity

def cycleFocusRuntime (focusState : FocusState) (order : List EntityId) : FocusState :=
  let admitted := order.filter focusState.admits
  match admitted with
  | [] => focusState
  | first :: _ =>
    match focusState.owner with
    | none => focusState.request first
    | some current =>
      let rec next : List EntityId → Option EntityId
        | [] => none
        | [x] => if x == current then some first else none
        | x :: y :: rest => if x == current then some y else next (y :: rest)
      focusState.request ((next admitted).getD first)

/-- CLI options parsed by `parseRuntimeArgs`. -/
structure RuntimeConfig where
  headlessGolden : Option System.FilePath := none
  /-- Render offscreen without connecting to a compositor. -/
  headless : Bool := false
  /-- Requested GPU backend mode (`auto`, `disabled`, `present`, `instanced`, `lavapipe`). -/
  gpuMode : Vulkan.GpuModeRequest := .auto
  /-- Offscreen Vulkan readback directory (CI differential parity harness only). -/
  gpuReadbackDir : Option System.FilePath := none
  width : Nat := 1280
  height : Nat := 800
  scale120 : Nat := 120
  darkTheme : Bool := true
  maxFrames : Nat := 1
  fontPattern : String := "IBM Plex Sans,Inter,sans-serif"
  title : String := "Orb Desktop"
  deriving Repr, Inhabited

/-- Parse CLI arguments (`--headless-golden <path>`, `--headless`, `--no-gpu`, `--gpu`,
`--gpu=present`, `--gpu=instanced`, `--gpu=lavapipe`, `--gpu-readback <dir>`, `--width <px>`,
`--height <px>`, `--scale120 <n>`, `--light`, `--dark`, `--frames <n>`). -/
def parseRuntimeArgs (args : List String) : RuntimeConfig :=
  let rec loop (rem : List String) (cfg : RuntimeConfig) : RuntimeConfig :=
    match rem with
    | [] => cfg
    | "--headless-golden" :: path :: rest =>
      loop rest { cfg with headlessGolden := some path }
    | "--headless" :: rest =>
      loop rest { cfg with headless := true }
    | "--no-gpu" :: rest =>
      loop rest { cfg with gpuMode := .disabled }
    | "--gpu" :: rest =>
      loop rest { cfg with gpuMode := .instanced }
    | "--gpu=present" :: rest =>
      loop rest { cfg with gpuMode := .present }
    | "--gpu=instanced" :: rest =>
      loop rest { cfg with gpuMode := .instanced }
    | "--gpu=lavapipe" :: rest =>
      loop rest { cfg with gpuMode := .lavapipe }
    | "--gpu-readback" :: dir :: rest =>
      loop rest { cfg with gpuReadbackDir := some dir }
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

structure ScrollRegion where
  id : EntityId
  bounds : Rect
  limitY : SubPx
  offsetY : SubPx := 0
  textLines : List WrappedLine := []
  deriving Inhabited

/-- Active pointer drag state for an overlay scrollbar thumb or track-jump drag. -/
structure ScrollbarDragState where
  regionId : EntityId
  grabOffsetSub : Int
  lastPy : Int
  geom : ScrollbarGeometry
  deriving DecidableEq, Repr, Inhabited

/-- Refresh an active scrollbar drag's geometry against the latest `scrollRegions` produced by
`view`, clearing the drag if its region vanished or became non-scrollable (`limitY == 0`). -/
def reconcileScrollbarDrag (drag? : Option ScrollbarDragState)
    (scrollRegions : List ScrollRegion) : Option ScrollbarDragState :=
  drag?.bind fun drag =>
    (scrollRegions.find? (·.id == drag.regionId)).bind fun r =>
      (scrollbarGeometry r.bounds r.limitY r.offsetY).map fun geom =>
        { drag with geom }

/-- Find the topmost scrollable `ScrollRegion` whose right-edge scrollbar gutter contains `(px, py)`. -/
def hitTestScrollbar (regions : List ScrollRegion) (px py : Int) :
    Option (ScrollRegion × ScrollbarGeometry) :=
  regions.foldl (fun acc r =>
    match scrollbarGeometry r.bounds r.limitY r.offsetY with
    | some g => if g.trackRectSub.contains px py then some (r, g) else acc
    | none => acc) none

abbrev FrameView := Text.GlyphAtlasCache × Color × Scene × List (EntityId × Rect) × List EntityId

/-- Single-owner UI state store driving layout, focus, scroll, damage, text atlas, and Vulkan. -/
structure RuntimeState (σ : Type) where
  app : σ
  wayland : Wayland.WaylandClient := {}
  vulkan : Vulkan.VulkanContext := {}
  atlas : Text.GlyphAtlasCache := {}
  primaryFont : Text.FontHandle := { fontId := 1, facePtr := 0, pattern := "IBM Plex Sans,Inter,sans-serif" }
  monoFont : Text.FontHandle := { fontId := 2, facePtr := 0, pattern := "Lilex Nerd Font,Lilex,IBM Plex Mono,DejaVu Sans Mono,monospace" }
  boldFont : Text.FontHandle := { fontId := 3, facePtr := 0, pattern := "IBM Plex Sans,Inter,sans-serif:weight=bold" }
  mediumFont : Text.FontHandle := { fontId := 4, facePtr := 0, pattern := "IBM Plex Sans,Inter,sans-serif:weight=medium" }
  semiboldFont : Text.FontHandle := { fontId := 5, facePtr := 0, pattern := "IBM Plex Sans,Inter,sans-serif:weight=demibold" }
  focus : FocusState := {}
  /-- Keyboard-initiated focus ring visibility (`:focus-visible`). True on Tab/Shift+Tab, false on pointer click. -/
  focusVisible : Bool := true
  windowFocused : Bool := true
  lastImeOwner : Option EntityId := none
  hoveredEntity : Option EntityId := none
  hitRegions : List (EntityId × Rect) := []
  scrollRegions : List ScrollRegion := []
  activeScrollbarDrag : Option ScrollbarDragState := none
  focusableOrder : List EntityId := []
  pressedEntity : Option EntityId := none
  scrollOffsetSub : Nat := 0
  contentHeightSub : Nat := 64000
  damage : Damage := none
  framesRendered : Nat := 0
  quiescentSkips : Nat := 0
  presentCount : Nat := 0
  frameCallbackSkips : Nat := 0
  lastFrameTotalNs : UInt64 := 0
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

/-- Device-pixel rect for a hit-testable entity, falling back to `viewportDeviceRect`. -/
def entityDeviceRect (rt : RuntimeState σ) (id : EntityId) : Rect :=
  match rt.hitRegions.find? (·.1 == id) with
  | some (_, r) => roundRectOut rt.wayland.scale120 r
  | none => rt.viewportDeviceRect

/-- Update modal focus traps; whenever traps change (e.g. a modal/menu opens or closes),
cancel any active scrollbar drag and pressed entity and damage the viewport. -/
def applyFocusTraps (rt : RuntimeState σ) (traps' : List (List EntityId)) : RuntimeState σ :=
  if traps' != rt.focus.traps then
    { rt with
      focus := { rt.focus with traps := traps' }
      activeScrollbarDrag := none
      pressedEntity := none
      damage := Damage.add rt.damage rt.viewportDeviceRect }
  else rt

/-- Clear keyboard `:focus-visible` modality (e.g. on pointer interaction), damaging any previously
visible non-text focus ring so it disappears cleanly. -/
def clearFocusVisible (rt : RuntimeState σ) : RuntimeState σ :=
  if !rt.focusVisible then rt
  else
    let dmg' := match rt.focus.owner with
      | some old =>
        if isTextInputEntity old then rt.damage
        else Damage.add rt.damage (rt.entityDeviceRect old)
      | none => rt.damage
    { rt with focusVisible := false, damage := dmg' }

/-- Request focus for `entityId` with explicit `:focus-visible` modality and minimal border damage. -/
def requestFocusWithVisibility (rt : RuntimeState σ) (entityId : EntityId) (focusRect : Rect)
    (visible : Bool) : RuntimeState σ :=
  let wasOwner := rt.focus.owner == some entityId
  let focus' := rt.focus.request entityId
  let nowOwner := focus'.owner == some entityId
  let wasShown := wasOwner && (isTextInputEntity entityId || rt.focusVisible)
  let nowShown := nowOwner && (isTextInputEntity entityId || visible)
  let borderDmg := focusBorderDamage wasShown nowShown focusRect
  let dmg' := match borderDmg with
    | none => rt.damage
    | some r => Damage.add rt.damage r
  let dmg' :=
    match rt.focus.owner with
    | none => dmg'
    | some old =>
      if old != entityId && focus'.owner != rt.focus.owner && (isTextInputEntity old || rt.focusVisible) then
        Damage.add dmg' (rt.entityDeviceRect old)
      else if old != entityId && focus'.owner == rt.focus.owner && rt.focusVisible && !visible && !isTextInputEntity old then
        Damage.add dmg' (rt.entityDeviceRect old)
      else dmg'
  { rt with focus := focus', focusVisible := visible, damage := dmg' }

/-- Request focus for `entityId` via `FocusState.request` preserving current `focusVisible` modality
and accumulating `focusBorderDamage` over `focusRect` when visible focus changes. -/
def requestFocus (rt : RuntimeState σ) (entityId : EntityId) (focusRect : Rect) : RuntimeState σ :=
  rt.requestFocusWithVisibility entityId focusRect rt.focusVisible

/-- Apply one `Event` to the runtime state and invoke the application's event reducer `onEvent`. -/
def stepEvent (rt : RuntimeState σ) (onEvent : σ → Event → σ × Damage) (ev : Event) :
    RuntimeState σ :=
  -- Consume pointer press/move/release when interacting with an overlay scrollbar so
  -- dragging never clicks, focuses, or activates underlying rows/widgets.
  match ev with
  | .pointerButton px py 0x110 true =>
    if let some (region, geom) := hitTestScrollbar rt.scrollRegions px py then
      let (nextOff, grabOffsetSub) := geom.pointerPress region.offsetY px py
      let drag : ScrollbarDragState :=
        { regionId := region.id, grabOffsetSub, lastPy := py, geom }
      let rt0 := { rt.clearFocusVisible with pressedEntity := none, activeScrollbarDrag := some drag }
      let (app', appDmg) := onEvent rt0.app (.scrollTo region.id nextOff)
      let finalDmg := appDmg.elim rt0.damage (Damage.add rt0.damage)
      { rt0 with app := app', damage := finalDmg }
    else
      stepEventNormal rt onEvent ev
  | .pointerMove _px py =>
    if let some drag := rt.activeScrollbarDrag then
      if py == drag.lastPy then rt
      else
        let nextOff := drag.geom.offsetForThumbTop (py - drag.grabOffsetSub)
        let (app', appDmg) := onEvent rt.app (.scrollTo drag.regionId nextOff)
        let finalDmg := appDmg.elim rt.damage (Damage.add rt.damage)
        { rt with
          app := app'
          activeScrollbarDrag := some { drag with lastPy := py }
          damage := finalDmg }
    else
      stepEventNormal rt onEvent ev
  | .pointerButton _px _py 0x110 false =>
    if rt.activeScrollbarDrag.isSome then
      { rt with activeScrollbarDrag := none, pressedEntity := none }
    else
      stepEventNormal rt onEvent ev
  | _ => stepEventNormal rt onEvent ev
where
  stepEventNormal (rt : RuntimeState σ) (onEvent : σ → Event → σ × Damage) (ev : Event) :
      RuntimeState σ :=
    let rt1 : RuntimeState σ :=
      match ev with
      | .resize w h =>
        let w1 := if w > 0 then w else rt.wayland.pendingW
        let h1 := if h > 0 then h else rt.wayland.pendingH
        let wl' := { rt.wayland with pendingW := w1, pendingH := h1 }
        let (bw, bh) := wl'.deviceBufferSize
        { rt with
          wayland := wl'
          activeScrollbarDrag := none
          damage := Damage.add rt.damage { x := 0, y := 0, w := (bw : Int), h := (bh : Int) } }
      | .scale s120 =>
        let sc := if s120 > 0 then s120 else 120
        let wl' := { rt.wayland with scale120 := sc }
        let (bw, bh) := wl'.deviceBufferSize
        { rt with wayland := wl', damage := Damage.add rt.damage { x := 0, y := 0, w := (bw : Int), h := (bh : Int) } }
      | .windowFocus f =>
        let dmg := focusBorderDamage rt.windowFocused f rt.viewportDeviceRect
        let d' := match dmg with | none => rt.damage | some r => Damage.add rt.damage r
        { rt with
          windowFocused := f
          activeScrollbarDrag := if f then rt.activeScrollbarDrag else none
          damage := d' }
      | .pointerMove px py =>
        let hit := hitTest rt.hitRegions px py
        { rt with hoveredEntity := hit }
      | .pointerLeave =>
        { rt with hoveredEntity := none }
      | .pointerButton px py button down =>
        if button != 0x110 then
          if down then rt.clearFocusVisible else rt
        else if down then
          match hitTest rt.hitRegions px py with
          | some id =>
            let r := (rt.hitRegions.find? (·.1 == id)).map (·.2) |>.getD rt.viewportDeviceRect
            let devR := roundRectOut rt.wayland.scale120 r
            let focused := if rt.focusableOrder.isEmpty || rt.focusableOrder.contains id then
                rt.requestFocusWithVisibility id devR false
              else rt.clearFocusVisible
            { focused with pressedEntity := some id }
          | none => rt.clearFocusVisible
        else
          match hitTest rt.hitRegions px py, rt.pressedEntity with
          | some id, some pressed =>
            let rt' := { rt with pressedEntity := none }
            if id == pressed then
              let (app', appDmg) := onEvent rt'.app (.activate id)
              let finalDmg := match appDmg with
                | none => rt'.damage
                | some r => Damage.add rt'.damage r
              { rt' with app := app', damage := finalDmg }
            else rt'
          | _, _ => { rt with pressedEntity := none }
      | .scroll _px _py _dx dy =>
        if !rt.scrollRegions.isEmpty then rt else
        let (_, vhSub) := rt.wayland.logicalSubSize
        let nextOff := scrollStep rt.contentHeightSub vhSub rt.scrollOffsetSub dy
        if nextOff == rt.scrollOffsetSub then rt
        else { (rt.markFullDamage) with scrollOffsetSub := nextOff }
      | .closeRequested =>
        { rt with running := false, activeScrollbarDrag := none }
      | .key keysym mods state =>
        if state == .pressed || state == .repeated then
          -- Tab is handled here so every screen shares one focus traversal policy.
          if keysym == 0xff09 || keysym == 0xfe20 then
            let reverse := keysym == 0xfe20 || mods &&& 1 != 0
            let focus' := cycleFocusRuntime rt.focus (if reverse then rt.focusableOrder.reverse else rt.focusableOrder)
            let dmg' :=
              if focus'.owner == rt.focus.owner && rt.focusVisible then rt.damage
              else
                let d0 := match rt.focus.owner with
                  | some old =>
                    if isTextInputEntity old || rt.focusVisible then
                      Damage.add rt.damage (rt.entityDeviceRect old)
                    else rt.damage
                  | none => rt.damage
                match focus'.owner with
                | some nextId => Damage.add d0 (rt.entityDeviceRect nextId)
                | none => d0
            { rt with focus := focus', focusVisible := true, damage := dmg' }
          else if keysym == 0xff0d || keysym == 0xff8d || keysym == 0x20 then
            match rt.focus.owner with
            | some id =>
              let isInput := isTextInputEntity id && (rt.focusableOrder.isEmpty || rt.focusableOrder.contains id)
              -- Space inserts a space character into focused text inputs rather than activating them.
              if isInput && keysym == 0x20 then rt
              else
                let editorReturn := isInput && keysym != 0x20
                if state == .repeated then rt else
                let action := if editorReturn then
                    Event.composerReturn (mods &&& 1 != 0)
                  else Event.activate id
                let (app', appDmg) := onEvent rt.app action
                let finalDmg := match appDmg with
                  | none => rt.damage
                  | some r => Damage.add rt.damage r
                { rt with app := app', damage := finalDmg }
            | none => rt
          else rt
        else rt
      | _ => rt
    let isActiveInput (st : RuntimeState σ) : Bool :=
      st.focus.owner.any (fun id => isTextInputEntity id && (st.focusableOrder.isEmpty || st.focusableOrder.contains id))
    let wasInput := isActiveInput rt
    let isInputNow := isActiveInput rt1
    let lostEditor := wasInput &&
      (!isInputNow || rt1.focus.owner != rt.focus.owner || (rt.windowFocused && !rt1.windowFocused))
    let rt1 := if lostEditor then
        let (app, dmg) := onEvent rt1.app (.preedit "" 0 0)
        { rt1 with app, damage := dmg.elim rt1.damage (Damage.add rt1.damage) }
      else rt1
    let isText := match ev with
      | .text _ | .preedit .. | .imeBatch .. => true
      | _ => false
    if isText && !isInputNow then rt1 else
    let (app', appDmg) := onEvent rt1.app ev
    let finalDmg := match appDmg with
      | none => rt1.damage
      | some r => Damage.add rt1.damage r
    { rt1 with app := app', damage := finalDmg }

/-- Return the synthesized activation event (`.activate id` or `.composerReturn`) that
`stepEvent` dispatches for `ev`, or `ev` itself when no activation occurs. -/
def effectiveEvent (rt : RuntimeState σ) (ev : Event) : Event :=
  match ev with
  | .pointerButton px py 0x110 false =>
    if rt.activeScrollbarDrag.isSome then ev
    else match hitTest rt.hitRegions px py, rt.pressedEntity with
    | some id, some pressed => if id == pressed then .activate id else ev
    | _, _ => ev
  | .key keysym mods state =>
    if (state == .pressed || state == .repeated) &&
        (keysym == 0xff0d || keysym == 0xff8d || keysym == 0x20) then
      match rt.focus.owner with
      | some id =>
        let isInput := isTextInputEntity id && (rt.focusableOrder.isEmpty || rt.focusableOrder.contains id)
        if isInput && keysym == 0x20 then ev
        else if state == .repeated then ev
        else if isInput then .composerReturn (mods &&& 1 != 0)
        else .activate id
      | none => ev
    else ev
  | _ => ev

/-- Apply one `Event` and reconcile focus via `focusChange`, passing the synthesized
`.activate` / `.composerReturn` event whenever `stepEvent` dispatched one. -/
def stepEventWithFocus (rt : RuntimeState σ) (onEvent : σ → Event → σ × Damage)
    (focusChange : σ → σ → Event → Option Nat) (ev : Event) : RuntimeState σ :=
  let before := rt.app
  let dispatched := rt.effectiveEvent ev
  let rt' := rt.stepEvent onEvent ev
  match focusChange before rt'.app dispatched with
  | some target => rt'.requestFocus target rt'.viewportDeviceRect
  | none => rt'

end RuntimeState

/-- Coalesce adjacent `.scroll` events in the same Wayland frame (absorbing interleaved `.time`
stamps emitted by `wl_pointer.axis`) so high-rate touchpad bursts update layout and repaint
once per frame. Only merges matching pointer coordinates and same-sign axis deltas to preserve
cross-container routing, clamping, and `Orb.Scroll` unpinning transitions. -/
def coalesceScrollEvents (evs : Array Event) : Array Event :=
  evs.foldl (init := #[]) fun acc ev =>
    match ev with
    | .scroll x2 y2 dx2 dy2 =>
      if dx2 == 0 && dy2 == 0 then acc
      else
        let canMerge (x1 y1 dx1 dy1 : Int) : Bool :=
          x1 == x2 && y1 == y2 && dx1 * dx2 ≥ 0 && dy1 * dy2 ≥ 0
        match acc.back? with
        | some (.scroll x1 y1 dx1 dy1) =>
          if canMerge x1 y1 dx1 dy1 then
            acc.pop.push (.scroll x1 y1 (dx1 + dx2) (dy1 + dy2))
          else acc.push ev
        | some (.time t) =>
          match acc[acc.size - 2]? with
          | some (.scroll x1 y1 dx1 dy1) =>
            if canMerge x1 y1 dx1 dy1 then
              let base := acc.pop.pop
              let base := match base.back? with | some (.time _) => base.pop | _ => base
              base.push (.time t) |>.push (.scroll x1 y1 (dx1 + dx2) (dy1 + dy2))
            else acc.push ev
          | _ => acc.push ev
        | _ => acc.push ev
    | _ => acc.push ev

/-- Execute one frame tick:
1. Pump Wayland events (`Wayland.pumpEvents`) and reduce them through `stepEvent`.
2. Check `needsRedraw rt.damage`: if `false`, skip rendering completely (`quiescentSkips + 1`).
3. If `needsRedraw rt.damage == true`, build the `Scene`, render via `Vulkan.renderFrame`, and
   clear `rt.damage` to `none`. -/
def stepFrameWithRegions {σ : Type} (rt : RuntimeState σ)
    (onEvent : RuntimeState σ → σ → Event → σ × Damage)
    (view : RuntimeState σ → IO (FrameView × List ScrollRegion))
    (focusChange : σ → σ → Event → Option Nat := fun _ _ _ => none)
    (focusTraps : σ → List (List EntityId) := fun _ => []) :
    IO (RuntimeState σ) := do
  let (wl1, evs) ← Wayland.pumpEvents rt.wayland
  let evs := coalesceScrollEvents evs
  let mut st := { rt with wayland := wl1 }
  for ev in evs do
    let before := st.app
    let prevOwner := st.focus.owner
    let dispatched := st.effectiveEvent ev
    st := st.stepEvent (onEvent st) ev
    st := st.applyFocusTraps (focusTraps st.app)
    if let some target := focusChange before st.app dispatched then
      st := st.requestFocus target st.viewportDeviceRect
      if prevOwner.any isTextInputEntity && st.focus.owner != prevOwner then
        let (app', dmg') := onEvent st st.app (.preedit "" 0 0)
        st := { st with app := app', damage := dmg'.elim st.damage (Damage.add st.damage) }
  if !needsRedraw st.damage then
    return { st with quiescentSkips := st.quiescentSkips + 1 }
  if !st.wayland.headless && st.wayland.frameCallbackPending && !st.wayland.configurePendingCommit then
    return { st with frameCallbackSkips := st.frameCallbackSkips + 1 }
  let frameT0 ← IO.monoNanosNow
  let (bw, bh) := st.wayland.deviceBufferSize
  let vk0 :=
    if st.vulkan.width != bw || st.vulkan.height != bh then
      { st.vulkan with
        width := bw
        height := bh
        framebuffer := ByteArray.empty }
    else st.vulkan
  let ((atlas', clearColor, scene, regions, focusOrder), scrollRegions) ← view { st with vulkan := vk0 }
  let activeScrollbarDrag := reconcileScrollbarDrag st.activeScrollbarDrag scrollRegions
  -- Transfer the old surface into the painter; retaining it in `st` forces
  -- a framebuffer-sized copy even for a small in-place repaint.
  st := { st with vulkan := default }
  if !st.wayland.headless && vk0.backend != .cpuShm then
    let wlRef ← IO.mkRef st.wayland
    let prePresent : IO Unit := do
      let wlA ← Wayland.syncViewportDestination (← wlRef.get)
      let wlB ← Wayland.requestFrameCallback wlA
      wlRef.set wlB
    let onAborted : IO Unit := do
      let wlC ← Wayland.cancelFrameCallback (← wlRef.get)
      wlRef.set wlC
    let (vkGpu, atlasGpu, presentedByVk) ←
      Vulkan.renderAndPresentGpu vk0 clearColor atlas' scene st.damage prePresent onAborted
    let wlAfter ← wlRef.get
    if presentedByVk then
      let frameT1 ← IO.monoNanosNow
      return {
        st with
        wayland := wlAfter
        vulkan := vkGpu
        atlas := atlasGpu
        hitRegions := regions
        scrollRegions
        activeScrollbarDrag
        focusableOrder := focusOrder
        damage := none
        framesRendered := st.framesRendered + 1
        presentCount := st.presentCount + 1
        lastFrameTotalNs := (frameT1 - frameT0).toUInt64
      }
    -- Runtime DEVICE_LOST fallback: render CPU frame so `runWindow` presents via `wl_shm`.
    let vkCpu ← Vulkan.renderFrame vkGpu clearColor atlasGpu scene
    let frameT1 ← IO.monoNanosNow
    return {
      st with
      wayland := wlAfter
      vulkan := vkCpu
      atlas := atlasGpu
      hitRegions := regions
      scrollRegions
      activeScrollbarDrag
      focusableOrder := focusOrder
      damage := none
      framesRendered := st.framesRendered + 1
      lastFrameTotalNs := (frameT1 - frameT0).toUInt64
    }
  let vk' ← match st.damage with
    | some dirty => Vulkan.renderFrameDamage vk0 clearColor atlas' dirty scene
    | none => Vulkan.renderFrame vk0 clearColor atlas' scene
  let frameT1 ← IO.monoNanosNow
  return {
    st with
    vulkan := vk'
    atlas := atlas'
    hitRegions := regions
    scrollRegions
    activeScrollbarDrag
    focusableOrder := focusOrder
    damage := none
    framesRendered := st.framesRendered + 1
    lastFrameTotalNs := (frameT1 - frameT0).toUInt64
  }

/-- Frame tick for views without independently scrollable input regions. -/
def stepFrame {σ : Type} (rt : RuntimeState σ) (onEvent : σ → Event → σ × Damage)
    (view : RuntimeState σ → IO FrameView) : IO (RuntimeState σ) :=
  stepFrameWithRegions rt (fun _ => onEvent) fun st => do return (← view st, [])

/-- Build the canonical Orb Desktop canary scene. -/
def buildCanaryScene (rt : RuntimeState Unit) :
    IO (Text.GlyphAtlasCache × Color × Scene × List (EntityId × Rect) × List EntityId) := do
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
  return (ac, bgClear, prims, [(1, compSubRect)], [1])

/-- `RuntimeState` for the Wayland session `wl`, with the whole viewport damaged. -/
def initRuntimeOn {σ : Type} (cfg : RuntimeConfig) (wl : Wayland.WaylandClient) (initialApp : σ) :
    IO (RuntimeState σ) := do
  let (bw, bh) := wl.deviceBufferSize
  let useCpuOnly := wl.headless || cfg.headless || cfg.headlessGolden.isSome
  let vk ←
    if useCpuOnly then Vulkan.initVulkan bw bh
    else Vulkan.initVulkanSurface bw bh wl.display wl.window.surface cfg.gpuMode wl.hasLinuxDmabuf
  let primaryPat := if cfg.headlessGolden.isSome then "Inter" else cfg.fontPattern
  let monoPat := if cfg.headlessGolden.isSome then "DejaVu Sans Mono"
    else "Lilex Nerd Font,Lilex,IBM Plex Mono,DejaVu Sans Mono,monospace"
  let font ← Text.openFont 1 primaryPat
  let mono ← Text.openFont 2 monoPat
  let bold ← Text.openFont 3 s!"{primaryPat}:weight=bold"
  let medium ← Text.openFont 4 s!"{primaryPat}:weight=medium"
  let semibold ← Text.openFont 5 s!"{primaryPat}:weight=demibold"
  let focus0 : FocusState := { owner := some 1, traps := [] }
  let initDmg : Damage := some { x := 0, y := 0, w := (bw : Int), h := (bh : Int) }
  return {
    app := initialApp
    wayland := wl
    vulkan := vk
    atlas := { pageWidth := 1024, pageHeight := 1024, pad := 1 }
    primaryFont := font
    monoFont := mono
    boldFont := bold
    mediumFont := medium
    semiboldFont := semibold
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

private def callArgs (a b c : UInt64) :=
  [a,b,c,0,0,0].foldl Wayland.pushU64LE ByteArray.empty

/-- A notification remains readable if the reader publishes before the window enters poll.
The caller joins its reader inside this scope, before the descriptor can be reused. -/
def withProducerWake {α : Type} (k : UInt32 → IO Unit → IO α) : IO α := do
  let create ← FFI.dlSym "" "eventfd"
  let signal ← FFI.dlSym "" "eventfd_write"
  let closeFd ← FFI.dlSym "" "close"
  if create == 0 || signal == 0 || closeFd == 0 then throw (IO.userError "window eventfd unavailable")
  -- Linux EFD_CLOEXEC | EFD_NONBLOCK, so children cannot inherit the descriptor.
  let fd := (← FFI.call create (callArgs 0 0x80800 0)).toUInt32
  if fd == 0xffffffff then throw (IO.userError "window eventfd allocation failed")
  try k fd (discard <| FFI.call signal (callArgs fd.toUInt64 1 0))
  finally discard <| FFI.call closeFd (callArgs fd.toUInt64 0 0)

/-- On Linux, poll the compositor fd with a timeout only when the app has a
background producer. Wayland input wakes immediately; the timeout samples the
mailbox without a frame-rate idle timer. `pumpEvents` owns actual dispatch. -/
private def withWindowWait {α σ : Type} (rt : RuntimeState σ) (wakeFd : Option UInt32) (k : (UInt64 → IO Unit) → IO α) : IO α := do
  if rt.wayland.display == 0 then return ← k (fun _ => IO.sleep 500)
  let getFd ← FFI.dlSym "libwayland-client.so.0" "wl_display_get_fd"
  let pollFn ← FFI.dlSym "" "poll"
  let flush ← FFI.dlSym "libwayland-client.so.0" "wl_display_flush"
  if getFd == 0 || pollFn == 0 || flush == 0 then throw (IO.userError "window poll unavailable")
  let fd ← FFI.call getFd (callArgs rt.wayland.display.toUInt64 0 0)
  let drain ← FFI.dlSym "" "eventfd_read"
  if wakeFd.isSome && drain == 0 then throw (IO.userError "window eventfd read unavailable")
  let p ← FFI.memAlloc 24
  if p == 0 then throw (IO.userError "window poll allocation failed")
  try
    -- Linux struct pollfd { int fd; short events; short revents; }, POLLIN=1.
    let wait := fun count timeout => do
      -- Dispatch can queue seat and IME requests after the event pump flushed.
      -- Wake on writability as well if the outgoing socket was full.
      let result ← FFI.call flush (callArgs rt.wayland.display.toUInt64 0 0)
      let events := if result.toUInt32 == 0xffffffff then 5 else 1
      FFI.memWrite p (Wayland.pushU32LE (Wayland.pushU32LE ByteArray.empty fd.toUInt32) events)
      discard <| FFI.call pollFn (callArgs p.toUInt64 count timeout)
    match wakeFd with
    | none => k (fun ms => wait 1 (min 500 ms))
    | some wake =>
      FFI.memWrite (p + 8) (Wayland.pushU32LE (Wayland.pushU32LE ByteArray.empty wake) 1)
      k (fun ms => do
        wait 2 ms
        -- Nonblocking read coalesces notices. A compositor-only wake returns EAGAIN.
        discard <| FFI.call drain (callArgs wake.toUInt64 (p + 16).toUInt64 0))
  finally FFI.memFree p

/-- Run the window until it is closed: render and present when there is damage, otherwise
block on the compositor. Nothing is drawn before the first `xdg_surface.configure`. -/
def runWindow {σ : Type} (rt0 : RuntimeState σ)
    (onEvent : RuntimeState σ → σ → Event → σ × Damage)
    (view : RuntimeState σ → IO (FrameView × List ScrollRegion))
    (pollFrame : RuntimeState σ → IO (σ × Damage) := fun rt => pure (rt.app, none))
    (hasProducer : σ → Bool := fun _ => false)
    (focusChange : σ → σ → Event → Option Nat := fun _ _ _ => none)
    (wakeFd : Option UInt32 := none) (workPending : σ → Bool := fun _ => false)
    (animationVisible : RuntimeState σ → Bool := fun _ => false)
    (focusTraps : σ → List (List EntityId) := fun _ => []) : IO (RuntimeState σ) := withWindowWait rt0 wakeFd fun timedWait => do
  let mut rt := rt0
  while rt.running do
    if !rt.wayland.configured then
      Wayland.waitEvents rt.wayland
      let (wl, evs) ← Wayland.pumpEvents rt.wayland
      rt := { rt with wayland := wl }
      for ev in evs do
        rt := rt.stepEvent (onEvent rt) ev
    else
      let before := rt.app
      let (app, damage) ← pollFrame rt
      rt := ({ rt with app }).applyFocusTraps (focusTraps app)
      if let some rect := damage then rt := rt.markDirty rect
      if let some target := focusChange before app (.time 0) then
        rt := rt.requestFocus target rt.viewportDeviceRect
      let rendered := rt.framesRendered
      rt ← stepFrameWithRegions rt onEvent view focusChange focusTraps
      let shape : UInt32 :=
        if rt.activeScrollbarDrag.isSome then 1
        else match rt.hoveredEntity with
          | some id =>
            if isTextInputEntity id && rt.focusableOrder.contains id then 9  -- text cursor in editable fields
            else if rt.focusableOrder.contains id then 4 else 1
          | none => 1
      let wl ← Wayland.syncCursor rt.wayland shape
      let textOwner : Option EntityId :=
        if rt.windowFocused then
          rt.focus.owner.filter (fun id => isTextInputEntity id && rt.focusableOrder.contains id)
        else none
      let wl ← if textOwner.isSome && rt.lastImeOwner.isSome && textOwner != rt.lastImeOwner then
          Wayland.syncTextFocus wl false
        else pure wl
      let wl ← Wayland.syncTextFocus wl textOwner.isSome
      rt := { rt with wayland := wl, lastImeOwner := textOwner }
      if rt.framesRendered != rendered && rt.vulkan.backend == .cpuShm then
        let wl ← Wayland.present rt.wayland rt.vulkan.framebuffer
        rt := { rt with wayland := wl, presentCount := rt.presentCount + 1 }
      else if rt.running then
        -- Anti-busy-spin rule: when redraw is deferred awaiting `wl_callback.done`, block on
        -- Wayland fd + `wakeFd` even when `workPending rt.app == true`!
        let deferredByFrameCb := rt.wayland.frameCallbackPending && !rt.wayland.configurePendingCommit
        if deferredByFrameCb then
          if animationVisible rt then timedWait (100 - (← IO.monoMsNow) % 100).toUInt64
          else timedWait 0xffffffff
        else if !workPending rt.app then
          if animationVisible rt then timedWait (100 - (← IO.monoMsNow) % 100).toUInt64
          else if hasProducer rt.app then timedWait 0xffffffff else Wayland.waitEvents rt.wayland
  return rt

/-- Cleanly release font and Vulkan scratch resources owned by `RuntimeState`. -/
def shutdownRuntime {σ : Type} (rt : RuntimeState σ) : IO Unit := do
  if rt.wayland.xkbState != 0 then
    FFI.xkbFree rt.wayland.xkbState
  for face in rt.atlas.fallbackFonts do Text.closeFont face
  Text.closeFont rt.primaryFont
  Text.closeFont rt.monoFont
  Text.closeFont rt.boldFont
  Text.closeFont rt.mediumFont
  Text.closeFont rt.semiboldFont
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
