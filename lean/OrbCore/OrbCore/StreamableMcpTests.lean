/-
  OrbCore.StreamableMcpTests: End-to-end tests for Milestone 2:
  1. Direct Streamable HTTP MCP JSON-RPC 2.0 endpoint (`POST/GET/DELETE /api/mcp/rpc`):
     initialize, notifications, ping, tools/list, tools/call (`get_capabilities`, `get_mission`,
     `get_budget`, `list_missions` role-gating), batch requests, error codes, and auth.
  2. Per-workspace direct HTTP MCP config generation for `opencode`, `claudecode`, `codex`,
     and `antigravity` (normal + `/goal`) without mandatory `sandboxed-mcp launch` or
     `.agents/.sandboxed-mcp.lock`, plus interrupt/restart idempotency check.
-/
import LeanSys.Http
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Control

namespace OrbCore.StreamableMcpTests

open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.Control
open OrbCore.RemoteDispatch

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw (IO.userError s!"[StreamableMcpTests] FAIL: {label}")

def run : IO Unit := do
  let nonce ← IO.monoNanosNow
  let root := s!"/tmp/orb-core-streamable-mcp-test-{nonce}"
  IO.FS.createDirAll root
  let .ok store ← openCoreStore root 0 "prod"
    | throw (IO.userError "openCoreStore failed")
  let cfg : CoreConfig := {
    devMode := false, host := "127.0.0.1", workingDir := root,
    dashboardPassword := "test-strong-passphrase-mcp-rpc",
    jwtSecret := "test-jwt-secret-mcp-rpc-0123456789abcdef",
    proxySecret := "test-proxy-secret-mcp-rpc-0123456789abcd"
  }
  let nowSec : UInt64 := 1700010000
  let .ok adminId ← bootstrapUsersAndBackfill store #[("admin", cfg.dashboardPassword)] s!"{nowSec}"
    | do closeCoreStore store; throw (IO.userError "bootstrap admin failed")
  let testMid := "11111111-2222-4333-8444-555555555555"
  let .ok () ← upsertMission store {
    id := testMid, title := "Streamable MCP Smoke", status := "active", backend := "antigravity",
    modelOverride := "", workingDirectory := root, updatedAt := "2026-11-27T00:00:00Z", ownerUserId := adminId
  } | do closeCoreStore store; throw (IO.userError "upsertMission failed")

  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true } : OrbCore.Managed.ManagedFleetState)
  let chainsRef ← IO.mkRef #[]
  let proxyCooldownsRef ← IO.mkRef #[]
  let seqRef ← IO.mkRef (1 : UInt64)
  let appSt : CoreAppState := {
    bootstrapAdminId := adminId,
    cfg := cfg, store := store, searchIdx? := none, managedRef := managedRef, chainsRef := chainsRef,
    proxyCooldownsRef := proxyCooldownsRef, seqRef := seqRef
  }
  let adminJwt := mintSessionTokenV2 cfg.jwtSecret adminId "admin" 1 (nowSec + 3600)

  let sup : RemoteJobSupervisor ← OrbCore.RemoteDispatch.newRemoteJobSupervisor cfg.jwtSecret false
  let mcpEnvs ← mintMissionScopedMcpEnv store sup testMid adminId "" "https://orbcore.thomas.md" false nowSec
  let scopedTok := (mcpEnvs.find? (fun (k, _) => k == "SANDBOXED_MCP_TOKEN")).map Prod.snd |>.getD ""
  assertTrue "minted scoped mcp1.* token" (scopedTok.startsWith "mcp1.")

  try
    let dispatch := fun (method path : String) (hdrs : Array (String × String)) (body : String) => do
      let hdrLines := hdrs.foldl (fun acc (k, v) => acc ++ s!"{k}: {v}\r\n") ""
      let wire := s!"{method} {path} HTTP/1.1\r\nHost: localhost\r\n{hdrLines}Content-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := LeanSys.Http.parseRequest wire.toUTF8 none
        | throw (IO.userError "parseRequest failed")
      match ← dispatchCoreRequest appSt req nowSec with
      | .ok r => pure r
      | .error e => throw (IO.userError s!"dispatch error: {e}")

    let execHdrs := #[("Authorization", s!"Bearer {scopedTok}"), ("Content-Type", "application/json")]
    let opHdrs := #[("Authorization", s!"Bearer {adminJwt}"), ("Content-Type", "application/json")]

    -- 1. Auth & HTTP method semantics
    let r401 ← dispatch "POST" "/api/mcp/rpc" #[] "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
    assertTrue "unauthenticated /api/mcp/rpc returns 401" (r401.status == 401)
    let rGet ← dispatch "GET" "/api/mcp/rpc" execHdrs ""
    assertTrue "GET /api/mcp/rpc returns 405 Method Not Allowed" (rGet.status == 405)
    let rDel ← dispatch "DELETE" "/api/mcp/rpc" execHdrs ""
    assertTrue "DELETE /api/mcp/rpc returns 204" (rDel.status == 204)

    -- 2. initialize + notification + ping
    let rInit ← dispatch "POST" "/api/mcp/rpc" execHdrs
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}"
    assertTrue "initialize returns 200 with Mcp-Session-Id header"
      (rInit.status == 200 && rInit.extraHdrs.any (fun (k, v) => k.toLower == "mcp-session-id" && !v.isEmpty))
    let .ok initJv := OrbBin.Json.parseBytes rInit.body | throw (IO.userError "init JSON parse")
    assertTrue "initialize negotiates protocolVersion and serverInfo"
      ((initJv.field? "result").bind (·.fieldStr? "protocolVersion") == some "2025-03-26" &&
       ((initJv.field? "result").bind (·.field? "serverInfo")).bind (·.fieldStr? "name") == some "sandboxed")

    let rNotif ← dispatch "POST" "/api/mcp/rpc" execHdrs
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
    assertTrue "notification returns 202 with empty body" (rNotif.status == 202 && rNotif.body.isEmpty)

    let rPing ← dispatch "POST" "/api/mcp/rpc" execHdrs
      "{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"ping\"}"
    let .ok pingJv := OrbBin.Json.parseBytes rPing.body | throw (IO.userError "ping JSON parse")
    assertTrue "ping returns JSON-RPC 2.0 success" (rPing.status == 200 && (pingJv.field? "result").isSome)

    -- 3. tools/list
    let rList ← dispatch "POST" "/api/mcp/rpc" execHdrs
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
    let .ok listJv := OrbBin.Json.parseBytes rList.body | throw (IO.userError "tools/list JSON parse")
    let toolsArr := ((listJv.field? "result").bind (·.fieldArr? "tools")).getD #[]
    assertTrue "tools/list exposes get_capabilities, get_mission, get_budget"
      (toolsArr.any (fun t => t.fieldStr? "name" == some "get_capabilities") &&
       toolsArr.any (fun t => t.fieldStr? "name" == some "get_mission") &&
       toolsArr.any (fun t => t.fieldStr? "name" == some "get_budget"))

    -- 4. tools/call: get_capabilities, get_mission, get_budget, and role-gated list_missions
    let callRpc := fun (hdrs : Array (String × String)) (idNum : Nat) (name : String) (args : JVal) => do
      let reqBody := renderCompact (.obj #[
        ("jsonrpc", .str "2.0"),
        ("id", .nat idNum),
        ("method", .str "tools/call"),
        ("params", .obj #[("name", .str name), ("arguments", args)])
      ])
      let r ← dispatch "POST" "/api/mcp/rpc" hdrs reqBody
      let .ok jv := OrbBin.Json.parseBytes r.body | throw (IO.userError s!"parse {name}")
      return (r.status, jv.fieldOrNull "result")

    let (stCaps, resCaps) ← callRpc execHdrs 3 "get_capabilities" (.obj #[])
    assertTrue "tools/call get_capabilities succeeds with executor identity"
      (stCaps == 200 && resCaps.fieldBool? "isError" == some false &&
       ((resCaps.field? "structuredContent").bind (·.field? "identity")).bind (·.fieldStr? "mission_id") == some testMid)

    let (stMis, resMis) ← callRpc execHdrs 4 "get_mission" (.obj #[("mission_id", .str testMid)])
    assertTrue "tools/call get_mission returns self mission without error"
      (stMis == 200 && resMis.fieldBool? "isError" == some false &&
       (resMis.field? "structuredContent").bind (·.fieldStr? "id") == some testMid)

    let (stBud, resBud) ← callRpc execHdrs 5 "get_budget" (.obj #[("mission_id", .str testMid)])
    assertTrue "tools/call get_budget returns budget payload without error"
      (stBud == 200 && resBud.fieldBool? "isError" == some false &&
       (resBud.field? "structuredContent").isSome)

    let (stForb, resForb) ← callRpc execHdrs 6 "list_missions" (.obj #[])
    assertTrue "executor tools/call list_missions is role-denied with isError=true"
      (stForb == 200 && resForb.fieldBool? "isError" == some true)

    let (stOpList, resOpList) ← callRpc opHdrs 7 "list_missions" (.obj #[])
    assertTrue "operator tools/call list_missions succeeds"
      (stOpList == 200 && resOpList.fieldBool? "isError" == some false)

    -- 5. Batch + error handling
    let rBatch ← dispatch "POST" "/api/mcp/rpc" execHdrs
      "[{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"ping\"},{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"},{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"unknown/method\"}]"
    let .ok (.arr batchRes) := OrbBin.Json.parseBytes rBatch.body | throw (IO.userError "batch JSON parse")
    assertTrue "JSON-RPC batch skips notifications and returns -32601 for unknown method"
      (rBatch.status == 200 && batchRes.size == 2 &&
       (batchRes[1]!.field? "error").bind (·.fieldInt? "code") == some (-32601))

    let rBad ← dispatch "POST" "/api/mcp/rpc" execHdrs "{not json"
    assertTrue "malformed JSON returns 400 with -32700" (rBad.status == 400)

    -- 6. Direct HTTP MCP per-workspace config generation for all 4 harnesses (no sandboxed-mcp launch!)
    setenvVar "SANDBOXED_PUBLIC_URL" "https://orbcore.thomas.md"
    try
      let mkSpec (backend : String) (goal : Bool := false) : RemoteTurnSpec := {
        missionId := testMid, targetNodeId := "uruk", backend := backend,
        modelOverride := if backend == "opencode" then "openai/gpt-5.4" else "",
        ownerUserId := adminId, prompt := "hello",
        goalDispatch? := if goal then some ("", 0) else none
      }
      -- OpenCode
      let .ok ocPrep ← prepareRemoteHarnessCommand store none none sup root "uruk" "j-oc" (mkSpec "opencode") nowSec
        | throw (IO.userError "prepare opencode failed")
      let ocCfgStr := (ocPrep.envPairs.find? (fun (k, _) => k == "OPENCODE_CONFIG_CONTENT")).map Prod.snd |>.getD ""
      let .ok ocCfgJv := OrbBin.Json.parse ocCfgStr | throw (IO.userError "parse OPENCODE_CONFIG_CONTENT")
      let ocMcp := (ocCfgJv.field? "mcp").bind (·.field? "sandboxed")
      assertTrue "opencode uses direct HTTP MCP in OPENCODE_CONFIG_CONTENT without sandboxed-mcp launch"
        ((ocPrep.command.splitOn "sandboxed-mcp launch").length == 1 &&
         ocMcp.bind (·.fieldStr? "type") == some "remote" &&
         ocMcp.bind (·.fieldStr? "url") == some "https://orbcore.thomas.md/api/mcp/rpc" &&
         (ocMcp.bind (·.field? "headers")).bind (·.fieldStr? "Authorization") == some "Bearer {env:SANDBOXED_MCP_TOKEN}")

      -- Claude Code
      let .ok clPrep ← prepareRemoteHarnessCommand store none none sup root "uruk" "j-cl" (mkSpec "claudecode") nowSec
        | throw (IO.userError "prepare claudecode failed")
      assertTrue "claudecode uses --mcp-config HTTP file without sandboxed-mcp launch or token in argv"
        ((clPrep.command.splitOn "sandboxed-mcp launch").length == 1 &&
         (clPrep.command.splitOn "https://orbcore.thomas.md/api/mcp/rpc").length > 1 &&
         (clPrep.command.splitOn "--mcp-config").length > 1 &&
         (clPrep.command.splitOn "mcp1.").length == 1)

      -- Codex
      let .ok cxPrep ← prepareRemoteHarnessCommand store none none sup root "uruk" "j-cx" (mkSpec "codex") nowSec
        | throw (IO.userError "prepare codex failed")
      assertTrue "codex uses direct HTTP MCP -c overrides with bearer_token_env_var without sandboxed-mcp launch"
        ((cxPrep.command.splitOn "sandboxed-mcp launch").length == 1 &&
         (cxPrep.command.splitOn "mcp_servers.sandboxed.url=\"https://orbcore.thomas.md/api/mcp/rpc\"").length > 1 &&
         (cxPrep.command.splitOn "mcp_servers.sandboxed.bearer_token_env_var=\"SANDBOXED_MCP_TOKEN\"").length > 1 &&
         (cxPrep.command.splitOn "mcp1.").length == 1)

      -- Antigravity (normal + /goal): executes prelude twice to prove interrupt=true leaves zero lock failures!
      let .ok agPrep ← prepareRemoteHarnessCommand store none none sup root "uruk" "j-ag" (mkSpec "antigravity" false) nowSec
        | throw (IO.userError "prepare antigravity failed")
      let .ok agGoalPrep ← prepareRemoteHarnessCommand store none none sup root "uruk" "j-ag-g" (mkSpec "antigravity" true) nowSec
        | throw (IO.userError "prepare antigravity goal failed")
      assertTrue "antigravity normal and /goal use direct HTTP MCP without sandboxed-mcp launch or .sandboxed-mcp.lock"
        ((agPrep.command.splitOn "sandboxed-mcp launch").length == 1 &&
         (agGoalPrep.command.splitOn "sandboxed-mcp launch").length == 1 &&
         (agPrep.command.splitOn ".sandboxed-mcp.lock").length == 1 &&
         (agPrep.command.splitOn "https://orbcore.thomas.md/api/mcp/rpc").length > 1)

      let fakeHome := s!"{root}/ag-home"
      IO.FS.createDirAll fakeHome
      let prelude := buildAntigravityHttpMcpPrelude "https://orbcore.thomas.md/api/mcp/rpc"
      for tok in #["mcp1.first.turn.sig", "mcp1.second.after.interrupt"] do
        let out ← IO.Process.output {
          cmd := "sh"
          args := #["-c", prelude ++ "true"]
          env := #[("HOME", some fakeHome), ("SANDBOXED_MCP_TOKEN", some tok)]
        }
        assertTrue "antigravity HTTP MCP prelude succeeds repeatedly without lock contention" (out.exitCode == 0)
      let cfgRaw ← IO.FS.readFile s!"{fakeHome}/.gemini/config/mcp_config.json"
      let .ok cfgJv := OrbBin.Json.parse cfgRaw | throw (IO.userError "parse agy mcp_config.json")
      let sbEntry := (cfgJv.field? "mcpServers").bind (·.field? "sandboxed")
      let lockExists ← (System.FilePath.mk s!"{fakeHome}/.agents/.sandboxed-mcp.lock").pathExists
      assertTrue "agy mcp_config.json has serverUrl + updated Bearer token and zero .sandboxed-mcp.lock"
        (sbEntry.bind (·.fieldStr? "serverUrl") == some "https://orbcore.thomas.md/api/mcp/rpc" &&
         (sbEntry.bind (·.field? "headers")).bind (·.fieldStr? "Authorization") == some "Bearer mcp1.second.after.interrupt" &&
         !lockExists)

      -- Pi harness: direct Streamable HTTP MCP via SANDBOXED_MCP_URL + full-catalog models.json + zero tokens in argv + 0700/0600 staging
      let .ok piPrep ← prepareRemoteHarnessCommand store none none sup root "uruk" "j-pi" (mkSpec "pi") nowSec
        | throw (IO.userError "prepare pi failed")
      let piMcpUrl := (piPrep.envPairs.find? (fun (k, _) => k == "SANDBOXED_MCP_URL")).map Prod.snd |>.getD ""
      let piModelsB64 := (piPrep.envPairs.find? (fun (k, _) => k == "ORB_PI_MODELS_JSON_B64")).map Prod.snd |>.getD ""
      let piExtB64 := (piPrep.envPairs.find? (fun (k, _) => k == "ORB_PI_EXT_B64")).map Prod.snd |>.getD ""
      assertTrue "pi uses sandboxed-node pi-rpc, SANDBOXED_MCP_URL, full models.json, 0700/0600 staging, and zero tokens in argv"
        ((piPrep.command.splitOn "sandboxed-node pi-rpc").length > 1 &&
         (piPrep.command.splitOn "chmod 700").length > 1 &&
         (piPrep.command.splitOn "chmod 600").length > 1 &&
         (piPrep.command.splitOn "mcp1.").length == 1 &&
         (piPrep.command.splitOn "orb-mpt-v1_").length == 1 &&
         piMcpUrl == "https://orbcore.thomas.md/api/mcp/rpc" &&
         !piModelsB64.isEmpty && !piExtB64.isEmpty &&
         OrbCore.Skills.nativeDirectory "pi" == ".pi/skills")
      let piModelsJson := remotePiModelsJson "https://orbcore.thomas.md" #[("custom/model-x", "Custom — Model X")]
      let .ok piModelsJv := OrbBin.Json.parse piModelsJson | throw (IO.userError "parse remotePiModelsJson")
      let orbProv := (piModelsJv.fieldOrNull "providers").fieldOrNull "orb"
      let orbModels := (orbProv.fieldArr? "models").getD #[]
      assertTrue "remotePiModelsJson registers env-var apiKey and full routable catalog for mid-session set_model"
        (orbProv.fieldStr? "apiKey" == some "SANDBOXED_PROXY_API_KEY" &&
         orbProv.fieldStr? "baseUrl" == some "https://orbcore.thomas.md/v1" &&
         orbModels.any (fun m => m.fieldStr? "id" == some "builtin/smart") &&
         orbModels.any (fun m => m.fieldStr? "id" == some "anthropic/claude-opus-5-5") &&
         orbModels.any (fun m => m.fieldStr? "id" == some "custom/model-x"))
    finally
      unsetenvVar "SANDBOXED_PUBLIC_URL"
  finally
    closeCoreStore store
    discard <| (IO.Process.output { cmd := "rm", args := #["-rf", root] }).toBaseIO

end OrbCore.StreamableMcpTests
