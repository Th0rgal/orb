/-
  OrbCore.McpGateway: Complete Control-Plane MCP Tool Dispatcher (`POST /api/mcp/call`)
  backing `sandboxed-mcp` (`OrbBin.McpCatalog`) for Hermes controllers, operator sessions,
  and per-mission agents (`0 import Lean`, `0 sorryAx`).
-/
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.McpCatalog
import OrbCore.DevOperator
import OrbCore.Store
import OrbCore.MissionSettings
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
import OrbCore.Cyber
import OrbCore.RemoteGoal
import OrbCore.ProxyModelRouting
import OrbCore.CloudHttpAndWorker
import OrbCore.ProjectFilesAndController
import OrbCore.MissionBoard

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
open OrbCore.MissionBoard

private def mcpOk (res : JVal) : String :=
  renderCompact (.obj #[("ok", .bool true), ("result", res)])

private def cellNat (r : Array String) (i : Nat) : Nat :=
  ((r[i]?).bind String.toNat?).getD 0

private def mcpErr (code message : String) (retryable : Bool := false) (accepted : String := "no") : String :=
  renderCompact (.obj #[
    ("ok", .bool false),
    ("error", .obj #[
      ("code", .str code),
      ("message", .str message),
      ("accepted", .str accepted),
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

/-- Check whether `claims` may read `targetMissionId` (self, own parent for child/`/btw`,
    transitive descendant, operator/coordinator in same project, or approved `mission_access.json` grant). -/
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
  if !claims.missionId.isEmpty then
    if parentMid == claims.missionId then
      return .ok ()
    -- Allow child / `/btw` missions to read their own direct parent mission.
    if let .ok callerRows ← execParamQuery store.missionsDb
        "SELECT COALESCE(parent_mission_id,'') FROM missions WHERE id=?1;" #[claims.missionId] then
      if callerRows.size > 1 && cell callerRows[1]! 0 == targetMissionId then
        return .ok ()
    -- Allow reading any transitive descendant in the caller's mission tree.
    if let .ok descRows ← execParamQuery store.missionsDb
        ("WITH RECURSIVE lineage(id) AS (SELECT id FROM missions WHERE id=?1 " ++
         "UNION SELECT m.id FROM missions m JOIN lineage l ON m.parent_mission_id=l.id) " ++
         "SELECT id FROM lineage WHERE id=?2 LIMIT 1;")
        #[claims.missionId, targetMissionId] then
      if descRows.size > 1 then
        return .ok ()
  let callerSubject := if claims.isExternal then "session:" ++ claims.sessionId
    else if !claims.missionId.isEmpty then "mission:" ++ claims.missionId else ""
  if ← hasApprovedMissionReadAccess store.rootDir claims.missionId targetMissionId nowEpochSec callerSubject then
    return .ok ()
  return .error s!"read access to mission `{targetMissionId}` requires operator role or `request_mission_access` approval"

/-- Enrich a settled MCP action result with receipt metadata (`action_id`, `tool_name`, `state`, `status`, `accepted`, `result`). -/
private def settledMcpActionReceipt (actionId toolName state : String) (resObj : JVal) (targetMissionId : String := "") : JVal :=
  let accepted := if state == "uncertain" || state == "accepted" then "unknown" else if state == "succeeded" then "yes" else "no"
  (MissionBoard.settledActionReceipt actionId toolName state resObj targetMissionId).setField "accepted" (.str accepted)

structure McpActionReservation where
  actionId : String
  replay : Bool
  receipt : JVal

/-- A durable refusal remains a failed tool call, while exposing its receipt.
    An in-flight concurrent duplicate (`state == "accepted"`) returns an explicit
    non-terminal `action_in_progress` reply (`accepted: "unknown"`) rather than
    pretending `result: {}` is a completed payload (`MCP-03`). -/
private def mcpReceiptReply (receipt : JVal) : String :=
  let st := (receipt.fieldStr? "state").getD ""
  if st == "failed" || st == "rejected" || st == "uncertain" || st == "reconciliation_required" then
    let baseErr := receipt.fieldOrNull "result"
    let errObj := if st == "uncertain" || st == "reconciliation_required" then
        baseErr.setField "accepted" (.str "unknown") |>.setField "retryable" (.bool false)
      else baseErr
    renderCompact (.obj #[("ok", .bool false), ("result", receipt), ("error", errObj)])
  else if st == "accepted" || st == "running" then
    let inProg := receipt.setField "accepted" (.str "unknown") |>.setField "in_progress" (.bool true)
    renderCompact (.obj #[
      ("ok", .bool false),
      ("result", inProg),
      ("error", .obj #[
        ("code", .str "action_in_progress"),
        ("message", .str "Action with this idempotency_key is still in progress; poll get_action."),
        ("retryable", .bool true),
        ("accepted", .str "unknown")
      ])
    ])
  else mcpOk receipt

private def actionScope (claims : McpSessionClaims) (userId tool : String) : String :=
  let actor := if claims.sessionId == "00000000-0000-4000-8000-000000000000" &&
      !userId.isEmpty then ":user:" ++ userId else ""
  s!"{claims.sessionId}:{claims.missionId}{actor}:{tool}"

private def reserveMcpAction
    (store : CoreStore) (claims : McpSessionClaims) (callerUserId toolName : String)
    (args : JVal) (nowIso targetMissionId : String) : IO (Except String McpActionReservation) := do
  let retryKey := ((args.fieldStr? "idempotency_key").getD "").trimAscii.toString
  if retryKey.isEmpty then return .error "mcp_idempotency_key_required"
  let scope := actionScope claims callerUserId toolName
  let ownerVal := if targetMissionId.isEmpty then claims.missionId else targetMissionId
  let reqJson := renderCanonical args
  let compactJson := renderCompact args
  let insertedId ← newUuidV4
  let insertResult ← execParamQuery store.projectsDb
      ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
       "VALUES(?1,?2,?3,?4,?5,?6,?7,?5,'accepted',?8,?9,?9) " ++
       "ON CONFLICT(scope,retry_key) DO NOTHING RETURNING id;")
      #[insertedId, ownerVal, scope, retryKey, reqJson,
        s!"{claims.role}:{callerUserId}:{claims.missionId}", toolName, "{}", nowIso]
  let rows ← match insertResult with
    | .ok r => pure r
    | .error _ => return .error "mcp_action_reservation_failed"
  let won := rows.size > 1
  let .ok existing ← execParamQuery store.projectsDb
      "SELECT id,tool,state,COALESCE(result,'{}'),COALESCE(owner,''),COALESCE(fingerprint,''),COALESCE(arguments,'') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2 LIMIT 1;"
      #[scope, retryKey] | return .error "mcp_action_reservation_failed"
  if existing.size ≤ 1 then return .error "mcp_action_reservation_missing"
  let r := existing[1]!
  let aid := cell r 0
  if cell r 1 != toolName then return .error "mcp_idempotency_conflict"
  let storedFp := cell r 5
  let storedArgs := cell r 6
  -- Canonicalize legacy fingerprints/arguments when checking replay equivalence (`MCP-03`)
  -- so object key reordering never triggers false conflicts while changed values always conflict.
  let storedCanon :=
    match OrbBin.Json.parse storedFp with
    | .ok jv => renderCanonical jv
    | .error _ => storedFp
  let legacyMatch := cell r 2 == "succeeded" && storedFp == retryKey &&
    (storedArgs == compactJson ||
      ((OrbBin.Json.parse storedArgs).toOption.map renderCanonical) == some reqJson)
  if storedFp != reqJson && storedCanon != reqJson && !legacyMatch then
    return .error "mcp_idempotency_conflict"
  let mut state := cell r 2
  let mut resRaw := cell r 3
  let mut ownerOut := cell r 4
  let replay := !won
  -- If a concurrent duplicate arrived while the winning call is still executing, wait
  -- briefly for settlement before returning an explicit non-terminal in-progress reply (`MCP-03`).
  if replay && state == "accepted" then
    for _ in [0:15] do
      IO.sleep 50
      if let .ok pRows ← execParamQuery store.projectsDb
          "SELECT state,COALESCE(result,'{}'),COALESCE(owner,'') FROM mcp_actions_v1 WHERE id=?1 LIMIT 1;" #[aid] then
        if pRows.size > 1 then
          state := cell pRows[1]! 0
          resRaw := cell pRows[1]! 1
          ownerOut := cell pRows[1]! 2
          if state != "accepted" then break
  let result := (OrbBin.Json.parse resRaw).toOption.getD (.obj #[])
  let receipt := settledMcpActionReceipt aid (cell r 1) state result ownerOut
  return .ok { actionId := aid, replay := replay, receipt := receipt }

/-- Look up a persisted MCP action receipt by `id` from `mcp_actions_v1`. -/
private def lookupMcpActionById? (store : CoreStore) (actionId : String) : IO (Option JVal) := do
  if actionId.trimAscii.toString.isEmpty then return none
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT id, tool, state, COALESCE(result,'{}'), COALESCE(owner,''), created_at, updated_at FROM mcp_actions_v1 WHERE id=?1 LIMIT 1;"
      #[actionId]
    | return none
  if rows.size ≤ 1 then return ← MissionBoard.actionById? store.missionsDb actionId
  let r := rows[1]!
  let aid := cell r 0
  let tname := cell r 1
  let stStr := cell r 2
  let resJv := (OrbBin.Json.parse (cell r 3)).toOption.getD (.obj #[])
  let tmid := cell r 4
  return some (settledMcpActionReceipt aid tname stStr resJv tmid)

/-- Look up a previously settled MCP action receipt by `(scope, retry_key)`. -/
private def lookupMcpActionByRetryKey? (store : CoreStore) (scope retryKey : String) : IO (Option JVal) := do
  if retryKey.trimAscii.toString.isEmpty then return none
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT id, tool, state, COALESCE(result,'{}'), COALESCE(owner,'') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2 ORDER BY updated_at DESC LIMIT 1;"
      #[scope, retryKey]
    | return none
  if rows.size ≤ 1 then return ← MissionBoard.actionByKey? store.missionsDb scope retryKey
  let r := rows[1]!
  let raw := cell r 3
  if raw.isEmpty then return none
  let some resJv := (OrbBin.Json.parse raw).toOption | return none
  return some (settledMcpActionReceipt (cell r 0) (cell r 1) (cell r 2) resJv (cell r 4))

/-- Persist a settled MCP action receipt in `mcp_actions_v1` and enrich `resObj` with `action_id`/`state`/`accepted`. -/
private def recordSettledMcpAction
    (store : CoreStore)
    (claims : McpSessionClaims)
    (callerUserId : String)
    (toolName : String)
    (args : JVal)
    (resObj : JVal)
    (nowIso : String)
    (targetMissionId : String := "") : IO (Except String JVal) := do
  let actId ← newUuidV4
  let retryKey := ((args.fieldStr? "idempotency_key").getD "").trimAscii.toString
  let effRetryKey := if retryKey.isEmpty then s!"auto:{actId}" else retryKey
  let scope := actionScope claims callerUserId toolName
  let ownerVal := if targetMissionId.isEmpty then claims.missionId else targetMissionId
  let payload := resObj.removeField "result"
  let enriched := settledMcpActionReceipt actId toolName "succeeded" payload ownerVal
  let resJson := renderCompact payload
  let reqJson := renderCanonical args
  let principalVal := s!"{claims.role}:{callerUserId}:{claims.missionId}"
  let .ok existing ← execParamQuery store.projectsDb
      "SELECT id FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2 LIMIT 1;" #[scope, effRetryKey]
    | return .error "mcp_action_record_failed"
  if existing.size > 1 then
    let storedId := cell existing[1]! 0
    let .ok _ ← execParamQuery store.projectsDb
        "UPDATE mcp_actions_v1 SET state='succeeded',result=?2,updated_at=?3,owner=?4 WHERE id=?1 AND state='accepted';"
        #[storedId, resJson, nowIso, ownerVal]
      | return .error "mcp_action_record_failed"
    let some receipt ← lookupMcpActionById? store storedId
      | return .error "mcp_action_record_failed"
    return .ok receipt
  let .ok _ ← execParamQuery store.projectsDb
    ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
     "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'succeeded',?9,?10,?10);")
    #[actId, ownerVal, scope, effRetryKey, reqJson, principalVal, toolName, reqJson, resJson, nowIso]
    | return .error "mcp_action_record_failed"
  return .ok enriched

private def settleReservedMcpAction
    (store : CoreStore) (claims : McpSessionClaims) (callerUserId toolName key state message nowIso : String)
    (code : String := "mutation_failed") (retryable? : Option Bool := none)
    (targetMissionId : String := "") : IO String := do
  let scope := actionScope claims callerUserId toolName
  let accepted := if state == "uncertain" then "unknown" else "no"
  let retryable := retryable?.getD (state == "failed")
  let payload := renderCompact (.obj #[
    ("error", .str message), ("message", .str message), ("code", .str code), ("accepted", .str accepted), ("retryable", .bool retryable)])
  let .ok _ ← execParamQuery store.projectsDb
      "UPDATE mcp_actions_v1 SET state=?3,result=?4,updated_at=?5,owner=CASE WHEN ?6<>'' THEN ?6 ELSE owner END WHERE scope=?1 AND retry_key=?2 AND state='accepted';"
      #[scope, key, state, payload, nowIso, targetMissionId]
    | return mcpErr "receipt_record_failed" "The mutation outcome could not be recorded." false accepted
  return mcpErr code message retryable accepted

private def failReservedOrErr
    (store : CoreStore) (claims : McpSessionClaims) (callerUserId toolName key code message nowIso : String)
    (retryable : Bool := false) (targetMissionId : String := "") : IO String := do
  if key.isEmpty then
    return mcpErr code message retryable
  settleReservedMcpAction store claims callerUserId toolName key "failed" message nowIso code (some retryable) targetMissionId

/-- Classify managed VM lifecycle / fork errors that occur AFTER a durable reservation,
    cost charge, or cloud provider call with an ambiguous remote outcome (`MCP-03`). -/
private def isManagedLifecycleUncertainError (err : String) : Bool :=
  if err.startsWith "managed_user_missing" || err.startsWith "managed_user_disabled" ||
     err.startsWith "mission_budget_exceeded:" || err.startsWith "managed_ttl_invalid" then
    false
  else
    err == "managed_extension_outcome_uncertain" ||
    err == "managed_lifecycle_commit_failed" ||
    err == "provider_http_error" ||
    err.startsWith "provider_http_error:" ||
    ManagedSpawnActions.uncertain err

private def isPendingActionState (state : String) : Bool :=
  #["accepted", "running", "queued", "pending", "dispatching"].contains state

private def isUncertainActionState (state : String) : Bool :=
  state == "uncertain" || state == "reconciliation_required"

private def isSucceededActionState (state : String) : Bool :=
  state == "succeeded" || state == "completed"

/-- Extract the latest bounded assistant reply for `get_consult_result`. -/
private def lastConsultAnswer? (store : CoreStore) (mid : String) (detail : JVal)
    (maxChars : Nat := 20000) : IO (Option String) := do
  let bound (raw : String) : String :=
    let trimmed := raw.trimAscii.toString
    if trimmed.length ≤ maxChars then trimmed
    else (trimmed.take maxChars).toString ++ "\n...[truncated]"
  if let .ok rows ← execParamQuery store.missionsDb
      ("SELECT COALESCE(content,''), COALESCE(payload,'{}') FROM mission_events " ++
       "WHERE mission_id=?1 AND event_type IN ('assistant_message','assistant_message_canonical','agent_message') " ++
       "ORDER BY COALESCE(seq, sequence, 0) DESC, id DESC LIMIT 10;") #[mid] then
    for i in [1:rows.size] do
      let r := rows[i]!
      let ec := (cell r 0).trimAscii.toString
      let ep := (cell r 1).trimAscii.toString
      let txt :=
        if !ec.isEmpty then ec
        else match OrbBin.Json.parse ep with
          | .ok pj => ((pj.fieldStr? "content").orElse (fun _ => pj.fieldStr? "text") |>.getD "").trimAscii.toString
          | .error _ => ep
      if !txt.isEmpty then
        return some (bound txt)
  if let some hItems := detail.fieldArr? "history" then
    for it in hItems.reverse do
      if it.fieldStr? "role" == some "assistant" then
        let c := ((it.fieldStr? "content").getD "").trimAscii.toString
        if !c.isEmpty then return some (bound c)
  if let some summary := ((detail.fieldOrNull "terminal_evidence").fieldStr? "summary").map (·.trimAscii.toString) then
    if !summary.isEmpty then return some (bound summary)
  return none

/-- Own the whole reserved branch, including early returns and thrown IO errors.
    Only an accepted row may transition; retries and terminal rows are immutable.
    A failed durable write is explicitly uncertain, never permission to retry fresh. -/
def withReservedMcpOutcome (store : CoreStore) (claims : McpSessionClaims)
    (userId tool key nowIso : String) (work : IO String) : IO String := do
  if key.isEmpty then
    return ← work
  let fallback := mcpOk (.obj #[("state", .str "uncertain"), ("accepted", .str "unknown"),
    ("tool_name", .str tool), ("error", .str "receipt_settlement_unavailable"), ("retryable", .bool false)])
  try
    let raw ← try work catch _ => pure fallback
    let scope := actionScope claims userId tool
    -- Any branch that did not explicitly settle has an unknown effect boundary.
    let .ok _ ← execParamQuery store.projectsDb
        "UPDATE mcp_actions_v1 SET state='uncertain',result=?3,updated_at=?4 WHERE scope=?1 AND retry_key=?2 AND state='accepted';"
        #[scope, key, renderCompact (.obj #[("error", .str "mutation_outcome_uncertain")]), nowIso]
      | return fallback
    if let some receipt ← lookupMcpActionByRetryKey? store scope key then
      -- Preserve explicit validation/operational errors even when their effect
      -- boundary requires an uncertain journal outcome.
      let parsed := (OrbBin.Json.parse raw).toOption.getD .null
      if receipt.fieldStr? "state" == some "uncertain" && parsed.fieldBool? "ok" == some false then
        let err := (parsed.fieldOrNull "error").setField "accepted" (.str "unknown")
          |>.setField "retryable" (.bool false)
        return renderCompact ((parsed.setField "error" err).setField "result" receipt)
      return mcpReceiptReply receipt
    return raw
  catch _ => return fallback

/-- Startup-only, after exclusive listen-port ownership and before dispatch.
    Generic recovery never changes provider-spawn rows or settled outcomes. -/
def fenceInterruptedGenericActions (store : CoreStore) : IO (Except String Unit) := do
  let now := formatEpochIso8601Utc (← coreEpochSec)
  match ← execParamQuery store.projectsDb
      "UPDATE mcp_actions_v1 SET state='uncertain',result=?1,updated_at=?2 WHERE tool<>'spawn_managed_machine' AND state IN ('accepted','running');"
      #[renderCompact (.obj #[("error", .str "core_restarted_during_action")]), now] with
  | .error _ => return .error "generic_action_recovery_failed"
  | .ok _ => return .ok ()

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

/-- The live stored session issuer, with a mission-owner fallback only for native
    mission tokens that predate persisted sessions. Never accept a body identity. -/
def scopedCallerUserId? (store : CoreStore) (claims : McpSessionClaims) (now : UInt64) : IO (Option String) := do
  if claims.isExternal then return (← externalManagedOwner? store claims now).map Prod.fst
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT owner FROM mcp_sessions_v1 WHERE id=?1;" #[claims.sessionId] | return none
  if rows.size > 1 then return some (cell rows[1]! 0)
  return (← getMission? store claims.missionId).map (·.ownerUserId)

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
/-- Models that actually served a mission's proxied requests, from the usage ledger:
    the name the harness asked for, the model and provider that answered, and how often.
    Empty when no request has completed or the harness does not use the proxy. -/
def servedModelsJson (store : CoreStore) (missionId : String) : IO JVal := do
  let .ok rows ← execParamQuery store.missionsDb
      ("SELECT COALESCE(requested_model,''),COALESCE(model,''),COALESCE(provider,''),COUNT(*) FROM proxy_usage " ++
       "WHERE mission_id=?1 GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 20;") #[missionId]
    | return .arr #[]
  return .arr ((rows.extract 1 rows.size).map fun r =>
    .obj #[("requested_model", .str (r[0]?.getD "")), ("effective_model", .str (r[1]?.getD "")),
      ("provider", .str (r[2]?.getD "")), ("requests", JVal.nat ((r[3]?.bind String.toNat?).getD 0))])

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
    (authenticatedAdmin : Bool := false)
    (askSide? : Option (String → String → String → IO (Except String String)) := none)
    (answerQuestion? : Option (String → String → String → JVal → IO (Except String (Option String))) := none)
    (cloudHub? : Option OrbCore.CloudHttpAndWorker.CloudRuntimeHub := none) : IO String := do
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
        if callerProj.isEmpty || toolName == "read_project_board" || toolName == "write_project_board" then callerProj := pj
        callerUserId := cell mRows[1]! 2

  if claims.isExternal then
    -- Never fall back to a mission or request-body identity for an external session.
    callerUserId := ""
    if let some (userId, project) ← externalManagedOwner? store claims nowEpochSec then
      callerUserId := userId
      callerProj := project
  else if directOperator then
    callerUserId := authenticatedUserId

  -- A shared mission's owner is not the identity of the user who minted its
  -- session. The persisted issuer remains authoritative for every tool/role.
  if !claims.isExternal && !directOperator && !claims.missionId.isEmpty then
    if let some uid ← scopedCallerUserId? store claims nowEpochSec then callerUserId := uid
  -- A missionless coordinator session (an owner's local harness) has no mission to resolve:
  -- its identity is the live stored issuer. A rowless or revoked token stays anonymous.
  if !claims.isExternal && !directOperator && claims.missionId.isEmpty then
    if let .ok rows ← execParamQuery store.projectsDb
        ("SELECT owner FROM mcp_sessions_v1 WHERE id=?1 AND revoked=0 AND COALESCE(owner,'')<>'' " ++
         "AND COALESCE(mission_id,'')='' AND (hard_expires_at=0 OR hard_expires_at>?2);")
        #[claims.sessionId, toString nowEpochSec] then
      if rows.size > 1 then callerUserId := cell rows[1]! 0

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

  let managedPreferenceUserId :=
    if !callerUserId.isEmpty then callerUserId
    else if !callerMid.isEmpty || claims.isExternal then ""
    else match operatorPrincipal? with
      | some uid => if uid.isEmpty then "admin" else uid
      | none => ""

  -- A read-only mission is an inspection/review worker.  Its scoped MCP token
  -- must not be able to turn that capability into a mutating child, message,
  -- cancellation, board write, or machine operation.  Keep the decision in
  -- Core, beside the persisted authority mode, rather than trusting tags or
  -- prompt text supplied by the worker.
  let readonlyCaller ← if callerMid.isEmpty then pure false else
    match ← execParamQuery store.missionsDb
      "SELECT COALESCE(authority_mode,'writer') FROM missions WHERE id=?1;" #[callerMid] with
    | .ok rows => pure (rows.size > 1 && cell rows[1]! 0 == "readonly")
    | .error _ => pure false

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
      -- User-owned machines have no project/lineage to delegate to a mission;
      -- dashboard/external callers keep their own user-owned fleet.
      if !callerMid.isEmpty then return false
      return (claims.isExternal || directOperator || !callerUserId.isEmpty) &&
        machine.ownerUserId == callerUserId && callerProj.isEmpty
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

  -- The provider of a spawn that may omit it: the one named, else the instance default,
  -- else its fallback when the default cannot take the request now. A snapshot or a
  -- fork (`pinned`) lives at one provider and is never moved.
  let chooseSpawnProvider (spawnArgs : JVal) (pinned : Bool) : IO ManagedProviderChoice := do
    let named? := ((spawnArgs.fieldStr? "provider").map canonicalizeProvider).filter (!·.isEmpty)
    let instanceDefault ← defaultManagedProvider
    let some mc := mc? | return { provider := named?.getD instanceDefault }
    let snapshot := ((spawnArgs.fieldStr? "from_snapshot").orElse
      (fun _ => spawnArgs.fieldStr? "managed_from_snapshot") |>.getD "").trimAscii.toString
    -- A retry stays with the provider its first attempt reserved on, so one key rents once.
    if let (none, some key) := (named?, (spawnArgs.fieldStr? "idempotency_key").filter (!·.isEmpty)) then
      let requestKey := scopedManagedRequestKey callerUserId callerMid key
      for candidate in #[instanceDefault, managedFallbackProvider] do
        if (← getManagedMachineByRequestKey? mc candidate requestKey).isSome then return { provider := candidate }
    chooseManagedProvider named? instanceDefault (pinned || !snapshot.isEmpty) fun candidate => do
      let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
          defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
        | .ok f => pure f
        | .error _ => pure defaultFleet
      let prefs ← if managedPreferenceUserId.isEmpty then pure #[] else getUserManagedPrefs mc managedPreferenceUserId
      let user? ← getUserById? store callerUserId
      let (inferenceSpent, computeSpent) ← if callerUserId.isEmpty then pure (0, 0)
        else getUserSpentTodayCents store callerUserId (nowIso.take 10).toString
      managedSpawnRefusal mc store.rootDir fleet prefs callerUserId candidate spawnArgs
        (inferenceSpent + computeSpent) (user?.bind (·.dailySpendCapCents?)) managedProvisioningOverride?

  let resolveSpawnSize (provider : String) (spawnArgs : JVal) : IO (Except String String) :=
    resolveObservedSpawnSize store.rootDir provider spawnArgs managedProvisioningOverride?.isNone

  -- One spawn path for `spawn_managed_machine` and `start_mission(auto-managed)`:
  -- same provider decision, admission, pricing, project-scoped snapshot resolution and bootstrap.
  let spawnForCaller (spawnArgs : JVal) (forkOfProviderId : String) :
      IO (Except (String × String) (ManagedMachine × ManagedProviderChoice)) := do
    let some mc := mc? | return .error ("unavailable", "managed compute store not configured")
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let choice ← chooseSpawnProvider spawnArgs (!forkOfProviderId.isEmpty)
    let prov := choice.provider
    let prefs ← if managedPreferenceUserId.isEmpty then pure #[] else getUserManagedPrefs mc managedPreferenceUserId
    if !isUserManagedProviderEnabled prefs prov then
      return .error ("provider_disabled_for_user", "This cloud provider is disabled in your preferences.")
    let sz ← match ← resolveSpawnSize prov spawnArgs with
      | .ok size => pure size
      | .error e => return .error ("invalid_arguments", e)
    let ttl := (spawnArgs.fieldUInt64? "ttl_minutes").getD 60
    let sName ← newManagedSandboxName ((spawnArgs.fieldStr? "name").getD "")
    let mid ← newUuidV4
    let quote ← match quoteManagedSpawnCents prov sz ttl (managedProvisioningOverride?.map Prod.fst) with
      | .ok cents => pure cents
      | .error e => return .error ("invalid_arguments", e)
    let callerUser? ← getUserById? store callerUserId
    if !callerUserId.isEmpty && (callerUser?.isNone || (callerUser?.map (·.disabled)).getD true) then
      return .error ("user_unavailable", "The owning user is unavailable.")
    let (infSpent, cmpSpent) ← if callerUserId.isEmpty then pure (0, 0)
      else getUserSpentTodayCents store callerUserId (nowIso.take 10).toString
    let userCap? := callerUser?.bind (·.dailySpendCapCents?)
    let userAdmission? := managedUserAdmissionOf ((callerUser?.map (·.role)).getD "") userCap?
      infSpent cmpSpent (← memberMaxMachines)
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
    | .ok spawned => return .ok (spawned.machine, choice)

  -- Enforce tenant ownership BEFORE dispatch and idempotent replay. An MCP role
  -- describes mission delegation, never authority over another user's objects.
  let tenantScoped := !callerUserId.isEmpty || claims.isExternal
  let user? ← getUserById? store callerUserId
  let userIsAdmin := (user?.map (fun u => !u.disabled && u.role == "admin")).getD false ||
    (directOperator && authenticatedAdmin)
  if (claims.isExternal && callerUserId.isEmpty) ||
      (!callerUserId.isEmpty && !(user?.map (fun u => !u.disabled)).getD false) then
    return mcpErr "forbidden" "Account unavailable"
  let missionReadTools := #["get_mission", "get_mission_health", "get_mission_diagnostics",
    "get_mission_events", "list_mission_shared_files", "get_consult_result", "get_cloud_execution", "get_budget"]
  let missionWriteTools := #["send_message_to_mission", "ask_mission", "answer_mission_question",
    "cancel_mission", "acknowledge_mission", "adopt_mission", "resume_mission", "update_mission_settings",
    "update_mission_metadata", "link_mission_to_project", "schedule_wakeup", "schedule_job_wakeup"]
  -- The REST collaboration class permits messages and cancellation to shared
  -- participants; changing owner settings/placement or resuming remains owner-only.
  let collaborateTools := #["send_message_to_mission", "ask_mission", "answer_mission_question", "cancel_mission"]
  let missionInTree (ancestor candidate : String) : IO Bool := do
    if ancestor == candidate then return true
    match ← execParamQuery store.missionsDb
        ("WITH RECURSIVE lineage(id) AS (SELECT id FROM missions WHERE id=?1 AND owner_user_id=?3 " ++
         "UNION SELECT m.id FROM missions m JOIN lineage l ON m.parent_mission_id=l.id " ++
         "WHERE m.owner_user_id=?3) SELECT id FROM lineage WHERE id=?2 LIMIT 1;")
        #[ancestor, candidate, callerUserId] with
    | .ok rows => return rows.size > 1
    | .error _ => return false
  let sameMissionTree (a b : String) : IO Bool := do
    if a == b then return true
    if a.isEmpty || b.isEmpty then return false
    if ← missionInTree a b then return true
    missionInTree b a
  let checkTenantMission (mid : String) (allowParticipant : Bool) (allowReadGrant : Bool := false) : IO Bool := do
    if !tenantScoped then return true
    let (exists_, owns, shares) ← getMissionRelationship store mid callerUserId
    if !exists_ then return false
    if allowParticipant && shares then return true
    if !owns then return false
    -- A mission session acts inside its own lineage, not every mission the same
    -- user happens to own (`R16`: unrelated same-user trees stay isolated unless
    -- explicitly bridged by an approved cross-mission read grant).
    if callerMid.isEmpty || claims.isExternal then return true
    if ← sameMissionTree callerMid mid then return true
    if allowReadGrant then
      return ← hasApprovedMissionReadAccess store.rootDir callerMid mid nowEpochSec ("mission:" ++ callerMid)
    return false
  if toolName == "get_consult_result" then
    match args.field? "mission_ids" with
    | none | some .null => pure ()
    | some _ =>
      return mcpErr "unsupported" "Batch/quorum consultation polling (`mission_ids`) is not supported; poll `get_consult_result` with a single `mission_id`."
  if missionReadTools.contains toolName || missionWriteTools.contains toolName then
    let mid := (args.fieldStr? "mission_id").orElse (fun _ =>
      (args.fieldStr? "target_mission_id").orElse (fun _ => args.fieldStr? "id")) |>.getD callerMid
    unless mid.isEmpty && toolName == "get_budget" do
      let isRead := missionReadTools.contains toolName
      unless ← checkTenantMission mid (isRead || collaborateTools.contains toolName) isRead do
        return mcpErr "not_found" "Mission not found"
  if toolName == "start_mission" || toolName == "consult_model" then
    let parent := (args.fieldStr? "parent_mission_id").getD callerMid
    unless parent.isEmpty do
      unless ← checkTenantMission parent false do return mcpErr "not_found" "Mission not found"
  -- Vault and host-approval state belong to the server owner. Members cannot
  -- inspect or enqueue owner actions, even with a self-selected operator role.
  let legacyOwner := !tenantScoped && (← getBootstrapAdmin? store).isNone
  let devTool := #["get_dev_access", "deploy_dev", "read_dev_logs", "list_privileged_access"].contains toolName ||
    (toolName == "request_privileged_access" && (args.fieldStr? "scope").getD "" == "dev_operator")
  let ownsDevMission ← if devTool && !claims.isExternal && !callerMid.isEmpty then
    checkTenantMission callerMid false else pure false
  if tenantScoped && #["request_mission_access", "list_mission_access"].contains toolName &&
      (!userIsAdmin || !callerMid.isEmpty) then
    unless !callerMid.isEmpty && (← checkTenantMission callerMid false) do
      return mcpErr "not_found" "Mission not found"
  if !userIsAdmin && !legacyOwner && !ownsDevMission && (toolName.startsWith "secret_" ||
      #["list_privileged_access", "request_privileged_access", "revoke_privileged_access",
        "execute_privileged_command", "get_dev_access", "deploy_dev", "read_dev_logs",
        "get_fleet_sweep", "reconcile_action", "list_cloud_accounts"].contains toolName) then
    return mcpErr "forbidden" "Administrator required"
  if toolName == "read_project_board" || toolName == "write_project_board" then
    let some mission ← getMission? store callerMid | return mcpErr "no_project" "Mission has no project"
    callerProj := mission.project
  if (toolName == "read_project_board" || toolName == "write_project_board") && (callerMid.isEmpty || callerProj.isEmpty) then
    return mcpErr "no_project" "Mission has no project"
  let projectTools := #["read_project_board", "write_project_board", "get_project", "update_project_status", "get_project_grant", "set_project_grant", "link_mission_to_project", "create_project_folder", "rename_project_folder"]
  let mut args := args
  if tenantScoped && projectTools.contains toolName then
    let raw := if toolName == "read_project_board" || toolName == "write_project_board" then callerProj
      else (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let bootstrap := ((← getBootstrapAdmin? store).map (·.id)).getD ""
    let scopedSlug := (scopeProjectSlug callerUserId bootstrap raw).getD raw
    let .ok rows ← execParamQuery store.projectsDb
        "SELECT slug FROM project_owners WHERE owner_user_id=?1 AND (slug=?2 OR slug=?3) ORDER BY (slug=?3) DESC LIMIT 1;"
        #[callerUserId, raw, scopedSlug] | return mcpErr "not_found" "Project not found"
    unless rows.size > 1 do return mcpErr "not_found" "Project not found"
    let slug := cell rows[1]! 0
    args := args.setField "project" (.str slug) |>.setField "slug" (.str slug)
  let scopedUid? := if tenantScoped then some callerUserId else none
  let (_, userComputeSpent) ← if tenantScoped then getUserSpentTodayCents store callerUserId (nowIso.take 10).toString
    else pure (0, 0)
  let userCap? := user?.bind (·.dailySpendCapCents?)

  let lookupCallerAction? (aid : String) : IO (Option JVal) := do
    if let some (owner, _) ← MissionBoard.actionScope? store.missionsDb aid then
      unless ← checkTenantMission owner false do return none
      return ← MissionBoard.actionById? store.missionsDb aid
    if tenantScoped then
      let .ok rows ← execParamQuery store.projectsDb
          "SELECT COALESCE(owner,''),scope FROM mcp_actions_v1 WHERE id=?1;" #[aid] | return none
      unless rows.size > 1 do return none
      let owner := cell rows[1]! 0
      if owner.isEmpty then
        let scope := cell rows[1]! 1
        unless scope.startsWith ((actionScope claims callerUserId "") ) do return none
      else
        unless ← checkTenantMission owner true do return none
    lookupMcpActionById? store aid

  -- Idempotent replay for retried mutating MCP calls carrying `idempotency_key`
  let idemKeyTop := ((args.fieldStr? "idempotency_key").getD "").trimAscii.toString
  if readonlyCaller && OrbBin.McpCatalog.isMutatingControlTool toolName then
    return mcpErr "read_only_mission" "This mission was launched with writer:false and cannot use mutating MCP tools."
  -- Reserve before effects, replay before admission, and settle each winning row
  -- once. Every reserved branch is enclosed by withReservedMcpOutcome (`MCP-03`).
  let receiptTools := #[
    "send_message_to_mission", "cancel_mission", "start_mission", "consult_model",
    "import_mission", "resume_mission", "adopt_mission", "acknowledge_mission",
    "schedule_wakeup", "schedule_job_wakeup", "ask_mission", "answer_mission_question",
    "reconcile_action", "update_project_status", "set_project_grant",
    "stop_managed_machine", "resume_managed_machine", "destroy_managed_machine",
    "extend_managed_machine", "snapshot_managed_machine", "delete_managed_snapshot",
    "fork_managed_machine", "update_mission_settings", "link_mission_to_project",
    "create_project_folder", "rename_project_folder", "update_mission_metadata"
  ]
  let targetOwnerMid :=
    if #["send_message_to_mission", "cancel_mission", "resume_mission", "adopt_mission",
         "acknowledge_mission", "schedule_wakeup", "schedule_job_wakeup", "ask_mission",
         "answer_mission_question", "update_mission_settings", "link_mission_to_project",
         "update_mission_metadata"].contains toolName then
      ((args.fieldStr? "mission_id").orElse (fun _ =>
        (args.fieldStr? "target_mission_id").orElse (fun _ => args.fieldStr? "id")) |>.filter (!·.isEmpty)).getD callerMid
    else callerMid
  if receiptTools.contains toolName && !idemKeyTop.isEmpty && toolName != "get_action" && toolName != "wait_actions" &&
      toolName != "cancel_action" && toolName != "write_project_board" && toolName != "write_mission_board" &&
      toolName != "spawn_managed_machine" then
    match ← reserveMcpAction store claims callerUserId toolName args nowIso targetOwnerMid with
    | .error e =>
      let code := if e == "mcp_idempotency_conflict" then "conflict" else "receipt_reservation_failed"
      return mcpErr code e
    | .ok reservation =>
      if reservation.replay then return mcpReceiptReply reservation.receipt

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
    if let some rec ← lookupCallerAction? aid then
      return mcpOk rec
    return mcpErr "not_found" "Action not found"

  | "reconcile_action" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    if normalizeMcpRole claims.role != "operator" then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" "reconcile_action requires operator role" nowIso
    let aid := ((args.fieldStr? "action_id").orElse (fun _ => args.fieldStr? "id") |>.getD "").trimAscii.toString
    if aid.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing action_id" nowIso
    let resolution := ((args.fieldStr? "resolution").getD "").trimAscii.toString
    if resolution != "completed" && resolution != "rejected" then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "resolution must be 'completed' or 'rejected'" nowIso
    let evidence := ((args.fieldStr? "evidence").getD "").trimAscii.toString
    if evidence.isEmpty || evidence.utf8ByteSize > 4096 then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "evidence is required (1..=4096 bytes)" nowIso
    if idemKeyTop.isEmpty || idemKeyTop.utf8ByteSize > 200 then
      return mcpErr "invalid_arguments" "missing idempotency_key"
    let readTargetAction : IO (Option JVal) := do
      if ← ManagedSpawnActions.isSpawnAction store aid then
        match ← ManagedSpawnActions.read? store aid { userId := callerUserId, missionId := callerMid } operatorIsAdmin with
        | .ok (some spawnAction) => return some spawnAction
        | _ => return none
      lookupCallerAction? aid
    let some existingRec ← readTargetAction
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Action not found" nowIso
    let curState := (existingRec.fieldStr? "state").getD ""
    if !isUncertainActionState curState then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_state" s!"Only uncertain actions may be reconciled; action `{aid}` is `{curState}`" nowIso
    let nextState := if resolution == "rejected" then "rejected" else "succeeded"
    let actor := if !callerUserId.isEmpty then callerUserId else claims.sessionId
    let reconciledPayload := JVal.obj #[
      ("reconciled", .bool true),
      ("resolution", .str resolution),
      ("evidence", .str evidence),
      ("reconciled_at", .str nowIso),
      ("reconciled_by", .str actor),
      ("previous_state", .str curState),
      ("previous_result", existingRec.fieldOrNull "result")
    ]
    match ← execParamQuery store.projectsDb
        "UPDATE mcp_actions_v1 SET state=?2, result=?3, updated_at=?4 WHERE id=?1 AND state IN ('uncertain','reconciliation_required') RETURNING id;"
        #[aid, nextState, renderCompact reconciledPayload, nowIso] with
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "db_error" e nowIso true
    | .ok updated =>
      if updated.size ≤ 1 then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_state" s!"Action `{aid}` is no longer uncertain and cannot be reconciled" nowIso
    let some targetReceipt ← readTargetAction
      | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "Reconciled action receipt could not be reloaded" nowIso
    let recResObj := JVal.obj #[
      ("target_action_id", .str aid),
      ("resolution", .str resolution),
      ("evidence", .str evidence),
      ("receipt", targetReceipt)
    ]
    let targetMid := (targetReceipt.fieldStr? "target_mission_id").getD ""
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args recResObj nowIso targetMid
      | return mcpErr "receipt_record_failed" "The action was reconciled but its receipt could not be recorded." false
    return mcpOk settled

  | "wait_actions" =>
    let idsArr : Array String :=
      match args.fieldArr? "action_ids" with
      | some xs => xs.filterMap JVal.asStr? |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      | none =>
        match (args.fieldStr? "action_id").filter (fun s => !s.trimAscii.toString.isEmpty) with
        | some s => #[s.trimAscii.toString]
        | none => #[]
    if idsArr.isEmpty then
      return mcpErr "invalid_arguments" "action_ids must contain at least one action_id"
    if idsArr.size > 64 then
      return mcpErr "invalid_arguments" "action_ids accepts at most 64 entries"
    let returnWhen ← match args.field? "return_when" with
      | none | some .null => pure "all"
      | some (.str "all") => pure "all"
      | some (.str "any") => pure "any"
      | some _ => return mcpErr "invalid_arguments" "invalid return_when; expected 'all' or 'any'"
    let timeoutMs ← match args.field? "timeout_ms" with
      | none | some .null => pure 15000
      | some v =>
        match v.asNat? with
        | some n => pure (Nat.min n 30000)
        | none => return mcpErr "invalid_arguments" "timeout_ms must be a non-negative integer"
    let readWaitSnapshot : IO (Array JVal × Array String × Nat × Bool × Bool × Bool) := do
      let mut receipts : Array JVal := Array.mkEmpty idsArr.size
      let mut pendingIds : Array String := #[]
      for aid in idsArr do
        -- Spawn receipts stay owner-scoped and report their real state here too.
        let rec ← if ← ManagedSpawnActions.isSpawnAction store aid then
            match ← ManagedSpawnActions.read? store aid { userId := callerUserId, missionId := callerMid } operatorIsAdmin with
            | .ok (some spawnAction) => pure spawnAction
            | _ => pure (.obj #[("action_id", .str aid), ("state", .str "not_found"), ("status", .str "not_found"), ("accepted", .str "no")])
          else
            match ← lookupCallerAction? aid with
            | some r => pure r
            | none => pure (.obj #[("action_id", .str aid), ("status", .str "not_found"), ("state", .str "not_found"), ("accepted", .str "no")])
        if isPendingActionState ((rec.fieldStr? "state").getD "") then
          pendingIds := pendingIds.push ((rec.fieldStr? "action_id").getD aid)
        receipts := receipts.push rec
      let settledCount := receipts.size - pendingIds.size
      let allSettled := pendingIds.isEmpty
      let allSucceeded := !receipts.isEmpty && receipts.all (fun r => isSucceededActionState ((r.fieldStr? "state").getD ""))
      let satisfied := if returnWhen == "any" then settledCount > 0 else settledCount == receipts.size
      return (receipts, pendingIds, settledCount, allSettled, allSucceeded, satisfied)
    let startMs ← IO.monoMsNow
    let deadlineMs := startMs + timeoutMs
    let mut snap ← readWaitSnapshot
    while !snap.2.2.2.2.2 do
      let nowMs ← IO.monoMsNow
      if nowMs ≥ deadlineMs then break
      let remaining := deadlineMs - nowMs
      IO.sleep (UInt32.ofNat (Nat.min remaining 25))
      snap ← readWaitSnapshot
    let (receipts, pendingIds, settledCount, allSettled, allSucceeded, satisfied) := snap
    return mcpOk (.obj #[
      ("receipts", .arr receipts),
      ("actions", .arr receipts),
      ("return_when", .str returnWhen),
      ("all_settled", .bool allSettled),
      ("all_succeeded", .bool allSucceeded),
      ("settled_count", JVal.nat settledCount),
      ("pending_count", JVal.nat pendingIds.size),
      ("timed_out", .bool (!satisfied)),
      ("pending_action_ids", .arr (pendingIds.map JVal.str))
    ])

  | "cancel_action" =>
    let aid := ((args.fieldStr? "action_id").orElse (fun _ => args.fieldStr? "id") |>.getD "").trimAscii.toString
    if aid.isEmpty then
      return mcpErr "invalid_arguments" "missing action_id"
    if idemKeyTop.isEmpty || idemKeyTop.utf8ByteSize > 200 then
      return mcpErr "invalid_arguments" "missing idempotency_key"
    let cScope := actionScope claims callerUserId toolName
    let reqFp := renderCanonical args
    if let .ok existingRows ← execParamQuery store.projectsDb
        "SELECT id, COALESCE(fingerprint,''), COALESCE(result,'{}') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2 LIMIT 1;"
        #[cScope, idemKeyTop] then
      if existingRows.size > 1 then
        let existingFp := cell existingRows[1]! 1
        if existingFp != reqFp then
          return mcpErr "conflict" "mcp_idempotency_conflict"
        let storedRes := (OrbBin.Json.parse (cell existingRows[1]! 2)).toOption.getD (.obj #[])
        return mcpOk storedRes
    let persistCancelReceipt (resObj : JVal) (didCancel : Bool) : IO String := do
      let cid ← newUuidV4
      let principalVal := s!"{claims.role}:{callerUserId}:{claims.missionId}"
      let stVal := if didCancel then "succeeded" else "rejected"
      let resJson := renderCompact resObj
      match ← execParamQuery store.projectsDb
          ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
           "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11) ON CONFLICT(scope,retry_key) DO NOTHING;")
          #[cid, claims.missionId, cScope, idemKeyTop, reqFp, principalVal, toolName, reqFp, stVal, resJson, nowIso] with
      | .ok _ =>
        if let .ok rRows ← execParamQuery store.projectsDb
            "SELECT COALESCE(fingerprint,''), COALESCE(result,'{}') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2 LIMIT 1;"
            #[cScope, idemKeyTop] then
          if rRows.size > 1 then
            if cell rRows[1]! 0 != reqFp then
              return mcpErr "conflict" "mcp_idempotency_conflict"
            return mcpOk ((OrbBin.Json.parse (cell rRows[1]! 1)).toOption.getD resObj)
        return mcpOk resObj
      | .error _ => return mcpOk resObj
    if ← ManagedSpawnActions.isSpawnAction store aid then
      match ← ManagedSpawnActions.cancel store aid { userId := callerUserId, missionId := callerMid } operatorIsAdmin with
      | .ok cancelled =>
        return ← persistCancelReceipt cancelled (cancelled.fieldBool? "cancelled" == some true)
      | .error _ => return mcpErr "not_found" "Action not found"
    if let some rec ← lookupCallerAction? aid then
      let curSt := (rec.fieldStr? "state").getD "succeeded"
      let canCancel := curSt == "queued" || curSt == "pending" || curSt == "accepted"
      let mut didCancel := false
      if canCancel then
        match ← execParamQuery store.projectsDb
            "UPDATE mcp_actions_v1 SET state='cancelled', updated_at=?2 WHERE id=?1 AND state IN ('queued','pending','accepted') RETURNING id;"
            #[aid, nowIso] with
        | .ok rows => didCancel := rows.size > 1
        | .error _ => return mcpErr "cancel_failed" "action receipt update failed" false
      let finalSt ← if didCancel then pure "cancelled" else do
        match ← lookupCallerAction? aid with
        | some refreshed => pure ((refreshed.fieldStr? "state").getD curSt)
        | none => pure curSt
      let resObj := JVal.obj #[
        ("action_id", .str aid),
        ("cancelled", .bool didCancel),
        ("state", .str finalSt),
        ("accepted", .str (if didCancel then "yes" else "no"))
      ]
      return ← persistCancelReceipt resObj didCancel
    return mcpErr "not_found" "Action not found"

  | "get_fleet_sweep" =>
    let scopeTree := !callerMid.isEmpty && !claims.isExternal && !directOperator
    let countScoped (ids : Array String) : IO Nat := do
      let mut n : Nat := 0
      for id in ids do
        if ← sameMissionTree callerMid id then n := n + 1
      return n
    let mut activeCnt : Nat := 0
    let mut armedCnt : Nat := 0
    if scopeTree then
      if let .ok r1 ← execParamQuery store.missionsDb "SELECT id FROM missions WHERE status='active';" #[] then
        activeCnt ← countScoped ((r1.extract 1 r1.size).map (fun r => cell r 0))
      if let .ok r2 ← execParamQuery store.missionsDb
          "SELECT DISTINCT mission_id FROM mission_continuations WHERE phase=1;" #[] then
        armedCnt ← countScoped ((r2.extract 1 r2.size).map (fun r => cell r 0))
    else
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
        buildComputeFleetJVal relayHub? mc fl scopedUid? userComputeSpent userCap? store.rootDir nowIso (some store)
      | none => pure (.obj #[("nodes", .arr #[])])
    return mcpOk (.obj #[
      ("active_missions", JVal.nat activeCnt),
      ("armed_continuations", JVal.nat armedCnt),
      ("fleet", fleetVal)
    ])

  | "schedule_wakeup" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let reqMid := ((args.fieldStr? "mission_id").getD callerMid).trimAscii.toString
    if reqMid.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "schedule_wakeup requires a mission_id (or a mission-scoped MCP session)" nowIso
    if normalizeMcpRole claims.role == "executor" && !callerMid.isEmpty && reqMid != callerMid then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" "executor sessions may only schedule wakeups for their own mission" nowIso
    let prompt := ((args.fieldStr? "prompt").getD "").trimAscii.toString
    if prompt.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "prompt is required" nowIso
    let reason := ((args.fieldStr? "reason").getD "scheduled_wakeup").trimAscii.toString
    let delayOpt := (args.fieldNat? "delay_seconds").orElse (fun _ => args.fieldNat? "delaySeconds")
    let nextAtOpt := ((args.fieldStr? "next_at").orElse (fun _ => args.fieldStr? "nextAt")).bind parseIso8601EpochU64?
    let dueEpoch ← match delayOpt, nextAtOpt with
      | some d, _ =>
        if d < 60 || d > 3600 then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "delay_seconds must be between 60 and 3600" nowIso
        pure (nowEpochSec + d.toUInt64)
      | none, some ep =>
        if ep ≤ nowEpochSec then pure (nowEpochSec + 60) else pure ep
      | none, none =>
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "delay_seconds (60..=3600) is required" nowIso
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
    | .error "mission_not_found" => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" s!"Mission `{reqMid}` not found" nowIso
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "continuation_rejected" e nowIso
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
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso reqMid
        | return mcpErr "receipt_record_failed" "The mutation completed but its receipt could not be recorded. Reconcile the action." false
      return mcpOk settled

  | "schedule_job_wakeup" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let reqMid := ((args.fieldStr? "mission_id").getD callerMid).trimAscii.toString
    if reqMid.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "schedule_job_wakeup requires a mission_id (or a mission-scoped MCP session)" nowIso
    if normalizeMcpRole claims.role == "executor" && !callerMid.isEmpty && reqMid != callerMid then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" "executor sessions may only schedule job wakeups for their own mission" nowIso
    let jobId := ((args.fieldStr? "job_id").orElse (fun _ => args.fieldStr? "jobId") |>.getD "").trimAscii.toString
    if jobId.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "job_id is required" nowIso
    let prompt := ((args.fieldStr? "prompt").getD "").trimAscii.toString
    if prompt.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "prompt is required" nowIso
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
    | .error "mission_not_found" => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" s!"Mission `{reqMid}` not found" nowIso
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "continuation_rejected" e nowIso
    | .ok savedCid =>
      let resObj := JVal.obj #[
        ("id", .str savedCid),
        ("continuation_id", .str savedCid),
        ("mission_id", .str reqMid),
        ("job_id", .str jobId),
        ("trigger_kind", .str "durable_job_terminal")
      ]
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso reqMid
        | return mcpErr "receipt_record_failed" "The mutation completed but its receipt could not be recorded. Reconcile the action." false
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
    match ← listMissionsJson store none scopedUid? flt with
    | .error e => return mcpErr "db_error" e
    | .ok rawArr =>
      let arr : Array JVal := match OrbBin.Json.parse rawArr with
        | .ok (.arr xs) => xs
        | _ => #[]
      let mut visible : Array JVal := #[]
      for item in arr do
        let id := (item.fieldStr? "id").getD ""
        if callerMid.isEmpty || claims.isExternal || directOperator || id.isEmpty ||
            (← sameMissionTree callerMid id) then
          visible := visible.push item
      return mcpOk (.obj #[("missions", .arr visible)])

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
        let served ← servedModelsJson store mid
        return mcpOk (match detail with
          | .obj fields => .obj (fields.push ("served_models", served))
          | other => other)

  | "get_mission_events" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD callerMid
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return mcpErr "forbidden" e
    let view := ((args.fieldStr? "view").getD "").trimAscii.toString
    let lim := Nat.max 1 (Nat.min ((args.fieldNat? "limit").getD 40) (if view == "all" then 50 else 500))
    let beforeSeq? := (args.fieldUInt64? "before_seq").filter (· > 0)
    let sinceSeq? := if beforeSeq?.isSome then none
      else (args.fieldUInt64? "since_seq").orElse (fun _ => args.fieldUInt64? "after_seq")
    let maxPayload := Nat.max 1024 (Nat.min ((args.fieldNat? "max_payload").getD 4096) 65536)
    let types := if view == "trace" then #["tool_call", "tool_result", "error"] else #[]
    match ← queryMissionEventsPage store mid sinceSeq? beforeSeq? lim types (some maxPayload)
        (if view == "transcript" then some "transcript" else none) with
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

  | "read_project_board" | "write_project_board" =>
    let slug := (args.fieldStr? "project").getD callerProj
    if slug != callerProj then return mcpErr "not_found" "Project not found"
    let .ok projectRows ← execParamQuery store.projectsDb
        "SELECT COALESCE(controller_mission_id,'') FROM projects WHERE slug=?1;" #[slug]
      | return mcpErr "not_found" "Project not found"
    if projectRows.size ≤ 1 then return mcpErr "not_found" "Project not found"
    let controller := cell projectRows[1]! 0
    if controller.isEmpty then
      if toolName == "read_project_board" then
        return mcpOk (← readProjectBoard store slug)
      return mcpErr "forbidden" "not_project_controller"
    let board ← MissionBoard.read store.missionsDb { userId := callerUserId, missionId := callerMid, role := claims.role } controller
    if toolName == "read_project_board" then
      match board with
      | .ok b => return mcpOk b
      | .error e => return mcpErr (if e == "mission_not_found" then "not_found" else e) e
    if callerMid.isEmpty || controller != callerMid then
      return mcpErr "forbidden" "not_project_controller"
    let some text := args.fieldStr? "text" | return mcpErr "invalid_arguments" "text required"
    let actionId ← newUuidV4
    match ← MissionBoard.write store.missionsDb { userId := callerUserId, missionId := callerMid, role := claims.role }
        controller text nowIso none actionId (actionScope claims callerUserId toolName)
        ((args.fieldStr? "idempotency_key").getD "") toolName (rejectConflict := true) with
    | .error e =>
      let code := if e == "not_mission_writer" then "forbidden" else if e == "mcp_idempotency_conflict" then "conflict" else e
      return mcpErr code e
    | .ok result => return mcpOk result

  | "read_mission_board" =>
    let mid := (args.fieldStr? "mission_id").getD callerMid
    match ← MissionBoard.read store.missionsDb { userId := callerUserId, missionId := callerMid, role := claims.role } mid with
    | .ok result => return mcpOk result
    | .error e => return mcpErr (if e == "mission_not_found" then "not_found" else e) e

  | "write_mission_board" =>
    let mid := (args.fieldStr? "mission_id").getD callerMid
    let some text := args.fieldStr? "text" | return mcpErr "invalid_arguments" "text required"
    let actionId ← newUuidV4
    match ← MissionBoard.write store.missionsDb { userId := callerUserId, missionId := callerMid, role := claims.role }
        mid text nowIso none actionId (actionScope claims callerUserId toolName)
        ((args.fieldStr? "idempotency_key").getD "") toolName (rejectConflict := true) with
    | .error e =>
      let code := if e == "not_mission_writer" then "forbidden" else if e == "mcp_idempotency_conflict" then "conflict" else e
      return mcpErr code e
    | .ok result => return mcpOk result

  | "start_mission" | "consult_model" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    match args.field? "cloud" with
    | none | some .null => pure ()
    | some _ =>
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
        "Cloud-hosted MCP mission launches are not implemented; no mission was started. Use a native launch without `cloud` for now." nowIso
    let isConsult := toolName == "consult_model"
    if isConsult then
      match args.field? "models" with
      | none | some .null => pure ()
      | some _ =>
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
          "Multi-model / quorum consultation (`models`) is not supported; call `consult_model` separately with a single `model`." nowIso
      match args.field? "quorum" with
      | none | some .null | some (.bool false) => pure ()
      | some _ =>
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
          "Quorum consultation is not supported; call `consult_model` separately with a single `model`." nowIso
    let title := ((args.fieldStr? "title").orElse (fun _ => args.fieldStr? "summary") |>.getD "Delegated Mission").trimAscii.toString
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
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_request"
        "consult_model requires a non-empty `question`" nowIso
    let rawProj := (args.fieldStr? "project").getD callerProj
    let checkedProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso
    let effProj ← if !tenantScoped || checkedProj.isEmpty then pure checkedProj else do
      let .ok rows ← execParamQuery store.projectsDb
          "SELECT slug FROM project_owners WHERE slug=?1 AND owner_user_id=?2;" #[checkedProj, callerUserId]
        | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "db_error" "Project lookup failed" nowIso true
      if rows.size > 1 then pure checkedProj
      else
        let some scopedSlug := scopeProjectSlug callerUserId
          (((← getBootstrapAdmin? store).map (·.id)).getD "") checkedProj
          | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "Invalid project" nowIso
        pure scopedSlug
    let controller := toolName == "start_mission" && (args.fieldBool? "controller").getD false
    if controller then
      if effProj.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "no_project" "Controller requires a project" nowIso
      let board ← readProjectBoard store effProj
      let owns ← execParamQuery store.projectsDb
        "SELECT slug FROM project_owners WHERE slug=?1 AND owner_user_id=?2;" #[effProj, callerUserId]
      let isOwner := match owns with | .ok rows => rows.size > 1 | _ => false
      unless userIsAdmin || isOwner || claims.role == "coordinator" ||
          (!callerMid.isEmpty && board.fieldStr? "controller_mission_id" == some callerMid) do
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" "not_project_controller" nowIso
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
        | none =>
          let msg := s!"consult_model cannot route model `{rawModelOv}`. Use <provider>/<model> (e.g. anthropic/claude-fable-5-2, openai/gpt-6-astra) or a short alias (fable-5.2, opus-5.5, gpt-6-astra)."
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unknown_model" msg nowIso
      else pure rawModelOv
    let effort := (args.fieldStr? "model_effort").orElse (fun _ => args.fieldStr? "reasoning_effort") |>.getD ""
    let parentMid := ((args.fieldStr? "parent_mission_id").filter (!·.isEmpty)).getD callerMid
    let requestedRn? := (args.fieldStr? "remote_node_id").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    let wantsSnapshot := !((args.fieldStr? "managed_from_snapshot").getD "").trimAscii.toString.isEmpty
    let autoManaged := match requestedRn? with
      | some rn => rn.toLower == "auto-managed" || rn.toLower.startsWith "auto-managed:"
      | none => false
    if wantsSnapshot && !autoManaged then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "managed_from_snapshot requires remote_node_id auto-managed[:size]" nowIso
    -- `FLT-14`: validate remote `/goal`, harness, and proxy preconditions BEFORE renting
    -- any paid `auto-managed` VM or inserting any mission row (including empty-prompt creates).
    if let some goalObj := OrbCore.Cyber.parseGoalPrefix? prompt then
      let capability := if OrbCore.RemoteGoal.supportsHarness (normalizeRemoteHarness backend) && remoteSup?.isSome
        then OrbCore.RemoteGoal.Capability.coreEmulated else .unavailable
      match OrbCore.RemoteGoal.admit capability false goalObj with
      | .error .emptyObjective =>
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "Goal mode requires a non-empty objective." nowIso
      | .error _ =>
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
          "remote_goal_unsupported: This remote harness cannot continue a Goal. Choose a Goal-capable harness or send a standard turn." nowIso
      | .ok _ => pure ()
    if let .error hErr := validateRemoteHarness backend then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported" hErr nowIso
    if !prompt.isEmpty then
      if let some sup := remoteSup? then
        let (_, proxyBase) ← resolveRemoteCallbackUrls sup (requestedRn?.getD "")
        if let .error pErr := validateRemoteLaunchPlan backend prompt proxyBase then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" pErr nowIso
    -- `auto-managed[:size]` rents one machine for this child through the shared spawn
    -- path. Nothing is rented when validation, admission or the snapshot lookup fails.
    let (explicitRn?, rentedMachineId, reused?, providerChoice) ← if !autoManaged
        then pure (requestedRn?, "", none, ({ provider := "" } : ManagedProviderChoice)) else do
      let (namedProvider?, namedSize?) ← match parseAutoManagedTarget (requestedRn?.getD "") with
        | .ok target => pure target
        | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" e nowIso
      let sizeFields : Array (String × JVal) := match namedSize? with
        | some size => #[("size", .str size)]
        | none => #[]
      let rentFields : Array (String × JVal) := #[
        ("ttl_minutes", JVal.uint64 ((args.fieldUInt64? "managed_ttl_minutes").getD 60)),
        ("from_snapshot", .str ((args.fieldStr? "managed_from_snapshot").getD ""))]
      let namedFields : Array (String × JVal) := match namedProvider? with
        | some provider => #[("provider", .str provider)]
        | none => #[]
      let choice ← chooseSpawnProvider (.obj (namedFields ++ sizeFields ++ rentFields ++ #[
        ("idempotency_key", .str (((args.fieldStr? "idempotency_key").filter (!·.isEmpty)).map ("start-mission:" ++ ·) |>.getD ""))])) false
      let provider := choice.provider
      let prefs ← match mc? with
        | some mc => if managedPreferenceUserId.isEmpty then pure #[] else getUserManagedPrefs mc managedPreferenceUserId
        | none => pure #[]
      if !isUserManagedProviderEnabled prefs provider then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "provider_disabled_for_user" "This cloud provider is disabled in your preferences." nowIso
      let size ← match resolveManagedSpawnSize provider (.obj sizeFields) with
        | .ok size => pure size
        | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" e nowIso
      -- An idle VM left by an ended child of this same caller is taken over instead
      -- of renting another. A snapshot request always gets a fresh machine.
      let reuseRequest : ManagedReuse.Request := {
        provider := provider
        size := size
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
        pure (some s!"managed-{claimed.machine.id}", claimed.machine.id, reused?, choice)
      else
        let retryKey ← match (args.fieldStr? "idempotency_key").filter (!·.isEmpty) with
          | some key => pure key
          | none => newUuidV4
        -- The provider is decided above and named here, so the spawn does not decide again.
        let spawnArgs := JVal.obj (#[("provider", JVal.str provider)] ++ rentFields ++ #[
          ("size", .str size), ("idempotency_key", .str ("start-mission:" ++ retryKey))])
        match ← spawnForCaller spawnArgs "" with
        | .error (_, message) => return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" message nowIso
        | .ok (rented, _) => pure (some s!"managed-{rented.id}", rented.id, none, choice)
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
      let normalizedRn := AutoPlacement.normalize rn
      let concreteExplicit := rn.toLower != "auto" && !rn.toLower.startsWith "auto:"
      if concreteExplicit && excluded.contains normalizedRn then
        releaseRented
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" s!"node `{rn}` is excluded for this mission" nowIso "placement_excluded"
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
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" "no_eligible_node" nowIso "placement_failed"
    if let (some owner, some target) := (user?, inheritedRn?) then
      let (_, nodes) ← loadStaticRemoteNodes
      if let .error _ ← authorizeRemotePlacement mc? owner target nodes then
        releaseRented
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" "This execution target is unavailable to this user" nowIso "placement_forbidden"
    if let some target := inheritedRn? then
      if let some cause ← nodeApiHangCause? store target then
        releaseRented
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" cause nowIso "hung_node"
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
    let requestedWriter? :=
      (args.fieldBool? "writer").orElse (fun _ => if isConsult then (args.fieldBool? "read_only").map (!·) else none)
    let requestedTags := (args.fieldArr? "tags").getD #[] |>.filterMap JVal.asStr?
    let requestedIntent := (args.fieldStr? "intent").getD ""
    let .ok authMode := classifyAuthorityMode requestedWriter? requestedTags
        (toolName == "consult_model" || requestedIntent == "review_only" || requestedIntent == "readonly")
      | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed"
          "contradictory_authority_tags" nowIso "contradictory_authority_tags"
    -- A consultation with nowhere to run must fail, not sit at awaiting_user/active.
    if isConsult && (remoteSup?.isNone || inheritedRn?.isNone) then
      return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" "no execution node is available" nowIso "no_execution_placement"
    -- This gateway can only run a first turn on a node. With a prompt and nowhere to
    -- run it, refuse: a mission that will never be dispatched must not be created `active`.
    if !prompt.isEmpty && (remoteSup?.isNone || inheritedRn?.isNone) then
      releaseRented
      return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" "no execution node is available" nowIso "no_execution_placement"
    let mid ← newUuidV4
    -- The model name the turn is launched with. Empty means the harness's own default.
    let sentModel := if backend == "opencode" && modelOv.isEmpty then "builtin/smart" else modelOv
    let initRev : UInt64 := if effProj.isEmpty && folder.isEmpty then 0 else 1
    let initStatus := if !prompt.isEmpty then "active" else "awaiting_user"
    let insSql :=
      "INSERT INTO missions(id,title,status,backend,model_override,model_effort,working_directory,workspace_id,project,folder,placement_revision,parent_mission_id,authority_mode,tags,created_at,updated_at,metadata_updated_at,node_boot_epoch,owner_user_id) " ++
      "VALUES(?1,?2,?3,?4,?5,?6,?7,'00000000-0000-0000-0000-000000000000',?8,?9,CAST(?10 AS INTEGER),NULLIF(?11,''),?12,?13,?14,?14,?14,CAST(?15 AS INTEGER),?16);"
    if let .error e ← execParamQuery store.missionsDb insSql
        #[mid, title, initStatus, backend, modelOv, effort, effWorkDir, effProj, folder, s!"{initRev}", parentMid, authMode, tagsJson, nowIso, s!"{store.bootEpoch}", callerUserId] then
      releaseRented
      return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" e nowIso
    if tenantScoped && !effProj.isEmpty then
      discard <| execParamQuery store.projectsDb
        "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
        #[effProj, callerUserId, nowIso]
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
          modelOverride    := sentModel
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
          if dispErr.startsWith "remote_dispatch_uncertain:" || dispErr.startsWith "remote_accept_persist_failed:" then
            -- Never delete the mission or destroy the VM when remote acceptance is
            -- uncertain (`FLT-05` / `MCP-03`): reconciliation probes the original job ID,
            -- and the MCP action settles `uncertain` (`retryable: false`) so callers do
            -- not spawn a competing second writer.
            return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain"
              s!"Remote dispatch outcome is uncertain for mission `{mid}` ({dispErr}); reconciliation will attach or settle it." nowIso
              "remote_dispatch_uncertain" (some false)
          discard <| execParamQuery store.missionsDb "DELETE FROM mission_events WHERE mission_id=?1;" #[mid]
          discard <| execParamQuery store.missionsDb "DELETE FROM missions WHERE id=?1;" #[mid]
          releaseRented
          return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" dispErr nowIso
    if controller then
      if let .error e ← nominateCreatedProjectController store effProj effProj mid nowIso callerUserId then
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" e nowIso
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
      -- What the caller asked for and what the turn is launched with (null: harness default).
      -- A chain name is resolved per request by the proxy; `get_mission` reports what served it.
      ("requested_model", if rawModelOv.isEmpty then .null else .str rawModelOv),
      ("effective_model", if sentModel.isEmpty then .null else .str sentModel),
      ("remote_node_id", match inheritedRn? with | some rn => .str rn | none => .null),
      ("project", if effProj.isEmpty then .null else .str effProj),
      ("folder", .str folder),
      ("placement_revision", JVal.uint64 initRev),
      -- A reused machine keeps its remaining lifetime: the child extends it if it needs more.
      ("managed_machine_reused", .bool reused?.isSome),
      -- Set when the instance default provider could not take the rental and another did.
      ("provider_fallback", ((providerChoice.annotate (.obj #[])).field? "provider_fallback").getD .null),
      ("managed_machine_expires_at_sec",
        match reused? with | some claimed => JVal.uint64 claimed.machine.expiresAtSec | none => .null)
    ]
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
      | return mcpErr "receipt_record_failed" "The mutation completed but its receipt could not be recorded. Reconcile the action." false
    return mcpOk settled

  | "get_consult_result" =>
    match args.field? "mission_ids" with
    | none | some .null => pure ()
    | some _ =>
      return mcpErr "unsupported" "Batch/quorum consultation polling (`mission_ids`) is not supported; poll `get_consult_result` with a single `mission_id`."
    let mid := ((args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD "").trimAscii.toString
    if mid.isEmpty then
      return mcpErr "invalid_arguments" "missing mission_id"
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return mcpErr "forbidden" e
    match ← missionDetailJson store mid none "" with
    | .ok (some raw) =>
      let detail := (OrbBin.Json.parse raw).toOption.getD (.obj #[])
      let status := (detail.fieldStr? "status").getD "pending"
      let done := !#["pending", "active", "running", "waiting_background"].contains status.toLower
      let model := (detail.fieldStr? "model_override").getD ""
      let served ← servedModelsJson store mid
      let mut fields : Array (String × JVal) := #[
        ("mission_id", .str mid),
        ("status", .str status),
        ("done", .bool done),
        ("served_models", served)
      ]
      if !model.isEmpty then
        fields := fields.push ("model", .str model)
      if done then
        let ans? ← lastConsultAnswer? store mid detail 20000
        fields := fields.push ("answer", match ans? with | some a => .str a | none => .null)
      else
        fields := fields.push ("next", .str "Still running: call get_consult_result again later.")
      return mcpOk (.obj fields)
    | _ => return mcpErr "not_found" s!"Mission `{mid}` not found"

  | "ask_mission" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    -- Ask a read-only `/btw` side agent about the mission. It never writes into the
    -- mission's own transcript; read the answer from the returned side mission (`MCP-07`).
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "target_mission_id") |>.getD ""
    let question := ((args.fieldStr? "content").orElse (fun _ => (args.fieldStr? "question").orElse (fun _ => args.fieldStr? "message")) |>.getD "").trimAscii.toString
    -- The side-agent launcher has no thread/sandbox continuation store: reject
    -- non-empty `thread_id` or `sandbox: true` instead of silently ignoring them.
    let hasThreadId := match args.field? "thread_id" with
      | none | some .null => false
      | some (.str s) => !s.trimAscii.toString.isEmpty
      | some _ => true
    if hasThreadId || (args.fieldBool? "sandbox").getD false then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported_argument" "ask_mission does not support thread_id or sandbox" nowIso
    if mid.isEmpty || question.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "mission_id and content are required" nowIso
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" e nowIso
    let some askSide := askSide?
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable" "ask_mission needs the Core server's side-agent launcher" nowIso true
    let idem ← if idemKeyTop.isEmpty then newUuidV4 else pure idemKeyTop
    match ← askSide mid question idem with
    | .error e =>
      let isServerErr := e.startsWith "5" || e.startsWith "remote_dispatch_uncertain:" || e.startsWith "remote_accept_persist_failed:"
      if e.startsWith "remote_dispatch_uncertain:" || e.startsWith "remote_accept_persist_failed:" then
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" e nowIso "ask_uncertain" (some false)
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "ask_failed" e nowIso isServerErr
    | .ok body =>
      let side := (OrbBin.Json.parse body).toOption.getD (.obj #[])
      let sideId := (side.fieldStr? "id").getD ""
      let resObj := JVal.obj #[
        ("side_mission_id", .str sideId),
        ("mission_id", .str mid),
        ("status", .str ((side.fieldStr? "status").getD "")),
        ("hint", .str s!"Read the answer with get_mission_events on `{sideId}`.")
      ]
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
        | return mcpErr "receipt_record_failed" "The side question launched but its receipt could not be recorded. Reconcile the action." false
      return mcpOk settled

  | "answer_mission_question" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => (args.fieldStr? "target_mission_id").orElse (fun _ => args.fieldStr? "id")) |>.getD ""
    let callId := ((args.fieldStr? "tool_call_id").orElse (fun _ => args.fieldStr? "request_id") |>.getD "").trimAscii.toString
    let answers := (args.field? "answers").getD .null
    -- Validate `answers`: published schema supplies `string[][]` (nested array of string arrays);
    -- also accept a non-empty object map for compatibility, rejecting scalar/malformed values (`MCP-07`).
    let answersValid : Bool :=
      match answers with
      | .arr rows =>
        !rows.isEmpty && rows.all fun row =>
          match row with
          | .arr opts => opts.all fun o => match o with | .str _ => true | _ => false
          | _ => false
      | .obj kvs => !kvs.isEmpty
      | _ => false
    if mid.isEmpty || !answersValid then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments"
        "mission_id and structured answers (non-empty string[][] or object) are required" nowIso
    let some answerQuestion := answerQuestion?
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable"
          "answer_mission_question needs the Core server's live control-request router" nowIso
    match ← answerQuestion callerUserId mid callId answers with
    | .error e =>
      if e.startsWith "multiple_pending_questions:" then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "ambiguous_question" e nowIso false mid
      if e.startsWith "unsupported:" then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported" e nowIso false mid
      if e.startsWith "invalid_arguments:" then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" e nowIso false mid
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "answer_failed" e nowIso false mid
    | .ok none =>
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found"
        "no live pending question for this mission/tool_call_id" nowIso false mid
    | .ok (some resolvedCallId) =>
      let resObj := JVal.obj #[
        ("ok", .bool true),
        ("mission_id", .str mid),
        ("tool_call_id", .str resolvedCallId),
        ("delivered", .bool true)
      ]
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
        | return mcpErr "receipt_record_failed" "The answer was delivered but its receipt could not be recorded. Reconcile the action." false
      return mcpOk settled

  | "send_message_to_mission" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "target_mission_id") |>.getD ""
    let content := ((args.fieldStr? "message").orElse (fun _ => (args.fieldStr? "content").orElse (fun _ => (args.fieldStr? "question").orElse (fun _ => args.fieldStr? "answer"))) |>.getD "").trimAscii.toString
    let rawMode := ((args.fieldStr? "mode").getD "").trimAscii.toString.toLower
    let rawDelivery := ((args.fieldStr? "delivery").getD "").trimAscii.toString.toLower
    if (args.fieldBool? "interrupt").getD false ||
        (!rawMode.isEmpty && rawMode != "queue" && rawMode != "default") ||
        (!rawDelivery.isEmpty && rawDelivery != "queue" && rawDelivery != "default") then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
        "interrupt/replace/steer delivery modes are not supported on send_message_to_mission" nowIso
    let unsupportedField? :=
      #["cloud_model", "cloud_model_params", "continue_identity", "track", "github_pr"].find? fun k =>
        match args.field? k with
        | none | some .null => false
        | some (.str s) => !s.trimAscii.toString.isEmpty
        | some (.arr xs) => !xs.isEmpty
        | some _ => true
    if let some uf := unsupportedField? then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
        s!"send_message_to_mission does not support `{uf}`" nowIso
    if mid.isEmpty || content.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "mission_id and message/content are required" nowIso
    if let some t := (args.fieldStr? "title").map (·.trimAscii.toString) then
      if !t.isEmpty then
        let .ok _ ← execParamQuery store.missionsDb "UPDATE missions SET title=?2, metadata_updated_at=?3 WHERE id=?1;" #[mid, t, nowIso]
          | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "title update failed" nowIso
    -- When the Core runtime dispatcher (`remoteSup?`) is wired, verify the mission exists
    -- and has a real delivery route before claiming success (`MCP-07`).
    let mut deliveryTarget? : Option (MissionRecord × String) := none
    if let some _ := remoteSup? then
      let some mr ← getMission? store mid
        | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" s!"Mission `{mid}` not found" nowIso
      match ← resolveMissionRemoteNode? store mc? mid with
      | some targetNode =>
        if targetNode.trimAscii.toString.isEmpty then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
            s!"Mission `{mid}` has no live remote delivery target; use the REST control endpoint for local/cloud turns." nowIso
        deliveryTarget? := some (mr, targetNode)
      | none =>
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
          s!"Mission `{mid}` has no remote delivery target (placement={mr.placementKind}); send_message_to_mission cannot silently fall back to a note." nowIso
    let noteId ← if idemKeyTop.isEmpty then newUuidV4
      else pure s!"mcp-msg-{(LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes (s!"{actionScope claims callerUserId toolName}:{idemKeyTop}".toUTF8))).take 24}"
    let .ok _ ← execParamQuery store.askDb
      "INSERT OR IGNORE INTO main.operator_notes(note_id,id,mission_id,content,body,created_at_iso,created_at) VALUES(?1,?1,?2,?3,?3,?4,?4);"
      #[noteId, mid, content, nowIso]
      | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "note insert failed" nowIso
    let .ok _ ← appendMissionEvent store mid "operator_note" (renderCompact (.obj #[("id", .str noteId), ("content", .str content)])) nowIso
      | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "note event failed" nowIso
    let mut queued := false
    if let (some sup, some (mr, targetNode)) := (remoteSup?, deliveryTarget?) then
      let hasInflight : Bool ← match ← execParamQuery store.missionsDb
          "SELECT 1 FROM remote_node_jobs WHERE mission_id=?1 AND state NOT IN ('succeeded','failed','cancelled','lost','terminal','completed','aborted') LIMIT 1;" #[mid] with
        | .ok rows => pure (decide (rows.size > 1))
        | .error _ => pure false
      if mr.status == "active" || mr.status == "pending" || mr.status == "waiting_background" || mr.status == "waiting_rate_limit" || hasInflight then
        match ← enqueueStructuredFollowup store "core" noteId mid content "mcp" nowIso with
        | .ok _ => queued := true
        | .error e => return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" e nowIso
      else
        let mut resumeSid? : Option String := none
        if let .ok sRows ← execParamQuery store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
          if sRows.size > 1 then
            let s := (cell sRows[1]! 0).trimAscii.toString
            if !s.isEmpty then resumeSid? := some s
        let .ok _ ← appendMissionEvent store mid "user_message"
          (renderCompact (.obj #[("id", .str noteId), ("content", .str content), ("source", .str "mcp")])) nowIso
          | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "user message event failed" nowIso
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
        if let .error e ← submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup workingDir spec nowEpochSec then
          return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" e nowIso
    let resObj := JVal.obj #[
      ("ok", .bool true),
      ("mission_id", .str mid),
      ("note_id", .str noteId),
      ("queued", .bool queued),
      ("delivered", .bool (deliveryTarget?.isSome && !queued))
    ]
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
      | return mcpErr "receipt_record_failed" "The mutation completed but its receipt could not be recorded. Reconcile the action." false
    return mcpOk settled

  | "cancel_mission" | "acknowledge_mission" | "adopt_mission" | "resume_mission" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD callerMid
    if mid.isEmpty then
      if toolName != "cancel_mission" || idemKeyTop.isEmpty then
        return mcpErr "invalid_arguments" "missing mission_id"
      return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" "missing mission_id" nowIso
    if toolName == "cancel_mission" then
      -- The cancellation helper rewrites job ledgers even when transport fails.
      -- Capture evidence before calling it; rewritten rows are not acknowledgement.
      let .ok pendingJobs ← execParamQuery store.missionsDb
          "SELECT COUNT(*) FROM remote_node_jobs WHERE mission_id=?1 AND state NOT IN ('terminal','completed','succeeded','failed','aborted','cancelled','lost');" #[mid]
        | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "remote cancellation state unavailable" nowIso
      if pendingJobs.size ≤ 1 then
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "remote cancellation state unavailable" nowIso
      let hadPendingRemoteJob := cellNat pendingJobs[1]! 0 > 0
      let .ok _ ← revokeContinuations store mid nowIso true
        | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "continuation revocation failed" nowIso
      let remoteCancelled ← cancelActiveRemoteJobForMission store mc? relayHub? mid "Cancelled via MCP"
      if !remoteCancelled && hadPendingRemoteJob then
        return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "remote cancellation failed" nowIso
      let .ok _ ← execParamQuery store.missionsDb
        "UPDATE mission_runs SET execution_state='terminal', terminal_reason='cancelled', updated_at=?2 WHERE mission_id=?1 AND execution_state NOT IN ('terminal','completed','failed','aborted');"
        #[mid, nowIso]
        | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "run cancellation write failed" nowIso
      let .ok _ ← execParamQuery store.missionsDb
        "UPDATE missions SET status='cancelled', terminal_reason='cancelled', updated_at=?2, state_revision=state_revision+1 WHERE id=?1;"
        #[mid, nowIso]
        | return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" "mission cancellation write failed" nowIso
      discard <| appendMissionEvent store mid "mission_status_changed"
        (renderCompact (.obj #[("status", .str "cancelled"), ("mission_id", .str mid)])) nowIso
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args
        (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str "cancelled")]) nowIso mid
        | return mcpErr "receipt_record_failed" "The mutation completed but its receipt could not be recorded. Reconcile the action." false
      return mcpOk settled
    else if toolName == "resume_mission" then
      if let some target ← resolveMissionRemoteNode? store mc? mid then
        if let some cause ← nodeApiHangCause? store target then
          return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" cause nowIso "hung_node"
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
            return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" dispErr nowIso
          let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args
            (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str "active")]) nowIso mid
            | return mcpErr "receipt_record_failed" "The mutation completed but its receipt could not be recorded. Reconcile the action." false
          return mcpOk settled
      -- No node to run the turn on: say so; never mark the mission active.
      return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "failed" "no execution node is available" nowIso "no_execution_placement"
    else
      let nextSt := if toolName == "adopt_mission" then "awaiting_user" else "completed"
      discard <| execParamQuery store.missionsDb
        "UPDATE missions SET status=?2, updated_at=?3, state_revision=state_revision+1 WHERE id=?1;"
        #[mid, nextSt, nowIso]
      discard <| appendMissionEvent store mid "mission_status_changed"
        (renderCompact (.obj #[("status", .str nextSt), ("mission_id", .str mid)])) nowIso
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args
        (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str nextSt)]) nowIso mid
        | return mcpErr "receipt_record_failed" "The mutation completed but its receipt could not be recorded. Reconcile the action." false
      return mcpOk settled

  | "update_mission_settings" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let .obj kvs := args
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "arguments must be a JSON object" nowIso
    let allowedSettingKeys := #[
      "mission_id", "title", "backend", "model_override", "model_effort",
      "short_description", "github_pr", "idempotency_key"
    ]
    for (k, v) in kvs do
      if #["agent", "config_profile", "fast_mode"].contains k then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported"
          s!"Field `{k}` is not supported by update_mission_settings; no settings were changed." nowIso false ""
      if !allowedSettingKeys.contains k then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments"
          s!"Unknown or unsupported update_mission_settings field `{k}`; no settings were changed." nowIso false ""
      if k == "mission_id" || k == "idempotency_key" then
        if v.asStr?.isNone then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments"
            s!"Field `{k}` must be a string." nowIso false ""
      else if k == "title" || k == "backend" || k == "short_description" || k == "github_pr" then
        if v != .null && v.asStr?.isNone then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments"
            s!"Field `{k}` must be a string." nowIso false ""
        if (k == "title" || k == "backend") && v == .null then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments"
            s!"Field `{k}` must be a non-null string." nowIso false ""
      else if k == "model_override" || k == "model_effort" then
        if v != .null && v.asStr?.isNone then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments"
            s!"Field `{k}` must be a string or null." nowIso false ""
    let mid := (args.fieldStr? "mission_id").getD callerMid
    if mid.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing mission_id" nowIso
    let some existing ← getMission? store mid
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "mission_not_found" nowIso false mid
    let allowed ← (show IO Bool from do
      if !claims.project.isEmpty && claims.project != existing.project then return false
      if operatorIsAdmin then return true
      if let some uid := operatorPrincipal? then
        if !uid.isEmpty && uid == existing.ownerUserId then return true
      if claims.isExternal || callerMid.isEmpty || callerUserId != existing.ownerUserId then return false
      if !callerProj.isEmpty && callerProj != existing.project then return false
      return ← managedMissionAncestor store callerMid mid callerUserId existing.project)
    if !allowed then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" "mission_settings_mutation_forbidden" nowIso false mid
    let mut normalizedArgs := args
    if let some rawB := args.fieldStr? "backend" then
      let bNorm := normalizeRemoteHarness rawB
      if !#["opencode", "claudecode", "codex", "grok", "antigravity", "vibe"].contains bNorm then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments"
          s!"Unsupported backend `{rawB}`" nowIso false mid
      let isRemoteMission :=
        existing.placementKind == "remote" || existing.placementKind == "remote_node" ||
        existing.placementKind == "managed_vm" ||
        (← resolveMissionRemoteNode? store mc? mid).isSome
      if isRemoteMission then
        if let .error hErr := validateRemoteHarness bNorm then
          return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" hErr nowIso false mid
      normalizedArgs := normalizedArgs.setField "backend" (.str bNorm)
    let settings ← match MissionSettings.resolve existing normalizedArgs with
      | .ok settings => pure settings
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" e nowIso false mid
    if let .error _ ← MissionSettings.persist store existing settings nowIso then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "mission_settings_update_failed" "mission_settings_update_failed" nowIso true mid
    let resObj := JVal.obj #[("ok", .bool true), ("mission_id", .str mid)]
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
      | return mcpErr "receipt_record_failed" "The settings updated but the receipt could not be recorded." false
    return mcpOk (if idemKeyTop.isEmpty then resObj.setField "action_id" (settled.fieldOrNull "action_id") else settled)

  | "link_mission_to_project" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let mid := (args.fieldStr? "mission_id").getD callerMid
    let rawProj := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD ""
    let effProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso false mid
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
    match ← MissionSettings.commitPlacementWithRecovery store #[upd] callerUserId nowIso with
    | .error (_, e) => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "move_failed" e nowIso false mid
    | .ok (_, _changed) =>
      let resObj := JVal.obj #[("ok", .bool true), ("mission_id", .str mid), ("project", .str effProj), ("folder", .str folder)]
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
        | return mcpErr "receipt_record_failed" "The mission link succeeded but the receipt could not be recorded." false
      return mcpOk (if idemKeyTop.isEmpty then resObj.setField "action_id" (settled.fieldOrNull "action_id") else settled)

  | "create_project_folder" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let rawProj := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD ""
    let effProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso
    if effProj.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing project slug" nowIso
    let rawFolder := (args.fieldStr? "folder").getD ""
    let some (rel, absFp) := OrbCore.ProjectFilesAndController.projectFileAbsPath? store.rootDir effProj rawFolder
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "invalid_folder_path" nowIso
    if rel.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "folder path must not be empty" nowIso
    if let .error e ← (IO.FS.createDirAll absFp).toBaseIO then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "mkdir_failed" s!"{e}" nowIso true
    let resObj := JVal.obj #[("ok", .bool true), ("project", .str effProj), ("folder", .str rel)]
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso callerMid
      | return mcpErr "receipt_record_failed" "The folder was created but the receipt could not be recorded." false
    return mcpOk (if idemKeyTop.isEmpty then resObj.setField "action_id" (settled.fieldOrNull "action_id") else settled)

  | "rename_project_folder" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let rawProj := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD ""
    let effProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso
    if effProj.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing project slug" nowIso
    let oldFolder := (args.fieldStr? "old_folder").getD ""
    let newFolder := (args.fieldStr? "new_folder").getD ""
    match ← OrbCore.ProjectFilesAndController.transferProjectFileOrFolder store broadcastHub? effProj effProj effProj oldFolder newFolder false nowIso with
    | .error (_, e) => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "rename_folder_failed" e nowIso
    | .ok res =>
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args res nowIso callerMid
        | return mcpErr "receipt_record_failed" "The folder was renamed but the receipt could not be recorded." false
      return mcpOk (if idemKeyTop.isEmpty then res.setField "action_id" (settled.fieldOrNull "action_id") else settled)

  | "update_mission_metadata" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let mid := (args.fieldStr? "mission_id").getD callerMid
    if mid.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing mission_id" nowIso
    let some existing ← getMission? store mid
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "mission_not_found" nowIso false mid
    let newTitle := match args.fieldStr? "title" with
      | some t =>
        let trimmed := t.trimAscii.toString
        if trimmed.isEmpty then existing.title else trimmed
      | none => existing.title
    let hasProj := (args.fieldStr? "project").isSome || (args.fieldStr? "slug").isSome
    let hasFolder := (args.fieldStr? "folder").isSome
    let nextProj ← if hasProj then
      let rawProj := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD ""
      match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso false mid
    else pure existing.project
    let nextFolder := if hasFolder then
      normalizeMissionFolder ((args.fieldStr? "folder").getD "")
    else existing.folder
    let effFolder := if nextProj.isEmpty then "" else nextFolder
    if newTitle != existing.title then
      if let .error e ← execParamQuery store.missionsDb
          "UPDATE missions SET title=?2, updated_at=?3, metadata_updated_at=?3, state_revision=state_revision+1 WHERE id=?1;"
          #[mid, newTitle, nowIso] then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "update_failed" e nowIso true mid
    if nextProj != existing.project || effFolder != existing.folder then
      let upd : CheckedPlacementUpdate := {
        missionId := mid
        expectedProject := existing.project
        nextProject := nextProj
        nextFolder := effFolder
      }
      if let .error (_, e) ← MissionSettings.commitPlacementWithRecovery store #[upd] callerUserId nowIso then
        return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "move_failed" e nowIso false mid
    let resObj := JVal.obj #[
      ("ok", .bool true),
      ("mission_id", .str mid),
      ("title", .str newTitle),
      ("project", .str nextProj),
      ("folder", .str effFolder)
    ]
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
      | return mcpErr "receipt_record_failed" "The metadata updated but the receipt could not be recorded." false
    return mcpOk (if idemKeyTop.isEmpty then resObj.setField "action_id" (settled.fieldOrNull "action_id") else settled)

  | "import_mission" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let title := ((args.fieldStr? "title").getD "").trimAscii.toString
    let sessionId := ((args.fieldStr? "session_id").getD "").trimAscii.toString
    if title.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing title" nowIso
    if sessionId.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing session_id" nowIso
    let backend := ((args.fieldStr? "backend").getD "antigravity").trimAscii.toString
    if !(#["opencode", "claudecode", "codex", "grok", "antigravity", "vibe"].contains backend) then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" s!"unsupported backend: {backend}" nowIso
    let rawProj := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD ""
    let effProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso
    let folder := if effProj.isEmpty then "" else normalizeMissionFolder ((args.fieldStr? "folder").getD "")
    let workDir := ((args.fieldStr? "working_directory").getD "").trimAscii.toString
    let modelOv := ((args.fieldStr? "model_override").getD "").trimAscii.toString
    let effort := ((args.fieldStr? "model_effort").getD "").trimAscii.toString
    let mut tags : Array String := #["imported-session"]
    if let some (.arr rawTags) := args.field? "tags" then
      for tv in rawTags do
        if let .str s := tv then
          let t := s.trimAscii.toString
          if !t.isEmpty && !tags.contains t then tags := tags.push t
    let tagsJson := renderCompact (.arr (tags.map JVal.str))
    let mid ← newUuidV4
    let initRev : UInt64 := if effProj.isEmpty && folder.isEmpty then 0 else 1
    if let .error e ← execParamQuery store.missionsDb
        ("INSERT INTO missions(id,title,status,backend,model_override,model_effort,working_directory,workspace_id,project,folder,placement_revision,session_id,resumable,authority_mode,tags,created_at,updated_at,metadata_updated_at,node_boot_epoch,owner_user_id) " ++
         "VALUES(?1,?2,'awaiting_user',?3,NULLIF(?4,''),NULLIF(?5,''),?6,'00000000-0000-0000-0000-000000000000',?7,?8,?9,?10,1,'writer',?11,?12,?12,?12,?13,?14);")
        #[mid, title, backend, modelOv, effort, workDir, effProj, folder, s!"{initRev}", sessionId, tagsJson, nowIso, s!"{store.bootEpoch}", callerUserId] then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "import_failed" e nowIso true
    discard <| execParamQuery store.missionsDb
      "INSERT OR REPLACE INTO harness_continuity(mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at) VALUES(?1,?2,1,?3,'','delivered','[]',0,1,?4);"
      #[mid, backend, sessionId, nowIso]
    let mut importedEvents : Nat := 0
    if let some (.arr hist) := args.field? "history" then
      let bounded := if hist.size > 200 then hist.extract (hist.size - 200) hist.size else hist
      for item in bounded do
        let role := ((item.fieldStr? "role").getD "").trimAscii.toString
        let content := (item.fieldStr? "content").getD ""
        let ts := match item.fieldStr? "timestamp" with
          | some s => if s.trimAscii.toString.isEmpty then nowIso else s.trimAscii.toString
          | none => nowIso
        if !content.isEmpty && (role == "user" || role == "assistant") then
          importedEvents := importedEvents + 1
          let evType := if role == "user" then "user_message" else "assistant_message"
          discard <| execParamQuery store.missionsDb
            "INSERT INTO mission_events(mission_id,seq,sequence,event_type,content,created_at,timestamp) VALUES(?1,?2,?2,?3,?4,?5,?5);"
            #[mid, s!"{importedEvents}", evType, content, ts]
    let resObj := JVal.obj #[
      ("ok", .bool true),
      ("mission_id", .str mid),
      ("status", .str "awaiting_user"),
      ("backend", .str backend),
      ("session_id", .str sessionId),
      ("project", .str effProj),
      ("folder", .str folder),
      ("imported_events", JVal.nat importedEvents)
    ]
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso mid
      | return mcpErr "receipt_record_failed" "The mission was imported but its receipt could not be recorded. Reconcile the action." false
    return mcpOk settled

  -- Compute Fleet & Managed Machines
  | "get_compute_fleet" =>
    let models ← if tenantScoped || userIsAdmin || legacyOwner then
        OrbCore.ProviderUsageAndLogin.configuredOpenCodeOptions store callerUserId (userIsAdmin || legacyOwner)
      else pure #[]
    let overrides := JVal.arr (models.filterMap (·.field? "value"))
    let some mc := mc?
      | return mcpOk (.obj #[("opencode_model_overrides", overrides), ("nodes", .arr #[]), ("managed_nodes", .arr #[]), ("static_nodes", .arr #[])])
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let fv ← buildComputeFleetJVal relayHub? mc fleet scopedUid? userComputeSpent userCap? store.rootDir nowIso (some store)
    return mcpOk (fv.setField "opencode_model_overrides" overrides)

  | "list_managed_machines" =>
    let some mc := mc?
      | return mcpOk (.obj #[("machines", .arr #[])])
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let prefs ← if managedPreferenceUserId.isEmpty then pure #[] else getUserManagedPrefs mc managedPreferenceUserId
    let .ok catalog ← loadManagedProviderCatalog mc store.rootDir fleet
        userIsAdmin prefs (managedProvisioningOverride?.map Prod.fst)
      | return mcpErr "unavailable" "managed_provider_catalog_unavailable"
    -- Destroyed machines are history, and there are thousands of them: the
    -- default list is the live ones; `verbose` adds the last 24 hours.
    let verbose := (args.fieldBool? "verbose").getD false
    let mut shown : Array ManagedMachine := #[]
    for m in fleet.machines do
      if m.status == "destroyed" && !(verbose && max m.createdAtSec m.expiresAtSec + 86400 ≥ nowEpochSec) then
        continue
      if ← canManageMachine m then shown := shown.push m
    let raw := renderManagedMachinesJson { fleet with machines := shown } scopedUid? userIsAdmin prefs userComputeSpent userCap?
    return mcpOk ((((OrbBin.Json.parse raw).toOption.getD (.obj #[])).setField "providers" catalog).setField
      "default_provider" (.str (← defaultManagedProvider)))

  | "get_budget" =>
    let some mc := mc?
      | return mcpOk (.obj #[("enabled", .bool false)])
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let targetMid := (args.fieldStr? "mission_id").getD callerMid
    if !targetMid.isEmpty then
      if targetMid != callerMid then
        match ← checkMissionReadAccess store claims targetMid nowEpochSec with
        | .ok () => pure ()
        | .error _ => return mcpErr "not_found" "Mission not found"
      let bCfg ← getMissionBudgetConfig mc targetMid
      let targetOwnerUid := ((← getMission? store targetMid).map (·.ownerUserId)).getD callerUserId
      let raw ← renderMissionBudgetJsonWithStore mc fleet bCfg targetOwnerUid nowEpochSec
      return mcpOk ((OrbBin.Json.parse raw).toOption.getD (.obj #[]))
    else
      let raw := renderManagedBudgetJson fleet scopedUid? userComputeSpent userCap?
      return mcpOk ((OrbBin.Json.parse raw).toOption.getD (.obj #[]))

  | "spawn_managed_machine" =>
    -- Accept at once and provision in the background: readiness takes minutes
    -- and callers used to time out with the outcome unknown. `get_action`
    -- returns the machine once it is ready, or the failure.
    -- Without a key, or without any owner to scope a receipt to, stay blocking.
    if idemKeyTop.isEmpty || (callerUserId.isEmpty && callerMid.isEmpty) then
      match ← spawnForCaller args "" with
      | .error (code, message) => return mcpErr code message
      | .ok (saved, choice) =>
        return mcpOk (choice.annotate ((OrbBin.Json.parse (renderManagedMachineItemJson saved)).toOption.getD (.obj #[])))
    let work : IO (Except String JVal) := do
      match ← spawnForCaller args "" with
      | .error (_, message) => return .error message
      | .ok (saved, choice) =>
        return .ok (choice.annotate ((OrbBin.Json.parse (renderManagedMachineItemJson saved)).toOption.getD (.obj #[])))
    -- Arguments that can never be admitted are refused now, not in a receipt.
    let admit : IO (Except String Unit) := do
      let provider := (← chooseSpawnProvider args false).provider
      let prefs ← match mc? with
        | some mc => if managedPreferenceUserId.isEmpty then pure #[] else getUserManagedPrefs mc managedPreferenceUserId
        | none => pure #[]
      if !isUserManagedProviderEnabled prefs provider then return .error "provider_disabled_for_user"
      let size ← match ← resolveSpawnSize provider args with
        | .ok size => pure size
        | .error e => return .error e
      match quoteManagedSpawnCents provider size ((args.fieldUInt64? "ttl_minutes").getD 60)
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
    return mcpErr "unsupported" "raw execution is unavailable on managed machines"

  | "stop_managed_machine" | "resume_managed_machine" | "destroy_managed_machine" | "extend_managed_machine" =>
    withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let some mc := mc? | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable" "managed compute store not configured" nowIso
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let some canonicalId ← resolveManagedMachineId? mc mid
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    let some (m, _) ← getManagedMachine? mc canonicalId
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    if !(← canManageMachine m) then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    let action := if toolName == "stop_managed_machine" then "stop"
      else if toolName == "destroy_managed_machine" then "destroy"
      else if toolName == "extend_managed_machine" then "extend" else "resume"
    let targetOwner := if m.ownerMission.isEmpty then callerMid else m.ownerMission
    match ← runConfiguredManagedLifecycle mc { store, fleet := defaultFleet, override? := managedProvisioningOverride? }
        m.id action nowEpochSec args idemKeyTop with
    | .error e =>
      if isManagedLifecycleUncertainError e then
        if !idemKeyTop.isEmpty then
          return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" e nowIso "lifecycle_uncertain" (some false) targetOwner
        return mcpErr "lifecycle_uncertain" e false "unknown"
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "lifecycle_rejected" e nowIso false targetOwner
    | .ok result =>
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args result nowIso targetOwner
        | return mcpErr "receipt_record_failed" "The lifecycle action completed but its receipt could not be recorded." false
      return mcpOk (if idemKeyTop.isEmpty then result.setField "action_id" (settled.fieldOrNull "action_id") else settled)

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

  | "snapshot_managed_machine" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    let some mc := mc? | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable" "managed compute store not configured" nowIso
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let some canonicalId ← resolveManagedMachineId? mc mid
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    let some (machine, slice) ← getManagedMachine? mc canonicalId
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    if !(← canManageMachine machine) then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    let project ← snapshotProject
    if project.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "snapshot_failed" "managed_snapshot_requires_project" nowIso
    if slice.phaseCode != 1 then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "snapshot_failed" "managed_machine_not_running" nowIso true
    let provider ← match ← snapshotProvider machine.provider with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable" e nowIso true
    match ← saveProjectSnapshot store provider project machine ((args.fieldStr? "name").getD "") with
    | .ok entry =>
      let resObj := ManagedSnapshotCatalog.entryJson entry
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso (if machine.ownerMission.isEmpty then callerMid else machine.ownerMission)
        | return mcpErr "receipt_record_failed" "The snapshot succeeded but its receipt could not be recorded." false
      return mcpOk (if idemKeyTop.isEmpty then resObj.setField "action_id" (settled.fieldOrNull "action_id") else settled)
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "snapshot_failed" e nowIso

  | "list_managed_snapshots" =>
    if mc?.isNone then return mcpOk (.obj #[("snapshots", .arr #[])])
    let project ← snapshotProject
    if project.isEmpty then
      return mcpOk (.obj #[("snapshots", .arr #[]), ("note", .str "This mission has no project; snapshots are project-scoped.")])
    let provider ← match ← snapshotProvider (canonicalizeProvider ((args.fieldStr? "provider").getD (← defaultManagedProvider))) with
      | .ok p => pure p
      | .error e => return mcpErr "unavailable" e true
    match ← projectSnapshotEntries store provider project with
    | .error e => return mcpErr "unavailable" e true
    | .ok entries =>
      return mcpOk (.obj #[("project", .str project),
        ("snapshots", .arr (entries.map ManagedSnapshotCatalog.entryJson))])

  | "delete_managed_snapshot" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    if mc?.isNone then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable" "managed compute store not configured" nowIso
    let requested := (args.fieldStr? "name").orElse (fun _ => args.fieldStr? "snapshot_id")
      |>.orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let provider ← match ← snapshotProvider (canonicalizeProvider ((args.fieldStr? "provider").getD (← defaultManagedProvider))) with
      | .ok p => pure p
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable" e nowIso true
    match ← deleteProjectSnapshot store provider (← snapshotProject) requested with
    | .ok name =>
      let resObj := JVal.obj #[("ok", .bool true), ("deleted", .str name)]
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso callerMid
        | return mcpErr "receipt_record_failed" "The snapshot was deleted but its receipt could not be recorded." false
      return mcpOk (if idemKeyTop.isEmpty then resObj.setField "action_id" (settled.fieldOrNull "action_id") else settled)
    | .error e =>
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop (if e.startsWith "managed_snapshot_not_found" then "not_found" else "snapshot_delete_failed") e nowIso

  | "fork_managed_machine" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    -- A fork is rented through the shared spawn path from the source's disk: the
    -- caller owns it, pays for it and waits for its own node to enrol.
    let some mc := mc? | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unavailable" "managed compute store not configured" nowIso
    let srcId := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "source_machine_id") |>.getD ""
    let some canonicalId ← resolveManagedMachineId? mc srcId
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    let some (source, slice) ← getManagedMachine? mc canonicalId
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    if !(← canManageMachine source) then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" "Managed machine not found" nowIso
    if slice.phaseCode != 1 then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "fork_rejected" "managed_machine_not_running" nowIso true
    let spawnArgs := JVal.obj #[
      ("provider", .str source.provider), ("size", .str source.size),
      ("ttl_minutes", JVal.uint64 ((args.fieldUInt64? "ttl_minutes").getD source.ttlMinutes)),
      ("name", .str ((args.fieldStr? "name").getD "")),
      ("idempotency_key", .str idemKeyTop)]
    let targetOwner := if source.ownerMission.isEmpty then callerMid else source.ownerMission
    match ← spawnForCaller spawnArgs source.effectiveProviderId with
    | .error (code, message) =>
      if isManagedLifecycleUncertainError message then
        if !idemKeyTop.isEmpty then
          return ← settleReservedMcpAction store claims callerUserId toolName idemKeyTop "uncertain" message nowIso "fork_uncertain" (some false) targetOwner
        return mcpErr "fork_uncertain" message false "unknown"
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop (if code == "spawn_rejected" then "fork_rejected" else code) message nowIso false targetOwner
    | .ok (forked, _) =>
      let item := (OrbBin.Json.parse (renderManagedMachineItemJson forked)).toOption.getD (.obj #[])
      let resObj := match item with
        | .obj fields => .obj (fields.push ("forked_from", .str source.id))
        | other => other
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args resObj nowIso (if forked.ownerMission.isEmpty then targetOwner else forked.ownerMission)
        | return mcpErr "receipt_record_failed" "The machine was forked but its receipt could not be recorded." false
      return mcpOk (if idemKeyTop.isEmpty then resObj.setField "action_id" (settled.fieldOrNull "action_id") else settled)

  -- Projects, Controller & Board
  | "list_projects" =>
    let allProjs ← listProjectsJVal store callerUserId
      (((← getBootstrapAdmin? store).map (·.id)).getD "") (!tenantScoped) false
    let filtered :=
      if claims.project.isEmpty then allProjs
      else allProjs.filter (fun p => (p.fieldStr? "slug") == some claims.project)
    return mcpOk (.obj #[("projects", .arr filtered)])

  | "get_project" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    if slug.isEmpty then return mcpErr "invalid_arguments" "missing project slug"
    return mcpOk (← getProjectJVal store slug slug)

  | "update_project_status" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    if normalizeMcpRole claims.role == "executor" then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" "update_project_status requires coordinator or operator role" nowIso
    -- #1807 retired project steers and controller status fields (`mode`/`next_action`/`blocker`).
    -- Refuse them explicitly so callers never believe discarded steer IDs were acknowledged.
    if let .obj kvs := args then
      for (k, v) in kvs do
        if v != .null then
          if k == "consumed_steer_ids" then
            return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported" "Project steers were retired; update_project_status does not accept or acknowledge consumed_steer_ids." nowIso
          if #["mode", "next_action", "blocker"].contains k then
            return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "unsupported" s!"Field `{k}` was retired; update_project_status only accepts slug, status, and idempotency_key." nowIso
          if !#["slug", "project", "status", "idempotency_key"].contains k then
            return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" s!"unknown argument `{k}` for update_project_status" nowIso
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso
    if slug.isEmpty then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing project slug" nowIso
    if idemKeyTop.isEmpty || idemKeyTop.utf8ByteSize > 200 then
      return mcpErr "invalid_arguments" "missing idempotency_key"
    let some stVal := (args.fieldStr? "status").map (·.trimAscii.toString)
      | return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "status is required (active, paused, completed, or archived)" nowIso
    if !#["active", "paused", "completed", "archived"].contains stVal then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" s!"unknown project status `{stVal}`; expected active, paused, completed, or archived" nowIso
    match ← execParamQuery store.projectsDb "SELECT slug FROM projects WHERE slug=?1 LIMIT 1;" #[slug] with
    | .ok rows => unless rows.size > 1 do return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" s!"Project `{slug}` not found" nowIso
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "internal_error" e nowIso true
    match ← execParamQuery store.projectsDb
        "UPDATE projects SET status=?2, updated_at=?3 WHERE slug=?1;" #[slug, stVal, nowIso] with
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "internal_error" e nowIso true
    | .ok _ => pure ()
    let projObj ← getProjectJVal store slug slug
    let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args projObj nowIso ""
      | return mcpErr "receipt_record_failed" "The project status was updated but its receipt could not be recorded. Reconcile the action." false
    return mcpOk settled

  | "get_project_grant" =>
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return mcpErr "project_scope_violation" e
    return mcpOk (← getProjectGrantJVal store slug slug)

  | "set_project_grant" => withReservedMcpOutcome store claims callerUserId toolName idemKeyTop nowIso do
    if normalizeMcpRole claims.role != "operator" && !userIsAdmin then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "forbidden" "set_project_grant requires operator role" nowIso
    let rawSlug := (args.fieldStr? "project").orElse (fun _ => args.fieldStr? "slug") |>.getD callerProj
    let slug ← match checkProjectScope claims rawSlug with
      | .ok s => pure s
      | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "project_scope_violation" e nowIso
    if slug.isEmpty then return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" "missing project slug" nowIso
    if idemKeyTop.isEmpty then
      return mcpErr "invalid_arguments" "missing idempotency_key"
    let grantMcpExtra := #["slug", "project", "idempotency_key"]
    if let .error e := validateProjectGrantPatch args grantMcpExtra then
      return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "invalid_arguments" e nowIso
    match ← execParamQuery store.projectsDb "SELECT slug FROM projects WHERE slug=?1 LIMIT 1;" #[slug] with
    | .ok rows => unless rows.size > 1 do return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "not_found" s!"Project `{slug}` not found" nowIso
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "internal_error" e nowIso true
    match ← upsertProjectGrantJVal store slug slug args nowIso grantMcpExtra with
    | .ok grant =>
      let .ok settled ← recordSettledMcpAction store claims callerUserId toolName args grant nowIso ""
        | return mcpErr "receipt_record_failed" "The project grant was updated but its receipt could not be recorded. Reconcile the action." false
      return mcpOk settled
    | .error e => return ← failReservedOrErr store claims callerUserId toolName idemKeyTop "internal_error" e nowIso true

  -- Workspaces & Jobs
  | "list_workspaces" =>
    let mut items : Array JVal := #[]
    if let .ok rows ← execParamQuery store.missionsDb
        "SELECT id, name, workspace_type, path, status FROM workspaces WHERE (?1='0' OR owner_user_id=?2) ORDER BY name ASC;"
        #[if tenantScoped then "1" else "0", callerUserId] then
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
        "SELECT id, name, workspace_type, path, status FROM workspaces WHERE (id=?1 OR name=?1) AND (?2='0' OR owner_user_id=?3) LIMIT 1;"
        #[wid, if tenantScoped then "1" else "0", callerUserId] then
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
    return mcpErr "not_implemented" s!"`{toolName}` is not implemented; use start_mission or durable jobs instead"

  -- Bitwarden Secret Broker, Mission Access & Privilege Broker
  | "secret_list" =>
    let callerSubject := if claims.isExternal then "session:" ++ claims.sessionId
      else if !callerMid.isEmpty then "mission:" ++ callerMid else ""
    return mcpOk (← mcpSecretList workingDir store.rootDir callerMid callerProj nowEpochSec callerSubject)

  | "secret_get" =>
    let secName := (args.fieldStr? "name").orElse (fun _ => args.fieldStr? "secret_name") |>.getD ""
    let reason := (args.fieldStr? "reason").getD ""
    if secName.isEmpty then return mcpErr "invalid_arguments" "missing secret name"
    -- A caller whose mission runs on a managed machine is untrusted: allowlisted secrets only.
    let callerOnManagedNode ← missionHasManagedPlacement store mc? callerMid
    let callerSubject := if claims.isExternal then "session:" ++ claims.sessionId
      else if !callerMid.isEmpty then "mission:" ++ callerMid else ""
    let initial ← mcpSecretGet workingDir store.rootDir callerMid callerProj secName reason callerOnManagedNode nowEpochSec callerSubject
    let waitSec ←
      match args.fieldNat? "wait_seconds" with
      | some n => pure (Nat.min 25 n)
      | none =>
        match (← IO.getEnv "ORB_SECRET_WAIT_SECONDS").bind String.toNat? with
        | some n => pure (Nat.min 25 n)
        | none => pure (if (← IO.getEnv "ORB_HERMETIC_TEST") == some "1" then 0 else 25)
    let mut finalRes := initial
    if (initial.fieldStr? "status") == some "pending" then
      let reqId := (initial.fieldStr? "request_id").getD ""
      if !reqId.isEmpty && waitSec > 0 then
        finalRes ← mcpSecretWait workingDir store.rootDir callerMid callerProj reqId callerSubject callerOnManagedNode waitSec (← coreEpochSec)
      if (finalRes.fieldStr? "status") == some "pending" && !reqId.isEmpty && !callerMid.isEmpty then
        let bwProj := (finalRes.fieldStr? "bitwarden_project").orElse (fun _ => initial.fieldStr? "bitwarden_project") |>.getD ""
        let armed ← armSecretApprovalWakeup store callerMid reqId "secret_get" secName bwProj (← coreEpochSec)
        if armed then
          finalRes := finalRes.setField "auto_resume" (.bool true)
    return mcpOk finalRes

  | "secret_put" | "secret_delete" | "secret_move" =>
    return mcpErr "unsupported" s!"`{toolName}` is not implemented; Bitwarden secret mutations (write/delete/move) are unsupported and no request was queued."

  | "secret_request" =>
    let bwProj := (args.fieldStr? "bitwarden_project").orElse (fun _ => args.fieldStr? "project") |>.getD "unassigned"
    let secName := (args.fieldStr? "name").orElse (fun _ => args.fieldStr? "secret_name") |>.getD ""
    let val := (args.fieldStr? "value").getD ""
    let note := (args.fieldStr? "note").getD ""
    let reason := (args.fieldStr? "reason").getD ""
    let callerSubject := if claims.isExternal then "session:" ++ claims.sessionId
      else if !callerMid.isEmpty then "mission:" ++ callerMid else ""
    let initial ← mcpSecretQueueAction workingDir store.rootDir toolName callerMid callerProj bwProj secName val note reason nowEpochSec callerSubject
    let waitSec ←
      match args.fieldNat? "wait_seconds" with
      | some n => pure (Nat.min 25 n)
      | none =>
        match (← IO.getEnv "ORB_SECRET_WAIT_SECONDS").bind String.toNat? with
        | some n => pure (Nat.min 25 n)
        | none => pure (if (← IO.getEnv "ORB_HERMETIC_TEST") == some "1" then 0 else 25)
    let mut finalRes := initial
    if (initial.fieldStr? "status") == some "pending" then
      let reqId := (initial.fieldStr? "request_id").getD ""
      if !reqId.isEmpty && waitSec > 0 then
        let callerOnManagedNode ← missionHasManagedPlacement store mc? callerMid
        finalRes ← mcpSecretWait workingDir store.rootDir callerMid callerProj reqId callerSubject callerOnManagedNode waitSec (← coreEpochSec)
      if (finalRes.fieldStr? "status") == some "pending" && !reqId.isEmpty && !callerMid.isEmpty then
        let armed ← armSecretApprovalWakeup store callerMid reqId toolName secName bwProj (← coreEpochSec)
        if armed then
          finalRes := finalRes.setField "auto_resume" (.bool true)
    return mcpOk finalRes

  | "request_mission_access" =>
    let targetMid := (args.fieldStr? "target_mission_id").orElse (fun _ => args.fieldStr? "mission_id") |>.getD ""
    let reason := (args.fieldStr? "reason").getD ""
    let ttlHrs := (args.fieldNat? "ttl_hours").getD 24
    if targetMid.isEmpty then return mcpErr "invalid_arguments" "missing target_mission_id"
    let callerSubject := if claims.isExternal then "session:" ++ claims.sessionId
      else if !callerMid.isEmpty then "mission:" ++ callerMid else ""
    return mcpOk (← mcpRequestMissionAccess store.rootDir callerMid targetMid reason ttlHrs nowEpochSec callerSubject)

  | "list_mission_access" =>
    let callerSubject := if claims.isExternal then "session:" ++ claims.sessionId
      else if !callerMid.isEmpty then "mission:" ++ callerMid else ""
    return mcpOk (← mcpListMissionAccess store.rootDir callerMid nowEpochSec callerSubject)

  | "get_dev_access" | "deploy_dev" | "read_dev_logs" =>
    if claims.isExternal || callerMid.isEmpty then
      return mcpErr "dev_operator_mission_required" "A mission with its own approved dev_operator grant is required"
    match ← OrbCore.DevOperator.call store callerMid toolName args nowEpochSec OrbCore.DevOperator.runCommand with
    | .ok value => return mcpOk value
    | .error err => return mcpErr err "Dev operation denied or unavailable"

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
    let listing ← mcpListPrivilegedAccess store store.rootDir callerMid nowEpochSec claims.sessionId true
    if !userIsAdmin && !legacyOwner then
      -- A member may discover its own approved dev pass, never the host audit,
      -- generic privilege leases or the raw lease token behind the dev bearer.
      let onlyDev := fun (values : Array JVal) => values.filter (fun value => value.fieldStr? "scope" == some "dev_operator")
      return mcpOk (.obj #[("requests", .arr (onlyDev ((listing.fieldArr? "requests").getD #[]))),
        ("grants", .arr ((onlyDev ((listing.fieldArr? "grants").getD #[])).map (·.removeField "lease_token")))])
    return mcpOk listing

  | "revoke_privileged_access" =>
    let gid := (args.fieldStr? "grant_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let rev? ← mcpRevokePrivilegedAccess store store.rootDir gid callerMid nowEpochSec
    return mcpOk (.obj #[("ok", .bool rev?.isSome), ("grant_id", .str gid)])

  | "execute_privileged_command" =>
    return mcpErr "privilege_requires_lease" "Use POST /api/privilege/exec with an active biometric-approved grant_id"

  | "create_worktree" | "remove_worktree" | "merge_branch" | "create_workspace" | "update_workspace"
  | "delete_workspace" | "get_backend_auth_status" | "deploy_sandboxed_sh" =>
    return mcpErr "unsupported" s!"`{toolName}` is advertised but not implemented; no state was changed."

  -- Cloud Execution / Models Discovery
  | "list_cloud_models" =>
    return mcpErr "not_implemented" "Cloud model discovery is not implemented; no models were listed."

  | "list_cloud_accounts" =>
    let some hub := cloudHub?
      | return mcpErr "cloud_unavailable" "Cloud runtime is unavailable; no accounts were listed."
    let username := (user?.map (·.username)).getD ""
    let bootstrapId := ((← getBootstrapAdmin? store).map (·.id)).getD ""
    let accts ← OrbCore.CloudHttpAndWorker.buildCloudAccountsJson hub store 0 callerUserId username bootstrapId userIsAdmin legacyOwner
    return mcpOk (.obj #[("accounts", accts)])

  | "get_cloud_execution" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD callerMid
    if mid.isEmpty then return mcpErr "invalid_arguments" "missing mission_id"
    if let .error e ← checkMissionReadAccess store claims mid nowEpochSec then
      return mcpErr "forbidden" e
    let includePrompt ← match args.field? "include_prompt" with
      | none | some .null => pure false
      | some (.bool b) => pure b
      | some _ => return mcpErr "invalid_arguments" "include_prompt must be a boolean"
    let limit ← match args.field? "limit" with
      | none | some .null => pure 1
      | some v =>
        match v.asNat? with
        | some n =>
          if n ≥ 1 && n ≤ 5 then pure n
          else return mcpErr "invalid_arguments" "limit must be an integer between 1 and 5"
        | none => return mcpErr "invalid_arguments" "limit must be an integer between 1 and 5"
    let offset? ← match args.field? "offset" with
      | none | some .null => pure none
      | some v =>
        match v.asNat? with
        | some n => pure (some n)
        | none => return mcpErr "invalid_arguments" "offset must be a non-negative integer"
    let textLimit ← match args.field? "text_limit" with
      | none | some .null => pure 4096
      | some v =>
        match v.asNat? with
        | some n =>
          if n ≥ 1 && n ≤ 8192 then pure n
          else return mcpErr "invalid_arguments" "text_limit must be an integer between 1 and 8192"
        | none => return mcpErr "invalid_arguments" "text_limit must be an integer between 1 and 8192"
    let textOffset ← match args.field? "text_offset" with
      | none | some .null => pure 0
      | some v =>
        match v.asNat? with
        | some n => pure n
        | none => return mcpErr "invalid_arguments" "text_offset must be a non-negative integer"
    match ← OrbCore.CloudHttpAndWorker.loadCloudExecutionJson? store mid with
    | none =>
      return mcpOk (.obj #[("enabled", .bool false), ("mission_id", .str mid), ("revision", .null), ("execution", .null)])
    | some (rev, execJv) =>
      let allTurns := (execJv.fieldArr? "turns").getD #[]
      let totalTurns := allTurns.size
      let startIdx := match offset? with
        | some o => Nat.min o totalTurns
        | none => if totalTurns > limit then totalTurns - limit else 0
      let endIdx := Nat.min totalTurns (startIdx + limit)
      let sliceText (raw : String) : String × JVal :=
        let totalChars := raw.length
        let sliced := ((raw.drop textOffset).take textLimit).toString
        let consumed := Nat.min totalChars (textOffset + sliced.length)
        let truncated := consumed < totalChars
        let metaJv := JVal.obj #[
          ("offset", JVal.nat textOffset),
          ("returned", JVal.nat sliced.length),
          ("total_chars", JVal.nat totalChars),
          ("truncated", .bool truncated),
          ("next_offset", if truncated then JVal.nat consumed else .null)
        ]
        (sliced, metaJv)
      let mut pagedTurns : Array JVal := #[]
      for idx in [startIdx:endIdx] do
        let t := allTurns[idx]!
        let mut tObj := (t.removeField "prompt").removeField "artifacts" |>.removeField "branches"
        let artCnt := ((t.fieldArr? "artifacts").getD #[]).size
        let brCnt := ((t.fieldArr? "branches").getD #[]).size
        tObj := (tObj.setField "artifact_count" (JVal.nat artCnt)).setField "branch_count" (JVal.nat brCnt)
        let mut slices : Array (String × JVal) := #[]
        if includePrompt then
          if let some pStr := t.fieldStr? "prompt" then
            let (ps, pm) := sliceText pStr
            tObj := tObj.setField "prompt" (.str ps)
            slices := slices.push ("prompt", pm)
        if let some rStr := t.fieldStr? "result" then
          let (rs, rm) := sliceText rStr
          tObj := tObj.setField "result" (.str rs)
          slices := slices.push ("result", rm)
        if let some dStr := t.fieldStr? "detail" then
          let (ds, dm) := sliceText dStr
          tObj := tObj.setField "detail" (.str ds)
          slices := slices.push ("detail", dm)
        tObj := tObj.setField "text_slices" (.obj slices)
        pagedTurns := pagedTurns.push tObj
      let pageObj := JVal.obj #[
        ("offset", JVal.nat startIdx),
        ("limit", JVal.nat limit),
        ("returned", JVal.nat pagedTurns.size),
        ("total_turns", JVal.nat totalTurns),
        ("next_offset", if endIdx < totalTurns then JVal.nat endIdx else .null)
      ]
      let boundedExec := (execJv.setField "turns" (.arr pagedTurns)).setField "page" pageObj
      return mcpOk (.obj #[
        ("enabled", .bool true), ("mission_id", .str mid), ("revision", JVal.nat rev),
        ("page", pageObj), ("execution", boundedExec)
      ])

  | _ =>
    return mcpErr "unknown_tool" s!"Unknown or unsupported MCP tool `{toolName}`"

/-! ## Direct Streamable HTTP MCP JSON-RPC 2.0 Endpoint (`POST /api/mcp/rpc`) -/

def mcpRpcSupportedProtocolVersions : Array String :=
  #["2025-06-18", "2025-03-26", "2024-11-05"]

def negotiateMcpProtocolVersion (requested? : Option String) : String :=
  match requested? with
  | some v =>
    let clean := v.trimAscii.toString
    if mcpRpcSupportedProtocolVersions.contains clean then clean else "2025-03-26"
  | none => "2025-03-26"

def mcpRpcError (idVal : JVal) (code : Int) (message : String) : JVal :=
  .obj #[
    ("jsonrpc", .str "2.0"),
    ("id", idVal),
    ("error", .obj #[
      ("code", JVal.int code),
      ("message", .str message)
    ])
  ]

def mcpRpcSuccess (idVal : JVal) (result : JVal) : JVal :=
  .obj #[
    ("jsonrpc", .str "2.0"),
    ("id", idVal),
    ("result", result)
  ]

/-- Convert internal `McpGateway` `{ ok, result, error }` reply into standard MCP `CallToolResult`. -/
def convertGatewayReplyToMcpCallResult (httpStatus : Nat) (rawReply : String) : JVal :=
  match OrbBin.Json.parse rawReply with
  | .ok jv =>
    if httpStatus < 300 && jv.fieldBool? "ok" == some true then
      let resVal := jv.fieldOrNull "result"
      let txt := renderCompact resVal
      let baseFields : Array (String × JVal) := #[
        ("content", .arr #[.obj #[("type", .str "text"), ("text", .str txt)]]),
        ("isError", .bool false)
      ]
      let fields :=
        if resVal.asObj?.isSome then baseFields.push ("structuredContent", resVal)
        else baseFields
      .obj fields
    else
      let errPayload :=
        match jv.field? "error" with
        | some e => renderCompact e
        | none => rawReply
      .obj #[
        ("content", .arr #[.obj #[("type", .str "text"), ("text", .str errPayload)]]),
        ("isError", .bool true)
      ]
  | .error _ =>
    .obj #[
      ("content", .arr #[.obj #[("type", .str "text"), ("text", .str rawReply)]]),
      ("isError", .bool (httpStatus >= 300))
    ]

private def catalogToolsJValForRole (role : String) : JVal :=
  let raw := (OrbBin.McpCatalog.catalogPrettyJsonForRole role).getD
    ((OrbBin.McpCatalog.catalogPrettyJsonForRole "executor").getD "[]")
  match OrbBin.Json.parse raw with
  | .ok (.arr items) => .arr items
  | _ => .arr #[]

private def isValidJsonRpcIdVal : JVal → Bool
  | .str _ => true
  | .num _ => true
  | _ => false

/-- Handle a single JSON-RPC 2.0 Streamable HTTP MCP message.
    Returns `none` for JSON-RPC notifications (no `id` field). -/
private def handleSingleStreamableMcpRpc
    (claims : McpSessionClaims)
    (msg : JVal)
    (executeTool : String → JVal → IO (Nat × String)) : IO (Option JVal) := do
  if msg.asObj?.isNone then
    return some (mcpRpcError .null (-32600) "Invalid Request")
  let method := (msg.fieldStr? "method").getD ""
  match msg.field? "id" with
  | none =>
    -- Notification (e.g. `notifications/initialized`, `notifications/cancelled`): no response body.
    return none
  | some idVal =>
    if (msg.fieldStr? "jsonrpc") != some "2.0" || method.isEmpty || !isValidJsonRpcIdVal idVal then
      return some (mcpRpcError (if isValidJsonRpcIdVal idVal then idVal else .null) (-32600) "Invalid Request")
    let params := (msg.field? "params").getD (.obj #[])
    match method with
    | "initialize" =>
      let proto := negotiateMcpProtocolVersion (params.fieldStr? "protocolVersion")
      return some (mcpRpcSuccess idVal (.obj #[
        ("protocolVersion", .str proto),
        ("capabilities", .obj #[
          ("tools", .obj #[("listChanged", .bool false)])
        ]),
        ("serverInfo", .obj #[
          ("name", .str "sandboxed"),
          ("version", .str "1.3.0")
        ])
      ]))
    | "ping" =>
      return some (mcpRpcSuccess idVal (.obj #[]))
    | "tools/list" =>
      let roleNorm := normalizeMcpRole claims.role
      let toolsArr := catalogToolsJValForRole roleNorm
      return some (mcpRpcSuccess idVal (.obj #[("tools", toolsArr)]))
    | "resources/list" =>
      return some (mcpRpcSuccess idVal (.obj #[("resources", .arr #[])]))
    | "resources/templates/list" =>
      return some (mcpRpcSuccess idVal (.obj #[("resourceTemplates", .arr #[])]))
    | "prompts/list" =>
      return some (mcpRpcSuccess idVal (.obj #[("prompts", .arr #[])]))
    | "tools/call" =>
      let toolName := ((params.fieldStr? "name").getD "").trimAscii.toString
      if toolName.isEmpty then
        return some (mcpRpcError idVal (-32602) "Invalid params: missing tool name")
      let args := (params.field? "arguments").getD (.obj #[])
      if args.asObj?.isNone then
        return some (mcpRpcError idVal (-32602) "Invalid params: arguments must be an object")
      let (httpSt, rawReply) ← executeTool toolName args
      return some (mcpRpcSuccess idVal (convertGatewayReplyToMcpCallResult httpSt rawReply))
    | _ =>
      return some (mcpRpcError idVal (-32601) s!"Method not found: {method}")

/-- Streamable HTTP MCP JSON-RPC 2.0 handler (`POST /api/mcp/rpc`).
    Supports single requests, notifications (`202 Accepted`), and JSON-RPC batch arrays,
    delegating tool execution to Core's unified authorization & `McpGateway` dispatcher. -/
def handleStreamableMcpRpc
    (claims : McpSessionClaims)
    (rawBody : ByteArray)
    (executeTool : String → JVal → IO (Nat × String)) : IO (Nat × Option String) := do
  match OrbBin.Json.parseBytes rawBody with
  | .error _ =>
    return (400, some (renderCompact (mcpRpcError .null (-32700) "Parse error")))
  | .ok (.arr batch) =>
    if batch.isEmpty then
      return (400, some (renderCompact (mcpRpcError .null (-32600) "Invalid Request")))
    let mut responses : Array JVal := #[]
    for item in batch do
      if let some resp ← handleSingleStreamableMcpRpc claims item executeTool then
        responses := responses.push resp
    if responses.isEmpty then
      return (202, none)
    else
      return (200, some (renderCompact (.arr responses)))
  | .ok single =>
    match ← handleSingleStreamableMcpRpc claims single executeTool with
    | none => return (202, none)
    | some resp =>
      let isReqErr :=
        match resp.field? "error" >>= (·.fieldInt? "code") with
        | some (-32600) => true
        | _ => false
      return (if isReqErr then 400 else 200, some (renderCompact resp))

end OrbCore.McpGateway
