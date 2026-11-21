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

-- The input method counts UTF-8 bytes on each side of a character-indexed caret.
private def imeDraft : DesktopState :=
  { base with composer := { base.composer with text := "a你🙂z", cursorOffset := 2 } }
private def replaced := (step imeDraft (.imeBatch 3 4 "é" "" 0 0)).composer
#guard replaced.text == "aéz" && replaced.cursorOffset == 2
#guard (step imeDraft (.imeBatch 2 3 "" "" 0 0)).composer.text == "a你🙂z"

private def menuState : DesktopState :=
  { base with liveData := true, connectionBinding := "local-test", openMission := some "a",
    missionCards := [{ (default : MissionSummaryCard) with widgetId := 1001, missionId := "a" },
                     { (default : MissionSummaryCard) with widgetId := 1004, missionId := "b" }],
    missionMenu := some { mission := "b", x := 20, y := 40 } }

#guard (step menuState (.activate 712)).writeRequest == some (.archive "b")
#guard (step menuState (.activate 712)).openMission == some "a"
#guard (step menuState (.key 0xff1b 0 .pressed)).missionMenu.isNone

private def group : DesktopState :=
  { menuState with multiRows := ["mission:a", "mission:c"], selectionAnchor := some "mission:a" }

#guard (contextSelection group "mission:a").multiRows == group.multiRows
#guard (contextSelection group "mission:b").multiRows.isEmpty
#guard (contextSelection group "mission:b").selectionAnchor.isNone
#guard (contextSelection group "mission:b").openMission == some "a"

private def refused := { menuState with missionMenu := none, writeError := "Stop or finish this agent before archiving it." }
#guard refused.headerTitle == menuState.headerTitle
#guard (step refused (.activate 914)).writeError.isEmpty
#guard (step refused (.activate 914)).openMission == some "a"

end OrbDesktop.Spec
