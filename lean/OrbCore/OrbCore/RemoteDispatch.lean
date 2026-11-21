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
import OrbCore.Spec
import OrbCore.Managed
import OrbCore.MemoryAndCloud
import OrbCore.QueueCont
import OrbCore.RemoteGoal
import OrbCore.R7Core
import OrbCore.LegacyHydrate
import OrbCore.ProviderUsageAndLogin
import OrbCore.RemoteFleetAndRelay
import OrbCore.Skills
import OrbCore.AutoPlacement
import OrbCore.TelemetryAndVoice

namespace OrbCore.RemoteDispatch

open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.HttpClient
open OrbCore.Store
open OrbCore.Spec
open OrbCore.Managed
open OrbCore.MemoryAndCloud
open OrbCore.QueueCont
open OrbCore.R7Core
open OrbCore.LegacyHydrate
open OrbCore.ProviderUsageAndLogin
open OrbCore.RemoteFleetAndRelay
open OrbCore.TelemetryAndVoice

/-! ## Remote Job Supervisor Handle -/

structure RemoteJobSupervisor where
  mu             : Std.Mutex (Array String)
  boundPortRef   : IO.Ref UInt16
  jwtSecret      : String
  devMode        : Bool
  telemetrySink? : Option TelemetrySink := none

def newRemoteJobSupervisor (jwtSecret : String := "") (devMode : Bool := false) (telemetrySink? : Option TelemetrySink := none) : IO RemoteJobSupervisor := do
  let mu ← Std.Mutex.new (#[] : Array String)
  let portRef ← IO.mkRef (0 : UInt16)
  return { mu := mu, boundPortRef := portRef, jwtSecret := jwtSecret, devMode := devMode, telemetrySink? := telemetrySink? }

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

/-- Stage the install script on an unlinked temporary file, using bounded environment entries.
    Neither the script nor its base64 contents become an exec argument (including the `sh` exec).
    Close fd 4 before launching the harness; prompt staging owns fd 3 independently. -/
def stageSkillBundle (script : String) : String × Array (String × String) := Id.run do
  if script.isEmpty then return ("", #[])
  else
    let chunks := splitUtf8Chunks script (96 * 1024)
    let mut envs : Array (String × String) := Array.mkEmpty chunks.size
    let mut refs : Array String := Array.mkEmpty chunks.size
    let mut unsetVars := "sandboxed_skill_bundle"
    for i in [0:chunks.size] do
      let k := s!"SANDBOXED_SKILL_PART_{i}"
      envs := envs.push (k, chunks[i]!)
      refs := refs.push s!"\"${k}\""
      unsetVars := unsetVars ++ " " ++ k
    let printfArgs := String.intercalate " " refs.toList
    let prelude :=
      "sandboxed_skill_bundle=\"$(mktemp)\" || exit 1; " ++
      s!"printf %s {printfArgs} > \"$sandboxed_skill_bundle\" || exit 1; " ++
      "exec 4< \"$sandboxed_skill_bundle\"; " ++
      "rm -f -- \"$sandboxed_skill_bundle\"; " ++
      s!"unset {unsetVars}; sh <&4 || exit 1; exec 4<&-; "
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

/-- Call a static node or dial-out managed VM with an exact byte body (uploads, chunks, downloads). -/
def callRemoteNodeRawOpt
    (hub? : Option RelayHub)
    (mc? : Option ManagedComputeStore)
    (targetNodeId method pathQuery : String)
    (bodyBytes : ByteArray)
    (contentType : String := "application/octet-stream")
    (extraHeaders : Array (String × String) := #[])
    (timeoutMs : Nat := 30000) : IO (Except String (Nat × String × Option JVal × String × String)) := do
  let (_, staticNodes) ← loadStaticRemoteNodes
  let cleanPath := if pathQuery.startsWith "/" then pathQuery else "/" ++ pathQuery
  if let some sn := staticNodes.find? (fun n => n.id == targetNodeId) then
    let some tok ← resolveStaticNodeToken? sn
      | return .error s!"remote node `{sn.id}` has no token in `{sn.tokenEnv}`"
    let mut hdrs := extraHeaders.push ("Authorization", s!"Bearer {tok}")
    if !bodyBytes.isEmpty then hdrs := hdrs.push ("Content-Type", contentType)
    match ← sendRequest method (sn.baseUrl ++ cleanPath) hdrs bodyBytes timeoutMs.toUInt32 67108864 with
    | .error e => return .error e
    | .ok resp =>
      let text := (String.fromUTF8? resp.body).getD ""
      let parsedJson := match OrbBin.Json.parseBytes resp.body with
        | .ok j => some j
        | .error _ => none
      return .ok (resp.status, text, parsedJson, sn.id, tok)
  else
    let some mc := mc?
      | return .error s!"unknown remote node `{targetNodeId}`"
    let some mid ← resolveManagedMachineId? mc targetNodeId
      | return .error s!"unknown remote node `{targetNodeId}`"
    let some hub := hub?
      | return .error "relay_hub_unavailable"
    let some (_, nodeTok) ← getManagedNodeAuth? mc mid
      | return .error s!"managed node `{mid}` has no enrolled token"
    let mut hdrs := extraHeaders.push ("Authorization", s!"Bearer {nodeTok}")
    if !bodyBytes.isEmpty then hdrs := hdrs.push ("Content-Type", contentType)
    match ← tunnelHttpToManagedMachine hub mc mid method cleanPath hdrs bodyBytes timeoutMs with
    | .error e => return .error e
    | .ok resp =>
      let text := (String.fromUTF8? resp.body).getD ""
      let parsedJson := match OrbBin.Json.parseBytes resp.body with
        | .ok j => some j
        | .error _ => none
      return .ok (resp.status, text, parsedJson, targetNodeId, nodeTok)

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

/-- Trust classification for secret delivery, shared by direct retrieval and
    approval polling. A managed binding is sufficient even before enrollment;
    unresolved automatic placement is not evidence of a trusted host. -/
def missionHasManagedPlacement (store : CoreStore) (mc? : Option ManagedComputeStore)
    (missionId : String) : IO Bool := do
  if missionId.isEmpty then return false
  match ← execParamQuery store.missionsDb
      "SELECT COALESCE(placement_kind,'') FROM missions WHERE id=?1;" #[missionId] with
  | .error _ => return true
  | .ok rows =>
    let kind := (rows[1]?.bind (·[0]?)).getD ""
    if rows.size < 2 || kind == "managed_vm" || kind.startsWith "managed-" then return true
  if let some mc := mc? then
    -- Preserve the wait path's existing restriction for an owned VM or active claim.
    match ← execParamQuery mc.db
        ("SELECT 1 FROM managed_machines WHERE owner_mission=?1 AND phase_code<>3 " ++
         "UNION ALL SELECT 1 FROM managed_vm_claims WHERE owner_mission=?1 AND phase_code=1 LIMIT 1;")
        #[missionId] with
    | .error _ => return true
    | .ok rows => if rows.size > 1 then return true
  -- A bound job is stronger evidence than a placement request such as `auto`.
  -- In particular, the static fleet may have changed since dispatch.
  if let .ok rows ← execParamQuery store.missionsDb
      ("SELECT node_id FROM remote_node_jobs WHERE mission_id=?1 AND node_id<>'' " ++
       "AND state NOT IN ('succeeded','failed','cancelled','lost','terminal','completed','aborted') " ++
       "ORDER BY updated_at DESC, rowid DESC LIMIT 1;") #[missionId] then
    if ((rows[1]?.bind (·[0]?)).getD "").startsWith "managed-" then return true
  let some target ← resolveMissionRemoteNode? store mc? missionId | return false
  if target.startsWith "managed-" || target == "auto-managed" || target.startsWith "auto-managed:" then
    return true
  let concrete ← resolveConcreteRemoteTargetNode mc? target (some (store, missionId))
  return match concrete with
  | .ok node => node.startsWith "managed-"
  | .error _ => true

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

/-- What a harness needs to reach Core's model router: its environment, extra CLI arguments,
    and the model name to launch it with. Turns that Core runs itself use this; without it a
    harness on the Core host falls back to its own logins and model list. -/
structure HarnessProxySetup where
  env   : Array (String × String) := #[]
  args  : Array String := #[]
  model : Option String := none

def harnessProxySetup (harness rawModel proxyBase proxyToken : String) : HarnessProxySetup :=
  let raw := rawModel.trimAscii.toString
  if harness == "opencode" then
    let stripped :=
      if raw.startsWith "builtin/" then (raw.drop 8).toString
      else if raw.startsWith "sandboxed-sh/" then (raw.drop 13).toString
      else raw
    let key := if stripped.isEmpty then "smart" else stripped
    { env := #[("SANDBOXED_PROXY_API_KEY", proxyToken),
               ("OPENCODE_CONFIG_CONTENT", remoteOpenCodeConfigJson key proxyBase)]
      model := some s!"builtin/{key}" }
  else if harness == "claudecode" then
    let bare := if raw.startsWith "anthropic/" then (raw.drop 10).toString else raw
    { env := #[("ANTHROPIC_BASE_URL", proxyBase), ("ANTHROPIC_AUTH_TOKEN", proxyToken)]
      model := if bare.isEmpty then none else some bare }
  else if harness == "codex" then
    let bare := if raw.startsWith "openai/" then (raw.drop 7).toString else raw
    { env := #[("SANDBOXED_PROXY_API_KEY", proxyToken)]
      args := #["-c", "model_provider=\"sandboxed\"",
                "-c", "model_providers.sandboxed.name=\"Sandboxed\"",
                "-c", s!"model_providers.sandboxed.base_url=\"{proxyBase}/v1\"",
                "-c", "model_providers.sandboxed.wire_api=\"responses\"",
                "-c", "model_providers.sandboxed.env_key=\"SANDBOXED_PROXY_API_KEY\""]
      model := if bare.isEmpty then none else some bare }
  else
    { model := if raw.isEmpty then none else some raw }

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
  -- Empty claim ID is the initial Goal launch; otherwise it is a durable continuation UUID.
  goalDispatch?      : Option (String × UInt64) := none
  wakeupClaim?       : Option WakeupClaim := none
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
  let skillBundle := (← OrbCore.Skills.remoteInstallPrelude coreWorkDir
    (if spec.project.trimAscii.toString.isEmpty then none else some spec.project) spec.backend.trimAscii.toString.toLower store.rootDir spec.ownerUserId bootstrapAdminId)
  let (skillPrelude, skillEnvs) := stageSkillBundle skillBundle
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
      wsPrefix ++ skillPrelude ++ fd3Prelude ++
      "command -v opencode >/dev/null 2>&1 || { echo 'opencode is not installed on this node' >&2; exit 127; }; " ++
      "if sandboxed-node opencode-acp --probe </dev/null >/dev/null 2>&1; then " ++
      wrapWithRemoteMcp "opencode" acpInner ++ "; else " ++ wrapWithRemoteMcp "opencode" inner ++ "; fi <&3"
    let envs :=
      skillEnvs ++ promptEnvs ++ mcpEnvs ++ #[
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
      wsPrefix ++ skillPrelude ++ fd3Prelude ++
      "command -v claude >/dev/null 2>&1 || { echo 'claude is not installed on this node' >&2; exit 127; }; " ++
      wrapWithRemoteMcp "claudecode" inner ++ " <&3"
    let envs :=
      skillEnvs ++ promptEnvs ++ mcpEnvs ++ #[
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
      wsPrefix ++ skillPrelude ++ fd3Prelude ++
      "command -v codex >/dev/null 2>&1 || { echo 'codex is not installed on this node' >&2; exit 127; }; " ++
      wrapWithRemoteMcp "codex" inner ++ " <&3"
    let envs :=
      skillEnvs ++ promptEnvs ++ mcpEnvs ++ #[
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
      wsPrefix ++ skillPrelude ++ fd3Prelude ++
      "command -v grok >/dev/null 2>&1 || { echo 'grok is not installed on this node' >&2; exit 127; }; " ++
      wrapWithRemoteMcp "grok" inner
    let envs := skillEnvs ++ promptEnvs ++ mcpEnvs ++ #[("NO_COLOR", "1")]
    return .ok { command := cmd, envPairs := envs, managedAuth := #["grok"], proxyToken := "" }

  else if harness == "antigravity" then
    let options := OrbBin.ClaudeControl.antigravityCliOptions spec.modelOverride (some spec.modelEffort) resumeSid?
    let argv := String.intercalate " " (options.toList.map shellSingleQuote)
    -- A sentinel preserves trailing newlines across shell command substitution.
    let goalSettings := include_str "antigravity_goal_settings.json"
    let goalFlags := if spec.goalDispatch?.isSome then " --settings " ++ shellSingleQuote goalSettings else ""
    let inner := "agy " ++ argv ++ goalFlags ++ " --print=\"${agy_prompt%.}\""
    -- Permission to call the Orb tools applies only with the mission-scoped server installed.
    let launch := if spec.goalDispatch?.isSome then
        "/usr/local/bin/sandboxed-mcp launch --harness antigravity -- " ++ inner
      else wrapWithRemoteMcp "antigravity" inner
    let cmd :=
      wsPrefix ++ skillPrelude ++ fd3Prelude ++
      "command -v agy >/dev/null 2>&1 || { echo 'agy is not installed on this node' >&2; exit 127; }; " ++
      "agy_prompt=\"$(cat <&3 && printf .)\" || exit 1; " ++
      launch
    let envs := skillEnvs ++ promptEnvs ++ mcpEnvs ++ #[("NO_COLOR", "1")]
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
  model?           : Option String := none
  inputTokens?     : Option UInt64 := none
  outputTokens?    : Option UInt64 := none
  cacheReadTokens? : Option UInt64 := none

private def emitMissionEventAndBroadcast
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (missionId evType payloadJson nowIso : String) : IO Unit := do
  discard <| appendMissionEvent store missionId evType payloadJson nowIso
  publishControlEvent broadcastHub? evType payloadJson (some missionId)

private def resumableGoalSession (backend sid : String) : Bool :=
  match backend with
  | "codex" | "antigravity" => parseUuidCanonical? sid == some sid
  | "opencode" => sid.startsWith "ses_"
  | _ => false

def remoteGoalPrompt (objective : String) : String :=
  s!"[Goal mode]\nObjective: {objective}\n\nTake the next concrete step and report progress. If the objective is fully achieved, end your reply with {RemoteGoal.completionMarker} on its own final line."

def maxRemoteGoalContinuations : Nat := 20

-- Leave live fenced POSTs to their submitter and reconcile their durable job IDs.
private def fencedSubmissionSql (column : String) : String :=
  s!"((instr({column},'\"goal_generation\":null')=0 AND instr({column},'\"goal_generation\":')>0) OR " ++
  s!"(instr({column},'\"wakeup_generation\":null')=0 AND instr({column},'\"wakeup_generation\":')>0))"

/-- Launch attempts a one-shot wake-up gets before it is retired as `launch_failed`. -/
def maxWakeupLaunchTries : Nat := 10

private def wakeupRetryCount (err : String) : Nat :=
  if err.startsWith "launch_retry:" then ((err.drop "launch_retry:".length).toString.toNat?).getD 0 else 0

-- The caller owns the write transaction. For a remote attempt, settlement and
-- job acceptance/rejection must commit together. A newer schedule wins over retry.
private def settleWakeupClaimUnlocked (store : CoreStore) (claim : WakeupClaim)
    (jobId : String) (accepted : Bool) (nextGen nowSec : UInt64) : IO (Except String Unit) := do
  let query := execParamQueryUnlocked store.missionsDb
  let iso := formatEpochIso8601Utc nowSec
  let fence := "id=?1 AND request_id=?2 AND phase=2 AND dispatch_job_id=?3"
  let args := #[claim.id, claim.requestId, jobId]
  let .ok rows ← query ("SELECT c.mission_id,c.run_generation,c.recurrence,c.stop_after_first,c.error, " ++
    "m.run_generation,m.status, EXISTS(SELECT 1 FROM mission_continuations n WHERE n.mission_id=c.mission_id " ++
    "AND n.phase=1 AND n.trigger_kind=c.trigger_kind AND (c.trigger_kind='time' OR n.job_id=c.job_id)) " ++
    "FROM mission_continuations c JOIN missions m ON m.id=c.mission_id WHERE " ++
    "c.id=?1 AND c.request_id=?2 AND c.phase=2 AND c.dispatch_job_id=?3;") args
    | return .error "wakeup_claim_read_failed"
  let some r := rows[1]? | return .ok ()
  let mid := cell r 0
  let recurrence := cell r 2
  let recurring := cellNat r 3 == 0 && recurrence.startsWith "interval:"
  let tries := wakeupRetryCount (cell r 4)
  let generation := cellNat r 1
  let ownerGen := cellNat r 5
  let status := cell r 6
  let replaced := cellNat r 7 != 0
  let canRetry := generation == ownerGen && !replaced && ownerTerminalOfStatus status == 0 && ownerBusyOfStatus status == 0
  if !accepted && canRetry && (recurring || tries + 1 < maxWakeupLaunchTries) then
    let delay := if recurring then 60 else Nat.min 900 (60 * 2 ^ (Nat.min tries 4))
    return (← query ("UPDATE mission_continuations SET phase=1, dispatch_job_id='', due_epoch=CAST(?4 AS INTEGER), error=?5, updated_at=?6 WHERE " ++ fence ++ ";")
      (args ++ #[s!"{nowSec + delay.toUInt64}", s!"launch_retry:{tries + 1}", iso])).map (fun _ => ())
  let outcome := if accepted then "" else if canRetry then "launch_failed" else "wakeup_claim_fenced"
  if let .error e ← query ("UPDATE mission_continuations SET phase=4, error=?4, updated_at=?5 WHERE " ++ fence ++ ";")
    (args ++ #[outcome, iso]) then return .error e
  let acceptedGen := if jobId.isEmpty then generation else nextGen.toNat
  if accepted && recurring && !replaced && ownerTerminalOfStatus status == 0 && ownerGen == acceptedGen then
    let nextId ← newUuidV4
    let interval := Nat.max 60 (((recurrence.drop 9).toString.toNat?).getD 300)
    return (← query
      ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,recurrence,stop_after_first,created_at,updated_at) " ++
       "SELECT ?2,mission_id,CAST(?3 AS INTEGER),1,CAST(?4 AS INTEGER),trigger_kind,reason,prompt,?2,job_id,'interval-rearm',recurrence,0,?5,?5 " ++
       "FROM mission_continuations WHERE id=?1 AND mission_id=?6;")
      #[claim.id, nextId, s!"{acceptedGen}", s!"{nowSec + interval.toUInt64}", iso, mid]).map (fun _ => ())
  return .ok ()

private def remoteWakeupOwned (store : CoreStore) (mid jid : String) (claim : WakeupClaim) : IO (Except String Bool) := do
  let rows ← execParamQueryUnlocked store.missionsDb
    ("SELECT 1 FROM mission_continuations c JOIN missions m ON m.id=c.mission_id " ++
     "WHERE m.id=?1 AND c.id=?2 AND c.request_id=?3 AND c.phase=2 AND c.dispatch_job_id=?4 " ++
     "AND c.run_generation=CAST(?5 AS INTEGER) AND m.run_generation=c.run_generation " ++
     "AND m.status NOT IN ('active','pending','waiting_background','cancelled','failed','completed','not_feasible');")
    #[mid, claim.id, claim.requestId, jid, s!"{claim.generation}"]
  return rows.map (·.size > 1)

-- Parameters: mission ID, generation, whether this is the initial launch ("1"/"0").
private def remoteGoalDispatchOwnerSql : String :=
  "m.id=?1 AND m.run_generation=CAST(?2 AS INTEGER) AND m.goal_mode=1 AND m.status='awaiting_user' " ++
  "AND ((?3='1' AND COALESCE(m.terminal_reason,'')='') OR " ++
  "(?3='0' AND m.terminal_reason IN ('remote_goal_continuation','remote_goal_dispatch_blocked')))"

private def remoteGoalDispatchOwned (store : CoreStore) (missionId jobId : String)
    (gen : UInt64) (initial : Bool) : IO (Except String Bool) := do
  let rows ← execParamQueryUnlocked store.missionsDb
    ("SELECT 1 FROM missions m JOIN remote_node_jobs j ON j.mission_id=m.id WHERE " ++
      remoteGoalDispatchOwnerSql ++ " AND j.job_id=?4 AND j.state IN ('submitting','uncertain');")
    #[missionId, s!"{gen}", if initial then "1" else "0", jobId]
  return rows.map (·.size > 1)

/-- Settle the owning job and arm at most one intent under the same write lock as Stop. -/
def settleRemoteGoal (store : CoreStore) (missionId jobId objective finalText : String)
    (generation nowSec : UInt64) (hasSession drained : Bool) : IO (Except String (Option (String × String × Nat))) := do
  let cid ← newUuidV4
  let iso := formatEpochIso8601Utc nowSec
  withImmediateTx store.missionsDb do
    let query := execParamQueryUnlocked store.missionsDb
    let .ok rows ← query
      ("SELECT (SELECT COUNT(*) FROM mission_continuations WHERE mission_id=m.id AND source='remote-goal'), " ++
       "EXISTS(SELECT 1 FROM mission_continuations WHERE mission_id=m.id AND phase=1) FROM missions m " ++
       "WHERE id=?1 AND run_generation=CAST(?2 AS INTEGER) AND placement_job_id=?3 AND goal_mode=1 " ++
       "AND status='active' AND terminal_reason='remote_node_job';") #[missionId, s!"{generation}", jobId]
      | return .error "remote_goal_owner_read_failed"
    let some row := rows[1]? | return .ok none
    let iteration := cellNat row 0
    let fence : RemoteGoal.TurnFence := ⟨missionId, 1, generation.toNat, jobId⟩
    let decision := RemoteGoal.decide { owner := fence, continuations := iteration }
      { owner := fence, outcome := .succeeded, drained := drained, finalText := finalText,
        kind := .finalAssistant, completionConfirmed := RemoteGoal.hasCompletionMarker finalText, madeProgress := true }
      { maxContinuations := some maxRemoteGoalContinuations, wakeupPending := cellNat row 1 != 0 }
    let (status, reason) := if !drained then ("awaiting_user", "remote_goal_evidence_incomplete") else match decision.effect with
      | .completed => ("completed", "remote_goal_complete")
      | .requestContinuation => if hasSession then ("awaiting_user", "remote_goal_continuation")
        else ("awaiting_user", "remote_goal_session_missing")
      | .park .budgetLimited => ("awaiting_user", "remote_goal_budget_limited")
      | .park .awaitingWakeup => ("awaiting_user", "awaiting_wakeup")
      | _ => ("awaiting_user", "remote_goal_blocked")
    if reason == "remote_goal_continuation" then
      if let .error e ← query
        ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
         "VALUES(?1,?2,CAST(?3 AS INTEGER),1,CAST(?4 AS INTEGER),'time','remote_goal',?5,?6,'','remote-goal','','',1,?7,?7);")
        #[cid, missionId, s!"{generation}", s!"{nowSec + 2}", remoteGoalPrompt objective, s!"remote-goal:{jobId}", iso] then
        return .error e
    if let .error e ← query
        "UPDATE missions SET status=?2,terminal_reason=?3,state_revision=state_revision+1,updated_at=?4 WHERE id=?1;"
        #[missionId, status, reason, iso] then return .error e
    return .ok (some (status, reason, decision.state.continuations))

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

/-- Retries a turn gets after a transient stream-cut (`stream_incomplete` / `idle_timeout`) before the mission is `failed`. -/
def maxTransientTurnRetries : Nat := 2

/-- Classify an error message or proxy outcome status into a transient turn failure reason (`1 = stream_incomplete`, `2 = idle_timeout`). -/
def classifyTransientTurnFailureText? (raw : String) : Option TransientTurnFailureReason :=
  let low := raw.trimAscii.toString.toLower
  if low.isEmpty then none
  else if (low.splitOn "stream_incomplete").length > 1 ||
          (low.splitOn "upstream stream ended without a finish_reason").length > 1 ||
          (low.splitOn "[done]data:").length > 1 then
    some .streamIncomplete
  else if (low.splitOn "idle_timeout").length > 1 ||
          (low.splitOn "upstream_idle_timeout").length > 1 then
    some .idleTimeout
  else none

/-- Encode `TransientTurnFailureReason` as its kernel gate reason code (`1` or `2`). -/
def transientTurnFailureReasonCode : TransientTurnFailureReason → UInt8
  | .streamIncomplete => 1
  | .idleTimeout      => 2

/-- Settle a failed turn when the failure is caused by a transient stream cut (`stream_incomplete` or `idle_timeout`).
    Consults `verifyTransientTurnRecovery` (`OrbCore.Spec`):
    - At most `maxTransientTurnRetries` (`2`) times per user instruction, emits a visible `recovered` event,
      arms a durable one-shot `mission_continuations` row with `20 * (prior + 1)` seconds backoff, and returns
      `some ("awaiting_user", "transient_turn_retry")`.
    - On the 3rd consecutive cut (`prior >= 2`) or when `retryable = false`, emits a terminal `error` event and
      returns `some ("failed", reasonString)`.
    - Returns `none` when the turn failure is not a transient stream cut / idle timeout. -/
def settleTransientTurnFailure
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (missionId nowIso : String)
    (nowSec : UInt64)
    (errText? : Option String := none)
    (retryable : Bool := true) : IO (Option (String × String)) := do
  let mut reason? := errText?.bind classifyTransientTurnFailureText?
  if reason?.isNone then
    if let .ok eRows ← execParamQuery store.missionsDb
        ("SELECT COALESCE(payload,'') FROM mission_events WHERE mission_id=?1 AND event_type='error' " ++
         "AND id > COALESCE((SELECT MAX(id) FROM mission_events WHERE mission_id=?1 AND event_type='user_message'),0) " ++
         "ORDER BY id DESC LIMIT 1;") #[missionId] then
      if eRows.size > 1 then
        reason? := classifyTransientTurnFailureText? (cell eRows[1]! 0)
  let some reason := reason?
    | return none
  let reasonStr := reason.reasonString
  let reasonCode := transientTurnFailureReasonCode reason
  let prior := match ← execParamQuery store.missionsDb
      ("SELECT c.reason FROM mission_continuations c WHERE c.mission_id=?1 AND c.reason LIKE 'transient_turn_retry:%' AND instr(COALESCE(" ++
       "(SELECT payload FROM mission_events WHERE mission_id=?1 AND event_type='user_message' ORDER BY id DESC LIMIT 1),''), c.id) > 0 LIMIT 1;") #[missionId] with
    | .ok rs =>
      ((rs[1]?.bind (·[0]?)).bind fun r =>
        let rest := (r.drop 21).toString
        ((rest.splitOn ":").headD "").toNat?).getD 0
    | .error _ => maxTransientTurnRetries
  let priorU8 : UInt8 := (Nat.min prior 255).toUInt8
  let retryFlag : UInt8 := if retryable then 1 else 0
  if verifyTransientTurnRecovery reasonCode priorU8 retryFlag == 1 then
    let cid ← newUuidV4
    let backoffSec := 20 * (prior.toUInt64 + 1)
    let armed ← execParamQuery store.missionsDb
      ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
       "SELECT ?1,id,COALESCE(run_generation,1),1,CAST(?3 AS INTEGER),'time',?4,?5,?1,'','transient-turn-retry','','',1,?6,?6 FROM missions WHERE id=?2;")
      #[cid, missionId, s!"{nowSec + backoffSec}", s!"transient_turn_retry:{prior + 1}:{reasonStr}",
        s!"Your previous turn was interrupted by a transient upstream stream cut ({reasonStr}). Continue the task from where you left off.", nowIso]
    if armed.isOk then
      emitMissionEventAndBroadcast store broadcastHub? missionId "recovered"
        (renderCompact (.obj #[
          ("message", .str s!"Transient upstream stream cut ({reasonStr}); recovering turn ({prior + 1} of {maxTransientTurnRetries})."),
          ("reason", .str reasonStr),
          ("code", .str reasonStr),
          ("attempt", .num s!"{prior + 1}"),
          ("max_retries", .num s!"{maxTransientTurnRetries}"),
          ("backoff_seconds", .num s!"{backoffSec}"),
          ("continuation_id", .str cid),
          ("retryable", .bool true)
        ])) nowIso
      return some ("awaiting_user", "transient_turn_retry")
  emitMissionEventAndBroadcast store broadcastHub? missionId "error"
    (renderCompact (.obj #[
      ("message", .str s!"Turn failed after {prior + 1} transient upstream stream cut attempt(s) ({reasonStr})."),
      ("reason", .str reasonStr),
      ("code", .str reasonStr),
      ("retryable", .bool false)
    ])) nowIso
  return some ("failed", reasonStr)

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
    let usageObj := jv.fieldOrNull "usage"
    let inTok? := (usageObj.fieldUInt64? "input_tokens").orElse (fun _ => jv.fieldUInt64? "input_tokens")
    let outTok? := (usageObj.fieldUInt64? "output_tokens").orElse (fun _ => jv.fieldUInt64? "output_tokens")
    let crTok? := (usageObj.fieldUInt64? "cache_read_input_tokens").orElse (fun _ => usageObj.fieldUInt64? "cache_read_tokens")
    let mdl? := ((jv.fieldStr? "model").orElse (fun _ => (jv.fieldOrNull "message").fieldStr? "model")).filter (!·.trimAscii.toString.isEmpty)
    if inTok?.isSome || outTok?.isSome || crTok?.isSome || mdl?.isSome then
      next := {
        next with
        model? := mdl?.orElse (fun _ => next.model?)
        inputTokens? := inTok?.orElse (fun _ => next.inputTokens?)
        outputTokens? := outTok?.orElse (fun _ => next.outputTokens?)
        cacheReadTokens? := crTok?.orElse (fun _ => next.cacheReadTokens?)
      }
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
    if parsed.model?.isSome || parsed.inputTokens?.isSome || parsed.outputTokens?.isSome || parsed.cacheReadTokens?.isSome then
      next := {
        next with
        model? := parsed.model?.orElse (fun _ => next.model?)
        inputTokens? := match next.inputTokens?, parsed.inputTokens? with
          | some a, some b => some (a + b)
          | none, some b => some b
          | some a, none => some a
          | none, none => none
        outputTokens? := match next.outputTokens?, parsed.outputTokens? with
          | some a, some b => some (a + b)
          | none, some b => some b
          | some a, none => some a
          | none, none => none
        cacheReadTokens? := match next.cacheReadTokens?, parsed.cacheReadTokens? with
          | some a, some b => some (a + b)
          | none, some b => some b
          | some a, none => some a
          | none, none => none
      }
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
      if piece.isEmpty then return next
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
  if jobId.isEmpty then
    if let .ok jRows ← execParamQuery store.missionsDb
         ("SELECT COALESCE(job_id,''), COALESCE(node_id,'') FROM remote_node_jobs WHERE mission_id=?1 " ++
         "AND state NOT IN ('terminal','completed','succeeded','failed','aborted','cancelled','lost') " ++
          "AND NOT (state IN ('submitting','uncertain') AND " ++ fencedSubmissionSql "payload_json" ++ ") " ++
         "ORDER BY updated_at DESC LIMIT 1;")
        #[missionId] then
      if jRows.size > 1 then
        jobId := (cell jRows[1]! 0).trimAscii.toString
        if nodeId.isEmpty then
          nodeId := (cell jRows[1]! 1).trimAscii.toString
  if nodeId.isEmpty then
    if let some rn ← resolveMissionRemoteNode? store mc? missionId then
      nodeId := rn
  let nowIso := formatEpochIso8601Utc (← nowEpoch)
  let reconcileCancelLedgers (jid : String) : IO Unit := do
    if !jid.isEmpty then
      discard <| execParamQuery store.missionsDb
        "UPDATE remote_node_jobs SET state='cancelled', updated_at=?2 WHERE job_id=?1;"
        #[jid, nowIso]
      discard <| execParamQuery store.projectsDb
        "UPDATE remote_jobs SET state='cancelled', heartbeat_at=?2, finished_at=COALESCE(finished_at,?2), updated_at=?2 WHERE job_id=?1;"
        #[jid, nowIso]
    discard <| execParamQuery store.missionsDb
      ("UPDATE remote_node_jobs SET state='cancelled', updated_at=?2 WHERE mission_id=?1 " ++
        "AND state NOT IN ('terminal','completed','succeeded','failed','aborted','cancelled','lost') " ++
         "AND NOT (state IN ('submitting','uncertain') AND " ++ fencedSubmissionSql "payload_json" ++ ");")
      #[missionId, nowIso]
    discard <| execParamQuery store.projectsDb
      ("UPDATE remote_jobs SET state='cancelled', heartbeat_at=?2, finished_at=COALESCE(finished_at,?2), updated_at=?2 WHERE mission_id=?1 " ++
       "AND state NOT IN ('terminal','completed','succeeded','failed','aborted','cancelled','lost');")
      #[missionId, nowIso]
  if jobId.isEmpty || nodeId.isEmpty then
    reconcileCancelLedgers jobId
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
    reconcileCancelLedgers jobId
    return (200 ≤ st && st < 300)
  | .error _ =>
    reconcileCancelLedgers jobId
    return false

private def popNextQueuedFollowup?
    (store : CoreStore)
    (missionId : String)
    (runGen : UInt64)
    (nowIso : String) : IO (Option (String × String)) := do
  let qRows ← execParamQuery store.missionsDb
    ("SELECT user_id, message_id, COALESCE(payload,'') FROM remote_message_queue " ++
     "WHERE mission_id=?1 AND state='waiting' AND COALESCE(phase,0)=0 ORDER BY sequence ASC, rowid ASC LIMIT 1;")
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
      return some (msgId, item.content)
    match OrbBin.Json.parse rawPl with
    | .ok jv =>
      let c := ((jv.field? "message").bind (·.fieldStr? "content")).orElse (fun _ => jv.fieldStr? "content") |>.getD ""
      return (if c.trimAscii.toString.isEmpty then none else some (msgId, c))
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
    -- The observer owns exactly the generation it was started for. A newer turn
    -- may replace this job while an old poller is still in flight; terminal
    -- observations from the old poller must never settle the new generation.
    let mut capturedGen : UInt64 := 1
    if let .ok gRows ← execParamQuery store.missionsDb
        "SELECT COALESCE(run_generation,1) FROM missions WHERE id=?1 LIMIT 1;" #[missionId] then
      if gRows.size > 1 then capturedGen := (cellNat gRows[1]! 0).toUInt64
    let mut offset : Nat := initialOffset
    let isGoal := (← getMission? store missionId).any (·.goalMode)
    let mut evidenceIntact := initialOffset == 0
    let mut lineRem : String := ""
    let mut acc : RemoteStreamAcc := {}
    let mut unreachableNotified : Bool := false
    if initialOffset > 0 then
      if let .ok tdRows ← execParamQuery store.missionsDb
          ("SELECT COALESCE(payload,''), COALESCE(content,'') FROM mission_events " ++
           "WHERE mission_id=?1 AND event_type='text_delta' " ++
           "AND id > COALESCE((SELECT MAX(id) FROM mission_events WHERE mission_id=?1 AND event_type='user_message'),0) " ++
           "ORDER BY id DESC LIMIT 1;") #[missionId] then
        if tdRows.size > 1 then
          let rawPl := cell tdRows[1]! 0
          let rawCnt := cell tdRows[1]! 1
          let prevTxt :=
            match OrbBin.Json.parse rawPl with
            | .ok jv => (jv.fieldStr? "content").getD rawCnt
            | .error _ => rawCnt
          if !prevTxt.isEmpty then
            acc := { acc with text := prevTxt, sawActivity := true }
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
      -- The poller must not retry an unreachable node after its store shuts down.
      if (← store.closedRef.get) then break
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
              discard <| execParamQuery store.missionsDb
                "UPDATE remote_node_jobs SET state='cancelled', updated_at=?2 WHERE job_id=?1;"
                #[jobId, nowIso]
              discard <| execParamQuery store.projectsDb
                "UPDATE remote_jobs SET state='cancelled', heartbeat_at=?2, finished_at=COALESCE(finished_at,?2), updated_at=?2 WHERE job_id=?1;"
                #[jobId, nowIso]
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
                if isGoal && ((ljv.fieldNat? "offset") != some offset || (ljv.fieldNat? "next_offset").isNone ||
                    (ljv.fieldNat? "log_len").isNone || (ljv.fieldStr? "data").isNone || nextOff < offset ||
                    nextOff > logLen || ((nextOff == offset) != chunk.isEmpty)) then
                  evidenceIntact := false
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
          -- Losing observation is not terminal evidence: the node may still be
          -- executing. Record unreachability durably, keep the turn owned and
          -- keep observing so a later success can settle the same run.
          if consecNetErrors ≥ 60 then
            discard <| execParamQuery store.missionsDb
              "UPDATE remote_node_jobs SET state='unreachable', updated_at=?2 WHERE job_id=?1 AND state NOT IN ('succeeded','failed','cancelled','lost','terminal');"
              #[jobId, nowIso]
            discard <| execParamQuery store.projectsDb
              "UPDATE remote_jobs SET state='unreachable', heartbeat_at=?2, updated_at=?2 WHERE job_id=?1 AND state NOT IN ('succeeded','failed','cancelled','lost','terminal');"
              #[jobId, nowIso]
            if !unreachableNotified then
              unreachableNotified := true
              emitMissionEventAndBroadcast store broadcastHub? missionId "error"
                (renderCompact (.obj #[("message", .str s!"Lost contact with remote node `{effNodeId}`; the turn remains owned and will reconcile when the node is reachable: {netErr}")])) nowIso
            IO.sleep 2000
        | .ok (jStatus, jTxt, jJv?, _, _) =>
          if jStatus == 404 then
            keepRunning := false
            if !proxyTok.isEmpty then revokeSingleMissionProxyToken store proxyTok
            let reason := "remote_job_missing_on_node"
            discard <| execParamQuery store.missionsDb
              "UPDATE mission_runs SET execution_state='terminal', terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND remote_job_id=?4 AND generation=CAST(?5 AS INTEGER) AND execution_state NOT IN ('terminal','completed','failed','aborted');"
              #[missionId, reason, nowIso, jobId, s!"{capturedGen}"]
            discard <| execParamQuery store.missionsDb
              "UPDATE remote_node_jobs SET state='lost', updated_at=?2 WHERE job_id=?1;" #[jobId, nowIso]
            discard <| execParamQuery store.projectsDb
              "UPDATE remote_jobs SET state='lost', heartbeat_at=?2, finished_at=COALESCE(finished_at,?2), updated_at=?2 WHERE job_id=?1;" #[jobId, nowIso]
            discard <| execParamQuery store.missionsDb
              "UPDATE missions SET status='interrupted', terminal_reason=?2, state_revision=state_revision+1, updated_at=?3 WHERE id=?1 AND run_generation=CAST(?4 AS INTEGER) AND status IN ('active','pending');"
              #[missionId, reason, nowIso, s!"{capturedGen}"]
            emitMissionEventAndBroadcast store broadcastHub? missionId "mission_status_changed"
              (renderCompact (.obj #[("status", .str "interrupted"), ("reason", .str reason)])) nowIso
          else if 200 ≤ jStatus && jStatus < 300 then
            consecNetErrors := 0
            unreachableNotified := false
            let jv := jJv?.getD (.obj #[])
            let rawJState := ((jv.fieldStr? "state").getD "running").trimAscii.toString.toLower
            let jState :=
              if rawJState == "canceled" || rawJState == "aborted" then "cancelled"
              else if rawJState == "completed" || rawJState == "terminal" then "succeeded"
              else rawJState
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
                "UPDATE remote_node_jobs SET state='cancelled', updated_at=?2 WHERE job_id=?1;"
                #[jobId, nowIso]
              discard <| execParamQuery store.projectsDb
                "UPDATE remote_jobs SET state='cancelled', heartbeat_at=?2, finished_at=COALESCE(finished_at,?2), updated_at=?2 WHERE job_id=?1;"
                #[jobId, nowIso]
              discard <| execParamQuery store.missionsDb
                "UPDATE mission_runs SET execution_state='terminal', terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND remote_job_id=?4 AND generation=CAST(?5 AS INTEGER) AND execution_state NOT IN ('terminal','completed','failed','aborted');"
                #[missionId, reason, nowIso, jobId, s!"{capturedGen}"]
              discard <| execParamQuery store.missionsDb
                "UPDATE missions SET status='failed', terminal_reason=?2, state_revision=state_revision+1, updated_at=?3 WHERE id=?1 AND run_generation=CAST(?4 AS INTEGER) AND status IN ('active','pending');"
                #[missionId, reason, nowIso, s!"{capturedGen}"]
              emitMissionEventAndBroadcast store broadcastHub? missionId "error"
                (renderCompact (.obj #[("message", .str (s!"{backend} produced no output for {firstEventSecs / 60} min and was stopped." ++
                  (if detail.isEmpty then "" else s!" Last log: {detail}")))])) nowIso
              emitMissionEventAndBroadcast store broadcastHub? missionId "mission_status_changed"
                (renderCompact (.obj #[("status", .str "failed"), ("reason", .str reason)])) nowIso
            else if jState == "succeeded" || jState == "failed" || jState == "cancelled" || jState == "lost" then
              -- Final log drain after terminal transition
              let mut finalDrained := false
              let mut remaining := if isGoal && jState == "succeeded" then 8 else 1
              while remaining > 0 do
                remaining := remaining - 1
                let .ok (flSt, _, some flJv, _, _) ← callRemoteNodeHttpOpt relayHub? mc? effNodeId "GET" s!"/jobs/{jobId}/log?offset={offset}&max_bytes=262144" none #[] 10000
                  | break
                if flSt < 200 || flSt ≥ 300 then break
                let chunk := (flJv.fieldStr? "data").getD ""
                if !chunk.isEmpty then
                  let (lines, rem) := splitCompleteLines (lineRem ++ chunk)
                  lineRem := rem
                  for ln in lines do
                    acc ← ingestRemoteHarnessLine store broadcastHub? backend missionId ln nowIso acc
                let some nextOff := flJv.fieldNat? "next_offset" | break
                let some logLen := flJv.fieldNat? "log_len" | break
                if (flJv.fieldNat? "offset") != some offset || (flJv.fieldStr? "data").isNone ||
                    nextOff < offset || nextOff > logLen || ((nextOff == offset) != chunk.isEmpty) then break
                if nextOff == logLen then
                  -- Older nodes also return an empty zero-length slice for file I/O errors.
                  finalDrained := evidenceIntact && logLen > 0
                  break
                if nextOff == offset then break
                offset := nextOff
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
                "UPDATE mission_runs SET execution_state='terminal', terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND remote_job_id=?4 AND generation=CAST(?5 AS INTEGER) AND execution_state NOT IN ('terminal','completed','failed','aborted');"
                #[missionId, termReason, nowIso, jobId, s!"{capturedGen}"]

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

              if let some tSink := sup.telemetrySink? then
                let bLow := backend.trimAscii.toString.toLower
                let normHarness := if bLow == "claude" then "claudecode" else bLow
                let effModel? :=
                  acc.model?.orElse fun _ =>
                    (mRec?.map (·.modelOverride.trimAscii.toString)).filter (!·.isEmpty)
                let ownerUid? := (mRec?.map (·.ownerUserId.trimAscii.toString)).filter (!·.isEmpty)
                let ownerUser? ← match ownerUid? with
                  | some uid => getUserById? store uid
                  | none => pure none
                let ownerUname? := (ownerUser?.map (·.username.trimAscii.toString)).filter (!·.isEmpty)
                let turnUsage : TurnUsageTelemetry := {
                  harness          := normHarness
                  model?           := effModel?
                  inputTokens?     := acc.inputTokens?
                  outputTokens?    := acc.outputTokens?
                  cacheReadTokens? := acc.cacheReadTokens?
                  costCents        := (mRec?.map (·.totalCostCents)).getD 0
                  interrupted      := jState != "succeeded"
                }
                observeControlTurnFinished tSink missionId turnUsage ownerUid? ownerUname? nowSec

              let nextQueued? ←
                if jState == "cancelled" || curRunGen != capturedGen || (isGoal && jState == "succeeded" && !finalDrained) then pure none
                else popNextQueuedFollowup? store missionId curRunGen nowIso
              match nextQueued?, mRec? with
              | some (nextMsgId, nextPrompt), some mr =>
                releasePolledJob sup jobId
                -- Carry the queue message id: clients retire the queued card of this exact
                -- message when its delivered `user_message` (same `id`) lands in the transcript.
                emitMissionEventAndBroadcast store broadcastHub? missionId "user_message"
                  (renderCompact (.obj #[("type", .str "user_message"), ("id", .str nextMsgId), ("content", .str nextPrompt), ("source", .str "queue")])) nowIso
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
                if curRunGen != capturedGen then break
                if jState == "succeeded" then
                  if let some goal := (mRec?.filter (·.goalMode)).map (·.goalObjective) then
                    match ← settleRemoteGoal store missionId jobId goal finalText capturedGen nowSec
                      (curSid?.any (resumableGoalSession backend)) finalDrained with
                    | .ok (some (status, reason, iteration)) =>
                      let phase := if reason == "remote_goal_complete" then "complete"
                        else if reason == "remote_goal_continuation" || reason == "awaiting_wakeup" then "active"
                        else "blocked"
                      emitMissionEventAndBroadcast store broadcastHub? missionId
                        (if reason == "remote_goal_continuation" then "goal_iteration" else "goal_status")
                        (renderCompact (.obj #[("status", .str phase), ("objective", .str goal),
                          ("iteration", .num s!"{iteration}"), ("reason", .str reason)])) nowIso
                      emitMissionEventAndBroadcast store broadcastHub? missionId "mission_status_changed"
                        (renderCompact (.obj #[("status", .str status), ("reason", .str reason), ("content", .str finalText)])) nowIso
                    | .ok none => pure ()
                    | .error e =>
                      emitMissionEventAndBroadcast store broadcastHub? missionId "error"
                        (renderCompact (.obj #[("message", .str s!"Could not settle remote Goal: {e}")])) nowIso
                    break
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
                let transientErrHint? :=
                  match acc.lastError? with
                  | some e => some e
                  | none =>
                    match nodeErr? with
                    | some e => some e
                    | none =>
                      if !logTail.trimAscii.toString.isEmpty then some ((logTail.trimAscii.toString.take 600).toString) else none
                let transientVerdict? ←
                  if jState != "succeeded" && jState != "cancelled" then
                    settleTransientTurnFailure store broadcastHub? missionId nowIso nowSec transientErrHint?
                  else pure none
                let mut curTermReason := ""
                if let .ok trRows ← execParamQuery store.missionsDb
                    "SELECT COALESCE(terminal_reason,'') FROM missions WHERE id=?1 LIMIT 1;" #[missionId] then
                  if trRows.size > 1 then
                    curTermReason := (cell trRows[1]! 0).trimAscii.toString
                let isProvErr := curTermReason == "provider_error" || (nodeErr?.map (· == "provider_error")).getD false
                let nextMissionStatus :=
                  if let some verdict := emptyVerdict? then verdict
                  else if let some (tStatus, _) := transientVerdict? then tStatus
                  else if jState == "succeeded" then
                    if armedWakeups > 0 then "awaiting_user" else "completed"
                  else if jState == "cancelled" then
                    if isProvErr then "interrupted" else "cancelled"
                  else "failed"
                let nextTermReason :=
                  if emptyVerdict?.isSome then (if nextMissionStatus == "failed" then "empty_turn" else "empty_turn_retry")
                  else if let some (_, tReason) := transientVerdict? then tReason
                  else if nextMissionStatus == "awaiting_user" then "awaiting_wakeup"
                  else if jState == "cancelled" && isProvErr then "provider_error"
                  else termReason
                if transientVerdict?.isSome then
                  discard <| execParamQuery store.missionsDb
                    "UPDATE mission_runs SET terminal_reason=?2, updated_at=?3 WHERE mission_id=?1 AND remote_job_id=?4 AND generation=CAST(?5 AS INTEGER);"
                    #[missionId, nextTermReason, nowIso, jobId, s!"{capturedGen}"]
                -- Only the observer that owns the current generation may settle
                -- the mission. A stale poller still closes its own job ledger,
                -- but cannot overwrite a newer turn's status or queues.
                if let .ok updated ← execParamQuery store.missionsDb
                  ("UPDATE missions SET status=?2, terminal_reason=?3, state_revision=state_revision+1, updated_at=?4 " ++
                   "WHERE id=?1 AND run_generation=CAST(?5 AS INTEGER) AND status NOT IN ('cancelled','interrupted') RETURNING id;")
                  #[missionId, nextMissionStatus, nextTermReason, nowIso, s!"{capturedGen}"] then
                  if updated.size > 1 then
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
  if let some cause ← nodeApiHangCause? store effTarget then return .error cause
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

  -- The original job identity is minted before the node can accept work so the
  -- lease and payload refer to one id. It is persisted durably immediately
  -- before the POST, after every local validation has passed.
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
  let leaseExpires := nowSec + 900
  let leaseTok := signRemoteNodeLeaseToken nodeSecret spec.missionId leaseNodeId "job:submit" leaseExpires (some jobId) spec.ownerUserId callerRole unixUser?
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

  -- A lost acceptance reply or a post-accept database failure is then an
  -- uncertain identity Core can probe and replay, never orphaned remote work.
  let submitNowIso := formatEpochIso8601Utc nowSec
  ensureDurableJobsTableLocal store
  let preMeta := renderCompact (.obj #[
    ("backend", .str spec.backend),
    ("side_question", .bool spec.sideQuestion),
    ("goal_generation", spec.goalDispatch?.map (fun g => JVal.uint64 g.2) |>.getD .null),
    ("goal_claim", spec.goalDispatch?.map (fun g => JVal.str g.1) |>.getD .null),
    ("wakeup_claim", spec.wakeupClaim?.map (fun c => .str c.id) |>.getD .null),
    ("wakeup_request", spec.wakeupClaim?.map (fun c => .str c.requestId) |>.getD .null),
    ("wakeup_generation", spec.wakeupClaim?.map (fun c => JVal.uint64 c.generation) |>.getD .null),
    ("wakeup_lease_expires", if spec.wakeupClaim?.isSome then JVal.uint64 leaseExpires else .null),
    ("prompt_bytes", JVal.nat spec.prompt.utf8ByteSize)
  ])
  let intentRes ← match spec.goalDispatch? with
    | some (cid, gen) => withImmediateTx store.missionsDb do
      let query := execParamQueryUnlocked store.missionsDb
      let .ok owners ← query ("SELECT 1 FROM missions m WHERE " ++ remoteGoalDispatchOwnerSql ++ ";")
        #[spec.missionId, s!"{gen}", if cid.isEmpty then "1" else "0"]
        | return .error "remote_goal_owner_read_failed"
      if owners.size ≤ 1 then return .error "remote_goal_dispatch_fenced"
      if !cid.isEmpty then
        let .ok claimed ← query
          ("UPDATE mission_continuations SET job_id=?4 WHERE id=?1 AND mission_id=?2 AND phase=2 " ++
           "AND run_generation=CAST(?3 AS INTEGER) AND COALESCE(job_id,'')='' RETURNING id;")
          #[cid, spec.missionId, s!"{gen}", jobId] | return .error "remote_goal_claim_write_failed"
        if claimed.size ≤ 1 then return .error "remote_goal_dispatch_fenced"
      query
        ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
         "VALUES(?1,?2,?3,'submitting',?4,?5,?5);")
        #[jobId, spec.missionId, effTarget, preMeta, submitNowIso]
    | none => withImmediateTx store.missionsDb do
      let query := execParamQueryUnlocked store.missionsDb
      if let some claim := spec.wakeupClaim? then
        let .ok rows ← query
          ("UPDATE mission_continuations SET dispatch_job_id=?5 WHERE id=?1 AND request_id=?2 AND mission_id=?3 " ++
           "AND phase=2 AND run_generation=CAST(?4 AS INTEGER) AND dispatch_job_id='' " ++
           "AND NOT EXISTS(SELECT 1 FROM remote_node_jobs WHERE mission_id=?3 AND state IN ('submitting','uncertain')) " ++
           "RETURNING id;") #[claim.id, claim.requestId, spec.missionId, s!"{claim.generation}", jobId]
          | return .error "wakeup_claim_write_failed"
        if rows.size ≤ 1 then return .error "wakeup_claim_fenced"
        match ← remoteWakeupOwned store spec.missionId jobId claim with
        | .error e => return .error e
        | .ok false => return .error "wakeup_claim_fenced"
        | .ok true => pure ()
      query
        ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
         "VALUES(?1,?2,?3,'submitting',?4,?5,?5) " ++
         "ON CONFLICT(job_id) DO UPDATE SET state='submitting', node_id=excluded.node_id, updated_at=excluded.updated_at;")
        #[jobId, spec.missionId, effTarget, preMeta, submitNowIso]
  match intentRes with
  | .error e =>
    if !prep.proxyToken.isEmpty then revokeSingleMissionProxyToken store prep.proxyToken
    return .error (if e == "remote_goal_dispatch_fenced" then e else s!"remote_launch_intent_failed:{e}")
  | .ok _ => pure ()

  if let some (cid, _) := spec.goalDispatch? then
    if !cid.isEmpty then
      emitMissionEventAndBroadcast store broadcastHub? spec.missionId "user_message"
        (renderCompact (.obj #[("type", .str "user_message"), ("content", .str spec.prompt),
          ("source", .str "wakeup"), ("continuation_id", .str cid)])) submitNowIso
  match ← callRemoteNodeHttpOpt relayHub? mc? effTarget "POST" "/jobs" (some submitBody) #[] 20000 with
  | .error e =>
    -- The request may have been accepted before the transport failed. Keep the
    -- durable identity in `uncertain`, not `lost`, and let startup/periodic
    -- reconciliation probe the same job id instead of submitting a duplicate.
    discard <| execParamQuery store.missionsDb
      "UPDATE remote_node_jobs SET state='uncertain', updated_at=?2 WHERE job_id=?1 AND state='submitting';"
      #[jobId, formatEpochIso8601Utc (← nowEpoch)]
    -- Keep the proxy token: the node may have accepted this exact job before the
    -- reply was lost, and a reconciled turn still needs it.
    return .error s!"remote_dispatch_uncertain:{e}"
  | .ok (status, respTxt, _, _, _) =>
    if status < 200 || status ≥ 300 then
      if spec.wakeupClaim?.isSome && (status ≥ 500 || status == 408 || status == 409) then
        discard <| execParamQuery store.missionsDb "UPDATE remote_node_jobs SET state='uncertain' WHERE job_id=?1 AND state='submitting';" #[jobId]
        return .error s!"remote_dispatch_uncertain:http_{status}"
      let settled ← withImmediateTx store.missionsDb do
        if let .error e ← execParamQueryUnlocked store.missionsDb
            "UPDATE remote_node_jobs SET state='failed', updated_at=?2 WHERE job_id=?1 AND state IN ('submitting','uncertain');"
            #[jobId, submitNowIso] then return .error e
        if let some claim := spec.wakeupClaim? then
          settleWakeupClaimUnlocked store claim jobId false 0 nowSec
        else pure (.ok ())
      if let .error _ := settled then
        discard <| execParamQuery store.missionsDb "UPDATE remote_node_jobs SET state='uncertain' WHERE job_id=?1 AND state='submitting';" #[jobId]
      if !prep.proxyToken.isEmpty then revokeSingleMissionProxyToken store prep.proxyToken
      return .error s!"remote_node_rejected_{status}:{respTxt}"
    let nowIso := formatEpochIso8601Utc nowSec
    let recMeta := renderCompact (.obj #[
      ("backend", .str spec.backend),
      ("side_question", .bool spec.sideQuestion),
      ("goal_generation", .null)
    ])
    if spec.goalDispatch?.isNone && spec.wakeupClaim?.isNone then
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
      if let some (cid, expected) := spec.goalDispatch? then
        match ← remoteGoalDispatchOwned store spec.missionId jobId expected cid.isEmpty with
        | .error e => return .error e
        | .ok false => return .error "remote_goal_dispatch_fenced"
        | .ok true => pure ()
      if let some claim := spec.wakeupClaim? then
        match ← remoteWakeupOwned store spec.missionId jobId claim with
        | .error e => return .error e
        | .ok false => return .error "remote_wakeup_dispatch_fenced"
        | .ok true => pure ()
      let gRows ← execParamQueryUnlocked store.missionsDb
        "SELECT COALESCE(run_generation,1), COALESCE((SELECT MAX(generation) FROM mission_runs WHERE mission_id=?1),0),status FROM missions WHERE id=?1;"
        #[spec.missionId]
      let mut nextGen : Nat := 1
      if let .ok grs := gRows then
        if grs.size > 1 then
          let mg := cellNat grs[1]! 0
          let rg := cellNat grs[1]! 1
          nextGen := if rg == 0 then Nat.max 1 mg else Nat.max mg (rg + 1)
      if let .error e ← insertMissionRunUnlocked
        store.missionsDb runId spec.missionId s!"{nextGen}" "running" "" jobId nowIso true
        s!"remote-job:{jobId}" s!"remote-node:{effTarget}" then return .error e
      if spec.goalDispatch?.isSome || spec.wakeupClaim?.isSome then
        if let .error e ← execParamQueryUnlocked store.missionsDb
          "UPDATE remote_node_jobs SET state='running',updated_at=?2 WHERE job_id=?1;" #[jobId, nowIso] then return .error e
      carryArmedWakeupsForward (execParamQueryUnlocked store.missionsDb) spec.missionId nextGen nowIso
      let result ← execParamQueryUnlocked store.missionsDb
        ("UPDATE missions SET status='active', terminal_reason='remote_node_job', placement_job_id=?2, " ++
         "run_generation=CAST(?3 AS INTEGER), state_revision=state_revision+1, updated_at=?4 WHERE id=?1;")
        #[spec.missionId, jobId, s!"{nextGen}", nowIso]
      if let .error e := result then return .error e
      if let some claim := spec.wakeupClaim? then
        if let .error e ← settleWakeupClaimUnlocked store claim jobId true nextGen.toUInt64 nowSec then return .error e
      return result
    if let .error dbErr := txRes then
      if dbErr == "remote_goal_dispatch_fenced" || dbErr == "remote_wakeup_dispatch_fenced" then
        let stopped ← callRemoteNodeHttpOpt relayHub? mc? effTarget "POST" s!"/jobs/{jobId}/cancel" (some (.obj #[])) #[] 8000
        let state := match stopped with
          | .ok (code, _, _, _, _) => if 200 ≤ code && code < 300 then "cancelled" else "uncertain"
          | .error _ => "uncertain"
        discard <| withImmediateTx store.missionsDb do
          if let .error e ← execParamQueryUnlocked store.missionsDb
              "UPDATE remote_node_jobs SET state=?2 WHERE job_id=?1;" #[jobId, state] then return .error e
          if state == "cancelled" then
            if let some claim := spec.wakeupClaim? then
              return ← settleWakeupClaimUnlocked store claim jobId true 0 nowSec
          return .ok ()
        return .error dbErr
      -- The node accepted the work but Core could not activate its owner row.
      -- Preserve the accepted identity as uncertain and do not start a second
      -- writer; boot reconciliation will attach the same job.
      discard <| execParamQuery store.missionsDb
        "UPDATE remote_node_jobs SET state='uncertain', updated_at=?2 WHERE job_id=?1;"
        #[jobId, nowIso]
      return .error s!"remote_accept_persist_failed:{dbErr}"
    emitMissionEventAndBroadcast store broadcastHub? spec.missionId "mission_status_changed"
      (renderCompact (.obj #[("status", .str "active"), ("job_id", .str jobId), ("remote_node_id", .str effTarget)])) nowIso
    if let some tSink := sup.telemetrySink? then
      let ownerUid? := if spec.ownerUserId.trimAscii.toString.isEmpty then none else some spec.ownerUserId.trimAscii.toString
      let ownerUname? := (ownerUser?.map (·.username.trimAscii.toString)).filter (!·.isEmpty)
      ensureTurnTelemetryStarted tSink spec.missionId spec.prompt ownerUid? ownerUname?
    spawnRemoteJobPoller store mc? relayHub? broadcastHub? sup coreWorkDir spec.missionId spec.backend effTarget jobId prep.proxyToken 0
    return .ok jobId

end

/-! ## Startup Re-Attachment of Live Remote Jobs -/

/-- Run after acquiring listen ownership and before admitting any new work.
    Mark all orphaned fenced submissions, including rows outside the probe limit. -/
def fenceInterruptedRemoteSubmissions (store : CoreStore) : IO (Except String Unit) := do
  ensureDurableJobsTableLocal store
  let result ← execParamQuery store.missionsDb
    ("UPDATE remote_node_jobs SET state='uncertain' WHERE state='submitting' AND " ++ fencedSubmissionSql "payload_json" ++ ";") #[]
  return result.map (fun _ => ())

/-- Probe remote submissions whose acceptance was never durably confirmed.
    Leave live fenced POSTs alone. Attach a found job to its original id, settle
    an authoritative absence, and keep an unavailable receipt uncertain. -/
def reconcileUncertainRemoteSubmissions
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (coreWorkDir : String) (startup : Bool := true) (nowOverride? : Option UInt64 := none) : IO Nat := do
  ensureDurableJobsTableLocal store
  let nowSec ← match nowOverride? with | some t => pure t | none => nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let .ok rows ← execParamQuery store.missionsDb
      ("SELECT j.job_id, COALESCE(j.node_id,''), COALESCE(j.mission_id,''), COALESCE(j.payload_json,'{}') " ++
       "FROM remote_node_jobs j JOIN missions m ON m.id=j.mission_id " ++
        "WHERE (j.state IN ('uncertain','submitting') AND ?1='1' AND NOT (j.state='submitting' AND " ++
        fencedSubmissionSql "j.payload_json" ++ ")) OR (j.state='uncertain' AND " ++ fencedSubmissionSql "j.payload_json" ++ ") " ++
        "ORDER BY j.updated_at ASC LIMIT 64;")
       #[if startup then "1" else "0"] | return 0
  let mut attached : Nat := 0
  for i in [1:rows.size] do
    let r := rows[i]!
    let jid := (cell r 0).trimAscii.toString
    let rawNode := (cell r 1).trimAscii.toString
    let mid := (cell r 2).trimAscii.toString
    if jid.isEmpty || mid.isEmpty then continue
    let metaJv := (OrbBin.Json.parse (cell r 3)).toOption.getD (.obj #[])
    let backend := (metaJv.fieldStr? "backend").getD "codex"
    let goalGen? := metaJv.fieldUInt64? "goal_generation"
    let wakeup? : Option WakeupClaim := do
      return ⟨← metaJv.fieldStr? "wakeup_claim", ← metaJv.fieldStr? "wakeup_request", ← metaJv.fieldUInt64? "wakeup_generation"⟩
    let initialGoal := metaJv.fieldStr? "goal_claim" == some ""
    let node? ← if wakeup?.isSome then pure (if rawNode.isEmpty then none else some rawNode)
      else match ← resolveConcreteRemoteTargetNode mc? rawNode (some (store, mid)) with
        | .ok n => pure (some n)
        | .error _ => pure (if rawNode.isEmpty then none else some rawNode)
    let some node := node? | continue
    -- Rotate fenced receipts through the bounded probe page even if their node
    -- keeps timing out. Do not change their acceptance state on a failed probe.
    if wakeup?.isSome || goalGen?.isSome then
      discard <| execParamQuery store.missionsDb
        "UPDATE remote_node_jobs SET updated_at=?2 WHERE job_id=?1 AND state='uncertain';" #[jid, nowIso]
    match ← callRemoteNodeHttpOpt relayHub? mc? node "GET" s!"/jobs/{jid}" none #[] 10000 with
    | .error _ => pure ()
    | .ok (status, response, view?, _, _) =>
      if status == 404 then
        if let some claim := wakeup? then
          -- A GET can overtake a delayed POST. Negative evidence is usable
          -- only after the original submission's lease can no longer admit it.
          -- The small grace period accommodates node clock skew.
          if (metaJv.fieldUInt64? "wakeup_lease_expires").any (fun exp => nowSec > exp + 30) &&
              response.trimAscii.toString == "job not found" then
            discard <| withImmediateTx store.missionsDb do
              let .ok changed ← execParamQueryUnlocked store.missionsDb
                "UPDATE remote_node_jobs SET state='failed',updated_at=?2 WHERE job_id=?1 AND state='uncertain' RETURNING job_id;"
                #[jid, nowIso] | return .error "remote_wakeup_missing_write_failed"
              if changed.size ≤ 1 then return .ok ()
              settleWakeupClaimUnlocked store claim jid false 0 nowSec
          continue
        if let some gen := goalGen? then
          discard <| withImmediateTx store.missionsDb do
            if let .ok true ← remoteGoalDispatchOwned store mid jid gen initialGoal then
              if let .error e ← execParamQueryUnlocked store.missionsDb
                "UPDATE missions SET status='interrupted',terminal_reason='remote_dispatch_uncertain_missing',state_revision=state_revision+1,updated_at=?2 WHERE id=?1;"
                #[mid, nowIso] then return .error e
            execParamQueryUnlocked store.missionsDb
              "UPDATE remote_node_jobs SET state='failed',updated_at=?2 WHERE job_id=?1 AND state IN ('submitting','uncertain');"
              #[jid, nowIso]
          continue
        discard <| execParamQuery store.missionsDb
          "UPDATE remote_node_jobs SET state='failed', updated_at=?2 WHERE job_id=?1 AND state IN ('submitting','uncertain');"
          #[jid, nowIso]
        discard <| execParamQuery store.missionsDb
          ("UPDATE missions SET status='interrupted', terminal_reason='remote_dispatch_uncertain_missing', " ++
           "state_revision=state_revision+1, updated_at=?2 WHERE id=?1 AND status IN ('active','pending') " ++
           "AND NOT EXISTS (SELECT 1 FROM remote_node_jobs j WHERE j.mission_id=?1 AND j.job_id<>?3 " ++
           "AND j.state NOT IN ('succeeded','failed','cancelled','lost','terminal','completed','aborted'));")
          #[mid, nowIso, jid]
      else if 200 ≤ status && status < 300 then
        if wakeup?.isSome && (view? >>= (·.fieldStr? "job_id")) != some jid then continue
        if goalGen?.isNone && wakeup?.isNone then
          discard <| execParamQuery store.missionsDb
            "UPDATE remote_node_jobs SET state='running', updated_at=?2 WHERE job_id=?1;"
            #[jid, nowIso]
        let .ok gRows ← execParamQuery store.missionsDb
            "SELECT COALESCE(run_generation,1), COALESCE((SELECT MAX(generation) FROM mission_runs WHERE mission_id=?1),0) FROM missions WHERE id=?1;"
            #[mid] | continue
        let mut nextGen : Nat := 1
        if gRows.size > 1 then
          let mg := cellNat gRows[1]! 0
          let rg := cellNat gRows[1]! 1
          nextGen := if rg == 0 then Nat.max 1 mg else Nat.max mg (rg + 1)
        let runId ← newUuidV4
        let txRes ← withImmediateTx store.missionsDb do
          if let some claim := wakeup? then
            let .ok pending ← execParamQueryUnlocked store.missionsDb
              "SELECT 1 FROM remote_node_jobs WHERE job_id=?1 AND state='uncertain';" #[jid]
              | return .error "remote_wakeup_pending_read_failed"
            if pending.size ≤ 1 then return .error "remote_wakeup_already_settled"
            match ← remoteWakeupOwned store mid jid claim with
            | .error e => return .error e
            | .ok false => return .error "remote_wakeup_dispatch_fenced"
            | .ok true => pure ()
            if let .error e ← execParamQueryUnlocked store.missionsDb
              "UPDATE remote_node_jobs SET state='running',updated_at=?2 WHERE job_id=?1;" #[jid, nowIso] then return .error e
            carryArmedWakeupsForward (execParamQueryUnlocked store.missionsDb) mid nextGen nowIso
          if let some gen := goalGen? then
            match ← remoteGoalDispatchOwned store mid jid gen initialGoal with
            | .error e => return .error e
            | .ok false => return .error "remote_goal_dispatch_fenced"
            | .ok true => pure ()
            if let .error e ← execParamQueryUnlocked store.missionsDb
              "UPDATE remote_node_jobs SET state='running',updated_at=?2 WHERE job_id=?1;" #[jid, nowIso] then return .error e
          if let .error e ← insertMissionRunUnlocked
            store.missionsDb runId mid s!"{nextGen}" "running" "" jid nowIso true
            s!"remote-job:{jid}" s!"remote-node:{node}" then return .error e
          let result ← execParamQueryUnlocked store.missionsDb
            "UPDATE missions SET status='active', terminal_reason='remote_node_job', placement_job_id=?2, run_generation=CAST(?3 AS INTEGER), state_revision=state_revision+1, updated_at=?4 WHERE id=?1 AND status NOT IN ('cancelled','completed','failed');"
            #[mid, jid, s!"{nextGen}", nowIso]
          if let .error e := result then return .error e
          if let some claim := wakeup? then
            if let .error e ← settleWakeupClaimUnlocked store claim jid true nextGen.toUInt64 nowSec then return .error e
          return result
        match txRes with
        | .error "remote_wakeup_already_settled" => pure ()
        | .error "remote_wakeup_dispatch_fenced" =>
          if let .ok (code, _, _, _, _) ← callRemoteNodeHttpOpt relayHub? mc? node "POST" s!"/jobs/{jid}/cancel" (some (.obj #[])) #[] 8000 then
            if 200 ≤ code && code < 300 then
              discard <| withImmediateTx store.missionsDb do
                if let .error e ← execParamQueryUnlocked store.missionsDb
                  "UPDATE remote_node_jobs SET state='cancelled' WHERE job_id=?1 AND state='uncertain';" #[jid] then return .error e
                if let some claim := wakeup? then return ← settleWakeupClaimUnlocked store claim jid true 0 nowSec
                return .ok ()
        | .error "remote_goal_dispatch_fenced" =>
          if let .ok pending ← execParamQuery store.missionsDb
              "SELECT 1 FROM remote_node_jobs WHERE job_id=?1 AND state IN ('submitting','uncertain');" #[jid] then
            if pending.size > 1 then
              if let .ok (code, _, _, _, _) ← callRemoteNodeHttpOpt relayHub? mc? node "POST" s!"/jobs/{jid}/cancel" (some (.obj #[])) #[] 8000 then
                if 200 ≤ code && code < 300 then
                  discard <| execParamQuery store.missionsDb "UPDATE remote_node_jobs SET state='cancelled' WHERE job_id=?1 AND state IN ('submitting','uncertain');" #[jid]
        | .error _ =>
          -- The accepted job is still owned by Core; keep it probeable rather
          -- than leaving a `running` job without a local owner row.
          unless wakeup?.isSome do
            discard <| execParamQuery store.missionsDb
              "UPDATE remote_node_jobs SET state='uncertain', updated_at=?2 WHERE job_id=?1 AND (?3='' OR state='submitting');"
              #[jid, nowIso, if goalGen?.isSome then "goal" else ""]
        | .ok _ =>
          spawnRemoteJobPoller store mc? relayHub? broadcastHub? sup coreWorkDir mid backend node jid "" 0
          attached := attached + 1
  return attached

/-- Re-attach background log/state pollers for all non-terminal `remote-job:*` `mission_runs` on Core startup. -/
def reattachActiveRemoteJobsOnStartup
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (coreWorkDir : String) : IO Nat := do
  ensureDurableJobsTableLocal store
  let reconciled ← reconcileUncertainRemoteSubmissions store mc? relayHub? broadcastHub? sup coreWorkDir
  let nowIso := formatEpochIso8601Utc (← nowEpoch)
  if let .ok staleRows ← execParamQuery store.missionsDb
      ("SELECT j.job_id, COALESCE(j.node_id,''), COALESCE(j.mission_id,'') " ++
       "FROM remote_node_jobs j LEFT JOIN missions m ON m.id = j.mission_id " ++
       "WHERE j.state NOT IN ('terminal','completed','succeeded','failed','aborted','cancelled','lost') " ++
     "AND (m.id IS NULL OR m.status NOT IN ('active','pending')) " ++
      "AND NOT (j.state IN ('submitting','uncertain') AND " ++ fencedSubmissionSql "j.payload_json" ++ ");")
      #[] then
    for i in [1:staleRows.size] do
      let srow := staleRows[i]!
      let sjid := (cell srow 0).trimAscii.toString
      let snid := (cell srow 1).trimAscii.toString
      let smid := (cell srow 2).trimAscii.toString
      if !sjid.isEmpty then
        if !snid.isEmpty then
          let effNode ← match ← resolveConcreteRemoteTargetNode mc? snid (if smid.isEmpty then none else some (store, smid)) with
            | .ok n => pure n
            | .error _ => pure snid
          let hdrs := #[("x-sandboxed-cancel-actor", "core"), ("x-sandboxed-cancel-reason", "Mission inactive on Core startup")]
          discard <| callRemoteNodeHttpOpt relayHub? mc? effNode "POST" s!"/jobs/{sjid}/cancel" (some (.obj #[])) hdrs 6000
        discard <| execParamQuery store.missionsDb
          "UPDATE remote_node_jobs SET state='cancelled', updated_at=?2 WHERE job_id=?1;" #[sjid, nowIso]
        discard <| execParamQuery store.projectsDb
          "UPDATE remote_jobs SET state='cancelled', heartbeat_at=?2, finished_at=COALESCE(finished_at,?2), updated_at=?2 WHERE job_id=?1;" #[sjid, nowIso]
  let qRes ← execParamQuery store.missionsDb
    ("SELECT r.mission_id, COALESCE(NULLIF(r.remote_job_id,''), NULLIF(m.placement_job_id,''), ''), COALESCE(r.owner_actor_id,''), COALESCE(r.scope_unit,''), " ++
     "COALESCE(m.backend,'codex'), COALESCE(r.updated_at,'') " ++
     "FROM mission_runs r JOIN missions m ON m.id = r.mission_id " ++
     "WHERE r.execution_state NOT IN ('terminal','completed','failed','aborted') " ++
     "AND r.generation = COALESCE(m.run_generation,1) " ++
     "AND m.status IN ('active','pending') " ++
     "UNION " ++
     "SELECT j.mission_id, j.job_id, 'remote-job:' || j.job_id, 'remote-node:' || j.node_id, " ++
     "COALESCE(m.backend,'codex'), COALESCE(j.updated_at,'') " ++
     "FROM remote_node_jobs j JOIN missions m ON m.id = j.mission_id " ++
     "WHERE j.state NOT IN ('submitting','uncertain','succeeded','failed','cancelled','lost','terminal','completed','aborted') " ++
     "AND m.status IN ('active','pending');")
    #[]
  let .ok rows := qRes | return 0
  let mut count : Nat := 0
  let mut seenJobs : Array String := #[]
  for i in [1:rows.size] do
    let row := rows[i]!
    let mid := (cell row 0).trimAscii.toString
    let rjid := (cell row 1).trimAscii.toString
    let actor := (cell row 2).trimAscii.toString
    let scope := (cell row 3).trimAscii.toString
    let backend := (cell row 4).trimAscii.toString
    let _runUpdated := (cell row 5).trimAscii.toString
    let jobId :=
      if !rjid.isEmpty then rjid
      else if actor.startsWith "remote-job:" then (actor.drop 11).trimAscii.toString
      else ""
    if !mid.isEmpty && !jobId.isEmpty && !seenJobs.contains jobId then
      seenJobs := seenJobs.push jobId
      let nodeFromScope :=
        if scope.startsWith "remote-node:" then some ((scope.drop 12).trimAscii.toString) else none
      let resolvedNode? ← match nodeFromScope.filter (!·.isEmpty) with
        | some n => pure (some n)
        | none => resolveMissionRemoteNode? store mc? mid
      if let some rawNode := resolvedNode? then
        let effNode ← match ← resolveConcreteRemoteTargetNode mc? rawNode (some (store, mid)) with
          | .ok n => pure n
          | .error _ => pure rawNode
        -- Resume from `remote_log_offsets.published_offset` (0 if no chunk was ingested before restart)
        let mut startOff : Nat := 0
        if let .ok offRows ← execParamQuery store.missionsDb
            "SELECT COALESCE(published_offset,0) FROM remote_log_offsets WHERE job_id=?1 LIMIT 1;" #[jobId] then
          if offRows.size > 1 then
            startOff := cellNat offRows[1]! 0
        spawnRemoteJobPoller store mc? relayHub? broadcastHub? sup coreWorkDir mid backend effNode jobId "" startOff
        count := count + 1
  return count + reconciled

/-- Independent pump for remote-owned missions with a waiting follow-up but no
    live remote job. The poller normally drains the queue on settlement; if that
    handoff was lost (crash, race, dropped reply), this pass re-establishes the
    turn from the durable queue row without waiting for a poller that is gone. -/
def tickRemoteFollowupPump
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (coreWorkDir : String)
    (nowSec : UInt64) : IO Nat := do
  let nowIso := formatEpochIso8601Utc nowSec
  let .ok rows ← execParamQuery store.missionsDb
      ("SELECT m.id, COALESCE(m.run_generation,1) FROM missions m WHERE m.status='active' " ++
       "AND EXISTS(SELECT 1 FROM remote_message_queue q WHERE q.mission_id=m.id AND q.state='waiting' AND COALESCE(q.phase,0)=0) " ++
       "AND NOT EXISTS(SELECT 1 FROM remote_node_jobs j WHERE j.mission_id=m.id AND j.state NOT IN ('submitting','uncertain','succeeded','failed','cancelled','lost','terminal','completed','aborted')) " ++
       "ORDER BY m.updated_at ASC LIMIT 32;") #[] | return 0
  let mut pumped : Nat := 0
  for i in [1:rows.size] do
    let mid := (cell rows[i]! 0).trimAscii.toString
    let gen := (cellNat rows[i]! 1).toUInt64
    if mid.isEmpty then continue
    let some mr ← getMission? store mid | continue
    if mr.status != "active" || mr.runGeneration != gen then continue
    -- Resolve the destination before claiming the queue row: a local mission
    -- must keep its waiting messages for the local harness, not consume them
    -- here. A stale historical job node is not proof the mission is remote now.
    let some rawNode ← resolveMissionRemoteNode? store mc? mid | continue
    if rawNode.trimAscii.toString.isEmpty then continue
    let effNode ← match ← resolveConcreteRemoteTargetNode mc? rawNode (some (store, mid)) with
      | .ok n => pure n
      | .error _ => pure rawNode
    let some (nextMsgId, nextPrompt) ← popNextQueuedFollowup? store mid gen nowIso | continue
    let mut sid? : Option String := none
    if let .ok sRows ← execParamQuery store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
      if sRows.size > 1 then
        let sid := (cell sRows[1]! 0).trimAscii.toString
        if !sid.isEmpty then sid? := some sid
    emitMissionEventAndBroadcast store broadcastHub? mid "user_message"
      (renderCompact (.obj #[("type", .str "user_message"), ("id", .str nextMsgId), ("content", .str nextPrompt), ("source", .str "queue")])) nowIso
    let spec : RemoteTurnSpec := {
      missionId := mid, targetNodeId := effNode, backend := mr.backend
      modelOverride := mr.modelOverride, modelEffort := mr.modelEffort
      workingDirectory := mr.workingDirectory, project := mr.project
      ownerUserId := mr.ownerUserId, authorityMode := mr.authorityMode
      placementKind := mr.placementKind, reservedDiskGib := mr.reservedDiskGib
      tagsJson := mr.tagsJson, prompt := nextPrompt, resumeSessionId? := sid?
    }
    match ← submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup coreWorkDir spec nowSec with
    | .ok _ => pumped := pumped + 1
    | .error e =>
      emitMissionEventAndBroadcast store broadcastHub? mid "error"
        (renderCompact (.obj #[("message", .str s!"Queued follow-up dispatch will be retried: {e}")])) nowIso
  return pumped

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
  let trigTypeExpr := if hasTrigType then "lower(trim(COALESCE(trigger_type,'')))" else "''"
  let trigDataExpr := if hasTrigData then "COALESCE(trigger_data,'{}')" else "'{}'"
  let lastTrigExpr := if colNames.contains "last_triggered_at" then "COALESCE(last_triggered_at,'')" else "''"
  let createdExpr := if colNames.contains "created_at" then "COALESCE(created_at,'')" else "''"
  let stopPolExpr := if colNames.contains "stop_policy" then "COALESCE(stop_policy,'')" else "''"

  let selSql :=
    s!"SELECT id, mission_id, {cmdExpr}, {trigTypeExpr}, {trigDataExpr}, {createdExpr}, {lastTrigExpr}, {stopPolExpr} " ++
    s!"FROM automations WHERE COALESCE(active,0)=1 AND {trigTypeExpr} IN ('interval','time','job','durable_job_terminal');"
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
    let stopFirst := #["after_first_fire", "after_first", "\"after_first\"", "{\"type\":\"after_first\"}"].contains stopPol
    if !(stopFirst || #["", "never", "when_mission_terminal"].contains stopPol) then continue
    if !aid.isEmpty && !mid.isEmpty then
      let result ← withImmediateTx store.missionsDb do
        let query := execParamQueryUnlocked store.missionsDb
        let mRows ← query "SELECT status, COALESCE(run_generation,1) FROM missions WHERE id=?1;" #[mid]
        match mRows with
        | .error e => return .error e
        | .ok mrs =>
          if mrs.size ≤ 1 then return .ok false
          let mStatus := cell mrs[1]! 0
          let mRunGen := Nat.max 1 (cellNat mrs[1]! 1)
          if mStatus == "cancelled" || mStatus == "failed" || mStatus == "not_feasible" then
            return .ok false
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
                |>.getD 0
            let explicitAt? :=
              (trigJv.fieldStr? "at")
                |>.orElse (fun _ => trigJv.fieldStr? "next_at")
                |>.bind parseIso8601EpochU64?
            let jobId := (trigJv.fieldStr? "job_id").getD ""
            let isJobTrig := trigType == "job" || trigType == "durable_job_terminal"
            if (isJobTrig && jobId.isEmpty) || (!isJobTrig && !jobId.isEmpty) ||
                (trigType == "interval" && secs < 60) || (trigType == "time" && explicitAt?.isNone && secs == 0) then
              return .ok false
            let effTrigKind := if isJobTrig then "durable_job_terminal" else "time"
            let dueEpoch :=
              if isJobTrig then nowSec + 86400
              else match explicitAt? with
                | some ep => ep
                | none => baseEpoch + secs
            let isRecurring :=
              !isJobTrig && (trigType == "interval") &&
              !stopFirst
            let recurrenceStr := if isRecurring then s!"interval:{Nat.max 60 secs.toNat}" else ""
            let stopFirstInt := if isRecurring then "0" else "1"
            let cid := s!"leg-auto-{aid}"
            let reqId := s!"legacy-automation:{aid}"
            let .ok inserted ← query
               ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
                "SELECT ?1,?2,CAST(?3 AS INTEGER),1,CAST(?4 AS INTEGER),?5,'legacy_automation',?6,?7,?8,'legacy-automations-migration','',?9,CAST(?10 AS INTEGER),?11,?11 " ++
                "WHERE EXISTS(SELECT 1 FROM automations WHERE id=?12 AND active=1) AND NOT EXISTS(" ++
                "SELECT 1 FROM mission_continuations WHERE mission_id=?2 AND phase IN (1,2) AND trigger_kind=?5 " ++
                "AND (?5='time' OR job_id=?8)) RETURNING id;")
               #[cid, mid, s!"{mRunGen}", s!"{dueEpoch}", effTrigKind, prompt, reqId, jobId, recurrenceStr, stopFirstInt, nowIso, aid]
              | return .error "legacy_automation_insert_failed"
            if inserted.size ≤ 1 then return .ok false
            if mStatus == "completed" then
              if let .error e ← query
                  "UPDATE missions SET status='awaiting_user', terminal_reason='awaiting_wakeup', state_revision=state_revision+1, updated_at=?2 WHERE id=?1 AND status='completed';"
                  #[mid, nowIso] then return .error e
            let .ok retired ← query "UPDATE automations SET active=0 WHERE id=?1 AND active=1 RETURNING id;" #[aid]
              | return .error "legacy_automation_retire_failed"
            if retired.size ≤ 1 then return .error "legacy_automation_retire_failed"
            return .ok true
      if let .ok true := result then migrated := migrated + 1
  return migrated

/-- Evaluate due `mission_continuations` (`time` and `durable_job_terminal`) and wake idle missions. -/
def tickContinuationScheduler
    (store : CoreStore)
    (mc? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (sup : RemoteJobSupervisor)
    (warmMgr? : Option OrbBin.ClaudeControl.WarmHarnessManager)
    (coreWorkDir : String)
    (localFallbackLaunch? : Option (MissionRecord → String → Option String → WakeupClaim → IO Bool) := none)
    (nowOverride? : Option UInt64 := none) : IO Nat := do
  let nowSec ← match nowOverride? with | some t => pure t | none => nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  discard <| migrateLegacyAutomations store nowSec
  ensureDurableJobsTableLocal store
  -- Fairness is part of the query, not an accident of row order. A blocked
  -- active owner must not occupy the whole bounded page and starve an idle
  -- owner behind it. Durable-job wakeups whose job is still nonterminal are not
  -- candidates yet; a terminal receipt is the only thing that makes them due.
  let dueRes ← execParamQuery store.missionsDb
    ("SELECT c.id, c.mission_id, COALESCE(c.run_generation,1), COALESCE(c.due_epoch,0), COALESCE(c.trigger_kind,'time'), " ++
     "COALESCE(c.prompt,''), COALESCE(c.reason,''), COALESCE(c.job_id,''), COALESCE(c.error,''), c.request_id,c.phase " ++
     "FROM mission_continuations c LEFT JOIN missions m ON m.id=c.mission_id " ++
     "WHERE c.phase = 1 AND NOT EXISTS(SELECT 1 FROM remote_node_jobs j WHERE j.mission_id=c.mission_id " ++
     "AND j.state IN ('submitting','uncertain') AND " ++ fencedSubmissionSql "j.payload_json" ++ ") AND (" ++
     "  (c.trigger_kind = 'time' AND c.due_epoch <= CAST(?1 AS INTEGER)) OR " ++
     "  (c.trigger_kind = 'durable_job_terminal' AND (c.due_epoch <= CAST(?1 AS INTEGER) OR " ++
     "     EXISTS(SELECT 1 FROM remote_node_jobs j WHERE j.job_id=c.job_id AND j.state IN ('succeeded','failed','cancelled','lost','terminal','completed','aborted'))))" ++
     ") OR (c.phase=2 AND c.reason='remote_goal' AND COALESCE(c.job_id,'')='' " ++
     "AND m.run_generation=c.run_generation AND m.status='awaiting_user' AND m.terminal_reason='remote_goal_continuation' " ++
     "AND NOT EXISTS (SELECT 1 FROM remote_node_jobs j WHERE j.mission_id=c.mission_id " ++
     "AND j.state IN ('submitting','uncertain') AND instr(j.payload_json,'\"goal_generation\":'||c.run_generation||',')>0)) " ++
     "ORDER BY CASE WHEN COALESCE(m.status,'') IN ('active','pending','waiting_background') THEN 1 ELSE 0 END ASC, " ++
     "c.due_epoch ASC, c.id ASC LIMIT 256;")
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
    -- Launch attempts already made for this wake-up (`launch_retry:N`).
    let rowErr := (cell r 8).trimAscii.toString
    let requestId := cell r 9
    let recoverClaim := cellNat r 10 == 2
    let tries := wakeupRetryCount rowErr
    let claim : WakeupClaim := ⟨cid, requestId, cGen⟩
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
            "UPDATE mission_continuations SET phase=4, error='owner_terminal', updated_at=?2 WHERE id=?1 AND phase=1 AND request_id=?3 AND run_generation=CAST(?4 AS INTEGER);"
            #[cid, nowIso, requestId, s!"{cGen}"]
        else if mr.runGeneration != cGen then
          discard <| execParamQuery store.missionsDb
            "UPDATE mission_continuations SET phase=3, error='stale_run_generation', updated_at=?2 WHERE id=?1 AND phase=1 AND request_id=?3 AND run_generation=CAST(?4 AS INTEGER);"
            #[cid, nowIso, requestId, s!"{cGen}"]
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
              "UPDATE mission_continuations SET due_epoch=CAST(?2 AS INTEGER) WHERE id=?1 AND phase=1 AND request_id=?3 AND run_generation=CAST(?4 AS INTEGER);"
              #[cid, s!"{nowSec}", requestId, s!"{cGen}"]
          match ← (if recoverClaim then pure (.ok (.ok mid))
            else actOnContinuation store cid "resume" nowIso nowSec (some (requestId, cGen))) with
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
            if tries == 0 && reason != "remote_goal" then
              emitMissionEventAndBroadcast store broadcastHub? mid "user_message"
                (renderCompact (.obj #[
                  ("type", .str "user_message"),
                  ("content", .str effPrompt),
                  ("source", .str "wakeup"),
                  ("continuation_id", .str cid)
                ])) nowIso

            let mut launchedOk := false
            let mut goalDispatchError := "remote_goal_node_missing"
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
                goalDispatch?    := if reason == "remote_goal" then some (cid, cGen) else none
                wakeupClaim?     := if reason == "remote_goal" then none else some claim
              }
              let result ← if reason == "remote_goal" && !(resumeSid?.any (resumableGoalSession mr.backend)) then pure (.error "remote_goal_session_missing")
                else submitRemoteMissionTurn store mc? relayHub? broadcastHub? sup coreWorkDir spec nowSec
              match result with
              | .ok _ =>
                launchedOk := true
                fired := fired + 1
              | .error dispErr =>
                goalDispatchError := dispErr
                emitMissionEventAndBroadcast store broadcastHub? mid "error"
                  (renderCompact (.obj #[("message", .str s!"Wakeup dispatch failed: {dispErr}")])) nowIso
            | none =>
              if let some launchLocal := (if reason == "remote_goal" then none else localFallbackLaunch?) then
                let ok ← launchLocal mr effPrompt resumeSid? claim
                if ok then
                  launchedOk := true
                  fired := fired + 1
                else
                  emitMissionEventAndBroadcast store broadcastHub? mid "error"
                    (renderCompact (.obj #[("message", .str "Wakeup launch failed")])) nowIso
              else
                let _ := warmMgr?
                pure ()

            -- Never allocate a second job after a Goal dispatch with unknown acceptance.
            if reason == "remote_goal" && !launchedOk then
              if goalDispatchError == "remote_goal_dispatch_fenced" then continue
              discard <| execParamQuery store.missionsDb
                "UPDATE mission_continuations SET phase=4,error=?2,updated_at=?3 WHERE id=?1 AND phase=2;"
                #[cid, goalDispatchError, nowIso]
              discard <| execParamQuery store.missionsDb
                "UPDATE missions SET terminal_reason='remote_goal_dispatch_blocked',state_revision=state_revision+1,updated_at=?2 WHERE id=?1 AND run_generation=CAST(?3 AS INTEGER) AND terminal_reason='remote_goal_continuation';"
                #[mid, nowIso, s!"{cGen}"]
              continue
            if reason == "remote_goal" then
              discard <| execParamQuery store.missionsDb
                "UPDATE mission_continuations SET phase=4, updated_at=?2 WHERE id=?1 AND phase=2;"
                #[cid, nowIso]

            else
              discard <| withImmediateTx store.missionsDb do
                -- A bound remote attempt is settled by the submitter or by
                -- reconciliation, never by the scheduler's transport result.
                settleWakeupClaimUnlocked store claim "" launchedOk 0 nowSec
          | _ => pure ()
      else
        discard <| execParamQuery store.missionsDb
          "UPDATE mission_continuations SET phase=4, error='mission_not_found', updated_at=?2 WHERE id=?1 AND phase=1;"
          #[cid, nowIso]
  return fired

end OrbCore.RemoteDispatch
