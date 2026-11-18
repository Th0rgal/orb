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
  { enabled := true, boatEnabled := true, dailyCapCents := 10, spentTodayCents := 0 }

private def machine (id : String) (cost : UInt64) : ManagedMachine :=
  { id, sandboxName := "orb-managed-" ++ id, spentCents := cost, ttlMinutes := 60 }

private def bandwidthMachine (id mission : String) : ManagedMachine :=
  { id, sandboxName := "orb-managed-" ++ id, ownerMission := mission,
    size := "small", ttlMinutes := 60 }

private def setBandwidth (st : ManagedComputeStore) (mission json : String) : IO Unit := do
  discard <| require (← saveMissionBudgetConfig st {
    missionId := mission, bandwidthLimitsJson := json })

private def setVmLimits (st : ManagedComputeStore) (mission json : String) : IO Unit := do
  discard <| require (← saveMissionBudgetConfig st {
    missionId := mission, vmLimitsJson := json })

private def configure (st : ManagedComputeStore) : IO Unit := do
  discard <| require (← saveManagedFleetConfig st true true fleet.dailyCapCents
    fleet.spentTodayCents fleet.maxConcurrent)

private def requireAdmission {α : Type} (label : String) (value : Except String α) : IO α :=
  match value with
  | .ok result => pure result
  | .error error => throw (IO.userError s!"{label}: {error}")

private def reservationCount (st : ManagedComputeStore) : IO UInt64 := do
  let rows ← require (← execParamQuery st.db
    "SELECT COUNT(*) FROM managed_cost_reservations;" #[])
  pure (if rows.size > 1 then cellU64 rows[1]! 0 else 0)

private def refusedAs (expected : String) (st : ManagedComputeStore) (id : String) (cost now : UInt64) : IO Unit := do
  let before ← reservationCount st
  match ← provisionManagedMachine st fleet (machine id cost) now with
  | .ok _ => throw (IO.userError s!"unexpected admission: {id}")
  | .error error => check (error == expected) s!"{id}: named budget refusal (got {error})"
  check ((← getManagedMachine? st id).isNone) s!"{id}: refusal creates no provider work"
  let after ← reservationCount st
  check (after == before) s!"{id}: refusal creates no reservation"

private def refusedWithFleet (expected : String) (st : ManagedComputeStore)
    (snapshot : ManagedFleetState) (id : String) (cost now : UInt64) : IO Unit := do
  let before ← reservationCount st
  match ← provisionManagedMachine st snapshot (machine id cost) now with
  | .ok _ => throw (IO.userError s!"unexpected admission: {id}")
  | .error error => check (error == expected) s!"{id}: named budget refusal (got {error})"
  check ((← getManagedMachine? st id).isNone) s!"{id}: refusal creates no provider work"
  let after ← reservationCount st
  check (after == before) s!"{id}: refusal creates no reservation"

private def refusedBandwidth (expected : String) (st : ManagedComputeStore)
    (mission id : String) (_cost now : UInt64) : IO Unit := do
  let before ← reservationCount st
  match ← provisionManagedMachine st fleet (bandwidthMachine id mission) now with
  | .ok _ => throw (IO.userError s!"unexpected admission: {id}")
  | .error error => check (error == expected) s!"{id}: named budget refusal (got {error})"
  check ((← getManagedMachine? st id).isNone) s!"{id}: refusal creates no provider work"
  let after ← reservationCount st
  check (after == before) s!"{id}: refusal creates no reservation"

private def refused (st : ManagedComputeStore) (id : String) (cost now : UInt64) : IO Unit :=
  refusedAs "managed_spawn_rejected" st id cost now

/-- All times are supplied explicitly; there is no wall clock or provider here.
    Fails at 27d2d096: no; guards the permanent marker across two midnights. -/
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
    sql reopened "UPDATE managed_fleet_state SET spent_today_cents=99;"
    let later ← require (← loadManagedFleetAt reopened true true 10 0 100 172801)
    check (later.spentTodayCents == 0) "midnightAndReload: legacy baseline is not reread"
    let baselines ← require (← execParamQuery reopened.db
      "SELECT COUNT(*) FROM managed_global_budget_baseline;" #[])
    check (baselines.size > 1 && cellU64 baselines[1]! 0 == 1)
      "midnightAndReload: one permanent legacy baseline"
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

/-- Fails at 27d2d096: yes; its lifetime subtraction loses seven cents. -/
def priorDayReservationMigration (root : String) : IO Unit := do
  let path := root ++ "/budget-prior-day.db"
  let st ← require (← openManagedComputeStore path)
  try
    configure st
    discard <| require (← provisionManagedMachine st fleet (machine "prior-day" 7) 86390)
    sql st "UPDATE managed_machines SET phase_code=3,status='destroyed' WHERE id='prior-day';"
    sql st "UPDATE managed_fleet_state SET spent_today_cents=10;"
    sql st "DELETE FROM managed_global_budget_baseline;"
  finally closeManagedComputeStore st
  let reopened ← require (← openManagedComputeStore path)
  try
    let loaded ← require (← loadManagedFleetAt reopened true true 10 0 100 86401)
    check (loaded.spentTodayCents == 10)
      "priorDayReservationMigration: prior-day completed charge is not subtracted"
    refused reopened "prior-day-over" 1 86402
  finally closeManagedComputeStore reopened

def snapshotParity (root : String) : IO Unit := do
  let noRow ← require (← openManagedComputeStore (root ++ "/budget-snapshot-empty.db"))
  try
    refusedWithFleet "managed_spawn_rejected" noRow { fleet with spentTodayCents := 10 }
      "snapshot-spent-no-row" 1 90000
      -- fails at 27d2d096: no; master and this head both refuse the snapshot.
  finally closeManagedComputeStore noRow
  let withBaseline ← require (← openManagedComputeStore (root ++ "/budget-snapshot-baseline.db"))
  try
    configure withBaseline
    sql withBaseline "INSERT INTO managed_global_budget_baseline(day_start,cents) VALUES(0,0);"
    refusedWithFleet "managed_spawn_rejected" withBaseline { fleet with spentTodayCents := 10 }
      "snapshot-spent-baseline" 1 90000
      -- Fails at 27d2d096: yes; master and this head refuse, that head admits.
  finally closeManagedComputeStore withBaseline
  let maxed ← require (← openManagedComputeStore (root ++ "/budget-snapshot-machines.db"))
  try
    configure maxed
    let snapshot := { fleet with maxConcurrent := 1 }
    let snapshot := { snapshot with machines := #[machine "snapshot-live" 0] }
    refusedWithFleet "managed_spawn_rejected" maxed snapshot "snapshot-machines" 1 90000
      -- Fails at 27d2d096: yes; master and this head refuse, that head admits.
  finally closeManagedComputeStore maxed

/-- Fails at 27d2d096: yes; min(snapshot cap, stored cap) rejects the second
    request although its preflight passes and the authoritative cap has room. -/
def storedRowAuthoritative (root : String) : IO Unit := do
  let st ← require (← openManagedComputeStore (root ++ "/budget-stored-row.db"))
  try
    configure st
    discard <| require (← provisionManagedMachine st fleet (machine "stored-first" 1) 90000)
    discard <| require (← provisionManagedMachine st { fleet with dailyCapCents := 1 }
      (machine "stored-second" 1) 90001)
    sql st "UPDATE managed_fleet_state SET daily_cap_cents=2;"
    refused st "stored-cap-over" 1 90002
  finally closeManagedComputeStore st

/-- Fails at 27d2d096: no; unlike the original race, this also requires dated
    rollover (reverting production to master leaves both requests refused). -/
def concurrentGlobalAdmission (root : String) : IO Unit := do
  let path := root ++ "/budget-concurrent.db"
  let a ← require (← openManagedComputeStore path)
  let b ← require (← openManagedComputeStore path)
  try
    configure a
    discard <| require (← provisionManagedMachine a fleet (machine "race-yesterday" 10) 86390)
    sql a "UPDATE managed_machines SET phase_code=3,status='destroyed' WHERE id='race-yesterday';"
    let before ← reservationCount a
    let first ← IO.asTask (provisionManagedMachine a fleet (machine "race-a" 6) 90000)
    let second ← IO.asTask (provisionManagedMachine b fleet (machine "race-b" 6) 90000)
    let .ok ra := first.get | throw (IO.userError "first admission task failed")
    let .ok rb := second.get | throw (IO.userError "second admission task failed")
    check (ra.isOk != rb.isOk) "concurrentGlobalAdmission: exactly one reservation"
    let loser := if ra.isOk then rb else ra
    match loser with
     | .error error => check (error == "managed_spawn_rejected") "concurrentGlobalAdmission: loser sees budget"
     | .ok _ => throw (IO.userError "both requests admitted")
    let after ← reservationCount a
    check (after == before + 1)
      "concurrentGlobalAdmission: loser creates no reservation"
    let loserId := if ra.isOk then "race-b" else "race-a"
    check ((← getManagedMachine? a loserId).isNone)
      "concurrentGlobalAdmission: loser creates no machine"
  finally
    closeManagedComputeStore b
    closeManagedComputeStore a

def bandwidthAdmission (root : String) : IO Unit := do
  let st ← require (← openManagedComputeStore (root ++ "/budget-bandwidth.db"))
  try
    configure st
    -- small is 2 vCPU: cap 3 fits one but not two (4), isolating aggregate refusal.
    setBandwidth st "owner" "{\"compute_vcpu_per_min\":3,\"compute_usd_per_hour\":100,\"protect_root\":false}"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "bw-first" "owner") 90000)
    let beforeOver ← reservationCount st
    match ← provisionManagedMachine st fleet (bandwidthMachine "bw-over" "owner") 90001 with
    | .ok _ => throw (IO.userError "unexpected admission: bw-over")
    | .error error => check (error == "managed_compute_vcpu_bandwidth_exceeded") "bw-over: named budget refusal"
    check ((← getManagedMachine? st "bw-over").isNone) "bw-over: refusal creates no provider work"
    let afterOver ← reservationCount st
    check (afterOver == beforeOver) "bw-over: refusal creates no reservation"
    sql st "UPDATE managed_machines SET phase_code=3,status='destroyed' WHERE id='bw-first';"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "bw-room" "owner") 1)
    -- Cap 2 admits each small VM on its own; a second tests the aggregate bypass.
    setBandwidth st "root-owner" "{\"compute_vcpu_per_min\":2,\"compute_usd_per_hour\":100,\"protect_root\":true}"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "root-first" "root-owner") 2)
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "root-protected" "root-owner") 2)
    setBandwidth st "root-owner" "{\"compute_vcpu_per_min\":1,\"compute_usd_per_hour\":100,\"protect_root\":true}"
    let beforeSingle ← reservationCount st
    refusedBandwidth "managed_compute_vcpu_bandwidth_exceeded" st "root-owner" "root-single-over" 0 90003
    let afterSingle ← reservationCount st
    check (afterSingle == beforeSingle) "root-single-over: refusal creates no reservation"
    setBandwidth st "owner" "{\"compute_vcpu_per_min\":3,\"compute_usd_per_hour\":100,\"protect_root\":false}"
    let beforeAggregate ← reservationCount st
    refusedBandwidth "managed_compute_vcpu_bandwidth_exceeded" st "owner" "bw-aggregate-over" 0 90004
    let afterAggregate ← reservationCount st
    check (afterAggregate == beforeAggregate) "bw-aggregate-over: refusal creates no reservation"
  finally closeManagedComputeStore st

/-- Fails at 27d2d096: no; directly exercises the dollar-rate gate independently
    of vCPU. Boat small costs $0.018/hour: $0.03 fits one but not two. -/
def bandwidthRateAdmission (root : String) : IO Unit := do
  let st ← require (← openManagedComputeStore (root ++ "/budget-bandwidth-rate.db"))
  try
    configure st
    setBandwidth st "rate-owner" "{\"compute_usd_per_hour\":0.03,\"protect_root\":false}"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "rate-first" "rate-owner") 90000)
    refusedBandwidth "managed_compute_cost_bandwidth_exceeded" st "rate-owner" "rate-aggregate-over" 0 90001
    setBandwidth st "rate-owner" "{\"compute_usd_per_hour\":0.03,\"protect_root\":true}"
    discard <| require (← provisionManagedMachine st fleet (bandwidthMachine "rate-protected" "rate-owner") 90002)
    setBandwidth st "rate-owner" "{\"compute_usd_per_hour\":0.01,\"protect_root\":true}"
    refusedBandwidth "managed_compute_cost_bandwidth_exceeded" st "rate-owner" "rate-single-over" 0 90003
  finally closeManagedComputeStore st

/-- FLT-10: a parent mission's compute bandwidth pool covers its descendants,
    including the impossible single-VM fit and subtree aggregate use, while a
    machine the pool's own mission owns keeps the `protect_root` bypass. -/
def ancestorBandwidthAdmission (root : String) : IO Unit := do
  let core ← require (← openCoreStore (root ++ "/budget-lineage-core"))
  try
    let st ← require (← openManagedComputeStore (root ++ "/budget-lineage.db"))
    let st := { st with missionsDb? := some core.missionsDb }
    try
      configure st
      for (id, parent, owner) in #[
          ("lineage-parent", "", "alice"), ("lineage-child", "lineage-parent", "alice"),
          ("lineage-grandchild", "lineage-child", "alice"),
          ("lineage-outsider", "lineage-parent", "bob")] do
        discard <| require (← execParamQuery core.missionsDb
          "INSERT INTO missions(id,parent_mission_id,owner_user_id,project) VALUES(?1,?2,?3,'p');"
          #[id, parent, owner])
      setBandwidth st "lineage-parent"
        "{\"compute_vcpu_per_min\":3,\"compute_usd_per_hour\":100,\"protect_root\":false}"
      discard <| require (← provisionManagedMachine st fleet
        (bandwidthMachine "lineage-first" "lineage-child") 90000)
      let beforeOver ← reservationCount st
      match ← provisionManagedMachine st fleet
          (bandwidthMachine "lineage-over" "lineage-grandchild") 90001 with
      | .ok _ => throw (IO.userError "unexpected admission: lineage-over")
      | .error error =>
        check (error == "managed_compute_vcpu_bandwidth_exceeded")
          "lineage-over: ancestor pool refuses subtree aggregate"
      check ((← getManagedMachine? st "lineage-over").isNone)
        "lineage-over: refusal creates no provider work"
      let afterOver ← reservationCount st
      check (afterOver == beforeOver) "lineage-over: refusal creates no reservation"
      -- A single VM larger than the whole ancestor ceiling can never be admitted.
      setBandwidth st "lineage-parent"
        "{\"compute_vcpu_per_min\":1,\"compute_usd_per_hour\":100,\"protect_root\":true}"
      refusedBandwidth "managed_compute_vcpu_bandwidth_exceeded" st
        "lineage-child" "lineage-single-over" 0 90002
      -- The root mission's own VM bypasses aggregate pacing, a child's VM does not.
      setBandwidth st "lineage-parent"
        "{\"compute_vcpu_per_min\":3,\"compute_usd_per_hour\":100,\"protect_root\":true}"
      discard <| require (← provisionManagedMachine st fleet
        (bandwidthMachine "lineage-root" "lineage-parent") 90003)
      refusedBandwidth "managed_compute_vcpu_bandwidth_exceeded" st
        "lineage-child" "lineage-child-over" 0 90004
      -- An ancestor pool never crosses into another owner's mission tree.
      discard <| require (← provisionManagedMachine st fleet
        { bandwidthMachine "lineage-outsider" "lineage-outsider" with ownerUserId := "bob" } 90005)
    finally closeManagedComputeStore st
  finally closeCoreStore core

/-- FLT-09: mission and provider concurrency caps are admission inputs, and an
    ancestor's cap covers its same-owner subtree instead of only its own row. -/
def ancestorConcurrencyAdmission (root : String) : IO Unit := do
  let core ← require (← openCoreStore (root ++ "/budget-concurrency-lineage-core"))
  try
    let st ← require (← openManagedComputeStore (root ++ "/budget-concurrency-lineage.db"))
    let st := { st with missionsDb? := some core.missionsDb }
    try
      configure st
      for (id, parent, owner) in #[
          ("conc-parent", "", "alice"), ("conc-child", "conc-parent", "alice"),
          ("conc-grandchild", "conc-child", "alice")] do
        discard <| require (← execParamQuery core.missionsDb
          "INSERT INTO missions(id,parent_mission_id,owner_user_id,project) VALUES(?1,?2,?3,'p');"
          #[id, parent, owner])
      setVmLimits st "conc-parent" "{\"max_concurrent\":1}"
      discard <| require (← provisionManagedMachine st fleet
        (bandwidthMachine "conc-first" "conc-child") 90000)
      let beforeMission ← reservationCount st
      refusedBandwidth "managed_mission_concurrency_limit_reached" st
        "conc-grandchild" "conc-mission-over" 0 90001
      check ((← reservationCount st) == beforeMission)
        "conc-mission-over: refusal creates no reservation"
      sql st "UPDATE managed_machines SET phase_code=3,status='destroyed' WHERE id='conc-first';"
      setVmLimits st "conc-parent" "{\"max_concurrent\":8,\"provider_max_concurrent\":{\"boat\":1}}"
      discard <| require (← provisionManagedMachine st fleet
        (bandwidthMachine "conc-provider-first" "conc-child") 90002)
      let beforeProvider ← reservationCount st
      refusedBandwidth "managed_provider_mission_concurrency_limit_reached" st
        "conc-grandchild" "conc-provider-over" 0 90003
      check ((← reservationCount st) == beforeProvider)
        "conc-provider-over: refusal creates no reservation"
    finally closeManagedComputeStore st
  finally closeCoreStore core

def run (root : String) : IO Unit := do
  try midnightAndReload root catch e => throw (IO.userError s!"midnightAndReload: {e}")
  try liveCommitmentAfterReload root catch e => throw (IO.userError s!"liveCommitmentAfterReload: {e}")
  try oldSchemaNonzeroLiveCommitment root catch e => throw (IO.userError s!"oldSchemaNonzeroLiveCommitment: {e}")
  try priorDayReservationMigration root catch e => throw (IO.userError s!"priorDayReservationMigration: {e}")
  try snapshotParity root catch e => throw (IO.userError s!"snapshotParity: {e}")
  try storedRowAuthoritative root catch e => throw (IO.userError s!"storedRowAuthoritative: {e}")
  try concurrentGlobalAdmission root catch e => throw (IO.userError s!"concurrentGlobalAdmission: {e}")
  try bandwidthAdmission root catch e => throw (IO.userError s!"bandwidthAdmission: {e}")
  try bandwidthRateAdmission root catch e => throw (IO.userError s!"bandwidthRateAdmission: {e}")
  try ancestorBandwidthAdmission root catch e => throw (IO.userError s!"ancestorBandwidthAdmission: {e}")
  try ancestorConcurrencyAdmission root catch e => throw (IO.userError s!"ancestorConcurrencyAdmission: {e}")

end OrbCore.ManagedBudgetTests
