import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
/-!
# LeanUI.Layout — pure two-axis Flexbox, inline text run wrapping, scroll clipping, and `LayoutCache`
-/
namespace LeanUI

/-- One pre-shaped glyph or inline atom with advance and atlas/offset metadata in `SubPx`. -/
structure ShapedGlyph where
  glyphId : Nat
  cluster : Nat := 0
  xAdvance : SubPx
  yAdvance : Int := 0
  xOffset : Int := 0
  yOffset : Int := 0
  atlasSrc : Rect := { x := 0, y := 0, w := 0, h := 0 }
  sizePx : Nat × Nat := (0, 0)
  bearingPx : Int × Int := (0, 0)
  isColor : Bool := false
  isBreakOpportunity : Bool := false
  isHardBreak : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- A contiguous inline word/segment made of shaped glyphs. -/
structure InlineRun where
  glyphs : List ShapedGlyph := []
  style : TextStyle := {}
  allowBreakAfter : Bool := true
  hardBreakAfter : Bool := false
  deriving DecidableEq, Repr, Inhabited

namespace InlineRun

@[inline] def advance (r : InlineRun) : SubPx :=
  (r.glyphs.map (·.xAdvance)).sum

end InlineRun

/-- Positioned glyph within a broken line (relative to the text block top-left in `SubPx`). -/
structure PositionedGlyph where
  glyph : ShapedGlyph
  relX : SubPx
  relY : SubPx
  color : Color
  deriving DecidableEq, Repr, Inhabited

/-- One wrapped line of positioned glyphs. -/
structure WrappedLine where
  glyphs : List PositionedGlyph := []
  widthSub : SubPx := 0
  heightSub : SubPx := 0
  ySub : SubPx := 0
  deriving DecidableEq, Repr, Inhabited

/-- Place a list of glyphs left-to-right starting at `(curX, ySub)`. -/
def placeGlyphs (curX ySub : SubPx) (color : Color) : List ShapedGlyph → List PositionedGlyph × SubPx
  | [] => ([], curX)
  | g :: gs =>
    let pg : PositionedGlyph := { glyph := g, relX := curX, relY := ySub, color := color }
    let (rest, endX) := placeGlyphs (curX + g.xAdvance) ySub color gs
    (pg :: rest, endX)

/-- Wrap a sequence of `InlineRun`s into lines of width at most `maxWidthSub` (when `maxWidthSub > 0`). -/
def wrapInlineRunsAux (maxWidthSub defaultLineHeight : SubPx)
    (curGlyphs : List PositionedGlyph) (curX curLineH curY : SubPx) :
    List InlineRun → List WrappedLine
  | [] =>
    if curGlyphs.isEmpty then []
    else [{ glyphs := curGlyphs, widthSub := curX, heightSub := max curLineH defaultLineHeight, ySub := curY }]
  | r :: rs =>
    let runAdv := r.advance
    let runH := max r.style.lineHeightSub defaultLineHeight
    let wraps := maxWidthSub > 0 && curX > 0 && curX + runAdv > maxWidthSub
    if wraps then
      let completedLine : WrappedLine :=
        { glyphs := curGlyphs, widthSub := curX, heightSub := max curLineH defaultLineHeight, ySub := curY }
      let nextY := curY + completedLine.heightSub
      let (placed, nextX) := placeGlyphs 0 nextY r.style.color r.glyphs
      if r.hardBreakAfter then
        let hardLine : WrappedLine :=
          { glyphs := placed, widthSub := nextX, heightSub := runH, ySub := nextY }
        completedLine :: hardLine :: wrapInlineRunsAux maxWidthSub defaultLineHeight [] 0 0 (nextY + runH) rs
      else
        completedLine :: wrapInlineRunsAux maxWidthSub defaultLineHeight placed nextX runH nextY rs
    else
      let lineH' := max curLineH runH
      let (placed, nextX) := placeGlyphs curX curY r.style.color r.glyphs
      let merged := curGlyphs ++ placed
      if r.hardBreakAfter then
        let hardLine : WrappedLine :=
          { glyphs := merged, widthSub := nextX, heightSub := lineH', ySub := curY }
        hardLine :: wrapInlineRunsAux maxWidthSub defaultLineHeight [] 0 0 (curY + lineH') rs
      else
        wrapInlineRunsAux maxWidthSub defaultLineHeight merged nextX lineH' curY rs

/-- Wrap inline runs into top-to-bottom `WrappedLine`s and compute bounding `(widthSub, heightSub)`. -/
def wrapInlineRuns (maxWidthSub defaultLineHeight : SubPx) (runs : List InlineRun) :
    List WrappedLine × SubPx × SubPx :=
  let lines := wrapInlineRunsAux maxWidthSub defaultLineHeight [] 0 0 0 runs
  let maxW := lines.foldl (fun acc l => max acc l.widthSub) 0
  let totalH := match lines.getLast? with
    | none => 0
    | some last => last.ySub + last.heightSub
  (lines, maxW, totalH)

/-- Scroll state for a 2D or vertical scroll container in `SubPx`. -/
structure ScrollSpec where
  offsetX : SubPx := 0
  offsetY : SubPx := 0
  contentWidth : SubPx := 0
  contentHeight : SubPx := 0
  deriving DecidableEq, Repr, Inhabited

namespace ScrollSpec

/-- Clamp and step vertical scroll offset using `Kernel.scrollStep` and `Kernel.scrollLimit`. -/
@[inline] def stepY (s : ScrollSpec) (viewportH : SubPx) (deltaY : Int) : ScrollSpec :=
  let limit := scrollLimit s.contentHeight viewportH
  let nextY := min limit (scrollStep s.contentHeight viewportH s.offsetY deltaY)
  { s with offsetY := nextY }

/-- Clamp and step horizontal scroll offset using `Kernel.scrollStep` and `Kernel.scrollLimit`. -/
@[inline] def stepX (s : ScrollSpec) (viewportW : SubPx) (deltaX : Int) : ScrollSpec :=
  let limit := scrollLimit s.contentWidth viewportW
  let nextX := min limit (scrollStep s.contentWidth viewportW s.offsetX deltaX)
  { s with offsetX := nextX }

end ScrollSpec

/-- Declarative input node to the two-axis Flexbox and inline layout engine. -/
inductive LayoutNode where
  | box (id : Option EntityId) (style : BoxStyle) (children : List LayoutNode)
  | text (id : Option EntityId) (style : BoxStyle) (lineHeightSub : SubPx) (runs : List InlineRun)
  | scroll (id : Option EntityId) (style : BoxStyle) (scroll : ScrollSpec) (child : LayoutNode)
  deriving Repr, Inhabited

/-- Computed layout box for a node, preserving both logical `SubPx` (`rectSub`) and device-pixel `rectDev`. -/
inductive ComputedBox where
  | mk
    (id : Option EntityId)
    (style : BoxStyle)
    (rectSub : Rect)
    (contentRectSub : Rect)
    (rectDev : Rect)
    (contentRectDev : Rect)
    (damageRectDev : Rect)
    (lines : List WrappedLine)
    (scrollOffset : Option (SubPx × SubPx))
    (scrollLimitXY : Option (SubPx × SubPx))
    (focusedBorderPrim : Option Prim)
    (children : List ComputedBox)
  deriving Repr, Inhabited

namespace ComputedBox

@[inline] def id : ComputedBox → Option EntityId
  | .mk v _ _ _ _ _ _ _ _ _ _ _ => v

@[inline] def style : ComputedBox → BoxStyle
  | .mk _ v _ _ _ _ _ _ _ _ _ _ => v

@[inline] def rectSub : ComputedBox → Rect
  | .mk _ _ v _ _ _ _ _ _ _ _ _ => v

@[inline] def contentRectSub : ComputedBox → Rect
  | .mk _ _ _ v _ _ _ _ _ _ _ _ => v

@[inline] def rectDev : ComputedBox → Rect
  | .mk _ _ _ _ v _ _ _ _ _ _ _ => v

@[inline] def contentRectDev : ComputedBox → Rect
  | .mk _ _ _ _ _ v _ _ _ _ _ _ => v

@[inline] def damageRectDev : ComputedBox → Rect
  | .mk _ _ _ _ _ _ v _ _ _ _ _ => v

@[inline] def lines : ComputedBox → List WrappedLine
  | .mk _ _ _ _ _ _ _ v _ _ _ _ => v

@[inline] def scrollOffset : ComputedBox → Option (SubPx × SubPx)
  | .mk _ _ _ _ _ _ _ _ v _ _ _ => v

@[inline] def scrollLimitXY : ComputedBox → Option (SubPx × SubPx)
  | .mk _ _ _ _ _ _ _ _ _ v _ _ => v

@[inline] def focusedBorderPrim : ComputedBox → Option Prim
  | .mk _ _ _ _ _ _ _ _ _ _ v _ => v

@[inline] def children : ComputedBox → List ComputedBox
  | .mk _ _ _ _ _ _ _ _ _ _ _ v => v

end ComputedBox

namespace LayoutNode

@[inline] def styleOf : LayoutNode → BoxStyle
  | .box _ s _ => s
  | .text _ s _ _ => s
  | .scroll _ s _ _ => s

@[inline] def idOf : LayoutNode → Option EntityId
  | .box id _ _ => id
  | .text id _ _ _ => id
  | .scroll id _ _ _ => id

end LayoutNode

/-- Intrinsic content measurement `(widthSub, heightSub)` (including padding & margins) for a `LayoutNode`. -/
def measureNode (availWidthSub : SubPx) : LayoutNode → SubPx × SubPx
  | .box _ s children =>
    let padW := s.padding.horizontal
    let padH := s.padding.vertical
    let marW := s.margin.horizontal
    let marH := s.margin.vertical
    let innerAvailW := availWidthSub - (padW + marW)
    let childMeasures : List (SubPx × SubPx) := measureNodeList innerAvailW children
    let count := childMeasures.length
    let totalGap := if count > 1 then s.gap * (count - 1) else 0
    let (contentW, contentH) :=
      match s.axis with
      | .row =>
        let sumW := (childMeasures.map Prod.fst).sum + totalGap
        let maxH := childMeasures.foldl (fun acc (p : SubPx × SubPx) => max acc p.2) 0
        (sumW, maxH)
      | .column =>
        let maxW := childMeasures.foldl (fun acc (p : SubPx × SubPx) => max acc p.1) 0
        let sumH := (childMeasures.map Prod.snd).sum + totalGap
        (maxW, sumH)
    let rawW := max s.basis (contentW + padW)
    let rawH := max (if s.axis == Axis.column then s.basis else 0) (contentH + padH)
    let clampedW := clampNat s.minWidth s.maxWidth rawW
    let clampedH := clampNat s.minHeight s.maxHeight rawH
    (clampedW + marW, clampedH + marH)
  | .text _ s lineHeightSub runs =>
    let padW := s.padding.horizontal
    let padH := s.padding.vertical
    let marW := s.margin.horizontal
    let marH := s.margin.vertical
    let innerAvailW := availWidthSub - (padW + marW)
    let (_, textW, textH) := wrapInlineRuns innerAvailW lineHeightSub runs
    let rawW := max s.basis (textW + padW)
    let rawH := max (textH + padH) s.minHeight
    let clampedW := clampNat s.minWidth s.maxWidth rawW
    let clampedH := clampNat s.minHeight s.maxHeight rawH
    (clampedW + marW, clampedH + marH)
  | .scroll _ s _ child =>
    let padW := s.padding.horizontal
    let padH := s.padding.vertical
    let marW := s.margin.horizontal
    let marH := s.margin.vertical
    let (cw, ch) := measureNode (availWidthSub - (padW + marW)) child
    let rawW := max s.basis (cw + padW)
    let rawH := max (if s.axis == Axis.column then s.basis else 0) (ch + padH)
    let clampedW := clampNat s.minWidth s.maxWidth rawW
    let clampedH := clampNat s.minHeight s.maxHeight rawH
    (clampedW + marW, clampedH + marH)
where
  measureNodeList (availW : SubPx) : List LayoutNode → List (SubPx × SubPx)
    | [] => []
    | n :: ns => measureNode availW n :: measureNodeList availW ns

/-- Build a `FlexItem` along `axis` from a child node and its intrinsic `(measuredW, measuredH)`. -/
def toFlexItem (axis : Axis) (s : BoxStyle) (measuredW measuredH : SubPx) : FlexItem :=
  match axis with
  | .row =>
    let marW := s.margin.horizontal
    let base := clampNat s.minWidth s.maxWidth (max s.basis (measuredW - marW)) + marW
    { basis := base,
      grow := s.grow,
      minMain := s.minWidth + marW,
      maxMain := s.maxWidth + marW }
  | .column =>
    let marH := s.margin.vertical
    let base := clampNat s.minHeight s.maxHeight (max s.basis (measuredH - marH)) + marH
    { basis := base,
      grow := s.grow,
      minMain := s.minHeight + marH,
      maxMain := s.maxHeight + marH }

/-- Solve main-axis child sizes using `Kernel.flexMainClamped` when growing and `Kernel.flexShrink` when overflowing. -/
def solveFlexMain (axis : Axis) (availMain : SubPx) (children : List LayoutNode)
    (measures : List (SubPx × SubPx)) : List SubPx :=
  let items := (children.zip measures).map fun (c, (mw, mh)) =>
    toFlexItem axis c.styleOf mw mh
  let basesSum := (items.map (·.basis)).sum
  if basesSum ≤ availMain then
    flexMainClamped availMain items
  else
    let weights := children.map fun c => c.styleOf.shrink
    if weights.sum > 0 then
      flexShrink availMain items weights
    else
      flexMainClamped availMain items

/-- Compute main-axis starting offset and inter-item spacing for `Justify`. -/
def computeJustifyOffsets (justify : Justify) (availMain usedMain baseGap count : SubPx) : SubPx × SubPx :=
  let totalBaseGap := if count > 1 then baseGap * (count - 1) else 0
  let occupied := usedMain + totalBaseGap
  let free := availMain - occupied
  match justify with
  | .start => (0, baseGap)
  | .center => (free / 2, baseGap)
  | .end_ => (free, baseGap)
  | .spaceBetween =>
    if count > 1 then
      let extraGap := (availMain - usedMain) / (count - 1)
      (0, max baseGap extraGap)
    else
      (0, baseGap)

/-- Compute cross-axis offset and allocated cross extent for a child under `Align`. -/
def computeCrossAlign (align : Align) (availCross intrinsicCross minCross maxCross : SubPx) : SubPx × SubPx :=
  match align with
  | .start =>
    let size := clampNat minCross maxCross intrinsicCross
    (0, size)
  | .center =>
    let size := clampNat minCross maxCross intrinsicCross
    ((availCross - size) / 2, size)
  | .«end» =>
    let size := clampNat minCross maxCross intrinsicCross
    (availCross - size, size)
  | .stretch =>
    let size := clampNat minCross maxCross (max intrinsicCross availCross)
    (0, size)

/-- Construct margin-inset outer and content rects in `SubPx` and round to device pixels via `Kernel.roundRect` / `Kernel.roundRectOut`. -/
def makeBoxRects (scale120 : Nat) (x y : Int) (w h : SubPx) (s : BoxStyle) :
    Rect × Rect × Rect × Rect × Rect :=
  let outerW := w - s.margin.horizontal
  let outerH := h - s.margin.vertical
  let rectSub : Rect :=
    { x := x + Int.ofNat s.margin.left,
      y := y + Int.ofNat s.margin.top,
      w := Int.ofNat outerW,
      h := Int.ofNat outerH }
  let contentW := outerW - s.padding.horizontal
  let contentH := outerH - s.padding.vertical
  let contentRectSub : Rect :=
    { x := rectSub.x + Int.ofNat s.padding.left,
      y := rectSub.y + Int.ofNat s.padding.top,
      w := Int.ofNat contentW,
      h := Int.ofNat contentH }
  let rectDev := roundRect scale120 rectSub
  let contentRectDev := roundRect scale120 contentRectSub
  let damageRectDev := roundRectOut scale120 rectSub
  (rectSub, contentRectSub, rectDev, contentRectDev, damageRectDev)

/-- Recursively compute the two-axis Flexbox and inline layout tree in `SubPx` and device pixels. -/
def layoutNode (scale120 : Nat) (focusOwner : Option EntityId) (focusColor : Color)
    (x y : Int) (availW availH : SubPx) : LayoutNode → ComputedBox
  | .box id s children =>
    let (rectSub, contentRectSub, rectDev, contentRectDev, damageRectDev) :=
      makeBoxRects scale120 x y availW availH s
    let cX : Int := contentRectSub.x
    let cY : Int := contentRectSub.y
    let cW := contentRectSub.w.toNat
    let cH := contentRectSub.h.toNat
    let measures := measureNode.measureNodeList cW children
    let count := children.length
    let totalBaseGap := if count > 1 then s.gap * (count - 1) else 0
    let availMain := (match s.axis with | .row => cW | .column => cH) - totalBaseGap
    let mainSizes := solveFlexMain s.axis availMain children measures
    let usedMain := mainSizes.sum
    let fullMain := match s.axis with | .row => cW | .column => cH
    let (startMain, stepGap) := computeJustifyOffsets s.justify fullMain usedMain s.gap count
    let laidChildren := layoutChildren scale120 focusOwner focusColor s.axis s.align cX cY cW cH
      startMain stepGap children mainSizes measures
    let isFocused := match id, focusOwner with
      | some eid, some owner => eid == owner
      | _, _ => false
    let fb := id.map fun _ => focusBorder isFocused rectDev focusColor
    ComputedBox.mk id s rectSub contentRectSub rectDev contentRectDev damageRectDev
      [] none none fb laidChildren
  | .text id s lineHeightSub runs =>
    let (rectSub, contentRectSub, rectDev, contentRectDev, damageRectDev) :=
      makeBoxRects scale120 x y availW availH s
    let cW := contentRectSub.w.toNat
    let (lines, _, _) := wrapInlineRuns cW lineHeightSub runs
    let isFocused := match id, focusOwner with
      | some eid, some owner => eid == owner
      | _, _ => false
    let fb := id.map fun _ => focusBorder isFocused rectDev focusColor
    ComputedBox.mk id s rectSub contentRectSub rectDev contentRectDev damageRectDev
      lines none none fb []
  | .scroll id s sc child =>
    let (rectSub, contentRectSub, rectDev, contentRectDev, damageRectDev) :=
      makeBoxRects scale120 x y availW availH s
    let vpX : Int := contentRectSub.x
    let vpY : Int := contentRectSub.y
    let vpW := contentRectSub.w.toNat
    let vpH := contentRectSub.h.toNat
    let (measW, measH) := measureNode vpW child
    let contentW := max sc.contentWidth (max vpW measW)
    let contentH := max sc.contentHeight (max vpH measH)
    let limX := scrollLimit contentW vpW
    let limY := scrollLimit contentH vpH
    let clampedOffX := scrollStep contentW vpW (min sc.offsetX limX) 0
    let clampedOffY := scrollStep contentH vpH (min sc.offsetY limY) 0
    let childX : Int := vpX - Int.ofNat clampedOffX
    let childY : Int := vpY - Int.ofNat clampedOffY
    let laidChild := layoutNode scale120 focusOwner focusColor childX childY contentW contentH child
    let isFocused := match id, focusOwner with
      | some eid, some owner => eid == owner
      | _, _ => false
    let fb := id.map fun _ => focusBorder isFocused rectDev focusColor
    ComputedBox.mk id ({ s with clip := true }) rectSub contentRectSub rectDev contentRectDev damageRectDev
      [] (some (clampedOffX, clampedOffY)) (some (limX, limY)) fb [laidChild]
where
  layoutChildren (scale120 : Nat) (focusOwner : Option EntityId) (focusColor : Color)
      (axis : Axis) (align : Align) (originX originY : Int) (cW cH curMain stepGap : SubPx) :
      List LayoutNode → List SubPx → List (SubPx × SubPx) → List ComputedBox
    | [], _, _ => []
    | c :: cs, m :: ms, (mw, mh) :: mws =>
      let csStyle := c.styleOf
      let (childX, childY, childW, childH) :=
        match axis with
        | .row =>
          let (crossOff, crossSize) :=
            computeCrossAlign align cH mh
              (csStyle.minHeight + csStyle.margin.vertical)
              (csStyle.maxHeight + csStyle.margin.vertical)
          (originX + Int.ofNat curMain, originY + Int.ofNat crossOff, m, crossSize)
        | .column =>
          let (crossOff, crossSize) :=
            computeCrossAlign align cW mw
              (csStyle.minWidth + csStyle.margin.horizontal)
              (csStyle.maxWidth + csStyle.margin.horizontal)
          (originX + Int.ofNat crossOff, originY + Int.ofNat curMain, crossSize, m)
      let box := layoutNode scale120 focusOwner focusColor childX childY childW childH c
      box :: layoutChildren scale120 focusOwner focusColor axis align originX originY cW cH
        (curMain + m + stepGap) stepGap cs ms mws
    | _, _, _ => []

/-- Content-addressed layout cache key combining node identity/hash, viewport bounds, and scale. -/
structure LayoutCacheKey where
  nodeHash : UInt64
  availW : SubPx
  availH : SubPx
  scale120 : Nat
  focusOwner : Option EntityId
  deriving DecidableEq, Repr, Inhabited

/-- FNV-1a 64-bit hash combiner for `LayoutCacheKey`. -/
@[inline] def mixU64 (h v : UInt64) : UInt64 :=
  (h ^^^ v) * 1099511628211

@[inline] def hashLayoutCacheKey (k : LayoutCacheKey) : UInt64 :=
  let h0 : UInt64 := 14695981039346656037
  let h1 := mixU64 h0 k.nodeHash
  let h2 := mixU64 h1 k.availW.toUInt64
  let h3 := mixU64 h2 k.availH.toUInt64
  let h4 := mixU64 h3 k.scale120.toUInt64
  let focusVal : UInt64 := match k.focusOwner with
    | none => 0
    | some eid => eid.toUInt64 + 1
  mixU64 h4 focusVal

/-- Structural 64-bit hash of a `LayoutNode` for `LayoutCache`. -/
def hashLayoutNode : LayoutNode → UInt64
  | .box id s children =>
    let h0 := mixU64 14695981039346656037 (match id with | none => 0 | some i => i.toUInt64 + 1)
    let h1 := mixU64 h0 s.basis.toUInt64
    let h2 := mixU64 h1 s.grow.toUInt64
    let h3 := mixU64 h2 s.gap.toUInt64
    hashLayoutNodeList h3 children
  | .text id s lh runs =>
    let h0 := mixU64 14695981039346656037 (match id with | none => 0 | some i => i.toUInt64 + 2)
    let h1 := mixU64 h0 s.basis.toUInt64
    let h2 := mixU64 h1 lh.toUInt64
    mixU64 h2 runs.length.toUInt64
  | .scroll id s sc child =>
    let h0 := mixU64 14695981039346656037 (match id with | none => 0 | some i => i.toUInt64 + 3)
    let h1 := mixU64 h0 sc.offsetX.toUInt64
    let h2 := mixU64 h1 sc.offsetY.toUInt64
    let h3 := mixU64 h2 s.basis.toUInt64
    mixU64 h3 (hashLayoutNode child)
where
  hashLayoutNodeList (acc : UInt64) : List LayoutNode → UInt64
    | [] => acc
    | n :: ns => hashLayoutNodeList (mixU64 acc (hashLayoutNode n)) ns

/-- Content-hashed layout cache built directly on `Kernel.HashCache`. -/
abbrev LayoutCache := HashCache ComputedBox

/-- Compute or retrieve a cached `ComputedBox` tree using `Kernel.HashCache`. -/
def layoutWithCache (cache : LayoutCache) (scale120 : Nat) (focusOwner : Option EntityId)
    (focusColor : Color) (availW availH : SubPx) (root : LayoutNode) : ComputedBox × LayoutCache :=
  let key : LayoutCacheKey := {
    nodeHash := hashLayoutNode root
    availW := availW
    availH := availH
    scale120 := scale120
    focusOwner := focusOwner
  }
  match cache.lookup hashLayoutCacheKey key with
  | some computed => (computed, cache)
  | none =>
    let computed := layoutNode scale120 focusOwner focusColor 0 0 availW availH root
    (computed, cache.insert hashLayoutCacheKey key computed)

end LeanUI
