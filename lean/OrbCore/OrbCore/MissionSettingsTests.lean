import OrbCore.Control

namespace OrbCore.MissionSettingsTests

open LeanSys.Http OrbBin.Json OrbBin.PosixExt
open OrbCore.Store OrbCore.Control OrbCore.Managed OrbCore.Proxy OrbCore.R7Core OrbCore.MemoryAndCloud

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"mission settings: {label}")

def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore s!"{root}/mission-settings"
    | throw (IO.userError "settings store open failed")
  try
    let now : UInt64 := 1700001000
    let cfg : CoreConfig := {
      workingDir := root, dashboardPassword := "settings-test-password",
      jwtSecret := "settings-test-jwt-secret-0123456789"
    }
    let app : CoreAppState := {
      cfg := cfg, store := store, searchIdx? := none,
      managedRef := (← IO.mkRef ({} : ManagedFleetState)),
      chainsRef := (← IO.mkRef (#[] : Array RoutingChain)),
      proxyCooldownsRef := (← IO.mkRef (#[] : Array AccountCooldown)),
      seqRef := (← IO.mkRef (1 : UInt64))
    }
    let sql (q : String) (params : Array String := #[]) := do
      let .ok rows ← execParamQuery store.missionsDb q params
        | throw (IO.userError "settings fixture query failed")
      return rows
    for (id, parent, owner, project) in #[
        ("parent", "", "alice", "p"), ("rest", "parent", "alice", "p"),
        ("mcp", "parent", "alice", "p"), ("grandchild", "mcp", "alice", "p"),
        ("unrelated", "", "alice", "p"), ("foreign", "parent", "bob", "p"),
        ("other-project", "parent", "alice", "q")] do
      discard <| sql
        ("INSERT INTO missions(id,title,backend,model_override,model_effort,session_id,resumable," ++
         "project,folder,placement_revision,parent_mission_id,owner_user_id) " ++
         "VALUES(?1,'before','claudecode','claude-model','high','claude-session',1,?4,'folder',7,?2,?3);")
        #[id, parent, owner, project]
    let claims : McpSessionClaims := {
      sessionId := "settings-session", missionId := "parent", role := "executor", project := "p", expiresAt := now + 3600
    }
    let call (c : McpSessionClaims) (mid : String) (patch : JVal) := do
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root c
        "update_mission_settings" (patch.setField "mission_id" (.str mid)) now
      let .ok value := OrbBin.Json.parse raw | throw (IO.userError "settings MCP JSON")
      return value
    let rest (patch : JVal) := do
      let body := renderCompact patch
      let jwt := mintSessionToken cfg.jwtSecret (now + 3600)
      let raw := s!"PATCH /api/control/missions/rest/settings HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "settings REST parse")
      let .ok response ← dispatchCoreRequest app req now | throw (IO.userError "settings REST dispatch")
      return response.status
    let snapshot (mid : String) := do
      let rows ← sql
        ("SELECT title,backend,COALESCE(model_override,''),COALESCE(model_effort,''),COALESCE(session_id,'')," ++
         "resumable,project,folder,placement_revision,state_revision,metadata_updated_at FROM missions WHERE id=?1;") #[mid]
      return rows[1]!
    let switched : JVal := .obj #[("backend", .str "codex"), ("model_override", .str "gpt-model"),
      ("model_effort", .str " XHIGH "), ("title", .str "after")]
    check ((← rest switched) == 200) "REST Claude to Codex"
    check ((← call claims "mcp" switched).fieldBool? "ok" == some true) "MCP Claude to Codex"
    let first ← snapshot "mcp"
    check (first[1]! == "codex" && first[2]! == "gpt-model" && first[3]! == "xhigh" &&
      first[4]! == "" && first[5]! == "0" && first[8]! == "7") "switch clears session but preserves placement"
    check ((← snapshot "rest") == first) "REST MCP switch parity"
    for mid in #["rest", "mcp"] do
      discard <| sql "UPDATE missions SET session_id='codex-session',resumable=1 WHERE id=?1;" #[mid]
    let same : JVal := .obj #[("backend", .str "codex"), ("model_override", .str "gpt-next")]
    check ((← rest same) == 200 && (← call claims "mcp" same).fieldBool? "ok" == some true) "same backend accepted"
    let retained ← snapshot "mcp"
    check (retained[4]! == "codex-session" && retained[5]! == "1" && (← snapshot "rest") == retained)
      "same backend model edits retain session on both paths"
    let invalid : JVal := .obj #[("backend", .str "antigravity"), ("model_effort", .str "max"),
      ("title", .str "must-not-persist"), ("project", .str "q")]
    check ((← rest invalid) == 400 && (← call claims "mcp" invalid).fieldBool? "ok" == some false)
      "invalid effort rejected on both paths"
    check ((← snapshot "mcp") == retained && (← snapshot "rest") == retained) "invalid patch is atomic"
    check ((← call claims "grandchild" same).fieldBool? "ok" == some true) "descendant mutation allowed"
    check ((← call { claims with missionId := "mcp" } "mcp" same).fieldBool? "ok" == some true) "self mutation allowed"
    for mid in #["unrelated", "foreign", "other-project", "missing"] do
      for role in #["executor", "coordinator", "operator"] do
        let before ← sql "SELECT * FROM missions WHERE id=?1;" #[mid]
        check ((← call { claims with role } mid switched).fieldBool? "ok" == some false) s!"deny {role}/{mid}"
        check ((← sql "SELECT * FROM missions WHERE id=?1;" #[mid]) == before) "denied mutation leaves row unchanged"
    IO.FS.writeFile s!"{store.rootDir}/mission_access.json"
      "{\"grants\":[{\"requester_mission_id\":\"parent\",\"target_mission_id\":\"unrelated\",\"status\":\"approved\",\"expires_at\":\"2099-01-01T00:00:00Z\"}]}"
    check (← OrbCore.SecretAndApproval.hasApprovedMissionReadAccess store.rootDir "parent" "unrelated" now)
      "read grant fixture is active"
    let before ← snapshot "unrelated"
    check ((← call claims "unrelated" switched).fieldBool? "ok" == some false && (← snapshot "unrelated") == before)
      "read grant does not authorize mutation"
    let operator : McpSessionClaims := {
      sessionId := "00000000-0000-4000-8000-000000000000", missionId := "", role := "operator", expiresAt := now + 3600
    }
    let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root operator
      "update_mission_settings" (same.setField "mission_id" (.str "unrelated")) now none none "alice"
    check (((OrbBin.Json.parse raw).toOption.getD .null).fieldBool? "ok" == some true) "trusted owner operator"
    check ((← call operator "unrelated" switched).fieldBool? "ok" == some false) "role alone is not operator authority"
    let cleared : JVal := .obj #[("model_override", .null), ("model_effort", .null)]
    check ((← rest cleared) == 200 && (← call claims "mcp" cleared).fieldBool? "ok" == some true)
      "explicit null clears model and effort"
    let clearedRow ← snapshot "mcp"
    let clearedRest ← snapshot "rest"
    check (clearedRow[2]! == "" && clearedRow[3]! == "" && clearedRow[4]! == "codex-session" &&
      clearedRest[2]! == "" && clearedRest[3]! == "" && clearedRest[4]! == "codex-session")
      "null patch parity preserves session"
    let move : JVal := .obj #[("project", .str "q"), ("folder", .str "moved")]
    check ((← rest move) == 200) "REST placement patch"
    let moved ← snapshot "rest"
    check (moved[6]! == "q" && moved[7]! == "moved" && moved[8]! == "8" && moved[4]! == "codex-session")
      "REST placement revision changes once and preserves session"
  finally
    closeCoreStore store

end OrbCore.MissionSettingsTests
