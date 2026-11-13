import OrbCore.Control
import OrbCore.ManagedProvisioningTests
import OrbCore.ProviderUsageAndLogin

namespace OrbCore.TenantIsolationTests

open OrbCore.Control OrbCore.Store OrbCore.Managed OrbCore.ProviderUsageAndLogin OrbBin.Json LeanSys.Http

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"tenant isolation: {label}")

set_option maxHeartbeats 800000
set_option maxRecDepth 200000

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
    -- Hydrated provider routes must project anonymous type labels and quota windows for members
    -- while preserving full account identity for admins.
    let provNameMarker := "admin-provider-name-marker-alpha"
    let provEmailMarker := "admin-provider-email-marker@example.com"
    let provBaseUrlMarker := "https://admin-provider-baseurl-marker.internal/v1"
    let provGoogleProjMarker := "admin-google-project-marker-999"
    let provOrgMarker := "admin-org-marker-corp"
    let provOrgIdMarker := "org-admin-marker-777"
    let provEnvMarker := "ANTHROPIC_API_KEY"
    let .ok () ← upsertAIProvider store {
      id := "prov-anth-1", providerType := "anthropic", name := provNameMarker,
      enabled := true, baseUrl := provBaseUrlMarker, apiKey := "sk-ant-secret-key-marker-1",
      rpmLimit? := some 4321, maxConcurrency? := some 17,
      customModels := #[{ id := "custom-claude", name? := some "Custom Claude" }],
      updatedAt := "2026-11-13T10:00:00Z" }
      | throw (IO.userError "isolation provider 1")
    let .ok () ← upsertAIProvider store {
      id := "prov-anth-2", providerType := "anthropic", name := "admin-provider-name-marker-beta",
      enabled := true, baseUrl := provBaseUrlMarker, apiKey := "sk-ant-secret-key-marker-2",
      updatedAt := "2026-11-13T10:00:00Z" }
      | throw (IO.userError "isolation provider 2")
    let hydratedJson : JVal := .arr #[
      .obj #[
        ("id", .str "prov-anth-1"),
        ("provider_type", .str "anthropic"),
        ("name", .str provNameMarker),
        ("enabled", .bool true),
        ("base_url", .str provBaseUrlMarker),
        ("account_email", .str provEmailMarker),
        ("google_project_id", .str provGoogleProjMarker),
        ("priority", .nat 7)
      ],
      .obj #[
        ("id", .str "prov-anth-2"),
        ("provider_type", .str "anthropic"),
        ("name", .str "admin-provider-name-marker-beta"),
        ("enabled", .bool true),
        ("base_url", .str provBaseUrlMarker),
        ("account_email", .str provEmailMarker),
        ("google_project_id", .str provGoogleProjMarker),
        ("priority", .nat 8)
      ]
    ]
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedJson)
    let pHub ← newProviderRuntimeHub
    let mkUsagePayload (pName : String) : JVal := .obj #[
      ("provider_type", .str "anthropic"),
      ("provider_name", .str pName),
      ("account_email", .str provEmailMarker),
      ("account_name", .str provNameMarker),
      ("organization", .str provOrgMarker),
      ("organization_id", .str provOrgIdMarker),
      ("status", .str "connected"),
      ("unified_5h_utilization", .num "0.42"),
      ("optimize", .obj #[
        ("as_of", .str "2026-11-13T10:00:00Z"),
        ("primary_window", .str "5h"),
        ("windows", .arr #[.obj #[("key", .str "5h"), ("label", .str "5-hour"), ("pct_used", .num "42"), ("pct_remaining", .nat 58)]])
      ])
    ]
    let nowReal ← OrbBin.PosixExt.nowEpoch
    pHub.mu.atomically do
      let cur ← get
      set { cur with
        usageEntries := #[
          { providerId := "prov-anth-1", fetchedSec := nowReal, fetchedIso := "2026-11-13T10:00:00Z", payload := mkUsagePayload provNameMarker },
          { providerId := "prov-anth-2", fetchedSec := nowReal, fetchedIso := "2026-11-13T10:00:00Z", payload := mkUsagePayload "admin-provider-name-marker-beta" }
        ]
      }
    let stWithProviders := { st with providerHub? := some pHub }
    let (_, adminProvDetailUsage) ← send "GET" "/api/ai/providers/prov-anth-1/usage" admin (.obj #[]) stWithProviders
    let (_, adminProvList) ← send "GET" "/api/ai/providers" admin (.obj #[]) stWithProviders
    let (_, adminProvDetail) ← send "GET" "/api/ai/providers/prov-anth-1" admin (.obj #[]) stWithProviders
    let (_, adminProvUsage) ← send "GET" "/api/ai/providers/usage" admin (.obj #[]) stWithProviders
    let (_, adminForBackend) ← send "GET" "/api/ai/providers/for-backend/claudecode" admin (.obj #[]) stWithProviders
    let adminCombined := renderCompact (.arr #[adminProvList, adminProvDetail, adminProvUsage, adminProvDetailUsage, adminForBackend])
    for marker in #[provNameMarker, provEmailMarker, provBaseUrlMarker, provGoogleProjMarker, provOrgMarker, provOrgIdMarker, provEnvMarker] do
      check ((adminCombined.splitOn marker).length > 1) s!"admin sees provider marker {marker}"
    let mut routeLeaks : Array String := #[]
    for (routeName, target) in #[
        ("GET /api/ai/providers", "/api/ai/providers"),
        ("GET /api/ai/providers/:id", "/api/ai/providers/prov-anth-1"),
        ("GET /api/ai/providers/usage", "/api/ai/providers/usage"),
        ("GET /api/ai/providers/:id/usage", "/api/ai/providers/prov-anth-1/usage"),
        ("GET /api/ai/providers/for-backend/claudecode", "/api/ai/providers/for-backend/claudecode")] do
      let (mStatus, mDoc) ← send "GET" target member (.obj #[]) stWithProviders
      let raw := renderCompact mDoc
      check (mStatus == 200) s!"member status 200 on {routeName}"
      let mut leakedOnRoute : Array String := #[]
      for marker in #[provNameMarker, "admin-provider-name-marker-beta", provEmailMarker, provBaseUrlMarker,
          provGoogleProjMarker, provOrgMarker, provOrgIdMarker, provEnvMarker, "4321", "sk-ant-secret"] do
        if (raw.splitOn marker).length > 1 then
          leakedOnRoute := leakedOnRoute.push marker
      if !leakedOnRoute.isEmpty then
        let joinedMarkers := String.intercalate ", " leakedOnRoute.toList
        routeLeaks := routeLeaks.push s!"{routeName} -> [{joinedMarkers}]"
    let joinedLeaks := String.intercalate "; " routeLeaks.toList
    check routeLeaks.isEmpty s!"member provider routes leaked owner identity: {joinedLeaks}"
    let (_, memberListDoc) ← send "GET" "/api/ai/providers" member (.obj #[]) stWithProviders
    let memberRows := match memberListDoc with | .arr xs => xs | _ => #[]
    let mRow1 := memberRows[0]?.getD .null
    let mRow2 := memberRows[1]?.getD .null
    check (mRow1.fieldStr? "id" == some "prov-anth-1" && mRow1.fieldStr? "name" == some "Anthropic 1" &&
      mRow2.fieldStr? "id" == some "prov-anth-2" && mRow2.fieldStr? "name" == some "Anthropic 2" &&
      (mRow1.field? "account_email").isNone && ((mRow1.fieldOrNull "status").field? "account").isNone &&
      (mRow1.field? "base_url").isNone && (mRow1.field? "google_project_id").isNone &&
      (mRow1.field? "env_var").isNone && (mRow1.field? "rpm_limit").isNone &&
      (mRow1.field? "max_concurrency").isNone && (mRow1.field? "priority").isNone)
      "member provider row keeps only projected fields and indexed type display name"
    let (_, memberDetailDoc) ← send "GET" "/api/ai/providers/prov-anth-1" member (.obj #[]) stWithProviders
    check (memberDetailDoc.fieldStr? "id" == some "prov-anth-1" &&
      memberDetailDoc.fieldStr? "name" == some "Anthropic 1" &&
      (memberDetailDoc.field? "account_email").isNone &&
      ((memberDetailDoc.fieldOrNull "status").field? "account").isNone)
      "member provider detail uses unified member projection"
    let (_, memberUsageDoc) ← send "GET" "/api/ai/providers/prov-anth-1/usage" member (.obj #[]) stWithProviders
    check (memberUsageDoc.fieldStr? "status" == some "connected" &&
      (memberUsageDoc.field? "unified_5h_utilization").isSome &&
      (((memberUsageDoc.fieldOrNull "optimize").fieldArr? "windows").getD #[]).size == 1 &&
      (memberUsageDoc.field? "account_email").isNone &&
      (memberUsageDoc.field? "organization").isNone &&
      (memberUsageDoc.field? "organization_id").isNone)
      "member provider usage keeps quota windows without account identity"
    -- `/api/model-routing/health*` must never expose sidecar auth file names or emails to any role.
    let .ok () ← upsertAIProvider store {
      id := "iso-claude-oauth", providerType := "anthropic", name := "Owner Personal Claude",
      enabled := true, apiKey := "cli-proxy-managed"
    } | throw (IO.userError "isolation oauth provider")
    let (scFd, scPort) ← IO.ofExcept (← LeanSys.Posix.tcpListen "127.0.0.1" 0 8)
    let priorScBase ← IO.getEnv "CLAUDE_CODE_PROXY_BASE_URL"
    let priorScKey ← IO.getEnv "CLI_PROXY_MANAGEMENT_KEY"
    OrbBin.PosixExt.setenvVar "CLAUDE_CODE_PROXY_BASE_URL" s!"http://127.0.0.1:{scPort}"
    OrbBin.PosixExt.setenvVar "CLI_PROXY_MANAGEMENT_KEY" "fixture-isolation-mgmt"
    let scStop ← IO.mkRef false
    let scBody := "{\"files\":[{\"name\":\"claude-owner-secret.json\",\"provider\":\"claude\",\"email\":\"owner-secret@example.com\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"2026-11-14T00:00:00Z\",\"remaining_seconds\":7200}]}]}"
    let hydratedWithOauth : JVal := .arr ((hydratedJson.asArr?.getD #[]).push (.obj #[
      ("id", .str "iso-claude-oauth"),
      ("provider_type", .str "anthropic"),
      ("name", .str "Owner Personal Claude"),
      ("enabled", .bool true),
      ("account_email", .str "owner-secret@example.com"),
      ("oauth", .obj #[("access_token", .str "fixture-only-no-live-access")])
    ]))
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedWithOauth)
    let scTask ← IO.asTask (prio := .dedicated) do
      while !(← scStop.get) do
        match ← LeanSys.Posix.tcpAcceptPoll scFd 50 with
        | .ok client =>
          discard <| LeanSys.Posix.readStreamChunk client 8192
          discard <| LeanSys.Posix.writeAll client
            s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {scBody.utf8ByteSize}\r\nConnection: close\r\n\r\n{scBody}".toUTF8
          discard <| LeanSys.Posix.closeFd client
        | .error _ => pure ()
    try
      for (roleLbl, bearer) in #[("admin", admin), ("member", member)] do
        let (hSt, hDoc) ← send "GET" "/api/model-routing/health" bearer (.obj #[]) stWithProviders
        let hRaw := renderCompact hDoc
        let hRow := ((hDoc.asArr?.getD #[]).find? (fun v => v.fieldStr? "account_id" == some "iso-claude-oauth")).getD .null
        check (hSt == 200 &&
          hRow.fieldUInt64? "cooldown_secs_remaining" == some 7200 &&
          hRow.fieldStr? "parked_until" == some "2026-11-14T00:00:00Z" &&
          hRow.fieldStr? "parked_reason" == some "credential_quota" &&
          (hRaw.splitOn "claude-owner-secret.json").length == 1 &&
          (hRaw.splitOn "owner-secret@example.com").length == 1 &&
          (hRaw.splitOn provEmailMarker).length == 1)
          s!"model-routing health exposes parked state without file name or email ({roleLbl})"
      check ((← send "POST" "/api/model-routing/health/iso-claude-oauth/clear" member (.obj #[]) stWithProviders).1 == 403)
        "member cannot clear model-routing health"
    finally
      IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedJson)
      scStop.set true
      discard <| IO.wait scTask
      discard <| LeanSys.Posix.closeFd scFd
      match priorScBase with
      | some v => OrbBin.PosixExt.setenvVar "CLAUDE_CODE_PROXY_BASE_URL" v
      | none => OrbBin.PosixExt.unsetenvVar "CLAUDE_CODE_PROXY_BASE_URL"
      match priorScKey with
      | some v => OrbBin.PosixExt.setenvVar "CLI_PROXY_MANAGEMENT_KEY" v
      | none => OrbBin.PosixExt.unsetenvVar "CLI_PROXY_MANAGEMENT_KEY"
    -- Delete `iso-claude-oauth` from SQLite so subsequent checks see the two baseline active providers.
    sql store.missionsDb "DELETE FROM ai_providers WHERE id='iso-claude-oauth';" #[]
    -- Sibling provider/AI/model-routing GET routes must not leak admin provider names,
    -- disabled admin provider rows, discovery labels, or global proxy usage/outcome rows to members,
    -- while returning 200 reduced views to members and leaving admin/legacy-unscoped responses unchanged.
    let disabledProvMarker := "admin-disabled-prov-marker"
    let .ok () ← upsertAIProvider store {
      id := disabledProvMarker, providerType := "openai", name := disabledProvMarker,
      enabled := false, apiKey := ""
    } | throw (IO.userError "isolation disabled provider")
    let hydratedWithDisabled : JVal := .arr ((hydratedJson.asArr?.getD #[]).push (.obj #[
      ("id", .str disabledProvMarker),
      ("provider_type", .str "openai"),
      ("name", .str disabledProvMarker),
      ("enabled", .bool false),
      ("account_email", .str provEmailMarker),
      ("priority", .nat 9)
    ]))
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedWithDisabled)
    let accountMarker := "admin-proxy-account-marker-1"
    let modelMarker := "admin-proxy-model-marker-v1"
    let discoveryMarker := "admin-discovery-connection-marker"
    let nowIsoReal := formatEpochIso8601Utc nowReal
    sql store.missionsDb
      "INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,cost_cents,provider,account_id,api_key_id,api_key_name,mission_id,caller_kind,purpose,reasoning_tokens,account_bound) VALUES(?1,?2,100,50,0,0,12,'anthropic',?3,'','','admin-mission','mission','turn',0,1);"
      #[nowIsoReal, modelMarker, accountMarker]
    sql store.missionsDb
      "INSERT INTO proxy_outcomes(timestamp,chain_id,provider,account_id,model,status,http_status,retries,ttft_ms,total_ms,fallback_depth,stream,superseded) VALUES(?1,'builtin/smart','anthropic',?2,?3,'error',502,1,0,120,0,0,0);"
      #[nowIsoReal, accountMarker, modelMarker]
    let discoveryJson : JVal := .obj #[
      ("schema_version", .nat 1),
      ("connections", .arr #[
        .obj #[
          ("provider_id", .str "anthropic"),
          ("label", .str discoveryMarker),
          ("access_profile", .str discoveryMarker),
          ("account_email", .str provEmailMarker),
          ("organization", .str provOrgMarker),
          ("diagnostic", .str discoveryMarker),
          ("status", .str "discovered"),
          ("source", .str "discovery"),
          ("checked_at", .str nowIsoReal),
          ("last_success", .obj #[
            ("observed_at", .str nowIsoReal),
            ("completeness", .str "complete"),
            ("models", .arr #[.obj #[("id", .str "claude-sonnet-4-5")]])
          ])
        ]
      ])
    ]
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/model-discovery.json")) (renderCompact discoveryJson)
    let siblingRoutes : Array (String × String) := #[
      ("GET /api/providers/catalog", "/api/providers/catalog"),
      ("GET /api/providers/discovery", "/api/providers/discovery"),
      ("GET /api/ai/usage/summary", "/api/ai/usage/summary"),
      ("GET /api/ai/proxy/health", "/api/ai/proxy/health"),
      ("GET /api/ai/proxy/timing", "/api/ai/proxy/timing"),
      ("GET /api/model-routing/health", "/api/model-routing/health")
    ]
    let siblingMarkers : Array String := #[
      provNameMarker,
      "admin-provider-name-marker-beta",
      disabledProvMarker,
      provEmailMarker,
      provOrgMarker,
      "admin-mission",
      accountMarker,
      modelMarker,
      discoveryMarker
    ]
    let stripGeneratedAt (jv : JVal) : JVal :=
      match jv with
      | .obj kvs => .obj (kvs.filter (fun (k, _) => k != "generated_at" && k != "window_start"))
      | other => other
    let mut adminSiblingDocs : Array JVal := #[]
    for (routeName, target) in siblingRoutes do
      let (aStatus, aDoc) ← send "GET" target admin (.obj #[]) stWithProviders
      let some (lStatus, _, lBytes) ← dispatchProviderAndAiRoute pHub store path 3000 none
          stWithProviders.proxyCooldownsRef "GET" target target ByteArray.empty "" false true stWithProviders.healthTracker?
        | throw (IO.userError s!"legacy unscoped dispatch missing on {routeName}")
      let .ok lDoc := OrbBin.Json.parseBytes lBytes
        | throw (IO.userError s!"legacy unscoped JSON parse failed on {routeName}")
      check (aStatus == 200 && lStatus == 200) s!"admin and legacy unscoped status 200 on {routeName}"
      check (renderCompact (stripGeneratedAt aDoc) == renderCompact (stripGeneratedAt lDoc))
        s!"admin and legacy unscoped receive identical response on {routeName}"
      adminSiblingDocs := adminSiblingDocs.push aDoc
    let adminSiblingCombined := renderCompact (.arr adminSiblingDocs)
    for marker in #[provNameMarker, "admin-provider-name-marker-beta", disabledProvMarker, "admin-mission", accountMarker, modelMarker, discoveryMarker] do
      check ((adminSiblingCombined.splitOn marker).length > 1) s!"admin sees sibling route marker {marker}"
    let mut siblingLeaks : Array String := #[]
    for (routeName, target) in siblingRoutes do
      let (mStatus, mDoc) ← send "GET" target member (.obj #[]) stWithProviders
      check (mStatus == 200) s!"member status 200 on {routeName}"
      let raw := renderCompact mDoc
      let mut leakedOnRoute : Array String := #[]
      for marker in siblingMarkers do
        if (raw.splitOn marker).length > 1 then
          leakedOnRoute := leakedOnRoute.push marker
      if !leakedOnRoute.isEmpty then
        let joinedMarkers := String.intercalate ", " leakedOnRoute.toList
        siblingLeaks := siblingLeaks.push s!"{routeName} ({mStatus}) -> [{joinedMarkers}]"
    let joinedSiblingLeaks := String.intercalate "; " siblingLeaks.toList
    check siblingLeaks.isEmpty s!"member sibling provider/ai routes leaked owner identity: {joinedSiblingLeaks}"
    -- Host-level views: members get their own missions only and no host paths.
    let (ovSt, ovDoc) ← send "GET" "/api/resources/overview" member (.obj #[]) stWithProviders
    check (ovSt == 200 && ((renderCompact ovDoc).splitOn "admin-mission").length == 1 &&
        ((ovDoc.field? "compute").bind (·.fieldArr? "sources")) == some #[] &&
        ((ovDoc.field? "inference").bind (·.fieldArr? "pools")) == some #[])
      "member resources overview hides other users' missions, fleet sources and inference pools"
    let (lsSt, lsDoc) ← send "GET" "/api/library/status" member (.obj #[]) stWithProviders
    check (lsSt != 200 || (lsDoc.fieldStr? "path" == some "" && lsDoc.fieldStr? "remote" == some ""))
      "member library status hides host path and remote"
    let (siSt, siDoc) ← send "GET" "/api/system/info" member (.obj #[]) stWithProviders
    check (siSt == 200 && ((siDoc.fieldArr? "components").getD #[]).all (fun c => (c.field? "path").getD .null == .null))
      "member system info hides binary paths"
    let (skSt, skDoc) ← send "GET" "/api/library/skill" member (.obj #[]) stWithProviders
    check (skSt == 200 && skDoc.asArr? == some #[]) "member Library skill list is empty"
    check ((← send "GET" "/api/library/skill/paloma-infra" member (.obj #[]) stWithProviders).1 == 404)
      "member cannot read a Library skill body"
    let (swSt, swDoc) ← send "GET" "/api/software" member (.obj #[]) stWithProviders
    check (swSt == 200 && ((swDoc.fieldArr? "components").getD #[]).all (fun c => (c.field? "binary_path").getD .null == .null))
      "member software inventory hides binary paths"
    check ((← send "POST" "/api/software/updates" member (.obj #[]) stWithProviders).1 == 403)
      "member cannot start software updates"
    let (_, mCatDoc) ← send "GET" "/api/providers/catalog" member (.obj #[]) stWithProviders
    let mCatProvs := (mCatDoc.fieldArr? "providers").getD #[]
    check (mCatProvs.size == 2 &&
      (mCatProvs[0]?.bind (·.fieldStr? "name")) == some "Anthropic 1" &&
      (mCatProvs[1]?.bind (·.fieldStr? "name")) == some "Anthropic 2")
      "member /api/providers/catalog keeps enabled configured rows with memberProviderDisplayName"
    let (_, mDiscDoc) ← send "GET" "/api/providers/discovery" member (.obj #[]) stWithProviders
    let mConns := (mDiscDoc.fieldArr? "connections").getD #[]
    check (mConns.size == 1 &&
      (mConns[0]?.bind (·.fieldStr? "provider_id")) == some "anthropic" &&
      (mConns[0]?.bind (·.fieldStr? "status")) == some "discovered" &&
      (mConns[0]?.bind (·.fieldStr? "access_profile")) == some "Anthropic 1")
      "member /api/providers/discovery keeps model-evidence connection with projected display name"
    let (_, mHealthDoc) ← send "GET" "/api/model-routing/health" member (.obj #[]) stWithProviders
    let mHealthRows := mHealthDoc.asArr?.getD #[]
    check (mHealthRows.size == 2 &&
      (mHealthRows[0]?.bind (·.fieldStr? "account_id")) == some "prov-anth-1" &&
      (mHealthRows[1]?.bind (·.fieldStr? "account_id")) == some "prov-anth-2")
      "member /api/model-routing/health keeps only enabled configured providers"
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
