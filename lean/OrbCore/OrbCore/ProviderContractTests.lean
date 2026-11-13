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
          let cached ← getJson app jwt
            "/api/ai/providers/10000000-0000-4000-8000-000000000002/usage?cached_only=true" now
          if cached.fieldInt? "codex_primary_reset_at" != some 1740001800 ||
             cached.fieldInt? "codex_secondary_reset_at" != some 1740604800 then
            failures := failures.push "cached Codex HTTP reset fields must be numeric epochs"
          if cached.fieldStr? "status" != some "needs_reauth" then
            failures := failures.push "provider metadata must not clear a cached authentication rejection"
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
