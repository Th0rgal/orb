import LeanSys
import OrbNetLeaf.TlsHttp
import OrbNetLeaf.Gzip
import OrbNetLeaf.H2Pool
import OrbBin.Json
import OrbLocald.Spec
import OrbLocald.Rpc

/-
  OrbLocald.CliMain — `orb-locald` loopback RPC & transport bridge daemon.
  - Strictly validates `ORB_LOCALD_TOKEN` (≥ 32-byte non-placeholder per-launch secret) and `ORB_LOCALD_PORT` (`1024..65535`).
  - Uses `LeanSys.Http.readHttpRequestFromFd` for smuggling-safe, looped Content-Length framing.
  - Never emits `Access-Control-Allow-Origin: *`; echoes only verified loopback/local shell `Origin`s.
  - Binds live loopback listeners for the RPC socket, the primary `/__orb_tx/<uuid>` proxy, and all 6 SSE shard sockets,
    answering `OPTIONS` preflights in 0ms and forwarding `/__orb_tx/<uuid>/...` across `failoverOrigins` gated by `canFailoverRequest`.
-/

open LeanSys.Posix
open LeanSys.Http
open OrbNetLeaf.TlsHttp
open OrbBin.Json
open OrbLocald.Spec
open OrbLocald.Rpc

private def findHeaderVal? (hdrs : Array (String × String)) (lowerKey : String) : Option String := do
  let (_, v) ← hdrs.find? fun (k, _) => k.trimAscii.toString.toLower == lowerKey
  let tv := v.trimAscii.toString
  if tv.isEmpty then none else some tv

private def corsExposeHeadersLine : String :=
  "Access-Control-Expose-Headers: X-Orb-Events-Protocol, X-Has-More, X-Next-Cursor, X-Page-Max-Sequence, X-Max-Sequence, X-Orb-Upstream, X-Orb-Idempotent-Replay, Content-Type, Content-Disposition, Retry-After, X-Request-Id, X-Orb-Transport-Rtt-Ms, X-Orb-Upstream-Origin\r\n"

private def corsAllowHeadersLine : String :=
  "Access-Control-Allow-Headers: Content-Type, Authorization, Accept, Accept-Encoding, Cache-Control, Last-Event-ID, Idempotency-Key, X-Orb-Token, X-Orb-Target, X-Orb-Priority, X-Paloma-Approval, X-Language\r\n"

private def corsHeaderBlock (origin? : Option String) : String :=
  match origin? with
  | none => ""
  | some raw =>
    let o := raw.trimAscii.toString
    if !o.isEmpty && isAllowedLocaldOrigin (some o) then
      s!"Access-Control-Allow-Origin: {o}\r\nVary: Origin\r\n" ++ corsExposeHeadersLine
    else
      ""

private def sendJsonHttp (fd : Fd) (status : Nat) (origin? : Option String) (jsonPayload : String)
    (keepAlive : Bool := false) : IO Bool := do
  let reason := HttpResponse.reasonPhrase status
  let body := jsonPayload.toUTF8
  let connHdr := if keepAlive then "Connection: keep-alive\r\nKeep-Alive: timeout=10\r\n\r\n" else "Connection: close\r\n\r\n"
  let head :=
    s!"HTTP/1.1 {status} {reason}\r\n" ++
    corsHeaderBlock origin? ++
    "Content-Type: application/json\r\n" ++
    s!"Content-Length: {body.size}\r\n" ++
    connHdr
  match ← writeAll fd (head.toUTF8 ++ body) false with
  | .ok _ => return true
  | .error _ => return false

private def sendPreflight204 (fd : Fd) (origin? : Option String) (keepAlive : Bool := false) : IO Bool := do
  let connHdr := if keepAlive then "Connection: keep-alive\r\nKeep-Alive: timeout=10\r\n\r\n" else "Connection: close\r\n\r\n"
  let head :=
    "HTTP/1.1 204 No Content\r\n" ++
    corsHeaderBlock origin? ++
    "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS\r\n" ++
    corsAllowHeadersLine ++
    "Access-Control-Max-Age: 86400\r\n" ++
    "Content-Length: 0\r\n" ++
    connHdr
  match ← writeAll fd head.toUTF8 false with
  | .ok _ => return true
  | .error _ => return false

private def isHopByHopHeader (name : String) : Bool :=
  let low := name.trimAscii.toString.toLower
  low == "host" || low == "connection" || low == "content-length" ||
  low == "transfer-encoding" || low == "keep-alive" || low == "upgrade" ||
  low == "proxy-connection" || low.startsWith "access-control-"

private def isStrippedClientHeader (name : String) : Bool :=
  let low := name.trimAscii.toString.toLower
  isHopByHopHeader low || low == "origin" || low == "referer" ||
  low == "x-orb-target" || low.startsWith "sec-"

private def isHeaderValueClean (s : String) : Bool :=
  !LeanSys.Http.hasHttpFieldControlByte s &&
  !(s.toList.any (fun c => c == '\r' || c == '\n' || c.toNat == 0))

private def sanitizeUpstreamHeaders (hdrs : Array (String × String)) (stripContentEncoding : Bool := false) : String := Id.run do
  let mut out := ""
  for (k, v) in hdrs do
    let tk := k.trimAscii.toString
    let tv := v.trimAscii.toString
    let low := tk.toLower
    if !tk.isEmpty && LeanSys.Http.isHttpToken tk && !isHopByHopHeader tk &&
       low != "content-type" && low != "vary" &&
       (!stripContentEncoding || low != "content-encoding") &&
       isHeaderValueClean tv then
      out := out ++ s!"{tk}: {tv}\r\n"
  return out

private def isSseStreamRequest (isShardPort : Bool) (req : HttpRequest) : Bool :=
  if isShardPort && req.method.toUpper == "GET" then true
  else
    let acc := (findHeaderVal? req.headers "accept").getD ""
    acc.toLower.splitOn "text/event-stream" |>.length > 1

/-- Stream Server-Sent Events and shard-port `GET` responses directly over a verified native OpenSSL
    WebPKI TLS 1.3/1.2 session (`openHttps11Stream`, zero external `curl` subprocesses), transparently
    de-chunking `Transfer-Encoding: chunked`, honoring `Content-Length`, and clearing `SO_RCVTIMEO`
    after response headers arrive so long-lived SSE keepalive intervals (>30s) never drop. -/
private def streamSseNativeTls (fd : Fd) (origin? : Option String)
    (host : String) (port : UInt16) (path method : String)
    (fwdHdrs : Array (String × String)) : IO Bool := do
  let cleanHdrs := fwdHdrs.filter fun (hk, hv) =>
    !hk.isEmpty && LeanSys.Http.isHttpToken hk && isHeaderValueClean hv
  let sess ← match ← openHttps11Stream method host port path cleanHdrs ByteArray.empty true 10000 with
    | .ok s => pure s
    | .error _ => return false
  let mut hdrAcc := ByteArray.empty
  let mut headerSent := false
  let mut isChunked := false
  let mut chunkState : ChunkedStreamState := .readSizeLine ByteArray.empty
  let mut remContentLen? : Option Nat := none
  let mut idleCleared := false
  let mut aborted := false
  let mut eof := false
  try
    while !eof && !aborted do
      let rcvTmo : UInt32 :=
        if headerSent && !idleCleared then 0xFFFFFFFF else 0
      if rcvTmo == 0xFFFFFFFF then
        idleCleared := true
      match ← readTlsSessionChunk sess 4096 rcvTmo with
      | .closeNotify | .tcpEof =>
        eof := true
      | .timeout | .transportError =>
        aborted := true
      | .chunk chunk =>
        if chunk.isEmpty then
          eof := true
        else if !headerSent then
          hdrAcc := hdrAcc ++ chunk
          match extractStreamingResponseHeadEx? hdrAcc with
          | .error _ =>
            aborted := true
          | .ok none =>
            pure ()
          | .ok (some (statusNat, parsedHdrs, chunkedFlag, cl?, bodyTail)) =>
            if statusNat == 429 || (500 ≤ statusNat && statusNat ≤ 599) then
              aborted := true
            else
              isChunked := chunkedFlag
              remContentLen? := cl?
              let ctype := (findHeaderVal? parsedHdrs "content-type").getD "text/event-stream"
              let extra := sanitizeUpstreamHeaders parsedHdrs
              let reason := HttpResponse.reasonPhrase statusNat
              let outHead :=
                s!"HTTP/1.1 {statusNat} {reason}\r\n" ++
                corsHeaderBlock origin? ++
                s!"Content-Type: {ctype}\r\n" ++
                "Cache-Control: no-cache\r\n" ++
                extra ++
                "Connection: close\r\n\r\n"
              if isChunked then
                match stepChunkedStream chunkState bodyTail with
                | .error _ =>
                  aborted := true
                | .ok (decTail, st', doneFlag) =>
                  chunkState := st'
                  match ← writeAll fd (outHead.toUTF8 ++ decTail) false with
                  | .ok _ =>
                    headerSent := true
                    if doneFlag then eof := true
                  | .error _ => eof := true
              else
                let initBody :=
                  match remContentLen? with
                  | some cl =>
                    let take := Nat.min cl bodyTail.size
                    bodyTail.extract 0 take
                  | none => bodyTail
                if let some cl := remContentLen? then
                  let rem := cl - initBody.size
                  remContentLen? := some rem
                  if rem == 0 then eof := true
                match ← writeAll fd (outHead.toUTF8 ++ initBody) false with
                | .ok _ => headerSent := true
                | .error _ => eof := true
        else if isChunked then
          match stepChunkedStream chunkState chunk with
          | .error _ => eof := true
          | .ok (decBytes, st', doneFlag) =>
            chunkState := st'
            if !decBytes.isEmpty then
              match ← writeAll fd decBytes false with
              | .ok _ => pure ()
              | .error _ => eof := true
            if doneFlag then
              eof := true
        else
          let outPayload :=
            match remContentLen? with
            | some rem => chunk.extract 0 (Nat.min rem chunk.size)
            | none => chunk
          if let some rem := remContentLen? then
            let nextRem := rem - outPayload.size
            remContentLen? := some nextRem
            if nextRem == 0 then eof := true
          if !outPayload.isEmpty then
            match ← writeAll fd outPayload false with
            | .ok _ => pure ()
            | .error _ => eof := true
  finally
    closeTlsSession sess
  return headerSent

private def handleTransportProxyRequest (stRef : IO.Ref LocaldState) (isShardPort : Bool) (fd : Fd) (req : HttpRequest) (origin? : Option String) (keepAlive : Bool := false) : IO Bool := do
  let st ← stRef.get
  let expectedPfx := s!"/__orb_tx/{st.bridge.bridgeUuid}"
  if !req.path.startsWith expectedPfx then
    sendJsonHttp fd 403 origin? "{\"error\":\"invalid_bridge_token\"}" keepAlive
  else if req.method == "OPTIONS" then
    sendPreflight204 fd origin? keepAlive
  else
    let rawRel := (req.path.drop expectedPfx.length).toString
    let relPath := if rawRel.isEmpty then "/" else if rawRel.startsWith "/" then rawRel else "/" ++ rawRel
    let hasIdem := (findHeaderVal? req.headers "idempotency-key").isSome
    let explicitPrio? := findHeaderVal? req.headers "x-orb-priority"
    let prio := classifyProxyRequestPriority req.method relPath explicitPrio?
    let baseFwdHdrs := req.headers.filter fun (k, _) =>
      let low := k.trimAscii.toString.toLower
      !isStrippedClientHeader k && low != "x-orb-priority"
    let reqBody := req.bodySlice.toByteArray
    let targetHdr := (findHeaderVal? req.headers "x-orb-target").getD ""
    let baseOrigins :=
      if !targetHdr.isEmpty then candidateOriginsFor targetHdr
      else st.bridge.failoverOrigins
    let nowInitMs ← IO.monoMsNow
    let origins := rankFailoverOrigins baseOrigins st.originHealth nowInitMs
    let wantSse := isSseStreamRequest isShardPort req && reqBody.isEmpty
    if origins.isEmpty then
      sendJsonHttp fd 503 origin? "{\"error\":\"no_failover_origins\"}" keepAlive
    else
      let mut idx : Nat := 0
      let mut done := false
      let mut canReuse := false
      while idx < origins.size && !done do
        let orig := origins[idx]!
        if wantSse then
          match parseOriginHostPort orig with
          | some (true, host, port, pfx) =>
            let t0 ← IO.monoMsNow
            if (← streamSseNativeTls fd origin? host port (pfx ++ relPath) req.method baseFwdHdrs) then
              let t1 ← IO.monoMsNow
              discard <| recordOriginSuccess stRef orig (Nat.min (Nat.max 1 (t1 - t0)) 60000).toUInt32
              done := true
            else
              let tFail ← IO.monoMsNow
              recordOriginFailure stRef orig tFail
              if canFailoverRequest req.method hasIdem (idx + 1) origins then
                idx := idx + 1
              else
                discard <| sendJsonHttp fd 502 origin? "{\"error\":\"upstream_stream_unreachable\"}" false
                done := true
          | _ =>
            if canFailoverRequest req.method hasIdem (idx + 1) origins then
              idx := idx + 1
            else
              discard <| sendJsonHttp fd 502 origin? "{\"error\":\"invalid_stream_origin\"}" false
              done := true
        else
          let isLongProvision :=
            req.method.toUpper == "POST" &&
            (relPath == "/api/control/missions" || relPath.startsWith "/api/control/missions?" ||
             relPath == "/api/managed-machines" || relPath.startsWith "/api/managed-machines?" ||
             relPath.startsWith "/api/managed-machines/")
          let upTimeoutMs : UInt32 := if isLongProvision then 540000 else 65000
          let connTimeoutMs : UInt32 := if origins.size > 1 && idx + 1 < origins.size then 6000 else 12000
          let hasAcceptEnc := (findHeaderVal? baseFwdHdrs "accept-encoding").isSome
          let fwdHdrs :=
            if hasAcceptEnc then baseFwdHdrs
            else baseFwdHdrs.push ("Accept-Encoding", "gzip")
          let attemptRes ← match parseOriginHostPort orig with
            | none => pure (.error "invalid_origin")
            | some (true, host, port, pfx) =>
              match st.h2Pool? with
              | some pool =>
                pool.request prio req.method host port (pfx ++ relPath) fwdHdrs reqBody maxLocaldProxyBodyBytes true connTimeoutMs upTimeoutMs
              | none =>
                let t0 ← IO.monoMsNow
                match ← httpsRequest req.method host port (pfx ++ relPath) fwdHdrs reqBody maxLocaldProxyBodyBytes true upTimeoutMs with
                | .ok up =>
                  let t1 ← IO.monoMsNow
                  pure (.ok { response := up, rttMs := (Nat.min (Nat.max 1 (t1 - t0)) 60000).toUInt32, reusedConn := false })
                | .error e => pure (.error e)
            | some (false, _, _, _) =>
              pure (.error "plaintext_origin_rejected")
          match attemptRes with
          | .ok pooled =>
            let up := pooled.response
            let retryStatus := up.status == 429 || (500 ≤ up.status && up.status ≤ 599)
            if retryStatus then
              let tFail ← IO.monoMsNow
              recordOriginFailure stRef orig tFail
            if retryStatus && canFailoverRequest req.method hasIdem (idx + 1) origins then
              idx := idx + 1
            else
              let isComputeBound := isComputeBoundProxyRequest req.method relPath
              let srtt ←
                if retryStatus then
                  pure pooled.rttMs
                else if isComputeBound then
                  let curSt ← stRef.get
                  let cappedRtt : UInt32 := if pooled.rttMs < 400 then pooled.rttMs else 400
                  match curSt.originHealth.find? (fun h => h.origin == orig) with
                  | some h => pure (if h.srttMs > 0 then h.srttMs else cappedRtt)
                  | none => pure cappedRtt
                else
                  recordOriginSuccess stRef orig pooled.rttMs
              let encVal := ((findHeaderVal? up.headers "content-encoding").getD "").trimAscii.toString.toLower
              let isGzip := (encVal == "gzip" || encVal == "x-gzip") && req.method.toUpper != "HEAD"
              let decodedRes : Except String (ByteArray × Bool) :=
                if isGzip && !up.body.isEmpty then
                  match OrbNetLeaf.Gzip.gunzipBounded up.body maxLocaldProxyBodyBytes with
                  | .ok plain => .ok (plain, true)
                  | .error e => .error e
                else if isGzip && up.body.isEmpty then
                  .ok (ByteArray.empty, true)
                else
                  .ok (up.body, false)
              match decodedRes with
              | .error _ =>
                let tFail ← IO.monoMsNow
                recordOriginFailure stRef orig tFail
                if canFailoverRequest req.method hasIdem (idx + 1) origins then
                  idx := idx + 1
                else
                  let sent ← sendJsonHttp fd 502 origin? "{\"error\":\"upstream_invalid_gzip\"}" keepAlive
                  canReuse := keepAlive && sent
                  done := true
              | .ok (finalBody, strippedEnc) =>
                let ctype := (findHeaderVal? up.headers "content-type").getD "application/json"
                let extra := sanitizeUpstreamHeaders up.headers strippedEnc
                let cleanOrig := if isHeaderValueClean orig then orig else "https://orb"
                let reason := HttpResponse.reasonPhrase up.status
                let connHdr := if keepAlive then "Connection: keep-alive\r\nKeep-Alive: timeout=10\r\n\r\n" else "Connection: close\r\n\r\n"
                let head :=
                  s!"HTTP/1.1 {up.status} {reason}\r\n" ++
                  corsHeaderBlock origin? ++
                  s!"Content-Type: {ctype}\r\n" ++
                  s!"X-Orb-Transport-Rtt-Ms: {srtt}\r\n" ++
                  s!"X-Orb-Upstream-Origin: {cleanOrig}\r\n" ++
                  extra ++
                  s!"Content-Length: {finalBody.size}\r\n" ++
                  connHdr
                match ← writeAll fd (head.toUTF8 ++ finalBody) false with
                | .ok _ =>
                  canReuse := keepAlive
                  if let some (imm, limOnly) := shouldTriggerOmarchySyncForProxy req.method relPath up.status then
                    triggerOmarchyAgentSync stRef imm limOnly
                | .error _ => canReuse := false
                done := true
          | .error _ =>
            let tFail ← IO.monoMsNow
            recordOriginFailure stRef orig tFail
            if canFailoverRequest req.method hasIdem (idx + 1) origins then
              idx := idx + 1
            else
              let sent ← sendJsonHttp fd 502 origin? "{\"error\":\"upstream_unreachable\"}" keepAlive
              canReuse := keepAlive && sent
              done := true
      return canReuse

private def handleClientConnection (stRef : IO.Ref LocaldState) (portIdx : Nat) (clientFd : Fd) : IO Unit := do
  try
    let isProxyPort := portIdx > 0
    let mut keepLoop := true
    let mut carry := ByteArray.empty
    let mut reqCount : Nat := 0
    while keepLoop && reqCount < 1024 do
      let tmo : UInt32 := if reqCount == 0 then 10000 else 25000
      match ← readLocaldHttpRequestFromFd clientFd carry isProxyPort tmo with
      | .error "empty_socket_read" =>
        keepLoop := false
      | .error errMsg =>
        let code := statusForParseError errMsg
        discard <| sendJsonHttp clientFd code none (renderCompact (.obj #[("error", .str errMsg)])) false
        keepLoop := false
      | .ok (req, remBytes) =>
        reqCount := reqCount + 1
        carry := remBytes
        let origin? := findHeaderVal? req.headers "origin"
        if !isAllowedLocaldOrigin origin? then
          discard <| sendJsonHttp clientFd 403 none "{\"error\":\"forbidden_origin\"}" false
          keepLoop := false
        else
          let connHdr := ((findHeaderVal? req.headers "connection").getD "").toLower
          let clientWantsClose := req.version == "HTTP/1.0" || ((connHdr.splitOn "close").length > 1)
          let keepAlive := !clientWantsClose
          let st ← stRef.get
          if isProxyPort || req.path.startsWith "/__orb_tx/" then
            let sent ← handleTransportProxyRequest stRef (portIdx ≥ 2) clientFd req origin? keepAlive
            keepLoop := keepAlive && sent
          else if req.method == "OPTIONS" && (req.path == "/__orb_rpc" || req.path == "/__orb_events") then
            let sent ← sendPreflight204 clientFd origin? keepAlive
            keepLoop := keepAlive && sent
          else if req.method == "GET" && req.path == "/__orb_events" then
            let provided := (findHeaderVal? req.headers "x-orb-token").getD ""
            if !checkRpcAuth "127.0.0.1" provided st.launchToken then
              discard <| sendJsonHttp clientFd 401 origin? "{\"error\":\"unauthorized\"}" false
            else
              streamLocalEventsSse stRef clientFd origin?
            keepLoop := false
          else if req.method != "POST" || req.path != "/__orb_rpc" then
            discard <| sendJsonHttp clientFd 404 origin? "{\"error\":\"not_found\"}" false
            keepLoop := false
          else
            let provided := (findHeaderVal? req.headers "x-orb-token").getD ""
            if !checkRpcAuth "127.0.0.1" provided st.launchToken then
              discard <| sendJsonHttp clientFd 401 origin? "{\"error\":\"unauthorized\"}" false
              keepLoop := false
            else
              let bodyStr := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
              match OrbBin.Json.parse bodyStr with
              | .error e =>
                let sent ← sendJsonHttp clientFd 400 origin? (renderCompact (.obj #[("error", .str e)])) keepAlive
                keepLoop := keepAlive && sent
              | .ok jv =>
                let cmd := (jv.fieldStr? "command").getD ""
                let cargs := (jv.field? "args").getD (.obj #[])
                let out ← dispatchRpcCommand stRef cmd cargs
                match out with
                | .ok res =>
                  let sent ← sendJsonHttp clientFd 200 origin? (renderCompact (.obj #[("result", res)])) keepAlive
                  keepLoop := keepAlive && sent
                | .error msg =>
                  let sent ← sendJsonHttp clientFd 400 origin? (renderCompact (.obj #[("error", .str msg)])) keepAlive
                  keepLoop := keepAlive && sent
  finally
    discard <| closeFd clientFd

partial def acceptMuxLoop (stRef : IO.Ref LocaldState) (rpcFd : Fd) (proxyFds : Array Fd)
    (parentPid? : Option Int64 := none) (tick : Nat := 0) : IO UInt32 := do
  if (← OrbBin.PosixExt.pollTermTrap) != 0 then
    discard <| closeFd rpcFd
    for pfd in proxyFds do discard <| closeFd pfd
    return 0
  if tick ≥ 8 then
    if (← shouldExitForDeadParent parentPid? stRef) then
      discard <| closeFd rpcFd
      for pfd in proxyFds do discard <| closeFd pfd
      return 0
  let nextTick := if tick ≥ 8 then 0 else tick + 1
  let allFds := #[rpcFd] ++ proxyFds
  match ← pollFdSet allFds 250 0 with
  | .ok readyIdxs =>
    for idx in readyIdxs do
      if h : idx < allFds.size then
        let lfd := allFds[idx]
        match ← tcpAcceptPoll lfd 10 with
        | .ok cfd =>
          discard <| IO.asTask (prio := .dedicated) (handleClientConnection stRef idx cfd)
        | .error _ => pure ()
  | .error _ => pure ()
  acceptMuxLoop stRef rpcFd proxyFds parentPid? nextTick

private def detectHostOs : IO String := do
  if (← System.FilePath.pathExists "/System/Library/CoreServices/SystemVersion.plist") then
    return "macos"
  return "linux"

private def bindLoopbackPortPool (baseHint : UInt16) : IO (Except String (Fd × UInt16 × Array Fd × Array UInt16)) := do
  -- Prefer a contiguous block `p, p+1 .. p+6` so `verifySseShardConfig` (`proxyPort + 6 <= 65535`) holds cleanly.
  let candidates : Array UInt16 := #[baseHint, 29480, 39480, 49480]
  for base in candidates do
    if base ≥ 1024 && base.toNat + 6 ≤ 65535 then
      match ← tcpListen "127.0.0.1" base 64 with
      | .error _ => pure ()
      | .ok (pFd, pPort) =>
        let mut sFds : Array Fd := #[]
        let mut sPorts : Array UInt16 := #[]
        let mut okAll := true
        for off in [1:7] do
          if okAll then
            let sp : UInt16 := (pPort.toNat + off).toUInt16
            match ← tcpListen "127.0.0.1" sp 64 with
            | .ok (sfd, boundSp) =>
              sFds := sFds.push sfd
              sPorts := sPorts.push boundSp
            | .error _ =>
              okAll := false
        if okAll && sPorts.size == 6 then
          return .ok (pFd, pPort, sFds, sPorts)
        else
          for sfd in sFds do discard <| closeFd sfd
          discard <| closeFd pFd
  -- Fallback: bind ephemeral OS-assigned loopback ports (`127.0.0.1:0`) if fixed ranges are busy.
  match ← tcpListen "127.0.0.1" 0 64 with
  | .error e => return .error s!"failed to bind proxy port: {e}"
  | .ok (pFd, pPort) =>
    if pPort.toNat + 6 > 65535 then
      discard <| closeFd pFd
      return .error s!"ephemeral proxy port {pPort} too close to 65535"
    let mut sFds : Array Fd := #[]
    let mut sPorts : Array UInt16 := #[]
    for _ in [0:6] do
      match ← tcpListen "127.0.0.1" 0 64 with
      | .ok (sfd, sp) =>
        sFds := sFds.push sfd
        sPorts := sPorts.push sp
      | .error e =>
        for x in sFds do discard <| closeFd x
        discard <| closeFd pFd
        return .error s!"failed to bind SSE shard port: {e}"
    return .ok (pFd, pPort, sFds, sPorts)

def main (args : List String) : IO UInt32 := do
  if args.contains "--version" then
    IO.println "orb-locald 0.13.0 (Lean 4)"
    return 0
  if args.contains "--print-init-script" then
    IO.print (renderWebviewInitScript 19479 "0123456789abcdef0123456789abcdef")
    return 0
  let portStr := ((← IO.getEnv "ORB_LOCALD_PORT").getD "19479").trimAscii.toString
  let some portNat := portStr.toNat?
    | do IO.eprintln s!"orb-locald: invalid ORB_LOCALD_PORT `{portStr}`"; return 1
  if portNat < 1024 || portNat > 65535 then
    IO.eprintln s!"orb-locald: ORB_LOCALD_PORT `{portNat}` must be in 1024..65535"
    return 1
  let port : UInt16 := portNat.toUInt16
  let rawTok? ← IO.getEnv "ORB_LOCALD_TOKEN"
  let tok ← match rawTok? with
    | some t => pure t.trimAscii.toString
    | none =>
      if args.contains "--ephemeral-token" then
        randomHexBytes 32
      else
        pure ""
  if !checkRpcAuth "127.0.0.1" tok tok then
    IO.eprintln "orb-locald: refusing to start without a non-placeholder ORB_LOCALD_TOKEN (>= 32 bytes) or --ephemeral-token"
    return 1
  let bridgeUuid ← randomUuidV4
  let hostOs ← detectHostOs
  let signerEnv? ← IO.getEnv "ORB_SIGNER_BIN"
  let signerBin? ← match signerEnv? with
    | some b =>
      let tb := b.trimAscii.toString
      pure (if tb.isEmpty then none else some tb)
    | none =>
      let appPath ← IO.appPath
      let sibling : String := match appPath.parent with
        | some dir => (dir / "orb-signer").toString
        | none => "orb-signer"
      if (← System.FilePath.pathExists sibling) then
        pure (some sibling)
      else if hostOs == "macos" then
        pure (some "macos_shell/build/orb-signer")
      else
        pure (some "linux_shell/build/orb-signer")
  let homeDir := ((← IO.getEnv "HOME").getD "/tmp").trimAscii.toString
  let rawStateEnv := ((← IO.getEnv "ORB_STATE_DIR").getD "").trimAscii.toString
  let orbStateDir := if rawStateEnv.isEmpty then s!"{homeDir}/.orb" else rawStateEnv
  let defaultKeyPath :=
    if hostOs == "macos" then s!"{homeDir}/Library/Application Support/sh.sandboxed.orb/approval-key.bin"
    else s!"{homeDir}/.config/orb/approval-key.bin"
  let rawKeyEnv := ((← IO.getEnv "ORB_APPROVAL_KEY_PATH").getD "").trimAscii.toString
  let approvalKeyPath := if rawKeyEnv.isEmpty then defaultKeyPath else rawKeyEnv
  let baseProxyHint : UInt16 := if port ≤ 65520 then port + 1 else 19480
  match ← bindLoopbackPortPool baseProxyHint with
  | .error e =>
    IO.eprintln s!"orb-locald: {e}"
    return 1
  | .ok (proxyFd, proxyPort, shardFds, shardPorts) =>
    match ← tcpListen "127.0.0.1" port 64 with
    | .error _ =>
      for sfd in shardFds do discard <| closeFd sfd
      discard <| closeFd proxyFd
      IO.eprintln s!"orb-locald: failed to bind 127.0.0.1:{port}"
      return 1
    | .ok (rpcFd, boundRpcPort) =>
      let h2Pool ← OrbNetLeaf.H2Pool.H2ClientPool.new
      let bridge : TransportBridgeState := {
        proxyPort := proxyPort
        bridgeUuid := bridgeUuid
        shardPorts := shardPorts
      }
      if let some primaryOrig := bridge.failoverOrigins[0]? then
        if let some (true, host, p, _) := parseOriginHostPort primaryOrig then
          h2Pool.prewarm host p true 6000
      let initState : LocaldState := {
        launchToken := tok
        rpcPort := boundRpcPort
        bridge := bridge
        approvalKeyPath := approvalKeyPath
        orbStateDir := orbStateDir
        homeDir := homeDir
        hostOs := hostOs
        signerBin? := signerBin?
        h2Pool? := some h2Pool
      }
      let parentPid? : Option Int64 :=
        match (← IO.getEnv "ORB_PARENT_PID") with
        | some raw =>
          match raw.trimAscii.toString.toNat? with
          | some n => if n > 1 && n ≤ 0x7FFFFFFF then some (Int64.ofNat n) else none
          | none => none
        | none => none
      OrbBin.PosixExt.installTermTrap
      let stRef ← IO.mkRef initState
      ensurePersistedBindingsLoaded stRef
      ensurePersistedOriginsLoaded stRef
      acceptMuxLoop stRef rpcFd (#[proxyFd] ++ shardFds) parentPid? 0
