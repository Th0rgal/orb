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

/-- Render `/api/managed-machines/spend` & budget summary JSON. -/
def renderManagedBudgetJson (st : ManagedFleetState) : String :=
  let active := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
  let enStr := if st.enabled then "true" else "false"
  let boatStr := if st.boatEnabled then "true" else "false"
  s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{st.spentTodayCents},\"daily_cap_cents\":{st.dailyCapCents}}"

/-- Map systemd unit alias (`sandboxed-sh`, `orb-core`, `sandboxed-node`, `orb-node`, `orb-privd`) to
    allowlisted `unitCode` (`1..3`) and validate via `verifyDeployUnitName` (`OrbCore.Spec`). -/
def validateDeployServiceUnit (rawUnit : String) : Except String String :=
  let trimmed := rawUnit.trimAscii.toString
  let hasTraversal : UInt8 :=
    if trimmed.contains '/' || trimmed.contains '\\' || (trimmed.splitOn "..").length > 1 then 1 else 0
  let leaf := ((trimmed.splitOn "/").getLast?).getD trimmed
  let canonical := if leaf.endsWith ".service" then (leaf.dropEnd 8).toString else leaf
  let (unitCode, systemdUnit) : UInt8 × String :=
    if canonical == "sandboxed-sh" || canonical == "orb-core" then (1, "sandboxed-sh.service")
    else if canonical == "sandboxed-node" || canonical == "orb-node" then (2, "sandboxed-node.service")
    else if canonical == "orb-privd" then (3, "orb-privd.service")
    else (0, "")
  if verifyDeployUnitName unitCode hasTraversal trimmed.utf8ByteSize.toUInt32 != 1 then
    .error s!"forbidden or invalid deploy unit `{rawUnit}`"
  else
    .ok systemdUnit

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
  "phase_code INTEGER NOT NULL,active_compute_eligible INTEGER NOT NULL);" ++
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
  "daily_cap_cents INTEGER NOT NULL,spent_today_cents INTEGER NOT NULL,max_concurrent INTEGER NOT NULL);"

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
  }

private def vmSliceOf (row : Array String) : VmSliceState :=
  {
    phaseCode := cellU8 row 13
    activeComputeEligible := cellU8 row 14
    nodeBootEpoch := cellU64 row 9
    deletableAt := cellU64 row 10
  }

def openManagedComputeStore (path : String) : IO (Except String ManagedComputeStore) := do
  match ← openSqliteDb path managedComputeDdl #[] false with
  | .error e => return .error e
  | .ok db => return .ok { db := db }

def closeManagedComputeStore (st : ManagedComputeStore) : IO Unit :=
  st.db.mu.atomically (sqliteCloseRaw st.db.handle)

private def loadMachineRows (db : SqliteDb) : IO (Except String (Array (Array String))) :=
  execParamQuery db
    "SELECT id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible FROM managed_machines ORDER BY id ASC;" #[]

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
    s!"{slice.phaseCode}", s!"{slice.activeComputeEligible}"
  ]

private def upsertMachineTx (db : SqliteDb) (m : ManagedMachine) (slice : VmSliceState) :
    IO (Except String Unit) := do
  let sql :=
    "INSERT INTO managed_machines(id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible) " ++
    "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15) " ++
    "ON CONFLICT(id) DO UPDATE SET sandbox_name=excluded.sandbox_name,provider=excluded.provider,size=excluded.size,status=excluded.status,owner_mission=excluded.owner_mission,ttl_minutes=excluded.ttl_minutes,spent_cents=excluded.spent_cents,cordoned=excluded.cordoned,node_boot_epoch=excluded.node_boot_epoch,deletable_at_sec=excluded.deletable_at_sec,owner_kind=excluded.owner_kind,requested_by_mission_id=excluded.requested_by_mission_id,phase_code=excluded.phase_code,active_compute_eligible=excluded.active_compute_eligible;"
  match ← execParamQueryUnlocked db sql (machineParams m slice) with
  | .error e => return .error e
  | .ok _ => return .ok ()

private def selectMachineTx (db : SqliteDb) (machineId : String) :
    IO (Except String (Option (ManagedMachine × VmSliceState))) := do
  match ← execParamQueryUnlocked db
      "SELECT id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible FROM managed_machines WHERE id=?1;"
      #[machineId] with
  | .error e => return .error e
  | .ok rows =>
    if rows.size ≤ 1 then return .ok none
    else return .ok (some (machineFromRow rows[1]!, vmSliceOf rows[1]!))

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

def renderManagedMachinesJson (st : ManagedFleetState) : String :=
  let active := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
  let enStr := if st.enabled then "true" else "false"
  let boatStr := if st.boatEnabled then "true" else "false"
  let items := st.machines.map fun m =>
    s!"\{\"id\":{jsonEscape m.id},\"sandbox_name\":{jsonEscape m.sandboxName},\"provider\":{jsonEscape m.provider},\"size\":{jsonEscape m.size},\"state\":{jsonEscape m.status},\"owner_mission\":{jsonEscape m.ownerMission},\"node_boot_epoch\":{m.nodeBootEpoch},\"deletable_at\":{m.deletableAtSec},\"spent_cents\":{m.spentCents},\"cordoned\":{if m.cordoned then "true" else "false"}}"
  s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{st.spentTodayCents},\"daily_cap_cents\":{st.dailyCapCents},\"machines\":[{String.intercalate "," items.toList}],\"budget\":{renderManagedBudgetJson st}}"

def renderRemoteNodesJson (st : ManagedFleetState) : String :=
  let nodes := st.machines.filterMap fun m =>
    if m.status == "destroyed" then none
    else some s!"\{\"id\":{jsonEscape s!"managed-{m.id}"},\"machine_id\":{jsonEscape m.id},\"provider\":{jsonEscape m.provider},\"status\":{jsonEscape m.status},\"node_boot_epoch\":{m.nodeBootEpoch}}"
  s!"\{\"nodes\":[{String.intercalate "," nodes.toList}],\"managed_compute\":{renderManagedBudgetJson st}}"

def renderRelayPollJson (cmd : ManagedRelayCommand) : String :=
  s!"[\{\"id\":{jsonEscape cmd.commandId},\"lease_id\":{cmd.heldLeaseId},\"lease_deadline\":{cmd.leaseDeadline},\"node_boot_epoch\":{cmd.nodeBootEpoch},\"payload\":{cmd.payloadJson}}]"

end OrbCore.Managed
