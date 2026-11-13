import LeanUI.Defs
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

/-- Deterministic 64-bit mixing hash for `GlyphKey` used with `Kernel.HashCache`. -/
@[inline] def hashGlyphKey (k : GlyphKey) : UInt64 :=
  let h0 : UInt64 := 0x9e3779b97f4a7c15
  let h1 := (h0 ^^^ k.font.toUInt64) * 0xbf58476d1ce4e5b9
  let h2 := (h1 ^^^ k.glyph.toUInt64) * 0x94d049bb133111eb
  let h3 := (h2 ^^^ k.sizeSub.toUInt64) * 0xbf58476d1ce4e5b9
  let h4 := (h3 ^^^ (k.subpx &&& 3).toUInt64) * 0x94d049bb133111eb
  h4 ^^^ (h4 >>> 31)

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

/-- Create an empty zero-initialized `pw × ph` RGBA8 atlas page. -/
def create (pw ph : Nat) : AtlasPageBuffer :=
  { atlas := { width := pw, height := ph, shelves := [], nextY := 0 }
    rgba := ByteArray.mk (Array.replicate (pw * ph * 4) 0) }

/-- Blit a `RasterizedGlyph` into `dstRect` on this page.
R8 glyphs are stored with `(255, 255, 255, cov)` and BGRA8 glyphs are swizzled to RGBA8. -/
def blitGlyph (page : AtlasPageBuffer) (dstRect : Rect) (rg : RasterizedGlyph) : AtlasPageBuffer := Id.run do
  let pw := page.atlas.width
  let ph := page.atlas.height
  let dx := dstRect.x.toNat
  let dy := dstRect.y.toNat
  let mut buf := page.rgba
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

/-- Multi-page shelf-packed glyph atlas + `HashCache AtlasGlyphEntry` with hit/miss counters. -/
structure GlyphAtlasCache where
  pageWidth : Nat := 1024
  pageHeight : Nat := 1024
  pad : Nat := 1
  pages : Array AtlasPageBuffer := #[]
  cache : HashCache AtlasGlyphEntry := {}
  hits : Nat := 0
  misses : Nat := 0
  deriving Inhabited

namespace GlyphAtlasCache

/-- Reset all atlas pages (`Atlas.reset`) and clear the `HashCache`. -/
def resetAll (ac : GlyphAtlasCache) : GlyphAtlasCache :=
  let pages' := ac.pages.map fun p =>
    { atlas := p.atlas.reset
      rgba := ByteArray.mk (Array.replicate (p.atlas.width * p.atlas.height * 4) 0) }
  { ac with pages := pages', cache := {} }

/-- Allocate a padded slot `(w, h)` across pages using `Atlas.allocPadded` / `Atlas.allocPages`
and blit the rasterized bitmap into the chosen page. -/
def insertRasterized (ac : GlyphAtlasCache) (key : GlyphKey) (rg : RasterizedGlyph) :
    GlyphAtlasCache × AtlasGlyphEntry := Id.run do
  if rg.width == 0 || rg.height == 0 then
    let entry : AtlasGlyphEntry :=
      { page := 0, uv := { x := 0, y := 0, w := 0, h := 0 },
        bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
    let cache' := ac.cache.insert hashGlyphKey key entry
    return ({ ac with cache := cache', misses := ac.misses + 1 }, entry)
  -- Try existing pages with `Atlas.allocPadded` first
  for idx in [0:ac.pages.size] do
    let p := ac.pages[idx]!
    if let some (rect, atlas') := p.atlas.allocPadded ac.pad rg.width rg.height then
      let p' := ({ p with atlas := atlas' }).blitGlyph rect rg
      let pages' := ac.pages.set! idx p'
      let entry : AtlasGlyphEntry :=
        { page := idx, uv := rect, bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
      let cache' := ac.cache.insert hashGlyphKey key entry
      return ({ ac with pages := pages', cache := cache', misses := ac.misses + 1 }, entry)
  -- Otherwise allocate a new page via `Atlas.allocPages` / `Atlas.allocPadded`
  let pw := max ac.pageWidth (rg.width + ac.pad)
  let ph := max ac.pageHeight (rg.height + ac.pad)
  let fresh := AtlasPageBuffer.create pw ph
  let pageIdx := ac.pages.size
  match fresh.atlas.allocPadded ac.pad rg.width rg.height with
  | some (rect, atlas') =>
    let fresh' := ({ fresh with atlas := atlas' }).blitGlyph rect rg
    let pages' := ac.pages.push fresh'
    let entry : AtlasGlyphEntry :=
      { page := pageIdx, uv := rect, bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
    let cache' := ac.cache.insert hashGlyphKey key entry
    return ({ ac with pages := pages', cache := cache', misses := ac.misses + 1 }, entry)
  | none =>
    -- Also exercise `Atlas.allocPages` fallback
    let atlases := (ac.pages.map (·.atlas)).toList
    let _ := Atlas.allocPages pw ph (rg.width + ac.pad) (rg.height + ac.pad) atlases
    let entry : AtlasGlyphEntry :=
      { page := 0, uv := { x := 0, y := 0, w := rg.width, h := rg.height },
        bearingX := rg.bearingX, bearingY := rg.bearingY, isColor := rg.isColor }
    return ({ ac with misses := ac.misses + 1 }, entry)

end GlyphAtlasCache

/-- Loaded FreeType + HarfBuzz font handle and its stable `fontId`. -/
structure FontHandle where
  fontId : Nat
  facePtr : USize
  pattern : String
  deriving Repr, Inhabited

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

/-- Rasterize a single glyph at `(size64, subpx)` or return it from `GlyphAtlasCache` on hit. -/
def getOrRasterizeGlyph (ac : GlyphAtlasCache) (f : FontHandle) (glyphId : UInt32)
    (size64 : UInt32) (subpx : UInt32) : IO (GlyphAtlasCache × AtlasGlyphEntry) := do
  let bin := (subpx &&& 3).toNat
  let key : GlyphKey :=
    { font := f.fontId, glyph := glyphId.toNat, sizeSub := size64.toNat, subpx := bin }
  if let some entry := ac.cache.lookup hashGlyphKey key then
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
  let shaped ← shapeText f devSize64 text features
  let mut curAc := ac
  let mut penDev64 : Int := (xSub * (scale120 : Int)) / (scaleDen : Int)
  let baseDevPx : Int := roundDev scale120 ySub
  let mut prims : Array Prim := #[]
  for sg in shaped do
    let gx64 := penDev64 + sg.xOffset64
    let gy64 := sg.yOffset64
    let wholeX : Int := gx64 / 64
    let remX : Int := gx64 % 64
    let subpxBin : UInt32 := ((if remX < 0 then remX + 64 else remX).toNat / 16).toUInt32
    let (ac', entry) ← getOrRasterizeGlyph curAc f sg.glyphId devSize64 subpxBin
    curAc := ac'
    if entry.uv.w > 0 && entry.uv.h > 0 then
      let dst : Rect :=
        { x := wholeX + entry.bearingX
          y := baseDevPx - entry.bearingY - (gy64 / 64)
          w := entry.uv.w
          h := entry.uv.h }
      let prim : Prim :=
        if entry.page > 0 && !entry.isColor then
          .mask entry.page entry.uv dst color
        else
          .glyph entry.uv dst color entry.isColor
      prims := prims.push prim
    penDev64 := penDev64 + sg.xAdvance64
  let advSub : Int := (penDev64 * (scaleDen : Int)) / (if scale120 == 0 then 120 else (scale120 : Int)) - xSub
  return (curAc, advSub, prims)

end LeanUI.Text
