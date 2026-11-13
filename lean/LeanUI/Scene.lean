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

/-- Visual payload carried by a declarative `WidgetNode`. -/
inductive WidgetPayload where
  | container
  | rrect (fill : Color) (radii : CornerRadii) (border : BorderStyle)
  | shadow (shadow : ShadowStyle) (radius : SubPx)
  | linearGradient (c0 c1 : Color) (angleDeg : Nat) (radius : SubPx)
  | text (lineHeightSub : SubPx) (runs : List InlineRun)
  | iconMask (page : Nat) (src : Rect) (color : Color)
  | image (tex : Nat) (src : Rect) (radius : SubPx)
  | scrollClip (scroll : ScrollSpec)
  | roundedClip (radii : CornerRadii)
  | opacityLayer (opacity : Nat)
  deriving Repr, Inhabited

/-- High-level declarative UI widget / scene node. -/
inductive WidgetNode where
  | mk
    (id : Option WidgetId)
    (focusable : Bool)
    (hitTestable : Bool)
    (style : BoxStyle)
    (payload : WidgetPayload)
    (children : List WidgetNode)
  deriving Repr, Inhabited

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
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome style (.text lineHeightSub runs) []

/-- Declarative coverage-mask icon / vector glyph widget builder. -/
@[inline] def icon (style : BoxStyle) (page : Nat) (src : Rect) (color : Color)
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome style (.iconMask page src color) []

/-- Declarative RGBA texture image widget builder. -/
@[inline] def image (style : BoxStyle) (tex : Nat) (src : Rect) (radius : SubPx := 0)
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false id.isSome style (.image tex src radius) []

/-- Declarative scrollable clip region widget builder. -/
@[inline] def scrollClip (style : BoxStyle) (scroll : ScrollSpec) (child : WidgetNode)
    (id : Option WidgetId := none) : WidgetNode :=
  .mk id false true ({ style with clip := true }) (.scrollClip scroll) [child]

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
    | .text lineHeightSub runs =>
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
    emitLineGlyphs scale120 originXSub originYSub line.glyphs ++
      emitWrappedLineGlyphs scale120 originXSub originYSub rest
where
  emitLineGlyphs (scale120 : Nat) (originXSub originYSub : Int) :
      List PositionedGlyph → List Prim
    | [] => []
    | pg :: pgs =>
      let gxSub := originXSub + Int.ofNat pg.relX + pg.glyph.xOffset
      let gySub := originYSub + Int.ofNat pg.relY + pg.glyph.yOffset
      let devX := roundDev scale120 gxSub + pg.glyph.bearingPx.1
      let devY := roundDev scale120 gySub - pg.glyph.bearingPx.2
      let (gw, gh) := pg.glyph.sizePx
      let dst : Rect :=
        if gw > 0 && gh > 0 then
          { x := devX, y := devY, w := Int.ofNat gw, h := Int.ofNat gh }
        else
          roundRect scale120
            { x := gxSub, y := gySub,
              w := Int.ofNat (max 1 pg.glyph.xAdvance),
              h := Int.ofNat (max 1 subPerPx) }
      Prim.glyph pg.glyph.atlasSrc dst pg.color pg.glyph.isColor ::
        emitLineGlyphs scale120 originXSub originYSub pgs

/-- Emit payload-specific primitives for a single laid-out node. -/
def emitPayloadPrims (scale120 : Nat) (box : ComputedBox) : WidgetPayload → List Prim
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
  | .text _ _ =>
    emitWrappedLineGlyphs scale120 box.contentRectSub.x box.contentRectSub.y box.lines
  | .iconMask page src color =>
    [.mask page src box.contentRectDev color]
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

/-- Output of lowering a laid-out widget tree into a Z-ordered `Scene` (`Array Prim`), tab order, and hit regions. -/
structure SceneOutput where
  prims : Scene
  focusableOrder : List WidgetId
  hitRegionsSub : List (WidgetId × Rect)
  hitRegionsDev : List (WidgetId × Rect)
  boundsDamage : Damage
  deriving Repr, Inhabited

/-- Lower a widget node and its paired `ComputedBox` into balanced `Prim` list, focusable tab order, and hit regions. -/
def lowerWidgetPair (scale120 : Nat) (focusState : FocusState) (theme : Theme)
    (clipSub : Option Rect) (clipDev : Option Rect) :
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
    let selfPayloadPrims := emitPayloadPrims scale120 box payload
    let (childPrims, childFocusOrder, childHitsSub, childHitsDev) :=
      lowerWidgetChildren scale120 focusState theme nextClipSub nextClipDev children box.children
    let isFocused := match id, focusState.owner with
      | some wid, some owner => wid == owner
      | _, _ => false
    let focusPrim : List Prim :=
      if focusable || isFocused then
        [focusBorder isFocused box.rectDev theme.palette.focusRing]
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
    let allPrims :=
      layerPushPrims ++
        selfBoxPrims ++
        clipPushPrims ++
        selfPayloadPrims ++
        childPrims ++
        clipPopPrims ++
        focusPrim ++
        layerPopPrims
    (allPrims,
     selfFocusOrder ++ childFocusOrder,
     selfHitSub ++ childHitsSub,
     selfHitDev ++ childHitsDev)
where
  lowerWidgetChildren (scale120 : Nat) (focusState : FocusState) (theme : Theme)
      (clipSub : Option Rect) (clipDev : Option Rect) :
      List WidgetNode → List ComputedBox →
      List Prim × List WidgetId × List (WidgetId × Rect) × List (WidgetId × Rect)
    | [], _ => ([], [], [], [])
    | _, [] => ([], [], [], [])
    | w :: ws, b :: bs =>
      let (p1, f1, hs1, hd1) := lowerWidgetPair scale120 focusState theme clipSub clipDev w b
      let (p2, f2, hs2, hd2) := lowerWidgetChildren scale120 focusState theme clipSub clipDev ws bs
      (p1 ++ p2, f1 ++ f2, hs1 ++ hs2, hd1 ++ hd2)

/-- Lower a laid-out widget tree (`WidgetNode` + `ComputedBox`) into a `SceneOutput`. -/
def buildSceneFromLayout (scale120 : Nat) (focusState : FocusState) (theme : Theme)
    (rootWidget : WidgetNode) (rootBox : ComputedBox) : SceneOutput :=
  let (primsList, focusOrder, hitsSub, hitsDev) :=
    lowerWidgetPair scale120 focusState theme none none rootWidget rootBox
  let dmg := Damage.add none rootBox.damageRectDev
  { prims := primsList.toArray,
    focusableOrder := focusOrder,
    hitRegionsSub := hitsSub,
    hitRegionsDev := hitsDev,
    boundsDamage := dmg }

/-- Perform layout and scene lowering in one pure pass from a declarative `WidgetNode` root. -/
def renderWidgetTree (scale120 : Nat) (availW availH : SubPx)
    (focusState : FocusState) (theme : Theme) (rootWidget : WidgetNode) :
    ComputedBox × SceneOutput :=
  let layoutRoot := rootWidget.toLayoutNode
  let rootBox := layoutNode scale120 focusState.owner theme.palette.focusRing 0 0 availW availH layoutRoot
  let sceneOut := buildSceneFromLayout scale120 focusState theme rootWidget rootBox
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
