import OrbCore.Managed

namespace OrbCore.ManagedBudgetTests

open OrbCore.Managed OrbCore.Store

private def require {α : Type} (value : Except String α) : IO α :=
  match value with
  | .ok result => pure result
  | .error error => throw (IO.userError error)

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"managed budget: {label}")

private def sql (st : ManagedComputeStore) (query : String) : IO Unit := do
  discard <| require (← execParamQuery st.db query #[])

private def fleet : ManagedFleetState :=
  { enabled := true, boatEnabled := true, dailyCapCents := 10 }

private def machine (id : String) (cost : UInt64) : ManagedMachine :=
  { id, sandboxName := "orb-managed-" ++ id, spentCents := cost, ttlMinutes := 60 }

private def bandwidthMachine (id mission : String) : ManagedMachine :=
  { id, sandboxName := "orb-managed-" ++ id, ownerMission := mission,
    size := "small", ttlMinutes := 60 }

private def setBandwidth (st : ManagedComputeStore) (mission json : String) : IO Unit := do
  discard <| require (← saveMissionBudgetConfig st {
    missionId := mission, bandwidthLimitsJson := json })

private def configure (st : ManagedComputeStore) : IO Unit := do
  discard <| require (← saveManagedFleetConfig st true true fleet.dailyCapCents
    fleet.spentTodayCents fleet.maxConcurrent)

private def requireAdmission {α : Type} (label : String) (value : Except String α) : IO α :=
  match value with
  | .ok result => pure result
  | .error error => throw (IO.userError s!"{label}: {error}")

private def refusedAs (expected : String) (st : ManagedComputeStore) (id : String) (cost now : UInt64) : IO Unit := do
  match ← provisionManagedMachine st fleet (machine id cost) now with
  | .ok _ => throw (IO.userError s!"unexpected admission: {id}")
  | .error error => check (error == expected) s!"{id}: named budget refusal (got {error})"
  check ((← getManagedMachine? st id).isNone) s!"{id}: refusal creates no provider work"

private def refused (st : ManagedComputeStore) (id : String) (cost now : UInt64) : IO Unit :=
  refusedAs "managed_spawn_rejected" st id cost now

/-- All times are supplied explicitly; there is no wall clock or provider here. -/
def midnightAndReload (root : String) : IO Unit := do
  let path := root ++ "/budget-midnight.db"
  let st ← require (← openManagedComputeStore path)
  try
    configure st
    discard <| requireAdmission "day-one" (← provisionManagedMachine st fleet (machine "day-one" 10) 86390)
    refused st "day-one-over" 1 86399
    refused st "live-midnight" 1 86401
    sql st "UPDATE managed_machines SET phase_code=3,status='destroyed' WHERE id='day-one';"
  finally closeManagedComputeStore st
  let reopened ← require (← openManagedComputeStore path)
  try
    configure reopened
    let snapshot ← require (← loadManagedFleetAt reopened true true 10 10 100 86402)
    check (snapshot.spentTodayCents == 0) "midnightAndReload: old completed commitments roll off"
    discard <| require (← provisionManagedMachine reopened { fleet with spentTodayCents := 10 }
      (machine "day-two" 10) 86402)
    refused reopened "day-two-over" 1 86403
  finally closeManagedComputeStore reopened

def liveCommitmentAfterReload (root : String) : IO Unit := do
  let path := root ++ "/budget-live-reload.db"
  let st ← require (← openManagedComputeStore path)
  try
    configure st
    discard <| require (← provisionManagedMachine st fleet (machine "live" 7) 86390)
  finally closeManagedComputeStore st
  let reopened ← require (← openManagedComputeStore path)
  try
    configure reopened
    refused reopened "live-over" 4 86401
    discard <| require (← provisionManagedMachine reopened fleet (machine "fits" 3) 86401)
    let snapshot ← require (← loadManagedFleetAt reopened true true 10 0 100 86402)
    check (snapshot.spentTodayCents == 10) "liveCommitmentAfterReload: live plus today's commitments"
  finally closeManagedComputeStore reopened

def oldSchemaNonzeroLiveCommitment (root : String) : IO Unit := do
  let path := root ++ "/budget-old-schema.db"
  -- Construct today's schema by removing only the new additive table, then
  -- reopen through the production migration. Eight cents, including one live
  -- three-cent commitment, must remain eight rather than eleven or three.
  let old ← require (← openManagedComputeStore path)
  try
    configure old
    discard <| require (← provisionManagedMachine old fleet (machine "legacy-live" 3) 86390)
    sql old "UPDATE managed_fleet_state SET spent_today_cents=8;"
    sql old "DELETE FROM managed_global_budget_baseline;"
  finally closeManagedComputeStore old
  let migrated ← require (← openManagedComputeStore path)
  try
    let first ← require (← loadManagedFleetAt migrated true true 10 0 100 86391)
    check (first.spentTodayCents == 8) "oldSchemaNonzeroLiveCommitment: preserve old total once"
    refused migrated "legacy-over" 3 86392
    discard <| require (← provisionManagedMachine migrated fleet (machine "legacy-fit" 2) 86392)
    sql migrated "UPDATE managed_machines SET phase_code=3,status='destroyed' WHERE id='legacy-fit';"
  finally closeManagedComputeStore migrated
  let reloaded ← require (← openManagedComputeStore path)
  try
    let sameDay ← require (← loadManagedFleetAt reloaded true true 10 0 100 86393)
    check (sameDay.spentTodayCents == 10) "oldSchemaNonzeroLiveCommitment: restart is idempotent"
    let nextDay ← require (← loadManagedFleetAt reloaded true true 10 0 100 86401)
    check (nextDay.spentTodayCents == 3) "oldSchemaNonzeroLiveCommitment: only live commitment crosses midnight"
    discard <| require (← provisionManagedMachine reloaded fleet (machine "legacy-next-day" 7) 86401)
  finally closeManagedComputeStore reloaded

def concurrentGlobalAdmission (root : String) : IO Unit := do
  let path := root ++ "/budget-concurrent.db"
  let a ← require (← openManagedComputeStore path)
  let b ← require (← openManagedComputeStore path)
  try
    configure a
    let first ← IO.asTask (provisionManagedMachine a fleet (machine "race-a" 6) 90000)
    let second ← IO.asTask (provisionManagedMachine b fleet (machine "race-b" 6) 90000)
    let .ok ra := first.get | throw (IO.userError "first admission task failed")
    let .ok rb := second.get | throw (IO.userError "second admission task failed")
    check (ra.isOk != rb.isOk) "concurrentGlobalAdmission: exactly one reservation"
    let loser := if ra.isOk then rb else ra
    match loser with
    | .error error => check (error == "managed_spawn_rejected") "concurrentGlobalAdmission: loser sees budget"
    | .ok _ => throw (IO.userError "both requests admitted")
  finally
    closeManagedComputeStore b
    closeManagedComputeStore a

def bandwidthAdmission (root : String) : IO Unit := do
  let st ← require (← openManagedComputeStore (root ++ "/budget-bandwidth.db"))
  try
    configure st
    setBandwidth st "owner" "{\"compute_vcpu_per_min\":3,\"compute_usd_per_hour\":100,\"protect_root\":false}"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "bw-first" "owner") 90000)
    match ← provisionManagedMachine st fleet (bandwidthMachine "bw-over" "owner") 90001 with
    | .ok _ => throw (IO.userError "unexpected admission: bw-over")
    | .error error => check (error == "managed_compute_vcpu_bandwidth_exceeded") "bw-over: named budget refusal"
    check ((← getManagedMachine? st "bw-over").isNone) "bw-over: refusal creates no provider work"
    sql st "UPDATE managed_machines SET phase_code=3,status='destroyed' WHERE id='bw-first';"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "bw-room" "owner") 1)
    setBandwidth st "root-owner" "{\"compute_vcpu_per_min\":2,\"compute_usd_per_hour\":100,\"protect_root\":true}"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "root-protected" "root-owner") 2)
  finally closeManagedComputeStore st

def run (root : String) : IO Unit := do
  try midnightAndReload root catch e => throw (IO.userError s!"midnightAndReload: {e}")
  try liveCommitmentAfterReload root catch e => throw (IO.userError s!"liveCommitmentAfterReload: {e}")
  try oldSchemaNonzeroLiveCommitment root catch e => throw (IO.userError s!"oldSchemaNonzeroLiveCommitment: {e}")
  try concurrentGlobalAdmission root catch e => throw (IO.userError s!"concurrentGlobalAdmission: {e}")
  try bandwidthAdmission root catch e => throw (IO.userError s!"bandwidthAdmission: {e}")

end OrbCore.ManagedBudgetTests
