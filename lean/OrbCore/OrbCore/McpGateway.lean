/-
  OrbCore.McpGateway: Complete Control-Plane MCP Tool Dispatcher (`POST /api/mcp/call`)
  backing `sandboxed-mcp` (`OrbBin.McpCatalog`) for Hermes controllers, operator sessions,
  and per-mission agents (`0 import Lean`, `0 sorryAx`).
-/
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.McpCatalog
import OrbCore.Store
import OrbCore.ManagedSpawnActions
import OrbCore.Managed
import OrbCore.ManagedHarvest
import OrbCore.AutoPlacement
import OrbCore.ManagedReuse
import OrbCore.MemoryAndCloud
import OrbCore.QueueCont
import OrbCore.R7Core
import OrbCore.LegacyHydrate
import OrbCore.SecretAndApproval
import OrbCore.RemoteFleetAndRelay
import OrbCore.RemoteDispatch
import OrbCore.ProxyModelRouting
import OrbCore.ProjectFilesAndController

namespace OrbCore.McpGateway

open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.Managed
open OrbCore.MemoryAndCloud
open OrbCore.QueueCont
open OrbCore.R7Core
open OrbCore.LegacyHydrate
open OrbCore.SecretAndApproval
open OrbCore.RemoteFleetAndRelay
open OrbCore.RemoteDispatch
open OrbCore.ProjectFilesAndController

private def mcpOk (res : JVal) : String :=
  renderCompact (.obj #[("ok", .bool true), ("result", res)])

private def cellNat (r : Array String) (i : Nat) : Nat :=
  ((r[i]?).bind String.toNat?).getD 0

private def mcpErr (code message : String) (retryable : Bool := false) : String :=
  renderCompact (.obj #[
    ("ok", .bool false),
    ("error", .obj #[
      ("code", .str code),
      ("message", .str message),
      ("accepted", .str "no"),
      ("retryable", .bool retryable)
    ])
  ])

/-- Enforce project confinement when `claims.project` is non-empty (`project_scoped == 1`). -/
private def checkProjectScope (claims : McpSessionClaims) (targetProj : String) : Except String String :=
  let eff := if targetProj.trimAscii.toString.isEmpty then claims.project else targetProj.trimAscii.toString
  if !claims.project.isEmpty && eff != claims.project then
    .error s!"MCP session is confined to project `{claims.project}` (cannot access `{eff}`)"
  else
    .ok eff

/-- Check whether `claims` may read `targetMissionId` (self, child/descendant, operator/coordinator in same project,
    or approved `mission_access.json` grant). -/
private def checkMissionReadAccess
    (store : CoreStore)
    (claims : McpSessionClaims)
    (targetMissionId : String)
    (nowEpochSec : UInt64) : IO (Except String Unit) := do
  if targetMissionId.isEmpty then
    return .error "missing mission_id"
  if claims.missionId == targetMissionId then
    return .ok ()
  let mut targetProj := ""
  let mut parentMid := ""
  if let .ok rows ← execParamQuery store.missionsDb
      "SELECT COALESCE(project,''), COALESCE(parent_mission_id,'') FROM missions WHERE id=?1;" #[targetMissionId] then
    if rows.size > 1 then
      targetProj := cell rows[1]! 0
      parentMid := cell rows[1]! 1
    else
      return .error s!"mission `{targetMissionId}` not found"
  if !claims.project.isEmpty && targetProj != claims.project then
    return .error s!"mission `{targetMissionId}` is outside confined project `{claims.project}`"
  if claims.role == "operator" || claims.role == "coordinator" then
    return .ok ()
  if !claims.missionId.isEmpty && parentMid == claims.missionId then
    return .ok ()
  if !claims.missionId.isEmpty then
    if ← hasApprovedMissionReadAccess store.rootDir claims.missionId targetMissionId nowEpochSec then
      return .ok ()
  return .error s!"read access to mission `{targetMissionId}` requires operator role or `request_mission_access` approval"

/-- Look up a persisted MCP action receipt by `id` from `mcp_actions_v1`. -/
private def lookupMcpActionById? (store : CoreStore) (actionId : String) : IO (Option JVal) := do
  if actionId.trimAscii.toString.isEmpty then return none
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT id, tool, state, COALESCE(result,'{}'), COALESCE(owner,''), created_at, updated_at FROM mcp_actions_v1 WHERE id=?1 LIMIT 1;"
      #[actionId]
    | return none
  if rows.size ≤ 1 then return none
  let r := rows[1]!
  let aid := cell r 0
  let tname := cell r 1
  let stStr := cell r 2
  let resJv := (OrbBin.Json.parse (cell r 3)).toOption.getD (.obj #[])
  let tmid := cell r 4
  let baseObj := resJv.setField "action_id" (.str aid)
    |>.setField "tool_name" (.str tname)
    |>.setField "state" (.str stStr)
    |>.setField "status" (.str (if stStr == "succeeded" then "completed" else stStr))
    |>.setField "accepted" (.str "yes")
    |>.setField "result" resJv
  let withMid := if tmid.isEmpty then baseObj else baseObj.setField "target_mission_id" (.str tmid)
  return some withMid

/-- Look up a previously settled MCP action receipt by `(scope, retry_key)`. -/
private def lookupMcpActionByRetryKey? (store : CoreStore) (scope retryKey : String) : IO (Option JVal) := do
  if retryKey.trimAscii.toString.isEmpty then return none
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT COALESCE(result,'') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2 AND state='succeeded' ORDER BY updated_at DESC LIMIT 1;"
      #[scope, retryKey]
    | return none
  if rows.size ≤ 1 then return none
  let raw := cell rows[1]! 0
  if raw.isEmpty then return none
  return (OrbBin.Json.parse raw).toOption

/-- Persist a settled MCP action receipt in `mcp_actions_v1` and enrich `resObj` with `action_id`/`state`/`accepted`. -/
private def recordSettledMcpAction
    (store : CoreStore)
    (claims : McpSessionClaims)
    (toolName : String)
    (args : JVal)
    (resObj : JVal)
    (nowIso : String)
    (targetMissionId : String := "") : IO JVal := do
  let actId ← newUuidV4
  let retryKey := ((args.fieldStr? "idempotency_key").getD "").trimAscii.toString
  let effRetryKey := if retryKey.isEmpty then s!"auto:{actId}" else retryKey
  let scope := s!"{claims.sessionId}:{claims.missionId}:{toolName}"
  let enriched :=
    resObj
      |>.setField "action_id" (.str actId)
      |>.setField "state" (.str "succeeded")
      |>.setField "accepted" (.str "yes")
  let resJson := renderCompact enriched
  let reqJson := renderCompact args
  let ownerVal := if targetMissionId.isEmpty then claims.missionId else targetMissionId
  let principalVal := s!"{claims.role}:{claims.missionId}"
  discard <| execParamQuery store.projectsDb
    ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
     "VALUES(?1,?2,?3,?4,?4,?5,?6,?7,'succeeded',?8,?9,?9) " ++
     "ON CONFLICT(scope,retry_key) DO UPDATE SET result=excluded.result, updated_at=excluded.updated_at;")
    #[actId, ownerVal, scope, effRetryKey, principalVal, toolName, reqJson, resJson, nowIso]
  return enriched

/-- Only persisted external sessions carry an authenticated user independently of a mission.
    Roles are deliberately not used here: external roles and mission-session roles are
    selected at mint time, not evidence of cross-tenant operator authority. -/
private def externalManagedOwner? (store : CoreStore) (claims : McpSessionClaims)
    (nowEpochSec : UInt64) : IO (Option (String × String)) := do
  if !claims.isExternal || !claims.missionId.isEmpty then return none
  let .ok rows ← execParamQuery store.projectsDb
      ("SELECT owner, project_scope FROM mcp_sessions_v1 WHERE id=?1 " ++
       "AND subject_kind='external_session' AND mission_id='' AND owner<>'' AND revoked=0 " ++
       "AND expires_at>?2 AND (hard_expires_at=0 OR hard_expires_at>?2);")
      #[claims.sessionId, toString nowEpochSec]
    | return none
  if rows.size ≤ 1 then return none
  let project := cell rows[1]! 1
  if !claims.project.isEmpty && !project.isEmpty && claims.project != project then return none
  return some (cell rows[1]! 0, if project.isEmpty then claims.project else project)

/-- Follow a single parent chain, never a shared ancestor's other children. `UNION`
    terminates even malformed cycles; every hop remains in the same tenant/project. -/
private def managedMissionAncestor (store : CoreStore) (ancestor descendant userId project : String) : IO Bool := do
  let .ok rows ← execParamQuery store.missionsDb
      ("WITH RECURSIVE lineage(id,parent) AS (" ++
       "SELECT id,COALESCE(parent_mission_id,'') FROM missions WHERE id=?1 AND owner_user_id=?3 AND project=?4 " ++
       "UNION SELECT m.id,COALESCE(m.parent_mission_id,'') FROM missions m JOIN lineage l ON m.id=l.parent " ++
       "WHERE m.owner_user_id=?3 AND m.project=?4) SELECT id FROM lineage WHERE id=?2 LIMIT 1;")
      #[descendant, ancestor, userId, project]
    | return false
  return rows.size > 1

set_option maxHeartbeats 1200000 in
/-- Execute a non-memory MCP tool call from `POST /api/mcp/call` and return the serialized JSON response body.
    `authenticatedUserId` must come from Control's verified Core principal, never tool
    arguments, and is accepted only for its synthetic unscoped operator fallback. -/
def dispatchMcpToolCall
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (defaultFleet : ManagedFleetState)
    (workingDir : String)
    (claims : McpSessionClaims)
    (toolName : String)
    (args : JVal)
    (nowEpochSec : UInt64)
    (remoteSup? : Option RemoteJobSupervisor := none)
    (managedProvisioningOverride? : Option (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig) := none)
    (authenticatedUserId : String := "")
    (authenticatedAdmin : Bool := false) : IO String := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let callerMid := claims.missionId
  -- `authenticatedAdmin` is Core's own verdict on the caller of a direct (not
  -- mission-scoped) call. Core's single-tenant administrator has no user id, so
  -- the verdict, not the id, is what makes that caller an operator.
  let directOperator := (!authenticatedUserId.isEmpty || authenticatedAdmin) && !claims.isExternal &&
    claims.sessionId == "00000000-0000-4000-8000-000000000000" &&
    callerMid.isEmpty && claims.project.isEmpty && claims.role == "operator"
  let mut callerWorkDir := workingDir
  let mut callerProj := claims.project
  let mut callerUserId := ""
  if !callerMid.isEmpty then
    if let .ok mRows ← execParamQuery store.missionsDb
        "SELECT COALESCE(working_directory,''), COALESCE(project,''), COALESCE(owner_user_id,'') FROM missions WHERE id=?1;" #[callerMid] then
      if mRows.size > 1 then
        let wd := cell mRows[1]! 0
        let pj := cell mRows[1]! 1
        if !wd.isEmpty then callerWorkDir := wd
        if callerProj.isEmpty && !pj.isEmpty then callerProj := pj
        callerUserId := cell mRows[1]! 2

  if claims.isExternal then
    -- Never fall back to a mission or request-body identity for an external session.
    callerUserId := ""
    if let some (userId, project) ← externalManagedOwner? store claims nowEpochSec then
      callerUserId := userId
      callerProj := project
  else if directOperator then
    callerUserId := authenticatedUserId

  -- Operator authority comes from who minted the session, never from the role label
  -- alone: `/api/mcp/session` requires a Core-authenticated user and records it. An
  -- admin's operator session manages any machine; another user's manages that user's.
  let operatorPrincipal? : Option String ←
    if claims.isExternal || claims.role != "operator" then pure none
    else if directOperator then pure (some authenticatedUserId)
    else do
      match ← execParamQuery store.projectsDb
          ("SELECT owner FROM mcp_sessions_v1 WHERE id=?1 AND revoked=0 AND subject_kind<>'external_session' " ++
           "AND (hard_expires_at=0 OR hard_expires_at>?2);") #[claims.sessionId, toString nowEpochSec] with
      | .ok rows => pure (if rows.size > 1 then some (cell rows[1]! 0) else none)
      | .error _ => pure none
  let operatorIsAdmin ← if directOperator && authenticatedAdmin then pure true else match operatorPrincipal? with
    | none => pure false
    -- An empty recorded owner is the unscoped single-tenant principal.
    | some "" => pure true
    | some uid => do pure (((← getUserById? store uid).map (fun u => u.role == "admin" && !u.disabled)).getD false)

  let canManageMachine (machine : ManagedMachine) : IO Bool := do
    if operatorIsAdmin then return true
    if let some uid := operatorPrincipal? then
      if !uid.isEmpty && machine.ownerUserId == uid then return true
    -- An empty identity is only the unscoped single-tenant case: a mission whose
    -- row has no owner may manage a machine that has none either, through lineage.
    if callerUserId.isEmpty && (claims.isExternal || directOperator || !machine.ownerUserId.isEmpty) then return false
    -- For a mission-owned machine the owning mission's user is authoritative (checked
    -- below); the row's own owner id can be a pre-cutover tenant label.
    if machine.ownerMission.isEmpty && !machine.ownerUserId.isEmpty && machine.ownerUserId != callerUserId then return false
    if machine.ownerMission.isEmpty then
      -- User-owned machines have no project/lineage to delegate to a mission.
      return (claims.isExternal || directOperator) && machine.ownerUserId == callerUserId && callerProj.isEmpty
    let some owner ← getMission? store machine.ownerMission | return false
    if owner.ownerUserId != callerUserId then return false
    if !callerProj.isEmpty && owner.project != callerProj then return false
    if claims.isExternal || directOperator then return true
    if callerMid.isEmpty then return false
    if ← managedMissionAncestor store callerMid machine.ownerMission callerUserId owner.project then return true
    return ← managedMissionAncestor store machine.ownerMission callerMid callerUserId owner.project

  -- Snapshots are project-scoped. Only an admin's operator session may name another project.
  let snapshotProject : IO String := do
    let asked := ((args.fieldStr? "project").getD "").trimAscii.toString
    return if operatorIsAdmin && !asked.isEmpty then asked else callerProj
  let snapshotProvider (name : String) : IO (Except String ManagedProvider.Provider) := do
    match managedProvisioningOverride? with
    | some pair => return .ok pair.1
    | none => resolveManagedProvider store.rootDir name

  -- One spawn path for `spawn_managed_machine` and `start_mission(auto-managed)`:
  -- same admission, pricing, project-scoped snapshot resolution and bootstrap.
  let spawnForCaller (spawnArgs : JVal) (forkOfProviderId : String) : IO (Except (String × String) ManagedMachine) := do
    let some mc := mc? | return .error ("unavailable", "managed compute store not configured")
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let prov := canonicalizeProvider ((spawnArgs.fieldStr? "provider").getD "boat")
    let sz := (spawnArgs.fieldStr? "size").getD "small"
    let ttl := (spawnArgs.fieldUInt64? "ttl_minutes").getD 60
    let sName ← newManagedSandboxName ((spawnArgs.fieldStr? "name").getD "")
    let mid ← newUuidV4
    let prefs ← if callerUserId.isEmpty then pure #[] else getUserManagedPrefs mc callerUserId
    if !isUserManagedProviderEnabled prefs prov then
      return .error ("provider_disabled_for_user", "This cloud provider is disabled in your preferences.")
    let quote ← match quoteManagedSpawnCents prov sz ttl (managedProvisioningOverride?.map Prod.fst) with
      | .ok cents => pure cents
      | .error e => return .error ("invalid_arguments", e)
    let callerUser? ← getUserById? store callerUserId
    if !callerUserId.isEmpty && (callerUser?.isNone || (callerUser?.map (·.disabled)).getD true) then
      return .error ("user_unavailable", "The owning user is unavailable.")
    let (infSpent, cmpSpent) ← if callerUserId.isEmpty then pure (0, 0)
      else getUserSpentTodayCents store callerUserId (nowIso.take 10).toString
    let userCap? := callerUser?.bind (·.dailySpendCapCents?)
    let userAdmission? : Option ManagedUserAdmission := userCap?.map fun cap => {
      capCents := cap, inferenceCents := infSpent, computeCents := cmpSpent
    }
    let m : ManagedMachine := {
      id := mid
      sandboxName := sName
      provider := prov
      size := sz
      status := "provisioning"
      ownerMission := callerMid
      ttlMinutes := ttl
      spentCents := quote
      nodeBootEpoch := 1
      deletableAtSec := nowEpochSec
      expiresAtSec := nowEpochSec + ttl * 60
      ownerKind := if callerMid.isEmpty then "user" else "mission"
      requestedByMissionId := callerMid
      ownerUserId := callerUserId
    }
    let requestedSnapshot := ((spawnArgs.fieldStr? "from_snapshot").orElse
      (fun _ => spawnArgs.fieldStr? "managed_from_snapshot") |>.getD "").trimAscii.toString
    let resolvedSnapshot ← if requestedSnapshot.isEmpty then pure "" else do
      let provider ← match ← snapshotProvider prov with
        | .ok p => pure p
        | .error e => return .error ("spawn_rejected", e)
      match ← resolveProjectSnapshot store provider (← snapshotProject) requestedSnapshot with
      | .ok name => pure name
      | .error e => return .error ("spawn_rejected", e)
    match ← spawnConfiguredManagedWorker mc store.rootDir fleet m spawnArgs "" managedProvisioningOverride? userAdmission? resolvedSnapshot forkOfProviderId with
    | .error e => return .error (if e == "provider_at_capacity" then e else "spawn_rejected", e)
    | .ok spawned => return .ok spawned.machine

  -- Idempotent replay for retried mutating MCP calls carrying `idempotency_key`
  let idemKeyTop := ((args.fieldStr? "idempotency_key").getD "").trimAscii.toString
  if !idemKeyTop.isEmpty && toolName != "get_action" && toolName != "wait_actions" &&
     toolName != "reconcile_action" && toolName != "cancel_action" then
    let scope := s!"{claims.sessionId}:{claims.missionId}:{toolName}"
    if let some prevRes ← lookupMcpActionByRetryKey? store scope idemKeyTop then
      return mcpOk prevRes

  match toolName with
  | "get_capabilities" =>
    let caps := (OrbBin.Json.parse (buildMcpCapabilitiesJson claims)).toOption.getD (.obj #[])
    return mcpOk caps

  | "get_action" =>
    let aid := (args.fieldStr? "action_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    if aid.trimAscii.toString.isEmpty then
      return mcpErr "invalid_arguments" "missing action_id"
    -- Spawn receipts are owner-scoped and report their real state.
    match ← ManagedSpawnActions.read? store aid { userId := callerUserId, missionId := callerMid } operatorIsAdmin with
    | .ok (some spawnAction) => return mcpOk spawnAction
    | .error _ => return mcpErr "not_found" "Action not found"
    | .ok none => pure ()
    if let some rec ← lookupMcpActionById? store aid then
      return mcpOk rec
    return mcpOk (.obj #[
      ("action_id", .str aid),
      ("status", .str "completed"),
      ("state", .str "succeeded"),
      ("accepted", .str "yes")
    ])

  | "reconcile_action" =>
    if normalizeMcpRole claims.role != "operator" then
      return mcpErr "forbidden" "reconcile_action requires operator role"
    let aid := (args.fieldStr? "action_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    if aid.trimAscii.toString.isEmpty then
      return mcpErr "invalid_arguments" "missing action_id"
    let resolution := ((args.fieldStr? "resolution").getD "completed").trimAscii.toString
    let nextState := if resolution == "rejected" then "rejected" else "succeeded"
    -- A spawn receipt is reconciled only from `uncertain`: a running one still
    -- owes its real outcome, and a settled one is not rewritten.
    discard <| execParamQuery store.projectsDb
      "UPDATE mcp_actions_v1 SET state=?2, updated_at=?3 WHERE id=?1 AND (tool<>'spawn_managed_machine' OR state='uncertain');"
      #[aid, nextState, nowIso]
    if let some rec ← lookupMcpActionById? store aid then
      return mcpOk rec
    return mcpOk (.obj #[
      ("action_id", .str aid),
      ("status", .str (if nextState == "succeeded" then "completed" else nextState)),
      ("state", .str nextState),
      ("accepted", .str "yes")
    ])

  | "wait_actions" =>
    let idsArr : Array String :=
      match args.fieldArr? "action_ids" with
      | some xs => xs.filterMap JVal.asStr? |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      | none =>
        match (args.fieldStr? "action_id").filter (fun s => !s.trimAscii.toString.isEmpty) with
        | some s => #[s.trimAscii.toString]
        | none => #[]
    let mut receipts : Array JVal := Array.mkEmpty idsArr.size
    for aid in idsArr do
      -- Spawn receipts stay owner-scoped and report their real state here too.
      if ← ManagedSpawnActions.isSpawnAction store aid then
        match ← ManagedSpawnActions.read? store aid { userId := callerUserId, missionId := callerMid } operatorIsAdmin with
        | .ok (some spawnAction) => receipts := receipts.push spawnAction
        | _ => receipts := receipts.push (.obj #[("action_id", .str aid), ("state", .str "not_found"), ("status", .str "not_found")])
        continue
      match ← lookupMcpActionById? store aid with
      | some rec => receipts := receipts.push rec
      | none =>
        receipts := receipts.push (.obj #[
          ("action_id", .str aid),
          ("status", .str "completed"),
          ("state", .str "succeeded"),
          ("accepted", .str "yes")
        ])
    return mcpOk (.obj #[
      ("receipts", .arr receipts),
      ("actions", .arr receipts),
      ("all_succeeded", .bool (receipts.all (fun r => r.fieldStr? "state" == some "succeeded"))),
      ("pending_action_ids", .arr (receipts.filterMap fun r =>
        if #["accepted", "running", "queued", "pending"].contains ((r.fieldStr? "state").getD "")
        then (r.fieldStr? "action_id").map JVal.str else none))
    ])

  | "cancel_action" =>
    let aid := (args.fieldStr? "action_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    if aid.trimAscii.toString.isEmpty then
      return mcpErr "invalid_arguments" "missing action_id"
    if ← ManagedSpawnActions.isSpawnAction store aid then
      match ← ManagedSpawnActions.cancel store aid { userId := callerUserId, missionId := callerMid } operatorIsAdmin with
      | .ok cancelled => return mcpOk cancelled
      | .error _ => return mcpErr "not_found" "Action not found"
    if let some rec ← lookupMcpActionById? store aid then
      let curSt := (rec.fieldStr? "state").getD "succeeded"
      let cancelled := curSt == "queued" || curSt == "pending"
      if cancelled then
        discard <| execParamQuery store.projectsDb
          "UPDATE mcp_actions_v1 SET state='cancelled', updated_at=?2 WHERE id=?1;" #[aid, nowIso]
      return mcpOk (.obj #[
        ("action_id", .str aid),
        ("cancelled", .bool cancelled),
        ("state", .str (if cancelled then "cancelled" else curSt)),
        ("accepted", .str "yes")
      ])
    return mcpOk (.obj #[("action_id", .str aid), ("cancelled", .bool false), ("state", .str "not_found")])

  | "get_fleet_sweep" =>
    let mut activeCnt : Nat := 0
    let mut armedCnt : Nat := 0
    if let .ok r1 ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM missions WHERE status='active';" #[] then
      if r1.size > 1 then activeCnt := cellNat r1[1]! 0
    if let .ok r2 ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM mission_continuations WHERE phase=1;" #[] then
      if r2.size > 1 then armedCnt := cellNat r2[1]! 0
    let fleetVal ← match mc? with
      | some mc =>
        let fl ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
            defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
          | .ok f => pure f
          | .error _ => pure defaultFleet
        buildComputeFleetJVal relayHub? mc fl none 0 none store.rootDir nowIso (some store)
      | none => pure (.obj #[("nodes", .arr #[])])
    return mcpOk (.obj #[
      ("active_missions", JVal.nat activeCnt),
      ("armed_continuations", JVal.nat armedCnt),
      ("fleet", fleetVal)
    ])

  | "schedule_wakeup" =>
    let reqMid := ((args.fieldStr? "mission_id").getD callerMid).trimAscii.toString
    if reqMid.isEmpty then
      return mcpErr "invalid_arguments" "schedule_wakeup requires a mission_id (or a mission-scoped MCP session)"
    if normalizeMcpRole claims.role == "executor" && !callerMid.isEmpty && reqMid != callerMid then
      return mcpErr "forbidden" "executor sessions may only schedule wakeups for their own mission"
    let prompt := ((args.fieldStr? "prompt").getD "").trimAscii.toString
    if prompt.isEmpty then
      return mcpErr "invalid_arguments" "prompt is required"
    let reason := ((args.fieldStr? "reason").getD "scheduled_wakeup").trimAscii.toString
    let delayOpt := (args.fieldNat? "delay_seconds").orElse (fun _ => args.fieldNat? "delaySeconds")
    let nextAtOpt := ((args.fieldStr? "next_at").orElse (fun _ => args.fieldStr? "nextAt")).bind parseIso8601EpochU64?
    let dueEpoch ← match delayOpt, nextAtOpt with
      | some d, _ =>
        if d < 60 || d > 3600 then
          return mcpErr "invalid_arguments" "delay_seconds must be between 60 and 3600"
        pure (nowEpochSec + d.toUInt64)
      | none, some ep =>
        if ep ≤ nowEpochSec then pure (nowEpochSec + 60) else pure ep
      | none, none =>
        return mcpErr "invalid_arguments" "delay_seconds (60..=3600) is required"
    -- Ensure a legacy mission parked in `completed` can arm its wakeup (`ownerTerminal == 0`)
    discard <| execParamQuery store.missionsDb
      "UPDATE missions SET status='awaiting_user', terminal_reason='awaiting_wakeup', state_revision=state_revision+1, updated_at=?2 WHERE id=?1 AND status='completed';"
      #[reqMid, nowIso]
    let cid ← newUuidV4
    let reqId := if idemKeyTop.isEmpty then cid else idemKeyTop
    let draft : ContinuationDraft := {
      id             := cid
      missionId      := reqMid
      requestId      := reqId
      prompt         := prompt
      reason         := if reason.isEmpty then "scheduled_wakeup" else reason
      source         := "automation-manager"
      triggerKind    := "time"
      dueEpoch       := dueEpoch
      stopAfterFirst := true
    }
    match ← registerContinuation store draft nowEpochSec nowIso none with
    | .error "mission_not_found" => return mcpErr "not_found" s!"Mission `{reqMid}` not found"
    | .error e => return mcpErr "continuation_rejected" e
    | .ok savedCid =>
      let nextIso := formatEpochIso8601Utc dueEpoch
      let resObj := JVal.obj #[
        ("id", .str savedCid),
        ("continuation_id", .str savedCid),
        ("mission_id", .str reqMid),
        ("trigger_kind", .str "time"),
        ("due_epoch", JVal.uint64 dueEpoch),
        ("next_at", .str nextIso)
      ]
      let settled ← recordSettledMcpAction store claims toolName args resObj nowIso reqMid
      return mcpOk settled

  | "schedule_job_wakeup" =>
    let reqMid := ((args.fieldStr? "mission_id").getD callerMid).trimAscii.toString
    if reqMid.isEmpty then
      return mcpErr "invalid_arguments" "schedule_job_wakeup requires a mission_id (or a mission-scoped MCP session)"
    if normalizeMcpRole claims.role == "executor" && !callerMid.isEmpty && reqMid != callerMid then
      return mcpErr "forbidden" "executor sessions may only schedule job wakeups for their own mission"
    let jobId := ((args.fieldStr? "job_id").orElse (fun _ => args.fieldStr? "jobId") |>.getD "").trimAscii.toString
    if jobId.isEmpty then
      return mcpErr "invalid_arguments" "job_id is required"
    let prompt := ((args.fieldStr? "prompt").getD "").trimAscii.toString
    if prompt.isEmpty then
      return mcpErr "invalid_arguments" "prompt is required"
    let reason := ((args.fieldStr? "reason").getD "durable_job_terminal").trimAscii.toString
    discard <| execParamQuery store.missionsDb
      "UPDATE missions SET status='awaiting_user', terminal_reason='awaiting_wakeup', state_revision=state_revision+1, updated_at=?2 WHERE id=?1 AND status='completed';"
      #[reqMid, nowIso]
    let cid ← newUuidV4
    let reqId := if idemKeyTop.isEmpty then cid else idemKeyTop
    let dueEpoch := nowEpochSec + 86400
    let draft : ContinuationDraft := {
      id             := cid
      missionId      := reqMid
      requestId      := reqId
      prompt         := prompt
      reason         := if reason.isEmpty then "durable_job_terminal" else reason
      source         := "durable-job-terminal"
      triggerKind    := "durable_job_terminal"
      jobId          := jobId
      dueEpoch       := dueEpoch
      stopAfterFirst := true
    }
    match ← registerContinuation store draft nowEpochSec nowIso none with
    | .error "mission_not_found" => return mcpErr "not_found" s!"Mission `{reqMid}` not found"
    | .error e => return mcpErr "continuation_rejected" e
    | .ok savedCid =>
      let resObj := JVal.obj #[
        ("id", .str savedCid),
        ("continuation_id", .str savedCid),
        ("mission_id", .str reqMid),
        ("job_id", .str jobId),
        ("trigger_kind", .str "durable_job_terminal")
      ]
      let settled ← recordSettledMcpAction store claims toolName args resObj nowIso reqMid
      return mcpOk settled

  -- Mission Discovery & Inspection
  | "list_missions" | "list_active_missions" =>
    let reqProj := (args.fieldStr? "project").getD ""
    let projFilter? ←
      if !claims.project.isEmpty then
        if !reqProj.isEmpty && reqProj != claims.project then
          return mcpErr "project_scope_violation" s!"confined to `{claims.project}`"
        else pure (some claims.project)
      else if !reqProj.isEmpty then pure (some reqProj)
      else pure none
    let lim := (args.fieldNat? "limit").getD 50
    let off := (args.fieldNat? "offset").getD 0
    let stFilter? :=
      if toolName == "list_active_missions" then some "active"
      else args.fieldStr? "status"
    let flt : MissionListFilter := {
      limit? := some (Nat.min lim 200)
      offset? := some off
      status? := stFilter?
      project? := projFilter?
      folder? := args.fieldStr? "folder"
      track? := args.fieldStr? "track"
    }
    match ← listMissionsJson store none none flt with
    | .error e => return mcpErr "db_error" e
    | .ok rawArr =>
      let arr := (OrbBin.Json.parse rawArr).toOption.getD (.arr #[])
      return mcpOk (.obj #[("missions", arr)])

  | "get_mission" | "get_mission_health" | "get_mission_diagnostics" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD callerMid
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return mcpErr "forbidden" e
    match ← missionDetailJson store mid none "" with
    | .error e => return mcpErr "db_error" e
    | .ok none => return mcpErr "not_found" s!"Mission `{mid}` not found"
    | .ok (some raw) =>
      let detail := (OrbBin.Json.parse raw).toOption.getD (.obj #[])
      if toolName == "get_mission_health" then
        return mcpOk (.obj #[
          ("mission_id", .str mid),
          ("status", detail.fieldOrNull "status"),
          ("health_verdict", detail.fieldOrNull "health_verdict"),
          ("resumable", detail.fieldOrNull "resumable")
        ])
      else
        return mcpOk detail

  | "get_mission_events" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD callerMid
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return mcpErr "forbidden" e
    let lim := Nat.min ((args.fieldNat? "limit").getD 100) 500
    let afterSeq := (args.fieldUInt64? "after_seq").getD 0
    match ← queryMissionEventsPage store mid (some afterSeq) none lim #[] (some 32768) with
    | .error e => return mcpErr "mission_events_query_failed" e
    | .ok page =>
      let evs := (OrbBin.Json.parse page.eventsJson).toOption.getD (.arr #[])
      return mcpOk (.obj #[
        ("mission_id", .str mid),
        ("events", evs),
        ("has_more", .bool page.hasMore),
        ("max_seq", JVal.uint64 page.maxSeq)
      ])

  | "list_mission_shared_files" =>
    let mid := (args.fieldStr? "mission_id").getD callerMid
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return mcpErr "forbidden" e
    return mcpOk (.obj #[("mission_id", .str mid), ("files", .arr #[])])

  | "start_mission" | "consult_model" =>
    let title := ((args.fieldStr? "title").orElse (fun _ => args.fieldStr? "summary") |>.getD "Delegated Mission").trimAscii.toString
    let isConsult := toolName == "consult_model"
    -- The published consult contract carries `question` (+ optional `files`).
    let consultFiles := ((args.fieldArr? "files").getD #[]).filterMap JVal.asStr?
    let consultPrompt :=
      let q := ((args.fieldStr? "question").getD "").trimAscii.toString
      if q.isEmpty || consultFiles.isEmpty then q
      else q ++ "\n\nRead these files first:\n" ++ String.intercalate "\n" (consultFiles.toList.map (fun f => s!"- {f}"))
    let prompt :=
      if isConsult && !consultPrompt.isEmpty then consultPrompt
      else ((args.fieldStr? "prompt").orElse (fun _ => args.fieldStr? "goal") |>.getD "").trimAscii.toString
    if isConsult && prompt.isEmpty then
      return mcpErr "invalid_request" "consult_model requires a non-empty `question`"
    let rawProj := (args.fieldStr? "project").getD callerProj
    let effProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return mcpErr "project_scope_violation" e
    let folder := normalizeMissionFolder ((args.fieldStr? "folder").getD "")
    let rawBackend :=
      if toolName == "consult_model" then ((args.fieldStr? "backend").getD "opencode")
      else ((args.fieldStr? "backend").getD "claudecode")
    let backend := if rawBackend == "claude" then "claudecode" else rawBackend
    let rawModelOv := (args.fieldStr? "model_override").orElse (fun _ => args.fieldStr? "model") |>.getD ""
    let modelOv ←
      if isConsult then
        match OrbCore.ProxyModelRouting.consultModel? rawModelOv with
        | some routed => pure routed
        | none => return mcpErr "unknown_model" s!"consult_model cannot route model `{rawModelOv}`. Use <provider>/<model> (e.g. anthropic/claude-fable-5-2, openai/gpt-6-astra) or a short alias (fable-5.2, opus-5.5, gpt-6-astra)."
      else pure rawModelOv
    let effort := (args.fieldStr? "model_effort").orElse (fun _ => args.fieldStr? "reasoning_effort") |>.getD ""
    let parentMid := ((args.fieldStr? "parent_mission_id").filter (!·.isEmpty)).getD callerMid
    let requestedRn? := (args.fieldStr? "remote_node_id").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    let wantsSnapshot := !((args.fieldStr? "managed_from_snapshot").getD "").trimAscii.toString.isEmpty
    let autoManaged := match requestedRn? with
      | some rn => rn.toLower == "auto-managed" || rn.toLower.startsWith "auto-managed:"
      | none => false
    if wantsSnapshot && !autoManaged then
      return mcpErr "invalid_arguments" "managed_from_snapshot requires remote_node_id auto-managed[:size]"
    -- `auto-managed[:size]` rents one machine for this child through the shared spawn
    -- path. Nothing is rented when validation, admission or the snapshot lookup fails.
    let (explicitRn?, rentedMachineId, reused?) ← if !autoManaged then pure (requestedRn?, "", none) else do
      let parts := (((requestedRn?.getD "").toLower.splitOn ":").drop 1).filter (fun part => part != "boat" && !part.isEmpty)
      -- An idle VM left by an ended child of this same caller is taken over instead
      -- of renting another. A snapshot request always gets a fresh machine.
      let reuseRequest : ManagedReuse.Request := {
        provider := "boat"
        size := parts.head?.getD "small"
        parentMission := callerMid
        userId := callerUserId
        project := effProj
        now := nowEpochSec
      }
      let reused? : Option ManagedReuse.Claimed ← match mc? with
        | some mc =>
          if wantsSnapshot || callerMid.isEmpty || parentMid != callerMid then pure none
          else ManagedReuse.claim store mc reuseRequest callerMid
        | none => pure none
      if let some claimed := reused? then
        pure (some s!"managed-{claimed.machine.id}", claimed.machine.id, reused?)
      else
        let retryKey ← match (args.fieldStr? "idempotency_key").filter (!·.isEmpty) with
          | some key => pure key
          | none => newUuidV4
        let spawnArgs := JVal.obj #[
          ("provider", .str "boat"), ("size", .str (parts.head?.getD "small")),
          ("ttl_minutes", JVal.uint64 ((args.fieldUInt64? "managed_ttl_minutes").getD 60)),
          ("from_snapshot", .str ((args.fieldStr? "managed_from_snapshot").getD "")),
          ("idempotency_key", .str ("start-mission:" ++ retryKey))]
        match ← spawnForCaller spawnArgs "" with
        | .error (_, message) => return mcpErr "managed_placement_failed" message
        | .ok rented => pure (some s!"managed-{rented.id}", rented.id, none)
    -- A failed start destroys what it rented, and hands back what it took over.
    let releaseRented : IO Unit := do
      if let (some mc, false) := (mc?, rentedMachineId.isEmpty) then
        match reused? with
        | some claimed => ManagedReuse.restore mc claimed
        | none =>
          discard <| runConfiguredManagedLifecycle mc
            { store, fleet := defaultFleet, override? := managedProvisioningOverride? } rentedMachineId "destroy" nowEpochSec
    -- Nodes this mission may not use: named here, or tagged on any ancestor.
    let excluded := AutoPlacement.normalizeAll
      ((((args.fieldArr? "exclude_nodes").getD #[]).filterMap JVal.asStr?) ++
        (← AutoPlacement.lineageExclusions store parentMid))
    if let some rn := explicitRn? then
      if excluded.contains (AutoPlacement.normalize rn) then
        releaseRented
        return mcpErr "placement_excluded" s!"node `{rn}` is excluded for this mission"
    let parentRn? ←
      if explicitRn?.isSome then pure explicitRn?
      else if !parentMid.isEmpty then resolveMissionRemoteNode? store mc? parentMid
      else pure none
    -- A parent recorded as `auto` predates concrete placement: it runs wherever the
    -- legacy resolver sends it, and its children share that workspace.
    let parentRn? ← match explicitRn?, parentRn? with
      | none, some rn =>
        if rn.toLower == "auto" || rn.toLower.startsWith "auto:" then
          match ← resolveConcreteRemoteTargetNode mc? rn (some (store, parentMid)) with
          | .ok concrete => pure (some concrete)
          | .error _ => pure none
        else pure parentRn?
      | _, _ => pure parentRn?
    -- A parent's node the lineage excludes is not inherited, and neither is its workspace.
    let inheritedRn? := parentRn?.filter (fun rn => !excluded.contains (AutoPlacement.normalize rn))
    let parentNodeExcluded := parentRn?.isSome && inheritedRn?.isNone
    -- Core has no local harness execution: a mission created through MCP with no
    -- node of its own and none to inherit would sit `active` forever without a
    -- job. Choose a node now and record it, so later turns stay with the workspace.
    let wantsAuto := match inheritedRn? with
      | none => true
      | some rn => rn.toLower == "auto" || rn.toLower.startsWith "auto:"
    let inheritedRn? ← if !wantsAuto then pure inheritedRn? else
      match ← AutoPlacement.decide store excluded with
      | .node id => pure (some id)
      | .noFleet => pure (some "auto")
      | .noneEligible =>
        releaseRented
        return mcpErr "placement_failed" "no_eligible_node" true
    let effWorkDir :=
      match (args.fieldStr? "working_directory").map (·.trimAscii.toString) |>.filter (!·.isEmpty) with
      | some wd => wd
      | none => if inheritedRn?.isSome then "" else callerWorkDir
    let mut tagsArr : Array String := #[]
    if let some rn := inheritedRn? then
      tagsArr := tagsArr.push s!"remote-node:{rn}"
      if effWorkDir.isEmpty && !parentMid.isEmpty && explicitRn?.isNone && !parentNodeExcluded then
        tagsArr := tagsArr.push s!"fork-workspace:{parentMid}"
    for nodeId in excluded do
      tagsArr := tagsArr.push (AutoPlacement.exclusionTagPrefix ++ nodeId)
    let tagsJson := renderCompact (.arr (tagsArr.map JVal.str))
    let authMode := if toolName == "consult_model" then "readonly" else "writer"
    -- A consultation with nowhere to run must fail, not sit at awaiting_user/active.
    if isConsult && (remoteSup?.isNone || inheritedRn?.isNone) then
      return mcpErr "no_execution_placement" s!"consult_model `{modelOv}` was not started: no execution node is available for this session. Pass remote_node_id or run from a placed mission." true
    let mid ← newUuidV4
    let initRev : UInt64 := if effProj.isEmpty && folder.isEmpty then 0 else 1
    let initStatus := if !prompt.isEmpty then "active" else "awaiting_user"
    let insSql :=
      "INSERT INTO missions(id,title,status,backend,model_override,model_effort,working_directory,workspace_id,project,folder,placement_revision,parent_mission_id,authority_mode,tags,created_at,updated_at,metadata_updated_at,node_boot_epoch,owner_user_id) " ++
      "VALUES(?1,?2,?3,?4,?5,?6,?7,'00000000-0000-0000-0000-000000000000',?8,?9,CAST(?10 AS INTEGER),NULLIF(?11,''),?12,?13,?14,?14,?14,CAST(?15 AS INTEGER),?16);"
    if let .error e ← execParamQuery store.missionsDb insSql
        #[mid, title, initStatus, backend, modelOv, effort, effWorkDir, effProj, folder, s!"{initRev}", parentMid, authMode, tagsJson, nowIso, s!"{store.bootEpoch}", callerUserId] then
      releaseRented
      return mcpErr "db_error" e
    -- The child owns the machine it was rented for; the caller is recorded as requester.
    if let (some mc, false) := (mc?, rentedMachineId.isEmpty) then
      discard <| execParamQuery mc.db
        "UPDATE managed_machines SET owner_mission=?2,owner_kind='mission',requested_by_mission_id=?3 WHERE id=?1;"
        #[rentedMachineId, mid, callerMid]
    if !prompt.isEmpty then
      discard <| appendMissionEvent store mid "user_message" (renderCompact (.obj #[("content", .str prompt)])) nowIso
      if let (some sup, some targetNode) := (remoteSup?, inheritedRn?) then
        let spec : RemoteTurnSpec := {
          missionId        := mid
          targetNodeId     := targetNode
          backend          := backend
          modelOverride    := if backend == "opencode" && modelOv.isEmpty then "builtin/smart" else modelOv
          modelEffort      := effort
          workingDirectory := effWorkDir
          project          := effProj
          authorityMode    := authMode
          tagsJson         := tagsJson
          prompt           := prompt
          sideQuestion     := toolName == "consult_model"
          companionOf?     := if toolName == "consult_model" && !parentMid.isEmpty then some parentMid else none
        }
        if let .error dispErr ← submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup workingDir spec nowEpochSec then
          discard <| execParamQuery store.missionsDb "DELETE FROM mission_events WHERE mission_id=?1;" #[mid]
          discard <| execParamQuery store.missionsDb "DELETE FROM missions WHERE id=?1;" #[mid]
          releaseRented
          return mcpErr "remote_dispatch_failed" dispErr true
    publishControlEvent broadcastHub? "mission_created" (renderCompact (.obj #[
      ("mission_id", .str mid),
      ("project", if effProj.isEmpty then .null else .str effProj),
      ("folder", .str folder)
    ])) (some mid)
    let resObj := JVal.obj #[
      ("mission_id", .str mid),
      ("id", .str mid),
      ("status", .str initStatus),
      ("backend", .str backend),
      ("model_override", if modelOv.isEmpty then .null else .str modelOv),
      ("remote_node_id", match inheritedRn? with | some rn => .str rn | none => .null),
      ("project", if effProj.isEmpty then .null else .str effProj),
      ("folder", .str folder),
      ("placement_revision", JVal.uint64 initRev),
      -- A reused machine keeps its remaining lifetime: the child extends it if it needs more.
      ("managed_machine_reused", .bool reused?.isSome),
      ("managed_machine_expires_at_sec",
        match reused? with | some claimed => JVal.uint64 claimed.machine.expiresAtSec | none => .null)
    ]
    let settled ← recordSettledMcpAction store claims toolName args resObj nowIso mid
    return mcpOk settled

  | "get_consult_result" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return mcpErr "forbidden" e
    match ← missionDetailJson store mid none "" with
    | .ok (some raw) => return mcpOk ((OrbBin.Json.parse raw).toOption.getD (.obj #[]))
    | _ => return mcpErr "not_found" s!"Mission `{mid}` not found"

  | "send_message_to_mission" | "ask_mission" | "answer_mission_question" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "target_mission_id") |>.getD ""
    let content := ((args.fieldStr? "message").orElse (fun _ => (args.fieldStr? "content").orElse (fun _ => (args.fieldStr? "question").orElse (fun _ => args.fieldStr? "answer"))) |>.getD "").trimAscii.toString
    if mid.isEmpty || content.isEmpty then
      return mcpErr "invalid_arguments" "mission_id and message/content are required"
    if let some t := (args.fieldStr? "title").map (·.trimAscii.toString) then
      if !t.isEmpty then
        discard <| execParamQuery store.missionsDb "UPDATE missions SET title=?2, metadata_updated_at=?3 WHERE id=?1;" #[mid, t, nowIso]
    let noteId ← newUuidV4
    discard <| execParamQuery store.askDb
      "INSERT INTO main.operator_notes(note_id,id,mission_id,content,body,created_at_iso,created_at) VALUES(?1,?1,?2,?3,?3,?4,?4);"
      #[noteId, mid, content, nowIso]
    discard <| appendMissionEvent store mid "operator_note" (renderCompact (.obj #[("id", .str noteId), ("content", .str content)])) nowIso
    let mut queued := false
    if toolName == "send_message_to_mission" then
      if let (some sup, some mr) := (remoteSup?, ← getMission? store mid) then
        if let some targetNode ← resolveMissionRemoteNode? store mc? mid then
          if mr.status == "active" || mr.status == "pending" then
            discard <| enqueueStructuredFollowup store "core" noteId mid content "mcp" nowIso
            queued := true
          else
            let mut resumeSid? : Option String := none
            if let .ok sRows ← execParamQuery store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
              if sRows.size > 1 then
                let s := (cell sRows[1]! 0).trimAscii.toString
                if !s.isEmpty then resumeSid? := some s
            discard <| appendMissionEvent store mid "user_message"
              (renderCompact (.obj #[("id", .str noteId), ("content", .str content), ("source", .str "mcp")])) nowIso
            let spec : RemoteTurnSpec := {
              missionId        := mid
              targetNodeId     := targetNode
              backend          := mr.backend
              modelOverride    := mr.modelOverride
              modelEffort      := mr.modelEffort
              workingDirectory := mr.workingDirectory
              project          := mr.project
              ownerUserId      := mr.ownerUserId
              authorityMode    := mr.authorityMode
              placementKind    := mr.placementKind
              reservedDiskGib  := mr.reservedDiskGib
              tagsJson         := mr.tagsJson
              prompt           := content
              resumeSessionId? := resumeSid?
            }
            discard <| submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup workingDir spec nowEpochSec
    let resObj := JVal.obj #[
      ("ok", .bool true),
      ("mission_id", .str mid),
      ("note_id", .str noteId),
      ("queued", .bool queued)
    ]
    let settled ← recordSettledMcpAction store claims toolName args resObj nowIso mid
    return mcpOk settled

  | "cancel_mission" | "acknowledge_mission" | "adopt_mission" | "resume_mission" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD callerMid
    if mid.isEmpty then return mcpErr "invalid_arguments" "missing mission_id"
    if toolName == "cancel_mission" then
      discard <| revokeContinuations store mid nowIso true
      discard <| cancelActiveRemoteJobForMission store mc? relayHub? mid "Cancelled via MCP"
      discard <| execParamQuery store.missionsDb
        "UPDATE mission_runs SET execution_state='terminal', terminal_reason='cancelled', updated_at=?2 WHERE mission_id=?1 AND execution_state NOT IN ('terminal','completed','failed','aborted');"
        #[mid, nowIso]
      discard <| execParamQuery store.missionsDb
        "UPDATE missions SET status='cancelled', terminal_reason='cancelled', updated_at=?2, state_revision=state_revision+1 WHERE id=?1;"
        #[mid, nowIso]
      let settled ← recordSettledMcpAction store claims toolName args
        (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str "cancelled")]) nowIso mid
      return mcpOk settled
    else if toolName == "resume_mission" then
      if let some t := (args.fieldStr? "title").map (·.trimAscii.toString) then
        if !t.isEmpty then
          discard <| execParamQuery store.missionsDb "UPDATE missions SET title=?2, metadata_updated_at=?3 WHERE id=?1;" #[mid, t, nowIso]
      if let (some sup, some mr) := (remoteSup?, ← getMission? store mid) then
        if let some targetNode ← resolveMissionRemoteNode? store mc? mid then
          -- The tool schema names the steering text `content`; `prompt`/`message` are legacy aliases.
          let prompt := ((args.fieldStr? "content").orElse (fun _ => (args.fieldStr? "prompt").orElse (fun _ => args.fieldStr? "message")) |>.getD "Continue.").trimAscii.toString
          let effPrompt := if prompt.isEmpty then "Continue." else prompt
          let mut resumeSid? : Option String := none
          if let .ok sRows ← execParamQuery store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
            if sRows.size > 1 then
              let s := (cell sRows[1]! 0).trimAscii.toString
              if !s.isEmpty then resumeSid? := some s
          discard <| appendMissionEvent store mid "user_message"
            (renderCompact (.obj #[("content", .str effPrompt), ("source", .str "mcp_resume")])) nowIso
          let spec : RemoteTurnSpec := {
            missionId        := mid
            targetNodeId     := targetNode
            backend          := mr.backend
            modelOverride    := mr.modelOverride
            modelEffort      := mr.modelEffort
            workingDirectory := mr.workingDirectory
            project          := mr.project
            ownerUserId      := mr.ownerUserId
            authorityMode    := mr.authorityMode
            placementKind    := mr.placementKind
            reservedDiskGib  := mr.reservedDiskGib
            tagsJson         := mr.tagsJson
            prompt           := effPrompt
            resumeSessionId? := resumeSid?
          }
          if let .error dispErr ← submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup workingDir spec nowEpochSec then
            return mcpErr "remote_dispatch_failed" dispErr true
          let settled ← recordSettledMcpAction store claims toolName args
            (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str "active")]) nowIso mid
          return mcpOk settled
      discard <| execParamQuery store.missionsDb
        "UPDATE missions SET status='active', updated_at=?2, state_revision=state_revision+1 WHERE id=?1;"
        #[mid, nowIso]
      let settled ← recordSettledMcpAction store claims toolName args
        (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str "active")]) nowIso mid
      return mcpOk settled
    else
      let nextSt := if toolName == "adopt_mission" then "awaiting_user" else "completed"
      discard <| execParamQuery store.missionsDb
        "UPDATE missions SET status=?2, updated_at=?3, state_revision=state_revision+1 WHERE id=?1;"
        #[mid, nextSt, nowIso]
      let settled ← recordSettledMcpAction store claims toolName args
        (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str nextSt)]) nowIso mid
      return mcpOk settled

  | "update_mission_settings" =>
    let mid := (args.fieldStr? "mission_id").getD callerMid
    if mid.isEmpty then return mcpErr "invalid_arguments" "missing mission_id"
    if let some t := args.fieldStr? "title" then
      discard <| execParamQuery store.missionsDb "UPDATE missions SET title=?2, metadata_updated_at=?3 WHERE id=?1;" #[mid, t, nowIso]
    if let some mo := args.fieldStr? "model_override" then
      discard <| execParamQuery store.missionsDb "UPDATE missions SET model_override=?2, metadata_updated_at=?3 WHERE id=?1;" #[mid, mo, nowIso]
    if let some me := args.fieldStr? "model_effort" then
      discard <| execParamQuery store.missionsDb "UPDATE missions SET model_effort=?2, metadata_updated_at=?3 WHERE id=?1;" #[mid, me, nowIso]
    return mcpOk (.obj #[("ok", .bool true), ("mission_id", .str mid)])

  | "link_mission_to_project" =>
    let mid := (args.fieldStr? "mission_id").getD callerMid
    let rawProj := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD ""
    let effProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return mcpErr "project_scope_violation" e
    let folder := normalizeMissionFolder ((args.fieldStr? "folder").getD "")
    let mut curProj := ""
    if let .ok r ← execParamQuery store.missionsDb "SELECT COALESCE(project,'') FROM missions WHERE id=?1;" #[mid] then
      if r.size > 1 then curProj := cell r[1]! 0
    let upd : CheckedPlacementUpdate := {
      missionId := mid
      expectedProject := curProj
      nextProject := effProj
      nextFolder := if effProj.isEmpty then "" else folder
    }
    match ← batchSetMissionPlacementChecked store #[upd] nowIso with
    | .error (_, e) => return mcpErr "move_failed" e
    | .ok (_, changed) =>
      rebindMovedMissionMcpSessions store changed
      return mcpOk (.obj #[("ok", .bool true), ("mission_id", .str mid), ("project", .str effProj), ("folder", .str folder)])

  -- Compute Fleet & Managed Machines
  | "get_compute_fleet" =>
    let some mc := mc?
      | return mcpOk (.obj #[("nodes", .arr #[]), ("managed_nodes", .arr #[]), ("static_nodes", .arr #[])])
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let fv ← buildComputeFleetJVal relayHub? mc fleet none 0 none store.rootDir nowIso (some store)
    return mcpOk fv

  | "list_managed_machines" =>
    let some mc := mc?
      | return mcpOk (.obj #[("machines", .arr #[])])
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let prefs ← if callerUserId.isEmpty then pure #[] else getUserManagedPrefs mc callerUserId
    let .ok catalog ← loadManagedProviderCatalog mc store.rootDir fleet
        (normalizeMcpRole claims.role == "operator") prefs (managedProvisioningOverride?.map Prod.fst)
      | return mcpErr "unavailable" "managed_provider_catalog_unavailable"
    -- Destroyed machines are history, and there are thousands of them: the
    -- default list is the live ones; `verbose` adds the last 24 hours.
    let verbose := (args.fieldBool? "verbose").getD false
    let shown := fleet.machines.filter fun m =>
      m.status != "destroyed" ||
        (verbose && max m.createdAtSec m.expiresAtSec + 86400 ≥ nowEpochSec)
    let raw := renderManagedMachinesJson { fleet with machines := shown }
    return mcpOk (((OrbBin.Json.parse raw).toOption.getD (.obj #[])).setField "providers" catalog)

  | "get_budget" =>
    let some mc := mc?
      | return mcpOk (.obj #[("enabled", .bool false)])
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let targetMid := (args.fieldStr? "mission_id").getD callerMid
    if !targetMid.isEmpty then
      let bCfg ← getMissionBudgetConfig mc targetMid
      let raw := renderMissionBudgetJson fleet bCfg nowEpochSec
      return mcpOk ((OrbBin.Json.parse raw).toOption.getD (.obj #[]))
    else
      let raw := renderManagedBudgetJson fleet
      return mcpOk ((OrbBin.Json.parse raw).toOption.getD (.obj #[]))

  | "spawn_managed_machine" =>
    -- Accept at once and provision in the background: readiness takes minutes
    -- and callers used to time out with the outcome unknown. `get_action`
    -- returns the machine once it is ready, or the failure.
    -- Without a key, or without any owner to scope a receipt to, stay blocking.
    if idemKeyTop.isEmpty || (callerUserId.isEmpty && callerMid.isEmpty) then
      match ← spawnForCaller args "" with
      | .error (code, message) => return mcpErr code message
      | .ok saved =>
        return mcpOk ((OrbBin.Json.parse (renderManagedMachineItemJson saved)).toOption.getD (.obj #[]))
    let work : IO (Except String JVal) := do
      match ← spawnForCaller args "" with
      | .error (_, message) => return .error message
      | .ok saved => return .ok ((OrbBin.Json.parse (renderManagedMachineItemJson saved)).toOption.getD (.obj #[]))
    -- Arguments that can never be admitted are refused now, not in a receipt.
    let admit : IO (Except String Unit) := do
      match quoteManagedSpawnCents (canonicalizeProvider ((args.fieldStr? "provider").getD "boat"))
          ((args.fieldStr? "size").getD "small") ((args.fieldUInt64? "ttl_minutes").getD 60)
          (managedProvisioningOverride?.map Prod.fst) with
      | .ok _ => return .ok ()
      | .error e => return .error e
    match ← ManagedSpawnActions.submit store { userId := callerUserId, missionId := callerMid } idemKeyTop args work admit with
    | .error e => return mcpErr (if e == "managed_idempotency_conflict" then "conflict" else "invalid_arguments") e
    | .ok accepted => return mcpOk accepted

  | "exec_raw_managed_machine" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "node_id") |>.getD ""
    let cmd := (args.fieldStr? "command").getD ""
    if mid.isEmpty || cmd.isEmpty then
      return mcpErr "invalid_arguments" "machine_id and command are required"
    let some canonicalId ← resolveManagedMachineId? mc mid
      | return mcpErr "not_found" "Managed machine not found"
    let some (machine, _) ← getManagedMachine? mc canonicalId
      | return mcpErr "not_found" "Managed machine not found"
    if !(← canManageMachine machine) then return mcpErr "not_found" "Managed machine not found"
    let timeoutMs := ((args.fieldNat? "timeout_secs").getD 60) * 1000
    match ← execOnRemoteNode relayHub? mc canonicalId callerMid cmd false timeoutMs with
    | .ok res => return mcpOk res
    | .error e => return mcpErr "exec_failed" e true

  | "stop_managed_machine" | "resume_managed_machine" | "destroy_managed_machine" | "extend_managed_machine" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let some canonicalId ← resolveManagedMachineId? mc mid
      | return mcpErr "not_found" "Managed machine not found"
    let some (m, _) ← getManagedMachine? mc canonicalId
      | return mcpErr "not_found" "Managed machine not found"
    if !(← canManageMachine m) then return mcpErr "not_found" "Managed machine not found"
    let action := if toolName == "stop_managed_machine" then "stop"
      else if toolName == "destroy_managed_machine" then "destroy"
      else if toolName == "extend_managed_machine" then "extend" else "resume"
    match ← runConfiguredManagedLifecycle mc { store, fleet := defaultFleet, override? := managedProvisioningOverride? }
        m.id action nowEpochSec args with
    | .error e => return mcpErr "lifecycle_rejected" e
    | .ok result => return mcpOk result

  | "harvest_managed_file" =>
    -- Copy one file out of a managed VM into the caller's own workspace. The
    -- content travels provider -> Core -> the caller's node; the reply carries
    -- only where it landed and its digest, never the bytes.
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let some canonicalId ← resolveManagedMachineId? mc mid
      | return mcpErr "not_found" "Managed machine not found"
    let some (m, slice) ← getManagedMachine? mc canonicalId
      | return mcpErr "not_found" "Managed machine not found"
    if !(← canManageMachine m) then return mcpErr "not_found" "Managed machine not found"
    -- An external session has no workspace of its own to receive the file.
    if claims.isExternal && callerMid.isEmpty then
      return mcpErr "harvest_rejected" "harvest_needs_mission_workspace"
    if slice.phaseCode != 1 then return mcpErr "harvest_rejected" "managed_machine_not_running" true
    let provider ← match ← snapshotProvider m.provider with
      | .ok p => pure p
      | .error e => return mcpErr "unavailable" e true
    -- The caller may lower the cap, never raise it.
    let cap := match args.fieldNat? "max_bytes" with
      | some n => if n == 0 then ManagedHarvest.defaultMaxBytes else min n ManagedHarvest.defaultMaxBytes
      | none => ManagedHarvest.defaultMaxBytes
    let harvested ← match ← ManagedHarvest.fetch provider m.effectiveProviderId
        ((args.fieldStr? "path").getD "") { maxBytes := cap } with
      | .ok h => pure h
      | .error e => return mcpErr "harvest_rejected" e
    let name := ManagedHarvest.deliveryName harvested.sourcePath
    -- Where the caller actually runs: the node of its latest job. A stored
    -- target such as `auto` is a request, not a node, so it is resolved first.
    let callerNode? ← if callerMid.isEmpty then pure none else do
      let jobNode? ← match ← execParamQuery store.missionsDb
          ("SELECT node_id FROM remote_node_jobs WHERE mission_id=?1 AND COALESCE(node_id,'') NOT IN ('','local') " ++
           "ORDER BY updated_at DESC LIMIT 1;") #[callerMid] with
        | .ok rows => pure ((rows[1]?.map (cell · 0)).filter (!·.isEmpty))
        | .error _ => pure none
      match jobNode? with
      | some node => pure (some node)
      | none =>
        match ← resolveMissionRemoteNode? store mc? callerMid with
        | none => pure none
        | some target =>
          match ← resolveConcreteRemoteTargetNode mc? target (some (store, callerMid)) with
          | .ok node => pure (some node)
          | .error _ => pure (some target)
    let delivered : Except String (String × String) ← match callerNode? with
      | some node => do
        let body := JVal.obj #[("name", .str name),
          ("data_base64", .str (OrbBin.PosixExt.base64Encode harvested.bytes))]
        match ← callRemoteNodeHttp relayHub? mc node "POST" "/uploads" (some body) #[] 180000 with
        | .error _ => pure (.error s!"harvest_delivery_failed:unreachable:{node}")
        | .ok (status, _, receipt?, _, _) =>
          if status < 200 || status ≥ 300 then pure (.error s!"harvest_delivery_failed:http_{status}:{node}") else
          match receipt?.bind (·.fieldStr? "path") with
          | none => pure (.error s!"harvest_delivery_failed:no_receipt:{node}")
          | some path =>
            -- The node re-hashes what it stored; an older node reports only the size.
            let digestOk := match receipt?.bind (·.fieldStr? "sha256") with
              | some digest => digest == harvested.sha256
              | none => (receipt?.bind (·.fieldNat? "size")) == some harvested.bytes.size
            if digestOk then pure (.ok (node, path))
            else pure (.error s!"harvest_delivery_failed:digest_mismatch:{node}")
      | none => do
        -- A mission on the Core host, or an operator session with no mission.
        let base := if callerMid.isEmpty then store.rootDir else callerWorkDir
        let dir := System.FilePath.mk base / "harvest" / (← newUuidV4)
        let dest := dir / name
        match ← (do IO.FS.createDirAll dir; IO.FS.writeBinFile dest harvested.bytes : IO Unit).toBaseIO with
        | .ok () => pure (.ok ("local", dest.toString))
        | .error _ => pure (.error "harvest_delivery_failed")
    match delivered with
    | .error e => return mcpErr "harvest_rejected" e true
    | .ok (node, path) =>
      return mcpOk (.obj #[("machine_id", .str m.id), ("source_path", .str harvested.sourcePath),
        ("node", .str node), ("path", .str path), ("bytes", JVal.nat harvested.bytes.size),
        ("sha256", .str harvested.sha256), ("chunks", JVal.nat harvested.chunks)])

  | "snapshot_managed_machine" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let some canonicalId ← resolveManagedMachineId? mc mid
      | return mcpErr "not_found" "Managed machine not found"
    let some (machine, slice) ← getManagedMachine? mc canonicalId
      | return mcpErr "not_found" "Managed machine not found"
    if !(← canManageMachine machine) then return mcpErr "not_found" "Managed machine not found"
    let project ← snapshotProject
    if project.isEmpty then return mcpErr "snapshot_failed" "managed_snapshot_requires_project"
    if slice.phaseCode != 1 then return mcpErr "snapshot_failed" "managed_machine_not_running" true
    let provider ← match ← snapshotProvider machine.provider with
      | .ok p => pure p
      | .error e => return mcpErr "unavailable" e true
    match ← saveProjectSnapshot store provider project machine ((args.fieldStr? "name").getD "") with
    | .ok entry => return mcpOk (ManagedSnapshotCatalog.entryJson entry)
    | .error e => return mcpErr "snapshot_failed" e

  | "list_managed_snapshots" =>
    if mc?.isNone then return mcpOk (.obj #[("snapshots", .arr #[])])
    let project ← snapshotProject
    if project.isEmpty then
      return mcpOk (.obj #[("snapshots", .arr #[]), ("note", .str "This mission has no project; snapshots are project-scoped.")])
    let provider ← match ← snapshotProvider (canonicalizeProvider ((args.fieldStr? "provider").getD "boat")) with
      | .ok p => pure p
      | .error e => return mcpErr "unavailable" e true
    match ← projectSnapshotEntries store provider project with
    | .error e => return mcpErr "unavailable" e true
    | .ok entries =>
      return mcpOk (.obj #[("project", .str project),
        ("snapshots", .arr (entries.map ManagedSnapshotCatalog.entryJson))])

  | "delete_managed_snapshot" =>
    if mc?.isNone then return mcpErr "unavailable" "managed compute store not configured"
    let requested := (args.fieldStr? "name").orElse (fun _ => args.fieldStr? "snapshot_id")
      |>.orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let provider ← match ← snapshotProvider (canonicalizeProvider ((args.fieldStr? "provider").getD "boat")) with
      | .ok p => pure p
      | .error e => return mcpErr "unavailable" e true
    match ← deleteProjectSnapshot store provider (← snapshotProject) requested with
    | .ok name => return mcpOk (.obj #[("ok", .bool true), ("deleted", .str name)])
    | .error e =>
      return mcpErr (if e.startsWith "managed_snapshot_not_found" then "not_found" else "snapshot_delete_failed") e

  | "fork_managed_machine" =>
    -- A fork is rented through the shared spawn path from the source's disk: the
    -- caller owns it, pays for it and waits for its own node to enrol.
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let srcId := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "source_machine_id") |>.getD ""
    let some canonicalId ← resolveManagedMachineId? mc srcId
      | return mcpErr "not_found" "Managed machine not found"
    let some (source, slice) ← getManagedMachine? mc canonicalId
      | return mcpErr "not_found" "Managed machine not found"
    if !(← canManageMachine source) then return mcpErr "not_found" "Managed machine not found"
    if slice.phaseCode != 1 then return mcpErr "fork_rejected" "managed_machine_not_running" true
    let spawnArgs := JVal.obj #[
      ("provider", .str source.provider), ("size", .str source.size),
      ("ttl_minutes", JVal.uint64 ((args.fieldUInt64? "ttl_minutes").getD source.ttlMinutes)),
      ("name", .str ((args.fieldStr? "name").getD "")),
      ("idempotency_key", .str idemKeyTop)]
    match ← spawnForCaller spawnArgs source.effectiveProviderId with
    | .error (code, message) => return mcpErr (if code == "spawn_rejected" then "fork_rejected" else code) message
    | .ok forked =>
      let item := (OrbBin.Json.parse (renderManagedMachineItemJson forked)).toOption.getD (.obj #[])
      return mcpOk (match item with
        | .obj fields => .obj (fields.push ("forked_from", .str source.id))
        | other => other)

  -- Projects, Controller & Board
  | "list_projects" =>
    let allProjs ← listProjectsJVal store "" "" true false
    let filtered :=
      if claims.project.isEmpty then allProjs
      else allProjs.filter (fun p => (p.fieldStr? "slug") == some claims.project)
    return mcpOk (.obj #[("projects", .arr filtered)])

  | "get_project" | "get_situation" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    if slug.isEmpty then return mcpErr "invalid_arguments" "missing project slug"
    return mcpOk (← buildProjectSituationJVal store slug slug)

  | "update_project_status" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let stVal := (args.fieldStr? "status").getD "active"
    let modeVal := (args.fieldStr? "mode").getD ""
    let nextAct := (args.fieldStr? "next_action").getD ""
    let blk := (args.fieldStr? "blocker").getD ""
    discard <| upsertProjectRecord store slug slug slug "" stVal "" nowIso none
    discard <| execParamQuery store.projectsDb
      "UPDATE projects SET status=?2, mode=COALESCE(NULLIF(?3,''),mode), next_action=COALESCE(NULLIF(?4,''),next_action), blocker=?5, updated_at=?6 WHERE slug=?1;"
      #[slug, stVal, modeVal, nextAct, blk, nowIso]
    return mcpOk (← buildProjectSituationJVal store slug slug)

  | "set_project_track" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let trk := (args.fieldStr? "track").getD ""
    let des := ((args.fieldStr? "desired_condition").orElse (fun _ => args.fieldStr? "desired_state")).getD ""
    let stVal := (args.fieldStr? "status").getD "open"
    let (code, raw) ← putProjectTrack store slug trk des stVal nowIso (args.fieldNat? "expected_revision")
    if 200 ≤ code && code < 300 then
      return mcpOk ((OrbBin.Json.parse raw).toOption.getD (.obj #[("ok", .bool true)]))
    else
      return mcpErr "track_error" raw

  | "accept_project_track_evidence" | "reopen_project_track" | "accept_project_track" | "invalidate_project_track_evidence" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let trk := (args.fieldStr? "track").getD ""
    let nextSt :=
      if toolName == "accept_project_track" || toolName == "accept_project_track_evidence" then "accepted"
      else "open"
    discard <| execParamQuery store.projectsDb
      "UPDATE project_tracks SET status=?3, state_revision=state_revision+1, updated_at=?4 WHERE (project_slug=?1 OR slug=?1) AND track=?2;"
      #[slug, trk, nextSt, nowIso]
    return mcpOk (.obj #[("ok", .bool true), ("project", .str slug), ("track", .str trk), ("status", .str nextSt)])

  | "get_project_grant" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    return mcpOk (← getProjectGrantJVal store slug slug)

  | "add_project_steer" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let body := ((args.fieldStr? "body").orElse (fun _ => args.fieldStr? "message") |>.getD "")
    match ← addProjectSteerJVal store slug body "mcp" nowIso with
    | .ok sv => return mcpOk sv
    | .error e => return mcpErr "invalid_arguments" e

  | "record_project_decision" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    match ← recordProjectDecisionJVal store slug args nowIso with
    | .ok dv => return mcpOk dv
    | .error e => return mcpErr "invalid_arguments" e

  | "answer_project_decision" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let did := (args.fieldStr? "id").orElse (fun _ => args.fieldStr? "decision_id") |>.getD ""
    let ans := (args.fieldStr? "answer").getD ""
    match ← answerProjectDecisionJVal store slug did ans nowIso with
    | .ok dv => return mcpOk dv
    | .error e => return mcpErr "invalid_arguments" e

  | "get_project_tasks" | "board_status" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let sit ← buildProjectSituationJVal store slug slug
    return mcpOk (.obj #[("project", .str slug), ("tasks", (sit.field? "tasks").getD (.arr #[]))])

  | "plan_project_tasks" | "plan_tasks" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let tasksArr := (args.fieldArr? "tasks").getD #[]
    for t in tasksArr do
      let tKey ← match (t.fieldStr? "task_key").orElse (fun _ => t.fieldStr? "key") with | some k => pure k | none => newUuidV4
      let trk := (t.fieldStr? "track").getD "default"
      let mid := (t.fieldStr? "mission_id").getD ""
      let stVal := (t.fieldStr? "status").getD "open"
      discard <| execParamQuery store.missionsDb
        "INSERT INTO mission_board_tasks(task_key,project_slug,track,mission_id,attempt_seq,status) VALUES(?1,?2,?3,?4,0,?5) ON CONFLICT(task_key) DO UPDATE SET track=excluded.track,mission_id=excluded.mission_id,status=excluded.status;"
        #[tKey, slug, trk, mid, stVal]
    let sit ← buildProjectSituationJVal store slug slug
    return mcpOk (.obj #[("ok", .bool true), ("tasks", (sit.field? "tasks").getD (.arr #[]))])

  | "update_project_task" | "cancel_project_task" | "review_task" | "accept_task" | "reject_task" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    let tKey := (args.fieldStr? "task_key").orElse (fun _ => args.fieldStr? "key") |>.getD ""
    let nextSt :=
      if toolName == "cancel_project_task" then "cancelled"
      else if toolName == "accept_task" then "accepted"
      else if toolName == "reject_task" then "open"
      else if toolName == "review_task" then "in_review"
      else ((args.fieldStr? "status").getD "done")
    discard <| execParamQuery store.missionsDb
      "UPDATE mission_board_tasks SET status=?3 WHERE project_slug=?1 AND task_key=?2;" #[slug, tKey, nextSt]
    return mcpOk (.obj #[("ok", .bool true), ("task_key", .str tKey), ("status", .str nextSt)])

  -- Workspaces & Jobs
  | "list_workspaces" =>
    let mut items : Array JVal := #[]
    if let .ok rows ← execParamQuery store.missionsDb
        "SELECT id, name, workspace_type, path, status FROM workspaces ORDER BY name ASC;" #[] then
      for i in [1:rows.size] do
        let r := rows[i]!
        items := items.push (.obj #[
          ("id", .str (cell r 0)),
          ("name", .str (cell r 1)),
          ("workspace_type", .str (cell r 2)),
          ("path", .str (cell r 3)),
          ("status", .str (cell r 4))
        ])
    return mcpOk (.obj #[("workspaces", .arr items)])

  | "get_workspace" =>
    let wid := (args.fieldStr? "workspace_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    if let .ok rows ← execParamQuery store.missionsDb
        "SELECT id, name, workspace_type, path, status FROM workspaces WHERE id=?1 OR name=?1 LIMIT 1;" #[wid] then
      if rows.size > 1 then
        let r := rows[1]!
        return mcpOk (.obj #[
          ("id", .str (cell r 0)),
          ("name", .str (cell r 1)),
          ("workspace_type", .str (cell r 2)),
          ("path", .str (cell r 3)),
          ("status", .str (cell r 4))
        ])
    return mcpErr "not_found" s!"Workspace `{wid}` not found"

  | "start_workspace_job" | "get_workspace_job" | "cancel_workspace_job" =>
    let jid ← match (args.fieldStr? "job_id").filter (!·.isEmpty) with | some j => pure j | none => newUuidV4
    let stStr := if toolName == "cancel_workspace_job" then "cancelled" else "completed"
    return mcpOk (.obj #[("job_id", .str jid), ("status", .str stStr)])

  -- Bitwarden Secret Broker, Mission Access & Privilege Broker
  | "secret_list" =>
    return mcpOk (← mcpSecretList workingDir store.rootDir callerMid callerProj nowEpochSec)

  | "secret_get" =>
    let secName := (args.fieldStr? "name").orElse (fun _ => args.fieldStr? "secret_name") |>.getD ""
    let reason := (args.fieldStr? "reason").getD ""
    if secName.isEmpty then return mcpErr "invalid_arguments" "missing secret name"
    -- A caller whose mission runs on a managed machine is untrusted: allowlisted secrets only.
    let callerOnManagedNode ←
      if callerMid.isEmpty then pure false
      else do
        let node? ← resolveMissionRemoteNode? store mc? callerMid
        pure ((node?.map (·.startsWith "managed-")).getD false)
    return mcpOk (← mcpSecretGet workingDir store.rootDir callerMid callerProj secName reason callerOnManagedNode nowEpochSec)

  | "secret_request" | "secret_put" | "secret_delete" | "secret_move" =>
    let bwProj := (args.fieldStr? "bitwarden_project").orElse (fun _ => args.fieldStr? "project") |>.getD "unassigned"
    let secName := (args.fieldStr? "name").orElse (fun _ => args.fieldStr? "secret_name") |>.getD ""
    let val := (args.fieldStr? "value").getD ""
    let note := (args.fieldStr? "note").getD ""
    let reason := (args.fieldStr? "reason").getD ""
    return mcpOk (← mcpSecretQueueAction workingDir store.rootDir toolName callerMid callerProj bwProj secName val note reason nowEpochSec)

  | "request_mission_access" =>
    let targetMid := (args.fieldStr? "target_mission_id").orElse (fun _ => args.fieldStr? "mission_id") |>.getD ""
    let reason := (args.fieldStr? "reason").getD ""
    let ttlHrs := (args.fieldNat? "ttl_hours").getD 24
    if targetMid.isEmpty then return mcpErr "invalid_arguments" "missing target_mission_id"
    return mcpOk (← mcpRequestMissionAccess store.rootDir callerMid targetMid reason ttlHrs nowEpochSec)

  | "list_mission_access" =>
    return mcpOk (← mcpListMissionAccess store.rootDir callerMid nowEpochSec)

  | "request_privileged_access" =>
    let scope := (args.fieldStr? "scope").getD "service_deploy"
    let host := (args.fieldStr? "target_host").getD "self"
    let reason := (args.fieldStr? "reason").getD ""
    let singleUnit? := (args.fieldStr? "allowed_unit").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    let arrUnits := ((args.fieldArr? "allowed_units").getD #[]).filterMap JVal.asStr?
    let units := match singleUnit? with
      | some u => if arrUnits.contains u then arrUnits else #[u] ++ arrUnits
      | none => arrUnits
    let ttlMins := (args.fieldNat? "ttl_minutes").getD 30
    let sessScoped := (args.fieldBool? "session_scoped").getD true
    return mcpOk (← mcpRequestPrivilegedAccess (some store) store.rootDir callerMid claims.sessionId scope host reason units ttlMins nowEpochSec sessScoped)

  | "list_privileged_access" =>
    return mcpOk (← mcpListPrivilegedAccess store store.rootDir callerMid nowEpochSec claims.sessionId true)

  | "revoke_privileged_access" =>
    let gid := (args.fieldStr? "grant_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let rev? ← mcpRevokePrivilegedAccess store store.rootDir gid callerMid nowEpochSec
    return mcpOk (.obj #[("ok", .bool rev?.isSome), ("grant_id", .str gid)])

  | "execute_privileged_command" =>
    return mcpErr "privilege_requires_lease" "Use POST /api/privilege/exec with an active biometric-approved grant_id"

  -- Cloud Execution / Models Discovery
  | "list_cloud_models" =>
    return mcpOk (.obj #[("models", .arr #[])])

  | "list_cloud_accounts" =>
    return mcpOk (.obj #[("accounts", .arr #[])])

  | "get_cloud_execution" =>
    return mcpOk (.obj #[("enabled", .bool false)])

  | _ =>
    return mcpErr "unknown_tool" s!"Unknown or unsupported MCP tool `{toolName}`"

end OrbCore.McpGateway
