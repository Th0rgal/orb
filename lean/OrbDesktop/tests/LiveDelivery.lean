import OrbDesktop.Core
import OrbDesktop.Screens
import LeanUI.Runtime

open OrbDesktop LeanUI

private def vp : Rect := { x := 0, y := 0, w := 800, h := 600 }

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

private def unsentDraft : DesktopState :=
  { hierarchyFixture with composer := { text := "Keep this draft" }, draftProject := "other" }

#guard (stepDesktopEvent 120 vp { unsentDraft with screen := .controlEmpty } (.composerReturn false)).1.writeRequest == some .create
#guard (stepDesktopEvent 120 vp unsentDraft (.composerReturn true)).1.composer.text == "\nKeep this draft"
#guard (stepDesktopEvent 120 vp { unsentDraft with composer := { unsentDraft.composer with imePreeditText := "か" } }
  (.composerReturn false)).1.writeRequest.isNone
#guard (stepDesktopEvent 120 vp { unsentDraft with composer := { unsentDraft.composer with isRunning := true } }
  (.composerReturn false)).1.writeRequest.isNone

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

def main (args : List String) : IO Unit := do
  let enter : Wayland.WlWireEvent := {
    tag := Wayland.tagPointer, proxy := 0, opcode := 0,
    args := #[.uint 417, .obj 0, .fixed 256, .fixed 512] }
  let (entered, _) ← Wayland.stepWireEvent { appliedCursor := some 4 } enter
  unless entered.enterSerial == some 417 && entered.appliedCursor.isNone do
    throw (IO.userError "pointer entry must use its own serial even when returning to the same row")
  let (left, _) ← Wayland.stepWireEvent entered { enter with opcode := 1, args := #[] }
  unless left.enterSerial.isNone do throw (IO.userError "cursor retained a serial after surface leave")
  let boot ← loadLiveState
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
          unless state.missionCards.length == 2 do throw (IO.userError "incomplete recovered roster")
          return
        IO.sleep 20
      throw (IO.userError "window failed to recover the new session and reload its catalog")
    return
  if args == ["unavailable"] then
    unless boot.isNone do throw (IO.userError "failed bootstrap appeared successful")
    return
  let some st := boot | throw (IO.userError "bootstrap failed")
  let [a,b] := st.missionCards | throw (IO.userError "bad roster")
  unless st.sidebarRows.any (fun r => r.title == "Project title" && r.subtitle == "Objective" && r.iconColor == some 0x8aaed4ff) do
    throw (IO.userError "wrong project fields")
  unless st.expandedProjects == ["p"] do throw (IO.userError "single project was collapsed at launch")
  let slot ← IO.mkRef (none : Option LiveSubscription)
  try
    if args == ["page-two"] || args == ["null-retry"] then
      let st ← clickMission st b
      let st ← awaitState slot st (fun s => streamedText s == "second\n\tλ🙂\n")
      unless st.openMission == some b.missionId && st.missionCards.length == 2 do throw (IO.userError "page displacement closed mission")
      return
    if args == ["idle-page-two"] then
      let mut current := st
      for _ in [0:150] do
        let (next, _) ← readLiveFrame slot 120 vp current
        unless next.hasLiveConnection && next.missionCards.length == 2 && next.openMission.isNone do
          throw (IO.userError "displaced authorized row dropped from idle roster")
        current := next
        IO.sleep 10
      return
    if args == ["idle-session"] then
      let next ← awaitState slot st (!·.hasLiveConnection)
      unless next.missionCards.isEmpty && next.sidebarRows.isEmpty do throw (IO.userError "idle session retained data")
      return
    if args == ["idle-share"] then
      let next ← awaitState slot st (·.missionCards.length == 1)
      unless next.hasLiveConnection && next.missionCards.head?.any (·.missionId == a.missionId) &&
          !next.sidebarRows.any (·.widgetId == b.widgetId) do throw (IO.userError "idle share removal incorrect")
      return
    if args == ["idle-identity"] || args == ["before-open"] then
      discard <| readLiveFrame slot 120 vp st
      let root := (← IO.getEnv "ORB_STATE_DIR").getD ""
      IO.FS.rename (System.FilePath.mk root / "rotated") (System.FilePath.mk root / "connection.json")
      let st := if args == ["before-open"] then (stepDesktopEvent 120 vp st (.activate a.widgetId)).1 else st
      let st ← awaitState slot st (!·.hasLiveConnection)
      unless st.missionCards.isEmpty && (← slot.get).isNone do throw (IO.userError "roster outlived identity")
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
      unless next.hasLiveConnection && (streamedText next).isEmpty && next.missionCards.length == 1 &&
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
    unless st.openMission.isNone && st.missionCards.isEmpty && st.sidebarRows.isEmpty &&
        (streamedText st).isEmpty && (← slot.get).isNone do throw (IO.userError "invalidation leaked state")
  finally closeLiveSubscription slot
