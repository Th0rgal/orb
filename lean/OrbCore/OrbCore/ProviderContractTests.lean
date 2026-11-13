/-
  Provider wire regressions PROV01/PROV05. Expectations are frozen from the
  Rust DTO and existing client readers, not generated from the implementation.
  All credentials are inert fixtures. These tests do not probe any vendor.
  Run orb-core-test from the repository root, as required by the Core CI suite.
-/
import OrbCore.Control

namespace OrbCore.ProviderContractTests

open LeanSys.Http
open OrbBin.Json OrbBin.PosixExt
open OrbCore.Store OrbCore.Control OrbCore.R7Core OrbCore.Proxy OrbCore.Managed
open OrbCore.ProviderUsageAndLogin

private def getJson (app : CoreAppState) (jwt target : String) (now : UInt64) : IO JVal := do
  let raw := s!"GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let .ok req := parseRequest raw.toUTF8 none
    | throw (IO.userError "provider contract request parse failed")
  let .ok resp ← dispatchCoreRequest app req now
    | throw (IO.userError "provider contract dispatch failed")
  if resp.status != 200 then
    throw (IO.userError s!"provider contract GET {target}: expected 200, got {resp.status}")
  let .ok value := parseBytes resp.body
    | throw (IO.userError "provider contract response is not JSON")
  return value

private def postJson (app : CoreAppState) (jwt target body : String) (now : UInt64) : IO (Nat × JVal) := do
  let raw := s!"POST {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
  let .ok req := parseRequest raw.toUTF8 none
    | throw (IO.userError "provider contract request parse failed")
  let .ok resp ← dispatchCoreRequest app req now
    | throw (IO.userError "provider contract dispatch failed")
  return (resp.status, (parseBytes resp.body).toOption.getD .null)

/-- Loopback stand-in for the CLIProxyAPI management API: every request is answered 200
    `{"status":"ok"}` until `stop` is set. Returns the request lines it saw. -/
private def mockSidecar (fd : LeanSys.Posix.Fd) (stop : IO.Ref Bool) : IO (Task (Except IO.Error (Array String))) :=
  IO.asTask (prio := .dedicated) do
    let mut seen : Array String := #[]
    while !(← stop.get) do
      match ← LeanSys.Posix.tcpAcceptPoll fd 100 with
      | .ok client =>
        let req := String.fromUTF8! (← LeanSys.Posix.readStreamChunk client 8192)
        seen := seen.push ((req.splitOn "\r\n").headD "")
        let body := "{\"status\":\"ok\"}"
        discard <| LeanSys.Posix.writeAll client
          s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8
        discard <| LeanSys.Posix.closeFd client
      | .error _ => pure ()
    return seen

/-- Replay of 13 Nov 2026: an Anthropic login held by CLIProxyAPI is refused (usage cached at
    `needs_reauth` 98%, request evidence, a cooldown in both owners), the user reconnects, the
    sidecar acknowledges the callback and reports `ok` before the new auth file is on disk,
    then the file appears. Only HTTP routes are used, and no request is proxied. -/
private def replayReconnect (app : CoreAppState) (store : CoreStore) (root jwt : String) (now : UInt64)
    (hub : ProviderRuntimeHub) : IO (Array String) := do
  let mut failures : Array String := #[]
  let pid := "10000000-0000-4000-8000-000000000001"
  let other := "10000000-0000-4000-8000-000000000002"
  let key := "cliproxyapi:anthropic"
  let tracker ← newProviderHealthTracker
  let app := { app with healthTracker? := some tracker }
  let wallNow ← nowEpoch
  app.proxyCooldownsRef.set #[{ accountId := key, untilEpoch := wallNow + 2400, reason := .serverError }]
  tracker.health.atomically do
    modify fun s => { s with accounts := #[{
      accountId := key, slotId := accountSlotId key, parkedQuota := true,
      cooldown? := some { accountId := key, untilEpoch := wallNow + 2400, reason := .serverError }
    }] }
  discard <| execParamQuery store.missionsDb
    "INSERT INTO provider_auth_health(account_key,code,observed_at) VALUES(?1,'auth_unavailable','t0'),('cliproxyapi:codex','auth_unavailable','t0');" #[key]
  hub.mu.atomically do
    modify fun s => { s with
      usageEntries := #[pid, other].map fun id => {
        providerId := id, fetchedSec := 1, fetchedIso := "1970-01-01T00:00:01Z",
        payload := .obj #[("status", .str "needs_reauth"), ("usage_percent", JVal.nat 98)]
      }
      loginSessions := #[{
        sessionId := "reconnect-fixture", providerSlug := "anthropic", authFileType := "claude",
        targetProvId? := some pid, stateToken := "fixture-state", authUrl := "https://fixture.invalid/auth",
        flow := "redirect", createdSec := wallNow, beforeFiles := #[]
      }]
    }
  let statusOf := fun (v : JVal) => (v.fieldOrNull "status").fieldStr? "type"
  let (fd, port) ← IO.ofExcept (← LeanSys.Posix.tcpListen "127.0.0.1" 0 8)
  let priorBase ← IO.getEnv "CLAUDE_CODE_PROXY_BASE_URL"
  let priorKey ← IO.getEnv "CLI_PROXY_MANAGEMENT_KEY"
  setenvVar "CLAUDE_CODE_PROXY_BASE_URL" s!"http://127.0.0.1:{port}"
  setenvVar "CLI_PROXY_MANAGEMENT_KEY" "fixture-only"
  let stop ← IO.mkRef false
  let server ← mockSidecar fd stop
  try
    let before := (← getJson app jwt "/api/ai/providers" now).asArr?.getD #[]
    if statusOf ((before.find? (fun v => v.fieldStr? "id" == some pid)).getD .null) != some "needs_reauth" ||
       statusOf (← getJson app jwt s!"/api/ai/providers/{pid}" now) != some "needs_reauth" then
      failures := failures.push "reconnect: the refused login must show needs_reauth before reconnecting"
    let session := "/api/ai/providers/cli-proxy-login/reconnect-fixture"
    let (cbCode, cb) ← postJson app jwt s!"{session}/callback"
      "{\"url\":\"http://localhost:54545/callback?code=fixture-code&state=fixture-state\"}" now
    if cbCode != 200 || cb.fieldStr? "status" != some "completing" then
      failures := failures.push s!"reconnect: callback acknowledged before the auth file exists must answer completing, got {cbCode} {cb.fieldStr? "status"}"
    let early ← getJson app jwt session now
    if early.fieldStr? "status" != some "completing" then
      failures := failures.push s!"reconnect: sidecar ok without a visible auth file must stay completing, got {early.fieldStr? "status"}"
    IO.FS.writeFile s!"{root}/auth-empty/claude-reconnected.json"
      "{\"type\":\"claude\",\"email\":\"reconnected@fixture.invalid\",\"access_token\":\"fixture-only-no-live-access\"}"
    let done ← getJson app jwt session now
    if done.fieldStr? "status" != some "completed" then
      failures := failures.push s!"reconnect: session must complete once the auth file is visible, got {done.fieldStr? "status"}"
    let list := (← getJson app jwt "/api/ai/providers" now).asArr?.getD #[]
    let detail ← getJson app jwt s!"/api/ai/providers/{pid}" now
    let usagePath := s!"/api/ai/providers/{pid}/usage?cached_only=true"
    let mut usage ← getJson app jwt usagePath now
    for _ in [0:40] do
      if usage.fieldInt? "usage_percent" == some 3 then break
      IO.sleep 50
      usage ← getJson app jwt usagePath now
    if statusOf ((list.find? (fun v => v.fieldStr? "id" == some pid)).getD .null) != some "connected" then
      failures := failures.push "reconnect: list must show connected without a proxied request"
    if statusOf detail != some "connected" then
      failures := failures.push "reconnect: detail must show connected without a proxied request"
    if usage.fieldStr? "status" != some "connected" || usage.fieldInt? "usage_percent" != some 3 then
      failures := failures.push s!"reconnect: usage must be re-probed after the login, got {usage.fieldStr? "status"} {usage.fieldInt? "usage_percent"}"
    let otherUsage ← getJson app jwt s!"/api/ai/providers/{other}/usage?cached_only=true" now
    if otherUsage.fieldStr? "status" != some "needs_reauth" then
      failures := failures.push "reconnect: another provider's cached rejection must be kept"
    if (← app.proxyCooldownsRef.get).any (fun c => c.accountId == key) then
      failures := failures.push "reconnect: legacy cooldown on the sidecar login remains"
    if (← lookupAccountHealthRecord tracker key).cooldown?.isSome then
      failures := failures.push "reconnect: health tracker cooldown on the sidecar login remains"
    match ← execParamQuery store.missionsDb "SELECT account_key FROM provider_auth_health ORDER BY account_key;" #[] with
    | .ok rows =>
      let keys := rows.filterMap (·[0]?)
      if keys.contains key || !keys.contains "cliproxyapi:codex" then
        failures := failures.push s!"reconnect: only the reconnected login's evidence may be cleared: {keys}"
    | .error e => failures := failures.push s!"reconnect: evidence query failed: {e}"
  finally
    stop.set true
    discard <| IO.wait server
    discard <| LeanSys.Posix.closeFd fd
    match priorBase with
    | some value => setenvVar "CLAUDE_CODE_PROXY_BASE_URL" value
    | none => unsetenvVar "CLAUDE_CODE_PROXY_BASE_URL"
    match priorKey with
    | some value => setenvVar "CLI_PROXY_MANAGEMENT_KEY" value
    | none => unsetenvVar "CLI_PROXY_MANAGEMENT_KEY"
    discard <| execParamQuery store.missionsDb "DELETE FROM provider_auth_health;" #[]
    IO.FS.removeFile s!"{root}/auth-empty/claude-reconnected.json"
  return failures

/-- A sidecar `ok` alone never completes a login: only a new, enabled auth file of the session's
    type with a token does, and none within 60 s fails the session. -/
private def reconcileNegatives (hub : ProviderRuntimeHub) (store : CoreStore) (root : String)
    (cooldowns : IO.Ref (Array AccountCooldown)) : IO (Array String) := do
  let mut failures : Array String := #[]
  let created ← nowEpoch
  IO.FS.writeFile s!"{root}/auth-empty/claude-existing.json"
    "{\"type\":\"claude\",\"access_token\":\"fixture-only-no-live-access\"}"
  let sess : CliLoginSession := {
    sessionId := "negative", providerSlug := "anthropic", authFileType := "claude",
    targetProvId? := none, stateToken := "negative-state", authUrl := "fixture", flow := "redirect",
    createdSec := created, beforeFiles := (← scanCliProxyAuthFiles).map (fun f => (f.fileName, f.fingerprint))
  }
  try
    let waiting ← reconcileCliLoginCompletion hub store root cooldowns none sess created
    if waiting.status != "completing" then failures := failures.push "unchanged auth file must not complete login"
    IO.FS.writeFile s!"{root}/auth-empty/wrong-type.json" "{\"type\":\"codex\",\"access_token\":\"fixture-only-no-live-access\"}"
    IO.FS.writeFile s!"{root}/auth-empty/disabled.json" "{\"type\":\"claude\",\"disabled\":true,\"access_token\":\"fixture-only-no-live-access\"}"
    IO.FS.writeFile s!"{root}/auth-empty/no-token.json" "{\"type\":\"claude\"}"
    let stillWaiting ← reconcileCliLoginCompletion hub store root cooldowns none waiting (created + 59)
    if stillWaiting.status != "completing" then
      failures := failures.push "wrong-type, disabled and token-less files cannot complete login"
    let timedOut ← reconcileCliLoginCompletion hub store root cooldowns none stillWaiting (created + 60)
    if timedOut.status != "failed" || timedOut.message?.isNone then
      failures := failures.push "missing new auth file must fail with a message after 60 seconds"
  finally
    for f in #["claude-existing.json", "wrong-type.json", "disabled.json", "no-token.json"] do
      try IO.FS.removeFile s!"{root}/auth-empty/{f}" catch _ => pure ()
  return failures

/-- Replay the production renderers and HTTP dispatch, never a live usage fetch. -/
def run : IO Unit := do
  let fixtureRaw ← IO.FS.readFile "shared/orb-spec/fixtures/provider-response-contract.json"
  let .ok fixture := OrbBin.Json.parse fixtureRaw
    | throw (IO.userError "provider-response-contract fixture parse failed")
  let cases := (fixture.fieldArr? "providers").getD #[]
  if cases.isEmpty then throw (IO.userError "provider contract fixture is empty")
  let root := s!"/tmp/orb-provider-contract-{← newUuidV4}"
  IO.FS.createDirAll s!"{root}/.sandboxed-sh"
  IO.FS.createDirAll s!"{root}/auth-empty"
  let previousAuthDir ← IO.getEnv "CLI_PROXY_AUTH_DIR"
  setenvVar "CLI_PROXY_AUTH_DIR" s!"{root}/auth-empty"
  try
    let .ok store ← openCoreStore s!"{root}/.sandboxed-sh"
      | throw (IO.userError "provider contract store open failed")
    try
      IO.FS.writeFile s!"{root}/.sandboxed-sh/ai_providers.json"
        (renderCompact (.arr (cases.map (·.fieldOrNull "provider"))))
      let baseHub ← newProviderRuntimeHub
      let hub := { baseHub with usageProbe? := some (fun _ => pure (.obj #[("status", .str "connected"), ("usage_percent", JVal.nat 3)])) }
      let managedRef ← IO.mkRef ({} : ManagedFleetState)
      let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
      let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
      let seqRef ← IO.mkRef (1 : UInt64)
      let cfg : CoreConfig := {
        workingDir := root
        dashboardPassword := "provider-contract-fixture-password"
        jwtSecret := "provider-contract-fixture-jwt-secret-0123456789"
      }
      let app : CoreAppState := {
        cfg := cfg, store := store, searchIdx? := none,
        managedRef := managedRef, chainsRef := chainsRef,
        proxyCooldownsRef := cooldownsRef, seqRef := seqRef, providerHub? := some hub
      }
      let now : UInt64 := 1700001000
      let jwt := mintSessionToken cfg.jwtSecret (now + 3600)
      let mut failures : Array String := #[]
      let listed ← getJson app jwt "/api/ai/providers" now
      let items := listed.asArr?.getD #[]
      if items.size != cases.size then failures := failures.push "provider list row count"
      for c in cases do
        let input := c.fieldOrNull "provider"
        let id := (input.fieldStr? "id").getD ""
        let expected := (c.fieldStr? "expected_status").getD ""
        let detail ← getJson app jwt s!"/api/ai/providers/{id}" now
        let listItem := (items.find? (fun v => v.fieldStr? "id" == some id)).getD .null
        for (surface, actual) in #[("list", listItem), ("detail", detail)] do
          if (actual.fieldOrNull "status").fieldStr? "type" != some expected then
            failures := failures.push s!"{surface} status for {id}: expected {expected}"
          if actual.fieldBool? "enabled" != input.fieldBool? "enabled" then
            failures := failures.push s!"{surface} disabled/enabled state for {id}"
          if (actual.field? "api_key").isSome then
            failures := failures.push s!"{surface} exposes api_key"
          if ((renderCompact actual).splitOn "fixture-only-no-live-access").length != 1 then
            failures := failures.push s!"{surface} exposes fixture credential"
      -- The same pure projector is used after the real wham transport completes.
      -- Assert field values AND JSON types, including absent versus explicit zero.
      for c in (fixture.fieldArr? "codex").getD #[] do
        let name := (c.fieldStr? "name").getD "unnamed"
        let (fields, windows, _) := projectCodexUsage (c.fieldOrNull "upstream")
        let projected := JVal.obj fields
        for (key, expected) in (c.fieldOrNull "expected").asObj?.getD #[] do
          if projected.field? key != some expected then
            failures := failures.push s!"Codex {name}: {key} value/type"
        for key in ((c.fieldArr? "absent_fields").getD #[]).filterMap JVal.asStr? do
          if (projected.field? key).isSome then
            failures := failures.push s!"Codex {name}: {key} must remain absent"
        -- Optimize has an intentionally separate ISO string reset contract.
        if name == "both windows retain numeric epoch seconds" then
          let expectedResets := ((c.fieldArr? "expected_optimize_resets").getD #[]).filterMap JVal.asStr?
          if expectedResets.size != 2 ||
             windows.map (fun w => (w.fieldStr? "reset_at").getD "") != expectedResets then
            failures := failures.push "Codex optimize reset_at must retain exact ISO values"
          -- Exercise cached-only HTTP serialization using the production projection.
          -- This fixture account has an API key, NOT OAuth: even an accidental
          -- fetch cannot enter the hardcoded OAuth wham HTTP request branch.
          let payload := JVal.obj (fields ++ #[("status", .str "needs_reauth")])
          hub.mu.atomically do
            modify fun state => { state with usageEntries := #[{
              providerId := "10000000-0000-4000-8000-000000000002",
              fetchedSec := 1, fetchedIso := "1970-01-01T00:00:01Z", payload := payload
            }] }
          -- Metadata replay after the rejection is present must not erase it.
          -- Dead login: the list and detail rows report the reconnect state for
          -- that account only; the other accounts stay connected.
          let relisted := (← getJson app jwt "/api/ai/providers" now).asArr?.getD #[]
          let redetail ← getJson app jwt "/api/ai/providers/10000000-0000-4000-8000-000000000002" now
          let statusOf := fun (v : JVal) => (v.fieldOrNull "status").fieldStr? "type"
          let dead := relisted.filter (fun v => statusOf v == some "needs_reauth")
          if dead.map (·.fieldStr? "id") != #[some "10000000-0000-4000-8000-000000000002"] ||
             statusOf redetail != some "needs_reauth" then
            failures := failures.push "a rejected login must show needs_reauth on its own row only"
          if (relisted.filter (fun v => statusOf v == some "connected")).size != 5 then
            failures := failures.push "other credentialed accounts must stay connected"
          -- Evidence from real proxied requests: a login CLIProxyAPI could not use marks the
          -- OAuth-only accounts of that type; a refused key marks that account. Clearing
          -- the evidence (a request served, a completed login) restores `connected`.
          let needsReauth := fun (rows : Array JVal) =>
            (rows.filter (fun v => statusOf v == some "needs_reauth")).filterMap (·.fieldStr? "id")
          let setEvidence := fun (sql : String) => discard <| execParamQuery store.missionsDb sql #[]
          setEvidence "INSERT INTO provider_auth_health(account_key,code,observed_at) VALUES('cliproxyapi:anthropic','auth_unavailable','t0'),('10000000-0000-4000-8000-000000000005','invalid_api_key','t0');"
          let observed := needsReauth ((← getJson app jwt "/api/ai/providers" now).asArr?.getD #[])
          if observed.qsort (· < ·) != #["10000000-0000-4000-8000-000000000001", "10000000-0000-4000-8000-000000000002",
              "10000000-0000-4000-8000-000000000005"] then
            failures := failures.push s!"a login refused on a real request must show needs_reauth: {observed}"
          if statusOf (← getJson app jwt "/api/ai/providers/10000000-0000-4000-8000-000000000001" now) != some "needs_reauth" then
            failures := failures.push "provider detail must use the same request evidence"
          setEvidence "DELETE FROM provider_auth_health;"
          if needsReauth ((← getJson app jwt "/api/ai/providers" now).asArr?.getD #[]) != #["10000000-0000-4000-8000-000000000002"] then
            failures := failures.push "cleared request evidence must restore connected"
          let cached ← getJson app jwt
            "/api/ai/providers/10000000-0000-4000-8000-000000000002/usage?cached_only=true" now
          if cached.fieldInt? "codex_primary_reset_at" != some 1740001800 ||
             cached.fieldInt? "codex_secondary_reset_at" != some 1740604800 then
            failures := failures.push "cached Codex HTTP reset fields must be numeric epochs"
          if cached.fieldStr? "status" != some "needs_reauth" then
            failures := failures.push "provider metadata must not clear a cached authentication rejection"
      failures := failures ++ (← replayReconnect app store root jwt now hub)
      failures := failures ++ (← reconcileNegatives hub store root cooldownsRef)
      if !failures.isEmpty then
        throw (IO.userError ("provider response contract failures:\n" ++ String.intercalate "\n" failures.toList))
    finally
      closeCoreStore store
  finally
    match previousAuthDir with
    | some value => setenvVar "CLI_PROXY_AUTH_DIR" value
    | none => unsetenvVar "CLI_PROXY_AUTH_DIR"
    IO.FS.removeDirAll root

end OrbCore.ProviderContractTests
