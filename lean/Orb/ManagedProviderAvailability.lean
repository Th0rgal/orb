/-!
Provider availability admission, specified before wiring Core's availability I/O.

Spec Card (Th0rgal/orb@31f24317b; this module and the shared configured-spawn
preflight): saturation and unknown capacity never authorize rental, even when an
operator enabled the provider. Available/degraded capacity may rent only when
enabled. Positive trace: enabled + available admits; enabled + saturated rejects.
The gate is read-only: it returns a decision, not a changed enabled flag. HTTP
capacity extraction, caching, authenticated toggle reads and provider races are
I/O TCB; this theorem does not certify them or promise subsequent creation succeeds.
-/
namespace Orb.ManagedProviderAvailability

inductive Status where
  | available
  | degraded
  | saturated
  | unknown
  deriving DecidableEq, BEq, Repr

def maySpawn (enabled : Bool) (status : Status) : Bool :=
  enabled && (match status with | .available | .degraded => true | _ => false)

def Permitted (enabled : Bool) (status : Status) : Prop :=
  enabled = true ∧ status ≠ .saturated ∧ status ≠ .unknown

theorem admission_iff (enabled : Bool) (status : Status) :
    maySpawn enabled status = true ↔ Permitted enabled status := by
  cases enabled <;> cases status <;> simp [maySpawn, Permitted]

theorem available_positive : maySpawn true .available = true := by decide

theorem degraded_positive : maySpawn true .degraded = true := by decide

theorem disabled_rejected (status : Status) : maySpawn false status = false := by
  cases status <;> decide

theorem saturated_rejected (enabled : Bool) : maySpawn enabled .saturated = false := by
  cases enabled <;> decide

/-- Editing a provider can explicitly opt into the fleet, but absent/false
    provider intent cannot enable or disable the independent global switch. -/
def fleetAfterProviderUpdate (current : Bool) (requested : Option Bool) : Bool :=
  current || requested.getD false

theorem credential_update_preserves_global (current : Bool) :
    fleetAfterProviderUpdate current none = current := by
  cases current <;> decide

theorem provider_disable_preserves_global (current : Bool) :
    fleetAfterProviderUpdate current (some false) = current := by
  cases current <;> decide

theorem explicit_enable_positive : fleetAfterProviderUpdate false (some true) = true := by decide

end Orb.ManagedProviderAvailability
