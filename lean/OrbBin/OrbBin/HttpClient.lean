/-
  OrbBin.HttpClient: Unified HTTP/1.1 & HTTPS Client over `LeanSys.Posix` + `OrbNetLeaf.TlsHttp` (`0 import Lean`).
  Supports `GET`, `POST`, `PUT`, `PATCH`, `DELETE` against both loopback/LAN `http://` and WebPKI `https://`,
  plus percent-encoding for query parameters and JSON request/response helpers.
-/
import LeanSys.Posix
import LeanSys.Http
import OrbNetLeaf.TlsHttp
import OrbBin.PosixExt
import OrbBin.Json

namespace OrbBin.HttpClient

open OrbNetLeaf.TlsHttp
open OrbBin.Json

structure ParsedUrl where
  isHttps    : Bool
  host       : String
  connectHost : String
  port       : UInt16
  hostHeader : String
  pathQuery  : String
  deriving Repr, BEq

def parseUrl (rawUrl : String) : Except String ParsedUrl := do
  let u := rawUrl.trimAscii.toString
  let (isHttps, rest) ←
    if u.startsWith "https://" then .ok (true, (u.drop 8).toString)
    else if u.startsWith "http://" then .ok (false, (u.drop 7).toString)
    else .error s!"URL must start with http:// or https://: `{u}`"
  let (authority, pq) :=
    match rest.splitOn "/" with
    | [] => (rest, "/")
    | a :: tail =>
      if tail.isEmpty then (a, "/")
      else (a, "/" ++ String.intercalate "/" tail)
  if authority.isEmpty then
    throw s!"URL has empty host: `{u}`"
  let defaultPort : UInt16 := if isHttps then 443 else 80
  let (host, port) ←
    if authority.startsWith "[" then
      match authority.splitOn "]" with
      | [hBracket, afterB] =>
        let ipv6 := (hBracket.drop 1).toString
        if afterB.isEmpty then .ok (ipv6, defaultPort)
        else if afterB.startsWith ":" then
          match (afterB.drop 1).toString.toNat? with
          | some p =>
            if 1 ≤ p && p ≤ 65535 then .ok (ipv6, p.toUInt16)
            else .error s!"invalid URL port in `{u}`"
          | none => .error s!"invalid URL port in `{u}`"
        else .error s!"invalid IPv6 authority in `{u}`"
      | _ => .error s!"malformed IPv6 authority in `{u}`"
    else
      match authority.splitOn ":" with
      | [h] => .ok (h, defaultPort)
      | [h, pStr] =>
        match pStr.toNat? with
        | some p =>
          if 1 ≤ p && p ≤ 65535 then .ok (h, p.toUInt16)
          else .error s!"invalid URL port `{pStr}` in `{u}`"
        | none => .error s!"invalid URL port `{pStr}` in `{u}`"
      | _ => .error s!"malformed authority in `{u}`"
  let connectHost :=
    if host == "localhost" || host == "::1" then "127.0.0.1" else host
  let hostHeader :=
    if (isHttps && port == 443) || (!isHttps && port == 80) then
      if host.contains ':' then s!"[{host}]" else host
    else
      if host.contains ':' then s!"[{host}]:{port}" else s!"{host}:{port}"
  return {
    isHttps
    host
    connectHost
    port
    hostHeader
    pathQuery := if pq.isEmpty then "/" else pq
  }

def urlEncodeComponent (s : String) : String := Id.run do
  let bytes := s.toUTF8
  let hex := "0123456789ABCDEF".toList.toArray
  let mut out : Array Char := Array.mkEmpty (bytes.size * 2)
  for i in [0:bytes.size] do
    let b := bytes.get! i
    let isUnreserved :=
      (0x41 ≤ b && b ≤ 0x5A) || (0x61 ≤ b && b ≤ 0x7A) ||
      (0x30 ≤ b && b ≤ 0x39) || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x7E
    if isUnreserved then
      out := out.push (Char.ofNat b.toNat)
    else
      out := out.push '%'
      out := out.push (hex[(b.toNat / 16) % 16]!)
      out := out.push (hex[b.toNat % 16]!)
  return String.ofList out.toList

/-- Execute a single HTTP/1.1 or HTTPS request (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`). -/
def sendRequest
    (method rawUrl : String)
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (timeoutMs : UInt32 := 30000)
    (maxRespBytes : Nat := 16777216) : IO (Except String HttpsResponse) := do
  let parsed ← match parseUrl rawUrl with
    | .ok p => pure p
    | .error e => return .error e
  if parsed.isHttps then
    httpsRequest method parsed.host parsed.port parsed.pathQuery headers body maxRespBytes true
  else
    let reqWire ← match buildOutboundHttp11Request method parsed.hostHeader parsed.pathQuery headers body with
      | .ok w => pure w
      | .error e => return .error e
    let fd ← match (← LeanSys.Posix.tcpConnect parsed.connectHost parsed.port) with
      | .ok f => pure f
      | .error e => return .error s!"HTTP connect failed to {parsed.connectHost}:{parsed.port}: {e}"
    try
      match (← LeanSys.Posix.writeAll fd reqWire) with
      | .error e =>
        let _ ← LeanSys.Posix.closeFd fd
        return .error s!"HTTP write failed to {parsed.connectHost}:{parsed.port}: {e}"
      | .ok _ => pure ()
      let mut respRaw := ByteArray.emptyWithCapacity 4096
      let mut cleanEof := false
      while true do
        match (← OrbBin.PosixExt.readSocketTimed fd 65536 timeoutMs) with
        | .eof =>
          cleanEof := true
          break
        | .timeout =>
          if respRaw.isEmpty then
            let _ ← LeanSys.Posix.closeFd fd
            return .error s!"HTTP read timed out after {timeoutMs}ms from {parsed.connectHost}:{parsed.port}"
          else
            break
        | .fatal code =>
          let _ ← LeanSys.Posix.closeFd fd
          return .error s!"HTTP read error ({code}) from {parsed.connectHost}:{parsed.port}"
        | .bytes chunk =>
          respRaw := respRaw ++ chunk
          if respRaw.size > maxRespBytes + 65536 then
            let _ ← LeanSys.Posix.closeFd fd
            return .error s!"HTTP response exceeded {maxRespBytes} bytes"
      let _ ← LeanSys.Posix.closeFd fd
      return parseHttpResponseWire respRaw maxRespBytes cleanEof method
    catch e =>
      let _ ← LeanSys.Posix.closeFd fd
      return .error s!"HTTP transport exception: {e}"

/-- Send an HTTP/HTTPS request with optional JSON body and optional Bearer token, returning `(status, rawBody, JVal?)`. -/
def sendJsonRequest
    (method rawUrl : String)
    (bearerToken : Option String := none)
    (jsonBody : Option JVal := none)
    (extraHeaders : Array (String × String) := #[])
    (timeoutMs : UInt32 := 30000) : IO (Except String (Nat × String × Option JVal)) := do
  let mut hdrs := extraHeaders
  if let some tok := bearerToken then
    if !tok.isEmpty then
      hdrs := hdrs.push ("Authorization", s!"Bearer {tok}")
  let bodyBytes ← match jsonBody with
    | some j =>
      hdrs := hdrs.push ("Content-Type", "application/json")
      pure (renderCompact j).toUTF8
    | none => pure ByteArray.empty
  match (← sendRequest method rawUrl hdrs bodyBytes timeoutMs) with
  | .error e => return .error e
  | .ok resp =>
    let text := (String.fromUTF8? resp.body).getD ""
    let parsedJson := match Json.parseBytes resp.body with
      | .ok j => some j
      | .error _ => none
    return .ok (resp.status, text, parsedJson)

end OrbBin.HttpClient
