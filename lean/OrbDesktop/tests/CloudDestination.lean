import OrbDesktop.Core
import OrbDesktop.Screens
import LeanUI.Runtime

open OrbDesktop LeanUI

private def viewport : Rect := ⟨0, 0, 900, 600⟩
private def reduce := stepDesktopEvent 120 viewport
private def step (st : DesktopState) (ev : Event) := (reduce st ev).1

private def settled (readState : DesktopState → IO (Option DesktopState)) (st : DesktopState) : IO DesktopState := do
  for _ in [:500] do
    if let some ready ← readState st then return ready
    IO.sleep 10
  throw (IO.userError "Cloud read timed out")

private partial def labels (n : WidgetNode) : List String :=
  let own := match n.payloadOf with
    | .text _ runs => [String.ofList ((runs.flatMap (·.glyphs)).map fun g => Char.ofNat g.glyphId)]
    | _ => []
  own ++ n.childrenOf.flatMap labels

private def view (st : DesktopState) : List String × SceneOutput :=
  let w := pxToSub 900
  let h := pxToSub 600
  let root := buildDesktopScreen st w h {} true
  (labels root, (renderWidgetTree 120 w h st.initialFocusState st.theme root).2)

private def verify (st : DesktopState) (words : List String) (ids : List Nat) : IO Unit := do
  let (texts, scene) := view st
  let relevant := scene.focusableOrder.filter fun id => id == 1 || id == 2 || id == 3 || (960 <= id && id < 972)
  unless words.all texts.contains && relevant == ids &&
      ids.all (fun id => scene.hitRegionsDev.any (fun (i,r) => i == id && r.w > 0 && r.h > 0)) do
    throw (IO.userError s!"Expected {words} / {ids}, projected {texts} / {relevant}")

private def enter (st : DesktopState) (id : Nat) := Id.run do
  let (_, scene) := view st
  let rt : Runtime.RuntimeState DesktopState := {
    app := st, focus := st.initialFocusState,
    focusableOrder := scene.focusableOrder }
  let mut rt := rt
  for _ in scene.focusableOrder do
    rt := rt.stepEvent reduce (.key 0xff09 0 .pressed)
    if rt.focus.owner == some id then return (rt.stepEvent reduce (.key 0xff0d 0 .pressed)).app
  return st

def main (args : List String) : IO Unit := do
  for dark in [false, true] do
    withLiveSources dark (pure ()) fun readState => do
      let boot ← settled readState { DesktopState.liveUnavailable dark 120 with initialRosterPending := true }
      let page := step boot (.key 0x32 8 .pressed)
      unless (enter boot 111).screen == .cloud && page.screen == .cloud &&
          page.visibleProjectRows.any (fun r => r.widgetId == 111 && r.selected) do
        throw (IO.userError "Cloud navigation")
      if args == ["empty"] then
        verify page ["Loading connected accounts…"] []
        let ready ← settled readState page
        verify ready ["No connected accounts"] [960]
        return
      verify page ["Loading connected accounts…", "Open · Cloud proof"] [964]
      let first ← settled readState page
      verify first ["Could not load connected accounts.", "Retry", "Open · Cloud proof"] [960,964]
      let ready ← settled readState (enter first 960)
      verify ready ["Cursor Cloud · Team · Available", "Grok Bot · Trial · Reconnect", "Open · Cloud proof", "Describe a task for your cloud agent"] [960,966,1]
      let slot ← IO.mkRef none
      let some card := ready.missionCards.find? (·.missionId == "proof") | throw (IO.userError "missing mission")
      unless (enter ready card.widgetId).cloudMission == "proof" do throw (IO.userError "sidebar conversation")
      let create := step ready (.text "Fixture task")
      verify create ["Create cloud agent", "Fixture task"] [960,966,1,968]
      let (created, _) ← readLiveFrame slot 120 viewport (enter create 968)
      unless created.cloudMission == "new-proof" && created.cloudDraft.text.isEmpty do throw (IO.userError "fixture launch")
      let detail := enter ready 966
      verify detail ["Cloud proof", "Loading conversation…"] [963]
      let denied ← settled readState { detail with connectionBinding := "unrelated fixture binding" }
      verify denied ["Could not load conversation.", "Retry"] [963,960]
      let active ← settled readState detail
      verify active ["You · Prove one plus one", "Agent · Two.", "Send follow-up", "Stop"] [963,960,1,969]
      let typed := step active (.text "why?")
      verify typed ["why?", "Send"] [963,960,1,968,969]
      let (unconfirmed, _) ← readLiveFrame slot 120 viewport (enter typed 1)
      unless unconfirmed.cloudDraft.text == "why?" && !unconfirmed.cloudAttempt.isEmpty && !unconfirmed.writeError.isEmpty do
        throw (IO.userError "failed follow-up lost retry identity or draft")
      let (sent, _) ← readLiveFrame slot 120 viewport (enter unconfirmed 968)
      unless sent.cloudDraft.text.isEmpty && sent.writeError.isEmpty do throw (IO.userError "send")
      let refreshed ← settled readState sent
      let (stopped, _) ← readLiveFrame slot 120 viewport (enter refreshed 969)
      let blocked ← settled readState stopped
      verify blocked ["Status · Reconnect account"] [963,960]
      unless (step blocked (.activate 969)).writeRequest.isNone && (step blocked (.composerReturn false)).writeRequest.isNone do
        throw (IO.userError "phantom action")
      let back := step blocked (.key 0xff1b 0 .pressed)
      unless back.cloudMission.isEmpty && back.screen == .cloud do throw (IO.userError "Back")
