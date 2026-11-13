/-
  OrbNetLeaf.TlsHttp: Verified outbound HTTPS / HTTP/1.1, native live TLS SSE streaming,
  native RFC 9113 HTTP/2 (`LeanSys.H2` + `OrbNetLeaf.HpackQpack` over WebPKI TLS ALPN `"h2"`
  with interactive `SETTINGS` ACK, `PING` ACK, bidirectional flow-control `WINDOW_UPDATE`,
  and `CONTINUATION`), and native RFC 9000/9001/9114 QUIC + HTTP/3 (`LeanSys.Quic` + `LeanSys.H3`
  + `OrbNetLeaf.HpackQpack` over UDP datagrams with stateful `Std.Mutex`-guarded anti-nonce-reuse
  and anti-replay `Quic1RttSession`).
  Zero external `curl` or `libcurl` dependencies; every slice and frame transition is strictly
  gated by `OrbNetLeaf.Spec` and `LeanSys.Spec`.
-/
import Std.Sync.Mutex
import LeanSys.Spec
import LeanSys.Http
import LeanSys.Posix
import LeanSys.H2
import LeanSys.Quic
import LeanSys.H3
import OrbNetLeaf.Spec
import OrbNetLeaf.Crypto
import OrbNetLeaf.HpackQpack

namespace OrbNetLeaf.TlsHttp

open LeanSys.Spec
open LeanSys.Http
open LeanSys.Posix
open LeanSys.H2
open LeanSys.Quic
open LeanSys.H3
open OrbNetLeaf.Spec
open OrbNetLeaf.Crypto
open OrbNetLeaf.HpackQpack

private opaque NonemptyTlsSession : NonemptyType
/-- Live OpenSSL WebPKI TLS 1.3/1.2 session handle backed by `orb_net_leaf.c` (`pthread_mutex_t` synchronized). -/
def TlsSession : Type := NonemptyTlsSession.type
instance : Nonempty TlsSession := NonemptyTlsSession.property

/-- Outcome of `orb_net_leaf_tls_open` (`0` = connect/TLS failure, `1` = TLS succeeded without ALPN `"h2"`, `2` = live session). -/
inductive TlsOpenOutcome where
  | failed
  | alpnNotH2
  | ok (sess : TlsSession)

@[extern "orb_net_leaf_tls_open"]
private opaque rawTlsOpen
    (host : @& String) (port : UInt16)
    (req : @& ByteArray) (verifyPeer alpnMode : UInt8)
    (timeoutMs : UInt32) : IO TlsOpenOutcome

@[extern "orb_net_leaf_tls_write"]
private opaque rawTlsWrite
    (sess : @& TlsSession) (buf : @& ByteArray) : IO UInt8

@[extern "orb_net_leaf_tls_read"]
private opaque rawTlsRead
    (sess : @& TlsSession) (maxChunk : USize) (rcvTimeoutMs : UInt32) : IO ByteArray

@[extern "orb_net_leaf_tls_close"]
private opaque rawTlsClose
    (sess : @& TlsSession) : IO Unit

@[extern "orb_net_leaf_udp_roundtrip"]
private opaque rawUdpRoundtrip
    (host : @& String) (port : UInt16)
    (dgram : @& ByteArray) (maxResp : USize) (timeoutMs : UInt32) : IO ByteArray

@[extern "orb_net_leaf_touch_excl_0600"]
private opaque rawTouchExcl0600 (path : @& String) : IO UInt64

/-- Create an exclusive owner-only (`0600`) regular file (`O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC`),
    rejecting embedded NUL bytes and symlink hijacking. -/
def createExclFile0600 (path : System.FilePath) : IO (Except String Unit) := do
  let s := path.toString
  if s.isEmpty || s.toUTF8.toList.any (· == 0) then
    return .error "invalid empty or NUL-containing path in createExclFile0600"
  let w ← rawTouchExcl0600 s
  if (w >>> 63) != 0 then
    return .error s!"failed to create exclusive 0600 file `{path}`"
  return .ok ()

/-- Close a live `TlsSession` deterministically (idempotent and mutex-safe across `Task`s). -/
def closeTlsSession (sess : TlsSession) : IO Unit :=
  rawTlsClose sess

/-- Write all bytes of `buf` onto a live `TlsSession` (mutex-synchronized). -/
def writeTlsSessionAll (sess : TlsSession) (buf : ByteArray) : IO Bool := do
  if buf.isEmpty then return true
  let rc ← rawTlsWrite sess buf
  return rc == 1

/-- Outcome of reading one decrypted record/chunk from a `TlsSession`. -/
inductive TlsReadOutcome where
  | chunk (bytes : ByteArray)
  | closeNotify
  | tcpEof
  | timeout
  | transportError

/-- Read up to `maxChunk` (`1..65536`) decrypted bytes from a live `TlsSession`.
    `rcvTimeoutMs`: `0` = keep current socket timeout, `0xFFFFFFFF` = clear `SO_RCVTIMEO` (no idle read timeout),
    `1..0xFFFFFFFE` = update `SO_RCVTIMEO` to `rcvTimeoutMs` ms before reading. -/
def readTlsSessionChunk
    (sess : TlsSession) (maxChunk : Nat := 16384) (rcvTimeoutMs : UInt32 := 0) : IO TlsReadOutcome := do
  let raw ← rawTlsRead sess (USize.ofNat (Nat.min (Nat.max maxChunk 1) 65536)) rcvTimeoutMs
  if verifySliceBounds 0 1 raw.size.toUInt64 != 1 then
    return .transportError
  let tag := raw.get! 0
  if tag == 0 then
    return .chunk (raw.extract 1 raw.size)
  else if tag == 1 then
    return .closeNotify
  else if tag == 4 then
    return .tcpEof
  else if tag == 5 then
    return .timeout
  else
    return .transportError

structure HttpsResponse where
  status  : Nat
  headers : Array (String × String)
  body    : ByteArray
  deriving Inhabited

def isBodylessHttpResponse (method : String) (statusCode : Nat) : Bool :=
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
    RFC 9112 visible ASCII without URL fragment `#` (`0x21..0x7E`, `c != 0x23`). -/
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

private def isAsciiAlphaNum (c : UInt8) : Bool :=
  (0x41 ≤ c && c ≤ 0x5A) || (0x61 ≤ c && c ≤ 0x7A) || (0x30 ≤ c && c ≤ 0x39)

private def isDnsHostByte (c : UInt8) : Bool :=
  isAsciiAlphaNum c || c == 0x2D || c == 0x2E || c == 0x5F

private def isIpv6LiteralByte (c : UInt8) : Bool :=
  (0x30 ≤ c && c ≤ 0x39) || (0x41 ≤ c && c ≤ 0x46) ||
  (0x61 ≤ c && c ≤ 0x66) || c == 0x3A || c == 0x2E

/-- Validate a bare DNS hostname or IPv4/IPv6 literal (`0` URI authority delimiters,
    forbidding leading/trailing `.` or `-`, `".."` empty labels, `":::"`, and bare punctuation). -/
def isValidBareHost (host : String) : Bool := Id.run do
  if host.isEmpty then
    return false
  let b := host.toUTF8
  let cap := b.size.toUInt64
  if host.contains ':' then
    if b.size < 2 || b.size > 45 then
      return false
    let first := b.get! 0
    let second := b.get! 1
    let last := b.get! (b.size - 1)
    let penult := b.get! (b.size - 2)
    if (first == 0x3A && second != 0x3A) || (last == 0x3A && penult != 0x3A) then
      return false
    let mut colonRun : Nat := 0
    let mut i : Nat := 0
    while verifySliceBounds i.toUInt64 1 cap == 1 do
      let c := b.get! i
      if !isIpv6LiteralByte c then
        return false
      if c == 0x3A then
        colonRun := colonRun + 1
        if colonRun > 2 then
          return false
      else
        colonRun := 0
      i := i + 1
    return true
  else
    if b.size > 253 then
      return false
    let first := b.get! 0
    let last := b.get! (b.size - 1)
    if first == 0x2D || first == 0x2E || last == 0x2D || last == 0x2E then
      return false
    let mut hasAlphaNum := false
    let mut prevDot := false
    let mut i : Nat := 0
    while verifySliceBounds i.toUInt64 1 cap == 1 do
      let c := b.get! i
      if !isDnsHostByte c then
        return false
      if isAsciiAlphaNum c then
        hasAlphaNum := true
      if c == 0x2E then
        if prevDot then
          return false
        prevDot := true
      else
        prevDot := false
      i := i + 1
    return hasAlphaNum

/-- Format RFC 9110 §7.2 `Host` / `:authority` from a validated bare `host` and `port`
    (wrapping IPv6 literals in `[...]` and appending `:port` when `port != defaultPort`). -/
def formatHostAuthority (host : String) (port : UInt16) (defaultPort : UInt16 := 443) : String :=
  let hostLit := if host.contains ':' then s!"[{host}]" else host
  if port == defaultPort then hostLit else s!"{hostLit}:{port}"

/-- Validate an RFC 9110 §7.2 `Host` / `:authority` string (`host`, `[ipv6]`, `host:port`, or `[ipv6]:port`). -/
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

/-- Build a smuggling-safe HTTP/1.1 outbound wire request. -/
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
    if hk.isEmpty || !isHttpToken hk || hasNoCrLfOrNul hv != 1 || hasHttpFieldControlByte hv then
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

/-- Open a verified WebPKI TLS 1.3/1.2 HTTP/1.1 streaming session (`ALPN "http/1.1"`),
    sending a smuggling-safe HTTP/1.1 request gated by `OrbNetLeaf.Spec.verifyOutboundRequest`. -/
def openHttps11Stream
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (verifyPeer : Bool := true)
    (timeoutMs : UInt32 := 10000)
    (initialHeadCapBytes : Nat := 65536) : IO (Except String TlsSession) := do
  let noCrLf := if isValidBareHost host && hasNoCrLfOrNul host == 1 then (1 : UInt8) else 0
  let vpFlag : UInt8 := if verifyPeer then 1 else 0
  let hostAuth := formatHostAuthority host port 443
  let reqWire ← match buildOutboundHttp11Request method hostAuth path headers body with
    | .ok w => pure w
    | .error e => return .error e
  if verifyOutboundRequest noCrLf vpFlag port.toUInt32
      host.toUTF8.size.toUInt64 reqWire.size.toUInt64 initialHeadCapBytes.toUInt64 != 1 then
    return .error "openHttps11Stream rejected by verifyOutboundRequest"
  match ← rawTlsOpen host port reqWire vpFlag 0 timeoutMs with
  | .ok sess => return .ok sess
  | .failed | .alpnNotH2 => return .error s!"TLS stream connection failed to {host}:{port}"

/-- Drain a live `TlsSession` in linear $O(N)$ time (`Array ByteArray` chunk accumulation + single flatten)
    up to `maxWireCap` bytes into `[statusByte || wireBytes]` (`1` = `close_notify`, `2` = cap exceeded, `4` = TCP EOF). -/
private def drainTlsSessionToFramed (sess : TlsSession) (maxWireCap : Nat) (rcvTimeoutMs : UInt32 := 0) : IO ByteArray := do
  let mut chunks : Array ByteArray := #[]
  let mut got : Nat := 0
  let mut status : UInt8 := 3
  let mut failed := false
  let mut firstRead := true
  try
    while status == 3 && !failed do
      if got > maxWireCap then
        status := 2
      else
        let stepCap := Nat.min 16384 ((maxWireCap + 1) - got)
        let tmo : UInt32 := if firstRead then rcvTimeoutMs else 0
        firstRead := false
        match ← readTlsSessionChunk sess stepCap tmo with
        | .chunk c =>
          chunks := chunks.push c
          got := got + c.size
          if got > maxWireCap then
            status := 2
        | .closeNotify => status := 1
        | .tcpEof => status := 4
        | .timeout | .transportError => failed := true
  finally
    closeTlsSession sess
  if failed then
    return ByteArray.empty
  return Id.run do
    let mut out := ByteArray.emptyWithCapacity (1 + got)
    out := out.push status
    for c in chunks do
      out := out ++ c
    return out

/-- Strip only RFC 9110 §5.6.3 optional whitespace (`SP` `0x20` and `HTAB` `0x09`),
    never `\r`, `\n`, `\x0b`, or `\x0c`. -/
def trimHttpOws (s : String) : String :=
  let isOws := fun (c : Char) => c == ' ' || c == '\t'
  ((s.dropWhile isOws).dropEndWhile isOws).toString

/-- Parse a single HTTP status + header block (`without` trailing `\r\n\r\n`). -/
def parseHttpHeaderBlock (hdrStr : String) (allowNonChunkedTe : Bool := false) :
    Except String (Nat × Array (String × String) × Bool × Bool × Option Nat) := do
  let lines := hdrStr.splitOn "\r\n"
  let statusLine :: rawFields := lines
    | throw "missing HTTP status line"
  if hasNoCrLfOrNul statusLine != 1 || hasHttpFieldControlByte statusLine then
    throw "HTTP status line contains bare CR/LF or control bytes"
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
      if hasNoCrLfOrNul line != 1 || hasHttpFieldControlByte line then
        throw "HTTP header line contains bare CR/LF or control bytes"
      if verifySliceBounds parsedHeaders.size.toUInt64 1 128 != 1 then
        throw "HTTP response exceeds 128 headers"
      match line.splitOn ":" with
      | [] | [_] => throw s!"malformed HTTP header line `{line}`"
      | hk :: rest =>
        let k := hk
        let rawVal := String.intercalate ":" rest
        let v := trimHttpOws rawVal
        if k.isEmpty || !isHttpToken k || hasNoCrLfOrNul v != 1 || hasHttpFieldControlByte v then
          throw s!"invalid HTTP response header `{k}`"
        if asciiEqIgnoreCase k "transfer-encoding" then
          let toks := (v.splitOn ",").map trimHttpOws |>.filter (!·.isEmpty)
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

/-- Parse a bounded HTTP/1.x wire response (`status`, `headers`, `Content-Length` or `chunked` `body`). -/
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

/-- Incremental Sans-I/O RFC 9112 §7.1 HTTP/1.1 `Transfer-Encoding: chunked` stream decoder state. -/
inductive ChunkedStreamState where
  | readSizeLine (lineBuf : ByteArray := ByteArray.empty)
  | readData (remaining : Nat)
  | readPostDataCr
  | readPostDataLf
  | readTrailers (trlBuf : ByteArray := ByteArray.empty)
  | finished
  deriving Inhabited

private def parseChunkHexLine? (lineBytes : ByteArray) : Option Nat := do
  -- Line ends just before `\r\n`; strip optional `;chunk-ext` (RFC 9112 §7.1.1)
  let mut semiIdx := lineBytes.size
  for i in [0:lineBytes.size] do
    let c := lineBytes.get! i
    guard (c != 0x00 && c != 0x0A && c != 0x0D)
    if c == 0x3B && semiIdx == lineBytes.size then
      semiIdx := i
  let mut s := 0
  let mut e := semiIdx
  while s < e && (lineBytes.get! s == 0x20 || lineBytes.get! s == 0x09) do
    s := s + 1
  while e > s && (lineBytes.get! (e - 1) == 0x20 || lineBytes.get! (e - 1) == 0x09) do
    e := e - 1
  if s >= e || e - s > 8 then
    none
  else Id.run do
    let mut val : Nat := 0
    for i in [s:e] do
      let c := lineBytes.get! i
      let nib? : Option Nat :=
        if 0x30 ≤ c && c ≤ 0x39 then some (c - 0x30).toNat
        else if 0x41 ≤ c && c ≤ 0x46 then some ((c - 0x41).toNat + 10)
        else if 0x61 ≤ c && c ≤ 0x66 then some ((c - 0x61).toNat + 10)
        else none
      match nib? with
      | some d => val := (val <<< 4) ||| d
      | none => return none
    if val > 16777216 then
      return none
    return some val

/-- Feed one raw wire `chunk` into `ChunkedStreamState`, emitting `(decodedPayload, nextState, isFinished)`
    or failing closed on malformed chunk framing / trailers. -/
def stepChunkedStream (st0 : ChunkedStreamState) (input : ByteArray) :
    Except String (ByteArray × ChunkedStreamState × Bool) := do
  let mut st := st0
  let mut out := ByteArray.empty
  let mut pos : Nat := 0
  while pos < input.size do
    match st with
    | .finished =>
      pos := input.size
    | .readSizeLine lineBuf =>
      let b := input.get! pos
      pos := pos + 1
      let lb := lineBuf.push b
      if lb.size > 256 then
        throw "chunked size line exceeds 256-byte cap"
      if lb.size >= 2 && lb.get! (lb.size - 2) == 0x0D && lb.get! (lb.size - 1) == 0x0A then
        let rawLine := lb.extract 0 (lb.size - 2)
        let some sz := parseChunkHexLine? rawLine
          | throw "malformed hexadecimal HTTP/1.1 chunk size"
        if sz == 0 then
          st := .readTrailers ByteArray.empty
        else
          st := .readData sz
      else
        st := .readSizeLine lb
    | .readData rem =>
      let avail := input.size - pos
      let take := Nat.min rem avail
      out := out ++ input.extract pos (pos + take)
      pos := pos + take
      if rem == take then
        st := .readPostDataCr
      else
        st := .readData (rem - take)
    | .readPostDataCr =>
      if input.get! pos != 0x0D then
        throw "missing CR after HTTP/1.1 chunk payload"
      pos := pos + 1
      st := .readPostDataLf
    | .readPostDataLf =>
      if input.get! pos != 0x0A then
        throw "missing LF after HTTP/1.1 chunk payload"
      pos := pos + 1
      st := .readSizeLine ByteArray.empty
    | .readTrailers trlBuf =>
      let b := input.get! pos
      pos := pos + 1
      if b == 0x0A && (trlBuf.isEmpty || trlBuf.get! (trlBuf.size - 1) != 0x0D) then
        throw "bare LF in HTTP/1.1 chunked trailer block"
      if !trlBuf.isEmpty && trlBuf.get! (trlBuf.size - 1) == 0x0D && b != 0x0A then
        throw "bare CR in HTTP/1.1 chunked trailer block"
      let tb := trlBuf.push b
      if tb.size > 16384 then
        throw "HTTP/1.1 chunked trailer section exceeds 16 KiB cap"
      if tb.size == 2 && tb.get! 0 == 0x0D && tb.get! 1 == 0x0A then
        st := .finished
      else
        match LeanSys.Http.findHeaderEnd? tb with
        | none => st := .readTrailers tb
        | some endIdx =>
          let trlBytes := tb.extract 0 (endIdx - 4)
          let some trlStr := String.fromUTF8? trlBytes
            | throw "non-UTF8 HTTP/1.1 chunked trailers"
          for ln in trlStr.splitOn "\r\n" do
            if !ln.isEmpty then
              if OrbNetLeaf.TlsHttp.hasNoCrLfOrNul ln != 1 || LeanSys.Http.hasHttpFieldControlByte ln then
                throw "HTTP/1.1 trailer line contains bare CR/LF or control bytes"
              match ln.splitOn ":" with
              | [] | [_] => throw "malformed HTTP/1.1 trailer line"
              | hk :: rest =>
                let k := hk
                let v := OrbNetLeaf.TlsHttp.trimHttpOws (String.intercalate ":" rest)
                if k.isEmpty || !LeanSys.Http.isHttpToken k ||
                   OrbNetLeaf.TlsHttp.hasNoCrLfOrNul v != 1 || LeanSys.Http.hasHttpFieldControlByte v then
                  throw "invalid HTTP/1.1 trailer field"
          st := .finished
  let isDone := match st with | .finished => true | _ => false
  return (out, st, isDone)

/-- Extract `(status, headers, isChunked, contentLen?, rawBodyTail)` from a raw byte buffer,
    validating headers via `OrbNetLeaf.TlsHttp.parseHttpHeaderBlock` (`allowNonChunkedTe = false`),
    skipping up to 8 `1xx` informational blocks, and rejecting `101 Switching Protocols` or colon-less headers. -/
def extractStreamingResponseHeadEx? (buf : ByteArray) :
    Except String (Option (Nat × Array (String × String) × Bool × Option Nat × ByteArray)) := do
  let mut cursor := buf
  let mut infoCount : Nat := 0
  while true do
    match LeanSys.Http.findHeaderEnd? cursor with
    | none =>
      if cursor.size > 65536 then
        throw "upstream HTTP response header block exceeds 64 KiB cap"
      return none
    | some bodyStart =>
      if bodyStart > 65536 then
        throw "upstream HTTP response header block exceeds 64 KiB cap"
      let hdrBytes := cursor.extract 0 (bodyStart - 4)
      let some hdrStr := String.fromUTF8? hdrBytes
        | throw "non-UTF8 upstream HTTP response headers"
      let (statusNat, parsedHdrs, _hasTe, isPureChunked, contentLen?) ←
        OrbNetLeaf.TlsHttp.parseHttpHeaderBlock hdrStr false
      let rest := cursor.extract bodyStart cursor.size
      if statusNat == 101 then
        throw "unexpected 101 Switching Protocols in upstream stream"
      else if 100 ≤ statusNat && statusNat < 200 then
        if infoCount ≥ 8 then
          throw "too many 1xx informational HTTP responses"
        infoCount := infoCount + 1
        cursor := rest
      else
        return some (statusNat, parsedHdrs, isPureChunked, contentLen?, rest)
  return none

/-- Extract `(status, headers, rawBodyTail)` from a raw byte buffer. -/
def extractStreamingResponseHead? (buf : ByteArray) :
    Except String (Option (Nat × Array (String × String) × ByteArray)) := do
  match ← extractStreamingResponseHeadEx? buf with
  | none => return none
  | some (statusNat, parsedHdrs, _, _, rest) => return some (statusNat, parsedHdrs, rest)

/-- Decode a status-prefixed TLS roundtrip buffer (`1` = `close_notify`, `2` = cap exceeded, `4` = TCP EOF). -/
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

/-- Execute a verified WebPKI TLS 1.3/1.2 HTTP/1.1 roundtrip (`ALPN "http/1.1"`). -/
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
  let connectTimeoutMs : UInt32 := if timeoutMs == 0 || timeoutMs > 15000 then 15000 else timeoutMs
  let .ok sess ← rawTlsOpen host port reqWire vpFlag 0 connectTimeoutMs
    | return .error s!"TLS roundtrip failed to {host}:{port}"
  let framed ← drainTlsSessionToFramed sess maxWireCap timeoutMs
  if framed.isEmpty then
    return .error s!"TLS read failed from {host}:{port}"
  return decodeTlsRoundtripWire framed maxRespBytes method

/-! ## Native RFC 9113 HTTP/2 (`LeanSys.H2` + `OrbNetLeaf.HpackQpack`) Client -/

/-- Validate and normalize pseudo-headers + application headers for HTTP/2 and HTTP/3 requests. -/
def buildPseudoAndAppHeaders
    (method authority path : String) (headers : Array (String × String))
    (bodyLen : Nat) : Except String (Array (String × String)) := do
  if method.isEmpty || !isHttpToken method then
    throw s!"invalid HTTP method `{method}`"
  if !isValidRequestTarget path then
    throw s!"invalid HTTP request target `{path}`"
  if !isValidHostChars authority || hasNoCrLfOrNul authority != 1 then
    throw "invalid HTTP :authority"
  let mut out : Array (String × String) := #[
    (":method", method),
    (":path", path),
    (":scheme", "https"),
    (":authority", authority)
  ]
  let mut hasCl := false
  for (hk, hv) in headers do
    if hasNoCrLfOrNul hv != 1 || hasHttpFieldControlByte hv then
      throw s!"invalid outbound header `{hk}`"
    let tv := trimHttpOws hv
    if hk.isEmpty || !isHttpToken hk || !isValidModernHeaderValue tv then
      throw s!"invalid outbound header `{hk}`"
    let low := hk.toLower
    if low == "host" || low == "connection" || low == "transfer-encoding" ||
       low == "upgrade" || low == "keep-alive" || low == "proxy-connection" || low.startsWith ":" then
      throw s!"forbidden HTTP/2 or HTTP/3 connection/pseudo header `{hk}`"
    if low == "content-length" then
      if hasCl then
        throw "duplicate outbound content-length header"
      match parseStrictContentLength? tv with
      | some declaredLen =>
        if declaredLen != bodyLen then
          throw s!"outbound content-length ({declaredLen}) does not match body size ({bodyLen})"
        hasCl := true
      | none =>
        throw s!"invalid outbound content-length `{hv}`"
    out := out.push (low, tv)
  if !hasCl && bodyLen > 0 then
    out := out.push ("content-length", toString bodyLen)
  return out

/-- Validate decoded HPACK/QPACK response header fields (`:status`, lowercase token names,
    RFC 9113 §8.2.1 / RFC 9110 §5.5 control-byte & whitespace hygiene, `<= 128` fields,
    forbidding connection-specific headers, and extracting any declared `content-length`). -/
def validateDecodedHeaderFields (proto : String) (fields : Array (String × String)) :
    Except String (Nat × Array (String × String) × Option Nat) := do
  let mut statusOpt : Option Nat := none
  let mut sawPseudoDone := false
  let mut appHeaders : Array (String × String) := #[]
  let mut contentLen? : Option Nat := none
  for (k, v) in fields do
    if hasNoCrLfOrNul k != 1 || !isValidModernHeaderValue v then
      throw s!"{proto} header contains forbidden control bytes or leading/trailing whitespace"
    if k.startsWith ":" then
      if sawPseudoDone then
        throw s!"{proto} pseudo-header `{k}` appeared after regular header"
      if k != ":status" then
        throw s!"{proto} unexpected response pseudo-header `{k}`"
      if statusOpt.isSome then
        throw s!"{proto} duplicate :status pseudo-header"
      let some code := parseStrictContentLength? v
        | throw s!"invalid {proto} :status `{v}`"
      if code < 100 || code > 599 then
        throw s!"out-of-range {proto} :status {code}"
      statusOpt := some code
    else
      sawPseudoDone := true
      if verifySliceBounds appHeaders.size.toUInt64 1 128 != 1 then
        throw s!"{proto} response exceeds 128 headers"
      if k.isEmpty || !isHttpToken k || k != k.toLower then
        throw s!"invalid or non-lowercase {proto} response header `{k}`"
      if k == "connection" || k == "transfer-encoding" || k == "keep-alive" ||
         k == "upgrade" || k == "proxy-connection" ||
         (k == "te" && v != "trailers") then
        throw s!"forbidden connection-specific {proto} header `{k}`"
      if k == "content-length" then
        match parseStrictContentLength? v with
        | some cl =>
          if contentLen?.isSome && contentLen? != some cl then
            throw s!"conflicting duplicate {proto} content-length headers"
          contentLen? := some cl
        | none =>
          throw s!"invalid {proto} content-length `{v}`"
      appHeaders := appHeaders.push (k, v)
  let some statusCode := statusOpt
    | throw s!"{proto} response missing :status pseudo-header"
  return (statusCode, appHeaders, contentLen?)

def validateTrailerFields (proto : String) (fields : Array (String × String)) : Except String Unit := do
  if verifySliceBounds fields.size.toUInt64 0 128 != 1 then
    throw s!"{proto} trailer section exceeds 128 fields"
  for (tk, tv) in fields do
    if tk.startsWith ":" || tk.isEmpty || !isHttpToken tk || tk != tk.toLower || !isValidModernHeaderValue tv then
      throw s!"invalid {proto} trailer field `{tk}`"
    if tk == "connection" || tk == "transfer-encoding" || tk == "keep-alive" ||
       tk == "upgrade" || tk == "proxy-connection" || tk == "content-length" || tk == "te" then
      throw s!"forbidden {proto} trailer field `{tk}`"

/-- Encode HPACK header block into `HEADERS` + `0..N` `CONTINUATION` frames (`<= maxFrameSize` each). -/
def encodeH2HeadersWithContinuation
    (streamId : UInt32) (hpackBlock : ByteArray) (endStream : Bool)
    (maxFrameSize : Nat := 16384) : Except String ByteArray := do
  let mfs32 := maxFrameSize.toUInt32
  if hpackBlock.size <= maxFrameSize then
    let fl : UInt8 := 0x04 ||| (if endStream then 0x01 else 0x00)
    let some f := encodeFrame? { frameType := .headers, flags := fl, streamId := streamId, payload := hpackBlock } mfs32
      | throw "failed to encode HTTP/2 HEADERS frame"
    return f
  else
    let firstChunk := hpackBlock.extract 0 maxFrameSize
    let firstFlags : UInt8 := if endStream then 0x01 else 0x00
    let some firstFrame := encodeFrame? {
        frameType := .headers, flags := firstFlags, streamId := streamId, payload := firstChunk
      } mfs32
      | throw "failed to encode initial HTTP/2 HEADERS fragment"
    let mut wire := firstFrame
    let mut off := maxFrameSize
    while off < hpackBlock.size do
      let fragLen := Nat.min maxFrameSize (hpackBlock.size - off)
      let isLast := off + fragLen == hpackBlock.size
      let cFlags : UInt8 := if isLast then 0x04 else 0x00
      let frag := hpackBlock.extract off (off + fragLen)
      let some cFrame := encodeFrame? {
          frameType := .continuation, flags := cFlags, streamId := streamId, payload := frag
        } mfs32
        | throw "failed to encode HTTP/2 CONTINUATION fragment"
      wire := wire ++ cFrame
      off := off + fragLen
    return wire

/-- Encode an outbound HTTP/2 initial flight (`clientPreface` + `SETTINGS` + connection `WINDOW_UPDATE`
    + `HEADERS`/`CONTINUATION` + up to `initialWindowCap` `DATA` bytes, returning `(wireBytes, sentBodyBytes)`). -/
def buildOutboundH2InitialBurst
    (method authority path : String)
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (initialWindowCap : Nat := 65535) : Except String (ByteArray × Nat) := do
  let allHdrs ← buildPseudoAndAppHeaders method authority path headers body.size
  -- Advertise HEADER_TABLE_SIZE=0, ENABLE_PUSH=0, INITIAL_WINDOW_SIZE=16 MiB (16777216)
  let some settingsFrame := buildSettingsFrame? #[(0x0001, 0), (0x0002, 0), (0x0004, 16777216)] false
    | throw "failed to encode HTTP/2 SETTINGS frame"
  -- Raise connection window from 65535 to 16777216 (`65535 + 16711681 = 16777216`)
  let some winFrame := buildWindowUpdateFrame? 0 16711681
    | throw "failed to encode HTTP/2 WINDOW_UPDATE frame"
  let hpackBlock := encodeHeadersBlock allHdrs
  let hdrFrames ← encodeH2HeadersWithContinuation 1 hpackBlock body.isEmpty 16384
  let mut wire := clientPreface ++ settingsFrame ++ winFrame ++ hdrFrames
  let sendLimit := Nat.min body.size initialWindowCap
  let mut off := 0
  while off < sendLimit do
    let chunkLen := Nat.min 16384 (sendLimit - off)
    let isFinalBody := (off + chunkLen == body.size)
    let dFlags : UInt8 := if isFinalBody then 0x01 else 0x00
    let chunk := body.extract off (off + chunkLen)
    let some dFrame := encodeFrame? {
        frameType := .data, flags := dFlags, streamId := 1, payload := chunk
      } 16384 (Nat.max sendLimit 65535).toUInt64
      | throw "failed to encode HTTP/2 DATA frame"
    wire := wire ++ dFrame
    off := off + chunkLen
  return (wire, sendLimit)

/-- Build a complete Sans-I/O outbound RFC 9113 HTTP/2 client stream burst (`body.size ≤ peerInitialWindow`,
    defaulting to the RFC 9113 §6.9.2 `65535`-byte initial flow-control window). -/
def buildOutboundH2PrefaceAndStream
    (method authority path : String)
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (peerInitialWindow : Nat := 65535) : Except String ByteArray := do
  if body.size > peerInitialWindow then
    throw s!"HTTP/2 request body ({body.size} B) exceeds peer initial flow-control window ({peerInitialWindow} B); use interactive http2Request"
  let (wire, _) ← buildOutboundH2InitialBurst method authority path headers body peerInitialWindow
  return wire

/-- Validate RFC 9113 §6.5.2 inbound `SETTINGS` payload parameters, returning any updated `INITIAL_WINDOW_SIZE`. -/
def validatePeerSettingsPayload (flags : UInt8) (payload : ByteArray) : Except String (Option Nat) := do
  if (flags &&& 0x01) != 0 then
    if !payload.isEmpty then
      throw "HTTP/2 SETTINGS ACK frame with non-empty payload"
    return none
  if payload.size % 6 != 0 then
    throw "HTTP/2 SETTINGS payload length not a multiple of 6"
  let mut newInitWin? : Option Nat := none
  let count := payload.size / 6
  for i in [0:count] do
    let base := i * 6
    let id : UInt16 := ((payload.get! base).toUInt16 <<< 8) ||| (payload.get! (base + 1)).toUInt16
    let v0 := (payload.get! (base + 2)).toUInt32
    let v1 := (payload.get! (base + 3)).toUInt32
    let v2 := (payload.get! (base + 4)).toUInt32
    let v3 := (payload.get! (base + 5)).toUInt32
    let val : UInt32 := (v0 <<< 24) ||| (v1 <<< 16) ||| (v2 <<< 8) ||| v3
    if id == 0x0002 && val > 1 then
      throw "HTTP/2 SETTINGS_ENABLE_PUSH > 1"
    else if id == 0x0004 then
      if val > 0x7FFFFFFF then
        throw "HTTP/2 SETTINGS_INITIAL_WINDOW_SIZE exceeds 2^31-1"
      newInitWin? := some val.toNat
    else if id == 0x0005 && (val < 16384 || val > 16777215) then
      throw s!"HTTP/2 SETTINGS_MAX_FRAME_SIZE out of range ({val})"
  return newInitWin?

def parseGoawayPayload (payload : ByteArray) : Except String (UInt32 × UInt32) := do
  if verifySliceBounds 0 8 payload.size.toUInt64 != 1 then
    throw "HTTP/2 GOAWAY frame shorter than 8 bytes"
  let s0 := (payload.get! 0).toUInt32 &&& 0x7F
  let s1 := (payload.get! 1).toUInt32
  let s2 := (payload.get! 2).toUInt32
  let s3 := (payload.get! 3).toUInt32
  let lastSid := (s0 <<< 24) ||| (s1 <<< 16) ||| (s2 <<< 8) ||| s3
  let e0 := (payload.get! 4).toUInt32
  let e1 := (payload.get! 5).toUInt32
  let e2 := (payload.get! 6).toUInt32
  let e3 := (payload.get! 7).toUInt32
  let errCode := (e0 <<< 24) ||| (e1 <<< 16) ||| (e2 <<< 8) ||| e3
  return (lastSid, errCode)

def enforceBodylessAndLengthInvariants
    (proto requestMethod : String) (statusCode : Nat)
    (respHeaders : Array (String × String))
    (contentLen? : Option Nat) (bodyAccum : ByteArray) : Except String HttpsResponse := do
  if isBodylessHttpResponse requestMethod statusCode then
    if !bodyAccum.isEmpty then
      throw s!"{proto} bodyless response (method={requestMethod}, status={statusCode}) carried non-empty DATA payload ({bodyAccum.size} B)"
    if statusCode == 204 && contentLen?.isSome && contentLen? != some 0 then
      throw s!"{proto} 204 No Content response carried non-zero content-length"
    return { status := statusCode, headers := respHeaders, body := ByteArray.empty }
  if let some cl := contentLen? then
    if bodyAccum.size != cl then
      throw s!"{proto} response body size ({bodyAccum.size}) mismatches content-length ({cl})"
  return { status := statusCode, headers := respHeaders, body := bodyAccum }

/-- Decode an inbound RFC 9113 HTTP/2 server frame stream on `targetStreamId`, requiring
    authenticated `END_STREAM` (`0x01`), full RFC 7541 HPACK (static 1..61 + dynamic + Huffman),
    connection-wide `CONTINUATION` lock, graceful `GOAWAY(NO_ERROR)` support, and strict bodyless checks. -/
def parseH2ResponseFrames
    (raw : ByteArray) (targetStreamId : UInt32 := 1)
    (maxBodyBytes : Nat := 16777216)
    (requestMethod : String := "GET") : Except String HttpsResponse := do
  let initRecvWin := Nat.max 16777216 (maxBodyBytes + 65536)
  let mut st : H2ConnState := { maxFrameSize := 16384, connRecvWindow := initRecvWin.toUInt64, connSendWindow := 65535 }
  let mut hpackTbl : HpackDecoderTable := {}
  let fullSrc := ByteSource.ofByteArray raw
  let mut off := 0
  let mut hdrAccum := ByteArray.empty
  let mut awaitingContStream? : Option UInt32 := none
  let mut pendingEndStream := false
  let mut sawFinalStatus := false
  let mut sawTrailers := false
  let mut infoCount : Nat := 0
  let mut statusCode : Nat := 0
  let mut respHeaders : Array (String × String) := #[]
  let mut contentLen? : Option Nat := none
  let mut bodyAccum := ByteArray.empty
  let mut endStream := false
  while off < raw.size && !endStream do
    let some remSrc := fullSrc.subSource? off (raw.size - off)
      | throw "HTTP/2 frame slice bounds error"
    let (decRes, st') := stepInboundFrame st remSrc
    st := st'
    match decRes with
    | .needMoreBytes => throw "truncated HTTP/2 frame on wire"
    | .protocolError reason => throw s!"HTTP/2 protocol error: {reason}"
    | .ok frame consumed =>
      off := off + consumed
      if let some expectedContSid := awaitingContStream? then
        if frame.frameType != .continuation || frame.streamId != expectedContSid then
          throw "HTTP/2 connection-level CONTINUATION lock violated"
      match frame.frameType with
      | .pushPromise =>
        throw "HTTP/2 server PUSH_PROMISE forbidden (SETTINGS_ENABLE_PUSH=0)"
      | .settings =>
        discard <| validatePeerSettingsPayload frame.flags frame.payload
      | .headers =>
        let padded := (frame.flags &&& 0x08) != 0
        let hasPrio := (frame.flags &&& 0x20) != 0
        let minHdr := (if padded then 1 else 0) + (if hasPrio then 5 else 0)
        if verifySliceBounds 0 minHdr.toUInt64 frame.payload.size.toUInt64 != 1 then
          throw "HTTP/2 HEADERS frame truncated before pad/priority header"
        let padLen := if padded then (frame.payload.get! 0).toNat else 0
        if verifySliceBounds minHdr.toUInt64 padLen.toUInt64 frame.payload.size.toUInt64 != 1 then
          throw "HTTP/2 HEADERS pad length exceeds payload"
        let fragLen := frame.payload.size - minHdr - padLen
        let frameHasEndHeaders := (frame.flags &&& 0x04) != 0
        let frameHasEndStream := (frame.flags &&& 0x01) != 0
        if hdrAccum.size + fragLen > 65536 then
          throw "HTTP/2 header block exceeds 64 KiB cap"
        hdrAccum := hdrAccum ++ frame.payload.extract minHdr (minHdr + fragLen)
        if !frameHasEndHeaders then
          awaitingContStream? := some frame.streamId
          if frame.streamId == targetStreamId then
            if sawTrailers then throw "HTTP/2 unexpected HEADERS after trailers"
            if sawFinalStatus && !frameHasEndStream then throw "HTTP/2 trailing HEADERS missing END_STREAM"
            pendingEndStream := frameHasEndStream
        else
          awaitingContStream? := none
          let some (fields, hpackTbl') := decodeRfc7541BlockWithTable? hpackTbl (ByteSource.ofByteArray hdrAccum)
            | throw "HTTP/2 HPACK header block decode failed"
          hpackTbl := hpackTbl'
          hdrAccum := ByteArray.empty
          if frame.streamId == targetStreamId then
            if sawTrailers then
              throw "HTTP/2 unexpected HEADERS after trailers"
            if sawFinalStatus then
              if !frameHasEndStream then
                throw "HTTP/2 trailing HEADERS missing END_STREAM"
              validateTrailerFields "HTTP/2" fields
              sawTrailers := true
            else
              let (code, hdrs, cl?) ← validateDecodedHeaderFields "HTTP/2" fields
              if code >= 100 && code < 200 then
                if code == 101 || frameHasEndStream then
                  throw "HTTP/2 invalid 1xx informational response"
                if infoCount >= 8 then
                  throw "HTTP/2 too many 1xx informational responses"
                infoCount := infoCount + 1
              else
                sawFinalStatus := true
                statusCode := code
                respHeaders := hdrs
                contentLen? := cl?
            if frameHasEndStream then
              endStream := true
      | .continuation =>
        if awaitingContStream?.isNone then
          throw "HTTP/2 unexpected CONTINUATION frame"
        if hdrAccum.size + frame.payload.size > 65536 then
          throw "HTTP/2 header block exceeds 64 KiB cap"
        hdrAccum := hdrAccum ++ frame.payload
        if (frame.flags &&& 0x04) != 0 then
          awaitingContStream? := none
          let some (fields, hpackTbl') := decodeRfc7541BlockWithTable? hpackTbl (ByteSource.ofByteArray hdrAccum)
            | throw "HTTP/2 HPACK continuation decode failed"
          hpackTbl := hpackTbl'
          hdrAccum := ByteArray.empty
          if frame.streamId == targetStreamId then
            let es := pendingEndStream
            pendingEndStream := false
            if sawFinalStatus then
              if !es then throw "HTTP/2 trailing HEADERS+CONTINUATION missing END_STREAM"
              validateTrailerFields "HTTP/2" fields
              sawTrailers := true
            else
              let (code, hdrs, cl?) ← validateDecodedHeaderFields "HTTP/2" fields
              if code >= 100 && code < 200 then
                if code == 101 || es then
                  throw "HTTP/2 invalid 1xx informational response"
                if infoCount >= 8 then
                  throw "HTTP/2 too many 1xx informational responses"
                infoCount := infoCount + 1
              else
                sawFinalStatus := true
                statusCode := code
                respHeaders := hdrs
                contentLen? := cl?
            if es then
              endStream := true
      | .data =>
        if frame.streamId == targetStreamId then
          if !sawFinalStatus || sawTrailers then
            throw "HTTP/2 DATA frame outside response body phase"
          let padded := (frame.flags &&& 0x08) != 0
          let dStart := if padded then 1 else 0
          if verifySliceBounds 0 dStart.toUInt64 frame.payload.size.toUInt64 != 1 then
            throw "HTTP/2 DATA frame truncated before pad length"
          let padLen := if padded then (frame.payload.get! 0).toNat else 0
          if verifySliceBounds dStart.toUInt64 padLen.toUInt64 frame.payload.size.toUInt64 != 1 then
            throw "HTTP/2 DATA pad length exceeds payload"
          let dLen := frame.payload.size - dStart - padLen
          if bodyAccum.size + dLen > maxBodyBytes then
            throw "HTTP/2 response body exceeds maxBodyBytes"
          bodyAccum := bodyAccum ++ frame.payload.extract dStart (dStart + dLen)
          if (frame.flags &&& 0x01) != 0 then
            endStream := true
      | .rstStream =>
        if frame.streamId == targetStreamId then
          throw "HTTP/2 peer reset stream (RST_STREAM)"
      | .goaway =>
        let (lastSid, errCode) ← parseGoawayPayload frame.payload
        if errCode != 0 || lastSid < targetStreamId then
          throw s!"HTTP/2 peer aborted stream via GOAWAY (lastStreamId={lastSid}, err={errCode})"
      | _ => pure ()
  if awaitingContStream?.isSome || !sawFinalStatus || !endStream then
    throw "incomplete HTTP/2 response stream (missing END_STREAM)"
  enforceBodylessAndLengthInvariants "HTTP/2" requestMethod statusCode respHeaders contentLen? bodyAccum

def h2SettingsAckFrame : ByteArray :=
  ByteArray.mk #[0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00]

def buildH2PingAckFrame (payload8 : ByteArray) : ByteArray :=
  (ByteArray.mk #[0x00, 0x00, 0x08, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00]) ++ payload8

/-- Outcome of attempting to open a persistent HTTP/2 session (`ALPN "h2"`). -/
inductive H2ConnectOutcome where
  | ok (sess : TlsSession)
  | alpnFallbackH1
  | transportError (msg : String)

/-- Open a persistent WebPKI TLS 1.3/1.2 HTTP/2 connection (`ALPN "h2"`), sending the RFC 9113
    client preface + `SETTINGS` (`HEADER_TABLE_SIZE=0`, `ENABLE_PUSH=0`, `INITIAL_WINDOW_SIZE=16 MiB`)
    + connection `WINDOW_UPDATE` (`+16,711,681` -> `16 MiB` window), gated by `verifyOutboundRequest`. -/
def openH2PersistentSessionOutcome
    (host : String) (port : UInt16 := 443)
    (verifyPeer : Bool := true)
    (connectTimeoutMs : UInt32 := 10000) : IO H2ConnectOutcome := do
  let noCrLf := if isValidBareHost host && hasNoCrLfOrNul host == 1 then (1 : UInt8) else 0
  let vpFlag : UInt8 := if verifyPeer then 1 else 0
  let some settingsFrame := buildSettingsFrame? #[(0x0001, 0), (0x0002, 0), (0x0004, 16777216)] false
    | return .transportError "failed to encode HTTP/2 SETTINGS frame"
  let some winFrame := buildWindowUpdateFrame? 0 16711681
    | return .transportError "failed to encode HTTP/2 WINDOW_UPDATE frame"
  let initWire := clientPreface ++ settingsFrame ++ winFrame
  if verifyOutboundRequest noCrLf vpFlag port.toUInt32
      host.toUTF8.size.toUInt64 initWire.size.toUInt64 65536 != 1 then
    return .transportError "openH2PersistentSession rejected by verifyOutboundRequest"
  match ← rawTlsOpen host port initWire vpFlag 1 connectTimeoutMs with
  | .ok sess => return .ok sess
  | .alpnNotH2 => return .alpnFallbackH1
  | .failed => return .transportError s!"TLS connect failed to {host}:{port}"

def openH2PersistentSession
    (host : String) (port : UInt16 := 443)
    (verifyPeer : Bool := true)
    (connectTimeoutMs : UInt32 := 10000) : IO (Except String TlsSession) := do
  match ← openH2PersistentSessionOutcome host port verifyPeer connectTimeoutMs with
  | .ok sess => return .ok sess
  | .alpnFallbackH1 => return .error s!"TLS ALPN h2 not negotiated by {host}:{port}"
  | .transportError msg => return .error msg

/-- Execute a verified interactive RFC 9113 HTTP/2 request over WebPKI TLS 1.3/1.2 with ALPN `"h2"`:
    - Sends `SETTINGS` ACK (`0x01`) and `PING` ACK (`0x01`) interactively via `writeTlsSessionAll`.
    - Respects the server's `65535`-byte initial flow-control window on large request bodies (`> 64 KiB`),
      streaming remaining `DATA` frames as peer `SETTINGS` / `WINDOW_UPDATE` credits arrive.
    - Replenishes connection & stream receive windows dynamically via `WINDOW_UPDATE` so multi-megabyte
      responses up to `maxRespBytes` never stall.
    - Scans inbound frames incrementally in linear $O(N)$ time and closes cleanly as soon as Stream 1
      completes (`END_STREAM`) after all request body bytes are sent. -/
def http2Request
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 4194304)
    (verifyPeer : Bool := true)
    (timeoutMs : UInt32 := 30000) : IO (Except String HttpsResponse) := do
  let noCrLf := if isValidBareHost host && hasNoCrLfOrNul host == 1 then (1 : UInt8) else 0
  let vpFlag : UInt8 := if verifyPeer then 1 else 0
  let hostAuth := formatHostAuthority host port 443
  let (initialWire, initSentBody) ← match buildOutboundH2InitialBurst method hostAuth path headers body 65535 with
    | .ok r => pure r
    | .error e => return .error e
  let estTotalReqBytes := initialWire.size + (body.size - initSentBody)
  if verifyOutboundRequest noCrLf vpFlag port.toUInt32
      host.toUTF8.size.toUInt64 estTotalReqBytes.toUInt64 maxRespBytes.toUInt64 != 1 then
    return .error "http2Request rejected by verifyOutboundRequest"
  let maxWireCap := maxRespBytes + 131072
  let .ok sess ← rawTlsOpen host port initialWire vpFlag 1 timeoutMs
    | return .error s!"TLS ALPN h2 handshake failed to {host}:{port}"
  let mut rxChunks : Array ByteArray := #[]
  let mut totalRxBytes : Nat := 0
  let mut pendingBuf := ByteArray.empty
  let mut pendingOff : Nat := 0
  let mut awaitingContSid? : Option UInt32 := none
  let mut pendingEnd := false
  let mut streamEnded := false
  let mut fatalWireErr? : Option String := none
  let mut capExceeded := false
  let mut transportErr := false
  let mut sentBody : Nat := initSentBody
  let mut peerInitWin : Int := 65535
  let mut peerConnWin : Int := (65535 : Int) - (initSentBody : Int)
  let mut peerStreamWin : Int := (65535 : Int) - (initSentBody : Int)
  let mut unackedRecvData : Nat := 0
  try
    while !streamEnded && fatalWireErr?.isNone && !capExceeded && !transportErr do
      -- Flush any remaining outbound request body bytes allowed by peer's flow-control window
      while !streamEnded && sentBody < body.size && peerConnWin > 0 && peerStreamWin > 0 && fatalWireErr?.isNone && !transportErr do
        let minWin : Int := if peerConnWin < peerStreamWin then peerConnWin else peerStreamWin
        let availWin := minWin.toNat
        let chunkLen := Nat.min 16384 (Nat.min availWin (body.size - sentBody))
        if chunkLen == 0 then
          break
        let isLast := (sentBody + chunkLen == body.size)
        let dFlags : UInt8 := if isLast then 0x01 else 0x00
        let chunk := body.extract sentBody (sentBody + chunkLen)
        match encodeFrame? { frameType := .data, flags := dFlags, streamId := 1, payload := chunk } 16384 chunkLen.toUInt64 with
        | none => fatalWireErr? := some "failed to encode follow-up HTTP/2 DATA frame"
        | some dFrame =>
          if !(← writeTlsSessionAll sess dFrame) then
            transportErr := true
          else
            sentBody := sentBody + chunkLen
            peerConnWin := peerConnWin - (chunkLen : Int)
            peerStreamWin := peerStreamWin - (chunkLen : Int)
      if !streamEnded && fatalWireErr?.isNone && !transportErr then
        let stepCap := Nat.min 16384 ((maxWireCap + 1) - totalRxBytes)
        match ← readTlsSessionChunk sess stepCap 0 with
        | .chunk c =>
          rxChunks := rxChunks.push c
          totalRxBytes := totalRxBytes + c.size
          if totalRxBytes > maxWireCap then
            capExceeded := true
          else
            pendingBuf := pendingBuf ++ c
            -- Incrementally inspect newly completed frames (`O(N)` cursor `pendingOff`)
            let mut scanMore := true
            while scanMore && fatalWireErr?.isNone && !transportErr do
              if pendingBuf.size - pendingOff < 9 then
                scanMore := false
              else
                let b0 := (pendingBuf.get! pendingOff).toNat
                let b1 := (pendingBuf.get! (pendingOff + 1)).toNat
                let b2 := (pendingBuf.get! (pendingOff + 2)).toNat
                let payLen := (b0 <<< 16) ||| (b1 <<< 8) ||| b2
                if payLen > 16384 then
                  fatalWireErr? := some "HTTP/2 frame exceeds 16384 maxFrameSize"
                else if pendingBuf.size - pendingOff < 9 + payLen then
                  scanMore := false
                else
                  let ty := pendingBuf.get! (pendingOff + 3)
                  let fl := pendingBuf.get! (pendingOff + 4)
                  let s0 := (pendingBuf.get! (pendingOff + 5)).toUInt32 &&& 0x7F
                  let s1 := (pendingBuf.get! (pendingOff + 6)).toUInt32
                  let s2 := (pendingBuf.get! (pendingOff + 7)).toUInt32
                  let s3 := (pendingBuf.get! (pendingOff + 8)).toUInt32
                  let sid := (s0 <<< 24) ||| (s1 <<< 16) ||| (s2 <<< 8) ||| s3
                  let pay := pendingBuf.extract (pendingOff + 9) (pendingOff + 9 + payLen)
                  pendingOff := pendingOff + 9 + payLen
                  -- Enforce connection-wide CONTINUATION lock immediately
                  if awaitingContSid?.isSome && (ty != 9 || awaitingContSid? != some sid) then
                    fatalWireErr? := some "HTTP/2 connection-level CONTINUATION lock violated"
                  -- Reply to SETTINGS with SETTINGS ACK & apply INITIAL_WINDOW_SIZE delta
                  else if ty == 4 && sid == 0 then
                    match validatePeerSettingsPayload fl pay with
                    | .error e => fatalWireErr? := some e
                    | .ok newWin? =>
                      if (fl &&& 0x01) == 0 then
                        if let some nw := newWin? then
                          let delta : Int := (nw : Int) - peerInitWin
                          peerInitWin := (nw : Int)
                          peerStreamWin := peerStreamWin + delta
                        if !(← writeTlsSessionAll sess h2SettingsAckFrame) then
                          transportErr := true
                  -- Reply to non-ACK PING with PING ACK
                  else if ty == 6 && sid == 0 && (fl &&& 0x01) == 0 && pay.size == 8 then
                    if !(← writeTlsSessionAll sess (buildH2PingAckFrame pay)) then
                      transportErr := true
                  -- Apply peer WINDOW_UPDATE credits
                  else if ty == 8 && pay.size == 4 then
                    let w0 := (pay.get! 0).toUInt32 &&& 0x7F
                    let w1 := (pay.get! 1).toUInt32
                    let w2 := (pay.get! 2).toUInt32
                    let w3 := (pay.get! 3).toUInt32
                    let inc := (w0 <<< 24) ||| (w1 <<< 16) ||| (w2 <<< 8) ||| w3
                    if inc == 0 then
                      fatalWireErr? := some "HTTP/2 zero WINDOW_UPDATE increment"
                    else if sid == 0 then
                      peerConnWin := peerConnWin + (inc.toNat : Int)
                      if peerConnWin > (0x7FFFFFFF : Int) then
                        fatalWireErr? := some "HTTP/2 connection send window overflow"
                    else if sid == 1 then
                      peerStreamWin := peerStreamWin + (inc.toNat : Int)
                      if peerStreamWin > (0x7FFFFFFF : Int) then
                        fatalWireErr? := some "HTTP/2 stream send window overflow"
                  -- Track RST_STREAM / GOAWAY / Stream 1 completion / inbound DATA window replenishment
                  else if ty == 3 && sid == 1 then
                    fatalWireErr? := some "HTTP/2 peer reset stream (RST_STREAM)"
                  else if ty == 7 then
                    match parseGoawayPayload pay with
                    | .error e => fatalWireErr? := some e
                    | .ok (lastSid, errCode) =>
                      if errCode != 0 || lastSid < 1 then
                        fatalWireErr? := some s!"HTTP/2 peer aborted stream via GOAWAY (lastStreamId={lastSid}, err={errCode})"
                  else if ty == 1 then
                    let es := (fl &&& 0x01) != 0
                    let eh := (fl &&& 0x04) != 0
                    if !eh then
                      awaitingContSid? := some sid
                      if sid == 1 then pendingEnd := es
                    else
                      awaitingContSid? := none
                      if sid == 1 && es then streamEnded := true
                  else if ty == 9 && awaitingContSid? == some sid then
                    if (fl &&& 0x04) != 0 then
                      awaitingContSid? := none
                      if sid == 1 then
                        if pendingEnd then streamEnded := true
                        pendingEnd := false
                  else if ty == 0 then
                    unackedRecvData := unackedRecvData + payLen
                    if sid == 1 && (fl &&& 0x01) != 0 then
                      streamEnded := true
                    if !streamEnded && unackedRecvData >= 4194304 then
                      if let (some wuConn, some wuStrm) :=
                          (buildWindowUpdateFrame? 0 unackedRecvData.toUInt32,
                           buildWindowUpdateFrame? 1 unackedRecvData.toUInt32) then
                        if !(← writeTlsSessionAll sess (wuConn ++ wuStrm)) then
                          transportErr := true
                        else
                          unackedRecvData := 0
            -- Amortized O(N) compaction of `pendingBuf`
            if pendingOff >= 32768 && pendingOff * 2 >= pendingBuf.size then
              pendingBuf := pendingBuf.extract pendingOff pendingBuf.size
              pendingOff := 0
        | .closeNotify | .tcpEof =>
          break
        | .timeout | .transportError =>
          transportErr := true
  finally
    closeTlsSession sess
  if capExceeded then
    return .error s!"HTTP/2 TLS response exceeded maxRespBytes budget ({maxRespBytes})"
  if let some ferr := fatalWireErr? then
    return .error ferr
  if transportErr then
    return .error s!"HTTP/2 TLS transport error with {host}:{port}"
  let fullWire := Id.run do
    let mut out := ByteArray.emptyWithCapacity totalRxBytes
    for c in rxChunks do
      out := out ++ c
    return out
  return parseH2ResponseFrames fullWire 1 maxRespBytes method

/-! ## Native RFC 9000/9001/9114 QUIC + HTTP/3 (`LeanSys.Quic` + `LeanSys.H3` + `OrbNetLeaf.HpackQpack`) -/

/-- Immutable cryptographic key material for an authenticated 1-RTT QUIC + HTTP/3 peer. -/
structure Quic1RttSessionKeys where
  dcid    : UInt64
  aeadAlg : AeadAlg := .aes128Gcm
  hpAlg   : QuicHpAlg := .aes128Ecb
  txKey   : ByteArray
  txIv12  : ByteArray
  txHpKey : ByteArray
  rxKey   : ByteArray
  rxIv12  : ByteArray
  rxHpKey : ByteArray

/-- Mutable per-session QUIC 1-RTT monotonic TX packet counter, bidirectional client stream ID (`0, 4, 8, ...`),
    and RX anti-replay / flow-control window state (`QuicConnState`). -/
structure Quic1RttLiveState where
  nextTxPktNum       : UInt64 := 0
  nextClientStreamId : UInt64 := 0
  connSt             : QuicConnState := {}

/-- Thread-safe stateful 1-RTT QUIC + HTTP/3 session (`Std.Mutex`-synchronized) that atomically
    advances `nextTxPktNum` & `nextClientStreamId` *before* transmitting any packet (preventing
    AEAD nonce reuse across calls, retries, timeouts, and concurrent `Task`s) and persists `connSt`
    anti-replay state across requests. -/
structure Quic1RttSession where
  keys : Quic1RttSessionKeys
  mu   : Std.Mutex Quic1RttLiveState

/-- Create a fresh stateful `Quic1RttSession` from `keys`. -/
def mkQuic1RttSession
    (keys : Quic1RttSessionKeys)
    (initialTxPktNum : UInt64 := 0)
    (initialClientStreamId : UInt64 := 0) : IO Quic1RttSession := do
  let mu ← Std.Mutex.new {
    nextTxPktNum := initialTxPktNum
    nextClientStreamId := initialClientStreamId
    connSt := {}
  }
  return { keys := keys, mu := mu }

/-- Inspect the current `(nextTxPktNum, nextClientStreamId, connSt)` snapshot of a `Quic1RttSession`. -/
def inspectQuic1RttSession (sess : Quic1RttSession) : IO Quic1RttLiveState :=
  sess.mu.atomically (get)

/-- Encode an RFC 9000 §19.8 `STREAM` frame. -/
def encodeQuicStreamFrame?
    (streamId offset : UInt64) (streamData : ByteArray) (fin : Bool := true) :
    Option ByteArray := do
  let frameTy : UInt8 := if fin then 0x0F else 0x0E
  let sidBytes ← encodeVarInt? streamId
  let offBytes ← encodeVarInt? offset
  let lenBytes ← encodeVarInt? streamData.size.toUInt64
  return (ByteArray.mk #[frameTy]) ++ sidBytes ++ offBytes ++ lenBytes ++ streamData

/-- Decode one RFC 9000 §19.8 `STREAM` frame (`0x08..0x0F`) at `pos` in `src`. -/
def decodeQuicStreamFrame? (src : ByteSource) (pos : Nat := 0) :
    Option (UInt64 × UInt64 × ByteArray × Bool × Nat) := do
  let tSub ← src.subSource? pos 1
  let ty := tSub.getByteD 0
  if ty < 0x08 || ty > 0x0F then
    none
  else
    let hasOff := (ty &&& 0x04) != 0
    let hasLen := (ty &&& 0x02) != 0
    let fin := (ty &&& 0x01) != 0
    let (sid, p1) ← decodeVarInt? src (pos + 1)
    let (offVal, p2) ← if hasOff then decodeVarInt? src p1 else some (0, p1)
    let (dLen, p3) ←
      if hasLen then
        let (l, afterL) ← decodeVarInt? src p2
        some (l.toNat, afterL)
      else
        some (src.size - p2, p2)
    let dSub ← src.subSource? p3 dLen
    some (sid, offVal, dSub.toByteArray, fin, p3 + dLen)

/-- Walk all RFC 9000 §12.4 frames inside a decrypted 1-RTT QUIC payload:
    - Skips valid control/acknowledgment frames (`PADDING`, `PING`, `ACK`/`ACK_ECN`, `MAX_DATA`,
      `MAX_STREAM_DATA`, `MAX_STREAMS`, `*_BLOCKED`, `NEW_CONNECTION_ID`, `RETIRE_CONNECTION_ID`,
      `PATH_CHALLENGE`, `PATH_RESPONSE`, `HANDSHAKE_DONE`, `NEW_TOKEN`, `CRYPTO`).
    - Rejects `RESET_STREAM`, `CONNECTION_CLOSE`, unknown/truncated frames, unexpected stream IDs,
      non-contiguous `STREAM` offsets, or missing `FIN`. -/
def extractQuic1RttStreamPayload
    (payload : ByteArray) (expectedStreamId : UInt64 := 0)
    (maxStreamBytes : Nat := 65536) : Except String ByteArray := do
  let src := ByteSource.ofByteArray payload
  let mut pos : Nat := 0
  let mut assembled := ByteArray.empty
  let mut sawFin := false
  while pos < src.size do
    let some tSub := src.subSource? pos 1
      | throw "QUIC payload slice bounds error"
    let ty := tSub.getByteD 0
    if ty == 0x00 || ty == 0x01 || ty == 0x1e then
      -- PADDING (0x00), PING (0x01), HANDSHAKE_DONE (0x1e)
      pos := pos + 1
    else if ty == 0x02 || ty == 0x03 then
      -- ACK / ACK_ECN (§19.3)
      let some (_, p1) := decodeVarInt? src (pos + 1) | throw "truncated QUIC ACK frame"
      let some (_, p2) := decodeVarInt? src p1 | throw "truncated QUIC ACK delay"
      let some (rcnt, p3) := decodeVarInt? src p2 | throw "truncated QUIC ACK range count"
      let some (_, p4) := decodeVarInt? src p3 | throw "truncated QUIC first ACK range"
      if rcnt.toNat > src.size then throw "oversized QUIC ACK range count"
      let mut cur := p4
      for _ in [0:rcnt.toNat] do
        let some (_, pa) := decodeVarInt? src cur | throw "truncated QUIC ACK gap"
        let some (_, pb) := decodeVarInt? src pa | throw "truncated QUIC ACK range"
        cur := pb
      if ty == 0x03 then
        let some (_, e1) := decodeVarInt? src cur | throw "truncated QUIC ECN ECT0"
        let some (_, e2) := decodeVarInt? src e1 | throw "truncated QUIC ECN ECT1"
        let some (_, e3) := decodeVarInt? src e2 | throw "truncated QUIC ECN CE"
        cur := e3
      pos := cur
    else if ty == 0x04 then
      throw "QUIC peer sent RESET_STREAM"
    else if ty == 0x05 then
      let some (sid, p1) := decodeVarInt? src (pos + 1) | throw "truncated QUIC STOP_SENDING"
      let some (_, p2) := decodeVarInt? src p1 | throw "truncated QUIC STOP_SENDING code"
      if sid == expectedStreamId then
        throw "QUIC peer sent STOP_SENDING on active stream"
      pos := p2
    else if ty == 0x06 then
      let some (_, p1) := decodeVarInt? src (pos + 1) | throw "truncated QUIC CRYPTO offset"
      let some (clen, p2) := decodeVarInt? src p1 | throw "truncated QUIC CRYPTO length"
      let some _ := src.subSource? p2 clen.toNat | throw "truncated QUIC CRYPTO data"
      pos := p2 + clen.toNat
    else if ty == 0x07 then
      let some (tlen, p1) := decodeVarInt? src (pos + 1) | throw "truncated QUIC NEW_TOKEN length"
      let some _ := src.subSource? p1 tlen.toNat | throw "truncated QUIC NEW_TOKEN data"
      pos := p1 + tlen.toNat
    else if 0x08 ≤ ty && ty ≤ 0x0F then
      let some (sid, offVal, chunk, fin, nextPos) := decodeQuicStreamFrame? src pos
        | throw "malformed QUIC STREAM frame"
      if sid != expectedStreamId then
        throw s!"unexpected QUIC stream ID {sid} (expected {expectedStreamId})"
      if sawFin then
        throw "duplicate QUIC STREAM frame after FIN"
      if offVal.toNat != assembled.size then
        throw s!"non-contiguous QUIC STREAM offset {offVal} (expected {assembled.size})"
      if assembled.size + chunk.size > maxStreamBytes then
        throw "QUIC STREAM payload exceeds maxStreamBytes"
      assembled := assembled ++ chunk
      if fin then
        sawFin := true
      pos := nextPos
    else if ty == 0x10 || ty == 0x12 || ty == 0x13 || ty == 0x14 ||
            ty == 0x16 || ty == 0x17 || ty == 0x19 then
      let some (_, p1) := decodeVarInt? src (pos + 1) | throw "truncated QUIC flow-control/CID frame"
      pos := p1
    else if ty == 0x11 || ty == 0x15 then
      let some (_, p1) := decodeVarInt? src (pos + 1) | throw "truncated QUIC stream flow-control frame"
      let some (_, p2) := decodeVarInt? src p1 | throw "truncated QUIC stream flow-control limit"
      pos := p2
    else if ty == 0x18 then
      -- NEW_CONNECTION_ID (§19.15)
      let some (_, p1) := decodeVarInt? src (pos + 1) | throw "truncated QUIC NEW_CONNECTION_ID seq"
      let some (_, p2) := decodeVarInt? src p1 | throw "truncated QUIC NEW_CONNECTION_ID retire"
      let some lenSub := src.subSource? p2 1 | throw "truncated QUIC NEW_CONNECTION_ID len"
      let cidLen := (lenSub.getByteD 0).toNat
      if cidLen < 1 || cidLen > 20 then throw "invalid QUIC NEW_CONNECTION_ID length"
      let some _ := src.subSource? (p2 + 1) (cidLen + 16) | throw "truncated QUIC NEW_CONNECTION_ID body"
      pos := p2 + 1 + cidLen + 16
    else if ty == 0x1a || ty == 0x1b then
      -- PATH_CHALLENGE / PATH_RESPONSE (§19.17–19.18): 8-byte payload
      let some _ := src.subSource? (pos + 1) 8 | throw "truncated QUIC PATH frame"
      pos := pos + 9
    else if ty == 0x1c || ty == 0x1d then
      throw "QUIC peer sent CONNECTION_CLOSE"
    else
      throw s!"unsupported or malformed QUIC 1-RTT frame type 0x{String.ofList (Nat.toDigits 16 ty.toNat)}"
  if !sawFin then
    throw "QUIC 1-RTT response missing STREAM frame with FIN"
  return assembled

/-- Decode an RFC 9114 HTTP/3 bidirectional response payload (`HEADERS` `0x01` + `DATA` `0x00` capsules)
    using `OrbNetLeaf.HpackQpack.decodeRfc9204Block?` (all 99 static entries + name-ref + Huffman + `String.fromUTF8?`). -/
def parseH3ResponseStream
    (raw : ByteArray) (maxBodyBytes : Nat := 16777216)
    (requestMethod : String := "GET") :
    Except String HttpsResponse := do
  let fullSrc := ByteSource.ofByteArray raw
  let mut off := 0
  let mut sawFinalStatus := false
  let mut sawTrailers := false
  let mut infoCount : Nat := 0
  let mut statusCode : Nat := 0
  let mut respHeaders : Array (String × String) := #[]
  let mut contentLen? : Option Nat := none
  let mut bodyAccum := ByteArray.empty
  while off < raw.size do
    let some remSrc := fullSrc.subSource? off (raw.size - off)
      | throw "HTTP/3 capsule slice bounds error"
    match decodeCapsulePrefix remSrc .bidiRequest with
    | .needMoreBytes => throw "truncated HTTP/3 frame capsule"
    | .frameError reason => throw s!"HTTP/3 frame error: {reason}"
    | .ok cap consumed =>
      off := off + consumed
      if cap.frameType == 0x01 then
        if sawTrailers then
          throw "HTTP/3 unexpected HEADERS capsule after trailers"
        if cap.payload.size > 65536 then
          throw "HTTP/3 QPACK header block exceeds 64 KiB cap"
        let some fields := decodeRfc9204Block? (ByteSource.ofByteArray cap.payload)
          | throw "HTTP/3 QPACK header section decode failed"
        if sawFinalStatus then
          validateTrailerFields "HTTP/3" fields
          sawTrailers := true
        else
          let (code, hdrs, cl?) ← validateDecodedHeaderFields "HTTP/3" fields
          if code >= 100 && code < 200 then
            if code == 101 then
              throw "HTTP/3 forbids 101 Switching Protocols"
            if infoCount >= 8 then
              throw "HTTP/3 too many 1xx informational responses"
            infoCount := infoCount + 1
          else
            sawFinalStatus := true
            statusCode := code
            respHeaders := hdrs
            contentLen? := cl?
      else if cap.frameType == 0x00 then
        if !sawFinalStatus || sawTrailers then
          throw "HTTP/3 DATA capsule outside response body phase"
        if bodyAccum.size + cap.payload.size > maxBodyBytes then
          throw "HTTP/3 response body exceeds maxBodyBytes"
        bodyAccum := bodyAccum ++ cap.payload
      else
        pure ()
  if !sawFinalStatus then
    throw "missing HTTP/3 response HEADERS capsule"
  enforceBodylessAndLengthInvariants "HTTP/3" requestMethod statusCode respHeaders contentLen? bodyAccum

/-- Build an authenticated, header-protected 1-RTT QUIC datagram carrying an RFC 9114 HTTP/3 request. -/
def buildProtectedH3RequestDatagram
    (keys : Quic1RttSessionKeys) (pktNum : UInt64)
    (method authority path : String)
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (streamId : UInt64 := 0) : IO (Except String ByteArray) := do
  let allHdrs ← match buildPseudoAndAppHeaders method authority path headers body.size with
    | .ok h => pure h
    | .error e => return .error e
  let some h3StreamBytes := encodeH3Message? allHdrs body
    | return .error "failed to encode HTTP/3 QPACK/DATA capsules"
  let some quicStreamFrame := encodeQuicStreamFrame? streamId 0 h3StreamBytes true
    | return .error "failed to encode QUIC STREAM frame"
  sealQuicShortPacket keys.aeadAlg keys.hpAlg keys.txKey keys.txIv12 keys.txHpKey
    { dcid := keys.dcid, pktNum := pktNum, keyPhase := false, payload := quicStreamFrame }

/-- Open, anti-replay-check, walk all RFC 9000 1-RTT frames, require `FIN` completion, and decode an
    inbound 1-RTT QUIC + HTTP/3 response datagram (`1..4`-byte PN supported). -/
def openProtectedH3ResponseDatagram
    (keys : Quic1RttSessionKeys) (connSt : QuicConnState)
    (wireDatagram : ByteArray) (expectedStreamId : UInt64 := 0)
    (maxBodyBytes : Nat := 65536)
    (requestMethod : String := "GET") : IO (Except String (HttpsResponse × QuicConnState)) := do
  let largestRx? : Option UInt64 := if connSt.hasRxPacket then some connSt.maxRxPktNum else none
  let pkt ← match ← openQuicShortPacketEx keys.aeadAlg keys.hpAlg
      keys.rxKey keys.rxIv12 keys.rxHpKey wireDatagram largestRx? with
    | .ok p => pure p
    | .error e => return .error e
  if pkt.dcid != keys.dcid then
    return .error "QUIC 1-RTT destination connection ID mismatch"
  let streamBytes ← match extractQuic1RttStreamPayload pkt.payload expectedStreamId (maxBodyBytes + 65536) with
    | .ok sb => pure sb
    | .error e => return .error e
  let endOff := streamBytes.size.toUInt64
  let some connSt' := admitStreamPacket? connSt pkt.pktNum expectedStreamId endOff
    | return .error "QUIC packet rejected by anti-replay or flow-control window gate"
  match parseH3ResponseStream streamBytes maxBodyBytes requestMethod with
  | .ok resp => return .ok (resp, connSt')
  | .error e => return .error e

/-- Execute a verified native single-datagram (`<= 64 KiB`) 1-RTT HTTP/3-over-QUIC UDP exchange
    over a stateful `Quic1RttSession`:
    - Atomically reserves and increments `(nextTxPktNum, nextClientStreamId)` *before* sealing/transmitting
      so no error, timeout, or concurrent `Task` can ever reuse an AEAD `(txKey, nonce)`.
    - Persists `connSt` (`maxRxPktNum`, `windowMask`, `connRecvBytes`) across requests so cross-request
      replayed UDP datagrams are deterministically rejected. -/
def http3Quic1RttRequest
    (sess : Quic1RttSession)
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 65536)
    (timeoutMs : UInt32 := 5000) : IO (Except String HttpsResponse) := do
  if maxRespBytes == 0 || maxRespBytes > 65536 then
    return .error s!"http3Quic1RttRequest single-datagram maxRespBytes ({maxRespBytes}) must be in 1..65536"
  let noCrLf := if isValidBareHost host && hasNoCrLfOrNul host == 1 then (1 : UInt8) else 0
  let hostAuth := formatHostAuthority host port 443
  -- Atomically reserve monotonic TX packet number and client bidi stream ID (0, 4, 8, ...) BEFORE sealing!
  let alloc? ← sess.mu.atomically do
    let st ← get
    if st.nextTxPktNum > maxVarInt || st.nextClientStreamId > maxVarInt - 4 then
      return none
    let txPn := st.nextTxPktNum
    let sid := st.nextClientStreamId
    set { st with nextTxPktNum := txPn + 1, nextClientStreamId := sid + 4 }
    return some (txPn, sid)
  let some (txPktNum, streamId) := alloc?
    | return .error "QUIC 1-RTT session packet number or stream ID space exhausted"
  let dgram ← match ← buildProtectedH3RequestDatagram sess.keys txPktNum method hostAuth path headers body streamId with
    | .ok d => pure d
    | .error e => return .error e
  if verifyOutboundRequest noCrLf 1 port.toUInt32
      host.toUTF8.size.toUInt64 dgram.size.toUInt64 maxRespBytes.toUInt64 != 1 then
    return .error "http3Quic1RttRequest rejected by verifyOutboundRequest"
  let rxWire ← rawUdpRoundtrip host port dgram (USize.ofNat maxRespBytes) timeoutMs
  if rxWire.isEmpty then
    return .error s!"QUIC UDP roundtrip timed out or failed to {host}:{port}"
  -- Serialize RX anti-replay window check & update under `sess.mu`
  sess.mu.atomically do
    let st ← get
    match ← openProtectedH3ResponseDatagram sess.keys st.connSt rxWire streamId maxRespBytes method with
    | .ok (resp, connSt') =>
      set { st with connSt := connSt' }
      return .ok resp
    | .error e =>
      return .error e

inductive HttpWireVersion where
  | http2
  | http3 (session? : Option Quic1RttSession := none)

instance : Inhabited HttpWireVersion := ⟨.http2⟩

/-- Unified verified native HTTP/2 & HTTP/3 outbound client (zero external `curl` or `libcurl`):
    - `.http2`: Interactive RFC 9113 HTTP/2 (`LeanSys.H2` + `OrbNetLeaf.HpackQpack`) over WebPKI TLS ALPN `"h2"`.
    - `.http3 (some sess)`: Stateful 1-RTT HTTP/3-over-QUIC UDP datagram exchange (`maxRespBytes` clamped to `<= 65536`,
      monotonic TX nonces & RX anti-replay enforced by `sess : Quic1RttSession`).
    - `.http3 none`: Alt-Svc fallback over verified native `http2Request` (`ALPN "h2"`). -/
def http2Or3Request
    (version : HttpWireVersion)
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 4194304)
    (timeoutSecs : Nat := 30) : IO (Except String HttpsResponse) := do
  let tMs : UInt32 := (Nat.min (if timeoutSecs == 0 then 1 else timeoutSecs) 300 * 1000).toUInt32
  match version with
  | .http2 =>
    http2Request method host port path headers body maxRespBytes true tMs
  | .http3 (some sess) =>
    let dgramCap := Nat.min (Nat.max maxRespBytes 1) 65536
    http3Quic1RttRequest sess method host port path headers body dgramCap tMs
  | .http3 none =>
    http2Request method host port path headers body maxRespBytes true tMs

end OrbNetLeaf.TlsHttp
