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
import OrbCore.NodeLiveness
import OrbCore.ManagedProvisioning
import OrbCore.ManagedTtl
import OrbCore.ManagedSnapshotCatalog
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

/-! ## `GET /api/compute/fleet`, Enriched `GET /api/remote-nodes`, & Persisted Static Node Cordons -/

/-- Read persisted static-node cordons from `<dataRoot>/node_state.json` (matching Rust `node_state.json`). -/
def loadPersistedNodeCordons (dataRoot : String) : IO (Array String) := do
  let trimmed := dataRoot.trimAscii.toString
  if trimmed.isEmpty then return #[]
  let path := System.FilePath.mk s!"{trimmed}/node_state.json"
  if !(← path.pathExists) then return #[]
  match ← (IO.FS.readFile path).toBaseIO with
  | .error _ => return #[]
  | .ok raw =>
    match OrbBin.Json.parse raw with
    | .ok jv =>
      return ((jv.fieldArr? "cordoned").getD #[]).filterMap JVal.asStr? |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    | .error _ => return #[]

/-- Update persisted static-node cordons in `<dataRoot>/node_state.json`, returning `changed`. -/
def setPersistedNodeCordoned (dataRoot nodeName : String) (cordoned : Bool) : IO Bool := do
  let trimmed := dataRoot.trimAscii.toString
  let cleanNode := nodeName.trimAscii.toString
  if trimmed.isEmpty || cleanNode.isEmpty then return false
  let path := System.FilePath.mk s!"{trimmed}/node_state.json"
  let mut existingObj : Array (String × JVal) := #[]
  if ← path.pathExists then
    if let .ok raw ← (IO.FS.readFile path).toBaseIO then
      if let .ok (.obj fields) := OrbBin.Json.parse raw then
        existingObj := fields.filter (fun (k, _) => k != "cordoned")
  let prev := ← loadPersistedNodeCordons trimmed
  let wasCordoned := prev.contains cleanNode
  if wasCordoned == cordoned then
    return false
  let next :=
    if cordoned then (prev.filter (· != cleanNode)).push cleanNode
    else prev.filter (· != cleanNode)
  let sortedNext := next.qsort (· < ·)
  let outObj := JVal.obj (existingObj.push ("cordoned", .arr (sortedNext.map .str)))
  discard <| (IO.FS.createDirAll (System.FilePath.mk trimmed)).toBaseIO
  discard <| (IO.FS.writeFile path ((renderCompact outObj) ++ "\n")).toBaseIO
  return true

/-- Build server-advertised typed remote launch capabilities (`RemoteLaunchCapabilities`). -/
def buildRemoteLaunchCapabilitiesJVal : IO JVal := do
  let p1 := ((← IO.getEnv "SANDBOXED_PROXY_PUBLIC_URL").getD "").trimAscii.toString
  let p2 := ((← IO.getEnv "SANDBOXED_PUBLIC_URL").getD "").trimAscii.toString
  let proxyConfigured := !p1.isEmpty || !p2.isEmpty
  return .obj #[
    ("typed", .bool true),
    ("harnesses", .arr #[.str "claudecode", .str "opencode", .str "grok", .str "codex", .str "antigravity", .str "vibe"]),
    ("requires_proxy_harnesses", .arr #[.str "claudecode", .str "opencode", .str "codex", .str "vibe"]),
    ("raw_command", .bool true),
    ("proxy_url_configured", .bool proxyConfigured),
    ("error_prefixes", .arr #[
      .str "REMOTE_HARNESS_UNSUPPORTED",
      .str "REMOTE_PROMPT_REQUIRED",
      .str "REMOTE_MODEL_REQUIRED",
      .str "REMOTE_GOAL_UNSUPPORTED",
      .str "REMOTE_AUTH_REQUIRED"
    ])
  ]

private def optNatJVal (v? : Option Nat) : JVal :=
  match v? with
  | some n => JVal.nat n
  | none => .null

private def optUInt64JVal (v? : Option UInt64) : JVal :=
  match v? with
  | some n => JVal.uint64 n
  | none => .null

private def optStrJVal (v? : Option String) : JVal :=
  match v? with
  | some s => .str s
  | none => .null

private def optBoolJVal (v? : Option Bool) : JVal :=
  match v? with
  | some b => .bool b
  | none => .null

def probeStaticNodeHeartbeat
    (sn : StaticRemoteNode)
    (persistedCordons : Array String := #[])
    (nowIso : String := "") : IO JVal := do
  let persistedCordoned := persistedCordons.contains sn.id
  let baseColocated :=
    sn.id == "sepolia" || sn.id == "agent-core" || sn.id == "orb-core" ||
    sn.baseUrl.contains "10.88.0.1:" || sn.baseUrl.endsWith "10.88.0.1" ||
    sn.baseUrl.contains "127.0.0.1" || sn.labels.contains "control-plane"
  let baseAdminOnly :=
    baseColocated || sn.id == "dgx-spark-admin" ||
    sn.labels.contains "administration" || sn.labels.contains "admin-only"
  let mkOfflineOrDegraded (statusStr errMsg : String) : JVal :=
    .obj #[
      ("resource_history", .arr #[]),
      ("id", .str sn.id),
      ("name", .str sn.id),
      ("kind", .str "static"),
      ("base_url", .str sn.baseUrl),
      ("token_env", .str sn.tokenEnv),
      ("status", .str statusStr),
      ("labels", .arr (sn.labels.map .str)),
      ("version", .null),
      ("protocol_version", .null),
      ("capacity_total", .null),
      ("capacity_available", .null),
      ("active_leases", .null),
      ("active_jobs", .null),
      ("queued_jobs", .null),
      ("available_slots", JVal.nat 0),
      ("cpu_total", .null),
      ("mem_total_bytes", .null),
      ("mem_available_bytes", .null),
      ("disk_total_bytes", .null),
      ("disk_available_bytes", .null),
      ("disk_pressure_pinned", .bool false),
      ("cached_toolchains", .arr #[]),
      ("lean_runtime_ready", .null),
      ("source_bundle_capacity", .null),
      ("last_seen", .null),
      ("error", .str errMsg),
      ("cordoned", .bool persistedCordoned),
      ("quarantined_harnesses", .arr #[]),
      ("admin_only", .bool baseAdminOnly),
      ("core_colocated", .bool baseColocated)
    ]
  match ← resolveStaticNodeToken? sn with
  | none =>
    return mkOfflineOrDegraded "degraded" s!"missing token env {sn.tokenEnv}"
  | some tok =>
    match ← sendJsonRequest "GET" (sn.baseUrl ++ "/heartbeat") (some tok) none #[] 2500 with
    | .ok (200, _, some hb) =>
      let cap := (hb.fieldNat? "capacity_total").orElse (fun _ => hb.fieldNat? "capacity") |>.getD 4
      let act := (hb.fieldNat? "active_jobs").orElse (fun _ => hb.fieldNat? "running_jobs") |>.getD 0
      let qd := (hb.fieldNat? "queued_jobs").getD 0
      let availSlots :=
        match hb.fieldNat? "capacity_available" with
        | some av => av
        | none => if cap > act then cap - act else 0
      let actLeases := (hb.fieldNat? "active_leases").getD act
      let hbLabels := ((hb.fieldArr? "labels").getD #[]).filterMap JVal.asStr?
      let rawLabels := if hbLabels.isEmpty then sn.labels else hbLabels
      let leanReady? := hb.fieldBool? "lean_runtime_ready"
      let effLabels :=
        if leanReady? == some false then rawLabels.filter (· != "lean") else rawLabels
      let effColocated := baseColocated || effLabels.contains "control-plane"
      let effAdminOnly :=
        (hb.fieldBool? "admin_only").getD
          (baseAdminOnly || effColocated || effLabels.contains "administration" || effLabels.contains "admin-only")
      let effCordoned := persistedCordoned || ((hb.fieldBool? "cordoned").getD false)
      let toolchains := ((hb.fieldArr? "cached_toolchains").getD #[]).filterMap JVal.asStr?
      let resHist := (hb.fieldArr? "resource_history").getD #[]
      let lastSeenVal :=
        if !nowIso.isEmpty then JVal.str nowIso
        else optStrJVal (hb.fieldStr? "timestamp")
      let mut fields : Array (String × JVal) := #[
        ("resource_history", .arr resHist),
        ("id", .str sn.id),
        ("name", .str sn.id),
        ("kind", .str "static"),
        ("base_url", .str sn.baseUrl),
        ("token_env", .str sn.tokenEnv),
        ("status", .str "online"),
        ("labels", .arr (effLabels.map .str)),
        ("version", optStrJVal (hb.fieldStr? "version")),
        ("protocol_version", optNatJVal (hb.fieldNat? "protocol_version")),
        ("capacity_total", JVal.nat cap),
        ("capacity_available", JVal.nat availSlots),
        ("available_slots", JVal.nat availSlots),
        ("active_leases", JVal.nat actLeases),
        ("active_jobs", JVal.nat act),
        ("queued_jobs", JVal.nat qd),
        ("coordinator_capacity", optNatJVal (hb.fieldNat? "coordinator_capacity")),
        ("cpu_total", optNatJVal (hb.fieldNat? "cpu_total")),
        ("mem_total_bytes", optUInt64JVal (hb.fieldUInt64? "mem_total_bytes")),
        ("mem_available_bytes", optUInt64JVal (hb.fieldUInt64? "mem_available_bytes")),
        ("disk_total_bytes", optUInt64JVal (hb.fieldUInt64? "disk_total_bytes")),
        ("disk_available_bytes", optUInt64JVal (hb.fieldUInt64? "disk_available_bytes")),
        ("disk_pressure_pinned", .bool ((hb.fieldBool? "disk_pressure_pinned").getD false)),
        ("cached_toolchains", .arr (toolchains.map .str)),
        ("lean_runtime_ready", optBoolJVal leanReady?),
        ("source_bundle_capacity", (hb.field? "source_bundle_capacity").getD .null),
        ("last_seen", lastSeenVal),
        ("error", .null),
        ("cordoned", .bool effCordoned),
        ("quarantined_harnesses", .arr #[]),
        ("admin_only", .bool effAdminOnly),
        ("core_colocated", .bool effColocated),
        ("heartbeat", hb)
      ]
      if let some fj := hb.fieldNat? "forced_jobs" then
        if fj > 0 then fields := fields.push ("forced_jobs", JVal.nat fj)
      if let some pj := hb.fieldNat? "priority_jobs" then
        if pj > 0 then fields := fields.push ("priority_jobs", JVal.nat pj)
      if let some mf := hb.fieldUInt64? "min_free_disk_bytes" then
        fields := fields.push ("min_free_disk_bytes", JVal.uint64 mf)
      return .obj fields
    | .ok (code, txt, _) =>
      return mkOfflineOrDegraded "degraded" s!"HTTP {code}: {(txt.take 120).toString}"
    | .error err =>
      return mkOfflineOrDegraded "offline" err

/-- Probe all configured static nodes concurrently so 9 nodes complete in a single ~15ms RTT. -/
def probeAllStaticNodesParallel
    (staticNodes : Array StaticRemoteNode)
    (persistedCordons : Array String)
    (nowIso : String) : IO (Array JVal) := do
  if staticNodes.isEmpty then return #[]
  let mut tasks : Array (Task (Except IO.Error JVal)) := Array.mkEmpty staticNodes.size
  for sn in staticNodes do
    let t ← IO.asTask (prio := .dedicated) (probeStaticNodeHeartbeat sn persistedCordons nowIso)
    tasks := tasks.push t
  let mut out : Array JVal := Array.mkEmpty tasks.size
  for i in [0:tasks.size] do
    match tasks[i]!.get with
    | .ok jv => out := out.push jv
    | .error e =>
      let sn := staticNodes[i]!
      out := out.push (.obj #[
        ("id", .str sn.id),
        ("name", .str sn.id),
        ("kind", .str "static"),
        ("base_url", .str sn.baseUrl),
        ("token_env", .str sn.tokenEnv),
        ("status", .str "offline"),
        ("labels", .arr (sn.labels.map .str)),
        ("cordoned", .bool (persistedCordons.contains sn.id)),
        ("error", .str (toString e))
      ])
  return out

/-- Last successful heartbeat per static node (`<dataRoot>/node_heartbeats.json`). -/
def loadNodeHeartbeatCache (dataRoot : String) : IO JVal := do
  let trimmed := dataRoot.trimAscii.toString
  if trimmed.isEmpty then return .obj #[]
  match ← (IO.FS.readFile s!"{trimmed}/node_heartbeats.json").toBaseIO with
  | .error _ => return .obj #[]
  | .ok raw =>
    match OrbBin.Json.parse raw with
    | .ok (.obj fields) => return .obj fields
    | _ => return .obj #[]

/-- Written through a temporary file and a rename, so a concurrent reader never
    sees a partial cache. Skipped when nothing changed. -/
def saveNodeHeartbeatCache (dataRoot : String) (previous next : JVal) : IO Unit := do
  let trimmed := dataRoot.trimAscii.toString
  if trimmed.isEmpty || previous == next then return
  let path := s!"{trimmed}/node_heartbeats.json"
  let tmp := s!"{path}.{← newUuidV4}.tmp"
  match ← (IO.FS.writeFile tmp (renderCompact next ++ "\n")).toBaseIO with
  | .error _ => pure ()
  | .ok () =>
    if let .error _ ← (IO.FS.rename tmp path).toBaseIO then
      discard <| (IO.FS.removeFile tmp).toBaseIO

/-- Non-terminal jobs per node in Core's ledger. -/
def activeJobsByNode (store : CoreStore) : IO (Array (String × Nat)) := do
  match ← execParamQuery store.missionsDb
      ("SELECT node_id, COUNT(*) FROM remote_node_jobs WHERE state NOT IN " ++
       "('terminal','completed','succeeded','failed','aborted','cancelled','lost') GROUP BY node_id;") #[] with
  | .ok rows => return (rows.extract 1 rows.size).map fun row => (cell row 0, ((cell row 1).toNat?).getD 0)
  | .error _ => return #[]

def buildComputeFleetJVal
    (hub? : Option RelayHub)
    (_mc? : Option ManagedComputeStore)
    (fleet : ManagedFleetState)
    (callerUserId? : Option String := none)
    (userSpentTodayCents : UInt64 := 0)
    (userDailyCapCents? : Option UInt64 := none)
    (dataRoot : String := "")
    (nowIso : String := "")
    (store? : Option CoreStore := none) : IO JVal := do
  let (rnEnabled, staticNodes) ← loadStaticRemoteNodes
  let nowSec ← nowEpoch
  let effIso := if nowIso.isEmpty then formatEpochIso8601Utc nowSec else nowIso
  let persistedCordons ← loadPersistedNodeCordons dataRoot
  let probed ← probeAllStaticNodesParallel staticNodes persistedCordons effIso
  -- A node that did not answer keeps what its last heartbeat reported.
  let heartbeatCache ← loadNodeHeartbeatCache dataRoot
  let staticItems := probed.map (NodeLiveness.applyCache heartbeatCache)
  saveNodeHeartbeatCache dataRoot heartbeatCache (NodeLiveness.updateCache heartbeatCache probed)
  let jobLoad ← match store? with
    | some store => activeJobsByNode store
    | none => pure #[]
  let visibleMachines :=
    match callerUserId? with
    | none => fleet.machines
    | some uid => fleet.machines.filter (fun m => m.ownerUserId == uid || m.ownerUserId.isEmpty)
  let mut managedItems : Array JVal := #[]
  for m in visibleMachines do
    if m.status != "destroyed" then
      let hubSeen? ← match hub? with
        | some h => getMachineLastSeen? h m.id
        | none => pure none
      -- The persisted poll counts too, so a Core restart does not erase liveness.
      let seenSec? := NodeLiveness.lastSeen hubSeen? m.lastPollSec
      let relayConnected := NodeLiveness.relayConnected seenSec? nowSec
      let nodeStatus := NodeLiveness.managedStatus m.status seenSec? nowSec
      let sizeSpec? := managedSizeSpec? m.provider m.size
      let activeJobs := ((jobLoad.find? (·.1 == s!"managed-{m.id}")).map (·.2)).getD 0
      let ownerKind :=
        if !m.ownerMission.isEmpty then "mission"
        else if m.ownerKind.isEmpty then "user"
        else m.ownerKind
      let lastSeenVal :=
        match seenSec? with
        | some s => JVal.str (formatEpochIso8601Utc s)
        | none => .null
      managedItems := managedItems.push (.obj #[
        ("resource_history", .arr #[]),
        ("id", .str s!"managed-{m.id}"),
        ("display_name", .str m.sandboxName),
        ("machine_id", .str m.id),
        ("name", .str m.sandboxName),
        ("sandbox_name", .str m.sandboxName),
        ("kind", .str "managed"),
        ("provider", .str m.provider),
        ("size", .str m.size),
        ("owner_kind", .str ownerKind),
        ("base_url", .str ""),
        ("token_env", .str ""),
        ("status", .str nodeStatus),
        ("state", .str m.status),
        ("relay_connected", .bool relayConnected),
        ("cordoned", .bool m.cordoned),
        ("owner_mission", .str m.ownerMission),
        ("node_boot_epoch", JVal.uint64 m.nodeBootEpoch),
        ("deletable_at", JVal.uint64 m.deletableAtSec),
        ("spent_cents", JVal.uint64 m.spentCents),
        ("version", .null),
        ("capacity_total", JVal.nat 2),
        ("capacity_available", JVal.nat (if nodeStatus == "online" then 2 else 0)),
        ("active_jobs", JVal.nat activeJobs),
        ("queued_jobs", JVal.nat 0),
        ("cpu_total", match sizeSpec? with | some spec => JVal.nat spec.cpu | none => .null),
        ("mem_total_bytes", match sizeSpec? with
          | some spec => JVal.uint64 (spec.ramGb.toUInt64 * 1024 * 1024 * 1024)
          | none => .null),
        ("mem_available_bytes", .null),
        ("disk_total_bytes", match sizeSpec? with
          | some spec => JVal.uint64 (spec.diskGb.toUInt64 * 1024 * 1024 * 1024)
          | none => .null),
        ("disk_available_bytes", .null),
        ("last_seen", lastSeenVal),
        ("error", .null),
        ("labels", .arr #[.str "managed", .str s!"provider={m.provider}", .str s!"owner={ownerKind}"])
      ])
  let rawBudget :=
    (OrbBin.Json.parse (renderManagedBudgetJson fleet callerUserId? userSpentTodayCents userDailyCapCents?)).toOption.getD (.obj #[])
  let activeManagedCount := (visibleMachines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
  let defaultSubTarget := if fleet.boatEnabled then "auto-managed:boat" else "auto"
  let budgetFields :=
    match rawBudget with
    | .obj fs =>
      let filtered := fs.filter (fun (k, _) => k != "default_subagent_target" && k != "active_machines")
      filtered ++ #[("default_subagent_target", .str defaultSubTarget), ("active_machines", JVal.nat activeManagedCount)]
    | _ => #[
        ("enabled", .bool fleet.enabled),
        ("boat_enabled", .bool fleet.boatEnabled),
        ("default_subagent_target", .str defaultSubTarget),
        ("active_machines", JVal.nat activeManagedCount),
        ("max_concurrent", JVal.uint64 fleet.maxConcurrent)
      ]
  let remoteLaunch ← buildRemoteLaunchCapabilitiesJVal
  let allNodes := staticItems ++ managedItems
  let sparkConfigured := staticNodes.any (fun n => n.id == "dgx-spark")
  return .obj #[
    ("enabled", .bool (rnEnabled || fleet.enabled)),
    ("remote_nodes_enabled", .bool rnEnabled),
    ("nodes", .arr allNodes),
    ("static_nodes", .arr staticItems),
    ("managed_nodes", .arr managedItems),
    ("recent_jobs", .arr #[]),
    ("spark_offload", .obj #[("configured", .bool sparkConfigured), ("enabled_workspaces", .arr #[])]),
    ("remote_launch", remoteLaunch),
    ("managed_compute", .obj budgetFields)
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

/-- Resolve credentials only inside Core; unsupported providers never create fake rows. -/
def resolveManagedProvider (dataRoot provider : String) : IO (Except String ManagedProvider.Provider) := do
  let prov := canonicalizeProvider provider
  let some entry := ManagedProvider.declaration? prov
    | return .error "managed_provider_not_implemented"
  let key? ← if prov == "boat" then getBoatApiKey? dataRoot dataRoot
    else do
      match ← openProviderSecret dataRoot prov false true with
      | .ok key => pure (some key)
      | .error _ => pure none
  let some key := key? | return .error (prov ++ "_api_key_not_configured")
  let base := trimTrailingSlashes (((← IO.getEnv entry.apiBaseEnv).getD entry.defaultApiBase).trimAscii.toString)
  return .ok (entry.create (ManagedProvider.httpTransport base key))

/-- One live catalog projection for REST and MCP. Availability never writes a toggle. -/
def loadManagedProviderCatalog (mc : ManagedComputeStore) (dataRoot : String)
    (fleet : ManagedFleetState) (isAdmin : Bool) (prefs : Array (String × Bool))
    (override? : Option ManagedProvider.Provider := none) : IO (Except String JVal) := do
  let .ok disabled ← ManagedProviderSettings.disabled mc
    | return .error "managed_provider_settings_unavailable"
  let mut configured : Array String := #[]
  let mut observations : Array (String × JVal) := #[]
  for name in knownProviders do
    if let .ok _ ← openProviderSecret dataRoot name false true then
      configured := configured.push name
    let resolved : Except String ManagedProvider.Provider ← match override? with
      | some provider => pure (if provider.name == name then .ok provider else .error "mock_provider_unconfigured")
      | none => resolveManagedProvider dataRoot name
    let observed : ManagedProvider.Availability ← match resolved with
      | .error _ => pure { status := .unknown, reason := "provider_unconfigured_or_unimplemented" }
      | .ok provider => do
        match ← provider.availability { name := "", size := "", ttlSeconds := 300, idempotencyKey := "" } with
        | .ok value => pure value
        | .error _ => pure { status := .unknown, reason := "provider_availability_unavailable" }
    observations := observations.push (name, ManagedProvider.availabilityJson observed)
  match OrbBin.Json.parse (renderManagedProvidersJson fleet isAdmin prefs configured disabled observations) with
  | .ok value => return .ok value
  | .error _ => return .error "managed_provider_catalog_invalid"

def loadManagedBootstrapConfig : IO (Except String ManagedProvisioning.BootstrapConfig) := do
  let coreUrl := (← IO.getEnv "SANDBOXED_MANAGED_CORE_URL").getD
    ((← IO.getEnv "SANDBOXED_PUBLIC_URL").getD "")
  let configuredPath := (← IO.getEnv "ORB_NODE_PROVISION_SCRIPT").getD "/usr/local/lib/orb/orb-node-provision.sh"
  for path in #[configuredPath, "scripts/orb-node-provision.sh"] do
    if let .ok script ← (IO.FS.readFile path).toBaseIO then
      if !script.trimAscii.toString.isEmpty then
        return .ok { coreUrl := coreUrl.trimAscii.toString, script }
  return .error "managed_bootstrap_script_missing"

def quoteManagedSpawnCents (provider size : String) (ttlMinutes : UInt64)
    (override? : Option ManagedProvider.Provider := none) : Except String UInt64 := do
  let quote := match ManagedProvider.declaration? provider with
    | some entry => entry.quoteCents size ttlMinutes
    | none => match override? with
      | some p => if p.name == provider then p.quoteCents size ttlMinutes
        else .error { code := "managed_provider_unavailable" }
      | none => .error { code := "managed_provider_not_implemented" }
  match quote with
  | .ok cents => return cents
  | .error e => throw e.code

/-- Saved snapshots of one project, from the provider's own list. -/
def projectSnapshotEntries (store : CoreStore) (provider : ManagedProvider.Provider) (project : String) :
    IO (Except String (Array ManagedSnapshotCatalog.Entry)) := do
  let inventory ← match ← provider.listSnapshots with
    | .ok items => pure items
    | .error e => return .error s!"managed_snapshot_list_failed:{e.code}:{e.status}"
  let registry ← match ← (IO.FS.readFile s!"{store.rootDir}/managed_snapshots.json").toBaseIO with
    | .ok raw => pure (ManagedSnapshotCatalog.parseLegacyRegistry raw)
    | .error _ => pure #[]
  let known ← match ← execParamQuery store.missionsDb
      "SELECT DISTINCT project FROM missions WHERE COALESCE(project,'')<>'';" #[] with
    | .ok rows => pure ((rows.extract 1 rows.size).map (cell · 0))
    | .error _ => pure #[]
  return .ok (ManagedSnapshotCatalog.visible inventory registry (known ++ registry.map (·.project)) project)

def resolveProjectSnapshot (store : CoreStore) (provider : ManagedProvider.Provider)
    (project requested : String) : IO (Except String String) := do
  if project.trimAscii.toString.isEmpty then return .error "managed_snapshot_requires_project"
  match ← projectSnapshotEntries store provider project with
  | .error e => return .error e
  | .ok entries => return ManagedSnapshotCatalog.resolve entries requested

/-- Save a running machine as a snapshot of `project`. The provider name carries
    the project, so the snapshot is listed, restored and deleted only inside it. -/
def saveProjectSnapshot (store : CoreStore) (provider : ManagedProvider.Provider)
    (project : String) (machine : ManagedMachine) (label : String) :
    IO (Except String ManagedSnapshotCatalog.Entry) := do
  let suffix := ((← newUuidV4).take 4).toString
  let name ← match ManagedSnapshotCatalog.newName project label suffix with
    | .ok n => pure n
    | .error e => return .error e
  let existing ← match ← projectSnapshotEntries store provider project with
    | .ok entries => pure entries
    | .error e => return .error e
  if ManagedSnapshotCatalog.labelTaken existing label then return .error "managed_snapshot_label_exists"
  -- Remove this VM's own credential files and flush. A snapshot that might
  -- still carry them is not taken.
  match ← provider.exec machine.effectiveProviderId ManagedSnapshotCatalog.preSaveCommand 30 with
  | .error _ => return .error "managed_snapshot_scrub_failed"
  | .ok reply =>
    let code := (reply.fieldInt? "exitCode").orElse (fun _ => reply.fieldInt? "exit_code")
      |>.orElse (fun _ => reply.fieldInt? "code")
    if code.any (· != 0) then return .error "managed_snapshot_scrub_failed"
  if let .error e ← provider.saveSnapshot machine.effectiveProviderId name then
    return .error s!"managed_snapshot_save_failed:{e.code}:{e.status}"
  let (status, sizeBytes) ← match ← provider.getSnapshot name with
    | .ok snap => pure (snap.status, snap.sizeBytes)
    | .error _ => pure ("saving", none)
  return .ok {
    name
    label := ManagedSnapshotCatalog.slug label 32
    project := ManagedSnapshotCatalog.slug project
    status
    sizeBytes
  }

/-- Delete one snapshot of `project`, named by provider name or label. A name
    outside the project is not found, whatever the provider holds. -/
def deleteProjectSnapshot (store : CoreStore) (provider : ManagedProvider.Provider)
    (project requested : String) : IO (Except String String) := do
  if project.trimAscii.toString.isEmpty then return .error "managed_snapshot_requires_project"
  let entries ← match ← projectSnapshotEntries store provider project with
    | .ok entries => pure entries
    | .error e => return .error e
  let name ← match ManagedSnapshotCatalog.resolveForDelete entries requested with
    | .ok n => pure n
    | .error e => return .error e
  match ← provider.deleteSnapshot name with
  | .ok () => return .ok name
  | .error e => return .error s!"managed_snapshot_delete_failed:{e.code}:{e.status}"

/-- Everything a configured spawn decides before it reserves or rents: the
    provider and bootstrap configuration, the image or resolved snapshot, and the
    provider request. Shared by the spawn itself and its synchronous preflight. -/
def prepareConfiguredManagedSpawn (dataRoot : String) (machine : ManagedMachine) (args : JVal)
    (idempotencyKey : String := "")
    (override? : Option (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig) := none)
    (resolvedSnapshot : String := "") :
    IO (Except String (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig × ManagedProvider.SpawnSpec)) := do
  let (provider, bootstrap) ← match override? with
    | some pair => pure pair
    | none => do
      let .ok provider ← resolveManagedProvider dataRoot machine.provider
        | return .error "managed_provider_unavailable"
      let .ok bootstrap ← loadManagedBootstrapConfig
        | return .error "managed_bootstrap_configuration_unavailable"
      pure (provider, bootstrap)
  let requestedSnapshot := (args.fieldStr? "from_snapshot").orElse (fun _ => args.fieldStr? "managed_from_snapshot")
    |>.getD ""
  -- A caller-supplied label never reaches the provider. Only a name the entry point
  -- resolved inside the caller's own project (`resolveProjectSnapshot`) is restored.
  if !requestedSnapshot.trimAscii.toString.isEmpty && resolvedSnapshot.isEmpty then
    return .error "managed_snapshot_scope_unresolved"
  let baseImage := (args.fieldStr? "image").getD "orb-node-base"
  if resolvedSnapshot.isEmpty && baseImage != "orb-node-base" && baseImage != "provider-default" then
    return .error "managed_image_not_allowlisted"
  let fromImage := if resolvedSnapshot.isEmpty then baseImage else resolvedSnapshot
  let key := if idempotencyKey.isEmpty then
    ((args.fieldStr? "idempotency_key").filter (!·.isEmpty)).getD machine.id
    else idempotencyKey
  let scopedKey := bytesToHexLower (sha256Bytes (renderCompact (.arr #[
    .str machine.ownerUserId, .str machine.ownerMission, .str key
  ])).toUTF8)
  let spec : ManagedProvider.SpawnSpec := {
    name := machine.sandboxName
    size := machine.size
    ttlSeconds := machine.ttlMinutes * 60
    idempotencyKey := scopedKey
    fromSnapshot := fromImage
    repo := (args.fieldStr? "repo").getD ""
    memoryMiB := args.fieldUInt64? "memory_mib"
  }
  return .ok (provider, bootstrap, spec)

/-- Refuse, before a receipt is accepted, what the spawn would refuse without
    renting: bad configuration, an unlisted image, a disabled provider, no capacity. -/
def preflightConfiguredManagedSpawn (mc : ManagedComputeStore) (dataRoot : String)
    (fleet : ManagedFleetState) (machine : ManagedMachine) (args : JVal)
    (override? : Option (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig) := none)
    (resolvedSnapshot : String := "") : IO (Except String Unit) := do
  match ← prepareConfiguredManagedSpawn dataRoot machine args "" override? resolvedSnapshot with
  | .error e => return .error e
  | .ok (provider, _, spec) => ManagedProvisioning.preflightAvailability mc fleet provider spec

/-- REST, MCP and automatic placement share admission, provider create, guest
    installation, enrollment, relay readiness, and failure cleanup. -/
def spawnConfiguredManagedWorker (mc : ManagedComputeStore) (dataRoot : String)
    (fleet : ManagedFleetState) (machine : ManagedMachine) (args : JVal)
    (idempotencyKey : String := "")
    (override? : Option (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig) := none)
    (userAdmission? : Option ManagedUserAdmission := none)
    (resolvedSnapshot : String := "")
    (forkOfProviderId : String := "") :
    IO (Except String ManagedProvisioning.SpawnResult) := do
  match ← prepareConfiguredManagedSpawn dataRoot machine args idempotencyKey override? resolvedSnapshot with
  | .error e => return .error e
  | .ok (provider, bootstrap, spec) =>
    -- A fork is a spawn whose disk comes from a running machine: the same
    -- reservation, admission, bootstrap and readiness rules apply to it.
    let provider := if forkOfProviderId.isEmpty then provider else
      { provider with spawn := fun forkSpec => provider.fork forkOfProviderId forkSpec }
    ManagedProvisioning.spawnManagedWorker mc fleet machine provider spec bootstrap {} userAdmission?

/-- Reconcile only Core-owned records against a complete provider list. Exact
    names repair pre-cutover bindings; known IDs and boot epochs fence stale lists.
    Provider readiness never substitutes for an authenticated relay poll. -/
def reconcileManagedProviderInventory (mc : ManagedComputeStore) (providerName servicePrefix : String)
    (inventory : Array ManagedProvider.Machine) (nowEpoch : UInt64) : IO (Except String JVal) := do
  let .ok fleet ← loadManagedFleet mc false false 0 0 100 | return .error "managed_inventory_read_failed"
  let completeNames := inventory.all (fun remote => !remote.name.trimAscii.toString.isEmpty)
  let mut backfilled : Array JVal := #[]
  let mut stopped : Array JVal := #[]
  let mut closed : Array JVal := #[]
  let mut ambiguous : Array JVal := #[]
  let mut missing : Array JVal := #[]
  for m in fleet.machines do
    if canonicalizeProvider m.provider != providerName then continue
    let canonicalName := servicePrefix ++ m.id
    let ownRecordedName := !m.sandboxName.isEmpty && m.sandboxName.startsWith servicePrefix
    let candidates := inventory.filter fun remote =>
      if !m.providerId.isEmpty then remote.providerId == m.providerId
      else remote.name == canonicalName || (ownRecordedName && remote.name == m.sandboxName)
    let candidates := candidates.foldl (fun acc remote =>
      if acc.any (fun other => other.providerId == remote.providerId) then acc else acc.push remote)
      (#[] : Array ManagedProvider.Machine)
    if candidates.size > 1 then
      ambiguous := ambiguous.push (.str m.id)
      continue
    if let some remote := candidates[0]? then
      if m.providerId.isEmpty then
        if let .error _ ← backfillManagedProviderIdentity mc m.id providerName remote.providerId then
          ambiguous := ambiguous.push (.str m.id)
          continue
        backfilled := backfilled.push (.str m.id)
      let .ok observed := observeProviderPayload providerName m.id 200 (.obj #[("state", .str remote.state)])
        | continue
      let observed := { observed with expectedProviderId? := some remote.providerId, expectedBootEpoch? := some m.nodeBootEpoch }
      if observed.observedStatus == "stopped" && (m.status == "ready" ||
          (observed.retainedArchived && (m.status == "destroyed" || m.status == "provisioning"))) then
        if (← applyProviderObservation mc observed nowEpoch 0 1).isOk then stopped := stopped.push (.str m.id)
      else if observed.orphaned then
        if (← applyProviderObservation mc observed nowEpoch 0 1).isOk then closed := closed.push (.str m.id)
    else
      missing := missing.push (.str m.id)
      -- A timed-out, unbound reservation with no matching sandbox can close
      -- locally. Unknown legacy names remain visible for operator investigation.
      if completeNames && m.providerId.isEmpty && m.status == "provisioning" && m.createdAtSec > 0 &&
          !inventory.any (fun remote => remote.name == m.sandboxName) &&
          nowEpoch ≥ m.createdAtSec + 360 then
        let observed : ProviderObservation := {
          provider := providerName, machineId := m.id, observedStatus := "destroyed", orphaned := true,
          expectedProviderId? := some "", expectedBootEpoch? := some m.nodeBootEpoch
        }
        if (← applyProviderObservation mc observed nowEpoch 0 1).isOk then closed := closed.push (.str m.id)
  return .ok (.obj #[("backfilled", .arr backfilled), ("stopped", .arr stopped),
    ("closed", .arr closed), ("ambiguous", .arr ambiguous), ("missing", .arr missing)])

def boatInventoryNeeded (fleet : ManagedFleetState) (checkedDestroyed : Array String) : Bool :=
  fleet.boatEnabled || fleet.machines.any (fun m => canonicalizeProvider m.provider == "boat" &&
    (m.status != "destroyed" || !checkedDestroyed.contains m.id))

def reconcileConfiguredBoatInventory (mc : ManagedComputeStore) (dataRoot : String)
    (nowEpoch : UInt64) (override? : Option ManagedProvider.Provider := none) : IO (Except String JVal) := do
  let provider ← match override? with
    | some p => pure p
    | none => do
      let .ok p ← resolveManagedProvider dataRoot "boat" | return .error "boat_provider_unavailable"
      pure p
  if provider.name != "boat" then return .error "managed_provider_mismatch"
  let .ok inventory ← provider.list | return .error "boat_inventory_unavailable"
  reconcileManagedProviderInventory mc "boat" (sandboxNamePrefixFor (← IO.appPath).toString) inventory nowEpoch

structure ManagedLifecycleContext where
  store : CoreStore
  fleet : ManagedFleetState := {}
  override? : Option (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig) := none

def loadManagedUserAdmission (store : CoreStore) (userId : String) (nowEpoch : UInt64) :
    IO (Except String (Option ManagedUserAdmission)) := do
  if userId.isEmpty then return .ok none
  -- User ids are not secrets; naming the missing one makes a stale owner diagnosable.
  let some user ← getUserById? store userId | return .error s!"managed_user_missing:{userId}"
  if user.disabled then return .error s!"managed_user_disabled:{userId}"
  let some cap := user.dailySpendCapCents? | return .ok none
  let (inf, cmp) ← getUserSpentTodayCents store userId (formatEpochIso8601Utc nowEpoch |>.take 10 |>.toString)
  return .ok (some { capCents := cap, inferenceCents := inf, computeCents := cmp })

/-- Pre-cutover rows carry a tenant label (for example `prod`) instead of a user id.
    Where the owning mission names a real user, adopt it. Rows whose mission has no
    such owner are left as they are; nothing is guessed. Idempotent. -/
def repairManagedMachineOwners (store : CoreStore) (mc : ManagedComputeStore) : IO Nat := do
  let .ok owners ← execParamQuery mc.db
      "SELECT DISTINCT owner_user_id FROM managed_machines WHERE owner_user_id<>'';" #[] | return 0
  let mut repaired := 0
  for i in [1:owners.size] do
    let stale := cell owners[i]! 0
    if (← getUserById? store stale).isSome then continue
    let .ok machines ← execParamQuery mc.db
        "SELECT id,owner_mission FROM managed_machines WHERE owner_user_id=?1 AND owner_mission<>'';" #[stale] | continue
    for j in [1:machines.size] do
      let machineId := cell machines[j]! 0
      let .ok missionRows ← execParamQuery store.missionsDb
          "SELECT COALESCE(owner_user_id,'') FROM missions WHERE id=?1;" #[cell machines[j]! 1] | continue
      if missionRows.size < 2 then continue
      let owner := cell missionRows[1]! 0
      if owner.isEmpty || owner == stale || (← getUserById? store owner).isNone then continue
      if let .ok _ ← execParamQuery mc.db
          "UPDATE managed_machines SET owner_user_id=?2 WHERE id=?1 AND owner_user_id=?3;" #[machineId, owner, stale] then
        discard <| execParamQuery mc.db
          "UPDATE managed_cost_reservations SET owner_user_id=?2 WHERE machine_id=?1 AND owner_user_id=?3;" #[machineId, owner, stale]
        repaired := repaired + 1
  return repaired

private def managedLifecycleResult (m : ManagedMachine) : JVal :=
  .obj #[("ok", .bool true), ("id", .str m.id), ("state", .str m.status),
    ("machine", (OrbBin.Json.parse (renderManagedMachineItemJson m)).toOption.getD .null)]

/-- One lifecycle implementation for REST and MCP. A resume is not committed
    until the successor's authenticated first poll; provider failures propagate. -/
def runConfiguredManagedLifecycle (mc : ManagedComputeStore) (ctx : ManagedLifecycleContext)
    (machineId action : String) (nowEpoch : UInt64) (args : JVal := .obj #[])
    (retryKey : String := "") : IO (Except String JVal) := do
  let some (m, slice) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
  let ttl := (args.fieldUInt64? "ttl_minutes").getD 60
  let resumeKey ← if action == "resume" then do
      let rawKey ← if !retryKey.isEmpty then pure retryKey else
        match (args.fieldStr? "idempotency_key").filter (!·.isEmpty) with
        | some key => pure key
        | none => newUuidV4
      pure (bytesToHexLower (sha256Bytes (renderCompact (.arr #[.str "managed-resume", .str m.id, .str m.ownerUserId, .str rawKey])).toUTF8))
    else pure ""
  if action == "resume" then
    match ← ManagedProvisioning.replayManagedResume mc machineId resumeKey ttl with
    | .error e => return .error e
    | .ok (some current) => return .ok (managedLifecycleResult current)
    | .ok none => pure ()
  let provider ← match ctx.override? with
    | some pair => pure pair.1
    | none => do
      let .ok p ← resolveManagedProvider ctx.store.rootDir m.provider | return .error "managed_provider_unavailable"
      pure p
  if provider.name != m.provider then return .error "managed_provider_mismatch"
  if action == "extend" then
    if ctx.override?.isNone then
      let some entry := ManagedProvider.declaration? m.provider | return .error "managed_provider_unavailable"
      if !entry.supportsExtend then return .error "managed_provider_extend_unsupported"
    let budget ← match ← loadManagedUserAdmission ctx.store m.ownerUserId nowEpoch with
      | .ok value => pure value
      | .error e => return .error e
    let .ok fleet ← loadManagedFleet mc ctx.fleet.enabled ctx.fleet.boatEnabled ctx.fleet.dailyCapCents
        ctx.fleet.spentTodayCents ctx.fleet.maxConcurrent | return .error "managed_fleet_read_failed"
    let rawKey ← if !retryKey.isEmpty then pure retryKey else
      match (args.fieldStr? "idempotency_key").filter (!·.isEmpty) with
      | some key => pure key
      | none => newUuidV4
    let key := bytesToHexLower (sha256Bytes (renderCompact (.arr #[.str "managed-extend",.str m.id,.str m.ownerUserId,.str rawKey])).toUTF8)
    let .ok minutes := ManagedTtl.extensionMinutes args | return .error "managed_extension_invalid"
    match ← ManagedTtl.extendWorker mc fleet provider m.id key minutes nowEpoch budget with
    | .ok updated => return .ok (managedLifecycleResult updated)
    | .error e => return .error e
  if action == "resume" then
    if provider.name == "boat" then
      if m.providerId.isEmpty then
        let .ok _ ← reconcileConfiguredBoatInventory mc ctx.store.rootDir nowEpoch (some provider)
          | return .error "boat_inventory_reconciliation_failed"
      let some (observedMachine, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
      if observedMachine.providerId.isEmpty then return .error "managed_provider_identity_pending"
      if !observedMachine.providerId.isEmpty then
        let observation ← match ← provider.get observedMachine.providerId with
          | .ok remote =>
            if remote.providerId != observedMachine.providerId then return .error "stale_provider_identity"
            pure (observeProviderPayload "boat" machineId 200 (.obj #[("state", .str remote.state)]))
          | .error e =>
            if e.status != 404 then return .error e.code
            pure (observeProviderPayload "boat" machineId 404 .null)
        let .ok observation := observation | return .error "boat_observation_invalid"
        let .ok _ ← applyProviderObservation mc { observation with
            expectedProviderId? := some observedMachine.providerId,
            expectedBootEpoch? := some observedMachine.nodeBootEpoch } nowEpoch 0 1
          | return .error "boat_observation_commit_failed"
    let some (m, _) ← getManagedMachine? mc machineId | return .error "managed_machine_missing"
    let bootstrap ← match ctx.override? with
      | some pair => pure pair.2
      | none => do
        let .ok cfg ← loadManagedBootstrapConfig | return .error "managed_bootstrap_configuration_unavailable"
        pure cfg
    let budget ← match ← loadManagedUserAdmission ctx.store m.ownerUserId nowEpoch with
      | .ok value => pure value
      | .error e => return .error e
    let fleet ← match ← loadManagedFleet mc ctx.fleet.enabled ctx.fleet.boatEnabled
        ctx.fleet.dailyCapCents ctx.fleet.spentTodayCents ctx.fleet.maxConcurrent with
      | .ok f => pure f
      | .error e => return .error e
    match ← ManagedProvisioning.resumeManagedWorker mc fleet m.id resumeKey ttl provider bootstrap {} budget with
    | .error e => return .error e
    | .ok ready => return .ok (managedLifecycleResult ready)
  let op ← if action == "stop" then pure (Orb.ManagedNode.VmOp.encode .stop)
    else if action == "destroy" then pure (Orb.ManagedNode.VmOp.encode .destroy)
    else return .error "managed_lifecycle_bootstrap_not_implemented"
  if slice.phaseCode == 2 && m.status == "provisioning" then return .error "managed_resume_pending"
  if Orb.ManagedNode.verifyVmLifecycleAdmit slice.phaseCode op 0 1
      slice.nodeBootEpoch slice.nodeBootEpoch nowEpoch slice.deletableAt != 1 then
    return .error "vm_lifecycle_rejected"
  if slice.phaseCode == 0 && m.providerId.isEmpty then return .error "managed_provider_identity_pending"
  let outcome ← if action == "stop" then provider.stop m.effectiveProviderId else provider.destroy m.effectiveProviderId
  if let .error e := outcome then return .error e.code
  let .ok _ ← applyVmLifecycle mc m.id {
      opCode := op, ownerLive := 0, idleElapsed := 1,
      presentedBootEpoch := m.nodeBootEpoch, nowEpoch
    }
    | return .error "managed_lifecycle_commit_failed"
  let some (saved, _) ← getManagedMachine? mc m.id
    | return .error "managed_machine_missing"
  return .ok (managedLifecycleResult saved)

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
    (nowIso : String) (providerOverride? : Option (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig) := none) :
    IO (Option (Nat × String × ByteArray)) := do
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
    let fv ← buildComputeFleetJVal hub? (some mc) fleet scopedUid? uSpent none store.rootDir nowIso (some store)
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
          if let .error error ← sealProviderSecret store.rootDir "boat" bKey.trimAscii.toString then
            return some (jsonErr (if error == "managed_secret_seal_busy" then 409 else 500)
              "managed_provider_secret_seal_failed")
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
      match ← loadManagedProviderCatalog mc store.rootDir fleet isAdmin prefs (providerOverride?.map Prod.fst) with
      | .error error => return some (jsonErr 503 error)
      | .ok catalog => return some (jsonResp 200 catalog)

    if method == "PUT" && segs.length == 4 && segs[2]? == some "providers" then
      if !isAdmin then return some (jsonErr 403 "admin_required")
      let prov := canonicalizeProvider segs[3]!
      let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
      if let some apiKey := (jv.fieldStr? "api_key").filter (!·.trimAscii.toString.isEmpty) then
        if let .error e ← sealProviderSecret store.rootDir prov apiKey.trimAscii.toString then
          return some (jsonErr 400 e)
      if let some enabled := (jv.fieldBool? "enabled").filter (fun _ => prov != "boat") then
        if let .error error ← ManagedProviderSettings.setEnabled mc prov enabled nowIso then
          return some (jsonErr 400 error)
      if prov == "boat" then
        let nextBoat := (jv.fieldBool? "enabled").getD fleet.boatEnabled
        discard <| saveManagedFleetConfig mc
          (Orb.ManagedProviderAvailability.fleetAfterProviderUpdate fleet.enabled (jv.fieldBool? "enabled"))
          nextBoat fleet.dailyCapCents fleet.spentTodayCents fleet.maxConcurrent
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
          match ← runConfiguredManagedLifecycle mc { store, fleet := defaultFleet, override? := providerOverride? } m.id action nowEpochSec jv
              (((headers.find? (fun h => h.1.toLower == "idempotency-key")).map Prod.snd).getD "") with
          | .ok updated => return some (jsonResp 200 updated)
          | .error e => return some (jsonErr 409 e)
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
        else if action == "stop" || action == "resume" || action == "destroy" then
          match ← runConfiguredManagedLifecycle mc { store, fleet := defaultFleet, override? := providerOverride? } m.id action nowEpochSec jv with
          | .error e => return some (jsonErr 409 e)
          | .ok result => return some (jsonResp 200 result)
      else if method == "DELETE" && segs.length == 3 then
        let some (m, _) ← getManagedMachine? mc sub2
          | return some (jsonErr 404 "managed_machine_not_found")
        if !isAdmin && !isLegacyUnscoped && !m.ownerUserId.isEmpty && m.ownerUserId != callerUserId then
          return some (jsonErr 404 "managed_machine_not_found")
        match ← runConfiguredManagedLifecycle mc { store, fleet := defaultFleet, override? := providerOverride? } m.id "destroy" nowEpochSec with
        | .error e => return some (jsonErr 409 e)
        | .ok result => return some (jsonResp 200 result)

  -- 5. `/api/nodes/:name/{cordon,uncordon,capacity}`
  if method == "POST" && segs.length == 4 && segs[0]? == some "api" && segs[1]? == some "nodes" then
    if !isAdmin then return some (jsonErr 403 "admin_required")
    let nodeName := segs[2]!
    let action := segs[3]!
    if action == "cordon" || action == "uncordon" then
      let wantCordoned := action == "cordon"
      let cordVal := if wantCordoned then "1" else "0"
      let mut changed := false
      if let some mid ← resolveManagedMachineId? mc nodeName then
        if let some (mPrev, _) ← getManagedMachine? mc mid then
          changed := mPrev.cordoned != wantCordoned
        discard <| execParamQuery mc.db "UPDATE managed_machines SET cordoned=?2 WHERE id=?1;" #[mid, cordVal]
      else
        let (_, staticNodes) ← loadStaticRemoteNodes
        if !staticNodes.any (fun n => n.id == nodeName) then
          return some (jsonErr 404 "unknown_node")
        changed ← setPersistedNodeCordoned store.rootDir nodeName wantCordoned
      return some (jsonResp 200 (.obj #[
        ("ok", .bool true),
        ("node", .str nodeName),
        ("cordoned", .bool wantCordoned),
        ("changed", .bool changed)
      ]))
    else if action == "capacity" then
      let jv := (OrbBin.Json.parse ((String.fromUTF8? bodyBytes).getD "{}")).toOption.getD (.obj #[])
      let some cap := jv.fieldNat? "capacity"
        | return some (jsonErr 400 "missing_capacity")
      if cap < 1 || cap > 256 then
        return some (jsonErr 400 "invalid_capacity")
      let (_, staticNodes) ← loadStaticRemoteNodes
      let staticMatch? := staticNodes.find? (fun n => n.id == nodeName)
      let (effNodeId, secret) ← do
        if let some sn := staticMatch? then
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
        if 200 ≤ st && st < 300 then
          if let some sn := staticMatch? then
            let persistedCordons ← loadPersistedNodeCordons store.rootDir
            let refreshed ← probeStaticNodeHeartbeat sn persistedCordons nowIso
            return some (jsonResp 200 refreshed)
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
