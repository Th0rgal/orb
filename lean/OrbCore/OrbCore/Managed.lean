/-
  OrbCore.Managed: Pure-Lean Managed Compute Fleet (`boat.dev`), Service-Scoped Sandbox Prefix,
  Reverse Long-Poll Relay, Budget Ledger & `sandboxed-sh deploy --service` Confinement (`0 import Lean`, `0 sorryAx`).
-/
import Orb.Kernel
import Orb.ManagedNode
import OrbBin.Json
import OrbBin.PosixExt
import OrbNetLeaf.Crypto
import OrbCore.Spec
import OrbCore.Store
import OrbCore.ManagedProviderRegistry

namespace OrbCore.Managed

open Orb.Kernel
open Orb.ManagedNode
open OrbBin.Json
open OrbBin.PosixExt
open OrbNetLeaf.Crypto
open OrbCore.Spec
open OrbCore.Store

/-- Service-scoped VM name prefix (`"orb-managed-"` on production or unsuffixed binaries,
    `"orb-managed-<suffix>-"` on `orb-core-<suffix>` / `sandboxed-sh-<suffix>` so non-prod instances never reap prod VMs). -/
def sandboxNamePrefixFor (exeName : String) : String :=
  let base := ((exeName.splitOn "/").getLast?).getD exeName
  if base.startsWith "orb-core-" then
    let suffix := (base.drop 9).toString
    if suffix.isEmpty || suffix == "prod" then "orb-managed-"
    else s!"orb-managed-{suffix}-"
  else if base.startsWith "sandboxed-sh-" then
    let suffix := (base.drop 13).toString
    if suffix.isEmpty || suffix == "prod" then "orb-managed-"
    else s!"orb-managed-{suffix}-"
  else
    "orb-managed-"

/-- Explicit instance identity also covers an unsuffixed dev binary. A dev
    executable cannot opt out of its safety ceiling by claiming to be prod. -/
def managedInstanceFor (configured exeName : String) : String :=
  if configured == "dev" || sandboxNamePrefixFor exeName == "orb-managed-dev-" then "dev" else "prod"

def currentManagedInstance : IO String := do
  return managedInstanceFor ((← IO.getEnv "ORB_INSTANCE").getD "") (← IO.appPath).toString

def managedSandboxNamePrefix : IO String := do
  if (← currentManagedInstance) == "dev" then return "orb-managed-dev-"
  return sandboxNamePrefixFor (← IO.appPath).toString

/-- Five dollars of daily rental commitments by default. Invalid configuration
    disables new dev spending instead of silently dropping the ceiling. -/
def devDailyCapCeiling (raw : Option String) : UInt64 :=
  match raw with
  | none => 500
  | some value =>
    match value.toNat? with
    | some n => if n ≤ 0x7FFFFFFFFFFFFFFF then n.toUInt64 else 0
    | none => 0

def newManagedSandboxName (requested : String := "") : IO String := do
  let namePrefix ← managedSandboxNamePrefix
  let suffix ← if requested.trimAscii.toString.isEmpty then do
    let id ← newUuidV4
    pure (id.take 12).toString
    else pure requested.trimAscii.toString
  return if suffix.startsWith namePrefix then suffix else namePrefix ++ suffix

/-- Managed machine record persisted in Core's fleet state. -/
structure ManagedMachine where
  id           : String
  sandboxName  : String
  provider     : String := "boat"
  size         : String := "small"
  status       : String := "ready"
  ownerMission : String := ""
  ttlMinutes   : UInt64 := 60
  spentCents   : UInt64 := 0
  cordoned     : Bool   := false
  nodeBootEpoch : UInt64 := 1
  deletableAtSec : UInt64 := 0
  ownerKind : String := ""
  requestedByMissionId : String := ""
  ownerUserId : String := ""
  providerId : String := ""
  createdAtSec : UInt64 := 0
  expiresAtSec : UInt64 := 0
  lastPollSec : UInt64 := 0
  requestKey : String := ""
  image : String := ""
  expiryProviderState : String := ""
  expiryCleanupState : String := ""
  deriving Repr, DecidableEq

/-- Legacy rows used the provider ID as Core's ID. New boots keep these identities separate. -/
def ManagedMachine.effectiveProviderId (m : ManagedMachine) : String :=
  if m.providerId.isEmpty then m.id else m.providerId

/-- Managed fleet budget & concurrency state. -/
structure ManagedFleetState where
  instanceName    : String := "prod"
  instanceDailyCapCents? : Option UInt64 := none
  enabled         : Bool   := false
  boatEnabled     : Bool   := false
  dailyCapCents   : UInt64 := 2000
  spentTodayCents : UInt64 := 0
  maxConcurrent   : UInt64 := 100
  machines        : Array ManagedMachine := #[]
  deriving Repr, DecidableEq

/-- Trusted caller spend snapshot. Pending VM reservations are added under the
    managed store transaction, so concurrent requests cannot bypass a user cap. -/
structure ManagedUserAdmission where
  capCents : UInt64
  inferenceCents : UInt64
  computeCents : UInt64

/-- Overflow-safe managed VM spawn admission through `Orb.Kernel.vmStep` (`orb_vm_step`). -/
def admitManagedSpawnCount (st : ManagedFleetState) (activeNat : Nat)
    (reqCents : UInt64) (ttlMins : UInt32 := 60) : Bool :=
  if !st.enabled then false
  else if reqCents > st.dailyCapCents || st.spentTodayCents > st.dailyCapCents - reqCents then
    false
  else
    let active : UInt32 := (Nat.min activeNat 0xFFFFFFFF).toUInt32
    let cap : UInt32 := (Nat.min st.maxConcurrent.toNat 0xFFFFFFFF).toUInt32
    let totalSpent : UInt64 := st.spentTodayCents + reqCents
    vmStep 0 1 3 0 0 0 0 0 active cap ttlMins 720 20 totalSpent st.dailyCapCents == 1

def admitManagedSpawn (st : ManagedFleetState) (reqCents : UInt64) (ttlMins : UInt32 := 60) : Bool :=
  admitManagedSpawnCount st
    (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size reqCents ttlMins

private def clampSpendU32 (v : UInt64) : UInt32 :=
  if v > 0xFFFFFFFF then 0xFFFFFFFF else v.toUInt32

/-- Dual global + per-user spend-cap and concurrency VM spawn admission via
    `Orb.Kernel.userSpendCapStep` + `admitManagedSpawn`.
    Returns `0` when admitted, `1` when global cap or concurrency rejects, `2` when user cap rejects. -/
def admitManagedSpawnMultiUser
    (st : ManagedFleetState)
    (reqCents : UInt64)
    (userSpentTodayCents : UInt64)
    (userDailyCapCents? : Option UInt64)
    (ttlMins : UInt32 := 60) : UInt8 :=
  let globalActive : UInt8 := 1
  let userActive : UInt8 := if userDailyCapCents?.isSome then 1 else 0
  let userCapU32 : UInt32 := clampSpendU32 (userDailyCapCents?.getD 0)
  let capWord :=
    userSpendCapStep
      globalActive (clampSpendU32 st.spentTodayCents) (clampSpendU32 st.dailyCapCents)
      userActive (clampSpendU32 userSpentTodayCents) userCapU32
      (clampSpendU32 reqCents)
  let capAdmit := (capWord &&& 1) == 1
  let denyReason := ((capWord >>> 1) &&& 0x7).toUInt8
  if !capAdmit then
    if denyReason == 2 then 2 else 1
  else if !admitManagedSpawn st reqCents ttlMins then
    1
  else
    0

private def formatCentsUsd2 (cents : UInt64) : String :=
  let dollars := cents / 100
  let rem := cents % 100
  let pad := if rem < 10 then s!"0{rem}" else s!"{rem}"
  s!"{dollars}.{pad}"

/-- Render `/api/managed-machines/spend` & budget summary JSON.
    When `callerUserId?` is `none`, preserves the exact single-tenant wire fields. -/
private def renderManagedBudgetBaseJson
    (st : ManagedFleetState)
    (callerUserId? : Option String := none)
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none) : String :=
  match callerUserId? with
  | none =>
    let active := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let enStr := if st.enabled then "true" else "false"
    let boatStr := if st.boatEnabled then "true" else "false"
    -- The desktop, iOS and Android `ManagedBudget` contract reads the `_usd`, `active`, TTL and size
    -- keys; the single-tenant reply carries them too, next to the original cent fields.
    s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active\":{active},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{st.spentTodayCents},\"daily_cap_cents\":{st.dailyCapCents}," ++
    s!"\"spent_today_usd\":{formatCentsUsd2 st.spentTodayCents},\"daily_cap_usd\":{formatCentsUsd2 st.dailyCapCents}," ++
    s!"\"default_ttl_minutes\":60,\"max_ttl_minutes\":720,\"default_size\":\"small\",\"max_size\":\"xlarge\"}"
  | some uid =>
    let ownMachines := st.machines.filter (fun m => m.ownerUserId == uid)
    let active := (ownMachines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let enStr := if st.enabled then "true" else "false"
    let boatStr := if st.boatEnabled then "true" else "false"
    let uCapCentsJson := match userDailyCapCents? with | some c => s!"{c}" | none => "null"
    let uCapUsdJson := match userDailyCapCents? with | some c => formatCentsUsd2 c | none => "null"
    let effSpentCents := userSpentTodayCents
    let exhaustedScope :=
      match userDailyCapCents? with
      | some uc => if effSpentCents ≥ uc then "\"user\"" else if st.spentTodayCents ≥ st.dailyCapCents then "\"global\"" else "null"
      | none => if st.spentTodayCents ≥ st.dailyCapCents then "\"global\"" else "null"
    s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active\":{active},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent}," ++
    s!"\"spent_today_cents\":{effSpentCents},\"daily_cap_cents\":{st.dailyCapCents}," ++
    s!"\"spent_today_usd\":{formatCentsUsd2 effSpentCents},\"daily_cap_usd\":{formatCentsUsd2 st.dailyCapCents}," ++
    s!"\"user_spent_today_cents\":{effSpentCents},\"user_daily_cap_cents\":{uCapCentsJson}," ++
    s!"\"user_spent_today_usd\":{formatCentsUsd2 effSpentCents},\"user_daily_cap_usd\":{uCapUsdJson}," ++
    s!"\"budget_exhausted_scope\":{exhaustedScope},\"default_ttl_minutes\":60,\"max_ttl_minutes\":720,\"default_size\":\"small\",\"max_size\":\"xlarge\"}"

/-- Usage is explicitly attributed to this instance. Per-user responses retain
    their own spend fields; no other user's usage is added to that projection. -/
def renderManagedBudgetJson
    (st : ManagedFleetState)
    (callerUserId? : Option String := none)
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none) : String :=
  let body := renderManagedBudgetBaseJson st callerUserId? userSpentTodayCents userDailyCapCents?
  let ceiling := match st.instanceDailyCapCents? with | some n => toString n | none => "null"
  (body.dropEnd 1).toString ++ s!",\"instance\":{jsonEscape st.instanceName},\"instance_daily_cap_cents\":{ceiling},\"cost_basis\":\"rental_commitments\"}"

/-- Map systemd unit alias (`sandboxed-sh`, `sandboxed-sh-prod`, `sandboxed-sh-dev`,
    `orb-core`, `orb-core-dev`, `sandboxed-node`, `orb-node`, `orb-privd`) to
    allowlisted `unitCode` (`1..3`) and validate via `verifyDeployUnitName` (`OrbCore.Spec`). -/
def validateDeployServiceUnit (rawUnit : String) : Except String String :=
  let trimmed := rawUnit.trimAscii.toString
  let hasTraversal : UInt8 :=
    if trimmed.contains '/' || trimmed.contains '\\' || (trimmed.splitOn "..").length > 1 then 1 else 0
  let leaf := ((trimmed.splitOn "/").getLast?).getD trimmed
  let canonical := if leaf.endsWith ".service" then (leaf.dropEnd 8).toString else leaf
  let (unitCode, systemdUnit) : UInt8 × String :=
    if canonical == "sandboxed-sh" || canonical == "orb-core" then (1, "sandboxed-sh.service")
    else if canonical == "sandboxed-sh-prod" || canonical == "orb-core-prod" then (1, "sandboxed-sh-prod.service")
    else if canonical == "sandboxed-sh-dev" || canonical == "orb-core-dev" then (1, "sandboxed-sh-dev.service")
    else if canonical == "sandboxed-node" || canonical == "orb-node" then (2, "sandboxed-node.service")
    else if canonical == "orb-privd" then (3, "orb-privd.service")
    else (0, "")
  if verifyDeployUnitName unitCode hasTraversal trimmed.utf8ByteSize.toUInt32 != 1 then
    .error s!"forbidden or invalid deploy unit `{rawUnit}`"
  else
    .ok systemdUnit

/-- Production units require biometric deploy approval. Dev/staging aliases do not. -/
def deployUnitIsProd (systemdUnit : String) : Bool :=
  systemdUnit != "sandboxed-sh-dev.service" && systemdUnit != "orb-core-dev.service"

/-! ## R5-B (`SM-19`): one SQLite authority, sealed credentials, leased relay -/

/-- Open handle for `managed_compute.db`. Credentials never live in this database. -/
structure ManagedComputeStore where
  db : SqliteDb
  instanceName : String := "prod"
  dailyCapCeilingCents : UInt64 := 500

/-- Pure provider observation. Adapters emit these; they never write the machine table. -/
structure ProviderObservation where
  provider : String
  machineId : String
  observedStatus : String
  spentCents : UInt64 := 0
  spentObserved : Bool := false
  orphaned : Bool := false
  retainedArchived : Bool := false
  expectedProviderId? : Option String := none
  expectedBootEpoch? : Option UInt64 := none
  deriving Repr, DecidableEq

structure ManagedExtensionIntent where
  id : String
  machineId : String
  bootEpoch : UInt64
  providerId : String
  minutes : UInt64
  oldExpiry : UInt64
  newExpiry : UInt64
  newTtl : UInt64
  cost : UInt64
  state : String
  deriving Repr, DecidableEq

structure ManagedResumeIntent where
  id : String
  machineId : String
  expectedBoot : UInt64
  oldProviderId : String
  newProviderId : String
  oldTtl : UInt64
  oldExpiry : UInt64
  newTtl : UInt64
  newExpiry : UInt64
  deadlineSec : UInt64
  state : String
  deriving Repr, DecidableEq

/-- Durable VM claim. `phaseCode` is `Orb.ManagedNode.ClaimPhase.encode`. -/
structure ManagedClaim where
  machineId : String
  reservationId : UInt64
  phaseCode : UInt8
  claimBoot : UInt64
  ownerMission : String
  deriving Repr, DecidableEq

/-- Durable relay command. `phaseCode` is `Orb.ManagedNode.RelayPhase.encode`. -/
structure ManagedRelayCommand where
  commandId : String
  machineId : String
  phaseCode : UInt8
  heldLeaseId : UInt64
  leaseSeq : UInt64 := 0
  leaseEpoch : UInt64
  leaseDeadline : UInt64
  nodeBootEpoch : UInt64
  payloadJson : String
  deriving Repr, DecidableEq

def coreMonitorSettingsDdl (schemaPrefix : String := "") : String :=
  "CREATE TABLE IF NOT EXISTS " ++ schemaPrefix ++
  "core_monitor_settings(singleton_id INTEGER PRIMARY KEY CHECK(singleton_id=1),data TEXT NOT NULL DEFAULT '{}');"

def managedComputeDdl : String :=
  "PRAGMA journal_mode=WAL;" ++
  "CREATE TABLE IF NOT EXISTS managed_machines(" ++
  "id TEXT PRIMARY KEY,sandbox_name TEXT NOT NULL,provider TEXT NOT NULL,size TEXT NOT NULL," ++
  "status TEXT NOT NULL,owner_mission TEXT NOT NULL,ttl_minutes INTEGER NOT NULL," ++
  "spent_cents INTEGER NOT NULL,cordoned INTEGER NOT NULL,node_boot_epoch INTEGER NOT NULL," ++
  "deletable_at_sec INTEGER NOT NULL,owner_kind TEXT NOT NULL,requested_by_mission_id TEXT NOT NULL," ++
  "phase_code INTEGER NOT NULL,active_compute_eligible INTEGER NOT NULL," ++
  "owner_user_id TEXT NOT NULL DEFAULT '',provider_id TEXT NOT NULL DEFAULT ''," ++
  "created_at_sec INTEGER NOT NULL DEFAULT 0,expires_at_sec INTEGER NOT NULL DEFAULT 0," ++
  "last_poll_sec INTEGER NOT NULL DEFAULT 0,request_key TEXT NOT NULL DEFAULT '',image TEXT NOT NULL DEFAULT '');" ++
  "CREATE INDEX IF NOT EXISTS idx_managed_machines_owner ON managed_machines(owner_user_id);" ++
  "CREATE TABLE IF NOT EXISTS managed_provider_settings(provider TEXT PRIMARY KEY,enabled INTEGER NOT NULL DEFAULT 1,updated_at TEXT NOT NULL DEFAULT '');" ++
  coreMonitorSettingsDdl ++
  "CREATE TABLE IF NOT EXISTS user_managed_provider_prefs(" ++
  "user_id TEXT NOT NULL,provider TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1," ++
  "updated_at TEXT NOT NULL DEFAULT '',PRIMARY KEY(user_id,provider));" ++
  "CREATE TABLE IF NOT EXISTS managed_preference_migrations(name TEXT PRIMARY KEY);" ++
  "CREATE TABLE IF NOT EXISTS managed_vm_claims(" ++
  "machine_id TEXT PRIMARY KEY,reservation_id INTEGER NOT NULL,phase_code INTEGER NOT NULL," ++
  "claim_boot INTEGER NOT NULL,owner_mission TEXT NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS managed_node_tokens(" ++
  "machine_id TEXT PRIMARY KEY,node_id TEXT NOT NULL,node_token TEXT NOT NULL," ++
  "enroll_token TEXT NOT NULL,node_boot_epoch INTEGER NOT NULL,readiness_deadline_sec INTEGER NOT NULL DEFAULT 0);" ++
  "CREATE TABLE IF NOT EXISTS managed_relay_commands(" ++
  "command_id TEXT PRIMARY KEY,machine_id TEXT NOT NULL,phase_code INTEGER NOT NULL," ++
  "held_lease_id INTEGER NOT NULL,lease_seq INTEGER NOT NULL,lease_epoch INTEGER NOT NULL," ++
  "lease_deadline INTEGER NOT NULL,node_boot_epoch INTEGER NOT NULL,payload_json TEXT NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS managed_fleet_state(" ++
  "singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1)," ++
  "enabled INTEGER NOT NULL,boat_enabled INTEGER NOT NULL," ++
  "daily_cap_cents INTEGER NOT NULL,spent_today_cents INTEGER NOT NULL,max_concurrent INTEGER NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS mission_budgets(" ++
  "mission_id TEXT PRIMARY KEY,budget_deci_milli_usd INTEGER," ++
  "reset_period TEXT NOT NULL DEFAULT 'total'," ++
  "vm_limits_json TEXT NOT NULL DEFAULT ''," ++
  "bandwidth_limits_json TEXT NOT NULL DEFAULT ''," ++
  "updated_at INTEGER NOT NULL DEFAULT 0);" ++
  "CREATE TABLE IF NOT EXISTS managed_cost_reservations(" ++
  "id TEXT PRIMARY KEY,machine_id TEXT NOT NULL,owner_user_id TEXT NOT NULL,day_start INTEGER NOT NULL,cents INTEGER NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS managed_resume_intents(" ++
  "id TEXT PRIMARY KEY,machine_id TEXT NOT NULL,expected_boot INTEGER NOT NULL," ++
  "old_provider_id TEXT NOT NULL,new_provider_id TEXT NOT NULL DEFAULT ''," ++
  "old_ttl INTEGER NOT NULL,old_expiry INTEGER NOT NULL,new_ttl INTEGER NOT NULL,new_expiry INTEGER NOT NULL," ++
  "deadline_sec INTEGER NOT NULL,state TEXT NOT NULL DEFAULT 'pending');" ++
  "CREATE UNIQUE INDEX IF NOT EXISTS one_active_managed_resume ON managed_resume_intents(machine_id) WHERE state IN ('pending','aborting');" ++
  "CREATE TABLE IF NOT EXISTS managed_extension_intents(id TEXT PRIMARY KEY,machine_id TEXT NOT NULL,boot_epoch INTEGER NOT NULL,provider_id TEXT NOT NULL,minutes INTEGER NOT NULL,old_expiry INTEGER NOT NULL,new_expiry INTEGER NOT NULL,new_ttl INTEGER NOT NULL,cost INTEGER NOT NULL,state TEXT NOT NULL DEFAULT 'pending');" ++
  "CREATE UNIQUE INDEX IF NOT EXISTS one_pending_managed_extension ON managed_extension_intents(machine_id) WHERE state='pending';" ++
  "CREATE TABLE IF NOT EXISTS managed_expirations(machine_id TEXT NOT NULL,boot_epoch INTEGER NOT NULL,provider_id TEXT NOT NULL,expires_at_sec INTEGER NOT NULL,observed_state TEXT NOT NULL DEFAULT 'unknown',spend_cents INTEGER NOT NULL DEFAULT 0,spend_source TEXT NOT NULL DEFAULT 'lease_reservation_estimate',state TEXT NOT NULL DEFAULT 'pending',PRIMARY KEY(machine_id,boot_epoch));"

def managedAdditiveAlters : Array String := #[
  "ALTER TABLE managed_machines ADD COLUMN owner_user_id TEXT NOT NULL DEFAULT '';",
  "CREATE INDEX IF NOT EXISTS idx_managed_machines_owner ON managed_machines(owner_user_id);",
  "ALTER TABLE managed_node_tokens ADD COLUMN readiness_deadline_sec INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE managed_machines ADD COLUMN provider_id TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE managed_machines ADD COLUMN created_at_sec INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE managed_machines ADD COLUMN expires_at_sec INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE managed_machines ADD COLUMN last_poll_sec INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE managed_machines ADD COLUMN request_key TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE managed_machines ADD COLUMN image TEXT NOT NULL DEFAULT '';",
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_managed_provider_identity ON managed_machines(provider,provider_id) WHERE provider_id<>'';",
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_managed_request ON managed_machines(provider,request_key) WHERE request_key<>'';",
  "CREATE INDEX IF NOT EXISTS managed_cost_reservation_day ON managed_cost_reservations(owner_user_id,day_start);",
  "INSERT OR IGNORE INTO managed_cost_reservations(id,machine_id,owner_user_id,day_start,cents) SELECT 'create:'||id,id,owner_user_id,(created_at_sec/86400)*86400,spent_cents FROM managed_machines WHERE created_at_sec>0;",
  "CREATE TABLE IF NOT EXISTS mission_budgets(mission_id TEXT PRIMARY KEY,budget_deci_milli_usd INTEGER,reset_period TEXT NOT NULL DEFAULT 'total',vm_limits_json TEXT NOT NULL DEFAULT '',bandwidth_limits_json TEXT NOT NULL DEFAULT '',updated_at INTEGER NOT NULL DEFAULT 0);"
]

def knownProviders : Array String :=
  #["boat", "leanci", "hetzner", "vastai", "scaleway", "colab"]

def canonicalizeProvider (provider : String) : String :=
  let key := provider.trimAscii.toString.toLower
  if key == "lean.ci" then "leanci" else key

def isKnownProvider (provider : String) : Bool :=
  let c := canonicalizeProvider provider
  knownProviders.any (· == c)

/-- Provider used when a caller names none (`auto-managed[:size]`, `spawn_managed_machine` without
    `provider`). `SANDBOXED_MANAGED_DEFAULT_PROVIDER` selects it (for example `leanci`); unset or
    unknown values keep `boat`. An explicit provider in the request always wins. -/
def defaultManagedProviderOf (raw? : Option String) : String :=
  match (raw?.map canonicalizeProvider).filter (!·.isEmpty) with
  | some p => if isKnownProvider p then p else "boat"
  | none => "boat"

def defaultManagedProvider : IO String := do
  return defaultManagedProviderOf (← IO.getEnv "SANDBOXED_MANAGED_DEFAULT_PROVIDER")

def statusOfPhase (phaseCode : UInt8) : String :=
  if phaseCode == 0 then "provisioning"
  else if phaseCode == 1 then "ready"
  else if phaseCode == 2 then "stopped"
  else "destroyed"

def phaseOfStatus (status : String) : UInt8 :=
  if status == "ready" || status == "online" then 1
  else if status == "stopped" then 2
  else if status == "destroyed" || status == "failed" then 3
  else 0

def cell (row : Array String) (i : Nat) : String :=
  (row[i]?).getD ""

def cellU64 (row : Array String) (i : Nat) : UInt64 :=
  (cell row i).toNat?.getD 0 |>.toUInt64

def cellU8 (row : Array String) (i : Nat) : UInt8 :=
  cellU64 row i |>.toUInt8

private def machineFromRow (row : Array String) : ManagedMachine :=
  {
    id := cell row 0
    sandboxName := cell row 1
    provider := cell row 2
    size := cell row 3
    status := if cell row 22 == "1" then "provisioning" else if cell row 24 == "pending" then "destroying" else cell row 4
    ownerMission := cell row 5
    ttlMinutes := cellU64 row 6
    spentCents := cellU64 row 7
    cordoned := cell row 8 == "1"
    nodeBootEpoch := cellU64 row 9
    deletableAtSec := cellU64 row 10
    ownerKind := cell row 11
    requestedByMissionId := cell row 12
    ownerUserId := cell row 15
    providerId := cell row 16
    createdAtSec := cellU64 row 17
    expiresAtSec := cellU64 row 18
    lastPollSec := cellU64 row 19
    requestKey := cell row 20
    image := cell row 21
    expiryProviderState := cell row 23
    expiryCleanupState := cell row 24
  }

private def vmSliceOf (row : Array String) : VmSliceState :=
  {
    phaseCode := cellU8 row 13
    activeComputeEligible := cellU8 row 14
    nodeBootEpoch := cellU64 row 9
    deletableAt := cellU64 row 10
  }

def openManagedComputeStore (path : String) : IO (Except String ManagedComputeStore) := do
  match ← openSqliteDb path managedComputeDdl managedAdditiveAlters false with
  | .error e => return .error e
  | .ok db => return .ok {
      db := db, instanceName := ← currentManagedInstance,
      dailyCapCeilingCents := devDailyCapCeiling (← IO.getEnv "ORB_DEV_DAILY_CAP_CENTS") }

def closeManagedComputeStore (st : ManagedComputeStore) : IO Unit :=
  st.db.mu.atomically (sqliteCloseRaw st.db.handle)

def backfillManagedMachineOwner (st : ManagedComputeStore) (bootstrapAdminId : String) : IO (Except String Unit) := do
  if bootstrapAdminId.isEmpty then return .ok ()
  withImmediateTx st.db do
    let .ok _ ← execParamQueryUnlocked st.db
        "UPDATE managed_machines SET owner_user_id=?1 WHERE owner_user_id='';" #[bootstrapAdminId]
      | return .error "managed_owner_backfill_failed"
    match ← execParamQueryUnlocked st.db
        "UPDATE managed_cost_reservations SET owner_user_id=?1 WHERE owner_user_id='';" #[bootstrapAdminId] with
    | .error e => return .error e
    | .ok _ => return .ok ()

def migrateManagedProviderOptIns (st : ManagedComputeStore) (bootstrapAdminId nowAt : String) :
    IO (Except String Unit) := do
  if bootstrapAdminId.isEmpty then return .error "managed_preference_migration_admin_unknown"
  withImmediateTx st.db do
    let .ok rows ← execParamQueryUnlocked st.db
        "SELECT name FROM managed_preference_migrations WHERE name='provider_opt_in_v1';" #[]
      | return .error "managed_preference_migration_failed"
    if rows.size > 1 then return .ok ()
    for provider in knownProviders do
      if provider == "boat" then continue
      let .ok _ ← execParamQueryUnlocked st.db
          ("INSERT OR IGNORE INTO user_managed_provider_prefs(user_id,provider,enabled,updated_at) " ++
           "SELECT DISTINCT CASE WHEN owner_user_id='' THEN ?1 ELSE owner_user_id END,?2,1,?3 " ++
           "FROM managed_machines WHERE provider=?2 AND (owner_user_id<>'' OR ?1<>'');")
          #[bootstrapAdminId, provider, nowAt]
        | return .error "managed_preference_migration_failed"
    let .ok _ ← execParamQueryUnlocked st.db
        "INSERT INTO managed_preference_migrations(name) VALUES('provider_opt_in_v1');" #[]
      | return .error "managed_preference_migration_failed"
    return .ok ()

def getUserManagedPrefs (st : ManagedComputeStore) (userId : String) : IO (Array (String × Bool)) := do
  match ← execParamQuery st.db
      "SELECT provider,enabled FROM user_managed_provider_prefs WHERE user_id=?1;" #[userId] with
  | .error _ => return #[]
  | .ok rows =>
    let mut out : Array (String × Bool) := #[]
    for i in [1:rows.size] do
      let r := rows[i]!
      out := out.push (cell r 0, cell r 1 != "0")
    return out

def isUserManagedProviderEnabled (prefs : Array (String × Bool)) (provider : String) : Bool :=
  let c := canonicalizeProvider provider
  match prefs.find? (fun (p, _) => canonicalizeProvider p == c) with
  | some (_, en) => en
  | none => c == "boat"

def setUserManagedPref (st : ManagedComputeStore) (userId provider : String) (enabled : Bool) (nowAt : String) :
    IO (Except String Unit) := do
  let prov := canonicalizeProvider provider
  if !isKnownProvider prov then
    return .error "unknown_provider"
  match ← execParamQuery st.db
      "INSERT INTO user_managed_provider_prefs(user_id,provider,enabled,updated_at) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id,provider) DO UPDATE SET enabled=excluded.enabled,updated_at=excluded.updated_at;"
      #[userId, prov, if enabled then "1" else "0", nowAt] with
  | .error e => return .error e
  | .ok _ => return .ok ()

private def loadMachineRows (db : SqliteDb) : IO (Except String (Array (Array String))) :=
  execParamQuery db
    "SELECT id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id,provider_id,created_at_sec,expires_at_sec,last_poll_sec,request_key,image,EXISTS(SELECT 1 FROM managed_resume_intents r WHERE r.machine_id=managed_machines.id AND r.state IN ('pending','aborting')),(SELECT observed_state FROM managed_expirations e WHERE e.machine_id=managed_machines.id AND e.boot_epoch=managed_machines.node_boot_epoch),(SELECT state FROM managed_expirations e WHERE e.machine_id=managed_machines.id AND e.boot_epoch=managed_machines.node_boot_epoch) FROM managed_machines ORDER BY id ASC;" #[]

def saveManagedFleetConfig (st : ManagedComputeStore) (enabled boatEnabled : Bool)
    (dailyCapCents spentTodayCents maxConcurrent : UInt64) : IO (Except String Unit) := do
  let sql :=
    "INSERT INTO managed_fleet_state(singleton_id,enabled,boat_enabled,daily_cap_cents,spent_today_cents,max_concurrent) " ++
    "VALUES(1,?1,?2,?3,?4,?5) ON CONFLICT(singleton_id) DO UPDATE SET " ++
    "enabled=excluded.enabled,boat_enabled=excluded.boat_enabled,daily_cap_cents=excluded.daily_cap_cents," ++
    "spent_today_cents=excluded.spent_today_cents,max_concurrent=excluded.max_concurrent;"
  match ← execParamQuery st.db sql #[
      if enabled then "1" else "0", if boatEnabled then "1" else "0",
      s!"{dailyCapCents}", s!"{spentTodayCents}", s!"{maxConcurrent}"
    ] with
  | .error e => return .error e
  | .ok _ => return .ok ()

def loadManagedFleetAt (st : ManagedComputeStore) (enabled boatEnabled : Bool)
    (dailyCapCents spentTodayCents maxConcurrent nowEpoch : UInt64) : IO (Except String ManagedFleetState) := do
  let (en, boatEn, capC, spentC, maxConc) ← do
    match ← execParamQuery st.db
        "SELECT enabled,boat_enabled,daily_cap_cents,spent_today_cents,max_concurrent FROM managed_fleet_state WHERE singleton_id=1;" #[] with
    | .ok rows =>
      if rows.size > 1 then
        let r := rows[1]!
        pure (cell r 0 == "1", cell r 1 == "1", cellU64 r 2, cellU64 r 3, cellU64 r 4)
      else
        pure (enabled, boatEnabled, dailyCapCents, spentTodayCents, maxConcurrent)
    | .error _ =>
      pure (enabled, boatEnabled, dailyCapCents, spentTodayCents, maxConcurrent)
  let (capC, spentC) ← if st.instanceName == "dev" then do
      let .ok costs ← execParamQuery st.db
          "SELECT COALESCE(SUM(cents),0) FROM managed_cost_reservations WHERE day_start=?1;"
          #[s!"{(nowEpoch / 86400) * 86400}"] | return .error "managed_instance_budget_read_failed"
      if costs.size < 2 then return .error "managed_instance_budget_read_failed"
      pure (min capC st.dailyCapCeilingCents, cellU64 costs[1]! 0)
    else pure (capC, spentC)
  match ← loadMachineRows st.db with
  | .error e => return .error e
  | .ok rows =>
    let mut machines : Array ManagedMachine := #[]
    for i in [1:rows.size] do
      machines := machines.push (machineFromRow rows[i]!)
    return .ok {
      instanceName := st.instanceName,
      instanceDailyCapCents? := if st.instanceName == "dev" then some st.dailyCapCeilingCents else none,
      enabled := en, boatEnabled := boatEn, dailyCapCents := capC,
      spentTodayCents := spentC, maxConcurrent := maxConc, machines
    }

def loadManagedFleet (st : ManagedComputeStore) (enabled boatEnabled : Bool)
    (dailyCapCents spentTodayCents maxConcurrent : UInt64) : IO (Except String ManagedFleetState) := do
  loadManagedFleetAt st enabled boatEnabled dailyCapCents spentTodayCents maxConcurrent (← nowEpoch)

/-- `257` admits only an explicit break-glass Core read from a non-managed host. `512` rejects
    every ordinary mission read (`operatorBreakGlass = false`) and every managed-node caller. -/
def admitCoreReservedSecret (callerOnManagedNode operatorBreakGlass : Bool) : UInt32 :=
  computeSecretGate 1 (if callerOnManagedNode then 1 else 0) 0 (if operatorBreakGlass then 1 else 0)

def managedSecretDir (rootDir : String) : System.FilePath :=
  System.FilePath.mk rootDir / "managed-secrets"

def managedMasterKeyPath (rootDir : String) : System.FilePath :=
  managedSecretDir rootDir / "master.key"

def managedSecretPath (rootDir provider : String) : System.FilePath :=
  managedSecretDir rootDir / s!"{provider}.aead"

private def readPrivate0600 (path : System.FilePath) : IO (Except String ByteArray) := do
  let st ← statPath path.toString
  if !st.exists_ || st.isSymlink || !st.isReg || !st.ownedByEuid || (st.mode &&& 0o077) != 0 then
    return .error "secret_file_mode_invalid"
  return .ok (← IO.FS.readBinFile path)

private def loadOrCreateMasterKey (rootDir : String) : IO (Except String ByteArray) := do
  let keyPath := managedMasterKeyPath rootDir
  let st ← statPath keyPath.toString
  if st.exists_ then
    match ← readPrivate0600 keyPath with
    | .error e => return .error e
    | .ok k =>
      if k.size != 32 then return .error "master_key_invalid_length"
      else return .ok k
  else
    let .ok k ← randBytes 32 | return .error "secret_key_rng_failed"
    match ← writeAtomicPrivate0600 keyPath k with
    | .error e => return .error e
    | .ok () => return .ok k

def sealProviderSecret (rootDir provider plaintext : String) : IO (Except String Unit) := do
  if admitCoreReservedSecret false true != 257 then
    return .error "core_reserved_secret_rejected"
  let prov := canonicalizeProvider provider
  if !isKnownProvider prov || plaintext.isEmpty then
    return .error "invalid_provider_secret"
  match ← ensurePrivateDir0700 (managedSecretDir rootDir) with
  | .error e => return .error e
  | .ok () =>
    -- Serialize first master-key creation and reseals across threads/processes.
    -- Otherwise two first-time seals could replace master.key and lose a key.
    let lock ← flockExclusiveNb (managedSecretDir rootDir / "seal.lock").toString
    if lock == 0xFFFFFFFF || lock == 0xFFFFFFFE then return .error "managed_secret_seal_busy"
    try
      let .ok key ← loadOrCreateMasterKey rootDir | return .error "master_key_unavailable"
      let .ok nonce ← randBytes 12 | return .error "secret_nonce_rng_failed"
      let aad := s!"orb-core-reserved:{prov}".toUTF8
      match ← aeadSeal .aes256Gcm key nonce aad plaintext.toUTF8 with
      | .error e => return .error e
      | .ok sealed =>
        writeAtomicPrivate0600 (managedSecretPath rootDir prov) (nonce ++ sealed)
    finally
      closeFdRaw lock.toInt32

def openProviderSecret (rootDir provider : String)
    (callerOnManagedNode : Bool) (operatorBreakGlass : Bool := true) :
    IO (Except String String) := do
  if admitCoreReservedSecret callerOnManagedNode operatorBreakGlass != 257 then
    return .error "core_reserved_secret_rejected"
  let prov := canonicalizeProvider provider
  if !isKnownProvider prov then
    return .error "invalid_provider_secret"
  let .ok key ← readPrivate0600 (managedMasterKeyPath rootDir)
    | return .error "master_key_unavailable"
  if key.size != 32 then
    return .error "master_key_invalid_length"
  let .ok raw ← readPrivate0600 (managedSecretPath rootDir prov)
    | return .error "sealed_secret_unavailable"
  if raw.size < 28 then
    return .error "sealed_secret_truncated"
  let nonce := raw.extract 0 12
  let sealed := raw.extract 12 raw.size
  let aad := s!"orb-core-reserved:{prov}".toUTF8
  match ← aeadOpen .aes256Gcm key nonce aad sealed with
  | .error e => return .error e
  | .ok pt => return .ok (String.fromUTF8? pt |>.getD "")

def observeManagedProviderCatalog (dataRoot : String) (catalog : JVal)
    (transport? : Option ManagedProvider.Transport := none)
    (cache : ManagedProvider.LeanciCapabilityCache := ManagedProvider.leanciCapabilityCache) : IO JVal := do
  let some items := catalog.asArr? | return catalog
  if !items.any (·.fieldStr? "provider" == some "leanci") then return catalog
  let mut chosen := transport?
  if chosen.isNone then
    let some entry := ManagedProvider.declaration? "leanci" | return catalog
    let .ok key ← openProviderSecret dataRoot "leanci" false true | return catalog
    let raw := ((← IO.getEnv entry.apiBaseEnv).getD entry.defaultApiBase).trimAscii.toString
    let base := String.intercalate "/" ((raw.splitOn "/").reverse.dropWhile (·.isEmpty)).reverse
    chosen := some (ManagedProvider.httpTransport base key)
  let some transport := chosen | return catalog
  let fields ← ManagedProvider.catalogFieldsObserved "leanci" transport cache
  return .arr (items.map fun item =>
    if item.fieldStr? "provider" != some "leanci" then item
    else fields.foldl (fun value field => value.setField field.1 field.2) item)

private def machineParams (m : ManagedMachine) (slice : VmSliceState) : Array String :=
  #[
    m.id, m.sandboxName, m.provider, m.size, statusOfPhase slice.phaseCode, m.ownerMission,
    s!"{m.ttlMinutes}", s!"{m.spentCents}", if m.cordoned then "1" else "0",
    s!"{slice.nodeBootEpoch}", s!"{slice.deletableAt}", m.ownerKind, m.requestedByMissionId,
    s!"{slice.phaseCode}", s!"{slice.activeComputeEligible}", m.ownerUserId, m.providerId,
    s!"{m.createdAtSec}", s!"{m.expiresAtSec}", s!"{m.lastPollSec}", m.requestKey, m.image
  ]

private def upsertMachineTx (db : SqliteDb) (m : ManagedMachine) (slice : VmSliceState) :
    IO (Except String Unit) := do
  let sql :=
    "INSERT INTO managed_machines(id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id,provider_id,created_at_sec,expires_at_sec,last_poll_sec,request_key,image) " ++
    "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22) " ++
    "ON CONFLICT(id) DO UPDATE SET sandbox_name=excluded.sandbox_name,provider=excluded.provider,size=excluded.size,status=excluded.status,owner_mission=excluded.owner_mission,ttl_minutes=excluded.ttl_minutes,spent_cents=excluded.spent_cents,cordoned=excluded.cordoned,node_boot_epoch=excluded.node_boot_epoch,deletable_at_sec=excluded.deletable_at_sec,owner_kind=excluded.owner_kind,requested_by_mission_id=excluded.requested_by_mission_id,phase_code=excluded.phase_code,active_compute_eligible=excluded.active_compute_eligible,owner_user_id=excluded.owner_user_id,provider_id=excluded.provider_id,created_at_sec=excluded.created_at_sec,expires_at_sec=excluded.expires_at_sec,last_poll_sec=excluded.last_poll_sec,request_key=excluded.request_key,image=excluded.image;"
  match ← execParamQueryUnlocked db sql (machineParams m slice) with
  | .error e => return .error e
  | .ok _ => return .ok ()

private def selectMachineTx (db : SqliteDb) (machineId : String) :
    IO (Except String (Option (ManagedMachine × VmSliceState))) := do
  match ← execParamQueryUnlocked db
      "SELECT id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id,provider_id,created_at_sec,expires_at_sec,last_poll_sec,request_key,image,EXISTS(SELECT 1 FROM managed_resume_intents r WHERE r.machine_id=managed_machines.id AND r.state IN ('pending','aborting')),(SELECT observed_state FROM managed_expirations e WHERE e.machine_id=managed_machines.id AND e.boot_epoch=managed_machines.node_boot_epoch),(SELECT state FROM managed_expirations e WHERE e.machine_id=managed_machines.id AND e.boot_epoch=managed_machines.node_boot_epoch) FROM managed_machines WHERE id=?1;"
      #[machineId] with
  | .error e => return .error e
  | .ok rows =>
    if rows.size ≤ 1 then return .ok none
    else return .ok (some (machineFromRow rows[1]!, vmSliceOf rows[1]!))

def getManagedMachine? (st : ManagedComputeStore) (machineId : String) :
    IO (Option (ManagedMachine × VmSliceState)) := do
  if machineId.isEmpty then return none
  match ← st.db.mu.atomically (selectMachineTx st.db machineId) with
  | .ok v => return v
  | .error _ => return none

def getManagedMachineByRequestKey? (st : ManagedComputeStore) (provider requestKey : String) :
    IO (Option ManagedMachine) := do
  if requestKey.isEmpty then return none
  let .ok rows ← execParamQuery st.db
      "SELECT id FROM managed_machines WHERE provider=?1 AND request_key=?2;" #[provider, requestKey]
    | return none
  if rows.size < 2 then return none
  return (← getManagedMachine? st (cell rows[1]! 0)).map Prod.fst

/-- Apply one lifecycle event through `verifyVmLifecycleAdmit` / `stepVmSlice` and persist it in one
    immediate transaction. `resume` and `replace` store the successor boot epoch the reducer returns.
    `destroy` closes the ledger only when the reducer emits `closeCostLedger`. -/
def applyVmLifecycle (st : ManagedComputeStore) (machineId : String) (ev : VmSliceEvent)
    (expectedProviderId? : Option String := none) : IO (Except String (VmSliceState × List VmEffect)) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (machine, slice)) =>
      if let some expected := expectedProviderId? then
        if machine.providerId != expected then return .error "stale_provider_identity"
      if verifyVmLifecycleAdmit slice.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
           slice.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch slice.deletableAt != 1 then
        return .error "vm_lifecycle_rejected"
      let (next, effs) := stepVmSlice slice ev
      if next == slice && effs.isEmpty then
        return .error "vm_lifecycle_rejected"
      match ← upsertMachineTx st.db machine next with
      | .error e => return .error e
      | .ok () =>
        if next.phaseCode == 3 then
          let .ok _ ← execParamQueryUnlocked st.db
              "UPDATE managed_resume_intents SET state='failed' WHERE machine_id=?1 AND state IN ('pending','aborting');" #[machineId]
            | return .error "managed_resume_close_failed"
        return .ok (next, effs)

private def admitManagedCostTx (st : ManagedComputeStore) (fleet : ManagedFleetState)
    (provider ownerUserId : String) (cost ttlMinutes nowEpoch : UInt64) (newSlot : Bool)
    (userAdmission? : Option ManagedUserAdmission) : IO (Except String ManagedFleetState) := do
  if ttlMinutes < 5 || ttlMinutes > 720 then return .error "managed_ttl_invalid"
  let .ok counts ← execParamQueryUnlocked st.db
      "SELECT COUNT(*) FROM managed_machines m WHERE phase_code IN (0,1) OR EXISTS(SELECT 1 FROM managed_resume_intents r WHERE r.machine_id=m.id AND r.state IN ('pending','aborting'));" #[]
    | return .error "managed_admission_read_failed"
  let .ok rows ← execParamQueryUnlocked st.db
      "SELECT enabled,boat_enabled,daily_cap_cents,spent_today_cents,max_concurrent FROM managed_fleet_state WHERE singleton_id=1;" #[]
    | return .error "managed_admission_read_failed"
  let current := if rows.size > 1 then { fleet with
      enabled := cell rows[1]! 0 == "1", boatEnabled := cell rows[1]! 1 == "1",
      dailyCapCents := cellU64 rows[1]! 2, spentTodayCents := cellU64 rows[1]! 3,
      maxConcurrent := cellU64 rows[1]! 4
    } else fleet
  -- This is inside the SAME immediate transaction as charging. Settings imports,
  -- stale snapshots, counter resets and concurrent callers cannot raise or race
  -- the dev ceiling. Creates, forks, resumes and extensions share this gate.
  let current ← if st.instanceName == "dev" then do
      let .ok costs ← execParamQueryUnlocked st.db
          "SELECT COALESCE(SUM(cents),0) FROM managed_cost_reservations WHERE day_start=?1;"
          #[s!"{(nowEpoch / 86400) * 86400}"] | return .error "managed_instance_budget_read_failed"
      if costs.size < 2 then return .error "managed_instance_budget_read_failed"
      pure { current with
        instanceName := "dev", instanceDailyCapCents? := some st.dailyCapCeilingCents,
        dailyCapCents := min current.dailyCapCents st.dailyCapCeilingCents, spentTodayCents := cellU64 costs[1]! 0 }
    else pure current
  if counts.size < 2 then return .error "managed_admission_read_failed"
  let active := (cellU64 counts[1]! 0).toNat
  -- An extension replaces one already-counted slot; a create/resume adds one.
  let chargedActive := if newSlot then active else active - 1
  if !admitManagedSpawnCount current chargedActive cost ttlMinutes.toUInt32 then
    return .error "managed_spawn_rejected"
  if provider == "boat" && !current.boatEnabled then return .error "provider_disabled"
  if provider != "boat" then
    let .ok providerRows ← execParamQueryUnlocked st.db
        "SELECT enabled FROM managed_provider_settings WHERE provider=?1;" #[provider]
      | return .error "managed_provider_settings_unavailable"
    if providerRows.size > 1 && cell providerRows[1]! 0 != "1" then return .error "provider_disabled"
  if let some budget := userAdmission? then
    if ownerUserId.isEmpty then return .error "managed_user_missing"
    let dayStart := (nowEpoch / 86400) * 86400
    let .ok reservedRows ← execParamQueryUnlocked st.db
        "SELECT COALESCE(SUM(cents),0) FROM managed_cost_reservations WHERE owner_user_id=?1 AND day_start=?2;"
        #[ownerUserId, s!"{dayStart}"]
      | return .error "managed_user_admission_read_failed"
    if reservedRows.size < 2 then return .error "managed_user_admission_read_failed"
    let compute := max budget.computeCents (cellU64 reservedRows[1]! 0)
    if budget.inferenceCents > budget.capCents || compute > budget.capCents - budget.inferenceCents then
      return .error "managed_user_spend_cap_exceeded"
    let spent := budget.inferenceCents + compute
    if cost > budget.capCents - spent ||
        admitManagedSpawnMultiUser { current with machines := #[] } cost spent
          (some budget.capCents) ttlMinutes.toUInt32 != 0 then
      return .error "managed_user_spend_cap_exceeded"
  return .ok current

private def chargeManagedCostTx (st : ManagedComputeStore) (current : ManagedFleetState)
    (reservationId machineId ownerUserId : String) (cost nowEpoch : UInt64) : IO (Except String Unit) := do
  let .ok _ ← execParamQueryUnlocked st.db
      "INSERT INTO managed_cost_reservations(id,machine_id,owner_user_id,day_start,cents) VALUES(?1,?2,?3,?4,?5);"
      #[reservationId, machineId, ownerUserId, s!"{(nowEpoch / 86400) * 86400}", s!"{cost}"]
    | return .error "managed_cost_reservation_failed"
  match ← execParamQueryUnlocked st.db
      ("INSERT INTO managed_fleet_state(singleton_id,enabled,boat_enabled,daily_cap_cents,spent_today_cents,max_concurrent) " ++
       "VALUES(1,?1,?2,?3,?4,?5) ON CONFLICT(singleton_id) DO UPDATE SET spent_today_cents=spent_today_cents+?6;")
      #[if current.enabled then "1" else "0", if current.boatEnabled then "1" else "0",
        s!"{current.dailyCapCents}", s!"{current.spentTodayCents + cost}", s!"{current.maxConcurrent}", s!"{cost}"] with
  | .error e => return .error e
  | .ok _ => return .ok ()

private def extensionFromRow (r : Array String) : ManagedExtensionIntent := {
  id := cell r 0, machineId := cell r 1, bootEpoch := cellU64 r 2, providerId := cell r 3,
  minutes := cellU64 r 4, oldExpiry := cellU64 r 5, newExpiry := cellU64 r 6,
  newTtl := cellU64 r 7, cost := cellU64 r 8, state := cell r 9
}

private def extensionTx (st : ManagedComputeStore) (key : String) : IO (Except String (Option ManagedExtensionIntent)) := do
  match ← execParamQueryUnlocked st.db
      "SELECT id,machine_id,boot_epoch,provider_id,minutes,old_expiry,new_expiry,new_ttl,cost,state FROM managed_extension_intents WHERE id=?1;" #[key] with
  | .error e => return .error e
  | .ok rows => return .ok (if rows.size > 1 then some (extensionFromRow rows[1]!) else none)

def pendingManagedExtensions (st : ManagedComputeStore) : IO (Except String (Array ManagedExtensionIntent)) := do
  let .ok rows ← execParamQuery st.db
      "SELECT id,machine_id,boot_epoch,provider_id,minutes,old_expiry,new_expiry,new_ttl,cost,state FROM managed_extension_intents WHERE state='pending';" #[]
    | return .error "managed_extension_read_failed"
  return .ok ((rows.extract 1 rows.size).map extensionFromRow)

private def bootStartedTx (st : ManagedComputeStore) (m : ManagedMachine) : IO (Except String UInt64) := do
  if m.nodeBootEpoch > 1 then
    let .ok rows ← execParamQueryUnlocked st.db
        "SELECT new_expiry,new_ttl FROM managed_resume_intents WHERE machine_id=?1 AND expected_boot=?2 AND state='completed' LIMIT 1;"
        #[m.id, s!"{m.nodeBootEpoch}"] | return .error "managed_boot_read_failed"
    if rows.size > 1 then return .ok (cellU64 rows[1]! 0 - cellU64 rows[1]! 1 * 60)
  if m.createdAtSec == 0 then return .error "managed_lease_start_unknown"
  return .ok m.createdAtSec

/-- Reserve a fixed extension target and its cost before provider I/O. Replays
    keep that target rather than adding another duration. Expiry claims exclude
    extensions, and pending extensions exclude premature expiry cleanup. -/
def prepareManagedExtension (st : ManagedComputeStore) (fleet : ManagedFleetState)
    (machineId key : String) (minutes nowEpoch : UInt64)
    (quote : String → UInt64 → Except String UInt64)
    (budget? : Option ManagedUserAdmission := none) : IO (Except String ManagedExtensionIntent) := do
  if key.isEmpty || minutes < 5 || minutes > 720 then return .error "managed_extension_invalid"
  withImmediateTx st.db do
    let prior ← match ← extensionTx st key with
      | .ok value => pure value
      | .error e => return .error e
    if let some p := prior then
      if p.machineId != machineId || p.minutes != minutes then return .error "managed_idempotency_conflict"
      return .ok p
    let .ok (some (m, vm)) ← selectMachineTx st.db machineId | return .error "managed_machine_missing"
    if vm.phaseCode != 1 || m.providerId.isEmpty || m.expiresAtSec ≤ nowEpoch then return .error "managed_machine_not_live"
    let .ok claims ← execParamQueryUnlocked st.db
        "SELECT 1 FROM managed_expirations WHERE machine_id=?1 AND boot_epoch=?2;" #[m.id, s!"{vm.nodeBootEpoch}"]
      | return .error "managed_expiry_read_failed"
    if claims.size > 1 then return .error "managed_expiry_already_claimed"
    let .ok started ← bootStartedTx st m | return .error "managed_lease_start_unknown"
    let hardEnd := started + 720 * 60
    let newExpiry := min (m.expiresAtSec + minutes * 60) hardEnd
    if newExpiry ≤ m.expiresAtSec then return .error "managed_max_lifetime_reached"
    let ttl := (newExpiry - started + 59) / 60
    let .ok oldQuote := quote m.size m.ttlMinutes | return .error "managed_extension_quote_invalid"
    let .ok newQuote := quote m.size ttl | return .error "managed_extension_quote_invalid"
    let cost := newQuote - oldQuote
    let current ← match ← admitManagedCostTx st fleet m.provider m.ownerUserId cost ttl nowEpoch false budget? with
      | .ok value => pure value
      | .error e => return .error e
    let intent : ManagedExtensionIntent := {
      id := key, machineId, bootEpoch := vm.nodeBootEpoch, providerId := m.providerId,
      minutes, oldExpiry := m.expiresAtSec, newExpiry, newTtl := ttl, cost, state := "pending"
    }
    let .ok _ ← execParamQueryUnlocked st.db
        "INSERT INTO managed_extension_intents(id,machine_id,boot_epoch,provider_id,minutes,old_expiry,new_expiry,new_ttl,cost) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);"
        #[key,m.id,s!"{vm.nodeBootEpoch}",m.providerId,s!"{minutes}",s!"{m.expiresAtSec}",s!"{newExpiry}",s!"{ttl}",s!"{cost}"]
      | return .error "managed_extension_already_pending"
    let .ok () ← chargeManagedCostTx st current s!"extend:{key}" m.id m.ownerUserId cost nowEpoch
      | return .error "managed_extension_cost_failed"
    return .ok intent

def finishManagedExtension (st : ManagedComputeStore) (key : String) (succeeded : Bool)
    (refund : Bool := false) : IO (Except String Unit) := do
  withImmediateTx st.db do
    let .ok (some intent) ← extensionTx st key | return .error "managed_extension_missing"
    if intent.state == "completed" && succeeded then return .ok ()
    if intent.state != "pending" then return .error "managed_extension_not_pending"
    let .ok (some (m, vm)) ← selectMachineTx st.db intent.machineId | return .error "managed_machine_missing"
    if vm.nodeBootEpoch != intent.bootEpoch || m.providerId != intent.providerId || (succeeded && vm.phaseCode != 1) then
      return .error "stale_boot_epoch"
    if !succeeded && refund then
      let .ok _ ← execParamQueryUnlocked st.db "DELETE FROM managed_cost_reservations WHERE id=?1;" #[s!"extend:{key}"]
        | return .error "managed_extension_refund_failed"
      let .ok _ ← execParamQueryUnlocked st.db
          "UPDATE managed_fleet_state SET spent_today_cents=MAX(0,spent_today_cents-?1) WHERE singleton_id=1;" #[s!"{intent.cost}"]
        | return .error "managed_extension_refund_failed"
    if succeeded then
      let .ok claims ← execParamQueryUnlocked st.db
          "SELECT 1 FROM managed_expirations WHERE machine_id=?1 AND boot_epoch=?2;" #[m.id,s!"{vm.nodeBootEpoch}"]
        | return .error "managed_expiry_read_failed"
      if claims.size > 1 then return .error "managed_expiry_already_claimed"
      if m.expiresAtSec != intent.oldExpiry then return .error "managed_extension_concurrent_change"
      let .ok () ← upsertMachineTx st.db {
          m with
          expiresAtSec := intent.newExpiry
          ttlMinutes := intent.newTtl
          spentCents := m.spentCents + intent.cost
        } vm | return .error "managed_extension_commit_failed"
    match ← execParamQueryUnlocked st.db "UPDATE managed_extension_intents SET state=?2 WHERE id=?1;"
        #[key, if succeeded then "completed" else "failed"] with
    | .error e => return .error e
    | .ok _ => return .ok ()

/-- No live machine runs without a deadline. A row written before deadlines existed
    gets one: its creation time plus its TTL, or one TTL from now when even the creation
    time is unknown. Stopped and destroyed rows are untouched. -/
def assignMissingDeadlines (st : ManagedComputeStore) (nowEpoch : UInt64) : IO (Except String Unit) := do
  match ← execParamQuery st.db
      ("UPDATE managed_machines SET " ++
       "expires_at_sec=(CASE WHEN created_at_sec>0 THEN created_at_sec ELSE ?1 END)+MAX(5,MIN(ttl_minutes,720))*60," ++
       "created_at_sec=CASE WHEN created_at_sec>0 THEN created_at_sec ELSE ?1 END " ++
       "WHERE expires_at_sec=0 AND phase_code IN (0,1);") #[s!"{nowEpoch}"] with
  | .error e => return .error e
  | .ok _ => return .ok ()

def claimManagedExpiry (st : ManagedComputeStore) (machineId : String) (nowEpoch : UInt64) : IO (Except String ManagedMachine) := do
  withImmediateTx st.db do
    let .ok (some (m, vm)) ← selectMachineTx st.db machineId | return .error "managed_machine_missing"
    if vm.phaseCode == 3 || (vm.phaseCode == 2 && m.status == "provisioning") ||
        m.expiresAtSec == 0 || m.expiresAtSec > nowEpoch then return .error "managed_machine_not_expired"
    if vm.deletableAt > nowEpoch then return .error "managed_minimum_lease_pending"
    let .ok pending ← execParamQueryUnlocked st.db
        "SELECT 1 FROM managed_extension_intents WHERE machine_id=?1 AND boot_epoch=?2 AND state='pending' AND new_expiry>?3;"
        #[m.id,s!"{vm.nodeBootEpoch}",s!"{nowEpoch}"] | return .error "managed_extension_read_failed"
    if pending.size > 1 then return .error "managed_extension_pending"
    let .ok _ ← execParamQueryUnlocked st.db
        "INSERT OR IGNORE INTO managed_expirations(machine_id,boot_epoch,provider_id,expires_at_sec,spend_cents) VALUES(?1,?2,?3,?4,?5);"
        #[m.id,s!"{vm.nodeBootEpoch}",m.providerId,s!"{m.expiresAtSec}",s!"{m.spentCents}"]
      | return .error "managed_expiry_claim_failed"
    -- The pending claim row is the fence: readers derive `destroying` from it, so a
    -- completed cleanup never leaves a stale status behind.
    return .ok m

def recordManagedExpiry (st : ManagedComputeStore) (m : ManagedMachine) (providerState : String)
    (completed : Bool) (usageCents? : Option UInt64 := none) : IO (Except String Unit) := do
  match ← execParamQuery st.db
      ("UPDATE managed_expirations SET observed_state=?3,state=?4," ++
       "spend_cents=CASE WHEN ?6='1' THEN ?7 ELSE spend_cents END,spend_source=CASE WHEN ?6='1' THEN 'provider_usage' ELSE spend_source END " ++
       "WHERE machine_id=?1 AND boot_epoch=?2 AND provider_id=?5;")
      #[m.id,s!"{m.nodeBootEpoch}",providerState,if completed then "completed" else "pending",m.providerId,
        if usageCents?.isSome then "1" else "0",s!"{usageCents?.getD 0}"] with
  | .error e => return .error e
  | .ok _ => return .ok ()

def provisionManagedMachine (st : ManagedComputeStore) (fleet : ManagedFleetState)
    (machine : ManagedMachine) (nowEpoch : UInt64)
    (userAdmission? : Option ManagedUserAdmission := none) : IO (Except String ManagedMachine) := do
  if machine.ttlMinutes < 5 || machine.ttlMinutes > 720 then return .error "managed_ttl_invalid"
  if st.instanceName != "dev" && !admitManagedSpawn fleet machine.spentCents machine.ttlMinutes.toUInt32 then
    return .error "managed_spawn_rejected"
  if !isKnownProvider machine.provider || machine.id.isEmpty || machine.nodeBootEpoch == 0 then
    return .error "managed_spawn_invalid"
  let slice : VmSliceState := {
    phaseCode := 0
    activeComputeEligible := 0
    nodeBootEpoch := machine.nodeBootEpoch
    deletableAt := machine.deletableAtSec
  }
  -- Reserving provider capacity is not evidence of node readiness. Only an
  -- authenticated relay poll may emit the verified `provision` event.
  let reserved := { machine with
    status := "provisioning", lastPollSec := 0,
    createdAtSec := if machine.createdAtSec == 0 then nowEpoch else machine.createdAtSec,
    expiresAtSec := if machine.expiresAtSec == 0 then nowEpoch + machine.ttlMinutes * 60 else machine.expiresAtSec
  }
  withImmediateTx st.db do
    let current ← match ← admitManagedCostTx st fleet machine.provider machine.ownerUserId
        machine.spentCents machine.ttlMinutes nowEpoch true userAdmission? with
      | .ok value => pure value
      | .error e => return .error e
    match ← selectMachineTx st.db machine.id with
    | .error e => return .error e
    | .ok (some _) => return .error "managed_machine_exists"
    | .ok none =>
      match ← upsertMachineTx st.db reserved slice with
      | .error e => return .error e
      | .ok () =>
        match ← chargeManagedCostTx st current s!"create:{machine.id}" machine.id
            machine.ownerUserId machine.spentCents nowEpoch with
        | .error e => return .error e
        | .ok _ => return .ok reserved

/-- Bind the provider's mutable boot identity without replacing Core's durable ID. -/
def bindManagedProviderId (st : ManagedComputeStore) (machineId providerId : String)
    (bootEpoch : UInt64) : IO (Except String Unit) := do
  if providerId.trimAscii.toString.isEmpty then return .error "provider_machine_id_missing"
  withImmediateTx st.db do
    let .ok (some (m, slice)) ← selectMachineTx st.db machineId
      | return .error "managed_machine_missing"
    if slice.nodeBootEpoch != bootEpoch || slice.phaseCode != 0 then return .error "stale_boot_epoch"
    upsertMachineTx st.db { m with providerId } slice

/-- Reconciliation may fill a legacy binding in any live phase, but never
    replace a known provider identity or change the durable machine/node ID. -/
def backfillManagedProviderIdentity (st : ManagedComputeStore) (machineId provider providerId : String) :
    IO (Except String Unit) := do
  if providerId.isEmpty then return .error "provider_machine_id_missing"
  withImmediateTx st.db do
    let .ok (some (m, slice)) ← selectMachineTx st.db machineId | return .error "managed_machine_missing"
    if canonicalizeProvider m.provider != provider then return .error "managed_provider_mismatch"
    if !m.providerId.isEmpty then
      if m.providerId == providerId then return .ok () else return .error "managed_provider_identity_conflict"
    upsertMachineTx st.db { m with providerId } slice

private def resumeIntentFromRow (r : Array String) : ManagedResumeIntent := {
  id := cell r 0, machineId := cell r 1, expectedBoot := cellU64 r 2,
  oldProviderId := cell r 3, newProviderId := cell r 4,
  oldTtl := cellU64 r 5, oldExpiry := cellU64 r 6,
  newTtl := cellU64 r 7, newExpiry := cellU64 r 8,
  deadlineSec := cellU64 r 9, state := cell r 10
}

private def getResumeIntentTx (st : ManagedComputeStore) (requestKey : String) :
    IO (Except String (Option ManagedResumeIntent)) := do
  match ← execParamQueryUnlocked st.db
      "SELECT id,machine_id,expected_boot,old_provider_id,new_provider_id,old_ttl,old_expiry,new_ttl,new_expiry,deadline_sec,state FROM managed_resume_intents WHERE id=?1;" #[requestKey] with
  | .error e => return .error e
  | .ok rows => return .ok (if rows.size > 1 then some (resumeIntentFromRow rows[1]!) else none)

def getManagedResumeIntent? (st : ManagedComputeStore) (requestKey : String) :
    IO (Except String (Option ManagedResumeIntent)) :=
  st.db.mu.atomically (getResumeIntentTx st requestKey)

/-- Reserve a resume before provider I/O. The old boot stays stopped and its
    token is revoked; the successor only becomes live on its authenticated poll. -/
def prepareManagedResume (st : ManagedComputeStore) (fleet : ManagedFleetState)
    (machineId requestKey enrollToken : String) (ttl cost nowEpoch deadlineSec : UInt64)
    (userAdmission? : Option ManagedUserAdmission := none) :
    IO (Except String (ManagedResumeIntent × Bool)) := do
  if requestKey.isEmpty || enrollToken.isEmpty then return .error "managed_resume_invalid"
  withImmediateTx st.db do
    let prior ← match ← getResumeIntentTx st requestKey with
      | .ok value => pure value
      | .error e => return .error e
    if let some p := prior then
      if p.machineId != machineId || p.newTtl != ttl then return .error "managed_idempotency_conflict"
      return .ok (p, false)
    let .ok (some (m, slice)) ← selectMachineTx st.db machineId
      | return .error "managed_machine_missing"
    let .ok expiryClaims ← execParamQueryUnlocked st.db
        "SELECT 1 FROM managed_expirations WHERE machine_id=?1 AND boot_epoch=?2 AND state='pending';" #[m.id,s!"{slice.nodeBootEpoch}"]
      | return .error "managed_expiry_read_failed"
    if expiryClaims.size > 1 then return .error "managed_expiry_cleanup_pending"
    let successor := slice.nodeBootEpoch + 1
    if verifyVmLifecycleAdmit slice.phaseCode (VmOp.encode .resume) 0 0
        slice.nodeBootEpoch successor nowEpoch slice.deletableAt != 1 then
      return .error "vm_resume_rejected"
    if deadlineSec ≤ nowEpoch || m.spentCents + cost < m.spentCents then
      return .error "managed_resume_invalid"
    let current ← match ← admitManagedCostTx st fleet m.provider m.ownerUserId cost ttl nowEpoch true userAdmission? with
      | .ok value => pure value
      | .error e => return .error e
    let intent : ManagedResumeIntent := {
      id := requestKey, machineId, expectedBoot := successor,
      oldProviderId := m.effectiveProviderId, newProviderId := "",
      oldTtl := m.ttlMinutes, oldExpiry := m.expiresAtSec,
      newTtl := ttl, newExpiry := nowEpoch + ttl * 60,
      deadlineSec, state := "pending"
    }
    let .ok _ ← execParamQueryUnlocked st.db
        "INSERT INTO managed_resume_intents(id,machine_id,expected_boot,old_provider_id,old_ttl,old_expiry,new_ttl,new_expiry,deadline_sec) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);"
        #[intent.id, machineId, s!"{successor}", intent.oldProviderId, s!"{intent.oldTtl}", s!"{intent.oldExpiry}", s!"{ttl}", s!"{intent.newExpiry}", s!"{deadlineSec}"]
      | return .error "managed_resume_already_pending"
    let .ok () ← chargeManagedCostTx st current s!"resume:{requestKey}" m.id m.ownerUserId cost nowEpoch
      | return .error "managed_resume_cost_reservation_failed"
    let .ok () ← upsertMachineTx st.db { m with spentCents := m.spentCents + cost, lastPollSec := 0 } slice
      | return .error "managed_resume_store_failed"
    let .ok _ ← execParamQueryUnlocked st.db
        ("INSERT INTO managed_node_tokens(machine_id,node_id,node_token,enroll_token,node_boot_epoch,readiness_deadline_sec) VALUES(?1,'','',?2,?3,?4) " ++
         "ON CONFLICT(machine_id) DO UPDATE SET node_id='',node_token='',enroll_token=excluded.enroll_token,node_boot_epoch=excluded.node_boot_epoch,readiness_deadline_sec=excluded.readiness_deadline_sec;")
        #[machineId, enrollToken, s!"{successor}", s!"{deadlineSec}"]
      | return .error "managed_resume_token_store_failed"
    return .ok (intent, true)

def bindManagedResumeProvider (st : ManagedComputeStore) (requestKey providerId : String) : IO (Except String Unit) := do
  if providerId.isEmpty then return .error "provider_machine_id_missing"
  withImmediateTx st.db do
    let .ok (some intent) ← getResumeIntentTx st requestKey | return .error "managed_resume_missing"
    let .ok (some (m, slice)) ← selectMachineTx st.db intent.machineId | return .error "managed_machine_missing"
    if intent.state != "pending" || slice.phaseCode != 2 || slice.nodeBootEpoch + 1 != intent.expectedBoot then
      return .error "stale_boot_epoch"
    let .ok _ ← execParamQueryUnlocked st.db
        "UPDATE managed_resume_intents SET new_provider_id=?2 WHERE id=?1 AND state='pending';" #[requestKey, providerId]
      | return .error "managed_resume_binding_failed"
    upsertMachineTx st.db { m with providerId, ttlMinutes := intent.newTtl, expiresAtSec := intent.newExpiry } slice

/-- Fence first-poll admission before deleting a timed-out successor. This
    prevents a late poll (or a wall-clock adjustment) racing provider cleanup. -/
def fenceManagedResumeCleanup (st : ManagedComputeStore) (requestKey : String) :
    IO (Except String ManagedResumeIntent) := do
  withImmediateTx st.db do
    let .ok (some intent) ← getResumeIntentTx st requestKey | return .error "managed_resume_missing"
    let .ok (some (_, slice)) ← selectMachineTx st.db intent.machineId | return .error "managed_machine_missing"
    if intent.state == "completed" then return .error "managed_resume_already_ready"
    if (intent.state != "pending" && intent.state != "aborting") || slice.phaseCode != 2 ||
        slice.nodeBootEpoch + 1 != intent.expectedBoot then return .error "stale_boot_epoch"
    let .ok _ ← execParamQueryUnlocked st.db "UPDATE managed_resume_intents SET state='aborting' WHERE id=?1;" #[requestKey]
      | return .error "managed_resume_fence_failed"
    let .ok _ ← execParamQueryUnlocked st.db "DELETE FROM managed_node_tokens WHERE machine_id=?1;" #[intent.machineId]
      | return .error "managed_resume_token_revoke_failed"
    return .ok { intent with state := "aborting" }

/-- Called only after the failed successor guest is confirmed destroyed. The
    retained stopped source remains resumable, but none of its old tokens revive. -/
def abortManagedResume (st : ManagedComputeStore) (requestKey : String) : IO (Except String Unit) := do
  withImmediateTx st.db do
    let .ok (some intent) ← getResumeIntentTx st requestKey | return .error "managed_resume_missing"
    let .ok (some (m, slice)) ← selectMachineTx st.db intent.machineId | return .error "managed_machine_missing"
    if (intent.state != "pending" && intent.state != "aborting") || slice.phaseCode != 2 || slice.nodeBootEpoch + 1 != intent.expectedBoot then
      return .error "stale_boot_epoch"
    let .ok () ← upsertMachineTx st.db {
        m with
        providerId := intent.oldProviderId
        ttlMinutes := intent.oldTtl
        expiresAtSec := intent.oldExpiry
        lastPollSec := 0
      } slice | return .error "managed_resume_rollback_failed"
    let .ok _ ← execParamQueryUnlocked st.db "DELETE FROM managed_node_tokens WHERE machine_id=?1;" #[m.id]
      | return .error "managed_resume_token_revoke_failed"
    match ← execParamQueryUnlocked st.db "UPDATE managed_resume_intents SET state='failed' WHERE id=?1;" #[requestKey] with
    | .error e => return .error e
    | .ok _ => return .ok ()

private def expectedManagedBootTx (st : ManagedComputeStore) (machineId : String)
    (vm : VmSliceState) : IO (Except String UInt64) := do
  if vm.phaseCode == 2 then
    let .ok rows ← execParamQueryUnlocked st.db
        "SELECT expected_boot FROM managed_resume_intents WHERE machine_id=?1 AND state='pending' AND new_provider_id<>'';" #[machineId]
      | return .error "managed_resume_read_failed"
    if rows.size > 1 then
      let expected := cellU64 rows[1]! 0
      if verifyVmLifecycleAdmit vm.phaseCode (VmOp.encode .resume) 0 0 vm.nodeBootEpoch expected 0 vm.deletableAt != 1 then
        return .error "stale_boot_epoch"
      return .ok expected
  return .ok vm.nodeBootEpoch

private def authenticateNodeTokenTx (st : ManagedComputeStore) (machineId nodeToken : String)
    (presentedBootEpoch? : Option UInt64) : IO (Except String UInt64) := do
  let .ok (some (_, vm)) ← selectMachineTx st.db machineId | return .error "node_unauthorized"
  let .ok rows ← execParamQueryUnlocked st.db
      "SELECT node_token,node_boot_epoch FROM managed_node_tokens WHERE machine_id=?1;" #[machineId]
    | return .error "node_unauthorized"
  if rows.size < 2 || nodeToken.isEmpty || cell rows[1]! 0 != nodeToken then return .error "node_unauthorized"
  if vm.phaseCode == 3 then return .error "stale_boot_epoch"
  let .ok expected ← expectedManagedBootTx st machineId vm | return .error "stale_boot_epoch"
  if cellU64 rows[1]! 1 != expected then return .error "stale_boot_epoch"
  if let some presented := presentedBootEpoch? then
    if presented != expected then return .error "stale_boot_epoch"
  return .ok expected

private def recordManagedPollTx (st : ManagedComputeStore) (machineId : String)
    (bootEpoch nowEpoch : UInt64) : IO (Except String UInt64) := do
  let .ok (some (m, slice)) ← selectMachineTx st.db machineId | return .error "managed_machine_missing"
  if slice.phaseCode == 3 then return .error "stale_boot_epoch"
  let .ok expected ← expectedManagedBootTx st machineId slice | return .error "stale_boot_epoch"
  if expected != bootEpoch || (slice.phaseCode == 2 && expected == slice.nodeBootEpoch) then
    return .error "stale_boot_epoch"
  let .ok pendingExtension ← execParamQueryUnlocked st.db
      "SELECT COALESCE(MAX(new_expiry),0) FROM managed_extension_intents WHERE machine_id=?1 AND boot_epoch=?2 AND provider_id=?3 AND state='pending';"
      #[m.id,s!"{slice.nodeBootEpoch}",m.providerId] | return .error "managed_extension_read_failed"
  let pendingExpiry := if pendingExtension.size > 1 then cellU64 pendingExtension[1]! 0 else 0
  let effectiveExpiry := max m.expiresAtSec pendingExpiry
  if effectiveExpiry != 0 && nowEpoch ≥ effectiveExpiry then return .error "managed_machine_expired"
  if slice.phaseCode != 1 then
    let .ok rows ← execParamQueryUnlocked st.db
        "SELECT readiness_deadline_sec FROM managed_node_tokens WHERE machine_id=?1;" #[machineId]
      | return .error "node_unauthorized"
    let deadline := if rows.size > 1 then cellU64 rows[1]! 0 else 0
    if deadline != 0 && nowEpoch ≥ deadline then return .error "managed_bootstrap_deadline_expired"
  let next ← if slice.phaseCode == 0 || slice.phaseCode == 2 then do
    let ev : VmSliceEvent := {
      opCode := if slice.phaseCode == 0 then VmOp.encode .provision else VmOp.encode .resume,
      ownerLive := 0, idleElapsed := 0, presentedBootEpoch := bootEpoch, nowEpoch
    }
    if verifyVmLifecycleAdmit slice.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
        slice.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch slice.deletableAt != 1 then
      return .error "vm_provision_rejected"
    pure (stepVmSlice slice ev).1
    else pure slice
  if slice.phaseCode == 2 then
    let .ok _ ← execParamQueryUnlocked st.db
        "UPDATE managed_resume_intents SET state='completed' WHERE machine_id=?1 AND expected_boot=?2 AND state='pending';"
        #[machineId, s!"{bootEpoch}"] | return .error "managed_resume_commit_failed"
  let .ok () ← upsertMachineTx st.db { m with lastPollSec := max m.lastPollSec nowEpoch } next
    | return .error "managed_poll_store_failed"
  return .ok next.nodeBootEpoch

/-- Trusted fixture/internal entry point; external polls use the atomic token
    authentication + observation function below to fence concurrent revocation. -/
def recordAuthenticatedManagedPoll (st : ManagedComputeStore) (machineId : String)
    (bootEpoch nowEpoch : UInt64) : IO (Except String UInt64) :=
  withImmediateTx st.db (recordManagedPollTx st machineId bootEpoch nowEpoch)

/-- Authentication, boot transition and heartbeat have one transaction/owner. -/
def authenticateAndRecordManagedPoll (st : ManagedComputeStore) (machineId nodeToken : String)
    (presentedBootEpoch? : Option UInt64) (nowEpoch : UInt64) : IO (Except String UInt64) :=
  withImmediateTx st.db do
    let boot ← match ← authenticateNodeTokenTx st machineId nodeToken presentedBootEpoch? with
      | .ok value => pure value
      | .error e => return .error e
    match ← recordManagedPollTx st machineId boot nowEpoch with
    | .ok value => return .ok value
    | .error _ => return .error "stale_boot_epoch"

private def claimFromRow (row : Array String) : ManagedClaim :=
  {
    machineId := cell row 0
    reservationId := cellU64 row 1
    phaseCode := cellU8 row 2
    claimBoot := cellU64 row 3
    ownerMission := cell row 4
  }

/-- Claim, release, or reclaim inside the same immediate transaction as the VM row read. -/
def applyVmClaim (st : ManagedComputeStore) (machineId ownerMission : String) (ev : ClaimSliceEvent) :
    IO (Except String ManagedClaim) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (machine, vm)) =>
      if ev.presentedBootEpoch != vm.nodeBootEpoch then
        return .error "stale_boot_epoch"
      match ← execParamQueryUnlocked st.db
          "SELECT machine_id,reservation_id,phase_code,claim_boot,owner_mission FROM managed_vm_claims WHERE machine_id=?1;"
          #[machineId] with
      | .error e => return .error e
      | .ok rows =>
        let prior := if rows.size ≤ 1 then
          ({ machineId, reservationId := 0, phaseCode := 0, claimBoot := 0, ownerMission := "" } : ManagedClaim)
        else claimFromRow rows[1]!
        let claimState : ClaimSliceState := {
          phaseCode := prior.phaseCode
          reservationId := prior.reservationId
          claimBoot := prior.claimBoot
          nodeBootEpoch := vm.nodeBootEpoch
        }
        let effPhase : UInt8 :=
          if (claimState.phaseCode == 1 || claimState.phaseCode == 2) &&
             claimState.claimBoot != 0 && claimState.claimBoot < claimState.nodeBootEpoch && ev.opCode == 0
          then 0
          else claimState.phaseCode
        if verifyVmClaimAdmit effPhase ev.opCode ev.ownerInLineage ev.ownerSuperseded
             ev.vmLive ev.activeComputeEligible claimState.reservationId ev.presentedReservation
             claimState.nodeBootEpoch ev.presentedBootEpoch != 1 then
          return .error "vm_claim_rejected"
        let (next, effs) := stepClaimSlice claimState ev
        if next == claimState && effs.isEmpty then
          return .error "vm_claim_rejected"
        match ← execParamQueryUnlocked st.db
            "INSERT INTO managed_vm_claims(machine_id,reservation_id,phase_code,claim_boot,owner_mission) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(machine_id) DO UPDATE SET reservation_id=excluded.reservation_id,phase_code=excluded.phase_code,claim_boot=excluded.claim_boot,owner_mission=excluded.owner_mission;"
            #[machineId, s!"{next.reservationId}", s!"{next.phaseCode}", s!"{next.claimBoot}", ownerMission] with
        | .error e => return .error e
        | .ok _ =>
          if ev.opCode == ClaimOp.encode .release then
            match ← upsertMachineTx st.db { machine with ownerMission := "" } vm with
            | .error e => return .error e
            | .ok () => pure ()
          else
            match ← upsertMachineTx st.db { machine with ownerMission := ownerMission } vm with
            | .error e => return .error e
            | .ok () => pure ()
          return .ok {
            machineId
            reservationId := next.reservationId
            phaseCode := next.phaseCode
            claimBoot := next.claimBoot
            ownerMission := if ev.opCode == ClaimOp.encode .release then "" else ownerMission
          }

def enrollManagedNode (st : ManagedComputeStore) (machineId presentedEnrollToken : String)
    (presentedBootEpoch? : Option UInt64 := none) : IO (Except String (String × String)) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (_, vm)) =>
      if vm.phaseCode == 3 then
        return .error "stale_boot_epoch"
      let .ok expected ← expectedManagedBootTx st machineId vm | return .error "stale_boot_epoch"
      if let some b := presentedBootEpoch? then
        if b != expected then return .error "stale_boot_epoch"
      match ← execParamQueryUnlocked st.db
          "SELECT machine_id,node_id,node_token,enroll_token,node_boot_epoch FROM managed_node_tokens WHERE machine_id=?1;"
          #[machineId] with
      | .error e => return .error e
      | .ok rows =>
        if rows.size ≤ 1 then return .error "enrollment_missing"
        let row := rows[1]!
        if cell row 3 != presentedEnrollToken || cellU64 row 4 != expected || (cell row 3).isEmpty then
          return .error "enrollment_rejected"
        if !(cell row 2).isEmpty then
          return .error "enrollment_rejected"
        let nodeToken ← newUuidV4
        let nodeId := s!"managed-{machineId}"
        match ← execParamQueryUnlocked st.db
            "UPDATE managed_node_tokens SET node_id=?2,node_token=?3,enroll_token='' WHERE machine_id=?1 AND enroll_token=?4 AND node_boot_epoch=?5;"
            #[machineId, nodeId, nodeToken, presentedEnrollToken, s!"{expected}"] with
        | .error e => return .error e
        | .ok _ => return .ok (nodeId, nodeToken)

def putEnrollmentToken (st : ManagedComputeStore) (machineId enrollToken : String)
    (readinessDeadlineSec : UInt64 := 0) : IO (Except String Unit) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (_, vm)) =>
      match ← execParamQueryUnlocked st.db
          "INSERT INTO managed_node_tokens(machine_id,node_id,node_token,enroll_token,node_boot_epoch,readiness_deadline_sec) VALUES(?1,'','',?2,?3,?4) ON CONFLICT(machine_id) DO UPDATE SET enroll_token=excluded.enroll_token,node_token='',node_boot_epoch=excluded.node_boot_epoch,readiness_deadline_sec=excluded.readiness_deadline_sec;"
          #[machineId, enrollToken, s!"{vm.nodeBootEpoch}", s!"{readinessDeadlineSec}"] with
      | .error e => return .error e
      | .ok _ => return .ok ()

def authenticateNodeToken (st : ManagedComputeStore) (machineId nodeToken : String)
    (presentedBootEpoch? : Option UInt64 := none) : IO (Except String UInt64) :=
  st.db.mu.atomically (authenticateNodeTokenTx st machineId nodeToken presentedBootEpoch?)

private def relayFromRow (row : Array String) : ManagedRelayCommand :=
  {
    commandId := cell row 0
    machineId := cell row 1
    phaseCode := cellU8 row 2
    heldLeaseId := cellU64 row 3
    leaseSeq := cellU64 row 4
    leaseEpoch := cellU64 row 5
    leaseDeadline := cellU64 row 6
    nodeBootEpoch := cellU64 row 7
    payloadJson := cell row 8
  }

private def saveRelayTx (db : SqliteDb) (cmd : ManagedRelayCommand) : IO (Except String Unit) := do
  match ← execParamQueryUnlocked db
      "INSERT INTO managed_relay_commands(command_id,machine_id,phase_code,held_lease_id,lease_seq,lease_epoch,lease_deadline,node_boot_epoch,payload_json) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(command_id) DO UPDATE SET phase_code=excluded.phase_code,held_lease_id=excluded.held_lease_id,lease_seq=excluded.lease_seq,lease_epoch=excluded.lease_epoch,lease_deadline=excluded.lease_deadline,node_boot_epoch=excluded.node_boot_epoch,payload_json=excluded.payload_json;"
      #[cmd.commandId, cmd.machineId, s!"{cmd.phaseCode}", s!"{cmd.heldLeaseId}", s!"{cmd.leaseSeq}", s!"{cmd.leaseEpoch}", s!"{cmd.leaseDeadline}", s!"{cmd.nodeBootEpoch}", cmd.payloadJson] with
  | .error e => return .error e
  | .ok _ => return .ok ()

def enqueueRelayCommand (st : ManagedComputeStore) (machineId commandId payloadJson : String) :
    IO (Except String Unit) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (_, vm)) =>
      if vm.phaseCode != 1 then return .error "vm_not_eligible"
      saveRelayTx st.db {
        commandId, machineId, phaseCode := RelayPhase.encode .pending, heldLeaseId := 0, leaseSeq := 0,
        leaseEpoch := 0, leaseDeadline := 0, nodeBootEpoch := vm.nodeBootEpoch, payloadJson
      }

def stepRelayCommand (st : ManagedComputeStore) (commandId : String) (ev : RelaySliceEvent)
    (leaseDeadline : UInt64 := 0) : IO (Except String ManagedRelayCommand) := do
  withImmediateTx st.db do
    match ← execParamQueryUnlocked st.db
        "SELECT command_id,machine_id,phase_code,held_lease_id,lease_seq,lease_epoch,lease_deadline,node_boot_epoch,payload_json FROM managed_relay_commands WHERE command_id=?1;"
        #[commandId] with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .error "relay_command_missing"
      let cmd := relayFromRow rows[1]!
      match ← selectMachineTx st.db cmd.machineId with
      | .error e => return .error e
      | .ok none => return .error "managed_machine_missing"
      | .ok (some (_, vm)) =>
        if ev.presentedBootEpoch != vm.nodeBootEpoch || cmd.nodeBootEpoch != vm.nodeBootEpoch then
          return .error "stale_boot_epoch"
        if verifyRelayCommandAdmit cmd.phaseCode ev.opCode
             cmd.heldLeaseId ev.presentedLeaseId vm.nodeBootEpoch ev.presentedBootEpoch != 1 then
          return .error "relay_command_rejected"
        let state : RelaySliceState := {
          phaseCode := cmd.phaseCode
          retired := relayPhaseRetired cmd.phaseCode
          heldLeaseId := cmd.heldLeaseId
          leaseEpoch := cmd.leaseEpoch
          nodeBootEpoch := vm.nodeBootEpoch
        }
        let (next, effs) := stepRelaySlice state ev
        if next == state && effs.isEmpty then
          return .error "relay_command_rejected"
        let saved : ManagedRelayCommand := {
          cmd with
          phaseCode := next.phaseCode
          heldLeaseId := next.heldLeaseId
          leaseEpoch := next.leaseEpoch
          nodeBootEpoch := next.nodeBootEpoch
          leaseDeadline := if ev.opCode == RelayOp.encode .lease then leaseDeadline else cmd.leaseDeadline
        }
        match ← saveRelayTx st.db saved with
        | .error e => return .error e
        | .ok () => return .ok saved

/-- A leased command past its deadline returns to `Pending` without dropping the payload.
    The verified reducer rejects `retry`, so expiry is an explicit pre-ack lease release. -/
def expireRelayLease (st : ManagedComputeStore) (commandId : String) (nowEpoch presentedBootEpoch : UInt64) :
    IO (Except String ManagedRelayCommand) := do
  withImmediateTx st.db do
    match ← execParamQueryUnlocked st.db
        "SELECT command_id,machine_id,phase_code,held_lease_id,lease_seq,lease_epoch,lease_deadline,node_boot_epoch,payload_json FROM managed_relay_commands WHERE command_id=?1;"
        #[commandId] with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .error "relay_command_missing"
      let cmd := relayFromRow rows[1]!
      match ← selectMachineTx st.db cmd.machineId with
      | .error e => return .error e
      | .ok none => return .error "managed_machine_missing"
      | .ok (some (_, vm)) =>
        if presentedBootEpoch != vm.nodeBootEpoch || cmd.phaseCode != RelayPhase.encode .leased ||
            cmd.leaseDeadline == 0 || nowEpoch < cmd.leaseDeadline then
          return .error "relay_lease_still_held"
        let released := { cmd with phaseCode := RelayPhase.encode .pending, heldLeaseId := 0, leaseEpoch := 0, leaseDeadline := 0 }
        match ← saveRelayTx st.db released with
        | .error e => return .error e
        | .ok () => return .ok released

def pollRelayLease (st : ManagedComputeStore) (machineId : String) (presentedBootEpoch nowEpoch leaseDeadline : UInt64) :
    IO (Except String (Option ManagedRelayCommand)) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (_, vm)) =>
      if presentedBootEpoch != vm.nodeBootEpoch then
        return .error "stale_boot_epoch"
      match ← execParamQueryUnlocked st.db
          "SELECT command_id FROM managed_relay_commands WHERE machine_id=?1 AND phase_code=0 AND node_boot_epoch=?2 ORDER BY command_id ASC LIMIT 1;"
          #[machineId, s!"{vm.nodeBootEpoch}"] with
      | .error e => return .error e
      | .ok rows =>
        if rows.size ≤ 1 then return .ok none
        let commandId := cell rows[1]! 0
        match ← execParamQueryUnlocked st.db
            "SELECT command_id,machine_id,phase_code,held_lease_id,lease_seq,lease_epoch,lease_deadline,node_boot_epoch,payload_json FROM managed_relay_commands WHERE command_id=?1;"
            #[commandId] with
        | .error e => return .error e
        | .ok cmdRows =>
          if cmdRows.size ≤ 1 then return .ok none
          let cmd := relayFromRow cmdRows[1]!
          let leaseId := cmd.leaseSeq + 1
          if verifyRelayCommandAdmit cmd.phaseCode (RelayOp.encode .lease)
               cmd.heldLeaseId leaseId vm.nodeBootEpoch vm.nodeBootEpoch != 1 then
            return .error "relay_lease_rejected"
          let ev : RelaySliceEvent := {
            opCode := RelayOp.encode .lease
            presentedLeaseId := leaseId
            presentedBootEpoch := vm.nodeBootEpoch
            nowEpoch
          }
          let (next, effs) := stepRelaySlice {
            phaseCode := cmd.phaseCode, retired := 0, heldLeaseId := cmd.heldLeaseId,
            leaseEpoch := cmd.leaseEpoch, nodeBootEpoch := vm.nodeBootEpoch
          } ev
          if effs.isEmpty then return .error "relay_lease_rejected"
          let saved := {
            cmd with
            phaseCode := next.phaseCode, heldLeaseId := next.heldLeaseId, leaseSeq := leaseId,
            leaseEpoch := next.leaseEpoch, leaseDeadline := leaseDeadline
          }
          match ← saveRelayTx st.db saved with
          | .error e => return .error e
          | .ok () => return .ok (some saved)

/-- Pure adapter across the six providers (`boat`, `leanci`, `hetzner`, `vastai`, `scaleway`, `colab`).
    Never touches SQLite or ledgers; emits only a `ProviderObservation`. -/
def observeProviderPayload (provider machineId : String) (httpStatus : Nat) (payload : JVal) :
    Except String ProviderObservation :=
  let prov := canonicalizeProvider provider
  if !isKnownProvider prov then
    .error "unknown_provider"
  else if httpStatus == 404 || (prov != "boat" && httpStatus == 410) then
    .ok { provider := prov, machineId, observedStatus := "destroyed", orphaned := true }
  else if httpStatus < 200 || httpStatus ≥ 300 then
    .error "provider_observation_failed"
  else
    let rawState :=
      ((payload.fieldStr? "state").orElse (fun _ => payload.fieldStr? "status")).getD ""
        |>.trimAscii.toString.toLower
    let spentCents := (payload.fieldUInt64? "spent_cents").getD 0
    let (normStatus, orphaned) :=
      if rawState == "running" || rawState == "ready" || rawState == "online" || rawState == "connected" ||
          (prov == "boat" && (rawState == "idle" || rawState == "busy")) then
        ("ready", false)
      else if rawState == "stopped" || rawState == "halted" || rawState == "off" ||
          rawState == "exited" || rawState == "stopped_in_place" || rawState == "disconnected" ||
          (prov == "boat" && (rawState == "archived" || rawState == "archiving" || rawState == "error")) then
        ("stopped", false)
      else if prov != "boat" && (rawState == "destroyed" || rawState == "deleted" || rawState == "terminated" ||
          rawState == "missing" || rawState == "reaped") then
        ("destroyed", true)
      else
        ("provisioning", false)
    .ok {
      provider := prov, machineId, observedStatus := normStatus, spentCents,
      spentObserved := (payload.fieldUInt64? "spent_cents").isSome, orphaned,
      retainedArchived := prov == "boat" && rawState == "archived"
    }

private def repairProviderStopped (st : ManagedComputeStore) (obs : ProviderObservation) :
    IO (Except String (List VmEffect)) :=
  withImmediateTx st.db do
    let .ok (some (m, slice)) ← selectMachineTx st.db obs.machineId
      | return .error "managed_machine_missing"
    if canonicalizeProvider m.provider != canonicalizeProvider obs.provider ||
        obs.observedStatus != "stopped" || obs.orphaned ||
        (slice.phaseCode == 3 && (m.provider != "boat" || !obs.retainedArchived)) ||
        obs.expectedProviderId? != some m.providerId || m.providerId.isEmpty then
      return .error "stale_provider_identity"
    if obs.expectedBootEpoch? != some slice.nodeBootEpoch then return .error "stale_boot_epoch"
    let next := observeVmRetainedArchive slice true slice.nodeBootEpoch
    if next == slice then return .error "vm_observation_rejected"
    let .ok _ ← execParamQueryUnlocked st.db
        "DELETE FROM managed_node_tokens WHERE machine_id=?1;" #[m.id]
      | return .error "managed_archive_token_revoke_failed"
    let .ok () ← upsertMachineTx st.db { m with lastPollSec := 0 } next
      | return .error "managed_archive_repair_failed"
    return .ok [.persistVmPhase next.phaseCode next.activeComputeEligible next.nodeBootEpoch]

/-- Apply one pure observation. Orphans and ledger closure happen only when `stepVmSlice` admits
    `destroy` and emits `closeCostLedger`. -/
def applyProviderObservation (st : ManagedComputeStore) (obs : ProviderObservation)
    (nowEpoch : UInt64) (ownerLive idleElapsed : UInt8) : IO (Except String (List VmEffect)) := do
  let prov := canonicalizeProvider obs.provider
  if !isKnownProvider prov then
    return .error "unknown_provider"
  match ← execParamQuery st.db
      "SELECT node_boot_epoch,phase_code,provider_id FROM managed_machines WHERE id=?1 AND provider=?2;" #[obs.machineId, prov] with
  | .error e => return .error e
  | .ok rows =>
    if rows.size ≤ 1 then return .error "managed_machine_missing"
    let boot := obs.expectedBootEpoch?.getD (cellU64 rows[1]! 0)
    let phase := cellU8 rows[1]! 1
    if let some expected := obs.expectedProviderId? then
      if expected != cell rows[1]! 2 then return .error "stale_provider_identity"
    if boot != cellU64 rows[1]! 0 then return .error "stale_boot_epoch"
    if obs.observedStatus == "stopped" && (phase == 0 || (obs.retainedArchived && phase == 3)) then
      return ← repairProviderStopped st obs
    if (obs.orphaned && phase == 3) || (obs.observedStatus == "stopped" && phase == 2) then
      return .ok []
    if obs.orphaned then
      match ← applyVmLifecycle st obs.machineId {
        opCode := VmOp.encode .destroy, ownerLive, idleElapsed,
        presentedBootEpoch := boot, nowEpoch
      } obs.expectedProviderId? with
      | .error e => return .error e
      | .ok (_, effs) => return .ok effs
    else if obs.observedStatus == "stopped" then
      match ← applyVmLifecycle st obs.machineId {
        opCode := VmOp.encode .stop, ownerLive := 0, idleElapsed := 0,
        presentedBootEpoch := boot, nowEpoch
      } obs.expectedProviderId? with
      | .error e => return .error e
      | .ok (_, effs) => return .ok effs
    else if !obs.spentObserved then
      return .ok []
    else
      match ← execParamQuery st.db
          ("UPDATE managed_machines SET spent_cents=?2 WHERE id=?1 AND provider=?3 " ++
           "AND (?4='0' OR provider_id=?5) AND (?6='0' OR node_boot_epoch=?7);")
          #[obs.machineId, s!"{obs.spentCents}", prov,
            if obs.expectedProviderId?.isSome then "1" else "0", obs.expectedProviderId?.getD "",
            if obs.expectedBootEpoch?.isSome then "1" else "0", s!"{boot}"] with
      | .error e => return .error e
      | .ok _ => return .ok []

private def providerDisplayName (p : String) : String :=
  match p with
  | "boat" => "boat.dev"
  | "leanci" => "lean.ci"
  | "hetzner" => "Hetzner"
  | "vastai" => "Vast.ai"
  | "scaleway" => "Scaleway"
  | "colab" => "Google Colab"
  | _ => p

def renderManagedProvidersJson
    (st : ManagedFleetState)
    (isAdmin : Bool := true)
    (userPrefs : Array (String × Bool) := #[])
    (configuredProviders : Array String := #[])
    (disabledProviders : Array String := #[])
    (observations : Array (String × JVal) := #[]) : String :=
  let items := knownProviders.map fun p =>
    let globallyConfigured := configuredProviders.any (fun cp => canonicalizeProvider cp == p) || (p == "boat" && st.boatEnabled)
    let globallyEnabled := st.enabled && !disabledProviders.contains p &&
      (if p == "boat" then st.boatEnabled else globallyConfigured)
    let observation := ((observations.find? (·.1 == p)).map Prod.snd).getD
      (ManagedProvider.availabilityJson { status := .unknown, reason := "not_observed" })
    let userEnabled := isUserManagedProviderEnabled userPrefs p
    let effectiveEnabled := globallyEnabled && userEnabled
    OrbBin.Json.renderCompact (.obj (#[
      ("provider", .str p), ("display_name", .str (providerDisplayName p)),
      ("configured", .bool globallyConfigured), ("enabled", .bool effectiveEnabled),
      ("globally_enabled", .bool globallyEnabled), ("user_enabled", .bool userEnabled),
      ("effective_enabled", .bool effectiveEnabled), ("availability", observation),
      ("credential_source", if isAdmin && globallyConfigured then .str "settings" else .null),
      ("key_hint", if isAdmin && globallyConfigured then .str "••••" else .null)
    ] ++ ManagedProvider.catalogFields p))
  "[" ++ String.intercalate "," items.toList ++ "]"

/-- The provider's declared shape for a machine's size, when Core knows it. -/
def managedSizeSpec? (provider size : String) : Option ManagedProvider.Size :=
  (ManagedProvider.declaration? (canonicalizeProvider provider)).bind fun entry =>
    entry.sizes.find? (·.name == size)

/-- Hourly price as a JSON number of dollars, from the declared milli-cent rate. -/
def managedUsdPerHourJson (provider size : String) : String :=
  match managedSizeSpec? provider size with
  | none => "null"
  | some spec =>
    let fraction := toString (spec.milliCentsPerHour % 100000)
    s!"{spec.milliCentsPerHour / 100000}.{String.ofList (List.replicate (5 - fraction.length) '0')}{fraction}"

private def optNatJson (value : Option Nat) : String :=
  match value with
  | some n => toString n
  | none => "null"

def managedMachineInstance (name : String) : String :=
  if name.startsWith "orb-managed-dev-" then "dev" else "prod"

def renderManagedMachineItemJson (m : ManagedMachine) : String :=
  s!"\{\"instance\":{jsonEscape (managedMachineInstance m.sandboxName)},\"id\":{jsonEscape m.id},\"name\":{jsonEscape m.sandboxName},\"sandbox_name\":{jsonEscape m.sandboxName},\"provider\":{jsonEscape m.provider},\"provider_id\":{jsonEscape (ManagedProvider.publicProviderId m.provider m.effectiveProviderId)},\"node_id\":{jsonEscape s!"managed-{m.id}"},\"image\":{jsonEscape m.image},\"size\":{jsonEscape m.size},\"cpu\":{optNatJson ((managedSizeSpec? m.provider m.size).map (·.cpu))},\"ram_gb\":{optNatJson ((managedSizeSpec? m.provider m.size).map (·.ramGb))},\"state\":{jsonEscape m.status},\"owner_mission\":{jsonEscape m.ownerMission},\"owner_mission_id\":{if m.ownerMission.isEmpty then "null" else jsonEscape m.ownerMission},\"owner_kind\":{if m.ownerKind.isEmpty then "\"user\"" else jsonEscape m.ownerKind},\"node_boot_epoch\":{m.nodeBootEpoch},\"last_poll_sec\":{m.lastPollSec},\"created_at_sec\":{m.createdAtSec},\"expires_at_sec\":{m.expiresAtSec},\"created_at\":{jsonEscape (formatEpochIso8601Utc m.createdAtSec)},\"expires_at\":{jsonEscape (formatEpochIso8601Utc m.expiresAtSec)},\"deletable_at\":{if m.deletableAtSec == 0 then "null" else jsonEscape (formatEpochIso8601Utc m.deletableAtSec)},\"deletable_at_sec\":{m.deletableAtSec},\"spent_cents\":{m.spentCents},\"cost_usd\":{formatCentsUsd2 m.spentCents},\"usd_per_hour\":{managedUsdPerHourJson m.provider m.size},\"expiry_provider_state\":{jsonEscape m.expiryProviderState},\"expiry_cleanup_state\":{jsonEscape m.expiryCleanupState},\"ledger_closed\":{if m.status == "destroyed" || m.expiryCleanupState == "completed" then "true" else "false"},\"cordoned\":{if m.cordoned then "true" else "false"}}"

def renderManagedMachinesJson
    (st : ManagedFleetState)
    (callerUserId? : Option String := none)
    (isAdmin : Bool := true)
    (userPrefs : Array (String × Bool) := #[])
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none)
    (configuredProviders : Array String := #[])
    (disabledProviders : Array String := #[]) : String :=
  match callerUserId? with
  | none =>
    let active := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let enStr := if st.enabled then "true" else "false"
    let boatStr := if st.boatEnabled then "true" else "false"
    let items := st.machines.map renderManagedMachineItemJson
    s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{st.spentTodayCents},\"daily_cap_cents\":{st.dailyCapCents},\"machines\":[{String.intercalate "," items.toList}],\"budget\":{renderManagedBudgetJson st}}"
  | some uid =>
    let visible := st.machines.filter (fun m => m.ownerUserId == uid)
    let active := (visible.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let enStr := if st.enabled then "true" else "false"
    let boatStr := if st.boatEnabled then "true" else "false"
    let items := visible.map renderManagedMachineItemJson
    let budgetJson := renderManagedBudgetJson st (some uid) userSpentTodayCents userDailyCapCents?
    let provsJson := renderManagedProvidersJson st isAdmin userPrefs configuredProviders disabledProviders
    s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{userSpentTodayCents},\"daily_cap_cents\":{st.dailyCapCents},\"machines\":[{String.intercalate "," items.toList}],\"sizes\":[],\"providers\":{provsJson},\"budget\":{budgetJson},\"daily_spend\":[]}"

def renderRemoteNodesJson
    (st : ManagedFleetState)
    (callerUserId? : Option String := none)
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none) : String :=
  let visible := match callerUserId? with
    | none => st.machines
    | some uid => st.machines.filter (fun m => m.ownerUserId == uid)
  let nodes := visible.filterMap fun m =>
    if m.status == "destroyed" then none
    else some s!"\{\"id\":{jsonEscape s!"managed-{m.id}"},\"machine_id\":{jsonEscape m.id},\"provider\":{jsonEscape m.provider},\"status\":{jsonEscape m.status},\"node_boot_epoch\":{m.nodeBootEpoch},\"labels\":[\"managed\",{jsonEscape s!"provider={m.provider}"}]}"
  s!"\{\"nodes\":[{String.intercalate "," nodes.toList}],\"managed_compute\":{renderManagedBudgetJson st callerUserId? userSpentTodayCents userDailyCapCents?}}"

def renderRelayPollJson (cmd : ManagedRelayCommand) : String :=
  s!"[\{\"id\":{jsonEscape cmd.commandId},\"lease_id\":{cmd.heldLeaseId},\"lease_deadline\":{cmd.leaseDeadline},\"node_boot_epoch\":{cmd.nodeBootEpoch},\"payload\":{cmd.payloadJson}}]"

/-! ## Mission Budget, Reset Cadence, VM Concurrency & Bandwidth Pacing (`/api/control/missions/:id/budget`) -/

structure MissionBudgetConfig where
  missionId           : String
  budgetDeciMilliUsd? : Option UInt64 := none
  resetPeriod         : String := "total"
  vmLimitsJson        : String := ""
  bandwidthLimitsJson : String := ""
  updatedAt           : UInt64 := 0
  deriving Repr, DecidableEq

/-- Parse a positive finite JSON number into `1e-4` USD integer units (`$1.00 = 10000`). -/
def parseDeciMilliUsd? (v : JVal) (minDm maxDm : UInt64) : Option UInt64 :=
  match v with
  | .num raw =>
    let s := raw.trimAscii.toString
    if s.isEmpty || s.startsWith "-" || s.contains 'e' || s.contains 'E' then none
    else
      match s.splitOn "." with
      | [wholeStr] => do
        let w ← wholeStr.toNat?
        let dm := (w * 10000).toUInt64
        if minDm ≤ dm && dm ≤ maxDm then some dm else none
      | [wholeStr, fracStr] => do
        let w ← if wholeStr.isEmpty then some 0 else wholeStr.toNat?
        if fracStr.isEmpty || !fracStr.all Char.isDigit then none
        else
          let padded := (fracStr ++ "0000").take 4 |>.toString
          let f ← padded.toNat?
          let roundUp :=
            if fracStr.length > 4 then
              let d5 := (fracStr.drop 4).take 1 |>.toString
              d5 ≥ "5"
            else false
          let dm := (w * 10000 + f + (if roundUp then 1 else 0)).toUInt64
          if minDm ≤ dm && dm ≤ maxDm then some dm else none
      | _ => none
  | _ => none

def formatDeciMilliUsd (dm : UInt64) : String :=
  let whole := dm / 10000
  let rem := dm % 10000
  if rem == 0 then
    s!"{whole}.0"
  else
    let pad4 :=
      if rem < 10 then s!"000{rem}"
      else if rem < 100 then s!"00{rem}"
      else if rem < 1000 then s!"0{rem}"
      else s!"{rem}"
    let revTrim := pad4.toList.reverse.dropWhile (· == '0')
    let frac := if revTrim.isEmpty then "0" else String.ofList revTrim.reverse
    s!"{whole}.{frac}"

def isValidBudgetResetPeriod (s : String) : Bool :=
  s == "total" || s == "daily" || s == "weekly"

/-- Return `(periodStartedAt?, periodResetsAt?)` in UTC ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`). -/
def budgetResetWindowBounds (resetPeriod : String) (nowEpochSec : UInt64) : Option String × Option String :=
  if resetPeriod == "daily" then
    let startSec := nowEpochSec - (nowEpochSec % 86400)
    let endSec := startSec + 86400
    (some (formatEpochIso8601Utc startSec), some (formatEpochIso8601Utc endSec))
  else if resetPeriod == "weekly" then
    let dayNum := nowEpochSec / 86400
    -- 1970-01-01 was Thursday (3 days after Monday)
    let daysFromMonday := (dayNum + 3) % 7
    let mondayStartSec := (dayNum - daysFromMonday) * 86400
    let nextMondaySec := mondayStartSec + 604800
    (some (formatEpochIso8601Utc mondayStartSec), some (formatEpochIso8601Utc nextMondaySec))
  else
    (none, none)

def validateVmLimitsPatch (v : JVal) : Except (String × String) String := do
  match v with
  | .null => return ""
  | .obj kvs =>
    let mut maxConcJson := "null"
    let mut hasMaxConc := false
    if let some mv := (kvs.find? (fun (k, _) => k == "max_concurrent")).map Prod.snd then
      match mv with
      | .null => maxConcJson := "null"
      | _ =>
        match mv.asNat? with
        | some n =>
          if 1 ≤ n && n ≤ 128 then
            maxConcJson := s!"{n}"
            hasMaxConc := true
          else
            throw ("invalid_vm_limits", "vm_limits.max_concurrent must be between 1 and 128")
        | none =>
          throw ("invalid_vm_limits", "vm_limits.max_concurrent must be an integer between 1 and 128")
    let mut provPairs : Array String := #[]
    if let some pv := (kvs.find? (fun (k, _) => k == "provider_max_concurrent")).map Prod.snd then
      match pv with
      | .null => pure ()
      | .obj pkvs =>
        for (pkRaw, pval) in pkvs do
          let pk := canonicalizeProvider pkRaw
          if !isKnownProvider pk then
            throw ("invalid_vm_limits", s!"Unknown cloud provider `{pkRaw}` in provider_max_concurrent")
          match pval.asNat? with
          | some n =>
            if n ≤ 128 then
              provPairs := provPairs.push s!"{jsonEscape pk}:{n}"
            else
              throw ("invalid_vm_limits", s!"Provider concurrency cap for `{pk}` must be between 0 and 128")
          | none =>
            throw ("invalid_vm_limits", s!"Provider concurrency cap for `{pk}` must be an integer between 0 and 128")
      | _ =>
        throw ("invalid_vm_limits", "vm_limits.provider_max_concurrent must be an object")
    if !hasMaxConc && provPairs.isEmpty then
      return ""
    return s!"\{\"max_concurrent\":{maxConcJson},\"provider_max_concurrent\":\{{String.intercalate "," provPairs.toList}}}"
  | _ =>
    throw ("invalid_vm_limits", "vm_limits must be an object or null")

def validateBandwidthLimitsPatch (v : JVal) : Except (String × String) String := do
  match v with
  | .null => return ""
  | .obj kvs =>
    let mut tokJson := "null"
    let mut infUsdJson := "null"
    let mut vcpuJson := "null"
    let mut cmpUsdJson := "null"
    let mut hasAnyCap := false
    if let some tv := (kvs.find? (fun (k, _) => k == "tokens_per_min")).map Prod.snd then
      if !tv.isNull then
        match tv.asNat? with
        | some n =>
          if 1000 ≤ n && n ≤ 100000000 then
            tokJson := s!"{n}"
            hasAnyCap := true
          else
            throw ("invalid_bandwidth_limits", "bandwidth_limits.tokens_per_min must be between 1000 and 100000000")
        | none =>
          throw ("invalid_bandwidth_limits", "bandwidth_limits.tokens_per_min must be an integer")
    if let some iv := (kvs.find? (fun (k, _) => k == "inference_usd_per_hour")).map Prod.snd then
      if !iv.isNull then
        match parseDeciMilliUsd? iv 100 100000000 with
        | some dm =>
          infUsdJson := formatDeciMilliUsd dm
          hasAnyCap := true
        | none =>
          throw ("invalid_bandwidth_limits", "bandwidth_limits.inference_usd_per_hour must be between 0.01 and 10000")
    if let some vv := (kvs.find? (fun (k, _) => k == "compute_vcpu_per_min")).map Prod.snd then
      if !vv.isNull then
        match vv.asNat? with
        | some n =>
          if 1 ≤ n && n ≤ 4096 then
            vcpuJson := s!"{n}"
            hasAnyCap := true
          else
            throw ("invalid_bandwidth_limits", "bandwidth_limits.compute_vcpu_per_min must be between 1 and 4096")
        | none =>
          throw ("invalid_bandwidth_limits", "bandwidth_limits.compute_vcpu_per_min must be an integer")
    if let some cv := (kvs.find? (fun (k, _) => k == "compute_usd_per_hour")).map Prod.snd then
      if !cv.isNull then
        match parseDeciMilliUsd? cv 100 100000000 with
        | some dm =>
          cmpUsdJson := formatDeciMilliUsd dm
          hasAnyCap := true
        | none =>
          throw ("invalid_bandwidth_limits", "bandwidth_limits.compute_usd_per_hour must be between 0.01 and 10000")
    let protectRoot :=
      match (kvs.find? (fun (k, _) => k == "protect_root")).map Prod.snd with
      | some (.bool b) => b
      | _ => true
    if !hasAnyCap then
      throw ("invalid_bandwidth_limits", "Set at least one rate cap or pass bandwidth_limits: null to clear")
    let prStr := if protectRoot then "true" else "false"
    return s!"\{\"tokens_per_min\":{tokJson},\"inference_usd_per_hour\":{infUsdJson},\"compute_vcpu_per_min\":{vcpuJson},\"compute_usd_per_hour\":{cmpUsdJson},\"protect_root\":{prStr}}"
  | _ =>
    throw ("invalid_bandwidth_limits", "bandwidth_limits must be an object or null")

def getMissionBudgetConfig (st : ManagedComputeStore) (missionId : String) : IO MissionBudgetConfig := do
  match ← execParamQuery st.db
      "SELECT budget_deci_milli_usd,reset_period,vm_limits_json,bandwidth_limits_json,updated_at FROM mission_budgets WHERE mission_id=?1;"
      #[missionId] with
  | .ok rows =>
    if rows.size > 1 then
      let r := rows[1]!
      let bRaw := (cell r 0).trimAscii.toString
      let bOpt := if bRaw.isEmpty then none else (bRaw.toNat?).map Nat.toUInt64
      let rpRaw := (cell r 1).trimAscii.toString
      let rp := if isValidBudgetResetPeriod rpRaw then rpRaw else "total"
      return {
        missionId := missionId
        budgetDeciMilliUsd? := bOpt
        resetPeriod := if bOpt.isSome then rp else "total"
        vmLimitsJson := (cell r 2).trimAscii.toString
        bandwidthLimitsJson := (cell r 3).trimAscii.toString
        updatedAt := cellU64 r 4
      }
    else
      return { missionId := missionId }
  | .error _ =>
    return { missionId := missionId }

def saveMissionBudgetConfig (st : ManagedComputeStore) (cfg : MissionBudgetConfig) : IO (Except String Unit) := do
  if cfg.budgetDeciMilliUsd?.isNone && cfg.vmLimitsJson.isEmpty && cfg.bandwidthLimitsJson.isEmpty then
    match ← execParamQuery st.db "DELETE FROM mission_budgets WHERE mission_id=?1;" #[cfg.missionId] with
    | .error e => return .error e
    | .ok _ => return .ok ()
  else
    let sql :=
      "INSERT INTO mission_budgets(mission_id,budget_deci_milli_usd,reset_period,vm_limits_json,bandwidth_limits_json,updated_at) " ++
      "VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(mission_id) DO UPDATE SET " ++
      "budget_deci_milli_usd=excluded.budget_deci_milli_usd,reset_period=excluded.reset_period," ++
      "vm_limits_json=excluded.vm_limits_json,bandwidth_limits_json=excluded.bandwidth_limits_json,updated_at=excluded.updated_at;"
    let bParam := match cfg.budgetDeciMilliUsd? with | some dm => s!"{dm}" | none => ""
    let rp := if cfg.budgetDeciMilliUsd?.isSome && isValidBudgetResetPeriod cfg.resetPeriod then cfg.resetPeriod else "total"
    match ← execParamQuery st.db sql #[cfg.missionId, bParam, rp, cfg.vmLimitsJson, cfg.bandwidthLimitsJson, s!"{cfg.updatedAt}"] with
    | .error e => return .error e
    | .ok _ => return .ok ()

def renderMissionBudgetJson
    (fleet : ManagedFleetState)
    (cfg : MissionBudgetConfig)
    (nowEpochSec : UInt64) : String :=
  let ownMachines := fleet.machines.filter (fun m => m.ownerMission == cfg.missionId)
  let liveMachines := ownMachines.filter (fun m => m.status == "ready" || m.status == "provisioning")
  let globalActive := (fleet.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
  let spentDm : UInt64 := ownMachines.foldl (fun acc m => acc + m.spentCents * 100) 0
  let reservedDm : UInt64 := liveMachines.foldl (fun acc m =>
    let remSecs : UInt64 := if m.deletableAtSec > nowEpochSec then m.deletableAtSec - nowEpochSec else m.ttlMinutes * 60
    -- Default $0.10/h = 1000 deci-milli-USD/hour
    acc + (remSecs * 1000) / 3600) 0
  let leasesJsonItems := liveMachines.map fun m =>
    let remSecs : UInt64 := if m.deletableAtSec > nowEpochSec then m.deletableAtSec - nowEpochSec else m.ttlMinutes * 60
    s!"\{\"remaining_secs\":{remSecs},\"usd_per_hour\":0.1}"
  let (ownBudgetJson, resetPeriodJson, poolIdJson, modeJson, poolJson, maxGrantJson) :=
    match cfg.budgetDeciMilliUsd? with
    | none =>
      ("null", "\"total\"", "null", "\"none\"", "null", "null")
    | some capDm =>
      let rp := if isValidBudgetResetPeriod cfg.resetPeriod then cfg.resetPeriod else "total"
      let (pStart?, pEnd?) := budgetResetWindowBounds rp nowEpochSec
      let pStartJson := match pStart? with | some s => jsonEscape s | none => "null"
      let pEndJson := match pEnd? with | some s => jsonEscape s | none => "null"
      let usedDm := spentDm + reservedDm
      let availDm : UInt64 := if capDm > usedDm then capDm - usedDm else 0
      let pJson :=
        s!"\{\"pool_id\":{jsonEscape cfg.missionId},\"budget_usd\":{formatDeciMilliUsd capDm}," ++
        s!"\"spent_usd\":{formatDeciMilliUsd spentDm},\"lifetime_spent_usd\":{formatDeciMilliUsd spentDm}," ++
        s!"\"reserved_usd\":{formatDeciMilliUsd reservedDm},\"carved_usd\":0.0,\"persistent_carved_usd\":0.0," ++
        s!"\"available_usd\":{formatDeciMilliUsd availDm},\"live_machines\":{liveMachines.size}," ++
        s!"\"live_leases\":[{String.intercalate "," leasesJsonItems.toList}]," ++
        s!"\"reset_period\":{jsonEscape rp},\"period_started_at\":{pStartJson},\"period_resets_at\":{pEndJson}}"
      (formatDeciMilliUsd capDm, jsonEscape rp, jsonEscape cfg.missionId, "\"own\"", pJson, formatDeciMilliUsd availDm)
  let (ownVmJson, vmModeJson, vmPoolIdJson, effVmJson) :=
    if cfg.vmLimitsJson.isEmpty then
      let eff :=
        s!"\{\"source\":\"global\",\"pool_id\":null,\"active\":{liveMachines.size},\"max_concurrent\":null," ++
        s!"\"global_active\":{globalActive},\"global_max_concurrent\":{fleet.maxConcurrent}," ++
        s!"\"ancestor_max_concurrent\":null,\"provider_limits\":[]}"
      ("null", "\"global\"", "null", eff)
    else
      let parsedVm := (OrbBin.Json.parse cfg.vmLimitsJson).toOption.getD (.obj #[])
      let mcJson := match parsedVm.fieldNat? "max_concurrent" with | some n => s!"{n}" | none => "null"
      let provItems : Array String :=
        match parsedVm.field? "provider_max_concurrent" with
        | some (.obj pkvs) =>
          pkvs.filterMap fun (pk, pv) =>
            let pkCanon := canonicalizeProvider pk
            pv.asNat?.map fun capN =>
              let actP := (liveMachines.filter (fun m => canonicalizeProvider m.provider == pkCanon)).size
              s!"\{\"provider\":{jsonEscape pkCanon},\"active\":{actP},\"max_concurrent\":{capN}}"
        | _ => #[]
      let eff :=
        s!"\{\"source\":\"mission\",\"pool_id\":{jsonEscape cfg.missionId},\"active\":{liveMachines.size},\"max_concurrent\":{mcJson}," ++
        s!"\"global_active\":{globalActive},\"global_max_concurrent\":{fleet.maxConcurrent}," ++
        s!"\"ancestor_max_concurrent\":null,\"provider_limits\":[{String.intercalate "," provItems.toList}]}"
      (cfg.vmLimitsJson, "\"own\"", jsonEscape cfg.missionId, eff)
  let (ownBwJson, bwModeJson, bwPoolIdJson, effBwJson) :=
    if cfg.bandwidthLimitsJson.isEmpty then
      let eff :=
        "{\"source\":\"none\",\"pool_id\":null,\"tokens_per_min\":null,\"inference_usd_per_hour\":null," ++
        "\"compute_vcpu_per_min\":null,\"compute_usd_per_hour\":null,\"protect_root\":true," ++
        "\"current_tokens_per_min\":0,\"current_inference_usd_per_hour\":0.0,\"current_vcpu_per_min\":0.0," ++
        "\"current_compute_usd_per_hour\":0.0,\"pacing_active\":false,\"paced_delay_ms\":0," ++
        "\"ancestor_tokens_per_min\":null,\"ancestor_inference_usd_per_hour\":null," ++
        "\"ancestor_compute_vcpu_per_min\":null,\"ancestor_compute_usd_per_hour\":null}"
      ("null", "\"none\"", "null", eff)
    else
      let parsedBw := (OrbBin.Json.parse cfg.bandwidthLimitsJson).toOption.getD (.obj #[])
      let rawFieldJson (k : String) : String :=
        match parsedBw.field? k with
        | some v => OrbBin.Json.renderCompact v
        | none => "null"
      let prStr := if (parsedBw.fieldBool? "protect_root").getD true then "true" else "false"
      let eff :=
        s!"\{\"source\":\"mission\",\"pool_id\":{jsonEscape cfg.missionId}," ++
        s!"\"tokens_per_min\":{rawFieldJson "tokens_per_min"}," ++
        s!"\"inference_usd_per_hour\":{rawFieldJson "inference_usd_per_hour"}," ++
        s!"\"compute_vcpu_per_min\":{rawFieldJson "compute_vcpu_per_min"}," ++
        s!"\"compute_usd_per_hour\":{rawFieldJson "compute_usd_per_hour"}," ++
        s!"\"protect_root\":{prStr}," ++
        "\"current_tokens_per_min\":0,\"current_inference_usd_per_hour\":0.0,\"current_vcpu_per_min\":0.0," ++
        "\"current_compute_usd_per_hour\":0.0,\"pacing_active\":false,\"paced_delay_ms\":0," ++
        "\"ancestor_tokens_per_min\":null,\"ancestor_inference_usd_per_hour\":null," ++
        "\"ancestor_compute_vcpu_per_min\":null,\"ancestor_compute_usd_per_hour\":null}"
      (cfg.bandwidthLimitsJson, "\"own\"", jsonEscape cfg.missionId, eff)
  s!"\{\"mission_id\":{jsonEscape cfg.missionId},\"own_budget_usd\":{ownBudgetJson},\"own_budget_reset_period\":{resetPeriodJson}," ++
  s!"\"pool_id\":{poolIdJson},\"mode\":{modeJson},\"pool\":{poolJson},\"max_grant_usd\":{maxGrantJson}," ++
  s!"\"own_vm_limits\":{ownVmJson},\"vm_limits_mode\":{vmModeJson},\"vm_limits_pool_id\":{vmPoolIdJson},\"effective_vm_limits\":{effVmJson}," ++
  s!"\"own_bandwidth_limits\":{ownBwJson},\"bandwidth_mode\":{bwModeJson},\"bandwidth_pool_id\":{bwPoolIdJson},\"effective_bandwidth\":{effBwJson}," ++
  "\"children\":[]}"

end OrbCore.Managed
