/-
Deliberately invalid policies for two-sided sealing regressions. These mutations
are NOT admission specifications: ignored authority inputs are the bug being
exhibited. Keep them separate from the audited production policy, as with
Orb.ManagedNodeMutants, rather than obscuring a real mutant to satisfy a linter.
-/
import Orb.ManagedProviderPolicy

namespace Orb.ManagedProviderSealingMutants

open Orb.ManagedProviderPolicy

/-- Weakening the gate to admin-only loses mission and managed-node confinement. -/
def adminOnlyMutant (admin _mission _managed : Bool) : Bool := admin

theorem admin_only_mutant_counterexample :
    adminOnlyMutant true true false = true ∧ maySeal true true false = false := by decide

theorem managed_admin_mutant_counterexample :
    adminOnlyMutant true false true = true ∧ maySeal true false true = false := by decide

end Orb.ManagedProviderSealingMutants
