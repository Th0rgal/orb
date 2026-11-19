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

private def putJson (app : CoreAppState) (jwt target body : String) (now : UInt64) : IO (Nat × JVal) := do
  let raw := s!"PUT {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
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
    -- r32_login_reporting_fixture_and_fresh_login: actual list/detail/health endpoints.
    let statusOf (v : JVal) := (v.fieldOrNull "status").fieldStr? "type"
    let initialFiles ← sidecarFilesJsonRef.get
    let fixtureRaw ← IO.FS.readFile "shared/orb-spec/fixtures/provider-login-health.json"
    let .ok fixture := OrbBin.Json.parse fixtureRaw
      | throw (IO.userError "r32 fixture parse failed")
    sidecarFilesJsonRef.set (renderCompact fixture)
    for file in (fixture.fieldArr? "files").getD #[] do
      setOauthEmail (file.fieldStr? "email")
      let detail ← getJson app jwt s!"/api/ai/providers/{oauthOnly}" now
      let listed := (← getJson app jwt "/api/ai/providers" now).asArr?.getD #[]
      let listedRow := (listed.find? (fun v => v.fieldStr? "id" == some oauthOnly)).getD .null
      if statusOf detail != some "needs_reauth" || statusOf listedRow != some "needs_reauth" then
        failures := failures.push "r32_login_reporting_fixture_and_fresh_login: list/detail must report needs_reauth"
      let health := (← getJson app jwt "/api/model-routing/health" now).asArr?.getD #[]
      let row := (health.find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
       if row.fieldStr? "login_message" != some "Sign in again" then
         failures := failures.push "r32_login_reporting_fixture_and_fresh_login: health must report Sign in again"
      if file.fieldStr? "name" == some "quota.json" &&
          row.fieldStr? "parked_until" != some "2026-11-18T12:00:00Z" then
        failures := failures.push "r32_login_reporting_fixture_and_fresh_login: reported reset changed"
      if (file.fieldBool? "disabled").getD false then
        patchCalls.set #[]
        let (code, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "{}" now
        if code != 409 || !(← patchCalls.get).isEmpty then
          failures := failures.push "r32_disabled_clear_never_reenables: disabled login was modified"
    sidecarFilesJsonRef.set "{\"files\":[{\"name\":\"fresh.json\",\"provider\":\"claude\",\"status\":\"ok\"}]}"
    let fresh ← getJson app jwt s!"/api/ai/providers/{oauthOnly}" now
    if statusOf fresh == some "needs_reauth" then
      failures := failures.push "r32_login_reporting_fixture_and_fresh_login: fresh login did not clear status"
    -- An old disabled duplicate must not prevent recovery of the enabled login.
    setOauthEmail (some "owner-secret@fixture.invalid")
    let .ok initialDoc := OrbBin.Json.parse initialFiles
      | throw (IO.userError "initial sidecar fixture parse")
    let duplicate := JVal.obj #[("name", .str "old-disabled.json"), ("provider", .str "claude"),
      ("email", .str "owner-secret@fixture.invalid"), ("disabled", .bool true)]
    sidecarFilesJsonRef.set (renderCompact (.obj #[("files", .arr
      (((initialDoc.fieldArr? "files").getD #[]).push duplicate))]))
    patchCalls.set #[]
    let (duplicateCode, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "{}" now
    let duplicateCalls ← patchCalls.get
    if duplicateCode != 204 || duplicateCalls.size != 2 ||
        duplicateCalls.any (fun s => (s.splitOn "old-disabled.json").length > 1) then
      failures := failures.push "r32_enabled_recovery_with_disabled_duplicate: must only toggle enabled file"
    sidecarFilesJsonRef.set initialFiles
    -- A skipped OAuth login must not replace the eligible account's context error.
    let chains ← IO.mkRef #[{ id := "r32-reporting", name := "R32", targets := #[
      { accountId := oauthOnly, provider := "openai", modelId := "fixture", baseUrl := "https://fixture.invalid", apiKey := "fixture" },
      { accountId := keyOwned, provider := "openai", modelId := "fixture", baseUrl := "https://fixture.invalid", apiKey := "fixture" }
    ] : RoutingChain }]
    cooldownsRef.set #[{ accountId := oauthOnly, untilEpoch := 2400, reason := .usageLimit, label := "fixture" }]
    let seen ← IO.mkRef (0 : Nat)
    let proxyApp := { app with
      cfg := { app.cfg with proxySecret := "r32-proxy-secret" }
      chainsRef := chains
      healthTracker? := none
      proxyMockTransport? := some (fun _ => do
        seen.modify (· + 1)
        return .ok { status := 400, headers := #[], body :=
          "{\"error\":{\"code\":\"context_length_exceeded\"},\"message\":\"Reduce context\"}".toUTF8 }) }
    let body := "{\"model\":\"r32-reporting\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
    let wire := s!"POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {proxyApp.cfg.proxySecret}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
    let .ok request := parseRequest wire.toUTF8 none | throw (IO.userError "r32 request parse")
    let .ok response ← dispatchCoreRequest proxyApp request now | throw (IO.userError "r32 dispatch")
    let .ok errorDoc := OrbBin.Json.parseBytes response.body | throw (IO.userError "r32 response parse")
    if response.status != 400 || (← seen.get) != 1 || errorDoc.field? "login_status" != none ||
        errorDoc.fieldStr? "message" != some "Reduce context" then
      failures := failures.push s!"r32_skipped_login_preserves_request_error: {renderCompact errorDoc}"
    cooldownsRef.set #[]
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
    if row1a.fieldUInt64? "cooldown_remaining_secs" != some 471600 ||
       row1a.fieldUInt64? "cooldown_remaining_secs" != row1a.fieldUInt64? "cooldown_secs_remaining" then
      failures := failures.push s!"sidecar parked (a): expected cooldown_remaining_secs equal to cooldown_secs_remaining=471600, got {renderCompact row1a}"
    if row1a.fieldStr? "provider_id" != some "anthropic" ||
       row1a.fieldBool? "is_healthy" != some false ||
       row1a.fieldBool? "is_degraded" != some true then
      failures := failures.push s!"sidecar parked (a): expected provider_id=anthropic, is_healthy=false, is_degraded=true on parked row, got {renderCompact row1a}"
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
       row1c.fieldUInt64? "cooldown_remaining_secs" != some 0 ||
       row1c.fieldStr? "provider_id" != some "anthropic" ||
       row1c.fieldBool? "is_healthy" != some true ||
       row1c.fieldBool? "is_degraded" != some false ||
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

    -- Case 4c: Closed shape on sidecar `reason` and `retry_at`:
    -- (a) free-string `reason` with marker -> defaults to `"credential_quota"` and marker never appears in reply;
    -- (b) free-string `retry_at` with marker -> falls back to computed UTC timestamp and marker never appears in reply;
    -- (c) valid slugs (`credential_quota`, `model_quota`) and valid `retry_at` (`2026-11-14T00:00:00Z`) pass through;
    -- (d) `reason` longer than 40 characters -> defaults to `"credential_quota"`.
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"owner-secret@fixture.invalid quota exceeded\",\"retry_at\":\"2026-11-14T00:00:00Z\",\"remaining_seconds\":471600}]}" ++
      "]}")
    let healthShapeA ← getJson app jwt "/api/model-routing/health" now
    let rawShapeA := renderCompact healthShapeA
    let rowShapeA := ((healthShapeA.asArr?.getD #[]).find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
    if rowShapeA.fieldStr? "parked_reason" != some "credential_quota" ||
       (rawShapeA.splitOn "owner-secret@fixture.invalid").length > 1 then
      failures := failures.push s!"sidecar shape (a): free-string reason must fall back to credential_quota and omit marker, got {rawShapeA}"

    let wallBeforeB ← nowEpoch
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"ask owner-secret@fixture.invalid\",\"remaining_seconds\":3600}]}" ++
      "]}")
    let healthShapeB ← getJson app jwt "/api/model-routing/health" now
    let wallAfterB ← nowEpoch
    let rawShapeB := renderCompact healthShapeB
    let rowShapeB := ((healthShapeB.asArr?.getD #[]).find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
    let expectedB1 := formatEpochIso8601Utc (wallBeforeB + 3600)
    let expectedB2 := formatEpochIso8601Utc (wallAfterB + 3600)
    let actualUntilB := (rowShapeB.fieldStr? "parked_until").getD ""
    if (actualUntilB != expectedB1 && actualUntilB != expectedB2) ||
       (rawShapeB.splitOn "owner-secret@fixture.invalid").length > 1 then
      failures := failures.push s!"sidecar shape (b): invalid retry_at must use computed UTC timestamp ({expectedB1}..{expectedB2}) and omit marker, got {rawShapeB}"

    for validReason in #["credential_quota", "model_quota"] do
      sidecarFilesJsonRef.set
        ("{\"files\":[" ++
          s!"\{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[\{\"scope\":\"credential\",\"reason\":\"{validReason}\",\"retry_at\":\"2026-11-14T00:00:00Z\",\"remaining_seconds\":471600}]}" ++
        "]}")
      let healthShapeC ← getJson app jwt "/api/model-routing/health" now
      let rowShapeC := ((healthShapeC.asArr?.getD #[]).find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
      if rowShapeC.fieldStr? "parked_reason" != some validReason ||
         rowShapeC.fieldStr? "parked_until" != some "2026-11-14T00:00:00Z" then
        failures := failures.push s!"sidecar shape (c): valid slug {validReason} and retry_at 2026-11-14T00:00:00Z must pass through unchanged, got {renderCompact rowShapeC}"

    let longReason := String.ofList (List.replicate 41 'a')
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        s!"\{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[\{\"scope\":\"credential\",\"reason\":\"{longReason}\",\"retry_at\":\"2026-11-14T00:00:00Z\",\"remaining_seconds\":471600}]}" ++
      "]}")
    let healthShapeD ← getJson app jwt "/api/model-routing/health" now
    let rowShapeD := ((healthShapeD.asArr?.getD #[]).find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
    if rowShapeD.fieldStr? "parked_reason" != some "credential_quota" then
      failures := failures.push s!"sidecar shape (d): reason > 40 chars must fall back to credential_quota, got {renderCompact rowShapeD}"

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

/-- R26: a provider-disabled login is terminal on `GET /api/model-routing/health`: no countdown,
    explicit `account_state`, and the provider's own message. Operator clear removes the terminal
    state. -/
private def r26DisabledProviderHealthContract
    (app : CoreAppState) (jwt : String) (tracker : ProviderHealthTracker) : IO (Array String) := do
  let mut failures : Array String := #[]
  let oauthOnly := "10000000-0000-4000-8000-000000000001"
  let providerMessage := "This account violated the Terms of Service"
  tracker.health.atomically do
    modify fun s => { s with accounts := s.accounts.filter (fun r => r.accountId != oauthOnly) }
  tracker.health.atomically do
    modify fun s => { s with accounts := s.accounts.push {
      accountId := oauthOnly, slotId := accountSlotId oauthOnly,
      disabledByProvider := true, disabledMessage := providerMessage, lastVerdictCode := 5
    } }
  let now : UInt64 := 0
  let before := (← getJson app jwt "/api/model-routing/health" now).asArr?.getD #[]
  let row := (before.find? (fun v => v.fieldStr? "account_id" == some oauthOnly)).getD .null
  if row.fieldStr? "account_state" != some "disabled_by_provider" ||
     row.fieldBool? "disabled_by_provider" != some true ||
     row.fieldBool? "disabled" != some true ||
     row.fieldStr? "disabled_by_provider_message" != some providerMessage then
    failures := failures.push s!"R26 health: disabled account state/message missing, got {renderCompact row}"
  if (row.fieldUInt64? "cooldown_secs_remaining").getD 0 != 0 ||
     (row.fieldUInt64? "cooldown_remaining_secs").getD 0 != 0 ||
     (row.field? "parked_until") != some .null then
    failures := failures.push s!"R26 health: provider disable must have no cooldown countdown, got {renderCompact row}"
  let (clearCode, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" "" now
  let cleared ← lookupAccountHealthRecord tracker oauthOnly
  if clearCode != 204 || cleared.disabledByProvider then
    failures := failures.push
      s!"R26 health: operator clear must remove terminal disable, got code={clearCode} disabled={cleared.disabledByProvider}"
  return failures

/-- R26: toggling an OAuth-only Core row changes its matched sidecar login's `disabled` flag, and
    a disabled sidecar login with no Core row still appears in the provider list. -/
private def r26SidecarToggleAndOrphanContract
    (app : CoreAppState) (root jwt : String) : IO (Array String) := do
  let mut failures : Array String := #[]
  let oauthOnly := "10000000-0000-4000-8000-000000000001"
  let now : UInt64 := 0
  let (fd, port) ← IO.ofExcept (← LeanSys.Posix.tcpListen "127.0.0.1" 0 16)
  let priorBase ← IO.getEnv "CLAUDE_CODE_PROXY_BASE_URL"
  let priorKey ← IO.getEnv "CLI_PROXY_MANAGEMENT_KEY"
  setenvVar "CLAUDE_CODE_PROXY_BASE_URL" s!"http://127.0.0.1:{port}"
  setenvVar "CLI_PROXY_MANAGEMENT_KEY" "fixture-only"
  let delayMs ← IO.mkRef (0 : UInt32)
  let patchBodies ← IO.mkRef (#[] : Array String)
  let sidecarFilesJsonRef ← IO.mkRef
    ("{\"files\":[" ++
      "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":false,\"status\":\"ok\",\"cooldowns\":[]}," ++
      "{\"name\":\"xai-orphan.json\",\"provider\":\"xai\",\"email\":\"orphan@fixture.invalid\",\"disabled\":true,\"status\":\"disabled\",\"cooldowns\":[]}" ++
    "]}")
  let handler : String → String → IO (Nat × String) := fun reqLine reqBody => do
    if reqLine.startsWith "GET /v0/management/auth-files" then
      return (200, ← sidecarFilesJsonRef.get)
    if reqLine.startsWith "PATCH /v0/management/auth-files/status" then
      patchBodies.modify (·.push reqBody)
      return (200, "{\"status\":\"ok\"}")
    return (404, "{\"error\":\"not_found\"}")
  let handlerRef ← IO.mkRef handler
  let stop ← IO.mkRef false
  let server ← mockSidecarAuthFiles fd delayMs handlerRef stop
  let origProvidersRaw ← IO.FS.readFile s!"{root}/.sandboxed-sh/ai_providers.json"
  let .ok origArr := (OrbBin.Json.parse origProvidersRaw).map (fun j => j.asArr?.getD #[])
    | throw (IO.userError "R26 orig providers parse")
  let updated := origArr.map fun row =>
    if row.fieldStr? "id" == some oauthOnly then
      match row with
      | .obj kvs => .obj ((kvs.filter (fun (k, _) => k != "account_email")).push ("account_email", .str "owner-secret@fixture.invalid"))
      | other => other
    else row
  let orphanPath := s!"{root}/auth-empty/xai-orphan.json"
  try
    IO.FS.writeFile s!"{root}/.sandboxed-sh/ai_providers.json" (renderCompact (.arr updated))
    match ← upsertAIProvider app.store {
        id := oauthOnly, providerType := "anthropic", name := "Anthropic fixture",
        apiKey := "cli-proxy-managed", updatedAt := "1700001000" } with
    | .error e => throw (IO.userError s!"R26 seed provider failed: {e}")
    | .ok () => pure ()
    IO.FS.writeFile orphanPath
      "{\"type\":\"xai\",\"email\":\"orphan@fixture.invalid\",\"disabled\":true}"
    let listed := (← getJson app jwt "/api/ai/providers" now).asArr?.getD #[]
    let orphanId := "cliproxyapi:xai:fb5d024d63da95145145c8093f7628bf4ebfe247900470810378269f4cd6da00"
    let orphan := (listed.find? (fun v => v.fieldStr? "id" == some orphanId)).getD .null
    if orphan.isNull then
      failures := failures.push "R26 sidecar: a disabled sidecar login with no Core row must be listed"
    let healthRows := (← getJson app jwt "/api/model-routing/health" now).asArr?.getD #[]
    let orphanHealth := (healthRows.find? (fun v => v.fieldStr? "account_id" == some orphanId)).getD .null
    if orphanHealth.fieldStr? "account_state" != some "disabled" ||
       orphanHealth.fieldBool? "disabled" != some true ||
       (orphanHealth.fieldUInt64? "cooldown_secs_remaining").getD 0 != 0 then
      failures := failures.push s!"R26 sidecar: orphan disabled login health must be disabled without countdown, got {renderCompact orphanHealth}"

    patchBodies.set #[]
    let (disableCode, _) ← putJson app jwt s!"/api/ai/providers/{oauthOnly}" "{\"enabled\":false}" now
    let disableBodies ← patchBodies.get
    if disableCode != 200 || disableBodies.size != 1 ||
       (disableBodies[0]!.splitOn "\"name\":\"claude-secret-file.json\"").length != 2 ||
       (disableBodies[0]!.splitOn "\"disabled\":true").length != 2 then
      failures := failures.push s!"R26 sidecar: disabling the Core row must disable its login once, got code={disableCode} bodies={disableBodies}"
    sidecarFilesJsonRef.set
      ("{\"files\":[" ++
        "{\"name\":\"claude-secret-file.json\",\"provider\":\"claude\",\"email\":\"owner-secret@fixture.invalid\",\"disabled\":true,\"status\":\"disabled\",\"cooldowns\":[]}," ++
        "{\"name\":\"xai-orphan.json\",\"provider\":\"xai\",\"email\":\"orphan@fixture.invalid\",\"disabled\":true,\"status\":\"disabled\",\"cooldowns\":[]}" ++
      "]}")

    patchBodies.set #[]
    let (enableCode, _) ← putJson app jwt s!"/api/ai/providers/{oauthOnly}" "{\"enabled\":true}" now
    let enableBodies ← patchBodies.get
    if enableCode != 200 || enableBodies.size != 1 ||
       (enableBodies[0]!.splitOn "\"name\":\"claude-secret-file.json\"").length != 2 ||
       (enableBodies[0]!.splitOn "\"disabled\":false").length != 2 then
      failures := failures.push s!"R26 sidecar: re-enabling the Core row must re-enable its login once, got code={enableCode} bodies={enableBodies}"
  finally
    discard <| deleteAIProvider app.store oauthOnly
    IO.FS.writeFile s!"{root}/.sandboxed-sh/ai_providers.json" origProvidersRaw
    discard <| (IO.FS.removeFile orphanPath).toBaseIO
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

/-- Contract test for `GET /api/ai/proxy/health`: verifies the additive client-read
    fields (`since`, `groups`, `chains`, and `totals.{ok,retried,errors,ttft_p50_ms,ttft_p95_ms,latency_p50_ms,latency_p95_ms}`,
    with `fell_back` omitted because Core never writes `fallback_depth`) alongside existing keys. -/
private def proxyHealthClientShapeContract (app : CoreAppState) (store : CoreStore) (jwt : String)
    (now : UInt64) : IO (Array String) := do
  let mut failures : Array String := #[]
  let wallNow ← nowEpoch
  let tsRecent := formatEpochIso8601Utc (wallNow - 60)
  discard <| execParamQuery store.missionsDb "DELETE FROM proxy_outcomes;" #[]
  discard <| execParamQuery store.missionsDb
    ("INSERT INTO proxy_outcomes(timestamp,chain_id,provider,account_id,model,status,http_status,retries,ttft_ms,total_ms,fallback_depth,stream,superseded) VALUES" ++
     "(?1,'builtin/smart','anthropic','10000000-0000-4000-8000-000000000001','claude-sonnet-4-5','ok',200,0,110,450,0,1,0)," ++
     "(?1,'builtin/smart','anthropic','10000000-0000-4000-8000-000000000001','claude-sonnet-4-5','error',502,2,0,900,1,1,0);")
    #[tsRecent]
  try
    let h24 ← getJson app jwt "/api/ai/proxy/health?window=24h" now
    if h24.field? "since" != h24.field? "window_start" || (h24.fieldStr? "since").isNone then
      failures := failures.push s!"proxy/health: expected since == window_start (non-null for 24h), got {renderCompact h24}"
    let hAll ← getJson app jwt "/api/ai/proxy/health?window=all" now
    if hAll.field? "since" != some .null || hAll.field? "window_start" != some .null then
      failures := failures.push s!"proxy/health: expected since == null for window=all, got {renderCompact hAll}"
    let tot := h24.fieldOrNull "totals"
    let byStatusOk := (tot.fieldOrNull "by_status").fieldNat? "ok"
    if tot.fieldNat? "requests" != some 2 ||
       tot.fieldNat? "succeeded" != some 1 ||
       tot.fieldNat? "failed" != some 1 ||
       tot.fieldNat? "ok" != byStatusOk ||
       tot.fieldNat? "ok" != some 1 then
      failures := failures.push s!"proxy/health: totals.ok must equal by_status.ok (1) and requests=2, got {renderCompact tot}"
    if tot.fieldNat? "retried" != some 1 ||
       tot.fieldNat? "retried_requests" != some 1 ||
       tot.fieldNat? "total_retries" != some 2 ||
       (tot.field? "fell_back").isSome then
      failures := failures.push s!"proxy/health: totals.retried must be 1 (retried_requests=1, total_retries=2) and fell_back omitted, got {renderCompact tot}"
    if tot.field? "success_rate" != some (.num "0.500000") && tot.field? "success_rate" != some (.num "0.5") then
      failures := failures.push s!"proxy/health: totals.success_rate must be 0.5 for 1 ok of 2 requests, got {renderCompact tot}"
    let ttftP50 := (tot.fieldOrNull "ttft_ms").field? "p50"
    let ttftP95 := (tot.fieldOrNull "ttft_ms").field? "p95"
    let totalP50 := (tot.fieldOrNull "total_ms").field? "p50"
    let totalP95 := (tot.fieldOrNull "total_ms").field? "p95"
    if tot.field? "ttft_p50_ms" != ttftP50 ||
       tot.field? "ttft_p95_ms" != ttftP95 ||
       tot.field? "latency_p50_ms" != totalP50 ||
       tot.field? "latency_p95_ms" != totalP95 then
      failures := failures.push s!"proxy/health: totals ttft/latency p50/p95 must match ttft_ms/total_ms p50/p95, got {renderCompact tot}"
    if (tot.fieldOrNull "errors").asObj?.isNone ||
       (tot.fieldOrNull "errors").fieldNat? "server_error:502" != some 1 then
      failures := failures.push s!"proxy/health: totals.errors must map server_error:502 -> 1, got {renderCompact tot}"
    let some groups := h24.fieldArr? "groups"
      | failures := failures.push s!"proxy/health: expected groups array, got {renderCompact h24}"; return failures
    let some chains := h24.fieldArr? "chains"
      | failures := failures.push s!"proxy/health: expected chains array, got {renderCompact h24}"; return failures
    if groups.size != 1 then
      failures := failures.push s!"proxy/health: expected 1 group row from proxy_outcomes, got {groups.size}: {renderCompact (.arr groups)}"
    else
      let g := groups[0]!
      if g.fieldStr? "provider" != some "anthropic" ||
         g.fieldStr? "model" != some "claude-sonnet-4-5" ||
         g.fieldStr? "account_id" != some "10000000-0000-4000-8000-000000000001" ||
         g.fieldNat? "requests" != some 2 ||
         g.fieldNat? "ok" != some 1 ||
         g.fieldNat? "retried" != some 1 ||
         (g.field? "fell_back").isSome ||
         (g.fieldArr? "flags").isNone ||
         (g.fieldOrNull "errors").fieldNat? "server_error:502" != some 1 then
        failures := failures.push s!"proxy/health: group row missing client ReliabilityGroup fields or wrong retried/errors, got {renderCompact g}"
    if chains.size != 1 then
      failures := failures.push s!"proxy/health: expected 1 chain row from proxy_outcomes, got {chains.size}: {renderCompact (.arr chains)}"
    else
      let c := chains[0]!
      if c.fieldStr? "chain_id" != some "builtin/smart" ||
         c.fieldNat? "requests" != some 2 ||
         c.fieldNat? "ok" != some 1 ||
         c.fieldNat? "retried" != some 1 ||
         (c.field? "fell_back").isSome ||
         (c.fieldOrNull "errors").fieldNat? "server_error:502" != some 1 then
        failures := failures.push s!"proxy/health: chain row missing client ChainReliability fields or wrong retried/errors, got {renderCompact c}"
  finally
    discard <| execParamQuery store.missionsDb "DELETE FROM proxy_outcomes;" #[]
  return failures

/-- Contract test for `GET /api/ai/usage/summary`: verifies additive client-read fields
    (`since`, `by_route`, `by_root_mission`, `by_hour`, `by_mission`, flattened `UsageTotals`
    field `requests` on `totals`/`today`/`this_week` and every group/day/hour row,
    `model`/`provider`/`source` on `by_model`, and `by_day` populated even when `compact=true`,
    while unsettled pricing fields `cost_cents`, `unknown_cost_requests`, and `cost_status`
    remain absent). -/
private def usageSummaryClientShapeContract (app : CoreAppState) (store : CoreStore) (jwt : String)
    (now : UInt64) : IO (Array String) := do
  let mut failures : Array String := #[]
  let wallNow ← nowEpoch
  let tsRecentSec := if wallNow % 86400 == 0 then wallNow else wallNow - 1
  let tsRecent := formatEpochIso8601Utc tsRecentSec
  let ts20d := formatEpochIso8601Utc (wallNow - 20 * 86400)
  let dayPrefix := (tsRecent.take 10).toString
  let day20dPrefix := (ts20d.take 10).toString
  let hourPrefix := (tsRecent.take 13).toString
  discard <| execParamQuery store.missionsDb "DELETE FROM proxy_usage;" #[]
  discard <| execParamQuery store.missionsDb
    "DELETE FROM missions WHERE id IN ('m-usage-1','m-usage-sub-1','m-usage-sub-2','m-usage-2','m-usage-2-sub','m-usage-3');" #[]
  discard <| execParamQuery store.missionsDb
    ("INSERT INTO missions(id,parent_mission_id) VALUES" ++
     "('m-usage-1',NULL),('m-usage-sub-1','m-usage-1'),('m-usage-sub-2','m-usage-sub-1')," ++
     "('m-usage-2',NULL),('m-usage-2-sub','m-usage-2')," ++
     "('m-usage-3',NULL);") #[]
  discard <| execParamQuery store.missionsDb
    ("INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,cost_cents,provider,account_id,api_key_id,api_key_name,mission_id,caller_kind,purpose,reasoning_tokens,account_bound) VALUES" ++
     "(?1,'claude-sonnet-4-5',25,15,10,20,15,'anthropic','10000000-0000-4000-8000-000000000001',NULL,'remote-launch:m-usage-1','m-usage-1','mission','turn',5,1)," ++
     "(?1,'claude-sonnet-4-5',95,65,0,10,8,'anthropic','10000000-0000-4000-8000-000000000001',NULL,'remote-launch:m-usage-sub-1','m-usage-sub-1','subagent','turn',0,1)," ++
     "(?1,'claude-sonnet-4-5',85,55,0,5,3,'anthropic','10000000-0000-4000-8000-000000000001',NULL,'remote-launch:m-usage-sub-2','m-usage-sub-2','subagent','turn',0,1)," ++
     "(?1,'claude-sonnet-4-5',100,65,0,0,10,'anthropic','10000000-0000-4000-8000-000000000001',NULL,'remote-launch:m-usage-2','m-usage-2','mission','turn',0,1)," ++
     "(?1,'claude-sonnet-4-5',100,75,0,0,6,'anthropic','10000000-0000-4000-8000-000000000001',NULL,'remote-launch:m-usage-2-sub','m-usage-2-sub','subagent','turn',0,1)," ++
     "(?1,'claude-sonnet-4-5',130,50,0,0,9,'anthropic','10000000-0000-4000-8000-000000000001',NULL,'remote-launch:m-usage-3','m-usage-3','mission','turn',0,1)," ++
     "(?1,'claude-sonnet-4-5',100,80,0,0,4,'anthropic','10000000-0000-4000-8000-000000000001',NULL,'',NULL,'api','turn',0,1);")
    #[tsRecent]
  try
    let s24 ← getJson app jwt "/api/ai/usage/summary?window=24h" now
    let rendered24 := renderCompact s24
    if (rendered24.splitOn "remote-launch:").length > 1 then
      failures := failures.push s!"usage/summary: reply leaked execution key remote-launch:, got {rendered24}"
    if s24.field? "since" != s24.field? "window_start" || (s24.fieldStr? "since").isNone then
      failures := failures.push s!"usage/summary: expected since == window_start (non-null for 24h), got {rendered24}"
    if (s24.field? "cost_status").isSome then
      failures := failures.push s!"usage/summary: cost_status must remain absent, got {rendered24}"
    if s24.fieldArr? "by_api_key" != some #[] ||
       (s24.fieldOrNull "filters_available").fieldArr? "api_keys" != some #[] then
      failures := failures.push s!"usage/summary: by_api_key and filters_available.api_keys must be empty, got {rendered24}"
    let sAll ← getJson app jwt "/api/ai/usage/summary?window=all" now
    if sAll.field? "since" != some .null || sAll.field? "window_start" != some .null then
      failures := failures.push s!"usage/summary: expected since == null for window=all, got {renderCompact sAll}"
    for tKey in #["totals", "today", "this_week"] do
      let t := s24.fieldOrNull tKey
      if t.fieldNat? "requests" != t.fieldNat? "events" ||
         t.fieldNat? "requests" != some 7 ||
         t.fieldNat? "recorded_cost_cents" != some 55 ||
         (t.field? "cost_cents").isSome ||
         (t.field? "unknown_cost_requests").isSome then
        failures := failures.push s!"usage/summary: {tKey} expected requests==events==7 and absent cost_cents/unknown_cost_requests, got {renderCompact t}"
    let some bySource := s24.fieldArr? "by_source"
      | failures := failures.push s!"usage/summary: expected by_source array, got {rendered24}"; return failures
    if bySource.size != 1 ||
       bySource[0]!.fieldStr? "key" != some "router" ||
       bySource[0]!.fieldStr? "label" != some "Router" ||
       bySource[0]!.fieldNat? "requests" != some 7 then
      failures := failures.push s!"usage/summary: expected single by_source row (router, requests=7), got {renderCompact (.arr bySource)}"
    let some byModel := s24.fieldArr? "by_model"
      | failures := failures.push s!"usage/summary: expected by_model array, got {rendered24}"; return failures
    if byModel.size != 1 then
      failures := failures.push s!"usage/summary: expected 1 by_model row, got {renderCompact (.arr byModel)}"
    else
      let m := byModel[0]!
      if m.fieldStr? "model" != some "claude-sonnet-4-5" ||
         m.fieldStr? "provider" != some "anthropic" ||
         m.fieldStr? "source" != some "router" ||
         m.fieldNat? "requests" != some 7 ||
         (m.field? "cost_cents").isSome ||
         (m.field? "unknown_cost_requests").isSome ||
         (m.field? "cost_status").isSome then
        failures := failures.push s!"usage/summary: by_model[0] unexpected ModelUsage fields, got {renderCompact m}"
    for gKey in #["by_provider", "by_source", "by_route", "by_caller_kind", "by_purpose", "by_mission", "by_root_mission", "by_account"] do
      let some arr := s24.fieldArr? gKey
        | failures := failures.push s!"usage/summary: expected {gKey} array, got {rendered24}"
      if arr.isEmpty then
        failures := failures.push s!"usage/summary: expected non-empty {gKey} for seeded proxy_usage row"
      else
        for g in arr do
          if g.fieldNat? "requests" != g.fieldNat? "events" ||
             (g.field? "cost_cents").isSome ||
             (g.field? "unknown_cost_requests").isSome ||
             (g.field? "cost_status").isSome then
            failures := failures.push s!"usage/summary: {gKey} row unexpected UsageTotals fields, got {renderCompact g}"
    let some byMission := s24.fieldArr? "by_mission"
      | failures := failures.push s!"usage/summary: expected by_mission array, got {rendered24}"; return failures
    if byMission.size != 7 ||
       !(byMission.any (fun g => g.field? "key" == some .null && g.field? "label" == some .null && g.fieldNat? "requests" == some 1)) ||
       !(byMission.any (fun g => g.fieldStr? "key" == some "m-usage-1" && g.fieldNat? "requests" == some 1)) ||
       !(byMission.any (fun g => g.fieldStr? "key" == some "m-usage-sub-1" && g.fieldNat? "requests" == some 1)) ||
       !(byMission.any (fun g => g.fieldStr? "key" == some "m-usage-sub-2" && g.fieldNat? "requests" == some 1)) then
      failures := failures.push s!"usage/summary: by_mission expected 7 buckets including m-usage-1, m-usage-sub-1, m-usage-sub-2, and null, got {renderCompact (.arr byMission)}"
    let some byRootMission := s24.fieldArr? "by_root_mission"
      | failures := failures.push s!"usage/summary: expected by_root_mission array, got {rendered24}"; return failures
    let rootM1 := (byRootMission.find? (fun g => g.fieldStr? "key" == some "m-usage-1")).getD .null
    if rootM1.fieldStr? "key" != some "m-usage-1" ||
       rootM1.fieldStr? "label" != some "m-usage-1" ||
       rootM1.fieldNat? "requests" != some 3 ||
       rootM1.fieldNat? "input_tokens" != some 205 then
      failures := failures.push s!"usage/summary (a): root row m-usage-1 must have key == label == m-usage-1 (requests=3, input=205) even when child bucket is larger than parent, got {renderCompact rootM1}"
    let rootTotals : Array Nat := byRootMission.map (fun g => (g.fieldNat? "input_tokens").getD 0 + (g.fieldNat? "output_tokens").getD 0)
    let mut nonIncreasing := true
    for idx in [1:rootTotals.size] do
      if rootTotals[idx]! > rootTotals[idx - 1]! then
        nonIncreasing := false
    let sTop2 ← getJson app jwt "/api/ai/usage/summary?window=24h&top_limit=2" now
    let rootTop2 := (sTop2.fieldArr? "by_root_mission").getD #[]
    let top2Totals : Array Nat := rootTop2.map (fun g => (g.fieldNat? "input_tokens").getD 0 + (g.fieldNat? "output_tokens").getD 0)
    if byRootMission.size != 4 || !nonIncreasing || top2Totals != #[340, 340] ||
       !(byRootMission.any (fun g => g.field? "key" == some .null && g.fieldNat? "requests" == some 1)) then
      failures := failures.push s!"usage/summary (b): by_root_mission must be in non-increasing input+output order (got totals={rootTotals}) and top_limit=2 must return the two largest [340, 340] (got {top2Totals}): {renderCompact (.arr byRootMission)}"
    let some byDay := s24.fieldArr? "by_day"
      | failures := failures.push s!"usage/summary: expected by_day array, got {rendered24}"; return failures
    if byDay.size != 1 then
      failures := failures.push s!"usage/summary: expected 1 by_day row, got {renderCompact (.arr byDay)}"
    else
      let d := byDay[0]!
      if d.fieldStr? "day" != some dayPrefix ||
         d.fieldNat? "requests" != some 7 ||
         d.fieldNat? "router_requests" != some 7 ||
         (d.field? "cost_cents").isSome ||
         (d.field? "unknown_cost_requests").isSome ||
         (d.fieldOrNull "by_caller_kind").fieldNat? "mission" != some 3 ||
         (d.fieldOrNull "by_caller_kind").fieldNat? "subagent" != some 3 ||
         (d.fieldOrNull "by_caller_kind").fieldNat? "api" != some 1 ||
         (d.fieldOrNull "totals").fieldNat? "requests" != some 7 then
        failures := failures.push s!"usage/summary: by_day[0] unexpected DayUsage fields, got {renderCompact d}"
    let some byHour := s24.fieldArr? "by_hour"
      | failures := failures.push s!"usage/summary: expected by_hour array, got {rendered24}"; return failures
    if byHour.size != 1 then
      failures := failures.push s!"usage/summary: expected 1 by_hour row, got {renderCompact (.arr byHour)}"
    else
      let h := byHour[0]!
      if h.fieldStr? "hour" != some hourPrefix ||
         h.fieldNat? "requests" != some 7 ||
         h.fieldNat? "router_requests" != some 7 ||
         (h.field? "cost_cents").isSome ||
         (h.field? "unknown_cost_requests").isSome ||
         (h.fieldOrNull "by_caller_kind").fieldNat? "mission" != some 3 then
        failures := failures.push s!"usage/summary: by_hour[0] unexpected HourUsage fields, got {renderCompact h}"
    -- Mobile compact query (`compact=true&top_limit=5`) reads `by_day` and `by_mission[].requests`
    let sCompact ← getJson app jwt "/api/ai/usage/summary?window=7d&compact=true&top_limit=5" now
    let some cDays := sCompact.fieldArr? "by_day"
      | failures := failures.push s!"usage/summary compact: expected by_day array, got {renderCompact sCompact}"; return failures
    let some cMissions := sCompact.fieldArr? "by_mission"
      | failures := failures.push s!"usage/summary compact: expected by_mission array, got {renderCompact sCompact}"; return failures
    if cDays.size != 1 || cDays[0]!.fieldNat? "requests" != some 7 ||
       cMissions.size != 5 then
      failures := failures.push s!"usage/summary compact: expected populated by_day and by_mission with requests, got {renderCompact sCompact}"
    -- Window > 14 days (`window=30d`) must include days older than 14 days even when 15 newer days exist
    for dIdx in [1:16] do
      let tsMid := formatEpochIso8601Utc (wallNow - dIdx.toUInt64 * 86400)
      discard <| execParamQuery store.missionsDb
        ("INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cost_cents,provider,account_id,mission_id,caller_kind,purpose) " ++
         "VALUES(?1,'claude-sonnet-4-5',10,10,1,'anthropic','10000000-0000-4000-8000-000000000001','m-usage-1','mission','turn');")
        #[tsMid]
    discard <| execParamQuery store.missionsDb
      ("INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cost_cents,provider,account_id,mission_id,caller_kind,purpose) " ++
       "VALUES(?1,'claude-sonnet-4-5',10,10,1,'anthropic','10000000-0000-4000-8000-000000000001','m-usage-1','mission','turn');")
      #[ts20d]
    let s30d ← getJson app jwt "/api/ai/usage/summary?window=30d" now
    let days30 := (s30d.fieldArr? "by_day").getD #[]
    if !(days30.any (fun d => d.fieldStr? "day" == some day20dPrefix)) then
      failures := failures.push s!"usage/summary: window=30d by_day missing 20-day-old row ({day20dPrefix}), got {days30.size} days: {renderCompact (.arr days30)}"
  finally
    discard <| execParamQuery store.missionsDb "DELETE FROM proxy_usage;" #[]
    discard <| execParamQuery store.missionsDb
      "DELETE FROM missions WHERE id IN ('m-usage-1','m-usage-sub-1','m-usage-sub-2','m-usage-2','m-usage-2-sub','m-usage-3','m-usage-4');" #[]
  return failures

/-- PROV06/PROV07/PROV08/PROV09/PROV10/PROV11: pure provider usage projections and live
    usage fetcher contracts against a local loopback server (zero external vendor probes). -/
private def providerUsageFetchersContract : IO (Array String) := do
  let failuresRef ← IO.mkRef (#[] : Array String)
  let must (cond : Bool) (msg : String) : IO Unit := do
    if !cond then failuresRef.modify (·.push s!"usage-fetchers: {msg}")

  -- 1. Muse Code projection (`projectMuseCodeUsage`):
  --    - `subs_tier_name` -> `muse_plan`
  --    - `is_subs_active` -> `muse_subscription_active` (never default true when absent!)
  --    - `subs_usage.window` -> `muse_5h_used_percent`, `muse_5h_reset`
  --    - `subs_usage.weekly` -> `muse_weekly_used_percent`, `muse_weekly_reset`
  --    - Idle response (no windows) -> `usage_note`, no fake `muse_subscription_active`
  let .ok museActiveRaw := OrbBin.Json.parse
      "{\"subs_tier_name\":\"Muse Pro\",\"is_subs_active\":true,\"subs_usage\":{\"window\":{\"used_percent\":42.5,\"resets_at\":1780003600},\"weekly\":{\"used_percent\":85,\"resets_at\":1780500000}}}"
    | throw (IO.userError "museActiveRaw parse failed")
  let (museFields, museWins, musePrimary) := projectMuseCodeUsage museActiveRaw
  let museObj := JVal.obj museFields
  must (museObj.fieldStr? "muse_plan" == some "Muse Pro")
    s!"muse_plan expected 'Muse Pro', got {museObj.fieldStr? "muse_plan"}"
  must (museObj.fieldBool? "muse_subscription_active" == some true)
    s!"muse_subscription_active expected true, got {museObj.fieldBool? "muse_subscription_active"}"
  must (museObj.field? "muse_5h_used_percent" == some (.num "42.5"))
    s!"muse_5h_used_percent expected 42.5, got {renderCompact (museObj.fieldOrNull "muse_5h_used_percent")}"
  must (museObj.fieldInt? "muse_5h_reset" == some 1780003600)
    s!"muse_5h_reset expected 1780003600, got {museObj.fieldInt? "muse_5h_reset"}"
  must (museObj.field? "muse_weekly_used_percent" == some (.num "85"))
    s!"muse_weekly_used_percent expected 85, got {renderCompact (museObj.fieldOrNull "muse_weekly_used_percent")}"
  must (museObj.fieldInt? "muse_weekly_reset" == some 1780500000)
    s!"muse_weekly_reset expected 1780500000, got {museObj.fieldInt? "muse_weekly_reset"}"
  must ((museObj.field? "usage_note").isNone)
    "muse active windows must not emit idle usage_note"
  must (museWins.size == 2 && musePrimary == .str "muse_weekly")
    s!"muse optimize windows expected 2 with primary muse_weekly (tighter 15% rem vs 58% rem), got size={museWins.size} primary={renderCompact musePrimary}"

  let (museIdleFields, museIdleWins, _) := projectMuseCodeUsage (.obj #[("subs_tier_name", .str "Muse Team")])
  let museIdleObj := JVal.obj museIdleFields
  must (museIdleObj.fieldStr? "muse_plan" == some "Muse Team")
    "muse idle must preserve muse_plan"
  must ((museIdleObj.field? "muse_subscription_active").isNone)
    "muse idle without is_subs_active must NOT fabricate muse_subscription_active=true"
  must (museIdleObj.fieldStr? "usage_note" == some "No Muse Code usage in the current window.")
    s!"muse idle expected usage_note, got {museIdleObj.fieldStr? "usage_note"}"
  must (museIdleWins.isEmpty)
    "muse idle must not emit fake 0% optimize windows"

  -- 2. Kimi Coding usage projection (`projectKimiUsage`):
  --    - `usage` + `limits` shape with `detail` (`limit`/`remaining`/`resetTime`) and `window` (`duration`/`timeUnit`)
  --    - `user.membership.level` (`LEVEL_INTERMEDIATE` -> `Intermediate`)
  --    - `kimi_5h_used_percent`, `kimi_5h_reset`, `kimi_weekly_used_percent`, `kimi_weekly_reset`, `kimi_windows`
  let .ok kimiLimitsRaw := OrbBin.Json.parse
      ("{\"user\":{\"membership\":{\"level\":\"LEVEL_INTERMEDIATE\"}}," ++
       "\"usage\":{\"limit\":\"2000\",\"used\":\"500\",\"remaining\":\"1500\",\"resetTime\":\"2026-06-05T10:00:00Z\"}," ++
       "\"limits\":[{\"window\":{\"duration\":300,\"timeUnit\":\"TIME_UNIT_MINUTE\"}," ++
       "\"detail\":{\"limit\":\"200\",\"remaining\":\"50\",\"resetTime\":\"1780003600000\"}}]}")
    | throw (IO.userError "kimiLimitsRaw parse failed")
  let (kimiFields, kimiWins, kimiPrimary) := projectKimiUsage kimiLimitsRaw 1780000000
  let kimiObj := JVal.obj kimiFields
  must (kimiObj.fieldStr? "kimi_plan" == some "Intermediate")
    s!"kimi_plan expected 'Intermediate', got {kimiObj.fieldStr? "kimi_plan"}"
  must (kimiObj.field? "kimi_5h_used_percent" == some (.num "75") || kimiObj.field? "kimi_5h_used_percent" == some (.num "75.0"))
    s!"kimi_5h_used_percent expected 75, got {renderCompact (kimiObj.fieldOrNull "kimi_5h_used_percent")}"
  must (kimiObj.fieldInt? "kimi_5h_reset" == some 1780003600)
    s!"kimi_5h_reset expected 1780003600 (ms converted to s), got {kimiObj.fieldInt? "kimi_5h_reset"}"
  must (kimiObj.field? "kimi_weekly_used_percent" == some (.num "25") || kimiObj.field? "kimi_weekly_used_percent" == some (.num "25.0"))
    s!"kimi_weekly_used_percent expected 25, got {renderCompact (kimiObj.fieldOrNull "kimi_weekly_used_percent")}"
  must (kimiObj.fieldInt? "kimi_weekly_reset" == some 1780653600)
    s!"kimi_weekly_reset expected 1780653600, got {kimiObj.fieldInt? "kimi_weekly_reset"}"
  let kwArr := (kimiObj.fieldArr? "kimi_windows").getD #[]
  must (kwArr.size == 2 && kwArr[0]!.fieldStr? "label" == some "5h" && kwArr[1]!.fieldStr? "label" == some "Weekly")
    s!"kimi_windows expected [5h, Weekly], got {renderCompact (.arr kwArr)}"
  must (kimiWins.size == 2 && kimiPrimary == .str "kimi_5h")
    s!"kimi optimize expected primary kimi_5h, got {renderCompact kimiPrimary}"

  -- 3. xAI / Grok billing + settings projection (`projectXaiBillingUsage`):
  --    - `config.creditUsagePercent`, `config.currentPeriod.{start, end}` -> Weekly/Monthly label, reset epoch, window seconds
  --    - `config.onDemandUsed`, `config.onDemandCap`
  --    - `settings.subscription_tier_display` -> `xai_plan`
  let .ok xaiBillingRaw := OrbBin.Json.parse
      ("{\"config\":{\"creditUsagePercent\":37.5,\"onDemandUsed\":12.5,\"onDemandCap\":50," ++
       "\"currentPeriod\":{\"start\":\"2026-08-10T00:00:00Z\",\"end\":\"2026-08-17T00:00:00Z\"}}}")
    | throw (IO.userError "xaiBillingRaw parse failed")
  let .ok xaiSettingsRaw := OrbBin.Json.parse "{\"subscription_tier_display\":\"SuperGrok Heavy\"}"
    | throw (IO.userError "xaiSettingsRaw parse failed")
  let (xaiFields, xaiWins, xaiPrimary) := projectXaiBillingUsage xaiBillingRaw (some xaiSettingsRaw)
  let xaiObj := JVal.obj xaiFields
  must (xaiObj.fieldStr? "xai_plan" == some "SuperGrok Heavy")
    s!"xai_plan expected 'SuperGrok Heavy', got {xaiObj.fieldStr? "xai_plan"}"
  must (xaiObj.fieldStr? "xai_credit_label" == some "Weekly")
    s!"xai_credit_label expected 'Weekly', got {xaiObj.fieldStr? "xai_credit_label"}"
  must (xaiObj.field? "xai_credit_used_percent" == some (.num "37.5"))
    s!"xai_credit_used_percent expected 37.5, got {renderCompact (xaiObj.fieldOrNull "xai_credit_used_percent")}"
  must (xaiObj.fieldInt? "xai_credit_reset" == some 1786924800)
    s!"xai_credit_reset expected 1786924800, got {xaiObj.fieldInt? "xai_credit_reset"}"
  must (xaiObj.fieldNat? "xai_credit_window_seconds" == some 604800)
    s!"xai_credit_window_seconds expected 604800, got {xaiObj.fieldNat? "xai_credit_window_seconds"}"
  must (xaiObj.field? "xai_on_demand_used" == some (.num "12.5") && (xaiObj.field? "xai_on_demand_cap" == some (.num "50") || xaiObj.field? "xai_on_demand_cap" == some (.num "50.0")))
    s!"xai on_demand expected 12.5/50, got {renderCompact (xaiObj.fieldOrNull "xai_on_demand_used")} / {renderCompact (xaiObj.fieldOrNull "xai_on_demand_cap")}"
  must (xaiWins.size == 1 && xaiPrimary == .str "xai_credits")
    s!"xai optimize expected xai_credits, got {renderCompact xaiPrimary}"

  -- 4. MiniMax Coding Plan projection (`projectMinimaxUsage`):
  --    - `base_resp.status_code == 0` with `model_remains` (`current_interval_total_count`, `current_interval_usage_count`, `end_time`, `current_weekly_total_count`, `current_weekly_usage_count`, `weekly_end_time`, `model_name`)
  --    - Note: MiniMax API's `current_interval_usage_count` is REMAINING count (per minimax_usage.rs)! Also support direct `current_interval_remaining_percent` if present.
  --    - `base_resp.status_code == 2062` -> `usage_note` ("No active Coding Plan..." / "No active Token Plan...")
  let .ok mmActiveRaw := OrbBin.Json.parse
      ("{\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}," ++
       "\"model_remains\":[{\"model_name\":\"MiniMax-M2.7\",\"start_time\":1776186000000,\"end_time\":1776204000000," ++
       "\"remains_time\":205320,\"current_interval_total_count\":1500,\"current_interval_usage_count\":1200," ++
       "\"current_weekly_total_count\":15000,\"current_weekly_usage_count\":9000," ++
       "\"weekly_start_time\":1775952000000,\"weekly_end_time\":1776556800000,\"weekly_remains_time\":353005320}]}")
    | throw (IO.userError "mmActiveRaw parse failed")
  let (mmFields, mmWins, mmPrimary) := projectMinimaxUsage mmActiveRaw
  let mmObj := JVal.obj mmFields
  must (mmObj.fieldNat? "minimax_interval_remaining_percent" == some 80)
    s!"minimax_interval_remaining_percent expected 80, got {renderCompact (mmObj.fieldOrNull "minimax_interval_remaining_percent")}"
  must (mmObj.fieldInt? "minimax_interval_reset" == some 1776204000)
    s!"minimax_interval_reset expected 1776204000, got {mmObj.fieldInt? "minimax_interval_reset"}"
  must (mmObj.fieldNat? "minimax_weekly_remaining_percent" == some 60)
    s!"minimax_weekly_remaining_percent expected 60, got {renderCompact (mmObj.fieldOrNull "minimax_weekly_remaining_percent")}"
  must (mmObj.fieldInt? "minimax_weekly_reset" == some 1776556800)
    s!"minimax_weekly_reset expected 1776556800, got {mmObj.fieldInt? "minimax_weekly_reset"}"
  must (((mmObj.fieldArr? "model_usage").getD #[]).size == 1)
    s!"minimax model_usage expected 1 entry, got {renderCompact (mmObj.fieldOrNull "model_usage")}"
  must (mmWins.size == 2 && mmPrimary == .str "minimax_weekly")
    s!"minimax optimize expected 2 windows with primary minimax_weekly (60% rem < 80% rem), got {renderCompact mmPrimary}"

  let .ok mmNoSubRaw := OrbBin.Json.parse "{\"base_resp\":{\"status_code\":2062,\"status_msg\":\"no plan\"},\"model_remains\":[]}"
    | throw (IO.userError "mmNoSubRaw parse failed")
  let (mmNoSubFields, mmNoSubWins, _) := projectMinimaxUsage mmNoSubRaw
  let mmNoSubObj := JVal.obj mmNoSubFields
  must ((mmNoSubObj.fieldStr? "usage_note").isSome && mmNoSubWins.isEmpty)
    s!"minimax status_code 2062 expected usage_note and empty windows, got {renderCompact mmNoSubObj}"

  -- 5. Z.ai quota monitor projection (`projectZaiUsage`):
  --    - `data.level` -> `zai_plan`
  --    - `TOKENS_LIMIT` `(unit=3, number=5)` -> `zai_5h_used_percent`, `zai_5h_reset` (`nextResetTime / 1000`)
  --    - `TOKENS_LIMIT` `(unit=6, number=1)` -> `zai_weekly_used_percent`, `zai_weekly_reset` (`nextResetTime / 1000`)
  --    - `TIME_LIMIT` -> `zai_mcp_percentage`, `zai_mcp_reset`
  let .ok zaiRaw := OrbBin.Json.parse
      ("{\"data\":{\"level\":\"Pro\",\"limits\":[" ++
       "{\"type\":\"TOKENS_LIMIT\",\"unit\":3,\"number\":5,\"percentage\":30,\"nextResetTime\":1780003600000}," ++
       "{\"type\":\"TOKENS_LIMIT\",\"unit\":6,\"number\":1,\"percentage\":70,\"nextResetTime\":1780608400000}," ++
       "{\"type\":\"TIME_LIMIT\",\"percentage\":15,\"nextResetTime\":1780900000000}]}}")
    | throw (IO.userError "zaiRaw parse failed")
  let (zaiFields, zaiWins, zaiPrimary) := projectZaiUsage zaiRaw
  let zaiObj := JVal.obj zaiFields
  must (zaiObj.fieldStr? "zai_plan" == some "Pro")
    s!"zai_plan expected 'Pro', got {zaiObj.fieldStr? "zai_plan"}"
  must (zaiObj.field? "zai_5h_used_percent" == some (.num "30"))
    s!"zai_5h_used_percent expected 30, got {renderCompact (zaiObj.fieldOrNull "zai_5h_used_percent")}"
  must (zaiObj.fieldInt? "zai_5h_reset" == some 1780003600)
    s!"zai_5h_reset expected 1780003600, got {zaiObj.fieldInt? "zai_5h_reset"}"
  must (zaiObj.field? "zai_weekly_used_percent" == some (.num "70"))
    s!"zai_weekly_used_percent expected 70, got {renderCompact (zaiObj.fieldOrNull "zai_weekly_used_percent")}"
  must (zaiObj.fieldInt? "zai_weekly_reset" == some 1780608400)
    s!"zai_weekly_reset expected 1780608400, got {zaiObj.fieldInt? "zai_weekly_reset"}"
  must (zaiObj.field? "zai_mcp_percentage" == some (.num "15") && zaiObj.fieldInt? "zai_mcp_reset" == some 1780900000)
    s!"zai_mcp expected 15 @ 1780900000, got {renderCompact (zaiObj.fieldOrNull "zai_mcp_percentage")} @ {zaiObj.fieldInt? "zai_mcp_reset"}"
  must (zaiWins.size == 2 && zaiPrimary == .str "zai_weekly")
    s!"zai optimize expected 2 windows with primary zai_weekly (30% rem < 70% rem), got {renderCompact zaiPrimary}"

  -- 6. Antigravity `loadCodeAssist` projection (`projectAntigravityAssist`):
  --    - Plan omitted when `paidTier.name` and `currentTier.name` are absent (never fabricate "Pro")
  --    - `antigravityNeedsVerification` true when no project, `ineligibleTiers` non-empty, and no `currentTier`/`paidTier`
  let .ok agyUnverifiedRaw := OrbBin.Json.parse
      "{\"ineligibleTiers\":[{\"reasonCode\":\"VALIDATION_REQUIRED\",\"validationUrl\":\"https://accounts.google.com/verify-me\"}]}"
    | throw (IO.userError "agyUnverifiedRaw parse failed")
  let (agyPlan1, agyNeedsVer1) := projectAntigravityAssist agyUnverifiedRaw
  must (agyPlan1 == none && agyNeedsVer1 == true)
    s!"antigravity unverified assist expected (none, true), got ({agyPlan1}, {agyNeedsVer1})"

  let .ok agyTierlessRaw := OrbBin.Json.parse "{\"cloudaicompanionProject\":\"proj-123\"}"
    | throw (IO.userError "agyTierlessRaw parse failed")
  let (agyPlan2, agyNeedsVer2) := projectAntigravityAssist agyTierlessRaw
  must (agyPlan2 == none && agyNeedsVer2 == false)
    s!"antigravity tierless assist with project expected (none, false), got ({agyPlan2}, {agyNeedsVer2})"

  -- 7. Codex `wham/usage` two-weekly-windows ("promax") projection (`projectCodexUsage`):
  --    - When both `primary_window` and `secondary_window` report `limit_window_seconds = 604800` (10080 minutes),
  --      the optimize windows must NOT assume `primary = 5h`: they must derive keys/labels from actual window length
  --      and disambiguate identical durations (`7d` / `7-day` and `7d_secondary` / `7-day (secondary)`).
  let .ok codexPromaxRaw := OrbBin.Json.parse
      ("{\"plan_type\":\"promax\",\"rate_limit\":{" ++
       "\"primary_window\":{\"used_percent\":12,\"reset_at\":1740604800,\"limit_window_seconds\":604800}," ++
       "\"secondary_window\":{\"used_percent\":68,\"reset_at\":1740604800,\"limit_window_seconds\":604800}}}")
    | throw (IO.userError "codexPromaxRaw parse failed")
  let (promaxFields, promaxWins, promaxPrimary) := projectCodexUsage codexPromaxRaw
  let promaxObj := JVal.obj promaxFields
  must (promaxObj.fieldStr? "codex_plan_type" == some "promax")
    s!"codex_plan_type expected 'promax', got {promaxObj.fieldStr? "codex_plan_type"}"
  must (promaxObj.fieldNat? "codex_primary_window_minutes" == some 10080 &&
        promaxObj.fieldNat? "codex_secondary_window_minutes" == some 10080)
    s!"codex promax window minutes expected (10080, 10080), got ({promaxObj.fieldNat? "codex_primary_window_minutes"}, {promaxObj.fieldNat? "codex_secondary_window_minutes"})"
  must (promaxWins.size == 2 &&
        promaxWins[0]!.fieldStr? "key" == some "7d" &&
        promaxWins[0]!.fieldStr? "label" == some "7-day" &&
        promaxWins[1]!.fieldStr? "key" == some "7d_secondary" &&
        promaxWins[1]!.fieldStr? "label" == some "7-day (secondary)" &&
        promaxPrimary == .str "7d_secondary")
    s!"codex promax optimize windows expected [7d/7-day, 7d_secondary/7-day (secondary)] with primary 7d_secondary, got {renderCompact (.arr promaxWins)} primary={renderCompact promaxPrimary}"

  let .ok codexNamedRaw := OrbBin.Json.parse
      ("{\"plan_type\":\"promax\",\"rate_limit\":{" ++
       "\"primary_window\":{\"used_percent\":12,\"reset_at\":1740604800,\"limit_window_seconds\":604800,\"limit_name\":\"General\"}," ++
       "\"secondary_window\":{\"used_percent\":68,\"reset_at\":1740604800,\"limit_window_seconds\":604800,\"limit_name\":\"Codex\"}}}")
    | throw (IO.userError "codexNamedRaw parse failed")
  let (namedFields, _, _) := projectCodexUsage codexNamedRaw
  let namedObj := JVal.obj namedFields
  must (namedObj.fieldStr? "codex_primary_window_label" == some "General" &&
        namedObj.fieldStr? "codex_secondary_window_label" == some "Codex")
    s!"codex named window labels expected ('General', 'Codex'), got ({namedObj.fieldStr? "codex_primary_window_label"}, {namedObj.fieldStr? "codex_secondary_window_label"})"

  return (← failuresRef.get)
private def customDiscoveryContract (app : CoreAppState) (jwt : String) (now : UInt64) : IO (Array String) := do
  let mut failures := #[]
  if customModelsUrl "https://custom.invalid/" != "https://custom.invalid/models" ||
      customModelsUrl "https://custom.invalid/api/v1/" != "https://custom.invalid/api/v1/models" ||
      customModelsUrl "https://custom.invalid/models/" != "https://custom.invalid/models" then
    failures := failures.push "custom discovery must append models to the configured API base without inserting a version prefix"
  let (fd, port) ← IO.ofExcept (← LeanSys.Posix.tcpListen "127.0.0.1" 0 8)
  let stop ← IO.mkRef false
  let authorized ← IO.mkRef false
  let server ← IO.asTask (prio := .dedicated) do
    while !(← stop.get) do
      match ← LeanSys.Posix.tcpAcceptPoll fd 100 with
      | .error _ => pure ()
      | .ok client =>
        let raw := String.fromUTF8! (← LeanSys.Posix.readStreamChunk client 8192)
        authorized.set (raw.startsWith "GET /v1/models " && (raw.splitOn "Bearer discovery-fixture-key").length == 2)
        let body := "{\"data\":[{\"id\":\"gpt-6-astra\"},{\"id\":\"gemini-4-argon\"},{\"id\":\"gpt-6-astra\"}]}"
        discard <| LeanSys.Posix.writeAll client s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8
        discard <| LeanSys.Posix.closeFd client
  try
    let (_, created) ← postJson app jwt "/api/ai/providers"
      (renderCompact (.obj #[("id", .str "prov-discovery"), ("name", .str "Surplus Intelligence"),
        ("provider_type", .str "custom"), ("base_url", .str s!"http://127.0.0.1:{port}/v1/"),
        ("api_key", .str "discovery-fixture-key"), ("enabled", .bool true),
        ("custom_models", .arr #[.obj #[("id", .str "gemini-4-argon")], .obj #[("id", .str "manual-only")]])])) now
    let _ := created
    discard <| postJson app jwt "/api/providers/catalog/refresh" "{}" now
    let disc ← getJson app jwt "/api/providers/discovery" now
    let cat ← getJson app jwt "/api/providers?include_all=true&include_unverified=true" now
    let p := (((cat.fieldArr? "providers").getD #[]).find? (fun p => p.fieldStr? "name" == some "Surplus Intelligence")).getD .null
    let ids := ((p.fieldArr? "models").getD #[]).filterMap (·.fieldStr? "id")
    if !(← authorized.get) || !(ids.contains "gpt-6-astra") || !(ids.contains "manual-only") || (ids.filter (· == "gemini-4-argon")).size != 1 then
      failures := failures.push "custom discovery must authenticate GET /v1/models and merge/deduplicate manual and discovered models"
    if ((renderCompact disc).splitOn "gpt-6-astra").length < 2 then
      failures := failures.push "custom discovery must be present on discovery endpoint"
    if ((renderCompact cat ++ renderCompact disc).splitOn "discovery-fixture-key").length != 1 then
      failures := failures.push "custom discovery must never return API key"
    -- Node X4: plain `ethereumfoundation/glm-5.3` is rejected upstream while flash variants work;
    -- discovery, catalog, direct routing, and chain entries must drop plain `glm-5.3` and keep flash variants.
    if OrbCore.ProxyModelRouting.customProviderModelAllowed "Ethereum Foundation" "https://inference.ethereum.foundation/v1" "glm-5.3" ||
       OrbCore.ProxyModelRouting.customProviderModelAllowed "ethereumfoundation" "" "glm-5.3" ||
       !OrbCore.ProxyModelRouting.customProviderModelAllowed "Ethereum Foundation" "https://inference.ethereum.foundation/v1" "glm-5.3-flash" ||
       !OrbCore.ProxyModelRouting.customProviderModelAllowed "zai" "" "glm-5.3" then
      failures := failures.push "X4: customProviderModelAllowed must reject plain ethereumfoundation/glm-5.3 while keeping flash variants and zai/glm-5.3"
    if (OrbCore.ProxyModelRouting.directEntry? "ethereumfoundation/glm-5.3" "/v1/chat/completions"
        #[("ethereumfoundation", "glm-5.3"), ("ethereumfoundation", "glm-5.3-flash")]).isSome ||
       (OrbCore.ProxyModelRouting.directEntry? "ethereumfoundation/glm-5.3-flash" "/v1/chat/completions"
        #[("ethereumfoundation", "glm-5.3"), ("ethereumfoundation", "glm-5.3-flash")]) != some ("ethereumfoundation", "glm-5.3-flash") then
      failures := failures.push "X4: directEntry? must reject plain ethereumfoundation/glm-5.3 and allow ethereumfoundation/glm-5.3-flash"
    let x4Chain := OrbCore.ProxyModelRouting.chainResponse "reviewer" "Reviewer"
      "[{\"provider_id\":\"ethereumfoundation\",\"model_id\":\"glm-5.3\"},{\"provider_id\":\"ethereumfoundation\",\"model_id\":\"glm-5.3-flash\"},{\"provider_id\":\"zai\",\"model_id\":\"glm-5.3\"}]"
      false false "t0" "t0"
    let x4Entries := ((x4Chain.fieldArr? "entries").getD #[]).map (fun e =>
      ((e.fieldStr? "provider_id").getD "", (e.fieldStr? "model_id").getD ""))
    if x4Entries != #[("ethereumfoundation", "glm-5.3-flash"), ("zai", "glm-5.3")] then
      failures := failures.push s!"X4: chainResponse must strip plain ethereumfoundation/glm-5.3 and preserve flash + zai/glm-5.3, got {x4Entries}"
    let (_, _) ← postJson app jwt "/api/ai/providers"
      (renderCompact (.obj #[("id", .str "prov-eth-x4"), ("name", .str "Ethereum Foundation"),
        ("provider_type", .str "custom"), ("base_url", .str s!"http://127.0.0.1:{port}/v1/"),
        ("api_key", .str "discovery-fixture-key"), ("enabled", .bool true),
        ("custom_models", .arr #[.obj #[("id", .str "glm-5.3")], .obj #[("id", .str "glm-5.3-flash")]])])) now
    let ethCat ← getJson app jwt "/api/providers/catalog" now
    let ethProv := (((ethCat.fieldArr? "providers").getD #[]).find? (fun p => p.fieldStr? "id" == some "prov-eth-x4")).getD .null
    let ethIds := ((ethProv.fieldArr? "models").getD #[]).filterMap (·.fieldStr? "id")
    if ethIds != #["glm-5.3-flash"] then
      failures := failures.push s!"X4: /api/providers/catalog must omit plain ethereumfoundation/glm-5.3 and keep glm-5.3-flash, got {ethIds}"
  finally
    stop.set true
    discard <| IO.wait server
    discard <| LeanSys.Posix.closeFd fd
  return failures

private def routingCatalogContract (app : CoreAppState) (root jwt : String) (now : UInt64) : IO (Array String) := do
  let mut failures := #[]
  let previousCatalog ← IO.getEnv "SANDBOXED_CATALOG_DIR"
  let cwd ← IO.currentDir
  let catalog := s!"{root}/installed/share/orb/catalog"
  IO.FS.createDirAll s!"{catalog}/snapshots"
  IO.FS.writeFile s!"{catalog}/providers.json"
    "{\"providers\":[{\"id\":\"google\",\"name\":\"Installed Google\"}]}"
  IO.FS.writeFile s!"{catalog}/snapshots/google-api.json"
    "{\"models\":[{\"id\":\"installed-google-model\"}]}"
  let discoveryPath := s!"{app.store.rootDir}/model-discovery.json"
  IO.FS.writeFile discoveryPath
    "{\"schema_version\":1,\"connections\":[{\"provider_id\":\"antigravity\",\"last_success\":{\"completeness\":\"complete\",\"models\":[{\"id\":\"gemini-4-carbon-low\"},{\"id\":\"gemini-4-carbon-medium\"},{\"id\":\"gemini-4-carbon-high\"},{\"id\":\"gemini-4-carbon-high\"}]}}]}"
  -- Sidecar-only OAuth connection: deliberately absent from SQLite and static catalog.
  IO.FS.writeFile s!"{root}/auth-empty/antigravity-catalog.json"
    "{\"type\":\"antigravity\",\"access_token\":\"fixture-only-no-live-access\",\"email\":\"catalog@example.invalid\"}"
  try
    setenvVar "SANDBOXED_CATALOG_DIR" catalog
    IO.Process.setCurrentDir root
    let doc ← getJson app jwt "/api/providers?include_all=true&include_unverified=true" now
    let providers := (doc.fieldArr? "providers").getD #[]
    let google := (providers.find? (fun p => p.fieldStr? "id" == some "google")).getD .null
    if google.fieldStr? "name" != some "Installed Google" ||
        ((google.fieldArr? "models").getD #[]).filterMap (·.fieldStr? "id") != #["installed-google-model"] then
      failures := failures.push "catalog must load env-selected providers AND snapshots outside repository cwd, not emergency fallback"
    let ag := providers.filter (fun p => p.fieldStr? "id" == some "antigravity")
    let models := (((ag[0]?).getD JVal.null).fieldArr? "models").getD #[]
    if ag.size != 1 || models.filterMap (·.fieldStr? "id") !=
        #["gemini-4-carbon-low", "gemini-4-carbon-medium", "gemini-4-carbon-high"] then
      failures := failures.push "OAuth-only Antigravity must appear once with deduplicated discovered Carbon ids"
    if !((doc.fieldArr? "configured_ids").getD #[]).contains (.str "antigravity") then
      failures := failures.push "OAuth-only Antigravity must be marked connected"
    if ((renderCompact doc).splitOn "fixture-only-no-live-access").length != 1 then
      failures := failures.push "catalog leaked credentials"
  finally
    IO.Process.setCurrentDir cwd
    match previousCatalog with
    | some v => setenvVar "SANDBOXED_CATALOG_DIR" v
    | none => unsetenvVar "SANDBOXED_CATALOG_DIR"
    IO.FS.removeFile discoveryPath
    IO.FS.removeFile s!"{root}/auth-empty/antigravity-catalog.json"
  return failures

/-- Real loopback HTTP and real proxy auth; only the vendor transport is replaced. -/
private def routingChainProbeContract (app : CoreAppState) (jwt : String) (now : UInt64) : IO (Array String) := do
  let mut failures := #[]
  let (fd, port) ← IO.ofExcept (← LeanSys.Posix.tcpListen "127.0.0.1" 0 8)
  let stop ← IO.mkRef false
  let reached ← IO.mkRef false
  let chains ← IO.mkRef #[{ id := "smart", name := "Smart", targets := #[{
    accountId := "probe-fixture", provider := "openai", modelId := "fixture-model",
    baseUrl := "https://fixture.invalid", apiKey := "fixture-key"
  }] : RoutingChain }]
  let app := { app with
    cfg := { app.cfg with port := port, proxySecret := "configured-secret-not-in-env" }
    chainsRef := chains
    proxyMockTransport? := some (fun _ => do
      reached.set true
      return .ok { status := 200, headers := #[], body := "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"pong\"}}]}".toUTF8 }) }
  let server ← IO.asTask (prio := .dedicated) do
    while !(← stop.get) do
      match ← LeanSys.Posix.tcpAcceptPoll fd 100 with
      | .error _ => pure ()
      | .ok client =>
        let bytes ← LeanSys.Posix.readStreamChunk client 65536
        let response ← match parseRequest bytes none with
          | .error _ => pure (401, "{}")
          | .ok req => do
            match ← dispatchCoreRequest app req now with
            | .error _ => pure (500, "{}")
            | .ok resp => pure (resp.status, String.fromUTF8! resp.body)
        let (code, body) := response
        discard <| LeanSys.Posix.writeAll client
          s!"HTTP/1.1 {code} Result\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8
        discard <| LeanSys.Posix.closeFd client
  try
    let (_, doc) ← postJson app jwt "/api/model-routing/chains/builtin/smart/test" "{}" now
    if doc.fieldBool? "ok" != some true || !(← reached.get) then
      failures := failures.push s!"authenticated builtin/smart test must reach upstream: {renderCompact doc}"
    if ← authenticateProxyRequest app #[] now then
      failures := failures.push "proxy must still reject missing credentials"
  finally
    stop.set true
    discard <| IO.wait server
    discard <| LeanSys.Posix.closeFd fd
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
      -- Protected provider routes require a live named user, not a subjectless
      -- legacy token whose authority was supplied by the bootstrap fallback.
      let .ok admin ← createUserRecord store "provider-admin" cfg.dashboardPassword "admin"
          none none "2026-11-16T00:00:00Z"
        | throw (IO.userError "provider contract admin creation failed")
      let jwt := mintSessionTokenV2 cfg.jwtSecret admin.id admin.role admin.sessionEpoch (now + 3600)
      let mut failures : Array String := #[]
      let .ok member ← createUserRecord store "vpn-settings-member" "vpn-member-fixture-password" "member"
          none none "2026-11-16T00:00:00Z"
        | throw (IO.userError "VPN settings member creation failed")
      let memberJwt := mintSessionTokenV2 cfg.jwtSecret member.id member.role member.sessionEpoch (now + 3600)
      let vpnSettings := "/api/settings/airvpn"
      let accountRoute := "/api/ai/providers/missing-account/vpn"
      for path in [vpnSettings, accountRoute] do
        let (anonymous, _) ← putJson app "" path "{}" now
        let (memberCode, _) ← putJson app memberJwt path "{}" now
        if anonymous != 401 || memberCode != 403 then
          failures := failures.push s!"VPN settings authority {path}: anonymous={anonymous}, member={memberCode}"
      let (missing, _) ← putJson app jwt accountRoute "{}" now
      if missing != 404 then failures := failures.push "VPN admin route must resolve the selected account"
      let settings ← getJson app jwt vpnSettings now
      if settings.fieldBool? "api_key_configured" != some false then
        failures := failures.push "VPN admin settings must expose the initial configuration status"
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
      let r26Tracker ← newProviderHealthTracker
      let r26App := { app with healthTracker? := some r26Tracker }
      failures := failures ++ (← r26DisabledProviderHealthContract r26App jwt r26Tracker)
      failures := failures ++ (← r26SidecarToggleAndOrphanContract app root jwt)
      failures := failures ++ (← proxyHealthClientShapeContract app store jwt now)
      failures := failures ++ (← usageSummaryClientShapeContract app store jwt now)
      failures := failures ++ (← providerUsageFetchersContract)
      failures := failures ++ (← routingCatalogContract app root jwt now)
      failures := failures ++ (← routingChainProbeContract app jwt now)
      failures := failures ++ (← customDiscoveryContract app jwt now)
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
