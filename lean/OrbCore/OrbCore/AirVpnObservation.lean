import Std.Net.Addr
import Orb.AccountVpn
import OrbBin.Json
import OrbNetLeaf.TlsHttp

namespace OrbCore.AirVpnObservation

open Orb.AccountVpn OrbBin.Json OrbNetLeaf.TlsHttp

/-- Collapse mapped IPv4 and alternate IPv6 spellings before checking isolation. -/
def parseExit? (raw : String) : Option ExitAddress := do
  let s := raw.trimAscii.toString
  guard (!s.isEmpty && s.length ≤ 45 && s.all (fun c => c.isHexDigit || c == '.' || c == ':'))
  if let some addr := Std.Net.IPv4Addr.ofString s then
    return .v4 (addr.octets.toArray.foldl (fun n b => n <<< 8 ||| b.toUInt32) 0)
  let addr ← Std.Net.IPv6Addr.ofString s
  let words := addr.segments.toArray
  let pack := fun (words : Array UInt16) => words.foldl (fun (n : UInt64) b => n <<< 16 ||| b.toUInt64) 0
  let hi := pack (words.extract 0 4)
  let lo := pack (words.extract 4 8)
  if hi == 0 && lo >>> 32 == 0xffff then return .v4 lo.toUInt32
  return .v6 hi lo

/-- Country and server identity come from an active AirVPN session whose
reported exit matches the independent IPv4 receiver on the candidate tunnel. -/
def verifyObservation? (server country : String) (sessions : Array JVal)
    (v4 : ExitAddress) (v6? : Option ExitAddress) : Option VerifiedTunnel := do
  let .v4 _ := v4 | none
  guard (!server.isEmpty && country.length == 2 && country.toList.all (fun c => 'A' ≤ c && c ≤ 'Z'))
  guard (sessions.any fun s =>
    (s.fieldStr? "server_name").map String.toLower == some server.toLower &&
    s.fieldStr? "server_country_code" == some country &&
    (s.fieldStr? "exit_ip").bind parseExit? == some v4)
  match v6? with
  | some (.v4 _) => none
  | some v6 => return ⟨server, country, [v4, v6]⟩
  | none => return ⟨server, country, [v4]⟩

private def probe (port : UInt16) (host : String) : IO (Option ExitAddress) := do
  let .ok r ← httpsRequest "GET" host 443 "/" #[] ByteArray.empty
      (maxRespBytes := 4096) (timeoutMs := 5000) (socksPort? := some port) | return none
  if r.status != 200 then return none
  return (String.fromUTF8? r.body).bind parseExit?

/-- ipv6Enabled describes the enforced tunnel configuration. A failed IPv6
probe on a dual-stack tunnel invalidates the whole observation. -/
def observe (port : UInt16) (ipv6Enabled : Bool) (server country : String)
    (sessions : Array JVal) : IO (Option VerifiedTunnel) := do
  let some v4 ← probe port "api.ipify.org" | return none
  if ipv6Enabled then
    let some v6 ← probe port "api6.ipify.org" | return none
    return verifyObservation? server country sessions v4 (some v6)
  return verifyObservation? server country sessions v4 none

end OrbCore.AirVpnObservation
