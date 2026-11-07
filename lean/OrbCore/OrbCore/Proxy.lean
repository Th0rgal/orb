/-
  OrbCore.Proxy: Verified `/v1/*` Multi-Provider LLM Proxy, Model-Routing Chain Resolver &
  Bounded Pre-First-Byte Failover Engine (`0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import Orb.Kernel
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
  exhaustionClass  : String := ""
  deriving Inhabited

/-- Why a routing-chain target is temporarily unavailable. -/
inductive CooldownReason where
  | rateLimit
  | usageLimit
  | authFailure
  | overloaded
  | serverError
  deriving Repr, DecidableEq, Inhabited

/-- A per-account cooldown recorded after an upstream failure. -/
structure AccountCooldown where
  accountId  : String
  untilEpoch : UInt64
  reason     : CooldownReason
  label      : String := ""
  deriving Repr, DecidableEq, Inhabited

/-- Cooldown-derived HTTP response (kept independent of `OrbCore.Control`). -/
structure ProxyHttpReply where
  status  : Nat
  headers : Array (String × String)
  body    : String
  deriving Repr, Inhabited

/-- Upper bound for an announced retry delay. Long enough to reflect a real
    quota cooldown instead of making clients re-poll every minute, but short
    enough that a weekly limit still gets re-checked periodically. -/
def maxCooldownRetryAfterSecs : UInt64 := 3600

def clampCooldownRetryAfter (secs : UInt64) : UInt64 :=
  let s := if secs == 0 then 1 else secs
  if s > maxCooldownRetryAfterSecs then maxCooldownRetryAfterSecs else s

def AccountCooldown.remainingSecs (c : AccountCooldown) (now : UInt64) : UInt64 :=
  if c.untilEpoch > now then c.untilEpoch - now else 0

def activeCooldowns (cooldowns : Array AccountCooldown) (now : UInt64) : Array AccountCooldown :=
  cooldowns.filter (fun c => c.untilEpoch > now)

def coolingFor (targets : Array ProviderTarget) (cooldowns : Array AccountCooldown) : Array AccountCooldown :=
  cooldowns.filter (fun c => targets.any (fun t => t.accountId == c.accountId))

def eligibleTargets (targets : Array ProviderTarget) (cooldowns : Array AccountCooldown) : Array ProviderTarget :=
  targets.filter (fun t => !cooldowns.any (fun c => c.accountId == t.accountId))

def soonestCooldown? (cooldowns : Array AccountCooldown) : Option AccountCooldown :=
  cooldowns.foldl
    (fun (best : Option AccountCooldown) (c : AccountCooldown) =>
      match best with
      | none => some c
      | some b => if c.untilEpoch < b.untilEpoch then some c else best)
    none

structure ChainPlan where
  eligible : Array ProviderTarget
  cooling  : Array AccountCooldown
  deriving Repr, Inhabited

/-- Split a chain into still-usable targets and cooling accounts. -/
def planChain (chain : RoutingChain) (cooldowns : Array AccountCooldown) (now : UInt64) : ChainPlan :=
  let active := activeCooldowns cooldowns now
  let cooling := coolingFor chain.targets active
  { eligible := eligibleTargets chain.targets cooling, cooling := cooling }

def ChainPlan.retryAfterSecs? (plan : ChainPlan) (now : UInt64) : Option UInt64 :=
  (soonestCooldown? plan.cooling).map (fun c => clampCooldownRetryAfter (c.remainingSecs now))

def ChainPlan.allUsageLimited (plan : ChainPlan) : Bool :=
  !plan.cooling.isEmpty &&
  plan.cooling.foldl (fun acc c => acc && c.reason == .usageLimit) true

def containsSubstring (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length > 1

def quotaHint (body : String) : Bool :=
  let low := body.toLower
  containsSubstring low "usage limit" || containsSubstring low "usage_limit" ||
  containsSubstring low "quota" || containsSubstring low "insufficient_quota" ||
  containsSubstring low "billing" || containsSubstring low "exhausted"

def authHint (body : String) : Bool :=
  let low := body.toLower
  containsSubstring low "invalid api key" || containsSubstring low "invalid_api_key" ||
  containsSubstring low "unauthorized" || containsSubstring low "authentication"

def lookupHeader? (headers : Array (String × String)) (name : String) : Option String :=
  let target := name.toLower
  headers.foldl
    (fun (acc : Option String) (kv : String × String) =>
      match acc with
      | some _ => acc
      | none =>
        if kv.1.trimAscii.toString.toLower == target then some kv.2.trimAscii.toString else none)
    none

def retryAfterSecs? (headers : Array (String × String)) : Option UInt64 :=
  match lookupHeader? headers "retry-after" with
  | some v => (v.toNat?).map (fun n => n.toUInt64)
  | none => none

def defaultCooldownSecs (reason : CooldownReason) : UInt64 :=
  match reason with
  | .usageLimit => 300
  | .rateLimit => 15
  | .authFailure => 15
  | .overloaded => 15
  | .serverError => 15

def cooldownReasonFor (status : Nat) (body : String) : Option CooldownReason :=
  if status == 429 then
    if quotaHint body then some .usageLimit else some .rateLimit
  else if status == 402 then some .usageLimit
  else if status == 401 then some .authFailure
  else if status == 403 then
    if authHint body then some .authFailure else none
  else if status == 529 || status == 503 then some .overloaded
  else if 500 ≤ status && status < 600 then some .serverError
  else none

/-- Record the failed selected account's cooldown after a proxy outcome. -/
def cooldownForOutcome (out : ProxyOutcome) (now : UInt64) : Option AccountCooldown :=
  if out.selectedAccount.isEmpty then none
  else
    let body := (String.fromUTF8? out.body).getD ""
    match cooldownReasonFor out.status body with
    | none => none
    | some reason =>
      let announced := (retryAfterSecs? out.headers).getD 0
      let secs := clampCooldownRetryAfter
        (if announced == 0 then defaultCooldownSecs reason else announced)
      some { accountId := out.selectedAccount, untilEpoch := now + secs, reason := reason, label := "" }

def cooldownReply (chainId : String) (retryAfterSecs : UInt64) : ProxyHttpReply :=
  let secs := clampCooldownRetryAfter retryAfterSecs
  { status := 429
    headers := #[("Retry-After", toString secs)]
    body :=
      s!"\{\"error\":\{\"message\":{jsonEscape s!"All providers in chain '{chainId}' are currently in cooldown or unconfigured"},\"type\":\"rate_limit_exceeded\",\"code\":\"rate_limit_exceeded\",\"retry_after_secs\":{secs}}}" }

def usageLimitReply (chainId : String) (c : AccountCooldown) (now : UInt64) : ProxyHttpReply :=
  let secs := clampCooldownRetryAfter (c.remainingSecs now)
  let resetIn := c.remainingSecs now
  let label := if c.label.isEmpty then "usage limit" else c.label
  let msg :=
    s!"You've hit your usage limit on every account configured for '{chainId}' ({label}). Try again in {secs} seconds."
  { status := 429
    headers := #[("Retry-After", toString secs)]
    body :=
      s!"\{\"error\":\{\"message\":{jsonEscape msg},\"type\":\"rate_limit_exceeded\",\"code\":\"usage_limit_reached\",\"resets_at\":{c.untilEpoch},\"resets_in_seconds\":{resetIn}}}" }

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

/-- Map `Orb.Kernel.proxyExhaustionStep` class code (`1..7`) to its canonical HTTP status and error code
    so HTTP `402` (`out_of_credit`, e.g. `particle-ai/particle-1`) is never misreported as `"client_or_auth_error"`. -/
def classifyExhaustionOutcome
    (rateLimitCount paymentRequiredCount clientAuthErrorCount
     serverErrorCount transportValidationCount : UInt32)
    (hasContextOverflow : Bool) : Nat × String × String :=
  let code :=
    Orb.Kernel.proxyExhaustionStep
      rateLimitCount paymentRequiredCount clientAuthErrorCount
      serverErrorCount transportValidationCount
      (if hasContextOverflow then 1 else 0)
  match code with
  | 1 => (503, "skipped_configuration", "No eligible providers configured in routing chain")
  | 2 => (502, "transport_validation", "All providers in routing chain failed transport validation")
  | 3 => (400, "context_length_exceeded", "Prompt exceeds context window across routing chain")
  | 4 => (502, "out_of_credit", "All providers in routing chain exhausted credits (HTTP 402 Payment Required)")
  | 5 => (502, "client_or_auth_error", "All providers in routing chain rejected the request (client/auth errors)")
  | 6 => (502, "server_unavailable", "All providers in routing chain returned upstream 5xx / transport errors")
  | _ => (429, "rate_limited_or_quota", "All providers in routing chain are rate-limited or quota-exhausted")

private def bodyIndicatesContextOverflow (body : ByteArray) : Bool :=
  let low := (String.fromUTF8? body |>.getD "").toLower
  (low.splitOn "context_length_exceeded").length > 1 ||
  (low.splitOn "maximum context length").length > 1

/-- Execute a bounded `/v1/*` proxy forward across `chain.targets` with proactive pacing spillover,
    pre-header failover on `402`, `429`, and `5xx`, and deterministic exhaustion classification via
    `Orb.Kernel.proxyExhaustionStep`. Targets in `skipAccountIds` (active cooldowns) are not attempted. -/
def forwardProxyChain
    (chain : RoutingChain)
    (method relPath : String)
    (extraHeaders : Array (String × String))
    (body : ByteArray)
    (mockTransport? : Option (ProviderTarget → IO (Except String HttpsResponse)) := none)
    (headersAlreadyCommitted : Bool := false)
    (pacingTracker? : Option ProxyPacingTracker := none)
    (skipAccountIds : Array String := #[]) :
    IO ProxyOutcome := do
  let targets := chain.targets.filter (fun t => !skipAccountIds.any (fun id => id == t.accountId))
  let n := targets.size
  if n == 0 then
    let (st, errCode, errMsg) := classifyExhaustionOutcome 0 0 0 0 0 false
    return {
      status := st
      contentType := "application/json"
      headers := #[("X-Orb-Exhaustion-Class", errCode)]
      body := s!"\{\"error\":{jsonEscape errCode},\"message\":{jsonEscape errMsg}}".toUTF8
      selectedAccount := ""
      attemptsUsed := 0
      exhaustionClass := errCode
    }
  let mut idx : Nat := 0
  let mut rateLimitCount : UInt32 := 0
  let mut paymentRequiredCount : UInt32 := 0
  let mut clientAuthErrorCount : UInt32 := 0
  let mut serverErrorCount : UInt32 := 0
  let mut transportValidationCount : UInt32 := 0
  let mut hasContextOverflow : Bool := false
  while idx < n do
    let tgt := targets[idx]!
    let slotAdmitted ← match pacingTracker? with
      | none => pure true
      | some tracker => do
        let nowMs ← IO.monoMsNow
        tryAcquireTargetSlot tracker tgt nowMs.toUInt64
    if !slotAdmitted then
      rateLimitCount := rateLimitCount + 1
      if canFailoverUpstream idx n 429 headersAlreadyCommitted then
        idx := idx + 1
      else
        return {
          status := 429
          contentType := "application/json"
          headers := #[("X-Orb-Exhaustion-Class", "rate_limited_or_quota")]
          body := "{\"error\":\"provider_pacing_limit_exceeded\"}".toUTF8
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
          exhaustionClass := "rate_limited_or_quota"
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
        if resp.status ≥ 200 && resp.status < 300 then
          let (ctype, safeHdrs) := sanitizeUpstreamHeaders resp.headers
          return {
            status := resp.status
            contentType := ctype
            headers := safeHdrs
            body := resp.body
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
          }
        if resp.status == 429 then
          rateLimitCount := rateLimitCount + 1
        else if resp.status == 402 then
          paymentRequiredCount := paymentRequiredCount + 1
        else if resp.status ≥ 500 && resp.status ≤ 599 then
          serverErrorCount := serverErrorCount + 1
        else if resp.status ≥ 400 && resp.status < 500 then
          clientAuthErrorCount := clientAuthErrorCount + 1
          if bodyIndicatesContextOverflow resp.body then
            hasContextOverflow := true
        if canFailoverUpstream idx n resp.status headersAlreadyCommitted then
          idx := idx + 1
        else if paymentRequiredCount > 0 ||
                paymentRequiredCount + rateLimitCount + serverErrorCount > 1 then
          let (st, errCode, errMsg) :=
            classifyExhaustionOutcome rateLimitCount paymentRequiredCount clientAuthErrorCount
              serverErrorCount transportValidationCount hasContextOverflow
          return {
            status := st
            contentType := "application/json"
            headers := #[("X-Orb-Exhaustion-Class", errCode)]
            body := s!"\{\"error\":{jsonEscape errCode},\"message\":{jsonEscape errMsg}}".toUTF8
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            exhaustionClass := errCode
          }
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
        serverErrorCount := serverErrorCount + 1
        if errMsg == "invalid_upstream_port" || errMsg == "plaintext_upstream_disabled" then
          transportValidationCount := transportValidationCount + 1
        if canFailoverUpstream idx n 503 headersAlreadyCommitted then
          idx := idx + 1
        else
          let (st, errCode, _) :=
            classifyExhaustionOutcome rateLimitCount paymentRequiredCount clientAuthErrorCount
              serverErrorCount transportValidationCount hasContextOverflow
          return {
            status := st
            contentType := "application/json"
            headers := #[("X-Orb-Exhaustion-Class", errCode)]
            body := s!"\{\"error\":{jsonEscape errMsg},\"exhaustion_class\":{jsonEscape errCode}}".toUTF8
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            exhaustionClass := errCode
          }
  let (st, errCode, errMsg) :=
    classifyExhaustionOutcome rateLimitCount paymentRequiredCount clientAuthErrorCount
      serverErrorCount transportValidationCount hasContextOverflow
  return {
    status := st
    contentType := "application/json"
    headers := #[("X-Orb-Exhaustion-Class", errCode)]
    body := s!"\{\"error\":{jsonEscape errCode},\"message\":{jsonEscape errMsg}}".toUTF8
    selectedAccount := ""
    attemptsUsed := n
    exhaustionClass := errCode
  }

end OrbCore.Proxy
