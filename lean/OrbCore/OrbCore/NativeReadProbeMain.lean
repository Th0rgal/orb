import OrbCore.ProviderUsageAndLogin
import OrbCore.AccountVpnRelay

open OrbCore.Store OrbCore.ProviderUsageAndLogin OrbBin.Sqlite OrbBin.Json

/-- Operator-only, one bounded generation, private dev service context and an authenticated
    member selection. This executable cannot run a user prompt or open a writable database. -/
def main (args : List String) : IO UInt32 := do
  let [dbFile, root, work, owner, account, model, runtime, profileUser] := args | return 2
  unless (← IO.getEnv "ORB_INSTANCE") == some "dev" && (← IO.getEnv "ORB_HERMETIC_TEST") == some "1" &&
    (← IO.getEnv "CLI_PROXY_AUTH_DIR").any (!·.isEmpty) && !owner.isEmpty && !account.isEmpty &&
    ["gemini-4-carbon-high", "gemini-4-neon-high"].contains model do return 2
  let some relayKey ← IO.getEnv "JWT_SECRET" | return 2
  let some portRaw ← IO.getEnv "ORB_AIRVPN_RELAY_PORT" | return 2
  let some port := portRaw.toNat? | return 2
  unless port > 0 && port < 65536 && !relayKey.isEmpty do return 2
  let h ← sqliteOpenReadOnlyRaw dbFile
  if h == 0 then return 2
  try
    let db : SqliteDb := ⟨h, dbFile, ← Std.Mutex.new ()⟩
    let store : CoreStore := {
      rootDir := root
      missionsDb := db
      projectsDb := db
      askDb := db
      idempotencyDb := db
      closedRef := ← IO.mkRef false }
    let allowed := fun _ : Unit => do
      let .ok users ← execParamQuery db
        "SELECT id FROM users WHERE id=?1 AND role='member' AND disabled=0;" #[owner] | return false
      if users.size != 2 then return false
      return isUserProviderEnabled (← getUserProviderPrefs store owner) account
    unless ← allowed () do return 3
    let .ok (some route) ← OrbCore.AccountVpnRoutes.read db account | return 3
    unless route.country == "NL" do return 3
    let providers ← loadHydratedProviders store work
    let some hp := providers.find? (·.id == account) | return 3
    unless hp.enabled && hp.providerType == "antigravity" && hp.hasOAuth && !hp.oauthToken.isEmpty &&
        !(accountRoutingFile providers hp).isEmpty do return 3
    let capsule := JVal.obj #[("account", .str account), ("model", .str model), ("relay_port", .nat port),
      ("access_token", .str hp.oauthToken), ("relay_password", .str (OrbCore.AccountVpnRelay.password relayKey ("antigravity/" ++ account)))]
    let child ← IO.Process.spawn {
      cmd := "/usr/bin/python3"
      args := #["-I", runtime ++ "/native_job_relay/read_probe.py", runtime, profileUser]
      inheritEnv := false
      env := #[("PATH", some (runtime ++ "/bin:/usr/sbin:/usr/bin:/bin"))]
      stdin := .piped
      stdout := .piped
      stderr := .null }
    let (input, running) ← child.takeStdin
    let feed := fun (pipe : IO.FS.Handle) => pipe.putStr (renderCompact capsule ++ "\n") *> pipe.flush
    feed input
    let started ← IO.monoMsNow
    repeat
      if (← running.tryWait).isSome then break
      IO.sleep 250
      unless (← allowed ()) && (← OrbCore.AccountVpnRoutes.checkGeneration db account route.generation).isOk &&
          (← IO.monoMsNow) < started + 60000 do
        running.kill
        discard running.wait
        return 3
    let line ← running.stdout.getLine
    let .ok receipt := OrbBin.Json.parse line | return 4
    let kind := (receipt.fieldStr? "result").getD "probe_unavailable"
    let known := ["verified", "timeout", "authentication_required", "provider_denied", "quota", "model_unavailable",
      "response_mismatch", "native_error", "probe_unavailable", "oversized_response",
      "catalog_timeout", "catalog_unavailable", "model_not_in_catalog", "catalog_isolation_unavailable",
      "catalog_library_unavailable", "catalog_authentication_required", "catalog_provider_denied", "catalog_transport_unavailable"]
    unless known.contains kind do return 4
    let selected := (receipt.fieldStr? "selected").getD model
    unless [model, "gemini-4-carbon", "gemini-4-neon"].contains selected do return 4
    let labels := ["generation", "userinfo", "fetch_user_info", "load_code_assist", "catalog", "headless_eligibility",
      "unknown", "PERMISSION_DENIED", "UNAUTHENTICATED", "RESOURCE_EXHAUSTED", "NOT_FOUND", "unspecified",
      "account_verification", "consumer_eligibility", "terms", "region", "insufficient_scope", "disabled_api",
      "project_permission", "model_access"]
    let safe := fun k => (receipt.fieldStr? k).filter labels.contains |>.getD "unknown"
    IO.println (renderCompact (.obj #[("model", .str selected), ("country", .str route.country),
      ("route_generation", .nat route.generation), ("result", .str kind), ("phase", .str (safe "phase")),
      ("observed_phase", .str (safe "observed_phase")), ("native_code", .str (safe "native_code")),
      ("reason", .str (safe "reason")), ("native_http", .nat (min 599 ((receipt.fieldNat? "native_http").getD 0))),
      ("userinfo_status", .nat (min 599 ((receipt.fieldNat? "userinfo_status").getD 0)))]))
    return if kind == "verified" then 0 else 4
  finally sqliteCloseRaw h
