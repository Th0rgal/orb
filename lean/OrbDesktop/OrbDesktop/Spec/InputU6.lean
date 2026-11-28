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
#guard (step base (.activate 102)).screen == .inbox
#guard (step base (.activate 111)).screen == .cloud
#guard (step base (.activate sidePanelDiffId)).sidePanelOpen
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
  { base with
    liveData := true, connectionBinding := "local-test", openMission := some "a",
    missionCards := [{ (default : MissionSummaryCard) with widgetId := 1001, missionId := "a" },
                     { (default : MissionSummaryCard) with widgetId := 1004, missionId := "b" }],
    missionMenu := some { mission := "b", x := 20, y := 40 } }

#guard (step menuState (.activate 712)).writeRequest == some (.archive "b")
#guard (step menuState (.activate 712)).openMission == some "a"
#guard (step menuState (.key 0xff1b 0 .pressed)).missionMenu.isNone

-- Live typing, IME commits, Create, Send, Stop, Archive and focus/history invariants (U6a).
private def liveNewAgent : DesktopState :=
  { base with
    liveData := true, connectionBinding := "local-test", screen := .controlEmpty, openMission := none,
    composer := {} }
private def liveNewDraft :=
  step (step (step liveNewAgent (.text "Hello ")) (.preedit "にほん" 0 3)) (.imeBatch 0 0 "日本語" "" 0 0)
#guard liveNewDraft.composer.text == "Hello 日本語"
#guard liveNewDraft.composer.imePreeditText.isEmpty
#guard (step liveNewDraft (.composerReturn false)).writeRequest == some .create
#guard (step (step liveNewDraft (.preedit "未確定" 0 3)) (.composerReturn false)).writeRequest.isNone

private def liveOpenIdle : DesktopState :=
  { menuState with
    missionMenu := none, screen := .missionTranscript, composer := { isRunning := false } }
private def liveFollowup :=
  step (step liveOpenIdle (.text "Ping ")) (.imeBatch 0 0 "漢字 🚀" "" 0 0)
#guard (step liveFollowup (.composerReturn false)).writeRequest == some (.send "a" "Ping 漢字 🚀")
#guard (step (step liveOpenIdle (.text "   \n")) (.composerReturn false)).writeRequest.isNone
#guard (step liveOpenIdle (.activate 106)).writeRequest == some (.archive "a")

private def liveOpenRunning : DesktopState :=
  { liveOpenIdle with composer := { isRunning := true } }
#guard (step liveOpenRunning (.activate 2)).writeRequest == some (.stop "a")
#guard (step liveOpenRunning (.activate 106)).writeRequest.isNone
#guard (step liveOpenRunning (.composerReturn false)).writeRequest.isNone

private def liveUnconfirmedRunning : DesktopState :=
  { liveOpenRunning with
    composer := { text := "retry me", cursorOffset := 8, isRunning := true },
    unconfirmedSend := some ("uuid-1", "retry me") }
#guard (step liveUnconfirmedRunning (.activate 2)).writeRequest == some (.send "a" "retry me")
#guard (step liveUnconfirmedRunning (.composerReturn false)).writeRequest == some (.send "a" "retry me")

-- Initial live connect and New Agent activation focus the composer so IME activates immediately.
private def liveConnecting : DesktopState :=
  { DesktopState.liveUnavailable with initialRosterPending := true }
#guard desktopFocusChange liveConnecting liveNewAgent (.time 0) == some 1
#guard desktopFocusChange liveConnecting { liveNewAgent with screen := .controlPopulated } (.time 0) == some 1
#guard desktopFocusChange liveNewAgent liveNewAgent (.activate 101) == some 1

-- Advancing persisted history during Send/recovery clears stale stream text so an empty
-- turn-boundary bubble frame never duplicates the previous assistant turn.
private def liveBeforeSend : DesktopState :=
  { liveOpenIdle with
    liveTurns := ["You: Turn 1"], liveTurnIds := ["id:1"], livePersistedCount := 1,
    stream := { shown := ["Answer 1"], pending := [], renders := 2 } }
private def liveAfterHistory :=
  (applyHistoryBatch 120 viewport liveBeforeSend "a"
    { turns := [("id:1", "You: Turn 1"), ("id:2", "Answer 1"), ("id:3", "You: Follow-up")] }).1
#guard liveAfterHistory.liveTurns == ["You: Turn 1", "Answer 1", "You: Follow-up"]
#guard (streamedText liveAfterHistory).isEmpty
#guard (applyLiveText 120 viewport liveAfterHistory "a" "").1.liveTurns ==
  ["You: Turn 1", "Answer 1", "You: Follow-up"]

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
