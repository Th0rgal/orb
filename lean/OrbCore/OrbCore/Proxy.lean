/-
  OrbCore.Proxy: Verified `/v1/*` Multi-Provider LLM Proxy, Model-Routing Chain Resolver &
  Bounded Pre-First-Byte Failover Engine (`0 import Lean`, `0 sorryAx`).
-/
import OrbCore.Spec
import OrbCore.Store
import OrbNetLeaf.TlsHttp

namespace OrbCore.Proxy

open OrbCore.Spec
open OrbCore.Store
open OrbNetLeaf.TlsHttp

/-- Single upstream provider target inside a model-routing fallback chain. -/
structure ProviderTarget where
  accountId : String
  provider  : String
  baseUrl   : String
  apiKey    : String
  modelId   : String
  deriving Repr, DecidableEq, Inhabited

/-- Model-routing chain configuration (`/api/model-routing/chains`). -/
structure RoutingChain where
  id      : String
  name    : String
  targets : Array ProviderTarget
  deriving Repr, DecidableEq

/-- Upstream proxy attempt outcome. -/
structure ProxyOutcome where
  status           : Nat
  contentType      : String := "application/json"
  headers          : Array (String × String)
  body             : ByteArray
  selectedAccount  : String
  attemptsUsed     : Nat
  deriving Inhabited

private def isForbiddenResponseHeader (name : String) : Bool :=
  let low := name.trimAscii.toString.toLower
  low == "transfer-encoding" || low == "content-length" || low == "connection" ||
  low == "keep-alive" || low == "te" || low == "trailer" || low == "upgrade" ||
  low == "proxy-connection" || low == "content-type" ||
  low.startsWith "access-control-"

private def hasHeaderCtl (s : String) : Bool :=
  s.toList.any (fun ch => ch == '\r' || ch == '\n' || ch.toNat == 0)

/-- Strip hop-by-hop / framing headers (`Transfer-Encoding`, `Content-Length`, `Connection`, etc.)
    and extract safe upstream `Content-Type` so downstream HTTP/1.1 framing never suffers CL.TE desync. -/
def sanitizeUpstreamHeaders (hdrs : Array (String × String)) : String × Array (String × String) := Id.run do
  let mut ctype := "application/json"
  let mut safe : Array (String × String) := #[]
  for (k, v) in hdrs do
    if !hasHeaderCtl k && !hasHeaderCtl v then
      if k.trimAscii.toString.toLower == "content-type" && !v.trimAscii.toString.isEmpty then
        ctype := v.trimAscii.toString
      else if !isForbiddenResponseHeader k && !k.trimAscii.toString.isEmpty then
        safe := safe.push (k.trimAscii.toString, v.trimAscii.toString)
  return (ctype, safe)

private def parseBoundedPort? (s : String) : Option UInt16 := do
  let n ← s.trimAscii.toString.toNat?
  if 1 ≤ n && n ≤ 65535 then some n.toUInt16 else none

/-- Parse `https://<host>[:<port>][/<prefix>]` or `http://<host>[:<port>][/<prefix>]` (including `[::1]:8443`)
    into `(isTls, host, port, pathPrefix)`, returning `port = 0` on out-of-range port numbers. -/
def splitUpstreamBaseUrl (raw : String) : Bool × String × UInt16 × String :=
  let (isTls, rest) :=
    if raw.startsWith "https://" then (true, (raw.drop 8).toString)
    else if raw.startsWith "http://" then (false, (raw.drop 7).toString)
    else (true, raw)
  let defPort : UInt16 := if isTls then 443 else 80
  let (hostPort, pfx) :=
    match rest.splitOn "/" with
    | [] => ("127.0.0.1", "")
    | h :: ps =>
      let tail := String.intercalate "/" ps
      (h, if tail.isEmpty then "" else "/" ++ tail)
  let (host, port) :=
    if hostPort.startsWith "[" then
      match hostPort.splitOn "]:" with
      | [h6, pStr] => ((h6.drop 1).toString, (parseBoundedPort? pStr).getD 0)
      | _ =>
        if hostPort.endsWith "]" then (((hostPort.drop 1).dropEnd 1).toString, defPort)
        else (hostPort, 0)
    else
      match hostPort.splitOn ":" with
      | [h] => (h, defPort)
      | [h, pStr] => (h, (parseBoundedPort? pStr).getD 0)
      | _ => (hostPort, 0)
  (isTls, host, port, pfx)

/-- Decide whether upstream `status` may fail over to `attemptIdx + 1` in `chainLen`,
    strictly gated by `verifyProxyFailoverStep` (`OrbCore.Spec`). -/
def canFailoverUpstream (attemptIdx chainLen : Nat) (status : Nat) (headersCommitted : Bool) : Bool :=
  if attemptIdx > 255 || chainLen > 255 then false
  else
    verifyProxyFailoverStep
      attemptIdx.toUInt8
      chainLen.toUInt8
      status.toUInt32
      (if headersCommitted then 1 else 0) == 1

/-- Execute a bounded `/v1/*` proxy forward across `chain.targets` with pre-header failover on `429` / `5xx`. -/
def forwardProxyChain
    (chain : RoutingChain)
    (method relPath : String)
    (extraHeaders : Array (String × String))
    (body : ByteArray)
    (mockTransport? : Option (ProviderTarget → IO (Except String HttpsResponse)) := none)
    (headersAlreadyCommitted : Bool := false) :
    IO ProxyOutcome := do
  let n := chain.targets.size
  if n == 0 then
    return {
      status := 503
      contentType := "application/json"
      headers := #[]
      body := "{\"error\":\"empty_routing_chain\"}".toUTF8
      selectedAccount := ""
      attemptsUsed := 0
    }
  let mut idx : Nat := 0
  while idx < n do
    let tgt := chain.targets[idx]!
    let (isTls, host, port, pfx) := splitUpstreamBaseUrl tgt.baseUrl
    let fullPath := if pfx.isEmpty then relPath else pfx ++ relPath
    let reqHdrs := extraHeaders.push ("Authorization", s!"Bearer {tgt.apiKey}")
    let respRes ← match mockTransport? with
      | some mockFn => mockFn tgt
      | none =>
        if port == 0 then
          pure (.error "invalid_upstream_port")
        else if isTls then
          httpsRequest method host port fullPath reqHdrs body
        else
          pure (.error "plaintext_upstream_disabled")
    match respRes with
    | .ok resp =>
      if canFailoverUpstream idx n resp.status headersAlreadyCommitted then
        idx := idx + 1
      else
        let (ctype, safeHdrs) := sanitizeUpstreamHeaders resp.headers
        return {
          status := resp.status
          contentType := ctype
          headers := safeHdrs
          body := resp.body
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
        }
    | .error errMsg =>
      if canFailoverUpstream idx n 503 headersAlreadyCommitted then
        idx := idx + 1
      else
        return {
          status := 502
          contentType := "application/json"
          headers := #[]
          body := s!"\{\"error\":{jsonEscape errMsg}}".toUTF8
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
        }
  return {
    status := 502
    contentType := "application/json"
    headers := #[]
    body := "{\"error\":\"routing_chain_exhausted\"}".toUTF8
    selectedAccount := ""
    attemptsUsed := n
  }

end OrbCore.Proxy
