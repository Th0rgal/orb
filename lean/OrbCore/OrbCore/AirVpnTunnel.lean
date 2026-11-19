import OrbCore.AirVpnObservation
import OrbCore.AirVpnSettings

namespace OrbCore.AirVpnTunnel

open OrbBin.PosixExt OrbBin.Json Orb.AccountVpn OrbCore.Managed OrbCore.AirVpnSettings

abbrev Child := IO.Process.Child { stdin := .null, stdout := .null, stderr := .null }

structure Tunnel where
  child : Child
  port : UInt16
  addresses : List ExitAddress

def Tunnel.stop (t : Tunnel) : IO Unit := do
  if (← t.child.tryWait).isNone then
    t.child.kill
    discard t.child.wait

/-- Start an isolated userspace WireGuard stack. Only the generated loopback
listener is published. The secret configuration passes over an anonymous pipe. -/
private def start (profile : DeviceProfile) (port : UInt16) : IO (Except String Tunnel) := do
  if port == 0 then return .error "invalid_vpn_listener"
  let cfg := profile.config ++ s!"\n[Socks5]\nBindAddress = 127.0.0.1:{port}\n"
  let args : IO.Process.SpawnArgs := {
    cmd := "wireproxy"
    args := #["-c", "/dev/stdin"]
    stdin := .piped
    stdout := .null
    stderr := .null }
  let child ← try IO.Process.spawn args catch _ => return .error "vpn_process_unavailable"
  let (input, running) ← child.takeStdin
  let tunnel : Tunnel := ⟨running, port, profile.addresses⟩
  try
    input.putStr cfg
    input.flush
  catch _ =>
    tunnel.stop
    return .error "vpn_config_transfer_failed"
  return .ok tunnel

private def ownsSession (addresses : List ExitAddress) (session : JVal) : Bool :=
  ((session.fieldStr? "vpn_ip").bind AirVpnObservation.parseExit?).any addresses.contains

/-- The caller must hold the allocation lock while associating this observation
with a live generation and publishing the admitted binding. -/
def Tunnel.verify (t : Tunnel) (root server country : String) : IO (Option VerifiedTunnel) := do
  if (← t.child.tryWait).isSome then return none
  let .ok sessions ← activeSessions root | return none
  let ipv6 := t.addresses.any fun | .v6 .. => true | _ => false
  let evidence ← AirVpnObservation.observe t.port ipv6 server country (sessions.filter (ownsSession t.addresses))
  if (← t.child.tryWait).isSome then return none
  return evidence

def checkReservation (addresses : List ExitAddress) (sessions : Array JVal) : Except String Unit := do
  if (reserve 5 sessions.size 0).isNone then throw "airvpn_session_limit"
  if addresses.isEmpty || sessions.any (fun s => ((s.fieldStr? "vpn_ip").bind AirVpnObservation.parseExit?).isNone) then
    throw "airvpn_session_evidence_unavailable"
  if sessions.any (ownsSession addresses) then throw "airvpn_device_in_use"

/-- Dev and production use the same operator-owned directory. Hold the lock
through the handshake until AirVPN lists the session, so the next reservation
sees it. A device already in use cannot replace another consumer's session. -/
def startVerified (root sharedDir device server country : String) (port : UInt16) :
    IO (Except String (Tunnel × VerifiedTunnel)) := do
  if sharedDir.isEmpty then return .error "vpn_coordinator_unconfigured"
  let lock ← flockExclusiveNb ((System.FilePath.mk sharedDir) / "airvpn.lock").toString
  if lock ≥ 0xFFFFFFFE then return .error "vpn_coordinator_busy"
  try
    let some (endpoint, profile) ← readEndpoint root device | return .error "vpn_profile_unavailable"
    if endpoint.country != country || endpoint.server != server then return .error "vpn_profile_changed"
    let .ok sessions ← activeSessions root | return .error "airvpn_session_evidence_unavailable"
    if let .error e := checkReservation profile.addresses sessions then return .error e
    let .ok t ← start profile port | return .error "vpn_start_failed"
    let checked ← try
      let mut evidence := none
      for _ in [:6] do
        IO.sleep 1000
        if (← t.child.tryWait).isSome then break
        evidence ← t.verify root server country
        if evidence.isSome then break
      pure evidence
    catch _ => pure none
    if let some verified := checked then return .ok (t, verified)
    t.stop
    return .error "vpn_exit_unverified"
  finally closeFdRaw lock.toInt32

end OrbCore.AirVpnTunnel
