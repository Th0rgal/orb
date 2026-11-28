import OrbCore.Control
import OrbCore.ApprovalSignatureTests

namespace OrbCore.R17Tests

open LeanSys.Http OrbBin.Json OrbBin.PosixExt
open OrbCore.Store OrbCore.Control OrbCore.Managed OrbCore.Proxy OrbCore.R7Core
open OrbCore.MemoryAndCloud OrbCore.LegacyHydrate

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"R17: {label}")
  IO.println s!"PASS {label}"

private def readBrokerJson (dataRoot : String) : IO JVal := do
  let p := s!"{dataRoot}/secret_broker.json"
  if let .ok raw ← (IO.FS.readFile p).toBaseIO then
    return (OrbBin.Json.parse raw).toOption.getD (.obj #[])
  return .obj #[]

private def writeBrokerJson (dataRoot : String) (v : JVal) : IO Unit := do
  IO.FS.createDirAll dataRoot
  IO.FS.writeFile s!"{dataRoot}/secret_broker.json" (renderCompact v)

private def runExtendedChecks
    (root : String) (store : CoreStore) (cfg : CoreConfig) (app : CoreAppState)
    (now : UInt64) (jwt : String) (operator : McpSessionClaims) (cap : JVal) : IO Unit := do
  let sql (q : String) (params : Array String := #[]) := do
    let .ok rows ← execParamQuery store.projectsDb q params
      | throw (IO.userError "R17 fixture query failed")
    return rows
  let msql (q : String) (params : Array String := #[]) := do
    let .ok rows ← execParamQuery store.missionsDb q params
      | throw (IO.userError "R17 missions fixture query failed")
    return rows
  let call (c : McpSessionClaims) (tool : String) (args : JVal) := do
    let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root c tool args now
    let .ok value := OrbBin.Json.parse raw | throw (IO.userError "R17 MCP JSON")
    return value
  let restAs (tok method path body : String) := do
    let raw := s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {tok}\r\nContent-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
    let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "R17 REST parse")
    let .ok response ← dispatchCoreRequest app req now | throw (IO.userError "R17 REST dispatch")
    return (response.status, (String.fromUTF8? response.body).getD "")
  let rest := restAs jwt
  let insertAction (aid state resultJson : String) := do
    discard <| sql
      ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
       "VALUES(?1,'','r17-op::test_tool',?2,'{}','operator::','test_tool','{}',?3,?4,'2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
      #[aid, "rk-" ++ aid, state, resultJson]

  -- HTTP-04: backup/restore explicit unsupported (GET/POST backup + POST restore + non-admin 403)
  let (backupGetSt, backupGetBody) ← rest "GET" "/api/settings/backup" ""
  check (backupGetSt == 501 && backupGetBody.contains "unsupported")
    "HTTP-04 GET /api/settings/backup is explicit unsupported"
  let (restoreSt, restoreBody) ← rest "POST" "/api/settings/restore" "{\"data\":\"bogus\"}"
  check (restoreSt == 501 && restoreBody.contains "unsupported")
    "HTTP-04 POST /api/settings/restore is explicit unsupported"
  discard <| msql
    "INSERT INTO users(id,username,password_hash,role) VALUES('r17-member','r17member','synthetic-hash','member');"
  let memberJwt := mintSessionTokenV2 cfg.jwtSecret "r17-member" "member" 1 (now + 3600)
  let (memberBackupSt, _) ← restAs memberJwt "POST" "/api/settings/backup" ""
  check (memberBackupSt == 403) "HTTP-04 non-admin backup is refused with 403"

  -- HTTP-05: software updates/cancel explicit unsupported (never fabricated 202 succeeded job)
  let (swUpdSt, swUpdBody) ← rest "POST" "/api/software/updates" "{\"component\":\"opencode\"}"
  check (swUpdSt == 501 && swUpdBody.contains "unsupported")
    "HTTP-05 POST /api/software/updates is explicit unsupported"
  let (swCanSt, swCanBody) ← rest "POST" "/api/software/updates/cancel" "{\"id\":\"fake-job\"}"
  check (swCanSt == 501 && swCanBody.contains "unsupported")
    "HTTP-05 POST /api/software/updates/cancel is explicit unsupported"

  -- HTTP-13: capabilities report observed state with detail/remedy (never bogus optimistic flags)
  let capsObj := cap.fieldOrNull "capabilities"
  let ghPush := capsObj.fieldOrNull "github_push"
  let ghLogin := capsObj.fieldOrNull "dashboard_github_login"
  check (ghPush.fieldBool? "available" == some false &&
    (ghPush.fieldStr? "remedy").isSome &&
    ghLogin.fieldBool? "available" == some false &&
    (cap.field? "mission_moves").isNone &&
    (cap.field? "mcp_gateway").isNone)
    "HTTP-13 GET /api/capabilities reports unconfigured GitHub with remedy and omits bogus flags"
  let appWithGh : CoreAppState := { app with cfg := { cfg with githubClientId := "gh-client-r17" } }
  let rawGhCap := s!"GET /api/capabilities HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: 0\r\n\r\n"
  let .ok reqGhCap := parseRequest rawGhCap.toUTF8 none | throw (IO.userError "R17 gh cap parse")
  let .ok respGhCap ← dispatchCoreRequest appWithGh reqGhCap now | throw (IO.userError "R17 gh cap dispatch")
  let .ok ghCapJv := OrbBin.Json.parse ((String.fromUTF8? respGhCap.body).getD "") | throw (IO.userError "R17 gh cap JSON")
  check ((((ghCapJv.fieldOrNull "capabilities").fieldOrNull "github_push").fieldBool? "available") == some true &&
    ((((ghCapJv.fieldOrNull "capabilities").fieldOrNull "dashboard_github_login").fieldBool? "available") == some true))
    "HTTP-13 GET /api/capabilities reflects configured GitHub state"

  -- HTTP-15: GET /api/backends reports Vibe native_plan=true alongside claudecode/codex/antigravity
  let (backendsSt, backendsBody) ← rest "GET" "/api/backends" ""
  let .ok (.arr backendsArr) := OrbBin.Json.parse backendsBody | throw (IO.userError "R17 backends JSON")
  let backendNativePlan (id : String) : Option Bool :=
    (backendsArr.find? (fun b => b.fieldStr? "id" == some id)).bind (·.fieldBool? "native_plan")
  check (backendsSt == 200 &&
    backendNativePlan "vibe" == some true &&
    backendNativePlan "claudecode" == some true &&
    backendNativePlan "codex" == some true &&
    backendNativePlan "antigravity" == some true &&
    backendNativePlan "grok" == some false &&
    backendNativePlan "opencode" == some false)
    "HTTP-15 GET /api/backends reports Vibe native_plan=true and exact capability matrix"

  -- HTTP-16: legacy /api/secrets/status reports unsupported+locked; lock/unlock/initialize return 501
  let (secStatSt, secStatBody) ← rest "GET" "/api/secrets/status" ""
  let .ok secStatJv := OrbBin.Json.parse secStatBody | throw (IO.userError "R17 secrets status JSON")
  check (secStatSt == 200 &&
    secStatJv.fieldBool? "supported" == some false &&
    secStatJv.fieldBool? "unlocked" == some false)
    "HTTP-16 GET /api/secrets/status reports supported=false and unlocked=false"
  for action in #["initialize", "unlock", "lock"] do
    let (st, bd) ← rest "POST" s!"/api/secrets/{action}" "{\"passphrase\":\"wrong\"}"
    check (st == 501 && bd.contains "unsupported")
      s!"HTTP-16 POST /api/secrets/{action} returns 501 unsupported"

  -- MCP-02 extra: wait_actions catalog discovery, not_found in mixed wait, atomic cancel_action
  for role in #["executor", "coordinator", "operator"] do
    let some rawCat := OrbBin.McpCatalog.catalogPrettyJsonForRole role
      | throw (IO.userError s!"R17 missing catalog for {role}")
    let .ok (.arr catTools) := OrbBin.Json.parse rawCat
      | throw (IO.userError s!"R17 invalid catalog JSON for {role}")
    check (catTools.any (fun t => t.fieldStr? "name" == some "wait_actions"))
      s!"MCP-02 {role} catalog advertises wait_actions"
  let waitMixedNotFound ← call operator "wait_actions" (.obj #[
    ("action_ids", .arr #[.str "r17-act-ok", .str "r17-act-missing"]),
    ("return_when", .str "all"), ("timeout_ms", .nat 50)])
  let wmnRes := waitMixedNotFound.fieldOrNull "result"
  let wmnReceipts := (wmnRes.fieldArr? "receipts").getD #[]
  let missingRec? := wmnReceipts.find? (fun r => r.fieldStr? "action_id" == some "r17-act-missing")
  check (waitMixedNotFound.fieldBool? "ok" == some true &&
    wmnRes.fieldBool? "all_settled" == some true &&
    wmnRes.fieldBool? "all_succeeded" == some false &&
    (missingRec?.bind (·.fieldStr? "state")) == some "not_found" &&
    (missingRec?.bind (·.fieldStr? "accepted")) == some "no")
    "MCP-02 wait_actions marks unknown IDs not_found with accepted=no and all_succeeded=false"
  let cancelNoKey ← call operator "cancel_action" (.obj #[("action_id", .str "r17-act-ok")])
  check (cancelNoKey.fieldBool? "ok" == some false &&
    (cancelNoKey.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
    "MCP-02 cancel_action requires idempotency_key"
  let cancelSettled ← call operator "cancel_action" (.obj #[("action_id", .str "r17-act-ok"), ("idempotency_key", .str "r17-can-settled")])
  let csRes := cancelSettled.fieldOrNull "result"
  check (cancelSettled.fieldBool? "ok" == some true &&
    csRes.fieldBool? "cancelled" == some false &&
    csRes.fieldStr? "state" == some "succeeded" &&
    csRes.fieldStr? "accepted" == some "no")
    "MCP-02 cancel_action refuses to cancel settled receipt and reports accepted=no"
  insertAction "r17-act-queued" "queued" "{}"
  let cancelQueued ← call operator "cancel_action" (.obj #[("action_id", .str "r17-act-queued"), ("idempotency_key", .str "r17-can-q1")])
  let cqRes := cancelQueued.fieldOrNull "result"
  check (cancelQueued.fieldBool? "ok" == some true &&
    cqRes.fieldBool? "cancelled" == some true &&
    cqRes.fieldStr? "state" == some "cancelled" &&
    cqRes.fieldStr? "accepted" == some "yes")
    "MCP-02 cancel_action atomically cancels queued receipt"
  let cancelQueuedReplay ← call operator "cancel_action" (.obj #[("action_id", .str "r17-act-queued"), ("idempotency_key", .str "r17-can-q1")])
  check (cancelQueuedReplay == cancelQueued)
    "MCP-02 cancel_action replays identical receipt on retry with same idempotency_key"
  let cancelQueuedConflict ← call operator "cancel_action" (.obj #[("action_id", .str "r17-act-ok"), ("idempotency_key", .str "r17-can-q1")])
  check (cancelQueuedConflict.fieldBool? "ok" == some false &&
    (cancelQueuedConflict.fieldOrNull "error").fieldStr? "code" == some "conflict")
    "MCP-02 cancel_action rejects conflicting action_id for reused idempotency_key"
  insertAction "r17-act-accepted" "accepted" "{}"
  let cancelAccepted ← call operator "cancel_action" (.obj #[("action_id", .str "r17-act-accepted"), ("idempotency_key", .str "r17-can-acc1")])
  let caRes := cancelAccepted.fieldOrNull "result"
  check (cancelAccepted.fieldBool? "ok" == some true &&
    caRes.fieldBool? "cancelled" == some true &&
    caRes.fieldStr? "state" == some "cancelled" &&
    caRes.fieldStr? "accepted" == some "yes")
    "MCP-02 cancel_action atomically cancels accepted receipt"
  let cancelMissing ← call operator "cancel_action" (.obj #[("action_id", .str "r17-act-does-not-exist"), ("idempotency_key", .str "r17-can-miss")])
  check (cancelMissing.fieldBool? "ok" == some false &&
    (cancelMissing.fieldOrNull "error").fieldStr? "code" == some "not_found")
    "MCP-02 cancel_action returns not_found for unknown action_id"

  -- MCP-10 extra: preserve parallel_missions=0 vs null, reject invalid types, REST parity
  let grantZero ← call operator "set_project_grant" (.obj #[
    ("slug", .str "r17-project"), ("parallel_missions", .nat 0), ("idempotency_key", .str "r17-grant-zero")])
  check (grantZero.fieldBool? "ok" == some true &&
    (grantZero.fieldOrNull "result").fieldNat? "parallel_missions" == some 0)
    "MCP-10 set_project_grant preserves explicit parallel_missions=0"
  let grantNullPar ← call operator "set_project_grant" (.obj #[
    ("slug", .str "r17-project"), ("parallel_missions", .null), ("idempotency_key", .str "r17-grant-nullpar")])
  check (grantNullPar.fieldBool? "ok" == some true &&
    (grantNullPar.fieldOrNull "result").fieldOrNull "parallel_missions" == .null)
    "MCP-10 set_project_grant clears parallel_missions to null"
  let grantBadType ← call operator "set_project_grant" (.obj #[
    ("slug", .str "r17-project"), ("parallel_missions", .str "many"), ("idempotency_key", .str "r17-grant-badpar")])
  check ((grantBadType.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
    "MCP-10 set_project_grant rejects non-integer parallel_missions"
  let (restGrantMissingSt, _) ← rest "PUT" "/api/projects/no-such-project/grant" "{\"autonomy_level\":\"observe\"}"
  check (restGrantMissingSt == 404) "MCP-10 REST PUT /api/projects/:slug/grant returns 404 for unknown project"
  let (restGrantBadSt, _) ← rest "PUT" "/api/projects/r17-project/grant" "{\"autonomy_level\":\"bogus\"}"
  check (restGrantBadSt == 400) "MCP-10 REST PUT /api/projects/:slug/grant rejects unknown autonomy_level"
  let (restGrantZeroSt, restGrantZeroBody) ← rest "PUT" "/api/projects/r17-project/grant" "{\"parallel_missions\":0}"
  let .ok restGrantZeroJv := OrbBin.Json.parse restGrantZeroBody | throw (IO.userError "R17 REST grant JSON")
  check (restGrantZeroSt == 200 && restGrantZeroJv.fieldNat? "parallel_missions" == some 0)
    "MCP-10 REST PUT /api/projects/:slug/grant preserves parallel_missions=0"

  -- MCP-11 REST check
  let (restSteerSt, restSteerBody) ← rest "POST" "/api/projects/r17-project/status"
    "{\"status\":\"active\",\"consumed_steer_ids\":[\"r17-steer-1\"]}"
  check (restSteerSt == 501 && restSteerBody.contains "unsupported")
    "MCP-11 REST POST /api/projects/:slug/status refuses consumed_steer_ids"

private def runFleetProvSecChecks
    (root : String) (store : CoreStore) (app : CoreAppState)
    (now : UInt64) (jwt : String) (operator : McpSessionClaims) : IO Unit := do
  let msql (q : String) (params : Array String := #[]) := do
    let .ok rows ← execParamQuery store.missionsDb q params
      | throw (IO.userError "R17 missions fixture query failed")
    return rows
  let call (c : McpSessionClaims) (tool : String) (args : JVal) := do
    let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root c tool args now
    let .ok value := OrbBin.Json.parse raw | throw (IO.userError "R17 MCP JSON")
    return value
  let rest (method path body : String) := do
    let raw := s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
    let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "R17 REST parse")
    let .ok response ← dispatchCoreRequest app req now | throw (IO.userError "R17 REST dispatch")
    return (response.status, (String.fromUTF8? response.body).getD "")

  -- MCP-15 complete: all 8 unsupported tools + update_mission_settings refusing unsupported fields
  for tool in #["remove_worktree", "update_workspace", "delete_workspace", "get_backend_auth_status"] do
    let r ← call operator tool (.obj #[])
    check ((r.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      s!"MCP-15 {tool} is explicit unsupported"
  for role in #["coordinator", "operator"] do
    let some rawCat := OrbBin.McpCatalog.catalogPrettyJsonForRole role
      | throw (IO.userError s!"R17 missing catalog for {role}")
    let .ok (.arr catTools) := OrbBin.Json.parse rawCat
      | throw (IO.userError s!"R17 invalid catalog JSON for {role}")
    let some umsTool := catTools.find? (fun t => t.fieldStr? "name" == some "update_mission_settings")
      | throw (IO.userError s!"R17 missing update_mission_settings in {role} catalog")
    let props := (umsTool.fieldOrNull "inputSchema").fieldOrNull "properties"
    check ((props.field? "agent").isNone && (props.field? "config_profile").isNone &&
      (props.field? "fast_mode").isNone && (props.field? "backend").isSome)
      s!"MCP-15 {role} catalog update_mission_settings omits unsupported fields"
  discard <| msql
    ("INSERT INTO missions(id,title,status,backend,model_override,project,authority_mode,owner_user_id,created_at,updated_at) " ++
     "VALUES('m-r17-settings','Original','awaiting_user','codex','','r17-project','writer','admin','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
  for (field, val) in #[("agent", JVal.str "plan"), ("config_profile", JVal.str "fast"), ("fast_mode", JVal.bool true)] do
    let rej ← call operator "update_mission_settings" (.obj #[
      ("mission_id", .str "m-r17-settings"), ("backend", .str "opencode"),
      (field, val), ("idempotency_key", .str s!"r17-ums-{field}")])
    check (rej.fieldBool? "ok" == some false &&
      (rej.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      s!"MCP-15 update_mission_settings refuses unsupported `{field}`"
  let afterRejBackend ← msql "SELECT backend FROM missions WHERE id='m-r17-settings';"
  check (afterRejBackend.size > 1 && afterRejBackend[1]![0]? == some "codex")
    "MCP-15 refused update_mission_settings leaves mission unchanged"
  let umsOk ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("backend", .str "opencode"),
    ("idempotency_key", .str "r17-ums-ok")])
  let afterOkBackend ← msql "SELECT backend FROM missions WHERE id='m-r17-settings';"
  check (umsOk.fieldBool? "ok" == some true && afterOkBackend.size > 1 && afterOkBackend[1]![0]? == some "opencode")
    "MCP-15 update_mission_settings persists supported backend update"

  -- MCP-16: cloud launch refused, list_cloud_models not_implemented, list_cloud_accounts & get_cloud_execution real
  let beforeCloudMissions ← msql "SELECT COUNT(*) FROM missions;"
  let cloudStart ← call operator "start_mission" (.obj #[
    ("title", .str "Cloud"), ("prompt", .str "Hi"),
    ("cloud", .obj #[("provider", .str "hermes"), ("account", .str "paloma")]),
    ("idempotency_key", .str "r17-cloud-start-1")])
  let afterCloudMissions ← msql "SELECT COUNT(*) FROM missions;"
  check (cloudStart.fieldBool? "ok" == some false &&
    (cloudStart.fieldOrNull "error").fieldStr? "code" == some "unsupported" &&
    beforeCloudMissions == afterCloudMissions)
    "MCP-16 start_mission with cloud returns unsupported and creates zero missions"
  let cloudModels ← call operator "list_cloud_models" (.obj #[("provider", .str "hermes")])
  check (cloudModels.fieldBool? "ok" == some false &&
    (cloudModels.fieldOrNull "error").fieldStr? "code" == some "not_implemented")
    "MCP-16 list_cloud_models returns explicit not_implemented"
  let cloudAcctsNoHub ← call operator "list_cloud_accounts" (.obj #[])
  check (cloudAcctsNoHub.fieldBool? "ok" == some false &&
    (cloudAcctsNoHub.fieldOrNull "error").fieldStr? "code" == some "cloud_unavailable")
    "MCP-16 list_cloud_accounts reports cloud_unavailable without hub instead of fake empty success"
  let cloudExecNone ← call operator "get_cloud_execution" (.obj #[("mission_id", .str "m-r17-settings")])
  check (cloudExecNone.fieldBool? "ok" == some true &&
    (cloudExecNone.fieldOrNull "result").fieldBool? "enabled" == some false)
    "MCP-16 get_cloud_execution reports enabled=false when mission has no cloud execution"
  discard <| msql
    ("INSERT INTO cloud_executions(mission_id,revision,provider,prompt,response_text,status,request_key,data,updated_at) " ++
     "VALUES('m-r17-settings',2,'hermes','check','real cloud reply','completed','rk-cloud-1','{}','2026-11-18T00:00:00Z');")
  let cloudExecSome ← call operator "get_cloud_execution" (.obj #[("mission_id", .str "m-r17-settings")])
  let cesRes := cloudExecSome.fieldOrNull "result"
  check (cloudExecSome.fieldBool? "ok" == some true &&
    cesRes.fieldBool? "enabled" == some true &&
    cesRes.fieldNat? "revision" == some 2)
    "MCP-16 get_cloud_execution returns persisted cloud execution when present"

  -- MCP-18: dynamic MCP server management & /api/tools return explicit 501 unsupported
  for (mth, pth) in #[("GET", "/api/mcp"), ("POST", "/api/mcp"), ("GET", "/api/mcp/srv-1"),
      ("PUT", "/api/mcp/srv-1"), ("DELETE", "/api/mcp/srv-1"), ("POST", "/api/mcp/srv-1/refresh"),
      ("GET", "/api/tools"), ("POST", "/api/tools/x/toggle")] do
    let (st, bd) ← rest mth pth "{}"
    check (st == 501 && bd.contains "unsupported")
      s!"MCP-18 {mth} {pth} returns 501 unsupported"

  -- FLT-04: /api/durable-jobs/:id/force returns 501 unsupported; cancel on unreachable node persists cancel_requested and returns 502 cancel_not_confirmed
  OrbCore.RemoteFleetAndRelay.ensureDurableJobsTable store
  discard <| msql
    ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
     "VALUES('r17-djob-1','m-r17-settings','unreachable-r17-node','running','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
  let (forceSt, forceBody) ← rest "POST" "/api/durable-jobs/r17-djob-1/force" "{}"
  let djobAfterForce ← msql "SELECT state FROM remote_node_jobs WHERE job_id='r17-djob-1';"
  check (forceSt == 501 && forceBody.contains "unsupported" &&
    djobAfterForce.size > 1 && djobAfterForce[1]![0]? == some "running")
    "FLT-04 POST /api/durable-jobs/:id/force returns 501 unsupported without mutating row"
  let (missingCanSt, _) ← rest "POST" "/api/durable-jobs/r17-djob-missing/cancel" "{}"
  check (missingCanSt == 404)
    "FLT-04 POST /api/durable-jobs/:id/cancel returns 404 for unknown job"
  let (unconfCanSt, unconfCanBody) ← rest "POST" "/api/durable-jobs/r17-djob-1/cancel" "{}"
  let .ok unconfJv := OrbBin.Json.parse unconfCanBody | throw (IO.userError "R17 cancel JSON")
  let djobAfterUnconf ← msql "SELECT state FROM remote_node_jobs WHERE job_id='r17-djob-1';"
  check (unconfCanSt == 502 &&
    unconfJv.fieldBool? "ok" == some false &&
    unconfJv.fieldStr? "error" == some "cancel_not_confirmed" &&
    unconfJv.fieldBool? "cancel_requested" == some true &&
    unconfJv.fieldBool? "confirmed" == some false &&
    djobAfterUnconf.size > 1 && djobAfterUnconf[1]![0]? == some "cancel_requested")
    "FLT-04 failed node cancel returns 502 cancel_not_confirmed and persists cancel_requested (never cancelled)"

  -- FLT-14: advertised typed launch capabilities match shared preflight validator
  let rLaunchCaps ← OrbCore.RemoteFleetAndRelay.buildRemoteLaunchCapabilitiesJVal
  let advHarnesses := (rLaunchCaps.fieldArr? "harnesses").getD #[]
  let advPrefixes := (rLaunchCaps.fieldArr? "error_prefixes").getD #[]
  check (rLaunchCaps.fieldBool? "typed" == some true &&
    !advHarnesses.contains (.str "vibe") &&
    advHarnesses.contains (.str "opencode") &&
    advPrefixes.contains (.str "REMOTE_HARNESS_UNSUPPORTED") &&
    advPrefixes.contains (.str "REMOTE_PROMPT_REQUIRED") &&
    advPrefixes.contains (.str "remote_goal_unsupported") &&
    advPrefixes.contains (.str "REMOTE_AUTH_REQUIRED") &&
    !advPrefixes.contains (.str "REMOTE_MODEL_REQUIRED"))
    "FLT-14 buildRemoteLaunchCapabilitiesJVal advertises only implemented harnesses and enforced prefixes"
  let vibeErr := match OrbCore.RemoteFleetAndRelay.validateRemoteLaunchPlan "vibe" "hello" "https://core.test" with
    | .error e => e | .ok _ => ""
  let emptyPromptErr := match OrbCore.RemoteFleetAndRelay.validateRemoteLaunchPlan "opencode" "   " "https://core.test" with
    | .error e => e | .ok _ => ""
  let missingProxyErr := match OrbCore.RemoteFleetAndRelay.validateRemoteLaunchPlan "opencode" "hello" "" with
    | .error e => e | .ok _ => ""
  let validPlanOk := match OrbCore.RemoteFleetAndRelay.validateRemoteLaunchPlan "claude" "hello" "https://core.test" with
    | .ok "claudecode" => true | _ => false
  check (vibeErr.startsWith "REMOTE_HARNESS_UNSUPPORTED:" &&
    emptyPromptErr.startsWith "REMOTE_PROMPT_REQUIRED:" &&
    missingProxyErr.startsWith "REMOTE_AUTH_REQUIRED:" &&
    validPlanOk)
    "FLT-14 validateRemoteLaunchPlan enforces advertised typed error prefixes"

  -- PROV08: reset-usage returns 501 unsupported without mutating cooldowns; auto_reset_on_limit refused on PUT and false in DTO
  let .ok _ ← upsertAIProvider store {
    id := "r17-prov-1", providerType := "anthropic", name := "R17 Anthropic",
    apiKey := "sk-ant-r17-synthetic", enabled := true, updatedAt := "1700002000"
  } | throw (IO.userError "R17 provider fixture")
  app.proxyCooldownsRef.set #[{ accountId := "r17-prov-1", reason := default, untilEpoch := now + 600 }]
  let (resetSt, resetBody) ← rest "POST" "/api/ai/providers/r17-prov-1/reset-usage" "{}"
  let .ok resetJv := OrbBin.Json.parse resetBody | throw (IO.userError "R17 reset-usage JSON")
  let cdsAfterReset ← app.proxyCooldownsRef.get
  check (resetSt == 501 &&
    resetJv.fieldBool? "ok" == some false &&
    resetJv.fieldStr? "error" == some "unsupported" &&
    resetJv.fieldBool? "reset_redeemed" == some false &&
    resetJv.fieldNat? "woken_missions" == some 0 &&
    cdsAfterReset.size == 1)
    "PROV08 POST /api/ai/providers/:id/reset-usage returns 501 unsupported and preserves cooldowns"
  let (arPutSt, arPutBody) ← rest "PUT" "/api/ai/providers/r17-prov-1" "{\"auto_reset_on_limit\":true}"
  check (arPutSt == 501 && arPutBody.contains "unsupported")
    "PROV08 PUT /api/ai/providers/:id refuses auto_reset_on_limit=true with 501 unsupported"
  let (provGetSt, provGetBody) ← rest "GET" "/api/ai/providers/r17-prov-1" ""
  let .ok provGetJv := OrbBin.Json.parse provGetBody | throw (IO.userError "R17 provider get JSON")
  check (provGetSt == 200 && provGetJv.fieldBool? "auto_reset_on_limit" == some false)
    "PROV08 GET /api/ai/providers/:id truthfully reports auto_reset_on_limit=false"

  -- SEC-06: secret_put/secret_delete/secret_move refused BEFORE queueing; legacy pending non-read requests refused on single & batch approve
  for secTool in #["secret_put", "secret_delete", "secret_move"] do
    let sr ← call operator secTool (.obj #[
      ("name", .str "R17_SYNTHETIC_KEY"), ("bitwarden_project", .str "ops"),
      ("value", .str "synthetic-unused"), ("reason", .str "r17 test")])
    check (sr.fieldBool? "ok" == some false &&
      (sr.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      s!"SEC-06 {secTool} is refused as unsupported before queueing"
  let brokerAfterRefusal ← readBrokerJson store.rootDir
  check (((brokerAfterRefusal.fieldArr? "requests").getD #[]).isEmpty &&
    ((brokerAfterRefusal.fieldArr? "grants").getD #[]).isEmpty)
    "SEC-06 refused secret mutations leave secret_broker.json with zero requests and zero grants"
  let legacyPending := JVal.obj #[
    ("requests", .arr #[.obj #[
      ("id", .str "r17-legacy-sec-put"),
      ("kind", .str "secret_put"),
      ("mission_id", .str "m-r17-settings"),
      ("requester_subject", .str "mission:m-r17-settings"),
      ("bitwarden_project", .str "ops"),
      ("secret_name", .str "R17_LEGACY_KEY"),
      ("status", .str "pending"),
      ("created_at", .str (formatEpochIso8601Utc now))
    ]]),
    ("grants", .arr #[])
  ]
  writeBrokerJson store.rootDir legacyPending
  let (pubKey, sign) ← OrbCore.ApprovalSignatureTests.makeSigner s!"{root}/r17-approval-key"
  IO.FS.writeFile s!"{store.rootDir}/approval_devices.json" (renderCompact (.obj #[
    ("mode", .str "biometric"),
    ("devices", .arr #[.obj #[("id", .str "test-device"), ("name", .str "R17"), ("public_key", .str pubKey)]])
  ]))
  let restSigned (path body : String) := do
    let sigHdr ← OrbCore.ApprovalSignatureTests.header store sign path body now
    let raw := s!"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nX-Paloma-Approval: {sigHdr}\r\nContent-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
    let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "R17 signed REST parse")
    let .ok response ← dispatchCoreRequest app req now | throw (IO.userError "R17 signed REST dispatch")
    return (response.status, (String.fromUTF8? response.body).getD "")
  let (singleAppSt, singleAppBody) ← restSigned "/api/bitwarden/requests/r17-legacy-sec-put/approve" "{}"
  check (singleAppSt == 409 && singleAppBody.contains "unsupported")
    s!"SEC-06 single approve refuses legacy pending secret_put without granting read access (st={singleAppSt} body={singleAppBody})"
  let (batchAppSt, batchAppBody) ← restSigned "/api/approvals/approve-all"
    "{\"items\":[{\"kind\":\"secret\",\"id\":\"r17-legacy-sec-put\"}],\"confirm_critical\":true}"
  let brokerAfterApprove ← readBrokerJson store.rootDir
  check (batchAppSt == 409 && batchAppBody.contains "unsupported_secret_tier" &&
    ((brokerAfterApprove.fieldArr? "grants").getD #[]).isEmpty)
    s!"SEC-06 batch approve refuses legacy pending secret_put and creates zero read grants (st={batchAppSt} body={batchAppBody})"

private def serveMockOrbNodeOnce (listenFd : LeanSys.Posix.Fd) (status : Nat) (ctype body : String) : IO (Task (Except IO.Error Unit)) :=
  IO.asTask (prio := .dedicated) do
    let .ok clientFd ← LeanSys.Posix.tcpAcceptPoll listenFd 5000 | return ()
    try
      discard <| readCoreHttpRequestFromFd clientFd
      let resp := s!"HTTP/1.1 {status} OK\r\nContent-Type: {ctype}\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}"
      discard <| LeanSys.Posix.writeAll clientFd resp.toUTF8
    finally
      discard <| LeanSys.Posix.closeFd clientFd

private def runCarbonRegressionChecks
    (root : String) (store : CoreStore) (mStore : ManagedComputeStore) (cfg : CoreConfig) (app : CoreAppState)
    (now : UInt64) (jwt : String) (operator : McpSessionClaims) : IO Unit := do
  let sql (q : String) (params : Array String := #[]) := do
    let .ok rows ← execParamQuery store.projectsDb q params
      | throw (IO.userError "R17 regression projects query failed")
    return rows
  let msql (q : String) (params : Array String := #[]) := do
    let .ok rows ← execParamQuery store.missionsDb q params
      | throw (IO.userError "R17 regression missions query failed")
    return rows
  let call (c : McpSessionClaims) (tool : String) (args : JVal) (sup? : Option OrbCore.RemoteDispatch.RemoteJobSupervisor := none) := do
    let raw ← OrbCore.McpGateway.dispatchMcpToolCall store (some mStore) none none {} root c tool args now (remoteSup? := sup?)
    let .ok value := OrbBin.Json.parse raw | throw (IO.userError "R17 regression MCP JSON")
    return value
  let restRaw (tok? : Option String) (method path body : String) (appOverride : CoreAppState := app) := do
    let authHdr := match tok? with | some t => s!"Authorization: Bearer {t}\r\n" | none => ""
    let raw := s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authHdr}Content-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
    let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "R17 regression REST parse")
    let .ok response ← dispatchCoreRequest appOverride req now | throw (IO.userError "R17 regression REST dispatch")
    return (response.status, (String.fromUTF8? response.body).getD "")

  -- Finding #1: Cross-tenant user:slug bypass, unknown GET /grant 404, strict REST POST /status
  discard <| msql
    "INSERT INTO users(id,username,password_hash,role) VALUES('r17-member-b','r17memberb','synthetic-hash','member');"
  let memberAJwt := mintSessionTokenV2 cfg.jwtSecret "r17-member" "member" 1 (now + 3600)
  let memberBJwt := mintSessionTokenV2 cfg.jwtSecret "r17-member-b" "member" 1 (now + 3600)
  let (mkProjSt, _) ← restRaw (some memberAJwt) "POST" "/api/projects" "{\"slug\":\"secret-proj\",\"title\":\"Alice Secret\",\"status\":\"paused\"}"
  check (mkProjSt == 200) "R17-F1 member-a creates scoped project"
  let (setGrantASt, _) ← restRaw (some memberAJwt) "PUT" "/api/projects/secret-proj/grant" "{\"autonomy_level\":\"observe\",\"parallel_missions\":2}"
  check (setGrantASt == 200) "R17-F1 member-a sets own project grant"
  let (crossGrantSt, crossGrantBody) ← restRaw (some memberBJwt) "GET" "/api/projects/r17-member:secret-proj/grant" ""
  check (crossGrantSt == 400 && !crossGrantBody.contains "observe")
    s!"R17-F1 member-b cannot read member-a grant via user:slug (st={crossGrantSt})"
  let (crossStatusSt, crossStatusBody) ← restRaw (some memberBJwt) "POST" "/api/projects/r17-member:secret-proj/status" "{\"status\":\"archived\"}"
  let aliceStatusAfter ← sql "SELECT status FROM projects WHERE slug='r17-member:secret-proj';"
  check (crossStatusSt == 400 && !crossStatusBody.contains "Alice Secret" &&
    aliceStatusAfter.size > 1 && aliceStatusAfter[1]![0]? == some "paused")
    s!"R17-F1 member-b cannot overwrite member-a status via user:slug (st={crossStatusSt})"
  let (unknownGrantSt, _) ← restRaw (some jwt) "GET" "/api/projects/definitely-missing-proj/grant" ""
  check (unknownGrantSt == 404) "R17-F1 GET /api/projects/:slug/grant returns 404 for unknown project"
  let (badJsonSt, _) ← restRaw (some jwt) "POST" "/api/projects/r17-project/status" "{not-json"
  let (omitStatusSt, _) ← restRaw (some jwt) "POST" "/api/projects/r17-project/status" "{}"
  let (bogusStatusSt, _) ← restRaw (some jwt) "POST" "/api/projects/r17-project/status" "{\"status\":\"made_up\"}"
  let (modeStatusSt, _) ← restRaw (some jwt) "POST" "/api/projects/r17-project/status" "{\"status\":\"paused\",\"mode\":\"autonomous\"}"
  let (missingProjStatusSt, _) ← restRaw (some jwt) "POST" "/api/projects/never-created-proj/status" "{\"status\":\"paused\"}"
  let createdCheck ← sql "SELECT COUNT(*) FROM projects WHERE slug='never-created-proj';"
  check (badJsonSt == 400 && omitStatusSt == 400 && bogusStatusSt == 400 &&
    modeStatusSt == 501 && missingProjStatusSt == 404 &&
    createdCheck.size > 1 && createdCheck[1]![0]? == some "0")
    s!"R17-F1 REST POST /status enforces strict JSON/enum/retired fields and never auto-creates (bad={badJsonSt},omit={omitStatusSt},bogus={bogusStatusSt},mode={modeStatusSt},missing={missingProjStatusSt})"

  -- Finding #2: FLT-04 live mock OrbNode cancel wire contract + settled-receipt immutability
  let .ok (mockFd, mockPort) ← LeanSys.Posix.tcpListen "127.0.0.1" 0 8
    | throw (IO.userError "R17-F2 mock OrbNode listen failed")
  try
    let prevRemoteNodes ← IO.getEnv "SANDBOXED_REMOTE_NODES"
    let prevMockTok ← IO.getEnv "R17_MOCK_NODE_TOK"
    setenvVar "R17_MOCK_NODE_TOK" "r17-mock-secret"
    setenvVar "SANDBOXED_REMOTE_NODES" s!"r17mock=http://127.0.0.1:{mockPort}|R17_MOCK_NODE_TOK"
    try
      -- (a) 404 "job <id> not found" confirms cancel
      discard <| msql
        "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) VALUES('r17-dj-404','m-r17-settings','r17mock','running','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');"
      let t1 ← serveMockOrbNodeOnce mockFd 404 "text/plain" "job r17-dj-404 not found"
      let (c404St, c404Body) ← restRaw (some jwt) "POST" "/api/durable-jobs/r17-dj-404/cancel" "{}"
      let _ := t1.get
      let .ok c404Jv := OrbBin.Json.parse c404Body | throw (IO.userError "R17-F2 c404 JSON")
      let st404 ← msql "SELECT state FROM remote_node_jobs WHERE job_id='r17-dj-404';"
      check (c404St == 200 && c404Jv.fieldBool? "confirmed" == some true && st404[1]![0]? == some "cancelled")
        s!"R17-F2 OrbNode 404 'job <id> not found' confirms cancel (st={c404St}, body={c404Body})"
      -- (b) Re-cancelling an already-cancelled job is idempotent 200 confirmed=true (no node call needed)
      let (cIdemSt, cIdemBody) ← restRaw (some jwt) "POST" "/api/durable-jobs/r17-dj-404/cancel" "{}"
      let .ok cIdemJv := OrbBin.Json.parse cIdemBody | throw (IO.userError "R17-F2 cIdem JSON")
      check (cIdemSt == 200 && cIdemJv.fieldBool? "confirmed" == some true && cIdemJv.fieldStr? "state" == some "cancelled")
        "R17-F2 retrying cancel on already-cancelled durable job returns idempotent 200 confirmed=true"
      -- (c) OrbNode 200 {state:"cancelled", cancel_requested:false} confirms cancel
      discard <| msql
        "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) VALUES('r17-dj-alcan','m-r17-settings','r17mock','running','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');"
      let t2 ← serveMockOrbNodeOnce mockFd 200 "application/json" "{\"job_id\":\"r17-dj-alcan\",\"state\":\"cancelled\",\"cancel_requested\":false}"
      let (cAlCanSt, cAlCanBody) ← restRaw (some jwt) "POST" "/api/durable-jobs/r17-dj-alcan/cancel" "{}"
      let _ := t2.get
      let .ok cAlCanJv := OrbBin.Json.parse cAlCanBody | throw (IO.userError "R17-F2 cAlCan JSON")
      check (cAlCanSt == 200 && cAlCanJv.fieldBool? "confirmed" == some true && cAlCanJv.fieldStr? "state" == some "cancelled")
        "R17-F2 OrbNode 200 {state:'cancelled',cancel_requested:false} returns 200 confirmed=true"
      -- (d) OrbNode 200 {state:"succeeded", cancel_requested:false} reconciles to succeeded & refuses cancel (409)
      discard <| msql
        "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) VALUES('r17-dj-done','m-r17-settings','r17mock','running','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');"
      let t3 ← serveMockOrbNodeOnce mockFd 200 "application/json" "{\"job_id\":\"r17-dj-done\",\"state\":\"succeeded\",\"cancel_requested\":false}"
      let (cDoneSt, cDoneBody) ← restRaw (some jwt) "POST" "/api/durable-jobs/r17-dj-done/cancel" "{}"
      let _ := t3.get
      let .ok cDoneJv := OrbBin.Json.parse cDoneBody | throw (IO.userError "R17-F2 cDone JSON")
      let stDone ← msql "SELECT state FROM remote_node_jobs WHERE job_id='r17-dj-done';"
      check (cDoneSt == 409 && cDoneJv.fieldBool? "confirmed" == some false &&
        cDoneJv.fieldStr? "state" == some "succeeded" && stDone[1]![0]? == some "succeeded")
        s!"R17-F2 OrbNode 200 terminal succeeded reconciles and refuses to rewrite to cancelled (st={cDoneSt}, body={cDoneBody})"
      -- (e) Settled local/remote job refuses cancel without rewriting DB
      discard <| msql
        "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) VALUES('r17-dj-local-ok','m-r17-settings','local','succeeded','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');"
      let (cLocSt, _) ← restRaw (some jwt) "POST" "/api/durable-jobs/r17-dj-local-ok/cancel" "{}"
      let stLoc ← msql "SELECT state FROM remote_node_jobs WHERE job_id='r17-dj-local-ok';"
      check (cLocSt == 409 && stLoc[1]![0]? == some "succeeded")
        "R17-F2 settled local durable job refuses rewrite to cancelled"

      -- Finding #3: HTTP-05 remote-targeted ?node=<remote> must return 501 BEFORE relaying to OrbNode
      let (remUpdSt, remUpdBody) ← restRaw (some jwt) "POST" "/api/software/updates?node=r17mock" "{}"
      let (remCanSt, remCanBody) ← restRaw (some jwt) "POST" "/api/software/updates/cancel?node=r17mock" "{}"
      check (remUpdSt == 501 && remUpdBody.contains "unsupported" &&
        remCanSt == 501 && remCanBody.contains "unsupported")
        s!"R17-F3 remote-targeted /api/software/updates* returns 501 before node relay (upd={remUpdSt}, can={remCanSt})"
    finally
      match prevRemoteNodes with | some v => setenvVar "SANDBOXED_REMOTE_NODES" v | none => unsetenvVar "SANDBOXED_REMOTE_NODES"
      match prevMockTok with | some v => setenvVar "R17_MOCK_NODE_TOK" v | none => unsetenvVar "R17_MOCK_NODE_TOK"
  finally
    discard <| LeanSys.Posix.closeFd mockFd

  -- Finding #4: MCP-18 unauthenticated /api/mcp and /api/tools* must return 401 (never 501)
  for (mth, pth) in #[("GET", "/api/mcp"), ("POST", "/api/mcp"), ("GET", "/api/mcp/srv-1"),
      ("GET", "/api/tools"), ("POST", "/api/tools/x/toggle")] do
    let (st, _) ← restRaw none mth pth "{}"
    check (st == 401) s!"R17-F4 unauthenticated {mth} {pth} returns 401 (got {st})"

  -- Finding #5: FLT-14 end-to-end REST & MCP remote launch preflight BEFORE auto-managed VM rental + 400 status
  let sup ← OrbCore.RemoteDispatch.newRemoteJobSupervisor cfg.jwtSecret false
  let appWithSup : CoreAppState := { app with remoteSup? := some sup }
  let beforeRestMissions ← msql "SELECT COUNT(*) FROM missions;"
  let (restVibeEmptySt, restVibeEmptyBody) ← restRaw (some jwt) "POST" "/api/control/missions"
    "{\"title\":\"Vibe Empty\",\"backend\":\"vibe\",\"remote_node_id\":\"auto-managed:boat:small\"}" appWithSup
  let afterRestVibe ← msql "SELECT COUNT(*) FROM missions;"
  check (restVibeEmptySt == 400 && restVibeEmptyBody.contains "REMOTE_HARNESS_UNSUPPORTED" && beforeRestMissions == afterRestVibe)
    s!"R17-F5 REST empty-prompt remote vibe rejected 400 before mission insert/VM rental (st={restVibeEmptySt}, body={restVibeEmptyBody})"
  let prevPub ← IO.getEnv "SANDBOXED_PUBLIC_URL"
  let prevProxy ← IO.getEnv "SANDBOXED_PROXY_PUBLIC_URL"
  unsetenvVar "SANDBOXED_PUBLIC_URL"
  unsetenvVar "SANDBOXED_PROXY_PUBLIC_URL"
  try
    let (restNoProxySt, restNoProxyBody) ← restRaw (some jwt) "POST" "/api/control/missions"
      "{\"title\":\"No Proxy\",\"backend\":\"opencode\",\"remote_node_id\":\"auto-managed:boat:small\",\"prompt\":\"hello\"}" appWithSup
    check (restNoProxySt == 400 && restNoProxyBody.contains "REMOTE_AUTH_REQUIRED")
      s!"R17-F5 REST missing proxy URL returns 400 REMOTE_AUTH_REQUIRED (not 502) (st={restNoProxySt}, body={restNoProxyBody})"
  finally
    match prevPub with | some v => setenvVar "SANDBOXED_PUBLIC_URL" v | none => pure ()
    match prevProxy with | some v => setenvVar "SANDBOXED_PROXY_PUBLIC_URL" v | none => pure ()
  let mcpVibeEmpty ← call operator "start_mission" (.obj #[
    ("title", .str "MCP Vibe Empty"), ("backend", .str "vibe"),
    ("remote_node_id", .str "auto-managed:boat:small"), ("idempotency_key", .str "r17-f5-mcp-vibe")]) (some sup)
  let mcpGoalVibe ← call operator "start_mission" (.obj #[
    ("title", .str "MCP Goal Vibe"), ("backend", .str "vibe"), ("prompt", .str "/goal Ship it"),
    ("remote_node_id", .str "auto-managed:boat:small"), ("idempotency_key", .str "r17-f5-mcp-goal")]) (some sup)
  let afterMcpVibe ← msql "SELECT COUNT(*) FROM missions;"
  let managedCount ← execParamQuery mStore.db "SELECT COUNT(*) FROM managed_machines;" #[]
  let mcpVibeMsg := ((mcpVibeEmpty.fieldOrNull "error").fieldStr? "message").getD ""
  let mcpGoalMsg := ((mcpGoalVibe.fieldOrNull "error").fieldStr? "message").getD ""
  check (mcpVibeEmpty.fieldBool? "ok" == some false &&
    mcpVibeMsg.contains "REMOTE_HARNESS_UNSUPPORTED" &&
    mcpGoalVibe.fieldBool? "ok" == some false &&
    mcpGoalMsg.contains "remote_goal_unsupported" &&
    beforeRestMissions == afterMcpVibe &&
    (managedCount.toOption.bind (fun rs => rs[1]?.bind (·[0]?))) == some "0")
    "R17-F5 MCP start_mission rejects unsupported harness & /goal before renting any auto-managed VM"

  -- Finding #6: MCP-02 ManagedSpawnActions accepted truth on running/uncertain/rejected receipts
  discard <| sql
    ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
     "VALUES('r17-spawn-run','m-r17-settings','s','rk-sr','{}','admin','spawn_managed_machine','{}','running','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z')," ++
     "('r17-spawn-unc','m-r17-settings','s','rk-su','{}','admin','spawn_managed_machine','{}','uncertain','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
  let cancelRunSpawn ← call operator "cancel_action" (.obj #[("action_id", .str "r17-spawn-run"), ("idempotency_key", .str "r17-f6-can-run")])
  let crsRes := cancelRunSpawn.fieldOrNull "result"
  check (cancelRunSpawn.fieldBool? "ok" == some true &&
    crsRes.fieldBool? "cancelled" == some false &&
    crsRes.fieldStr? "accepted" == some "no")
    s!"R17-F6 cancel_action on running ManagedSpawnAction returns cancelled=false, accepted=no ({renderCompact cancelRunSpawn})"
  let recRejSpawn ← call operator "reconcile_action" (.obj #[
    ("action_id", .str "r17-spawn-unc"), ("resolution", .str "rejected"),
    ("evidence", .str "verified no VM rented"), ("idempotency_key", .str "r17-f6-rec-rej")])
  let recTarget := (recRejSpawn.fieldOrNull "result").fieldOrNull "receipt"
  check (recRejSpawn.fieldBool? "ok" == some true &&
    recTarget.fieldStr? "state" == some "rejected" &&
    recTarget.fieldStr? "accepted" == some "no")
    s!"R17-F6 reconcile_action(rejected) on uncertain ManagedSpawnAction reports accepted=no ({renderCompact recRejSpawn})"

  -- Finding #7: PROV08 POST /api/ai/providers rejects auto_reset_on_limit=true; all DTOs emit auto_reset_on_limit=false
  let (arPostSt, arPostBody) ← restRaw (some jwt) "POST" "/api/ai/providers"
    "{\"provider_type\":\"anthropic\",\"name\":\"R17 Bad Reset\",\"api_key\":\"sk-ant-r17-bad\",\"auto_reset_on_limit\":true}"
  check (arPostSt == 501 && arPostBody.contains "unsupported")
    s!"R17-F7 POST /api/ai/providers rejects auto_reset_on_limit=true with 501 (st={arPostSt})"
  let (goodPostSt, goodPostBody) ← restRaw (some jwt) "POST" "/api/ai/providers"
    "{\"id\":\"r17-prov-2\",\"provider_type\":\"anthropic\",\"name\":\"R17 Good\",\"api_key\":\"sk-ant-r17-good\"}"
  let .ok goodPostJv := OrbBin.Json.parse goodPostBody | throw (IO.userError "R17-F7 post prov JSON")
  let (goodPutSt, goodPutBody) ← restRaw (some jwt) "PUT" "/api/ai/providers/r17-prov-2" "{\"name\":\"R17 Good Renamed\"}"
  let .ok goodPutJv := OrbBin.Json.parse goodPutBody | throw (IO.userError "R17-F7 put prov JSON")
  let (memListSt, memListBody) ← restRaw (some memberAJwt) "GET" "/api/ai/providers" ""
  let .ok (.arr memProvArr) := OrbBin.Json.parse memListBody | throw (IO.userError "R17-F7 member prov JSON")
  check (goodPostSt == 201 && goodPostJv.fieldBool? "auto_reset_on_limit" == some false &&
    goodPutSt == 200 && goodPutJv.fieldBool? "auto_reset_on_limit" == some false &&
    memListSt == 200 && memProvArr.any (fun p => p.fieldBool? "auto_reset_on_limit" == some false))
    "R17-F7 POST, PUT, and member GET /api/ai/providers all emit auto_reset_on_limit=false"

  -- Finding #8: MCP-16 get_cloud_execution read-access enforcement + paging/prompt redaction
  let execOtherClaims : McpSessionClaims := {
    sessionId := "r17-exec-other", missionId := "m-unrelated-exec", role := "executor",
    project := "", isExternal := false, expiresAt := now + 3600
  }
  let cloudForbidden ← call execOtherClaims "get_cloud_execution" (.obj #[("mission_id", .str "m-r17-settings")])
  check (cloudForbidden.fieldBool? "ok" == some false &&
    (cloudForbidden.fieldOrNull "error").fieldStr? "code" == some "forbidden")
    s!"R17-F8 get_cloud_execution enforces checkMissionReadAccess in single-tenant mode ({renderCompact cloudForbidden})"
  let multiTurnData := renderCompact (.obj #[
    ("mission_id", .str "m-r17-settings"),
    ("turns", .arr #[
      .obj #[("key", .str "t1"), ("prompt", .str "SECRET_PROMPT_1"), ("result", .str "abcdefghij"), ("detail", .str "d1"), ("artifacts", .arr #[.str "a1"]), ("branches", .arr #[])],
      .obj #[("key", .str "t2"), ("prompt", .str "SECRET_PROMPT_2"), ("result", .str "0123456789"), ("detail", .str "d2"), ("artifacts", .arr #[.str "a2", .str "a3"]), ("branches", .arr #[.str "b1"])]
    ])
  ])
  discard <| msql "UPDATE cloud_executions SET data=?1, revision=3 WHERE mission_id='m-r17-settings';" #[multiTurnData]
  let cloudDefault ← call operator "get_cloud_execution" (.obj #[("mission_id", .str "m-r17-settings")])
  let cdTurns := (((cloudDefault.fieldOrNull "result").fieldOrNull "execution").fieldArr? "turns").getD #[]
  check (cloudDefault.fieldBool? "ok" == some true && cdTurns.size == 1 &&
    cdTurns[0]!.fieldStr? "key" == some "t2" &&
    (cdTurns[0]!.field? "prompt").isNone &&
    (cdTurns[0]!.field? "artifacts").isNone &&
    cdTurns[0]!.fieldNat? "artifact_count" == some 2 &&
    cdTurns[0]!.fieldNat? "branch_count" == some 1)
    s!"R17-F8 get_cloud_execution defaults to latest 1 turn, omits prompt & raw artifacts/branches ({renderCompact cloudDefault})"
  let cloudPaged ← call operator "get_cloud_execution" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("include_prompt", .bool true),
    ("offset", .nat 0), ("limit", .nat 2), ("text_offset", .nat 2), ("text_limit", .nat 4)])
  let cpTurns := (((cloudPaged.fieldOrNull "result").fieldOrNull "execution").fieldArr? "turns").getD #[]
  check (cloudPaged.fieldBool? "ok" == some true && cpTurns.size == 2 &&
    cpTurns[0]!.fieldStr? "prompt" == some "CRET" &&
    cpTurns[0]!.fieldStr? "result" == some "cdef")
    s!"R17-F8 get_cloud_execution honors include_prompt/offset/limit/text_offset/text_limit ({renderCompact cloudPaged})"

  -- Finding #9: MCP-10 & MCP-15 strict field validation on set_project_grant and update_mission_settings
  let badGrantMcp ← call operator "set_project_grant" (.obj #[
    ("slug", .str "r17-project"), ("max_parallel", .nat 2), ("idempotency_key", .str "r17-f9-badgrant")])
  let (badGrantRestSt, _) ← restRaw (some jwt) "PUT" "/api/projects/r17-project/grant" "{\"max_parallel\":2}"
  check (badGrantMcp.fieldBool? "ok" == some false &&
    (badGrantMcp.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments" &&
    badGrantRestSt == 400)
    "R17-F9 set_project_grant and REST PUT /grant reject unknown fields"
  let umsNullAgent ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("agent", .null), ("idempotency_key", .str "r17-f9-nullagent")])
  let umsUnknownKey ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("model", .str "gpt-5"), ("idempotency_key", .str "r17-f9-unkkey")])
  let umsBadTitle ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("title", .nat 123), ("idempotency_key", .str "r17-f9-badtitle")])
  let umsBogusBackend ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("backend", .str "bogus"), ("idempotency_key", .str "r17-f9-bogus")])
  discard <| msql "UPDATE missions SET placement_kind='remote_node' WHERE id='m-r17-settings';"
  let umsRemoteVibe ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("backend", .str "vibe"), ("idempotency_key", .str "r17-f9-remvibe")])
  check ((umsNullAgent.fieldOrNull "error").fieldStr? "code" == some "unsupported" &&
    (umsUnknownKey.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments" &&
    (umsBadTitle.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments" &&
    (umsBogusBackend.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments" &&
    (umsRemoteVibe.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
    "R17-F9 update_mission_settings rejects null unsupported fields, unknown keys, wrong types, bogus & remote-incompatible backends"

  -- Finding #10: McpCatalog containment & secret_* mutating classification
  for role in #["executor", "coordinator", "operator"] do
    let some rawCat := OrbBin.McpCatalog.catalogPrettyJsonForRole role
      | throw (IO.userError s!"R17-F10 missing catalog for {role}")
    let .ok (.arr catTools) := OrbBin.Json.parse rawCat
      | throw (IO.userError s!"R17-F10 invalid catalog JSON for {role}")
    for unimpl in #["secret_put", "secret_delete", "secret_move", "start_workspace_job", "get_workspace_job", "cancel_workspace_job",
        "create_worktree", "remove_worktree", "merge_branch", "create_workspace", "update_workspace", "delete_workspace",
        "get_backend_auth_status", "deploy_sandboxed_sh", "list_cloud_models"] do
      check (!(catTools.any (fun t => t.fieldStr? "name" == some unimpl)))
        s!"R17-F10 {role} catalog omits unimplemented `{unimpl}`"
    if let some stTool := catTools.find? (fun t => t.fieldStr? "name" == some "start_mission") then
      check ((((stTool.fieldOrNull "inputSchema").fieldOrNull "properties").field? "cloud").isNone)
        s!"R17-F10 {role} start_mission omits unimplemented cloud schema"
    if let some umsTool := catTools.find? (fun t => t.fieldStr? "name" == some "update_mission_settings") then
      check (((((umsTool.fieldOrNull "inputSchema").fieldOrNull "properties").fieldOrNull "model_override").fieldStr? "type") == some "string")
        s!"R17-F10 {role} update_mission_settings model_override uses portable string type"
  check (OrbBin.McpCatalog.isMutatingControlTool "secret_put" &&
    OrbBin.McpCatalog.isMutatingControlTool "secret_delete" &&
    OrbBin.McpCatalog.isMutatingControlTool "secret_move")
    "R17-F10 secret_put/secret_delete/secret_move are classified mutating"

  -- Round 2 regressions (Findings 1–6)
  -- R2-F1: pending spawn/generic action receipts emit accepted="yes" so sandboxed-mcp classifies them pending (not reconciliation_required)
  discard <| sql
    ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
     "VALUES('r17-r2-pend-spawn','m-r17-settings','s','rk-r2-ps','{}','admin','spawn_managed_machine','{}','accepted','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z')," ++
     "('r17-r2-pend-gen','m-r17-settings','r17-op::test_tool','rk-r2-pg','{}','operator::','test_tool','{}','running','{}','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
  let getPendSpawn ← call operator "get_action" (.obj #[("action_id", .str "r17-r2-pend-spawn")])
  let getPendGen ← call operator "get_action" (.obj #[("action_id", .str "r17-r2-pend-gen")])
  check ((getPendSpawn.fieldOrNull "result").fieldStr? "accepted" == some "yes" &&
    (getPendSpawn.fieldOrNull "result").fieldStr? "state" == some "accepted" &&
    (getPendGen.fieldOrNull "result").fieldStr? "accepted" == some "yes" &&
    (getPendGen.fieldOrNull "result").fieldStr? "state" == some "running")
    "R17-R2-F1 pending spawn and generic action receipts report accepted=yes"

  -- R2-F2: POST /api/projects and /file/transfer/:dstSlug reject cross-tenant user:slug
  let (crossPostProjSt, crossPostProjBody) ← restRaw (some memberBJwt) "POST" "/api/projects"
    "{\"slug\":\"r17-member:secret-proj\",\"title\":\"Hijacked\",\"status\":\"archived\"}"
  let aliceTitleAfter ← sql "SELECT title, status FROM projects WHERE slug='r17-member:secret-proj';"
  check (crossPostProjSt == 400 && !crossPostProjBody.contains "Alice Secret" &&
    aliceTitleAfter.size > 1 && aliceTitleAfter[1]![0]? == some "Alice Secret" && aliceTitleAfter[1]![1]? == some "paused")
    s!"R17-R2-F2 member-b POST /api/projects cannot overwrite member-a via user:slug (st={crossPostProjSt})"
  let (mkBProjSt, _) ← restRaw (some memberBJwt) "POST" "/api/projects" "{\"slug\":\"b-proj\",\"title\":\"Bob Proj\"}"
  check (mkBProjSt == 200) "R17-R2-F2 member-b creates own project"
  let (crossXferSt, _) ← restRaw (some memberBJwt) "POST" "/api/projects/b-proj/file/transfer/r17-member:secret-proj"
    "{\"path\":\"x.txt\",\"destination\":\"AGENTS.md\",\"copy\":true}"
  check (crossXferSt == 400)
    s!"R17-R2-F2 member-b /file/transfer/:dstSlug rejects foreign user:slug (st={crossXferSt})"

  -- R2-F3: classifyOrbNodeCancelReply distinguishes confirmedCancelled vs alreadyTerminal vs unstopped lost
  check (OrbCore.RemoteFleetAndRelay.classifyOrbNodeCancelReply 404 "job j-1 not found" "j-1" none == .confirmedCancelled &&
    OrbCore.RemoteFleetAndRelay.classifyOrbNodeCancelReply 200 "" "j-1" (some (.obj #[("state", .str "cancelled"), ("cancel_requested", .bool false)])) == .confirmedCancelled &&
    OrbCore.RemoteFleetAndRelay.classifyOrbNodeCancelReply 200 "" "j-1" (some (.obj #[("state", .str "succeeded"), ("cancel_requested", .bool false)])) == .alreadyTerminal "succeeded" &&
    OrbCore.RemoteFleetAndRelay.classifyOrbNodeCancelReply 200 "" "j-1" (some (.obj #[("state", .str "lost"), ("cancel_requested", .bool false)])) == .notConfirmed)
    "R17-R2-F3 classifyOrbNodeCancelReply handles 404, cancelled, terminal succeeded, and unstopped lost honestly"

  -- R2-F4: empty-prompt opencode without proxy URL rejected BEFORE VM rental on both MCP and REST
  let prevPub2 ← IO.getEnv "SANDBOXED_PUBLIC_URL"
  let prevProxy2 ← IO.getEnv "SANDBOXED_PROXY_PUBLIC_URL"
  unsetenvVar "SANDBOXED_PUBLIC_URL"
  unsetenvVar "SANDBOXED_PROXY_PUBLIC_URL"
  try
    let (restEmptyOcSt, restEmptyOcBody) ← restRaw (some jwt) "POST" "/api/control/missions"
      "{\"title\":\"OC Empty\",\"backend\":\"opencode\",\"remote_node_id\":\"auto-managed:boat:small\"}" appWithSup
    let mcpEmptyOc ← call operator "start_mission" (.obj #[
      ("title", .str "MCP OC Empty"), ("backend", .str "opencode"), ("prompt", .str ""),
      ("remote_node_id", .str "auto-managed:boat:small"), ("idempotency_key", .str "r17-r2-f4-mcp-oc")]) (some sup)
    let mcpEmptyOcMsg := ((mcpEmptyOc.fieldOrNull "error").fieldStr? "message").getD ""
    let managedCntAfterR2 ← execParamQuery mStore.db "SELECT COUNT(*) FROM managed_machines;" #[]
    check (restEmptyOcSt == 400 && restEmptyOcBody.contains "REMOTE_AUTH_REQUIRED" &&
      mcpEmptyOc.fieldBool? "ok" == some false && mcpEmptyOcMsg.contains "REMOTE_AUTH_REQUIRED" &&
      (managedCntAfterR2.toOption.bind (fun rs => rs[1]?.bind (·[0]?))) == some "0")
      s!"R17-R2-F4 empty-prompt opencode rejected with REMOTE_AUTH_REQUIRED before VM rental (rest={restEmptyOcSt})"
  finally
    match prevPub2 with | some v => setenvVar "SANDBOXED_PUBLIC_URL" v | none => pure ()
    match prevProxy2 with | some v => setenvVar "SANDBOXED_PROXY_PUBLIC_URL" v | none => pure ()

  -- R2-F5: short_description:null & github_pr:null clear DB; goal/effort backend checks; REST /settings parity
  discard <| msql
    "UPDATE missions SET short_description='old-desc', github_pr='owner/repo#1', repo='owner/repo#1', model_effort='xhigh', backend='codex', goal_mode=1, placement_kind='remote_node' WHERE id='m-r17-settings';"
  let umsClear ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("short_description", .null), ("github_pr", .null),
    ("idempotency_key", .str "r17-r2-f5-clear")])
  let clearedCols ← msql "SELECT COALESCE(short_description,''), COALESCE(github_pr,''), COALESCE(repo,'') FROM missions WHERE id='m-r17-settings';"
  check (umsClear.fieldBool? "ok" == some true && clearedCols.size > 1 &&
    clearedCols[1]![0]? == some "" && clearedCols[1]![1]? == some "" && clearedCols[1]![2]? == some "")
    s!"R17-R2-F5 update_mission_settings clears short_description and github_pr on null ({renderCompact umsClear})"
  let umsBadEffortSwitch ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("backend", .str "antigravity"),
    ("idempotency_key", .str "r17-r2-f5-badeff")])
  let umsBadEffortOpencode ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("backend", .str "opencode"),
    ("idempotency_key", .str "r17-r2-f5-badeff-oc")])
  let umsBadGoalSwitch ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("backend", .str "vibe"), ("model_effort", .null),
    ("idempotency_key", .str "r17-r2-f5-badgoal")])
  let (restBadBackendSt, _) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings" "{\"backend\":\"bogus\"}"
  let (restRetiredSt, _) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings" "{\"agent\":\"plan\"}"
  let (restBadEffortSt, _) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings" "{\"backend\":\"antigravity\"}"
  check ((umsBadEffortSwitch.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments" &&
    (umsBadEffortOpencode.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments" &&
    (umsBadGoalSwitch.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments" &&
    restBadBackendSt == 400 && restRetiredSt == 501 && restBadEffortSt == 400)
    s!"R17-R2-F5 enforces effort/goal compatibility and REST /settings parity (badB={restBadBackendSt}, ret={restRetiredSt}, badEff={restBadEffortSt})"

  -- Round 3 regressions (Findings 1–3)
  -- R3-F1: REST /settings accepts resume:false and service_tier:standard from first-party clients, refuses resume:true & service_tier:fast with 501
  let (r3ResFalseSt, r3ResFalseBody) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings"
    "{\"resume\":false,\"model_override\":\"gpt-5-r3\"}"
  let .ok r3ResFalseJv := OrbBin.Json.parse r3ResFalseBody | throw (IO.userError "R17-R3-F1 resume=false JSON")
  let (r3ResTrueSt, r3ResTrueBody) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings"
    "{\"resume\":true}"
  let (r3ResBadSt, _) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings"
    "{\"resume\":\"yes\"}"
  let (r3TierFastSt, r3TierFastBody) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings"
    "{\"resume\":false,\"service_tier\":\"fast\"}"
  let (r3TierStdSt, _) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings"
    "{\"resume\":false,\"service_tier\":\"standard\"}"
  let (r3TierBadSt, _) ← restRaw (some jwt) "PATCH" "/api/control/missions/m-r17-settings/settings"
    "{\"resume\":false,\"service_tier\":123}"
  let mcpResumeRej ← call operator "update_mission_settings" (.obj #[
    ("mission_id", .str "m-r17-settings"), ("resume", .bool false), ("idempotency_key", .str "r17-r3-f1-mcp-res")])
  check (r3ResFalseSt == 200 && r3ResFalseJv.fieldStr? "model_override" == some "gpt-5-r3" &&
    r3ResTrueSt == 501 && r3ResTrueBody.contains "unsupported" &&
    r3ResBadSt == 400 &&
    r3TierFastSt == 501 && r3TierFastBody.contains "unsupported" &&
    r3TierStdSt == 200 && r3TierBadSt == 400 &&
    (mcpResumeRej.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
    s!"R17-R3-F1 REST /settings honors resume:false/service_tier:standard and refuses resume:true/service_tier:fast with 501 (resF={r3ResFalseSt}, resT={r3ResTrueSt}, tierF={r3TierFastSt})"

  -- R3-F2: REST GET|POST /api/projects/:slug/grant includes nested grant object (or null before set) alongside top-level fields
  let (r3MkProjSt, _) ← restRaw (some jwt) "POST" "/api/projects" "{\"slug\":\"r17-grant-env\",\"title\":\"Grant Env\"}"
  let (r3GetEmptySt, r3GetEmptyBody) ← restRaw (some jwt) "GET" "/api/projects/r17-grant-env/grant" ""
  let .ok r3GetEmptyJv := OrbBin.Json.parse r3GetEmptyBody | throw (IO.userError "R17-R3-F2 empty grant JSON")
  let (r3PostGrSt, r3PostGrBody) ← restRaw (some jwt) "POST" "/api/projects/r17-grant-env/grant" "{\"parallel_missions\":3}"
  let .ok r3PostGrJv := OrbBin.Json.parse r3PostGrBody | throw (IO.userError "R17-R3-F2 post grant JSON")
  let (r3GetSetSt, r3GetSetBody) ← restRaw (some jwt) "GET" "/api/projects/r17-grant-env/grant" ""
  let .ok r3GetSetJv := OrbBin.Json.parse r3GetSetBody | throw (IO.userError "R17-R3-F2 get grant JSON")
  check (r3MkProjSt == 200 && r3GetEmptySt == 200 && r3GetEmptyJv.field? "grant" == some .null &&
    r3PostGrSt == 200 && (r3PostGrJv.fieldOrNull "grant").fieldNat? "parallel_missions" == some 3 &&
    r3PostGrJv.fieldNat? "parallel_missions" == some 3 &&
    r3GetSetSt == 200 && (r3GetSetJv.fieldOrNull "grant").fieldNat? "parallel_missions" == some 3)
    s!"R17-R3-F2 REST grant endpoints expose nested grant null/object envelope ({r3PostGrBody})"

  -- R3-F3: loopback static node resolves before pre-dispatch proxy check on auto/inherited/consult_model
  let supLoop ← OrbCore.RemoteDispatch.newRemoteJobSupervisor cfg.jwtSecret false
  supLoop.boundPortRef.set 39999
  let appLoop : CoreAppState := { app with remoteSup? := some supLoop }
  let prevPub3 ← IO.getEnv "SANDBOXED_PUBLIC_URL"
  let prevProxy3 ← IO.getEnv "SANDBOXED_PROXY_PUBLIC_URL"
  let prevRn3 ← IO.getEnv "SANDBOXED_REMOTE_NODES"
  unsetenvVar "SANDBOXED_PUBLIC_URL"
  unsetenvVar "SANDBOXED_PROXY_PUBLIC_URL"
  setenvVar "SANDBOXED_REMOTE_NODES" "r17loop=http://localhost:19999|tok,r17loop127=http://127.0.0.1:19999|tok"
  try
    discard <| msql
      ("INSERT INTO missions(id,title,status,backend,project,authority_mode,owner_user_id,tags,created_at,updated_at) " ++
       "VALUES('m-r17-loop-parent','Loop Parent','active','opencode','r17-project','writer','admin','[\"remote-node:r17loop127\"]','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
    let (restAutoLoopSt, restAutoLoopBody) ← restRaw (some jwt) "POST" "/api/control/missions"
      "{\"title\":\"Loop Auto\",\"backend\":\"opencode\",\"remote_node_id\":\"auto\"}" appLoop
    let mcpAutoLoop ← call operator "start_mission" (.obj #[
      ("title", .str "MCP Loop Auto"), ("backend", .str "opencode"), ("prompt", .str ""),
      ("remote_node_id", .str "auto"), ("idempotency_key", .str "r17-r3-f3-mcp-auto")]) (some supLoop)
    let mcpInhLoop ← call operator "start_mission" (.obj #[
      ("title", .str "MCP Loop Inherit"), ("backend", .str "opencode"), ("prompt", .str ""),
      ("parent_mission_id", .str "m-r17-loop-parent"), ("idempotency_key", .str "r17-r3-f3-mcp-inh")]) (some supLoop)
    let mcpConsultLoop ← call operator "consult_model" (.obj #[
      ("model", .str "builtin/smart"), ("question", .str "Loopback check"),
      ("idempotency_key", .str "r17-r3-f3-consult")]) (some supLoop)
    let consultMsg := ((mcpConsultLoop.fieldOrNull "error").fieldStr? "message").getD ""
    check (restAutoLoopSt == 201 &&
      mcpAutoLoop.fieldBool? "ok" == some true &&
      mcpInhLoop.fieldBool? "ok" == some true &&
      !consultMsg.contains "REMOTE_AUTH_REQUIRED" &&
      !consultMsg.contains "no_eligible_node")
      s!"R17-R3-F3 loopback static node passes proxy check for auto/inherited/consult_model (rest={restAutoLoopSt} {restAutoLoopBody}, auto={renderCompact mcpAutoLoop}, inh={renderCompact mcpInhLoop}, consult={consultMsg})"
    -- Non-loopback static node still refuses opencode without SANDBOXED_PUBLIC_URL before mission insert
    setenvVar "SANDBOXED_REMOTE_NODES" "r17rem=http://10.255.255.1:19999|tok"
    let beforeNonLoop ← msql "SELECT COUNT(*) FROM missions;"
    let (restNonLoopSt, restNonLoopBody) ← restRaw (some jwt) "POST" "/api/control/missions"
      "{\"title\":\"NonLoop Auto\",\"backend\":\"opencode\",\"remote_node_id\":\"auto\"}" appLoop
    let mcpNonLoop ← call operator "start_mission" (.obj #[
      ("title", .str "MCP NonLoop Inherit"), ("backend", .str "opencode"), ("prompt", .str ""),
      ("idempotency_key", .str "r17-r3-f3-mcp-nonloop")]) (some supLoop)
    let afterNonLoop ← msql "SELECT COUNT(*) FROM missions;"
    let mcpNonLoopMsg := ((mcpNonLoop.fieldOrNull "error").fieldStr? "message").getD ""
    check (restNonLoopSt == 400 && restNonLoopBody.contains "REMOTE_AUTH_REQUIRED" &&
      mcpNonLoop.fieldBool? "ok" == some false && mcpNonLoopMsg.contains "REMOTE_AUTH_REQUIRED" &&
      beforeNonLoop == afterNonLoop)
      s!"R17-R3-F3 non-loopback static node still rejects opencode without proxy URL before mission insert (rest={restNonLoopSt}, mcp={mcpNonLoopMsg})"
  finally
    match prevPub3 with | some v => setenvVar "SANDBOXED_PUBLIC_URL" v | none => unsetenvVar "SANDBOXED_PUBLIC_URL"
    match prevProxy3 with | some v => setenvVar "SANDBOXED_PROXY_PUBLIC_URL" v | none => unsetenvVar "SANDBOXED_PROXY_PUBLIC_URL"
    match prevRn3 with | some v => setenvVar "SANDBOXED_REMOTE_NODES" v | none => unsetenvVar "SANDBOXED_REMOTE_NODES"

def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore s!"{root}/r17"
    | throw (IO.userError "R17 store open failed")
  let .ok mStore ← openManagedComputeStore s!"{root}/r17/managed.db"
    | do closeCoreStore store; throw (IO.userError "R17 managed store open failed")
  try
    let now : UInt64 := 1700002000
    let cfg : CoreConfig := {
      workingDir := root, dashboardPassword := "r17-test-password",
      jwtSecret := "r17-test-jwt-secret-0123456789"
    }
    let bHub ← newBroadcastHub
    let app : CoreAppState := {
      bootstrapAdminId := "admin",
      cfg := cfg, store := store, searchIdx? := none,
      managedStore? := some mStore,
      managedRef := (← IO.mkRef ({} : ManagedFleetState)),
      chainsRef := (← IO.mkRef (#[] : Array RoutingChain)),
      proxyCooldownsRef := (← IO.mkRef (#[] : Array AccountCooldown)),
      seqRef := (← IO.mkRef (1 : UInt64)),
      broadcastHub? := some bHub
    }
    let sql (q : String) (params : Array String := #[]) := do
      let .ok rows ← execParamQuery store.projectsDb q params
        | throw (IO.userError "R17 fixture query failed")
      return rows
    discard <| sql "INSERT INTO projects(slug,name,title) VALUES('r17-project','r17','R17');"
    let operator : McpSessionClaims := {
      sessionId := "r17-op", missionId := "", role := "operator", project := "",
      expiresAt := now + 3600
    }
    let executor : McpSessionClaims := { operator with sessionId := "r17-exec", role := "executor" }
    let call (c : McpSessionClaims) (tool : String) (args : JVal) := do
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root c tool args now
      let .ok value := OrbBin.Json.parse raw | throw (IO.userError "R17 MCP JSON")
      return value
    let grantArgs (pause key : String) : JVal := .obj #[
      ("slug", .str "r17-project"), ("autonomy_level", .str "observe"),
      ("pause_reason", .str pause), ("idempotency_key", .str key)
    ]
    let granted ← call operator "set_project_grant" (grantArgs "hold" "r17-grant-1")
    check (granted.fieldBool? "ok" == some true) "MCP set_project_grant persists"
    check ((granted.fieldOrNull "result").fieldStr? "autonomy_level" == some "observe")
      "MCP set_project_grant reports stored grant"
    let conflict ← call operator "set_project_grant" (grantArgs "" "r17-grant-1")
    check ((conflict.fieldOrNull "error").fieldStr? "code" == some "conflict")
      "MCP set_project_grant rejects conflicting reuse of idempotency_key"
    let cleared ← call operator "set_project_grant" (grantArgs "" "r17-grant-2")
    check ((cleared.fieldOrNull "result").fieldOrNull "pause_reason" == .null)
      "MCP set_project_grant clears an explicit empty field"
    let denied ← call executor "set_project_grant" (grantArgs "hold" "r17-grant-3")
    check ((denied.fieldOrNull "error").fieldStr? "code" == some "forbidden")
      "MCP set_project_grant requires operator"
    for tool in #["start_workspace_job", "get_workspace_job", "cancel_workspace_job"] do
      let r ← call operator tool (.obj #[("job_id", .str "job-r17")])
      check ((r.fieldOrNull "error").fieldStr? "code" == some "not_implemented")
        s!"MCP {tool} is explicit not_implemented"
    for tool in #["create_worktree", "merge_branch", "create_workspace", "deploy_sandboxed_sh"] do
      let r ← call operator tool (.obj #[])
      check ((r.fieldOrNull "error").fieldStr? "code" == some "unsupported")
        s!"MCP {tool} is explicit unsupported"
    let .ok _ ← execParamQuery store.missionsDb
        "INSERT INTO users(id,username,password_hash,role) VALUES('admin','admin','synthetic-hash','admin');" #[]
      | throw (IO.userError "R17 admin fixture")
    let jwt := mintSessionTokenV2 cfg.jwtSecret "admin" "admin" 1 (now + 3600)
    let rest (method path body : String) := do
      let raw := s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "R17 REST parse")
      let .ok response ← dispatchCoreRequest app req now | throw (IO.userError "R17 REST dispatch")
      return (response.status, (String.fromUTF8? response.body).getD "")
    let (capStatus, capBody) ← rest "GET" "/api/capabilities" ""
    check (capStatus == 200) "GET /api/capabilities succeeds"
    let .ok cap := OrbBin.Json.parse capBody | throw (IO.userError "R17 capabilities JSON")
    check (((cap.fieldOrNull "capabilities").fieldOrNull "mission_dispatch").fieldBool? "available" == some true)
      "capabilities report mission dispatch availability"
    let (backupStatus, backupBody) ← rest "POST" "/api/settings/backup" ""
    check (backupStatus == 501 && backupBody.contains "unsupported")
      "POST /api/settings/backup is explicit unsupported"

    -- MCP-02: all/any waits, mixed wait states, and evidence-bound reconciliation
    discard <| sql
      "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('r17-op','admin','',?1,0,'operator'),('r17-exec','admin','',?1,0,'mission');"
      #[toString (now + 3600)]
    discard <| sql
      "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES('r17-project','admin','2026-11-18T00:00:00Z');"
    let msql (q : String) (params : Array String := #[]) := do
      let .ok rows ← execParamQuery store.missionsDb q params
        | throw (IO.userError "R17 missions fixture query failed")
      return rows
    let insertAction (aid state resultJson : String) := do
      discard <| sql
        ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
         "VALUES(?1,'','r17-op::test_tool',?2,'{}','operator::','test_tool','{}',?3,?4,'2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
        #[aid, "rk-" ++ aid, state, resultJson]
    insertAction "r17-act-ok" "succeeded" "{\"ok\":true,\"note\":\"original\"}"
    insertAction "r17-act-fail" "failed" "{\"error\":\"boom\",\"code\":\"failed\"}"
    insertAction "r17-act-pend" "accepted" "{}"
    insertAction "r17-act-unc-ok" "uncertain" "{\"error\":\"transport_lost\"}"
    insertAction "r17-act-unc-rej" "reconciliation_required" "{\"error\":\"restart_fenced\"}"
    insertAction "r17-act-live-1" "accepted" "{}"
    insertAction "r17-act-live-2" "running" "{}"

    let waitEmpty ← call operator "wait_actions" (.obj #[("action_ids", .arr #[])])
    check ((waitEmpty.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      "MCP-02 wait_actions refuses empty action_ids"
    let waitBadWhen ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-ok"]), ("return_when", .str "mostly")])
    check ((waitBadWhen.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      "MCP-02 wait_actions refuses invalid return_when"
    let waitBadTimeout ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-ok"]), ("timeout_ms", .str "nope")])
    check ((waitBadTimeout.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      "MCP-02 wait_actions refuses non-integer timeout_ms"

    let waitMixedFail ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-ok", .str "r17-act-fail"]),
      ("return_when", .str "all"), ("timeout_ms", .nat 50)])
    let wmfRes := waitMixedFail.fieldOrNull "result"
    check (waitMixedFail.fieldBool? "ok" == some true &&
      wmfRes.fieldBool? "all_settled" == some true &&
      wmfRes.fieldBool? "all_succeeded" == some false &&
      wmfRes.fieldBool? "timed_out" == some false &&
      wmfRes.fieldNat? "settled_count" == some 2 &&
      wmfRes.fieldNat? "pending_count" == some 0)
      "MCP-02 wait_actions mixed [succeeded, failed] is settled with all_succeeded=false"

    let waitMixedUnc ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-ok", .str "r17-act-unc-ok"]),
      ("return_when", .str "all"), ("timeout_ms", .nat 50)])
    let wmuRes := waitMixedUnc.fieldOrNull "result"
    check (waitMixedUnc.fieldBool? "ok" == some true &&
      wmuRes.fieldBool? "all_settled" == some true &&
      wmuRes.fieldBool? "all_succeeded" == some false &&
      wmuRes.fieldBool? "timed_out" == some false)
      "MCP-02 wait_actions mixed [succeeded, uncertain] is settled with all_succeeded=false"

    let waitAnyImmediate ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-ok", .str "r17-act-pend"]),
      ("return_when", .str "any"), ("timeout_ms", .nat 500)])
    let waiRes := waitAnyImmediate.fieldOrNull "result"
    check (waitAnyImmediate.fieldBool? "ok" == some true &&
      waiRes.fieldStr? "return_when" == some "any" &&
      waiRes.fieldBool? "timed_out" == some false &&
      waiRes.fieldBool? "all_settled" == some false &&
      waiRes.fieldBool? "all_succeeded" == some false &&
      waiRes.fieldNat? "settled_count" == some 1 &&
      waiRes.fieldNat? "pending_count" == some 1 &&
      waiRes.fieldArr? "pending_action_ids" == some #[.str "r17-act-pend"])
      "MCP-02 wait_actions return_when=any returns immediately on mixed [succeeded, pending]"

    let waitAllTimeout ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-ok", .str "r17-act-pend"]),
      ("return_when", .str "all"), ("timeout_ms", .nat 40)])
    let watRes := waitAllTimeout.fieldOrNull "result"
    check (waitAllTimeout.fieldBool? "ok" == some true &&
      watRes.fieldStr? "return_when" == some "all" &&
      watRes.fieldBool? "timed_out" == some true &&
      watRes.fieldBool? "all_settled" == some false &&
      watRes.fieldBool? "all_succeeded" == some false &&
      watRes.fieldNat? "settled_count" == some 1 &&
      watRes.fieldNat? "pending_count" == some 1 &&
      watRes.fieldArr? "pending_action_ids" == some #[.str "r17-act-pend"])
      "MCP-02 wait_actions return_when=all times out when one action remains pending"

    let bgSettle1 ← IO.asTask (prio := .dedicated) do
      IO.sleep 25
      discard <| execParamQuery store.projectsDb
        "UPDATE mcp_actions_v1 SET state='succeeded', result='{\"ok\":true}' WHERE id='r17-act-live-1';" #[]
    let waitLiveAny ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-live-1", .str "r17-act-live-2"]),
      ("return_when", .str "any"), ("timeout_ms", .nat 1000)])
    discard <| IO.ofExcept bgSettle1.get
    let wlaRes := waitLiveAny.fieldOrNull "result"
    check (waitLiveAny.fieldBool? "ok" == some true &&
      wlaRes.fieldBool? "timed_out" == some false &&
      wlaRes.fieldBool? "all_settled" == some false &&
      wlaRes.fieldNat? "settled_count" == some 1 &&
      wlaRes.fieldNat? "pending_count" == some 1)
      "MCP-02 wait_actions return_when=any wakes as soon as first action settles"

    let bgSettle2 ← IO.asTask (prio := .dedicated) do
      IO.sleep 25
      discard <| execParamQuery store.projectsDb
        "UPDATE mcp_actions_v1 SET state='succeeded', result='{\"ok\":true}' WHERE id='r17-act-live-2';" #[]
    let waitLiveAll ← call operator "wait_actions" (.obj #[
      ("action_ids", .arr #[.str "r17-act-live-1", .str "r17-act-live-2"]),
      ("return_when", .str "all"), ("timeout_ms", .nat 1000)])
    discard <| IO.ofExcept bgSettle2.get
    let wlallRes := waitLiveAll.fieldOrNull "result"
    check (waitLiveAll.fieldBool? "ok" == some true &&
      wlallRes.fieldBool? "timed_out" == some false &&
      wlallRes.fieldBool? "all_settled" == some true &&
      wlallRes.fieldBool? "all_succeeded" == some true &&
      wlallRes.fieldNat? "settled_count" == some 2 &&
      wlallRes.fieldNat? "pending_count" == some 0)
      "MCP-02 wait_actions return_when=all waits until every action settles"

    -- MCP-02 reconciliation: operator-only, evidence-bound, refuses settled/pending rewrites
    let recExecDenied ← call executor "reconcile_action" (.obj #[
      ("action_id", .str "r17-act-unc-ok"), ("resolution", .str "completed"),
      ("evidence", .str "checked"), ("idempotency_key", .str "r17-rec-denied")])
    check ((recExecDenied.fieldOrNull "error").fieldStr? "code" == some "forbidden")
      "MCP-02 reconcile_action requires operator role"

    let recNoEvidence ← call operator "reconcile_action" (.obj #[
      ("action_id", .str "r17-act-unc-ok"), ("resolution", .str "completed"),
      ("evidence", .str "   "), ("idempotency_key", .str "r17-rec-noev")])
    check ((recNoEvidence.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      "MCP-02 reconcile_action rejects blank evidence"

    let recBadRes ← call operator "reconcile_action" (.obj #[
      ("action_id", .str "r17-act-unc-ok"), ("resolution", .str "maybe"),
      ("evidence", .str "checked"), ("idempotency_key", .str "r17-rec-badres")])
    check ((recBadRes.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      "MCP-02 reconcile_action rejects invalid resolution"

    let recMissingKey ← call operator "reconcile_action" (.obj #[
      ("action_id", .str "r17-act-unc-ok"), ("resolution", .str "completed"),
      ("evidence", .str "checked")])
    check ((recMissingKey.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      "MCP-02 reconcile_action requires idempotency_key"

    for (aid, label) in #[("r17-act-ok", "succeeded"), ("r17-act-fail", "failed"), ("r17-act-pend", "accepted")] do
      let refused ← call operator "reconcile_action" (.obj #[
        ("action_id", .str aid), ("resolution", .str "rejected"),
        ("evidence", .str "attempt rewrite"), ("idempotency_key", .str s!"r17-refuse-{aid}")])
      check ((refused.fieldOrNull "error").fieldStr? "code" == some "invalid_state")
        s!"MCP-02 reconcile_action refuses to rewrite {label} receipt"
    let okRows ← sql "SELECT state, result FROM mcp_actions_v1 WHERE id='r17-act-ok';"
    check (okRows.size > 1 && okRows[1]![0]? == some "succeeded" &&
      (okRows[1]![1]?.getD "").contains "original")
      "MCP-02 refused reconciliation leaves settled receipt untouched"

    let recOkArgs : JVal := .obj #[
      ("action_id", .str "r17-act-unc-ok"), ("resolution", .str "completed"),
      ("evidence", .str "Verified target exists on node-a"),
      ("idempotency_key", .str "r17-rec-ok-1")]
    let recOk ← call operator "reconcile_action" recOkArgs
    let recOkRes := recOk.fieldOrNull "result"
    check (recOk.fieldBool? "ok" == some true &&
      recOkRes.fieldStr? "target_action_id" == some "r17-act-unc-ok" &&
      recOkRes.fieldStr? "evidence" == some "Verified target exists on node-a" &&
      (recOkRes.fieldOrNull "receipt").fieldStr? "state" == some "succeeded")
      "MCP-02 reconcile_action settles uncertain action as completed with evidence"
    let readRecOk ← call operator "get_action" (.obj #[("action_id", .str "r17-act-unc-ok")])
    let readRecOkRes := readRecOk.fieldOrNull "result"
    check (readRecOk.fieldBool? "ok" == some true &&
      readRecOkRes.fieldStr? "state" == some "succeeded" &&
      readRecOkRes.fieldStr? "status" == some "completed" &&
      readRecOkRes.fieldStr? "accepted" == some "yes" &&
      (readRecOkRes.fieldOrNull "result").fieldBool? "reconciled" == some true &&
      (readRecOkRes.fieldOrNull "result").fieldStr? "evidence" == some "Verified target exists on node-a")
      "MCP-02 get_action exposes persisted reconciliation evidence"

    let recOkReplay ← call operator "reconcile_action" recOkArgs
    check (recOkReplay.fieldBool? "ok" == some true &&
      (recOkReplay.fieldOrNull "result").fieldStr? "action_id" == recOkRes.fieldStr? "action_id")
      "MCP-02 reconcile_action replays identically under same idempotency_key"
    let recOkConflict ← call operator "reconcile_action" (recOkArgs.setField "evidence" (.str "mutated evidence"))
    check ((recOkConflict.fieldOrNull "error").fieldStr? "code" == some "conflict")
      "MCP-02 reconcile_action rejects conflicting arguments for same idempotency_key"
    let recOkRewrite ← call operator "reconcile_action" (.obj #[
      ("action_id", .str "r17-act-unc-ok"), ("resolution", .str "rejected"),
      ("evidence", .str "flip after settlement"), ("idempotency_key", .str "r17-rec-ok-2")])
    check ((recOkRewrite.fieldOrNull "error").fieldStr? "code" == some "invalid_state")
      "MCP-02 reconcile_action refuses rewriting an already-reconciled receipt"

    let recRej ← call operator "reconcile_action" (.obj #[
      ("action_id", .str "r17-act-unc-rej"), ("resolution", .str "rejected"),
      ("evidence", .str "Confirmed zero target mutations"), ("idempotency_key", .str "r17-rec-rej-1")])
    check (recRej.fieldBool? "ok" == some true &&
      ((recRej.fieldOrNull "result").fieldOrNull "receipt").fieldStr? "state" == some "rejected")
      "MCP-02 reconcile_action settles reconciliation_required as rejected with evidence"
    let readRecRej ← call operator "get_action" (.obj #[("action_id", .str "r17-act-unc-rej")])
    let readRecRejRes := readRecRej.fieldOrNull "result"
    check (readRecRej.fieldBool? "ok" == some true &&
      readRecRejRes.fieldStr? "state" == some "rejected" &&
      readRecRejRes.fieldStr? "accepted" == some "no" &&
      (readRecRejRes.fieldOrNull "result").fieldStr? "evidence" == some "Confirmed zero target mutations")
      "MCP-02 rejected reconciliation persists accepted=no and evidence"

    -- MCP-06: consult polls return done + terminal answer; quorum is explicitly refused
    let beforeConsultMissions ← msql "SELECT COUNT(*) FROM missions;"
    let quorumModels ← call operator "consult_model" (.obj #[
      ("models", .arr #[.str "openai/gpt-6-astra", .str "anthropic/claude-fable-5-2"]),
      ("question", .str "Compare these two implementations"),
      ("idempotency_key", .str "r17-quorum-1")])
    check (quorumModels.fieldBool? "ok" == some false &&
      (quorumModels.fieldOrNull "error").fieldStr? "code" == some "unsupported" &&
      (quorumModels.fieldOrNull "result").fieldStr? "state" == some "failed")
      "MCP-06 consult_model refuses models quorum with explicit unsupported"

    let quorumMixed ← call operator "consult_model" (.obj #[
      ("model", .str "gpt-6-astra"),
      ("models", .arr #[.str "gpt-6-astra", .str "fable-5.2"]),
      ("question", .str "Compare"),
      ("idempotency_key", .str "r17-quorum-2")])
    check (quorumMixed.fieldBool? "ok" == some false &&
      (quorumMixed.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      "MCP-06 consult_model refuses models array even when single model is also supplied"

    let quorumFlag ← call operator "consult_model" (.obj #[
      ("model", .str "gpt-6-astra"),
      ("quorum", .bool true),
      ("question", .str "Review"),
      ("idempotency_key", .str "r17-quorum-3")])
    check (quorumFlag.fieldBool? "ok" == some false &&
      (quorumFlag.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      "MCP-06 consult_model refuses quorum=true with explicit unsupported"
    let afterConsultMissions ← msql "SELECT COUNT(*) FROM missions;"
    check (beforeConsultMissions == afterConsultMissions)
      "MCP-06 refused quorum consult_model creates zero missions"

    let batchPoll ← call operator "get_consult_result" (.obj #[
      ("mission_ids", .arr #[.str "m-consult-1", .str "m-consult-2"])])
    check (batchPoll.fieldBool? "ok" == some false &&
      (batchPoll.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      "MCP-06 get_consult_result refuses batch mission_ids with explicit unsupported"

    discard <| msql
      ("INSERT INTO missions(id,title,status,backend,model_override,project,authority_mode,owner_user_id,created_at,updated_at) " ++
       "VALUES('m-consult-1','Consult','active','opencode','openai/gpt-6-astra','r17-project','readonly','admin','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
    let pollRunning ← call operator "get_consult_result" (.obj #[("mission_id", .str "m-consult-1")])
    let prRes := pollRunning.fieldOrNull "result"
    check (pollRunning.fieldBool? "ok" == some true &&
      prRes.fieldStr? "mission_id" == some "m-consult-1" &&
      prRes.fieldStr? "status" == some "active" &&
      prRes.fieldBool? "done" == some false &&
      prRes.fieldStr? "model" == some "openai/gpt-6-astra" &&
      (prRes.field? "answer").isNone &&
      (prRes.fieldStr? "next").isSome)
      "MCP-06 get_consult_result reports done=false without answer while active"

    discard <| appendMissionEvent store "m-consult-1" "assistant_message"
      "{\"content\":\"Intermediate draft\"}" "2026-11-18T00:00:05Z"
    discard <| appendMissionEvent store "m-consult-1" "assistant_message"
      "{\"content\":\"Final verified consult answer.\"}" "2026-11-18T00:00:10Z"
    discard <| msql "UPDATE missions SET status='completed' WHERE id='m-consult-1';"
    let pollDone ← call operator "get_consult_result" (.obj #[("mission_id", .str "m-consult-1")])
    let pdRes := pollDone.fieldOrNull "result"
    check (pollDone.fieldBool? "ok" == some true &&
      pdRes.fieldStr? "status" == some "completed" &&
      pdRes.fieldBool? "done" == some true &&
      pdRes.fieldStr? "model" == some "openai/gpt-6-astra" &&
      pdRes.fieldStr? "answer" == some "Final verified consult answer." &&
      (pdRes.fieldArr? "served_models").isSome)
      "MCP-06 get_consult_result returns done=true and latest terminal answer when completed"

    discard <| msql "UPDATE missions SET status='awaiting_user' WHERE id='m-consult-1';"
    let pollAwaiting ← call operator "get_consult_result" (.obj #[("mission_id", .str "m-consult-1")])
    let paRes := pollAwaiting.fieldOrNull "result"
    check (pollAwaiting.fieldBool? "ok" == some true &&
      paRes.fieldBool? "done" == some true &&
      paRes.fieldStr? "answer" == some "Final verified consult answer.")
      "MCP-06 get_consult_result returns done=true and terminal answer on awaiting_user"

    discard <| msql
      ("INSERT INTO missions(id,title,status,backend,model_override,project,authority_mode,owner_user_id,created_at,updated_at) " ++
       "VALUES('m-consult-failed','Consult failed','failed','opencode','openai/gpt-6-astra','r17-project','readonly','admin','2026-11-18T00:00:00Z','2026-11-18T00:00:00Z');")
    let pollFailed ← call operator "get_consult_result" (.obj #[("mission_id", .str "m-consult-failed")])
    let pfRes := pollFailed.fieldOrNull "result"
    check (pollFailed.fieldBool? "ok" == some true &&
      pfRes.fieldStr? "status" == some "failed" &&
      pfRes.fieldBool? "done" == some true &&
      pfRes.fieldOrNull "answer" == .null)
      "MCP-06 get_consult_result reports done=true and null answer when failed without reply"

    -- MCP-11: align update_project_status schema & runtime; never acknowledge discarded steer IDs
    for role in #["coordinator", "operator"] do
      let some rawCat := OrbBin.McpCatalog.catalogPrettyJsonForRole role
        | throw (IO.userError s!"R17 missing catalog for {role}")
      let .ok (.arr catTools) := OrbBin.Json.parse rawCat
        | throw (IO.userError s!"R17 invalid catalog JSON for {role}")
      let some updTool := catTools.find? (fun t => t.fieldStr? "name" == some "update_project_status")
        | throw (IO.userError s!"R17 missing update_project_status in {role} catalog")
      let schema := updTool.fieldOrNull "inputSchema"
      let props := schema.fieldOrNull "properties"
      let req := (schema.fieldArr? "required").getD #[]
      check ((props.field? "consumed_steer_ids").isNone &&
        (props.field? "mode").isNone &&
        (props.field? "status").isSome &&
        (props.field? "slug").isSome &&
        (props.field? "idempotency_key").isSome &&
        req.contains (.str "slug") &&
        req.contains (.str "status") &&
        req.contains (.str "idempotency_key") &&
        !req.contains (.str "mode"))
        s!"MCP-11 {role} McpCatalog update_project_status schema drops steers/mode and requires status"

    discard <| sql "INSERT INTO project_steers(id,slug,body,created_at,consumed_at) VALUES('r17-steer-1','r17-project','legacy steer','2026-11-18T00:00:00Z',NULL);"
    let statusWithSteers ← call operator "update_project_status" (.obj #[
      ("slug", .str "r17-project"), ("status", .str "paused"),
      ("consumed_steer_ids", .arr #[.str "r17-steer-1"]),
      ("idempotency_key", .str "r17-st-steer")])
    check (statusWithSteers.fieldBool? "ok" == some false &&
      (statusWithSteers.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      "MCP-11 update_project_status refuses consumed_steer_ids instead of discarding"
    let steerCheck ← sql "SELECT COALESCE(consumed_at,'') FROM project_steers WHERE id='r17-steer-1';"
    let projStatusBefore ← sql "SELECT status FROM projects WHERE slug='r17-project';"
    check (steerCheck.size > 1 && steerCheck[1]![0]? == some "" &&
      projStatusBefore.size > 1 && projStatusBefore[1]![0]? == some "active")
      "MCP-11 refused steer call leaves steer unconsumed and project status unchanged"

    let statusWithMode ← call operator "update_project_status" (.obj #[
      ("slug", .str "r17-project"), ("status", .str "paused"), ("mode", .str "autonomous"),
      ("idempotency_key", .str "r17-st-mode")])
    check ((statusWithMode.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      "MCP-11 update_project_status refuses retired mode field"

    let statusExecDenied ← call executor "update_project_status" (.obj #[
      ("slug", .str "r17-project"), ("status", .str "paused"), ("idempotency_key", .str "r17-st-exec")])
    check ((statusExecDenied.fieldOrNull "error").fieldStr? "code" == some "forbidden")
      "MCP-11 update_project_status rejects executor role"

    let statusMissing ← call operator "update_project_status" (.obj #[
      ("slug", .str "r17-project"), ("idempotency_key", .str "r17-st-nostatus")])
    check ((statusMissing.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      "MCP-11 update_project_status refuses omitted status instead of defaulting to active"

    let statusUnknownProj ← call operator "update_project_status" (.obj #[
      ("slug", .str "r17-missing-project"), ("status", .str "paused"),
      ("idempotency_key", .str "r17-st-missing")])
    check ((statusUnknownProj.fieldOrNull "error").fieldStr? "code" == some "not_found")
      "MCP-11 update_project_status refuses unknown project instead of creating one"

    let statusOk ← call operator "update_project_status" (.obj #[
      ("slug", .str "r17-project"), ("status", .str "paused"),
      ("idempotency_key", .str "r17-st-ok")])
    let statusOkRes := statusOk.fieldOrNull "result"
    check (statusOk.fieldBool? "ok" == some true &&
      (statusOkRes.fieldOrNull "project").fieldStr? "status" == some "paused" &&
      (statusOkRes.field? "consumed_steer_ids").isNone &&
      (statusOkRes.field? "acknowledged_steer_ids").isNone)
      "MCP-11 update_project_status updates status cleanly without acknowledging steers"
    let steerStillUnconsumed ← sql "SELECT COALESCE(consumed_at,'') FROM project_steers WHERE id='r17-steer-1';"
    check (steerStillUnconsumed.size > 1 && steerStillUnconsumed[1]![0]? == some "")
      "MCP-11 valid status update never marks retired steers consumed"

    runExtendedChecks root store cfg app now jwt operator cap
    runFleetProvSecChecks root store app now jwt operator
    runCarbonRegressionChecks root store mStore cfg app now jwt operator
  finally
    closeManagedComputeStore mStore
    closeCoreStore store

end OrbCore.R17Tests
