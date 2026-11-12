/-
Fast inner-loop entry point for the same managed-provider contract tests used by
Core's full self-test. No live provider/vault calls. Full Core CI remains required.
-/
import OrbCore.ManagedProviderTests
import OrbCore.ManagedProvisioningTests
import OrbCore.ManagedProviderSealingTests
import OrbCore.ManagedProviderAvailabilityTests

open OrbCore.Store

def main : IO UInt32 := do
  let stamp ← IO.monoNanosNow
  let root := s!"/tmp/orb-managed-provider-test-{stamp}"
  let .ok store ← openCoreStore root
    | do IO.eprintln "managed provider test store unavailable"; return 1
  try
    OrbCore.ManagedProviderTests.run
    OrbCore.ManagedProvisioningTests.run root
    OrbCore.ManagedProviderSealingTests.run root
    OrbCore.ManagedProviderAvailabilityTests.run root
    IO.println "{\"ok\":true,\"suite\":\"managed-providers\",\"live_provider_calls\":0}"
    return 0
  catch error =>
    IO.eprintln s!"managed provider test failed: {error}"
    return 1
  finally
    closeCoreStore store
