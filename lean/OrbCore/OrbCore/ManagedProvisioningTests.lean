import OrbCore.ManagedProvisioning

namespace OrbCore.ManagedProvisioningTests

open OrbCore.Managed OrbCore.ManagedProvider OrbCore.ManagedProvisioning OrbCore.Store OrbBin.Json

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed provisioning: {label}")

/-- Virtual-time full provisioning replay, including token exchange and a first
    authenticated poll. The mock guest never executes scripts or opens a socket. -/
def run (root : String) : IO Unit := do
  let .ok mc ← openManagedComputeStore s!"{root}/provisioning.db"
    | throw (IO.userError "provisioning store open failed")
  try
    let clock ← IO.mkRef (0 : UInt64)
    let requests ← IO.mkRef (#[] : Array Request)
    let shouldPoll ← IO.mkRef true
    let createStatus ← IO.mkRef (201 : Nat)
    let currentId ← IO.mkRef "core-id-1"
    let runtime : Runtime := {
      nowEpoch := do return 1000 + (← clock.get) / 1000
      monotonicMs := clock.get
      sleepMs := fun ms => clock.modify (· + ms.toUInt64)
    }
    let transport : Transport := fun req => do
      requests.modify (·.push req)
      let providerId := "provider-" ++ (← currentId.get)
      let providerPath := "/sandboxes/" ++ providerId
      if req.method == "POST" && req.path == "/sandboxes" then
        return .ok (← createStatus.get, .obj #[("sandbox", .obj #[("id", .str providerId), ("state", .str "idle")])])
      if req.method == "GET" && req.path == providerPath then
        return .ok (200, .obj #[("id", .str providerId), ("state", .str "idle")])
      if req.method == "POST" && req.path == providerPath ++ "/commands" then
        let cmd := ((req.body.getD .null).fieldStr? "command").getD ""
        if (cmd.splitOn "sudo bash").length > 1 && (← shouldPoll.get) then
          let mid ← currentId.get
          let .ok rows ← execParamQuery mc.db "SELECT enroll_token FROM managed_node_tokens WHERE machine_id=?1;" #[mid]
            | return .error { code := "mock_missing_enrollment" }
          let token := if rows.size > 1 then cell rows[1]! 0 else ""
          let .ok (_, nodeToken) ← enrollManagedNode mc mid token (some 1)
            | return .error { code := "mock_enrollment_failed" }
          let .ok boot ← authenticateNodeToken mc mid nodeToken (some 1)
            | return .error { code := "mock_authentication_failed" }
          let .ok () ← recordAuthenticatedManagedPoll mc mid boot (← runtime.nowEpoch)
            | return .error { code := "mock_poll_failed" }
        return .ok (200, .obj #[("exitCode", .nat 0)])
      if req.method == "PUT" && req.path == providerPath ++ "/files" then return .ok (200, .null)
      if req.method == "DELETE" && req.path == providerPath then return .ok (204, .null)
      return .error { code := "mock_unexpected_request" }
    let provider := boat transport runtime.sleepMs
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
    let baseMachine : ManagedMachine := {
      id := "core-id-1", sandboxName := "orb-managed-test-1", provider := "boat",
      size := "small", ttlMinutes := 5, spentCents := 1, nodeBootEpoch := 1,
      deletableAtSec := 1000
    }
    let baseSpec : SpawnSpec := {
      name := baseMachine.sandboxName, size := "small", ttlSeconds := 300,
      idempotencyKey := "request-1", fromSnapshot := "warm-snapshot"
    }
    let cfg : BootstrapConfig := { coreUrl := "https://core.example", script := "#!/bin/bash\nexit 0\n" }
    let .ok spawned ← spawnManagedWorker mc fleet baseMachine provider baseSpec cfg runtime
      | throw (IO.userError "mock provisioning failed")
    let ready := spawned.machine
    check spawned.created "initial request reports a newly created reservation"
    check (ready.id == "core-id-1" && ready.providerId == "provider-core-id-1" &&
      ready.status == "ready" && ready.lastPollSec == 1000) "readiness comes from authenticated guest poll"
    let .ok replayed ← spawnManagedWorker mc fleet { baseMachine with id := "retry-generated-id" }
        provider baseSpec cfg runtime
      | throw (IO.userError "idempotent replay failed")
    check (replayed.machine.id == ready.id && !replayed.created && (← requests.get).size == 6) "retry reuses durable reservation without provider I/O"
    let conflict ← spawnManagedWorker mc fleet baseMachine provider
      { baseSpec with fromSnapshot := "different-snapshot" } cfg runtime
    check (!conflict.isOk && (← requests.get).size == 6) "retry key cannot change snapshot"
    let sent ← requests.get
    check (sent.size == 6 && (sent[0]!.body.getD .null).fieldStr? "from" == some "warm-snapshot") "spawn snapshot then bootstrap"
    let delivered := (sent[3]!.body.getD .null).fieldStr? "content" |>.getD ""
    check ((delivered.splitOn "SANDBOXED_NODE_MANAGED_ID=\"core-id-1\"").length == 2 &&
      (delivered.splitOn "SANDBOXED_NODE_ENROLL_TOKEN=").length == 2) "enrollment delivered as file"
    let commands := sent.filter (fun r => r.path.endsWith "/commands")
    for request in commands do
      let cmd := ((request.body.getD .null).fieldStr? "command").getD ""
      check ((cmd.splitOn "SANDBOXED_NODE_ENROLL_TOKEN").length == 1) "enrollment token is not in command argv"

    -- Timeout runs 360 seconds of virtual time, destroys at provider, then
    -- closes the reservation through the same verified lifecycle reducer.
    clock.set 0
    requests.set #[]
    shouldPoll.set false
    currentId.set "core-id-timeout"
    let timed := { baseMachine with id := "core-id-timeout", sandboxName := "orb-managed-timeout" }
    let result ← spawnManagedWorker mc fleet timed provider { baseSpec with name := timed.sandboxName, idempotencyKey := "timeout" } cfg runtime
    check (!result.isOk && (← clock.get) == 360000) "bounded bootstrap deadline"
    let some (failed, failedSlice) ← getManagedMachine? mc timed.id
      | throw (IO.userError "timeout reservation disappeared")
    check (failed.status == "destroyed" && failedSlice.activeComputeEligible == 0 &&
      (← requests.get).back!.method == "DELETE") "timeout destroys provider and closes local lifecycle"
    let .ok failedTokens ← execParamQuery mc.db "SELECT node_token FROM managed_node_tokens WHERE machine_id=?1;" #[timed.id]
      | throw (IO.userError "token query failed")
    check (failedTokens.size > 1 && cell failedTokens[1]! 0 == "") "timed out guest did not acquire node credential"

    requests.set #[]
    let rejected ← spawnManagedWorker mc { fleet with maxConcurrent := 0 }
      { baseMachine with id := "reject-before-io" } provider { baseSpec with idempotencyKey := "admission-reject" } cfg runtime
    check (!rejected.isOk && (← requests.get).isEmpty) "admission precedes provider I/O"
    let invalidCfg ← spawnManagedWorker mc fleet { baseMachine with id := "bad-config" }
      provider baseSpec { cfg with coreUrl := "http://core.example" } runtime
    check (!invalidCfg.isOk && (← requests.get).isEmpty) "invalid bootstrap config rents nothing"

    clock.set 0
    createStatus.set 403
    currentId.set "provider-refused"
    let refused := { baseMachine with id := "provider-refused" }
    check (!(← spawnManagedWorker mc fleet refused provider { baseSpec with idempotencyKey := "refusal" } cfg runtime).isOk) "provider refusal preserved"
    let some (refusedRow, _) ← getManagedMachine? mc refused.id
      | throw (IO.userError "refused reservation missing")
    check (refusedRow.status == "destroyed" && refusedRow.providerId.isEmpty) "provider refusal cannot manufacture ready machine"
    createStatus.set 503
    let uncertain := { baseMachine with id := "provider-uncertain" }
    check (!(← spawnManagedWorker mc fleet uncertain provider { baseSpec with idempotencyKey := "uncertain" } cfg runtime).isOk) "uncertain provider outcome preserved"
    let some (uncertainRow, _) ← getManagedMachine? mc uncertain.id
      | throw (IO.userError "uncertain reservation missing")
    check (uncertainRow.status == "provisioning" && uncertainRow.providerId.isEmpty) "uncertain reservation retained for reconciliation"

    -- Neither caller-supplied estimates nor a stale daily-spend snapshot can
    -- bypass a cap: the second lease is checked against durable reservations.
    createStatus.set 201
    shouldPoll.set true
    clock.set 0
    currentId.set "user-capped-first"
    let capped := { baseMachine with id := "user-capped-first", ownerUserId := "capped-user", spentCents := 0 }
    let budget : ManagedUserAdmission := { capCents := 1, inferenceCents := 0, computeCents := 0 }
    let .ok cappedResult ← spawnManagedWorker mc fleet capped provider
        { baseSpec with idempotencyKey := "user-first" } cfg runtime (some budget)
      | throw (IO.userError "first capped reservation failed")
    check (cappedResult.machine.spentCents == 1) "caller estimate cannot lower the provider quote"
    let beforeCapReject := (← requests.get).size
    check (!(← spawnManagedWorker mc fleet { capped with id := "user-capped-second" } provider
      { baseSpec with idempotencyKey := "user-second" } cfg runtime (some budget)).isOk &&
      (← requests.get).size == beforeCapReject) "pending reservations enforce user cap before I/O"

    let .ok admissionStore ← openManagedComputeStore s!"{root}/stale-admission.db"
      | throw (IO.userError "admission fixture open failed")
    try
      let staleFleet := { fleet with maxConcurrent := 1 }
      let .ok _ ← provisionManagedMachine admissionStore staleFleet baseMachine 1000
        | throw (IO.userError "first reservation admission failed")
      check (!(← provisionManagedMachine admissionStore staleFleet
        { baseMachine with id := "second-stale-reservation" } 1000).isOk) "transaction rejects stale concurrency snapshot"
    finally
      closeManagedComputeStore admissionStore
  finally
    closeManagedComputeStore mc

/-- Policy-only provider for REST/MCP tenant tests. This implements no real
    provider protocol (in particular, it is not a lean.ci client). -/
def mockPolicyProvider (mc : ManagedComputeStore) (providerName : String) : Provider := {
  name := providerName
  readinessDeadlineSecs := 360
  isReady := fun state => state == "ready"
  isStopped := fun state => state == "stopped"
  quoteCents := fun _ _ => .ok 10
  spawn := fun spec => do
    return .ok { providerId := (← OrbBin.PosixExt.newUuidV4), name := spec.name, state := "ready" }
  get := fun id => pure (.ok { providerId := id, state := "ready" })
  list := pure (.ok #[])
  destroy := fun _ => pure (.ok ())
  stop := fun _ => pure (.ok ())
  resume := fun _ _ => pure (.error { code := "mock_not_implemented" })
  fork := fun _ _ => pure (.error { code := "mock_not_implemented" })
  extend := fun _ _ => pure (.error { code := "mock_not_implemented" })
  saveSnapshot := fun _ _ => pure (.error { code := "mock_not_implemented" })
  getSnapshot := fun _ => pure (.error { code := "mock_not_implemented" })
  listSnapshots := pure (.ok #[])
  deleteSnapshot := fun _ => pure (.error { code := "mock_not_implemented" })
  writeFile := fun _ _ _ => pure (.ok ())
  exec := fun providerId command _ => do
    if (command.splitOn "sudo bash").length > 1 then
      let .ok rows ← execParamQuery mc.db
          "SELECT m.id,t.enroll_token,m.node_boot_epoch FROM managed_machines m JOIN managed_node_tokens t ON t.machine_id=m.id WHERE m.provider_id=?1;" #[providerId]
        | return .error { code := "mock_enrollment_missing" }
      if rows.size < 2 then return .error { code := "mock_enrollment_missing" }
      let mid := cell rows[1]! 0
      let boot := cellU64 rows[1]! 2
      let .ok (_, token) ← enrollManagedNode mc mid (cell rows[1]! 1) (some boot)
        | return .error { code := "mock_enrollment_failed" }
      let .ok _ ← authenticateNodeToken mc mid token (some boot)
        | return .error { code := "mock_authentication_failed" }
      let .ok () ← recordAuthenticatedManagedPoll mc mid boot (← coreEpochSec)
        | return .error { code := "mock_poll_failed" }
    return .ok (.obj #[("exitCode", .nat 0)])
}

end OrbCore.ManagedProvisioningTests
