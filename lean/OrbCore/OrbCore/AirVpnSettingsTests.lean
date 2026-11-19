import OrbCore.AirVpnSettings
import Orb.AccountVpn

namespace OrbCore.AirVpnSettingsTests

open OrbBin.Json OrbCore.Managed OrbCore.AirVpnSettings

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"airvpn settings: {label}")

def run (root : String) : IO Unit := do
  let dir := root ++ "/airvpn-settings-test"
  check ((sessionCount? (.obj #[("result", .str "ok")])).isNone)
    "missing session list cannot admit a new tunnel"
  check (sessionCount? (.obj #[("result", .str "ok"), ("sessions", .arr #[])]) == some 0)
    "explicit empty session list"
  let key := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  let profile := s!"[Interface]\nAddress = 10.2.0.2/32\nPrivateKey = {key}\n[Peer]\nPublicKey = {key}\nEndpoint = example.invalid:1637\nAllowedIPs = 0.0.0.0/0"
  let put := fun (value : JVal) => settings dir "PUT" (renderCompact value).toUTF8
  let upload := fun id content => put (.obj #[("device_id", .str id), ("profile", .str content)])
  let (invalid, _) ← upload "../boat" profile
  check (invalid == 400) "invalid device path rejected"
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
