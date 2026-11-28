import Std.Data.HashMap
import LeanUI.Defs
import LeanUI.Layout
import LeanUI.Kernel
import LeanUI.FFI
/-!
# LeanUI.Text — Fontconfig + FreeType + HarfBuzz wrapper & shelf-packed glyph atlas

Wraps `LeanUI.FFI.{fontOpen, fontClose, fontMetrics, shape, rasterize}` (`c/lean_ui_text.c`)
and integrates directly with `LeanUI.Atlas.{allocPadded, allocPages, reset}` and
`LeanUI.HashCache` keyed by `GlyphKey` (`(fontId, glyphId, sizeSub, subpx)`).
-/
namespace LeanUI.Text

@[inline] private def readU32LE (b : ByteArray) (off : Nat) : UInt32 :=
  if off + 4 ≤ b.size then
    let b0 := b.get! off |>.toUInt32
    let b1 := b.get! (off + 1) |>.toUInt32
    let b2 := b.get! (off + 2) |>.toUInt32
    let b3 := b.get! (off + 3) |>.toUInt32
    b0 ||| (b1 <<< 8) ||| (b2 <<< 16) ||| (b3 <<< 24)
  else 0

@[inline] private def readI32LE (b : ByteArray) (off : Nat) : Int :=
  let u := readU32LE b off
  if u ≥ 0x80000000 then (u.toNat : Int) - 0x100000000 else (u.toNat : Int)

/-- Scaled 26.6 (`1/64` px) font metrics decoded from `FFI.fontMetrics` (20 bytes). -/
structure FontMetrics where
  ascender : Int
  descender : Int
  lineHeight : Int
  underlinePosition : Int
  underlineThickness : Int
  deriving DecidableEq, Repr, Inhabited

/-- Decode a 20-byte `ByteArray` from `FFI.fontMetrics` into `FontMetrics`. -/
def decodeFontMetrics (b : ByteArray) : FontMetrics :=
  if b.size < 20 then
    { ascender := 0, descender := 0, lineHeight := 0, underlinePosition := 0, underlineThickness := 0 }
  else
    { ascender := readI32LE b 0
      descender := readI32LE b 4
      lineHeight := readI32LE b 8
      underlinePosition := readI32LE b 12
      underlineThickness := readI32LE b 16 }

/-- One HarfBuzz shaped glyph entry in 26.6 (`1/64` px) fractional coordinates. -/
structure ShapedGlyph where
  glyphId : UInt32
  cluster : UInt32
  xAdvance64 : Int
  yAdvance64 : Int := 0
  xOffset64 : Int
  yOffset64 : Int := 0
  deriving DecidableEq, Repr, Inhabited

/-- Decode the `ByteArray` returned by `FFI.shape` into `Array ShapedGlyph`.
Supports both the 24-byte C ABI record `(glyph, cluster, xAdv, yAdv, xOff, yOff)`
from `c/lean_ui_text.c` and compact 16-byte `(glyph, cluster, xAdv, xOff)` test records. -/
def decodeShapedGlyphs (b : ByteArray) : Array ShapedGlyph := Id.run do
  let mut out : Array ShapedGlyph := #[]
  if b.size == 0 then return out
  let stride : Nat := if b.size % 24 == 0 then 24 else if b.size % 16 == 0 then 16 else 24
  let n := b.size / stride
  for i in [0:n] do
    let off := i * stride
    let glyphId := readU32LE b off
    let cluster := readU32LE b (off + 4)
    let xAdvance64 := readI32LE b (off + 8)
    if stride == 24 then
      let yAdvance64 := readI32LE b (off + 12)
      let xOffset64 := readI32LE b (off + 16)
      let yOffset64 := readI32LE b (off + 20)
      out := out.push { glyphId, cluster, xAdvance64, yAdvance64, xOffset64, yOffset64 }
    else
      let xOffset64 := readI32LE b (off + 12)
      out := out.push { glyphId, cluster, xAdvance64, yAdvance64 := 0, xOffset64, yOffset64 := 0 }
  return out

/-- Decoded FreeType glyph bitmap from `FFI.rasterize`.
`format` is `1` for R8 grayscale coverage (`isColor = false`) and `4` for BGRA8 color (`isColor = true`). -/
structure RasterizedGlyph where
  width : Nat
  height : Nat
  bearingX : Int
  bearingY : Int
  format : UInt32
  isColor : Bool
  pixels : ByteArray
  deriving Inhabited

/-- Decode the `ByteArray` returned by `FFI.rasterize`.
Handles both the 17-byte header `(w:u32, h:u32, left:i32, top:i32, isColor:u8)` emitted by
`c/lean_ui_text.c` and 20-byte `(w:u32, h:u32, left:i32, top:i32, format:u32)` headers. -/
def decodeRasterizedGlyph (b : ByteArray) : RasterizedGlyph :=
  if b.size < 17 then
    { width := 0, height := 0, bearingX := 0, bearingY := 0, format := 1, isColor := false, pixels := ByteArray.empty }
  else
    let w := (readU32LE b 0).toNat
    let h := (readU32LE b 4).toNat
    let bx := readI32LE b 8
    let by_ := readI32LE b 12
    let c16 := b.get! 16
    let isC17 := c16 != 0
    let bpp17 := if isC17 then 4 else 1
    if b.size == 17 + w * h * bpp17 then
      let fmt : UInt32 := if isC17 then 4 else 1
      { width := w, height := h, bearingX := bx, bearingY := by_,
        format := fmt, isColor := isC17, pixels := b.extract 17 b.size }
    else if b.size ≥ 20 then
      let fmtRaw := readU32LE b 16
      let isC := fmtRaw == 4 || fmtRaw == 1 && b.size == 20 + w * h * 4
      let fmt : UInt32 := if isC then 4 else 1
      { width := w, height := h, bearingX := bx, bearingY := by_,
        format := fmt, isColor := isC, pixels := b.extract 20 b.size }
    else
      { width := w, height := h, bearingX := bx, bearingY := by_,
        format := if isC17 then 4 else 1, isColor := isC17, pixels := b.extract 17 b.size }

/-- Deterministic 64-bit mixing hash for `GlyphKey` used with `Kernel.HashCache` and `Std.HashMap`. -/
@[inline] def hashGlyphKey (k : GlyphKey) : UInt64 :=
  let h0 : UInt64 := 0x9e3779b97f4a7c15
  let h1 := (h0 ^^^ k.font.toUInt64) * 0xbf58476d1ce4e5b9
  let h2 := (h1 ^^^ k.glyph.toUInt64) * 0x94d049bb133111eb
  let h3 := (h2 ^^^ k.sizeSub.toUInt64) * 0xbf58476d1ce4e5b9
  let h4 := (h3 ^^^ (k.subpx &&& 3).toUInt64) * 0x94d049bb133111eb
  h4 ^^^ (h4 >>> 31)

instance : Hashable GlyphKey where
  hash := hashGlyphKey

/-- Cached atlas entry for a rasterized glyph. -/
structure AtlasGlyphEntry where
  page : Nat
  uv : Rect
  bearingX : Int
  bearingY : Int
  isColor : Bool
  deriving DecidableEq, Repr, Inhabited

/-- Pixel buffer backing one GPU/CPU glyph atlas page (stored as RGBA8 for unified sampling). -/
structure AtlasPageBuffer where
  atlas : Atlas := { width := 0, height := 0, shelves := [], nextY := 0 }
  rgba : ByteArray := ByteArray.empty
  deriving Inhabited

namespace AtlasPageBuffer

/-- Allocate packed pixels directly; an `Array UInt8` temporary needs a pointer per byte. -/
def zeroBytes (n : Nat) : ByteArray := Id.run do
  if n == 0 then return ByteArray.empty
  let mut out := (ByteArray.emptyWithCapacity n).push 0
  -- Extend in contiguous chunks; avoid a Lean loop per zero byte.
  let block := ByteArray.mk (Array.replicate (min 4096 n) 0)
  while out.size < n do
    out := block.copySlice 0 out out.size (min block.size (n - out.size))
  return out

/-- Create an empty zero-initialized `pw × ph` RGBA8 atlas page. -/
def create (pw ph : Nat) : AtlasPageBuffer :=
  { atlas := { width := pw, height := ph, shelves := [], nextY := 0 }
    rgba := ByteArray.empty }

/-- Blit a `RasterizedGlyph` into `dstRect` on this page.
R8 glyphs are stored with `(255, 255, 255, cov)` and BGRA8 glyphs are swizzled to RGBA8. -/
def blitGlyph (page : AtlasPageBuffer) (dstRect : Rect) (rg : RasterizedGlyph) : AtlasPageBuffer := Id.run do
  let pw := page.atlas.width
  let ph := page.atlas.height
  let dx := dstRect.x.toNat
  let dy := dstRect.y.toNat
  let mut buf := page.rgba
  -- Keep the shelf geometry fixed; untouched trailing rows sample transparent.
  -- Allocate bands on first write so a snapshot copies only populated rows.
  let rows := min ph (((dy + rg.height + 63) / 64) * 64)
  let needed := rows * pw * 4
  if needed > buf.size then
    let padding := zeroBytes (needed - buf.size)
    buf := padding.copySlice 0 buf buf.size padding.size
  for row in [0:rg.height] do
    let y := dy + row
    if y < ph then
      for col in [0:rg.width] do
        let x := dx + col
        if x < pw then
          let dstIdx := (y * pw + x) * 4
          if dstIdx + 4 ≤ buf.size then
            if rg.isColor then
              let srcIdx := (row * rg.width + col) * 4
              if srcIdx + 4 ≤ rg.pixels.size then
                let b := rg.pixels.get! srcIdx
                let g := rg.pixels.get! (srcIdx + 1)
                let r := rg.pixels.get! (srcIdx + 2)
                let a := rg.pixels.get! (srcIdx + 3)
                buf := buf.set! dstIdx r
                buf := buf.set! (dstIdx + 1) g
                buf := buf.set! (dstIdx + 2) b
                buf := buf.set! (dstIdx + 3) a
            else
              let srcIdx := row * rg.width + col
              if srcIdx < rg.pixels.size then
                let cov := rg.pixels.get! srcIdx
                buf := buf.set! dstIdx 255
                buf := buf.set! (dstIdx + 1) 255
                buf := buf.set! (dstIdx + 2) 255
                buf := buf.set! (dstIdx + 3) cov
  return { page with rgba := buf }

end AtlasPageBuffer

structure ShapeCacheEntry where
  fontId : Nat
  size64 : UInt32
  text : String
  features : String
  glyphs : Array ShapedGlyph

/-- Maximum single-dimension pixel extent of any vector-icon / diagram-lane raster (fits one
1024×1024 GPU atlas page with `pad = 1` on both axes). -/
def maxIconRasterDim : Nat := 1022

/-- Bound a vector-icon or lane raster `(w, h)` to fit inside a single atlas page with `1 ≤ h ≤ w ≤ maxIconRasterDim`. -/
@[inline] def boundIconRasterSize (w h : Nat) : Nat × Nat :=
  let bw := min maxIconRasterDim (max 1 w)
  let bh := min bw (max 1 (if h == 0 then bw else h))
  (bw, bh)

/-- Supersampled round-cap/round-join SVG strokes, shared by desktop chrome icons.
The source view box is 16px; path coordinates are tenths of a logical pixel.
`strokeTenths` is the stroke radius in tenths of a view unit (55 → the historical
5.5-unit radius); edge routing and decision outlines pass a thinner radius so their
rendered stroke matches the 2px widget border weight instead of stretching with the raster.
`rasterHeight` bounds vertical rasterisation to the widget's actual visible height while
keeping the 160-unit view box scaled by `size` (1:1 aspect ratio). -/
def rasterizeIconReference (paths : List (List (Int × Int))) (size : Nat)
    (strokeTenths : Nat := 55) (rasterHeight : Nat := size) : RasterizedGlyph := Id.run do
  let h := min size rasterHeight
  if size == 0 || h == 0 then
    return { width := size, height := h, bearingX := 0, bearingY := 0,
             format := 1, isColor := false, pixels := ByteArray.empty }
  let radius := strokeTenths.toFloat / 10
  let r2 := radius * radius
  let cull := radius + 0.5
  let segments := (paths.flatMap fun ps => ps.zip (ps.drop 1)).map fun ((ax, ay), (bx, by_)) =>
    let dx := (bx - ax).toFloat
    let dy := (by_ - ay).toFloat
    (ax.toFloat, ay.toFloat, dx, dy, dx * dx + dy * dy,
      (min ay by_).toFloat - cull, (max ay by_).toFloat + cull,
      (min ax bx).toFloat - cull, (max ax bx).toFloat + cull)
  let zeroRow := AtlasPageBuffer.zeroBytes size
  let mut pixels := ByteArray.emptyWithCapacity (size * h)
  for y in [0:h] do
    -- Exclude segments outside this scanline's expanded interval before running
    -- the 16 sample tests.
    let lo := y.toFloat * 160 / size.toFloat
    let hi := (y + 1).toFloat * 160 / size.toFloat
    let active := segments.filter fun (_, _, _, _, _, ymin, ymax, _, _) => ymin ≤ hi && ymax ≥ lo
    if active.isEmpty then
      pixels := pixels ++ zeroRow
    else
      for x in [0:size] do
        let xlo := x.toFloat * 160 / size.toFloat
        let xhi := (x + 1).toFloat * 160 / size.toFloat
        let activeX := active.filter fun (_, _, _, _, _, _, _, xmin, xmax) => xmin ≤ xhi && xmax ≥ xlo
        if activeX.isEmpty then
          pixels := pixels.push 0
        else
          let mut coverage := 0
          for sy in [0:4] do
            for sx in [0:4] do
              let px := (x.toFloat + (sx.toFloat + 0.5) / 4) * 160 / size.toFloat
              let py := (y.toFloat + (sy.toFloat + 0.5) / 4) * 160 / size.toFloat
              let hit := activeX.any fun (ax, ay, dx, dy, len, _, _, _, _) =>
                let vx := px - ax
                let vy := py - ay
                let t := if len == 0 then 0 else max 0 (min 1 ((vx * dx + vy * dy) / len))
                let ex := vx - t * dx
                let ey := vy - t * dy
                ex * ex + ey * ey <= r2
              if hit then coverage := coverage + 1
          pixels := pixels.push ((coverage * 255 + 8) / 16).toUInt8
  return { width := size, height := h, bearingX := 0, bearingY := 0,
           format := 1, isColor := false, pixels := pixels }

/-- Stroke radius (tenths of a view unit) whose rendered stroke on a raster drawn 1:1
at `strokePx` device px across a `rasterW`-px-wide raster matches the shared 2px
widget border weight. Clamped so thin rasters keep anti-aliasable coverage. -/
def iconStrokeTenthsForPxWidth (rasterW : Nat) : Nat :=
  max 4 ((1600 + rasterW / 2) / max 1 rasterW)

def rasterizeIcon (paths : List (List (Int × Int))) (size : Nat)
    (strokeTenths : Nat := 55) (rasterHeight : Nat := size) : RasterizedGlyph := Id.run do
  let h := min size rasterHeight
  if size == 0 || h == 0 then
    return { width := size, height := h, bearingX := 0, bearingY := 0,
             format := 1, isColor := false, pixels := ByteArray.empty }
  if size > 1024 || h > size || strokeTenths > 10000 then
    return rasterizeIconReference paths size strokeTenths h
  let mut segments := ByteArray.empty
  for path in paths do
    for ((ax, ay), (bx, by_)) in path.zip (path.drop 1) do
      for coord in [ax, ay, bx, by_] do
        if coord < -128 || coord > 255 then
          return rasterizeIconReference paths size strokeTenths h
        -- Store signed coordinates losslessly in two little-endian bytes.
        let biased := (coord + 128).toNat
        segments := segments.push biased.toUInt8 |>.push (biased / 256).toUInt8
  return { width := size, height := h, bearingX := 0, bearingY := 0,
           format := 1, isColor := false,
           pixels := FFI.iconMask segments size.toUSize h.toUSize strokeTenths.toUInt32 }

/-- Maximum UTF-8 byte length eligible for short-label shaping/resolved-run caching.
Longer strings (such as growing streaming replies) bypass caching to prevent thrashing. -/
def maxShapeCacheBytes : Nat := 128

/-- Maximum retained atlas-resolved short-label runs per `GlyphAtlasCache`. -/
def maxResolvedRuns : Nat := 512

/-- O(1) lookup key for `GlyphAtlasCache.resolvedMap` (color/underline applied on hit). -/
structure ResolvedRunKey where
  face : USize
  scale : Nat
  sizeSub : SubPx
  text : String
  deriving BEq, Hashable, Inhabited

/-- Short label with atlas-resolved glyph positions, scoped to the owning atlas. -/
structure ResolvedRun where
  face : USize
  scale : Nat
  text : String
  style : TextStyle
  run : InlineRun

/-- Loaded FreeType + HarfBuzz font handle and its stable `fontId`. -/
structure FontHandle where
  fontId : Nat
  facePtr : USize
  pattern : String
  deriving Repr, Inhabited

/-- Multi-page shelf-packed glyph atlas and bounded font/label caches. -/
structure GlyphAtlasCache where
  pageWidth : Nat := 1024
  pageHeight : Nat := 1024
  pad : Nat := 1
  pages : Array AtlasPageBuffer := #[]
  /-- While building a frame, allocate UVs immediately but commit new bitmaps
  together so an immutable previous frame costs at most one page copy. -/
  pendingUploads : Option (Array (Nat × Rect × RasterizedGlyph)) := none
  /-- Dirty `(pageIdx, rect)` atlas sub-regions pending GPU 2D-array upload. -/
  gpuDirtyRects : Array (Nat × Rect) := #[]
  /-- Monotonic atlas generation incremented on `resetAll` (triggers GPU `vkCmdClearColorImage`). -/
  generation : UInt64 := 0
  cache : HashCache AtlasGlyphEntry := {}
  /-- O(1) index mirroring `cache` so glyph and vector-icon lookups never scan linearly. -/
  cacheMap : Std.HashMap GlyphKey AtlasGlyphEntry := {}
  /-- `true` once every entry in `cache` is known to be indexed in `cacheMap` (set on first
  insert into an empty `cache` and on `resetAll`). When `false` (externally populated `cache`),
  `lookupGlyph` falls back to `cache.lookup` on miss so mixed states never drop keys. -/
  cacheMapSynced : Bool := false
  /-- Shaping results reused across frames; glyph rasterization is cached separately below. -/
  shapeCache : Array ShapeCacheEntry := #[]
  fallbackFonts : Array FontHandle := #[]
  missingCharsets : Array String := #[]
  resolved : Array ResolvedRun := #[]
  resolvedMap : Std.HashMap ResolvedRunKey InlineRun := {}
  hits : Nat := 0
  misses : Nat := 0
  /-- Bounded vector-icon / diagram-lane rasterisation telemetry. -/
  iconRasterHits : Nat := 0
  iconRasterMisses : Nat := 0
  iconRasterPixels : Nat := 0
  maxIconRasterPixels : Nat := 0
  deriving Inhabited

namespace GlyphAtlasCache

/-- O(1) glyph/icon cache lookup via `cacheMap`, with sound fallback to `cache` if `cache` was
populated externally without going through `insertRasterized`. -/
@[inline] def lookupGlyph (ac : GlyphAtlasCache) (key : GlyphKey) : Option AtlasGlyphEntry :=
  match ac.cacheMap.get? key with
  | some entry => some entry
  | none =>
    if ac.cache.entries.isEmpty || ac.cacheMapSynced then none
    else ac.cache.lookup hashGlyphKey key

def beginUploads (ac : GlyphAtlasCache) : GlyphAtlasCache :=
  { ac with pendingUploads := some (ac.pendingUploads.getD #[]) }

def finishUploads (ac : GlyphAtlasCache) : GlyphAtlasCache := Id.run do
  let some uploads := ac.pendingUploads | return ac
  let mut pages := ac.pages
  let mut gpuDirty := ac.gpuDirtyRects
  if !uploads.isEmpty then
    pages := pages.mapIdx fun idx page => Id.run do
      let mut out := page
      for (p, rect, glyph) in uploads do
        if p == idx then out := out.blitGlyph rect glyph
      return out
    for (p, rect, _) in uploads do
      gpuDirty := gpuDirty.push (p, rect)
  return { ac with pages, pendingUploads := none, gpuDirtyRects := gpuDirty }

/-- Clear GPU-pending dirty atlas sub-regions after uploading them to the GPU 2D-array atlas. -/
def clearGpuDirtyRects (ac : GlyphAtlasCache) : GlyphAtlasCache :=
  { ac with gpuDirtyRects := #[] }

/-- Reset all atlas pages (`Atlas.reset`) and clear the `HashCache` and O(1) index. -/
def resetAll (ac : GlyphAtlasCache) : GlyphAtlasCache :=
  let pages' := ac.pages.map fun p =>
    { atlas := p.atlas.reset
      rgba := ByteArray.empty }
  { ac with
    pages := pages'
    cache := {}
    cacheMap := {}
    cacheMapSynced := true
    resolved := #[]
    resolvedMap := {}
    pendingUploads := none
    gpuDirtyRects := #[]
    generation := ac.generation + 1 }

/-- Allocate a padded slot `(w, h)` across pages using `Atlas.allocPadded` / `Atlas.allocPages`
and blit the rasterized bitmap into the chosen page. -/
def insertRasterized (ac : GlyphAtlasCache) (key : GlyphKey) (rg : RasterizedGlyph) :
    GlyphAtlasCache × AtlasGlyphEntry := Id.run do
  let synced := ac.cacheMapSynced || ac.cache.entries.isEmpty
  if rg.width == 0 || rg.height == 0 then
    let entry : AtlasGlyphEntry :=
      { page := 0, uv := { x := 0, y := 0, w := 0, h := 0 },
        bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
    let cache' := ac.cache.insert hashGlyphKey key entry
    let cacheMap' := ac.cacheMap.insert key entry
    return ({ ac with cache := cache', cacheMap := cacheMap', cacheMapSynced := synced, misses := ac.misses + 1 }, entry)
  -- Try existing pages with `Atlas.allocPadded` first
  for idx in [0:ac.pages.size] do
    let p := ac.pages[idx]!
    if let some (rect, atlas') := p.atlas.allocPadded ac.pad rg.width rg.height then
      -- Modify the element in place when the atlas is uniquely owned. Holding
      -- the old page during blit forces a 4 MiB copy for each new glyph.
      let pages' := ac.pages.modify idx fun page =>
        let updated := { page with atlas := atlas' }
        if ac.pendingUploads.isSome then updated else updated.blitGlyph rect rg
      let entry : AtlasGlyphEntry :=
        { page := idx, uv := rect, bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
      let cache' := ac.cache.insert hashGlyphKey key entry
      let cacheMap' := ac.cacheMap.insert key entry
      let gpuDirty' := if ac.pendingUploads.isSome then ac.gpuDirtyRects else ac.gpuDirtyRects.push (idx, rect)
      return ({ ac with pages := pages', cache := cache', cacheMap := cacheMap', cacheMapSynced := synced, misses := ac.misses + 1,
                        pendingUploads := ac.pendingUploads.map (·.push (idx, rect, rg)),
                        gpuDirtyRects := gpuDirty' }, entry)
  -- Otherwise allocate a new page via `Atlas.allocPages` / `Atlas.allocPadded`
  let pw := max ac.pageWidth (rg.width + ac.pad)
  let ph := max ac.pageHeight (rg.height + ac.pad)
  let fresh := AtlasPageBuffer.create pw ph
  let pageIdx := ac.pages.size
  match fresh.atlas.allocPadded ac.pad rg.width rg.height with
  | some (rect, atlas') =>
    let allocated := { fresh with atlas := atlas' }
    let fresh' := if ac.pendingUploads.isSome then allocated else allocated.blitGlyph rect rg
    let pages' := ac.pages.push fresh'
    let entry : AtlasGlyphEntry :=
      { page := pageIdx, uv := rect, bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
    let cache' := ac.cache.insert hashGlyphKey key entry
    let cacheMap' := ac.cacheMap.insert key entry
    let gpuDirty' := if ac.pendingUploads.isSome then ac.gpuDirtyRects else ac.gpuDirtyRects.push (pageIdx, rect)
    return ({ ac with pages := pages', cache := cache', cacheMap := cacheMap', cacheMapSynced := synced, misses := ac.misses + 1,
                      pendingUploads := ac.pendingUploads.map (·.push (pageIdx, rect, rg)),
                      gpuDirtyRects := gpuDirty' }, entry)
  | none =>
    -- Also exercise `Atlas.allocPages` fallback
    let atlases := (ac.pages.map (·.atlas)).toList
    let _ := Atlas.allocPages pw ph (rg.width + ac.pad) (rg.height + ac.pad) atlases
    let entry : AtlasGlyphEntry :=
      { page := 0, uv := { x := 0, y := 0, w := rg.width, h := rg.height },
        bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
    return ({ ac with misses := ac.misses + 1 }, entry)

/-- Look up or rasterize a bounded vector icon / Mermaid routing lane (`w × h`) into the shared
atlas with O(1) cache lookup, capping raster extents to `maxIconRasterDim` and bounding vertical
rasterisation to the visible widget height `h`. -/
def getOrRasterizeIcon (ac : GlyphAtlasCache) (paths : List (List (Int × Int)))
    (w h : Nat) (strokeTenths : Nat := 55) : GlyphAtlasCache × AtlasGlyphEntry :=
  if w == 0 then
    let key : GlyphKey :=
      { font := 0xFFFF, glyph := (mixHash (hash paths) (hash strokeTenths)).toNat,
        sizeSub := 0, subpx := 0 }
    match ac.lookupGlyph key with
    | some entry => ({ ac with hits := ac.hits + 1, iconRasterHits := ac.iconRasterHits + 1 }, entry)
    | none =>
      let (ac', entry) := ac.insertRasterized key (rasterizeIcon paths 0 strokeTenths 0)
      ({ ac' with iconRasterMisses := ac'.iconRasterMisses + 1 }, entry)
  else
    let (bw, bh) := boundIconRasterSize w h
    let key : GlyphKey :=
      { font := 0xFFFF,
        glyph := (mixHash (hash paths) (mixHash (hash strokeTenths) (hash bh))).toNat,
        sizeSub := bw, subpx := 0 }
    match ac.lookupGlyph key with
    | some entry => ({ ac with hits := ac.hits + 1, iconRasterHits := ac.iconRasterHits + 1 }, entry)
    | none =>
      let rg := rasterizeIcon paths bw strokeTenths bh
      let px := rg.width * rg.height
      let (ac', entry) := ac.insertRasterized key rg
      ({ ac' with
        iconRasterMisses := ac'.iconRasterMisses + 1
        iconRasterPixels := ac'.iconRasterPixels + px
        maxIconRasterPixels := max ac'.maxIconRasterPixels px }, entry)

end GlyphAtlasCache

/-- Open a font face via Fontconfig (`FFI.fontOpen`). -/
def openFont (fontId : Nat) (pattern : String := "sans-serif") : IO FontHandle := do
  let ptr ← FFI.fontOpen pattern
  return { fontId, facePtr := ptr, pattern }

/-- Close a font face via `FFI.fontClose`. -/
def closeFont (f : FontHandle) : IO Unit :=
  if f.facePtr != 0 then FFI.fontClose f.facePtr else pure ()

/-- Query scaled 26.6 (`1/64` px) font metrics for `f` at `size64`. -/
def getFontMetrics (f : FontHandle) (size64 : UInt32) : IO FontMetrics := do
  let raw ← FFI.fontMetrics f.facePtr size64
  return decodeFontMetrics raw

/-- Shape UTF-8 `text` with `f` at `size64` (26.6 fractional px) and HarfBuzz `features`. -/
def shapeText (f : FontHandle) (size64 : UInt32) (text : String) (features : String := "") :
    IO (Array ShapedGlyph) := do
  if text.isEmpty then return #[]
  let raw ← FFI.shape f.facePtr size64 text features
  return decodeShapedGlyphs raw

/-- Shape text with a small atlas-owned cache. The key includes the font, size, text, and shaping
features, so unchanged chrome is not sent through HarfBuzz on every display tick. -/
def shapeTextCached (ac : GlyphAtlasCache) (f : FontHandle) (size64 : UInt32) (text : String)
    (features : String := "") : IO (GlyphAtlasCache × Array ShapedGlyph) := do
  -- Bound retained bytes as well as entry count. Growing replies are shaped
  -- once per new prefix; keeping those prefixes evicts reusable labels.
  if text.utf8ByteSize > maxShapeCacheBytes then return (ac, ← shapeText f size64 text features)
  match ac.shapeCache.find? (fun cached =>
      cached.fontId == f.fontId && cached.size64 == size64 && cached.text == text && cached.features == features) with
  | some cached =>
    return (ac, cached.glyphs)
  | none =>
    let shaped ← shapeText f size64 text features
    let next := ac.shapeCache.push { fontId := f.fontId, size64, text, features, glyphs := shaped }
    let bounded := if next.size > 64 then next.extract (next.size - 64) next.size else next
    return ({ ac with shapeCache := bounded }, shaped)

/-- Resolve missing HarfBuzz clusters against installed fonts without changing the
shaping of adjacent glyphs. Cluster offsets remain relative to the original string. -/
def shapeWithFallback (ac : GlyphAtlasCache) (primary : FontHandle) (size64 : UInt32)
    (text : String) (features : String := "") :
    IO (GlyphAtlasCache × Array (FontHandle × ShapedGlyph)) := do
  let (initial, shaped) ← shapeTextCached ac primary size64 text features
  if !shaped.any (·.glyphId == 0) then return (initial, shaped.map (primary, ·))
  let bytes := text.toUTF8
  let mut state := initial
  let mut out := #[]
  let mut i := 0
  while i < shaped.size do
    let start := shaped[i]!.cluster
    let mut j := i + 1
    while j < shaped.size && shaped[j]!.cluster == start do j := j + 1
    let group := shaped.extract i j
    let mut face := primary
    let mut glyphs := group
    if group.any (·.glyphId == 0) then
      -- HarfBuzz clusters are monotone in either direction.
      let stop := if j < shaped.size && shaped[j]!.cluster > start then shaped[j]!.cluster.toNat
        else if i > 0 && shaped[i-1]!.cluster > start then shaped[i-1]!.cluster.toNat else bytes.size
      if let some piece := String.fromUTF8? (bytes.extract start.toNat stop) then
        let charset := String.intercalate " " (piece.toList.map fun c => String.ofList (Nat.toDigits 16 c.toNat))
        let pattern := "sans-serif:charset=" ++ charset
        let choices := state.fallbackFonts
        for candidate in choices do
          let (next, trial) ← shapeTextCached state candidate size64 piece features
          state := next
          if !trial.isEmpty && trial.all (·.glyphId != 0) then
            face := candidate
            glyphs := trial.map fun g => { g with cluster := start }
            break
        if face.facePtr == primary.facePtr && choices.size < 16 && !state.missingCharsets.contains pattern then
          if let .ok candidate ← (openFont (16 + choices.size) pattern).toBaseIO then
            let trial ← shapeText candidate size64 piece features
            if !trial.isEmpty && trial.all (·.glyphId != 0) then
              state := { state with fallbackFonts := choices.push candidate }
              face := candidate
              glyphs := trial.map fun g => { g with cluster := start }
            else
              closeFont candidate
              let missing := state.missingCharsets.push pattern
              state := { state with missingCharsets := missing.extract (missing.size - 64) missing.size }
    out := out ++ glyphs.map (face, ·)
    i := j
  return (state, out)

/-- Rasterize a single glyph at `(size64, subpx)` or return it from `GlyphAtlasCache` on hit. -/
def getOrRasterizeGlyph (ac : GlyphAtlasCache) (f : FontHandle) (glyphId : UInt32)
    (size64 : UInt32) (subpx : UInt32) : IO (GlyphAtlasCache × AtlasGlyphEntry) := do
  let bin := (subpx &&& 3).toNat
  let key : GlyphKey :=
    { font := f.fontId, glyph := glyphId.toNat, sizeSub := size64.toNat, subpx := bin }
  if let some entry := ac.lookupGlyph key then
    return ({ ac with hits := ac.hits + 1 }, entry)
  let raw ← FFI.rasterize f.facePtr size64 glyphId (subpx &&& 3)
  let rg := decodeRasterizedGlyph raw
  return ac.insertRasterized key rg

/-- Shape and layout a single-line UTF-8 text run at logical `Sub` origin `(xSub, ySub)` and
device scale `scale120`, emitting `Prim.glyph` primitives in device pixels. -/
def layoutTextRun (ac : GlyphAtlasCache) (f : FontHandle) (sizeSub : Nat) (scale120 : Nat)
    (xSub ySub : Int) (color : Color) (text : String) (features : String := "") :
    IO (GlyphAtlasCache × Int × Array Prim) := do
  let devSize64 : UInt32 := ((sizeSub * scale120 + scaleDen / 2) / scaleDen).toUInt32
  let (initial, shaped) ← shapeWithFallback ac f devSize64 text features
  let mut curAc := initial
  let mut penDev64 : Int := (xSub * (scale120 : Int)) / (scaleDen : Int)
  let baseDevPx : Int := roundDev scale120 ySub
  let mut prims : Array Prim := #[]
  for (face, sg) in shaped do
    let gx64 := penDev64 + sg.xOffset64
    let gy64 := sg.yOffset64
    let wholeX : Int := gx64 / 64
    let remX : Int := gx64 % 64
    let subpxBin : UInt32 := ((if remX < 0 then remX + 64 else remX).toNat / 16).toUInt32
    let (ac', entry) ← getOrRasterizeGlyph curAc face sg.glyphId devSize64 subpxBin
    curAc := ac'
    if entry.uv.w > 0 && entry.uv.h > 0 then
      let dst : Rect :=
        { x := wholeX + entry.bearingX
          y := baseDevPx - entry.bearingY - (gy64 / 64)
          w := entry.uv.w
          h := entry.uv.h }
      let prim : Prim :=
        .glyph entry.uv dst color entry.isColor entry.page
      prims := prims.push prim
    penDev64 := penDev64 + sg.xAdvance64
  let advSub : Int := (penDev64 * (scaleDen : Int)) / (if scale120 == 0 then 120 else (scale120 : Int)) - xSub
  return (curAc, advSub, prims)

end LeanUI.Text
