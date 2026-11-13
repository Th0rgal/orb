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

private def postJson (app : CoreAppState) (jwt target : String) (now : UInt64) : IO (Nat × JVal) := do
  let raw := s!"POST {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: 0\r\n\r\n"
  let .ok req := parseRequest raw.toUTF8 none
    | throw (IO.userError "provider contract POST request parse failed")
  let .ok resp ← dispatchCoreRequest app req now
    | throw (IO.userError "provider contract POST dispatch failed")
  return (resp.status, (parseBytes resp.body).toOption.getD .null)

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
  let (clearCode, _) ← postJson app jwt s!"/api/model-routing/health/{oauthOnly}/clear" now
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
      let hub ← newProviderRuntimeHub
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
      failures := failures ++ (← healthCooldownOwners app jwt cooldownsRef)
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
