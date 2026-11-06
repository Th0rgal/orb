/-
  OrbCore.Store: Parameterized SQLite Mission, Transfer, Project, Ask & Idempotency Store
  (`0 import Lean`, `0 sorryAx`) for Wave 4 Core Gateway (`sandboxed-sh`).
  Opens existing `missions.db` / `missions-*.db` / `projects.db` / `ask.db` / `idempotency_keys.db`
  in-place with WAL journaling and positional `?1..?N` bindings.
-/
import OrbCore.Spec

namespace OrbCore.Store

open OrbCore.Spec

@[extern "orb_sqlite_open"]
opaque sqliteOpenRaw (path : @& String) : IO UInt64

@[extern "orb_sqlite_close"]
opaque sqliteCloseRaw (handle : UInt64) : IO Unit

@[extern "orb_sqlite_exec"]
opaque sqliteExecRaw (handle : UInt64) (sql : @& String) : IO (Except String Unit)

@[extern "orb_sqlite_query_rows"]
opaque sqliteQueryRowsRaw (handle : UInt64) (sql : @& String) (params : @& Array String) : IO (Except String (Array (Array String)))

@[extern "orb_core_epoch_sec"]
opaque coreEpochSec : IO UInt64

/-- Typed SQLite handle opened in WAL mode. -/
structure SqliteDb where
  handle : UInt64
  path   : String
  deriving Repr, DecidableEq

/-- Conversation turn history entry (`pub history: Vec<MissionHistoryEntry>,` capability parity). -/
structure MissionHistoryEntry where
  role        : String
  content     : String
  thinking    : String := ""
  costCents   : UInt64 := 0
  createdAt   : String := ""
  deriving Repr, DecidableEq

/-- Persisted mission summary record (`history: Array MissionHistoryEntry` & `total_cost_cents`). -/
structure MissionRecord where
  id               : String
  title            : String
  status           : String
  backend          : String
  modelOverride    : String
  workingDirectory : String
  updatedAt        : String
  totalCostCents   : UInt64 := 0
  history          : Array MissionHistoryEntry := #[]
  deriving Repr, DecidableEq

/-- Machine transfer state machine record (`machine_transfers`). -/
structure TransferRecord where
  id               : String
  missionId        : String
  requestKey       : String
  revision         : UInt64
  phase            : String
  destination      : String
  sourceRevision   : String
  sourceGeneration : UInt64
  generation       : UInt64
  createdAt        : String
  deriving Repr, DecidableEq

/-- Core SQLite database bundle across `missions.db`, `projects.db`, `ask.db`, and `idempotency_keys.db`. -/
structure CoreStore where
  rootDir       : String
  missionsDb    : SqliteDb
  projectsDb    : SqliteDb
  askDb         : SqliteDb
  idempotencyDb : SqliteDb

def transferSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS machine_transfers (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, request_key TEXT NOT NULL, revision INTEGER NOT NULL, phase TEXT NOT NULL, data TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(mission_id,request_key)); CREATE UNIQUE INDEX IF NOT EXISTS one_machine_transfer ON machine_transfers(mission_id) WHERE phase NOT IN ('activated','cancelled');"

def transferCleanupSql : String :=
  "BEGIN IMMEDIATE;\n" ++
  "CREATE TRIGGER IF NOT EXISTS cancel_machine_transfers_after_mission_delete\n" ++
  "AFTER DELETE ON missions\n" ++
  "BEGIN\n" ++
  "    UPDATE machine_transfers\n" ++
  "    SET phase = 'cancelled',\n" ++
  "        data = json_set(data, '$.phase', 'cancelled', '$.revision', revision + 1),\n" ++
  "        revision = revision + 1\n" ++
  "    WHERE mission_id = OLD.id AND phase NOT IN ('activated', 'cancelled');\n" ++
  "END;\n" ++
  "UPDATE machine_transfers\n" ++
  "SET phase = 'cancelled',\n" ++
  "    data = json_set(data, '$.phase', 'cancelled', '$.revision', revision + 1),\n" ++
  "    revision = revision + 1\n" ++
  "WHERE phase NOT IN ('activated', 'cancelled')\n" ++
  "  AND NOT EXISTS (SELECT 1 FROM missions WHERE missions.id = machine_transfers.mission_id);\n" ++
  "COMMIT;"

def missionsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS missions (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'awaiting_user', backend TEXT NOT NULL DEFAULT 'codex', model_override TEXT, model_effort TEXT, working_directory TEXT NOT NULL DEFAULT '', requires_local_disk INTEGER NOT NULL DEFAULT 0, tags TEXT NOT NULL DEFAULT '[]', session_id TEXT, deferred_goal TEXT, workspace_id TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000', terminal_reason TEXT, updated_at TEXT NOT NULL DEFAULT '', opened_at TEXT, agent TEXT, config_profile TEXT, total_cost_cents INTEGER NOT NULL DEFAULT 0, history_json TEXT NOT NULL DEFAULT '[]');" ++
  "CREATE TABLE IF NOT EXISTS mission_runs (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 1, execution_state TEXT NOT NULL DEFAULT 'terminal', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_events (id INTEGER PRIMARY KEY AUTOINCREMENT, mission_id TEXT NOT NULL, seq INTEGER NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_automations (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, cron_expr TEXT NOT NULL, prompt TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS model_routing_chains (id TEXT PRIMARY KEY, name TEXT NOT NULL, models_json TEXT NOT NULL DEFAULT '[]', updated_at TEXT NOT NULL DEFAULT '');" ++
  transferSchemaSql ++ "\n" ++ transferCleanupSql

def projectsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, root_path TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS project_grant (slug TEXT PRIMARY KEY, merge_authority TEXT, budget_per_tick TEXT, parallel_missions INTEGER, pause_reason TEXT, resume_condition TEXT, material_bar TEXT, autonomy_level TEXT, updated_at TEXT NOT NULL DEFAULT '');"

def upsertProjectGrantSql : String :=
  "INSERT INTO project_grant (slug, merge_authority, budget_per_tick, parallel_missions, pause_reason, resume_condition, material_bar, autonomy_level, updated_at) " ++
  "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) " ++
  "ON CONFLICT(slug) DO UPDATE SET " ++
  "merge_authority = COALESCE(excluded.merge_authority, project_grant.merge_authority), " ++
  "budget_per_tick = COALESCE(excluded.budget_per_tick, project_grant.budget_per_tick), " ++
  "parallel_missions = COALESCE(excluded.parallel_missions, project_grant.parallel_missions), " ++
  "pause_reason = COALESCE(excluded.pause_reason, project_grant.pause_reason), " ++
  "resume_condition = COALESCE(excluded.resume_condition, project_grant.resume_condition), " ++
  "material_bar = COALESCE(excluded.material_bar, project_grant.material_bar), " ++
  "autonomy_level = COALESCE(excluded.autonomy_level, project_grant.autonomy_level), " ++
  "updated_at = excluded.updated_at;"

def askSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS ask_requests (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, question TEXT NOT NULL, answer TEXT, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL DEFAULT '');"

def idempotencySchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS idempotency_keys (scope TEXT NOT NULL, request_key TEXT NOT NULL, response_json TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(scope, request_key));"

def openSqliteDb (path : String) (ddl : String) : IO (Except String SqliteDb) := do
  let h ← sqliteOpenRaw path
  if h == 0 then
    return .error s!"sqlite_open_failed:{path}"
  match ← sqliteExecRaw h ddl with
  | .error e =>
    sqliteCloseRaw h
    return .error e
  | .ok () =>
    return .ok { handle := h, path := path }

/-- Open or initialize the full `CoreStore` SQLite bundle in `rootDir` (preserving existing DB files in-place). -/
def openCoreStore (rootDir : String) : IO (Except String CoreStore) := do
  IO.FS.createDirAll rootDir
  let mRes ← openSqliteDb s!"{rootDir}/missions.db" missionsSchemaSql
  let .ok mDb := mRes | return .error (match mRes with | .error e => e | .ok _ => "err")
  let pRes ← openSqliteDb s!"{rootDir}/projects.db" projectsSchemaSql
  let .ok pDb := pRes | do sqliteCloseRaw mDb.handle; return .error (match pRes with | .error e => e | .ok _ => "err")
  let aRes ← openSqliteDb s!"{rootDir}/ask.db" askSchemaSql
  let .ok aDb := aRes | do sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; return .error (match aRes with | .error e => e | .ok _ => "err")
  let iRes ← openSqliteDb s!"{rootDir}/idempotency_keys.db" idempotencySchemaSql
  let .ok iDb := iRes | do
    sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle
    return .error (match iRes with | .error e => e | .ok _ => "err")
  return .ok { rootDir := rootDir, missionsDb := mDb, projectsDb := pDb, askDb := aDb, idempotencyDb := iDb }

def closeCoreStore (st : CoreStore) : IO Unit := do
  sqliteCloseRaw st.missionsDb.handle
  sqliteCloseRaw st.projectsDb.handle
  sqliteCloseRaw st.askDb.handle
  sqliteCloseRaw st.idempotencyDb.handle

/-- Minimal RFC 8259 JSON string escaper. -/
def jsonEscape (s : String) : String := Id.run do
  let mut out := "\""
  for ch in s.toList do
    if ch == '"' then out := out ++ "\\\""
    else if ch == '\\' then out := out ++ "\\\\"
    else if ch == '\n' then out := out ++ "\\n"
    else if ch == '\r' then out := out ++ "\\r"
    else if ch == '\t' then out := out ++ "\\t"
    else out := out.push ch
  return out ++ "\""

/-- Convert `(headerRow + dataRows)` from `sqliteQueryRowsRaw` into a JSON array of objects. -/
def rowsToJsonArray (rows : Array (Array String)) : String :=
  if rows.size ≤ 1 then "[]"
  else Id.run do
    let hdr := rows[0]!
    let mut objs : Array String := Array.mkEmpty (rows.size - 1)
    for rIdx in [1:rows.size] do
      let r := rows[rIdx]!
      let mut kvs : Array String := Array.mkEmpty hdr.size
      for cIdx in [0:hdr.size] do
        let k := hdr[cIdx]!
        let v := if cIdx < r.size then r[cIdx]! else ""
        kvs := kvs.push s!"{jsonEscape k}:{jsonEscape v}"
      objs := objs.push ("{" ++ String.intercalate "," kvs.toList ++ "}")
    return "[" ++ String.intercalate "," objs.toList ++ "]"

def execParamQuery (db : SqliteDb) (sql : String) (params : Array String) : IO (Except String (Array (Array String))) :=
  sqliteQueryRowsRaw db.handle sql params

/-- Upsert a mission record into `missions.db`. -/
def upsertMission (st : CoreStore) (m : MissionRecord) : IO (Except String Unit) := do
  let sql := "INSERT INTO missions(id,title,status,backend,model_override,working_directory,updated_at,total_cost_cents) VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(id) DO UPDATE SET title=excluded.title,status=excluded.status,backend=excluded.backend,model_override=excluded.model_override,working_directory=excluded.working_directory,updated_at=excluded.updated_at,total_cost_cents=excluded.total_cost_cents;"
  let res ← execParamQuery st.missionsDb sql #[
    m.id, m.title, m.status, m.backend, m.modelOverride, m.workingDirectory, m.updatedAt, s!"{m.totalCostCents}"
  ]
  return res.map (fun _ => ())

/-- Record mission opened timestamp (`mark_mission_opened` capability parity). -/
def mark_mission_opened (st : CoreStore) (missionId openedAt : String) : IO (Except String Unit) := do
  let res ← execParamQuery st.missionsDb
    "UPDATE missions SET opened_at=?2, updated_at=?2 WHERE id=?1;" #[missionId, openedAt]
  return res.map (fun _ => ())

/-- List missions from `missions.db` as JSON, preserving `total_cost_cents` telemetry. -/
def listMissionsJson (st : CoreStore) : IO (Except String String) := do
  let rows ← execParamQuery st.missionsDb
    "SELECT id,title,status,backend,COALESCE(model_override,'') AS model_override,working_directory,updated_at,total_cost_cents FROM missions ORDER BY updated_at DESC, id ASC;" #[]
  return rows.map (fun rs =>
    if rs.size ≤ 1 then "[]"
    else Id.run do
      let mut items : Array String := #[]
      for i in [1:rs.size] do
        let r := rs[i]!
        let c0 := r[0]?.getD ""
        let c1 := r[1]?.getD ""
        let c2 := r[2]?.getD ""
        let c3 := r[3]?.getD ""
        let c4 := r[4]?.getD ""
        let c5 := r[5]?.getD ""
        let c6 := r[6]?.getD ""
        let total_cost_cents := (r[7]?.bind String.toNat?).getD 0
        items := items.push s!"\{\"id\":{jsonEscape c0},\"title\":{jsonEscape c1},\"status\":{jsonEscape c2},\"backend\":{jsonEscape c3},\"model_override\":{jsonEscape c4},\"working_directory\":{jsonEscape c5},\"updated_at\":{jsonEscape c6},\"total_cost_cents\":{total_cost_cents}}"
      return "[" ++ String.intercalate "," items.toList ++ "]")

/-- Check whether `status` permits starting a machine transfer. -/
def isStatusMovable (status : String) : Bool :=
  status == "awaiting_user" || status == "completed" || status == "failed" ||
  status == "interrupted" || status == "paused" || status == "blocked" ||
  status == "not_feasible" || status == "acknowledged"

/-- Fence-checked machine-transfer initiation gated by `verifyTransferFence` (`OrbCore.Spec`). -/
def startMachineTransfer (st : CoreStore) (t : TransferRecord) : IO (Except String TransferRecord) := do
  let activeRows ← execParamQuery st.missionsDb
    "SELECT COUNT(*) FROM machine_transfers WHERE mission_id=?1 AND phase NOT IN ('activated','cancelled');" #[t.missionId]
  let .ok ar := activeRows | return .error "transfer_active_query_failed"
  let activeCnt := ((ar[1]?.bind (·[0]?)).bind String.toNat?).getD 1
  let runRows ← execParamQuery st.missionsDb
    "SELECT COUNT(*), COALESCE(MAX(generation),0) FROM mission_runs WHERE mission_id=?1 AND execution_state<>'terminal';" #[t.missionId]
  let .ok rr := runRows | return .error "transfer_runs_query_failed"
  let nonTermCnt := ((rr[1]?.bind (·[0]?)).bind String.toNat?).getD 1
  let genRows ← execParamQuery st.missionsDb
    "SELECT COALESCE(MAX(generation),0) FROM mission_runs WHERE mission_id=?1;" #[t.missionId]
  let .ok gr := genRows | return .error "transfer_gen_query_failed"
  let storedGen := (((gr[1]?.bind (·[0]?)).bind String.toNat?).getD 0).toUInt64
  let mRows ← execParamQuery st.missionsDb
    "SELECT status, updated_at FROM missions WHERE id=?1;" #[t.missionId]
  let .ok mr := mRows | return .error "transfer_mission_query_failed"
  if mr.size ≤ 1 then return .error "mission_not_found"
  let status := (mr[1]?.bind (·[0]?)).getD ""
  let rev := (mr[1]?.bind (·[1]?)).getD ""
  let movable : UInt8 := if isStatusMovable status && rev == t.sourceRevision then 1 else 0
  let activeFlag : UInt8 := if activeCnt > 0 then 1 else 0
  let nonTermFlag : UInt8 := if nonTermCnt > 0 then 1 else 0
  if verifyTransferFence activeFlag nonTermFlag 0 movable storedGen t.sourceGeneration != 1 then
    return .error "Machine transfer fenced or source state changed"
  let nextGen := storedGen + 1
  let outRec := { t with generation := nextGen, revision := 0 }
  let dataJson := s!"\{\"id\":{jsonEscape outRec.id},\"mission_id\":{jsonEscape outRec.missionId},\"phase\":{jsonEscape outRec.phase},\"destination\":{jsonEscape outRec.destination},\"generation\":{outRec.generation}}"
  let ins ← execParamQuery st.missionsDb
    "INSERT INTO machine_transfers(id,mission_id,request_key,revision,phase,data,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7);"
    #[outRec.id, outRec.missionId, outRec.requestKey, "0", outRec.phase, dataJson, outRec.createdAt]
  match ins with
  | .error e => return .error e
  | .ok _ => return .ok outRec

/-- Idempotency key read-or-insert (`idempotency_keys.db`). -/
def checkOrStoreIdempotency (st : CoreStore) (scope reqKey responseJson createdAt : String) : IO (Except String String) := do
  let existing ← execParamQuery st.idempotencyDb
    "SELECT response_json FROM idempotency_keys WHERE scope=?1 AND request_key=?2;" #[scope, reqKey]
  match existing with
  | .error e => return .error e
  | .ok rows =>
    if rows.size > 1 then
      return .ok ((rows[1]?.bind (·[0]?)).getD "{}")
    let ins ← execParamQuery st.idempotencyDb
      "INSERT INTO idempotency_keys(scope,request_key,response_json,created_at) VALUES(?1,?2,?3,?4);"
      #[scope, reqKey, responseJson, createdAt]
    match ins with
    | .error e => return .error e
    | .ok _ => return .ok responseJson

end OrbCore.Store
