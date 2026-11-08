/-
  OrbBin.SelfTest: End-to-End Verification Suite (`orb-bin-test`) for Wave 1 Companion Binaries.
-/
import OrbBin.Spec
import OrbBin.MutantSuite
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbBin.McpCatalog
import OrbBin.McpRegistry
import OrbBin.StdioMcpServer
import OrbBin.FidoAgentProxyMain
import OrbBin.PrivdShared
import OrbBin.PrivdMain
import OrbBin.MeshCli
import OrbBin.PalomaCtlMain
import OrbBin.SandboxedMcpMain
import OrbBin.WorkspaceMcpMain
import OrbBin.DesktopMcpMain
import OrbBin.AutomationMcpMain

namespace OrbBin.SelfTest

open OrbBin.Spec
open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient
open OrbBin.StdioMcpServer
open OrbBin.FidoAgentProxy
open OrbBin.PrivdShared
open OrbBin.Privd
open OrbBin.MeshCli
open OrbBin.PalomaCtl
open OrbBin.SandboxedMcp
open OrbBin.WorkspaceMcp

private def assertEq {α : Type} [BEq α] [Repr α] (label : String) (got expected : α) : IO Unit := do
  if got != expected then
    throw <| IO.userError s!"FAIL [{label}]: got {repr got}, expected {repr expected}"
  IO.println s!"  [OK] {label}"

private def isErr {ε α : Type} : Except ε α → Bool
  | .error _ => true
  | .ok _ => false

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw <| IO.userError s!"FAIL [{label}]: expected true"
  IO.println s!"  [OK] {label}"

private def runR7bMcpAndPrivdTests (tmpDir : System.FilePath) : IO Unit := do
  IO.println "--- R7-B / R7-C: SM-22 Control MCP Outcome, Stdio MCP Lifecycle & orb-privd TOCTOU ---"

  -- 1. SM-22 Control MCP `receipt_settled` vs `action_outcome`
  assertEq "verifyMcpActionOutcome reconciliation_required is settled (259) and never accepted"
    (verifyMcpActionOutcome 4 1 4 0 0) 259
  assertEq "verifyMcpActionOutcome transportDropped forces reconciliation_required (259)"
    (verifyMcpActionOutcome 2 1 2 1 1) 259
  assertEq "verifyMcpActionOutcome accepted:\"unknown\" forces reconciliation_required (259)"
    (verifyMcpActionOutcome 2 3 2 0 1) 259
  assertEq "verifyMcpActionOutcome pre-commit rejected permits fresh retry (16777474)"
    (verifyMcpActionOutcome 3 2 3 0 0) 16777474
  assertEq "verifyMcpActionOutcome accepted completed with result is 65793"
    (verifyMcpActionOutcome 2 0 2 0 1) 65793

  let recReceipt := JVal.obj #[
    ("action_id", .str "11111111-1111-4111-8111-111111111111"),
    ("state", .str "reconciliation_required"),
    ("accepted", .str "unknown")
  ]
  let clsRec := classifyMcpActionReceipt recReceipt false
  assertEq "classifyMcpActionReceipt reconciliation_required settled=true" clsRec.receiptSettled true
  assertEq "classifyMcpActionReceipt reconciliation_required durableSuccess=false" clsRec.durableSuccess false
  assertEq "classifyMcpActionReceipt reconciliation_required mayRetryFreshKey=false" clsRec.mayRetryFreshKey false
  assertEq "classifyMcpActionReceipt reconciliation_required outcome" clsRec.outcome .uncertainReconciliationRequired

  let dropReceipt := JVal.obj #[
    ("error", .obj #[("code", .str "transport_unavailable"), ("accepted", .str "unknown")])
  ]
  let clsDrop := classifyMcpActionReceipt dropReceipt true
  assertEq "classifyMcpActionReceipt dropped mutation outcome" clsDrop.outcome .uncertainReconciliationRequired
  assertEq "classifyMcpActionReceipt dropped mutation mayRetryFreshKey=false" clsDrop.mayRetryFreshKey false

  let okReceipt := JVal.obj #[
    ("action_id", .str "22222222-2222-4222-8222-222222222222"),
    ("state", .str "completed"),
    ("result", .obj #[("mission_id", .str "33333333-3333-4333-8333-333333333333")])
  ]
  let clsOk := classifyMcpActionReceipt okReceipt false
  assertEq "classifyMcpActionReceipt Core completed receipt outcome" clsOk.outcome .accepted
  assertEq "classifyMcpActionReceipt Core completed receipt durableSuccess=true" clsOk.durableSuccess true

  let batchPayload := JVal.obj #[("receipts", .arr #[okReceipt, recReceipt])]
  let normBatch := normalizeWaitActionsResult batchPayload false
  assertEq "normalizeWaitActionsResult batch receipt_settled=true"
    (normBatch.fieldBool? "receipt_settled") (some true)
  assertEq "normalizeWaitActionsResult batch all_succeeded=false when any needs reconciliation"
    (normBatch.fieldBool? "all_succeeded") (some false)
  assertEq "normalizeWaitActionsResult batch reconciliation_required=true"
    (normBatch.fieldBool? "reconciliation_required") (some true)
  assertEq "normalizeWaitActionsResult batch action_outcome"
    (normBatch.fieldStr? "action_outcome") (some "reconciliation_required")

  -- 1b. Boolean / non-string `accepted` tags never count as durable acceptance
  let boolFalseReceipt := JVal.obj #[
    ("accepted", .bool false),
    ("result", .obj #[])
  ]
  let clsBoolFalse := classifyMcpActionReceipt boolFalseReceipt false
  assertEq "parseAcceptedTag bool false is rejected tag 2" (parseAcceptedTag boolFalseReceipt) 2
  assertEq "classifyMcpActionReceipt accepted:false + result is rejected" clsBoolFalse.outcome .rejected
  assertEq "classifyMcpActionReceipt accepted:false durableSuccess=false" clsBoolFalse.durableSuccess false
  let boolTrueReceipt := JVal.obj #[
    ("accepted", .bool true),
    ("result", .obj #[("ok", .bool true)])
  ]
  let clsBoolTrue := classifyMcpActionReceipt boolTrueReceipt false
  assertEq "parseAcceptedTag bool true is accepted tag 1" (parseAcceptedTag boolTrueReceipt) 1
  assertEq "classifyMcpActionReceipt accepted:true + result is accepted" clsBoolTrue.outcome .accepted
  let numAcceptedReceipt := JVal.obj #[("accepted", .nat 1), ("result", .obj #[])]
  assertEq "parseAcceptedTag numeric accepted is non-canonical tag 4" (parseAcceptedTag numAcceptedReceipt) 4
  assertEq "classifyMcpActionReceipt numeric accepted is rejected"
    (classifyMcpActionReceipt numAcceptedReceipt false).outcome .rejected
  let errBoolReceipt := JVal.obj #[("error", .obj #[("accepted", .bool false), ("message", .str "no")])]
  assertEq "parseAcceptedTag error.accepted bool false is tag 2" (parseAcceptedTag errBoolReceipt) 2
  assertEq "classifyMcpActionReceipt error.accepted=false is rejected"
    (classifyMcpActionReceipt errBoolReceipt false).outcome .rejected
  let core400 := JVal.obj #[
    ("ok", .bool false),
    ("error", .obj #[
      ("code", .str "invalid_json"),
      ("message", .str "Malformed JSON body"),
      ("accepted", .str "no"),
      ("retryable", .bool false)
    ])
  ]
  let cls400 := classifyMcpActionReceipt (JVal.obj #[("error", core400.fieldOrNull "error")]) false
  assertEq "Core HTTP 400 JSON stays rejected pre-commit" cls400.outcome .rejected
  assertEq "Core HTTP 400 JSON mayRetryFreshKey=true" cls400.mayRetryFreshKey true
  let preflightErr := JVal.obj #[("error", .obj #[("code", .str "preflight_failed"), ("accepted", .str "no")])]
  let clsPre := classifyMcpActionReceipt preflightErr false
  assertEq "pre-send token failure accepted:no is rejected" clsPre.outcome .rejected
  assertTrue "pre-send token failure is not reconciliation_required"
    (clsPre.outcome != .uncertainReconciliationRequired)
  let midFlight := JVal.obj #[("error", .obj #[("code", .str "transport_unavailable"), ("accepted", .str "unknown")])]
  let clsMid := classifyMcpActionReceipt midFlight true
  assertEq "mid-flight socket drop is reconciliation_required" clsMid.outcome .uncertainReconciliationRequired
  assertEq "mid-flight socket drop may_retry_fresh_key=false" clsMid.mayRetryFreshKey false

  -- 1c. Live `McpClient.handleRpc` end-to-end tests: HTTP 400 vs pre-send failure vs mid-flight socket drop
  let (coreListenFd, corePort) ← match (← LeanSys.Posix.tcpListen "127.0.0.1" 0 16) with
    | .ok pair => pure pair
    | .error e => throw <| IO.userError s!"tcpListen mock core failed: {e}"
  let coreBaseUrl := s!"http://127.0.0.1:{corePort}"
  let validTok := "mcp1.01234567-89ab-4def-8123-456789abcdef.secret"
  let futureExp : Int := Int.ofNat ((← nowEpoch).toNat + 3600)
  let mkLiveClient (tok : String) (tokenFile? : Option System.FilePath) (primeCache : Bool) : IO McpClient := do
    match (← McpClient.create coreBaseUrl tok tokenFile? "executor" none none none none (some (tmpDir / "mcp-secrets").toString) none) with
    | .error e => throw <| IO.userError s!"McpClient.create failed: {e}"
    | .ok c =>
      if primeCache then
        c.sessionLock.atomically (set (some (tok, futureExp)))
      pure c

  -- (a) Core HTTP 400 JSON error on mutating `tools/call` -> accepted:"no", action_outcome=="rejected"
  let srv400Task ← IO.asTask do
    match (← LeanSys.Posix.tcpAcceptPoll coreListenFd 5000) with
    | .error _ => pure false
    | .ok cfd =>
      let _ ← LeanSys.Posix.readStreamChunk cfd 8192
      let body400 := "{\"ok\":false,\"error\":{\"code\":\"invalid_json\",\"message\":\"Bad args\",\"accepted\":\"no\",\"retryable\":false}}"
      let resp400 := s!"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {body400.utf8ByteSize}\r\nConnection: close\r\n\r\n{body400}"
      let _ ← LeanSys.Posix.writeAll cfd resp400.toUTF8
      let _ ← LeanSys.Posix.closeFd cfd
      pure true
  let liveClient ← mkLiveClient validTok none true
  let cancelRef1 ← IO.mkRef false
  let rpc400 ← liveClient.handleRpc (.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", .nat 10),
    ("method", .str "tools/call"),
    ("params", .obj #[
      ("name", .str "start_mission"),
      ("arguments", .obj #[("title", .str "t"), ("prompt", .str "p"), ("idempotency_key", .str "k-400")])
    ])
  ]) cancelRef1
  let _ ← IO.ofExcept srv400Task.get
  let res400 := rpc400.fieldOrNull "result"
  let sc400 := res400.fieldOrNull "structuredContent"
  assertEq "Live mutating HTTP 400 sets isError=true" (res400.fieldBool? "isError") (some true)
  assertEq "Live mutating HTTP 400 error.accepted == no" ((sc400.fieldOrNull "error").fieldStr? "accepted") (some "no")
  assertEq "Live mutating HTTP 400 action_outcome == rejected" (sc400.fieldStr? "action_outcome") (some "rejected")
  assertEq "Live mutating HTTP 400 may_retry_fresh_key == true" (sc400.fieldBool? "may_retry_fresh_key") (some true)

  -- (b) Pre-send token/preflight failure on mutating `tools/call` -> accepted:"no" (NOT reconciliation_required),
  --     and read-only tool failure never synthesizes mutation lockout fields
  let missingClient ← mkLiveClient "" (some (tmpDir / "does-not-exist.tok")) false
  let cancelRef2 ← IO.mkRef false
  let rpcPreMut ← missingClient.handleRpc (.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", .nat 11),
    ("method", .str "tools/call"),
    ("params", .obj #[
      ("name", .str "start_mission"),
      ("arguments", .obj #[("title", .str "t"), ("prompt", .str "p"), ("idempotency_key", .str "k-pre")])
    ])
  ]) cancelRef2
  let scPreMut := (rpcPreMut.fieldOrNull "result").fieldOrNull "structuredContent"
  assertEq "Live mutating pre-send failure error.accepted == no"
    ((scPreMut.fieldOrNull "error").fieldStr? "accepted") (some "no")
  assertEq "Live mutating pre-send failure action_outcome == rejected"
    (scPreMut.fieldStr? "action_outcome") (some "rejected")
  assertTrue "Live mutating pre-send failure is never reconciliation_required"
    ((scPreMut.fieldStr? "action_outcome") != some "reconciliation_required")

  let rpcPreRo ← missingClient.handleRpc (.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", .nat 12),
    ("method", .str "tools/call"),
    ("params", .obj #[
      ("name", .str "get_mission"),
      ("arguments", .obj #[("mission_id", .str "01234567-89ab-4def-8123-456789abcdef")])
    ])
  ]) cancelRef2
  let scPreRo := (rpcPreRo.fieldOrNull "result").fieldOrNull "structuredContent"
  assertTrue "Read-only preflight failure omits mutation action_outcome"
    (scPreRo.fieldStr? "action_outcome").isNone
  assertTrue "Read-only preflight failure omits accepted lockout tag"
    ((scPreRo.fieldOrNull "error").field? "accepted").isNone

  -- (c) Mid-flight socket drop after request write on mutating `tools/call` -> reconciliation_required
  let srvDropTask ← IO.asTask do
    match (← LeanSys.Posix.tcpAcceptPoll coreListenFd 5000) with
    | .error _ => pure false
    | .ok cfd =>
      let _ ← LeanSys.Posix.readStreamChunk cfd 8192
      let _ ← LeanSys.Posix.closeFd cfd
      pure true
  let rpcDrop ← liveClient.handleRpc (.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", .nat 13),
    ("method", .str "tools/call"),
    ("params", .obj #[
      ("name", .str "start_mission"),
      ("arguments", .obj #[("title", .str "t"), ("prompt", .str "p"), ("idempotency_key", .str "k-drop")])
    ])
  ]) cancelRef1
  let _ ← IO.ofExcept srvDropTask.get
  let scDrop := (rpcDrop.fieldOrNull "result").fieldOrNull "structuredContent"
  assertEq "Live mutating mid-flight socket drop action_outcome == reconciliation_required"
    (scDrop.fieldStr? "action_outcome") (some "reconciliation_required")
  assertEq "Live mutating mid-flight socket drop error.accepted == unknown"
    ((scDrop.fieldOrNull "error").fieldStr? "accepted") (some "unknown")
  assertEq "Live mutating mid-flight socket drop may_retry_fresh_key == false"
    (scDrop.fieldBool? "may_retry_fresh_key") (some false)

  let _ ← LeanSys.Posix.closeFd coreListenFd

  -- 2. Generation-fenced external stdio MCP lifecycle + `/proc/<pid>/stat` start-ticks reaping
  assertEq "verifyMcpStdioLifecycleStep stale generation event ignored without reap"
    (verifyMcpStdioLifecycleStep 2 5 4 0 1) (65536 + 2)
  assertEq "verifyMcpStdioLifecycleStep current child exit transitions Connected->Disconnected + mustReap"
    (verifyMcpStdioLifecycleStep 2 5 5 1 1) 256
  assertEq "verifyMcpStdioLifecycleStep Connecting handshake failure transitions Connecting->Errored + mustReap"
    (verifyMcpStdioLifecycleStep 1 5 5 0 0) (256 + 3)
  let parsedStat := OrbBin.McpRegistry.parseProcStatContent
    "4242 (mcp server (v2)) S 1 4242 4242 0 -1 4194304 10 0 0 0 1 2 0 0 20 0 1 0 987654321 1234 56\n"
  assertEq "parseProcStatContent handles spaces & parens in comm (actualStartTicks)"
    parsedStat.actualStartTicks 987654321
  assertEq "parseProcStatContent handles spaces & parens in comm (procReadError=0)"
    parsedStat.procReadError 0
  let obsLive2000 : OrbBin.McpRegistry.ProcStatObservation :=
    { procMissing := 0, procReadError := 0, isZombieOrDeadState := 0, fieldsAfterComm := 22, actualStartTicks := 2000 }
  let obsLive1000 : OrbBin.McpRegistry.ProcStatObservation :=
    { procMissing := 0, procReadError := 0, isZombieOrDeadState := 0, fieldsAfterComm := 22, actualStartTicks := 1000 }
  assertEq "classifyChildLiveness refuses PID-reused foreign startTicks"
    (OrbBin.McpRegistry.classifyChildLiveness 4242 1000 obsLive2000) 0
  assertEq "classifyChildLiveness confirms matching live startTicks"
    (OrbBin.McpRegistry.classifyChildLiveness 4242 1000 obsLive1000) 1

  let mcpGoodScript := tmpDir / "mock-mcp-good.sh"
  IO.FS.writeFile mcpGoodScript
    "#!/bin/sh\nread init_line\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}'\nread list_line\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"demo_tool\"}]}}'\nsleep 5\n"
  let mcpBadScript := tmpDir / "mock-mcp-bad.sh"
  IO.FS.writeFile mcpBadScript
    "#!/bin/sh\nread init_line\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}'\nread list_line\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32000,\"message\":\"boom\"}}'\n"

  let reg ← OrbBin.McpRegistry.McpStdioRegistry.new
  let st1 ← OrbBin.McpRegistry.connect reg "ext" "/bin/sh" #[mcpGoodScript.toString]
  assertEq "McpStdioRegistry connect 1 reaches connected" st1 OrbBin.McpRegistry.McpConnState.connected
  let (gen1, pid1?, ticks1) ← match (← OrbBin.McpRegistry.getEntry? reg "ext") with
    | some ent =>
      assertEq "McpStdioRegistry gen1 == 1" ent.generation 1
      assertEq "McpStdioRegistry entry connected" ent.state OrbBin.McpRegistry.McpConnState.connected
      pure (ent.generation, ent.child?.map (·.pid), (ent.child?.map (·.startTicks)).getD 0)
    | none => throw <| IO.userError "missing ext entry"
  -- Reconnect increments generation and reaps gen1's process group
  let st2 ← OrbBin.McpRegistry.connect reg "ext" "/bin/sh" #[mcpGoodScript.toString]
  assertEq "McpStdioRegistry connect 2 reaches connected" st2 OrbBin.McpRegistry.McpConnState.connected
  let gen2 ← match (← OrbBin.McpRegistry.getEntry? reg "ext") with
    | some ent =>
      assertEq "McpStdioRegistry gen2 == 2" ent.generation 2
      pure ent.generation
    | none => throw <| IO.userError "missing ext entry after reconnect"
  -- Late child-exit callback from stale gen1 must be fenced (ignored)
  OrbBin.McpRegistry.noteChildExit reg "ext" gen1
  match (← OrbBin.McpRegistry.getEntry? reg "ext") with
  | some ent => assertEq "Stale generation exit leaves gen2 connected" ent.state OrbBin.McpRegistry.McpConnState.connected
  | none => throw <| IO.userError "missing ext entry after stale exit"
  if let some p1 := pid1? then
    let obs1 ← OrbBin.McpRegistry.observeProcStat p1
    let live1 := OrbBin.McpRegistry.classifyChildLiveness p1 ticks1 obs1
    assertEq "Replaced gen1 child was reaped" live1 0
  -- Current-generation exit transitions Connected -> Disconnected & reaps child
  OrbBin.McpRegistry.noteChildExit reg "ext" gen2
  match (← OrbBin.McpRegistry.getEntry? reg "ext") with
  | some ent =>
    assertEq "Current generation exit transitions to disconnected" ent.state OrbBin.McpRegistry.McpConnState.disconnected
    assertTrue "Current generation exit clears child reference" ent.child?.isNone
  | none => throw <| IO.userError "missing ext entry after active exit"

  let stBad ← OrbBin.McpRegistry.connect reg "bad" "/bin/sh" #[mcpBadScript.toString]
  assertEq "Handshake tools/list error moves entry to errored" stBad OrbBin.McpRegistry.McpConnState.errored
  match (← OrbBin.McpRegistry.getEntry? reg "bad") with
  | some ent =>
    assertEq "Failed handshake leaves entry in errored state" ent.state OrbBin.McpRegistry.McpConnState.errored
    assertTrue "Failed handshake reaps child reference" ent.child?.isNone
  | none => throw <| IO.userError "missing bad entry"

  -- (e) Wedged stdio MCP child (partial bytes without `\n`, sleeps) times out promptly and is reaped (`killSig pid 0 != 0`)
  let wedgePidFile := tmpDir / "wedge-mcp.pid"
  let mcpWedgeScript := tmpDir / "mock-mcp-wedge.sh"
  IO.FS.writeFile mcpWedgeScript (
    "#!/bin/sh\necho $$ > '" ++ wedgePidFile.toString ++ "'\n" ++
    "read init_line\nprintf '%s' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":'\nsleep 30\n"
  )
  let tWedge0 ← IO.monoMsNow
  let stWedge ← OrbBin.McpRegistry.connect reg "wedged" "/bin/sh" #[mcpWedgeScript.toString] 180
  let tWedge1 ← IO.monoMsNow
  assertTrue "Wedged stdio MCP connect times out promptly (< 2500ms)" (tWedge1 - tWedge0 < 2500)
  assertTrue "Wedged stdio MCP connect is non-connected" (stWedge != OrbBin.McpRegistry.McpConnState.connected)
  match (← OrbBin.McpRegistry.getEntry? reg "wedged") with
  | some ent =>
    assertTrue "Wedged stdio MCP entry clears child reference" ent.child?.isNone
  | none => throw <| IO.userError "missing wedged entry"
  let wedgePidStr := (← IO.FS.readFile wedgePidFile).trimAscii.toString
  let some wedgePidNat := wedgePidStr.toNat?
    | throw <| IO.userError s!"invalid wedge pid: {wedgePidStr}"
  let wedgeAliveRc ← killSig (Int64.ofNat wedgePidNat) 0
  assertTrue "Wedged stdio MCP child process was deterministically reaped" (wedgeAliveRc != 0)

  -- (f) Concurrent `McpRegistry.connect` calls on same server name serialize cleanly without orphan processes
  let concLogFile := tmpDir / "conc-mcp.pids"
  IO.FS.writeFile concLogFile ""
  let mcpConcScript := tmpDir / "mock-mcp-conc.sh"
  IO.FS.writeFile mcpConcScript (
    "#!/bin/sh\necho $$ >> '" ++ concLogFile.toString ++ "'\n" ++
    "read init_line\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}'\n" ++
    "read list_line\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo_val\",\"description\":\"echo\"}]}}'\n" ++
    "while read req_line; do\n  printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"echoed\":\"ok-from-stdio\"}}'\ndone\n"
  )
  let concT1 ← IO.asTask (OrbBin.McpRegistry.connect reg "conc" "/bin/sh" #[mcpConcScript.toString] 2000)
  let concT2 ← IO.asTask (OrbBin.McpRegistry.connect reg "conc" "/bin/sh" #[mcpConcScript.toString] 2000)
  let concR1 ← IO.ofExcept concT1.get
  let concR2 ← IO.ofExcept concT2.get
  assertEq "Concurrent connect 1 reaches connected" concR1 OrbBin.McpRegistry.McpConnState.connected
  assertEq "Concurrent connect 2 reaches connected" concR2 OrbBin.McpRegistry.McpConnState.connected
  let activeConcPid ← match (← OrbBin.McpRegistry.getEntry? reg "conc") with
    | some ent =>
      assertEq "Concurrent connect reaches generation 2" ent.generation 2
      assertEq "Concurrent connect final state connected" ent.state OrbBin.McpRegistry.McpConnState.connected
      match ent.child? with
      | some ch => pure ch.rawPid
      | none => throw <| IO.userError "missing active child after concurrent connect"
    | none => throw <| IO.userError "missing conc entry"
  let spawnedLines := ((← IO.FS.readFile concLogFile).splitOn "\n").filterMap (fun l => l.trimAscii.toString.toNat?)
  assertEq "Concurrent connects spawned 2 sequential generations" spawnedLines.length 2
  for spPid in spawnedLines do
    let p64 := Int64.ofNat spPid
    if p64 != activeConcPid then
      let rc ← killSig p64 0
      assertTrue "Superseded concurrent child process was reaped" (rc != 0)
  OrbBin.McpRegistry.shutdownAll reg
  let postShutRc ← killSig activeConcPid 0
  assertTrue "shutdownAll reaped active concurrent child" (postShutRc != 0)

  -- Live `McpClient.handleRpc` stdio MCP integration (`tools/list` + namespaced `tools/call` + `shutdown`)
  let missionUuid := "11111111-2222-4333-8444-555555555555"
  let cacheFile := tmpDir / "mcp-preflight-cache.json"
  let capsPayload := JVal.obj #[
    ("contract_version", .str contractVersion),
    ("identity", .obj #[("mission_id", .str missionUuid), ("role", .str "executor"), ("session_id", .str missionUuid)]),
    ("tools", .arr #[.obj #[("name", .str "get_mission"), ("description", .str "core tool")]])
  ]
  let wrCache ← writePreflightCache cacheFile missionUuid "executor" validTok futureExp capsPayload
  assertTrue "writePreflightCache succeeds" wrCache.isOk
  let extClient ← match (← McpClient.create "http://127.0.0.1:1" validTok none "executor" (some missionUuid) none none none (some (tmpDir / "ext-sec").toString) (some cacheFile)) with
    | .ok c => pure c
    | .error e => throw <| IO.userError s!"extClient create: {e}"
  let stExtLive ← OrbBin.McpRegistry.connect extClient.stdioRegistry "helper" "/bin/sh" #[mcpConcScript.toString] 2000
  assertEq "extClient.stdioRegistry connect connected" stExtLive OrbBin.McpRegistry.McpConnState.connected
  let extPid ← match (← OrbBin.McpRegistry.getEntry? extClient.stdioRegistry "helper") with
    | some ent =>
      match ent.child? with
      | some ch => pure ch.rawPid
      | none => throw <| IO.userError "missing helper child"
    | none => throw <| IO.userError "missing helper entry"
  let cancelExt ← IO.mkRef false
  let listRpc ← extClient.handleRpc (.obj #[("jsonrpc", .str "2.0"), ("id", .nat 20), ("method", .str "tools/list")]) cancelExt
  let listedTools := ((listRpc.fieldOrNull "result").fieldArr? "tools").getD #[]
  assertTrue "McpClient tools/list includes namespaced helper.echo_val"
    (listedTools.any (fun t => t.fieldStr? "name" == some "helper.echo_val"))
  let callExtRpc ← extClient.handleRpc (.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", .nat 21),
    ("method", .str "tools/call"),
    ("params", .obj #[("name", .str "helper.echo_val"), ("arguments", .obj #[("x", .nat 1)])])
  ]) cancelExt
  let callExtRes := callExtRpc.fieldOrNull "result"
  assertEq "Namespaced stdio tools/call isError=false" (callExtRes.fieldBool? "isError") (some false)
  assertEq "Namespaced stdio tools/call returns structuredContent"
    ((callExtRes.fieldOrNull "structuredContent").fieldStr? "echoed") (some "ok-from-stdio")
  extClient.shutdown
  let extAfterShut ← killSig extPid 0
  assertTrue "extClient.shutdown reaps stdio child" (extAfterShut != 0)

  -- 3. `orb-privd` TOCTOU (`verifyPrivdToctouStep`) & reply enforcement tests
  let tSelf := targetIdWord (normalizeTargetLabel "self" "node-alpha")
  let tHost := targetIdWord (normalizeTargetLabel "node-alpha" "node-alpha")
  let tOther := targetIdWord (normalizeTargetLabel "node-beta" "node-alpha")
  assertEq "normalizeTargetLabel maps self to hostLabel" tSelf tHost
  let d1 := commandDigestU64 #["/bin/ls", "-la"] "/root"
  let d2 := commandDigestU64 #["/bin/rm", "-rf", "/tmp/x"] "/root"
  let l1 := leaseEpochWord "orb-jit-tok-1" "grant-1"
  assertEq "verifyPrivdToctouStep admits matching lease/target/digest"
    (verifyPrivdToctouStep 3 0 tSelf tHost l1 l1 100 200 d1 d1 1 1) 257
  assertEq "verifyPrivdToctouStep blocks bunker mode (513)"
    (verifyPrivdToctouStep 3 1 tSelf tHost l1 l1 100 200 d1 d1 1 1) 513
  assertEq "verifyPrivdToctouStep blocks expired lease (515)"
    (verifyPrivdToctouStep 3 0 tSelf tHost l1 l1 200 200 d1 d1 1 1) 515
  assertEq "verifyPrivdToctouStep blocks swapped lease epoch (516)"
    (verifyPrivdToctouStep 3 0 tSelf tHost l1 (l1 + 1) 100 200 d1 d1 1 1) 516
  assertEq "verifyPrivdToctouStep blocks target drift (517)"
    (verifyPrivdToctouStep 3 0 tSelf tOther l1 l1 100 200 d1 d1 1 1) 517
  assertEq "verifyPrivdToctouStep blocks command digest swap (518)"
    (verifyPrivdToctouStep 3 0 tSelf tHost l1 l1 100 200 d1 d2 1 1) 518
  assertEq "verifyPrivdToctouStep blocks missing grant or allow_exec=false (519)"
    (verifyPrivdToctouStep 3 0 tSelf tHost l1 l1 100 200 d1 d1 0 1) 519

  -- End-to-end `handleUpdateHarness` & `handleExec` rejection when non-root / Core unreachable
  let auditPath := (tmpDir / "privd-audit.jsonl").toString
  let privCfg : PrivdConfig := {
    socketPath := (tmpDir / "privd.sock").toString
    groupName := "sandboxed-node"
    apiUrl := "http://127.0.0.1:1"
    apiToken := some "test-token"
    auditLog := auditPath
    hostLabel := "node-alpha"
  }
  let nonRootPeer : PeerCred := { uid := some 1000, gid := some 1000, pid := some 4242 }
  let repPath1 := tmpDir / "privd-reply-1.json"
  IO.FS.writeFile repPath1 ""
  let repFd1 ← match (← LeanSys.Posix.openFd repPath1.toString 4 0 0) with
    | .ok fd => pure fd
    | .error e => throw <| IO.userError s!"open repPath1: {e}"
  handleUpdateHarness repFd1 privCfg nonRootPeer (.obj #[("name", .str "codex"), ("version", .str "1.2.3")])
  let _ ← LeanSys.Posix.closeFd repFd1
  match Json.parse (← IO.FS.readFile repPath1) with
  | .ok rj =>
    assertEq "Non-root update_harness without lease rejected (ok=false)" (rj.fieldBool? "ok") (some false)
    assertEq "Non-root update_harness without lease returns exit_code 126" (rj.fieldInt? "exit_code") (some 126)
  | .error e => throw <| IO.userError s!"parse privd reply 1: {e}"

  let repPath2 := tmpDir / "privd-reply-2.json"
  IO.FS.writeFile repPath2 ""
  let repFd2 ← match (← LeanSys.Posix.openFd repPath2.toString 4 0 0) with
    | .ok fd => pure fd
    | .error e => throw <| IO.userError s!"open repPath2: {e}"
  handleExec repFd2 privCfg nonRootPeer (.obj #[
    ("mission_id", .str "m-1"),
    ("lease_token", .str "orb-jit-dead"),
    ("target_host", .str "self"),
    ("argv", .arr #[.str "/bin/true"])
  ])
  let _ ← LeanSys.Posix.closeFd repFd2
  match Json.parse (← IO.FS.readFile repPath2) with
  | .ok rj2 =>
    assertEq "Unverified Core lease handleExec rejected (ok=false)" (rj2.fieldBool? "ok") (some false)
    assertEq "Unverified Core lease handleExec returns exit_code 126" (rj2.fieldInt? "exit_code") (some 126)
  | .error e => throw <| IO.userError s!"parse privd exec reply: {e}"

  -- (g) & (h) Live `Privd.handleExec` TOCTOU binary/cwd swap & deadline/bunker rejection tests
  assertEq "verifyExecWindowAndToctou rejects stalled execution past 30s window (515)"
    (verifyExecWindowAndToctou 3 0 tSelf tHost l1 l1 1000 1030 none d1 d1 1 1) 515
  assertEq "verifyExecWindowAndToctou rejects expired Core lease before 30s window (515)"
    (verifyExecWindowAndToctou 3 0 tSelf tHost l1 l1 1000 1010 (some 1005) d1 d1 1 1) 515
  assertEq "verifyExecWindowAndToctou admits execution within window and Core expiry (257)"
    (verifyExecWindowAndToctou 3 0 tSelf tHost l1 l1 1000 1010 (some 1050) d1 d1 1 1) 257

  let privTrustedDir := tmpDir / "privd-trusted-bin"
  let privWorkDirA := tmpDir / "privd-cwd-a"
  let privWorkDirB := tmpDir / "privd-cwd-b"
  let markerSwap := tmpDir / "swap-executed.marker"
  IO.FS.createDirAll privTrustedDir
  IO.FS.createDirAll privWorkDirA
  IO.FS.createDirAll privWorkDirB
  let _ ← chmod privTrustedDir.toString 0o755
  let _ ← chmod privWorkDirA.toString 0o755
  let _ ← chmod privWorkDirB.toString 0o755
  let safeBin := privTrustedDir / "safe-cmd"
  let evilBin := privTrustedDir / "evil-cmd"
  let runLink := privTrustedDir / "run-cmd"
  IO.FS.writeFile safeBin "#!/bin/sh\nprintf 'SAFE_OK'\n"
  IO.FS.writeFile evilBin s!"#!/bin/sh\necho PWN > '{markerSwap}'\n"
  let _ ← chmod safeBin.toString 0o755
  let _ ← chmod evilBin.toString 0o755
  let lnSafe ← IO.Process.output { cmd := "ln", args := #["-sfn", safeBin.toString, runLink.toString] }
  assertEq "ln -sfn safe-cmd -> run-cmd" lnSafe.exitCode 0

  let (privHttpFd, privHttpPort) ← match (← LeanSys.Posix.tcpListen "127.0.0.1" 0 16) with
    | .ok pair => pure pair
    | .error e => throw <| IO.userError s!"tcpListen mock privd core failed: {e}"
  let livePrivCfg : PrivdConfig := {
    socketPath  := (tmpDir / "privd-live.sock").toString
    groupName   := "sandboxed-node"
    apiUrl      := s!"http://127.0.0.1:{privHttpPort}"
    apiToken    := some "privd-core-tok"
    auditLog    := auditPath
    hostLabel   := "node-alpha"
    trustedDirs := #[privTrustedDir.toString]
  }
  let serveOneCoreVerify (respBody : String) : IO (Task (Except IO.Error Bool)) := do
    IO.asTask do
      match (← LeanSys.Posix.tcpAcceptPoll privHttpFd 5000) with
      | .error _ => pure false
      | .ok cfd =>
        let _ ← LeanSys.Posix.readStreamChunk cfd 8192
        let wire := s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {respBody.utf8ByteSize}\r\nConnection: close\r\n\r\n{respBody}"
        let _ ← LeanSys.Posix.writeAll cfd wire.toUTF8
        let _ ← LeanSys.Posix.closeFd cfd
        pure true

  let nowSecPriv ← nowEpoch
  let validGrantJson := renderCompact <| JVal.obj #[
    ("allowed", .bool true),
    ("allow_exec", .bool true),
    ("scope", .str "root_exec"),
    ("grant_id", .str "grant-live-1"),
    ("bunker_state", .nat 0),
    ("expires_at", .uint64 (nowSecPriv + 120))
  ]

  -- (g1) Binary symlink/inode swap between Core HTTP verify and exec is rejected (exit_code=126) without executing evilBin
  let tVerifySwap ← serveOneCoreVerify validGrantJson
  let repSwapPath := tmpDir / "privd-reply-swap.json"
  IO.FS.writeFile repSwapPath ""
  let repSwapFd ← match (← LeanSys.Posix.openFd repSwapPath.toString 4 0 0) with
    | .ok fd => pure fd
    | .error e => throw <| IO.userError s!"open repSwapPath: {e}"
  let swapHook : IO Unit := do
    let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", evilBin.toString, runLink.toString] }
  handleExec repSwapFd livePrivCfg nonRootPeer (.obj #[
    ("mission_id", .str "m-swap"),
    ("lease_token", .str "orb-jit-live-1"),
    ("target_host", .str "self"),
    ("cwd", .str privWorkDirA.toString),
    ("argv", .arr #[.str runLink.toString])
  ]) (some swapHook)
  let _ ← LeanSys.Posix.closeFd repSwapFd
  let _ ← IO.ofExcept tVerifySwap.get
  match Json.parse (← IO.FS.readFile repSwapPath) with
  | .ok rSwap =>
    assertEq "Binary swap between verify and exec rejected (ok=false)" (rSwap.fieldBool? "ok") (some false)
    assertEq "Binary swap between verify and exec exit_code == 126" (rSwap.fieldInt? "exit_code") (some 126)
  | .error e => throw <| IO.userError s!"parse repSwapPath: {e}"
  let markerSt ← statPath markerSwap.toString
  assertTrue "Swapped evil binary was never executed" (!markerSt.exists_)

  -- Restore runLink -> safeBin, then test (g2) cwd swap to symlink between verify and exec
  let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", safeBin.toString, runLink.toString] }
  let tVerifyCwd ← serveOneCoreVerify validGrantJson
  let repCwdPath := tmpDir / "privd-reply-cwd.json"
  IO.FS.writeFile repCwdPath ""
  let repCwdFd ← match (← LeanSys.Posix.openFd repCwdPath.toString 4 0 0) with
    | .ok fd => pure fd
    | .error e => throw <| IO.userError s!"open repCwdPath: {e}"
  let cwdSwapHook : IO Unit := do
    try IO.FS.removeDirAll privWorkDirA catch _ => pure ()
    let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", privWorkDirB.toString, privWorkDirA.toString] }
  handleExec repCwdFd livePrivCfg nonRootPeer (.obj #[
    ("mission_id", .str "m-cwd"),
    ("lease_token", .str "orb-jit-live-2"),
    ("target_host", .str "self"),
    ("cwd", .str privWorkDirA.toString),
    ("argv", .arr #[.str runLink.toString])
  ]) (some cwdSwapHook)
  let _ ← LeanSys.Posix.closeFd repCwdFd
  let _ ← IO.ofExcept tVerifyCwd.get
  match Json.parse (← IO.FS.readFile repCwdPath) with
  | .ok rCwd =>
    assertEq "Cwd symlink swap between verify and exec rejected (ok=false)" (rCwd.fieldBool? "ok") (some false)
    assertEq "Cwd symlink swap between verify and exec exit_code == 126" (rCwd.fieldInt? "exit_code") (some 126)
  | .error e => throw <| IO.userError s!"parse repCwdPath: {e}"

  -- (h) Expired lease / past-deadline response from Core is rejected by handleExec TOCTOU gate (515 -> exit_code 126)
  let expiredGrantJson := renderCompact <| JVal.obj #[
    ("allowed", .bool true),
    ("allow_exec", .bool true),
    ("scope", .str "root_exec"),
    ("grant_id", .str "grant-expired-1"),
    ("bunker_state", .nat 0),
    ("expires_at", .uint64 (nowSecPriv - 1))
  ]
  let tVerifyExp ← serveOneCoreVerify expiredGrantJson
  let repExpPath := tmpDir / "privd-reply-exp.json"
  IO.FS.writeFile repExpPath ""
  let repExpFd ← match (← LeanSys.Posix.openFd repExpPath.toString 4 0 0) with
    | .ok fd => pure fd
    | .error e => throw <| IO.userError s!"open repExpPath: {e}"
  handleExec repExpFd livePrivCfg nonRootPeer (.obj #[
    ("mission_id", .str "m-exp"),
    ("lease_token", .str "orb-jit-exp-1"),
    ("target_host", .str "self"),
    ("cwd", .str privWorkDirB.toString),
    ("argv", .arr #[.str runLink.toString])
  ])
  let _ ← LeanSys.Posix.closeFd repExpFd
  let _ ← IO.ofExcept tVerifyExp.get
  match Json.parse (← IO.FS.readFile repExpPath) with
  | .ok rExp =>
    assertEq "Expired lease rejected at exec gate (ok=false)" (rExp.fieldBool? "ok") (some false)
    assertEq "Expired lease returns exit_code == 126" (rExp.fieldInt? "exit_code") (some 126)
    assertTrue "Expired lease stderr mentions TOCTOU gate 515"
      ((((rExp.fieldStr? "stderr").getD "").splitOn "515").length > 1)
  | .error e => throw <| IO.userError s!"parse repExpPath: {e}"

  -- Unmodified execution within window succeeds end-to-end (sanity positive check)
  let tVerifyOk ← IO.asTask do
    -- Accept pre-exec verify AND post-exec audit log
    for _ in [0:2] do
      if let .ok cfd ← LeanSys.Posix.tcpAcceptPoll privHttpFd 5000 then
        let _ ← LeanSys.Posix.readStreamChunk cfd 8192
        let wire := s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {validGrantJson.utf8ByteSize}\r\nConnection: close\r\n\r\n{validGrantJson}"
        let _ ← LeanSys.Posix.writeAll cfd wire.toUTF8
        let _ ← LeanSys.Posix.closeFd cfd
    pure true
  let repOkPath := tmpDir / "privd-reply-ok.json"
  IO.FS.writeFile repOkPath ""
  let repOkFd ← match (← LeanSys.Posix.openFd repOkPath.toString 4 0 0) with
    | .ok fd => pure fd
    | .error e => throw <| IO.userError s!"open repOkPath: {e}"
  handleExec repOkFd livePrivCfg nonRootPeer (.obj #[
    ("mission_id", .str "m-ok"),
    ("lease_token", .str "orb-jit-ok-1"),
    ("target_host", .str "self"),
    ("cwd", .str privWorkDirB.toString),
    ("argv", .arr #[.str runLink.toString])
  ])
  let _ ← LeanSys.Posix.closeFd repOkFd
  let _ ← IO.ofExcept tVerifyOk.get
  match Json.parse (← IO.FS.readFile repOkPath) with
  | .ok rOk =>
    assertEq "Unmodified verified exec succeeds (ok=true)" (rOk.fieldBool? "ok") (some true)
    assertEq "Unmodified verified exec stdout == SAFE_OK" (rOk.fieldStr? "stdout") (some "SAFE_OK")
  | .error e => throw <| IO.userError s!"parse repOkPath: {e}"

  let _ ← LeanSys.Posix.closeFd privHttpFd

def runAllTests : IO UInt32 := do
  IO.println "=== OrbBin Wave 1 Companion Binaries Self-Test ==="

  -- 1. Spec gates & framing
  assertEq "verifySshSignForward blocks unapproved SK sign"
    (verifySshSignForward 64 13 1 0 1) 0
  assertEq "verifySshSignForward admits approved SK sign"
    (verifySshSignForward 64 13 1 1 1) 1
  assertEq "verifySshSignForward admits non-SK sign without FIDO"
    (verifySshSignForward 64 13 0 0 1) 1
  assertEq "verifyMcpSecretPersistence rejects non-mcp1 token"
    (verifyMcpSecretPersistence 0 1 1 1 1) 0
  assertEq "verifyMcpSecretPersistence admits private 0600 mcp1"
    (verifyMcpSecretPersistence 1 1 1 1 1) 1
  assertEq "verifyStdioJsonRpcFrame rejects >1 MiB line"
    (verifyStdioJsonRpcFrame 1048577 1 0 8) 0
  assertEq "verifyStdioJsonRpcFrame rejects 9th concurrent slot"
    (verifyStdioJsonRpcFrame 128 1 8 8) 0
  assertEq "verifyStdioJsonRpcFrame admits valid frame"
    (verifyStdioJsonRpcFrame 128 1 7 8) 1

  -- 2. Base64, UUID v4, private 0700/0600 atomic files
  let sample := "mcp1.session-test-payload!@#".toUTF8
  let b64Std := base64Encode sample false true
  assertTrue "Base64 std round-trip" (base64Decode? b64Std == some sample)
  let b64Url := base64Encode sample true false
  assertTrue "Base64 URL-safe nopad round-trip" (base64Decode? b64Url == some sample)
  let u1 ← newUuidV4
  assertTrue "UUID v4 canonical parse" (parseUuidCanonical? u1 == some u1)

  let tmpDir := System.FilePath.mk "/tmp" / s!"orb-bin-selftest-{u1}"
  let dirRes ← ensurePrivateDir0700 tmpDir
  assertTrue "ensurePrivateDir0700 succeeds" dirRes.isOk
  let stDir ← statPath tmpDir.toString
  assertTrue "tmpDir mode is 0700" (stDir.exists_ && stDir.isDir && (stDir.mode &&& 0o777) == 0o700)
  let secFile := tmpDir / "credential"
  let wrRes ← persistScopedCredential secFile "mcp1.valid-token"
  assertTrue "persistScopedCredential accepts mcp1.*" wrRes.isOk
  let wrBad ← persistScopedCredential secFile "owner-jwt-token"
  assertTrue "persistScopedCredential rejects non-mcp1.*" (isErr wrBad)
  let stFile ← statPath secFile.toString
  assertTrue "credential mode is 0600" (stFile.exists_ && stFile.isReg && (stFile.mode &&& 0o777) == 0o600)

  -- 3. RFC 8259 JSON parser & escape round-trip
  let complexJson := "{\"a\":123,\"b\":[true,false,null,\"hello\\n\\\"world\\\"\\u0041\"],\"nested\":{\"k\":-42}}"
  match Json.parse complexJson with
  | .error e => throw <| IO.userError s!"JSON parse failed: {e}"
  | .ok parsed =>
    assertEq "JSON field a" (parsed.fieldNat? "a") (some 123)
    let reparsed := Json.parse (renderCompact parsed)
    match reparsed with
    | .ok rp => assertEq "JSON renderCompact round-trip" rp parsed
    | .error e => throw <| IO.userError s!"JSON reparse failed: {e}"

  -- 4. SSH SK sign request parser (`fido-agent-proxy`)
  let ktBytes := "sk-ssh-ed25519@openssh.com".toUTF8
  let mkSshStr := fun (bs : ByteArray) =>
    let n := bs.size.toUInt32
    ByteArray.mk #[((n >>> 24) &&& 0xFF).toUInt8, ((n >>> 16) &&& 0xFF).toUInt8, ((n >>> 8) &&& 0xFF).toUInt8, (n &&& 0xFF).toUInt8] ++ bs
  let keyBlob := mkSshStr ktBytes ++ mkSshStr (ByteArray.mk #[1, 2, 3, 4])
  let signPayload := ByteArray.mk #[13] ++ mkSshStr keyBlob ++ mkSshStr "challenge".toUTF8 ++ ByteArray.mk #[0, 0, 0, 0]
  match parseSignRequestKeyInfo? signPayload with
  | none => throw <| IO.userError "Failed parsing SSH_AGENTC_SIGN_REQUEST"
  | some (kt, fp) =>
    assertEq "Parsed SK key type" kt "sk-ssh-ed25519@openssh.com"
    assertTrue "Parsed SK fingerprint prefix" (fp.startsWith "SHA256:")
    assertTrue "isSkKeyType true" (isSkKeyType kt)

  -- 5. `orb-privd` / `orb-sudo` policy & `Orb.Kernel.privdCommandStep`
  assertTrue "isStrictSemver accepts 1.3.0" (isStrictSemver "1.3.0")
  assertTrue "isStrictSemver rejects 1.3.0-beta;rm" (!isStrictSemver "1.3.0-beta;rm")
  assertEq "hasUnsafeClientEnv blocks LD_PRELOAD"
    (hasUnsafeClientEnv #[("LD_PRELOAD", "/tmp/evil.so")]) 1
  assertEq "hasUnsafeClientEnv allows LANG"
    (hasUnsafeClientEnv #[("LANG", "C.UTF-8")]) 0
  assertEq "checkScopeRestrictions ops_read journalctl == 1793"
    (← checkScopeRestrictions "ops_read" #[] #["journalctl", "-u", "orb-core", "-n", "20", "--no-pager"] (some "/var/log")).toOption
    (some 1793)
  assertEq "checkScopeRestrictions service_deploy systemctl == 1794"
    (← checkScopeRestrictions "service_deploy" #["orb-core"] #["systemctl", "restart", "orb-core.service"] (some "/root")).toOption
    (some 1794)
  assertTrue "checkScopeRestrictions rejects metachar"
    (isErr (← checkScopeRestrictions "ops_read" #[] #["ps; id"] (some "/root")))
  assertTrue "checkScopeRestrictions rejects cwd traversal"
    (isErr (← checkScopeRestrictions "root_exec" #[] #["id"] (some "/var/lib/../../etc")))
  assertTrue "checkScopeRestrictions rejects wrong deploy unit"
    (isErr (← checkScopeRestrictions "service_deploy" #["orb-core"] #["systemctl", "restart", "postgres.service"] (some "/root")))
  assertTrue "checkScopeRestrictions rejects untrusted exe path"
    (isErr (← checkScopeRestrictions "ops_read" #[] #["/attacker-controlled/ps"] (some "/root")))

  -- 6. `palomactl` diagnostic clustering & PR gate recommendation
  let clustered := clusterDiagnostics "Foo.lean:12:4: error: type mismatch\nFoo.lean:99:1: error: type mismatch\nBar.lean:3:2: warning: unused\n"
  match clustered.asArr? with
  | none => throw <| IO.userError "clusterDiagnostics expected JSON array"
  | some clsArr =>
    assertEq "clusterDiagnostics unique_clusters" clsArr.size 2
    assertEq "clusterDiagnostics top count" (clsArr[0]!.fieldNat? "count") (some 2)
  assertEq "prGateRecommendation 8" (prGateRecommendation 8) "ready_for_review_or_merge"

  -- 7. `sandboxed-mcp` catalogue, overlays, ACP injection & Antigravity lock
  for (role, expectedMin) in [("executor", 44), ("coordinator", 74), ("operator", 89)] do
    let some catTxt := OrbBin.McpCatalog.catalogPrettyJsonForRole role
      | throw <| IO.userError s!"Missing catalog for {role}"
    match Json.parse catTxt with
    | .ok (.arr tools) =>
      assertTrue s!"Catalog {role} count ({tools.size} >= {expectedMin})" (tools.size ≥ expectedMin)
      for memTool in ["memory_search_knowledge", "memory_get_knowledge_page", "memory_get_knowledge_tree", "memory_recall"] do
        assertTrue s!"Catalog {role} includes {memTool}"
          (tools.any (fun t => (t.fieldStr? "name") == some memTool))
    | _ => throw <| IO.userError s!"Failed parsing catalog JSON for {role}"

  -- 7b. `sandboxed-mcp` `--preflight-cache` zero-RTT hit & fail-closed rejection
  let cacheMission ← newUuidV4
  let cacheFile := tmpDir / "preflight.json"
  let expFuture : Int := Int.ofNat (← nowEpoch).toNat + 3600
  let mockCaps := JVal.obj #[
    ("contract_version", .str OrbBin.McpCatalog.contractVersion),
    ("identity", .obj #[("mission_id", .str cacheMission), ("role", .str "executor")]),
    ("limits", .obj #[("session_expires_at", .int expFuture)]),
    ("tools", .arr #[.obj #[("name", .str "memory_search_knowledge")]])
  ]
  let wrCache ← writePreflightCache cacheFile cacheMission "executor" "mcp1.cached-token" expFuture mockCaps
  assertTrue "writePreflightCache 0600 succeeds" wrCache.isOk
  let unreachableUrl := "http://127.0.0.1:9"
  let cachedClient ← match (← McpClient.create unreachableUrl "mcp1.cached-token" none "executor" (some cacheMission) none none none none (some cacheFile)) with
    | .ok c => pure c
    | .error e => throw <| IO.userError s!"McpClient.create failed: {e}"
  let cancelRef0 ← IO.mkRef false
  let initResp ← cachedClient.handleRpc (.obj #[("jsonrpc", .str "2.0"), ("id", .nat 1), ("method", .str "initialize")]) cancelRef0
  assertTrue "preflight-cache serves initialize in 0 HTTP RTTs" ((initResp.field? "result").isSome)
  let listResp ← cachedClient.handleRpc (.obj #[("jsonrpc", .str "2.0"), ("id", .nat 2), ("method", .str "tools/list")]) cancelRef0
  assertEq "preflight-cache serves tools/list in 0 HTTP RTTs"
    ((((listResp.fieldOrNull "result").fieldArr? "tools").getD #[]).size) 1
  -- Wrong mission_id must fail closed to live HTTP (and fail against 127.0.0.1:9)
  let otherMission ← newUuidV4
  let mismatchClient ← match (← McpClient.create unreachableUrl "mcp1.cached-token" none "executor" (some otherMission) none none none none (some cacheFile)) with
    | .ok c => pure c
    | .error e => throw <| IO.userError s!"McpClient.create mismatch failed: {e}"
  let mismatchPreflight ← mismatchClient.preflight
  assertTrue "preflight-cache fails closed on mission_id mismatch" (isErr mismatchPreflight)
  -- World-readable 0644 mode must fail closed
  let chmodOut ← IO.Process.output { cmd := "chmod", args := #["0644", cacheFile.toString] }
  assertEq "chmod 0644 preflight.json" chmodOut.exitCode 0
  let insecureClient ← match (← McpClient.create unreachableUrl "mcp1.cached-token" none "executor" (some cacheMission) none none none none (some cacheFile)) with
    | .ok c => pure c
    | .error e => throw <| IO.userError s!"McpClient.create insecure failed: {e}"
  let insecurePreflight ← insecureClient.preflight
  assertTrue "preflight-cache fails closed when mode != 0600" (isErr insecurePreflight)

  let srvDummy := JVal.obj #[("name", .str "sandboxed"), ("command", .str "/bin/sandboxed-mcp"), ("args", .arr #[]), ("env", .arr #[])]
  let acpNew := "{\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/work\",\"mcpServers\":[{\"name\":\"other\"},{\"name\":\"sandboxed\",\"command\":\"stale\"}]}}".toUTF8
  match transformGrokAcpFrame acpNew srvDummy with
  | .error e => throw <| IO.userError s!"ACP frame transform failed: {e}"
  | .ok outBytes =>
    let .ok j := Json.parseBytes outBytes | throw <| IO.userError "ACP output invalid JSON"
    let some srvs := (j.fieldOrNull "params").fieldArr? "mcpServers" | throw <| IO.userError "missing mcpServers"
    assertEq "ACP preserved sibling + injected sandboxed" srvs.size 2
    assertEq "ACP first server is other" (srvs[0]!.fieldStr? "name") (some "other")
    assertEq "ACP second server is sandboxed" (srvs[1]!.fieldStr? "command") (some "/bin/sandboxed-mcp")

  let agyWs := tmpDir / "agy-ws"
  IO.FS.createDirAll (agyWs / ".agents")
  let origCfg := "{\"mcpServers\":{\"user\":{\"command\":\"user-server\"}}}".toUTF8
  IO.FS.writeBinFile (agyWs / ".agents" / "mcp_config.json") origCfg
  let agyInstallCfg := JVal.obj #[("mcpServers", .obj #[("sandboxed", .obj #[("command", .str "scoped-srv")])])]
  match (← installAntigravityOverlay agyWs agyInstallCfg) with
  | .error e => throw <| IO.userError s!"Antigravity overlay install failed: {e}"
  | .ok ov =>
    let secondAttempt ← installAntigravityOverlay agyWs agyInstallCfg
    assertTrue "Antigravity flock blocks concurrent run" (isErr secondAttempt)
    restoreAntigravityOverlay ov
    let restored ← IO.FS.readBinFile (agyWs / ".agents" / "mcp_config.json")
    assertTrue "Antigravity overlay restores exact original bytes" (restored == origCfg)

  -- 8. Companion MCP tool counts + HS256 JWT minting
  assertEq "workspace-mcp tool count" OrbBin.WorkspaceMcp.toolDefinitions.size 8
  assertEq "desktop-mcp tool count" OrbBin.DesktopMcp.toolDefinitions.size 9
  assertEq "automation-manager-mcp tool count" OrbBin.AutomationMcp.toolDefinitions.size 7
  let jwt ← OrbBin.AutomationMcp.mintServiceJwt "unit-test-secret"
  assertEq "HS256 JWT has 3 dot-separated segments" (jwt.splitOn ".").length 3

  -- 9. `palomactl` snapshot-directory models, RFC3339 validation & task-based `dispatch-plan`
  let snapDir := tmpDir / "snaps"
  IO.FS.createDirAll snapDir
  let snapBase := JVal.obj #[
    ("schema_version", .nat 1),
    ("provider_id", .str "openai"),
    ("access_profile", .str "api_key"),
    ("source", .str "curated"),
    ("completeness", .str "complete"),
    ("models", .arr #[
      .obj #[("id", .str "gpt-5"), ("name", .str "GPT-5")],
      .obj #[("id", .str "gpt-4o"), ("name", .str "GPT-4o")]
    ])
  ]
  IO.FS.writeFile (snapDir / "openai-api_key.json") (renderPretty snapBase ++ "\n")
  let loadedSnaps ← loadSnapshotDir snapDir
  assertTrue "loadSnapshotDir validates matching filename" loadedSnaps.isOk
  let snapPartial := JVal.obj #[
    ("schema_version", .nat 1),
    ("provider_id", .str "openai"),
    ("access_profile", .str "api_key"),
    ("source", .str "discovery"),
    ("observed_at", .str "2026-11-06T08:00:00Z"),
    ("completeness", .str "partial"),
    ("models", .arr #[
      .obj #[("id", .str "gpt-5-mini"), ("name", .str "GPT-5 Mini")]
    ])
  ]
  match mergeSnapshotJson snapBase snapPartial with
  | .error e => throw <| IO.userError s!"mergeSnapshotJson failed: {e}"
  | .ok mergedSnap =>
    assertEq "partial snapshot merge preserves existing + adds incoming"
      ((mergedSnap.fieldArr? "models").getD #[]).size 3
  let diffJ := snapshotDiffJson snapBase snapPartial
  assertEq "partial diff marks removals non-authoritative"
    (diffJ.fieldBool? "removals_authoritative") (some false)

  IO.FS.writeFile (snapDir / "mismatch-name.json") (renderPretty snapBase ++ "\n")
  let badSnapLoad ← loadSnapshotDir snapDir
  assertTrue "loadSnapshotDir rejects filename/provider mismatch" (isErr badSnapLoad)

  assertTrue "parseRfc3339Epoch? accepts UTC Z" (parseRfc3339Epoch? "2099-01-01T00:00:00Z").isSome
  assertTrue "parseRfc3339Epoch? accepts fractional UTC Z" (parseRfc3339Epoch? "2099-01-01T00:00:00.125Z").isSome
  assertTrue "parseRfc3339Epoch? accepts +02:00" (parseRfc3339Epoch? "2099-01-01T02:00:00+02:00").isSome
  assertTrue "parseRfc3339Epoch? rejects invalid timestamp" (parseRfc3339Epoch? "not-a-timestamp").isNone
  assertTrue "parseRfc3339Epoch? rejects non-digit fractional suffix" (parseRfc3339Epoch? "2099-01-01T00:00:00.garbageZ").isNone
  assertTrue "parseRfc3339Epoch? rejects empty fractional suffix" (parseRfc3339Epoch? "2099-01-01T00:00:00.Z").isNone
  assertTrue "parseRfc3339Epoch? rejects double dot fractional suffix" (parseRfc3339Epoch? "2099-01-01T00:00:00.1.2Z").isNone

  assertTrue "resolveTrustedBinary? resolves /bin/sh (even when symlinked)"
    (← resolveTrustedBinary? "/bin/sh").isSome
  assertTrue "resolveTrustedBinary? resolves bare sh"
    (← resolveTrustedBinary? "sh").isSome

  let palomaWs := tmpDir / "paloma-ws"
  IO.FS.createDirAll (palomaWs / ".paloma" / "fixtures")
  IO.FS.createDirAll (palomaWs / ".paloma" / "modes")
  IO.FS.createDirAll (palomaWs / ".paloma" / "projects")
  IO.FS.createDirAll (palomaWs / "docs")
  IO.FS.writeFile (palomaWs / ".paloma" / "modes" / "orb.json")
    "{\"project\":\"orb\",\"mode\":\"conservative\",\"until\":\"2099-01-01T00:00:00Z\"}\n"
  IO.FS.writeFile (palomaWs / ".paloma" / "fixtures" / "tasks.json")
    "[{\"id\":\"t-exp\",\"project\":\"orb\",\"status\":\"ready\",\"intent\":\"explore alternative proof\"},{\"id\":\"t-std\",\"project\":\"orb\",\"status\":\"ready\",\"intent\":\"fix bug\"}]\n"
  match (← buildDispatchPlanJson palomaWs "orb") with
  | .error e => throw <| IO.userError s!"buildDispatchPlanJson failed: {e}"
  | .ok plan =>
    let disp := (plan.fieldArr? "dispatch").getD #[]
    assertEq "conservative mode dispatches only 1 safe task" disp.size 1
    assertEq "conservative mode selects standard task over exploration"
      (disp[0]!.fieldStr? "task_id") (some "t-std")
    assertEq "conservative mode sets null reason when safe task is dispatched"
      (plan.field? "reason") (some .null)

  -- Local tracker doc scan + drift detection (`ShortMissionId`, `StaleMissionRef`, `LiveMismatch`, `PrListedOpenButMerged`)
  IO.FS.writeFile (palomaWs / ".paloma" / "fixtures" / "missions.json")
    "[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"status\":\"active\"}]\n"
  IO.FS.writeFile (palomaWs / ".paloma" / "fixtures" / "pr-lfglabs-dev__verity-103.json")
    "{\"state\":\"closed\",\"draft\":false,\"merged\":true,\"checks\":[]}\n"
  IO.FS.writeFile (palomaWs / ".paloma" / "projects" / "verity.md")
    "Repo: lfglabs-dev/verity\nmission abc1234\nmission: 22222222-2222-4222-8222-222222222222\nmission: 11111111-1111-4111-8111-111111111111\nstatus: blocked\nPR #103 open\n"
  IO.FS.writeFile (palomaWs / "docs" / "PALOMA_EXTRA.md")
    "- [x]UX1: wire feature\n"
  let localSt ← buildLocalState palomaWs
  let docArr := (localSt.fieldArr? "project_docs").getD #[]
  let driftArr := (localSt.fieldArr? "drift").getD #[]
  assertEq "scanProjectDocs finds .paloma/projects + docs/PALOMA_*.md" docArr.size 2
  assertTrue "detectLocalDrift finds short_mission_id"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "short_mission_id"))
  assertTrue "detectLocalDrift finds stale_mission_ref"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "stale_mission_ref"))
  assertTrue "detectLocalDrift finds live_mismatch"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "live_mismatch"))
  assertTrue "detectLocalDrift finds pr_listed_open_but_merged"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "pr_listed_open_but_merged"))
  let parsedChecklist := parseTrackerMarkdown "- [x] A1: ship feature\n- [ ] no code item here\n- [ ] Réparer interface Δ1\n"
  assertEq "parseTrackerMarkdown item count" parsedChecklist.size 3
  assertEq "parseTrackerMarkdown normalizes code key" parsedChecklist[0]!.key "a1"
  assertEq "parseTrackerMarkdown derives title key" parsedChecklist[1]!.key "no-code-item-here"
  assertEq "parseTrackerMarkdown preserves & lowercases Unicode alphanumeric title"
    parsedChecklist[2]!.key "réparer-interface-δ1"

  -- TOML validation-matrix syntax (single-quoted literal strings, multiline arrays, trailing commas, inline-table gates, 4/5-quote multiline strings)
  let tomlMatrix :=
    "version = 1\nproject = 'verity-core'\n\n[[gates]]\nid = 'build'\ncommand = [\n  'lake',\n  \"build\",\n] # trailing comma + multiline\nrequired = true\n"
  match parseValidationMatrixText tomlMatrix >>= validateMatrixJson with
  | .error e => throw <| IO.userError s!"parseValidationMatrixText TOML failed: {e}"
  | .ok mat =>
    assertEq "TOML validation matrix project" (mat.fieldStr? "project") (some "verity-core")
    let gs := (mat.fieldArr? "gates").getD #[]
    assertEq "TOML validation matrix gate count" gs.size 1
    let cmdArr := ((gs[0]!.fieldArr? "command").getD #[]).filterMap JVal.asStr?
    assertEq "TOML validation matrix multiline command" cmdArr #["lake", "build"]

  let inlineMatrix :=
    "project = \"orb\"\ngates = [{ id = \"build\", command = [\"sh\", \"-c\", \"\"\"echo \"hello\"\"\"\", '''say ''hi'''''] }]\n"
  match parseValidationMatrixText inlineMatrix >>= validateMatrixJson with
  | .error e => throw <| IO.userError s!"parseValidationMatrixText inline gates failed: {e}"
  | .ok mat2 =>
    let gs2 := (mat2.fieldArr? "gates").getD #[]
    assertEq "TOML inline gates count" gs2.size 1
    let cmdArr2 := ((gs2[0]!.fieldArr? "command").getD #[]).filterMap JVal.asStr?
    assertEq "TOML multiline 4/5-quote endings" cmdArr2 #["sh", "-c", "echo \"hello\"", "say ''hi''"]
  assertTrue "validateMatrixJson rejects invalid mode enum"
    (isErr (parseValidationMatrixText "project = \"orb\"\ngates = [{ id = \"g\", command = [\"true\"], mode = \"cleen\" }]\n" >>= validateMatrixJson))
  assertTrue "validateMatrixJson rejects negative timeout_secs"
    (isErr (parseValidationMatrixText "project = \"orb\"\ngates = [{ id = \"g\", command = [\"true\"], timeout_secs = -1 }]\n" >>= validateMatrixJson))
  assertTrue "validateMatrixJson rejects non-string dependencies"
    (isErr (parseValidationMatrixText "project = \"orb\"\ngates = [{ id = \"g\", command = [\"true\"], dependencies = [123] }]\n" >>= validateMatrixJson))
  assertTrue "validateMatrixJson rejects timeout_secs > u64::MAX"
    (isErr (parseValidationMatrixText "project = \"orb\"\ngates = [{ id = \"g\", command = [\"true\"], timeout_secs = 18446744073709551616 }]\n" >>= validateMatrixJson))
  assertTrue "validateMatrixJson detects cycle through JSON depends_on alias"
    (isErr (parseValidationMatrixText "{\"project\":\"orb\",\"gates\":[{\"id\":\"a\",\"command\":[\"true\"],\"depends_on\":[\"b\"]},{\"id\":\"b\",\"command\":[\"true\"],\"depends_on\":[\"a\"]}]}" >>= validateMatrixJson))
  assertTrue "validateMatrixJson rejects duplicate dependencies + depends_on"
    (isErr (parseValidationMatrixText "{\"project\":\"orb\",\"gates\":[{\"id\":\"a\",\"command\":[\"true\"],\"dependencies\":[],\"depends_on\":[]}]}" >>= validateMatrixJson))
  assertTrue "parseValidationMatrixText rejects duplicate TOML inline table dependencies"
    (isErr (parseValidationMatrixText "project = \"orb\"\ngates = [{ id = \"a\", command = [\"true\"], dependencies = [\"a\"], dependencies = [] }]\n" >>= validateMatrixJson))
  assertTrue "parseValidationMatrixText rejects duplicate TOML inline table depends_on"
    (isErr (parseValidationMatrixText "project = \"orb\"\ngates = [{ id = \"a\", command = [\"true\"], depends_on = [\"a\"], depends_on = [] }]\n" >>= validateMatrixJson))
  assertEq "parseRfc3339Epoch? accepts pre-1970 timestamp"
    (parseRfc3339Epoch? "1969-12-31T23:59:59Z") (some (-1))
  assertTrue "parseRfc3339Epoch? rejects padded whitespace"
    (parseRfc3339Epoch? " 2026-01-01T00:00:00Z ").isNone
  let badModelSnap :=
    "{\"schema_version\":1,\"provider_id\":\"openai\",\"access_profile\":\"api\",\"source\":\"curated\",\"observed_at\":null,\"completeness\":\"complete\",\"models\":[{\"id\":\"gpt-5\"}]}"
  let parsedBadModel ← match Json.parse badModelSnap with
    | .ok j => pure j
    | .error e => throw <| IO.userError e
  assertTrue "mergeSnapshotJson rejects snapshot model missing name"
    (isErr (mergeSnapshotJson parsedBadModel parsedBadModel))
  let win1252Bytes := ByteArray.mk #[0x43, 0x61, 0x66, 0xE9, 0x20, 0x80]
  assertEq "decodeHttpBodyText decodes windows-1252 / iso-8859-1"
    (decodeHttpBodyText "text/html; charset=ISO-8859-1" win1252Bytes) "Café €"
  let brokenUtf8 := ByteArray.mk #[0x68, 0x69, 0xFF, 0x21]
  assertEq "decodeHttpBodyText replaces malformed UTF-8 byte with U+FFFD"
    (decodeHttpBodyText "text/plain; charset=utf-8" brokenUtf8) "hi\uFFFD!"

  -- HTTP redirect URL resolution (RFC 3986 relative, query-only, dot segments, fragment stripping)
  assertEq "resolveRedirectUrl relative root path"
    (resolveRedirectUrl "http://example.com:8080/docs/old" "/docs/new").toOption
    (some "http://example.com:8080/docs/new")
  assertEq "resolveRedirectUrl scheme-relative URL"
    (resolveRedirectUrl "https://example.com/a" "//cdn.example.com/b").toOption
    (some "https://cdn.example.com/b")
  assertEq "resolveRedirectUrl query-only preserves base path"
    (resolveRedirectUrl "https://example.com/docs/page?old=1" "?v=2#frag").toOption
    (some "https://example.com/docs/page?v=2")
  assertEq "resolveRedirectUrl dot-segment normalization"
    (resolveRedirectUrl "https://example.com/a/b/c" "../d/./e#sec").toOption
    (some "https://example.com/a/d/e")
  assertEq "resolveRedirectUrl preserves slash-containing query with empty path"
    (resolveRedirectUrl "https://example.com/start" "http://example.com?next=/a/b#frag").toOption
    (some "http://example.com/?next=/a/b")
  assertEq "resolveRedirectUrl scheme-relative preserves slash-containing query with empty path"
    (resolveRedirectUrl "https://example.com/start" "//cdn.example.com?next=/a/b").toOption
    (some "https://cdn.example.com/?next=/a/b")

  -- `workspace-mcp` directory symlink root traversal
  let realSubDir := tmpDir / "ws-real-dir"
  let linkSubDir := tmpDir / "ws-link-dir"
  IO.FS.createDirAll realSubDir
  IO.FS.writeFile (realSubDir / "hello.txt") "hi\n"
  let lnOut ← IO.Process.output { cmd := "ln", args := #["-sfn", realSubDir.toString, linkSubDir.toString] }
  assertEq "ln -sfn ws-link-dir exitCode" lnOut.exitCode 0
  let listSymRes ← execListDirectory (.obj #[("path", .str "ws-link-dir")]) tmpDir
  assertEq "execListDirectory follows explicitly requested directory symlink"
    listSymRes.toOption (some "hello.txt")

  -- 10. `StdioMcpServer` cancel + reused ID ownership & 8-slot `inFlight` retention
  let inPath := tmpDir / "rpc-in.jsonl"
  let outPath := tmpDir / "rpc-out.jsonl"
  let rpcFrames :=
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"slow\"}\n" ++
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}\n" ++
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fast\"}\n"
  IO.FS.writeFile inPath rpcFrames
  IO.FS.writeFile outPath ""
  let inFd ← match (← LeanSys.Posix.openFd inPath.toString 0 0 0) with
    | .ok fd => pure (Int32.ofBitVec (BitVec.ofNat 32 fd.raw.toNat))
    | .error e => throw <| IO.userError s!"open inPath: {e}"
  let outFd ← match (← LeanSys.Posix.openFd outPath.toString 4 0 0) with
    | .ok fd => pure (Int32.ofBitVec (BitVec.ofNat 32 fd.raw.toNat))
    | .error e => throw <| IO.userError s!"open outPath: {e}"
  serveFd inFd outFd (fun req cancelRef => do
    let m := (req.fieldStr? "method").getD ""
    let idv := req.fieldOrNull "id"
    if m == "slow" then
      IO.sleep 60
      let _ ← cancelRef.get
      return jsonRpcSuccess idv (.str "stale-slow")
    else
      IO.sleep 15
      return jsonRpcSuccess idv (.str "fresh-fast"))
  closeFdRaw inFd
  closeFdRaw outFd
  let outLines := ((← IO.FS.readFile outPath).splitOn "\n").filter (!·.trimAscii.toString.isEmpty)
  assertEq "cancel + reused ID emits exactly 2 responses (-32800 + fresh-fast)" outLines.length 2
  assertTrue "reused ID never emits stale-slow response" (!outLines.any (fun l => (l.splitOn "stale-slow").length > 1))
  assertTrue "reused ID emits fresh-fast response" (outLines.any (fun l => (l.splitOn "fresh-fast").length > 1))

  -- 11. R7-B / R7-C SM-22 + G-ORB-7 MCP & orb-privd lifecycle / TOCTOU tests
  runR7bMcpAndPrivdTests tmpDir

  try IO.FS.removeDirAll tmpDir catch _ => pure ()
  IO.println "=== ALL ORB-BIN WAVE 1 SELF-TESTS PASSED ==="
  return 0

end OrbBin.SelfTest
