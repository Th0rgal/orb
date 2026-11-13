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

/-- Loopback stand-in for the CLIProxyAPI management API. Each connection is answered 200
    with the JSON body the `answer` ref currently holds (default `{"status":"ok"}`), so a
    test can re-script it between requests. `stop` ends the loop. -/
private def mockSidecar (fd : LeanSys.Posix.Fd) (answer : IO.Ref String)
    (stop : IO.Ref Bool) : IO (Task (Except IO.Error (Array String))) :=
  IO.asTask (prio := .dedicated) do
    let mut seen : Array String := #[]
    while !(← stop.get) do
      match ← LeanSys.Posix.tcpAcceptPoll fd 100 with
      | .ok client =>
        let req := String.fromUTF8! (← LeanSys.Posix.readStreamChunk client 8192)
        seen := seen.push ((req.splitOn "\r\n").headD "")
        let body ← answer.get
        discard <| LeanSys.Posix.writeAll client
          s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8
        discard <| LeanSys.Posix.closeFd client
      | .error _ => pure ()
    return seen

/-- While a session is completing, the sidecar's own `error` is authoritative and must fail
    the session at once with its message, not after the 60 s visibility timeout. `ok` alone
    must still never complete. -/
private def lateSidecarError (app : CoreAppState) (hub : ProviderRuntimeHub) (answer : IO.Ref String)
    (jwt : String) (now : UInt64) : IO (Array String) := do
  let mut failures : Array String := #[]
  let wallNow ← nowEpoch
  let baseline := (← scanCliProxyAuthFiles).map (fun f => (f.fileName, f.fingerprint))
  hub.mu.atomically do
    modify fun st => { st with loginSessions := st.loginSessions.push ({
        sessionId := "late-error-fixture", providerSlug := "anthropic", authFileType := "claude",
        targetProvId? := some "10000000-0000-4000-8000-000000000001", stateToken := "late-state",
        authUrl := "https://fixture.invalid/auth", flow := "redirect", createdSec := wallNow, beforeFiles := baseline
      }) }
  let session := "/api/ai/providers/cli-proxy-login/late-error-fixture"
  -- The sidecar accepts the callback before it exchanges the code, then reports an error.
  answer.set "{\"status\":\"ok\"}"
  let (_, cb) ← postJson app jwt s!"{session}/callback"
    "{\"url\":\"http://localhost:54545/callback?code=late-code&state=late-state\"}" now
  if cb.fieldStr? "status" != some "completing" then
    failures := failures.push s!"callback must leave the session completing before any file is visible, got {cb.fieldStr? "status"}"
  answer.set "{\"status\":\"error\",\"error\":\"code expired\"}"
  let poll ← getJson app jwt session now
  answer.set "{\"status\":\"ok\"}"
  let gotStatus := poll.fieldStr? "status"
  let gotMsg := poll.fieldStr? "message"
  if gotStatus != some "failed" || gotMsg != some "code expired" then
    failures := failures.push
      s!"late sidecar error must fail the session at once with its message: got {gotStatus} {gotMsg}"
  return failures

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
  let answer ← IO.mkRef "{\"status\":\"ok\"}"
  let stop ← IO.mkRef false
  let server ← mockSidecar fd answer stop
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
    failures := failures ++ (← lateSidecarError app hub answer jwt now)
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

/-- Antigravity pools models under `cliproxyapi:antigravity:<model>`. A reconnect of Antigravity
    must clear its per-model cooldowns (legacy and tracker) and `provider_auth_health` rows while
    leaving `cliproxyapi:anthropic` untouched. -/
private def antigravityReconnectClearsPerModelKeys
    (hub : ProviderRuntimeHub) (store : CoreStore) (root : String)
    (cooldowns : IO.Ref (Array AccountCooldown)) : IO (Array String) := do
  let mut failures : Array String := #[]
  let wallNow ← nowEpoch
  let agModelKey := "cliproxyapi:antigravity:claude-opus-5-5-high"
  let anthKey := "cliproxyapi:anthropic"
  let tracker ← newProviderHealthTracker
  cooldowns.set #[
    { accountId := agModelKey, untilEpoch := wallNow + 2400, reason := .serverError },
    { accountId := anthKey, untilEpoch := wallNow + 2400, reason := .serverError }
  ]
  tracker.health.atomically do
    modify fun s => { s with accounts := #[
      { accountId := agModelKey, slotId := accountSlotId agModelKey, parkedQuota := true,
        cooldown? := some { accountId := agModelKey, untilEpoch := wallNow + 2400, reason := .serverError } },
      { accountId := anthKey, slotId := accountSlotId anthKey, parkedQuota := true,
        cooldown? := some { accountId := anthKey, untilEpoch := wallNow + 2400, reason := .serverError } }
    ] }
  discard <| execParamQuery store.missionsDb
    "INSERT INTO provider_auth_health(account_key,code,observed_at) VALUES(?1,'auth_unavailable','t0'),(?2,'auth_unavailable','t0');"
    #[agModelKey, anthKey]
  let baseline := (← scanCliProxyAuthFiles).map (fun f => (f.fileName, f.fingerprint))
  let sess : CliLoginSession := {
    sessionId := "ag-reconnect", providerSlug := "antigravity", authFileType := "antigravity",
    targetProvId? := some "10000000-0000-4000-8000-000000000003", stateToken := "ag-state",
    authUrl := "fixture", flow := "redirect", createdSec := wallNow, beforeFiles := baseline
  }
  IO.FS.writeFile s!"{root}/auth-empty/antigravity-reconnected.json"
    "{\"type\":\"antigravity\",\"email\":\"ag@fixture.invalid\",\"access_token\":\"fixture-only-no-live-access\"}"
  try
    let done ← reconcileCliLoginCompletion hub store root cooldowns (some tracker) sess wallNow
    if done.status != "completed" then
      failures := failures.push s!"antigravity reconnect must complete, got {done.status}"
    let remCooldowns ← cooldowns.get
    if remCooldowns.any (fun c => c.accountId == agModelKey) || !(remCooldowns.any (fun c => c.accountId == anthKey)) then
      failures := failures.push s!"antigravity reconnect must clear {agModelKey} legacy cooldown and keep {anthKey}: {remCooldowns.map (·.accountId)}"
    if (← lookupAccountHealthRecord tracker agModelKey).cooldown?.isSome ||
       (← lookupAccountHealthRecord tracker anthKey).cooldown?.isNone then
      failures := failures.push s!"antigravity reconnect must clear {agModelKey} tracker cooldown and keep {anthKey}"
    match ← execParamQuery store.missionsDb "SELECT account_key FROM provider_auth_health ORDER BY account_key;" #[] with
    | .ok rows =>
      let keys := (rows.drop 1).filterMap (·[0]?)
      if keys != #[anthKey] then
        failures := failures.push s!"antigravity reconnect must remove {agModelKey} auth-health row and keep {anthKey}, got {keys}"
    | .error e => failures := failures.push s!"antigravity auth-health query failed: {e}"
  finally
    cooldowns.set #[]
    discard <| execParamQuery store.missionsDb "DELETE FROM provider_auth_health;" #[]
    try IO.FS.removeFile s!"{root}/auth-empty/antigravity-reconnected.json" catch _ => pure ()
  return failures

/-- The routing health view merges the two cooldown owners, and clearing a login resets
    both: seed one cooldown under the legacy ref and one under the health tracker for a
    CLIProxyAPI-held login, plus one legacy cooldown for an unrelated account, and check
    `GET /api/model-routing/health` and `POST /api/model-routing/health/:id/clear`. -/
private def healthCooldownOwners (app : CoreAppState) (jwt : String)
    (cooldownsRef : IO.Ref (Array AccountCooldown)) : IO (Array String) := do
  let oauthOnly := "10000000-0000-4000-8000-000000000001"
  let keyOwned := "10000000-0000-4000-8000-000000000002"
  let sidecarKey := "cliproxyapi:anthropic"
  let tracker ← newProviderHealthTracker
  let app := { app with healthTracker? := some tracker }
  let wallNow ← nowEpoch
  let legacyWindow : UInt64 := 2400
  let trackerWindow : UInt64 := 1500
  let otherWindow : UInt64 := 1200
  cooldownsRef.set #[
    { accountId := sidecarKey, untilEpoch := wallNow + legacyWindow, reason := .serverError },
    { accountId := keyOwned, untilEpoch := wallNow + otherWindow, reason := .serverError }
  ]
  tracker.health.atomically do
    modify fun s => { s with accounts := #[{
      accountId := sidecarKey, slotId := accountSlotId sidecarKey, parkedQuota := true,
      cooldown? := some { accountId := sidecarKey, untilEpoch := wallNow + trackerWindow, reason := .serverError }
    }] }
  let now : UInt64 := 0
  let remainingOf (id : String) : IO UInt64 := do
    let rows := (← getJson app jwt "/api/model-routing/health" now).asArr?.getD #[]
    let row := (rows.find? (fun v => v.fieldStr? "account_id" == some id)).getD .null
    return (row.fieldUInt64? "cooldown_secs_remaining").getD 0
  let sidecarBefore ← remainingOf oauthOnly
  let otherBefore ← remainingOf keyOwned
  -- The endpoint measures against the wall clock, so assert the windows with slack:
  -- the sidecar login's row must carry the legacy owner's longer window.
  if sidecarBefore < legacyWindow - 2 || sidecarBefore > legacyWindow ||
     otherBefore < otherWindow - 2 || otherBefore > otherWindow then
    return #[s!"health GET windows are off: sidecar {sidecarBefore}, unrelated {otherBefore}"]
  let (clearCode, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "" now
  if clearCode != 204 then
    return #[s!"health clear must answer 204, got {clearCode}"]
  let sidecarAfter ← remainingOf oauthOnly
  let otherAfter ← remainingOf keyOwned
  if sidecarAfter != 0 then
    return #[s!"clearing the sidecar login's health must reset both owners, got {sidecarAfter}"]
  let tracked ← lookupAccountHealthRecord tracker sidecarKey
  if tracked.cooldown?.isSome || tracked.parkedQuota then
    return #["clearing the sidecar login's health must clear its tracker record"]
  if otherAfter < otherWindow - 2 || otherAfter > otherWindow then
    return #[s!"clearing one login's health must keep an unrelated account's cooldown, got {otherAfter}"]
  cooldownsRef.set #[]
  return #[]

/-- Scriptable sidecar for `/v0/management/auth-files` and `PATCH /v0/management/auth-files/status`.
    `delayMs` holds the response open so the 2-second timeout can be checked; `handler` returns
    `(httpStatus, jsonBody)` given `(reqLine, reqBody)`. -/
private def mockSidecarAuthFiles
    (fd : LeanSys.Posix.Fd)
    (delayMs : IO.Ref UInt32)
    (handler : IO.Ref (String → String → IO (Nat × String)))
    (stop : IO.Ref Bool) : IO (Task (Except IO.Error (Array (String × String)))) :=
  IO.asTask (prio := .dedicated) do
    let mut seen : Array (String × String) := #[]
    while !(← stop.get) do
      match ← LeanSys.Posix.tcpAcceptPoll fd 50 with
      | .ok client =>
        let raw := String.fromUTF8! (← LeanSys.Posix.readStreamChunk client 16384)
        let reqLine := (raw.splitOn "\r\n").headD ""
        let reqBody := match raw.splitOn "\r\n\r\n" with
          | _ :: rest => String.intercalate "\r\n\r\n" rest
          | [] => ""
        seen := seen.push (reqLine, reqBody)
        let d ← delayMs.get
        if d > 0 then IO.sleep d
        let fn ← handler.get
        let (st, body) ← fn reqLine reqBody
        let stText := if st == 200 then "200 OK" else s!"{st} Error"
        discard <| LeanSys.Posix.writeAll client
          s!"HTTP/1.1 {stText}\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8
        discard <| LeanSys.Posix.closeFd client
      | .error _ => pure ()
    return seen

/-- Sidecar parked credentials on `GET /api/model-routing/health` and `POST /api/model-routing/health/:id/clear`:
    1) Matching cases (a), (b), (c), (d):
       (a) row email set and 1 row + 1 enabled file of that type carry it -> match without leaking file name/email;
       (b) otherwise, 1 OAuth-only row + 1 enabled file of that type and file email empty (or equal to row's) -> match;
       (c) 1 row + 1 file, both emails set and different -> no match and no PATCH on clear;
       (d) anything else (e.g. multiple OAuth rows without decisive email) -> no match and no PATCH on clear;
    2) Clear on a row whose matched file has `remainingSecs == 0` makes zero PATCH calls and answers 204;
    3) Clear when `disabled: true` fails returns 502 naming the provider row id and stating the sidecar cooldown
       was not cleared and the login was not disabled (after clearing Core's own cooldowns);
    4) Clear when `disabled: false` fails once retries and answers 204; when both enable calls fail it returns 502
       naming the provider row id, stating the login was left disabled, and telling the operator to re-enable it
       in CLIProxyAPI (never leaking file name or email);
    5) A slow or unreachable sidecar times out within 2 seconds and leaves Core's own cooldowns untouched. -/
private def sidecarParkedHealthContract
    (app : CoreAppState) (root jwt : String)
    (cooldownsRef : IO.Ref (Array AccountCooldown)) : IO (Array String) := do
  let mut failures : Array String := #[]
  let oauthOnly := "10000000-0000-4000-8000-000000000001"
  let keyOwned := "10000000-0000-4000-8000-000000000002"
  let agOauth := "10000000-0000-4000-8000-000000000003"
  let now : UInt64 := 0
  let (fd, port) ← IO.ofExcept (← LeanSys.Posix.tcpListen "127.0.0.1" 0 16)
  let priorBase ← IO.getEnv "CLAUDE_CODE_PROXY_BASE_URL"
  let priorKey ← IO.getEnv "CLI_PROXY_MANAGEMENT_KEY"
  setenvVar "CLAUDE_CODE_PROXY_BASE_URL" s!"http://127.0.0.1:{port}"
  setenvVar "CLI_PROXY_MANAGEMENT_KEY" "fixture-only"
  let delayMs ← IO.mkRef (0 : UInt32)
  let patchCalls ← IO.mkRef (#[] : Array String)
  let disableFailRemaining ← IO.mkRef (0 : Nat)
  let enableFailRemaining ← IO.mkRef (0 : Nat)
  let sidecarFilesJsonRef ← IO.mkRef
    ("{\"files\":[" ++
      "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"2026-11-18T12:00:00Z\",\"remaining_seconds\":471600,\"http_status\":429}]}," ++
      "{\"name\":\"claude-second-file.json\",\"provider\":\"claude\",\"email\":\"other-claude@fixture.invalid\",\"disabled\":false,\"status\":\"ok\",\"cooldowns\":[]}," ++
      "{\"name\":\"antigravity-ambig.json\",\"provider\":\"antigravity\",\"email\":\"ag-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"quota\",\"retry_at\":\"2026-11-13T20:00:00Z\",\"remaining_seconds\":3600}]}" ++
    "]}")
  let defaultHandler : String → String → IO (Nat × String) := fun reqLine reqBody => do
    if reqLine.startsWith "GET /v0/management/auth-files" then
      return (200, ← sidecarFilesJsonRef.get)
    if reqLine.startsWith "PATCH /v0/management/auth-files/status" then
      patchCalls.modify (·.push reqBody)
      if ((reqBody.splitOn "\"disabled\":true").length > 1) then
        let dRem ← disableFailRemaining.get
        if dRem > 0 then
          disableFailRemaining.set (dRem - 1)
          return (500, "{\"error\":\"sidecar disable failed for claude-secret-file.json owner-secret@fixture.invalid\"}")
      if ((reqBody.splitOn "\"disabled\":false").length > 1) then
        let rem ← enableFailRemaining.get
        if rem > 0 then
          enableFailRemaining.set (rem - 1)
          return (500, "{\"error\":\"sidecar enable failed for claude-secret-file.json owner-secret@fixture.invalid\"}")
      return (200, "{\"status\":\"ok\"}")
    return (404, "{\"error\":\"not_found\"}")
  let handlerRef ← IO.mkRef defaultHandler
  let stop ← IO.mkRef false
  let server ← mockSidecarAuthFiles fd delayMs handlerRef stop
  let origProvidersRaw ← IO.FS.readFile s!"{root}/.sandboxed-sh/ai_providers.json"
  let .ok origArr := (OrbBin.Json.parse origProvidersRaw).map (fun j => j.asArr?.getD #[])
    | throw (IO.userError "orig providers parse")
  let setOauthEmail (email? : Option String) (extraRows : Array JVal := #[]) : IO Unit := do
    let updated := origArr.map fun row =>
      if row.fieldStr? "id" == some oauthOnly then
        match row, email? with
        | .obj kvs, some em =>
          .obj ((kvs.filter (fun (k, _) => k != "account_email")).push ("account_email", .str em))
        | .obj kvs, none =>
          .obj (kvs.filter (fun (k, _) => k != "account_email"))
        | other, _ => other
      else row
    IO.FS.writeFile s!"{root}/.sandboxed-sh/ai_providers.json" (renderCompact (.arr (updated ++ extraRows)))
  try
    -- Case 1(a): row email set and 1 row + 1 enabled file of that type carry it (even with a 2nd OAuth row & file).
    let extraClaudeNoEmail : JVal := .obj #[
      ("id", .str "10000000-0000-4000-8000-000000000009"),
      ("name", .str "Claude second"),
      ("provider_type", .str "anthropic"),
      ("enabled", .bool true),
      ("oauth", .obj #[("access_token", .str "fixture-only-no-live-access")])
    ]
    setOauthEmail (some "owner-secret@fixture.invalid") #[extraClaudeNoEmail]
    let health1a ← getJson app jwt "/api/model-routing/health" now
    let raw1a := renderCompact health1a
    let rows1a := health1a.asArr?.getD #[]
    let row1a := (rows1a.find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
    if (row1a.fieldUInt64? "cooldown_secs_remaining").getD 0 != 471600 then
      failures := failures.push s!"sidecar parked (a): expected cooldown_secs_remaining=471600, got {row1a.fieldUInt64? "cooldown_secs_remaining"}"
    if row1a.fieldStr? "parked_until" != some "2026-11-18T12:00:00Z" ||
       row1a.fieldStr? "parked_reason" != some "credential_quota" ||
       row1a.fieldStr? "parked_source" != some "sidecar" then
      failures := failures.push s!"sidecar parked (a): expected parked_until/parked_reason/parked_source on {oauthOnly}, got {renderCompact row1a}"
    if (row1a.field? "cooldown_remaining_secs").isSome then
      failures := failures.push "sidecar parked (a): must keep cooldown_secs_remaining as the only cooldown field"
    if (raw1a.splitOn "claude-secret-file.json").length > 1 ||
       (raw1a.splitOn "owner-secret@fixture.invalid").length > 1 ||
       (raw1a.splitOn "ag-secret@fixture.invalid").length > 1 then
      failures := failures.push s!"sidecar parked (a): health response leaked auth file name or email: {raw1a}"

    -- Case 1(b): 1 OAuth-only row (even with row email set) and 1 enabled file of that type whose email is empty -> match.
    setOauthEmail (some "lone-row@fixture.invalid")
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"2026-11-18T12:00:00Z\",\"remaining_seconds\":471600}]}" ++
      "]}")
    let rows1b := (← getJson app jwt "/api/model-routing/health" now).asArr?.getD #[]
    let row1b := (rows1b.find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
    if (row1b.fieldUInt64? "cooldown_secs_remaining").getD 0 != 471600 ||
       row1b.fieldStr? "parked_source" != some "sidecar" then
      failures := failures.push s!"sidecar parked (b): lone row with empty-email file must match, got {renderCompact row1b}"

    -- Case 1(c): 1 row, 1 file, both emails set and different -> no match and no PATCH on clear.
    setOauthEmail (some "row-a@fixture.invalid")
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"file-b@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"2026-11-18T12:00:00Z\",\"remaining_seconds\":471600}]}" ++
      "]}")
    let rows1c := (← getJson app jwt "/api/model-routing/health" now).asArr?.getD #[]
    let row1c := (rows1c.find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
    if (row1c.fieldUInt64? "cooldown_secs_remaining").getD 0 != 0 ||
       (row1c.field? "parked_until") != some .null ||
       (row1c.field? "parked_reason") != some .null ||
       (row1c.field? "parked_source") != some .null then
      failures := failures.push s!"sidecar parked (c): mismatched emails must not match, got {renderCompact row1c}"
    patchCalls.set #[]
    let (clear1cCode, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "" now
    if clear1cCode != 204 || !(← patchCalls.get).isEmpty then
      failures := failures.push s!"sidecar parked (c): clear on mismatched emails must not PATCH, got code={clear1cCode} calls={← patchCalls.get}"

    -- Case 1(d): multiple OAuth rows of same type without matching email -> no match and no PATCH on clear.
    let extraAg : JVal := .obj #[
      ("id", .str "10000000-0000-4000-8000-000000000008"),
      ("name", .str "Antigravity second"),
      ("provider_type", .str "antigravity"),
      ("enabled", .bool true),
      ("oauth", .obj #[("access_token", .str "fixture-only-no-live-access")])
    ]
    setOauthEmail (some "owner-secret@fixture.invalid") #[extraAg]
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"2026-11-18T12:00:00Z\",\"remaining_seconds\":471600}]}," ++
        "{\"name\":\"antigravity-ambig.json\",\"provider\":\"antigravity\",\"email\":\"ag-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"quota\",\"retry_at\":\"2026-11-13T20:00:00Z\",\"remaining_seconds\":3600}]}" ++
      "]}")
    let rowsAmbig := (← getJson app jwt "/api/model-routing/health" now).asArr?.getD #[]
    for aid in #[agOauth, "10000000-0000-4000-8000-000000000008"] do
      let r := (rowsAmbig.find? (fun v => v.fieldStr? "account_id" == some aid)).getD .null
      if (r.fieldUInt64? "cooldown_secs_remaining").getD 0 != 0 ||
         (r.field? "parked_until") != some .null ||
         (r.field? "parked_reason") != some .null ||
         (r.field? "parked_source") != some .null then
        failures := failures.push s!"sidecar parked (d): ambiguous OAuth row {aid} must show no parked state, got {renderCompact r}"
    patchCalls.set #[]
    let (ambigClearCode, _) ← postJson app jwt s!"/api/model-routing/health/{agOauth}/clear" "" now
    if ambigClearCode != 204 || !(← patchCalls.get).isEmpty then
      failures := failures.push s!"sidecar parked (d): ambiguous OAuth clear must not toggle any sidecar file, got code={ambigClearCode} calls={← patchCalls.get}"

    -- Case 2: Clear on a row whose matched file is healthy (`remainingSecs == 0`) makes zero PATCH calls and answers 204.
    setOauthEmail (some "owner-secret@fixture.invalid")
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"ok\",\"cooldowns\":[]}" ++
      "]}")
    patchCalls.set #[]
    let (healthyClearCode, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "" now
    if healthyClearCode != 204 || !(← patchCalls.get).isEmpty then
      failures := failures.push s!"sidecar parked: clear on healthy matched file must make 0 PATCH calls and answer 204, got code={healthyClearCode} calls={← patchCalls.get}"

    -- Restore parked sidecar file for clear error/retry tests.
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"2026-11-18T12:00:00Z\",\"remaining_seconds\":471600}]}" ++
      "]}")

    -- Case 3: Clear when first PATCH (`disabled: true`) fails -> 502 naming provider row id, stating cooldown was not cleared
    -- and login was not disabled, while Core's own cooldown was already cleared.
    let wallNow0 ← nowEpoch
    cooldownsRef.set #[{ accountId := "cliproxyapi:anthropic", untilEpoch := wallNow0 + 600, reason := .rateLimit }]
    patchCalls.set #[]
    disableFailRemaining.set 1
    let (disableFailCode, disableFailBody) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "" now
    let disableFailRaw := renderCompact disableFailBody
    let callsAfterDisableFail ← patchCalls.get
    if disableFailCode != 502 || callsAfterDisableFail.size != 1 then
      failures := failures.push s!"sidecar parked: failed disable PATCH must return 502 after 1 call, got code={disableFailCode} calls={callsAfterDisableFail}"
    if (disableFailRaw.splitOn oauthOnly).length == 1 ||
       (disableFailRaw.splitOn "not cleared").length == 1 ||
       (disableFailRaw.splitOn "not disabled").length == 1 then
      failures := failures.push s!"sidecar parked: failed disable 502 must name {oauthOnly} and say cooldown was not cleared and login was not disabled, got {disableFailRaw}"
    if (disableFailRaw.splitOn "claude-secret-file.json").length > 1 ||
       (disableFailRaw.splitOn "owner-secret@fixture.invalid").length > 1 then
      failures := failures.push s!"sidecar parked: failed disable 502 leaked file name or email: {disableFailRaw}"
    if !(← cooldownsRef.get).isEmpty then
      failures := failures.push "sidecar parked: clear must remove Core's cooldowns before calling sidecar"
    disableFailRemaining.set 0

    -- Case 4a: Clear when first enable (`disabled: false`) fails, retry succeeds -> 204 (3 PATCH calls: true, false, false).
    patchCalls.set #[]
    enableFailRemaining.set 1
    let (retryClearCode, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "" now
    let callsAfterRetry ← patchCalls.get
    if retryClearCode != 204 || callsAfterRetry.size != 3 then
      failures := failures.push s!"sidecar parked: clear with one transient enable failure must retry and succeed (204, 3 calls), got code={retryClearCode} calls={callsAfterRetry}"

    -- Case 4b: Clear when enable fails on both attempts -> 502 naming provider row id, stating login was left disabled
    -- and how to recover ("re-enable it in CLIProxyAPI"), never leaking file name or email.
    patchCalls.set #[]
    enableFailRemaining.set 2
    let (failClearCode, failClearBody) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "" now
    let failClearRaw := renderCompact failClearBody
    let callsAfterFail ← patchCalls.get
    if failClearCode != 502 || callsAfterFail.size != 3 then
      failures := failures.push s!"sidecar parked: clear with persistent enable failure must return 502 after retry, got code={failClearCode} calls={callsAfterFail}"
    if (failClearRaw.splitOn oauthOnly).length == 1 ||
       (failClearRaw.splitOn "left disabled").length == 1 ||
       (failClearRaw.splitOn "re-enable it in CLIProxyAPI").length == 1 then
      failures := failures.push s!"sidecar parked: failed enable error must state login was left disabled, name {oauthOnly}, and advise re-enable it in CLIProxyAPI, got {failClearRaw}"
    if (failClearRaw.splitOn "claude-secret-file.json").length > 1 ||
       (failClearRaw.splitOn "owner-secret@fixture.invalid").length > 1 then
      failures := failures.push s!"sidecar parked: failed enable error leaked file name or email: {failClearRaw}"
    enableFailRemaining.set 0

    -- Case 5: Slow sidecar (> 2s) times out within 2s and leaves Core's own cooldowns intact.
    let wallNow ← nowEpoch
    cooldownsRef.set #[{ accountId := keyOwned, untilEpoch := wallNow + 900, reason := .serverError }]
    delayMs.set 3500
    let t0 ← IO.monoMsNow
    let slowHealth ← getJson app jwt "/api/model-routing/health" now
    let elapsed := (← IO.monoMsNow) - t0
    if elapsed > 2500 then
      failures := failures.push s!"sidecar parked: GET /api/model-routing/health waited {elapsed}ms (> 2s cap)"
    let slowRows := slowHealth.asArr?.getD #[]
    let keyRow := (slowRows.find? (fun v => v.fieldStr? "account_id" == some keyOwned)).getD .null
    let keyRem := (keyRow.fieldUInt64? "cooldown_secs_remaining").getD 0
    if keyRem < 890 || keyRem > 900 then
      failures := failures.push s!"sidecar parked: slow/unreachable sidecar must preserve Core cooldowns, got {keyRem}"
  finally
    cooldownsRef.set #[]
    IO.FS.writeFile s!"{root}/.sandboxed-sh/ai_providers.json" origProvidersRaw
    stop.set true
    discard <| IO.wait server
    discard <| LeanSys.Posix.closeFd fd
    match priorBase with
    | some v => setenvVar "CLAUDE_CODE_PROXY_BASE_URL" v
    | none => unsetenvVar "CLAUDE_CODE_PROXY_BASE_URL"
    match priorKey with
    | some v => setenvVar "CLI_PROXY_MANAGEMENT_KEY" v
    | none => unsetenvVar "CLI_PROXY_MANAGEMENT_KEY"
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
      failures := failures ++ (← antigravityReconnectClearsPerModelKeys hub store root cooldownsRef)
      failures := failures ++ (← healthCooldownOwners app jwt cooldownsRef)
      failures := failures ++ (← sidecarParkedHealthContract app root jwt cooldownsRef)
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
