import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
/-!
# LeanUI.Scene — declarative `WidgetNode` / `SceneNode` builder, Z-ordered `Prim` batcher, focus order & hit-testing
-/
namespace LeanUI

/-- Semantic widget identity alias (`EntityId`). -/
abbrev WidgetId := EntityId

/-- Caret overlay drawn inside a `WidgetPayload.text` when `focusState.owner == some owner`. -/
structure TextCaretSpec where
  owner : WidgetId
  pos : Nat
  length : Nat
  color : Color
  deriving DecidableEq, Repr, Inhabited

/-- Visual payload carried by a declarative `WidgetNode`. -/
inductive WidgetPayload where
  | container
  | rrect (fill : Color) (radii : CornerRadii) (border : BorderStyle)
  | shadow (shadow : ShadowStyle) (radius : SubPx)
  | linearGradient (c0 c1 : Color) (angleDeg : Nat) (radius : SubPx)
  | text (lineHeightSub : SubPx) (runs : List InlineRun) (caret : Option TextCaretSpec := none)
  | iconMask (page : Nat) (src : Rect) (color : Color) (badgeBg : Option Color := none)
  /-- Round-capped polylines in a 16px view box, coordinates in tenths of a pixel.
  `strokeTenths` is the stroke radius in tenths of a view unit (55 → the historical
  5.5-unit radius); diagram edges and decision outlines pass a thinner radius so
  their rendered stroke matches the shared 2px widget border weight. -/
  | vectorIcon (paths : List (List (Int × Int))) (color : Color)
      (badgeBg : Option Color := none) (strokeTenths : Nat := 55)
  /-- Tree branch behind an icon, with its small bottom-right status ring. -/
  | treeDecoration (branch last children : Bool) (rails : List Nat) (stroke status background : Color)
  | image (tex : Nat) (src : Rect) (radius : SubPx)
  | scrollClip (scroll : ScrollSpec)
  | roundedClip (radii : CornerRadii)
  | opacityLayer (opacity : Nat)
  deriving Repr, Inhabited, BEq

/-- High-level declarative UI widget / scene node. -/
inductive WidgetNode where
  | mk
    (id : Option WidgetId)
    (focusable : Bool)
    (hitTestable : Bool)
    (style : BoxStyle)
    (payload : WidgetPayload)
    (children : List WidgetNode)
  deriving Repr, Inhabited, BEq

/-- Alias for `WidgetNode` when used as a declarative scene graph node. -/
abbrev SceneNode := WidgetNode

namespace WidgetNode

@[inline] def idOf : WidgetNode → Option WidgetId
  | .mk id _ _ _ _ _ => id

@[inline] def isFocusable : WidgetNode → Bool
  | .mk _ focusable _ _ _ _ => focusable

@[inline] def isHitTestable : WidgetNode → Bool
  | .mk _ focusable hitTestable _ _ _ => focusable || hitTestable

@[inline] def styleOf : WidgetNode → BoxStyle
  | .mk _ _ _ style _ _ => style

@[inline] def payloadOf : WidgetNode → WidgetPayload
  | .mk _ _ _ _ payload _ => payload

@[inline] def childrenOf : WidgetNode → List WidgetNode
  | .mk _ _ _ _ _ children => children

/-- Declarative Flex box container builder. -/
@[inline] def box (style : BoxStyle := {}) (children : List WidgetNode := [])
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome style .container children

/-- Declarative rounded rectangle widget builder. -/
@[inline] def rrect (style : BoxStyle) (fill : Color) (radii : CornerRadii)
    (border : BorderStyle := {}) (children : List WidgetNode := [])
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome style (.rrect fill radii border) children

/-- Declarative SDF drop shadow widget builder. -/
@[inline] def shadow (style : BoxStyle) (sh : ShadowStyle) (radius : SubPx := 0)
    (children : List WidgetNode := []) : WidgetNode :=
  .mk none false false style (.shadow sh radius) children

/-- Declarative two-stop linear gradient widget builder. -/
@[inline] def linearGradient (style : BoxStyle) (c0 c1 : Color) (angleDeg : Nat := 90)
    (radius : SubPx := 0) (children : List WidgetNode := []) : WidgetNode :=
  .mk none false false style (.linearGradient c0 c1 angleDeg radius) children

/-- Declarative inline text run widget builder. -/
@[inline] def text (style : BoxStyle) (lineHeightSub : SubPx) (runs : List InlineRun)
    (id : Option WidgetId := none) (caret : Option TextCaretSpec := none) : WidgetNode :=
  .mk id false id.isSome style (.text lineHeightSub runs caret) []

/-- Declarative coverage-mask icon / vector glyph widget builder. -/
@[inline] def icon (style : BoxStyle) (page : Nat) (src : Rect) (color : Color)
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome style (.iconMask page src color) []

/-- Chevron used by dropdown controls in the desktop chrome and composer. -/
def downChevronPaths : List (List (Int × Int)) := [[(50,65),(80,95),(110,65)]]

/-- Declarative RGBA texture image widget builder. -/
@[inline] def image (style : BoxStyle) (tex : Nat) (src : Rect) (radius : SubPx := 0)
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome style (.image tex src radius) []

/-- Declarative scrollable clip region widget builder. -/
@[inline] def scrollClip (style : BoxStyle) (scroll : ScrollSpec) (child : WidgetNode)
    (id : Option WidgetId := none) (hitTestable := true) : WidgetNode :=
  .mk id false hitTestable ({ style with clip := true }) (.scrollClip scroll) [child]

/-- Declarative rounded scissor clip region widget builder. -/
@[inline] def roundedClip (style : BoxStyle) (radii : CornerRadii)
    (children : List WidgetNode := []) (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome ({ style with radii := radii, clipRounded := true }) (.roundedClip radii) children

/-- Declarative group opacity layer (`0..255`) widget builder. -/
@[inline] def opacityLayer (opacity : Nat) (style : BoxStyle := {})
    (children : List WidgetNode := []) : WidgetNode :=
  .mk none false false ({ style with opacity := min 255 opacity }) (.opacityLayer (min 255 opacity)) children

/-- Wrap or mark a widget as keyboard-focusable and hit-testable with `wid`. -/
@[inline] def focusable (wid : WidgetId) (node : WidgetNode) : WidgetNode :=
  match node with
  | .mk _ _ _ style payload children =>
    .mk (some wid) true true style payload children

/-- Lower a declarative `WidgetNode` tree to a `LayoutNode` tree for Flexbox + inline layout. -/
def toLayoutNode : WidgetNode → LayoutNode
  | .mk id _ _ style payload children =>
    match payload with
    | .text lineHeightSub runs _ =>
      .text id style lineHeightSub runs
    | .scrollClip sc =>
      let childLayout := match children with
        | [] => .box none {} []
        | [c] => toLayoutNode c
        | cs => .box none { axis := style.axis, gap := style.gap } (toLayoutList cs)
      .scroll id style sc childLayout
    | _ =>
      .box id style (toLayoutList children)
where
  toLayoutList : List WidgetNode → List LayoutNode
    | [] => []
    | w :: ws => toLayoutNode w :: toLayoutList ws

end WidgetNode

/-- Emit background and border primitives for a `BoxStyle` at `rectDev`. -/
def emitBoxStylePrims (scale120 : Nat) (rectDev : Rect) (s : BoxStyle) : List Prim :=
  let shPrim : List Prim :=
    if s.shadow.isVisible then
      let spreadSub := s.shadow.spread
      let shRectSub : Rect :=
        { x := rectDev.x + roundDev scale120 s.shadow.offsetX - roundDev scale120 spreadSub,
          y := rectDev.y + roundDev scale120 s.shadow.offsetY - roundDev scale120 spreadSub,
          w := rectDev.w + 2 * roundDev scale120 spreadSub,
          h := rectDev.h + 2 * roundDev scale120 spreadSub }
      let radPx := scaleSubPx scale120 s.radii.topLeft
      let blurPx := scaleSubPx scale120 s.shadow.blur
      [.shadow shRectSub s.shadow.color radPx blurPx]
    else []
  let hasBg := (s.background &&& 0x000000FF) != 0
  let hasBorder := s.border.isVisible
  let fillPrim : List Prim :=
    if !hasBg && !hasBorder then []
    else if s.radii.isUniform && s.border.isUniform then
      let radPx := scaleSubPx scale120 s.radii.topLeft
      let bwPx := if hasBorder then max 1 (scaleSubPx scale120 s.border.widths.top) else 0
      [.quad rectDev s.background radPx bwPx s.border.color]
    else
      let radiiPx := s.radii.toDevTuple scale120
      let bordersPx := s.border.toDevTuple scale120
      [.rrect rectDev s.background radiiPx bordersPx s.border.color]
  shPrim ++ fillPrim

/-- Convert positioned glyphs on wrapped lines into `Prim.glyph` primitives in device pixels. -/
def emitWrappedLineGlyphs (scale120 : Nat) (originXSub originYSub : Int) :
    List WrappedLine → List Prim
  | [] => []
  | line :: rest =>
    emitLineGlyphs scale120 originXSub originYSub line.heightSub line.glyphs ++
      emitWrappedLineGlyphs scale120 originXSub originYSub rest
where
  emitLineGlyphs (scale120 : Nat) (originXSub originYSub : Int) (lineHSub : SubPx) :
      List PositionedGlyph → List Prim
    | [] => []
    | pg :: pgs =>
      let baselineOffSub : Int := (Int.ofNat lineHSub * 7 + 4) / 9
      let gxSub := originXSub + Int.ofNat pg.relX + pg.glyph.xOffset
      let gySub := originYSub + Int.ofNat pg.relY + baselineOffSub + pg.glyph.yOffset
      let devX := roundDev scale120 gxSub + pg.glyph.bearingPx.1
      let devY := roundDev scale120 gySub - pg.glyph.bearingPx.2
      let (gw, gh) := pg.glyph.sizePx
      let dst : Rect :=
        if gw > 0 && gh > 0 then
          { x := devX, y := devY, w := Int.ofNat gw, h := Int.ofNat gh }
        else
          roundRect scale120
            { x := gxSub, y := originYSub + Int.ofNat pg.relY + pg.glyph.yOffset,
              w := Int.ofNat (max 1 pg.glyph.xAdvance),
              h := Int.ofNat (max 1 subPerPx) }
      (if gw > 0 && gh > 0 then [Prim.glyph pg.glyph.atlasSrc dst pg.color pg.glyph.isColor pg.glyph.atlasPage] else []) ++
        emitLineGlyphs scale120 originXSub originYSub lineHSub pgs

/-- Emit a crisp vertical caret bar at the logical scalar insertion point when `owner` is focused. -/
def emitTextCaret (scale120 : Nat) (focusState : FocusState) (box : ComputedBox)
    (lineH : SubPx) : Option TextCaretSpec → List Prim
  | none => []
  | some c =>
    if focusState.owner != some c.owner then []
    else
      let barW : Int := Int.ofNat (max 1 (scaleSubPx scale120 (pxToSub 1 + pxToSub 1 / 2)))
      if c.length == 0 then
        let r : Rect := {
          x := roundDev scale120 box.contentRectSub.x,
          y := roundDev scale120 (box.contentRectSub.y + pxToSub 1),
          w := barW,
          h := Int.ofNat (max 1 (scaleSubPx scale120 (lineH - pxToSub 2)))
        }
        [Prim.quad r c.color 0 0 0]
      else
        let rows := editorRows box.lines c.length
        let row := rows[editorRowIndex rows c.pos]?.getD
          { start := 0, stops := [(0, 0)], top := 0, height := lineH }
        let relX : SubPx :=
          match row.stops.find? (fun p => p.1 >= c.pos) with
          | some (_, x) => x
          | none => match row.stops.getLast? with
            | some (_, x) => x
            | none => 0
        let r : Rect := {
          x := roundDev scale120 (box.contentRectSub.x + Int.ofNat relX),
          y := roundDev scale120 (box.contentRectSub.y + Int.ofNat row.top + pxToSub 1),
          w := barW,
          h := Int.ofNat (max 1 (scaleSubPx scale120 (row.height - pxToSub 2)))
        }
        [Prim.quad r c.color 0 0 0]

/-- Emit payload-specific primitives for a single laid-out node. -/
def emitPayloadPrims (scale120 : Nat) (focusState : FocusState) (box : ComputedBox) : WidgetPayload → List Prim
  | .container => []
  | .rrect fill radii border =>
    let radiiPx := radii.toDevTuple scale120
    let bordersPx := border.toDevTuple scale120
    [.rrect box.rectDev fill radiiPx bordersPx border.color]
  | .shadow sh radius =>
    let spreadPx := roundDev scale120 sh.spread
    let shRect : Rect :=
      { x := box.rectDev.x + roundDev scale120 sh.offsetX - spreadPx,
        y := box.rectDev.y + roundDev scale120 sh.offsetY - spreadPx,
        w := box.rectDev.w + 2 * spreadPx,
        h := box.rectDev.h + 2 * spreadPx }
    [.shadow shRect sh.color (scaleSubPx scale120 radius) (scaleSubPx scale120 sh.blur)]
  | .linearGradient c0 c1 angleDeg radius =>
    [.linear box.rectDev c0 c1 angleDeg (scaleSubPx scale120 radius)]
  | .text lineH _ caret =>
    emitWrappedLineGlyphs scale120 box.contentRectSub.x box.contentRectSub.y box.lines ++
      emitTextCaret scale120 focusState box lineH caret
  | .iconMask page src color none =>
    [.mask page src box.contentRectDev color]
  | .iconMask page src color (some bg) =>
    let p (n : Nat) := Int.ofNat (scaleSubPx scale120 (pxToSub n))
    let r := box.rectDev
    let disc : Rect := { x := r.right - p 8, y := r.bottom - p 9, w := p 12, h := p 12 }
    [.quad disc bg (scaleSubPx scale120 (pxToSub 6)) 0 0,
     .mask page src { x := disc.x + p 1, y := disc.y + p 1, w := p 10, h := p 10 } color]
  | .vectorIcon _ _ _ _ => [] -- Rasterized into the shared atlas before layout.
  | .treeDecoration branch last children rails stroke status background =>
    let r := box.rectDev
    let p (n : Nat) := Int.ofNat (scaleSubPx scale120 (pxToSub n))
    let x := r.x - p 8
    let y := r.y + p 8
    let top := r.y - p 7
    let rail := fun offset => Prim.quad { x := x - p (16 * offset), y := top, w := p 1, h := p 32 } stroke 0 0 0
    let childLink := if children then
      [Prim.quad { x := r.x + p 8, y := r.bottom, w := p 1, h := p 9 } stroke 0 0 0] else []
    rails.map rail ++ childLink ++
    (if !branch then [] else if last then
       [Prim.rrect { x, y := top, w := p 9, h := y - top + p 1 } 0 (0, 0, 0, (p 4).toNat)
         (0, 0, (p 1).toNat, (p 1).toNat) stroke]
     else [rail 0, Prim.quad { x, y, w := p 9, h := p 1 } stroke 0 0 0]) ++
    (if status == 0 then [] else
       [Prim.quad { x := r.x + p 10, y := r.y + p 10, w := p 8, h := p 8 }
         background (scaleSubPx scale120 (pxToSub 4)) (scaleSubPx scale120 (pxToSub 1)) status])
  | .image tex src radius =>
    [.image tex src box.contentRectDev (scaleSubPx scale120 radius)]
  | .scrollClip _ => []
  | .roundedClip _ => []
  | .opacityLayer _ => []

/-- Intersect two device-pixel clip rectangles. -/
@[inline] def intersectRect (a b : Rect) : Rect :=
  let x0 := max a.x b.x
  let y0 := max a.y b.y
  let r0 := min a.right b.right
  let b0 := min a.bottom b.bottom
  { x := x0, y := y0, w := max 0 (r0 - x0), h := max 0 (b0 - y0) }

/-- Stable paint record for one explicitly identified widget. The effect bounds include shadows,
borders and text geometry, so replacing or moving a node invalidates both its old and new pixels. -/
structure SceneNodeRecord where
  id : WidgetId
  effectBoundsDev : Rect
  fingerprint : UInt64
  deriving DecidableEq, Repr, Inhabited

/-- Conservative diff result for identified scene nodes. -/
structure SceneDiff where
  damage : Damage := none
  fullRedraw : Bool := false
  changed : List WidgetId := []
  deriving DecidableEq, Repr, Inhabited

/-- Output of lowering a laid-out widget tree into a Z-ordered `Scene` (`Array Prim`), tab order,
hit regions, and stable records for changed-node damage tracking. -/
structure SceneOutput where
  prims : Scene
  focusableOrder : List WidgetId
  hitRegionsSub : List (WidgetId × Rect)
  hitRegionsDev : List (WidgetId × Rect)
  boundsDamage : Damage
  nodeRecords : Array SceneNodeRecord := #[]
  deriving Repr, Inhabited

/-- Whether a widget node paints a visible focus ring: bordered text inputs step their 1px border
whenever focused, borderless text inputs (e.g. search bar `701`) rely on their vertical caret, and
non-text controls paint `focusRing` only on keyboard `:focus-visible`. -/
def nodeShowsFocusRing (id : Option WidgetId) (style : BoxStyle) (payload : WidgetPayload)
    (focusState : FocusState) (focusVisible : Bool) : Bool :=
  let isFocused := match id, focusState.owner with
    | some wid, some owner => wid == owner
    | _, _ => false
  let isTextInput := match id with
    | some wid => isTextInputEntity wid
    | none => false
  let hasVisibleBorder : Bool :=
    match payload with
    | .rrect _ _ border => border.isVisible
    | _ => style.border.isVisible
  isFocused && (if isTextInput then hasVisibleBorder else focusVisible)

/-- Fingerprint paint-affecting node content without including child nodes, which are tracked by
separate records. -/
def nodeFingerprint (node : WidgetNode) (box : ComputedBox) (showFocusRing : Bool := false) : UInt64 :=
  hash s!"{repr node.styleOf}|{repr node.payloadOf}|{repr box.rectDev}|{repr box.lines}|{repr box.focusedBorderPrim}|{showFocusRing}"

/-- Expand a node's layout damage enough to cover local shadows, focus rings, and decorative
branches. This is deliberately conservative: under-invalidation leaves stale pixels, while a
slightly larger dirty box still preserves the damage-only path. -/
def effectBounds (r : Rect) : Rect :=
  { x := r.x - 64, y := r.y - 64, w := r.w + 128, h := r.h + 128 }

/-- Collect explicitly identified nodes in document order. Anonymous nodes remain covered by the
existing conservative root damage path. -/
def collectNodeRecords (focusState : FocusState := {}) (focusVisible : Bool := true) :
    WidgetNode → ComputedBox → Array SceneNodeRecord
  | node, box =>
    match node with
    | .mk id _ _ style payload children =>
      let self := match id with
        | none => #[]
        | some wid =>
          let showRing := nodeShowsFocusRing id style payload focusState focusVisible
          let record : SceneNodeRecord :=
            { id := wid
              effectBoundsDev := effectBounds box.damageRectDev
              fingerprint := nodeFingerprint node box showRing }
          #[record]
      self ++ collectChildren focusState focusVisible children box.children
where
  collectChildren (focusState : FocusState) (focusVisible : Bool) :
      List WidgetNode → List ComputedBox → Array SceneNodeRecord
    | [], _ => #[]
    | _, [] => #[]
    | n :: ns, b :: bs =>
      collectNodeRecords focusState focusVisible n b ++ collectChildren focusState focusVisible ns bs

private def findNodeRecord (records : Array SceneNodeRecord) (id : WidgetId) : Option SceneNodeRecord :=
  records.find? (·.id == id)

/-- Diff node records, unioning both old and new effect bounds for moved/resized/replaced nodes. -/
def diffSceneNodes (before after : Array SceneNodeRecord) : SceneDiff :=
  let ids := ((before.toList.map (·.id)) ++ (after.toList.map (·.id))).eraseDups
  ids.foldl (fun acc id =>
    match findNodeRecord before id, findNodeRecord after id with
    | some old, some new =>
      if old.fingerprint == new.fingerprint && old.effectBoundsDev == new.effectBoundsDev then acc
      else
        { damage := Damage.add (Damage.add acc.damage old.effectBoundsDev) new.effectBoundsDev,
          changed := acc.changed ++ [id] }
    | some old, none =>
      { damage := Damage.add acc.damage old.effectBoundsDev, changed := acc.changed ++ [id] }
    | none, some new =>
      { damage := Damage.add acc.damage new.effectBoundsDev, changed := acc.changed ++ [id] }
    | none, none => acc) {}

@[inline] def SceneOutput.diff (before after : SceneOutput) : SceneDiff :=
  diffSceneNodes before.nodeRecords after.nodeRecords

/-- Shared pure geometry for a vertical overlay scrollbar in logical `SubPx` coordinates.
Used as the single source of truth by both `scrollbarPrims` painting and pointer hit-testing/drag math. -/
structure ScrollbarGeometry where
  /-- Right-edge pointer hit gutter (`12px` wide, clamped to viewport width) over full viewport height. -/
  trackRectSub : Rect
  /-- Painted `6px` overlay thumb rectangle in logical `SubPx`. -/
  thumbRectSub : Rect
  /-- Pointer hit rectangle for the thumb (full hit gutter width, thumb vertical span). -/
  thumbHitRectSub : Rect
  /-- Top Y of the thumb travel track (`bounds.y + padY`) in logical `SubPx`. -/
  trackTopSub : Int
  /-- Maximum vertical thumb travel (`usableH - thumbH`) in logical `SubPx`. -/
  travelSub : Int
  /-- Vertical scroll limit (`limitY`) in logical `SubPx`. -/
  limitY : SubPx
  deriving DecidableEq, Repr, Inhabited

/-- Compute vertical overlay scrollbar geometry in logical `SubPx` from container `boundsSub`,
vertical scroll limit `limitY`, and current `offsetY`. Returns `none` when non-scrollable (`limitY == 0`). -/
def scrollbarGeometry (boundsSub : Rect) (limitY offsetY : SubPx) : Option ScrollbarGeometry :=
  if limitY == 0 || boundsSub.w ≤ 0 || boundsSub.h ≤ 0 then none
  else
    let viewH := boundsSub.h
    let limitInt : Int := Int.ofNat limitY
    let contentH := viewH + limitInt
    let offInt : Int := min (Int.ofNat offsetY) limitInt
    let padY : Int := Int.ofNat (pxToSub 4)
    let minThumb : Int := Int.ofNat (pxToSub 28)
    let usableH : Int := max 1 (viewH - 2 * padY)
    let thumbH : Int := min usableH (max minThumb ((usableH * viewH) / max 1 contentH))
    let travel : Int := max 0 (usableH - thumbH)
    let trackTop : Int := boundsSub.y + padY
    let thumbY : Int := trackTop + (offInt * travel) / limitInt
    let thumbW : Int := Int.ofNat (pxToSub 6)
    let rightInset : Int := Int.ofNat (pxToSub 3)
    let thumbX : Int := boundsSub.right - thumbW - rightInset
    let gutterW : Int := min boundsSub.w (Int.ofNat (pxToSub 12))
    let trackRectSub : Rect :=
      { x := boundsSub.right - gutterW, y := boundsSub.y, w := gutterW, h := boundsSub.h }
    let thumbRectSub : Rect :=
      { x := thumbX, y := thumbY, w := thumbW, h := thumbH }
    let thumbHitRectSub : Rect :=
      { x := trackRectSub.x, y := thumbY, w := trackRectSub.w, h := thumbH }
    some { trackRectSub, thumbRectSub, thumbHitRectSub, trackTopSub := trackTop, travelSub := travel, limitY }

namespace ScrollbarGeometry

/-- Compute clamped vertical scroll offset (`[0, limitY]`) for a desired thumb top coordinate. -/
def offsetForThumbTop (g : ScrollbarGeometry) (desiredThumbTopSub : Int) : SubPx :=
  if g.limitY == 0 || g.travelSub ≤ 0 then 0
  else
    let clampedPos := max 0 (min g.travelSub (desiredThumbTopSub - g.trackTopSub))
    let num := clampedPos * Int.ofNat g.limitY + g.travelSub / 2
    min g.limitY (num / g.travelSub).toNat

/-- Compute thumb top Y coordinate in `SubPx` corresponding to a given `offsetY`. -/
def thumbTopForOffset (g : ScrollbarGeometry) (offsetY : SubPx) : Int :=
  if g.limitY == 0 then g.trackTopSub
  else
    let offInt : Int := min (Int.ofNat offsetY) (Int.ofNat g.limitY)
    g.trackTopSub + (offInt * g.travelSub) / Int.ofNat g.limitY

/-- Compute `(targetOffsetY, grabOffsetSub)` for a pointer press at `(px, py)` inside `g.trackRectSub`:
- On the thumb: keeps `currentOffsetY` (clamped) and anchors `grabOffsetSub = py - thumbY`.
- On the track above/below the thumb: jumps thumb center to `py` (clamped to `[0, limitY]`)
  and anchors `grabOffsetSub` at the jumped thumb top so holding and dragging works seamlessly. -/
def pointerPress (g : ScrollbarGeometry) (currentOffsetY : SubPx) (px py : Int) : SubPx × Int :=
  if g.thumbHitRectSub.contains px py then
    (min g.limitY currentOffsetY, py - g.thumbRectSub.y)
  else
    let desiredTop := py - g.thumbRectSub.h / 2
    let nextOff := g.offsetForThumbTop desiredTop
    let jumpedTop := g.thumbTopForOffset nextOff
    (nextOff, py - jumpedTop)

end ScrollbarGeometry

/-- Device-pixel distance a node may paint above or below its layout box: shadows (offset,
spread and blur support), plus a scale-aware allowance for focus rings, glyph overhang and
tree rails, which all stay within a few logical pixels of the box. -/
def nodeInkOverhangY (scale120 : Nat) (style : BoxStyle) (payload : WidgetPayload) : Int :=
  let shadowExt (sh : ShadowStyle) : Int :=
    (if sh.offsetY < 0 then -sh.offsetY else sh.offsetY) + max 0 sh.spread + 2 * (sh.blur : Int)
  let sub : Int :=
    (if style.shadow.isVisible then shadowExt style.shadow else 0) +
    (match payload with | .shadow sh _ => shadowExt sh | _ => 0)
  Int.ofNat (scaleSubPx scale120 (pxToSub 48)) + (roundDev scale120 sub)

/-- True when neither `box` nor any descendant can paint or hit-test inside the vertical span
of `clipDev`: every prim they emit would be scissored away by an ancestor clip. -/
partial def subtreeOutsideClipY (scale120 : Nat) (clipDev : Rect) : WidgetNode → ComputedBox → Bool
  | .mk _ _ _ style payload children, box =>
    let m := nodeInkOverhangY scale120 style payload
    let r := box.rectDev
    (r.y + r.h + m ≤ clipDev.y || r.y - m ≥ clipDev.y + clipDev.h) &&
      (children.zip box.children).all fun (w, b) => subtreeOutsideClipY scale120 clipDev w b

/-- Tab order of a subtree, identical to what lowering it would produce. -/
partial def subtreeFocusOrder (focusState : FocusState) : WidgetNode → ComputedBox → List WidgetId
  | .mk id focusable _ _ _ children, box =>
    let self := match id with
      | some wid => if focusable && focusState.admits wid then [wid] else []
      | none => []
    self ++ (children.zip box.children).flatMap fun (w, b) => subtreeFocusOrder focusState w b

/-- Lower a widget node and its paired `ComputedBox` into balanced `Prim` list, focusable tab order, and hit regions. -/
def lowerWidgetPair (scale120 : Nat) (focusState : FocusState) (theme : Theme)
    (clipSub : Option Rect) (clipDev : Option Rect) (focusVisible : Bool := true) :
    WidgetNode → ComputedBox →
    List Prim × List WidgetId × List (WidgetId × Rect) × List (WidgetId × Rect)
  | .mk id focusable hitTestable style payload children, box =>
    let effOpacity : Nat :=
      match payload with
      | .opacityLayer op => min 255 op
      | _ => min 255 style.opacity
    let needsLayer := effOpacity < 255
    let roundedRadii : Option CornerRadii :=
      match payload with
      | .roundedClip r => some r
      | _ => if style.clipRounded then some style.radii else none
    let needsRoundedClip := roundedRadii.isSome
    let needsRectClip := !needsRoundedClip && (style.clip || (match payload with | .scrollClip _ => true | _ => false))
    let clipTargetSub := if (match payload with | .scrollClip _ => true | _ => false) then box.contentRectSub else box.rectSub
    let clipTargetDev := if (match payload with | .scrollClip _ => true | _ => false) then box.contentRectDev else box.rectDev
    let nextClipSub :=
      if needsRoundedClip || needsRectClip then
        match clipSub with
        | none => some clipTargetSub
        | some c => some (intersectRect c clipTargetSub)
      else clipSub
    let nextClipDev :=
      if needsRoundedClip || needsRectClip then
        match clipDev with
        | none => some clipTargetDev
        | some c => some (intersectRect c clipTargetDev)
      else clipDev
    let layerPushPrims : List Prim := if needsLayer then [.layerPush effOpacity] else []
    let layerPopPrims : List Prim := if needsLayer then [.layerPop] else []
    let clipPushPrims : List Prim :=
      match roundedRadii with
      | some r => [.clipPushRounded clipTargetDev (r.toDevTuple scale120)]
      | none => if needsRectClip then [.clipPush clipTargetDev] else []
    let clipPopPrims : List Prim :=
      if needsRoundedClip || needsRectClip then [.clipPop] else []
    let selfBoxPrims := emitBoxStylePrims scale120 box.rectDev style
    let selfPayloadPrims := emitPayloadPrims scale120 focusState box payload
    let (childPrims, childFocusOrder, childHitsSub, childHitsDev) :=
      lowerWidgetChildren scale120 focusState theme nextClipSub nextClipDev focusVisible children box.children
    -- Cursor-style quiet focus (`AGENTS.md`): buttons/pills/dropdowns/tabs show `focusRing`
    -- only on keyboard `:focus-visible`; bordered text inputs step their 1px border while
    -- borderless text inputs (e.g. search bar `701`) rely on their vertical text caret.
    let showFocusRing : Bool :=
      nodeShowsFocusRing id style payload focusState focusVisible
    let focusRadius : SubPx :=
      match payload with
      | .rrect _ radii _ => radii.topLeft
      | .roundedClip radii => radii.topLeft
      | _ => style.radii.topLeft
    -- `Kernel.focusBorder`, following the corner radius of the widget it outlines.
    let focusPrim : List Prim :=
      if focusable || showFocusRing then
        [match focusBorder showFocusRing box.rectDev theme.palette.focusRing with
          | .quad r fill _ bw col => .quad r fill (scaleSubPx scale120 focusRadius) bw col
          | p => p]
      else []
    let selfFocusOrder : List WidgetId :=
      match id with
      | some wid => if focusable && focusState.admits wid then [wid] else []
      | none => []
    let selfHitSub : List (WidgetId × Rect) :=
      match id with
      | some wid =>
        if focusable || hitTestable then
          let hitR := match clipSub with
            | none => box.rectSub
            | some c => intersectRect c box.rectSub
          if hitR.isEmpty then [] else [(wid, hitR)]
        else []
      | none => []
    let selfHitDev : List (WidgetId × Rect) :=
      match id with
      | some wid =>
        if focusable || hitTestable then
          let hitR := match clipDev with
            | none => box.rectDev
            | some c => intersectRect c box.rectDev
          if hitR.isEmpty then [] else [(wid, hitR)]
        else []
      | none => []
    let scrollbarPrims : List Prim :=
      match payload, box.scrollLimitXY with
      | .scrollClip sc, some (_, limitY) =>
        if !sc.showScrollbar then [] else
        match scrollbarGeometry box.contentRectSub limitY (box.scrollOffset.getD (0, 0)).2 with
        | none => []
        | some geom =>
          let thumbDev := roundRect scale120 geom.thumbRectSub
          let alpha : Nat := (if theme.isDark then 0x38 else 0x30) * min 255 sc.scrollbarOpacity / 255
          let thumbCol : Color := (if theme.isDark then 0xFFFFFF00 else 0x00000000) ||| alpha.toUInt32
          if alpha == 0 then [] else
          [Prim.quad thumbDev thumbCol (scaleSubPx scale120 (pxToSub 3)) 0 0]
      | _, _ => []
    let allPrims :=
      layerPushPrims ++
        selfBoxPrims ++
        clipPushPrims ++
        (match payload with
         | .iconMask _ _ _ (some _) => childPrims ++ selfPayloadPrims
         | _ => selfPayloadPrims ++ childPrims) ++
        scrollbarPrims ++
        clipPopPrims ++
        focusPrim ++
        layerPopPrims
    (allPrims,
     selfFocusOrder ++ childFocusOrder,
     selfHitSub ++ childHitsSub,
     selfHitDev ++ childHitsDev)
where
  lowerWidgetChildren (scale120 : Nat) (focusState : FocusState) (theme : Theme)
      (clipSub : Option Rect) (clipDev : Option Rect) (focusVisible : Bool) :
      List WidgetNode → List ComputedBox →
      List Prim × List WidgetId × List (WidgetId × Rect) × List (WidgetId × Rect)
    | [], _ => ([], [], [], [])
    | _, [] => ([], [], [], [])
    | w :: ws, b :: bs =>
      -- Rows scrolled out of a clipped viewport emit nothing visible and no hit regions:
      -- skip lowering them (keeping their tab order) instead of emitting prims to scissor away.
      let culled := match clipDev with
        | some c => subtreeOutsideClipY scale120 c w b
        | none => false
      let (p1, f1, hs1, hd1) :=
        if culled then ([], subtreeFocusOrder focusState w b, [], [])
        else lowerWidgetPair scale120 focusState theme clipSub clipDev focusVisible w b
      let (p2, f2, hs2, hd2) := lowerWidgetChildren scale120 focusState theme clipSub clipDev focusVisible ws bs
      (p1 ++ p2, f1 ++ f2, hs1 ++ hs2, hd1 ++ hd2)

/-- Lower a laid-out widget tree (`WidgetNode` + `ComputedBox`) into a `SceneOutput`. -/
def buildSceneFromLayout (scale120 : Nat) (focusState : FocusState) (theme : Theme)
    (rootWidget : WidgetNode) (rootBox : ComputedBox) (recordNodes := true)
    (focusVisible : Bool := true) : SceneOutput :=
  let (primsList, focusOrder, hitsSub, hitsDev) :=
    lowerWidgetPair scale120 focusState theme none none focusVisible rootWidget rootBox
  let dmg := Damage.add none rootBox.damageRectDev
  { prims := primsList.toArray,
    focusableOrder := focusOrder,
    hitRegionsSub := hitsSub,
    hitRegionsDev := hitsDev,
    boundsDamage := dmg,
    nodeRecords := if recordNodes then collectNodeRecords focusState focusVisible rootWidget rootBox else #[] }

/-- Perform layout and scene lowering in one pure pass from a declarative `WidgetNode` root. -/
def renderWidgetTree (scale120 : Nat) (availW availH : SubPx)
    (focusState : FocusState) (theme : Theme) (rootWidget : WidgetNode)
    (focusVisible : Bool := true) :
    ComputedBox × SceneOutput :=
  let layoutRoot := rootWidget.toLayoutNode
  let rootBox := layoutNode scale120 focusState.owner theme.palette.focusRing 0 0 availW availH layoutRoot
  let sceneOut := buildSceneFromLayout scale120 focusState theme rootWidget rootBox (focusVisible := focusVisible)
  (rootBox, sceneOut)

/-- Hit-test a `SceneOutput` at `(x, y)` (in logical `SubPx` coordinates) using `Kernel.hitTest`. -/
@[inline] def SceneOutput.hitTest (s : SceneOutput) (x y : Int32) : Option WidgetId :=
  LeanUI.hitTest s.hitRegionsSub x.toInt y.toInt

/-- Hit-test a `SceneOutput` at device-pixel coordinates `(x, y)` using `Kernel.hitTest`. -/
@[inline] def SceneOutput.hitTestDev (s : SceneOutput) (x y : Int32) : Option WidgetId :=
  LeanUI.hitTest s.hitRegionsDev x.toInt y.toInt

/-- Compute minimal focus-transition damage between `beforeOwner` and `afterOwner` across laid-out boxes. -/
def collectFocusDamage (beforeOwner afterOwner : Option WidgetId) : ComputedBox → Damage
  | .mk id _ _ _ _ _ damageRectDev _ _ _ _ children =>
    let selfDmg : Damage :=
      match id with
      | some wid =>
        let wasFocused := beforeOwner == some wid
        let nowFocused := afterOwner == some wid
        focusBorderDamage wasFocused nowFocused damageRectDev
      | none => none
    let childDmg := collectChildrenFocusDamage beforeOwner afterOwner children
    match selfDmg, childDmg with
    | none, d => d
    | some r, none => Damage.add none r
    | some r1, some r2 => Damage.add (Damage.add none r1) r2
where
  collectChildrenFocusDamage (beforeOwner afterOwner : Option WidgetId) : List ComputedBox → Damage
    | [] => none
    | c :: cs =>
      let d1 := collectFocusDamage beforeOwner afterOwner c
      let d2 := collectChildrenFocusDamage beforeOwner afterOwner cs
      match d1, d2 with
      | none, d => d
      | some r, none => Damage.add none r
      | some r1, some r2 => Damage.add (Damage.add none r1) r2

/-- Advance keyboard focus forward (`reverse = false`) or backward (`reverse = true`) in `focusableOrder`. -/
def cycleFocus (focusState : FocusState) (focusableOrder : List WidgetId) (reverse : Bool := false) : FocusState :=
  let order := if reverse then focusableOrder.reverse else focusableOrder
  let admitted := order.filter focusState.admits
  match admitted with
  | [] => focusState
  | first :: _ =>
    match focusState.owner with
    | none => focusState.request first
    | some cur =>
      let rec findNext : List WidgetId → Option WidgetId
        | [] => none
        | [x] => if x == cur then some first else none
        | x :: y :: rest => if x == cur then some y else findNext (y :: rest)
      let target := (findNext admitted).getD first
      focusState.request target

end LeanUI
