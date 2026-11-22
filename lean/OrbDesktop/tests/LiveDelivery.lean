import OrbDesktop.Core
import OrbDesktop.Screens
import LeanUI.Runtime

open OrbDesktop LeanUI

private def vp : Rect := { x := 0, y := 0, w := 800, h := 600 }

private def typed : Widgets.ComposerBuffer := { text := "one\n二X", cursorOffset := 6 }
#guard (typed.editKey? 0xff08 0).map (·.text) == some "one\n二"
#guard (typed.editKey? 0xff50 0).map (·.cursorOffset) == some 4
#guard ((typed.editKey? 0xff50 0).bind (·.editKey? 0xffff 0)).map (·.text) == some "one\nX"
#guard ((typed.editKey? 0xff08 0).bind (·.editKey? 0x7a 2)).map (·.text) == some typed.text
#guard ((typed.setPreedit "あ").editKey? 0xff08 0).isNone

-- A Wayland IME can replace both sides of the caret in one committed edit.
private def sourceDraft : Widgets.ComposerBuffer := { text := "a二Xb", cursorOffset := 2 }
private def replacement := sourceDraft.applyImeBatch 3 1 "東京" ""
#guard replacement.text == "a東京b" && replacement.cursorOffset == 3
#guard replacement.undo.text == sourceDraft.text && replacement.undo.cursorOffset == 2
#guard replacement.undo.redo.text == replacement.text
#guard (sourceDraft.applyImeBatch 1 0 "" "候").undoStack.isEmpty

private def hierarchyFixture : DesktopState := {
  DesktopState.liveUnavailable with
  connectionBinding := "fixture"
  missionCards := [{ (default : MissionSummaryCard) with widgetId := 1001, missionId := "m", project := "now" }]
  sidebarRows := [
    { widgetId := 1001, rowId := "mission:m", kind := "mission", title := "Mission" },
    { widgetId := 1000, rowId := "project:now", kind := "project", title := "Now" }] }

#guard (hierarchyFixture.visibleProjectRows.map (·.rowId)) == ["project:now"]
#guard (({ hierarchyFixture with expandedProjects := ["now"] } : DesktopState).visibleProjectRows.map
  (fun r => (r.rowId, r.depth))) == [("project:now", 0), ("mission:m", 1)]

private def hydratedHistory : DesktopState := { hierarchyFixture with
  expandedProjects := ["now"], projectMemberships := [("now", [])] }
#guard (hydratedHistory.visibleProjectRows.map (·.rowId)) == ["project:now"]
#guard hydratedHistory.missionCards.length == 1
#guard (({ hydratedHistory with openMission := some "m" } : DesktopState).visibleProjectRows.map (·.rowId)) ==
  ["project:now", "mission:m"]

-- Cold open: the persisted Core timeline populates completed turns; foreign, empty
-- and identical batches are no-ops that never erase or redraw.
private def coldFixture : DesktopState :=
  { hierarchyFixture with screen := .missionTranscript, openMission := some "m", liveData := true }
#guard (applyHistoryTurns 120 vp coldFixture "m" ["one"]).1.liveTurns == ["one"]
#guard (applyHistoryTurns 120 vp coldFixture "m" ["one"]).2.isSome
#guard (applyHistoryTurns 120 vp coldFixture "other" ["one"]).2.isNone
#guard (applyHistoryTurns 120 vp coldFixture "m" []).2.isNone
#guard (applyHistoryTurns 120 vp { coldFixture with liveTurns := ["one"] } "m" ["one"]).2.isNone
#guard (applyHistoryTurns 120 vp { coldFixture with liveTurns := ["old"] } "m" ["one", "two"]).1.liveTurns == ["one", "two"]

private def treeRow (depth : Nat) (selected := false) : ChromeSidebarRow :=
  { widgetId := 1001, rowId := "row", kind := "mission", title := "Row", depth, selected }
private def treeGeometry (rows : List ChromeSidebarRow) :=
  (sidebarTreeBranches rows).map fun (_, last, children, rails) => (last, children, rails)
#guard treeGeometry [treeRow 0, treeRow 1 true, treeRow 2, treeRow 1] ==
  [(true, true, []), (false, true, []), (true, false, [1]), (true, false, [])]
#guard treeGeometry [treeRow 0, treeRow 1] == [(true, true, []), (true, false, [])]
private def miscFixture : DesktopState := { hierarchyFixture with
  missionCards := [{ (default : MissionSummaryCard) with widgetId := 1001, missionId := "m" }]
  sidebarRows := [hierarchyFixture.sidebarRows.head!, { widgetId := 1000, rowId := "project:default", kind := "project", title := "Misc" }] }
#guard (miscFixture.visibleProjectRows.map (·.rowId)) == ["project:default"]
#guard (({ miscFixture with expandedProjects := ["default"] } : DesktopState).visibleProjectRows.map (·.depth)) == [0, 1]

private def hoverRegions : List (WidgetId × Rect) :=
  [(1001, { x := 0, y := 64, w := 640, h := 192 }), (1000, { x := 0, y := 256, w := 640, h := 192 })]

#guard hierarchyFixture.sidebarHoverRow (some (projectNewAgentId 1000)) == some 1000
#guard hierarchyFixture.sidebarHoverDamage hoverRegions 120 (some 1001) (some (missionDisclosureId 1001)) == none
#guard hierarchyFixture.sidebarHoverDamage hoverRegions 120 none (some 1000) ==
  some (roundRectOut 120 hoverRegions[1]!.2)
#guard hierarchyFixture.sidebarHoverDamage hoverRegions 192 (some 1001) none ==
  some (roundRectOut 192 hoverRegions[0]!.2)

private def controllerFixture : DesktopState :=
  let child := { (default : MissionSummaryCard) with widgetId := 1004, missionId := "child", project := "now", callbackParentMissionId := "m" }
  { hierarchyFixture with
    expandedProjects := ["now"]
    missionCards := child :: hierarchyFixture.missionCards
    sidebarRows := { widgetId := child.widgetId, rowId := "mission:child", kind := "mission", title := "Worker" } :: hierarchyFixture.sidebarRows }

#guard (controllerFixture.visibleProjectRows.map (fun r => (r.rowId, r.badge))) ==
  [("project:now", 0), ("mission:m", 1)]
#guard (({ controllerFixture with expandedMissions := ["mission:m"] } : DesktopState).visibleProjectRows.map
  (fun r => (r.rowId, r.depth))) == [("project:now", 0), ("mission:m", 1), ("mission:child", 2)]

-- The controller's move can reach the client before its child's metadata.
private def movedControllerFixture : DesktopState :=
  { controllerFixture with missionCards := controllerFixture.missionCards.map fun card =>
      if card.missionId == "child" then { card with project := "old-project" } else card }

#guard movedControllerFixture.visibleProjectRows == controllerFixture.visibleProjectRows
#guard (({ movedControllerFixture with expandedMissions := ["mission:m"] } : DesktopState).visibleProjectRows.map
  (fun row => (row.rowId, row.depth))) == [("project:now", 0), ("mission:m", 1), ("mission:child", 2)]

private def cyclicControllerFixture : DesktopState :=
  { controllerFixture with missionCards := controllerFixture.missionCards.map fun card =>
      if card.missionId == "m" then { card with parentMissionId := "child" } else card }

#guard (cyclicControllerFixture.visibleProjectRows.map (fun row => (row.rowId, row.depth, row.badge))) ==
  [("project:now", 0, 0), ("mission:child", 1, 0), ("mission:m", 1, 0)]

-- A mission snapshot can arrive before its project. Keep its controller
-- disclosure functional until the folder becomes available.
private def missingProjectFixture : DesktopState :=
  { controllerFixture with sidebarRows := controllerFixture.sidebarRows.filter (·.kind != "project") }

#guard (missingProjectFixture.visibleProjectRows.map (fun r => (r.rowId, r.depth, r.badge))) ==
  [("mission:m", 0, 1)]
#guard (({ missingProjectFixture with expandedMissions := ["mission:m"] } : DesktopState).visibleProjectRows.map
  (fun r => (r.rowId, r.depth))) == [("mission:m", 0), ("mission:child", 1)]

private def nestedControllerFixture : DesktopState :=
  let grandchild := { (default : MissionSummaryCard) with
    widgetId := 1007, missionId := "grandchild", project := "now", parentMissionId := "child" }
  { controllerFixture with
    missionCards := grandchild :: controllerFixture.missionCards
    sidebarRows := { widgetId := grandchild.widgetId, rowId := "mission:grandchild", kind := "mission", title := "Worker child" } :: controllerFixture.sidebarRows }

#guard (nestedControllerFixture.visibleProjectRows.map (fun r => (r.rowId, r.badge))) ==
  [("project:now", 0), ("mission:m", 2)]
#guard (({ nestedControllerFixture with expandedMissions := ["mission:m"] } : DesktopState).visibleProjectRows.map
  (fun r => (r.rowId, r.badge))) == [("project:now", 0), ("mission:m", 2), ("mission:child", 1)]

-- Tagged workers retain their execution status. A tagged parent supplies context only
-- while a visible worker needs it, regardless of whether the controller is expanded.
private def archiveFixture (ids : List String) :=
  let cards := nestedControllerFixture.missionCards.map fun c => { c with archiveTag := ids.contains c.missionId }
  { nestedControllerFixture with expandedMissions := ["mission:m", "mission:child"], missionCards := cards }

#guard ((archiveFixture ["child"]).visibleProjectRows.map fun r => (r.rowId, r.badge, r.archiveOnly)) ==
  [("project:now", 0, false), ("mission:m", 2, false), ("mission:child", 1, false), ("mission:grandchild", 0, false)]
#guard (((archiveFixture ["child", "grandchild"]).visibleProjectRows.filter (!·.archiveOnly)).map fun r => (r.rowId, r.badge)) ==
  [("project:now", 0), ("mission:m", 0)]
#guard ((archiveFixture ["child", "grandchild"]).visibleProjectRows.filter (·.archiveOnly)).length == 2

private def unsentDraft : DesktopState :=
  { hierarchyFixture with composer := { text := "Keep this draft" }, draftProject := "other" }

#guard (stepDesktopEvent 120 vp { unsentDraft with screen := .controlEmpty } (.composerReturn false)).1.writeRequest == some .create
#guard (stepDesktopEvent 120 vp unsentDraft (.composerReturn true)).1.composer.text == "\nKeep this draft"
#guard (stepDesktopEvent 120 vp { unsentDraft with composer := { unsentDraft.composer with imePreeditText := "か" } }
  (.composerReturn false)).1.writeRequest.isNone
#guard (stepDesktopEvent 120 vp { unsentDraft with composer := { unsentDraft.composer with isRunning := true } }
  (.composerReturn false)).1.writeRequest.isNone

private def projectDraft : DesktopState := { unsentDraft with screen := .controlEmpty, draftProject := "now" }
private def pickedProject : DesktopState :=
  let menu : MissionMenu := { mission := "", x := 0, y := 0, page := .draftProject }
  let state := { unsentDraft with screen := .controlEmpty, missionMenu := some menu }
  (stepDesktopEvent 120 vp state (.activate 2000000)).1
#guard pickedProject.draftProject == "now" && pickedProject.composer.text == unsentDraft.composer.text
#guard pickedProject.missionMenu.isNone && pickedProject.writeRequest.isNone

private def inferencePage := (stepDesktopEvent 120 vp projectDraft (.activate 113)).1
private def machinesPage := (stepDesktopEvent 120 vp inferencePage (.activate 112)).1
private def returnedDraft := (stepDesktopEvent 120 vp machinesPage (.activate 101)).1

#guard inferencePage.headerTitle == "Inference"
#guard machinesPage.headerTitle == "Machines"
#guard returnedDraft.headerTitle == "Now" && returnedDraft.composer.text == projectDraft.composer.text
#guard (stepDesktopEvent 120 vp inferencePage (.composerReturn true)).1.composer.text == projectDraft.composer.text
#guard (stepDesktopEvent 120 vp machinesPage (.composerReturn false)).1.writeRequest.isNone
#guard (stepDesktopEvent 120 vp { projectDraft with openMission := some "m", screen := .missionTranscript }
  (.activate 113)).1.composer.text.isEmpty

private def providerList : DesktopState :=
  { inferencePage with fleetTopSub := 4800, providers := some [
    { (default : ProviderAccount) with id := "first" },
    { (default : ProviderAccount) with id := "second", providerType := "antigravity" }] }

private def providerDetail := (stepDesktopEvent 120 vp providerList (.activate (providerSettingsId 1))).1
private def providerEsc := (stepDesktopEvent 120 vp providerDetail (.key 0xff1b 0 .pressed)).1
#guard providerDetail.accountRoutePage.any (·.account.id == "second")
#guard providerDetail.writeRequest.isNone && providerDetail.fleetTopSub == 0
#guard desktopFocusChange providerList providerDetail (.activate (providerSettingsId 1)) == some providersBackId
#guard providerEsc.fleetTopSub == providerList.fleetTopSub && providerEsc.accountRoutePage.isNone
#guard desktopFocusChange providerDetail providerEsc (.key 0xff1b 0 .pressed) == some (providerSettingsId 1)

private def blankDraft : DesktopState := { hierarchyFixture with screen := .controlEmpty }
#guard desktopFocusChange blankDraft blankDraft (.key 0x6e 2 .pressed) == some 1
#guard desktopFocusChange blankDraft blankDraft (.key 0x6e 0 .pressed) == none

private def collapsed := (stepDesktopEvent 120 vp unsentDraft (.activate sidebarToggleId)).1
#guard collapsed.sidebarWidth == 0 && collapsed.composer.text == unsentDraft.composer.text
#guard (stepDesktopEvent 120 vp collapsed (.key 0x62 2 .pressed)).1.sidebarWidth == chromeSidebarWidthSub
#guard (stepDesktopEvent 120 vp collapsed (.key 0x62 3 .pressed)).1.sidebarHidden

private def openedProject := (stepDesktopEvent 120 vp unsentDraft (.activate 1000)).1
#guard openedProject.composer.text == unsentDraft.composer.text && openedProject.draftProject == "other"
#guard openedProject.expandedProjects == ["now"]
#guard (stepDesktopEvent 120 vp openedProject (.activate (projectNewAgentId 1000))).1.draftProject == "now"

#guard (stepDesktopEvent 120 vp hierarchyFixture (.activate 112)).1.screen == .machinesFleet
#guard (stepDesktopEvent 120 vp hierarchyFixture (.key 0x33 2 .pressed)).1.screen == .machinesFleet
#guard (stepDesktopEvent 120 vp hierarchyFixture (.key 0x33 8 .pressed)).1.screen == .machinesFleet
#guard (stepDesktopEvent 120 vp hierarchyFixture (.key 0x33 0 .pressed)).1.screen != .machinesFleet

-- The wire driver renders without font files, so every synthesized run stores its
-- Unicode codepoint in `glyphId`; decoding the laid-out boxes recovers the text.
private def decodeBoxLines (box : ComputedBox) : String :=
  box.lines.foldl (fun acc line =>
    line.glyphs.foldl (fun acc pg => acc ++ String.singleton (Char.ofNat pg.glyph.glyphId)) acc) ""

-- Traversals are depth-bounded `partial` so they elaborate identically in any
-- environment (no termination proof for the harness to fail on).
private partial def renderedBoxText : ComputedBox → Nat → String
  | _box, 0 => ""
  | box, depth + 1 =>
    box.children.foldl (fun acc child => acc ++ renderedBoxText child depth) (decodeBoxLines box)

private def renderedBoxRoot (box : ComputedBox) : String := renderedBoxText box 24

/-- Observed text boxes: decoded text plus its absolute sub-pixel and device rects. -/
private partial def collectObserved : ComputedBox → Nat → List (String × Rect × Rect)
  | _box, 0 => []
  | box, depth + 1 =>
    let self := if box.lines.isEmpty then [] else [(decodeBoxLines box, box.rectSub, box.rectDev)]
    box.children.foldl (fun acc child => acc ++ collectObserved child depth) self

/-- Use the live screen with a populated header run, as in a shaped window.
Obtain the target from the lowered scene, never by injecting an activate event. -/
private def clickMission (st : DesktopState) (card : MissionSummaryCard) : IO DesktopState := do
  let w := pxToSub 800
  let h := pxToSub 600
  let runs := [Widgets.overlaySynthRun (Theme.bodyText st.theme) st.headerTitle]
  let tree := buildDesktopScreen st w h { headerTitleRuns := runs } true
  let focus := st.initialFocusState
  let (_, scene) := renderWidgetTree 120 w h focus st.theme tree
  let some (_, rect) := scene.hitRegionsSub.find? (·.1 == card.widgetId)
    | throw (IO.userError "rendered live mission row has no hit region")
  let x := rect.x + rect.w / 2
  let y := rect.y + rect.h / 2
  unless x >= 0 && x < (chromeSidebarWidthSub : Int) && y >= 0 && y < (h : Int) do
    throw (IO.userError "mission row is not visible in the sidebar")
  let rt : Runtime.RuntimeState DesktopState := { app := st, focus, hitRegions := scene.hitRegionsSub }
  let reduce := stepDesktopEvent 120 vp
  let secondary := (rt.stepEvent reduce (.pointerButton x y 0x111 true)).stepEvent reduce (.pointerButton x y 0x111 false)
  unless secondary.app.openMission == st.openMission && secondary.pressedEntity.isNone do
    throw (IO.userError "secondary click unexpectedly opened the clicked mission")
  let down := rt.stepEvent reduce (.pointerButton x y 0x110 true)
  unless down.pressedEntity == some card.widgetId && down.app.openMission == st.openMission do
    throw (IO.userError "pointer press missed or selected before release")
  let up := down.stepEvent reduce (.pointerButton x y 0x110 false)
  unless up.app.screen == .missionTranscript && up.app.openMission == some card.missionId &&
      up.damage.isSome && up.app.sidebarRows.any (fun r => r.widgetId == card.widgetId && r.selected) do
    throw (IO.userError "pointer release did not select rendered mission")
  return up.app

private def awaitState (slot : IO.Ref (Option LiveSubscription)) (st : DesktopState)
    (accept : DesktopState → Bool) : IO DesktopState := do
  let mut current := st
  for _ in [0:800] do
    let (next, damage) ← readLiveFrame slot 120 vp current
    if accept next then
      unless damage.isSome do throw (IO.userError "missing damage")
      return next
    current := next
    IO.sleep 10
  throw (IO.userError "poll timed out")

/-- Lower `.vectorIcon` payloads the way Main.lean's shaping pass does, so driver scenes
carry the icon-mask prims (the diamond outline) without the glyph atlas. The mask source
rect mirrors the rasterized icon; driver assertions only inspect the destination. -/
private partial def lowerVectorIcons : WidgetNode → WidgetNode
  | .mk id focusable hit style payload children =>
    let payload := match payload with
      | .vectorIcon _paths color badgeBg _stroke =>
        let size := if badgeBg.isSome then pxToSub 10 else max (pxToSub 16) style.minWidth
        .iconMask 0 { x := 0, y := 0, w := size, h := size } color badgeBg
      | p => p
    .mk id focusable hit style payload (children.map lowerVectorIcons)

/-- Render the live transcript the way Main.lean's window does, with the current
stream text synthesized for the no-font driver. -/
private def renderScreen (st : DesktopState) (streamText : String) : ComputedBox × SceneOutput :=
  let stream := Widgets.synthInlineRun (Theme.bodyText st.theme) streamText
  renderWidgetTree 120 (pxToSub 800) (pxToSub 600) st.initialFocusState st.theme
    (lowerVectorIcons (buildDesktopScreen st (pxToSub 800) (pxToSub 600) { streamRuns := [stream] } true))

/-- Pure shape check for a decision node: its label center (device rect) is covered by an
icon-mask prim (the rhombus stroke rendered through the vector-icon pipeline) that covers
no other observed node's center, the label sits centered in the contour, and the label's
extent fits inside the rhombus half-width at the label's rows. -/
private def diamondObserved (scene : SceneOutput)
    (observed : List (String × Rect × Rect)) (self : String) (others : List String) : Bool :=
  match observed.filter (fun p => p.1 == self) with
  | [(_, _, fix)] =>
    let centers := (others.filterMap fun t =>
      (observed.filter (fun p => p.1 == t)).head?.map (fun p =>
        (p.2.2.x + p.2.2.w / 2, p.2.2.y + p.2.2.h / 2)))
    let fx := fix.x + fix.w / 2
    let fy := fix.y + fix.h / 2
    scene.prims.toList.any fun p => match p with
      | .mask _ _ dst _ =>
        let covers (cx cy : Int) :=
          dst.x ≤ cx && cx ≤ dst.x + dst.w && dst.y ≤ cy && cy ≤ dst.y + dst.h
        covers fx fy && !(centers.any fun (cx, cy) => covers cx cy) &&
        -- The visible label is centered in the contour and fits inside the rhombus
        -- half-width at the label's rows (the outline insets the tips by 6 of 160
        -- view units, so the contour half-width shrinks linearly from the middle).
        let cx := dst.x + dst.w / 2
        let cy := dst.y + dst.h / 2
        let lcx := fix.x + fix.w / 2
        let lcy := fix.y + fix.h / 2
        let tipInset := dst.w * 6 / 160
        let dy := if lcy ≥ cy then lcy - cy else cy - lcy
        let halfRow := (dst.w / 2 - tipInset) * (dst.h / 2 - dy) / max 1 (dst.h / 2)
        (lcx - cx).natAbs ≤ 8 && dy < dst.h / 2 && fix.w / 2 ≤ halfRow
      | _ => false
  | _ => false

/-- Semantic diagram assertions shared by the live-turn and cold-open cases: node and
edge labels are observed exactly once, edges are directed (each label sits strictly
between its source and target columns), the requested node shapes are observable, the
nodes are separately hit-testable, and no fence source leaks into the render. -/
private def assertDiagram (scene : SceneOutput) (observed : List (String × Rect × Rect))
    (rendered : String) : IO Unit := do
  let exactlyOne (t what : String) : IO Rect := do
    match observed.filter (fun p => p.1 == t) with
    | [(_, sub, _)] => pure sub
    | hits =>
      let labels := observed.map (·.1) |> String.intercalate ","
      throw (IO.userError ("rendered diagram " ++ what ++ " was not observed exactly once: " ++ t ++
        s!" (hits: {hits.length}; labels: {labels})"))
  let spec ← exactlyOne "Spec" "node label"
  let build ← exactlyOne "Build" "node label"
  let fix ← exactlyOne "Fix" "node label"
  let approve ← exactlyOne "Approve" "edge label"
  let revise ← exactlyOne "Revise" "edge label"
  unless spec.x < approve.x && approve.x < build.x do
    throw (IO.userError "Approve edge is not directed Spec -> Build")
  unless build.x < revise.x && revise.x < fix.x do
    throw (IO.userError "Revise edge is not directed Build -> Fix")
  -- Each orthogonal connector ends in a small accent chevron (a real directional
  -- tip rasterized as an ~8 device-px icon mask, distinct from the flat 2 device-px
  -- shaft), one per directed edge. Scene prim rects are device pixels (the driver
  -- renders at scale 120).
  let arrowheads := scene.prims.toList.filter fun p => match p with
    | .mask _ _ dst _ => dst.w ≤ 8 && dst.h ≤ 8
    | _ => false
  unless arrowheads.length ≥ 2 do
    let small := scene.prims.toList.filterMap fun p => match p with
      | .mask _ _ dst _ =>
        if dst.w ≤ 12 && dst.h ≤ 12 then some s!"({dst.x},{dst.y},{dst.w},{dst.h})" else none
      | _ => none
    throw (IO.userError ("rendered diagram edges have no arrowheads; small masks: " ++
      String.intercalate " | " small))
  let devRectOf (t : String) : Option Rect :=
    (observed.filter (fun p => p.1 == t)).head?.map (fun p => p.2.2)
  let observedRadius (t : String) : IO Nat := do
    let some dev := devRectOf t | throw (IO.userError ("missing device rect for " ++ t))
    let cx := dev.x + dev.w / 2
    let cy := dev.y + dev.h / 2
    let nearest := scene.prims.toList.foldl (fun best p => match p with
      | .rrect r _ (tl, _, _, _) _ _ =>
        if r.x ≤ cx && cx ≤ r.x + r.w && r.y ≤ cy && cy ≤ r.y + r.h then
          let area := r.w * r.h
          match best with
          | some (ba, _) => if area < ba then some (area, tl) else best
          | none => some (area, tl)
        else best
      | _ => best) none
    match nearest with
    | some (_, radius) => pure radius
    | none => throw (IO.userError ("no scene rect observed around " ++ t))
  let specR ← observedRadius "Spec"
  let buildR ← observedRadius "Build"
  unless buildR > specR do
    throw (IO.userError "rendered node shapes did not observe pill > rounded")
  unless diamondObserved scene observed "Fix" ["Spec", "Build"] do
    throw (IO.userError "decision node is not rendered as a diamond outline")
  let covering (sub : Rect) : List Rect :=
    (scene.hitRegionsSub.filter fun r =>
      let cx := sub.x + sub.w / 2
      let cy := sub.y + sub.h / 2
      r.2.x ≤ cx && cx ≤ r.2.x + r.2.w && r.2.y ≤ cy && cy ≤ r.2.y + r.2.h).map (·.2)
  let coversCenter (r : Rect) (other : Rect) : Bool :=
    let ox := other.x + other.w / 2
    let oy := other.y + other.h / 2
    r.x ≤ ox && ox ≤ r.x + r.w && r.y ≤ oy && oy ≤ r.y + r.h
  let hasOwnRegion (self a b : Rect) : Bool :=
    (covering self).any (fun r => !coversCenter r a && !coversCenter r b)
  unless hasOwnRegion spec build fix && hasOwnRegion build spec fix &&
      hasOwnRegion fix spec build do
    throw (IO.userError "rendered diagram nodes are not separately hit-testable")
  unless !rendered.contains "```" && !rendered.contains "mermaid" do
    throw (IO.userError "Mermaid source was rendered as literal text")

/-- Render persisted turns as a cold transcript would show them. -/
private def renderedTurns (turns : List String) :
    List (String × Rect × Rect) × SceneOutput × String :=
  let st := { coldFixture with liveTurns := turns }
  let (rootBox, scene) := renderScreen st ""
  (collectObserved rootBox 24, scene, renderedBoxRoot rootBox)

private def observedOnce (observed : List (String × Rect × Rect)) (t : String) : Option Rect :=
  match observed.filter (fun p => p.1 == t) with
  | [(_, sub, _)] => some sub
  | _ => none

-- Chained statements link each target to its preceding node, so A --> B --> C
-- renders two forward steps instead of a shortcut from A to C.
private def chainTurn : String := "```mermaid\ngraph LR\n  A --> B --> C\n```"
private def chainObserved := (renderedTurns [chainTurn]).1
#guard [observedOnce chainObserved "A", observedOnce chainObserved "B",
  observedOnce chainObserved "C"].all (·.isSome)
#guard match (observedOnce chainObserved "A", observedOnce chainObserved "B",
    observedOnce chainObserved "C") with
  | (some a, some b, some c) => a.x < b.x && b.x < c.x
  | _ => false
#guard !((renderedTurns [chainTurn]).2.2.contains "```")

-- A cycle must not inflate ranks on every pass: the layout stays stable with
-- coordinates bounded by the rendered transcript instead of walking off screen.
private def cycleTurn : String := "```mermaid\ngraph LR\n  P --> Q --> P\n```"
private def cycleObserved := (renderedTurns [cycleTurn]).1
#guard [observedOnce cycleObserved "P", observedOnce cycleObserved "Q"].all (·.isSome)
#guard match (observedOnce cycleObserved "P", observedOnce cycleObserved "Q") with
  | (some p, some q) => p.x < q.x && q.x + q.w <= pxToSub 800 && q.y + q.h <= pxToSub 600
  | _ => false

-- Physical parity for the m2air evidence flow: a four-node graph with two labeled
-- edges and a decision node keeps every node and both edge labels visible in source
-- order, and the decision node renders as a rhombus (icon mask), not a rect fill.
private def flowTurn : String :=
  "```mermaid\ngraph LR\n  A[Spec] -->|Approve| B(Build)\n  B -->|Revise| C{Review}\n  C --> D[Done]\n```"
private def flowObserved := (renderedTurns [flowTurn]).1
#guard [observedOnce flowObserved "Spec", observedOnce flowObserved "Build",
  observedOnce flowObserved "Review", observedOnce flowObserved "Done",
  observedOnce flowObserved "Approve", observedOnce flowObserved "Revise"].all (·.isSome)
#guard match (observedOnce flowObserved "Spec", observedOnce flowObserved "Build",
    observedOnce flowObserved "Review", observedOnce flowObserved "Done",
    observedOnce flowObserved "Approve", observedOnce flowObserved "Revise") with
  | (some a, some b, some c, some d, some ap, some rv) =>
    a.x < b.x && b.x < c.x && c.x < d.x &&
    a.x < ap.x && ap.x < b.x && b.x < rv.x && rv.x < c.x
  | _ => false
#guard diamondObserved (renderedTurns [flowTurn]).2.1 flowObserved "Review" ["Spec", "Build", "Done"]
#guard !((renderedTurns [flowTurn]).2.2.contains "```")

-- The decision outline rasterizes as a closed rhombus on the node's actual rectangle:
-- scanning the rasterized contour row by row, the width is near zero at the upper tip,
-- widens to the middle, then narrows symmetrically to a lower tip that still carries
-- paint inside the clip bounds (both lower sides present). Rows are sampled in the
-- raster of a 136x40 node (nodeW pixels; the rhombus band is exactly nodeH pixels tall).
private def diamondRowSpan (g : LeanUI.Text.RasterizedGlyph) (y : Nat) : Nat := Id.run do
  let mut lo := g.width
  let mut hi := 0
  for x in [0:g.width] do
    if g.pixels.get! (y * g.width + x) > 0 then
      if x < lo then lo := x
      if x + 1 > hi then hi := x + 1
  if hi ≤ lo then 0 else hi - lo

private def diamondSpans : List Nat :=
  -- Rasterized with the pure reference rasterizer at the node width so the scan
  -- needs no atlas FFI (the segment fast path has no interpreter symbol in the
  -- harness) and stays cheap to elaborate; the contour shape is scale-invariant
  -- in the 160-unit view box, so the band maps to band/160 * size pixels.
  let g := LeanUI.Text.rasterizeIconReference (LeanUI.Widgets.mermaidDiamondOutline (pxToSub 136) (pxToSub 40)) 136
  [2, 10, 19, 29, 37].map (diamondRowSpan g)
#guard match diamondSpans with
  | [top, inner, mid, innerBot, bot] =>
    top > 0 && bot > 0 && top ≤ inner && inner ≤ mid && mid ≥ innerBot && innerBot ≥ bot &&
    mid > top && mid > bot && (top + 8 ≥ bot) && (bot + 8 ≥ top) &&
    (inner + 8 ≥ innerBot) && (innerBot + 8 ≥ inner)
  | _ => false

def main (args : List String) : IO Unit := do
  for dark in [true, false] do
    for width in [480, 1000] do
      let cold := { DesktopState.liveUnavailable dark with initialRosterPending := true }
      let page := (stepDesktopEvent 120 vp cold (.key 0x2c 2 .pressed)).1
      let w := pxToSub width
      let h := pxToSub 480
      let (_, scene) := renderWidgetTree 120 w h page.initialFocusState page.theme (buildDesktopScreen page w h)
      unless page.screen == .settingsGeneral && [103, accountFormId].all scene.focusableOrder.contains do
        throw (IO.userError "cold Settings footer or sign-in action missing")
      for id in [103, accountFormId] do
        let some (_, r) := scene.hitRegionsSub.find? (·.1 == id) | throw (IO.userError "missing target")
        unless r.w > 0 && r.h > 0 && r.x >= 0 && r.right <= w && r.y >= 0 && r.bottom <= h do
          throw (IO.userError "account target clipped")
      let rt : Runtime.RuntimeState DesktopState := {
        app := page, focus := page.initialFocusState.request accountFormId
        focusableOrder := scene.focusableOrder }
      unless (rt.stepEvent (stepDesktopEvent 120 vp) (.key 0xff0d 0 .pressed)).app.openAccountForm do
        throw (IO.userError "keyboard sign-in unavailable")
      let page := (stepDesktopEvent 120 vp page (.text "ignored")).1
      unless page.composer.text.isEmpty && page.writeRequest.isNone do throw (IO.userError "editable native account view")
  let enter : Wayland.WlWireEvent := {
    tag := Wayland.tagPointer, proxy := 0, opcode := 0,
    args := #[.uint 417, .obj 0, .fixed 256, .fixed 512] }
  let (entered, _) ← Wayland.stepWireEvent { appliedCursor := some 4 } enter
  unless entered.enterSerial == some 417 && entered.appliedCursor.isNone do
    throw (IO.userError "pointer entry must use its own serial even when returning to the same row")
  let (left, _) ← Wayland.stepWireEvent entered { enter with opcode := 1, args := #[] }
  unless left.enterSerial.isNone do throw (IO.userError "cursor retained a serial after surface leave")
  let boot ← withLiveSources true (pure ()) fun readSources => do
    let pending := { DesktopState.liveUnavailable with initialRosterPending := true }
    unless pending.headerTitle == "Connecting to Core…" do throw (IO.userError "missing initial loading state")
    for _ in [:1000] do
      if let some next ← readSources pending then
        if next.initialRosterPending then throw (IO.userError "initial read failed to settle")
        if args == ["reconnect"] && next.headerTitle != "Sign in to Core" then
          throw (IO.userError "rejected session reported as an outage")
        if args == ["denied"] && next.headerTitle != "Access denied" then
          throw (IO.userError "account denial reported as an outage")
        if args == ["unavailable"] && next.headerTitle != "Core unavailable" then
          throw (IO.userError "invalid Core response reported as an authentication failure")
        return if next.hasLiveConnection then some next else none
      IO.sleep 20
    throw (IO.userError "initial roster did not finish")
  if args == ["reconnect"] then
    unless boot.isNone do throw (IO.userError "expired fixture token was accepted")
    let root := System.FilePath.mk ((← IO.getEnv "ORB_STATE_DIR").getD "")
    withLiveSources true (pure ()) fun readSources => do
      let mut state := DesktopState.liveUnavailable
      discard <| readSources state
      IO.FS.rename (root / "rotated") (root / "connection.json")
      for _ in [:300] do
        if let some next ← readSources state then state := next
        if state.hasLiveConnection && !state.catalogLoading then
          unless state.missionCards.length == 2 && state.accountUsername == "Alice" && !state.accountEndpoint.isEmpty do throw (IO.userError "incomplete recovered roster")
          return
        IO.sleep 20
      throw (IO.userError "window failed to recover the new session and reload its catalog")
    return
  if args == ["unavailable"] || args == ["denied"] then
    unless boot.isNone do throw (IO.userError "failed bootstrap appeared successful")
    return
  let some st := boot | throw (IO.userError "bootstrap failed")
  if args == ["settings-switch"] then
    withLiveSources true (pure ()) fun readSources => do
      let mut page := (stepDesktopEvent 120 vp st (.activate 103)).1
      unless page.accountUsername == "Ben" && page.screen == .settingsGeneral do throw (IO.userError "wrong initial account")
      discard <| readSources page
      let dir := System.FilePath.mk ((← IO.getEnv "ORB_STATE_DIR").getD "")
      IO.FS.rename (dir / "rotated") (dir / "connection.json")
      let mut sawReset := false
      for _ in [:600] do
        if let some next ← readSources page then page := next
        unless page.screen == .settingsGeneral do throw (IO.userError "account switch navigated away")
        if !page.hasLiveConnection then
          unless page.accountUsername.isEmpty && page.missionCards.isEmpty && page.sidebarRows == [settingsFooter] do
            throw (IO.userError "stale account data survived rotation")
          sawReset := true
        if page.accountUsername == "Alice" && sawReset && page.hasLiveConnection then return
        IO.sleep 20
      throw (IO.userError "new account did not recover")
    return
  if let ["inbox", action] := args then
    unless !st.inboxAvailable && st.missionCards.isEmpty do throw (IO.userError "bootstrap waited for Inbox history")
    let slot ← IO.mkRef none
    try
      let st ← awaitState slot st (·.inboxAvailable)
      let page := (stepDesktopEvent 120 vp st (.key 0x69 2 .pressed)).1
      let tree := buildDesktopScreen page (pxToSub 800) (pxToSub 600)
      let (_, scene) := renderWidgetTree 120 (pxToSub 800) (pxToSub 600) page.initialFocusState page.theme tree
      unless page.screen == .inbox && page.inboxAvailable &&
          page.visibleProjectRows.any (fun r => r.rowId == "nav:inbox" && r.badge == 1) &&
          [940, 941].all scene.focusableOrder.contains do throw (IO.userError "missing unread item or controls")
      if action == "partial" then
        let next ← awaitState slot st fun s => s.missionCards.any (·.missionId == "next-roster")
        unless next.inboxAvailable && next.inboxItems == st.inboxItems &&
            next.visibleProjectRows.any (fun r => r.rowId == "nav:inbox" && r.badge == 1) do
          throw (IO.userError "partial Core response replaced the last complete Inbox")
        return
      let rt : Runtime.RuntimeState DesktopState := {
        app := page, focus := page.initialFocusState.request 940
        focusableOrder := scene.focusableOrder }
      let reduce := stepDesktopEvent 120 vp
      let rt := if action == "read" then rt.stepEvent reduce (.key 0xff09 0 .pressed) else rt
      let rt := rt.stepEvent reduce (.key 0xff0d 0 .pressed)
      let (next, _) ← readLiveFrame slot 120 vp rt.app
      unless next.visibleProjectRows.any (fun r => r.rowId == "nav:inbox" && r.badge == 0) && next.writeError.isEmpty &&
          next.openMission == (if action == "open" then some "shared" else none) do
        throw (IO.userError "keyboard activation did not acknowledge the item")
      return
    finally
      closeLiveSubscription slot
  let [a,b] := st.missionCards | throw (IO.userError "bad roster")
  unless st.sidebarRows.any (fun r => r.title == "Project title" && r.subtitle == "Objective" && r.iconColor == some 0x8aaed4ff) do
    throw (IO.userError "wrong project fields")
  unless st.expandedProjects == ["p"] do throw (IO.userError "single project was collapsed at launch")
  let slot ← IO.mkRef (none : Option LiveSubscription)
  try
    if args == ["cold-open"] then
      -- Cold open of a previously completed mission in the real Core persistence
      -- shape: user prompts and plain assistant_message turns, with the final turn
      -- also present as its canonical replacement. The client must repopulate the
      -- earlier turns from the persisted timeline (in-memory liveTurns alone cannot
      -- reconstruct them), cover delivered user prompts, keep one copy of the
      -- canonical replacement, yield the newest turn to the live bubble, and then
      -- let a third turn stream live.
      let some source ← IO.getEnv "ORB_TEST_MERMAID" | throw (IO.userError "missing ORB_TEST_MERMAID")
      let st ← clickMission st a
      -- The earlier turns can only come from the persisted timeline: the live bubble
      -- shows the newest turn, which the transport yields to the stream.
      let st ← awaitState slot st
        (fun s => s.liveTurns == ["You: PRIVATE", "Amber blossom", "You: PRIVATE"] && streamedText s == source)
      let (rootBox, scene) := renderScreen st source
      let rendered := renderedBoxRoot rootBox
      let observed := collectObserved rootBox 24
      unless rendered.contains "Amber blossom" && (rendered.splitOn "You: PRIVATE").length == 3 do
        throw (IO.userError "cold open did not repopulate the persisted turns and user prompts")
      assertDiagram scene observed rendered
      -- Let the fixture stage the next turn only after the cold-open render passed.
      let root := (← IO.getEnv "ORB_STATE_DIR").getD ""
      IO.FS.writeFile (System.FilePath.mk root / "cold-open-observed") "1"
      let st ← awaitState slot st (fun s => streamedText s == "Ripened fruit")
      let (rootBox, scene) := renderScreen st "Ripened fruit"
      let rendered := renderedBoxRoot rootBox
      let observed := collectObserved rootBox 24
      unless rendered.contains "Amber blossom" && (rendered.splitOn "You: PRIVATE").length == 3 &&
          rendered.contains "Ripened fruit" do
        throw (IO.userError "continuing live stream lost the persisted earlier turns")
      assertDiagram scene observed rendered
      return
    if args == ["mermaid-backedge"] then
      -- The controller-reported graph: all four edges render, including the
      -- Review -> Draft back edge, both edge labels are visible, and Review
      -- (two labelled outgoing edges) shows Approve and Revise on opposite
      -- sides. The back edge routes through a lane below the rank rows with its
      -- arrowhead at the Draft (target) end.
      let some backedge ← IO.getEnv "ORB_TEST_BACKEDGE" | throw (IO.userError "missing ORB_TEST_BACKEDGE")
      let st ← clickMission st a
      let st ← awaitState slot st (fun s => streamedText s == backedge)
      let (rootBox, scene) := renderScreen st backedge
      let rendered := renderedBoxRoot rootBox
      let observed := collectObserved rootBox 24
      let exactlyOne (t what : String) : IO Rect := do
        match observed.filter (fun p => p.1 == t) with
        | [(_, sub, _)] => pure sub
        | hits =>
          let labels := observed.map (·.1) |> String.intercalate ","
          throw (IO.userError ("rendered diagram " ++ what ++ " was not observed exactly once: " ++ t ++
            s!" (hits: {hits.length}; labels: {labels})"))
      let draft ← exactlyOne "Design spec" "node label"
      let review ← exactlyOne "Code review" "node label"
      let deploy ← exactlyOne "Canary deploy" "node label"
      let _verify ← exactlyOne "Verify release" "node label"
      let approve ← exactlyOne "Approve" "edge label"
      let revise ← exactlyOne "Revise" "edge label"
      unless review.x < approve.x && approve.x < deploy.x do
        throw (IO.userError "Approve edge is not directed Review -> Deploy")
      unless draft.x < revise.x && revise.x < review.x do
        throw (IO.userError "Revise back edge label is not between Draft (target) and Review (source)")
      unless review.y < revise.y && deploy.y < revise.y do
        throw (IO.userError "Revise back edge is not routed below the rank rows")
      unless approve.x > review.x && revise.x < review.x do
        throw (IO.userError "Review does not show two labelled outgoing edges on opposite sides")
      let arrowheads := scene.prims.toList.filter fun p => match p with
        | .mask _ _ dst _ => dst.w ≤ 8 && dst.h ≤ 8
        | _ => false
      unless arrowheads.length ≥ 4 do
        throw (IO.userError s!"rendered diagram edges have {arrowheads.length} arrowheads, expected 4")
      let some (_, _, draftDev) := observed.filter (fun p => p.1 == "Design spec") |>.head? |
        throw (IO.userError "missing device rect for Design spec")
      let some (_, _, reviewDev) := observed.filter (fun p => p.1 == "Code review") |>.head? |
        throw (IO.userError "missing device rect for Code review")
      let some (_, _, verifyDev) := observed.filter (fun p => p.1 == "Verify release") |>.head? |
        throw (IO.userError "missing device rect for Verify release")
      let draftCx := draftDev.x + draftDev.w / 2
      let reviewCx := reviewDev.x + reviewDev.w / 2
      -- The lane tip: a chevron at the Draft (target) column, below the rank rows,
      -- with the lane's continuous path directly under it spanning both columns.
      let laneTips := arrowheads.filterMap fun p => match p with
        | .mask _ _ dst _ =>
          if (dst.x + dst.w / 2 - draftCx).natAbs ≤ 16 && dst.y > verifyDev.y then some dst else none
        | _ => none
      unless laneTips.length == 1 do
        throw (IO.userError s!"the back edge needs exactly one chevron at the Draft end below the rows, got {laneTips.length}")
      let some (laneTip) := laneTips.head? | throw (IO.userError "unreachable")
      let lanePaths := scene.prims.toList.filterMap fun p => match p with
        | .mask _ _ dst _ =>
          if dst.w ≥ 100 && dst.y > verifyDev.y &&
              dst.x ≤ reviewCx && reviewCx < dst.x + dst.w then some dst else none
        | _ => none
      unless lanePaths.length == 1 do
        throw (IO.userError s!"the back edge needs one continuous lane path spanning Review and Draft, got {lanePaths.length}")
      let some (lanePath) := lanePaths.head? | throw (IO.userError "unreachable")
      -- Physically connected: the chevron sits directly on the path's row (adjacent
      -- lane rows, no gap), and the path spans both column centers end to end.
      unless (lanePath.y - (laneTip.y + laneTip.h)).natAbs ≤ 1 do
        throw (IO.userError "the lane chevron is not attached to the lane path row")
      unless (lanePath.x - min reviewCx draftCx).natAbs ≤ 2 &&
          (lanePath.x + lanePath.w - max reviewCx draftCx).natAbs ≤ 2 do
        throw (IO.userError "the lane path does not span the Review and Draft columns exactly")
      unless rendered.contains "Design spec" && rendered.contains "Verify release" do
        throw (IO.userError "reported graph nodes missing from the render")
      return
    if args == ["mermaid-cycle"] then
      -- The review's exact contract for a two-node bidirectional cycle: both
      -- directions render as separate actual paths with clear labels and
      -- arrowheads at opposite targets.
      let some cycleSrc ← IO.getEnv "ORB_TEST_CYCLE" | throw (IO.userError "missing ORB_TEST_CYCLE")
      let st ← clickMission st a
      let st ← awaitState slot st (fun s => streamedText s == cycleSrc)
      let (rootBox, scene) := renderScreen st cycleSrc
      let rendered := renderedBoxRoot rootBox
      let observed := collectObserved rootBox 24
      let exactlyOne (t what : String) : IO Rect := do
        match observed.filter (fun p => p.1 == t) with
        | [(_, sub, _)] => pure sub
        | hits =>
          let labels := observed.map (·.1) |> String.intercalate ","
          throw (IO.userError ("rendered diagram " ++ what ++ " was not observed exactly once: " ++ t ++
            s!" (hits: {hits.length}; labels: {labels})"))
      let alpha ← exactlyOne "Alpha" "node label"
      let beta ← exactlyOne "Beta" "node label"
      let ship ← exactlyOne "Ship" "edge label"
      let ret ← exactlyOne "Return" "edge label"
      unless alpha.x < ship.x && ship.x < beta.x do
        throw (IO.userError "Ship edge is not directed Alpha -> Beta")
      unless alpha.x < ret.x && ret.x < beta.x do
        throw (IO.userError "Return label is not between the two columns")
      unless ret.y > alpha.y && ret.y > beta.y do
        throw (IO.userError "Return back edge is not routed below the rank rows")
      let some (_, _, alphaDev) := observed.filter (fun p => p.1 == "Alpha") |>.head? |
        throw (IO.userError "missing device rect for Alpha")
      let some (_, _, betaDev) := observed.filter (fun p => p.1 == "Beta") |>.head? |
        throw (IO.userError "missing device rect for Beta")
      let alphaCx := alphaDev.x + alphaDev.w / 2
      let betaCx := betaDev.x + betaDev.w / 2
      let alphaCy := alphaDev.y + alphaDev.h / 2
      let betaCy := betaDev.y + betaDev.h / 2
      let smallMasks := scene.prims.toList.filterMap fun p => match p with
        | .mask _ _ dst _ => if dst.w ≤ 8 && dst.h ≤ 8 then some dst else none
        | _ => none
      -- Arrowheads at opposite targets: the forward tip touches the Beta node's
      -- left edge at node height, the return tip is centered on the Alpha column
      -- below the rank rows.
      unless smallMasks.any fun dst =>
          (dst.x + dst.w - (betaDev.x - 12)).natAbs ≤ 16 &&
          (dst.y + dst.h / 2 - betaCy).natAbs ≤ 10 do
        throw (IO.userError "the forward edge has no arrowhead at the Beta (target) column at node height")
      unless smallMasks.any fun dst =>
          (dst.x + dst.w / 2 - alphaCx).natAbs ≤ 16 && dst.y > betaDev.y + betaDev.h do
        throw (IO.userError "the return edge has no arrowhead at the Alpha (target) column below the rows")
      -- Separate actual paths: the return lane is one wide continuous mask below the
      -- rows spanning both columns, while the forward shaft is a thin rect at node
      -- height between the columns.
      let lanePaths := scene.prims.toList.filterMap fun p => match p with
        | .mask _ _ dst _ => if dst.w ≥ 60 && dst.y > betaDev.y + betaDev.h then some dst else none
        | _ => none
      unless lanePaths.length == 1 do
        throw (IO.userError s!"the return edge needs one lane path below the rows, got {lanePaths.length}")
      let some (lanePath) := lanePaths.head? | throw (IO.userError "unreachable")
      unless (lanePath.x - min alphaCx betaCx).natAbs ≤ 2 &&
          (lanePath.x + lanePath.w - max alphaCx betaCx).natAbs ≤ 2 do
        throw (IO.userError "the lane path does not span the Alpha and Beta columns exactly")
      let shafts := scene.prims.toList.filter fun p => match p with
        | .rrect r _ _ _ _ =>
          r.h ≤ 3 && r.w ≥ 20 &&
            (r.y + r.h / 2 - alphaCy).natAbs ≤ 10 &&
            r.x ≥ alphaDev.x && r.x + r.w ≤ betaDev.x + betaDev.w
        | _ => false
      unless shafts.length ≥ 1 do
        throw (IO.userError "the forward edge has no shaft at node height between the columns")
      unless !rendered.contains "```" && !rendered.contains "mermaid" do
        throw (IO.userError "Mermaid source was rendered as literal text")
      return
    if args == ["cold-recover"] then
      -- Cold open with persisted turns, then a transient unavailable window,
      -- then the same text: the wipe must not cost the persisted archive for
      -- good, and the replayed current turn shows exactly one visible copy.
      let st ← clickMission st a
      let st ← awaitState slot st
        (fun s => s.liveTurns == ["You: PRIVATE", "Amber blossom", "You: PRIVATE"] &&
          streamedText s == "Cold ember glow")
      let st ← awaitState slot st (fun s => s.liveTurns.isEmpty && (streamedText s).isEmpty)
      let st ← awaitState slot st
        (fun s => s.liveTurns == ["You: PRIVATE", "Amber blossom", "You: PRIVATE"] &&
          streamedText s == "Cold ember glow")
      let (rootBox, _) := renderScreen st "Cold ember glow"
      let rendered := renderedBoxRoot rootBox
      unless rendered.contains "Amber blossom" && (rendered.splitOn "You: PRIVATE").length == 3 &&
          (rendered.splitOn "Cold ember glow").length == 2 do
        throw (IO.userError "unavailable window lost the persisted archive or duplicated the current turn")
      return
    if args == ["markdown-turn"] then
      -- Both stream shapes render markdown-lite: a one-line stream must not show
      -- its literal bold markers, and the completed multi-line document renders
      -- headings, bullets, links, inline styles and a non-mermaid code fence.
      let some md ← IO.getEnv "ORB_TEST_MARKDOWN" | throw (IO.userError "missing ORB_TEST_MARKDOWN")
      let st ← clickMission st a
      let st ← awaitState slot st (fun s => streamedText s == "Amber blossom")
      let st ← awaitState slot st (fun s => streamedText s == "**Ember glow**")
      let (rootBox, _) := renderScreen st "**Ember glow**"
      let rendered := renderedBoxRoot rootBox
      unless rendered.contains "Ember glow" && !rendered.contains "**" do
        throw (IO.userError ("single-line stream kept literal markdown markers: " ++ rendered.take 300))
      let st ← awaitState slot st (fun s => streamedText s == md)
      let (rootBox, _) := renderScreen st md
      let rendered := renderedBoxRoot rootBox
      unless rendered.contains "Release notes" && rendered.contains "• First bullet" &&
          rendered.contains "• Second bullet" &&
          rendered.contains "the guide (https://example.test/guide)" &&
          rendered.contains "a soft italic" && rendered.contains "inline code" &&
          rendered.contains "print(\"hi\")" do
        throw (IO.userError ("multi-line markdown lost a rendered span: " ++ rendered.take 600))
      let markerContext (m : String) : String :=
        match rendered.splitOn m with
        | before :: after :: _ =>
          let i := before.length
          "…" ++ before.drop (if i > 40 then i - 40 else 0) ++ "⟪" ++ m ++ "⟫" ++ after.take 40 ++ "…"
        | _ => ""
      for m in ["#", "**", "](", "```", "`", "- First"] do
        if rendered.contains m then
          throw (IO.userError ("multi-line markdown kept literal marker " ++ m ++ ": " ++
            markerContext m))
      return
    if args == ["mermaid-turn"] then
      -- Two-turn live case: the earlier assistant turn must survive the follow-up
      -- turn, whose canonical Mermaid fence renders as an actual diagram.
      let some source ← IO.getEnv "ORB_TEST_MERMAID" | throw (IO.userError "missing ORB_TEST_MERMAID")
      let st ← clickMission st a
      let st ← awaitState slot st (fun s => streamedText s == "Amber blossom")
      let st ← awaitState slot st (fun s => streamedText s == source)
      let (rootBox, scene) := renderScreen st source
      let rendered := renderedBoxRoot rootBox
      let observed := collectObserved rootBox 24
      unless rendered.contains "Amber blossom" do
        throw (IO.userError ("earlier assistant turn was dropped from the live transcript; liveTurns: " ++
          String.intercalate " | " st.liveTurns ++ "; rendered: " ++ rendered.take 400))
      assertDiagram scene observed rendered
      return
    if args == ["start-running"] then
      let st ← clickMission st b
      if st.composer.isRunning then throw (IO.userError "pending mission offered Stop")
      let st ← awaitState slot st (fun s => s.selectedCard.any (·.status == "active") && streamedText s == "second\n\tλ🙂\n")
      let (next, _) := stepDesktopEvent 120 vp st (.activate 2)
      unless next.writeRequest == some (.stop b.missionId) do
        throw (IO.userError "active roster and bubble left Send in place of Stop")
      return
    if args == ["project-first"] then
      let st := { st with inboxAvailable := true, inboxItems := [{ mission := a.missionId, card := a, stamp := 1000, version := 1 }] }
      let next ← awaitState slot st (fun s => s.projectMemberships == [("p", ["older"])])
      unless st.inboxAvailable && next.inboxAvailable && next.inboxItems == st.inboxItems &&
          next.missionCards.length == 3 && next.missionCards.any (fun m => m.missionId == "older" && m.archiveTag) &&
          next.missionCards.contains a && next.missionCards.contains b && next.fleetMachines == st.fleetMachines &&
          next.sidebarRows.any (·.rowId == "project:p") do
        throw (IO.userError "project sample displaced unrelated roster data")
      return
    if args == ["project-lag"] then
      let st ← clickMission st b
      let next ← awaitState slot st (fun s => streamedText s == "second\n\tλ🙂\n")
      unless next.projectMemberships.isEmpty do throw (IO.userError "bubble waited for project history")
      return
    if args == ["page-two"] || args == ["null-retry"] then
      let st ← clickMission st b
      let expected := if args == ["page-two"] then 201 else 2
      let st ← awaitState slot st (fun s => streamedText s == "second\n\tλ🙂\n" && s.missionCards.length == expected)
      unless st.openMission == some b.missionId && st.missionCards.length == expected &&
          st.selectedCard.any (·.widgetId == b.widgetId) do throw (IO.userError "page update displaced the selected mission")
      return
    if args == ["idle-page-two"] then
      let current ← awaitState slot st (fun s => s.missionCards.length == 201)
      unless current.hasLiveConnection && current.openMission.isNone &&
          current.missionCards.any (fun m => m.missionId == b.missionId && m.widgetId == b.widgetId) &&
          current.sidebarRows.any (·.rowId == "mission:new-198") do
        throw (IO.userError "live page lost new or displaced authorized row")
      return
    if args == ["idle-session"] then
      let next ← awaitState slot st (!·.hasLiveConnection)
      unless next.missionCards.isEmpty && next.sidebarRows == [settingsFooter] do throw (IO.userError "idle session retained data")
      return
    if args == ["idle-share"] then
      let next ← awaitState slot st (·.missionCards.length == 1)
      unless next.hasLiveConnection && next.missionCards.head?.any (·.missionId == a.missionId) &&
          !next.sidebarRows.any (·.widgetId == b.widgetId) do throw (IO.userError "idle share removal incorrect")
      return
    if args == ["idle-identity"] || args == ["before-open"] then
      unless st.accountUsername == "Ben" do throw (IO.userError "missing authenticated username")
      let st := (stepDesktopEvent 120 vp st (.activate 103)).1
      discard <| readLiveFrame slot 120 vp st
      let root := (← IO.getEnv "ORB_STATE_DIR").getD ""
      IO.FS.rename (System.FilePath.mk root / "rotated") (System.FilePath.mk root / "connection.json")
      let st := if args == ["before-open"] then (stepDesktopEvent 120 vp st (.activate a.widgetId)).1 else st
      let st ← awaitState slot st (!·.hasLiveConnection)
      unless st.missionCards.isEmpty && st.accountUsername.isEmpty && st.accountEndpoint.isEmpty && (← slot.get).isNone do throw (IO.userError "roster outlived identity")
      return
    if args == ["access-loss"] then
      -- Transient access loss is not a turn boundary: the output clears without
      -- archiving, and the replayed identical text shows exactly one visible copy.
      let st ← clickMission st b
      let st ← awaitState slot st (fun s => streamedText s == "second\n\tλ🙂\n")
      let st ← awaitState slot st (fun s => s.liveTurns.isEmpty && (streamedText s).isEmpty)
      let st ← awaitState slot st (fun s => streamedText s == "second\n\tλ🙂\n")
      let (rootBox, _) := renderScreen st "second\n\tλ🙂\n"
      unless st.liveTurns.isEmpty && ((renderedBoxRoot rootBox).splitOn "λ🙂").length == 2 do
        throw (IO.userError "replayed turn was archived or rendered more than once")
      return
    if args == ["share-403"] then
      -- Permission denial leaves the mission: the roster keeps only accessible
      -- missions and no earlier text survives from late frames.
      let st ← clickMission st b
      let st ← awaitState slot st (fun s => streamedText s == "second\n\tλ🙂\n")
      let next ← awaitState slot st (·.openMission.isNone)
      unless next.hasLiveConnection && (streamedText next).isEmpty && next.liveTurns.isEmpty &&
          next.missionCards.length == 1 &&
          !next.sidebarRows.any (·.widgetId == b.widgetId) do
        throw (IO.userError "permission loss retained earlier text or roster entry")
      let st ← clickMission next a
      let st ← awaitState slot st (fun s => streamedText s == "canonical")
      let (rootBox, _) := renderScreen st "canonical"
      unless !((renderedBoxRoot rootBox).contains "second") do
        throw (IO.userError "revoked mission text leaked into the new conversation")
      return
    let st ← clickMission st a
    let st ← awaitState slot st (fun s => streamedText s == "canonical")
    let (stopped, damage) := stepDesktopEvent 120 vp st (.activate 2)
    unless damage.isNone && stopped.composer == st.composer && !stopped.missionStopped do
      throw (IO.userError "live stop fabricated an effect")
    let (st, damage) := stepDesktopEvent 120 vp st (.text "draft A")
    unless damage.isSome && st.composer.text == "draft A" do throw (IO.userError "live typing lost draft")
    let (sent, damage) := stepDesktopEvent 120 vp st (.activate 2)
    unless damage.isNone && sent.composer == st.composer && !sent.messageSent do
      throw (IO.userError "live send consumed draft")
    let st ← awaitState slot st (fun s => (streamedText s).isEmpty && s.headerTitle == "Updated")
    unless st.composer.text == "draft A" && st.selectedCard.any (·.status == "awaiting_user") do
      throw (IO.userError "followup/status merge")
    let st ← clickMission st b
    unless st.openMission == some b.missionId && st.headerTitle == b.title && st.composer.text.isEmpty && st.composer.undoStack.isEmpty do
      throw (IO.userError "selection retained prior metadata or draft")
    let st ← awaitState slot st (fun s => streamedText s == "second\n\tλ🙂\n")
    if args == ["revoke"] then
      let next ← awaitState slot st (·.openMission.isNone)
      -- The late racing reply is not a turn boundary: nothing it showed is archived.
      unless next.hasLiveConnection && (streamedText next).isEmpty && next.liveTurns.isEmpty &&
          next.missionCards.length == 1 &&
          !next.sidebarRows.any (·.widgetId == b.widgetId) && next.missionCards.head?.any (·.missionId == a.missionId) do
        throw (IO.userError "mission revocation lost unrelated roster or retained selected data")
      return
    if args == ["oversize"] then
      let next ← awaitState slot st (fun s => (streamedText s).isEmpty)
      unless next.hasLiveConnection && next.openMission == some b.missionId && next.missionCards.length == 2 do
        throw (IO.userError "oversized payload wiped roster")
      return
    if args == ["leave"] then
      let (st, _) := stepDesktopEvent 120 vp st (.activate 101)
      discard <| readLiveFrame slot 120 vp st
      unless st.openMission.isNone && (streamedText st).isEmpty && (← slot.get).any (·.mission.isEmpty) do
        throw (IO.userError "mission reader survived navigation")
      IO.sleep 1200
      return
    if args == ["identity"] then
      let root := (← IO.getEnv "ORB_STATE_DIR").getD ""
      IO.FS.rename (System.FilePath.mk root / "rotated") (System.FilePath.mk root / "connection.json")
    let st ← awaitState slot st (·.connectionBinding.isEmpty)
    unless st.openMission.isNone && st.missionCards.isEmpty && st.sidebarRows == [settingsFooter] &&
        (streamedText st).isEmpty && (← slot.get).isNone do throw (IO.userError "invalidation leaked state")
  finally closeLiveSubscription slot

-- Compact chrome opens the same picker flow for a new draft and an existing mission.
private def compactSettings (mid : String) : MissionMenu :=
  { mission := mid, trigger := 714, page := .settings, x := 0, y := 0 }

#guard ((missionMenuRows hierarchyFixture (compactSettings "")).map (·.id)) == [720, 721, 722]
#guard !(missionMenuRows hierarchyFixture (compactSettings "m")).any (·.id == 720)

-- Replace focus on the loading placeholder when a member's remote nodes arrive.
private def waitingForNodes : DesktopState :=
  { hierarchyFixture with missionMenu := some { compactSettings "" with page := .picker .machine } }
#guard menuFocusChange waitingForNodes { waitingForNodes with launchMachines := some [("babylon", "Babylon")] } == some 2000000

private def remoteCatalogFixture : DesktopState := {
  hierarchyFixture with
  nativeHarnessAvailable := true
  draftSettings := { machine := "uruk" }
  missionMenu := some { compactSettings "" with page := .picker .backend }
  catalog := [⟨"codex", "Codex", "astra", "Astra"⟩]
  nativeCatalog := some ("uruk", [⟨"antigravity", "Antigravity CLI", "neon", "Neon"⟩]) }

#guard nativeCatalogRequest remoteCatalogFixture == some "uruk"
#guard (settingChoices remoteCatalogFixture "" .backend).length == 2
#guard settingChoices { remoteCatalogFixture with draftSettings := { machine := "babylon" } } "" .backend == [("codex", "Codex")]
#guard nativeCatalogRequest { remoteCatalogFixture with nativeHarnessAvailable := false } == none

private def nativeDraftFixture : DesktopState := { remoteCatalogFixture with
  draftSettings := { backend := "antigravity", model := "neon", machine := "uruk" } }

#guard (applyNativeCatalog nativeDraftFixture "uruk" []).draftSettings.model == ""
#guard (applyNativeCatalog nativeDraftFixture "babylon" []).draftSettings.model == "neon"
#guard (applyNativeCatalog { nativeDraftFixture with missionMenu := some (compactSettings "m") } "uruk" []).draftSettings.model == "neon"

private def inboxFixture : DesktopState := { hierarchyFixture with
  inboxAvailable := true
  inboxItems := [⟨"first", 10, 0, default⟩, ⟨"second", 20, 3, default⟩]
  sidebarRows := [{ widgetId := 102, rowId := "nav:inbox", kind := "nav", title := "Inbox" }] }
private def inboxStep (st : DesktopState) (event : Event) :=
  (stepDesktopEvent 120 vp st event).1
private def inboxOpened := inboxStep inboxFixture (.key 0x69 2 .pressed)
private def inboxSecond := inboxStep inboxOpened (.key 0xff54 0 .pressed)
#guard inboxOpened.screen == .inbox && inboxOpened.writeRequest.isNone
#guard desktopFocusChange inboxFixture inboxOpened (.activate 102) == some 940
#guard (inboxStep inboxSecond (.activate 941)).writeRequest == some (.inboxRead ⟨"second", 20, 3, default⟩ false)
#guard (inboxStep inboxSecond (.activate 940)).writeRequest == some (.inboxRead ⟨"second", 20, 3, default⟩ true)
