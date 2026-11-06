import LeanSys
import OrbNetLeaf.TlsHttp
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

private def corsHeaderBlock (origin? : Option String) : String :=
  match origin? with
  | none => ""
  | some raw =>
    let o := raw.trimAscii.toString
    if !o.isEmpty && isAllowedLocaldOrigin (some o) then
      s!"Access-Control-Allow-Origin: {o}\r\nVary: Origin\r\n"
    else
      ""

private def sendJsonHttp (fd : Fd) (status : Nat) (origin? : Option String) (jsonPayload : String) : IO Unit := do
  let reason := HttpResponse.reasonPhrase status
  let body := jsonPayload.toUTF8
  let head :=
    s!"HTTP/1.1 {status} {reason}\r\n" ++
    corsHeaderBlock origin? ++
    "Content-Type: application/json\r\n" ++
    s!"Content-Length: {body.size}\r\n" ++
    "Connection: close\r\n\r\n"
  discard <| writeAll fd (head.toUTF8 ++ body) false

private def sendPreflight204 (fd : Fd) (origin? : Option String) : IO Unit := do
  let head :=
    "HTTP/1.1 204 No Content\r\n" ++
    corsHeaderBlock origin? ++
    "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
    "Access-Control-Allow-Headers: Content-Type, Authorization, X-Orb-Token, Idempotency-Key\r\n" ++
    "Access-Control-Max-Age: 86400\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n\r\n"
  discard <| writeAll fd head.toUTF8 false

private def parseOriginHostPort (raw : String) : Option (Bool × String × UInt16 × String) :=
  let (isTls, rest) :=
    if raw.startsWith "https://" then (true, (raw.drop 8).toString)
    else if raw.startsWith "http://" then (false, (raw.drop 7).toString)
    else (false, "")
  if rest.isEmpty then none
  else
    let defPort : UInt16 := if isTls then 443 else 80
    let parts := rest.splitOn "/"
    let hostPort := parts.head?.getD ""
    let tail := String.intercalate "/" (parts.drop 1)
    let pfx := if tail.isEmpty then "" else "/" ++ tail
    match hostPort.splitOn ":" with
    | [h] => if h.isEmpty then none else some (isTls, h, defPort, pfx)
    | [h, pStr] =>
      match pStr.toNat? with
      | some p => if !h.isEmpty && 1 ≤ p && p ≤ 65535 then some (isTls, h, p.toUInt16, pfx) else none
      | none => none
    | _ => none

private def isHopByHopHeader (name : String) : Bool :=
  let low := name.trimAscii.toString.toLower
  low == "host" || low == "connection" || low == "content-length" ||
  low == "transfer-encoding" || low == "keep-alive" || low == "upgrade" ||
  low == "proxy-connection" || low.startsWith "access-control-"

private def isHeaderValueClean (s : String) : Bool :=
  !(s.toList.any (fun c => c == '\r' || c == '\n' || c.toNat == 0))

private def sanitizeUpstreamHeaders (hdrs : Array (String × String)) : String := Id.run do
  let mut out := ""
  for (k, v) in hdrs do
    let tk := k.trimAscii.toString
    let tv := v.trimAscii.toString
    if !tk.isEmpty && !isHopByHopHeader tk && tk.toLower != "content-type" &&
       isHeaderValueClean tk && isHeaderValueClean tv then
      out := out ++ s!"{tk}: {tv}\r\n"
  return out

private def findCurlBin? : IO (Option String) := do
  for cand in #["/usr/bin/curl", "/bin/curl", "/opt/homebrew/bin/curl"] do
    if (← System.FilePath.pathExists cand) then
      return some cand
  return none

private def isSseStreamRequest (isShardPort : Bool) (req : HttpRequest) : Bool :=
  if isShardPort && req.method.toUpper == "GET" then true
  else
    let acc := (findHeaderVal? req.headers "accept").getD ""
    acc.toLower.splitOn "text/event-stream" |>.length > 1

private def streamSseViaCurl (fd : Fd) (origin? : Option String) (url : String)
    (method : String) (fwdHdrs : Array (String × String)) : IO Bool := do
  let some curlBin ← findCurlBin? | return false
  let mut cargs : Array String := #[
    "--disable", "--globoff", "--path-as-is", "--disallow-username-in-url",
    "--silent", "--show-error", "--no-buffer", "-N", "--http1.1",
    "--proto", "=https", "--connect-timeout", "10", "-i", "-X", method
  ]
  for (hk, hv) in fwdHdrs do
    if isHeaderValueClean hk && isHeaderValueClean hv then
      cargs := cargs.push "-H"
      cargs := cargs.push s!"{hk}: {hv}"
  cargs := cargs.push "--url"
  cargs := cargs.push url
  let child ← IO.Process.spawn {
    cmd := curlBin
    args := cargs
    stdin := .null
    stdout := .piped
    stderr := .null
  }
  let mut hdrAcc := ByteArray.empty
  let mut headerSent := false
  let mut aborted := false
  let mut eof := false
  while !eof && !aborted do
    let chunk ← child.stdout.read 4096
    if chunk.isEmpty then
      eof := true
    else if !headerSent then
      hdrAcc := hdrAcc ++ chunk
      match extractStreamingResponseHead? hdrAcc with
      | .error _ =>
        aborted := true
      | .ok none =>
        pure ()
      | .ok (some (statusNat, parsedHdrs, bodyTail)) =>
        if statusNat == 429 || (500 ≤ statusNat && statusNat ≤ 599) then
          aborted := true
        else
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
          match ← writeAll fd (outHead.toUTF8 ++ bodyTail) false with
          | .ok _ => headerSent := true
          | .error _ => eof := true
    else
      match ← writeAll fd chunk false with
      | .ok _ => pure ()
      | .error _ => eof := true
  try child.kill catch _ => pure ()
  discard <| child.wait
  return headerSent

private def handleTransportProxyRequest (st : LocaldState) (isShardPort : Bool) (fd : Fd) (req : HttpRequest) (origin? : Option String) : IO Unit := do
  let expectedPfx := s!"/__orb_tx/{st.bridge.bridgeUuid}"
  if !req.path.startsWith expectedPfx then
    sendJsonHttp fd 403 origin? "{\"error\":\"invalid_bridge_token\"}"
  else if req.method == "OPTIONS" then
    sendPreflight204 fd origin?
  else
    let rawRel := (req.path.drop expectedPfx.length).toString
    let relPath := if rawRel.isEmpty then "/" else if rawRel.startsWith "/" then rawRel else "/" ++ rawRel
    let hasIdem := (findHeaderVal? req.headers "idempotency-key").isSome
    let fwdHdrs := req.headers.filter fun (k, _) => !isHopByHopHeader k
    let reqBody := req.bodySlice.toByteArray
    let origins := st.bridge.failoverOrigins
    let wantSse := isSseStreamRequest isShardPort req && reqBody.isEmpty
    if origins.isEmpty then
      sendJsonHttp fd 503 origin? "{\"error\":\"no_failover_origins\"}"
    else
      let mut idx : Nat := 0
      let mut done := false
      while idx < origins.size && !done do
        let orig := origins[idx]!
        if wantSse then
          match parseOriginHostPort orig with
          | some (true, host, port, pfx) =>
            let auth := if port == 443 then host else s!"{host}:{port}"
            let fullUrl := s!"https://{auth}{pfx}{relPath}"
            if (← streamSseViaCurl fd origin? fullUrl req.method fwdHdrs) then
              done := true
            else if canFailoverRequest req.method hasIdem (idx + 1) origins then
              idx := idx + 1
            else
              sendJsonHttp fd 502 origin? "{\"error\":\"upstream_stream_unreachable\"}"
              done := true
          | _ =>
            if canFailoverRequest req.method hasIdem (idx + 1) origins then
              idx := idx + 1
            else
              sendJsonHttp fd 502 origin? "{\"error\":\"invalid_stream_origin\"}"
              done := true
        else
          let attemptRes ← match parseOriginHostPort orig with
            | none => pure (.error "invalid_origin")
            | some (true, host, port, pfx) =>
              httpsRequest req.method host port (pfx ++ relPath) fwdHdrs reqBody
            | some (false, _, _, _) =>
              pure (.error "plaintext_origin_rejected")
          match attemptRes with
          | .ok up =>
            let retryStatus := up.status == 429 || (500 ≤ up.status && up.status ≤ 599)
            if retryStatus && canFailoverRequest req.method hasIdem (idx + 1) origins then
              idx := idx + 1
            else
              let ctype := (findHeaderVal? up.headers "content-type").getD "application/json"
              let extra := sanitizeUpstreamHeaders up.headers
              let reason := HttpResponse.reasonPhrase up.status
              let head :=
                s!"HTTP/1.1 {up.status} {reason}\r\n" ++
                corsHeaderBlock origin? ++
                s!"Content-Type: {ctype}\r\n" ++
                extra ++
                s!"Content-Length: {up.body.size}\r\n" ++
                "Connection: close\r\n\r\n"
              discard <| writeAll fd (head.toUTF8 ++ up.body) false
              done := true
          | .error _ =>
            if canFailoverRequest req.method hasIdem (idx + 1) origins then
              idx := idx + 1
            else
              sendJsonHttp fd 502 origin? "{\"error\":\"upstream_unreachable\"}"
              done := true

private def handleClientConnection (stRef : IO.Ref LocaldState) (portIdx : Nat) (clientFd : Fd) : IO Unit := do
  try
    match ← readHttpRequestFromFd clientFd none 5000 with
    | .error errMsg =>
      let code := statusForParseError errMsg
      sendJsonHttp clientFd code none (renderCompact (.obj #[("error", .str errMsg)]))
    | .ok req =>
      let origin? := findHeaderVal? req.headers "origin"
      if !isAllowedLocaldOrigin origin? then
        sendJsonHttp clientFd 403 none "{\"error\":\"forbidden_origin\"}"
      else
        let st ← stRef.get
        if portIdx > 0 || req.path.startsWith "/__orb_tx/" then
          handleTransportProxyRequest st (portIdx ≥ 2) clientFd req origin?
        else if req.method == "OPTIONS" && req.path == "/__orb_rpc" then
          sendPreflight204 clientFd origin?
        else if req.method != "POST" || req.path != "/__orb_rpc" then
          sendJsonHttp clientFd 404 origin? "{\"error\":\"not_found\"}"
        else
          let provided := (findHeaderVal? req.headers "x-orb-token").getD ""
          if !checkRpcAuth "127.0.0.1" provided st.launchToken then
            sendJsonHttp clientFd 401 origin? "{\"error\":\"unauthorized\"}"
          else
            let bodyStr := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
            match OrbBin.Json.parse bodyStr with
            | .error e =>
              sendJsonHttp clientFd 400 origin? (renderCompact (.obj #[("error", .str e)]))
            | .ok jv =>
              let cmd := (jv.fieldStr? "command").getD ""
              let cargs := (jv.field? "args").getD (.obj #[])
              let out ← dispatchRpcCommand stRef cmd cargs
              match out with
              | .ok res =>
                sendJsonHttp clientFd 200 origin? (renderCompact (.obj #[("result", res)]))
              | .error msg =>
                sendJsonHttp clientFd 400 origin? (renderCompact (.obj #[("error", .str msg)]))
  finally
    discard <| closeFd clientFd

partial def acceptMuxLoop (stRef : IO.Ref LocaldState) (rpcFd : Fd) (proxyFds : Array Fd) : IO UInt32 := do
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
  acceptMuxLoop stRef rpcFd proxyFds

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
      else
        pure (some "macos_shell/build/orb-signer")
  let homeDir := ((← IO.getEnv "HOME").getD "/tmp").trimAscii.toString
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
      let bridge : TransportBridgeState := {
        proxyPort := proxyPort
        bridgeUuid := bridgeUuid
        shardPorts := shardPorts
      }
      let initState : LocaldState := {
        launchToken := tok
        rpcPort := boundRpcPort
        bridge := bridge
        approvalKeyPath := approvalKeyPath
        hostOs := hostOs
        signerBin? := signerBin?
      }
      let stRef ← IO.mkRef initState
      acceptMuxLoop stRef rpcFd (#[proxyFd] ++ shardFds)
