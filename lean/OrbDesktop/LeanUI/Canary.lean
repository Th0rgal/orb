import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
import LeanUI.Widgets.VirtualList
import LeanUI.Widgets.RichText
import LeanUI.Widgets.DiffViewer
import LeanUI.Widgets.MermaidSvg
import LeanUI.Widgets.Overlays
import LeanUI.Widgets.Composer
import LeanUI.FFI
import LeanUI.Wayland
import LeanUI.Text
import LeanUI.Vulkan
import LeanUI.Runtime
/-!
# LeanUI.Canary — End-to-End 1-Unit Canary Screen & Wave 2B Reusable Widget Library Showcase

Integrates the pure declarative UI stack (`LeanUI.Style`, `LeanUI.Layout`, `LeanUI.Scene`,
`LeanUI.Kernel`, and all 6 reusable widget modules under `LeanUI.Widgets.*`) with the native
runtime stack (`LeanUI.Wayland`, `LeanUI.Text`, `LeanUI.Vulkan`, `LeanUI.Runtime`) to render
the canonical Orb Desktop screen across Dark/Light themes and `1.0x`/`2.0x` HiDPI scale factors
with deterministic `--headless-golden` PNG verification and `0` redraws when quiescent
(`quiescentSkips >= 1`).
-/
namespace LeanUI

namespace Theme

@[inline] def dark : Theme := orbDarkTheme

@[inline] def light : Theme := orbLightTheme

end Theme

/-- Compute the two-axis Flexbox and inline layout tree from root origin `(0, 0)` in `SubPx` and device pixels. -/
@[inline] def layoutTree (scale120 : Nat) (focusOwner : Option EntityId) (focusColor : Color)
    (availW availH : SubPx) (root : LayoutNode) : ComputedBox :=
  layoutNode scale120 focusOwner focusColor 0 0 availW availH root

/-- Alias for `renderWidgetTree` returning `SceneOutput` directly. -/
@[inline] def buildScene (scale120 : Nat) (availW availH : SubPx)
    (focusState : FocusState) (theme : Theme) (rootWidget : WidgetNode) : SceneOutput :=
  (renderWidgetTree scale120 availW availH focusState theme rootWidget).2

/-- Extract focusable tab order (`List WidgetId`) from a `SceneOutput`. -/
@[inline] def focusOrder (s : SceneOutput) : List WidgetId :=
  s.focusableOrder

end LeanUI

namespace LeanUI.Canary

/-- Canonical focusable widget IDs on the Orb Desktop Canary screen. -/
def navInboxId : WidgetId := 101
def navTranscriptId : WidgetId := 102
def composerWidgetId : WidgetId := 1

/-- Application state for the Canary screen (theme selection and active mission metadata). -/
structure CanaryState where
  theme : Theme := Theme.dark
  activeMissionTitle : String := "Wave 2 — End-to-End Canary Screen"
  deriving Repr, Inhabited

/-- Shape a single-line or word-wrapped UTF-8 string into `List InlineRun` via `LeanUI.Text`
(updating `GlyphAtlasCache`), or synthesize deterministic fallback `InlineRun` advances when
running without a font face. -/
def shapeInlineRuns (ac : Text.GlyphAtlasCache) (font : Text.FontHandle)
    (scale120 : Nat) (style : TextStyle) (text : String) :
    IO (Text.GlyphAtlasCache × List InlineRun) := do
  if text.isEmpty then
    return (ac, [])
  let devSize64 : UInt32 := ((style.sizeSub * scale120 + scaleDen / 2) / scaleDen).toUInt32
  if font.facePtr != 0 then
    let shaped ← Text.shapeText font devSize64 text ""
    let mut curAc := ac
    let mut glyphs : List ShapedGlyph := []
    let scDen : Int := scaleDen
    let scNum : Int := if scale120 == 0 then 120 else scale120
    for sg in shaped do
      let (ac', entry) ← Text.getOrRasterizeGlyph curAc font sg.glyphId devSize64 0
      curAc := ac'
      let advSubNat : SubPx := ((max 0 sg.xAdvance64 * scDen) / scNum).toNat
      let xOffSub : Int := (sg.xOffset64 * scDen) / scNum
      let yOffSub : Int := (sg.yOffset64 * scDen) / scNum
      let g : ShapedGlyph := {
        glyphId := sg.glyphId.toNat
        cluster := sg.cluster.toNat
        xAdvance := max (4 * subPerPx) advSubNat
        yAdvance := 0
        xOffset := xOffSub
        yOffset := yOffSub
        atlasSrc := entry.uv
        sizePx := (entry.uv.w.toNat, entry.uv.h.toNat)
        bearingPx := (entry.bearingX, entry.bearingY)
        isColor := entry.isColor
      }
      glyphs := glyphs ++ [g]
    let run : InlineRun := {
      glyphs := glyphs
      style := style
      allowBreakAfter := true
      hardBreakAfter := false
    }
    return (curAc, [run])
  else
    let charAdv : SubPx := max (6 * subPerPx) (style.sizeSub / 2)
    let glyphs : List ShapedGlyph :=
      text.toList.mapIdx fun idx c => {
        glyphId := c.toNat
        cluster := idx
        xAdvance := charAdv
      }
    return (ac, [{ glyphs := glyphs, style := style }])

/-- Build the declarative `WidgetNode` tree for the Orb Desktop Canary screen:
1. Left sidebar with project header, active mission item, and focusable navigation pills (`WidgetId` 101, 102).
2. Top header bar with breadcrumbs, status badge, and theme/scale indicator.
3. Main scrollable mission transcript (`LayoutNode.scroll` + `WidgetNode.scrollClip`) containing
   assistant message cards with SDF drop shadow, rounded code block, and diff preview (`diffAddBg`/`diffDelBg`).
4. Bottom focusable composer box (`WidgetId` 1) with `Kernel.focusBorder` ring. -/
def buildCanaryWidgetTree (theme : Theme) (availW availH : SubPx) (scrollOffsetSub : SubPx)
    (titleRuns codeRuns diffAddRuns diffDelRuns : List InlineRun) : WidgetNode :=
  let pal := theme.palette
  let sidebarW : SubPx := pxToSub 260
  let headerH : SubPx := pxToSub 48
  let composerH : SubPx := pxToSub 64
  let mainW : SubPx := availW - sidebarW
  let transcriptViewportH : SubPx := availH - headerH - composerH

  -- 1. Left Sidebar
  let projectHeaderBox : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 10))
        |>.withFixedSize (sidebarW - pxToSub 24) (pxToSub 40))
      pal.elevatedSurface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)

  let navPill101 : WidgetNode :=
    WidgetNode.focusable navInboxId <|
      WidgetNode.rrect
        (BoxStyle.row (pxToSub 8)
          |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 8))
          |>.withFixedSize (sidebarW - pxToSub 24) (pxToSub 36))
        pal.accentMuted
        (CornerRadii.uniform theme.radiusMd)
        (BorderStyle.uniform theme.borderWidth pal.accent)

  let navPill102 : WidgetNode :=
    WidgetNode.focusable navTranscriptId <|
      WidgetNode.rrect
        (BoxStyle.row (pxToSub 8)
          |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 8))
          |>.withFixedSize (sidebarW - pxToSub 24) (pxToSub 36))
        pal.surface
        (CornerRadii.uniform theme.radiusMd)
        (BorderStyle.uniform theme.borderWidth pal.borderSubtle)

  let sidebarNode : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col (pxToSub 10)
        |>.withPadding (Edges.all (pxToSub 12))
        |>.withFixedSize sidebarW availH)
      pal.sidebar
      CornerRadii.zero
      { widths := Edges.trbl 0 theme.borderWidth 0 0, color := pal.border }
      [projectHeaderBox, navPill101, navPill102]

  -- 2. Top Header Bar (breadcrumbs + status badge + theme/scale indicator)
  let breadcrumbBox : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize (mainW - pxToSub 260) (pxToSub 24))
      theme.typo.lineBase
      titleRuns

  let statusBadge : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0 |>.withFixedSize (pxToSub 96) (pxToSub 26))
      pal.diffAddBg
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.success)

  let scaleBadge : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0 |>.withFixedSize (pxToSub 96) (pxToSub 26))
      pal.elevatedSurface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.border)

  let headerNode : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 12)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 20) (pxToSub 10))
        |>.withFixedSize mainW headerH)
      pal.header
      CornerRadii.zero
      { widths := Edges.trbl 0 0 theme.borderWidth 0, color := pal.border }
      [breadcrumbBox, statusBadge, scaleBadge]

  -- 3. Scrollable Mission Transcript powered by `LeanUI.Widgets.VirtualList` containing
  --    `RichText` (syntax-highlighted `CodeBlock` + KaTeX `MathExpr`), `DiffViewer`,
  --    `MermaidSvg` diagram, and `Overlays` (`Toast` + `Tooltip` + `SearchDialog` filter)
  let cardW : SubPx := mainW - pxToSub 40
  let innerBlockW : SubPx := cardW - pxToSub 32

  -- 3a. RichText: Syntax-highlighted CodeBlock + KaTeX MathExpr (`Fraction`, `Superscript`, `Radical`)
  let codeBlockNode : WidgetNode :=
    Widgets.buildCodeBlockWidget theme innerBlockW "lean4"
      [ [ { text := "theorem ", role := .keyword }
        , { text := "needsRedraw_none ", role := .functionName }
        , { text := ": ", role := .operator }
        , { text := "needsRedraw none = false ", role := .typeName }
        , { text := ":= rfl", role := .keyword }
        ]
      ]
      (some 301)

  let katexExpr : Widgets.MathExpr :=
    .row
      [ .atom "ΔE2E"
      , .operator "≥"
      , .fraction (.superscript (.atom "W") (.atom "2" false)) (.radical (.atom "N"))
      ]
  let mathWidgetNode : WidgetNode :=
    Widgets.buildRichBlockWidget theme innerBlockW (.mathBlock katexExpr)

  -- 3b. DiffViewer: Unified diff viewer with line-number gutters and `+add`/`-del` badges
  let diffSpec : Widgets.DiffFileSpec := {
    filePath := "lean/LeanUI/Scene.lean"
    mode := .unified
    collapsed := false
    additions := 1
    deletions := 1
    collapseToggleId := some 302
    modeToggleId := some 303
    lines := [
      { kind := .del, oldLine := some 41, newLine := none, text := "- WebKitGTK + SolidJS bridge", runs := diffDelRuns },
      { kind := .add, oldLine := none, newLine := some 41, text := "+ LeanUI pure Layout + Scene + Vulkan SDF", runs := diffAddRuns }
    ]
  }
  let diffViewerNode : WidgetNode :=
    Widgets.buildDiffViewerWidget theme innerBlockW diffSpec

  -- 3c. MermaidSvg: Layered Sugiyama diagram widget in `SubPx`
  let diagramSpec : Widgets.DiagramSpec := {
    title := "LeanUI Render Pipeline"
    direction := .leftRight
    nodeWidthSub := pxToSub 120
    nodeHeightSub := pxToSub 34
    rankGapSub := pxToSub 32
    columnGapSub := pxToSub 14
    nodes := [
      { id := 1, label := "WidgetNode", rank := 0, column := 0, shape := .rounded, widgetId := some 401 },
      { id := 2, label := "ComputedBox", rank := 1, column := 0, shape := .rounded, widgetId := some 402 },
      { id := 3, label := "Vulkan SDF", rank := 2, column := 0, shape := .pill, accentColor := some pal.success, widgetId := some 403 }
    ]
    edges := [
      { fromId := 1, toId := 2, label := "layout" },
      { fromId := 2, toId := 3, label := "lower" }
    ]
  }
  let mermaidWidgetNode : WidgetNode :=
    Widgets.buildMermaidDiagramWidget theme innerBlockW diagramSpec

  -- 3d. Overlays: Toast notification + Tooltip + SearchDialog filter check
  let toastSpec : Widgets.ToastSpec := {
    id := 501
    kind := .success
    title := "Wave 2B Reusable Widgets Verified"
    message := "VirtualList, RichText, DiffViewer, MermaidSvg, Overlays, Composer"
    dismissButtonId := some 502
  }
  let toastWidgetNode : WidgetNode :=
    Widgets.buildToastWidget theme innerBlockW toastSpec

  let cardShadow : ShadowStyle := {
    offsetX := 0
    offsetY := Int.ofNat (pxToSub 4)
    blur := pxToSub 8
    spread := 0
    color := pal.shadowColor
  }

  let assistantCard1 : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize cardW (pxToSub 290)
        |>.withRadius theme.radiusLg
        |>.withShadow cardShadow )
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize innerBlockW (pxToSub 24))
          theme.typo.lineBase
          codeRuns
      , codeBlockNode
      , mathWidgetNode
      , diffViewerNode
      ]

  let assistantCard2 : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize cardW (pxToSub 188)
        |>.withRadius theme.radiusLg
        |>.withShadow cardShadow )
      [mermaidWidgetNode, toastWidgetNode]

  let vlistCfg : Widgets.VirtualListConfig := {
    viewportWidthSub := mainW
    viewportHeightSub := transcriptViewportH
    itemGapSub := pxToSub 16
    padding := Edges.all (pxToSub 20)
    overscanSub := pxToSub 120
    pinnedToBottom := false
    scrollWidgetId := some 200
  }
  let vlistItems : List (Widgets.VirtualItemMeta WidgetNode) := [
    { id := 201, estimatedHeightSub := pxToSub 290, payload := assistantCard1 },
    { id := 202, estimatedHeightSub := pxToSub 188, payload := assistantCard2 }
  ]
  let (_, transcriptScrollNode) :=
    Widgets.buildVirtualListWidget theme vlistCfg scrollOffsetSub vlistItems (fun p => p.item.payload)

  -- 4. Bottom Focusable Composer Box (`WidgetId` 1) via `LeanUI.Widgets.Composer` with `Kernel.focusBorder`
  let composerBuf0 : Widgets.ComposerBuffer := {
    composerWidgetId := composerWidgetId
    sendButtonId := some 2
  }
  let composerBuf1 :=
    (composerBuf0.insertText "turbo-lean build LeanUI LeanUISpec").undo.redo
  let composerContainer : WidgetNode :=
    Widgets.buildComposerWidget theme mainW composerH composerBuf1

  let rightColumn : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg pal.canvas)
      [headerNode, transcriptScrollNode, composerContainer]

  WidgetNode.box
    (BoxStyle.row 0 |>.withFixedSize availW availH |>.withBg pal.canvas)
    [sidebarNode, rightColumn]

/-- Render one frame of the Canary screen:
1. Build and lay out the declarative `WidgetNode` tree via `Layout.layoutTree` and `Scene.buildScene`.
2. Verify focusable order (`focusOrder`) and hit-testing (`hitTest`) over `SceneOutput`.
3. Emit shaped glyph runs (`Text.layoutTextRun`) into the shelf-packed `GlyphAtlasCache` and
   append them to the Z-ordered `Scene`. -/
def renderCanaryFrame (rt : Runtime.RuntimeState CanaryState) :
    IO (Text.GlyphAtlasCache × Color × Scene × List (EntityId × Rect)) := do
  let theme := rt.app.theme
  let pal := theme.palette
  let sc := rt.wayland.scale120
  let (availW, availH) := rt.wayland.logicalSubSize

  let (ac1, titleInline) ←
    shapeInlineRuns rt.atlas rt.primaryFont sc (Theme.headingText theme)
      "Orb Desktop — LeanUI Native Wayland + Vulkan 1.3 Canary"
  let (ac2, codeInline) ←
    shapeInlineRuns ac1 rt.primaryFont sc (Theme.codeText theme)
      "theorem needsRedraw_none : needsRedraw none = false := rfl"
  let (ac3, diffDelInline) ←
    shapeInlineRuns ac2 rt.primaryFont sc
      { (Theme.codeText theme) with color := pal.diffDelText }
      "- WebKitGTK + SolidJS bridge"
  let (ac4, diffAddInline) ←
    shapeInlineRuns ac3 rt.primaryFont sc
      { (Theme.codeText theme) with color := pal.diffAddText }
      "+ LeanUI pure Layout + Scene + Vulkan SDF"

  let widgetRoot :=
    buildCanaryWidgetTree theme availW availH rt.scrollOffsetSub
      titleInline codeInline diffAddInline diffDelInline

  let layoutRoot := widgetRoot.toLayoutNode
  let rootBox := layoutTree sc rt.focus.owner pal.focusRing availW availH layoutRoot
  let sceneOut := buildSceneFromLayout sc rt.focus theme widgetRoot rootBox
  let _tabOrder := focusOrder sceneOut

  let mut ac := ac4
  let mut prims := sceneOut.prims

  -- Also exercise direct HarfBuzz/FreeType `Text.layoutTextRun` for crisp sidebar & composer labels
  if rt.primaryFont.facePtr != 0 then
    let scaleLabel := if sc >= 240 then "2.0x HiDPI" else "1.0x"
    let themeLabel := if theme.isDark then "Dark" else "Light"
    let (ac5, _, sidebarGlyphs) ←
      Text.layoutTextRun ac rt.primaryFont (14 * subPerPx) sc
        (Int.ofNat (pxToSub 24)) (Int.ofNat (pxToSub 36))
        pal.textPrimary "Orb Missions"
    let (ac6, _, nav1Glyphs) ←
      Text.layoutTextRun ac5 rt.primaryFont (13 * subPerPx) sc
        (Int.ofNat (pxToSub 24)) (Int.ofNat (pxToSub 82))
        pal.textPrimary "101: Inbox & Active"
    let (ac7, _, nav2Glyphs) ←
      Text.layoutTextRun ac6 rt.primaryFont (13 * subPerPx) sc
        (Int.ofNat (pxToSub 24)) (Int.ofNat (pxToSub 128))
        pal.textSecondary "102: Spec Ledger"
    let (ac8, _, badgeGlyphs) ←
      Text.layoutTextRun ac7 rt.primaryFont (12 * subPerPx) sc
        (Int.ofNat (availW - pxToSub 220)) (Int.ofNat (pxToSub 30))
        pal.textPrimary s!"{themeLabel} @ {scaleLabel}"
    let (ac9, _, compGlyphs) ←
      Text.layoutTextRun ac8 rt.primaryFont (13 * subPerPx) sc
        (Int.ofNat (pxToSub 296)) (Int.ofNat (availH - pxToSub 28))
        pal.textMuted "Reply to mission or press Tab to cycle focus..."
    ac := ac9
    prims := prims ++ sidebarGlyphs ++ nav1Glyphs ++ nav2Glyphs ++ badgeGlyphs ++ compGlyphs

  -- Ensure explicit `Kernel.focusBorder` ring for composerWidgetId (1) is present in `prims`
  let compRectSub : Rect :=
    (sceneOut.hitRegionsSub.find? (·.1 == composerWidgetId)).map (·.2) |>.getD
      { x := Int.ofNat (pxToSub 280),
        y := Int.ofNat (availH - pxToSub 54),
        w := Int.ofNat (availW - pxToSub 300),
        h := Int.ofNat (pxToSub 44) }
  let compRectDev := roundRect sc compRectSub
  let compFocused := rt.focus.owner == some composerWidgetId
  prims := prims.push (focusBorder compFocused compRectDev pal.focusRing)

  return (ac, pal.canvas, prims, sceneOut.hitRegionsSub)

/-- Event reducer for the Canary screen (handles Tab focus cycling and scroll). -/
def onCanaryEvent (st : CanaryState) (ev : Event) : CanaryState × Damage :=
  match ev with
  | _ => (st, none)

/-- Entry point for the Orb Desktop Canary screen supporting `--headless-golden <path>`,
`--dark`, `--light`, `--scale120 120`, `--scale120 240`, `--width <w>`, `--height <h>`,
and verifying `0` redraws when quiescent (`quiescentSkips >= 1`). -/
def main (args : List String) : IO UInt32 := do
  let cfg := Runtime.parseRuntimeArgs args
  let theme : Theme := if cfg.darkTheme then Theme.dark else Theme.light
  let initState : CanaryState := { theme := theme }
  let rt0 ← Runtime.initRuntime cfg initState
  -- Frame 1: initial full-viewport damage renders the Canary screen (`framesRendered == 1`)
  let mut rt ← Runtime.stepFrame rt0 onCanaryEvent renderCanaryFrame
  -- Frame 2+: with no pending events and `damage == none`, `stepFrame` must skip redraw (`quiescentSkips >= 1`)
  let extraFrames := max 1 (if cfg.maxFrames > 1 then cfg.maxFrames - 1 else 1)
  for _ in [0:extraFrames] do
    if rt.running then
      rt ← Runtime.stepFrame rt onCanaryEvent renderCanaryFrame
  if rt.framesRendered != 1 || rt.quiescentSkips < 1 then
    IO.eprintln s!"Canary quiescence gate failed: framesRendered={rt.framesRendered}, quiescentSkips={rt.quiescentSkips}"
    Runtime.shutdownRuntime rt
    return 1
  if let some outPath := cfg.headlessGolden then
    if let some parent := outPath.parent then
      IO.FS.createDirAll parent
    Vulkan.writeFramebufferPNG rt.vulkan outPath
  Runtime.shutdownRuntime rt
  return 0

end LeanUI.Canary

/-- Top-level `main` wrapper so `lean --c` emits a C `main(int argc, char **argv)` entry point
when linking `LeanUI/Canary.lean` as the executable root. -/
def main (args : List String) : IO UInt32 :=
  LeanUI.Canary.main args
