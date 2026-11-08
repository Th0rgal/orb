/-
  OrbCore.Store: Parameterized SQLite Mission, Transfer, Project, Privilege Lease, Ask &
  Idempotency Store (`0 import Lean`, `0 sorryAx`) for Wave 4 Core Gateway (`sandboxed-sh`).
  Opens existing `missions.db` / `projects.db` / `ask.db` / `idempotency_keys.db`
  in-place with WAL journaling and positional `?1..?N` bindings.
-/
import Std.Sync.Mutex
import Orb.Kernel
import Orb.Lifecycle
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Spec

namespace OrbCore.Store

open Orb.Kernel
open Orb.Lifecycle
open OrbBin.Json
open OrbBin.PosixExt
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
  leaseEpoch       : UInt64 := 0
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
  "CREATE TABLE IF NOT EXISTS mission_runs (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 1, execution_state TEXT NOT NULL DEFAULT 'terminal', terminal_reason TEXT NOT NULL DEFAULT '', remote_job_id TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_remote_waits (mission_id TEXT PRIMARY KEY, node_id TEXT NOT NULL, failed_job_id TEXT NOT NULL, scheduled_origin_job_id TEXT NOT NULL DEFAULT '', retries INTEGER NOT NULL DEFAULT 0, max_retries INTEGER NOT NULL DEFAULT 10, replays INTEGER NOT NULL DEFAULT 0, deadline_epoch INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_events (id INTEGER PRIMARY KEY AUTOINCREMENT, mission_id TEXT NOT NULL, seq INTEGER NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS cloud_executions (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, provider TEXT NOT NULL DEFAULT 'hermes', prompt TEXT NOT NULL DEFAULT '', response_text TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_automations (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, cron_expr TEXT NOT NULL, prompt TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, variables_used TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS model_routing_chains (id TEXT PRIMARY KEY, name TEXT NOT NULL, models_json TEXT NOT NULL DEFAULT '[]', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS privilege_leases (grant_id TEXT PRIMARY KEY, lease_token TEXT NOT NULL UNIQUE, mission_id TEXT NOT NULL, target_host TEXT NOT NULL, scope TEXT NOT NULL, allowed_units_json TEXT NOT NULL DEFAULT '[]', require_force_cmd INTEGER NOT NULL DEFAULT 0, biometric_signed INTEGER NOT NULL DEFAULT 1, revoked INTEGER NOT NULL DEFAULT 0, expires_at_epoch INTEGER NOT NULL DEFAULT 0, lease_epoch INTEGER NOT NULL DEFAULT 0);" ++
  "CREATE TABLE IF NOT EXISTS privilege_audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, grant_id TEXT NOT NULL, mission_id TEXT NOT NULL, target_host TEXT NOT NULL, executing_host TEXT NOT NULL, command TEXT NOT NULL, allowed INTEGER NOT NULL, created_at TEXT NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS core_boot_state (singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1), boot_epoch INTEGER NOT NULL DEFAULT 0, bunker_state INTEGER NOT NULL DEFAULT 0);" ++
  "CREATE TABLE IF NOT EXISTS remote_message_queue (sequence INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, message_id TEXT NOT NULL, mission_id TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'waiting', UNIQUE(user_id,message_id));" ++
  "CREATE INDEX IF NOT EXISTS remote_message_pending ON remote_message_queue(state,sequence);" ++
  "CREATE TABLE IF NOT EXISTS ai_providers (id TEXT PRIMARY KEY, provider_type TEXT NOT NULL, name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, base_url TEXT NOT NULL DEFAULT '', api_key TEXT NOT NULL DEFAULT '', rpm_limit INTEGER, max_concurrency INTEGER, custom_models_json TEXT NOT NULL DEFAULT '[]', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS deferred_message_batches (mission_id TEXT NOT NULL, batch_seq INTEGER NOT NULL, message_id TEXT NOT NULL, content TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', unpacked INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(mission_id, batch_seq, message_id));" ++
  "CREATE UNIQUE INDEX IF NOT EXISTS deferred_message_batches_uuid ON deferred_message_batches(mission_id, message_id);" ++
  "CREATE TABLE IF NOT EXISTS queue_item_receipts (message_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, phase INTEGER NOT NULL DEFAULT 0, claimed_generation INTEGER NOT NULL DEFAULT 0, claim_boot_epoch INTEGER NOT NULL DEFAULT 0, delivered_seq INTEGER NOT NULL DEFAULT 0, edit_revision INTEGER NOT NULL DEFAULT 0, content TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS mission_continuations (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, run_generation INTEGER NOT NULL, phase INTEGER NOT NULL DEFAULT 1, due_epoch INTEGER NOT NULL DEFAULT 0, trigger_kind TEXT NOT NULL DEFAULT 'time', reason TEXT NOT NULL DEFAULT '', prompt TEXT NOT NULL DEFAULT '', request_id TEXT NOT NULL DEFAULT '', job_id TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '', recurrence TEXT NOT NULL DEFAULT '', stop_after_first INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '', UNIQUE(mission_id, request_id));" ++
  "CREATE TABLE IF NOT EXISTS mission_supervision (mission_id TEXT PRIMARY KEY, bg_wait_arms INTEGER NOT NULL DEFAULT 0, stall_consecutive_arms INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '');" ++
  transferSchemaSql ++ "\n" ++ transferCleanupSql

def projectsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, root_path TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS project_grant (slug TEXT PRIMARY KEY, merge_authority TEXT, budget_per_tick TEXT, parallel_missions INTEGER, pause_reason TEXT, resume_condition TEXT, material_bar TEXT, autonomy_level TEXT, updated_at TEXT NOT NULL DEFAULT '');" ++
  "CREATE TABLE IF NOT EXISTS project_track_leases (project_slug TEXT NOT NULL, track TEXT NOT NULL, reservation_id TEXT NOT NULL UNIQUE, mission_id TEXT NOT NULL, repo TEXT NOT NULL DEFAULT '', authority_mode TEXT NOT NULL DEFAULT 'writer', phase TEXT NOT NULL DEFAULT 'preparing', boot_epoch INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(project_slug, track, mission_id));" ++
  "CREATE TABLE IF NOT EXISTS project_decisions (id TEXT PRIMARY KEY, project_slug TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', question TEXT NOT NULL DEFAULT '', evidence TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');"

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

def harnessContinuitySchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS harness_continuity (" ++
  "mission_id TEXT PRIMARY KEY, " ++
  "backend TEXT NOT NULL, " ++
  "session_generation INTEGER NOT NULL, " ++
  "session_id TEXT NOT NULL DEFAULT '', " ++
  "prompt_claim_id TEXT NOT NULL DEFAULT '', " ++
  "prompt_claim_phase TEXT NOT NULL DEFAULT 'none' CHECK(prompt_claim_phase IN ('none','claimed','delivered','uncertain')), " ++
  "tool_journal_json TEXT NOT NULL DEFAULT '[]', " ++
  "reconcile_required INTEGER NOT NULL DEFAULT 0, " ++
  "state_revision INTEGER NOT NULL DEFAULT 1, " ++
  "updated_at TEXT NOT NULL DEFAULT '');"

def harnessContinuityIndexSql : String :=
  "CREATE INDEX IF NOT EXISTS idx_harness_continuity_reconcile ON harness_continuity(reconcile_required, updated_at);"

def askSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS ask_requests (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, question TEXT NOT NULL, answer TEXT, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL DEFAULT '');"

def askMidturnSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS operator_notes (" ++
  "note_id TEXT PRIMARY KEY, " ++
  "mission_id TEXT NOT NULL, " ++
  "content TEXT NOT NULL, " ++
  "created_at_seq INTEGER NOT NULL, " ++
  "created_at_iso TEXT NOT NULL DEFAULT '', " ++
  "delivery_tries INTEGER NOT NULL DEFAULT 0, " ++
  "flushed_at TEXT DEFAULT NULL);"

def askMidturnPendingIndexSql : String :=
  "CREATE INDEX IF NOT EXISTS idx_operator_notes_pending ON operator_notes(mission_id, flushed_at, created_at_seq);"

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
  "ALTER TABLE missions ADD COLUMN repo TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE missions ADD COLUMN placement_job_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE missions ADD COLUMN scheduled_remote_job_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE missions ADD COLUMN not_before INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE missions ADD COLUMN resume_intent INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE mission_runs ADD COLUMN terminal_reason TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE mission_runs ADD COLUMN remote_job_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE remote_message_queue ADD COLUMN phase INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN claimed_generation INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN claim_boot_epoch INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN delivered_seq INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN edit_revision INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE mission_automations ADD COLUMN variables_used TEXT NOT NULL DEFAULT '{}';",
  "ALTER TABLE core_boot_state ADD COLUMN bunker_state INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE privilege_leases ADD COLUMN lease_epoch INTEGER NOT NULL DEFAULT 0;",
  "CREATE UNIQUE INDEX IF NOT EXISTS deferred_message_batches_uuid ON deferred_message_batches(mission_id, message_id);"
]

def projectsAdditiveAlters : Array String := #[
  "ALTER TABLE project_decisions ADD COLUMN project_slug TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE project_decisions ADD COLUMN status TEXT NOT NULL DEFAULT 'pending';",
  "ALTER TABLE project_decisions ADD COLUMN question TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE project_decisions ADD COLUMN evidence TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE project_decisions ADD COLUMN updated_at TEXT NOT NULL DEFAULT '';",
  "CREATE TABLE IF NOT EXISTS context_entries (project_slug TEXT NOT NULL, path TEXT NOT NULL, content_hash TEXT NOT NULL DEFAULT '', directory INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT '', PRIMARY KEY(project_slug, path));",
  "CREATE TABLE IF NOT EXISTS context_conflicts (id TEXT PRIMARY KEY, project_slug TEXT NOT NULL, path TEXT NOT NULL, base_revision INTEGER NOT NULL DEFAULT 0, base_present INTEGER NOT NULL DEFAULT 0, content_hash TEXT NOT NULL DEFAULT '', directory INTEGER NOT NULL DEFAULT 0, delete_flag INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT '');",
  "ALTER TABLE context_entries ADD COLUMN source TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE context_conflicts ADD COLUMN base_present INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE context_conflicts ADD COLUMN content_hash TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE context_conflicts ADD COLUMN directory INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE context_conflicts ADD COLUMN delete_flag INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE context_conflicts ADD COLUMN source TEXT NOT NULL DEFAULT '';"
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

/-- Maximum per-mission/job reserved scratch disk budget (`512 GiB`, matching API schema ceiling). -/
def maxReservedDiskGib : UInt64 := 512

/-- Parse existing `missions.tags` JSON array so custom non-system tags survive authority/lease updates. -/
def parseStringJsonArray (raw : String) : Array String :=
  match OrbBin.Json.parse raw with
  | .ok (.arr xs) => xs.filterMap (fun v => match v with | .str s => some s | _ => none)
  | _ => #[]

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

/-- Reconcile `dispatch_lease_intents` (`missions.db`) and `project_track_leases` (`projects.db`)
    deterministically on startup (`SM-08`), rolling back uncommitted `preparing` / `rejected` rows
    and clearing stale-boot leases without relying on ambient process mutexes or 6h TTL expiry. -/
def recoverDispatchLeases (mDb pDb : SqliteDb) (bootEpoch : UInt64 := 1) : IO (Except String Unit) := do
  let bootStr := s!"{bootEpoch}"
  let intentRows ← mDb.mu.atomically <|
    sqliteQueryRowsRaw mDb.handle
      "SELECT reservation_id,mission_id,project_slug,track,phase,boot_epoch,reserved_disk_gib FROM dispatch_lease_intents WHERE phase IN ('preparing','rejected') OR (phase='active' AND boot_epoch<>?1) OR (phase NOT IN ('rolled_back','released') AND NOT EXISTS (SELECT 1 FROM missions m WHERE m.id = dispatch_lease_intents.mission_id));"
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
      let mTagRows ← mDb.mu.atomically <|
        sqliteQueryRowsRaw mDb.handle
          "SELECT authority_mode,placement_kind,superseded_by_mission_id,orphaned_at,tags,reserved_disk_gib FROM missions WHERE id=?1;" #[mid]
      if let .ok mtrs := mTagRows then
        if mtrs.size > 1 && (((mtrs[1]![5]?).bind String.toNat?).getD 0) > 0 then
          let am := (mtrs[1]![0]?).getD "writer"
          let pk := (mtrs[1]![1]?).getD "managed"
          let sb := (mtrs[1]![2]?).getD ""
          let oa := (mtrs[1]![3]?).getD ""
          let ex := parseStringJsonArray ((mtrs[1]![4]?).getD "[]")
          let nextTags := projectCompatibilityTagsJson am pk sb oa 0 ex
          let diskRel ← mDb.mu.atomically <|
            sqliteQueryRowsRaw mDb.handle
              "UPDATE missions SET reserved_disk_gib=0, tags=?2, state_revision=state_revision+1 WHERE id=?1 AND reserved_disk_gib>0;" #[mid, nextTags]
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
        "SELECT d.phase,d.boot_epoch,CASE WHEN EXISTS (SELECT 1 FROM missions m WHERE m.id=d.mission_id) THEN '1' ELSE '0' END FROM dispatch_lease_intents d WHERE d.reservation_id=?1;" #[rid]
    let intentPhase := match chk with | .ok crs => (crs[1]?.bind (·[0]?)).getD "" | .error _ => ""
    let intentBoot := match chk with | .ok crs => (crs[1]?.bind (·[1]?)).getD "" | .error _ => ""
    let missionExists := match chk with | .ok crs => ((crs[1]?.bind (·[2]?)).getD "0") == "1" | .error _ => false
    if intentPhase == "active" && intentBoot == bootStr && missionExists then
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

private def hasStoreRawTrailerMarker (s : String) : Bool :=
  (s.splitOn "<!-- sandboxed:messages:v1:").length > 1

private def stripStoreDeferredTrailer (goal : String) : String × Option String :=
  let nlMarker := "\n<!-- sandboxed:messages:v1:"
  let nlParts := goal.splitOn nlMarker
  if nlParts.length ≥ 2 && (nlParts.getLast!).endsWith " -->" then
    let head := String.intercalate nlMarker (nlParts.dropLast)
    let b64 := ((nlParts.getLast!).dropEnd 4).toString
    (head, some b64)
  else
    let marker := "<!-- sandboxed:messages:v1:"
    let parts := goal.splitOn marker
    if parts.length < 2 then
      (goal, none)
    else
      let head := String.intercalate marker (parts.dropLast)
      let tail := parts.getLast!
      if tail.endsWith " -->" then
        let b64 := (tail.dropEnd 4).toString
        (head, some b64)
      else
        (goal, none)

private def isStoreCanonicalUuid (s : String) : Bool :=
  (parseUuidCanonical? s) == some s.toLower

private def parseStoreDeferredBatch? (b64 : String) : Except String (Array (String × String)) := do
  let some bytes := base64Decode? b64 | throw "deferred_batch_b64"
  let some txt := String.fromUTF8? bytes | throw "deferred_batch_utf8"
  let .ok jv := OrbBin.Json.parse txt | throw "deferred_batch_json"
  let some arr := jv.fieldArr? "messages" | throw "deferred_batch_messages"
  if arr.isEmpty then throw "deferred_batch_empty"
  let mut out : Array (String × String) := #[]
  let mut seen : Array String := #[]
  for item in arr do
    let some pair := item.asArr? | throw "deferred_batch_pair"
    if pair.size < 2 then throw "deferred_batch_pair"
    let some mid := pair[0]!.asStr? | throw "deferred_batch_id"
    let some content := pair[1]!.asStr? | throw "deferred_batch_content"
    let canon := mid.trimAscii.toString.toLower
    if !isStoreCanonicalUuid canon then throw "deferred_batch_uuid"
    if content.trimAscii.toString.isEmpty then throw "deferred_batch_content"
    if hasStoreRawTrailerMarker content then throw "deferred_batch_nested_trailer"
    if seen.any (· == canon) then throw "deferred_batch_dup"
    seen := seen.push canon
    out := out.push (canon, content)
  return out

private def extractStoreDeferredTrailerStrict (raw : String) : Except String (String × Option (Array (String × String))) := do
  let (plain, b64?) := stripStoreDeferredTrailer raw
  match b64? with
  | none =>
    if hasStoreRawTrailerMarker raw then
      throw "deferred_batch_unterminated"
    return (raw, none)
  | some b64 =>
    if hasStoreRawTrailerMarker plain then
      throw "deferred_batch_multiple"
    let msgs ← parseStoreDeferredBatch? b64
    return (plain, some msgs)

/-- Reconcile missions stranded in transitional `status = 'pending'` whose latest `mission_runs`
    row ended with `terminal_reason = 'remote_dispatch_failed'` (or whose mission row already carries
    a `remote_dispatch_failed` / `usage_limit_wait` / `node_maintenance_wait` pre-dispatch snapshot)
    and that have zero non-terminal runs and no `deferred_goal`, gated by `Orb.Kernel.remoteReplayStep 1` (`262`). -/
def reconcileStrandedPendingMissions (mDb : SqliteDb) (nowAt : String := "startup") : IO (Except String Nat) :=
  mDb.mu.atomically do
    if let .error e ← sqliteExecRaw mDb.handle "BEGIN IMMEDIATE;" then
      return .error s!"stranded_pending_begin_failed:{e}"
    let q ← sqliteQueryRowsRaw mDb.handle
      ("SELECT m.id, m.placement_kind, COALESCE(m.deferred_goal,''), COALESCE(m.terminal_reason,''), " ++
       "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal'), " ++
       "COALESCE((SELECT r2.terminal_reason FROM mission_runs r2 WHERE r2.mission_id=m.id ORDER BY r2.generation DESC, r2.rowid DESC LIMIT 1),'') " ++
       "FROM missions m WHERE m.status='pending';") #[]
    match q with
    | .error qe =>
      discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
      return .error s!"stranded_pending_select_failed:{qe}"
    | .ok rows =>
      let mut healed : Nat := 0
      for i in [1:rows.size] do
        let r := rows[i]!
        let mid := (r[0]?).getD ""
        let pKind := (r[1]?).getD "managed"
        let defGoal := ((r[2]?).getD "").trimAscii.toString
        let mReason := (r[3]?).getD ""
        let liveCnt := ((r[4]?.bind String.toNat?).getD 0)
        let latestRunReason := (r[5]?).getD ""
        let notClientPlaced : UInt8 := if pKind == "client" then 0 else 1
        let hasActiveOrDeferred : UInt8 := if liveCnt > 0 || !defGoal.isEmpty then 1 else 0
        let reasonFailed : UInt8 :=
          if latestRunReason == "remote_dispatch_failed" ||
             mReason == "remote_dispatch_failed" ||
             mReason == "usage_limit_wait" ||
             mReason == "node_maintenance_wait" then 1 else 0
        let verdict := Orb.Kernel.remoteReplayStep 1 1 notClientPlaced 1 reasonFailed hasActiveOrDeferred 0 0 0
        if verdict == 262 then
          let restoredReason :=
            if mReason == "usage_limit_wait" || mReason == "node_maintenance_wait" then mReason
            else "remote_dispatch_failed"
          let nextStatus := if restoredReason == "usage_limit_wait" then "waiting_rate_limit" else "interrupted"
          let upd ← sqliteQueryRowsRaw mDb.handle
            "UPDATE missions SET status=?2,terminal_reason=?3,resume_intent=CASE WHEN ?2='waiting_rate_limit' THEN 1 ELSE resume_intent END,state_revision=state_revision+1,updated_at=CASE WHEN ?4='' THEN updated_at ELSE ?4 END WHERE id=?1 AND status='pending';"
            #[mid, nextStatus, restoredReason, nowAt]
          if let .error ue := upd then
            discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
            return .error s!"stranded_pending_update_failed:{ue}"
          healed := healed + 1
      if let .error ce ← sqliteExecRaw mDb.handle "COMMIT;" then
        discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
        return .error s!"stranded_pending_commit_failed:{ce}"
      return .ok healed

def runStartupAndHealthReconcile (mDb : SqliteDb) (bootEpoch : UInt64) (nowAt : String := "startup") : IO (Except String Nat) := do
  match ← reconcileStrandedPendingMissions mDb nowAt with
  | .error e => return .error e
  | .ok healedPending =>
    mDb.mu.atomically do
      if let .error e ← sqliteExecRaw mDb.handle "BEGIN IMMEDIATE;" then
        return .error s!"shared_reconcile_begin_failed:{e}"
      let q ← sqliteQueryRowsRaw mDb.handle
        ("SELECT m.id,m.status,m.placement_kind,m.node_boot_epoch,m.orphaned_at," ++
         "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal')," ++
         "(SELECT COUNT(*) FROM mission_events ev WHERE ev.mission_id=m.id)," ++
         "(SELECT COUNT(*) FROM mission_continuations c WHERE c.mission_id=m.id AND c.phase=1)," ++
         "COALESCE(m.deferred_goal,'') FROM missions m;") #[]
      match q with
      | .error qe =>
        discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
        return .error s!"shared_reconcile_select_failed:{qe}"
      | .ok rows =>
        let mut extra : Nat := 0
        for i in [1:rows.size] do
          let r := rows[i]!
          let mid := (r[0]?).getD ""
          let status := (r[1]?).getD ""
          let pKind := (r[2]?).getD "managed"
          let rowBoot := ((r[3]?.bind String.toNat?).getD 1).toUInt64
          let orphAt := (r[4]?).getD ""
          let liveCnt := ((r[5]?.bind String.toNat?).getD 0)
          let evCnt := ((r[6]?.bind String.toNat?).getD 0)
          let armedContCnt := ((r[7]?.bind String.toNat?).getD 0)
          let defGoalRaw := (r[8]?).getD ""
          if hasStoreRawTrailerMarker defGoalRaw then
            if let .ok (strippedGoal, some msgs) := extractStoreDeferredTrailerStrict defGoalRaw then
              let seqRows ← sqliteQueryRowsRaw mDb.handle
                "SELECT COALESCE(MAX(batch_seq),0) FROM deferred_message_batches WHERE mission_id=?1;" #[mid]
              let nextBatchSeq :=
                match seqRows with
                | .ok srs => (((srs[1]?.bind (·[0]?)).bind String.toNat?).getD 0) + 1
                | .error _ => 1
              let mut dupFound := false
              for (bMid, _) in msgs do
                if let .ok drs ← sqliteQueryRowsRaw mDb.handle
                    "SELECT COUNT(*) FROM deferred_message_batches WHERE mission_id=?1 AND message_id=?2;" #[mid, bMid] then
                  if (((drs[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 0 then
                    dupFound := true
              if !dupFound then
                let markAt := if nowAt.isEmpty then "startup" else nowAt
                for (bMid, bContent) in msgs do
                  discard <| sqliteQueryRowsRaw mDb.handle
                    "INSERT INTO deferred_message_batches(mission_id,batch_seq,message_id,content,source,unpacked,created_at) VALUES(?1,?2,?3,?4,'reconcile',1,?5);"
                    #[mid, s!"{nextBatchSeq}", bMid, bContent, markAt]
                discard <| sqliteQueryRowsRaw mDb.handle
                  "UPDATE missions SET deferred_goal=?2 WHERE id=?1;" #[mid, strippedGoal]
          let statusCode : UInt8 :=
            if status == "active" then 0
            else if status == "awaiting_user" then 1
            else if status == "interrupted" then 2
            else 3
          let isClient : UInt8 := if pKind == "client" then 1 else 0
          let sameBoot : UInt8 := if rowBoot == bootEpoch then 1 else 0
          let alreadyOrph : UInt8 := if orphAt.isEmpty then 0 else 1
          let hasDurableBgScope : Bool := liveCnt > 0 || armedContCnt > 0
          let verdict := Orb.Kernel.reconcileStep
            statusCode isClient sameBoot 0 0 0
            (if liveCnt > 0 then 1 else 0) 0 (if evCnt > 0 then 1 else 0) alreadyOrph 0 0 0
          if verdict == 2 && orphAt.isEmpty then
            let markAt := if nowAt.isEmpty then "startup" else nowAt
            let upd ← sqliteQueryRowsRaw mDb.handle
              "UPDATE missions SET orphaned_at=?2,state_revision=state_revision+1 WHERE id=?1 AND orphaned_at='';"
              #[mid, markAt]
            if let .error ue := upd then
              discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
              return .error s!"shared_reconcile_orphan_failed:{ue}"
            extra := extra + 1
          else if status == "waiting_background" && sameBoot == 0 && !hasDurableBgScope then
            let markAt := if nowAt.isEmpty then "startup" else nowAt
            let _ ← sqliteQueryRowsRaw mDb.handle
              "INSERT INTO mission_supervision(mission_id,bg_wait_arms,stall_consecutive_arms,updated_at) VALUES(?1,1,0,?2) ON CONFLICT(mission_id) DO UPDATE SET bg_wait_arms=mission_supervision.bg_wait_arms+1,updated_at=excluded.updated_at;"
              #[mid, markAt]
            let upd ← sqliteQueryRowsRaw mDb.handle
              "UPDATE missions SET status='interrupted',terminal_reason='background_wait_reconciled',state_revision=state_revision+1 WHERE id=?1 AND status='waiting_background';"
              #[mid]
            if let .error ue := upd then
              discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
              return .error s!"shared_reconcile_bg_failed:{ue}"
            extra := extra + 1
        let qRows ← sqliteQueryRowsRaw mDb.handle
          "SELECT user_id,message_id,COALESCE(claim_boot_epoch,0) FROM remote_message_queue WHERE COALESCE(phase,0)=1;" #[]
        if let .ok qrs := qRows then
          for i in [1:qrs.size] do
            let qr := qrs[i]!
            let uid := (qr[0]?).getD ""
            let msgId := (qr[1]?).getD ""
            let cBoot := ((qr[2]?.bind String.toNat?).getD 0).toUInt64
            let outWord := Orb.Kernel.outboxCrashReconcileStep 1 0 1 cBoot bootEpoch 1 1
            if (outWord &&& 512) != 0 && cBoot != bootEpoch then
              let _ ← sqliteQueryRowsRaw mDb.handle
                "UPDATE remote_message_queue SET phase=3,state='crash_tombstone' WHERE user_id=?1 AND message_id=?2 AND COALESCE(phase,0)=1;"
                #[uid, msgId]
              let _ ← sqliteQueryRowsRaw mDb.handle
                "UPDATE queue_item_receipts SET phase=3 WHERE message_id=?1;" #[msgId]
              extra := extra + 1
        if let .error ce ← sqliteExecRaw mDb.handle "COMMIT;" then
          discard <| sqliteExecRaw mDb.handle "ROLLBACK;"
          return .error s!"shared_reconcile_commit_failed:{ce}"
        return .ok (healedPending + extra)

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
  let contInitRes : Except String Unit ← mDb.mu.atomically do
    if let .error e ← sqliteQueryRowsRaw mDb.handle harnessContinuitySchemaSql #[] then
      return .error e
    match ← sqliteQueryRowsRaw mDb.handle harnessContinuityIndexSql #[] with
    | .ok _ => return .ok ()
    | .error e => return .error e
  if let .error contErr := contInitRes then
    sqliteCloseRaw mDb.handle
    return .error s!"core_store_continuity_schema_failed:{contErr}"
  let effBootRes : Except String UInt64 ←
    if bootEpoch == 0 then allocateNextBootEpoch mDb else pure (.ok bootEpoch)
  let .ok effBoot := effBootRes | do
    sqliteCloseRaw mDb.handle
    return .error (match effBootRes with | .error e => e | .ok _ => "boot_epoch_failed")
  let pRes ← openSqliteDb s!"{trimmedRoot}/projects.db" projectsSchemaSql projectsAdditiveAlters
  let .ok pDb := pRes | do sqliteCloseRaw mDb.handle; return .error (match pRes with | .error e => e | .ok _ => "err")
  let aRes ← openSqliteDb s!"{trimmedRoot}/ask.db" askSchemaSql
  let .ok aDb := aRes | do sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; return .error (match aRes with | .error e => e | .ok _ => "err")
  let askNotesInitRes : Except String Unit ← aDb.mu.atomically do
    if let .error e ← sqliteQueryRowsRaw aDb.handle askMidturnSchemaSql #[] then
      return .error e
    match ← sqliteQueryRowsRaw aDb.handle askMidturnPendingIndexSql #[] with
    | .ok _ => return .ok ()
    | .error e => return .error e
  if let .error askNotesErr := askNotesInitRes then
    sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle
    return .error s!"core_store_ask_midturn_schema_failed:{askNotesErr}"
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
    match ← runStartupAndHealthReconcile mDb effBoot "" with
    | .error pendErr =>
      sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle; sqliteCloseRaw iDb.handle
      return .error s!"core_store_stranded_pending_recovery_failed:{pendErr}"
    | .ok _ =>
      let r7Ask :=
        "CREATE TABLE IF NOT EXISTS inbox_state (" ++
        "entry_key TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL DEFAULT '', " ++
        "stamp INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 0, " ++
        "client_id TEXT NOT NULL DEFAULT '', mutation_seq INTEGER NOT NULL DEFAULT 0);"
      let r7Proj :=
        "CREATE TABLE IF NOT EXISTS project_tracks (" ++
        "project_slug TEXT NOT NULL, track TEXT NOT NULL, desired_condition TEXT NOT NULL DEFAULT '', " ++
        "status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','satisfied','blocked','cancelled')), " ++
        "updated_at TEXT NOT NULL DEFAULT '', state_revision INTEGER NOT NULL DEFAULT 1, " ++
        "PRIMARY KEY(project_slug, track));" ++
        "CREATE TABLE IF NOT EXISTS context_entries (" ++
        "project_slug TEXT NOT NULL, path TEXT NOT NULL, content_hash TEXT NOT NULL DEFAULT '', " ++
        "directory INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0, " ++
        "size INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, " ++
        "source TEXT NOT NULL DEFAULT '', " ++
        "PRIMARY KEY(project_slug, path));" ++
        "CREATE TABLE IF NOT EXISTS context_heads (" ++
        "project_slug TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0);" ++
        "CREATE TABLE IF NOT EXISTS context_conflicts (" ++
        "id TEXT PRIMARY KEY, project_slug TEXT NOT NULL, path TEXT NOT NULL, " ++
        "base_revision INTEGER NOT NULL DEFAULT 0, base_present INTEGER NOT NULL DEFAULT 0, " ++
        "content_hash TEXT NOT NULL DEFAULT '', directory INTEGER NOT NULL DEFAULT 0, " ++
        "delete_flag INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT '', " ++
        "created_at TEXT NOT NULL DEFAULT '');" ++
        "CREATE TABLE IF NOT EXISTS context_history (" ++
        "project_slug TEXT NOT NULL, revision INTEGER NOT NULL, path TEXT NOT NULL, " ++
        "content_hash TEXT NOT NULL DEFAULT '', directory INTEGER NOT NULL DEFAULT 0, " ++
        "size INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, " ++
        "source TEXT NOT NULL DEFAULT '', " ++
        "PRIMARY KEY(project_slug, revision));" ++
        "CREATE TABLE IF NOT EXISTS context_receipts (" ++
        "op_id TEXT PRIMARY KEY, project_slug TEXT NOT NULL, conflict INTEGER NOT NULL, " ++
        "revision INTEGER NOT NULL);"
      let r7ProjAlters : Array String := #[
        "ALTER TABLE context_entries ADD COLUMN source TEXT NOT NULL DEFAULT '';",
        "ALTER TABLE context_conflicts ADD COLUMN base_present INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE context_conflicts ADD COLUMN content_hash TEXT NOT NULL DEFAULT '';",
        "ALTER TABLE context_conflicts ADD COLUMN directory INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE context_conflicts ADD COLUMN delete_flag INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE context_conflicts ADD COLUMN source TEXT NOT NULL DEFAULT '';"
      ]
      let r7Miss :=
        "CREATE TABLE IF NOT EXISTS mission_board_tasks (" ++
        "task_key TEXT PRIMARY KEY, project_slug TEXT NOT NULL, track TEXT NOT NULL, " ++
        "mission_id TEXT NOT NULL, attempt_seq INTEGER NOT NULL DEFAULT 0, " ++
        "status TEXT NOT NULL DEFAULT 'open');" ++
        "CREATE TABLE IF NOT EXISTS deploy_receipts (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT, unit_name TEXT NOT NULL, " ++
        "observed_digest TEXT NOT NULL, exec_digest TEXT NOT NULL, " ++
        "verdict TEXT NOT NULL, dry_run INTEGER NOT NULL DEFAULT 0, " ++
        "created_at TEXT NOT NULL DEFAULT '');"
      let r7AskRes ← aDb.mu.atomically (sqliteExecRaw aDb.handle r7Ask)
      let r7ProjRes ← pDb.mu.atomically do
        match ← sqliteExecRaw pDb.handle r7Proj with
        | .error e => return .error e
        | .ok () => applyAdditiveAlters pDb.handle r7ProjAlters
      let r7MissRes ← mDb.mu.atomically (sqliteExecRaw mDb.handle r7Miss)
      if let .error r7Err := r7AskRes then
        sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle; sqliteCloseRaw iDb.handle
        return .error s!"core_store_r7_schema_failed:{r7Err}"
      if let .error r7Err := r7ProjRes then
        sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle; sqliteCloseRaw iDb.handle
        return .error s!"core_store_r7_schema_failed:{r7Err}"
      if let .error r7Err := r7MissRes then
        sqliteCloseRaw mDb.handle; sqliteCloseRaw pDb.handle; sqliteCloseRaw aDb.handle; sqliteCloseRaw iDb.handle
        return .error s!"core_store_r7_schema_failed:{r7Err}"
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

private def isIntegerCol (col : String) : Bool :=
  col == "enabled" || col == "revision" || col == "total_cost_cents" || col == "generation" ||
  col == "parallel_missions" || col == "state_revision" || col == "reserved_disk_gib" ||
  col == "owner_epoch" || col == "run_generation" || col == "node_boot_epoch" ||
  col == "phase" || col == "delivered" || col == "committed_oversize" || col == "body_bytes" ||
  col == "status_code" || col == "verified" || col == "retries" || col == "max_retries" ||
  col == "replays" || col == "deadline_epoch" || col == "not_before" || col == "resume_intent" ||
  col == "claimed_generation" || col == "claim_boot_epoch" || col == "delivered_seq" ||
  col == "edit_revision" || col == "batch_seq" || col == "unpacked" || col == "due_epoch" ||
  col == "stop_after_first" || col == "bg_wait_arms" || col == "stall_consecutive_arms"

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
      | "waiting_rate_limit" => "waiting_rate_limit"
      | "pending" => "pending"
      | "interrupted" => "interrupted"
      | "awaiting_user" => "awaiting_user"
      | "active" =>
        let stepCode := Orb.Kernel.missionStep 1 0 0 (if wakeupArmed then 1 else 0) 1 0 3 0 10 0
        if stepCode == 4 then "paused_wakeup" else "healthy"
      | _ => "unknown"

private def isRawJsonCol (col : String) : Bool :=
  col == "models_json" || col == "data" || col == "history_json" || col == "tags" || col == "allowed_units_json" || col == "payload" || col == "variables_used"

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
  if m.reservedDiskGib > maxReservedDiskGib then
    return .error s!"invalid_reserved_disk_gib:{m.reservedDiskGib}"
  let compatTags :=
    projectCompatibilityTagsJson m.authorityMode m.placementKind m.supersededById m.orphanedAt m.reservedDiskGib
      (parseStringJsonArray m.tagsJson)
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

/-- Insert a brand-new mission row (`POST /api/control/missions`), failing with `mission_already_exists`
    if `m.id` is already present so caller error-cleanup never mutates or deletes pre-existing missions. -/
def insertNewMission (st : CoreStore) (m : MissionRecord) : IO (Except String Unit) := do
  if m.authorityMode != "readonly" && m.authorityMode != "writer" then
    return .error s!"invalid_authority_mode:{m.authorityMode}"
  if m.reservedDiskGib > maxReservedDiskGib then
    return .error s!"invalid_reserved_disk_gib:{m.reservedDiskGib}"
  let compatTags :=
    projectCompatibilityTagsJson m.authorityMode m.placementKind m.supersededById m.orphanedAt m.reservedDiskGib
      (parseStringJsonArray m.tagsJson)
  let rev := if m.stateRevision == 0 then 1 else m.stateRevision
  let ownEp := if m.ownerEpoch == 0 then 1 else m.ownerEpoch
  let runGen := if m.runGeneration == 0 then 1 else m.runGeneration
  let bootEp := if m.nodeBootEpoch == 0 then 1 else m.nodeBootEpoch
  withImmediateTx st.missionsDb do
    let existing ← execParamQueryUnlocked st.missionsDb "SELECT id FROM missions WHERE id=?1;" #[m.id]
    let .ok ers := existing | return .error "mission_exists_check_failed"
    if ers.size > 1 then
      return .error "mission_already_exists"
    let sql :=
      "INSERT INTO missions(id,title,status,backend,model_override,model_effort,working_directory,project,updated_at,total_cost_cents,authority_mode,placement_kind,superseded_by_mission_id,orphaned_at,reserved_disk_gib,state_revision,owner_epoch,run_generation,node_boot_epoch,tags,track,repo) " ++
      "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22);"
    let res ← execParamQueryUnlocked st.missionsDb sql #[
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
  else if nextReservedDiskGib > maxReservedDiskGib then
    pure (.error s!"invalid_reserved_disk_gib:{nextReservedDiskGib}")
  else
    withImmediateTx st.missionsDb do
      let curRows ← execParamQueryUnlocked st.missionsDb
        "SELECT owner_epoch,run_generation,node_boot_epoch,state_revision,tags FROM missions WHERE id=?1;"
        #[missionId]
      let .ok rs := curRows | return .error "cas_select_failed"
      if rs.size ≤ 1 then
        return .error "mission_not_found"
      let r := rs[1]!
      let durOwner := ((r[0]?.bind String.toNat?).getD 1).toUInt64
      let durRun := ((r[1]?.bind String.toNat?).getD 1).toUInt64
      let durBoot := ((r[2]?.bind String.toNat?).getD 1).toUInt64
      let durRev := ((r[3]?.bind String.toNat?).getD 1).toUInt32
      let prevExtraTags := parseStringJsonArray ((r[4]?).getD "[]")
      let fenceWord := Orb.Kernel.epochFenceStep
        durOwner liveOwnerEpoch durRun liveRunGen durBoot liveBootEpoch durRev expectedRev writerOwnerEpoch
      let lo32 := (fenceWord &&& 0xFFFFFFFF).toUInt32
      let nextRev := (fenceWord >>> 32).toUInt32
      if (lo32 &&& 256) == 0 then
        let reason := lo32 &&& 0xFF
        return .error s!"cas_fence_rejected:{reason}:expected={expectedRev}:actual={durRev}"
      let compatTags := projectCompatibilityTagsJson
        nextAuthorityMode nextPlacementKind nextSupersededBy nextOrphanedAt nextReservedDiskGib prevExtraTags
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
  if req.reservedDiskGib > maxReservedDiskGib then
    return .error s!"invalid_reserved_disk_gib:{req.reservedDiskGib}"
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
  -- Track exclusivity is scoped to `project_slug`, while non-empty repository/PR writer exclusivity
  -- applies globally across all projects (`SM-08`), preventing cross-project PR writer split-brain.
  let projRes ← withImmediateTx st.projectsDb do
    let existing ← execParamQueryUnlocked st.projectsDb
      "SELECT project_slug,mission_id,track,repo,authority_mode,phase FROM project_track_leases WHERE phase IN ('preparing','active');"
      #[]
    let .ok rs := existing | return .error "project_lease_query_failed"
    for i in [1:rs.size] do
      let r := rs[i]!
      let otherProj := (r[0]?).getD ""
      let otherMid := (r[1]?).getD ""
      let otherTrack := (r[2]?).getD ""
      let otherRepo := (r[3]?).getD ""
      let otherMode := (r[4]?).getD "writer"
      let otherPhase := (r[5]?).getD "active"
      if otherMid != req.missionId then
        let inUnresolved : UInt8 := if otherPhase == "preparing" then 1 else 0
        let hasLiveOwner : UInt8 := if otherPhase == "active" then 1 else 0
        let holds := Orb.Kernel.verifyTrackHold inUnresolved 0 hasLiveOwner 0
        if holds == 1 then
          if otherProj == req.projectSlug && otherTrack == req.track && (req.authorityMode == "writer" || otherMode == "writer") then
            return .error s!"track_writer_conflict:{otherMid}"
          if req.authorityMode == "writer" && otherMode == "writer" then
            if otherProj == req.projectSlug && (!req.repo.isEmpty || !otherRepo.isEmpty) then
              let hKnown : UInt8 := if otherRepo.isEmpty then 0 else 1
              let tKnown : UInt8 := if req.repo.isEmpty then 0 else 1
              let sameRepo : UInt8 := if otherRepo == req.repo then 1 else 0
              if Orb.Kernel.verifyRepoDisjoint hKnown tKnown sameRepo == 0 then
                return .error s!"repo_writer_conflict:{otherMid}"
            else if !req.repo.isEmpty && !otherRepo.isEmpty then
              let sameRepo : UInt8 := if otherRepo == req.repo then 1 else 0
              if Orb.Kernel.verifyRepoDisjoint 1 1 sameRepo == 0 then
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
      let mRows ← execParamQueryUnlocked st.missionsDb
        "SELECT placement_kind,superseded_by_mission_id,orphaned_at,tags FROM missions WHERE id=?1;" #[req.missionId]
      let pk := match mRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "managed" | .error _ => "managed"
      let sb := match mRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
      let oa := match mRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
      let ex := match mRows with | .ok rs => parseStringJsonArray ((rs[1]?.bind (·[3]?)).getD "[]") | .error _ => #[]
      let leaseTags := projectCompatibilityTagsJson req.authorityMode pk sb oa req.reservedDiskGib ex
      let u1 ← execParamQueryUnlocked st.missionsDb
        "UPDATE dispatch_lease_intents SET phase='active',updated_at=?2 WHERE reservation_id=?1;"
        #[req.reservationId, req.nowAt]
      if let .error e := u1 then return .error e
      let u2 ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET project=?2,track=?3,repo=?4,authority_mode=?5,reserved_disk_gib=?6,tags=?8,state_revision=state_revision+1,updated_at=?7 WHERE id=?1;"
        #[req.missionId, req.projectSlug, req.track, req.repo, req.authorityMode, s!"{req.reservedDiskGib}", req.nowAt, leaseTags]
      return u2.map (fun _ => ())
    if let .error e := actRes then
      discard <| recoverDispatchLeases st.missionsDb st.projectsDb req.bootEpoch
      return .error e
    let projActRes ← withImmediateTx st.projectsDb do
      let pu ← execParamQueryUnlocked st.projectsDb
        "UPDATE project_track_leases SET phase='active',updated_at=?2 WHERE reservation_id=?1;"
        #[req.reservationId, req.nowAt]
      return pu.map (fun _ => ())
    match projActRes with
    | .ok () => return .ok ()
    | .error pe =>
      -- Phase 3b failed after the missions intent was promoted: roll the reservation back instead of
      -- leaving an active lease that the caller will treat as a failed admission.
      let rollbackTags := projectCompatibilityTagsJson req.authorityMode "managed" "" "" 0
      discard <| withImmediateTx st.missionsDb do
        let mRows ← execParamQueryUnlocked st.missionsDb
          "SELECT placement_kind,superseded_by_mission_id,orphaned_at,tags FROM missions WHERE id=?1;" #[req.missionId]
        let pk := match mRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "managed" | .error _ => "managed"
        let sb := match mRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
        let oa := match mRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
        let ex := match mRows with | .ok rs => parseStringJsonArray ((rs[1]?.bind (·[3]?)).getD "[]") | .error _ => #[]
        let rbTags := if mRows.isOk then projectCompatibilityTagsJson req.authorityMode pk sb oa 0 ex else rollbackTags
        discard <| execParamQueryUnlocked st.missionsDb
          "UPDATE dispatch_lease_intents SET phase='rolled_back',updated_at=?2 WHERE reservation_id=?1;"
          #[req.reservationId, req.nowAt]
        execParamQueryUnlocked st.missionsDb
          "UPDATE missions SET reserved_disk_gib=0,tags=?3,state_revision=state_revision+1,updated_at=?2 WHERE id=?1;"
          #[req.missionId, req.nowAt, rbTags]
      discard <| withImmediateTx st.projectsDb do
        execParamQueryUnlocked st.projectsDb
          "DELETE FROM project_track_leases WHERE reservation_id=?1;" #[req.reservationId]
      discard <| recoverDispatchLeases st.missionsDb st.projectsDb req.bootEpoch
      return .error pe

/-- Release an active cross-DB dispatch track lease cleanly across `projects.db` and `missions.db`. -/
def releaseDispatchTrackLease (st : CoreStore) (reservationId nowAt : String) : IO (Except String Unit) := do
  let pRes ← withImmediateTx st.projectsDb do
    let d ← execParamQueryUnlocked st.projectsDb
      "DELETE FROM project_track_leases WHERE reservation_id=?1;" #[reservationId]
    return d.map (fun _ => ())
  if let .error e := pRes then return .error e
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT mission_id,authority_mode,reserved_disk_gib FROM dispatch_lease_intents WHERE reservation_id=?1;" #[reservationId]
    let mid := match rows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
    let mode := match rows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "writer" | .error _ => "writer"
    let u1 ← execParamQueryUnlocked st.missionsDb
      "UPDATE dispatch_lease_intents SET phase='released',updated_at=?2 WHERE reservation_id=?1;"
      #[reservationId, nowAt]
    if let .error e := u1 then return .error e
    if !mid.isEmpty then
      let mRows ← execParamQueryUnlocked st.missionsDb
        "SELECT placement_kind,superseded_by_mission_id,orphaned_at,tags FROM missions WHERE id=?1;" #[mid]
      let pk := match mRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "managed" | .error _ => "managed"
      let sb := match mRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
      let oa := match mRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
      let ex := match mRows with | .ok rs => parseStringJsonArray ((rs[1]?.bind (·[3]?)).getD "[]") | .error _ => #[]
      let releasedTags := projectCompatibilityTagsJson mode pk sb oa 0 ex
      let u2 ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET reserved_disk_gib=0,tags=?3,state_revision=state_revision+1,updated_at=?2 WHERE id=?1;"
        #[mid, nowAt, releasedTags]
      if let .error e := u2 then return .error e
    return .ok ()

/-- Record mission opened timestamp (`mark_mission_opened` capability parity). -/
def mark_mission_opened (st : CoreStore) (missionId openedAt : String) : IO (Except String Unit) := do
  let res ← execParamQuery st.missionsDb
    "UPDATE missions SET opened_at=?2, updated_at=?2 WHERE id=?1;" #[missionId, openedAt]
  return res.map (fun _ => ())

/-- Fetch one mission row, or `none` when it does not exist. -/
def getMission? (st : CoreStore) (missionId : String) : IO (Option MissionRecord) := do
  if missionId.isEmpty then return none
  match ← execParamQuery st.missionsDb
    "SELECT id,title,status,backend,COALESCE(model_override,''),COALESCE(model_effort,''),working_directory,COALESCE(project,''),updated_at,total_cost_cents FROM missions WHERE id=?1;" #[missionId] with
  | .error _ => return none
  | .ok rows =>
    if rows.size ≤ 1 then return none
    let r := rows[1]!
    return some {
      id               := (r[0]?).getD ""
      title            := (r[1]?).getD ""
      status           := (r[2]?).getD ""
      backend          := (r[3]?).getD ""
      modelOverride    := (r[4]?).getD ""
      modelEffort      := (r[5]?).getD ""
      workingDirectory := (r[6]?).getD ""
      project          := (r[7]?).getD ""
      updatedAt        := (r[8]?).getD ""
      totalCostCents   := (((r[9]?).bind String.toNat?).getD 0).toUInt64
    }

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

/-- Convert Unix epoch seconds (`1970-01-01T00:00:00Z = 0`) into canonical ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`)
    using the Howard Hinnant civil-from-days algorithm (`0 import Lean`, `SM-07`). -/
def formatEpochIso8601Utc (epochSecs : UInt64) : String :=
  let totalSecs : Nat := epochSecs.toNat
  let daySecs : Nat := totalSecs % 86400
  let hh : Nat := daySecs / 3600
  let mm : Nat := (daySecs % 3600) / 60
  let ss : Nat := daySecs % 60
  let z : Int := Int.ofNat (totalSecs / 86400) + 719468
  let era : Int := (if z ≥ 0 then z else z - 146096) / 146097
  let doe : Nat := (z - era * 146097).toNat
  let yoe : Nat := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y : Int := Int.ofNat yoe + era * 400
  let doy : Nat := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp : Nat := (5 * doy + 2) / 153
  let d : Nat := doy - (153 * mp + 2) / 5 + 1
  let m : Nat := if mp < 10 then mp + 3 else mp - 9
  let yr : Int := if m ≤ 2 then y + 1 else y
  let pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else s!"{n}"
  let pad4 (n : Int) : String :=
    let k := n.toNat
    if k < 10 then s!"000{k}"
    else if k < 100 then s!"00{k}"
    else if k < 1000 then s!"0{k}"
    else s!"{k}"
  s!"{pad4 yr}-{pad2 m}-{pad2 d}T{pad2 hh}:{pad2 mm}:{pad2 ss}Z"

private def isLeapYearUtc (y : Nat) : Bool :=
  (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

private def daysInMonthUtc (y m : Nat) : Nat :=
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
  | 4 | 6 | 9 | 11 => 30
  | 2 => if isLeapYearUtc y then 29 else 28
  | _ => 0

/-- Parse an ISO-8601 / RFC-3339 timestamp (`YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`) into `UInt64` UTC epoch seconds (`>= 0`). -/
def parseIso8601EpochU64? (s : String) : Option UInt64 := do
  if s.trimAscii.toString != s then none
  let (datePart, rest0) ← match s.splitOn "T" with
    | [d, t] => some (d, t)
    | _ => match s.splitOn "t" with
      | [d, t] => some (d, t)
      | _ => none
  let [yStr, mStr, dStr] := datePart.splitOn "-" | none
  if yStr.length != 4 || mStr.length != 2 || dStr.length != 2 then none
  if !yStr.all Char.isDigit || !mStr.all Char.isDigit || !dStr.all Char.isDigit then none
  let y ← yStr.toNat?
  let mo ← mStr.toNat?
  let da ← dStr.toNat?
  if y < 1970 || mo < 1 || mo > 12 || da < 1 || da > daysInMonthUtc y mo then none
  let (timePart, tzOffsetSec) ←
    if rest0.endsWith "Z" || rest0.endsWith "z" then
      some ((rest0.dropEnd 1).toString, (0 : Int))
    else if rest0.length > 6 then
      let tzSignPos := rest0.length - 6
      let pfx := (rest0.take tzSignPos).toString
      let sfx := (rest0.drop tzSignPos).toString
      let signChar := sfx.toList.headD ' '
      if signChar != '+' && signChar != '-' then none
      else
        match (sfx.drop 1).toString.splitOn ":" with
        | [ohS, omS] =>
          if ohS.length != 2 || omS.length != 2 || !ohS.all Char.isDigit || !omS.all Char.isDigit then none
          else
            let oh ← ohS.toNat?
            let om ← omS.toNat?
            if oh > 23 || om > 59 then none
            else
              let mag : Int := Int.ofNat (oh * 3600 + om * 60)
              some (pfx, if signChar == '+' then mag else -mag)
        | _ => none
    else none
  let baseTime ← match timePart.splitOn "." with
    | [h] => some h
    | [h, frac] =>
      if !frac.isEmpty && frac.all Char.isDigit then some h else none
    | _ => none
  let [hhS, mmS, ssS] := baseTime.splitOn ":" | none
  if hhS.length != 2 || mmS.length != 2 || ssS.length != 2 then none
  if !hhS.all Char.isDigit || !mmS.all Char.isDigit || !ssS.all Char.isDigit then none
  let hh ← hhS.toNat?
  let mm ← mmS.toNat?
  let ss ← ssS.toNat?
  if hh > 23 || mm > 59 || ss > 60 then none
  let mut yearDays : Nat := 0
  for yr in [1970:y] do
    yearDays := yearDays + (if isLeapYearUtc yr then 366 else 365)
  let mut monthDays : Nat := 0
  for mn in [1:mo] do
    monthDays := monthDays + daysInMonthUtc y mn
  let totalDays : Int := Int.ofNat (yearDays + monthDays + (da - 1))
  let utcSec : Int := totalDays * 86400 + Int.ofNat (hh * 3600 + mm * 60 + ss) - tzOffsetSec
  if utcSec < 0 then none else some utcSec.toNat.toUInt64

/-- Normalize any continuation timestamp string: if already valid ISO-8601, return canonical UTC `Z`;
    if decimal epoch seconds, format as ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`). -/
def normalizeContinuationIso8601 (raw : String) (fallbackEpoch : UInt64 := 0) : String :=
  let t := raw.trimAscii.toString
  if let some ep := parseIso8601EpochU64? t then
    formatEpochIso8601Utc ep
  else if let some n := t.toNat? then
    formatEpochIso8601Utc n.toUInt64
  else
    formatEpochIso8601Utc fallbackEpoch

/-- Format continuation `next_at` JSON field value (`null` when `trigger_kind == "job"` or `due == 0`,
    otherwise JSON-escaped ISO-8601 UTC `YYYY-MM-DDTHH:MM:SSZ`). -/
def renderContinuationNextAtJson (triggerKind : String) (dueEpoch : UInt64) : String :=
  if triggerKind == "job" || dueEpoch == 0 then "null"
  else jsonEscape (formatEpochIso8601Utc dueEpoch)

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
    "m.tags," ++
    "(SELECT COUNT(*) FROM mission_continuations c WHERE c.mission_id=m.id AND c.phase=1) AS armed_wakeups," ++
    "COALESCE(e.verified,1) AS ev_verified " ++
    "FROM missions m LEFT JOIN mission_terminal_evidence e ON e.mission_id = m.id " ++
    "ORDER BY m.updated_at DESC, m.id ASC;"
  let rows ← execParamQuery st.missionsDb sql #[]
  let contRows ← execParamQuery st.missionsDb
    ("SELECT mission_id,id,phase,due_epoch,trigger_kind,reason,source,error,recurrence " ++
     "FROM mission_continuations WHERE phase IN (1,2,3) ORDER BY due_epoch ASC, id ASC;") #[]
  let contItemsByMission : String → Array String := fun mid =>
    match contRows with
    | .error _ => #[]
    | .ok crs =>
      if crs.size ≤ 1 then #[]
      else Id.run do
        let mut acc : Array String := #[]
        for ci in [1:crs.size] do
          let cr := crs[ci]!
          if (cr[0]?).getD "" == mid then
            let cid := (cr[1]?).getD ""
            let cphase := ((cr[2]?.bind String.toNat?).getD 1).toUInt8
            let cdue := (cr[3]?.bind String.toNat?).getD 0
            let ctrig := (cr[4]?).getD "time"
            let creason := (cr[5]?).getD ""
            let csrc := (cr[6]?).getD ""
            let cerr := (cr[7]?).getD ""
            let crec := (cr[8]?).getD ""
            let cstate :=
              if cphase == 2 then (if ctrig == "delivery" then "waiting_for_client" else "queued")
              else if cphase == 3 then "error"
              else "scheduled"
            let srcJson := if csrc.isEmpty then "" else s!",\"source\":{jsonEscape csrc}"
            let errJson := if cerr.isEmpty then "" else s!",\"error\":{jsonEscape cerr}"
            let recJson := if crec.isEmpty then "" else s!",\"recurrence\":{jsonEscape crec}"
            acc := acc.push (
              s!"\{\"id\":{jsonEscape cid},\"state\":{jsonEscape cstate}," ++
              s!"\"next_at\":{renderContinuationNextAtJson ctrig cdue.toUInt64},\"trigger\":{jsonEscape ctrig},\"reason\":{jsonEscape creason}{srcJson}{errJson}{recJson}}")
        return acc
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
        let armedWakeups := (r[24]?.bind String.toNat?).getD 0
        let evVerified := ((r[25]?.bind String.toNat?).getD 1) != 0
        let effReason := if !evReason.isEmpty then evReason else mTermReason
        let hasEv := !evRecorded.isEmpty || !evReason.isEmpty
        let verdict := deriveMissionHealthVerdict
          c2 effReason orphAt superBy placeKind
          (rowBoot == nodeBootEpoch) false (liveRuns > 0) (evCnt > 0) (armedWakeups > 0) hasEv
        let evJson :=
          if hasEv then
            s!"\{\"terminal_reason\":{jsonEscape evReason},\"summary\":{jsonEscape evSummary},\"artifact_ref\":{jsonEscape evArtifact},\"verified\":{if evVerified then "true" else "false"},\"recorded_at\":{jsonEscape evRecorded}}"
          else "null"
        let cItems := contItemsByMission c0
        let contJson := s!"\{\"count\":{cItems.size},\"items\":[{String.intercalate "," cItems.toList}]}"
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
          s!"\"health_verdict\":{jsonEscape verdict},\"terminal_evidence\":{evJson},\"continuation\":{contJson},\"tags\":{tagsOut}}"
        )
      return "[" ++ String.intercalate "," items.toList ++ "]")

/-- Check whether `status` permits starting a machine transfer. -/
def isStatusMovable (status : String) : Bool :=
  status == "awaiting_user" || status == "completed" || status == "failed" ||
  status == "interrupted" || status == "paused" || status == "blocked" ||
  status == "not_feasible" || status == "acknowledged" || status == "waiting_rate_limit"

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
    "INSERT OR REPLACE INTO privilege_leases(grant_id,lease_token,mission_id,target_host,scope,allowed_units_json,require_force_cmd,biometric_signed,revoked,expires_at_epoch,lease_epoch) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11);"
    #[rec.grantId, rec.leaseToken, rec.missionId, rec.targetHost, rec.scope, rec.allowedUnitsJson,
      if rec.requireForceCmd then "1" else "0",
      if rec.biometricSigned then "1" else "0",
      if rec.revoked then "1" else "0",
      s!"{rec.expiresAtEpoch}",
      s!"{rec.leaseEpoch}"]
  return res.map (fun _ => ())

/-- Look up a privilege lease by `lease_token` in `missions.db`. -/
def lookupPrivilegeLease? (st : CoreStore) (leaseToken : String) : IO (Option PrivilegeLeaseRecord) := do
  if leaseToken.isEmpty then return none
  match ← execParamQuery st.missionsDb
    "SELECT grant_id,lease_token,mission_id,target_host,scope,allowed_units_json,require_force_cmd,biometric_signed,revoked,expires_at_epoch,lease_epoch FROM privilege_leases WHERE lease_token=?1;" #[leaseToken] with
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
      leaseEpoch       := (((r[10]?).bind String.toNat?).getD 0).toUInt64
    }

/-- Persistent bunker lattice (`0` normal, `1` soft, `2` hard). Shared by every process on this store. -/
def readPersistedBunkerState (st : CoreStore) : IO UInt8 := do
  match ← execParamQuery st.missionsDb
      "SELECT bunker_state FROM core_boot_state WHERE singleton_id=1;" #[] with
  | .ok rows =>
    let n := ((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    pure (if n ≥ 2 then 2 else n.toUInt8)
  | .error _ => pure 0

def writePersistedBunkerState (st : CoreStore) (state : UInt8) : IO (Except String Unit) := do
  let clamped : Nat := if state.toNat ≥ 2 then 2 else state.toNat
  let res ← execParamQuery st.missionsDb
    "INSERT INTO core_boot_state(singleton_id,boot_epoch,bunker_state) VALUES(1,0,?1) ON CONFLICT(singleton_id) DO UPDATE SET bunker_state=excluded.bunker_state;"
    #[s!"{clamped}"]
  return res.map (fun _ => ())

/-- Live writer missions: non-terminal runs plus active writer track leases. -/
def countLiveWriters (st : CoreStore) : IO (Except String UInt32) := do
  let runs ← execParamQuery st.missionsDb
    "SELECT COUNT(*) FROM mission_runs WHERE execution_state NOT IN ('terminal','failed','cancelled','completed');" #[]
  let leases ← execParamQuery st.projectsDb
    "SELECT COUNT(*) FROM project_track_leases WHERE phase IN ('preparing','active') AND authority_mode='writer';" #[]
  match runs, leases with
  | .ok rr, .ok lr =>
    let n := ((rr[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    let m := ((lr[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    let sum := n + m
    pure (.ok (Nat.min sum 0xFFFFFFFF).toUInt32)
  | .error e, _ => pure (.error e)
  | _, .error e => pure (.error e)

/-- Wall-clock seconds of the newest non-dry-run admitted deploy of `unitName`, if any. -/
def lastAdmittedDeployEpoch? (st : CoreStore) (unitName : String) : IO (Option UInt64) := do
  match ← execParamQuery st.missionsDb
      "SELECT created_at FROM deploy_receipts WHERE unit_name=?1 AND verdict='admitted' AND dry_run=0 ORDER BY id DESC LIMIT 1;"
      #[unitName] with
  | .ok rows =>
    match (rows[1]?.bind (·[0]?)).bind String.toNat? with
    | some n => pure (some n.toUInt64)
    | none => pure none
  | .error _ => pure none

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

/-- Enqueue a waiting remote follow-up. Replaying the same id returns its current content without moving it.
    Strips any `<!-- sandboxed:messages:v1:<b64> -->` trailer into `deferred_message_batches` (`SM-05`)
    and fails closed on malformed trailers or duplicate batch UUIDs. -/
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
      let (plain, batchMsgs?) ←
        match extractStoreDeferredTrailerStrict content with
        | .error e => return .error e
        | .ok p => pure p
      if plain.trimAscii.toString.isEmpty then
        return .error "deferred_batch_content"
      if let some msgs := batchMsgs? then
        let seqRows ← execParamQueryUnlocked st.missionsDb
          "SELECT COALESCE(MAX(batch_seq),0) FROM deferred_message_batches WHERE mission_id=?1;" #[missionId]
        let .ok srs := seqRows | return .error "deferred_batch_seq_failed"
        let batchSeq := (((srs[1]?.bind (·[0]?)).bind String.toNat?).getD 0) + 1
        for (mid, _) in msgs do
          let dupBatch ← execParamQueryUnlocked st.missionsDb
            "SELECT COUNT(*) FROM deferred_message_batches WHERE mission_id=?1 AND message_id=?2;" #[missionId, mid]
          let .ok drs := dupBatch | return .error "deferred_batch_dup_check_failed"
          if (((drs[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 0 then
            return .error "deferred_batch_dup"
        for (mid, c) in msgs do
          let insB ← execParamQueryUnlocked st.missionsDb
            "INSERT INTO deferred_message_batches(mission_id,batch_seq,message_id,content,source,unpacked,created_at) VALUES(?1,?2,?3,?4,?5,1,'');"
            #[missionId, s!"{batchSeq}", mid, c, source?.getD ""]
          if let .error e := insB then return .error e
      let ins ← execParamQueryUnlocked st.missionsDb
        "INSERT INTO remote_message_queue(user_id,message_id,mission_id,payload,state,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision) VALUES(?1,?2,?3,?4,'waiting',0,0,0,0,0);"
        #[userId, messageId, missionId, queuePayload plain missionId source?]
      if let .error e := ins then return .error e
      let rec ← execParamQueryUnlocked st.missionsDb
        "INSERT INTO queue_item_receipts(message_id,mission_id,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision,content,source,updated_at) VALUES(?1,?2,0,0,0,0,0,?3,?4,'') ON CONFLICT(message_id) DO NOTHING;"
        #[messageId, missionId, plain, source?.getD ""]
      match rec with
      | .error e => return .error e
      | .ok _ => return .ok plain

/-- List one mission's waiting queue in FIFO order (`sequence ASC`). -/
def listRemoteQueueJson (st : CoreStore) (userId missionId : String) : IO (Except String String) := do
  let rows ← execParamQuery st.missionsDb
    "SELECT sequence,message_id,mission_id,payload,state FROM remote_message_queue WHERE user_id=?1 AND mission_id=?2 AND state='waiting' AND COALESCE(phase,0)=0 AND json_extract(payload,'$.job_id') IS NULL ORDER BY sequence ASC;"
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

/-- Edit a waiting unbound row in place via `Orb.Lifecycle.stepQueueSlice` (`opCode = 6`, `SM-04`/`SM-05`).
    Bound or non-waiting rows (`claimed`/`delivered`/`crash_tombstone`/`cancelled`) are `AlreadyDelivered`;
    missing ids are `NotFound`; empty or trailer-bearing content returns `.error`. -/
def editRemoteMessage (st : CoreStore) (userId messageId content : String) : IO (Except String QueueEditOutcome) := do
  let cleanContent ←
    match extractStoreDeferredTrailerStrict content with
    | .error e => return .error e
    | .ok (_, some _) => return .error "deferred_batch_edit_trailer"
    | .ok (plain, none) =>
      let t := plain.trimAscii.toString
      if t.isEmpty then return .error "deferred_batch_content"
      else pure plain
  withImmediateTx st.missionsDb do
    let found ← execParamQueryUnlocked st.missionsDb
      ("SELECT mission_id,payload,state,json_extract(payload,'$.job_id'),COALESCE(phase,0)," ++
       "COALESCE(claimed_generation,0),COALESCE(claim_boot_epoch,0),COALESCE(delivered_seq,0),COALESCE(edit_revision,0) " ++
       "FROM remote_message_queue WHERE user_id=?1 AND message_id=?2;")
      #[userId, messageId]
    match found with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .ok .NotFound
      let r := rows[1]!
      let missionId := (r[0]?).getD ""
      let payload := (r[1]?).getD ""
      let state := (r[2]?).getD ""
      let job := (r[3]?).getD ""
      let phaseNat := ((r[4]?.bind String.toNat?).getD 0)
      let claimedGen := ((r[5]?.bind String.toNat?).getD 0).toUInt64
      let claimBoot := ((r[6]?.bind String.toNat?).getD 0).toUInt64
      let delivSeq := ((r[7]?.bind String.toNat?).getD 0).toUInt64
      let editRev := ((r[8]?.bind String.toNat?).getD 0).toUInt32
      let source? := payloadSource? payload
      let effPhase : UInt8 :=
        if phaseNat != 0 then phaseNat.toUInt8
        else if state == "claimed" || !job.isEmpty then 1
        else if state == "delivered" then 2
        else if state == "crash_tombstone" then 3
        else if state == "cancelled" then 4
        else 0
      let pendingRows ← execParamQueryUnlocked st.missionsDb
        "SELECT COUNT(*) FROM deferred_message_batches WHERE mission_id=?1 AND unpacked=0;" #[missionId]
      let .ok prs := pendingRows | return .error "deferred_pending_select_failed"
      let pendingCnt := ((prs[1]?.bind (·[0]?)).bind String.toNat?).getD 0
      let deferredUnpacked : UInt8 :=
        if hasStoreRawTrailerMarker payload || pendingCnt > 0 then 0 else 1
      let effBoot : UInt64 := if st.bootEpoch == 0 then 1 else st.bootEpoch
      let (nextState, effs) := stepQueueSlice
        { phaseCode := effPhase, claimedGeneration := claimedGen, claimBootEpoch := claimBoot, deliveredSeq := delivSeq, editRevision := editRev }
        { opCode := 6, deferredUnpacked := deferredUnpacked, durablyStarted := 1, uncertainTimeout := 0, operatorConfirmedNotDelivered := 0,
          contentNonEmpty := 1, runGeneration := 0, nodeBootEpoch := effBoot, deliverySeq := 0 }
      if effs.isEmpty || state != "waiting" || !job.isEmpty then
        return .ok .AlreadyDelivered
      let (nextPhase, nextClaimed, nextDeliv) :=
        match effs with
        | .persistQueuePhase ph cg ds :: _ => (ph, cg, ds)
        | _ => (nextState.phaseCode, nextState.claimedGeneration, nextState.deliveredSeq)
      let nextBoot := nextState.claimBootEpoch
      let updated ← execParamQueryUnlocked st.missionsDb
        ("UPDATE remote_message_queue SET payload=json_set(payload,'$.message.content',?3)," ++
         "phase=?4,claimed_generation=?5,claim_boot_epoch=?6,delivered_seq=?7,edit_revision=?8 " ++
         "WHERE user_id=?1 AND message_id=?2 AND state='waiting' AND COALESCE(phase,0)=0 AND COALESCE(edit_revision,0)=CAST(?9 AS INTEGER) AND json_extract(payload,'$.job_id') IS NULL;")
        #[userId, messageId, cleanContent, s!"{nextPhase.toNat}", s!"{nextClaimed}", s!"{nextBoot}",
          s!"{nextDeliv}", s!"{nextState.editRevision}", s!"{editRev}"]
      match updated with
      | .error e => return .error e
      | .ok _ =>
        let changed ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
        match changed with
        | .error e => return .error e
        | .ok crs =>
          let n := ((crs[1]?.bind (·[0]?)).bind String.toNat?).getD 0
          if n == 0 then return .ok .AlreadyDelivered
          let rec ← execParamQueryUnlocked st.missionsDb
            ("INSERT INTO queue_item_receipts(message_id,mission_id,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision,content,source,updated_at) " ++
             "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,'') ON CONFLICT(message_id) DO UPDATE SET " ++
             "phase=excluded.phase,claimed_generation=excluded.claimed_generation," ++
             "claim_boot_epoch=excluded.claim_boot_epoch,delivered_seq=excluded.delivered_seq," ++
             "edit_revision=excluded.edit_revision,content=excluded.content;")
            #[messageId, missionId, s!"{nextPhase.toNat}", s!"{nextClaimed}", s!"{nextBoot}",
              s!"{nextDeliv}", s!"{nextState.editRevision}", cleanContent, source?.getD ""]
          if let .error re := rec then return .error re
          return .ok (.Edited missionId source?)

/-- Per-model metadata & router pacing limits on a custom inference provider. -/
structure CustomModelConfig where
  id              : String
  name?           : Option String := none
  contextLimit?   : Option UInt32 := none
  outputLimit?    : Option UInt32 := none
  rpmLimit?       : Option UInt32 := none
  tpmLimit?       : Option UInt64 := none
  maxConcurrency? : Option UInt32 := none
  deriving Repr, DecidableEq, Inhabited

/-- Persisted AI provider account record (`ai_providers` in `missions.db`). -/
structure AIProviderRecord where
  id              : String
  providerType    : String
  name            : String
  enabled         : Bool := true
  baseUrl         : String := ""
  apiKey          : String := ""
  rpmLimit?       : Option UInt32 := none
  maxConcurrency? : Option UInt32 := none
  customModels    : Array CustomModelConfig := #[]
  updatedAt       : String := ""
  deriving Repr, DecidableEq, Inhabited

/-- Validate account-level and per-model RPM (`1..=100000`), concurrency (`1..=1024`),
    and TPM (`1..=1000000000`) bounds. -/
def validateAIProviderRecord (p : AIProviderRecord) : Except String Unit := do
  if p.name.trimAscii.toString.isEmpty then
    throw "provider_name_required"
  if let some rpm := p.rpmLimit? then
    if rpm < 1 || rpm > 100000 then
      throw "rpm_limit_out_of_range"
  if let some conc := p.maxConcurrency? then
    if conc < 1 || conc > 1024 then
      throw "max_concurrency_out_of_range"
  for m in p.customModels do
    if m.id.trimAscii.toString.isEmpty then
      throw "custom_model_id_required"
    if let some mrpm := m.rpmLimit? then
      if mrpm < 1 || mrpm > 100000 then
        throw s!"model_rpm_limit_out_of_range:{m.id}"
    if let some mconc := m.maxConcurrency? then
      if mconc < 1 || mconc > 1024 then
        throw s!"model_max_concurrency_out_of_range:{m.id}"
    if let some mtpm := m.tpmLimit? then
      if mtpm < 1 || mtpm > 1000000000 then
        throw s!"model_tpm_limit_out_of_range:{m.id}"

/-- Parse an optional bounded `UInt32` field from a JSON object (`null` / absent -> `.ok none`,
    non-integer or out-of-range -> `.error`). -/
def parseOptionalBoundedU32 (jv : JVal) (field : String) (lo hi : Nat) : Except String (Option UInt32) :=
  match jv.field? field with
  | none | some .null => .ok none
  | some v =>
    match v.asInt? with
    | some n =>
      if n ≥ Int.ofNat lo && n ≤ Int.ofNat hi then
        .ok (some n.toNat.toUInt32)
      else
        .error s!"{field}_out_of_range"
    | none => .error s!"{field}_invalid_integer"

/-- Parse an optional bounded `UInt64` field from a JSON object (`null` / absent -> `.ok none`,
    non-integer or out-of-range -> `.error`). -/
def parseOptionalBoundedU64 (jv : JVal) (field : String) (lo hi : Nat) : Except String (Option UInt64) :=
  match jv.field? field with
  | none | some .null => .ok none
  | some v =>
    match v.asInt? with
    | some n =>
      if n ≥ Int.ofNat lo && n ≤ Int.ofNat hi then
        .ok (some n.toNat.toUInt64)
      else
        .error s!"{field}_out_of_range"
    | none => .error s!"{field}_invalid_integer"

/-- Strictly parse and validate a `custom_models` JSON array from an API request body. -/
def parseCustomModelsStrict (arr : Array JVal) : Except String (Array CustomModelConfig) := do
  let mut out : Array CustomModelConfig := Array.mkEmpty arr.size
  for it in arr do
    let mid := ((it.fieldStr? "id").getD "").trimAscii.toString
    if mid.isEmpty then
      throw "custom_model_id_required"
    let nm? := (it.fieldStr? "name").map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
    let ctx? ← parseOptionalBoundedU32 it "context_limit" 1 100000000
    let outLim? ← parseOptionalBoundedU32 it "output_limit" 1 100000000
    let rpm? ← parseOptionalBoundedU32 it "rpm_limit" 1 100000
    let tpm? ← parseOptionalBoundedU64 it "tpm_limit" 1 1000000000
    let conc? ← parseOptionalBoundedU32 it "max_concurrency" 1 1024
    out := out.push {
      id := mid
      name? := nm?
      contextLimit? := ctx?
      outputLimit? := outLim?
      rpmLimit? := rpm?
      tpmLimit? := tpm?
      maxConcurrency? := conc?
    }
  return out

/-- Best-effort hydration of stored `custom_models_json` from SQLite. -/
def parseCustomModelsStored (rawJson : String) : Array CustomModelConfig :=
  match OrbBin.Json.parse rawJson with
  | .ok (.arr arr) => (parseCustomModelsStrict arr).toOption.getD #[]
  | _ => #[]

/-- Render `CustomModelConfig` array as compact JSON. -/
def renderCustomModelsJson (models : Array CustomModelConfig) : String := Id.run do
  let mut items : Array String := Array.mkEmpty models.size
  for m in models do
    let mut kvs : Array String := #[s!"\"id\":{jsonEscape m.id}"]
    if let some nm := m.name? then
      kvs := kvs.push s!"\"name\":{jsonEscape nm}"
    if let some ctx := m.contextLimit? then
      kvs := kvs.push s!"\"context_limit\":{ctx}"
    if let some outLim := m.outputLimit? then
      kvs := kvs.push s!"\"output_limit\":{outLim}"
    if let some rpm := m.rpmLimit? then
      kvs := kvs.push s!"\"rpm_limit\":{rpm}"
    if let some tpm := m.tpmLimit? then
      kvs := kvs.push s!"\"tpm_limit\":{tpm}"
    if let some conc := m.maxConcurrency? then
      kvs := kvs.push s!"\"max_concurrency\":{conc}"
    items := items.push ("{" ++ String.intercalate "," kvs.toList ++ "}")
  return "[" ++ String.intercalate "," items.toList ++ "]"

/-- Render `AIProviderRecord` for API responses (redacting `apiKey` completely). -/
def renderAIProviderJson (p : AIProviderRecord) (observedKeyRpm? : Option UInt32 := none) : String := Id.run do
  let enStr := if p.enabled then "true" else "false"
  let hasKeyStr := if p.apiKey.isEmpty then "false" else "true"
  let statusStr := if p.enabled then "{\"type\":\"connected\"}" else "{\"type\":\"disabled\"}"
  let mut kvs : Array String := #[
    s!"\"id\":{jsonEscape p.id}",
    s!"\"provider_type\":{jsonEscape p.providerType}",
    s!"\"name\":{jsonEscape p.name}",
    s!"\"enabled\":{enStr}",
    s!"\"has_api_key\":{hasKeyStr}",
    "\"uses_oauth\":false",
    s!"\"status\":{statusStr}"
  ]
  if !p.baseUrl.isEmpty then
    kvs := kvs.push s!"\"base_url\":{jsonEscape p.baseUrl}"
  if let some rpm := p.rpmLimit? then
    kvs := kvs.push s!"\"rpm_limit\":{rpm}"
  if let some conc := p.maxConcurrency? then
    kvs := kvs.push s!"\"max_concurrency\":{conc}"
  if let some obs := observedKeyRpm? then
    kvs := kvs.push s!"\"observed_key_rpm_limit\":{obs}"
  if !p.customModels.isEmpty || p.providerType == "custom" then
    kvs := kvs.push s!"\"custom_models\":{renderCustomModelsJson p.customModels}"
  if !p.updatedAt.isEmpty then
    kvs := kvs.push s!"\"updated_at\":{jsonEscape p.updatedAt}"
  return "{" ++ String.intercalate "," kvs.toList ++ "}"

private def rowToAIProviderRecord (r : Array String) : AIProviderRecord :=
  let rpm? := ((r[6]?).bind String.toNat?).filter (fun n => n ≥ 1 && n ≤ 100000) |>.map (·.toUInt32)
  let conc? := ((r[7]?).bind String.toNat?).filter (fun n => n ≥ 1 && n ≤ 1024) |>.map (·.toUInt32)
  {
    id              := (r[0]?).getD ""
    providerType    := (r[1]?).getD "custom"
    name            := (r[2]?).getD ""
    enabled         := ((r[3]?).getD "1") != "0"
    baseUrl         := (r[4]?).getD ""
    apiKey          := (r[5]?).getD ""
    rpmLimit?       := rpm?
    maxConcurrency? := conc?
    customModels    := parseCustomModelsStored ((r[8]?).getD "[]")
    updatedAt       := (r[9]?).getD ""
  }

/-- List all persisted `AIProviderRecord` rows ordered by `updated_at ASC, id ASC`. -/
def listAIProviders (st : CoreStore) : IO (Array AIProviderRecord) := do
  match ← execParamQuery st.missionsDb
    "SELECT id,provider_type,name,enabled,base_url,api_key,COALESCE(CAST(rpm_limit AS TEXT),''),COALESCE(CAST(max_concurrency AS TEXT),''),custom_models_json,updated_at FROM ai_providers ORDER BY id ASC;" #[] with
  | .error _ => return #[]
  | .ok rows =>
    if rows.size ≤ 1 then return #[]
    let mut out : Array AIProviderRecord := Array.mkEmpty (rows.size - 1)
    for i in [1:rows.size] do
      out := out.push (rowToAIProviderRecord rows[i]!)
    return out

/-- Look up a single `AIProviderRecord` by `id`. -/
def getAIProvider? (st : CoreStore) (pid : String) : IO (Option AIProviderRecord) := do
  if pid.isEmpty then return none
  match ← execParamQuery st.missionsDb
    "SELECT id,provider_type,name,enabled,base_url,api_key,COALESCE(CAST(rpm_limit AS TEXT),''),COALESCE(CAST(max_concurrency AS TEXT),''),custom_models_json,updated_at FROM ai_providers WHERE id=?1;" #[pid] with
  | .error _ => return none
  | .ok rows =>
    if rows.size ≤ 1 then return none
    return some (rowToAIProviderRecord rows[1]!)

/-- Validate and upsert an `AIProviderRecord` into `missions.db`. -/
def upsertAIProvider (st : CoreStore) (p : AIProviderRecord) : IO (Except String Unit) := do
  match validateAIProviderRecord p with
  | .error e => return .error e
  | .ok () =>
    let rpmParam := match p.rpmLimit? with | some v => s!"{v}" | none => ""
    let concParam := match p.maxConcurrency? with | some v => s!"{v}" | none => ""
    let res ← execParamQuery st.missionsDb
      "INSERT INTO ai_providers(id,provider_type,name,enabled,base_url,api_key,rpm_limit,max_concurrency,custom_models_json,updated_at) VALUES(?1,?2,?3,?4,?5,?6,NULLIF(?7,''),NULLIF(?8,''),?9,?10) ON CONFLICT(id) DO UPDATE SET provider_type=excluded.provider_type,name=excluded.name,enabled=excluded.enabled,base_url=excluded.base_url,api_key=excluded.api_key,rpm_limit=excluded.rpm_limit,max_concurrency=excluded.max_concurrency,custom_models_json=excluded.custom_models_json,updated_at=excluded.updated_at;"
      #[p.id, p.providerType, p.name, if p.enabled then "1" else "0", p.baseUrl, p.apiKey,
        rpmParam, concParam, renderCustomModelsJson p.customModels, p.updatedAt]
    return res.map (fun _ => ())

/-- Delete an `AIProviderRecord` by `id`. -/
def deleteAIProvider (st : CoreStore) (pid : String) : IO (Except String Unit) := do
  let res ← execParamQuery st.missionsDb "DELETE FROM ai_providers WHERE id=?1;" #[pid]
  return res.map (fun _ => ())

/-- Non-zero FNV-1a 64-bit hash for non-empty job IDs (`0` iff empty string), used by
    `OrbCore.Spec.verifyRemoteReplaySupersession` (`0 import Lean`). -/
def nonZeroJobIdHash (s : String) : UInt64 :=
  let trimmed := s.trimAscii.toString
  if trimmed.isEmpty then 0
  else Id.run do
    let mut h : UInt64 := 14695981039346656037
    for b in trimmed.toUTF8 do
      h := (h ^^^ b.toUInt64) * 1099511628211
    return if h == 0 then 1 else h

/-- Encode mission status string into `Orb.Kernel.activationRollbackAdmit` domain (`0..10`, `255` unknown). -/
def encodeRollbackStatus (status : String) : UInt8 :=
  match status with
  | "pending" => 0
  | "active" => 1
  | "awaiting_user" => 2
  | "acknowledged" => 3
  | "waiting_background" => 4
  | "completed" => 5
  | "failed" => 6
  | "interrupted" => 7
  | "blocked" => 8
  | "not_feasible" => 9
  | "paused" => 10
  | "waiting_rate_limit" => 7
  | _ => 255

/-- Atomically restore pre-activation `(snapshotStatus, snapshotReason)` after a rejected local or
    remote dispatch attempt, gated by `Orb.Kernel.activationRollbackAdmit`:
    - Admits `pending (0)` (remote pre-dispatch activation), `active (1)` (host pre-dispatch activation),
      and idempotent `currentStatus == snapshotStatus` when zero non-terminal `mission_runs` exist.
    - Strictly fences `acknowledged (3)` (`StickyFence`), live non-terminal runs (`hasActiveRun = 1`),
      and third-party concurrent transitions (`completed`, `failed`, etc.). -/
def restoreMissionStatus
    (st : CoreStore) (missionId snapshotStatus snapshotReason updatedAt : String) : IO (Except String Bool) :=
  withImmediateTx st.missionsDb do
    let q ← execParamQueryUnlocked st.missionsDb
      "SELECT m.status, (SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal') FROM missions m WHERE m.id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then
        return .error s!"mission_not_found:{missionId}"
      let curStatus := (rows[1]?.bind (·[0]?)).getD ""
      let liveRuns := ((rows[1]?.bind (·[1]?)).bind String.toNat?).getD 0
      let exactStatusGuard :=
        curStatus == "pending" || curStatus == "active" || curStatus == snapshotStatus
      let curCode := encodeRollbackStatus curStatus
      let snapCode := encodeRollbackStatus snapshotStatus
      let hasActiveRun : UInt8 := if liveRuns > 0 then 1 else 0
      if !exactStatusGuard || Orb.Kernel.activationRollbackAdmit curCode snapCode hasActiveRun != 1 then
        return .ok false
      let upd ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET status=?2,terminal_reason=?3,state_revision=state_revision+1,updated_at=?4 WHERE id=?1;"
        #[missionId, snapshotStatus, snapshotReason, updatedAt]
      match upd with
      | .error ue => return .error ue
      | .ok _ => return .ok true

/-- Arm a `RemoteWait` recovery record (`mission_remote_waits`) when a remote node pauses on
    `usage_limit_wait` or `node_maintenance_wait`, persisting the failed remote job ID and optional
    scheduled-wakeup origin job ID. -/
def armRemoteMissionWait
    (st : CoreStore)
    (missionId nodeId failedJobId scheduledOriginJobId : String)
    (maxRetries : UInt32 := 10)
    (deadlineEpoch : UInt64 := 0)
    (terminalReason : String := "usage_limit_wait")
    (updatedAt : String := "") : IO (Except String Unit) :=
  withImmediateTx st.missionsDb do
    if nodeId.trimAscii.isEmpty || failedJobId.trimAscii.isEmpty then
      return .error "remote_wait_invalid_ids"
    let q ← execParamQueryUnlocked st.missionsDb
      "SELECT id,status,superseded_by_mission_id,COALESCE(owner_epoch,1),COALESCE(state_revision,1),COALESCE(not_before,0) FROM missions WHERE id=?1;" #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then
        return .error s!"mission_not_found:{missionId}"
      let curStatus := (rows[1]?.bind (·[1]?)).getD ""
      let superseded : UInt8 := if ((rows[1]?.bind (·[2]?)).getD "").isEmpty then 0 else 1
      let ownerEpoch := ((rows[1]?.bind (·[3]?)).bind String.toNat?).getD 1 |>.toUInt64
      let stateRev := ((rows[1]?.bind (·[4]?)).bind String.toNat?).getD 1 |>.toUInt32
      let curNotBefore := ((rows[1]?.bind (·[5]?)).bind String.toNat?).getD 0 |>.toUInt64
      let parkPhase : UInt8 :=
        if curStatus == "active" || curStatus == "pending" || curStatus == "interrupted" ||
           curStatus == "awaiting_user" || curStatus == "paused" ||
           curStatus == "waiting_background" || curStatus == "waiting_rate_limit" then 1
        else 6
      let effNotBefore : UInt64 := if deadlineEpoch == 0 then 1 else deadlineEpoch
      let (nextState, effs) := stepMissionSlice
        { phaseCode := parkPhase, superseded := superseded, resumeIntent := 0, ownerEpoch := ownerEpoch, notBeforeEpoch := curNotBefore, stateRevision := stateRev }
        { opCode := 3, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := 1, callerEpoch := ownerEpoch, nowEpoch := 0, reqNotBefore := effNotBefore, markSuperseded := 0 }
      if effs.isEmpty then
        return .error s!"remote_wait_rejected:{curStatus}"
      let parkedStatus := if terminalReason == "usage_limit_wait" then "waiting_rate_limit" else "interrupted"
      let parkedIntent := if parkedStatus == "waiting_rate_limit" then "1" else "0"
      let storedNotBefore := if deadlineEpoch == 0 then curNotBefore else nextState.notBeforeEpoch
      let updM ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET status=?2,terminal_reason=?3,placement_job_id=?4,scheduled_remote_job_id=?5,not_before=?6,resume_intent=?7,state_revision=?8,updated_at=?9 WHERE id=?1 AND status=?10 AND COALESCE(state_revision,1)=CAST(?11 AS INTEGER);"
        #[missionId, parkedStatus, terminalReason, failedJobId, scheduledOriginJobId, s!"{storedNotBefore}", parkedIntent, s!"{nextState.stateRevision}", updatedAt, curStatus, s!"{stateRev}"]
      if let .error ue := updM then return .error ue
      let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok crs := ch | return .error "remote_wait_changes_failed"
      if ((crs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 == 0 then
        return .error "remote_wait_cas_lost"
      let insW ← execParamQueryUnlocked st.missionsDb
        ("INSERT INTO mission_remote_waits(mission_id,node_id,failed_job_id,scheduled_origin_job_id,retries,max_retries,replays,deadline_epoch,updated_at) " ++
         "VALUES(?1,?2,?3,?4,0,?5,0,?6,?7) " ++
         "ON CONFLICT(mission_id) DO UPDATE SET node_id=excluded.node_id,failed_job_id=excluded.failed_job_id,scheduled_origin_job_id=excluded.scheduled_origin_job_id,retries=0,max_retries=excluded.max_retries,deadline_epoch=excluded.deadline_epoch,updated_at=excluded.updated_at;")
        #[missionId, nodeId, failedJobId, scheduledOriginJobId, s!"{maxRetries}", s!"{deadlineEpoch}", updatedAt]
      return insW.map (fun _ => ())

/-- Structured receipt returned by `stepRemoteMissionReplay`. -/
structure RemoteReplayReceipt where
  action               : UInt32
  verdict              : UInt32
  missionStatus        : String
  terminalReason       : String
  placementJobId       : String
  scheduledRemoteJobId : String
  failedJobId          : String
  retries              : UInt32
  replays              : UInt32
  waitActive           : Bool
  deriving Repr, DecidableEq

/-- Execute a single transactional remote wait replay step (`Orb.Kernel.remoteReplayStep` +
    `Orb.Kernel.activationRollbackAdmit` + `OrbCore.Spec.verifyRemoteReplaySupersession`):
    - Pre-flight heals a mission left in `pending` (`usage_limit_wait` / `node_maintenance_wait` /
      `remote_dispatch_failed`) with zero active runs back to `interrupted`.
    - Verifies `RemoteWait` lineage via `verifyRemoteReplaySupersession`: rejects (`superseded`)
      and clears the wait if a manual resume or live run replaced `placement_job_id`, while
      admitting consecutive pre-dispatch `remote_dispatch_failed` attempts.
    - Enforces scheduled-origin binding (`scheduled_recovery_missing_remote_job` when scheduled
      replay lacks `scheduled_remote_job_id`).
    - On transient pre-dispatch error (`dispatchOutcome = 1`, e.g. HTTP 500 `ENOSPC`), atomically
      rolls `pending -> interrupted` (`bit 9 = 512`), restores `scheduled_remote_job_id` to
      `previousOriginJob` when `hasRecoveryHandle = 0` (`bit 10 = 1024`), records the terminal
      `remote_dispatch_failed` run, and advances `mission_remote_waits.failed_job_id = candidateJobId`
      so retry #2 never hits false `409` supersession or `400` missing-job errors! -/
def stepRemoteMissionReplay
    (st : CoreStore)
    (missionId nodeId candidateJobId : String)
    (isScheduledOrigin : Bool)
    (dispatchOutcome : UInt8)
    (hasRecoveryHandle : UInt8 := 0)
    (retryFitsDeadline : UInt8 := 1)
    (nowEpoch : UInt64 := 0)
    (updatedAt : String := "") : IO (Except String RemoteReplayReceipt) :=
  withImmediateTx st.missionsDb do
    if candidateJobId.trimAscii.isEmpty then
      return .error "remote_replay_missing_candidate_job"
    if dispatchOutcome > 2 || hasRecoveryHandle > 1 || retryFitsDeadline > 1 then
      return .error "remote_replay_invalid_flags"
    let mq ← execParamQueryUnlocked st.missionsDb
      ("SELECT m.status, COALESCE(m.terminal_reason,''), COALESCE(m.placement_job_id,''), COALESCE(m.scheduled_remote_job_id,''), COALESCE(m.run_generation,1), " ++
       "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal'), " ++
       "COALESCE((SELECT r2.execution_state FROM mission_runs r2 WHERE r2.mission_id=m.id ORDER BY r2.generation DESC, r2.rowid DESC LIMIT 1),''), " ++
       "COALESCE((SELECT r2.terminal_reason FROM mission_runs r2 WHERE r2.mission_id=m.id ORDER BY r2.generation DESC, r2.rowid DESC LIMIT 1),''), " ++
       "COALESCE((SELECT r2.remote_job_id FROM mission_runs r2 WHERE r2.mission_id=m.id ORDER BY r2.generation DESC, r2.rowid DESC LIMIT 1),''), " ++
       "COALESCE(m.superseded_by_mission_id,''), COALESCE(m.owner_epoch,1), COALESCE(m.state_revision,0), " ++
       "COALESCE(m.not_before,0), COALESCE(m.resume_intent,0) " ++
       "FROM missions m WHERE m.id=?1;")
      #[missionId]
    let .ok mrows := mq | return .error (match mq with | .error e => e | .ok _ => "err")
    if mrows.size ≤ 1 then
      return .error s!"mission_not_found:{missionId}"
    let mr := mrows[1]!
    let rawStatus := (mr[0]?).getD ""
    let rawReason := (mr[1]?).getD ""
    let curPlacementJob := (mr[2]?).getD ""
    let curScheduledJob := (mr[3]?).getD ""
    let curRunGen := ((mr[4]?.bind String.toNat?).getD 1).toUInt64
    let liveRunCnt := ((mr[5]?.bind String.toNat?).getD 0)
    let latestExecState := (mr[6]?).getD ""
    let latestRunReason := (mr[7]?).getD ""
    let latestRunJob := (mr[8]?).getD ""
    let supersededFlag : UInt8 := if ((mr[9]?).getD "").isEmpty then 0 else 1
    let ownerEpoch := ((mr[10]?.bind String.toNat?).getD 1).toUInt64
    let curStateRev := ((mr[11]?.bind String.toNat?).getD 0).toUInt32
    let curNotBefore := ((mr[12]?.bind String.toNat?).getD 0).toUInt64
    let curResumeIntent := ((mr[13]?.bind String.toNat?).getD 0).toUInt8

    let wq ← execParamQueryUnlocked st.missionsDb
      "SELECT node_id, failed_job_id, scheduled_origin_job_id, retries, max_retries, replays, deadline_epoch FROM mission_remote_waits WHERE mission_id=?1;"
      #[missionId]
    let .ok wrows := wq | return .error (match wq with | .error e => e | .ok _ => "err")
    if wrows.size ≤ 1 then
      return .error "remote_wait_not_armed"
    let wr := wrows[1]!
    let waitNode := (wr[0]?).getD ""
    let waitFailedJob := (wr[1]?).getD ""
    let waitOriginJob := (wr[2]?).getD ""
    let retries := ((wr[3]?.bind String.toNat?).getD 0).toUInt32
    let maxRetries := ((wr[4]?.bind String.toNat?).getD 10).toUInt32
    let replays := ((wr[5]?.bind String.toNat?).getD 0).toUInt32
    let deadlineEpoch := ((wr[6]?.bind String.toNat?).getD 0).toUInt64

    -- Pre-flight heal if a crash left this waiting mission in transitional `pending` with zero active runs
    let mut snapStatus := rawStatus
    let mut snapReason := if rawReason.isEmpty then "usage_limit_wait" else rawReason
    if snapStatus == "pending" && liveRunCnt == 0 &&
       (rawReason == "usage_limit_wait" || rawReason == "node_maintenance_wait" ||
        rawReason == "remote_dispatch_failed" || latestRunReason == "remote_dispatch_failed") then
      if Orb.Kernel.activationRollbackAdmit 0 7 0 == 1 then
        snapStatus := if snapReason == "usage_limit_wait" then "waiting_rate_limit" else "interrupted"
        if snapReason == "remote_dispatch_failed" then
          snapReason := "usage_limit_wait"
          snapStatus := "waiting_rate_limit"

    if liveRunCnt > 0 || (snapStatus != "interrupted" && snapStatus != "waiting_rate_limit") then
      let clearWord := Orb.Kernel.remoteReplayStep 0 0 1 0 0 0 1 retries maxRetries
      if (clearWord &&& 0xFF) == 1 then
        discard <| execParamQueryUnlocked st.missionsDb "DELETE FROM mission_remote_waits WHERE mission_id=?1;" #[missionId]
      return .error "scheduled_recovery_superseded"

    let nodeMatches : UInt8 := if waitNode == nodeId then 1 else 0
    let latestTerm : UInt8 := if latestExecState == "terminal" then 1 else 0
    let latestDispFailed : UInt8 := if latestRunReason == "remote_dispatch_failed" then 1 else 0
    let supOk :=
      OrbCore.Spec.verifyRemoteReplaySupersession
        1 nodeMatches latestTerm latestDispFailed
        (nonZeroJobIdHash curPlacementJob)
        (nonZeroJobIdHash waitFailedJob)
        (nonZeroJobIdHash latestRunJob)
    let exactStringLineage :=
      waitNode == nodeId && !curPlacementJob.isEmpty && !waitFailedJob.isEmpty &&
      (curPlacementJob == waitFailedJob ||
       (latestExecState == "terminal" && latestRunReason == "remote_dispatch_failed" &&
        !latestRunJob.isEmpty && latestRunJob == curPlacementJob))
    if supOk != 1 || !exactStringLineage then
      if waitNode == nodeId then
        let clearWord := Orb.Kernel.remoteReplayStep 0 0 1 0 0 0 1 retries maxRetries
        if (clearWord &&& 0xFF) == 1 then
          discard <| execParamQueryUnlocked st.missionsDb "DELETE FROM mission_remote_waits WHERE mission_id=?1;" #[missionId]
      return .error "scheduled_recovery_superseded"

    let previousOriginJob :=
      if !curScheduledJob.isEmpty then curScheduledJob else waitOriginJob
    if isScheduledOrigin && previousOriginJob.trimAscii.isEmpty then
      return .error "scheduled_recovery_missing_remote_job"

    if curRunGen == 0xFFFFFFFFFFFFFFFF then
      return .error "run_generation_overflow"
    let nextGen := curRunGen + 1
    let tentativeSchedJob := if isScheduledOrigin then candidateJobId else curScheduledJob
    let snapPhase : UInt8 := if snapStatus == "waiting_rate_limit" then 3 else 4
    let effResumeInt : UInt8 := if snapPhase == 3 then (if curResumeIntent == 0 then 1 else curResumeIntent) else curResumeIntent
    let effNowForResume : UInt64 := if nowEpoch < curNotBefore then curNotBefore else nowEpoch
    let dispatchOp : UInt8 := if snapPhase == 3 then 4 else 0

    -- Transitional pre-dispatch activation (`interrupted | waiting_rate_limit -> pending`) gated by `Orb.Lifecycle` + CAS;
    -- `run_generation` is NOT advanced before `dispatchOutcome` / `remoteReplayStep` outcome is known!
    let (preSlice, preEffs) := stepMissionSlice
      { phaseCode := snapPhase, superseded := supersededFlag, resumeIntent := effResumeInt,
        ownerEpoch := ownerEpoch, notBeforeEpoch := curNotBefore, stateRevision := curStateRev }
      { opCode := dispatchOp, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := effResumeInt,
        callerEpoch := ownerEpoch, nowEpoch := effNowForResume, reqNotBefore := curNotBefore, markSuperseded := 0 }
    if preEffs.isEmpty then
      return .error s!"remote_replay_lifecycle_rejected:{rawStatus}"
    let preRev := preSlice.stateRevision
    let preAct ← execParamQueryUnlocked st.missionsDb
      "UPDATE missions SET status='pending',placement_job_id=?2,scheduled_remote_job_id=?3,state_revision=?4,updated_at=?5 WHERE id=?1 AND status=?6 AND COALESCE(state_revision,0)=CAST(?7 AS INTEGER);"
      #[missionId, candidateJobId, tentativeSchedJob, s!"{preRev}", updatedAt, rawStatus, s!"{curStateRev}"]
    if let .error pe := preAct then return .error pe
    let preChg ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok preCrs := preChg | return .error "remote_replay_changes_failed"
    if ((preCrs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 != 1 then
      return .error "remote_replay_cas_lost"

    let pastDeadline : UInt8 :=
      if deadlineEpoch > 0 && nowEpoch > deadlineEpoch then 1 else 0
    let verdict :=
      Orb.Kernel.remoteReplayStep 0 1 1 pastDeadline dispatchOutcome hasRecoveryHandle retryFitsDeadline retries maxRetries
    let action := verdict &&& 0xFF
    let mustRollbackStatus := (verdict &&& 512) != 0
    let mustRestoreOrigin := (verdict &&& 1024) != 0

    if action == 3 then
      -- `mark_replayed`: remote job started! Gate run claim via `Orb.Lifecycle.verifyRunLifecycleAdmit` and advance `run_generation` now.
      let runPhase : UInt8 := if curRunGen == 0 then 0 else 4
      let runAdmit := verifyRunLifecycleAdmit runPhase 0 supersededFlag 0 0 0 0 curRunGen nextGen ownerEpoch ownerEpoch
      if runAdmit != 1 then
        return .error "remote_replay_run_lifecycle_rejected"
      if preRev == 0xFFFFFFFF then
        return .error "remote_replay_revision_overflow"
      let finalRev := preRev + 1
      let newReplays := replays + 1
      let insRun ← execParamQueryUnlocked st.missionsDb
        "INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) VALUES(?1,?2,?3,'running','',?4,?5);"
        #[s!"remote-job:{candidateJobId}", missionId, s!"{nextGen}", candidateJobId, updatedAt]
      if let .error re := insRun then return .error re
      let updOk ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET status='active',terminal_reason='',not_before=0,resume_intent=0,run_generation=?2,state_revision=?3,updated_at=?4 WHERE id=?1 AND status='pending' AND COALESCE(state_revision,0)=CAST(?5 AS INTEGER);"
        #[missionId, s!"{nextGen}", s!"{finalRev}", updatedAt, s!"{preRev}"]
      if let .error ue := updOk then return .error ue
      let okChg ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok okCrs := okChg | return .error "remote_replay_changes_failed"
      if ((okCrs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 != 1 then
        return .error "remote_replay_cas_lost"
      let delW ← execParamQueryUnlocked st.missionsDb
        "DELETE FROM mission_remote_waits WHERE mission_id=?1;" #[missionId]
      if let .error de := delW then return .error de
      return .ok {
        action := action
        verdict := verdict
        missionStatus := "active"
        terminalReason := ""
        placementJobId := candidateJobId
        scheduledRemoteJobId := tentativeSchedJob
        failedJobId := candidateJobId
        retries := 0
        replays := newReplays
        waitActive := false
      }
    else if action == 4 then
      -- `retry_wait`: roll back transitional `pending -> interrupted | waiting_rate_limit` via `Orb.Lifecycle` + `activationRollbackAdmit`,
      -- keeping `missions.run_generation` unadvanced because no live run was spawned!
      let admitRb := Orb.Kernel.activationRollbackAdmit 0 (encodeRollbackStatus snapStatus) 0
      if !mustRollbackStatus || admitRb != 1 then
        return .error "remote_replay_rollback_invariant_failed"
      let rbOp : UInt8 := if snapStatus == "waiting_rate_limit" then 3 else 5
      let rbNotBefore : UInt64 := if rbOp == 3 then (if curNotBefore > nowEpoch then curNotBefore else nowEpoch + 1) else curNotBefore
      let (rbSlice, rbEffs) := stepMissionSlice
        { phaseCode := 1, superseded := supersededFlag, resumeIntent := 0,
          ownerEpoch := ownerEpoch, notBeforeEpoch := curNotBefore, stateRevision := preRev }
        { opCode := rbOp, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := 1,
          callerEpoch := ownerEpoch, nowEpoch := nowEpoch, reqNotBefore := rbNotBefore, markSuperseded := 0 }
      if rbEffs.isEmpty then
        return .error "remote_replay_rollback_lifecycle_rejected"
      let insAborted ← execParamQueryUnlocked st.missionsDb
        "INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) VALUES(?1,?2,?3,'terminal','remote_dispatch_failed',?4,?5);"
        #[s!"remote-job:{candidateJobId}", missionId, s!"{curRunGen}", candidateJobId, updatedAt]
      if let .error re := insAborted then return .error re
      let restoredSchedJob :=
        if isScheduledOrigin && mustRestoreOrigin then previousOriginJob else tentativeSchedJob
      let updRb ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET status=?2,terminal_reason=?3,scheduled_remote_job_id=?4,resume_intent=CASE WHEN ?2='waiting_rate_limit' THEN 1 ELSE resume_intent END,state_revision=?5,updated_at=?6 WHERE id=?1 AND status='pending' AND COALESCE(state_revision,0)=CAST(?7 AS INTEGER);"
        #[missionId, snapStatus, snapReason, restoredSchedJob, s!"{rbSlice.stateRevision}", updatedAt, s!"{preRev}"]
      if let .error ue := updRb then return .error ue
      let rbChg ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok rbCrs := rbChg | return .error "remote_replay_changes_failed"
      if ((rbCrs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 != 1 then
        return .error "remote_replay_cas_lost"
      let newRetries := retries + 1
      let updW ← execParamQueryUnlocked st.missionsDb
        "UPDATE mission_remote_waits SET failed_job_id=?2,scheduled_origin_job_id=?3,retries=?4,updated_at=?5 WHERE mission_id=?1;"
        #[missionId, candidateJobId, restoredSchedJob, s!"{newRetries}", updatedAt]
      if let .error we := updW then return .error we
      return .ok {
        action := action
        verdict := verdict
        missionStatus := snapStatus
        terminalReason := snapReason
        placementJobId := candidateJobId
        scheduledRemoteJobId := restoredSchedJob
        failedJobId := candidateJobId
        retries := newRetries
        replays := replays
        waitActive := true
      }
    else
      -- `fail_deadline (2)` or `give_up_fail (5)`: terminal failure gated by `Orb.Lifecycle` (`opCode = 7`), clear wait, record evidence
      let (failSlice, failEffs) := stepMissionSlice
        { phaseCode := 1, superseded := supersededFlag, resumeIntent := 0,
          ownerEpoch := ownerEpoch, notBeforeEpoch := curNotBefore, stateRevision := preRev }
        { opCode := 7, hasEvidence := 1, hasTermReceipt := 0, reqResumeInt := 0,
          callerEpoch := ownerEpoch, nowEpoch := nowEpoch, reqNotBefore := 0, markSuperseded := 0 }
      if failEffs.isEmpty then
        return .error "remote_replay_fail_lifecycle_rejected"
      let termReason := if action == 2 then "remote_wait_deadline_exceeded" else "remote_replay_exhausted"
      let insAborted ← execParamQueryUnlocked st.missionsDb
        "INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) VALUES(?1,?2,?3,'terminal','remote_dispatch_failed',?4,?5);"
        #[s!"remote-job:{candidateJobId}", missionId, s!"{curRunGen}", candidateJobId, updatedAt]
      if let .error re := insAborted then return .error re
      let restoredSchedJob :=
        if isScheduledOrigin && mustRestoreOrigin then previousOriginJob else tentativeSchedJob
      let updFail ← execParamQueryUnlocked st.missionsDb
        "UPDATE missions SET status='failed',terminal_reason=?2,scheduled_remote_job_id=?3,not_before=0,resume_intent=0,state_revision=?4,updated_at=?5 WHERE id=?1 AND status='pending' AND COALESCE(state_revision,0)=CAST(?6 AS INTEGER);"
        #[missionId, termReason, restoredSchedJob, s!"{failSlice.stateRevision}", updatedAt, s!"{preRev}"]
      if let .error ue := updFail then return .error ue
      let failChg ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok failCrs := failChg | return .error "remote_replay_changes_failed"
      if ((failCrs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 != 1 then
        return .error "remote_replay_cas_lost"
      let insEv ← execParamQueryUnlocked st.missionsDb
        ("INSERT INTO mission_terminal_evidence(mission_id,terminal_reason,summary,artifact_ref,verified,recorded_at) " ++
         "VALUES(?1,?2,'Remote wait recovery exhausted or expired','',1,?3) " ++
         "ON CONFLICT(mission_id) DO UPDATE SET terminal_reason=excluded.terminal_reason,summary=excluded.summary,recorded_at=excluded.recorded_at;")
        #[missionId, termReason, updatedAt]
      if let .error ee := insEv then return .error ee
      let delW ← execParamQueryUnlocked st.missionsDb
        "DELETE FROM mission_remote_waits WHERE mission_id=?1;" #[missionId]
      if let .error de := delW then return .error de
      return .ok {
        action := action
        verdict := verdict
        missionStatus := "failed"
        terminalReason := termReason
        placementJobId := candidateJobId
        scheduledRemoteJobId := restoredSchedJob
        failedJobId := candidateJobId
        retries := retries
        replays := replays
        waitActive := false
      }

end OrbCore.Store
