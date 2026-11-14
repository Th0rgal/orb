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
import OrbBin.GitWorkspace
import OrbBin.ClaudeControl

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
open OrbBin.GitWorkspace
open OrbBin.ClaudeControl

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
    ("argv", .arr #[.str "true"])
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

  let privTrustedRaw := tmpDir / "privd-trusted-bin"
  IO.FS.createDirAll privTrustedRaw
  let privTrustedDir ← try IO.FS.realPath privTrustedRaw catch _ => pure privTrustedRaw
  let privWorkDirA := tmpDir / "privd-cwd-a"
  let privWorkDirB := tmpDir / "privd-cwd-b"
  let markerSwap := tmpDir / "swap-executed.marker"
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

private def callTestPrivdSocket (sockPath : String) (payload : JVal) : IO JVal := do
  let fd ← match (← LeanSys.Posix.unixConnect sockPath) with
    | .ok f => pure f
    | .error e => throw <| IO.userError s!"unixConnect {sockPath} failed: {e}"
  let wire := ((renderCompact payload) ++ "\n").toUTF8
  let _ ← LeanSys.Posix.writeAll fd wire
  let _ ← shutdownWr (Int32.ofBitVec (BitVec.ofNat 32 fd.raw.toNat))
  let mut respBytes := ByteArray.emptyWithCapacity 4096
  while true do
    match (← readSocketTimed fd 65536 15000) with
    | .eof => break
    | .timeout => break
    | .fatal _ => break
    | .bytes chunk => respBytes := respBytes ++ chunk
  let _ ← LeanSys.Posix.closeFd fd
  match Json.parseBytes respBytes with
  | .ok j => return j
  | .error e => throw <| IO.userError s!"privd parseBytes failed: {e}"

private def runMultiUserPrivdBrokerTests (tmpDir : System.FilePath) : IO Unit := do
  IO.println "--- Multi-User orb-privd Confined User Execution & Symlink Confinement ---"
  assertTrue "checkUserExecAdmission admits valid dedicated uid/gid >= 2000"
    ((checkUserExecAdmission true true false "member" "orb-alice" 2500 2500 true true true &&& 1) == 1)
  assertTrue "checkUserExecAdmission rejects uid < 2000"
    ((checkUserExecAdmission true true false "member" "orb-alice" 1000 2500 true true true &&& 1) == 0)
  assertTrue "checkUserExecAdmission rejects reserved root username"
    ((checkUserExecAdmission true true false "member" "root" 2500 2500 true true true &&& 1) == 0)
  assertTrue "checkUserExecAdmission rejects member on admin-only node"
    ((checkUserExecAdmission true true true "member" "orb-alice" 2500 2500 true true true &&& 1) == 0)
  assertTrue "checkUserExecAdmission rejects privileged group membership"
    ((checkUserExecAdmission true true false "member" "orb-alice" 2500 2500 false true true &&& 1) == 0)
  let scrubbed := scrubUserJobEnv #[
    ("ORB_CORE_API_TOKEN", "secret-core"),
    ("ORB_NODE_TOKEN", "secret-node"),
    ("SANDBOXED_NODE_TOKEN", "secret-snode"),
    ("LD_PRELOAD", "/tmp/evil.so"),
    ("ANTHROPIC_API_KEY", "orb-mpt-v1_ok"),
    ("ANTHROPIC_BASE_URL", "http://127.0.0.1:3000/v1")
  ] "/home/orb-alice"
  assertTrue "scrubUserJobEnv strips node/core tokens and LD_PRELOAD"
    (!scrubbed.any (fun (k, _) => k == "ORB_CORE_API_TOKEN" || k == "ORB_NODE_TOKEN" || k == "SANDBOXED_NODE_TOKEN" || k == "LD_PRELOAD"))
  assertTrue "scrubUserJobEnv preserves mission_proxy_token env and pins HOME"
    (scrubbed.any (fun (k, v) => k == "ANTHROPIC_API_KEY" && v == "orb-mpt-v1_ok") &&
     scrubbed.any (fun (k, v) => k == "HOME" && v == "/home/orb-alice"))
  let privdForkSnippet := "fork_root=$(pwd -P); fork_root=${fork_root%/*}; printf '%s' \"$fork_root\""
  let privdSdCmd := buildPrivdSystemdRunCmd "orb-job-u1" 2500 2500
    "/home/orb-alice/.orb-missions/m1" "/home/orb-alice" "/var/log/orb/j1.log"
    3600 (some 2147483648) (some 1932735283) (some 100) (some "200%")
    scrubbed #["bash", "-lc", privdForkSnippet] true
  let idxPrivdNoExp := (privdSdCmd.findIdx? (· == "--expand-environment=no")).getD 999
  let idxPrivdDash := (privdSdCmd.findIdx? (· == "--")).getD 999
  assertTrue "buildPrivdSystemdRunCmd passes --expand-environment=no before '--' and preserves ${fork_root%/*}"
    (privdSdCmd[0]? == some "/usr/bin/systemd-run" &&
     privdSdCmd[1]? == some "--system" &&
     idxPrivdNoExp < idxPrivdDash &&
     privdSdCmd.back? == some privdForkSnippet)
  let privdLegacyCmd := buildPrivdSystemdRunCmd "orb-job-u1" 2500 2500
    "/home/orb-alice/.orb-missions/m1" "/home/orb-alice" "/var/log/orb/j1.log"
    3600 (some 2147483648) (some 1932735283) (some 100) (some "200%")
    scrubbed #["bash", "-lc", privdForkSnippet] false
  assertTrue "buildPrivdSystemdRunCmd omits --expand-environment=no and doubles $ on pre-254 systemd"
    (!privdLegacyCmd.contains "--expand-environment=no" &&
     privdLegacyCmd.back? == some "fork_root=$$(pwd -P); fork_root=$${fork_root%/*}; printf '%s' \"$$fork_root\"")

  let homeRoot := tmpDir / "privd-homes"
  let stateDir := tmpDir / "privd-state"
  let sharedElan := tmpDir / "shared-elan"
  let logDir := tmpDir / "privd-logs"
  IO.FS.createDirAll (sharedElan / "bin")
  IO.FS.createDirAll (sharedElan / "toolchains" / "leanprover--lean4---v4.35.0")
  IO.FS.writeFile (sharedElan / "bin" / "lean") "#!/bin/sh\necho lean-mock\n"
  IO.FS.writeFile (sharedElan / "settings.toml") "default_toolchain = \"leanprover/lean4:v4.35.0\"\n"
  IO.FS.createDirAll homeRoot
  IO.FS.createDirAll stateDir
  IO.FS.createDirAll logDir

  setenvVar "ORB_PRIVD_ALLOW_NONROOT_TEST" "1"
  setenvVar "ORB_PRIVD_HOME_ROOT" homeRoot.toString
  setenvVar "ORB_PRIVD_STATE_DIR" stateDir.toString
  setenvVar "ORB_PRIVD_SHARED_ELAN" sharedElan.toString
  let cleanupPrivdEnv : IO Unit := do
    unsetenvVar "ORB_PRIVD_ALLOW_NONROOT_TEST"
    unsetenvVar "ORB_PRIVD_HOME_ROOT"
    unsetenvVar "ORB_PRIVD_STATE_DIR"
    unsetenvVar "ORB_PRIVD_SHARED_ELAN"
  let runInner : IO Unit := do
    let pidU ← getpid
    let sockPath := s!"/tmp/opd-{pidU}.sock"
    try IO.FS.removeFile sockPath catch _ => pure ()
    let lfd ← match (← LeanSys.Posix.unixListen sockPath 16) with
      | .ok f => pure f
      | .error e => throw <| IO.userError s!"unixListen {sockPath} failed: {e}"
    let cfg : PrivdConfig := {
      socketPath := sockPath
      groupName := "staff"
      apiUrl := "http://127.0.0.1:9"
      apiToken := some "tok"
      auditLog := (tmpDir / "privd-audit.jsonl").toString
      hostLabel := "self"
    }
    let serveOne : IO Unit := do
      match (← LeanSys.Posix.tcpAcceptPoll lfd 5000) with
      | .ok cfd => handleConnection cfd cfg
      | .error e => throw <| IO.userError s!"tcpAcceptPoll failed: {e}"

    let tBad ← IO.asTask serveOne
    let rBad ← callTestPrivdSocket sockPath (.obj #[
      ("action", .str "ensure_mission_user"),
      ("unix_username", .str "root"),
      ("mission_id", .str "11111111-1111-4111-8111-111111111111")
    ])
    let _ ← IO.ofExcept tBad.get
    assertEq "ensure_mission_user rejects root username" (rBad.fieldBool? "ok") (some false)

    let mid := "11111111-1111-4111-8111-111111111111"
    let tEns ← IO.asTask serveOne
    let rEns ← callTestPrivdSocket sockPath (.obj #[
      ("action", .str "ensure_mission_user"),
      ("unix_username", .str "orb-alice"),
      ("mission_id", .str mid),
      ("workspace_files", .arr #[.obj #[("path", .str "opencode.json"), ("content", .str "{\"ok\":true}\n")]])
    ])
    let _ ← IO.ofExcept tEns.get
    assertEq "ensure_mission_user orb-alice ok" (rEns.fieldBool? "ok") (some true)
    assertTrue "shared elan bin copied into ~/.elan/bin/lean"
      (← (homeRoot / "orb-alice" / ".elan" / "bin" / "lean").pathExists)
    assertTrue "workspace_files written inside mission cwd"
      (← (homeRoot / "orb-alice" / ".orb-missions" / mid / "opencode.json").pathExists)

    let logFile := (logDir / "job-u1.log").toString
    let tSp ← IO.asTask serveOne
    let rSp ← callTestPrivdSocket sockPath (.obj #[
      ("action", .str "spawn_user_job"),
      ("unix_username", .str "orb-alice"),
      ("job_id", .str "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
      ("mission_id", .str mid),
      ("argv", .arr #[.str "bash", .str "-lc", .str "printf 'MPT=%s|NT=%s\\n' \"$ANTHROPIC_API_KEY\" \"$ORB_NODE_TOKEN\" > result.txt; cat result.txt"]),
      ("env", .obj #[
        ("ANTHROPIC_API_KEY", .str "orb-mpt-v1_test123"),
        ("ORB_NODE_TOKEN", .str "MUST_NOT_LEAK")
      ]),
      ("log_path", .str logFile)
    ])
    let _ ← IO.ofExcept tSp.get
    assertEq "spawn_user_job orb-alice ok" (rSp.fieldBool? "ok") (some true)

    let mut jobDone := false
    let mut jobRc : Int := -1
    for _ in [0:40] do
      IO.sleep 50
      let tSt ← IO.asTask serveOne
      let rSt ← callTestPrivdSocket sockPath (.obj #[
        ("action", .str "control_user_job"),
        ("op", .str "status"),
        ("job_id", .str "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        ("unix_username", .str "orb-alice")
      ])
      let _ ← IO.ofExcept tSt.get
      if (rSt.fieldBool? "done") == some true then
        jobDone := true
        jobRc := (rSt.fieldInt? "exit_code").getD (-1)
        break
    assertTrue "control_user_job observed completion rc==0" (jobDone && jobRc == 0)

    let tFsRead ← IO.asTask serveOne
    let rFsRead ← callTestPrivdSocket sockPath (.obj #[
      ("action", .str "user_fs_op"),
      ("unix_username", .str "orb-alice"),
      ("mission_id", .str mid),
      ("subop", .str "file_browser"),
      ("req_json", .obj #[("action", .str "read"), ("path", .str "result.txt")])
    ])
    let _ ← IO.ofExcept tFsRead.get
    let readContent := ((rFsRead.fieldOrNull "result").fieldStr? "content").getD ""
    assertEq "user_fs_op read verifies MPT present and ORB_NODE_TOKEN scrubbed"
      readContent.trimAscii.toString "MPT=orb-mpt-v1_test123|NT="

    let outsideSecret := tmpDir / "outside-secret.txt"
    IO.FS.writeFile outsideSecret "TOP_SECRET"
    let evilLink := homeRoot / "orb-alice" / ".orb-missions" / mid / "evil-link.txt"
    let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", outsideSecret.toString, evilLink.toString] }
    let tFsSym ← IO.asTask serveOne
    let rFsSym ← callTestPrivdSocket sockPath (.obj #[
      ("action", .str "user_fs_op"),
      ("unix_username", .str "orb-alice"),
      ("mission_id", .str mid),
      ("subop", .str "file_browser"),
      ("req_json", .obj #[("action", .str "read"), ("path", .str "evil-link.txt")])
    ])
    let _ ← IO.ofExcept tFsSym.get
    assertEq "user_fs_op rejects symlink escape with O_NOFOLLOW/lstat" (rFsSym.fieldBool? "ok") (some false)

    let _ ← LeanSys.Posix.closeFd lfd
    try IO.FS.removeFile sockPath catch _ => pure ()
  try
    runInner
    cleanupPrivdEnv
  catch e =>
    cleanupPrivdEnv
    throw e

/-- OpenCode over ACP against a scripted mock agent (`python3`). -/
def runOpenCodeAcpTests : IO Unit := do
  let tmpDir : System.FilePath := s!"/tmp/orb-bin-acp-{← IO.monoNanosNow}"
  IO.FS.createDirAll tmpDir
  -- OpenCode over ACP: chunks reach the caller while the agent is still producing them
  -- (regression: `opencode run --format json` printed a reply only once it was finished).
  let mockAcpBin := tmpDir / "mock-opencode-acp.py"
  let acpLog := tmpDir / "mock-acp-methods.log"
  let acpPy :=
    "#!/usr/bin/env python3\n" ++
    "import sys, json, time\n" ++
    s!"log = open('{acpLog}', 'w')\n" ++
    "def out(o):\n    print(json.dumps(o), flush=True)\n" ++
    "def upd(u):\n    out({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'ses_mock','update':u}})\n" ++
    "for line in sys.stdin:\n" ++
    "    m = json.loads(line)\n" ++
    "    meth = m.get('method')\n" ++
    "    if meth is None:\n        log.write('reply ' + json.dumps(m.get('result')) + '\\n'); log.flush(); continue\n" ++
    "    log.write(meth + ' ' + json.dumps(m.get('params', {}).get('configId', m.get('params', {}).get('sessionId', ''))) + '\\n'); log.flush()\n" ++
    "    if meth == 'initialize': out({'jsonrpc':'2.0','id':m['id'],'result':{'protocolVersion':1}})\n" ++
    "    elif meth == 'session/resume': out({'jsonrpc':'2.0','id':m['id'],'error':{'code':-32602,'message':'no such session'}})\n" ++
    "    elif meth == 'session/new': out({'jsonrpc':'2.0','id':m['id'],'result':{'sessionId':'ses_mock'}})\n" ++
    "    elif meth == 'session/set_config_option': out({'jsonrpc':'2.0','id':m['id'],'result':{}})\n" ++
    "    elif meth == 'session/prompt':\n" ++
    "        out({'jsonrpc':'2.0','id':99,'method':'session/request_permission','params':{'options':[{'optionId':'no','kind':'reject_once'},{'optionId':'yes','kind':'allow_once'}]}})\n" ++
    "        upd({'sessionUpdate':'agent_thought_chunk','content':{'type':'text','text':'thinking'}})\n" ++
    "        for piece in ['Hello', ' world', '!']:\n" ++
    "            upd({'sessionUpdate':'agent_message_chunk','messageId':'msg_1','content':{'type':'text','text':piece}})\n" ++
    "            time.sleep(0.3)\n" ++
    "        upd({'sessionUpdate':'tool_call','toolCallId':'t1','name':'shell','kind':'execute','status':'pending','rawInput':{'command':'ls'}})\n" ++
    "        upd({'sessionUpdate':'tool_call_update','toolCallId':'t1','kind':'execute','status':'completed','title':'ls'})\n" ++
    "        upd({'sessionUpdate':'agent_message_chunk','messageId':'msg_2','content':{'type':'text','text':'Done.'}})\n" ++
    "        out({'jsonrpc':'2.0','id':m['id'],'result':{'stopReason':'end_turn'}})\n"
  IO.FS.writeFile mockAcpBin acpPy
  let _ ← chmod mockAcpBin.toString 0o755
  let acpLinesRef ← IO.mkRef (#[] : Array (Nat × String))
  let acpT0 ← IO.monoMsNow
  let acpEnv := (← currentEnvPairs).map fun (k, v) => s!"{k}={v}"
  let acpCode ← runOpenCodeAcpTurn mockAcpBin.toString acpEnv
    { cwd := tmpDir.toString, prompt := "hi", model? := some "builtin/smart", sessionId? := some "ses_gone" }
    (fun ln => do acpLinesRef.modify (·.push ((← IO.monoMsNow) - acpT0, ln)))
  let acpLines ← acpLinesRef.get
  let parsedAcp := acpLines.map (fun (_, ln) => parseOneShotHarnessEvent "opencode" ln)
  let mut acpText := ""
  let mut acpLast : Option String := none
  for pl in parsedAcp do
    if !pl.textDelta.isEmpty then
      let (piece, nextLast) := joinHarnessText "opencode" acpText acpLast pl
      acpText := acpText ++ piece
      acpLast := nextLast
  let chunkTimes := (acpLines.zip parsedAcp).filterMap (fun ((t, _), pl) => if pl.isChunk then some t else none)
  assertEq "OpenCode ACP turn exits cleanly" acpCode 0
  assertEq "OpenCode ACP chunks of one message join, a new message starts a paragraph" acpText "Hello world!\n\nDone."
  assertTrue "OpenCode ACP chunks arrive as produced"
    (chunkTimes.size ≥ 3 && chunkTimes[0]! + 400 ≤ chunkTimes[2]!)
  assertTrue "OpenCode ACP reports the new session after a failed resume"
    (parsedAcp.any (fun pl => pl.sessionId? == some "ses_mock"))
  assertTrue "OpenCode ACP maps thinking and tool updates"
    (parsedAcp.any (fun pl => pl.thinking? == some "thinking") &&
     parsedAcp.any (fun pl => (pl.activity?.map (fun a => a.done && a.label == "shell" && a.kind == "command")) == some true))
  let acpMethods ← IO.FS.readFile acpLog
  assertTrue "OpenCode ACP resumes, falls back to a new session, sets the model, then prompts"
    ((acpMethods.splitOn "session/resume \"ses_gone\"").length > 1 &&
     (acpMethods.splitOn "session/set_config_option \"model\"").length > 1 &&
     (acpMethods.splitOn "session/prompt").length > 1)
  assertTrue "OpenCode ACP permission prompts pick the allow option"
    ((acpMethods.splitOn "\"optionId\": \"yes\"").length > 1)

  assertEq "ACP model keeps an advertised name" (resolveAcpModel "orbrouter/builtin/smart" #["orbrouter/builtin/smart"]) (some "orbrouter/builtin/smart")
  assertEq "ACP model maps another provider prefix" (resolveAcpModel "opencode/builtin/smart" #["x/a", "orbrouter/builtin/smart"]) (some "orbrouter/builtin/smart")
  assertEq "ACP model maps a bare name" (resolveAcpModel "builtin/smart" #["orbrouter/builtin/smart"]) (some "orbrouter/builtin/smart")
  assertEq "ACP model unknown to the agent" (resolveAcpModel "nope/zzz" #["orbrouter/builtin/smart"]) none
  IO.FS.removeDirAll tmpDir

def runAllTests : IO UInt32 := do
  runOpenCodeAcpTests
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
      for memTool in ["memory_search_knowledge", "memory_get_knowledge_page", "memory_get_knowledge_tree", "memory_recall",
                      "request_macbook_tether", "list_macbook_tethers", "revoke_macbook_tether"] do
        assertTrue s!"Catalog {role} includes {memTool}"
          (tools.any (fun t => (t.fieldStr? "name") == some memTool))
      let some spawn := tools.find? (·.fieldStr? "name" == some "spawn_managed_machine")
        | throw <| IO.userError s!"Missing spawn_managed_machine for {role}"
      let schema := spawn.fieldOrNull "inputSchema"
      let props := schema.fieldOrNull "properties"
      let provider := props.fieldOrNull "provider"
      assertEq s!"Catalog {role} managed provider enum"
        (provider.fieldArr? "enum") (some #[.str "boat", .str "leanci", .str "colab"])
      -- The default is the instance's (`SANDBOXED_MANAGED_DEFAULT_PROVIDER`), never a schema constant.
      assertTrue s!"Catalog {role} managed provider has no fixed default" ((provider.field? "default").isNone)
      let spawnDesc := (spawn.fieldStr? "description").getD ""
      for term in ["instance's default provider", "provider_fallback", "supports_extend=false", "covers the whole task"] do
        assertTrue s!"Catalog {role} spawn description includes {term}" ((spawnDesc.splitOn term).length > 1)
      assertTrue s!"Catalog {role} spawn description names no fixed default provider"
        ((spawnDesc.splitOn "boat.dev, default").length == 1)
      let some extendTool := tools.find? (·.fieldStr? "name" == some "extend_managed_machine")
        | throw <| IO.userError s!"Missing extend_managed_machine for {role}"
      assertTrue s!"Catalog {role} extend says some providers cannot be extended"
        ((((extendTool.fieldStr? "description").getD "").splitOn "supports_extend=true").length > 1)
      assertTrue s!"Catalog {role} managed provider optional"
        (!((schema.fieldArr? "required").getD #[]).contains (.str "provider"))
      let size := props.fieldOrNull "size"
      assertEq s!"Catalog {role} catalog profile is string" (size.fieldStr? "type") (some "string")
      for restriction in ["enum", "const", "pattern", "anyOf", "oneOf"] do
        assertTrue s!"Catalog {role} live profiles not restricted by {restriction}"
          ((size.field? restriction).isNone)
      for (resource, needed) in [("cpu", 32), ("ram_gb", 96)] do
        let field := props.fieldOrNull resource
        assertEq s!"Catalog {role} {resource} integer" (field.fieldStr? "type") (some "integer")
        assertEq s!"Catalog {role} {resource} positive" (field.fieldNat? "minimum") (some 1)
        assertTrue s!"Catalog {role} {resource} accepts leanci 2xlarge"
          ((field.fieldNat? "maximum").getD needed ≥ needed)
      let some listMachines := tools.find? (·.fieldStr? "name" == some "list_managed_machines")
        | throw <| IO.userError s!"Missing list_managed_machines for {role}"
      for tool in [spawn, listMachines] do
        let desc := (tool.fieldStr? "description").getD ""
        for term in ["boat", "leanci", "colab", "opt-in", "catalog", "2xlarge", "32 vCPU/96 GiB", "t4", "disk"] do
          assertTrue s!"Catalog {role} managed description includes {term}" ((desc.splitOn term).length > 1)
      let some start := tools.find? (·.fieldStr? "name" == some "start_mission")
        | throw <| IO.userError s!"Missing start_mission for {role}"
      let remote := ((start.fieldOrNull "inputSchema").fieldOrNull "properties").fieldOrNull "remote_node_id"
      assertTrue s!"Catalog {role} provider-qualified managed placement"
        ((((remote.fieldStr? "description").getD "").splitOn "auto-managed:<provider>:<size>").length > 1)
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
  runMultiUserPrivdBrokerTests tmpDir

  -- 12. Warm Claude bidirectional stdio control protocol, hidden git checkpoints & sibling worktrees
  IO.println "--- Warm Claude Control Protocol, Hidden Git Checkpoints & Worktree Isolation ---"
  assertEq "parsePermissionMode supervised -> default CLI wire"
    (parsePermissionMode "supervised").toCliWire "default"
  assertEq "parsePermissionMode acceptEdits -> acceptEdits CLI wire"
    (parsePermissionMode "auto-edit").toCliWire "acceptEdits"
  assertEq "parsePermissionMode auto -> auto CLI wire"
    (parsePermissionMode "auto").toCliWire "auto"
  assertEq "parsePermissionMode full-access -> bypassPermissions CLI wire"
    (parsePermissionMode "full-access").toCliWire "bypassPermissions"

  let sampleCtrlEv := JVal.obj #[
    ("type", .str "control_request"),
    ("request_id", .str "req-perm-1"),
    ("request", .obj #[
      ("subtype", .str "can_use_tool"),
      ("tool_name", .str "Bash"),
      ("input", .obj #[("command", .str "cargo test")]),
      ("permission_suggestions", .arr #[.obj #[("type", .str "addRules"), ("destination", .str "session")]])
    ])
  ]
  let parsedPerm? := parseClaudeControlRequest? sampleCtrlEv
  assertTrue "parseClaudeControlRequest? recognizes Bash can_use_tool" parsedPerm?.isSome
  let parsedPerm := parsedPerm?.get!
  assertEq "parsedPerm.method == permission" parsedPerm.method "permission"
  let (allowSessJson, _) := buildClaudeControlResponse parsedPerm (.obj #[("action", .str "accept_session")])
  assertTrue "accept_session includes updatedPermissions"
    ((allowSessJson.splitOn "updatedPermissions").length > 1)
  let (denyJson, _) := buildClaudeControlResponse parsedPerm (.obj #[("action", .str "revise"), ("feedback", .str "Use pnpm test instead")])
  assertTrue "revise sends behavior:deny with inline feedback"
    ((denyJson.splitOn "\"behavior\":\"deny\"").length > 1 && (denyJson.splitOn "Use pnpm test instead").length > 1)

  let initRespRaw := "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"orb-model-discovery\",\"response\":{\"models\":[{\"value\":\"default\",\"resolvedModel\":\"claude-sonnet-5-5\"},{\"value\":\"opus\",\"resolvedModel\":\"claude-opus-5-5\"},{\"value\":\"sonnet\",\"resolvedModel\":\"claude-sonnet-5-5\"}]}}}"
  let initModels := (OrbBin.Json.parse initRespRaw).toOption.bind (parseClaudeInitializeModels? · "orb-model-discovery")
  assertEq "parseClaudeInitializeModels? extracts class releases"
    initModels (some #[("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5")])

  let initFableMythosRaw := "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"orb-model-discovery\",\"response\":{\"models\":[{\"value\":\"default\",\"resolvedModel\":\"claude-fable-5-1\"},{\"value\":\"fable\",\"resolvedModel\":\"claude-fable-5-2\"},{\"value\":\"claude-fable-5-1\"},{\"value\":\"claude-mythos-5-1\"},{\"value\":\"claude-mythos-5-2\"},{\"value\":\"claude-mythos-5-2[1m]\"},{\"value\":\"sonnet\",\"resolvedModel\":\"claude-sonnet-5-5\"},{\"value\":\"opus\",\"resolvedModel\":\"claude-opus-5-5\"}]}}}"
  let initFableMythos := (OrbBin.Json.parse initFableMythosRaw).toOption.bind (parseClaudeInitializeModels? · "orb-model-discovery")
  assertEq "parseClaudeInitializeModels? keeps Opus first and picks Fable 5.2 + Mythos 5.2"
    initFableMythos (some #[
      ("claude-opus-5-5", "Claude Opus 5.5"),
      ("claude-fable-5-2", "Claude Fable 5.2"),
      ("claude-mythos-5-2", "Claude Mythos 5.2"),
      ("claude-sonnet-5-5", "Claude Sonnet 5.5")
    ])

  -- Live mock warm Claude process test (2 turns + interactive `can_use_tool` over open stdin/stdout pipes!)
  let mockClaudeScript := tmpDir / "mock-warm-claude.py"
  let pyCode :=
    "#!/usr/bin/env python3\n" ++
    "import sys, json\n" ++
    "turn = 0\n" ++
    "for raw in sys.stdin:\n" ++
    "    line = raw.strip()\n" ++
    "    if not line: continue\n" ++
    "    msg = json.loads(line)\n" ++
    "    if msg.get('type') == 'control_request' and msg.get('request', {}).get('subtype') == 'initialize':\n" ++
    "        print(json.dumps({'type':'system','subtype':'init','session_id':'warm-sid-42'}), flush=True)\n" ++
    "        continue\n" ++
    "    if msg.get('type') == 'user':\n" ++
    "        turn += 1\n" ++
    "        if turn == 1:\n" ++
    "            print(json.dumps({'type':'control_request','request_id':'req-1','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'ls'}}}), flush=True)\n" ++
    "        else:\n" ++
    "            print(json.dumps({'type':'stream_event','event':{'type':'content_block_delta','delta':{'type':'text_delta','text':'Warm turn 2!'}}}), flush=True)\n" ++
    "            print(json.dumps({'type':'result','num_turns':1,'is_error':False,'result':'Warm turn 2!','session_id':'warm-sid-42'}), flush=True)\n" ++
    "    elif msg.get('type') == 'control_response':\n" ++
    "        beh = msg.get('response', {}).get('response', {}).get('behavior', '')\n" ++
    "        txt = f'Turn 1 ({beh})'\n" ++
    "        print(json.dumps({'type':'stream_event','event':{'type':'content_block_delta','delta':{'type':'text_delta','text':txt}}}), flush=True)\n" ++
    "        print(json.dumps({'type':'result','num_turns':1,'is_error':False,'result':txt,'session_id':'warm-sid-42'}), flush=True)\n"
  IO.FS.writeFile mockClaudeScript pyCode
  let _ ← chmod mockClaudeScript.toString 0o755

  -- Set up a temporary git repository to test hidden checkpoints, diffing, restore & worktree isolation simultaneously
  let repoDir := tmpDir / "git-checkpoint-repo"
  IO.FS.createDirAll repoDir
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoDir.toString, "init", "-b", "main"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoDir.toString, "config", "user.email", "test@orb.local"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoDir.toString, "config", "user.name", "Orb Test"] }
  IO.FS.writeFile (repoDir / "app.txt") "v1\n"
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoDir.toString, "add", "app.txt"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoDir.toString, "commit", "-m", "initial"] }

  let warmMgr ← newWarmHarnessManager
  let seenCtrlRef ← IO.mkRef (none : Option PendingControlRequest)
  let cbs : HarnessCallbacks := {
    onControlRequest := fun req => seenCtrlRef.set (some req)
  }
  let launch1 ← startHarnessTurn warmMgr "m-warm-1" "claudecode" mockClaudeScript.toString repoDir.toString "Run ls"
    1 none none none .supervised "local" #[] cbs
  assertTrue "Warm Claude turn 1 launches cleanly" launch1.toOption.isSome

  let mut waitedCtrl := 0
  while waitedCtrl < 3000 && (← seenCtrlRef.get).isNone do
    IO.sleep 25
    waitedCtrl := waitedCtrl + 25
  let some pendingCtrl ← seenCtrlRef.get
    | throw <| IO.userError "Expected warm Claude control_request on turn 1"
  assertEq "Warm Claude emits Bash permission request" pendingCtrl.toolName "Bash"
  let answered ← respondToControlRequest warmMgr "m-warm-1" pendingCtrl.requestId (.obj #[("action", .str "accept_session")])
  assertEq "respondToControlRequest succeeds over open stdin" answered true

  let mut waitedTurn1 := 0
  while waitedTurn1 < 3000 do
    if let some st ← getRunState? warmMgr "m-warm-1" then
      if st.done then break
    IO.sleep 25
    waitedTurn1 := waitedTurn1 + 25
  let st1 := (← getRunState? warmMgr "m-warm-1").get!
  assertEq "Warm Claude turn 1 completes with allow response" st1.text "Turn 1 (allow)"
  assertEq "Warm Claude turn 1 binds session_id" st1.sessionId? (some "warm-sid-42")

  -- Mutate working tree between turns, then run Turn 2 on the SAME warm process (zero respawn!)
  IO.FS.writeFile (repoDir / "app.txt") "v2-modified\n"
  IO.FS.writeFile (repoDir / "extra.txt") "untracked-file\n"
  let launch2 ← startHarnessTurn warmMgr "m-warm-1" "claudecode" mockClaudeScript.toString repoDir.toString "Second prompt"
    2 none none st1.sessionId? .acceptEdits "local" #[] cbs
  assertTrue "Warm Claude turn 2 reuses open process" launch2.toOption.isSome
  let mut waitedTurn2 := 0
  while waitedTurn2 < 3000 do
    if let some st ← getRunState? warmMgr "m-warm-1" then
      if st.done then break
    IO.sleep 25
    waitedTurn2 := waitedTurn2 + 25
  let st2 := (← getRunState? warmMgr "m-warm-1").get!
  assertEq "Warm Claude turn 2 output" st2.text "Warm turn 2!"
  stopHarnessRun warmMgr "m-warm-1"

  -- Verify hidden git checkpoints (`refs/orb/checkpoints/...`), diffing, and atomic rollback!
  let cpsRes ← listCheckpoints repoDir.toString "m-warm-1"
  let cps := cpsRes.toOption.getD #[]
  assertTrue "Hidden git checkpoints captured automatically across turns (Turn 0, 1, 2)" (cps.size == 3)
  assertEq "Checkpoint 0 turn_index == 0" cps[0]!.turnIndex 0
  assertEq "Checkpoint 1 turn_index == 1" cps[1]!.turnIndex 1
  assertEq "Checkpoint 2 turn_index == 2" cps[2]!.turnIndex 2
  let crossRefRej ← restoreCheckpoint repoDir.toString "other-mission" cps[0]!.ref
  assertTrue "restoreCheckpoint rejects cross-mission checkpoint ref" crossRefRej.isOk.not
  let badBranchRej ← createMissionWorktree repoDir.toString "m-wt-bad" (some "--upload-pack=evil")
  assertTrue "createMissionWorktree rejects leading-dash baseBranch" badBranchRej.isOk.not
  let diffRes ← diffCheckpoints repoDir.toString "HEAD" "WORKTREE"
  let diffRep := diffRes.toOption.get!
  assertTrue "diffCheckpoints detects modified + untracked files" (diffRep.files.size == 2)
  assertTrue "diffCheckpoints includes unified patch hunks" (diffRep.files.any (fun f => !f.patch.isEmpty))

  -- Restore to turn 1 pre-checkpoint (`app.txt == "v1\n"` and `extra.txt` removed!)
  let firstCp := cps[0]!
  let restoreRes ← restoreCheckpoint repoDir.toString "m-warm-1" firstCp.ref
  assertTrue "restoreCheckpoint succeeds" restoreRes.toOption.isSome
  let restoredContent ← IO.FS.readFile (repoDir / "app.txt")
  assertEq "restoreCheckpoint reverts tracked file to v1" restoredContent "v1\n"
  let extraStillExists ← System.FilePath.pathExists (repoDir / "extra.txt")
  assertEq "restoreCheckpoint cleans untracked file added after checkpoint" extraStillExists false

  -- Verify `inspectWorktreeStatus` (`Orb.Kernel.worktreeDecisionStep`) + `createMissionWorktree` + `removeMissionWorktree`
  let wtBusy ← inspectWorktreeStatus repoDir.toString "m-wt-2" #[repoDir.toString] false
  assertEq "Occupied repo triggers worktreeDecisionStep == 513" wtBusy.decisionWord 513
  assertEq "Occupied repo recommends isolated worktree" wtBusy.createWorktree true
  let wtCreatedRes ← createMissionWorktree repoDir.toString "m-wt-2" none
  assertTrue "createMissionWorktree succeeds" wtCreatedRes.toOption.isSome
  let wtCreated := wtCreatedRes.toOption.get!
  assertTrue "Sibling worktree path exists on disk" (← System.FilePath.pathExists wtCreated.worktreePath)
  let wtRemovedRes ← removeMissionWorktree wtCreated.worktreePath true
  assertTrue "removeMissionWorktree cleans up sibling worktree" wtRemovedRes.toOption.isSome

  let coordSeed ← OrbBin.MeshCli.generateCsprngSeed32
  let initFleetRes ← OrbBin.MeshCli.initPalomaFleet 1700000000 coordSeed
  assertTrue "initPalomaFleet signs and verifies Ed25519 manifest" initFleetRes.toOption.isSome

  -- 10. MacBook tether helpers: loopback UDP, WireGuard mac1, X25519/ChaCha20-Poly1305 PSK seal, OpenSSH Ed25519 keygen
  let (.ok (ufdA, uportA)) ← udpBind "127.0.0.1" 0 | throw <| IO.userError "udpBind A failed"
  let (.ok (ufdB, uportB)) ← udpBind "127.0.0.1" 0 | throw <| IO.userError "udpBind B failed"
  let loIp := (parseIpv4U32? "127.0.0.1").get!
  let sendRc ← udpSendTo ufdA loIp uportB "ping-lean-udp".toUTF8
  assertEq "udpSendTo loopback succeeds" sendRc 0
  let rxOpt ← udpRecvFromPoll ufdB 500 256
  closeFdRaw ufdA
  closeFdRaw ufdB
  let (some rxPkt) := rxOpt | throw <| IO.userError "udpRecvFromPoll timed out"
  assertEq "udpRecvFromPoll payload matches" (String.fromUTF8! rxPkt.payload) "ping-lean-udp"
  assertEq "udpRecvFromPoll srcPort matches" rxPkt.srcPort uportA

  let (.ok (kemPrivA, kemPubA, _)) ← generateWireguardKeypair | throw <| IO.userError "WG keygen A failed"
  let (.ok (kemPrivB, kemPubB, _)) ← generateWireguardKeypair | throw <| IO.userError "WG keygen B failed"
  let (.ok (_, pskSampleB64, _)) ← generateWireguardKeypair | throw <| IO.userError "PSK sample gen failed"
  let mac1Val ← wgMac1 (ByteArray.mk ((Array.range 32).map (·.toUInt8))) (ByteArray.mk (Array.replicate 116 0x42))
  assertEq "wgMac1 matches the BLAKE2s reference" (LeanSys.Auth.bytesToHexLower mac1Val) "fe7603c3fa9d38645bc6b67fd06b6f78"
  let (.ok sealedPsk) ← sealTetherPsk kemPrivA kemPubB "req-uuid-1" pskSampleB64 | throw <| IO.userError "sealTetherPsk failed"
  let (.ok openedPsk) ← openTetherPsk kemPrivB kemPubA "req-uuid-1" sealedPsk | throw <| IO.userError "openTetherPsk failed"
  assertEq "E2EE X25519+ChaCha20-Poly1305 PSK round-trip matches" openedPsk pskSampleB64
  let wrongReqOpen ← openTetherPsk kemPrivB kemPubA "req-uuid-2" sealedPsk
  assertTrue "openTetherPsk rejects mismatched requestId AAD" wrongReqOpen.isOk.not
  let (.ok (sshPem, sshPub)) ← generateOpenSshEd25519Keypair "orb-tether-test" | throw <| IO.userError "SSH keygen failed"
  assertTrue "OpenSSH PEM header present" (sshPem.startsWith "-----BEGIN OPENSSH PRIVATE KEY-----")
  assertTrue "OpenSSH authorized_keys line valid" (sshPub.startsWith "ssh-ed25519 ")

  try IO.FS.removeDirAll tmpDir catch _ => pure ()
  IO.println "=== ALL ORB-BIN WAVE 1 SELF-TESTS PASSED ==="
  return 0

end OrbBin.SelfTest
