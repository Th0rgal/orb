import OrbCore.AccountVpnRoutes
import OrbCore.AirVpnTunnel

namespace OrbCore.AccountVpnPool

open Orb.AccountVpn OrbCore.AirVpnSettings OrbCore.AirVpnTunnel
open OrbCore.AccountVpnRoutes (Preference)
open OrbBin.PosixExt OrbBin.Sqlite

def category (provider : String) : String :=
  match provider.trimAscii.toString.toLower with
  | "openai" | "chatgpt" | "codex" => "openai"
  | "anthropic" | "claude" => "anthropic"
  | "google" | "gemini" | "antigravity" | "gemini-cli" => "google"
  | "grok" | "xai" => "xai"
  | "meta" | "muse-code" => "meta"
  | other => other

structure Occupant where
  binding : Binding
  generation : Nat
  locks : List UInt32

structure Active where
  endpoint : Endpoint
  tunnel : Tunnel
  evidence : VerifiedTunnel
  occupants : List Occupant

abbrev Pool := Std.Mutex (List Active)

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
  a.tunnel.stop
  for o in a.occupants do unlock o.locks

private def install (dir : String) (db : SqliteDb) (account cat : String) (pref : Preference)
    (t : Active) (others : List Active) : IO (Except String Active) := do
  let ready := (t :: others).flatMap (fun a => a.occupants.map (·.binding))
  let binding : Binding := ⟨account, cat, t.evidence.country, t.evidence.exits⟩
  if (admit pref.country binding ready).isNone then return .error "vpn_exit_in_use"
  let locks ← match ← lockExits dir cat binding.exits with
    | .ok locks => pure locks
    | .error e => return .error e
  if let .error e ← AccountVpnRoutes.rememberServer db account pref t.evidence.server then
    unlock locks
    return .error e
  return .ok { t with occupants := ⟨binding, pref.generation, locks⟩ :: t.occupants }

/-- Recheck the credential's saved generation while serializing local admission.
Each selected listener belongs to a running process with fresh exit evidence. -/
def allocate (pool : Pool) (root dir : String) (db : SqliteDb) (account provider : String)
    (pref : Preference) : IO (Except String UInt16) := pool.atomically do
  if dir.isEmpty then return .error "vpn_coordinator_unconfigured"
  let cat := category provider
  let mut available ← get
  -- Reusing a socket after its binding changed would also keep old streams alive.
  for t in available do
    if let some o := t.occupants.find? (fun o => o.binding.account == account) then
      if o.generation == pref.generation && o.binding.category == cat then
        if (← t.tunnel.verify root t.endpoint.server pref.country) == some t.evidence then
          return .ok t.tunnel.port
      drain t
      available := available.filter (fun a => a.tunnel.port != t.tunnel.port)
      set available
  let ready := available.flatMap (fun t => t.occupants.map (·.binding))
  let req : Request := ⟨account, cat, pref.country, some pref.preferredServer⟩
  let mut candidates := available
  repeat
    let some best := choose req ready (candidates.map (·.evidence)) | break
    let some t := candidates.find? (fun a => a.evidence == best) | break
    candidates := candidates.filter (fun a => a.tunnel.port != t.tunnel.port)
    if (← t.tunnel.verify root t.endpoint.server pref.country) != some best then
      drain t
      available := available.filter (fun a => a.tunnel.port != t.tunnel.port)
      set available
      continue
    let others := available.filter (fun a => a.tunnel.port != t.tunnel.port)
    if let .ok active ← install dir db account cat pref t others then
      set (active :: others)
      return .ok t.tunnel.port
  let inventory := (← endpoints root).filter fun e =>
    e.country == pref.country && !available.any (fun a => a.endpoint.device == e.device)
  let (preferred, rest) := inventory.partition (fun e => e.server == pref.preferredServer)
  let mut failure := "vpn_no_compatible_profile"
  for endpoint in preferred ++ rest do
    let .ok bytes ← OrbNetLeaf.Crypto.randBytes 2 | return .error "vpn_port_unavailable"
    let port := (20000 + ((bytes[0]!.toNat * 256 + bytes[1]!.toNat) % 40000)).toUInt16
    match ← startVerified root dir endpoint.device endpoint.server endpoint.country port with
    | .error e =>
      if e == "airvpn_session_limit" || e == "vpn_coordinator_busy" then return .error e
      failure := e
    | .ok (tunnel, verified) =>
      let active : Active := ⟨endpoint, tunnel, verified, []⟩
      match ← install dir db account cat pref active available with
      | .ok admitted =>
        set (admitted :: available)
        return .ok port
      | .error e =>
        tunnel.stop
        failure := e
  return .error failure

def shutdown (pool : Pool) : IO Unit := pool.atomically do
  for t in ← get do drain t
  set ([] : List Active)

end OrbCore.AccountVpnPool
