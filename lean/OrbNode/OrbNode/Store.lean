/-
  OrbNode.Store: Durable Crash-Atomic Job Ledger (`LeanSys.Store` WAL) + Legacy `jobs.db`
  SQLite Importer + First-Wins Terminal Transition Guard (`Orb.Kernel.verifyJobTransition`).
-/
import LeanSys.Store
import Orb.Kernel
import OrbBin.Json
import OrbNode.Posix

namespace OrbNode.Store

open OrbBin.Json

inductive JobState where
  | queued
  | running
  | succeeded
  | failed
  | cancelled
  | lost
  deriving Repr, DecidableEq, BEq, Inhabited

def JobState.code : JobState → UInt8
  | .queued    => 0
  | .running   => 1
  | .succeeded => 2
  | .failed    => 3
  | .cancelled => 4
  | .lost      => 5

def JobState.asString : JobState → String
  | .queued    => "queued"
  | .running   => "running"
  | .succeeded => "succeeded"
  | .failed    => "failed"
  | .cancelled => "cancelled"
  | .lost      => "lost"

def JobState.ofString? : String → Option JobState
  | "queued"    => some .queued
  | "running"   => some .running
  | "succeeded" => some .succeeded
  | "failed"    => some .failed
  | "cancelled" => some .cancelled
  | "lost"      => some .lost
  | _           => none

def JobState.isTerminal : JobState → Bool
  | .succeeded | .failed | .cancelled => true
  | .queued | .running | .lost        => false

def canTransitionTo (fromState toState : JobState) : Bool :=
  Orb.Kernel.verifyJobTransition fromState.code toState.code == 1

structure ArtifactEntry where
  path      : String
  sha256    : String
  sizeBytes : UInt64
  deriving Repr, BEq, Inhabited

def ArtifactEntry.toJson (a : ArtifactEntry) : JVal :=
  .obj #[ ("path", .str a.path)
        , ("sha256", .str a.sha256)
        , ("size_bytes", JVal.uint64 a.sizeBytes) ]

def ArtifactEntry.fromJson? (v : JVal) : Option ArtifactEntry := do
  let path ← v.fieldStr? "path"
  let sha256 ← v.fieldStr? "sha256"
  let sz ← v.fieldUInt64? "size_bytes"
  return { path := path, sha256 := sha256, sizeBytes := sz }

structure JobCancellation where
  actor       : String
  reason      : String
  requestedAt : String
  deriving Repr, BEq, Inhabited

def JobCancellation.toJson (c : JobCancellation) : JVal :=
  .obj #[ ("actor", .str c.actor)
        , ("reason", .str c.reason)
        , ("requested_at", .str c.requestedAt) ]

def JobCancellation.fromJson? (v : JVal) : Option JobCancellation := do
  let actor ← v.fieldStr? "actor"
  let reason ← v.fieldStr? "reason"
  let reqAt ← v.fieldStr? "requested_at"
  return { actor := actor, reason := reason, requestedAt := reqAt }

structure JobRecord where
  jobId         : String
  missionId     : String
  payloadJson   : String
  state         : JobState
  exitCode?     : Option Int := none
  createdAt     : String
  startedAt?    : Option String := none
  finishedAt?   : Option String := none
  logPath?      : Option String := none
  error?        : Option String := none
  artifacts     : Array ArtifactEntry := #[]
  cancellation? : Option JobCancellation := none
  forced        : Bool := false
  deriving Repr, Inhabited

def JobRecord.toJson (r : JobRecord) (logTail? : Option String := none) : JVal :=
  let base : Array (String × JVal) :=
    #[ ("job_id", .str r.jobId)
     , ("mission_id", .str r.missionId)
     , ("state", .str r.state.asString)
     , ("exit_code", match r.exitCode? with | some c => JVal.int c | none => .null)
     , ("created_at", .str r.createdAt)
     , ("started_at", match r.startedAt? with | some s => .str s | none => .null)
     , ("finished_at", match r.finishedAt? with | some s => .str s | none => .null)
     , ("error", match r.error? with | some s => .str s | none => .null)
     , ("log_tail", match logTail? with | some s => .str s | none => .null)
     , ("artifacts", .arr (r.artifacts.map ArtifactEntry.toJson))
     , ("forced", .bool r.forced) ]
  let extra : Array (String × JVal) :=
    (match r.cancellation? with
     | some c => #[("cancellation", c.toJson)]
     | none => #[]) ++
    #[ ("payload_json", .str r.payloadJson) ] ++
    (match r.logPath? with
     | some lp => #[("log_path", .str lp)]
     | none => #[])
  .obj (base ++ extra)

/-- Public HTTP `NodeJobStatus` JSON projection (omits internal `payload_json`/`log_path`). -/
def JobRecord.toStatusJson (r : JobRecord) (logTail? : Option String := none) : JVal :=
  let fields : Array (String × JVal) :=
    (match r.cancellation? with
     | some c => #[("cancellation", c.toJson)]
     | none => #[]) ++
    #[ ("job_id", .str r.jobId)
     , ("mission_id", .str r.missionId)
     , ("state", .str r.state.asString)
     , ("exit_code", match r.exitCode? with | some c => JVal.int c | none => .null)
     , ("created_at", .str r.createdAt)
     , ("started_at", match r.startedAt? with | some s => .str s | none => .null)
     , ("finished_at", match r.finishedAt? with | some s => .str s | none => .null)
     , ("error", match r.error? with | some s => .str s | none => .null)
     , ("log_tail", match logTail? with | some s => .str s | none => .null)
     , ("artifacts", .arr (r.artifacts.map ArtifactEntry.toJson))
     , ("forced", .bool r.forced) ]
  .obj fields

def JobRecord.fromStoreJson? (v : JVal) : Option JobRecord := do
  let jobId ← v.fieldStr? "job_id"
  let missionId ← v.fieldStr? "mission_id"
  let stateStr ← v.fieldStr? "state"
  let state ← JobState.ofString? stateStr
  let createdAt ← v.fieldStr? "created_at"
  let payloadJson := (v.fieldStr? "payload_json").getD "{}"
  let exitCode? := v.fieldInt? "exit_code"
  let startedAt? := v.fieldStr? "started_at"
  let finishedAt? := v.fieldStr? "finished_at"
  let logPath? := v.fieldStr? "log_path"
  let error? := v.fieldStr? "error"
  let forced := (v.fieldBool? "forced").getD false
  let artifacts :=
    match v.fieldArr? "artifacts" with
    | some xs => xs.filterMap ArtifactEntry.fromJson?
    | none => #[]
  let cancellation? := (v.field? "cancellation") >>= JobCancellation.fromJson?
  return {
    jobId := jobId
    missionId := missionId
    payloadJson := payloadJson
    state := state
    exitCode? := exitCode?
    createdAt := createdAt
    startedAt? := startedAt?
    finishedAt? := finishedAt?
    logPath? := logPath?
    error? := error?
    artifacts := artifacts
    cancellation? := cancellation?
    forced := forced
  }

def formatEpochIso (epochSecs : UInt64) : String :=
  s!"epoch-{epochSecs}Z"

def nowRfc3339 : IO String := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }
  if out.exitCode == 0 && !out.stdout.trimAscii.isEmpty then
    return out.stdout.trimAscii.toString
  let ep ← OrbNode.Posix.nowEpoch
  return formatEpochIso ep

structure Ledger where
  workDir : String
  store   : LeanSys.Store.Handle
  jobs    : Std.HashMap String JobRecord
  order   : Array String

private def jobKey (jobId : String) : String := s!"job/{jobId}"

/-- Import legacy SQLite `<work_dir>/jobs.db` rows idempotently when `sqlite3` and `jobs.db` exist. -/
private def importLegacySqliteJobs (workDir : String) : IO (Array JobRecord) := do
  let dbPath : System.FilePath := System.FilePath.mk workDir / "jobs.db"
  if !(← dbPath.pathExists) then return #[]
  let res ← IO.Process.output {
    cmd := "sqlite3"
    args := #["-json", dbPath.toString,
      "SELECT id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json FROM jobs ORDER BY created_at ASC;"]
  }
  if res.exitCode != 0 || res.stdout.trimAscii.isEmpty then return #[]
  let .ok (.arr rows) := OrbBin.Json.parse res.stdout
    | return #[]
  let mut out : Array JobRecord := #[]
  for row in rows do
    if let some id := row.fieldStr? "id" then
      let missionId := (row.fieldStr? "mission_id").getD "00000000-0000-0000-0000-000000000000"
      let payloadJson := (row.fieldStr? "payload_json").getD "{}"
      let state := ((row.fieldStr? "state") >>= JobState.ofString?).getD .lost
      let createdAt := (row.fieldStr? "created_at").getD "1970-01-01T00:00:00Z"
      let artifacts : Array ArtifactEntry :=
        match row.fieldStr? "artifacts_json" with
        | some s =>
          match OrbBin.Json.parse s with
          | .ok (.arr xs) => xs.filterMap ArtifactEntry.fromJson?
          | _ => #[]
        | none => #[]
      let cancellation? : Option JobCancellation :=
        match row.fieldStr? "cancellation_json" with
        | some s =>
          match OrbBin.Json.parse s with
          | .ok cv => JobCancellation.fromJson? cv
          | _ => none
        | none => none
      out := out.push {
        jobId := id
        missionId := missionId
        payloadJson := payloadJson
        state := state
        exitCode? := row.fieldInt? "exit_code"
        createdAt := createdAt
        startedAt? := row.fieldStr? "started_at"
        finishedAt? := row.fieldStr? "finished_at"
        logPath? := row.fieldStr? "log_path"
        error? := row.fieldStr? "error"
        artifacts := artifacts
        cancellation? := cancellation?
      }
  return out

/-- Open `<work_dir>/orb-node.store`, replay WAL, import legacy `jobs.db` rows if absent,
    and flip any in-flight (`queued` / `running`) job on daemon startup to `lost`. -/
def openLedger (workDir : String) : IO (Except String Ledger) := do
  IO.FS.createDirAll (System.FilePath.mk workDir / "logs")
  IO.FS.createDirAll (System.FilePath.mk workDir / ".scratch")
  IO.FS.createDirAll (System.FilePath.mk workDir / "uploads")
  let storeDir := (System.FilePath.mk workDir / "orb-node.store").toString
  let h0 ← match ← LeanSys.Store.openStore storeDir with
    | .ok h => pure h
    | .error e => return .error s!"LeanSys.Store.openStore failed: {repr e}"
  let mut h := h0
  let mut jobs : Std.HashMap String JobRecord := {}
  let mut order : Array String := #[]
  for (k, v) in h.kv.toList do
    if k.startsWith "job/" then
      if let some raw := String.fromUTF8? v then
        if let .ok jv := OrbBin.Json.parse raw then
          if let some rec := JobRecord.fromStoreJson? jv then
            jobs := jobs.insert rec.jobId rec
            order := order.push rec.jobId
  let legacyRows ← importLegacySqliteJobs workDir
  for rec in legacyRows do
    if !jobs.contains rec.jobId then
      let serialized := renderCompact (rec.toJson none)
      if let .ok h' ← LeanSys.Store.putString h (jobKey rec.jobId) serialized then
        h := h'
        jobs := jobs.insert rec.jobId rec
        order := order.push rec.jobId
  let nowTs ← nowRfc3339
  for (jid, rec) in jobs.toList do
    if rec.state == .queued || rec.state == .running then
      if canTransitionTo rec.state .lost then
        let lostRec : JobRecord := {
          rec with
          state := .lost
          finishedAt? := some nowTs
          error? := some "node restarted while the job was in flight"
        }
        let serialized := renderCompact (lostRec.toJson none)
        if let .ok h' ← LeanSys.Store.putString h (jobKey jid) serialized then
          h := h'
          jobs := jobs.insert jid lostRec
  return .ok { workDir := workDir, store := h, jobs := jobs, order := order }

namespace Ledger

def insertQueued (l : Ledger) (rec : JobRecord) : IO (Except String Ledger) := do
  if l.jobs.contains rec.jobId then
    return .error "duplicate_job_id"
  let serialized := renderCompact (rec.toJson none)
  match ← LeanSys.Store.putString l.store (jobKey rec.jobId) serialized with
  | .error e => return .error s!"WAL write failed: {repr e}"
  | .ok h' =>
    return .ok {
      l with
      store := h'
      jobs := l.jobs.insert rec.jobId rec
      order := l.order.push rec.jobId
    }

/-- Transition `jobId` to `nextState` under `Orb.Kernel.verifyJobTransition` (first terminal wins). -/
def updateJob
    (l : Ledger) (jobId : String)
    (mutate : JobRecord → Except String JobRecord) : IO (Except String (Ledger × JobRecord)) := do
  let some cur := l.jobs.get? jobId
    | return .error "not_found"
  match mutate cur with
  | .error msg => return .error msg
  | .ok next =>
    if next.state != cur.state && !canTransitionTo cur.state next.state then
      return .ok (l, cur)
    let serialized := renderCompact (next.toJson none)
    match ← LeanSys.Store.putString l.store (jobKey jobId) serialized with
    | .error e => return .error s!"WAL write failed: {repr e}"
    | .ok h' =>
      return .ok ({ l with store := h', jobs := l.jobs.insert jobId next }, next)

def listRecent (l : Ledger) (limit : Nat) : Array JobRecord := Id.run do
  let clamped := max 1 (min 200 limit)
  let mut out : Array JobRecord := #[]
  let n := l.order.size
  let mut idx := n
  while idx > 0 && out.size < clamped do
    idx := idx - 1
    let jid := l.order[idx]!
    if let some rec := l.jobs.get? jid then
      out := out.push rec
  return out

end Ledger

end OrbNode.Store
