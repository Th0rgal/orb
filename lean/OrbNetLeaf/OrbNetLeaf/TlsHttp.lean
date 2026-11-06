/-
  OrbNetLeaf.TlsHttp: Verified outbound HTTPS / HTTP/1.1 client over OpenSSL
  TLS 1.3/1.2 (`orb_net_leaf_tls_roundtrip` with socket deadlines & truncation/EOF
  status verification) + HTTP/2 / HTTP/3 (`curl --http2` / `--http3` with
  header-file separation so curl's decoded stdout body is never double-dechunked),
  strictly gated by `OrbNetLeaf.Spec` and `LeanSys.Spec`.
-/
import LeanSys.Spec
import LeanSys.Http
import LeanSys.Posix
import OrbNetLeaf.Spec
import OrbNetLeaf.Crypto

namespace OrbNetLeaf.TlsHttp

open LeanSys.Spec
open LeanSys.Http
open OrbNetLeaf.Spec

@[extern "orb_net_leaf_tls_roundtrip"]
private opaque rawTlsRoundtrip
    (host : @& String) (port : UInt16)
    (req : @& ByteArray) (maxResp : USize)
    (verifyPeer : UInt8) (timeoutMs : UInt32) : IO ByteArray

@[extern "orb_net_leaf_touch_excl_0600"]
private opaque rawTouchExcl0600 (path : @& String) : IO UInt64

/-- Create an exclusive owner-only (`0600`) regular file (`O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC`)
    so temporary response-header files in `/tmp` are never world-readable or symlink-hijackable. -/
def createExclFile0600 (path : System.FilePath) : IO (Except String Unit) := do
  let w ← rawTouchExcl0600 path.toString
  if (w >>> 63) != 0 then
    return .error s!"failed to create exclusive 0600 file `{path}`"
  return .ok ()

structure HttpsResponse where
  status  : Nat
  headers : Array (String × String)
  body    : ByteArray
  deriving Inhabited

private def isBodylessHttpResponse (method : String) (statusCode : Nat) : Bool :=
  asciiEqIgnoreCase method "HEAD" ||
  (statusCode >= 100 && statusCode <= 199) ||
  statusCode == 204 ||
  statusCode == 304

/-- Check that a hostname or HTTP header string contains zero CR/LF/NUL control bytes,
    routing slice indexing through `verifySliceBounds`. -/
def hasNoCrLfOrNul (s : String) : UInt8 := Id.run do
  let b := s.toUTF8
  let cap := b.size.toUInt64
  let mut i : Nat := 0
  while verifySliceBounds i.toUInt64 1 cap == 1 do
    let c := b.get! i
    if c == 0 || c == 10 || c == 13 then
      return 0
    i := i + 1
  return 1

/-- Check that an HTTP request-target (`origin-form`, starting with `/`) contains only
    RFC 9112 visible ASCII without URL fragment `#` (`0x21..0x7E`, `c != 0x23` — rejecting
    spaces, tabs, `#`, DEL, CR, LF, NUL, and non-ASCII). -/
def isValidRequestTarget (path : String) : Bool := Id.run do
  if path.isEmpty || !path.startsWith "/" then
    return false
  let b := path.toUTF8
  let cap := b.size.toUInt64
  let mut i : Nat := 0
  while verifySliceBounds i.toUInt64 1 cap == 1 do
    let c := b.get! i
    if c < 0x21 || c > 0x7E || c == 0x23 then
      return false
    i := i + 1
  return true

private def isDnsHostByte (c : UInt8) : Bool :=
  (0x41 ≤ c && c ≤ 0x5A) || (0x61 ≤ c && c ≤ 0x7A) ||
  (0x30 ≤ c && c ≤ 0x39) || c == 0x2D || c == 0x2E || c == 0x5F

private def isIpv6LiteralByte (c : UInt8) : Bool :=
  (0x30 ≤ c && c ≤ 0x39) || (0x41 ≤ c && c ≤ 0x46) ||
  (0x61 ≤ c && c ≤ 0x66) || c == 0x3A || c == 0x2E

/-- Validate a bare DNS hostname or IPv4/IPv6 literal (`0` URI authority delimiters such as
    `@`, `/`, `?`, `#`, `[`, `]`, whitespace, or control bytes). -/
def isValidBareHost (host : String) : Bool := Id.run do
  if host.isEmpty then
    return false
  let b := host.toUTF8
  let cap := b.size.toUInt64
  if host.contains ':' then
    let mut i : Nat := 0
    while verifySliceBounds i.toUInt64 1 cap == 1 do
      if !isIpv6LiteralByte (b.get! i) then
        return false
      i := i + 1
    return true
  else
    let mut i : Nat := 0
    while verifySliceBounds i.toUInt64 1 cap == 1 do
      if !isDnsHostByte (b.get! i) then
        return false
      i := i + 1
    return true

/-- Format RFC 9110 §7.2 `Host` / URL authority from a validated bare `host` and `port`
    (wrapping IPv6 literals in `[...]` and appending `:port` when `port != defaultPort`). -/
def formatHostAuthority (host : String) (port : UInt16) (defaultPort : UInt16 := 443) : String :=
  let hostLit := if host.contains ':' then s!"[{host}]" else host
  if port == defaultPort then hostLit else s!"{hostLit}:{port}"

/-- Validate an RFC 9110 §7.2 `Host` header authority (`host`, `[ipv6]`, `host:port`, or `[ipv6]:port`),
    forbidding `@`, `/`, `?`, `#`, whitespace, and control bytes. -/
def isValidHostChars (hostAuth : String) : Bool :=
  if hostAuth.isEmpty then false
  else if hostAuth.startsWith "[" then
    match hostAuth.splitOn "]" with
    | [brack, rest] =>
      let ipv6 := (brack.drop 1).toString
      ipv6.contains ':' && isValidBareHost ipv6 &&
      (if rest.isEmpty then true
       else if rest.startsWith ":" then
         match parseStrictContentLength? (rest.drop 1).toString with
         | some p => 1 ≤ p && p ≤ 65535
         | none => false
       else false)
    | _ => false
  else
    match hostAuth.splitOn ":" with
    | [h] => !h.contains ':' && isValidBareHost h
    | [h, pStr] =>
      !h.contains ':' && isValidBareHost h &&
      match parseStrictContentLength? pStr with
      | some p => 1 ≤ p && p ≤ 65535
      | none => false
    | _ => false

/-- Build a smuggling-safe HTTP/1.1 outbound wire request:
    - Validates `method` (`isHttpToken`), `path` (`isValidRequestTarget`, rejecting spaces/tabs/controls),
      and `host` (`isValidHostChars`).
    - Rejects reserved framing headers (`Host`, `Connection`, `Transfer-Encoding`) and validates
      any caller-supplied `Content-Length` to forbid duplicates and require exact match to `body.size`. -/
def buildOutboundHttp11Request
    (method host path : String)
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty) : Except String ByteArray := do
  if method.isEmpty || !isHttpToken method then
    throw s!"invalid HTTP method `{method}`"
  if !isValidRequestTarget path then
    throw s!"invalid HTTP request target `{path}`"
  if !isValidHostChars host || hasNoCrLfOrNul host != 1 then
    throw "hostname contains invalid whitespace or control bytes"
  let mut hdrBlock := s!"{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n"
  let mut hasCl := false
  let mut idx : Nat := 0
  let nHdrs := headers.size.toUInt64
  while verifySliceBounds idx.toUInt64 1 nHdrs == 1 do
    let (hk, hv) := headers[idx]!
    if hk.isEmpty || !isHttpToken hk || hasNoCrLfOrNul hv != 1 then
      throw s!"invalid outbound HTTP header `{hk}`"
    if asciiEqIgnoreCase hk "host" || asciiEqIgnoreCase hk "connection" ||
       asciiEqIgnoreCase hk "transfer-encoding" then
      throw s!"reserved outbound HTTP header `{hk}`"
    if asciiEqIgnoreCase hk "content-length" then
      if hasCl then
        throw "duplicate outbound Content-Length header"
      match parseStrictContentLength? hv.trimAscii.toString with
      | some declaredLen =>
        if declaredLen != body.size then
          throw s!"outbound Content-Length ({declaredLen}) does not match body size ({body.size})"
        hasCl := true
      | none =>
        throw s!"invalid outbound Content-Length `{hv}`"
    hdrBlock := hdrBlock ++ s!"{hk}: {hv}\r\n"
    idx := idx + 1
  if !hasCl && body.size > 0 then
    hdrBlock := hdrBlock ++ s!"Content-Length: {body.size}\r\n"
  hdrBlock := hdrBlock ++ "\r\n"
  return hdrBlock.toUTF8 ++ body

/-- Parse a single HTTP status + header block (`without` trailing `\r\n\r\n`) into
    `(statusCode, headers, hasTransferEncoding, isPureChunked, contentLen?)`.
    Under RFC 9112 §6.1, any `Transfer-Encoding` header overrides `Content-Length`,
    and our HTTP/1.x wire parser only admits `Transfer-Encoding: chunked` (rejecting
    unsupported transfer codings such as `gzip` or `chunked, gzip` fail-closed). -/
def parseHttpHeaderBlock (hdrStr : String) (allowNonChunkedTe : Bool := false) :
    Except String (Nat × Array (String × String) × Bool × Bool × Option Nat) := do
  let lines := hdrStr.splitOn "\r\n"
  let statusLine :: rawFields := lines
    | throw "missing HTTP status line"
  let statusParts := (statusLine.splitOn " ").filter (!·.isEmpty)
  let ver :: codeStr :: _ := statusParts
    | throw s!"malformed HTTP status line `{statusLine}`"
  if !(ver == "HTTP/1.1" || ver == "HTTP/1.0" || ver == "HTTP/2" || ver == "HTTP/3") then
    throw s!"unsupported HTTP response version `{ver}`"
  let some statusCode := parseStrictContentLength? codeStr
    | throw s!"non-numeric HTTP status code `{codeStr}`"
  if statusCode < 100 || statusCode > 599 then
    throw s!"out-of-range HTTP status code {statusCode}"
  let mut parsedHeaders : Array (String × String) := #[]
  let mut teCodings : Array String := #[]
  let mut contentLen? : Option Nat := none
  for line in rawFields do
    if !line.isEmpty then
      if verifySliceBounds parsedHeaders.size.toUInt64 1 128 != 1 then
        throw "HTTP response exceeds 128 headers"
      match line.splitOn ":" with
      | [] | [_] => throw s!"malformed HTTP header line `{line}`"
      | hk :: rest =>
        let k := hk.trimAscii.toString
        let v := (String.intercalate ":" rest).trimAscii.toString
        if k.isEmpty || !isHttpToken k || hasNoCrLfOrNul v != 1 then
          throw s!"invalid HTTP response header `{k}`"
        if asciiEqIgnoreCase k "transfer-encoding" then
          let toks := (v.splitOn ",").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
          if toks.isEmpty then
            throw "empty Transfer-Encoding header"
          for t in toks do
            teCodings := teCodings.push t
        else if asciiEqIgnoreCase k "content-length" then
          match parseStrictContentLength? v with
          | some cl =>
            if contentLen?.isSome && contentLen? != some cl then
              throw "conflicting duplicate Content-Length headers"
            contentLen? := some cl
          | none => throw "invalid Content-Length response value"
        parsedHeaders := parsedHeaders.push (k, v)
  let hasTe := !teCodings.isEmpty
  let isPureChunked := teCodings.size == 1 && asciiEqIgnoreCase teCodings[0]! "chunked"
  if hasTe && !isPureChunked && !allowNonChunkedTe then
    throw s!"unsupported HTTP Transfer-Encoding `{String.intercalate ", " teCodings.toList}`"
  let effectiveCl := if hasTe then none else contentLen?
  return (statusCode, parsedHeaders, hasTe, isPureChunked, effectiveCl)

/-- Parse a bounded HTTP/1.x wire response (`status`, `headers`, `Content-Length` or `chunked` `body`),
    skipping up to 8 RFC 9110 §15.2 `1xx` informational header blocks (`100 Continue`, `103 Early Hints`,
    excluding `101 Switching Protocols`), honoring RFC 9112 §6.3 bodyless response rules (`HEAD`, `204`, `304`)
    before `Transfer-Encoding` / `Content-Length` framing, and rejecting unauthenticated TLS EOF on
    close-delimited responses fail-closed. -/
def parseHttpResponseWire
    (raw : ByteArray)
    (maxBodyBytes : Nat := 16777216)
    (authenticatedEof : Bool := true)
    (requestMethod : String := "GET") :
    Except String HttpsResponse := do
  let mut cursor := raw
  let mut infoCount : Nat := 0
  while true do
    let cap := cursor.size.toUInt64
    if verifySliceBounds 0 12 cap != 1 then
      throw "truncated HTTP response status line"
    let some bodyStart := findHeaderEnd? cursor
      | throw "unterminated HTTP response header block"
    if verifySliceBounds 0 bodyStart.toUInt64 cap != 1 ||
       verifySliceBounds 0 bodyStart.toUInt64 65536 != 1 then
      throw "HTTP response header block exceeds 64 KiB cap"
    let hdrBytes := cursor.extract 0 (bodyStart - 4)
    let some hdrStr := String.fromUTF8? hdrBytes
      | throw "non-UTF8 HTTP response headers"
    let (statusCode, parsedHeaders, hasTe, isPureChunked, contentLen?) ← parseHttpHeaderBlock hdrStr true
    let remLen := cursor.size - bodyStart
    if verifySliceBounds bodyStart.toUInt64 remLen.toUInt64 cap != 1 then
      throw "invalid HTTP response body slice"
    let rest := cursor.extract bodyStart cursor.size
    if statusCode >= 100 && statusCode <= 199 && statusCode != 101 then
      if infoCount >= 8 then
        throw "too many 1xx informational HTTP responses"
      infoCount := infoCount + 1
      cursor := rest
    else if statusCode == 101 then
      throw "unexpected 101 Switching Protocols in HTTP response"
    else if isBodylessHttpResponse requestMethod statusCode then
      return { status := statusCode, headers := parsedHeaders, body := ByteArray.empty }
    else if hasTe then
      if !isPureChunked then
        throw "unsupported HTTP Transfer-Encoding"
      match decodeChunkedBody? rest maxBodyBytes with
      | some decoded =>
        return { status := statusCode, headers := parsedHeaders, body := decoded }
      | none => throw "malformed or oversized chunked HTTP response body"
    else
      match contentLen? with
      | some cl =>
        if verifySliceBounds 0 cl.toUInt64 rest.size.toUInt64 != 1 ||
           verifySliceBounds 0 cl.toUInt64 maxBodyBytes.toUInt64 != 1 then
          throw "HTTP response body truncated or exceeds maxBodyBytes"
        return { status := statusCode, headers := parsedHeaders, body := rest.extract 0 cl }
      | none =>
        if !authenticatedEof then
          throw "unauthenticated TLS EOF on close-delimited HTTP response"
        if verifySliceBounds 0 rest.size.toUInt64 maxBodyBytes.toUInt64 != 1 then
          throw "HTTP response body exceeds maxBodyBytes"
        return { status := statusCode, headers := parsedHeaders, body := rest }
  throw "unreachable HTTP response parse state"

/-- Decode the status-prefixed buffer returned by `orb_net_leaf_tls_roundtrip`:
    - `status == 1`: clean TLS `close_notify` (`SSL_ERROR_ZERO_RETURN`) -> `authenticatedEof := true`
    - `status == 2`: response exceeded `maxWireBytes` budget -> rejected fail-closed
    - `status == 4`: TCP EOF without `close_notify` -> accepted only if self-delimiting (`Content-Length` / `chunked` / bodyless)
    - empty / other: TLS handshake, write, read, or socket timeout failure -> rejected fail-closed. -/
def decodeTlsRoundtripWire
    (framed : ByteArray) (maxBodyBytes : Nat) (requestMethod : String := "GET") :
    Except String HttpsResponse := do
  if verifySliceBounds 0 1 framed.size.toUInt64 != 1 then
    throw "TLS transport error or timeout"
  let status := framed.get! 0
  let wire := framed.extract 1 framed.size
  if status == 2 then
    throw s!"TLS response exceeded maxRespBytes budget ({maxBodyBytes})"
  else if status == 1 then
    parseHttpResponseWire wire maxBodyBytes true requestMethod
  else if status == 4 then
    parseHttpResponseWire wire maxBodyBytes false requestMethod
  else
    throw s!"TLS read failed with transport status {status}"

/-- Execute a verified WebPKI TLS 1.3/1.2 roundtrip (`orb_net_leaf_tls_roundtrip`),
    strictly gated by `OrbNetLeaf.Spec.verifyOutboundRequest`. -/
def httpsRequest
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 4194304)
    (verifyPeer : Bool := true)
    (timeoutMs : UInt32 := 30000) : IO (Except String HttpsResponse) := do
  let noCrLf := if isValidBareHost host && hasNoCrLfOrNul host == 1 then (1 : UInt8) else 0
  let vpFlag : UInt8 := if verifyPeer then 1 else 0
  let hostAuth := formatHostAuthority host port 443
  let reqWire ← match buildOutboundHttp11Request method hostAuth path headers body with
    | .ok w => pure w
    | .error e => return .error e
  if verifyOutboundRequest noCrLf vpFlag port.toUInt32
      host.toUTF8.size.toUInt64 reqWire.size.toUInt64 maxRespBytes.toUInt64 != 1 then
    return .error "httpsRequest rejected by verifyOutboundRequest"
  let maxWireCap := maxRespBytes + 65536
  let framed ← rawTlsRoundtrip host port reqWire (USize.ofNat maxWireCap) vpFlag timeoutMs
  if framed.isEmpty then
    return .error s!"TLS roundtrip failed to {host}:{port}"
  return decodeTlsRoundtripWire framed maxRespBytes method

/-- Parse `curl --dump-header` output (which may contain `100 Continue` blocks AND trailing HTTP
    trailer blocks without a `HTTP/` status line, and whose stdout `decodedBody` has ALREADY had
    HTTP/1.1 `chunked` framing removed by curl) without double-decoding `Transfer-Encoding: chunked`
    and while honoring bodyless `HEAD` / `204` / `304` responses. -/
def parseCurlDumpHeadersAndBody
    (hdrDump decodedBody : ByteArray)
    (maxBodyBytes : Nat := 16777216)
    (requestMethod : String := "GET") :
    Except String HttpsResponse := do
  let some dumpStr := String.fromUTF8? hdrDump
    | throw "non-UTF8 curl response headers"
  let blocks := (dumpStr.splitOn "\r\n\r\n").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let httpBlocks := blocks.filter (fun b => b.startsWith "HTTP/")
  let some lastHttpBlock := httpBlocks.getLast?
    | throw "empty curl response header dump"
  let (statusCode, parsedHeaders, hasTe, _, contentLen?) ← parseHttpHeaderBlock lastHttpBlock true
  if isBodylessHttpResponse requestMethod statusCode then
    return { status := statusCode, headers := parsedHeaders, body := ByteArray.empty }
  if decodedBody.size > maxBodyBytes then
    throw s!"HTTP response body ({decodedBody.size}) exceeds maxBodyBytes ({maxBodyBytes})"
  if !hasTe then
    if let some cl := contentLen? then
      if decodedBody.size != cl then
        throw s!"curl response body size ({decodedBody.size}) mismatches Content-Length ({cl})"
  return { status := statusCode, headers := parsedHeaders, body := decodedBody }

inductive HttpWireVersion where
  | http2
  | http3
  deriving Repr, DecidableEq, BEq, Inhabited

private def readBoundedFileBytes (path : System.FilePath) (maxCap : Nat) : IO (Except String ByteArray) := do
  let h ← IO.FS.Handle.mk path .read
  let chunk ← h.read (USize.ofNat (maxCap + 1))
  if chunk.size > maxCap then
    return .error s!"file `{path}` exceeds {maxCap}-byte cap"
  return .ok chunk

private def hdrDumpExceedsCap (path : System.FilePath) (maxCap : Nat) : IO Bool := do
  try
    let m ← path.metadata
    return m.byteSize.toNat > maxCap
  catch _ =>
    return false

/-- Execute a verified outbound HTTP/2 or HTTP/3 request via `/usr/bin/curl` prior to Wave 5
    native `LeanSys.{H2,Quic,H3}` cutover, separating `--dump-header <tmp>` from stdout body so
    HTTP/1.1 chunked fallback responses are never double-dechunked. -/
def http2Or3RequestViaCurl
    (version : HttpWireVersion)
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 4194304)
    (timeoutSecs : Nat := 30) : IO (Except String HttpsResponse) := do
  let noCrLf := if isValidBareHost host && hasNoCrLfOrNul host == 1 then (1 : UInt8) else 0
  let hostAuth := formatHostAuthority host port 443
  let reqWire ← match buildOutboundHttp11Request method hostAuth path headers body with
    | .ok w => pure w
    | .error e => return .error e
  if verifyOutboundRequest noCrLf 1 port.toUInt32
      host.toUTF8.size.toUInt64 reqWire.size.toUInt64 maxRespBytes.toUInt64 != 1 then
    return .error "http2Or3RequestViaCurl rejected by verifyOutboundRequest"
  let nonceBytes ← match (← OrbNetLeaf.Crypto.randBytes 8) with
    | .ok b => pure b
    | .error e => return .error e
  let mut nonceHex := ""
  for i in [0:nonceBytes.size] do
    let v := (nonceBytes.get! i).toNat
    let hex := "0123456789abcdef".toList.toArray
    nonceHex := nonceHex.push (hex[(v / 16) % 16]!) |>.push (hex[v % 16]!)
  let hdrFile : System.FilePath := s!"/tmp/orb_curl_hdr_{nonceHex}.tmp"
  if let .error e ← createExclFile0600 hdrFile then
    return .error e
  let isHead := asciiEqIgnoreCase method "HEAD"
  let verFlag := match version with
    | .http2 => "--http2"
    | .http3 => "--http3"
  let mut args : Array String := #[
    "--disable", "--globoff", "--path-as-is", "--disallow-username-in-url", "--proto", "=https",
    "--silent", "--show-error", "--dump-header", hdrFile.toString,
    "--max-time", toString (if timeoutSecs == 0 then 1 else timeoutSecs),
    verFlag
  ]
  if isHead then
    args := args.push "--head" |>.push "--output" |>.push "/dev/null"
  else
    args := args.push "--max-filesize" |>.push (toString maxRespBytes) |>.push "-X" |>.push method
  for (hk, hv) in headers do
    args := args.push "-H"
    args := args.push s!"{hk}: {hv}"
  let urlHost := if host.contains ':' then s!"[{host}]" else host
  let url := s!"https://{urlHost}:{port}{path}"
  args := args.push url
  let lifeMu ← Std.Mutex.new false
  let hdrExceededFlag ← IO.mkRef false
  let mut watchdogOpt : Option (Task (Except IO.Error Unit)) := none
  let mut childOpt : Option (IO.Process.Child ⟨.null, .piped, .piped⟩) := none
  let stopWatchdog (wd? : Option (Task (Except IO.Error Unit))) : IO Unit := do
    lifeMu.atomically (set true)
    if let some wd := wd? then
      let _ ← IO.wait wd
  try
    let child ← IO.Process.spawn {
      cmd := "/usr/bin/curl"
      args := if isHead || body.isEmpty then args else args.push "--data-binary" |>.push "@-"
      stdin := .piped
      stdout := .piped
      stderr := .piped
    }
    try
      if !isHead && !body.isEmpty then
        child.stdin.write body
        child.stdin.flush
    catch _ =>
      let (_, childErr) ← child.takeStdin
      childOpt := some childErr
      throw (IO.userError "failed writing request body to curl stdin")
    let (_, child') ← child.takeStdin
    childOpt := some child'
    let watchdog ← IO.asTask (prio := .dedicated) do
      let mut keepPolling := true
      while keepPolling do
        let exceeded ← hdrDumpExceedsCap hdrFile 65536
        keepPolling ← lifeMu.atomically do
          if ← get then
            return false
          if exceeded then
            hdrExceededFlag.set true
            child'.kill
            set true
            return false
          return true
        if keepPolling then
          IO.sleep 25
    watchdogOpt := some watchdog
    let stdoutCap := if isHead then 65536 else maxRespBytes
    let mut outBytes := ByteArray.empty
    while true do
      let chunk ← child'.stdout.read 65536
      if chunk.isEmpty then break
      outBytes := outBytes ++ chunk
      if outBytes.size > stdoutCap then
        lifeMu.atomically do
          if !(← get) then
            child'.kill
            set true
        stopWatchdog watchdogOpt
        let _ ← child'.wait
        childOpt := none
        try IO.FS.removeFile hdrFile catch _ => pure ()
        return .error s!"curl ({verFlag}) response exceeded maxRespBytes {maxRespBytes}"
    let errStr ← child'.stderr.readToEnd
    stopWatchdog watchdogOpt
    let code ← child'.wait
    childOpt := none
    if (← hdrExceededFlag.get) || (← hdrDumpExceedsCap hdrFile 65536) then
      try IO.FS.removeFile hdrFile catch _ => pure ()
      return .error "curl response header dump exceeds 64 KiB cap"
    if code != 0 then
      try IO.FS.removeFile hdrFile catch _ => pure ()
      return .error s!"curl ({verFlag}) exited with {code}: {errStr.trimAscii.toString}"
    let hdrRes ← readBoundedFileBytes hdrFile 65536
    try IO.FS.removeFile hdrFile catch _ => pure ()
    let hdrBytes ← match hdrRes with
      | .ok b => pure b
      | .error _ => return .error "curl response header dump exceeds 64 KiB cap"
    return parseCurlDumpHeadersAndBody hdrBytes (if isHead then ByteArray.empty else outBytes) maxRespBytes method
  catch e =>
    lifeMu.atomically do
      if !(← get) then
        if let some c := childOpt then
          c.kill
        set true
    stopWatchdog watchdogOpt
    if let some c := childOpt then
      try let _ ← c.wait catch _ => pure ()
    try IO.FS.removeFile hdrFile catch _ => pure ()
    return .error s!"curl ({verFlag}) execution failed: {e}"

end OrbNetLeaf.TlsHttp
