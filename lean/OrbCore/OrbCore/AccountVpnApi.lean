import OrbCore.AccountVpnPool

namespace OrbCore.AccountVpnApi

open OrbCore.Store OrbBin.Json Orb.AccountVpn OrbCore.AccountVpnRoutes

private def formatExit : ExitAddress → String
  | .v4 n => String.intercalate "." ([24, 16, 8, 0].map fun k : UInt32 => toString ((n >>> k).toUInt8))
  | .v6 hi lo =>
    let parts := fun (n : UInt64) => [48, 32, 16, 0].map fun k : UInt64 => ((n >>> k).toUInt16)
    let words := parts hi ++ parts lo
    String.intercalate ":" (words.map fun w => String.ofList (Nat.toDigits 16 w.toNat))

private def reasonMessage : String → String
  | "airvpn_session_limit" => "All five AirVPN sessions are in use."
  | "vpn_exit_in_use" => "This exit is already reserved for another account in this category."
  | "vpn_no_compatible_profile" => "Import another device profile for this country in AirVPN Settings."
  | "vpn_awaiting_verification" => "Waiting for exit verification."
  | "airvpn_session_evidence_unavailable" => "Check the saved API key and AirVPN session lookup."
  | "vpn_coordinator_unconfigured" => "The Core VPN coordinator needs configuration."
  | "vpn_coordinator_busy" => "Another VPN connection is starting. Retry shortly."
  | "airvpn_device_in_use" => "This WireGuard device already has an active session."
  | "vpn_exit_unverified" => "The server, country, or exit address could not be verified."
  | _ => "The VPN route is unavailable."

private def observed? (pool : AccountVpnPool.Pool) (account : String) (pref : Preference) :
    IO (Option VerifiedTunnel) := pool.atomically do
  for t in ← get do
    if t.occupants.any (fun o => o.binding.account == account && o.generation == pref.generation) &&
        (← t.tunnel.child.tryWait).isNone then return some t.evidence
  return none

def route (store : CoreStore) (pool? : Option AccountVpnPool.Pool) (dir account provider : String)
    (canConfigure : Bool) (method : String) (body : ByteArray)
    (configure? : Option (Bool → IO (Except String Unit)) := none) : IO (Nat × JVal) := do
  let err := fun (code : Nat) (reason : String) => (code, JVal.obj #[("error", .str reason)])
  if method != "GET" && method != "PUT" then return err 405 "method_not_allowed"
  if method == "PUT" then
    if !canConfigure then return err 409 "vpn_credential_owner_unavailable"
    if body.size > 1024 then return err 413 "route_too_large"
    let .ok j := parseBytes body | return err 400 "invalid_json"
    let country? ← match j.fieldStr? "mode", j.field? "country" with
      | some "direct", none | some "direct", some .null => pure none
      | some "vpn", some (.str c) =>
        unless validCountry c do return err 400 "invalid_vpn_country"
        pure (some c)
      | _, _ => return err 400 "invalid_vpn_preference"
    let some pool := pool? | return err 503 "vpn_coordinator_unavailable"
    if let .error e ← AccountVpnPool.savePreference pool store.missionsDb account country? configure? then return err 503 e
  let preference ← match ← AccountVpnRoutes.read store.missionsDb account with
    | .ok p => pure p
    | .error e => return err 503 e
  let countries := ((← AirVpnSettings.endpoints store.rootDir).map (·.country)).eraseDups.mergeSort
  let mut fields := #[("countries", JVal.arr (countries.toArray.map JVal.str)),
    ("can_configure", .bool canConfigure)]
  let some pref := preference | return (200, .obj (fields ++ #[("mode", .str "direct"), ("status", .str "direct")]))
  fields := fields ++ #[("mode", .str "vpn"), ("country", .str pref.country)]
  let mut reason := "vpn_awaiting_verification"
  if dir.isEmpty || pool?.isNone then reason := "vpn_coordinator_unconfigured"
  if let some pool := pool? then
    if method == "PUT" then
      if let .error e ← AccountVpnPool.allocate pool store.rootDir dir store.missionsDb account provider pref then reason := e
    if let some t ← observed? pool account pref then
      return (200, .obj (fields ++ #[("status", .str "verified"), ("server", .str t.server),
        ("exits", .arr (t.exits.toArray.map (fun ip => .str (formatExit ip))))]))
  return (200, .obj (fields ++ #[("status", .str "blocked"), ("reason", .str reason), ("message", .str (reasonMessage reason))]))

end OrbCore.AccountVpnApi
