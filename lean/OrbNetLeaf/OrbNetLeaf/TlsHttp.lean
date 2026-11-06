/-
  OrbNetLeaf.TlsHttp: Verified outbound HTTPS / HTTP/1.1 client over OpenSSL
  TLS 1.3/1.2 (`orb_net_leaf_tls_roundtrip`) + HTTP/2 / HTTP/3 (`curl --http2` / `--http3`
  fallback when `curl` is requested for multiplexed/QUIC upstream endpoints),
  with zero-copy response parsing strictly gated by `OrbNetLeaf.Spec` and `LeanSys.Spec`.
-/
import LeanSys.Spec
import LeanSys.Http
import LeanSys.Posix
import OrbNetLeaf.Spec

namespace OrbNetLeaf.TlsHttp

open LeanSys.Spec
open LeanSys.Http
open OrbNetLeaf.Spec

@[extern "orb_net_leaf_tls_roundtrip"]
private opaque rawTlsRoundtrip
    (host : @& String) (port : UInt16)
    (req : @& ByteArray) (maxResp : USize) (verifyPeer : UInt8) : IO ByteArray

structure HttpsResponse where
  status  : Nat
  headers : Array (String × String)
  body    : ByteArray
  deriving Inhabited

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

/-- Build a smuggling-safe HTTP/1.1 outbound wire request with validated header tokens & values. -/
def buildOutboundHttp11Request
    (method host path : String)
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty) : Except String ByteArray := do
  if method.isEmpty || !isHttpToken method then
    throw s!"invalid HTTP method `{method}`"
  if path.isEmpty || !path.startsWith "/" || hasNoCrLfOrNul path != 1 then
    throw s!"invalid HTTP request target `{path}`"
  if hasNoCrLfOrNul host != 1 then
    throw "hostname contains CR/LF/NUL"
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
      hasCl := true
    hdrBlock := hdrBlock ++ s!"{hk}: {hv}\r\n"
    idx := idx + 1
  if !hasCl && body.size > 0 then
    hdrBlock := hdrBlock ++ s!"Content-Length: {body.size}\r\n"
  hdrBlock := hdrBlock ++ "\r\n"
  return hdrBlock.toUTF8 ++ body

/-- Parse a bounded HTTP/1.x wire response (`status`, `headers`, `Content-Length` or `chunked` `body`),
    routing every slice boundary check through `LeanSys.Spec.verifySliceBounds`. -/
def parseHttpResponseWire (raw : ByteArray) (maxBodyBytes : Nat := 16777216) :
    Except String HttpsResponse := do
  let cap := raw.size.toUInt64
  if verifySliceBounds 0 12 cap != 1 then
    throw "truncated HTTP response status line"
  let some bodyStart := findHeaderEnd? raw
    | throw "unterminated HTTP response header block"
  if verifySliceBounds 0 bodyStart.toUInt64 cap != 1 ||
     verifySliceBounds 0 bodyStart.toUInt64 65536 != 1 then
    throw "HTTP response header block exceeds 64 KiB cap"
  let hdrBytes := raw.extract 0 (bodyStart - 4)
  let some hdrStr := String.fromUTF8? hdrBytes
    | throw "non-UTF8 HTTP response headers"
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
  let mut isChunked := false
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
        if asciiEqIgnoreCase k "transfer-encoding" &&
           (asciiEqIgnoreCase v "chunked" || ((v.splitOn ",").any fun t => asciiEqIgnoreCase t.trimAscii.toString "chunked")) then
          isChunked := true
        else if asciiEqIgnoreCase k "content-length" then
          match parseStrictContentLength? v with
          | some cl =>
            if contentLen?.isSome && contentLen? != some cl then
              throw "conflicting duplicate Content-Length headers"
            contentLen? := some cl
          | none => throw "invalid Content-Length response value"
        parsedHeaders := parsedHeaders.push (k, v)
  let remLen := raw.size - bodyStart
  if verifySliceBounds bodyStart.toUInt64 remLen.toUInt64 cap != 1 then
    throw "invalid HTTP response body slice"
  let rawBody := raw.extract bodyStart raw.size
  if isChunked then
    match decodeChunkedBody? rawBody maxBodyBytes with
    | some decoded =>
      return { status := statusCode, headers := parsedHeaders, body := decoded }
    | none => throw "malformed or oversized chunked HTTP response body"
  else
    match contentLen? with
    | some cl =>
      if verifySliceBounds 0 cl.toUInt64 rawBody.size.toUInt64 != 1 ||
         verifySliceBounds 0 cl.toUInt64 maxBodyBytes.toUInt64 != 1 then
        throw "HTTP response body truncated or exceeds maxBodyBytes"
      return { status := statusCode, headers := parsedHeaders, body := rawBody.extract 0 cl }
    | none =>
      if verifySliceBounds 0 rawBody.size.toUInt64 maxBodyBytes.toUInt64 != 1 then
        throw "HTTP response body exceeds maxBodyBytes"
      return { status := statusCode, headers := parsedHeaders, body := rawBody }

/-- Execute a verified WebPKI TLS 1.3/1.2 roundtrip (`orb_net_leaf_tls_roundtrip`),
    strictly gated by `OrbNetLeaf.Spec.verifyOutboundRequest`. -/
def httpsRequest
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 4194304)
    (verifyPeer : Bool := true) : IO (Except String HttpsResponse) := do
  let noCrLf := hasNoCrLfOrNul host
  let vpFlag : UInt8 := if verifyPeer then 1 else 0
  let reqWire ← match buildOutboundHttp11Request method host path headers body with
    | .ok w => pure w
    | .error e => return .error e
  if verifyOutboundRequest noCrLf vpFlag port.toUInt32
      host.toUTF8.size.toUInt64 reqWire.size.toUInt64 maxRespBytes.toUInt64 != 1 then
    return .error "httpsRequest rejected by verifyOutboundRequest"
  let rawResp ← rawTlsRoundtrip host port reqWire (USize.ofNat maxRespBytes) vpFlag
  if rawResp.isEmpty then
    return .error s!"TLS roundtrip failed to {host}:{port}"
  return parseHttpResponseWire rawResp maxRespBytes

inductive HttpWireVersion where
  | http2
  | http3
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Execute a verified outbound HTTP/2 or HTTP/3 request via `/usr/bin/curl` when multiplexed
    or QUIC transport is requested before Wave 5 native `LeanH2`/`LeanQuic`/`LeanH3` cutover,
    strictly gated by `OrbNetLeaf.Spec.verifyOutboundRequest` and parsed by `parseHttpResponseWire`. -/
def http2Or3RequestViaCurl
    (version : HttpWireVersion)
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 4194304)
    (timeoutSecs : Nat := 30) : IO (Except String HttpsResponse) := do
  let noCrLf := hasNoCrLfOrNul host
  let reqWire ← match buildOutboundHttp11Request method host path headers body with
    | .ok w => pure w
    | .error e => return .error e
  if verifyOutboundRequest noCrLf 1 port.toUInt32
      host.toUTF8.size.toUInt64 reqWire.size.toUInt64 maxRespBytes.toUInt64 != 1 then
    return .error "http2Or3RequestViaCurl rejected by verifyOutboundRequest"
  let verFlag := match version with
    | .http2 => "--http2"
    | .http3 => "--http3"
  let mut args : Array String := #[
    "--silent", "--show-error", "--include",
    "--max-time", toString (if timeoutSecs == 0 then 1 else timeoutSecs),
    "--max-filesize", toString maxRespBytes,
    verFlag, "-X", method
  ]
  for (hk, hv) in headers do
    args := args.push "-H"
    args := args.push s!"{hk}: {hv}"
  let url := s!"https://{host}:{port}{path}"
  args := args.push url
  let child ← IO.Process.spawn {
    cmd := "/usr/bin/curl"
    args := if body.isEmpty then args else args.push "--data-binary" |>.push "@-"
    stdin := .piped
    stdout := .piped
    stderr := .piped
  }
  if !body.isEmpty then
    child.stdin.write body
    child.stdin.flush
  let (_, child') ← child.takeStdin
  let mut outBytes := ByteArray.empty
  while true do
    let chunk ← child'.stdout.read 65536
    if chunk.isEmpty then break
    outBytes := outBytes ++ chunk
    if outBytes.size > maxRespBytes then
      return .error s!"curl ({verFlag}) response exceeded maxRespBytes {maxRespBytes}"
  let errStr ← child'.stderr.readToEnd
  let code ← child'.wait
  if code != 0 then
    return .error s!"curl ({verFlag}) exited with {code}: {errStr.trimAscii.toString}"
  return parseHttpResponseWire outBytes maxRespBytes

end OrbNetLeaf.TlsHttp
