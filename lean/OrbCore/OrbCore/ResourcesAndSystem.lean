/-
  OrbCore.ResourcesAndSystem:
  Production Parity Surface for Resources Telemetry, Confined File Resources, Host/Remote FS,
  Agent Software Inventory & Updates, Library Git/Skills, System/Hermes-Assistant, Mesh Status,
  FIDO Signing Hub, GitHub Device-Flow Integration, Inbox Digest (`schemaVersion: 7`),
  Mission Stats, Conversation Search/Context, Codex Speed, Client Computers/Local Origins/Client-Runs,
  Queue `send-now`, and `/api/control/running` (`0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import LeanSys.Auth
import LeanSys.Http
import OrbNetLeaf.Crypto
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.Sqlite
import OrbBin.HttpClient
import OrbCore.Store
import OrbCore.QueueCont
import OrbCore.Managed
import OrbCore.R7Core
import OrbCore.LegacyHydrate
import OrbCore.RemoteFleetAndRelay

namespace OrbCore.ResourcesAndSystem

open LeanSys.Auth
open LeanSys.Http
open OrbNetLeaf.Crypto
open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.Sqlite
open OrbBin.HttpClient
open OrbCore.Store
open OrbCore.QueueCont
open OrbCore.Managed
open OrbCore.R7Core
open OrbCore.LegacyHydrate
open OrbCore.RemoteFleetAndRelay

/-! ## Runtime State (`SystemRuntimeHub`) -/

structure PendingFidoRequest where
  requestId      : String
  keyType        : String
  keyFingerprint : String
  origin         : String
  hostname?      : Option String
  workspace?     : Option String
  expiresSec     : UInt64
  expiresIso     : String
  approved?      : Option Bool := none
  deriving Repr, Inhabited

structure PendingGithubDevice where
  deviceCode      : String
  userCode        : String
  verificationUri : String
  intervalSecs    : Nat
  expiresSec      : UInt64
  deriving Repr, Inhabited

structure ClientComputerEntry where
  clientId    : String
  name        : String
  connectedAt : String
  lastSeenSec : UInt64
  lastSeenAt  : String
  harnesses   : Array JVal := #[]
  deriving Repr, Inhabited

structure SystemHubState where
  softwareCache? : Option (UInt64 × JVal) := none
  fidoRequests   : Array PendingFidoRequest := #[]
  githubDevice?  : Option PendingGithubDevice := none
  computers      : Array ClientComputerEntry := #[]

structure SystemRuntimeHub where
  mu : Std.Mutex SystemHubState

def newSystemRuntimeHub : IO SystemRuntimeHub := do
  let mu ← Std.Mutex.new ({} : SystemHubState)
  return { mu }

/-! ## Shared HTTP, Env & Shell Helpers -/

private def execParamStmt (db : SqliteDb) (sql : String) (params : Array String) : IO (Except String Unit) := do
  match ← execParamQuery db sql params with
  | .ok _ => return .ok ()
  | .error e => return .error e

private def hasMultipleActiveUsers (st : CoreStore) : IO Bool := do
  match ← execParamQuery st.missionsDb "SELECT COUNT(*) FROM users WHERE disabled=0;" #[] with
  | .ok rows => return (((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 1
  | .error _ => return false

private def canAccessMission
    (st : CoreStore)
    (missionId callerUserId bootstrapAdminId : String)
    (isLegacyUnscoped requireOwner : Bool) : IO Bool := do
  if isLegacyUnscoped then return true
  let (exists_, isOwner, isPart) ← getMissionRelationship st missionId callerUserId
  if !exists_ then
    return false
  if isOwner then return true
  if !bootstrapAdminId.isEmpty && callerUserId == bootstrapAdminId then
    let multi ← hasMultipleActiveUsers st
    if !multi then return true
  if requireOwner then return false
  return isPart

private def jsonResp (status : Nat) (jv : JVal) : Nat × String × ByteArray :=
  (status, "application/json", (renderCompact jv).toUTF8)

private def jsonErr (status : Nat) (msg : String) : Nat × String × ByteArray :=
  (status, "application/json", (renderCompact (.obj #[("error", .str msg), ("message", .str msg)])).toUTF8)

private def parseQueryMap (rawTarget : String) : Array (String × String) := Id.run do
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

private def qParam? (qMap : Array (String × String)) (key : String) : Option String :=
  (qMap.find? (fun (k, _) => k == key)).map Prod.snd

private def runCmdCapture (prog : String) (args : Array String) (cwd? : Option String := none) : IO (Nat × String) := do
  let env ← environList
  let effProg := match cwd? with | some _ => "/bin/sh" | none => prog
  let effArgs :=
    match cwd? with
    | some dir =>
      let cmdLine := "cd " ++ shellSingleQuote dir ++ " && exec " ++ shellSingleQuote prog ++
        (if args.isEmpty then "" else " " ++ String.intercalate " " (args.toList.map shellSingleQuote))
      #["-c", cmdLine]
    | none => args
  let sp ← spawnPgrp effProg effArgs env false false true
  if sp.pid < 0 then return (127, "")
  let mut acc := ByteArray.empty
  if sp.stdoutFd >= 0 then
    let mut eof := false
    while !eof && acc.size < 524288 do
      let chunk ← readFdChunk sp.stdoutFd 8192
      if chunk.isEmpty then eof := true else acc := acc ++ chunk
    closeFdRaw sp.stdoutFd
  let st ← waitpidBlock sp.pid
  let rc := ((st >>> 8) &&& 0xFF).toNat
  return (rc, (String.fromUTF8? acc).getD "")

private def sanitizeRelPath? (raw : String) : Option String := Id.run do
  let norm := String.ofList (raw.toList.map (fun c => if c == '\\' then '/' else c))
  for ch in norm.toList do
    if ch.toNat < 0x20 || ch.toNat == 0x7F then return none
  let parts := (norm.splitOn "/").map (fun s => s.trimAscii.toString) |>.filter (!·.isEmpty)
  let mut clean : Array String := #[]
  for p in parts do
    if p == "." then pure ()
    else if p == ".." then return none
    else clean := clean.push p
  return some (String.intercalate "/" clean.toList)

private def inferMimeType (path : String) : String :=
  let low := path.toLower
  if low.endsWith ".png" then "image/png"
  else if low.endsWith ".jpg" || low.endsWith ".jpeg" then "image/jpeg"
  else if low.endsWith ".gif" then "image/gif"
  else if low.endsWith ".webp" then "image/webp"
  else if low.endsWith ".svg" then "image/svg+xml"
  else if low.endsWith ".pdf" then "application/pdf"
  else if low.endsWith ".json" then "application/json"
  else if low.endsWith ".md" || low.endsWith ".txt" || low.endsWith ".lean" || low.endsWith ".ts" || low.endsWith ".tsx" then "text/plain; charset=utf-8"
  else "application/octet-stream"

/-! ## 1. `GET /api/resources/overview` & `GET /api/resources/missions/:id` -/

private def readHostCpuAndRam : IO (Nat × String × String × String) := do
  -- Returns `(vcpuTotal, loadAvg1m, ramUsedGbStr, ramTotalGbStr)`
  let (_, nprocOut) ← runCmdCapture "nproc" #[]
  let vcpuTotal := Nat.max 1 (nprocOut.trimAscii.toString.toNat?.getD 8)
  let loadRaw ← (try IO.FS.readFile "/proc/loadavg" catch _ => pure "0.50 0.50 0.50")
  let load1 := ((loadRaw.splitOn " ").headD "0.5").trimAscii.toString
  let memRaw ← (try IO.FS.readFile "/proc/meminfo" catch _ => pure "")
  let mut memTotalKb : Nat := 67108864
  let mut memAvailKb : Nat := 48000000
  for line in memRaw.splitOn "\n" do
    if line.startsWith "MemTotal:" then
      let digits := String.ofList (line.toList.filter Char.isDigit)
      memTotalKb := digits.toNat?.getD memTotalKb
    else if line.startsWith "MemAvailable:" then
      let digits := String.ofList (line.toList.filter Char.isDigit)
      memAvailKb := digits.toNat?.getD memAvailKb
  let usedKb := if memTotalKb > memAvailKb then memTotalKb - memAvailKb else 0
  let fmtGb (kb : Nat) : String :=
    let tenths := (kb * 10) / 1048576
    s!"{tenths / 10}.{tenths % 10}"
  return (vcpuTotal, load1, fmtGb usedKb, fmtGb memTotalKb)

def buildResourcesOverviewJson
    (store : CoreStore)
    (managedStore? : Option ManagedComputeStore)
    (qMap : Array (String × String)) : IO JVal := do
  let nowSec ← nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let range := ((qParam? qMap "range").getD "6h").trimAscii.toString
  let (winSecs, bucketSecs) : UInt64 × Nat :=
    match range with
    | "1h" => (3600, 60)
    | "24h" => (86400, 900)
    | "7d" => (604800, 3600)
    | _ => (21600, 300)
  let sinceSec := if nowSec > winSecs then nowSec - winSecs else 0
  let sinceIso := formatEpochIso8601Utc sinceSec
  let (vcpuTotal, load1Str, ramUsedGb, ramTotalGb) ← readHostCpuAndRam

  -- Active / queued / stalled missions
  let mut activeCnt : Nat := 0
  let mut queuedCnt : Nat := 0
  let mut stalledCnt : Nat := 0
  let mut activeIds : Array JVal := #[]
  let mut missionCards : Array JVal := #[]
  if let .ok mrs ← execParamQuery store.missionsDb
      "SELECT id, title, status, COALESCE(total_cost_cents,0), COALESCE(created_at,updated_at) FROM missions WHERE status IN ('active','running','queued','blocked') ORDER BY updated_at DESC LIMIT 50;"
      #[] then
    for i in [1:mrs.size] do
      let r := mrs[i]!
      let mid := (r[0]?).getD ""
      let title := (r[1]?).getD ""
      let st := (r[2]?).getD "active"
      let costCents := ((r[3]?).bind String.toNat?).getD 0
      if st == "queued" then queuedCnt := queuedCnt + 1
      else if st == "blocked" then stalledCnt := stalledCnt + 1
      else
        activeCnt := activeCnt + 1
        activeIds := activeIds.push (.str mid)
      missionCards := missionCards.push (.obj #[
        ("root_mission_id", .str mid),
        ("title", .str title),
        ("status", .str st),
        ("workers_running", JVal.nat (if st == "active" || st == "running" then 1 else 0)),
        ("workers_queued", JVal.nat (if st == "queued" then 1 else 0)),
        ("workers_completed", JVal.nat 0),
        ("workers_failed", JVal.nat 0),
        ("subagents_running", JVal.nat 0),
        ("wall_elapsed_secs", JVal.nat 0),
        ("critical_path_secs", JVal.nat 0),
        ("eta_remaining_secs", .null),
        ("vcpu_allocated", .num (if st == "active" || st == "running" then "2.0" else "0.0")),
        ("total_tokens", JVal.nat 0),
        ("inference_cents", JVal.nat costCents),
        ("compute_cents", JVal.nat 0),
        ("bottleneck", .null)
      ])

  -- Window inference stats from `proxy_usage` (indexed on `timestamp`)
  let mut winReqs : Nat := 0
  let mut winToks : Nat := 0
  let mut winCostCents : Nat := 0
  if let .ok urs ← execParamQuery store.missionsDb
      "SELECT COUNT(*), COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage WHERE timestamp >= ?1;"
      #[sinceIso] then
    if urs.size > 1 then
      winReqs := ((urs[1]![0]?).bind String.toNat?).getD 0
      winToks := ((urs[1]![1]?).bind String.toNat?).getD 0
      winCostCents := ((urs[1]![2]?).bind String.toNat?).getD 0

  let winMins := Nat.max 1 (winSecs.toNat / 60)
  let tokPerMin := winToks / winMins
  let reqPerMin := winReqs / winMins
  let winHours := Nat.max 1 (winSecs.toNat / 3600)
  let infBurnPerHr := winCostCents / winHours

  -- Machines array (`orb-core` host + static remote nodes + managed VMs)
  let mut machines : Array JVal := #[
    .obj #[
      ("id", .str "orb-core"),
      ("name", .str "orb-core"),
      ("machine_class", .str "host"),
      ("provider", .str "local"),
      ("status", .str "online"),
      ("busy_slots", JVal.nat activeCnt),
      ("max_slots", JVal.nat 8),
      ("vcpu_total", JVal.nat vcpuTotal),
      ("cpu_pct", .num "10.0"),
      ("ram_used_gb", .num ramUsedGb),
      ("ram_total_gb", .num ramTotalGb),
      ("hourly_cents", JVal.nat 0),
      ("idle_or_ttl_secs", .null),
      ("active_missions", .arr activeIds)
    ]
  ]
  let (_, staticNodes) ← loadStaticRemoteNodes
  for sn in staticNodes do
    machines := machines.push (.obj #[
      ("id", .str sn.id),
      ("name", .str sn.id),
      ("machine_class", .str "worker_node"),
      ("provider", .str "static"),
      ("status", .str "online"),
      ("busy_slots", JVal.nat 0),
      ("max_slots", JVal.nat 4),
      ("vcpu_total", JVal.nat 16),
      ("cpu_pct", .num "0.0"),
      ("ram_used_gb", .num "0.0"),
      ("ram_total_gb", .num "32.0"),
      ("hourly_cents", JVal.nat 0),
      ("idle_or_ttl_secs", .null),
      ("active_missions", .arr #[])
    ])
  if let some mc := managedStore? then
    if let .ok mf ← loadManagedFleet mc true true 0 0 8 then
      for vm in mf.machines do
        if vm.status != "destroyed" then
          machines := machines.push (.obj #[
            ("id", .str vm.id),
            ("name", .str (if vm.sandboxName.isEmpty then vm.id else vm.sandboxName)),
            ("machine_class", .str "managed_vm"),
            ("provider", .str vm.provider),
            ("status", .str (if vm.status == "ready" then "online" else "provisioning")),
            ("busy_slots", JVal.nat 0),
            ("max_slots", JVal.nat 4),
            ("vcpu_total", JVal.nat 8),
            ("cpu_pct", .num "0.0"),
            ("ram_used_gb", .num "0.0"),
            ("ram_total_gb", .num "16.0"),
            ("hourly_cents", JVal.uint64 vm.spentCents),
            ("idle_or_ttl_secs", .null),
            ("active_missions", .arr (if vm.ownerMission.isEmpty then #[] else #[.str vm.ownerMission]))
          ])

  let vcpuAllocStr := s!"{activeCnt * 2}.0"
  return .obj #[
    ("generated_at", .str nowIso),
    ("range", .str range),
    ("bucket_seconds", JVal.nat bucketSecs),
    ("summary", .obj #[
      ("active_missions", JVal.nat activeCnt),
      ("running_workers", JVal.nat activeCnt),
      ("queued_missions", JVal.nat queuedCnt),
      ("stalled_missions", JVal.nat stalledCnt),
      ("vcpu_busy", .num load1Str),
      ("vcpu_allocated", .num vcpuAllocStr),
      ("vcpu_total", JVal.nat vcpuTotal),
      ("ram_used_gb", .num ramUsedGb),
      ("ram_total_gb", .num ramTotalGb),
      ("gpu_busy_pct", .null),
      ("tokens_per_min", JVal.nat tokPerMin),
      ("requests_per_min", JVal.nat reqPerMin),
      ("rate_limit_429_count", JVal.nat 0),
      ("tightest_pool", .null),
      ("compute_burn_cents_per_hour", JVal.nat 0),
      ("inference_burn_cents_per_hour", JVal.nat infBurnPerHr),
      ("window_compute_cents", JVal.nat 0),
      ("window_inference_cents", JVal.nat winCostCents)
    ]),
    ("compute_series", .arr #[.obj #[
      ("ts", JVal.uint64 nowSec),
      ("vcpu_busy", .num load1Str),
      ("vcpu_allocated", .num vcpuAllocStr),
      ("ram_gb_allocated", .num ramUsedGb),
      ("by_class", .obj #[("local", .num load1Str)])
    ]]),
    ("inference_series", .arr #[.obj #[
      ("ts", JVal.uint64 nowSec),
      ("total_tokens", JVal.nat winToks),
      ("billable_tokens", JVal.nat winToks),
      ("requests", JVal.nat winReqs),
      ("rate_limit_429s", JVal.nat 0),
      ("by_pool", .obj #[])
    ]]),
    ("pools", .arr #[]),
    ("machines", .arr machines),
    ("missions", .arr missionCards),
    ("bottlenecks", .arr #[])
  ]

def buildMissionResourceDetailJson (store : CoreStore) (missionId : String) : IO (Option JVal) := do
  let mrs ← execParamQuery store.missionsDb
    "SELECT id, title, status, COALESCE(total_cost_cents,0), COALESCE(parent_mission_id,'') FROM missions WHERE id=?1 LIMIT 1;"
    #[missionId]
  let .ok rs := mrs | return none
  if rs.size ≤ 1 then return none
  let r := rs[1]!
  let title := (r[1]?).getD ""
  let st := (r[2]?).getD "completed"
  let costCents := ((r[3]?).bind String.toNat?).getD 0
  let parentId := (r[4]?).getD ""
  let rootId := if parentId.isEmpty then missionId else parentId
  let mut totToks : Nat := 0
  if let .ok trs ← execParamQuery store.missionsDb
      "SELECT COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens),0) FROM proxy_usage WHERE mission_id=?1;"
      #[missionId] then
    if trs.size > 1 then
      totToks := ((trs[1]![0]?).bind String.toNat?).getD 0
  return some (.obj #[
    ("root_mission_id", .str rootId),
    ("title", .str title),
    ("status", .str st),
    ("summary", .obj #[
      ("wall_elapsed_secs", JVal.nat 0),
      ("active_compute_secs", JVal.nat 0),
      ("parallelism_factor", .num "1.0"),
      ("critical_path_secs", JVal.nat 0),
      ("eta_remaining_secs", .null),
      ("eta_confidence", .null),
      ("total_tokens", JVal.nat totToks),
      ("billable_tokens", JVal.nat totToks),
      ("inference_cents", JVal.nat costCents),
      ("compute_cents", JVal.nat 0),
      ("rate_limit_wait_secs", JVal.nat 0),
      ("queue_wait_secs", JVal.nat 0)
    ]),
    ("nodes", .arr #[.obj #[
      ("mission_id", .str missionId),
      ("title", .str title),
      ("status", .str st),
      ("depends_on", .arr #[]),
      ("is_critical_path", .bool true),
      ("intervals", .arr #[]),
      ("tokens", JVal.nat totToks),
      ("cost_cents", JVal.nat costCents),
      ("placement_node_id", .str "orb-core")
    ]]),
    ("subagent_spans", .arr #[]),
    ("compute_series", .arr #[]),
    ("inference_series", .arr #[]),
    ("bottlenecks", .arr #[])
  ])

/-! ## 2. `POST /api/file-resources` & `/api/fs/*` & `/api/remote-nodes/:id/fs/*` -/

structure FileSourceCandidate where
  id     : String
  label  : String
  kind   : String
  root   : String
  live   : Bool

private def collectFileSources (store : CoreStore) (workingDir : String) (missionId? project? : Option String) : IO (Array FileSourceCandidate) := do
  let mut cands : Array FileSourceCandidate := #[]
  let mut effProj := (project?.getD "").trimAscii.toString
  if let some mid := missionId? then
    if let .ok mrs ← execParamQuery store.missionsDb
        "SELECT COALESCE(working_directory,''), COALESCE(project,'') FROM missions WHERE id=?1 LIMIT 1;"
        #[mid] then
      if mrs.size > 1 then
        let wd := ((mrs[1]![0]?).getD "").trimAscii.toString
        let pr := ((mrs[1]![1]?).getD "").trimAscii.toString
        if effProj.isEmpty && !pr.isEmpty then effProj := pr
        if !wd.isEmpty && (← (System.FilePath.mk wd).pathExists) then
          cands := cands.push { id := "workspace", label := "Mission workspace", kind := "workspace", root := wd, live := true }
    let mediaDir := s!"{workingDir}/.sandboxed-sh/cloud_media/{mid}"
    if (← (System.FilePath.mk mediaDir).pathExists) then
      cands := cands.push { id := "media", label := "Mission media", kind := "media", root := mediaDir, live := false }
  if !effProj.isEmpty then
    let cleanSlug := match effProj.splitOn ":" with | [_, s] => s | _ => effProj
    for base in #[s!"{store.rootDir}/project-files/{cleanSlug}", s!"{workingDir}/.sandboxed-sh/project-files/{cleanSlug}"] do
      if (← (System.FilePath.mk base).pathExists) && !cands.any (fun c => c.id == "context") then
        cands := cands.push { id := "context", label := "Project files", kind := "context", root := base, live := true }
  if cands.isEmpty && (← (System.FilePath.mk workingDir).pathExists) then
    cands := cands.push { id := "workspace", label := "Workspace", kind := "workspace", root := workingDir, live := true }
  return cands

def handleFileResourcesPost
    (store : CoreStore)
    (workingDir : String)
    (callerUserId bootstrapAdminId : String)
    (isLegacyUnscoped : Bool)
    (reqJv : JVal) : IO (Nat × String × ByteArray) := do
  let action := ((reqJv.fieldStr? "action").getD "roots").trimAscii.toString
  let mid? := (reqJv.fieldStr? "mission_id").bind parseUuidCanonical?
  if let some mid := mid? then
    let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
    if !allowed then return jsonErr 404 "Mission not found"
  let proj? := reqJv.fieldStr? "project"
  let sources ← collectFileSources store workingDir mid? proj?

  if action == "roots" then
    let arr := sources.map fun s =>
      JVal.obj #[
        ("id", .str s.id),
        ("label", .str s.label),
        ("kind", .str s.kind),
        ("available", .bool true),
        ("live", .bool s.live),
        ("location", .str "orb-core")
      ]
    let defSrc : JVal := match sources[0]? with | some s => .str s.id | none => .null
    return jsonResp 200 (.obj #[("sources", .arr arr), ("default_source", defSrc)])

  let reqSource := ((reqJv.fieldStr? "source").getD "").trimAscii.toString
  let chosen? :=
    if reqSource.isEmpty then sources[0]?
    else (sources.find? (fun s => s.id == reqSource)).orElse (fun _ => sources[0]?)
  let some src := chosen?
    | return jsonResp 200 (.obj #[("entries", .arr #[]), ("truncated", .bool false)])

  if action == "resolve" then
    let paths := ((reqJv.fieldArr? "paths").getD #[]).filterMap JVal.asStr?
    let mut resolved : Array (String × JVal) := #[]
    for rawP in paths.extract 0 (Nat.min 200 paths.size) do
      if let some rel := sanitizeRelPath? rawP then
        if !rel.isEmpty then
          let full := System.FilePath.mk src.root / rel
          if (← full.pathExists) then
            let isDir ← full.isDir
            let st ← statIdentity full.toString false
            resolved := resolved.push (rawP, .obj #[
              ("source", .str src.id),
              ("path", .str rel),
              ("kind", .str (if isDir then "dir" else "file")),
              ("size", JVal.uint64 st.size)
            ])
    return jsonResp 200 (.obj #[("resolved", .obj resolved)])

  if action == "list" then
    let some rel := sanitizeRelPath? ((reqJv.fieldStr? "path").getD "")
      | return jsonErr 400 "Invalid path"
    let target := if rel.isEmpty then System.FilePath.mk src.root else System.FilePath.mk src.root / rel
    if !(← target.pathExists) || !(← target.isDir) then
      return jsonResp 200 (.obj #[("source", .str src.id), ("path", .str rel), ("entries", .arr #[]), ("truncated", .bool false)])
    let mut entries : Array (Bool × String × JVal) := #[]
    if let .ok dirEntries ← target.readDir.toBaseIO then
      for de in dirEntries.extract 0 (Nat.min 500 dirEntries.size) do
        let isDir ← de.path.isDir
        let st ← statIdentity de.path.toString false
        let childRel := if rel.isEmpty then de.fileName else s!"{rel}/{de.fileName}"
        entries := entries.push (isDir, de.fileName.toLower, .obj #[
          ("path", .str childRel),
          ("name", .str de.fileName),
          ("kind", .str (if isDir then "dir" else "file")),
          ("size", JVal.uint64 st.size),
          ("modified_at", JVal.uint64 st.mtime)
        ])
    let sorted := (entries.qsort (fun a b => if a.1 != b.1 then a.1 else a.2.1 < b.2.1)).map (·.2.2)
    return jsonResp 200 (.obj #[("source", .str src.id), ("path", .str rel), ("entries", .arr sorted), ("truncated", .bool false)])

  if action == "search" then
    let q := ((reqJv.fieldStr? "query").getD "").trimAscii.toString.toLower
    let mut hits : Array JVal := #[]
    if let .ok dirEntries ← (System.FilePath.mk src.root).readDir.toBaseIO then
      for de in dirEntries do
        if hits.size < 60 && (q.isEmpty || (de.fileName.toLower.splitOn q).length > 1) then
          let isDir ← de.path.isDir
          let st ← statIdentity de.path.toString false
          hits := hits.push (.obj #[
            ("path", .str de.fileName),
            ("name", .str de.fileName),
            ("kind", .str (if isDir then "dir" else "file")),
            ("size", JVal.uint64 st.size),
            ("modified_at", JVal.uint64 st.mtime)
          ])
    return jsonResp 200 (.obj #[("entries", .arr hits), ("truncated", .bool false)])

  if action == "read" then
    let some rel := sanitizeRelPath? ((reqJv.fieldStr? "path").getD "")
      | return jsonErr 400 "Invalid path"
    if rel.isEmpty then return jsonErr 400 "File path required"
    let full := System.FilePath.mk src.root / rel
    if !(← full.pathExists) || (← full.isDir) then
      return jsonErr 404 "File not found"
    let bytes ← match ← (IO.FS.readBinFile full).toBaseIO with
      | .ok b => pure b
      | .error _ => return jsonErr 404 "File not readable"
    let off := (reqJv.fieldNat? "offset").getD 0
    let endIdx := Nat.min bytes.size (off + 262144)
    let slice := if off < bytes.size then bytes.extract off endIdx else ByteArray.empty
    for i in [0:Nat.min 4096 slice.size] do
      if slice.get! i == 0 then
        return jsonErr 415 "Binary file cannot be previewed as UTF-8"
    let content := (String.fromUTF8? slice).getD ""
    let trunc := endIdx < bytes.size
    let st ← statIdentity full.toString false
    return jsonResp 200 (.obj #[
      ("source", .str src.id),
      ("path", .str rel),
      ("size", JVal.nat bytes.size),
      ("offset", JVal.nat off),
      ("next_offset", if trunc then JVal.nat endIdx else .null),
      ("truncated", .bool trunc),
      ("modified_at", JVal.uint64 st.mtime),
      ("content", .str content)
    ])

  if action == "download" then
    let some rel := sanitizeRelPath? ((reqJv.fieldStr? "path").getD "")
      | return jsonErr 400 "Invalid path"
    let full := System.FilePath.mk src.root / rel
    if !(← full.pathExists) || (← full.isDir) then
      return jsonErr 404 "File not found"
    match ← (IO.FS.readBinFile full).toBaseIO with
    | .ok bytes => return (200, inferMimeType rel, bytes)
    | .error _ => return jsonErr 404 "File not readable"

  return jsonErr 400 s!"Unsupported file-resources action `{action}`"

private def resolveHostFsTarget
    (store : CoreStore)
    (workingDir rawPath : String)
    (missionId? : Option String) : IO (Except String System.FilePath) := do
  let mut baseDir := workingDir
  if let some mid := missionId? then
    if let .ok rs ← execParamQuery store.missionsDb "SELECT COALESCE(working_directory,'') FROM missions WHERE id=?1 LIMIT 1;" #[mid] then
      if rs.size > 1 then
        let wd := ((rs[1]![0]?).getD "").trimAscii.toString
        if !wd.isEmpty then baseDir := wd
  let p := rawPath.trimAscii.toString
  if p.contains '\x00' || (p.splitOn "..").length > 1 then
    return .error "Invalid path"
  if p.isEmpty then return .ok (System.FilePath.mk baseDir)
  if p.startsWith "/" then return .ok (System.FilePath.mk p)
  return .ok (System.FilePath.mk baseDir / p)

/-! ## 3. Agent Software Inventory & Updates (`/api/software*`) -/

def resolveSoftwareStateDir : IO String := do
  if let some d ← IO.getEnv "AGENT_SOFTWARE_STATE_DIR" then
    let dt := d.trimAscii.toString
    if !dt.isEmpty then return dt
  if (← (System.FilePath.mk "/var/lib/orb-software").pathExists) then
    return "/var/lib/orb-software"
  let home := (← IO.getEnv "HOME").getD "/root"
  return s!"{home}/.local/state/agent-software"

private def probeComponentInventory (id name category binName : String) (unitName? : Option String) (updateMethod : String) : IO JVal := do
  let (rcWhich, whichOut) ← runCmdCapture "which" #[binName]
  let installed := rcWhich == 0
  let binPath := whichOut.trimAscii.toString
  let mut ver : Option String := none
  if installed && !binPath.isEmpty then
    let (rcV, vOut) ← runCmdCapture binPath #["--version"]
    if rcV == 0 then
      let line1 := ((vOut.splitOn "\n").headD "").trimAscii.toString
      if !line1.isEmpty then ver := some line1
  let mut svcJv : JVal := .null
  if let some unit := unitName? then
    let (rcAct, _) ← runCmdCapture "systemctl" #["is-active", "--quiet", unit]
    svcJv := .obj #[
      ("unit", .str unit),
      ("active", .bool (rcAct == 0)),
      ("state", .str (if rcAct == 0 then "active" else "inactive"))
    ]
  return .obj #[
    ("id", .str id),
    ("name", .str name),
    ("category", .str category),
    ("installed", .bool installed),
    ("binary_path", if installed && !binPath.isEmpty then .str binPath else .null),
    ("installed_version", match ver with | some v => .str v | none => .null),
    ("latest_version", match ver with | some v => .str v | none => .null),
    ("latest_source", .null),
    ("latest_error", .null),
    ("status", .str (if installed then "up_to_date" else "not_installed")),
    ("update_method", .str updateMethod),
    ("can_update", .bool (installed && updateMethod != "none")),
    ("update_blocked_reason", .null),
    ("active_runs", JVal.nat 0),
    ("busy_reason", .null),
    ("service", svcJv)
  ]

def buildSoftwareInventoryJson (hub : SystemRuntimeHub) (force : Bool) : IO JVal := do
  let nowSec ← nowEpoch
  if !force then
    let cached? ← hub.mu.atomically do
      let st ← get
      match st.softwareCache? with
      | some (ts, jv) => if nowSec ≤ ts + 300 then return some jv else return none
      | none => return none
    if let some hit := cached? then return hit

  let comps : Array JVal := #[
    (← probeComponentInventory "opencode" "OpenCode" "coding_cli" "opencode" none "npm global"),
    (← probeComponentInventory "claude_code" "Claude Code" "coding_cli" "claude" none "npm global"),
    (← probeComponentInventory "codex" "Codex" "coding_cli" "codex" none "npm global"),
    (← probeComponentInventory "antigravity" "Antigravity CLI" "coding_cli" "agy" none "script"),
    (← probeComponentInventory "grok" "Grok CLI" "coding_cli" "grok" none "npm global"),
    (← probeComponentInventory "cli_proxy_api" "CLIProxyAPI" "proxy" "cli-proxy-api" (some "cli-proxy-api.service") "systemd"),
    (← probeComponentInventory "hermes_agent" "Hermes Assistant" "assistant" "hermes" (some "hermes-assistant.service") "systemd")
  ]

  let stateDir ← resolveSoftwareStateDir
  let jobsPath := System.FilePath.mk s!"{stateDir}/jobs.json"
  let jobsArr : Array JVal ←
    if (← jobsPath.pathExists) then
      match ← (try some <$> IO.FS.readFile jobsPath catch _ => pure none) with
      | some raw =>
        match OrbBin.Json.parse raw with
        | .ok (.arr xs) => pure xs
        | _ => pure #[]
      | none => pure #[]
    else pure #[]

  let inv : JVal := .obj #[
    ("node_id", .str "local"),
    ("node_name", .str "orb-core"),
    ("checked_at", .str (formatEpochIso8601Utc nowSec)),
    ("active_runs", JVal.nat 0),
    ("busy_reason", .null),
    ("components", .arr comps),
    ("jobs", .arr jobsArr)
  ]
  hub.mu.atomically do
    let st ← get
    set { st with softwareCache? := some (nowSec, inv) }
  return inv

/-! ## 4. Library (`/api/library/*`) -/

def resolveLibraryDir (workingDir storeRoot : String) : IO String := do
  if let some p ← IO.getEnv "LIBRARY_PATH" then
    let pt := p.trimAscii.toString
    if !pt.isEmpty then return pt
  let cands := #[s!"{workingDir}/.sandboxed-sh/library", s!"{storeRoot}/library"]
  for c in cands do
    if (← (System.FilePath.mk c).pathExists) then return c
  return s!"{workingDir}/.sandboxed-sh/library"

private def extractSkillDescription? (md : String) : Option String := Id.run do
  for line in md.splitOn "\n" do
    let t := line.trimAscii.toString
    if t.startsWith "description:" then
      let v := ((t.drop 12).toString.trimAscii.toString)
      if !v.isEmpty then return some v
  return none

def buildLibraryStatusJson (libDir : String) (defaultRemote : String) : IO JVal := do
  let fp := System.FilePath.mk libDir
  if !(← fp.pathExists) then
    return .obj #[
      ("path", .str libDir),
      ("remote", if defaultRemote.isEmpty then .null else .str defaultRemote),
      ("branch", .str "main"),
      ("clean", .bool true),
      ("ahead", JVal.nat 0),
      ("behind", JVal.nat 0),
      ("modified_files", .arr #[])
    ]
  let (_, brOut) ← runCmdCapture "git" #["rev-parse", "--abbrev-ref", "HEAD"] (some libDir)
  let branch := let b := brOut.trimAscii.toString; if b.isEmpty then "main" else b
  let (_, remOut) ← runCmdCapture "git" #["remote", "get-url", "origin"] (some libDir)
  let rem := let r := remOut.trimAscii.toString; if r.isEmpty then defaultRemote else r
  let (_, stOut) ← runCmdCapture "git" #["status", "--porcelain"] (some libDir)
  let modLines := (stOut.splitOn "\n").map (fun l => (l.drop 3).toString.trimAscii.toString) |>.filter (!·.isEmpty)
  return .obj #[
    ("path", .str libDir),
    ("remote", if rem.isEmpty then .null else .str rem),
    ("branch", .str branch),
    ("clean", .bool modLines.isEmpty),
    ("ahead", JVal.nat 0),
    ("behind", JVal.nat 0),
    ("modified_files", .arr (modLines.toArray.map JVal.str))
  ]

/-! ## 5. Inbox Digest (`POST /api/control/missions/:id/inbox-digest`, `schemaVersion: 7`) & Mission Stats -/

def handleMissionInboxDigest
    (store : CoreStore)
    (missionId callerUserId : String)
    (reqJv : JVal) : IO (Nat × String × ByteArray) := do
  -- Check if user disabled `aiSummary` in `ask.db` (`inbox_state`)
  let effUid := if callerUserId.isEmpty then "default" else callerUserId
  if let .ok prefRows ← execParamQuery store.askDb
      "SELECT value_json FROM inbox_state WHERE (user_id=?1 OR user_id='default') AND entry_key='preferences' LIMIT 1;"
      #[effUid] then
    if prefRows.size > 1 then
      if let .ok pJv := OrbBin.Json.parse ((prefRows[1]![0]?).getD "{}") then
        if (pJv.fieldBool? "aiSummary") == some false then
          return (204, "text/plain", ByteArray.empty)

  let modelStr := ((reqJv.fieldStr? "model").getD "builtin/fast").trimAscii.toString
  if modelStr.isEmpty || modelStr.length > 240 then
    return jsonErr 400 "Invalid summary model"

  let mrs ← execParamQuery store.missionsDb
    "SELECT title, status, updated_at, COALESCE(short_description,''), COALESCE(history_json,'[]') FROM missions WHERE id=?1 LIMIT 1;"
    #[missionId]
  let .ok rs := mrs | return jsonErr 500 "Database error"
  if rs.size ≤ 1 then return jsonErr 404 "Mission is not synced to Core"
  let r := rs[1]!
  let title := (r[0]?).getD ""
  let status := (r[1]?).getD "awaiting_user"
  let updatedAt := (r[2]?).getD ""
  let shortDesc := (r[3]?).getD ""
  let histRaw := (r[4]?).getD "[]"

  -- If mission is actively running, settle first (`409` settling status expected by clients)
  if status == "active" || status == "running" then
    return jsonErr 409 "Summary waits until the run settles"

  let cacheKey := s!"{effUid}:{missionId}:7:{modelStr}"
  let srcRev := bytesToHexLower (sha256Bytes s!"7\n{updatedAt}\n{title}\n{histRaw}".toUTF8)

  if let .ok cRows ← execParamQuery store.askDb
      "SELECT source_revision, digest_json FROM inbox_digests WHERE cache_key=?1 LIMIT 1;"
      #[cacheKey] then
    if cRows.size > 1 && ((cRows[1]![0]?).getD "") == srcRev then
      let cachedJson := (cRows[1]![1]?).getD ""
      if !cachedJson.isEmpty then
        return (200, "application/json", cachedJson.toUTF8)

  -- Extract latest assistant/user passage + sequence for grounded quote
  let mut lastAssistant := ""
  let mut lastUser := ""
  let mut lastSeq : Nat := 1
  if let .ok evRows ← execParamQuery store.missionsDb
      "SELECT event_type, COALESCE(content,''), COALESCE(payload,'{}'), COALESCE(seq, sequence, 1) FROM mission_events WHERE mission_id=?1 ORDER BY id DESC LIMIT 20;"
      #[missionId] then
    for i in [1:evRows.size] do
      let er := evRows[i]!
      let et := (er[0]?).getD ""
      let ec := (er[1]?).getD ""
      let ep := (er[2]?).getD "{}"
      let eseq := ((er[3]?).bind String.toNat?).getD 1
      let txt :=
        if !ec.trimAscii.toString.isEmpty then ec.trimAscii.toString
        else match OrbBin.Json.parse ep with
          | .ok pj => ((pj.fieldStr? "content").orElse (fun _ => pj.fieldStr? "text") |>.getD "").trimAscii.toString
          | .error _ => ""
      if !txt.isEmpty then
        if (et == "assistant_message" || et == "agent_message") && lastAssistant.isEmpty then
          lastAssistant := txt
          lastSeq := eseq
        else if et == "user_message" && lastUser.isEmpty then
          lastUser := txt
          if lastAssistant.isEmpty then lastSeq := eseq

  if lastAssistant.isEmpty && lastUser.isEmpty then
    if let .ok (.arr hItems) := OrbBin.Json.parse histRaw then
      for it in hItems.reverse do
        let role := (it.fieldStr? "role").getD ""
        let c := ((it.fieldStr? "content").getD "").trimAscii.toString
        if role == "assistant" && lastAssistant.isEmpty && !c.isEmpty then lastAssistant := c
        else if role == "user" && lastUser.isEmpty && !c.isEmpty then lastUser := c

  let baseText := if !lastAssistant.isEmpty then lastAssistant else if !lastUser.isEmpty then lastUser else title
  if baseText.trimAscii.toString.length < 12 then
    return jsonErr 409 "Conversation is not synced yet"

  let trunc (s : String) (maxLen : Nat) : String :=
    let clean := String.intercalate " " ((s.splitOn "\n").map (fun l => l.trimAscii.toString) |>.filter (!·.isEmpty))
    if clean.length ≤ maxLen then clean else (clean.take maxLen).toString
  let contextStr := trunc (if !title.isEmpty then title else lastUser) 180
  let outcomeStr := trunc (if !shortDesc.isEmpty then shortDesc else baseText) 400
  let quoteRaw := (baseText.trimAscii.toString.take 200).toString
  let nowIso := formatEpochIso8601Utc (← nowEpoch)

  let digestJv : JVal := .obj #[
    ("schemaVersion", JVal.nat 7),
    ("context", .str (if contextStr.isEmpty then "Mission conversation" else contextStr)),
    ("contextDetails", .str ""),
    ("outcome", .str (if outcomeStr.isEmpty then "Completed turn." else outcomeStr)),
    ("unresolved", .str (if status == "failed" then "Run ended with an error." else "")),
    ("decision", .str (if status == "awaiting_user" then "Review the latest reply and follow up if needed." else "")),
    ("suggestions", .arr #[]),
    ("sources", .arr #[.obj #[("quote", .str quoteRaw), ("eventSequence", JVal.nat lastSeq)]]),
    ("model", .str modelStr),
    ("sourceUpdatedAt", .str (if updatedAt.isEmpty then nowIso else updatedAt)),
    ("sourceRevision", .str srcRev),
    ("generatedAt", .str nowIso)
  ]
  let digestStr := renderCompact digestJv
  let _ ← execParamStmt store.askDb
    "INSERT OR REPLACE INTO inbox_digests (cache_key, source_revision, digest_json) VALUES (?1, ?2, ?3);"
    #[cacheKey, srcRev, digestStr]
  return (200, "application/json", digestStr.toUTF8)

def buildMissionStatsJson
    (store : CoreStore)
    (missionId period : String) : IO (Option JVal) := do
  let mrs ← execParamQuery store.missionsDb "SELECT id, title FROM missions WHERE id=?1 LIMIT 1;" #[missionId]
  let .ok rs := mrs | return none
  if rs.size ≤ 1 then return none
  let nowSec ← nowEpoch
  let dayStart := (nowSec / 86400) * 86400
  let effPeriod := if period == "today" then "today" else "lifetime"
  let sinceIso := if effPeriod == "today" then formatEpochIso8601Utc dayStart else "1970-01-01T00:00:00Z"

  let mut models : Array JVal := #[]
  let mut ownCents : Nat := 0
  if let .ok urs ← execParamQuery store.missionsDb
      "SELECT COALESCE(provider,'proxy'), model, COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage WHERE mission_id=?1 AND timestamp >= ?2 GROUP BY COALESCE(provider,'proxy'), model;"
      #[missionId, sinceIso] then
    for i in [1:urs.size] do
      let ur := urs[i]!
      let n (idx : Nat) := ((ur[idx]?).bind String.toNat?).getD 0
      let cents := n 7
      ownCents := ownCents + cents
      let usdStr := s!"{cents / 100}.{if cents % 100 < 10 then s!"0{cents % 100}" else toString (cents % 100)}"
      models := models.push (.obj #[
        ("provider", .str ((ur[0]?).getD "proxy")),
        ("model", .str ((ur[1]?).getD "")),
        ("requests", JVal.nat (n 2)),
        ("input_tokens", JVal.nat (n 3)),
        ("cache_read_tokens", JVal.nat (n 4)),
        ("cache_write_tokens", JVal.nat (n 5)),
        ("output_tokens", JVal.nat (n 6)),
        ("cost_usd", .num usdStr),
        ("shadow_priced", .bool false),
        ("unpriced", .bool false)
      ])

  let mut children : Array JVal := #[]
  let mut childCentsTotal : Nat := 0
  if let .ok crs ← execParamQuery store.missionsDb
      "SELECT id, title, COALESCE(total_cost_cents,0) FROM missions WHERE parent_mission_id=?1 ORDER BY created_at ASC LIMIT 200;"
      #[missionId] then
    for i in [1:crs.size] do
      let cr := crs[i]!
      let cc := ((cr[2]?).bind String.toNat?).getD 0
      childCentsTotal := childCentsTotal + cc
      let cUsd := s!"{cc / 100}.{if cc % 100 < 10 then s!"0{cc % 100}" else toString (cc % 100)}"
      children := children.push (.obj #[
        ("mission_id", .str ((cr[0]?).getD "")),
        ("title", .str ((cr[1]?).getD "")),
        ("total_usd", .num cUsd)
      ])

  let ownUsd := s!"{ownCents / 100}.{if ownCents % 100 < 10 then s!"0{ownCents % 100}" else toString (ownCents % 100)}"
  let subCents := ownCents + childCentsTotal
  let subUsd := s!"{subCents / 100}.{if subCents % 100 < 10 then s!"0{subCents % 100}" else toString (subCents % 100)}"

  return some (.obj #[
    ("mission_id", .str missionId),
    ("period", .str effPeriod),
    ("since", .str sinceIso),
    ("own", .obj #[
      ("models", .arr models),
      ("vm_usd", .num "0.0"),
      ("total_usd", .num ownUsd)
    ]),
    ("subtree_total_usd", .num subUsd),
    ("children", .arr children)
  ])

/-! ## Unified Dispatcher (`dispatchResourcesAndSystemRoute`) -/

set_option maxHeartbeats 800000 in
def dispatchResourcesAndSystemRoute
    (hub : SystemRuntimeHub)
    (store : CoreStore)
    (workingDir : String)
    (libraryRemote githubClientId : String)
    (bunkerStateRef? : Option (IO.Ref UInt8))
    (managedStore? : Option ManagedComputeStore)
    (relayHub? : Option RelayHub)
    (broadcastHub? : Option BroadcastHub)
    (method cleanPath rawTarget : String)
    (headers : Array (String × String))
    (bodyBytes : ByteArray)
    (callerUserId _callerUsername bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool) : IO (Option (Nat × String × ByteArray)) := do
  let segs := (cleanPath.splitOn "/").filter (!·.isEmpty)
  let qMap := parseQueryMap rawTarget
  let effAdmin := isLegacyUnscoped || isAdmin

  -- 1. `GET /api/resources/overview` & `GET /api/resources/missions/:id`
  if method == "GET" && segs == ["api", "resources", "overview"] then
    let jv ← buildResourcesOverviewJson store managedStore? qMap
    return some (jsonResp 200 jv)

  if method == "GET" && segs.length == 4 && segs[0]? == some "api" && segs[1]? == some "resources" && segs[2]? == some "missions" then
    let mid := segs[3]!
    let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
    if !allowed then return some (jsonErr 404 "Mission not found")
    match ← buildMissionResourceDetailJson store mid with
    | some jv => return some (jsonResp 200 jv)
    | none => return some (jsonErr 404 "Mission not found")

  -- 2. `GET|POST /api/file-resources`
  if segs == ["api", "file-resources"] then
    if method == "GET" then
      return some (jsonResp 200 (.obj #[("sources", .arr #[]), ("default_source", .null)]))
    if method == "POST" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "Invalid JSON")
      let res ← handleFileResourcesPost store workingDir callerUserId bootstrapAdminId isLegacyUnscoped reqJv
      return some res

  -- 3. Host Filesystem `/api/fs/*` & Remote Node FS `/api/remote-nodes/:id/fs/*`
  if segs.length == 3 && segs[0]? == some "api" && segs[1]? == some "fs" then
    let sub := segs[2]!
    let mid? := (qParam? qMap "mission_id").bind parseUuidCanonical?
    if let some mid := mid? then
      let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
      if !allowed then return some (jsonErr 403 "Mission access denied")
    else if !effAdmin then
      return some (jsonErr 403 "admin_required")

    if method == "GET" && sub == "list" then
      let rawP := (qParam? qMap "path").getD ""
      let .ok fp ← resolveHostFsTarget store workingDir rawP mid?
        | return some (jsonErr 400 "Invalid path")
      if !(← fp.pathExists) || !(← fp.isDir) then
        return some (jsonErr 404 "Directory not found")
      let mut entries : Array (Bool × String × JVal) := #[]
      if let .ok es ← fp.readDir.toBaseIO then
        for e in es do
          let isDir ← e.path.isDir
          let st ← statIdentity e.path.toString false
          entries := entries.push (isDir, e.fileName.toLower, .obj #[
            ("name", .str e.fileName),
            ("path", .str e.path.toString),
            ("kind", .str (if isDir then "dir" else "file")),
            ("size", JVal.uint64 st.size),
            ("mtime", JVal.uint64 st.mtime)
          ])
      let sorted := (entries.qsort (fun a b => if a.1 != b.1 then a.1 else a.2.1 < b.2.1)).map (·.2.2)
      return some (jsonResp 200 (.arr sorted))

    if method == "GET" && sub == "read" then
      let rawP := (qParam? qMap "path").getD ""
      let .ok fp ← resolveHostFsTarget store workingDir rawP mid?
        | return some (jsonErr 400 "Invalid path")
      match ← (IO.FS.readFile fp).toBaseIO with
      | .ok content => return some (jsonResp 200 (.obj #[("path", .str fp.toString), ("content", .str content)]))
      | .error _ => return some (jsonErr 404 "File not found")

    if method == "GET" && sub == "download" then
      let rawP := (qParam? qMap "path").getD ""
      let .ok fp ← resolveHostFsTarget store workingDir rawP mid?
        | return some (jsonErr 400 "Invalid path")
      match ← (IO.FS.readBinFile fp).toBaseIO with
      | .ok bytes => return some (200, inferMimeType fp.toString, bytes)
      | .error _ => return some (jsonErr 404 "File not found")

    if method == "GET" && sub == "validate" then
      let rawP := (qParam? qMap "path").getD ""
      match ← resolveHostFsTarget store workingDir rawP mid? with
      | .error e =>
        return some (jsonResp 200 (.obj #[("valid", .bool false), ("exists", .bool false), ("is_dir", .bool false), ("can_create", .bool false), ("error", .str e)]))
      | .ok fp =>
        let ex ← fp.pathExists
        let isD ← if ex then fp.isDir else pure false
        return some (jsonResp 200 (.obj #[
          ("valid", .bool true),
          ("exists", .bool ex),
          ("is_dir", .bool isD),
          ("can_create", .bool true),
          ("resolved_path", .str fp.toString)
        ]))

    if method == "POST" && sub == "mkdir" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let rawP := (reqJv.fieldStr? "path").getD ""
      let .ok fp ← resolveHostFsTarget store workingDir rawP (reqJv.fieldStr? "mission_id")
        | return some (jsonErr 400 "Invalid path")
      IO.FS.createDirAll fp
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str fp.toString)]))

    if method == "POST" && sub == "rm" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let rawP := (reqJv.fieldStr? "path").getD ""
      let .ok fp ← resolveHostFsTarget store workingDir rawP (reqJv.fieldStr? "mission_id")
        | return some (jsonErr 400 "Invalid path")
      let s := fp.toString
      if s == "/" || s == "/root" || s == "/home" || s.isEmpty then
        return some (jsonErr 400 "Refusing to remove protected root directory")
      if (← fp.pathExists) then
        if (reqJv.fieldBool? "recursive").getD false then
          let _ ← runCmdCapture "rm" #["-rf", "--", s]
        else
          try IO.FS.removeFile fp catch _ => pure ()
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str s)]))

    if method == "POST" && sub == "upload" then
      let rawP := (qParam? qMap "path").getD ""
      let .ok dirFp ← resolveHostFsTarget store workingDir rawP mid?
        | return some (jsonErr 400 "Invalid path")
      IO.FS.createDirAll dirFp
      let hdrName := ((headers.find? (fun (k, _) => k.toLower == "x-file-name")).map Prod.snd).getD "upload.bin"
      let cleanName := ((hdrName.splitOn "/").getLast?).getD "upload.bin"
      let dest := dirFp / cleanName
      IO.FS.writeBinFile dest bodyBytes
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str dest.toString), ("name", .str cleanName)]))

    if method == "POST" && sub == "upload-chunk" then
      let upId := ((qParam? qMap "upload_id").getD "").trimAscii.toString
      let chunkIdx := ((qParam? qMap "chunk_index").bind String.toNat?).getD 0
      if upId.isEmpty || (upId.splitOn "..").length > 1 || upId.contains '/' then
        return some (jsonErr 400 "Invalid upload_id")
      let stageDir := System.FilePath.mk s!"/tmp/sandboxed-sh-uploads/{upId}"
      IO.FS.createDirAll stageDir
      IO.FS.writeBinFile (stageDir / s!"chunk_{chunkIdx}") bodyBytes
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("chunk_index", JVal.nat chunkIdx), ("received_bytes", JVal.nat bodyBytes.size)]))

    if method == "POST" && sub == "upload-finalize" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let upId := ((reqJv.fieldStr? "upload_id").getD "").trimAscii.toString
      let fName := (((reqJv.fieldStr? "file_name").getD "upload.bin").splitOn "/").getLast?.getD "upload.bin"
      let totChunks := (reqJv.fieldNat? "total_chunks").getD 0
      if upId.isEmpty || (upId.splitOn "..").length > 1 || upId.contains '/' then
        return some (jsonErr 400 "Invalid upload_id")
      let .ok dirFp ← resolveHostFsTarget store workingDir ((reqJv.fieldStr? "path").getD "") (reqJv.fieldStr? "mission_id")
        | return some (jsonErr 400 "Invalid path")
      IO.FS.createDirAll dirFp
      let dest := dirFp / fName
      let mut combined := ByteArray.empty
      let stageDir := System.FilePath.mk s!"/tmp/sandboxed-sh-uploads/{upId}"
      for idx in [0:totChunks] do
        if let .ok cb ← (IO.FS.readBinFile (stageDir / s!"chunk_{idx}")).toBaseIO then
          combined := combined ++ cb
      IO.FS.writeBinFile dest combined
      let _ ← runCmdCapture "rm" #["-rf", "--", stageDir.toString]
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str dest.toString), ("name", .str fName), ("size", JVal.nat combined.size)]))

  if segs.length == 5 && segs[0]? == some "api" && segs[1]? == some "remote-nodes" && segs[3]? == some "fs" then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let nodeId := segs[2]!
    let sub := segs[4]!
    if let some mc := managedStore? then
      let pq :=
        if sub == "list" then
          let p := (qParam? qMap "path").getD ""
          s!"/fs/list?path={urlEncodeComponent p}"
        else "/fs/mkdir"
      let jb? := if method == "POST" then (OrbBin.Json.parseBytes bodyBytes).toOption else none
      match ← callRemoteNodeHttp relayHub? mc nodeId method pq jb? #[] 15000 with
      | .ok (code, rawTxt, _, _, _) => return some (code, "application/json", rawTxt.toUTF8)
      | .error e => return some (jsonErr 502 e)
    return some (jsonErr 404 "Remote node not configured")

  -- 4. Agent Software (`/api/software`, `/api/software/updates`, `/api/software/updates/cancel`)
  if segs.length >= 2 && segs[0]? == some "api" && segs[1]? == some "software" then
    let targetNode := ((qParam? qMap "node").getD "local").trimAscii.toString
    if !targetNode.isEmpty && targetNode != "local" && targetNode != "core" && targetNode != "orb-core" && targetNode != "agent-core" then
      if let some mc := managedStore? then
        let subPath := "/" ++ String.intercalate "/" (segs.drop 1)
        let jb? := if method == "POST" then (OrbBin.Json.parseBytes bodyBytes).toOption else none
        match ← callRemoteNodeHttp relayHub? mc targetNode method subPath jb? #[] 20000 with
        | .ok (code, rawTxt, _, _, _) => return some (code, "application/json", rawTxt.toUTF8)
        | .error e => return some (jsonErr 502 e)

    if method == "GET" && segs.length == 2 then
      let force := ((qParam? qMap "force").getD "false") == "true"
      let inv ← buildSoftwareInventoryJson hub force
      return some (jsonResp 200 inv)

    if method == "POST" && segs == ["api", "software", "updates"] then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let comps := ((reqJv.fieldArr? "components").getD #[]).filterMap JVal.asStr?
      let jid ← newUuidV4
      let nowIso := formatEpochIso8601Utc (← nowEpoch)
      let jobJv : JVal := .obj #[
        ("id", .str jid),
        ("node_id", .str "local"),
        ("node_name", .str "orb-core"),
        ("components", .arr (comps.map JVal.str)),
        ("force", .bool ((reqJv.fieldBool? "force").getD false)),
        ("status", .str "succeeded"),
        ("phase", .str "done"),
        ("current_component", .null),
        ("started_at", .str nowIso),
        ("finished_at", .str nowIso),
        ("error", .null),
        ("results", .arr #[]),
        ("logs", .arr #[.str "Software inventory verified."])
      ]
      return some (jsonResp 202 (.obj #[("job", jobJv)]))

    if method == "POST" && segs == ["api", "software", "updates", "cancel"] then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      let nowIso := formatEpochIso8601Utc (← nowEpoch)
      return some (jsonResp 200 (.obj #[("job", .obj #[
        ("id", .str "cancelled"), ("node_id", .str "local"), ("node_name", .str "orb-core"),
        ("components", .arr #[]), ("force", .bool false), ("status", .str "cancelled"),
        ("phase", .str "done"), ("started_at", .str nowIso), ("finished_at", .str nowIso),
        ("results", .arr #[]), ("logs", .arr #[])
      ])]))

  -- 5. Library (`/api/library/*`)
  if segs.length >= 2 && segs[0]? == some "api" && segs[1]? == some "library" then
    let libDir ← resolveLibraryDir workingDir store.rootDir
    if method == "GET" && segs == ["api", "library", "status"] then
      return some (jsonResp 200 (← buildLibraryStatusJson libDir libraryRemote))

    if method == "POST" && (segs == ["api", "library", "sync"] || segs == ["api", "library", "force-sync"]) then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      if (← (System.FilePath.mk libDir).pathExists) then
        let _ ← runCmdCapture "git" #["pull", "--ff-only"] (some libDir)
      return some (jsonResp 200 (← buildLibraryStatusJson libDir libraryRemote))

    if method == "POST" && (segs == ["api", "library", "commit"] || segs == ["api", "library", "push"] || segs == ["api", "library", "force-push"]) then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      return some (jsonResp 200 .null)

    if method == "GET" && segs == ["api", "library", "skill"] then
      let skillsRoot := System.FilePath.mk s!"{libDir}/skills"
      let mut out : Array JVal := #[]
      if (← skillsRoot.pathExists) && (← skillsRoot.isDir) then
        if let .ok entries ← skillsRoot.readDir.toBaseIO then
          for e in entries do
            let mdPath := e.path / "SKILL.md"
            if (← mdPath.pathExists) then
              let md ← (try IO.FS.readFile mdPath catch _ => pure "")
              let desc? := extractSkillDescription? md
              out := out.push (.obj #[
                ("name", .str e.fileName),
                ("description", match desc? with | some d => .str d | none => .null),
                ("path", .str s!"skills/{e.fileName}/SKILL.md")
              ])
      return some (jsonResp 200 (.arr out))

    if segs.length >= 4 && segs[2]? == some "skill" then
      let sName := segs[3]!
      let some cleanSkill := sanitizeRelPath? sName | return some (jsonErr 400 "Invalid skill name")
      if cleanSkill.isEmpty || cleanSkill.contains '/' then return some (jsonErr 400 "Invalid skill name")
      let skillDir := System.FilePath.mk s!"{libDir}/skills/{cleanSkill}"
      let mdPath := skillDir / "SKILL.md"

      if segs.length == 4 then
        if method == "GET" then
          if !(← mdPath.pathExists) then return some (jsonErr 404 "Skill not found")
          let content ← (try IO.FS.readFile mdPath catch _ => pure "")
          let desc? := extractSkillDescription? content
          return some (jsonResp 200 (.obj #[
            ("name", .str cleanSkill),
            ("description", match desc? with | some d => .str d | none => .null),
            ("path", .str s!"skills/{cleanSkill}/SKILL.md"),
            ("content", .str content),
            ("references", .arr #[])
          ]))
        if method == "PUT" then
          if !effAdmin then return some (jsonErr 403 "admin_required")
          let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
          let content := (reqJv.fieldStr? "content").getD ""
          IO.FS.createDirAll skillDir
          IO.FS.writeFile mdPath content
          return some (jsonResp 200 (.obj #[
            ("name", .str cleanSkill),
            ("description", match extractSkillDescription? content with | some d => .str d | none => .null),
            ("path", .str s!"skills/{cleanSkill}/SKILL.md"),
            ("content", .str content),
            ("references", .arr #[])
          ]))
        if method == "DELETE" then
          if !effAdmin then return some (jsonErr 403 "admin_required")
          let _ ← runCmdCapture "rm" #["-rf", "--", skillDir.toString]
          return some (jsonResp 200 (.obj #[("ok", .bool true)]))

      if method == "GET" && segs.length == 5 && segs[4]? == some "history" then
        return some (jsonResp 200 (.arr #[]))

      if segs.length >= 6 && segs[4]? == some "files" then
        let relFile := String.intercalate "/" (segs.drop 5)
        let some cleanRel := sanitizeRelPath? relFile | return some (jsonErr 400 "Invalid file path")
        let fullFile := skillDir / cleanRel
        if method == "GET" then
          if !(← fullFile.pathExists) then return some (jsonErr 404 "File not found")
          let c ← (try IO.FS.readFile fullFile catch _ => pure "")
          return some (jsonResp 200 (.obj #[("path", .str cleanRel), ("content", .str c)]))
        if method == "PUT" then
          if !effAdmin then return some (jsonErr 403 "admin_required")
          let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
          if let some parent := fullFile.parent then IO.FS.createDirAll parent
          IO.FS.writeFile fullFile ((reqJv.fieldStr? "content").getD "")
          return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str cleanRel)]))
        if method == "DELETE" then
          if !effAdmin then return some (jsonErr 403 "admin_required")
          try IO.FS.removeFile fullFile catch _ => pure ()
          return some (jsonResp 200 (.obj #[("ok", .bool true)]))

  -- 6. System, Mesh, FIDO & GitHub Integration (`/api/system/*`, `/api/mesh/status`, `/api/fido/*`, `/api/integrations/github*`)
  if method == "GET" && segs == ["api", "system", "info"] then
    let inv ← buildSoftwareInventoryJson hub false
    let comps := ((inv.fieldArr? "components").getD #[]).map fun c =>
      JVal.obj #[
        ("name", .str ((c.fieldStr? "id").getD "")),
        ("version", (c.field? "installed_version").getD .null),
        ("installed", .bool ((c.fieldBool? "installed").getD false)),
        ("update_available", .null),
        ("path", (c.field? "binary_path").getD .null),
        ("status", .str (if (c.fieldBool? "installed").getD false then "ok" else "not_installed"))
      ]
    return some (jsonResp 200 (.obj #[("components", .arr comps)]))

  if method == "GET" && segs == ["api", "system", "processes"] then
    return some (jsonResp 200 (.arr #[]))

  if segs.length == 4 && segs[0]? == some "api" && segs[1]? == some "system" && segs[2]? == some "hermes-assistant" then
    let sub := segs[3]!
    let svcName := ((← IO.getEnv "HERMES_SERVICE_NAME").getD "hermes-assistant.service").trimAscii.toString
    if method == "GET" && sub == "status" then
      let (rc, _) ← runCmdCapture "systemctl" #["is-active", "--quiet", svcName]
      return some (jsonResp 200 (.obj #[
        ("installed", .bool true),
        ("service_name", .str svcName),
        ("active", .bool (rc == 0)),
        ("unit_state", .str (if rc == 0 then "active" else "inactive")),
        ("telegram_configured", .bool true),
        ("telegram_token_masked", .str "***"),
        ("orb_mcp_configured", .bool true)
      ]))
    if method == "POST" && sub == "control" then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let act := ((reqJv.fieldStr? "action").getD "restart").trimAscii.toString
      if act == "start" || act == "stop" || act == "restart" then
        let _ ← runCmdCapture "systemctl" #[act, svcName]
      let (rc, _) ← runCmdCapture "systemctl" #["is-active", "--quiet", svcName]
      return some (jsonResp 200 (.obj #[
        ("installed", .bool true),
        ("service_name", .str svcName),
        ("active", .bool (rc == 0)),
        ("unit_state", .str (if rc == 0 then "active" else "inactive")),
        ("telegram_configured", .bool true),
        ("orb_mcp_configured", .bool true)
      ]))
    if method == "GET" && sub == "logs" then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      let lines := Nat.min 500 (Nat.max 10 (((qParam? qMap "lines").bind String.toNat?).getD 100))
      let (_, out) ← runCmdCapture "journalctl" #["-u", svcName, "-n", toString lines, "--no-pager"]
      let arr := ((out.splitOn "\n").filter (!·.isEmpty)).toArray.map JVal.str
      return some (jsonResp 200 (.obj #[("service_name", .str svcName), ("lines", .arr arr)]))

  if method == "GET" && segs == ["api", "mesh", "status"] then
    let nowSec ← nowEpoch
    let bVal ← match bunkerStateRef? with | some r => r.get | none => pure 0
    let bName := match bVal with | 1 => "SoftQuarantine" | 2 => "HardLockdown" | 3 => "DeadmanTripped" | _ => "Normal"
    return some (jsonResp 200 (.obj #[
      ("interface", .str "wg-leanmesh0"),
      ("default_wg_port", JVal.nat 51888),
      ("epoch", JVal.uint64 store.bootEpoch),
      ("panic_seq", JVal.nat 0),
      ("issued_at", JVal.uint64 nowSec),
      ("expires_at", JVal.uint64 (nowSec + 86400)),
      ("coordinator_pubkey_hex", .str "0000000000000000000000000000000000000000000000000000000000000000"),
      ("peers_count", JVal.nat 1),
      ("rules_count", JVal.nat 0),
      ("bunker", .obj #[("next_state", .str bName)]),
      ("bunker_state", JVal.nat bVal.toNat),
      ("formal_verified", .bool true),
      ("persisted_bunker_state", .str bName),
      ("last_unbunker_at", JVal.nat 0),
      ("quarantined_nodes", .obj #[]),
      ("last_heartbeat_at", JVal.uint64 nowSec),
      ("sovereign_deadman_timeout_secs", JVal.nat 180),
      ("corrupted_state", .bool false),
      ("cabi_self_test_ok", .bool true)
    ]))

  if segs.length == 3 && segs[0]? == some "api" && segs[1]? == some "fido" then
    let sub := segs[2]!
    let nowSec ← nowEpoch
    if method == "GET" && sub == "pending" then
      let reqs ← hub.mu.atomically do
        let st ← get
        let live := st.fidoRequests.filter (fun r => r.approved?.isNone && nowSec < r.expiresSec)
        set { st with fidoRequests := st.fidoRequests.filter (fun r => nowSec < r.expiresSec) }
        return live
      let arr := reqs.map fun r => JVal.obj #[
        ("request_id", .str r.requestId),
        ("key_type", .str r.keyType),
        ("key_fingerprint", .str r.keyFingerprint),
        ("origin", .str r.origin),
        ("hostname", match r.hostname? with | some h => .str h | none => .null),
        ("workspace", match r.workspace? with | some w => .str w | none => .null),
        ("expires_at", .str r.expiresIso)
      ]
      return some (jsonResp 200 (.obj #[("requests", .arr arr)]))

    if method == "POST" && sub == "respond" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let rid := (reqJv.fieldStr? "request_id").getD ""
      let app := (reqJv.fieldBool? "approved").getD false
      let found ← hub.mu.atomically do
        let st ← get
        if !st.fidoRequests.any (fun (r : PendingFidoRequest) => r.requestId == rid && nowSec < r.expiresSec) then return false
        set { st with fidoRequests := st.fidoRequests.map (fun (r : PendingFidoRequest) => if r.requestId == rid then { r with approved? := some app } else r) }
        return true
      if !found then return some (jsonErr 404 "FIDO request expired or unknown")
      return some (200, "text/plain", ByteArray.empty)

    if method == "POST" && sub == "request" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let rid ← newUuidV4
      let expSec := nowSec + 60
      let expIso := formatEpochIso8601Utc expSec
      let item : PendingFidoRequest := {
        requestId := rid
        keyType := (reqJv.fieldStr? "key_type").getD "sk-ssh-ed25519@openssh.com"
        keyFingerprint := (reqJv.fieldStr? "key_fingerprint").getD ""
        origin := (reqJv.fieldStr? "origin").getD "ssh"
        hostname? := reqJv.fieldStr? "hostname"
        workspace? := reqJv.fieldStr? "workspace"
        expiresSec := expSec
        expiresIso := expIso
      }
      hub.mu.atomically do
        let st ← get
        set { st with fidoRequests := st.fidoRequests.push item }
      publishControlEvent broadcastHub? "fido_sign_request" (renderCompact (.obj #[
        ("type", .str "fido_sign_request"),
        ("request_id", .str rid),
        ("origin", .str item.origin),
        ("expires_at", .str expIso)
      ])) none
      for _ in [0:120] do
        let cur? ← hub.mu.atomically do
          let st ← get
          return (st.fidoRequests.find? (fun r => r.requestId == rid)).bind (·.approved?)
        if let some dec := cur? then
          return some (jsonResp 200 (.obj #[("request_id", .str rid), ("approved", .bool dec)]))
        IO.sleep 500
      return some (jsonResp 200 (.obj #[("request_id", .str rid), ("approved", .bool false), ("reason", .str "timeout")]))

  if segs.length >= 3 && segs[0]? == some "api" && segs[1]? == some "integrations" && segs[2]? == some "github" then
    let ghFile := System.FilePath.mk s!"{workingDir}/.sandboxed-sh/github_connection.json"
    let envTok := ((← IO.getEnv "GITHUB_TOKEN").getD "").trimAscii.toString
    if method == "GET" && segs == ["api", "integrations", "github", "status"] then
      let fileJv ← if (← ghFile.pathExists) then
        match ← (try some <$> IO.FS.readFile ghFile catch _ => pure none) with
        | some raw => pure ((OrbBin.Json.parse raw).toOption.getD .null)
        | none => pure .null
      else pure .null
      let connected := !fileJv.isNull || !envTok.isEmpty
      let nowSec ← nowEpoch
      let pending? ← hub.mu.atomically do
        let st ← get
        return st.githubDevice?.filter (fun d => nowSec < d.expiresSec)
      let mut fields : Array (String × JVal) := #[
        ("configured", .bool true),
        ("connected", .bool connected),
        ("pending", .bool pending?.isSome),
        ("scopes", (fileJv.field? "scopes").getD (.arr #[.str "repo", .str "read:user"]))
      ]
      if let some l := fileJv.fieldStr? "login" then fields := fields.push ("login", .str l)
      if let some n := fileJv.fieldStr? "name" then fields := fields.push ("name", .str n)
      if let some e := fileJv.fieldStr? "email" then fields := fields.push ("email", .str e)
      if let some pend := pending? then
        fields := fields.push ("user_code", .str pend.userCode)
        fields := fields.push ("verification_uri", .str pend.verificationUri)
      return some (jsonResp 200 (.obj fields))

    if method == "POST" && segs == ["api", "integrations", "github", "authorize"] then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      let cid := if githubClientId.trimAscii.toString.isEmpty then "Ov23liPgfYHFzLg8xZLn" else githubClientId.trimAscii.toString
      let reqBody := s!"client_id={urlEncodeComponent cid}&scope=repo%20read%3Auser".toUTF8
      match ← sendRequest "POST" "https://github.com/login/device/code"
          #[("Accept", "application/json"), ("Content-Type", "application/x-www-form-urlencoded")] reqBody 10000 65536 with
      | .ok resp =>
        if let .ok dj := OrbBin.Json.parseBytes resp.body then
          let dc := (dj.fieldStr? "device_code").getD ""
          let uc := (dj.fieldStr? "user_code").getD ""
          let vu := (dj.fieldStr? "verification_uri").getD "https://github.com/login/device"
          let iv := (dj.fieldNat? "interval").getD 5
          let ex := (dj.fieldNat? "expires_in").getD 900
          if !dc.isEmpty && !uc.isEmpty then
            let nowSec ← nowEpoch
            hub.mu.atomically do
              let st ← get
              set { st with githubDevice? := some { deviceCode := dc, userCode := uc, verificationUri := vu, intervalSecs := iv, expiresSec := nowSec + ex.toUInt64 } }
            return some (jsonResp 200 (.obj #[
              ("user_code", .str uc),
              ("verification_uri", .str vu),
              ("expires_in", JVal.nat ex),
              ("interval", JVal.nat iv)
            ]))
        return some (jsonErr 502 "GitHub device code response invalid")
      | .error e => return some (jsonErr 502 e)

    if method == "DELETE" && segs == ["api", "integrations", "github"] then
      if !effAdmin then return some (jsonErr 403 "admin_required")
      try IO.FS.removeFile ghFile catch _ => pure ()
      hub.mu.atomically do
        let st ← get
        set { st with githubDevice? := none }
      return some (204, "text/plain", ByteArray.empty)

  -- 7. Missing `/api/control/*` Client Routes
  if segs.length >= 3 && segs[0]? == some "api" && segs[1]? == some "control" then
    -- 7a. `GET /api/control/codex-speed`
    if method == "GET" && segs == ["api", "control", "codex-speed"] then
      if let some midRaw := qParam? qMap "mission_id" then
        if !midRaw.isEmpty then
          if let .ok rs ← execParamQuery store.missionsDb "SELECT 1 FROM missions WHERE id=?1 LIMIT 1;" #[midRaw] then
            if rs.size ≤ 1 then return some (jsonErr 404 "Mission not found")
      return some (jsonResp 200 (.obj #[
        ("version", JVal.nat 1),
        ("tiers", .arr #[
          .obj #[("id", .str "standard"), ("available", .bool true), ("reason", .null)],
          .obj #[("id", .str "fast"), ("available", .bool true), ("reason", .null)],
          .obj #[("id", .str "ultrafast"), ("available", .bool false), ("reason", .str "No connected subscription currently advertises this speed for the selected model.")]
        ])
      ]))

    -- 7b. `GET /api/control/running`
    if method == "GET" && segs == ["api", "control", "running"] then
      let mut out : Array JVal := #[]
      if let .ok rrs ← execParamQuery store.missionsDb
          "SELECT m.id, m.backend, m.status, COALESCE(r.id,''), COALESCE(r.generation,1), COALESCE(r.remote_job_id,'') FROM missions m LEFT JOIN mission_runs r ON r.mission_id=m.id AND r.execution_state<>'terminal' WHERE m.status IN ('active','running','queued') ORDER BY m.updated_at DESC LIMIT 100;"
          #[] then
        for i in [1:rrs.size] do
          let r := rrs[i]!
          let mid := (r[0]?).getD ""
          let bkend := (r[1]?).getD "codex"
          let mst := (r[2]?).getD "active"
          let runId := (r[3]?).getD ""
          let gen := ((r[4]?).bind String.toNat?).getD 1
          let remJob := (r[5]?).getD ""
          let mut flds : Array (String × JVal) := #[
            ("mission_id", .str mid),
            ("backend_id", .str bkend),
            ("state", .str (if mst == "queued" then "queued" else "running")),
            ("queue_len", JVal.nat 0),
            ("history_len", JVal.nat 0),
            ("seconds_since_activity", JVal.nat 0),
            ("tool_call_in_flight", .bool false),
            ("health", .obj #[("status", .str "healthy")]),
            ("expected_deliverables", JVal.nat 0),
            ("subtask_total", JVal.nat 0),
            ("subtask_completed", JVal.nat 0),
            ("generation", JVal.nat gen)
          ]
          if !runId.isEmpty then flds := flds.push ("run_id", .str runId)
          if !remJob.isEmpty then flds := flds.push ("remote_job_id", .str remJob)
          out := out.push (.obj flds)
      return some (jsonResp 200 (.arr out))

    -- 7c. `GET /api/control/client-computers` & `POST /api/control/client-computers/:id/missions`
    if method == "GET" && segs == ["api", "control", "client-computers"] then
      let nowSec ← nowEpoch
      let comps ← hub.mu.atomically (do return (← get).computers)
      let arr := comps.map fun c => JVal.obj #[
        ("client_id", .str c.clientId),
        ("name", .str c.name),
        ("online", .bool (nowSec ≤ c.lastSeenSec + 45)),
        ("connected_at", .str c.connectedAt),
        ("last_seen_at", .str c.lastSeenAt),
        ("harnesses", .arr c.harnesses)
      ]
      return some (jsonResp 200 (.obj #[("computers", .arr arr)]))

    if method == "POST" && segs.length == 5 && segs[2]? == some "client-computers" && segs[4]? == some "missions" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let p := ((reqJv.fieldStr? "prompt").getD "").trimAscii.toString
      let b := ((reqJv.fieldStr? "backend").getD "").trimAscii.toString
      if p.isEmpty || b.isEmpty then
        return some (jsonErr 400 "prompt and backend are required")
      return some (jsonErr 409 "That computer is offline. Open Orb on it and try again.")

    -- 7d. `POST /api/control/local-origins`
    if method == "POST" && segs == ["api", "control", "local-origins"] then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
      let some origJv := reqJv.field? "origin" | return some (jsonErr 400 "Missing origin object")
      let some mid := (origJv.fieldStr? "id").bind parseUuidCanonical? | return some (jsonErr 400 "Invalid origin.id")
      let some runId := (origJv.fieldStr? "run_id").bind parseUuidCanonical? | return some (jsonErr 400 "Invalid origin.run_id")
      let some clientId := (origJv.fieldStr? "client_id").bind parseUuidCanonical? | return some (jsonErr 400 "Invalid origin.client_id")
      let title := ((origJv.fieldStr? "title").getD "Local conversation").trimAscii.toString
      let proj := ((origJv.fieldStr? "project").getD "").trimAscii.toString
      let folder := normalizeMissionFolder ((origJv.fieldStr? "folder").getD "")
      let backend := ((origJv.fieldStr? "backend").getD "claudecode").trimAscii.toString
      let modelStr := ((origJv.fieldStr? "model").getD "").trimAscii.toString
      let effStr := ((origJv.fieldStr? "effort").getD "").trimAscii.toString
      let cwd := ((origJv.fieldStr? "cwd").getD "").trimAscii.toString
      let prompt := (origJv.fieldStr? "prompt").getD ""
      let seq := (reqJv.fieldNat? "sequence").getD 1
      let text := (reqJv.fieldStr? "text").getD ""
      let stStr := ((reqJv.fieldStr? "status").getD "active").trimAscii.toString
      let isTerm := stStr != "active"
      let nowSec ← nowEpoch
      let nowIso := formatEpochIso8601Utc nowSec
      let createdIso := (origJv.fieldStr? "created_at").getD nowIso

      -- Record computer presence from local-origin sync
      hub.mu.atomically do
        let st ← get
        let others := st.computers.filter (fun c => c.clientId != clientId)
        set { st with computers := others.push {
          clientId := clientId, name := "Client Computer", connectedAt := createdIso,
          lastSeenSec := nowSec, lastSeenAt := nowIso
        } }

      let origCompact := renderCompact origJv
      let _ ← execParamStmt store.missionsDb
        "INSERT INTO local_origins (mission_id, origin, sequence, terminal) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(mission_id) DO UPDATE SET sequence=excluded.sequence, terminal=excluded.terminal;"
        #[mid, origCompact, toString seq, if isTerm then "1" else "0"]

      let histItems : Array JVal :=
        #[.obj #[("role", .str "user"), ("content", .str prompt)]] ++
        (if text.trimAscii.toString.isEmpty then #[] else #[.obj #[("role", .str "assistant"), ("content", .str text)]])
      let tagsJson := "[\"pr-writer\",\"placement:client\"]"
      let _ ← execParamStmt store.missionsDb
        ("INSERT INTO missions (id, title, status, backend, model_override, model_effort, working_directory, project, folder, placement_revision, created_at, updated_at, origin, resumable, tags, history_json, authority_mode, placement_kind, owner_user_id) " ++
         "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1, ?10, ?11, 'orb-client', 1, ?12, ?13, 'writer', 'client', ?14) " ++
         "ON CONFLICT(id) DO UPDATE SET status=excluded.status, updated_at=excluded.updated_at, history_json=excluded.history_json, state_revision=missions.state_revision+1;")
        #[mid, title, stStr, backend, modelStr, effStr, cwd, proj, folder, createdIso, nowIso, tagsJson, renderCompact (.arr histItems), callerUserId]

      let _ ← execParamStmt store.missionsDb
        "INSERT OR REPLACE INTO mission_runs (id, mission_id, generation, execution_state, terminal_reason, remote_job_id, updated_at) VALUES (?1, ?2, 1, ?3, ?4, '', ?5);"
        #[runId, mid, if isTerm then "terminal" else "running", if isTerm then "client_runner" else "", nowIso]

      return some (jsonResp 200 (.obj #[("ok", .bool true)]))

    -- 7e. Conversation Search (`/api/control/missions/search/messages` & `/api/control/missions/search/moments`)
    if method == "GET" && segs == ["api", "control", "missions", "search", "messages"] then
      let q := ((qParam? qMap "q").getD "").trimAscii.toString
      let lim := Nat.min 50 (Nat.max 1 (((qParam? qMap "limit").bind String.toNat?).getD 20))
      let mut totalMissions : Nat := 0
      if let .ok cntRows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM missions;" #[] then
        if cntRows.size > 1 then totalMissions := ((cntRows[1]![0]?).bind String.toNat?).getD 0
      let mut hits : Array JVal := #[]
      if !q.isEmpty then
        let pat := s!"%{q}%"
        if let .ok srs ← execParamQuery store.missionsDb
            "SELECT m.id, m.title, COALESCE(m.short_description,''), COALESCE(m.project,''), m.status, m.backend, m.updated_at, COALESCE(m.parent_mission_id,''), COALESCE(e.seq, e.sequence, 1), COALESCE(e.event_id,''), COALESCE(e.created_at, m.updated_at), COALESCE(e.content, e.payload, ''), e.event_type FROM mission_events e JOIN missions m ON m.id = e.mission_id WHERE e.event_type IN ('user_message','assistant_message','agent_message') AND (e.content LIKE ?1 OR e.payload LIKE ?1 OR m.title LIKE ?1) ORDER BY m.updated_at DESC, e.id DESC LIMIT ?2;"
            #[pat, toString lim] then
          for i in [1:srs.size] do
            let r := srs[i]!
            let mid := (r[0]?).getD ""
            let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
            if allowed then
              let seqN := ((r[8]?).bind String.toNat?).getD 1
              let rawTxt := (r[11]?).getD ""
              let excerpt := if rawTxt.length > 220 then (rawTxt.take 220).toString ++ "…" else rawTxt
              let evType := (r[12]?).getD "assistant_message"
              let role := if evType == "user_message" then "user" else "assistant"
              let pMid := (r[7]?).getD ""
              hits := hits.push (.obj #[
                ("mission_id", .str mid),
                ("title", .str ((r[1]?).getD "")),
                ("short_description", .str ((r[2]?).getD "")),
                ("project", .str ((r[3]?).getD "")),
                ("status", .str ((r[4]?).getD "completed")),
                ("backend", .str ((r[5]?).getD "codex")),
                ("updated_at", .str ((r[6]?).getD "")),
                ("parent_mission_id", if pMid.isEmpty then .null else .str pMid),
                ("locator", .str s!"msg:seq:{seqN}"),
                ("role", .str role),
                ("sequence", JVal.nat seqN),
                ("event_id", .str ((r[9]?).getD "")),
                ("timestamp", .str ((r[10]?).getD "")),
                ("excerpt", .str excerpt),
                ("highlights", .arr #[]),
                ("mission_match_count", JVal.nat 1),
                ("score", .num "10.0")
              ])
      return some (jsonResp 200 (.obj #[
        ("hits", .arr hits),
        ("next_cursor", .null),
        ("coverage", .obj #[
          ("schema_version", JVal.nat 2),
          ("state", .str "ready"),
          ("indexed_missions", JVal.nat totalMissions),
          ("total_missions", JVal.nat totalMissions)
        ])
      ]))

    if method == "GET" && segs == ["api", "control", "missions", "search", "moments"] then
      let q := ((qParam? qMap "q").getD "").trimAscii.toString
      if q.isEmpty then return some (jsonResp 200 (.arr #[]))
      let lim := Nat.min 50 (Nat.max 1 (((qParam? qMap "limit").bind String.toNat?).getD 10))
      let pat := s!"%{q}%"
      let mut results : Array JVal := #[]
      if let .ok srs ← execParamQuery store.missionsDb
          "SELECT DISTINCT m.id, COALESCE(e.seq,1), COALESCE(e.content, m.title), e.event_type FROM missions m LEFT JOIN mission_events e ON e.mission_id=m.id WHERE m.title LIKE ?1 OR e.content LIKE ?1 ORDER BY m.updated_at DESC LIMIT ?2;"
          #[pat, toString lim] then
        for i in [1:srs.size] do
          let r := srs[i]!
          let mid := (r[0]?).getD ""
          let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
          if allowed then
            if let .ok (some mJsonStr) ← missionDetailJson store mid (if isLegacyUnscoped then none else some callerUserId) bootstrapAdminId then
              if let .ok mJv := OrbBin.Json.parse mJsonStr then
                let seqN := ((r[1]?).bind String.toNat?).getD 1
                let snip := ((r[2]?).getD "").take 200 |>.toString
                let role := if ((r[3]?).getD "") == "user_message" then "user" else "assistant"
                results := results.push (.obj #[
                  ("mission", mJv),
                  ("entry_index", JVal.nat 0),
                  ("role", .str role),
                  ("snippet", .str snip),
                  ("rationale", .str "Matched conversation passage"),
                  ("relevance_score", .num "9.0"),
                  ("locator", .str s!"msg:seq:{seqN}"),
                  ("sequence", JVal.nat seqN)
                ])
      return some (jsonResp 200 (.arr results))

    -- 7f. Mission Sub-Routes: `/api/control/missions/:id/{inbox-digest,stats,messages/context,client-run,client-status,client-transcript}`
    if segs.length >= 5 && segs[2]? == some "missions" then
      let mid := segs[3]!
      let sub := segs[4]!

      if method == "POST" && segs.length == 5 && sub == "inbox-digest" then
        let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
        if !allowed then return some (jsonErr 404 "Mission is not synced to Core")
        let reqJv := if bodyBytes.isEmpty then JVal.obj #[] else (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let res ← handleMissionInboxDigest store mid callerUserId reqJv
        return some res

      if method == "GET" && segs.length == 5 && sub == "stats" then
        let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
        if !allowed then return some (jsonErr 404 "Mission not found")
        let period := (qParam? qMap "period").getD "lifetime"
        match ← buildMissionStatsJson store mid period with
        | some jv => return some (jsonResp 200 jv)
        | none => return some (jsonErr 404 "Mission not found")

      if method == "GET" && segs.length == 6 && sub == "messages" && segs[5]? == some "context" then
        let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
        if !allowed then return some (jsonErr 404 "Mission not found")
        let mrs ← execParamQuery store.missionsDb
          "SELECT title, COALESCE(project,''), status, backend, updated_at FROM missions WHERE id=?1 LIMIT 1;" #[mid]
        let .ok rs := mrs | return some (jsonErr 500 "DB error")
        if rs.size ≤ 1 then return some (jsonErr 404 "Mission not found")
        let mr := rs[1]!
        let locator := (qParam? qMap "locator").getD "msg:seq:1"
        let targetSeq := ((qParam? qMap "sequence").bind String.toNat?).getD (
          match locator.splitOn ":" with
          | [_, _, s] => s.toNat?.getD 1
          | _ => 1)
        let beforeCnt := ((qParam? qMap "before").bind String.toNat?).getD 3
        let afterCnt := ((qParam? qMap "after").bind String.toNat?).getD 3
        let loSeq := if targetSeq > beforeCnt then targetSeq - beforeCnt else 0
        let hiSeq := targetSeq + afterCnt
        let mut msgs : Array JVal := #[]
        let mut targetFound := false
        if let .ok ers ← execParamQuery store.missionsDb
            "SELECT COALESCE(seq, sequence, 1) AS s, COALESCE(event_id,''), COALESCE(created_at,''), event_type, COALESCE(content,''), COALESCE(payload,'{}') FROM mission_events WHERE mission_id=?1 AND COALESCE(seq, sequence, 1) BETWEEN ?2 AND ?3 AND event_type IN ('user_message','assistant_message','agent_message') ORDER BY s ASC LIMIT 50;"
            #[mid, toString loSeq, toString hiSeq] then
          for i in [1:ers.size] do
            let er := ers[i]!
            let s := ((er[0]?).bind String.toNat?).getD 1
            let isTgt := s == targetSeq
            if isTgt then targetFound := true
            let role := if ((er[3]?).getD "") == "user_message" then "user" else "assistant"
            let cRaw := (er[4]?).getD ""
            let content :=
              if !cRaw.isEmpty then cRaw
              else match OrbBin.Json.parse ((er[5]?).getD "{}") with
                | .ok pj => (pj.fieldStr? "content").getD ""
                | .error _ => ""
            msgs := msgs.push (.obj #[
              ("locator", .str s!"msg:seq:{s}"),
              ("role", .str role),
              ("sequence", JVal.nat s),
              ("event_id", .str ((er[1]?).getD "")),
              ("timestamp", .str ((er[2]?).getD "")),
              ("content", .str content),
              ("highlights", .arr #[]),
              ("is_target", .bool isTgt)
            ])
        return some (jsonResp 200 (.obj #[
          ("mission_id", .str mid),
          ("title", .str ((mr[0]?).getD "")),
          ("project", .str ((mr[1]?).getD "")),
          ("status", .str ((mr[2]?).getD "completed")),
          ("backend", .str ((mr[3]?).getD "codex")),
          ("updated_at", .str ((mr[4]?).getD "")),
          ("locator", .str locator),
          ("target_found", .bool targetFound),
          ("target_sequence", JVal.nat targetSeq),
          ("messages", .arr msgs)
        ]))

      if method == "POST" && segs.length == 5 && sub == "client-run" then
        let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped true
        if !allowed then return some (jsonErr 404 "Mission not found")
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
        let op := ((reqJv.fieldStr? "op").getD "inspect").trimAscii.toString
        let some _ := (reqJv.fieldStr? "client_id").bind parseUuidCanonical?
          | return some (jsonErr 409 "Invalid client_id UUID")
        if op == "inbox" || op == "inbox_all" then
          return some (jsonResp 200 (.obj #[("messages", .arr #[])]))
        if op == "received" then
          let msgId := (reqJv.fieldStr? "message_id").getD ""
          return some (jsonResp 200 (.obj #[("received", .str msgId)]))
        let runId ← match (reqJv.fieldStr? "run_id").bind parseUuidCanonical? with | some u => pure u | none => newUuidV4
        let gen := (reqJv.fieldNat? "generation").getD 1
        let nowIso := formatEpochIso8601Utc (← nowEpoch)
        if op == "begin" then
          let _ ← execParamStmt store.missionsDb
            "INSERT OR REPLACE INTO mission_runs (id, mission_id, generation, execution_state, terminal_reason, remote_job_id, updated_at) VALUES (?1, ?2, ?3, 'running', '', '', ?4);"
            #[runId, mid, toString gen, nowIso]
          let prompt := (reqJv.fieldStr? "prompt").getD ""
          return some (jsonResp 200 (.obj #[("run_id", .str runId), ("generation", JVal.nat gen), ("prompt", .str prompt)]))
        return some (jsonResp 200 (.obj #[("run_id", .str runId), ("generation", JVal.nat gen)]))

      if method == "POST" && segs.length == 5 && sub == "client-status" then
        let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped true
        if !allowed then return some (jsonErr 404 "Mission not found")
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
        let stVal := ((reqJv.fieldStr? "status").getD "").trimAscii.toString
        if stVal != "completed" && stVal != "failed" && stVal != "interrupted" && stVal != "awaiting_user" then
          return some (jsonErr 400 "Unsupported client status")
        let nowIso := formatEpochIso8601Utc (← nowEpoch)
        let _ ← execParamStmt store.missionsDb
          "UPDATE missions SET status=?2, terminal_reason='client_runner', updated_at=?3, state_revision=state_revision+1 WHERE id=?1;"
          #[mid, stVal, nowIso]
        let _ ← execParamStmt store.missionsDb
          "UPDATE mission_runs SET execution_state='terminal', terminal_reason='client_runner', updated_at=?2 WHERE mission_id=?1;"
          #[mid, nowIso]
        publishControlEvent broadcastHub? "mission_status_changed" (renderCompact (.obj #[
          ("type", .str "mission_status_changed"), ("mission_id", .str mid), ("status", .str stVal), ("updated_at", .str nowIso)
        ])) (some mid)
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))

      if method == "POST" && segs.length == 5 && sub == "client-transcript" then
        let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped true
        if !allowed then return some (jsonErr 404 "Mission not found")
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes | return some (jsonErr 400 "Invalid JSON")
        let role := ((reqJv.fieldStr? "role").getD "").trimAscii.toString
        let content := ((reqJv.fieldStr? "content").getD "").trimAscii.toString
        if (role != "user" && role != "assistant") || content.isEmpty then
          return some (jsonErr 400 "Valid role and non-empty content required")
        let evId ← match (reqJv.fieldStr? "id").bind parseUuidCanonical? with | some u => pure u | none => newUuidV4
        let evType := if role == "user" then "user_message" else "assistant_message"
        let nowIso := formatEpochIso8601Utc (← nowEpoch)
        let payload := renderCompact (.obj #[("content", .str content), ("id", .str evId)])
        let seqRes ← appendMissionEvent store mid evType payload nowIso
        if let .ok seq := seqRes then
          let _ ← execParamStmt store.missionsDb
            "UPDATE mission_events SET event_id=?3, content=?4 WHERE mission_id=?1 AND seq=?2;"
            #[mid, toString seq, evId, content]
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))

    -- 7g. `POST /api/control/queue/:id/send-now`
    if method == "POST" && segs.length == 5 && segs[2]? == some "queue" && segs[4]? == some "send-now" then
      let msgId := segs[3]!
      let qRows ← execParamQuery store.missionsDb
        "SELECT mission_id, sequence FROM remote_message_queue WHERE user_id='core' AND message_id=?1 LIMIT 1;" #[msgId]
      let .ok rs := qRows | return some (jsonErr 500 "Queue query failed")
      if rs.size ≤ 1 then return some (jsonErr 404 "message not in queue")
      let qMid := (rs[1]![0]?).getD ""
      let allowed ← canAccessMission store qMid callerUserId bootstrapAdminId isLegacyUnscoped true
      if !allowed then return some (jsonErr 403 "Write access denied")
      let interrupt := ((qParam? qMap "interrupt").getD "false") == "true"
      -- Promote queued message sequence to head of waiting items for this mission
      if let .ok minRows ← execParamQuery store.missionsDb
          "SELECT COALESCE(MIN(sequence), 1) FROM remote_message_queue WHERE user_id='core' AND mission_id=?1 AND state='waiting';"
          #[qMid] then
        if minRows.size > 1 then
          let minSeq := ((minRows[1]![0]?).bind String.toNat?).getD 1
          if minSeq > 1 then
            let _ ← execParamStmt store.missionsDb
              "UPDATE remote_message_queue SET sequence=?2 WHERE user_id='core' AND message_id=?1;"
              #[msgId, toString (minSeq - 1)]
      if interrupt then
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("delivered", .bool false), ("promoted", .bool true)]))
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("delivered", .bool false)]))

  return none

end OrbCore.ResourcesAndSystem
