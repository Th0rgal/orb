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
    let grantArgs (pause : String) : JVal := .obj #[
      ("slug", .str "r17-project"), ("autonomy_level", .str "observe"),
      ("pause_reason", .str pause), ("idempotency_key", .str "r17-grant-1")
    ]
    let granted ← call operator "set_project_grant" (grantArgs "hold")
    check (granted.fieldBool? "ok" == some true) "MCP set_project_grant persists"
    check ((granted.fieldOrNull "result").fieldStr? "autonomy_level" == some "observe")
      "MCP set_project_grant reports stored grant"
    let cleared ← call operator "set_project_grant" (grantArgs "")
    check ((cleared.fieldOrNull "result").fieldOrNull "pause_reason" == .null)
      "MCP set_project_grant clears an explicit empty field"
    let denied ← call executor "set_project_grant" (grantArgs "hold")
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
  finally
    closeCoreStore store

end OrbCore.R17Tests
