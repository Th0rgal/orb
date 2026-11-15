import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
/-!
# LeanUI.Widgets.RichText — Markdown AST, Syntax-Highlighted `CodeBlock`, and KaTeX Math Boxes (`0` FFI)

Pure declarative rich-text widget builder supporting:
- Inline Markdown AST (`Text`, `Bold`, `Italic`, `InlineCode`, `Link`, `InlineMath`)
- Block Markdown AST (`Paragraph`, `Heading`, `CodeBlock`, `BlockQuote`, `BulletList`, `MathBlock`)
- Syntax-highlighted `CodeBlock` with language header bar and focusable copy button (`WidgetId`)
- KaTeX-style mathematical box layout (`Atom`, `Fraction`, `Superscript`, `Subscript`, `Radical`, `Delimited`, `Row`)
-/
namespace LeanUI.Widgets

/-- KaTeX-style mathematical expression AST for pure 2D box layout. -/
inductive MathExpr where
  | atom (text : String) (italic : Bool := true)
  | operator (op : String)
  | fraction (numer denom : MathExpr)
  | superscript (base sup : MathExpr)
  | subscript (base sub : MathExpr)
  | supSub (base sup sub : MathExpr)
  | radical (radicand : MathExpr)
  | delimited (leftDelim rightDelim : String) (inner : MathExpr)
  | row (items : List MathExpr)
  deriving Repr, Inhabited

/-- Syntax highlighting token category for `CodeBlock`. -/
inductive SyntaxRole where
  | plain
  | keyword
  | typeName
  | stringLit
  | numberLit
  | comment
  | operator
  | functionName
  deriving DecidableEq, Repr, Inhabited

/-- A single syntax-highlighted token span inside a `CodeBlock` line. -/
structure CodeToken where
  text : String
  role : SyntaxRole := .plain
  deriving DecidableEq, Repr, Inhabited

/-- Inline rich-text elements inside paragraphs, headings, blockquotes, and list items. -/
inductive RichInline where
  | text (content : String)
  | bold (content : String)
  | italic (content : String)
  | inlineCode (code : String)
  | link (label : String) (url : String) (linkId : Option WidgetId := none)
  | inlineMath (expr : MathExpr)
  deriving Repr, Inhabited

/-- Block-level Markdown / rich-text AST nodes. -/
inductive RichBlock where
  | paragraph (inlines : List RichInline)
  | heading (level : Nat) (inlines : List RichInline)
  | codeBlock (language : String) (lines : List (List CodeToken)) (copyButtonId : Option WidgetId := none)
  | blockQuote (blocks : List RichBlock)
  | bulletList (items : List (List RichInline))
  | mathBlock (expr : MathExpr)
  deriving Repr, Inhabited

/-- Deterministic pure fallback synthesizer turning a UTF-8 `String` into an `InlineRun`
when pre-shaped HarfBuzz glyphs are not provided. -/
def synthInlineRun (style : TextStyle) (text : String)
    (allowBreakAfter : Bool := true) (hardBreakAfter : Bool := false) : InlineRun :=
  let charAdv : SubPx := max (6 * subPerPx) (style.sizeSub / 2)
  let glyphs : List ShapedGlyph :=
    text.toList.mapIdx fun idx c => {
      glyphId := c.toNat
      cluster := idx
      xAdvance := charAdv
      isBreakOpportunity := c == ' '
      isHardBreak := c == '\n'
    }
  { glyphs := glyphs
    style := style
    allowBreakAfter := allowBreakAfter
    hardBreakAfter := hardBreakAfter }

/-- Map a `SyntaxRole` to its semantic theme color. -/
@[inline] def syntaxRoleColor (theme : Theme) : SyntaxRole → Color
  | .plain        => theme.palette.textPrimary
  | .keyword      => theme.palette.accent
  | .typeName     => theme.palette.diffHunkText
  | .stringLit    => theme.palette.diffAddText
  | .numberLit    => theme.palette.warning
  | .comment      => theme.palette.textMuted
  | .operator     => theme.palette.textSecondary
  | .functionName => theme.palette.focusRing

/-- Convert a list of `CodeToken`s into styled `InlineRun`s. -/
def codeTokensToRuns (theme : Theme) (tokens : List CodeToken) : List InlineRun :=
  let baseStyle := Theme.codeText theme
  tokens.map fun tok =>
    let tokStyle : TextStyle := {
      baseStyle with
      color := syntaxRoleColor theme tok.role
      weight := if tok.role == .keyword then 600 else 400
      italic := tok.role == .comment
    }
    synthInlineRun tokStyle tok.text false false

/-- Measure approximate width and height in `SubPx` of a `MathExpr` at font size `fontSizeSub`. -/
def measureMathExpr (fontSizeSub : SubPx) : MathExpr → SubPx × SubPx
  | .atom txt _ =>
    let charW := max (pxToSub 6) (fontSizeSub / 2)
    (max charW (txt.length * charW), fontSizeSub + pxToSub 4)
  | .operator op =>
    let charW := max (pxToSub 6) (fontSizeSub / 2)
    (op.length * charW + pxToSub 8, fontSizeSub + pxToSub 4)
  | .fraction numer denom =>
    let subFont := max (pxToSub 9) ((fontSizeSub * 3) / 4)
    let (nw, nh) := measureMathExpr subFont numer
    let (dw, dh) := measureMathExpr subFont denom
    (max nw dw + pxToSub 10, nh + dh + pxToSub 8)
  | .superscript base sup =>
    let subFont := max (pxToSub 8) ((fontSizeSub * 2) / 3)
    let (bw, bh) := measureMathExpr fontSizeSub base
    let (sw, sh) := measureMathExpr subFont sup
    (bw + sw + pxToSub 2, max bh (sh + fontSizeSub / 2))
  | .subscript base sub =>
    let subFont := max (pxToSub 8) ((fontSizeSub * 2) / 3)
    let (bw, bh) := measureMathExpr fontSizeSub base
    let (sw, sh) := measureMathExpr subFont sub
    (bw + sw + pxToSub 2, max bh (sh + fontSizeSub / 2))
  | .supSub base sup sub =>
    let subFont := max (pxToSub 8) ((fontSizeSub * 2) / 3)
    let (bw, bh) := measureMathExpr fontSizeSub base
    let (supW, supH) := measureMathExpr subFont sup
    let (subW, subH) := measureMathExpr subFont sub
    (bw + max supW subW + pxToSub 2, max bh (supH + subH + pxToSub 2))
  | .radical radicand =>
    let (rw, rh) := measureMathExpr fontSizeSub radicand
    (rw + pxToSub 12, rh + pxToSub 6)
  | .delimited l r inner =>
    let (iw, ih) := measureMathExpr fontSizeSub inner
    let delimW := max (pxToSub 6) ((l.length + r.length) * (fontSizeSub / 2))
    (iw + delimW + pxToSub 6, ih + pxToSub 4)
  | .row items =>
    measureMathRow fontSizeSub items
where
  measureMathRow (fontSizeSub : SubPx) : List MathExpr → SubPx × SubPx
    | [] => (0, fontSizeSub)
    | m :: ms =>
      let (w1, h1) := measureMathExpr fontSizeSub m
      let (w2, h2) := measureMathRow fontSizeSub ms
      (w1 + w2 + (if ms.isEmpty then 0 else pxToSub 2), max h1 h2)

/-- Build a pure declarative `WidgetNode` tree for a KaTeX-style `MathExpr`
(`Fraction`, `Superscript`, `Subscript`, `Radical`, `Delimited`, `Row`). -/
def buildMathWidget (theme : Theme) (fontSizeSub : SubPx) : MathExpr → WidgetNode
  | .atom txt isItalic =>
    let (w, h) := measureMathExpr fontSizeSub (.atom txt isItalic)
    let st : TextStyle := {
      (Theme.bodyText theme) with
      sizeSub := fontSizeSub
      lineHeightSub := h
      italic := isItalic
      color := theme.palette.textPrimary
    }
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize w h)
      h
      [synthInlineRun st txt false false]
  | .operator op =>
    let (w, h) := measureMathExpr fontSizeSub (.operator op)
    let st : TextStyle := {
      (Theme.bodyText theme) with
      sizeSub := fontSizeSub
      lineHeightSub := h
      color := theme.palette.accent
    }
    WidgetNode.text
      (BoxStyle.row 0
        |>.withPadding (Edges.xy (pxToSub 4) 0)
        |>.withFixedSize w h)
      h
      [synthInlineRun st op false false]
  | .fraction numer denom =>
    let subFont := max (pxToSub 9) ((fontSizeSub * 3) / 4)
    let numerNode := buildMathWidget theme subFont numer
    let denomNode := buildMathWidget theme subFont denom
    let (fw, fh) := measureMathExpr fontSizeSub (.fraction numer denom)
    let barW := max (pxToSub 12) (fw - pxToSub 4)
    let vinculumBar : WidgetNode :=
      WidgetNode.rrect
        (BoxStyle.row 0 |>.withFixedSize barW (pxToSub 1))
        theme.palette.textPrimary
        CornerRadii.zero
    WidgetNode.box
      (BoxStyle.col (pxToSub 2)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 3) (pxToSub 1))
        |>.withFixedSize fw fh)
      [numerNode, vinculumBar, denomNode]
  | .superscript base sup =>
    let subFont := max (pxToSub 8) ((fontSizeSub * 2) / 3)
    let baseNode := buildMathWidget theme fontSizeSub base
    let supNode := buildMathWidget theme subFont sup
    let (w, h) := measureMathExpr fontSizeSub (.superscript base sup)
    WidgetNode.box
      (BoxStyle.row (pxToSub 1)
        |>.withAlign .start
        |>.withFixedSize w h)
      [baseNode, supNode]
  | .subscript base sub =>
    let subFont := max (pxToSub 8) ((fontSizeSub * 2) / 3)
    let baseNode := buildMathWidget theme fontSizeSub base
    let subNode := buildMathWidget theme subFont sub
    let (w, h) := measureMathExpr fontSizeSub (.subscript base sub)
    WidgetNode.box
      (BoxStyle.row (pxToSub 1)
        |>.withAlign .end_
        |>.withFixedSize w h)
      [baseNode, subNode]
  | .supSub base sup sub =>
    let subFont := max (pxToSub 8) ((fontSizeSub * 2) / 3)
    let baseNode := buildMathWidget theme fontSizeSub base
    let supNode := buildMathWidget theme subFont sup
    let subNode := buildMathWidget theme subFont sub
    let (_, supH) := measureMathExpr subFont sup
    let (supW, _) := measureMathExpr subFont sup
    let (subW, subH) := measureMathExpr subFont sub
    let stackW := max supW subW
    let stackNode :=
      WidgetNode.box
        (BoxStyle.col (pxToSub 1) |>.withFixedSize stackW (supH + subH + pxToSub 2))
        [supNode, subNode]
    let (w, h) := measureMathExpr fontSizeSub (.supSub base sup sub)
    WidgetNode.box
      (BoxStyle.row (pxToSub 1) |>.withAlign .center |>.withFixedSize w h)
      [baseNode, stackNode]
  | .radical radicand =>
    let radNode := buildMathWidget theme fontSizeSub radicand
    let (rw, rh) := measureMathExpr fontSizeSub radicand
    let (totalW, totalH) := measureMathExpr fontSizeSub (.radical radicand)
    let surdGlyphStyle : TextStyle := {
      (Theme.bodyText theme) with
      sizeSub := fontSizeSub
      lineHeightSub := totalH
      weight := 600
      color := theme.palette.accent
    }
    let surdCol : WidgetNode :=
      WidgetNode.text
        (BoxStyle.col 0 |>.withFixedSize (pxToSub 10) totalH)
        totalH
        [synthInlineRun surdGlyphStyle "√" false false]
    let overbar : WidgetNode :=
      WidgetNode.rrect
        (BoxStyle.row 0 |>.withFixedSize (rw + pxToSub 2) (pxToSub 1))
        theme.palette.textPrimary
        CornerRadii.zero
    let radicandCol : WidgetNode :=
      WidgetNode.box
        (BoxStyle.col (pxToSub 2) |>.withFixedSize (rw + pxToSub 2) (rh + pxToSub 4))
        [overbar, radNode]
    WidgetNode.box
      (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize totalW totalH)
      [surdCol, radicandCol]
  | .delimited leftD rightD inner =>
    let innerNode := buildMathWidget theme fontSizeSub inner
    let (totalW, totalH) := measureMathExpr fontSizeSub (.delimited leftD rightD inner)
    let delimStyle : TextStyle := {
      (Theme.bodyText theme) with
      sizeSub := fontSizeSub + pxToSub 2
      lineHeightSub := totalH
      color := theme.palette.textSecondary
    }
    let leftNode :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (pxToSub 8) totalH)
        totalH
        [synthInlineRun delimStyle leftD false false]
    let rightNode :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (pxToSub 8) totalH)
        totalH
        [synthInlineRun delimStyle rightD false false]
    WidgetNode.box
      (BoxStyle.row (pxToSub 2) |>.withAlign .center |>.withFixedSize totalW totalH)
      [leftNode, innerNode, rightNode]
  | .row items =>
    let (w, h) := measureMathExpr fontSizeSub (.row items)
    let children := buildMathRowList theme fontSizeSub items
    WidgetNode.box
      (BoxStyle.row (pxToSub 2) |>.withAlign .center |>.withFixedSize w h)
      children
where
  buildMathRowList (theme : Theme) (fontSizeSub : SubPx) : List MathExpr → List WidgetNode
    | [] => []
    | m :: ms => buildMathWidget theme fontSizeSub m :: buildMathRowList theme fontSizeSub ms

/-- Flatten a `MathExpr` to a linear UTF-8 fallback representation when embedded inside an `InlineRun` stream. -/
def flattenMathExprToString : MathExpr → String
  | .atom txt _ => txt
  | .operator op => " " ++ op ++ " "
  | .fraction n d => "(" ++ flattenMathExprToString n ++ "/" ++ flattenMathExprToString d ++ ")"
  | .superscript b s => flattenMathExprToString b ++ "^" ++ flattenMathExprToString s
  | .subscript b s => flattenMathExprToString b ++ "_" ++ flattenMathExprToString s
  | .supSub b sup sub => flattenMathExprToString b ++ "_" ++ flattenMathExprToString sub ++ "^" ++ flattenMathExprToString sup
  | .radical r => "√(" ++ flattenMathExprToString r ++ ")"
  | .delimited l r i => l ++ flattenMathExprToString i ++ r
  | .row items => String.join (items.map flattenMathExprToString)

/-- Convert a list of `RichInline` spans into `InlineRun`s for word-wrapped paragraph/heading rendering. -/
def richInlinesToRuns (theme : Theme) (baseStyle : TextStyle) (inlines : List RichInline) : List InlineRun :=
  inlines.map fun inl =>
    match inl with
    | .text txt => synthInlineRun baseStyle txt
    | .bold txt => synthInlineRun { baseStyle with weight := 700 } txt
    | .italic txt => synthInlineRun { baseStyle with italic := true } txt
    | .inlineCode code =>
      synthInlineRun
        { (Theme.codeText theme) with color := theme.palette.accent }
        ("`" ++ code ++ "`")
    | .link label _ _ =>
      synthInlineRun
        { baseStyle with color := theme.palette.accent, underline := true }
        label
    | .inlineMath expr =>
      synthInlineRun
        { baseStyle with italic := true, color := theme.palette.diffHunkText }
        (flattenMathExprToString expr)

/-- Build a syntax-highlighted `CodeBlock` widget with language header bar and focusable copy button (`WidgetId`). -/
def buildCodeBlockWidget (theme : Theme) (availW : SubPx) (language : String)
    (lines : List (List CodeToken)) (copyButtonId : Option WidgetId := none) : WidgetNode :=
  let pal := theme.palette
  let headerH : SubPx := pxToSub 32
  let lineH : SubPx := theme.typo.lineBase
  let lineCount := max 1 lines.length
  let bodyH : SubPx := lineCount * lineH + pxToSub 16
  let totalH : SubPx := headerH + bodyH
  let langStyle := Theme.mutedText theme
  let langLabel : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 110) (pxToSub 18))
      theme.typo.lineTight
      [synthInlineRun langStyle (if language.isEmpty then "text" else language)]
  let copyBtnRaw : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 4)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 4))
        |>.withFixedSize (pxToSub 64) (pxToSub 22))
      pal.surface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.border)
      [WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (pxToSub 48) (pxToSub 14))
        theme.typo.lineTight
        [synthInlineRun langStyle "Copy"]]
      copyButtonId
  let copyBtn : WidgetNode :=
    match copyButtonId with
    | some wid => WidgetNode.focusable wid copyBtnRaw
    | none => copyBtnRaw
  let headerBar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 5))
        |>.withFixedSize availW headerH)
      pal.elevatedSurface
      { topLeft := theme.radiusMd, topRight := theme.radiusMd, bottomRight := 0, bottomLeft := 0 }
      { widths := Edges.trbl 0 0 theme.borderWidth 0, color := pal.borderSubtle }
      [langLabel, copyBtn]
  let lineNodes : List WidgetNode :=
    lines.map fun tokLine =>
      let runs := codeTokensToRuns theme tokLine
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 24) lineH)
        lineH
        runs
  let codeBody : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 8))
        |>.withFixedSize availW bodyH
        |>.withBg pal.codeBg)
      lineNodes
  WidgetNode.rrect
    (BoxStyle.col 0 |>.withFixedSize availW totalH)
    pal.codeBg
    (CornerRadii.uniform theme.radiusMd)
    (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
    [headerBar, codeBody]

/-- Build a declarative `WidgetNode` for a single `RichBlock`. -/
def buildRichBlockWidget (theme : Theme) (availW : SubPx) : RichBlock → WidgetNode
  | .paragraph inlines =>
    let baseStyle := Theme.bodyText theme
    let runs := richInlinesToRuns theme baseStyle inlines
    let (_, _, wrappedH) := wrapInlineRuns availW baseStyle.lineHeightSub runs
    let h := max baseStyle.lineHeightSub wrappedH
    -- If paragraph contains any `inlineMath` spans, also render their structured KaTeX boxes in a companion row
    let mathBoxes : List WidgetNode :=
      inlines.filterMap fun inl =>
        match inl with
        | .inlineMath expr => some (buildMathWidget theme theme.typo.base expr)
        | _ => none
    let textNode :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize availW h)
        baseStyle.lineHeightSub
        runs
    if mathBoxes.isEmpty then
      textNode
    else
      WidgetNode.box
        (BoxStyle.col (pxToSub 6) |>.withFixedSize availW (h + pxToSub 28))
        (textNode ::
          [WidgetNode.box (BoxStyle.row (pxToSub 8) |>.withAlign .center |>.withFixedSize availW (pxToSub 22)) mathBoxes])
  | .heading level inlines =>
    let hSize :=
      if level <= 1 then theme.typo.xl
      else if level == 2 then theme.typo.lg
      else theme.typo.md
    let lh := if level <= 2 then theme.typo.lineHeading else theme.typo.lineRelaxed
    let hStyle : TextStyle := {
      (Theme.headingText theme) with
      sizeSub := hSize
      lineHeightSub := lh
      weight := 700
    }
    let runs := richInlinesToRuns theme hStyle inlines
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize availW lh)
      lh
      runs
  | .codeBlock language lines copyButtonId =>
    buildCodeBlockWidget theme availW language lines copyButtonId
  | .blockQuote innerBlocks =>
    let innerW := availW - pxToSub 20
    let children := buildRichBlockList theme innerW innerBlocks
    let totalH := pxToSub (max 36 (innerBlocks.length * 28))
    WidgetNode.rrect
      (BoxStyle.col (pxToSub 6)
        |>.withPadding (Edges.trbl (pxToSub 6) (pxToSub 10) (pxToSub 6) (pxToSub 14))
        |>.withFixedSize availW totalH)
      theme.palette.elevatedSurface
      (CornerRadii.uniform theme.radiusSm)
      { widths := Edges.trbl 0 0 0 (pxToSub 3), color := theme.palette.accent }
      children
  | .bulletList items =>
    let baseStyle := Theme.bodyText theme
    let itemH := baseStyle.lineHeightSub
    let rows : List WidgetNode :=
      items.map fun itemInlines =>
        let dot : WidgetNode :=
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withFixedSize (pxToSub 6) (pxToSub 6))
            theme.palette.accent
            (CornerRadii.uniform (pxToSub 3))
        let runs := richInlinesToRuns theme baseStyle itemInlines
        let txt : WidgetNode :=
          WidgetNode.text
            (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 20) itemH)
            itemH
            runs
        WidgetNode.box
          (BoxStyle.row (pxToSub 8) |>.withAlign .center |>.withFixedSize availW itemH)
          [dot, txt]
    let totalH := max itemH (items.length * (itemH + pxToSub 4))
    WidgetNode.box
      (BoxStyle.col (pxToSub 4) |>.withFixedSize availW totalH)
      rows
  | .mathBlock expr =>
    let mathNode := buildMathWidget theme theme.typo.md expr
    let (_, mh) := measureMathExpr theme.typo.md expr
    let boxH := mh + pxToSub 16
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .center
        |>.withPadding (Edges.all (pxToSub 8))
        |>.withFixedSize availW boxH)
      theme.palette.elevatedSurface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth theme.palette.borderSubtle)
      [mathNode]
where
  buildRichBlockList (theme : Theme) (availW : SubPx) : List RichBlock → List WidgetNode
    | [] => []
    | b :: bs => buildRichBlockWidget theme availW b :: buildRichBlockList theme availW bs

/-- Build a vertical document container from a list of `RichBlock`s. -/
def buildRichDocumentWidget (theme : Theme) (availW : SubPx) (blocks : List RichBlock) : WidgetNode :=
  let children := buildRichBlockWidget.buildRichBlockList theme availW blocks
  WidgetNode.box
    (BoxStyle.col (pxToSub 10) |>.withFixedSize availW (pxToSub (max 48 (blocks.length * 56))))
    children

end LeanUI.Widgets
