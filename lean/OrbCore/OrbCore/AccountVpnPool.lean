import OrbCore.AccountVpnRoutes
import OrbCore.AirVpnTunnel

namespace OrbCore.AccountVpnPool

open Orb.AccountVpn OrbCore.AirVpnSettings OrbCore.AirVpnTunnel
open OrbCore.AccountVpnRoutes (Preference)
open OrbBin.PosixExt OrbBin.Sqlite

structure Gateway where
  port : UInt16
  revoked : IO.Ref Bool

structure Occupant where
  binding : Binding
  generation : Nat
  locks : List UInt32
  gateway : Gateway

structure Active where
  endpoint : Endpoint
  tunnel : Tunnel
  evidence : VerifiedTunnel
  occupants : List Occupant
  retiredLocks : List UInt32 := []

structure PoolState where
  active : List Active := []
  failures : Std.HashMap String (Nat × String) := {}

abbrev Pool := Std.Mutex PoolState

private def unlock (locks : List UInt32) : IO Unit :=
  locks.forM fun fd => closeFdRaw fd.toInt32

/-- Every process coordinating through this directory holds an exclusive
lease on every address for the whole lifetime of a category's binding. -/
def lockExits (dir cat : String) (exits : List ExitAddress) : IO (Except String (List UInt32)) := do
  if dir.isEmpty || cat.isEmpty || cat.length > 128 || exits.isEmpty ||
      !cat.all (fun c => c.isAlphanum || c == '-' || c == '_') then return .error "invalid_vpn_binding"
  let mut locks := []
  for ip in exits.eraseDups do
    let suffix := match ip with
      | .v4 n => s!"4-{n}"
      | .v6 hi lo => s!"6-{hi}-{lo}"
    let fd ← flockExclusiveNb ((System.FilePath.mk dir) / s!"exit-{cat}-{suffix}.lock").toString
    if fd ≥ 0xFFFFFFFE then
      unlock locks
      return .error (if fd == 0xFFFFFFFE then "vpn_exit_in_use" else "vpn_coordinator_unavailable")
    locks := fd :: locks
  return .ok locks

private def drain (a : Active) : IO Unit := do
  for o in a.occupants do o.gateway.revoked.set true
  a.tunnel.stop
  for o in a.occupants do unlock o.locks
  unlock a.retiredLocks

/-- Commit an admin credential change under the admission lock and retire
the children using the previous secret before accepting another request. -/
def saveSecret (pool : Pool) : SaveSecret := fun root secret value => pool.atomically do
  let active := (← get).active
  let (affected, keep) := active.partition fun t => match secret with
    | .apiKey => true
    | .device device => t.endpoint.device == device
  if !affected.isEmpty && (← OrbCore.Managed.openAirVpnSecret root secret).toOption == some value then
    return .ok ()
  if let .error e ← OrbCore.Managed.sealAirVpnSecret root secret value then return .error e
  for t in affected do drain t
  modify fun state => { state with active := keep }
  return .ok ()

/-- On a shared transport, existing streams can outlive a preference change.
Hold the old exit leases until the last occupant drains the transport. -/
private def detach (active : List Active) (account : String) : IO (List Active) := do
  let mut keep := []
  for t in active do
    let (leaving, others) := t.occupants.partition (fun o => o.binding.account == account)
    for o in leaving do o.gateway.revoked.set true
    if leaving.isEmpty then keep := t :: keep
    else if others.isEmpty then drain t
    else keep := { t with occupants := others, retiredLocks := t.retiredLocks ++ leaving.flatMap (·.locks) } :: keep
  return keep.reverse

def savePreference (pool : Pool) (db : SqliteDb) (account : String) (country? : Option String)
    (configure? : Option (Bool → IO (Except String Unit)) := none) :
    IO (Except String Unit) := pool.atomically do
  let .ok before ← AccountVpnRoutes.read db account | return .error "vpn_route_store_unavailable"
  if country?.isSome then
    if let some configure := configure? then
      if let .error e ← configure true then return .error e
  if let .error e ← AccountVpnRoutes.set db account country? then return .error e
  if before.map (·.country) != country? then
    let active ← detach (← get).active account
    modify fun state => { state with active, failures := state.failures.erase account }
  if country?.isNone then
    if let some configure := configure? then
      if let .error e ← configure false then return .error e
  return .ok ()

private def install (dir : String) (db : SqliteDb) (account cat : String) (pref : Preference)
    (t : Active) (others : List Active) : IO (Except String (Active × Gateway)) := do
  let ready := (t :: others).flatMap (fun a => a.occupants.map (·.binding))
  let binding : Binding := ⟨account, cat, t.evidence.country, t.evidence.exits⟩
  if (admit pref.country binding ready).isNone then return .error "vpn_exit_in_use"
  let locks ← match ← lockExits dir cat binding.exits with
    | .ok locks => pure locks
    | .error e => return .error e
  if let .error e ← AccountVpnRoutes.rememberServer db account pref t.evidence.server then
    unlock locks
    return .error e
  let gateway : Gateway := ⟨t.tunnel.port, ← IO.mkRef false⟩
  return .ok ({ t with occupants := ⟨binding, pref.generation, locks, gateway⟩ :: t.occupants }, gateway)

/-- Recheck the credential's saved generation while serializing local admission.
Each selected listener belongs to a running process with fresh exit evidence. -/
private def allocateLocked (root dir : String) (db : SqliteDb) (account provider : String)
    (pref : Preference) : Std.AtomicT PoolState IO (Except String Gateway) := do
  let .ok current ← AccountVpnRoutes.read db account | return .error "vpn_route_store_unavailable"
  let some current := current | return .error "vpn_route_changed"
  if current.generation != pref.generation || current.country != pref.country then
    return .error "vpn_route_changed"
  if dir.isEmpty then return .error "vpn_coordinator_unconfigured"
  let cat := canonicalCategory provider
  let mut available := (← get).active
  -- Reusing a socket after its binding changed would also keep old streams alive.
  for t in available do
    if let some o := t.occupants.find? (fun o => o.binding.account == account) then
      if o.generation == pref.generation && o.binding.category == cat then
        if (← t.tunnel.verify root t.endpoint.server pref.country) == some t.evidence then
          return .ok o.gateway
        drain t
        available := available.filter (fun a => a.tunnel.port != t.tunnel.port)
      else
        available ← detach available account
      modify fun state => { state with active := available }
  let req : Request := ⟨account, cat, pref.country, some current.preferredServer⟩
  let configured := (← endpoints root).filter (fun e => e.country == pref.country)
  let running := (available.filter (fun a => a.endpoint.country == pref.country)).map (·.endpoint)
  let candidates := serverOrder (·.server) req.preferredServer
    (running ++ configured.filter (fun e => !running.any (fun r => r.device == e.device)))
  let mut startupBlocked : Option String := none
  let mut failure := "vpn_no_compatible_profile"
  for endpoint in candidates do
    if let some t := available.find? (fun a => a.endpoint.device == endpoint.device) then
      let ready := available.flatMap (fun a => a.occupants.map (·.binding))
      if (choose req ready [t.evidence]).isNone then continue
      let others := available.filter (fun a => a.tunnel.port != t.tunnel.port)
      if (← t.tunnel.verify root endpoint.server pref.country) == some t.evidence then
        match ← install dir db account cat pref t others with
        | .ok (active, gateway) =>
          modify fun state => { state with active := active :: others }
          return .ok gateway
        | .error e => failure := e
        continue
      drain t
      available := others
      modify fun state => { state with active := available }
      if !configured.contains endpoint then continue
    if startupBlocked.isSome then continue
    let .ok bytes ← OrbNetLeaf.Crypto.randBytes 2 | return .error "vpn_port_unavailable"
    let port := (20000 + ((bytes[0]!.toNat * 256 + bytes[1]!.toNat) % 40000)).toUInt16
    match ← startVerified root dir endpoint.device endpoint.server endpoint.country port with
    | .error e =>
      if e == "airvpn_session_limit" || e == "vpn_coordinator_busy" then startupBlocked := some e
      failure := e
    | .ok (tunnel, verified) =>
      let active : Active := { endpoint, tunnel, evidence := verified, occupants := [] }
      match ← install dir db account cat pref active available with
      | .ok (admitted, gateway) =>
        modify fun state => { state with active := admitted :: available }
        return .ok gateway
      | .error e =>
        tunnel.stop
        failure := e
  return .error (startupBlocked.getD failure)

/-- Keep the last verification outcome with the live pool. It expires when a
preference changes or Core restarts. A delayed request cannot replace a newer outcome. -/
def allocateGateway (pool : Pool) (root dir : String) (db : SqliteDb) (account provider : String)
    (pref : Preference) : IO (Except String Gateway) := pool.atomically do
  let result ← allocateLocked root dir db account provider pref
  match result with
  | .ok _ => modify fun state => { state with failures := state.failures.erase account }
  | .error "vpn_route_changed" | .error "vpn_route_store_unavailable" => pure ()
  | .error reason =>
    modify fun state => { state with failures := state.failures.insert account (pref.generation, reason) }
  return result

def allocate (pool : Pool) (root dir : String) (db : SqliteDb) (account provider : String)
    (pref : Preference) : IO (Except String UInt16) := do
  return (← allocateGateway pool root dir db account provider pref).map (·.port)

def shutdown (pool : Pool) : IO Unit := pool.atomically do
  for t in (← get).active do drain t
  set ({} : PoolState)

end OrbCore.AccountVpnPool
