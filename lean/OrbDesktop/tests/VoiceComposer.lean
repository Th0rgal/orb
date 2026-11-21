import OrbDesktop.Voice
import OrbDesktop.Screens
import LeanUI.Runtime

open OrbDesktop LeanUI

private def draft : DesktopState := {
  DesktopState.liveUnavailable with
  connectionBinding := "fixture", voiceAvailable := true
  composer := { text := "A猫Z", cursorOffset := 2 } }

private def step (st : DesktopState) (event : Event) :=
  (stepDesktopEvent 120 { x := 0, y := 0, w := 800, h := 600 } st event).1

private def recording := step draft (.activate voiceButtonId)
private def finishing := step recording (.activate voiceButtonId)
#guard recording.voicePhase == .recording
#guard finishing.voicePhase == .finishing
#guard (step recording (.key 0xff1b 0 .pressed)).voicePhase == .idle
#guard (step finishing (.activate voiceButtonId)).voicePhase == .idle
#guard (step recording (.activate voiceCancelId)).voicePhase == .idle
#guard (step { draft with voiceAvailable := false } (.activate voiceButtonId)).voicePhase == .idle
#guard (step draft (.pointerMove 1 1)).voicePhase == .idle
#guard draft.hoverTarget (some voiceButtonId) == some voiceButtonId

private def deliver (st : DesktopState) : IO DesktopState := do
  let session : VoiceSession := {
    binding := "fixture", generation := recording.voiceGeneration
    stop := pure (), finish := pure (), result := pure (some (some "語")) }
  let slot ← IO.mkRef (some session)
  pollVoice slot true st (pure ())

def main : IO Unit := do
  let w := pxToSub 960
  let h := pxToSub 600
  let tree := buildDesktopScreen draft w h
  let (_, scene) := renderWidgetTree 120 w h draft.initialFocusState draft.theme tree
  let some (_, r) := scene.hitRegionsSub.find? (·.1 == voiceButtonId)
    | throw (IO.userError "rendered microphone has no hit region")
  let x := r.x + r.w / 2
  let y := r.y + r.h / 2
  let rt : Runtime.RuntimeState DesktopState := {
    app := draft, focus := draft.initialFocusState, focusableOrder := scene.focusableOrder
    hitRegions := scene.hitRegionsSub }
  let reduce := stepDesktopEvent 120 rt.viewportDeviceRect
  let down := rt.stepEvent reduce (.pointerButton x y 0x110 true)
  let up := down.stepEvent reduce (.pointerButton x y 0x110 false)
  unless scene.focusableOrder.contains voiceButtonId && down.focus.owner == some voiceButtonId &&
      down.app.voicePhase == .idle && up.app.voicePhase == .recording do
    throw (IO.userError "pointer focus or deliberate release failed")
  for key in [0xff0d, 0x20] do
    let pressed := down.stepEvent reduce (.key key 0 .pressed)
    let held := pressed.stepEvent reduce (.key key 0 .repeated)
    unless held.app.voicePhase == .recording && held.app.writeRequest.isNone do
      throw (IO.userError "keyboard activation or repeat guard failed")
  let inserted ← deliver finishing
  unless inserted.composer.text == "A猫語Z" && inserted.composer.cursorOffset == 3 &&
      inserted.composer.undo.text == draft.composer.text && inserted.writeRequest.isNone do
    throw (IO.userError "dictation must be a single editable insertion")
  for stale in [step recording (.key 0xff1b 0 .pressed), resetSelection finishing none,
                { finishing with connectionBinding := "other" }, { finishing with openMission := some "other" }] do
    let ignored ← deliver stale
    unless ignored.composer == stale.composer && ignored.writeRequest.isNone do
      throw (IO.userError "stale dictation edited a different draft")
