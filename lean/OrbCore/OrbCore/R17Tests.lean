import OrbCore.Control

namespace OrbCore.R17Tests

open LeanSys.Http OrbBin.Json OrbBin.PosixExt
open OrbCore.Store OrbCore.Control OrbCore.Managed OrbCore.Proxy OrbCore.R7Core
open OrbCore.MemoryAndCloud OrbCore.LegacyHydrate

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"R17: {label}")
  IO.println s!"PASS {label}"

def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore s!"{root}/r17"
    | throw (IO.userError "R17 store open failed")
  try
    let now : UInt64 := 1700002000
    let cfg : CoreConfig := {
      workingDir := root, dashboardPassword := "r17-test-password",
      jwtSecret := "r17-test-jwt-secret-0123456789"
    }
    let bHub ← newBroadcastHub
    let app : CoreAppState := {
      cfg := cfg, store := store, searchIdx? := none,
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
  finally
    closeCoreStore store

end OrbCore.R17Tests
