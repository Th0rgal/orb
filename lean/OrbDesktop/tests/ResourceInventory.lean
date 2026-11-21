import OrbDesktop.Core
import OrbDesktop.Screens

open OrbDesktop LeanUI

private def step (st : DesktopState) (ev : Event) : DesktopState :=
  (stepDesktopEvent 120 ⟨0, 0, 900, 600⟩ st ev).1

private def settled (readState : DesktopState → IO (Option DesktopState))
    (st : DesktopState) : IO DesktopState := do
  for _ in [:500] do
    if let some ready ← readState st then return ready
    IO.sleep 10
  throw (IO.userError "fixture read timed out")

def main (args : List String) : IO Unit := do
  for dark in [false, true] do
    withLiveSources dark (pure ()) fun readState => do
      let boot ← settled readState { DesktopState.liveUnavailable dark 120 with initialRosterPending := true }
      let page := step boot (.key 0x36 8 .pressed)
      unless (step boot (.activate 114)).screen == .resources && page.screen == .resources &&
          page.sidebarRows.any (fun r => r.rowId == "nav:resources" && r.selected) &&
          desktopFocusChange boot page (.activate 114) == some 114 do
        throw (IO.userError "Resources navigation")
      let ready ← settled readState page
      let shorter := step ready (.activate 955)
      unless shorter.resourceRange == "30m" && shorter.resourceRows.isNone do throw (IO.userError "range change")
      let changed ← settled readState shorter
      unless changed.resourceRows == ready.resourceRows && changed.resourceFailed == ready.resourceFailed do
        throw (IO.userError "range read")
      if args == ["failed"] then
        unless ready.resourceFailed && ready.resourceRows.isNone && !(step ready (.activate 945)).resourceFailed do
          throw (IO.userError "failure and retry")
        return
      if args == ["empty"] then
        unless ready.resourceRows == some [] && !ready.resourceFailed do throw (IO.userError "empty overview")
        return
      unless ready.resourceRows == some [
          ⟨"", "Inference · Pool", "0 B tok/h · $0/h"⟩,
          ⟨"", "Compute · Node", "2/8 vCPU · $1.5/h"⟩,
          ⟨"a", "Mission · A", "active · 2 vCPU · 0.5 B tok/h"⟩,
          ⟨"b", "Mission · B", "active · 2 vCPU · 0.5 B tok/h"⟩,
          ⟨"c", "Mission · C", "active · 2 vCPU · 0.5 B tok/h"⟩] do
        throw (IO.userError "wrong resource projection")
      let next := step ready (.key 0xff56 0 .pressed)
      let w := pxToSub 900
      let h := pxToSub 600
      let (_, scene) := renderWidgetTree 120 w h next.initialFocusState next.theme (buildDesktopScreen next w h)
      unless [114, 945, 946, 947, 950, 955, 956, 957, 958, 959].all scene.focusableOrder.contains &&
          desktopFocusChange ready next (.key 0xff56 0 .pressed) == some 947 &&
          (step next (.activate 946)).resourcePage == 0 &&
          (step next (.composerReturn false)).writeRequest.isNone do
        throw (IO.userError "resource controls")
      let mission := step next (.activate 950)
      unless mission.screen == .missionTranscript && mission.openMission == some "c" && mission.writeRequest.isNone do
        throw (IO.userError "mission navigation")
