import OrbCore.Control

namespace OrbCore.MissionSettingsTests

open LeanSys.Http OrbBin.Json OrbBin.PosixExt
open OrbCore.Store OrbCore.Control OrbCore.Managed OrbCore.Proxy OrbCore.R7Core OrbCore.MemoryAndCloud OrbCore.LegacyHydrate

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"mission settings: {label}")
  if label.startsWith "B5_" || label.startsWith "B5b_" then IO.println s!"PASS {label}"

def moveRecovery (root : String) : IO Unit := do
  let path := s!"{root}/b5b-recovery"
  let .ok store ← openCoreStore path | throw (IO.userError "B5b open")
  let sql (db : SqliteDb) (q : String) := do
    let .ok rows ← execParamQuery db q #[] | throw (IO.userError s!"B5b query: {q}")
    return rows
  try
    for family in #["a", "b"] do
      for (suffix, parent) in #[("root", ""), ("child", family ++ "root"), ("deep", family ++ "child")] do
        let id := family ++ suffix
        discard <| sql store.missionsDb s!"INSERT INTO missions(id,project,parent_mission_id,owner_user_id) VALUES('{id}','source','{parent}','alice');"
        discard <| sql store.projectsDb s!"INSERT INTO mcp_sessions_v1(id,mission_id,project_scope,project_scoped) VALUES('{id}','{id}','source',1);"
        discard <| sql store.projectsDb s!"INSERT INTO project_track_leases(project_slug,track,reservation_id,mission_id,phase) VALUES('source','{id}','{id}','{id}','active');"
    discard <| sql store.projectsDb "CREATE TRIGGER reject_rebind BEFORE UPDATE ON mcp_sessions_v1 BEGIN SELECT RAISE(ABORT,'injected crash boundary'); END;"
    for id in #["aroot", "broot"] do
      let some mr ← getMission? store id | throw (IO.userError "B5b fixture missing")
      let result ← OrbCore.MissionSettings.applyPlacementPatch store mr
        (.obj #[("project", .str "destination")]) "alice" true "" "t1" 1000
      check (!result.isOk) "B5b injected post-commit failure"
    discard <| sql store.projectsDb "DROP TRIGGER reject_rebind;"
  finally closeCoreStore store
  OrbCore.MissionMoveRecovery.startup path
  let .ok reopened ← openCoreStore path | throw (IO.userError "B5b reopen")
  try
    let missions ← sql reopened.missionsDb "SELECT project FROM missions ORDER BY id;"
    let sessions ← sql reopened.projectsDb "SELECT project_scope FROM mcp_sessions_v1 ORDER BY id;"
    let leases ← sql reopened.projectsDb "SELECT project_slug FROM project_track_leases ORDER BY mission_id;"
    check (missions.size == 7 && sessions.size == 7 && leases.size == 7 &&
      (missions.extract 1 missions.size).all (fun r => r[0]! == "destination") &&
      (sessions.extract 1 sessions.size).all (fun r => r[0]! == "destination") &&
      (leases.extract 1 leases.size).all (fun r => r[0]! == "destination"))
      "B5b_crash_between_commits_startup_repairs_two_families"
    check ((← OrbCore.MissionMoveRecovery.pending reopened.missionsDb).toOption == some #[])
      "B5b_recovery_clears_markers"
    discard <| sql reopened.missionsDb "CREATE TRIGGER reject_settings BEFORE UPDATE OF backend ON missions BEGIN SELECT RAISE(ABORT,'before commit'); END;"
    let some before ← getMission? reopened "aroot" | throw (IO.userError "missing root")
    let settings : OrbCore.MissionSettings.Settings := {
      title := "rollback", backend := "codex", modelOverride := "", modelEffort := "",
      shortDescription? := none, githubPr? := none }
    let rolled ← OrbCore.MissionSettings.applyPlacementPatch reopened before
      (.obj #[("project", .str "rollback-target")]) "alice" true "" "t2" 1001 (some settings)
    check (!rolled.isOk && (← OrbCore.MissionMoveRecovery.pending reopened.missionsDb).toOption == some #[])
      "B5b_before_commit_failure_has_no_marker"
    discard <| sql reopened.missionsDb "DROP TRIGGER reject_settings;"
    OrbCore.MissionMoveRecovery.startup path
    check ((← sql reopened.missionsDb "SELECT project FROM missions ORDER BY id;") == missions &&
      (← sql reopened.projectsDb "SELECT project_scope FROM mcp_sessions_v1 ORDER BY id;") == sessions &&
      (← sql reopened.projectsDb "SELECT project_slug FROM project_track_leases ORDER BY mission_id;") == leases)
      "B5b_second_startup_is_noop"
    let normal ← OrbCore.MissionSettings.applyPlacementPatch reopened before
      (.obj #[("project", .str "normal-target")]) "alice" true "" "t3" 1002
    check (normal.isOk && (← OrbCore.MissionMoveRecovery.pending reopened.missionsDb).toOption == some #[])
      "B5b_normal_move_has_no_marker"
  finally closeCoreStore reopened

def run (root : String) : IO Unit := do
  moveRecovery root
  let .ok store ← openCoreStore s!"{root}/mission-settings"
    | throw (IO.userError "settings store open failed")
  try
    let now : UInt64 := 1700001000
    let cfg : CoreConfig := {
      workingDir := root, dashboardPassword := "settings-test-password",
      jwtSecret := "settings-test-jwt-secret-0123456789"
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
      let .ok rows ← execParamQuery store.missionsDb q params
        | throw (IO.userError "settings fixture query failed")
      return rows
    for uid in #["alice", "bob"] do
      discard <| sql "INSERT INTO users(id,username,password_hash,role) VALUES(?1,?1,'synthetic-hash','member');" #[uid]
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
    let restAt (method path : String) (patch : JVal) := do
      let body := renderCompact patch
      let jwt := mintSessionTokenV2 cfg.jwtSecret "alice" "member" 1 (now + 3600)
      let raw := s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "settings REST parse")
      let .ok response ← dispatchCoreRequest app req now | throw (IO.userError "settings REST dispatch")
      return (response.status, (String.fromUTF8? response.body).getD "")
    let rest (patch : JVal) := do
      let (st, _) ← restAt "PATCH" "/api/control/missions/rest/settings" patch
      return st
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
    let (moveStatus, moveBody) ← restAt "PATCH" "/api/control/missions/rest/settings" move
    check (moveStatus == 200) s!"REST placement patch: {moveBody}"
    let moved ← snapshot "rest"
    check (moved[6]! == "alice:q" && moved[7]! == "" && moved[8]! == "8" && moved[4]! == "codex-session")
      "REST placement revision changes once and preserves session"
    -- B5 replay regression: `POST /api/control/missions/:id/project` moves root, co-located forks,
    -- running workers, nested grandchildren, `/btw` side sessions, and `descendant_ids` atomically.
    discard <| sql
      ("UPDATE missions SET created_at='2026-11-15T10:00:00Z', updated_at='2026-11-15T10:10:00Z' WHERE id='parent';")
    discard <| sql
      ("INSERT INTO missions(id,title,status,backend,model_override,model_effort,session_id,resumable," ++
       "project,folder,placement_revision,parent_mission_id,owner_user_id,tags,created_at,updated_at) VALUES" ++
       "('running-worker','Worker 1','active','codex','gpt-model','high','w1-sess',1,'p','folder',7,'parent','alice','[]','2026-11-15T10:02:00Z','2026-11-15T10:09:00Z')," ++
       "('deep-worker','Worker 2','active','codex','gpt-model','high','w2-sess',1,'p','folder',7,'running-worker','alice','[]','2026-11-15T10:03:00Z','2026-11-15T10:08:00Z')," ++
       "('fork-v1','Fork v1','awaiting_user','claudecode','claude-model','high','f1-sess',1,'p','folder',7,'parent','alice','[\"fork-of:parent\"]','2026-11-15T10:01:00Z','2026-11-15T10:01:00Z')," ++
       "('btw-child','Side Question','awaiting_user','claudecode','claude-model','high','btw-sess',1,'p','',7,'','alice','[\"btw-parent:parent\"]','2026-11-15T10:04:00Z','2026-11-15T10:04:00Z')," ++
       "('callback-child','Callback Worker','active','codex','gpt-model','high','cb-sess',1,'p','folder',7,'','alice','[]','2026-11-15T10:05:00Z','2026-11-15T10:05:00Z')," ++
       "('unowned-child','Unowned Child','active','codex','gpt-model','high','uo-sess',1,'p','folder',7,'parent','','[]','2026-11-15T10:06:00Z','2026-11-15T10:06:00Z');")
    discard <| sql
      ("INSERT INTO dispatch_lease_intents(reservation_id,mission_id,project_slug,track,repo,authority_mode,phase,boot_epoch,created_at,updated_at) VALUES" ++
       "('res-worker-1','running-worker','p','b5-track','Th0rgal/orb#1829','writer','active',1,'2026-11-15T10:02:00Z','2026-11-15T10:09:00Z');")
    let .ok _ ← execParamQuery store.projectsDb
      ("INSERT INTO project_track_leases(project_slug,track,reservation_id,mission_id,repo,authority_mode,phase,boot_epoch,updated_at) VALUES" ++
       "('p','b5-track','res-worker-1','running-worker','Th0rgal/orb#1829','writer','active',1,'2026-11-15T10:09:00Z');")
      #[]
      | throw (IO.userError "project_track_leases insert failed")
    let .ok _ ← execParamQuery store.projectsDb
      ("INSERT INTO mcp_sessions_v1(id,owner,mission_id,project_scope,project_scoped,expires_at,revoked,subject_kind) VALUES" ++
       "('sess-parent','alice','parent','p',1,?1,0,'mission')," ++
       "('sess-worker','alice','running-worker','p',1,?1,0,'mission')," ++
       "('sess-deep','alice','deep-worker','p',1,?1,0,'mission');")
      #[s!"{now + 3600}"]
      | throw (IO.userError "mcp_sessions_v1 insert failed")
    IO.FS.writeFile s!"{store.rootDir}/secret_broker.json"
      "{\"grants\":[{\"id\":\"g-worker\",\"mission_id\":\"running-worker\",\"secret_name\":\"ETH_RPC\",\"project\":\"p\"}],\"requests\":[]}"
    let (_, subQ) ← registerSseSubscriber bHub none
    let familyMoveCheck : JVal := .obj #[
      ("project", .str "r"),
      ("folder", .str "Audits"),
      ("descendant_ids", .arr #[.str "callback-child", .str "unowned-child"])
    ]
    let (chkSt, chkBody) ← restAt "POST" "/api/control/missions/parent/project" familyMoveCheck
    check (chkSt == 409 && (chkBody.splitOn "approval_transfer_confirmation_required").length >= 2)
      "POST /:id/project preflights cross-project secret grants across descendant workers"
    check ((← snapshot "parent")[6]! == "p" && (← snapshot "running-worker")[6]! == "p")
      "409 secret preflight leaves parent and running worker placement untouched"
    let familyMoveRevoke : JVal := .obj #[
      ("project", .str "r"),
      ("folder", .str "Audits"),
      ("approval_policy", .str "revoke"),
      ("descendant_ids", .arr #[.str "callback-child", .str "unowned-child"])
    ]
    let (mvSt, _) ← restAt "POST" "/api/control/missions/parent/project" familyMoveRevoke
    check (mvSt == 200) "POST /api/control/missions/:id/project moves family with approval_policy=revoke"
    let sseEvs ← subQ.get
    check (!sseEvs.isEmpty && (sseEvs[0]!.splitOn "mission_placement_changed").length >= 2 &&
      (sseEvs[0]!.splitOn "running-worker").length >= 2)
      "POST /:id/project broadcasts mission_placement_changed for family"
    let parentMoved ← snapshot "parent"
    let forkMoved ← snapshot "fork-v1"
    check (parentMoved[6]! == "alice:r" && parentMoved[7]! == "Audits" && parentMoved[8]! == "8" &&
      forkMoved[6]! == "alice:r" && forkMoved[7]! == "Audits" && forkMoved[8]! == "8")
      "root and co-located fork version move to destination project and folder"
    for (cid, expRev) in #[
        ("running-worker", "8"), ("deep-worker", "8"), ("rest", "9"),
        ("mcp", "8"), ("grandchild", "8"), ("other-project", "8"),
        ("btw-child", "8"), ("callback-child", "8")] do
      let row ← snapshot cid
      check (row[6]! == "alice:r" && row[7]! == "" && row[8]! == expRev)
        s!"descendant {cid} moved atomically to project r with folder cleared"
    let updRows ← sql "SELECT updated_at FROM missions WHERE id='running-worker';"
    check (updRows[1]![0]! == "2026-11-15T10:09:00Z")
      "running worker updated_at preserved across family move"
    let .ok scopeRows ← execParamQuery store.projectsDb
      "SELECT mission_id, project_scope FROM mcp_sessions_v1 WHERE id IN ('sess-parent','sess-worker','sess-deep') ORDER BY id;" #[]
      | throw (IO.userError "mcp_sessions_v1 select failed")
    check (scopeRows.size == 4 && scopeRows[1]![1]! == "alice:r" && scopeRows[2]![1]! == "alice:r" && scopeRows[3]![1]! == "alice:r")
      "running worker and root MCP sessions rebound to destination project"
    let intentRows ← sql "SELECT project_slug FROM dispatch_lease_intents WHERE reservation_id='res-worker-1';"
    let .ok leaseRows ← execParamQuery store.projectsDb
      "SELECT project_slug FROM project_track_leases WHERE reservation_id='res-worker-1';" #[]
      | throw (IO.userError "project_track_leases select failed")
    check (intentRows.size == 2 && intentRows[1]![0]! == "alice:r" && leaseRows.size == 2 && leaseRows[1]![0]! == "alice:r")
      "active track leases and dispatch lease intents transfer to destination project"
    let foreignAfter ← snapshot "foreign"
    let unrelatedAfter ← snapshot "unrelated"
    let unownedAfter ← snapshot "unowned-child"
    check (foreignAfter[6]! == "p" && foreignAfter[7]! == "folder" && foreignAfter[8]! == "7" &&
      unrelatedAfter[6]! == "p" && unrelatedAfter[7]! == "folder" && unrelatedAfter[8]! == "7" &&
      unownedAfter[6]! == "p" && unownedAfter[7]! == "folder" && unownedAfter[8]! == "7")
      "foreign-owner, unowned, and unrelated missions remain untouched"
    -- Event-order reconciliation replay (`orb_placement_merge_step`, `docs/ui/mission-moves.md`):
    -- 1) Stale pre-move poll (rev=7) during in-flight move (pendingOpId=101) is fenced (`status=5`).
    -- 2) Authoritative family move event (rev=8, ackOpId=101) commits and clears pending op (`1793`).
    -- 3) Late stale poll (rev=7) after commit (curRev=8) is rejected (`status=4`).
    -- 4) Second hop to project `s` (rev=9) followed by out-of-order first-hop response (rev=8) stays at `rev=9`.
    let wStaleInflight := Orb.Kernel.placementMergeStep 7 7 101 0 0 1
    let wAckMove1 := Orb.Kernel.placementMergeStep 7 (parentMoved[8]!.toNat?.getD 0).toUInt64 101 101 1 1
    let wLateStalePoll := Orb.Kernel.placementMergeStep 8 7 0 0 0 1
    let (mv2St, _) ← restAt "POST" "/api/control/missions/parent/project"
      (.obj #[("project", .str "s"), ("folder", .str "Final"), ("approval_policy", .str "keep")])
    let parentHop2 ← snapshot "parent"
    let workerHop2 ← snapshot "running-worker"
    let wAckMove2 := Orb.Kernel.placementMergeStep 8 (parentHop2[8]!.toNat?.getD 0).toUInt64 102 102 1 1
    let wOutOfOrderMove1 := Orb.Kernel.placementMergeStep 9 8 0 101 1 1
    check (mv2St == 200 && parentHop2[6]! == "alice:s" && parentHop2[7]! == "Final" && parentHop2[8]! == "9" &&
      workerHop2[6]! == "alice:s" && workerHop2[7]! == "" && workerHop2[8]! == "9" &&
      (wStaleInflight &&& 0xFFFFFFFF) == 5 &&
      (wAckMove1 &&& 0xFFFFFFFF) == 1793 && (wAckMove1 >>> 32) == 8 &&
      (wLateStalePoll &&& 0xFFFFFFFF) == 4 && (wLateStalePoll >>> 32) == 8 &&
      (wAckMove2 &&& 0xFFFFFFFF) == 1793 && (wAckMove2 >>> 32) == 9 &&
      (wOutOfOrderMove1 &&& 0xFFFFFFFF) == 4 && (wOutOfOrderMove1 >>> 32) == 9)
      "orb_placement_merge_step fences stale polls and out-of-order multi-hop family move responses"
    -- B5 follow-up: each replay uses a fresh owned fixture family.
    let memberRest (mid : String) (patch : JVal) := do
      let body := renderCompact patch
      let jwt := mintSessionTokenV2 cfg.jwtSecret "alice" "member" 1 (now + 3600)
      let raw := s!"POST /api/control/missions/{mid}/project HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {jwt}\r\nContent-Type: application/json\r\nContent-Length: {body.toUTF8.size}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none | throw (IO.userError "member request parse")
      let .ok response ← dispatchCoreRequest app req now | throw (IO.userError "member request dispatch")
      return response.status
    for (id, parent, tags) in #[
        ("retry-root", "", "[]"), ("retry-worker", "retry-root", "[]"),
        ("retry-fork", "retry-worker", "[\"fork-of:retry-worker\"]"),
        ("retry-deep", "retry-fork", "[]"),
        ("retry-btw", "", "[\"btw-parent:retry-root\"]")] do
      discard <| sql
        "INSERT INTO missions(id,title,backend,owner_user_id,project,folder,parent_mission_id,tags,placement_revision) VALUES(?1,'fixture','claudecode','alice','alice:source','old',?2,?3,7);"
        #[id, parent, tags]
    let patch : JVal := .obj #[("project", .str "destination"), ("folder", .str "new")]
    check ((← memberRest "retry-worker" patch) == 200 && (← snapshot "retry-worker")[7]! == "")
      "B5_selected_worker_folder"
    check ((← memberRest "retry-btw" patch) == 200 && (← snapshot "retry-btw")[7]! == "")
      "B5_selected_btw_folder"
    discard <| sql "UPDATE missions SET project='alice:source',folder='old' WHERE id LIKE 'retry-%';"
    discard <| sql "CREATE TRIGGER reject_b5_settings BEFORE UPDATE OF backend ON missions WHEN NEW.id='retry-root' BEGIN SELECT RAISE(ABORT,'fixture settings failure'); END;"
    let failedPatch := patch.setField "backend" (.str "codex")
    check ((← memberRest "retry-root" failedPatch) == 500)
      "B5_combined_settings_failure_status"
    check ((← snapshot "retry-root")[6]! == "alice:source" && (← snapshot "retry-worker")[6]! == "alice:source")
      "B5_combined_settings_failure_atomic"
    discard <| sql "DROP TRIGGER reject_b5_settings;"
    let .ok _ ← execParamQuery store.projectsDb
      "INSERT INTO mcp_sessions_v1(id,owner,mission_id,project_scope,project_scoped,expires_at,revoked,subject_kind) VALUES('retry-session','alice','retry-worker','alice:source',1,9999999999,0,'mission');" #[]
      | throw (IO.userError "retry session fixture")
    let .ok _ ← execParamQuery store.projectsDb
      "CREATE TRIGGER reject_b5_session BEFORE UPDATE ON mcp_sessions_v1 WHEN NEW.id='retry-session' BEGIN SELECT RAISE(ABORT,'fixture session failure'); END;" #[]
      | throw (IO.userError "retry failure trigger")
    check ((← memberRest "retry-root" patch) == 500) "B5_rebind_database_failure"
    let .ok _ ← execParamQuery store.projectsDb "DROP TRIGGER reject_b5_session;" #[]
      | throw (IO.userError "retry failure cleanup")
    check ((← memberRest "retry-root" patch) == 200) "B5_member_rest_retry"
    let .ok repaired ← execParamQuery store.projectsDb
      "SELECT project_scope FROM mcp_sessions_v1 WHERE id='retry-session';" #[]
      | throw (IO.userError "retry session read")
    check (repaired[1]![0]! == "alice:destination") "B5_retry_repairs_unchanged_session"
    for id in #["retry-fork", "retry-deep"] do
      let row ← snapshot id
      check (row[6]! == "alice:destination" && row[7]! == "") "B5_nested_worker_fork_closure"
    let .ok absent ← execParamQuery store.askDb
      "SELECT name FROM sqlite_master WHERE type='table' AND name='mcp_sessions_v1';" #[]
      | throw (IO.userError "legacy table lookup")
    check (absent.size <= 1 && (← memberRest "retry-root" patch) == 200)
      "B5_missing_legacy_session_table"
    let .ok _ ← execParamQuery store.askDb
      "CREATE TABLE mcp_sessions_v1(mission_id TEXT, project_scope TEXT, project_scoped INTEGER);" #[]
      | throw (IO.userError "legacy session table fixture")
    let .ok _ ← execParamQuery store.askDb
      "INSERT INTO mcp_sessions_v1 VALUES('retry-worker','alice:source',1);" #[]
      | throw (IO.userError "legacy session fixture")
    let .ok _ ← execParamQuery store.askDb
      "CREATE TRIGGER reject_b5_legacy BEFORE UPDATE ON mcp_sessions_v1 BEGIN SELECT RAISE(ABORT,'no such table: injected failure in existing table'); END;" #[]
      | throw (IO.userError "legacy trigger fixture")
    check ((← memberRest "retry-root" patch) == 500) "B5_existing_legacy_session_error"
    let .ok _ ← execParamQuery store.askDb "DROP TRIGGER reject_b5_legacy;" #[]
      | throw (IO.userError "legacy trigger cleanup")
    check ((← memberRest "retry-root" patch) == 200) "B5_legacy_session_retry"
  finally
    closeCoreStore store

end OrbCore.MissionSettingsTests
