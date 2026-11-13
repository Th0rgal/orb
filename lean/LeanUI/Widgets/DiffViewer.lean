import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
/-!
# LeanUI.Widgets.DiffViewer — Unified & Split Side-by-Side Diff Viewer (`0` FFI)

Pure declarative unified and split side-by-side diff viewer supporting:
- `DiffLineKind` (`context`, `add`, `del`, `hunkHeader`)
- `DiffMode` (`unified`, `split`)
- Dual line-number gutters (`oldLine`, `newLine`), semantic `diffAddBg`/`diffDelBg`/`diffHunkBg` styling,
  collapsible file header bar with `+additions` / `-deletions` badges, and focusable mode/collapse controls.
-/
namespace LeanUI.Widgets

/-- Classification of a single diff line. -/
inductive DiffLineKind where
  | context
  | add
  | del
  | hunkHeader
  deriving DecidableEq, Repr, Inhabited

/-- Presentation mode for a `DiffViewer`. -/
inductive DiffMode where
  | unified
  | split
  deriving DecidableEq, Repr, Inhabited

/-- A single annotated line in a unified diff hunk. -/
structure DiffLine where
  kind : DiffLineKind
  oldLine : Option Nat := none
  newLine : Option Nat := none
  text : String
  runs : List InlineRun := []
  deriving Repr, Inhabited

/-- A paired row in split (side-by-side) diff presentation. -/
structure SplitDiffRow where
  left : Option DiffLine
  right : Option DiffLine
  deriving Repr, Inhabited

/-- File-level diff state and metadata. -/
structure DiffFileSpec where
  filePath : String
  mode : DiffMode := .unified
  collapsed : Bool := false
  additions : Nat := 0
  deletions : Nat := 0
  collapseToggleId : Option WidgetId := none
  modeToggleId : Option WidgetId := none
  lines : List DiffLine := []
  deriving Repr, Inhabited

/-- Deterministic fallback `InlineRun` synthesizer for diff line strings and line numbers. -/
@[inline] def diffSynthRun (style : TextStyle) (text : String) : InlineRun :=
  let charAdv : SubPx := max (6 * subPerPx) (style.sizeSub / 2)
  let glyphs : List ShapedGlyph :=
    text.toList.mapIdx fun idx c => {
      glyphId := c.toNat
      cluster := idx
      xAdvance := charAdv
    }
  { glyphs := glyphs, style := style, allowBreakAfter := false, hardBreakAfter := false }

/-- Background fill color for a `DiffLineKind`. -/
@[inline] def diffLineBg (pal : Palette) : DiffLineKind → Color
  | .context    => pal.codeBg
  | .add        => pal.diffAddBg
  | .del        => pal.diffDelBg
  | .hunkHeader => pal.diffHunkBg

/-- Foreground text color for a `DiffLineKind`. -/
@[inline] def diffLineFg (pal : Palette) : DiffLineKind → Color
  | .context    => pal.textPrimary
  | .add        => pal.diffAddText
  | .del        => pal.diffDelText
  | .hunkHeader => pal.diffHunkText

/-- Prefix sigil (`" "`, `"+"`, `"-"`, `"@@"`) for a `DiffLineKind`. -/
@[inline] def diffLinePrefix : DiffLineKind → String
  | .context    => " "
  | .add        => "+"
  | .del        => "-"
  | .hunkHeader => "@@"

/-- Pair a list of unified `DiffLine`s into side-by-side `SplitDiffRow`s. -/
def pairSplitDiffLines : List DiffLine → List SplitDiffRow
  | [] => []
  | l1 :: l2 :: rest =>
    match l1.kind, l2.kind with
    | .del, .add =>
      { left := some l1, right := some l2 } :: pairSplitDiffLines rest
    | _, _ =>
      let row1 : SplitDiffRow :=
        match l1.kind with
        | .context => { left := some l1, right := some l1 }
        | .del => { left := some l1, right := none }
        | .add => { left := none, right := some l1 }
        | .hunkHeader => { left := some l1, right := some l1 }
      row1 :: pairSplitDiffLines (l2 :: rest)
  | [l] =>
    let row : SplitDiffRow :=
      match l.kind with
      | .context => { left := some l, right := some l }
      | .del => { left := some l, right := none }
      | .add => { left := none, right := some l }
      | .hunkHeader => { left := some l, right := some l }
    [row]

/-- Render a single unified diff row with old/new line-number gutters and colored background. -/
def buildUnifiedDiffRow (theme : Theme) (availW : SubPx) (line : DiffLine) : WidgetNode :=
  let pal := theme.palette
  let rowH : SubPx := pxToSub 24
  let gutterW : SubPx := pxToSub 38
  let sigilW : SubPx := pxToSub 18
  let codeW : SubPx := availW - (2 * gutterW + sigilW + pxToSub 16)
  let bg := diffLineBg pal line.kind
  let fg := diffLineFg pal line.kind
  let gutterStyle : TextStyle := { (Theme.codeText theme) with sizeSub := theme.typo.xs, color := pal.textMuted }
  let codeStyle : TextStyle := { (Theme.codeText theme) with color := fg }
  let oldStr := match line.oldLine with | some n => toString n | none => ""
  let newStr := match line.newLine with | some n => toString n | none => ""
  let oldCell :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize gutterW (pxToSub 18))
      theme.typo.lineTight
      [diffSynthRun gutterStyle oldStr]
  let newCell :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize gutterW (pxToSub 18))
      theme.typo.lineTight
      [diffSynthRun gutterStyle newStr]
  let sigilCell :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize sigilW (pxToSub 18))
      theme.typo.lineTight
      [diffSynthRun codeStyle (diffLinePrefix line.kind)]
  let effectiveRuns :=
    if line.runs.isEmpty then [diffSynthRun codeStyle line.text] else line.runs
  let codeCell :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize codeW (pxToSub 18))
      theme.typo.lineTight
      effectiveRuns
  WidgetNode.box
    (BoxStyle.row (pxToSub 4)
      |>.withAlign .center
      |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 3))
      |>.withFixedSize availW rowH
      |>.withBg bg)
    [oldCell, newCell, sigilCell, codeCell]

/-- Render one half (left or right pane) of a split diff row. -/
def buildSplitPaneCell (theme : Theme) (paneW : SubPx) (isLeft : Bool)
    (optLine : Option DiffLine) : WidgetNode :=
  let pal := theme.palette
  let rowH : SubPx := pxToSub 24
  let gutterW : SubPx := pxToSub 34
  let codeW : SubPx := paneW - gutterW - pxToSub 14
  match optLine with
  | none =>
    WidgetNode.box
      (BoxStyle.row 0
        |>.withFixedSize paneW rowH
        |>.withBg pal.codeBg)
      []
  | some line =>
    let bg := diffLineBg pal line.kind
    let fg := diffLineFg pal line.kind
    let gutterStyle : TextStyle := { (Theme.codeText theme) with sizeSub := theme.typo.xs, color := pal.textMuted }
    let codeStyle : TextStyle := { (Theme.codeText theme) with color := fg }
    let lineNoStr :=
      match (if isLeft then line.oldLine else line.newLine) with
      | some n => toString n
      | none => ""
    let gutterCell :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize gutterW (pxToSub 18))
        theme.typo.lineTight
        [diffSynthRun gutterStyle lineNoStr]
    let effectiveRuns :=
      if line.runs.isEmpty then [diffSynthRun codeStyle (diffLinePrefix line.kind ++ " " ++ line.text)]
      else line.runs
    let codeCell :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize codeW (pxToSub 18))
        theme.typo.lineTight
        effectiveRuns
    WidgetNode.box
      (BoxStyle.row (pxToSub 4)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 6) (pxToSub 3))
        |>.withFixedSize paneW rowH
        |>.withBg bg)
      [gutterCell, codeCell]

/-- Render a side-by-side `SplitDiffRow`. -/
def buildSplitDiffRow (theme : Theme) (availW : SubPx) (row : SplitDiffRow) : WidgetNode :=
  let pal := theme.palette
  let rowH : SubPx := pxToSub 24
  let dividerW : SubPx := theme.borderWidth
  let paneW : SubPx := (availW - dividerW) / 2
  let leftPane := buildSplitPaneCell theme paneW true row.left
  let divider :=
    WidgetNode.rrect
      (BoxStyle.col 0 |>.withFixedSize dividerW rowH)
      pal.borderSubtle
      CornerRadii.zero
  let rightPane := buildSplitPaneCell theme (availW - paneW - dividerW) false row.right
  WidgetNode.box
    (BoxStyle.row 0 |>.withFixedSize availW rowH)
    [leftPane, divider, rightPane]

/-- Build a complete `DiffViewer` widget (collapsible file header + unified or split diff body). -/
def buildDiffViewerWidget (theme : Theme) (availW : SubPx) (spec : DiffFileSpec) : WidgetNode :=
  let pal := theme.palette
  let headerH : SubPx := pxToSub 36
  let rowH : SubPx := pxToSub 24
  let fileLabelStyle : TextStyle := { (Theme.codeText theme) with weight := 600, color := pal.textPrimary }
  let addBadgeStyle : TextStyle := { (Theme.codeText theme) with sizeSub := theme.typo.xs, color := pal.diffAddText }
  let delBadgeStyle : TextStyle := { (Theme.codeText theme) with sizeSub := theme.typo.xs, color := pal.diffDelText }
  let modeLabelStyle : TextStyle := Theme.mutedText theme

  let collapseIcon := if spec.collapsed then "▸ " else "▾ "
  let fileTitleRaw : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 220) (pxToSub 20))
      theme.typo.lineBase
      [diffSynthRun fileLabelStyle (collapseIcon ++ spec.filePath)]
      spec.collapseToggleId
  let fileTitle : WidgetNode :=
    match spec.collapseToggleId with
    | some wid => WidgetNode.focusable wid fileTitleRaw
    | none => fileTitleRaw

  let statsBadge : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 6) |>.withAlign .center |>.withFixedSize (pxToSub 92) (pxToSub 22))
      [ WidgetNode.rrect
          (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) (pxToSub 2)) |>.withFixedSize (pxToSub 42) (pxToSub 20))
          pal.diffAddBg
          (CornerRadii.uniform theme.radiusSm)
          (BorderStyle.uniform theme.borderWidth pal.success)
          [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 30) (pxToSub 16)) theme.typo.lineTight
            [diffSynthRun addBadgeStyle ("+" ++ toString spec.additions)]]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) (pxToSub 2)) |>.withFixedSize (pxToSub 42) (pxToSub 20))
          pal.diffDelBg
          (CornerRadii.uniform theme.radiusSm)
          (BorderStyle.uniform theme.borderWidth pal.danger)
          [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 30) (pxToSub 16)) theme.typo.lineTight
            [diffSynthRun delBadgeStyle ("-" ++ toString spec.deletions)]]
      ]

  let modeStr := match spec.mode with | .unified => "Unified" | .split => "Split"
  let modeBtnRaw : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 3))
        |>.withFixedSize (pxToSub 68) (pxToSub 22))
      pal.surface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.border)
      [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 52) (pxToSub 16)) theme.typo.lineTight
        [diffSynthRun modeLabelStyle modeStr]]
      spec.modeToggleId
  let modeBtn : WidgetNode :=
    match spec.modeToggleId with
    | some wid => WidgetNode.focusable wid modeBtnRaw
    | none => modeBtnRaw

  let headerBar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 7))
        |>.withFixedSize availW headerH)
      pal.elevatedSurface
      (if spec.collapsed then CornerRadii.uniform theme.radiusMd
       else { topLeft := theme.radiusMd, topRight := theme.radiusMd, bottomRight := 0, bottomLeft := 0 })
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
      [fileTitle, statsBadge, modeBtn]

  if spec.collapsed then
    headerBar
  else
    let bodyRows : List WidgetNode :=
      match spec.mode with
      | .unified => spec.lines.map (buildUnifiedDiffRow theme availW)
      | .split   => (pairSplitDiffLines spec.lines).map (buildSplitDiffRow theme availW)
    let bodyH : SubPx := max rowH (bodyRows.length * rowH)
    let bodyContainer : WidgetNode :=
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize availW bodyH |>.withBg pal.codeBg)
        bodyRows
    WidgetNode.rrect
      (BoxStyle.col 0 |>.withFixedSize availW (headerH + bodyH))
      pal.codeBg
      (CornerRadii.uniform theme.radiusMd)
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
      [headerBar, bodyContainer]

end LeanUI.Widgets
