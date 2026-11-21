import OrbDesktop.State
import Std.Sync.Mutex

namespace OrbDesktop

private def adapter : String := include_str "voice_capture.py"

private def catalog : String := include_str "../../../orb/src/voiceLanguages.json"

structure VoiceCapability where
  language : String := ""
  picker : Bool := false
  deriving Inhabited

def probeVoice : IO VoiceCapability := do
  try
    let r ← IO.Process.output { cmd := "python3", args := #["-I", "-c", adapter, "probe", catalog] }
    if r.exitCode == 0 then
      if let [language, picker] := r.stdout.trimAscii.toString.splitOn "\t" then
        return { language, picker := picker == "picker" }
    return {}
  catch _ => return {}

structure VoiceSession where
  binding : String
  generation : Nat
  finish : IO Unit
  stop : IO Unit
  result : IO (Option (Option String))
  finishing : Bool := false

private def startVoice (st : DesktopState) (notify : IO Unit) : IO VoiceSession := do
  let mode := if st.voicePhase == .choosing then "choose" else "record"
  let child ← IO.Process.spawn {
    cmd := "python3", args := #["-I", "-c", adapter, mode, catalog, st.voiceLanguage],
    stdin := .piped, stdout := .piped, stderr := .null, setsid := true }
  let mailbox ← Std.Mutex.new (none : Option (Option String))
  let reader ← IO.asTask (prio := .dedicated) do
    let result ← try
      let out ← child.stdout.readToEnd
      let status ← child.wait
      pure (if status == 0 && !out.isEmpty then some out else none)
    catch _ => pure none
    mailbox.atomically (set (some result))
    notify
  return {
    binding := st.connectionBinding, generation := st.voiceGeneration,
    result := mailbox.atomically get, finish := do
      child.stdin.putStr "F"
      child.stdin.flush
    stop := do
      try child.kill catch _ => pure ()
      discard (IO.wait reader) }

def closeVoice (slot : IO.Ref (Option VoiceSession)) : IO Unit := do
  if let some s ← slot.swap none then s.stop

def pollVoice (slot : IO.Ref (Option VoiceSession)) (capability : IO.Ref VoiceCapability)
    (state : DesktopState) (notify : IO Unit) : IO DesktopState := do
  let cap ← capability.get
  let available := !cap.language.isEmpty
  let st := { state with voiceAvailable := available, voiceLanguage := cap.language, voicePicker := cap.picker }
  let active ← slot.get
  if let some s := active then
    if !st.voiceDraft || st.voicePhase == .idle || s.generation != st.voiceGeneration ||
        s.binding != st.connectionBinding then
      closeVoice slot
    else
      if let some result ← s.result then
        slot.set none
        if st.voicePhase == .choosing then
          if let some output := result then
            let language := output.trimAscii.toString
            capability.set { cap with language }
            return { st with voicePhase := .idle, voiceLanguage := language }
          return { st with voicePhase := .idle, writeError := "Could not select dictation language." }
        return { st with
          voicePhase := .idle, composer := st.composer.insertText (result.getD ""),
          writeError := if result.isNone then "Dictation failed. Try again." else st.writeError }
      if st.voicePhase == .finishing && !s.finishing then
        try s.finish catch _ => pure ()
        slot.set (some { s with finishing := true })
      return st
  if available && st.voiceDraft && st.voiceBinding == st.connectionBinding && (st.voicePhase == .recording || st.voicePhase == .choosing) then
    try
      slot.set (some (← startVoice st notify))
      return st
    catch _ => return { st with voicePhase := .idle, writeError := "Could not start dictation." }
  return { st with voicePhase := .idle }

end OrbDesktop
