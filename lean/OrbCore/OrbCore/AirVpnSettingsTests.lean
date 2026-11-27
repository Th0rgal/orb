import OrbCore.AccountVpnRelayTests
import OrbCore.AirVpnSettings
import OrbCore.AirVpnTunnel
import OrbCore.AccountVpnApi
import OrbCore.ProviderCredentialIdentity

namespace OrbCore.AirVpnSettingsTests

open OrbBin.Json OrbCore.Managed OrbCore.AirVpnSettings

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"airvpn settings: {label}")

/-- A failing check may already have collected the fixture process. -/
private def stopFixture (child : AirVpnTunnel.Child) : IO Unit :=
  try
    child.kill
    discard child.wait
  catch _ => pure ()

private def routeStorage (root : String) : IO Unit := do
  let path := root ++ "/vpn-prefs-test.db"
  let openDb := OrbBin.Sqlite.openSqliteDb path OrbCore.Store.missionsSchemaSql #[]
  let db ← IO.ofExcept (← openDb)
  try
    let blocked := fun (_ : AccountVpnRoutes.Preference) => pure (.error "unverified")
    check ((← AccountVpnRoutes.resolve db "a" blocked).toOption == some none) "legacy Direct route"
    check (← AccountVpnRoutes.set db "a" none).isOk "explicit Direct on legacy account"
    check (← AccountVpnRoutes.checkGeneration db "a" 0).isOk "unchanged legacy Direct exchange remains valid"
    check (← AccountVpnRoutes.set db "a" none).isOk "retry explicit Direct"
    check (← AccountVpnRoutes.checkGeneration db "a" 1).isOk "saved Direct choice is idempotent"
    check (← AccountVpnRoutes.set db "a" (some "NL")).isOk "enable VPN for one account"
    let some first := (← AccountVpnRoutes.read db "a").toOption.join | throw (IO.userError "vpn preference missing")
    check (!(← AccountVpnRoutes.checkGeneration db "a" 0).isOk &&
      (← AccountVpnRoutes.checkGeneration db "a" first.generation).isOk)
      "a pending Direct exchange must restart after enabling VPN"
    check (← AccountVpnRoutes.rememberServer db "a" first "west").isOk "remember verified server"
    check (← AccountVpnRoutes.set db "a" (some "NL")).isOk "retry preference save"
    check ((← AccountVpnRoutes.resolve db "a" blocked).isOk == false &&
      (← AccountVpnRoutes.resolve db "b" blocked).toOption == some none) "unavailable VPN scoped to selected account"
    check (← AccountVpnRoutes.set db "a" none).isOk "switch to Direct"
    check (!(← AccountVpnRoutes.checkGeneration db "a" 0).isOk)
      "a Direct OAuth callback cannot survive a Direct to VPN to Direct cycle"
    let .ok (.direct revision) ← AccountVpnRoutes.snapshot db "a" | throw (IO.userError "Direct revision missing")
    check (← AccountVpnRoutes.set db "a" none).isOk "retry Direct"
    check (← AccountVpnRoutes.checkGeneration db "a" revision).isOk "unchanged Direct exchange remains valid"
    check (← AccountVpnRoutes.set db "a" (some "NL")).isOk "switch back to VPN"
    check (!(← AccountVpnRoutes.rememberServer db "a" first "stale").isOk) "stale observation after re-enable"
    let pool ← Std.Mutex.new ({} : AccountVpnPool.PoolState)
    check (!(← AccountVpnRoutes.checkGeneration db "a" first.generation).isOk)
      "a pending VPN exchange cannot use a replacement route generation"
    let stale ← AccountVpnPool.allocate pool root root db "a" "openai" first
    check (match stale with | .error "vpn_route_changed" => true | _ => false)
      "a delayed request cannot allocate or detach a newer generation"
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
  AccountVpnRelayTests.run
  let cat := Orb.AccountVpn.canonicalCategory
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
    let pool ← Std.Mutex.new ({} : AccountVpnPool.PoolState)
    let route := AccountVpnApi.route store (some pool) "" "a" "openai"
    let payload := "{\"mode\":\"vpn\",\"country\":\"NL\"}".toUTF8
    let (sidecar, _) ← route false "PUT" payload
    check (sidecar == 409) "unsupported credential owner cannot enable VPN"
    let refuse : Bool → IO (Except String Unit) := fun (_ : Bool) => pure (.error "vpn_sidecar_update_failed" : Except String Unit)
    let (failed, _) ← AccountVpnApi.route store (some pool) "" "a" "openai" true "PUT" payload (some refuse)
    let (_, afterFailure) ← route true "GET" ByteArray.empty
    check (failed == 503 && afterFailure.fieldStr? "mode" == some "direct")
      "failed sidecar enable cannot commit the VPN preference"
    let patched ← IO.mkRef false
    let configure : Bool → IO (Except String Unit) := fun (enable : Bool) => do
      let .ok none ← AccountVpnRoutes.read store.missionsDb "a" | return .error "unexpected_phase"
      patched.set enable
      return .ok ()
    let (saved, state) ← AccountVpnApi.route store (some pool) "" "a" "openai" true "PUT" payload (some configure)
    check (← patched.get) "sidecar bound before VPN admission"
    check (saved == 200 && state.fieldStr? "mode" == some "vpn" &&
      state.fieldStr? "status" == some "blocked" &&
      state.fieldStr? "reason" == some "vpn_coordinator_unconfigured") "saved VPN reports blocked with reason"
    let reload := AccountVpnApi.route store (some pool) root "a" "openai"
    let (_, noProfile) ← reload true "PUT" payload
    check (noProfile.fieldStr? "reason" == some "vpn_no_compatible_profile")
      "verification reports the missing country profile"
    let (_, reopened) ← reload true "GET" ByteArray.empty
    check (reopened.fieldStr? "reason" == noProfile.fieldStr? "reason" &&
      reopened.fieldStr? "message" == noProfile.fieldStr? "message")
      "reopening Settings retains the actionable failure"
    let (_, direct) ← AccountVpnApi.route store (some pool) "" "a" "openai" true "PUT" "{\"mode\":\"direct\"}".toUTF8 (some configure)
    check (!(← patched.get)) "sidecar unbound after explicit Direct selection"
    check (direct.fieldStr? "mode" == some "direct" && (direct.field? "exits").isNone) "direct clears VPN selection"
    let db := store.missionsDb
    IO.ofExcept (← AccountVpnPool.savePreference pool db "v" (some "NL"))
    let .ok (some pref) ← AccountVpnRoutes.read db "v" | throw (IO.userError "fixture VPN preference")
    IO.ofExcept (← AccountVpnPool.savePreference pool db "w" (some "NL"))
    let .ok (some sharing) ← AccountVpnRoutes.read db "w" | throw (IO.userError "fixture sharing preference")
    let child ← IO.Process.spawn { cmd := "sleep", args := #["30"], stdin := .null, stdout := .null, stderr := .null }
    let seen := [Orb.AccountVpn.ExitAddress.v4 0x01020304, .v6 0x20010db800000000 1]
    let gateway : AccountVpnPool.Gateway := ⟨30002, ← IO.mkRef false⟩
    let tunnel : AirVpnTunnel.Tunnel :=
      ⟨child, 30002, seen, ← IO.mkRef none, ← IO.Promise.new, ← IO.asTask (pure ()), ← IO.mkRef false⟩
    let occupant : AccountVpnPool.Occupant := ⟨⟨"v", cat "openai", "NL", seen⟩, pref.generation, [], gateway⟩
    -- An account of another category shares the tunnel and both of its exits.
    let sharer : AccountVpnPool.Occupant :=
      ⟨⟨"w", cat "claude", "NL", seen⟩, sharing.generation, [], ⟨30002, ← IO.mkRef false⟩⟩
    let running : AccountVpnPool.Active :=
      { endpoint := ⟨"device", "NL", "west"⟩, tunnel, evidence := ⟨"west", "NL", seen⟩, occupants := [occupant, sharer] }
    pool.atomically <| set ({ active := [running] } : AccountVpnPool.PoolState)
    let shown := AccountVpnApi.route store (some pool) root "v" "openai" true "GET" ByteArray.empty
    let shownSharer := AccountVpnApi.route store (some pool) root "w" "claude" true "GET" ByteArray.empty
    let (_, verified) ← shown
    check (verified.fieldStr? "mode" == some "vpn" && verified.fieldStr? "country" == some "NL" &&
      verified.fieldStr? "status" == some "verified" && verified.fieldStr? "server" == some "west" &&
      ((verified.fieldArr? "exits").getD #[]).map JVal.asStr? == #[some "1.2.3.4", some "2001:db8:0:0:0:0:0:1"] &&
      verified.fieldBool? "can_configure" == some true && (verified.fieldArr? "countries").isSome)
      "verified route names its server and both exits"
    let liveSummaries ← AccountVpnPool.activeTunnels pool
    check (liveSummaries.size == 1 &&
      liveSummaries[0]!.fieldStr? "device" == some "device" &&
      liveSummaries[0]!.fieldStr? "country" == some "NL" &&
      liveSummaries[0]!.fieldStr? "server" == some "west" &&
      liveSummaries[0]!.fieldNat? "accounts" == some 2 &&
      ((liveSummaries[0]!.fieldArr? "exits").getD #[]).map JVal.asStr? == #[some "1.2.3.4", some "2001:db8:0:0:0:0:0:1"])
      "activeTunnels reports live shared tunnel metadata and occupant count"
    -- The state every check after the first one finds once the tunnel process has exited.
    child.kill
    discard child.wait
    let (stopped, afterExit) ← shown
    check (stopped == 200 && afterExit.fieldStr? "status" == some "blocked" && (afterExit.field? "exits").isNone)
      "exited tunnel is no longer shown as a verified exit"
    check (afterExit.fieldStr? "reason" == some "vpn_tunnel_stopped" &&
      (afterExit.fieldStr? "message").any (·.startsWith "The VPN tunnel stopped."))
      "a stopped tunnel is reported as a failure to retry, not as awaiting verification"
    check (← tunnel.reaped.get) "the first observed exit is recorded on the tunnel"
    check ((← AccountVpnPool.activeTunnels pool).isEmpty)
      "activeTunnels omits an already-reaped tunnel without calling waitpid again"
    -- If activeTunnels observes an exited child first, it must record `reaped` so later stops never signal a reused PID.
    let shortLived ← IO.Process.spawn { cmd := "true", args := #[], stdin := .null, stdout := .null, stderr := .null }
    IO.sleep 100
    let shortTunnel : AirVpnTunnel.Tunnel :=
      ⟨shortLived, 30003, seen, ← IO.mkRef none, ← IO.Promise.new, ← IO.asTask (pure ()), ← IO.mkRef false⟩
    pool.atomically <| set ({ active := [{ running with tunnel := shortTunnel }] } : AccountVpnPool.PoolState)
    check ((← AccountVpnPool.activeTunnels pool).isEmpty && (← shortTunnel.reaped.get))
      "activeTunnels records tunnel exit via Tunnel.exited when observing exit first"
    pool.atomically <| set ({ active := [running] } : AccountVpnPool.PoolState)
    let refused ← AccountVpnPool.allocate pool store.rootDir root db "v" "openai" pref
    check (refused.toOption.isNone && (← gateway.revoked.get) && (← pool.atomically get).active.isEmpty)
      "exited tunnel is refused, revoked and retired"
    let (_, reported) ← shown
    check (reported.fieldStr? "status" == some "blocked" && reported.fieldStr? "reason" != some "vpn_awaiting_verification")
      "settings report why the exited tunnel was not replaced"
    let (_, left) ← shownSharer
    check (left.fieldStr? "status" == some "blocked" && left.fieldStr? "reason" == some "vpn_tunnel_stopped")
      "an account sharing a tunnel retired by another account's request is told it stopped"
    -- The system may reissue the process id of a collected child. A running
    -- process stands in for the one that received it.
    let bystander ← IO.Process.spawn { cmd := "sleep", args := #["30"], stdin := .null, stdout := .null, stderr := .null }
    try
      let collected : AirVpnTunnel.Tunnel :=
        ⟨bystander, 30002, seen, ← IO.mkRef none, ← IO.Promise.new, ← IO.asTask (pure ()), ← IO.mkRef true⟩
      pool.atomically <| set ({ active := [{ running with tunnel := collected }] } : AccountVpnPool.PoolState)
      check ((← AccountVpnPool.activeTunnels pool).isEmpty)
        "activeTunnels ignores a collected tunnel even when another process reuses its PID"
      let (_, reused) ← shown
      check (reused.fieldStr? "reason" == some "vpn_tunnel_stopped")
        "a process that reuses a collected tunnel's id is not shown as its verified exit"
      discard <| AccountVpnPool.allocate pool store.rootDir root db "v" "openai" pref
      let spared ← try pure (← bystander.tryWait).isNone catch _ => pure false
      check ((← pool.atomically get).active.isEmpty && spared)
        "retiring a collected tunnel does not signal the process that reuses its id"
      -- An account of another category asks to join a tunnel that has stopped.
      pool.atomically <| set ({ active := [{ running with tunnel := collected, occupants := [sharer] }] } : AccountVpnPool.PoolState)
      discard <| AccountVpnPool.allocate pool store.rootDir root db "v" "openai" pref
      let (_, joined) ← shownSharer
      check ((← pool.atomically get).active.isEmpty && joined.fieldStr? "reason" == some "vpn_tunnel_stopped")
        "an account on a tunnel retired when another account tried to join it is told it stopped"
      -- Rotating the API key or deleting an active device profile retires affected tunnels and reports vpn_tunnel_stopped to every occupant.
      let gwV1 : AccountVpnPool.Gateway := ⟨30004, ← IO.mkRef false⟩
      let gwW1 : AccountVpnPool.Gateway := ⟨30004, ← IO.mkRef false⟩
      let activeForSave : AccountVpnPool.Active :=
        { running with tunnel := collected, occupants := [{ occupant with gateway := gwV1 }, { sharer with gateway := gwW1 }] }
      pool.atomically <| set ({ active := [activeForSave] } : AccountVpnPool.PoolState)
      IO.ofExcept (← AccountVpnPool.saveSecret pool store.rootDir .apiKey "rotated-api-key")
      let (_, afterKeyV) ← shown
      let (_, afterKeyW) ← shownSharer
      check ((← gwV1.revoked.get) && (← gwW1.revoked.get) && (← AccountVpnPool.activeTunnels pool).isEmpty &&
        afterKeyV.fieldStr? "reason" == some "vpn_tunnel_stopped" &&
        afterKeyW.fieldStr? "reason" == some "vpn_tunnel_stopped")
        "saveSecret retirement revokes gateways and reports vpn_tunnel_stopped to all occupants"
      let gwV2 : AccountVpnPool.Gateway := ⟨30005, ← IO.mkRef false⟩
      let gwW2 : AccountVpnPool.Gateway := ⟨30005, ← IO.mkRef false⟩
      let activeForDel : AccountVpnPool.Active :=
        { running with tunnel := collected, occupants := [{ occupant with gateway := gwV2 }, { sharer with gateway := gwW2 }] }
      pool.atomically <| set ({ active := [activeForDel] } : AccountVpnPool.PoolState)
      IO.ofExcept (← AccountVpnPool.deleteSecret pool store.rootDir (.device "device"))
      let (_, afterDelV) ← shown
      let (_, afterDelW) ← shownSharer
      check ((← gwV2.revoked.get) && (← gwW2.revoked.get) && (← AccountVpnPool.activeTunnels pool).isEmpty &&
        afterDelV.fieldStr? "reason" == some "vpn_tunnel_stopped" &&
        afterDelW.fieldStr? "reason" == some "vpn_tunnel_stopped")
        "deleteSecret retirement revokes gateways and reports vpn_tunnel_stopped to all occupants"
    finally stopFixture bystander
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
  let withEmail := { first with fileName := "different.json", prefixId := "", email := "shared@fixture.invalid" }
  check ((ProviderUsageAndLogin.matchCredential? #[withEmail] "legacy-row" false "missing.json" "" "" "shared@fixture.invalid" false).isNone &&
    (ProviderUsageAndLogin.matchCredential? #[withEmail] "legacy-row" false "missing.json" "" "" "shared@fixture.invalid" false true).any (·.fileName == "different.json"))
    "strict routing binding rejects stale filename email fallback while display fallback allows it"
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
  let sessions := #[JVal.obj #[("server_name", .str "West"), ("server_country_code", .str "nl"),
    ("exit_ip", .str "1.2.3.4")]]
  let observed := AirVpnObservation.verifyObservation?
  check ((observed "west" "NL" sessions v4 (some v6)).any (fun t => t.exits == [v4, v6]))
    "AirVPN lowercase country matches requested country and independent receiver"
  check ((observed "west" "US" sessions v4 none).isNone &&
      (observed "east" "NL" sessions v4 none).isNone &&
      (observed "west" "NL" sessions (.v4 123) none).isNone &&
      (observed "west" "NL" sessions v4 (some v4)).isNone)
    "country, server, source address and family mismatch reject"
  let missingDir ← AirVpnTunnel.startVerified root (root ++ "/missing/dir") "device" "east" "NL" 30001
  check (match missingDir with | .error "vpn_coordinator_unavailable" => true | _ => false)
    "missing coordinator directory needs an operator fix"
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
  let profiles := (summary.fieldArr? "profiles").getD #[]
  check (profiles.size == 1 && profiles[0]!.fieldStr? "device" == some "device" &&
      profiles[0]!.fieldStr? "country" == some "NL" && profiles[0]!.fieldStr? "server" == some "west")
    "settings report non-secret profile metadata"
  check (!(renderCompact summary).contains "synthetic-api-key" && !(renderCompact summary).contains key)
    "settings omit key and profile material"
  let (badDelete, _) ← settings dir "DELETE" "{\"device_id\":\"../boat\"}".toUTF8
  check (badDelete == 400) "invalid device delete rejected"
  let (delStatus, _) ← settings dir "DELETE" "{\"device_id\":\"device\"}".toUTF8
  let (_, afterDelete) ← settings dir "GET" ByteArray.empty
  check (delStatus == 200 && ((afterDelete.fieldArr? "devices").getD #[]).isEmpty &&
      ((afterDelete.fieldArr? "profiles").getD #[]).isEmpty)
    "device deletion clears sealed profile and summary"

end OrbCore.AirVpnSettingsTests
