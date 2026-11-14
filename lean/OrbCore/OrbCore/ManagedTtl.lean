import OrbCore.Managed
import OrbCore.ManagedProvider
import OrbCore.Store
import OrbCore.LegacyHydrate

namespace OrbCore.ManagedTtl

open OrbCore.Managed OrbCore.ManagedProvider OrbCore.Store OrbCore.LegacyHydrate OrbBin.Json

abbrev Resolver := String → IO (Except String Provider)

def extensionMinutes (args : JVal) : Except String UInt64 := do
  match (args.field? "ttl_minutes").orElse (fun _ => args.field? "minutes") with
  | none | some .null => return 60
  | some (.num raw) =>
    if raw.length > 3 then throw "managed_extension_invalid"
    let some n := raw.toNat? | throw "managed_extension_invalid"
    if n < 5 || n > 720 then throw "managed_extension_invalid"
    return n.toUInt64
  | _ => throw "managed_extension_invalid"

/-- A pending request is retried against its fixed absolute target. Never add the
    duration again, or claim local success when the provider did not acknowledge. -/
def applyExtension (mc : ManagedComputeStore) (provider : Provider)
    (intent : ManagedExtensionIntent) (nowEpoch : UInt64) : IO (Except String Unit) := do
  if intent.state == "completed" then return .ok ()
  if intent.state != "pending" then return .error "managed_extension_failed"
  if nowEpoch ≥ intent.newExpiry then
    discard <| finishManagedExtension mc intent.id false
    return .error "managed_extension_target_expired"
  match ← provider.extend intent.providerId (intent.newExpiry - nowEpoch) with
  | .ok () => finishManagedExtension mc intent.id true
  | .error e =>
    -- lean.ci answers 409 for a VM that can no longer be extended: final there.
    if #[400,401,403,404,405,422].contains e.status || (provider.name == "leanci" && e.status == 409) then
      discard <| finishManagedExtension mc intent.id false true
    return .error (if e.status == 0 || e.status ≥ 500 then "managed_extension_outcome_uncertain" else "managed_provider_extension_failed")

def extendWorker (mc : ManagedComputeStore) (fleet : ManagedFleetState) (provider : Provider)
    (machineId key : String) (minutes nowEpoch : UInt64)
    (budget? : Option ManagedUserAdmission := none) : IO (Except String ManagedMachine) := do
  let quote := fun size ttl => (provider.quoteCents size ttl).mapError (fun e => e.code)
  let prepared ← prepareManagedExtension mc fleet machineId key minutes nowEpoch quote budget?
  let intent ← match prepared with | .ok value => pure value | .error e => return .error e
  if provider.name.isEmpty then return .error "managed_provider_mismatch"
  let applied ← applyExtension mc provider intent nowEpoch
  if let .error e := applied then return .error e
  let some (updated, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
  return .ok updated

private def safeState (state : String) : String :=
  if #["ready","running","idle","busy","starting","provisioning","archived","archiving","stopped","deleted","destroyed","error","failed","reaped","offline"].contains state
    then state else "unknown"

/-- Read-only operator probe: Core's row beside the provider's own view. It never
    mutates Core state or the provider, and prints no credential or upstream body.
    Accepts a full id, `managed-<id>`, or a unique id prefix. -/
def inspectMachine (mc : ManagedComputeStore) (resolve : Resolver) (rawId : String)
    (nowEpoch : UInt64) : IO JVal := do
  let trimmed := rawId.trimAscii.toString
  let wanted := if trimmed.startsWith "managed-" then (trimmed.drop 8).toString else trimmed
  let fail (reason : String) : JVal := .obj #[("query", .str rawId), ("error", .str reason)]
  if wanted.isEmpty || !wanted.toList.all (fun c => c.isAlphanum || c == '-') then return fail "invalid_machine_id"
  let .ok rows ← execParamQuery mc.db
      "SELECT id FROM managed_machines WHERE id=?1 OR substr(id,1,length(?1))=?1 ORDER BY id LIMIT 3;" #[wanted]
    | return fail "managed_store_read_failed"
  if rows.size < 2 then return fail "managed_machine_not_found"
  if rows.size > 2 && cell rows[1]! 0 != wanted then return fail "ambiguous_machine_id_prefix"
  let some (m, _) ← getManagedMachine? mc (cell rows[1]! 0) | return fail "managed_machine_not_found"
  let base : Array (String × JVal) := #[
    ("id", .str m.id), ("sandbox_name", .str m.sandboxName), ("provider", .str m.provider),
    ("size", .str m.size), ("owner_mission", .str m.ownerMission), ("core_state", .str m.status),
    ("core_provider_id", .str m.providerId), ("node_boot_epoch", JVal.uint64 m.nodeBootEpoch),
    ("expires_at_sec", JVal.uint64 m.expiresAtSec), ("last_poll_sec", JVal.uint64 m.lastPollSec),
    ("expired", .bool (m.expiresAtSec != 0 && nowEpoch ≥ m.expiresAtSec)),
    ("core_spent_cents", JVal.uint64 m.spentCents)]
  let provider ← match ← resolve m.provider with
    | .ok p => pure p
    | .error e => return .obj (base.push ("provider_lookup", .str e))
  -- Prefer the recorded provider id; otherwise match the complete inventory by exact name.
  let observed ← if !m.providerId.isEmpty then
      match ← provider.get m.providerId with
      | .ok remote => pure (Except.ok (some remote))
      | .error e => if e.status == 404 || e.status == 410 then pure (.ok none) else pure (.error s!"{e.code}:{e.status}")
    else
      match ← provider.list with
      | .error e => pure (.error s!"{e.code}:{e.status}")
      | .ok inventory =>
        let hits := inventory.filter (fun r => r.name == m.sandboxName)
        if hits.size > 1 then pure (.error "ambiguous_provider_name") else pure (.ok hits[0]?)
  match observed with
  | .error e => return .obj (base.push ("provider_lookup", .str e))
  | .ok none =>
    return .obj (base ++ #[("provider_lookup", .str "ok"), ("provider_exists", .bool false),
      ("provider_state", .str "absent"), ("provider_billable", .bool false)])
  | .ok (some remote) =>
    let state := safeState remote.state
    let usage ← match ← provider.usageCents remote.providerId with
      | .ok (some cents) => pure (JVal.uint64 cents)
      | _ => pure .null
    return .obj (base ++ #[("provider_lookup", .str "ok"), ("provider_exists", .bool true),
      ("provider_id", .str remote.providerId), ("provider_state", .str state),
      ("provider_billable", .bool (!provider.isStopped remote.state)),
      ("provider_usage_cents", usage)])

/-- Minutes before expiry at which the owning mission is warned, most urgent first. -/
def warningMinutes : Array UInt64 := #[5, 20]

/-- The warning due now, if any: the most urgent threshold the machine has
    crossed. The 20-minute warning is skipped for a machine whose whole lifetime
    is shorter, so a 15-minute VM is not "warned" at birth; the 5-minute one
    always applies. -/
def warningDue (m : ManagedMachine) (nowEpoch : UInt64) : Option UInt64 :=
  if m.status == "destroyed" || m.expiresAtSec == 0 || nowEpoch ≥ m.expiresAtSec then none else
  warningMinutes.find? fun minutes =>
    nowEpoch + minutes * 60 ≥ m.expiresAtSec &&
      (minutes == 5 || m.createdAtSec == 0 || m.createdAtSec + minutes * 60 + 60 ≤ m.expiresAtSec)

private def eventOnce (store : CoreStore) (m : ManagedMachine) (kind message : String)
    (nowEpoch : UInt64) (providerState : String := "unknown") (usageCents? : Option UInt64 := none)
    (stage : String := "") : IO (Except String Unit) := do
  if m.ownerMission.isEmpty then return .ok ()
  let some owner ← getMission? store m.ownerMission | return .ok ()
  if !m.ownerUserId.isEmpty && owner.ownerUserId != m.ownerUserId then return .error "managed_owner_mismatch"
  -- The expiry is part of the key, so an extension re-arms both warnings.
  let key := s!"managed-ttl:{m.id}:{m.nodeBootEpoch}:{m.expiresAtSec}:{kind}{if stage.isEmpty then "" else ":" ++ stage}"
  let .ok rows ← execParamQuery store.missionsDb
      "SELECT 1 FROM mission_events WHERE mission_id=?1 AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.id') ELSE NULL END=?2 LIMIT 1;"
      #[m.ownerMission,key] | return .error "managed_expiry_event_read_failed"
  if rows.size > 1 then return .ok ()
  let payload := renderCompact (.obj #[
    ("id",.str key), ("code",.str kind), ("message",.str message), ("content",.str message),
    ("machine_id",.str m.id), ("node_id",.str s!"managed-{m.id}"),
    ("expires_at_sec",JVal.uint64 m.expiresAtSec), ("provider_state",.str providerState),
    ("minutes_before", match stage.toNat? with | some n => JVal.nat n | none => .null),
    ("spend_cents",JVal.uint64 (usageCents?.getD m.spentCents)),
    ("spend_source",.str (if usageCents?.isSome then "provider_usage" else "lease_reservation_estimate"))])
  match ← appendMissionEvent store m.ownerMission (if kind == "managed_machine_expired" then "error" else "system")
      payload (formatEpochIso8601Utc nowEpoch) with
  | .ok _ => return .ok ()
  | .error e => return .error e

/-- TTL is an explicit hard boundary, including busy guests. Provider errors keep
    cleanup pending; an expiry never becomes successful just because polls stop.
    Already nonbilling archived disks are retained rather than deleting recoverable work. -/
def tick (mc : ManagedComputeStore) (store : CoreStore) (defaults : ManagedFleetState)
    (resolve : Resolver) (nowEpoch : UInt64) : IO (Except String JVal) := do
  let .ok extensions ← pendingManagedExtensions mc | return .error "managed_extension_read_failed"
  for intent in extensions do
    if let some (m, _) ← getManagedMachine? mc intent.machineId then
      if let .ok provider ← resolve m.provider then discard <| applyExtension mc provider intent nowEpoch
  let .ok () ← assignMissingDeadlines mc nowEpoch | return .error "managed_deadline_repair_failed"
  let .ok fleet ← loadManagedFleet mc defaults.enabled defaults.boatEnabled defaults.dailyCapCents
      defaults.spentTodayCents defaults.maxConcurrent | return .error "managed_fleet_read_failed"
  let servicePrefix := sandboxNamePrefixFor (← IO.appPath).toString
  let mut reaped : Array JVal := #[]
  let mut pending : Array JVal := #[]
  for m in fleet.machines do
    if m.expiresAtSec == 0 then continue
    if let some minutes := warningDue m nowEpoch then
      discard <| eventOnce store m "managed_machine_expiring"
        (s!"Managed VM {m.sandboxName} (managed-{m.id}) expires in at most {minutes} minutes, at " ++
         s!"{formatEpochIso8601Utc m.expiresAtSec}. Busy VMs are not auto-extended: " ++
         -- Only advise a call the machine's provider declares.
         (if (OrbCore.ManagedProvider.declaration? m.provider).any (!·.supportsExtend)
          then "call extend_managed_machine if this provider supports it now (supports_extend in list_managed_machines), or bring results back with harvest_managed_file and push work before the deadline."
          else "call extend_managed_machine to keep it, or bring results back with harvest_managed_file and push work before the deadline."))
        nowEpoch "unknown" none (toString minutes)
    if nowEpoch < m.expiresAtSec then continue
    -- Retry an owner notification after a crash even if cleanup already completed.
    let .ok prior ← execParamQuery mc.db
        "SELECT observed_state,state FROM managed_expirations WHERE machine_id=?1 AND boot_epoch=?2;" #[m.id,s!"{m.nodeBootEpoch}"]
      | continue
    if prior.size > 1 && cell prior[1]! 1 == "completed" then
      -- Retry the closing notice after a crash; `eventOnce` deduplicates.
      discard <| eventOnce store m "managed_machine_expiry_cleaned"
        s!"Expired VM {m.sandboxName}: provider cleanup was verified and its compute lease is closed." nowEpoch (cell prior[1]! 0)
      continue
    if m.status == "destroyed" then continue
    let .ok claimed ← claimManagedExpiry mc m.id nowEpoch | continue
    -- Only a machine that was still serving work loses something at expiry; a
    -- machine stopped earlier gets the quieter cleanup notice alone.
    if m.status == "ready" || m.status == "provisioning" then
      discard <| eventOnce store claimed "managed_machine_expired"
        s!"Managed VM {m.sandboxName} reached its TTL. Running work can no longer continue on this lease; provider cleanup is being verified." nowEpoch
    let .ok provider ← resolve claimed.provider | do pending := pending.push (.str m.id); continue
    if claimed.providerId.isEmpty then
      -- Never bound to a provider id: look for it by exact name in the complete
      -- inventory. Found once, bind it and finish next tick; absent, close locally.
      let .ok inventory ← provider.list | do pending := pending.push (.str m.id); continue
      let hits := inventory.filter (fun r => r.name == claimed.sandboxName || r.name == servicePrefix ++ claimed.id)
      if inventory.any (·.name.isEmpty) || hits.size > 1 then
        pending := pending.push (.str m.id)
        continue
      if let some remote := hits[0]? then
        discard <| backfillManagedProviderIdentity mc m.id claimed.provider remote.providerId
        discard <| execParamQuery mc.db
          "UPDATE managed_expirations SET provider_id=?3 WHERE machine_id=?1 AND boot_epoch=?2 AND provider_id='';"
          #[m.id, s!"{claimed.nodeBootEpoch}", remote.providerId]
        pending := pending.push (.str m.id)
        continue
      let some (_, vm) ← getManagedMachine? mc m.id | continue
      if vm.phaseCode != 2 then
        let .ok _ ← applyVmLifecycle mc m.id {
          opCode := Orb.ManagedNode.VmOp.encode .destroy, ownerLive := 0, idleElapsed := 1,
          presentedBootEpoch := claimed.nodeBootEpoch, nowEpoch
        } (some "") | do pending := pending.push (.str m.id); continue
      let .ok () ← recordManagedExpiry mc claimed "absent" true | do pending := pending.push (.str m.id); continue
      discard <| eventOnce store claimed "managed_machine_expiry_cleaned"
        s!"Expired VM {m.sandboxName} has no sandbox at the provider; its lease is closed." nowEpoch "absent"
      reaped := reaped.push (.obj #[("id",.str m.id),("provider_state",.str "absent"),("was_billable",.bool false)])
      continue
    let observed ← provider.get claimed.providerId
    let state ← match observed with
      | .ok remote =>
        if remote.providerId != claimed.providerId then do pending := pending.push (.str m.id); continue
        pure (safeState remote.state)
      | .error e =>
        if e.status == 404 || (claimed.provider != "boat" && e.status == 410) then pure "deleted"
        else do pending := pending.push (.str m.id); continue
    let usage ← match ← provider.usageCents claimed.providerId with
      | .ok amount => pure amount
      | .error _ => pure none
    discard <| recordManagedExpiry mc claimed state false usage
    let confirmedMissing := match observed with
      | .error e => e.status == 404 || (claimed.provider != "boat" && e.status == 410)
      | .ok _ => false
    if (claimed.provider == "boat" && !confirmedMissing && (state == "deleted" || state == "destroyed")) ||
        (!provider.isStopped state && state != "deleted" && state != "destroyed") then
      if !(← provider.destroy claimed.providerId).isOk then
        pending := pending.push (.str m.id)
        continue
    -- Preserve an already archived, nonbilling disk for recovery. A billable
    -- expired guest must be destroyed before the local lifecycle closes.
    if provider.isStopped state && state != "deleted" && state != "destroyed" then
      let some (_, vm) ← getManagedMachine? mc m.id | continue
      if vm.phaseCode == 1 then
        let .ok _ ← applyVmLifecycle mc m.id {
          opCode := Orb.ManagedNode.VmOp.encode .stop, ownerLive := 0, idleElapsed := 1,
          presentedBootEpoch := claimed.nodeBootEpoch, nowEpoch
        } (some claimed.providerId) | do pending := pending.push (.str m.id); continue
      else if vm.phaseCode == 0 then
        let .ok observation := observeProviderPayload claimed.provider m.id 200 (.obj #[("state", .str "stopped")])
          | do pending := pending.push (.str m.id); continue
        let .ok _ ← applyProviderObservation mc { observation with
            expectedProviderId? := some claimed.providerId, expectedBootEpoch? := some claimed.nodeBootEpoch
          } nowEpoch 0 1 | do pending := pending.push (.str m.id); continue
    else
      let .ok _ ← applyVmLifecycle mc m.id {
        opCode := Orb.ManagedNode.VmOp.encode .destroy, ownerLive := 0, idleElapsed := 1,
        presentedBootEpoch := claimed.nodeBootEpoch, nowEpoch
      } (some claimed.providerId) | do pending := pending.push (.str m.id); continue
    let .ok () ← recordManagedExpiry mc claimed state true usage | do pending := pending.push (.str m.id); continue
    discard <| eventOnce store claimed "managed_machine_expiry_cleaned"
      (if provider.isStopped state && state != "deleted" && state != "destroyed" then
        s!"Expired VM {m.sandboxName} was already stopped at the provider. Its nonbilling archived disk was retained for recovery."
       else s!"Expired VM {m.sandboxName} was verified deleted/stopped at the provider; its compute lease is closed.") nowEpoch state usage
    reaped := reaped.push (.obj #[("id",.str m.id),("provider_state",.str state),
      ("was_billable",.bool (!provider.isStopped state && state != "deleted" && state != "destroyed"))])
  return .ok (.obj #[("reaped",.arr reaped),("pending",.arr pending)])

end OrbCore.ManagedTtl
