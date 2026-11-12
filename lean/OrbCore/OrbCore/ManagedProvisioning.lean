/-
  One provisioning pipeline for every managed-worker entry point. Core reserves
  capacity before provider I/O, owns the stable machine identity, and admits no
  work until the guest makes its first authenticated relay poll.
-/
import OrbCore.Managed
import OrbCore.ManagedProvider

namespace OrbCore.ManagedProvisioning

open OrbCore.Managed OrbCore.Store OrbBin.Json OrbBin.PosixExt

structure BootstrapConfig where
  coreUrl : String
  script : String

structure SpawnResult where
  machine : ManagedMachine
  created : Bool

structure Runtime where
  nowEpoch : IO UInt64 := coreEpochSec
  monotonicMs : IO UInt64 := do return ((← IO.monoNanosNow) / 1000000).toUInt64
  sleepMs : UInt32 → IO Unit := fun ms => do IO.sleep ms

def enrollmentEnv (machine : ManagedMachine) (coreUrl token : String) : String :=
  "SANDBOXED_NODE_DIAL_CORE_URL=" ++ jsonEscape coreUrl ++ "\n" ++
  "SANDBOXED_NODE_MANAGED_ID=" ++ jsonEscape machine.id ++ "\n" ++
  "SANDBOXED_NODE_ENROLL_TOKEN=" ++ jsonEscape token ++ "\n" ++
  "SANDBOXED_NODE_ID=" ++ jsonEscape s!"managed-{machine.id}" ++ "\n" ++
  "SANDBOXED_NODE_WORK_DIR=/var/lib/orb-node/work\n" ++
  "SANDBOXED_NODE_CREDENTIAL_FILE=/var/lib/orb-node/node.cred\n"

private def execFailed (body : JVal) : Bool :=
  let code := (body.fieldInt? "exitCode").orElse (fun _ => body.fieldInt? "exit_code")
    |>.orElse (fun _ => body.fieldInt? "code")
  -- Some provider command replies omit an exit code. They are not readiness
  -- evidence: the pipeline must still observe the authenticated relay poll.
  code.any (· != 0)

private def validateBootstrap (cfg : BootstrapConfig) : Except String Unit := do
  let .ok url := OrbBin.HttpClient.parseUrl cfg.coreUrl
    | throw "managed_public_url_invalid"
  if !url.isHttps || cfg.coreUrl.contains '\n' || cfg.coreUrl.contains '\r' then
    throw "managed_public_https_url_required"
  if cfg.script.trimAscii.toString.isEmpty then throw "managed_bootstrap_script_missing"

private def destroyFailedProvision {α : Type} (mc : ManagedComputeStore) (provider : ManagedProvider.Provider)
    (machine : ManagedMachine) (runtime : Runtime) (reason : String) : IO (Except String α) := do
  match ← provider.destroy machine.effectiveProviderId with
  | .error _ => return .error (reason ++ ":provider_cleanup_pending:" ++ machine.id)
  | .ok () =>
    let now ← runtime.nowEpoch
    match ← applyVmLifecycle mc machine.id {
        opCode := Orb.ManagedNode.VmOp.encode .destroy
        ownerLive := 0
        idleElapsed := 1
        presentedBootEpoch := machine.nodeBootEpoch
        nowEpoch := now
      } with
    | .error _ => return .error (reason ++ ":reservation_cleanup_pending:" ++ machine.id)
    | .ok _ => return .error reason

def bootstrapAndWait (mc : ManagedComputeStore) (provider : ManagedProvider.Provider)
    (machine : ManagedMachine) (cfg : BootstrapConfig) (runtime : Runtime)
    (startedMs : UInt64) (prepared? : Option (String × UInt64 × UInt64) := none) : IO (Except String ManagedMachine) := do
  let elapsed : IO UInt64 := do return (← runtime.monotonicMs) - startedMs
  let deadlineMs := provider.readinessDeadlineSecs * 1000
  -- Guest file/command endpoints are only usable after the provider boots.
  let mut acceptingCommands := false
  while (← elapsed) < deadlineMs do
    match ← provider.get machine.effectiveProviderId with
    | .ok observed =>
      if provider.isReady observed.state then
        acceptingCommands := true
        break
      if provider.isStopped observed.state then return .error "provider_stopped_during_bootstrap"
    | .error e =>
      if e.status == 401 || e.status == 403 || e.status == 404 then
        return .error "provider_bootstrap_unavailable"
    runtime.sleepMs 1000
  if !acceptingCommands || (← elapsed) ≥ deadlineMs then return .error "managed_bootstrap_timeout"
  let token ← match prepared? with
    | some (token, _, _) => pure token
    | none => do
      let token ← newUuidV4
      let .ok () ← putEnrollmentToken mc machine.id token (machine.createdAtSec + provider.readinessDeadlineSecs)
        | return .error "managed_enrollment_token_store_failed"
      pure token
  let readyBoot := prepared?.map (fun p => p.2.1) |>.getD machine.nodeBootEpoch
  let pendingPhase : UInt8 := if prepared?.isSome then 2 else 0
  -- Prepare a private delivery directory before writing any enrollment credential.
  let .ok prepared ← provider.exec machine.effectiveProviderId
      "mkdir -p /home/user/.orb && chmod 700 /home/user/.orb" 15
    | return .error "managed_bootstrap_directory_failed"
  if execFailed prepared then return .error "managed_bootstrap_directory_failed"
  if (← elapsed) ≥ deadlineMs then return .error "managed_bootstrap_timeout"
  let .ok () ← provider.writeFile machine.effectiveProviderId "/home/user/.orb/enroll.env"
      (enrollmentEnv machine cfg.coreUrl token)
    | return .error "managed_enrollment_delivery_failed"
  let .ok () ← provider.writeFile machine.effectiveProviderId "/home/user/.orb/orb-node-provision.sh" cfg.script
    | return .error "managed_bootstrap_script_delivery_failed"
  if (← elapsed) ≥ deadlineMs then return .error "managed_bootstrap_timeout"
  let command := "chmod 600 /home/user/.orb/enroll.env && sudo bash /home/user/.orb/orb-node-provision.sh " ++
    shellSingleQuote cfg.coreUrl ++ " " ++ shellSingleQuote machine.id
  let .ok launched ← provider.exec machine.effectiveProviderId command 90
    | return .error "managed_bootstrap_launch_failed"
  if execFailed launched then return .error "managed_bootstrap_launch_failed"
  while (← elapsed) < deadlineMs do
    let some (live, slice) ← getManagedMachine? mc machine.id
      | return .error "managed_machine_missing"
    if slice.phaseCode == 1 && live.nodeBootEpoch == readyBoot && live.lastPollSec > 0 then return .ok live
    if slice.phaseCode != pendingPhase || live.nodeBootEpoch != machine.nodeBootEpoch then
      return .error "managed_bootstrap_superseded"
    runtime.sleepMs 250
  -- The poll may have committed just before the final timer tick. Its database
  -- deadline is authoritative, so observe it once before beginning cleanup.
  if let some (live, slice) ← getManagedMachine? mc machine.id then
    if slice.phaseCode == 1 && live.nodeBootEpoch == readyBoot && live.lastPollSec > 0 then return .ok live
  return .error "managed_bootstrap_timeout"

/-- Shared create path. A failed provider call cannot manufacture a local ready
    machine. Uncertain creation leaves its reservation/name for reconciliation. -/
def spawnManagedWorker (mc : ManagedComputeStore) (fleet : ManagedFleetState)
    (machine : ManagedMachine) (provider : ManagedProvider.Provider)
    (spec : ManagedProvider.SpawnSpec) (cfg : BootstrapConfig)
    (runtime : Runtime := {}) (userAdmission? : Option ManagedUserAdmission := none) : IO (Except String SpawnResult) := do
  let .ok () := validateBootstrap cfg | return .error "managed_bootstrap_configuration_invalid"
  if provider.name != machine.provider || spec.name != machine.sandboxName || spec.idempotencyKey.isEmpty ||
      spec.size != machine.size || spec.ttlSeconds != machine.ttlMinutes * 60 then
    return .error "managed_spawn_invalid"
  if let some prior ← getManagedMachineByRequestKey? mc provider.name spec.idempotencyKey then
    if prior.ownerUserId != machine.ownerUserId || prior.ownerMission != machine.ownerMission ||
        prior.size != machine.size || prior.ttlMinutes != machine.ttlMinutes || prior.image != spec.fromSnapshot then
      return .error "managed_idempotency_conflict"
    if prior.status == "ready" && prior.lastPollSec > 0 then return .ok { machine := prior, created := false }
    return .error ("managed_spawn_existing_" ++ prior.status ++ ":" ++ prior.id)
  let .ok quote := provider.quoteCents machine.size machine.ttlMinutes
    | return .error "managed_spawn_quote_invalid"
  let now ← runtime.nowEpoch
  let .ok reserved ← provisionManagedMachine mc fleet {
      machine with requestKey := spec.idempotencyKey, image := spec.fromSnapshot, spentCents := quote
    } now userAdmission?
    | return .error "managed_spawn_rejected"
  let started ← runtime.monotonicMs
  let created ← match ← provider.spawn spec with
    | .ok m => pure m
    | .error e =>
      -- Definitive refusal can close the reservation; transport/5xx/malformed
      -- responses are uncertain and must be reconciled using its stable name.
      if e.status == 400 || e.status == 401 || e.status == 403 || e.status == 422 then
        discard <| applyVmLifecycle mc reserved.id {
          opCode := Orb.ManagedNode.VmOp.encode .destroy, ownerLive := 0, idleElapsed := 1,
          presentedBootEpoch := reserved.nodeBootEpoch, nowEpoch := (← runtime.nowEpoch)
        }
      return .error (e.code ++ ":" ++ reserved.id)
  let live := { reserved with providerId := created.providerId }
  if let .error _ ← bindManagedProviderId mc reserved.id created.providerId reserved.nodeBootEpoch then
    -- A provider ID may already belong to another request (e.g. a provider
    -- idempotency replay). Never destroy a guest whose ownership was not bound.
    return .error ("managed_provider_binding_uncertain:" ++ reserved.id)
  match ← bootstrapAndWait mc provider live cfg runtime started with
  | .ok ready => return .ok { machine := ready, created := true }
  | .error reason => return ← destroyFailedProvision mc provider live runtime reason

/-- Resume retains the Core ID and the archived source, rents a successor via
    the provider interface, and commits the new boot only on its real relay poll. -/
def resumeManagedWorker (mc : ManagedComputeStore) (fleet : ManagedFleetState)
    (machineId requestKey : String) (ttl : UInt64) (provider : ManagedProvider.Provider)
    (cfg : BootstrapConfig) (runtime : Runtime := {})
    (userAdmission? : Option ManagedUserAdmission := none) : IO (Except String ManagedMachine) := do
  let .ok () := validateBootstrap cfg | return .error "managed_bootstrap_configuration_invalid"
  let some (m, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
  if m.provider != provider.name then return .error "managed_provider_mismatch"
  let .ok cost := provider.quoteCents m.size ttl | return .error "managed_resume_quote_invalid"
  let now ← runtime.nowEpoch
  let started ← runtime.monotonicMs
  let enrollment ← newUuidV4
  let prepared ← prepareManagedResume mc fleet machineId requestKey enrollment ttl cost now
    (now + provider.readinessDeadlineSecs) userAdmission?
  let (intent, fresh) ← match prepared with
    | .error e => return .error e
    | .ok value => pure value
  if !fresh then
    if intent.state == "completed" then
      let some (current, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
      return .ok current
    return .error ("managed_resume_" ++ intent.state ++ ":" ++ requestKey)
  let spec : ManagedProvider.SpawnSpec := {
    name := m.sandboxName, size := m.size, ttlSeconds := ttl * 60, idempotencyKey := requestKey
  }
  let child ← match ← provider.resume intent.oldProviderId spec with
    | .ok value => pure value
    | .error e =>
      if #[400, 401, 403, 404, 422].contains e.status then discard <| abortManagedResume mc intent.id
      return .error (e.code ++ ":" ++ requestKey)
  if child.providerId == intent.oldProviderId then
    return .error ("managed_resume_identity_uncertain:" ++ requestKey)
  let .ok () ← bindManagedResumeProvider mc intent.id child.providerId
    | return .error ("managed_resume_binding_uncertain:" ++ requestKey)
  let some (bound, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
  match ← bootstrapAndWait mc provider bound cfg runtime started
      (some (enrollment, intent.expectedBoot, intent.deadlineSec)) with
  | .ok ready => return .ok ready
  | .error reason =>
    -- Fence readiness before provider deletion; a valid just-in-time poll wins
    -- atomically and is never destroyed by the timeout cleanup path.
    match ← fenceManagedResumeCleanup mc intent.id with
    | .error "managed_resume_already_ready" =>
      let some (ready, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
      return .ok ready
    | .error _ => return .error (reason ++ ":resume_cleanup_pending:" ++ requestKey)
    | .ok fenced =>
      if fenced.newProviderId.isEmpty || fenced.newProviderId == fenced.oldProviderId then
        return .error (reason ++ ":resume_identity_uncertain:" ++ requestKey)
      let .ok () ← provider.destroy fenced.newProviderId
        | return .error (reason ++ ":provider_cleanup_pending:" ++ requestKey)
      let .ok () ← abortManagedResume mc intent.id
        | return .error (reason ++ ":resume_rollback_pending:" ++ requestKey)
      return .error reason

end OrbCore.ManagedProvisioning
