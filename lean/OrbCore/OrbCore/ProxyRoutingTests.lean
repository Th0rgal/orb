/-
  Rust proxy model admission regressions. No vendor calls: all transport is mocked.
  Saved aliases are test-only configurations, not guessed production definitions.
-/
import OrbCore.Control

namespace OrbCore.ProxyRoutingTests
open LeanSys.Http OrbBin.Json OrbBin.PosixExt OrbBin.Sqlite
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
  let fixtureRaw ← IO.FS.readFile "shared/orb-spec/fixtures/proxy-model-aliases.json"
  let .ok fixture := OrbBin.Json.parse fixtureRaw
    | throw (IO.userError "proxy alias reference fixture failed to parse")
  for pair in (fixture.fieldArr? "provider_prefixes").getD #[] do
    let values := pair.asArr?.getD #[]
    let providerPrefix := (values[0]?.bind JVal.asStr?).getD ""
    let provider := (values[1]?.bind JVal.asStr?).getD ""
    check (OrbCore.ProxyModelRouting.directEntry? s!"{providerPrefix}/org/model-x" "/v1/chat/completions" ==
      some (provider, "org/model-x")) s!"direct prefix {providerPrefix}"
  for c in (fixture.fieldArr? "bare_cases").getD #[] do
    let model := (c.fieldStr? "model").getD ""
    let path := (c.fieldStr? "path").getD ""
    let expected := c.fieldOrNull "expected"
    let actual := OrbCore.ProxyModelRouting.directEntry? model path
    if expected.isNull then check actual.isNone s!"unexpected bare model {model}"
    else
      let pair := expected.asArr?.getD #[]
      check (actual == some ((pair[0]?.bind JVal.asStr?).getD "", (pair[1]?.bind JVal.asStr?).getD "")) s!"bare model {model}"
  for c in (fixture.fieldArr? "stock_entries").getD #[] do
    let id := (c.fieldStr? "id").getD ""
    let some (_, _, entries) := OrbCore.ProxyModelRouting.stockChains.find? (fun (i, _, _) => i == id)
      | throw (IO.userError s!"missing stock reference {id}")
    let encoded := JVal.arr (entries.map (fun (p, m) => .arr #[.str p, .str m]))
    check (encoded == c.fieldOrNull "entries") s!"stock target order {id}"
  for (alias, expected) in #[
      ("fable-5.2", some "anthropic/claude-fable-5-2"), ("opus-5.5", some "anthropic/claude-opus-5-5"),
      ("claude-fable-5-2", some "anthropic/claude-fable-5-2"), ("gpt-6-astra", some "openai/gpt-6-astra"),
      ("anthropic/claude-fable-5-2", some "anthropic/claude-fable-5-2"),
      ("github-copilot/claude-fable-5.2", some "github-copilot/claude-fable-5.2"),
      ("builtin/smart", some "builtin/smart"), ("no-such-family", none), ("nowhere/model", none), ("", none)] do
    check (OrbCore.ProxyModelRouting.consultModel? alias == expected) s!"consult alias {alias}"
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
      dashboardPassword := "proxy-routing-fixture-password"
      proxySecret := "proxy-routing-fixture-secret-0123456789"
      jwtSecret := "proxy-routing-fixture-jwt-secret-0123456789"
    }
    let app : CoreAppState := {
      cfg, store, searchIdx? := none, managedRef, chainsRef,
      proxyCooldownsRef := cooldowns, seqRef,
      proxyMockTransport? := some (fun target => do
        attempts.modify (·.push target.modelId)
        if target.modelId.startsWith "claude-" then
          return .ok {
            status := 503
            headers := #[("content-type", "application/json")]
            body := "{\"error\":{\"type\":\"auth_unavailable\",\"message\":\"no auth available\"}}".toUTF8
          }
        return .ok {
          status := 200
          headers := #[("content-type", "application/json")]
          body := "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"fixture output\"},\"finish_reason\":\"stop\"}]}".toUTF8
        })
    }
    let postAt := fun (path model : String) => do
      let body := renderCompact (.obj #[("model", .str model), ("messages", .arr #[])])
      let raw := s!"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {cfg.proxySecret}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none
        | throw (IO.userError "proxy routing fixture request parse failed")
      let .ok response ← dispatchCoreRequest app req 1700001000
        | throw (IO.userError "unexpected proxy routing websocket upgrade")
      return response
    let post := postAt "/v1/chat/completions"
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
    -- No silent substitution: a model owned by a provider whose login is dead
    -- surfaces that provider's error. It never reaches the smart chain's model.
    let .ok () ← upsertAIProvider store { id := "anth-fixture", providerType := "anthropic", name := "Anthropic fixture", apiKey := "fixture-only" }
      | throw (IO.userError "anthropic fixture provider failed")
    for (path, model, bare) in #[
        ("/v1/messages", "claude-fable-5-2", "claude-fable-5-2"),
        ("/v1/messages", "claude-sonnet-5-5", "claude-sonnet-5-5"),
        ("/v1/chat/completions", "claude-fable-5-2", "claude-fable-5-2"),
        ("/v1/chat/completions", "anthropic/claude-fable-5-2", "claude-fable-5-2")] do
      attempts.set #[]
      let response ← postAt path model
      let text := (String.fromUTF8? response.body).getD ""
      let hdr := fun (k : String) => ((response.extraHdrs.find? (fun h => h.1 == k)).map (·.2)).getD ""
      check (response.status == 503 && (text.splitOn "auth_unavailable").length == 2)
        s!"{model} on {path}: upstream error must be relayed, got {response.status} {text}"
      check ((← attempts.get) == #[bare]) s!"{model} on {path}: served by another model {← attempts.get}"
      check (hdr "X-Orb-Requested-Model" == model && hdr "X-Orb-Effective-Model" == bare && hdr "X-Orb-Route" == "direct")
        s!"{model}: requested/effective headers"
    let .ok recorded ← execParamQuery store.missionsDb
        "SELECT COUNT(*), COALESCE(SUM(CASE WHEN model IN ('claude-fable-5-2','claude-sonnet-5-5') THEN 1 ELSE 0 END),0) FROM proxy_outcomes WHERE chain_id='direct';" #[]
      | throw (IO.userError "proxy_outcomes query failed")
    check (recorded[1]? == some #["4", "4"]) s!"direct outcomes must record the unchanged effective model: {recorded}"
    let .ok chainRows ← execParamQuery store.missionsDb
        "SELECT COUNT(*) FROM proxy_outcomes WHERE requested_model='reviewer' AND chain_id='reviewer' AND model='review-model' AND status='ok';" #[]
      | throw (IO.userError "proxy_outcomes chain query failed")
    check ((((chainRows[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 0) "chain alias outcome records requested and effective model"
    -- Fallback Chains contract: every row decodes as the clients' `ModelChain`.
    let jwt := mintSessionToken cfg.jwtSecret (1700001000 + 3600)
    let api := fun (method path body : String) => do
      let raw := s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none
        | throw (IO.userError "chain contract request parse failed")
      let .ok response ← dispatchCoreRequest app req 1700001000
        | throw (IO.userError "chain contract unexpected upgrade")
      return (response.status, (OrbBin.Json.parseBytes response.body).toOption.getD .null)
    let .ok contract := OrbBin.Json.parse (← IO.FS.readFile "shared/orb-spec/fixtures/model-chains-response.json")
      | throw (IO.userError "model-chains-response fixture failed to parse")
    let typeOf := fun (v : JVal) => match v with
      | .str _ => "string" | .bool _ => "boolean" | .arr _ => "array" | .num _ => "number" | .obj _ => "object" | .null => "null"
    let conforms := fun (row : JVal) =>
      ((contract.fieldOrNull "required").asObj?.getD #[]).all (fun (k, t) => (row.field? k).map typeOf == t.asStr?) &&
      ((row.fieldArr? "entries").getD #[]).all (fun e =>
        ((contract.fieldOrNull "entry_required").asObj?.getD #[]).all (fun (k, t) => (e.field? k).map typeOf == t.asStr?)) &&
      ((contract.fieldArr? "forbidden").getD #[]).all (fun k => !((renderCompact row).splitOn s!"\"{k.asStr?.getD "?"}\"").length > 1)
    let (createSt, created) ← api "POST" "/api/model-routing/chains"
      "{\"id\":\"contract\",\"name\":\"Contract\",\"entries\":[{\"provider_id\":\"zai\",\"model_id\":\"glm-5.3\",\"api_key\":\"sk-inline-secret\"}]}"
    check (createSt == 201 && conforms created) s!"create returns the chain row: {createSt} {renderCompact created}"
    let (listSt, listed) ← api "GET" "/api/model-routing/chains" ""
    let rows := listed.asArr?.getD #[]
    check (listSt == 200 && rows.size ≥ 7 && rows.all conforms) s!"chain list rows must match the client type: {renderCompact listed}"
    check ((rows.filter (fun r => r.fieldBool? "is_default" == some true)).map (·.fieldStr? "id") == #[some "builtin/smart"])
      "exactly the stock default chain is default before anyone chooses one"
    -- The desktop's "set default" sends only `is_default`; entries and name survive.
    let (putSt, updated) ← api "PUT" "/api/model-routing/chains/contract" "{\"is_default\":true}"
    check (putSt == 200 && conforms updated && updated.fieldBool? "is_default" == some true &&
      updated.fieldStr? "name" == some "Contract" && ((updated.fieldArr? "entries").getD #[]).size == 1)
      s!"partial update must keep entries and name: {putSt} {renderCompact updated}"
    let (_, relisted) ← api "GET" "/api/model-routing/chains" ""
    check (((relisted.asArr?.getD #[]).filter (fun r => r.fieldBool? "is_default" == some true)).map (·.fieldStr? "id") == #[some "contract"])
      "setting a default leaves exactly one default chain"
    let (getSt, got) ← api "GET" "/api/model-routing/chains/contract" ""
    let (missSt, _) ← api "GET" "/api/model-routing/chains/absent-chain" ""
    let (delBuiltinSt, _) ← api "DELETE" "/api/model-routing/chains/builtin/smart" ""
    let (delSt, _) ← api "DELETE" "/api/model-routing/chains/contract" ""
    let (delAgainSt, _) ← api "DELETE" "/api/model-routing/chains/contract" ""
    let (emptySt, _) ← api "POST" "/api/model-routing/chains" "{\"id\":\"empty\",\"entries\":[]}"
    let (unknownSt, _) ← api "GET" "/api/model-routing/no-such-route" ""
    check (getSt == 200 && conforms got && missSt == 404 && delBuiltinSt != 200 && delSt == 200 && delAgainSt == 404 &&
      emptySt == 400 && unknownSt == 404)
      s!"chain get/delete/create must not fabricate success: get={getSt} miss={missSt} builtin={delBuiltinSt} del={delSt} again={delAgainSt} empty={emptySt} unknown={unknownSt}"
    -- A client can only echo provider + model: saving must not erase a stored inline
    -- setting for an entry it kept, and must drop the entries it removed.
    check (OrbCore.ProxyModelRouting.keepStoredEntrySettings
        "[{\"provider_id\":\"b\",\"model_id\":\"m2\"},{\"provider_id\":\"a\",\"model_id\":\"m1\"}]"
        "[{\"provider_id\":\"a\",\"model_id\":\"m1\",\"base_url\":\"http://h\"},{\"provider_id\":\"c\",\"model_id\":\"m3\"}]"
      == "[{\"provider_id\":\"b\",\"model_id\":\"m2\"},{\"provider_id\":\"a\",\"model_id\":\"m1\",\"base_url\":\"http://h\"}]")
      "saving a chain keeps stored entry settings"
    check (OrbCore.ProxyModelRouting.directEntry? "my_spark_42/org/model-x" "/v1/chat/completions"
      #[("my_spark_42", "org/model-x")] == some ("my_spark_42", "org/model-x")) "advertised custom namespace"
    check ((OrbCore.ProxyModelRouting.directEntry? "my_spark_42/typo" "/v1/chat/completions"
      #[("my_spark_42", "org/model-x")]).isNone) "unadvertised custom model"
    -- Fresh stores retain all six historical stock chain ids, without guessing
    -- targets for arbitrary reviewer/scout aliases.
    let stock ← loadRoutingChainsFromStore store root
    for id in #["builtin/smart", "builtin/cheap", "builtin/fast", "builtin/assistant",
        "google-opus", "google-sonnet"] do
      check (stock.any (fun c => c.id == id)) s!"missing stock chain {id}"
    chainsRef.set stock
    -- A chain saved behind the running snapshot (import, another process) is found
    -- in the store before its name is refused.
    let .ok _ ← execParamQuery store.missionsDb
        "INSERT INTO model_routing_chains(id,name,models_json,updated_at) VALUES('late-reviewer','Late','[{\"provider_id\":\"zai\",\"model_id\":\"glm-5.3\"}]','t0');" #[]
      | throw (IO.userError "late chain insert failed")
    attempts.set #[]
    let late ← post "late-reviewer"
    check (late.status == 200 && !(← attempts.get).isEmpty) s!"a chain saved behind the snapshot is served, got {late.status}"
    for c in stock do
      let bare := if c.id.startsWith "builtin/" then (c.id.drop 8).toString else c.id
      for alias in #[c.id, bare, s!"builtin/{bare}"] do
        attempts.set #[]
        let response ← post alias
        check (response.status == 200 && !(← attempts.get).isEmpty) s!"stock alias {alias}"
  finally
    closeCoreStore store
    IO.FS.removeDirAll root

end OrbCore.ProxyRoutingTests
