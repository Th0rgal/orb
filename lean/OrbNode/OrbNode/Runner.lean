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

/-! ### Live Process-Group Job State, Linux `/proc` Child-Tool Inspection, & Reconciler -/

/-- Compute deadline (`Option UInt64` seconds) for a job payload (`src/node/runner.rs:1312-1316`):
    non-side `raw_command` jobs with `long_running == true` have NO deadline when `timeout_secs` is
    absent, and honor an explicit `timeout_secs` without clamping to `maxJobSecs`. -/
def computeJobTimeoutSecs (kind : String) (payload : JVal) (maxJobSecs : UInt64) : Option UInt64 :=
  let side := (payload.fieldBool? "side_question").getD false
  let longRunning := (payload.fieldBool? "long_running").getD false
  if kind == "raw_command" && longRunning && !side then
    (payload.fieldUInt64? "timeout_secs").map (fun s => max 1 s)
  else
    let raw := (payload.fieldUInt64? "timeout_secs").getD maxJobSecs
    some (max 1 (min maxJobSecs raw))

private structure ProcStatEntry where
  ppid    : UInt32
  comm    : String
  cmdline : String

private def isHarnessProc (e : ProcStatEntry) : Bool :=
  let c := e.comm
  let cmd := e.cmdline
  if c == "opencode" || c == "claude" || c == "codex" || c == "grok" ||
     c == "agy" || c == "antigravity" || c == "vibe-acp" then true
  else if c == "node" || c == "bun" then
    (cmd.splitOn "opencode").length > 1 || (cmd.splitOn "claude").length > 1 ||
    (cmd.splitOn "codex").length > 1 || (cmd.splitOn "grok").length > 1 ||
    (cmd.splitOn "antigravity").length > 1 || (cmd.splitOn "agy").length > 1
  else false

private def isAuxHarnessHelper (e : ProcStatEntry) : Bool :=
  let c := e.comm
  let cmd := e.cmdline
  (c.splitOn "mcp").length > 1 ||
  (cmd.splitOn "sandboxed-mcp").length > 1 ||
  (cmd.splitOn "control_mcp").length > 1 ||
  (cmd.splitOn "mcp-stdio").length > 1 ||
  (cmd.splitOn "--mcp").length > 1 ||
  (c == "cat" && (cmd == "cat" || cmd.startsWith "cat ")) ||
  c == "systemd-run" || c == "nsenter" || c == "script" || c == "sandboxed-launch" ||
  (cmd.splitOn ".sandboxed-sh-opencode-cmd.sh").length > 1 ||
  (cmd.splitOn "orb-native-plan").length > 1

/-- Inspect `/proc` process subtree below `rootPid` (`src/node/tool_interrupt.rs`) and return active
    descendant child-tool PIDs (never including `rootPid`, harness PIDs, or MCP stdio sidecars). -/
def collectInflightChildToolPids (rootPid : UInt64) : IO (Array UInt32) := do
  let procRoot := System.FilePath.mk "/proc"
  if !(← procRoot.isDir) || rootPid == 0 then return #[]
  let .ok entries ← procRoot.readDir |>.toBaseIO | return #[]
  let mut table : Std.HashMap UInt32 ProcStatEntry := {}
  let mut children : Std.HashMap UInt32 (Array UInt32) := {}
  for item in entries do
    if let some pidNat := item.fileName.toNat? then
      let pid := pidNat.toUInt32
      if let .ok statRaw ← IO.FS.readFile (item.path / "stat") |>.toBaseIO then
        let partsOpen := statRaw.splitOn "("
        if partsOpen.length ≥ 2 then
          let afterOpen := String.intercalate "(" partsOpen.tail!
          let partsClose := afterOpen.splitOn ") "
          if partsClose.length ≥ 2 then
            let rest := partsClose.getLast!
            let comm := String.intercalate ") " partsClose.dropLast
            let fields := (rest.splitOn " ").filter (fun s => !s.isEmpty)
            if let st :: ppidStr :: _ := fields then
              if st != "Z" && st != "X" then
                if let some ppidNat := ppidStr.toNat? then
                  let ppid := ppidNat.toUInt32
                  let cmdline ← match ← IO.FS.readBinFile (item.path / "cmdline") |>.toBaseIO with
                    | .ok b =>
                      let s := String.fromUTF8? (b.foldl (fun acc x => if x == 0 then acc.push 32 else acc.push x) ByteArray.empty) |>.getD ""
                      pure s.trimAscii.toString
                    | .error _ => pure ""
                  table := table.insert pid { ppid, comm, cmdline }
                  let curKids := (children.get? ppid).getD #[]
                  children := children.insert ppid (curKids.push pid)
  let rootU32 := rootPid.toUInt32
  let mut subtree : Std.HashMap UInt32 Unit := {}
  let mut stack : Array UInt32 := #[rootU32]
  while !stack.isEmpty do
    let p := stack.back!
    stack := stack.pop
    if !subtree.contains p then
      subtree := subtree.insert p ()
      if let some kids := children.get? p then
        stack := stack ++ kids
  if subtree.isEmpty then return #[]
  let mut harnessPids : Std.HashMap UInt32 Unit := {}
  for (p, _) in subtree.toList do
    if let some info := table.get? p then
      if isHarnessProc info then
        harnessPids := harnessPids.insert p ()
  let mut candidateRoots : Array UInt32 := #[]
  if !harnessPids.isEmpty then
    for (hp, _) in harnessPids.toList do
      if let some kids := children.get? hp then
        for k in kids do
          if !harnessPids.contains k then
            candidateRoots := candidateRoots.push k
  else
    for (p, _) in subtree.toList do
      if p != rootU32 then
        candidateRoots := candidateRoots.push p
  let mut toolPids : Array UInt32 := #[]
  let mut seenTools : Std.HashMap UInt32 Unit := {}
  let mut toolStack := candidateRoots
  while !toolStack.isEmpty do
    let p := toolStack.back!
    toolStack := toolStack.pop
    if !seenTools.contains p && p != rootU32 && !harnessPids.contains p then
      seenTools := seenTools.insert p ()
      if let some info := table.get? p then
        if isAuxHarnessHelper info then
          if harnessPids.isEmpty then
            if let some kids := children.get? p then
              toolStack := toolStack ++ kids
        else
          toolPids := toolPids.push p
          if let some kids := children.get? p then
            toolStack := toolStack ++ kids
  return toolPids.qsort (· < ·)

def sigintInflightChildTools (rootPid : UInt64) : IO Nat := do
  let pids ← collectInflightChildToolPids rootPid
  let mut count : Nat := 0
  let revPids := pids.reverse
  for p in revPids do
    if p > 1 then
      let rc ← killSig (Int64.ofNat p.toNat) 2
      if rc == 0 then
        count := count + 1
  return count

structure LaunchingSlot where
  forced    : Bool
  sideLane  : Bool
  coordLane : Bool
  missionId : String
  trackBg   : Bool
  deriving Repr, Inhabited

structure LiveProc where
  pid              : UInt64
  startedEp        : UInt64
  timeoutSecs?     : Option UInt64
  forced           : Bool
  sideLane         : Bool
  coordLane        : Bool
  artifacts        : Array String
  cwd              : String
  isolatedCheckout : Option String := none
  steerAfterTool   : Bool := false
  deriving Repr, Inhabited

structure PreparedJobSpec where
  jid              : String
  forced           : Bool
  sideLane         : Bool
  coordLane        : Bool
  timeoutSecs?     : Option UInt64
  logPath          : String
  cwd              : String
  isolatedCheckout : Option String
  prog             : String
  args             : Array String
  envKv            : Array String
  artifacts        : Array String
  deriving Repr, Inhabited

structure NodeRuntime where
  cfg            : NodeConfig
  shrinkDebt     : UInt32 := 0
  activeExecMain : UInt32 := 0
  activeExecSide : UInt32 := 0
  ledger         : Ledger
  launching      : Std.HashMap String LaunchingSlot := {}
  liveProcs      : Std.HashMap String LiveProc := {}
  queueOrder     : Array String := #[]

def activeRegularCount (rt : NodeRuntime) : UInt32 :=
  rt.activeExecMain +
  rt.launching.fold (fun acc _ sl =>
    if !sl.forced && !sl.sideLane && !sl.coordLane then acc + 1 else acc) 0 +
  rt.liveProcs.fold (fun acc _ lp =>
    if !lp.forced && !lp.sideLane && !lp.coordLane then acc + 1 else acc) 0

def activeSideCount (rt : NodeRuntime) : UInt32 :=
  rt.activeExecSide +
  rt.launching.fold (fun acc _ sl => if sl.sideLane then acc + 1 else acc) 0 +
  rt.liveProcs.fold (fun acc _ lp => if lp.sideLane then acc + 1 else acc) 0

def activeForcedCount (rt : NodeRuntime) : UInt32 :=
  rt.launching.fold (fun acc _ sl => if sl.forced then acc + 1 else acc) 0 +
  rt.liveProcs.fold (fun acc _ lp => if lp.forced then acc + 1 else acc) 0

def activeCoordCount (rt : NodeRuntime) : UInt32 :=
  rt.launching.fold (fun acc _ sl => if sl.coordLane then acc + 1 else acc) 0 +
  rt.liveProcs.fold (fun acc _ lp => if lp.coordLane then acc + 1 else acc) 0

/-- Check whether workspace `wsMissionId` currently has any queued, launching, or running
    ordinary background job (`!side_question && companion_of.isNone`) on this node. -/
def hasWorkspaceBackgroundWork (rt : NodeRuntime) (wsMissionId : String) : Bool := Id.run do
  for (_, sl) in rt.launching.toList do
    if sl.missionId == wsMissionId && sl.trackBg then
      return true
  for (jid, _) in rt.liveProcs.toList do
    if let some rec := rt.ledger.jobs.get? jid then
      if rec.missionId == wsMissionId then
        if let .ok payload := OrbBin.Json.parse rec.payloadJson then
          let kind := (payload.fieldStr? "kind").getD "raw_command"
          if kind == "lean_build" then
            return true
          let side := (payload.fieldBool? "side_question").getD false
          let comp? := (payload.fieldStr? "companion_of").filter (fun s => !s.isEmpty)
          if !side && comp?.isNone then
            return true
  for qid in rt.queueOrder do
    if let some rec := rt.ledger.jobs.get? qid then
      if rec.state == .queued && rec.missionId == wsMissionId then
        if let .ok payload := OrbBin.Json.parse rec.payloadJson then
          let kind := (payload.fieldStr? "kind").getD "raw_command"
          if kind == "lean_build" then
            return true
          let side := (payload.fieldBool? "side_question").getD false
          let comp? := (payload.fieldStr? "companion_of").filter (fun s => !s.isEmpty)
          if !side && comp?.isNone then
            return true
  return false

/-- Decide whether a queued job can be admitted right now and on which lane (`sideLane`, `coordLane`)
    by delegating directly to `Orb.Kernel.nodeLaneStep` (`orb_node_lane_step`). -/
def decideQueuedAdmission (rt : NodeRuntime) (payload : JVal) : Option (Bool × Bool × Bool) :=
  let kind := (payload.fieldStr? "kind").getD "raw_command"
  let (isSide, isCoordPrio, hasWsBg, isChild, isNativeGoal, trackBg) :=
    if kind == "lean_build" then
      (false, false, false, false, false, true)
    else
      let side := (payload.fieldBool? "side_question").getD false
      let coord := (payload.fieldBool? "coordinator_priority").getD false
      let child := (payload.fieldBool? "is_child_worker").getD false
      let goal := (payload.fieldBool? "native_goal").getD false
      let comp? := ((payload.fieldStr? "companion_of") >>= parseUuidCanonical?).orElse
        (fun _ => (payload.fieldStr? "companion_of").filter (fun s => !s.isEmpty))
      let wsBg := match comp? with
        | some wsId => hasWorkspaceBackgroundWork rt wsId
        | none => false
      (side, coord, wsBg, child, goal, !side && comp?.isNone)
  let mainMax := rt.cfg.capacityTotal
  let effMainRun := min mainMax (activeRegularCount rt + rt.shrinkDebt)
  let sideMax := rt.cfg.sideCapacity
  let sideRun := min sideMax (activeSideCount rt)
  let coordMax := rt.cfg.coordinatorCapacity
  let coordRun := min coordMax (activeCoordCount rt)
  let code := Orb.Kernel.nodeLaneStep
    (if isSide then 1 else 0)
    (if isCoordPrio then 1 else 0)
    (if hasWsBg then 1 else 0)
    (if isChild then 1 else 0)
    (if isNativeGoal then 1 else 0)
    effMainRun mainMax sideRun sideMax coordRun coordMax
  match code with
  | 258 => some (true, false, trackBg)   -- AdmitSide
  | 260 => some (false, true, trackBg)   -- AdmitCompanion (uses coordinator/companion pool)
  | 259 => some (false, true, trackBg)   -- AdmitCoordinator
  | 257 => some (false, false, trackBg)  -- AdmitMain
  | _   => none

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
  let activeAsync := (rt.launching.size + rt.liveProcs.size).toUInt32
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

private def cleanupIsolatedCheckout (iso? : Option String) : IO Unit := do
  if let some dir := iso? then
    if !dir.isEmpty then
      let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dir] }

/-- Materialize checkout & environment outside `Std.Mutex NodeRuntime` so slow `git fetch` or
    archive extraction never blocks `/heartbeat`, `/cancel`, `/jobs/:id/log`, or timeouts. -/
def prepareJobOutsideLock
    (cfg : NodeConfig) (jid missionId : String) (payload : JVal) (logPath : String)
    (forced sideLane coordLane : Bool) : IO (Except String PreparedJobSpec) := do
  let kind := (payload.fieldStr? "kind").getD "raw_command"
  let missionDir := (System.FilePath.mk cfg.workDir / missionId).toString
  IO.FS.createDirAll missionDir
  let timeoutSecs? := computeJobTimeoutSecs kind payload cfg.maxJobSecs
  let mut cwd := missionDir
  let mut isolatedCheckout : Option String := none
  let mut prog := "bash"
  let mut args : Array String := #[]
  let mut envPairs : Array (String × String) := #[]
  let mut artifacts : Array String := #[]
  if kind == "lean_build" then
    let some srcObj := payload.field? "source"
      | return .error "missing source"
    let checkoutDir ← match ← materializeLeanCheckout cfg.workDir srcObj logPath (some jid) with
      | .ok d => pure d
      | .error err => return .error err
    isolatedCheckout := some checkoutDir
    cwd := checkoutDir
    if let some cwdRelRaw := payload.fieldStr? "cwd_rel" then
      let cwdRel := (cwdRelRaw.dropWhile (· == '/') |>.dropEndWhile (· == '/')).toString
      if !cwdRel.isEmpty && relPathIsSafe cwdRel then
        let sub := System.FilePath.mk checkoutDir / cwdRel
        if !(← sub.isDir) then
          cleanupIsolatedCheckout isolatedCheckout
          return .error s!"cwd_rel '{cwdRel}' does not exist in checkout"
        cwd := sub.toString
    let cmdParts := ((payload.fieldArr? "command").getD #[]).filterMap JVal.asStr?
    if h : 0 < cmdParts.size then
      prog := cmdParts[0]
      args := cmdParts.extract 1 cmdParts.size
    else
      prog := "true"
    let usesFanout := prog != "turbo-lean" || args.contains "build"
    let st ← OrbNode.Posix.hostStats cfg.workDir
    let repo := (srcObj.fieldStr? "repo").getD ""
    let payloadEnv := ((payload.field? "env") >>= JVal.asObj?).getD #[]
    envPairs ← buildLeanJobEnv cfg.workDir repo st.cpuTotal cfg.capacityTotal
      cfg.envAllowlist usesFanout payloadEnv
    envPairs := mergeEnvPair envPairs "SANDBOXED_MISSION_ID" missionId
    envPairs := mergeEnvPair envPairs "SANDBOXED_JOB_ID" jid
    if let some arts := payload.fieldArr? "artifacts" then
      artifacts := arts.filterMap JVal.asStr?
  else
    let cmdStr := (payload.fieldStr? "command").getD "true"
    args := #["-lc", cmdStr]
    envPairs ← prepareSharedMissionEnv cfg.workDir missionDir
    envPairs := mergeEnvPair envPairs "SANDBOXED_MISSION_ID" missionId
    envPairs := mergeEnvPair envPairs "SANDBOXED_JOB_ID" jid
    if let some envObj := (payload.field? "env") >>= JVal.asObj? then
      for (ek, ev) in envObj do
        if let some sv := ev.asStr? then
          envPairs := mergeEnvPair envPairs ek sv
    let reqProfiles := ((payload.fieldArr? "managed_auth").getD #[]).filterMap JVal.asStr?
    if !reqProfiles.isEmpty then
      match ← prepareManagedAuthWorkspace cfg.managedAuth reqProfiles missionDir with
      | .error err => return .error err
      | .ok authEnv =>
        for (ak, av) in authEnv do
          envPairs := mergeEnvPair envPairs ak av
  return .ok {
    jid := jid
    forced := forced
    sideLane := sideLane
    coordLane := coordLane
    timeoutSecs? := timeoutSecs?
    logPath := logPath
    cwd := cwd
    isolatedCheckout := isolatedCheckout
    prog := prog
    args := args
    envKv := flattenEnvKv envPairs
    artifacts := artifacts
  }

/-- Commit a `PreparedJobSpec` into `NodeRuntime` (clearing its `launching` reservation and spawning `-pgid`
    unless cancelled while preparing). -/
def commitPreparedJob
    (rt0 : NodeRuntime) (jid : String) (prepRes : Except String PreparedJobSpec) : IO NodeRuntime := do
  let wasLaunching := rt0.launching.get? jid
  let mut rt := { rt0 with launching := rt0.launching.erase jid }
  let releaseDebt (r : NodeRuntime) : NodeRuntime :=
    match wasLaunching with
    | some sl =>
      if !sl.forced && !sl.sideLane && !sl.coordLane && r.shrinkDebt > 0 then
        { r with shrinkDebt := r.shrinkDebt - 1 }
      else r
    | none => r
  let some cur := rt.ledger.jobs.get? jid
    | if let .ok spec := prepRes then cleanupIsolatedCheckout spec.isolatedCheckout
      return releaseDebt rt
  if cur.state != .queued then
    if let .ok spec := prepRes then cleanupIsolatedCheckout spec.isolatedCheckout
    return releaseDebt rt
  let nowTs ← nowRfc3339
  match prepRes with
  | .error errMsg =>
    if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
      r with state := .failed, finishedAt? := some nowTs, error? := some errMsg
    }) then
      rt := { rt with ledger := l' }
    return releaseDebt rt
  | .ok spec =>
    let nowEp ← OrbNode.Posix.nowEpoch
    match ← (OrbNode.Posix.spawnJobPgrp spec.prog spec.args spec.envKv spec.cwd spec.logPath).toBaseIO with
    | .error e =>
      cleanupIsolatedCheckout spec.isolatedCheckout
      if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
        r with state := .failed, finishedAt? := some nowTs, error? := some (toString e), forced := spec.forced
      }) then
        rt := { rt with ledger := l' }
      return releaseDebt rt
    | .ok pid =>
      match ← rt.ledger.updateJob jid (fun r => .ok {
        r with state := .running, startedAt? := some nowTs, logPath? := some spec.logPath, forced := spec.forced
      }) with
      | .ok (l', _) =>
        let lp : LiveProc := {
          pid := pid
          startedEp := nowEp
          timeoutSecs? := spec.timeoutSecs?
          forced := spec.forced
          sideLane := spec.sideLane
          coordLane := spec.coordLane
          artifacts := spec.artifacts
          cwd := spec.cwd
          isolatedCheckout := spec.isolatedCheckout
        }
        return { rt with ledger := l', liveProcs := rt.liveProcs.insert jid lp }
      | .error _ =>
        OrbNode.Posix.killPgrp pid 9
        discard <| OrbNode.Posix.pollPid pid
        cleanupIsolatedCheckout spec.isolatedCheckout
        return releaseDebt rt

private def startQueuedJobSync
    (rt : NodeRuntime) (jid : String) (payloadOverride? : Option JVal := none)
    (forced : Bool := false) (sideLane : Bool := false) (coordLane : Bool := false)
    (trackBg : Bool := true) : IO NodeRuntime := do
  let some rec := rt.ledger.jobs.get? jid
    | return rt
  if rec.state != .queued then return rt
  let payload ← match payloadOverride? with
    | some pv => pure pv
    | none =>
      match OrbBin.Json.parse rec.payloadJson with
      | .ok pv => pure pv
      | .error _ => return rt
  let logPath := rec.logPath?.getD ((System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jid}.log").toString)
  let sl : LaunchingSlot := { forced, sideLane, coordLane, missionId := rec.missionId, trackBg }
  let rtReserved := { rt with launching := rt.launching.insert jid sl }
  let prepRes ← prepareJobOutsideLock rtReserved.cfg jid rec.missionId payload logPath forced sideLane coordLane
  commitPreparedJob rtReserved jid prepRes

structure PendingAsyncLaunch where
  cfg       : NodeConfig
  jid       : String
  missionId : String
  payload   : JVal
  logPath   : String
  forced    : Bool
  sideLane  : Bool
  coordLane : Bool

/-- Reap exited/timed-out/steered process groups (`-pgid` zero-orphan kill) and reserve lane slots for
    eligible queued jobs, returning `(updatedRuntime, jobsToLaunchOutsideLock)`. -/
def tickRuntimeReserve
    (rt0 : NodeRuntime) (payloadHints : Std.HashMap String JVal := {}) :
    IO (NodeRuntime × Array PendingAsyncLaunch) := do
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
      cleanupIsolatedCheckout lp.isolatedCheckout
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
    else if let some limitSecs := lp.timeoutSecs? then
      if nowEp > lp.startedEp + limitSecs then
        OrbNode.Posix.killPgrp lp.pid 15
        OrbNode.Posix.killPgrp lp.pid 9
        discard <| OrbNode.Posix.pollPid lp.pid
        cleanupIsolatedCheckout lp.isolatedCheckout
        let nowTs ← nowRfc3339
        if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
          r with
          state := .failed
          exitCode? := some 124
          finishedAt? := some nowTs
          error? := some s!"job timed out after {limitSecs}s"
        }) then
          rt := { rt with ledger := l' }
        rt := { rt with liveProcs := rt.liveProcs.erase jid }
      else if lp.steerAfterTool then
        let inflight ← collectInflightChildToolPids lp.pid
        if inflight.isEmpty then
          OrbNode.Posix.killPgrp lp.pid 15
          OrbNode.Posix.killPgrp lp.pid 9
          discard <| OrbNode.Posix.pollPid lp.pid
          cleanupIsolatedCheckout lp.isolatedCheckout
          let nowTs ← nowRfc3339
          let cInfo : JobCancellation := {
            actor := "core", reason := "Steered immediately after tool call completed", requestedAt := nowTs
          }
          if let .ok (l', _) ← rt.ledger.updateJob jid (fun r =>
            if r.state.isTerminal then .ok r
            else .ok { r with state := .cancelled, finishedAt? := some nowTs, cancellation? := some cInfo }) then
            rt := { rt with ledger := l' }
          rt := { rt with liveProcs := rt.liveProcs.erase jid }
          if !lp.forced && !lp.sideLane && !lp.coordLane && rt.shrinkDebt > 0 then
            rt := { rt with shrinkDebt := rt.shrinkDebt - 1 }
    else if lp.steerAfterTool then
      let inflight ← collectInflightChildToolPids lp.pid
      if inflight.isEmpty then
        OrbNode.Posix.killPgrp lp.pid 15
        OrbNode.Posix.killPgrp lp.pid 9
        discard <| OrbNode.Posix.pollPid lp.pid
        cleanupIsolatedCheckout lp.isolatedCheckout
        let nowTs ← nowRfc3339
        let cInfo : JobCancellation := {
          actor := "core", reason := "Steered immediately after tool call completed", requestedAt := nowTs
        }
        if let .ok (l', _) ← rt.ledger.updateJob jid (fun r =>
          if r.state.isTerminal then .ok r
          else .ok { r with state := .cancelled, finishedAt? := some nowTs, cancellation? := some cInfo }) then
          rt := { rt with ledger := l' }
        rt := { rt with liveProcs := rt.liveProcs.erase jid }
        if !lp.forced && !lp.sideLane && !lp.coordLane && rt.shrinkDebt > 0 then
          rt := { rt with shrinkDebt := rt.shrinkDebt - 1 }
  let mut remQueue : Array String := #[]
  let mut toLaunch : Array PendingAsyncLaunch := #[]
  for jid in rt.queueOrder do
    if let some rec := rt.ledger.jobs.get? jid then
      if rec.state == .queued && !rt.launching.contains jid then
        let payload? := (payloadHints.get? jid).orElse (fun _ =>
          match OrbBin.Json.parse rec.payloadJson with
          | .ok pv => some pv
          | .error _ => none)
        if let some payload := payload? then
          match decideQueuedAdmission rt payload with
          | some (sideLane, coordLane, trackBg) =>
            let logPath := rec.logPath?.getD ((System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jid}.log").toString)
            let sl : LaunchingSlot := {
              forced := false, sideLane, coordLane, missionId := rec.missionId, trackBg
            }
            rt := { rt with launching := rt.launching.insert jid sl }
            toLaunch := toLaunch.push {
              cfg := rt.cfg
              jid := jid
              missionId := rec.missionId
              payload := payload
              logPath := logPath
              forced := false
              sideLane := sideLane
              coordLane := coordLane
            }
          | none =>
            remQueue := remQueue.push jid
  return ({ rt with queueOrder := remQueue }, toLaunch)

/-- Synchronous `tickRuntime` wrapper (used by single-threaded `SelfTest` / `handleRequest`). -/
def tickRuntime
    (rt0 : NodeRuntime) (payloadHints : Std.HashMap String JVal := {}) : IO NodeRuntime := do
  let (rtReserved, launches) ← tickRuntimeReserve rt0 payloadHints
  let mut rt := rtReserved
  for item in launches do
    let prepRes ← prepareJobOutsideLock item.cfg item.jid item.missionId item.payload item.logPath
      item.forced item.sideLane item.coordLane
    rt ← commitPreparedJob rt item.jid prepRes
  return rt

def cancelJob (rt : NodeRuntime) (jid actor reason : String) : IO (Except String (NodeRuntime × JobRecord)) := do
  let some _cur := rt.ledger.jobs.get? jid
    | return .error "not_found"
  let nowTs ← nowRfc3339
  let cleanReason := (reason.take 256).toString
  let cleanActor :=
    if actor == "core" || actor == "operator" || actor == "startup_watchdog" || actor == "provider_error" then actor
    else "unknown"
  let cInfo : JobCancellation := { actor := cleanActor, reason := cleanReason, requestedAt := nowTs }
  let mut releasedRegular := false
  if let some lp := rt.liveProcs.get? jid then
    OrbNode.Posix.killPgrp lp.pid 15
    OrbNode.Posix.killPgrp lp.pid 9
    discard <| OrbNode.Posix.pollPid lp.pid
    cleanupIsolatedCheckout lp.isolatedCheckout
    if !lp.forced && !lp.sideLane && !lp.coordLane then
      releasedRegular := true
  if let some sl := rt.launching.get? jid then
    if !sl.forced && !sl.sideLane && !sl.coordLane then
      releasedRegular := true
  let nextProcs := rt.liveProcs.erase jid
  let nextLaunching := rt.launching.erase jid
  let nextQueue := rt.queueOrder.filter (· != jid)
  let nextDebt := if releasedRegular && rt.shrinkDebt > 0 then rt.shrinkDebt - 1 else rt.shrinkDebt
  match ← rt.ledger.updateJob jid (fun r =>
    if r.state.isTerminal then .ok r
    else .ok { r with state := .cancelled, finishedAt? := some nowTs, cancellation? := some cInfo }) with
  | .error e => return .error e
  | .ok (l', updated) =>
    return .ok ({
      rt with
      ledger := l'
      launching := nextLaunching
      liveProcs := nextProcs
      queueOrder := nextQueue
      shrinkDebt := nextDebt
    }, updated)

/-- Reserve the force slot for a queued job (`POST /jobs/:id/force`), returning a `PendingAsyncLaunch`
    so concurrent callers materialize checkouts outside `Std.Mutex NodeRuntime`. -/
def reserveForceJob (rt : NodeRuntime) (jid : String) :
    Except String (NodeRuntime × PendingAsyncLaunch × JobRecord) := do
  let some cur := rt.ledger.jobs.get? jid
    | throw "not_found"
  if cur.state != .queued || rt.launching.contains jid then
    throw "not_queued"
  if activeForcedCount rt >= 1 then
    throw "force_slot_busy"
  let .ok payload := OrbBin.Json.parse cur.payloadJson
    | throw "corrupt_payload"
  let side := (payload.fieldBool? "side_question").getD false
  let comp? := (payload.fieldStr? "companion_of").filter (fun s => !s.isEmpty)
  let kind := (payload.fieldStr? "kind").getD "raw_command"
  let trackBg := kind == "lean_build" || (!side && comp?.isNone)
  let logPath := cur.logPath?.getD ((System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jid}.log").toString)
  let sl : LaunchingSlot := {
    forced := true, sideLane := false, coordLane := false, missionId := cur.missionId, trackBg
  }
  let rt' := {
    rt with
    queueOrder := rt.queueOrder.filter (· != jid)
    launching := rt.launching.insert jid sl
  }
  let launch : PendingAsyncLaunch := {
    cfg := rt.cfg
    jid := jid
    missionId := cur.missionId
    payload := payload
    logPath := logPath
    forced := true
    sideLane := false
    coordLane := false
  }
  return (rt', launch, cur)

def forceJob (rt : NodeRuntime) (jid : String) : IO (Except String (NodeRuntime × JobRecord)) := do
  match reserveForceJob rt jid with
  | .error e => return .error e
  | .ok (rtReserved, launch, cur) =>
    let prepRes ← prepareJobOutsideLock launch.cfg launch.jid launch.missionId launch.payload launch.logPath
      launch.forced launch.sideLane launch.coordLane
    let rt' ← commitPreparedJob rtReserved jid prepRes
    let updated := (rt'.ledger.jobs.get? jid).getD cur
    return .ok (rt', updated)

/-- Interrupt or steer a running/queued job (`src/node/runner.rs::interrupt_job`):
    - `interrupt_now`: sends `SIGINT` to in-flight child tools, waits briefly, and cancels the turn.
    - `steer_between_tools`: cancels immediately when no child tool is active (`deferred_until_tool_finishes: false`);
      when a child tool IS active under `lp.pid`, sets `lp.steerAfterTool := true` (`deferred_until_tool_finishes: true`)
      so the reconciler/watcher cancels the turn right as the child tool finishes! -/
def interruptJob (rt : NodeRuntime) (jid mode : String) : IO (Except String (NodeRuntime × JVal × Option UInt64)) := do
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
      ], none)
  if cur.state != .running then
    return .ok (rt, .obj #[
      ("job_id", .str jid),
      ("state", .str cur.state.asString),
      ("accepted", .bool false),
      ("signalled_pids", JVal.nat 0),
      ("deferred_until_tool_finishes", .bool false)
    ], none)
  let some lp := rt.liveProcs.get? jid
    | return .ok (rt, .obj #[
        ("job_id", .str jid),
        ("state", .str cur.state.asString),
        ("accepted", .bool false),
        ("signalled_pids", JVal.nat 0),
        ("deferred_until_tool_finishes", .bool false)
      ], none)
  if mode == "steer_between_tools" then
    let inflight ← collectInflightChildToolPids lp.pid
    if inflight.isEmpty then
      match ← cancelJob rt jid "core" "Steered between tool calls" with
      | .error e => return .error e
      | .ok (rt', updated) =>
        return .ok (rt', .obj #[
          ("job_id", .str jid),
          ("state", .str updated.state.asString),
          ("accepted", .bool true),
          ("signalled_pids", JVal.nat 0),
          ("deferred_until_tool_finishes", .bool false)
        ], none)
    else
      let lpSteered := { lp with steerAfterTool := true }
      let rt' := { rt with liveProcs := rt.liveProcs.insert jid lpSteered }
      return .ok (rt', .obj #[
        ("job_id", .str jid),
        ("state", .str "running"),
        ("accepted", .bool true),
        ("signalled_pids", JVal.nat 0),
        ("deferred_until_tool_finishes", .bool true)
      ], some lp.pid)
  else
    let sigCount ← sigintInflightChildTools lp.pid
    if sigCount > 0 then
      IO.sleep 60
    match ← cancelJob rt jid "core" "Interrupted in-flight tool via SIGINT for immediate controller steering" with
    | .error e => return .error e
    | .ok (rt', updated) =>
      return .ok (rt', .obj #[
        ("job_id", .str jid),
        ("state", .str updated.state.asString),
        ("accepted", .bool true),
        ("signalled_pids", JVal.nat sigCount),
        ("deferred_until_tool_finishes", .bool false)
      ], none)

/-- Run cleared-env synchronous `POST /execute` command under `<workDir>/<missionId>`, fenced via `jobs.db`. -/
def execClearedLeaseCommand
    (workDir : String) (hasSqlite3 : Bool) (missionId command : String) (maxJobSecs : UInt64) :
    IO (Except String JVal) := do
  let execId ← newUuidV4
  if let .error fenceErr ← acquireExecFenceReceipt workDir hasSqlite3 execId missionId then
    return .error fenceErr
  try
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
    return .ok (.obj #[
      ("accepted", .bool true),
      ("exit_code", JVal.int (Int.ofNat out.exitCode.toNat)),
      ("stdout", .str out.stdout),
      ("stderr", .str out.stderr)
    ])
  finally
    releaseExecFenceReceipt workDir hasSqlite3 execId missionId

/-- Single-threaded synchronous `POST /execute` helper (used by direct `handleRequest` tests). -/
def runSyncExecute (rt : NodeRuntime) (missionId command : String) (sideLane : Bool := false) : IO (Nat × JVal) := do
  if sideLane then
    if activeSideCount rt >= rt.cfg.sideCapacity then
      return (429, .str "node side-lane capacity exhausted")
  else if activeRegularCount rt + rt.shrinkDebt >= rt.cfg.capacityTotal then
    return (429, .str "node capacity exhausted")
  match ← execClearedLeaseCommand rt.cfg.workDir rt.ledger.hasSqlite3 missionId command rt.cfg.maxJobSecs with
  | .ok resp => return (200, resp)
  | .error fenceErr => return (503, .str fenceErr)

end OrbNode.Runner
