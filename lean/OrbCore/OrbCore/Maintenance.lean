/-
  OrbCore.Maintenance: periodic workspace retention, dispatch-reservation recovery
  and disk-pressure observation. Destructive retention is explicitly opt-in.
-/
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.SettingsFile
import OrbCore.Store

namespace OrbCore.Maintenance

open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store

def defaultRetentionDays : Nat := 1
def defaultStoppedRetentionDays : Nat := 7
def defaultGcIntervalMinutes : Nat := 60
def pressureIntervalSeconds : Nat := 300
def recoveryMarginPct : Nat := 3
def defaultAlertRepeatSeconds : Nat := 24 * 3600

structure GcSettings where
  enabled : Bool := false
  execute : Bool := false
  retentionDays : Nat := defaultRetentionDays
  stoppedRetentionDays : Nat := defaultStoppedRetentionDays
  orphansEnabled : Bool := false
  intervalSeconds : Nat := defaultGcIntervalMinutes * 60
  deriving Repr, DecidableEq, Inhabited

private def envNat (name : String) : IO (Option Nat) := do
  return ((← IO.getEnv name).map (fun raw => raw.trimAscii.toString)).bind String.toNat?

def gcExecutionEnabled : IO Bool := do
  let raw := ((← IO.getEnv "WORKSPACE_GC_EXECUTE").getD "").trimAscii.toString.toLower
  return raw == "1" || raw == "true"

private def boundedDays (value : Option Nat) (fallback : Nat) : Nat :=
  match value with
  | some n => if n >= 1 && n <= 3650 then n else fallback
  | none => fallback

/-- Read the historical settings keys from the Core settings owner. Missing,
    corrupt or unreadable settings fail closed to retention disabled. -/
def readGcSettings (settingsRoot : String) : IO GcSettings := do
  let execute ← gcExecutionEnabled
  let interval? ← envNat "WORKSPACE_GC_INTERVAL_MINUTES"
  let intervalMinutes :=
    match interval? with
    | some n => if n >= 1 && n <= 1440 then n else defaultGcIntervalMinutes
    | none => defaultGcIntervalMinutes
  match ← OrbCore.SettingsFile.read settingsRoot with
  | .error _ => return { execute := execute, intervalSeconds := intervalMinutes * 60 }
  | .ok snap =>
    let v := snap.value
    let enabled := (v.fieldBool? "auto_cleanup_enabled").getD false
    let days := boundedDays (v.fieldNat? "auto_cleanup_days") defaultRetentionDays
    let stoppedDays := boundedDays (v.fieldNat? "auto_cleanup_stopped_days") defaultStoppedRetentionDays
    let orphans := (v.fieldBool? "auto_cleanup_orphans_enabled").getD enabled
    return {
      enabled := enabled, execute := execute,
      retentionDays := days, stoppedRetentionDays := stoppedDays,
      orphansEnabled := orphans, intervalSeconds := intervalMinutes * 60
    }

/-- Only `not_feasible` is terminal enough to collect. Resumable
    failed/interrupted/blocked and replyable completed/acknowledged/awaiting_user/
    paused source must survive so resume never becomes config-only. -/
private def gcEligibleStatus (status : String) : Bool :=
  status == "not_feasible"

structure MissionRetentionRow where
  id : String
  status : String
  workingDirectory : String
  updatedAtEpoch : UInt64
  resumable : Bool
  deriving Repr, DecidableEq, Inhabited

private def epochOfColumn (raw : String) : UInt64 :=
  let t := raw.trimAscii.toString
  if t.isEmpty then 0
  else if t.toList.all (fun c => '0' ≤ c && c ≤ '9') then ((t.toNat?).getD 0).toUInt64
  else (OrbCore.Store.parseIso8601EpochU64? t).getD 0

def retentionEligible (settings : GcSettings) (nowEpochSec : UInt64) (row : MissionRetentionRow) : Bool :=
  if !settings.enabled || settings.retentionDays == 0 then false
  else if row.workingDirectory.trimAscii.toString.isEmpty then false
  else if row.resumable || !gcEligibleStatus row.status then false
  else
    let age := if nowEpochSec > row.updatedAtEpoch then nowEpochSec - row.updatedAtEpoch else 0
    age >= settings.retentionDays.toUInt64 * 86400

private def stripTrailingSlash (s : String) : String :=
  if s.length > 1 && s.endsWith "/" then (s.dropEnd 1).toString else s

private def cellStr (row : Array String) (i : Nat) : String :=
  (row[i]?).getD ""

private def realOrSelf (path : System.FilePath) : IO String := do
  if ← path.pathExists then
    try return (← IO.FS.realPath path).toString catch _ => return path.toString
  else return path.toString

private def strictlyInside (root child : String) : Bool :=
  let r := stripTrailingSlash root
  let c := stripTrailingSlash child
  c != r && c.startsWith (r ++ "/")

private def confinedToRoot (root : System.FilePath) (candidate : System.FilePath) : IO Bool := do
  let rootReal ← realOrSelf root
  let candReal ← realOrSelf candidate
  return strictlyInside rootReal candReal

private def removeConfinedTree (root : System.FilePath) (candidate : System.FilePath) : IO Bool := do
  if !(← candidate.pathExists) then return false
  let st ← statPath candidate.toString
  if st.isSymlink || !st.isDir then return false
  let rootReal ← realOrSelf root
  let candReal ← realOrSelf candidate
  if !strictlyInside rootReal candReal then return false
  match ← (IO.FS.removeDirAll candidate).toBaseIO with
  | .ok () => return true
  | .error _ => return false

def runRetentionSweep (store : CoreStore) (workspacesRoot : System.FilePath)
    (settings : GcSettings) (nowEpochSec : UInt64) : IO JVal := do
  if !settings.enabled then
    return .obj #[("enabled", .bool false), ("would_remove", .nat 0), ("removed", .nat 0), ("errors", .nat 0)]
  let .ok rows ← execParamQuery store.missionsDb
      "SELECT id,COALESCE(status,''),COALESCE(working_directory,''),COALESCE(updated_at,''),COALESCE(resumable,0) FROM missions;" #[]
    | return .obj #[("enabled", .bool true), ("would_remove", .nat 0), ("removed", .nat 0), ("errors", .nat 1)]
  let mut proposed : Nat := 0
  let mut removed : Nat := 0
  let mut errors : Nat := 0
  for i in [1:rows.size] do
    let r := rows[i]!
    let row : MissionRetentionRow := {
      id := cellStr r 0, status := cellStr r 1, workingDirectory := cellStr r 2,
      updatedAtEpoch := epochOfColumn (cellStr r 3), resumable := cellStr r 4 == "1"
    }
    if retentionEligible settings nowEpochSec row then
      let candidate := System.FilePath.mk row.workingDirectory
      if ← confinedToRoot workspacesRoot candidate then
        proposed := proposed + 1
        if settings.execute then
          if ← removeConfinedTree workspacesRoot candidate then
            removed := removed + 1
          else errors := errors + 1
  -- Unmatched directories are reported but never deleted: a short-id collision
  -- or an unreadable owner store must not become an authorization to remove work.
  let mut orphanSeen : Nat := 0
  if settings.orphansEnabled then
    if let .ok entries ← workspacesRoot.readDir |>.toBaseIO then
      let mut referenced : Array String := #[]
      for i in [1:rows.size] do
        referenced := referenced.push (stripTrailingSlash (cellStr rows[i]! 2))
      for entry in entries do
        if entry.fileName.startsWith "mission-" && !referenced.contains (stripTrailingSlash entry.path.toString) then
          orphanSeen := orphanSeen + 1
  return .obj #[
    ("enabled", .bool true), ("execute", .bool settings.execute),
    ("would_remove", .nat proposed), ("removed", .nat removed),
    ("orphans_seen", .nat orphanSeen), ("errors", .nat errors)
  ]

structure Tracker where
  lastGcEpoch : UInt64 := 0
  lastPressureEpoch : UInt64 := 0
  lastAlertEpoch : UInt64 := 0
  lastAlertPct : Nat := 0
  deriving Repr, DecidableEq, Inhabited

private def diskPercent (path : String) : IO Nat := do
  try
    let (total, used) ← statvfsBytes path
    if total == 0 then return 100
    return (used * 100 / total).toNat
  catch _ => return 0

def diskWarnPct : IO Nat := do
  let pct := ((← IO.getEnv "DISK_WARN_PCT").bind String.toNat?).getD 85
  return if pct >= 1 && pct <= 100 then pct else 85

def diskCriticalPct : IO Nat := do
  let pct := ((← IO.getEnv "DISK_CRITICAL_PCT").bind String.toNat?).getD 95
  return if pct >= 1 && pct <= 100 then pct else 95

/-- Run the cheap duties on every scheduler tick: stale dispatch-reservation
    recovery plus a five-minute pressure sample. Workspace deletion only runs
    when configured, due, and explicitly enabled by `WORKSPACE_GC_EXECUTE`. -/
def tick (store : CoreStore) (workingDir : String) (nowEpochSec : UInt64)
    (tracker : Tracker) : IO (Tracker × JVal) := do
  discard <| recoverDispatchLeases store.missionsDb store.projectsDb store.bootEpoch
  let settings ← readGcSettings store.rootDir
  let workspacesRoot := System.FilePath.mk workingDir / "workspaces"
  let mut tr := tracker
  let pressureDue := tr.lastPressureEpoch == 0 || nowEpochSec >= tr.lastPressureEpoch + pressureIntervalSeconds.toUInt64
  if !pressureDue then
    return (tr, .obj #[("skipped", .bool true)])
  tr := { tr with lastPressureEpoch := nowEpochSec }
  let pct ← diskPercent workingDir
  let warn ← diskWarnPct
  let critical ← diskCriticalPct
  let level := if pct >= critical then 2 else if pct >= warn then 1 else 0
  let pressure := level > 0
  let repeatSec := defaultAlertRepeatSeconds
  if pressure && (tr.lastAlertPct == 0 || nowEpochSec >= tr.lastAlertEpoch + repeatSec.toUInt64) then
    tr := { tr with lastAlertEpoch := nowEpochSec, lastAlertPct := pct }
    IO.eprintln s!"[orb-core] disk pressure {if level == 2 then "critical" else "warning"}: {pct}% used at {workingDir}"
  else if !pressure && tr.lastAlertPct > 0 && pct + recoveryMarginPct < warn then
    tr := { tr with lastAlertPct := 0 }
    IO.eprintln s!"[orb-core] disk pressure recovered: {pct}% used at {workingDir}"
  let scheduledDue := settings.enabled && nowEpochSec >= tr.lastGcEpoch + settings.intervalSeconds.toUInt64
  if !scheduledDue && !(pressure && settings.execute) then
    return (tr, .obj #[("pressure_pct", .nat pct), ("skipped", .bool true)])
  tr := { tr with lastGcEpoch := nowEpochSec }
  let report ← runRetentionSweep store workspacesRoot settings nowEpochSec
  let report := report.setField "pressure_pct" (.nat pct) |>.setField "trigger"
    (.str (if pressure then "disk-pressure" else "scheduled"))
  return (tr, report)

end OrbCore.Maintenance
