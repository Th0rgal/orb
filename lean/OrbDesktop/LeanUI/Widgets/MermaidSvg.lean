import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Text
import LeanUI.Scene
/-!
# LeanUI.Widgets.MermaidSvg — Native Diagram & Vector Tile Widget (`0` FFI)

Pure native diagram and vector-tile widget supporting:
- `DiagramNode`, `DiagramEdge`, and `SvgPathCmd` (`moveTo`, `lineTo`, `quadTo`, `cubicTo`, `closePath`)
- Directed Sugiyama-style layered rank/column layout in `SubPx`
- Rounded box/pill nodes, stroked rhombus decision nodes sized to the node rectangle,
  orthogonal connector segments, arrowheads, and edge labels
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

/-! ## Mermaid flowchart parsing (`graph` / `flowchart` subset)

Pure line-based parser for fenced ```mermaid transcript blocks. Supported: `graph LR|TD|TB`
and `flowchart LR|TD|TB` headers, node references with `[label]` / `(label)` / `{label}`
shapes, `-->` edges with optional `|label|` annotations, chained statements on one line and
standalone node declarations. Anything else fails closed (`none`); callers fall back to
plain text. Ranks use layered peeling with cycle cutting, so they stay bounded by the
node count and a cycle can neither inflate them nor destabilize the layout. -/

/-- Mermaid node reference: identifier plus optional display label and shape. -/
private structure MermaidRef where
  id : String
  label : Option String := none
  shape : Option DiagramNodeShape := none

private def isMermaidSpace (c : Char) : Bool := c == ' ' || c == '\t'

private def isMermaidIdentChar (c : Char) : Bool :=
  c.isAlpha || c.isDigit || c == '_' || c == '-'

/-- Trim spaces and tabs (the prelude-only `LeanUI` environment has no `String.trim`). -/
def mermaidTrim (s : String) : String :=
  String.ofList (((s.toList.dropWhile isMermaidSpace).reverse.dropWhile isMermaidSpace).reverse)

/-- Parse one node reference: `Id`, `Id[label]`, `Id(label)` or `Id{label}`. -/
private def parseMermaidRef (raw : String) : Option MermaidRef :=
  let s := (mermaidTrim raw).toList
  match s.findIdx? fun c => c == '[' || c == '(' || c == '{' with
  | none =>
    if s.isEmpty || !(s.all isMermaidIdentChar) then none else some { id := String.ofList s }
  | some idx =>
    let idPart := s.take idx
    let opener := s[idx]!
    let closer : Char := match opener with
      | '[' => ']'
      | '(' => ')'
      | _ => '}'
    let shape : DiagramNodeShape := match opener with
      | '[' => .rounded
      | '(' => .pill
      | _ => .diamond
    if idPart.isEmpty || !(idPart.all isMermaidIdentChar) || s.getLast? != some closer then none
    else
      some { id := String.ofList idPart
             label := some (mermaidTrim (String.ofList (((s.drop (idx + 1)).reverse.drop 1).reverse)))
             shape := some shape }

/-- Parse one statement line into its source ref and successive `-->` targets with optional
`|label|` edge labels; a line without `-->` declares a standalone node. -/
private def parseMermaidStmt (line : String) : Option (MermaidRef × List (String × MermaidRef)) :=
  match line.splitOn "-->" with
  | [] => none
  | srcSeg :: rest => do
    let src ← parseMermaidRef srcSeg
    let targets ← rest.mapM fun seg => do
      let t := mermaidTrim seg
      if t.startsWith "|" then
        match (String.ofList (t.toList.drop 1)).splitOn "|" with
        | label :: tail =>
          let ref ← parseMermaidRef (String.intercalate "|" tail)
          return (mermaidTrim label, ref)
        | [] => none
      else
        return ("", ← parseMermaidRef t)
    return (src, targets)

/-- Accumulator keeping node declaration order, last label/shape per node and all edges. -/
private structure MermaidAcc where
  order : List String := []
  labels : List (String × String) := []
  shapes : List (String × DiagramNodeShape) := []
  edges : List (String × String × String) := []

private def mermaidInsert (acc : MermaidAcc) (ref : MermaidRef) : MermaidAcc :=
  let acc := if acc.order.contains ref.id then acc else { acc with order := acc.order ++ [ref.id] }
  let acc := match ref.label with
    | some l => { acc with labels := (acc.labels.filter (·.1 != ref.id)) ++ [(ref.id, l)] }
    | none => acc
  match ref.shape with
  | some sh => { acc with shapes := (acc.shapes.filter (·.1 != ref.id)) ++ [(ref.id, sh)] }
  | none => acc

/-- Layered rank per node id via Kahn peeling with cycle cutting: each round places
the nodes whose predecessors are all placed; when only cycles remain, the first
unplaced node in declaration order is cut free at the next layer. One round per node,
so ranks stay bounded by the node count and a cycle can never inflate them. -/
private def mermaidRanks (order : List String) (edges : List (String × String × String)) :
    List (String × Nat) :=
  let predecessors (id : String) : List String := (edges.filter fun e => e.2.1 == id).map (·.1)
  (List.range order.length).foldl (fun (m : List (String × Nat)) _ =>
    let placed := m.map (·.1)
    let layer := match m with
      | [] => 0
      | _ => (m.foldl (fun acc p => max acc p.2) 0) + 1
    let fresh := order.filter fun id =>
      !(placed.contains id) && (predecessors id).all (placed.contains ·)
    match fresh with
    | [] => match order.find? fun id => !placed.contains id with
      | some cut => m ++ [(cut, layer)]
      | none => m
    | _ => m ++ fresh.map (·, layer)) []
  |> fun m => order.map fun id => (id, (m.lookup id).getD 0)

/-- Parse a Mermaid flowchart source into a `DiagramSpec`, or `none` when the subset does
not match (callers then render the text plainly). Widget ids stay unassigned: the renderer
owns the reserved widget-id band. -/
def parseMermaidFlowchart (src : String) : Option DiagramSpec := do
  let lines := (src.splitOn "\n").filterMap fun l =>
    let t := mermaidTrim l
    if t.isEmpty then none else some t
  match lines with
  | [] => none
  | header :: stmts =>
    let dir : DiagramDirection ←
      match (header.splitOn " ").filter (· != "") with
      | [kind, d] =>
        if kind == "graph" || kind == "flowchart" then
          match d with
          | "LR" => some .leftRight
          | "TD" | "TB" => some .topDown
          | _ => none
        else none
      | _ => none
    let acc ← stmts.foldlM (fun (acc : MermaidAcc) line => do
      let (src, targets) ← parseMermaidStmt line
      let acc := mermaidInsert acc src
      -- Each target chains from its preceding node, so `A --> B --> C` yields the
      -- edges A→B and B→C, never a shortcut from A to C.
      let (acc, _) := targets.foldl
        (fun (state : MermaidAcc × String) (lbl, dst) =>
          let acc := mermaidInsert state.1 dst
          ({ acc with edges := acc.edges ++ [(state.2, dst.id, lbl)] }, dst.id))
        (acc, src.id)
      pure acc) {}
    let ids := acc.order
    let ranks := mermaidRanks ids acc.edges
    let maxRank := ranks.foldl (fun acc p => max acc p.2) 0
    let colOf : List (String × Nat) := Id.run do
      let mut col : List (String × Nat) := []
      for r in [:maxRank + 1] do
        let inRank := ids.filter fun id => ranks.lookup id == some r
        col := col ++ inRank.mapIdx fun i id => (id, i)
      return col
    let nodes := ids.mapIdx fun i id =>
      ({ id := i
         label := (acc.labels.lookup id).getD id
         rank := (ranks.lookup id).getD 0
         column := (colOf.lookup id).getD 0
         shape := (acc.shapes.lookup id).getD .rounded } : DiagramNode)
    let edges := acc.edges.map fun e =>
      ({ fromId := (ids.findIdx? (· == e.1)).getD 0
         toId := (ids.findIdx? (· == e.2.1)).getD 0
         label := e.2.2 } : DiagramEdge)
    return { direction := dir, nodes := nodes, edges := edges }

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
  { glyphs := glyphs, style := style, allowBreakAfter := false, hardBreakAfter := false, isSynthetic := true }

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

/-- Mermaid decision-node outline sized to the node's actual rectangle: the icon mask
draws its square raster 1:1 and clips it to the content rect, so a wide short decision
box needs the rhombus to occupy exactly the node-height band of the view box (top apex,
right/left tips and bottom apex), with the 5.5-unit stroke inset so every tip —
including the lower one — stays inside the paint and clipping bounds. -/
def mermaidDiamondOutline (nodeW nodeH : SubPx) : List (List (Int × Int)) :=
  let tip : Int := 6
  let band : Int :=
    min (160 - 2 * tip) (max (2 * tip + 2) (Int.ofNat (160 * nodeH / max 1 nodeW)))
  let mid := band / 2
  [[(80, tip), (160 - tip, mid), (80, band - tip), (tip, mid), (80, tip)]]

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
  let label : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize (nodeW - pxToSub 20) (pxToSub 18))
      theme.typo.lineTight
      [diagramSynthRun labelStyle n.label]
  let rawBox : WidgetNode :=
    match n.shape with
    | .diamond =>
      -- Decision parity: a stroked rhombus sized to the node's actual dimensions with
      -- the label centered inside, the way mermaid.js draws `{decision}` nodes. The
      -- box carries no padding so the mask destination is the full node rect, which is
      -- exactly the band the outline occupies in the square raster.
      let runs := [diagramSynthRun labelStyle n.label]
      let (_, labelW, _) := wrapInlineRuns (nodeW - pxToSub 20) theme.typo.lineTight runs
      -- The square raster is drawn 1:1, so the historical 5.5-unit stroke would
      -- render ~9px on a 136px node. Pick the radius whose rendered weight matches
      -- the shared 2px widget border instead.
      let strokeTenths := Text.iconStrokeTenthsForPxWidth (nodeW / subPerPx)
      WidgetNode.mk none false true
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .center
          |>.withFixedSize nodeW nodeH)
        (.vectorIcon (mermaidDiamondOutline nodeW nodeH) borderCol none strokeTenths)
        [WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (min (nodeW - pxToSub 20) labelW) (pxToSub 18))
          theme.typo.lineTight runs]
    | _ =>
      WidgetNode.rrect
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .center
          |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 6))
          |>.withFixedSize nodeW nodeH)
        pal.surface
        (CornerRadii.uniform radius)
        (BorderStyle.uniform (pxToSub 2) borderCol)
        [label]
        n.widgetId
  match n.widgetId with
  | some wid => WidgetNode.focusable wid rawBox
  | none => rawBox

/-- Build an orthogonal connector segment + arrowhead between two consecutive rank layers.
The tip is a real directional chevron (round-join polyline pointing into the target
column) rasterized at the shared 2px stroke weight, and the arrow row anchors to the
connector's bottom so the caller can bottom-align the stack onto the node centers. -/
def buildOrthogonalConnectorWidget (theme : Theme) (connW connH : SubPx) (label : String) : WidgetNode :=
  let pal := theme.palette
  let lineCol := pal.textSecondary
  let arrowHeadW : SubPx := pxToSub 8
  let shaftW : SubPx := connW - arrowHeadW
  let shaft : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0 |>.withFixedSize shaftW (pxToSub 2))
      lineCol
      CornerRadii.zero
  let arrowTip : WidgetNode :=
    WidgetNode.mk none false true
      (BoxStyle.row 0 |>.withFixedSize arrowHeadW (pxToSub 8))
      (.vectorIcon [[(28, 24), (132, 80), (28, 136)]] pal.accent none
        (Text.iconStrokeTenthsForPxWidth 8))
      []
  let arrowRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize connW (pxToSub 10))
      [shaft, arrowTip]
  if label.isEmpty then
    WidgetNode.box
      (BoxStyle.col 0 |>.withJustify .end_ |>.withFixedSize connW connH)
      [arrowRow]
  else
    let lblStyle := Theme.mutedText theme
    let lblNode : WidgetNode :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize connW (pxToSub 14))
        theme.typo.lineTight
        [diagramSynthRun lblStyle label]
    WidgetNode.box
      (BoxStyle.col (pxToSub 2) |>.withJustify .end_ |>.withFixedSize connW connH)
      [lblNode, arrowRow]

/-- Extract sorted distinct ranks present in `nodes`. -/
def distinctRanks (nodes : List DiagramNode) : List Nat :=
  let maxRank := nodes.foldl (fun acc n => max acc n.rank) 0
  (List.range (maxRank + 1)).filter fun r => nodes.any (fun n => n.rank == r)

/-- Column position of a rank in the sorted distinct rank list (0 when absent). -/
private def rankPos : List Nat → Nat → Nat
  | [], _ => 0
  | r :: rest, target => if r == target then 0 else rankPos rest target + 1

/-- Canvas center x of the rank column at `pos`: the interleaved row is
`[col, conn, col, ...]` after a 12-SubPx canvas padding. -/
private def columnCenterX (nodeW rankGap : SubPx) (pos : Nat) : SubPx :=
  pxToSub 12 + pos * (nodeW + rankGap) + nodeW / 2

/-- Physically connected routing lane for a non-adjacent edge (back edge, skip
forward, self loop), drawn just below the rank rows: one continuous thin-stroke
polyline leaves the source column's bottom (a same-pen stub segment joins it
through the tip row), runs across the lane and rises into the target column's
bottom, a directional chevron sits directly on the target stub so the route
enters the target node from the lane side, and the edge label rides the lane
just below the run. The stroke radius is chosen so the rendered weight matches
the shared 2px border, so the return route reads as the same pen as the forward
connectors. -/
def buildLaneEdgeWidget (theme : Theme) (laneW laneH : SubPx)
    (xSource xTarget : SubPx) (label : String) : WidgetNode :=
  let pal := theme.palette
  let xMin := min xSource xTarget
  let xMax := max xSource xTarget
  let spanPx : Nat := (xMax - xMin) / subPerPx
  let boxW : SubPx := pxToSub (spanPx + 2)
  let tipRowH : SubPx := pxToSub 8
  let runRowH : SubPx := pxToSub 8
  let lblRowH : SubPx := pxToSub 12
  -- View-box conversion for the lane raster: it is `spanPx + 2` px square, drawn 1:1
  -- and clipped to the run row, so the visible vertical band is
  -- `160 * runRowH / (spanPx + 2)` view units and the horizontal run sits at that
  -- band's vertical center (half-up rounded so it always lands inside the visible
  -- row) with both stubs rising to the row's very top (the tip row, then the node
  -- bottoms above).
  let band : Int := max 1 (Int.ofNat ((640 + (spanPx + 2) / 2) / max 1 (spanPx + 2)))
  let uOf (x : SubPx) : Int :=
    Int.ofNat ((x - xMin + subPerPx) * 160 / max 1 boxW)
  let xs := uOf xSource
  let xt := uOf xTarget
  let strokeTenths := Text.iconStrokeTenthsForPxWidth (spanPx + 2)
  let path : List (List (Int × Int)) :=
    [[(xs, 0), (xs, band), (xt, band), (xt, 0)]]
  let lanePath : WidgetNode :=
    WidgetNode.mk none false true
      (BoxStyle.row 0 |>.withFixedSize boxW runRowH)
      (.vectorIcon path pal.textSecondary none strokeTenths)
      []
  -- Directional tip: a chevron pointing up into the target node, centered on the
  -- target column so it caps the rising stub exactly. The vector box is square
  -- (8×8, matching the raster) and the polyline reserves the stroke's full extent
  -- inside it — wings 1.4px from the side edges, ink within 0.2px of top and
  -- bottom — so neither wing is clipped by the view box.
  let laneTip : WidgetNode :=
    WidgetNode.mk none false true
      (BoxStyle.row 0 |>.withFixedSize (pxToSub 8) tipRowH)
      (.vectorIcon [[(28, 132), (80, 24), (132, 132)]] pal.accent none
        (Text.iconStrokeTenthsForPxWidth 8))
      []
  -- Source-side join: the polyline's source stub rises only to the run row's
  -- top, so the tip row above the source column carries a thin vertical stub
  -- segment of the same pen, continuing the route into the source node's bottom
  -- edge. No arrowhead on the source side — the direction stays source -> target.
  let laneStub : WidgetNode :=
    WidgetNode.mk none false true
      (BoxStyle.row 0 |>.withFixedSize (pxToSub 8) tipRowH)
      (.vectorIcon [[(80, 0), (80, 160)]] pal.textSecondary none
        (Text.iconStrokeTenthsForPxWidth 8))
      []
  let tipRow : WidgetNode :=
    if xSource == xTarget then
      -- Degenerate lane (self loop): the chevron caps the shared column.
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize laneW tipRowH)
        [WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (xTarget - pxToSub 4) tipRowH) [], laneTip]
    else if xSource < xTarget then
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize laneW tipRowH)
        [WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (xSource - pxToSub 4) tipRowH) [], laneStub,
         WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (xTarget - xSource - pxToSub 8) tipRowH) [], laneTip]
    else
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize laneW tipRowH)
        [WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (xTarget - pxToSub 4) tipRowH) [], laneTip,
         WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (xSource - xTarget - pxToSub 8) tipRowH) [], laneStub]
  let leadSpacer : WidgetNode :=
    WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (xMin - subPerPx) runRowH) []
  let runRow : WidgetNode :=
    WidgetNode.box (BoxStyle.row 0 |>.withFixedSize laneW runRowH) [leadSpacer, lanePath]
  let lblRow : WidgetNode :=
    if label.isEmpty then
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize laneW lblRowH) []
    else
      let runs := [diagramSynthRun (Theme.mutedText theme) label]
      let (_, measW, _) := wrapInlineRuns (max 1 (xMax - xMin)) theme.typo.lineTight runs
      let lblW := max 1 (min measW (max 1 (xMax - xMin)))
      let midX : SubPx := (xMin + xMax) / 2
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize laneW lblRowH)
        [WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (midX - lblW / 2) lblRowH) [],
         WidgetNode.text (BoxStyle.row 0 |>.withFixedSize lblW lblRowH) theme.typo.lineTight runs]
  WidgetNode.box (BoxStyle.col 0 |>.withFixedSize laneW laneH) [tipRow, runRow, lblRow]

/-- Build a complete Mermaid / SVG diagram widget in `SubPx` using Sugiyama rank columns
and orthogonal connector widgets. Edges between adjacent rank columns route forward, one
orthogonal connector per edge with that edge's own label; every other edge (back edge,
skip forward, self loop) routes through a physically connected lane below the columns so
no edge or label is ever dropped. Rank columns are bottom-aligned and the canvas keeps
no bottom padding, so each lane's stubs rise from the shared bottom edge into the node
rects and the return route is physically attached to both endpoints. -/
def buildMermaidDiagramWidget (theme : Theme) (availW : SubPx) (spec : DiagramSpec) : WidgetNode :=
  let pal := theme.palette
  let ranks := distinctRanks spec.nodes
  let maxColCount :=
    ranks.foldl (fun acc r => max acc (spec.nodes.filter (fun n => n.rank == r)).length) 1
  -- Intrinsic height of the tallest rank column; every column and connector band is
  -- bottom-aligned within it so lane stubs can rise from the shared bottom edge.
  let colsH : SubPx :=
    max spec.nodeHeightSub
      (maxColCount * spec.nodeHeightSub + (maxColCount - 1) * spec.columnGapSub)
  -- Distance from the column bottom to a connector's arrow row: the arrow's center
  -- lands exactly on the (bottom-aligned) node centers.
  let bandPad : SubPx := spec.nodeHeightSub / 2 - pxToSub 5
  let canvasH : SubPx := colsH + pxToSub 12
  let headerH : SubPx := if spec.title.isEmpty then 0 else pxToSub 28
  -- Resolve every edge to its endpoints' rank positions; adjacent columns route
  -- forward, everything else routes through a lane below the rank rows.
  let resolved : List (DiagramEdge × Nat × Nat) := spec.edges.filterMap fun e => do
    let s ← spec.nodes.find? (fun n => n.id == e.fromId)
    let t ← spec.nodes.find? (fun n => n.id == e.toId)
    some (e, rankPos ranks s.rank, rankPos ranks t.rank)
  let laneEdges := resolved.filter (fun (_, ps, pt) => pt != ps + 1)
  let laneH : SubPx := laneEdges.length * pxToSub 28
  let totalH : SubPx := headerH + canvasH + laneH + pxToSub 8

  let buildConnBand (pos : Nat) : WidgetNode :=
    match resolved.filter (fun (_, ps, pt) => ps == pos && pt == pos + 1) with
    | [] => WidgetNode.box
        (BoxStyle.row 0 |>.withFixedSize spec.rankGapSub colsH) []
    | edges =>
      let each :=
        ((colsH - bandPad) - pxToSub 4 * (edges.length - 1)) / edges.length
      WidgetNode.box
        (BoxStyle.col (pxToSub 4) |>.withJustify .end_
          |>.withPadding { top := 0, right := 0, bottom := bandPad, left := 0 }
          |>.withFixedSize spec.rankGapSub colsH)
        (edges.map fun (e, _, _) =>
          buildOrthogonalConnectorWidget theme spec.rankGapSub each e.label)

  let rec buildRankInterleaved : List Nat → Nat → List WidgetNode
    | [], _ => []
    | [r], _pos =>
      let colNodes := spec.nodes.filter (fun n => n.rank == r)
      let colWidgets := colNodes.map (buildDiagramNodeBox theme spec.nodeWidthSub spec.nodeHeightSub)
      [WidgetNode.box
        (BoxStyle.col spec.columnGapSub |>.withJustify .end_ |>.withFixedSize spec.nodeWidthSub colsH)
        colWidgets]
    | r :: rNext :: rest, pos =>
      let colNodes := spec.nodes.filter (fun n => n.rank == r)
      let colWidgets := colNodes.map (buildDiagramNodeBox theme spec.nodeWidthSub spec.nodeHeightSub)
      let rankCol :=
        WidgetNode.box
          (BoxStyle.col spec.columnGapSub |>.withJustify .end_ |>.withFixedSize spec.nodeWidthSub colsH)
          colWidgets
      rankCol :: buildConnBand pos :: buildRankInterleaved (rNext :: rest) (pos + 1)

  let graphColumns := buildRankInterleaved ranks 0
  let graphCanvas : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0
        |>.withAlign .center
        -- No bottom padding: the columns' bottom edge is the canvas's bottom edge,
        -- which is exactly where the return lane's stubs begin.
        |>.withPadding { top := pxToSub 12, right := pxToSub 12, bottom := 0, left := pxToSub 12 }
        |>.withFixedSize (availW - pxToSub 8) canvasH)
      graphColumns
  let laneRow : List WidgetNode :=
    if laneEdges.isEmpty then []
    else
      let xOf := columnCenterX spec.nodeWidthSub spec.rankGapSub
      [WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize (availW - pxToSub 8) laneH)
        (laneEdges.map fun (e, ps, pt) =>
          buildLaneEdgeWidget theme (availW - pxToSub 8) (pxToSub 28) (xOf ps) (xOf pt) e.label)]

  let children : List WidgetNode :=
    (if spec.title.isEmpty then [graphCanvas] else
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
      [titleBar, graphCanvas]) ++ laneRow

  WidgetNode.rrect
    (BoxStyle.col 0
      |>.withPadding (Edges.all (pxToSub 4))
      |>.withFixedSize availW totalH)
    pal.elevatedSurface
    (CornerRadii.uniform theme.radiusMd)
    (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
    children

end LeanUI.Widgets
