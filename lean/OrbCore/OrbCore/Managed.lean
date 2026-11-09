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

namespace OrbCore.Managed

open Orb.Kernel
open Orb.ManagedNode
open OrbBin.Json
open OrbBin.PosixExt
open OrbNetLeaf.Crypto
open OrbCore.Spec
open OrbCore.Store

/-- Service-scoped VM name prefix (`"orb-managed-"` on production or unsuffixed binaries,
    `"orb-managed-<suffix>-"` on `sandboxed-sh-<suffix>` so non-prod instances never reap prod VMs). -/
def sandboxNamePrefixFor (exeName : String) : String :=
  let base := ((exeName.splitOn "/").getLast?).getD exeName
  if base.startsWith "sandboxed-sh-" then
    let suffix := (base.drop 13).toString
    if suffix.isEmpty || suffix == "prod" then "orb-managed-"
    else s!"orb-managed-{suffix}-"
  else
    "orb-managed-"

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
  deriving Repr, DecidableEq

/-- Managed fleet budget & concurrency state. -/
structure ManagedFleetState where
  enabled         : Bool   := false
  boatEnabled     : Bool   := false
  dailyCapCents   : UInt64 := 2000
  spentTodayCents : UInt64 := 0
  maxConcurrent   : UInt64 := 100
  machines        : Array ManagedMachine := #[]
  deriving Repr, DecidableEq

/-- Overflow-safe managed VM spawn admission through `Orb.Kernel.vmStep` (`orb_vm_step`). -/
def admitManagedSpawn (st : ManagedFleetState) (reqCents : UInt64) (ttlMins : UInt32 := 60) : Bool :=
  if !st.enabled then false
  else if reqCents > st.dailyCapCents || st.spentTodayCents > st.dailyCapCents - reqCents then
    false
  else
    let activeNat := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let active : UInt32 := (Nat.min activeNat 0xFFFFFFFF).toUInt32
    let cap : UInt32 := (Nat.min st.maxConcurrent.toNat 0xFFFFFFFF).toUInt32
    let totalSpent : UInt64 := st.spentTodayCents + reqCents
    vmStep 0 1 3 0 0 0 0 0 active cap ttlMins 720 20 totalSpent st.dailyCapCents == 1

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
def renderManagedBudgetJson
    (st : ManagedFleetState)
    (callerUserId? : Option String := none)
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none) : String :=
  match callerUserId? with
  | none =>
    let active := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let enStr := if st.enabled then "true" else "false"
    let boatStr := if st.boatEnabled then "true" else "false"
    s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{st.spentTodayCents},\"daily_cap_cents\":{st.dailyCapCents}}"
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
    else if canonical == "sandboxed-sh-prod" then (1, "sandboxed-sh-prod.service")
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

/-- Pure provider observation. Adapters emit these; they never write the machine table. -/
structure ProviderObservation where
  provider : String
  machineId : String
  observedStatus : String
  spentCents : UInt64 := 0
  orphaned : Bool := false
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

def managedComputeDdl : String :=
  "PRAGMA journal_mode=WAL;" ++
  "CREATE TABLE IF NOT EXISTS managed_machines(" ++
  "id TEXT PRIMARY KEY,sandbox_name TEXT NOT NULL,provider TEXT NOT NULL,size TEXT NOT NULL," ++
  "status TEXT NOT NULL,owner_mission TEXT NOT NULL,ttl_minutes INTEGER NOT NULL," ++
  "spent_cents INTEGER NOT NULL,cordoned INTEGER NOT NULL,node_boot_epoch INTEGER NOT NULL," ++
  "deletable_at_sec INTEGER NOT NULL,owner_kind TEXT NOT NULL,requested_by_mission_id TEXT NOT NULL," ++
  "phase_code INTEGER NOT NULL,active_compute_eligible INTEGER NOT NULL," ++
  "owner_user_id TEXT NOT NULL DEFAULT '');" ++
  "CREATE INDEX IF NOT EXISTS idx_managed_machines_owner ON managed_machines(owner_user_id);" ++
  "CREATE TABLE IF NOT EXISTS user_managed_provider_prefs(" ++
  "user_id TEXT NOT NULL,provider TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1," ++
  "updated_at TEXT NOT NULL DEFAULT '',PRIMARY KEY(user_id,provider));" ++
  "CREATE TABLE IF NOT EXISTS managed_vm_claims(" ++
  "machine_id TEXT PRIMARY KEY,reservation_id INTEGER NOT NULL,phase_code INTEGER NOT NULL," ++
  "claim_boot INTEGER NOT NULL,owner_mission TEXT NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS managed_node_tokens(" ++
  "machine_id TEXT PRIMARY KEY,node_id TEXT NOT NULL,node_token TEXT NOT NULL," ++
  "enroll_token TEXT NOT NULL,node_boot_epoch INTEGER NOT NULL);" ++
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
  "updated_at INTEGER NOT NULL DEFAULT 0);"

def managedAdditiveAlters : Array String := #[
  "ALTER TABLE managed_machines ADD COLUMN owner_user_id TEXT NOT NULL DEFAULT '';",
  "CREATE INDEX IF NOT EXISTS idx_managed_machines_owner ON managed_machines(owner_user_id);",
  "CREATE TABLE IF NOT EXISTS mission_budgets(mission_id TEXT PRIMARY KEY,budget_deci_milli_usd INTEGER,reset_period TEXT NOT NULL DEFAULT 'total',vm_limits_json TEXT NOT NULL DEFAULT '',bandwidth_limits_json TEXT NOT NULL DEFAULT '',updated_at INTEGER NOT NULL DEFAULT 0);"
]

def knownProviders : Array String :=
  #["boat", "boost", "hetzner", "vastai", "scaleway", "colab"]

def isKnownProvider (provider : String) : Bool :=
  knownProviders.any (· == provider)

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
    status := cell row 4
    ownerMission := cell row 5
    ttlMinutes := cellU64 row 6
    spentCents := cellU64 row 7
    cordoned := cell row 8 == "1"
    nodeBootEpoch := cellU64 row 9
    deletableAtSec := cellU64 row 10
    ownerKind := cell row 11
    requestedByMissionId := cell row 12
    ownerUserId := cell row 15
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
  | .ok db => return .ok { db := db }

def closeManagedComputeStore (st : ManagedComputeStore) : IO Unit :=
  st.db.mu.atomically (sqliteCloseRaw st.db.handle)

def backfillManagedMachineOwner (st : ManagedComputeStore) (bootstrapAdminId : String) : IO (Except String Unit) := do
  if bootstrapAdminId.isEmpty then return .ok ()
  match ← execParamQuery st.db
      "UPDATE managed_machines SET owner_user_id=?1 WHERE owner_user_id='';" #[bootstrapAdminId] with
  | .error e => return .error e
  | .ok _ => return .ok ()

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
  match prefs.find? (fun (p, _) => p == provider) with
  | some (_, en) => en
  | none => true

def setUserManagedPref (st : ManagedComputeStore) (userId provider : String) (enabled : Bool) (nowAt : String) :
    IO (Except String Unit) := do
  if !isKnownProvider provider then
    return .error "unknown_provider"
  match ← execParamQuery st.db
      "INSERT INTO user_managed_provider_prefs(user_id,provider,enabled,updated_at) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id,provider) DO UPDATE SET enabled=excluded.enabled,updated_at=excluded.updated_at;"
      #[userId, provider, if enabled then "1" else "0", nowAt] with
  | .error e => return .error e
  | .ok _ => return .ok ()

private def loadMachineRows (db : SqliteDb) : IO (Except String (Array (Array String))) :=
  execParamQuery db
    "SELECT id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id FROM managed_machines ORDER BY id ASC;" #[]

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

def loadManagedFleet (st : ManagedComputeStore) (enabled boatEnabled : Bool)
    (dailyCapCents spentTodayCents maxConcurrent : UInt64) : IO (Except String ManagedFleetState) := do
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
  match ← loadMachineRows st.db with
  | .error e => return .error e
  | .ok rows =>
    let mut machines : Array ManagedMachine := #[]
    for i in [1:rows.size] do
      machines := machines.push (machineFromRow rows[i]!)
    return .ok {
      enabled := en, boatEnabled := boatEn, dailyCapCents := capC,
      spentTodayCents := spentC, maxConcurrent := maxConc, machines
    }

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
  if !isKnownProvider provider || plaintext.isEmpty then
    return .error "invalid_provider_secret"
  match ← ensurePrivateDir0700 (managedSecretDir rootDir) with
  | .error e => return .error e
  | .ok () =>
    let .ok key ← loadOrCreateMasterKey rootDir | return .error "master_key_unavailable"
    let .ok nonce ← randBytes 12 | return .error "secret_nonce_rng_failed"
    let aad := s!"orb-core-reserved:{provider}".toUTF8
    match ← aeadSeal .aes256Gcm key nonce aad plaintext.toUTF8 with
    | .error e => return .error e
    | .ok sealed =>
      writeAtomicPrivate0600 (managedSecretPath rootDir provider) (nonce ++ sealed)

def openProviderSecret (rootDir provider : String)
    (callerOnManagedNode : Bool) (operatorBreakGlass : Bool := true) :
    IO (Except String String) := do
  if admitCoreReservedSecret callerOnManagedNode operatorBreakGlass != 257 then
    return .error "core_reserved_secret_rejected"
  if !isKnownProvider provider then
    return .error "invalid_provider_secret"
  let .ok key ← readPrivate0600 (managedMasterKeyPath rootDir)
    | return .error "master_key_unavailable"
  if key.size != 32 then
    return .error "master_key_invalid_length"
  let .ok raw ← readPrivate0600 (managedSecretPath rootDir provider)
    | return .error "sealed_secret_unavailable"
  if raw.size < 28 then
    return .error "sealed_secret_truncated"
  let nonce := raw.extract 0 12
  let sealed := raw.extract 12 raw.size
  let aad := s!"orb-core-reserved:{provider}".toUTF8
  match ← aeadOpen .aes256Gcm key nonce aad sealed with
  | .error e => return .error e
  | .ok pt => return .ok (String.fromUTF8? pt |>.getD "")

private def machineParams (m : ManagedMachine) (slice : VmSliceState) : Array String :=
  #[
    m.id, m.sandboxName, m.provider, m.size, statusOfPhase slice.phaseCode, m.ownerMission,
    s!"{m.ttlMinutes}", s!"{m.spentCents}", if m.cordoned then "1" else "0",
    s!"{slice.nodeBootEpoch}", s!"{slice.deletableAt}", m.ownerKind, m.requestedByMissionId,
    s!"{slice.phaseCode}", s!"{slice.activeComputeEligible}", m.ownerUserId
  ]

private def upsertMachineTx (db : SqliteDb) (m : ManagedMachine) (slice : VmSliceState) :
    IO (Except String Unit) := do
  let sql :=
    "INSERT INTO managed_machines(id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id) " ++
    "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16) " ++
    "ON CONFLICT(id) DO UPDATE SET sandbox_name=excluded.sandbox_name,provider=excluded.provider,size=excluded.size,status=excluded.status,owner_mission=excluded.owner_mission,ttl_minutes=excluded.ttl_minutes,spent_cents=excluded.spent_cents,cordoned=excluded.cordoned,node_boot_epoch=excluded.node_boot_epoch,deletable_at_sec=excluded.deletable_at_sec,owner_kind=excluded.owner_kind,requested_by_mission_id=excluded.requested_by_mission_id,phase_code=excluded.phase_code,active_compute_eligible=excluded.active_compute_eligible,owner_user_id=excluded.owner_user_id;"
  match ← execParamQueryUnlocked db sql (machineParams m slice) with
  | .error e => return .error e
  | .ok _ => return .ok ()

private def selectMachineTx (db : SqliteDb) (machineId : String) :
    IO (Except String (Option (ManagedMachine × VmSliceState))) := do
  match ← execParamQueryUnlocked db
      "SELECT id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id FROM managed_machines WHERE id=?1;"
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

/-- Apply one lifecycle event through `verifyVmLifecycleAdmit` / `stepVmSlice` and persist it in one
    immediate transaction. `resume` and `replace` store the successor boot epoch the reducer returns.
    `destroy` closes the ledger only when the reducer emits `closeCostLedger`. -/
def applyVmLifecycle (st : ManagedComputeStore) (machineId : String) (ev : VmSliceEvent) :
    IO (Except String (VmSliceState × List VmEffect)) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (machine, slice)) =>
      if verifyVmLifecycleAdmit slice.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
           slice.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch slice.deletableAt != 1 then
        return .error "vm_lifecycle_rejected"
      let (next, effs) := stepVmSlice slice ev
      if next == slice && effs.isEmpty then
        return .error "vm_lifecycle_rejected"
      match ← upsertMachineTx st.db machine next with
      | .error e => return .error e
      | .ok () => return .ok (next, effs)

def provisionManagedMachine (st : ManagedComputeStore) (fleet : ManagedFleetState)
    (machine : ManagedMachine) (nowEpoch : UInt64) : IO (Except String ManagedMachine) := do
  if !admitManagedSpawn fleet machine.spentCents machine.ttlMinutes.toUInt32 then
    return .error "managed_spawn_rejected"
  if !isKnownProvider machine.provider || machine.id.isEmpty || machine.nodeBootEpoch == 0 then
    return .error "managed_spawn_invalid"
  let slice : VmSliceState := {
    phaseCode := 0
    activeComputeEligible := 0
    nodeBootEpoch := machine.nodeBootEpoch
    deletableAt := machine.deletableAtSec
  }
  let ev : VmSliceEvent := {
    opCode := VmOp.encode .provision
    ownerLive := 0
    idleElapsed := 0
    presentedBootEpoch := machine.nodeBootEpoch
    nowEpoch := nowEpoch
  }
  let (next, _) := stepVmSlice slice ev
  if next.phaseCode != 1 then
    return .error "vm_provision_rejected"
  withImmediateTx st.db do
    match ← selectMachineTx st.db machine.id with
    | .error e => return .error e
    | .ok (some _) => return .error "managed_machine_exists"
    | .ok none =>
      match ← upsertMachineTx st.db machine next with
      | .error e => return .error e
      | .ok () =>
        let newSpent := fleet.spentTodayCents + machine.spentCents
        let fleetSql :=
          "INSERT INTO managed_fleet_state(singleton_id,enabled,boat_enabled,daily_cap_cents,spent_today_cents,max_concurrent) " ++
          "VALUES(1,?1,?2,?3,?4,?5) ON CONFLICT(singleton_id) DO UPDATE SET " ++
          "enabled=excluded.enabled,boat_enabled=excluded.boat_enabled,daily_cap_cents=excluded.daily_cap_cents," ++
          "spent_today_cents=spent_today_cents+?6,max_concurrent=excluded.max_concurrent;"
        discard <| execParamQueryUnlocked st.db fleetSql #[
          if fleet.enabled then "1" else "0", if fleet.boatEnabled then "1" else "0",
          s!"{fleet.dailyCapCents}", s!"{newSpent}", s!"{fleet.maxConcurrent}", s!"{machine.spentCents}"
        ]
        return .ok { machine with
          status := statusOfPhase next.phaseCode
          nodeBootEpoch := next.nodeBootEpoch
          deletableAtSec := next.deletableAt
        }

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
      if let some b := presentedBootEpoch? then
        if b != vm.nodeBootEpoch then
          return .error "stale_boot_epoch"
      match ← execParamQueryUnlocked st.db
          "SELECT machine_id,node_id,node_token,enroll_token,node_boot_epoch FROM managed_node_tokens WHERE machine_id=?1;"
          #[machineId] with
      | .error e => return .error e
      | .ok rows =>
        if rows.size ≤ 1 then return .error "enrollment_missing"
        let row := rows[1]!
        if cell row 3 != presentedEnrollToken || cellU64 row 4 != vm.nodeBootEpoch || (cell row 3).isEmpty then
          return .error "enrollment_rejected"
        if !(cell row 2).isEmpty then
          return .error "enrollment_rejected"
        let nodeToken ← newUuidV4
        let nodeId := s!"managed-{machineId}"
        match ← execParamQueryUnlocked st.db
            "UPDATE managed_node_tokens SET node_id=?2,node_token=?3,enroll_token='' WHERE machine_id=?1 AND enroll_token=?4 AND node_boot_epoch=?5;"
            #[machineId, nodeId, nodeToken, presentedEnrollToken, s!"{vm.nodeBootEpoch}"] with
        | .error e => return .error e
        | .ok _ => return .ok (nodeId, nodeToken)

def putEnrollmentToken (st : ManagedComputeStore) (machineId enrollToken : String) :
    IO (Except String Unit) := do
  withImmediateTx st.db do
    match ← selectMachineTx st.db machineId with
    | .error e => return .error e
    | .ok none => return .error "managed_machine_missing"
    | .ok (some (_, vm)) =>
      match ← execParamQueryUnlocked st.db
          "INSERT INTO managed_node_tokens(machine_id,node_id,node_token,enroll_token,node_boot_epoch) VALUES(?1,'','',?2,?3) ON CONFLICT(machine_id) DO UPDATE SET enroll_token=excluded.enroll_token,node_token='',node_boot_epoch=excluded.node_boot_epoch;"
          #[machineId, enrollToken, s!"{vm.nodeBootEpoch}"] with
      | .error e => return .error e
      | .ok _ => return .ok ()

def authenticateNodeToken (st : ManagedComputeStore) (machineId nodeToken : String)
    (presentedBootEpoch? : Option UInt64 := none) : IO (Except String UInt64) := do
  match ← execParamQuery st.db
      "SELECT t.node_token,t.node_boot_epoch,m.node_boot_epoch,m.phase_code FROM managed_node_tokens t JOIN managed_machines m ON m.id=t.machine_id WHERE t.machine_id=?1;"
      #[machineId] with
  | .error e => return .error e
  | .ok rows =>
    if rows.size ≤ 1 then return .error "node_unauthorized"
    let row := rows[1]!
    if cell row 0 != nodeToken || (cell row 0).isEmpty then
      return .error "node_unauthorized"
    let tokBoot := cellU64 row 1
    let vmBoot := cellU64 row 2
    let phase := cellU8 row 3
    if phase == 3 || tokBoot != vmBoot then
      return .error "stale_boot_epoch"
    if let some b := presentedBootEpoch? then
      if b != vmBoot then
        return .error "stale_boot_epoch"
    return .ok vmBoot

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

/-- Pure adapter across the six providers (`boat`, `boost`, `hetzner`, `vastai`, `scaleway`, `colab`).
    Never touches SQLite or ledgers; emits only a `ProviderObservation`. -/
def observeProviderPayload (provider machineId : String) (httpStatus : Nat) (payload : JVal) :
    Except String ProviderObservation :=
  if !isKnownProvider provider then
    .error "unknown_provider"
  else if httpStatus == 404 || httpStatus == 410 then
    .ok { provider, machineId, observedStatus := "destroyed", orphaned := true }
  else
    let rawState :=
      ((payload.fieldStr? "state").orElse (fun _ => payload.fieldStr? "status")).getD ""
        |>.trimAscii.toString.toLower
    let spentCents := (payload.fieldUInt64? "spent_cents").getD 0
    let (normStatus, orphaned) :=
      if rawState == "running" || rawState == "ready" || rawState == "online" || rawState == "connected" then
        ("ready", false)
      else if rawState == "stopped" || rawState == "halted" || rawState == "off" ||
          rawState == "exited" || rawState == "stopped_in_place" || rawState == "disconnected" then
        ("stopped", false)
      else if rawState == "destroyed" || rawState == "deleted" || rawState == "terminated" || rawState == "missing" then
        ("destroyed", true)
      else
        ("provisioning", false)
    .ok { provider, machineId, observedStatus := normStatus, spentCents, orphaned }

/-- Apply one pure observation. Orphans and ledger closure happen only when `stepVmSlice` admits
    `destroy` and emits `closeCostLedger`. -/
def applyProviderObservation (st : ManagedComputeStore) (obs : ProviderObservation)
    (nowEpoch : UInt64) (ownerLive idleElapsed : UInt8) : IO (Except String (List VmEffect)) := do
  if !isKnownProvider obs.provider then
    return .error "unknown_provider"
  match ← execParamQuery st.db
      "SELECT node_boot_epoch FROM managed_machines WHERE id=?1 AND provider=?2;" #[obs.machineId, obs.provider] with
  | .error e => return .error e
  | .ok rows =>
    if rows.size ≤ 1 then return .error "managed_machine_missing"
    let boot := cellU64 rows[1]! 0
    if obs.orphaned then
      match ← applyVmLifecycle st obs.machineId {
        opCode := VmOp.encode .destroy, ownerLive, idleElapsed,
        presentedBootEpoch := boot, nowEpoch
      } with
      | .error e => return .error e
      | .ok (_, effs) => return .ok effs
    else if obs.observedStatus == "stopped" then
      match ← applyVmLifecycle st obs.machineId {
        opCode := VmOp.encode .stop, ownerLive := 0, idleElapsed := 0,
        presentedBootEpoch := boot, nowEpoch
      } with
      | .error e => return .error e
      | .ok (_, effs) => return .ok effs
    else
      match ← execParamQuery st.db
          "UPDATE managed_machines SET spent_cents=?2 WHERE id=?1 AND provider=?3;"
          #[obs.machineId, s!"{obs.spentCents}", obs.provider] with
      | .error e => return .error e
      | .ok _ => return .ok []

private def providerDisplayName (p : String) : String :=
  match p with
  | "boat" => "boat.dev"
  | "boost" => "boost.ci"
  | "hetzner" => "Hetzner"
  | "vastai" => "Vast.ai"
  | "scaleway" => "Scaleway"
  | "colab" => "Google Colab"
  | _ => p

def renderManagedProvidersJson
    (st : ManagedFleetState)
    (isAdmin : Bool := true)
    (userPrefs : Array (String × Bool) := #[])
    (configuredProviders : Array String := #[]) : String :=
  let items := knownProviders.map fun p =>
    let globallyConfigured := configuredProviders.any (· == p) || (p == "boat" && st.boatEnabled)
    let globallyEnabled := st.enabled && (if p == "boat" then st.boatEnabled else globallyConfigured)
    let userEnabled := isUserManagedProviderEnabled userPrefs p
    let effectiveEnabled := globallyEnabled && userEnabled
    let cfgStr := if globallyConfigured then "true" else "false"
    let globStr := if globallyEnabled then "true" else "false"
    let usrStr := if userEnabled then "true" else "false"
    let effStr := if effectiveEnabled then "true" else "false"
    let credFields :=
      if isAdmin && globallyConfigured then
        ",\"credential_source\":\"settings\",\"key_hint\":\"••••\""
      else
        ",\"credential_source\":null,\"key_hint\":null"
    s!"\{\"provider\":{jsonEscape p},\"display_name\":{jsonEscape (providerDisplayName p)},\"configured\":{cfgStr},\"enabled\":{effStr},\"globally_enabled\":{globStr},\"user_enabled\":{usrStr},\"effective_enabled\":{effStr}{credFields},\"supports_snapshots\":true,\"supports_free_stop\":true,\"sizes\":[]}"
  "[" ++ String.intercalate "," items.toList ++ "]"

def renderManagedMachineItemJson (m : ManagedMachine) : String :=
  s!"\{\"id\":{jsonEscape m.id},\"name\":{jsonEscape m.sandboxName},\"sandbox_name\":{jsonEscape m.sandboxName},\"provider\":{jsonEscape m.provider},\"provider_id\":{jsonEscape m.id},\"node_id\":{jsonEscape s!"managed-{m.id}"},\"image\":\"ubuntu-24.04\",\"size\":{jsonEscape m.size},\"cpu\":4,\"ram_gb\":8,\"state\":{jsonEscape m.status},\"owner_mission\":{jsonEscape m.ownerMission},\"owner_mission_id\":{if m.ownerMission.isEmpty then "null" else jsonEscape m.ownerMission},\"owner_kind\":{if m.ownerKind.isEmpty then "\"user\"" else jsonEscape m.ownerKind},\"node_boot_epoch\":{m.nodeBootEpoch},\"deletable_at\":{m.deletableAtSec},\"spent_cents\":{m.spentCents},\"cost_usd\":{formatCentsUsd2 m.spentCents},\"usd_per_hour\":0.10,\"ledger_closed\":{if m.status == "destroyed" then "true" else "false"},\"cordoned\":{if m.cordoned then "true" else "false"}}"

def renderManagedMachinesJson
    (st : ManagedFleetState)
    (callerUserId? : Option String := none)
    (isAdmin : Bool := true)
    (userPrefs : Array (String × Bool) := #[])
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none)
    (configuredProviders : Array String := #[]) : String :=
  match callerUserId? with
  | none =>
    let active := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let enStr := if st.enabled then "true" else "false"
    let boatStr := if st.boatEnabled then "true" else "false"
    let items := st.machines.map fun m =>
      s!"\{\"id\":{jsonEscape m.id},\"sandbox_name\":{jsonEscape m.sandboxName},\"provider\":{jsonEscape m.provider},\"size\":{jsonEscape m.size},\"state\":{jsonEscape m.status},\"owner_mission\":{jsonEscape m.ownerMission},\"node_boot_epoch\":{m.nodeBootEpoch},\"deletable_at\":{m.deletableAtSec},\"spent_cents\":{m.spentCents},\"cordoned\":{if m.cordoned then "true" else "false"}}"
    s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{st.spentTodayCents},\"daily_cap_cents\":{st.dailyCapCents},\"machines\":[{String.intercalate "," items.toList}],\"budget\":{renderManagedBudgetJson st}}"
  | some uid =>
    let visible := st.machines.filter (fun m => m.ownerUserId == uid)
    let active := (visible.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let enStr := if st.enabled then "true" else "false"
    let boatStr := if st.boatEnabled then "true" else "false"
    let items := visible.map renderManagedMachineItemJson
    let budgetJson := renderManagedBudgetJson st (some uid) userSpentTodayCents userDailyCapCents?
    let provsJson := renderManagedProvidersJson st isAdmin userPrefs configuredProviders
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
          let pk := pkRaw.trimAscii.toString.toLower
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
            pv.asNat?.map fun capN =>
              let actP := (liveMachines.filter (fun m => m.provider == pk)).size
              s!"\{\"provider\":{jsonEscape pk},\"active\":{actP},\"max_concurrent\":{capN}}"
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
