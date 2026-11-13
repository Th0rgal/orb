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

  let batchRoot := root ++ "/provider-sealing-batch"
  let inventories ← IO.mkRef (0 : Nat)
  let discover : IO (Except String (Array String)) := do
    inventories.modify (· + 1)
    return .ok #["boat", "colab"]
  calls.set #[]
  for (admin, mission, managed) in #[(false, false, false), (true, true, false), (true, false, true)] do
    check (!(← sealConfigured batchRoot admin mission managed discover resolve).isOk)
      "batch authorization rejects untrusted callers"
  check ((← inventories.get) == 0 && (← calls.get).isEmpty && !(← (managedSecretDir batchRoot).pathExists))
    "batch rejection precedes inventory, key lookup and filesystem writes"
  check ((← sealConfigured batchRoot true false false discover resolve).toOption == some #["boat", "colab"])
    "one command seals every configured provider, including disabled providers"
  check ((← calls.get) == #["BOAT_API_KEY", "COLAB_API_TOKEN"] &&
    !(← (managedSecretPath batchRoot "leanci").pathExists)) "unconfigured providers are skipped without lookup"
  for provider in #["boat", "colab"] do
    let some name := reservedKey? provider | throw (IO.userError "batch reserved mapping missing")
    check ((← openProviderSecret batchRoot provider false true).toOption == some ("synthetic-test-value-" ++ name))
      "batch seal decrypts only inside Core"
  calls.set #[]
  check (!(← sealConfigured batchRoot true false false (pure (.ok #["boat", "boat"])) resolve).isOk &&
    !(← sealConfigured batchRoot true false false (pure (.ok #["unknown"])) resolve).isOk &&
    (← calls.get).isEmpty) "invalid inventories perform no key lookup"
  let .error inventoryError ← sealConfigured batchRoot true false false (pure (.error "sensitive fixture")) resolve
    | throw (IO.userError "failed batch inventory succeeded")
  check (inventoryError == "managed_provider_inventory_failed" && (← calls.get).isEmpty)
    "inventory failures disclose no upstream text and look up no values"
  let .error batchError ← sealConfigured batchRoot true false false discover (fun _ => pure (.error "sensitive fixture"))
    | throw (IO.userError "failed batch vault lookup succeeded")
  check (batchError == "managed_provider_seal_failed:boat") "batch errors disclose no upstream text or key values"
  check ((← sealConfigured batchRoot true false false discover resolve).isOk)
    "rerunning batch sealing safely completes the configured inventory"

  -- One-time move of a key sealed under the provider's former name.
  let legacyRoot := root ++ "/provider-sealing-legacy"
  check ((← migrateLegacyLeanciSecret legacyRoot).toOption == some false) "nothing to migrate is not an error"
  let .ok () ← sealProviderSecret legacyRoot "boat" "synthetic-boat" | throw (IO.userError "legacy fixture master key")
  let masterKey ← IO.FS.readBinFile (managedMasterKeyPath legacyRoot)
  let .ok nonce ← OrbNetLeaf.Crypto.randBytes 12 | throw (IO.userError "legacy fixture nonce")
  let .ok legacySealed ← OrbNetLeaf.Crypto.aeadSeal .aes256Gcm masterKey nonce "orb-core-reserved:boost".toUTF8
      "synthetic-legacy-key".toUTF8
    | throw (IO.userError "legacy fixture seal")
  let legacyPath := managedSecretPath legacyRoot "boost"
  let .ok () ← writeAtomicPrivate0600 legacyPath (nonce ++ legacySealed) | throw (IO.userError "legacy fixture write")
  check (!(← openProviderSecret legacyRoot "leanci" false true).isOk) "the old file is not read as an alias"
  check ((← migrateLegacyLeanciSecret legacyRoot).toOption == some true) "legacy key migrated"
  let .ok moved ← openProviderSecret legacyRoot "leanci" false true | throw (IO.userError "migrated key unreadable")
  check (moved == "synthetic-legacy-key" && !(← legacyPath.pathExists) &&
    (← migrateLegacyLeanciSecret legacyRoot).toOption == some false) "key readable under leanci, old file gone, rerun is a no-op"
  let .ok () ← writeAtomicPrivate0600 legacyPath (nonce ++ legacySealed) | throw (IO.userError "stale fixture write")
  let .ok () ← sealProviderSecret legacyRoot "leanci" "synthetic-current-key" | throw (IO.userError "current key seal")
  check ((← migrateLegacyLeanciSecret legacyRoot).toOption == some true && !(← legacyPath.pathExists) &&
    (← openProviderSecret legacyRoot "leanci" false true).toOption == some "synthetic-current-key")
    "a stale old file never replaces the current key"
  let .ok () ← writeAtomicPrivate0600 legacyPath "not a sealed value at all, far too short?".toUTF8
    | throw (IO.userError "corrupt fixture write")
  IO.FS.removeFile (managedSecretPath legacyRoot "leanci")
  check (!(← migrateLegacyLeanciSecret legacyRoot).isOk && (← legacyPath.pathExists)) "an unreadable old file is kept, not deleted"

end OrbCore.ManagedProviderSealingTests
