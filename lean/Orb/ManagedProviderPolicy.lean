/-!
Managed provider admission policies, written before their Core I/O adapters.

Human Spec Card (Th0rgal/orb, base f3863239c; this file and the reserved-seal
route in OrbCore.Control / OrbCore.SecretAndApproval): only an authenticated
operator may initiate a vault-to-Core seal; mission credentials and managed-node
callers never acquire this authority. Positive trace: (admin=true, mission=false,
managed=false) admits. Theorems below cover the three extracted authority flags,
not HTTP authentication, token classification, Bitwarden, filesystem or AEAD.
Those are the I/O TCB and require route/transport tests. No input-domain relaxation
or existing lifecycle-spec change is made here.
-/
namespace Orb.ManagedProviderPolicy

/-- Core evaluates this only after authenticating the HTTP principal. -/
def maySeal (admin mission managed : Bool) : Bool :=
  admin && !mission && !managed

/-- Observable authority requirement, independent of the boolean implementation. -/
def SealAuthority (admin mission managed : Bool) : Prop :=
  admin = true ∧ mission = false ∧ managed = false

theorem seal_authority_iff (admin mission managed : Bool) :
    maySeal admin mission managed = true ↔ SealAuthority admin mission managed := by
  simp [maySeal, SealAuthority, and_assoc]

theorem seal_operator_positive : maySeal true false false = true := by decide

theorem seal_mission_rejected (admin managed : Bool) :
    maySeal admin true managed = false := by
  cases admin <;> cases managed <;> decide

theorem seal_managed_rejected (admin mission : Bool) :
    maySeal admin mission true = false := by
  cases admin <;> cases mission <;> decide

/- Deliberately buggy policies and their counterexamples live in
   Orb.ManagedProviderSealingMutants, imported by the native sealing tests. -/

end Orb.ManagedProviderPolicy
