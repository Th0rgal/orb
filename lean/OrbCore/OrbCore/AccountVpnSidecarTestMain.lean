import OrbCore.AccountVpnWireGuardTests
import OrbCore.AccountVpnSidecar
import OrbCore.AccountVpnRelay

/-- Create a fresh synthetic store for the job transport test. Never attach
    this fixture issuer to an existing database. -/
private def seedRelayGrants (root owner mission job : String) : IO UInt32 := do
  IO.FS.createDir root
  let store ← IO.ofExcept (← OrbCore.Store.openCoreStore root)
  try
    let _ ← OrbCore.Store.interruptTurnsLostToRestart store.missionsDb
    discard <| IO.ofExcept (← OrbCore.Store.execParamQuery store.missionsDb
      "INSERT INTO ai_providers(id,name,provider_type,created_by_user_id) VALUES('d','fixture','antigravity',?1);" #[owner])
    discard <| IO.ofExcept (← OrbCore.Store.changeNativeOwnerEnrollment store "ledger-node" owner "d" 0)
    discard <| IO.ofExcept (← OrbCore.AccountVpnRoutes.set store.missionsDb "d" (some "NL"))
    let expires := (← OrbCore.Store.coreEpochSec) + 300
    let out ← IO.getStdout
    for _ in [:2] do
      out.putStrLn (← IO.ofExcept (← OrbCore.Store.mintNativeAntigravityToken store mission owner job "d"
        "gemini-4-carbon" expires (some "ledger-node")))
    return 0
  finally OrbCore.Store.closeCoreStore store

/-- Fixture entry point for the same management client used by the account
Settings route. The short-lived fixture management key arrives on stdin. -/
def main (args : List String) : IO UInt32 := do
  if let ["job-relay-grants", root, owner, mission, job] := args then return ← seedRelayGrants root owner mission job
  if let ["wireguard", root] := args then return ← OrbCore.AccountVpnWireGuardTests.run root false
  if let ["wireguard-hold", root] := args then return ← OrbCore.AccountVpnWireGuardTests.run root true true
  if let ["wireguard-resume", root] := args then return ← OrbCore.AccountVpnWireGuardTests.run root true
  if let ["relay", first, second] := args then
    let some a := first.toNat? | return 2
    let some b := second.toNat? | return 2
    if a == 0 || b == 0 || a > 65535 || b > 65535 then return 2
    let input ← IO.getStdin
    let key := (← input.getLine).trimAscii.toString
    let unavailable ← IO.mkRef false
    let live ← IO.mkRef false
    let listener ← IO.ofExcept (← OrbCore.AccountVpnRelay.start 0 key fun provider account => do
      match provider, account with
      | "openai", "a" => return if ← unavailable.get then .error "vpn_exit_unverified" else .ok ⟨a.toUInt16, unavailable⟩
      | "openai", "b" => return .ok ⟨b.toUInt16, live⟩
      | "anthropic", "c" => return .ok ⟨a.toUInt16, live⟩
      | "kimi", "e" => return if ← unavailable.get then .error "vpn_exit_unverified" else .ok ⟨a.toUInt16, unavailable⟩
      | "antigravity", "d" => return if ← unavailable.get then .error "vpn_exit_unverified" else .ok ⟨b.toUInt16, unavailable⟩
      | _, _ => return .error "unknown_account")
    try
      let out ← IO.getStdout
      for (provider, account) in [("openai", "a"), ("openai", "b"), ("anthropic", "c"), ("antigravity", "d"), ("kimi", "e")] do
        let some url := OrbCore.AccountVpnRelay.proxyUrl key listener.port provider account | return 1
        out.putStrLn url
      out.flush
      if (← input.getLine).trimAscii == "drop-a-d-e" then
        unavailable.set true
        out.putStrLn "blocked"
        out.flush
        discard input.getLine
      return 0
    finally listener.stop
  if let ["routers", base, file, mode] := args then
    let desired := mode == "allow"
    if !desired && mode != "restrict" then return 2
    let key := (← (← IO.getStdin).getLine).trimAscii.toString
    let outcome ← OrbCore.AccountVpnSidecar.alternativeRouterAccess base key file (some desired)
    if outcome.toOption == some desired then return 0
    return 1
  if let ["confirm", base, file, relay, modelPrefix] := args then
    let key := (← (← IO.getStdin).getLine).trimAscii.toString
    if (← OrbCore.AccountVpnSidecar.confirm base key file relay modelPrefix).isOk then return 0
    return 1
  let [base, file, relay, mode] := args | return 2
  if !["enable", "disable"].contains mode then return 2
  let key := (← (← IO.getStdin).getLine).trimAscii.toString
  match ← OrbCore.AccountVpnSidecar.configure base key file relay (mode == "enable") with
  | .ok () => return 0
  | .error code =>
    IO.eprintln code
    return 1
