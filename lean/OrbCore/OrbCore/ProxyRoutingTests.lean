/-
  Rust proxy model admission regressions. No vendor calls: all transport is mocked.
  Saved aliases are test-only configurations, not guessed production definitions.
-/
import OrbCore.Control

namespace OrbCore.ProxyRoutingTests
open LeanSys.Http OrbBin.Json OrbBin.PosixExt
open OrbCore.Control OrbCore.Store OrbCore.Proxy OrbCore.Managed

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"proxy routing contract: {label}")

private def chain (id name model : String) : RoutingChain := {
  id := id
  name := name
  targets := #[{ accountId := id, provider := "openai", baseUrl := "http://127.0.0.1:1", apiKey := "fixture-only", modelId := model }]
}

/-- Actual request routing, including unknown errors and no default/name/suffix aliasing. -/
def run : IO Unit := do
  let root := s!"/tmp/orb-proxy-routing-{← newUuidV4}"
  let .ok store ← openCoreStore root
    | throw (IO.userError "proxy routing fixture store failed")
  try
    let managedRef ← IO.mkRef ({} : ManagedFleetState)
    let chainsRef ← IO.mkRef #[
      chain "builtin/smart" "Smart (Default)" "stock-smart-model",
      chain "smart" "Custom smart" "exact-smart-model",
      chain "reviewer" "Reviewer" "review-model",
      chain "MiniMax-M3" "Scout" "scout-model",
      chain "user/review" "Friendly review display" "namespaced-review-model"]
    let cooldowns ← IO.mkRef (#[] : Array AccountCooldown)
    let seqRef ← IO.mkRef (1 : UInt64)
    let attempts ← IO.mkRef (#[] : Array String)
    let cfg : CoreConfig := {
      workingDir := root
      proxySecret := "proxy-routing-fixture-secret-0123456789"
      jwtSecret := "proxy-routing-fixture-jwt-secret-0123456789"
    }
    let app : CoreAppState := {
      cfg, store, searchIdx? := none, managedRef, chainsRef,
      proxyCooldownsRef := cooldowns, seqRef,
      proxyMockTransport? := some (fun target => do
        attempts.modify (·.push target.modelId)
        return .ok {
          status := 200
          headers := #[("content-type", "application/json")]
          body := "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"fixture output\"},\"finish_reason\":\"stop\"}]}".toUTF8
        })
    }
    let post := fun (model : String) => do
      let body := renderCompact (.obj #[("model", .str model), ("messages", .arr #[])])
      let raw := s!"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {cfg.proxySecret}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none
        | throw (IO.userError "proxy routing fixture request parse failed")
      let .ok response ← dispatchCoreRequest app req 1700001000
        | throw (IO.userError "unexpected proxy routing websocket upgrade")
      return response
    let mut failures : Array String := #[]
    -- Exact id wins even when a builtin compatibility id occurs earlier.
    for (model, expected) in #[
        ("smart", "exact-smart-model"), ("builtin/smart", "stock-smart-model"),
        ("reviewer", "review-model"), ("builtin/reviewer", "review-model"),
        ("MiniMax-M3", "scout-model"), ("builtin/MiniMax-M3", "scout-model"),
        ("user/review", "namespaced-review-model"),
        ("builtin/user/review", "namespaced-review-model")] do
      attempts.set #[]
      let response ← post model
      if response.status != 200 || (← attempts.get) != #[expected] then
        failures := failures.push s!"{model}: wrong saved-chain target or status"
    -- Neither display names, arbitrary namespace suffixes, case-folding nor an
    -- unknown id may silently choose the default chain.
    for model in #["Friendly review display", "Smart (Default)", "Smart", " smart ",
        "BUILTIN/smart", "other/smart", "missing-model", "unknown\"quoted-model"] do
      attempts.set #[]
      let response ← post model
      let body := (OrbBin.Json.parseBytes response.body).toOption.getD .null
      let error := body.fieldOrNull "error"
      if response.status != 400 || error.fieldStr? "code" != some "model_not_found" ||
          (((error.fieldStr? "message").getD "").splitOn model).length ≤ 1 ||
          !(← attempts.get).isEmpty then
        failures := failures.push s!"{model}: expected named 400 before transport"
    -- Exercise every saved id and its compatibility spelling, not an allowlist
    -- containing only today's smart/reviewer incidents.
    for c in (← chainsRef.get) do
      for requested in #[c.id, s!"builtin/{c.id}"] do
        let expected := if let some exactChain := (← chainsRef.get).find? (fun x => x.id == requested) then
            exactChain.targets[0]!.modelId
          else c.targets[0]!.modelId
        attempts.set #[]
        let response ← post requested
        if response.status != 200 || (← attempts.get) != #[expected] then
          failures := failures.push s!"configured alias {requested}: not resolved"
    if !failures.isEmpty then
      throw (IO.userError (String.intercalate "\n" failures.toList))
    -- Fresh stores retain all six historical stock chain ids, without guessing
    -- targets for arbitrary reviewer/scout aliases.
    let stock ← loadRoutingChainsFromStore store root
    for id in #["builtin/smart", "builtin/cheap", "builtin/fast", "builtin/assistant",
        "google-opus", "google-sonnet"] do
      check (stock.any (fun c => c.id == id)) s!"missing stock chain {id}"
  finally
    closeCoreStore store
    IO.FS.removeDirAll root

end OrbCore.ProxyRoutingTests
