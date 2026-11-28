import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.FFI
import LeanUI.Text
import LeanUI.Swapchain
import LeanUI.VulkanStructs
import LeanUI.VulkanDevice
import LeanUI.VulkanSwapchain
import LeanUI.VulkanPipeline
/-!
# LeanUI.Vulkan — Vulkan 1.3 dynamic loader bridge, swapchain, instanced GPU SDF/glyph renderer & PNG encoder

Wraps `LeanUI.FFI` (`c/lean_ui_vulkan.c` + `c/lean_ui_vk_bridge.c`), `LeanUI.Vk` (`VulkanDevice`,
`VulkanSwapchain`, `VulkanPipeline`), and the deterministic CPU reference rasterizer for
`--headless-golden*`, `--gtk-sidebar-host`, and graceful `wl_shm` fallback.
-/
namespace LeanUI.Vulkan

@[inline] private def pushU16LE (b : ByteArray) (v : UInt16) : ByteArray :=
  b.push v.toUInt8
   |>.push (v >>> 8).toUInt8

@[inline] private def pushU32LE (b : ByteArray) (v : UInt32) : ByteArray :=
  b.push v.toUInt8
   |>.push (v >>> 8).toUInt8
   |>.push (v >>> 16).toUInt8
   |>.push (v >>> 24).toUInt8

@[inline] private def pushU64LE (b : ByteArray) (v : UInt64) : ByteArray :=
  let lo : UInt32 := (v &&& 0xFFFFFFFF).toUInt32
  let hi : UInt32 := (v >>> 32).toUInt32
  pushU32LE (pushU32LE b lo) hi

@[inline] private def pushU32BE (b : ByteArray) (v : UInt32) : ByteArray :=
  b.push (v >>> 24).toUInt8
   |>.push (v >>> 16).toUInt8
   |>.push (v >>> 8).toUInt8
   |>.push v.toUInt8

/-- Invoke a 6-argument C function pointer via `FFI.call` (`48` bytes of `UInt64`). -/
def call6 (fn : USize) (a0 a1 a2 a3 a4 a5 : UInt64 := 0) : IO UInt64 := do
  if fn == 0 then return 0
  let mut args := ByteArray.emptyWithCapacity 48
  args := pushU64LE args a0
  args := pushU64LE args a1
  args := pushU64LE args a2
  args := pushU64LE args a3
  args := pushU64LE args a4
  args := pushU64LE args a5
  FFI.call fn args

private structure PaintSnapshot where
  scene : Scene
  pages : Array Text.AtlasPageBuffer
  clear : Color
  width : Nat
  height : Nat

/-- Active presentation / rendering backend owned by `VulkanContext`. -/
inductive RenderBackend where
  | cpuShm
  | vkPresent
  | vkInstanced
  deriving DecidableEq, Repr, Inhabited

/-- Requested GPU backend mode from CLI flags and `ORB_LEANUI_GPU`. -/
inductive GpuModeRequest where
  | auto
  | disabled
  | present
  | instanced
  | lavapipe
  deriving DecidableEq, Repr, Inhabited

/-- Live Vulkan WSI swapchain and optional Phase 2 instanced GPU pipeline. -/
structure VulkanGpuSession where
  wsi : Vk.VkWsiState
  pipe : Option Vk.VkInstancedPipeline := none

/-- Dynamic Vulkan 1.3 loader, GPU swapchain/pipeline session, and CPU reference context. -/
structure VulkanContext where
  vkGetInstanceProcAddr : USize := 0
  vkCreateInstance : USize := 0
  vkEnumeratePhysicalDevices : USize := 0
  scratchPtr : USize := 0
  scratchCap : USize := 0
  width : Nat := 1280
  height : Nat := 800
  framebuffer : ByteArray := ByteArray.empty
  previousPaint : Option PaintSnapshot := none
  /-- Authoritative dirty region modified by `renderFrame` / `renderFrameDamage`. -/
  lastUploadedDirtyRect : Option Rect := none
  /-- Active backend (`cpuShm`, Phase 1 `vkPresent`, or Phase 2 `vkInstanced`). -/
  backend : RenderBackend := .cpuShm
  icdName : String := ""
  presentMode : UInt32 := 0
  fallbackReason : Option String := none
  swapchainRecreates : Nat := 0
  gpuAllocatedBytes : Nat := 0
  lastAcquireNs : UInt64 := 0
  lastUploadNs : UInt64 := 0
  lastSubmitNs : UInt64 := 0
  lastPresentNs : UInt64 := 0
  lastUploadBytes : Nat := 0
  lastAtlasUploadBytes : Nat := 0
  lastSsboBytes : Nat := 0
  gpuSession : Option VulkanGpuSession := none
  /-- Number of visual primitives submitted by the last frame. -/
  lastDrawnPrims : Nat := 0
  /-- Number of device pixels cleared by the last frame's damage pass. -/
  lastDamagePixels : Nat := 0
  /-- Number of frames that reused the framebuffer outside a dirty rectangle. -/
  partialFrames : Nat := 0
  deriving Inhabited

/-- Initialize the deterministic CPU reference context (headless / `--headless-golden*` /
`--bench` / `--gtk-sidebar-host` / fallback safe). Avoids eagerly `dlopen`-ing `libvulkan.so.1`
or allocating native scratch buffers so headless/bench startup stays fast and memory-bounded. -/
def initVulkan (width height : Nat) : IO VulkanContext :=
  return {
    width
    height
    backend := .cpuShm
  }

/-- Resolve effective `GpuModeRequest` combining CLI flag and `ORB_LEANUI_GPU` environment variable. -/
def resolveGpuMode (cliMode : GpuModeRequest) : IO GpuModeRequest := do
  match cliMode with
  | .disabled => return .disabled
  | .present | .instanced | .lavapipe => return cliMode
  | .auto =>
    match (← IO.getEnv "ORB_LEANUI_GPU") with
    | some "0" | some "false" | some "off" => return .disabled
    | some "present" => return .present
    | some "lavapipe" | some "force" => return .lavapipe
    | some "1" | some "instanced" | some "true" => return .instanced
    | _ => return .auto

/-- Initialize Vulkan 1.3 WSI swapchain (and Phase 2 instanced pipeline when requested/supported)
on `(wlDisplay, wlSurface)`. Gracefully falls back to `cpuShm` with `fallbackReason` set on any
missing library, unsupported WSI (e.g. compositor lacking `zwp_linux_dmabuf_v1`), software-only
ICD (unless `lavapipe`), or `--no-gpu`. -/
def initVulkanSurface (width height : Nat) (wlDisplay wlSurface : USize)
    (cliMode : GpuModeRequest := .auto) (wlHasDmabuf : Bool := true) : IO VulkanContext := do
  let base ← initVulkan width height
  let mode ← resolveGpuMode cliMode
  if mode == .disabled then
    return { base with backend := .cpuShm, fallbackReason := some "GPU disabled via --no-gpu / ORB_LEANUI_GPU=0" }
  if wlDisplay == 0 || wlSurface == 0 then
    return { base with backend := .cpuShm, fallbackReason := some "headless session (no Wayland surface)" }
  let allowSoftware := mode == .lavapipe
  if !allowSoftware && !wlHasDmabuf then
    return { base with backend := .cpuShm, fallbackReason := some "Wayland compositor lacks zwp_linux_dmabuf_v1; falling back to wl_shm" }
  let enableVal := (← IO.getEnv "ORB_LEANUI_VK_VALIDATION") == some "1"
  let wantInstanced := mode != .present
  match ← Vk.createWsi wlDisplay wlSurface width height allowSoftware enableVal with
  | .error reason =>
    return { base with backend := .cpuShm, fallbackReason := some reason }
  | .ok wsi =>
    let allocBytes ← wsi.dev.allocatedBytes.get
    let pMode := wsi.bundle.map (·.presentMode) |>.getD 0
    let canDirectInstanced := wsi.bundle.map (fun b => b.canTransferSrc && b.canBlitSrc && b.canBlitDst) |>.getD false
    if wantInstanced && canDirectInstanced then
      let fmt := wsi.bundle.map (·.format) |>.getD Vk.VK_FORMAT_B8G8R8A8_UNORM
      match ← Vk.createInstancedPipeline wsi.dev fmt with
      | .ok pipe =>
        let allocBytes2 ← wsi.dev.allocatedBytes.get
        return { base with
          vkGetInstanceProcAddr := wsi.dev.fns.getInstanceProcAddr
          vkCreateInstance := wsi.dev.fns.createInstance
          vkEnumeratePhysicalDevices := wsi.dev.fns.enumeratePhysicalDevices
          backend := .vkInstanced
          icdName := wsi.dev.deviceName
          presentMode := pMode
          fallbackReason := none
          gpuAllocatedBytes := allocBytes2
          gpuSession := some { wsi, pipe := some pipe } }
      | .error reason =>
        -- Graceful degrade from Phase 2 -> Phase 1 (`vkPresent`)
        return { base with
          vkGetInstanceProcAddr := wsi.dev.fns.getInstanceProcAddr
          vkCreateInstance := wsi.dev.fns.createInstance
          vkEnumeratePhysicalDevices := wsi.dev.fns.enumeratePhysicalDevices
          backend := .vkPresent
          icdName := wsi.dev.deviceName
          presentMode := pMode
          fallbackReason := some s!"vkInstanced unavailable ({reason}); using vkPresent"
          gpuAllocatedBytes := allocBytes
          gpuSession := some { wsi, pipe := none } }
    else
      return { base with
        vkGetInstanceProcAddr := wsi.dev.fns.getInstanceProcAddr
        vkCreateInstance := wsi.dev.fns.createInstance
        vkEnumeratePhysicalDevices := wsi.dev.fns.enumeratePhysicalDevices
        backend := .vkPresent
        icdName := wsi.dev.deviceName
        presentMode := pMode
        fallbackReason := none
        gpuAllocatedBytes := allocBytes
        gpuSession := some { wsi, pipe := none } }

/-- Free GPU swapchain/pipeline handles in strict reverse lifecycle order (`vkDeviceWaitIdle`
first) and native scratch memory (`FFI.memFree`) owned by `VulkanContext`. -/
def shutdownVulkan (ctx : VulkanContext) : IO Unit := do
  if let some sess := ctx.gpuSession then
    if let some pipe := sess.pipe then
      Vk.destroyInstancedPipeline sess.wsi.dev pipe
    let _ ← Vk.destroyWsi sess.wsi
  if ctx.scratchPtr != 0 then
    FFI.memFree ctx.scratchPtr

/-- Per-corner radii `(tl, tr, br, bl)` in device pixels. -/
abbrev CornerRadii := Nat × Nat × Nat × Nat

/-- Packed 80-byte GPU instance record matching `struct PrimInstance` in `shaders/scene_sdf.glsl`. -/
structure GpuPrimInstance where
  dst : Rect
  uv : Rect
  clip : Rect
  radii : CornerRadii
  colorRGBA : Color
  kind : UInt32
  aux0 : UInt32
  aux1 : UInt32
  deriving DecidableEq, Repr, Inhabited

/-- Serialize an array of `GpuPrimInstance` into a tightly packed binary SSBO buffer (`80` bytes
per instance) and stage the prefix into `ctx.scratchPtr` via `FFI.memWrite`. -/
def stageInstances (ctx : VulkanContext) (insts : Array GpuPrimInstance) : IO ByteArray := do
  let mut buf := ByteArray.emptyWithCapacity (insts.size * 80)
  for inst in insts do
    let (tl, tr, br, bl) := inst.radii
    buf := pushU32LE buf inst.dst.x.toInt32.toUInt32
    buf := pushU32LE buf inst.dst.y.toInt32.toUInt32
    buf := pushU32LE buf inst.dst.w.toInt32.toUInt32
    buf := pushU32LE buf inst.dst.h.toInt32.toUInt32
    buf := pushU32LE buf inst.uv.x.toInt32.toUInt32
    buf := pushU32LE buf inst.uv.y.toInt32.toUInt32
    buf := pushU32LE buf inst.uv.w.toInt32.toUInt32
    buf := pushU32LE buf inst.uv.h.toInt32.toUInt32
    buf := pushU32LE buf inst.clip.x.toInt32.toUInt32
    buf := pushU32LE buf inst.clip.y.toInt32.toUInt32
    buf := pushU32LE buf inst.clip.w.toInt32.toUInt32
    buf := pushU32LE buf inst.clip.h.toInt32.toUInt32
    buf := pushU32LE buf tl.toUInt32
    buf := pushU32LE buf tr.toUInt32
    buf := pushU32LE buf br.toUInt32
    buf := pushU32LE buf bl.toUInt32
    buf := pushU32LE buf inst.colorRGBA
    buf := pushU32LE buf inst.kind
    buf := pushU32LE buf inst.aux0
    buf := pushU32LE buf inst.aux1
  if ctx.scratchPtr != 0 && buf.size > 0 && buf.size.toUSize ≤ ctx.scratchCap then
    FFI.memWrite ctx.scratchPtr buf
  return buf

/-- Intersection of two axis-aligned `Rect` values. -/
@[inline] def intersectRect (a b : Rect) : Rect :=
  let x0 := max a.x b.x
  let y0 := min (max a.y b.y) (max a.bottom b.bottom)
  let x1 := max x0 (min a.right b.right)
  let y1 := max y0 (min a.bottom b.bottom)
  { x := x0, y := y0, w := x1 - x0, h := y1 - y0 }

/-- Integer square root helper for analytical SDF corner distance evaluation. -/
@[inline] private def isqrt (n : Nat) : Nat := Id.run do
  if n == 0 then return 0
  let mut x := n
  let mut y := (x + 1) / 2
  for _ in [0:32] do
    if y ≥ x then break
    x := y
    y := (x + n / x) / 2
  return x

/-- Signed distance in fixed-point (`1/16` px) from pixel center `(px, py)` to a rounded rectangle
`r` with per-corner radii `radii = (tl, tr, br, bl)`. Negative inside, positive outside. -/
def sdfRoundedRect16 (r : Rect) (radii : CornerRadii) (px py : Int) : Int :=
  let (tl, tr, br, bl) := radii
  let rw : Nat := r.w.toNat
  let rh : Nat := r.h.toNat
  let hx16 : Int := (rw : Int) * 8
  let hy16 : Int := (rh : Int) * 8
  let cx16 : Int := r.x * 16 + hx16
  let cy16 : Int := r.y * 16 + hy16
  let px16 : Int := px * 16 + 8
  let py16 : Int := py * 16 + 8
  let dx16 : Int := px16 - cx16
  let dy16 : Int := py16 - cy16
  let rawRad : Nat :=
    if dx16 < 0 then
      if dy16 < 0 then tl else bl
    else
      if dy16 < 0 then tr else br
  let maxR : Nat := min (rw / 2) (rh / 2)
  let rad : Nat := min rawRad maxR
  let rad16 : Int := (rad : Int) * 16
  let qx16 : Int := (dx16.natAbs : Int) - hx16 + rad16
  let qy16 : Int := (dy16.natAbs : Int) - hy16 + rad16
  let mx16 : Nat := if qx16 > 0 then qx16.toNat else 0
  let my16 : Nat := if qy16 > 0 then qy16.toNat else 0
  let isCircleCap : Bool := rad ≤ 1 || rawRad > maxR || (rw == rh && rawRad ≥ maxR)
  let outLen16 : Int :=
    if max mx16 my16 ≥ rad * 16 + 16 then
      (max mx16 my16 : Int)
    else if isCircleCap then
      (isqrt (mx16 * mx16 + my16 * my16) : Int)
    else
      let sx := mx16 * mx16
      let sy := my16 * my16
      (isqrt (isqrt (sx * sx + sy * sy)) : Int)
  let inMax16 : Int := min (max qx16 qy16) 0
  inMax16 + outLen16 - rad16

/-- Alpha-over blend of `src = (sr, sg, sb, sa)` onto `(dr, dg, db, da)` in `[0..255]`,
matching Skia 8-bit premultiplied compositing. -/
@[inline] private def blendOver (dr dg db da sr sg sb sa : UInt8) : UInt8 × UInt8 × UInt8 × UInt8 :=
  if sa == 0 then (dr, dg, db, da)
  else if sa == 255 then (sr, sg, sb, 255)
  else
    let a := sa.toNat
    let inv := 255 - a
    let r := (sr.toNat * a + dr.toNat * inv + 127) / 255
    let g := (sg.toNat * a + dg.toNat * inv + 127) / 255
    let b := (sb.toNat * a + db.toNat * inv + 127) / 255
    let outA := min 255 (a + (da.toNat * inv + 127) / 255)
    (r.toUInt8, g.toUInt8, b.toUInt8, outA.toUInt8)

@[inline] private def unpackColor (c : Color) : UInt8 × UInt8 × UInt8 × UInt8 :=
  (((c >>> 24) &&& 0xFF).toUInt8,
   ((c >>> 16) &&& 0xFF).toUInt8,
   ((c >>> 8) &&& 0xFF).toUInt8,
   (c &&& 0xFF).toUInt8)

/-- Clamp a rectangle to viewport bounds `(0, 0, vw, vh)` intersect `clip`. -/
@[inline] private def clampBounds (vw vh : Nat) (clip dst : Rect) : Int × Int × Int × Int :=
  let vp : Rect := { x := 0, y := 0, w := (vw : Int), h := (vh : Int) }
  let b := intersectRect (intersectRect vp clip) dst
  (b.x, b.y, b.right, b.bottom)

/-- Premultiplied source-over blend of already-premultiplied `(sr, sg, sb, sa)` modulated by
`modA` onto premultiplied `(dr, dg, db, da)`. Avoids double-premultiplication on offscreen layers
and FreeType `FT_PIXEL_MODE_BGRA` color glyphs. -/
@[inline] private def blendOverPremul (dr dg db da sr sg sb sa modA : UInt8) :
    UInt8 × UInt8 × UInt8 × UInt8 :=
  let effA := (sa.toNat * modA.toNat + 127) / 255
  if effA == 0 then (dr, dg, db, da)
  else
    let inv := 255 - effA
    let r := min 255 ((sr.toNat * modA.toNat + 127) / 255 + (dr.toNat * inv + 127) / 255)
    let g := min 255 ((sg.toNat * modA.toNat + 127) / 255 + (dg.toNat * inv + 127) / 255)
    let b := min 255 ((sb.toNat * modA.toNat + 127) / 255 + (db.toNat * inv + 127) / 255)
    let outA := min 255 (effA + (da.toNat * inv + 127) / 255)
    (r.toUInt8, g.toUInt8, b.toUInt8, outA.toUInt8)

/-- Compute combined rounded-clip coverage `[0..255]` for pixel `(px, py)` across active rounded clips. -/
@[inline] private def roundedClipCov (rclips : List (Rect × CornerRadii)) (px py : Int) : Nat :=
  rclips.foldl (fun cov (cr, radii) =>
    if cov == 0 then 0
    else
      let d16 := sdfRoundedRect16 cr radii px py
      if d16 ≥ 8 then 0
      else if d16 ≤ -8 then cov
      else (cov * (((8 - d16).toNat * 255) / 16) + 127) / 255) 255

/-- `true` when every clip in `rclips` covers `(px, py)` fully: inside its rectangle and one pixel
    clear of its corner squares, where `sdfRoundedRect16 ≤ -8` and `roundedClipCov` keeps `255`. -/
@[inline] private def roundedClipFull (rclips : List (Rect × CornerRadii)) (px py : Int) : Bool :=
  rclips.all fun (r, (tl, tr, br, bl)) =>
    let m : Int := Int.ofNat (max (max tl tr) (max br bl)) + 1
    px ≥ r.x && px < r.right && py ≥ r.y && py < r.bottom &&
      ((px ≥ r.x + m && px < r.right - m) || (py ≥ r.y + m && py < r.bottom - m))

/-- Apply rounded clip masks to newly painted pixels inside `region` by blending `painted` over `saved`. -/
private def applyRoundedClips (vw vh : Nat) (saved painted : ByteArray) (region : Rect)
    (rclips : List (Rect × CornerRadii)) : ByteArray := Id.run do
  if rclips.isEmpty then return painted
  let vp : Rect := ⟨0, 0, vw, vh⟩
  let b := intersectRect vp region
  if b.isEmpty then return painted
  let mut out := painted
  for py in [b.y.toNat : b.bottom.toNat] do
    for px in [b.x.toNat : b.right.toNat] do
      let cov := roundedClipCov rclips (px : Int) (py : Int)
      if cov < 255 then
        let idx := (py * vw + px) * 4
        if cov == 0 then
          out := out.set! idx (saved.get! idx)
            |>.set! (idx + 1) (saved.get! (idx + 1))
            |>.set! (idx + 2) (saved.get! (idx + 2))
            |>.set! (idx + 3) (saved.get! (idx + 3))
        else
          let inv := 255 - cov
          let mixC (a b : UInt8) : UInt8 := ((a.toNat * cov + b.toNat * inv + 127) / 255).toUInt8
          out := out.set! idx (mixC (painted.get! idx) (saved.get! idx))
            |>.set! (idx + 1) (mixC (painted.get! (idx + 1)) (saved.get! (idx + 1)))
            |>.set! (idx + 2) (mixC (painted.get! (idx + 2)) (saved.get! (idx + 2)))
            |>.set! (idx + 3) (mixC (painted.get! (idx + 3)) (saved.get! (idx + 3)))
  return out

/-- Saved offscreen layer state for `Prim.layerPush` / `Prim.layerPop`. The rounded clips active
at the push are set aside while the layer is painted and applied once, when it is composited.
The clip stack is saved with them, so clip commands inside a layer cannot outlive or escape it. -/
private structure LayerFrame where
  opacity : Nat
  clip : Rect
  savedBuf : ByteArray
  clipStack : List Rect
  rclipStack : List (Option (Rect × CornerRadii))
  activeRClips : List (Rect × CornerRadii)

/-- Helper to rasterize a rounded rect fill + optional inner border onto `fb`. -/
private def drawRoundedBox (vw vh : Nat) (fb : ByteArray) (curClip r : Rect)
    (radii : CornerRadii) (fill : Color) (borders : Nat × Nat × Nat × Nat) (borderCol : Color) :
    ByteArray := Id.run do
  let mut out := fb
  let (x0, y0, x1, y1) := clampBounds vw vh curClip r
  if x1 ≤ x0 || y1 ≤ y0 then return out
  let (fr, fg, fbC, fa) := unpackColor fill
  let (br, bg, bb, ba) := unpackColor borderCol
  let (bt, brW, bbW, blW) := borders
  let hasBorder := (bt > 0 || brW > 0 || bbW > 0 || blW > 0) && ba > 0
  if fa == 0 && !hasBorder then return out
  if fa == 255 && !hasBorder && radii == (0, 0, 0, 0) then
    -- Pixel-aligned opaque rectangles have constant coverage: build one
    -- scanline, then copy it into the clipped span of each affected row.
    let w := (x1 - x0).toNat
    let mut row := ByteArray.emptyWithCapacity (w * 4)
    for _ in [:w] do row := row.push fr |>.push fg |>.push fbC |>.push fa
    for y in [y0.toNat:y1.toNat] do
      out := row.copySlice 0 out ((y * vw + x0.toNat) * 4) row.size
    return out
  -- Blend `c` over the part of `[ax0, ax1) × [ay0, ay1)` inside the clamped bounds. `blendRect`
  -- uses the same arithmetic as `blendOver`, so full-coverage spans match the per-pixel path.
  let blendSpan (o : ByteArray) (ax0 ay0 ax1 ay1 : Int) (c : Color) : ByteArray :=
    let bx0 := max x0 ax0
    let by0 := max y0 ay0
    let bx1 := min x1 ax1
    let by1 := min y1 ay1
    if bx1 ≤ bx0 || by1 ≤ by0 then o
    else FFI.blendRect o (by0.toNat * vw + bx0.toNat).toUSize vw.toUSize
      (bx1 - bx0).toNat.toUSize (by1 - by0).toNat.toUSize c
  if radii == (0, 0, 0, 0) then
    -- Square corners: every pixel has full coverage, so the fill and the border bands (the
    -- pixels outside the inner rectangle) are solid spans, painted fill first as below.
    if fa > 0 then out := blendSpan out x0 y0 x1 y1 fill
    if hasBorder then
      let iy0 := min r.bottom (r.y + (bt : Int))
      let iy1 := max iy0 (r.bottom - (bbW : Int))
      let ix0 := min r.right (r.x + (blW : Int))
      let ix1 := max ix0 (r.right - (brW : Int))
      out := blendSpan out r.x r.y r.right iy0 borderCol
      out := blendSpan out r.x iy1 r.right r.bottom borderCol
      out := blendSpan out r.x iy0 ix0 iy1 borderCol
      out := blendSpan out ix1 iy0 r.right iy1 borderCol
    return out
  let innerRect : Rect :=
    { x := r.x + (blW : Int)
      y := r.y + (bt : Int)
      w := max 0 (r.w - (blW : Int) - (brW : Int))
      h := max 0 (r.h - (bt : Int) - (bbW : Int)) }
  let (tl, tr, brR, blR) := radii
  let innerRadii : CornerRadii :=
    (tl - min tl (max bt blW),
     tr - min tr (max bt brW),
     brR - min brR (max bbW brW),
     blR - min blR (max bbW blW))
  -- Inside either straight strip the pixel has full coverage. Only corner
  -- pixels need a signed distance, including for the inner border edge.
  let margin : Int := max (max tl tr) (max brR blR)
  let spanL := min x1 (max x0 (max (r.x + margin) (if hasBorder then innerRect.x + margin else x0)))
  let spanR := max spanL (min x1 (min (r.right - margin) (if hasBorder then innerRect.right - margin else x1)))
  let top := if hasBorder then max y0 innerRect.y else y0
  let bottom := if hasBorder then min y1 innerRect.bottom else y1
  let bulk := spanR - spanL ≥ 16 && top < bottom
  -- Without a border, rows clear of the corner radius have full coverage across the whole width.
  let sTop := if hasBorder then y0 else min y1 (max y0 (r.y + margin))
  let sBot := if hasBorder then y0 else max sTop (min y1 (r.bottom - margin))
  if sBot > sTop then out := blendSpan out x0 sTop x1 sBot fill
  if bulk then
    if sBot > sTop then
      out := blendSpan out spanL top spanR sTop fill
      out := blendSpan out spanL sBot spanR bottom fill
    else
      out := FFI.blendRect out (top.toNat * vw + spanL.toNat).toUSize vw.toUSize
        (spanR-spanL).toNat.toUSize (bottom-top).toNat.toUSize fill
  for py in [y0.toNat : y1.toNat] do
    if (py : Int) ≥ sTop && (py : Int) < sBot then continue
    let y : Int := py
    let straightRow := y ≥ r.y + margin && y < r.bottom - margin
    let innerRow := y ≥ innerRect.y && y < innerRect.bottom
    let straightInnerRow := y ≥ innerRect.y + margin && y < innerRect.bottom - margin
    let useStrip := bulk && (!hasBorder || innerRow)
    let skip := if useStrip then (spanR-spanL).toNat else 0
    for edgeX in [x0.toNat : x1.toNat - skip] do
      let px := if useStrip && edgeX ≥ spanL.toNat then edgeX + skip else edgeX
      let x : Int := px
      let dOut16 := if straightRow || (x ≥ r.x + margin && x < r.right - margin) then -8
        else sdfRoundedRect16 r radii x y
      if dOut16 < 8 then
        let covOut : Nat := if dOut16 ≤ -8 then 255 else ((8 - dOut16).toNat * 255) / 16
        let idx := (py * vw + px) * 4
        if fa > 0 then
          let effA : UInt8 := ((fa.toNat * covOut + 127) / 255).toUInt8
          let (nr, ng, nb, na) := if effA == 255 then (fr, fg, fbC, effA) else
            blendOver (out.get! idx) (out.get! (idx + 1)) (out.get! (idx + 2)) (out.get! (idx + 3)) fr fg fbC effA
          out := out.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
        if hasBorder && !(innerRow && x ≥ innerRect.x && x < innerRect.right &&
            (straightInnerRow || (x ≥ innerRect.x + margin && x < innerRect.right - margin))) then
          let dIn16 := sdfRoundedRect16 innerRect innerRadii (px : Int) (py : Int)
          if dIn16 > -8 then
            let covIn : Nat := if dIn16 ≥ 8 then 255 else ((dIn16 + 8).toNat * 255) / 16
            let covB := (covOut * covIn + 127) / 255
            let effB : UInt8 := ((ba.toNat * covB + 127) / 255).toUInt8
            let (nr, ng, nb, na) :=
              blendOver (out.get! idx) (out.get! (idx + 1)) (out.get! (idx + 2)) (out.get! (idx + 3))
                br bg bb effB
            out := out.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
  return out

/-- Sliding-window box blur with edge replication, O(width * height), independent of radius.
The framebuffer is opaque; each pass preserves alpha and constant-color surfaces. -/
def blurAxis (fb : ByteArray) (vw vh radius : Nat) (horizontal : Bool) : ByteArray := Id.run do
  if vw == 0 || vh == 0 || radius == 0 then return fb
  let mut out := Text.AtlasPageBuffer.zeroBytes fb.size
  let len := if horizontal then vw else vh
  let count := if horizontal then vh else vw
  let index (line pos channel : Nat) :=
    ((if horizontal then line * vw + pos else pos * vw + line) * 4) + channel
  let width := radius * 2 + 1
  for line in [0:count] do
    for channel in [0:4] do
      let mut sum : Nat := 0
      for k in [0:width] do
        let pos := min (len - 1) (k - radius)
        sum := sum + (fb.get! (index line pos channel)).toNat
      for pos in [0:len] do
        out := out.set! (index line pos channel) ((sum + width / 2) / width).toUInt8
        let oldPos := pos - radius
        let newPos := min (len - 1) (pos + radius + 1)
        sum := sum - (fb.get! (index line oldPos channel)).toNat +
          (fb.get! (index line newPos channel)).toNat
  return out

/-- Three separable box passes approximate a Gaussian of standard deviation `sigma`.
Keep this explicit: native blur is deterministic, but is not Skia's filter pipeline. -/
def blurBackdrop (fb : ByteArray) (vw vh sigma : Nat) : ByteArray := Id.run do
  if sigma == 0 then return fb
  let mut out := fb
  for radius in [sigma - 1, sigma - 1, sigma] do
    if radius == 0 then continue
    if radius ≤ 65535 && vw * vh * 4 == fb.size then
      out := FFI.boxAxis out vw.toUSize vh.toUSize radius.toUSize true
      out := FFI.boxAxis out vw.toUSize vh.toUSize radius.toUSize false
    else
      out := blurAxis out vw vh radius true
      out := blurAxis out vw vh radius false
  return out

/-- Render a scene into either a fresh framebuffer or an existing framebuffer. When `dirty` is
present, only pixels and visual primitives intersecting that rectangle are touched; structural clip
and layer commands remain so compositing order is unchanged. -/
def rasterizeSceneInto (vw vh : Nat) (clearColor : Color) (atlas : Text.GlyphAtlasCache)
    (initial : Option ByteArray) (dirty : Option Rect) (scene : Scene) : ByteArray × Array GpuPrimInstance := Id.run do
  let (cr, cg, cb, ca) := unpackColor clearColor
  let totalBytes := vw * vh * 4
  let fullClip : Rect := { x := 0, y := 0, w := (vw : Int), h := (vh : Int) }
  let renderClip := match dirty with
    | none => fullClip
    | some d => intersectRect fullClip d
  let mut fb := match initial with
    | some previous => if previous.size == totalBytes then previous else ByteArray.emptyWithCapacity totalBytes
    | none => ByteArray.emptyWithCapacity totalBytes
  if fb.size == 0 then
    let mut row := ByteArray.emptyWithCapacity (vw * 4)
    for _ in [:vw] do row := row.push cr |>.push cg |>.push cb |>.push ca
    for y in [:vh] do fb := row.copySlice 0 fb (y * row.size) row.size
  if let some d := dirty then
    let (x0, y0, x1, y1) := clampBounds vw vh fullClip d
    if x1 > x0 && y1 > y0 then
      let w := (x1-x0).toNat
      let mut row := ByteArray.emptyWithCapacity (4*w)
      for _ in [:w] do row := row.push cr |>.push cg |>.push cb |>.push ca
      for py in [y0.toNat : y1.toNat] do
        fb := row.copySlice 0 fb ((py * vw + x0.toNat) * 4) row.size
  let mut clipStack : List Rect := [renderClip]
  let mut rclipStack : List (Option (Rect × CornerRadii)) := [none]
  let mut activeRClips : List (Rect × CornerRadii) := []
  let mut layerStack : List LayerFrame := []
  let mut instances : Array GpuPrimInstance := #[]

  for prim in scene do
    let curClip := clipStack.head?.getD renderClip
    if !prim.intersects curClip then continue
    match prim with
    | .backdropBlur sigma =>
      fb := blurBackdrop fb vw vh sigma
    | .clipPush r =>
      clipStack := intersectRect curClip r :: clipStack
      rclipStack := none :: rclipStack
    | .clipPushRounded r radii =>
      clipStack := intersectRect curClip r :: clipStack
      rclipStack := some (r, radii) :: rclipStack
      activeRClips := (r, radii) :: activeRClips
    | .clipPop =>
      -- The base entry stays: an unmatched pop cannot widen the clip of the enclosing layer.
      if let _ :: tail := clipStack then
        if !tail.isEmpty then clipStack := tail
      if let top :: rtail := rclipStack then
        rclipStack := if rtail.isEmpty then [none] else rtail
        if top.isSome then
          if let _ :: atail := activeRClips then activeRClips := atail
    | .layerPush opacity =>
      let saved := fb
      fb := Text.AtlasPageBuffer.zeroBytes totalBytes
      layerStack := { opacity := min opacity 255, clip := curClip, savedBuf := saved,
                      clipStack, rclipStack, activeRClips } :: layerStack
      clipStack := [curClip]
      rclipStack := [none]
      activeRClips := []
    | .layerPop =>
      if let top :: rest := layerStack then
        layerStack := rest
        let layerBuf := fb
        fb := top.savedBuf
        clipStack := top.clipStack
        rclipStack := top.rclipStack
        activeRClips := top.activeRClips
        let (x0, y0, x1, y1) := clampBounds vw vh top.clip renderClip
        if x1 > x0 && y1 > y0 then
          let modA : UInt8 := top.opacity.toUInt8
          for py in [y0.toNat : y1.toNat] do
            for px in [x0.toNat : x1.toNat] do
              let idx := (py * vw + px) * 4
              let lr := layerBuf.get! idx
              let lg := layerBuf.get! (idx + 1)
              let lb := layerBuf.get! (idx + 2)
              let la := layerBuf.get! (idx + 3)
              if la > 0 && modA > 0 then
                let effModA : UInt8 :=
                  if activeRClips.isEmpty || roundedClipFull activeRClips (px : Int) (py : Int) then modA
                  else ((modA.toNat * roundedClipCov activeRClips (px : Int) (py : Int) + 127) / 255).toUInt8
                if effModA > 0 then
                  let dr := fb.get! idx
                  let dg := fb.get! (idx + 1)
                  let db := fb.get! (idx + 2)
                  let da := fb.get! (idx + 3)
                  let (nr, ng, nb, na) := blendOverPremul dr dg db da lr lg lb la effModA
                  fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
    | .quad r fill rad bw border =>
      let radii : CornerRadii := (rad, rad, rad, rad)
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := fill, kind := 0, aux0 := bw.toUInt32, aux1 := 255
      }
      if bw > 0 then
        instances := instances.push {
          dst := r, uv := { x := bw, y := bw, w := bw, h := bw }, clip := curClip,
          radii, colorRGBA := border, kind := 1, aux0 := bw.toUInt32, aux1 := 255
        }
      let saved := if activeRClips.isEmpty then ByteArray.empty else fb
      fb := drawRoundedBox vw vh fb curClip r radii fill (bw, bw, bw, bw) border
      if !activeRClips.isEmpty then fb := applyRoundedClips vw vh saved fb (intersectRect curClip r) activeRClips
    | .rrect r fill radii borders border =>
      let (bt, brW, bbW, blW) := borders
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := fill, kind := 0, aux0 := bt.toUInt32, aux1 := 255
      }
      if bt > 0 || brW > 0 || bbW > 0 || blW > 0 then
        instances := instances.push {
          dst := r, uv := { x := bt, y := brW, w := bbW, h := blW }, clip := curClip,
          radii, colorRGBA := border, kind := 1, aux0 := 0, aux1 := 255
        }
      let saved := if activeRClips.isEmpty then ByteArray.empty else fb
      fb := drawRoundedBox vw vh fb curClip r radii fill borders border
      if !activeRClips.isEmpty then fb := applyRoundedClips vw vh saved fb (intersectRect curClip r) activeRClips
    | .linear r c0 c1 angleDeg rad =>
      let radii : CornerRadii := (rad, rad, rad, rad)
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := c0, kind := 6, aux0 := c1,
        aux1 := (255 : UInt32) ||| ((angleDeg % 360).toUInt32 <<< 8)
      }
      let (r0, g0, b0, a0) := unpackColor c0
      let (r1, g1, b1, a1) := unpackColor c1
      let (x0, y0, x1, y1) := clampBounds vw vh curClip r
      if x1 > x0 && y1 > y0 then
        let radF : Float := ((angleDeg % 360).toFloat) * 3.141592653589793 / 180.0
        let dirX : Float := Float.sin radF
        let dirY : Float := -(Float.cos radF)
        let halfW : Float := 0.5 * r.w.toNat.toFloat
        let halfH : Float := 0.5 * r.h.toNat.toFloat
        let cxF : Float := r.x.toFloat + halfW
        let cyF : Float := r.y.toFloat + halfH
        let halfLen : Float := max (Float.abs dirX * halfW + Float.abs dirY * halfH) 1e-4
        let saved := if activeRClips.isEmpty then ByteArray.empty else fb
        for py in [y0.toNat : y1.toNat] do
          let pyF : Float := py.toFloat + 0.5 - cyF
          for px in [x0.toNat : x1.toNat] do
            let d16 := sdfRoundedRect16 r radii (px : Int) (py : Int)
            if d16 < 8 then
              let pxF : Float := px.toFloat + 0.5 - cxF
              let tRaw : Float := (pxF * dirX + pyF * dirY) / (2.0 * halfLen) + 0.5
              let tClamped : Float := if tRaw < 0.0 then 0.0 else if tRaw > 1.0 then 1.0 else tRaw
              let tN : Nat := (tClamped * 1024.0 + 0.5).toUInt32.toNat
              let tN := min 1024 tN
              let inv := 1024 - tN
              let mr := ((r0.toNat * inv + r1.toNat * tN + 512) / 1024).toUInt8
              let mg := ((g0.toNat * inv + g1.toNat * tN + 512) / 1024).toUInt8
              let mb := ((b0.toNat * inv + b1.toNat * tN + 512) / 1024).toUInt8
              let ma := ((a0.toNat * inv + a1.toNat * tN + 512) / 1024).toUInt8
              let cov : Nat := if d16 ≤ -8 then 255 else ((8 - d16).toNat * 255) / 16
              let effA := ((ma.toNat * cov + 127) / 255).toUInt8
              let idx := (py * vw + px) * 4
              let (nr, ng, nb, na) :=
                blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                  mr mg mb effA
              fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
        if !activeRClips.isEmpty then fb := applyRoundedClips vw vh saved fb (intersectRect curClip r) activeRClips
    | .shadow r col rad blur =>
      let radii : CornerRadii := (rad, rad, rad, rad)
      let pad : Int := (blur * 2 : Int)
      let expanded : Rect :=
        { x := r.x - pad, y := r.y - pad
          w := r.w + 2 * pad, h := r.h + 2 * pad }
      instances := instances.push {
        dst := expanded, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := col, kind := 2, aux0 := blur.toUInt32, aux1 := 255
      }
      let (sr, sg, sb, sa) := unpackColor col
      let sigma := blur / 2
      let halo : Int := if sigma == 0 then 0 else (sigma + (sigma - 1) * 2 : Nat)
      let support : Rect :=
        { x := r.x - halo, y := r.y - halo
          w := r.w + 2 * halo, h := r.h + 2 * halo }
      let (x0, y0, x1, y1) := clampBounds vw vh curClip support
      if x1 > x0 && y1 > y0 && sa > 0 then
        let saved := if activeRClips.isEmpty then ByteArray.empty else fb
        let mx := max 0 (x0 - halo)
        let my := max 0 (y0 - halo)
        let mw := (min (vw : Int) (x1 + halo) - mx).toNat
        let mh := (min (vh : Int) (y1 + halo) - my).toNat
        let bounds : Rect := ⟨0, 0, mw, mh⟩
        let empty := Text.AtlasPageBuffer.zeroBytes (mw * mh * 4)
        let mask := drawRoundedBox mw mh empty bounds { r with x := r.x - mx, y := r.y - my } radii 0xFFFFFFFF (0, 0, 0, 0) 0
        let blurred := blurBackdrop mask mw mh sigma
        let sw := (x1 - x0).toNat
        let sh := (y1 - y0).toNat
        let sx := (x0 - mx).toNat
        let sy := (y0 - my).toNat
        if sh > 0 && sw > 0 && (sy + sh - 1) * mw + sx + sw ≤ blurred.size / 4 then
          fb := FFI.blitGlyph fb blurred (y0.toNat * vw + x0.toNat).toUSize (sy * mw + sx).toUSize
            vw.toUSize mw.toUSize sw.toUSize sh.toUSize col false
        else
          for py in [y0.toNat : y1.toNat] do
            for px in [x0.toNat : x1.toNat] do
              let idx := (py * vw + px) * 4
              let alpha := ((py - my.toNat) * mw + px - mx.toNat) * 4 + 3
              let effA := ((sa.toNat * (blurred.get! alpha).toNat + 127) / 255).toUInt8
              let (nr, ng, nb, na) :=
                blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                  sr sg sb effA
              fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
        if !activeRClips.isEmpty then fb := applyRoundedClips vw vh saved fb ⟨x0, y0, x1 - x0, y1 - y0⟩ activeRClips
    | .glyph src dst col isColor pageIdx =>
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii := (0, 0, 0, 0), colorRGBA := col,
        kind := if isColor then 4 else 3, aux0 := pageIdx.toUInt32, aux1 := 255
      }
      if let some page := atlas.pages[pageIdx]? then
        let pw := page.atlas.width
        let ph := page.atlas.height
        let (sr, sg, sb, sa) := unpackColor col
        let (x0, y0, x1, y1) := clampBounds vw vh curClip dst
        if x1 > x0 && y1 > y0 && sa > 0 then
          let saved := if activeRClips.isEmpty then ByteArray.empty else fb
          let sx := src.x.toNat + (x0.toNat - dst.x.toNat)
          let sy := src.y.toNat + (y0.toNat - dst.y.toNat)
          let w := min (pw-sx) (x1-x0).toNat
          let h := min (ph-sy) (y1-y0).toNat
          if h > 0 && w > 0 && (sy+h-1)*pw+sx+w ≤ page.rgba.size/4 then
            fb := FFI.blitGlyph fb page.rgba (y0.toNat*vw+x0.toNat).toUSize (sy*pw+sx).toUSize
              vw.toUSize pw.toUSize w.toUSize h.toUSize col isColor
          else
           for py in [y0.toNat : y1.toNat] do
            let ty := src.y.toNat + (py - dst.y.toNat)
            if ty < ph then
              for px in [x0.toNat : x1.toNat] do
                let tx := src.x.toNat + (px - dst.x.toNat)
                if tx < pw then
                  let aIdx := (ty * pw + tx) * 4
                  if aIdx + 4 ≤ page.rgba.size then
                    let idx := (py * vw + px) * 4
                    if isColor then
                      let tr := page.rgba.get! aIdx
                      let tg := page.rgba.get! (aIdx + 1)
                      let tb := page.rgba.get! (aIdx + 2)
                      let ta := page.rgba.get! (aIdx + 3)
                      let (nr, ng, nb, na) :=
                        blendOverPremul (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                          tr tg tb ta sa
                      fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
                    else
                      let cov := page.rgba.get! (aIdx + 3)
                      let effA := ((sa.toNat * cov.toNat + 127) / 255).toUInt8
                      let (nr, ng, nb, na) :=
                        blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                          sr sg sb effA
                      fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
          if !activeRClips.isEmpty then fb := applyRoundedClips vw vh saved fb ⟨x0, y0, x1 - x0, y1 - y0⟩ activeRClips
    | .mask pageIdx src dst col =>
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii := (0, 0, 0, 0), colorRGBA := col,
        kind := 3, aux0 := pageIdx.toUInt32, aux1 := 255
      }
      if let some page := atlas.pages[pageIdx]? then
        let pw := page.atlas.width
        let ph := page.atlas.height
        let (sr, sg, sb, sa) := unpackColor col
        let (x0, y0, x1, y1) := clampBounds vw vh curClip dst
        let sw := src.w.toNat
        let sh := src.h.toNat
        let dw := dst.w.toNat
        let dh := dst.h.toNat
        if x1 > x0 && y1 > y0 && sa > 0 && sw > 0 && sh > 0 && dw > 0 && dh > 0 then
          let saved := if activeRClips.isEmpty then ByteArray.empty else fb
          if sw == dw && sh == dh then
            -- 1:1 coverage mask tinted by `col`: blend natively, clamped strictly inside `src`.
            let dx0 := x0.toNat - dst.x.toNat
            let dy0 := y0.toNat - dst.y.toNat
            let sx := src.x.toNat + dx0
            let sy := src.y.toNat + dy0
            let mw := min (min (pw - sx) (sw - dx0)) (x1 - x0).toNat
            let mh := min (min (ph - sy) (sh - dy0)) (y1 - y0).toNat
            if mh > 0 && mw > 0 && (sy + mh - 1) * pw + sx + mw ≤ page.rgba.size / 4 then
              fb := FFI.blitGlyph fb page.rgba (y0.toNat * vw + x0.toNat).toUSize (sy * pw + sx).toUSize
                vw.toUSize pw.toUSize mw.toUSize mh.toUSize col false
            else
              for py in [y0.toNat : y1.toNat] do
                let dy := py - dst.y.toNat
                let ty := src.y.toNat + dy
                if dy < sh && ty < ph then
                  for px in [x0.toNat : x1.toNat] do
                    let dx := px - dst.x.toNat
                    let tx := src.x.toNat + dx
                    if dx < sw && tx < pw then
                      let aIdx := (ty * pw + tx) * 4
                      if aIdx + 4 ≤ page.rgba.size then
                        let cov := page.rgba.get! (aIdx + 3)
                        let effA := ((sa.toNat * cov.toNat + 127) / 255).toUInt8
                        let idx := (py * vw + px) * 4
                        let (nr, ng, nb, na) :=
                          blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                            sr sg sb effA
                        fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
          else
            -- Scaled coverage mask (`src.w != dst.w` or `src.h != dst.h`, e.g. clamped wide lanes
            -- at 2x HiDPI or tall icons): sample with `VK_FILTER_NEAREST` pixel-center mapping
            -- strictly inside `[src.x, src.x + sw) × [src.y, src.y + sh)` to match `scene_sdf.glsl`.
            for py in [y0.toNat : y1.toNat] do
              let dy := py - dst.y.toNat
              let tyOff := min (sh - 1) (((2 * dy + 1) * sh) / (2 * dh))
              let ty := src.y.toNat + tyOff
              if ty < ph then
                for px in [x0.toNat : x1.toNat] do
                  let dx := px - dst.x.toNat
                  let txOff := min (sw - 1) (((2 * dx + 1) * sw) / (2 * dw))
                  let tx := src.x.toNat + txOff
                  if tx < pw then
                    let aIdx := (ty * pw + tx) * 4
                    if aIdx + 4 ≤ page.rgba.size then
                      let cov := page.rgba.get! (aIdx + 3)
                      if cov > 0 then
                        let effA := ((sa.toNat * cov.toNat + 127) / 255).toUInt8
                        let idx := (py * vw + px) * 4
                        let (nr, ng, nb, na) :=
                          blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                            sr sg sb effA
                        fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
          if !activeRClips.isEmpty then fb := applyRoundedClips vw vh saved fb ⟨x0, y0, x1 - x0, y1 - y0⟩ activeRClips
    | .image _tex src dst rad =>
      let radii : CornerRadii := (rad, rad, rad, rad)
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii, colorRGBA := 0xC8D2E6FF,
        kind := 5, aux0 := 0, aux1 := 255
      }
      let saved := if activeRClips.isEmpty then ByteArray.empty else fb
      fb := drawRoundedBox vw vh fb curClip dst radii 0xC8D2E6FF (0, 0, 0, 0) 0
      if !activeRClips.isEmpty then fb := applyRoundedClips vw vh saved fb (intersectRect curClip dst) activeRClips
  return (fb, instances)

/-- Full-frame compatibility entry point. -/
def rasterizeScene (vw vh : Nat) (clearColor : Color) (atlas : Text.GlyphAtlasCache)
    (scene : Scene) : ByteArray × Array GpuPrimInstance :=
  rasterizeSceneInto vw vh clearColor atlas none none scene

/-- Render a `Scene` onto `ctx`, staging GPU instances into native scratch memory via `FFI.memWrite`. -/
def renderFrame (ctx : VulkanContext) (clearColor : Color) (atlas : Text.GlyphAtlasCache)
    (scene : Scene) : IO VulkanContext := do
  let (fb, insts) := rasterizeScene ctx.width ctx.height clearColor atlas scene
  if ctx.scratchPtr != 0 then
    let _ ← stageInstances ctx insts
  return { ctx with
    framebuffer := fb
    lastUploadedDirtyRect := some { x := 0, y := 0, w := (ctx.width : Int), h := (ctx.height : Int) }
    lastDrawnPrims := insts.size
    lastDamagePixels := ctx.width * ctx.height
    previousPaint := some ⟨scene, atlas.pages, clearColor, ctx.width, ctx.height⟩ }

/-- Backdrop blur samples the whole framebuffer and therefore cannot be safely clipped to a dirty
rectangle. Such scenes use the full path; ordinary changed-node scenes reuse the old framebuffer. -/
def hasGlobalEffect (scene : Scene) : Bool :=
  scene.any fun p => match p with
    | .backdropBlur _ | .layerPush _ | .layerPop => true
    | _ => false

private def unionRect (a b : Rect) : Rect :=
  ⟨min a.x b.x, min a.y b.y, max a.right b.right - min a.x b.x, max a.bottom b.bottom - min a.y b.y⟩

private def horizNear (a b : Rect) (pad : Int := 32) : Bool :=
  !(a.right + pad ≤ b.x || b.right + pad ≤ a.x)

-- Diff the exact command stream into up to two horizontally disjoint dirty rectangles.
-- Keeping widely separated columns separate (such as transcript prose and a right-edge
-- overlay scrollbar) avoids expanding the dirty rectangle across untouched intervening chrome.
private def changedRects (vp : Rect) (old new : Scene) : Option (Array Rect) := Id.run do
  let n := min old.size new.size
  let mut pre := 0
  while pre < n && old[pre]? == new[pre]? do pre := pre + 1
  let mut suf := 0
  while suf < n - pre && old[old.size-1-suf]? == new[new.size-1-suf]? do suf := suf + 1
  let mut clips := [vp]
  for i in [:pre] do
    match old[i]? with
    | some (.clipPush r) | some (.clipPushRounded r _) => clips := intersectRect (clips.head?.getD vp) r :: clips
    | some .clipPop => clips := match clips with | _ :: _ :: _ => clips.tail! | _ => [vp]
    | _ => pure ()
  let clip := clips.head?.getD vp
  let mut rects : Array Rect := #[]
  for cmds in #[old, new] do
    for i in [pre:cmds.size-suf] do
      let some p := cmds[i]? | return none
      let some r := p.bounds | return none
      let b := intersectRect clip r
      if b.w > 0 && b.h > 0 then
        if rects.size == 0 then
          rects := #[b]
        else if rects.size == 1 then
          let a := rects[0]!
          if horizNear a b then
            rects := #[unionRect a b]
          else
            rects := #[a, b]
        else
          let r0 := rects[0]!
          let r1 := rects[1]!
          let (n0, n1) :=
            if horizNear r0 b then (unionRect r0 b, r1)
            else if horizNear r1 b then (r0, unionRect r1 b)
            else
              let gap0 := if b.x ≥ r0.right then b.x - r0.right else r0.x - b.right
              let gap1 := if b.x ≥ r1.right then b.x - r1.right else r1.x - b.right
              if gap0 ≤ gap1 then (unionRect r0 b, r1) else (r0, unionRect r1 b)
          if horizNear n0 n1 0 then
            rects := #[unionRect n0 n1]
          else
            rects := #[n0, n1]
  return some rects

-- Express paints in coordinates relative to a horizontal band. Equality includes
-- paint order, all style/sampling parameters and the actually visible scissor.
private def bandPaint (scene : Scene) (band : Rect) : Option (Array (Prim × Rect)) := Id.run do
  let mut stack := [band]
  let mut paints := #[]
  let rel := fun (r : Rect) => { r with y := r.y - band.y }
  for p in scene do
    let clip := stack.head?.getD band
    match p with
    | .clipPush r => stack := intersectRect clip r :: stack
    | .clipPop => if stack.length < 2 then return none else stack := stack.tail!
    | _ =>
      let some r := p.bounds | return none
      let vis := intersectRect clip r
      if !vis.isEmpty then
        let v := rel vis
        let key : Option Prim := match p with
          | .quad b c rad w e => some (.quad (if rad == 0 && w == 0 then v else rel b) c rad w e)
          | .rrect b c rad w e => some (.rrect (rel b) c rad w e)
          | .glyph s d c k p => if d.y < 0 then none else some (.glyph s (rel d) c k p)
          | .mask i s d c => if d.y < 0 then none else some (.mask i s (rel d) c)
          | _ => none
        let some k := key | return none
        paints := paints.push (k,v)
  return some paints

-- A matching glyph proposes a displacement only. Accept the copy solely when
-- the entire source and destination band have identical clipped paint programs.
private def scrollBand (old new : Scene) (dirty vp : Rect) : Option (Rect × Nat) := Id.run do
  if dirty.h < 160 || dirty.w < 128 then return none
  let mut i := 0
  while i < min old.size new.size && old[i]? == new[i]? do i := i + 1
  let mut shift := 0
  for j in [i:old.size] do
    if let some (.glyph s a c k pg1) := old[j]? then
      if a.y > dirty.y + 64 && a.y < dirty.bottom then
        for n in [max i (j-160):min new.size (j+64)] do
          if let some (.glyph t b e l pg2) := new[n]? then
            if s == t && a.x == b.x && c == e && k == l && pg1 == pg2 && a.y > b.y && a.y-b.y ≤ 64 then
              shift := (a.y-b.y).toNat
              break
        if shift > 0 then break
  if shift == 0 then return none
  let band := { dirty with h := dirty.h - max 96 (2 * (shift : Int)) }
  let src := { band with y := band.y + shift }
  if intersectRect vp src != src then return none
  let matchesBand (b : Rect) : Bool :=
    let s := { b with y := b.y + shift }
    match bandPaint old s, bandPaint new b with
    | some a, some c => a == c
    | _, _ => false
  if matchesBand band then
    return some (band, shift)
  -- Overlay scrollbars paint inside the right-edge gutter and move opposite to content.
  -- Inset by a narrow right-edge strip so `FFI.scrollRows` still reuses the content body.
  let gutter : Int := min (band.w / 8) 32
  if gutter > 0 && band.w > gutter + 96 then
    let inner := { band with w := band.w - gutter }
    if matchesBand inner then
      return some (inner, shift)
  return none

-- New glyph allocations may change unused texels. Prove that every old
-- sampling command still sees the same bytes, or discard the framebuffer.
private def samplesUnchanged (scene : Scene) (idx : Nat) (a b : Text.AtlasPageBuffer) : Bool := Id.run do
  if a.atlas.width != b.atlas.width || a.atlas.height != b.atlas.height then return false
  if a.rgba == b.rgba then return true
  for p in scene do
    let pair := match p with
      | .glyph src dst _ _ page => if idx == page then some (src,dst) else none
      | .mask page src dst _ => if idx == page then some (src,dst) else none
      | _ => none
    if let some (src,dst) := pair then
      let x := src.x.toNat
      let y := src.y.toNat
      let sw := if src.w > 0 then src.w.toNat else dst.w.toNat
      let sh := if src.h > 0 then src.h.toNat else dst.h.toNat
      let w := min sw (a.atlas.width - x)
      let h := min sh (a.atlas.height - y)
      if w > 0 && h > 0 then
        if ((y+h-1)*a.atlas.width+x+w)*4 > min a.rgba.size b.rgba.size then return false
        if !FFI.sameRows a.rgba b.rgba ((y * a.atlas.width + x) * 4).toUSize
            (a.atlas.width * 4).toUSize (w * 4).toUSize h.toUSize then return false
  return true

/-- Render only changed rectangles, preserving pixels outside them and culling unchanged visual
primitives. The scene remains authoritative: structural clip/layer commands are retained.
When `forceFull` is `false`, even a conservative viewport-sized `dirty` hint is narrowed via
`changedRects` so only changed nodes are repainted; `forceFull := true` bypasses diffing for
forced full repaints (resize, scale change, or `--verify-repaint` reference passes). -/
def renderFrameDamage (ctx : VulkanContext) (clearColor : Color) (atlas : Text.GlyphAtlasCache)
    (_dirty : Rect) (scene : Scene) (forceFull : Bool := false) : IO VulkanContext := do
  let some prev := ctx.previousPaint | return ← renderFrame ctx clearColor atlas scene
  if forceFull || prev.width != ctx.width || prev.height != ctx.height || prev.clear != clearColor ||
      ctx.framebuffer.size != ctx.width * ctx.height * 4 || hasGlobalEffect scene || hasGlobalEffect prev.scene then
    return ← renderFrame ctx clearColor atlas scene
  let vp : Rect := ⟨0,0,ctx.width,ctx.height⟩
  let profile := (← IO.getEnv "ORB_U7_PROFILE") == some "1"
  let t0 ← IO.monoNanosNow
  let some dirtyRects := changedRects vp prev.scene scene | return ← renderFrame ctx clearColor atlas scene
  let t1 ← IO.monoNanosNow
  if prev.pages.size != atlas.pages.size then return ← renderFrame ctx clearColor atlas scene
  for i in [:prev.pages.size] do
    let a := prev.pages[i]!
    let b := atlas.pages[i]!
    if !samplesUnchanged prev.scene i a b then
      return ← renderFrame ctx clearColor atlas scene
  if dirtyRects.isEmpty then
    if profile then IO.eprintln s!"u7-paint-ns {t1-t0} {(← IO.monoNanosNow)-t1} 0 0 0"
    return { ctx with
      previousPaint := some ⟨scene, atlas.pages, clearColor, ctx.width, ctx.height⟩
      lastUploadedDirtyRect := none
      lastDamagePixels := 0
      lastDrawnPrims := 0
      partialFrames := ctx.partialFrames + 1 }
  let t2 ← IO.monoNanosNow
  -- In profile mode make the copy-on-write allocation explicit so it can be
  -- timed separately from clearing and painting. Ordinary runs retain COW.
  let initial := if profile then ctx.framebuffer.copySlice 0 ByteArray.empty 0 ctx.framebuffer.size else ctx.framebuffer
  let ctx := { ctx with framebuffer := ByteArray.empty }
  let t3 ← IO.monoNanosNow
  let mut fb := initial
  let mut insts : Array GpuPrimInstance := #[]
  let mut pixels : Nat := 0
  let mut uploadedUnion : Option Rect := none
  for dRect in dirtyRects do
    let mut paint := dRect
    let mut extraStrip : Option Rect := none
    if let some (band, shift) := scrollBand prev.scene scene dRect vp then
      fb := FFI.scrollRows fb ((band.y.toNat*ctx.width+band.x.toNat)*4).toUSize
        (ctx.width*4).toUSize (band.w.toNat*4).toUSize band.h.toNat.toUSize shift.toUSize
      paint := { dRect with y := band.bottom, h := dRect.bottom - band.bottom }
      if band.right < dRect.right then
        extraStrip := some { x := band.right, y := dRect.y, w := dRect.right - band.right, h := band.bottom - dRect.y }
      if profile then IO.eprintln s!"u7-scroll-reuse dy={shift} pixels={band.w*band.h}"
    let (fb0, insts0) := rasterizeSceneInto ctx.width ctx.height clearColor atlas (some fb) (some paint) scene
    fb := fb0
    insts := insts ++ insts0
    if let some strip := extraStrip then
      let (fb1, insts1) := rasterizeSceneInto ctx.width ctx.height clearColor atlas (some fb) (some strip) scene
      fb := fb1
      insts := insts ++ insts1
    let clipped := intersectRect vp dRect
    if !clipped.isEmpty then
      uploadedUnion := match uploadedUnion with
        | none => some clipped
        | some u => some (unionRect u clipped)
    pixels := pixels + (max 0 clipped.w * max 0 clipped.h).toNat
  let t4 ← IO.monoNanosNow
  if ctx.scratchPtr != 0 then
    let _ ← stageInstances ctx insts
  if profile then IO.eprintln s!"u7-paint-ns {t1-t0} {t2-t1} {t3-t2} {t4-t3} {(← IO.monoNanosNow)-t4}"
  return {
    ctx with
    framebuffer := fb
    previousPaint := some ⟨scene, atlas.pages, clearColor, ctx.width, ctx.height⟩
    lastUploadedDirtyRect := uploadedUnion
    lastDrawnPrims := insts.size
    lastDamagePixels := pixels
    partialFrames := ctx.partialFrames + 1
  }

/-- Tear down an active GPU session after unrecoverable `DEVICE_LOST` and switch to `cpuShm`. -/
private def fallbackToCpuShm (ctx : VulkanContext) (reason : String) : IO VulkanContext := do
  if let some sess := ctx.gpuSession then
    if let some pipe := sess.pipe then
      Vk.destroyInstancedPipeline sess.wsi.dev pipe
    let _ ← Vk.destroyWsi sess.wsi
  return { ctx with
    backend := .cpuShm
    gpuSession := none
    fallbackReason := some reason
    gpuAllocatedBytes := 0
    previousPaint := none
    framebuffer := ByteArray.empty }

/-- Render and present a live Wayland frame on the active Vulkan backend (`vkInstanced` or
`vkPresent`). On `vkInstanced`, CPU `framebuffer` and `previousPaint` are never allocated.
Returns `(ctx', atlas', handledByVulkan, didPresent)`:
- `(true, true)`: frame was presented to WSI (clear damage, bump `presentCount`).
- `(true, false)`: swapchain needs recreate / zero-extent suspended (preserve damage, do not bump `presentCount`).
- `(false, false)`: runtime `DEVICE_LOST` fell back to `cpuShm` (caller renders CPU + `wl_shm`). -/
def renderAndPresentGpu (ctx : VulkanContext) (clearColor : Color) (atlas : Text.GlyphAtlasCache)
    (scene : Scene) (dirty : Option Rect) (prePresent onPresentAborted : IO Unit)
    (forceFull : Bool := false) :
    IO (VulkanContext × Text.GlyphAtlasCache × Bool × Bool) := do
  let some sess := ctx.gpuSession | return (ctx, atlas, false, false)
  match ctx.backend, sess.pipe with
  | .vkInstanced, some pipe =>
    -- Backdrop blur, opacity layers, and explicit full-repaint overrides present the whole surface.
    let presentDirty := if forceFull || hasGlobalEffect scene then none else dirty
    let (wsi', pipe', outcome, primCount, ssboBytes, atlasBytes) ←
      Vk.presentInstancedScene sess.wsi pipe ctx.width ctx.height clearColor atlas scene presentDirty prePresent onPresentAborted
    let allocBytes ← wsi'.dev.allocatedBytes.get
    match outcome with
    | .presented _ acqNs upNs subNs presNs =>
      let ctx' : VulkanContext := { ctx with
        framebuffer := ByteArray.empty
        previousPaint := none
        lastUploadedDirtyRect := dirty
        gpuSession := some { wsi := wsi', pipe := some pipe' }
        swapchainRecreates := wsi'.sm.recreateCount
        gpuAllocatedBytes := allocBytes
        lastAcquireNs := acqNs
        lastUploadNs := upNs
        lastSubmitNs := subNs
        lastPresentNs := presNs
        lastUploadBytes := ssboBytes + atlasBytes
        lastAtlasUploadBytes := atlasBytes
        lastSsboBytes := ssboBytes
        lastDrawnPrims := primCount
        lastDamagePixels := ctx.width * ctx.height }
      return (ctx', atlas.clearGpuDirtyRects, true, true)
    | .skipped =>
      return ({ ctx with gpuSession := some { wsi := wsi', pipe := some pipe' }, gpuAllocatedBytes := allocBytes }, atlas, true, false)
    | .needsRecreate =>
      return ({ ctx with gpuSession := some { wsi := wsi', pipe := some pipe' }, swapchainRecreates := wsi'.sm.recreateCount, gpuAllocatedBytes := allocBytes }, atlas, true, false)
    | .deviceLost reason =>
      let fbCtx ← fallbackToCpuShm { ctx with gpuSession := some { wsi := wsi', pipe := some pipe' } } reason
      return (fbCtx, atlas, false, false)
  | .vkPresent, _ =>
    let ctx1 ← match dirty with
      | some d => renderFrameDamage ctx clearColor atlas d scene forceFull
      | none => renderFrame ctx clearColor atlas scene
    let (wsi', outcome) ←
      Vk.presentCpuDirty sess.wsi ctx1.framebuffer ctx1.width ctx1.height ctx1.lastUploadedDirtyRect prePresent onPresentAborted
    let allocBytes ← wsi'.dev.allocatedBytes.get
    match outcome with
    | .presented upBytes acqNs upNs subNs presNs =>
      let ctx' : VulkanContext := { ctx1 with
        gpuSession := some { sess with wsi := wsi' }
        swapchainRecreates := wsi'.sm.recreateCount
        gpuAllocatedBytes := allocBytes
        lastAcquireNs := acqNs
        lastUploadNs := upNs
        lastSubmitNs := subNs
        lastPresentNs := presNs
        lastUploadBytes := upBytes }
      return (ctx', atlas, true, true)
    | .skipped =>
      return ({ ctx1 with gpuSession := some { sess with wsi := wsi' }, gpuAllocatedBytes := allocBytes }, atlas, true, false)
    | .needsRecreate =>
      let wsiDirty := match wsi'.bundle with
        | some b => { wsi' with bundle := some { b with backingNeedsFullUpload := true } }
        | none => wsi'
      return ({ ctx1 with gpuSession := some { sess with wsi := wsiDirty }, swapchainRecreates := wsiDirty.sm.recreateCount, gpuAllocatedBytes := allocBytes }, atlas, true, false)
    | .deviceLost reason =>
      let fbCtx ← fallbackToCpuShm { ctx1 with gpuSession := some { sess with wsi := wsi' } } reason
      return (fbCtx, atlas, false, false)
  | _, _ =>
    return (ctx, atlas, false, false)

/-- Compute IEEE 802.3 CRC-32 for a PNG chunk (`type ++ data`). -/
def crc32 (data : ByteArray) : UInt32 := Id.run do
  let mut c : UInt32 := 0xFFFFFFFF
  for i in [0:data.size] do
    let b := (data.get! i).toUInt32
    c := c ^^^ b
    for _ in [0:8] do
      if (c &&& 1) != 0 then
        c := (c >>> 1) ^^^ 0xEDB88320
      else
        c := c >>> 1
  return c ^^^ 0xFFFFFFFF

/-- Compute Adler-32 checksum over raw zlib payload bytes. -/
def adler32 (data : ByteArray) : UInt32 := Id.run do
  let mut s1 : UInt32 := 1
  let mut s2 : UInt32 := 0
  for i in [0:data.size] do
    s1 := (s1 + (data.get! i).toUInt32) % 65521
    s2 := (s2 + s1) % 65521
  return (s2 <<< 16) ||| s1

private def appendPngChunk (out : ByteArray) (tag : String) (payload : ByteArray) : ByteArray :=
  let tagBytes := tag.toUTF8
  let body := tagBytes ++ payload
  let crc := crc32 body
  let out1 := pushU32BE out payload.size.toUInt32
  let out2 := out1 ++ body
  pushU32BE out2 crc

/-- Encode an RGBA8 pixel buffer (`width × height × 4` bytes) into a valid, deterministic PNG
(`ByteArray`) using uncompressed RFC 1950 / RFC 1951 stored DEFLATE blocks. -/
def encodeRGBA8ToPNG (width height : Nat) (rgba : ByteArray) : ByteArray := Id.run do
  let rowBytes := width * 4
  let rawSize := height * (1 + rowBytes)
  let mut raw := ByteArray.emptyWithCapacity rawSize
  for y in [0:height] do
    raw := raw.push 0
    let rowStart := y * rowBytes
    for x in [0:rowBytes] do
      let idx := rowStart + x
      raw := raw.push (if idx < rgba.size then rgba.get! idx else 0)

  let mut zlib := ByteArray.emptyWithCapacity (raw.size + (raw.size / 65535 + 2) * 5 + 6)
  zlib := zlib.push 0x78 |>.push 0x01
  let mut pos : Nat := 0
  let total := raw.size
  if total == 0 then
    zlib := zlib.push 0x01
    zlib := pushU16LE zlib 0
    zlib := pushU16LE zlib 0xFFFF
  else
    while pos < total do
      let rem := total - pos
      let blkLen := min rem 65535
      let isFinal : UInt8 := if pos + blkLen ≥ total then 0x01 else 0x00
      zlib := zlib.push isFinal
      let len16 := blkLen.toUInt16
      zlib := pushU16LE zlib len16
      zlib := pushU16LE zlib (len16 ^^^ 0xFFFF)
      zlib := zlib ++ raw.extract pos (pos + blkLen)
      pos := pos + blkLen
  zlib := pushU32BE zlib (adler32 raw)

  let sig : ByteArray := ByteArray.mk #[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  let mut ihdr := ByteArray.emptyWithCapacity 13
  ihdr := pushU32BE ihdr width.toUInt32
  ihdr := pushU32BE ihdr height.toUInt32
  ihdr := ihdr.push 8 |>.push 6 |>.push 0 |>.push 0 |>.push 0
  let mut png := sig
  png := appendPngChunk png "IHDR" ihdr
  png := appendPngChunk png "IDAT" zlib
  png := appendPngChunk png "IEND" ByteArray.empty
  return png

/-- Write the current framebuffer of `ctx` to a PNG file at `path`. -/
def writeFramebufferPNG (ctx : VulkanContext) (path : System.FilePath) : IO Unit := do
  let png := encodeRGBA8ToPNG ctx.width ctx.height ctx.framebuffer
  IO.FS.writeBinFile path png

end LeanUI.Vulkan
