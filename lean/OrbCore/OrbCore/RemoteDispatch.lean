/-
  OrbCore.RemoteDispatch: Asynchronous Remote-Node (`OrbNode`) Harness Job Dispatch,
  Live NDJSON Event Streaming Poller, Startup Run Re-Attachment, Legacy `automations`
  Migration, and Background Wakeup Continuation Scheduler (`0 import Lean`, `0 sorryAx`).
-/
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.HttpClient
import OrbBin.ClaudeControl
import OrbCore.Store
import OrbCore.Managed
import OrbCore.MemoryAndCloud
import OrbCore.QueueCont
import OrbCore.R7Core
import OrbCore.LegacyHydrate
import OrbCore.ProviderUsageAndLogin
import OrbCore.RemoteFleetAndRelay
import OrbCore.Skills
import OrbCore.AutoPlacement

namespace OrbCore.RemoteDispatch

open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.HttpClient
open OrbCore.Store
open OrbCore.Managed
open OrbCore.MemoryAndCloud
open OrbCore.QueueCont
open OrbCore.R7Core
open OrbCore.LegacyHydrate
open OrbCore.ProviderUsageAndLogin
open OrbCore.RemoteFleetAndRelay

/-! ## Remote Job Supervisor Handle -/

structure RemoteJobSupervisor where
  mu           : Std.Mutex (Array String)
  boundPortRef : IO.Ref UInt16
  jwtSecret    : String
  devMode      : Bool

def newRemoteJobSupervisor (jwtSecret : String := "") (devMode : Bool := false) : IO RemoteJobSupervisor := do
  let mu ← Std.Mutex.new (#[] : Array String)
  let portRef ← IO.mkRef (0 : UInt16)
  return { mu := mu, boundPortRef := portRef, jwtSecret := jwtSecret, devMode := devMode }

private def claimPolledJob (sup : RemoteJobSupervisor) (jobId : String) : IO Bool :=
  sup.mu.atomically do
    let cur ← get
    if cur.contains jobId then
      return false
    set (cur.push jobId)
    return true

private def releasePolledJob (sup : RemoteJobSupervisor) (jobId : String) : IO Unit :=
  sup.mu.atomically do
    let cur ← get
    set (cur.filter (· != jobId))

/-! ## Small String & Shell Helpers -/

private def cellNat (r : Array String) (i : Nat) : Nat :=
  ((r[i]?).bind String.toNat?).getD 0

private def trimTrailingSlashes (s : String) : String :=
  let rev := s.trimAscii.toString.toList.reverse.dropWhile (· == '/')
  String.ofList rev.reverse

private def shellSingleQuote (s : String) : String :=
  "'" ++ String.intercalate "'\"'\"'" (s.splitOn "'") ++ "'"

private def isSafeWorkspaceIdSeg (s : String) : Bool :=
  !s.isEmpty &&
  s != "." &&
  s != ".." &&
  !s.toList.any (fun c => c == '/' || c == '\\' || c.toNat == 0)

private def parseTagsArray (raw : String) : Array String :=
  match OrbBin.Json.parse raw with
  | .ok (.arr xs) => xs.filterMap JVal.asStr?
  | _ => #[]

private def extractTagValue? (tags : Array String) (pref : String) : Option String :=
  tags.findSome? fun t =>
    if t.startsWith pref then
      let v := (t.drop pref.length).trimAscii.toString
      if v.isEmpty then none else some v
    else none

/-- Split UTF-8 text into chunks of at most `maxBytes` bytes without splitting multi-byte codepoints. -/
def splitUtf8Chunks (text : String) (maxBytes : Nat := 96 * 1024) : Array String := Id.run do
  let bytes := text.toUTF8
  if bytes.isEmpty then return #[""]
  let cap := Nat.max 64 maxBytes
  let mut out : Array String := #[]
  let mut pos : Nat := 0
  while pos < bytes.size do
    let rem := bytes.size - pos
    if rem ≤ cap then
      let slice := bytes.extract pos bytes.size
      out := out.push ((String.fromUTF8? slice).getD "")
      pos := bytes.size
    else
      let mut endIdx := pos + cap
      while endIdx > pos && ((bytes.get! endIdx &&& 0xC0) == 0x80) do
        endIdx := endIdx - 1
      if endIdx == pos then
        endIdx := pos + cap
      let slice := bytes.extract pos endIdx
      out := out.push ((String.fromUTF8? slice).getD "")
      pos := endIdx
  return out

/-- Stage prompt text onto file descriptor 3 via `SANDBOXED_PROMPT_PART_N` environment variables. -/
def stagePromptOnFd3 (prompt : String) : String × Array (String × String) := Id.run do
  let chunks := splitUtf8Chunks prompt (96 * 1024)
  let mut envs : Array (String × String) := Array.mkEmpty chunks.size
  let mut refs : Array String := Array.mkEmpty chunks.size
  let mut unsetVars : String := "sandboxed_prompt"
  for i in [0:chunks.size] do
    let k := s!"SANDBOXED_PROMPT_PART_{i}"
    envs := envs.push (k, chunks[i]!)
    refs := refs.push s!"\"${k}\""
    unsetVars := unsetVars ++ " " ++ k
  let printfArgs := String.intercalate " " refs.toList
  let prelude :=
    "sandboxed_prompt=\"$(mktemp)\" || exit 1; " ++
    s!"printf %s {printfArgs} > \"$sandboxed_prompt\" || exit 1; " ++
    "exec 3< \"$sandboxed_prompt\"; " ++
    "rm -f -- \"$sandboxed_prompt\"; " ++
    s!"unset {unsetVars}; "
  return (prelude, envs)

/-! ## Remote Node Placement Resolution & Unified Transport Wrapper -/

/-- Call a static remote node or dial-out managed VM (`OrbNode`), supporting `mc? = none` for static nodes. -/
def callRemoteNodeHttpOpt
    (hub? : Option RelayHub)
    (mc? : Option ManagedComputeStore)
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
    let some mc := mc?
      | return .error s!"unknown remote node `{targetNodeId}`"
    callRemoteNodeHttp hub? mc targetNodeId method pathQuery jsonBody? extraHeaders timeoutMs

/-- Check whether `targetNodeId` resolves to a loopback HTTP URL (`127.0.0.1` or `localhost`). -/
private def isLoopbackStaticNode (targetNodeId : String) : IO Bool := do
  let (_, staticNodes) ← loadStaticRemoteNodes
  match staticNodes.find? (fun n => n.id == targetNodeId) with
  | none => return false
  | some sn =>
    let u := sn.baseUrl.toLower
    return u.startsWith "http://127.0.0.1" || u.startsWith "http://localhost" || u.startsWith "http://[::1]"

/-- The ready managed machine an unnamed managed target (`auto-managed`, or `auto`
    with no static fleet), or a sandbox name, may resolve to for `missionId`: one owned by that
    mission or an ancestor, or a user-owned one of the mission's own user. Never
    another mission's or another user's machine; with no mission, none. -/
def scopedReadyManagedMachine?
    (mc : ManagedComputeStore)
    (scope? : Option (CoreStore × String))
    (sandboxName : String := "") : IO (Option String) := do
  let some (store, missionId) := scope? | return none
  let mut lineage : Array String := #[]
  let mut current := missionId.trimAscii.toString
  let mut ownerUser := ""
  for depth in [0:8] do
    if current.isEmpty || lineage.contains current then break
    let .ok rows ← execParamQuery store.missionsDb
        "SELECT COALESCE(parent_mission_id,''), COALESCE(owner_user_id,'') FROM missions WHERE id=?1;" #[current]
      | break
    if rows.size < 2 then break
    lineage := lineage.push current
    if depth == 0 then ownerUser := (cell rows[1]! 1).trimAscii.toString
    current := (cell rows[1]! 0).trimAscii.toString
  if lineage.isEmpty then return none
  let .ok rows ← execParamQuery mc.db
      ("SELECT id, owner_mission, owner_kind, owner_user_id FROM managed_machines " ++
       "WHERE phase_code=1 AND cordoned=0 AND (?1='' OR sandbox_name=?1) ORDER BY last_poll_sec DESC, id;") #[sandboxName]
    | return none
  for row in rows.extract 1 rows.size do
    let ownerMission := cell row 1
    let allowed :=
      if ownerMission.isEmpty then cell row 2 != "mission" && cell row 3 == ownerUser
      else lineage.contains ownerMission
    if allowed && !(cell row 0).isEmpty then return some s!"managed-{cell row 0}"
  return none

/-- Resolve `"auto"`, `"auto-managed"`, or sandbox names into a concrete `targetNodeId` accepted by `callRemoteNodeHttpOpt`. -/
def resolveConcreteRemoteTargetNode
    (mc? : Option ManagedComputeStore)
    (rawTarget : String)
    (scope? : Option (CoreStore × String) := none) : IO (Except String String) := do
  let clean := rawTarget.trimAscii.toString
  if clean.isEmpty || clean == "local" || clean == "client" then
    return .error "not_a_remote_target"
  let (_, staticNodes) ← loadStaticRemoteNodes
  if staticNodes.any (fun n => n.id == clean) then
    return .ok clean
  if clean == "auto" || clean.startsWith "auto:" then
    if let some sn := staticNodes[0]? then
      return .ok sn.id
    if let some mc := mc? then
      if let some node ← scopedReadyManagedMachine? mc scope? then return .ok node
    return .error "no_remote_nodes_available"
  if clean == "auto-managed" || clean.startsWith "auto-managed:" then
    let some mc := mc?
      | return .error "no_managed_machines_available"
    if let some node ← scopedReadyManagedMachine? mc scope? then return .ok node
    return .error "no_managed_machines_available"
  if let some mc := mc? then
    let cand := if clean.startsWith "managed-" then (clean.drop 8).toString else clean
    if let some _ ← getManagedMachine? mc cand then
      return .ok (if clean.startsWith "managed-" then clean else s!"managed-{cand}")
    -- A sandbox name is guessable, so it only names a machine the mission may use.
    if let some node ← scopedReadyManagedMachine? mc scope? clean then return .ok node
  return .ok clean

/-- Authoritatively resolve the remote node ID for an existing mission across `machine_transfers`,
    `missions.tags`, `missions.placement_kind`, `mission_runs.scope_unit`, `remote_node_jobs`,
    `managed_machines`, and fork / `/btw` parent lineage. -/
def resolveMissionRemoteNode?
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (missionId : String)
    (depth : Nat := 4) : IO (Option String) := do
  let mid := missionId.trimAscii.toString
  if mid.isEmpty then return none
  -- 1. Committed/activated machine transfer destination
  if let .ok txRows ← execParamQuery store.missionsDb
      "SELECT COALESCE(destination,'') FROM machine_transfers WHERE mission_id=?1 AND phase IN ('committed','activated') ORDER BY created_at DESC LIMIT 1;"
      #[mid] then
    if txRows.size > 1 then
      let dest := (cell txRows[1]! 0).trimAscii.toString
      if !dest.isEmpty && dest != "local" && dest != "client" then
        return some dest
  -- 2. Mission tags and placement_kind
  let mut tags : Array String := #[]
  let mut placeKind : String := ""
  let mut parentMid : String := ""
  if let .ok mRows ← execParamQuery store.missionsDb
      "SELECT COALESCE(tags,'[]'), COALESCE(placement_kind,''), COALESCE(parent_mission_id,'') FROM missions WHERE id=?1;"
      #[mid] then
    if mRows.size > 1 then
      tags := parseTagsArray (cell mRows[1]! 0)
      placeKind := (cell mRows[1]! 1).trimAscii.toString
      parentMid := (cell mRows[1]! 2).trimAscii.toString
  if let some rn := (extractTagValue? tags "remote-node:").orElse (fun _ => extractTagValue? tags "remote_node:") then
    if rn != "local" && rn != "client" then
      return some rn
  if placeKind.startsWith "managed-" && placeKind != "managed" then
    return some placeKind
  -- 3. `mission_runs.scope_unit` (`remote-node:<id>`)
  if let .ok rRows ← execParamQuery store.missionsDb
      "SELECT COALESCE(scope_unit,'') FROM mission_runs WHERE mission_id=?1 AND COALESCE(scope_unit,'') LIKE 'remote-node:%' ORDER BY generation DESC, rowid DESC LIMIT 1;"
      #[mid] then
    if rRows.size > 1 then
      let su := (cell rRows[1]! 0).trimAscii.toString
      if su.startsWith "remote-node:" then
        let rn := (su.drop 12).trimAscii.toString
        if !rn.isEmpty && rn != "local" then
          return some rn
  -- 4. `remote_node_jobs` / `projects.remote_jobs` ledger
  if let .ok jRows ← execParamQuery store.missionsDb
      "SELECT COALESCE(node_id,'') FROM remote_node_jobs WHERE mission_id=?1 AND COALESCE(node_id,'')<>'' ORDER BY updated_at DESC LIMIT 1;"
      #[mid] then
    if jRows.size > 1 then
      let jn := (cell jRows[1]! 0).trimAscii.toString
      if !jn.isEmpty && jn != "local" then
        return some jn
  if let .ok pjRows ← execParamQuery store.projectsDb
      "SELECT COALESCE(node_id,'') FROM remote_jobs WHERE mission_id=?1 AND COALESCE(node_id,'')<>'' ORDER BY updated_at DESC LIMIT 1;"
      #[mid] then
    if pjRows.size > 1 then
      let pjn := (cell pjRows[1]! 0).trimAscii.toString
      if !pjn.isEmpty && pjn != "local" then
        return some pjn
  -- 4b. `mission_orchestration_meta.placement_node_id`
  if let .ok oRows ← execParamQuery store.missionsDb
      "SELECT COALESCE(placement_node_id,'') FROM mission_orchestration_meta WHERE mission_id=?1 LIMIT 1;"
      #[mid] then
    if oRows.size > 1 then
      let pn := (cell oRows[1]! 0).trimAscii.toString
      if !pn.isEmpty && pn != "local" && pn != "client" && pn != "core" && pn != "orb-core" && pn != "agent-core" then
        return some pn
  -- 5. Managed VM owned by mission
  if placeKind == "managed_vm" then
    if let some mc := mc? then
      if let .ok vmRows ← execParamQuery mc.db
          "SELECT id FROM managed_machines WHERE owner_mission=?1 AND phase_code<>3 ORDER BY created_at_sec DESC, id LIMIT 1;"
          #[mid] then
        if vmRows.size > 1 then
          let vmid := (cell vmRows[1]! 0).trimAscii.toString
          if !vmid.isEmpty then
            return some s!"managed-{vmid}"
  -- 6. Recurse into fork / `/btw` parent when workspace is inherited
  if depth > 0 then
    let anc? :=
      (extractTagValue? tags "fork-workspace:")
        |>.orElse (fun _ => extractTagValue? tags "btw-parent:")
        |>.orElse (fun _ => extractTagValue? tags "forked-from:")
        |>.orElse (fun _ => if parentMid.isEmpty then none else some parentMid)
    if let some anc := anc? then
      if anc != mid then
        return (← resolveMissionRemoteNode? store mc? anc (depth - 1))
  return none

/-! ## Remote Harness Command & Environment Construction -/

private def ensureDurableJobsTableLocal (store : CoreStore) : IO Unit := do
  discard <| execParamQuery store.missionsDb
    ("CREATE TABLE IF NOT EXISTS remote_node_jobs (" ++
     "job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', node_id TEXT NOT NULL DEFAULT '', " ++
     "state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', " ++
     "created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');")
    #[]
  discard <| execParamQuery store.missionsDb
    "CREATE TABLE IF NOT EXISTS remote_log_offsets (job_id TEXT PRIMARY KEY, published_offset INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '');"
    #[]
  discard <| execParamQuery store.projectsDb
    ("CREATE TABLE IF NOT EXISTS remote_jobs (" ++
     "job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, node_id TEXT NOT NULL, kind TEXT NOT NULL, " ++
     "state TEXT NOT NULL, identity_version INTEGER NOT NULL DEFAULT 0, identity_hash TEXT, identity_json TEXT, " ++
     "submission_sequence INTEGER NOT NULL DEFAULT 0, started_at TEXT NOT NULL, accepted_at TEXT, heartbeat_at TEXT, " ++
     "finished_at TEXT, exit_status INTEGER, artifacts_json TEXT NOT NULL DEFAULT '[]', " ++
     "wake_required INTEGER NOT NULL DEFAULT 0, wake_delivered_at TEXT, wake_suppressed_by TEXT, updated_at TEXT NOT NULL);")
    #[]

private def remoteOpenCodeConfigJson (modelKey proxyBaseUrl : String) : String :=
  let low := modelKey.toLower
  let ctxLimit : Nat := if (low.splitOn "gpt-").length > 1 then 272000 else 200000
  let modelEntry := JVal.obj #[
    ("name", .str modelKey),
    ("attachment", .bool true),
    ("modalities", .obj #[
      ("input", .arr #[.str "text", .str "image"]),
      ("output", .arr #[.str "text"])
    ]),
    ("limit", .obj #[
      ("context", .nat ctxLimit),
      ("output", .nat 32000)
    ])
  ]
  renderCompact (.obj #[
    ("$schema", .str "https://opencode.ai/config.json"),
    ("permission", .obj #[
      ("*", .str "allow"),
      ("external_directory", .obj #[("*", .str "allow")]),
      ("doom_loop", .str "allow"),
      ("read", .obj #[("*", .str "allow")])
    ]),
    ("provider", .obj #[
      ("builtin", .obj #[
        ("npm", .str "@ai-sdk/openai-compatible"),
        ("name", .str "Builtin"),
        ("models", .obj #[(modelKey, modelEntry)]),
        ("options", .obj #[
          ("baseURL", .str s!"{proxyBaseUrl}/v1"),
          ("apiKey", .str "{env:SANDBOXED_PROXY_API_KEY}"),
          ("timeout", .nat 900000)
        ])
      ])
    ])
  ])

private def wrapWithRemoteMcp (harness innerCmd : String) : String :=
  s!"if [ -x /usr/local/bin/sandboxed-mcp ]; then /usr/local/bin/sandboxed-mcp launch --harness {harness} -- {innerCmd}; else {innerCmd}; fi"

private def buildWorkspacePrefix (coreWorkDir workingDir : String) (tags : Array String) : String :=
  let cleanWd := workingDir.trimAscii.toString
  if cleanWd.isEmpty then
    match extractTagValue? tags "fork-workspace:" with
    | some srcId =>
      if isSafeWorkspaceIdSeg srcId then
        s!"fork_root=$(pwd -P); fork_root=$\{fork_root%/*}; fork_dir=\"$fork_root/{srcId}\"; " ++
        "[ -d \"$fork_dir\" ] && [ ! -L \"$fork_dir\" ] || { echo 'Fork workspace unavailable' >&2; exit 78; }; " ++
        "cd -- \"$fork_dir\" || exit 78; "
      else ""
    | none => ""
  else if cleanWd != coreWorkDir.trimAscii.toString then
    s!"cd -- {shellSingleQuote cleanWd} || exit 78; "
  else
    ""

structure RemoteTurnSpec where
  missionId          : String
  targetNodeId       : String
  backend            : String
  modelOverride      : String := ""
  modelEffort        : String := ""
  workingDirectory   : String := ""
  project            : String := ""
  ownerUserId        : String := ""
  authorityMode      : String := "writer"
  placementKind      : String := "managed"
  reservedDiskGib    : UInt64 := 0
  tagsJson           : String := "[]"
  prompt             : String
  resumeSessionId?   : Option String := none
  sideQuestion       : Bool := false
  companionOf?       : Option String := none
  coordinatorPrio    : Bool := false
  rawCommandOverride?: Option String := none
  deriving Repr

/-- Remote execution uses the stored tenant's Linux identity and a dedicated
    node or that tenant's VM. Static metadata is Core configuration, never tool
    arguments; aliases and control-plane labels cannot bypass the placement gate. -/
def authorizeRemotePlacement (mc? : Option ManagedComputeStore) (owner : UserRecord)
    (target : String) (nodes : Array StaticRemoteNode) : IO (Except String Unit) := do
  if owner.disabled then return .error "remote_owner_unavailable"
  if owner.role == "admin" then return .ok ()
  let node? := nodes.find? (·.id == target)
  let managed := node?.isNone && target.startsWith "managed-"
  let targetKind : UInt8 := if node?.isSome then 2 else if managed then 3 else 0
  let adminOnly : UInt8 := if (node?.map OrbCore.AutoPlacement.reserved).getD (!managed) then 1 else 0
  let validUx : UInt8 := if (owner.unixUsername?.map Orb.Kernel.validUnixUsername).getD false then 1 else 0
  unless Orb.Kernel.placementRoleAdmit 0 targetKind adminOnly validUx == 1 do
    return .error "remote_placement_forbidden"
  if managed then
    let some mc := mc? | return .error "remote_placement_forbidden"
    let some (machine, _) ← getManagedMachine? mc (target.drop 8).toString
      | return .error "remote_placement_forbidden"
    unless machine.ownerUserId == owner.id do return .error "remote_placement_forbidden"
  return .ok ()

/-- A call site omitting `ownerUserId` must never mint admin MCP/proxy/node
    credentials for a member's mission. Bind it before any credential or host I/O. -/
def bindRemoteTurnOwner (store : CoreStore) (mc? : Option ManagedComputeStore)
    (spec : RemoteTurnSpec) (target : String) (nodes : Array StaticRemoteNode) : IO (Except String RemoteTurnSpec) := do
  let some mission ← getMission? store spec.missionId | return .error "remote_mission_missing"
  unless spec.ownerUserId.isEmpty || spec.ownerUserId == mission.ownerUserId do
    return .error "remote_owner_mismatch"
  let ownedSpec := { spec with ownerUserId := mission.ownerUserId }
  if mission.ownerUserId.isEmpty then return .ok ownedSpec
  let some owner ← getUserById? store mission.ownerUserId | return .error "remote_owner_unavailable"
  if let .error error ← authorizeRemotePlacement mc? owner target nodes then return .error error
  return .ok ownedSpec

structure PreparedRemoteCommand where
  command     : String
  envPairs    : Array (String × String)
  managedAuth : Array String
  proxyToken  : String

private def resolveRemoteCallbackUrls (sup : RemoteJobSupervisor) (targetNodeId : String) : IO (String × String) := do
  let pubApiRaw := trimTrailingSlashes ((← lookupEnvWithFiles? "SANDBOXED_PUBLIC_URL").getD "")
  let apiBase ←
    if !pubApiRaw.isEmpty then
      pure pubApiRaw
    else do
      let bPort ← sup.boundPortRef.get
      let isLoop ← isLoopbackStaticNode targetNodeId
      if bPort > 0 && (isLoop || sup.devMode) then
        pure s!"http://127.0.0.1:{bPort}"
      else
        pure ""
  let pubProxyRaw := trimTrailingSlashes ((← lookupEnvWithFiles? "SANDBOXED_PROXY_PUBLIC_URL").getD "")
  let proxyBase := if !pubProxyRaw.isEmpty then pubProxyRaw else apiBase
  return (apiBase, proxyBase)

private def mintMissionScopedMcpEnv
    (store : CoreStore)
    (sup : RemoteJobSupervisor)
    (missionId ownerUid project apiBaseUrl : String)
    (sideQuestion : Bool)
    (nowSec : UInt64) : IO (Array (String × String)) := do
  if apiBaseUrl.isEmpty then return #[]
  let sid ← newUuidV4
  let exp := nowSec + 86400
  let hardExp := nowSec + 86400 * 7
  let role := if sideQuestion then "executor" else "executor"
  let projScoped := if project.isEmpty then "0" else "1"
  let insRes ← execParamQuery store.projectsDb
    ("INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind,client_label,host_hint,project_scope,project_scoped,hard_expires_at) " ++
     "VALUES(?1,?2,?3,CAST(?4 AS INTEGER),0,'mission','remote_harness','orb_node',?5,CAST(?6 AS INTEGER),CAST(?7 AS INTEGER));")
    #[sid, ownerUid, missionId, s!"{exp}", project, projScoped, s!"{hardExp}"]
  if let .error _ := insRes then
    discard <| execParamQuery store.projectsDb
      ("INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind,client_label,host_hint,project_scope,hard_expires_at) " ++
       "VALUES(?1,?2,?3,CAST(?4 AS INTEGER),0,'mission','remote_harness','orb_node',?5,CAST(?6 AS INTEGER));")
      #[sid, ownerUid, missionId, s!"{exp}", project, s!"{hardExp}"]
  let claims : McpSessionClaims := {
    sessionId     := sid
    missionId     := missionId
    role          := role
    project       := project
    isExternal    := false
    expiresAt     := exp
    hardExpiresAt := hardExp
  }
  let mcpTok := mintScopedMcpToken sup.jwtSecret claims
  return #[
    ("SANDBOXED_MCP_API_URL", apiBaseUrl),
    ("SANDBOXED_MCP_TOKEN", mcpTok),
    ("SANDBOXED_SH_MISSION_ID", missionId),
    ("SANDBOXED_MCP_WRAPPER", "/usr/local/bin/sandboxed-mcp")
  ]

private def prepareRemoteHarnessCommand
    (store : CoreStore)
    (sup : RemoteJobSupervisor)
    (coreWorkDir effNodeId : String)
    (spec : RemoteTurnSpec)
    (nowSec : UInt64) : IO (Except String PreparedRemoteCommand) := do
  let tags := parseTagsArray spec.tagsJson
  let wsPrefix := buildWorkspacePrefix coreWorkDir spec.workingDirectory tags
  let (apiBase, proxyBase) ← resolveRemoteCallbackUrls sup effNodeId
  let mcpEnvs ← mintMissionScopedMcpEnv store sup spec.missionId spec.ownerUserId spec.project apiBase spec.sideQuestion nowSec
  if let some rawCmd := spec.rawCommandOverride?.filter (fun s => !s.trimAscii.toString.isEmpty) then
    return .ok {
      command     := wsPrefix ++ rawCmd
      envPairs    := mcpEnvs.push ("NO_COLOR", "1")
      managedAuth := #[]
      proxyToken  := ""
    }
  let trimmedPrompt := spec.prompt.trimAscii.toString
  let isPlanPrompt :=
    trimmedPrompt == "/plan" || trimmedPrompt.startsWith "/plan " || trimmedPrompt.startsWith "/plan\n"
  let deliveredPrompt :=
    if isPlanPrompt && trimmedPrompt.length > 5 then
      (trimmedPrompt.drop 5).trimAscii.toString
    else
      spec.prompt
  -- The Library lives on Core: ship the delivered skills into the node workspace so every
  -- harness finds them where it looks (`.opencode/skills`, `.claude/skills`, `.agents/skills`).
  let bootstrapAdminId := (← getBootstrapAdmin? store).map (·.id) |>.getD ""
  let wsPrefix := wsPrefix ++ (← OrbCore.Skills.remoteInstallPrelude coreWorkDir
    (if spec.project.trimAscii.toString.isEmpty then none else some spec.project) spec.backend.trimAscii.toString.toLower store.rootDir spec.ownerUserId bootstrapAdminId)
  let (fd3Prelude, promptEnvs) := stagePromptOnFd3 deliveredPrompt
  let resumeSid? := spec.resumeSessionId?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let bLow := spec.backend.trimAscii.toString.toLower
  let harness := if bLow == "claude" then "claudecode" else bLow

  if harness == "opencode" then
    if proxyBase.isEmpty then
      return .error "SANDBOXED_PUBLIC_URL (or SANDBOXED_PROXY_PUBLIC_URL) must be configured for remote opencode turns"
    let pTok ← match ← mintMissionProxyToken store spec.missionId spec.ownerUserId (nowSec + 86400) with
      | .ok t => pure t
      | .error e => return .error s!"failed to mint mission proxy token: {e}"
    let rawModel := spec.modelOverride.trimAscii.toString
    let strippedModel :=
      if rawModel.startsWith "builtin/" then (rawModel.drop 8).toString
      else if rawModel.startsWith "sandboxed-sh/" then (rawModel.drop 13).toString
      else rawModel
    let modelKey := if strippedModel.isEmpty then "smart" else strippedModel
    let ocCfg := remoteOpenCodeConfigJson modelKey proxyBase
    let planArg := if isPlanPrompt || spec.authorityMode == "readonly" && false then " --agent plan" else if isPlanPrompt then " --agent plan" else ""
    let sessArg :=
      match resumeSid? with
      | some sid => if sid.startsWith "ses_" then s!" --session {shellSingleQuote sid}" else ""
      | none => ""
    let inner := s!"opencode run --format json --thinking{planArg}{sessArg} --model {shellSingleQuote s!"builtin/{modelKey}"}"
    -- Streams over ACP when the node's `sandboxed-node` supports it; older nodes keep
    -- `opencode run`, which prints each text part only once it is finished.
    let acpPlan := if planArg.isEmpty then "" else " --plan"
    let acpInner := s!"sandboxed-node opencode-acp{acpPlan}{sessArg} --model {shellSingleQuote s!"builtin/{modelKey}"}"
    let cmd :=
      wsPrefix ++ fd3Prelude ++
      "command -v opencode >/dev/null 2>&1 || { echo 'opencode is not installed on this node' >&2; exit 127; }; " ++
      "if sandboxed-node opencode-acp --probe </dev/null >/dev/null 2>&1; then " ++
      wrapWithRemoteMcp "opencode" acpInner ++ "; else " ++ wrapWithRemoteMcp "opencode" inner ++ "; fi <&3"
    let envs :=
      promptEnvs ++ mcpEnvs ++ #[
        ("SANDBOXED_PROXY_API_KEY", pTok),
        ("NO_COLOR", "1"),
        ("OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS", "600000"),
        ("OPENCODE_CONFIG_CONTENT", ocCfg)
      ]
    return .ok { command := cmd, envPairs := envs, managedAuth := #[], proxyToken := pTok }

  else if harness == "claudecode" then
    if proxyBase.isEmpty then
      return .error "SANDBOXED_PUBLIC_URL (or SANDBOXED_PROXY_PUBLIC_URL) must be configured for remote claudecode turns"
    let pTok ← match ← mintMissionProxyToken store spec.missionId spec.ownerUserId (nowSec + 86400) with
      | .ok t => pure t
      | .error e => return .error s!"failed to mint mission proxy token: {e}"
    let rawModel := spec.modelOverride.trimAscii.toString
    let bareModel := if rawModel.startsWith "anthropic/" then (rawModel.drop 10).toString else rawModel
    let modelArg := if bareModel.isEmpty then "" else s!" --model {shellSingleQuote bareModel}"
    let effArg :=
      if spec.modelEffort.trimAscii.toString.isEmpty then ""
      else s!" --effort {shellSingleQuote spec.modelEffort.trimAscii.toString}"
    let permArg := if isPlanPrompt then " --permission-mode plan" else ""
    let resArg := match resumeSid? with | some sid => s!" --resume {shellSingleQuote sid}" | none => ""
    let inner :=
      "claude -p --dangerously-skip-permissions --output-format stream-json --verbose --include-partial-messages" ++
      permArg ++ modelArg ++ effArg ++ resArg
    let cmd :=
      wsPrefix ++ fd3Prelude ++
      "command -v claude >/dev/null 2>&1 || { echo 'claude is not installed on this node' >&2; exit 127; }; " ++
      wrapWithRemoteMcp "claudecode" inner ++ " <&3"
    let envs :=
      promptEnvs ++ mcpEnvs ++ #[
        ("ANTHROPIC_BASE_URL", proxyBase),
        ("ANTHROPIC_AUTH_TOKEN", pTok),
        ("NO_COLOR", "1"),
        ("GH_NO_PAGER", "1"),
        ("GH_PROMPT_DISABLED", "1")
      ]
    return .ok { command := cmd, envPairs := envs, managedAuth := #[], proxyToken := pTok }

  else if harness == "codex" then
    if proxyBase.isEmpty then
      return .error "SANDBOXED_PUBLIC_URL (or SANDBOXED_PROXY_PUBLIC_URL) must be configured for remote codex turns"
    let pTok ← match ← mintMissionProxyToken store spec.missionId spec.ownerUserId (nowSec + 86400) with
      | .ok t => pure t
      | .error e => return .error s!"failed to mint mission proxy token: {e}"
    let rawModel := spec.modelOverride.trimAscii.toString
    let bareModel := if rawModel.startsWith "openai/" then (rawModel.drop 7).toString else rawModel
    let modelArg := if bareModel.isEmpty then "" else s!" -m {shellSingleQuote bareModel}"
    let effClean := spec.modelEffort.trimAscii.toString
    let effArg :=
      if effClean.isEmpty then ""
      else s!" -c {shellSingleQuote s!"model_reasoning_effort=\"{effClean}\""}"
    let baseUrlCfg := shellSingleQuote s!"model_providers.sandboxed.base_url=\"{proxyBase}/v1\""
    let provArgs :=
      " -c 'model_provider=\"sandboxed\"'" ++
      " -c 'model_providers.sandboxed.name=\"Sandboxed\"'" ++
      s!" -c {baseUrlCfg}" ++
      " -c 'model_providers.sandboxed.wire_api=\"responses\"'" ++
      " -c 'model_providers.sandboxed.env_key=\"SANDBOXED_PROXY_API_KEY\"'"
    let tailArgs :=
      match resumeSid? with
      | some sid => s!" resume {shellSingleQuote sid} -"
      | none => " -"
    let inner :=
      "codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check" ++
      provArgs ++ modelArg ++ effArg ++ tailArgs
    let cmd :=
      wsPrefix ++ fd3Prelude ++
      "command -v codex >/dev/null 2>&1 || { echo 'codex is not installed on this node' >&2; exit 127; }; " ++
      wrapWithRemoteMcp "codex" inner ++ " <&3"
    let envs :=
      promptEnvs ++ mcpEnvs ++ #[
        ("SANDBOXED_PROXY_API_KEY", pTok),
        ("NO_COLOR", "1")
      ]
    return .ok { command := cmd, envPairs := envs, managedAuth := #[], proxyToken := pTok }

  else if harness == "grok" then
    let rawModel := spec.modelOverride.trimAscii.toString
    let bareModel := if rawModel.startsWith "xai/" then (rawModel.drop 4).toString else rawModel
    let modelArg := if bareModel.isEmpty then "" else s!" --model {shellSingleQuote bareModel}"
    let freshSid ← newUuidV4
    let sessArg :=
      match resumeSid? with
      | some sid => s!" --resume {shellSingleQuote sid}"
      | none => s!" --session-id {shellSingleQuote freshSid}"
    let inner := s!"grok --output-format streaming-json --always-approve --no-plan{modelArg}{sessArg} --cwd \"$PWD\" -p \"$(cat <&3)\""
    let cmd :=
      wsPrefix ++ fd3Prelude ++
      "command -v grok >/dev/null 2>&1 || { echo 'grok is not installed on this node' >&2; exit 127; }; " ++
      wrapWithRemoteMcp "grok" inner
    let envs := promptEnvs ++ mcpEnvs ++ #[("NO_COLOR", "1")]
    return .ok { command := cmd, envPairs := envs, managedAuth := #["grok"], proxyToken := "" }

  else if harness == "antigravity" then
    let rawModel := spec.modelOverride.trimAscii.toString
    let effOpt := if spec.modelEffort.trimAscii.toString.isEmpty then none else some spec.modelEffort.trimAscii.toString
    let (modelArg, effArg) :=
      if rawModel.isEmpty then
        let ea := match effOpt with | some e => s!" --effort {shellSingleQuote e}" | none => ""
        ("", ea)
      else
        let (fullM, remEff?) := OrbBin.ClaudeControl.normalizeAntigravityCliModel rawModel effOpt
        let ea := match remEff? with | some e => s!" --effort {shellSingleQuote e}" | none => ""
        (s!" --model {shellSingleQuote fullM}", ea)
    let resArg := match resumeSid? with | some sid => s!" --resume {shellSingleQuote sid}" | none => ""
    let inner := s!"agy --print{modelArg}{effArg}{resArg} \"$(cat <&3)\""
    let cmd :=
      wsPrefix ++ fd3Prelude ++
      "command -v agy >/dev/null 2>&1 || { echo 'agy is not installed on this node' >&2; exit 127; }; " ++
      wrapWithRemoteMcp "antigravity" inner
    let envs := promptEnvs ++ mcpEnvs ++ #[("NO_COLOR", "1")]
    return .ok { command := cmd, envPairs := envs, managedAuth := #["antigravity"], proxyToken := "" }

  else
    return .error s!"unsupported remote harness `{spec.backend}`"

/-! ## NDJSON Line Ingestion (`claudecode` + `opencode` + `codex` + `grok` + `antigravity`) -/

private structure RemoteStreamAcc where
  text             : String := ""
  sawPartialDeltas : Bool   := false
  sessionId?       : Option String := none
  lastError?       : Option String := none
  lastMessageId?   : Option String := none
  /-- The harness has produced thinking, a tool call or text this turn. -/
  sawActivity      : Bool := false

private def emitMissionEventAndBroadcast
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (missionId evType payloadJson nowIso : String) : IO Unit := do
  discard <| appendMissionEvent store missionId evType payloadJson nowIso
  publishControlEvent broadcastHub? evType payloadJson (some missionId)

/-- Retries a turn gets after ending with no output before the mission is `failed`. -/
def maxEmptyTurnRetries : Nat := 2

/-- Call when a turn ended "successfully" with no assistant text. If it also made no
    tool call since the last user message, it did no work: that is a failure, never a
    completion. Returns `none` when the turn did produce work (tool-only turns are
    legitimate), otherwise the mission status to write: `awaiting_user` with a durable
    one-shot retry armed (at most `maxEmptyTurnRetries` per user message), else `failed`.
    The retry is a `mission_continuations` row, so it survives a Core restart. -/
def settleEmptyTurn (store : CoreStore) (broadcastHub? : Option BroadcastHub)
    (missionId nowIso : String) (nowSec : UInt64) (retryable : Bool := true) : IO (Option String) := do
  let produced := match ← execParamQuery store.missionsDb
      ("SELECT COUNT(*) FROM mission_events WHERE mission_id=?1 AND event_type IN ('tool_call','tool_result','assistant_message') " ++
       "AND id > COALESCE((SELECT MAX(id) FROM mission_events WHERE mission_id=?1 AND event_type='user_message'),0);") #[missionId] with
    | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 1
    | .error _ => 1
  if produced > 0 then return none
  -- Attempts so far: set when the turn that just ended was itself launched by a retry.
  let prior := match ← execParamQuery store.missionsDb
      ("SELECT c.reason FROM mission_continuations c WHERE c.mission_id=?1 AND c.reason LIKE 'empty_turn_retry:%' AND instr(COALESCE(" ++
       "(SELECT payload FROM mission_events WHERE mission_id=?1 AND event_type='user_message' ORDER BY id DESC LIMIT 1),''), c.id) > 0 LIMIT 1;") #[missionId] with
    | .ok rs => ((rs[1]?.bind (·[0]?)).bind fun r => (r.drop 17).toString.toNat?).getD 0
    | .error _ => maxEmptyTurnRetries
  if retryable && prior < maxEmptyTurnRetries then
    let cid ← newUuidV4
    let armed ← execParamQuery store.missionsDb
      ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
       "SELECT ?1,id,COALESCE(run_generation,1),1,CAST(?3 AS INTEGER),'time',?4,?5,?1,'','empty-turn-retry','','',1,?6,?6 FROM missions WHERE id=?2;")
      #[cid, missionId, s!"{nowSec + 20 * (prior.toUInt64 + 1)}", s!"empty_turn_retry:{prior + 1}",
        "Your previous turn ended without any output or tool call. Continue the task from where you left off.", nowIso]
    if armed.isOk then
      emitMissionEventAndBroadcast store broadcastHub? missionId "error"
        (renderCompact (.obj #[("message", .str s!"The model returned no output. Retrying ({prior + 1} of {maxEmptyTurnRetries})."),
          ("code", .str "empty_turn"), ("retryable", .bool true)])) nowIso
      return some "awaiting_user"
  emitMissionEventAndBroadcast store broadcastHub? missionId "error"
    (renderCompact (.obj #[("message", .str s!"The model returned no output after {prior + 1} attempt(s). The turn failed."),
      ("code", .str "empty_turn"), ("retryable", .bool false)])) nowIso
  return some "failed"

private def persistDiscoveredSessionId (store : CoreStore) (missionId sid : String) : IO Unit := do
  let clean := sid.trimAscii.toString
  if !clean.isEmpty then
    discard <| execParamQuery store.missionsDb
      "UPDATE missions SET session_id=?2, resumable=1 WHERE id=?1 AND COALESCE(session_id,'')<>?2;"
      #[missionId, clean]

private def ingestClaudeStreamLine
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (missionId rawLine nowIso : String)
    (acc : RemoteStreamAcc) : IO RemoteStreamAcc := do
  let trimmed := rawLine.trimAscii.toString
  if trimmed.isEmpty then return acc
  let .ok jv := OrbBin.Json.parse trimmed
    | return acc
  let mut next := acc
  if let some sid := (jv.fieldStr? "session_id").filter (!·.isEmpty) then
    if next.sessionId? != some sid then
      next := { next with sessionId? := some sid }
      persistDiscoveredSessionId store missionId sid
  let ty := (jv.fieldStr? "type").getD ""
  if ty == "stream_event" then
    let ev := jv.fieldOrNull "event"
    if (ev.fieldStr? "type") == some "content_block_delta" then
      let delta := ev.fieldOrNull "delta"
      let dty := (delta.fieldStr? "type").getD ""
      if dty == "text_delta" then
        let piece := (delta.fieldStr? "text").getD ""
        if !piece.isEmpty then
          let full := next.text ++ piece
          next := { next with text := full, sawPartialDeltas := true }
          emitMissionEventAndBroadcast store broadcastHub? missionId "text_delta"
            (renderCompact (.obj #[("content", .str full)])) nowIso
      else if dty == "thinking_delta" then
        let th := (delta.fieldStr? "thinking").getD ""
        if !th.isEmpty then
          emitMissionEventAndBroadcast store broadcastHub? missionId "thinking"
            (renderCompact (.obj #[("content", .str th)])) nowIso
  else if ty == "assistant" then
    let msg := jv.fieldOrNull "message"
    let blocks := (msg.fieldArr? "content").getD #[]
    for blk in blocks do
      let bty := (blk.fieldStr? "type").getD ""
      if bty == "tool_use" then
        let cid := (blk.fieldStr? "id").getD "tool"
        let nm := (blk.fieldStr? "name").getD "tool"
        let inp := (blk.field? "input").getD (.obj #[])
        emitMissionEventAndBroadcast store broadcastHub? missionId "tool_call"
          (renderCompact (.obj #[("tool_call_id", .str cid), ("tool_name", .str nm), ("name", .str nm), ("args", inp)])) nowIso
      else if bty == "text" && !next.sawPartialDeltas then
        let piece := (blk.fieldStr? "text").getD ""
        if !piece.isEmpty then
          let full := if next.text.isEmpty then piece else next.text ++ "\n\n" ++ piece
          next := { next with text := full }
          emitMissionEventAndBroadcast store broadcastHub? missionId "text_delta"
            (renderCompact (.obj #[("content", .str full)])) nowIso
  else if ty == "user" then
    let msg := jv.fieldOrNull "message"
    let blocks := (msg.fieldArr? "content").getD #[]
    for blk in blocks do
      if (blk.fieldStr? "type") == some "tool_result" then
        let cid := (blk.fieldStr? "tool_use_id").getD "tool"
        let isErr := (blk.fieldBool? "is_error").getD false
        let outVal := (blk.field? "content").getD (.str "")
        emitMissionEventAndBroadcast store broadcastHub? missionId "tool_result"
          (renderCompact (.obj #[
            ("tool_call_id", .str cid),
            ("is_error", .bool isErr),
            ("result", outVal)
          ])) nowIso
  else if ty == "result" then
    let isErr := (jv.fieldBool? "is_error").getD false
    let resTxt := (jv.fieldStr? "result").getD ""
    if isErr && !resTxt.isEmpty then
      next := { next with lastError? := some resTxt }
    else if !isErr && next.text.isEmpty && !resTxt.isEmpty then
      next := { next with text := resTxt }
      emitMissionEventAndBroadcast store broadcastHub? missionId "text_delta"
        (renderCompact (.obj #[("content", .str resTxt)])) nowIso
  return next

private def ingestRemoteHarnessLine
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (backend missionId rawLine nowIso : String)
    (acc : RemoteStreamAcc) : IO RemoteStreamAcc := do
  let bLow := backend.trimAscii.toString.toLower
  let harness := if bLow == "claude" then "claudecode" else bLow
  if harness == "claudecode" then
    let next ← ingestClaudeStreamLine store broadcastHub? missionId rawLine nowIso acc
    let active := ["\"type\":\"assistant\"", "\"type\":\"stream_event\""].any (fun k => (rawLine.splitOn k).length > 1)
    return { next with sawActivity := next.sawActivity || active }
  else
    let parsed := OrbBin.ClaudeControl.parseOneShotHarnessEvent harness rawLine
    let mut next := acc
    if let some sid := parsed.sessionId?.filter (!·.isEmpty) then
      if next.sessionId? != some sid then
        next := { next with sessionId? := some sid }
        persistDiscoveredSessionId store missionId sid
    if let some em := parsed.errorMsg? then
      next := { next with lastError? := some em }
    if parsed.thinking?.isSome || parsed.activity?.isSome || !parsed.textDelta.isEmpty then
      next := { next with sawActivity := true }
    if let some th := parsed.thinking? then
      emitMissionEventAndBroadcast store broadcastHub? missionId "thinking"
        (renderCompact (.obj #[("content", .str th)])) nowIso
    if let some act := parsed.activity? then
      let evTy := if act.done then "tool_result" else "tool_call"
      let pl := act.toJVal
      emitMissionEventAndBroadcast store broadcastHub? missionId evTy (renderCompact pl) nowIso
    if !parsed.textDelta.isEmpty then
      let (piece, lastMsg?) := OrbBin.ClaudeControl.joinHarnessText harness next.text next.lastMessageId? parsed
      let full := next.text ++ piece
      next := { next with text := full, lastMessageId? := lastMsg? }
      emitMissionEventAndBroadcast store broadcastHub? missionId "text_delta"
        (renderCompact (.obj #[("content", .str full)])) nowIso
    return next

private def splitCompleteLines (buf : String) : Array String × String := Id.run do
  let parts := buf.splitOn "\n"
  if parts.length ≤ 1 then
    return (#[], buf)
  let complete := (parts.take (parts.length - 1)).toArray.map fun l =>
    if l.endsWith "\r" then (l.dropEnd 1).toString else l
  let rem := parts.getLast!
  return (complete, rem)

/-! ## Remote Job Cancellation, Submission, Polling & Queued Follow-Up Drain -/

/-- Send `POST /jobs/:id/cancel` to the remote `OrbNode` for any live remote job on `missionId`. -/
def cancelActiveRemoteJobForMission
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (missionId reason : String)
    (cancelActor : String := "core") : IO Bool := do
  let mut jobId := ""
  let mut nodeId := ""
  if let .ok rRows ← execParamQuery store.missionsDb
      ("SELECT COALESCE(remote_job_id,''), COALESCE(owner_actor_id,''), COALESCE(scope_unit,'') " ++
       "FROM mission_runs WHERE mission_id=?1 ORDER BY generation DESC, rowid DESC LIMIT 1;")
      #[missionId] then
    if rRows.size > 1 then
      let rjid := (cell rRows[1]! 0).trimAscii.toString
      let actor := (cell rRows[1]! 1).trimAscii.toString
      let scope := (cell rRows[1]! 2).trimAscii.toString
      jobId :=
        if !rjid.isEmpty then rjid
        else if actor.startsWith "remote-job:" then (actor.drop 11).trimAscii.toString
        else ""
      if scope.startsWith "remote-node:" then
        nodeId := (scope.drop 12).trimAscii.toString
  if jobId.isEmpty then
    if let .ok mRows ← execParamQuery store.missionsDb
        "SELECT COALESCE(placement_job_id,'') FROM missions WHERE id=?1;" #[missionId] then
      if mRows.size > 1 then
        jobId := (cell mRows[1]! 0).trimAscii.toString
  if nodeId.isEmpty then
    if let some rn ← resolveMissionRemoteNode? store mc? missionId then
      nodeId := rn
  if jobId.isEmpty || nodeId.isEmpty then
    return false
  let effNode ← match ← resolveConcreteRemoteTargetNode mc? nodeId (some (store, missionId)) with
    | .ok n => pure n
    | .error _ => pure nodeId
  let hdrs := #[
    ("x-sandboxed-cancel-actor", if cancelActor.isEmpty then "core" else cancelActor),
    ("x-sandboxed-cancel-reason", if reason.isEmpty then "Mission stopped on Core" else reason)
  ]
  match ← callRemoteNodeHttpOpt relayHub? mc? effNode "POST" s!"/jobs/{jobId}/cancel" (some (.obj #[])) hdrs 10000 with
  | .ok (st, _, _, _, _) =>
    let nowIso := formatEpochIso8601Utc (← nowEpoch)
    discard <| execParamQuery store.missionsDb
      "UPDATE remote_node_jobs SET state='cancelled', updated_at=?2 WHERE job_id=?1;"
      #[jobId, nowIso]
    return (200 ≤ st && st < 300)
  | .error _ =>
    return false

private def popNextQueuedFollowup?
    (store : CoreStore)
    (missionId : String)
    (runGen : UInt64)
    (nowIso : String) : IO (Option String) := do
  let qRows ← execParamQuery store.missionsDb
    ("SELECT user_id, message_id, COALESCE(payload,'') FROM remote_message_queue " ++
     "WHERE mission_id=?1 AND state='waiting' AND COALESCE(phase,0)=0 ORDER BY rowid ASC LIMIT 1;")
    #[missionId]
  let .ok rs := qRows | return none
  if rs.size ≤ 1 then return none
  let uid := cell rs[1]! 0
  let msgId := cell rs[1]! 1
  let rawPl := cell rs[1]! 2
  let claimRes ← stepQueueItem store uid msgId 0 s!"{runGen}" s!"{store.bootEpoch}" "1" nowIso
  match claimRes with
  | .ok (.ok item) =>
    discard <| stepQueueItem store uid msgId 1 s!"{runGen}" s!"{store.bootEpoch}" "1" nowIso
    if !item.content.trimAscii.toString.isEmpty then
      return some item.content
    match OrbBin.Json.parse rawPl with
    | .ok jv =>
      let c := ((jv.field? "message").bind (·.fieldStr? "content")).orElse (fun _ => jv.fieldStr? "content") |>.getD ""
      return (if c.trimAscii.toString.isEmpty then none else some c)
    | .error _ => return none
  | _ => return none

mutual

/-- Background poller streaming NDJSON logs and terminal state for an active `OrbNode` job. -/
partial def spawnRemoteJobPoller
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (coreWorkDir missionId backend effNodeId jobId proxyTok : String)
    (initialOffset : Nat := 0) : IO Unit := do
  let claimed ← claimPolledJob sup jobId
  if !claimed then return ()
  discard <| IO.asTask (prio := .dedicated) do
    let mut offset : Nat := initialOffset
    let mut lineRem : String := ""
    let mut acc : RemoteStreamAcc := {}
    let mut cancelSent : Bool := false
    let mut keepRunning : Bool := true
    let mut consecNetErrors : Nat := 0
    -- A harness that never produces its first event (e.g. OpenCode after a failed model
    -- stream, which logs the error but does not exit) would otherwise hang the turn forever.
    -- Only fresh turns are watched: a poller resumed mid-turn may be inside a long tool call.
    let firstEventSecs := ((← IO.getEnv "SANDBOXED_TURN_FIRST_EVENT_SECS").bind String.toNat?).getD 900
    let turnStartSec ← nowEpoch
    while keepRunning do
      IO.sleep 350
      let nowSec ← nowEpoch
      let nowIso := formatEpochIso8601Utc nowSec
      -- Check if mission was cancelled/interrupted on Core
      if !cancelSent then
        if let .ok mRows ← execParamQuery store.missionsDb
            "SELECT status FROM missions WHERE id=?1;" #[missionId] then
          if mRows.size > 1 then
            let mst := cell mRows[1]! 0
            if mst == "cancelled" || mst == "interrupted" then
              cancelSent := true
              let hdrs := #[
                ("x-sandboxed-cancel-actor", "core"),
                ("x-sandboxed-cancel-reason", s!"Mission {mst} on Core")
              ]
              discard <| callRemoteNodeHttpOpt relayHub? mc? effNodeId "POST" s!"/jobs/{jobId}/cancel" (some (.obj #[])) hdrs 8000
          else
            keepRunning := false
      if keepRunning then
        -- 1. Drain available log chunk
        let mut drainedMore := true
        let mut drainLoops : Nat := 0
        while drainedMore && drainLoops < 8 do
          drainLoops := drainLoops + 1
          match ← callRemoteNodeHttpOpt relayHub? mc? effNodeId "GET" s!"/jobs/{jobId}/log?offset={offset}&max_bytes=262144" none #[] 12000 with
          | .error _ =>
            drainedMore := false
          | .ok (lStatus, _, lJv?, _, _) =>
            if 200 ≤ lStatus && lStatus < 300 then
              if let some ljv := lJv? then
                let chunk := (ljv.fieldStr? "data").getD ""
                let nextOff := (ljv.fieldNat? "next_offset").getD (offset + chunk.utf8ByteSize)
                let logLen := (ljv.fieldNat? "log_len").getD nextOff
                if !chunk.isEmpty then
                  let (lines, rem) := splitCompleteLines (lineRem ++ chunk)
                  lineRem := rem
                  for ln in lines do
                    acc ← ingestRemoteHarnessLine store broadcastHub? backend missionId ln nowIso acc
                if nextOff > offset then
                  discard <| execParamQuery store.missionsDb
                    ("INSERT INTO remote_log_offsets(job_id,published_offset,updated_at) VALUES(?1,CAST(?2 AS INTEGER),?3) " ++
                     "ON CONFLICT(job_id) DO UPDATE SET published_offset=excluded.published_offset, updated_at=excluded.updated_at;")
                    #[jobId, s!"{nextOff}", nowIso]
                offset := nextOff
                drainedMore := nextOff < logLen && !chunk.isEmpty
              else
                drainedMore := false
            else
              drainedMore := false

        -- 2. Poll job state
        match ← callRemoteNodeHttpOpt relayHub? mc? effNodeId "GET" s!"/jobs/{jobId}" none #[] 12000 with
        | .error netErr =>
          consecNetErrors := consecNetErrors + 1
          if consecNetErrors ≥ 60 then
            keepRunning := false
            if !proxyTok.isEmpty then revokeSingleMissionProxyToken store proxyTok
            let reason := "remote_node_unreachable"
            discard <| execParamQuery store.missionsDb
              "UPDATE mission_runs SET execution_state='terminal', terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND execution_state NOT IN ('terminal','completed','failed','aborted');"
              #[missionId, reason, nowIso]
            discard <| execParamQuery store.missionsDb
              "UPDATE remote_node_jobs SET state='lost', updated_at=?2 WHERE job_id=?1;" #[jobId, nowIso]
            discard <| execParamQuery store.missionsDb
              "UPDATE missions SET status='failed', terminal_reason=?2, state_revision=state_revision+1, updated_at=?3 WHERE id=?1 AND status IN ('active','pending');"
              #[missionId, reason, nowIso]
            emitMissionEventAndBroadcast store broadcastHub? missionId "error"
              (renderCompact (.obj #[("message", .str s!"Lost contact with remote node `{effNodeId}`: {netErr}")])) nowIso
            emitMissionEventAndBroadcast store broadcastHub? missionId "mission_status_changed"
              (renderCompact (.obj #[("status", .str "failed"), ("reason", .str reason)])) nowIso
        | .ok (jStatus, jTxt, jJv?, _, _) =>
          if jStatus == 404 then
            keepRunning := false
            if !proxyTok.isEmpty then revokeSingleMissionProxyToken store proxyTok
            let reason := "remote_job_missing_on_node"
            discard <| execParamQuery store.missionsDb
              "UPDATE mission_runs SET execution_state='terminal', terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND execution_state NOT IN ('terminal','completed','failed','aborted');"
              #[missionId, reason, nowIso]
            discard <| execParamQuery store.missionsDb
              "UPDATE remote_node_jobs SET state='lost', updated_at=?2 WHERE job_id=?1;" #[jobId, nowIso]
            discard <| execParamQuery store.missionsDb
              "UPDATE missions SET status='interrupted', terminal_reason=?2, state_revision=state_revision+1, updated_at=?3 WHERE id=?1 AND status IN ('active','pending');"
              #[missionId, reason, nowIso]
            emitMissionEventAndBroadcast store broadcastHub? missionId "mission_status_changed"
              (renderCompact (.obj #[("status", .str "interrupted"), ("reason", .str reason)])) nowIso
          else if 200 ≤ jStatus && jStatus < 300 then
            consecNetErrors := 0
            let jv := jJv?.getD (.obj #[])
            let jState := (jv.fieldStr? "state").getD "running"
            discard <| execParamQuery store.missionsDb
              "UPDATE mission_runs SET updated_at=?2 WHERE mission_id=?1 AND remote_job_id=?3 AND execution_state NOT IN ('terminal','completed','failed','aborted');"
              #[missionId, nowIso, jobId]
            discard <| execParamQuery store.missionsDb
              "UPDATE remote_node_jobs SET state=?2, updated_at=?3 WHERE job_id=?1;"
              #[jobId, jState, nowIso]
            discard <| execParamQuery store.projectsDb
              "UPDATE remote_jobs SET state=?2, heartbeat_at=?3, finished_at=CASE WHEN ?2 IN ('succeeded','failed','cancelled','lost') THEN ?3 ELSE finished_at END, updated_at=?3 WHERE job_id=?1;"
              #[jobId, jState, nowIso]
            if jState == "running" && initialOffset == 0 && firstEventSecs > 0 && !acc.sawActivity &&
                nowSec ≥ turnStartSec + firstEventSecs.toUInt64 then
              keepRunning := false
              let hdrs := #[("x-sandboxed-cancel-actor", "core"), ("x-sandboxed-cancel-reason", "No harness output")]
              discard <| callRemoteNodeHttpOpt relayHub? mc? effNodeId "POST" s!"/jobs/{jobId}/cancel" (some (.obj #[])) hdrs 8000
              if !proxyTok.isEmpty then revokeSingleMissionProxyToken store proxyTok
              let reason := "harness_no_output"
              let logTail := ((jv.fieldStr? "log_tail").getD "").trimAscii.toString
              let detail := acc.lastError?.getD (if logTail.isEmpty then "" else (logTail.takeEnd 600).toString)
              discard <| execParamQuery store.missionsDb
                "UPDATE mission_runs SET execution_state='terminal', terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND execution_state NOT IN ('terminal','completed','failed','aborted');"
                #[missionId, reason, nowIso]
              discard <| execParamQuery store.missionsDb
                "UPDATE missions SET status='failed', terminal_reason=?2, state_revision=state_revision+1, updated_at=?3 WHERE id=?1 AND status IN ('active','pending');"
                #[missionId, reason, nowIso]
              emitMissionEventAndBroadcast store broadcastHub? missionId "error"
                (renderCompact (.obj #[("message", .str (s!"{backend} produced no output for {firstEventSecs / 60} min and was stopped." ++
                  (if detail.isEmpty then "" else s!" Last log: {detail}")))])) nowIso
              emitMissionEventAndBroadcast store broadcastHub? missionId "mission_status_changed"
                (renderCompact (.obj #[("status", .str "failed"), ("reason", .str reason)])) nowIso
            else if jState == "succeeded" || jState == "failed" || jState == "cancelled" || jState == "lost" then
              -- Final log drain after terminal transition
              if let .ok (flSt, _, flJv?, _, _) ← callRemoteNodeHttpOpt relayHub? mc? effNodeId "GET" s!"/jobs/{jobId}/log?offset={offset}&max_bytes=262144" none #[] 10000 then
                if 200 ≤ flSt && flSt < 300 then
                  if let some flJv := flJv? then
                    let chunk := (flJv.fieldStr? "data").getD ""
                    if !chunk.isEmpty then
                      let (lines, rem) := splitCompleteLines (lineRem ++ chunk)
                      lineRem := rem
                      for ln in lines do
                        acc ← ingestRemoteHarnessLine store broadcastHub? backend missionId ln nowIso acc
              if !lineRem.trimAscii.toString.isEmpty then
                acc ← ingestRemoteHarnessLine store broadcastHub? backend missionId lineRem nowIso acc
                lineRem := ""
              keepRunning := false
              if !proxyTok.isEmpty then
                revokeSingleMissionProxyToken store proxyTok
              let nodeErr? := (jv.fieldStr? "error").filter (!·.trimAscii.toString.isEmpty)
              let logTail := (jv.fieldStr? "log_tail").getD ""
              let exitCode := (jv.fieldInt? "exit_code").getD (if jState == "succeeded" then 0 else 1)
              let finalText :=
                if !acc.text.trimAscii.toString.isEmpty then acc.text
                else if jState == "succeeded" && !logTail.trimAscii.toString.isEmpty &&
                        backend != "opencode" && backend != "claudecode" && backend != "claude" && backend != "codex" then
                  logTail.trimAscii.toString
                else ""
              if jState == "succeeded" && !finalText.isEmpty then
                emitMissionEventAndBroadcast store broadcastHub? missionId "assistant_message"
                  (renderCompact (.obj #[("content", .str finalText)])) nowIso
              else if jState != "succeeded" && jState != "cancelled" then
                let errMsg :=
                  acc.lastError?
                    |>.orElse (fun _ => nodeErr?)
                    |>.getD (if !logTail.trimAscii.toString.isEmpty then (logTail.trimAscii.toString.take 600).toString
                             else s!"Remote job `{jobId}` {jState} (exit_code={exitCode})")
                emitMissionEventAndBroadcast store broadcastHub? missionId "error"
                  (renderCompact (.obj #[("message", .str errMsg)])) nowIso

              let termReason :=
                if jState == "succeeded" then "completed"
                else if jState == "cancelled" then "cancelled"
                else "remote_job_failed"
              discard <| execParamQuery store.missionsDb
                "UPDATE mission_runs SET execution_state='terminal', terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND (remote_job_id=?4 OR execution_state NOT IN ('terminal','completed','failed','aborted'));"
                #[missionId, termReason, nowIso, jobId]

              -- Check if a queued user message is waiting for this mission
              let mut curRunGen : UInt64 := 1
              let mut mRec? : Option MissionRecord := none
              let mut curSid? : Option String := acc.sessionId?
              if let some mr ← getMission? store missionId then
                mRec? := some mr
                curRunGen := mr.runGeneration
              if curSid?.isNone then
                if let .ok sRows ← execParamQuery store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[missionId] then
                  if sRows.size > 1 then
                    let s := (cell sRows[1]! 0).trimAscii.toString
                    if !s.isEmpty then curSid? := some s

              let nextQueued? ←
                if jState == "cancelled" then pure none
                else popNextQueuedFollowup? store missionId curRunGen nowIso
              match nextQueued?, mRec? with
              | some nextPrompt, some mr =>
                releasePolledJob sup jobId
                emitMissionEventAndBroadcast store broadcastHub? missionId "user_message"
                  (renderCompact (.obj #[("type", .str "user_message"), ("content", .str nextPrompt), ("source", .str "queue")])) nowIso
                let followSpec : RemoteTurnSpec := {
                  missionId        := missionId
                  targetNodeId     := effNodeId
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
                  prompt           := nextPrompt
                  resumeSessionId? := curSid?
                }
                discard <| submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup coreWorkDir followSpec nowSec
                return ()
              | _, _ =>
                -- Check if mission has an armed wakeup continuation (`phase = 1`):
                -- `verifyWakeupContinuationAdmit` (`op=2`) requires `ownerTerminal == 0 && ownerBusy == 0` (`awaiting_user`).
                let mut armedWakeups : Nat := 0
                if let .ok cRows ← execParamQuery store.missionsDb
                    "SELECT COUNT(*) FROM mission_continuations WHERE mission_id=?1 AND phase=1;" #[missionId] then
                  if cRows.size > 1 then
                    armedWakeups := cellNat cRows[1]! 0
                -- A "succeeded" job with no text and no tool call did no work.
                let emptyVerdict? ←
                  if jState == "succeeded" && finalText.isEmpty then
                    settleEmptyTurn store broadcastHub? missionId nowIso nowSec
                  else pure none
                let nextMissionStatus :=
                  if let some verdict := emptyVerdict? then verdict
                  else if jState == "succeeded" then
                    if armedWakeups > 0 then "awaiting_user" else "completed"
                  else if jState == "cancelled" then "cancelled"
                  else "failed"
                discard <| execParamQuery store.missionsDb
                  ("UPDATE missions SET status=?2, terminal_reason=?3, state_revision=state_revision+1, updated_at=?4 " ++
                   "WHERE id=?1 AND status NOT IN ('cancelled','interrupted');")
                  #[missionId, nextMissionStatus,
                    if emptyVerdict?.isSome then (if nextMissionStatus == "failed" then "empty_turn" else "empty_turn_retry")
                    else if nextMissionStatus == "awaiting_user" then "awaiting_wakeup" else termReason, nowIso]
                emitMissionEventAndBroadcast store broadcastHub? missionId "mission_status_changed"
                  (renderCompact (.obj #[("status", .str nextMissionStatus), ("content", .str finalText)])) nowIso
          else
            let _ := jTxt
            consecNetErrors := consecNetErrors + 1
    releasePolledJob sup jobId

/-- Submit an asynchronous harness turn to `OrbNode` (`POST /jobs`), persist `mission_runs` + `remote_node_jobs`,
    transition `missions.status = 'active'`, and launch the live streaming poller. -/
partial def submitRemoteMissionTurn
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (coreWorkDir : String)
    (spec : RemoteTurnSpec)
    (nowSec : UInt64) : IO (Except String String) := do
  let effTarget ← match ← resolveConcreteRemoteTargetNode mc? spec.targetNodeId (some (store, spec.missionId)) with
    | .ok n => pure n
    | .error e => return .error e

  -- Resolve node auth `(leaseNodeId, nodeSecret)` so we can sign the HMAC `job:submit` lease token
  let (_, staticNodes) ← loadStaticRemoteNodes
  let spec ← match ← bindRemoteTurnOwner store mc? spec effTarget staticNodes with
    | .ok owned => pure owned
    | .error error => return .error error
  let (leaseNodeId, nodeSecret) ← do
    if let some sn := staticNodes.find? (fun n => n.id == effTarget) then
      let some tok ← resolveStaticNodeToken? sn
        | return .error s!"remote node `{sn.id}` has no token in `{sn.tokenEnv}`"
      pure (sn.id, tok)
    else
      let some mc := mc?
        | return .error s!"unknown remote node `{effTarget}`"
      let some mid ← resolveManagedMachineId? mc effTarget
        | return .error s!"unknown remote node `{effTarget}`"
      let some (nid, ntok) ← getManagedNodeAuth? mc mid
        | return .error s!"managed node `{mid}` has no enrolled token"
      pure (nid, ntok)

  let prep ← match ← prepareRemoteHarnessCommand store sup coreWorkDir effTarget spec nowSec with
    | .ok p => pure p
    | .error e => return .error e

  let jobId ← newUuidV4
  let ownerUser? ← if spec.ownerUserId.isEmpty then pure none else getUserById? store spec.ownerUserId
  unless spec.ownerUserId.isEmpty || (ownerUser?.map (fun u => !u.disabled)).getD false do
    return .error "remote_owner_unavailable"
  let callerRole :=
    match ownerUser? with
    | some u => if u.role == "member" then "member" else "admin"
    | none   => "admin"
  let unixUser? :=
    ownerUser?.bind fun u =>
      (u.unixUsername?.map (·.trimAscii.toString)).filter (!·.isEmpty)
  let leaseTok := signRemoteNodeLeaseToken nodeSecret spec.missionId leaseNodeId "job:submit" (nowSec + 900) (some jobId) spec.ownerUserId callerRole unixUser?
  let envObj : JVal := .obj (prep.envPairs.map fun (k, v) => (k, .str v))
  let authArr : JVal := .arr (prep.managedAuth.map JVal.str)
  let compVal : JVal := match spec.companionOf? with | some c => .str c | none => .null
  let placeWire :=
    if spec.placementKind == "managed_vm" || spec.placementKind.startsWith "managed-" then "managed_vm"
    else if spec.placementKind == "remote" || spec.placementKind == "remote_node" then "remote"
    else "managed"
  let submitBody : JVal := .obj #[
    ("job_id", .str jobId),
    ("mission_id", .str spec.missionId),
    ("authority_mode", .str (if spec.authorityMode == "readonly" then "readonly" else "writer")),
    ("placement_kind", .str placeWire),
    ("reserved_disk_gib", JVal.uint64 spec.reservedDiskGib),
    ("lease_token", .str leaseTok),
    ("payload", .obj #[
      ("kind", .str "raw_command"),
      ("command", .str prep.command),
      ("side_question", .bool spec.sideQuestion),
      ("companion_of", compVal),
      ("coordinator_priority", .bool spec.coordinatorPrio),
      ("is_child_worker", .bool false),
      ("native_goal", .bool false),
      ("long_running", .bool true),
      ("env", envObj),
      ("managed_auth", authArr)
    ])
  ]

  match ← callRemoteNodeHttpOpt relayHub? mc? effTarget "POST" "/jobs" (some submitBody) #[] 20000 with
  | .error e =>
    if !prep.proxyToken.isEmpty then revokeSingleMissionProxyToken store prep.proxyToken
    return .error s!"remote_dispatch_failed:{e}"
  | .ok (status, respTxt, _, _, _) =>
    if status < 200 || status ≥ 300 then
      if !prep.proxyToken.isEmpty then revokeSingleMissionProxyToken store prep.proxyToken
      return .error s!"remote_node_rejected_{status}:{respTxt}"
    let nowIso := formatEpochIso8601Utc nowSec
    ensureDurableJobsTableLocal store
    let recMeta := renderCompact (.obj #[
      ("backend", .str spec.backend),
      ("side_question", .bool spec.sideQuestion)
    ])
    discard <| execParamQuery store.missionsDb
      ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
       "VALUES(?1,?2,?3,'running',?4,?5,?5) " ++
       "ON CONFLICT(job_id) DO UPDATE SET state='running', node_id=excluded.node_id, updated_at=excluded.updated_at;")
      #[jobId, spec.missionId, effTarget, recMeta, nowIso]
    discard <| execParamQuery store.projectsDb
      ("INSERT INTO remote_jobs(job_id,mission_id,node_id,kind,state,started_at,accepted_at,heartbeat_at,updated_at) " ++
       "VALUES(?1,?2,?3,'mission','running',?4,?4,?4,?4) " ++
       "ON CONFLICT(job_id) DO UPDATE SET state='running', node_id=excluded.node_id, heartbeat_at=excluded.updated_at, updated_at=excluded.updated_at;")
      #[jobId, spec.missionId, effTarget, nowIso]

    let runId ← newUuidV4
    let txRes ← withImmediateTx store.missionsDb do
      let gRows ← execParamQueryUnlocked store.missionsDb
        "SELECT COALESCE(run_generation,1), COALESCE((SELECT MAX(generation) FROM mission_runs WHERE mission_id=?1),0) FROM missions WHERE id=?1;"
        #[spec.missionId]
      let mut nextGen : Nat := 1
      if let .ok grs := gRows then
        if grs.size > 1 then
          let mg := cellNat grs[1]! 0
          let rg := cellNat grs[1]! 1
          nextGen := if rg == 0 then Nat.max 1 mg else Nat.max mg (rg + 1)
      let insRun ← insertMissionRunUnlocked
        store.missionsDb runId spec.missionId s!"{nextGen}" "running" "" jobId nowIso true
        s!"remote-job:{jobId}" s!"remote-node:{effTarget}"
      if let .error e := insRun then return .error e
      carryArmedWakeupsForward (execParamQueryUnlocked store.missionsDb) spec.missionId nextGen nowIso
      execParamQueryUnlocked store.missionsDb
        ("UPDATE missions SET status='active', terminal_reason='remote_node_job', placement_job_id=?2, " ++
         "run_generation=CAST(?3 AS INTEGER), state_revision=state_revision+1, updated_at=?4 WHERE id=?1;")
        #[spec.missionId, jobId, s!"{nextGen}", nowIso]
    if let .error dbErr := txRes then
      let _ := dbErr
      pure ()
    emitMissionEventAndBroadcast store broadcastHub? spec.missionId "mission_status_changed"
      (renderCompact (.obj #[("status", .str "active"), ("job_id", .str jobId), ("remote_node_id", .str effTarget)])) nowIso
    spawnRemoteJobPoller store mc? relayHub? broadcastHub? sup coreWorkDir spec.missionId spec.backend effTarget jobId prep.proxyToken 0
    return .ok jobId

end

/-! ## Startup Re-Attachment of Live Remote Jobs -/

/-- Re-attach background log/state pollers for all non-terminal `remote-job:*` `mission_runs` on Core startup. -/
def reattachActiveRemoteJobsOnStartup
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (coreWorkDir : String) : IO Nat := do
  ensureDurableJobsTableLocal store
  let qRes ← execParamQuery store.missionsDb
    ("SELECT r.mission_id, COALESCE(r.remote_job_id,''), COALESCE(r.owner_actor_id,''), COALESCE(r.scope_unit,''), " ++
     "COALESCE(m.backend,'codex'), COALESCE(r.updated_at,'') " ++
     "FROM mission_runs r JOIN missions m ON m.id = r.mission_id " ++
     "WHERE r.execution_state NOT IN ('terminal','completed','failed','aborted') " ++
     "AND m.status IN ('active','pending');")
    #[]
  let .ok rows := qRes | return 0
  let mut count : Nat := 0
  for i in [1:rows.size] do
    let row := rows[i]!
    let mid := (cell row 0).trimAscii.toString
    let rjid := (cell row 1).trimAscii.toString
    let actor := (cell row 2).trimAscii.toString
    let scope := (cell row 3).trimAscii.toString
    let backend := (cell row 4).trimAscii.toString
    let runUpdated := (cell row 5).trimAscii.toString
    let jobId :=
      if !rjid.isEmpty then rjid
      else if actor.startsWith "remote-job:" then (actor.drop 11).trimAscii.toString
      else ""
    if !mid.isEmpty && !jobId.isEmpty then
      let nodeFromScope :=
        if scope.startsWith "remote-node:" then some ((scope.drop 12).trimAscii.toString) else none
      let resolvedNode? ← match nodeFromScope.filter (!·.isEmpty) with
        | some n => pure (some n)
        | none => resolveMissionRemoteNode? store mc? mid
      if let some rawNode := resolvedNode? then
        let effNode ← match ← resolveConcreteRemoteTargetNode mc? rawNode (some (store, mid)) with
          | .ok n => pure n
          | .error _ => pure rawNode
        -- Determine safe resume byte offset (`remote_log_offsets` first, then remote `log_len` fallback)
        let mut startOff : Nat := 0
        if let .ok offRows ← execParamQuery store.missionsDb
            "SELECT COALESCE(published_offset,0) FROM remote_log_offsets WHERE job_id=?1 LIMIT 1;" #[jobId] then
          if offRows.size > 1 then
            startOff := cellNat offRows[1]! 0
        if startOff == 0 && !runUpdated.isEmpty then
          if let .ok evCntRows ← execParamQuery store.missionsDb
              "SELECT COUNT(*) FROM mission_events WHERE mission_id=?1 AND COALESCE(created_at,timestamp,'') >= ?2;"
              #[mid, runUpdated] then
            if evCntRows.size > 1 && cellNat evCntRows[1]! 0 > 0 then
              if let .ok (stCode, _, ljv?, _, _) ← callRemoteNodeHttpOpt relayHub? mc? effNode "GET" s!"/jobs/{jobId}/log?offset=0&max_bytes=1" none #[] 6000 then
                if 200 ≤ stCode && stCode < 300 then
                  startOff := (ljv?.bind (·.fieldNat? "log_len")).getD 0
        spawnRemoteJobPoller store mc? relayHub? broadcastHub? sup coreWorkDir mid backend effNode jobId "" startOff
        count := count + 1
  return count

/-! ## Legacy `automations` Migration & Background Wakeup Continuation Scheduler -/

/-- Migrate active rows from legacy Rust `automations` table into `mission_continuations` (`phase = 1`). -/
def migrateLegacyAutomations (store : CoreStore) (nowSec : UInt64) : IO Nat := do
  let tblChk ← execParamQuery store.missionsDb
    "SELECT name FROM sqlite_master WHERE type='table' AND name='automations';" #[]
  let .ok trs := tblChk | return 0
  if trs.size ≤ 1 then return 0
  let colsRes ← execParamQuery store.missionsDb "PRAGMA table_info(automations);" #[]
  let .ok colRows := colsRes | return 0
  let mut colNames : Array String := #[]
  for i in [1:colRows.size] do
    if let some nm := colRows[i]![1]? then
      colNames := colNames.push nm
  let hasSplitCmd := colNames.contains "command_source_data"
  let hasJsonCmd := colNames.contains "command_source"
  let cmdExpr :=
    if hasSplitCmd then "COALESCE(command_source_data,'')"
    else if hasJsonCmd then "COALESCE(command_source,'')"
    else "''"
  let hasTrigType := colNames.contains "trigger_type"
  let hasTrigData := colNames.contains "trigger_data"
  let trigTypeExpr := if hasTrigType then "COALESCE(trigger_type,'interval')" else "'interval'"
  let trigDataExpr := if hasTrigData then "COALESCE(trigger_data,'{}')" else "'{}'"
  let lastTrigExpr := if colNames.contains "last_triggered_at" then "COALESCE(last_triggered_at,'')" else "''"
  let createdExpr := if colNames.contains "created_at" then "COALESCE(created_at,'')" else "''"
  let stopPolExpr := if colNames.contains "stop_policy" then "COALESCE(stop_policy,'')" else "''"

  let selSql :=
    s!"SELECT id, mission_id, {cmdExpr}, {trigTypeExpr}, {trigDataExpr}, {createdExpr}, {lastTrigExpr}, {stopPolExpr} " ++
    "FROM automations WHERE COALESCE(active,0) = 1 LIMIT 64;"
  let .ok aRows ← execParamQuery store.missionsDb selSql #[]
    | return 0
  if aRows.size ≤ 1 then return 0
  let nowIso := formatEpochIso8601Utc nowSec
  let mut migrated : Nat := 0
  for i in [1:aRows.size] do
    let r := aRows[i]!
    let aid := (cell r 0).trimAscii.toString
    let mid := (cell r 1).trimAscii.toString
    let rawCmd := (cell r 2).trimAscii.toString
    let trigType := (cell r 3).trimAscii.toString.toLower
    let rawTrig := (cell r 4).trimAscii.toString
    let createdAt := (cell r 5).trimAscii.toString
    let lastTrig := (cell r 6).trimAscii.toString
    let stopPol := (cell r 7).trimAscii.toString
    if !aid.isEmpty && !mid.isEmpty then
      let mRows ← execParamQuery store.missionsDb
        "SELECT status, COALESCE(run_generation,1) FROM missions WHERE id=?1;" #[mid]
      match mRows with
      | .ok mrs =>
        if mrs.size ≤ 1 then
          discard <| execParamQuery store.missionsDb "UPDATE automations SET active=0 WHERE id=?1;" #[aid]
        else
          let mStatus := cell mrs[1]! 0
          let mRunGen := Nat.max 1 (cellNat mrs[1]! 1)
          if mStatus == "cancelled" || mStatus == "failed" || mStatus == "not_feasible" then
            discard <| execParamQuery store.missionsDb "UPDATE automations SET active=0 WHERE id=?1;" #[aid]
          else
            let prompt :=
              match OrbBin.Json.parse rawCmd with
              | .ok jv =>
                (jv.fieldStr? "content")
                  |>.orElse (fun _ => jv.fieldStr? "prompt")
                  |>.orElse (fun _ => jv.asStr?)
                  |>.getD (if rawCmd.isEmpty then "Continue." else rawCmd)
              | .error _ => if rawCmd.isEmpty then "Continue." else rawCmd
            let trigJv := (OrbBin.Json.parse rawTrig).toOption.getD (.obj #[])
            let baseEpoch :=
              (if !lastTrig.isEmpty then parseIso8601EpochU64? lastTrig else none)
                |>.orElse (fun _ => if !createdAt.isEmpty then parseIso8601EpochU64? createdAt else none)
                |>.getD nowSec
            let secs :=
              (trigJv.fieldUInt64? "seconds")
                |>.orElse (fun _ => trigJv.fieldUInt64? "interval_seconds")
                |>.orElse (fun _ => trigJv.fieldUInt64? "delay_seconds")
                |>.getD 300
            let explicitAt? :=
              (trigJv.fieldStr? "at")
                |>.orElse (fun _ => trigJv.fieldStr? "next_at")
                |>.bind parseIso8601EpochU64?
            let jobId := (trigJv.fieldStr? "job_id").getD ""
            let isJobTrig := trigType == "job" || trigType == "durable_job_terminal" || !jobId.isEmpty
            let effTrigKind := if isJobTrig then "durable_job_terminal" else "time"
            let dueEpoch :=
              if isJobTrig then nowSec + 86400
              else match explicitAt? with
                | some ep => ep
                | none => baseEpoch + secs
            let isRecurring :=
              !isJobTrig && (trigType == "interval") &&
              stopPol != "after_first" && stopPol != "\"after_first\"" && stopPol != "{\"type\":\"after_first\"}"
            let recurrenceStr := if isRecurring then s!"interval:{Nat.max 60 secs.toNat}" else ""
            let stopFirstInt := if isRecurring then "0" else "1"
            let cid := s!"leg-auto-{aid}"
            let reqId := s!"legacy-automation:{aid}"
            -- Ensure mission is not parked in terminal `completed` while holding an active legacy wakeup
            if mStatus == "completed" then
              discard <| execParamQuery store.missionsDb
                "UPDATE missions SET status='awaiting_user', terminal_reason='awaiting_wakeup', state_revision=state_revision+1, updated_at=?2 WHERE id=?1 AND status='completed';"
                #[mid, nowIso]
            -- Supersede any older time continuation on this mission if migrating a time trigger so `idx` / invariant holds
            if effTrigKind == "time" then
              discard <| execParamQuery store.missionsDb
                "UPDATE mission_continuations SET phase=4, updated_at=?2 WHERE mission_id=?1 AND trigger_kind='time' AND phase=1 AND id<>?3;"
                #[mid, nowIso, cid]
            discard <| execParamQuery store.missionsDb
              ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
               "VALUES(?1,?2,CAST(?3 AS INTEGER),1,CAST(?4 AS INTEGER),?5,'legacy_automation',?6,?7,?8,'legacy-automations-migration','',?9,CAST(?10 AS INTEGER),?11,?11) " ++
               "ON CONFLICT(id) DO NOTHING;")
              #[cid, mid, s!"{mRunGen}", s!"{dueEpoch}", effTrigKind, prompt, reqId, jobId, recurrenceStr, stopFirstInt, nowIso]
            discard <| execParamQuery store.missionsDb "UPDATE automations SET active=0 WHERE id=?1;" #[aid]
            migrated := migrated + 1
      | .error _ => pure ()
  return migrated

/-- Launch attempts a one-shot wake-up gets before it is retired as `launch_failed`. -/
def maxWakeupLaunchTries : Nat := 10

/-- Evaluate due `mission_continuations` (`time` and `durable_job_terminal`) and wake idle missions. -/
def tickContinuationScheduler
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (warmMgr? : Option OrbBin.ClaudeControl.WarmHarnessManager)
    (coreWorkDir : String)
    (localFallbackLaunch? : Option (MissionRecord → String → Option String → IO Bool) := none)
    (nowOverride? : Option UInt64 := none) : IO Nat := do
  let nowSec ← match nowOverride? with | some t => pure t | none => nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  discard <| migrateLegacyAutomations store nowSec
  ensureDurableJobsTableLocal store
  let dueRes ← execParamQuery store.missionsDb
    ("SELECT id, mission_id, COALESCE(run_generation,1), COALESCE(due_epoch,0), COALESCE(trigger_kind,'time'), " ++
     "COALESCE(prompt,''), COALESCE(reason,''), COALESCE(job_id,''), COALESCE(recurrence,''), COALESCE(stop_after_first,1), COALESCE(error,'') " ++
     "FROM mission_continuations " ++
     "WHERE phase = 1 AND (" ++
     "  (trigger_kind = 'time' AND due_epoch <= CAST(?1 AS INTEGER)) OR " ++
     "  trigger_kind = 'durable_job_terminal'" ++
     ") ORDER BY due_epoch ASC LIMIT 256;")
    #[s!"{nowSec}"]
  let .ok rows := dueRes | return 0
  if rows.size ≤ 1 then return 0
  let mut fired : Nat := 0
  for i in [1:rows.size] do
    let r := rows[i]!
    let cid := (cell r 0).trimAscii.toString
    let mid := (cell r 1).trimAscii.toString
    let cGen := (cellNat r 2).toUInt64
    let dueEp := (cellNat r 3).toUInt64
    let trigKind := (cell r 4).trimAscii.toString
    let rawPrompt := cell r 5
    let reason := cell r 6
    let jobId := (cell r 7).trimAscii.toString
    let recurrence := (cell r 8).trimAscii.toString
    let stopFirst := cellNat r 9 != 0
    -- Launch attempts already made for this wake-up (`launch_retry:N`).
    let rowErr := (cell r 10).trimAscii.toString
    let tries := if rowErr.startsWith "launch_retry:" then ((rowErr.drop 13).toString.toNat?).getD 0 else 0
    let mut jobDue := trigKind != "durable_job_terminal" || dueEp ≤ nowSec
    -- A wake-up waiting out its retry backoff is not due early, even if its job is terminal.
    if !jobDue && !jobId.isEmpty && tries == 0 then
      if let .ok jr1 ← execParamQuery store.missionsDb
          "SELECT 1 FROM remote_node_jobs WHERE job_id=?1 AND state IN ('succeeded','failed','cancelled','lost') LIMIT 1;" #[jobId] then
        if jr1.size > 1 then jobDue := true
      if !jobDue then
        if let .ok jr2 ← execParamQuery store.projectsDb
            "SELECT 1 FROM remote_jobs WHERE job_id=?1 AND state IN ('succeeded','failed','cancelled','lost') LIMIT 1;" #[jobId] then
          if jr2.size > 1 then jobDue := true
    if jobDue then
      if let some mr ← getMission? store mid then
        if mr.status == "cancelled" || mr.status == "failed" || mr.status == "not_feasible" then
          discard <| execParamQuery store.missionsDb
            "UPDATE mission_continuations SET phase=4, error='owner_terminal', updated_at=?2 WHERE id=?1 AND phase=1;"
            #[cid, nowIso]
        else if mr.runGeneration != cGen then
          discard <| execParamQuery store.missionsDb
            "UPDATE mission_continuations SET phase=3, error='stale_run_generation', updated_at=?2 WHERE id=?1 AND phase=1;"
            #[cid, nowIso]
        else if mr.status == "active" || mr.status == "pending" || mr.status == "waiting_background" then
          -- Mission is currently executing a turn; keep armed so it fires once idle
          pure ()
        else
          -- If legacy mission was parked in `completed`, normalize to `awaiting_user` so `verifyWakeupContinuationAdmit` (`op=2`) admits
          if mr.status == "completed" then
            discard <| execParamQuery store.missionsDb
              "UPDATE missions SET status='awaiting_user', terminal_reason='awaiting_wakeup', state_revision=state_revision+1, updated_at=?2 WHERE id=?1 AND status='completed';"
              #[mid, nowIso]
          -- A job wake-up is armed with a far deadline; once its job is terminal it is due now.
          if trigKind == "durable_job_terminal" && dueEp > nowSec then
            discard <| execParamQuery store.missionsDb
              "UPDATE mission_continuations SET due_epoch=CAST(?2 AS INTEGER) WHERE id=?1 AND phase=1;" #[cid, s!"{nowSec}"]
          match ← actOnContinuation store cid "resume" nowIso nowSec with
          | .ok (.ok _) =>
            let mut resumeSid? : Option String := none
            if let .ok sRows ← execParamQuery store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
              if sRows.size > 1 then
                let s := (cell sRows[1]! 0).trimAscii.toString
                if !s.isEmpty then resumeSid? := some s

            let effPrompt :=
              if !rawPrompt.trimAscii.toString.isEmpty then rawPrompt
              else if trigKind == "durable_job_terminal" && !jobId.isEmpty then
                s!"Durable job `{jobId}` has reached a terminal state. Inspect its result and continue."
              else "Scheduled wakeup triggered. Inspect current status and continue."

            -- One transcript entry per wake-up, not one per launch attempt.
            if tries == 0 then
              emitMissionEventAndBroadcast store broadcastHub? mid "user_message"
                (renderCompact (.obj #[
                  ("type", .str "user_message"),
                  ("content", .str effPrompt),
                  ("source", .str "wakeup"),
                  ("continuation_id", .str cid)
                ])) nowIso

            let mut launchedOk := false
            match ← resolveMissionRemoteNode? store mc? mid with
            | some targetNode =>
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
              match ← submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup coreWorkDir spec nowSec with
              | .ok _ =>
                launchedOk := true
                fired := fired + 1
              | .error dispErr =>
                emitMissionEventAndBroadcast store broadcastHub? mid "error"
                  (renderCompact (.obj #[("message", .str s!"Wakeup dispatch failed: {dispErr}")])) nowIso
            | none =>
              if let some launchLocal := localFallbackLaunch? then
                let ok ← launchLocal mr effPrompt resumeSid?
                if ok then
                  launchedOk := true
                  fired := fired + 1
                else
                  -- The failed launch may have marked the mission active with no process.
                  discard <| execParamQuery store.missionsDb
                    "UPDATE missions SET status='interrupted',terminal_reason='wakeup_launch_failed',state_revision=state_revision+1,updated_at=?2 WHERE id=?1 AND status='active';"
                    #[mid, nowIso]
                  emitMissionEventAndBroadcast store broadcastHub? mid "error"
                    (renderCompact (.obj #[("message", .str "Wakeup launch failed; it will be retried")])) nowIso
              else
                let _ := warmMgr?
                pure ()

            let isRecurringInterval := !stopFirst && recurrence.startsWith "interval:"
            if launchedOk || isRecurringInterval then
              discard <| execParamQuery store.missionsDb
                "UPDATE mission_continuations SET phase=4, updated_at=?2 WHERE id=?1 AND phase=2;"
                #[cid, nowIso]

            -- A one-shot wake-up that could not launch is not consumed: it fires late, not never.
            -- Re-armed under the mission's current generation with a backoff of 1, 2, 4 ... 15 min;
            -- after `maxWakeupLaunchTries` attempts (about two hours) it is retired with a visible error.
            if !launchedOk && !isRecurringInterval then
              if tries + 1 ≥ maxWakeupLaunchTries then
                discard <| execParamQuery store.missionsDb
                  "UPDATE mission_continuations SET phase=4, error='launch_failed', updated_at=?2 WHERE id=?1 AND phase=2;"
                  #[cid, nowIso]
                emitMissionEventAndBroadcast store broadcastHub? mid "error"
                  (renderCompact (.obj #[("message", .str s!"Scheduled wake-up abandoned after {tries + 1} failed launch attempts")])) nowIso
              else
                let backoff := Nat.min 900 (60 * 2 ^ (Nat.min tries 4))
                discard <| execParamQuery store.missionsDb
                  ("UPDATE mission_continuations SET phase=1, due_epoch=CAST(?2 AS INTEGER), error=?3, updated_at=?4, " ++
                   "run_generation=COALESCE((SELECT run_generation FROM missions WHERE id=mission_continuations.mission_id),run_generation) WHERE id=?1 AND phase=2;")
                  #[cid, s!"{nowSec + backoff.toUInt64}", s!"launch_retry:{tries + 1}", nowIso]

            -- Re-arm next interval using the exact post-launch `missions.run_generation`
            -- (if `launchedOk == false` due to a transient remote/node hiccup, still re-arm in 60s so a recurring wakeup is never permanently dropped!)
            if isRecurringInterval then
              let ivSecs :=
                if launchedOk then Nat.max 60 (((recurrence.drop 9).trimAscii.toString.toNat?).getD 300)
                else 60
              let mut updatedGen : Nat := mr.runGeneration.toNat
              if let .ok gRows ← execParamQuery store.missionsDb
                  "SELECT COALESCE(run_generation,1) FROM missions WHERE id=?1;" #[mid] then
                if gRows.size > 1 then
                  updatedGen := Nat.max 1 (cellNat gRows[1]! 0)
              let nextCid ← newUuidV4
              let nextReqId ← newUuidV4
              let nextDue := nowSec + ivSecs.toUInt64
              discard <| execParamQuery store.missionsDb
                ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
                 "VALUES(?1,?2,CAST(?3 AS INTEGER),1,CAST(?4 AS INTEGER),'time',?5,?6,?7,'','interval-rearm','',?8,0,?9,?9);")
                #[nextCid, mid, s!"{updatedGen}", s!"{nextDue}", reason, rawPrompt, nextReqId, recurrence, nowIso]
          | _ => pure ()
      else
        discard <| execParamQuery store.missionsDb
          "UPDATE mission_continuations SET phase=4, error='mission_not_found', updated_at=?2 WHERE id=?1 AND phase=1;"
          #[cid, nowIso]
  return fired

end OrbCore.RemoteDispatch
