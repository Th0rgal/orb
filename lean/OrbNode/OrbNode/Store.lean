/-
  OrbNode.Store: Durable Crash-Atomic Job Ledger (`LeanSys.Store` WAL) + Legacy `jobs.db`
  SQLite Dual-Sync (preserving `rolling_upgrade_nodes.py` `BEGIN IMMEDIATE` fencing) +
  First-Wins Terminal Transition Guard (`Orb.Kernel.verifyJobTransition`).
-/
import LeanSys.Store
import LeanSys.Auth
import Orb.Kernel
import Orb.ManagedNode
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.Posix

namespace OrbNode.Store

open LeanSys.Auth
open OrbBin.PosixExt
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
  operationId     : String := ""
  nodeBootEpoch   : UInt64 := 0
  pid             : UInt64 := 0
  startTicks      : UInt64 := 0
  phaseCode       : UInt8 := 0
  procPhase       : UInt8 := 0
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
      , ("state_revision", JVal.uint64 r.stateRevision.toUInt64)
      , ("operation_id", .str r.operationId)
      , ("node_boot_epoch", JVal.uint64 r.nodeBootEpoch)
      , ("pid", JVal.uint64 r.pid)
      , ("start_ticks", JVal.uint64 r.startTicks)
      , ("phase_code", JVal.uint64 r.phaseCode.toUInt64)
      , ("proc_phase", JVal.uint64 r.procPhase.toUInt64) ]
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
      , ("forced", .bool r.forced)
      , ("operation_id", .str r.operationId)
      , ("node_boot_epoch", JVal.uint64 r.nodeBootEpoch)
      , ("phase_code", JVal.uint64 r.phaseCode.toUInt64) ]
  .obj fields

def defaultPhaseCodeForState : JobState → UInt8
  | .queued | .running => 1
  | .succeeded         => 3
  | .failed            => 4
  | .cancelled         => 5
  | .lost              => 2

def operationIdToken (raw : String) : UInt64 := Id.run do
  let clean := raw.trimAscii.toString
  if clean.isEmpty then
    return 0
  if let some n := clean.toNat? then
    if 0 < n && n ≤ 0xFFFFFFFFFFFFFFFF then
      return n.toUInt64
  let digest := sha256Bytes clean.toUTF8
  let mut w : UInt64 := 0
  for i in [0:8] do
    w := w ||| ((digest.get! i).toUInt64 <<< (i * 8).toUInt64)
  return if w == 0 then 1 else w

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
  let operationId := (v.fieldStr? "operation_id").getD ""
  let nodeBootEpoch := (v.fieldUInt64? "node_boot_epoch").getD 0
  let pid := (v.fieldUInt64? "pid").getD 0
  let startTicks := (v.fieldUInt64? "start_ticks").getD 0
  let rawPhase := ((v.fieldUInt64? "phase_code").getD 0).toUInt8
  let phaseCode := if rawPhase == 0 || rawPhase > 5 then defaultPhaseCodeForState state else rawPhase
  let procPhase := ((v.fieldUInt64? "proc_phase").getD 0).toUInt8
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
    operationId := if operationId.isEmpty then jobId else operationId
    nodeBootEpoch := nodeBootEpoch
    pid := pid
    startTicks := startTicks
    phaseCode := phaseCode
    procPhase := if procPhase > 4 then 0 else procPhase
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

structure ContainerLeaderRecord where
  workspaceId   : String
  machineName   : String
  leaderPid     : UInt32
  startTicks    : UInt64
  nodeBootEpoch : UInt64
  procPhase     : UInt8 := 1
  jobId         : String := ""
  updatedAt     : String := ""
  deriving Repr, BEq, Inhabited

structure ScratchReceipt where
  id                : String
  missionId         : String
  jobId?            : Option String := none
  nodeBootEpoch     : UInt64 := 1
  claimSeq          : UInt64 := 1
  parentIdentity    : String
  directoryIdentity : String
  retiredAt?        : Option String := none
  deriving Repr, BEq, Inhabited

structure Ledger where
  workDir           : String
  sqliteBackend     : SqliteBackend := .cli
  nodeBootEpoch     : UInt64 := 1
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

private def pySqliteClaimRetireScratchSnippet : String :=
  "import json,os,sqlite3,sys\n" ++
  "db,sid,scratch_dir,claim_dir,exp_p,exp_d,exp_boot,exp_seq,now_ts,t_ms=sys.argv[1:11]\n" ++
  "eb=int(exp_boot or '0')\n" ++
  "es=int(exp_seq or '0')\n" ++
  "parent_dir=(os.path.dirname(scratch_dir.rstrip('/')) or '/') if scratch_dir else ''\n" ++
  "def pident(p):\n" ++
  "  if not p:\n" ++
  "    return None\n" ++
  "  try:\n" ++
  "    st=os.lstat(p)\n" ++
  "    if (st.st_mode & 0o170000) == 0o120000:\n" ++
  "      return None\n" ++
  "    return f'{st.st_dev}:{st.st_ino}'\n" ++
  "  except OSError:\n" ++
  "    return None\n" ++
  "con=sqlite3.connect(db,timeout=float(t_ms)/1000.0,isolation_level=None)\n" ++
  "con.row_factory=sqlite3.Row\n" ++
  "res={'ok':False,'claimed':False,'reason':'unknown'}\n" ++
  "try:\n" ++
  "  con.execute('BEGIN IMMEDIATE')\n" ++
  "  row=con.execute('SELECT node_boot_epoch, claim_seq, parent_identity, directory_identity, retired_at FROM node_scratch WHERE id = ?', (sid,)).fetchone()\n" ++
  "  if row is None:\n" ++
  "    con.execute('ROLLBACK')\n" ++
  "    res={'ok':False,'claimed':False,'reason':'scratch_receipt_missing'}\n" ++
  "  else:\n" ++
  "    sb=int(row['node_boot_epoch'] or 0)\n" ++
  "    ss=int(row['claim_seq'] or 0)\n" ++
  "    sp=row['parent_identity'] or ''\n" ++
  "    sd=row['directory_identity'] or ''\n" ++
  "    if not sp or not sd or (exp_p and sp != exp_p) or (exp_d and sd != exp_d) or (eb and sb != eb) or (es and ss != es):\n" ++
  "      con.execute('ROLLBACK')\n" ++
  "      res={'ok':False,'claimed':False,'reason':'scratch_identity_mismatch'}\n" ++
  "    elif row['retired_at'] is not None:\n" ++
  "      con.execute('COMMIT')\n" ++
  "      res={'ok':True,'claimed':False,'reason':'already_retired'}\n" ++
  "    else:\n" ++
  "      claimed=False\n" ++
  "      if scratch_dir:\n" ++
  "        cp=pident(parent_dir)\n" ++
  "        cd=pident(scratch_dir)\n" ++
  "        if cp != sp or cd != sd:\n" ++
  "          con.execute('ROLLBACK')\n" ++
  "          res={'ok':False,'claimed':False,'reason':'scratch_identity_mismatch'}\n" ++
  "          sys.stdout.write(json.dumps(res))\n" ++
  "          sys.exit(0)\n" ++
  "        if claim_dir:\n" ++
  "          os.rename(scratch_dir, claim_dir)\n" ++
  "          rp=pident(parent_dir)\n" ++
  "          rd=pident(claim_dir)\n" ++
  "          if rp != sp or rd != sd:\n" ++
  "            try:\n" ++
  "              if not os.path.lexists(scratch_dir):\n" ++
  "                os.rename(claim_dir, scratch_dir)\n" ++
  "            except OSError:\n" ++
  "              pass\n" ++
  "            con.execute('ROLLBACK')\n" ++
  "            res={'ok':False,'claimed':False,'reason':'scratch_identity_mismatch'}\n" ++
  "            sys.stdout.write(json.dumps(res))\n" ++
  "            sys.exit(0)\n" ++
  "          claimed=True\n" ++
  "      con.execute('UPDATE node_scratch SET retired_at = ? WHERE id = ? AND node_boot_epoch = ? AND claim_seq = ? AND parent_identity = ? AND directory_identity = ? AND retired_at IS NULL', (now_ts, sid, sb, ss, sp, sd))\n" ++
  "      con.execute('COMMIT')\n" ++
  "      res={'ok':True,'claimed':claimed,'reason':'retired'}\n" ++
  "except Exception as e:\n" ++
  "  try:\n" ++
  "    con.execute('ROLLBACK')\n" ++
  "  except Exception:\n" ++
  "    pass\n" ++
  "  res={'ok':False,'claimed':False,'reason':str(e)}\n" ++
  "finally:\n" ++
  "  con.close()\n" ++
  "sys.stdout.write(json.dumps(res))\n"

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

private def runSqliteQueryJson (backend : SqliteBackend) (dbPath sql : String) : IO (Except String (Array JVal)) := do
  let res ← match backend with
    | .cli =>
      (IO.Process.output {
        cmd := "sqlite3"
        args := #["-json", dbPath, sql]
      }).toBaseIO
    | .python3 =>
      (IO.Process.output {
        cmd := "python3"
        args := #["-c", pySqliteQueryJsonSnippet, dbPath]
      } (input? := some sql)).toBaseIO
  let .ok outRes := res | return .error "sqlite query execution failed"
  if outRes.exitCode != 0 then
    return .error s!"sqlite query failed: {outRes.stderr.trimAscii}"
  if outRes.stdout.trimAscii.isEmpty then return .ok #[]
  match OrbBin.Json.parse outRes.stdout with
  | .ok (.arr rows) => return .ok rows
  | _ => return .error "corrupt JSON output from sqlite query"

def readPathIdentity? (path : String) : IO (Option String) := do
  let st ← statPath path
  if !st.exists_ || st.isSymlink then
    return none
  match ← (IO.Process.output { cmd := "stat", args := #["-c", "%d:%i", path] }).toBaseIO with
  | .ok out =>
    if out.exitCode == 0 then
      let trimmed := out.stdout.trimAscii.toString
      if !trimmed.isEmpty then return some trimmed
  | .error _ => pure ()
  match ← (IO.Process.output { cmd := "stat", args := #["-f", "%d:%i", path] }).toBaseIO with
  | .ok out =>
    if out.exitCode == 0 then
      let trimmed := out.stdout.trimAscii.toString
      if !trimmed.isEmpty then return some trimmed
  | .error _ => pure ()
  return none

private def runClaimRetireScratchTx
    (backend : SqliteBackend)
    (dbPath scratchId scratchDir claimDir expectedParent expectedDir : String)
    (expectedBootEpoch expectedClaimSeq : UInt64)
    (nowTs : String) (timeoutMs : Nat := 2500) (attempts : Nat := 3)
    (forceCliFallback : Bool := false) : IO (Except String Bool) := do
  let mut lastErr := "scratch_retire_failed"
  for i in [0 : max 1 attempts] do
    let pyRes ←
      if forceCliFallback then
        pure (.error (IO.userError "force_cli"))
      else
        (IO.Process.output {
          cmd := "python3"
          args := #[
            "-c", pySqliteClaimRetireScratchSnippet,
            dbPath, scratchId, scratchDir, claimDir, expectedParent, expectedDir,
            toString expectedBootEpoch, toString expectedClaimSeq, nowTs, toString timeoutMs
          ]
        }).toBaseIO
    match pyRes with
    | .ok out =>
      if out.exitCode == 0 then
        match OrbBin.Json.parse out.stdout with
        | .ok jv =>
          if (jv.fieldBool? "ok").getD false then
            return .ok ((jv.fieldBool? "claimed").getD false)
          else
            lastErr := (jv.fieldStr? "reason").getD "scratch_retire_rejected"
        | .error _ =>
          lastErr := "corrupt scratch retire response"
      else
        lastErr := out.stderr.trimAscii.toString
    | .error pyIoErr =>
      if backend == .cli then
        let parentPath := (System.FilePath.mk scratchDir).parent.map (·.toString) |>.getD ""
        let preRows ← match ← runSqliteQueryJson .cli dbPath
            s!"SELECT node_boot_epoch, claim_seq, parent_identity, directory_identity, retired_at FROM node_scratch WHERE id = {sqlEsc scratchId};" with
          | .ok rs => pure rs
          | .error qe => return .error qe
        let some preRow := preRows[0]?
          | return .error "scratch_receipt_missing"
        let preBoot := (preRow.fieldUInt64? "node_boot_epoch").getD 0
        let preSeq := (preRow.fieldUInt64? "claim_seq").getD 0
        let preParent := (preRow.fieldStr? "parent_identity").getD ""
        let preDir := (preRow.fieldStr? "directory_identity").getD ""
        if preParent.isEmpty || preDir.isEmpty ||
           (!expectedParent.isEmpty && preParent != expectedParent) ||
           (!expectedDir.isEmpty && preDir != expectedDir) ||
           (expectedBootEpoch != 0 && preBoot != expectedBootEpoch) ||
           (expectedClaimSeq != 0 && preSeq != expectedClaimSeq) then
          return .error "scratch_identity_mismatch"
        if (preRow.fieldStr? "retired_at").isSome then
          return .ok false
        let liveParent ← if scratchDir.isEmpty then pure preParent else pure ((← readPathIdentity? parentPath).getD "")
        let liveDir ← if scratchDir.isEmpty then pure preDir else pure ((← readPathIdentity? scratchDir).getD "")
        if liveParent != preParent || liveDir != preDir then
          return .error "scratch_identity_mismatch"
        let bootPred := if expectedBootEpoch == 0 then "" else s!" AND node_boot_epoch = {expectedBootEpoch}"
        let seqPred := if expectedClaimSeq == 0 then "" else s!" AND claim_seq = {expectedClaimSeq}"
        let claimCmd :=
          if !scratchDir.isEmpty && !claimDir.isEmpty then
            let escMv (p : String) : String := "'" ++ String.intercalate "'\\''" (p.splitOn "'") ++ "'"
            s!".shell mv -- {escMv scratchDir} {escMv claimDir}\n"
          else ""
        let cliSql :=
          "BEGIN IMMEDIATE;\n" ++
          claimCmd ++
          "UPDATE node_scratch SET retired_at = " ++ sqlEsc nowTs ++
          " WHERE id = " ++ sqlEsc scratchId ++
          bootPred ++ seqPred ++
          " AND parent_identity = " ++ sqlEsc liveParent ++
          " AND directory_identity = " ++ sqlEsc liveDir ++
          " AND retired_at IS NULL;\n" ++
          "SELECT changes() AS chg, node_boot_epoch, claim_seq, retired_at FROM node_scratch WHERE id = " ++ sqlEsc scratchId ++ ";\n" ++
          "COMMIT;\n"
        let cliRes ← (IO.Process.output {
          cmd := "sqlite3"
          args := #["-json", "-cmd", s!".timeout {timeoutMs}", dbPath]
        } (input? := some cliSql)).toBaseIO
        let cliClaimed ←
          if !scratchDir.isEmpty && !claimDir.isEmpty then (System.FilePath.mk claimDir).pathExists
          else pure false
        match cliRes with
        | .ok cout =>
          if cout.exitCode == 0 then
            let rows := match OrbBin.Json.parse cout.stdout with
              | .ok (.arr rs) => rs
              | _ => #[]
            let some row := rows[0]? | do
              if cliClaimed && !(← (System.FilePath.mk scratchDir).pathExists) then
                discard <| (IO.FS.rename claimDir scratchDir).toBaseIO
              return .error "scratch_receipt_missing"
            let chg := (row.fieldUInt64? "chg").getD 0
            if chg > 0 then
              if cliClaimed then
                let postParent := (← readPathIdentity? parentPath).getD ""
                let postDir := (← readPathIdentity? claimDir).getD ""
                if postParent != liveParent || postDir != liveDir then
                  discard <| runSqliteStdinWithRetry .cli dbPath
                    s!"BEGIN IMMEDIATE; UPDATE node_scratch SET retired_at = NULL WHERE id = {sqlEsc scratchId} AND node_boot_epoch = {preBoot} AND claim_seq = {preSeq} AND parent_identity = {sqlEsc liveParent} AND directory_identity = {sqlEsc liveDir}; COMMIT;"
                    1500 2
                  if !(← (System.FilePath.mk scratchDir).pathExists) then
                    discard <| (IO.FS.rename claimDir scratchDir).toBaseIO
                  return .error "scratch_identity_mismatch"
                return .ok true
              else if !scratchDir.isEmpty && !claimDir.isEmpty then
                discard <| runSqliteStdinWithRetry .cli dbPath
                  s!"BEGIN IMMEDIATE; UPDATE node_scratch SET retired_at = NULL WHERE id = {sqlEsc scratchId} AND node_boot_epoch = {preBoot} AND claim_seq = {preSeq} AND parent_identity = {sqlEsc liveParent} AND directory_identity = {sqlEsc liveDir}; COMMIT;"
                  1500 2
                return .error "scratch_identity_mismatch"
              else
                return .ok false
            let rowBoot := (row.fieldUInt64? "node_boot_epoch").getD 0
            let rowSeq := (row.fieldUInt64? "claim_seq").getD 0
            if cliClaimed && !(← (System.FilePath.mk scratchDir).pathExists) then
              discard <| (IO.FS.rename claimDir scratchDir).toBaseIO
            if (row.fieldStr? "retired_at").isSome &&
               (expectedBootEpoch == 0 || rowBoot == expectedBootEpoch) &&
               (expectedClaimSeq == 0 || rowSeq == expectedClaimSeq) then
              return .ok false
            return .error "scratch_identity_mismatch"
          else
            if cliClaimed && !(← (System.FilePath.mk scratchDir).pathExists) then
              discard <| (IO.FS.rename claimDir scratchDir).toBaseIO
            lastErr := cout.stderr.trimAscii.toString
        | .error ce =>
          if cliClaimed && !(← (System.FilePath.mk scratchDir).pathExists) then
            discard <| (IO.FS.rename claimDir scratchDir).toBaseIO
          lastErr := toString ce
      else
        lastErr := toString pyIoErr
    if i + 1 < attempts && (lastErr.toLower.splitOn "locked").length > 1 then
      IO.sleep ((i + 1) * 150).toUInt32
    else
      break
  return .error lastErr

private def legacyJobAdditiveAlters : Array String := #[
  "ALTER TABLE jobs ADD COLUMN authority_mode TEXT NOT NULL DEFAULT 'writer';",
  "ALTER TABLE jobs ADD COLUMN placement_kind TEXT NOT NULL DEFAULT 'managed';",
  "ALTER TABLE jobs ADD COLUMN superseded_by_mission_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE jobs ADD COLUMN orphaned_at TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE jobs ADD COLUMN reserved_disk_gib INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE jobs ADD COLUMN state_revision INTEGER NOT NULL DEFAULT 1;",
  "ALTER TABLE jobs ADD COLUMN operation_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE jobs ADD COLUMN node_boot_epoch INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE jobs ADD COLUMN pid INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE jobs ADD COLUMN start_ticks INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE jobs ADD COLUMN phase_code INTEGER NOT NULL DEFAULT 1;",
  "ALTER TABLE jobs ADD COLUMN proc_phase INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE node_scratch ADD COLUMN node_boot_epoch INTEGER NOT NULL DEFAULT 1;",
  "ALTER TABLE node_scratch ADD COLUMN claim_seq INTEGER NOT NULL DEFAULT 1;"
]

private def ensureLegacySqliteSchema (workDir : String) (backend : SqliteBackend) : IO (Except String Unit) := do
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let ddl :=
    "PRAGMA journal_mode=WAL; " ++
    "CREATE TABLE IF NOT EXISTS node_boot_state (singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1), boot_epoch INTEGER NOT NULL DEFAULT 1); " ++
    "CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, payload_json TEXT NOT NULL, state TEXT NOT NULL, exit_code INTEGER, created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT, log_path TEXT, error TEXT, artifacts_json TEXT, cancellation_json TEXT, authority_mode TEXT NOT NULL DEFAULT 'writer', placement_kind TEXT NOT NULL DEFAULT 'managed', superseded_by_mission_id TEXT NOT NULL DEFAULT '', orphaned_at TEXT NOT NULL DEFAULT '', reserved_disk_gib INTEGER NOT NULL DEFAULT 0, state_revision INTEGER NOT NULL DEFAULT 1, operation_id TEXT NOT NULL DEFAULT '', node_boot_epoch INTEGER NOT NULL DEFAULT 0, pid INTEGER NOT NULL DEFAULT 0, start_ticks INTEGER NOT NULL DEFAULT 0, phase_code INTEGER NOT NULL DEFAULT 1, proc_phase INTEGER NOT NULL DEFAULT 0); " ++
    "CREATE TABLE IF NOT EXISTS node_scratch (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, job_id TEXT, node_boot_epoch INTEGER NOT NULL DEFAULT 1, claim_seq INTEGER NOT NULL DEFAULT 1, parent_identity TEXT NOT NULL, directory_identity TEXT NOT NULL, retired_at TEXT); " ++
    "CREATE TABLE IF NOT EXISTS container_leaders (workspace_id TEXT NOT NULL, machine_name TEXT NOT NULL, leader_pid INTEGER NOT NULL, start_ticks INTEGER NOT NULL, node_boot_epoch INTEGER NOT NULL, proc_phase INTEGER NOT NULL DEFAULT 1, job_id TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '', PRIMARY KEY (workspace_id, machine_name));"
  if let .error e ← runSqliteStdinWithRetry backend dbPath ddl 5000 3 then
    return .error e
  for alt in legacyJobAdditiveAlters do
    match ← runSqliteStdin backend dbPath alt 5000 with
    | .ok () => pure ()
    | .error e =>
      if (e.toLower.splitOn "duplicate column name").length ≤ 1 then
        return .error e
  return .ok ()

private def allocateNextNodeBootEpoch
    (workDir : String) (backend : SqliteBackend) (explicitEpoch : UInt64 := 0) :
    IO (Except String UInt64) := do
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let updSql :=
    if explicitEpoch != 0 then
      s!"BEGIN IMMEDIATE; INSERT INTO node_boot_state(singleton_id, boot_epoch) VALUES(1, {explicitEpoch}) ON CONFLICT(singleton_id) DO UPDATE SET boot_epoch = CASE WHEN {explicitEpoch} > node_boot_state.boot_epoch THEN {explicitEpoch} ELSE node_boot_state.boot_epoch END; COMMIT;"
    else
      "BEGIN IMMEDIATE; INSERT INTO node_boot_state(singleton_id, boot_epoch) VALUES(1, 1) ON CONFLICT(singleton_id) DO UPDATE SET boot_epoch = node_boot_state.boot_epoch + 1; COMMIT;"
  if let .error e ← runSqliteStdinWithRetry backend dbPath updSql 5000 4 then
    return .error s!"node_boot_epoch_bump_failed:{e}"
  if explicitEpoch != 0 then
    return .ok explicitEpoch
  match ← runSqliteQueryJson backend dbPath "SELECT boot_epoch FROM node_boot_state WHERE singleton_id = 1;" with
  | .error qe => return .error s!"node_boot_epoch_select_failed:{qe}"
  | .ok rows =>
    let ep := (rows[0]?.bind (·.fieldUInt64? "boot_epoch")).getD 1
    return .ok (if ep == 0 then 1 else ep)

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
  let opId := if r.operationId.isEmpty then r.jobId else r.operationId
  let ph := if r.phaseCode == 0 || r.phaseCode > 5 then defaultPhaseCodeForState r.state else r.phaseCode
  let pPh := if r.procPhase > 4 then 0 else r.procPhase
  "INSERT INTO jobs (id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json, authority_mode, placement_kind, superseded_by_mission_id, orphaned_at, reserved_disk_gib, state_revision, operation_id, node_boot_epoch, pid, start_ticks, phase_code, proc_phase) VALUES (" ++
  s!"{sqlEsc r.jobId}, {sqlEsc r.missionId}, {sqlEsc r.payloadJson}, {sqlEsc r.state.asString}, {exitSql}, {sqlEsc r.createdAt}, {sqlOptStr r.startedAt?}, {sqlOptStr r.finishedAt?}, {sqlOptStr r.logPath?}, {sqlOptStr r.error?}, {artsSql}, {cancSql}, {sqlEsc r.authorityMode}, {sqlEsc r.placementKind}, {sqlEsc r.supersededById}, {sqlEsc r.orphanedAt}, {r.reservedDiskGib}, {rev}, {sqlEsc opId}, {r.nodeBootEpoch}, {r.pid}, {r.startTicks}, {ph}, {pPh}) " ++
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
  "reserved_disk_gib = excluded.reserved_disk_gib, state_revision = excluded.state_revision, " ++
  "operation_id = excluded.operation_id, node_boot_epoch = excluded.node_boot_epoch, " ++
  "pid = excluded.pid, start_ticks = excluded.start_ticks, " ++
  "phase_code = CASE WHEN jobs.state IN ('succeeded', 'failed', 'cancelled') THEN jobs.phase_code ELSE excluded.phase_code END, " ++
  "proc_phase = excluded.proc_phase " ++
  "WHERE excluded.state_revision >= jobs.state_revision;"

def containerLeaderUpsertSql (c : ContainerLeaderRecord) : String :=
  "INSERT INTO container_leaders (workspace_id, machine_name, leader_pid, start_ticks, node_boot_epoch, proc_phase, job_id, updated_at) VALUES (" ++
  s!"{sqlEsc c.workspaceId}, {sqlEsc c.machineName}, {c.leaderPid}, {c.startTicks}, {c.nodeBootEpoch}, {c.procPhase}, {sqlEsc c.jobId}, {sqlEsc c.updatedAt}) " ++
  "ON CONFLICT(workspace_id, machine_name) DO UPDATE SET " ++
  "leader_pid = excluded.leader_pid, start_ticks = excluded.start_ticks, " ++
  "node_boot_epoch = excluded.node_boot_epoch, proc_phase = excluded.proc_phase, " ++
  "job_id = excluded.job_id, updated_at = excluded.updated_at;"

def scratchReceiptUpsertSql (s : ScratchReceipt) : String :=
  let bootEp := if s.nodeBootEpoch == 0 then 1 else s.nodeBootEpoch
  let cSeq := if s.claimSeq == 0 then 1 else s.claimSeq
  "INSERT INTO node_scratch (id, mission_id, job_id, node_boot_epoch, claim_seq, parent_identity, directory_identity, retired_at) VALUES (" ++
  s!"{sqlEsc s.id}, {sqlEsc s.missionId}, {sqlOptStr s.jobId?}, {bootEp}, {cSeq}, {sqlEsc s.parentIdentity}, {sqlEsc s.directoryIdentity}, {sqlOptStr s.retiredAt?}) " ++
  "ON CONFLICT(id) DO UPDATE SET " ++
  "node_boot_epoch = excluded.node_boot_epoch, claim_seq = excluded.claim_seq, " ++
  "parent_identity = excluded.parent_identity, directory_identity = excluded.directory_identity, " ++
  "retired_at = excluded.retired_at " ++
  "WHERE node_scratch.retired_at IS NOT NULL OR " ++
  "(node_scratch.node_boot_epoch = excluded.node_boot_epoch AND node_scratch.claim_seq = excluded.claim_seq);"

def createScratchDirAndReceipt
    (workDir id missionId : String) (jobId? : Option String)
    (nodeBootEpoch : UInt64 := 1) (claimSeq : UInt64 := 1) : IO (Except String (String × ScratchReceipt)) := do
  let scratchParent := (System.FilePath.mk workDir / ".scratch").toString
  IO.FS.createDirAll scratchParent
  let prefixTag := if jobId?.isSome then "job" else "exec"
  let scratchDir := (System.FilePath.mk scratchParent / s!"{prefixTag}-{id}").toString
  IO.FS.createDirAll scratchDir
  let (some parentId, some dirId) ← pure (← readPathIdentity? scratchParent, ← readPathIdentity? scratchDir)
    | discard <| (IO.Process.output { cmd := "rm", args := #["-rf", scratchDir] }).toBaseIO
      return .error "failed reading node_scratch directory identity"
  let bootEp := if nodeBootEpoch == 0 then 1 else nodeBootEpoch
  let cSeq := if claimSeq == 0 then 1 else claimSeq
  return .ok (scratchDir, {
    id := id
    missionId := missionId
    jobId? := jobId?
    nodeBootEpoch := bootEp
    claimSeq := cSeq
    parentIdentity := parentId
    directoryIdentity := dirId
    retiredAt? := none
  })

private def syncJobToLegacySqlite
    (workDir : String) (backend : SqliteBackend) (r : JobRecord)
    (timeoutMs : Nat := 5000) (attempts : Nat := 4)
    (extraSql : String := "") :
    IO (Except String Unit) := do
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let sql := "BEGIN IMMEDIATE; " ++ jobUpsertSql r ++
    (if extraSql.isEmpty then "" else " " ++ extraSql) ++ " COMMIT;"
  runSqliteStdinWithRetry backend dbPath sql timeoutMs attempts

/-- Import legacy SQLite `<work_dir>/jobs.db` rows idempotently when `jobs.db` exists. -/
private def importLegacySqliteJobs (workDir : String) (backend : SqliteBackend) : IO (Except String (Array JobRecord)) := do
  let dbPath : System.FilePath := System.FilePath.mk workDir / "jobs.db"
  if !(← dbPath.pathExists) then return .ok #[]
  let query :=
    "SELECT id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json, authority_mode, placement_kind, superseded_by_mission_id, orphaned_at, reserved_disk_gib, state_revision, operation_id, node_boot_epoch, pid, start_ticks, phase_code, proc_phase FROM jobs ORDER BY created_at ASC;"
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
      let rawPhase := ((row.fieldUInt64? "phase_code").getD 0).toUInt8
      let phaseCode := if rawPhase == 0 || rawPhase > 5 then defaultPhaseCodeForState state else rawPhase
      let opIdRaw := (row.fieldStr? "operation_id").getD ""
      let procPh := ((row.fieldUInt64? "proc_phase").getD 0).toUInt8
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
        operationId := if opIdRaw.isEmpty then id else opIdRaw
        nodeBootEpoch := (row.fieldUInt64? "node_boot_epoch").getD 0
        pid := (row.fieldUInt64? "pid").getD 0
        startTicks := (row.fieldUInt64? "start_ticks").getD 0
        phaseCode := phaseCode
        procPhase := if procPh > 4 then 0 else procPh
      }
  return .ok out

/-- Open `<work_dir>/orb-node.store`, require SQLite support for `jobs.db` compatibility and
    rolling-upgrade fencing (failing closed if unavailable), replay WAL, import/initialize `jobs.db`,
    and flip any in-flight (`queued` / `running`) job on daemon startup to `lost`. -/
def openLedger (workDir : String) (explicitBootEpoch : UInt64 := 0) : IO (Except String Ledger) := do
  IO.FS.createDirAll (System.FilePath.mk workDir / "logs")
  IO.FS.createDirAll (System.FilePath.mk workDir / ".scratch")
  IO.FS.createDirAll (System.FilePath.mk workDir / "uploads")
  let some sqliteBackend ← detectSqliteBackend
    | return .error "SQLite support (sqlite3 CLI or python3 sqlite3) is required before accepting node work"
  if let .error schemaErr ← ensureLegacySqliteSchema workDir sqliteBackend then
    return .error s!"jobs.db schema initialization failed: {schemaErr}"
  let liveBootEpoch ← match ← allocateNextNodeBootEpoch workDir sqliteBackend explicitBootEpoch with
    | .ok ep => pure ep
    | .error bootErr => return .error bootErr
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
    let nonTerminalOrStaleBoot :=
      !rec.state.isTerminal &&
      (rec.state == .queued || rec.state == .running || rec.nodeBootEpoch != liveBootEpoch)
    if nonTerminalOrStaleBoot then
      let canFlip := rec.state == .lost || canTransitionTo rec.state .lost
      if canFlip then
        let curRev := if rec.stateRevision == 0 then 1 else rec.stateRevision
        let lostRec : JobRecord := {
          rec with
          state := .lost
          phaseCode := 2
          procPhase := if rec.pid != 0 then rec.procPhase else 0
          finishedAt? := some (rec.finishedAt?.getD nowTs)
          error? := some (rec.error?.getD "node restarted while the job was in flight")
          stateRevision := if rec.state == .lost then curRev else curRev + 1
        }
        let serialized := renderCompact (lostRec.toJson none)
        if let .ok h' ← LeanSys.Store.putString h (jobKey jid) serialized then
          h := h'
          jobs := jobs.insert jid lostRec
          batchSql := batchSql ++ jobUpsertSql lostRec ++ " "
      else
        batchSql := batchSql ++ jobUpsertSql rec ++ " "
    else
      batchSql := batchSql ++ jobUpsertSql rec ++ " "
  batchSql := batchSql ++ s!"UPDATE container_leaders SET proc_phase = 2 WHERE node_boot_epoch != {liveBootEpoch} AND proc_phase != 2; COMMIT;"
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  if let .error syncErr ← runSqliteStdinWithRetry sqliteBackend dbPath batchSql 10000 4 then
    return .error s!"jobs.db startup reconciliation failed: {syncErr}"
  return .ok {
    workDir := workDir
    sqliteBackend := sqliteBackend
    nodeBootEpoch := liveBootEpoch
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

def insertQueued
    (l0 : Ledger) (rec0 : JobRecord)
    (scratch? : Option ScratchReceipt := none)
    (leader? : Option ContainerLeaderRecord := none) : IO (Except String Ledger) := do
  if rec0.authorityMode != "readonly" && rec0.authorityMode != "writer" then
    return .error s!"invalid_authority_mode:{rec0.authorityMode}"
  if rec0.reservedDiskGib > maxReservedDiskGib then
    return .error s!"invalid_reserved_disk_gib:{rec0.reservedDiskGib}"
  let l ← flushPendingSqlite l0
  if l.jobs.contains rec0.jobId then
    return .error "duplicate_job_id"
  let opId := if rec0.operationId.isEmpty then rec0.jobId else rec0.operationId
  let opBoot := if rec0.nodeBootEpoch == 0 then l.nodeBootEpoch else rec0.nodeBootEpoch
  let presentedTok := operationIdToken opId
  if Orb.ManagedNode.verifyRemoteJobAdmit 0 0 0 presentedTok opBoot l.nodeBootEpoch != 1 then
    return .error s!"job_claim_fence_rejected:boot={opBoot}:live={l.nodeBootEpoch}"
  let acceptedRec : JobRecord := {
    rec0 with
    operationId := opId
    nodeBootEpoch := l.nodeBootEpoch
    phaseCode := Orb.ManagedNode.remoteJobTargetPhase 0
  }
  let mut extraSql := ""
  if let some sc := scratch? then
    extraSql := extraSql ++ scratchReceiptUpsertSql sc ++ " "
  if let some cl := leader? then
    extraSql := extraSql ++ containerLeaderUpsertSql { cl with nodeBootEpoch := l.nodeBootEpoch } ++ " "
  if let .error e ← syncJobToLegacySqlite l.workDir l.sqliteBackend acceptedRec 1500 1 extraSql then
    return .error e
  let serialized := renderCompact (acceptedRec.toJson none)
  match ← LeanSys.Store.putString l.store (jobKey acceptedRec.jobId) serialized with
  | .error e =>
    let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
    let mut rbSql := s!"BEGIN IMMEDIATE; DELETE FROM jobs WHERE id = {sqlEsc acceptedRec.jobId}; "
    if let some sc := scratch? then
      rbSql := rbSql ++ s!"DELETE FROM node_scratch WHERE id = {sqlEsc sc.id}; "
    if let some cl := leader? then
      rbSql := rbSql ++ s!"DELETE FROM container_leaders WHERE workspace_id = {sqlEsc cl.workspaceId} AND machine_name = {sqlEsc cl.machineName} AND job_id = {sqlEsc acceptedRec.jobId}; "
    rbSql := rbSql ++ "COMMIT;"
    discard <| runSqliteStdinWithRetry l.sqliteBackend dbPath rbSql 5000 3
    return .error s!"WAL write failed: {repr e}"
  | .ok h' =>
    return .ok {
      l with
      store := h'
      jobs := l.jobs.insert acceptedRec.jobId acceptedRec
      order := l.order.push acceptedRec.jobId
    }

/-- Transition `jobId` to `nextState` under `Orb.Kernel.verifyJobTransition` (first terminal wins),
    `Orb.ManagedNode.verifyRemoteJobAdmit` (`SM-20` claim fence), and monotone `Orb.Kernel.epochFenceStep`
    revision bump (`SM-02`). -/
def updateJob
    (l0 : Ledger) (jobId : String)
    (mutate : JobRecord → Except String JobRecord)
    (extraSql : String := "") : IO (Except String (Ledger × JobRecord)) := do
  let l ← flushPendingSqlite l0
  let some cur := l.jobs.get? jobId
    | return .error "not_found"
  match mutate cur with
  | .error msg => return .error msg
  | .ok next0 =>
    if next0.state != cur.state && !canTransitionTo cur.state next0.state then
      return .ok (l, cur)
    let curPhase : UInt8 :=
      if cur.phaseCode == 0 || cur.phaseCode > 5 then defaultPhaseCodeForState cur.state else cur.phaseCode
    let heldOpStr := if cur.operationId.isEmpty then cur.jobId else cur.operationId
    let heldTok := operationIdToken heldOpStr
    let opBoot := if cur.nodeBootEpoch == 0 then l.nodeBootEpoch else cur.nodeBootEpoch
    let mut nextPhase :=
      if next0.phaseCode != 0 && next0.phaseCode != cur.phaseCode then next0.phaseCode
      else defaultPhaseCodeForState next0.state
    if next0.state != cur.state && opBoot == l.nodeBootEpoch then
      let gateOp? : Option UInt8 :=
        if curPhase == 1 then
          match next0.state with
          | .lost      => some 1
          | .succeeded => some 2
          | .failed    => some 3
          | .cancelled => some 4
          | _          => none
        else if curPhase == 2 then
          match next0.state with
          | .queued | .running => some 6
          | .succeeded         => some 7
          | .failed            => some 8
          | .cancelled         => some 9
          | .lost              => none
        else none
      if let some opCode := gateOp? then
        if Orb.ManagedNode.verifyRemoteJobAdmit curPhase opCode heldTok heldTok opBoot l.nodeBootEpoch != 1 then
          return .error s!"job_admit_rejected:phase={curPhase}:op={opCode}"
        nextPhase := Orb.ManagedNode.remoteJobTargetPhase opCode
    let curRev := if cur.stateRevision == 0 then 1 else cur.stateRevision
    let fenceWord := Orb.Kernel.epochFenceStep 1 1 1 1 1 1 curRev curRev 1
    let bumpedRev := if (fenceWord &&& 256) != 0 then (fenceWord >>> 32).toUInt32 else curRev + 1
    let next : JobRecord := {
      next0 with
      operationId := if next0.operationId.isEmpty then heldOpStr else next0.operationId
      nodeBootEpoch := if next0.nodeBootEpoch == 0 then opBoot else next0.nodeBootEpoch
      phaseCode := nextPhase
      stateRevision := bumpedRev
    }
    let serialized := renderCompact (next.toJson none)
    match ← LeanSys.Store.putString l.store (jobKey jobId) serialized with
    | .error e => return .error s!"WAL write failed: {repr e}"
    | .ok h' =>
      let nextPending ← match ← syncJobToLegacySqlite l.workDir l.sqliteBackend next 500 1 extraSql with
        | .ok () => pure (l.pendingSqliteSync.erase jobId)
        | .error _ => pure (l.pendingSqliteSync.insert jobId next)
      return .ok ({
        l with
        store := h'
        jobs := l.jobs.insert jobId next
        pendingSqliteSync := nextPending
      }, next)

/-- Apply an explicit `Orb.ManagedNode.JobOp` (`0..10`) to an existing job claim (`SM-20`),
    enforcing sticky `Uncertain` (`opCode = 5` blind retry always rejected) and same-boot fencing
    via `Orb.ManagedNode.stepJobSlice` / `Orb.ManagedNode.verifyRemoteJobAdmit`. -/
def stepJobClaim
    (l0 : Ledger) (jobId : String) (opCode : UInt8)
    (presentedOperationId : String) (presentedBootEpoch : UInt64)
    (nowTs : String) : IO (Except String (Ledger × JobRecord)) := do
  let l ← flushPendingSqlite l0
  let some cur := l.jobs.get? jobId
    | return .error "not_found"
  let curPhase : UInt8 :=
    if cur.phaseCode == 0 || cur.phaseCode > 5 then defaultPhaseCodeForState cur.state else cur.phaseCode
  let heldOpStr := if cur.operationId.isEmpty then cur.jobId else cur.operationId
  let heldTok := operationIdToken heldOpStr
  let presClean := presentedOperationId.trimAscii.toString
  let presTok :=
    if opCode == 10 then
      let rawTok := operationIdToken presClean
      if presClean != heldOpStr && rawTok ≤ heldTok && heldTok < 0xFFFFFFFFFFFFFFFF then
        heldTok + 1
      else rawTok
    else
      operationIdToken presClean
  let sliceIn : Orb.ManagedNode.JobSliceState := {
    phaseCode := curPhase
    operationId := heldTok
    operationBoot := cur.nodeBootEpoch
  }
  let ev : Orb.ManagedNode.JobSliceEvent := {
    opCode := opCode
    operationBootEpoch := presentedBootEpoch
    nodeBootEpoch := l.nodeBootEpoch
    presentedOperation := presTok
  }
  let (sliceOut, effs) := Orb.ManagedNode.stepJobSlice sliceIn ev
  if effs.isEmpty then
    return .error s!"claim_step_rejected:phase={curPhase}:op={opCode}:heldBoot={cur.nodeBootEpoch}:presBoot={presentedBootEpoch}:liveBoot={l.nodeBootEpoch}"
  let nextState : JobState :=
    match sliceOut.phaseCode with
    | 1 => if cur.state == .running then .running else .queued
    | 2 => .lost
    | 3 => .succeeded
    | 4 => .failed
    | 5 => .cancelled
    | _ => cur.state
  let nextOpStr := if opCode == 10 && !presClean.isEmpty then presClean else heldOpStr
  let curRev := if cur.stateRevision == 0 then 1 else cur.stateRevision
  let fenceWord := Orb.Kernel.epochFenceStep 1 1 1 1 1 1 curRev curRev 1
  let bumpedRev := if (fenceWord &&& 256) != 0 then (fenceWord >>> 32).toUInt32 else curRev + 1
  let isTerm := nextState.isTerminal
  let next : JobRecord := {
    cur with
    state := nextState
    operationId := nextOpStr
    nodeBootEpoch := sliceOut.operationBoot
    phaseCode := sliceOut.phaseCode
    finishedAt? := if isTerm || nextState == .lost then some (cur.finishedAt?.getD nowTs) else none
    error? := if nextState == .queued || nextState == .running then none else cur.error?
    stateRevision := bumpedRev
  }
  if let .error e ← syncJobToLegacySqlite l.workDir l.sqliteBackend next 1500 2 then
    return .error e
  let serialized := renderCompact (next.toJson none)
  match ← LeanSys.Store.putString l.store (jobKey jobId) serialized with
  | .error e => return .error s!"WAL write failed: {repr e}"
  | .ok h' =>
    return .ok ({
      l with
      store := h'
      jobs := l.jobs.insert jobId next
      pendingSqliteSync := l.pendingSqliteSync.erase jobId
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

def persistScratchReceipt (l : Ledger) (s : ScratchReceipt) : IO (Except String Unit) := do
  let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
  runSqliteStdinWithRetry l.sqliteBackend dbPath ("BEGIN IMMEDIATE; " ++ scratchReceiptUpsertSql s ++ " COMMIT;") 1500 2

def retireScratchReceipt
    (l : Ledger) (scratchId expectedParent expectedDir retiredAt : String)
    (scratchDirPath : String := "")
    (expectedBootEpoch : UInt64 := 0) (expectedClaimSeq : UInt64 := 0) : IO (Except String Unit) := do
  let idClean := scratchId.trimAscii.toString
  let parentClean := expectedParent.trimAscii.toString
  let dirClean := expectedDir.trimAscii.toString
  if idClean.isEmpty || parentClean.isEmpty || dirClean.isEmpty then
    return .error "scratch_identity_missing"
  let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
  let mut claimPath := ""
  if !scratchDirPath.isEmpty then
    let parentPath := (System.FilePath.mk scratchDirPath).parent.map (·.toString) |>.getD ""
    if parentPath.isEmpty then
      return .error "scratch_identity_missing"
    let nonce ← newUuidV4
    claimPath := (System.FilePath.mk parentPath / s!".retire-{idClean}-{nonce}").toString
  match ← runClaimRetireScratchTx l.sqliteBackend dbPath idClean scratchDirPath claimPath
      parentClean dirClean expectedBootEpoch expectedClaimSeq retiredAt 1500 2 with
  | .error e => return .error e
  | .ok claimed =>
    if claimed && !claimPath.isEmpty then
      discard <| (IO.Process.output { cmd := "rm", args := #["-rf", claimPath] }).toBaseIO
    return .ok ()

def upsertContainerLeader (l : Ledger) (c0 : ContainerLeaderRecord) : IO (Except String Unit) := do
  let nowTs ← nowRfc3339
  let c : ContainerLeaderRecord := {
    c0 with
    nodeBootEpoch := if c0.nodeBootEpoch == 0 then l.nodeBootEpoch else c0.nodeBootEpoch
    updatedAt := if c0.updatedAt.isEmpty then nowTs else c0.updatedAt
  }
  let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
  runSqliteStdinWithRetry l.sqliteBackend dbPath ("BEGIN IMMEDIATE; " ++ containerLeaderUpsertSql c ++ " COMMIT;") 1500 2

def listContainerLeaders (l : Ledger) : IO (Except String (Array ContainerLeaderRecord)) := do
  let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
  match ← runSqliteQueryJson l.sqliteBackend dbPath
      "SELECT workspace_id, machine_name, leader_pid, start_ticks, node_boot_epoch, proc_phase, job_id, updated_at FROM container_leaders ORDER BY updated_at ASC;" with
  | .error qe => return .error qe
  | .ok rows =>
    let mut out : Array ContainerLeaderRecord := #[]
    for row in rows do
      if let some ws := row.fieldStr? "workspace_id" then
        if let some mn := row.fieldStr? "machine_name" then
          let ph := ((row.fieldUInt64? "proc_phase").getD 1).toUInt8
          out := out.push {
            workspaceId := ws
            machineName := mn
            leaderPid := ((row.fieldUInt64? "leader_pid").getD 0).toUInt32
            startTicks := (row.fieldUInt64? "start_ticks").getD 0
            nodeBootEpoch := (row.fieldUInt64? "node_boot_epoch").getD 0
            procPhase := if ph > 4 then 0 else ph
            jobId := (row.fieldStr? "job_id").getD ""
            updatedAt := (row.fieldStr? "updated_at").getD ""
          }
    return .ok out

def getScratchReceipt? (l : Ledger) (scratchId : String) : IO (Option ScratchReceipt) := do
  let dbPath := (System.FilePath.mk l.workDir / "jobs.db").toString
  let .ok rows ← runSqliteQueryJson l.sqliteBackend dbPath
      s!"SELECT id, mission_id, job_id, node_boot_epoch, claim_seq, parent_identity, directory_identity, retired_at FROM node_scratch WHERE id = {sqlEsc scratchId};"
    | return none
  let some row := rows[0]? | return none
  let some id := row.fieldStr? "id" | return none
  return some {
    id := id
    missionId := (row.fieldStr? "mission_id").getD ""
    jobId? := row.fieldStr? "job_id"
    nodeBootEpoch := (row.fieldUInt64? "node_boot_epoch").getD 1
    claimSeq := (row.fieldUInt64? "claim_seq").getD 1
    parentIdentity := (row.fieldStr? "parent_identity").getD ""
    directoryIdentity := (row.fieldStr? "directory_identity").getD ""
    retiredAt? := row.fieldStr? "retired_at"
  }

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

def retireScratchOutsideLedger
    (workDir : String) (backend : SqliteBackend)
    (scratchId scratchDirPath : String)
    (expectedBootEpoch : UInt64 := 0) (expectedClaimSeq : UInt64 := 0)
    (forceCliFallback : Bool := false) : IO Bool := do
  let idClean := scratchId.trimAscii.toString
  if idClean.isEmpty || scratchDirPath.isEmpty then
    return false
  let parentPath := (System.FilePath.mk scratchDirPath).parent.map (·.toString) |>.getD ""
  if parentPath.isEmpty then
    return false
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let nonce ← newUuidV4
  let claimPath := (System.FilePath.mk parentPath / s!".retire-{idClean}-{nonce}").toString
  let nowTs ← nowRfc3339
  match ← runClaimRetireScratchTx backend dbPath idClean scratchDirPath claimPath
      "" "" expectedBootEpoch expectedClaimSeq nowTs 2500 3 forceCliFallback with
  | .error _ => return false
  | .ok claimed =>
    if claimed then
      discard <| (IO.Process.output { cmd := "rm", args := #["-rf", claimPath] }).toBaseIO
    return true

/-- Fence synchronous `POST /execute` admission against `rolling_upgrade_nodes.py`'s `BEGIN IMMEDIATE`
    transaction on `jobs.db`: creates a per-execute scratch directory, captures `(parent_identity, directory_identity)`
    and inserts BOTH the temporary `running` row and the `node_scratch` receipt in one `BEGIN IMMEDIATE`
    transaction before execution starts (failing closed if `jobs.db` is write-locked), then verifies identity
    and retires `node_scratch` on completion. -/
def acquireExecFenceReceipt
    (workDir : String) (backend : SqliteBackend) (execId missionId : String)
    (nodeBootEpoch : UInt64 := 1) : IO (Except String String) := do
  let scratchParent := (System.FilePath.mk workDir / ".scratch").toString
  let scratchDir := (System.FilePath.mk scratchParent / s!"exec-{execId}").toString
  IO.FS.createDirAll scratchDir
  let (some parentId, some dirId) ← pure (← readPathIdentity? scratchParent, ← readPathIdentity? scratchDir)
    | discard <| (IO.Process.output { cmd := "rm", args := #["-rf", scratchDir] }).toBaseIO
      return .error "failed reading node_scratch directory identity"
  let nowTs ← nowRfc3339
  let bootEp := if nodeBootEpoch == 0 then 1 else nodeBootEpoch
  let execRec : JobRecord := {
    jobId := execId
    missionId := missionId
    payloadJson := "{\"kind\":\"sync_execute\"}"
    state := .running
    createdAt := nowTs
    startedAt? := some nowTs
    operationId := execId
    nodeBootEpoch := bootEp
    phaseCode := 1
  }
  let sc : ScratchReceipt := {
    id := execId
    missionId := missionId
    jobId? := some execId
    nodeBootEpoch := bootEp
    claimSeq := operationIdToken execId
    parentIdentity := parentId
    directoryIdentity := dirId
    retiredAt? := none
  }
  match ← syncJobToLegacySqlite workDir backend execRec 1500 1 (scratchReceiptUpsertSql sc) with
  | .ok () => return .ok scratchDir
  | .error e =>
    discard <| (IO.Process.output { cmd := "rm", args := #["-rf", scratchDir] }).toBaseIO
    return .error e

def releaseExecFenceReceipt
    (workDir : String) (backend : SqliteBackend) (execId missionId : String)
    (scratchDir : String := "") (nodeBootEpoch : UInt64 := 0) : IO Unit := do
  let effDir :=
    if scratchDir.isEmpty then (System.FilePath.mk workDir / ".scratch" / s!"exec-{execId}").toString
    else scratchDir
  discard <| retireScratchOutsideLedger workDir backend execId effDir nodeBootEpoch (operationIdToken execId)
  let dbPath := (System.FilePath.mk workDir / "jobs.db").toString
  let sql := s!"BEGIN IMMEDIATE; DELETE FROM jobs WHERE id = {sqlEsc execId} AND mission_id = {sqlEsc missionId}; COMMIT;"
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
