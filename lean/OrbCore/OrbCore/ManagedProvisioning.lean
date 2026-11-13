/-
  One provisioning pipeline for every managed-worker entry point. Core reserves
  capacity before provider I/O, owns the stable machine identity, and admits no
  work until the guest makes its first authenticated relay poll.
-/
import OrbCore.Managed
import OrbCore.ManagedProvider
import OrbCore.ManagedProviderSettings

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

/-- Text a provider's exec reply carries, whichever field names it uses. -/
def guestOutput (reply : JVal) : String :=
  let decoded (field : String) : String :=
    ((reply.fieldStr? field).bind OrbBin.PosixExt.base64Decode? |>.bind String.fromUTF8?).getD ""
  String.intercalate "\n" (#[decoded "stdout_b64", decoded "stderr_b64", (reply.fieldStr? "output").getD "",
    (reply.fieldStr? "stdout").getD "", (reply.fieldStr? "stderr").getD ""].filter (!·.isEmpty)).toList

/-- Guest text for Core's log: the enrolment token removed, control characters
    dropped, bounded, one prefixed line per guest line so it cannot forge others. -/
def guestLogLines (machineId token text : String) : Array String :=
  let redacted := if token.isEmpty then text else text.replace token "[enrolment-token]"
  let clean := String.ofList ((redacted.toList.filter (fun c => c == '\n' || (c.toNat ≥ 32 && c.toNat < 127))).take 4000)
  ((clean.splitOn "\n").filter (!·.trimAscii.toString.isEmpty)).toArray.map
    (fun line => s!"[managed-bootstrap] machine={machineId} guest: {line}")

/-- CPU count, memory and root disk of a guest, on one line. Read-only. -/
def guestFactsCommand : String :=
  "echo \"cpus=$(nproc) memory_mib=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) " ++
  "root_disk_gb=$(df -BG --output=size / 2>/dev/null | tail -n 1 | tr -dc 0-9) " ++
  "root_free_gb=$(df -BG --output=avail / 2>/dev/null | tail -n 1 | tr -dc 0-9) " ++
  "workspace_disk_gb=$(df -BG --output=size /workspace 2>/dev/null | tail -n 1 | tr -dc 0-9) " ++
  "gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1)\""

/-- What to ask a guest whose node never reached Core. Read-only. -/
def guestDiagnosticCommand (coreUrl : String) : String :=
  "echo \"pid1=$(cat /proc/1/comm 2>/dev/null) arch=$(uname -m)\"; " ++
  "ls -ld /opt /opt/orb /opt/orb/bin /opt/orb/bin/sandboxed-node 2>&1; " ++
  "echo \"mount=$(findmnt -T /opt/orb/bin -no TARGET,OPTIONS 2>&1 | head -n 1)\"; " ++
  "systemctl cat orb-node.service 2>/dev/null | grep -E '^(User|ExecStart)=' ; " ++
  "echo \"systemd=$([ -d /run/systemd/system ] && echo yes || echo no)\"; " ++
  "echo \"unit=$(systemctl is-active orb-node.service 2>&1 | head -n 1)\"; " ++
  "echo \"node_processes=$(pgrep -u orbnode -x sandboxed-node 2>/dev/null | wc -l)\"; " ++
  "echo \"core_http=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' " ++ shellSingleQuote (coreUrl ++ "/api/health") ++ " 2>&1 | tail -c 200)\"; " ++
  "(journalctl -u orb-node.service -n 25 --no-pager 2>/dev/null || true) | tail -n 25; " ++
  "tail -n 25 /var/log/orb-node.log 2>/dev/null || true"

def bootstrapAndWait (mc : ManagedComputeStore) (provider : ManagedProvider.Provider)
    (machine : ManagedMachine) (cfg : BootstrapConfig) (runtime : Runtime)
    (startedMs : UInt64) (prepared? : Option (String × UInt64 × UInt64) := none) : IO (Except String ManagedMachine) := do
  let elapsed : IO UInt64 := do return (← runtime.monotonicMs) - startedMs
  let deadlineMs := provider.readinessDeadlineSecs * 1000
  -- One line per stage in Core's log, so a failed bootstrap says where it stopped.
  let stage (message : String) : IO Unit := do
    IO.eprintln s!"[managed-bootstrap] machine={machine.id} provider={provider.name} {message} elapsed_ms={← elapsed}"
  -- Guest file/command endpoints are only usable after the provider boots.
  let mut acceptingCommands := false
  let mut lastSeen := "never observed"
  while (← elapsed) < deadlineMs do
    match ← provider.get machine.effectiveProviderId with
    | .ok observed =>
      lastSeen := s!"state {observed.state}"
      if provider.isReady observed.state then
        acceptingCommands := true
        break
      if provider.isStopped observed.state then
        stage s!"provider stopped the machine ({lastSeen})"
        return .error "provider_stopped_during_bootstrap"
    | .error e =>
      lastSeen := s!"error {e.code} status {e.status}"
      if e.status == 401 || e.status == 403 || e.status == 404 then
        stage s!"provider refused the machine lookup ({lastSeen})"
        return .error "provider_bootstrap_unavailable"
    runtime.sleepMs 1000
  if !acceptingCommands || (← elapsed) ≥ deadlineMs then
    stage s!"provider never reported the machine ready (last: {lastSeen})"
    return .error "managed_bootstrap_timeout_provider_not_ready"
  stage "provider reports the machine ready"
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
    | do stage "guest command call failed (create directory)"; return .error "managed_bootstrap_directory_failed"
  if execFailed prepared then
    stage "guest could not create the delivery directory"
    for line in guestLogLines machine.id token (guestOutput prepared) do IO.eprintln line
    return .error "managed_bootstrap_directory_failed"
  if (← elapsed) ≥ deadlineMs then return .error "managed_bootstrap_timeout_during_delivery"
  let .ok () ← provider.writeFile machine.effectiveProviderId "/home/user/.orb/enroll.env"
      (enrollmentEnv machine cfg.coreUrl token)
    | do stage "enrolment file delivery failed"; return .error "managed_enrollment_delivery_failed"
  let .ok () ← provider.writeFile machine.effectiveProviderId "/home/user/.orb/orb-node-provision.sh" cfg.script
    | do stage "provisioning script delivery failed"; return .error "managed_bootstrap_script_delivery_failed"
  if (← elapsed) ≥ deadlineMs then return .error "managed_bootstrap_timeout_during_delivery"
  stage "enrolment file and provisioning script delivered"
  let command := "chmod 600 /home/user/.orb/enroll.env && sudo bash /home/user/.orb/orb-node-provision.sh " ++
    shellSingleQuote cfg.coreUrl ++ " " ++ shellSingleQuote machine.id ++ " && " ++ guestFactsCommand
  let .ok launched ← provider.exec machine.effectiveProviderId command 90
    | do stage "guest command call failed (provisioning script)"; return .error "managed_bootstrap_launch_failed"
  if execFailed launched then
    stage "provisioning script exited with an error"
    for line in guestLogLines machine.id token (guestOutput launched) do IO.eprintln line
    return .error "managed_bootstrap_launch_failed"
  stage "provisioning script finished; waiting for the node's first relay poll"
  -- The same call reported what the provider actually delivered, so the catalog's
  -- sizes can be checked against every real machine.
  stage s!"guest output for size {machine.size} follows"
  for line in guestLogLines machine.id token (guestOutput launched) do IO.eprintln line
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
  -- The guest is about to be destroyed: record why its node never reached Core.
  stage "the node never polled Core; asking the guest why"
  match ← provider.exec machine.effectiveProviderId (guestDiagnosticCommand cfg.coreUrl) 25 with
  | .ok reply => for line in guestLogLines machine.id token (guestOutput reply) do IO.eprintln line
  | .error e => stage s!"guest diagnostics unavailable ({e.code})"
  return .error "managed_bootstrap_timeout_no_relay_poll"

/-- Availability is advisory and read-only; final toggle/budget/cap checks occur
    again under the reservation transaction. A saturated request rents nothing. -/
def preflightAvailability (mc : ManagedComputeStore) (fleet : ManagedFleetState)
    (provider : ManagedProvider.Provider) (spec : ManagedProvider.SpawnSpec) : IO (Except String Unit) := do
  let .ok enabled ← ManagedProviderSettings.isEnabled mc provider.name
    | return .error "managed_provider_settings_unavailable"
  let permitted := enabled && fleet.enabled && (provider.name != "boat" || fleet.boatEnabled)
  if !permitted then return .error "provider_disabled"
  let .ok observed ← provider.availability spec
    | return .error "managed_provider_availability_unavailable"
  if !Orb.ManagedProviderAvailability.maySpawn permitted observed.status then
    return .error (if observed.status == .saturated then "provider_at_capacity" else "managed_provider_availability_unavailable")
  return .ok ()

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
  if let .error error ← preflightAvailability mc fleet provider spec then return .error error
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

def replayManagedResume (mc : ManagedComputeStore) (machineId requestKey : String) (ttl : UInt64) :
    IO (Except String (Option ManagedMachine)) := do
  let .ok prior ← getManagedResumeIntent? mc requestKey
    | return .error "managed_resume_intent_read_failed"
  let some intent := prior | return .ok none
  if intent.machineId != machineId || intent.newTtl != ttl then return .error "managed_idempotency_conflict"
  if intent.state != "completed" then return .error ("managed_resume_" ++ intent.state ++ ":" ++ requestKey)
  let some (current, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
  return .ok (some current)

/-- Resume retains the Core ID and the archived source, rents a successor via
    the provider interface, and commits the new boot only on its real relay poll. -/
def resumeManagedWorker (mc : ManagedComputeStore) (fleet : ManagedFleetState)
    (machineId requestKey : String) (ttl : UInt64) (provider : ManagedProvider.Provider)
    (cfg : BootstrapConfig) (runtime : Runtime := {})
    (userAdmission? : Option ManagedUserAdmission := none) : IO (Except String ManagedMachine) := do
  match ← replayManagedResume mc machineId requestKey ttl with
  | .error e => return .error e
  | .ok (some current) => return .ok current
  | .ok none => pure ()
  let .ok () := validateBootstrap cfg | return .error "managed_bootstrap_configuration_invalid"
  let some (m, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
  if m.provider != provider.name then return .error "managed_provider_mismatch"
  let .ok cost := provider.quoteCents m.size ttl | return .error "managed_resume_quote_invalid"
  let servicePrefix ← managedSandboxNamePrefix
  let providerName := if m.sandboxName.startsWith servicePrefix then m.sandboxName else servicePrefix ++ m.id
  let spec : ManagedProvider.SpawnSpec := {
    name := providerName, size := m.size, ttlSeconds := ttl * 60, idempotencyKey := requestKey
  }
  let .ok priorIntent ← getManagedResumeIntent? mc requestKey
    | return .error "managed_resume_intent_read_failed"
  if priorIntent.isNone then
    if let .error error ← preflightAvailability mc fleet provider spec then return .error error
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
