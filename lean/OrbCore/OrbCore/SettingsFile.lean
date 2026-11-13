/- One owner for settings.json reads, locking and compare-and-set writes. -/
import OrbBin.PosixExt
import OrbBin.Json

namespace OrbCore.SettingsFile

open OrbBin.Json OrbBin.PosixExt

def path (root : String) : System.FilePath := System.FilePath.mk root / "settings.json"

def errorStatus (error : String) : Nat :=
  if error == "settings_busy" || error == "settings_changed" then 409 else 500

structure Snapshot where
  raw : Option String
  value : JVal

/-- Import must distinguish absent settings from unreadable or corrupt settings. -/
def read (root : String) : IO (Except String Snapshot) := do
  try
    if !(← (path root).pathExists) then return .ok ⟨none, .obj #[]⟩
    let raw ← IO.FS.readFile (path root)
    let .ok value@(.obj _) := OrbBin.Json.parse raw | return .error "settings_file_invalid"
    return .ok ⟨some raw, value⟩
  catch _ => return .error "settings_file_unreadable"

def withLock {α : Type} (root : String) (action : IO (Except String α)) : IO (Except String α) := do
  let fd ← flockExclusiveNb s!"{root}/.settings.lock"
  if fd ≥ 0xFFFFFFFE then return .error "settings_busy"
  try action finally closeFdRaw fd.toInt32

def writeUnlocked (root : String) (value : JVal) : IO (Except String Unit) := do
  try
    match ← writeAtomicPrivate0600 (path root) (renderPretty value ++ "\n").toUTF8 with
    | .ok () => return .ok ()
    | .error _ => return .error "settings_file_write_failed"
  catch _ => return .error "settings_file_write_failed"

def restoreUnlocked (root : String) (before : Snapshot) : IO (Except String Unit) := do
  try
    match before.raw with
    | some raw =>
      match ← writeAtomicPrivate0600 (path root) raw.toUTF8 with
      | .ok () => return .ok ()
      | .error _ => return .error "settings_file_restore_failed"
    | none =>
      if ← (path root).pathExists then IO.FS.removeFile (path root)
      return .ok ()
  catch _ => return .error "settings_file_restore_failed"

def write (root : String) (value : JVal) (expected? : Option JVal := none) : IO (Except String Unit) :=
  withLock root do
    let .ok current ← read root | return .error "settings_file_unavailable"
    if let some expected := expected? then
      if renderCompact current.value != renderCompact expected then return .error "settings_changed"
    writeUnlocked root value

end OrbCore.SettingsFile
