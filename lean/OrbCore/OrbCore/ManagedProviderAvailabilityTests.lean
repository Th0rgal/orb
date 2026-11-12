import OrbCore.ManagedProvisioning
import OrbCore.ManagedProviderBoat
import Orb.ManagedProviderAvailabilityMutants

namespace OrbCore.ManagedProviderAvailabilityTests

open OrbCore.Managed OrbCore.ManagedProvider OrbCore.ManagedProvisioning OrbCore.Store

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed provider availability: {label}")

private def expectError {α : Type} (result : Except String α) (expected label : String) : IO Unit := do
  match result with
  | .error actual => check (actual == expected) s!"{label}: expected {expected}, got {actual}"
  | .ok _ => throw (IO.userError s!"managed provider availability: {label}: unexpectedly accepted")

private def checkNoReservations (mc : ManagedComputeStore) : IO Unit := do
  let .ok machines ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_machines;" #[]
    | throw (IO.userError "availability machine count failed")
  let .ok costs ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_cost_reservations;" #[]
    | throw (IO.userError "availability reservation count failed")
  check (machines.size == 2 && cellU64 machines[1]! 0 == 0 &&
    costs.size == 2 && cellU64 costs[1]! 0 == 0) "rejection creates neither VM rows nor cost reservations"

/-- Native, local-only replay of advisory availability and the durable operator
    toggle. Boat's transport is a tripwire, never a network client. Importing the
    mutant suite also checks the two-sided admission proof in this test target. -/
def run (root : String) : IO Unit := do
  let path := s!"{root}/provider-availability.db"
  let .ok mc ← openManagedComputeStore path
    | throw (IO.userError "availability store open failed")
  try
    let requests ← IO.mkRef (#[] : Array Request)
    let observations ← IO.mkRef (0 : Nat)
    let status ← IO.mkRef Orb.ManagedProviderAvailability.Status.available
    let unavailable ← IO.mkRef false
    let transport : Transport := fun request => do
      requests.modify (·.push request)
      return .error { code := "availability_test_unexpected_provider_io" }
    let baseProvider := boat transport (fun _ => pure ())
    let machine : ManagedMachine := {
      id := "availability-capacity", sandboxName := "orb-availability-capacity", provider := "leanci",
      size := "small", ttlMinutes := 5, spentCents := 1, nodeBootEpoch := 1,
      deletableAtSec := 1000
    }
    let spec : SpawnSpec := {
      name := machine.sandboxName, size := machine.size, ttlSeconds := 300,
      idempotencyKey := "availability-capacity-request"
    }
    let provider : Provider := { baseProvider with
      name := "leanci"
      availability := fun supplied => do
        observations.modify (· + 1)
        check (supplied.name == spec.name && supplied.size == spec.size &&
          supplied.ttlSeconds == spec.ttlSeconds && supplied.idempotencyKey == spec.idempotencyKey)
          "preflight forwards the requested spawn spec"
        if ← unavailable.get then return .error { code := "mock_availability_failed" }
        return .ok { status := (← status.get) }
    }
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
    let cfg : BootstrapConfig := { coreUrl := "https://core.example", script := "#!/bin/bash\nexit 0\n" }
    let runtime : Runtime := {
      nowEpoch := pure 1000, monotonicMs := pure 0, sleepMs := fun _ => pure ()
    }

    -- Boat explicitly allows admission when its API exposes no capacity signal.
    -- Providers without a supported observation must instead fail closed.
    let .ok defaultObservation ← baseProvider.availability spec
      | throw (IO.userError "Boat availability failed")
    check (defaultObservation.status == .available && defaultObservation.reason == "capacity_not_exposed")
      "Boat explicitly reports available when capacity is not exposed"
    let unknownProvider : Provider := { baseProvider with
      availability := fun _ => pure (.ok { status := .unknown })
    }
    expectError (← preflightAvailability mc fleet unknownProvider spec)
      "managed_provider_availability_unavailable" "unsupported availability fails closed"
    let .ok defaultEnabled ← ManagedProviderSettings.isEnabled mc "leanci"
      | throw (IO.userError "default enabled lookup failed")
    check defaultEnabled "an absent operator setting defaults to enabled"
    check (← preflightAvailability mc fleet baseProvider spec).isOk "default availability permits preflight"

    for observed in #[Orb.ManagedProviderAvailability.Status.available, .degraded, .saturated, .unknown] do
      status.set observed
      let result ← preflightAvailability mc fleet provider spec
      match observed with
      | .available => check result.isOk "available permits admission"
      | .degraded => check result.isOk "degraded still permits admission"
      | .saturated => expectError result "provider_at_capacity" "saturated preflight"
      | .unknown => expectError result "managed_provider_availability_unavailable" "unknown preflight"
    check ((← observations.get) == 4) "all four statuses are observed"

    -- Test the actual spawn boundary, not just the advisory helper: rejection
    -- must precede both the local reservation and Boat's create request.
    status.set .saturated
    expectError (← spawnManagedWorker mc fleet machine provider spec cfg runtime)
      "provider_at_capacity" "saturated spawn"
    checkNoReservations mc
    check ((← requests.get).isEmpty) "capacity rejection makes no provider create or other transport calls"
    let .ok stillEnabled ← ManagedProviderSettings.isEnabled mc "leanci"
      | throw (IO.userError "enabled lookup after saturation failed")
    check stillEnabled "observed saturation does not disable a default-enabled provider"
    let .ok settings ← execParamQuery mc.db
        "SELECT provider FROM managed_provider_settings WHERE provider=?1;" #["leanci"]
      | throw (IO.userError "availability settings query failed")
    check (settings.size == 1) "availability does not persist an operator toggle"

    status.set .unknown
    expectError (← spawnManagedWorker mc fleet machine provider spec cfg runtime)
      "managed_provider_availability_unavailable" "unknown spawn"
    unavailable.set true
    expectError (← preflightAvailability mc fleet provider spec)
      "managed_provider_availability_unavailable" "failed observation"
    unavailable.set false

    -- Boat's legacy switch applies only to Boat, not the non-Boat table toggle.
    status.set .available
    check (← preflightAvailability mc { fleet with boatEnabled := false } provider spec).isOk
      "Boat's legacy switch does not disable leanci"
    let beforeSwitches ← observations.get
    expectError (← preflightAvailability mc { fleet with enabled := false } provider spec)
      "provider_disabled" "global disabled"
    expectError (← preflightAvailability mc { fleet with boatEnabled := false } { provider with name := "boat" } spec)
      "provider_disabled" "Boat disabled"
    check ((← observations.get) == beforeSwitches) "disabled fleet switches skip availability"

    let .ok () ← ManagedProviderSettings.setEnabled mc "leanci" false "2026-11-12T00:00:00Z"
      | throw (IO.userError "persist disabled provider failed")
    status.set .available
    let .ok observedAvailable ← provider.availability spec
      | throw (IO.userError "available observation failed")
    check (observedAvailable.status == .available) "disabled provider can still be observed available"
    let beforeDisabled ← observations.get
    expectError (← preflightAvailability mc fleet provider spec) "provider_disabled" "operator disabled preflight"
    expectError (← spawnManagedWorker mc fleet machine provider spec cfg runtime)
      "provider_disabled" "operator disabled spawn"
    check ((← observations.get) == beforeDisabled) "operator disabled rejects before availability"
    let .ok remainsDisabled ← ManagedProviderSettings.isEnabled mc "leanci"
      | throw (IO.userError "disabled lookup failed")
    check (!remainsDisabled) "observed available never re-enables a persisted disabled provider"

    -- `fleet` is the pre-toggle snapshot. Reservation must reread the durable
    -- setting under its transaction even when the caller bypasses preflight.
    expectError (← provisionManagedMachine mc fleet machine 1000)
      "provider_disabled" "reservation rechecks operator toggle with stale fleet"
    checkNoReservations mc
    check ((← requests.get).isEmpty) "all availability rejections rent nothing"

    -- Boat retains exactly one operator-toggle owner: the legacy fleet row.
    let .ok () ← saveManagedFleetConfig mc true false fleet.dailyCapCents 0 fleet.maxConcurrent
      | throw (IO.userError "disable legacy Boat configuration failed")
    let .ok boatDisabled ← ManagedProviderSettings.isEnabled mc "boat"
      | throw (IO.userError "legacy Boat disabled lookup failed")
    check (!boatDisabled) "Boat enabled lookup reads the legacy disabled switch"
    let .ok () ← saveManagedFleetConfig mc true true fleet.dailyCapCents 0 fleet.maxConcurrent
      | throw (IO.userError "enable legacy Boat configuration failed")
    let .ok boatEnabled ← ManagedProviderSettings.isEnabled mc "boat"
      | throw (IO.userError "legacy Boat enabled lookup failed")
    check boatEnabled "Boat enabled lookup reads the legacy enabled switch"
    let .ok boatSettings ← execParamQuery mc.db
        "SELECT provider FROM managed_provider_settings WHERE provider=?1;" #["boat"]
      | throw (IO.userError "Boat settings ownership query failed")
    check (boatSettings.size == 1) "Boat configuration never creates a second toggle in provider settings"

    -- Fresh resumes must reject capacity before preparing an intent or charging
    -- another lease. This synthetic stopped VM needs no enrollment or provider.
    let stopped : ManagedMachine := { machine with
      id := "availability-stopped-boat"
      provider := "boat"
      providerId := "availability-stopped-provider"
    }
    let .ok _ ← provisionManagedMachine mc fleet stopped 1000
      | throw (IO.userError "stopped Boat reservation fixture failed")
    let .ok _ ← execParamQuery mc.db
        "UPDATE managed_machines SET status='stopped',phase_code=2 WHERE id=?1;" #[stopped.id]
      | throw (IO.userError "stopped Boat fixture update failed")
    let .ok beforeResumeCosts ← execParamQuery mc.db
        "SELECT COUNT(*),COALESCE(SUM(cents),0) FROM managed_cost_reservations;" #[]
      | throw (IO.userError "resume cost baseline query failed")
    let .ok beforeResumeSpend ← execParamQuery mc.db
        "SELECT spent_today_cents FROM managed_fleet_state WHERE singleton_id=1;" #[]
      | throw (IO.userError "resume fleet spend baseline query failed")
    let resumeProvider : Provider := { baseProvider with
      availability := fun _ => do return .ok { status := (← status.get) }
    }
    let rejectResume := fun (key expected : String) => do
      expectError (← resumeManagedWorker mc fleet stopped.id key 5 resumeProvider cfg runtime)
        expected "fresh resume availability rejection"
      let .ok intents ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_resume_intents;" #[]
        | throw (IO.userError "resume intent count failed")
      check (intents.size == 2 && cellU64 intents[1]! 0 == 0)
        "resume availability rejection creates no intent"
      let .ok afterCosts ← execParamQuery mc.db
          "SELECT COUNT(*),COALESCE(SUM(cents),0) FROM managed_cost_reservations;" #[]
        | throw (IO.userError "resume rejected cost query failed")
      let .ok afterSpend ← execParamQuery mc.db
          "SELECT spent_today_cents FROM managed_fleet_state WHERE singleton_id=1;" #[]
        | throw (IO.userError "resume rejected fleet spend query failed")
      check (afterCosts == beforeResumeCosts && afterSpend == beforeResumeSpend)
        "resume rejection adds no reservation or fleet spend"
      check ((← requests.get).isEmpty) "resume rejection makes no provider transport calls"
    status.set .saturated
    rejectResume "availability-resume-saturated" "provider_at_capacity"
    status.set .unknown
    rejectResume "availability-resume-unknown" "managed_provider_availability_unavailable"
  finally
    closeManagedComputeStore mc

  -- Reopening the store proves the toggle is durable rather than cached in the
  -- provider or the caller's fleet value. An enabled control validates the same
  -- five-minute reservation fixture used by the stale-toggle rejection above.
  let .ok reopened ← openManagedComputeStore path
    | throw (IO.userError "availability store reopen failed")
  try
    let .ok enabled ← ManagedProviderSettings.isEnabled reopened "leanci"
      | throw (IO.userError "reopened toggle lookup failed")
    check (!enabled) "disabled toggle survives store reopen"
    let .ok () ← ManagedProviderSettings.setEnabled reopened "leanci" true "2026-11-12T00:01:00Z"
      | throw (IO.userError "re-enable provider failed")
    let .ok _ ← provisionManagedMachine reopened { enabled := true, boatEnabled := true } {
        id := "availability-control", sandboxName := "orb-availability-control", provider := "leanci",
        size := "small", ttlMinutes := 5, spentCents := 1, nodeBootEpoch := 1,
        deletableAtSec := 1000
      } 1000
      | throw (IO.userError "enabled reservation control failed")
  finally
    closeManagedComputeStore reopened

end OrbCore.ManagedProviderAvailabilityTests
