import OrbDesktop.State
import OrbDesktop.Screens
import Orb.Scroll

/-!
# InputU6Sweep — Exhaustive 9-Screen Hit-Testing, `Orb.Scroll` Policy & Control Verification

Lays out all 9 canonical screens + live interactive views (transcript + side panel,
Inference VPN/routing, Machines, Cloud, Resources, Inbox, Settings, Search modal) at
1470×923 (1x and 2x), asserts:
- Zero duplicate widget IDs in `focusableOrder` or `hitRegionsSub` (catches focus-loop collisions).
- Every interactive control has a non-empty hit region inside the viewport whose center
  hit-tests back to that exact widget ID and is present in `focusableOrder`.
- `ScrollPolicyState` matches `Orb.Scroll` at exact boundary values.
- Executable regression guards for modal focus traps, live `Back`/`Forward` invariants,
  Search modal interior clicks, IME/text input isolation, and Escape key-release handling.
-/

open LeanUI OrbDesktop

private def vpW : SubPx := pxToSub 1470
private def vpH : SubPx := pxToSub 923
private def vpDev : Rect := { x := 0, y := 0, w := 1470, h := 923 }

private def renderScreenScene (st : DesktopState) (scale120 : Nat := 120) :
    ComputedBox × SceneOutput :=
  let runs : ShapedScreenRuns :=
    { headerTitleRuns := [Widgets.overlaySynthRun (chromeTitleStyle st.theme) st.headerTitle] }
  let tree := buildDesktopScreen st vpW vpH runs
  let focus := st.initialFocusState
  let (box, scene) := renderWidgetTree scale120 vpW vpH focus st.theme tree
  match st.modal with
  | .searchPalette spec =>
    let over := buildSearchModalOverlay st.theme vpW vpH spec st.searchFilterTab
      st.searchProjectFilter st.searchTimeFilter st.searchSortOrder (!st.liveData)
    let (obox, oscene) := renderWidgetTree scale120 vpW vpH focus st.theme over
    let outside : Rect := { x := 0, y := 0, w := vpW, h := vpH }
    (obox, { oscene with hitRegionsSub := (searchBackdropId, outside) :: oscene.hitRegionsSub })
  | _ => (box, scene)

private def findDuplicates (ids : List WidgetId) : List WidgetId := Id.run do
  let mut seen : List WidgetId := []
  let mut dups : List WidgetId := []
  for id in ids do
    if seen.contains id && !dups.contains id then
      dups := dups ++ [id]
    else
      seen := id :: seen
  return dups

private def assertHitTargets (label : String) (st : DesktopState) (ids : List WidgetId) : IO Unit := do
  for sc in [120, 240] do
    let (_, scene) := renderScreenScene st sc
    let focusDups := findDuplicates scene.focusableOrder
    unless focusDups.isEmpty do
      throw <| IO.userError s!"{label} (scale={sc}): duplicate widget IDs in focusableOrder: {repr focusDups}"
    let hitDups := findDuplicates (scene.hitRegionsSub.map (·.1))
    unless hitDups.isEmpty do
      throw <| IO.userError s!"{label} (scale={sc}): duplicate widget IDs in hitRegionsSub: {repr hitDups}"
    for id in ids do
      let some (_, r) := scene.hitRegionsSub.find? (·.1 == id)
        | throw <| IO.userError s!"{label} (scale={sc}): missing hit region for widget {id}"
      let cx := r.x + r.w / 2
      let cy := r.y + r.h / 2
      unless r.w > 0 && r.h > 0 && cx ≥ 0 && cx < (vpW : Int) && cy ≥ 0 && cy < (vpH : Int) do
        throw <| IO.userError s!"{label} (scale={sc}): widget {id} out of viewport bounds {repr r}"
      let got := hitTest scene.hitRegionsSub cx cy
      unless got == some id do
        throw <| IO.userError s!"{label} (scale={sc}): hitTest at center of {id} returned {repr got}"
      unless scene.focusableOrder.contains id do
        throw <| IO.userError s!"{label} (scale={sc}): widget {id} missing from focusableOrder"

private def verifyOrbScrollEquivalence : IO Unit := do
  let contentPx : Nat := 2000
  let viewPx : Nat := 500
  let contentSub := pxToSub contentPx
  let viewSub := pxToSub viewPx
  let s0 : ScrollPolicyState := { pinned := true, topSub := pxToSub 1500 }
  let s1 := s0.onUserScroll contentSub viewSub (-(Int.ofNat (pxToSub 200)))
  let o1 := Orb.Scroll.userScroll s0.toOrbScrollState contentPx viewPx 1300
  unless s1.toOrbScrollState == o1 && !s1.pinned do
    throw <| IO.userError s!"scroll up mismatch: {repr s1} vs {repr o1}"
  let sAtNear := s1.onUserScroll contentSub viewSub (Int.ofNat (pxToSub 176))
  let oAtNear := Orb.Scroll.userScroll o1 contentPx viewPx 1476
  unless sAtNear.toOrbScrollState == oAtNear && !sAtNear.pinned do
    throw <| IO.userError s!"scroll at exact near boundary mismatch: {repr sAtNear} vs {repr oAtNear}"
  let sInsideNear := sAtNear.onUserScroll contentSub viewSub (Int.ofNat (pxToSub 1))
  let oInsideNear := Orb.Scroll.userScroll oAtNear contentPx viewPx 1477
  unless sInsideNear.toOrbScrollState == oInsideNear && sInsideNear.pinned do
    throw <| IO.userError s!"scroll inside near boundary mismatch: {repr sInsideNear} vs {repr oInsideNear}"
  let sResize := sInsideNear.onScrollEvent false true (pxToSub 2400) viewSub (pxToSub 1000)
  unless sResize.pinned do
    throw <| IO.userError "passive resize flipped pinned"
  let sJump := s1.onJump contentSub viewSub
  unless sJump.toOrbScrollState == Orb.Scroll.jump o1 contentPx viewPx && sJump.pinned do
    throw <| IO.userError "onJump mismatch with Orb.Scroll.jump"

private def verifyNineScreenControls : IO Unit := do
  -- Screen 01: controlEmpty
  assertHitTargets "01_control_empty" (DesktopState.forScreen .controlEmpty)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId,
     101, 102, 111, 112, 113, 114, 103,
     draftProjectPickerId, 720, draftDirectoryPickerId, 1, 3, 722, 2]

  -- Screen 02: controlPopulated
  assertHitTargets "02_control_populated" (DesktopState.forScreen .controlPopulated)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId,
     101, 102, 112, 113, 103,
     draftProjectPickerId, 720, draftDirectoryPickerId, 1, 3, 722, 2]

  -- Screen 03: missionTranscript
  assertHitTargets "03_mission_transcript" (DesktopState.forScreen .missionTranscript)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId,
     sidePanelDiffId, sidePanelFilesId, sidePanelChatId,
     101, 105, 103, 1, 3, 2]

  -- Screen 04: missionSplitDiff
  assertHitTargets "04_mission_split_diff" (DesktopState.forScreen .missionSplitDiff)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId,
     sidePanelDiffId, sidePanelFilesId, sidePanelChatId,
     1, 3, 2, diffRefId, diffUnifiedId, diffSplitId, diffRefreshId, diffFileChipId]

  -- Screen 05: machinesFleet
  assertHitTargets "05_machines_fleet" (DesktopState.forScreen .machinesFleet)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId, 112, 103,
     fleetLocalId, fleetCoreId, fleetPrimaryId, fleetLargeAId, fleetDefaultBId, fleetSoftwareId, fleetCopyKeyId]

  -- Screen 06: settingsGeneral
  assertHitTargets "06_settings_general" (DesktopState.forScreen .settingsGeneral)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId,
     101, 102, 111, 112, 113, 114, 103,
     settingsTabAccountId, settingsTabUsersId, settingsTabTelemetryId,
     settingsApiUrlId, settingsDisconnectId, settingsConnectGhId, settingsRefreshCloudId,
     settingsThemeId, settingsSyncId]

  -- Screen 07: searchDialog (modal traps focus, interior card does not hit backdrop)
  let searchSt := DesktopState.forScreen .searchDialog
  assertHitTargets "07_search_dialog" searchSt
    [701, searchClearId, searchEscId, searchOpenId,
     searchTabAllId, searchTabUserId, searchTabAssistantId, searchTabTitlesId, searchTabToolsId,
     searchProjectFilterId, searchTimeFilterId, searchSortOrderId,
     702, 703, 704]
  let (_, searchScene) := renderScreenScene searchSt 120
  unless hitTest searchScene.hitRegionsSub (pxToSub 900) (pxToSub 300) == some searchDialogCardId do
    throw <| IO.userError "clicking inside Search modal preview pane must hit searchDialogCardId, not backdrop"
  unless hitTest searchScene.hitRegionsSub (pxToSub 20) (pxToSub 20) == some searchBackdropId do
    throw <| IO.userError "clicking outside Search modal card must hit searchBackdropId"

  -- Screen 08: newMissionDialog
  assertHitTargets "08_new_mission_dialog" (DesktopState.forScreen .newMissionDialog)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId,
     draftProjectPickerId, 720, draftDirectoryPickerId, 1, 3, 722, 2]

  -- Screen 09: toastNotifications
  assertHitTargets "09_toast_notifications" (DesktopState.forScreen .toastNotifications)
    [sidebarToggleId, sidebarSearchId, sidebarBackId, sidebarForwardId, 1, 3, 2, 911, 912, 913]

  -- Verify dismissing toasts individually preserves remaining toasts and their hit regions
  let t0 := DesktopState.forScreen .toastNotifications
  let t1 := (stepDesktopEvent 120 vpDev t0 (.activate 912)).1
  unless t1.toasts.length == 2 && t1.toasts.all (·.dismissButtonId != some 912) do
    throw <| IO.userError "dismissing toast 912 did not remove only toast 912"
  assertHitTargets "09_toast_after_dismiss_912" t1 [911, 913]

  -- Verify live Inference VPN & Alternative Routers hit-testing
  let infBase : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .inference
    connectionBinding := "u6-live"
    providers := some [
      { id := "acct-1", name := "Antigravity", category := "Antigravity", userEnabled := true, globallyEnabled := true, providerType := "antigravity" }
    ]
  }
  assertHitTargets "live_inference_list" infBase [providerWidgetId 0, providerSettingsId 0]
  let infRoute : DesktopState := {
    infBase with
    accountRoutePage := some {
      account := infBase.providers.get!.head!
      options := some [
        { action := "", value := "", title := "Account connection", detail := "Direct" },
        { action := "vpn", value := "NL", title := "AirVPN · NL", detail := "" },
        { action := "routers", value := "off", title := "Alternative routers", detail := "Allowed" }
      ]
    }
  }
  assertHitTargets "live_inference_vpn_routes" infRoute [providersBackId, providerRouteId 1, providerRouteId 2]

  -- Verify live side-panel hit-testing on missionTranscript
  let liveTx : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .missionTranscript
    connectionBinding := "u6-live"
    openMission := some "m1"
    sidePanelOpen := true
    sidePanelTab := "diff"
    missionCards := [{ (default : MissionSummaryCard) with widgetId := 1001, missionId := "m1", title := "Live Mission" }]
  }
  assertHitTargets "live_transcript_side_panel" liveTx
    [sidePanelDiffId, sidePanelFilesId, sidePanelChatId, sidePanelCloseId, diffRefId, diffUnifiedId, diffSplitId, diffRefreshId, diffFileChipId, 1, 3, 2]

  -- Verify live Cloud, Resources, and Inbox hit-testing + no scrollClip hit pollution
  let cloudLive : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .cloud
    connectionBinding := "u6-live"
    cloudLines := some ["Cursor · Ready"]
    cloudAccounts := [("cursor_cloud", "c1", "Team 1"), ("cursor_cloud", "c2", "Team 2")]
    sidebarRows := [
      { widgetId := 1000, rowId := "project:p1", kind := "project", title := "P1" },
      { widgetId := 1003, rowId := "project:p2", kind := "project", title := "P2" }
    ]
  }
  let (_, cloudScene) := renderScreenScene cloudLive 120
  unless !cloudScene.hitRegionsSub.any (fun (id, _) => id == rosterViewportId || id == transcriptViewportId || id == fleetViewportId) do
    throw <| IO.userError "scrollClip viewport IDs must not appear in hitRegionsSub"
  assertHitTargets "live_cloud_controls" cloudLive [960, 970, 971, 1]

  let resLive : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .resources
    connectionBinding := "u6-live"
    resourceRows := some ((List.range 5).map fun i =>
      { mission := s!"m{i}", title := s!"Active worker {i}", usage := "2 vCPU · 1.2 B tok/h" })
  }
  assertHitTargets "live_resources_controls" resLive [955, 956, 945, 946, 947]

  let inboxLive : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .inbox
    connectionBinding := "u6-live"
    inboxAvailable := true
    inboxEnabled := true
    inboxItems := [
      { mission := "m1", stamp := 100, version := 1, card := { (default : MissionSummaryCard) with widgetId := 1001, missionId := "m1", title := "Inbox Mission 1" } },
      { mission := "m2", stamp := 200, version := 1, card := { (default : MissionSummaryCard) with widgetId := 1002, missionId := "m2", title := "Inbox Mission 2" } }
    ]
  }
  assertHitTargets "live_inbox_controls" inboxLive [940, 941, 943]

private def verifyInteractionRegressions : IO Unit := do
  -- Finding 1: closing Search dialog pops focus traps and restores focusability on target screen.
  let s0 := DesktopState.forScreen .searchDialog
  unless desktopFocusTraps s0 == [searchModalTrapIds defaultSearchDialogSpec] do
    throw <| IO.userError "search dialog must expose modal focus trap"
  let (sClosed, _) := stepDesktopEvent 120 vpDev s0 (.key 0xff1b 0 .pressed)
  unless sClosed.modal == .none && desktopFocusTraps sClosed == [] do
    throw <| IO.userError "closing search dialog must clear focus traps"
  let fAfter := ({ s0.initialFocusState with traps := desktopFocusTraps sClosed }).request 1
  unless fAfter.owner == some 1 do
    throw <| IO.userError "focus request on composer 1 after closing search dialog must succeed"

  -- Finding 3: live Back/Forward preserves openMission invariants (no zombie transcript or leaked mission on controlEmpty).
  let card1 : MissionSummaryCard := { (default : MissionSummaryCard) with widgetId := 1001, missionId := "m1", title := "Mission 1", status := "active" }
  let live0 : DesktopState := {
    DesktopState.liveUnavailable with
    connectionBinding := "u6-live"
    missionCards := [card1]
    sidebarRows := [
      { widgetId := 101, rowId := "nav:new", kind := "nav", title := "New Agent", selected := true },
      { widgetId := 112, rowId := "nav:machines", kind := "nav", title := "Machines" },
      { widgetId := 1001, rowId := "mission:m1", kind := "mission", title := "Mission 1", status := "active" },
      settingsFooter
    ]
  }
  let liveMachines := (stepDesktopEvent 120 vpDev live0 (.key 0x33 2 .pressed)).1
  let liveMission := (stepDesktopEvent 120 vpDev liveMachines (.activate 1001)).1
  unless liveMission.screen == .missionTranscript && liveMission.openMission == some "m1" do
    throw <| IO.userError "opening mission m1 failed"
  let backToMachines := (stepDesktopEvent 120 vpDev liveMission (.key 0x5b 2 .pressed)).1
  unless backToMachines.screen == .machinesFleet && backToMachines.openMission.isNone do
    throw <| IO.userError "Back to Machines leaked openMission"
  let backToControl := (stepDesktopEvent 120 vpDev backToMachines (.key 0x5b 2 .pressed)).1
  unless backToControl.screen == .controlEmpty && backToControl.openMission.isNone do
    throw <| IO.userError "Back to Control Empty leaked openMission"
  let fwdToMachines := (stepDesktopEvent 120 vpDev backToControl (.key 0x5d 2 .pressed)).1
  let fwdToMission := (stepDesktopEvent 120 vpDev fwdToMachines (.key 0x5d 2 .pressed)).1
  unless fwdToMission.screen == .missionTranscript && fwdToMission.openMission == some "m1" do
    throw <| IO.userError "Forward to Mission m1 failed to restore openMission"

  -- Finding 6: live Escape release does NOT close sidePanelOpen or clear multiRows.
  let livePanel : DesktopState := { liveMission with sidePanelOpen := true, multiRows := ["mission:m1"] }
  let afterRelease := (stepDesktopEvent 120 vpDev livePanel (.key 0xff1b 0 .released)).1
  unless afterRelease.sidePanelOpen && afterRelease.multiRows == ["mission:m1"] do
    throw <| IO.userError "Escape key release must not close sidePanelOpen or clear multiRows"
  -- Fixture split-diff starts with sidePanelOpen=true and Escape reverts to missionTranscript.
  let split0 := DesktopState.forScreen .missionSplitDiff
  unless split0.sidePanelOpen do
    throw <| IO.userError "04_mission_split_diff must initialize sidePanelOpen := true"
  let splitEsc := (stepDesktopEvent 120 vpDev split0 (.key 0xff1b 0 .pressed)).1
  unless !splitEsc.sidePanelOpen && splitEsc.screen == .missionTranscript do
    throw <| IO.userError "Escape on 04_mission_split_diff must close side panel and revert to missionTranscript"

  -- Finding 5: fixture Send clears imePreeditText and ignores composerReturn while preedit is active.
  let compPre : DesktopState := { DesktopState.forScreen .controlEmpty with composer := ((DesktopState.forScreen .controlEmpty).composer.insertText "hi").setPreedit "ni" }
  let retBlocked := (stepDesktopEvent 120 vpDev compPre (.composerReturn false)).1
  unless !retBlocked.messageSent && retBlocked.composer.text == "hi" do
    throw <| IO.userError "composerReturn must not send while IME preedit is active"
  let sentClick := (stepDesktopEvent 120 vpDev compPre (.activate 2)).1
  unless sentClick.messageSent && sentClick.composer.text.isEmpty && sentClick.composer.imePreeditText.isEmpty do
    throw <| IO.userError "Send button must clear composer text and imePreeditText"

  -- Finding 5: live missionMenu Rename confirms on composerReturn false.
  let renameMenu : DesktopState := {
    live0 with
    missionMenu := some { mission := "m1", x := 0, y := 0, page := .rename, draft := { text := "Renamed M1", cursorOffset := 10 } }
  }
  let renamed := (stepDesktopEvent 120 vpDev renameMenu (.composerReturn false)).1
  unless renamed.missionMenu.isNone && renamed.writeRequest == some (.rename "m1" "Renamed M1") do
    throw <| IO.userError "Return in live Rename menu must submit LiveWrite.rename"

  -- Finding 8: desktopFocusChange on fixture Settings focuses settingsTabAccountId (not live-only accountFormId).
  let fx0 := DesktopState.forScreen .controlEmpty
  let fxSet := (stepDesktopEvent 120 vpDev fx0 (.activate 103)).1
  unless desktopFocusChange fx0 fxSet (.activate 103) == some settingsTabAccountId do
    throw <| IO.userError "fixture Settings focus change must target settingsTabAccountId"

def main : IO UInt32 := do
  verifyOrbScrollEquivalence
  verifyNineScreenControls
  verifyInteractionRegressions
  IO.println "InputU6Sweep: all 9 screens, live panels, Inference VPN/routing, Orb.Scroll, and regression checks passed"
  return 0
