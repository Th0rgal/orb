import OrbBin.HttpClient
import OrbCore.Managed

namespace OrbCore.AirVpnSettings

open OrbBin.Json OrbBin.PosixExt OrbCore.Managed

/-- Accept the single-interface, single-peer data fields used by AirVPN's
WireGuard exporter. Never import shell directives from wg-quick profiles. -/
def validateProfile (raw : String) : Except String Unit := do
  let mut stanza := ""
  let mut seen : List (String × String) := []
  for rawLine in raw.splitOn "\n" do
    let line := rawLine.trimAscii.toString
    if line.isEmpty || line.startsWith "#" then continue
    if line == "[Interface]" && stanza.isEmpty then
      stanza := "interface"
      continue
    if line == "[Peer]" && stanza == "interface" then
      stanza := "peer"
      continue
    let name := (line.takeWhile (· != '=')).toString
    unless line.contains '=' do throw "invalid_wireguard_profile"
    let value := (line.drop (name.length + 1)).trimAscii.toString
    let field := name.trimAscii.toString
    let permitted := if stanza == "interface" then
        ["PrivateKey", "Address", "DNS", "MTU"]
      else if stanza == "peer" then
        ["PublicKey", "PresharedKey", "Endpoint", "AllowedIPs", "PersistentKeepalive"]
      else []
    unless permitted.contains field && !(seen.contains (stanza, field)) &&
        !value.isEmpty && value.toList.all (fun (c : Char) => c.isAlphanum || "+/=.,:-[] ".contains c) do
      throw "invalid_wireguard_profile"
    if ["PrivateKey", "PublicKey", "PresharedKey"].contains field then
      unless (base64Decode? value).any (·.size == 32) do throw "invalid_wireguard_key"
    seen := (stanza, field) :: seen
  for pair in [("interface", "PrivateKey"), ("interface", "Address"),
      ("peer", "PublicKey"), ("peer", "Endpoint"), ("peer", "AllowedIPs")] do
    unless seen.contains pair do throw "incomplete_wireguard_profile"

/-- Missing session evidence cannot be interpreted as a free slot. -/
def sessionCount? (response : JVal) : Option Nat := do
  guard (response.fieldStr? "result" == some "ok")
  let sessions ← response.fieldArr? "sessions"
  return sessions.size

private def testKey (root : String) : IO (Nat × JVal) := do
  let .ok key ← openAirVpnSecret root .apiKey
    | return (409, .obj #[("error", .str "airvpn_api_key_unavailable")])
  let payload := JVal.obj #[("key", .str key), ("format", .str "json")]
  let .ok (200, _, some response) ← OrbBin.HttpClient.sendJsonRequest "POST"
      "https://airvpn.org/api/userinfo/" none (some payload) #[] 10000 262144
    | return (502, .obj #[("error", .str "airvpn_session_lookup_failed")])
  let some count := sessionCount? response
    | return (502, .obj #[("error", .str "airvpn_session_evidence_unavailable")])
  return (200, .obj #[("active_sessions", .num (toString count))])

def settings (root method : String) (payload : ByteArray) : IO (Nat × JVal) := do
  let err := fun (status : Nat) (code : String) => (status, JVal.obj #[("error", .str code)])
  if method == "GET" then
    let dir := managedSecretDir root
    let mut profiles : Array String := #[]
    if ← dir.pathExists then
      for entry in ← dir.readDir do
        if entry.fileName.startsWith "airvpn-device-" && entry.fileName.endsWith ".aead" then
          profiles := profiles.push ((entry.fileName.drop 14).dropEnd 5).toString
    return (200, .obj #[("api_key_configured", .bool (← airVpnSecretConfigured root .apiKey)),
      ("devices", .arr ((profiles.qsort (· < ·)).map JVal.str))])
  if method == "POST" then return ← testKey root
  if method != "PUT" then return err 405 "method_not_allowed"
  if payload.size > 32768 then return err 413 "settings_too_large"
  let .ok j := parseBytes payload | return err 400 "invalid_json"
  let (secret, value) ← match j.fieldStr? "api_key", j.fieldStr? "device_id", j.fieldStr? "profile" with
    | some key, none, none => do
      let clean := key.trimAscii.toString
      if clean.isEmpty || clean.length > 512 || clean.any Char.isWhitespace then
        return err 400 "invalid_airvpn_api_key"
      pure (AirVpnSecret.apiKey, clean)
    | none, some id, some profile => do
      if let .error e := validateProfile profile then return err 400 e
      pure (AirVpnSecret.device id, profile)
    | _, _, _ => return err 400 "expected_api_key_or_device_profile"
  match ← sealAirVpnSecret root secret value with
  | .ok () => return (200, .obj #[("saved", .bool true)])
  | .error "invalid_airvpn_device" => return err 400 "invalid_airvpn_device"
  | .error "managed_secret_seal_busy" => return err 409 "secret_store_busy"
  | .error _ => return err 503 "secret_store_unavailable"

end OrbCore.AirVpnSettings
