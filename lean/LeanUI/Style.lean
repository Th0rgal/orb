import LeanUI.Defs
import LeanUI.Kernel
/-!
# LeanUI.Style — declarative style, theme, and palette tokens (`0` FFI)
-/
namespace LeanUI

/-- Logical coordinate or dimension in 1/64 logical pixel (`subPerPx = 64`). -/
abbrev SubPx := Nat

/-- Convert whole logical pixels to `SubPx` (`1/64` px units). -/
@[inline] def pxToSub (px : Nat) : SubPx := px * subPerPx

/-- Scale a `SubPx` length by Wayland fractional `scale120` into device pixels (rounded to nearest). -/
@[inline] def scaleSubPx (scale120 : Nat) (v : SubPx) : Nat :=
  (roundDev scale120 (Int.ofNat v)).toNat

/-- Four-sided edge insets (top, right, bottom, left) in `SubPx`. -/
structure Edges where
  top : SubPx := 0
  right : SubPx := 0
  bottom : SubPx := 0
  left : SubPx := 0
  deriving DecidableEq, Repr, Inhabited

namespace Edges

@[inline] def zero : Edges := {}

@[inline] def all (v : SubPx) : Edges :=
  { top := v, right := v, bottom := v, left := v }

@[inline] def xy (x y : SubPx) : Edges :=
  { top := y, right := x, bottom := y, left := x }

@[inline] def trbl (t r b l : SubPx) : Edges :=
  { top := t, right := r, bottom := b, left := l }

@[inline] def horizontal (e : Edges) : SubPx := e.left + e.right

@[inline] def vertical (e : Edges) : SubPx := e.top + e.bottom

@[inline] def mainSum (axis : Axis) (e : Edges) : SubPx :=
  match axis with
  | .row => e.horizontal
  | .column => e.vertical

@[inline] def crossSum (axis : Axis) (e : Edges) : SubPx :=
  match axis with
  | .row => e.vertical
  | .column => e.horizontal

@[inline] def mainStart (axis : Axis) (e : Edges) : SubPx :=
  match axis with
  | .row => e.left
  | .column => e.top

@[inline] def crossStart (axis : Axis) (e : Edges) : SubPx :=
  match axis with
  | .row => e.top
  | .column => e.left

end Edges

/-- Per-corner radii (top-left, top-right, bottom-right, bottom-left) in `SubPx`. -/
structure CornerRadii where
  topLeft : SubPx := 0
  topRight : SubPx := 0
  bottomRight : SubPx := 0
  bottomLeft : SubPx := 0
  deriving DecidableEq, Repr, Inhabited

namespace CornerRadii

@[inline] def zero : CornerRadii := {}

@[inline] def uniform (r : SubPx) : CornerRadii :=
  { topLeft := r, topRight := r, bottomRight := r, bottomLeft := r }

@[inline] def isZero (c : CornerRadii) : Bool :=
  c.topLeft == 0 && c.topRight == 0 && c.bottomRight == 0 && c.bottomLeft == 0

@[inline] def isUniform (c : CornerRadii) : Bool :=
  c.topLeft == c.topRight && c.topRight == c.bottomRight && c.bottomRight == c.bottomLeft

@[inline] def toDevTuple (scale120 : Nat) (c : CornerRadii) : Nat × Nat × Nat × Nat :=
  (scaleSubPx scale120 c.topLeft,
   scaleSubPx scale120 c.topRight,
   scaleSubPx scale120 c.bottomRight,
   scaleSubPx scale120 c.bottomLeft)

end CornerRadii

/-- Per-side border widths and stroke color. -/
structure BorderStyle where
  widths : Edges := {}
  color : Color := 0x00000000
  deriving DecidableEq, Repr, Inhabited

namespace BorderStyle

@[inline] def none : BorderStyle := {}

@[inline] def uniform (width : SubPx) (color : Color) : BorderStyle :=
  { widths := Edges.all width, color := color }

@[inline] def isVisible (b : BorderStyle) : Bool :=
  (b.widths.top > 0 || b.widths.right > 0 || b.widths.bottom > 0 || b.widths.left > 0) &&
    (b.color &&& 0x000000FF) != 0

@[inline] def isUniform (b : BorderStyle) : Bool :=
  b.widths.top == b.widths.right &&
    b.widths.right == b.widths.bottom &&
    b.widths.bottom == b.widths.left

@[inline] def toDevTuple (scale120 : Nat) (b : BorderStyle) : Nat × Nat × Nat × Nat :=
  (scaleSubPx scale120 b.widths.top,
   scaleSubPx scale120 b.widths.right,
   scaleSubPx scale120 b.widths.bottom,
   scaleSubPx scale120 b.widths.left)

end BorderStyle

/-- SDF drop shadow configuration in `SubPx`. -/
structure ShadowStyle where
  offsetX : Int := 0
  offsetY : Int := 0
  blur : SubPx := 0
  spread : Int := 0
  color : Color := 0x00000000
  deriving DecidableEq, Repr, Inhabited

namespace ShadowStyle

@[inline] def none : ShadowStyle := {}

@[inline] def isVisible (s : ShadowStyle) : Bool :=
  (s.color &&& 0x000000FF) != 0 && (s.blur > 0 || s.spread != 0 || s.offsetX != 0 || s.offsetY != 0)

end ShadowStyle

/-- Main-axis justification modes for Flexbox containers. -/
inductive Justify where
  | start
  | center
  | end_
  | spaceBetween
  deriving DecidableEq, Repr, Inhabited

/-! ## Cross-axis alignment and axis helpers -/

namespace Align

/-- Alias for `Align.«end»`. -/
@[inline] def end_ : Align := Align.«end»

end Align

namespace Axis

/-- Alias for `Axis.column`. -/
@[inline] def col : Axis := Axis.column

end Axis

/-- Typography style (sizes and metrics in `SubPx` `1/64` px units). -/
structure TextStyle where
  fontId : Nat := 0
  sizeSub : SubPx := 14 * subPerPx
  lineHeightSub : SubPx := 20 * subPerPx
  weight : Nat := 400
  color : Color := 0xECEFF4FF
  monospace : Bool := false
  italic : Bool := false
  underline : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Declarative box layout & paint style. -/
structure BoxStyle where
  axis : Axis := .row
  align : Align := .start
  justify : Justify := .start
  padding : Edges := {}
  margin : Edges := {}
  gap : SubPx := 0
  basis : SubPx := 0
  grow : Nat := 0
  shrink : Nat := 1
  minWidth : SubPx := 0
  maxWidth : SubPx := 1048576 * subPerPx
  minHeight : SubPx := 0
  maxHeight : SubPx := 1048576 * subPerPx
  background : Color := 0x00000000
  radii : CornerRadii := {}
  border : BorderStyle := {}
  shadow : ShadowStyle := {}
  opacity : Nat := 255
  clip : Bool := false
  clipRounded : Bool := false
  deriving DecidableEq, Repr, Inhabited

namespace BoxStyle

@[inline] def row (gap : SubPx := 0) : BoxStyle :=
  { axis := .row, gap := gap }

@[inline] def col (gap : SubPx := 0) : BoxStyle :=
  { axis := .column, gap := gap }

@[inline] def withPadding (s : BoxStyle) (p : Edges) : BoxStyle :=
  { s with padding := p }

@[inline] def withMargin (s : BoxStyle) (m : Edges) : BoxStyle :=
  { s with margin := m }

@[inline] def withAlign (s : BoxStyle) (a : Align) : BoxStyle :=
  { s with align := a }

@[inline] def withJustify (s : BoxStyle) (j : Justify) : BoxStyle :=
  { s with justify := j }

@[inline] def withFlex (s : BoxStyle) (basis : SubPx) (grow : Nat := 0) (shrink : Nat := 1) : BoxStyle :=
  { s with basis := basis, grow := grow, shrink := shrink }

@[inline] def withFixedSize (s : BoxStyle) (w h : SubPx) : BoxStyle :=
  { s with minWidth := w, maxWidth := w, minHeight := h, maxHeight := h, basis := w, grow := 0, shrink := 0 }

@[inline] def withBg (s : BoxStyle) (c : Color) : BoxStyle :=
  { s with background := c }

@[inline] def withRadius (s : BoxStyle) (r : SubPx) : BoxStyle :=
  { s with radii := CornerRadii.uniform r }

@[inline] def withBorder (s : BoxStyle) (width : SubPx) (c : Color) : BoxStyle :=
  { s with border := BorderStyle.uniform width c }

@[inline] def withShadow (s : BoxStyle) (sh : ShadowStyle) : BoxStyle :=
  { s with shadow := sh }

end BoxStyle

/-- Complete semantic color palette (`0xRRGGBBAA`) for Orb Desktop parity. -/
structure Palette where
  canvas : Color
  surface : Color
  elevatedSurface : Color
  sidebar : Color
  header : Color
  border : Color
  borderSubtle : Color
  focusRing : Color
  textPrimary : Color
  textSecondary : Color
  textMuted : Color
  accent : Color
  accentMuted : Color
  codeBg : Color
  diffAddBg : Color
  diffAddText : Color
  diffDelBg : Color
  diffDelText : Color
  diffHunkBg : Color
  diffHunkText : Color
  danger : Color
  warning : Color
  success : Color
  shadowColor : Color
  /-- Selected sidebar row: `--bg-active` of `.sidebar` composited over `sidebar`. -/
  rowActive : Color
  /-- `--fg-strong`: label of the selected row. -/
  textStrong : Color
  /-- `--fg-4`: shortcut hints. -/
  textFaint : Color
  /-- `--stroke-strong`: composer border while it has focus. -/
  borderStrong : Color
  /-- `--plus-bg`, `--send-bg`, `--send-fg`: the round composer buttons. -/
  plusBg : Color
  sendBg : Color
  sendFg : Color
  deriving DecidableEq, Repr, Inhabited

/-- Typography scale in `SubPx` (`1/64` logical pixel units). -/
structure TypographyScale where
  xs : SubPx := 11 * subPerPx
  sm : SubPx := 12 * subPerPx
  base : SubPx := 14 * subPerPx
  md : SubPx := 15 * subPerPx
  lg : SubPx := 18 * subPerPx
  xl : SubPx := 22 * subPerPx
  xxl : SubPx := 28 * subPerPx
  lineTight : SubPx := 16 * subPerPx
  lineBase : SubPx := 20 * subPerPx
  lineRelaxed : SubPx := 24 * subPerPx
  lineHeading : SubPx := 32 * subPerPx
  fontSans : Nat := 0
  fontMono : Nat := 1
  deriving DecidableEq, Repr, Inhabited

/-- Complete UI theme combining semantic palette, typography scale, and standard radii/borders. -/
structure Theme where
  isDark : Bool
  palette : Palette
  typo : TypographyScale := {}
  radiusSm : SubPx := 4 * subPerPx
  radiusMd : SubPx := 6 * subPerPx
  radiusLg : SubPx := 10 * subPerPx
  borderWidth : SubPx := 1 * subPerPx
  deriving DecidableEq, Repr, Inhabited

/-- Orb Dark palette (`0xRRGGBBAA`): the dark design tokens of `orb/src/styles.css`, with the
translucent sidebar and main surfaces composited over the dark canvas. Checked by
`scripts/test_leanui_tokens.py`. -/
def orbDarkPalette : Palette := {
  canvas          := 0x141414FF
  surface         := 0x1C1C1CFF
  elevatedSurface := 0x212121FF
  sidebar         := 0x121313FF
  header          := 0x141414FF
  border          := 0x2F2F2FFF
  borderSubtle    := 0x2C2C2CFF
  focusRing       := 0x5B5B5BFF
  textPrimary     := 0xD8D8D7FF
  textSecondary   := 0xB1B1B1FF
  textMuted       := 0x8A8A8AFF
  accent          := 0x86AEE4FF
  accentMuted     := 0x86AEE433
  codeBg          := 0x282828FF
  diffAddBg       := 0x2DA44E21
  diffAddText     := 0x2DA44EFF
  diffDelBg       := 0xEF7F8B21
  diffDelText     := 0xEF7F8BFF
  diffHunkBg      := 0x2F2F2F59
  diffHunkText    := 0xD8D8D7FF
  danger          := 0xEF7F8BFF
  warning         := 0xD9B23AFF
  success         := 0x80B28DFF
  shadowColor     := 0x0000007F
  rowActive       := 0x202121FF
  textStrong      := 0xE6E6E5FF
  textFaint       := 0x5C5C5CFF
  borderStrong    := 0x3A3A3AFF
  plusBg          := 0x2C2C2CFF
  sendBg          := 0xD8D8D7FF
  sendFg          := 0x191919FF
}

/-- Orb Light palette (`0xRRGGBBAA`): the light design tokens of `orb/src/styles.css`. -/
def orbLightPalette : Palette := {
  canvas          := 0xFFFFFFFF
  surface         := 0xF6F5F2FF
  elevatedSurface := 0xF1F0EDFF
  sidebar         := 0xF9F9F7FF
  header          := 0xFFFFFFFF
  border          := 0xE0DFD9FF
  borderSubtle    := 0xE8E7E2FF
  focusRing       := 0xABABA6FF
  textPrimary     := 0x242423FF
  textSecondary   := 0x535250FF
  textMuted       := 0x7B7A76FF
  accent          := 0x2F6BD8FF
  accentMuted     := 0x2F6BD826
  codeBg          := 0xEAE9E5FF
  diffAddBg       := 0x2DA44E21
  diffAddText     := 0x2DA44EFF
  diffDelBg       := 0xC0283A21
  diffDelText     := 0xC0283AFF
  diffHunkBg      := 0xE0DFD959
  diffHunkText    := 0x242423FF
  danger          := 0xC0283AFF
  warning         := 0x876A0AFF
  success         := 0x1E7A45FF
  shadowColor     := 0x1E1E1C2D
  rowActive       := 0xEAEAE8FF
  textStrong      := 0x101010FF
  textFaint       := 0xA9A8A2FF
  borderStrong    := 0xD4D3CDFF
  plusBg          := 0xE8E7E3FF
  sendBg          := 0x242423FF
  sendFg          := 0xFFFFFFFF
}

/-- Canonical Orb Dark theme. -/
def orbDarkTheme : Theme := {
  isDark := true
  palette := orbDarkPalette
}

/-- Canonical Orb Light theme. -/
def orbLightTheme : Theme := {
  isDark := false
  palette := orbLightPalette
}

namespace Theme

@[inline] def bodyText (t : Theme) : TextStyle :=
  { fontId := t.typo.fontSans, sizeSub := t.typo.base, lineHeightSub := t.typo.lineBase,
    weight := 400, color := t.palette.textPrimary, monospace := false }

@[inline] def secondaryText (t : Theme) : TextStyle :=
  { fontId := t.typo.fontSans, sizeSub := t.typo.sm, lineHeightSub := t.typo.lineTight,
    weight := 400, color := t.palette.textSecondary, monospace := false }

@[inline] def mutedText (t : Theme) : TextStyle :=
  { fontId := t.typo.fontSans, sizeSub := t.typo.xs, lineHeightSub := t.typo.lineTight,
    weight := 400, color := t.palette.textMuted, monospace := false }

@[inline] def headingText (t : Theme) : TextStyle :=
  { fontId := t.typo.fontSans, sizeSub := t.typo.lg, lineHeightSub := t.typo.lineHeading,
    weight := 600, color := t.palette.textPrimary, monospace := false }

@[inline] def codeText (t : Theme) : TextStyle :=
  { fontId := t.typo.fontMono, sizeSub := t.typo.sm, lineHeightSub := t.typo.lineBase,
    weight := 400, color := t.palette.textPrimary, monospace := true }

@[inline] def cardBox (t : Theme) : BoxStyle :=
  { axis := .column,
    padding := Edges.all (12 * subPerPx),
    gap := 8 * subPerPx,
    background := t.palette.surface,
    radii := CornerRadii.uniform t.radiusMd,
    border := BorderStyle.uniform t.borderWidth t.palette.border }

end Theme

end LeanUI
