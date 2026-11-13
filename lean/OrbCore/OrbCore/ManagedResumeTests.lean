import OrbCore.Managed
import OrbCore.RemoteFleetAndRelay
import OrbCore.ManagedProvisioningTests

namespace OrbCore.ManagedResumeTests

open OrbCore.Managed OrbCore.Store Orb.ManagedNode

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed resume: {label}")

private def runInventoryTests (root : String) : IO Unit := do
  let .ok mc ← openManagedComputeStore s!"{root}/boat-inventory.db" | throw (IO.userError "inventory open failed")
  let .ok core ← openCoreStore s!"{root}/inventory-core" | throw (IO.userError "inventory core open failed")
  try
    let now ← coreEpochSec
    let seedLegacy (id label : String) : IO Unit := do
      let .ok _ ← execParamQuery mc.db
          ("INSERT INTO managed_machines(id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id) " ++
           "VALUES(?1,?2,'boat','small','ready','',60,7,0,1,0,'user','',1,1,'');") #[id, label]
        | throw (IO.userError "legacy fixture failed")
    for (id, label) in #[ ("mm72guzp66", "small-a"), ("mmavnctzce", "small-b"),
        ("mmhbh4dmg9", "pareto-worker"), ("mmkryf6rxn", "ldgr-worker"), ("mmambiguous", "ambiguous") ] do
      seedLegacy id label
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
    let .ok _ ← provisionManagedMachine mc fleet {
      id := "orphan-reservation", sandboxName := "orb-managed-orphan-reservation", ttlMinutes := 60,
      spentCents := 1, deletableAtSec := 0
    } (now - 500) | throw (IO.userError "orphan fixture failed")
    let .ok _ ← provisionManagedMachine mc fleet {
      id := "recent-reservation", sandboxName := "orb-managed-recent-reservation", ttlMinutes := 60,
      spentCents := 1, deletableAtSec := 0
    } (now - 100) | throw (IO.userError "recent fixture failed")
    let inventory : Array OrbCore.ManagedProvider.Machine := #[
      { providerId := "bx_wsja57zz", name := "orb-managed-mm72guzp66", state := "archived" },
      { providerId := "bx_d6nrdma7", name := "orb-managed-mmavnctzce", state := "archived" },
      { providerId := "bx_pareto_test", name := "orb-managed-mmhbh4dmg9", state := "archived" },
      { providerId := "bx_ae42drr8", name := "orb-managed-mmkryf6rxn", state := "archived" },
      { providerId := "duplicate-a", name := "orb-managed-mmambiguous", state := "archived" },
      { providerId := "duplicate-b", name := "orb-managed-mmambiguous", state := "archived" },
      { providerId := "unrelated", name := "orb-managed-unregistered", state := "idle" }
    ]
    let .ok report ← OrbCore.RemoteFleetAndRelay.reconcileManagedProviderInventory mc "boat" "orb-managed-" inventory now
      | throw (IO.userError "inventory reconcile failed")
    check (((report.fieldArr? "backfilled").getD #[]).size == 4 &&
      ((report.fieldArr? "stopped").getD #[]).size == 4 &&
      ((report.fieldArr? "ambiguous").getD #[]).size == 1) "exact names recover archived pre-cutover records"
    for (id, providerId) in #[ ("mm72guzp66", "bx_wsja57zz"), ("mmavnctzce", "bx_d6nrdma7"),
        ("mmhbh4dmg9", "bx_pareto_test"), ("mmkryf6rxn", "bx_ae42drr8") ] do
      let some (m, slice) ← getManagedMachine? mc id | throw (IO.userError "legacy record missing")
      check (m.id == id && m.providerId == providerId && m.status == "stopped" &&
        m.spentCents == 7 && slice.nodeBootEpoch == 1 && slice.activeComputeEligible == 0) "backfill changes no Core identity, cost or boot"
    let some (ambiguous, _) ← getManagedMachine? mc "mmambiguous" | throw (IO.userError "ambiguous record missing")
    let some (orphan, _) ← getManagedMachine? mc "orphan-reservation" | throw (IO.userError "orphan record missing")
    let some (recent, _) ← getManagedMachine? mc "recent-reservation" | throw (IO.userError "recent record missing")
    check (ambiguous.providerId.isEmpty && ambiguous.status == "ready" && orphan.status == "destroyed" &&
      recent.status == "provisioning") "ambiguous names and fresh requests are never guessed or reaped"
    let .ok repeated ← OrbCore.RemoteFleetAndRelay.reconcileManagedProviderInventory mc "boat" "orb-managed-" inventory now
      | throw (IO.userError "repeat reconcile failed")
    check (((repeated.fieldArr? "stopped").getD #[]).isEmpty) "reconciliation is idempotent"

    -- The real resume entry point repairs a legacy record before attempting fork.
    let prefixName := sandboxNamePrefixFor (← IO.appPath).toString
    seedLegacy "mmondemand" "on-demand-worker"
    let source : OrbCore.ManagedProvider.Machine := {
      providerId := "bx_on_demand", name := prefixName ++ "mmondemand", state := "archived"
    }
    let template := OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat"
    let requestedSource ← IO.mkRef ""
    let requestedName ← IO.mkRef ""
    let provider := { template with
      list := pure (.ok (inventory.push source))
      get := fun id => if id == source.providerId then pure (.ok source) else template.get id
      resume := fun id spec => do
        requestedSource.set id
        requestedName.set spec.name
        template.resume id spec
    }
    let ctx : OrbCore.RemoteFleetAndRelay.ManagedLifecycleContext := {
      store := core, fleet,
      override? := some (provider, { coreUrl := "https://core.example", script := "#!/bin/sh\nexit 0\n" })
    }
    let .ok resumed ← OrbCore.RemoteFleetAndRelay.runConfiguredManagedLifecycle mc ctx "mmondemand" "resume" now
        (.obj #[("ttl_minutes", .nat 5)]) "restore-existing-boat"
      | throw (IO.userError "on-demand legacy resume failed")
    let some (current, _) ← getManagedMachine? mc "mmondemand" | throw (IO.userError "resumed legacy missing")
    check ((← requestedSource.get) == "bx_on_demand" && (← requestedName.get) == prefixName ++ "mmondemand" &&
      current.id == "mmondemand" && current.nodeBootEpoch == 2 &&
      current.status == "ready" && current.providerId != "bx_on_demand" &&
      (((resumed.field? "machine").getD .null).fieldStr? "node_id") == some "managed-mmondemand") "archived source forks under the same machine and node ID"
    let stale : ProviderObservation := {
      provider := "boat", machineId := current.id, observedStatus := "stopped",
      expectedProviderId? := some "bx_on_demand", expectedBootEpoch? := some 1
    }
    check (!(← applyProviderObservation mc stale now 0 1).isOk) "stale source observations cannot stop the successor"
    let some (stillReady, _) ← getManagedMachine? mc current.id | throw (IO.userError "successor missing")
    check (stillReady.status == "ready" && stillReady.nodeBootEpoch == 2) "reconciliation preserves the live successor"

    let actualId := "a6fed7e9-950b-40e8-ad83-4c599ceee4b4"
    let seedDestroyed (id providerId : String) : IO Unit := do
      seedLegacy id (prefixName ++ id)
      let .ok _ ← execParamQuery mc.db
          "UPDATE managed_machines SET status='destroyed',phase_code=3,active_compute_eligible=0,provider_id=?2 WHERE id=?1;"
          #[id, providerId] | throw (IO.userError "destroyed fixture failed")
      let .ok () ← putEnrollmentToken mc id "stale-enrollment" | throw (IO.userError "stale fixture failed")
    seedDestroyed actualId "bx_xcew9qru"
    check (!(← prepareManagedResume mc fleet actualId "unobserved" "new-token" 5 1 now (now + 360)).isOk)
      "destroyed resume requires provider observation"
    let retained : OrbCore.ManagedProvider.Machine := {
      providerId := "bx_xcew9qru", name := prefixName ++ actualId, state := "archived"
    }
    let .ok _ ← execParamQuery mc.db
        "UPDATE managed_node_tokens SET node_token='stale-node-token' WHERE machine_id=?1;" #[actualId]
      | throw (IO.userError "stale node fixture failed")
    let .ok archivedObservation := observeProviderPayload "boat" actualId 200 (.obj #[("state", .str "archived")])
      | throw (IO.userError "archive adapter failed")
    check (!(← applyProviderObservation mc { archivedObservation with
        expectedProviderId? := some "wrong-source", expectedBootEpoch? := some 1 } now 0 1).isOk &&
      !(← applyProviderObservation mc { archivedObservation with
        expectedProviderId? := some "bx_xcew9qru", expectedBootEpoch? := some 2 } now 0 1).isOk)
      "archive repair requires matching provider and boot fences"
    let .ok _ ← OrbCore.RemoteFleetAndRelay.reconcileManagedProviderInventory mc "boat" prefixName #[retained] now
      | throw (IO.userError "destroyed archive reconciliation failed")
    let some (repaired, repairedSlice) ← getManagedMachine? mc actualId | throw (IO.userError "repair missing")
    check (repaired.status == "stopped" && repaired.providerId == "bx_xcew9qru" &&
      repaired.nodeBootEpoch == 1 && repairedSlice.activeComputeEligible == 0 &&
      !(← enrollManagedNode mc actualId "stale-enrollment" (some 1)).isOk &&
      !(← authenticateNodeToken mc actualId "stale-node-token" (some 1)).isOk)
      "archived observation repairs false destruction without reviving enrollment"
    check (!(← prepareManagedResume mc fleet actualId
      "budget-recovery" "new-token" 5 1 now (now + 360)
      (some { capCents := 0, inferenceCents := 0, computeCents := 0 })).isOk)
      "archive correction does not bypass user budget admission"
    let .ok _ ← execParamQuery mc.db
        "UPDATE managed_machines SET status='destroyed',phase_code=3 WHERE id=?1;" #[actualId]
      | throw (IO.userError "on-demand destroyed fixture failed")
    let observedIds ← IO.mkRef (#[] : Array String)
    let recoveryProvider := { provider with
      get := fun id => do
        observedIds.modify (·.push id)
        if id == "bx_xcew9qru" then return .ok retained
        if #["mm5xvnw6ha", "mm3dagt4ua", "mmp2t4xd94"].contains id then
          return .error { code := "provider_http_404", status := 404 }
        template.get id
    }
    let recoveryCtx := { ctx with override? := some (recoveryProvider,
      { coreUrl := "https://core.example", script := "#!/bin/sh\nexit 0\n" }) }
    let .ok recovered ← OrbCore.RemoteFleetAndRelay.runConfiguredManagedLifecycle mc recoveryCtx actualId "resume" now
        (.obj #[("ttl_minutes", .nat 5)]) "recover-false-destroy"
      | throw (IO.userError "destroyed bound resume failed")
    check ((← requestedSource.get) == "bx_xcew9qru" &&
      (((recovered.field? "machine").getD .null).fieldStr? "node_id") == some ("managed-" ++ actualId))
      "fork uses Boat id while retaining actual Core and node identity"
    for id in #["mm5xvnw6ha", "mm3dagt4ua", "mmp2t4xd94"] do
      seedDestroyed id id
      requestedSource.set ""
      check (!(← OrbCore.RemoteFleetAndRelay.runConfiguredManagedLifecycle mc recoveryCtx id "resume" now
        (.obj #[("ttl_minutes", .nat 5)]) ("missing-" ++ id)).isOk) "genuine 404 resume rejected"
      let some (gone, _) ← getManagedMachine? mc id | throw (IO.userError "404 fixture missing")
      check (gone.status == "destroyed" && (← requestedSource.get).isEmpty && (← observedIds.get).contains id)
        "genuine 404 stays destroyed and never forks"
  finally
    closeManagedComputeStore mc
    closeCoreStore core

def run (root : String) : IO Unit := do
  runInventoryTests root
  let .ok mc ← openManagedComputeStore s!"{root}/resume.db"
    | throw (IO.userError "resume store open failed")
  try
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
    let machine : ManagedMachine := {
      id := "resume-core-id", sandboxName := "orb-managed-resume", provider := "boat",
      size := "small", ttlMinutes := 5, spentCents := 1, deletableAtSec := 1000
    }
    let .ok _ ← provisionManagedMachine mc fleet machine 1000 | throw (IO.userError "reserve failed")
    let .ok () ← bindManagedProviderId mc machine.id "source-provider-id" 1 | throw (IO.userError "bind failed")
    let .ok () ← putEnrollmentToken mc machine.id "boot-one-enroll" 1100 | throw (IO.userError "token failed")
    let .ok (_, firstToken) ← enrollManagedNode mc machine.id "boot-one-enroll" (some 1)
      | throw (IO.userError "enroll failed")
    let .ok firstBoot ← authenticateAndRecordManagedPoll mc machine.id firstToken (some 1) 1001
      | throw (IO.userError "initial poll failed")
    check (firstBoot == 1) "first boot ready"
    let .ok () ← enqueueRelayCommand mc machine.id "old-boot-command" "{}"
      | throw (IO.userError "old command fixture failed")
    let .ok _ ← applyVmLifecycle mc machine.id {
      opCode := VmOp.encode .stop, ownerLive := 0, idleElapsed := 0,
      presentedBootEpoch := 1, nowEpoch := 1002
    } | throw (IO.userError "stop failed")
    check (!(← authenticateAndRecordManagedPoll mc machine.id firstToken (some 1) 1003).isOk) "stopped poll cannot revive a boot"

    let .ok (intent, fresh) ← prepareManagedResume mc fleet machine.id "resume-one" "boot-two-enroll" 5 1 1010 1100
      | throw (IO.userError "prepare failed")
    check (fresh && intent.expectedBoot == 2 && intent.oldProviderId == "source-provider-id") "successor reserved before provider I/O"
    let some (pending, pendingSlice) ← getManagedMachine? mc machine.id | throw (IO.userError "pending missing")
    check (pending.status == "provisioning" && pending.nodeBootEpoch == 1 && pendingSlice.phaseCode == 2 &&
      pendingSlice.activeComputeEligible == 0) "pending successor remains ineligible"
    check (!(← authenticateNodeToken mc machine.id firstToken (some 1)).isOk) "predecessor token revoked before fork"
    check (!(← enrollManagedNode mc machine.id "boot-two-enroll" (some 2)).isOk) "unbound provider cannot enroll"
    let .ok (replayPending, wasNew) ← prepareManagedResume mc fleet machine.id "resume-one" "ignored-token" 5 1 1011 1100
      | throw (IO.userError "pending replay failed")
    check (!wasNew && replayPending.id == intent.id) "concurrent retry cannot rent a second successor"
    check (!(← prepareManagedResume mc fleet machine.id "another-resume" "other-token" 5 1 1011 1100).isOk) "one pending resume per VM"

    -- A pending resume consumes a real fleet slot even though its old boot is stopped.
    let .ok () ← saveManagedFleetConfig mc true true 2000 2 1 | throw (IO.userError "config failed")
    check (!(← provisionManagedMachine mc fleet { machine with id := "capacity-bypass" } 1011).isOk) "pending resume counts toward capacity"
    let .ok () ← saveManagedFleetConfig mc true true 2000 2 100 | throw (IO.userError "config failed")
    let .ok () ← bindManagedResumeProvider mc intent.id "successor-provider-id" | throw (IO.userError "resume bind failed")
    check (!(← enrollManagedNode mc machine.id "boot-two-enroll" (some 1)).isOk) "old boot cannot consume successor enrollment"
    let .ok (_, secondToken) ← enrollManagedNode mc machine.id "boot-two-enroll" (some 2)
      | throw (IO.userError "successor enroll failed")
    let some (_, beforePoll) ← getManagedMachine? mc machine.id | throw (IO.userError "pending missing")
    check (beforePoll.phaseCode == 2 && beforePoll.nodeBootEpoch == 1) "enrollment is not resume completion"
    check (!(← authenticateAndRecordManagedPoll mc machine.id secondToken (some 1) 1019).isOk) "successor token cannot claim old epoch"
    let .ok resumedBoot ← authenticateAndRecordManagedPoll mc machine.id secondToken (some 2) 1020
      | throw (IO.userError "successor poll failed")
    let some (ready, readySlice) ← getManagedMachine? mc machine.id | throw (IO.userError "ready missing")
    check (resumedBoot == 2 && ready.id == machine.id && ready.providerId == "successor-provider-id" &&
      ready.status == "ready" && ready.nodeBootEpoch == 2 && readySlice.activeComputeEligible == 1) "atomic first poll commits successor boot"
    let .ok newLease ← pollRelayLease mc machine.id 2 1020 1080 | throw (IO.userError "resumed lease poll failed")
    check newLease.isNone "successor never receives predecessor commands"
    let .ok (replayed, replayFresh) ← prepareManagedResume mc fleet machine.id "resume-one" "ignored" 5 1 1021 1100
      | throw (IO.userError "completed replay failed")
    check (!replayFresh && replayed.state == "completed") "completed retry is durable"
    check (!(← prepareManagedResume mc fleet machine.id "resume-one" "ignored" 10 1 1021 1100).isOk) "retry cannot change TTL"
    check (!(← authenticateNodeToken mc machine.id firstToken (some 1)).isOk) "old credential stays fenced after resume"

    let .ok _ ← applyVmLifecycle mc machine.id {
      opCode := VmOp.encode .stop, ownerLive := 0, idleElapsed := 0,
      presentedBootEpoch := 2, nowEpoch := 1025
    } | throw (IO.userError "second stop failed")
    let .ok (failedIntent, _) ← prepareManagedResume mc fleet machine.id "resume-timeout" "boot-three-enroll" 5 1 1030 1050
      | throw (IO.userError "second prepare failed")
    let .ok () ← bindManagedResumeProvider mc failedIntent.id "timed-out-provider-id" | throw (IO.userError "bind failed")
    let .ok (_, thirdToken) ← enrollManagedNode mc machine.id "boot-three-enroll" (some 3)
      | throw (IO.userError "third enroll failed")
    check (!(← authenticateAndRecordManagedPoll mc machine.id thirdToken (some 3) 1050).isOk) "deadline rejects late readiness"
    let .ok fenced ← fenceManagedResumeCleanup mc failedIntent.id | throw (IO.userError "cleanup fence failed")
    check (fenced.state == "aborting" &&
      !(← authenticateAndRecordManagedPoll mc machine.id thirdToken (some 3) 1040).isOk) "cleanup fence survives a backward clock jump"
    -- Provider destruction is a precondition of this rollback, mocked by this store test.
    let .ok () ← abortManagedResume mc failedIntent.id | throw (IO.userError "rollback failed")
    let some (restored, restoredSlice) ← getManagedMachine? mc machine.id | throw (IO.userError "restored missing")
    check (restored.status == "stopped" && restored.providerId == "successor-provider-id" &&
      restored.nodeBootEpoch == 2 && restoredSlice.activeComputeEligible == 0) "failed child preserves stopped source"
    check (!(← authenticateNodeToken mc machine.id secondToken).isOk &&
      !(← authenticateNodeToken mc machine.id thirdToken).isOk) "rollback revives no credential"
    let .ok charges ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_cost_reservations;" #[]
      | throw (IO.userError "charges query failed")
    check (charges.size > 1 && cell charges[1]! 0 == "3") "replays reserve no duplicate cost"
  finally
    closeManagedComputeStore mc

end OrbCore.ManagedResumeTests
