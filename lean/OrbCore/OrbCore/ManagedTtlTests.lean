import OrbCore.ManagedTtl
import OrbCore.ManagedProvisioningTests

namespace OrbCore.ManagedTtlTests

open OrbCore.Managed OrbCore.ManagedProvider OrbCore.ManagedTtl OrbCore.Store OrbBin.Json

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed TTL: {label}")

private def requireOk {α : Type} (result : Except String α) (label : String) : IO α := do
  match result with
  | .ok value => return value
  | .error e => throw (IO.userError s!"managed TTL: {label}: {e}")

private def checkError {α : Type} (result : Except String α) (expected label : String) : IO Unit := do
  match result with
  | .error e => check (e == expected) s!"{label}: expected {expected}, got {e}"
  | .ok _ => throw (IO.userError s!"managed TTL: {label}: unexpectedly succeeded")

private def fleet : ManagedFleetState := {
  enabled := true, boatEnabled := true, dailyCapCents := 100000, maxConcurrent := 1000
}

private def machine (mc : ManagedComputeStore) (id : String) : IO ManagedMachine := do
  let some (m, _) ← getManagedMachine? mc id
    | throw (IO.userError s!"managed TTL: missing fixture {id}")
  return m

private def sql (mc : ManagedComputeStore) (query : String) (args : Array String := #[]) :
    IO (Array (Array String)) := do
  requireOk (← execParamQuery mc.db query args) "fixture/query"

/-- Exercise real reservation/readiness methods, with no bootstrap or real guest.
    The store's trusted fixture poll accepts an explicit virtual timestamp. -/
private def seed (mc : ManagedComputeStore) (id : String) (start : UInt64 := 1000)
    (ttl : UInt64 := 5) (deletable : UInt64 := 1000) (owner : String := "") : IO ManagedMachine := do
  discard <| requireOk (← provisionManagedMachine mc fleet {
    id, sandboxName := s!"orb-managed-{id}", provider := "boat", ownerUserId := "alice",
    ownerMission := owner, ttlMinutes := ttl, spentCents := ttl, deletableAtSec := deletable
  } start) "reserve fixture"
  discard <| requireOk (← bindManagedProviderId mc id s!"remote-{id}" 1) "bind fixture"
  discard <| requireOk (← recordAuthenticatedManagedPoll mc id 1 start) "ready fixture"
  machine mc id

private def stop (mc : ManagedComputeStore) (m : ManagedMachine) (now : UInt64) : IO Unit := do
  discard <| requireOk (← applyVmLifecycle mc m.id {
    opCode := Orb.ManagedNode.VmOp.encode .stop, ownerLive := 0, idleElapsed := 0,
    presentedBootEpoch := m.nodeBootEpoch, nowEpoch := now
  }) "stop fixture"

private def extensionTests (root : String) : IO Unit := do
  let mc ← requireOk (← openManagedComputeStore s!"{root}/ttl-extensions.db") "open extensions"
  try
    let calls ← IO.mkRef (#[] : Array (String × UInt64))
    let response ← IO.mkRef (none : Option ProviderError)
    let template := OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat"
    let provider : Provider := { template with
      quoteCents := fun _ ttl => .ok ttl
      extend := fun id seconds => do
        calls.modify (·.push (id, seconds))
        if let some e ← response.get then return .error e
        return .ok ()
    }
    let original ← seed mc "explicit"
    let updated ← requireOk (← extendWorker mc fleet provider original.id "explicit-key" 5 1100)
      "explicit extension"
    check ((← calls.get) == #[(original.providerId, 500)])
      "provider receives remaining seconds to absolute target 1600, not added duration 300"
    check (updated.expiresAtSec == 1600 && updated.ttlMinutes == 10 && updated.spentCents == 10 &&
      updated.id == original.id && updated.providerId == original.providerId &&
      updated.nodeBootEpoch == original.nodeBootEpoch && updated.sandboxName == original.sandboxName &&
      updated.ownerUserId == original.ownerUserId && updated.createdAtSec == original.createdAtSec)
      "successful extension preserves public/node/provider identity and charges once"
    let replay ← requireOk (← extendWorker mc fleet provider original.id "explicit-key" 5 1150) "replay"
    check (replay.expiresAtSec == 1600 && replay.spentCents == 10 && (← calls.get).size == 1)
      "completed same-key retry neither adds duration nor performs provider I/O"
    checkError (← extendWorker mc fleet provider original.id "explicit-key" 10 1150)
      "managed_idempotency_conflict" "retry cannot change duration"
    let charges ← sql mc "SELECT COUNT(*),SUM(cents) FROM managed_cost_reservations WHERE machine_id=?1;" #[original.id]
    check (cell charges[1]! 0 == "2" && cell charges[1]! 1 == "10") "one create plus one extension charge"

    let capped ← seed mc "hard-cap" 1000 715
    let capResult ← requireOk (← extendWorker mc fleet provider capped.id "hard-cap-key" 10 1100) "hard cap"
    check (capResult.expiresAtSec == 44200 && capResult.ttlMinutes == 720 &&
      (← calls.get).back! == (capped.providerId, 43100)) "deadline clamps to current boot start plus 720 minutes"
    let beforeMax := (← calls.get).size
    checkError (← extendWorker mc fleet provider capped.id "over-hard-cap" 5 1101)
      "managed_max_lifetime_reached" "cannot extend past hard limit"
    check ((← calls.get).size == beforeMax) "hard-limit rejection precedes I/O"

    -- Resume uses the actual durable resume intent, not a synthetic created_at.
    let predecessor ← seed mc "resumed"
    stop mc predecessor 1100
    let (intent, _) ← requireOk (← prepareManagedResume mc fleet predecessor.id "ttl-resume"
      "resume-enroll" 5 5 10000 10100) "reserve resumed boot"
    discard <| requireOk (← bindManagedResumeProvider mc intent.id "remote-resumed-boot-two") "bind resumed boot"
    discard <| requireOk (← recordAuthenticatedManagedPoll mc predecessor.id 2 10001) "commit resumed boot"
    let resumed ← requireOk (← extendWorker mc fleet provider predecessor.id "resumed-cap" 720 10010) "extend resumed boot"
    check (resumed.createdAtSec == 1000 && resumed.nodeBootEpoch == 2 &&
      resumed.providerId == "remote-resumed-boot-two" && resumed.expiresAtSec == 53200 &&
      resumed.ttlMinutes == 720 && (← calls.get).back! == (resumed.providerId, 43190))
      "resumed lifetime starts at 10000, not the original machine creation or readiness poll"

    let refused ← seed mc "refused"
    let beforeRefusal ← sql mc "SELECT spent_today_cents FROM managed_fleet_state WHERE singleton_id=1;"
    response.set (some { code := "denied", status := 403 })
    checkError (← extendWorker mc fleet provider refused.id "refused-key" 5 1100)
      "managed_provider_extension_failed" "definitive provider error is propagated"
    let unchanged ← machine mc refused.id
    let refund ← sql mc "SELECT COUNT(*) FROM managed_cost_reservations WHERE id='extend:refused-key';"
    let failedIntent ← sql mc "SELECT state FROM managed_extension_intents WHERE id='refused-key';"
    let afterRefusal ← sql mc "SELECT spent_today_cents FROM managed_fleet_state WHERE singleton_id=1;"
    check (unchanged.expiresAtSec == 1300 && unchanged.spentCents == 5 &&
      cell beforeRefusal[1]! 0 == cell afterRefusal[1]! 0 &&
      cell refund[1]! 0 == "0" && cell failedIntent[1]! 0 == "failed")
      "definitive refusal never claims success and releases its durable reservation"
    let beforeFailedReplay := (← calls.get).size
    checkError (← extendWorker mc fleet provider refused.id "refused-key" 5 1110)
      "managed_extension_failed" "failed-key replay cannot manufacture success"
    check ((← calls.get).size == beforeFailedReplay) "definitively failed key is not sent again"
    response.set none
    discard <| requireOk (← extendWorker mc fleet provider refused.id "new-after-refusal" 5 1120)
      "released pending slot permits a new key"

    let uncertain ← seed mc "uncertain"
    response.set (some { code := "timeout", status := 0 })
    checkError (← extendWorker mc fleet provider uncertain.id "uncertain-key" 5 1100)
      "managed_extension_outcome_uncertain" "uncertain provider error"
    check ((← machine mc uncertain.id).expiresAtSec == 1300 &&
      (← machine mc uncertain.id).spentCents == 5) "uncertain result does not claim local success"
    let pending ← requireOk (← pendingManagedExtensions mc) "pending extension read"
    let some pendingIntent := pending[0]?
      | throw (IO.userError "managed TTL: missing uncertain extension intent")
    check (pending.size == 1 && pendingIntent.newExpiry == 1600 && pendingIntent.cost == 5)
      "uncertain extension retains fixed target and reserved cost"
    -- A 5xx retry is also uncertain, not a release of the reservation.
    response.set (some { code := "unavailable", status := 503 })
    checkError (← extendWorker mc fleet provider uncertain.id "uncertain-key" 5 1200)
      "managed_extension_outcome_uncertain" "server error retains retry intent"
    check ((← calls.get).back! == (uncertain.providerId, 400)) "uncertain retry keeps target 1600"
    response.set none
    let recovered ← requireOk (← extendWorker mc fleet provider uncertain.id "uncertain-key" 5 1250) "uncertain retry success"
    let retainedCharge ← sql mc "SELECT COUNT(*),SUM(cents) FROM managed_cost_reservations WHERE machine_id=?1;" #[uncertain.id]
    check (recovered.expiresAtSec == 1600 && recovered.spentCents == 10 &&
      (← calls.get).back! == (uncertain.providerId, 350) &&
      cell retainedCharge[1]! 0 == "2" && cell retainedCharge[1]! 1 == "10")
      "uncertain retries shorten remaining seconds without adding duration or cost"

    let budgeted ← seed mc "budgeted"
    let beforeBudget := (← calls.get).size
    let totals ← sql mc "SELECT spent_today_cents FROM managed_fleet_state WHERE singleton_id=1;"
    let total := cellU64 totals[1]! 0
    discard <| requireOk (← saveManagedFleetConfig mc true true total total 1000) "set exact fleet cap"
    checkError (← extendWorker mc fleet provider budgeted.id "fleet-cap" 5 1100)
      "managed_spawn_rejected" "durable fleet cap beats stale caller defaults"
    discard <| requireOk (← saveManagedFleetConfig mc true true 100000 total 1000) "restore fleet cap"
    checkError (← extendWorker mc fleet provider budgeted.id "user-cap" 5 1100
      (some { capCents := 1, inferenceCents := 0, computeCents := 0 }))
      "managed_user_spend_cap_exceeded" "durable user reservations beat stale spend snapshot"
    check ((← calls.get).size == beforeBudget) "fleet and user cost rejection both precede provider I/O"
    let rejectedIntents ← sql mc "SELECT COUNT(*) FROM managed_extension_intents WHERE id IN ('fleet-cap','user-cap');"
    check (cell rejectedIntents[1]! 0 == "0") "rejected admission leaves no pending extension"
  finally
    closeManagedComputeStore mc

private def fencingTests (root : String) : IO Unit := do
  let mc ← requireOk (← openManagedComputeStore s!"{root}/ttl-fencing.db") "open fencing"
  let core ← requireOk (← openCoreStore s!"{root}/ttl-fencing-core") "open fencing core"
  try
    let m ← seed mc "pending"
    let calls ← IO.mkRef (#[] : Array String)
    let template := OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat"
    let provider : Provider := { template with
      quoteCents := fun _ ttl => .ok ttl
      extend := fun _ seconds => do
        calls.modify (·.push s!"extend:{seconds}")
        return .error { code := "timeout", status := 0 }
      get := fun id => do
        calls.modify (·.push "get")
        return .ok { providerId := id, state := "running" }
      destroy := fun _ => do calls.modify (·.push "destroy"); return .ok ()
    }
    let resolve : Resolver := fun _ => pure (.ok provider)
    checkError (← extendWorker mc fleet provider m.id "pending-key" 5 1200)
      "managed_extension_outcome_uncertain" "prepare uncertain fencing fixture"
    checkError (← claimManagedExpiry mc m.id 1300) "managed_extension_pending"
      "pending target protects old deadline from expiry claim"
    discard <| requireOk (← tick mc core fleet resolve 1301) "tick pending extension"
    check ((← calls.get) == #["extend:400", "extend:299"] &&
      (← machine mc m.id).status == "ready" && !(← machine mc m.id).cordoned)
      "reaper retries fixed target but cannot observe/destroy guest at the old deadline"
    discard <| requireOk (← recordAuthenticatedManagedPoll mc m.id 1 1301) "pending target permits heartbeat"
    checkError (← recordAuthenticatedManagedPoll mc m.id 2 1302) "stale_boot_epoch"
      "pending extension never authorizes another boot"
    checkError (← recordAuthenticatedManagedPoll mc m.id 1 1600) "managed_machine_expired"
      "pending extension cannot let heartbeat cross its fixed target"
    discard <| requireOk (← claimManagedExpiry mc m.id 1600) "claim at fixed target"
    checkError (← finishManagedExtension mc "pending-key" true) "managed_expiry_already_claimed"
      "expiry wins against an in-flight late provider acknowledgement"
    -- Use a pre-expiry timestamp to distinguish the durable claim fence from
    -- mere now >= expires rejection; this is an intentional interleaving replay.
    checkError (← prepareManagedExtension mc fleet m.id "race-after-claim" 5 1299
      (fun _ ttl => .ok ttl)) "managed_expiry_already_claimed"
      "durable expiry claim blocks racing extension even with a stale clock"
    check ((← machine mc m.id).expiresAtSec == 1300 && (← machine mc m.id).status == "destroying")
      "late completion cannot resurrect a claimed lease"
  finally
    closeManagedComputeStore mc
    closeCoreStore core

private def reaperTests (root : String) : IO Unit := do
  let mc ← requireOk (← openManagedComputeStore s!"{root}/ttl-reaper.db") "open reaper"
  let core ← requireOk (← openCoreStore s!"{root}/ttl-reaper-core") "open reaper core"
  try
    discard <| requireOk (← execParamQuery core.missionsDb
      "INSERT INTO missions(id,owner_user_id,project) VALUES('ttl-owner','alice','ttl-tests');" #[]) "owner fixture"
    let active ← seed mc "active" 1000 5 1000 "ttl-owner"
    let archived ← seed mc "archived" 1000 5 1000 "ttl-owner"
    stop mc archived 1100
    let archiveObserved ← seed mc "archive-observed" 1000 5 1000 "ttl-owner"
    let retry ← seed mc "destroy-retry" 1000 5 1000 "ttl-owner"
    let minimum ← seed mc "minimum" 1000 5 1500 "ttl-owner"
    let fresh ← seed mc "fresh" 1250 5 1250 "ttl-owner"
    let destroys ← IO.mkRef (#[] : Array String)
    let gets ← IO.mkRef (#[] : Array String)
    let usageCalls ← IO.mkRef (#[] : Array String)
    let failDestroy ← IO.mkRef true
    let template := OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat"
    let provider : Provider := { template with
      isStopped := fun state => state == "archived" || state == "stopped"
      get := fun id => do
        gets.modify (·.push id)
        return .ok {
          providerId := id
          state := if id == archived.providerId || id == archiveObserved.providerId then "archived" else "running"
        }
      destroy := fun id => do
        destroys.modify (·.push id)
        if id == retry.providerId && (← failDestroy.get) then
          return .error { code := "unavailable", status := 503 }
        return .ok ()
      usageCents := fun id => do
        usageCalls.modify (·.push id)
        return .ok (if id == active.providerId then some 17 else none)
    }
    let resolve : Resolver := fun _ => pure (.ok provider)
    -- Warning is owner-scoped and idempotent, with no provider work beforehand.
    discard <| requireOk (← tick mc core fleet resolve 1200) "warning tick"
    discard <| requireOk (← tick mc core fleet resolve 1200) "repeat warning tick"
    check ((← gets.get).isEmpty && (← destroys.get).isEmpty && (← usageCalls.get).isEmpty)
      "unexpired and fresh guests incur no provider I/O"
    let warnings ← requireOk (← execParamQuery core.missionsDb
      "SELECT COUNT(*) FROM mission_events WHERE mission_id='ttl-owner' AND json_extract(payload,'$.code')='managed_machine_expiring';" #[]) "warning count"
    check (cell warnings[1]! 0 == "5") "one owner warning per expiring guest despite repeated tick"

    let first ← requireOk (← tick mc core fleet resolve 1300) "expiry tick"
    check (((first.fieldArr? "reaped").getD #[]).size == 3 &&
      ((first.fieldArr? "pending").getD #[]) == #[.str retry.id]) "active and archived cleanup succeeds; failed destroy stays pending"
    check ((← destroys.get).size == 2 && (← destroys.get).contains active.providerId &&
      (← destroys.get).contains retry.providerId && !(← destroys.get).contains archived.providerId &&
      !(← destroys.get).contains archiveObserved.providerId) "never delete already nonbilling archived disks"
    check ((← gets.get).size == 4 && !(← gets.get).contains minimum.providerId &&
      !(← gets.get).contains fresh.providerId) "minimum lease and fresh guest both defer all provider work"
    check ((← machine mc active.id).status == "destroyed" &&
      (← machine mc archived.id).status == "stopped" &&
      (← machine mc archiveObserved.id).status == "stopped") "running guest destroyed; archived disks retained under stopped lifecycle"
    let pendingMachine ← machine mc retry.id
    check (pendingMachine.status == "destroying" &&
      pendingMachine.expiryCleanupState == "pending") "failed destroy is fenced, not falsely closed"
    checkError (← recordAuthenticatedManagedPoll mc retry.id 1 1300) "managed_machine_expired"
      "fresh heartbeat cannot revive an expired cleanup-pending guest"
    let deferred ← machine mc minimum.id
    check (!deferred.cordoned && deferred.status == "ready" &&
      (← machine mc fresh.id).lastPollSec == 1250) "minimum lease deferral and fresh state preserved"
    let usage ← sql mc
      "SELECT spend_cents,spend_source,state FROM managed_expirations WHERE machine_id=?1;" #[active.id]
    let estimate ← sql mc
      "SELECT spend_cents,spend_source,state FROM managed_expirations WHERE machine_id=?1;" #[archived.id]
    check (cell usage[1]! 0 == "17" && cell usage[1]! 1 == "provider_usage" && cell usage[1]! 2 == "completed" &&
      cell estimate[1]! 0 == "5" && cell estimate[1]! 1 == "lease_reservation_estimate")
      "recorded provider usage is distinct from an explicitly labeled reservation estimate"
    let cleanedEvents ← requireOk (← execParamQuery core.missionsDb
      ("SELECT json_extract(payload,'$.machine_id'),json_extract(payload,'$.spend_cents'),json_extract(payload,'$.spend_source') " ++
       "FROM mission_events WHERE mission_id='ttl-owner' AND json_extract(payload,'$.code')='managed_machine_expiry_cleaned';") #[]) "cleanup event payloads"
    check ((cleanedEvents.extract 1 cleanedEvents.size).any (fun row =>
        cell row 0 == active.id && cell row 1 == "17" && cell row 2 == "provider_usage") &&
      (cleanedEvents.extract 1 cleanedEvents.size).any (fun row =>
        cell row 0 == archived.id && cell row 1 == "5" && cell row 2 == "lease_reservation_estimate"))
      "owner cleanup events report actual usage or honestly labeled estimates"

    failDestroy.set false
    let second ← requireOk (← tick mc core fleet resolve 1301) "retry destroy tick"
    check (((second.fieldArr? "reaped").getD #[]).size == 1 &&
      ((second.fieldArr? "pending").getD #[]).isEmpty &&
      (← machine mc retry.id).status == "destroyed" && (← destroys.get).size == 3)
      "provider destroy failure retries and closes only after acknowledgement"
    let eventsBefore ← requireOk (← execParamQuery core.missionsDb
      "SELECT COUNT(*) FROM mission_events WHERE mission_id='ttl-owner';" #[]) "event count before replay"
    let ioBefore := ((← gets.get).size, (← destroys.get).size, (← usageCalls.get).size)
    discard <| requireOk (← tick mc core fleet resolve 1301) "repeat completed tick"
    let eventsAfter ← requireOk (← execParamQuery core.missionsDb
      "SELECT COUNT(*) FROM mission_events WHERE mission_id='ttl-owner';" #[]) "event count after replay"
    check (cell eventsBefore[1]! 0 == cell eventsAfter[1]! 0 &&
      ioBefore == ((← gets.get).size, (← destroys.get).size, (← usageCalls.get).size))
      "completed repeat tick duplicates neither owner events nor provider work"
    let eventCounts ← requireOk (← execParamQuery core.missionsDb
      ("SELECT json_extract(payload,'$.machine_id'),json_extract(payload,'$.code'),COUNT(*) FROM mission_events " ++
       "WHERE json_extract(payload,'$.code') IN ('managed_machine_expired','managed_machine_expiry_cleaned') " ++
       "GROUP BY json_extract(payload,'$.machine_id'),json_extract(payload,'$.code');") #[]) "expiry event counts"
    let counted := eventCounts.extract 1 eventCounts.size
    let has (id code : String) := counted.any (fun row => cell row 0 == id && cell row 1 == code)
    -- Three guests were serving work at expiry; `archived` was stopped earlier, so it
    -- gets the cleanup notice without the error-level expiry event.
    check (counted.size == 7 && counted.all (fun row => cell row 2 == "1") &&
      #[active.id, archiveObserved.id, retry.id].all (fun id => has id "managed_machine_expired") &&
      #[active.id, archived.id, archiveObserved.id, retry.id].all (fun id => has id "managed_machine_expiry_cleaned") &&
      !has archived.id "managed_machine_expired")
      "live guests get one expired and one cleaned event; an earlier-stopped guest gets only the cleanup notice"
    discard <| requireOk (← tick mc core fleet resolve 1500) "minimum lease boundary tick"
    check ((← machine mc minimum.id).status == "destroyed" &&
      (← destroys.get).contains minimum.providerId && (← machine mc fresh.id).status == "ready" &&
      !(← destroys.get).contains fresh.providerId) "minimum lease cleans exactly at boundary without reaping unexpired guest"
    -- Operator probe: read-only, both id forms, provider view beside Core's row.
    let destroysBefore := (← destroys.get).size
    let live ← inspectMachine mc resolve s!"managed-{fresh.id}" 1500
    let stoppedView ← inspectMachine mc resolve archived.id 1500
    check (live.fieldStr? "id" == some fresh.id && live.fieldStr? "provider_state" == some "running" &&
      live.fieldBool? "provider_billable" == some true && live.fieldBool? "expired" == some false)
      "inspect reports a live billable guest through its node id"
    check (stoppedView.fieldStr? "provider_state" == some "archived" &&
      stoppedView.fieldBool? "provider_billable" == some false) "inspect reports an archived nonbilling guest"
    check ((← inspectMachine mc resolve "x' OR 1=1" 1500).fieldStr? "error" == some "invalid_machine_id" &&
      (← inspectMachine mc resolve "no-such-machine" 1500).fieldStr? "error" == some "managed_machine_not_found" &&
      (← destroys.get).size == destroysBefore && (← machine mc fresh.id).status == "ready")
      "inspect rejects malformed ids and mutates nothing"
  finally
    closeManagedComputeStore mc
    closeCoreStore core

/-- Self-test entry point. All clocks, provider observations, usage and failures
    are injected; only isolated SQLite fixtures under the supplied root are used. -/
def run (root : String) : IO Unit := do
  extensionTests root
  fencingTests root
  reaperTests root

end OrbCore.ManagedTtlTests
