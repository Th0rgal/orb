import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.FFI
import LeanUI.Text
/-!
# LeanUI.Vulkan — Vulkan 1.3 dynamic loader bridge, instanced SDF/glyph renderer & PNG encoder

Wraps `LeanUI.FFI.{dlSym, call, memAlloc, memFree, memWrite, memRead}` (`c/lean_ui_vulkan.c`),
packs `Prim` batches into 80-byte `PrimInstance` records matching `shaders/scene_sdf.glsl`,
executes instanced SDF rounded-rect / border / drop-shadow / glyph / gradient / mask / image
rendering with hierarchical `clipPush`/`clipPop` and `layerPush`/`layerPop` compositing, and
encodes deterministic RGBA8 PNG files for `--headless-golden`.
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

/-- Dynamic Vulkan 1.3 loader and scratch buffer context backed by `LeanUI.FFI`. -/
structure VulkanContext where
  vkGetInstanceProcAddr : USize := 0
  vkCreateInstance : USize := 0
  vkEnumeratePhysicalDevices : USize := 0
  scratchPtr : USize := 0
  scratchCap : USize := 0
  width : Nat := 1280
  height : Nat := 800
  framebuffer : ByteArray := ByteArray.empty
  deriving Inhabited

/-- Resolve `vkGetInstanceProcAddr` from `libvulkan.so.1` via `FFI.dlSym`, allocate a native
scratch block for SSBO/struct staging via `FFI.memAlloc`, and initialize the offscreen RGBA8
framebuffer. Gracefully falls back when no Vulkan ICD or `libvulkan.so.1` is present. -/
def initVulkan (width height : Nat) : IO VulkanContext := do
  let getProc ← try FFI.dlSym "libvulkan.so.1" "vkGetInstanceProcAddr" catch _ => pure 0
  let createInst ←
    if getProc != 0 then
      try FFI.dlSym "libvulkan.so.1" "vkCreateInstance" catch _ => pure 0
    else pure 0
  let enumDevs ←
    if getProc != 0 then
      try FFI.dlSym "libvulkan.so.1" "vkEnumeratePhysicalDevices" catch _ => pure 0
    else pure 0
  let scratchCap : USize := 65536
  let scratchPtr ← try FFI.memAlloc scratchCap catch _ => pure 0
  let fb := ByteArray.mk (Array.replicate (width * height * 4) 0)
  return {
    vkGetInstanceProcAddr := getProc
    vkCreateInstance := createInst
    vkEnumeratePhysicalDevices := enumDevs
    scratchPtr
    scratchCap
    width
    height
    framebuffer := fb
  }

/-- Free native scratch memory (`FFI.memFree`) owned by `VulkanContext`. -/
def shutdownVulkan (ctx : VulkanContext) : IO Unit := do
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
    if y < x then
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
  let rad16 : Int := (min rawRad maxR : Int) * 16
  let qx16 : Int := (dx16.natAbs : Int) - hx16 + rad16
  let qy16 : Int := (dy16.natAbs : Int) - hy16 + rad16
  let mx16 : Nat := if qx16 > 0 then qx16.toNat else 0
  let my16 : Nat := if qy16 > 0 then qy16.toNat else 0
  let outLen16 : Int := (isqrt (mx16 * mx16 + my16 * my16) : Int)
  let inMax16 : Int := min (max qx16 qy16) 0
  inMax16 + outLen16 - rad16

/-- Alpha-over blend of `src = (sr, sg, sb, sa)` onto `(dr, dg, db, da)` in `[0..255]`. -/
@[inline] private def blendOver (dr dg db da sr sg sb sa : UInt8) : UInt8 × UInt8 × UInt8 × UInt8 :=
  if sa == 0 then (dr, dg, db, da)
  else if sa == 255 then (sr, sg, sb, 255)
  else
    let a := sa.toNat
    let inv := 255 - a
    let r := (sr.toNat * a + dr.toNat * inv + 127) / 255
    let g := (sg.toNat * a + dg.toNat * inv + 127) / 255
    let b := (sb.toNat * a + db.toNat * inv + 127) / 255
    let outA := a + (da.toNat * inv + 127) / 255
    (r.toUInt8, g.toUInt8, b.toUInt8, (min outA 255).toUInt8)

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

/-- Saved offscreen layer state for `Prim.layerPush` / `Prim.layerPop`. -/
private structure LayerFrame where
  opacity : Nat
  clip : Rect
  savedBuf : ByteArray

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
  for py in [y0.toNat : y1.toNat] do
    for px in [x0.toNat : x1.toNat] do
      let dOut16 := sdfRoundedRect16 r radii (px : Int) (py : Int)
      if dOut16 < 8 then
        let covOut : Nat := if dOut16 ≤ -8 then 255 else ((8 - dOut16).toNat * 255) / 16
        let idx := (py * vw + px) * 4
        if fa > 0 then
          let effA : UInt8 := ((fa.toNat * covOut + 127) / 255).toUInt8
          let (nr, ng, nb, na) :=
            blendOver (out.get! idx) (out.get! (idx + 1)) (out.get! (idx + 2)) (out.get! (idx + 3))
              fr fg fbC effA
          out := out.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
        if hasBorder then
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
  let mut out := ByteArray.mk (Array.replicate fb.size 0)
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
    out := blurAxis out vw vh radius true
    out := blurAxis out vw vh radius false
  return out

/-- Render a `Scene` (`Array Prim`) onto an RGBA8 buffer `(vw × vh)` using the unified SDF
rounded-rect / border / drop-shadow / glyph-atlas / clip / layer pipeline. -/
def rasterizeScene (vw vh : Nat) (clearColor : Color) (atlas : Text.GlyphAtlasCache)
    (scene : Scene) : ByteArray × Array GpuPrimInstance := Id.run do
  let (cr, cg, cb, ca) := unpackColor clearColor
  let totalBytes := vw * vh * 4
  let mut fb := ByteArray.emptyWithCapacity totalBytes
  for _ in [0 : vw * vh] do
    fb := fb.push cr |>.push cg |>.push cb |>.push ca
  let fullClip : Rect := { x := 0, y := 0, w := (vw : Int), h := (vh : Int) }
  let mut clipStack : List Rect := [fullClip]
  let mut layerStack : List LayerFrame := []
  let mut instances : Array GpuPrimInstance := #[]

  for prim in scene do
    let curClip := clipStack.head?.getD fullClip
    match prim with
    | .backdropBlur sigma =>
      fb := blurBackdrop fb vw vh sigma
    | .clipPush r =>
      clipStack := intersectRect curClip r :: clipStack
    | .clipPushRounded r _radii =>
      clipStack := intersectRect curClip r :: clipStack
    | .clipPop =>
      if let _ :: tail := clipStack then
        clipStack := if tail.isEmpty then [fullClip] else tail
    | .layerPush opacity =>
      let saved := fb
      fb := ByteArray.mk (Array.replicate totalBytes 0)
      layerStack := { opacity := min opacity 255, clip := curClip, savedBuf := saved } :: layerStack
    | .layerPop =>
      if let top :: rest := layerStack then
        layerStack := rest
        let layerBuf := fb
        fb := top.savedBuf
        let (x0, y0, x1, y1) := clampBounds vw vh top.clip fullClip
        if x1 > x0 && y1 > y0 then
          for py in [y0.toNat : y1.toNat] do
            for px in [x0.toNat : x1.toNat] do
              let idx := (py * vw + px) * 4
              let lr := layerBuf.get! idx
              let lg := layerBuf.get! (idx + 1)
              let lb := layerBuf.get! (idx + 2)
              let la := ((layerBuf.get! (idx + 3)).toNat * top.opacity + 127) / 255
              if la > 0 then
                let dr := fb.get! idx
                let dg := fb.get! (idx + 1)
                let db := fb.get! (idx + 2)
                let da := fb.get! (idx + 3)
                let (nr, ng, nb, na) := blendOver dr dg db da lr lg lb la.toUInt8
                fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
    | .quad r fill rad bw border =>
      let radii : CornerRadii := (rad, rad, rad, rad)
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := fill, kind := 0, aux0 := bw.toUInt32, aux1 := 255
      }
      if bw > 0 then
        instances := instances.push {
          dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
          radii, colorRGBA := border, kind := 1, aux0 := bw.toUInt32, aux1 := 255
        }
      fb := drawRoundedBox vw vh fb curClip r radii fill (bw, bw, bw, bw) border
    | .rrect r fill radii borders border =>
      let (bt, _, _, _) := borders
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := fill, kind := 0, aux0 := bt.toUInt32, aux1 := 255
      }
      fb := drawRoundedBox vw vh fb curClip r radii fill borders border
    | .linear r c0 c1 _angle rad =>
      let radii : CornerRadii := (rad, rad, rad, rad)
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := c0, kind := 0, aux0 := c1, aux1 := 255
      }
      let (r0, g0, b0, a0) := unpackColor c0
      let (r1, g1, b1, a1) := unpackColor c1
      let (x0, y0, x1, y1) := clampBounds vw vh curClip r
      let span := max 1 r.h.toNat
      if x1 > x0 && y1 > y0 then
        for py in [y0.toNat : y1.toNat] do
          let t := min span (py - r.y.toNat)
          let inv := span - t
          let mr := ((r0.toNat * inv + r1.toNat * t) / span).toUInt8
          let mg := ((g0.toNat * inv + g1.toNat * t) / span).toUInt8
          let mb := ((b0.toNat * inv + b1.toNat * t) / span).toUInt8
          let ma := ((a0.toNat * inv + a1.toNat * t) / span).toUInt8
          for px in [x0.toNat : x1.toNat] do
            let d16 := sdfRoundedRect16 r radii (px : Int) (py : Int)
            if d16 < 8 then
              let cov : Nat := if d16 ≤ -8 then 255 else ((8 - d16).toNat * 255) / 16
              let effA := ((ma.toNat * cov + 127) / 255).toUInt8
              let idx := (py * vw + px) * 4
              let (nr, ng, nb, na) :=
                blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                  mr mg mb effA
              fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
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
      -- CSS blur-radius is twice Gaussian sigma. Blur coverage, not the distance
      -- field: the old polynomial falloff made broad dark wedges beside dialogs.
      let empty := ByteArray.mk (Array.replicate totalBytes 0)
      let mask := drawRoundedBox vw vh empty fullClip r radii 0xFFFFFFFF (0, 0, 0, 0) 0
      let blurred := blurBackdrop mask vw vh (blur / 2)
      let (x0, y0, x1, y1) := clampBounds vw vh curClip expanded
      if x1 > x0 && y1 > y0 && sa > 0 then
        for py in [y0.toNat : y1.toNat] do
          for px in [x0.toNat : x1.toNat] do
            let idx := (py * vw + px) * 4
            let effA := ((sa.toNat * (blurred.get! (idx + 3)).toNat + 127) / 255).toUInt8
            let (nr, ng, nb, na) :=
              blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                sr sg sb effA
            fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
    | .glyph src dst col isColor =>
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii := (0, 0, 0, 0), colorRGBA := col,
        kind := if isColor then 4 else 3, aux0 := 0, aux1 := 255
      }
      if let some page := atlas.pages[0]? then
        let pw := page.atlas.width
        let ph := page.atlas.height
        let (sr, sg, sb, sa) := unpackColor col
        let (x0, y0, x1, y1) := clampBounds vw vh curClip dst
        if x1 > x0 && y1 > y0 && sa > 0 then
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
                      let ta := ((page.rgba.get! (aIdx + 3)).toNat * sa.toNat + 127) / 255
                      let (nr, ng, nb, na) :=
                        blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                          tr tg tb ta.toUInt8
                      fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
                    else
                      let cov := page.rgba.get! (aIdx + 3)
                      let effA := ((sa.toNat * cov.toNat + 127) / 255).toUInt8
                      let (nr, ng, nb, na) :=
                        blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                          sr sg sb effA
                      fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
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
        if x1 > x0 && y1 > y0 && sa > 0 then
          for py in [y0.toNat : y1.toNat] do
            let ty := src.y.toNat + (py - dst.y.toNat)
            if ty < ph then
              for px in [x0.toNat : x1.toNat] do
                let tx := src.x.toNat + (px - dst.x.toNat)
                if tx < pw then
                  let aIdx := (ty * pw + tx) * 4
                  if aIdx + 4 ≤ page.rgba.size then
                    let cov := page.rgba.get! (aIdx + 3)
                    let effA := ((sa.toNat * cov.toNat + 127) / 255).toUInt8
                    let idx := (py * vw + px) * 4
                    let (nr, ng, nb, na) :=
                      blendOver (fb.get! idx) (fb.get! (idx + 1)) (fb.get! (idx + 2)) (fb.get! (idx + 3))
                        sr sg sb effA
                    fb := fb.set! idx nr |>.set! (idx + 1) ng |>.set! (idx + 2) nb |>.set! (idx + 3) na
    | .image _tex src dst rad =>
      let radii : CornerRadii := (rad, rad, rad, rad)
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii, colorRGBA := 0xC8D2E6FF,
        kind := 5, aux0 := 0, aux1 := 255
      }
      fb := drawRoundedBox vw vh fb curClip dst radii 0xC8D2E6FF (0, 0, 0, 0) 0
  return (fb, instances)

/-- Render a `Scene` onto `ctx`, staging GPU instances into native scratch memory via `FFI.memWrite`. -/
def renderFrame (ctx : VulkanContext) (clearColor : Color) (atlas : Text.GlyphAtlasCache)
    (scene : Scene) : IO VulkanContext := do
  let (fb, insts) := rasterizeScene ctx.width ctx.height clearColor atlas scene
  let _ ← stageInstances ctx insts
  return { ctx with framebuffer := fb }

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
