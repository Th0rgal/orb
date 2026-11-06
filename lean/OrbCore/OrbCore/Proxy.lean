/-
  OrbCore.Proxy: Verified `/v1/*` Multi-Provider LLM Proxy, Model-Routing Chain Resolver &
  Bounded Pre-First-Byte Failover Engine (`0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import OrbBin.Json
import OrbCore.Spec
import OrbCore.Store
import OrbNetLeaf.TlsHttp

namespace OrbCore.Proxy

open OrbBin.Json
open OrbCore.Spec
open OrbCore.Store
open OrbNetLeaf.TlsHttp

/-- Single upstream provider target inside a model-routing fallback chain. -/
structure ProviderTarget where
  accountId             : String
  provider              : String
  baseUrl               : String
  apiKey                : String
  modelId               : String
  accountRpmLimit?      : Option UInt32 := none
  accountMaxConcurrency? : Option UInt32 := none
  modelRpmLimit?        : Option UInt32 := none
  modelTpmLimit?        : Option UInt64 := none
  modelMaxConcurrency?  : Option UInt32 := none
  deriving Repr, DecidableEq, Inhabited

/-- In-memory sliding-window RPM, active in-flight concurrency & learned upstream header state. -/
structure ProxyPacingState where
  accountWindows  : Array (String × Array UInt64) := #[]
  modelWindows    : Array (String × Array UInt64) := #[]
  accountInflight : Array (String × Nat)          := #[]
  modelInflight   : Array (String × Nat)          := #[]
  observedKeyRpm  : Array (String × UInt32)       := #[]
  deriving Inhabited

/-- Mutex-protected runtime pacing tracker shared across concurrent HTTP worker tasks. -/
abbrev ProxyPacingTracker := Std.Mutex ProxyPacingState

def newProxyPacingTracker : IO ProxyPacingTracker :=
  Std.Mutex.new {}

private def modelSlotKey (accountId modelId : String) : String :=
  s!"{accountId}\x00{modelId}"

private def lookupAssoc {α : Type} (xs : Array (String × α)) (k : String) : Option α :=
  (xs.find? (fun (ek, _) => ek == k)).map Prod.snd

private def upsertAssoc {α : Type} (xs : Array (String × α)) (k : String) (v : α) : Array (String × α) :=
  if xs.any (fun (ek, _) => ek == k) then
    xs.map (fun (ek, ev) => if ek == k then (k, v) else (ek, ev))
  else
    xs.push (k, v)

private def pruneWindowMs (stamps : Array UInt64) (nowMs : UInt64) : Array UInt64 :=
  let cutoff : UInt64 := if nowMs > 60000 then nowMs - 60000 else 0
  stamps.filter (fun ts => ts ≥ cutoff)

private def parseBoundedRpmHeader? (raw : String) : Option UInt32 := do
  let n ← raw.trimAscii.toString.toNat?
  if 1 ≤ n && n ≤ 100000 then some n.toUInt32 else none

/-- Extract learned account/key RPM limit from upstream LiteLLM / OpenAI-compatible rate-limit headers.
    Prefers `x-litellm-key-rpm-limit` over generic `x-ratelimit-limit-requests` / `x-ratelimit-limit`. -/
def extractObservedRpmLimit? (hdrs : Array (String × String)) : Option UInt32 := Id.run do
  let mut genericRpm? : Option UInt32 := none
  for (k, v) in hdrs do
    let low := k.trimAscii.toString.toLower
    if low == "x-litellm-key-rpm-limit" then
      if let some lim := parseBoundedRpmHeader? v then
        return some lim
    else if low == "x-ratelimit-limit-requests" || low == "x-ratelimit-limit" then
      if genericRpm?.isNone then
        genericRpm? := parseBoundedRpmHeader? v
  return genericRpm?

/-- Look up the learned upstream `x-litellm-key-rpm-limit` / `x-ratelimit-limit-requests` for `accountId`. -/
def lookupObservedKeyRpm? (tracker : ProxyPacingTracker) (accountId : String) : IO (Option UInt32) :=
  tracker.atomically do
    let st ← get
    return lookupAssoc st.observedKeyRpm accountId

/-- Record upstream response rate-limit headers for `accountId` when present. -/
def recordObservedHeaders (tracker : ProxyPacingTracker) (accountId : String) (hdrs : Array (String × String)) : IO Unit := do
  if let some lim := extractObservedRpmLimit? hdrs then
    tracker.atomically do
      let st ← get
      set { st with observedKeyRpm := upsertAssoc st.observedKeyRpm accountId lim }

private def clampLoadU32 (n : Nat) : UInt32 :=
  if n > 4000000000 then 4000000000 else n.toUInt32

/-- Atomically check `verifyProviderPacingAdmission` (`OrbCore.Spec`) against live RPM windows and
    active in-flight slots; when admitted (`1`), records the timestamp and increments in-flight counters. -/
def tryAcquireTargetSlot (tracker : ProxyPacingTracker) (tgt : ProviderTarget) (nowMs : UInt64) : IO Bool :=
  tracker.atomically do
    let st ← get
    let mKey := modelSlotKey tgt.accountId tgt.modelId
    let acctWin := pruneWindowMs ((lookupAssoc st.accountWindows tgt.accountId).getD #[]) nowMs
    let mdlWin := pruneWindowMs ((lookupAssoc st.modelWindows mKey).getD #[]) nowMs
    let acctInf := (lookupAssoc st.accountInflight tgt.accountId).getD 0
    let mdlInf := (lookupAssoc st.modelInflight mKey).getD 0
    let effAcctRpm := (tgt.accountRpmLimit?.orElse (fun _ => lookupAssoc st.observedKeyRpm tgt.accountId)).getD 0
    let effAcctConc := tgt.accountMaxConcurrency?.getD 0
    let effMdlRpm := tgt.modelRpmLimit?.getD 0
    let effMdlConc := tgt.modelMaxConcurrency?.getD 0
    let admitted :=
      verifyProviderPacingAdmission
        effAcctRpm effAcctConc effMdlRpm effMdlConc
        (clampLoadU32 acctWin.size) (clampLoadU32 acctInf)
        (clampLoadU32 mdlWin.size) (clampLoadU32 mdlInf) == 1
    if !admitted then
      set {
        st with
        accountWindows := upsertAssoc st.accountWindows tgt.accountId acctWin
        modelWindows   := upsertAssoc st.modelWindows mKey mdlWin
      }
      return false
    else
      set {
        st with
        accountWindows  := upsertAssoc st.accountWindows tgt.accountId (acctWin.push nowMs)
        modelWindows    := upsertAssoc st.modelWindows mKey (mdlWin.push nowMs)
        accountInflight := upsertAssoc st.accountInflight tgt.accountId (acctInf + 1)
        modelInflight   := upsertAssoc st.modelInflight mKey (mdlInf + 1)
      }
      return true

/-- Release an acquired in-flight slot for `tgt` upon upstream completion or transport error. -/
def releaseTargetSlot (tracker : ProxyPacingTracker) (tgt : ProviderTarget) : IO Unit :=
  tracker.atomically do
    let st ← get
    let mKey := modelSlotKey tgt.accountId tgt.modelId
    let acctInf := (lookupAssoc st.accountInflight tgt.accountId).getD 0
    let mdlInf := (lookupAssoc st.modelInflight mKey).getD 0
    set {
      st with
      accountInflight := upsertAssoc st.accountInflight tgt.accountId (if acctInf > 0 then acctInf - 1 else 0)
      modelInflight   := upsertAssoc st.modelInflight mKey (if mdlInf > 0 then mdlInf - 1 else 0)
    }

/-- Rewrite `"model"` in JSON request `body` when `tgt.modelId` is non-empty so fallback targets
    receive their concrete upstream model identifier. -/
def rewriteTargetModelBody (tgt : ProviderTarget) (body : ByteArray) : ByteArray :=
  if tgt.modelId.isEmpty then body
  else
    match String.fromUTF8? body with
    | none => body
    | some raw =>
      match OrbBin.Json.parse raw with
      | .ok obj@(.obj _) =>
        if (obj.field? "model").isSome then
          (renderCompact (obj.setField "model" (.str tgt.modelId))).toUTF8
        else
          body
      | _ => body

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

/-- Execute a bounded `/v1/*` proxy forward across `chain.targets` with proactive pacing spillover
    and pre-header failover on `429` / `5xx`. -/
def forwardProxyChain
    (chain : RoutingChain)
    (method relPath : String)
    (extraHeaders : Array (String × String))
    (body : ByteArray)
    (mockTransport? : Option (ProviderTarget → IO (Except String HttpsResponse)) := none)
    (headersAlreadyCommitted : Bool := false)
    (pacingTracker? : Option ProxyPacingTracker := none) :
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
    let slotAdmitted ← match pacingTracker? with
      | none => pure true
      | some tracker => do
        let nowMs ← IO.monoMsNow
        tryAcquireTargetSlot tracker tgt nowMs.toUInt64
    if !slotAdmitted then
      if canFailoverUpstream idx n 429 headersAlreadyCommitted then
        idx := idx + 1
      else
        return {
          status := 429
          contentType := "application/json"
          headers := #[]
          body := "{\"error\":\"provider_pacing_limit_exceeded\"}".toUTF8
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
        }
    else
      let (isTls, host, port, pfx) := splitUpstreamBaseUrl tgt.baseUrl
      let fullPath := if pfx.isEmpty then relPath else pfx ++ relPath
      let reqHdrs := extraHeaders.push ("Authorization", s!"Bearer {tgt.apiKey}")
      let outBody := rewriteTargetModelBody tgt body
      let respRes ← try
        match mockTransport? with
        | some mockFn => mockFn tgt
        | none =>
          if port == 0 then
            pure (.error "invalid_upstream_port")
          else if isTls then
            httpsRequest method host port fullPath reqHdrs outBody
          else
            pure (.error "plaintext_upstream_disabled")
      finally
        if let some tracker := pacingTracker? then
          releaseTargetSlot tracker tgt
      match respRes with
      | .ok resp =>
        if let some tracker := pacingTracker? then
          recordObservedHeaders tracker tgt.accountId resp.headers
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
