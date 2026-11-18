import OrbDesktop.State
import OrbDesktop.Screens
/-!
# OrbDesktop.Spec.InputU6 — named U6 interaction replay

The native runtime supplies pointer hit-testing and activation; this pure replay
locks the reducer contract used by Wayland injection and keeps the browser parity
surface honest: mission creation, IME text, send, stop, archive, navigation and
side-panel toggles all mutate one `DesktopState` owner.
-/
namespace OrbDesktop.Spec

open LeanUI OrbDesktop

private def viewport : Rect := { x := 0, y := 0, w := 1470, h := 923 }
private def base : DesktopState := DesktopState.forScreen .missionTranscript
private def step (s : DesktopState) (e : Event) : DesktopState :=
  (stepDesktopEvent 120 viewport s e).1

#guard (step (step base (.text "hello")) (.activate 2)).messageSent
#guard !(step (step base (.text "hello")) (.activate 2)).missionStopped
#guard (step (step base (.text "hello")) (.activate 2)).composer.text == ""
#guard (step { base with composer := { base.composer with isRunning := true } } (.activate 2)).missionStopped
#guard (step base (.activate 106)).missionArchived
#guard (step base (.activate 111)).sidePanelOpen
#guard !(step base (.activate 805)).missionCreated
#guard (step { base with modal := defaultNewMissionModal } (.activate 805)).missionCreated
#guard (step { base with screen := .controlEmpty } (.activate 103)).screen == .settingsGeneral
#guard (step (step base (.preedit "ni" 0 2)) (.imeBatch 0 0 "你" "" 0 0)).composer.text == "你"

end OrbDesktop.Spec
