import OrbDesktop.Core
import OrbDesktop.Screens
import LeanUI.Runtime

open OrbDesktop LeanUI

private def vp : Rect := { x := 0, y := 0, w := 800, h := 600 }

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
  let boot ← loadLiveState
  if args == ["unavailable"] then
    unless boot.isNone do throw (IO.userError "failed bootstrap appeared successful")
    return
  let some st := boot | throw (IO.userError "bootstrap failed")
  let [a,b] := st.missionCards | throw (IO.userError "bad roster")
  unless st.sidebarRows.any (fun r => r.title == "Project title" && r.subtitle == "Objective") do
    throw (IO.userError "wrong project fields")
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
