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

/-- Matches `src/remote_node/protocol.rs::job_state_confirms_termination`:
    `lost` does NOT confirm process termination until explicit scope stop succeeds. -/
def JobState.confirmsTermination : JobState → Bool
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
  jobId           : String
  missionId       : String
  payloadJson     : String
  state           : JobState
  exitCode?       : Option Int := none
  createdAt       : String
  startedAt?      : Option String := none
  finishedAt?     : Option String := none
  logPath?        : Option String := none
  error?          : Option String := none
  artifacts       : Array ArtifactEntry := #[]
  cancellation?   : Option JobCancellation := none
  forced          : Bool := false
  authorityMode   : String := "writer"
  placementKind   : String := "managed"
  supersededById  : String := ""
  orphanedAt      : String := ""
  reservedDiskGib : UInt64 := 0
  stateRevision   : UInt32 := 1
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
     , ("forced", .bool r.forced)
     , ("authority_mode", .str r.authorityMode)
     , ("placement_kind", .str r.placementKind)
     , ("superseded_by_mission_id", .str r.supersededById)
     , ("orphaned_at", .str r.orphanedAt)
     , ("reserved_disk_gib", JVal.uint64 r.reservedDiskGib)
     , ("state_revision", JVal.uint64 r.stateRevision.toUInt64) ]
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
  let authorityMode := (v.fieldStr? "authority_mode").getD "writer"
  let placementKind := (v.fieldStr? "placement_kind").getD "managed"
  let supersededById := (v.fieldStr? "superseded_by_mission_id").getD ""
  let orphanedAt := (v.fieldStr? "orphaned_at").getD ""
  let reservedDiskGib := (v.fieldUInt64? "reserved_disk_gib").getD 0
  let stateRevision := ((v.fieldUInt64? "state_revision").getD 1).toUInt32
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
    authorityMode := authorityMode
    placementKind := placementKind
    supersededById := supersededById
    orphanedAt := orphanedAt
    reservedDiskGib := reservedDiskGib
    stateRevision := if stateRevision == 0 then 1 else stateRevision
  }

def formatEpochIso (epochSecs : UInt64) : String :=
  s!"epoch-{epochSecs}Z"

def nowRfc3339 : IO String := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }
  if out.exitCode == 0 && !out.stdout.trimAscii.isEmpty then
    return out.stdout.trimAscii.toString
  let ep ← OrbNode.Posix.nowEpoch
  return formatEpochIso ep

inductive SqliteBackend where
  | cli
  | python3
  deriving Repr, BEq, Inhabited

structure Ledger where
  workDir           : String
  sqliteBackend     : SqliteBackend := .cli
  store             : LeanSys.Store.Handle
  jobs              : Std.HashMap String JobRecord
  order             : Array String
  pendingSqliteSync : Std.HashMap String JobRecord := {}

private def jobKey (jobId : String) : String := s!"job/{jobId}"

private def sqlEsc (s : String) : String :=
  "'" ++ String.intercalate "''" (s.splitOn "'") ++ "'"

private def sqlOptStr : Option String → String
  | some s => sqlEsc s
  | none   => "NULL"

/-- Detect mandatory SQLite backend (`sqlite3` CLI or `python3` stdlib `sqlite3`).
    Fails closed (`none`) only when neither is installed on the host! -/
def detectSqliteBackend : IO (Option SqliteBackend) := do
  match ← (IO.Process.output { cmd := "sqlite3", args := #["--version"] }).toBaseIO with
  | .ok out => if out.exitCode == 0 then return some .cli
  | .error _ => pure ()
  match ← (IO.Process.output { cmd := "python3", args := #["-c", "import sqlite3"] }).toBaseIO with
  | .ok out => if out.exitCode == 0 then return some .python3
  | .error _ => pure ()
  return none

private def pySqliteExecSnippet : String :=
  "import sqlite3,sys\n" ++
  "con=sqlite3.connect(sys.argv[1],timeout=float(sys.argv[2])/1000.0,isolation_level=None)\n" ++
  "con.executescript(sys.stdin.read())\n" ++
  "con.close()\n"

private def pySqliteQueryJsonSnippet : String :=
  "import json,sqlite3,sys\n" ++
  "con=sqlite3.connect(sys.argv[1],timeout=5.0)\n" ++
  "con.row_factory=sqlite3.Row\n" ++
  "rows=[dict(r) for r in con.execute(sys.stdin.read()).fetchall()]\n" ++
  "con.close()\n" ++
  "sys.stdout.write(json.dumps(rows))\n"

private def runSqliteStdin (backend : SqliteBackend) (dbPath sql : String) (timeoutMs : Nat := 5000) : IO (Except String Unit) := do
  let res ← match backend with
    | .cli =>
      (IO.Process.output {
        cmd := "sqlite3"
        args := #["-cmd", s!".timeout {timeoutMs}", dbPath]
      } (input? := some (sql ++ "\n"))).toBaseIO
    | .python3 =>
      (IO.Process.output {
        cmd := "python3"
        args := #["-c", pySqliteExecSnippet, dbPath, toString timeoutMs]
      } (input? := some sql)).toBaseIO
  match res with
  | .error e => return .error (toString e)
  | .ok out =>
    if out.exitCode == 0 then return .ok ()
    else return .error s!"jobs.db write locked or failed: {out.stderr.trimAscii}"

private def runSqliteStdinWithRetry
    (backend : SqliteBackend) (dbPath sql : String)
    (timeoutMs : Nat := 5000) (attempts : Nat := 4) : IO (Except String Unit) := do
  let mut lastErr := "sqlite write failed"
  for i in [0 : max 1 attempts] do
    match ← runSqliteStdin backend dbPath sql timeoutMs with
    | .ok () => return .ok ()
    | .error e =>
      lastErr := e
      if i + 1 < attempts then
        IO.sleep ((i + 1) * 150).toUInt32
  return .error lastErr

private def legacyJobAdditiveAlters : Array String := #[
  "ALTER TABLE jobs ADD COLUMN authority_mode TEXT NOT NULL DEFAULT 'writer';",
  "ALTER TABLE jobs ADD COLUMN placement_kind TEXT NOT NULL DEFAULT 'managed';",
  "ALTER TABLE jobs ADD COLUMN superseded_by_mission_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE jobs ADD COLUMN orphaned_at TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE jobs ADD COLUMN reserved_disk_gib INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE jobs ADD COLUMN state_revision INTEGER NOT NULL DEFAULT 1;"
]

private def ensureLegacySqliteSchema (workDir : String) (backend : SqliteBackend) : IO (Except String Unit) := do
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let ddl :=
    "PRAGMA journal_mode=WAL; " ++
    "CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, payload_json TEXT NOT NULL, state TEXT NOT NULL, exit_code INTEGER, created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT, log_path TEXT, error TEXT, artifacts_json TEXT, cancellation_json TEXT, authority_mode TEXT NOT NULL DEFAULT 'writer', placement_kind TEXT NOT NULL DEFAULT 'managed', superseded_by_mission_id TEXT NOT NULL DEFAULT '', orphaned_at TEXT NOT NULL DEFAULT '', reserved_disk_gib INTEGER NOT NULL DEFAULT 0, state_revision INTEGER NOT NULL DEFAULT 1); " ++
    "CREATE TABLE IF NOT EXISTS node_scratch (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, job_id TEXT, parent_identity TEXT NOT NULL, directory_identity TEXT NOT NULL, retired_at TEXT);"
  if let .error e ← runSqliteStdinWithRetry backend dbPath ddl 5000 3 then
    return .error e
  for alt in legacyJobAdditiveAlters do
    match ← runSqliteStdin backend dbPath alt 5000 with
    | .ok () => pure ()
    | .error e =>
      if (e.toLower.splitOn "duplicate column name").length ≤ 1 then
        return .error e
  return .ok ()

private def jobUpsertSql (r : JobRecord) : String :=
  let exitSql := match r.exitCode? with | some c => toString c | none => "NULL"
  let artsSql :=
    if r.artifacts.isEmpty then "NULL"
    else sqlEsc (renderCompact (.arr (r.artifacts.map ArtifactEntry.toJson)))
  let cancSql :=
    match r.cancellation? with
    | some c => sqlEsc (renderCompact c.toJson)
    | none => "NULL"
  let rev := if r.stateRevision == 0 then 1 else r.stateRevision
  "INSERT INTO jobs (id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json, authority_mode, placement_kind, superseded_by_mission_id, orphaned_at, reserved_disk_gib, state_revision) VALUES (" ++
  s!"{sqlEsc r.jobId}, {sqlEsc r.missionId}, {sqlEsc r.payloadJson}, {sqlEsc r.state.asString}, {exitSql}, {sqlEsc r.createdAt}, {sqlOptStr r.startedAt?}, {sqlOptStr r.finishedAt?}, {sqlOptStr r.logPath?}, {sqlOptStr r.error?}, {artsSql}, {cancSql}, {sqlEsc r.authorityMode}, {sqlEsc r.placementKind}, {sqlEsc r.supersededById}, {sqlEsc r.orphanedAt}, {r.reservedDiskGib}, {rev}) " ++
  "ON CONFLICT(id) DO UPDATE SET " ++
  "state = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN jobs.state ELSE excluded.state END, " ++
  "exit_code = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN COALESCE(jobs.exit_code, excluded.exit_code) ELSE excluded.exit_code END, " ++
  "started_at = COALESCE(excluded.started_at, jobs.started_at), " ++
  "finished_at = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN COALESCE(jobs.finished_at, excluded.finished_at) ELSE excluded.finished_at END, " ++
  "log_path = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN COALESCE(jobs.log_path, excluded.log_path) ELSE excluded.log_path END, " ++
  "error = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN COALESCE(jobs.error, excluded.error) ELSE excluded.error END, " ++
  "artifacts_json = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN COALESCE(jobs.artifacts_json, excluded.artifacts_json) ELSE excluded.artifacts_json END, " ++
  "cancellation_json = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN COALESCE(jobs.cancellation_json, excluded.cancellation_json) ELSE excluded.cancellation_json END, " ++
  "authority_mode = excluded.authority_mode, placement_kind = excluded.placement_kind, " ++
  "superseded_by_mission_id = excluded.superseded_by_mission_id, orphaned_at = excluded.orphaned_at, " ++
  "reserved_disk_gib = excluded.reserved_disk_gib, state_revision = excluded.state_revision " ++
  "WHERE excluded.state_revision >= jobs.state_revision;"

private def syncJobToLegacySqlite
    (workDir : String) (backend : SqliteBackend) (r : JobRecord)
    (timeoutMs : Nat := 5000) (attempts : Nat := 4) :
    IO (Except String Unit) := do
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  runSqliteStdinWithRetry backend dbPath (jobUpsertSql r) timeoutMs attempts

/-- Import legacy SQLite `<work_dir>/jobs.db` rows idempotently when `jobs.db` exists. -/
private def importLegacySqliteJobs (workDir : String) (backend : SqliteBackend) : IO (Except String (Array JobRecord)) := do
  let dbPath : System.FilePath := System.FilePath.mk workDir / "jobs.db"
  if !(← dbPath.pathExists) then return .ok #[]
  let query :=
    "SELECT id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json, authority_mode, placement_kind, superseded_by_mission_id, orphaned_at, reserved_disk_gib, state_revision FROM jobs ORDER BY created_at ASC;"
  let res ← match backend with
    | .cli =>
      (IO.Process.output {
        cmd := "sqlite3"
        args := #["-json", dbPath.toString, query]
      }).toBaseIO
    | .python3 =>
      (IO.Process.output {
        cmd := "python3"
        args := #["-c", pySqliteQueryJsonSnippet, dbPath.toString]
      } (input? := some query)).toBaseIO
  let .ok outRes := res | return .error "failed reading legacy jobs.db"
  if outRes.exitCode != 0 then
    return .error s!"legacy jobs.db query failed: {outRes.stderr.trimAscii}"
  if outRes.stdout.trimAscii.isEmpty then return .ok #[]
  let .ok (.arr rows) := OrbBin.Json.parse outRes.stdout
    | return .error "corrupt JSON output while importing legacy jobs.db"
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
      let revRaw := ((row.fieldUInt64? "state_revision").getD 1).toUInt32
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
        authorityMode := (row.fieldStr? "authority_mode").getD "writer"
        placementKind := (row.fieldStr? "placement_kind").getD "managed"
        supersededById := (row.fieldStr? "superseded_by_mission_id").getD ""
        orphanedAt := (row.fieldStr? "orphaned_at").getD ""
        reservedDiskGib := (row.fieldUInt64? "reserved_disk_gib").getD 0
        stateRevision := if revRaw == 0 then 1 else revRaw
      }
  return .ok out

/-- Open `<work_dir>/orb-node.store`, require SQLite support for `jobs.db` compatibility and
    rolling-upgrade fencing (failing closed if unavailable), replay WAL, import/initialize `jobs.db`,
    and flip any in-flight (`queued` / `running`) job on daemon startup to `lost`. -/
def openLedger (workDir : String) : IO (Except String Ledger) := do
  IO.FS.createDirAll (System.FilePath.mk workDir / "logs")
  IO.FS.createDirAll (System.FilePath.mk workDir / ".scratch")
  IO.FS.createDirAll (System.FilePath.mk workDir / "uploads")
  let some sqliteBackend ← detectSqliteBackend
    | return .error "SQLite support (sqlite3 CLI or python3 sqlite3) is required before accepting node work"
  if let .error schemaErr ← ensureLegacySqliteSchema workDir sqliteBackend then
    return .error s!"jobs.db schema initialization failed: {schemaErr}"
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
  let legacyRows ← match ← importLegacySqliteJobs workDir sqliteBackend with
    | .ok rows => pure rows
    | .error importErr => return .error importErr
  for rec in legacyRows do
    if !jobs.contains rec.jobId then
      let serialized := renderCompact (rec.toJson none)
      if let .ok h' ← LeanSys.Store.putString h (jobKey rec.jobId) serialized then
        h := h'
        jobs := jobs.insert rec.jobId rec
        order := order.push rec.jobId
  let nowTs ← nowRfc3339
  let mut batchSql := "BEGIN IMMEDIATE; "
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
          batchSql := batchSql ++ jobUpsertSql lostRec ++ " "
    else
      batchSql := batchSql ++ jobUpsertSql rec ++ " "
  batchSql := batchSql ++ "COMMIT;"
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  if let .error syncErr ← runSqliteStdinWithRetry sqliteBackend dbPath batchSql 10000 4 then
    return .error s!"jobs.db startup reconciliation failed: {syncErr}"
  return .ok {
    workDir := workDir
    sqliteBackend := sqliteBackend
    store := h
    jobs := jobs
    order := order
    pendingSqliteSync := {}
  }

namespace Ledger

/-- Reconcile any deferred `jobs.db` transitions so `rolling_upgrade_nodes.py` never observes stale rows. -/
def flushPendingSqlite (l : Ledger) : IO Ledger := do
  if l.pendingSqliteSync.isEmpty then
    return l
  let mut sql := "BEGIN IMMEDIATE; "
  for (_, rec) in l.pendingSqliteSync.toList do
    sql := sql ++ jobUpsertSql rec ++ " "
  sql := sql ++ "COMMIT;"
  let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
  match ← runSqliteStdin l.sqliteBackend dbPath sql 500 with
  | .ok () => return { l with pendingSqliteSync := {} }
  | .error _ => return l

def maxReservedDiskGib : UInt64 := 512

def insertQueued (l0 : Ledger) (rec : JobRecord) : IO (Except String Ledger) := do
  if rec.authorityMode != "readonly" && rec.authorityMode != "writer" then
    return .error s!"invalid_authority_mode:{rec.authorityMode}"
  if rec.reservedDiskGib > maxReservedDiskGib then
    return .error s!"invalid_reserved_disk_gib:{rec.reservedDiskGib}"
  let l ← flushPendingSqlite l0
  if l.jobs.contains rec.jobId then
    return .error "duplicate_job_id"
  if let .error e ← syncJobToLegacySqlite l.workDir l.sqliteBackend rec 1500 1 then
    return .error e
  let serialized := renderCompact (rec.toJson none)
  match ← LeanSys.Store.putString l.store (jobKey rec.jobId) serialized with
  | .error e =>
    let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
    discard <| runSqliteStdinWithRetry l.sqliteBackend dbPath s!"DELETE FROM jobs WHERE id = {sqlEsc rec.jobId};" 5000 3
    return .error s!"WAL write failed: {repr e}"
  | .ok h' =>
    return .ok {
      l with
      store := h'
      jobs := l.jobs.insert rec.jobId rec
      order := l.order.push rec.jobId
    }

/-- Transition `jobId` to `nextState` under `Orb.Kernel.verifyJobTransition` (first terminal wins)
    and monotone `Orb.Kernel.epochFenceStep` revision bump (`SM-02`). -/
def updateJob
    (l0 : Ledger) (jobId : String)
    (mutate : JobRecord → Except String JobRecord) : IO (Except String (Ledger × JobRecord)) := do
  let l ← flushPendingSqlite l0
  let some cur := l.jobs.get? jobId
    | return .error "not_found"
  match mutate cur with
  | .error msg => return .error msg
  | .ok next0 =>
    if next0.state != cur.state && !canTransitionTo cur.state next0.state then
      return .ok (l, cur)
    let curRev := if cur.stateRevision == 0 then 1 else cur.stateRevision
    let fenceWord := Orb.Kernel.epochFenceStep 1 1 1 1 1 1 curRev curRev 1
    let bumpedRev := if (fenceWord &&& 256) != 0 then (fenceWord >>> 32).toUInt32 else curRev + 1
    let next := { next0 with stateRevision := bumpedRev }
    let serialized := renderCompact (next.toJson none)
    match ← LeanSys.Store.putString l.store (jobKey jobId) serialized with
    | .error e => return .error s!"WAL write failed: {repr e}"
    | .ok h' =>
      let nextPending ← match ← syncJobToLegacySqlite l.workDir l.sqliteBackend next 500 1 with
        | .ok () => pure (l.pendingSqliteSync.erase jobId)
        | .error _ => pure (l.pendingSqliteSync.insert jobId next)
      return .ok ({
        l with
        store := h'
        jobs := l.jobs.insert jobId next
        pendingSqliteSync := nextPending
      }, next)

/-- Atomic compare-and-swap update on typed authority/placement/supersession/orphan/disk columns (`SM-02`),
    gated by `Orb.Kernel.epochFenceStep` so stale `expectedRev` callers never clobber concurrent disk release
    or supersession updates. -/
def updateJobAuthorityCas
    (l0 : Ledger) (jobId : String) (expectedRev : UInt32)
    (nextAuthorityMode nextPlacementKind nextSupersededBy nextOrphanedAt : String)
    (nextReservedDiskGib : UInt64) : IO (Except String (Ledger × JobRecord)) := do
  if nextAuthorityMode != "readonly" && nextAuthorityMode != "writer" then
    return .error s!"invalid_authority_mode:{nextAuthorityMode}"
  if nextReservedDiskGib > maxReservedDiskGib then
    return .error s!"invalid_reserved_disk_gib:{nextReservedDiskGib}"
  let l ← flushPendingSqlite l0
  let some cur := l.jobs.get? jobId
    | return .error "not_found"
  let durRev := if cur.stateRevision == 0 then 1 else cur.stateRevision
  let fenceWord := Orb.Kernel.epochFenceStep 1 1 1 1 1 1 durRev expectedRev 1
  let lo32 := (fenceWord &&& 0xFFFFFFFF).toUInt32
  if (lo32 &&& 256) == 0 then
    return .error s!"cas_fence_rejected:{lo32 &&& 0xFF}:expected={expectedRev}:actual={durRev}"
  let nextRev := (fenceWord >>> 32).toUInt32
  let next : JobRecord := {
    cur with
    authorityMode := nextAuthorityMode
    placementKind := nextPlacementKind
    supersededById := nextSupersededBy
    orphanedAt := nextOrphanedAt
    reservedDiskGib := nextReservedDiskGib
    stateRevision := nextRev
  }
  let serialized := renderCompact (next.toJson none)
  match ← LeanSys.Store.putString l.store (jobKey jobId) serialized with
  | .error e => return .error s!"WAL write failed: {repr e}"
  | .ok h' =>
    let nextPending ← match ← syncJobToLegacySqlite l.workDir l.sqliteBackend next 500 1 with
      | .ok () => pure (l.pendingSqliteSync.erase jobId)
      | .error _ => pure (l.pendingSqliteSync.insert jobId next)
    return .ok ({
      l with
      store := h'
      jobs := l.jobs.insert jobId next
      pendingSqliteSync := nextPending
    }, next)

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
def acquireExecFenceReceipt (workDir : String) (backend : SqliteBackend) (execId missionId : String) :
    IO (Except String Unit) := do
  let nowTs ← nowRfc3339
  let execRec : JobRecord := {
    jobId := execId
    missionId := missionId
    payloadJson := "{\"kind\":\"sync_execute\"}"
    state := .running
    createdAt := nowTs
    startedAt? := some nowTs
  }
  syncJobToLegacySqlite workDir backend execRec 1500 1

def releaseExecFenceReceipt (workDir : String) (backend : SqliteBackend) (execId missionId : String) : IO Unit := do
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let sql := s!"DELETE FROM jobs WHERE id = {sqlEsc execId} AND mission_id = {sqlEsc missionId};"
  match ← runSqliteStdinWithRetry backend dbPath sql 5000 4 with
  | .ok () => pure ()
  | .error _ =>
    discard <| IO.asTask (do
      for step in [0 : 12] do
        IO.sleep ((step + 1) * 500).toUInt32
        if (← runSqliteStdin backend dbPath sql 5000) matches .ok () then
          break
    ) Task.Priority.dedicated

end OrbNode.Store
