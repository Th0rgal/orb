import OrbCore.Store

namespace OrbCore.AccountVpnRoutes

open OrbCore.Store OrbBin.Sqlite

structure Preference where
  country : String
  generation : Nat
  preferredServer : String
  deriving Repr, DecidableEq

def validCountry (country : String) : Bool :=
  country.length == 2 && country.toList.all (fun c => 'A' ≤ c && c ≤ 'Z')

inductive Route where
  | direct (revision : Nat)
  | vpn (preference : Preference)

def Route.generation : Route → Nat
  | .direct n => n
  | .vpn p => p.generation

/-- An absent row is a legacy Direct account. A failed read or malformed
record must block dispatch because it could conceal an enabled VPN. -/
def snapshot (db : SqliteDb) (account : String) : IO (Except String Route) := do
  let .ok rows ← execParamQuery db
    "SELECT country,CAST(generation AS TEXT),preferred_server FROM account_vpn_routes WHERE account_id=?1;" #[account]
    | return .error "vpn_route_store_unavailable"
  if rows.size ≤ 1 then return .ok (.direct 0)
  let #[country, generation, server] := rows[1]! | return .error "vpn_route_store_invalid"
  let some n := generation.toNat? | return .error "vpn_route_store_invalid"
  if n == 0 then return .error "vpn_route_store_invalid"
  if country.isEmpty then return .ok (.direct n)
  if !validCountry country then return .error "vpn_route_store_invalid"
  return .ok (.vpn ⟨country, n, server⟩)

def read (db : SqliteDb) (account : String) : IO (Except String (Option Preference)) := do
  return (← snapshot db account).map fun
    | .direct _ => none
    | .vpn p => some p

/-- An OAuth callback belongs to the route from which its login was started.
A route change can require another authenticated exchange. -/
def checkGeneration (db : SqliteDb) (account : String) (expected : Nat) : IO (Except String Unit) := do
  match ← snapshot db account with
  | .error e => return .error e
  | .ok current =>
    if current.generation == expected then return .ok ()
    return .error "vpn_route_changed"

/-- Persist the desired country. Direct uses an empty country so turning a VPN
off and on again cannot accidentally reuse an older admission generation. -/
def set (db : SqliteDb) (account : String) (country? : Option String) : IO (Except String Unit) := do
  if account.isEmpty || country?.any (fun c => !validCountry c) then return .error "invalid_vpn_preference"
  let sql := "INSERT INTO account_vpn_routes(account_id,country) SELECT ?1,?2 " ++
    "WHERE ?2<>'' OR EXISTS (SELECT 1 FROM account_vpn_routes WHERE account_id=?1) " ++
    "ON CONFLICT(account_id) DO UPDATE SET country=excluded.country, generation=generation+1, preferred_server='' " ++
    "WHERE account_vpn_routes.country<>excluded.country;"
  let r ← execParamQuery db sql #[account, country?.getD ""]
  return r.map (fun _ => ()) |>.mapError (fun _ => "vpn_route_store_unavailable")

/-- A late verification must not overwrite a newer route choice. No verified
exit or SOCKS port is persisted across Core restarts. -/
def rememberServer (db : SqliteDb) (account : String) (p : Preference) (server : String) :
    IO (Except String Unit) := do
  let .ok rows ← execParamQuery db
      ("UPDATE account_vpn_routes SET preferred_server=?4 WHERE account_id=?1 AND country=?2 " ++
      "AND generation=CAST(?3 AS INTEGER) RETURNING account_id;") #[account, p.country, toString p.generation, server]
    | return .error "vpn_route_store_unavailable"
  if rows.size != 2 then return .error "vpn_route_changed"
  return .ok ()

/-- The credential owner supplies a freshly verified listener for VPN mode.
Only a successful Direct lookup can produce an absent SOCKS port. -/
def resolve (db : SqliteDb) (account : String) (verified : Preference → IO (Except String UInt16)) :
    IO (Except String (Option UInt16)) := do
  match ← read db account with
  | .error e => return .error e
  | .ok none => return .ok none
  | .ok (some preference) =>
    match ← verified preference with
    | .ok 0 => return .error "account_vpn_unavailable"
    | .ok port => return .ok (some port)
    | .error e => return .error e

end OrbCore.AccountVpnRoutes
