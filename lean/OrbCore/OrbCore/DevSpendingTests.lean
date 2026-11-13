import OrbCore.Managed

namespace OrbCore.DevSpendingTests

open OrbCore.Managed OrbCore.Store OrbBin.Json

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"dev spending: {label}")

private def budgetDenied {α : Type} (result : Except String α) (label : String) : IO Unit := do
  match result with
  | .error err => check (err == "managed_spawn_rejected") label
  | .ok _ => throw (IO.userError s!"dev spending: {label}")

def run (root : String) : IO Unit := do
  check (devDailyCapCeiling none == 500 && devDailyCapCeiling (some "0") == 0 &&
    devDailyCapCeiling (some "125") == 125) "default five-dollar ceiling and explicit operator values"
  for bad in #["", "-1", "invalid", "18446744073709551616"] do
    check (devDailyCapCeiling (some bad) == 0) "invalid cap configuration disables new dev spending"
  check (managedInstanceFor "dev" "/bin/orb-core" == "dev" &&
    managedInstanceFor "prod" "/bin/orb-core-dev" == "dev" &&
    managedInstanceFor "prod" "/bin/orb-core" == "prod") "dev identity covers environment and executable"
  let .ok mc ← openManagedComputeStore (root ++ "/dev-spending.db")
    | throw (IO.userError "dev spending store")
  let dev := { mc with instanceName := "dev", dailyCapCeilingCents := 5 }
  let fleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 100000, maxConcurrent := 100 }
  let machine (id user : String) (cost : UInt64) : ManagedMachine := {
    id := id, sandboxName := "orb-managed-dev-" ++ id, ownerUserId := user,
    ttlMinutes := 5, spentCents := cost }
  let query (sql : String) : IO Unit := do
    let .ok _ ← execParamQuery mc.db sql #[] | throw (IO.userError "dev spending fixture SQL")
  try
    check ((← provisionManagedMachine dev fleet (machine "first" "alice" 3) 90000).isOk) "first dev reservation"
    -- Simulates importing a generous prod cap and resetting a stale legacy
    -- counter: the immutable dev ceiling and ledger must still win.
    let .ok () ← saveManagedFleetConfig mc true true 100000 0 100
      | throw (IO.userError "fleet settings fixture")
    check (!(← provisionManagedMachine dev fleet (machine "over" "bob" 3) 90001).isOk)
      "imported settings, another user and reset counters cannot evade dev cap"
    check ((← provisionManagedMachine dev fleet (machine "boundary" "bob" 2) 90001).isOk)
      "exact remaining budget is admitted across users"
    check (!(← provisionManagedMachine dev fleet (machine "one-more" "alice" 1) 90002).isOk)
      "spending above the ceiling is refused"
    let .ok live ← loadManagedFleetAt dev true true 100000 0 100 90002
      | throw (IO.userError "dev usage projection")
    check (live.instanceName == "dev" && live.instanceDailyCapCents? == some 5 &&
      live.dailyCapCents == 5 && live.spentTodayCents == 5) "usage reports dev attribution, effective cap and UTC-day commitments"
    let .ok usage := OrbBin.Json.parse (renderManagedBudgetJson live)
      | throw (IO.userError "dev usage JSON")
    check (usage.fieldStr? "instance" == some "dev" && usage.fieldUInt64? "instance_daily_cap_cents" == some 5 &&
      usage.fieldStr? "cost_basis" == some "rental_commitments") "usage carries explicit instance and accounting basis"
    let .ok ownUsage := OrbBin.Json.parse (renderManagedBudgetJson live (some "alice") 3)
      | throw (IO.userError "own usage JSON")
    check (ownUsage.fieldUInt64? "spent_today_cents" == some 3 && ownUsage.fieldStr? "instance" == some "dev")
      "instance attribution preserves user-scoped spending"
    let .ok item := OrbBin.Json.parse (renderManagedMachineItemJson (machine "first" "alice" 3))
      | throw (IO.userError "dev machine JSON")
    check (item.fieldStr? "instance" == some "dev" &&
      managedMachineInstance "orb-managed-production-name" == "prod") "provider-visible names and machine rows distinguish dev"
    query "UPDATE managed_machines SET phase_code=1,status='ready',provider_id='synthetic-provider' WHERE id='first';"
    let quote := fun (_ : String) (minutes : UInt64) => Except.ok ((minutes * 3 + 4) / 5)
    budgetDenied (← prepareManagedExtension dev fleet "first" "over-cap-extension" 5 90002 quote)
      "extensions use the same authoritative dev budget before provider I/O"
    query "UPDATE managed_machines SET phase_code=2,status='stopped' WHERE id='first';"
    budgetDenied (← prepareManagedResume dev fleet "first" "over-cap-resume" "synthetic-enrollment" 5 3 90003 90100)
      "resumes use the same authoritative dev budget before provider I/O"
    check ((← provisionManagedMachine dev { fleet with dailyCapCents := 5, spentTodayCents := 5 } (machine "next-day" "alice" 5) 180000).isOk)
      "new UTC day receives a fresh daily budget even with a stale exhausted caller snapshot"
    let .ok nextDay ← loadManagedFleetAt dev true true 100000 0 100 180001
      | throw (IO.userError "next day usage")
    check (nextDay.spentTodayCents == 5) "prior days are excluded from today's spend"
    -- Failures cannot fall back to a mutable counter and admit a rental.
    query "DROP TABLE managed_cost_reservations;"
    check (!(← loadManagedFleetAt dev true true 100000 0 100 180001).isOk &&
      !(← provisionManagedMachine dev fleet (machine "missing-ledger" "alice" 1) 180002).isOk)
      "unavailable ledger fails closed"
  finally closeManagedComputeStore mc

  let .ok prod ← openManagedComputeStore (root ++ "/prod-spending.db")
    | throw (IO.userError "prod spending store")
  try
    check ((← provisionManagedMachine { prod with instanceName := "prod", dailyCapCeilingCents := 5 }
      fleet { machine "prod-fixture" "alice" 6 with sandboxName := "orb-managed-prod-fixture" } 90000).isOk)
      "dev ceiling does not change production admission"
  finally closeManagedComputeStore prod

  let racePath := root ++ "/dev-spending-race.db"
  let .ok first ← openManagedComputeStore racePath | throw (IO.userError "first concurrent store")
  try
    let .ok second ← openManagedComputeStore racePath | throw (IO.userError "second concurrent store")
    try
      let a ← IO.asTask (provisionManagedMachine { first with instanceName := "dev", dailyCapCeilingCents := 5 }
        fleet (machine "race-a" "alice" 4) 90000)
      let b ← IO.asTask (provisionManagedMachine { second with instanceName := "dev", dailyCapCeilingCents := 5 }
        fleet (machine "race-b" "bob" 4) 90000)
      let .ok ra := a.get | throw (IO.userError "first reservation task")
      let .ok rb := b.get | throw (IO.userError "second reservation task")
      check (ra.isOk != rb.isOk) "concurrent users sharing the dev budget cannot overspend"
      if ra.isOk then budgetDenied rb "losing reservation sees the committed budget"
      else budgetDenied ra "losing reservation sees the committed budget"
    finally closeManagedComputeStore second
  finally closeManagedComputeStore first

end OrbCore.DevSpendingTests
