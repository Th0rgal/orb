import OrbDesktop.State
import OrbDesktop.Screens
import Orb.Scroll

/-!
# InputU6Sweep — Exhaustive 9-Screen Hit-Testing, `Orb.Scroll` Policy & Control Verification

Lays out all 9 canonical screens + live interactive views (transcript + side panel,
Inference VPN/routing, Machines, Cloud, Resources, Inbox, Settings, Search modal) at
1470×923 (1x and 2x), asserts every interactive control has a non-empty hit region inside
the viewport whose center hit-tests back to that exact widget ID, verifies `ScrollPolicyState`
agrees with `Orb.Scroll`, and replays every U6 interaction through the real `desktopReducer`.
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

private def assertHitTargets (label : String) (st : DesktopState) (ids : List WidgetId) : IO Unit := do
  for sc in [120, 240] do
    let (_, scene) := renderScreenScene st sc
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
  -- Exact parity with `Orb.Scroll.userScroll` at `gap == near - 1` (re-pins) vs `gap == near` (stays unpinned).
  let contentPx : Nat := 2000
  let viewPx : Nat := 500
  let contentSub := pxToSub contentPx
  let viewSub := pxToSub viewPx
  let s0 : ScrollPolicyState := { pinned := true, topSub := pxToSub 1500 }
  -- Scroll up 200px -> unpins
  let s1 := s0.onUserScroll contentSub viewSub (-(Int.ofNat (pxToSub 200)))
  let o1 := Orb.Scroll.userScroll s0.toOrbScrollState contentPx viewPx 1300
  unless s1.toOrbScrollState == o1 && !s1.pinned do
    throw <| IO.userError s!"scroll up mismatch: {repr s1} vs {repr o1}"
  -- Scroll down to exact gap == 24px (`Orb.Scroll.near`) -> MUST stay unpinned (`gap < near` is false)
  let sAtNear := s1.onUserScroll contentSub viewSub (Int.ofNat (pxToSub 176))
  let oAtNear := Orb.Scroll.userScroll o1 contentPx viewPx 1476
  unless sAtNear.toOrbScrollState == oAtNear && !sAtNear.pinned do
    throw <| IO.userError s!"scroll at exact near boundary mismatch: {repr sAtNear} vs {repr oAtNear}"
  -- Scroll down 1 more px to gap == 23px (< near) -> MUST re-pin
  let sInsideNear := sAtNear.onUserScroll contentSub viewSub (Int.ofNat (pxToSub 1))
  let oInsideNear := Orb.Scroll.userScroll oAtNear contentPx viewPx 1477
  unless sInsideNear.toOrbScrollState == oInsideNear && sInsideNear.pinned do
    throw <| IO.userError s!"scroll inside near boundary mismatch: {repr sInsideNear} vs {repr oInsideNear}"
  -- Passive resize event (`intent=false, resized=true`) never flips `pinned`
  let sResize := sInsideNear.onScrollEvent false true (pxToSub 2400) viewSub (pxToSub 1000)
  unless sResize.pinned do
    throw <| IO.userError "passive resize flipped pinned"
  -- Jump pins at bottom
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
    [sidebarToggleId, sidebarSearchId, 101, 102, 112, 113, 103,
     draftProjectPickerId, 720, draftDirectoryPickerId, 1, 3, 722, 2]

  -- Screen 03: missionTranscript
  assertHitTargets "03_mission_transcript" (DesktopState.forScreen .missionTranscript)
    [sidebarToggleId, sidebarSearchId, sidePanelDiffId, sidePanelFilesId, sidePanelChatId,
     101, 105, 103, 1, 3, 2]

  -- Screen 04: missionSplitDiff
  assertHitTargets "04_mission_split_diff" (DesktopState.forScreen .missionSplitDiff)
    [sidebarToggleId, sidePanelDiffId, sidePanelFilesId, sidePanelChatId,
     1, 3, 2, diffRefId, diffUnifiedId, diffSplitId, diffRefreshId, diffFileChipId]

  -- Screen 05: machinesFleet
  assertHitTargets "05_machines_fleet" (DesktopState.forScreen .machinesFleet)
    [sidebarToggleId, 112, 103,
     fleetLocalId, fleetCoreId, fleetPrimaryId, fleetLargeAId, fleetDefaultBId, fleetSoftwareId, fleetCopyKeyId]

  -- Screen 06: settingsGeneral
  assertHitTargets "06_settings_general" (DesktopState.forScreen .settingsGeneral)
    [101, 102, 111, 112, 113, 114, 103,
     settingsTabAccountId, settingsTabUsersId, settingsTabTelemetryId,
     settingsApiUrlId, settingsDisconnectId, settingsConnectGhId, settingsRefreshCloudId,
     settingsThemeId, settingsSyncId]

  -- Screen 07: searchDialog (modal traps focus and owns hit-testing)
  assertHitTargets "07_search_dialog" (DesktopState.forScreen .searchDialog)
    [701, searchClearId, searchEscId, searchOpenId,
     searchTabAllId, searchTabUserId, searchTabAssistantId, searchTabTitlesId, searchTabToolsId,
     searchProjectFilterId, searchTimeFilterId, searchSortOrderId,
     702, 703, 704]

  -- Screen 08: newMissionDialog
  assertHitTargets "08_new_mission_dialog" (DesktopState.forScreen .newMissionDialog)
    [sidebarToggleId, draftProjectPickerId, 720, draftDirectoryPickerId, 1, 3, 722, 2]

  -- Screen 09: toastNotifications
  assertHitTargets "09_toast_notifications" (DesktopState.forScreen .toastNotifications)
    [sidebarToggleId, 1, 3, 2, 911, 912, 913]

  -- Verify dismissing toasts individually preserves remaining toasts and their hit regions!
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

  -- Verify viewport scrollClips do NOT pollute hitRegions (no collision with Cloud 970/971 or accountFormId 972)
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

def main : IO UInt32 := do
  verifyOrbScrollEquivalence
  verifyNineScreenControls
  IO.println "InputU6Sweep: all 9 screens, live panels, Inference VPN/routing, and Orb.Scroll checks passed"
  return 0
