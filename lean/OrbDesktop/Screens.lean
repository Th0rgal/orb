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
import OrbDesktop.State
import OrbDesktop.Chrome
/-!
# OrbDesktop.Screens — Pure Declarative Builders for All 9 Canonical Orb Desktop Screens (`0` FFI)

Implements the 9 canonical screens (zero FFI, zero IO, kernel-verified):
1. `01_control_empty` (`/?screen=control`)
2. `02_control_populated` (`/?screen=control&fixture=populated`)
3. `03_mission_transcript` (`/?screen=mission&id=m-active`)
4. `04_mission_split_diff` (`/?screen=mission&id=m-diff&mode=split`)
5. `05_machines_fleet` (`/?screen=machines`)
6. `06_settings_general` (`/?screen=settings&tab=general`)
7. `07_search_dialog` (`/?screen=control&modal=search`)
8. `08_new_mission_dialog` (`/?screen=control&modal=new-mission`)
9. `09_toast_notifications` (`/?screen=control&fixture=toasts`)
-/
namespace OrbDesktop

open LeanUI
open LeanUI.Widgets

/-- Pre-shaped inline text runs optionally supplied by the native HarfBuzz/FreeType shaper. -/
structure ShapedScreenRuns where
  headerTitleRuns : List InlineRun := []
  primarySubtitleRuns : List InlineRun := []
  codeSampleRuns : List InlineRun := []
  diffDelRuns : List InlineRun := []
  diffAddRuns : List InlineRun := []
  deriving Repr, Inhabited

/-- Elevation shadow helper for Orb Desktop cards. -/
@[inline] def desktopCardShadow (pal : Palette) : ShadowStyle :=
  { offsetX := 0
    offsetY := Int.ofNat (pxToSub 4)
    blur := pxToSub 10
    spread := 0
    color := pal.shadowColor }

/-! ## 1. `01_control_empty` (`/?screen=control`) -/

/-- Build the empty Control Center hero card with quick-start buttons and architecture diagram. -/
def buildControlEmptyBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let cardW : SubPx := mainW - pxToSub 40
  let innerW : SubPx := cardW - pxToSub 32

  let heroTitle : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 28))
      theme.typo.lineHeading
      [overlaySynthRun (Theme.headingText theme) "Welcome to Orb Desktop — Pure Lean 4 + Vulkan 1.3 Shell"]

  let heroSub : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 22))
      theme.typo.lineBase
      [overlaySynthRun (Theme.secondaryText theme)
        "No active missions in this workspace. Launch a new mission or press Cmd+K to search."]

  let newMissionBtn : WidgetNode :=
    WidgetNode.focusable 310 <|
      WidgetNode.rrect
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .center
          |>.withPadding (Edges.xy (pxToSub 14) (pxToSub 8))
          |>.withFixedSize (pxToSub 164) (pxToSub 36))
        pal.accent
        (CornerRadii.uniform theme.radiusSm)
        BorderStyle.none
        [WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (pxToSub 136) (pxToSub 18))
          theme.typo.lineBase
          [overlaySynthRun { (Theme.bodyText theme) with weight := 600 } "+ New Mission (⌘N)"]]

  let fleetBtn : WidgetNode :=
    WidgetNode.focusable 311 <|
      WidgetNode.rrect
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .center
          |>.withPadding (Edges.xy (pxToSub 14) (pxToSub 8))
          |>.withFixedSize (pxToSub 164) (pxToSub 36))
        pal.surface
        (CornerRadii.uniform theme.radiusSm)
        (BorderStyle.uniform theme.borderWidth pal.border)
        [WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (pxToSub 136) (pxToSub 18))
          theme.typo.lineBase
          [overlaySynthRun (Theme.bodyText theme) "Inspect Fleet (⌘2)"]]

  let actionRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 12) |>.withAlign .center |>.withFixedSize innerW (pxToSub 42))
      [newMissionBtn, fleetBtn]

  let archDiagram : DiagramSpec := {
    title := "Zero-WebView Native Pipeline (0 FFI Pure Core -> Vulkan 1.3 SDF)"
    direction := .leftRight
    nodeWidthSub := pxToSub 132
    nodeHeightSub := pxToSub 36
    rankGapSub := pxToSub 36
    columnGapSub := pxToSub 14
    nodes := [
      { id := 1, label := "OrbDesktop.State", rank := 0, column := 0, shape := .rounded, widgetId := some 312 },
      { id := 2, label := "LeanUI.Layout", rank := 1, column := 0, shape := .rounded, widgetId := some 313 },
      { id := 3, label := "Vulkan 1.3 SDF", rank := 2, column := 0, shape := .pill, accentColor := some pal.success, widgetId := some 314 }
    ]
    edges := [
      { fromId := 1, toId := 2, label := "pure" },
      { fromId := 2, toId := 3, label := "damage" }
    ]
  }
  let diagramNode := buildMermaidDiagramWidget theme innerW archDiagram

  let heroCard : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize cardW (pxToSub 268)
        |>.withRadius theme.radiusLg
        |>.withShadow (desktopCardShadow pal) )
      [heroTitle, heroSub, actionRow, diagramNode]

  WidgetNode.box
    (BoxStyle.col (pxToSub 16)
      |>.withPadding (Edges.all (pxToSub 20))
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    [heroCard]

/-! ## 2. `02_control_populated` (`/?screen=control&fixture=populated`), `07`, `08`, `09` -/

/-- Build a single mission summary card for the populated Control Center. -/
def buildMissionSummaryCardWidget (theme : Theme) (cardW : SubPx) (mc : MissionSummaryCard) : WidgetNode :=
  let pal := theme.palette
  let innerW := cardW - pxToSub 28
  let badgeCol := statusBadgeColor pal mc.status
  let badgeBg :=
    if mc.status == "running" then pal.accentMuted
    else if mc.status == "awaiting_approval" then pal.diffDelBg
    else pal.diffAddBg
  let titleStyle : TextStyle := { (Theme.headingText theme) with sizeSub := theme.typo.md }
  let metaStyle := Theme.mutedText theme
  let bodyStyle := Theme.secondaryText theme

  let topRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withFixedSize innerW (pxToSub 26))
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (innerW - pxToSub 148) (pxToSub 22))
          theme.typo.lineBase
          [overlaySynthRun titleStyle mc.title]
      , WidgetNode.rrect
          (BoxStyle.row 0
            |>.withAlign .center
            |>.withJustify .center
            |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 3))
            |>.withFixedSize (pxToSub 128) (pxToSub 22))
          badgeBg
          (CornerRadii.uniform theme.radiusSm)
          (BorderStyle.uniform theme.borderWidth badgeCol)
          [WidgetNode.text
            (BoxStyle.row 0 |>.withFixedSize (pxToSub 110) (pxToSub 16))
            theme.typo.lineTight
            [overlaySynthRun { metaStyle with weight := 600, color := badgeCol } mc.status]]
      ]

  let summaryRow : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 20))
      theme.typo.lineBase
      [overlaySynthRun bodyStyle mc.summaryText]

  let footerMetaStr := s!"{mc.project} / {mc.track}  ·  model: {mc.model}  ·  {mc.updatedLabel}"
  let metaRow : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 18))
      theme.typo.lineTight
      [overlaySynthRun metaStyle footerMetaStr]

  let rawCard : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 14))
        |>.withFixedSize cardW (pxToSub 102)
        |>.withRadius theme.radiusMd
        |>.withShadow (desktopCardShadow pal) )
      [topRow, summaryRow, metaRow]
      (some mc.widgetId)
  WidgetNode.focusable mc.widgetId rawCard

/-- Build the populated Control Center body (`02_control_populated`, and background for `07`, `08`, `09`). -/
def buildControlPopulatedBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let cardW : SubPx := mainW - pxToSub 40

  let toastNodes := buildToastStackChrome theme mainW st.toasts
  let modalNodes := buildModalOverlayChrome theme mainW st.modal

  let statsBar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 16)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 16) (pxToSub 10))
        |>.withFixedSize cardW (pxToSub 44))
      pal.elevatedSurface
      (CornerRadii.uniform theme.radiusMd)
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (cardW - pxToSub 240) (pxToSub 20))
          theme.typo.lineBase
          [overlaySynthRun (Theme.bodyText theme)
            "Active Campaign: lean-ui  ·  3 missions (1 running, 1 awaiting approval, 1 completed)"]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 180) (pxToSub 24))
          pal.diffAddBg
          (CornerRadii.uniform theme.radiusSm)
          (BorderStyle.uniform theme.borderWidth pal.success)
          [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 160) (pxToSub 16)) theme.typo.lineTight
            [overlaySynthRun { (Theme.mutedText theme) with color := pal.diffAddText } "124/124 Specs Verified"]]
      ]

  let cards := st.missionCards.map (buildMissionSummaryCardWidget theme cardW)

  WidgetNode.box
    (BoxStyle.col (pxToSub 12)
      |>.withPadding (Edges.all (pxToSub 20))
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    (modalNodes ++ toastNodes ++ [statsBar] ++ cards)

/-! ## 3. `03_mission_transcript` (`/?screen=mission&id=m-active`) -/

/-- Build the scrollable Mission Transcript body (`03_mission_transcript`) with `VirtualList`,
`RichText` (`CodeBlock` + KaTeX `MathExpr`), unified `DiffViewer`, and `MermaidSvg` diagram. -/
def buildMissionTranscriptBody (st : DesktopState) (mainW bodyH : SubPx)
    (runs : ShapedScreenRuns) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let cardW : SubPx := mainW - pxToSub 40
  let innerW : SubPx := cardW - pxToSub 32

  let codeBlockNode : WidgetNode :=
    buildCodeBlockWidget theme innerW "lean4"
      [ [ { text := "theorem ", role := .keyword }
        , { text := "needsRedraw_none ", role := .functionName }
        , { text := ": ", role := .operator }
        , { text := "needsRedraw none = false ", role := .typeName }
        , { text := ":= rfl", role := .keyword }
        ]
      , [ { text := "theorem ", role := .keyword }
        , { text := "pinned_layout_at_bottom ", role := .functionName }
        , { text := ": ", role := .operator }
        , { text := "gap h c (layout s h c d).top = 0 ", role := .typeName }
        , { text := ":= by simp; omega", role := .keyword }
        ]
      ]
      (some 301)

  let katexExpr : MathExpr :=
    .row
      [ .atom "SSIM" false
      , .delimited "(" ")" (.atom "G, R" true)
      , .operator "="
      , .fraction
          (.row [.delimited "(" ")" (.atom "2μ_G μ_R + c_1" true), .delimited "(" ")" (.atom "2σ_{GR} + c_2" true)])
          (.row [.delimited "(" ")" (.superscript (.atom "μ_G") (.atom "2" false)), .operator "+", .radical (.atom "N")])
      , .operator "≥"
      , .atom "0.985" false
      ]
  let mathWidgetNode : WidgetNode :=
    buildRichBlockWidget theme innerW (.mathBlock katexExpr)

  let diffSpec : DiffFileSpec := {
    filePath := "lean/OrbDesktop/Screens.lean"
    mode := .unified
    collapsed := false
    additions := 2
    deletions := 1
    collapseToggleId := some 302
    modeToggleId := some 303
    lines := [
      { kind := .del, oldLine := some 18, newLine := none, text := "- webkit_web_view_load_uri(wv, orb_dev_url);", runs := runs.diffDelRuns },
      { kind := .add, oldLine := none, newLine := some 18, text := "+ buildDesktopScreen st availW availH shapedRuns", runs := runs.diffAddRuns },
      { kind := .add, oldLine := none, newLine := some 19, text := "+ Vulkan.renderFrame vk clearColor atlas scene", runs := [] }
    ]
  }
  let diffNode : WidgetNode := buildDiffViewerWidget theme innerW diffSpec

  let diagramSpec : DiagramSpec := {
    title := "OrbDesktop Native Turn Pipeline"
    direction := .leftRight
    nodeWidthSub := pxToSub 124
    nodeHeightSub := pxToSub 34
    rankGapSub := pxToSub 32
    columnGapSub := pxToSub 14
    nodes := [
      { id := 1, label := "Orb.Stream", rank := 0, column := 0, shape := .rounded, widgetId := some 401 },
      { id := 2, label := "VirtualList", rank := 1, column := 0, shape := .rounded, widgetId := some 402 },
      { id := 3, label := "Vulkan SDF", rank := 2, column := 0, shape := .pill, accentColor := some pal.success, widgetId := some 403 }
    ]
    edges := [
      { fromId := 1, toId := 2, label := "coalesce" },
      { fromId := 2, toId := 3, label := "raster" }
    ]
  }
  let mermaidNode : WidgetNode := buildMermaidDiagramWidget theme innerW diagramSpec

  let leadRuns :=
    if runs.codeSampleRuns.isEmpty then
      [overlaySynthRun (Theme.bodyText theme)
        "Turn #1 (builtin/smart) — Verified pure Lean 4 layout, KaTeX math, and unified diff:"]
    else runs.codeSampleRuns

  let card1 : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize cardW (pxToSub 330)
        |>.withRadius theme.radiusLg
        |>.withShadow (desktopCardShadow pal) )
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 22))
          theme.typo.lineBase
          leadRuns
      , codeBlockNode
      , mathWidgetNode
      , diffNode
      ]

  let card2 : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize cardW (pxToSub 140)
        |>.withRadius theme.radiusLg
        |>.withShadow (desktopCardShadow pal) )
      [mermaidNode]

  let vlistCfg : VirtualListConfig := {
    viewportWidthSub := mainW
    viewportHeightSub := bodyH
    itemGapSub := pxToSub 14
    padding := Edges.all (pxToSub 20)
    overscanSub := pxToSub 120
    pinnedToBottom := false
    scrollWidgetId := some 200
  }
  let vlistItems : List (VirtualItemMeta WidgetNode) := [
    { id := 201, estimatedHeightSub := pxToSub 330, payload := card1 },
    { id := 202, estimatedHeightSub := pxToSub 140, payload := card2 }
  ]
  let (_, scrollNode) :=
    buildVirtualListWidget theme vlistCfg st.scroll.topSub vlistItems (fun p => p.item.payload)
  scrollNode

/-! ## 4. `04_mission_split_diff` (`/?screen=mission&id=m-diff&mode=split`) -/

/-- Build the Split Side-by-Side Diff Review screen (`04_mission_split_diff`). -/
def buildMissionSplitDiffBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let cardW : SubPx := mainW - pxToSub 40
  let innerW : SubPx := cardW - pxToSub 32

  let splitSpec1 : DiffFileSpec := {
    filePath := "linux_shell/gtk_chrome.c -> lean/OrbDesktop/Chrome.lean"
    mode := .split
    collapsed := false
    additions := 4
    deletions := 4
    collapseToggleId := some 411
    modeToggleId := some 412
    lines := [
      { kind := .hunkHeader, oldLine := some 1, newLine := some 1, text := "@@ -1,4 +1,4 @@ Native Sidebar & Command Palette" },
      { kind := .del, oldLine := some 23, newLine := none, text := "GtkWidget *win, *wv, *paned, *sb_list;" },
      { kind := .add, oldLine := none, newLine := some 23, text := "def buildSidebarChrome (st : DesktopState) : WidgetNode" },
      { kind := .del, oldLine := some 49, newLine := none, text := "webkit_web_view_evaluate_javascript(wv, js);" },
      { kind := .add, oldLine := none, newLine := some 49, text := "def stepDesktopEvent (st : DesktopState) (ev : Event)" },
      { kind := .context, oldLine := some 52, newLine := some 52, text := "-- Single-owner pure state store (0 FFI)" },
      { kind := .del, oldLine := some 80, newLine := none, text := "connect_loopback(j->port, 0);" },
      { kind := .add, oldLine := none, newLine := some 80, text := "SyncCursorState.step cur inEpoch inSeq true true" }
    ]
  }

  let splitSpec2 : DiffFileSpec := {
    filePath := "lean/OrbDesktop/Main.lean"
    mode := .split
    collapsed := false
    additions := 3
    deletions := 1
    collapseToggleId := some 413
    modeToggleId := some 414
    lines := [
      { kind := .context, oldLine := some 10, newLine := some 10, text := "def main (args : List String) : IO UInt32 := do" },
      { kind := .del, oldLine := some 11, newLine := none, text := "  -- single canary golden" },
      { kind := .add, oldLine := none, newLine := some 11, text := "  -- 36-golden matrix (9 screens x 2 themes x 2 scales)" },
      { kind := .add, oldLine := none, newLine := some 12, text := "  renderAllGoldens outDir" }
    ]
  }

  let viewer1 := buildDiffViewerWidget theme innerW splitSpec1
  let viewer2 := buildDiffViewerWidget theme innerW splitSpec2

  let diffCard : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize cardW (bodyH - pxToSub 40)
        |>.withRadius theme.radiusLg
        |>.withShadow (desktopCardShadow pal) )
      [viewer1, viewer2]

  WidgetNode.box
    (BoxStyle.col (pxToSub 14)
      |>.withPadding (Edges.all (pxToSub 20))
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    [diffCard]

/-! ## 5. `05_machines_fleet` (`/?screen=machines`) -/

/-- Build a single compute node / managed VM card for `05_machines_fleet`. -/
def buildFleetMachineCardWidget (theme : Theme) (cardW : SubPx) (mc : FleetMachineCard) : WidgetNode :=
  let pal := theme.palette
  let innerW := cardW - pxToSub 28
  let badgeCol := if mc.state == "running" then pal.success else pal.accent
  let badgeBg := if mc.state == "running" then pal.diffAddBg else pal.accentMuted
  let titleStyle : TextStyle := { (Theme.headingText theme) with sizeSub := theme.typo.md }
  let bodyStyle := Theme.secondaryText theme
  let metaStyle := Theme.mutedText theme

  let headerRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withFixedSize innerW (pxToSub 26))
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (innerW - pxToSub 160) (pxToSub 22))
          theme.typo.lineBase
          [overlaySynthRun titleStyle s!"{mc.name}  ·  {mc.roleLabel}"]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 120) (pxToSub 22))
          badgeBg
          (CornerRadii.uniform theme.radiusSm)
          (BorderStyle.uniform theme.borderWidth badgeCol)
          [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 100) (pxToSub 16)) theme.typo.lineTight
            [overlaySynthRun { metaStyle with weight := 600, color := badgeCol } mc.state]]
      ]

  let specRow : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 20))
      theme.typo.lineBase
      [overlaySynthRun bodyStyle s!"Hardware: {mc.cpuRamSpec}   ·   Active Missions: {mc.activeMissions}"]

  let costRow : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 18))
      theme.typo.lineTight
      [overlaySynthRun metaStyle s!"Node ID: {mc.machineId}   ·   {mc.ttlLabel}   ·   Rate: {mc.costLabel}"]

  let rawCard : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 14))
        |>.withFixedSize cardW (pxToSub 102)
        |>.withRadius theme.radiusMd
        |>.withShadow (desktopCardShadow pal) )
      [headerRow, specRow, costRow]
      (some mc.widgetId)
  WidgetNode.focusable mc.widgetId rawCard

/-- Build the Compute Fleet screen (`05_machines_fleet`). -/
def buildMachinesFleetBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let cardW : SubPx := mainW - pxToSub 40

  let budgetBanner : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 16)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 16) (pxToSub 10))
        |>.withFixedSize cardW (pxToSub 48))
      pal.elevatedSurface
      (CornerRadii.uniform theme.radiusMd)
      (BorderStyle.uniform theme.borderWidth pal.border)
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (cardW - pxToSub 220) (pxToSub 20))
          theme.typo.lineBase
          [overlaySynthRun (Theme.bodyText theme)
            "Managed Compute Fleet (boat.dev EU + Static Core)  ·  3 Nodes Online  ·  Pool Spend: $0.18 / $25.00"]
      , WidgetNode.focusable 510 <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 156) (pxToSub 28))
            pal.accent
            (CornerRadii.uniform theme.radiusSm)
            BorderStyle.none
            [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 136) (pxToSub 16)) theme.typo.lineTight
              [overlaySynthRun { (Theme.secondaryText theme) with weight := 600, color := pal.textPrimary } "+ Spawn Managed VM"]]
      ]

  let machineNodes := st.fleetMachines.map (buildFleetMachineCardWidget theme cardW)

  WidgetNode.box
    (BoxStyle.col (pxToSub 12)
      |>.withPadding (Edges.all (pxToSub 20))
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    (budgetBanner :: machineNodes)

/-! ## 6. `06_settings_general` (`/?screen=settings&tab=general`) -/

/-- Build the Settings (`general` tab) screen (`06_settings_general`) using `Field`, `Select`, and `Toast`. -/
def buildSettingsGeneralBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let cardW : SubPx := mainW - pxToSub 40
  let innerW : SubPx := cardW - pxToSub 32
  let controlW : SubPx := min (pxToSub 520) innerW

  let tabBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10) |>.withAlign .center |>.withFixedSize innerW (pxToSub 36))
      [ WidgetNode.focusable 601 <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 110) (pxToSub 30))
            pal.accentMuted
            (CornerRadii.uniform theme.radiusSm)
            (BorderStyle.uniform theme.borderWidth pal.accent)
            [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 84) (pxToSub 16)) theme.typo.lineTight
              [overlaySynthRun { (Theme.bodyText theme) with weight := 600 } "General"]]
      , WidgetNode.focusable 602 <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 110) (pxToSub 30))
            pal.surface
            (CornerRadii.uniform theme.radiusSm)
            (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
            [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 84) (pxToSub 16)) theme.typo.lineTight
              [overlaySynthRun (Theme.secondaryText theme) "Appearance"]]
      , WidgetNode.focusable 603 <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 120) (pxToSub 30))
            pal.surface
            (CornerRadii.uniform theme.radiusSm)
            (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
            [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 96) (pxToSub 16)) theme.typo.lineTight
              [overlaySynthRun (Theme.secondaryText theme) "Wayland & GPU"]]
      ]

  let apiField : FieldSpec := {
    id := 611
    label := "Orb Core Loopback Endpoint"
    value := "http://127.0.0.1:4173"
    placeholder := "http://127.0.0.1:<port>"
  }
  let fontField : FieldSpec := {
    id := 612
    label := "Primary UI Font Family (Fontconfig + FreeType + HarfBuzz)"
    value := "Inter / sans-serif (Subpixel 1/64 px)"
    placeholder := "sans-serif"
  }
  let themeSelect : SelectSpec := {
    triggerId := 613
    label := "Theme & HiDPI Fractional Scale"
    selectedIdx := if theme.isDark then 0 else 1
    isOpen := false
    options := [
      { value := "dark", label := "Orb Dark Theme (Default)", optionWidgetId := 621 },
      { value := "light", label := "Orb Light Theme (Daylight)", optionWidgetId := 622 }
    ]
  }
  let statusToast : ToastSpec := {
    id := 614
    kind := .success
    title := "Vulkan 1.3 SDF Uber-Shader Active"
    message := "Quiescent frame gate enabled: 0 redraws when needsRedraw damage = false."
    dismissButtonId := some 615
  }

  let settingsCard : WidgetNode :=
    WidgetNode.box
      ( (Theme.cardBox theme)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize cardW (pxToSub 340)
        |>.withRadius theme.radiusLg
        |>.withShadow (desktopCardShadow pal) )
      [ tabBar
      , buildFieldWidget theme controlW apiField
      , buildFieldWidget theme controlW fontField
      , buildSelectWidget theme controlW themeSelect
      , buildToastWidget theme innerW statusToast
      ]

  WidgetNode.box
    (BoxStyle.col (pxToSub 14)
      |>.withPadding (Edges.all (pxToSub 20))
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    [settingsCard]

/-! ## 7. Complete `OrbDesktop` Screen Assembly -/

/-- Build the complete declarative `WidgetNode` tree for any `DesktopState`, viewport `(availW, availH)`
in `SubPx`, and optional pre-shaped `ShapedScreenRuns`. -/
def buildDesktopScreen (st : DesktopState) (availW availH : SubPx)
    (runs : ShapedScreenRuns := {}) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let sidebarW := chromeSidebarWidthSub
  let headerH := chromeHeaderHeightSub
  let composerH := chromeComposerHeightSub
  let mainW : SubPx := availW - sidebarW
  let bodyH : SubPx := availH - headerH - composerH

  let sidebarNode := buildSidebarChrome st availH
  let headerNode := buildHeaderChrome st mainW runs.headerTitleRuns

  let bodyNode : WidgetNode :=
    match st.screen with
    | .controlEmpty       => buildControlEmptyBody st mainW bodyH
    | .controlPopulated   => buildControlPopulatedBody st mainW bodyH
    | .missionTranscript  => buildMissionTranscriptBody st mainW bodyH runs
    | .missionSplitDiff   => buildMissionSplitDiffBody st mainW bodyH
    | .machinesFleet      => buildMachinesFleetBody st mainW bodyH
    | .settingsGeneral    => buildSettingsGeneralBody st mainW bodyH
    | .searchDialog       => buildControlPopulatedBody st mainW bodyH
    | .newMissionDialog   => buildControlPopulatedBody st mainW bodyH
    | .toastNotifications => buildControlPopulatedBody st mainW bodyH

  let composerNode := buildComposerWidget theme mainW composerH st.composer

  let rightColumn : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg pal.canvas)
      [headerNode, bodyNode, composerNode]

  WidgetNode.box
    (BoxStyle.row 0 |>.withFixedSize availW availH |>.withBg pal.canvas)
    [sidebarNode, rightColumn]

end OrbDesktop
