/-
  OrbCore.Proxy: Verified `/v1/*` Multi-Provider LLM Proxy, Model-Routing Chain Resolver &
  Bounded Pre-First-Byte Failover Engine (`0 import Lean`, `0 sorryAx`).

  Phase R4-D (`SM-21`): Consolidates proxy commitment, circuit-breaker transitions, proactive
  pacing, and exponential account cooldowns behind one single-owner state machine wired
  authoritatively to `Orb.HarnessCloud.classifyProviderAttempt` / `stepProviderAttemptSlice`
  and `Orb.Kernel.proxyStep` / `breakerStep` / `accountCooldownSecs`.
-/
import Std.Sync.Mutex
import LeanSys.Posix
import Orb.Kernel
import Orb.HarnessCloud
import OrbBin.Json
import OrbCore.Spec
import OrbCore.Store
import OrbNetLeaf.TlsHttp

namespace OrbCore.Proxy

open LeanSys.Posix
open Orb.HarnessCloud
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

/-- Canonicalize Antigravity proxy model IDs so retired `agy-model*` / `agy-demo*` and base
    `gemini-4-carbon` / `gemini-4-argon` identifiers resolve to CLIProxyAPI's effort-baked Carbon/Argon IDs. -/
def canonicalAntigravityProxyModelId (raw : String) : String :=
  let m0 := raw.trimAscii.toString
  let m := if m0.startsWith "antigravity/" then (m0.drop 12).toString else m0
  if m == "agy-model" || m == "agy-model-high" || m == "gemini-4-carbon" || m == "gemini-4-carbon-eap" || m == "gemini-4-carbon-high" then
    "gemini-4-carbon-high"
  else if m == "agy-model-medium" || m == "gemini-4-carbon-medium" then
    "gemini-4-carbon-medium"
  else if m == "agy-model-low" || m == "gemini-4-carbon-low" then
    "gemini-4-carbon-low"
  else if m == "agy-demo" || m == "agy-demo-high" || m == "gemini-4-argon" || m == "gemini-4-argon-eap" || m == "gemini-4-argon-high" then
    "gemini-4-argon-high"
  else if m == "agy-demo-medium" || m == "gemini-4-argon-medium" then
    "gemini-4-argon-medium"
  else if m == "agy-demo-low" || m == "gemini-4-argon-low" then
    "gemini-4-argon-low"
  else
    m0

/-- Rewrite `"model"` in JSON request `body` when `tgt.modelId` is non-empty so fallback targets
    receive their concrete upstream model identifier (canonicalizing Antigravity Carbon/Argon IDs). -/
def rewriteTargetModelBody (tgt : ProviderTarget) (body : ByteArray) : ByteArray :=
  let isAg := tgt.provider == "antigravity" || tgt.provider.startsWith "antigravity:"
  if tgt.modelId.isEmpty && !isAg then body
  else
    match String.fromUTF8? body with
    | none => body
    | some raw =>
      match OrbBin.Json.parse raw with
      | .ok obj@(.obj _) =>
        match obj.fieldStr? "model" with
        | some reqMdl =>
          let chosen := if tgt.modelId.isEmpty then reqMdl else tgt.modelId
          let effMdl := if isAg then canonicalAntigravityProxyModelId chosen else chosen
          if effMdl.isEmpty then body
          else (renderCompact (obj.setField "model" (.str effMdl))).toUTF8
        | none => body
      | _ => body

/-- Model-routing chain configuration (`/api/model-routing/chains`). -/
structure RoutingChain where
  id      : String
  name    : String
  targets : Array ProviderTarget
  deriving Repr, DecidableEq

/-- Hands decoded body bytes to the client; `false` means the client went away.
    An empty piece is a liveness check and must not be written. -/
abbrev BodyEmit := ByteArray → IO Bool

/-- Relays an upstream body through `BodyEmit` and returns a bounded copy of it for
    usage accounting along with whether the body completed normally. -/
abbrev BodyPump := BodyEmit → IO (ByteArray × Bool)

/-- Upstream proxy attempt outcome. -/
structure ProxyOutcome where
  status             : Nat
  contentType        : String := "application/json"
  headers            : Array (String × String)
  body               : ByteArray
  selectedAccount    : String
  attemptsUsed       : Nat
  exhaustionClass    : String := ""
  firstByteCommitted : Bool := false
  pinnedAccountId    : UInt32 := 0
  verdictCode        : UInt8 := 0
  /-- Set for a committed 2xx streamed reply: `body` is empty and the pump relays it. -/
  stream?            : Option BodyPump := none
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

/-- Spec-aligned failover bound (`verifyProxyFailoverStep`: `chainLen ≤ 16 && attemptIdx < 16`). -/
def maxProxyChainTargets : Nat := 16

/-- Truncate a planned/forwarded candidate chain to the 16-target spec bound. -/
def capProxyTargets (targets : Array ProviderTarget) : Array ProviderTarget :=
  if targets.size ≤ maxProxyChainTargets then targets else targets.extract 0 maxProxyChainTargets

/-- Split a chain into still-usable targets (capped to `maxProxyChainTargets = 16`) and cooling accounts. -/
def planChain (chain : RoutingChain) (cooldowns : Array AccountCooldown) (now : UInt64) : ChainPlan :=
  let active := activeCooldowns cooldowns now
  let cooling := coolingFor chain.targets active
  { eligible := capProxyTargets (eligibleTargets chain.targets cooling), cooling := cooling }

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

def defaultCooldownBaseSecs (reason : CooldownReason) : UInt64 :=
  match reason with
  | .usageLimit  => 300
  | .rateLimit   => 15
  | .authFailure => 15
  | .overloaded  => 15
  | .serverError => 15

def defaultCooldownSecs (reason : CooldownReason) : UInt64 :=
  Orb.Kernel.accountCooldownSecs (defaultCooldownBaseSecs reason) maxCooldownRetryAfterSecs 1

def exponentialCooldownSecs (reason : CooldownReason) (consecutive : UInt32 := 1) : UInt64 :=
  Orb.Kernel.accountCooldownSecs (defaultCooldownBaseSecs reason) maxCooldownRetryAfterSecs consecutive

/-- Map an upstream HTTP status + response body to `Orb.HarnessCloud.classifyProviderAttempt` /
    `Orb.Kernel.breakerStep` failure reason code (`0..5`):
    `0 = ok_fresh`, `1 = rate_limit_429`, `2 = quota_exhausted`, `3 = payment_required_402`,
    `4 = transient_502_stall`, `5 = auth_401_403`. -/
def providerFailureReasonCode (status : Nat) (body : String) : UInt8 :=
  if status ≥ 200 && status < 300 then 0
  else if status == 429 then
    if quotaHint body then 2 else 1
  else if status == 402 then 3
  else if status == 401 then 5
  else if status == 403 then
    if authHint body then 5 else 0
  else if status ≥ 500 && status < 600 then 4
  else 0

def cooldownReasonFor (status : Nat) (body : String) : Option CooldownReason :=
  let code := providerFailureReasonCode status body
  if code == 2 || code == 3 then some .usageLimit
  else if code == 1 then some .rateLimit
  else if code == 5 then some .authFailure
  else if code == 4 then
    if status == 529 || status == 503 then some .overloaded else some .serverError
  else none

/-- Authoritative circuit-breaker & exponential cooldown evaluation via `Orb.Kernel.breakerStep`
    + `Orb.Kernel.accountCooldownSecs`. When `transientThreshold > 0` and `status` is a `5xx`
    transient failure (`reason == 4`) with `transientStreak < transientThreshold`, `breakerStep`
    returns `0` (`applyCooldown == 0`) so transient blips do not prematurely cool down the account. -/
def cooldownForOutcomeWithBreaker
    (out : ProxyOutcome)
    (now : UInt64)
    (consecutive : UInt32 := 1)
    (transientStreak : UInt32 := 1)
    (transientThreshold : UInt32 := 1) : Option AccountCooldown :=
  if out.selectedAccount.isEmpty then none
  else
    let body := (String.fromUTF8? out.body).getD ""
    let failCode := providerFailureReasonCode out.status body
    if failCode == 0 then none
    else
      let breakerWord := Orb.Kernel.breakerStep failCode transientStreak transientThreshold
      let applyCooldown := ((breakerWord >>> 16) &&& 0xFF) == 1
      if !applyCooldown then none
      else
        match cooldownReasonFor out.status body with
        | none => none
        | some reason =>
          let announced := (retryAfterSecs? out.headers).getD 0
          let computed := exponentialCooldownSecs reason consecutive
          let secs := clampCooldownRetryAfter (if announced == 0 then computed else announced)
          some { accountId := out.selectedAccount, untilEpoch := now + secs, reason := reason, label := "" }

/-- Record the failed selected account's cooldown after a proxy outcome. -/
def cooldownForOutcome (out : ProxyOutcome) (now : UInt64) : Option AccountCooldown :=
  cooldownForOutcomeWithBreaker out now 1 1 2

/-! ### Unified Generation-Fenced `ProviderHealthTracker` (`SM-21`) -/

/-- Stable non-zero 32-bit candidate account slot hash (`≥ 1`) for `stepProviderAttemptSlice`. -/
def accountSlotId (accountId : String) : UInt32 := Id.run do
  let bytes := accountId.toUTF8
  let mut h : UInt32 := 2166136261
  for i in [0:bytes.size] do
    let b := bytes.get! i
    h := (h ^^^ b.toUInt32) * 16777619
  return if h == 0 then 1 else h

/-- Per-account circuit-breaker, streak, parking & exponential cooldown state owned by `ProviderHealthTracker`. -/
structure AccountHealthRecord where
  accountId        : String
  slotId           : UInt32
  transientStreak  : UInt32 := 0
  consecutiveTrips : UInt32 := 0
  parkedQuota      : Bool   := false
  poisonedSub      : Bool   := false
  cooldown?        : Option AccountCooldown := none
  lastVerdictCode  : UInt8  := 0
  deriving Repr, DecidableEq, Inhabited

/-- Single-owner provider health, circuit-breaker, route-generation, and pacing state (`SM-21`). -/
structure ProviderHealthState where
  routeGeneration    : UInt64 := 1
  transientThreshold : UInt32 := 2
  accounts           : Array AccountHealthRecord := #[]
  deriving Repr, Inhabited

/-- Unified single-owner runtime tracker consolidating `proxy.rs` commitment, `provider_health.rs`
    transient streaks / circuit-breaker trips, and `account_limits.rs` pacing & cooldowns (`SM-21`). -/
structure ProviderHealthTracker where
  pacing : ProxyPacingTracker
  health : Std.Mutex ProviderHealthState

def newProviderHealthTracker
    (routeGeneration : UInt64 := 1)
    (transientThreshold : UInt32 := 2) : IO ProviderHealthTracker := do
  let pacing ← newProxyPacingTracker
  let effGen : UInt64 := if routeGeneration == 0 then 1 else routeGeneration
  let health ← Std.Mutex.new { routeGeneration := effGen, transientThreshold := transientThreshold }
  return { pacing := pacing, health := health }

private def lookupAccountHealth (xs : Array AccountHealthRecord) (accountId : String) : AccountHealthRecord :=
  match xs.find? (fun r => r.accountId == accountId) with
  | some r => r
  | none => { accountId := accountId, slotId := accountSlotId accountId }

private def upsertAccountHealth (xs : Array AccountHealthRecord) (rec : AccountHealthRecord) : Array AccountHealthRecord :=
  if xs.any (fun r => r.accountId == rec.accountId) then
    xs.map (fun r => if r.accountId == rec.accountId then rec else r)
  else
    xs.push rec

/-- Read current `routeGeneration` from `ProviderHealthTracker`. -/
def currentRouteGeneration (tracker : ProviderHealthTracker) : IO UInt64 :=
  tracker.health.atomically do
    return (← get).routeGeneration

/-- Advance `routeGeneration` monotonically (`+ 1`) so in-flight attempts carrying an older
    `attemptGeneration` fail closed (`0 = rejectStaleOrPin`) without mutating cooldowns or streaks. -/
def bumpRouteGeneration (tracker : ProviderHealthTracker) : IO UInt64 :=
  tracker.health.atomically do
    let st ← get
    let nextGen := if st.routeGeneration < 0xFFFFFFFFFFFFFFFF then st.routeGeneration + 1 else st.routeGeneration
    set { st with routeGeneration := nextGen }
    return nextGen

/-- Inspect per-account health record (`transientStreak`, `consecutiveTrips`, `cooldown?`, `parkedQuota`). -/
def lookupAccountHealthRecord (tracker : ProviderHealthTracker) (accountId : String) : IO AccountHealthRecord :=
  tracker.health.atomically do
    let st ← get
    return lookupAccountHealth st.accounts accountId

/-- Snapshot all active cooldowns (`untilEpoch > nowEpoch`) currently enforced by `ProviderHealthTracker`,
    lazy-expiring elapsed cooldown windows so recovered accounts become eligible again automatically. -/
def snapshotActiveHealthCooldowns (tracker : ProviderHealthTracker) (nowEpoch : UInt64) : IO (Array AccountCooldown) :=
  tracker.health.atomically do
    let st ← get
    let mut updated : Array AccountHealthRecord := Array.mkEmpty st.accounts.size
    let mut active : Array AccountCooldown := #[]
    for rec in st.accounts do
      match rec.cooldown? with
      | some c =>
        if c.untilEpoch > nowEpoch then
          updated := updated.push rec
          active := active.push c
        else
          updated := updated.push { rec with cooldown? := none, parkedQuota := false, poisonedSub := false }
      | none =>
        updated := updated.push rec
    set { st with accounts := updated }
    return active

/-- Operator reset: forget the cooldown, quota park, poison and streaks of every account whose
    id satisfies `pick`. Used by the health "clear" route and after a completed login. -/
def clearAccountHealthWhere (tracker : ProviderHealthTracker) (pick : String → Bool) : IO Unit :=
  tracker.health.atomically do
    let st ← get
    set { st with accounts := st.accounts.filter (fun r => !pick r.accountId) }

/-- Plan a `RoutingChain` directly from `ProviderHealthTracker`'s single-owner state at `nowEpoch`. -/
def planChainFromHealth (tracker : ProviderHealthTracker) (chain : RoutingChain) (nowEpoch : UInt64) : IO ChainPlan := do
  let active ← snapshotActiveHealthCooldowns tracker nowEpoch
  return planChain chain active nowEpoch

/-- Pure single-step reconciliation of an attempt outcome against `(ProviderHealthState, ProviderAttemptSliceState)`
    using `Orb.HarnessCloud.stepProviderAttemptSlice`, `Orb.Kernel.breakerStep`, and `Orb.Kernel.accountCooldownSecs`.
    - Stale `attemptGeneration != routeGeneration` or pin mismatch returns verdict `0` (`rejectStaleOrPin`) with zero state mutation.
    - Committed stream (`s.firstByteCommitted == 1`) with `status` 2xx (`failureReason == 0`) returns verdict `8` (`passCommittedStream`)
      without resetting `transientStreak` or opening a second upstream attempt.
    - Committed stream (`s.firstByteCommitted == 1`) with any failure returns verdict `4` (`abortCommittedLock`) and emits `.abortLockedStream`. -/
def stepHealthAttemptPure
    (hst : ProviderHealthState)
    (slice : ProviderAttemptSliceState)
    (accountId : String)
    (status : Nat)
    (respHeaders : Array (String × String))
    (respBody : String)
    (chunkCommits : Bool)
    (maxRetries : UInt32)
    (attemptGeneration : UInt64)
    (nowEpoch : UInt64) :
    ProviderHealthState × ProviderAttemptSliceState × UInt8 × List ProviderAttemptEffect :=
  let rec0 := lookupAccountHealth hst.accounts accountId
  let activeCoolUntil : UInt64 :=
    match rec0.cooldown? with
    | some c => if c.untilEpoch > nowEpoch then c.untilEpoch else 0
    | none => 0
  let failCode :=
    let raw := providerFailureReasonCode status respBody
    if slice.firstByteCommitted == 1 && raw == 0 && !(status ≥ 200 && status < 300) then 4 else raw
  let candId :=
    if slice.pinnedAccountId != 0 && slice.firstByteCommitted == 1 && accountId.isEmpty then
      slice.pinnedAccountId
    else
      rec0.slotId
  let sliceIn : ProviderAttemptSliceState := {
    slice with
    transientStreak := rec0.transientStreak
    routeGeneration := hst.routeGeneration
  }
  let nextConsecutive := if rec0.consecutiveTrips < 0xFFFFFFFF then rec0.consecutiveTrips + 1 else rec0.consecutiveTrips
  let proposedCooldownSecs : UInt64 :=
    match cooldownReasonFor status respBody with
    | none => 0
    | some reason =>
      let announced := (retryAfterSecs? respHeaders).getD 0
      let computed := exponentialCooldownSecs reason nextConsecutive
      clampCooldownRetryAfter (if announced == 0 then computed else announced)
  let nextCooldownEpoch :=
    if proposedCooldownSecs > 0 then nowEpoch + proposedCooldownSecs else activeCoolUntil
  let ev : ProviderAttemptSliceEvent := {
    chunkCommits := if chunkCommits then 1 else 0
    failureReason := failCode
    candidateAccountId := candId
    maxRetries := maxRetries
    transientThreshold := hst.transientThreshold
    attemptGeneration := attemptGeneration
    nowEpoch := nowEpoch
    nextCooldownEpoch := nextCooldownEpoch
  }
  let verdict := classifyProviderAttempt
    sliceIn.firstByteCommitted ev.failureReason
    sliceIn.pinnedAccountId ev.candidateAccountId
    sliceIn.attemptsUsed ev.maxRetries
    sliceIn.transientStreak ev.transientThreshold
    sliceIn.routeGeneration ev.attemptGeneration
    ev.nowEpoch sliceIn.cooldownUntilEpoch
  let (sliceOut, effs) := stepProviderAttemptSlice sliceIn ev
  if verdict == 0 || verdict == 8 then
    (hst, sliceIn, verdict, effs)
  else
    let breakerWord := Orb.Kernel.breakerStep failCode sliceOut.transientStreak hst.transientThreshold
    let parkAcct := (breakerWord &&& 0xFF) == 1
    let poisonSub := ((breakerWord >>> 8) &&& 0xFF) == 1
    let breakerCooldown := ((breakerWord >>> 16) &&& 0xFF) == 1
    let sliceTripped := effs.any (fun e => match e with | .tripAccountBreaker _ _ => true | _ => false)
    let tripped := sliceTripped || breakerCooldown
    let targetCoolUntil :=
      if sliceTripped && sliceOut.cooldownUntilEpoch > nowEpoch then sliceOut.cooldownUntilEpoch
      else nextCooldownEpoch
    let nextCool? : Option AccountCooldown :=
      if tripped && targetCoolUntil > nowEpoch then
        match cooldownReasonFor status respBody with
        | some reason =>
          some { accountId := accountId, untilEpoch := targetCoolUntil, reason := reason, label := "" }
        | none =>
          some { accountId := accountId, untilEpoch := nowEpoch + clampCooldownRetryAfter 15, reason := .serverError, label := "" }
      else if verdict == 1 then
        none
      else if activeCoolUntil > nowEpoch then
        rec0.cooldown?
      else
        none
    let nextTrips : UInt32 :=
      if verdict == 1 then 0
      else if tripped then nextConsecutive
      else rec0.consecutiveTrips
    let rec1 : AccountHealthRecord := {
      rec0 with
      transientStreak := sliceOut.transientStreak
      consecutiveTrips := nextTrips
      parkedQuota := if verdict == 1 then false else (rec0.parkedQuota || parkAcct)
      poisonedSub := if verdict == 1 then false else (rec0.poisonedSub || poisonSub)
      cooldown? := nextCool?
      lastVerdictCode := verdict
    }
    ({ hst with accounts := upsertAccountHealth hst.accounts rec1 }, sliceOut, verdict, effs)

/-- Record an attempt outcome atomically on `ProviderHealthTracker`. -/
def recordHealthAttempt
    (tracker : ProviderHealthTracker)
    (slice : ProviderAttemptSliceState)
    (accountId : String)
    (status : Nat)
    (respHeaders : Array (String × String))
    (respBody : String)
    (chunkCommits : Bool)
    (maxRetries : UInt32)
    (attemptGeneration : UInt64)
    (nowEpoch : UInt64) :
    IO (ProviderAttemptSliceState × UInt8 × List ProviderAttemptEffect) :=
  tracker.health.atomically do
    let hst ← get
    let (hst', slice', v, effs) :=
      stepHealthAttemptPure hst slice accountId status respHeaders respBody
        chunkCommits maxRetries attemptGeneration nowEpoch
    set hst'
    return (slice', v, effs)

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

/-- The request sent to one chain target, as the Rust proxy built it (`proxy.rs`,
    `default_base_url` + `completions_url`): `(tls, host, port, path, headers, body)`.
    - A base URL that already carries its API version (`/v1`, `/api/coding/paas/v4`,
      `/v1beta/openai`) replaces the client's `/v1`; it is never doubled.
    - JSON bodies are declared as such (MiniMax rejects the body otherwise).
    - Kimi's own endpoint needs its CLI user agent and `temperature: 1`; z.ai has no
      `[1m]` model suffix. -/
def upstreamRequest (tgt : ProviderTarget) (relPath : String)
    (extraHeaders : Array (String × String)) (body : ByteArray) :
    Bool × String × UInt16 × String × Array (String × String) × ByteArray :=
  let (isTls, host, port, pfx) := splitUpstreamBaseUrl tgt.baseUrl
  let versioned := (pfx.splitOn "/").any fun seg =>
    match seg.toList with
    | 'v' :: d :: _ => d.isDigit
    | _ => false
  let rel :=
    if versioned && relPath.startsWith "/v1/" then (relPath.drop 3).toString
    else if versioned && relPath == "/v1" then ""
    else relPath
  let fullPath := if pfx.isEmpty then rel else pfx ++ rel
  let direct := fun (name : String) => tgt.provider == name && (host.splitOn name).length > 1
  let kimiDirect := direct "kimi"
  let tgt' := if tgt.provider == "zai" && tgt.modelId.endsWith "[1m]" then { tgt with modelId := (tgt.modelId.dropEnd 4).toString } else tgt
  let rewritten := rewriteTargetModelBody tgt' body
  let outBody :=
    if !kimiDirect then rewritten
    else match (String.fromUTF8? rewritten).bind (fun raw => (OrbBin.Json.parse raw).toOption) with
      | some obj@(.obj _) => (renderCompact (obj.setField "temperature" (.nat 1))).toUTF8
      | _ => rewritten
  let has := fun (name : String) => extraHeaders.any (fun h => h.1.toLower == name)
  let hdrs := extraHeaders.push ("Authorization", s!"Bearer {tgt.apiKey}")
  let hdrs := if outBody.isEmpty || has "content-type" then hdrs else hdrs.push ("Content-Type", "application/json")
  let hdrs := if kimiDirect && !has "user-agent" then hdrs.push ("User-Agent", "KimiCLI/1.5") else hdrs
  (isTls, host, port, fullPath, hdrs, outBody)

/-- Short machine code from an upstream error body (`error.code`, `error.type`, `code`,
    `type`), for the per-target failure list. Never the message: it can name accounts. -/
def upstreamErrorCode (body : String) : String :=
  match OrbBin.Json.parse body with
  | .ok jv =>
    let err := jv.fieldOrNull "error"
    let code := (err.fieldStr? "code").orElse (fun _ => err.fieldStr? "type")
      |>.orElse (fun _ => jv.fieldStr? "code") |>.orElse (fun _ => jv.fieldStr? "type")
      |>.orElse (fun _ => err.asStr?) |>.getD ""
    if code.length ≤ 64 && code.all (fun c => c.isAlphanum || c == '_' || c == '-' || c == '.') then code else ""
  | .error _ => ""

/-- An upstream answer that means "this account's login is no longer accepted": a 401, or
    the auth error codes of CLIProxyAPI and the vendors' OAuth endpoints. A 403 alone is
    not enough (it is also used for model or region permission). -/
def isAuthRejection (status : Nat) (code body : String) : Bool :=
  status == 401 || code == "auth_unavailable" || code == "invalid_grant" ||
    code == "authentication_error" || code == "invalid_api_key" ||
    (body.splitOn "invalid_grant").length > 1

/-- Body returned when every target of a chain failed: the class, and each target's outcome. -/
def chainExhaustedBody (errCode errMsg : String) (failures : Array (String × String × Nat × String)) : ByteArray :=
  (renderCompact (.obj #[("error", .str errCode), ("message", .str errMsg),
    ("targets", .arr (failures.map fun (provider, model, status, code) =>
      .obj #[("provider", .str provider), ("model", .str model), ("status", .nat status), ("code", .str code)]))])).toUTF8

/-- Decide whether upstream `status` may fail over to `attemptIdx + 1` in `chainLen`.
    Chains longer than 16 are compared against the capped length so `attemptIdx = 0` is not
    disabled solely because `targets.size > 16`. Still gated by `Orb.Kernel.proxyStep`
    (no transparent reroute once `firstByteCommitted == 1`) and `verifyProxyFailoverStep`. -/
def canFailoverUpstream (attemptIdx chainLen : Nat) (status : Nat) (headersCommitted : Bool) : Bool :=
  let effLen := if chainLen > maxProxyChainTargets then maxProxyChainTargets else chainLen
  if attemptIdx > 255 || effLen > 255 then false
  else
    let commBit : UInt8 := if headersCommitted then 1 else 0
    let maxRet : UInt32 := if effLen > 1 then (effLen - 1).toUInt32 else 0
    let proxyWord := Orb.Kernel.proxyStep commBit 0 1 attemptIdx.toUInt32 maxRet
    let proxyAction := (proxyWord >>> 8) &&& 0xFF
    let kernelAllows := proxyAction == 1 || proxyAction == 2
    let specAllows :=
      verifyProxyFailoverStep
        attemptIdx.toUInt8
        effLen.toUInt8
        status.toUInt32
        commBit == 1
    kernelAllows && specAllows && attemptIdx + 1 < effLen && !headersCommitted

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

private def isPrivatePlaintextHost (host : String) : Bool :=
  host == "127.0.0.1" || host == "localhost" ||
  host.startsWith "10." || host.startsWith "100." || host.startsWith "192.168." ||
  host.startsWith "172.16." || host.startsWith "172.17." || host.startsWith "172.18." ||
  host.startsWith "172.19." || host.startsWith "172.2" || host.startsWith "172.30." ||
  host.startsWith "172.31."

/-- Longest silence tolerated from a plaintext upstream before the response is abandoned. -/
def upstreamIdleLimitMs : Nat := 600000

/-- Longest total duration of one plaintext upstream call. -/
def upstreamTotalLimitMs : Nat := 3600000

private def loopbackHttpRequest
    (method host : String) (port : UInt16) (path : String)
    (headers : Array (String × String)) (body : ByteArray) :
    IO (Except String HttpsResponse) := do
  let connectHost := if host == "localhost" then "127.0.0.1" else host
  let hostAuth := formatHostAuthority host port 80
  let reqWire ← match buildOutboundHttp11Request method hostAuth path headers body with
    | .ok w => pure w
    | .error e => return .error e
  let .ok fd ← tcpConnect connectHost port
    | return .error "loopback_connect_failed"
  let mut rawBuf := ByteArray.empty
  try
    if let .error _ ← writeAll fd reqWire false then
      return .error "loopback_write_failed"
    -- A model can think for minutes before its first byte and pause between stream chunks, so a
    -- quiet socket is not the end of the response: only EOF, a socket error, `upstreamIdleLimitMs`
    -- without a byte, or `upstreamTotalLimitMs` overall end the read.
    let t0 ← IO.monoMsNow
    let mut lastByteMs := t0
    let mut eof := false
    while !eof && rawBuf.size ≤ 16777216 do
      let nowMs ← IO.monoMsNow
      if nowMs - t0 > upstreamTotalLimitMs || nowMs - lastByteMs > upstreamIdleLimitMs then
        eof := true
      else
        match ← pollReadable fd 5000 with
        | .error .eagain => pure ()
        | .error _ => eof := true
        | .ok () =>
          let chunk ← readStreamChunk fd 65536
          if chunk.isEmpty then eof := true
          else
            rawBuf := rawBuf ++ chunk
            lastByteMs ← IO.monoMsNow
  finally
    discard <| closeFd fd
  return parseHttpResponseWire rawBuf 16777216 true method

/-! ### Streaming passthrough

A model reply asked for with `"stream": true` is relayed to the client as the upstream
produces it instead of after the last byte. Failover still happens only before the
response head: a non-2xx head is drained and handled exactly like a buffered reply. -/

/-- Largest body copy kept for accounting; the relay itself is not bounded by it. -/
def maxStreamCopyBytes : Nat := 16777216

/-- Raw response bytes from one upstream connection; `none` ends the read
    (EOF, socket error, or an idle/total limit). `eof` reports whether the
    read ended cleanly: TLS `close_notify` only over TLS, or an orderly close
    (`read == 0`) over plain TCP. -/
structure UpstreamReader where
  read  : IO (Option ByteArray)
  close : IO Unit
  eof   : IO Bool := pure true

/-- How the response body is delimited on the wire. -/
inductive BodyFraming where
  | chunked (st : ChunkedStreamState)
  | length (remaining : Nat)
  | untilClose
  deriving Inhabited

/-- Decode one wire piece: `(payload, nextFraming, finished)`. -/
def stepBodyFraming : BodyFraming → ByteArray → Except String (ByteArray × BodyFraming × Bool)
  | .chunked st, input => do
    let (out, st', fin) ← stepChunkedStream st input
    return (out, .chunked st', fin)
  | .length rem, input =>
    let take := Nat.min rem input.size
    .ok (input.extract 0 take, .length (rem - take), rem - take == 0)
  | .untilClose, input => .ok (input, .untilClose, false)

/-- Framing for a response head: `chunked`, then `Content-Length`, else read until close. -/
def bodyFramingFor (isChunked : Bool) (contentLen? : Option Nat) : BodyFraming :=
  if isChunked then .chunked (.readSizeLine ByteArray.empty)
  else match contentLen? with
    | some n => .length n
    | none => .untilClose

/-- Whether a client asked for a streamed reply (OpenAI/Anthropic `"stream": true`,
    Gemini `:streamGenerateContent`). -/
def requestWantsStream (relPath : String) (body : ByteArray) : Bool :=
  (relPath.splitOn "streamGenerateContent").length > 1 ||
  match OrbBin.Json.parseBytes body with
  | .ok jv => match jv.field? "stream" with
    | some (.bool true) => true
    | _ => false
  | .error _ => false

/-- Relay the body: `tail` first, then reads from `r`, until framing ends, the upstream
    closes, or `emit` reports the client gone. Always closes `r`. -/
def pumpUpstreamBody (r : UpstreamReader) (framing0 : BodyFraming) (tail : ByteArray)
    (emit : BodyEmit) : IO (ByteArray × Bool) := do
  let mut framing := framing0
  let mut copy := ByteArray.empty
  let mut pending : Option ByteArray := some tail
  let mut complete := match framing0 with | .length 0 => true | _ => false
  let mut aborted := false
  let mut done := complete
  try
    while !done do
      let fromTail := pending.isSome
      let piece? ← match pending with
        | some p => pure (some p)
        | none => r.read
      pending := none
      match piece? with
      | none =>
        if let .untilClose := framing then complete := true
        done := true
      | some piece =>
        match stepBodyFraming framing piece with
        | .error _ => done := true
        | .ok (out, next, fin) =>
          framing := next
          if !out.isEmpty then
            if copy.size + out.size ≤ maxStreamCopyBytes then
              copy := copy ++ out
            if !(← emit out) then
              aborted := true
              done := true
          else if fromTail && !fin then
            if !(← emit ByteArray.empty) then
              aborted := true
              done := true
          if fin && !aborted then
            complete := true
            done := true
  finally
    r.close
  return (copy, complete && !aborted)

/-- Read until the response head (after any `1xx`) is complete. -/
def readUpstreamHead (r : UpstreamReader) :
    IO (Except String (Nat × Array (String × String) × Bool × Option Nat × ByteArray)) := do
  let mut acc := ByteArray.empty
  while true do
    match ← r.read with
    | none => return .error "upstream_closed_before_headers"
    | some c =>
      acc := acc ++ c
      match extractStreamingResponseHeadEx? acc with
      | .error e => return .error e
      | .ok none => pure ()
      | .ok (some head) => return .ok head
  return .error "upstream_head_unreachable"

private def openTlsUpstreamReader (method host : String) (port : UInt16) (path : String)
    (headers : Array (String × String)) (body : ByteArray) : IO (Except String UpstreamReader) := do
  match ← openHttps11Stream method host port path headers body true 15000 with
  | .error e => return .error e
  | .ok sess =>
    let t0 ← IO.monoMsNow
    return .ok {
      -- A model can think for minutes before its first byte: `upstreamIdleLimitMs`
      -- bounds silence between reads and `upstreamTotalLimitMs` bounds total wall time.
      read := do
        let elapsed := (← IO.monoMsNow) - t0
        if elapsed ≥ upstreamTotalLimitMs then
          return none
        let waitMs := Nat.min upstreamIdleLimitMs (upstreamTotalLimitMs - elapsed)
        match ← readTlsSessionChunk sess 16384 waitMs.toUInt32 with
        | .chunk c => return if c.isEmpty then none else some c
        | _ => return none
      close := closeTlsSession sess
    }

private def openLoopbackUpstreamReader (method host : String) (port : UInt16) (path : String)
    (headers : Array (String × String)) (body : ByteArray) : IO (Except String UpstreamReader) := do
  let connectHost := if host == "localhost" then "127.0.0.1" else host
  let hostAuth := formatHostAuthority host port 80
  let reqWire ← match buildOutboundHttp11Request method hostAuth path headers body with
    | .ok w => pure w
    | .error e => return .error e
  let .ok fd ← tcpConnect connectHost port
    | return .error "loopback_connect_failed"
  if let .error _ ← writeAll fd reqWire false then
    discard <| closeFd fd
    return .error "loopback_write_failed"
  let t0 ← IO.monoMsNow
  let lastByte ← IO.mkRef t0
  return .ok {
    read := do
      while true do
        let nowMs ← IO.monoMsNow
        if nowMs - t0 > upstreamTotalLimitMs || nowMs - (← lastByte.get) > upstreamIdleLimitMs then
          return none
        match ← pollReadable fd 5000 with
        | .error .eagain => pure ()
        | .error _ => return none
        | .ok () =>
          let chunk ← readStreamChunk fd 65536
          if chunk.isEmpty then return none
          lastByte.set (← IO.monoMsNow)
          return some chunk
      return none
    close := discard <| closeFd fd
  }

/-- One upstream call that relays a 2xx body as it arrives. A non-2xx (or bodyless)
    reply is read whole so the failover logic sees the same `HttpsResponse` as before. -/
def streamingUpstreamRequest (isTls : Bool) (method host : String) (port : UInt16) (path : String)
    (headers : Array (String × String)) (body : ByteArray) :
    IO (Except String (HttpsResponse × Option BodyPump)) := do
  let opened ← if isTls then openTlsUpstreamReader method host port path headers body
    else openLoopbackUpstreamReader method host port path headers body
  let r ← match opened with
    | .ok r => pure r
    | .error e => return .error e
  match ← readUpstreamHead r with
  | .error e =>
    r.close
    return .error e
  | .ok (status, hdrs, isChunked, contentLen?, tail) =>
    let framing := bodyFramingFor isChunked contentLen?
    if status ≥ 200 && status < 300 && !isBodylessHttpResponse method status then
      return .ok ({ status, headers := hdrs, body := ByteArray.empty },
        some (pumpUpstreamBody r framing tail))
    else
      let whole ← if isBodylessHttpResponse method status then do r.close; pure ByteArray.empty
        else (·.1) <$> pumpUpstreamBody r framing tail (fun _ => pure true)
      return .ok ({ status, headers := hdrs, body := whole }, none)

/-- Execute a bounded `/v1/*` proxy forward across `chain.targets` with proactive pacing spillover,
    sticky `firstByteCommitted` pin enforcement via `Orb.HarnessCloud.stepProviderAttemptSlice` /
    `classifyProviderAttempt` (`SM-21`), pre-header failover on `402`, `429`, and `5xx` via
    `Orb.Kernel.proxyStep` + `verifyProxyFailoverStep`, and deterministic exhaustion classification via
    `Orb.Kernel.proxyExhaustionStep`. Targets in `skipAccountIds` or active cooldowns in `healthTracker?`
    are not attempted. -/
def forwardProxyChain
    (chain : RoutingChain)
    (method relPath : String)
    (extraHeaders : Array (String × String))
    (body : ByteArray)
    (mockTransport? : Option (ProviderTarget → IO (Except String HttpsResponse)) := none)
    (headersAlreadyCommitted : Bool := false)
    (pacingTracker? : Option ProxyPacingTracker := none)
    (skipAccountIds : Array String := #[])
    (healthTracker? : Option ProviderHealthTracker := none)
    (attemptGeneration? : Option UInt64 := none)
    (nowEpoch? : Option UInt64 := none)
    (pinnedAccount? : Option String := none)
    (authEvidence? : Option (IO.Ref (Array (String × String))) := none) :
    IO ProxyOutcome := do
  let wantsStream := requestWantsStream relPath body
  let nowSec ← match nowEpoch? with
    | some ep => pure ep
    | none => coreEpochSec
  let healthCooldownIds ← match healthTracker? with
    | none => pure #[]
    | some htr => do
      if headersAlreadyCommitted then
        pure #[]
      else
        let active ← snapshotActiveHealthCooldowns htr nowSec
        pure (active.map (fun c => c.accountId))
  let targets := capProxyTargets (chain.targets.filter (fun t =>
    !skipAccountIds.any (fun id => id == t.accountId) &&
    !healthCooldownIds.any (fun id => id == t.accountId)))
  let n := targets.size
  let explicitPin? : Option String :=
    pinnedAccount?.map (·.trimAscii.toString)
  let routeGen ← match healthTracker? with
    | some htr => currentRouteGeneration htr
    | none => pure 1
  let attemptGen := attemptGeneration?.getD routeGen
  if attemptGen == 0 || routeGen == 0 || attemptGen != routeGen then
    let candSlot0 : UInt32 :=
      match targets[0]? with
      | some t => accountSlotId t.accountId
      | none => 0
    let pinSlot0 : UInt32 :=
      if headersAlreadyCommitted then
        match explicitPin? with
        | some p => if p.isEmpty then 0 else accountSlotId p
        | none => candSlot0
      else
        0
    let v0 := classifyProviderAttempt
      (if headersAlreadyCommitted then 1 else 0) 0 pinSlot0 candSlot0
      0 (if n > 1 then (n - 1).toUInt32 else 0) 0 2 routeGen attemptGen nowSec 0
    return {
      status := 409
      contentType := "application/json"
      headers := #[("X-Orb-Exhaustion-Class", "stale_route_generation")]
      body := "{\"error\":\"stale_route_generation\"}".toUTF8
      selectedAccount := ""
      attemptsUsed := 0
      exhaustionClass := "stale_route_generation"
      firstByteCommitted := headersAlreadyCommitted
      pinnedAccountId := pinSlot0
      verdictCode := v0
    }
  if headersAlreadyCommitted then
    if let some pinnedAcct := explicitPin? then
      if pinnedAcct.isEmpty then
        let candSlot0 : UInt32 :=
          match targets[0]? with
          | some t => accountSlotId t.accountId
          | none => 0
        let vPin0 := classifyProviderAttempt
          1 0 0 candSlot0 0 (if n > 1 then (n - 1).toUInt32 else 0) 0 2 routeGen attemptGen nowSec 0
        return {
          status := 502
          contentType := "application/json"
          headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
          body := "{\"error\":\"committed_stream_missing_pin\"}".toUTF8
          selectedAccount := ""
          attemptsUsed := 0
          exhaustionClass := "committed_stream_aborted"
          firstByteCommitted := true
          pinnedAccountId := 0
          verdictCode := vPin0
        }
  if n == 0 then
    if headersAlreadyCommitted then
      let pinSlot0 : UInt32 :=
        match explicitPin? with
        | some p => if p.isEmpty then 0 else accountSlotId p
        | none => 0
      return {
        status := 502
        contentType := "application/json"
        headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
        body := "{\"error\":\"committed_stream_pin_mismatch\"}".toUTF8
        selectedAccount := ""
        attemptsUsed := 0
        exhaustionClass := "committed_stream_aborted"
        firstByteCommitted := true
        pinnedAccountId := pinSlot0
        verdictCode := ProviderAttemptVerdict.encode .rejectStaleOrPin
      }
    let (st, errCode, errMsg) := classifyExhaustionOutcome 0 0 0 0 0 false
    return {
      status := st
      contentType := "application/json"
      headers := #[("X-Orb-Exhaustion-Class", errCode)]
      body := s!"\{\"error\":{jsonEscape errCode},\"message\":{jsonEscape errMsg}}".toUTF8
      selectedAccount := ""
      attemptsUsed := 0
      exhaustionClass := errCode
      firstByteCommitted := headersAlreadyCommitted
    }
  let effPacing? : Option ProxyPacingTracker :=
    pacingTracker?.orElse (fun _ => healthTracker?.map (fun h => h.pacing))
  let initPin : UInt32 :=
    if headersAlreadyCommitted then
      match explicitPin? with
      | some pinnedAcct => if pinnedAcct.isEmpty then 0 else accountSlotId pinnedAcct
      | none => accountSlotId targets[0]!.accountId
    else
      0
  let maxRetriesU32 : UInt32 := if n > 1 then (n - 1).toUInt32 else 0
  if headersAlreadyCommitted && initPin == 0 then
    let vMissing := classifyProviderAttempt
      1 0 0 (accountSlotId targets[0]!.accountId) 0 maxRetriesU32 0 2 routeGen attemptGen nowSec 0
    return {
      status := 502
      contentType := "application/json"
      headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
      body := "{\"error\":\"committed_stream_missing_pin\"}".toUTF8
      selectedAccount := ""
      attemptsUsed := 0
      exhaustionClass := "committed_stream_aborted"
      firstByteCommitted := true
      pinnedAccountId := 0
      verdictCode := vMissing
    }
  if headersAlreadyCommitted && !targets.any (fun t => accountSlotId t.accountId == initPin) then
    let vGone := classifyProviderAttempt
      1 0 initPin (accountSlotId targets[0]!.accountId) 0 maxRetriesU32 0 2 routeGen attemptGen nowSec 0
    return {
      status := 502
      contentType := "application/json"
      headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
      body := "{\"error\":\"committed_stream_pin_mismatch\"}".toUTF8
      selectedAccount := ""
      attemptsUsed := 0
      exhaustionClass := "committed_stream_aborted"
      firstByteCommitted := true
      pinnedAccountId := initPin
      verdictCode := vGone
    }
  let mut attemptSlice : ProviderAttemptSliceState := {
    firstByteCommitted := if headersAlreadyCommitted then 1 else 0
    pinnedAccountId := initPin
    attemptsUsed := 0
    transientStreak := 0
    routeGeneration := routeGen
    cooldownUntilEpoch := 0
  }
  let mut idx : Nat := 0
  let mut rateLimitCount : UInt32 := 0
  let mut paymentRequiredCount : UInt32 := 0
  let mut clientAuthErrorCount : UInt32 := 0
  let mut failures : Array (String × String × Nat × String) := #[]
  let mut serverErrorCount : UInt32 := 0
  let mut transportValidationCount : UInt32 := 0
  let mut hasContextOverflow : Bool := false
  while idx < n do
    let tgt := targets[idx]!
    let candSlot := accountSlotId tgt.accountId
    let isCommitted := attemptSlice.firstByteCommitted == 1
    if isCommitted && attemptSlice.pinnedAccountId != 0 && candSlot != attemptSlice.pinnedAccountId then
      return {
        status := 502
        contentType := "application/json"
        headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
        body := "{\"error\":\"committed_stream_pin_mismatch\"}".toUTF8
        selectedAccount := tgt.accountId
        attemptsUsed := idx
        exhaustionClass := "committed_stream_aborted"
        firstByteCommitted := true
        pinnedAccountId := attemptSlice.pinnedAccountId
        verdictCode := ProviderAttemptVerdict.encode .rejectStaleOrPin
      }
    let slotAdmitted ← match effPacing? with
      | none => pure true
      | some tracker => do
        let nowMs ← IO.monoMsNow
        tryAcquireTargetSlot tracker tgt nowMs.toUInt64
    if !slotAdmitted then
      rateLimitCount := rateLimitCount + 1
      let (nextSlice, vCode, _) ← match healthTracker? with
        | some htr =>
          recordHealthAttempt htr attemptSlice tgt.accountId 429 #[] "provider_pacing_limit_exceeded"
            false maxRetriesU32 attemptGen nowSec
        | none =>
          let ev : ProviderAttemptSliceEvent := {
            chunkCommits := 0
            failureReason := 1
            candidateAccountId := candSlot
            maxRetries := maxRetriesU32
            transientThreshold := 2
            attemptGeneration := attemptGen
            nowEpoch := nowSec
            nextCooldownEpoch := nowSec + defaultCooldownSecs .rateLimit
          }
          let v := classifyProviderAttempt
            attemptSlice.firstByteCommitted ev.failureReason
            attemptSlice.pinnedAccountId ev.candidateAccountId
            attemptSlice.attemptsUsed ev.maxRetries
            attemptSlice.transientStreak ev.transientThreshold
            attemptSlice.routeGeneration ev.attemptGeneration
            ev.nowEpoch attemptSlice.cooldownUntilEpoch
          let (s', effs) := stepProviderAttemptSlice attemptSlice ev
          pure (s', v, effs)
      attemptSlice := nextSlice
      if !isCommitted && vCode == ProviderAttemptVerdict.encode .rejectStaleOrPin then
        return {
          status := 409
          contentType := "application/json"
          headers := #[("X-Orb-Exhaustion-Class", "stale_route_generation")]
          body := "{\"error\":\"stale_route_generation\"}".toUTF8
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
          exhaustionClass := "stale_route_generation"
          firstByteCommitted := false
          pinnedAccountId := attemptSlice.pinnedAccountId
          verdictCode := vCode
        }
      else if !isCommitted && vCode != ProviderAttemptVerdict.encode .abortCommittedLock &&
         canFailoverUpstream idx n 429 isCommitted then
        attemptSlice := { attemptSlice with cooldownUntilEpoch := 0 }
        idx := idx + 1
      else if vCode == ProviderAttemptVerdict.encode .abortCommittedLock then
        return {
          status := 502
          contentType := "application/json"
          headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
          body := "{\"error\":\"committed_stream_aborted\",\"reason\":\"provider_pacing_limit_exceeded\"}".toUTF8
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
          exhaustionClass := "committed_stream_aborted"
          firstByteCommitted := true
          pinnedAccountId := attemptSlice.pinnedAccountId
          verdictCode := vCode
        }
      else
        return {
          status := 429
          contentType := "application/json"
          headers := #[("X-Orb-Exhaustion-Class", "rate_limited_or_quota")]
          body := "{\"error\":\"provider_pacing_limit_exceeded\"}".toUTF8
          selectedAccount := tgt.accountId
          attemptsUsed := idx + 1
          exhaustionClass := "rate_limited_or_quota"
          firstByteCommitted := attemptSlice.firstByteCommitted == 1
          pinnedAccountId := attemptSlice.pinnedAccountId
          verdictCode := vCode
        }
    else
      let (isTls, host, port, fullPath, reqHdrs, outBody) := upstreamRequest tgt relPath extraHeaders body
      let respRes : Except String (HttpsResponse × Option BodyPump) ←
        try
          match mockTransport? with
          | some mockFn => pure ((← mockFn tgt).map (·, none))
          | none =>
            if port == 0 then
              pure (.error "invalid_upstream_port")
            else if !isTls && !isPrivatePlaintextHost host then
              pure (.error "plaintext_upstream_disabled")
            else if wantsStream then
              streamingUpstreamRequest isTls method host port fullPath reqHdrs outBody
            else if isTls then
              pure ((← httpsRequest method host port fullPath reqHdrs outBody).map (·, none))
            else
              pure ((← loopbackHttpRequest method host port fullPath reqHdrs outBody).map (·, none))
        catch e =>
          if let some tracker := effPacing? then
            releaseTargetSlot tracker tgt
          throw e
      let releaseSlot : IO Unit := do
        if let some tracker := effPacing? then
          releaseTargetSlot tracker tgt
      let respRes : Except String (HttpsResponse × Option BodyPump) := match respRes with
        | .ok (resp, some rawPump) =>
          .ok (resp, some fun emit => do
            try
              rawPump emit
            finally
              releaseSlot)
        | other => other
      if let .ok (_, some _) := respRes then
        pure ()
      else
        releaseSlot
      match respRes with
      | .ok (resp, pump?) =>
        if let some tracker := effPacing? then
          recordObservedHeaders tracker tgt.accountId resp.headers
        let respBodyStr := (String.fromUTF8? resp.body).getD ""
        if resp.status ≥ 200 && resp.status < 300 then
          let (nextSlice, vCode, _) ← match healthTracker? with
            | some htr =>
              recordHealthAttempt htr attemptSlice tgt.accountId resp.status resp.headers respBodyStr
                true maxRetriesU32 attemptGen nowSec
            | none =>
              let ev : ProviderAttemptSliceEvent := {
                chunkCommits := 1
                failureReason := 0
                candidateAccountId := candSlot
                maxRetries := maxRetriesU32
                transientThreshold := 2
                attemptGeneration := attemptGen
                nowEpoch := nowSec
                nextCooldownEpoch := 0
              }
              let v := classifyProviderAttempt
                attemptSlice.firstByteCommitted ev.failureReason
                attemptSlice.pinnedAccountId ev.candidateAccountId
                attemptSlice.attemptsUsed ev.maxRetries
                attemptSlice.transientStreak ev.transientThreshold
                attemptSlice.routeGeneration ev.attemptGeneration
                ev.nowEpoch attemptSlice.cooldownUntilEpoch
              let (s', effs) := stepProviderAttemptSlice attemptSlice ev
              pure (s', v, effs)
          let (ctype, safeHdrs) := sanitizeUpstreamHeaders resp.headers
          if vCode == ProviderAttemptVerdict.encode .rejectStaleOrPin && !isCommitted then
            if let some pump := pump? then
              discard <| pump (fun _ => pure false)
            return {
              status := 409
              contentType := "application/json"
              headers := #[("X-Orb-Exhaustion-Class", "stale_route_generation")]
              body := "{\"error\":\"stale_route_generation\"}".toUTF8
              selectedAccount := tgt.accountId
              attemptsUsed := idx + 1
              exhaustionClass := "stale_route_generation"
              firstByteCommitted := false
              pinnedAccountId := nextSlice.pinnedAccountId
              verdictCode := vCode
            }
          return {
            status := resp.status
            contentType := ctype
            headers := safeHdrs
            body := resp.body
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            firstByteCommitted := nextSlice.firstByteCommitted == 1
            pinnedAccountId := nextSlice.pinnedAccountId
            verdictCode := vCode
            stream? := pump?
          }
        let upstreamCode := upstreamErrorCode respBodyStr
        failures := failures.push (tgt.provider, tgt.modelId, resp.status, upstreamCode)
        -- The upstream refused this account's login: evidence for the provider's status.
        if let some evidence := authEvidence? then
          if isAuthRejection resp.status upstreamCode respBodyStr then
            evidence.modify (·.push (tgt.accountId, if upstreamCode.isEmpty then s!"http_{resp.status}" else upstreamCode))
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
        let failCode := providerFailureReasonCode resp.status respBodyStr
        let (nextSlice, vCode, _) ← match healthTracker? with
          | some htr =>
            if failCode == 0 && !isCommitted then
              pure (attemptSlice, ProviderAttemptVerdict.encode .dispatchFresh, [])
            else
              recordHealthAttempt htr attemptSlice tgt.accountId resp.status resp.headers respBodyStr
                false maxRetriesU32 attemptGen nowSec
          | none =>
            let effFail : UInt8 := if isCommitted && failCode == 0 then 4 else failCode
            let ev : ProviderAttemptSliceEvent := {
              chunkCommits := 0
              failureReason := effFail
              candidateAccountId := candSlot
              maxRetries := maxRetriesU32
              transientThreshold := 2
              attemptGeneration := attemptGen
              nowEpoch := nowSec
              nextCooldownEpoch :=
                match cooldownReasonFor resp.status respBodyStr with
                | some r => nowSec + defaultCooldownSecs r
                | none => 0
            }
            let v := classifyProviderAttempt
              attemptSlice.firstByteCommitted ev.failureReason
              attemptSlice.pinnedAccountId ev.candidateAccountId
              attemptSlice.attemptsUsed ev.maxRetries
              attemptSlice.transientStreak ev.transientThreshold
              attemptSlice.routeGeneration ev.attemptGeneration
              ev.nowEpoch attemptSlice.cooldownUntilEpoch
            let (s', effs) := stepProviderAttemptSlice attemptSlice ev
            pure (s', v, effs)
        attemptSlice := nextSlice
        if vCode == ProviderAttemptVerdict.encode .abortCommittedLock || isCommitted then
          return {
            status := if resp.status ≥ 400 then resp.status else 502
            contentType := "application/json"
            headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
            body := s!"\{\"error\":\"committed_stream_aborted\",\"upstream_status\":{resp.status}}".toUTF8
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            exhaustionClass := "committed_stream_aborted"
            firstByteCommitted := true
            pinnedAccountId := attemptSlice.pinnedAccountId
            verdictCode := ProviderAttemptVerdict.encode .abortCommittedLock
          }
        else if vCode == ProviderAttemptVerdict.encode .rejectStaleOrPin then
          return {
            status := 409
            contentType := "application/json"
            headers := #[("X-Orb-Exhaustion-Class", "stale_route_generation")]
            body := "{\"error\":\"stale_route_generation\"}".toUTF8
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            exhaustionClass := "stale_route_generation"
            firstByteCommitted := false
            pinnedAccountId := attemptSlice.pinnedAccountId
            verdictCode := vCode
          }
        else if canFailoverUpstream idx n resp.status false then
          attemptSlice := { attemptSlice with cooldownUntilEpoch := 0 }
          idx := idx + 1
        else if paymentRequiredCount > 0 || failures.size > 1 ||
                paymentRequiredCount + rateLimitCount + serverErrorCount > 1 then
          -- Every target of the chain failed: one classified error naming each target's
          -- outcome. A single-target request keeps the upstream's own answer (below).
          let (st, errCode, errMsg) :=
            classifyExhaustionOutcome rateLimitCount paymentRequiredCount clientAuthErrorCount
              serverErrorCount transportValidationCount hasContextOverflow
          return {
            status := st
            contentType := "application/json"
            headers := #[("X-Orb-Exhaustion-Class", errCode)]
            body := chainExhaustedBody errCode errMsg failures
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            exhaustionClass := errCode
            firstByteCommitted := attemptSlice.firstByteCommitted == 1
            pinnedAccountId := attemptSlice.pinnedAccountId
            verdictCode := vCode
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
            firstByteCommitted := attemptSlice.firstByteCommitted == 1
            pinnedAccountId := attemptSlice.pinnedAccountId
            verdictCode := vCode
          }
      | .error errMsg =>
        failures := failures.push (tgt.provider, tgt.modelId, 0, "transport_error")
        serverErrorCount := serverErrorCount + 1
        if errMsg == "invalid_upstream_port" || errMsg == "plaintext_upstream_disabled" then
          transportValidationCount := transportValidationCount + 1
        let (nextSlice, vCode, _) ← match healthTracker? with
          | some htr =>
            recordHealthAttempt htr attemptSlice tgt.accountId 503 #[] errMsg
              false maxRetriesU32 attemptGen nowSec
          | none =>
            let ev : ProviderAttemptSliceEvent := {
              chunkCommits := 0
              failureReason := 4
              candidateAccountId := candSlot
              maxRetries := maxRetriesU32
              transientThreshold := 2
              attemptGeneration := attemptGen
              nowEpoch := nowSec
              nextCooldownEpoch := nowSec + defaultCooldownSecs .overloaded
            }
            let v := classifyProviderAttempt
              attemptSlice.firstByteCommitted ev.failureReason
              attemptSlice.pinnedAccountId ev.candidateAccountId
              attemptSlice.attemptsUsed ev.maxRetries
              attemptSlice.transientStreak ev.transientThreshold
              attemptSlice.routeGeneration ev.attemptGeneration
              ev.nowEpoch attemptSlice.cooldownUntilEpoch
            let (s', effs) := stepProviderAttemptSlice attemptSlice ev
            pure (s', v, effs)
        attemptSlice := nextSlice
        if vCode == ProviderAttemptVerdict.encode .abortCommittedLock || isCommitted then
          return {
            status := 502
            contentType := "application/json"
            headers := #[("X-Orb-Exhaustion-Class", "committed_stream_aborted")]
            body := s!"\{\"error\":{jsonEscape errMsg},\"exhaustion_class\":\"committed_stream_aborted\"}".toUTF8
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            exhaustionClass := "committed_stream_aborted"
            firstByteCommitted := true
            pinnedAccountId := attemptSlice.pinnedAccountId
            verdictCode := ProviderAttemptVerdict.encode .abortCommittedLock
          }
        else if vCode == ProviderAttemptVerdict.encode .rejectStaleOrPin then
          return {
            status := 409
            contentType := "application/json"
            headers := #[("X-Orb-Exhaustion-Class", "stale_route_generation")]
            body := "{\"error\":\"stale_route_generation\"}".toUTF8
            selectedAccount := tgt.accountId
            attemptsUsed := idx + 1
            exhaustionClass := "stale_route_generation"
            firstByteCommitted := false
            pinnedAccountId := attemptSlice.pinnedAccountId
            verdictCode := vCode
          }
        else if canFailoverUpstream idx n 503 false then
          attemptSlice := { attemptSlice with cooldownUntilEpoch := 0 }
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
            firstByteCommitted := attemptSlice.firstByteCommitted == 1
            pinnedAccountId := attemptSlice.pinnedAccountId
            verdictCode := vCode
          }
  let (st, errCode, errMsg) :=
    classifyExhaustionOutcome rateLimitCount paymentRequiredCount clientAuthErrorCount
      serverErrorCount transportValidationCount hasContextOverflow
  return {
    status := st
    contentType := "application/json"
    headers := #[("X-Orb-Exhaustion-Class", errCode)]
    body := chainExhaustedBody errCode errMsg failures
    selectedAccount := ""
    attemptsUsed := n
    exhaustionClass := errCode
    firstByteCommitted := attemptSlice.firstByteCommitted == 1
    pinnedAccountId := attemptSlice.pinnedAccountId
  }

/-- Filter `chain.targets` according to a user's `user_provider_prefs` (`(providerId, enabled)` pairs;
    providers omitted from `prefs` default to `true`). Checks both `tgt.accountId` and `tgt.provider`
    (plus stripped `custom:<id>`). -/
def filterChainTargetsForUserPrefs (chain : RoutingChain) (userPrefs : Array (String × Bool)) : RoutingChain :=
  if userPrefs.isEmpty then chain
  else
    let allowed (tgt : ProviderTarget) : Bool :=
      let stripped := if tgt.provider.startsWith "custom:" then (tgt.provider.drop 7).toString else tgt.provider
      isUserProviderEnabled userPrefs tgt.accountId &&
      isUserProviderEnabled userPrefs tgt.provider &&
      isUserProviderEnabled userPrefs stripped
    { chain with targets := chain.targets.filter allowed }

/-- Estimate inference cost in USD cents from a `2xx` upstream JSON response body or explicit
    `X-Orb-Cost-Cents` header (`minimum 1 cent` whenever positive token usage is reported). -/
def estimateProxyUsageCostCents (respHdrs : Array (String × String)) (respBody : ByteArray) : UInt64 := Id.run do
  for (hk, hv) in respHdrs do
    if hk.trimAscii.toString.toLower == "x-orb-cost-cents" then
      if let some n := hv.trimAscii.toString.toNat? then
        return n.toUInt64
  let rawStr := (String.fromUTF8? respBody).getD ""
  match OrbBin.Json.parse rawStr with
  | .ok jv =>
    if let some usageObj := jv.field? "usage" then
      let inToks :=
        (usageObj.fieldNat? "input_tokens").orElse (fun _ => usageObj.fieldNat? "prompt_tokens") |>.getD 0
      let outToks :=
        (usageObj.fieldNat? "output_tokens").orElse (fun _ => usageObj.fieldNat? "completion_tokens") |>.getD 0
      let totalToks :=
        (usageObj.fieldNat? "total_tokens").getD (inToks + outToks)
      if totalToks == 0 && inToks == 0 && outToks == 0 then
        return 0
      -- Conservative blended estimate (~$3/1M input + ~$15/1M output => cents = ceil((3*in + 15*out)/10000), min 1 cent)
      let weighted := inToks * 3 + outToks * 15 + (if inToks == 0 && outToks == 0 then totalToks * 5 else 0)
      let cents := (weighted + 9999) / 10000
      return (Nat.max 1 cents).toUInt64
    return 0
  | .error _ =>
    return 0

/-- Token counts of one inference call. `input` excludes cached tokens, so the four counts add up
    to the tokens the provider processed. -/
structure ProxyUsage where
  input       : Nat := 0
  output      : Nat := 0
  cacheCreate : Nat := 0
  cacheRead   : Nat := 0
  reasoning   : Nat := 0
  deriving Repr, DecidableEq, Inhabited

def ProxyUsage.total (u : ProxyUsage) : Nat := u.input + u.output + u.cacheCreate + u.cacheRead

/-- Reads a `usage` object in Chat Completions, Responses or Anthropic Messages spelling. -/
def proxyUsageOfObject (u : JVal) : ProxyUsage :=
  let detail (obj key : String) : Nat := ((u.field? obj).bind (·.fieldNat? key)).getD 0
  let cachedInPrompt := Nat.max (detail "prompt_tokens_details" "cached_tokens") (detail "input_tokens_details" "cached_tokens")
  let anthropicCacheRead := (u.fieldNat? "cache_read_input_tokens").getD 0
  let rawInput := ((u.fieldNat? "input_tokens").orElse (fun _ => u.fieldNat? "prompt_tokens")).getD 0
  { input := rawInput - Nat.min rawInput cachedInPrompt
    output := ((u.fieldNat? "output_tokens").orElse (fun _ => u.fieldNat? "completion_tokens")).getD 0
    cacheCreate := (u.fieldNat? "cache_creation_input_tokens").getD 0
    cacheRead := Nat.max cachedInPrompt anthropicCacheRead
    reasoning := Nat.max (detail "completion_tokens_details" "reasoning_tokens") (detail "output_tokens_details" "reasoning_tokens") }

private def proxyUsageOfEvent (jv : JVal) : ProxyUsage :=
  let fromField (holder : JVal) : ProxyUsage := ((holder.field? "usage").map proxyUsageOfObject).getD {}
  let merge (a b : ProxyUsage) : ProxyUsage :=
    { input := Nat.max a.input b.input, output := Nat.max a.output b.output
      cacheCreate := Nat.max a.cacheCreate b.cacheCreate, cacheRead := Nat.max a.cacheRead b.cacheRead
      reasoning := Nat.max a.reasoning b.reasoning }
  #["message", "response"].foldl (fun acc key => merge acc (((jv.field? key).map fromField).getD {})) (fromField jv)

/-- Token usage of a buffered upstream response: a JSON body, or an SSE stream whose events report
    usage piecemeal (Anthropic sends input counts first and output counts last), merged per field. -/
def extractProxyUsage (body : ByteArray) : ProxyUsage := Id.run do
  let text := (String.fromUTF8? body).getD ""
  if let .ok jv := OrbBin.Json.parse text then
    return proxyUsageOfEvent jv
  let mut acc : ProxyUsage := {}
  for line in text.splitOn "\n" do
    let t := line.trimAscii.toString
    if t.startsWith "data:" then
      if let .ok jv := OrbBin.Json.parse ((t.drop 5).toString.trimAscii.toString) then
        let u := proxyUsageOfEvent jv
        acc := { input := Nat.max acc.input u.input, output := Nat.max acc.output u.output
                 cacheCreate := Nat.max acc.cacheCreate u.cacheCreate, cacheRead := Nat.max acc.cacheRead u.cacheRead
                 reasoning := Nat.max acc.reasoning u.reasoning }
  return acc

/-- Estimated cost in cents at the blended list price `estimateProxyUsageCostCents` assumes
    ($3 / $15 per million input / output tokens, cache writes at 1.25x and cache reads at 0.1x of input),
    rounded to the nearest cent. Core has no per-model price table. -/
def estimateUsageCostCents (u : ProxyUsage) : UInt64 :=
  Orb.Kernel.costCentsStep (u.input + u.cacheCreate).toUInt64 u.output.toUInt64 u.cacheCreate.toUInt64 u.cacheRead.toUInt64
    3000 15000 3750 300

/-- Appends one `proxy_usage` row; calls that report no tokens are not recorded. -/
def recordProxyUsage (store : CoreStore) (nowEpochSec : UInt64) (model provider accountId apiKeyName missionId callerKind : String)
    (u : ProxyUsage) (requestedModel : String := "") : IO Unit := do
  if u.total == 0 then return
  discard <| execParamQuery store.missionsDb
    ("INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,cost_cents," ++
     "provider,account_id,api_key_name,mission_id,caller_kind,reasoning_tokens,requested_model) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,NULLIF(?11,''),?12,?13,NULLIF(?14,''));")
    #[formatEpochIso8601Utc nowEpochSec, model, toString u.input, toString u.output, toString u.cacheCreate, toString u.cacheRead,
      toString (estimateUsageCostCents u), provider, accountId, apiKeyName, missionId, callerKind, toString u.reasoning,
      requestedModel]

end OrbCore.Proxy
