/-
  OrbNode.Runner: Worker Configuration, Live Capacity Resize (`Orb.Kernel.nodeResizeStep`),
  Bounded Log Byte-Range Slicing (`<= 256 KiB` newline-cut), and Process-Group (`-pgid`)
  Zero-Orphan Execution for `/execute`, `raw_command`, and `lean_build`.
-/
import LeanSys.Posix
import LeanSys.Auth
import Orb.Kernel
import Orb.ManagedNode
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

/-- Trim any trailing incomplete multi-byte UTF-8 sequence from `sub` (up to 3 bytes) when `sub`
    ends before `total` or mid-write, returning `(validSlice, trimmedLen)`. If an earlier byte in
    `sub` is genuinely invalid UTF-8, replaces only malformed byte runs with `?` while still keeping
    a trailing incomplete starter sequence unread for the next poll! -/
private def trimIncompleteUtf8Suffix (sub : ByteArray) : ByteArray := Id.run do
  if sub.isEmpty then return sub
  if (String.fromUTF8? sub).isSome then return sub
  -- Check if the last 1..3 bytes form an incomplete leading/continuation UTF-8 suffix
  let sz := sub.size
  for trimN in [1, 2, 3] do
    if trimN <= sz then
      let leadIdx := sz - trimN
      let lead := sub.get! leadIdx
      let expectedLen : Nat :=
        if (lead &&& 0xE0) == 0xC0 then 2
        else if (lead &&& 0xF0) == 0xE0 then 3
        else if (lead &&& 0xF8) == 0xF0 then 4
        else 0
      if expectedLen > trimN then
        let mut allCont := true
        for k in [leadIdx + 1 : sz] do
          if (sub.get! k &&& 0xC0) != 0x80 then
            allCont := false
        if allCont then
          return sub.extract 0 leadIdx
  return sub

private def decodeUtf8LossyPreservingValid (sub : ByteArray) : String := Id.run do
  if let some s := String.fromUTF8? sub then
    return s
  let mut out := ""
  let mut i : Nat := 0
  while i < sub.size do
    let b0 := sub.get! i
    if b0 < 0x80 then
      out := out.push (Char.ofNat b0.toNat)
      i := i + 1
    else
      let seqLen : Nat :=
        if (b0 &&& 0xE0) == 0xC0 then 2
        else if (b0 &&& 0xF0) == 0xE0 then 3
        else if (b0 &&& 0xF8) == 0xF0 then 4
        else 1
      if seqLen > 1 && i + seqLen <= sub.size then
        match String.fromUTF8? (sub.extract i (i + seqLen)) with
        | some ch =>
          out := out ++ ch
          i := i + seqLen
        | none =>
          out := out.push '?'
          i := i + 1
      else
        out := out.push '?'
        i := i + 1
  return out

/-- Core pure log-window slicer given `window` (`rawLog[offset .. offset + window.size]`), `offset`,
    and total `fileLen` (`fstatSize`), cutting at the last `\n` when not at EOF and leaving any
    trailing incomplete UTF-8 multi-byte sequence unread while the job is active (`!isTerminal`),
    while consuming trailing malformed bytes lossily (`\uFFFD`) once the job is terminal (`isTerminal`)
    so Core's `next_offset >= log_len` drain loop always terminates! -/
def sliceJobLogWindow
    (window : ByteArray) (offset : UInt64) (fileLen : UInt64)
    (maxBytes : Nat := 262144) (isTerminal : Bool := false) : LogSliceResult := Id.run do
  if offset >= fileLen || window.isEmpty then
    let clamped := min offset fileLen
    return {
      offset := clamped
      nextOffset := clamped
      logLen := fileLen
      data := ""
    }
  let cap := max 4 (min 262144 maxBytes)
  let rawLen := min window.size cap
  let atEof := offset + rawLen.toUInt64 >= fileLen
  let mut cutLen := rawLen
  if !atEof then
    let mut k := rawLen
    while k > 0 do
      k := k - 1
      if window.get! k == 10 then
        cutLen := k + 1
        break
  let rawSub := window.extract 0 cutLen
  let trimmed := if isTerminal && atEof then rawSub else trimIncompleteUtf8Suffix rawSub
  let text := decodeUtf8LossyPreservingValid trimmed
  return {
    offset := offset
    nextOffset := offset + trimmed.size.toUInt64
    logLen := fileLen
    data := text
  }

/-- Slice in-memory `rawLog` from `offset` up to `clampedMax` (`4..=262144` bytes). -/
def sliceJobLogBytes (rawLog : ByteArray) (offset : Nat) (maxBytes : Nat := 262144) (isTerminal : Bool := false) : LogSliceResult :=
  let total := rawLog.size
  if offset >= total then
    { offset := total.toUInt64, nextOffset := total.toUInt64, logLen := total.toUInt64, data := "" }
  else
    let cap := max 4 (min 262144 maxBytes)
    let window := rawLog.extract offset (min total (offset + cap))
    sliceJobLogWindow window offset.toUInt64 total.toUInt64 maxBytes isTerminal

/-- Seek-based bounded log file reader (`fstatSize` + `preadByteArray` of at most `262144` bytes)
    so `/jobs/:id/log` polls never load multi-gigabyte logs into memory! -/
def readJobLogSliceBounded
    (logPath? : Option String) (offset : UInt64)
    (maxBytes : Nat := 262144) (isTerminal : Bool := false) : IO LogSliceResult := do
  let empty : LogSliceResult := { offset := 0, nextOffset := 0, logLen := 0, data := "" }
  let some lp := logPath? | return empty
  let cap := max 4 (min 262144 maxBytes)
  match ← LeanSys.Posix.withFd lp 0 (fun fd => do
    let fileLen ← match ← LeanSys.Posix.fstatSize fd with
      | .ok sz => pure sz
      | .error e => return .error e
    if offset >= fileLen then
      return .ok { offset := fileLen, nextOffset := fileLen, logLen := fileLen, data := "" }
    let window ← LeanSys.Posix.preadByteArray fd offset cap
    return .ok (sliceJobLogWindow window offset fileLen cap isTerminal)
  ) with
  | .ok res => return res
  | .error _ => return empty

/-- Seek-based bounded 64 KiB log tail reader (`fstatSize` + `preadByteArray` from `max 0 (size - 65536)`). -/
def readJobLogTailBounded (logPath? : Option String) (tailMax : Nat := 65536) : IO (Option String) := do
  let some lp := logPath? | return none
  match ← LeanSys.Posix.withFd lp 0 (fun fd => do
    let fileLen ← match ← LeanSys.Posix.fstatSize fd with
      | .ok sz => pure sz
      | .error e => return .error e
    if fileLen == 0 then
      return .ok ""
    let startOff : UInt64 := if fileLen > tailMax.toUInt64 then fileLen - tailMax.toUInt64 else 0
    let sub ← LeanSys.Posix.preadByteArray fd startOff tailMax
    -- Skip any leading UTF-8 continuation bytes if `startOff > 0` landed mid-character
    let mut skip : Nat := 0
    if startOff > 0 then
      while skip < min 3 sub.size && (sub.get! skip &&& 0xC0) == 0x80 do
        skip := skip + 1
    let clean := trimIncompleteUtf8Suffix (sub.extract skip sub.size)
    return .ok (decodeUtf8LossyPreservingValid clean)
  ) with
  | .ok s => return some s
  | .error _ => return none

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
  (cmd.splitOn "--sandboxed-scope-exec-cleared-env").length > 1 ||
  (c == "env" && cmd.startsWith "env -i ") ||
  (cmd.splitOn ".sandboxed-sh-opencode-cmd.sh").length > 1 ||
  (cmd.splitOn "orb-native-plan").length > 1

/-- Inspect `/proc` process subtree below `rootPid` (plus any PIDs in `scopeUnit?`, matching
    `src/node/tool_interrupt.rs`) and return active descendant child-tool PIDs
    (never including `rootPid`, harness PIDs, or MCP stdio sidecars). -/
def collectInflightChildToolPids (rootPid : UInt64) (scopeUnit? : Option String := none) : IO (Array UInt32) := do
  let procRoot := System.FilePath.mk "/proc"
  if !(← procRoot.isDir) || rootPid == 0 then return #[]
  let .ok entries ← procRoot.readDir |>.toBaseIO | return #[]
  let mut table : Std.HashMap UInt32 ProcStatEntry := {}
  let mut children : Std.HashMap UInt32 (Array UInt32) := {}
  let mut unitSeeds : Array UInt32 := #[]
  let unitNeedle? := scopeUnit?.map (fun u => s!"/{u}")
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
                  if let some needle := unitNeedle? then
                    if let .ok cg ← IO.FS.readFile (item.path / "cgroup") |>.toBaseIO then
                      if (cg.splitOn "\n").any (fun line => line.trimAscii.toString.endsWith needle) then
                        unitSeeds := unitSeeds.push pid
  let rootU32 := rootPid.toUInt32
  let mut subtree : Std.HashMap UInt32 Unit := {}
  let mut stack : Array UInt32 := #[rootU32] ++ unitSeeds
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
    -- Descend through `systemd-run`, `--sandboxed-scope-exec-cleared-env`, and `env -i` wrappers
    -- (and find any scope root PID whose parent lies outside `subtree`) so the top-level payload shell
    -- (`bash -lc ...` or `lean`) acts as the effective job root rather than being misclassified as a child tool!
    let mut scopeRoots : Array UInt32 := #[rootU32]
    for (p, _) in subtree.toList do
      if let some info := table.get? p then
        if !subtree.contains info.ppid && !scopeRoots.contains p then
          scopeRoots := scopeRoots.push p
    let mut effRoots : Std.HashMap UInt32 Unit := {}
    for sr in scopeRoots do
      let mut cur := sr
      for _ in [0:6] do
        let shouldStep := match table.get? cur with
          | some info =>
            info.comm == "systemd-run" ||
            (info.cmdline.splitOn "--sandboxed-scope-exec-cleared-env").length > 1 ||
            (info.comm == "env" && info.cmdline.startsWith "env -i ")
          | none => false
        if shouldStep then
          if let some kids := children.get? cur then
            if let some firstKid := kids[0]? then
              cur := firstKid
      effRoots := effRoots.insert cur ()
    for (p, _) in subtree.toList do
      if p != rootU32 && !effRoots.contains p then
        let defEntry : ProcStatEntry := { ppid := 0, comm := "", cmdline := "" }
        let info := (table.get? p).getD defEntry
        if !isAuxHarnessHelper info then
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

structure ProcLivenessSample where
  procMissing : UInt8
  isZombie    : UInt8
  actualPid   : UInt32
  actualTicks : UInt64
  bootId      : String := ""
  deriving Repr, BEq, Inhabited

/-- Read the Linux kernel boot UUID (`/proc/sys/kernel/random/boot_id`) so liveness samples and
    signals fail closed if `/proc` is unmounted or `boot_id` rotated across a host reboot. -/
def readKernelBootId : IO String := do
  match ← (IO.FS.readFile (System.FilePath.mk "/proc/sys/kernel/random/boot_id")).toBaseIO with
  | .ok raw => return raw.trimAscii.toString
  | .error _ => return ""

/-- Parse Linux `/proc/<pid>/stat` after the last `)` of `(comm)`:
    - field 3 (`fields[0]` after `") "`) is process state (`Z` / `X` = zombie/dead)
    - field 22 (`fields[19]` after `") "`, 1-based field 22 in `proc(5)`) is `starttime` in clock ticks.
    Handles arbitrary spaces and nested parentheses inside `comm`. -/
def parseProcStatLiveness (statRaw : String) (fallbackPid : UInt32 := 0) (bootId : String := "") : ProcLivenessSample := Id.run do
  let partsOpen := statRaw.splitOn "("
  if partsOpen.length < 2 then
    return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
  let pidParsed : UInt32 :=
    (partsOpen.head!.trimAscii.toString.toNat?.map (·.toUInt32)).getD fallbackPid
  let afterOpen := String.intercalate "(" partsOpen.tail!
  let partsClose := afterOpen.splitOn ") "
  if partsClose.length < 2 then
    return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
  let rest := partsClose.getLast!
  let fields := (rest.splitOn " ").filter (fun s => !s.isEmpty) |>.toArray
  if fields.size < 20 then
    return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
  let st := fields[0]!
  let ticksRaw := fields[19]!.trimAscii.toString
  let some ticksNat := ticksRaw.toNat?
    | return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
  let ticks := ticksNat.toUInt64
  if ticks == 0 || pidParsed == 0 then
    return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
  let zombie : UInt8 := if st == "Z" || st == "X" || st == "x" then 1 else 0
  return {
    procMissing := 0
    isZombie := zombie
    actualPid := pidParsed
    actualTicks := ticks
    bootId := bootId
  }

def sampleProcLiveness (pid : UInt64) : IO ProcLivenessSample := do
  if pid == 0 || pid > 0xFFFFFFFF then
    return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
  let bootId ← readKernelBootId
  if bootId.isEmpty then
    return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
  let statPath := System.FilePath.mk s!"/proc/{pid}/stat"
  match ← (IO.FS.readFile statPath).toBaseIO with
  | .ok raw => return parseProcStatLiveness raw pid.toUInt32 bootId
  | .error _ => return { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }

/-- Execute one `Orb.ManagedNode.ProcOp` (`0=observeAlive`, `1=observeDead`, `2=sigterm`, `3=sigkill`)
    against `(expectedPid, expectedTicks, expectedBootId)` by re-reading `/proc/<pid>/stat` +
    `/proc/sys/kernel/random/boot_id` and gating via `Orb.ManagedNode.stepProcSlice` and
    `Orb.ManagedNode.verifyProcLivenessAdmit`. Returns `(nextPhase, admitted)`. Never signals a reused
    or unsampled PID! -/
def stepVerifiedPgrpOp
    (curPhase opCode : UInt8) (expectedPid : UInt64) (expectedTicks : UInt64)
    (sampleOverride? : Option ProcLivenessSample := none)
    (expectedBootId : String := "") : IO (UInt8 × Bool) := do
  if expectedPid == 0 || expectedPid > 0xFFFFFFFF || expectedTicks == 0 then
    return (2, false)
  let rawSample ← match sampleOverride? with
    | some s => pure s
    | none => sampleProcLiveness expectedPid
  let bootMismatch :=
    !expectedBootId.isEmpty && (rawSample.bootId.isEmpty || rawSample.bootId != expectedBootId)
  let sample : ProcLivenessSample :=
    if bootMismatch then
      { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := "" }
    else
      rawSample
  let admit := Orb.ManagedNode.verifyProcLivenessAdmit curPhase opCode sample.procMissing sample.isZombie
    expectedPid.toUInt32 sample.actualPid expectedTicks sample.actualTicks
  if admit != 1 then
    return (curPhase, false)
  let stIn : Orb.ManagedNode.ProcSliceState := {
    phaseCode := curPhase
    leaderPid := expectedPid.toUInt32
    leaderTicks := expectedTicks
  }
  let ev : Orb.ManagedNode.ProcSliceEvent := {
    opCode := opCode
    procMissing := sample.procMissing
    isZombie := sample.isZombie
    actualPid := sample.actualPid
    actualTicks := sample.actualTicks
  }
  let (stOut, effs) := Orb.ManagedNode.stepProcSlice stIn ev
  if effs.isEmpty then
    return (curPhase, false)
  for eff in effs do
    match eff with
    | .persistLeader _ _ _ => pure ()
    | .sendSignal sig p ticks =>
      if p > 1 && ticks != 0 && sample.procMissing == 0 && sample.isZombie == 0 && !bootMismatch then
        if Orb.ManagedNode.verifyProcLivenessAdmit curPhase opCode sample.procMissing sample.isZombie
            expectedPid.toUInt32 sample.actualPid expectedTicks sample.actualTicks == 1 then
          OrbNode.Posix.killPgrp p.toUInt64 sig.toUInt32
  return (stOut.phaseCode, true)

/-- Escalate termination (`alive -> termSent (SIGTERM) -> killSent (SIGKILL) -> dead`) for a tracked
    process group `(pid, startTicks, expectedBootId)` with mandatory `/proc/<pid>/stat` + `boot_id`
    re-verification via `Orb.ManagedNode.verifyProcLivenessAdmit` before EVERY signal (`SM-20`).
    If the process already exited, `/proc` is missing (`procMissing == 1`), became a zombie, or its
    PID was reused with different `startTicks`, transitions cleanly via `observeDead` without signalling. -/
def terminateVerifiedPgrp
    (curPhase : UInt8) (pid : UInt64) (startTicks : UInt64)
    (sampleOverride? : Option ProcLivenessSample := none)
    (expectedBootId : String := "") : IO UInt8 := do
  if pid ≤ 1 || pid > 0xFFFFFFFF then
    return 2
  if startTicks == 0 then
    return 2
  let mut ph := if curPhase == 0 then 1 else curPhase
  if ph == 2 then
    return 2
  if ph == 1 then
    let (phTerm, sentTerm) ← stepVerifiedPgrpOp ph 2 pid startTicks sampleOverride? expectedBootId
    ph := phTerm
    if !sentTerm then
      let (phDead, _) ← stepVerifiedPgrpOp ph 1 pid startTicks sampleOverride? expectedBootId
      return phDead
  if ph == 3 then
    let (phKill, sentKill) ← stepVerifiedPgrpOp ph 3 pid startTicks sampleOverride? expectedBootId
    ph := phKill
    if !sentKill then
      let (phDead, _) ← stepVerifiedPgrpOp ph 1 pid startTicks sampleOverride? expectedBootId
      return phDead
  let (phFinal, obsDead) ← stepVerifiedPgrpOp ph 1 pid startTicks sampleOverride? expectedBootId
  return if obsDead then phFinal else ph

/-- Discover active container leaders for `workspaceId` strictly from the durable `container_leaders`
    SQLite runtime table verified via `/proc/<leader_pid>/stat` + `Orb.ManagedNode.stepProcSlice`
    (never by scanning `/proc/*/environ`, `SM-20`). Marks stale/dead/reused-PID leaders `dead (2)`. -/
def resolveLiveContainerLeaders
    (l : Ledger) (workspaceId : String) : IO (Array ContainerLeaderRecord) := do
  let .ok allRows ← l.listContainerLeaders | return #[]
  let nowTs ← nowRfc3339
  let mut live : Array ContainerLeaderRecord := #[]
  for rec in allRows do
    if rec.workspaceId == workspaceId then
      if rec.nodeBootEpoch != l.nodeBootEpoch || rec.procPhase == 2 || rec.leaderPid == 0 || rec.startTicks == 0 then
        if rec.procPhase != 2 then
          discard <| l.upsertContainerLeader { rec with procPhase := 2, updatedAt := nowTs }
      else
        let sample ← sampleProcLiveness rec.leaderPid.toUInt64
        let probePh : UInt8 := if rec.procPhase == 0 || rec.procPhase == 1 then rec.procPhase else 1
        let aliveAdmit := Orb.ManagedNode.verifyProcLivenessAdmit probePh 0 sample.procMissing sample.isZombie
          rec.leaderPid sample.actualPid rec.startTicks sample.actualTicks
        let stIn : Orb.ManagedNode.ProcSliceState := {
          phaseCode := probePh
          leaderPid := rec.leaderPid
          leaderTicks := rec.startTicks
        }
        let evAlive : Orb.ManagedNode.ProcSliceEvent := {
          opCode := 0
          procMissing := sample.procMissing
          isZombie := sample.isZombie
          actualPid := sample.actualPid
          actualTicks := sample.actualTicks
        }
        let (stAlive, effAlive) := Orb.ManagedNode.stepProcSlice stIn evAlive
        if aliveAdmit == 1 && !effAlive.isEmpty then
          let nextRec := { rec with procPhase := stAlive.phaseCode, updatedAt := nowTs }
          if rec.procPhase != stAlive.phaseCode then
            discard <| l.upsertContainerLeader nextRec
          live := live.push nextRec
        else
          let (phDead, _) ← stepVerifiedPgrpOp rec.procPhase 1 rec.leaderPid.toUInt64 rec.startTicks (some sample)
          let deadCode : UInt8 := if phDead == 2 then 2 else 2
          discard <| l.upsertContainerLeader { rec with procPhase := deadCode, updatedAt := nowTs }
  return live

def sigintInflightChildTools (rootPid : UInt64) (scopeUnit? : Option String := none)
    (expectedRootTicks : UInt64 := 0) (expectedBootId : String := "") : IO Nat := do
  if expectedRootTicks == 0 then
    return 0
  let (_, rootAlive) ← stepVerifiedPgrpOp 1 0 rootPid expectedRootTicks none expectedBootId
  if !rootAlive then
    return 0
  let pids ← collectInflightChildToolPids rootPid scopeUnit?
  let mut count : Nat := 0
  let revPids := pids.reverse
  for p in revPids do
    if p > 1 then
      let sample0 ← sampleProcLiveness p.toUInt64
      if sample0.procMissing == 0 && sample0.isZombie == 0 && sample0.actualTicks != 0 &&
         !sample0.bootId.isEmpty && (expectedBootId.isEmpty || sample0.bootId == expectedBootId) then
        let sample1 ← sampleProcLiveness p.toUInt64
        if sample1.bootId == sample0.bootId &&
           Orb.ManagedNode.verifyProcLivenessAdmit 1 2 sample1.procMissing sample1.isZombie
             p sample1.actualPid sample0.actualTicks sample1.actualTicks == 1 then
          let rc ← killSig (Int64.ofNat p.toNat) 2
          if rc == 0 then
            count := count + 1
  return count

/-! ### Transient Systemd Scope Containment (`systemd-run --scope`) -/

inductive SystemdScopeMode where
  | system
  | user
  deriving Repr, BEq, Inhabited

structure SystemdScope where
  unit           : String
  mode           : SystemdScopeMode
  userRuntimeDir : Option String := none
  deriving Repr, BEq, Inhabited

private def nodeScopePrefix (nodeId workDir : String) : String :=
  let raw := (nodeId ++ String.singleton (Char.ofNat 0) ++ workDir).toUTF8
  let hex16 := (bytesToHexLower (sha256Bytes raw)).take 32 |>.toString
  s!"sandboxed-node-{hex16}"

private def detectSystemdScopeMode : IO (Option (SystemdScopeMode × Option String)) := do
  if !(← (System.FilePath.mk "/run/systemd/system").isDir) then
    return none
  let hasSystemdRun ← do
    match ← (IO.Process.output { cmd := "systemd-run", args := #["--version"] }).toBaseIO with
    | .ok out => pure (out.exitCode == 0)
    | .error _ => pure false
  if !hasSystemdRun then
    return none
  let uid ← OrbNode.Posix.geteuid
  if uid == 0 then
    match ← (IO.Process.output { cmd := "systemctl", args := #["show", "--property=Version", "--value"] }).toBaseIO with
    | .ok out => if out.exitCode == 0 then return some (.system, none) else return none
    | .error _ => return none
  let mut candidates : Array String := #[]
  if let some xdg ← IO.getEnv "XDG_RUNTIME_DIR" then
    let clean := xdg.trimAscii.toString
    if !clean.isEmpty then candidates := candidates.push clean
  let derived := s!"/run/user/{uid}"
  if !candidates.contains derived then
    candidates := candidates.push derived
  for rtDir in candidates do
    let busPath := s!"{rtDir}/bus"
    match ← LeanSys.Posix.unixConnect busPath with
    | .ok fd =>
      discard <| LeanSys.Posix.closeFd fd
      return some (.user, some rtDir)
    | .error _ => pure ()
  return none

private def parseJobCpuWeight (raw? : Option String) : Option String := do
  let t := (← raw?).trimAscii.toString
  if t.isEmpty then none
  else if t == "idle" then some "idle"
  else
    let w ← t.toNat?
    if 1 ≤ w && w ≤ 10000 then some (toString w) else none

private def parseJobCpuQuota (raw? : Option String) : Option String := do
  let t := (← raw?).trimAscii.toString
  if t.isEmpty then none
  else if t == "infinity" then some "infinity"
  else if t.endsWith "%" then
    let numPart := (t.dropEnd 1).toString
    let parts := numPart.splitOn "."
    match parts with
    | [whole] =>
      let n ← whole.toNat?
      if n > 0 then some t else none
    | [whole, frac] =>
      let nw ← whole.toNat?
      let nf ← frac.toNat?
      if nw > 0 || nf > 0 then some t else none
    | _ => none
  else none

private def computeJobMemoryLimitBytes (cfg : NodeConfig) : IO UInt64 := do
  if let some raw ← IO.getEnv "SANDBOXED_NODE_JOB_MEMORY_BYTES" then
    if let some n := raw.trimAscii.toString.toNat? then
      if n > 0 then
        return n.toUInt64
  let st ← OrbNode.Posix.hostStats cfg.workDir
  let total := if st.memTotalBytes > 0 then st.memTotalBytes else (8 * 1024 * 1024 * 1024)
  let denom := cfg.capacityTotal.toUInt64 + cfg.sideCapacity.toUInt64
  return max (256 * 1024 * 1024) ((total / 5 * 4) / max 1 denom)

private def resolveTrampolineExe : IO (Option String) := do
  match ← (IO.appPath).toBaseIO with
  | .ok p =>
    let raw := p.toString
    let cand := if raw.endsWith " (deleted)" then (raw.dropEnd 10).toString else raw
    let st ← statPath cand
    if st.exists_ && st.isReg then
      return some cand
    return none
  | .error _ => return none

/-- Wrap `(prog, args, envPairs)` in a transient `systemd-run --scope` unit when a usable systemd
    manager is available on Linux; degrades cleanly to direct `-pgid` spawn in container/test hosts. -/
private def wrapWithSystemdScope
    (cfg : NodeConfig) (isSync : Bool) (scopeUuid : String) (timeoutSecs? : Option UInt64)
    (prog : String) (args : Array String) (envPairs : Array (String × String)) :
    IO (String × Array String × Array (String × String) × Option SystemdScope) := do
  let some (mode, userRt?) ← detectSystemdScopeMode
    | return (prog, args, envPairs, none)
  let some trampExe ← resolveTrampolineExe
    | return (prog, args, envPairs, none)
  let cleanHex := (scopeUuid.splitOn "-").foldl (· ++ ·) ""
  let kindTag := if isSync then "sync" else "job"
  let unit := s!"{nodeScopePrefix cfg.nodeId cfg.workDir}-{kindTag}-{cleanHex}.scope"
  let scope : SystemdScope := { unit := unit, mode := mode, userRuntimeDir := userRt? }
  let memMax ← computeJobMemoryLimitBytes cfg
  let memHigh := (memMax / 10) * 9
  let cpuWeight? := parseJobCpuWeight (← IO.getEnv "SANDBOXED_NODE_JOB_CPU_WEIGHT")
  let cpuQuota? := parseJobCpuQuota (← IO.getEnv "SANDBOXED_NODE_JOB_CPU_QUOTA")
  let mut sArgs : Array String := #[]
  let mut sEnv := envPairs
  if mode == .user then
    sArgs := sArgs.push "--user"
    if let some rtDir := userRt? then
      sEnv := (sEnv.filter (fun (k, _) => k != "XDG_RUNTIME_DIR" && k != "DBUS_SESSION_BUS_ADDRESS"))
        |>.push ("XDG_RUNTIME_DIR", rtDir)
        |>.push ("DBUS_SESSION_BUS_ADDRESS", s!"unix:path={rtDir}/bus")
  if let some pathVal ← IO.getEnv "PATH" then
    if !(sEnv.any (fun (k, _) => k == "PATH")) then
      sEnv := sEnv.push ("PATH", pathVal)
  sArgs := sArgs ++ #[
    "--scope",
    "--quiet",
    s!"--unit={unit}",
    "--property=KillMode=control-group",
    s!"--property=MemoryMax={memMax}",
    s!"--property=MemoryHigh={memHigh}",
    "--property=MemorySwapMax=0"
  ]
  if let some w := cpuWeight? then
    sArgs := sArgs.push s!"--property=CPUWeight={w}"
  if let some q := cpuQuota? then
    sArgs := sArgs.push s!"--property=CPUQuota={q}"
  if let some secs := timeoutSecs? then
    sArgs := sArgs.push s!"--property=RuntimeMaxSec={max 1 secs}"
  sArgs := sArgs.push "--"
  sArgs := sArgs.push trampExe
  sArgs := sArgs.push "--sandboxed-scope-exec-cleared-env"
  for (k, _) in envPairs do
    sArgs := sArgs.push k
  sArgs := sArgs.push "--"
  sArgs := sArgs.push prog
  sArgs := sArgs ++ args
  return ("systemd-run", sArgs, sEnv, some scope)

/-- Immediately send `SIGKILL` to every process in `SystemdScope` (`systemctl kill --kill-who=all --signal=SIGKILL`),
    then `systemctl stop` and `systemctl reset-failed` so even `SIGTERM`-ignoring or `setsid()`-detached
    descendants inside the job's cgroup are reaped instantaneously without waiting for `TimeoutStopSec`! -/
def stopSystemdScope (scope? : Option SystemdScope) : IO Unit := do
  let some sc := scope? | return
  let mut baseArgs : Array String := #[]
  let mut envMods : Array (String × Option String) := #[]
  if sc.mode == .user then
    baseArgs := baseArgs.push "--user"
    if let some rtDir := sc.userRuntimeDir then
      envMods := #[
        ("XDG_RUNTIME_DIR", some rtDir),
        ("DBUS_SESSION_BUS_ADDRESS", some s!"unix:path={rtDir}/bus")
      ]
  discard <| (IO.Process.output {
    cmd := "systemctl", args := baseArgs ++ #["kill", "--kill-who=all", "--signal=SIGKILL", sc.unit], env := envMods
  }).toBaseIO
  discard <| (IO.Process.output {
    cmd := "systemctl", args := baseArgs ++ #["stop", sc.unit], env := envMods
  }).toBaseIO
  discard <| (IO.Process.output {
    cmd := "systemctl", args := baseArgs ++ #["reset-failed", sc.unit], env := envMods
  }).toBaseIO

/-- Stop and verify retirement of a post-restart `.lost` job's systemd scope (`src/node/runner.rs:2245-2290`).
    Returns `true` ONLY when `systemctl stop` + `reset-failed` succeeded OR `systemctl show --property=LoadState`
    confirmed `"not-found"`, so Core never retires a workspace ownership fence while D-Bus/systemctl failed! -/
def stopSystemdScopeVerified (sc : SystemdScope) : IO Bool := do
  let mut baseArgs : Array String := #[]
  let mut envMods : Array (String × Option String) := #[]
  if sc.mode == .user then
    baseArgs := baseArgs.push "--user"
    if let some rtDir := sc.userRuntimeDir then
      envMods := #[
        ("XDG_RUNTIME_DIR", some rtDir),
        ("DBUS_SESSION_BUS_ADDRESS", some s!"unix:path={rtDir}/bus")
      ]
  discard <| (IO.Process.output {
    cmd := "timeout"
    args := #["-k", "2", "10s", "systemctl"] ++ baseArgs ++ #["kill", "--kill-who=all", "--signal=SIGKILL", sc.unit]
    env := envMods
  }).toBaseIO
  let stopRes ← (IO.Process.output {
    cmd := "timeout"
    args := #["-k", "2", "10s", "systemctl"] ++ baseArgs ++ #["stop", sc.unit]
    env := envMods
  }).toBaseIO
  if let .ok so := stopRes then
    if so.exitCode == 0 then
      let resetRes ← (IO.Process.output {
        cmd := "timeout"
        args := #["-k", "2", "10s", "systemctl"] ++ baseArgs ++ #["reset-failed", sc.unit]
        env := envMods
      }).toBaseIO
      if let .ok ro := resetRes then
        if ro.exitCode == 0 then
          return true
  let showRes ← (IO.Process.output {
    cmd := "timeout"
    args := #["-k", "2", "10s", "systemctl"] ++ baseArgs ++ #["show", "--property=LoadState", "--value", sc.unit]
    env := envMods
  }).toBaseIO
  if let .ok sho := showRes then
    if sho.exitCode == 0 && sho.stdout.trimAscii.toString == "not-found" then
      return true
  return false

/-- Stop a post-restart `.lost` job's transient systemd scope outside `Std.Mutex NodeRuntime`.
    On non-systemd hosts (`detectSystemdScopeMode == none`), returns `true`. -/
def stopLostJobScopeOutsideLock (nodeId workDir jid : String) : IO Bool := do
  let some (mode, userRt?) ← detectSystemdScopeMode
    | return true
  let cleanHex := (jid.splitOn "-").foldl (· ++ ·) ""
  let unit := s!"{nodeScopePrefix nodeId workDir}-job-{cleanHex}.scope"
  stopSystemdScopeVerified { unit := unit, mode := mode, userRuntimeDir := userRt? }

/-- Detach `stopSystemdScope` and `cleanupIsolatedCheckout` onto a background worker so callers holding
    `Std.Mutex NodeRuntime` never block on `systemctl` D-Bus / `rm -rf` subprocess I/O! -/
def teardownJobResourcesAsync
    (scope? : Option SystemdScope) (iso? : Option String)
    (scratchFinalize? : Option (String × SqliteBackend × String × String × UInt64 × UInt64) := none) : IO Unit := do
  if scope?.isNone && iso?.isNone && scratchFinalize?.isNone then return
  discard <| IO.asTask do
    stopSystemdScope scope?
    if let some dir := iso? then
      if !dir.isEmpty then
        discard <| (IO.Process.output { cmd := "rm", args := #["-rf", dir] }).toBaseIO
    if let some (workDir, backend, scratchId, scratchDir, bootEp, claimSeq) := scratchFinalize? then
      discard <| retireScratchOutsideLedger workDir backend scratchId scratchDir bootEp claimSeq

/-- Reap any leftover `sandboxed-node-<prefix>-{sync,job}-*.scope` units from a previous daemon start. -/
def reapPreviousScopesOnStart (cfg : NodeConfig) : IO Unit := do
  let some (mode, userRt?) ← detectSystemdScopeMode
    | return
  let pfx := nodeScopePrefix cfg.nodeId cfg.workDir
  let syncPfx := s!"{pfx}-sync-"
  let jobPfx := s!"{pfx}-job-"
  let mut baseArgs : Array String := #[]
  let mut envMods : Array (String × Option String) := #[]
  if mode == .user then
    baseArgs := baseArgs.push "--user"
    if let some rtDir := userRt? then
      envMods := #[
        ("XDG_RUNTIME_DIR", some rtDir),
        ("DBUS_SESSION_BUS_ADDRESS", some s!"unix:path={rtDir}/bus")
      ]
  let listArgs := baseArgs ++ #[
    "list-units", "--all", "--full", "--type=scope", "--plain", "--no-legend",
    s!"{syncPfx}*.scope", s!"{jobPfx}*.scope"
  ]
  if let .ok out ← (IO.Process.output { cmd := "systemctl", args := listArgs, env := envMods }).toBaseIO then
    if out.exitCode == 0 then
      for line in out.stdout.splitOn "\n" do
        let unit := ((line.trimAscii.toString.splitOn " ").headD "").trimAscii.toString
        if (unit.startsWith syncPfx || unit.startsWith jobPfx) && unit.endsWith ".scope" then
          stopSystemdScope (some { unit := unit, mode := mode, userRuntimeDir := userRt? })

structure LaunchingSlot where
  forced    : Bool
  sideLane  : Bool
  coordLane : Bool
  missionId : String
  trackBg   : Bool
  deriving Repr, Inhabited

structure LiveProc where
  pid              : UInt64
  startTicks       : UInt64 := 0
  bootId           : String := ""
  procPhase        : UInt8 := 1
  startedEp        : UInt64
  timeoutSecs?     : Option UInt64
  forced           : Bool
  sideLane         : Bool
  coordLane        : Bool
  artifacts        : Array String
  cwd              : String
  isolatedCheckout : Option String := none
  systemdScope?    : Option SystemdScope := none
  scratchDir?      : Option String := none
  machineName?     : Option String := none
  workspaceId      : String := ""
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
  systemdScope?    : Option SystemdScope := none
  scratchDir?      : Option String := none
  machineName?     : Option String := none
  workspaceId      : String := ""
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
  queuedPayloads : Std.HashMap String JVal := {}
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
  if (← cachedLake.pathExists) && !(← cachedLake.isDir) then return true
  let optLake := System.FilePath.mk "/opt/orb/elan/bin/lake"
  if (← optLake.pathExists) && !(← optLake.isDir) then return true
  let pathStr := (← IO.getEnv "PATH").getD "/usr/local/bin:/usr/bin:/bin"
  for d in (pathStr.splitOn ":").filter (·.startsWith "/") do
    let cand := System.FilePath.mk d / "lake"
    if (← cand.pathExists) && !(← cand.isDir) then return true
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

private def prepareJobOutsideLockInner
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
        let segs := (cwdRel.splitOn "/").filter (fun s => !s.isEmpty)
        match ← isSymlinkFreePath (System.FilePath.mk checkoutDir) segs with
        | some st =>
          if !st.isDir then
            cleanupIsolatedCheckout isolatedCheckout
            return .error s!"cwd_rel '{cwdRel}' does not exist in checkout"
          cwd := (System.FilePath.mk checkoutDir / cwdRel).toString
        | none =>
          cleanupIsolatedCheckout isolatedCheckout
          return .error s!"cwd_rel '{cwdRel}' does not exist or traverses a symlink in checkout"
    let cmdParts := ((payload.fieldArr? "command").getD #[]).filterMap JVal.asStr?
    if h : 0 < cmdParts.size then
      prog := cmdParts[0]
      args := cmdParts.extract 1 cmdParts.size
    else
      prog := "true"
    let usesFanout := prog != "turbo-lean" || args.contains "build"
    let st ← OrbNode.Posix.hostStats cfg.workDir
    let repo := ((srcObj.fieldStr? "repo").getD "").trimAscii.toString
    let payloadEnv := ((payload.field? "env") >>= JVal.asObj?).getD #[]
    envPairs ← buildLeanJobEnv cfg.workDir repo st.cpuTotal cfg.capacityTotal
      cfg.envAllowlist usesFanout payloadEnv
    if prog == "turbo-lean" then
      let searchPath := (envPairs.find? (fun (k, _) => k == "PATH")).map Prod.snd
      let helpOut ← (IO.Process.output {
        cmd := "turbo-lean"
        args := #["--help"]
        env := match searchPath with | some p => #[("PATH", some p)] | none => #[]
      }).toBaseIO
      if let .ok ho := helpOut then
        let txt := ho.stdout ++ ho.stderr
        let mut prefixFlags : Array String := #[]
        if (txt.splitOn "--no-daemon").length > 1 && !args.contains "--no-daemon" then
          prefixFlags := prefixFlags.push "--no-daemon"
        if (txt.splitOn "--no-telemetry").length > 1 && !args.contains "--no-telemetry" then
          prefixFlags := prefixFlags.push "--no-telemetry"
        if (txt.splitOn "--no-auto-worktree-link").length > 1 && !args.contains "--no-auto-worktree-link" then
          prefixFlags := prefixFlags.push "--no-auto-worktree-link"
        args := prefixFlags ++ args
    envPairs := mergeEnvPair envPairs "SANDBOXED_MISSION_ID" missionId
    envPairs := mergeEnvPair envPairs "SANDBOXED_JOB_ID" jid
    envPairs := mergeEnvPair envPairs "SANDBOXED_REMOTE_EXECUTION" "1"
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
  let scratchCand := (System.FilePath.mk cfg.workDir / ".scratch" / s!"job-{jid}").toString
  IO.FS.createDirAll scratchCand
  let wsId := ((payload.fieldStr? "workspace_id").orElse (fun _ => payload.fieldStr? "companion_of")).getD missionId
  let machName? := ((payload.fieldStr? "machine_name").orElse (fun _ => payload.fieldStr? "container_machine")).map
    (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
  let (wrappedProg, wrappedArgs, wrappedEnvPairs, scope?) ←
    wrapWithSystemdScope cfg false jid timeoutSecs? prog args envPairs
  return .ok {
    jid := jid
    forced := forced
    sideLane := sideLane
    coordLane := coordLane
    timeoutSecs? := timeoutSecs?
    logPath := logPath
    cwd := cwd
    isolatedCheckout := isolatedCheckout
    systemdScope? := scope?
    scratchDir? := some scratchCand
    machineName? := machName?
    workspaceId := wsId
    prog := wrappedProg
    args := wrappedArgs
    envKv := flattenEnvKv wrappedEnvPairs
    artifacts := artifacts
  }

/-- Clean up any partial per-job isolated checkout directory `<workDir>/checkouts/<repoHash16>/jobs/<jid>`. -/
private def cleanupPartialJobCheckout (workDir : String) (jid : String) (payload : JVal) : IO Unit := do
  if let some rawRepo := (payload.field? "source").bind (·.fieldStr? "repo") then
    let repo := rawRepo.trimAscii.toString
    let rh16 := (bytesToHexLower (sha256Bytes repo.toUTF8)).take 16 |>.toString
    let cand := (System.FilePath.mk workDir / "checkouts" / rh16 / "jobs" / jid).toString
    discard <| (IO.Process.output { cmd := "rm", args := #["-rf", cand] }).toBaseIO

/-- Materialize checkout & environment outside `Std.Mutex NodeRuntime`, catching any `IO.Error`
    and cleaning up any partial per-job isolated checkout on BOTH `.ok (.error _)` and `.error _`
    so `launching` slots and disk checkouts can never strand! -/
def prepareJobOutsideLock
    (cfg : NodeConfig) (jid missionId : String) (payload : JVal) (logPath : String)
    (forced sideLane coordLane : Bool) : IO (Except String PreparedJobSpec) := do
  match ← (prepareJobOutsideLockInner cfg jid missionId payload logPath forced sideLane coordLane).toBaseIO with
  | .ok (.ok spec) => return .ok spec
  | .ok (.error msg) =>
    cleanupPartialJobCheckout cfg.workDir jid payload
    return .error msg
  | .error ioErr =>
    cleanupPartialJobCheckout cfg.workDir jid payload
    return .error s!"job preparation I/O error: {ioErr}"

/-- Commit a `PreparedJobSpec` into `NodeRuntime` (clearing its `launching` reservation and `queuedPayloads`,
    and spawning `-pgid` / transient `systemd-run --scope` unless cancelled while preparing). -/
def commitPreparedJob
    (rt0 : NodeRuntime) (jid : String) (prepRes : Except String PreparedJobSpec)
    (postSpawnSampleOverride? : Option ProcLivenessSample := none)
    (injectPostSpawnUpdateErr? : Option String := none) : IO NodeRuntime := do
  let wasLaunching := rt0.launching.get? jid
  let mut rt := {
    rt0 with
    launching := rt0.launching.erase jid
    queuedPayloads := rt0.queuedPayloads.erase jid
  }
  let releaseDebt (r : NodeRuntime) : NodeRuntime :=
    match wasLaunching with
    | some sl =>
      if !sl.forced && !sl.sideLane && !sl.coordLane && r.shrinkDebt > 0 then
        { r with shrinkDebt := r.shrinkDebt - 1 }
      else r
    | none => r
  let scratchFinOf (bootEp claimSeq : UInt64) (s? : Option String) :
      Option (String × SqliteBackend × String × String × UInt64 × UInt64) :=
    s?.map (fun sd => (rt0.cfg.workDir, rt0.ledger.sqliteBackend, jid, sd, bootEp, claimSeq))
  let some cur := rt.ledger.jobs.get? jid
    | if let .ok spec := prepRes then
        teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout (scratchFinOf 0 0 spec.scratchDir?)
      return releaseDebt rt
  let curOpStr := if cur.operationId.isEmpty then jid else cur.operationId
  let curClaimSeq := operationIdToken curOpStr
  if cur.nodeBootEpoch != rt.ledger.nodeBootEpoch then
    if let .ok spec := prepRes then
      teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout
        (scratchFinOf cur.nodeBootEpoch curClaimSeq spec.scratchDir?)
    let nowStale ← nowRfc3339
    if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
      r with
      state := .lost
      phaseCode := 2
      finishedAt? := some (r.finishedAt?.getD nowStale)
      error? := some (r.error?.getD "refused adopting job from prior node_boot_epoch")
    }) then
      rt := { rt with ledger := l' }
    return releaseDebt rt
  if cur.state != .queued then
    if let .ok spec := prepRes then
      teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout
        (scratchFinOf cur.nodeBootEpoch curClaimSeq spec.scratchDir?)
    return releaseDebt rt
  let nowTs ← nowRfc3339
  match prepRes with
  | .error errMsg =>
    let defScratch := (System.FilePath.mk rt.cfg.workDir / ".scratch" / s!"job-{jid}").toString
    discard <| retireScratchOutsideLedger rt.cfg.workDir rt.ledger.sqliteBackend jid defScratch
      cur.nodeBootEpoch curClaimSeq
    if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
      r with state := .failed, finishedAt? := some nowTs, error? := some errMsg
    }) then
      rt := { rt with ledger := l' }
    return releaseDebt rt
  | .ok spec =>
    let mut preExtraSql := ""
    if let some sd := spec.scratchDir? then
      let parentPath := (System.FilePath.mk sd).parent.map (·.toString) |>.getD ""
      if let (some pId, some dId) ← pure (← readPathIdentity? parentPath, ← readPathIdentity? sd) then
        preExtraSql := preExtraSql ++ scratchReceiptUpsertSql {
          id := jid
          missionId := cur.missionId
          jobId? := some jid
          nodeBootEpoch := cur.nodeBootEpoch
          claimSeq := curClaimSeq
          parentIdentity := pId
          directoryIdentity := dId
          retiredAt? := none
        } ++ " "
    let nowEp ← OrbNode.Posix.nowEpoch
    match ← (OrbNode.Posix.spawnJobPgrp spec.prog spec.args spec.envKv spec.cwd spec.logPath).toBaseIO with
    | .error e =>
      teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout
        (scratchFinOf cur.nodeBootEpoch curClaimSeq spec.scratchDir?)
      if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
        r with state := .failed, finishedAt? := some nowTs, error? := some (toString e), forced := spec.forced
      }) then
        rt := { rt with ledger := l' }
      return releaseDebt rt
    | .ok pid =>
      let sample ← match postSpawnSampleOverride? with
        | some s => pure s
        | none => sampleProcLiveness pid
      let initTicks := sample.actualTicks
      let initBootId := sample.bootId
      if sample.procMissing == 1 || initTicks == 0 || initBootId.isEmpty then
        let wFast ← OrbNode.Posix.pollPid pid
        let doneFast := (wFast &&& 1) == 1
        if doneFast && postSpawnSampleOverride?.isNone then
          let codeU32 := (wFast >>> 32).toUInt32
          let codeInt : Int := if codeU32 == 0xFFFFFFFF then -1 else Int.ofNat codeU32.toNat
          let arts ← collectArtifactsConfined spec.cwd spec.artifacts
          teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout
            (scratchFinOf cur.nodeBootEpoch curClaimSeq spec.scratchDir?)
          let nextState : JobState := if codeInt == 0 then .succeeded else .failed
          if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
            r with
            state := if r.state == .cancelled then .cancelled else nextState
            exitCode? := some codeInt
            startedAt? := some nowTs
            finishedAt? := some nowTs
            logPath? := some spec.logPath
            forced := spec.forced
            pid := pid
            startTicks := 0
            procPhase := 2
            artifacts := arts
          }) preExtraSql then
            rt := { rt with ledger := l' }
          return releaseDebt rt
        else
          -- Fail closed without signalling by bare PID when `(starttime_ticks, boot_id)` could not be sampled!
          teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout
            (scratchFinOf cur.nodeBootEpoch curClaimSeq spec.scratchDir?)
          let unsampledErr :=
            s!"proc_liveness_unsampled: refused bare-PID signal when /proc/{pid}/stat starttime_ticks or boot_id could not be sampled"
          if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
            r with
            state := .failed
            startedAt? := some nowTs
            finishedAt? := some nowTs
            logPath? := some spec.logPath
            forced := spec.forced
            pid := pid
            startTicks := 0
            procPhase := 0
            error? := some unsampledErr
          }) preExtraSql then
            rt := { rt with ledger := l' }
          return releaseDebt rt
      let (initProcPh, _) ← stepVerifiedPgrpOp 0 0 pid initTicks (some sample) initBootId
      let mut extraSql := preExtraSql
      if let some mName := spec.machineName? then
        if initTicks != 0 && pid ≤ 0xFFFFFFFF then
          extraSql := extraSql ++ containerLeaderUpsertSql {
            workspaceId := if spec.workspaceId.isEmpty then cur.missionId else spec.workspaceId
            machineName := mName
            leaderPid := pid.toUInt32
            startTicks := initTicks
            nodeBootEpoch := rt.ledger.nodeBootEpoch
            procPhase := initProcPh
            jobId := jid
            updatedAt := nowTs
          } ++ " "
      let postSpawnUpdateRes ← match injectPostSpawnUpdateErr? with
        | some simErr => pure (.error simErr)
        | none =>
          rt.ledger.updateJob jid (fun r => .ok {
            r with
            state := .running
            startedAt? := some nowTs
            logPath? := some spec.logPath
            forced := spec.forced
            pid := pid
            startTicks := initTicks
            procPhase := initProcPh
          }) extraSql
      match postSpawnUpdateRes with
      | .ok (l', _) =>
        let lp : LiveProc := {
          pid := pid
          startTicks := initTicks
          bootId := initBootId
          procPhase := initProcPh
          startedEp := nowEp
          timeoutSecs? := spec.timeoutSecs?
          forced := spec.forced
          sideLane := spec.sideLane
          coordLane := spec.coordLane
          artifacts := spec.artifacts
          cwd := spec.cwd
          isolatedCheckout := spec.isolatedCheckout
          systemdScope? := spec.systemdScope?
          scratchDir? := spec.scratchDir?
          machineName? := spec.machineName?
          workspaceId := if spec.workspaceId.isEmpty then cur.missionId else spec.workspaceId
        }
        return { rt with ledger := l', liveProcs := rt.liveProcs.insert jid lp }
      | .error updErr =>
        let mut postPh ← terminateVerifiedPgrp initProcPh pid initTicks none initBootId
        if postPh == 3 then
          postPh ← terminateVerifiedPgrp 3 pid initTicks none initBootId
        discard <| OrbNode.Posix.pollPid pid
        teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout
          (scratchFinOf cur.nodeBootEpoch curClaimSeq spec.scratchDir?)
        let recErr := s!"post_spawn_ledger_update_failed: {updErr}"
        if let .ok (lErr, _) ← rt.ledger.updateJob jid (fun r => .ok {
          r with
          state := .failed
          startedAt? := some nowTs
          finishedAt? := some nowTs
          logPath? := some spec.logPath
          forced := spec.forced
          pid := pid
          startTicks := initTicks
          procPhase := postPh
          error? := some recErr
        }) then
          rt := { rt with ledger := lErr }
        return releaseDebt rt

structure PendingAsyncLaunch where
  cfg       : NodeConfig
  jid       : String
  missionId : String
  payload   : JVal
  logPath   : String
  forced    : Bool
  sideLane  : Bool
  coordLane : Bool

/-- Reap exited/timed-out/steered process groups (`-pgid` + detached `SIGKILL` systemd scope teardown)
    and reserve lane slots for eligible queued jobs, returning `(updatedRuntime, jobsToLaunchOutsideLock)`. -/
def tickRuntimeReserve
    (rt0 : NodeRuntime) (payloadHints : Std.HashMap String JVal := {}) :
    IO (NodeRuntime × Array PendingAsyncLaunch) := do
  let mut rt := rt0
  if !rt.ledger.pendingSqliteSync.isEmpty then
    let lFlushed ← rt.ledger.flushPendingSqlite
    rt := { rt with ledger := lFlushed }
  let nowEp ← OrbNode.Posix.nowEpoch
  for (jid, lp) in rt.liveProcs.toList do
    let recJob? := rt.ledger.jobs.get? jid
    let recBootEp := (recJob?.map (·.nodeBootEpoch)).getD rt.ledger.nodeBootEpoch
    let recClaimSeq := operationIdToken ((recJob?.map (fun r => if r.operationId.isEmpty then jid else r.operationId)).getD jid)
    let scratchFin : Option (String × SqliteBackend × String × String × UInt64 × UInt64) :=
      lp.scratchDir?.map (fun sd => (rt.cfg.workDir, rt.ledger.sqliteBackend, jid, sd, recBootEp, recClaimSeq))
    let mkLeaderDeadSql (nowTs : String) : String :=
      match lp.machineName? with
      | some mName =>
        if lp.startTicks != 0 && lp.pid ≤ 0xFFFFFFFF then
          containerLeaderUpsertSql {
            workspaceId := lp.workspaceId
            machineName := mName
            leaderPid := lp.pid.toUInt32
            startTicks := lp.startTicks
            nodeBootEpoch := rt.ledger.nodeBootEpoch
            procPhase := 2
            jobId := jid
            updatedAt := nowTs
          }
        else ""
      | none => ""
    let w ← OrbNode.Posix.pollPid lp.pid
    let done := (w &&& 1) == 1
    if done then
      let codeU32 := (w >>> 32).toUInt32
      let codeInt : Int := if codeU32 == 0xFFFFFFFF then -1 else Int.ofNat codeU32.toNat
      if lp.startTicks != 0 then
        discard <| terminateVerifiedPgrp lp.procPhase lp.pid lp.startTicks none lp.bootId
      let arts ← collectArtifactsConfined lp.cwd lp.artifacts
      teardownJobResourcesAsync lp.systemdScope? lp.isolatedCheckout scratchFin
      let nowTs ← nowRfc3339
      let nextState : JobState := if codeInt == 0 then .succeeded else .failed
      if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
        r with
        state := if r.state == .cancelled then .cancelled else nextState
        exitCode? := some codeInt
        finishedAt? := some nowTs
        artifacts := arts
        procPhase := 2
      }) (mkLeaderDeadSql nowTs) then
        rt := { rt with ledger := l' }
      rt := { rt with liveProcs := rt.liveProcs.erase jid }
      if !lp.forced && !lp.sideLane && !lp.coordLane && rt.shrinkDebt > 0 then
        rt := { rt with shrinkDebt := rt.shrinkDebt - 1 }
    else if let some limitSecs := lp.timeoutSecs? then
      if nowEp > lp.startedEp + limitSecs then
        if lp.startTicks != 0 then
          discard <| terminateVerifiedPgrp lp.procPhase lp.pid lp.startTicks none lp.bootId
        discard <| OrbNode.Posix.pollPid lp.pid
        teardownJobResourcesAsync lp.systemdScope? lp.isolatedCheckout scratchFin
        let nowTs ← nowRfc3339
        if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
          r with
          state := .failed
          exitCode? := some 124
          finishedAt? := some nowTs
          error? := some s!"job timed out after {limitSecs}s"
          procPhase := 2
        }) (mkLeaderDeadSql nowTs) then
          rt := { rt with ledger := l' }
        rt := { rt with liveProcs := rt.liveProcs.erase jid }
        if !lp.forced && !lp.sideLane && !lp.coordLane && rt.shrinkDebt > 0 then
          rt := { rt with shrinkDebt := rt.shrinkDebt - 1 }
      else if lp.steerAfterTool then
        let inflight ← collectInflightChildToolPids lp.pid (lp.systemdScope?.map (·.unit))
        if inflight.isEmpty then
          if lp.startTicks != 0 then
            discard <| terminateVerifiedPgrp lp.procPhase lp.pid lp.startTicks none lp.bootId
          discard <| OrbNode.Posix.pollPid lp.pid
          teardownJobResourcesAsync lp.systemdScope? lp.isolatedCheckout scratchFin
          let nowTs ← nowRfc3339
          let cInfo : JobCancellation := {
            actor := "core", reason := "Steered immediately after tool call completed", requestedAt := nowTs
          }
          if let .ok (l', _) ← rt.ledger.updateJob jid (fun r =>
            if r.state.isTerminal then .ok r
            else .ok { r with state := .cancelled, finishedAt? := some nowTs, cancellation? := some cInfo, procPhase := 2 })
            (mkLeaderDeadSql nowTs) then
            rt := { rt with ledger := l' }
          rt := { rt with liveProcs := rt.liveProcs.erase jid }
          if !lp.forced && !lp.sideLane && !lp.coordLane && rt.shrinkDebt > 0 then
            rt := { rt with shrinkDebt := rt.shrinkDebt - 1 }
    else if lp.steerAfterTool then
      let inflight ← collectInflightChildToolPids lp.pid (lp.systemdScope?.map (·.unit))
      if inflight.isEmpty then
        if lp.startTicks != 0 then
          discard <| terminateVerifiedPgrp lp.procPhase lp.pid lp.startTicks none lp.bootId
        discard <| OrbNode.Posix.pollPid lp.pid
        teardownJobResourcesAsync lp.systemdScope? lp.isolatedCheckout scratchFin
        let nowTs ← nowRfc3339
        let cInfo : JobCancellation := {
          actor := "core", reason := "Steered immediately after tool call completed", requestedAt := nowTs
        }
        if let .ok (l', _) ← rt.ledger.updateJob jid (fun r =>
          if r.state.isTerminal then .ok r
          else .ok { r with state := .cancelled, finishedAt? := some nowTs, cancellation? := some cInfo, procPhase := 2 })
          (mkLeaderDeadSql nowTs) then
          rt := { rt with ledger := l' }
        rt := { rt with liveProcs := rt.liveProcs.erase jid }
        if !lp.forced && !lp.sideLane && !lp.coordLane && rt.shrinkDebt > 0 then
          rt := { rt with shrinkDebt := rt.shrinkDebt - 1 }
  let mut remQueue : Array String := #[]
  let mut toLaunch : Array PendingAsyncLaunch := #[]
  for jid in rt.queueOrder do
    if let some rec := rt.ledger.jobs.get? jid then
      if rec.state == .queued && rec.nodeBootEpoch != rt.ledger.nodeBootEpoch then
        let nowStale ← nowRfc3339
        if let .ok (l', _) ← rt.ledger.updateJob jid (fun r => .ok {
          r with
          state := .lost
          phaseCode := 2
          finishedAt? := some (r.finishedAt?.getD nowStale)
          error? := some (r.error?.getD "refused adopting job from prior node_boot_epoch")
        }) then
          rt := { rt with ledger := l', queuedPayloads := rt.queuedPayloads.erase jid }
      else if rec.state == .queued && !rt.launching.contains jid then
        let payload? := (rt.queuedPayloads.get? jid).orElse (fun _ =>
          (payloadHints.get? jid).orElse (fun _ =>
            match OrbBin.Json.parse rec.payloadJson with
            | .ok pv => some pv
            | .error _ => none))
        if let some payload := payload? then
          match decideQueuedAdmission rt payload with
          | some (sideLane, coordLane, trackBg) =>
            let logPath := rec.logPath?.getD ((System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jid}.log").toString)
            let sl : LaunchingSlot := {
              forced := false, sideLane, coordLane, missionId := rec.missionId, trackBg
            }
            rt := {
              rt with
              launching := rt.launching.insert jid sl
              queuedPayloads := rt.queuedPayloads.erase jid
            }
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

def cancelJob
    (rt : NodeRuntime) (jid actor reason : String)
    (lostScopeVerified? : Option Bool := none) : IO (Except String (NodeRuntime × JobRecord × Bool)) := do
  let some cur := rt.ledger.jobs.get? jid
    | return .error "not_found"
  if cur.state.isTerminal then
    return .ok (rt, cur, false)
  let nowTs ← nowRfc3339
  let cleanReason := (reason.take 256).toString
  let cleanActor :=
    if actor == "core" || actor == "operator" || actor == "startup_watchdog" || actor == "provider_error" then actor
    else "unknown"
  let cInfo : JobCancellation := { actor := cleanActor, reason := cleanReason, requestedAt := nowTs }
  if cur.state == .lost then
    let scopeStopped ← match lostScopeVerified? with
      | some ok => pure ok
      | none => stopLostJobScopeOutsideLock rt.cfg.nodeId rt.cfg.workDir jid
    if !scopeStopped then
      match ← rt.ledger.updateJob jid (fun r =>
        if r.state != .lost then .ok r
        else .ok { r with cancellation? := some cInfo }) with
      | .error e => return .error e
      | .ok (l', updated) => return .ok ({ rt with ledger := l' }, updated, false)
    if cur.nodeBootEpoch == rt.ledger.nodeBootEpoch && cur.pid > 1 && cur.startTicks != 0 then
      let lostBoot ← readKernelBootId
      discard <| terminateVerifiedPgrp cur.procPhase cur.pid cur.startTicks none lostBoot
    let lostOpStr := if cur.operationId.isEmpty then jid else cur.operationId
    let lostScratch := (System.FilePath.mk rt.cfg.workDir / ".scratch" / s!"job-{jid}").toString
    teardownJobResourcesAsync none none
      (some (rt.cfg.workDir, rt.ledger.sqliteBackend, jid, lostScratch, cur.nodeBootEpoch, operationIdToken lostOpStr))
  let curCancelOp := if cur.operationId.isEmpty then jid else cur.operationId
  let curCancelSeq := operationIdToken curCancelOp
  let mut releasedRegular := false
  let mut cancelLeaderSql := ""
  if let some lp := rt.liveProcs.get? jid then
    if lp.startTicks != 0 then
      discard <| terminateVerifiedPgrp lp.procPhase lp.pid lp.startTicks none lp.bootId
    discard <| OrbNode.Posix.pollPid lp.pid
    let scratchFin : Option (String × SqliteBackend × String × String × UInt64 × UInt64) :=
      lp.scratchDir?.map (fun sd => (rt.cfg.workDir, rt.ledger.sqliteBackend, jid, sd, cur.nodeBootEpoch, curCancelSeq))
    teardownJobResourcesAsync lp.systemdScope? lp.isolatedCheckout scratchFin
    if let some mName := lp.machineName? then
      if lp.startTicks != 0 && lp.pid ≤ 0xFFFFFFFF then
        cancelLeaderSql := containerLeaderUpsertSql {
          workspaceId := lp.workspaceId
          machineName := mName
          leaderPid := lp.pid.toUInt32
          startTicks := lp.startTicks
          nodeBootEpoch := rt.ledger.nodeBootEpoch
          procPhase := 2
          jobId := jid
          updatedAt := nowTs
        }
    if !lp.forced && !lp.sideLane && !lp.coordLane then
      releasedRegular := true
  else if cur.state == .queued then
    let qScratch := (System.FilePath.mk rt.cfg.workDir / ".scratch" / s!"job-{jid}").toString
    teardownJobResourcesAsync none none
      (some (rt.cfg.workDir, rt.ledger.sqliteBackend, jid, qScratch, cur.nodeBootEpoch, curCancelSeq))
  if let some sl := rt.launching.get? jid then
    if !sl.forced && !sl.sideLane && !sl.coordLane then
      releasedRegular := true
  let nextProcs := rt.liveProcs.erase jid
  let nextLaunching := rt.launching.erase jid
  let nextPayloads := rt.queuedPayloads.erase jid
  let nextQueue := rt.queueOrder.filter (· != jid)
  let nextDebt := if releasedRegular && rt.shrinkDebt > 0 then rt.shrinkDebt - 1 else rt.shrinkDebt
  match ← rt.ledger.updateJob jid (fun r =>
    if r.state.isTerminal then .ok r
    else .ok {
      r with
      state := .cancelled
      finishedAt? := some nowTs
      cancellation? := some cInfo
      procPhase := if r.pid != 0 then 2 else r.procPhase
    }) cancelLeaderSql with
  | .error e => return .error e
  | .ok (l', updated) =>
    return .ok ({
      rt with
      ledger := l'
      queuedPayloads := nextPayloads
      launching := nextLaunching
      liveProcs := nextProcs
      queueOrder := nextQueue
      shrinkDebt := nextDebt
    }, updated, true)

/-- Reserve the force slot for a queued job (`POST /jobs/:id/force`), returning a `PendingAsyncLaunch`
    with the retained full in-memory payload so concurrent callers materialize checkouts outside `Std.Mutex NodeRuntime`. -/
def reserveForceJob (rt : NodeRuntime) (jid : String) :
    Except String (NodeRuntime × PendingAsyncLaunch × JobRecord) := do
  let some cur := rt.ledger.jobs.get? jid
    | throw "not_found"
  if cur.state != .queued || cur.nodeBootEpoch != rt.ledger.nodeBootEpoch || rt.launching.contains jid then
    throw "not_queued"
  if activeForcedCount rt >= 1 then
    throw "force_slot_busy"
  let payload ← match rt.queuedPayloads.get? jid with
    | some pv => pure pv
    | none =>
      match OrbBin.Json.parse cur.payloadJson with
      | .ok pv => pure pv
      | .error _ => throw "corrupt_payload"
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
    queuedPayloads := rt.queuedPayloads.erase jid
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
    | .ok (rt', updated, _) =>
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
  let scopeUnit? := lp.systemdScope?.map (·.unit)
  if mode == "steer_between_tools" then
    let inflight ← collectInflightChildToolPids lp.pid scopeUnit?
    if inflight.isEmpty then
      match ← cancelJob rt jid "core" "Steered between tool calls" with
      | .error e => return .error e
      | .ok (rt', updated, _) =>
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
    let sigCount ← sigintInflightChildTools lp.pid scopeUnit? lp.startTicks lp.bootId
    if sigCount > 0 then
      IO.sleep 60
    match ← cancelJob rt jid "core" "Interrupted in-flight tool via SIGINT for immediate controller steering" with
    | .error e => return .error e
    | .ok (rt', updated, _) =>
      return .ok (rt', .obj #[
        ("job_id", .str jid),
        ("state", .str updated.state.asString),
        ("accepted", .bool true),
        ("signalled_pids", JVal.nat sigCount),
        ("deferred_until_tool_finishes", .bool false)
      ], none)

/-- Maximum retained bytes per stream (`stdout`, `stderr`) for synchronous `POST /execute`
    (`(16 * 1024 * 1024 - 1024) / 6 = 2796032`, matching `src/node/runner.rs::read_capped`). -/
def syncExecOutputCapBytes : Nat := 2796032

private def drainHandleCapped (h : IO.FS.Handle) (capBytes : Nat) : IO String := do
  let mut kept := ByteArray.emptyWithCapacity (min capBytes 65536)
  let mut truncated := false
  while true do
    let chunk ← match ← (h.read 8192).toBaseIO with
      | .ok b => pure b
      | .error _ => pure ByteArray.empty
    if chunk.isEmpty then break
    let rem := capBytes - kept.size
    if rem > 0 then
      let takeLen := min chunk.size rem
      kept := kept ++ chunk.extract 0 takeLen
      if takeLen < chunk.size then
        truncated := true
    else
      truncated := true
  let clean := trimIncompleteUtf8Suffix kept
  let mut text := decodeUtf8LossyPreservingValid clean
  if truncated then
    text := text ++ "\n[node output truncated to fit 16 MiB JSON limit]\n"
  return text

/-- Spawn a child process in its own session (`setsid` when non-scoped) and drain `stdout`/`stderr`
    concurrently with bounded retention (`capBytes = 2796032`), tearing down `activeScope?` and
    escalating verified termination of the child process group (`-pid`) IMMEDIATELY after `child.wait`
    returns ONLY when `/proc/<pid>/stat` + `boot_id` matches `(childPid, childTicks)` and
    `Orb.ManagedNode.verifyProcLivenessAdmit == 1` (never signalling when `/proc` is missing or `procMissing == 1`). -/
def runBoundedOutput
    (sa : IO.Process.SpawnArgs)
    (activeScope? : Option SystemdScope := none)
    (killChildPgrp : Bool := false)
    (capBytes : Nat := syncExecOutputCapBytes)
    (postWaitSampleOverride? : Option ProcLivenessSample := none) : IO IO.Process.Output := do
  let child ← IO.Process.spawn {
    sa with
    stdin := .null
    stdout := .piped
    stderr := .piped
  }
  let childPid := child.pid.toUInt64
  let initSample ← sampleProcLiveness childPid
  let childTicks := initSample.actualTicks
  let childBootId := initSample.bootId
  let outTask ← IO.asTask (drainHandleCapped child.stdout capBytes) Task.Priority.dedicated
  let errTask ← IO.asTask (drainHandleCapped child.stderr capBytes) Task.Priority.dedicated
  let exitCode ← child.wait
  stopSystemdScope activeScope?
  if killChildPgrp && childPid > 1 && childTicks != 0 && !childBootId.isEmpty then
    let afterSample ← match postWaitSampleOverride? with
      | some s => pure s
      | none => sampleProcLiveness childPid
    if afterSample.procMissing == 0 && afterSample.isZombie == 0 && afterSample.bootId == childBootId &&
       Orb.ManagedNode.verifyProcLivenessAdmit 1 2 afterSample.procMissing afterSample.isZombie
         childPid.toUInt32 afterSample.actualPid childTicks afterSample.actualTicks == 1 then
      discard <| terminateVerifiedPgrp 1 childPid childTicks none childBootId
  let stdout := (← IO.wait outTask).toOption.getD ""
  let stderr := (← IO.wait errTask).toOption.getD ""
  return { exitCode, stdout, stderr }

/-- Run cleared-env synchronous `POST /execute` command under `<cfg.workDir>/<missionId>`,
    fenced via `jobs.db` and contained in a transient `systemd-run --scope` unit (or `setsid` process group
    fallback) so all spawned descendants are terminated as soon as the top-level command exits. -/
def execClearedLeaseCommand
    (cfg : NodeConfig) (sqliteBackend : SqliteBackend) (missionId command : String)
    (nodeBootEpoch : UInt64 := 1)
    (postWaitSampleOverride? : Option ProcLivenessSample := none) :
    IO (Except String JVal) := do
  let execId ← newUuidV4
  let scratchDir ← match ← acquireExecFenceReceipt cfg.workDir sqliteBackend execId missionId nodeBootEpoch with
    | .ok sd => pure sd
    | .error fenceErr => return .error fenceErr
  let mut activeScope? : Option SystemdScope := none
  try
    let missionDir := (System.FilePath.mk cfg.workDir / missionId).toString
    IO.FS.createDirAll missionDir
    let mut envPairs ← prepareSharedMissionEnv cfg.workDir missionDir
    envPairs := mergeEnvPair envPairs "SANDBOXED_MISSION_ID" missionId
    let hasTimeout ← do
      let r ← (IO.Process.output { cmd := "timeout", args := #["--version"] }).toBaseIO
      pure (match r with | .ok o => o.exitCode == 0 | .error _ => false)
    let hasSetsid ← do
      let r ← (IO.Process.output { cmd := "setsid", args := #["--version"] }).toBaseIO
      pure (match r with | .ok o => o.exitCode == 0 | .error _ => false)
    let baseProg := if hasTimeout then "timeout" else "bash"
    let baseArgs :=
      if hasTimeout then #["-k", "5", s!"{max 1 cfg.maxJobSecs}s", "bash", "-lc", command]
      else #["-lc", command]
    let (wrappedProg, wrappedArgs, wrappedEnv, scope?) ←
      wrapWithSystemdScope cfg true execId (some cfg.maxJobSecs) baseProg baseArgs envPairs
    activeScope? := scope?
    let out ←
      if scope?.isSome then
        let r ← runBoundedOutput {
          cmd := wrappedProg
          args := wrappedArgs
          cwd := some missionDir
          env := wrappedEnv.map (fun (k, v) => (k, some v))
        } activeScope? false
        activeScope? := none
        pure r
      else
        let mut envArgs : Array String := #["-i"]
        for (k, v) in envPairs do
          envArgs := envArgs.push s!"{k}={v}"
        envArgs := envArgs ++ #[baseProg] ++ baseArgs
        let (spawnCmd, spawnArgs) :=
          if hasSetsid then ("setsid", #["env"] ++ envArgs)
          else ("env", envArgs)
        runBoundedOutput {
          cmd := spawnCmd
          args := spawnArgs
          cwd := some missionDir
        } none hasSetsid syncExecOutputCapBytes postWaitSampleOverride?
    return .ok (.obj #[
      ("accepted", .bool true),
      ("exit_code", JVal.int (Int.ofNat out.exitCode.toNat)),
      ("stdout", .str out.stdout),
      ("stderr", .str out.stderr)
    ])
  finally
    stopSystemdScope activeScope?
    releaseExecFenceReceipt cfg.workDir sqliteBackend execId missionId scratchDir nodeBootEpoch

/-- Single-threaded synchronous `POST /execute` helper (used by direct `handleRequest` tests). -/
def runSyncExecute
    (rt : NodeRuntime) (missionId command : String) (sideLane : Bool := false)
    (postWaitSampleOverride? : Option ProcLivenessSample := none) : IO (Nat × JVal) := do
  if sideLane then
    if activeSideCount rt >= rt.cfg.sideCapacity then
      return (429, .str "node side-lane capacity exhausted")
  else if activeRegularCount rt + rt.shrinkDebt >= rt.cfg.capacityTotal then
    return (429, .str "node capacity exhausted")
  match ← execClearedLeaseCommand rt.cfg rt.ledger.sqliteBackend missionId command rt.ledger.nodeBootEpoch
      postWaitSampleOverride? with
  | .ok resp => return (200, resp)
  | .error fenceErr => return (503, .str fenceErr)

end OrbNode.Runner
