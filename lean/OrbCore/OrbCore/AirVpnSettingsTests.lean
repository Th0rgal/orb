import OrbCore.AirVpnSettings
import OrbCore.AirVpnTunnel
import OrbCore.AccountVpnApi
import OrbCore.ProviderCredentialIdentity

namespace OrbCore.AirVpnSettingsTests

open OrbBin.Json OrbCore.Managed OrbCore.AirVpnSettings

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"airvpn settings: {label}")

private def routeStorage (root : String) : IO Unit := do
  let path := root ++ "/vpn-prefs-test.db"
  let openDb := OrbBin.Sqlite.openSqliteDb path OrbCore.Store.missionsSchemaSql #[]
  let db ← IO.ofExcept (← openDb)
  try
    let blocked := fun (_ : AccountVpnRoutes.Preference) => pure (.error "unverified")
    check ((← AccountVpnRoutes.resolve db "a" blocked).toOption == some none) "legacy Direct route"
    check (← AccountVpnRoutes.set db "a" (some "NL")).isOk "enable VPN for one account"
    let some first := (← AccountVpnRoutes.read db "a").toOption.join | throw (IO.userError "vpn preference missing")
    check (← AccountVpnRoutes.rememberServer db "a" first "west").isOk "remember verified server"
    check (← AccountVpnRoutes.set db "a" (some "NL")).isOk "retry preference save"
    check ((← AccountVpnRoutes.resolve db "a" blocked).isOk == false &&
      (← AccountVpnRoutes.resolve db "b" blocked).toOption == some none) "unavailable VPN scoped to selected account"
    check (← AccountVpnRoutes.set db "a" none).isOk "switch to Direct"
    check (← AccountVpnRoutes.set db "a" (some "NL")).isOk "switch back to VPN"
    check (!(← AccountVpnRoutes.rememberServer db "a" first "stale").isOk) "stale observation after re-enable"
    let some current := (← AccountVpnRoutes.read db "a").toOption.join | throw (IO.userError "current route missing")
    check (← AccountVpnRoutes.rememberServer db "a" current "east").isOk "save new generation server"
  finally discard <| OrbBin.Sqlite.sqliteCloseRaw db.handle
  let .ok reopened ← openDb | throw (IO.userError "vpn db reopen")
  try
    let pref := (← AccountVpnRoutes.read reopened "a").toOption.join
    check (pref.any (fun p => p.country == "NL" && p.preferredServer == "east")) "server survives restart"
    check (!(← AccountVpnRoutes.resolve reopened "a" (fun _ => pure (.ok 0))).isOk)
      "restart requires a live transport"
  finally discard <| OrbBin.Sqlite.sqliteCloseRaw reopened.handle

def run (root : String) : IO Unit := do
  let cat := AccountVpnPool.category
  check (cat "ChatGPT" == cat " Codex " && cat "Gemini" == cat "google" &&
    cat "Claude" != cat "ChatGPT") "credential category aliases"
  let exits := [Orb.AccountVpn.ExitAddress.v4 1, .v6 0 42]
  let .ok firstLocks ← AccountVpnPool.lockExits root (cat "codex") exits | throw (IO.userError "first VPN lease")
  try
    check (!(← AccountVpnPool.lockExits root (cat "chatgpt") [.v4 2, .v6 0 42]).isOk)
      "same-category overlap across independent file handles"
    let .ok second ← AccountVpnPool.lockExits root (cat "claude") exits | throw (IO.userError "cross-category VPN lease")
    second.forM fun fd => OrbBin.PosixExt.closeFdRaw fd.toInt32
    let .ok released ← AccountVpnPool.lockExits root (cat "codex") [.v4 2] | throw (IO.userError "partial lease retained")
    released.forM fun fd => OrbBin.PosixExt.closeFdRaw fd.toInt32
  finally firstLocks.forM fun fd => OrbBin.PosixExt.closeFdRaw fd.toInt32
  let reject : OrbBin.HttpClient.ResolveTransport := pure (.error "account_vpn_unavailable")
  let denied ← OrbBin.HttpClient.sendJsonRequest "GET" "https://example.invalid/quota" none none #[] 50 4096
    (resolveTransport? := some reject)
  check (match denied with | .error e => e == "account_vpn_unavailable" | _ => false) "quota request requires verified transport"
  let viaVpn : OrbBin.HttpClient.ResolveTransport := pure (.ok (some 30001))
  let plain ← OrbBin.HttpClient.sendRequest "GET" "http://127.0.0.1:1/status"
    (resolveTransport? := some viaVpn)
  check (match plain with | .error e => e == "vpn_requires_tls" | _ => false) "plaintext quota bypass rejected"
  let store ← IO.ofExcept (← OrbCore.Store.openCoreStore (root ++ "/vpn-api"))
  try
    let pool ← Std.Mutex.new ([] : List AccountVpnPool.Active)
    let route := AccountVpnApi.route store (some pool) "" "a" "openai"
    let payload := "{\"mode\":\"vpn\",\"country\":\"NL\"}".toUTF8
    let (sidecar, _) ← route false "PUT" payload
    check (sidecar == 409) "unsupported credential owner cannot enable VPN"
    let (saved, state) ← route true "PUT" payload
    check (saved == 200 && state.fieldStr? "mode" == some "vpn" &&
      state.fieldStr? "status" == some "blocked" &&
      state.fieldStr? "reason" == some "vpn_coordinator_unconfigured") "saved VPN reports blocked with reason"
    let (_, direct) ← route true "PUT" "{\"mode\":\"direct\"}".toUTF8
    check (direct.fieldStr? "mode" == some "direct" && (direct.field? "exits").isNone) "direct clears VPN selection"
  finally OrbCore.Store.closeCoreStore store
  let first : ProviderUsageAndLogin.CliAuthFileInfo := { (default : ProviderUsageAndLogin.CliAuthFileInfo) with
    fileName := "one.json", authType := "codex", prefixId := "first" }
  let second := { first with fileName := "two.json", prefixId := "second" }
  let identify := ProviderUsageAndLogin.matchCredential? #[first, second]
  check ((identify "first" true "" "" "" "" false).any (·.fileName == "one.json") &&
    (identify "db-row" false "two.json" "" "" "" false).any (·.fileName == "two.json"))
    "same-category sidecar account matched independently"
  check ((identify "first" false "two.json" "" "" "" false).isNone &&
    (identify "db-row" false "" "" "" "" true).isNone &&
    (identify "db-row" true "two.json" "" "" "" false).isNone)
    "conflicting, ambiguous and member-unowned bindings rejected"
  check (ProviderUsageAndLogin.fileAccountId "openai" first.fileName != ProviderUsageAndLogin.fileAccountId "openai" second.fileName)
    "two unprefixed auth files get distinct IDs"
  routeStorage root
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
  let dualStack := profile.replace "10.2.0.2/32" "10.2.0.2, fd00::2/128"
  check ((parseProfile dualStack).toOption.any (fun p => p.addresses.length == 2))
    "bare addresses and CIDR addresses can coexist in WireGuard export"
  check (!(parseProfile (profile.replace "10.2.0.2/32" "10.2.0.2/33")).isOk)
    "reject out-of-range prefix length"
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
  let (namedStatus, _) ← put (.obj #[("device_id", .str "device"), ("profile", .str profile),
    ("country", .str "NL"), ("server", .str "west")])
  check (namedStatus == 200 && (← endpoints dir) == [⟨"device", "NL", "west"⟩])
    "named server metadata and device profile updated together"
  let (keyStatus, _) ← put (.obj #[("api_key", .str "synthetic-api-key")])
  check (keyStatus == 200) "api key saved"
  let (readStatus, summary) ← settings dir "GET" ByteArray.empty
  check (readStatus == 200 && summary.fieldBool? "api_key_configured" == some true &&
      ((summary.fieldArr? "devices").getD #[]).map JVal.asStr? == #[some "device"])
    "settings report configured device names"
  check (!(renderCompact summary).contains "synthetic-api-key" && !(renderCompact summary).contains key)
    "settings omit key and profile material"

end OrbCore.AirVpnSettingsTests
