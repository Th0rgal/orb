/-
  OrbCore.MachineTransfer: Full v1 Machine Transfer Lifecycle (`GET/POST /api/control/missions/:id/machine-transfer`).
  - Matches `orb/src/machineTransfer.ts` and `orb/src/ChangeMachine.tsx` (`TransferView` v1,
    `TransferAction`, `Destination`, `Machine`).
  - Reuses `OrbCore.Store.startMachineTransfer` (`verifyTransferFence` in `OrbCore.Spec`),
    `OrbNode.Transfer.operateTransfer` (for Core-hosted workspaces), and
    `OrbCore.RemoteDispatch.callRemoteNodeHttpOpt` (for static & `managed-*` remote nodes).
  - Unblocks moving missions between static nodes, `managed-*` VMs, Core, and `client` (`This computer`).
  (`0 import Lean`, `0 sorryAx`).
-/
import LeanSys.Auth
import OrbBin.Json
import OrbBin.PosixExt
import OrbNode.Transfer
import OrbCore.Store
import OrbCore.Managed
import OrbCore.RemoteFleetAndRelay
import OrbCore.RemoteDispatch

namespace OrbCore.MachineTransfer

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.Managed
open OrbCore.RemoteFleetAndRelay
open OrbCore.RemoteDispatch

/-- Machine endpoint in the v1 machine-transfer protocol (`Machine` in `orb/src/machineTransfer.ts`). -/
inductive MachineTarget where
  | core
  | node (id : String)
  | client (id : String)
  deriving Repr, BEq

def MachineTarget.kindStr : MachineTarget → String
  | .core => "core"
  | .node _ => "node"
  | .client _ => "client"

def MachineTarget.idStr : MachineTarget → String
  | .core => ""
  | .node id => id
  | .client id => id

def MachineTarget.toJson : MachineTarget → JVal
  | .core => .obj #[("kind", .str "core")]
  | .node id => .obj #[("kind", .str "node"), ("id", .str id)]
  | .client id => .obj #[("kind", .str "client"), ("id", .str id)]

def MachineTarget.fromJson? (jv : JVal) (fallbackClientId : String := "unknown") : Option MachineTarget :=
  match jv with
  | .str s =>
    let clean := s.trimAscii.toString
    if clean.isEmpty || clean == "core" || clean == "local" then some .core
    else if clean == "client" then some (.client fallbackClientId)
    else some (.node clean)
  | .obj _ =>
    match (jv.fieldStr? "kind").map (·.trimAscii.toString) with
    | some "core" => some .core
    | some "node" =>
      let nid := ((jv.fieldStr? "id").getD "").trimAscii.toString
      if nid.isEmpty then none else some (.node nid)
    | some "client" =>
      let cid := ((jv.fieldStr? "id").getD fallbackClientId).trimAscii.toString
      some (.client (if cid.isEmpty then fallbackClientId else cid))
    | _ => none
  | _ => none

def MachineTarget.label : MachineTarget → String
  | .core => "Core"
  | .client _ => "This computer"
  | .node id => id

/-- Relative workspace path for the Core-owned conversation transcript archive. -/
def conversationRelPath (transferId : String) : String :=
  s!".paloma/transfers/{transferId}/conversation.txt"

private def defaultTransferHarnesses : Array String :=
  #["opencode", "claudecode", "codex", "antigravity"]

private def extractRemoteNodeFromTags (tagsJson : String) : Option String :=
  let tags := parseStringJsonArray tagsJson
  let raw? :=
    (tags.find? (·.startsWith "remote-node:")).map (fun t => (t.drop 12).toString)
      |>.orElse (fun _ => (tags.find? (·.startsWith "remote_node:")).map (fun t => (t.drop 12).toString))
  raw?.map (·.trimAscii.toString) |>.filter fun s =>
    !s.isEmpty && s != "core" && s != "local" && s != "client"

private def extractSourceTransferFromWorkDir (workDir : String) : Option String :=
  let parts := (workDir.splitOn "/.transfers/").toArray
  if parts.size < 2 then none
  else
    let tail := parts[parts.size - 1]!
    let segs := tail.splitOn "/"
    match segs with
    | tid :: "destination" :: _ => parseUuidCanonical? tid
    | _ => none

private structure MissionTransferInfo where
  id               : String
  title            : String
  status           : String
  backend          : String
  modelOverride    : String
  modelEffort      : String
  workingDirectory : String
  placementKind    : String
  tagsJson         : String
  updatedAt        : String
  ownerUserId      : String

private def loadMissionTransferInfo? (store : CoreStore) (missionId : String) : IO (Option MissionTransferInfo) := do
  match ← execParamQuery store.missionsDb
      ("SELECT id, COALESCE(title,''), COALESCE(status,'awaiting_user'), COALESCE(backend,'codex'), " ++
       "COALESCE(model_override,''), COALESCE(model_effort,''), COALESCE(working_directory,''), " ++
       "COALESCE(placement_kind,'managed'), COALESCE(tags,'[]'), COALESCE(updated_at,''), COALESCE(owner_user_id,'') " ++
       "FROM missions WHERE id=?1;") #[missionId] with
  | .error _ => return none
  | .ok rows =>
    if rows.size ≤ 1 then return none
    let r := rows[1]!
    return some {
      id               := cell r 0
      title            := cell r 1
      status           := cell r 2
      backend          := cell r 3
      modelOverride    := cell r 4
      modelEffort      := cell r 5
      workingDirectory := cell r 6
      placementKind    := cell r 7
      tagsJson         := cell r 8
      updatedAt        := cell r 9
      ownerUserId      := cell r 10
    }

private def loadMaxMissionGeneration (store : CoreStore) (missionId : String) : IO UInt64 := do
  match ← execParamQuery store.missionsDb
      "SELECT COALESCE(MAX(generation),0) FROM mission_runs WHERE mission_id=?1;" #[missionId] with
  | .ok rows =>
    if rows.size > 1 then
      return ((cell rows[1]! 0).toNat?.getD 0).toUInt64
    return 0
  | .error _ => return 0

/-- Build the archived conversation transcript bytes served as `.paloma/transfers/<tid>/conversation.txt`. -/
def buildConversationArchiveBytes (store : CoreStore) (missionId : String) : IO ByteArray := do
  let title := match ← loadMissionTransferInfo? store missionId with
    | some info => info.title
    | none => ""
  let mut lines : Array String := #[
    s!"# Mission {missionId}",
    if title.isEmpty then "# Archived Conversation" else s!"# Title: {title}",
    ""
  ]
  match ← execParamQuery store.missionsDb
      ("SELECT event_type, COALESCE(payload,''), COALESCE(content,''), COALESCE(NULLIF(created_at,''),timestamp,'') " ++
       "FROM mission_events WHERE mission_id=?1 " ++
       "AND event_type IN ('user_message','assistant_message') " ++
       "ORDER BY id ASC LIMIT 200;") #[missionId] with
  | .ok rows =>
    for i in [1:rows.size] do
      let r := rows[i]!
      let evType := cell r 0
      let payload := cell r 1
      let fallback := cell r 2
      let ts := cell r 3
      let text :=
        (((OrbBin.Json.parse payload).toOption.bind fun j =>
            (j.fieldStr? "content").orElse (fun _ => j.fieldStr? "text")).getD fallback).trimAscii.toString
      if !text.isEmpty then
        let role := if evType == "assistant_message" then "Assistant" else "User"
        let hdr := if ts.isEmpty then s!"## {role}" else s!"## {role} ({ts})"
        lines := lines.push hdr
        lines := lines.push text
        lines := lines.push ""
  | .error _ => pure ()
  return (String.intercalate "\n" lines.toList ++ "\n").toUTF8

/-- Construct a single-file manifest containing only the archived conversation (for `light: true`). -/
def buildConversationOnlyManifest (transferId : String) (convBytes : ByteArray) : JVal :=
  let convSha := bytesToHexLower (sha256Bytes convBytes)
  let sz := convBytes.size.toUInt64
  .obj #[
    ("files", .arr #[.obj #[
      ("path", .str (conversationRelPath transferId)),
      ("bytes", JVal.uint64 sz),
      ("sha256", .str convSha),
      ("executable", .bool false)
    ]]),
    ("excluded", .arr #[]),
    ("bytes", JVal.uint64 sz),
    ("links", .arr #[]),
    ("skipped", .arr #[])
  ]

/-- Merge Core's `.paloma/transfers/<tid>/conversation.txt` entry into a workspace `Manifest`. -/
def mergeConversationIntoManifest (manifest : JVal) (transferId : String) (convBytes : ByteArray) : JVal :=
  let relPath := conversationRelPath transferId
  let convSha := bytesToHexLower (sha256Bytes convBytes)
  let convSz := convBytes.size.toUInt64
  let curFiles := (manifest.fieldArr? "files").getD #[]
  let alreadyHas := curFiles.any (fun f => f.fieldStr? "path" == some relPath)
  if alreadyHas then manifest
  else
    let convEntry := JVal.obj #[
      ("path", .str relPath),
      ("bytes", JVal.uint64 convSz),
      ("sha256", .str convSha),
      ("executable", .bool false)
    ]
    let nextFiles := curFiles.push convEntry
    let prevBytes := (manifest.fieldUInt64? "bytes").getD 0
    let nextBytes := prevBytes + convSz
    let baseFields : Array (String × JVal) := match manifest with
      | .obj fs => fs.filter (fun p => p.1 != "files" && p.1 != "bytes")
      | _ => #[("excluded", .arr #[])]
    .obj ((baseFields.push ("files", .arr nextFiles)).push ("bytes", JVal.uint64 nextBytes))

private def upgradeActionRow (id phase dataStr createdAt missionId : String) : JVal :=
  match OrbBin.Json.parse dataStr with
  | .ok (.obj fs) =>
    let hasSource := fs.any (fun p => p.1 == "source")
    let hasDestObj := (fs.find? (fun p => p.1 == "destination")).bind (fun p => p.2.asObj?) |>.isSome
    if hasSource && hasDestObj then
      let cleaned := fs.filter (fun p => p.1 != "phase")
      .obj (cleaned.push ("phase", .str phase))
    else
      let destVal := match (fs.find? (fun p => p.1 == "destination")).map Prod.snd with
        | some jv => (MachineTarget.fromJson? jv).getD .core |>.toJson
        | none => MachineTarget.core.toJson
      .obj #[
        ("id", .str id),
        ("mission_id", .str missionId),
        ("phase", .str phase),
        ("light", .bool false),
        ("source", MachineTarget.core.toJson),
        ("destination", destVal),
        ("backend", .str "codex"),
        ("model", .null),
        ("effort", .null),
        ("source_root", .null),
        ("destination_root", .null),
        ("manifest", .null),
        ("receipt", .null),
        ("created_at", .str createdAt)
      ]
  | _ =>
    .obj #[
      ("id", .str id),
      ("mission_id", .str missionId),
      ("phase", .str phase),
      ("light", .bool false),
      ("source", MachineTarget.core.toJson),
      ("destination", MachineTarget.core.toJson),
      ("backend", .str "codex"),
      ("model", .null),
      ("effort", .null),
      ("source_root", .null),
      ("destination_root", .null),
      ("manifest", .null),
      ("receipt", .null),
      ("created_at", .str createdAt)
    ]

/-- Load all recorded transfer actions for `missionId` in chronological order. -/
def loadTransferActions (store : CoreStore) (missionId : String) : IO (Array JVal) := do
  match ← execParamQuery store.missionsDb
      "SELECT id, phase, COALESCE(data,'{}'), COALESCE(created_at,'') FROM machine_transfers WHERE mission_id=?1 ORDER BY created_at ASC, rowid ASC;"
      #[missionId] with
  | .error _ => return #[]
  | .ok rows =>
    let mut out : Array JVal := #[]
    for i in [1:rows.size] do
      let r := rows[i]!
      out := out.push (upgradeActionRow (cell r 0) (cell r 1) (cell r 2) (cell r 3) missionId)
    return out

private def loadTransferActionById? (store : CoreStore) (missionId transferId : String) : IO (Option JVal) := do
  match ← execParamQuery store.missionsDb
      "SELECT id, phase, COALESCE(data,'{}'), COALESCE(created_at,'') FROM machine_transfers WHERE mission_id=?1 AND id=?2;"
      #[missionId, transferId] with
  | .error _ => return none
  | .ok rows =>
    if rows.size ≤ 1 then return none
    let r := rows[1]!
    return some (upgradeActionRow (cell r 0) (cell r 1) (cell r 2) (cell r 3) missionId)

private def loadActiveTransferByRequestKey? (store : CoreStore) (missionId reqKey : String) : IO (Option JVal) := do
  if reqKey.isEmpty then return none
  match ← execParamQuery store.missionsDb
      "SELECT id, phase, COALESCE(data,'{}'), COALESCE(created_at,'') FROM machine_transfers WHERE mission_id=?1 AND request_key=?2 AND phase<>'cancelled' ORDER BY rowid DESC LIMIT 1;"
      #[missionId, reqKey] with
  | .error _ => return none
  | .ok rows =>
    if rows.size ≤ 1 then return none
    let r := rows[1]!
    return some (upgradeActionRow (cell r 0) (cell r 1) (cell r 2) (cell r 3) missionId)

private def saveTransferAction (store : CoreStore) (transferId phase : String) (actionJv : JVal) : IO (Except String Unit) := do
  let res ← execParamQuery store.missionsDb
    "UPDATE machine_transfers SET phase=?2, data=?3, revision=revision+1 WHERE id=?1;"
    #[transferId, phase, renderCompact actionJv]
  return res.map (fun _ => ())

private def setActionField (actionJv : JVal) (key : String) (val : JVal) : JVal :=
  match actionJv with
  | .obj fs => .obj ((fs.filter (fun p => p.1 != key)).push (key, val))
  | _ => actionJv

private def resolveMissionSourceMachine (info : MissionTransferInfo) (actions : Array JVal) : MachineTarget :=
  if info.placementKind == "client" then
    let lastClientId? := actions.foldl (fun acc act =>
      if act.fieldStr? "phase" == some "activated" then
        match act.field? "destination" >>= MachineTarget.fromJson? with
        | some (.client cid) => if !cid.isEmpty && cid != "unknown" then some cid else acc
        | _ => acc
      else acc) none
    .client (lastClientId?.getD "unknown")
  else if let some rn := extractRemoteNodeFromTags info.tagsJson then
    .node rn
  else
    .core

private def isStaticNodeAdminOnly (n : StaticRemoteNode) : Bool :=
  n.id.endsWith "-core" || n.id.endsWith "-admin" ||
  n.labels.any (fun l => l == "admin-only" || l == "admin_only")

/-- Build the `destinations` array for `GET /api/control/missions/:id/machine-transfer`. -/
def buildTransferDestinations
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (callerUserId? : Option String)
    (isAdmin : Bool)
    (nowSec : UInt64) : IO (Array JVal) := do
  let mut dests : Array JVal := #[]
  if isAdmin then
    dests := dests.push (.obj #[
      ("machine", MachineTarget.core.toJson),
      ("label", .str "Core"),
      ("available", .bool true),
      ("harnesses", .arr (defaultTransferHarnesses.map .str))
    ])
  let (_, staticNodes) ← loadStaticRemoteNodes
  for n in staticNodes do
    let allowed :=
      if isAdmin then true
      else if isStaticNodeAdminOnly n then false
      else match n.dedicatedOwner? with
        | none => true
        | some owner => callerUserId? == some owner
    if allowed then
      dests := dests.push (.obj #[
        ("machine", (MachineTarget.node n.id).toJson),
        ("label", .str n.id),
        ("available", .bool true),
        ("harnesses", .arr (defaultTransferHarnesses.map .str))
      ])
  if let some mc := mc? then
    let machines : Array ManagedMachine ← match ← loadManagedFleetAt mc true true 0 0 0 nowSec with
      | .ok fleet => pure fleet.machines
      | .error _ => pure #[]
    let visible := match callerUserId? with
      | none => machines
      | some uid => machines.filter (fun m => m.ownerUserId == uid)
    for m in visible do
      let isActiveVm :=
        (m.status == "ready" || m.status == "running" || m.status == "provisioning") &&
        (m.expiresAtSec == (0 : UInt64) || m.expiresAtSec > nowSec)
      if isActiveVm then
        let hubSeen? ← match relayHub? with
          | some h => getMachineLastSeen? h m.id
          | none => pure none
        let seenSec? := NodeLiveness.lastSeen hubSeen? m.lastPollSec
        let nodeStatus := NodeLiveness.managedStatus m.status seenSec? nowSec
        let avail := !m.cordoned && (m.status == "ready" || m.status == "running")
        let ownerKind :=
          if !m.ownerMission.isEmpty then "mission"
          else if m.ownerKind.isEmpty then "user"
          else m.ownerKind
        let lbl := if m.sandboxName.trimAscii.toString.isEmpty then s!"managed-{m.id}" else m.sandboxName
        let base : Array (String × JVal) := #[
          ("machine", (MachineTarget.node s!"managed-{m.id}").toJson),
          ("label", .str lbl),
          ("available", .bool avail),
          ("harnesses", .arr (defaultTransferHarnesses.map .str)),
          ("owner_kind", .str ownerKind)
        ]
        let fields :=
          if avail then base
          else base.push ("reason", .str (if m.cordoned then "Machine is cordoned" else s!"Machine is {nodeStatus}"))
        dests := dests.push (.obj fields)
  return dests

/-- Authorize a caller to target `dest` for a machine transfer. Returns `some (code, body)` if denied. -/
private def authorizeTransferDestination
    (mc? : Option ManagedComputeStore)
    (callerUserId : String)
    (isAdmin : Bool)
    (dest : MachineTarget) : IO (Option (Nat × String)) := do
  match dest with
  | .client _ => return none
  | .core =>
    if isAdmin then return none
    else return some (403, "{\"error\":\"admin_required_for_core_placement\"}")
  | .node nodeId =>
    if isAdmin then return none
    if nodeId.startsWith "managed-" then
      let some mc := mc? | return some (403, "{\"error\":\"managed_machine_unavailable\"}")
      let mid := (nodeId.drop 8).toString
      match ← getManagedMachine? mc mid with
      | some (m, _) =>
        if !callerUserId.isEmpty && m.ownerUserId == callerUserId then return none
        else return some (403, "{\"error\":\"managed_machine_owner_required\"}")
      | none => return some (404, "{\"error\":\"managed_machine_not_found\"}")
    else
      let (_, staticNodes) ← loadStaticRemoteNodes
      match staticNodes.find? (·.id == nodeId) with
      | none => return none
      | some sn =>
        if isStaticNodeAdminOnly sn then return some (403, "{\"error\":\"admin_required_for_node\"}")
        match sn.dedicatedOwner? with
        | some owner =>
          if owner == callerUserId then return none
          else return some (403, "{\"error\":\"node_owner_required\"}")
        | none => return none

/-- Handle `GET /api/control/missions/:id/machine-transfer` returning v1 `TransferView`. -/
def handleMachineTransferGet
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (missionId : String)
    (callerUserId? : Option String)
    (isAdmin : Bool)
    (nowSec : UInt64) : IO (Nat × String) := do
  let some info ← loadMissionTransferInfo? store missionId
    | return (404, "{\"error\":\"mission_not_found\"}")
  let actions ← loadTransferActions store missionId
  let source := resolveMissionSourceMachine info actions
  let dests ← buildTransferDestinations mc? relayHub? callerUserId? isAdmin nowSec
  let view := JVal.obj #[
    ("version", .nat 1),
    ("source", source.toJson),
    ("features", .arr #[.str "links", .str "selection"]),
    ("actions", .arr actions),
    ("destinations", .arr dests)
  ]
  return (200, renderCompact view)

private def executeSideTransferOp
    (relayHub? : Option RelayHub)
    (mc? : Option ManagedComputeStore)
    (coreWorkDir missionId transferId side : String)
    (target : MachineTarget)
    (missionWorkDir : String)
    (operation : JVal) : IO (Except (Nat × String) JVal) := do
  match target with
  | .client _ =>
    return .error (400, "Client-side transfer operations must run on the client")
  | .core =>
    let area := System.FilePath.mk coreWorkDir / ".transfers" / transferId / side
    let srcDir :=
      if missionWorkDir.trimAscii.toString.isEmpty then
        System.FilePath.mk coreWorkDir / missionId
      else System.FilePath.mk missionWorkDir
    let opName := (operation.fieldStr? "op").getD ""
    if side == "source" && (opName == "inventory" || opName == "snapshot") then
      if !(← srcDir.pathExists) then
        discard <| (IO.FS.createDirAll srcDir).toBaseIO
    match ← OrbNode.Transfer.operateTransfer area (some srcDir) operation with
    | .ok res => return .ok res
    | .error msg => return .error (409, msg)
  | .node nodeId =>
    let mut bodyFields : Array (String × JVal) := #[
      ("mission_id", .str missionId),
      ("transfer_id", .str transferId),
      ("side", .str side),
      ("operation", operation)
    ]
    if side == "source" then
      if let some prevTid := extractSourceTransferFromWorkDir missionWorkDir then
        bodyFields := bodyFields.push ("source_transfer", .str prevTid)
    match ← callRemoteNodeHttpOpt relayHub? mc? nodeId "POST" "/machine-transfer/files" (some (.obj bodyFields)) #[] 60000 with
    | .error e => return .error (502, s!"Remote node {nodeId} transfer failed: {e}")
    | .ok (code, respBody, _, _, _) =>
      if code < 200 || code ≥ 300 then
        let errMsg :=
          match OrbBin.Json.parse respBody with
          | .ok jv => (jv.fieldStr? "error").getD (if respBody.trimAscii.isEmpty then s!"Remote node HTTP {code}" else respBody)
          | .error _ => if respBody.trimAscii.isEmpty then s!"Remote node HTTP {code}" else respBody
        return .error (if code == 409 || code == 400 || code == 422 then code else 502, errMsg)
      match OrbBin.Json.parse respBody with
      | .ok jv => return .ok jv
      | .error _ => return .error (502, "Remote node returned invalid JSON for transfer operation")

/-- Handle `POST /api/control/missions/:id/machine-transfer` for all v1 lifecycle operations:
    `prepare`, `files`, `client_snapshot`, `client_verified`, `bulk_copy`, `activate`, `cancel`. -/
def handleMachineTransferPost
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (coreWorkDir missionId : String)
    (callerUserId : String)
    (isAdmin : Bool)
    (rawBody : ByteArray)
    (nowIso : String) : IO (Nat × String) := do
  let .ok jv := OrbBin.Json.parseBytes rawBody
    | return (400, "{\"error\":\"invalid_json\"}")
  let some info ← loadMissionTransferInfo? store missionId
    | return (404, "{\"error\":\"mission_not_found\"}")
  let op := ((jv.fieldStr? "op").getD "").trimAscii.toString

  -- 1. `prepare`
  if op == "prepare" then
    let clientId := ((jv.fieldStr? "client_id").getD "unknown").trimAscii.toString
    let some destVal := jv.field? "destination"
      | return (400, "{\"error\":\"missing_destination\"}")
    let some dest := MachineTarget.fromJson? destVal clientId
      | return (400, "{\"error\":\"invalid_destination\"}")
    if let some denied ← authorizeTransferDestination mc? callerUserId isAdmin dest then
      return denied
    let reqKey :=
      (((jv.fieldStr? "idempotency_key").orElse (fun _ => jv.fieldStr? "request_key")).getD "").trimAscii.toString
    if let some existing ← loadActiveTransferByRequestKey? store missionId reqKey then
      return (200, renderCompact existing)
    let actions ← loadTransferActions store missionId
    let rawSource := resolveMissionSourceMachine info actions
    let source : MachineTarget := match rawSource with
      | .client "unknown" => if !clientId.isEmpty && clientId != "unknown" then MachineTarget.client clientId else rawSource
      | other => other
    let light := (jv.fieldBool? "light").getD false
    let reqBackend := ((jv.fieldStr? "backend").getD "").trimAscii.toString
    let effBackend := if reqBackend.isEmpty then info.backend else reqBackend
    let reqModel := ((jv.fieldStr? "model").getD "").trimAscii.toString
    let effModel? : Option String := if reqModel.isEmpty then (if info.modelOverride.isEmpty then none else some info.modelOverride) else some reqModel
    let reqEffort? := (jv.fieldStr? "effort").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    let clientRoot? := (jv.fieldStr? "client_root").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    let txId ← newUuidV4
    let effReqKey := if reqKey.isEmpty then s!"rk-{txId}" else reqKey
    let maxGen ← loadMaxMissionGeneration store missionId
    let txRec : TransferRecord := {
      id := txId, missionId := missionId, requestKey := effReqKey, revision := 0,
      phase := if light then "snapshotted" else "preparing",
      destination := dest.kindStr ++ (if dest.idStr.isEmpty then "" else ":" ++ dest.idStr),
      sourceRevision := info.updatedAt,
      sourceGeneration := maxGen,
      generation := 0,
      createdAt := nowIso
    }
    match ← startMachineTransfer store txRec with
    | .error e => return (409, renderCompact (.obj #[("error", .str e)]))
    | .ok started =>
      let manifestVal ←
        if light then
          let convBytes ← buildConversationArchiveBytes store missionId
          pure (buildConversationOnlyManifest started.id convBytes)
        else pure .null
      let srcRootVal : JVal :=
        match source with
        | .client _ => match clientRoot? with | some r => .str r | none => .null
        | _ => if info.workingDirectory.isEmpty then .null else .str info.workingDirectory
      let phaseStr := if light then "snapshotted" else "preparing"
      let actionJv := JVal.obj #[
        ("id", .str started.id),
        ("mission_id", .str missionId),
        ("phase", .str phaseStr),
        ("light", .bool light),
        ("source", source.toJson),
        ("destination", dest.toJson),
        ("backend", .str effBackend),
        ("model", match effModel? with | some m => .str m | none => .null),
        ("effort", match reqEffort? with | some e => .str e | none => .null),
        ("source_root", srcRootVal),
        ("destination_root", .null),
        ("manifest", manifestVal),
        ("receipt", .null),
        ("generation", JVal.uint64 started.generation),
        ("created_at", .str nowIso)
      ]
      let _ ← saveTransferAction store started.id phaseStr actionJv
      return (200, renderCompact actionJv)

  -- 2. `files`
  if op == "files" then
    let transferId := ((jv.fieldStr? "transfer_id").getD "").trimAscii.toString
    let side := ((jv.fieldStr? "side").getD "").trimAscii.toString
    let some operation := jv.field? "operation"
      | return (400, "{\"error\":\"missing_operation\"}")
    if side != "source" && side != "destination" then
      return (400, "{\"error\":\"invalid_side\"}")
    let some actionJv ← loadTransferActionById? store missionId transferId
      | return (404, "{\"error\":\"transfer_not_found\"}")
    let phase := (actionJv.fieldStr? "phase").getD ""
    if phase == "activated" || phase == "cancelled" then
      return (409, s!"\{\"error\":\"Transfer is already {phase}\"}")
    let opName := ((operation.fieldStr? "op").getD "").trimAscii.toString
    -- Core always serves `.paloma/transfers/<tid>/conversation.txt` on `source` `read`.
    if side == "source" && opName == "read" && operation.fieldStr? "path" == some (conversationRelPath transferId) then
      let convBytes ← buildConversationArchiveBytes store missionId
      let offset := ((operation.fieldUInt64? "offset").getD 0).toNat
      if offset > convBytes.size then
        return (409, "{\"error\":\"Read offset out of range\"}")
      let endIdx := min convBytes.size (offset + OrbNode.Transfer.transferBlockBytes)
      let slice := convBytes.extract offset endIdx
      let b64 := base64Encode slice false true
      return (200, renderCompact (.obj #[("data", .str b64)]))
    let some targetJv := actionJv.field? side
      | return (400, "{\"error\":\"missing_transfer_endpoint\"}")
    let some target := MachineTarget.fromJson? targetJv
      | return (400, "{\"error\":\"invalid_transfer_endpoint\"}")
    match ← executeSideTransferOp relayHub? mc? coreWorkDir missionId transferId side target info.workingDirectory operation with
    | .error (code, msg) => return (code, renderCompact (.obj #[("error", .str msg)]))
    | .ok resJv =>
      if side == "source" && opName == "snapshot" then
        let convBytes ← buildConversationArchiveBytes store missionId
        let merged := mergeConversationIntoManifest resJv transferId convBytes
        let nextAct := setActionField (setActionField actionJv "manifest" merged) "phase" (.str "snapshotted")
        let _ ← saveTransferAction store transferId "snapshotted" nextAct
        return (200, renderCompact nextAct)
      else if side == "destination" && opName == "verify" then
        let destRoot := ((resJv.fieldStr? "root").getD "").trimAscii.toString
        let nextAct :=
          setActionField
            (setActionField
              (setActionField actionJv "receipt" resJv)
              "destination_root" (if destRoot.isEmpty then .null else .str destRoot))
            "phase" (.str "verified")
        let _ ← saveTransferAction store transferId "verified" nextAct
        return (200, renderCompact nextAct)
      else
        return (200, renderCompact resJv)

  -- 3. `client_snapshot`
  if op == "client_snapshot" then
    let transferId := ((jv.fieldStr? "transfer_id").getD "").trimAscii.toString
    let some manifest := jv.field? "manifest"
      | return (400, "{\"error\":\"missing_manifest\"}")
    let rootStr := ((jv.fieldStr? "root").getD "").trimAscii.toString
    let some actionJv ← loadTransferActionById? store missionId transferId
      | return (404, "{\"error\":\"transfer_not_found\"}")
    let phase := (actionJv.fieldStr? "phase").getD ""
    if phase == "activated" || phase == "cancelled" then
      return (409, s!"\{\"error\":\"Transfer is already {phase}\"}")
    let srcTarget := (actionJv.field? "source").bind MachineTarget.fromJson?
    if (srcTarget.map MachineTarget.kindStr) != some "client" then
      return (409, "{\"error\":\"Transfer source is not a client\"}")
    let convBytes ← buildConversationArchiveBytes store missionId
    let merged := mergeConversationIntoManifest manifest transferId convBytes
    let nextAct :=
      setActionField
        (setActionField
          (setActionField actionJv "manifest" merged)
          "source_root" (if rootStr.isEmpty then .null else .str rootStr))
        "phase" (.str "snapshotted")
    let _ ← saveTransferAction store transferId "snapshotted" nextAct
    return (200, renderCompact nextAct)

  -- 4. `client_verified`
  if op == "client_verified" then
    let transferId := ((jv.fieldStr? "transfer_id").getD "").trimAscii.toString
    let some receipt := jv.field? "receipt"
      | return (400, "{\"error\":\"missing_receipt\"}")
    let some actionJv ← loadTransferActionById? store missionId transferId
      | return (404, "{\"error\":\"transfer_not_found\"}")
    let phase := (actionJv.fieldStr? "phase").getD ""
    if phase == "activated" || phase == "cancelled" then
      return (409, s!"\{\"error\":\"Transfer is already {phase}\"}")
    let dstTarget := (actionJv.field? "destination").bind MachineTarget.fromJson?
    if (dstTarget.map MachineTarget.kindStr) != some "client" then
      return (409, "{\"error\":\"Transfer destination is not a client\"}")
    let destRoot := ((receipt.fieldStr? "root").getD "").trimAscii.toString
    let nextAct :=
      setActionField
        (setActionField
          (setActionField actionJv "receipt" receipt)
          "destination_root" (if destRoot.isEmpty then .null else .str destRoot))
        "phase" (.str "verified")
    let _ ← saveTransferAction store transferId "verified" nextAct
    return (200, renderCompact nextAct)

  -- 5. `bulk_copy` (per-file copy is always available; explicit refusal triggers clean UI fallback)
  if op == "bulk_copy" then
    return (409, "{\"error\":\"bulk_copy_unavailable\"}")

  -- 6. `activate`
  if op == "activate" then
    let transferId := ((jv.fieldStr? "transfer_id").getD "").trimAscii.toString
    let some actionJv ← loadTransferActionById? store missionId transferId
      | return (404, "{\"error\":\"transfer_not_found\"}")
    let phase := (actionJv.fieldStr? "phase").getD ""
    if phase == "activated" then
      return (200, renderCompact actionJv)
    if phase == "cancelled" then
      return (409, "{\"error\":\"Transfer was cancelled\"}")
    if phase != "verified" then
      return (409, "{\"error\":\"Destination workspace must be verified before activation\"}")
    let some destTarget := (actionJv.field? "destination").bind MachineTarget.fromJson?
      | return (400, "{\"error\":\"invalid_transfer_destination\"}")
    if let some denied ← authorizeTransferDestination mc? callerUserId isAdmin destTarget then
      return denied
    let destRoot := ((actionJv.fieldStr? "destination_root").getD "").trimAscii.toString
    let newBackend := ((actionJv.fieldStr? "backend").getD info.backend).trimAscii.toString
    let newModel := ((actionJv.fieldStr? "model").getD "").trimAscii.toString
    let newEffort := ((actionJv.fieldStr? "effort").getD "").trimAscii.toString
    let oldTags := parseStringJsonArray info.tagsJson
    let cleanTags := oldTags.filter (fun t => !(t.startsWith "remote-node:") && !(t.startsWith "remote_node:"))
    let (newPlaceKind, newTags) :=
      match destTarget with
      | .client _ => ("client", cleanTags)
      | .core => ("core", cleanTags)
      | .node nid =>
        let pk := if nid.startsWith "managed-" then "managed_vm" else "remote"
        (pk, cleanTags.push s!"remote-node:{nid}")
    let newTagsJson := renderCompact (.arr (newTags.map JVal.str))
    let effWorkDir := if destRoot.isEmpty then info.workingDirectory else destRoot
    let activatedJv := setActionField actionJv "phase" (.str "activated")
    let txRes ← withImmediateTx store.missionsDb do
      let u1 ← execParamQueryUnlocked store.missionsDb
        ("UPDATE missions SET placement_kind=?2, tags=?3, working_directory=?4, backend=?5, " ++
         "model_override=?6, model_effort=?7, session_id='', placement_revision=COALESCE(placement_revision,0)+1, " ++
         "updated_at=?8, metadata_updated_at=?8 WHERE id=?1;")
        #[missionId, newPlaceKind, newTagsJson, effWorkDir, newBackend, newModel, newEffort, nowIso]
      let .ok _ := u1 | return .error "mission_placement_update_failed"
      let u2 ← execParamQueryUnlocked store.missionsDb
        "UPDATE machine_transfers SET phase='activated', data=?2, revision=revision+1 WHERE id=?1;"
        #[transferId, renderCompact activatedJv]
      let .ok _ := u2 | return .error "transfer_activate_update_failed"
      return .ok ()
    match txRes with
    | .error e => return (500, renderCompact (.obj #[("error", .str e)]))
    | .ok () => return (200, renderCompact activatedJv)

  -- 7. `cancel`
  if op == "cancel" then
    let transferId := ((jv.fieldStr? "transfer_id").getD "").trimAscii.toString
    let some actionJv ← loadTransferActionById? store missionId transferId
      | return (404, "{\"error\":\"transfer_not_found\"}")
    let phase := (actionJv.fieldStr? "phase").getD ""
    if phase == "activated" then
      return (409, "{\"error\":\"Cannot cancel an already activated transfer\"}")
    if phase == "cancelled" then
      return (200, renderCompact actionJv)
    let cancelledJv := setActionField actionJv "phase" (.str "cancelled")
    let _ ← saveTransferAction store transferId "cancelled" cancelledJv
    return (200, renderCompact cancelledJv)

  return (400, renderCompact (.obj #[("error", .str s!"unsupported_machine_transfer_op:{op}")]))

end OrbCore.MachineTransfer
