/-
  OrbNode.Runner: Worker Configuration, Live Capacity Resize (`Orb.Kernel.nodeResizeStep`),
  Bounded Log Byte-Range Slicing (`<= 256 KiB` newline-cut), and Process-Group (`-pgid`)
  Zero-Orphan Execution for `/execute`, `raw_command`, and `lean_build`.
-/
import LeanSys.Auth
import Orb.Kernel
import OrbBin.Json
import OrbNode.Spec
import OrbNode.Posix
import OrbNode.Lease
import OrbNode.Store

namespace OrbNode.Runner

open LeanSys.Auth
open OrbBin.Json
open OrbNode.Spec
open OrbNode.Lease
open OrbNode.Store

structure NodeConfig where
  bindHost            : String := "127.0.0.1"
  bindPort            : UInt16 := 3088
  nodeId              : String := "local-node"
  token               : String := ""
  tokenPrevious?      : Option String := none
  workDir             : String := "/var/lib/sandboxed-node/work"
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

def loadConfigFromEnv : IO NodeConfig := do
  let bindRaw := (← IO.getEnv "SANDBOXED_NODE_BIND").getD "127.0.0.1:3088"
  let (host, port) := parseBindAddr bindRaw
  let nodeId := ((← IO.getEnv "SANDBOXED_NODE_ID").getD "local-node").trimAscii.toString
  let token := ((← IO.getEnv "SANDBOXED_NODE_TOKEN").getD "").trimAscii.toString
  let prev? := (← IO.getEnv "SANDBOXED_NODE_TOKEN_PREVIOUS").map (·.trimAscii.toString)
    |>.filter (fun s => !s.isEmpty)
  let workDir := ((← IO.getEnv "SANDBOXED_NODE_WORK_DIR").getD "/var/lib/sandboxed-node/work").trimAscii.toString
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
  let mut cfg : NodeConfig := {
    bindHost := host
    bindPort := port
    nodeId := if nodeId.isEmpty then "local-node" else nodeId
    token := token
    tokenPrevious? := prev?
    workDir := workDir
    labels := labels
    allowRoot := allowRoot
    capacityTotal := capClamped
    sideCapacity := (max 1 (min 16 sideCap)).toUInt32
    coordinatorCapacity := (max 1 (min 16 coordCap)).toUInt32
    maxQueued := max 1 maxQueued
    maxJobSecs := maxJobSecs.toUInt64
    minFreeDiskBytes := minFreeGb.toUInt64 * 1024 * 1024 * 1024
    envAllowlist := allowKeys
  }
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
  cfg        : NodeConfig
  shrinkDebt : UInt32 := 0
  ledger     : Ledger
  liveProcs  : Std.HashMap String LiveProc := {}
  queueOrder : Array String := #[]

def activeRegularCount (rt : NodeRuntime) : UInt32 :=
  rt.liveProcs.fold (fun acc _ lp =>
    if !lp.forced && !lp.sideLane && !lp.coordLane then acc + 1 else acc) 0

def activeSideCount (rt : NodeRuntime) : UInt32 :=
  rt.liveProcs.fold (fun acc _ lp => if lp.sideLane then acc + 1 else acc) 0

def activeForcedCount (rt : NodeRuntime) : UInt32 :=
  rt.liveProcs.fold (fun acc _ lp => if lp.forced then acc + 1 else acc) 0

def activeCoordCount (rt : NodeRuntime) : UInt32 :=
  rt.liveProcs.fold (fun acc _ lp => if lp.coordLane then acc + 1 else acc) 0

/-- Apply operator-authorized live capacity resize via `Orb.Kernel.nodeResizeStep` + `OrbNode.Spec`. -/
def resizeCapacity
    (rt : NodeRuntime) (targetCap : UInt32) (targetCoord? : Option UInt32) :
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
  let ovJson := renderCompact (.obj #[
    ("capacity", JVal.nat targetCap.toNat),
    ("coordinator_capacity", JVal.nat nextCoord.toNat)
  ])
  let ovPath := System.FilePath.mk rt.cfg.workDir / "capacity_override.json"
  IO.FS.writeFile ovPath (ovJson ++ "\n")
  return .ok { rt with cfg := nextCfg, shrinkDebt := nextDebt }

def buildHeartbeatJson (rt : NodeRuntime) : IO JVal := do
  let st ← OrbNode.Posix.hostStats rt.cfg.workDir
  let leanReady ← (System.FilePath.mk "/opt/orb/elan/bin/lake").pathExists <||>
    (do let r ← IO.Process.output { cmd := "sh", args := #["-c", "command -v lake >/dev/null 2>&1"] }
        pure (r.exitCode == 0))
  let labels := if leanReady then rt.cfg.labels else rt.cfg.labels.filter (· != "lean")
  let activeReg := activeRegularCount rt
  let activeTot := rt.liveProcs.size.toUInt32
  let capAvail : UInt32 :=
    if rt.cfg.capacityTotal > activeReg + rt.shrinkDebt then
      rt.cfg.capacityTotal - (activeReg + rt.shrinkDebt)
    else 0
  let diskWord := Orb.Kernel.nodeDiskAdmissionStep
    st.diskAvailBytes 0 rt.cfg.minFreeDiskBytes rt.cfg.minFreeDiskBytes (20 * 1024 * 1024 * 1024) 0
  let diskPinned := ((diskWord &&& 0xFFFFFFFF).toUInt32 &&& 256) == 0
  return .obj #[
    ("resource_history", .arr #[]),
    ("node_id", .str rt.cfg.nodeId),
    ("online", .bool true),
    ("capacity_total", JVal.nat rt.cfg.capacityTotal.toNat),
    ("capacity_available", JVal.nat capAvail.toNat),
    ("active_leases", JVal.nat activeTot.toNat),
    ("version", .str "1.3.0-lean4"),
    ("protocol_version", JVal.nat 5),
    ("labels", .arr (labels.map .str)),
    ("cpu_total", JVal.nat st.cpuTotal.toNat),
    ("mem_total_bytes", JVal.uint64 st.memTotalBytes),
    ("mem_available_bytes", JVal.uint64 st.memAvailBytes),
    ("disk_total_bytes", JVal.uint64 st.diskTotalBytes),
    ("disk_available_bytes", JVal.uint64 st.diskAvailBytes),
    ("active_jobs", JVal.nat activeTot.toNat),
    ("queued_jobs", JVal.nat rt.queueOrder.size),
    ("side_jobs", JVal.nat (activeSideCount rt).toNat),
    ("forced_jobs", JVal.nat (activeForcedCount rt).toNat),
    ("priority_jobs", JVal.nat (activeCoordCount rt).toNat),
    ("coordinator_capacity", JVal.nat rt.cfg.coordinatorCapacity.toNat),
    ("cached_toolchains", .arr #[]),
    ("lean_runtime_ready", .bool leanReady),
    ("source_bundle_capacity", .obj #[
      ("overlay_bytes", JVal.uint64 (1024 * 1024)),
      ("complete_bytes", JVal.uint64 (32 * 1024 * 1024))
    ]),
    ("min_free_disk_bytes", JVal.uint64 rt.cfg.minFreeDiskBytes),
    ("disk_pressure_pinned", .bool diskPinned),
    ("managed_auth", .arr #[])
  ]

private def collectArtifacts (cwd : String) (relPaths : Array String) : IO (Array ArtifactEntry) := do
  let mut out : Array ArtifactEntry := #[]
  for rel in relPaths do
    if !rel.isEmpty && !rel.startsWith "/" && !(rel.splitOn "..").tail.isEmpty == false then
      let full := System.FilePath.mk cwd / rel
      if ← full.pathExists then
        if let .ok bytes ← IO.FS.readBinFile full |>.toBaseIO then
          let hex := bytesToHexLower (sha256Bytes bytes)
          out := out.push { path := rel, sha256 := hex, sizeBytes := bytes.size.toUInt64 }
  return out

private def hasTraversalSegment (rel : String) : Bool :=
  rel.startsWith "/" || (rel.splitOn "/").any (fun seg => seg == "..")

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
  let mut envKv : Array String := #["SANDBOXED_MISSION_ID", rec.missionId, "SANDBOXED_JOB_ID", jid]
  let mut artifacts : Array String := #[]
  if kind == "lean_build" then
    if let some cwdRel := payload.fieldStr? "cwd_rel" then
      if !cwdRel.isEmpty && !hasTraversalSegment cwdRel then
        cwd := (System.FilePath.mk missionDir / cwdRel).toString
        IO.FS.createDirAll cwd
    if let some srcObj := payload.field? "source" then
      if let some bundle := srcObj.field? "bundle" then
        if let some files := bundle.fieldArr? "files" then
          for f in files do
            if let (some fpath, some b64) := (f.fieldStr? "path", f.fieldStr? "data_base64") then
              if !hasTraversalSegment fpath then
                if let some decoded := base64UrlDecode? (b64.replace "+" "-" |>.replace "/" "_") then
                  let dest := System.FilePath.mk missionDir / fpath
                  if let some parent := dest.parent then IO.FS.createDirAll parent
                  IO.FS.writeBinFile dest decoded
    if let some envObj := (payload.field? "env") >>= JVal.asObj? then
      for (ek, ev) in envObj do
        if rt.cfg.envAllowlist.contains ek then
          if let some sv := ev.asStr? then
            envKv := envKv.push ek |>.push sv
    if let some arts := payload.fieldArr? "artifacts" then
      artifacts := arts.filterMap JVal.asStr?
    let cmdParts := ((payload.fieldArr? "command").getD #[]).filterMap JVal.asStr?
    if h : 0 < cmdParts.size then
      prog := cmdParts[0]
      args := cmdParts.extract 1 cmdParts.size
    else
      prog := "true"
  else
    let cmdStr := (payload.fieldStr? "command").getD "true"
    args := #["-lc", cmdStr]
    if let some envObj := (payload.field? "env") >>= JVal.asObj? then
      for (ek, ev) in envObj do
        if let some sv := ev.asStr? then
          envKv := envKv.push ek |>.push sv
  let nowTs ← nowRfc3339
  let nowEp ← OrbNode.Posix.nowEpoch
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
      let arts ← collectArtifacts lp.cwd lp.artifacts
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
  let mut nextProcs := rt.liveProcs.erase jid
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

/-- Synchronous `POST /execute` command under `<work_root>/<mission_id>`. -/
def runSyncExecute (rt : NodeRuntime) (missionId command : String) (sideLane : Bool := false) : IO (Nat × JVal) := do
  if sideLane then
    if activeSideCount rt >= rt.cfg.sideCapacity then
      return (429, .str "node side-lane capacity exhausted")
  else if activeRegularCount rt + rt.shrinkDebt >= rt.cfg.capacityTotal then
    return (429, .str "node capacity exhausted")
  let missionDir := (System.FilePath.mk rt.cfg.workDir / missionId).toString
  IO.FS.createDirAll missionDir
  let out ← IO.Process.output {
    cmd := "bash"
    args := #["-lc", command]
    cwd := some missionDir
  }
  return (200, .obj #[
    ("accepted", .bool true),
    ("exit_code", JVal.int (Int.ofNat out.exitCode.toNat)),
    ("stdout", .str out.stdout),
    ("stderr", .str out.stderr)
  ])

end OrbNode.Runner
