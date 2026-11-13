import Orb.ManagedProviderAvailability

namespace Orb.ManagedProviderAvailabilityMutants

open Orb.ManagedProviderAvailability

/-- Mutation ignores observed capacity and treats the operator toggle as capacity. -/
def ignoresCapacityMutant (enabled : Bool) (_status : Status) : Bool := enabled

theorem saturated_mutant_counterexample :
    ignoresCapacityMutant true .saturated = true ∧ maySpawn true .saturated = false := by decide

/-- Historical bug: a retained Boat flag silently re-enables a disabled fleet. -/
def boatFlagEnablesFleetMutant (current : Bool) (requested : Option Bool) (boat : Bool) : Bool :=
  current || requested.getD false || boat

theorem credential_edit_mutant_counterexample :
    boatFlagEnablesFleetMutant false none true = true ∧
    fleetAfterProviderUpdate false none = false := by decide

end Orb.ManagedProviderAvailabilityMutants
