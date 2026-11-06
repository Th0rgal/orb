/-
  OrbNode.Store: Durable Crash-Atomic Job Ledger (`LeanSys.Store` WAL) + Legacy `jobs.db`
  SQLite Dual-Sync (preserving `rolling_upgrade_nodes.py` `BEGIN IMMEDIATE` fencing) +
  First-Wins Terminal Transition Guard (`Orb.Kernel.verifyJobTransition`).
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
  workDir     : String
  hasSqlite3  : Bool := false
  store       : LeanSys.Store.Handle
  jobs        : Std.HashMap String JobRecord
  order       : Array String

private def jobKey (jobId : String) : String := s!"job/{jobId}"

private def sqlEsc (s : String) : String :=
  "'" ++ String.intercalate "''" (s.splitOn "'") ++ "'"

private def sqlOptStr : Option String → String
  | some s => sqlEsc s
  | none   => "NULL"

private def detectSqlite3 : IO Bool := do
  let r ← (IO.Process.output { cmd := "sqlite3", args := #["--version"] }).toBaseIO
  match r with
  | .ok out => return out.exitCode == 0
  | .error _ => return false

private def runSqliteStdin (dbPath sql : String) (timeoutMs : Nat := 5000) : IO (Except String Unit) := do
  let res ← (IO.Process.output {
    cmd := "sqlite3"
    args := #["-cmd", s!".timeout {timeoutMs}", dbPath]
  } (input? := some (sql ++ "\n"))).toBaseIO
  match res with
  | .error e => return .error (toString e)
  | .ok out =>
    if out.exitCode == 0 then return .ok ()
    else return .error s!"jobs.db write locked or failed: {out.stderr.trimAscii}"

private def ensureLegacySqliteSchema (workDir : String) (hasSqlite3 : Bool) : IO Unit := do
  if !hasSqlite3 then return
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let ddl :=
    "PRAGMA journal_mode=WAL; " ++
    "CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, payload_json TEXT NOT NULL, state TEXT NOT NULL, exit_code INTEGER, created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT, log_path TEXT, error TEXT, artifacts_json TEXT, cancellation_json TEXT); " ++
    "CREATE TABLE IF NOT EXISTS node_scratch (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, job_id TEXT, parent_identity TEXT NOT NULL, directory_identity TEXT NOT NULL, retired_at TEXT);"
  discard <| runSqliteStdin dbPath ddl 5000

private def syncJobToLegacySqlite
    (workDir : String) (hasSqlite3 : Bool) (r : JobRecord) (timeoutMs : Nat := 5000) :
    IO (Except String Unit) := do
  if !hasSqlite3 then return .ok ()
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let exitSql := match r.exitCode? with | some c => toString c | none => "NULL"
  let artsSql :=
    if r.artifacts.isEmpty then "NULL"
    else sqlEsc (renderCompact (.arr (r.artifacts.map ArtifactEntry.toJson)))
  let cancSql :=
    match r.cancellation? with
    | some c => sqlEsc (renderCompact c.toJson)
    | none => "NULL"
  let sql :=
    "INSERT OR REPLACE INTO jobs (id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json) VALUES (" ++
    s!"{sqlEsc r.jobId}, {sqlEsc r.missionId}, {sqlEsc r.payloadJson}, {sqlEsc r.state.asString}, {exitSql}, {sqlEsc r.createdAt}, {sqlOptStr r.startedAt?}, {sqlOptStr r.finishedAt?}, {sqlOptStr r.logPath?}, {sqlOptStr r.error?}, {artsSql}, {cancSql});"
  runSqliteStdin dbPath sql timeoutMs

/-- Import legacy SQLite `<work_dir>/jobs.db` rows idempotently when `sqlite3` and `jobs.db` exist. -/
private def importLegacySqliteJobs (workDir : String) (hasSqlite3 : Bool) : IO (Array JobRecord) := do
  if !hasSqlite3 then return #[]
  let dbPath : System.FilePath := System.FilePath.mk workDir / "jobs.db"
  if !(← dbPath.pathExists) then return #[]
  let .ok res ← (IO.Process.output {
    cmd := "sqlite3"
    args := #["-json", dbPath.toString,
      "SELECT id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json FROM jobs ORDER BY created_at ASC;"]
  }).toBaseIO | return #[]
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

/-- Open `<work_dir>/orb-node.store`, replay WAL, import/initialize `jobs.db`,
    and flip any in-flight (`queued` / `running`) job on daemon startup to `lost`. -/
def openLedger (workDir : String) : IO (Except String Ledger) := do
  IO.FS.createDirAll (System.FilePath.mk workDir / "logs")
  IO.FS.createDirAll (System.FilePath.mk workDir / ".scratch")
  IO.FS.createDirAll (System.FilePath.mk workDir / "uploads")
  let hasSqlite3 ← detectSqlite3
  ensureLegacySqliteSchema workDir hasSqlite3
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
  let legacyRows ← importLegacySqliteJobs workDir hasSqlite3
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
          discard <| syncJobToLegacySqlite workDir hasSqlite3 lostRec
    else
      discard <| syncJobToLegacySqlite workDir hasSqlite3 rec
  return .ok {
    workDir := workDir
    hasSqlite3 := hasSqlite3
    store := h
    jobs := jobs
    order := order
  }

namespace Ledger

def insertQueued (l : Ledger) (rec : JobRecord) : IO (Except String Ledger) := do
  if l.jobs.contains rec.jobId then
    return .error "duplicate_job_id"
  if let .error e ← syncJobToLegacySqlite l.workDir l.hasSqlite3 rec 1500 then
    return .error e
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
      discard <| syncJobToLegacySqlite l.workDir l.hasSqlite3 next
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

def missionHasLiveJobs (l : Ledger) (missionId : String) : Bool :=
  l.jobs.fold (fun acc _ r =>
    acc || (r.missionId == missionId && (r.state == .queued || r.state == .running))) false

end Ledger

/-- Strip `source.archive.data_base64` before persisting `payload_json` to durable stores (`persisted_payload_json`). -/
def sanitizePersistedPayload (payloadVal : JVal) : JVal :=
  match payloadVal with
  | .obj fields =>
    if (payloadVal.fieldStr? "kind") == some "lean_build" then
      .obj (fields.map fun (k, v) =>
        if k == "source" then
          match v with
          | .obj sFields =>
            (k, .obj (sFields.map fun (sk, sv) =>
              if sk == "archive" then
                match sv with
                | .obj aFields =>
                  (sk, .obj (aFields.map fun (ak, av) =>
                    if ak == "data_base64" then (ak, .str "") else (ak, av)))
                | other => (sk, other)
              else (sk, sv)))
          | other => (k, other)
        else (k, v))
    else payloadVal
  | other => other

/-- Fence synchronous `POST /execute` admission against `rolling_upgrade_nodes.py`'s `BEGIN IMMEDIATE`
    transaction on `jobs.db`: inserts a temporary `running` row into `jobs.db` before execution
    starts (failing closed if `jobs.db` is write-locked) and removes it on completion. -/
def acquireExecFenceReceipt (workDir : String) (hasSqlite3 : Bool) (execId missionId : String) :
    IO (Except String Unit) := do
  if !hasSqlite3 then return .ok ()
  let nowTs ← nowRfc3339
  let execRec : JobRecord := {
    jobId := execId
    missionId := missionId
    payloadJson := "{\"kind\":\"sync_execute\"}"
    state := .running
    createdAt := nowTs
    startedAt? := some nowTs
  }
  syncJobToLegacySqlite workDir hasSqlite3 execRec 1500

def releaseExecFenceReceipt (workDir : String) (hasSqlite3 : Bool) (execId missionId : String) : IO Unit := do
  if !hasSqlite3 then return
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let sql := s!"DELETE FROM jobs WHERE id = {sqlEsc execId} AND mission_id = {sqlEsc missionId};"
  discard <| runSqliteStdin dbPath sql 5000

end OrbNode.Store
