/-
  OrbBin.StdioMcpServer: Bounded `<= 1 MiB` Line-Framed JSON-RPC 2.0 Stdio Transport (`0 import Lean`).
  Implements:
  - Constant-memory overlong frame draining (`> 1048576` bytes -> `-32600` `"Request exceeds 1 MiB"`)
    so subsequent valid frames survive.
  - Malformed JSON recovery (`-32700` `"Invalid JSON"`).
  - `notifications/cancelled` tracking (`-32800` `"Request cancelled; accepted actions continue"`).
  - Bounded 8-slot concurrency (`-32001` `"At most eight concurrent requests are allowed"`),
    duplicate active request-id detection (`-32600` `"Duplicate active request id"`),
    and serialized thread-safe frame output.
  - Enforces `OrbBin.Spec.verifyStdioJsonRpcFrame` on every non-empty request frame.
-/
import Std.Sync.Mutex
import OrbBin.Spec
import OrbBin.Json
import OrbBin.PosixExt

namespace OrbBin.StdioMcpServer

open OrbBin.Json
open OrbBin.PosixExt

def maxFrameBytes : Nat := 1048576
def maxConcurrentRequests : UInt32 := 8

def jsonRpcError (idVal : JVal) (code : Int) (message : String) : JVal :=
  .obj #[
    ("jsonrpc", .str "2.0"),
    ("id", idVal),
    ("error", .obj #[
      ("code", JVal.int code),
      ("message", .str message)
    ])
  ]

def jsonRpcSuccess (idVal : JVal) (result : JVal) : JVal :=
  .obj #[
    ("jsonrpc", .str "2.0"),
    ("id", idVal),
    ("result", result)
  ]

inductive FrameRead where
  | eof
  | oversized
  | line (bytes : ByteArray)
  deriving BEq

structure FdLineReader where
  fd  : Int32
  buf : IO.Ref ByteArray

def FdLineReader.new (fd : Int32) : IO FdLineReader := do
  let buf ← IO.mkRef ByteArray.empty
  return { fd, buf }

private def findNewline? (ba : ByteArray) : Option Nat := Id.run do
  for i in [0:ba.size] do
    if ba.get! i == 0x0A then return some i
  return none

/-- Read one `\n`-delimited frame from `r.fd`, draining frames `> 1 MiB` without unbounded allocation. -/
def FdLineReader.readFrame (r : FdLineReader) : IO FrameRead := do
  let mut acc := ByteArray.emptyWithCapacity 256
  let mut over := false
  while true do
    let buffered ← r.buf.get
    if buffered.isEmpty then
      let chunk ← readFdChunk r.fd 16384
      if chunk.isEmpty then
        if over then return .oversized
        else if acc.isEmpty then return .eof
        else return .line acc
      r.buf.set chunk
    else
      match findNewline? buffered with
      | some nlIdx =>
        let rem := buffered.extract (nlIdx + 1) buffered.size
        r.buf.set rem
        if !over then
          if acc.size + nlIdx > maxFrameBytes then
            over := true
            acc := ByteArray.empty
          else
            acc := acc ++ buffered.extract 0 nlIdx
        if over then return .oversized
        else return .line acc
      | none =>
        r.buf.set ByteArray.empty
        if !over then
          if acc.size + buffered.size > maxFrameBytes then
            over := true
            acc := ByteArray.empty
          else
            acc := acc ++ buffered
  return .eof

private def isAllAsciiWhitespace (ba : ByteArray) : Bool := Id.run do
  for i in [0:ba.size] do
    let b := ba.get! i
    if !(b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A) then
      return false
  return true

private def isValidJsonRpcId (v : JVal) : Bool :=
  match v with
  | .str _ => true
  | .num _ => true
  | _ => false

private def idKey (v : JVal) : String :=
  renderCompact v

structure ActiveRequestEntry where
  key       : String
  idVal     : JVal
  cancelled : IO.Ref Bool

private structure ServerState where
  active : Array ActiveRequestEntry := #[]

private def writeJsonLine (outLock : Std.Mutex Unit) (outFd : Int32) (v : JVal) : IO Unit := do
  outLock.atomically do
    let line := (renderCompact v ++ "\n").toUTF8
    let _ ← writeFdAll outFd line

/-- Serve concurrent JSON-RPC 2.0 requests from `inFd` to `outFd` (default stdin `0` -> stdout `1`).
    Each `handler req cancelFlag` receives a cancellation `IO.Ref Bool` so slow or cancelled requests
    release cleanly on `notifications/cancelled`. -/
def serveFd
    (inFd : Int32)
    (outFd : Int32)
    (handler : JVal → IO.Ref Bool → IO JVal) : IO Unit := do
  let reader ← FdLineReader.new inFd
  let stateMutex ← Std.Mutex.new ({ active := #[] } : ServerState)
  let outLock ← Std.Mutex.new ()
  let mut tasks : Array (Task (Except IO.Error Unit)) := #[]
  while true do
    match (← reader.readFrame) with
    | .eof => break
    | .oversized =>
      writeJsonLine outLock outFd (jsonRpcError .null (-32600) "Request exceeds 1 MiB")
    | .line rawLine =>
      if isAllAsciiWhitespace rawLine then
        pure ()
      else
        match Json.parseBytes rawLine with
        | .error _ =>
          writeJsonLine outLock outFd (jsonRpcError .null (-32700) "Invalid JSON")
        | .ok req =>
          let method := (req.fieldStr? "method").getD ""
          match req.field? "id" with
          | none =>
            if method == "notifications/cancelled" then
              if let some params := req.field? "params" then
                if let some reqId := params.field? "requestId" then
                  let targetKey := idKey reqId
                  let cancelledEntry? ← stateMutex.atomically do
                    let st ← get
                    match st.active.find? (fun e => e.key == targetKey) with
                    | none => return none
                    | some entry =>
                      set { st with active := st.active.filter (fun e => e.key != targetKey) }
                      return some entry
                  if let some entry := cancelledEntry? then
                    entry.cancelled.set true
                    writeJsonLine outLock outFd
                      (jsonRpcError entry.idVal (-32800) "Request cancelled; accepted actions continue")
          | some idVal =>
            let jsonrpcOk := (req.fieldStr? "jsonrpc") == some "2.0"
            if !jsonrpcOk || method.isEmpty || !isValidJsonRpcId idVal then
              writeJsonLine outLock outFd (jsonRpcError idVal (-32600) "Invalid JSON-RPC request")
            else
              let key := idKey idVal
              let cancelRef ← IO.mkRef false
              let admitRes ← stateMutex.atomically do
                let st ← get
                if st.active.any (fun e => e.key == key) then
                  return Except.error (-32600, "Duplicate active request id")
                let gateOk := OrbBin.Spec.verifyStdioJsonRpcFrame
                  rawLine.size.toUInt64 1 st.active.size.toUInt32 maxConcurrentRequests
                if gateOk != 1 then
                  return Except.error (-32001, "At most eight concurrent requests are allowed")
                let entry : ActiveRequestEntry := { key, idVal, cancelled := cancelRef }
                set { st with active := st.active.push entry }
                return Except.ok ()
              match admitRes with
              | .error (code, msg) =>
                writeJsonLine outLock outFd (jsonRpcError idVal code msg)
              | .ok () =>
                let t ← IO.asTask do
                  let resp ← handler req cancelRef
                  let stillOwned ← stateMutex.atomically do
                    let st ← get
                    let present := st.active.any (fun e => e.key == key)
                    if present then
                      set { st with active := st.active.filter (fun e => e.key != key) }
                    return present
                  if stillOwned then
                    writeJsonLine outLock outFd resp
                tasks := tasks.push t
  for t in tasks do
    let _ ← IO.wait t

def serveStdio (handler : JVal → IO.Ref Bool → IO JVal) : IO Unit :=
  serveFd 0 1 handler

end OrbBin.StdioMcpServer
