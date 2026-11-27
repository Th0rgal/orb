import OrbDesktop.State
import OrbDesktop.Screens
import Orb.Scroll
import LeanUI.Runtime

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

  -- Review Blocker 1: Live Search modal with >= 8 missions uses disjoint result IDs (10000 + i),
  -- avoiding collisions with Search controls (706..744) during clicking and Tab-cycling past result #5.
  let manyCards : List MissionSummaryCard := (List.range 8).map fun i =>
    { (default : MissionSummaryCard) with
      widgetId := 1001 + i
      missionId := s!"m{i}"
      title := s!"Live Mission {i}"
      project := "Project 1"
      status := "completed" }
  let liveMany0 : DesktopState := {
    DesktopState.liveUnavailable with
    connectionBinding := "u6-live"
    missionCards := manyCards
    sidebarRows := [
      { widgetId := 101, rowId := "nav:new", kind := "nav", title := "New Agent", selected := true },
      settingsFooter
    ] ++ manyCards.map fun c =>
      { widgetId := c.widgetId, rowId := "mission:" ++ c.missionId, kind := "mission", title := c.title, status := c.status }
  }
  let liveSearchSt := (stepDesktopEvent 120 vpDev liveMany0 (.key 0x6b 2 .pressed)).1
  match liveSearchSt.modal with
  | .searchPalette spec =>
    unless spec.items.length == 8 do
      throw <| IO.userError s!"live Search modal expected 8 items, got {spec.items.length}"
    for i in List.range 8 do
      let expectedWid := liveSearchResultWidgetId i
      unless spec.items[i]?.map (·.widgetId) == some expectedWid do
        throw <| IO.userError s!"live Search item #{i} expected widgetId {expectedWid}"
    assertHitTargets "live_search_8_missions" liveSearchSt
      ([701, searchClearId, searchEscId, searchOpenId,
        searchTabAllId, searchTabUserId, searchTabAssistantId, searchTabTitlesId, searchTabToolsId,
        searchProjectFilterId, searchTimeFilterId, searchSortOrderId] ++
       (List.range 7).map liveSearchResultWidgetId)
    -- Tab-cycle from search input (701) through all controls and past result #5 (index 5 -> 10005) & #6 (10006).
    let (_, liveSearchScene) := renderScreenScene liveSearchSt 120
    let mut foc := liveSearchSt.initialFocusState
    let mut visited : List WidgetId := []
    for _ in List.range liveSearchScene.focusableOrder.length do
      foc := cycleFocus foc liveSearchScene.focusableOrder
      match foc.owner with
      | some wid => visited := visited ++ [wid]
      | none => throw <| IO.userError "Tab-cycling in live Search modal lost focus"
    unless visited.contains (liveSearchResultWidgetId 5) && visited.contains (liveSearchResultWidgetId 6) do
      throw <| IO.userError s!"Tab-cycling in live Search modal did not reach results #5/#6: {repr visited}"
    let idx4 := visited.findIdx? (· == liveSearchResultWidgetId 4)
    let idx5 := visited.findIdx? (· == liveSearchResultWidgetId 5)
    let idx6 := visited.findIdx? (· == liveSearchResultWidgetId 6)
    unless idx4.isSome && idx5 == idx4.map (· + 1) && idx6 == idx5.map (· + 1) do
      throw <| IO.userError s!"Tab order across live Search results #4/#5/#6 was broken: {repr visited}"
    -- Clicking result #5 (10005) selects index 5 (does not trigger searchClearId/searchEscId), and second click opens m5.
    let typedSearch := (stepDesktopEvent 120 vpDev liveSearchSt (.text "Live")).1
    let clicked5 := (stepDesktopEvent 120 vpDev typedSearch (.activate (liveSearchResultWidgetId 5))).1
    match clicked5.modal with
    | .searchPalette spec5 =>
      unless spec5.selectedIdx == 5 && spec5.query == "Live" do
        throw <| IO.userError s!"clicking result #5 must select index 5 without clearing query, got {repr spec5.selectedIdx} / {repr spec5.query}"
    | _ => throw <| IO.userError "clicking result #5 once closed Search modal prematurely"
    let opened5 := (stepDesktopEvent 120 vpDev clicked5 (.activate (liveSearchResultWidgetId 5))).1
    unless opened5.modal == .none && opened5.screen == .missionTranscript && opened5.openMission == some "m5" do
      throw <| IO.userError s!"second click on result #5 failed to open m5: screen={repr opened5.screen}, openMission={repr opened5.openMission}"
    -- ArrowDown to result #7 (index 7 -> 10007) scrolls window and activates m7 cleanly.
    let mut scrolled := liveSearchSt
    for _ in List.range 7 do
      scrolled := (stepDesktopEvent 120 vpDev scrolled (.key 0xff54 0 .pressed)).1
    assertHitTargets "live_search_8_missions_scrolled" scrolled
      [701, searchClearId, searchEscId, searchOpenId, liveSearchResultWidgetId 5, liveSearchResultWidgetId 6, liveSearchResultWidgetId 7]
    let opened7 := (stepDesktopEvent 120 vpDev scrolled (.activate (liveSearchResultWidgetId 7))).1
    unless opened7.modal == .none && opened7.screen == .missionTranscript && opened7.openMission == some "m7" do
      throw <| IO.userError "clicking selected result #7 failed to open m7"
    -- searchClearId (706) and searchEscId (707) still function cleanly with 8 live missions.
    let cleared := (stepDesktopEvent 120 vpDev typedSearch (.activate searchClearId)).1
    match cleared.modal with
    | .searchPalette specClr =>
      unless specClr.query == "" do throw <| IO.userError "searchClearId failed to clear live Search query"
    | _ => throw <| IO.userError "searchClearId unexpectedly closed Search modal"
    let escaped := (stepDesktopEvent 120 vpDev cleared (.activate searchEscId)).1
    unless escaped.modal == .none do
      throw <| IO.userError "searchEscId failed to close live Search modal"
  | _ => throw <| IO.userError "Ctrl+K did not open live Search modal"

  -- Review Blocker 2: Embedded GTK hybrid sidebar emits toolbar IDs 117..120 (not 351..353),
  -- while standalone sidebar emits 117 and 351..353.
  let embSt : DesktopState := {
    DesktopState.liveUnavailable with
    sidebarRows := [
      { widgetId := 1000, rowId := "nav:new", kind := "nav", title := "New Agent", selected := true },
      { widgetId := 1001, rowId := "nav:settings", kind := "footer", title := "Settings" }
    ]
  }
  let embRoot := buildSidebarChrome embSt vpH (width := chromeSidebarWidthSub) (embedded := true)
  let (_, embScene) := renderWidgetTree 120 chromeSidebarWidthSub vpH {} embSt.theme embRoot
  let embHitDups := findDuplicates (embScene.hitRegionsSub.map (·.1))
  unless embHitDups.isEmpty do
    throw <| IO.userError s!"embedded sidebar has duplicate hit IDs: {repr embHitDups}"
  for tid in ([117, 118, 119, 120] : List WidgetId) do
    let some (_, r) := embScene.hitRegionsSub.find? (·.1 == tid)
      | throw <| IO.userError s!"embedded sidebar missing toolbar hit region {tid}"
    unless r.w > 0 && r.h > 0 && hitTest embScene.hitRegionsSub (r.x + r.w / 2) (r.y + r.h / 2) == some tid do
      throw <| IO.userError s!"embedded sidebar toolbar hit region {tid} failed center hit-test: {repr r}"
  for standaloneId in ([sidebarSearchId, sidebarBackId, sidebarForwardId] : List WidgetId) do
    if embScene.hitRegionsSub.any (·.1 == standaloneId) then
      throw <| IO.userError s!"embedded sidebar must not emit standalone toolbar ID {standaloneId}"

  -- Review Minor 4: measurePrependedHeightDelta accounts for narrowed leftW when sidePanelOpen is true.
  let narrowVp : Rect := { x := 0, y := 0, w := 1200, h := 923 }
  let longTurn := String.intercalate " " (List.replicate 20 "**segment** plain")
  let txClosed : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .missionTranscript
    connectionBinding := "u6-live"
    openMission := some "m1"
    sidePanelOpen := false
  }
  let txOpen : DesktopState := { txClosed with sidePanelOpen := true, sidePanelTab := "diff" }
  let deltaClosed := measurePrependedHeightDelta txClosed 120 narrowVp [longTurn] false false
  let deltaOpen := measurePrependedHeightDelta txOpen 120 narrowVp [longTurn] false false
  unless deltaOpen > deltaClosed do
    throw <| IO.userError s!"measurePrependedHeightDelta with sidePanelOpen=true ({deltaOpen}) must exceed sidePanelOpen=false ({deltaClosed}) for wrapping text"
  let mainW1200 : SubPx := pxToSub 1200 - txOpen.sidebarWidth
  let leftW1200 : SubPx := mainW1200 - min (pxToSub 480) (mainW1200 / 2)
  let colW1200 : SubPx := min (pxToSub 748) (leftW1200 - pxToSub 48)
  let (expectedRows, _) := buildLiveTurnsNodes txOpen.theme colW1200 (transcriptTextWidth leftW1200) [longTurn]
  let expectedDelta : Int := expectedRows.foldl (fun acc row =>
    let (_, rowH) := measureNode leftW1200 row.toLayoutNode
    acc + (rowH : Int) + (transcriptColumnGapSub : Int)) 0
  unless deltaOpen == expectedDelta do
    throw <| IO.userError s!"measurePrependedHeightDelta sidePanelOpen mismatch: got {deltaOpen}, expected {expectedDelta}"

private def verifyScrollbarQuietFocusAndCaret : IO Unit := do
  -- 1. Pure caret positioning (empty, mid-string, multi-byte UTF-8, IME preedit).
  let theme := orbDarkTheme
  let caretX (txt : String) (pos : Nat) : Option Int :=
    let st : TextStyle := Theme.bodyText theme
    let run := { Widgets.overlaySynthRun st txt with editorStart := if txt.isEmpty then none else some 0 }
    let node := WidgetNode.focusable 701 <|
      WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 260) (pxToSub 22)) (pxToSub 22)
        [run] none (some { owner := 701, pos, length := txt.length, color := theme.palette.textPrimary })
    let (_, scene) := renderWidgetTree 120 (pxToSub 260) (pxToSub 22) { owner := some 701 } theme node (focusVisible := false)
    scene.prims.toList.findSome? fun p => match p with
      | .quad r col 0 0 0 => if col == theme.palette.textPrimary then some r.x else none
      | _ => none
  unless caretX "" 0 == some 0 do
    throw <| IO.userError "caret: empty string caret must sit at x=0"
  let some xMid := caretX "hello world" 5 | throw <| IO.userError "caret: mid-string missing"
  let some xEnd := caretX "hello world" 11 | throw <| IO.userError "caret: end-string missing"
  unless 0 < xMid && xMid < xEnd do
    throw <| IO.userError s!"caret: ASCII ordering broken ({xMid}, {xEnd})"
  let multi := "a日🚀z"
  let mut lastX : Int := -1
  for i in [0 : multi.length + 1] do
    let some xi := caretX multi i | throw <| IO.userError s!"caret: missing at UTF-8 scalar {i}"
    unless xi > lastX do
      throw <| IO.userError s!"caret: UTF-8 scalar {i} did not advance ({xi} <= {lastX})"
    lastX := xi
  let imeBuf := ({ text := "ab", cursorOffset := 1 } : Widgets.ComposerBuffer).setPreedit "検索"
  let imePos := Widgets.ComposerBuffer.clampCursor imeBuf.text imeBuf.cursorOffset + imeBuf.imePreeditText.length
  let some xBeforeIme := caretX imeBuf.displayText 1 | throw <| IO.userError "caret: missing before preedit"
  let some xAfterIme := caretX imeBuf.displayText imePos | throw <| IO.userError "caret: missing after preedit"
  unless imeBuf.displayText == "a検索b" && imePos == 3 && xAfterIme > xBeforeIme do
    throw <| IO.userError "caret: IME preedit caret did not advance past preedit"

  -- 2. Quiet pointer focus vs keyboard Tab :focus-visible on real controlPopulated pills + borderless search 701.
  let popSt := DesktopState.forScreen .controlPopulated
  let popTree := buildDesktopScreen popSt vpW vpH {}
  let (_, popQuiet) := renderWidgetTree 120 vpW vpH { owner := some draftProjectPickerId } popSt.theme popTree (focusVisible := false)
  let (_, popKeyboard) := renderWidgetTree 120 vpW vpH { owner := some draftProjectPickerId } popSt.theme popTree (focusVisible := true)
  let hasFocusRing (s : SceneOutput) (col : Color) : Bool :=
    s.prims.any fun p => match p with
      | .quad _ 0 _ bw c => bw > 0 && c == col
      | _ => false
  if hasFocusRing popQuiet popSt.theme.palette.focusRing then
    throw <| IO.userError "quiet focus: pointer-focused pill must not paint focusRing"
  unless hasFocusRing popKeyboard popSt.theme.palette.focusRing do
    throw <| IO.userError "keyboard focus: Tab-focused pill must paint focusRing"
  -- Borderless search input 701 never draws a box outline even with focusVisible = true.
  let (_, searchScene) := renderScreenScene (DesktopState.forScreen .searchDialog) 120
  if hasFocusRing searchScene orbDarkTheme.palette.focusRing then
    throw <| IO.userError "search input 701 must stay borderless (no focusRing box outline)"
  -- Cloud Agent prompt editor (`id = 1` on `ScreenId.cloud`) steps its 1px border AND draws its caret even on pointer click (`focusVisible = false`).
  let cloudFocusSt : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .cloud
    connectionBinding := "u6-live"
    cloudLines := some ["Cursor · Ready"]
    cloudAccounts := [("cursor_cloud", "c1", "Team 1")]
    cloudDraft := { text := "deploy check", cursorOffset := 6 }
    sidebarRows := [{ widgetId := 1000, rowId := "project:p1", kind := "project", title := "P1" }]
  }
  let cloudTree := buildDesktopScreen cloudFocusSt vpW vpH {}
  let (_, cloudFocusedScene) := renderWidgetTree 120 vpW vpH { owner := some 1 } cloudFocusSt.theme cloudTree (focusVisible := false)
  let hasCaretPrim (s : SceneOutput) (col : Color) : Bool :=
    s.prims.any fun p => match p with
      | .quad r c 0 0 0 => c == col && r.w >= 1 && r.h >= 10
      | _ => false
  unless hasFocusRing cloudFocusedScene cloudFocusSt.theme.palette.focusRing do
    throw <| IO.userError "cloud editor (id=1) must step its border when focused even with focusVisible = false"
  unless hasCaretPrim cloudFocusedScene cloudFocusSt.theme.palette.textPrimary do
    throw <| IO.userError "cloud editor (id=1) must render its vertical text caret when focused"
  -- Rename menu inline editor (`item.id = 1` in `buildMissionMenu`) renders its vertical caret when focused.
  let renameSt : DesktopState := {
    DesktopState.liveUnavailable with
    connectionBinding := "u6-live"
    missionCards := [{ (default : MissionSummaryCard) with widgetId := 1001, missionId := "m1", title := "Old Title" }]
  }
  let renameMenu : MissionMenu := { mission := "m1", x := 0, y := 0, page := .rename, draft := { text := "New Title", cursorOffset := 3 } }
  let menuTree := buildMissionMenu renameSt renameMenu (pxToSub 228) 4
  let (_, menuScene) := renderWidgetTree 120 (pxToSub 228) (pxToSub 120) { owner := some 1 } renameSt.theme menuTree (focusVisible := false)
  unless hasCaretPrim menuScene renameSt.theme.palette.textPrimary do
    throw <| IO.userError "missionMenu rename input (id=1) must render its vertical text caret when focused"
  -- Right-click press clears focusVisible; effectiveEvent handles inputs 1, 701, 604 consistently.
  let rtRight : Runtime.RuntimeState Unit := { app := (), focus := { owner := some 105 }, focusVisible := true, focusableOrder := [105] }
  let afterRight := rtRight.stepEvent (fun s _ => (s, none)) (.pointerButton (pxToSub 40) (pxToSub 80) 0x111 true)
  unless !afterRight.focusVisible && afterRight.damage.isSome do
    throw <| IO.userError "right-click press must clear focusVisible"
  for tid in ([1, 701, 604] : List EntityId) do
    let rtIn : Runtime.RuntimeState Unit := { app := (), focus := { owner := some tid }, focusableOrder := [tid] }
    unless (match rtIn.effectiveEvent (.key 0xff0d 0 .pressed) with | .composerReturn false => true | _ => false) do
      throw <| IO.userError s!"effectiveEvent Return mismatch on text input {tid}"
    unless (match rtIn.effectiveEvent (.key 0x20 0 .pressed) with | .key 0x20 0 .pressed => true | _ => false) do
      throw <| IO.userError s!"effectiveEvent Space mismatch on text input {tid}"

  -- 3. Scrollbar geometry, thumb drag, track jump, clamping [0, limitY], and Orb.Scroll unpinning across viewports.
  let bounds : Rect := { x := pxToSub 220, y := pxToSub 35, w := pxToSub 1250, h := pxToSub 461 }
  let lim : SubPx := pxToSub 900
  let some g := scrollbarGeometry bounds lim lim | throw <| IO.userError "scrollbarGeometry returned none for limitY > 0"
  let gx := g.trackRectSub.x + g.trackRectSub.w / 2
  let mut rosterSt : DesktopState := { DesktopState.liveUnavailable with connectionBinding := "u6", rosterTopSub := 0 }
  let (rosterMoved, rosterDmg) := applyScrollRegionTo 120 rosterViewportId bounds lim 0 (pxToSub 9999) rosterSt
  unless rosterMoved.rosterTopSub == lim && rosterDmg.isSome do
    throw <| IO.userError "applyScrollRegionTo did not clamp rosterViewportId to limitY"
  let fleetSt : DesktopState := { DesktopState.liveUnavailable with screen := .machinesFleet, connectionBinding := "u6", fleetTopSub := 0 }
  let (fleetMoved, _) := applyScrollRegionTo 120 fleetViewportId bounds lim 0 (pxToSub 320) fleetSt
  unless fleetMoved.fleetTopSub == pxToSub 320 do
    throw <| IO.userError "applyScrollRegionTo failed on fleetViewportId"
  let compSt : DesktopState := { DesktopState.liveUnavailable with connectionBinding := "u6" }
  let (compMoved, _) := applyScrollRegionTo 120 Widgets.composerViewportId bounds lim 0 (pxToSub 150) compSt
  unless compMoved.composer.wheelTop == some (pxToSub 150) do
    throw <| IO.userError "applyScrollRegionTo failed on composerViewportId"
  -- Transcript drag upward unpins Orb.Scroll and track jump starts continuous drag.
  let txSt : DesktopState := {
    DesktopState.liveUnavailable with
    screen := .missionTranscript
    connectionBinding := "u6"
    openMission := some "m1"
    scroll := { pinned := true, topSub := lim }
  }
  let region : Runtime.ScrollRegion := { id := transcriptViewportId, bounds, limitY := lim, offsetY := lim }
  let reduce (st : DesktopState) (ev : Event) :=
    match ev with
    | .scrollTo rid off => applyScrollRegionTo 120 rid region.bounds region.limitY region.offsetY off st
    | _ => (st, none)
  let rt : Runtime.RuntimeState DesktopState := { app := txSt, scrollRegions := [region] }
  let jumped := rt.stepEvent reduce (.pointerButton gx (bounds.y + pxToSub 40) 0x110 true)
  unless jumped.activeScrollbarDrag.isSome && !jumped.app.scroll.pinned && jumped.app.scroll.topSub < lim / 2 do
    throw <| IO.userError s!"track jump did not unpin transcript: {repr jumped.app.scroll}"
  let heldDown := jumped.stepEvent reduce (.pointerMove gx (bounds.bottom + pxToSub 100))
  unless heldDown.app.scroll.topSub == lim && heldDown.app.scroll.pinned do
    throw <| IO.userError s!"drag-to-bottom after track jump did not re-pin: {repr heldDown.app.scroll}"
  let done := heldDown.stepEvent reduce (.pointerButton gx bounds.bottom 0x110 false)
  unless done.activeScrollbarDrag.isNone do
    throw <| IO.userError "pointer release did not finish scrollbar drag"
  -- Stationary thumb press / horizontal jitter at lim - 10px (< nearBottomSub) leaves pinned == false and topSub unchanged.
  let nearOff := lim - pxToSub 10
  let unpinnedNear : ScrollPolicyState := { pinned := false, topSub := nearOff }
  let afterZero := unpinnedNear.onUserScrollTo (lim + bounds.h.toNat) bounds.h.toNat nearOff
  unless !afterZero.pinned && afterZero.topSub == nearOff do
    throw <| IO.userError s!"stationary onUserScrollTo at lim-10px re-pinned: {repr afterZero}"
  -- Modal-open trap change cancels active scrollbar drag and pressedEntity; limitY growth refreshes drag.geom.
  let searchOpened := (stepDesktopEvent 120 vpDev jumped.app (.key 0x6b 2 .pressed)).1
  let cancelled := ({ jumped with app := searchOpened, pressedEntity := some 101 }).applyFocusTraps (desktopFocusTraps searchOpened)
  unless cancelled.activeScrollbarDrag.isNone && cancelled.pressedEntity.isNone do
    throw <| IO.userError "opening modal during scrollbar drag did not clear activeScrollbarDrag and pressedEntity"
  let limGrown : SubPx := pxToSub 1800
  let grownReg : Runtime.ScrollRegion := { id := transcriptViewportId, bounds, limitY := limGrown, offsetY := jumped.app.scroll.topSub }
  let refreshed := Runtime.reconcileScrollbarDrag jumped.activeScrollbarDrag [grownReg]
  unless refreshed.any (fun d => d.geom.limitY == limGrown) do
    throw <| IO.userError s!"reconcileScrollbarDrag failed to update limitY to {limGrown}"
  let reduceGrown (st : DesktopState) (ev : Event) :=
    match ev with
    | .scrollTo rid off => applyScrollRegionTo 120 rid grownReg.bounds grownReg.limitY grownReg.offsetY off st
    | _ => (st, none)
  let rtGrown := { jumped with scrollRegions := [grownReg], activeScrollbarDrag := refreshed }
  let toNewBot := rtGrown.stepEvent reduceGrown (.pointerMove gx (bounds.bottom + pxToSub 100))
  unless toNewBot.app.scroll.topSub == limGrown && toNewBot.app.scroll.pinned do
    throw <| IO.userError s!"drag after limitY growth did not reach new limit {limGrown}: {repr toNewBot.app.scroll}"

  -- 4. Scroll event coalescing (matching coords + same-sign deltas + interleaved .time).
  let coalesced := Runtime.coalesceScrollEvents #[
    .time 1, .scroll 300 400 0 10, .time 2, .scroll 300 400 0 25,
    .time 3, .scroll 300 400 0 (-8), .scroll 300 400 0 0,
    .scroll 500 400 0 12]
  let expected : Array Event := #[
    .time 2, .scroll 300 400 0 35,
    .time 3, .scroll 300 400 0 (-8),
    .scroll 500 400 0 12]
  unless reprStr coalesced == reprStr expected do
    throw <| IO.userError s!"coalesceScrollEvents mismatch: {reprStr coalesced}"

private def verifyWaylandImeSerialGuard : IO Unit := do
  -- After switching text inputs (commit serial 1 -> disable 2 -> enable 3), a stale
  -- in-flight `done(1)` must be dropped so commits from the prior input cannot leak.
  let wl0 : Wayland.WaylandClient :=
    { imeEntered := true, imeEnabled := true, imeCommitSerial := 3, imeEnableSerial := 3 }
  let (wl1, evs1) ← Wayland.stepWireEvent wl0
    { tag := Wayland.tagTextInput, proxy := 1, opcode := 3, args := #[.str (some "stale")] }
  unless evs1.isEmpty && wl1.ime.commit == "stale" do
    throw <| IO.userError "commit_string did not stage pending IME text"
  let (wl2, evs2) ← Wayland.stepWireEvent wl1
    { tag := Wayland.tagTextInput, proxy := 1, opcode := 5, args := #[.uint 1] }
  unless evs2.isEmpty && wl2.ime.commit.isEmpty do
    throw <| IO.userError s!"stale zwp_text_input_v3.done(1) leaked into new text input: {reprStr evs2}"
  -- Matching serial `done(3)` delivers the atomic `.imeBatch` normally.
  let (wl3, _) ← Wayland.stepWireEvent wl2
    { tag := Wayland.tagTextInput, proxy := 1, opcode := 3, args := #[.str (some "日本語")] }
  let (wl4, evs4) ← Wayland.stepWireEvent wl3
    { tag := Wayland.tagTextInput, proxy := 1, opcode := 5, args := #[.uint 3] }
  let expectedIme : Array Event := #[.imeBatch 0 0 "日本語" "" 0 0]
  unless reprStr evs4 == reprStr expectedIme && wl4.ime.commit.isEmpty do
    throw <| IO.userError s!"current zwp_text_input_v3.done(3) did not emit expected imeBatch: {reprStr evs4}"

  -- Logical IME session keys must change across same-EntityId (1) composer switches:
  -- New Agent -> Create/Mission -> Ctrl+N -> Rename -> close Rename, and Send reset.
  let baseDraft : DesktopState := {
    DesktopState.forScreen .controlEmpty true 120 with
    liveData := true, connectionBinding := "u6a", screen := .controlEmpty, openMission := none
  }
  let kDraft := desktopImeSessionKey baseDraft
  let card1 : MissionSummaryCard := { (default : MissionSummaryCard) with widgetId := 2001, missionId := "m-u6a", title := "Indigo" }
  let afterCreate := resetSelection { baseDraft with screen := .missionTranscript } (some card1)
  let kMission := desktopImeSessionKey afterCreate
  unless kMission != kDraft do
    throw <| IO.userError "desktopImeSessionKey did not change across New Agent -> Mission Create"
  let afterSend := { afterCreate with imeResetGen := afterCreate.imeResetGen + 1 }
  unless desktopImeSessionKey afterSend != kMission do
    throw <| IO.userError "desktopImeSessionKey did not change after Send reset"
  let afterCtrlN := (stepDesktopEvent 120 vpDev afterCreate (.key 0x6e 2 .pressed)).1
  unless desktopImeSessionKey afterCtrlN != kMission do
    throw <| IO.userError "desktopImeSessionKey did not change on Ctrl+N"
  let withRename : DesktopState := {
    afterCreate with
    missionMenu := some { mission := "m-u6a", x := 100, y := 100, trigger := 1, page := .rename }
  }
  let kRename := desktopImeSessionKey withRename
  unless kRename != kMission do
    throw <| IO.userError "desktopImeSessionKey did not change when opening inline Rename (id=1)"
  let afterEscRename := (stepDesktopEvent 120 vpDev withRename (.key 0xff1b 0 .pressed)).1
  unless desktopImeSessionKey afterEscRename != kRename do
    throw <| IO.userError "desktopImeSessionKey did not change when closing inline Rename back to trigger 1"

  -- Mid-batch focus switch (Ctrl+K opening Search 701 + trailing .imeBatch in same pumpEvents batch)
  -- must drop the trailing IME commit instead of leaking it into Search query.
  let rt0 : Runtime.RuntimeState DesktopState := {
    app := baseDraft
    focus := { owner := some 1 }
    lastImeOwner := some 1
    lastImeContext := desktopImeSessionKey baseDraft
  }
  let rtBatch := Runtime.applyEventBatch rt0
    #[.key 0x6b 2 .pressed, .imeBatch 0 0 "LEAK_TO_SEARCH" "" 0 0]
    (fun _ st ev => stepDesktopEvent 120 vpDev st ev) desktopFocusChange desktopFocusTraps desktopImeSessionKey
  match rtBatch.app.modal with
  | .searchPalette spec =>
    unless spec.query.isEmpty do
      throw <| IO.userError s!"mid-batch IME leaked into Search palette after Ctrl+K: {spec.query}"
  | _ => throw <| IO.userError "Ctrl+K did not open searchPalette in applyEventBatch test"

  -- Poll-frame logical IME context switch (e.g. Create/Send completing before syncTextFocus)
  -- must also drop an in-flight .imeBatch sitting in the socket for that tick.
  let rtPostCreate : Runtime.RuntimeState DesktopState := {
    app := afterCreate
    focus := { owner := some 1 }
    lastImeOwner := some 1
    lastImeContext := kDraft
  }
  let rtPolled := Runtime.applyEventBatch rtPostCreate
    #[.imeBatch 0 0 "PRE_CREATE_LEAK" "" 0 0]
    (fun _ st ev => stepDesktopEvent 120 vpDev st ev) desktopFocusChange desktopFocusTraps desktopImeSessionKey
  unless rtPolled.app.composer.text.isEmpty do
    throw <| IO.userError s!"in-flight IME leaked across pollFrame context switch: {rtPolled.app.composer.text}"

  -- Draft directory Return must not commit while IME preedit is active or path is non-absolute.
  let dirStPreedit : DesktopState := {
    baseDraft with
    missionMenu := some {
      mission := "", x := 400, y := 400, trigger := draftDirectoryPickerId, page := .draftDirectory,
      draft := { text := "/tmp", cursorOffset := 4, imePreeditText := "にほん" }
    }
  }
  let (dirAfterPreedit, _) := stepDesktopEvent 120 vpDev dirStPreedit (.composerReturn false)
  unless dirAfterPreedit.missionMenu.isSome && dirAfterPreedit.draftDirectory.isEmpty do
    throw <| IO.userError "draftDirectory Return committed while IME preedit was active"
  let dirStRelative : DesktopState := {
    baseDraft with
    missionMenu := some {
      mission := "", x := 400, y := 400, trigger := draftDirectoryPickerId, page := .draftDirectory,
      draft := { text := "relative/path", cursorOffset := 13 }
    }
  }
  let (dirAfterRel, _) := stepDesktopEvent 120 vpDev dirStRelative (.composerReturn false)
  unless dirAfterRel.missionMenu.isSome && dirAfterRel.draftDirectory.isEmpty do
    throw <| IO.userError "draftDirectory Return accepted a non-absolute path"
  let dirStValid : DesktopState := {
    baseDraft with
    missionMenu := some {
      mission := "", x := 400, y := 400, trigger := draftDirectoryPickerId, page := .draftDirectory,
      draft := { text := "/tmp/u6a", cursorOffset := 8 }
    }
  }
  let (dirAfterValid, _) := stepDesktopEvent 120 vpDev dirStValid (.composerReturn false)
  unless dirAfterValid.missionMenu.isNone && dirAfterValid.draftDirectory == "/tmp/u6a" do
    throw <| IO.userError s!"draftDirectory Return did not commit valid absolute path: {repr dirAfterValid.draftDirectory}"

  -- Preedit cancellation & IME session-cycling regressions (Finding 3):
  -- 1. Ctrl+K from cloudDraft / settingsApiUrl clears active preedit while preserving committed text.
  let cloudPreedit : DesktopState := {
    baseDraft with
    screen := .cloud, cloudMission := "cm1", cloudActions := ["send"],
    cloudDraft := { text := "cloud committed", cursorOffset := 15, imePreeditText := "未確定" }
  }
  let (cloudAfterK, _) := stepDesktopEvent 120 vpDev cloudPreedit (.key 0x6b 2 .pressed)
  unless cloudAfterK.cloudDraft.text == "cloud committed" && cloudAfterK.cloudDraft.imePreeditText.isEmpty do
    throw <| IO.userError "Ctrl+K from cloudDraft did not cancel preedit while preserving committed text"

  -- 2. Live nav shortcut (Ctrl+3) + Back (Ctrl+[) from cloudDraft cancels cloudDraft preedit.
  let (cloudNav3, _) := stepDesktopEvent 120 vpDev cloudPreedit (.key 0x33 2 .pressed)
  let (cloudBack, _) := stepDesktopEvent 120 vpDev cloudNav3 (.key 0x5b 2 .pressed)
  unless cloudNav3.cloudDraft.imePreeditText.isEmpty && cloudBack.cloudDraft.imePreeditText.isEmpty do
    throw <| IO.userError "nav shortcut from cloudDraft left zombie imePreeditText"

  -- 3. Fixture Ctrl+K from settingsApiUrl, Ctrl+N / Ctrl+3 from composer, and Search Clear / fixture Send.
  let settingsPreedit : DesktopState := {
    DesktopState.forScreen .settingsGeneral true 120 with
    settingsApiUrl := { text := "http://127.0.0.1:14470", cursorOffset := 22, imePreeditText := "組" }
  }
  let (settingsAfterK, _) := stepDesktopEvent 120 vpDev settingsPreedit (.key 0x6b 2 .pressed)
  unless settingsAfterK.settingsApiUrl.text == "http://127.0.0.1:14470" && settingsAfterK.settingsApiUrl.imePreeditText.isEmpty do
    throw <| IO.userError "Ctrl+K from settingsApiUrl left zombie preedit"

  let fixComposerPreedit : DesktopState := {
    DesktopState.forScreen .controlPopulated true 120 with
    composer := { text := "draft", cursorOffset := 5, imePreeditText := "かな" }
  }
  let (fixCtrlN, _) := stepDesktopEvent 120 vpDev fixComposerPreedit (.key 0x6e 2 .pressed)
  let (fixCtrl3, _) := stepDesktopEvent 120 vpDev fixComposerPreedit (.key 0x33 2 .pressed)
  unless fixCtrlN.composer.text == "draft" && fixCtrlN.composer.imePreeditText.isEmpty &&
      fixCtrl3.composer.text == "draft" && fixCtrl3.composer.imePreeditText.isEmpty do
    throw <| IO.userError "fixture Ctrl+N / Ctrl+3 did not clear composer preedit"

  let kFixPreSend := desktopImeSessionKey { fixComposerPreedit with composer := { text := "send me", cursorOffset := 7 } }
  let (fixSent, _) := stepDesktopEvent 120 vpDev { fixComposerPreedit with composer := { text := "send me", cursorOffset := 7 } } (.activate 2)
  unless fixSent.messageSent && desktopImeSessionKey fixSent != kFixPreSend do
    throw <| IO.userError "fixture Send did not advance desktopImeSessionKey"

  let searchOpenSt := (stepDesktopEvent 120 vpDev fixComposerPreedit (.key 0x6b 2 .pressed)).1
  let kSearchPreClear := desktopImeSessionKey searchOpenSt
  let (searchCleared, _) := stepDesktopEvent 120 vpDev searchOpenSt (.activate searchClearId)
  unless desktopImeSessionKey searchCleared != kSearchPreClear do
    throw <| IO.userError "Search Clear (706) did not advance desktopImeSessionKey"

  -- 4. applyEventBatch with clearAllPreeditChecked cancels preedit on focus/context switch even when
  --    a non-text menu opens and drops .preedit events (e.g. right-click sidebar mission row).
  let menuOpenPreedit : DesktopState := {
    afterCreate with
    composer := { text := "keep me", cursorOffset := 7, imePreeditText := "未確定" }
  }
  let openActionsMenu := fun (_ : Runtime.RuntimeState DesktopState) (st : DesktopState) (_ : Event) =>
    ({ st with missionMenu := some { mission := "m-u6a", x := 100, y := 300, trigger := 2001, page := .actions } }, some vpDev)
  let rtMenu : Runtime.RuntimeState DesktopState := {
    app := menuOpenPreedit, focus := { owner := some 1 },
    lastImeOwner := some 1, lastImeContext := desktopImeSessionKey menuOpenPreedit
  }
  let rtAfterMenu := Runtime.applyEventBatch rtMenu #[.pointerButton 100 300 0x111 true]
    openActionsMenu desktopFocusChange desktopFocusTraps desktopImeSessionKey DesktopState.clearAllPreeditChecked
  unless rtAfterMenu.app.composer.text == "keep me" && rtAfterMenu.app.composer.imePreeditText.isEmpty do
    throw <| IO.userError "opening context menu left zombie composer preedit in applyEventBatch"

def main : IO UInt32 := do
  verifyOrbScrollEquivalence
  verifyNineScreenControls
  verifyInteractionRegressions
  verifyScrollbarQuietFocusAndCaret
  verifyWaylandImeSerialGuard
  IO.println "InputU6Sweep: all 9 screens, live panels, Inference VPN/routing, Orb.Scroll, caret, scrollbar drag, quiet focus, IME serial guard, and regression checks passed"
  return 0
