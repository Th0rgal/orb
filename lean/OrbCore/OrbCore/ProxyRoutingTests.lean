/-
  Rust proxy model admission regressions. No vendor calls: all transport is mocked.
  Saved aliases are test-only configurations, not guessed production definitions.
-/
import OrbCore.Control

namespace OrbCore.ProxyRoutingTests
open LeanSys.Http LeanSys.Posix OrbBin.Json OrbBin.PosixExt OrbBin.Sqlite
open OrbCore.Control OrbCore.Store OrbCore.Proxy OrbCore.Managed

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"proxy routing contract: {label}")

private def chain (id name model : String) : RoutingChain := {
  id := id
  name := name
  targets := #[{ accountId := id, provider := "openai", baseUrl := "http://127.0.0.1:1", apiKey := "fixture-only", modelId := model }]
}

private class PumpOutcome (α : Type) where
  unpack : α → ByteArray × Bool
private instance : PumpOutcome ByteArray := ⟨(·, true)⟩
private instance : PumpOutcome (ByteArray × Bool) := ⟨id⟩

/-- A streamed reply reaches the client while the upstream is still producing it
    (regression: every `/v1/*` reply used to be buffered until its last byte). -/
def runStreaming : IO Unit := do
  -- Framing and request detection.
  check (requestWantsStream "/v1/chat/completions" "{\"stream\":true}".toUTF8) "stream flag"
  check (!requestWantsStream "/v1/chat/completions" "{\"stream\":false}".toUTF8) "stream false"
  check (requestWantsStream "/v1beta/models/g:streamGenerateContent" ByteArray.empty) "gemini stream path"
  check (encodeHttpChunk "hello".toUTF8 == "5\r\nhello\r\n".toUTF8 &&
    encodeHttpChunk ByteArray.empty == "0\r\n\r\n".toUTF8) "chunk frames"
  match stepBodyFraming (.length 3) "abcdef".toUTF8 with
  | .ok (out, _, fin) => check (out == "abc".toUTF8 && fin) "content-length framing"
  | .error _ => check false "content-length framing"
  -- Live relay over a loopback upstream that pauses between SSE events.
  let pieces := #["data: {\"n\":1}\n\n", "data: {\"n\":2}\n\n", "data: [DONE]\n\n"]
  let pauseMs : UInt32 := 400
  let .ok (lfd, port) ← tcpListen "127.0.0.1" 0 4
    | throw (IO.userError "proxy streaming: listen failed")
  let _ ← IO.asTask (prio := .dedicated) do
    if let .ok cfd ← tcpAcceptPoll lfd 5000 then
      discard <| pollReadable cfd 2000
      discard <| readStreamChunk cfd 65536
      discard <| writeAll cfd ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n").toUTF8 false
      for p in pieces do
        discard <| writeAll cfd (encodeHttpChunk p.toUTF8) false
        IO.sleep pauseMs
      discard <| writeAll cfd (encodeHttpChunk ByteArray.empty) false
      discard <| closeFd cfd
    discard <| closeFd lfd
  let streamChain : RoutingChain := {
    id := "s", name := "s",
    targets := #[{ accountId := "s", provider := "openai", baseUrl := s!"http://127.0.0.1:{port}", apiKey := "k", modelId := "m" }] }
  let out ← forwardProxyChain streamChain "POST" "/v1/chat/completions" #[]
    "{\"model\":\"m\",\"stream\":true}".toUTF8
  check (out.status == 200) s!"streamed status {out.status}"
  let some pump := out.stream?
    | throw (IO.userError "proxy streaming: 2xx stream reply was buffered")
  let t0 ← IO.monoMsNow
  let arrivals ← IO.mkRef (#[] : Array Nat)
  let (copy, _) := PumpOutcome.unpack <| ← pump fun piece => do
    if !piece.isEmpty then
      arrivals.modify (·.push ((← IO.monoMsNow) - t0))
    return true
  let times ← arrivals.get
  check (String.fromUTF8? copy == some (String.join pieces.toList)) "streamed body is intact"
  -- The first event must not wait for the upstream to finish (~3 pauses).
  check (times.size ≥ 2 && times[0]! + pauseMs.toNat ≤ times[times.size - 1]!) s!"events arrive as produced: {times}"

def runStreamingPumpContracts : IO Unit := do
  let failures ← IO.mkRef (#[] : Array String)
  let expect (ok : Bool) (label : String) : IO Unit := do
    if !ok then failures.modify (·.push label)
  let binary := ByteArray.mk #[0, 255, 13, 10]
  let payload := binary ++ "é".toUTF8
  let wire := encodeHttpChunk payload ++ encodeHttpChunk ByteArray.empty
  let cursor ← IO.mkRef (0 : Nat)
  let closes ← IO.mkRef (0 : Nat)
  let reader : UpstreamReader := {
    read := do
      let i ← cursor.get
      if i ≥ wire.size then return none
      cursor.set (i + 1)
      return some (wire.extract i (i + 1))
    close := closes.modify (· + 1)
  }
  let emitted ← IO.mkRef ByteArray.empty
  let (copy, copyComplete) := PumpOutcome.unpack <| ← pumpUpstreamBody reader (bodyFramingFor true none) ByteArray.empty fun bytes => do
    emitted.modify (· ++ bytes)
    return true
  expect (copy == payload && copyComplete && (← emitted.get) == payload) "byte-fragmented binary and UTF-8 body"
  expect ((← closes.get) == 1) "successful pump closes upstream exactly once"
  let reads ← IO.mkRef (0 : Nat)
  let cancelCloses ← IO.mkRef (0 : Nat)
  let cancelledReader : UpstreamReader := {
    read := do
      reads.modify (· + 1)
      return some "unexpected".toUTF8
    close := cancelCloses.modify (· + 1)
  }
  discard <| pumpUpstreamBody cancelledReader .untilClose "first".toUTF8 (fun _ => pure false)
  expect ((← reads.get) == 0 && (← cancelCloses.get) == 1)
    "failed downstream emit prevents further reads and closes upstream"
  let headOnlyReads ← IO.mkRef (0 : Nat)
  let headOnlyCloses ← IO.mkRef (0 : Nat)
  let headOnlyReader : UpstreamReader := {
    read := do
      headOnlyReads.modify (· + 1)
      return some "unexpected".toUTF8
    close := headOnlyCloses.modify (· + 1)
  }
  discard <| pumpUpstreamBody headOnlyReader (bodyFramingFor true none) ByteArray.empty (fun _ => pure false)
  expect ((← headOnlyReads.get) == 0 && (← headOnlyCloses.get) == 1)
    "aborted pump with empty tail closes upstream without reading"
  let truncatedCloses ← IO.mkRef (0 : Nat)
  let truncatedReader : UpstreamReader := {
    read := pure none
    close := truncatedCloses.modify (· + 1)
  }
  let (truncCopy, truncComplete) := PumpOutcome.unpack <|
    ← pumpUpstreamBody truncatedReader (.length 5) "ab".toUTF8 (fun _ => pure true)
  expect ((← truncatedCloses.get) == 1) "truncated pump closes upstream exactly once"
  expect (truncCopy == "ab".toUTF8 && !truncComplete)
    "truncated content-length must not report normal stream completion"

  let chunkCloses ← IO.mkRef (0 : Nat)
  let chunkReader : UpstreamReader := {
    read := pure none
    close := chunkCloses.modify (· + 1)
  }
  let (chunkCopy, chunkComplete) := PumpOutcome.unpack <|
    ← pumpUpstreamBody chunkReader (bodyFramingFor true none) (encodeHttpChunk "ab".toUTF8) (fun _ => pure true)
  expect ((← chunkCloses.get) == 1) "incomplete chunked pump closes upstream exactly once"
  expect (chunkCopy == "ab".toUTF8 && !chunkComplete)
    "chunked body without its final chunk must not report normal stream completion"

  let badChunkCloses ← IO.mkRef (0 : Nat)
  let badChunkReader : UpstreamReader := {
    read := pure none
    close := badChunkCloses.modify (· + 1)
  }
  let (badChunkCopy, badChunkComplete) := PumpOutcome.unpack <|
    ← pumpUpstreamBody badChunkReader (bodyFramingFor true none) "zz\r\n".toUTF8 (fun _ => pure true)
  expect ((← badChunkCloses.get) == 1) "malformed chunk pump closes upstream exactly once"
  expect (badChunkCopy.isEmpty && !badChunkComplete)
    "chunk decoding error must not report normal stream completion"

  let timeoutStep ← IO.mkRef (0 : Nat)
  let timeoutCloses ← IO.mkRef (0 : Nat)
  let timeoutEmitted ← IO.mkRef ByteArray.empty
  let timeoutReader : UpstreamReader := {
    read := do
      let n ← timeoutStep.get
      timeoutStep.set (n + 1)
      return if n == 0 then some "event-1\n".toUTF8 else none
    close := timeoutCloses.modify (· + 1)
    eof := pure false
  }
  let (timeoutCopy, timeoutComplete) := PumpOutcome.unpack <|
    ← pumpUpstreamBody timeoutReader .untilClose ByteArray.empty fun bytes => do
      timeoutEmitted.modify (· ++ bytes)
      return true
  expect (timeoutCopy == "event-1\n".toUTF8 && (← timeoutEmitted.get) == "event-1\n".toUTF8 &&
    !timeoutComplete && (← timeoutCloses.get) == 1)
    "untilClose reader ending on timeout or failure must not report normal stream completion"

  let eofStep ← IO.mkRef (0 : Nat)
  let eofCloses ← IO.mkRef (0 : Nat)
  let eofEmitted ← IO.mkRef ByteArray.empty
  let eofReader : UpstreamReader := {
    read := do
      let n ← eofStep.get
      eofStep.set (n + 1)
      return if n == 0 then some "event-1\n".toUTF8 else none
    close := eofCloses.modify (· + 1)
    eof := pure true
  }
  let (eofCopy, eofComplete) := PumpOutcome.unpack <|
    ← pumpUpstreamBody eofReader .untilClose ByteArray.empty fun bytes => do
      eofEmitted.modify (· ++ bytes)
      return true
  expect (eofCopy == "event-1\n".toUTF8 && (← eofEmitted.get) == "event-1\n".toUTF8 &&
    eofComplete && (← eofCloses.get) == 1)
    "untilClose reader ending on clean EOF reports normal stream completion"

  let .ok (ucLfd, ucPort) ← tcpListen "127.0.0.1" 0 4
    | throw (IO.userError "proxy streaming untilClose: listen failed")
  let ucTask ← IO.asTask (prio := .dedicated) do
    if let .ok ufd ← tcpAcceptPoll ucLfd 5000 then
      discard <| pollReadable ufd 2000
      discard <| readStreamChunk ufd 65536
      discard <| writeAll ufd ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: clean\n\n").toUTF8 false
      discard <| closeFd ufd
    discard <| closeFd ucLfd
  let mut ucCopy := ByteArray.empty
  let mut ucComplete := false
  if let .ok (_, some ucPump) ← streamingUpstreamRequest false "POST" "127.0.0.1" ucPort "/v1/chat/completions" #[]
      "{\"model\":\"m\",\"stream\":true}".toUTF8 then
    let (c, ok) ← ucPump (fun _ => pure true)
    ucCopy := c
    ucComplete := ok
  let _ := ucTask.get
  expect (ucCopy == "data: clean\n\n".toUTF8 && ucComplete)
    "loopback untilClose socket closed cleanly reports normal stream completion"

  -- Defect 1 (downstream wire) & (b): a cut-off upstream stream must not get a closing chunk
  -- from Core, and its partial SSE copy must still be accounted in proxy_usage.
  -- Defect 2 & (e): a refused downstream head write must immediately close the upstream
  -- connection even when the upstream sent only the response head and no body bytes.
  -- (c): a non-2xx error reply whose body is cut off preserves its HTTP status and partial body.
  let .ok (upLfd, upPort) ← tcpListen "127.0.0.1" 0 4
    | throw (IO.userError "proxy streaming head-fail: listen failed")
  let upClosed ← IO.mkRef false
  let partialSse := "data: {\"usage\":{\"input_tokens\":42,\"output_tokens\":7}}\n\n"
  let partialErr := "{\"error\":\"rate_limited\"}"
  let upTask ← IO.asTask (prio := .dedicated) do
    -- First connection: upstream cuts off a chunked stream without the final 0-length chunk.
    if let .ok ufd1 ← tcpAcceptPoll upLfd 5000 then
      discard <| pollReadable ufd1 2000
      discard <| readStreamChunk ufd1 65536
      discard <| writeAll ufd1 (("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n").toUTF8 ++ encodeHttpChunk partialSse.toUTF8) false
      discard <| closeFd ufd1
    -- Second connection: upstream sends only the head; downstream head write is refused.
    if let .ok ufd2 ← tcpAcceptPoll upLfd 5000 then
      discard <| pollReadable ufd2 2000
      discard <| readStreamChunk ufd2 65536
      discard <| writeAll ufd2 ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n").toUTF8 false
      if let .ok () ← pollReadable ufd2 1000 then
        let rest ← readStreamChunk ufd2 65536
        upClosed.set rest.isEmpty
      discard <| closeFd ufd2
    discard <| closeFd upLfd
  let .ok (errLfd, errPort) ← tcpListen "127.0.0.1" 0 4
    | throw (IO.userError "proxy streaming err-trunc: listen failed")
  let errTask ← IO.asTask (prio := .dedicated) do
    if let .ok ufd3 ← tcpAcceptPoll errLfd 5000 then
      discard <| pollReadable ufd3 2000
      discard <| readStreamChunk ufd3 65536
      discard <| writeAll ufd3 (s!"HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\n" ++
        s!"Content-Length: 100\r\n\r\n{partialErr}").toUTF8 false
      discard <| closeFd ufd3
    discard <| closeFd errLfd
  let headFailRoot := s!"/tmp/orb-stream-head-fail-{← newUuidV4}"
  let .ok headFailStore ← openCoreStore headFailRoot
    | throw (IO.userError "proxy streaming head-fail: store failed")
  let mut downstreamWire := ByteArray.empty
  let mut usageRows : Array (Array String) := #[]
  let mut truncErrStatus : Nat := 0
  let mut truncErrBody := ByteArray.empty
  try
    let hfManaged ← IO.mkRef ({} : ManagedFleetState)
    let hfChains ← IO.mkRef #[({
      id := "s", name := "s",
      targets := #[{ accountId := "s", provider := "openai", baseUrl := s!"http://127.0.0.1:{upPort}",
                     apiKey := "k", modelId := "m" }]
    } : RoutingChain)]
    let hfCooldowns ← IO.mkRef (#[] : Array AccountCooldown)
    let hfSeq ← IO.mkRef (1 : UInt64)
    let hfCfg : CoreConfig := {
      workingDir := headFailRoot
      dashboardPassword := "proxy-head-fail-password"
      proxySecret := "proxy-head-fail-secret-0123456789"
      jwtSecret := "proxy-head-fail-jwt-secret-0123456789"
    }
    let hfApp : CoreAppState := {
      cfg := hfCfg, store := headFailStore, searchIdx? := none,
      managedRef := hfManaged, chainsRef := hfChains,
      proxyCooldownsRef := hfCooldowns, seqRef := hfSeq
    }
    let .ok (cLfd, cPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming head-fail: client listen failed")
    let srvTask ← IO.asTask (prio := .dedicated) do
      if let .ok sfd1 ← tcpAcceptPoll cLfd 5000 then
        handleClientConn hfApp sfd1 false
      if let .ok sfd2 ← tcpAcceptPoll cLfd 5000 then
        handleClientConn hfApp sfd2 false (some fun _ => pure false)
      discard <| closeFd cLfd
    let body := "{\"model\":\"s\",\"stream\":true}"
    let req := s!"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {hfCfg.proxySecret}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
    if let .ok cfd1 ← tcpConnect "127.0.0.1" cPort then
      discard <| writeAll cfd1 req.toUTF8 false
      let mut done1 := false
      while !done1 do
        match ← pollReadable cfd1 2000 with
        | .ok () =>
          let part ← readStreamChunk cfd1 65536
          if part.isEmpty then done1 := true else downstreamWire := downstreamWire ++ part
        | .error _ => done1 := true
      discard <| closeFd cfd1
    if let .ok cfd2 ← tcpConnect "127.0.0.1" cPort then
      discard <| writeAll cfd2 req.toUTF8 false
      discard <| closeFd cfd2
    let _ := srvTask.get
    if let .ok (errResp, none) ← streamingUpstreamRequest false "POST" "127.0.0.1" errPort "/v1/chat/completions" #[] body.toUTF8 then
      truncErrStatus := errResp.status
      truncErrBody := errResp.body
    let _ := upTask.get
    let _ := errTask.get
    if let .ok rows ← execParamQuery headFailStore.missionsDb
        "SELECT input_tokens, output_tokens FROM proxy_usage ORDER BY id DESC LIMIT 1;" #[] then
      usageRows := rows
  finally
    closeCoreStore headFailStore
    discard <| (IO.FS.removeDirAll headFailRoot).toBaseIO
  let downstreamText := String.fromUTF8! downstreamWire
  expect (!downstreamText.endsWith "0\r\n\r\n")
    "cut-off upstream stream must not write closing chunk to client"
  expect (usageRows.size > 1 && usageRows[1]! == #["42", "7"])
    s!"cut-off upstream stream still accounts partial usage: {usageRows}"
  expect (← upClosed.get) "refused downstream head write still closes head-only upstream stream"
  expect (truncErrStatus == 429 && truncErrBody == partialErr.toUTF8)
    s!"truncated non-2xx reply keeps status and partial body: status={truncErrStatus}"

  -- Defect 3: the pacing concurrency slot must stay held until the stream body is relayed.
  let .ok (pLfd, pPort) ← tcpListen "127.0.0.1" 0 4
    | throw (IO.userError "proxy streaming pacing: listen failed")
  let pUpTask ← IO.asTask (prio := .dedicated) do
    if let .ok ufd ← tcpAcceptPoll pLfd 5000 then
      discard <| pollReadable ufd 2000
      discard <| readStreamChunk ufd 65536
      discard <| writeAll ufd ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n").toUTF8 false
      discard <| closeFd ufd
    discard <| closeFd pLfd
  let pTgt : ProviderTarget := {
    accountId := "paced-stream", provider := "openai",
    baseUrl := s!"http://127.0.0.1:{pPort}", apiKey := "k", modelId := "m",
    accountMaxConcurrency? := some 1, modelMaxConcurrency? := some 1
  }
  let pChain : RoutingChain := { id := "ps", name := "ps", targets := #[pTgt] }
  let tracker ← newProxyPacingTracker
  let pOut ← forwardProxyChain pChain "POST" "/v1/chat/completions" #[]
    "{\"model\":\"m\",\"stream\":true}".toUTF8 (pacingTracker? := some tracker)
  let some pPump := pOut.stream?
    | throw (IO.userError "proxy streaming pacing: expected a stream pump")
  let heldWhileOpen ← tryAcquireTargetSlot tracker pTgt (← IO.monoMsNow).toUInt64
  if heldWhileOpen then releaseTargetSlot tracker pTgt
  expect (!heldWhileOpen) "pacing concurrency slot stays held while the stream body is open"
  discard <| pPump (fun _ => pure true)
  let _ := pUpTask.get
  let admittedAfter ← tryAcquireTargetSlot tracker pTgt (← IO.monoMsNow).toUInt64
  if admittedAfter then releaseTargetSlot tracker pTgt
  expect admittedAfter "pacing concurrency slot is released once the stream body is relayed"

  -- Streamed idle-timeout budget across attempts and post-head stream idle behavior:
  -- (a) Fake upstream accepts and never answers, two targets in the chain: client gets
  --     504 {"error":"upstream_idle_timeout"} with X-Orb-Exhaustion-Class: upstream_idle_timeout
  --     within the cross-attempt budget plus a small margin, and the attempt count is reported.
  let .ok (hangLfd, hangPort) ← tcpListen "127.0.0.1" 0 8
    | throw (IO.userError "proxy streaming idle-budget: listen failed")
  let hangAccepted ← IO.mkRef (0 : Nat)
  let hangTask ← IO.asTask (prio := .dedicated) do
    for _ in [0:2] do
      if let .ok ufd ← tcpAcceptPoll hangLfd 10000 then
        hangAccepted.modify (· + 1)
        discard <| IO.asTask (prio := .dedicated) do
          discard <| pollReadable ufd 2000
          discard <| readStreamChunk ufd 65536
          IO.sleep 3000
          discard <| closeFd ufd
    discard <| closeFd hangLfd
  let hangChain : RoutingChain := {
    id := "hang-chain", name := "hang-chain",
    targets := #[
      { accountId := "h1", provider := "openai", baseUrl := s!"http://127.0.0.1:{hangPort}", apiKey := "k1", modelId := "m1" },
      { accountId := "h2", provider := "anthropic", baseUrl := s!"http://127.0.0.1:{hangPort}", apiKey := "k2", modelId := "m2" }
    ]
  }
  let idleRoot := s!"/tmp/orb-stream-idle-{← newUuidV4}"
  let .ok idleStore ← openCoreStore idleRoot
    | throw (IO.userError "proxy streaming idle-budget: store failed")
  try
    let idleManaged ← IO.mkRef ({} : ManagedFleetState)
    let idleChains ← IO.mkRef #[hangChain]
    let idleCooldowns ← IO.mkRef (#[] : Array AccountCooldown)
    let idleSeq ← IO.mkRef (1 : UInt64)
    let idleCfg : CoreConfig := {
      workingDir := idleRoot
      dashboardPassword := "proxy-idle-password"
      proxySecret := "proxy-idle-secret-0123456789"
      jwtSecret := "proxy-idle-jwt-secret-0123456789"
    }
    let idleApp : CoreAppState := {
      cfg := idleCfg, store := idleStore, searchIdx? := none,
      managedRef := idleManaged, chainsRef := idleChains,
      proxyCooldownsRef := idleCooldowns, seqRef := idleSeq,
      proxyStreamLimits? := some { idleMs := 200, totalMs := 10000, preHeadBudgetMs := 350 }
    }
    let .ok (cHangLfd, cHangPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming idle-budget: client listen failed")
    let cHangSrv ← IO.asTask (prio := .dedicated) do
      if let .ok sfd ← tcpAcceptPoll cHangLfd 10000 then
        handleClientConn idleApp sfd false
      discard <| closeFd cHangLfd
    let hangReqBody := "{\"model\":\"hang-chain\",\"stream\":true}"
    let hangReqWire := s!"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {idleCfg.proxySecret}\r\nContent-Length: {hangReqBody.utf8ByteSize}\r\n\r\n{hangReqBody}"
    let tHang0 ← IO.monoMsNow
    let mut hangClientWire := ByteArray.empty
    if let .ok cfd ← tcpConnect "127.0.0.1" cHangPort then
      discard <| writeAll cfd hangReqWire.toUTF8 false
      let mut doneH := false
      while !doneH do
        match ← pollReadable cfd 10000 with
        | .ok () =>
          let part ← readStreamChunk cfd 65536
          if part.isEmpty then doneH := true else hangClientWire := hangClientWire ++ part
        | .error _ => doneH := true
      discard <| closeFd cfd
    let hangElapsed := (← IO.monoMsNow) - tHang0
    let _ := cHangSrv.get
    let _ := hangTask.get
    let .ok hangParsed := OrbNetLeaf.TlsHttp.parseHttpResponseWire hangClientWire 65536 true "POST"
      | throw (IO.userError s!"proxy streaming idle-budget: client wire parse failed: {String.fromUTF8? hangClientWire}")
    let hangBodyStr := (String.fromUTF8? hangParsed.body).getD ""
    let exhHdr := lookupHeader? hangParsed.headers "x-orb-exhaustion-class"
    let attHdr := lookupHeader? hangParsed.headers "x-orb-attempts-used"
    expect (hangParsed.status == 504) s!"(a) expected 504 on pre-head idle budget exhaustion, got {hangParsed.status}"
    expect (hangBodyStr == "{\"error\":\"upstream_idle_timeout\"}")
      s!"(a) expected exact upstream_idle_timeout body, got {hangBodyStr}"
    expect (exhHdr == some "upstream_idle_timeout")
      s!"(a) expected X-Orb-Exhaustion-Class: upstream_idle_timeout, got {exhHdr}"
    expect (attHdr == some "2" && (← hangAccepted.get) == 2)
      s!"(a) expected 2 attempts reported across chain within budget, got header={attHdr} accepted={← hangAccepted.get}"
    expect (hangElapsed ≥ 300 && hangElapsed < 10000)
      s!"(a) expected completion within 350ms budget .. 10000ms bound, took {hangElapsed}ms"
    if let .ok rows ← execParamQuery idleStore.missionsDb
        "SELECT status, http_status, retries FROM proxy_outcomes ORDER BY id DESC LIMIT 1;" #[] then
      expect (rows.size > 1 && rows[1]! == #["upstream_idle_timeout", "504", "1"])
        s!"(a) proxy_outcomes records upstream_idle_timeout and retries: {rows}"

    -- Distinct pre-head idle timeout reason on a single attempt within a larger budget:
    -- attempt 1 idles out at 150ms (recorded as upstream_idle_timeout), attempt 2 returns 503,
    -- chain exhaustion body names upstream_idle_timeout for attempt 1 (not generic transport_error).
    let .ok (mixLfd, mixPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming distinct-idle: listen failed")
    let mixTask ← IO.asTask (prio := .dedicated) do
      if let .ok ufd1 ← tcpAcceptPoll mixLfd 10000 then
        discard <| IO.asTask (prio := .dedicated) do
          discard <| pollReadable ufd1 2000
          discard <| readStreamChunk ufd1 65536
          IO.sleep 3000
          discard <| closeFd ufd1
      if let .ok ufd2 ← tcpAcceptPoll mixLfd 10000 then
        discard <| pollReadable ufd2 2000
        discard <| readStreamChunk ufd2 65536
        let b2 := "{\"error\":{\"code\":\"overloaded\"}}"
        discard <| writeAll ufd2 (s!"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: {b2.utf8ByteSize}\r\n\r\n{b2}").toUTF8 false
        discard <| closeFd ufd2
      discard <| closeFd mixLfd
    let mixChain : RoutingChain := {
      id := "mix", name := "mix",
      targets := #[
        { accountId := "m1", provider := "openai", baseUrl := s!"http://127.0.0.1:{mixPort}", apiKey := "k1", modelId := "m1" },
        { accountId := "m2", provider := "anthropic", baseUrl := s!"http://127.0.0.1:{mixPort}", apiKey := "k2", modelId := "m2" }
      ]
    }
    let mixOut ← forwardProxyChain mixChain "POST" "/v1/chat/completions" #[]
      "{\"model\":\"mix\",\"stream\":true}".toUTF8
      (streamLimits? := some { idleMs := 150, totalMs := 10000, preHeadBudgetMs := 5000 })
    let _ := mixTask.get
    let mixBodyStr := (String.fromUTF8? mixOut.body).getD ""
    expect (mixOut.attemptsUsed == 2 && (mixBodyStr.splitOn "\"code\":\"upstream_idle_timeout\"").length > 1)
      s!"(c-distinct) pre-head idle attempt recorded as upstream_idle_timeout before failover: {mixBodyStr}"

    -- Non-2xx upstream answer finishing after preHeadBudgetMs is not relabelled 504:
    -- target 1 sends 429 headers before the 150ms pre-head budget, then sends the 429 body
    -- at 200ms (after the budget is spent). Failover stops at attempt 1 and returns the real 429.
    let .ok (rlLfd, rlPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming non2xx-after-budget: listen failed")
    let rlTask ← IO.asTask (prio := .dedicated) do
      if let .ok ufd ← tcpAcceptPoll rlLfd 10000 then
        discard <| pollReadable ufd 2000
        discard <| readStreamChunk ufd 65536
        let b429 := "{\"error\":{\"code\":\"rate_limit_exceeded\"}}"
        discard <| writeAll ufd (s!"HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: {b429.utf8ByteSize}\r\n\r\n").toUTF8 false
        IO.sleep 200
        discard <| writeAll ufd b429.toUTF8 false
        discard <| closeFd ufd
      discard <| closeFd rlLfd
    let rlChain : RoutingChain := {
      id := "rl-budget", name := "rl-budget",
      targets := #[
        { accountId := "r1", provider := "openai", baseUrl := s!"http://127.0.0.1:{rlPort}", apiKey := "k1", modelId := "m1" },
        { accountId := "r2", provider := "anthropic", baseUrl := s!"http://127.0.0.1:{rlPort}", apiKey := "k2", modelId := "m2" }
      ]
    }
    let rlOut ← forwardProxyChain rlChain "POST" "/v1/chat/completions" #[]
      "{\"model\":\"rl-budget\",\"stream\":true}".toUTF8
      (streamLimits? := some { idleMs := 2000, totalMs := 10000, preHeadBudgetMs := 150 })
    let _ := rlTask.get
    expect (rlOut.status == 429 && rlOut.attemptsUsed == 1 && rlOut.exhaustionClass != "upstream_idle_timeout")
      s!"(a-non2xx) real 429 after pre-head budget stops failover and keeps 429: status={rlOut.status} attempts={rlOut.attemptsUsed} class={rlOut.exhaustionClass}"

    -- (b) Upstream sends a head and one chunk, then nothing: client receives the chunk,
    --     then the connection is closed without the zero chunk within idle plus margin,
    --     and proxy_outcomes records upstream_idle_timeout.
    let postIdleApp : CoreAppState := {
      idleApp with
      proxyStreamLimits? := some { idleMs := 200, totalMs := 10000, preHeadBudgetMs := 5000 }
    }
    let .ok (postIdleLfd, postIdlePort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming post-head-idle: listen failed")
    let oneChunk := "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}\n\n"
    let postIdleTask ← IO.asTask (prio := .dedicated) do
      if let .ok ufd ← tcpAcceptPoll postIdleLfd 10000 then
        discard <| pollReadable ufd 2000
        discard <| readStreamChunk ufd 65536
        discard <| writeAll ufd (("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++
          "Transfer-Encoding: chunked\r\n\r\n").toUTF8 ++ encodeHttpChunk oneChunk.toUTF8) false
        discard <| IO.asTask (prio := .dedicated) do
          IO.sleep 3000
          discard <| closeFd ufd
      discard <| closeFd postIdleLfd
    idleChains.set #[{
      id := "post-idle", name := "post-idle",
      targets := #[{ accountId := "p1", provider := "openai", baseUrl := s!"http://127.0.0.1:{postIdlePort}", apiKey := "k", modelId := "m" }]
    }]
    let .ok (cPostLfd, cPostPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming post-head-idle: client listen failed")
    let cPostSrv ← IO.asTask (prio := .dedicated) do
      if let .ok sfd ← tcpAcceptPoll cPostLfd 10000 then
        handleClientConn postIdleApp sfd false
      discard <| closeFd cPostLfd
    let postReqBody := "{\"model\":\"post-idle\",\"stream\":true}"
    let postReqWire := s!"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {idleCfg.proxySecret}\r\nContent-Length: {postReqBody.utf8ByteSize}\r\n\r\n{postReqBody}"
    let tPost0 ← IO.monoMsNow
    let mut postClientWire := ByteArray.empty
    if let .ok cfd ← tcpConnect "127.0.0.1" cPostPort then
      discard <| writeAll cfd postReqWire.toUTF8 false
      let mut doneP := false
      while !doneP do
        match ← pollReadable cfd 10000 with
        | .ok () =>
          let part ← readStreamChunk cfd 65536
          if part.isEmpty then doneP := true else postClientWire := postClientWire ++ part
        | .error _ => doneP := true
      discard <| closeFd cfd
    let postElapsed := (← IO.monoMsNow) - tPost0
    let _ := cPostSrv.get
    let _ := postIdleTask.get
    let postWireStr := (String.fromUTF8? postClientWire).getD ""
    expect ((postWireStr.splitOn oneChunk).length > 1 && !postWireStr.endsWith "0\r\n\r\n")
      s!"(b) client receives chunk and closes without terminating 0 chunk: {postWireStr}"
    expect (postElapsed ≥ 180 && postElapsed < 10000)
      s!"(b) post-head idle closes within 200ms idle .. 10000ms bound, took {postElapsed}ms"
    if let .ok rows ← execParamQuery idleStore.missionsDb
        "SELECT status, http_status FROM proxy_outcomes ORDER BY id DESC LIMIT 1;" #[] then
      expect (rows.size > 1 && rows[1]! == #["upstream_idle_timeout", "200"])
        s!"(b) post-head idle timeout recorded in proxy_outcomes.status: {rows}"

    -- (c) Normal stream is unchanged under injected limits.
    let .ok (normLfd, normPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming normal: listen failed")
    let normTask ← IO.asTask (prio := .dedicated) do
      if let .ok ufd ← tcpAcceptPoll normLfd 10000 then
        discard <| pollReadable ufd 2000
        discard <| readStreamChunk ufd 65536
        discard <| writeAll ufd (("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++
          "Transfer-Encoding: chunked\r\n\r\n").toUTF8 ++
          encodeHttpChunk "data: {\"n\":1}\n\n".toUTF8 ++
          encodeHttpChunk ByteArray.empty) false
        discard <| closeFd ufd
      discard <| closeFd normLfd
    idleChains.set #[{
      id := "norm", name := "norm",
      targets := #[{ accountId := "n1", provider := "openai", baseUrl := s!"http://127.0.0.1:{normPort}", apiKey := "k", modelId := "m" }]
    }]
    let .ok (cNormLfd, cNormPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming normal: client listen failed")
    let cNormSrv ← IO.asTask (prio := .dedicated) do
      if let .ok sfd ← tcpAcceptPoll cNormLfd 10000 then
        handleClientConn postIdleApp sfd false
      discard <| closeFd cNormLfd
    let normReqBody := "{\"model\":\"norm\",\"stream\":true}"
    let normReqWire := s!"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {idleCfg.proxySecret}\r\nContent-Length: {normReqBody.utf8ByteSize}\r\n\r\n{normReqBody}"
    let mut normClientWire := ByteArray.empty
    if let .ok cfd ← tcpConnect "127.0.0.1" cNormPort then
      discard <| writeAll cfd normReqWire.toUTF8 false
      let mut doneN := false
      while !doneN do
        match ← pollReadable cfd 10000 with
        | .ok () =>
          let part ← readStreamChunk cfd 65536
          if part.isEmpty then doneN := true else normClientWire := normClientWire ++ part
        | .error _ => doneN := true
      discard <| closeFd cfd
    let _ := cNormSrv.get
    let _ := normTask.get
    let normWireStr := (String.fromUTF8? normClientWire).getD ""
    expect ((normWireStr.splitOn "data: {\"n\":1}\n\n").length > 1 && normWireStr.endsWith "0\r\n\r\n")
      s!"(c) normal stream completes with terminating 0 chunk: {normWireStr}"
    if let .ok rows ← execParamQuery idleStore.missionsDb
        "SELECT status, http_status FROM proxy_outcomes ORDER BY id DESC LIMIT 1;" #[] then
      expect (rows.size > 1 && rows[1]! == #["ok", "200"])
        s!"(c) normal stream records ok in proxy_outcomes.status: {rows}"

    -- (d) Upstream sends only a keep-alive line every 80ms while idleMs is 200ms:
    --     any upstream byte resets the idle clock, so the stream stays open across 350ms
    --     (> idleMs) until the total limit (450ms) cuts it off.
    let .ok (kaLfd, kaPort) ← tcpListen "127.0.0.1" 0 4
      | throw (IO.userError "proxy streaming keepalive: listen failed")
    let kaTask ← IO.asTask (prio := .dedicated) do
      if let .ok ufd ← tcpAcceptPoll kaLfd 10000 then
        discard <| pollReadable ufd 2000
        discard <| readStreamChunk ufd 65536
        discard <| writeAll ufd ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++
          "Transfer-Encoding: chunked\r\n\r\n").toUTF8 false
        for _ in [0:10] do
          IO.sleep 80
          discard <| writeAll ufd (encodeHttpChunk ": keepalive\n\n".toUTF8) false
        discard <| closeFd ufd
      discard <| closeFd kaLfd
    let kaChain : RoutingChain := {
      id := "ka", name := "ka",
      targets := #[{ accountId := "ka1", provider := "openai", baseUrl := s!"http://127.0.0.1:{kaPort}", apiKey := "k", modelId := "m" }]
    }
    let tKa0 ← IO.monoMsNow
    let kaOut ← forwardProxyChain kaChain "POST" "/v1/chat/completions" #[]
      "{\"model\":\"ka\",\"stream\":true}".toUTF8
      (streamLimits? := some { idleMs := 200, totalMs := 450, preHeadBudgetMs := 5000 })
    let some kaPump := kaOut.stream?
      | throw (IO.userError "proxy streaming keepalive: expected stream pump")
    let (kaCopy, kaComplete) := PumpOutcome.unpack <| ← kaPump (fun _ => pure true)
    let kaElapsed := (← IO.monoMsNow) - tKa0
    let _ := kaTask.get
    let kaText := (String.fromUTF8? kaCopy).getD ""
    expect (!kaComplete && kaElapsed ≥ 350 && kaElapsed < 10000 && (kaText.splitOn ": keepalive").length ≥ 3)
      s!"(d) keep-alive lines every 80ms reset the 200ms idle timer until the 450ms total limit fires: elapsed={kaElapsed}ms complete={kaComplete}"
  finally
    closeCoreStore idleStore
    discard <| (IO.FS.removeDirAll idleRoot).toBaseIO

  let bad ← failures.get
  check bad.isEmpty (String.intercalate "; " bad.toList)


/-- Actual request routing, including unknown errors and no default/name/suffix aliasing. -/
def run : IO Unit := do
  runStreaming
  runStreamingPumpContracts
  -- A spent Antigravity quota cools only that model: Opus 4.6 and Gemini stay eligible.
  let agClaude := OrbCore.ProxyModelRouting.antigravityPoolAccount "claude-opus-5-5-high"
  let agGemini := OrbCore.ProxyModelRouting.antigravityPoolAccount "gemini-4-carbon-eap"
  let agOpus46 := OrbCore.ProxyModelRouting.antigravityPoolAccount "claude-opus-4-6-thinking"
  check (agClaude != agGemini && agClaude != agOpus46) "each Antigravity model is its own pool"
  let opus55Spent : AccountCooldown := { accountId := agClaude, untilEpoch := 2000, reason := .usageLimit }
  let fallbackChain : RoutingChain := { id := "google-opus", name := "g", targets := #[
    { accountId := agClaude, provider := "antigravity", baseUrl := "", apiKey := "", modelId := "claude-opus-5-5-high" },
    { accountId := agOpus46, provider := "antigravity", baseUrl := "", apiKey := "", modelId := "claude-opus-4-6-thinking" }] }
  check ((planChain fallbackChain #[opus55Spent] 1000).eligible.size == 1) "Opus 5.5 limit leaves Opus 4.6 eligible"
  let agChain : RoutingChain := { id := "google-opus", name := "g", targets := #[
    { accountId := agClaude, provider := "antigravity", baseUrl := "", apiKey := "", modelId := "claude-opus-5-5-high" }] }
  let geminiSpent : AccountCooldown := { accountId := agGemini, untilEpoch := 2000, reason := .usageLimit }
  check ((planChain agChain #[geminiSpent] 1000).eligible.size == 1) "Gemini limit leaves Claude eligible"
  let fixtureRaw ← IO.FS.readFile "shared/orb-spec/fixtures/proxy-model-aliases.json"
  let .ok fixture := OrbBin.Json.parse fixtureRaw
    | throw (IO.userError "proxy alias reference fixture failed to parse")
  for pair in (fixture.fieldArr? "provider_prefixes").getD #[] do
    let values := pair.asArr?.getD #[]
    let providerPrefix := (values[0]?.bind JVal.asStr?).getD ""
    let provider := (values[1]?.bind JVal.asStr?).getD ""
    check (OrbCore.ProxyModelRouting.directEntry? s!"{providerPrefix}/org/model-x" "/v1/chat/completions" ==
      some (provider, "org/model-x")) s!"direct prefix {providerPrefix}"
  for c in (fixture.fieldArr? "bare_cases").getD #[] do
    let model := (c.fieldStr? "model").getD ""
    let path := (c.fieldStr? "path").getD ""
    let expected := c.fieldOrNull "expected"
    let actual := OrbCore.ProxyModelRouting.directEntry? model path
    if expected.isNull then check actual.isNone s!"unexpected bare model {model}"
    else
      let pair := expected.asArr?.getD #[]
      check (actual == some ((pair[0]?.bind JVal.asStr?).getD "", (pair[1]?.bind JVal.asStr?).getD "")) s!"bare model {model}"
  for c in (fixture.fieldArr? "stock_entries").getD #[] do
    let id := (c.fieldStr? "id").getD ""
    let some (_, _, entries) := OrbCore.ProxyModelRouting.stockChains.find? (fun (i, _, _) => i == id)
      | throw (IO.userError s!"missing stock reference {id}")
    let encoded := JVal.arr (entries.map (fun (p, m) => .arr #[.str p, .str m]))
    check (encoded == c.fieldOrNull "entries") s!"stock target order {id}"
  for (alias, expected) in #[
      ("fable-5.2", some "anthropic/claude-fable-5-2"), ("opus-5.5", some "anthropic/claude-opus-5-5"),
      ("claude-fable-5-2", some "anthropic/claude-fable-5-2"), ("gpt-6-astra", some "openai/gpt-6-astra"),
      ("anthropic/claude-fable-5-2", some "anthropic/claude-fable-5-2"),
      ("github-copilot/claude-fable-5.2", some "github-copilot/claude-fable-5.2"),
      ("builtin/smart", some "builtin/smart"), ("no-such-family", none), ("nowhere/model", none), ("", none)] do
    check (OrbCore.ProxyModelRouting.consultModel? alias == expected) s!"consult alias {alias}"
  let root := s!"/tmp/orb-proxy-routing-{← newUuidV4}"
  let .ok store ← openCoreStore root
    | throw (IO.userError "proxy routing fixture store failed")
  try
    let managedRef ← IO.mkRef ({} : ManagedFleetState)
    let chainsRef ← IO.mkRef #[
      chain "builtin/smart" "Smart (Default)" "stock-smart-model",
      chain "smart" "Custom smart" "exact-smart-model",
      chain "reviewer" "Reviewer" "review-model",
      chain "MiniMax-M3" "Scout" "scout-model",
      chain "user/review" "Friendly review display" "namespaced-review-model"]
    let cooldowns ← IO.mkRef (#[] : Array AccountCooldown)
    let seqRef ← IO.mkRef (1 : UInt64)
    let attempts ← IO.mkRef (#[] : Array String)
    let cfg : CoreConfig := {
      workingDir := root
      dashboardPassword := "proxy-routing-fixture-password"
      proxySecret := "proxy-routing-fixture-secret-0123456789"
      jwtSecret := "proxy-routing-fixture-jwt-secret-0123456789"
    }
    let app : CoreAppState := {
      cfg, store, searchIdx? := none, managedRef, chainsRef,
      proxyCooldownsRef := cooldowns, seqRef,
      proxyMockTransport? := some (fun target => do
        attempts.modify (·.push target.modelId)
        if target.modelId.startsWith "fail400-" then
          return .ok {
            status := 400
            headers := #[("content-type", "application/json")]
            body := "{\"error\":{\"message\":\"unknown provider for model k3\",\"code\":\"model_not_found\"}}".toUTF8
          }
        if target.modelId.startsWith "fail404-" then
          return .ok {
            status := 404
            headers := #[("content-type", "text/plain")]
            body := "Not Found".toUTF8
          }
        if target.modelId.startsWith "fail401-" then
          return .ok {
            status := 401
            headers := #[("content-type", "application/json")]
            body := "{\"error\":{\"type\":\"auth_unavailable\",\"message\":\"account someone@example.test: invalid_grant\"}}".toUTF8
          }
        if target.modelId.startsWith "claude-" then
          return .ok {
            status := 503
            headers := #[("content-type", "application/json")]
            body := "{\"error\":{\"type\":\"auth_unavailable\",\"message\":\"no auth available\"}}".toUTF8
          }
        return .ok {
          status := 200
          headers := #[("content-type", "application/json")]
          body := "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"fixture output\"},\"finish_reason\":\"stop\"}]}".toUTF8
        })
    }
    let postAt := fun (path model : String) => do
      let body := renderCompact (.obj #[("model", .str model), ("messages", .arr #[])])
      let raw := s!"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {cfg.proxySecret}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none
        | throw (IO.userError "proxy routing fixture request parse failed")
      let .ok response ← dispatchCoreRequest app req 1700001000
        | throw (IO.userError "unexpected proxy routing websocket upgrade")
      return response
    let post := postAt "/v1/chat/completions"
    let mut failures : Array String := #[]
    -- Exact id wins even when a builtin compatibility id occurs earlier.
    for (model, expected) in #[
        ("smart", "exact-smart-model"), ("builtin/smart", "stock-smart-model"),
        ("reviewer", "review-model"), ("builtin/reviewer", "review-model"),
        ("MiniMax-M3", "scout-model"), ("builtin/MiniMax-M3", "scout-model"),
        ("user/review", "namespaced-review-model"),
        ("builtin/user/review", "namespaced-review-model")] do
      attempts.set #[]
      let response ← post model
      if response.status != 200 || (← attempts.get) != #[expected] then
        failures := failures.push s!"{model}: wrong saved-chain target or status"
    -- Neither display names, arbitrary namespace suffixes, case-folding nor an
    -- unknown id may silently choose the default chain.
    for model in #["Friendly review display", "Smart (Default)", "Smart", " smart ",
        "BUILTIN/smart", "other/smart", "missing-model", "unknown\"quoted-model"] do
      attempts.set #[]
      let response ← post model
      let body := (OrbBin.Json.parseBytes response.body).toOption.getD .null
      let error := body.fieldOrNull "error"
      if response.status != 400 || error.fieldStr? "code" != some "model_not_found" ||
          (((error.fieldStr? "message").getD "").splitOn model).length ≤ 1 ||
          !(← attempts.get).isEmpty then
        failures := failures.push s!"{model}: expected named 400 before transport"
    -- Exercise every saved id and its compatibility spelling, not an allowlist
    -- containing only today's smart/reviewer incidents.
    for c in (← chainsRef.get) do
      for requested in #[c.id, s!"builtin/{c.id}"] do
        let expected := if let some exactChain := (← chainsRef.get).find? (fun x => x.id == requested) then
            exactChain.targets[0]!.modelId
          else c.targets[0]!.modelId
        attempts.set #[]
        let response ← post requested
        if response.status != 200 || (← attempts.get) != #[expected] then
          failures := failures.push s!"configured alias {requested}: not resolved"
    if !failures.isEmpty then
      throw (IO.userError (String.intercalate "\n" failures.toList))
    -- No silent substitution: a model owned by a provider whose login is dead
    -- surfaces that provider's error. It never reaches the smart chain's model.
    let .ok () ← upsertAIProvider store { id := "anth-fixture", providerType := "anthropic", name := "Anthropic fixture", apiKey := "fixture-only" }
      | throw (IO.userError "anthropic fixture provider failed")
    for (path, model, bare) in #[
        ("/v1/messages", "claude-fable-5-2", "claude-fable-5-2"),
        ("/v1/messages", "claude-sonnet-5-5", "claude-sonnet-5-5"),
        ("/v1/chat/completions", "claude-fable-5-2", "claude-fable-5-2"),
        ("/v1/chat/completions", "anthropic/claude-fable-5-2", "claude-fable-5-2")] do
      attempts.set #[]
      let response ← postAt path model
      let text := (String.fromUTF8? response.body).getD ""
      let hdr := fun (k : String) => ((response.extraHdrs.find? (fun h => h.1 == k)).map (·.2)).getD ""
      check (response.status == 503 && (text.splitOn "auth_unavailable").length == 2)
        s!"{model} on {path}: upstream error must be relayed, got {response.status} {text}"
      check ((← attempts.get) == #[bare]) s!"{model} on {path}: served by another model {← attempts.get}"
      check (hdr "X-Orb-Requested-Model" == model && hdr "X-Orb-Effective-Model" == bare && hdr "X-Orb-Route" == "direct")
        s!"{model}: requested/effective headers"
    let .ok recorded ← execParamQuery store.missionsDb
        "SELECT COUNT(*), COALESCE(SUM(CASE WHEN model IN ('claude-fable-5-2','claude-sonnet-5-5') THEN 1 ELSE 0 END),0) FROM proxy_outcomes WHERE chain_id='direct';" #[]
      | throw (IO.userError "proxy_outcomes query failed")
    check (recorded[1]? == some #["4", "4"]) s!"direct outcomes must record the unchanged effective model: {recorded}"
    let .ok chainRows ← execParamQuery store.missionsDb
        "SELECT COUNT(*) FROM proxy_outcomes WHERE requested_model='reviewer' AND chain_id='reviewer' AND model='review-model' AND status='ok';" #[]
      | throw (IO.userError "proxy_outcomes chain query failed")
    check ((((chainRows[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 0) "chain alias outcome records requested and effective model"
    -- Fallback Chains contract: every row decodes as the clients' `ModelChain`.
    let jwt := mintSessionToken cfg.jwtSecret (1700001000 + 3600)
    let api := fun (method path body : String) => do
      let raw := s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none
        | throw (IO.userError "chain contract request parse failed")
      let .ok response ← dispatchCoreRequest app req 1700001000
        | throw (IO.userError "chain contract unexpected upgrade")
      return (response.status, (OrbBin.Json.parseBytes response.body).toOption.getD .null)
    let .ok contract := OrbBin.Json.parse (← IO.FS.readFile "shared/orb-spec/fixtures/model-chains-response.json")
      | throw (IO.userError "model-chains-response fixture failed to parse")
    let typeOf := fun (v : JVal) => match v with
      | .str _ => "string" | .bool _ => "boolean" | .arr _ => "array" | .num _ => "number" | .obj _ => "object" | .null => "null"
    let conforms := fun (row : JVal) =>
      ((contract.fieldOrNull "required").asObj?.getD #[]).all (fun (k, t) => (row.field? k).map typeOf == t.asStr?) &&
      ((row.fieldArr? "entries").getD #[]).all (fun e =>
        ((contract.fieldOrNull "entry_required").asObj?.getD #[]).all (fun (k, t) => (e.field? k).map typeOf == t.asStr?)) &&
      ((contract.fieldArr? "forbidden").getD #[]).all (fun k => !((renderCompact row).splitOn s!"\"{k.asStr?.getD "?"}\"").length > 1)
    let (createSt, created) ← api "POST" "/api/model-routing/chains"
      "{\"id\":\"contract\",\"name\":\"Contract\",\"entries\":[{\"provider_id\":\"zai\",\"model_id\":\"glm-5.3\",\"api_key\":\"sk-inline-secret\"}]}"
    check (createSt == 201 && conforms created) s!"create returns the chain row: {createSt} {renderCompact created}"
    let (listSt, listed) ← api "GET" "/api/model-routing/chains" ""
    let rows := listed.asArr?.getD #[]
    check (listSt == 200 && rows.size ≥ 7 && rows.all conforms) s!"chain list rows must match the client type: {renderCompact listed}"
    check ((rows.filter (fun r => r.fieldBool? "is_default" == some true)).map (·.fieldStr? "id") == #[some "builtin/smart"])
      "exactly the stock default chain is default before anyone chooses one"
    -- The desktop's "set default" sends only `is_default`; entries and name survive.
    let (putSt, updated) ← api "PUT" "/api/model-routing/chains/contract" "{\"is_default\":true}"
    check (putSt == 200 && conforms updated && updated.fieldBool? "is_default" == some true &&
      updated.fieldStr? "name" == some "Contract" && ((updated.fieldArr? "entries").getD #[]).size == 1)
      s!"partial update must keep entries and name: {putSt} {renderCompact updated}"
    let (_, relisted) ← api "GET" "/api/model-routing/chains" ""
    check (((relisted.asArr?.getD #[]).filter (fun r => r.fieldBool? "is_default" == some true)).map (·.fieldStr? "id") == #[some "contract"])
      "setting a default leaves exactly one default chain"
    let (getSt, got) ← api "GET" "/api/model-routing/chains/contract" ""
    let (missSt, _) ← api "GET" "/api/model-routing/chains/absent-chain" ""
    let (delBuiltinSt, _) ← api "DELETE" "/api/model-routing/chains/builtin/smart" ""
    let (delSt, _) ← api "DELETE" "/api/model-routing/chains/contract" ""
    let (delAgainSt, _) ← api "DELETE" "/api/model-routing/chains/contract" ""
    let (emptySt, _) ← api "POST" "/api/model-routing/chains" "{\"id\":\"empty\",\"entries\":[]}"
    let (unknownSt, _) ← api "GET" "/api/model-routing/no-such-route" ""
    check (getSt == 200 && conforms got && missSt == 404 && delBuiltinSt != 200 && delSt == 200 && delAgainSt == 404 &&
      emptySt == 400 && unknownSt == 404)
      s!"chain get/delete/create must not fabricate success: get={getSt} miss={missSt} builtin={delBuiltinSt} del={delSt} again={delAgainSt} empty={emptySt} unknown={unknownSt}"
    -- A client can only echo provider + model: saving must not erase a stored inline
    -- setting for an entry it kept, and must drop the entries it removed.
    check (OrbCore.ProxyModelRouting.keepStoredEntrySettings
        "[{\"provider_id\":\"b\",\"model_id\":\"m2\"},{\"provider_id\":\"a\",\"model_id\":\"m1\"}]"
        "[{\"provider_id\":\"a\",\"model_id\":\"m1\",\"base_url\":\"http://h\"},{\"provider_id\":\"c\",\"model_id\":\"m3\"}]"
      == "[{\"provider_id\":\"b\",\"model_id\":\"m2\"},{\"provider_id\":\"a\",\"model_id\":\"m1\",\"base_url\":\"http://h\"}]")
      "saving a chain keeps stored entry settings"
    check (OrbCore.ProxyModelRouting.directEntry? "my_spark_42/org/model-x" "/v1/chat/completions"
      #[("my_spark_42", "org/model-x")] == some ("my_spark_42", "org/model-x")) "advertised custom namespace"
    check ((OrbCore.ProxyModelRouting.directEntry? "my_spark_42/typo" "/v1/chat/completions"
      #[("my_spark_42", "org/model-x")]).isNone) "unadvertised custom model"
    -- Fresh stores retain all six historical stock chain ids, without guessing
    -- targets for arbitrary reviewer/scout aliases.
    let stock ← loadRoutingChainsFromStore store root
    for id in #["builtin/smart", "builtin/cheap", "builtin/fast", "builtin/assistant",
        "google-opus", "google-sonnet"] do
      check (stock.any (fun c => c.id == id)) s!"missing stock chain {id}"
    chainsRef.set stock
    -- A chain saved behind the running snapshot (import, another process) is found
    -- in the store before its name is refused.
    let .ok _ ← execParamQuery store.missionsDb
        "INSERT INTO model_routing_chains(id,name,models_json,updated_at) VALUES('late-reviewer','Late','[{\"provider_id\":\"zai\",\"model_id\":\"glm-5.3\"}]','t0');" #[]
      | throw (IO.userError "late chain insert failed")
    attempts.set #[]
    let late ← post "late-reviewer"
    check (late.status == 200 && !(← attempts.get).isEmpty) s!"a chain saved behind the snapshot is served, got {late.status}"
    -- A target that cannot serve the request (unknown model, wrong endpoint, dead login)
    -- hands over to the next target of the SAME chain; nothing has reached the client yet.
    let multi := fun (id : String) (models : Array String) =>
      { chain id id "" with targets := models.map fun m => (chain s!"{id}-{m}" id m).targets[0]! }
    chainsRef.modify fun cs => ((cs.push (multi "fo-recover" #["fail400-a", "fail404-b", "good-c"])).push
      (multi "fo-dead" #["fail400-a", "fail404-b", "fail401-c"])).push (multi "fo-single" #["fail400-a"])
    attempts.set #[]
    let recovered ← post "fo-recover"
    check (recovered.status == 200 && (← attempts.get) == #["fail400-a", "fail404-b", "good-c"])
      s!"a chain fails over past unservable targets: {recovered.status} {← attempts.get}"
    attempts.set #[]
    let dead ← post "fo-dead"
    let deadText := (String.fromUTF8? dead.body).getD ""
    check (dead.status == 502 && (← attempts.get).size == 3 &&
        (deadText.splitOn ("\"targets\":[{\"provider\":\"openai\",\"model\":\"fail400-a\",\"status\":400,\"code\":\"model_not_found\"}," ++
          "{\"provider\":\"openai\",\"model\":\"fail404-b\",\"status\":404,\"code\":\"\"}," ++
          "{\"provider\":\"openai\",\"model\":\"fail401-c\",\"status\":401,\"code\":\"auth_unavailable\"}]")).length == 2)
      s!"an exhausted chain lists each target's failure: {dead.status} {deadText}"
    check ((deadText.splitOn "example.test").length == 1) "upstream messages are not relayed in the failure list"
    -- The refused login is recorded for that upstream account only, and an account
    -- that serves a request is cleared.
    let evidence := fun (key : String) => do
      let .ok rows ← execParamQuery store.missionsDb "SELECT code FROM provider_auth_health WHERE account_key=?1;" #[key]
        | throw (IO.userError "auth health query failed")
      return (rows[1]?.bind (·[0]?))
    check ((← evidence "fo-dead-fail401-c") == some "auth_unavailable" && (← evidence "fo-dead-fail400-a").isNone)
      s!"a refused login is recorded for its account: {← evidence "fo-dead-fail401-c"}"
    discard <| execParamQuery store.missionsDb "INSERT INTO provider_auth_health(account_key,code,observed_at) VALUES('fo-recover-good-c','auth_unavailable','t0');" #[]
    discard <| post "fo-recover"
    check ((← evidence "fo-recover-good-c").isNone) "an account that served a request is no longer marked refused"
    attempts.set #[]
    let single ← post "fo-single"
    check (single.status == 400 && (((String.fromUTF8? single.body).getD "").splitOn "unknown provider for model k3").length == 2)
      s!"a single target keeps the upstream's own answer: {single.status}"

    -- Request each provider adapter sends, as the Rust proxy built it (base URL with its
    -- API version + /chat/completions, JSON content type, bearer key, only `model` rewritten).
    let sent := fun (provider base model : String) =>
      let target := { (chain "a" "a" model).targets[0]! with provider := provider, baseUrl := base, apiKey := "k" }
      let (tls, host, _, path, hdrs, body) := upstreamRequest target
        "/v1/chat/completions" #[] "{\"model\":\"chain-name\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}".toUTF8
      (s!"{if tls then "https" else "http"}://{host}{path}", hdrs, (OrbBin.Json.parse ((String.fromUTF8? body).getD "")).toOption.getD .null)
    for (provider, model, url) in #[
        ("minimax", "MiniMax-M3", "https://api.minimax.io/v1/chat/completions"),
        ("zai", "glm-5.3", "https://api.z.ai/api/coding/paas/v4/chat/completions"),
        ("kimi", "kimi-k3", "https://api.kimi.com/coding/v1/chat/completions"),
        ("cerebras", "zai-glm-4.7", "https://api.cerebras.ai/v1/chat/completions"),
        ("openai", "gpt-6-astra", "https://api.openai.com/v1/chat/completions"),
        ("xai", "grok-4.6", "https://api.x.ai/v1/chat/completions"),
        ("muse", "muse-spark-1.3", "https://api.meta.ai/v1/chat/completions"),
        ("groq", "m", "https://api.groq.com/openai/v1/chat/completions"),
        ("google", "gemini-4-argon", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")] do
      let (gotUrl, hdrs, body) := sent provider (defaultProviderBaseUrl provider) model
      check (gotUrl == url) s!"{provider} upstream URL: {gotUrl}"
      check (hdrs.contains ("Content-Type", "application/json") && hdrs.contains ("Authorization", "Bearer k")) s!"{provider} headers"
      check (body.fieldStr? "model" == some model && ((body.fieldArr? "messages").getD #[]).size == 1) s!"{provider} body keeps messages, names its model"
      check (hdrs.any (fun h => h.1 == "User-Agent") == (provider == "kimi") &&
          ((body.field? "temperature").isSome == (provider == "kimi"))) s!"{provider}: only Kimi's own endpoint gets its CLI agent and temperature"
    check ((sent "custom:lab" "https://llm.example/v1" "m").1 == "https://llm.example/v1/chat/completions") "custom base ending in /v1"
    check ((sent "kimi" "http://127.0.0.1:8317" "kimi-k3").1 == "http://127.0.0.1/v1/chat/completions") "CLIProxy base without a version"
    check (((sent "zai" (defaultProviderBaseUrl "zai") "glm-5.3[1m]").2.2.fieldStr? "model") == some "glm-5.3") "z.ai has no [1m] suffix"
    for (provider, entry, upstream) in #[("kimi", "k3", "kimi-k3"), ("kimi", "kimi-for-coding", "kimi-k3"),
        ("kimi", "kimi-for-coding-highspeed", "kimi-k2.7-code-highspeed"), ("kimi", "kimi-k3.1-pro", "kimi-k3.1-pro"),
        ("xai", "grok-4.6-latest", "grok-4.6"), ("minimax", "MiniMax-M3", "MiniMax-M3")] do
      check (OrbCore.ProxyModelRouting.cliProxyModelId provider entry == upstream) s!"CLIProxy model id for {provider}/{entry}"
    for c in stock do
      let bare := if c.id.startsWith "builtin/" then (c.id.drop 8).toString else c.id
      for alias in #[c.id, bare, s!"builtin/{bare}"] do
        attempts.set #[]
        let response ← post alias
        check (response.status == 200 && !(← attempts.get).isEmpty) s!"stock alias {alias}"

    -- Cooling-chain & unconfigured-chain mission turn termination (`wip/h-cooling-chain-ends-turn`):
    -- When a mission-bound proxy request hits a chain with no eligible target and the soonest
    -- cooling target is > 60s away (or no target is configured at all, 503 `skipped_configuration`),
    -- Core immediately emits one mission `error` event (naming the chain and return time, with
    -- zero account identifiers), stops the running turn via the same entry point user Stop uses,
    -- and leaves the mission in a state (`interrupted`, `terminal_reason = "remote_quota"` or
    -- `"remote_configuration"`) from which a follow-up message starts a new turn.
    let nowT : UInt64 := 1700001000
    let nowIso := formatEpochIso8601Utc nowT
    let coolChain : RoutingChain := {
      id := "cool-test", name := "Cool Test",
      targets := #[{
        accountId := "acct-secret-alice@example.test",
        provider := "openai",
        baseUrl := "http://127.0.0.1:1",
        apiKey := "sk-super-secret-key-999",
        modelId := "gpt-6-astra"
      }]
    }
    let emptyChain : RoutingChain := {
      id := "empty-test", name := "Empty Test",
      targets := #[]
    }
    let sideCoolChain : RoutingChain := {
      id := "side-cool-test", name := "Side Cool Test",
      targets := #[{
        accountId := "acct-secret-alice@example.test",
        provider := "openai",
        baseUrl := "http://127.0.0.1:1",
        apiKey := "sk-super-secret-key-999",
        modelId := "gpt-6-astra"
      }]
    }
    chainsRef.modify fun cs => ((cs.push coolChain).push emptyChain).push sideCoolChain
    let seedRunningMissionWithModel := fun (mid ownerUid modelOverride : String) => do
      let .ok _ ← execParamQuery store.missionsDb
        ("INSERT INTO missions(id,title,status,backend,model_override,working_directory,owner_user_id,run_generation,state_revision,created_at,updated_at) " ++
         "VALUES(?1,?2,'active','opencode',?3,?4,?5,1,1,?6,?6);")
        #[mid, s!"Mission {mid}", modelOverride, root, ownerUid, nowIso]
        | throw (IO.userError s!"seed mission {mid} failed")
      let .ok _ ← execParamQuery store.missionsDb
        ("INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) " ++
         "VALUES(?1,?2,1,'running','','',?3);")
        #[s!"run-{mid}-1", mid, nowIso]
        | throw (IO.userError s!"seed mission_run {mid} failed")
      let .ok mpt ← mintMissionProxyToken store mid ownerUid (nowT + 3600)
        | throw (IO.userError s!"mint proxy token {mid} failed")
      return mpt
    let seedRunningMission := fun (mid ownerUid : String) =>
      seedRunningMissionWithModel mid ownerUid "cool-test"
    let postBoundWithHeader := fun (bearer model : String) (execKey? : Option String) => do
      let body := renderCompact (.obj #[("model", .str model), ("messages", .arr #[])])
      let execHdr := match execKey? with
        | some k => s!"X-Sandboxed-Execution-Key: {k}\r\n"
        | none => ""
      let raw := s!"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {bearer}\r\n{execHdr}Content-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := parseRequest raw.toUTF8 none
        | throw (IO.userError "proxy bound request parse failed")
      let .ok response ← dispatchCoreRequest app req nowT
        | throw (IO.userError "unexpected proxy bound websocket upgrade")
      return response
    let postBound := fun (bearer model : String) =>
      postBoundWithHeader bearer model none
    let readMissionState := fun (mid : String) => do
      let .ok mRows ← execParamQuery store.missionsDb
        "SELECT status, COALESCE(terminal_reason,''), COALESCE(run_generation,1) FROM missions WHERE id=?1;" #[mid]
        | throw (IO.userError "mission state query failed")
      let st := (mRows[1]?.bind (·[0]?)).getD ""
      let tr := (mRows[1]?.bind (·[1]?)).getD ""
      let gen := ((mRows[1]?.bind (·[2]?)).bind String.toNat?).getD 0
      let .ok rRows ← execParamQuery store.missionsDb
        "SELECT COUNT(*) FROM mission_runs WHERE mission_id=?1 AND execution_state NOT IN ('terminal','completed','failed','aborted');" #[mid]
        | throw (IO.userError "mission live runs query failed")
      let liveRuns := ((rRows[1]?.bind (·[0]?)).bind String.toNat?).getD 0
      let .ok eRows ← execParamQuery store.missionsDb
        "SELECT payload FROM mission_events WHERE mission_id=?1 AND event_type='error' ORDER BY seq ASC;" #[mid]
        | throw (IO.userError "mission error events query failed")
      let errs := (eRows.drop 1).map (fun r => (r[0]?).getD "")
      return (st, tr, gen, liveRuns, errs)

    let tok1 ← seedRunningMission "m-cool-2400" ""
    let _tokOther ← seedRunningMission "m-other-member" "user-other"
    -- (i) All-cooling chain, 2400 seconds left: mission gets one `error` event, turn is no longer
    -- running, status='interrupted' and terminal_reason='remote_quota', no account identifier in text.
    cooldowns.set #[{
      accountId := "acct-secret-alice@example.test",
      untilEpoch := nowT + 2400,
      reason := .usageLimit,
      label := "acct-secret-alice@example.test"
    }]
    let r2400 ← postBound tok1 "cool-test"
    check (r2400.status == 429) s!"2400s cooling proxy status: {r2400.status}"
    let (st1, tr1, gen1, live1, errs1) ← readMissionState "m-cool-2400"
    check (errs1.size == 1 && live1 == 0 && st1 == "interrupted" && tr1 == "remote_quota" && gen1 == 2)
      s!"(i) 2400s cooling chain must emit 1 error event and stop turn with interrupted/remote_quota: errs={errs1.size} live={live1} status={st1} reason={tr1} gen={gen1}"
    let errText1 := errs1[0]?.getD ""
    check ((errText1.splitOn "cool-test").length > 1 &&
           ((errText1.splitOn "2400").length > 1 || (errText1.splitOn "40m").length > 1 || (errText1.splitOn (formatEpochIso8601Utc (nowT + 2400))).length > 1) &&
           (errText1.splitOn "acct-secret").length == 1 &&
           (errText1.splitOn "alice@example.test").length == 1 &&
           (errText1.splitOn "sk-super-secret").length == 1)
      s!"(i) error event must name chain and return time without account identifiers: {errText1}"

    -- (ii) Same turn, second request: still one event and no second cancel/generation bump.
    let r2400Again ← postBound tok1 "cool-test"
    check (r2400Again.status == 429) s!"second 2400s cooling status: {r2400Again.status}"
    let (st2, tr2, gen2, live2, errs2) ← readMissionState "m-cool-2400"
    check (errs2.size == 1 && live2 == 0 && st2 == "interrupted" && tr2 == "remote_quota" && gen2 == 2)
      s!"(ii) second request from same stopped turn must not add a second event or cancel: errs={errs2.size} gen={gen2}"

    -- (v) Another member's mission is untouched.
    let (stOther, trOther, genOther, liveOther, errsOther) ← readMissionState "m-other-member"
    check (stOther == "active" && trOther == "" && genOther == 1 && liveOther == 1 && errsOther.isEmpty)
      s!"(v) another member's mission must remain untouched: status={stOther} reason={trOther} gen={genOther} live={liveOther} errs={errsOther.size}"

    -- (iii) 30 seconds left: no event, mission still running.
    let tokShort ← seedRunningMission "m-cool-30" ""
    cooldowns.set #[{
      accountId := "acct-secret-alice@example.test",
      untilEpoch := nowT + 30,
      reason := .rateLimit,
      label := ""
    }]
    let r30 ← postBound tokShort "cool-test"
    check (r30.status == 429) s!"30s cooling proxy status: {r30.status}"
    let (st30, tr30, gen30, live30, errs30) ← readMissionState "m-cool-30"
    check (errs30.isEmpty && live30 == 1 && st30 == "active" && tr30 == "" && gen30 == 1)
      s!"(iii) <=60s wait must leave mission running with no error event: errs={errs30.size} live={live30} status={st30}"

    -- (iv) Unbound caller: reply bytes unchanged, no event anywhere.
    cooldowns.set #[{
      accountId := "acct-secret-alice@example.test",
      untilEpoch := nowT + 2400,
      reason := .rateLimit,
      label := ""
    }]
    let .ok evBeforeRows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM mission_events;" #[]
      | throw (IO.userError "count mission_events before unbound failed")
    let evBefore := ((evBeforeRows[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    let rUnbound ← post "cool-test"
    let expectedUnbound := cooldownReply "cool-test" 2400
    let .ok evAfterRows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM mission_events;" #[]
      | throw (IO.userError "count mission_events after unbound failed")
    let evAfter := ((evAfterRows[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    check (rUnbound.status == expectedUnbound.status &&
           String.fromUTF8? rUnbound.body == some expectedUnbound.body &&
           evAfter == evBefore)
      s!"(iv) unbound caller reply bytes and event count must be unchanged: status={rUnbound.status} evBefore={evBefore} evAfter={evAfter}"

    -- 503 `skipped_configuration` (nothing eligible, nothing cooling) on a mission-bound request:
    -- gets the same treatment with an error event saying the chain has no configured target.
    cooldowns.set #[]
    let tokEmpty ← seedRunningMissionWithModel "m-empty-chain" "" "empty-test"
    let rEmpty ← postBound tokEmpty "empty-test"
    check (rEmpty.status == 503) s!"empty chain status: {rEmpty.status}"
    let (stEmp, trEmp, genEmp, liveEmp, errsEmp) ← readMissionState "m-empty-chain"
    check (errsEmp.size == 1 && liveEmp == 0 && stEmp == "interrupted" && trEmp == "remote_configuration" && genEmp == 2)
      s!"503 skipped_configuration must emit 1 error event and stop turn with interrupted/remote_configuration: errs={errsEmp.size} live={liveEmp} status={stEmp} reason={trEmp} gen={genEmp}"
    let errTextEmp := errsEmp[0]?.getD ""
    check ((errTextEmp.splitOn "empty-test").length > 1 && (errTextEmp.splitOn "no configured target").length > 1)
      s!"503 skipped_configuration error event must name chain and say it has no configured target: {errTextEmp}"

    -- Point 1 (proven per-mission proxy token):
    -- (1a) Token of mission A + X-Sandboxed-Execution-Key header naming running mission B + cooling chain:
    -- B stays active, no error event on B.
    cooldowns.set #[{
      accountId := "acct-secret-alice@example.test",
      untilEpoch := nowT + 2400,
      reason := .usageLimit,
      label := "acct-secret-alice@example.test"
    }]
    let tokA ← seedRunningMission "m-pt1-caller-a" ""
    let _tokB ← seedRunningMission "m-pt1-victim-b" ""
    let rSpoofFromA ← postBoundWithHeader tokA "cool-test" (some "remote-launch:m-pt1-victim-b")
    check (rSpoofFromA.status == 429) s!"(1a) spoof from A status: {rSpoofFromA.status}"
    let (stB1, trB1, genB1, liveB1, errsB1) ← readMissionState "m-pt1-victim-b"
    check (stB1 == "active" && trB1 == "" && genB1 == 1 && liveB1 == 1 && errsB1.isEmpty)
      s!"(1a) token of A with header naming B must leave B active with 0 errors: status={stB1} reason={trB1} gen={genB1} live={liveB1} errs={errsB1.size}"

    -- (1b) Global proxy secret + X-Sandboxed-Execution-Key header naming running mission B + cooling chain:
    -- B stays active, no error event on B.
    let _tokB2 ← seedRunningMission "m-pt1-victim-b2" ""
    let rSpoofGlobal ← postBoundWithHeader cfg.proxySecret "cool-test" (some "remote-launch:m-pt1-victim-b2")
    check (rSpoofGlobal.status == 429) s!"(1b) spoof with global proxy secret status: {rSpoofGlobal.status}"
    let (stB2, trB2, genB2, liveB2, errsB2) ← readMissionState "m-pt1-victim-b2"
    check (stB2 == "active" && trB2 == "" && genB2 == 1 && liveB2 == 1 && errsB2.isEmpty)
      s!"(1b) global proxy secret with header naming B2 must leave B2 active with 0 errors: status={stB2} reason={trB2} gen={genB2} live={liveB2} errs={errsB2.size}"

    -- (1c) Token of B + header naming B: B is stopped as today.
    let tokB3 ← seedRunningMission "m-pt1-valid-b3" ""
    let rValidB ← postBoundWithHeader tokB3 "cool-test" (some "remote-launch:m-pt1-valid-b3")
    check (rValidB.status == 429) s!"(1c) valid token B3 + matching header B3 status: {rValidB.status}"
    let (stB3, trB3, genB3, liveB3, errsB3) ← readMissionState "m-pt1-valid-b3"
    check (errsB3.size == 1 && liveB3 == 0 && stB3 == "interrupted" && trB3 == "remote_quota" && genB3 == 2)
      s!"(1c) token of B3 with matching header B3 must stop B3: status={stB3} reason={trB3} gen={genB3} live={liveB3} errs={errsB3.size}"

    -- Point 2 (wrong chain — side calls on another model must not stop the turn):
    -- Mission's own stored model is `cool-test`, but it makes a side call on `side-cool-test` which is cooling.
    let tokSide ← seedRunningMissionWithModel "m-pt2-side-chain" "" "cool-test"
    let rSide ← postBound tokSide "side-cool-test"
    check (rSide.status == 429) s!"(2) side chain cooling status: {rSide.status}"
    let (stSide, trSide, genSide, liveSide, errsSide) ← readMissionState "m-pt2-side-chain"
    check (stSide == "active" && trSide == "" && genSide == 1 && liveSide == 1 && errsSide.isEmpty)
      s!"(2) side-call on a different cooling chain must not stop mission turn: status={stSide} reason={trSide} gen={genSide} live={liveSide} errs={errsSide.size}"

    -- Point 3 (non-quota cooldown reason label and message):
    -- When the soonest cooldown is `.overloaded` / `.serverError` / `.authFailure` (not `.rateLimit` or `.usageLimit`),
    -- `terminal_reason` is `"provider_unavailable"` (not `"remote_quota"`) and the `error` event says the provider
    -- is unavailable while naming the chain and return time with zero account identifiers.
    cooldowns.set #[{
      accountId := "acct-secret-alice@example.test",
      untilEpoch := nowT + 2400,
      reason := .overloaded,
      label := "acct-secret-alice@example.test"
    }]
    let tokNonQuota ← seedRunningMission "m-pt3-overloaded" ""
    let rNonQuota ← postBound tokNonQuota "cool-test"
    check (rNonQuota.status == 429) s!"(3) overloaded cooling status: {rNonQuota.status}"
    let (stNq, trNq, genNq, liveNq, errsNq) ← readMissionState "m-pt3-overloaded"
    let errTextNq := errsNq[0]?.getD ""
    check (errsNq.size == 1 && liveNq == 0 && stNq == "interrupted" && trNq == "provider_unavailable" && genNq == 2 &&
           (errTextNq.splitOn "Provider is unavailable").length > 1 &&
           (errTextNq.splitOn "cool-test").length > 1 &&
           (errTextNq.splitOn "2400").length > 1 &&
           (errTextNq.splitOn "acct-secret").length == 1 &&
           (errTextNq.splitOn "alice@example.test").length == 1)
      s!"(3) non-quota cooldown must set terminal_reason=provider_unavailable and say provider is unavailable: status={stNq} reason={trNq} errs={errsNq.size} text={errTextNq}"
  finally
    closeCoreStore store
    IO.FS.removeDirAll root

end OrbCore.ProxyRoutingTests
