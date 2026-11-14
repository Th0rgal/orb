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
- Left navigation sidebar (`buildSidebarChrome`) with navigation rows, project tree, status dots,
  shortcut hints, count pills, and the settings footer
- Title row (`buildHeaderChrome`) with the screen title
- Modal overlay layer (`buildModalOverlayChrome`) for `SearchDialog` (`Cmd+K`) and `NewMissionDialog`
- Floating toast stack (`buildToastStackChrome`) for live notifications
-/
namespace OrbDesktop

open LeanUI
open LeanUI.Widgets

/-- Semantic status indicator color for a sidebar row or mission status string. -/
@[inline] def statusBadgeColor (pal : Palette) (status : String) : Color :=
  match status with
  | "running"           => pal.accent
  | "completed"         => pal.success
  | "awaiting_approval" => pal.warning
  | "attention"         => pal.warning
  | "failed"            => pal.danger
  | _                   => pal.textMuted

/-- Body text of the SolidJS chrome (`13px/1.4`), laid out on an `18 px` line. -/
def chromeText (theme : Theme) (color : Color) : TextStyle :=
  { (Theme.bodyText theme) with sizeSub := pxToSub 13, lineHeightSub := pxToSub 18, color := color }

/-- Text of the title row (`.tb-title`): chrome body text in `--fg-2`. -/
def chromeTitleStyle (theme : Theme) : TextStyle :=
  chromeText theme theme.palette.textSecondary

/-- One line of text: as tall as its line, as wide as its glyphs, or the free space with `grow`. -/
def chromeLabel (lineH : SubPx) (runs : List InlineRun) (grow : Nat := 0) : WidgetNode :=
  WidgetNode.text
    { BoxStyle.row 0 with grow := grow, minHeight := lineH, maxHeight := lineH }
    lineH
    runs

/-- Build one sidebar row (`.row`, `.section` or `.gear-btn` of the SolidJS desktop): `30 px`
tall with `6 px` corners, a `16 px` icon slot (`18 px` for a mission, holding its status dot),
the label, and an optional count pill and shortcut hint. Icons are not drawn yet. -/
def buildSidebarRowWidget (theme : Theme) (innerW : SubPx) (row : ChromeSidebarRow)
    (margin : Edges := {}) : WidgetNode :=
  let pal := theme.palette
  let small := Theme.mutedText theme
  if row.kind == "section" then
    WidgetNode.box
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 (pxToSub 8) 0 (pxToSub 10))
        |>.withMargin margin
        |>.withFixedSize innerW (pxToSub 18))
      [chromeLabel small.lineHeightSub [overlaySynthRun small row.title]]
  else
    let isFooter := row.kind == "footer"
    let isMission := row.kind == "mission"
    let padLeft : SubPx :=
      if isFooter then pxToSub 8
      else if row.kind == "nav" then pxToSub 6
      else pxToSub 10 + row.depth * pxToSub 16
    let padRight : SubPx := if isFooter then pxToSub 8 else pxToSub 6
    let leadSize : SubPx := if isMission then pxToSub 18 else pxToSub 16
    let lead : WidgetNode :=
      WidgetNode.box
        (BoxStyle.row 0 |>.withAlign .«end» |>.withJustify .end_ |>.withFixedSize leadSize leadSize)
        (if row.status.isEmpty || row.status == "muted" then []
         else
          [WidgetNode.rrect
            (BoxStyle.row 0 |>.withFixedSize (pxToSub 8) (pxToSub 8))
            (statusBadgeColor pal row.status)
            (CornerRadii.uniform (pxToSub 4))])
    let labelColor : Color :=
      if isFooter then (if row.selected then pal.textPrimary else pal.textSecondary)
      else if row.selected then pal.textStrong
      else if row.status == "muted" then pal.textMuted
      else if row.kind == "project" then pal.textSecondary
      else pal.textPrimary
    let labelStyle := chromeText theme labelColor
    let badge : List WidgetNode :=
      if row.badge == 0 then []
      else
        [WidgetNode.rrect
          { BoxStyle.row 0 with
              align := .center, justify := .center, padding := Edges.xy (pxToSub 9 / 2) 0,
              minWidth := pxToSub 16, minHeight := pxToSub 16, maxHeight := pxToSub 16 }
          ((pal.textPrimary &&& 0xFFFFFF00) ||| 0x12)
          (CornerRadii.uniform (pxToSub 8))
          BorderStyle.none
          [chromeLabel small.lineHeightSub [overlaySynthRun small (toString row.badge)]]]
    let shortcut : List WidgetNode :=
      if row.shortcut.isEmpty || isMission then []
      else
        [chromeLabel small.lineHeightSub
          [overlaySynthRun { small with color := pal.textFaint } row.shortcut]]
    WidgetNode.focusable row.widgetId <|
      WidgetNode.rrect
        (BoxStyle.row (pxToSub 8)
          |>.withAlign .center
          |>.withPadding (Edges.trbl 0 padRight 0 padLeft)
          |>.withMargin margin
          |>.withFixedSize innerW (if isFooter then pxToSub 32 else pxToSub 30))
        (if row.selected && !isFooter then pal.rowActive else 0x00000000)
        (CornerRadii.uniform (if isFooter then pxToSub 8 else pxToSub 6))
        BorderStyle.none
        ([lead, chromeLabel labelStyle.lineHeightSub [overlaySynthRun labelStyle row.title] 1]
          ++ badge ++ shortcut)
        (some row.widgetId)

/-- Reference SolidJS sidebar rows for each `ScreenId` when rendering full frames. -/
def referenceSidebarRows (scr : ScreenId) : List ChromeSidebarRow :=
  if scr == .settingsGeneral then
    [ { widgetId := 101, rowId := "s:back", kind := "nav", title := "Back", status := "muted" }
    , { widgetId := 102, rowId := "s:account", kind := "nav", title := "Account", selected := true }
    , { widgetId := 111, rowId := "s:models", kind := "nav", title := "Models" }
    , { widgetId := 112, rowId := "s:agents", kind := "nav", title := "Agents" }
    , { widgetId := 113, rowId := "s:security", kind := "nav", title := "Security" }
    , { widgetId := 114, rowId := "s:notifs", kind := "nav", title := "Notifications" }
    ]
  else
    let isNewAgent :=
      match scr with
      | .controlEmpty | .controlPopulated | .searchDialog | .newMissionDialog | .toastNotifications => true
      | _ => false
    let isMachines := scr == .machinesFleet
    let isEmptyProjects := scr == .controlEmpty || scr == .machinesFleet
    let isExpanded := scr == .missionTranscript || scr == .missionSplitDiff
    let navs : List ChromeSidebarRow :=
      [ { widgetId := 101, rowId := "nav:new", kind := "nav", title := "New Agent", shortcut := "⌘N", selected := isNewAgent }
      , { widgetId := 102, rowId := "nav:inbox", kind := "nav", title := "Inbox", shortcut := "⌘I" }
      , { widgetId := 111, rowId := "nav:cloud", kind := "nav", title := "Cloud agent", shortcut := "⌘2" }
      , { widgetId := 112, rowId := "nav:machines", kind := "nav", title := "Machines", shortcut := "⌘3", selected := isMachines }
      , { widgetId := 113, rowId := "nav:inference", kind := "nav", title := "Inference", shortcut := "⌘4" }
      , { widgetId := 114, rowId := "nav:resources", kind := "nav", title := "Resources", shortcut := "⌘6" }
      , { widgetId := 108, rowId := "section:projects", kind := "section", title := "Projects" }
      ]
    let tree : List ChromeSidebarRow :=
      if isEmptyProjects then
        [ { widgetId := 104, rowId := "empty:projects", kind := "empty", title := "No projects on the core backend." }
        , { widgetId := 109, rowId := "section:archived", kind := "section", title := "Archived" }
        ]
      else if isExpanded then
        [ { widgetId := 104, rowId := "proj:0", kind := "project", depth := 0, title := "Project 0" }
        , { widgetId := 120, rowId := "m:80", kind := "mission", depth := 1, title := "Mission 80 doing some work", status := "completed" }
        , { widgetId := 121, rowId := "m:60", kind := "mission", depth := 1, title := "Mission 60 doing some work", status := "completed" }
        , { widgetId := 122, rowId := "m:40", kind := "mission", depth := 1, title := "Mission 40 doing some work", status := "completed" }
        , { widgetId := 123, rowId := "m:20", kind := "mission", depth := 1, title := "Mission 20 doing some work", status := "completed" }
        , { widgetId := 105, rowId := "m:0", kind := "mission", depth := 1, title := "Long mission", status := "running", selected := true }
        ] ++ (List.range 14).map (fun k =>
          let idx := k + 1
          { widgetId := 130 + idx, rowId := s!"proj:{idx}", kind := "project", depth := 0, title := s!"Project {idx}" })
      else
        (List.range 19).map (fun idx =>
          { widgetId := 130 + idx, rowId := s!"proj:{idx}", kind := "project", depth := 0, title := s!"Project {idx}" })
    navs ++ tree ++ [{ widgetId := 103, rowId := "nav:settings", kind := "footer", title := "Settings" }]

/-- Build the left sidebar (`aside.sidebar`, `--sb-w` wide with a `1 px` right border): an empty
band as tall as the title row, the navigation rows on a `31 px` pitch, the section label and
project tree, and the settings button in a `45 px` footer. -/
def buildSidebarChrome (st : DesktopState) (availH : SubPx) (useReferenceTree : Bool := false) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let border := theme.borderWidth
  let innerW := chromeSidebarWidthSub - border
  let rowW := innerW - pxToSub 12
  let footH := pxToSub 45
  let rowsSource := if useReferenceTree then referenceSidebarRows st.screen else st.sidebarRows
  let isNav (r : ChromeSidebarRow) : Bool := r.kind == "nav"
  let isFoot (r : ChromeSidebarRow) : Bool := r.kind == "footer"
  let navRows : List WidgetNode :=
    (rowsSource.filter isNav).mapIdx fun i r =>
      let topM :=
        if i == 0 then 0
        else if st.screen == .settingsGeneral && i == 1 then pxToSub 14
        else pxToSub 1
      buildSidebarRowWidget theme rowW r (Edges.trbl topM 0 0 0)
  let treeRows : List WidgetNode :=
    (rowsSource.filter fun r => !isNav r && !isFoot r).map fun r =>
      if r.kind == "empty" then
        let small := Theme.mutedText theme
        WidgetNode.box
          (BoxStyle.row 0
            |>.withAlign .center
            |>.withPadding (Edges.trbl 0 (pxToSub 8) 0 (pxToSub 10))
            |>.withFixedSize rowW (pxToSub 24))
          [chromeLabel small.lineHeightSub [overlaySynthRun small r.title]]
      else
        buildSidebarRowWidget theme rowW r
          (if r.kind == "section" then Edges.trbl (pxToSub 14) 0 (pxToSub 4) 0
           else Edges.trbl 0 0 (pxToSub 1) 0)
  let footRows : List WidgetNode :=
    (rowsSource.filter isFoot).map fun r => buildSidebarRowWidget theme rowW r
  WidgetNode.rrect
    (BoxStyle.col 0
      |>.withPadding (Edges.trbl 0 border 0 0)
      |>.withFixedSize chromeSidebarWidthSub availH)
    pal.sidebar
    CornerRadii.zero
    { widths := Edges.trbl 0 border 0 0, color := pal.borderSubtle }
    [ WidgetNode.box (BoxStyle.row 0 |>.withFixedSize innerW chromeHeaderHeightSub) []
    , WidgetNode.box
        (BoxStyle.col 0
          |>.withPadding (Edges.trbl 0 (pxToSub 6) (pxToSub 12) (pxToSub 6))
          |>.withFixedSize innerW (availH - chromeHeaderHeightSub - footH))
        (navRows ++ treeRows)
    , WidgetNode.rrect
        (BoxStyle.row 0
          |>.withPadding (Edges.trbl (pxToSub 6 + border) (pxToSub 6) (pxToSub 6) (pxToSub 6))
          |>.withFixedSize innerW footH)
        0x00000000
        CornerRadii.zero
        (if footRows.isEmpty then BorderStyle.none
         else { widths := Edges.trbl border 0 0 0, color := pal.borderSubtle })
        footRows ]

/-- Build the title row (`header.titlebar`, `--tb-h` tall, no border): the screen title, inset by
the `7 px` padding of the `.session-title` button on a mission. -/
def buildHeaderChrome (st : DesktopState) (mainW : SubPx)
    (titleOverrideRuns : List InlineRun := []) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let titleStyle := chromeTitleStyle theme
  let titleRuns :=
    if titleOverrideRuns.isEmpty then
      [overlaySynthRun titleStyle st.screen.headerTitle]
    else titleOverrideRuns
  let inset : SubPx :=
    match st.screen with
    | .missionTranscript | .missionSplitDiff => pxToSub 7
    | _ => 0
  let rightButtons : List WidgetNode :=
    match st.screen with
    | .missionTranscript | .missionSplitDiff =>
      let bdr := theme.borderWidth
      let mutedSt : TextStyle := { (Theme.mutedText theme) with sizeSub := pxToSub 12, lineHeightSub := pxToSub 16 }
      let secSt : TextStyle := { (Theme.secondaryText theme) with sizeSub := pxToSub 12, lineHeightSub := pxToSub 16 }
      [ WidgetNode.box
          (BoxStyle.row (pxToSub 8) |>.withAlign .center |>.withFixedSize (pxToSub 136) (pxToSub 26))
          [ chromeLabel (pxToSub 16) [overlaySynthRun mutedSt "selected machine"]
          , WidgetNode.rrect
              (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 24) (pxToSub 24))
              (if st.screen == .missionSplitDiff then pal.rowActive else 0x00000000)
              (CornerRadii.uniform (pxToSub 6))
              (if st.screen == .missionSplitDiff then BorderStyle.uniform bdr pal.border else BorderStyle.none)
              [chromeLabel (pxToSub 16) [overlaySynthRun secSt "⇄"]]
          ]
      ]
    | _ => []
  WidgetNode.rrect
    (BoxStyle.row 0
      |>.withAlign .center
      |>.withJustify .spaceBetween
      |>.withPadding (Edges.trbl 0 (pxToSub 10) 0 (pxToSub 14 + inset))
      |>.withFixedSize mainW chromeHeaderHeightSub)
    pal.header
    CornerRadii.zero
    BorderStyle.none
    ([chromeLabel titleStyle.lineHeightSub titleRuns 1] ++ rightButtons)

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
