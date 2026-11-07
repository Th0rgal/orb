/-
  OrbCore.Store: Parameterized SQLite Mission, Transfer, Project, Privilege Lease, Ask &
  Idempotency Store (`0 import Lean`, `0 sorryAx`) for Wave 4 Core Gateway (`sandboxed-sh`).
  Opens existing `missions.db` / `projects.db` / `ask.db` / `idempotency_keys.db`
  in-place with WAL journaling and positional `?1..?N` bindings.
-/
import Std.Sync.Mutex
import Orb.Kernel
import OrbBin.Json
import OrbCore.Spec

namespace OrbCore.Store

open Orb.Kernel
open OrbBin.Json
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

/-- Typed SQLite handle opened in WAL mode with an exclusive `Std.Mutex` serializing C `sqlite3*` access. -/
structure SqliteDb where
  handle : UInt64
  path   : String
  mu     : Std.Mutex Unit

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
  modelEffort      : String := ""
  workingDirectory : String
  project          : String := ""
  updatedAt        : String
  totalCostCents   : UInt64 := 0
  authorityMode    : String := "writer"
  placementKind    : String := "managed"
  supersededById   : String := ""
  orphanedAt       : String := ""
  reservedDiskGib  : UInt64 := 0
  stateRevision    : UInt32 := 1
  ownerEpoch       : UInt64 := 1
  runGeneration    : UInt64 := 1
  nodeBootEpoch    : UInt64 := 1
  tagsJson         : String := "[]"
  track            : String := ""
  repo             : String := ""
  history          : Array MissionHistoryEntry := #[]
  deriving Repr, DecidableEq

/-- Authoritative terminal outcome receipt stored in `mission_terminal_evidence` (`SM-01`). -/
structure TerminalEvidenceRecord where
  missionId      : String
  terminalReason : String
  summary        : String := ""
  artifactRef    : String := ""
  verified       : Bool   := true
  recordedAt     : String
  deriving Repr, DecidableEq

/-- Durable effect outbox row (`effect_outbox`) gated by `Orb.Kernel.effectOutboxStep` (`R2-C`). -/
structure OutboxIntent where
  effectId      : String
  intentKind    : String
  payloadJson   : String
  attemptEpoch  : UInt64 := 1
  deriving Repr, DecidableEq

/-- Cross-DB two-phase track/repository lease reservation (`SM-08`). -/
structure DispatchLeaseRequest where
  reservationId     : String
  missionId         : String
  projectSlug       : String
  track             : String
  repo              : String := ""
  authorityMode     : String := "writer"
  reservedDiskGib   : UInt64 := 0
  freeDiskBytes     : UInt64 := 1099511627776
  bootEpoch         : UInt64 := 1
  nowAt             : String
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

/-- Hardware-approved JIT privilege lease record (`privilege_leases`). -/
structure PrivilegeLeaseRecord where
  grantId          : String
  leaseToken       : String
  missionId        : String
  targetHost       : String
  scope            : String
  allowedUnitsJson : String := "[]"
  requireForceCmd  : Bool   := false
  biometricSigned  : Bool   := true
  revoked          : Bool   := false
  expiresAtEpoch   : UInt64
  deriving Repr, DecidableEq

/-- Core SQLite database bundle across `missions.db`, `projects.db`, `ask.db`, and `idempotency_keys.db`. -/
structure CoreStore where
  rootDir       : String
  bootEpoch     : UInt64 := 1
  missionsDb    : SqliteDb
  projectsDb    : SqliteDb
  askDb         : SqliteDb
  idempotencyDb : SqliteDb
  closedRef     : IO.Ref Bool

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
  "CREATE TABLE IF NOT EXISTS missions (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'awaiting_user', backend TEXT NOT NULL DEFAULT 'codex', model_override TEXT, model_effort TEXT, working_directory TEXT NOT NULL DEFAULT '', project TEXT NOT NULL DEFAULT '', requires_local_disk INTEGER NOT NULL DEFAULT 0, tags TEXT NOT NULL DEFAULT '[]', session_id TEXT, deferred_goal TEXT, workspace_id TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000', terminal_reason TEXT, updated_at TEXT NOT NULL DEFAULT '', opened_at TEXT, agent TEXT, config_profile TEXT, total_cost_cents INTEGER NOT NULL DEFAULT 0, history_json TEXT NOT NULL DEFAULT '[]', authority_mode TEXT NOT NULL DEFAULT 'writer' CHECK(authority_mode IN ('readonly','writer')), placement_kind TEXT NOT NULL DEFAULT 'managed', superseded_by_mission_id TEXT NOT NULL DEFAULT '', orphaned_at TEXT NOT NULL DEFAULT '', reserved_disk_gib INTEGER NOT NULL DEFAULT 0, state_revision INTEGER NOT NULL DEFAULT 1, owner_epoch INTEGER NOT NULL DEFAULT 1, run_generation INTEGER NOT NULL DEFAULT 1, node_boot_epoch INTEGER NOT NULL DEFAULT 1, track TEXT NOT NULL DEFAULT '', repo TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_terminal_evidence (mission_id TEXT PRIMARY KEY, terminal_reason TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '', artifact_ref TEXT NOT NULL DEFAULT '', verified INTEGER NOT NULL DEFAULT 1, recorded_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS effect_outbox (effect_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, state_revision INTEGER NOT NULL, intent_kind TEXT NOT NULL, payload_json TEXT NOT NULL, phase INTEGER NOT NULL DEFAULT 0, delivered INTEGER NOT NULL DEFAULT 0, attempt_epoch INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS dispatch_lease_intents (reservation_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, project_slug TEXT NOT NULL, track TEXT NOT NULL, repo TEXT NOT NULL DEFAULT '', authority_mode TEXT NOT NULL DEFAULT 'writer', reserved_disk_gib INTEGER NOT NULL DEFAULT 0, phase TEXT NOT NULL DEFAULT 'preparing', boot_epoch INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_runs (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 1, execution_state TEXT NOT NULL DEFAULT 'terminal', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_events (id INTEGER PRIMARY KEY AUTOINCREMENT, mission_id TEXT NOT NULL, seq INTEGER NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_automations (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, cron_expr TEXT NOT NULL, prompt TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS model_routing_chains (id TEXT PRIMARY KEY, name TEXT NOT NULL, models_json TEXT NOT NULL DEFAULT '[]', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS privilege_leases (grant_id TEXT PRIMARY KEY, lease_token TEXT NOT NULL UNIQUE, mission_id TEXT NOT NULL, target_host TEXT NOT NULL, scope TEXT NOT NULL, allowed_units_json TEXT NOT NULL DEFAULT '[]', require_force_cmd INTEGER NOT NULL DEFAULT 0, biometric_signed INTEGER NOT NULL DEFAULT 1, revoked INTEGER NOT NULL DEFAULT 0, expires_at_epoch INTEGER NOT NULL DEFAULT 0);" ++
  "CREATE TABLE IF NOT EXISTS privilege_audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, grant_id TEXT NOT NULL, mission_id TEXT NOT NULL, target_host TEXT NOT NULL, executing_host TEXT NOT NULL, command TEXT NOT NULL, allowed INTEGER NOT NULL, created_at TEXT NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS core_boot_state (singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1), boot_epoch INTEGER NOT NULL DEFAULT 0);" ++
  "CREATE TABLE IF NOT EXISTS remote_message_queue (sequence INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, message_id TEXT NOT NULL, mission_id TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'waiting', UNIQUE(user_id,message_id));" ++
  "CREATE INDEX IF NOT EXISTS remote_message_pending ON remote_message_queue(state,sequence);" ++
  transferSchemaSql ++ "\n" ++ transferCleanupSql

def projectsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, root_path TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS project_grant (slug TEXT PRIMARY KEY, merge_authority TEXT, budget_per_tick TEXT, parallel_missions INTEGER, pause_reason TEXT, resume_condition TEXT, material_bar TEXT, autonomy_level TEXT, updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS project_track_leases (project_slug TEXT NOT NULL, track TEXT NOT NULL, reservation_id TEXT NOT NULL UNIQUE, mission_id TEXT NOT NULL, repo TEXT NOT NULL DEFAULT '', authority_mode TEXT NOT NULL DEFAULT 'writer', phase TEXT NOT NULL DEFAULT 'preparing', boot_epoch INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(project_slug, track, mission_id));"

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
  "CREATE TABLE IF NOT EXISTS idempotency_keys (scope TEXT NOT NULL, request_key TEXT NOT NULL, response_json TEXT NOT NULL, status_code INTEGER NOT NULL DEFAULT 200, committed_oversize INTEGER NOT NULL DEFAULT 0, body_bytes INTEGER NOT NULL DEFAULT 0, phase TEXT NOT NULL DEFAULT 'committed', created_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(scope, request_key));"

private def isIgnorableDuplicateColErr (msg : String) : Bool :=
  (msg.toLower.splitOn "duplicate column name").length > 1

/-- Execute additive `ALTER TABLE ... ADD COLUMN` statements, tolerating already-present columns
    while failing closed on persistent schema, corruption, or read-only errors (`SM-01`). -/
private def applyAdditiveAlters (h : UInt64) (alters : Array String) : IO (Except String Unit) := do
  for stmt in alters do
    match ← sqliteExecRaw h stmt with
    | .ok () => pure ()
    | .error e =>
      if !isIgnorableDuplicateColErr e then
        return .error e
  return .ok ()

def missionsAdditiveAlters : Array String := #[
  "ALTER TABLE missions ADD COLUMN project TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE missions ADD COLUMN authority_mode TEXT NOT NULL DEFAULT 'writer';",
  "ALTER TABLE missions ADD COLUMN placement_kind TEXT NOT NULL DEFAULT 'managed';",
  "ALTER TABLE missions ADD COLUMN superseded_by_mission_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE missions ADD COLUMN orphaned_at TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE missions ADD COLUMN reserved_disk_gib INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE missions ADD COLUMN state_revision INTEGER NOT NULL DEFAULT 1;",
  "ALTER TABLE missions ADD COLUMN owner_epoch INTEGER NOT NULL DEFAULT 1;",
  "ALTER TABLE missions ADD COLUMN run_generation INTEGER NOT NULL DEFAULT 1;",
  "ALTER TABLE missions ADD COLUMN node_boot_epoch INTEGER NOT NULL DEFAULT 1;",
  "ALTER TABLE missions ADD COLUMN track TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE missions ADD COLUMN repo TEXT NOT NULL DEFAULT '';"
]

def idempotencyAdditiveAlters : Array String := #[
  "ALTER TABLE idempotency_keys ADD COLUMN status_code INTEGER NOT NULL DEFAULT 200;",
  "ALTER TABLE idempotency_keys ADD COLUMN committed_oversize INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE idempotency_keys ADD COLUMN body_bytes INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE idempotency_keys ADD COLUMN phase TEXT NOT NULL DEFAULT 'committed';"
]

/-- Open a persistent SQLite database file and verify write durability (`BEGIN IMMEDIATE; ROLLBACK;`).
    Never accepts `:memory:` or `mode=memory` URIs unless `allowMemory == true`, and never falls back
    to an in-memory store on persistent open/migration failure (`SM-01`). -/
def openSqliteDb (path : String) (ddl : String) (alters : Array String := #[]) (allowMemory : Bool := false) : IO (Except String SqliteDb) := do
  let norm := path.trimAscii.toString
  if norm.isEmpty then
    return .error "sqlite_empty_path_rejected"
  if !allowMemory && (norm == ":memory:" || (norm.toLower.splitOn "mode=memory").length > 1) then
    return .error s!"sqlite_memory_fallback_forbidden:{path}"
  let h ← sqliteOpenRaw path
  if h == 0 then
    return .error s!"sqlite_open_failed:{path}"
  match ← sqliteExecRaw h ddl with
  | .error e =>
    sqliteCloseRaw h
    return .error e
  | .ok () =>
    match ← applyAdditiveAlters h alters with
    | .error ae =>
      sqliteCloseRaw h
      return .error ae
    | .ok () =>
      match ← sqliteExecRaw h "BEGIN IMMEDIATE; ROLLBACK;" with
      | .error we =>
        sqliteCloseRaw h
        return .error s!"sqlite_write_probe_failed:{we}"
      | .ok () =>
        let mu ← Std.Mutex.new ()
        return .ok { handle := h, path := path, mu := mu }

/-- Reconcile `dispatch_lease_intents` (`missions.db`) and `project_track_leases` (`projects.db`)
    deterministically on startup (`SM-08`), rolling back uncommitted `preparing` / `rejected` rows
    and clearing stale-boot leases without relying on ambient process mutexes or 6h TTL expiry. -/
def recoverDispatchLeases (mDb pDb : SqliteDb) (bootEpoch : UInt64 := 1) : IO (Except String Unit) := do
  let bootStr := s!"{bootEpoch}"
  let intentRows ← mDb.mu.atomically <|
    sqliteQueryRowsRaw mDb.handle
      "SELECT reservation_id,mission_id,project_slug,track,phase,boot_epoch,reserved_disk_gib FROM dispatch_lease_intents WHERE phase IN ('preparing','rejected') OR (phase='active' AND boot_epoch<>?1);"
      #[bootStr]
  let .ok rs := intentRows
    | return .error (match intentRows with | .error e => e | .ok _ => "lease_recovery_query_failed")
  for i in [1:rs.size] do
    let r := rs[i]!
    let rid := (r[0]?).getD ""
    let mid := (r[1]?).getD ""
    let phase := (r[4]?).getD "preparing"
    let recPhase : UInt8 := if phase == "preparing" || phase == "rejected" then 1 else 2
    let admWord := Orb.Kernel.admissionStep recPhase 0 0 0 0
    let mustRollback := ((admWord >>> 8) &&& 0xFF) == 1 || ((admWord >>> 16) &&& 0xFF) == 1
    if mustRollback then
      let pDel ← pDb.mu.atomically <|
        sqliteQueryRowsRaw pDb.handle
          "DELETE FROM project_track_leases WHERE reservation_id=?1;" #[rid]
      if let .error e := pDel then return .error e
      let mUpd ← mDb.mu.atomically <|
        sqliteQueryRowsRaw mDb.handle
          "UPDATE dispatch_lease_intents SET phase='rolled_back' WHERE reservation_id=?1;" #[rid]
      if let .error e := mUpd then return .error e
      let diskRel ← mDb.mu.atomically <|
        sqliteQueryRowsRaw mDb.handle
          "UPDATE missions SET reserved_disk_gib=0, state_revision=state_revision+1 WHERE id=?1 AND reserved_disk_gib>0;" #[mid]
      if let .error e := diskRel then return .error e
  let orphanProjs ← pDb.mu.atomically <|
    sqliteQueryRowsRaw pDb.handle
      "SELECT reservation_id,phase,boot_epoch FROM project_track_leases;"
      #[]
  let .ok ors := orphanProjs
    | return .error (match orphanProjs with | .error e => e | .ok _ => "project_lease_recovery_failed")
  for i in [1:ors.size] do
    let rid := (ors[i]![0]?).getD ""
    let projPhase := (ors[i]![1]?).getD ""
    let chk ← mDb.mu.atomically <|
      sqliteQueryRowsRaw mDb.handle
        "SELECT phase,boot_epoch FROM dispatch_lease_intents WHERE reservation_id=?1;" #[rid]
    let intentPhase := match chk with | .ok crs => (crs[1]?.bind (·[0]?)).getD "" | .error _ => ""
    let intentBoot := match chk with | .ok crs => (crs[1]?.bind (·[1]?)).getD "" | .error _ => ""
    if intentPhase == "active" && intentBoot == bootStr then
      if projPhase != "active" then
        let pProm ← pDb.mu.atomically <|
          sqliteQueryRowsRaw pDb.handle
            "UPDATE project_track_leases SET phase='active',boot_epoch=?2 WHERE reservation_id=?1;" #[rid, bootStr]
        if let .error e := pProm then return .error e
    else
      let pDel ← pDb.mu.atomically <|
        sqliteQueryRowsRaw pDb.handle "DELETE FROM project_track_leases WHERE reservation_id=?1;" #[rid]
      if let .error e := pDel then return .error e
  return .ok ()

/-- Atomically allocate and persist the next monotonic `boot_epoch` in `core_boot_state` (`missions.db`),
    ensuring every `runCoreServer` / auto-epoch `openCoreStore` start increments `node_boot_epoch`. -/
private def allocateNextBootEpoch (mDb : SqliteDb) : IO (Except String UInt64) :=
  mDb.mu.atomically do
    if let .error e ← sqliteExecRaw mDb.handle "BEGIN IMMEDIATE;" then
      return .error s!"boot_epoch_begin_failed:{e}"
    if let .error e ← sqliteExecRaw mDb.handle
      "INSERT INTO core_boot_state(singleton_id,boot_epoch) VALUES(1,1) ON CONFLICT(singleton_id) DO UPDATE SET boot_epoch=core_boot_state.boot_epoch+1;" then
      discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
      return .error s!"boot_epoch_bump_failed:{e}"
    let q ← sqliteQueryRowsRaw mDb.handle "SELECT boot_epoch FROM core_boot_state WHERE singleton_id=1;" #[]
    match q with
    | .error qe =>
      discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
      return .error s!"boot_epoch_select_failed:{qe}"
    | .ok rs =>
      let ep := ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 1
      if let .error ce ← sqliteExecRaw mDb.handle "COMMIT;" then
        discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
        return .error s!"boot_epoch_commit_failed:{ce}"
      return .ok ep.toUInt64

/-- Open or initialize the full `CoreStore` SQLite bundle in `rootDir` (preserving existing DB files in-place
    and failing closed on any persistent open/schema/recovery failure without in-memory fallback).
    When `bootEpoch == 0` (the default), atomically increments and persists `boot_epoch` in `core_boot_state`. -/
def openCoreStore (rootDir : String) (bootEpoch : UInt64 := 0) : IO (Except String CoreStore) := do
  let trimmedRoot := rootDir.trimAscii.toString
  if trimmedRoot.isEmpty || trimmedRoot == ":memory:" then
    return .error "core_store_invalid_root"
  let createRes ← (IO.FS.createDirAll trimmedRoot).toBaseIO
  if let .error ioErr := createRes then
    return .error s!"core_store_mkdir_failed:{ioErr}"
  let mRes ← openSqliteDb s!"{trimmedRoot}/missions.db" missionsSchemaSql missionsAdditiveAlters
  let .ok mDb := mRes | return .error (match mRes with | .error e => e | .ok _ => "err")
  let effBootRes : Except String UInt64 ←
    if bootEpoch == 0 then allocateNextBootEpoch mDb else pure (.ok bootEpoch)
  let .ok effBoot := effBootRes | do
    sqliteCloseRaw mDb.handle
    return .error (match effBootRes with | .error e => e | .ok _ => "boot_epoch_failed")
  let pRes ← openSqliteDb s!"{trimmedRoot}/projects.db" projectsSchemaSql
  let .ok pDb := pRes | do sqliteCloseRaw mDb.handle; return .error (match pRes with | .error e => e | .ok _ => "err")
  let aRes ← openSqliteDb s!"{trimmedRoot}/ask.db" askSchemaSql
  let .ok aDb := aRes | do sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; return .error (match aRes with | .error e => e | .ok _ => "err")
  let iRes ← openSqliteDb s!"{trimmedRoot}/idempotency_keys.db" idempotencySchemaSql idempotencyAdditiveAlters
  let .ok iDb := iRes | do
    sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle
    return .error (match iRes with | .error e => e | .ok _ => "err")
  if let .error cleanErr ← iDb.mu.atomically (sqliteExecRaw iDb.handle "DELETE FROM idempotency_keys WHERE phase='in_progress';") then
    sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle; sqliteCloseRaw iDb.handle
    return .error s!"core_store_idempotency_recovery_failed:{cleanErr}"
  match ← recoverDispatchLeases mDb pDb effBoot with
  | .error recErr =>
    sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle; sqliteCloseRaw iDb.handle
    return .error s!"core_store_lease_recovery_failed:{recErr}"
  | .ok () =>
    let closedRef ← IO.mkRef false
    return .ok { rootDir := trimmedRoot, bootEpoch := effBoot, missionsDb := mDb, projectsDb := pDb, askDb := aDb, idempotencyDb := iDb, closedRef := closedRef }

/-- Idempotently close all SQLite handles in `CoreStore` (prevents double-close). -/
def closeCoreStore (st : CoreStore) : IO Unit := do
  let already ← st.closedRef.swap true
  if !already then
    st.missionsDb.mu.atomically (sqliteCloseRaw st.missionsDb.handle)
    st.projectsDb.mu.atomically (sqliteCloseRaw st.projectsDb.handle)
    st.askDb.mu.atomically (sqliteCloseRaw st.askDb.handle)
    st.idempotencyDb.mu.atomically (sqliteCloseRaw st.idempotencyDb.handle)

private def hexNibble (n : Nat) : Char :=
  let v := n % 16
  if v < 10 then Char.ofNat (48 + v) else Char.ofNat (87 + v)

/-- Complete RFC 8259 JSON string escaper (escapes quotes, backslashes, and all `U+0000..U+001F`). -/
def jsonEscape (s : String) : String := Id.run do
  let mut out := "\""
  for ch in s.toList do
    let code := ch.toNat
    if ch == '"' then out := out ++ "\\\""
    else if ch == '\\' then out := out ++ "\\\\"
    else if ch == '\n' then out := out ++ "\\n"
    else if ch == '\r' then out := out ++ "\\r"
    else if ch == '\t' then out := out ++ "\\t"
    else if code == 8 then out := out ++ "\\b"
    else if code == 12 then out := out ++ "\\f"
    else if code < 0x20 then
      out := out ++ "\\u00" ++ String.singleton (hexNibble (code / 16)) ++ String.singleton (hexNibble (code % 16))
    else out := out.push ch
  return out ++ "\""

private def isIntegerCol (col : String) : Bool :=
  col == "enabled" || col == "revision" || col == "total_cost_cents" || col == "generation" ||
  col == "parallel_missions" || col == "state_revision" || col == "reserved_disk_gib" ||
  col == "owner_epoch" || col == "run_generation" || col == "node_boot_epoch" ||
  col == "phase" || col == "delivered" || col == "committed_oversize" || col == "body_bytes" ||
  col == "status_code" || col == "verified"

/-- Classify authority mode (`readonly | writer`) via `Orb.Kernel.verifyLeaseMode` (`SM-02`),
    rejecting contradictory `pr-writer` + `pr-readonly` tag combinations fail-closed. -/
def classifyAuthorityMode (writerFlag : Option Bool) (tags : Array String) (isReadonlyIntent : Bool := false) : Except String String :=
  let hasRo := tags.any (fun t => t == "pr-readonly")
  let hasWr := tags.any (fun t => t == "pr-writer")
  if hasRo && hasWr then
    .error "contradictory_authority_tags"
  else
    let wf : UInt8 := match writerFlag with | some false => 0 | some true => 1 | none => 2
    let code := Orb.Kernel.verifyLeaseMode wf (if hasRo then 1 else 0) (if hasWr then 1 else 0) (if isReadonlyIntent then 1 else 0)
    .ok (if code == 0 then "readonly" else "writer")

/-- Read-compatibility `tags` JSON array projection from typed `missions` columns (`SM-02`, `R2-B`). -/
def projectCompatibilityTagsJson
    (authorityMode placementKind supersededById orphanedAt : String)
    (reservedDiskGib : UInt64)
    (extraTags : Array String := #[]) : String := Id.run do
  let filtered := extraTags.filter fun t =>
    t != "pr-writer" && t != "pr-readonly" &&
    !t.startsWith "placement:" && !t.startsWith "superseded_by:" &&
    t != "orphaned" && !t.startsWith "disk-gib:"
  let mut out : Array String := #[]
  out := out.push (if authorityMode == "readonly" then "pr-readonly" else "pr-writer")
  if !placementKind.isEmpty then
    out := out.push s!"placement:{placementKind}"
  if !supersededById.isEmpty then
    out := out.push s!"superseded_by:{supersededById}"
  if !orphanedAt.isEmpty then
    out := out.push "orphaned"
  if reservedDiskGib > 0 then
    out := out.push s!"disk-gib:{reservedDiskGib}"
  for t in filtered do
    if !out.contains t then
      out := out.push t
  return "[" ++ String.intercalate "," (out.toList.map jsonEscape) ++ "]"

/-- Authoritative unified mission `health_verdict` derived from `MissionLifecycle` +
    `Orb.Kernel.missionStep` + `Orb.Kernel.reconcileStep` (`SM-01`). -/
def deriveMissionHealthVerdict
    (status terminalReason orphanedAt supersededById placementKind : String)
    (sameBoot runningInActor hasLiveRun hasEvents wakeupArmed hasEvidence : Bool) : String :=
  if !supersededById.isEmpty then
    "superseded"
  else if !orphanedAt.isEmpty then
    "orphaned"
  else
    let statusCode : UInt8 :=
      if status == "active" then 0
      else if status == "awaiting_user" then 1
      else if status == "interrupted" then 2
      else 3
    let isClient : UInt8 := if placementKind == "client" then 1 else 0
    let recVerdict := Orb.Kernel.reconcileStep
      statusCode isClient (if sameBoot then 1 else 0) 0
      (if runningInActor then 1 else 0) 0 (if hasLiveRun then 1 else 0)
      0 (if hasEvents then 1 else 0) 0 0 0 0
    if recVerdict == 1 then
      "ghost_active"
    else if recVerdict == 2 then
      "orphaned"
    else if recVerdict == 3 then
      "needs_reresume"
    else
      match status with
      | "completed" => if hasEvidence then "completed" else "completed_unverified"
      | "failed" =>
        if terminalReason == "budget_limited" then "budget_limited"
        else if terminalReason == "stalled" then "stalled"
        else "failed"
      | "cancelled" => "cancelled"
      | "blocked" => if terminalReason == "budget_limited" then "budget_limited" else "blocked"
      | "not_feasible" => "not_feasible"
      | "acknowledged" => "acknowledged"
      | "paused" =>
        let stepCode := Orb.Kernel.missionStep 1 0 0 (if wakeupArmed then 1 else 0) 1 0 3 0 10 0
        if stepCode == 4 then "paused_wakeup" else "paused"
      | "waiting_background" => "waiting_background"
      | "pending" => "pending"
      | "interrupted" => "interrupted"
      | "awaiting_user" => "awaiting_user"
      | "active" =>
        let stepCode := Orb.Kernel.missionStep 1 0 0 (if wakeupArmed then 1 else 0) 1 0 3 0 10 0
        if stepCode == 4 then "paused_wakeup" else "healthy"
      | _ => "unknown"

private def isRawJsonCol (col : String) : Bool :=
  col == "models_json" || col == "data" || col == "history_json" || col == "tags" || col == "allowed_units_json" || col == "payload"

/-- Convert `(headerRow + dataRows)` from `sqliteQueryRowsRaw` into a JSON array of objects,
    preserving integer and raw JSON columns where applicable. -/
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
        let valJson :=
          if isIntegerCol k then
            match v.toInt? with
            | some n => s!"{n}"
            | none => "0"
          else if isRawJsonCol k && (v.startsWith "[" || v.startsWith "{") then
            v
          else
            jsonEscape v
        kvs := kvs.push s!"{jsonEscape k}:{valJson}"
      objs := objs.push ("{" ++ String.intercalate "," kvs.toList ++ "}")
    return "[" ++ String.intercalate "," objs.toList ++ "]"

def execParamQueryUnlocked (db : SqliteDb) (sql : String) (params : Array String) : IO (Except String (Array (Array String))) :=
  sqliteQueryRowsRaw db.handle sql params

def execParamQuery (db : SqliteDb) (sql : String) (params : Array String) : IO (Except String (Array (Array String))) :=
  db.mu.atomically (sqliteQueryRowsRaw db.handle sql params)

/-- Execute `act` inside an atomic, mutex-serialized `BEGIN IMMEDIATE ... COMMIT` SQLite write transaction. -/
def withImmediateTx {α : Type} (db : SqliteDb) (act : IO (Except String α)) : IO (Except String α) :=
  db.mu.atomically do
    match ← sqliteExecRaw db.handle "BEGIN IMMEDIATE;" with
    | .error e => return .error s!"tx_begin_failed:{e}"
    | .ok () =>
      match ← act with
      | .ok v =>
        match ← sqliteExecRaw db.handle "COMMIT;" with
        | .ok () => return .ok v
        | .error e =>
          discard <| sqliteExecRaw db.handle "ROLLBACK;"
          return .error s!"tx_commit_failed:{e}"
      | .error err =>
        discard <| sqliteExecRaw db.handle "ROLLBACK;"
        return .error err

/-- Upsert a mission record into `missions.db`, persisting typed R2-B columns alongside the
    read-compatibility `tags` projection (`SM-02`). -/
def upsertMission (st : CoreStore) (m : MissionRecord) : IO (Except String Unit) := do
  if m.authorityMode != "readonly" && m.authorityMode != "writer" then
    return .error s!"invalid_authority_mode:{m.authorityMode}"
  let compatTags :=
    if m.tagsJson.isEmpty || m.tagsJson == "[]" then
      projectCompatibilityTagsJson m.authorityMode m.placementKind m.supersededById m.orphanedAt m.reservedDiskGib
    else
      m.tagsJson
  let rev := if m.stateRevision == 0 then 1 else m.stateRevision
  let ownEp := if m.ownerEpoch == 0 then 1 else m.ownerEpoch
  let runGen := if m.runGeneration == 0 then 1 else m.runGeneration
  let bootEp := if m.nodeBootEpoch == 0 then 1 else m.nodeBootEpoch
  let sql :=
    "INSERT INTO missions(id,title,status,backend,model_override,model_effort,working_directory,project,updated_at,total_cost_cents,authority_mode,placement_kind,superseded_by_mission_id,orphaned_at,reserved_disk_gib,state_revision,owner_epoch,run_generation,node_boot_epoch,tags,track,repo) " ++
    "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22) " ++
    "ON CONFLICT(id) DO UPDATE SET title=excluded.title,status=excluded.status,backend=excluded.backend,model_override=excluded.model_override,model_effort=excluded.model_effort,working_directory=excluded.working_directory,project=excluded.project,updated_at=excluded.updated_at,total_cost_cents=excluded.total_cost_cents," ++
    "track=excluded.track,repo=excluded.repo;"
  let res ← execParamQuery st.missionsDb sql #[
    m.id, m.title, m.status, m.backend, m.modelOverride, m.modelEffort, m.workingDirectory, m.project,
    m.updatedAt, s!"{m.totalCostCents}", m.authorityMode, m.placementKind, m.supersededById, m.orphanedAt,
    s!"{m.reservedDiskGib}", s!"{rev}", s!"{ownEp}", s!"{runGen}", s!"{bootEp}", compatTags, m.track, m.repo
  ]
  return res.map (fun _ => ())

/-- Record authoritative terminal evidence in `mission_terminal_evidence` (`SM-01`). -/
def upsertTerminalEvidence (st : CoreStore) (ev : TerminalEvidenceRecord) : IO (Except String Unit) := do
  let res ← execParamQuery st.missionsDb
    "INSERT INTO mission_terminal_evidence(mission_id,terminal_reason,summary,artifact_ref,verified,recorded_at) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(mission_id) DO UPDATE SET terminal_reason=excluded.terminal_reason,summary=excluded.summary,artifact_ref=excluded.artifact_ref,verified=excluded.verified,recorded_at=excluded.recorded_at;"
    #[ev.missionId, ev.terminalReason, ev.summary, ev.artifactRef, if ev.verified then "1" else "0", ev.recordedAt]
  return res.map (fun _ => ())

/-- Reusable transactional CAS state transition + durable outbox intent commit (`R2-C`, `SM-02`).
    Enforces `Orb.Kernel.epochFenceStep` over `(owner_epoch, run_generation, node_boot_epoch, state_revision)`
    and `Orb.Kernel.effectOutboxStep` (`op=0` Planned) for every atomically staged intent. -/
def commitTransitionWithIntents
    (st : CoreStore)
    (missionId : String)
    (expectedRev : UInt32)
    (liveOwnerEpoch liveRunGen liveBootEpoch writerOwnerEpoch : UInt64)
    (nextStatus nextAuthorityMode nextPlacementKind nextSupersededBy nextOrphanedAt : String)
    (nextReservedDiskGib : UInt64)
    (updatedAt : String)
    (intents : Array OutboxIntent := #[]) : IO (Except String UInt32) :=
  if nextAuthorityMode != "readonly" && nextAuthorityMode != "writer" then
    pure (.error s!"invalid_authority_mode:{nextAuthorityMode}")
  else
    withImmediateTx st.missionsDb do
      let curRows ← execParamQueryUnlocked st.missionsDb
        "SELECT owner_epoch,run_generation,node_boot_epoch,state_revision FROM missions WHERE id=?1;"
        #[missionId]
      let .ok rs := curRows | return .error "cas_select_failed"
      if rs.size ≤ 1 then
        return .error "mission_not_found"
      let r := rs[1]!
      let durOwner := ((r[0]?.bind String.toNat?).getD 1).toUInt64
      let durRun := ((r[1]?.bind String.toNat?).getD 1).toUInt64
      let durBoot := ((r[2]?.bind String.toNat?).getD 1).toUInt64
      let durRev := ((r[3]?.bind String.toNat?).getD 1).toUInt32
      let fenceWord := Orb.Kernel.epochFenceStep
        durOwner liveOwnerEpoch durRun liveRunGen durBoot liveBootEpoch durRev expectedRev writerOwnerEpoch
      let lo32 := (fenceWord &&& 0xFFFFFFFF).toUInt32
      let nextRev := (fenceWord >>> 32).toUInt32
      if (lo32 &&& 256) == 0 then
        let reason := lo32 &&& 0xFF
        return .error s!"cas_fence_rejected:{reason}:expected={expectedRev}:actual={durRev}"
      let compatTags := projectCompatibilityTagsJson
        nextAuthorityMode nextPlacementKind nextSupersededBy nextOrphanedAt nextReservedDiskGib
      let upd ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET status=?2,authority_mode=?3,placement_kind=?4,superseded_by_mission_id=?5,orphaned_at=?6,reserved_disk_gib=?7,tags=?8,state_revision=?9,updated_at=?10 WHERE id=?1 AND state_revision=?11;"
        #[missionId, nextStatus, nextAuthorityMode, nextPlacementKind, nextSupersededBy, nextOrphanedAt,
          s!"{nextReservedDiskGib}", compatTags, s!"{nextRev}", updatedAt, s!"{durRev}"]
      let .ok _ := upd | return .error (match upd with | .error e => e | .ok _ => "cas_update_failed")
      let chg ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok crs := chg | return .error "cas_changes_failed"
      if ((crs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 == 0 then
        return .error s!"cas_conflict:expected={expectedRev}"
      for intent in intents do
        let attEp := if intent.attemptEpoch == 0 then liveBootEpoch else intent.attemptEpoch
        let outWord := Orb.Kernel.effectOutboxStep 3 0 0 1 attEp liveBootEpoch
        let outLo := (outWord &&& 0xFFFFFFFF).toUInt32
        if (outLo &&& 256) == 0 then
          return .error s!"outbox_plan_rejected:{outLo &&& 0xFF}"
        let ins ← execParamQueryUnlocked st.missionsDb
          "INSERT INTO effect_outbox(effect_id,mission_id,state_revision,intent_kind,payload_json,phase,delivered,attempt_epoch,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,0,0,?6,?7,?7);"
          #[intent.effectId, missionId, s!"{nextRev}", intent.intentKind, intent.payloadJson, s!"{attEp}", updatedAt]
        if let .error e := ins then
          return .error e
      return .ok nextRev

/-- Advance a durable outbox effect (`Claim=1`, `Accept=2`, `RejectPreCommit=3`, `MarkUncertain=4`,
    `Reconcile=5`) gated by `Orb.Kernel.effectOutboxStep` (`StickyFence` blocks fresh retry on `Uncertain`). -/
def transitionOutboxEffect
    (st : CoreStore) (effectId : String) (op : UInt8)
    (attemptEpoch nodeBootEpoch : UInt64) (updatedAt : String) : IO (Except String (UInt8 × UInt8)) :=
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT phase,delivered FROM effect_outbox WHERE effect_id=?1;" #[effectId]
    let .ok rs := rows | return .error "outbox_select_failed"
    if rs.size ≤ 1 then return .error "outbox_not_found"
    let curPhase := ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 |>.toUInt8
    let curDeliv := ((rs[1]?.bind (·[1]?)).bind String.toNat?).getD 0 |>.toUInt8
    let word := Orb.Kernel.effectOutboxStep curPhase curDeliv op 1 attemptEpoch nodeBootEpoch
    let lo32 := (word &&& 0xFFFFFFFF).toUInt32
    if (lo32 &&& 256) == 0 then
      return .error s!"outbox_transition_rejected:{lo32 &&& 0xFF}:phase={curPhase}:op={op}"
    let nextPhase := ((lo32 >>> 16) &&& 0xFF).toUInt8
    let nextDeliv := ((word >>> 32) &&& 0xFF).toUInt8
    let upd ← execParamQueryUnlocked st.missionsDb
      "UPDATE effect_outbox SET phase=?2,delivered=?3,attempt_epoch=?4,updated_at=?5 WHERE effect_id=?1 AND phase=?6;"
      #[effectId, s!"{nextPhase}", s!"{nextDeliv}", s!"{attemptEpoch}", updatedAt, s!"{curPhase}"]
    if let .error e := upd then return .error e
    return .ok (nextPhase, nextDeliv)

/-- Durable two-phase cross-DB (`missions.db` <-> `projects.db`) track/repository lease protocol (`SM-08`),
    gated by `Orb.Kernel.admissionStep`, `Orb.Kernel.verifyTrackHold`, and `Orb.Kernel.verifyRepoDisjoint`. -/
def acquireDispatchTrackLease (st : CoreStore) (req : DispatchLeaseRequest) : IO (Except String Unit) := do
  if req.projectSlug.isEmpty || req.track.isEmpty then
    return .error "lease_missing_project_or_track"
  if req.authorityMode != "readonly" && req.authorityMode != "writer" then
    return .error s!"invalid_authority_mode:{req.authorityMode}"
  let gibBytes : UInt64 := req.reservedDiskGib * 1073741824
  let admWord := Orb.Kernel.admissionStep 0 1 0 gibBytes req.freeDiskBytes
  if (admWord &&& 1) == 0 then
    return .error "lease_disk_budget_rejected"
  -- Phase 1: Durable `preparing` reservation intent in `missions.db`
  let prepRes ← withImmediateTx st.missionsDb do
    let ins ← execParamQueryUnlocked st.missionsDb
      "INSERT INTO dispatch_lease_intents(reservation_id,mission_id,project_slug,track,repo,authority_mode,reserved_disk_gib,phase,boot_epoch,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,'preparing',?8,?9,?9);"
      #[req.reservationId, req.missionId, req.projectSlug, req.track, req.repo, req.authorityMode,
        s!"{req.reservedDiskGib}", s!"{req.bootEpoch}", req.nowAt]
    return ins.map (fun _ => ())
  if let .error e := prepRes then
    return .error e
  -- Phase 2: Atomic conflict check + lease insert in `projects.db`
  let projRes ← withImmediateTx st.projectsDb do
    let existing ← execParamQueryUnlocked st.projectsDb
      "SELECT mission_id,track,repo,authority_mode,phase FROM project_track_leases WHERE project_slug=?1 AND phase IN ('preparing','active');"
      #[req.projectSlug]
    let .ok rs := existing | return .error "project_lease_query_failed"
    for i in [1:rs.size] do
      let r := rs[i]!
      let otherMid := (r[0]?).getD ""
      let otherTrack := (r[1]?).getD ""
      let otherRepo := (r[2]?).getD ""
      let otherMode := (r[3]?).getD "writer"
      let otherPhase := (r[4]?).getD "active"
      if otherMid != req.missionId then
        let inUnresolved : UInt8 := if otherPhase == "preparing" then 1 else 0
        let hasLiveOwner : UInt8 := if otherPhase == "active" then 1 else 0
        let holds := Orb.Kernel.verifyTrackHold inUnresolved 0 hasLiveOwner 0
        if holds == 1 then
          if otherTrack == req.track && (req.authorityMode == "writer" || otherMode == "writer") then
            return .error s!"track_writer_conflict:{otherMid}"
          if req.authorityMode == "writer" && otherMode == "writer" && (!req.repo.isEmpty || !otherRepo.isEmpty) then
            let hKnown : UInt8 := if otherRepo.isEmpty then 0 else 1
            let tKnown : UInt8 := if req.repo.isEmpty then 0 else 1
            let sameRepo : UInt8 := if otherRepo == req.repo then 1 else 0
            if Orb.Kernel.verifyRepoDisjoint hKnown tKnown sameRepo == 0 then
              return .error s!"repo_writer_conflict:{otherMid}"
    let ins ← execParamQueryUnlocked st.projectsDb
      "INSERT INTO project_track_leases(project_slug,track,reservation_id,mission_id,repo,authority_mode,phase,boot_epoch,updated_at) VALUES(?1,?2,?3,?4,?5,?6,'preparing',?7,?8) ON CONFLICT(project_slug,track,mission_id) DO UPDATE SET reservation_id=excluded.reservation_id,repo=excluded.repo,authority_mode=excluded.authority_mode,phase='preparing',boot_epoch=excluded.boot_epoch,updated_at=excluded.updated_at;"
      #[req.projectSlug, req.track, req.reservationId, req.missionId, req.repo, req.authorityMode, s!"{req.bootEpoch}", req.nowAt]
    return ins.map (fun _ => ())
  match projRes with
  | .error conflictErr =>
    discard <| withImmediateTx st.missionsDb do
      execParamQueryUnlocked st.missionsDb
        "UPDATE dispatch_lease_intents SET phase='rolled_back',updated_at=?2 WHERE reservation_id=?1;"
        #[req.reservationId, req.nowAt]
    return .error conflictErr
  | .ok () =>
    -- Phase 3: Promote intent to `active` in `missions.db` (source of truth), then promote `projects.db` row
    let actRes ← withImmediateTx st.missionsDb do
      let u1 ← execParamQueryUnlocked st.missionsDb
        "UPDATE dispatch_lease_intents SET phase='active',updated_at=?2 WHERE reservation_id=?1;"
        #[req.reservationId, req.nowAt]
      if let .error e := u1 then return .error e
      let u2 ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET project=?2,track=?3,repo=?4,authority_mode=?5,reserved_disk_gib=?6,state_revision=state_revision+1,updated_at=?7 WHERE id=?1;"
        #[req.missionId, req.projectSlug, req.track, req.repo, req.authorityMode, s!"{req.reservedDiskGib}", req.nowAt]
      return u2.map (fun _ => ())
    if let .error e := actRes then
      discard <| recoverDispatchLeases st.missionsDb st.projectsDb req.bootEpoch
      return .error e
    let projActRes ← withImmediateTx st.projectsDb do
      let pu ← execParamQueryUnlocked st.projectsDb
        "UPDATE project_track_leases SET phase='active',updated_at=?2 WHERE reservation_id=?1;"
        #[req.reservationId, req.nowAt]
      return pu.map (fun _ => ())
    if let .error pe := projActRes then
      discard <| recoverDispatchLeases st.missionsDb st.projectsDb req.bootEpoch
      return .error pe
    return .ok ()

/-- Release an active cross-DB dispatch track lease cleanly across `projects.db` and `missions.db`. -/
def releaseDispatchTrackLease (st : CoreStore) (reservationId nowAt : String) : IO (Except String Unit) := do
  let pRes ← withImmediateTx st.projectsDb do
    let d ← execParamQueryUnlocked st.projectsDb
      "DELETE FROM project_track_leases WHERE reservation_id=?1;" #[reservationId]
    return d.map (fun _ => ())
  if let .error e := pRes then return .error e
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT mission_id FROM dispatch_lease_intents WHERE reservation_id=?1;" #[reservationId]
    let mid := match rows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
    let u1 ← execParamQueryUnlocked st.missionsDb
      "UPDATE dispatch_lease_intents SET phase='released',updated_at=?2 WHERE reservation_id=?1;"
      #[reservationId, nowAt]
    if let .error e := u1 then return .error e
    if !mid.isEmpty then
      let u2 ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET reserved_disk_gib=0,state_revision=state_revision+1,updated_at=?2 WHERE id=?1;"
        #[mid, nowAt]
      if let .error e := u2 then return .error e
    return .ok ()

/-- Record mission opened timestamp (`mark_mission_opened` capability parity). -/
def mark_mission_opened (st : CoreStore) (missionId openedAt : String) : IO (Except String Unit) := do
  let res ← execParamQuery st.missionsDb
    "UPDATE missions SET opened_at=?2, updated_at=?2 WHERE id=?1;" #[missionId, openedAt]
  return res.map (fun _ => ())

/-- List all mission status strings currently persisted in `missions.db`. -/
def listMissionStatuses (st : CoreStore) : IO (Except String (Array String)) := do
  let rows ← execParamQuery st.missionsDb "SELECT status FROM missions;" #[]
  return rows.map (fun rs =>
    if rs.size ≤ 1 then #[]
    else Id.run do
      let mut out : Array String := Array.mkEmpty (rs.size - 1)
      for i in [1:rs.size] do
        out := out.push ((rs[i]![0]?).getD "")
      return out)

/-- List mission status strings scoped to a specific `project` slug in `missions.db`. -/
def listProjectMissionStatuses (st : CoreStore) (proj : String) : IO (Except String (Array String)) := do
  let rows ← execParamQuery st.missionsDb "SELECT status FROM missions WHERE project=?1;" #[proj]
  return rows.map (fun rs =>
    if rs.size ≤ 1 then #[]
    else Id.run do
      let mut out : Array String := Array.mkEmpty (rs.size - 1)
      for i in [1:rs.size] do
        out := out.push ((rs[i]![0]?).getD "")
      return out)

/-- Look up optional `parallel_missions` grant integer for `slug` in `projects.db`. -/
def queryProjectParallelMissions? (st : CoreStore) (slug : String) : IO (Option Int) := do
  if slug.isEmpty then return none
  match ← execParamQuery st.projectsDb "SELECT COALESCE(parallel_missions, 0) FROM project_grant WHERE slug=?1;" #[slug] with
  | .error _ => return none
  | .ok rows =>
    if rows.size ≤ 1 then return none
    return (rows[1]?.bind (·[0]?)).bind String.toInt?

/-- List missions from `missions.db` joined with `mission_terminal_evidence` as JSON (`SM-01`, `SM-02`),
    preserving `total_cost_cents` telemetry, typed authority/placement/revision columns, and unified `health_verdict`. -/
def listMissionsJson (st : CoreStore) (nodeBootEpoch? : Option UInt64 := none) : IO (Except String String) := do
  let nodeBootEpoch := nodeBootEpoch?.getD st.bootEpoch
  let sql :=
    "SELECT m.id,m.title,m.status,m.backend,COALESCE(m.model_override,'') AS model_override," ++
    "COALESCE(m.model_effort,'') AS model_effort,m.working_directory,m.updated_at,m.total_cost_cents," ++
    "m.authority_mode,m.placement_kind,m.superseded_by_mission_id,m.orphaned_at,m.reserved_disk_gib," ++
    "m.state_revision,m.node_boot_epoch,COALESCE(m.terminal_reason,'') AS mission_term_reason," ++
    "COALESCE(e.terminal_reason,'') AS ev_reason,COALESCE(e.summary,'') AS ev_summary," ++
    "COALESCE(e.artifact_ref,'') AS ev_artifact,COALESCE(e.recorded_at,'') AS ev_recorded_at," ++
    "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal') AS live_runs," ++
    "(SELECT COUNT(*) FROM mission_events ev WHERE ev.mission_id=m.id) AS ev_cnt," ++
    "m.tags " ++
    "FROM missions m LEFT JOIN mission_terminal_evidence e ON e.mission_id = m.id " ++
    "ORDER BY m.updated_at DESC, m.id ASC;"
  let rows ← execParamQuery st.missionsDb sql #[]
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
        let c7 := r[7]?.getD ""
        let total_cost_cents := (r[8]?.bind String.toNat?).getD 0
        let authMode := r[9]?.getD "writer"
        let placeKind := r[10]?.getD "managed"
        let superBy := r[11]?.getD ""
        let orphAt := r[12]?.getD ""
        let diskGib := (r[13]?.bind String.toNat?).getD 0
        let stateRev := (r[14]?.bind String.toNat?).getD 1
        let rowBoot := ((r[15]?.bind String.toNat?).getD 1).toUInt64
        let mTermReason := r[16]?.getD ""
        let evReason := r[17]?.getD ""
        let evSummary := r[18]?.getD ""
        let evArtifact := r[19]?.getD ""
        let evRecorded := r[20]?.getD ""
        let liveRuns := (r[21]?.bind String.toNat?).getD 0
        let evCnt := (r[22]?.bind String.toNat?).getD 0
        let rawTags := r[23]?.getD "[]"
        let effReason := if !evReason.isEmpty then evReason else mTermReason
        let hasEv := !evRecorded.isEmpty || !evReason.isEmpty
        let verdict := deriveMissionHealthVerdict
          c2 effReason orphAt superBy placeKind
          (rowBoot == nodeBootEpoch) false (liveRuns > 0) (evCnt > 0) false hasEv
        let evJson :=
          if hasEv then
            s!"\{\"terminal_reason\":{jsonEscape evReason},\"summary\":{jsonEscape evSummary},\"artifact_ref\":{jsonEscape evArtifact},\"recorded_at\":{jsonEscape evRecorded}}"
          else "null"
        let tagsOut :=
          if rawTags.startsWith "[" then rawTags
          else projectCompatibilityTagsJson authMode placeKind superBy orphAt diskGib.toUInt64
        items := items.push (
          s!"\{\"id\":{jsonEscape c0},\"title\":{jsonEscape c1},\"status\":{jsonEscape c2},\"backend\":{jsonEscape c3}," ++
          s!"\"model_override\":{jsonEscape c4},\"model_effort\":{jsonEscape c5},\"working_directory\":{jsonEscape c6}," ++
          s!"\"updated_at\":{jsonEscape c7},\"total_cost_cents\":{total_cost_cents}," ++
          s!"\"authority_mode\":{jsonEscape authMode},\"placement_kind\":{jsonEscape placeKind}," ++
          s!"\"superseded_by_mission_id\":{jsonEscape superBy},\"orphaned_at\":{jsonEscape orphAt}," ++
          s!"\"reserved_disk_gib\":{diskGib},\"state_revision\":{stateRev}," ++
          s!"\"health_verdict\":{jsonEscape verdict},\"terminal_evidence\":{evJson},\"tags\":{tagsOut}}"
        )
      return "[" ++ String.intercalate "," items.toList ++ "]")

/-- Check whether `status` permits starting a machine transfer. -/
def isStatusMovable (status : String) : Bool :=
  status == "awaiting_user" || status == "completed" || status == "failed" ||
  status == "interrupted" || status == "paused" || status == "blocked" ||
  status == "not_feasible" || status == "acknowledged"

/-- Transactional fence-checked machine-transfer initiation gated by `verifyTransferFence` (`OrbCore.Spec`). -/
def startMachineTransfer (st : CoreStore) (t : TransferRecord) : IO (Except String TransferRecord) := do
  let nowSec ← coreEpochSec
  withImmediateTx st.missionsDb do
    let activeRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COUNT(*) FROM machine_transfers WHERE mission_id=?1 AND phase NOT IN ('activated','cancelled');" #[t.missionId]
    let .ok ar := activeRows | return .error "transfer_active_query_failed"
    let activeCnt := ((ar[1]?.bind (·[0]?)).bind String.toNat?).getD 1
    let runRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COUNT(*), COALESCE(MAX(generation),0) FROM mission_runs WHERE mission_id=?1 AND execution_state<>'terminal';" #[t.missionId]
    let .ok rr := runRows | return .error "transfer_runs_query_failed"
    let nonTermCnt := ((rr[1]?.bind (·[0]?)).bind String.toNat?).getD 1
    let leaseRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COUNT(*) FROM privilege_leases WHERE mission_id=?1 AND revoked=0 AND expires_at_epoch>?2;" #[t.missionId, s!"{nowSec}"]
    let .ok lr := leaseRows | return .error "transfer_lease_query_failed"
    let liveLeaseCnt := ((lr[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    let genRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COALESCE(MAX(generation),0) FROM mission_runs WHERE mission_id=?1;" #[t.missionId]
    let .ok gr := genRows | return .error "transfer_gen_query_failed"
    let storedGen := (((gr[1]?.bind (·[0]?)).bind String.toNat?).getD 0).toUInt64
    let mRows ← execParamQueryUnlocked st.missionsDb
      "SELECT status, updated_at FROM missions WHERE id=?1;" #[t.missionId]
    let .ok mr := mRows | return .error "transfer_mission_query_failed"
    if mr.size ≤ 1 then return .error "mission_not_found"
    let status := (mr[1]?.bind (·[0]?)).getD ""
    let rev := (mr[1]?.bind (·[1]?)).getD ""
    let movable : UInt8 := if isStatusMovable status && rev == t.sourceRevision then 1 else 0
    let activeFlag : UInt8 := if activeCnt > 0 then 1 else 0
    let nonTermFlag : UInt8 := if nonTermCnt > 0 then 1 else 0
    let leaseContendedFlag : UInt8 := if liveLeaseCnt > 0 then 1 else 0
    if verifyTransferFence activeFlag nonTermFlag leaseContendedFlag movable storedGen t.sourceGeneration != 1 then
      return .error "Machine transfer fenced or source state changed"
    let nextGen := storedGen + 1
    let outRec := { t with generation := nextGen, revision := 0 }
    let dataJson := s!"\{\"id\":{jsonEscape outRec.id},\"mission_id\":{jsonEscape outRec.missionId},\"phase\":{jsonEscape outRec.phase},\"destination\":{jsonEscape outRec.destination},\"generation\":{outRec.generation}}"
    let ins ← execParamQueryUnlocked st.missionsDb
      "INSERT INTO machine_transfers(id,mission_id,request_key,revision,phase,data,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7);"
      #[outRec.id, outRec.missionId, outRec.requestKey, "0", outRec.phase, dataJson, outRec.createdAt]
    let .ok _ := ins | return .error (match ins with | .error e => e | .ok _ => "transfer_insert_failed")
    let runIns ← execParamQueryUnlocked st.missionsDb
      "INSERT OR REPLACE INTO mission_runs(id,mission_id,generation,execution_state,updated_at) VALUES(?1,?2,?3,'terminal',?4);"
      #[s!"txrun-{outRec.id}", outRec.missionId, s!"{nextGen}", outRec.createdAt]
    match runIns with
    | .error e => return .error e
    | .ok _ => return .ok outRec

/-- Insert or update a hardware-approved JIT privilege lease in `missions.db`. -/
def upsertPrivilegeLease (st : CoreStore) (rec : PrivilegeLeaseRecord) : IO (Except String Unit) := do
  let res ← execParamQuery st.missionsDb
    "INSERT OR REPLACE INTO privilege_leases(grant_id,lease_token,mission_id,target_host,scope,allowed_units_json,require_force_cmd,biometric_signed,revoked,expires_at_epoch) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10);"
    #[rec.grantId, rec.leaseToken, rec.missionId, rec.targetHost, rec.scope, rec.allowedUnitsJson,
      if rec.requireForceCmd then "1" else "0",
      if rec.biometricSigned then "1" else "0",
      if rec.revoked then "1" else "0",
      s!"{rec.expiresAtEpoch}"]
  return res.map (fun _ => ())

/-- Look up a privilege lease by `lease_token` in `missions.db`. -/
def lookupPrivilegeLease? (st : CoreStore) (leaseToken : String) : IO (Option PrivilegeLeaseRecord) := do
  if leaseToken.isEmpty then return none
  match ← execParamQuery st.missionsDb
    "SELECT grant_id,lease_token,mission_id,target_host,scope,allowed_units_json,require_force_cmd,biometric_signed,revoked,expires_at_epoch FROM privilege_leases WHERE lease_token=?1;" #[leaseToken] with
  | .error _ => return none
  | .ok rows =>
    if rows.size ≤ 1 then return none
    let r := rows[1]!
    return some {
      grantId          := (r[0]?).getD ""
      leaseToken       := (r[1]?).getD ""
      missionId        := (r[2]?).getD ""
      targetHost       := (r[3]?).getD ""
      scope            := (r[4]?).getD "ops_read"
      allowedUnitsJson := (r[5]?).getD "[]"
      requireForceCmd  := ((r[6]?).getD "0") == "1"
      biometricSigned  := ((r[7]?).getD "0") == "1"
      revoked          := ((r[8]?).getD "0") == "1"
      expiresAtEpoch   := (((r[9]?).bind String.toNat?).getD 0).toUInt64
    }

/-- Append a privilege verification & execution audit entry to `privilege_audit_log`. -/
def appendPrivilegeAuditLog (st : CoreStore)
    (grantId missionId targetHost execHost command : String) (allowed : Bool) (createdAt : String) : IO (Except String Unit) := do
  let res ← execParamQuery st.missionsDb
    "INSERT INTO privilege_audit_log(grant_id,mission_id,target_host,executing_host,command,allowed,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7);"
    #[grantId, missionId, targetHost, execHost, command, if allowed then "1" else "0", createdAt]
  return res.map (fun _ => ())

/-- Maximum inline response payload stored verbatim in `idempotency_keys` (`512 KiB`, `SM-12`). -/
def maxIdempotencyResponseBytes : Nat := 524288

/-- Outcome of `recordOrReplayIdempotency` (`SM-12` durable `committed_oversize` sentinel). -/
structure IdempotencyReceipt where
  statusCode        : Nat
  bodyJson          : String
  replayed          : Bool
  committedOversize : Bool
  deriving Repr, DecidableEq

/-- Outcome of `claimIdempotencySlot` (pre-effect reservation preventing concurrent duplicate mutation). -/
inductive IdempotencySlotClaim where
  | Claimed
  | Replayed (receipt : IdempotencyReceipt)
  | InFlight
  deriving Repr, DecidableEq

/-- Atomically reserve an in-flight `(scope, reqKey)` slot in `idempotency_keys.db` BEFORE performing side effects.
    - If already `committed`, returns `.Replayed` with the durable receipt (gated by `effectOutboxStep`).
    - If `in_progress`, returns `.InFlight` (`409 idempotency_key_in_flight`), preventing concurrent duplicate creation.
    - Otherwise inserts a `phase='in_progress'` reservation row (`Planned -> Claimed` via `effectOutboxStep`). -/
def claimIdempotencySlot (st : CoreStore) (scope reqKey createdAt : String) : IO (Except String IdempotencySlotClaim) :=
  withImmediateTx st.idempotencyDb do
    let existing ← execParamQueryUnlocked st.idempotencyDb
      "SELECT response_json,status_code,committed_oversize,phase FROM idempotency_keys WHERE scope=?1 AND request_key=?2;"
      #[scope, reqKey]
    match existing with
    | .error e => return .error e
    | .ok rows =>
      if rows.size > 1 then
        let r := rows[1]!
        let storedBody := (r[0]?).getD "{}"
        let storedCode := ((r[1]?.bind String.toNat?).getD 200)
        let storedOver := (((r[2]?.bind String.toNat?).getD 0) != 0)
        let storedPhase := (r[3]?).getD "committed"
        if storedPhase == "in_progress" then
          let claimConflict := Orb.Kernel.effectOutboxStep 1 0 1 1 1 1
          if (claimConflict &&& 256) != 0 then
            return .error "idempotency_inflight_fence_broken"
          return .ok .InFlight
        let fenceWord := Orb.Kernel.effectOutboxStep (if storedOver then 4 else 2) 1 1 1 1 1
        if (fenceWord &&& 256) != 0 then
          return .error "idempotency_sticky_fence_broken"
        return .ok (.Replayed {
          statusCode := storedCode
          bodyJson := storedBody
          replayed := true
          committedOversize := storedOver
        })
      let planWord := Orb.Kernel.effectOutboxStep 0 0 1 1 1 1
      if (planWord &&& 256) == 0 then
        return .error "idempotency_claim_fence_rejected"
      let ins ← execParamQueryUnlocked st.idempotencyDb
        "INSERT INTO idempotency_keys(scope,request_key,response_json,status_code,committed_oversize,body_bytes,phase,created_at) VALUES(?1,?2,'{}',202,0,0,'in_progress',?3);"
        #[scope, reqKey, createdAt]
      return ins.map (fun _ => .Claimed)

/-- Release an uncommitted `in_progress` idempotency reservation when pre-commit admission fails (`4xx`/`5xx`). -/
def abortIdempotencySlot (st : CoreStore) (scope reqKey : String) : IO (Except String Unit) :=
  withImmediateTx st.idempotencyDb do
    let d ← execParamQueryUnlocked st.idempotencyDb
      "DELETE FROM idempotency_keys WHERE scope=?1 AND request_key=?2 AND phase='in_progress';"
      #[scope, reqKey]
    return d.map (fun _ => ())

/-- Durable HTTP idempotency guard (`SM-12`, `R1-01` / `R2-C`):
    - If `(scope, reqKey)` is already `committed`, replays the stored `statusCode` and `response_json`
      (including `committed_oversize = 1` sentinel receipts, preventing duplicate mutation on retry!).
    - If `(scope, reqKey)` is `in_progress` (reserved by `claimIdempotencySlot`), finalizes it to `committed`.
    - If committed `2xx` exceeds `512 KiB` (`maxIdempotencyResponseBytes`), persists a compact
      `committed_oversize = 1` durable sentinel receipt (never dropping the key or returning `500`),
      gated by `Orb.Kernel.effectOutboxStep` (`StickyFence`). -/
def recordOrReplayIdempotency
    (st : CoreStore) (scope reqKey : String)
    (statusCode : Nat) (responseJson createdAt : String) : IO (Except String IdempotencyReceipt) :=
  withImmediateTx st.idempotencyDb do
    let existing ← execParamQueryUnlocked st.idempotencyDb
      "SELECT response_json,status_code,committed_oversize,phase FROM idempotency_keys WHERE scope=?1 AND request_key=?2;"
      #[scope, reqKey]
    match existing with
    | .error e => return .error e
    | .ok rows =>
      let hasInProgress :=
        rows.size > 1 && ((rows[1]?.bind (·[3]?)).getD "committed") == "in_progress"
      if rows.size > 1 && !hasInProgress then
        let r := rows[1]!
        let storedBody := (r[0]?).getD "{}"
        let storedCode := ((r[1]?.bind String.toNat?).getD 200)
        let storedOver := (((r[2]?.bind String.toNat?).getD 0) != 0)
        -- StickyFence witness: once Accepted/Uncertain, fresh Claim (`op=1`) is rejected (`bit 8 == 0`)
        let fenceWord := Orb.Kernel.effectOutboxStep (if storedOver then 4 else 2) 1 1 1 1 1
        if (fenceWord &&& 256) != 0 then
          return .error "idempotency_sticky_fence_broken"
        return .ok {
          statusCode := storedCode
          bodyJson := storedBody
          replayed := true
          committedOversize := storedOver
        }
      let rawBytes := responseJson.utf8ByteSize
      let isOversizeCommitted := statusCode ≥ 200 && statusCode < 300 && rawBytes > maxIdempotencyResponseBytes
      let persistedBody :=
        if isOversizeCommitted then
          s!"\{\"ok\":true,\"committed_oversize\":true,\"status_code\":{statusCode},\"original_body_bytes\":{rawBytes},\"scope\":{jsonEscape scope},\"idempotency_key\":{jsonEscape reqKey}}"
        else
          responseJson
      let overFlag := if isOversizeCommitted then "1" else "0"
      let writeRes ←
        if hasInProgress then
          execParamQueryUnlocked st.idempotencyDb
            "UPDATE idempotency_keys SET response_json=?3,status_code=?4,committed_oversize=?5,body_bytes=?6,phase='committed',created_at=?7 WHERE scope=?1 AND request_key=?2;"
            #[scope, reqKey, persistedBody, s!"{statusCode}", overFlag, s!"{rawBytes}", createdAt]
        else
          execParamQueryUnlocked st.idempotencyDb
            "INSERT INTO idempotency_keys(scope,request_key,response_json,status_code,committed_oversize,body_bytes,phase,created_at) VALUES(?1,?2,?3,?4,?5,?6,'committed',?7);"
            #[scope, reqKey, persistedBody, s!"{statusCode}", overFlag, s!"{rawBytes}", createdAt]
      match writeRes with
      | .error e => return .error e
      | .ok _ =>
        return .ok {
          statusCode := statusCode
          bodyJson := persistedBody
          replayed := false
          committedOversize := isOversizeCommitted
        }

/-- Transactional idempotency key read-or-insert (`idempotency_keys.db`), backed by `recordOrReplayIdempotency`
    so oversize committed payloads persist a durable `committed_oversize` sentinel rather than failing (`SM-12`). -/
def checkOrStoreIdempotency (st : CoreStore) (scope reqKey responseJson createdAt : String) : IO (Except String String) := do
  let res ← recordOrReplayIdempotency st scope reqKey 200 responseJson createdAt
  return res.map (·.bodyJson)

/-- Durable remote follow-up edit. Same id and FIFO sequence; content changes only while waiting and unbound. -/
inductive QueueEditOutcome where
  | Edited (missionId : String) (source? : Option String)
  | AlreadyDelivered
  | NotFound
  deriving Repr, DecidableEq

private def queuePayload (content missionId : String) (source? : Option String) : String :=
  let sourceJson := match source? with | some s => jsonEscape s | none => "null"
  s!"\{\"message\":\{\"id\":\"\",\"content\":{jsonEscape content},\"mission_id\":{jsonEscape missionId},\"source\":{sourceJson}},\"job_id\":null}"

private def payloadContent? (payload : String) : Option String :=
  (OrbBin.Json.parse payload).toOption.bind (·.field? "message") |>.bind (·.fieldStr? "content")

private def payloadSource? (payload : String) : Option String :=
  (OrbBin.Json.parse payload).toOption.bind (·.field? "message") |>.bind (·.fieldStr? "source")

/-- Enqueue a waiting remote follow-up. Replaying the same id returns its current content without moving it. -/
def enqueueRemoteMessage (st : CoreStore) (userId messageId missionId content : String)
    (source? : Option String := some "remote-queue") : IO (Except String String) :=
  withImmediateTx st.missionsDb do
    let existing ← execParamQueryUnlocked st.missionsDb
      "SELECT payload FROM remote_message_queue WHERE user_id=?1 AND message_id=?2;" #[userId, messageId]
    match existing with
    | .error e => return .error e
    | .ok rows =>
      if rows.size > 1 then
        return .ok ((payloadContent? ((rows[1]?.bind (·[0]?)).getD "")).getD "")
      let ins ← execParamQueryUnlocked st.missionsDb
        "INSERT INTO remote_message_queue(user_id,message_id,mission_id,payload,state) VALUES(?1,?2,?3,?4,'waiting');"
        #[userId, messageId, missionId, queuePayload content missionId source?]
      match ins with
      | .error e => return .error e
      | .ok _ => return .ok content

/-- List one mission's waiting queue in FIFO order (`sequence ASC`). -/
def listRemoteQueueJson (st : CoreStore) (userId missionId : String) : IO (Except String String) := do
  let rows ← execParamQuery st.missionsDb
    "SELECT sequence,message_id,mission_id,payload,state FROM remote_message_queue WHERE user_id=?1 AND mission_id=?2 AND state='waiting' AND json_extract(payload,'$.job_id') IS NULL ORDER BY sequence ASC;"
    #[userId, missionId]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok "[]"
    let mut items : Array String := #[]
    for i in [1:rs.size] do
      let r := rs[i]!
      let id := (r[1]?).getD ""
      let mid := (r[2]?).getD ""
      let payload := (r[3]?).getD ""
      let content := (payloadContent? payload).getD ""
      let sourceJson := match payloadSource? payload with | some s => jsonEscape s | none => "null"
      items := items.push s!"\{\"id\":{jsonEscape id},\"mission_id\":{jsonEscape mid},\"content\":{jsonEscape content},\"source\":{sourceJson},\"inflight\":false}"
    return .ok ("[" ++ String.intercalate "," items.toList ++ "]")

/-- Edit a waiting unbound row in place. Bound or non-waiting rows are `AlreadyDelivered`; missing ids are `NotFound`. -/
def editRemoteMessage (st : CoreStore) (userId messageId content : String) : IO (Except String QueueEditOutcome) :=
  withImmediateTx st.missionsDb do
    let found ← execParamQueryUnlocked st.missionsDb
      "SELECT mission_id,payload,state,json_extract(payload,'$.job_id') FROM remote_message_queue WHERE user_id=?1 AND message_id=?2;"
      #[userId, messageId]
    match found with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .ok .NotFound
      let missionId := ((rows[1]?.bind (·[0]?)).getD "")
      let payload := ((rows[1]?.bind (·[1]?)).getD "")
      let state := ((rows[1]?.bind (·[2]?)).getD "")
      let job := ((rows[1]?.bind (·[3]?)).getD "")
      let source? := payloadSource? payload
      if state != "waiting" || !job.isEmpty then return .ok .AlreadyDelivered
      let updated ← execParamQueryUnlocked st.missionsDb
        "UPDATE remote_message_queue SET payload=json_set(payload,'$.message.content',?3) WHERE user_id=?1 AND message_id=?2 AND state='waiting' AND json_extract(payload,'$.job_id') IS NULL;"
        #[userId, messageId, content]
      match updated with
      | .error e => return .error e
      | .ok _ =>
        let changed ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
        match changed with
        | .error e => return .error e
        | .ok crs =>
          let n := ((crs[1]?.bind (·[0]?)).bind String.toNat?).getD 0
          if n == 0 then return .ok .AlreadyDelivered
          return .ok (.Edited missionId source?)

end OrbCore.Store
