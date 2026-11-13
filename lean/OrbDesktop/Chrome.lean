import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
import LeanUI.Widgets.Overlays
import LeanUI.Widgets.Composer
import OrbDesktop.State
/-!
# OrbDesktop.Chrome — Pure Native Chrome (Sidebar, Header Bar, Modal Overlays & Toast Stack) (`0` FFI)

Implements the pure declarative `WidgetNode` builders for the Orb Desktop shell chrome
(zero FFI, zero IO, kernel-verified), replacing `linux_shell/gtk_chrome.c` with:
- Left navigation sidebar (`buildSidebarChrome`) with workspace header, project tree, status dots,
  shortcut pills, unread badges, and footer status bar
- Top header bar (`buildHeaderChrome`) with navigation breadcrumbs, route pill, sync cursor badge,
  and theme/scale indicator
- Modal overlay layer (`buildModalOverlayChrome`) for `SearchDialog` (`Cmd+K`) and `NewMissionDialog`
- Floating toast stack (`buildToastStackChrome`) for live notifications
-/
namespace OrbDesktop

open LeanUI
open LeanUI.Widgets

/-- Standard sidebar width in logical `SubPx` (`260 px`). -/
@[inline] def chromeSidebarWidthSub : SubPx := pxToSub 260

/-- Standard top header bar height in logical `SubPx` (`48 px`). -/
@[inline] def chromeHeaderHeightSub : SubPx := pxToSub 48

/-- Standard bottom composer height in logical `SubPx` (`64 px`). -/
@[inline] def chromeComposerHeightSub : SubPx := pxToSub 64

/-- Semantic status indicator color for a sidebar row or mission status string. -/
@[inline] def statusBadgeColor (pal : Palette) (status : String) : Color :=
  match status with
  | "running"           => pal.accent
  | "completed"         => pal.success
  | "awaiting_approval" => pal.warning
  | "attention"         => pal.warning
  | "failed"            => pal.danger
  | _                   => pal.textMuted

/-- Build a single focusable `WidgetNode` row in the left navigation sidebar. -/
def buildSidebarRowWidget (theme : Theme) (innerW : SubPx) (row : ChromeSidebarRow) : WidgetNode :=
  let pal := theme.palette
  let rowH : SubPx := pxToSub 34
  let indentSub : SubPx := row.depth * pxToSub 12
  let bgCol : Color :=
    if row.selected then pal.accentMuted
    else if row.kind == "project" then pal.elevatedSurface
    else pal.sidebar
  let borderCol : Color :=
    if row.selected then pal.accent
    else if row.kind == "project" then pal.borderSubtle
    else 0x00000000
  let borderStyle : BorderStyle :=
    if row.selected || row.kind == "project" then
      BorderStyle.uniform theme.borderWidth borderCol
    else BorderStyle.none
  let titleStyle : TextStyle := {
    (Theme.bodyText theme) with
    weight := if row.selected || row.kind == "project" then 600 else 400
    color := if row.selected then pal.textPrimary else pal.textSecondary
  }
  let metaStyle : TextStyle := Theme.mutedText theme

  let statusDot : List WidgetNode :=
    if row.status.isEmpty then []
    else
      [WidgetNode.rrect
        (BoxStyle.row 0 |>.withFixedSize (pxToSub 8) (pxToSub 8))
        (statusBadgeColor pal row.status)
        (CornerRadii.uniform (pxToSub 4))]

  let labelW : SubPx := innerW - indentSub - pxToSub 76
  let labelNode : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize labelW (pxToSub 18))
      theme.typo.lineTight
      [overlaySynthRun titleStyle row.title]

  let rightTagStr : String :=
    if row.badge > 0 then toString row.badge
    else if !row.shortcut.isEmpty then row.shortcut
    else row.subtitle

  let rightBadge : List WidgetNode :=
    if rightTagStr.isEmpty then []
    else
      let badgeBg := if row.badge > 0 then pal.accent else pal.surface
      let badgeFg := if row.badge > 0 then pal.textPrimary else pal.textMuted
      [WidgetNode.rrect
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .center
          |>.withPadding (Edges.xy (pxToSub 6) (pxToSub 2))
          |>.withFixedSize (pxToSub 44) (pxToSub 20))
        badgeBg
        (CornerRadii.uniform theme.radiusSm)
        (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
        [WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (pxToSub 32) (pxToSub 14))
          theme.typo.lineTight
          [overlaySynthRun { metaStyle with color := badgeFg } rightTagStr]]]

  let rawRow : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 6)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.trbl (pxToSub 6) (pxToSub 10) (pxToSub 6) (pxToSub 10 + indentSub))
        |>.withFixedSize innerW rowH)
      bgCol
      (CornerRadii.uniform theme.radiusSm)
      borderStyle
      (statusDot ++ [labelNode] ++ rightBadge)
      (some row.widgetId)
  WidgetNode.focusable row.widgetId rawRow

/-- Build the complete left navigation sidebar (`260 px` wide) with brand header,
navigation rows, project/mission tree, and sync status footer. -/
def buildSidebarChrome (st : DesktopState) (availH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let sidebarW := chromeSidebarWidthSub
  let innerW := sidebarW - pxToSub 24

  -- 1. Brand / Workspace Switcher Header
  let brandStyle : TextStyle := { (Theme.headingText theme) with sizeSub := theme.typo.md }
  let subStyle : TextStyle := Theme.mutedText theme
  let brandHeader : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 8))
        |>.withFixedSize innerW (pxToSub 42))
      pal.elevatedSurface
      (CornerRadii.uniform theme.radiusMd)
      (BorderStyle.uniform theme.borderWidth pal.border)
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (innerW - pxToSub 76) (pxToSub 20))
          theme.typo.lineBase
          [overlaySynthRun brandStyle "Orb Desktop"]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 48) (pxToSub 20))
          pal.accentMuted
          (CornerRadii.uniform theme.radiusSm)
          (BorderStyle.uniform theme.borderWidth pal.accent)
          [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 36) (pxToSub 14)) theme.typo.lineTight
            [overlaySynthRun { subStyle with color := pal.accent } "Cmd+K"]]
      ]

  -- 2. Sidebar Navigation & Mission Rows
  let rowNodes : List WidgetNode :=
    st.sidebarRows.map (buildSidebarRowWidget theme innerW)

  -- 3. Bottom Sync Cursor & Fleet Status Footer
  let footerStr := s!"Sync e{st.syncCursor.epoch}:s{st.syncCursor.seq} · 0 FFI Pure"
  let footerBox : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 6))
        |>.withFixedSize innerW (pxToSub 32))
      pal.surface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
      [ WidgetNode.rrect
          (BoxStyle.row 0 |>.withFixedSize (pxToSub 8) (pxToSub 8))
          pal.success
          (CornerRadii.uniform (pxToSub 4))
      , WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (innerW - pxToSub 34) (pxToSub 16))
          theme.typo.lineTight
          [overlaySynthRun subStyle footerStr]
      ]

  WidgetNode.rrect
    (BoxStyle.col (pxToSub 8)
      |>.withPadding (Edges.all (pxToSub 12))
      |>.withFixedSize sidebarW availH)
    pal.sidebar
    CornerRadii.zero
    { widths := Edges.trbl 0 theme.borderWidth 0 0, color := pal.border }
    ([brandHeader] ++ rowNodes ++ [footerBox])

/-- Build the top header bar (`48 px` tall) with screen breadcrumb title, route badge,
and theme/scale badge. -/
def buildHeaderChrome (st : DesktopState) (mainW : SubPx)
    (titleOverrideRuns : List InlineRun := []) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let headerH := chromeHeaderHeightSub
  let titleStyle := Theme.headingText theme
  let metaStyle := Theme.mutedText theme
  let titleRuns :=
    if titleOverrideRuns.isEmpty then
      [overlaySynthRun titleStyle st.screen.headerTitle]
    else titleOverrideRuns

  let breadcrumbBox : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize (mainW - pxToSub 360) (pxToSub 24))
      theme.typo.lineBase
      titleRuns

  let routePill : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 4))
        |>.withFixedSize (pxToSub 188) (pxToSub 26))
      pal.surface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
      [WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (pxToSub 168) (pxToSub 16))
        theme.typo.lineTight
        [overlaySynthRun { (Theme.codeText theme) with sizeSub := theme.typo.xs, color := pal.textSecondary }
          st.screen.routeQuery]]

  let scaleStr := if st.scale120 >= 240 then "2.0x HiDPI" else "1.0x"
  let themeStr := if theme.isDark then "Dark" else "Light"
  let themeScaleBadge : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 4))
        |>.withFixedSize (pxToSub 112) (pxToSub 26))
      pal.accentMuted
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.accent)
      [WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (pxToSub 92) (pxToSub 16))
        theme.typo.lineTight
        [overlaySynthRun { metaStyle with weight := 600, color := pal.textPrimary }
          s!"{themeStr} · {scaleStr}"]]

  WidgetNode.rrect
    (BoxStyle.row (pxToSub 12)
      |>.withAlign .center
      |>.withJustify .spaceBetween
      |>.withPadding (Edges.xy (pxToSub 20) (pxToSub 10))
      |>.withFixedSize mainW headerH)
    pal.header
    CornerRadii.zero
    { widths := Edges.trbl 0 0 theme.borderWidth 0, color := pal.border }
    [breadcrumbBox, routePill, themeScaleBadge]

/-- Build the toast notification stack widget for `st.toasts`. -/
def buildToastStackChrome (theme : Theme) (availW : SubPx) (toasts : List ToastSpec) : List WidgetNode :=
  if toasts.isEmpty then []
  else
    let toastW : SubPx := min (pxToSub 520) (availW - pxToSub 40)
    let items := toasts.map (buildToastWidget theme toastW)
    let stackH : SubPx := toasts.length * pxToSub 66 + pxToSub 8
    [WidgetNode.box
      (BoxStyle.col (pxToSub 8)
        |>.withAlign .end_
        |>.withPadding (Edges.xy (pxToSub 20) (pxToSub 6))
        |>.withFixedSize availW stackH)
      items]

/-- Build the active modal overlay widget (`SearchDialog` or `NewMissionDialog`) when `st.modal != .none`. -/
def buildModalOverlayChrome (theme : Theme) (availW : SubPx) (modal : ActiveModal) : List WidgetNode :=
  match modal with
  | .none => []
  | .searchPalette spec =>
    let cardW : SubPx := min (pxToSub 620) (availW - pxToSub 48)
    let paletteCard := buildSearchDialogWidget theme cardW spec
    [WidgetNode.box
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .center
        |>.withPadding (Edges.xy (pxToSub 20) (pxToSub 12))
        |>.withFixedSize availW (pxToSub 248)
        |>.withBg 0x00000066)
      [paletteCard]]
  | .newMission dlg titleF repoF modelSel =>
    let fieldW : SubPx := pxToSub 428
    let f1 := buildFieldWidget theme fieldW titleF
    let f2 := buildFieldWidget theme fieldW repoF
    let s1 := buildSelectWidget theme fieldW modelSel
    let dialogNode := buildDialogWidget theme availW (pxToSub 330) dlg [f1, f2, s1]
    [dialogNode]

end OrbDesktop
