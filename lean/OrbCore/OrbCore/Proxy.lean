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
  headers          : Array (String × String)
  body             : ByteArray
  selectedAccount  : String
  attemptsUsed     : Nat
  deriving Inhabited

/-- Parse `https://<host>[:<port>][/<prefix>]` or `http://<host>[:<port>][/<prefix>]` into `(isTls, host, port, pathPrefix)`. -/
def splitUpstreamBaseUrl (raw : String) : Bool × String × UInt16 × String :=
  let (isTls, rest) :=
    if raw.startsWith "https://" then (true, (raw.drop 8).toString)
    else if raw.startsWith "http://" then (false, (raw.drop 7).toString)
    else (true, raw)
  let (hostPort, pfx) :=
    match rest.splitOn "/" with
    | [] => ("127.0.0.1", "")
    | h :: ps =>
      let tail := String.intercalate "/" ps
      (h, if tail.isEmpty then "" else "/" ++ tail)
  let (host, port) :=
    match hostPort.splitOn ":" with
    | [h, pStr] =>
      let p := (pStr.toNat?.getD (if isTls then 443 else 80)).toUInt16
      (h, p)
    | _ => (hostPort, if isTls then 443 else 80)
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
    (mockTransport? : Option (ProviderTarget → IO (Except String HttpsResponse)) := none) :
    IO ProxyOutcome := do
  let n := chain.targets.size
  if n == 0 then
    return {
      status := 503
      headers := #[("Content-Type", "application/json")]
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
        if isTls then
          httpsRequest method host port fullPath reqHdrs body
        else
          pure (.error "plaintext_upstream_disabled")
    match respRes with
    | .ok resp =>
      if canFailoverUpstream idx n resp.status false then
        idx := idx + 1
      else
        return {
          status := resp.status
          headers := resp.headers
          body := resp.body
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
        }
    | .error errMsg =>
      if canFailoverUpstream idx n 503 false then
        idx := idx + 1
      else
        return {
          status := 502
          headers := #[("Content-Type", "application/json")]
          body := s!"\{\"error\":{jsonEscape errMsg}}".toUTF8
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
        }
  return {
    status := 502
    headers := #[("Content-Type", "application/json")]
    body := "{\"error\":\"routing_chain_exhausted\"}".toUTF8
    selectedAccount := ""
    attemptsUsed := n
  }

end OrbCore.Proxy
