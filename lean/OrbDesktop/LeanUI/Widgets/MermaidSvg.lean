import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
/-!
# LeanUI.Widgets.MermaidSvg — Native Diagram & Vector Tile Widget (`0` FFI)

Pure native diagram and vector-tile widget supporting:
- `DiagramNode`, `DiagramEdge`, and `SvgPathCmd` (`moveTo`, `lineTo`, `quadTo`, `cubicTo`, `closePath`)
- Directed Sugiyama-style layered rank/column layout in `SubPx`
- Rounded box/pill/diamond diagram nodes, orthogonal connector segments, arrowheads, and edge labels
  lowered directly into declarative `WidgetNode`s.
-/
namespace LeanUI.Widgets

/-- 2D vector path commands in logical `SubPx` coordinates. -/
inductive SvgPathCmd where
  | moveTo (x y : Int)
  | lineTo (x y : Int)
  | quadTo (cx cy x y : Int)
  | cubicTo (c1x c1y c2x c2y x y : Int)
  | closePath
  deriving DecidableEq, Repr, Inhabited

/-- Visual shape of a diagram node. -/
inductive DiagramNodeShape where
  | rect
  | rounded
  | pill
  | diamond
  deriving DecidableEq, Repr, Inhabited

/-- A node in a Mermaid / directed graph diagram. -/
structure DiagramNode where
  id : Nat
  label : String
  rank : Nat := 0
  column : Nat := 0
  shape : DiagramNodeShape := .rounded
  accentColor : Option Color := none
  widgetId : Option WidgetId := none
  deriving DecidableEq, Repr, Inhabited

/-- A directed edge between two `DiagramNode`s. -/
structure DiagramEdge where
  fromId : Nat
  toId : Nat
  label : String := ""
  dashed : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Direction of layered Sugiyama graph layout. -/
inductive DiagramDirection where
  | topDown
  | leftRight
  deriving DecidableEq, Repr, Inhabited

/-- Complete specification of a native Mermaid diagram. -/
structure DiagramSpec where
  title : String := ""
  direction : DiagramDirection := .leftRight
  nodes : List DiagramNode := []
  edges : List DiagramEdge := []
  svgPaths : List SvgPathCmd := []
  nodeWidthSub : SubPx := pxToSub 136
  nodeHeightSub : SubPx := pxToSub 40
  rankGapSub : SubPx := pxToSub 44
  columnGapSub : SubPx := pxToSub 20
  deriving Repr, Inhabited

/-- Positioned diagram node in `SubPx` after Sugiyama rank/column assignment. -/
structure PositionedDiagramNode where
  node : DiagramNode
  xSub : SubPx
  ySub : SubPx
  wSub : SubPx
  hSub : SubPx
  deriving DecidableEq, Repr, Inhabited

/-- Deterministic fallback `InlineRun` synthesizer for diagram node & edge labels. -/
@[inline] def diagramSynthRun (style : TextStyle) (text : String) : InlineRun :=
  let charAdv : SubPx := max (6 * subPerPx) (style.sizeSub / 2)
  let glyphs : List ShapedGlyph :=
    text.toList.mapIdx fun idx c => {
      glyphId := c.toNat
      cluster := idx
      xAdvance := charAdv
    }
  { glyphs := glyphs, style := style, allowBreakAfter := false, hardBreakAfter := false }

/-- Compute the Sugiyama-style layered `(xSub, ySub, wSub, hSub)` coordinates for every `DiagramNode`. -/
def layoutDiagramNodes (spec : DiagramSpec) : List PositionedDiagramNode :=
  spec.nodes.map fun n =>
    let (x, y) :=
      match spec.direction with
      | .leftRight =>
        (n.rank * (spec.nodeWidthSub + spec.rankGapSub),
         n.column * (spec.nodeHeightSub + spec.columnGapSub))
      | .topDown =>
        (n.column * (spec.nodeWidthSub + spec.columnGapSub),
         n.rank * (spec.nodeHeightSub + spec.rankGapSub))
    { node := n
      xSub := x
      ySub := y
      wSub := spec.nodeWidthSub
      hSub := spec.nodeHeightSub }

/-- Convert a `DiagramEdge` between two `PositionedDiagramNode`s into orthogonal `SvgPathCmd` segments. -/
def edgeToSvgPath (dir : DiagramDirection) (src dst : PositionedDiagramNode) : List SvgPathCmd :=
  match dir with
  | .leftRight =>
    let sx := Int.ofNat (src.xSub + src.wSub)
    let sy := Int.ofNat (src.ySub + src.hSub / 2)
    let dx := Int.ofNat dst.xSub
    let dy := Int.ofNat (dst.ySub + dst.hSub / 2)
    let midX := (sx + dx) / 2
    [.moveTo sx sy, .lineTo midX sy, .lineTo midX dy, .lineTo dx dy]
  | .topDown =>
    let sx := Int.ofNat (src.xSub + src.wSub / 2)
    let sy := Int.ofNat (src.ySub + src.hSub)
    let dx := Int.ofNat (dst.xSub + dst.wSub / 2)
    let dy := Int.ofNat dst.ySub
    let midY := (sy + dy) / 2
    [.moveTo sx sy, .lineTo sx midY, .lineTo dx midY, .lineTo dx dy]

/-- Collect all orthogonal `SvgPathCmd` commands for a `DiagramSpec` (explicit `svgPaths` + routed edges). -/
def collectDiagramSvgPaths (spec : DiagramSpec) : List SvgPathCmd :=
  let positioned := layoutDiagramNodes spec
  let edgePaths : List SvgPathCmd :=
    spec.edges.foldl (fun acc e =>
      let srcOpt := positioned.find? (fun p => p.node.id == e.fromId)
      let dstOpt := positioned.find? (fun p => p.node.id == e.toId)
      match srcOpt, dstOpt with
      | some s, some d => acc ++ edgeToSvgPath spec.direction s d
      | _, _ => acc) []
  spec.svgPaths ++ edgePaths

/-- Build a declarative `WidgetNode` for a single `DiagramNode`. -/
def buildDiagramNodeBox (theme : Theme) (nodeW nodeH : SubPx) (n : DiagramNode) : WidgetNode :=
  let pal := theme.palette
  let borderCol := n.accentColor.getD pal.accent
  let radius : SubPx :=
    match n.shape with
    | .rect    => pxToSub 2
    | .rounded => theme.radiusMd
    | .pill    => nodeH / 2
    | .diamond => theme.radiusSm
  let labelStyle : TextStyle := { (Theme.codeText theme) with weight := 600, color := pal.textPrimary }
  let rawBox : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .center
        |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 6))
        |>.withFixedSize nodeW nodeH)
      pal.surface
      (CornerRadii.uniform radius)
      (BorderStyle.uniform (pxToSub 2) borderCol)
      [WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (nodeW - pxToSub 20) (pxToSub 18))
        theme.typo.lineTight
        [diagramSynthRun labelStyle n.label]]
      n.widgetId
  match n.widgetId with
  | some wid => WidgetNode.focusable wid rawBox
  | none => rawBox

/-- Build an orthogonal connector segment + arrowhead between two consecutive rank layers. -/
def buildOrthogonalConnectorWidget (theme : Theme) (connW connH : SubPx) (label : String) : WidgetNode :=
  let pal := theme.palette
  let lineCol := pal.textSecondary
  let arrowHeadW : SubPx := pxToSub 6
  let shaftW : SubPx := connW - arrowHeadW
  let shaft : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0 |>.withFixedSize shaftW (pxToSub 2))
      lineCol
      CornerRadii.zero
  let arrowTip : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0 |>.withFixedSize arrowHeadW (pxToSub 6))
      pal.accent
      (CornerRadii.uniform (pxToSub 1))
  let arrowRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize connW (pxToSub 10))
      [shaft, arrowTip]
  if label.isEmpty then
    WidgetNode.box
      (BoxStyle.col 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize connW connH)
      [arrowRow]
  else
    let lblStyle := Theme.mutedText theme
    let lblNode : WidgetNode :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize connW (pxToSub 14))
        theme.typo.lineTight
        [diagramSynthRun lblStyle label]
    WidgetNode.box
      (BoxStyle.col (pxToSub 2) |>.withAlign .center |>.withJustify .center |>.withFixedSize connW connH)
      [lblNode, arrowRow]

/-- Extract sorted distinct ranks present in `nodes`. -/
def distinctRanks (nodes : List DiagramNode) : List Nat :=
  let maxRank := nodes.foldl (fun acc n => max acc n.rank) 0
  (List.range (maxRank + 1)).filter fun r => nodes.any (fun n => n.rank == r)

/-- Build a complete Mermaid / SVG diagram widget in `SubPx` using Sugiyama rank columns
and orthogonal connector widgets. -/
def buildMermaidDiagramWidget (theme : Theme) (availW : SubPx) (spec : DiagramSpec) : WidgetNode :=
  let pal := theme.palette
  let ranks := distinctRanks spec.nodes
  let maxColCount :=
    ranks.foldl (fun acc r => max acc (spec.nodes.filter (fun n => n.rank == r)).length) 1
  let bodyH : SubPx :=
    max (spec.nodeHeightSub + pxToSub 24)
      (maxColCount * spec.nodeHeightSub + (maxColCount - 1) * spec.columnGapSub + pxToSub 24)
  let headerH : SubPx := if spec.title.isEmpty then 0 else pxToSub 28
  let totalH : SubPx := headerH + bodyH + pxToSub 16

  let rec buildRankInterleaved : List Nat → List WidgetNode
    | [] => []
    | [r] =>
      let colNodes := spec.nodes.filter (fun n => n.rank == r)
      let colWidgets := colNodes.map (buildDiagramNodeBox theme spec.nodeWidthSub spec.nodeHeightSub)
      [WidgetNode.box
        (BoxStyle.col spec.columnGapSub |>.withJustify .center |>.withFixedSize spec.nodeWidthSub (bodyH - pxToSub 16))
        colWidgets]
    | r :: rNext :: rest =>
      let colNodes := spec.nodes.filter (fun n => n.rank == r)
      let colWidgets := colNodes.map (buildDiagramNodeBox theme spec.nodeWidthSub spec.nodeHeightSub)
      let rankCol :=
        WidgetNode.box
          (BoxStyle.col spec.columnGapSub |>.withJustify .center |>.withFixedSize spec.nodeWidthSub (bodyH - pxToSub 16))
          colWidgets
      let edgeLabel :=
        match spec.edges.find? (fun e =>
          colNodes.any (fun n => n.id == e.fromId)) with
        | some e => e.label
        | none => ""
      let connCol :=
        buildOrthogonalConnectorWidget theme spec.rankGapSub (bodyH - pxToSub 16) edgeLabel
      rankCol :: connCol :: buildRankInterleaved (rNext :: rest)

  let graphColumns := buildRankInterleaved ranks
  let graphCanvas : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.all (pxToSub 12))
        |>.withFixedSize (availW - pxToSub 8) bodyH)
      graphColumns

  let children : List WidgetNode :=
    if spec.title.isEmpty then
      [graphCanvas]
    else
      let titleStyle := Theme.secondaryText theme
      let titleBar :=
        WidgetNode.box
          (BoxStyle.row 0
            |>.withAlign .center
            |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 4))
            |>.withFixedSize (availW - pxToSub 8) headerH)
          [WidgetNode.text
            (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 32) (pxToSub 18))
            theme.typo.lineTight
            [diagramSynthRun titleStyle spec.title]]
      [titleBar, graphCanvas]

  WidgetNode.rrect
    (BoxStyle.col 0
      |>.withPadding (Edges.all (pxToSub 4))
      |>.withFixedSize availW totalH)
    pal.elevatedSurface
    (CornerRadii.uniform theme.radiusMd)
    (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
    children

end LeanUI.Widgets
