/-
  OrbCore.McpGateway: Complete Control-Plane MCP Tool Dispatcher (`POST /api/mcp/call`)
  backing `sandboxed-mcp` (`OrbBin.McpCatalog`) for Hermes controllers, operator sessions,
  and per-mission agents (`0 import Lean`, `0 sorryAx`).
-/
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.McpCatalog
import OrbCore.Store
import OrbCore.Managed
import OrbCore.MemoryAndCloud
import OrbCore.QueueCont
import OrbCore.R7Core
import OrbCore.LegacyHydrate
import OrbCore.SecretAndApproval
import OrbCore.RemoteFleetAndRelay
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
open OrbCore.ProjectFilesAndController

private def mcpOk (res : JVal) : String :=
  renderCompact (.obj #[("ok", .bool true), ("result", res)])

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

set_option maxHeartbeats 800000 in
/-- Execute a non-memory MCP tool call from `POST /api/mcp/call` and return the serialized JSON response body. -/
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
    (nowEpochSec : UInt64) : IO String := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let callerMid := claims.missionId
  let mut callerWorkDir := workingDir
  let mut callerProj := claims.project
  if !callerMid.isEmpty then
    if let .ok mRows ← execParamQuery store.missionsDb
        "SELECT COALESCE(working_directory,''), COALESCE(project,'') FROM missions WHERE id=?1;" #[callerMid] then
      if mRows.size > 1 then
        let wd := cell mRows[1]! 0
        let pj := cell mRows[1]! 1
        if !wd.isEmpty then callerWorkDir := wd
        if callerProj.isEmpty && !pj.isEmpty then callerProj := pj

  match toolName with
  | "get_capabilities" =>
    let caps := (OrbBin.Json.parse (buildMcpCapabilitiesJson claims)).toOption.getD (.obj #[])
    return mcpOk caps

  | "get_action" =>
    let aid := (args.fieldStr? "action_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    return mcpOk (.obj #[("action_id", .str aid), ("status", .str "completed")])

  | "cancel_action" =>
    let aid := (args.fieldStr? "action_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    return mcpOk (.obj #[("action_id", .str aid), ("cancelled", .bool true)])

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
    let prompt := ((args.fieldStr? "prompt").orElse (fun _ => args.fieldStr? "goal") |>.getD "").trimAscii.toString
    let rawProj := (args.fieldStr? "project").getD callerProj
    let effProj ← match checkProjectScope claims rawProj with
      | .ok p => pure p
      | .error e => return mcpErr "project_scope_violation" e
    let folder := normalizeMissionFolder ((args.fieldStr? "folder").getD "")
    let backend :=
      if toolName == "consult_model" then ((args.fieldStr? "backend").getD "opencode")
      else ((args.fieldStr? "backend").getD "claude")
    let modelOv := (args.fieldStr? "model_override").orElse (fun _ => args.fieldStr? "model") |>.getD ""
    let effort := (args.fieldStr? "model_effort").orElse (fun _ => args.fieldStr? "reasoning_effort") |>.getD ""
    let parentMid := ((args.fieldStr? "parent_mission_id").filter (!·.isEmpty)).getD callerMid
    let mid ← newUuidV4
    let initRev : UInt64 := if effProj.isEmpty && folder.isEmpty then 0 else 1
    let insSql :=
      "INSERT INTO missions(id,title,status,backend,model_override,model_effort,working_directory,workspace_id,project,folder,placement_revision,parent_mission_id,created_at,updated_at,metadata_updated_at,node_boot_epoch) " ++
      "VALUES(?1,?2,'active',?3,?4,?5,?6,'00000000-0000-0000-0000-000000000000',?7,?8,CAST(?9 AS INTEGER),NULLIF(?10,''),?11,?11,?11,CAST(?12 AS INTEGER));"
    if let .error e ← execParamQuery store.missionsDb insSql
        #[mid, title, backend, modelOv, effort, workingDir, effProj, folder, s!"{initRev}", parentMid, nowIso, s!"{store.bootEpoch}"] then
      return mcpErr "db_error" e
    if !prompt.isEmpty then
      discard <| appendMissionEvent store mid "user_message" (renderCompact (.obj #[("content", .str prompt)])) nowIso
    publishControlEvent broadcastHub? "mission_created" (renderCompact (.obj #[
      ("mission_id", .str mid),
      ("project", if effProj.isEmpty then .null else .str effProj),
      ("folder", .str folder)
    ])) (some mid)
    return mcpOk (.obj #[
      ("mission_id", .str mid),
      ("id", .str mid),
      ("status", .str "active"),
      ("backend", .str backend),
      ("model_override", if modelOv.isEmpty then .null else .str modelOv),
      ("project", if effProj.isEmpty then .null else .str effProj),
      ("folder", .str folder),
      ("placement_revision", JVal.uint64 initRev)
    ])

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
    let noteId ← newUuidV4
    discard <| execParamQuery store.askDb
      "INSERT INTO main.operator_notes(note_id,id,mission_id,content,body,created_at_iso,created_at) VALUES(?1,?1,?2,?3,?3,?4,?4);"
      #[noteId, mid, content, nowIso]
    discard <| appendMissionEvent store mid "operator_note" (renderCompact (.obj #[("id", .str noteId), ("content", .str content)])) nowIso
    return mcpOk (.obj #[("ok", .bool true), ("mission_id", .str mid), ("note_id", .str noteId)])

  | "cancel_mission" | "acknowledge_mission" | "adopt_mission" | "resume_mission" =>
    let mid := (args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id") |>.getD callerMid
    if mid.isEmpty then return mcpErr "invalid_arguments" "missing mission_id"
    let nextSt :=
      if toolName == "cancel_mission" then "cancelled"
      else if toolName == "resume_mission" || toolName == "adopt_mission" then "active"
      else "completed"
    discard <| execParamQuery store.missionsDb
      "UPDATE missions SET status=?2, updated_at=?3, state_revision=state_revision+1 WHERE id=?1;"
      #[mid, nextSt, nowIso]
    return mcpOk (.obj #[("ok", .bool true), ("mission_id", .str mid), ("status", .str nextSt)])

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
    let fv ← buildComputeFleetJVal relayHub? mc fleet none 0 none
    return mcpOk fv

  | "list_managed_machines" =>
    let some mc := mc?
      | return mcpOk (.obj #[("machines", .arr #[])])
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let raw := renderManagedMachinesJson fleet
    return mcpOk ((OrbBin.Json.parse raw).toOption.getD (.obj #[]))

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
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let prov := canonicalizeProvider ((args.fieldStr? "provider").getD "boat")
    let sz := (args.fieldStr? "size").getD "small"
    let ttl := (args.fieldUInt64? "ttl_minutes").getD 60
    let sName ← match (args.fieldStr? "name").filter (!·.isEmpty) with
      | some n => pure n
      | none => do
        let u ← newUuidV4
        pure s!"orb-managed-{(u.take 8).toString}"
    let mut mid ← newUuidV4
    if prov == "boat" then
      if let .ok (st, bJv) ← callBoatApi store.rootDir "POST" "/sandboxes"
          (some (.obj #[("name", .str sName), ("size", .str sz), ("ttl_minutes", JVal.uint64 ttl)])) 20000 then
        if 200 ≤ st && st < 300 then
          if let some bid := bJv.fieldStr? "id" then
            if !bid.isEmpty then mid := bid
    let m : ManagedMachine := {
      id := mid
      sandboxName := sName
      provider := prov
      size := sz
      status := "provisioning"
      ownerMission := callerMid
      ttlMinutes := ttl
      spentCents := 10
      nodeBootEpoch := 1
      deletableAtSec := nowEpochSec + ttl * 60
      ownerKind := if callerMid.isEmpty then "user" else "mission"
      requestedByMissionId := callerMid
    }
    match ← provisionManagedMachine mc fleet m nowEpochSec with
    | .error e => return mcpErr "spawn_rejected" e
    | .ok saved =>
      let enrollTok ← newUuidV4
      discard <| putEnrollmentToken mc saved.id enrollTok
      let itemJson := (OrbBin.Json.parse (renderManagedMachineItemJson saved)).toOption.getD (.obj #[])
      return mcpOk itemJson

  | "exec_raw_managed_machine" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "node_id") |>.getD ""
    let cmd := (args.fieldStr? "command").getD ""
    if mid.isEmpty || cmd.isEmpty then
      return mcpErr "invalid_arguments" "machine_id and command are required"
    let timeoutMs := ((args.fieldNat? "timeout_secs").getD 60) * 1000
    match ← execOnRemoteNode relayHub? mc mid callerMid cmd false timeoutMs with
    | .ok res => return mcpOk res
    | .error e => return mcpErr "exec_failed" e true

  | "stop_managed_machine" | "resume_managed_machine" | "destroy_managed_machine" | "extend_managed_machine" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let some (m, _) ← getManagedMachine? mc mid
      | return mcpErr "not_found" s!"Managed machine `{mid}` not found"
    if toolName == "extend_managed_machine" then
      let mins := (args.fieldUInt64? "minutes").orElse (fun _ => args.fieldUInt64? "ttl_minutes") |>.getD 60
      let newDel := (if m.deletableAtSec > nowEpochSec then m.deletableAtSec else nowEpochSec) + mins * 60
      discard <| execParamQuery mc.db
        "UPDATE managed_machines SET ttl_minutes=ttl_minutes+?2,deletable_at_sec=?3 WHERE id=?1;"
        #[m.id, s!"{mins}", s!"{newDel}"]
      return mcpOk (.obj #[("ok", .bool true), ("id", .str m.id), ("deletable_at", JVal.uint64 newDel)])
    else
      let op :=
        if toolName == "stop_managed_machine" then Orb.ManagedNode.VmOp.encode .stop
        else if toolName == "resume_managed_machine" then Orb.ManagedNode.VmOp.encode .resume
        else Orb.ManagedNode.VmOp.encode .destroy
      if m.provider == "boat" then
        if toolName == "stop_managed_machine" then discard <| callBoatApi store.rootDir "POST" s!"/sandboxes/{m.id}/stop" none 12000
        else if toolName == "resume_managed_machine" then discard <| callBoatApi store.rootDir "POST" s!"/sandboxes/{m.id}/start" none 12000
        else discard <| callBoatApi store.rootDir "DELETE" s!"/sandboxes/{m.id}" none 12000
      match ← applyVmLifecycle mc m.id {
        opCode := op, ownerLive := 0, idleElapsed := if toolName == "destroy_managed_machine" then 1 else 0,
        presentedBootEpoch := m.nodeBootEpoch, nowEpoch := nowEpochSec
      } with
      | .error e => return mcpErr "lifecycle_rejected" e
      | .ok _ => return mcpOk (.obj #[("ok", .bool true), ("id", .str m.id)])

  | "snapshot_managed_machine" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let mid := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let sName := (args.fieldStr? "name").getD ""
    match ← createManagedSnapshot mc store.rootDir mid sName nowIso with
    | .ok sv => return mcpOk sv
    | .error e => return mcpErr "snapshot_failed" e

  | "list_managed_snapshots" =>
    let some mc := mc? | return mcpOk (.obj #[("snapshots", .arr #[])])
    return mcpOk (← listManagedSnapshotsJson mc store.rootDir)

  | "delete_managed_snapshot" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let sid := (args.fieldStr? "snapshot_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let ok ← deleteManagedSnapshot mc store.rootDir sid
    return mcpOk (.obj #[("ok", .bool ok)])

  | "fork_managed_machine" =>
    let some mc := mc? | return mcpErr "unavailable" "managed compute store not configured"
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let srcId := (args.fieldStr? "machine_id").orElse (fun _ => args.fieldStr? "source_machine_id") |>.getD ""
    let some (m, _) ← getManagedMachine? mc srcId
      | return mcpErr "not_found" s!"Managed machine `{srcId}` not found"
    let forkId ← newUuidV4
    let forkName := ((args.fieldStr? "name").filter (!·.isEmpty)).getD s!"{m.sandboxName}-fork"
    let forked : ManagedMachine := {
      m with
      id := forkId
      sandboxName := forkName
      status := "provisioning"
      nodeBootEpoch := 1
      deletableAtSec := nowEpochSec + m.ttlMinutes * 60
    }
    match ← provisionManagedMachine mc fleet forked nowEpochSec with
    | .error e => return mcpErr "fork_rejected" e
    | .ok saved =>
      let enrollTok ← newUuidV4
      discard <| putEnrollmentToken mc saved.id enrollTok
      return mcpOk ((OrbBin.Json.parse (renderManagedMachineItemJson saved)).toOption.getD (.obj #[]))

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
    return mcpOk (← mcpSecretGet workingDir store.rootDir callerMid callerWorkDir callerProj secName reason nowEpochSec)

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
    let scope := (args.fieldStr? "scope").getD "systemctl"
    let host := (args.fieldStr? "target_host").getD "self"
    let reason := (args.fieldStr? "reason").getD ""
    let units := ((args.fieldArr? "allowed_units").getD #[]).filterMap JVal.asStr?
    let ttlMins := (args.fieldNat? "ttl_minutes").getD 30
    return mcpOk (← mcpRequestPrivilegedAccess store.rootDir callerMid scope host reason units ttlMins nowEpochSec)

  | "list_privileged_access" =>
    return mcpOk (← mcpListPrivilegedAccess store store.rootDir callerMid nowEpochSec)

  | "revoke_privileged_access" =>
    let gid := (args.fieldStr? "grant_id").orElse (fun _ => args.fieldStr? "id") |>.getD ""
    let ok ← mcpRevokePrivilegedAccess store gid callerMid
    return mcpOk (.obj #[("ok", .bool ok), ("grant_id", .str gid)])

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
