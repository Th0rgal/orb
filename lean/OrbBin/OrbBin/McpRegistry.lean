/-
  OrbBin.McpRegistry: Generation-fenced external stdio MCP child registry (`SM-22`).
  Each connection owns one `(pid, startTicks, generation)` with poll-bounded raw pipe reads
  and per-entry mutex serialization across `connect` (`initialize` + `tools/list`) and `request`.
-/
import Std.Sync.Mutex
import LeanSys.Posix
import Orb.Kernel
import OrbBin.Spec
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.StdioMcpServer

namespace OrbBin.McpRegistry

open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.StdioMcpServer

def maxFrameBytes : Nat := OrbBin.StdioMcpServer.maxFrameBytes
def defaultTimeoutMs : UInt32 := 5000

inductive McpConnState where
  | disconnected
  | connecting
  | connected
  | errored
  deriving Repr, DecidableEq, BEq

def McpConnState.toWire : McpConnState → UInt8
  | .disconnected => 0
  | .connecting => 1
  | .connected => 2
  | .errored => 3

def McpConnState.ofWire : UInt8 → McpConnState
  | 1 => .connecting
  | 2 => .connected
  | 3 => .errored
  | _ => .disconnected

structure ProcStatObservation where
  procMissing         : UInt8
  procReadError       : UInt8
  isZombieOrDeadState : UInt8
  fieldsAfterComm     : UInt32
  actualStartTicks    : UInt64
  deriving Repr, DecidableEq

/-- Parse `/proc/<pid>/stat`. Field 1 after the last `") "` is state; field 20 is `starttime`. -/
def parseProcStatContent (raw : String) : ProcStatObservation :=
  let partsOpen := raw.splitOn "("
  if partsOpen.length < 2 then
    { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  else
    let afterOpen := String.intercalate "(" partsOpen.tail!
    let partsClose := afterOpen.splitOn ") "
    if partsClose.length < 2 then
      { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
    else
      let rest := partsClose.getLast!
      let fields := ((rest.trimAscii.toString.splitOn " ").filter (fun s => !s.isEmpty)).toArray
      if fields.size == 0 then
        { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
      else
        let stTok := fields[0]!
        let isZomb : UInt8 := if stTok == "Z" || stTok == "X" || stTok == "x" then 1 else 0
        let ticks : UInt64 :=
          if h : 19 < fields.size then
            match fields[19].toNat? with
            | some n => n.toUInt64
            | none => 0
          else 0
        { procMissing := 0
          procReadError := 0
          isZombieOrDeadState := isZomb
          fieldsAfterComm := (Nat.min fields.size 0xFFFFFFFF).toUInt32
          actualStartTicks := ticks }

def observeProcStat (pid : UInt32) (procRoot : System.FilePath := System.FilePath.mk "/proc") : IO ProcStatObservation := do
  if pid == 0 then
    return { procMissing := 1, procReadError := 0, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  let statFile := procRoot / s!"{pid}" / "stat"
  let stFlags ← statPath statFile.toString
  if !stFlags.exists_ then
    return { procMissing := 1, procReadError := 0, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  match ← IO.FS.readFile statFile |>.toBaseIO with
  | .error _ =>
    return { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  | .ok raw =>
    return parseProcStatContent raw

def readLiveProcStartTicks? (pid : UInt32) (procRoot : System.FilePath := System.FilePath.mk "/proc") : IO (Option UInt64) := do
  let obs ← observeProcStat pid procRoot
  let v := Orb.Kernel.procLivenessStep
    obs.procMissing obs.procReadError obs.isZombieOrDeadState 0
    obs.fieldsAfterComm 0 obs.actualStartTicks
  if v == 1 then return some obs.actualStartTicks else return none

/-- `0` dead / PID reused (never signal), `1` alive, `2` inconclusive procfs read. -/
def classifyChildLiveness (pid : UInt32) (startTicks : UInt64) (obs : ProcStatObservation) : UInt8 :=
  if pid == 0 then 0
  else
    let hasExpected : UInt8 := if startTicks != 0 then 1 else 0
    Orb.Kernel.procLivenessStep
      obs.procMissing obs.procReadError obs.isZombieOrDeadState hasExpected
      obs.fieldsAfterComm startTicks obs.actualStartTicks

structure StdioChild where
  rawPid     : Int64
  pid        : UInt32
  startTicks : UInt64
  generation : UInt64
  stdinFd    : Int32
  stdoutFd   : Int32
  buf        : IO.Ref ByteArray
  fdsClosed  : IO.Ref Bool
  nextReqId  : IO.Ref Nat

structure McpServerEntry where
  name       : String
  state      : McpConnState := .disconnected
  generation : UInt64 := 0
  child?     : Option StdioChild := none
  tools      : Array JVal := #[]

instance : Inhabited McpServerEntry where
  default := { name := "" }

private structure ServerSlot where
  name : String
  lock : Std.Mutex Unit

structure McpStdioRegistry where
  servers : Std.Mutex (Array McpServerEntry)
  slots   : Std.Mutex (Array ServerSlot)

def McpStdioRegistry.new : IO McpStdioRegistry := do
  let servers ← Std.Mutex.new (#[] : Array McpServerEntry)
  let slots ← Std.Mutex.new (#[] : Array ServerSlot)
  return { servers, slots }

private def findIdx (xs : Array McpServerEntry) (name : String) : Option Nat :=
  xs.findIdx? (fun e => e.name == name)

private def getServerLock (reg : McpStdioRegistry) (name : String) : IO (Std.Mutex Unit) := do
  reg.slots.atomically do
    let xs ← get
    match xs.find? (fun s => s.name == name) with
    | some s => return s.lock
    | none =>
      let lk ← Std.Mutex.new ()
      set (xs.push { name, lock := lk })
      return lk

private def findNewlineIdx? (ba : ByteArray) : Option Nat := Id.run do
  for i in [0:ba.size] do
    if ba.get! i == 0x0A then return some i
  return none

private def stripTrailingCr (ba : ByteArray) : ByteArray :=
  if ba.size > 0 && ba.get! (ba.size - 1) == 0x0D then
    ba.extract 0 (ba.size - 1)
  else
    ba

private def writeFrame (ch : StdioChild) (v : JVal) : IO Bool := do
  if (← ch.fdsClosed.get) || ch.stdinFd < 0 then
    return false
  let rc ← writeFdAll ch.stdinFd ((renderCompact v) ++ "\n").toUTF8
  return rc == 0

private inductive PollFrameResult where
  | line (bytes : ByteArray)
  | closedOrInvalid

/-- Poll-bounded raw pipe line reader enforcing `timeoutMs`, overall monotonic deadline, and `maxFrameBytes = 1 MiB`. -/
private def readFrameTimed (ch : StdioChild) (timeoutMs : UInt32) : IO PollFrameResult := do
  if (← ch.fdsClosed.get) || ch.stdoutFd < 0 then
    return .closedOrInvalid
  let fd : LeanSys.Posix.Fd := { raw := ch.stdoutFd.toUInt32 }
  let startMs ← IO.monoMsNow
  let deadlineMs := startMs + timeoutMs.toNat
  let mut acc := ByteArray.emptyWithCapacity 256
  while true do
    let buffered ← ch.buf.get
    if !buffered.isEmpty then
      match findNewlineIdx? buffered with
      | some nlIdx =>
        let rem := buffered.extract (nlIdx + 1) buffered.size
        ch.buf.set rem
        if acc.size + nlIdx > maxFrameBytes then
          return .closedOrInvalid
        let lineBytes := stripTrailingCr (acc ++ buffered.extract 0 nlIdx)
        return .line lineBytes
      | none =>
        ch.buf.set ByteArray.empty
        if acc.size + buffered.size > maxFrameBytes then
          return .closedOrInvalid
        acc := acc ++ buffered
    else
      let nowMs ← IO.monoMsNow
      if nowMs ≥ deadlineMs then
        return .closedOrInvalid
      let remMs : UInt32 := (Nat.min (deadlineMs - nowMs) 0xFFFFFFFF).toUInt32
      match (← LeanSys.Posix.pollReadable fd (if remMs == 0 then 1 else remMs)) with
      | .error _ => return .closedOrInvalid
      | .ok () =>
        let chunk ← readFdChunk ch.stdoutFd 16384
        if chunk.isEmpty then
          return .closedOrInvalid
        ch.buf.set chunk
  return .closedOrInvalid

private def closeChildFds (ch : StdioChild) : IO Unit := do
  let already ← ch.fdsClosed.swap true
  if !already then
    if ch.stdinFd >= 0 then closeFdRaw ch.stdinFd
    if ch.stdoutFd >= 0 then closeFdRaw ch.stdoutFd

/-- Reap only when `/proc` still names this generation's `(pid, startTicks)` and close pipe descriptors once. -/
def reapChild (ch : StdioChild) : IO Unit := do
  closeChildFds ch
  let obs ← observeProcStat ch.pid
  let live := classifyChildLiveness ch.pid ch.startTicks obs
  if live != 0 && ch.pid > 0 && ch.rawPid > 0 then
    let _ ← killSig (-ch.rawPid) 9
    let _ ← killSig ch.rawPid 9
  if ch.rawPid > 0 then
    let _ ← waitpidBlock ch.rawPid

def applyLifecycleWord (entry : McpServerEntry) (eventGen : UInt64) (toolsListOk childExited : UInt8) : McpServerEntry :=
  let word := OrbBin.Spec.verifyMcpStdioLifecycleStep
    entry.state.toWire entry.generation eventGen toolsListOk childExited
  let next := McpConnState.ofWire (word &&& 255).toUInt8
  let mustReap := ((word >>> 8) &&& 1) == 1
  { entry with
    state := next
    child? := if mustReap then none else entry.child?
    tools := if mustReap || next != .connected then #[] else entry.tools }

private def readMatchingRpcReply
    (ch : StdioChild) (expectedId : JVal) (timeoutMs : UInt32) : IO (Option JVal) := do
  let startMs ← IO.monoMsNow
  let deadlineMs := startMs + timeoutMs.toNat
  while true do
    let nowMs ← IO.monoMsNow
    if nowMs ≥ deadlineMs then
      return none
    let remMs : UInt32 := (Nat.min (deadlineMs - nowMs) 0xFFFFFFFF).toUInt32
    match (← readFrameTimed ch (if remMs == 0 then 1 else remMs)) with
    | .closedOrInvalid => return none
    | .line bytes =>
      match Json.parseBytes bytes with
      | .error _ => return none
      | .ok v =>
        match v.field? "id" with
        | none =>
          -- Ignore asynchronous server notifications (`method` without `id`)
          if (v.fieldStr? "method").isNone then
            return none
        | some gotId =>
          if gotId == expectedId then
            return some v
          else
            return none
  return none

/-- Spawn `command` as generation `entry.generation + 1`, then `initialize` + `tools/list` under per-entry serialization.
    A failed/wedged handshake or stale generation moves the entry via `verifyMcpStdioLifecycleStep` and reaps the child. -/
def connect
    (reg : McpStdioRegistry)
    (name : String)
    (command : String)
    (args : Array String)
    (timeoutMs : UInt32 := defaultTimeoutMs)
    (extraEnv : Array (String × String) := #[]) : IO McpConnState := do
  let srvLock ← getServerLock reg name
  srvLock.atomically do
    let (prev?, gen) ← reg.servers.atomically do
      let xs ← get
      match findIdx xs name with
      | none =>
        set (xs.push { name, state := .connecting, generation := 1, child? := none, tools := #[] })
        return (none, (1 : UInt64))
      | some i =>
        let e := xs[i]!
        let nextGen := e.generation + 1
        let bumped := { e with state := .connecting, generation := nextGen, child? := none, tools := #[] }
        set (xs.set! i bumped)
        return (e.child?, nextGen)
    if let some prev := prev? then
      reapChild prev
    let baseEnv ← currentEnvPairs
    let mut mergedEnv : Array String := Array.mkEmpty (baseEnv.size + extraEnv.size)
    for (k, v) in baseEnv do
      if !(extraEnv.any (fun (ek, _) => ek == k)) then
        mergedEnv := mergedEnv.push s!"{k}={v}"
    for (ek, ev) in extraEnv do
      mergedEnv := mergedEnv.push s!"{ek}={ev}"
    let spawned? ←
      try
        let sp ← spawnPgrp command args mergedEnv (pipeStdin := true) (nullStdio := true) (pipeStdout := true)
        pure (some sp)
      catch _ =>
        pure none
    let some sp := spawned? | do
      let st ← reg.servers.atomically do
        let xs ← get
        match findIdx xs name with
        | none => return McpConnState.disconnected
        | some i =>
          let e := xs[i]!
          if e.generation != gen then return e.state
          let stepped := applyLifecycleWord e gen 0 1
          set (xs.set! i stepped)
          return stepped.state
      return st
    let pid : UInt32 := if sp.pid ≤ 0 then 0 else sp.pid.toUInt64.toUInt32
    let ticks ← match (← readLiveProcStartTicks? pid) with
      | some t => pure t
      | none => pure 0
    let bufRef ← IO.mkRef ByteArray.empty
    let closedRef ← IO.mkRef false
    let reqIdRef ← IO.mkRef 3
    let stdio : StdioChild := {
      rawPid := sp.pid
      pid
      startTicks := ticks
      generation := gen
      stdinFd := sp.stdinFd
      stdoutFd := sp.stdoutFd
      buf := bufRef
      fdsClosed := closedRef
      nextReqId := reqIdRef
    }
    let stillActive ← reg.servers.atomically do
      let xs ← get
      match findIdx xs name with
      | none => return false
      | some i =>
        if xs[i]!.generation == gen && xs[i]!.state == .connecting then
          set (xs.set! i { xs[i]! with child? := some stdio })
          return true
        else
          return false
    if !stillActive then
      reapChild stdio
      let curSt ← reg.servers.atomically do
        let xs ← get
        return ((xs.find? (·.name == name)).map (·.state)).getD .disconnected
      return curSt

    let initReq := JVal.obj #[
      ("jsonrpc", .str "2.0"), ("id", .nat 1), ("method", .str "initialize"),
      ("params", .obj #[
        ("protocolVersion", .str "2024-11-05"),
        ("capabilities", .obj #[]),
        ("clientInfo", .obj #[("name", .str "orb-mcp-registry"), ("version", .str "1")])
      ])
    ]
    let toolsReq := JVal.obj #[
      ("jsonrpc", .str "2.0"), ("id", .nat 2), ("method", .str "tools/list")
    ]
    let startMs ← IO.monoMsNow
    let deadlineMs := startMs + timeoutMs.toNat
    let mut toolsOk : UInt8 := 0
    let mut exited : UInt8 := 0
    let mut discoveredTools : Array JVal := #[]
    let w1 ← writeFrame stdio initReq
    if !w1 then
      exited := 1
    else
      match (← readMatchingRpcReply stdio (.nat 1) timeoutMs) with
      | none =>
        -- Timeout / EOF / oversized frame on handshake: treat as failed handshake (`toolsOk = 0`)
        let wPid ← waitpidWnohang stdio.rawPid
        exited := if wPid != 0xFFFFFFFF then 1 else 0
      | some iv =>
        if (iv.field? "result").isSome && (iv.field? "error").isNone then
          let nowMs ← IO.monoMsNow
          if nowMs ≥ deadlineMs then
            exited := 0
          else
            let remMs : UInt32 := (Nat.min (deadlineMs - nowMs) 0xFFFFFFFF).toUInt32
            let w2 ← writeFrame stdio toolsReq
            if !w2 then
              exited := 1
            else
              match (← readMatchingRpcReply stdio (.nat 2) (if remMs == 0 then 1 else remMs)) with
              | none =>
                let wPid ← waitpidWnohang stdio.rawPid
                exited := if wPid != 0xFFFFFFFF then 1 else 0
              | some tv =>
                if let some res := tv.field? "result" then
                  if (tv.field? "error").isNone then
                    toolsOk := 1
                    discoveredTools := (res.fieldArr? "tools").getD #[]
    let (nextState, shouldReap) ← reg.servers.atomically do
      let xs ← get
      match findIdx xs name with
      | none => return (McpConnState.disconnected, true)
      | some i =>
        let e := xs[i]!
        if e.generation != gen then
          return (e.state, true)
        let word := OrbBin.Spec.verifyMcpStdioLifecycleStep e.state.toWire e.generation gen toolsOk exited
        let mustReap := ((word >>> 8) &&& 1) == 1
        let stepped := applyLifecycleWord e gen toolsOk exited
        let finalState :=
          if !mustReap && stepped.state == .connecting && toolsOk == 1 && exited == 0 then McpConnState.connected
          else stepped.state
        let stored : McpServerEntry := {
          stepped with
          state := finalState
          child? := if mustReap || finalState != .connected then none else some stdio
          tools := if !mustReap && finalState == .connected then discoveredTools else #[]
        }
        set (xs.set! i stored)
        return (stored.state, mustReap || finalState != .connected)
    if shouldReap then
      reapChild stdio
    return nextState

/-- Send a serialized JSON-RPC request to a connected external stdio MCP server with bounded timeout and response-ID verification.
    If the child exits, wedges past `timeoutMs`, emits malformed/oversized data, or mismatches `"id"`, transitions via
    `verifyMcpStdioLifecycleStep` and reaps the child. -/
def request
    (reg : McpStdioRegistry)
    (name : String)
    (method : String)
    (params? : Option JVal := none)
    (timeoutMs : UInt32 := defaultTimeoutMs) : IO (Except String JVal) := do
  let srvLock ← getServerLock reg name
  srvLock.atomically do
    let cur? ← reg.servers.atomically do
      let xs ← get
      return xs.find? (fun e => e.name == name)
    let some entry := cur? | return .error s!"External MCP server `{name}` is not registered"
    let some ch := entry.child? | return .error s!"External MCP server `{name}` is not connected"
    if entry.state != .connected then
      return .error s!"External MCP server `{name}` is in state {repr entry.state}"
    let gen := entry.generation
    let reqNum ← ch.nextReqId.modifyGet (fun n => (n, n + 1))
    let reqId := JVal.nat reqNum
    let mut fields : Array (String × JVal) := #[("jsonrpc", .str "2.0"), ("id", reqId), ("method", .str method)]
    if let some p := params? then
      fields := fields.push ("params", p)
    let okWrite ← writeFrame ch (.obj fields)
    let reply? ←
      if okWrite then readMatchingRpcReply ch reqId timeoutMs
      else pure none
    match reply? with
    | some v =>
      if let some errObj := v.field? "error" then
        if errObj != .null then
          let msg := (errObj.fieldStr? "message").getD "External MCP tool error"
          return .error msg
      return .ok (v.fieldOrNull "result")
    | none =>
      let toReap? ← reg.servers.atomically do
        let xs ← get
        match findIdx xs name with
        | none => return some ch
        | some i =>
          let e := xs[i]!
          if e.generation != gen then
            return none
          let stepped := applyLifecycleWord e gen 0 1
          set (xs.set! i stepped)
          return some ch
      if let some dead := toReap? then
        reapChild dead
      return .error s!"External MCP server `{name}` timed out or closed connection"

/-- Ignore a child-exit event unless `eventGen` is still the active generation. -/
def noteChildExit (reg : McpStdioRegistry) (name : String) (eventGen : UInt64) : IO Unit := do
  let reap? ← reg.servers.atomically do
    let xs ← get
    match findIdx xs name with
    | none => return none
    | some i =>
      let e := xs[i]!
      let word := OrbBin.Spec.verifyMcpStdioLifecycleStep e.state.toWire e.generation eventGen 1 1
      if ((word >>> 16) &&& 1) == 1 then
        return none
      let stepped := applyLifecycleWord e eventGen 1 1
      set (xs.set! i stepped)
      return if ((word >>> 8) &&& 1) == 1 then e.child? else none
  if let some ch := reap? then
    if ch.generation == eventGen then
      reapChild ch

def disconnect (reg : McpStdioRegistry) (name : String) : IO Unit := do
  let srvLock ← getServerLock reg name
  srvLock.atomically do
    let prev? ← reg.servers.atomically do
      let xs ← get
      match findIdx xs name with
      | none => return none
      | some i =>
        let e := xs[i]!
        set (xs.set! i { e with state := .disconnected, generation := e.generation + 1, child? := none, tools := #[] })
        return e.child?
    if let some ch := prev? then
      reapChild ch

def getEntry? (reg : McpStdioRegistry) (name : String) : IO (Option McpServerEntry) := do
  reg.servers.atomically do
    let xs ← get
    return xs.find? (fun e => e.name == name)

def listConnectedTools (reg : McpStdioRegistry) : IO (Array (String × JVal)) := do
  reg.servers.atomically do
    let xs ← get
    let mut out : Array (String × JVal) := #[]
    for e in xs do
      if e.state == .connected then
        for t in e.tools do
          out := out.push (e.name, t)
    return out

def shutdownAll (reg : McpStdioRegistry) : IO Unit := do
  let children ← reg.servers.atomically do
    let xs ← get
    set (xs.map fun e => { e with state := .disconnected, generation := e.generation + 1, child? := none, tools := #[] })
    return xs.filterMap (·.child?)
  for ch in children do
    reapChild ch

end OrbBin.McpRegistry
