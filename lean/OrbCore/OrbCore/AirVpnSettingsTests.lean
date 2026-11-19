import OrbCore.AirVpnSettings
import OrbCore.AirVpnTunnel

namespace OrbCore.AirVpnSettingsTests

open OrbBin.Json OrbCore.Managed OrbCore.AirVpnSettings

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"airvpn settings: {label}")

def run (root : String) : IO Unit := do
  let parseIp := AirVpnObservation.parseExit?
  let v4 := Orb.AccountVpn.ExitAddress.v4 0x01020304
  check (parseIp "1.2.3.4" == some v4 && parseIp "::FFFF:0102:0304" == some v4 &&
      parseIp "::ffff:1.2.3.4" == some v4) "mapped IPv4 matches dotted address"
  let v6 := Orb.AccountVpn.ExitAddress.v6 0x20010db800000000 1
  check (parseIp "2001:db8::1" == some v6 && parseIp "2001:0DB8:0:0:0:0:0:1" == some v6)
    "compressed and expanded IPv6 match"
  check ((parseIp "fe80::1%eth0").isNone && (parseIp "1.2.3.4\x00ignored").isNone)
    "zone and NUL reject"
  let sessions := #[JVal.obj #[("server_name", .str "West"), ("server_country_code", .str "NL"),
    ("exit_ip", .str "1.2.3.4")]]
  let observed := AirVpnObservation.verifyObservation?
  check ((observed "west" "NL" sessions v4 (some v6)).any (fun t => t.exits == [v4, v6]))
    "active server matches independent receiver"
  check ((observed "west" "US" sessions v4 none).isNone &&
      (observed "east" "NL" sessions v4 none).isNone &&
      (observed "west" "NL" sessions (.v4 123) none).isNone &&
      (observed "west" "NL" sessions v4 (some v4)).isNone)
    "country, server, source address and family mismatch reject"
  let checkSlot := AirVpnTunnel.checkReservation [v4]
  let used := JVal.obj #[("vpn_ip", .str "::ffff:1.2.3.4")]
  let other := JVal.obj #[("vpn_ip", .str "10.1.2.3")]
  check ((checkSlot #[other]).isOk && !(checkSlot #[used]).isOk)
    "reservation preserves other consumers of the same device"
  check ((checkSlot (Array.replicate 5 other)).isOk == false &&
    !(checkSlot #[JVal.null]).isOk) "full budget and unknown devices block startup"
  let dir := root ++ "/airvpn-settings-test"
  check ((sessionRecords? (.obj #[("result", .str "ok")])).isNone)
    "missing session list cannot admit a new tunnel"
  check (((sessionRecords? (.obj #[("result", .str "ok"), ("sessions", .arr #[])])).map Array.size) == some 0)
    "explicit empty session list"
  let key := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  let profile := s!"[Interface]\nDNS = 10.2.0.1\nAddress = 10.2.0.2/32\nPrivateKey = {key}\n[Peer]\nPublicKey = {key}\nEndpoint = example.invalid:1637\nAllowedIPs = 0.0.0.0/0"
  let put := fun (value : JVal) => settings dir "PUT" (renderCompact value).toUTF8
  let upload := fun id content => put (.obj #[("device_id", .str id), ("profile", .str content)])
  let (invalid, _) ← upload "../boat" profile
  check (invalid == 400) "invalid device path rejected"
  let (missingDns, _) ← upload "device" (profile.replace "DNS = 10.2.0.1\n" "")
  check (missingDns == 400) "require tunnel DNS to prevent system resolver fallback"
  let (badDns, _) ← upload "device" (profile.replace "DNS = 10.2.0.1" "DNS = system")
  check (badDns == 400) "require literal DNS addresses"
  let (hook, _) ← upload "device" (profile ++ "\nPostUp = anything")
  check (hook == 400) "executable profile directive rejected"
  let (status, _) ← upload "device" profile
  check (status == 200) "profile import"
  let .ok original ← openAirVpnSecret dir (.device "device")
    | throw (IO.userError "sealed profile unavailable")
  check (original == profile) "profile round trip"
  let (invalidEdit, _) ← upload "device" "[Interface]"
  check (invalidEdit == 400) "malformed replacement rejected"
  check ((← openAirVpnSecret dir (.device "device")).toOption == some profile)
    "previous device retained on invalid edit"
  let (keyStatus, _) ← put (.obj #[("api_key", .str "synthetic-api-key")])
  check (keyStatus == 200) "api key saved"
  let (readStatus, summary) ← settings dir "GET" ByteArray.empty
  check (readStatus == 200 && summary.fieldBool? "api_key_configured" == some true &&
      ((summary.fieldArr? "devices").getD #[]).map JVal.asStr? == #[some "device"])
    "settings report configured device names"
  check (!(renderCompact summary).contains "synthetic-api-key" && !(renderCompact summary).contains key)
    "settings omit key and profile material"

end OrbCore.AirVpnSettingsTests
