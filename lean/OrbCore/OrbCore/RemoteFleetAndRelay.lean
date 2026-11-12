/-
  OrbCore.RemoteFleetAndRelay:
  1. Reverse Long-Poll HTTP Tunnel Hub (`RelayHub`) wire-compatible with `OrbNode.Dial` (`sandboxed-node` on Boat VMs)
     and `ManagedComputeStore` (`managed_node_tokens`).
  2. Static Remote Nodes (`SANDBOXED_REMOTE_NODES` / `SANDBOXED_REMOTE_NODES_ENABLED`) + HMAC-SHA256 `LeaseClaims`
     minting (`mission:execute`, `job:submit`, `job:force`, `node:capacity`) compatible with `OrbNode.Lease`.
  3. Unified Remote Node HTTP Client (direct HTTP/HTTPS for static nodes, `RelayHub` HTTP tunnel for `managed-*` VMs).
  4. `GET /api/compute/fleet`, enriched `GET /api/remote-nodes`, Boat API (`https://boat.dev/api/v1`) lifecycle,
     `/api/managed-machines/{settings,providers*,snapshots*,:id*,bootstrap-binary/:id,relay/tunnel/:id/*}`,
     `/api/nodes/:name/{cordon,uncordon,capacity}`, and `/api/durable-jobs*`.
  (`0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import LeanSys.Auth
import LeanSys.Http
import OrbNetLeaf.Crypto
import OrbNetLeaf.TlsHttp
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.HttpClient
import OrbCore.Store
import OrbCore.Managed
import OrbCore.R7Core
import OrbCore.LegacyHydrate

namespace OrbCore.RemoteFleetAndRelay

open LeanSys.Auth
open LeanSys.Http
open OrbNetLeaf.Crypto
open OrbNetLeaf.TlsHttp
open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.HttpClient
open OrbCore.Store
open OrbCore.Managed
open OrbCore.R7Core
open OrbCore.LegacyHydrate

/-! ## Reverse Long-Poll HTTP Tunnel Hub (`RelayHub`) -/

structure RelayHttpReq where
  id          : String
  machineId   : String
  method      : String
  path        : String
  headers     : Array (String × String)
  bodyB64     : String
  timeoutSecs : Nat := 30
  createdSec  : UInt64 := 0
  deriving Repr, Inhabited

structure RelayHttpResp where
  id      : String
  status  : Nat
  headers : Array (String × String)
  bodyB64 : String
  deriving Repr, Inhabited

structure RelayHubState where
  pendingByMachine : Array (String × Array RelayHttpReq) := #[]
  completedById    : Array (String × RelayHttpResp) := #[]
  lastSeenSec      : Array (String × UInt64) := #[]

structure RelayHub where
  mu         : Std.Mutex RelayHubState
  longPollMs : Nat := 0

def newRelayHub (longPollMs : Nat := 0) : IO RelayHub := do
  let mu ← Std.Mutex.new ({} : RelayHubState)
  return { mu, longPollMs }

def recordMachinePollSeen (hub : RelayHub) (machineId : String) (nowSec : UInt64) : IO Unit :=
  hub.mu.atomically do
    let st ← get
    let filtered := st.lastSeenSec.filter (fun (m, _) => m != machineId)
    set { st with lastSeenSec := filtered.push (machineId, nowSec) }

def getMachineLastSeen? (hub : RelayHub) (machineId : String) : IO (Option UInt64) :=
  hub.mu.atomically do
    let st ← get
    return (st.lastSeenSec.find? (fun (m, _) => m == machineId)).map Prod.snd

def enqueueRelayHttpReq (hub : RelayHub) (req : RelayHttpReq) : IO Unit :=
  hub.mu.atomically do
    let st ← get
    let cur := ((st.pendingByMachine.find? (fun (m, _) => m == req.machineId)).map Prod.snd).getD #[]
    let others := st.pendingByMachine.filter (fun (m, _) => m != req.machineId)
    set { st with pendingByMachine := others.push (req.machineId, cur.push req) }

def drainRelayHttpReqs (hub : RelayHub) (machineId : String) : IO (Array RelayHttpReq) :=
  hub.mu.atomically do
    let st ← get
    let cur := ((st.pendingByMachine.find? (fun (m, _) => m == machineId)).map Prod.snd).getD #[]
    if cur.isEmpty then
      return #[]
    else
      let others := st.pendingByMachine.filter (fun (m, _) => m != machineId)
      set { st with pendingByMachine := others }
      return cur

def deliverRelayHttpResp (hub : RelayHub) (resp : RelayHttpResp) : IO Unit :=
  hub.mu.atomically do
    let st ← get
    let kept :=
      if st.completedById.size > 512 then
        st.completedById.extract (st.completedById.size - 256) st.completedById.size
      else
        st.completedById
    let withoutDup := kept.filter (fun (id, _) => id != resp.id)
    set { st with completedById := withoutDup.push (resp.id, resp) }

def takeRelayHttpResp? (hub : RelayHub) (reqId : String) : IO (Option RelayHttpResp) :=
  hub.mu.atomically do
    let st ← get
    match st.completedById.find? (fun (id, _) => id == reqId) with
    | none => return none
    | some (_, resp) =>
      set { st with completedById := st.completedById.filter (fun (id, _) => id != reqId) }
      return some resp

def renderRelayHttpReqsJson (reqs : Array RelayHttpReq) : String :=
  let items := reqs.map fun r =>
    JVal.obj #[
      ("id", .str r.id),
      ("method", .str r.method),
      ("path", .str r.path),
      ("timeout_secs", JVal.nat r.timeoutSecs),
      ("headers", .arr (r.headers.map (fun (k, v) => .arr #[.str k, .str v]))),
      ("body_b64", .str r.bodyB64)
    ]
  renderCompact (.arr items)

def parseRelayHttpRespJson? (jv : JVal) : Option RelayHttpResp := do
  let id ← jv.fieldStr? "id"
  if id.isEmpty then none
  let status := (jv.fieldNat? "status").getD 200
  let bodyB64 := (jv.fieldStr? "body_b64").getD ""
  let hdrs : Array (String × String) :=
    match jv.fieldArr? "headers" with
    | some arr =>
      arr.filterMap fun pair =>
        match pair with
        | .arr kv =>
          if kv.size ≥ 2 then
            match kv[0]!.asStr?, kv[1]!.asStr? with
            | some k, some v => some (k, v)
            | _, _ => none
          else none
        | _ => none
    | none => #[]
  return { id, status, headers := hdrs, bodyB64 }

def getManagedNodeAuth? (mc : ManagedComputeStore) (machineId : String) : IO (Option (String × String)) := do
  match ← execParamQuery mc.db
      "SELECT node_id,node_token FROM managed_node_tokens WHERE machine_id=?1;"
      #[machineId] with
  | .ok rows =>
    if rows.size > 1 then
      let nid := cell rows[1]! 0
      let tok := cell rows[1]! 1
      if tok.isEmpty then return none
      else return some (if nid.isEmpty then s!"managed-{machineId}" else nid, tok)
    else
      return none
  | .error _ => return none

/-- Tunnel an HTTP request over `RelayHub` to a dial-out `sandboxed-node` (`OrbNode.Dial`),
    injecting `Authorization: Bearer <nodeToken>` when not already present. -/
def tunnelHttpToManagedMachine
    (hub : RelayHub)
    (mc : ManagedComputeStore)
    (machineId method pathQuery : String)
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (timeoutMs : Nat := 25000) : IO (Except String HttpsResponse) := do
  let some (_, nodeTok) ← getManagedNodeAuth? mc machineId
    | return .error s!"managed machine `{machineId}` has no enrolled node token"
  let reqId ← newUuidV4
  let nowSec ← nowEpoch
  let hasAuth := headers.any (fun (k, _) => k.toLower == "authorization")
  let effHdrs :=
    if hasAuth then headers
    else headers.push ("Authorization", s!"Bearer {nodeTok}")
  let cleanPath := if pathQuery.startsWith "/" then pathQuery else "/" ++ pathQuery
  let timeoutSecs := Nat.max 5 ((timeoutMs + 999) / 1000)
  enqueueRelayHttpReq hub {
    id := reqId
    machineId := machineId
    method := method
    path := cleanPath
    headers := effHdrs
    bodyB64 := OrbBin.PosixExt.base64Encode body false true
    timeoutSecs := timeoutSecs
    createdSec := nowSec
  }
  let stepMs : Nat := 25
  let maxIters := Nat.max 1 (timeoutMs / stepMs)
  for _ in [0:maxIters] do
    if let some r ← takeRelayHttpResp? hub reqId then
      let decodedBody := (OrbBin.PosixExt.base64Decode? r.bodyB64).getD ByteArray.empty
      return .ok {
        status := r.status
        headers := r.headers
        body := decodedBody
      }
    IO.sleep stepMs.toUInt32
  -- Clean up unconsumed queued request if node never polled
  let _ ← hub.mu.atomically do
    let st ← get
    let updated := st.pendingByMachine.map fun (m, arr) =>
      if m == machineId then (m, arr.filter (fun q => q.id != reqId)) else (m, arr)
    set { st with pendingByMachine := updated }
  return .error s!"relay tunnel timeout waiting for managed machine `{machineId}`"

/-! ## `OrbNode.Lease` Scoped HMAC-SHA256 Token Minting -/

def signRemoteNodeLeaseToken
    (nodeSecret missionId nodeId scope : String)
    (expiresAt : UInt64)
    (jobId? : Option String := none)
    (ownerUserId : String := "")
    (callerRole : String := "admin")
    (unixUsername? : Option String := none) : String :=
  let cleanUnix? := unixUsername?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let fields : Array (String × JVal) :=
    #[ ("mission_id", .str missionId)
     , ("node_id", .str nodeId)
     , ("scope", .str scope)
     , ("expires_at", JVal.uint64 expiresAt) ] ++
    (match jobId? with | some j => #[("job_id", .str j)] | none => #[]) ++
    (if ownerUserId.isEmpty then #[] else #[("owner_user_id", .str ownerUserId)]) ++
    (if callerRole == "admin" && ownerUserId.isEmpty && cleanUnix?.isNone then #[] else #[("caller_role", .str callerRole)]) ++
    (match cleanUnix? with | some u => #[("unix_username", .str u)] | none => #[])
  let b64 := OrbBin.PosixExt.base64Encode (renderCompact (.obj fields)).toUTF8 true false
  let sigHex := hmacSha256Hex nodeSecret b64
  s!"{b64}.{sigHex}"

/-! ## Static Remote Nodes (`SANDBOXED_REMOTE_NODES`) & Unified Remote Node Client -/

structure StaticRemoteNode where
  id       : String
  baseUrl  : String
  tokenEnv : String
  labels   : Array String := #[]
  deriving Repr, Inhabited

private def parseBoolEnvFlag (key : String) (defaultVal : Bool := false) : IO Bool := do
  match ← IO.getEnv key with
  | none => return defaultVal
  | some raw =>
    let s := raw.trimAscii.toString.toLower
    if s == "1" || s == "true" || s == "yes" || s == "on" then return true
    else if s == "0" || s == "false" || s == "no" || s == "off" then return false
    else return defaultVal

def defaultRemoteNodeTokenEnv (nodeId : String) : String :=
  let mapped := nodeId.toList.map fun ch =>
    if ch.isAlphanum then ch.toUpper else '_'
  s!"SANDBOXED_REMOTE_NODE_{String.ofList mapped}_TOKEN"

private def trimTrailingSlashes (s : String) : String :=
  let rev := s.trimAscii.toString.toList.reverse.dropWhile (· == '/')
  String.ofList rev.reverse

def parseStaticRemoteNodesRaw (raw : String) : Array StaticRemoteNode := Id.run do
  let trimmed := raw.trimAscii.toString
  if trimmed.isEmpty then return #[]
  if trimmed.startsWith "[" then
    match OrbBin.Json.parse trimmed with
    | .ok (.arr items) =>
      return items.filterMap fun it => do
        let id ← it.fieldStr? "id"
        let url ← (it.fieldStr? "base_url").orElse (fun _ => it.fieldStr? "url")
        let tokEnv := ((it.fieldStr? "token_env").filter (!·.isEmpty)).getD (defaultRemoteNodeTokenEnv id)
        let lbls := ((it.fieldArr? "labels").getD #[]).filterMap JVal.asStr?
        if id.isEmpty || url.isEmpty then none
        else some { id, baseUrl := trimTrailingSlashes url, tokenEnv := tokEnv, labels := lbls }
    | _ => return #[]
  else
    let entries := (trimmed.splitOn ",").map (fun e => e.trimAscii.toString) |>.filter (!·.isEmpty)
    let mut out : Array StaticRemoteNode := #[]
    for entry in entries do
      let eqParts := entry.splitOn "="
      if eqParts.length ≥ 2 then
        let id := eqParts[0]!.trimAscii.toString
        let rest := String.intercalate "=" (eqParts.drop 1)
        let pipeParts := (rest.splitOn "|").map (fun p => p.trimAscii.toString)
        let url := (pipeParts[0]?.getD "")
        let tokEnv :=
          match pipeParts[1]? with
          | some te => if te.isEmpty then defaultRemoteNodeTokenEnv id else te
          | none => defaultRemoteNodeTokenEnv id
        if !id.isEmpty && !url.isEmpty then
          out := out.push { id, baseUrl := trimTrailingSlashes url, tokenEnv := tokEnv }
    return out

def loadStaticRemoteNodes : IO (Bool × Array StaticRemoteNode) := do
  let enabled ← parseBoolEnvFlag "SANDBOXED_REMOTE_NODES_ENABLED" false
  let raw := ((← IO.getEnv "SANDBOXED_REMOTE_NODES").getD "").trimAscii.toString
  let parsed := parseStaticRemoteNodesRaw raw
  return (enabled || !parsed.isEmpty, parsed)

def resolveStaticNodeToken? (node : StaticRemoteNode) : IO (Option String) := do
  if let some v ← IO.getEnv node.tokenEnv then
    let t := v.trimAscii.toString
    if !t.isEmpty then return some t
  return none

/-- Extract `machineId` if `nodeOrMachineId` refers to a managed machine (`"managed-<id>"` or `<id>`). -/
def resolveManagedMachineId? (mc : ManagedComputeStore) (nodeOrMachineId : String) : IO (Option String) := do
  let clean := nodeOrMachineId.trimAscii.toString
  if clean.isEmpty then return none
  let cand := if clean.startsWith "managed-" then (clean.drop 8).toString else clean
  if let some _ ← getManagedMachine? mc cand then
    return some cand
  return none

/-- Unified HTTP call to either a static remote node or a dial-out managed VM (`OrbNode`). -/
def callRemoteNodeHttp
    (hub? : Option RelayHub)
    (mc : ManagedComputeStore)
    (targetNodeId method pathQuery : String)
    (jsonBody? : Option JVal := none)
    (extraHeaders : Array (String × String) := #[])
    (timeoutMs : Nat := 15000) : IO (Except String (Nat × String × Option JVal × String × String)) := do
  let (_, staticNodes) ← loadStaticRemoteNodes
  let cleanPath := if pathQuery.startsWith "/" then pathQuery else "/" ++ pathQuery
  if let some sn := staticNodes.find? (fun n => n.id == targetNodeId) then
    let some tok ← resolveStaticNodeToken? sn
      | return .error s!"remote node `{sn.id}` has no token in `{sn.tokenEnv}`"
    let fullUrl := sn.baseUrl ++ cleanPath
    match ← sendJsonRequest method fullUrl (some tok) jsonBody? extraHeaders timeoutMs.toUInt32 with
    | .error e => return .error e
    | .ok (st, txt, jv?) => return .ok (st, txt, jv?, sn.id, tok)
  else
    let some mid ← resolveManagedMachineId? mc targetNodeId
      | return .error s!"unknown remote node `{targetNodeId}`"
    let some (effNodeId, nodeTok) ← getManagedNodeAuth? mc mid
      | return .error s!"managed node `{mid}` has no enrolled token"
    let some hub := hub?
      | return .error "relay_hub_unavailable"
    let mut hdrs := extraHeaders.push ("Authorization", s!"Bearer {nodeTok}")
    let bodyBytes ← match jsonBody? with
      | some j =>
        hdrs := hdrs.push ("Content-Type", "application/json")
        pure (renderCompact j).toUTF8
      | none => pure ByteArray.empty
    match ← tunnelHttpToManagedMachine hub mc mid method cleanPath hdrs bodyBytes timeoutMs with
    | .error e => return .error e
    | .ok resp =>
      let txt := (String.fromUTF8? resp.body).getD ""
      let jv? := (OrbBin.Json.parseBytes resp.body).toOption
      return .ok (resp.status, txt, jv?, effNodeId, nodeTok)

/-- Execute a command synchronously (`POST /execute`) on a remote node or managed VM. -/
def execOnRemoteNode
    (hub? : Option RelayHub)
    (mc : ManagedComputeStore)
    (targetNodeId missionId command : String)
    (sideLane : Bool := false)
    (timeoutMs : Nat := 60000) : IO (Except String JVal) := do
  let (_, staticNodes) ← loadStaticRemoteNodes
  let (effNodeId, nodeSecret) ← do
    if let some sn := staticNodes.find? (fun n => n.id == targetNodeId) then
      match ← resolveStaticNodeToken? sn with
      | some tok => pure (sn.id, tok)
      | none => return .error s!"remote node `{sn.id}` has no token in `{sn.tokenEnv}`"
    else
      match ← resolveManagedMachineId? mc targetNodeId with
      | none => return .error s!"unknown remote node `{targetNodeId}`"
      | some mid =>
        match ← getManagedNodeAuth? mc mid with
        | some pair => pure pair
        | none => return .error s!"managed machine `{mid}` has no enrolled token"
  let nowSec ← nowEpoch
  let effMissionId :=
    if missionId.trimAscii.toString.isEmpty then "00000000-0000-0000-0000-000000000000"
    else missionId.trimAscii.toString
  let leaseTok := signRemoteNodeLeaseToken nodeSecret effMissionId effNodeId "mission:execute" (nowSec + 900)
  let payload := JVal.obj #[
    ("mission_id", .str effMissionId),
    ("lease_token", .str leaseTok),
    ("command", .str command),
    ("side_lane", .bool sideLane)
  ]
  match ← callRemoteNodeHttp hub? mc targetNodeId "POST" "/execute" (some payload) #[] timeoutMs with
  | .error e => return .error e
  | .ok (st, txt, jv?, _, _) =>
    if 200 ≤ st && st < 300 then
      return .ok (jv?.getD (.obj #[("stdout", .str txt), ("exit_code", JVal.nat 0)]))
    else
      return .error s!"node HTTP {st}: {txt}"

/-! ## `GET /api/compute/fleet` & Enriched `GET /api/remote-nodes` -/

def probeStaticNodeHeartbeat (sn : StaticRemoteNode) : IO JVal := do
  let cordonedFlag := false
  match ← resolveStaticNodeToken? sn with
  | none =>
    return .obj #[
      ("id", .str sn.id),
      ("name", .str sn.id),
      ("kind", .str "static"),
      ("base_url", .str sn.baseUrl),
      ("status", .str "degraded"),
      ("cordoned", .bool cordonedFlag),
      ("labels", .arr (sn.labels.map .str)),
      ("error", .str s!"missing token env {sn.tokenEnv}")
    ]
  | some tok =>
    match ← sendJsonRequest "GET" (sn.baseUrl ++ "/heartbeat") (some tok) none #[] 2500 with
    | .ok (200, _, some hb) =>
      let cap := (hb.fieldNat? "capacity_total").orElse (fun _ => hb.fieldNat? "capacity") |>.getD 4
      let act := (hb.fieldNat? "active_jobs").orElse (fun _ => hb.fieldNat? "running_jobs") |>.getD 0
      let qd := (hb.fieldNat? "queued_jobs").getD 0
      let availSlots := if cap > act then cap - act else 0
      return .obj #[
        ("id", .str sn.id),
        ("name", .str sn.id),
        ("kind", .str "static"),
        ("base_url", .str sn.baseUrl),
        ("status", .str "online"),
        ("cordoned", .bool ((hb.fieldBool? "cordoned").getD false)),
        ("capacity_total", JVal.nat cap),
        ("active_jobs", JVal.nat act),
        ("queued_jobs", JVal.nat qd),
        ("available_slots", JVal.nat availSlots),
        ("labels", .arr (sn.labels.map .str)),
        ("heartbeat", hb)
      ]
    | .ok (code, txt, _) =>
      return .obj #[
        ("id", .str sn.id),
        ("name", .str sn.id),
        ("kind", .str "static"),
        ("base_url", .str sn.baseUrl),
        ("status", .str "degraded"),
        ("cordoned", .bool false),
        ("labels", .arr (sn.labels.map .str)),
        ("error", .str s!"HTTP {code}: {(txt.take 120).toString}")
      ]
    | .error err =>
      return .obj #[
        ("id", .str sn.id),
        ("name", .str sn.id),
        ("kind", .str "static"),
        ("base_url", .str sn.baseUrl),
        ("status", .str "offline"),
        ("cordoned", .bool false),
        ("labels", .arr (sn.labels.map .str)),
        ("error", .str err)
      ]

def buildComputeFleetJVal
    (hub? : Option RelayHub)
    (_mc : ManagedComputeStore)
    (fleet : ManagedFleetState)
    (callerUserId? : Option String := none)
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none) : IO JVal := do
  let (rnEnabled, staticNodes) ← loadStaticRemoteNodes
  let nowSec ← nowEpoch
  let mut staticItems : Array JVal := #[]
  for sn in staticNodes do
    staticItems := staticItems.push (← probeStaticNodeHeartbeat sn)
  let visibleMachines :=
    match callerUserId? with
    | none => fleet.machines
    | some uid => fleet.machines.filter (fun m => m.ownerUserId == uid || m.ownerUserId.isEmpty)
  let mut managedItems : Array JVal := #[]
  for m in visibleMachines do
    if m.status != "destroyed" then
      let seenSec? ← match hub? with
        | some h => getMachineLastSeen? h m.id
        | none => pure none
      let relayConnected :=
        match seenSec? with
        | some s => nowSec ≤ s + 90
        | none => m.status == "ready"
      managedItems := managedItems.push (.obj #[
        ("id", .str s!"managed-{m.id}"),
        ("machine_id", .str m.id),
        ("name", .str m.sandboxName),
        ("sandbox_name", .str m.sandboxName),
        ("kind", .str "managed"),
        ("provider", .str m.provider),
        ("size", .str m.size),
        ("status", .str m.status),
        ("relay_connected", .bool relayConnected),
        ("cordoned", .bool m.cordoned),
        ("owner_mission", .str m.ownerMission),
        ("node_boot_epoch", JVal.uint64 m.nodeBootEpoch),
        ("deletable_at", JVal.uint64 m.deletableAtSec),
        ("spent_cents", JVal.uint64 m.spentCents),
        ("labels", .arr #[.str "managed", .str s!"provider={m.provider}"])
      ])
  let budgetVal :=
    (OrbBin.Json.parse (renderManagedBudgetJson fleet callerUserId? userSpentTodayCents userDailyCapCents?)).toOption.getD (.obj #[])
  let allNodes := staticItems ++ managedItems
  return .obj #[
    ("remote_nodes_enabled", .bool rnEnabled),
    ("nodes", .arr allNodes),
    ("static_nodes", .arr staticItems),
    ("managed_nodes", .arr managedItems),
    ("managed_compute", budgetVal)
  ]

/-! ## Boat (`boat.dev`) Provider API Helper & Managed Snapshots Store -/

private def ensureManagedSnapshotsTable (mc : ManagedComputeStore) : IO Unit := do
  discard <| execParamQuery mc.db
    "CREATE TABLE IF NOT EXISTS managed_snapshots (id TEXT PRIMARY KEY, name TEXT NOT NULL, provider TEXT NOT NULL DEFAULT 'boat', source_machine_id TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'ready', size_gb INTEGER NOT NULL DEFAULT 20, created_at TEXT NOT NULL DEFAULT '');" #[]

def getBoatApiKey? (workingDir dataRoot : String) : IO (Option String) := do
  match ← openProviderSecret dataRoot "boat" false true with
  | .ok k =>
    let clean := k.trimAscii.toString
    if !clean.isEmpty then return some clean
  | .error _ => pure ()
  if let some envK ← IO.getEnv "BOAT_API_KEY" then
    let clean := envK.trimAscii.toString
    if !clean.isEmpty then return some clean
  let settingsObj ← readSettingsJson dataRoot
  if let some sk := settingsObj.fieldStr? "boat_api_key" then
    let key32? ← loadPrivateKeyBytes? workingDir dataRoot
    if let .ok dec ← decryptEnvValue key32? sk then
      let clean := dec.trimAscii.toString
      if !clean.isEmpty then return some clean
  return none

def boatApiBaseUrl : IO String := do
  let raw := ((← IO.getEnv "BOAT_API_URL").getD "https://boat.dev/api/v1").trimAscii.toString
  return trimTrailingSlashes raw

def callBoatApi
    (dataRoot method relPath : String)
    (jsonBody? : Option JVal := none)
    (timeoutMs : UInt32 := 25000) : IO (Except String (Nat × JVal)) := do
  let some apiKey ← getBoatApiKey? dataRoot dataRoot
    | return .error "boat_api_key_not_configured"
  let base ← boatApiBaseUrl
  let url := base ++ (if relPath.startsWith "/" then relPath else "/" ++ relPath)
  match ← sendJsonRequest method url (some apiKey) jsonBody? #[] timeoutMs with
  | .error e => return .error e
  | .ok (st, txt, jv?) =>
    return .ok (st, jv?.getD (.obj #[("raw", .str txt)]))

def listManagedSnapshotsJson (mc : ManagedComputeStore) (dataRoot : String) : IO JVal := do
  ensureManagedSnapshotsTable mc
  let mut localSnaps : Array JVal := #[]
  if let .ok rows ← execParamQuery mc.db
      "SELECT id,name,provider,source_machine_id,status,size_gb,created_at FROM managed_snapshots ORDER BY created_at DESC;" #[] then
    for i in [1:rows.size] do
      let r := rows[i]!
      localSnaps := localSnaps.push (.obj #[
        ("id", .str (cell r 0)),
        ("name", .str (cell r 1)),
        ("provider", .str (cell r 2)),
        ("source_machine_id", .str (cell r 3)),
        ("status", .str (cell r 4)),
        ("size_gb", JVal.uint64 (cellU64 r 5)),
        ("created_at", .str (cell r 6))
      ])
  -- Merge live Boat snapshots if Boat API responds quickly
  if let .ok (200, bJv) ← callBoatApi dataRoot "GET" "/snapshots" none 4000 then
    let remoteArr := (bJv.fieldArr? "snapshots").orElse (fun _ => bJv.asArr?) |>.getD #[]
    for rs in remoteArr do
      let rid := (rs.fieldStr? "id").getD ""
      if !rid.isEmpty && !localSnaps.any (fun ls => (ls.fieldStr? "id") == some rid) then
        localSnaps := localSnaps.push rs
  return .obj #[("snapshots", .arr localSnaps)]

def createManagedSnapshot
    (mc : ManagedComputeStore)
    (dataRoot machineId snapName nowIso : String) : IO (Except String JVal) := do
  ensureManagedSnapshotsTable mc
  let some (m, _) ← getManagedMachine? mc machineId
    | return .error "managed_machine_missing"
  let effName :=
    let t := snapName.trimAscii.toString
    if t.isEmpty then s!"snap-{m.sandboxName}" else t
  let mut snapId ← newUuidV4
  if m.provider == "boat" then
    if let .ok (st, bJv) ← callBoatApi dataRoot "POST" s!"/sandboxes/{m.id}/snapshots"
        (some (.obj #[("name", .str effName)])) 15000 then
      if 200 ≤ st && st < 300 then
        if let some bid := bJv.fieldStr? "id" then
          if !bid.isEmpty then snapId := bid
  discard <| execParamQuery mc.db
    "INSERT INTO managed_snapshots(id,name,provider,source_machine_id,status,size_gb,created_at) VALUES(?1,?2,?3,?4,'ready',20,?5) ON CONFLICT(id) DO UPDATE SET name=excluded.name,status='ready';"
    #[snapId, effName, m.provider, m.id, nowIso]
  return .ok (.obj #[
    ("id", .str snapId),
    ("name", .str effName),
    ("provider", .str m.provider),
    ("source_machine_id", .str m.id),
    ("status", .str "ready"),
    ("created_at", .str nowIso)
  ])

def deleteManagedSnapshot (mc : ManagedComputeStore) (dataRoot snapId : String) : IO Bool := do
  ensureManagedSnapshotsTable mc
  discard <| callBoatApi dataRoot "DELETE" s!"/snapshots/{snapId}" none 8000
  match ← execParamQuery mc.db "DELETE FROM managed_snapshots WHERE id=?1;" #[snapId] with
  | .ok _ => return true
  | .error _ => return false

/-! ## Durable Node Job Ledger Queries (`/api/durable-jobs*`) -/

private def ensureDurableJobsTable (store : CoreStore) : IO Unit := do
  discard <| execParamQuery store.missionsDb
    "CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', node_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');" #[]

def listDurableJobsJson (store : CoreStore) (missionId? : Option String := none) (limit : Nat := 100) : IO JVal := do
  ensureDurableJobsTable store
  let lim := Nat.min (Nat.max limit 1) 500
  let qRes ← match missionId? with
    | some mid =>
      execParamQuery store.missionsDb
        "SELECT job_id,mission_id,node_id,state,payload_json,created_at,updated_at FROM remote_node_jobs WHERE mission_id=?1 ORDER BY updated_at DESC LIMIT ?2;"
        #[mid, s!"{lim}"]
    | none =>
      execParamQuery store.missionsDb
        "SELECT job_id,mission_id,node_id,state,payload_json,created_at,updated_at FROM remote_node_jobs ORDER BY updated_at DESC LIMIT ?1;"
        #[s!"{lim}"]
  let mut jobs : Array JVal := #[]
  if let .ok rows := qRes then
    for i in [1:rows.size] do
      let r := rows[i]!
      jobs := jobs.push (.obj #[
        ("job_id", .str (cell r 0)),
        ("mission_id", .str (cell r 1)),
        ("node_id", .str (cell r 2)),
        ("state", .str (cell r 3)),
        ("created_at", .str (cell r 5)),
        ("updated_at", .str (cell r 6))
      ])
  return .obj #[("jobs", .arr jobs)]

/-! ## HTTP Route Dispatcher for Fleet, Managed Extensions, Nodes & Durable Jobs -/

private def parseRawQueryMap (rawTarget : String) : Array (String × String) := Id.run do
  let qStr :=
    match rawTarget.splitOn "?" with
    | _ :: qs => String.intercalate "?" qs
    | [] => ""
  if qStr.isEmpty then return #[]
  let mut out : Array (String × String) := #[]
  for pair in qStr.splitOn "&" do
    if !pair.isEmpty then
      match pair.splitOn "=" with
      | [] => pure ()
      | [k] => out := out.push ((percentDecodeStrict k).getD k, "")
      | k :: vs =>
        let rawV := String.intercalate "=" vs
        out := out.push ((percentDecodeStrict k).getD k, (percentDecodeStrict rawV).getD rawV)
  return out

private def lookupQueryParam? (qMap : Array (String × String)) (key : String) : Option String :=
  (qMap.find? (fun (k, _) => k == key)).map Prod.snd

private def jsonResp (status : Nat) (jv : JVal) : Nat × String × ByteArray :=
  (status, "application/json", (renderCompact jv).toUTF8)

private def jsonRawResp (status : Nat) (rawJson : String) : Nat × String × ByteArray :=
  (status, "application/json", rawJson.toUTF8)

private def jsonErr (status : Nat) (code : String) : Nat × String × ByteArray :=
  (status, "application/json", s!"\{\"error\":{jsonEscape code}}".toUTF8)

set_option maxHeartbeats 800000 in
/-- Dispatch fleet, relay HTTP tunnel, bootstrap binary, managed-machine extensions,
    node cordon/capacity, and durable-job endpoints. Returns `none` when path does not match. -/
def dispatchRemoteFleetAndRelayRoutes?
    (store : CoreStore)
    (mc : ManagedComputeStore)
    (hub? : Option RelayHub)
    (defaultFleet : ManagedFleetState)
    (method cleanPath rawTarget : String)
    (headers : Array (String × String))
    (bodyBytes : ByteArray)
    (callerUserId : String)
    (isAdmin : Bool)
    (isLegacyUnscoped : Bool)
    (nowEpochSec : UInt64)
    (nowIso : String) : IO (Option (Nat × String × ByteArray)) := do
  let segs := (cleanPath.splitOn "/").filter (!·.isEmpty)
  let scopedUid? : Option String := if isLegacyUnscoped then none else some callerUserId

  -- 1. Public node bootstrap binary download (`GET /api/managed-machines/bootstrap-binary/:id`)
  if method == "GET" && segs.length == 4 &&
      segs[0]? == some "api" && segs[1]? == some "managed-machines" && segs[2]? == some "bootstrap-binary" then
    let mid := segs[3]!
    let some _ ← getManagedMachine? mc mid
      | return some (jsonErr 404 "managed_machine_not_found")
    let binCandidates := #["/usr/local/bin/sandboxed-node", "/usr/bin/sandboxed-node"]
    for bp in binCandidates do
      if ← (System.FilePath.mk bp).pathExists then
        if let .ok bytes ← (IO.FS.readBinFile bp).toBaseIO then
          return some (200, "application/octet-stream", bytes)
    return some (jsonErr 404 "bootstrap_binary_unavailable")

  -- 2. Authenticated relay HTTP tunnel (`* /api/managed-machines/relay/tunnel/:id/*`)
  if segs.length ≥ 5 &&
      segs[0]? == some "api" && segs[1]? == some "managed-machines" &&
      segs[2]? == some "relay" && segs[3]? == some "tunnel" then
    if !isAdmin then
      return some (jsonErr 403 "admin_required")
    let mid := segs[4]!
    let some hub := hub?
      | return some (jsonErr 503 "relay_hub_unavailable")
    let subSegs := segs.drop 5
    let rawSubPath := "/" ++ String.intercalate "/" subSegs
    let queryTail :=
      match rawTarget.splitOn "?" with
      | _ :: qs => if qs.isEmpty then "" else "?" ++ String.intercalate "?" qs
      | [] => ""
    let forwardHdrs := headers.filter fun (k, _) =>
      let kl := k.toLower
      kl != "host" && kl != "connection" && kl != "content-length" && kl != "authorization"
    match ← tunnelHttpToManagedMachine hub mc mid method (rawSubPath ++ queryTail) forwardHdrs bodyBytes 25000 with
    | .error e => return some (jsonErr 502 e)
    | .ok r =>
      let ct := ((r.headers.find? (fun (k, _) => k.toLower == "content-type")).map Prod.snd).getD "application/json"
      return some (r.status, ct, r.body)

  -- 3. `GET /api/compute/fleet`
  if method == "GET" && segs == ["api", "compute", "fleet"] then
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet
    let uSpent ←
      if scopedUid?.isSome then
        let (_, cmp) ← getUserSpentTodayCents store callerUserId (nowIso.take 10).toString
        pure cmp
      else pure 0
    let fv ← buildComputeFleetJVal hub? mc fleet scopedUid? uSpent none
    return some (jsonResp 200 fv)

  -- 4. `/api/managed-machines/{settings,providers*,snapshots*,:id*}`
  if segs.length ≥ 3 && segs[0]? == some "api" && segs[1]? == some "managed-machines" then
    let fleet ← match ← loadManagedFleet mc defaultFleet.enabled defaultFleet.boatEnabled
        defaultFleet.dailyCapCents defaultFleet.spentTodayCents defaultFleet.maxConcurrent with
      | .ok f => pure f
      | .error _ => pure defaultFleet

    if segs == ["api", "managed-machines", "settings"] then
      if method == "GET" then
        return some (jsonResp 200 (.obj #[
          ("enabled", .bool fleet.enabled),
          ("boat_enabled", .bool fleet.boatEnabled),
          ("daily_cap_cents", JVal.uint64 fleet.dailyCapCents),
          ("spent_today_cents", JVal.uint64 fleet.spentTodayCents),
          ("max_concurrent", JVal.uint64 fleet.maxConcurrent)
        ]))
      else if method == "PUT" || method == "POST" || method == "PATCH" then
        if !isAdmin then return some (jsonErr 403 "admin_required")
        let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
        let nextEn := (jv.fieldBool? "enabled").getD fleet.enabled
        let nextBoat := (jv.fieldBool? "boat_enabled").getD fleet.boatEnabled
        let nextCap := (jv.fieldUInt64? "daily_cap_cents").getD fleet.dailyCapCents
        let nextMax := (jv.fieldUInt64? "max_concurrent").getD fleet.maxConcurrent
        if let some bKey := (jv.fieldStr? "boat_api_key").filter (!·.trimAscii.toString.isEmpty) then
          discard <| sealProviderSecret store.rootDir "boat" bKey.trimAscii.toString
        discard <| saveManagedFleetConfig mc nextEn nextBoat nextCap fleet.spentTodayCents nextMax
        return some (jsonResp 200 (.obj #[
          ("ok", .bool true),
          ("enabled", .bool nextEn),
          ("boat_enabled", .bool nextBoat),
          ("daily_cap_cents", JVal.uint64 nextCap),
          ("max_concurrent", JVal.uint64 nextMax)
        ]))

    if method == "GET" && segs == ["api", "managed-machines", "providers"] then
      let prefs ← getUserManagedPrefs mc callerUserId
      let mut cfgProvs : Array String := #[]
      for p in knownProviders do
        if let .ok _ ← openProviderSecret store.rootDir p false true then
          cfgProvs := cfgProvs.push p
      return some (jsonRawResp 200 (renderManagedProvidersJson fleet isAdmin prefs cfgProvs))

    if method == "PUT" && segs.length == 4 && segs[2]? == some "providers" then
      if !isAdmin then return some (jsonErr 403 "admin_required")
      let prov := canonicalizeProvider segs[3]!
      let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
      if let some apiKey := (jv.fieldStr? "api_key").filter (!·.trimAscii.toString.isEmpty) then
        if let .error e ← sealProviderSecret store.rootDir prov apiKey.trimAscii.toString then
          return some (jsonErr 400 e)
      if prov == "boat" then
        let nextBoat := (jv.fieldBool? "enabled").getD true
        discard <| saveManagedFleetConfig mc (fleet.enabled || nextBoat) nextBoat fleet.dailyCapCents fleet.spentTodayCents fleet.maxConcurrent
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("provider", .str prov)]))

    if method == "PUT" && segs.length == 4 && segs[2]? == some "user-providers" then
      let prov := canonicalizeProvider segs[3]!
      let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
      let en := (jv.fieldBool? "enabled").getD true
      match ← setUserManagedPref mc callerUserId prov en nowIso with
      | .ok () => return some (jsonResp 200 (.obj #[("ok", .bool true), ("provider", .str prov), ("enabled", .bool en)]))
      | .error e => return some (jsonErr 400 e)

    if segs == ["api", "managed-machines", "snapshots"] then
      if method == "GET" then
        return some (jsonResp 200 (← listManagedSnapshotsJson mc store.rootDir))
      else if method == "POST" then
        let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
        let mid := (jv.fieldStr? "machine_id").getD ""
        let sName := (jv.fieldStr? "name").getD ""
        match ← createManagedSnapshot mc store.rootDir mid sName nowIso with
        | .ok sv => return some (jsonResp 201 sv)
        | .error e => return some (jsonErr 400 e)

    if method == "DELETE" && segs.length == 4 && segs[2]? == some "snapshots" then
      let ok ← deleteManagedSnapshot mc store.rootDir segs[3]!
      return some (jsonResp 200 (.obj #[("ok", .bool ok)]))

    -- Reserved single-segment routes in Control.lean: `spend`, `enroll`, `relay`
    let sub2 := segs[2]!
    if sub2 != "spend" && sub2 != "enroll" && sub2 != "relay" then
      if method == "GET" && segs.length == 3 then
        match ← getManagedMachine? mc sub2 with
        | none => return some (jsonErr 404 "managed_machine_not_found")
        | some (m, _) =>
          if !isAdmin && !isLegacyUnscoped && !m.ownerUserId.isEmpty && m.ownerUserId != callerUserId then
            return some (jsonErr 404 "managed_machine_not_found")
          return some (jsonRawResp 200 (renderManagedMachineItemJson m))
      else if method == "GET" && segs.length == 4 && segs[3]? == some "operations" then
        return some (jsonResp 200 (.obj #[("operations", .arr #[])]))
      else if method == "POST" && segs.length == 4 then
        let action := segs[3]!
        let some (m, _) ← getManagedMachine? mc sub2
          | return some (jsonErr 404 "managed_machine_not_found")
        if !isAdmin && !isLegacyUnscoped && !m.ownerUserId.isEmpty && m.ownerUserId != callerUserId then
          return some (jsonErr 404 "managed_machine_not_found")
        let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
        if action == "extend" then
          let addMins := (jv.fieldUInt64? "minutes").orElse (fun _ => jv.fieldUInt64? "ttl_minutes") |>.getD 60
          let newDel := (if m.deletableAtSec > nowEpochSec then m.deletableAtSec else nowEpochSec) + addMins * 60
          discard <| execParamQuery mc.db
            "UPDATE managed_machines SET ttl_minutes=ttl_minutes+?2,deletable_at_sec=?3 WHERE id=?1;"
            #[m.id, s!"{addMins}", s!"{newDel}"]
          return some (jsonResp 200 (.obj #[("ok", .bool true), ("id", .str m.id), ("deletable_at", JVal.uint64 newDel)]))
        else if action == "snapshot" then
          let sName := (jv.fieldStr? "name").getD ""
          match ← createManagedSnapshot mc store.rootDir m.id sName nowIso with
          | .ok sv => return some (jsonResp 201 sv)
          | .error e => return some (jsonErr 400 e)
        else if action == "owner" then
          let nextMission := (jv.fieldStr? "owner_mission").orElse (fun _ => jv.fieldStr? "mission_id") |>.getD ""
          let nextKind := (jv.fieldStr? "owner_kind").getD (if nextMission.isEmpty then "user" else "mission")
          discard <| execParamQuery mc.db
            "UPDATE managed_machines SET owner_mission=?2,owner_kind=?3 WHERE id=?1;"
            #[m.id, nextMission, nextKind]
          return some (jsonResp 200 (.obj #[("ok", .bool true), ("id", .str m.id), ("owner_mission", .str nextMission)]))
        else if action == "fork" then
          let forkId ← newUuidV4
          let forkName := ((jv.fieldStr? "name").filter (!·.isEmpty)).getD s!"{m.sandboxName}-fork"
          let forked : ManagedMachine := {
            m with
            id := forkId
            sandboxName := forkName
            status := "provisioning"
            nodeBootEpoch := 1
            deletableAtSec := nowEpochSec + m.ttlMinutes * 60
          }
          match ← provisionManagedMachine mc fleet forked nowEpochSec with
          | .error e => return some (jsonErr 409 e)
          | .ok saved =>
            let enrollTok ← newUuidV4
            discard <| putEnrollmentToken mc saved.id enrollTok
            return some (jsonRawResp 201 (renderManagedMachineItemJson saved))
        else if action == "stop" then
          if m.provider == "boat" then
            discard <| callBoatApi store.rootDir "POST" s!"/sandboxes/{m.id}/stop" none 12000
          match ← applyVmLifecycle mc m.id {
            opCode := Orb.ManagedNode.VmOp.encode .stop, ownerLive := 0, idleElapsed := 0,
            presentedBootEpoch := m.nodeBootEpoch, nowEpoch := nowEpochSec
          } with
          | .error e => return some (jsonErr 409 e)
          | .ok _ => return some (jsonResp 200 (.obj #[("ok", .bool true), ("id", .str m.id), ("state", .str "stopped")]))
        else if action == "resume" then
          if m.provider == "boat" then
            discard <| callBoatApi store.rootDir "POST" s!"/sandboxes/{m.id}/start" none 12000
          match ← applyVmLifecycle mc m.id {
            opCode := Orb.ManagedNode.VmOp.encode .resume, ownerLive := 0, idleElapsed := 0,
            presentedBootEpoch := m.nodeBootEpoch, nowEpoch := nowEpochSec
          } with
          | .error e => return some (jsonErr 409 e)
          | .ok (next, _) =>
            return some (jsonResp 200 (.obj #[("ok", .bool true), ("id", .str m.id), ("state", .str "provisioning"), ("node_boot_epoch", JVal.uint64 next.nodeBootEpoch)]))
        else if action == "destroy" then
          if m.provider == "boat" then
            discard <| callBoatApi store.rootDir "DELETE" s!"/sandboxes/{m.id}" none 12000
          match ← applyVmLifecycle mc m.id {
            opCode := Orb.ManagedNode.VmOp.encode .destroy, ownerLive := 0, idleElapsed := 1,
            presentedBootEpoch := m.nodeBootEpoch, nowEpoch := nowEpochSec
          } with
          | .error e => return some (jsonErr 409 e)
          | .ok _ => return some (jsonResp 200 (.obj #[("ok", .bool true), ("id", .str m.id), ("state", .str "destroyed")]))
      else if method == "DELETE" && segs.length == 3 then
        let some (m, _) ← getManagedMachine? mc sub2
          | return some (jsonErr 404 "managed_machine_not_found")
        if !isAdmin && !isLegacyUnscoped && !m.ownerUserId.isEmpty && m.ownerUserId != callerUserId then
          return some (jsonErr 404 "managed_machine_not_found")
        if m.provider == "boat" then
          discard <| callBoatApi store.rootDir "DELETE" s!"/sandboxes/{m.id}" none 12000
        match ← applyVmLifecycle mc m.id {
          opCode := Orb.ManagedNode.VmOp.encode .destroy, ownerLive := 0, idleElapsed := 1,
          presentedBootEpoch := m.nodeBootEpoch, nowEpoch := nowEpochSec
        } with
        | .error e => return some (jsonErr 409 e)
        | .ok _ => return some (jsonResp 200 (.obj #[("ok", .bool true), ("id", .str m.id), ("state", .str "destroyed")]))

  -- 5. `/api/nodes/:name/{cordon,uncordon,capacity}`
  if method == "POST" && segs.length == 4 && segs[0]? == some "api" && segs[1]? == some "nodes" then
    if !isAdmin then return some (jsonErr 403 "admin_required")
    let nodeName := segs[2]!
    let action := segs[3]!
    if action == "cordon" || action == "uncordon" then
      let cordVal := if action == "cordon" then "1" else "0"
      if let some mid ← resolveManagedMachineId? mc nodeName then
        discard <| execParamQuery mc.db "UPDATE managed_machines SET cordoned=?2 WHERE id=?1;" #[mid, cordVal]
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("node", .str nodeName), ("cordoned", .bool (action == "cordon"))]))
    else if action == "capacity" then
      let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
      let some cap := jv.fieldNat? "capacity"
        | return some (jsonErr 400 "missing_capacity")
      let (_, staticNodes) ← loadStaticRemoteNodes
      let (effNodeId, secret) ← do
        if let some sn := staticNodes.find? (fun n => n.id == nodeName) then
          match ← resolveStaticNodeToken? sn with
          | some tok => pure (sn.id, tok)
          | none => return some (jsonErr 400 "node_token_missing")
        else
          match ← resolveManagedMachineId? mc nodeName with
          | none => return some (jsonErr 404 "unknown_node")
          | some mid =>
            match ← getManagedNodeAuth? mc mid with
            | some pair => pure pair
            | none => return some (jsonErr 400 "node_token_missing")
      let leaseTok := signRemoteNodeLeaseToken secret "00000000-0000-0000-0000-000000000000" effNodeId "node:capacity" (nowEpochSec + 300)
      let mut bodyFields := #[("lease_token", JVal.str leaseTok), ("capacity", JVal.nat cap)]
      if let some cc := jv.fieldNat? "coordinator_capacity" then
        bodyFields := bodyFields.push ("coordinator_capacity", JVal.nat cc)
      match ← callRemoteNodeHttp hub? mc nodeName "POST" "/capacity" (some (.obj bodyFields)) #[] 10000 with
      | .error e => return some (jsonErr 502 e)
      | .ok (st, txt, jv?, _, _) =>
        return some (jsonResp st (jv?.getD (.obj #[("raw", .str txt)])))

  -- 6. `/api/durable-jobs*`
  if segs.length ≥ 2 && segs[0]? == some "api" && segs[1]? == some "durable-jobs" then
    let qMap := parseRawQueryMap rawTarget
    if method == "GET" && segs.length == 2 then
      let mid? := lookupQueryParam? qMap "mission_id"
      let lim := (lookupQueryParam? qMap "limit" >>= String.toNat?).getD 100
      return some (jsonResp 200 (← listDurableJobsJson store mid? lim))
    else if method == "GET" && segs.length == 3 then
      ensureDurableJobsTable store
      let jid := segs[2]!
      match ← execParamQuery store.missionsDb
          "SELECT job_id,mission_id,node_id,state,payload_json,created_at,updated_at FROM remote_node_jobs WHERE job_id=?1;" #[jid] with
      | .ok rows =>
        if rows.size > 1 then
          let r := rows[1]!
          return some (jsonResp 200 (.obj #[
            ("job_id", .str (cell r 0)),
            ("mission_id", .str (cell r 1)),
            ("node_id", .str (cell r 2)),
            ("state", .str (cell r 3)),
            ("created_at", .str (cell r 5)),
            ("updated_at", .str (cell r 6))
          ]))
        else return some (jsonErr 404 "durable_job_not_found")
      | .error e => return some (jsonErr 500 e)
    else if method == "POST" && segs.length == 4 && (segs[3]? == some "cancel" || segs[3]? == some "force") then
      ensureDurableJobsTable store
      let jid := segs[2]!
      let act := segs[3]!
      let nextState := if act == "cancel" then "cancelled" else "running"
      discard <| execParamQuery store.missionsDb
        "UPDATE remote_node_jobs SET state=?2,updated_at=?3 WHERE job_id=?1;"
        #[jid, nextState, nowIso]
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("job_id", .str jid), ("state", .str nextState)]))

  return none

end OrbCore.RemoteFleetAndRelay
