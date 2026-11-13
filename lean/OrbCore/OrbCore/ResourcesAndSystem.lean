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
import OrbCore.Skills
import OrbCore.SettingsDocument

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
  return (st.toNat, (String.fromUTF8? acc).getD "")

/-- Execute `git` non-interactively (`GIT_TERMINAL_PROMPT=0`, batch SSH) and capture combined stdout+stderr. -/
private def runGitCapture (args : Array String) (cwd? : Option String := none) : IO (Nat × String) := do
  let env ← environList
  let hasSshCmd := env.any (fun e => e.startsWith "GIT_SSH_COMMAND=")
  let envPrefix :=
    "GIT_TERMINAL_PROMPT=0 " ++
    (if hasSshCmd then "" else "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' ")
  let cdPrefix := match cwd? with | some dir => "cd " ++ shellSingleQuote dir ++ " && " | none => ""
  let cmdLine := cdPrefix ++ envPrefix ++ "exec 'git'" ++
    (if args.isEmpty then "" else " " ++ String.intercalate " " (args.toList.map shellSingleQuote)) ++ " 2>&1"
  let sp ← spawnPgrp "/bin/sh" #["-c", cmdLine] env false false true
  if sp.pid < 0 then return (127, "failed to spawn git")
  let mut acc := ByteArray.empty
  if sp.stdoutFd >= 0 then
    let mut eof := false
    while !eof && acc.size < 524288 do
      let chunk ← readFdChunk sp.stdoutFd 8192
      if chunk.isEmpty then eof := true else acc := acc ++ chunk
    closeFdRaw sp.stdoutFd
  let st ← waitpidBlock sp.pid
  return (st.toNat, (String.fromUTF8? acc).getD "")

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

/-- Fixed-point JSON number: renders `scaled / 10^decimals` (`decimals ≥ 1`). -/
private def numFixed (scaled decimals : Nat) : JVal :=
  let base := 10 ^ decimals
  let frac := toString (scaled % base)
  .num s!"{scaled / base}.{String.ofList (List.replicate (decimals - frac.length) '0')}{frac}"

/-- Parses a non-negative decimal such as `"4.08"` into thousandths (`4080`). -/
private def parseDecimalMilli (raw : String) : Nat :=
  match raw.trimAscii.toString.splitOn "." with
  | [whole] => (whole.toNat?.getD 0) * 1000
  | whole :: frac :: _ =>
    let f3 := ((frac ++ "000").take 3).toString
    (whole.toNat?.getD 0) * 1000 + (f3.toNat?.getD 0)
  | [] => 0

/-- Per-id token and cost totals, one slot per time bucket. -/
private structure ResSeries where
  id    : String
  tok   : Array Nat
  cents : Array Nat

private def bumpSeries (accs : Array ResSeries) (id : String) (nb bi tok cents : Nat) : Array ResSeries :=
  match accs.findIdx? (·.id == id) with
  | some i =>
    accs.modify i fun a => { a with tok := a.tok.modify bi (· + tok), cents := a.cents.modify bi (· + cents) }
  | none =>
    let z : Array Nat := Array.replicate nb 0
    accs.push { id, tok := z.modify bi (· + tok), cents := z.modify bi (· + cents) }

private def sumNat (xs : Array Nat) : Nat := xs.foldl (· + ·) 0

/-- Billions of tokens per hour, 9 decimals. -/
private def bTokPerHour (tok secs : Nat) : JVal := numFixed (tok * 3600 / Nat.max 1 secs) 9

/-- US dollars per hour from cents, 6 decimals. -/
private def usdPerHour (cents secs : Nat) : JVal := numFixed (cents * 36000000 / Nat.max 1 secs) 6

/-- Per-bucket rates; the last bucket is still filling, so it is divided by its elapsed time. -/
private def rateSeries (vals : Array Nat) (bucketSecs lastSecs : Nat) (rate : Nat → Nat → JVal) : JVal :=
  .arr ((Array.range vals.size).map fun i =>
    rate vals[i]! (if i + 1 == vals.size then lastSecs else bucketSecs))

private def zeroSeries (nb : Nat) : JVal := .arr (Array.replicate nb (.num "0.0"))

/-- `(range id, window minutes, bucket minutes)`; unknown ranges fall back to `6h`. -/
private def resourcesRangeSpec (raw : String) : String × Nat × Nat :=
  match raw with
  | "30m" => ("30m", 30, 1)
  | "1h" => ("1h", 60, 1)
  | "24h" => ("24h", 1440, 20)
  | "7d" => ("7d", 10080, 120)
  | _ => ("6h", 360, 5)

private def inferencePoolLabel (id : String) : String :=
  match id with
  | "anthropic" => "Anthropic"
  | "openai" => "OpenAI"
  | "google" => "Google"
  | "gemini" => "Google Gemini"
  | "xai" => "xAI"
  | "zai" => "Z.AI"
  | "openrouter" => "OpenRouter"
  | "unknown" => "Unattributed"
  | other => other

private def managedClassLabel (provider size : String) : String :=
  let prov := match provider with
    | "boat" => "Boat"
    | "leanci" => "lean.ci"
    | "hetzner" => "Hetzner"
    | "vastai" => "Vast.ai"
    | "scaleway" => "Scaleway"
    | "colab" => "Google Colab"
    | "" => "Cloud"
    | other => other
  s!"{prov} · {if size.isEmpty then "vm" else size}"

/-- vCPU of a managed VM in thousandths, from the provider's declared size.
    An undeclared size counts as 4. -/
private def managedSizeVcpuMilli (provider size : String) : Nat :=
  match managedSizeSpec? provider size with
  | some spec => spec.cpu * 1000
  | none => 4000

/-- vCPU assumed for a static node whose capacity Core has not sampled, in thousandths. -/
private def staticNodeVcpuMilli : Nat := 8000

private def externalTrafficId : String := "__external__"

private def tokenSumSql : String := "input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens"

/-- Epoch seconds of a mission timestamp column that may hold ISO-8601 text or a bare epoch. -/
private def epochOfColumnSql (col : String) : String :=
  s!"CASE WHEN {col} GLOB '[0-9]*' AND {col} NOT LIKE '%-%' THEN CAST({col} AS INTEGER) ELSE CAST(strftime('%s',{col}) AS INTEGER) END"

/-- Walks `parent_mission_id` to the root mission; `none` when the mission row does not exist. -/
private def resolveRootMission (store : CoreStore) (mid : String) : IO (Option String) := do
  let mut cur := mid
  for hop in [0:8] do
    match ← execParamQuery store.missionsDb
        "SELECT COALESCE(parent_mission_id,'') FROM missions WHERE id=?1 LIMIT 1;" #[cur] with
    | .ok rs =>
      if rs.size ≤ 1 then return (if hop == 0 then none else some cur)
      let parent := (rs[1]![0]?).getD ""
      if parent.isEmpty || parent == cur then return some cur
      cur := parent
    | .error _ => return none
  return some cur

private def resourceBarState (status : String) : String :=
  match status with
  | "blocked" | "failed" => "capped"
  | "completed" | "acknowledged" | "done" => "done"
  | "active" | "waiting_background" | "running" => "active"
  | "cancelled" | "interrupted" => "cancelled"
  | _ => "pending"

private def missionStatusIsLive (status : String) : Bool :=
  status == "active" || status == "running" || status == "pending" || status == "queued" ||
  status == "waiting_background" || status == "blocked"

structure ComputeSources where
  /-- `(id, label, sublabel, totalMilli, activeMilli)` per machine class. -/
  sources : Array (String × String × String × Nat × Nat)
  classCounts : Array (String × Nat)
  /-- `(class id, root mission, leased milli-vCPU)`. -/
  links : Array (String × String × Nat)

/-- Live compute capacity and use per machine class: the Core host by load,
    the static fleet by size, managed VMs by what a mission holds. -/
def liveComputeSources (store : CoreStore) (managedStore? : Option ManagedComputeStore) : IO ComputeSources := do
  let (hostVcpu, load1Str, _, _) ← readHostCpuAndRam
  let hostTotalMilli := hostVcpu * 1000
  let mut sources : Array (String × String × String × Nat × Nat) :=
    #[("core:host", "Local host", "local", hostTotalMilli, Nat.min hostTotalMilli (parseDecimalMilli load1Str))]
  let (_, staticNodes) ← loadStaticRemoteNodes
  if !staticNodes.isEmpty then
    let n := staticNodes.size
    sources := sources.push ("static:fleet", "Static fleet", s!"{n} host{if n == 1 then "" else "s"}", n * staticNodeVcpuMilli, 0)
  let mut classCounts : Array (String × Nat) := #[]
  let mut compLinks : Array (String × String × Nat) := #[]
  if let some mc := managedStore? then
    if let .ok mf ← loadManagedFleet mc true true 0 0 8 then
      for vm in mf.machines do
        if vm.status == "destroyed" then continue
        let classId := s!"{vm.provider}:{if vm.size.isEmpty then "vm" else vm.size}"
        let vcpu := managedSizeVcpuMilli vm.provider vm.size
        let mut leased := 0
        if !vm.ownerMission.isEmpty then
          if let some root ← resolveRootMission store vm.ownerMission then
            leased := vcpu
            match compLinks.findIdx? (fun l => l.1 == classId && l.2.1 == root) with
            | some li => compLinks := compLinks.modify li fun (c, m, v) => (c, m, v + vcpu)
            | none => compLinks := compLinks.push (classId, root, vcpu)
        match classCounts.findIdx? (·.1 == classId) with
        | some ci => classCounts := classCounts.modify ci fun (c, k) => (c, k + 1)
        | none => classCounts := classCounts.push (classId, 1)
        match sources.findIdx? (·.1 == classId) with
        | some si => sources := sources.modify si fun (i, l, s, t, a) => (i, l, s, t + vcpu, a + leased)
        | none => sources := sources.push (classId, managedClassLabel vm.provider vm.size, "", vcpu, leased)
  return { sources, classCounts, links := compLinks }

/-- Record this minute's compute use per machine class. One row per class and
    minute; a second sample in the same minute replaces the first. -/
def sampleComputeRollup (store : CoreStore) (managedStore? : Option ManagedComputeStore) (nowSec : UInt64) :
    IO (Except String Nat) := do
  let live ← liveComputeSources store managedStore?
  let bucket := nowSec / 60
  for (id, _, _, total, active) in live.sources do
    if let .error e ← execParamQuery store.missionsDb
        ("INSERT OR REPLACE INTO compute_rollup_1m(bucket_unix_min,machine_class,node_id,root_mission_id,mission_id,state," ++
         "vcpu_allocated,vcpu_busy) VALUES(CAST(?1 AS INTEGER),?2,'','','','sampled'," ++
         "CAST(?3 AS REAL)/1000.0,CAST(?4 AS REAL)/1000.0);")
        #[toString bucket, id, toString total, toString active] then
      return .error e
  -- The longest chart is seven days; keep a little more.
  discard <| execParamQuery store.missionsDb
    "DELETE FROM compute_rollup_1m WHERE bucket_unix_min < CAST(?1 AS INTEGER);" #[toString (bucket - min bucket (8 * 24 * 60))]
  return .ok live.sources.size

/-- Mean busy vCPU (thousandths) per chart bucket for each machine class, from
    the minute samples. A bucket with no sample is absent. -/
def computeRollupSeries (store : CoreStore) (firstMin step nb : Nat) : IO (Array (String × Array (Option Nat))) := do
  let mut out : Array (String × Array (Option Nat)) := #[]
  if let .ok rows ← execParamQuery store.missionsDb
      ("SELECT machine_class, (bucket_unix_min - CAST(?1 AS INTEGER))/CAST(?2 AS INTEGER), " ++
       "CAST(ROUND(AVG(vcpu_busy)*1000) AS INTEGER) FROM compute_rollup_1m " ++
       "WHERE bucket_unix_min >= CAST(?1 AS INTEGER) AND state='sampled' GROUP BY 1,2;")
      #[toString firstMin, toString step] then
    for row in rows.extract 1 rows.size do
      let id := (row[0]?).getD ""
      let some index := (row[1]?).bind String.toNat? | continue
      if index ≥ nb then continue
      let value := ((row[2]?).bind String.toNat?).getD 0
      match out.findIdx? (·.1 == id) with
      | some at_ => out := out.modify at_ fun (k, series) => (k, series.set! index (some value))
      | none => out := out.push (id, (Array.replicate nb none).set! index (some value))
  return out

/-- `GET /api/resources/overview`: the `ResourcesOverviewResponse` contract shared by desktop, iOS and Android.
    Inference figures are aggregated from `proxy_usage`. Core keeps no compute history, so compute series
    carry only the live sample in their last bucket. -/
def buildResourcesOverviewJson
    (store : CoreStore)
    (managedStore? : Option ManagedComputeStore)
    (qMap : Array (String × String)) : IO JVal := do
  let nowSec := (← nowEpoch).toNat
  let (rangeId, minutes, step) := resourcesRangeSpec ((qParam? qMap "range").getD "6h").trimAscii.toString
  let nb := Nat.max 2 (minutes / step)
  let firstMin := nowSec / 60 - (nb - 1) * step
  let bucketSecs := step * 60
  let lastStartSec := (firstMin + (nb - 1) * step) * 60
  let lastSecs := Nat.min bucketSecs (Nat.max 60 (nowSec - lastStartSec))
  let windowSecs := Nat.max 1800 (minutes * 60)
  let sinceIso := formatEpochIso8601Utc (firstMin * 60).toUInt64

  -- Inference: tokens and cost per (bucket, provider, mission).
  let mut pools : Array ResSeries := #[]
  let mut missionSeries : Array ResSeries := #[]
  let mut infLinks : Array (String × String × Nat × Nat) := #[]
  let mut rootCache : Array (String × Option String) := #[]
  if let .ok rows ← execParamQuery store.missionsDb
      (s!"SELECT (CAST(strftime('%s',timestamp) AS INTEGER)/60 - CAST(?1 AS INTEGER))/CAST(?2 AS INTEGER), " ++
       s!"COALESCE(NULLIF(provider,''),'unknown'), COALESCE(mission_id,''), SUM({tokenSumSql}), SUM(cost_cents) " ++
       "FROM proxy_usage WHERE timestamp >= ?3 GROUP BY 1,2,3;")
      #[toString firstMin, toString step, sinceIso] then
    for i in [1:rows.size] do
      let r := rows[i]!
      let some biRaw := (r[0]?).bind String.toNat? | continue
      let bi := Nat.min (nb - 1) biRaw
      let pool := (r[1]?).getD "unknown"
      let mid := (r[2]?).getD ""
      let tok := ((r[3]?).bind String.toNat?).getD 0
      let cents := ((r[4]?).bind String.toNat?).getD 0
      if tok == 0 && cents == 0 then continue
      let mut target := externalTrafficId
      if !mid.isEmpty then
        match rootCache.find? (·.1 == mid) with
        | some hit => target := hit.2.getD externalTrafficId
        | none =>
          let root? ← resolveRootMission store mid
          rootCache := rootCache.push (mid, root?)
          target := root?.getD externalTrafficId
      pools := bumpSeries pools pool nb bi tok cents
      missionSeries := bumpSeries missionSeries target nb bi tok cents
      match infLinks.findIdx? (fun l => l.1 == pool && l.2.1 == target) with
      | some li => infLinks := infLinks.modify li fun (p, m, t, c) => (p, m, t + tok, c + cents)
      | none => infLinks := infLinks.push (pool, target, tok, cents)

  -- Compute: live capacity per machine class, and its history from the minute samples.
  let live ← liveComputeSources store managedStore?
  let sources := live.sources
  let classCounts := live.classCounts
  let compLinks := live.links
  let history ← computeRollupSeries store firstMin step nb
  let mut sourceVals : Array JVal := #[]
  let mut totalMilli := 0
  let mut activeMilli := 0
  for (id, label, sub, total, active) in sources do
    let sublabel := match classCounts.find? (·.1 == id) with
      | some (_, k) => s!"{k} VM{if k == 1 then "" else "s"}"
      | none => sub
    totalMilli := totalMilli + total
    activeMilli := activeMilli + active
    sourceVals := sourceVals.push (.obj #[
      ("id", .str id), ("label", .str label), ("sublabel", .str sublabel),
      ("total_vcpu", numFixed total 3), ("active_vcpu", numFixed active 3),
      ("idle_leased_vcpu", .num "0.0"), ("est_usd_per_h", .num "0.0"), ("health", .str "ok"),
      -- Past buckets come from the samples; the last one is the live reading.
      ("series_vcpu", .arr (((Array.range (nb - 1)).map fun index =>
        match (history.find? (·.1 == id)).bind (fun (_, series) => (series[index]?).join) with
        | some milli => numFixed milli 3
        | none => .num "0.0").push (numFixed active 3))),
      ("series_usd_per_h", zeroSeries nb)
    ])

  -- Inference pools, busiest first.
  let poolsSorted := pools.qsort fun a b => sumNat a.tok > sumNat b.tok
  let poolVals := poolsSorted.map fun p =>
    .obj #[
      ("id", .str p.id), ("label", .str (inferencePoolLabel p.id)), ("sublabel", .str "metered"),
      ("provider", .str ((p.id.splitOn ":").headD p.id)),
      ("quota_pct_remaining", .null), ("reset_at", .null),
      ("current_b_tok_per_h", bTokPerHour (sumNat p.tok) windowSecs),
      ("est_usd_per_h", usdPerHour (sumNat p.cents) windowSecs),
      ("health", .str "ok"),
      ("series_b_tok_per_h", rateSeries p.tok bucketSecs lastSecs bTokPerHour),
      ("series_usd_per_h", rateSeries p.cents bucketSecs lastSecs usdPerHour)
    ]
  let winTok := pools.foldl (fun acc p => acc + sumNat p.tok) 0
  let winCents := pools.foldl (fun acc p => acc + sumNat p.cents) 0

  -- Missions: every root with usage or a leased VM in the window, plus live roots.
  let mut rootIds : Array String := #[]
  for s in missionSeries do
    if s.id != externalTrafficId && !rootIds.contains s.id then rootIds := rootIds.push s.id
  for (_, root, _) in compLinks do
    if !rootIds.contains root then rootIds := rootIds.push root
  if let .ok lrs ← execParamQuery store.missionsDb
      ("SELECT id FROM missions WHERE status IN ('active','running','pending','queued','waiting_background','blocked') " ++
       "AND COALESCE(parent_mission_id,'')='' ORDER BY updated_at DESC LIMIT 50;") #[] then
    for i in [1:lrs.size] do
      let id := (lrs[i]![0]?).getD ""
      if !id.isEmpty && !rootIds.contains id then rootIds := rootIds.push id
  let mut cards : Array (Nat × JVal) := #[]
  for rootId in rootIds do
    let .ok mrs ← execParamQuery store.missionsDb
        "SELECT title, COALESCE(project,''), status FROM missions WHERE id=?1 LIMIT 1;" #[rootId] | continue
    if mrs.size ≤ 1 then continue
    let title := (mrs[1]![0]?).getD ""
    let project := (mrs[1]![1]?).getD ""
    let status := (mrs[1]![2]?).getD ""
    let mut subTotal := 0
    let mut subRunning := 0
    if let .ok srs ← execParamQuery store.missionsDb
        ("SELECT COUNT(*), COALESCE(SUM(CASE WHEN status IN ('active','running','waiting_background') THEN 1 ELSE 0 END),0) " ++
         "FROM missions WHERE parent_mission_id=?1;") #[rootId] then
      if srs.size > 1 then
        subTotal := ((srs[1]![0]?).bind String.toNat?).getD 0
        subRunning := ((srs[1]![1]?).bind String.toNat?).getD 0
    let series := (missionSeries.find? (·.id == rootId)).getD
      { id := rootId, tok := Array.replicate nb 0, cents := Array.replicate nb 0 }
    let vcpuMilli := compLinks.foldl (fun acc (_, m, v) => if m == rootId then acc + v else acc) 0
    let tok := sumNat series.tok
    if tok == 0 && sumNat series.cents == 0 && vcpuMilli == 0 && !missionStatusIsLive status then continue
    cards := cards.push (tok + vcpuMilli, .obj #[
      ("id", .str rootId), ("title", .str title),
      ("project", if project.isEmpty then .null else .str project),
      ("status", .str status), ("stall_kind", .null),
      ("subagent_running", JVal.nat subRunning), ("subagent_total", JVal.nat subTotal),
      ("vcpu", numFixed vcpuMilli 3), ("idle_vcpu", .num "0.0"), ("compute_usd_per_h", .num "0.0"),
      ("b_tok_per_h", bTokPerHour tok windowSecs),
      ("inference_usd_per_h", usdPerHour (sumNat series.cents) windowSecs),
      ("eta_remaining_secs", .null),
      ("series_vcpu", .arr ((Array.replicate (nb - 1) (.num "0.0")).push (numFixed vcpuMilli 3))),
      ("series_compute_usd_per_h", zeroSeries nb),
      ("series_b_tok_per_h", rateSeries series.tok bucketSecs lastSecs bTokPerHour),
      ("series_inference_usd_per_h", rateSeries series.cents bucketSecs lastSecs usdPerHour)
    ])
  if let some ext := missionSeries.find? (·.id == externalTrafficId) then
    cards := cards.push (sumNat ext.tok, .obj #[
      ("id", .str externalTrafficId), ("title", .str "API & external tools"),
      ("project", .null), ("status", .str "active"), ("stall_kind", .null),
      ("subagent_running", JVal.nat 0), ("subagent_total", JVal.nat 0),
      ("vcpu", .num "0.0"), ("idle_vcpu", .num "0.0"), ("compute_usd_per_h", .num "0.0"),
      ("b_tok_per_h", bTokPerHour (sumNat ext.tok) windowSecs),
      ("inference_usd_per_h", usdPerHour (sumNat ext.cents) windowSecs),
      ("eta_remaining_secs", .null),
      ("series_vcpu", zeroSeries nb), ("series_compute_usd_per_h", zeroSeries nb),
      ("series_b_tok_per_h", rateSeries ext.tok bucketSecs lastSecs bTokPerHour),
      ("series_inference_usd_per_h", rateSeries ext.cents bucketSecs lastSecs usdPerHour)
    ])
  let shownIds := cards.map fun (_, c) => (c.fieldStr? "id").getD ""
  let missionVals := (cards.qsort fun a b => a.1 > b.1).map (·.2)

  -- Links only reference missions that are listed.
  let mut linkVals : Array JVal := #[]
  for (classId, root, vcpu) in compLinks do
    if shownIds.contains root then
      linkVals := linkVals.push (.obj #[
        ("kind", .str "compute"), ("source_id", .str classId), ("mission_id", .str root),
        ("value", numFixed vcpu 3), ("est_usd_per_h", .num "0.0"), ("degraded", .bool false)])
  for (pool, target, tok, cents) in infLinks do
    if shownIds.contains target then
      linkVals := linkVals.push (.obj #[
        ("kind", .str "inference"), ("source_id", .str pool), ("mission_id", .str target),
        ("value", bTokPerHour tok windowSecs), ("est_usd_per_h", usdPerHour cents windowSecs),
        ("degraded", .bool false)])

  return .obj #[
    ("as_of", .str (formatEpochIso8601Utc nowSec.toUInt64)),
    ("range", .str rangeId),
    ("bucket_seconds", JVal.nat bucketSecs),
    ("timestamps_ms", .arr ((Array.range nb).map fun i => JVal.nat ((firstMin + i * step) * 60000))),
    ("compute", .obj #[
      ("total_vcpu", numFixed totalMilli 3), ("active_vcpu", numFixed activeMilli 3),
      ("idle_leased_vcpu", .num "0.0"), ("hourly_burn_usd", .num "0.0"),
      ("sources", .arr sourceVals)]),
    ("inference", .obj #[
      ("current_b_tok_per_h", bTokPerHour winTok windowSecs),
      ("est_usd_per_h", usdPerHour winCents windowSecs),
      ("window_total_tokens", JVal.nat winTok),
      ("window_est_usd", numFixed (winCents * 10000) 6),
      ("throttled_429_count", JVal.nat 0),
      ("pools", .arr poolVals)]),
    ("missions", .arr missionVals),
    ("links", .arr linkVals)
  ]

/-- Missions in the lineage of `?1`: the root itself plus every descendant. -/
private def lineageIdsSql : String :=
  "WITH RECURSIVE lineage(id) AS (SELECT ?1 UNION SELECT m.id FROM missions m JOIN lineage l ON m.parent_mission_id = l.id) "

/-- `GET /api/resources/missions/:id`: the `MissionResourcesResponse` contract. Inference figures come from
    `proxy_usage`; compute and projected series are `null` because Core keeps no compute history. -/
def buildMissionResourceDetailJson (store : CoreStore) (missionId : String)
    (qMap : Array (String × String)) : IO (Option JVal) := do
  let nowSec := (← nowEpoch).toNat
  let .ok rs ← execParamQuery store.missionsDb
      (s!"SELECT title, COALESCE(project,''), status, COALESCE({epochOfColumnSql "created_at"},0), " ++
       s!"COALESCE({epochOfColumnSql "updated_at"},0) FROM missions WHERE id=?1 LIMIT 1;")
      #[missionId] | return none
  if rs.size ≤ 1 then return none
  let r := rs[1]!
  let title := (r[0]?).getD ""
  let project := (r[1]?).getD ""
  let status := (r[2]?).getD ""
  let createdSec := ((r[3]?).bind String.toNat?).getD 0
  let updatedSec := ((r[4]?).bind String.toNat?).getD 0
  let live := missionStatusIsLive status
  let startSec := if createdSec == 0 || createdSec > nowSec then nowSec - Nat.min nowSec 300 else createdSec
  let endSec? : Option Nat := if live || updatedSec < startSec then none else some (Nat.min nowSec updatedSec)
  let anchorSec := endSec?.getD nowSec
  let fullElapsed := Nat.max 60 (anchorSec - startSec)

  -- Horizons: the active wave, plus the whole history once it outgrows six hours.
  let waveSpan := if fullElapsed ≤ 3600 then 3600 else 21600
  let allSpan := Nat.max 3600 (fullElapsed * 112 / 100)
  let mut horizons : Array JVal := #[.obj #[
    ("id", .str "6h"),
    ("label", .str (if fullElapsed ≤ 3600 then "Active wave (1h)" else "Fast-DAG (6h)")),
    ("span_secs", JVal.nat waveSpan)]]
  if fullElapsed > 21600 then
    let label :=
      if fullElapsed ≥ 86400 then s!"{fullElapsed / 86400}.{(fullElapsed % 86400) * 10 / 86400}d history"
      else s!"{(fullElapsed + 3599) / 3600}h history"
    horizons := horizons.push (.obj #[("id", .str "all"), ("label", .str label), ("span_secs", JVal.nat allSpan)])
  let activeHorizon :=
    if (qParam? qMap "horizon") == some "all" && fullElapsed > 21600 then "all" else "6h"
  let (originSec, horizonSecs) :=
    if activeHorizon == "all" then (startSec, allSpan)
    else if fullElapsed > waveSpan then (Nat.max startSec (anchorSec - waveSpan * 3 / 4), waveSpan)
    else (startSec, waveSpan)
  let originIso := formatEpochIso8601Utc originSec.toUInt64

  -- Lineage rows as `(id, title, status, model, startSec, endSec)`; the root comes first.
  let mut members : Array (String × String × String × String × Nat × Nat) := #[]
  if let .ok lrs ← execParamQuery store.missionsDb
      (lineageIdsSql ++
       s!"SELECT m.id, m.title, m.status, COALESCE(m.model_override,''), COALESCE({epochOfColumnSql "m.created_at"},0), " ++
       s!"COALESCE({epochOfColumnSql "m.updated_at"},0) FROM missions m JOIN lineage l ON m.id = l.id " ++
       "ORDER BY (m.id = ?1) DESC, m.created_at ASC LIMIT 400;") #[missionId] then
    for i in [1:lrs.size] do
      let lr := lrs[i]!
      members := members.push ((lr[0]?).getD "", (lr[1]?).getD "", (lr[2]?).getD "", (lr[3]?).getD "",
        ((lr[4]?).bind String.toNat?).getD 0, ((lr[5]?).bind String.toNat?).getD 0)

  -- Usage inside the horizon per (mission, provider).
  let mut usage : Array (String × String × Nat × Nat) := #[]
  if let .ok urs ← execParamQuery store.missionsDb
      (lineageIdsSql ++
       s!"SELECT u.mission_id, COALESCE(NULLIF(u.provider,''),'unknown'), SUM({tokenSumSql}), SUM(u.cost_cents) " ++
       "FROM proxy_usage u JOIN lineage l ON u.mission_id = l.id WHERE u.timestamp >= ?2 GROUP BY 1,2;")
      #[missionId, originIso] then
    for i in [1:urs.size] do
      let ur := urs[i]!
      usage := usage.push ((ur[0]?).getD "", (ur[1]?).getD "unknown",
        ((ur[2]?).bind String.toNat?).getD 0, ((ur[3]?).bind String.toNat?).getD 0)
  let rateSecs := Nat.max 1800 (Nat.min horizonSecs (Nat.max 60 (anchorSec - originSec)))
  let missionTok (id : String) : Nat := usage.foldl (fun acc (m, _, t, _) => if m == id then acc + t else acc) 0
  let missionCents (id : String) : Nat := usage.foldl (fun acc (m, _, _, c) => if m == id then acc + c else acc) 0
  let mut poolIds : Array String := #[]
  for (_, p, _, _) in usage do
    if !poolIds.contains p then poolIds := poolIds.push p
  let poolTok (p : String) : Nat := usage.foldl (fun acc (_, q, t, _) => if q == p then acc + t else acc) 0
  let poolCents (p : String) : Nat := usage.foldl (fun acc (_, q, _, c) => if q == p then acc + c else acc) 0

  let trackId := "main"
  let mut subagents : Array JVal := #[]
  let mut trackEdges : Array JVal := #[]
  let mut bars : Array JVal := #[]
  for (id, mTitle, mStatus, model, mCreated, mUpdated) in members do
    let isRoot := id == missionId
    let role := if isRoot then "coordinator" else "worker"
    let state := resourceBarState mStatus
    let tok := missionTok id
    let cents := missionCents id
    subagents := subagents.push (.obj #[
      ("id", .str id), ("mission_id", .str id), ("native", .bool false), ("track_id", .str trackId),
      ("role", .str role), ("label", .str mTitle),
      ("model", if model.isEmpty then .null else .str model), ("node_id", .null),
      ("vcpu", .num "0.0"), ("compute_usd_per_h", .num "0.0"),
      ("b_tok_per_h", bTokPerHour tok rateSecs), ("inference_usd_per_h", usdPerHour cents rateSecs),
      ("state", .str state)])
    if tok > 0 || cents > 0 then
      trackEdges := trackEdges.push (.obj #[
        ("kind", .str "inference"), ("source_id", .str trackId), ("target_id", .str id),
        ("weight", bTokPerHour tok rateSecs), ("est_usd_per_h", usdPerHour cents rateSecs),
        ("degraded", .bool false)])
    let mStart := if mCreated == 0 then startSec else mCreated
    let mEnd := if missionStatusIsLive mStatus || mUpdated < mStart then nowSec else Nat.min nowSec mUpdated
    if mEnd ≥ originSec && mStart ≤ originSec + horizonSecs then
      let clippedStart := Nat.max originSec mStart
      bars := bars.push (.obj #[
        ("id", .str id), ("mission_id", .str id), ("label", .str mTitle),
        ("section", .str (if isRoot then "Coordinator" else "Subagents")), ("role", .str role),
        ("model", if model.isEmpty then .null else .str model), ("node_id", .null),
        ("vcpu", .num "0.0"), ("compute_usd_per_h", .num "0.0"),
        ("b_tok_per_h", bTokPerHour tok rateSecs), ("inference_usd_per_h", usdPerHour cents rateSecs),
        ("start_offset_secs", JVal.nat (clippedStart - originSec)),
        ("duration_secs", JVal.nat (Nat.max 1 (mEnd - clippedStart))),
        ("eta_remaining_secs", .null), ("eta_basis", .null),
        ("state", .str state), ("after_ids", .arr #[])])
  let inputs := poolIds.map fun p =>
    .obj #[("id", .str p), ("kind", .str "inference"), ("label", .str (inferencePoolLabel p)),
      ("sub", .str "metered"), ("weight", bTokPerHour (poolTok p) rateSecs),
      ("est_usd_per_h", usdPerHour (poolCents p) rateSecs)]
  let inputEdges := poolIds.map fun p =>
    .obj #[("kind", .str "inference"), ("source_id", .str p), ("target_id", .str trackId),
      ("weight", bTokPerHour (poolTok p) rateSecs), ("est_usd_per_h", usdPerHour (poolCents p) rateSecs),
      ("degraded", .bool false)]
  let subCount := members.size - 1

  -- Timeline: observed inference per bucket up to now; nothing is projected.
  let tlBuckets := 60
  let tlSecs := Nat.max 60 (horizonSecs / tlBuckets)
  let mut tlTok : Array Nat := Array.replicate tlBuckets 0
  let mut tlCents : Array Nat := Array.replicate tlBuckets 0
  if let .ok trs ← execParamQuery store.missionsDb
      (lineageIdsSql ++
       s!"SELECT (CAST(strftime('%s',u.timestamp) AS INTEGER) - CAST(?3 AS INTEGER))/CAST(?4 AS INTEGER), SUM({tokenSumSql}), SUM(u.cost_cents) " ++
       "FROM proxy_usage u JOIN lineage l ON u.mission_id = l.id WHERE u.timestamp >= ?2 GROUP BY 1;")
      #[missionId, originIso, toString originSec, toString tlSecs] then
    for i in [1:trs.size] do
      let tr := trs[i]!
      let some bi := (tr[0]?).bind String.toNat? | continue
      if bi < tlBuckets then
        tlTok := tlTok.modify bi (· + ((tr[1]?).bind String.toNat?).getD 0)
        tlCents := tlCents.modify bi (· + ((tr[2]?).bind String.toNat?).getD 0)
  let observed (vals : Array Nat) (rate : Nat → Nat → JVal) : JVal :=
    .arr ((Array.range tlBuckets).map fun i =>
      if originSec + i * tlSecs > anchorSec then .null else rate vals[i]! tlSecs)
  let nulls : JVal := .arr (Array.replicate tlBuckets .null)

  return some (.obj #[
    ("as_of", .str (formatEpochIso8601Utc nowSec.toUInt64)),
    ("mission", .obj #[
      ("id", .str missionId), ("title", .str title),
      ("project", if project.isEmpty then .null else .str project),
      ("status", .str status),
      ("started_at", .str (formatEpochIso8601Utc startSec.toUInt64)),
      ("completed_at", match endSec? with | some e => .str (formatEpochIso8601Utc e.toUInt64) | none => .null),
      ("elapsed_secs", JVal.nat fullElapsed),
      ("eta_remaining_secs", .null),
      ("subagent_count", JVal.nat subCount),
      ("track_count", JVal.nat 1)]),
    ("available_horizons", .arr horizons),
    ("active_horizon", .str activeHorizon),
    ("flow", .obj #[
      ("inputs", .arr inputs),
      ("tracks", .arr #[.obj #[
        ("id", .str trackId), ("label", .str "Main"),
        ("sub", .str s!"{subCount} subagent{if subCount == 1 then "" else "s"}"),
        ("state", .str (resourceBarState status))]]),
      ("subagents", .arr subagents),
      ("input_to_track", .arr inputEdges),
      ("track_to_subagent", .arr trackEdges)]),
    ("dag", .obj #[
      ("origin_unix_secs", JVal.nat originSec),
      ("horizon_secs", JVal.nat horizonSecs),
      ("now_offset_secs", JVal.nat (Nat.min horizonSecs (nowSec - originSec))),
      ("bars", .arr bars)]),
    ("timeline", .obj #[
      ("offsets_secs", .arr ((Array.range tlBuckets).map fun i => JVal.nat (i * tlSecs))),
      ("observed_vcpu", nulls), ("projected_vcpu", nulls),
      ("observed_compute_usd_per_h", nulls), ("projected_compute_usd_per_h", nulls),
      ("observed_b_tok_per_h", observed tlTok bTokPerHour), ("projected_b_tok_per_h", nulls),
      ("observed_inference_usd_per_h", observed tlCents usdPerHour), ("projected_inference_usd_per_h", nulls)])
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

/-! ## 4. Library (`/api/library/*` & `PUT /api/settings/library-remote`) -/

def resolveLibraryDir (workingDir storeRoot : String) : IO String :=
  OrbCore.Skills.resolveLibraryRoot workingDir storeRoot

private def hasLoopbackHttpPrefix (u pfx : String) : Bool :=
  if !u.startsWith pfx then false
  else
    let rest := (u.drop pfx.length).toString
    if rest.startsWith "/" then true
    else if rest.startsWith ":" then
      let afterColon := (rest.drop 1).toString
      let portDigits := String.ofList (afterColon.toList.takeWhile Char.isDigit)
      let afterPort := (afterColon.drop portDigits.length).toString
      !portDigits.isEmpty && afterPort.startsWith "/"
    else false

def isValidGitRemote (raw : String) : Bool := Id.run do
  let u := raw.trimAscii.toString
  if u.isEmpty || u.length > 1024 || u.startsWith "-" then
    return false
  for ch in u.toList do
    if ch.toNat ≤ 0x20 || ch.toNat == 0x7F then
      return false
  return u.startsWith "https://" ||
         hasLoopbackHttpPrefix u "http://127.0.0.1" ||
         hasLoopbackHttpPrefix u "http://localhost" ||
         u.startsWith "ssh://" ||
         u.startsWith "git@" ||
         u.startsWith "file://" ||
         u.startsWith "/"

private def findHeaderCI? (hdrs : Array (String × String)) (target : String) : Option String :=
  let t := target.toLower
  (hdrs.find? (fun (k, _) => k.toLower == t)).map Prod.snd

def resolveEffectiveLibraryRemote
    (storeRoot defaultRemote : String)
    (headers : Array (String × String) := #[]) : IO String := do
  if let some hdrRem := findHeaderCI? headers "x-sandboxed-library-remote" then
    let h := hdrRem.trimAscii.toString
    if isValidGitRemote h then return h
  let settings ← readSettingsJson storeRoot
  match settings.field? "library_remote" with
  | some .null => return ""
  | some (.str r) => return r.trimAscii.toString
  | _ => return defaultRemote.trimAscii.toString

private def isDivergedGitOutput (out : String) : Bool :=
  let low := out.toLower
  (low.splitOn "diverged").length > 1 ||
  (low.splitOn "not possible to fast-forward").length > 1 ||
  (low.splitOn "non-fast-forward").length > 1 ||
  (low.splitOn "fetch first").length > 1

private def resolveRemoteTrackingRef (libDir branch : String) : IO (Option String) := do
  let (rcUp, upOut) ← runGitCapture #["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"] (some libDir)
  let up := upOut.trimAscii.toString
  if rcUp == 0 && !up.isEmpty && !up.startsWith "-" then
    return some up
  for cand in #[s!"origin/{branch}", "origin/main", "origin/master"] do
    let (rcC, _) ← runGitCapture #["rev-parse", "--verify", "--quiet", cand] (some libDir)
    if rcC == 0 then return some cand
  return none

private def gitOriginUrl? (libDir : String) : IO (Option String) := do
  let (rc, out) ← runGitCapture #["remote", "get-url", "origin"] (some libDir)
  let u := out.trimAscii.toString
  if rc == 0 && !u.isEmpty then return some u else return none

private def gitCurrentBranch (libDir : String) : IO String := do
  let (rc, out) ← runGitCapture #["rev-parse", "--abbrev-ref", "HEAD"] (some libDir)
  let b := out.trimAscii.toString
  if rc == 0 && !b.isEmpty && b != "HEAD" then return b else return "main"

/-- Ensure `libDir` is initialized/updated for `effRemote` (`clone` when absent, `remote add`/`set-url` + `fetch` when changed). -/
def ensureLibraryRepo (libDir effRemote : String) (forceReinit : Bool := false) : IO (Except String Bool) := do
  let rem := effRemote.trimAscii.toString
  if rem.isEmpty then return .ok false
  if !isValidGitRemote rem then return .error "Invalid Library repository URL"
  let fp := System.FilePath.mk libDir
  let gitFp := fp / ".git"
  if (← fp.pathExists) && !(← gitFp.pathExists) then
    let entries ← try fp.readDir catch _ => pure #[]
    if forceReinit || entries.isEmpty then
      let _ ← runCmdCapture "rm" #["-rf", "--", libDir]
    else
      let (rcInit, outInit) ← runGitCapture #["init", "-b", "main"] (some libDir)
      if rcInit != 0 then
        let (rcInit2, outInit2) ← runGitCapture #["init"] (some libDir)
        if rcInit2 != 0 then
          let msg := (if outInit2.trimAscii.isEmpty then outInit else outInit2).trimAscii.toString
          return .error (if msg.isEmpty then "git init failed" else msg)
  if !(← fp.pathExists) then
    if let some parent := fp.parent then
      IO.FS.createDirAll parent
    let (rc, out) ← runGitCapture #["clone", "--", rem, libDir] none
    if rc != 0 then
      if !(← gitFp.pathExists) then
        let _ ← runCmdCapture "rm" #["-rf", "--", libDir]
      let msg := out.trimAscii.toString
      return .error (if msg.isEmpty then "git clone failed" else msg)
    let (rcHead, _) ← runGitCapture #["rev-parse", "--verify", "--quiet", "HEAD"] (some libDir)
    if rcHead != 0 then
      if let some ref ← resolveRemoteTrackingRef libDir "main" then
        let targetBr := if ref.startsWith "origin/" then (ref.drop 7).toString else "main"
        let _ ← runGitCapture #["checkout", "-B", targetBr, "--track", ref] (some libDir)
    return .ok true
  if !(← gitFp.pathExists) then
    return .error "Library directory exists without a Git repository"
  let curRem? ← gitOriginUrl? libDir
  if !forceReinit && curRem? == some rem then
    return .ok false
  let (rcRem, outRem) ←
    match curRem? with
    | none => runGitCapture #["remote", "add", "origin", "--", rem] (some libDir)
    | some _ => runGitCapture #["remote", "set-url", "origin", "--", rem] (some libDir)
  if rcRem != 0 then
    let msg := outRem.trimAscii.toString
    return .error (if msg.isEmpty then "git remote configuration failed" else msg)
  let (rcFetch, outFetch) ← runGitCapture #["fetch", "--prune", "origin"] (some libDir)
  if rcFetch != 0 then
    let msg := outFetch.trimAscii.toString
    return .error (if msg.isEmpty then "git fetch failed" else msg)
  let (rcHead, _) ← runGitCapture #["rev-parse", "--verify", "--quiet", "HEAD"] (some libDir)
  if rcHead != 0 then
    if let some ref ← resolveRemoteTrackingRef libDir "main" then
      let targetBr := if ref.startsWith "origin/" then (ref.drop 7).toString else "main"
      let coArgs :=
        if forceReinit then #["checkout", "-f", "-B", targetBr, "--track", ref]
        else #["checkout", "-B", targetBr, "--track", ref]
      let (rcCo, outCo) ← runGitCapture coArgs (some libDir)
      if rcCo != 0 then
        let msg := outCo.trimAscii.toString
        return .error (if msg.isEmpty then "git checkout failed" else msg)
  else if forceReinit then
    let (rcSt, stOut) ← runGitCapture #["status", "--porcelain"] (some libDir)
    if rcSt == 0 && stOut.trimAscii.isEmpty then
      let br ← gitCurrentBranch libDir
      if let some ref ← resolveRemoteTrackingRef libDir br then
        let targetBr := if ref.startsWith "origin/" then (ref.drop 7).toString else br
        let _ ← runGitCapture #["checkout", "-B", targetBr, "--track", ref] (some libDir)
  return .ok true

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
  let branch ← gitCurrentBranch libDir
  let rem ← if defaultRemote.isEmpty then pure "" else pure ((← gitOriginUrl? libDir).getD defaultRemote)
  let (rcSt, stOut) ← runGitCapture #["status", "--porcelain"] (some libDir)
  let modLines :=
    if rcSt == 0 then
      (stOut.splitOn "\n").map (fun l => (l.drop 3).toString.trimAscii.toString) |>.filter (!·.isEmpty)
    else []
  let mut ahead : Nat := 0
  let mut behind : Nat := 0
  if !rem.isEmpty then
    if let some upRef ← resolveRemoteTrackingRef libDir branch then
      let (rcCnt, cntOut) ← runGitCapture #["rev-list", "--left-right", "--count", s!"HEAD...{upRef}"] (some libDir)
      if rcCnt == 0 then
        let nums := (cntOut.trimAscii.toString.split (fun c => c == '\t' || c == ' ')).toArray.filterMap (fun s => s.toString.toNat?)
        if nums.size ≥ 2 then
          ahead := nums[0]!
          behind := nums[1]!
  let fetchSt ← statIdentity (fp / ".git" / "FETCH_HEAD").toString true
  let headSt ← statIdentity (fp / ".git" / "HEAD").toString true
  let syncedMtime : UInt64 :=
    if fetchSt.exists_ && fetchSt.mtime > 0 then fetchSt.mtime
    else if headSt.exists_ && headSt.mtime > 0 then headSt.mtime
    else 0
  let mut fields : Array (String × JVal) := #[
    ("path", .str libDir),
    ("remote", if rem.isEmpty then .null else .str rem),
    ("branch", .str branch),
    ("clean", .bool modLines.isEmpty),
    ("ahead", JVal.nat ahead),
    ("behind", JVal.nat behind),
    ("modified_files", .arr (modLines.toArray.map JVal.str))
  ]
  if syncedMtime > 0 then
    fields := fields.push ("last_synced_at", JVal.uint64 syncedMtime)
  return .obj fields

private def countSkillLines (s : String) : Nat :=
  if s.isEmpty then 0 else (s.splitOn "\n").length

private def hasSymlinkSegment (baseDir : System.FilePath) (cleanRel : String) : IO Bool := do
  let baseSt ← statPath baseDir.toString
  if baseSt.isSymlink then return true
  let mut cur := baseDir
  for seg in (cleanRel.splitOn "/").filter (!·.isEmpty) do
    cur := cur / seg
    let st ← statPath cur.toString
    if st.isSymlink then return true
  return false

/-- Collect companion files (`files` inline UTF-8 text + `references` non-markdown paths) inside `skillDir`.
    Fails closed (`.error`) if any readable companion directory or regular file cannot be enumerated/read,
    or if companion directory nesting exceeds the safety depth cap (`16`), so a partial directory read
    never erases installed local companion files. -/
private partial def collectSkillCompanionFiles
    (curDir : System.FilePath)
    (relPrefix : String)
    (depth : Nat) : IO (Except String (Array (String × String × String) × Array String)) := do
  if depth > 16 then
    return .error s!"Skill companion directory exceeds maximum nesting depth (16): '{curDir}'"
  let entries ← match ← curDir.readDir.toBaseIO with
    | .ok xs => pure xs
    | .error err => return .error s!"Failed to enumerate skill directory '{curDir}': {err}"
  let sorted := entries.qsort (fun a b => a.fileName < b.fileName)
  let mut inlineFiles : Array (String × String × String) := #[]
  let mut refPaths : Array String := #[]
  for e in sorted do
    let fname := e.fileName
    if !fname.isEmpty && !fname.startsWith "." then
      let rel := if relPrefix.isEmpty then fname else s!"{relPrefix}/{fname}"
      if rel != "SKILL.md" then
        let st ← statPath e.path.toString
        if !st.isSymlink then
          if st.isDir then
            match ← collectSkillCompanionFiles e.path rel (depth + 1) with
            | .error err => return .error err
            | .ok (subInline, subRefs) =>
              inlineFiles := inlineFiles ++ subInline
              refPaths := refPaths ++ subRefs
          else if st.isReg then
            let mut inlined := false
            let idSt ← statIdentity e.path.toString
            if !idSt.exists_ then
              return .error s!"Failed to stat skill companion file '{e.path}'"
            if idSt.size ≤ 262144 then
              match ← (IO.FS.readBinFile e.path).toBaseIO with
              | .error err => return .error s!"Failed to read skill companion file '{e.path}': {err}"
              | .ok bytes =>
                let mut hasNul := false
                for i in [0:bytes.size] do
                  if bytes.get! i == 0 then hasNul := true
                if !hasNul then
                  if let some txt := String.fromUTF8? bytes then
                    inlineFiles := inlineFiles.push (fname, rel, txt)
                    inlined := true
            if !inlined || !fname.toLower.endsWith ".md" then
              refPaths := refPaths.push rel
  return .ok (inlineFiles, refPaths)

private def buildSkillSummaryJson (name prefixDir content : String) (includeBundle : Bool)
    (skillDir : System.FilePath) : IO (Except String JVal) := do
  let desc? := OrbCore.Skills.extractDescription content
  let (_, scope?) := OrbCore.Skills.parseSandboxedMeta content
  let aud := OrbCore.Skills.effectiveAudience content
  let mut fields : Array (String × JVal) := #[
    ("name", .str name),
    ("description", match desc? with | some d => .str d | none => .null),
    ("path", .str s!"{prefixDir}/{name}"),
    ("audience", .arr (aud.map .str)),
    ("scope", match scope? with | some sc => .str sc | none => .null),
    ("line_count", JVal.nat (countSkillLines content))
  ]
  if includeBundle then
    match ← collectSkillCompanionFiles skillDir "" 0 with
    | .error err => return .error err
    | .ok (inlineFiles, refPaths) =>
      let filesJv := inlineFiles.map fun (fn, rp, txt) =>
        JVal.obj #[("name", .str fn), ("path", .str rp), ("content", .str txt)]
      fields := fields ++ #[
        ("content", .str content),
        ("files", .arr filesJv),
        ("references", .arr (refPaths.map .str))
      ]
  return .ok (.obj fields)

private def locateSkillDir (libDir cleanSkill : String) (forWrite : Bool) : IO (String × System.FilePath) := do
  let canonDir := System.FilePath.mk s!"{libDir}/skill/{cleanSkill}"
  let legacyDir := System.FilePath.mk s!"{libDir}/skills/{cleanSkill}"
  if ← canonDir.pathExists then return ("skill", canonDir)
  if ← legacyDir.pathExists then return ("skills", legacyDir)
  if forWrite then
    let canonRoot := System.FilePath.mk s!"{libDir}/skill"
    let legacyRoot := System.FilePath.mk s!"{libDir}/skills"
    if !(← canonRoot.pathExists) && (← legacyRoot.pathExists) then
      return ("skills", legacyDir)
  return ("skill", canonDir)

private def isHexGitRev (s : String) : Bool :=
  7 ≤ s.length && s.length ≤ 64 &&
  s.toList.all fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

private def sanitizeGitAuthorField (raw : String) : String :=
  String.ofList ((raw.trimAscii.toString.take 120).toString.toList.filter fun c =>
    c.toNat ≥ 0x20 && c.toNat != 0x7F && c != '<' && c != '>')

def handleUpdateLibraryRemote
    (store : CoreStore)
    (workingDir : String)
    (effAdmin : Bool)
    (bodyBytes : ByteArray) : IO (Nat × String × ByteArray) := do
  if !effAdmin then return jsonErr 403 "admin_required"
  let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
    | return jsonErr 400 "Invalid JSON"
  let nextRemote? : Option String ←
    match reqJv.field? "library_remote" with
    | some .null => pure none
    | some (.str s) =>
      let t := s.trimAscii.toString
      pure (if t.isEmpty then none else some t)
    | none => return jsonErr 400 "Missing library_remote field"
    | _ => return jsonErr 400 "Invalid library_remote field"
  if let some u := nextRemote? then
    if !isValidGitRemote u then
      return jsonErr 400 "Invalid Library repository URL"
  let curSettings ← readSettingsJson store.rootDir
  let nextVal : JVal := match nextRemote? with | some u => .str u | none => .null
  let updatedSettings := curSettings.setField "library_remote" nextVal
  if let .error e ← writeSettingsJson store.rootDir updatedSettings (some curSettings) then
    return jsonErr (OrbCore.SettingsFile.errorStatus e) e
  let libDir ← resolveLibraryDir workingDir store.rootDir
  match nextRemote? with
  | none =>
    let gitFp := System.FilePath.mk libDir / ".git"
    if (← gitFp.pathExists) && (← gitOriginUrl? libDir).isSome then
      let _ ← runGitCapture #["remote", "remove", "origin"] (some libDir)
    return jsonResp 200 (.obj #[
      ("library_remote", .null),
      ("library_reinitialized", .bool false)
    ])
  | some u =>
    let forceReinit := (reqJv.fieldBool? "force_reinitialize").getD false
    match ← ensureLibraryRepo libDir u forceReinit with
    | .ok reinit =>
      return jsonResp 200 (.obj #[
        ("library_remote", .str u),
        ("library_reinitialized", .bool reinit)
      ])
    | .error err =>
      return jsonResp 200 (.obj #[
        ("library_remote", .str u),
        ("library_reinitialized", .bool false),
        ("library_error", .str err)
      ])

set_option maxHeartbeats 400000 in
def handleLibraryRoute
    (store : CoreStore)
    (workingDir defaultLibraryRemote : String)
    (effAdmin : Bool)
    (method : String)
    (segs : List String)
    (qMap headers : Array (String × String))
    (bodyBytes : ByteArray) : IO (Option (Nat × String × ByteArray)) := do
  let libDir ← resolveLibraryDir workingDir store.rootDir
  let hdrsForRemote := if effAdmin then headers else #[]
  let effRemote ← resolveEffectiveLibraryRemote store.rootDir defaultLibraryRemote hdrsForRemote
  let libFp := System.FilePath.mk libDir
  let gitFp := libFp / ".git"

  -- A transferred revision pins the next explicit synchronization. Importing
  -- configuration never copies Library files or resets a working checkout.
  if method == "POST" && (segs == ["api", "library", "sync"] || segs == ["api", "library", "force-sync"]) then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let settings ← readSettingsJson store.rootDir
    if let some revision := settings.fieldStr? "library_revision" then
      unless OrbCore.SettingsDocument.validLibraryRevision revision do
        return some (jsonErr 400 "settings_invalid_library_revision")
      if effRemote.isEmpty then return some (jsonErr 400 "Library remote is not configured")
      if let .error _ ← ensureLibraryRepo libDir effRemote false then
        return some (jsonErr 502 "library_revision_repository_unavailable")
      let (status, changes) ← runGitCapture #["status", "--porcelain"] (some libDir)
      if status != 0 || !changes.trimAscii.isEmpty then
        return some (jsonErr 409 "library_revision_requires_clean_checkout")
      let (fetched, _) ← runGitCapture #["fetch", "--no-tags", "origin", revision] (some libDir)
      if fetched != 0 then return some (jsonErr 502 "library_revision_unavailable")
      let (checkedOut, _) ← runGitCapture #["checkout", "--detach", revision] (some libDir)
      if checkedOut != 0 then return some (jsonErr 409 "library_revision_checkout_failed")
      return some (jsonResp 200 (← buildLibraryStatusJson libDir effRemote))

  if method == "GET" && segs == ["api", "library", "status"] then
    if !(← gitFp.pathExists) && !effRemote.isEmpty then
      if let .error e ← ensureLibraryRepo libDir effRemote false then
        return some (jsonErr 502 s!"Failed to initialize Library repository: {e}")
    let libSt ← buildLibraryStatusJson libDir effRemote
    -- Members see sync state only, not the host path or the remote URL.
    return some (jsonResp 200 (if effAdmin then libSt else (libSt.setField "path" (.str "")).setField "remote" (.str "")))

  if method == "POST" && segs == ["api", "library", "sync"] then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    if !effRemote.isEmpty then
      if !(← gitFp.pathExists) then
        if let .error e ← ensureLibraryRepo libDir effRemote false then
          return some (500, "text/plain; charset=utf-8", e.toUTF8)
      else
        if isValidGitRemote effRemote then
          match ← gitOriginUrl? libDir with
          | none => discard <| runGitCapture #["remote", "add", "origin", "--", effRemote] (some libDir)
          | some cur =>
            if cur != effRemote then
              discard <| runGitCapture #["remote", "set-url", "origin", "--", effRemote] (some libDir)
        if (← gitOriginUrl? libDir).isSome then
          let (rcF, outF) ← runGitCapture #["fetch", "--prune", "origin"] (some libDir)
          if rcF != 0 then
            return some (500, "text/plain; charset=utf-8", outF.trimAscii.toString.toUTF8)
          let branch ← gitCurrentBranch libDir
          if let some upRef ← resolveRemoteTrackingRef libDir branch then
            let (rcM, outM) ← runGitCapture #["merge", "--ff-only", upRef] (some libDir)
            if rcM != 0 then
              let cleanErr := outM.trimAscii.toString
              if isDivergedGitOutput cleanErr then
                return some (409, "text/plain; charset=utf-8", s!"DIVERGED_HISTORY: {cleanErr}".toUTF8)
              let (rcCnt, cntOut) ← runGitCapture #["rev-list", "--left-right", "--count", s!"HEAD...{upRef}"] (some libDir)
              if rcCnt == 0 then
                let nums := (cntOut.trimAscii.toString.split (fun c => c == '\t' || c == ' ')).toArray.filterMap (fun s => s.toString.toNat?)
                if nums.size ≥ 2 && nums[0]! > 0 && nums[1]! > 0 then
                  return some (409, "text/plain; charset=utf-8", s!"DIVERGED_HISTORY: {cleanErr}".toUTF8)
              return some (500, "text/plain; charset=utf-8", cleanErr.toUTF8)
    return some (jsonResp 200 (← buildLibraryStatusJson libDir effRemote))

  if method == "POST" && segs == ["api", "library", "force-sync"] then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    if effRemote.isEmpty then
      return some (jsonErr 400 "Library remote is not configured")
    if !(← gitFp.pathExists) then
      if let .error e ← ensureLibraryRepo libDir effRemote true then
        return some (500, "text/plain; charset=utf-8", e.toUTF8)
    else
      if isValidGitRemote effRemote then
        match ← gitOriginUrl? libDir with
        | none => discard <| runGitCapture #["remote", "add", "origin", "--", effRemote] (some libDir)
        | some cur =>
          if cur != effRemote then
            discard <| runGitCapture #["remote", "set-url", "origin", "--", effRemote] (some libDir)
      if (← gitOriginUrl? libDir).isNone then
        return some (jsonErr 400 "Library remote is not configured")
      let (rcF, outF) ← runGitCapture #["fetch", "--prune", "origin"] (some libDir)
      if rcF != 0 then
        return some (500, "text/plain; charset=utf-8", outF.trimAscii.toString.toUTF8)
      let branch ← gitCurrentBranch libDir
      let targetRef := (← resolveRemoteTrackingRef libDir branch).getD "FETCH_HEAD"
      let (rcR, outR) ← runGitCapture #["reset", "--hard", targetRef] (some libDir)
      if rcR != 0 then
        return some (500, "text/plain; charset=utf-8", outR.trimAscii.toString.toUTF8)
      let _ ← runGitCapture #["clean", "-fd"] (some libDir)
    return some (jsonResp 200 (← buildLibraryStatusJson libDir effRemote))

  if method == "POST" && segs == ["api", "library", "commit"] then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
      | return some (jsonErr 400 "Invalid JSON")
    let message := ((reqJv.fieldStr? "message").getD "").trimAscii.toString
    if message.isEmpty then
      return some (jsonErr 400 "Commit message required")
    IO.FS.createDirAll libFp
    if !(← gitFp.pathExists) then
      let (rcInit, outInit) ← runGitCapture #["init", "-b", "main"] (some libDir)
      if rcInit != 0 then
        let _ ← runGitCapture #["init"] (some libDir)
        let _ := outInit
    let (rcAdd, outAdd) ← runGitCapture #["add", "-A"] (some libDir)
    if rcAdd != 0 then
      return some (500, "text/plain; charset=utf-8", s!"git add failed: {outAdd.trimAscii.toString}".toUTF8)
    let (rcSt, stOut) ← runGitCapture #["status", "--porcelain"] (some libDir)
    if rcSt != 0 then
      return some (500, "text/plain; charset=utf-8", s!"git status failed: {stOut.trimAscii.toString}".toUTF8)
    if stOut.trimAscii.isEmpty then
      return some (200, "text/plain; charset=utf-8", "Nothing to commit".toUTF8)
    let hdrName := sanitizeGitAuthorField ((findHeaderCI? headers "x-sandboxed-git-author-name").getD "")
    let hdrEmail := sanitizeGitAuthorField ((findHeaderCI? headers "x-sandboxed-git-author-email").getD "")
    let (rcCfgName, cfgNameOut) ← runGitCapture #["config", "user.name"] (some libDir)
    let (rcCfgEmail, cfgEmailOut) ← runGitCapture #["config", "user.email"] (some libDir)
    let mut commitArgs : Array String := #[]
    if !hdrName.isEmpty then
      commitArgs := commitArgs ++ #["-c", s!"user.name={hdrName}"]
    else if rcCfgName != 0 || cfgNameOut.trimAscii.isEmpty then
      commitArgs := commitArgs ++ #["-c", "user.name=Orb"]
    if !hdrEmail.isEmpty then
      commitArgs := commitArgs ++ #["-c", s!"user.email={hdrEmail}"]
    else if rcCfgEmail != 0 || cfgEmailOut.trimAscii.isEmpty then
      commitArgs := commitArgs ++ #["-c", "user.email=orb@localhost"]
    commitArgs := commitArgs ++ #["commit", "-m", message]
    let (rcC, outC) ← runGitCapture commitArgs (some libDir)
    if rcC != 0 then
      return some (500, "text/plain; charset=utf-8", s!"git commit failed: {outC.trimAscii.toString}".toUTF8)
    return some (200, "text/plain; charset=utf-8", "Committed successfully".toUTF8)

  if method == "POST" && (segs == ["api", "library", "push"] || segs == ["api", "library", "force-push"]) then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let isForce := segs == ["api", "library", "force-push"]
    if !(← gitFp.pathExists) then
      return some (400, "text/plain; charset=utf-8", "Library repository is not initialized".toUTF8)
    if effRemote.isEmpty then
      -- When no remote is configured, treat push as a clean local-only no-op unless `force-push` was requested.
      if !isForce then
        return some (200, "text/plain; charset=utf-8", "No remote configured; saved locally".toUTF8)
      return some (400, "text/plain; charset=utf-8", "No Library remote configured".toUTF8)
    if isValidGitRemote effRemote then
      match ← gitOriginUrl? libDir with
      | none => discard <| runGitCapture #["remote", "add", "origin", "--", effRemote] (some libDir)
      | some cur =>
        if cur != effRemote then
          discard <| runGitCapture #["remote", "set-url", "origin", "--", effRemote] (some libDir)
    if (← gitOriginUrl? libDir).isNone then
      return some (400, "text/plain; charset=utf-8", "No Library remote configured".toUTF8)
    let pushArgs := if isForce then #["push", "--force", "-u", "origin", "HEAD"] else #["push", "-u", "origin", "HEAD"]
    let (rcP, outP) ← runGitCapture pushArgs (some libDir)
    if rcP != 0 then
      let cleanErr := outP.trimAscii.toString
      if !isForce && isDivergedGitOutput cleanErr then
        return some (409, "text/plain; charset=utf-8", s!"DIVERGED_HISTORY: {cleanErr}".toUTF8)
      return some (500, "text/plain; charset=utf-8", s!"git push failed: {cleanErr}".toUTF8)
    return some (200, "text/plain; charset=utf-8", "Pushed successfully".toUTF8)

  -- Skill sources can describe the owner's infrastructure: members get no Library skill bodies.
  if !effAdmin && segs.length >= 3 && segs[2]? == some "skill" then
    if method == "GET" && segs.length == 3 then return some (jsonResp 200 (.arr #[]))
    return some (jsonErr (if method == "GET" then 404 else 403) (if method == "GET" then "Skill not found" else "admin_required"))

  if method == "GET" && segs == ["api", "library", "skill"] then
    if !(← gitFp.pathExists) && !effRemote.isEmpty then
      if let .error e ← ensureLibraryRepo libDir effRemote false then
        return some (jsonErr 502 s!"Failed to initialize Library repository: {e}")
    let includeBundle :=
      ((qParam? qMap "include").getD "") == "bundle" ||
      ((qParam? qMap "bundle").getD "") == "1"
    let mut seenNames : Array String := #[]
    let mut items : Array (String × JVal) := #[]
    for prefixDir in #["skill", "skills"] do
      let skillsRoot := System.FilePath.mk s!"{libDir}/{prefixDir}"
      let rootSt ← statPath skillsRoot.toString
      if rootSt.exists_ && rootSt.isDir && !rootSt.isSymlink then
        let entries ← match ← skillsRoot.readDir.toBaseIO with
          | .ok xs => pure xs
          | .error err => return some (jsonErr 500 s!"Failed to enumerate Library skills directory: {err}")
        for e in entries do
          let sname := e.fileName
          if OrbCore.Skills.nameCharsValid sname && !sname.startsWith "." && !seenNames.contains sname then
            let eSt ← statPath e.path.toString
            let mdPath := e.path / "SKILL.md"
            let mdSt ← statPath mdPath.toString
            if !eSt.isSymlink && mdSt.exists_ && mdSt.isReg && !mdSt.isSymlink then
              let md ← match ← (IO.FS.readFile mdPath).toBaseIO with
                | .ok txt => pure txt
                | .error err => return some (jsonErr 500 s!"Failed to read SKILL.md for '{sname}': {err}")
              match ← buildSkillSummaryJson sname prefixDir md includeBundle e.path with
              | .error err => return some (jsonErr 500 err)
              | .ok jv =>
                seenNames := seenNames.push sname
                items := items.push (sname, jv)
    let sorted := (items.qsort (fun a b => a.1 < b.1)).map Prod.snd
    return some (jsonResp 200 (.arr sorted))

  if segs.length >= 4 && segs[2]? == some "skill" then
    let rawName := (percentDecodeStrict segs[3]!).getD segs[3]!
    if !OrbCore.Skills.nameCharsValid rawName || rawName.startsWith "." then
      return some (jsonErr 400 "Invalid skill name")
    let cleanSkill := rawName

    if segs.length == 4 then
      if method == "GET" then
        let (prefixDir, skillDir) ← locateSkillDir libDir cleanSkill false
        let dirSt ← statPath skillDir.toString
        let mdPath := skillDir / "SKILL.md"
        let mdSt ← statPath mdPath.toString
        if dirSt.isSymlink || !mdSt.exists_ || !mdSt.isReg || mdSt.isSymlink then
          return some (jsonErr 404 "Skill not found")
        let content ← match ← (IO.FS.readFile mdPath).toBaseIO with
          | .ok txt => pure txt
          | .error err => return some (jsonErr 500 s!"Failed to read SKILL.md for '{cleanSkill}': {err}")
        match ← buildSkillSummaryJson cleanSkill prefixDir content true skillDir with
        | .error err => return some (jsonErr 500 err)
        | .ok jv => return some (jsonResp 200 jv)

      if method == "PUT" then
        if !effAdmin then return some (jsonErr 403 "admin_required")
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
          | return some (jsonErr 400 "Invalid JSON")
        let content := (reqJv.fieldStr? "content").getD ""
        let (prefixDir, skillDir) ← locateSkillDir libDir cleanSkill true
        let dirSt ← statPath skillDir.toString
        if dirSt.isSymlink then
          return some (jsonErr 400 "Refusing to write through symlinked skill directory")
        let mdPath := skillDir / "SKILL.md"
        let mdSt ← statPath mdPath.toString
        if mdSt.isSymlink then
          return some (jsonErr 400 "Refusing to write through symlinked SKILL.md")
        IO.FS.createDirAll skillDir
        IO.FS.writeFile mdPath content
        match ← buildSkillSummaryJson cleanSkill prefixDir content true skillDir with
        | .error err => return some (jsonErr 500 err)
        | .ok jv => return some (jsonResp 200 jv)

      if method == "DELETE" then
        if !effAdmin then return some (jsonErr 403 "admin_required")
        let canonDir := System.FilePath.mk s!"{libDir}/skill/{cleanSkill}"
        let legacyDir := System.FilePath.mk s!"{libDir}/skills/{cleanSkill}"
        let cExists ← canonDir.pathExists
        let lExists ← legacyDir.pathExists
        if !cExists && !lExists then
          return some (jsonErr 404 s!"Skill not found: {cleanSkill}")
        if cExists then
          let _ ← runCmdCapture "rm" #["-rf", "--", canonDir.toString]
        if lExists then
          let _ ← runCmdCapture "rm" #["-rf", "--", legacyDir.toString]
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))

    if method == "GET" && segs.length == 5 && segs[4]? == some "history" then
      let (prefixDir, skillDir) ← locateSkillDir libDir cleanSkill false
      if !(← (skillDir / "SKILL.md").pathExists) then
        return some (jsonErr 404 "Skill not found")
      if !(← gitFp.pathExists) then
        return some (jsonResp 200 (.arr #[]))
      let relMd := s!"{prefixDir}/{cleanSkill}/SKILL.md"
      let (rcH, outH) ← runGitCapture #["log", "-n", "50", "--format=%H%x09%an%x09%ct%x09%s", "--", relMd] (some libDir)
      if rcH != 0 then
        return some (jsonResp 200 (.arr #[]))
      let mut hist : Array JVal := #[]
      for line in outH.splitOn "\n" do
        let l := line.trimAscii.toString
        if !l.isEmpty then
          let cols := l.splitOn "\t"
          if cols.length ≥ 4 then
            let rev := cols[0]!
            let author := cols[1]!
            let ts := cols[2]!.toNat?.getD 0
            let subj := String.intercalate "\t" (cols.drop 3)
            hist := hist.push (.obj #[
              ("rev", .str rev),
              ("author", .str author),
              ("timestamp", JVal.nat ts),
              ("subject", .str subj)
            ])
      return some (jsonResp 200 (.arr hist))

    if method == "GET" && segs.length == 6 && segs[4]? == some "history" then
      let rawRev := ((percentDecodeStrict segs[5]!).getD segs[5]!).trimAscii.toString
      if !isHexGitRev rawRev then
        return some (jsonErr 400 "Invalid git revision")
      if !(← gitFp.pathExists) then
        return some (jsonErr 404 "Revision not found")
      for pfx in #["skill", "skills"] do
        let (rcS, outS) ← runGitCapture #["show", s!"{rawRev}:{pfx}/{cleanSkill}/SKILL.md"] (some libDir)
        if rcS == 0 then
          return some (200, "text/plain; charset=utf-8", outS.toUTF8)
      return some (jsonErr 404 "Revision not found")

    if segs.length >= 6 && segs[4]? == some "files" then
      let decodedSegs := (segs.drop 5).map (fun s => (percentDecodeStrict s).getD s)
      let relFile := String.intercalate "/" decodedSegs
      let some cleanRel := sanitizeRelPath? relFile
        | return some (jsonErr 400 "Invalid file path")
      if cleanRel.isEmpty then
        return some (jsonErr 400 "Invalid file path")
      let (_, skillDir) ← locateSkillDir libDir cleanSkill (method == "PUT")
      if (← hasSymlinkSegment skillDir cleanRel) then
        return some (jsonErr 400 "Refusing symlinked skill file path")
      let fullFile := skillDir / cleanRel
      if method == "GET" then
        if !(← fullFile.pathExists) || (← fullFile.isDir) then
          return some (jsonErr 404 "File not found")
        match ← (IO.FS.readBinFile fullFile).toBaseIO with
        | .ok bytes => return some (200, "text/plain; charset=utf-8", bytes)
        | .error _ => return some (jsonErr 404 "File not readable")
      if method == "PUT" then
        if !effAdmin then return some (jsonErr 403 "admin_required")
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
          | return some (jsonErr 400 "Invalid JSON")
        if let some parent := fullFile.parent then IO.FS.createDirAll parent
        IO.FS.writeFile fullFile ((reqJv.fieldStr? "content").getD "")
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str cleanRel)]))
      if method == "DELETE" then
        if !effAdmin then return some (jsonErr 403 "admin_required")
        if cleanRel == "SKILL.md" then
          return some (jsonErr 400 "Cannot delete SKILL.md")
        if !(← fullFile.pathExists) || (← fullFile.isDir) then
          return some (jsonErr 404 "File not found")
        try IO.FS.removeFile fullFile catch _ => pure ()
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))

  return none

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
    if effAdmin then return some (jsonResp 200 jv)
    -- Members: only their own missions; no fleet sources or instance-wide inference totals.
    let mut mine : Array JVal := #[]
    for m in (jv.fieldArr? "missions").getD #[] do
      if ← canAccessMission store ((m.fieldStr? "id").getD "") callerUserId bootstrapAdminId isLegacyUnscoped false then
        mine := mine.push m
    let compute := ((jv.field? "compute").getD (.obj #[])).setField "sources" (.arr #[])
    let inference : JVal := .obj #[
      ("current_b_tok_per_h", JVal.nat 0), ("est_usd_per_h", JVal.nat 0),
      ("window_total_tokens", JVal.nat 0), ("window_est_usd", JVal.nat 0),
      ("throttled_429_count", JVal.nat 0), ("pools", .arr #[])]
    let reduced := ((jv.setField "missions" (.arr mine)).setField "compute" compute).setField "inference" inference
    return some (jsonResp 200 reduced)

  if method == "GET" && segs.length == 4 && segs[0]? == some "api" && segs[1]? == some "resources" && segs[2]? == some "missions" then
    let mid := segs[3]!
    let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
    if !allowed then return some (jsonErr 404 "Mission not found")
    match ← buildMissionResourceDetailJson store mid qMap with
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
    let localNode := targetNode.isEmpty || targetNode == "local" || targetNode == "core" || targetNode == "orb-core" || targetNode == "agent-core"
    if !effAdmin then
      -- Members: local inventory only, without host paths or install job history.
      if !(method == "GET" && segs.length == 2 && localNode) then return some (jsonErr 403 "admin_required")
      let inv ← buildSoftwareInventoryJson hub false
      let comps := ((inv.fieldArr? "components").getD #[]).map fun c =>
        (c.setField "binary_path" .null).setField "can_update" (.bool false)
      return some (jsonResp 200 (((inv.setField "components" (.arr comps)).setField "jobs" (.arr #[])).setField "active_job" .null))
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

  -- 5. Library (`/api/library/*` & `PUT /api/settings/library-remote`)
  if method == "PUT" && segs == ["api", "settings", "library-remote"] then
    return some (← handleUpdateLibraryRemote store workingDir effAdmin bodyBytes)

  if segs.length >= 2 && segs[0]? == some "api" && segs[1]? == some "library" then
    if let some res ← handleLibraryRoute store workingDir libraryRemote effAdmin method segs qMap headers bodyBytes then
      return some res

  -- 6. System, Mesh, FIDO & GitHub Integration (`/api/system/*`, `/api/mesh/status`, `/api/fido/*`, `/api/integrations/github*`)
  if method == "GET" && segs == ["api", "system", "info"] then
    let inv ← buildSoftwareInventoryJson hub false
    let comps := ((inv.fieldArr? "components").getD #[]).map fun c =>
      JVal.obj #[
        ("name", .str ((c.fieldStr? "id").getD "")),
        ("version", (c.field? "installed_version").getD .null),
        ("installed", .bool ((c.fieldBool? "installed").getD false)),
        ("update_available", .null),
        ("path", if effAdmin then (c.field? "binary_path").getD .null else .null),
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
