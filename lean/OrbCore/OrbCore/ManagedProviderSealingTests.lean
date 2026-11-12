import OrbCore.ManagedProviderSealing
import Orb.ManagedProviderSealingMutants

namespace OrbCore.ManagedProviderSealingTests

open OrbCore.Managed OrbCore.ManagedProviderSealing OrbBin.PosixExt

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed sealing: {label}")

/-- Synthetic vault values only: authorization precedes lookup and file creation. -/
def run (root : String) : IO Unit := do
  let dataRoot := root ++ "/provider-sealing"
  let calls ← IO.mkRef (#[] : Array String)
  let resolve : Resolver := fun name => do
    calls.modify (·.push name)
    return .ok ("synthetic-test-value-" ++ name)
  for (admin, mission, managed) in #[(false, false, false), (true, true, false), (true, false, true)] do
    check (!(← sealReserved dataRoot "leanci" admin mission managed resolve).isOk) "untrusted authority rejected"
  check ((← calls.get).isEmpty && !(← (managedSecretDir dataRoot).pathExists))
    "rejected authority performs neither vault nor filesystem I/O"
  check (!(← sealReserved dataRoot "unknown" true false false resolve).isOk &&
    (← calls.get).isEmpty) "unknown provider cannot choose a vault key"
  for provider in #["boat", "leanci", "colab"] do
    check (← sealReserved dataRoot provider true false false resolve).isOk "operator seal succeeds"
    let some name := reservedKey? provider | throw (IO.userError "missing reserved mapping")
    let .ok clear ← openProviderSecret dataRoot provider false true
      | throw (IO.userError "Core cannot open its sealed provider key")
    check (clear == "synthetic-test-value-" ++ name) "AEAD round trip"
    check (!(← openProviderSecret dataRoot provider true true).isOk &&
      !(← openProviderSecret dataRoot provider false false).isOk) "sealed read remains Core-reserved"
    let st ← statPath (managedSecretPath dataRoot provider).toString
    check (st.isReg && st.ownedByEuid && (st.mode &&& 0o777) == 0o600) "sealed file remains private"
  check ((← calls.get) == #["BOAT_API_KEY", "LEANCI_API_KEY", "COLAB_API_TOKEN"])
    "canonical reserved key names only"
  let dirStat ← statPath (managedSecretDir dataRoot).toString
  check (dirStat.isDir && dirStat.ownedByEuid && (dirStat.mode &&& 0o777) == 0o700) "sealed directory remains private"
  let lock ← flockExclusiveNb (managedSecretDir dataRoot / "seal.lock").toString
  check (lock != 0xFFFFFFFF && lock != 0xFFFFFFFE) "test acquired seal lock"
  try
    check (!(← sealReserved dataRoot "leanci" true false false resolve).isOk) "concurrent seal fails closed"
  finally closeFdRaw lock.toInt32
  let .ok prior ← openProviderSecret dataRoot "leanci" false true
    | throw (IO.userError "locked seal lost the existing key")
  check (prior == "synthetic-test-value-LEANCI_API_KEY") "lock contention preserves existing key"
  check (!(← sealReserved dataRoot "leanci" true false false (fun _ => pure (.error "sensitive upstream text"))).isOk)
    "vault failures do not seal an empty value"
  let .error err ← sealReserved dataRoot "colab" true false false (fun _ => pure (.error "sensitive upstream text"))
    | throw (IO.userError "vault failure was accepted")
  check (err == "managed_provider_secret_lookup_failed") "vault details never escape"
  check (!(← sealReserved dataRoot "colab" true false false (fun _ => pure (.ok "  "))).isOk)
    "empty vault values refused"

end OrbCore.ManagedProviderSealingTests
