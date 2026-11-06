/-
  OrbNode.Runner: Worker Configuration, Live Capacity Resize (`Orb.Kernel.nodeResizeStep`),
  Bounded Log Byte-Range Slicing (`<= 256 KiB` newline-cut), and Process-Group (`-pgid`)
  Zero-Orphan Execution for `/execute`, `raw_command`, and `lean_build`.
-/
import LeanSys.Auth
import Orb.Kernel
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.Spec
import OrbNode.Posix
import OrbNode.Lease
import OrbNode.Store
import OrbNode.LeanBuild
import OrbNode.FileBrowser

namespace OrbNode.Runner

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json
open OrbNode.Spec
open OrbNode.Lease
open OrbNode.Store
open OrbNode.LeanBuild
open OrbNode.FileBrowser

structure NodeConfig where
  bindHost            : String := "127.0.0.1"
  bindPort            : UInt16 := 3088
  nodeId              : String := "local-node"
  token               : String := ""
  tokenPrevious?      : Option String := none
  workDir             : String := "/var/lib/sandboxed-node/work"
  envFile             : String := "/etc/sandboxed-node.env"
  labels              : Array String := #[]
  allowRoot           : Bool := false
  capacityTotal       : UInt32 := 1
  sideCapacity        : UInt32 := 2
  coordinatorCapacity : UInt32 := 2
  maxQueued           : Nat := 4
  maxJobSecs          : UInt64 := 14400
  minFreeDiskBytes    : UInt64 := 10 * 1024 * 1024 * 1024
  envAllowlist        : Array String := #[
    "LEAN_NUM_THREADS", "LAKE_JOBS", "TURBO_LEAN_MAX_MEMORY_MB", "TURBO_LEAN_NO_AUDIT_CACHE"
  ]
  managedAuth         : ManagedAuthConfig := {}
  deriving Repr, Inhabited

def parseBindAddr (raw : String) : String × UInt16 :=
  let s := raw.trimAscii.toString
  let parts := s.splitOn ":"
  if parts.length < 2 then
    ("127.0.0.1", 3088)
  else
    let portStr := parts.getLast!
    let host := String.intercalate ":" (parts.dropLast)
    let port := (portStr.toNat?.map (fun n => if 1 ≤ n && n ≤ 65535 then n.toUInt16 else 3088)).getD 3088
    (if host.isEmpty then "127.0.0.1" else host, port)

private def isTruthyEnv (s? : Option String) : Bool :=
  match s? with
  | some v =>
    let lv := v.trimAscii.toString.toLower
    lv == "1" || lv == "true" || lv == "yes"
  | none => false

private def parseEnvFileCapacity (envFile : String) : IO (Option UInt32) := do
  let p := System.FilePath.mk envFile
  if !(← p.pathExists) then return none
  let .ok raw ← IO.FS.readFile p |>.toBaseIO | return none
  for line in raw.splitOn "\n" do
    let trimmed := line.trimAscii.toString
    if trimmed.startsWith "SANDBOXED_NODE_CAPACITY=" ||
       trimmed.startsWith "export SANDBOXED_NODE_CAPACITY=" then
      let valRaw := (trimmed.splitOn "=").tail! |> String.intercalate "="
      let unquoted := (valRaw.trimAscii.toString.dropWhile (fun c => c == '"' || c == '\'')
        |>.dropEndWhile (fun c => c == '"' || c == '\'')).toString
      if let some n := unquoted.toNat? then
        if 1 ≤ n && n ≤ 256 then
          return some n.toUInt32
  return none

def loadConfigFromEnv : IO NodeConfig := do
  let bindRaw := (← IO.getEnv "SANDBOXED_NODE_BIND").getD "127.0.0.1:3088"
  let (host, port) := parseBindAddr bindRaw
  let nodeId := ((← IO.getEnv "SANDBOXED_NODE_ID").getD "local-node").trimAscii.toString
  let token := ((← IO.getEnv "SANDBOXED_NODE_TOKEN").getD "").trimAscii.toString
  let prev? := (← IO.getEnv "SANDBOXED_NODE_TOKEN_PREVIOUS").map (·.trimAscii.toString)
    |>.filter (fun s => !s.isEmpty)
  let workDir := ((← IO.getEnv "SANDBOXED_NODE_WORK_DIR").getD "/var/lib/sandboxed-node/work").trimAscii.toString
  let envFile := ((← IO.getEnv "SANDBOXED_NODE_ENV_FILE").getD "/etc/sandboxed-node.env").trimAscii.toString
  let labelsRaw := (← IO.getEnv "SANDBOXED_NODE_LABELS").getD ""
  let labels := (labelsRaw.splitOn ",").toArray.map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
  let allowRoot := isTruthyEnv (← IO.getEnv "SANDBOXED_NODE_ALLOW_ROOT")
  let cap := ((← IO.getEnv "SANDBOXED_NODE_CAPACITY") >>= String.toNat?).getD 1
  let capClamped : UInt32 := (max 1 (min 256 cap)).toUInt32
  let sideCap := ((← IO.getEnv "SANDBOXED_NODE_SIDE_CAPACITY") >>= String.toNat?).getD 2
  let coordCap := ((← IO.getEnv "SANDBOXED_NODE_COORDINATOR_CAPACITY") >>= String.toNat?).getD 2
  let maxQueued := ((← IO.getEnv "SANDBOXED_NODE_MAX_QUEUED") >>= String.toNat?).getD (capClamped.toNat * 4)
  let maxJobSecs := ((← IO.getEnv "SANDBOXED_NODE_MAX_JOB_SECS") >>= String.toNat?).getD 14400
  let minFreeGb := ((← IO.getEnv "SANDBOXED_NODE_MIN_FREE_GB") >>= String.toNat?).getD 10
  let allowRaw := (← IO.getEnv "SANDBOXED_NODE_ENV_ALLOWLIST").getD
    "LEAN_NUM_THREADS,LAKE_JOBS,TURBO_LEAN_MAX_MEMORY_MB,TURBO_LEAN_NO_AUDIT_CACHE"
  let allowKeys := (allowRaw.splitOn ",").toArray.map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
  let managedAuth ← loadManagedAuthFromEnv workDir
  let mut cfg : NodeConfig := {
    bindHost := host
    bindPort := port
    nodeId := if nodeId.isEmpty then "local-node" else nodeId
    token := token
    tokenPrevious? := prev?
    workDir := workDir
    envFile := envFile
    labels := labels
    allowRoot := allowRoot
    capacityTotal := capClamped
    sideCapacity := (max 1 (min 16 sideCap)).toUInt32
    coordinatorCapacity := (max 1 (min 16 coordCap)).toUInt32
    maxQueued := max 1 maxQueued
    maxJobSecs := maxJobSecs.toUInt64
    minFreeDiskBytes := minFreeGb.toUInt64 * 1024 * 1024 * 1024
    envAllowlist := allowKeys
    managedAuth := managedAuth
  }
  if let some envCap ← parseEnvFileCapacity envFile then
    cfg := { cfg with capacityTotal := envCap }
  let ovPath := System.FilePath.mk workDir / "capacity_override.json"
  if ← ovPath.pathExists then
    if let .ok raw ← IO.FS.readFile ovPath |>.toBaseIO then
      if let .ok jv := OrbBin.Json.parse raw then
        if let some c := jv.fieldNat? "capacity" then
          if 1 ≤ c && c ≤ 256 then
            cfg := { cfg with capacityTotal := c.toUInt32 }
        if let some cc := jv.fieldNat? "coordinator_capacity" then
          if 1 ≤ cc && cc ≤ 16 then
            cfg := { cfg with coordinatorCapacity := cc.toUInt32 }
  return cfg

/-! ### Bounded Log Byte-Range Slicing (`GET /jobs/:id/log?offset=N&max_bytes=M`) -/

structure LogSliceResult where
  offset     : UInt64
  nextOffset : UInt64
  logLen     : UInt64
  data       : String
  deriving Repr, BEq

/-- Slice `rawLog` from `offset` up to `clampedMax` (`4..=262144` bytes), cutting back to the
    last `\n` when not at EOF so Core never receives a split multi-byte UTF-8 line mid-stream. -/
def sliceJobLogBytes (rawLog : ByteArray) (offset : Nat) (maxBytes : Nat := 262144) : LogSliceResult := Id.run do
  let total := rawLog.size
  if offset >= total then
    return {
      offset := total.toUInt64
      nextOffset := total.toUInt64
      logLen := total.toUInt64
      data := ""
    }
  let cap := max 4 (min 262144 maxBytes)
  let rawEnd := min total (offset + cap)
  let mut cutEnd := rawEnd
  if rawEnd < total then
    let mut k := rawEnd
    while k > offset do
      k := k - 1
      if rawLog.get! k == 10 then
        cutEnd := k + 1
        break
  let sub := rawLog.extract offset cutEnd
  let text := String.fromUTF8? sub |>.getD (String.fromUTF8! (sub.foldl (fun acc b =>
    if b < 128 then acc.push b else acc.push 63) ByteArray.empty))
  return {
    offset := offset.toUInt64
    nextOffset := cutEnd.toUInt64
    logLen := total.toUInt64
    data := text
  }

/-! ### Live Process-Group Job State & Reconciler -/

structure LiveProc where
  pid         : UInt64
  startedEp   : UInt64
  timeoutSecs : UInt64
  forced      : Bool
  sideLane    : Bool
  coordLane   : Bool
  artifacts   : Array String
  cwd         : String
  deriving Repr, Inhabited

structure NodeRuntime where
  cfg            : NodeConfig
  shrinkDebt     : UInt32 := 0
  activeExecMain : UInt32 := 0
  activeExecSide : UInt32 := 0
  ledger         : Ledger
  liveProcs      : Std.HashMap String LiveProc := {}
  queueOrder     : Array String := #[]

def activeRegularCount (rt : NodeRuntime) : UInt32 :=
  rt.activeExecMain + rt.liveProcs.fold (fun acc _ lp =>
    if !lp.forced && !lp.sideLane && !lp.coordLane then acc + 1 else acc) 0

def activeSideCount (rt : NodeRuntime) : UInt32 :=
  rt.activeExecSide + rt.liveProcs.fold (fun acc _ lp => if lp.sideLane then acc + 1 else acc) 0

def activeForcedCount (rt : NodeRuntime) : UInt32 :=
  rt.liveProcs.fold (fun acc _ lp => if lp.forced then acc + 1 else acc) 0

def activeCoordCount (rt : NodeRuntime) : UInt32 :=
  rt.liveProcs.fold (fun acc _ lp => if lp.coordLane then acc + 1 else acc) 0

/-- Apply operator-authorized live capacity resize via `Orb.Kernel.nodeResizeStep` + `OrbNode.Spec`. -/
def resizeCapacity
    (rt : NodeRuntime) (targetCap : UInt32) (targetCoord? : Option UInt32)
    (persistOverride : Bool := true) :
    IO (Except String NodeRuntime) := do
  let nextCoord := targetCoord?.getD rt.cfg.coordinatorCapacity
  if verifyNodeCapacityDisk targetCap nextCoord 0 0 1 0 != 1 then
    return .error "capacity bounds rejected (capacity in 1..=256, coordinator_capacity in 1..=16)"
  let running := activeRegularCount rt
  let idle : UInt32 :=
    if rt.cfg.capacityTotal > running then rt.cfg.capacityTotal - running else 0
  let word := Orb.Kernel.nodeResizeStep 1 0 1 rt.cfg.capacityTotal rt.shrinkDebt idle targetCap 256
  let lo32 := (word &&& 0xFFFFFFFF).toUInt32
  let nextDebt := (word >>> 32).toUInt32
  if (lo32 &&& 256) == 0 then
    return .error s!"orb_node_resize_step rejected with code {lo32}"
  let nextCfg := { rt.cfg with capacityTotal := targetCap, coordinatorCapacity := nextCoord }
  if persistOverride then
    let nowTs ← nowRfc3339
    let ovJson := renderCompact (.obj #[
      ("capacity", JVal.nat targetCap.toNat),
      ("coordinator_capacity", JVal.nat nextCoord.toNat),
      ("updated_at", .str nowTs)
    ])
    let ovPath := System.FilePath.mk rt.cfg.workDir / "capacity_override.json"
    IO.FS.writeFile ovPath (ovJson ++ "\n")
  return .ok { rt with cfg := nextCfg, shrinkDebt := nextDebt }

/-- Reload capacity from `envFile` and `capacity_override.json` (`SIGHUP` handler). -/
def reloadCapacityFromFiles (rt : NodeRuntime) : IO NodeRuntime := do
  let mut targetCap := rt.cfg.capacityTotal
  let mut targetCoord := rt.cfg.coordinatorCapacity
  if let some envCap ← parseEnvFileCapacity rt.cfg.envFile then
    targetCap := envCap
  let ovPath := System.FilePath.mk rt.cfg.workDir / "capacity_override.json"
  if ← ovPath.pathExists then
    if let .ok raw ← IO.FS.readFile ovPath |>.toBaseIO then
      if let .ok jv := OrbBin.Json.parse raw then
        if let some c := jv.fieldNat? "capacity" then
          if 1 ≤ c && c ≤ 256 then targetCap := c.toUInt32
        if let some cc := jv.fieldNat? "coordinator_capacity" then
          if 1 ≤ cc && cc ≤ 16 then targetCoord := cc.toUInt32
  match ← resizeCapacity rt targetCap (some targetCoord) false with
  | .ok rt' => return rt'
  | .error _ => return rt

private def detectLeanRuntimeReady (workDir : String) : IO Bool := do
  let cachedLake := System.FilePath.mk workDir / "caches" / "elan" / "bin" / "lake"
  if ← cachedLake.pathExists then return true
  if ← (System.FilePath.mk "/opt/orb/elan/bin/lake").pathExists then return true
  let pathStr := (← IO.getEnv "PATH").getD "/usr/local/bin:/usr/bin:/bin"
  for d in (pathStr.splitOn ":").filter (·.startsWith "/") do
    let st ← statPath ((System.FilePath.mk d / "lake").toString)
    if st.exists_ && st.isReg then return true
  return false

def buildHeartbeatJson (rt : NodeRuntime) : IO JVal := do
  let st ← OrbNode.Posix.hostStats rt.cfg.workDir
  let leanReady ← detectLeanRuntimeReady rt.cfg.workDir
  let labels := if leanReady then rt.cfg.labels else rt.cfg.labels.filter (· != "lean")
  let activeReg := activeRegularCount rt
  let activeAsync := rt.liveProcs.size.toUInt32
  let capAvail : UInt32 :=
    if rt.cfg.capacityTotal > activeReg + rt.shrinkDebt then
      rt.cfg.capacityTotal - (activeReg + rt.shrinkDebt)
    else 0
  let diskWord := Orb.Kernel.nodeDiskAdmissionStep
    st.diskAvailBytes 0 rt.cfg.minFreeDiskBytes rt.cfg.minFreeDiskBytes (20 * 1024 * 1024 * 1024) 0
  let diskPinned := ((diskWord &&& 0xFFFFFFFF).toUInt32 &&& 256) == 0
  let toolchains ← listCachedToolchains rt.cfg.workDir
  let advAuth ← advertisedManagedAuth rt.cfg.managedAuth
  return .obj #[
    ("resource_history", .arr #[]),
    ("node_id", .str rt.cfg.nodeId),
    ("online", .bool true),
    ("capacity_total", JVal.nat rt.cfg.capacityTotal.toNat),
    ("capacity_available", JVal.nat capAvail.toNat),
    ("active_leases", JVal.nat rt.activeExecMain.toNat),
    ("version", .str "1.3.0-lean4"),
    ("protocol_version", JVal.nat 5),
    ("labels", .arr (labels.map .str)),
    ("cpu_total", JVal.nat st.cpuTotal.toNat),
    ("mem_total_bytes", JVal.uint64 st.memTotalBytes),
    ("mem_available_bytes", JVal.uint64 st.memAvailBytes),
    ("disk_total_bytes", JVal.uint64 st.diskTotalBytes),
    ("disk_available_bytes", JVal.uint64 st.diskAvailBytes),
    ("active_jobs", JVal.nat activeAsync.toNat),
    ("queued_jobs", JVal.nat rt.queueOrder.size),
    ("side_jobs", JVal.nat (activeSideCount rt).toNat),
    ("forced_jobs", JVal.nat (activeForcedCount rt).toNat),
    ("priority_jobs", JVal.nat (activeCoordCount rt).toNat),
    ("coordinator_capacity", JVal.nat rt.cfg.coordinatorCapacity.toNat),
    ("cached_toolchains", .arr (toolchains.map .str)),
    ("lean_runtime_ready", .bool leanReady),
    ("source_bundle_capacity", .obj #[
      ("overlay_bytes", JVal.uint64 defaultMaxSourceBundleBytes),
      ("complete_bytes", JVal.uint64 defaultMaxCompleteBundleBytes)
    ]),
    ("min_free_disk_bytes", JVal.uint64 rt.cfg.minFreeDiskBytes),
    ("disk_pressure_pinned", .bool diskPinned),
    ("managed_auth", .arr (advAuth.map .str))
  ]

private def flattenEnvKv (pairs : Array (String × String)) : Array String := Id.run do
  let mut out : Array String := Array.mkEmpty (pairs.size * 2)
  for (k, v) in pairs do
    out := out.push k |>.push v
  return out

private def mergeEnvPair (pairs : Array (String × String)) (k v : String) : Array (String × String) :=
  (pairs.filter (fun (ek, _) => ek != k)).push (k, v)

private def startQueuedJob (rt : NodeRuntime) (jid : String) (forcedOverride : Bool := false) :
    IO NodeRuntime := do
  let some rec := rt.ledger.jobs.get? jid
    | return rt
  if rec.state != .queued then return rt
  let .ok payload := OrbBin.Json.parse rec.payloadJson
    | return rt
  let kind := (payload.fieldStr? "kind").getD "raw_command"
  let missionDir := (System.FilePath.mk rt.cfg.workDir / rec.missionId).toString
  IO.FS.createDirAll missionDir
  let logPath := rec.logPath?.getD ((System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jid}.log").toString)
  let timeout := min rt.cfg.maxJobSecs ((payload.fieldUInt64? "timeout_secs").getD rt.cfg.maxJobSecs)
  let sideLane := (payload.fieldBool? "side_question").getD false
  let coordLane := (payload.fieldBool? "coordinator_priority").getD false
  let forced := forcedOverride || rec.forced
  let mut cwd := missionDir
  let mut prog := "bash"
  let mut args : Array String := #[]
  let mut envPairs : Array (String × String) := #[]
  let mut artifacts : Array String := #[]
  let nowTs ← nowRfc3339
  if kind == "lean_build" then
    let some srcObj := payload.field? "source"
      | match ← rt.ledger.updateJob jid (fun r => .ok {
            r with state := .failed, finishedAt? := some nowTs, error? := some "missing source", forced := forced
          }) with
        | .ok (l', _) => return { rt with ledger := l' }
        | .error _ => return rt
    let checkoutDir ← match ← materializeLeanCheckout rt.cfg.workDir srcObj logPath with
      | .ok d => pure d
      | .error err =>
        match ← rt.ledger.updateJob jid (fun r => .ok {
            r with state := .failed, finishedAt? := some nowTs, logPath? := some logPath,
                   error? := some err, forced := forced
          }) with
        | .ok (l', _) => return { rt with ledger := l' }
        | .error _ => return rt
    cwd := checkoutDir
    if let some cwdRelRaw := payload.fieldStr? "cwd_rel" then
      let cwdRel := (cwdRelRaw.dropWhile (· == '/') |>.dropEndWhile (· == '/')).toString
      if !cwdRel.isEmpty && relPathIsSafe cwdRel then
        let sub := System.FilePath.mk checkoutDir / cwdRel
        if !(← sub.isDir) then
          match ← rt.ledger.updateJob jid (fun r => .ok {
              r with state := .failed, finishedAt? := some nowTs,
                     error? := some s!"cwd_rel '{cwdRel}' does not exist in checkout", forced := forced
            }) with
          | .ok (l', _) => return { rt with ledger := l' }
          | .error _ => return rt
        cwd := sub.toString
    let cmdParts := ((payload.fieldArr? "command").getD #[]).filterMap JVal.asStr?
    if h : 0 < cmdParts.size then
      prog := cmdParts[0]
      args := cmdParts.extract 1 cmdParts.size
    else
      prog := "true"
    let usesFanout := prog != "turbo-lean" || args.contains "build"
    let st ← OrbNode.Posix.hostStats rt.cfg.workDir
    let repo := (srcObj.fieldStr? "repo").getD ""
    let payloadEnv := ((payload.field? "env") >>= JVal.asObj?).getD #[]
    envPairs ← buildLeanJobEnv rt.cfg.workDir repo st.cpuTotal rt.cfg.capacityTotal
      rt.cfg.envAllowlist usesFanout payloadEnv
    envPairs := mergeEnvPair envPairs "SANDBOXED_MISSION_ID" rec.missionId
    envPairs := mergeEnvPair envPairs "SANDBOXED_JOB_ID" jid
    if let some arts := payload.fieldArr? "artifacts" then
      artifacts := arts.filterMap JVal.asStr?
  else
    let cmdStr := (payload.fieldStr? "command").getD "true"
    args := #["-lc", cmdStr]
    envPairs ← prepareSharedMissionEnv rt.cfg.workDir missionDir
    envPairs := mergeEnvPair envPairs "SANDBOXED_MISSION_ID" rec.missionId
    envPairs := mergeEnvPair envPairs "SANDBOXED_JOB_ID" jid
    if let some envObj := (payload.field? "env") >>= JVal.asObj? then
      for (ek, ev) in envObj do
        if let some sv := ev.asStr? then
          envPairs := mergeEnvPair envPairs ek sv
    let reqProfiles := ((payload.fieldArr? "managed_auth").getD #[]).filterMap JVal.asStr?
    if !reqProfiles.isEmpty then
      match ← prepareManagedAuthWorkspace rt.cfg.managedAuth reqProfiles missionDir with
      | .error err =>
        match ← rt.ledger.updateJob jid (fun r => .ok {
            r with state := .failed, finishedAt? := some nowTs, error? := some err, forced := forced
          }) with
        | .ok (l', _) => return { rt with ledger := l' }
        | .error _ => return rt
      | .ok authEnv =>
        for (ak, av) in authEnv do
          envPairs := mergeEnvPair envPairs ak av
  let nowEp ← OrbNode.Posix.nowEpoch
  let envKv := flattenEnvKv envPairs
  match ← (OrbNode.Posix.spawnJobPgrp prog args envKv cwd logPath).toBaseIO with
  | .error e =>
    match ← rt.ledger.updateJob jid (fun r => .ok {
      r with state := .failed, finishedAt? := some nowTs, error? := some (toString e), forced := forced
    }) with
    | .ok (l', _) => return { rt with ledger := l' }
    | .error _ => return rt
  | .ok pid =>
    match ← rt.ledger.updateJob jid (fun r => .ok {
      r with state := .running, startedAt? := some nowTs, logPath? := some logPath, forced := forced
    }) with
    | .ok (l', _) =>
      let lp : LiveProc := {
        pid := pid
        startedEp := nowEp
        timeoutSecs := max 1 timeout
        forced := forced
        sideLane := sideLane
        coordLane := coordLane
        artifacts := artifacts
        cwd := cwd
      }
      return { rt with ledger := l', liveProcs := rt.liveProcs.insert jid lp }
    | .error _ => return rt

/-- Reap exited/timed-out process groups (`-pgid` zero-orphan kill) and dispatch eligible queued jobs. -/
def tickRuntime (rt0 : NodeRuntime) : IO NodeRuntime := do
  let mut rt := rt0
  let nowEp ← OrbNode.Posix.nowEpoch
  for (jid, lp) in rt.liveProcs.toList do
    let w ← OrbNode.Posix.pollPid lp.pid
    let done := (w &&& 1) == 1
    if done then
      let codeU32 := (w >>> 32).toUInt32
      let codeInt : Int := if codeU32 == 0xFFFFFFFF then -1 else Int.ofNat codeU32.toNat
      OrbNode.Posix.killPgrp lp.pid 9
      let arts ← collectArtifactsConfined lp.cwd lp.artifacts
      let nowTs ← nowRfc3339
      let nextState : JobState := if codeInt == 0 then .succeeded else .failed
      if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
        r with
        state := if r.state == .cancelled then .cancelled else nextState
        exitCode? := some codeInt
        finishedAt? := some nowTs
        artifacts := arts
      }) then
        rt := { rt with ledger := l' }
      rt := { rt with liveProcs := rt.liveProcs.erase jid }
      if !lp.forced && !lp.sideLane && !lp.coordLane && rt.shrinkDebt > 0 then
        rt := { rt with shrinkDebt := rt.shrinkDebt - 1 }
    else if nowEp > lp.startedEp + lp.timeoutSecs then
      OrbNode.Posix.killPgrp lp.pid 15
      OrbNode.Posix.killPgrp lp.pid 9
      discard <| OrbNode.Posix.pollPid lp.pid
      let nowTs ← nowRfc3339
      if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
        r with
        state := .failed
        exitCode? := some 124
        finishedAt? := some nowTs
        error? := some s!"job timed out after {lp.timeoutSecs}s"
      }) then
        rt := { rt with ledger := l' }
      rt := { rt with liveProcs := rt.liveProcs.erase jid }
  let mut remQueue : Array String := #[]
  for jid in rt.queueOrder do
    if let some rec := rt.ledger.jobs.get? jid then
      if rec.state == .queued then
        let .ok payload := OrbBin.Json.parse rec.payloadJson | continue
        let side := (payload.fieldBool? "side_question").getD false
        let coord := (payload.fieldBool? "coordinator_priority").getD false
        let canRun :=
          if side then activeSideCount rt < rt.cfg.sideCapacity
          else if coord then activeCoordCount rt < rt.cfg.coordinatorCapacity
          else activeRegularCount rt + rt.shrinkDebt < rt.cfg.capacityTotal
        if canRun then
          rt ← startQueuedJob rt jid false
        else
          remQueue := remQueue.push jid
  return { rt with queueOrder := remQueue }

def cancelJob (rt : NodeRuntime) (jid actor reason : String) : IO (Except String (NodeRuntime × JobRecord)) := do
  let some _cur := rt.ledger.jobs.get? jid
    | return .error "not_found"
  let nowTs ← nowRfc3339
  let cleanReason := (reason.take 256).toString
  let cleanActor :=
    if actor == "core" || actor == "operator" || actor == "startup_watchdog" || actor == "provider_error" then actor
    else "unknown"
  let cInfo : JobCancellation := { actor := cleanActor, reason := cleanReason, requestedAt := nowTs }
  if let some lp := rt.liveProcs.get? jid then
    OrbNode.Posix.killPgrp lp.pid 15
    OrbNode.Posix.killPgrp lp.pid 9
    discard <| OrbNode.Posix.pollPid lp.pid
  let nextProcs := rt.liveProcs.erase jid
  let nextQueue := rt.queueOrder.filter (· != jid)
  match ← rt.ledger.updateJob jid (fun r =>
    if r.state.isTerminal then .ok r
    else .ok { r with state := .cancelled, finishedAt? := some nowTs, cancellation? := some cInfo }) with
  | .error e => return .error e
  | .ok (l', updated) =>
    return .ok ({ rt with ledger := l', liveProcs := nextProcs, queueOrder := nextQueue }, updated)

def forceJob (rt : NodeRuntime) (jid : String) : IO (Except String (NodeRuntime × JobRecord)) := do
  let some cur := rt.ledger.jobs.get? jid
    | return .error "not_found"
  if cur.state != .queued then
    return .error "not_queued"
  if activeForcedCount rt >= 1 then
    return .error "force_slot_busy"
  let rt' ← startQueuedJob { rt with queueOrder := rt.queueOrder.filter (· != jid) } jid true
  let updated := (rt'.ledger.jobs.get? jid).getD cur
  return .ok (rt', updated)

def interruptJob (rt : NodeRuntime) (jid mode : String) : IO (Except String (NodeRuntime × JVal)) := do
  let some cur := rt.ledger.jobs.get? jid
    | return .error "not_found"
  if cur.state == .queued then
    match ← cancelJob rt jid "core" "Cancelled queued job for controller steering" with
    | .error e => return .error e
    | .ok (rt', updated) =>
      return .ok (rt', .obj #[
        ("job_id", .str jid),
        ("state", .str updated.state.asString),
        ("accepted", .bool true),
        ("signalled_pids", JVal.nat 0),
        ("deferred_until_tool_finishes", .bool false)
      ])
  if cur.state != .running then
    return .ok (rt, .obj #[
      ("job_id", .str jid),
      ("state", .str cur.state.asString),
      ("accepted", .bool false),
      ("signalled_pids", JVal.nat 0),
      ("deferred_until_tool_finishes", .bool false)
    ])
  if mode == "steer_between_tools" then
    return .ok (rt, .obj #[
      ("job_id", .str jid),
      ("state", .str cur.state.asString),
      ("accepted", .bool true),
      ("signalled_pids", JVal.nat 0),
      ("deferred_until_tool_finishes", .bool true)
    ])
  let mut sigCount : Nat := 0
  if let some lp := rt.liveProcs.get? jid then
    OrbNode.Posix.killPgrp lp.pid 2
    sigCount := 1
  return .ok (rt, .obj #[
    ("job_id", .str jid),
    ("state", .str cur.state.asString),
    ("accepted", .bool (sigCount > 0)),
    ("signalled_pids", JVal.nat sigCount),
    ("deferred_until_tool_finishes", .bool false)
  ])

/-- Run cleared-env synchronous `POST /execute` command under `<workDir>/<missionId>`. -/
def execClearedLeaseCommand (workDir missionId command : String) (maxJobSecs : UInt64) : IO JVal := do
  let missionDir := (System.FilePath.mk workDir / missionId).toString
  IO.FS.createDirAll missionDir
  let mut envPairs ← prepareSharedMissionEnv workDir missionDir
  envPairs := mergeEnvPair envPairs "SANDBOXED_MISSION_ID" missionId
  let mut envArgs : Array String := #["-i"]
  for (k, v) in envPairs do
    envArgs := envArgs.push s!"{k}={v}"
  let hasTimeout ← do
    let r ← (IO.Process.output { cmd := "timeout", args := #["--version"] }).toBaseIO
    pure (match r with | .ok o => o.exitCode == 0 | .error _ => false)
  if hasTimeout then
    envArgs := envArgs ++ #["timeout", "-k", "5", s!"{max 1 maxJobSecs}s", "bash", "-lc", command]
  else
    envArgs := envArgs ++ #["bash", "-lc", command]
  let out ← IO.Process.output {
    cmd := "env"
    args := envArgs
    cwd := some missionDir
  }
  return .obj #[
    ("accepted", .bool true),
    ("exit_code", JVal.int (Int.ofNat out.exitCode.toNat)),
    ("stdout", .str out.stdout),
    ("stderr", .str out.stderr)
  ]

/-- Single-threaded synchronous `POST /execute` helper (used by direct `handleRequest` tests). -/
def runSyncExecute (rt : NodeRuntime) (missionId command : String) (sideLane : Bool := false) : IO (Nat × JVal) := do
  if sideLane then
    if activeSideCount rt >= rt.cfg.sideCapacity then
      return (429, .str "node side-lane capacity exhausted")
  else if activeRegularCount rt + rt.shrinkDebt >= rt.cfg.capacityTotal then
    return (429, .str "node capacity exhausted")
  let resp ← execClearedLeaseCommand rt.cfg.workDir missionId command rt.cfg.maxJobSecs
  return (200, resp)

end OrbNode.Runner
