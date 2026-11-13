import OrbCore.Control
import OrbCore.ManagedProvisioningTests

namespace OrbCore.TenantIsolationTests

open OrbCore.Control OrbCore.Store OrbCore.Managed OrbBin.Json LeanSys.Http

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"tenant isolation: {label}")

/-- Two real stored principals through the REST/desktop and MCP HTTP boundary.
    All records, credentials and provider state are synthetic; no host effects. -/
def run (root : String) : IO Unit := do
  let path := root ++ "/tenant-isolation"
  let .ok store ← openCoreStore path | throw (IO.userError "isolation store")
  let .ok mc ← openManagedComputeStore (path ++ "/managed_compute.db")
    | do closeCoreStore store; throw (IO.userError "isolation managed store")
  try
    let now : UInt64 := 1794564000
    let sql (db : SqliteDb) (query : String) (params : Array String := #[]) : IO Unit := do
      let .ok _ ← execParamQuery db query params | throw (IO.userError "isolation fixture SQL")
    for (uid, role) in #[("admin", "admin"), ("member", "member")] do
      sql store.missionsDb "INSERT INTO users(id,username,password_hash,role,unix_username) VALUES(?1,?1,'synthetic-hash',?2,?3);"
        #[uid, role, "orb-" ++ uid]
      let .ok () ← upsertMission store {
        id := uid ++ "-mission", ownerUserId := uid, title := uid ++ "-private-marker",
        status := "awaiting_user", backend := "codex", modelOverride := "",
        workingDirectory := path, project := uid ++ "-project", updatedAt := "2026-11-13T10:00:00Z" }
        | throw (IO.userError "isolation mission")
      sql store.projectsDb "INSERT INTO projects(slug,name,title,objective) VALUES(?1,?1,?1,?2);"
        #[uid ++ "-project", uid ++ "-private-marker"]
      sql store.projectsDb "INSERT INTO project_owners(slug,owner_user_id) VALUES(?1,?2);" #[uid ++ "-project", uid]
      sql store.missionsDb "INSERT INTO workspaces(id,name,path,owner_user_id) VALUES(?1,?1,?2,?3);"
        #[uid ++ "-workspace", path ++ "/" ++ uid ++ "-private-marker", uid]
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 5000, maxConcurrent := 10 }
    -- Pre-cutover rows are operator data, never implicitly shared with members.
    sql store.projectsDb "INSERT INTO projects(slug,name,objective) VALUES('legacy-project','admin-private-marker-legacy','legacy owner data');"
    let .ok () ← saveManagedFleetConfig mc true true 5000 0 10 | throw (IO.userError "isolation fleet")
    let .ok _ ← provisionManagedMachine mc fleet {
      id := "legacy-machine", sandboxName := "admin-private-marker-legacy", ownerUserId := "",
      ownerKind := "user", spentCents := 0 } now | throw (IO.userError "isolation legacy machine")
    for uid in #["admin", "member"] do
      let .ok _ ← provisionManagedMachine mc fleet {
        id := uid ++ "-machine", sandboxName := uid ++ "-private-marker", ownerUserId := uid,
        ownerKind := "user", spentCents := 0 } now | throw (IO.userError "isolation machine")
      let .ok () ← addUserSpendCents store uid (currentUtcDay now) 0 (if uid == "admin" then 73 else 2)
        | throw (IO.userError "isolation usage")
    sql mc.db "CREATE TABLE IF NOT EXISTS managed_snapshots (id TEXT PRIMARY KEY,name TEXT NOT NULL,provider TEXT NOT NULL DEFAULT 'boat',source_machine_id TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'ready',size_gb INTEGER NOT NULL DEFAULT 20,created_at TEXT NOT NULL DEFAULT '');"
    for uid in #["admin", "member", "legacy"] do
      sql mc.db "INSERT INTO managed_snapshots(id,name,source_machine_id) VALUES(?1,?2,?3);"
        #[uid ++ "-snapshot", (if uid == "member" then "member" else "admin") ++ "-private-marker-snapshot", uid ++ "-machine"]
    let .ok loadedFleet ← loadManagedFleet mc true true 5000 0 10 | throw (IO.userError "isolation fleet load")
    let st : CoreAppState := {
      cfg := { instanceName := "dev", jwtSecret := "synthetic-isolation-jwt-not-a-live-secret", workingDir := path },
      store := store, managedStore? := some mc, bootstrapAdminId := "admin", searchIdx? := none,
      managedProvisioningOverride? := some (OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat",
        { coreUrl := "https://unused.invalid", script := "" }),
      managedRef := ← IO.mkRef loadedFleet, chainsRef := ← IO.mkRef #[],
      proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 1 }
    let token (uid role : String) := mintSessionTokenV2 st.cfg.jwtSecret uid role 1 (now + 3600)
    let member := token "member" "member"
    let admin := token "admin" "admin"
    let send (method target bearer : String) (body : JVal := .obj #[]) (app : CoreAppState := st) : IO (Nat × JVal) := do
      let payload := renderCompact body
      let wire := s!"{method} {target} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {bearer}\r\nContent-Type: application/json\r\nContent-Length: {payload.utf8ByteSize}\r\n\r\n{payload}"
      let .ok request := parseRequest wire.toUTF8 none | throw (IO.userError "isolation request")
      let .ok response ← dispatchCoreRequest app request now | throw (IO.userError "isolation dispatch")
      return (response.status, (parseBytes response.body).toOption.getD .null)
    let call (bearer tool : String) (args : JVal := .obj #[]) : IO JVal := do
      let (status, doc) ← send "POST" "/api/mcp/call" bearer (.obj #[("name", .str tool), ("arguments", args)])
      check (status == 200) s!"MCP transport {tool}"
      return doc
    let configured := { st with cfg := { st.cfg with usersJson := "{\"member\":\"configured-member-password-123\"}" } }
    let (legacyStatus, legacyMe) ← send "GET" "/api/auth/me" "configured-member-password-123" (.obj #[]) configured
    check (legacyStatus == 200 && (legacyMe.fieldOrNull "user").fieldStr? "id" == some "member" &&
      (legacyMe.fieldOrNull "user").fieldStr? "role" == some "member") "configured raw password never becomes bootstrap admin"
    let (legacyForeign, _) ← send "GET" "/api/control/missions/admin-mission" "configured-member-password-123" (.obj #[]) configured
    check (legacyForeign == 404) "configured password retains REST tenant confinement"
    let ambiguous := { configured with cfg := { configured.cfg with
      usersJson := "{\"admin\":\"configured-member-password-123\",\"member\":\"configured-member-password-123\"}" } }
    check ((← send "GET" "/api/auth/me" "configured-member-password-123" (.obj #[]) ambiguous).1 == 401)
      "ambiguous configured passwords fail closed"
    -- REST retry receipts have the same tenant boundary as their MCP equivalents.
    for (bearer, uid) in #[(admin, "admin"), (member, "member")] do
      let body : JVal := .obj #[("id", .str (uid ++ "-retry-mission")), ("title", .str "retry fixture"),
        ("placement", .str "client"), ("idempotency_key", .str "same-rest-key-two-users")]
      let (status, created) ← send "POST" "/api/control/missions" bearer body
      check (status == 201 && created.fieldStr? "id" == some (uid ++ "-retry-mission")) "REST retry receipt stays with caller"
      let (repeatedStatus, repeated) ← send "POST" "/api/control/missions" bearer body
      check (repeatedStatus == 201 && repeated == created) "REST own retry stays idempotent"
    let foreign : JVal := .obj #[("mission_id", .str "admin-mission"), ("id", .str "admin-mission"),
      ("message", .str "attempted mutation"), ("prompt", .str "attempted wakeup"), ("delay_seconds", .nat 60),
      ("role", .str "operator"), ("user_id", .str "admin"), ("owner_user_id", .str "admin")]
    -- The desktop uses these same REST paths. Neither list nor guessed ids disclose admin data.
    for target in #["/api/control/missions", "/api/projects", "/api/workspaces", "/api/managed-machines"] do
      let (status, doc) ← send "GET" target member
      check (status == 200 && ((renderCompact doc).splitOn "admin-private-marker").length == 1) s!"REST list {target}"
    for method in #["GET", "PATCH", "DELETE"] do
      let (status, _) ← send method "/api/control/missions/admin-mission" member
      check (status == 404) s!"REST guessed foreign mission {method}"
    for target in #["/api/bitwarden/status", "/api/secrets", "/api/admin/users"] do
      check ((← send "GET" target member).1 == 403) s!"REST admin boundary {target}"
    for method in #["GET", "POST"] do
      let target := if method == "GET" then "/api/managed-machines/admin-machine" else "/api/managed-machines/admin-machine/stop"
      check ((← send method target member).1 == 404) "REST foreign machine read/action"
    check ((← send "GET" "/api/managed-machines/member-machine" member).1 == 200) "REST own machine"
    for target in #["/api/managed-machines/legacy-machine", "/api/managed-machines/legacy-machine/operations"] do
      check ((← send "GET" target member).1 == 404) "unowned legacy machine is operator-only"
    check ((← send "POST" "/api/managed-machines/legacy-machine/stop" member).1 == 404)
      "unowned legacy machine cannot be controlled by member"
    -- Denials happen before provider lookup, mutation or any vault/network I/O.
    let (snapStatus, snaps) ← send "GET" "/api/managed-machines/snapshots" member
    check (snapStatus == 200 && ((renderCompact snaps).splitOn "admin-private-marker").length == 1 &&
      ((renderCompact snaps).splitOn "member-snapshot").length > 1) "REST snapshot inventory has verified ownership"
    check ((← send "POST" "/api/managed-machines/snapshots" member
      (.obj #[("machine_id", .str "admin-machine"), ("name", .str "unauthorized-snapshot")])).1 == 404)
      "foreign snapshot creation denied before provider"
    for sid in #["admin-snapshot", "legacy-snapshot", "absent-snapshot"] do
      check ((← send "DELETE" ("/api/managed-machines/snapshots/" ++ sid) member).1 == 404)
        "foreign or unowned snapshot deletion denied before provider"
    let .ok snapshots ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_snapshots;" #[]
      | throw (IO.userError "isolation snapshot verification")
    check ((snapshots[1]?.bind (·[0]?)) == some "3") "denied snapshot operations leave fixtures intact"
    let (_, memberSettings) ← send "GET" "/api/managed-machines/settings" member
    check (memberSettings.fieldNat? "spent_today_cents" == some 2) "REST settings never disclose fleet usage to a member"
    for target in #["/api/managed-machines/providers/boat", "/api/managed-machines/settings"] do
      check ((← send "PUT" target member).1 == 403) s!"REST provider mutation {target}"
    -- Member dashboard bearer used to become an unconstrained MCP operator.
    for tool in #["get_mission", "get_mission_events", "get_mission_health", "get_mission_diagnostics",
        "list_mission_shared_files", "get_budget", "get_consult_result", "get_cloud_execution",
        "send_message_to_mission", "cancel_mission", "resume_mission", "update_mission_settings", "schedule_wakeup"] do
      let doc ← call member tool foreign
      check (doc.fieldBool? "ok" == some false && (doc.fieldOrNull "error").fieldStr? "code" == some "not_found")
        s!"MCP foreign mission {tool}"
    for tool in #["list_missions", "list_active_missions", "list_projects", "list_workspaces"] do
      let doc ← call member tool
      check (doc.fieldBool? "ok" == some true && ((renderCompact doc).splitOn "admin-private-marker").length == 1 &&
        ((renderCompact doc).splitOn "admin-mission").length == 1 && ((renderCompact doc).splitOn "admin-project").length == 1 &&
        ((renderCompact doc).splitOn "admin-workspace").length == 1) s!"MCP scoped list {tool}"
    let machines ← call member "list_managed_machines"
    let machineResult := machines.fieldOrNull "result"
    check (machines.fieldBool? "ok" == some true &&
      ((renderCompact machineResult).splitOn "admin-machine").length == 1 &&
      ((renderCompact machineResult).splitOn "member-machine").length > 1 &&
      machineResult.fieldNat? "spent_today_cents" == some 2) "MCP machine inventory and usage stay with member"
    let budget ← call member "get_budget"
    check ((budget.fieldOrNull "result").fieldNat? "spent_today_cents" == some 2) "MCP budget excludes admin spend"
    let projectArgs : JVal := .obj #[("project", .str "admin-project"), ("status", .str "archived")]
    for tool in #["get_project", "get_situation", "get_project_tasks", "get_project_grant", "update_project_status", "add_project_steer"] do
      let doc ← call member tool projectArgs
      check (doc.fieldBool? "ok" == some false) s!"MCP foreign project {tool}"
    for tool in #["secret_list", "secret_get", "secret_request", "secret_put", "secret_delete", "secret_move", "list_privileged_access"] do
      let doc ← call member tool (.obj #[("name", .str "SYNTHETIC_DENIED_PROBE")])
      check (doc.fieldBool? "ok" == some false) s!"MCP member cannot use owner broker {tool}"
    -- Choosing a more powerful role at session minting must not change tenant ownership.
    let mut memberSession := ""
    for role in #["executor", "coordinator", "operator"] do
      let (status, minted) ← send "POST" "/api/mcp/session" member
        (.obj #[("mission_id", .str "member-mission"), ("role", .str role)])
      let scopedToken := (minted.fieldStr? "token").getD ""
      if role == "executor" then memberSession := scopedToken
      check (status == 200 && !scopedToken.isEmpty) s!"session mint {role}"
      for tool in #["get_mission", "get_mission_events", "cancel_mission", "schedule_wakeup"] do
        let doc ← call scopedToken tool foreign
        check (doc.fieldBool? "ok" == some false) s!"scoped role cannot cross tenant {role}/{tool}"
    -- Members can request the plan's dev-only pass for their OWN mission. It
    -- still requires a separately approved live lease and never exposes host
    -- audit or generic privilege tokens. Dashboard role labels cannot redeem it.
    let requested ← call memberSession "request_privileged_access" (.obj #[("scope", .str "dev_operator"),
      ("reason", .str "synthetic approval test"), ("ttl_minutes", .nat 30)])
    check (requested.fieldBool? "ok" == some true && (requested.fieldOrNull "result").fieldStr? "state" == some "pending")
      "member mission can request a dev pass without bypassing approval"
    let devArgs : JVal := .obj #[("grant_id", .str "member-dev-grant")]
    check ((← call memberSession "get_dev_access" devArgs).fieldBool? "ok" == some false)
      "dev access denied before approval"
    for uid in #["admin", "member"] do
      let .ok () ← upsertPrivilegeLease store {
        grantId := uid ++ "-dev-grant", leaseToken := "synthetic-" ++ uid ++ "-dev-pass",
        missionId := uid ++ "-mission", scope := "dev_operator", targetHost := "dev", expiresAtEpoch := now + 1800 }
        | throw (IO.userError "isolation approved dev lease fixture")
    let devAccess ← call memberSession "get_dev_access" devArgs
    check (devAccess.fieldBool? "ok" == some true && (devAccess.fieldOrNull "result").fieldStr? "instance" == some "dev")
      "member mission may redeem its own approved dev pass"
    check ((← call member "get_dev_access" devArgs).fieldBool? "ok" == some false)
      "direct member cannot take a mission's approved pass"
    check ((← call memberSession "get_dev_access" (devArgs.setField "grant_id" (.str "admin-dev-grant"))).fieldBool? "ok" == some false)
      "member mission cannot redeem the admin mission's approved pass"
    let ownGrants ← call memberSession "list_privileged_access"
    check (ownGrants.fieldBool? "ok" == some true &&
      ((renderCompact ownGrants).splitOn "admin-dev-grant").length == 1 &&
      ((renderCompact ownGrants).splitOn "lease_token").length == 1 &&
      ((ownGrants.fieldOrNull "result").field? "command_audit").isNone)
      "member grant listing contains only dev grant metadata for its own mission"
    let (externalStatus, externalDoc) ← send "POST" "/api/mcp/external-sessions" member
      (.obj #[("role", .str "coordinator")])
    let externalToken := (externalDoc.fieldStr? "token").getD ""
    check (externalStatus == 200 && !externalToken.isEmpty) "external member session minted"
    check ((← call externalToken "get_mission" foreign).fieldBool? "ok" == some false)
      "external coordinator remains tenant scoped"
    -- Dashboard callers share a transport session id, never a retry-key namespace.
    let wakeArgs := foreign.setField "idempotency_key" (.str "same-key-two-users")
    let adminWake ← call admin "schedule_wakeup" wakeArgs
    let adminAction := ((adminWake.fieldOrNull "result").fieldStr? "action_id").getD ""
    check (!adminAction.isEmpty) "admin wakeup positive control"
    let memberArgs := wakeArgs.setField "mission_id" (.str "member-mission") |>.setField "id" (.str "member-mission")
    let memberWake ← call member "schedule_wakeup" memberArgs
    let memberResult := memberWake.fieldOrNull "result"
    let memberAction := (memberResult.fieldStr? "action_id").getD ""
    check (!memberAction.isEmpty && memberAction != adminAction && memberResult.fieldStr? "mission_id" == some "member-mission")
      "retry keys cannot replay another user's action result"
    let repeated ← call member "schedule_wakeup" memberArgs
    check ((repeated.fieldOrNull "result").fieldStr? "action_id" == some memberAction) "own retry remains idempotent"
    for tool in #["get_action", "cancel_action"] do
      let doc ← call member tool (.obj #[("action_id", .str adminAction)])
      check (((renderCompact doc).splitOn "admin-mission").length == 1 &&
        (doc.fieldBool? "ok" == some false || (doc.fieldOrNull "result").fieldBool? "cancelled" == some false))
        s!"foreign action receipt {tool}"
    let waits ← call member "wait_actions" (.obj #[("action_ids", .arr #[.str adminAction])])
    check (((renderCompact waits).splitOn "admin-mission").length == 1 &&
      (waits.fieldOrNull "result").fieldBool? "all_succeeded" == some false) "wait cannot disclose or confirm foreign action"
    let memory ← call member "memory_get_knowledge_tree"
    check (memory.fieldBool? "ok" == some false &&
      (memory.fieldOrNull "error").fieldStr? "message" == some "Administrator required")
      "member is denied before the owner's personal memory broker"
    -- A member who cannot see a mission cannot delete its queued follow-up (`404`, row unchanged).
    let (enqAdminQueueStatus, _) ← send "POST" "/api/control/queue" admin
      (.obj #[("id", .str "admin-queue-item"), ("mission_id", .str "admin-mission"),
        ("content", .str "admin-queued-followup"), ("source", .str "desktop")])
    check (enqAdminQueueStatus == 201) "admin queue enqueue positive control"
    let (memberDelForeignQueueStatus, _) ← send "DELETE" "/api/control/queue/admin-queue-item" member
    check (memberDelForeignQueueStatus == 404) "member cannot delete foreign mission queue item"
    let .ok foreignQueueRows ← execParamQuery store.missionsDb
      "SELECT state,COALESCE(phase,0),json_extract(payload,'$.message.content') FROM remote_message_queue WHERE user_id='core' AND message_id='admin-queue-item';" #[]
      | throw (IO.userError "isolation foreign queue verification")
    check (foreignQueueRows[1]? == some #["waiting", "0", "admin-queued-followup"])
      "foreign mission queue row survives denied member DELETE"
    -- A role chosen for a shared admin mission must not adopt the admin's identity.
    sql store.missionsDb "INSERT INTO mission_shares(mission_id,user_id,granted_by) VALUES('admin-mission','member','admin');"
    let (sharedStatus, sharedDoc) ← send "POST" "/api/mcp/session" member
      (.obj #[("mission_id", .str "admin-mission"), ("role", .str "operator")])
    let sharedToken := (sharedDoc.fieldStr? "token").getD ""
    check (sharedStatus == 200 && !sharedToken.isEmpty) "shared session minted"
    check ((← call sharedToken "get_mission" foreign).fieldBool? "ok" == some true) "participant may read shared mission"
    check ((← call sharedToken "resume_mission" foreign).fieldBool? "ok" == some false)
      "shared session cannot acquire owner mutation rights"
    check ((← call sharedToken "secret_list").fieldBool? "ok" == some false)
      "shared admin mission does not grant its owner's secret authority"
    check ((← call sharedToken "get_dev_access" (devArgs.setField "grant_id" (.str "admin-dev-grant"))).fieldBool? "ok" == some false)
      "shared admin mission does not delegate its owner's approved dev pass"
    let sharedMemory ← call sharedToken "memory_get_knowledge_tree"
    check ((sharedMemory.fieldOrNull "error").fieldStr? "message" == some "Administrator required")
      "shared admin mission does not grant its owner's personal memory"
    let ownProject ← call member "get_project" (.obj #[("project", .str "member-project")])
    check (ownProject.fieldBool? "ok" == some true) "member retains own project access"
    sql store.projectsDb "INSERT INTO project_bindings(slug,control_session_id) VALUES('admin-project','admin-session');"
    let (_, hiddenBinding) ← send "GET" "/api/projects/by-session/admin-session" member
    check ((hiddenBinding.field? "slug").getD .null == .null) "project session binding cannot disclose another user's project"
    let (_, ownBinding) ← send "GET" "/api/projects/by-session/admin-session" admin
    check (ownBinding.fieldStr? "slug" == some "admin-project") "owner retains project session binding"
    for suffix in #["controller", "controller/action", "crons", "crons/defaults", "crons/admin-job", "crons/admin-job/action"] do
      for method in #["GET", "POST", "PATCH", "DELETE"] do
        check ((← send method ("/api/projects/admin-project/" ++ suffix) member).1 == 403)
          "member cannot read or change the shared host scheduler through project routes"
    -- A global task-key collision must not overwrite the admin's board row,
    -- even though the member legitimately owns the project named in the call.
    sql store.missionsDb "INSERT INTO mission_board_tasks(task_key,project_slug,track,mission_id,attempt_seq,status) VALUES('admin-task','admin-project','private','admin-mission',0,'open');"
    for task in #[.obj #[("task_key", .str "admin-task"), ("status", .str "done")],
        .obj #[("task_key", .str "new-rest-task"), ("mission_id", .str "admin-mission")]] do
      check ((← send "POST" "/api/projects/member-project/tasks" member task).1 == 404)
        "REST task upserts cannot overwrite admin tasks or link admin missions"
    for tool in #["plan_tasks", "plan_project_tasks"] do
      let task : JVal := .obj #[("task_key", .str "admin-task"), ("status", .str "done")]
      let collision ← call member tool (.obj #[("project", .str "member-project"), ("tasks", .arr #[task])])
      check (collision.fieldBool? "ok" == some false) "task-key collision cannot mutate a foreign project"
      let foreignLink ← call member tool (.obj #[("project", .str "member-project"),
        ("tasks", .arr #[task.setField "task_key" (.str "member-new-task") |>.setField "mission_id" (.str "admin-mission")])])
      check (foreignLink.fieldBool? "ok" == some false) "member board cannot disclose a foreign mission through a link"
    let .ok taskRows ← execParamQuery store.missionsDb
      "SELECT mission_id,status FROM mission_board_tasks WHERE task_key='admin-task';" #[]
      | throw (IO.userError "isolation task verification")
    check (taskRows[1]? == some #["admin-mission", "open"]) "admin board survives denied task upserts"
    let decision : JVal := .obj #[("id", .str "admin-decision"), ("project", .str "admin-project"),
      ("question", .str "admin-private-decision")]
    check ((← call admin "record_project_decision" decision).fieldBool? "ok" == some true)
      "admin decision positive control"
    let attemptedDecision := decision.setField "project" (.str "member-project") |>.setField "question" (.str "unauthorized change")
    check ((← call member "record_project_decision" attemptedDecision).fieldBool? "ok" == some false)
      "MCP global decision id cannot overwrite another project"
    check ((← send "POST" "/api/projects/member-project/decision" member attemptedDecision).1 == 400)
      "REST global decision id cannot overwrite another project"
    let .ok decisionRows ← execParamQuery store.projectsDb
      "SELECT question FROM project_decisions WHERE id='admin-decision';" #[]
      | throw (IO.userError "isolation decision verification")
    check (decisionRows[1]? == some #["admin-private-decision"]) "admin decision survives rejected cross-project writes"
    -- No prompt is supplied: a bad placement must fail even for an inert MCP
    -- create, before any machine rental, credential minting or job submission.
    for node in #["agent-core", "sepolia", "managed-admin-machine", "managed-legacy-machine"] do
      let denied ← call member "start_mission" (.obj #[("title", .str "denied placement"), ("remote_node_id", .str node)])
      check (denied.fieldBool? "ok" == some false) s!"MCP cannot bypass placement authority: {node}"
    let some memberRecord ← getUserById? store "member" | throw (IO.userError "member fixture disappeared")
    let nodes : Array OrbCore.RemoteFleetAndRelay.StaticRemoteNode := #[{
      id := "dedicated", baseUrl := "https://unused.invalid", tokenEnv := "SYNTHETIC_UNUSED_NODE_TOKEN" }]
    let remoteSpec : OrbCore.RemoteDispatch.RemoteTurnSpec := {
      missionId := "member-mission", targetNodeId := "dedicated", backend := "codex", prompt := "synthetic" }
    let .ok owned ← OrbCore.RemoteDispatch.bindRemoteTurnOwner store (some mc) remoteSpec "dedicated" nodes
      | throw (IO.userError "valid member remote placement rejected")
    check (owned.ownerUserId == "member") "omitted dispatch owner is restored before minting any credentials"
    check (!(← OrbCore.RemoteDispatch.bindRemoteTurnOwner store (some mc)
      { remoteSpec with ownerUserId := "admin" } "dedicated" nodes).isOk) "dispatch cannot spoof another owner"
    check (!(← OrbCore.RemoteDispatch.authorizeRemotePlacement (some mc)
      { memberRecord with unixUsername? := none } "dedicated" nodes).isOk) "member needs a stored Linux identity"
    check (!(← OrbCore.RemoteDispatch.authorizeRemotePlacement (some mc) memberRecord "dedicated"
      (nodes.map (fun n => { n with labels := #["control-plane"] }))).isOk) "control-plane node labels are authoritative"
    check ((← OrbCore.RemoteDispatch.authorizeRemotePlacement (some mc) memberRecord "managed-member-machine" nodes).isOk)
      "member may use its own managed VM"
    for tool in #["list_cloud_accounts", "list_mission_access"] do
      check ((← call member tool).fieldBool? "ok" == some false) "direct member cannot enumerate owner account/grant metadata"
    check ((← call sharedToken "list_mission_access").fieldBool? "ok" == some false)
      "shared mission cannot disclose the owner's mission grants"
    let own ← call member "get_mission" (.obj #[("mission_id", .str "member-mission")])
    check (own.fieldBool? "ok" == some true) "member retains own mission access"
    let adm ← call admin "get_mission" foreign
    check (adm.fieldBool? "ok" == some true) "admin retains own mission access"
    let some unchanged ← getMission? store "admin-mission" | throw (IO.userError "admin mission disappeared")
    check (unchanged.status == "awaiting_user" && unchanged.title == "admin-private-marker") "denied operations have no effects"
    -- Disabling/deleting an issuer must stop every previously minted session,
    -- including an external session with no mission id and a shared mission.
    for update in #["UPDATE users SET disabled=1 WHERE id='member';", "DELETE FROM users WHERE id='member';"] do
      sql store.missionsDb update
      for bearer in #[memberSession, externalToken, sharedToken] do
        let (status, doc) ← send "POST" "/api/mcp/call" bearer (.obj #[("name", .str "get_mission"),
          ("arguments", .obj #[("mission_id", .str "member-mission")])])
        check (status == 401 || status == 403 || (status == 200 && doc.fieldBool? "ok" == some false))
          "disabled or deleted issuer cannot use old MCP sessions"
  finally
    closeManagedComputeStore mc
    closeCoreStore store

end OrbCore.TenantIsolationTests
