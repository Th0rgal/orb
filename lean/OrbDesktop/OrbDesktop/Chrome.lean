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

/-- Chrome SVG strokes from `orb/src/icons.tsx`, in tenths of a 16px view box. -/
def chromeIconPaths (name : String) : List (List (Int × Int)) :=
  match name with
  | "nav:new" => [[(25,30),(135,30),(95,82),(95,130),(65,114),(65,82),(25,30)]]
  | "nav:inbox" => [[(22,92),(37,35),(49,26),(111,26),(123,35),(138,92),(138,123),(126,135),(34,135),(22,123),(22,92)],[(23,93),(57,93),(66,108),(94,108),(103,93),(137,93)]]
  | "nav:machines" => [[(35,24),(125,24),(140,39),(140,91),(125,106),(35,106),(20,91),(20,39),(35,24)],[(80,106),(80,128)],[(52,136),(108,136)]]
  | "server" => [[(20,28),(140,28),(140,68),(20,68),(20,28)],[(20,92),(140,92),(140,132),(20,132),(20,92)],[(38,48),(38,48)],[(38,112),(38,112)]]
  | "nav:inference" | "s:models" => [[(80,24),(134,54),(134,106),(80,136),(26,106),(26,54),(80,24)],[(26,54),(80,84),(134,54)],[(80,84),(80,136)]]
  | "nav:resources" => [[(24,42),(48,42),(62,48),(80,70),(100,80),(136,80)],[(24,118),(48,118),(62,112),(80,90),(100,80)],[(116,58),(138,80),(116,102)]]
  | "nav:cloud" => [[(42,125),(25,121),(16,108),(17,92),(26,79),(43,73),(51,53),(68,44),(87,45),(104,56),(111,73),(126,74),(140,86),(143,103),(135,119),(122,125),(42,125)]]
  | "nav:settings" | "s:account" => [[(100,80),(94,94),(80,100),(66,94),(60,80),(66,66),(80,60),(94,66),(100,80)],[(80,18),(92,36),(113,32),(120,52),(139,62),(130,80),(139,98),(120,108),(113,128),(92,124),(80,142),(68,124),(47,128),(40,108),(21,98),(30,80),(21,62),(40,52),(47,32),(68,36),(80,18)]]
  | "s:back" | "back" => [[(130,80),(30,80)],[(70,40),(30,80),(70,120)]]
  | "forward" => [[(30,80),(130,80)],[(90,40),(130,80),(90,120)]]
  | "sidebar" => [[(40,30),(120,30),(140,40),(140,120),(120,130),(40,130),(20,120),(20,40),(40,30)],[(60,30),(60,130)]]
  | "search" => [[(114,72),(108,93),(93,108),(72,114),(51,108),(36,93),(30,72),(36,51),(51,36),(72,30),(93,36),(108,51),(114,72)],[(104,104),(135,135)]]
  | "s:security" => [[(84,80),(77,97),(60,104),(43,97),(36,80),(43,63),(60,56),(77,63),(84,80)],[(82,80),(134,80),(121,94)],[(112,80),(112,96)]]
  | "s:notifs" => [[(80,26),(60,32),(48,58),(48,79),(32,104),(128,104),(112,79),(112,58),(100,32),(80,26)],[(64,124),(70,135),(90,135),(96,124)]]
  | "s:agents" => [[(80,20),(140,50),(80,80),(20,50),(80,20)],[(20,80),(80,110),(140,80)],[(20,110),(80,140),(140,110)]]
  | "mission" => [[(40,55),(120,55),(130,65),(130,115),(30,115),(30,65),(40,55)],[(80,55),(80,30),(60,30)],[(55,75),(55,90)],[(105,75),(105,90)],[(10,75),(10,95)],[(150,75),(150,95)]]
  | "rename" => [[(28,112),(25,136),(49,130),(133,46),(114,27),(28,112)],[(101,41),(120,60)]]
  | "archive" => [[(22,32),(138,32),(138,58),(22,58),(22,32)],[(32,59),(32,132),(128,132),(128,59)],[(61,82),(99,82)]]
  | "copy" => [[(56,56),(136,56),(136,138),(56,138),(56,56)],[(40,106),(24,106),(24,22),(106,22),(106,40)]]
  | "check" => [[(22,80),(60,118),(138,40)]]
  | "plus" => [[(40,80),(120,80)],[(80,40),(80,120)]]
  | "close" => [[(45,45),(115,115)],[(115,45),(45,115)]]
  | "chevron-down" => WidgetNode.downChevronPaths
  | "chevron-right" => [[(65,50),(95,80),(65,110)]]
  | "file" => [[(42,24),(94,24),(120,52),(120,136),(108,148),(42,148),(30,136),(30,36),(42,24)],[(92,25),(92,53),(120,53)]]
  | "folder" => [[(20,48),(20,38),(28,30),(61,30),(76,46),(122,46),(140,64),(140,114),(132,132),(38,132),(20,114),(20,48)]]
  | "chat" => [[(30,110),(20,140),(60,120),(100,120),(130,100),(140,70),(130,40),(100,20),(60,20),(30,40),(20,70),(30,110)],[(50,60),(110,60)],[(50,85),(90,85)]]
  | "list" => [[(30,40),(130,40)],[(30,80),(100,80)],[(30,120),(130,120)]]
  | "project-folder" => [[(133,133),(143,129),(147,120),(147,53),(143,44),(133,40),(81,40),(74,38),(69,34),(64,26),(59,22),(53,20),(27,20),(17,24),(13,33),(13,120),(17,129),(27,133),(133,133)]]
  | _ => [[(20,48),(20,38),(28,30),(61,30),(76,46),(122,46),(140,64),(140,114),(132,132),(38,132),(20,114),(20,48)]]

def chromeIcon (name : String) (color : Color) (size : Nat := 16) : WidgetNode :=
  .mk none false false (BoxStyle.row 0 |>.withFixedSize (pxToSub size) (pxToSub size))
    (.vectorIcon (chromeIconPaths name) color) []

def liveComposerControls (st : DesktopState) (width : SubPx) : WidgetNode :=
  let mid := st.openMission.getD ""
  let v := currentSettings st mid
  let control := fun (id : Nat) (label : String) (interactive : Bool) =>
    let text := WidgetNode.text (BoxStyle.row 0) (pxToSub 18) [overlaySynthRun (Theme.mutedText st.theme) label]
    let raw := WidgetNode.box (BoxStyle.row (pxToSub 3) |>.withAlign .center)
      ([text] ++ (if interactive then [chromeIcon "chevron-down" st.theme.palette.textMuted 10] else []))
    if interactive then WidgetNode.focusable id raw else raw
  let display := fun (s fallback : String) => if s.isEmpty then fallback else s
  let machine := ((st.fleetMachines.find? (·.machineId == v.machine)).map (·.name)).getD v.machine
  let harness := ((st.catalog.find? (·.backend == v.backend)).map (·.harnessName)).getD v.backend
  let model := ((st.catalog.find? fun c => c.backend == v.backend && c.model == v.model).map (·.modelName)).getD v.model
  let children := [control 720 (display machine "Default machine") mid.isEmpty,
    control 721 (display harness "Harness") true, control 722 (display model "Model") true] ++
    (if ["codex","antigravity","claudecode"].contains v.backend then [control 723 (display v.effort "Default effort") true] else []) ++
    (if v.backend == "claudecode" then [control 724 v.permission true] else [])
  WidgetNode.box (BoxStyle.row (pxToSub 12) |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 12) 0)
    |>.withFixedSize width (pxToSub 36)) children

def buildMissionMenu (st : DesktopState) (menu : MissionMenu) (width : SubPx) (visibleCount : Nat) : WidgetNode :=
  let pal := st.theme.palette
  let rows := (((missionMenuRows st menu).drop menu.first).take visibleCount).mapIdx fun i item =>
    let label := WidgetNode.text { BoxStyle.row 0 with grow := 1 } (pxToSub 18)
      [overlaySynthRun (Theme.bodyText st.theme) item.label]
    let row := WidgetNode.focusable item.id <| WidgetNode.box
      (BoxStyle.row (pxToSub 9) |>.withBg (if menu.first + i == menu.highlighted then pal.accentMuted else pal.elevatedSurface)
        |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 8) 0)
        |>.withFixedSize (width - pxToSub 12) (pxToSub 30))
      ([chromeIcon item.icon pal.textMuted 14, label] ++
        (if item.id == 711 || (menu.page == .settings && (settingTrigger item.id).isSome) then [chromeIcon "chevron-right" pal.textMuted 12] else []))
    if item.separatorBefore then
      [WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (width - pxToSub 12) (pxToSub 1) |>.withBg pal.border) [], row]
    else [row]
  WidgetNode.box
    (BoxStyle.col 0 |>.withPadding (Edges.all (pxToSub 6)) |>.withRadius (pxToSub 10)
      |>.withBorder st.theme.borderWidth pal.border |>.withBg pal.elevatedSurface)
    rows.flatten

/-- Semantic status indicator color for a sidebar row or mission status string. -/
@[inline] def statusBadgeColor (pal : Palette) (status : String) : Color :=
  match status with
  | "running"           => pal.accent
  | "completed"         => pal.success
  | "awaiting_approval" => pal.warning
  | "attention"         => pal.warning
  | "failed"            => pal.danger
  | _                   => pal.textMuted

/-- Live rows use the same status vocabulary and badge tones as MissionGlyph. -/
def liveBadgeKind (status : String) : String :=
  match status with
  | "active" | "running" | "starting" | "resuming" | "working" | "in_progress" | "processing" | "streaming" => "loader"
  | "pending" | "queued" | "awaiting_wakeup" | "waiting_background" => "clock"
  | "paused" | "interrupted" | "cancelled" => "pause"
  | "completed" | "succeeded" => "check"
  | "blocked" | "failed" | "error" | "errored" | "not_feasible" | "timed_out" => "alert"
  | _ => ""

private def liveMissionLead (theme : Theme) (status : String) (phase : Nat) : WidgetNode :=
  let pal := theme.palette
  let bot := chromeIcon "mission" pal.textMuted
  let kind := liveBadgeKind status
  if kind.isEmpty then bot else
    let ring : List (Int × Int) := [(80,15),(112,24),(136,48),(145,80),(136,112),(112,136),
      (80,145),(48,136),(24,112),(15,80),(24,48),(48,24)]
    let circle := ring ++ ring.take 1
    let paths := match kind with
      | "loader" => [((ring.drop (phase % 12)) ++ (ring.take (phase % 12))).take 10]
      | "clock" => [circle, [(80,40),(80,80),(105,93)]]
      | "pause" => [[(55,36),(55,125)],[(105,36),(105,125)]]
      | "alert" => [circle,[(80,43),(80,86)],[(80,107),(80,111)]]
      | _ => [circle,[(43,81),(69,105),(116,56)]]
    let tone := if kind == "loader" || status == "waiting_background" then pal.accent
      else if kind == "alert" then pal.warning else if kind == "check" then pal.success else pal.textMuted
    .mk none false false (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize (pxToSub 18) (pxToSub 18))
      (.vectorIcon paths tone (some (pal.sidebar ||| 255))) [bot]

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
 the label, and an optional count pill and shortcut hint. -/
def buildSidebarRowWidget (theme : Theme) (innerW : SubPx) (row : ChromeSidebarRow)
    (margin : Edges := {}) (livePhase : Option Nat := none) (expanded : Bool := false) : WidgetNode :=
  let pal := theme.palette
  let small := Theme.mutedText theme
  if row.kind == "section" then
    let isArchives := row.rowId == "section:archives"
    let icon := if isArchives then (if expanded then "chevron-down" else "chevron-right")
      else if row.rowId == "section:archived" then "chevron-right" else "plus"
    let sectionRow := WidgetNode.box
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 (pxToSub 8) 0 (pxToSub 10))
        |>.withMargin margin
        |>.withFixedSize innerW (pxToSub 18))
       [chromeLabel small.lineHeightSub [overlaySynthRun small row.title] 1,
        chromeIcon icon pal.textFaint 14]
       (if isArchives then some row.widgetId else none)
    if isArchives then WidgetNode.focusable row.widgetId sectionRow else sectionRow
  else
    let isFooter := row.kind == "footer"
    let isMission := row.kind == "mission"
    let padLeft : SubPx :=
      if isFooter then pxToSub 8
      else if row.kind == "nav" then (if row.rowId.startsWith "s:" then pxToSub 11 else pxToSub 6)
      else pxToSub 10 + row.depth * pxToSub 16
    let padRight : SubPx := if isFooter then pxToSub 8 else pxToSub 6
    let leadSize : SubPx := if isMission then pxToSub 18 else pxToSub 16
    let projectRunning := row.kind == "project" && ((row.rowId.drop 5).toString.toNat?.getD 99) < 8
    let lead : WidgetNode :=
      .mk none false false
        (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize leadSize leadSize)
        (.treeDecoration isMission row.selected pal.borderSubtle
          (if isMission && livePhase.isNone then statusBadgeColor pal row.status else if projectRunning && livePhase.isNone then pal.accent else 0)
          (if row.selected then pal.rowActive else pal.sidebar))
        [if isMission && livePhase.isSome then liveMissionLead theme row.status (livePhase.getD 0) else chromeIcon (if isMission then "mission" else if row.kind == "project" then "project-folder" else row.rowId) pal.textMuted]
    let labelColor : Color :=
      if isFooter then (if row.selected then pal.textPrimary else pal.textSecondary)
      else if row.selected then pal.textStrong
      else if row.status == "muted" then pal.textMuted
      else if row.kind == "project" then pal.textSecondary
      else pal.textPrimary
    -- Keep the row pitch fixed while lifting the sidebar's optical text baseline.
    let labelStyle := { (chromeText theme labelColor) with lineHeightSub := pxToSub 17 }
    let badge : List WidgetNode :=
      if row.badge == 0 then []
      else if isMission && livePhase.isSome then
        let id := missionDisclosureId row.widgetId
        [WidgetNode.focusable id <| WidgetNode.box
          (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withJustify .center
            |>.withFixedSize (pxToSub 38) (pxToSub 26))
          [chromeLabel small.lineHeightSub [overlaySynthRun small (toString row.badge)],
           chromeIcon (if expanded then "chevron-down" else "chevron-right") pal.textFaint 12] (some id)]
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
        ([lead, if isMission then
            WidgetNode.text
              { (BoxStyle.row 0 |>.withFixedSize (innerW - padLeft - padRight - leadSize - pxToSub 8 - (if badge.isEmpty then 0 else pxToSub 46)) labelStyle.lineHeightSub) with clip := true }
              labelStyle.lineHeightSub [overlaySynthRun labelStyle row.title]
          else chromeLabel labelStyle.lineHeightSub [overlaySynthRun labelStyle row.title] 1]
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
     , { widgetId := 103, rowId := "nav:settings", kind := "footer", title := "Settings", selected := true }
    ]
  else
    let isNewAgent :=
      match scr with
      | .controlEmpty | .controlPopulated | .searchDialog | .newMissionDialog | .toastNotifications => true
      | _ => false
    let isMachines := scr == .machinesFleet
    let isEmptyProjects := scr == .controlEmpty
    let isExpanded := scr == .missionTranscript || scr == .missionSplitDiff
    let navs : List ChromeSidebarRow :=
      [ { widgetId := 101, rowId := "nav:new", kind := "nav", title := "New Agent", shortcut := "⌘N", selected := isNewAgent }
      , { widgetId := 102, rowId := "nav:inbox", kind := "nav", title := "Inbox", shortcut := "⌘I", badge := if isEmptyProjects then 0 else 92 }
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
        (List.range 20).map (fun idx =>
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
  let rowsSource := if useReferenceTree then referenceSidebarRows st.screen else st.visibleProjectRows
  let isNav (r : ChromeSidebarRow) : Bool := r.kind == "nav"
  let isFoot (r : ChromeSidebarRow) : Bool := r.kind == "footer"
  let navRows : List WidgetNode :=
    (rowsSource.filter isNav).mapIdx fun i r =>
      let topM :=
        if i == 0 then (if st.screen == .settingsGeneral then pxToSub 4 else 0)
        else if st.screen == .settingsGeneral && i == 1 then pxToSub 10
        else pxToSub 1
      buildSidebarRowWidget theme rowW r (Edges.trbl topM 0 0 0)
  let archived := fun (r : ChromeSidebarRow) => st.liveData && r.kind == "mission" && r.status == "acknowledged"
  let archiveRows := rowsSource.filter archived
  let archiveGroup : List ChromeSidebarRow := if !st.hasLiveConnection then [] else
    [{ widgetId := 730, rowId := "section:archives", kind := "section", title := "Archived" }] ++
    (if st.archivesOpen then archiveRows else [])
  let treeRows : List WidgetNode :=
    ((rowsSource.filter fun r => !isNav r && !isFoot r && !archived r) ++ archiveGroup).map fun r =>
      if r.kind == "empty" then
        let small := Theme.mutedText theme
        WidgetNode.box
          (BoxStyle.row 0
            |>.withAlign .center
            |>.withPadding (Edges.trbl 0 (pxToSub 8) 0 (pxToSub 10))
            |>.withFixedSize rowW (pxToSub 24))
          [chromeLabel small.lineHeightSub [overlaySynthRun small r.title]]
      else
        buildSidebarRowWidget theme rowW { r with selected := r.selected || st.multiRows.contains r.rowId }
          (if r.kind == "section" then Edges.trbl (pxToSub 14) 0 (pxToSub 4) 0
           else Edges.trbl 0 0 (pxToSub 1) 0) (if st.liveData then some st.badgePhase else none) (if r.rowId == "section:archives" then st.archivesOpen else st.expandedMissions.contains r.rowId)
  let footRows : List WidgetNode :=
    (rowsSource.filter isFoot).map fun r => buildSidebarRowWidget theme rowW r
  let rosterH := availH - chromeHeaderHeightSub - footH
  let rosterStyle := BoxStyle.col 0
    |>.withPadding (Edges.trbl 0 (pxToSub 6) (pxToSub 12) (pxToSub 6))
  let roster := if st.liveData then
      WidgetNode.scrollClip (BoxStyle.col 0 |>.withFixedSize innerW rosterH)
        { offsetY := st.rosterTopSub } (WidgetNode.box rosterStyle (navRows ++ treeRows)) (some rosterViewportId)
    else WidgetNode.box (rosterStyle.withFixedSize innerW rosterH) (navRows ++ treeRows)
  WidgetNode.rrect
    (BoxStyle.col 0
      |>.withPadding (Edges.trbl 0 border 0 0)
      |>.withFixedSize chromeSidebarWidthSub availH)
    pal.sidebar
    CornerRadii.zero
    { widths := Edges.trbl 0 border 0 0, color := pal.borderSubtle }
    [ WidgetNode.box (BoxStyle.row 10 |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 12) 0) |>.withFixedSize innerW chromeHeaderHeightSub)
        [chromeIcon "sidebar" pal.textMuted 14,
         WidgetNode.box (BoxStyle.row 0 |>.withMargin (Edges.trbl 0 0 0 (pxToSub 12))) [chromeIcon "search" pal.textMuted 14],
         WidgetNode.box { BoxStyle.row 0 with grow := 1 } [],
         chromeIcon "back" pal.textMuted 14,
         WidgetNode.box (BoxStyle.row 0 |>.withMargin (Edges.trbl 0 0 0 (pxToSub 12))) [chromeIcon "forward" pal.textFaint 14]]
    , roster
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
      [overlaySynthRun titleStyle st.headerTitle]
    else titleOverrideRuns
  let inset : SubPx :=
    match st.screen with
    | .missionTranscript | .missionSplitDiff => pxToSub 7
    | _ => 0
  let rightButtons : List WidgetNode :=
    match st.screen with
    | .missionTranscript | .missionSplitDiff =>
      let mutedSt : TextStyle := { (Theme.mutedText theme) with sizeSub := pxToSub 12, lineHeightSub := pxToSub 16 }
      [ WidgetNode.box
          (BoxStyle.row (pxToSub 14) |>.withAlign .center |>.withFixedSize (pxToSub 122) (pxToSub 26))
          [ WidgetNode.rrect
              (BoxStyle.row (pxToSub 5) |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 54) (pxToSub 26))
              0 (CornerRadii.uniform (pxToSub 13)) (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
              [chromeIcon "list" pal.textMuted 12, chromeLabel (pxToSub 16) [overlaySynthRun mutedSt "20"]]
          , chromeIcon "file" pal.textSecondary 14
          , chromeIcon "chat" pal.textSecondary 14
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
    ([WidgetNode.box { BoxStyle.row (pxToSub 8) with grow := 1, align := .center }
       ([chromeLabel titleStyle.lineHeightSub titleRuns] ++
         (if inset > 0 then [chromeIcon "nav:cloud" pal.textMuted 14] else []))] ++ rightButtons)

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
