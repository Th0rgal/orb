import Std.Sync.Mutex
import LeanSys
import Orb.Kernel
import OrbNetLeaf
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.Sqlite
import OrbBin.GitWorkspace
import OrbBin.ClaudeControl
import OrbLocald.Spec
import OrbLocald.NativeChrome

/-
  OrbLocald.Rpc — Loopback JSON-RPC & transport proxy bridge for Orb desktop:
    - All 89 desktop IPC commands (`88` commands + `plugin:app|version`)
    - `transport_bridge_configure` with 6 dedicated live SSE stream shard sockets,
      0ms local OPTIONS CORS preflight, DoH (`1.1.1.1` / `8.8.8.8`), and
      3-way failover (`orbcore.thomas.md` <-> `agent-backend.nico-best-pc-ever.ovh` <-> `agent-backend.thomas.md`)
    - `Channel<T>` subscription token & queued event delivery (`*_subscribe` / `*_unsubscribe` / `__orb_poll_events`)
    - Paloma Secure Enclave approval signer delegation (`orb-signer`) & grace gate
-/

namespace OrbLocald.Rpc

open OrbBin.Json
open OrbLocald.Spec

def defaultFailoverOrigins : Array String := #[
  "https://orbcore.thomas.md",
  "https://agent-backend.thomas.md",
  "https://agent-backend.nico-best-pc-ever.ovh"
]

/-- Ordered Edge-diverse candidate HTTPS origins matching `candidateApiUrls` in `orb/src/api.ts`:
    - Hosted Orb endpoints rotate across distinct network edges (`orbcore.thomas.md` -> Cloudflare BBR `agent-backend.thomas.md` -> direct OVH `agent-backend.nico-best-pc-ever.ovh`).
    - Custom/self-hosted origins never leak requests to hosted failover endpoints. -/
def candidateOriginsFor (raw : String) : Array String :=
  let clean := OrbBin.PosixExt.stripTrailingSlash raw.trimAscii.toString
  if clean.isEmpty || !clean.startsWith "https://" ||
     clean.toList.any (fun c => c.toNat ≤ 0x20 || c.toNat == 0x7F) then
    defaultFailoverOrigins
  else
    let low := clean.toLower
    if low == "https://orbcore.thomas.md" then
      #[clean, "https://agent-backend.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh"]
    else if low == "https://agent-backend.nico-best-pc-ever.ovh" then
      #[clean, "https://agent-backend.thomas.md", "https://orbcore.thomas.md"]
    else if low == "https://agent-backend.thomas.md" then
      #[clean, "https://orbcore.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh"]
    else if low.endsWith ".thomas.md" then
      #[clean, "https://agent-backend.thomas.md", "https://orbcore.thomas.md"]
    else
      #[clean]

abbrev candidateFailoverOrigins := candidateOriginsFor

/-- Classify local transport proxy requests into `P0` (`0`), `P1` (`1`), or `P2` (`2`) priority lanes. -/
def classifyProxyRequestPriority (method relPath : String) (explicitPrio? : Option String := none) : UInt8 :=
  match explicitPrio? with
  | some "p0" | some "0" => 0
  | some "p2" | some "2" => 2
  | some "p1" | some "1" => 1
  | _ =>
    let m := method.trimAscii.toString.toUpper
    let p := (relPath.splitOn "?").head?.getD relPath
    if p == "/api/file-resources" || p.endsWith "/inbox-digest" || p.endsWith "/opened" ||
       p.startsWith "/api/control/inbox-state/seen/" then
      1
    else if m != "GET" && m != "HEAD" && m != "OPTIONS" then
      0
    else if p == "/api/health" || p.startsWith "/api/auth/" || p.startsWith "/api/bitwarden/" || p.startsWith "/api/privilege-access/" then
      0
    else if p.startsWith "/api/software" || p.startsWith "/api/stats" ||
            p.startsWith "/api/providers/antigravity-models" ||
            p.startsWith "/api/antigravity-models" || p.startsWith "/api/crons" ||
            p.startsWith "/api/library/skill-delivery" || p.startsWith "/api/ai/providers/usage" ||
            p.startsWith "/api/usage-telemetry" || p.startsWith "/api/remote-nodes" ||
            p.endsWith "/context/conflicts" || p.endsWith "/context/manifest" ||
            p.endsWith "/automations" || p.endsWith "/machine-transfer" ||
            p.endsWith "/files" || (p.splitOn "/files/").length > 1 then
      2
    else
      1

/-- True when an upstream proxy request's latency reflects server-side subprocess/provider work
    rather than network link RTT, so it must not update `originHealth.srttMs`. -/
def isComputeBoundProxyRequest (method relPath : String) : Bool :=
  let m := method.trimAscii.toString.toUpper
  let p := (relPath.splitOn "?").head?.getD relPath
  (m != "GET" && m != "HEAD" && m != "OPTIONS") ||
  p == "/api/file-resources" ||
  p.endsWith "/inbox-digest" ||
  p.startsWith "/api/software" ||
  p.startsWith "/api/stats" ||
  p.startsWith "/api/resources/" ||
  p.startsWith "/api/usage" ||
  p.startsWith "/api/proxy-health" ||
  p.startsWith "/api/providers/antigravity-models" ||
  p.startsWith "/api/antigravity-models" ||
  p == "/api/ai/providers/usage" ||
  (p.startsWith "/api/ai/providers/" && p.endsWith "/usage")

/-- Per-origin EWMA RTT and cooldown health tracked inside `orb-locald`. -/
structure OriginHealthEntry where
  origin              : String
  srttMs              : UInt32 := 0
  rttVarMs            : UInt32 := 0
  consecutiveFailures : UInt32 := 0
  cooldownUntilMs     : Nat := 0
  deriving Repr, Inhabited

/-- Rank candidate origins so non-cooled origins come first while preserving configured tie-break order. -/
def rankFailoverOrigins (origins : Array String) (health : Array OriginHealthEntry) (nowMs : Nat) : Array String :=
  let isCooled (orig : String) : Bool :=
    match health.find? (fun h => h.origin == orig) with
    | some h => h.cooldownUntilMs > nowMs
    | none => false
  let healthy := origins.filter (fun o => !isCooled o)
  let cooled := origins.filter isCooled
  healthy ++ cooled

def defaultDohEndpoints : Array String := #[
  "https://1.1.1.1/dns-query",
  "https://8.8.8.8/dns-query"
]

structure TransportBridgeState where
  proxyPort        : UInt16 := 19480
  bridgeUuid       : String := "00000000-0000-4000-8000-000000000001"
  shardPorts       : Array UInt16 := #[19481, 19482, 19483, 19484, 19485, 19486]
  configuredTarget : String := "https://orbcore.thomas.md"
  failoverOrigins  : Array String := defaultFailoverOrigins
  dohEndpoints     : Array String := defaultDohEndpoints
  deriving Repr, Inhabited

def TransportBridgeState.proxyBaseUrl (st : TransportBridgeState) : String :=
  s!"http://127.0.0.1:{st.proxyPort}/__orb_tx/{st.bridgeUuid}"

def TransportBridgeState.streamProxyBaseUrls (st : TransportBridgeState) : Array String :=
  st.shardPorts.map fun p => s!"http://127.0.0.1:{p}/__orb_tx/{st.bridgeUuid}"

def TransportBridgeState.toJson (st : TransportBridgeState) : JVal :=
  .obj #[
    ("proxy_base_url", .str st.proxyBaseUrl),
    ("stream_proxy_base_urls", .arr (st.streamProxyBaseUrls.map .str)),
    ("configured_target", .str st.configuredTarget),
    ("failover_origins", .arr (st.failoverOrigins.map .str)),
    ("doh_endpoints", .arr (st.dohEndpoints.map .str))
  ]

/-- Read `n` CSPRNG bytes from `/dev/urandom` as lowercase hex (`2*n` chars). -/
def randomHexBytes (nBytes : Nat := 16) : IO String := do
  let h ← IO.FS.Handle.mk "/dev/urandom" .read
  let bs ← h.read nBytes.toUSize
  return LeanSys.Auth.bytesToHexLower bs

/-- Generate a RFC 4122 v4 random UUID (`8-4-4-4-12` lowercase hex) from `/dev/urandom`. -/
def randomUuidV4 : IO String := do
  let h ← IO.FS.Handle.mk "/dev/urandom" .read
  let raw ← h.read 16
  if raw.size < 16 then
    return "550e8400-e29b-41d4-a716-446655440000"
  let b6 := ((raw.get! 6) &&& 0x0F) ||| 0x40
  let b8 := ((raw.get! 8) &&& 0x3F) ||| 0x80
  let mut patched := ByteArray.emptyWithCapacity 16
  for i in [0:16] do
    if i == 6 then patched := patched.push b6
    else if i == 8 then patched := patched.push b8
    else patched := patched.push (raw.get! i)
  let hex := LeanSys.Auth.bytesToHexLower patched
  return (hex.take 8).toString ++ "-" ++
         ((hex.drop 8).take 4).toString ++ "-" ++
         ((hex.drop 12).take 4).toString ++ "-" ++
         ((hex.drop 16).take 4).toString ++ "-" ++
         (hex.drop 20).toString

/-- Check if an HTTP method is safe to retry across failover origins without Idempotency-Key. -/
def isSafeHttpMethod (m : String) : Bool :=
  let u := m.toUpper
  u == "GET" || u == "HEAD" || u == "OPTIONS"

/-- Decide whether a transport request may fail over to `nextOriginIdx`. -/
def canFailoverRequest (method : String) (hasIdempotencyKey : Bool)
    (nextOriginIdx : Nat) (origins : Array String) : Bool :=
  let safeFlag : UInt8 := if isSafeHttpMethod method then 1 else 0
  let idemFlag : UInt8 := if hasIdempotencyKey then 1 else 0
  let nextU8 : UInt8 := UInt8.ofNat (min nextOriginIdx 255)
  let countU8 : UInt8 := UInt8.ofNat (min origins.size 255)
  verifyTransportWriteRetry safeFlag idemFlag nextU8 countU8 == 1

private def isHexChar (c : Char) : Bool :=
  ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

/-- Strict canonical `8-4-4-4-12` hex UUID check matching `macos_shell/signer/main.swift`. -/
def isCanonicalUuid (s : String) : Bool :=
  if s.utf8ByteSize != 36 then false
  else
    match s.splitOn "-" with
    | [p1, p2, p3, p4, p5] =>
      p1.utf8ByteSize == 8 && p2.utf8ByteSize == 4 && p3.utf8ByteSize == 4 &&
      p4.utf8ByteSize == 4 && p5.utf8ByteSize == 12 &&
      [p1, p2, p3, p4, p5].all (fun part => part.toList.all isHexChar)
    | _ => false

/-- Check whether a Paloma approval payload is eligible to reuse Touch ID grace
    (matches `macos_shell/signer/main.swift` line-by-line: `paloma-approval-v1`, non-empty summary,
    exact `/api/bitwarden/requests/<canonical-uuid>/approve|reject` without `//` collapse). -/
def isPalomaPayloadGraceEligible (payload : String) : Bool :=
  let lines := (payload.splitOn "\n").toArray
  if lines.size >= 6 && lines[0]! == "paloma-approval-v1" && !(lines[5]!).trimAscii.toString.isEmpty then
    let routeParts := ((lines[2]!).splitOn " ").toArray
    if routeParts.size == 2 then
      let isPost : UInt8 := if routeParts[0]! == "POST" then 1 else 0
      let rawPath := routeParts[1]!
      let segs := (rawPath.splitOn "/").toArray
      if rawPath.startsWith "/" && segs.size == 6 && segs[0]! == "" then
        let isBw : UInt8 :=
          if segs[1]! == "api" && segs[2]! == "bitwarden" && segs[3]! == "requests" then 1 else 0
        let u := segs[4]!
        let uuidLen : UInt32 := if isCanonicalUuid u then UInt32.ofNat u.utf8ByteSize else 0
        let act := segs[5]!
        let actCode : UInt8 := if act == "approve" then 1 else if act == "reject" then 2 else 0
        verifyPalomaGraceEligible isPost isBw uuidLen actCode == 1
      else false
    else false
  else false

structure SubscriptionEntry where
  token   : Nat
  channel : String
  target? : Option String := none
  active  : Bool := true
  deriving Repr, Inhabited

/-- Lifecycle states for a run-scoped interactive tool / bridge slot (`SM-11`).
    `"native-*"` request ids share this exact lifecycle with zero prefix bypass. -/
inductive InteractiveToolSlotLifecycle where
  | waitingAck
  | earlyBuffered
  | answered (responseJson : JVal)
  | cancelled (reason : String)
  deriving Repr, Inhabited, BEq

def InteractiveToolSlotLifecycle.isActive : InteractiveToolSlotLifecycle → Bool
  | .waitingAck | .earlyBuffered => true
  | .answered _ | .cancelled _   => false

def InteractiveToolSlotLifecycle.label : InteractiveToolSlotLifecycle → String
  | .waitingAck     => "waiting_ack"
  | .earlyBuffered  => "early_buffered"
  | .answered _     => "answered"
  | .cancelled _    => "cancelled"

structure InteractiveToolSlot where
  runId         : String
  sessionEpoch  : UInt64
  requestId     : String
  payload       : JVal
  payloadDigest : String
  lifecycle     : InteractiveToolSlotLifecycle
  deriving Repr, Inhabited, BEq

structure RunToolSlotTable where
  runId        : String
  currentEpoch : UInt64 := 1
  slots        : Array InteractiveToolSlot := #[]
  deriving Repr, Inhabited

structure InteractiveToolHubState where
  maxCap : UInt16 := maxInteractiveToolSlots.toUInt16
  runs   : Array RunToolSlotTable := #[]
  deriving Repr, Inhabited

private partial def canonicalizeJsonValue : JVal → JVal
  | .null => .null
  | .bool b => .bool b
  | .num raw => .num raw.trimAscii.toString
  | .str s => .str s
  | .arr xs => .arr (xs.map canonicalizeJsonValue)
  | .obj kvs =>
    let mapped := kvs.map fun (k, v) => (k, canonicalizeJsonValue v)
    let sorted := mapped.qsort (fun a b => a.1 < b.1)
    .obj sorted

def digestToolPayload (payload : JVal) : String :=
  let canon := renderCompact (canonicalizeJsonValue payload)
  LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes canon.toUTF8)

def InteractiveToolSlot.toSummaryJson (s : InteractiveToolSlot) : JVal :=
  let base : Array (String × JVal) := #[
    ("run_id", .str s.runId),
    ("session_epoch", JVal.uint64 s.sessionEpoch),
    ("request_id", .str s.requestId),
    ("state", .str s.lifecycle.label),
    ("active", .bool s.lifecycle.isActive),
    ("payload_digest", .str s.payloadDigest),
    ("payload", s.payload)
  ]
  let extra : Array (String × JVal) := match s.lifecycle with
    | .answered resp => #[("answer", resp)]
    | .cancelled r   => #[("cancel_reason", .str r)]
    | _              => #[]
  .obj (base ++ extra)

def InteractiveToolSlot.toClientRequestJson (s : InteractiveToolSlot) : JVal :=
  match s.payload with
  | .obj _ =>
    if (s.payload.fieldStr? "id").isSome then s.payload
    else s.payload.setField "id" (.str s.requestId)
  | _ =>
    .obj #[("id", .str s.requestId), ("method", .str "questions"), ("params", s.payload)]

def RunToolSlotTable.activeCount (tbl : RunToolSlotTable) : Nat :=
  (tbl.slots.filter fun s => s.sessionEpoch == tbl.currentEpoch && s.lifecycle.isActive).size

def RunToolSlotTable.firstActiveSlot? (tbl : RunToolSlotTable) : Option InteractiveToolSlot :=
  tbl.slots.find? fun s => s.sessionEpoch == tbl.currentEpoch && s.lifecycle.isActive

def InteractiveToolHubState.findRun? (hub : InteractiveToolHubState) (runId : String) : Option RunToolSlotTable :=
  hub.runs.find? fun r => r.runId == runId

private def upsertRunTable (hub : InteractiveToolHubState) (tbl : RunToolSlotTable) : InteractiveToolHubState :=
  if hub.runs.any (fun r => r.runId == tbl.runId) then
    { hub with runs := hub.runs.map (fun r => if r.runId == tbl.runId then tbl else r) }
  else
    { hub with runs := hub.runs.push tbl }

private def cancelPriorEpochs (slots : Array InteractiveToolSlot) (newEpoch : UInt64) (reason : String) :
    Array InteractiveToolSlot :=
  slots.map fun s =>
    if s.sessionEpoch < newEpoch && s.lifecycle.isActive then
      { s with lifecycle := .cancelled reason }
    else s

/-- Admit or replay a run-scoped interactive tool slot (`register` or `offer_early`),
    gated authoritatively by `OrbLocald.Spec.verifyInteractiveToolSlotAdmit`.
    Never evicts active `waitingAck` or `earlyBuffered` slots; returns explicit errors on
    stale epoch, conflicting duplicate payload, or capacity exhaustion (`interactive_slot_backpressure`). -/
def InteractiveToolHubState.admitSlot
    (hub : InteractiveToolHubState)
    (runId : String)
    (sessionEpoch : UInt64)
    (requestId : String)
    (payload : JVal)
    (isEarly : Bool) : Except String (InteractiveToolSlot × Bool × InteractiveToolHubState) := do
  let cleanRun := runId.trimAscii.toString
  let cleanReq := requestId.trimAscii.toString
  let hasRunFlag : UInt8 := if cleanRun.isEmpty then 0 else 1
  let hasReqFlag : UInt8 := if cleanReq.isEmpty then 0 else 1
  let existingTbl : RunToolSlotTable :=
    (hub.findRun? cleanRun).getD { runId := cleanRun, currentEpoch := (if sessionEpoch > 0 then sessionEpoch else 1), slots := #[] }
  let curEpoch := existingTbl.currentEpoch
  let effectiveTbl : RunToolSlotTable :=
    if sessionEpoch > curEpoch then
      { existingTbl with
          currentEpoch := sessionEpoch,
          slots := cancelPriorEpochs existingTbl.slots sessionEpoch "superseded_epoch" }
    else existingTbl
  let digest := digestToolPayload payload
  let existingSlot? := effectiveTbl.slots.find? fun s =>
    s.sessionEpoch == sessionEpoch && s.requestId == cleanReq
  let (dupFlag, sameFlag, confFlag) : (UInt8 × UInt8 × UInt8) :=
    match existingSlot? with
    | none => (0, 0, 0)
    | some prev =>
      if prev.payloadDigest == digest then (1, 1, 0) else (1, 0, 1)
  let activeU16 : UInt16 := UInt16.ofNat (min effectiveTbl.activeCount 65535)
  let maxCapU16 : UInt16 := hub.maxCap
  let gateVerdict := verifyInteractiveToolSlotAdmit
    activeU16 maxCapU16 sessionEpoch curEpoch
    hasRunFlag hasReqFlag dupFlag sameFlag confFlag
  if gateVerdict != 1 then
    if hasRunFlag == 0 || hasReqFlag == 0 then
      throw "invalid_tool_slot_identity"
    else if sessionEpoch == 0 || curEpoch == 0 || sessionEpoch < curEpoch then
      throw "stale_session_epoch"
    else if dupFlag == 1 then
      match classifyToolSlotDuplicate sameFlag confFlag with
      | some .conflictingDuplicate => throw "duplicate_request_id_conflict"
      | _ => throw "invalid_tool_slot_duplicate"
    else if maxCapU16 < 1 || maxCapU16 > 256 then
      throw "invalid_tool_slot_capacity"
    else
      throw "interactive_slot_backpressure"
  match existingSlot? with
  | some prev =>
    -- Idempotent replay: promote `earlyBuffered` to `waitingAck` if `register` arrives after `offer_early`,
    -- while preserving `answered` / `cancelled` receipts verbatim without consuming an extra slot.
    let updatedSlot : InteractiveToolSlot :=
      match prev.lifecycle with
      | .earlyBuffered =>
        if !isEarly then { prev with lifecycle := .waitingAck } else prev
      | _ => prev
    let nextSlots := effectiveTbl.slots.map fun s =>
      if s.sessionEpoch == sessionEpoch && s.requestId == cleanReq then updatedSlot else s
    let nextHub := upsertRunTable hub { effectiveTbl with slots := nextSlots }
    return (updatedSlot, true, nextHub)
  | none =>
    let fresh : InteractiveToolSlot := {
      runId := cleanRun
      sessionEpoch := sessionEpoch
      requestId := cleanReq
      payload := payload
      payloadDigest := digest
      lifecycle := if isEarly then .earlyBuffered else .waitingAck
    }
    let nextTbl := { effectiveTbl with slots := effectiveTbl.slots.push fresh }
    let nextHub := upsertRunTable hub nextTbl
    return (fresh, false, nextHub)

def InteractiveToolHubState.answerSlot
    (hub : InteractiveToolHubState)
    (runId : String)
    (sessionEpoch? : Option UInt64)
    (requestId : String)
    (answerJson : JVal) : Except String (InteractiveToolSlot × InteractiveToolHubState) := do
  let cleanRun := runId.trimAscii.toString
  let cleanReq := requestId.trimAscii.toString
  if cleanRun.isEmpty || cleanReq.isEmpty then
    throw "invalid_tool_slot_identity"
  let some tbl := hub.findRun? cleanRun
    | throw "unknown_interactive_slot"
  let targetEpoch := sessionEpoch?.getD tbl.currentEpoch
  if targetEpoch == 0 || targetEpoch < tbl.currentEpoch then
    throw "stale_session_epoch"
  if targetEpoch > tbl.currentEpoch then
    throw "unknown_interactive_slot"
  let some slot := tbl.slots.find? (fun s => s.sessionEpoch == targetEpoch && s.requestId == cleanReq)
    | throw "unknown_interactive_slot"
  match slot.lifecycle with
  | .cancelled _ =>
    throw "cancelled_interactive_slot"
  | .answered prevAns =>
    if digestToolPayload prevAns == digestToolPayload answerJson then
      return (slot, hub)
    else
      throw "duplicate_answer_conflict"
  | .waitingAck | .earlyBuffered =>
    let updated := { slot with lifecycle := .answered answerJson }
    let nextSlots := tbl.slots.map fun s =>
      if s.sessionEpoch == targetEpoch && s.requestId == cleanReq then updated else s
    let nextHub := upsertRunTable hub { tbl with slots := nextSlots }
    return (updated, nextHub)

def InteractiveToolHubState.cancelRunSlots
    (hub : InteractiveToolHubState)
    (runId : String)
    (reason : String)
    (bumpEpoch : Bool) : (Nat × UInt64 × InteractiveToolHubState) :=
  let cleanRun := runId.trimAscii.toString
  match hub.findRun? cleanRun with
  | none => (0, 1, hub)
  | some tbl =>
    let cancelledCount := (tbl.slots.filter (·.lifecycle.isActive)).size
    let nextSlots := tbl.slots.map fun s =>
      if s.lifecycle.isActive then { s with lifecycle := .cancelled reason } else s
    let nextEpoch := if bumpEpoch then tbl.currentEpoch + 1 else tbl.currentEpoch
    let nextTbl := { tbl with currentEpoch := nextEpoch, slots := nextSlots }
    (cancelledCount, nextEpoch, upsertRunTable hub nextTbl)

def InteractiveToolHubState.reconcileRun
    (hub : InteractiveToolHubState)
    (runId : String)
    (sessionEpoch? : Option UInt64) : Except String (RunToolSlotTable × InteractiveToolHubState) := do
  let cleanRun := runId.trimAscii.toString
  if cleanRun.isEmpty then
    throw "invalid_tool_slot_identity"
  let existingTbl : RunToolSlotTable :=
    (hub.findRun? cleanRun).getD { runId := cleanRun, currentEpoch := (sessionEpoch?.filter (· > 0) |>.getD 1), slots := #[] }
  match sessionEpoch? with
  | none =>
    let nextHub := upsertRunTable hub existingTbl
    return (existingTbl, nextHub)
  | some reqEpoch =>
    if reqEpoch == 0 || reqEpoch < existingTbl.currentEpoch then
      throw "stale_session_epoch"
    else if reqEpoch > existingTbl.currentEpoch then
      let nextTbl : RunToolSlotTable := {
        existingTbl with
          currentEpoch := reqEpoch
          slots := cancelPriorEpochs existingTbl.slots reqEpoch "superseded_epoch"
      }
      let nextHub := upsertRunTable hub nextTbl
      return (nextTbl, nextHub)
    else
      let nextHub := upsertRunTable hub existingTbl
      return (existingTbl, nextHub)

/-- Outbound journal frame buffered on `orb-locald` until Core acknowledges `seq` (`SM-26`). -/
structure ClientLinkJournalFrame where
  seq       : UInt64
  missionId : String
  payload   : JVal
  deriving Repr, Inhabited, BEq

/-- Start-result receipt recorded by `client_link_start_result` (`SM-26`). -/
structure ClientLinkStartReceipt where
  requestId : String
  ok        : Bool
  missionId : Option String := none
  errorMsg  : Option String := none
  deriving Repr, Inhabited, BEq

/-- Epoch-scoped capability latch, 256-frame outbound journal ring, and reconnect resync state (`SM-26`). -/
structure ClientLinkState where
  connected          : Bool := false
  endpoint           : String := ""
  serverBuild        : String := ""
  unsupportedLatched : Bool := false
  maxCap             : UInt16 := maxClientLinkOutboundFrames.toUInt16
  lastAckedSeq       : UInt64 := 0
  headSeq            : UInt64 := 0
  unackedFrames      : Array ClientLinkJournalFrame := #[]
  harnesses          : JVal := .arr #[]
  startReceipts      : Array ClientLinkStartReceipt := #[]
  deriving Repr, Inhabited

private def normalizeEndpointKey (raw : String) : String :=
  OrbBin.PosixExt.stripTrailingSlash raw.trimAscii.toString

/-- Update `(endpoint, server_build)` capability latch via `verifyCapabilityLatch` (`OrbLocald.Spec`). -/
def ClientLinkState.stepEndpointEpoch
    (cl : ClientLinkState)
    (rawEndpoint : String)
    (observedBuild? : Option String := none)
    (observedHttpStatus : UInt16 := 0) : ClientLinkState :=
  let nextEp := normalizeEndpointKey rawEndpoint
  let cleanBuild? := observedBuild?.map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
  let sameEp : UInt8 := if !cl.endpoint.isEmpty && cl.endpoint == nextEp then 1 else 0
  let hasObsB : UInt8 := if cleanBuild?.isSome then 1 else 0
  let sameB : UInt8 :=
    match cleanBuild? with
    | none => 1
    | some b => if !cl.serverBuild.isEmpty && cl.serverBuild == b then 1 else 0
  let prevL : UInt8 := if cl.unsupportedLatched then 1 else 0
  let latchedNext : Bool :=
    verifyCapabilityLatch prevL sameEp sameB observedHttpStatus hasObsB == 1
  let nextBuild : String :=
    if sameEp == 0 then cleanBuild?.getD ""
    else match cleanBuild? with
      | some b => b
      | none => cl.serverBuild
  let nextConnected : Bool :=
    if latchedNext then false
    else if sameEp == 0 then false
    else cl.connected
  { cl with
      endpoint := if nextEp.isEmpty then cl.endpoint else nextEp
      serverBuild := nextBuild
      unsupportedLatched := latchedNext
      connected := nextConnected }

/-- Enqueue one outbound client-link journal frame gated by `verifyJournalRingStep` (`op = 0`).
    Returns `"client_link_journal_backpressure"` at 256 unacked frames instead of overwriting. -/
def ClientLinkState.enqueueFrame
    (cl : ClientLinkState)
    (missionId : String)
    (payload : JVal) : Except String (ClientLinkJournalFrame × ClientLinkState) := do
  if cl.unsupportedLatched then
    throw "client_link_unsupported_for_epoch"
  let unackedU16 := UInt16.ofNat (min cl.unackedFrames.size 65535)
  let targetSeq := if cl.headSeq < 0xFFFFFFFFFFFFFFFF then cl.headSeq + 1 else cl.headSeq
  if verifyJournalRingStep 0 unackedU16 cl.maxCap cl.lastAckedSeq cl.headSeq targetSeq != 1 then
    throw "client_link_journal_backpressure"
  let frame : ClientLinkJournalFrame := {
    seq := targetSeq
    missionId := missionId.trimAscii.toString
    payload := payload
  }
  let nextFrames := cl.unackedFrames.push frame
  return (frame, { cl with headSeq := targetSeq, unackedFrames := nextFrames })

/-- Apply cumulative `ackSeq` gated by `verifyJournalRingStep` (`op = 1`). -/
def ClientLinkState.ackUpTo
    (cl : ClientLinkState)
    (ackSeq : UInt64) : Except String ClientLinkState := do
  let unackedU16 := UInt16.ofNat (min cl.unackedFrames.size 65535)
  if verifyJournalRingStep 1 unackedU16 cl.maxCap cl.lastAckedSeq cl.headSeq ackSeq != 1 then
    throw "client_link_invalid_ack_seq"
  let remaining := cl.unackedFrames.filter (fun f => f.seq > ackSeq)
  return { cl with lastAckedSeq := ackSeq, unackedFrames := remaining }

/-- Compute reconnect resync replay window `(replayFromSeq, framesToReplay)` gated by `verifyJournalRingStep` (`op = 2`). -/
def ClientLinkState.resyncWindow
    (cl : ClientLinkState)
    (peerAckSeq : UInt64) : Except String (UInt64 × Array ClientLinkJournalFrame) := do
  let unackedU16 := UInt16.ofNat (min cl.unackedFrames.size 65535)
  if verifyJournalRingStep 2 unackedU16 cl.maxCap cl.lastAckedSeq cl.headSeq peerAckSeq != 1 then
    throw "client_link_invalid_resync_cursor"
  let floorSeq := if peerAckSeq > cl.lastAckedSeq then peerAckSeq else cl.lastAckedSeq
  let window := cl.unackedFrames.filter (fun f => f.seq > floorSeq)
  return (floorSeq, window)

def ClientLinkState.hasPendingForMission (cl : ClientLinkState) (missionId : String) : Bool :=
  let clean := missionId.trimAscii.toString
  if clean.isEmpty then !cl.unackedFrames.isEmpty
  else cl.unackedFrames.any (fun f => f.missionId == clean)

def ClientLinkState.toSummaryJson (cl : ClientLinkState) : JVal :=
  .obj #[
    ("active", .bool (cl.connected && !cl.unsupportedLatched)),
    ("connected", .bool cl.connected),
    ("endpoint", .str cl.endpoint),
    ("server_build", .str cl.serverBuild),
    ("unsupported_latched", .bool cl.unsupportedLatched),
    ("max_cap", JVal.nat cl.maxCap.toNat),
    ("last_acked_seq", JVal.uint64 cl.lastAckedSeq),
    ("head_seq", JVal.uint64 cl.headSeq),
    ("unacked_count", JVal.nat cl.unackedFrames.size)
  ]

/-- Parse a typed `409 Conflict` tag (`1..5`) from explicit code or structured payload (`SM-23` / `SM-26`). -/
def parseConflictTagCode (code : String) : UInt8 :=
  let c := code.trimAscii.toString.toLower
  if c == "stopping" || c == "remote_job_still_running" then 1
  else if c == "non_terminal_run" || c == "already_running" then 2
  else if c == "already_ended" then 3
  else if c == "moved" || c == "transferred" then 4
  else if c == "stale_receipt" || c == "fenced_receipt" then 5
  else 0

def conflictTagName : UInt8 → String
  | 1 => "stopping"
  | 2 => "non_terminal_run"
  | 3 => "already_ended"
  | 4 => "moved"
  | 5 => "stale_receipt"
  | _ => "unclassified"

/-- Classify an HTTP status + typed conflict code via `verifyLocalConflictDisposition` (`OrbLocald.Spec`). -/
def classifyLocalOriginConflict (httpStatus : UInt16) (code : String) : Option (UInt8 × Bool) :=
  let tag := parseConflictTagCode code
  if verifyLocalConflictDisposition httpStatus tag 1 == 1 then
    some (tag, true)
  else if verifyLocalConflictDisposition httpStatus tag 0 == 1 then
    some (tag, false)
  else
    none

/-- Durable in-memory local-origin mission row managed by `local_origin_*` (`SM-26`). -/
structure LocalOriginEntry where
  id                : String
  runId             : String := ""
  endpoint          : String
  title             : String
  status            : String := "active"
  statusMessage     : Option String := none
  backend           : String := "opencode"
  workingDirectory  : String := "."
  rawPrompt         : String := ""
  deliveredPrompt   : String := ""
  localSyncPending  : Bool := true
  localRunActive    : Bool := true
  syncSeq           : UInt64 := 1
  ackedSeq          : UInt64 := 0
  syncText          : String := ""
  syncError         : Option String := none
  syncLocalOnly     : Bool := false
  observedAt        : UInt64 := 0
  lastConflictCode  : Option String := none
  retryableConflict : Bool := false
  project           : String := ""
  folder            : Option String := none
  tags              : Array String := #["placement:client"]
  modelOverride     : Option String := none
  modelEffort       : Option String := none
  serviceTier       : Option String := none
  cyberAccess       : Option String := none
  createdAt         : String := ""
  updatedAt         : String := ""
  history           : Array JVal := #[]
  deriving Repr, Inhabited

def LocalOriginEntry.toMissionJson (e : LocalOriginEntry) : JVal :=
  let base : Array (String × JVal) := #[
    ("id", .str e.id),
    ("endpoint", .str e.endpoint),
    ("title", .str e.title),
    ("status", .str e.status),
    ("backend", .str e.backend),
    ("working_directory", .str e.workingDirectory),
    ("delivered_prompt", .str e.deliveredPrompt),
    ("placement_kind", .str "client"),
    ("local_sync_pending", .bool e.localSyncPending),
    ("local_run_active", .bool e.localRunActive),
    ("sync_seq", JVal.uint64 e.syncSeq),
    ("acked_seq", JVal.uint64 e.ackedSeq),
    ("sync_text", .str e.syncText),
    ("total_cost_cents", JVal.nat 0),
    ("tags", .arr (e.tags.map .str)),
    ("history", .arr e.history),
    ("created_at", .str (if e.createdAt.isEmpty then "1970-01-01T00:00:00Z" else e.createdAt)),
    ("updated_at", .str (if e.updatedAt.isEmpty then "1970-01-01T00:00:00Z" else e.updatedAt))
  ]
  let withStatusMsg :=
    match e.statusMessage with | some sm => base.push ("status_message", .str sm) | none => base
  let withRun :=
    if e.runId.isEmpty then withStatusMsg else withStatusMsg.push ("run_id", .str e.runId)
  let withRawPrompt :=
    if e.rawPrompt.isEmpty then withRun else withRun.push ("raw_prompt", .str e.rawPrompt)
  let withSyncErr :=
    match e.syncError with | some se => withRawPrompt.push ("local_sync_error", .str se) | none => withRawPrompt
  let withLocalOnly :=
    if e.syncLocalOnly then withSyncErr.push ("local_sync_local_only", .bool true) else withSyncErr
  let withProj :=
    if e.project.isEmpty then withLocalOnly else withLocalOnly.push ("project", .str e.project)
  let withFolder :=
    match e.folder with | some f => withProj.push ("folder", .str f) | none => withProj
  let withModel :=
    match e.modelOverride with | some m => withFolder.push ("model_override", .str m) | none => withFolder
  let withEffort :=
    match e.modelEffort with | some ef => withModel.push ("model_effort", .str ef) | none => withModel
  let withTier :=
    match e.serviceTier with | some st => withEffort.push ("service_tier", .str st) | none => withEffort
  let withCyber :=
    match e.cyberAccess with | some cy => withTier.push ("cyber_access", .str cy) | none => withTier
  let withConflict := match e.lastConflictCode with
    | some code =>
      (withCyber.push ("conflict_code", .str code)).push ("conflict_retryable", .bool e.retryableConflict)
    | none => withCyber
  .obj withConflict

def LocalOriginEntry.fromMissionJson? (jv : JVal) : Option LocalOriginEntry := do
  let id ← jv.fieldStr? "id"
  let runId := (jv.fieldStr? "run_id").getD ""
  let ep := (jv.fieldStr? "endpoint").getD ""
  let title := (jv.fieldStr? "title").getD "Local Mission"
  let status := (jv.fieldStr? "status").getD "active"
  let rawStatusMsg := (jv.fieldStr? "status_message").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let rawSyncErr := (jv.fieldStr? "local_sync_error").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let migratedTurnErr :=
    match rawStatusMsg, rawSyncErr with
    | none, some se => if status == "failed" && !(se.startsWith "Core synchronization ") then some se else none
    | _, _ => none
  let statusMessage := rawStatusMsg.orElse (fun _ => migratedTurnErr)
  let syncError := if migratedTurnErr.isSome then none else rawSyncErr
  let syncLocalOnly := (jv.fieldBool? "local_sync_local_only").getD false
  let backend := (jv.fieldStr? "backend").getD "opencode"
  let cwd := (jv.fieldStr? "working_directory").getD "."
  let prompt := (jv.fieldStr? "delivered_prompt").getD ""
  let rawPrompt := (jv.fieldStr? "raw_prompt").getD prompt
  let syncPend := (jv.fieldBool? "local_sync_pending").getD false
  let runAct := (jv.fieldBool? "local_run_active").getD false
  let syncSeq := (jv.fieldUInt64? "sync_seq").getD 1
  let ackedSeq := (jv.fieldUInt64? "acked_seq").getD (if syncPend then 0 else syncSeq)
  let syncText := (jv.fieldStr? "sync_text").getD ""
  let obsAt := (jv.fieldUInt64? "observed_at").getD 0
  let confCode := jv.fieldStr? "conflict_code"
  let confRetry := (jv.fieldBool? "conflict_retryable").getD false
  let proj := (jv.fieldStr? "project").getD ""
  let folder := jv.fieldStr? "folder"
  let tags : Array String := match jv.fieldArr? "tags" with
    | some xs => xs.filterMap (·.asStr?)
    | none => #["placement:client"]
  let modelOv := jv.fieldStr? "model_override"
  let modelEf := jv.fieldStr? "model_effort"
  let svcTier := jv.fieldStr? "service_tier"
  let cyberAcc := jv.fieldStr? "cyber_access"
  let createdAt := (jv.fieldStr? "created_at").getD ""
  let updatedAt := (jv.fieldStr? "updated_at").getD ""
  let hist := (jv.fieldArr? "history").getD #[]
  return {
    id, runId, endpoint := ep, title, status, statusMessage, backend, workingDirectory := cwd,
    rawPrompt, deliveredPrompt := prompt, localSyncPending := syncPend, localRunActive := runAct,
    syncSeq, ackedSeq, syncText, syncError, syncLocalOnly,
    observedAt := obsAt, lastConflictCode := confCode, retryableConflict := confRetry,
    project := proj, folder, tags, modelOverride := modelOv, modelEffort := modelEf,
    serviceTier := svcTier, cyberAccess := cyberAcc, createdAt, updatedAt, history := hist
  }

structure LocaldState where
  launchToken          : String
  rpcPort              : UInt16 := 19479
  bridge               : TransportBridgeState := {}
  nextSubToken         : Nat := 1
  subscriptions        : Array SubscriptionEntry := #[]
  queuedChannelEvents  : Array (Nat × JVal) := #[]
  nextSseSubId         : Nat := 1
  sseSubscribers       : Array (Nat × Array JVal) := #[]
  bindingsLoaded       : Bool := false
  bindingsRevision     : Nat := 0
  bindingsEntries      : Array (String × JVal) := #[]
  originsLoaded        : Bool := false
  toolHub              : InteractiveToolHubState := {}
  clientLink           : ClientLinkState := {}
  localOrigins         : Array LocalOriginEntry := #[]
  softwareJobs         : Array JVal := #[]
  approvalGraceSecs    : Nat := 300
  approvalGraceUntil   : UInt64 := 0
  approvalKeyPath      : String := ""
  orbStateDir          : String := ""
  homeDir              : String := ""
  machineId            : String := ""
  grantedFolders       : Array String := #[]
  grantedUploadFiles   : Array String := #[]
  offeredUploadBatches : Array (String × Array String × Array (String × String)) := #[]
  grantedUploadBatches : Array (String × Array String) := #[]
  grantedBrowseRoots   : Array String := #[]
  cachedMemTotal       : Nat := 0
  cachedLogicalCpu     : Nat := 0
  prevCpuTotal         : Nat := 0
  prevCpuIdle          : Nat := 0
  lastMetricsMonoMs    : Nat := 0
  lastMetricsDetails   : Bool := false
  lastMetricsSnap      : JVal := .null
  metricsHistory       : Array (Nat × JVal) := #[]
  connectionJson       : JVal := .null
  hostOs               : String := "linux"
  signerBin?           : Option String := none
  originHealth         : Array OriginHealthEntry := #[]
  h2Pool?              : Option OrbNetLeaf.H2Pool.H2ClientPool := none
  warmMgr?             : Option OrbBin.ClaudeControl.WarmHarnessManager := none
  runGenerations       : Array (String × UInt64) := #[]
  syncingOriginIds     : Array String := #[]
  unsupportedOriginSyncEndpoints : Array String := #[]
  nativeChrome         : OrbLocald.NativeChrome.NativeChromeHub := {}
  deriving Inhabited

/-- Record an upstream RTT sample (`orb_rtt_ewma_step`) and clear cooldown on `origin`, returning updated `srttMs`. -/
def recordOriginSuccess (stRef : IO.Ref LocaldState) (origin : String) (sampleMs : UInt32) : IO UInt32 := do
  stRef.modifyGet fun s =>
    let cur := (s.originHealth.find? (fun h => h.origin == origin)).getD { origin := origin }
    let packed := Orb.Kernel.rttEwmaStep cur.srttMs cur.rttVarMs sampleMs
    let nextSrtt : UInt32 := (packed &&& 0xFFFFFFFF).toUInt32
    let nextVar : UInt32 := ((packed >>> 32) &&& 0xFFFFFFFF).toUInt32
    let updated : OriginHealthEntry := {
      origin := origin
      srttMs := nextSrtt
      rttVarMs := nextVar
      consecutiveFailures := 0
      cooldownUntilMs := 0
    }
    let others := s.originHealth.filter (fun h => h.origin != origin)
    (nextSrtt, { s with originHealth := others.push updated })

/-- Record an upstream transport or 5xx/429 failure on `origin`, placing it into a 20s failover cooldown. -/
def recordOriginFailure (stRef : IO.Ref LocaldState) (origin : String) (nowMs : Nat) (cooldownMs : Nat := 20000) : IO Unit := do
  stRef.modify fun s =>
    let cur := (s.originHealth.find? (fun h => h.origin == origin)).getD { origin := origin }
    let updated : OriginHealthEntry := {
      cur with
      consecutiveFailures := cur.consecutiveFailures + 1
      cooldownUntilMs := nowMs + cooldownMs
    }
    let others := s.originHealth.filter (fun h => h.origin != origin)
    { s with originHealth := others.push updated }

/-- Check whether `orb-locald` may safely exit after its parent shell process (`ORB_PARENT_PID`) exits.
    Returns `false` while any local-origin run is still active or unsynchronized, or while any
    interactive tool slot is awaiting an answer, so background local work is never cut short. -/
def LocaldState.canExitOnOrphanParent (st : LocaldState) : Bool :=
  !st.localOrigins.any (fun e => e.localRunActive || e.localSyncPending) &&
  !st.toolHub.runs.any (fun r => r.activeCount > 0)

/-- Decide whether an orphaned `orb-locald` should shut down after `ORB_PARENT_PID` is no longer alive. -/
def shouldExitForDeadParent (parentPid? : Option Int64) (stRef : IO.Ref LocaldState) : IO Bool := do
  match parentPid? with
  | none => return false
  | some ppid =>
    if ppid ≤ 1 then return false
    -- `kill(ppid, 0)` returns `0` when alive or `EPERM` (`1`) if alive under different credentials; `ESRCH` (`3`) means gone.
    let rc ← OrbBin.PosixExt.killSig ppid 0
    if rc == 0 || rc == 1 then
      return false
    let st ← stRef.get
    return st.canExitOnOrphanParent

def LocaldState.bindingsSnapshotJson (st : LocaldState) : JVal :=
  .obj #[("revision", JVal.nat st.bindingsRevision), ("bindings", .obj st.bindingsEntries)]

def LocaldState.activeInteractionJson (st : LocaldState) (runId : String) : JVal :=
  let clean := runId.trimAscii.toString
  if clean.isEmpty then .null
  else
    match (st.toolHub.findRun? clean).bind RunToolSlotTable.firstActiveSlot? with
    | some slot => slot.toClientRequestJson
    | none      => .null

def LocaldState.enqueueTokenEvent (st : LocaldState) (tok : Nat) (payload : JVal) : LocaldState :=
  let evObj : JVal := .obj #[("token", JVal.nat tok), ("payload", payload)]
  let nextSse := st.sseSubscribers.map fun (sid, q) => (sid, q.push evObj)
  { st with
      queuedChannelEvents := st.queuedChannelEvents.push (tok, payload)
      sseSubscribers := nextSse }

def LocaldState.enqueueNamedEvent (st : LocaldState) (eventName : String) (payload : JVal) : LocaldState :=
  let evObj : JVal := .obj #[("event", .str eventName), ("payload", payload)]
  let nextSse := st.sseSubscribers.map fun (sid, q) => (sid, q.push evObj)
  { st with sseSubscribers := nextSse }

def LocaldState.publishChannelEvent (st : LocaldState) (channel : String) (payload : JVal) (target? : Option String := none) : LocaldState :=
  let matching := st.subscriptions.filter fun e =>
    e.active && e.channel == channel &&
    (match target?, e.target? with
     | some reqT, some subT => reqT == subT
     | _, _ => true)
  matching.foldl (fun acc e => acc.enqueueTokenEvent e.token payload) st

def LocaldState.publishInteractionSnapshot (st : LocaldState) (runId : String) : LocaldState :=
  let clean := runId.trimAscii.toString
  let snap := st.activeInteractionJson clean
  (st.subscriptions.filter fun e =>
      e.active && e.channel == "local_interaction" &&
      (match e.target? with | none => true | some t => t == clean)).foldl
    (fun acc e => acc.enqueueTokenEvent e.token snap) st

def ensureWarmManager (stRef : IO.Ref LocaldState) : IO OrbBin.ClaudeControl.WarmHarnessManager := do
  let cur ← stRef.get
  match cur.warmMgr? with
  | some m => return m
  | none =>
    let fresh ← OrbBin.ClaudeControl.newWarmHarnessManager
    stRef.modifyGet fun s =>
      match s.warmMgr? with
      | some existing => (existing, s)
      | none => (fresh, { s with warmMgr? := some fresh })

def LocaldState.subscribe (st : LocaldState) (channel : String) (initialEvent? : Option JVal := none)
    (target? : Option String := none) : (Nat × LocaldState) :=
  let tok := st.nextSubToken
  let entry : SubscriptionEntry := { token := tok, channel := channel, target? := target?, active := true }
  let st1 := { st with nextSubToken := tok + 1, subscriptions := st.subscriptions.push entry }
  let st2 := match initialEvent? with
    | some ev => st1.enqueueTokenEvent tok ev
    | none    => st1
  (tok, st2)

def LocaldState.unsubscribe (st : LocaldState) (tok : Nat) : LocaldState :=
  { st with
      subscriptions := st.subscriptions.filter (fun e => e.token != tok && e.active),
      queuedChannelEvents := st.queuedChannelEvents.filter (fun (t, _) => t != tok) }

def LocaldState.clearAllSubscriptions (st : LocaldState) : LocaldState :=
  { st with subscriptions := #[], queuedChannelEvents := #[] }

def LocaldState.registerSseSubscriber (st : LocaldState) : (Nat × LocaldState) :=
  let sid := st.nextSseSubId
  (sid, { st with nextSseSubId := sid + 1, sseSubscribers := st.sseSubscribers.push (sid, #[]) })

def LocaldState.unregisterSseSubscriber (st : LocaldState) (sid : Nat) : LocaldState :=
  { st with sseSubscribers := st.sseSubscribers.filter (fun (id, _) => id != sid) }

def LocaldState.drainSseSubscriber (st : LocaldState) (sid : Nat) : (Array JVal × LocaldState) :=
  match st.sseSubscribers.find? (fun (id, _) => id == sid) with
  | none => (#[], st)
  | some (_, q) =>
    if q.isEmpty then (#[], st)
    else
      let nextSubs := st.sseSubscribers.map fun (id, cur) => if id == sid then (id, #[]) else (id, cur)
      (q, { st with sseSubscribers := nextSubs })

/-- Validate loopback host + ≥32-byte non-placeholder per-launch bearer token via `verifyLocaldRpcAuth`. -/
def checkRpcAuth (remoteHost : String) (providedToken : String) (expectedToken : String) : Bool :=
  let isLoop : UInt8 :=
    if remoteHost == "127.0.0.1" || remoteHost == "localhost" || remoteHost == "::1" then 1 else 0
  let isPlaceholder : Bool :=
    expectedToken == "orb-locald-default-token" || expectedToken == "dev-token" || expectedToken == "default"
  let tokLen : UInt32 :=
    if isPlaceholder then 0 else UInt32.ofNat (min expectedToken.utf8ByteSize 65535)
  let tokOk : UInt8 := if !isPlaceholder && LeanSys.Auth.ctEqString providedToken expectedToken then 1 else 0
  verifyLocaldRpcAuth isLoop tokOk tokLen == 1

/-- Check whether an HTTP `Origin` header is an allowed local desktop shell origin (never wildcard `*`),
    rejecting CR/LF/NUL control characters so header reflection is impossible. -/
def isAllowedLocaldOrigin (origin? : Option String) : Bool :=
  match origin? with
  | none => true
  | some raw =>
    if raw.toList.any (fun c => c == '\r' || c == '\n' || c.toNat == 0) then false
    else
      let o := raw.trimAscii.toString
      o.isEmpty || o == "null" || o == "file://" || o == "orb://localhost" || o == "tauri://localhost" ||
      o.startsWith "http://127.0.0.1:" || o.startsWith "http://localhost:" ||
      o == "http://127.0.0.1" || o == "http://localhost"

/-- Canonical list of all desktop IPC commands (`plugin:app|version` + native RPCs). -/
def supportedDesktopCommands : Array String := #[
  "plugin:app|version",
  "desktop_bootstrap",
  "transport_bridge_configure",
  "desktop_connection_load", "desktop_connection_save",
  "desktop_prefs_load", "desktop_prefs_patch",
  "ui_cache_get", "ui_cache_put", "ui_cache_clear",
  "native_chrome_sync_state", "native_chrome_get_rows", "native_chrome_toggle_expand",
  "native_chrome_move_admit", "native_chrome_palette_query",
  "diagnostics_append",
  "reveal_logs", "local_machine_metrics", "paloma_ssh_pubkey",
  "open_url", "reveal_download", "save_file_as", "set_window_theme", "mistral_usage_sign_in",
  "approval_key_status", "approval_key_create", "approval_sign",
  "approval_grace_until", "set_approval_grace", "biometric_status", "biometric_authenticate",
  "client_link_active", "client_link_flush", "client_link_connect",
  "client_link_set_capabilities", "client_link_start_result",
  "local_binding_set", "local_bindings_refresh", "local_bindings_subscribe", "local_bindings_unsubscribe",
  "local_origin_launch", "local_origin_list", "local_origin_confirm", "local_origin_disconnect",
  "local_run_launch", "local_run_reconcile",
  "local_interaction", "local_interaction_subscribe", "local_interaction_unsubscribe", "local_interaction_answer",
  "local_agents_cyber_capabilities", "local_codex_speed_options", "local_agents_scan",
  "local_antigravity_models", "local_claude_models", "local_opencode_models", "local_agents_workspace", "local_agents_directory",
  "local_agents_write", "local_agents_poll", "local_agents_subscribe", "local_agents_unsubscribe", "local_agents_stop",
  "local_wakeups_sync", "local_wakeups_cancel", "local_wakeups_discard",
  "local_session_git", "local_machine_transfer", "local_machine_identity",
  "pick_upload_files", "pick_upload_folder", "grant_upload_folder", "revoke_upload_folder",
  "pick_working_directory", "read_upload_file", "read_upload_file_chunk", "stat_upload_file",
  "stage_upload_file", "stage_upload_file_from_path", "browse_local_files",
  "project_context_file", "project_context_prepare", "project_skills_prepare",
  "project_context_status", "project_context_subscribe", "project_context_unsubscribe",
  "project_context_sync", "project_context_disconnect", "project_context_workers", "project_context_stop",
  "software_inventory", "software_update", "software_cancel",
  "local_skills_status", "local_skills_sync", "local_skill_source_files", "local_invocable_skills",
  "voice_capability", "voice_prewarm", "voice_transcribe", "voice_cancel",
  "local_checkpoints_list", "local_checkpoint_diff", "local_checkpoint_restore",
  "local_worktree_status", "local_worktree_create", "local_worktree_remove",
  "local_permission_mode_set"
]

structure InvocableSkill where
  name        : String
  description : Option String
  path        : String
  deriving Repr, DecidableEq

/-- `(globalRel, projectRel)` matching desktop `HARNESS_TARGETS`. -/
def harnessSkillTargets (harness : String) : Option (String × String) :=
  match harness with
  | "claudecode"  => some (".claude/skills", ".claude/skills")
  | "codex"       => some (".codex/skills", ".agents/skills")
  | "antigravity" => some (".gemini/config/skills", ".agents/skills")
  | "opencode"    => some (".config/opencode/skills", ".opencode/skills")
  | "grok"        => some (".grok/skills", ".grok/skills")
  | "vibe"        => some (".vibe/skills", ".vibe/skills")
  | _             => none

def validSkillIdentifier (name : String) : Bool :=
  !name.isEmpty && name.length ≤ 64 && (name.splitOn "..").length == 1 &&
    name.toList.all fun c =>
      ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9') || c == '.' || c == '_' || c == '-'

private def extractSkillDescription (content : String) : Option String := Id.run do
  let text := content.replace "\r\n" "\n"
  if text.startsWith "---\n" then
    let rest := (text.drop 4).toString
    let lines := rest.splitOn "\n"
    let mut inFm := true
    let mut desc? : Option String := none
    let mut body : Array String := #[]
    for line in lines do
      if inFm then
        if line == "---" then inFm := false
        else if line.startsWith "description:" then
          let raw := ((line.drop 12).toString).trimAscii.toString
          let v := if raw.startsWith "\"" && raw.endsWith "\"" && raw.length ≥ 2 then ((raw.drop 1).dropEnd 1).toString else raw
          if !v.isEmpty then desc? := some v
      else
        body := body.push line
    if let some d := desc? then return some d
    let p := (((String.intercalate "\n" body.toList).trimAscii.toString.splitOn "\n\n").head?.getD "").trimAscii.toString
    if p.isEmpty then return none
    return some (if p.length > 220 then (p.take 220).toString else p)
  else
    let p := text.trimAscii.toString
    if p.isEmpty then return none
    let paragraph := (p.splitOn "\n\n").head?.getD p
    return some (if paragraph.length > 220 then (paragraph.take 220).toString else paragraph)

/-- Project skills (`cwd/<projectRel>`) win over global skills (`home/<globalRel>`), sorted by skill name. -/
def invocableSkillsIn (home cwd : System.FilePath) (harness : String) : IO (Except String (Array InvocableSkill)) := do
  let some (globalRel, projectRel) := harnessSkillTargets harness
    | return .error "Unknown skill harness"
  let mut found : Array InvocableSkill := #[]
  for root in #[cwd / projectRel, home / globalRel] do
    let entries ← try root.readDir catch _ => pure #[]
    for entry in entries do
      let name := entry.fileName
      if validSkillIdentifier name && !(found.any (fun s => s.name == name)) then
        let md := entry.path / "SKILL.md"
        let st ← OrbBin.PosixExt.statPath md.toString
        if st.exists_ && st.isReg && !st.isSymlink then
          let raw ← try IO.FS.readFile md catch _ => pure ""
          found := found.push { name := name, description := extractSkillDescription raw, path := md.toString }
  return .ok (found.qsort (fun a b => a.name < b.name))

def selectLocalSkillsIn (home cwd : System.FilePath) (harness prompt : String) : IO (Except String (Array (String × String × UInt8))) := do
  let refs := (prompt.split (fun c => c == ' ' || c == '\t' || c == '\n' || c == '\r')).toArray.filterMap fun w =>
    if w.startsWith "/skill:" then some (w.drop 7).toString else none
  if refs.isEmpty then return .ok #[]
  let skills ← match ← invocableSkillsIn home cwd harness with
    | .ok xs => pure xs
    | .error e => return .error e
  let hKind : UInt8 := if harness == "opencode" then 1 else if harness == "claudecode" then 2 else 0
  let mut selected : Array (String × String × UInt8) := #[]
  for name in refs do
    if selected.any (fun (n, _, _) => n == name) then
      continue
    let skill? := skills.find? (fun s => s.name == name)
    let verdict := Orb.Kernel.skillSlashStep
      hKind
      (if skill?.isSome then 1 else 0)
      0
      (if validSkillIdentifier name then 1 else 0)
      (if name.utf8ByteSize > 0xFFFFFFFF then 0xFFFFFFFF else name.utf8ByteSize.toUInt32)
      64
      selected.size.toUInt32
      8
    let lo := verdict.toUInt32
    if (lo &&& 255) != 0 then
      let code := lo &&& 255
      let msg :=
        if code == 1 || code == 2 then "Invalid /skill: identifier (use at most 64 ASCII letters, numbers, '.', '_' or '-', without '..')"
        else if code == 3 then s!"Selected skill is not delivered to this mission: {name}"
        else if code == 5 then "Select at most 8 distinct skills"
        else "Skill selection rejected"
      return .error msg
    let some sk := skill? | return .error "Selected skill is unavailable"
    selected := selected.push (name, sk.path, ((lo >>> 16) &&& 255).toUInt8)
  return .ok selected

def withLocalSkillDirective (prompt : String) (selected : Array (String × String × UInt8)) : String :=
  if selected.isEmpty then prompt
  else Id.run do
    let mut result := prompt ++ "\n\nSelected skills (load before performing the current request):\n"
    for (rawName, rawPath, strategy) in selected do
      let name := renderCompact (.str rawName)
      let path := renderCompact (.str rawPath)
      if strategy == 1 then
        result := result ++ s!"- Invoke the Skill tool with name {name}. If unavailable, read {path} and follow its instructions.\n"
      else
        result := result ++ s!"- Read {path} and follow the instructions for skill {name}.\n"
    return result

def validateLocalCodexLaunch (prompt model cyberMode : String) (hasImages : Bool) : Except String Unit := do
  let bare := (model.splitOn "/").getLast?.getD model
  let hasRetired := bare == "gpt-daybreak-blue-latest" || bare == "gpt-daybreak-red-latest"
  let mode := cyberMode.trimAscii.toString.toLower
  let explicitCyber := !mode.isEmpty && mode != "automatic"
  let modelCompat :=
    if mode == "standard" then !(bare.startsWith "gpt-daybreak-" || bare == "gpt-5.6-cyber")
    else if mode == "daybreak" then
      bare == "gpt-6-sol" || bare == "gpt-6.1-sol" || bare == "gpt-6-astra" || bare == "gpt-5.6-sol" || bare == "gpt-5.6-cyber"
    else mode.isEmpty || mode == "automatic"
  let t := prompt.trimAscii.toString
  let goalObj? : Option String :=
    if t == "/goal" then some ""
    else if t.startsWith "/goal" then
      let rest := (t.drop 5).toString
      match rest.toList.head? with
      | some c => if c == ' ' || c == '\t' || c == '\n' || c == '\r' then some rest.trimAscii.toString else none
      | none => some ""
    else none
  let verdict := Orb.Kernel.codexGoalLaunchStep
    (if goalObj?.isSome then 1 else 0)
    (if (goalObj?.map (fun o => !o.isEmpty)).getD false then 1 else 0)
    (if hasImages then 1 else 0)
    (if explicitCyber then 1 else 0)
    1
    (if modelCompat then 1 else 0)
    1
    0
    (if hasRetired then 1 else 0)
  if verdict == 1 then throw "invalid_access_program: the selected model alias is retired."
  if verdict == 2 then throw "invalid_access_program: explicit cyber selection is incompatible with this model."
  if verdict == 5 then throw "unsupported_access_program: native goal continuations cannot confirm a per-turn cyber selection. Choose Automatic explicitly for this goal."
  if verdict == 6 then throw "/goal requires a non-empty objective."
  if verdict == 7 then throw "Goal launches with images are not supported yet; include file paths in the objective."
  if explicitCyber && bare.isEmpty then
    throw "unsupported_access_program: choose an explicit model before selecting a Cyber program. No thread was started."

private def resolveApprovalKeyPath (st : LocaldState) : String :=
  if st.approvalKeyPath.trimAscii.toString.isEmpty then "approval-key.bin" else st.approvalKeyPath

private def resolveApprovalKeyArgs (st : LocaldState) (verb : String) : Array String :=
  #[verb, "--key", resolveApprovalKeyPath st]

private def runOrbSigner (signerBin : String) (subArgs : Array String) (stdinText? : Option String := none) :
    IO (Except (UInt32 × String) JVal) := do
  if !(← System.FilePath.pathExists signerBin) then
    return .error (127, "orb-signer binary not found")
  match stdinText? with
  | none =>
    let child ← IO.Process.spawn {
      cmd := signerBin
      args := subArgs
      stdin := .null
      stdout := .piped
      stderr := .piped
    }
    let outTask ← IO.asTask child.stdout.readToEnd Task.Priority.dedicated
    let errStr ← child.stderr.readToEnd
    let code ← child.wait
    let outStr ← IO.ofExcept outTask.get
    if code != 0 then
      let msg := if errStr.trimAscii.toString.isEmpty then s!"orb-signer exited {code}" else errStr.trimAscii.toString
      return .error (code, msg)
    match OrbBin.Json.parse outStr.trimAscii.toString with
    | .ok jv => return .ok jv
    | .error e => return .error (1, s!"orb-signer JSON parse error: {e}")
  | some txt =>
    let child ← IO.Process.spawn {
      cmd := signerBin
      args := subArgs
      stdin := .piped
      stdout := .piped
      stderr := .piped
    }
    let child' ← do
      let (stdinH, c') ← child.takeStdin
      stdinH.putStr txt
      stdinH.flush
      pure c'
    let outTask ← IO.asTask child'.stdout.readToEnd Task.Priority.dedicated
    let errStr ← child'.stderr.readToEnd
    let code ← child'.wait
    let outStr ← IO.ofExcept outTask.get
    if code != 0 then
      let msg := if errStr.trimAscii.toString.isEmpty then s!"orb-signer exited {code}" else errStr.trimAscii.toString
      return .error (code, msg)
    match OrbBin.Json.parse outStr.trimAscii.toString with
    | .ok jv => return .ok jv
    | .error e => return .error (1, s!"orb-signer JSON parse error: {e}")

private structure SignerServerProc where
  signerBin : String
  keyPath   : String
  graceSecs : Nat
  stdinH    : IO.FS.Handle
  child     : IO.Process.Child { stdin := .null, stdout := .piped, stderr := .null }

initialize signerServerMutex : Std.Mutex (Option SignerServerProc) ← Std.Mutex.new none

private def stopSignerServerProc (srv? : Option SignerServerProc) : IO Unit := do
  if let some srv := srv? then
    try srv.child.kill catch _ => pure ()
    try discard <| srv.child.wait catch _ => pure ()

private def resetSignerServer : IO Unit := do
  signerServerMutex.atomically do
    let prev ← get
    set (none : Option SignerServerProc)
    stopSignerServerProc prev

private def spawnSignerServerProc (signerBin keyPath : String) (graceSecs : Nat) : IO SignerServerProc := do
  let rawChild ← IO.Process.spawn {
    cmd := signerBin
    args := #["serve", "--key", keyPath, "--grace", s!"{graceSecs}"]
    stdin := .piped
    stdout := .piped
    stderr := .null
  }
  let (stdinH, child) ← rawChild.takeStdin
  return { signerBin, keyPath, graceSecs, stdinH, child }

private def signViaOrbSignerServer (signerBin keyPath : String) (graceSecs : Nat) (payload : String) :
    IO (Except (UInt32 × String) JVal) := do
  if !(← System.FilePath.pathExists signerBin) then
    return .error (127, "orb-signer binary not found")
  let reqLine := OrbBin.PosixExt.base64Encode payload.toUTF8 false true ++ "\n"
  signerServerMutex.atomically do
    let tryOnce (srv : SignerServerProc) : IO (Option JVal) := do
      try
        srv.stdinH.putStr reqLine
        srv.stdinH.flush
        let line ← srv.child.stdout.getLine
        let trimmed := line.trimAscii.toString
        if trimmed.isEmpty then
          return none
        match OrbBin.Json.parse trimmed with
        | .ok jv => return some jv
        | .error _ => return none
      catch _ =>
        return none
    let mut cur ← get
    if let some existing := cur then
      if existing.signerBin != signerBin || existing.keyPath != keyPath || existing.graceSecs != graceSecs then
        stopSignerServerProc (some existing)
        cur := none
      else if (← try existing.child.tryWait catch _ => pure (some 1)).isSome then
        stopSignerServerProc (some existing)
        cur := none
    let srv ← match cur with
      | some s => pure s
      | none =>
        try
          let fresh ← spawnSignerServerProc signerBin keyPath graceSecs
          set (some fresh)
          pure fresh
        catch e =>
          set (none : Option SignerServerProc)
          return .error (1, s!"Could not start orb-signer: {e}")
    let reply? ← match ← tryOnce srv with
      | some jv => pure (some jv)
      | none =>
        stopSignerServerProc (some srv)
        set (none : Option SignerServerProc)
        try
          let fresh ← spawnSignerServerProc signerBin keyPath graceSecs
          set (some fresh)
          tryOnce fresh
        catch _ =>
          set (none : Option SignerServerProc)
          pure none
    match reply? with
    | none =>
      let curAfter ← get
      stopSignerServerProc curAfter
      set (none : Option SignerServerProc)
      return .error (1, "orb-signer closed unexpectedly")
    | some jv =>
      if let some errMsg := jv.fieldStr? "error" then
        let codeNat := (jv.fieldStr? "code").bind String.toNat? |>.getD 1
        return .error (codeNat.toUInt32, errMsg)
      return .ok jv

private def allShardPortsValid (rpcPort proxyPort : UInt16) (shardPorts : Array UInt16) : Bool :=
  shardPorts.all (fun p => p ≥ 1024 && p != rpcPort && p != proxyPort) &&
  (shardPorts.toList.eraseDups.length == shardPorts.size)

/-- Convert Unix epoch seconds to `YYYY-MM-DD` (UTC Howard Hinnant civil-from-days algorithm). -/
def formatUtcYmd (epochSecs : UInt64) : String :=
  let z : Int := Int.ofNat (epochSecs.toNat / 86400) + 719468
  let era : Int := (if z ≥ 0 then z else z - 146096) / 146097
  let doe : Nat := (z - era * 146097).toNat
  let yoe : Nat := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y : Int := Int.ofNat yoe + era * 400
  let doy : Nat := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp : Nat := (5 * doy + 2) / 153
  let d : Nat := doy - (153 * mp + 2) / 5 + 1
  let m : Nat := if mp < 10 then mp + 3 else mp - 9
  let yr : Int := if m ≤ 2 then y + 1 else y
  let pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else s!"{n}"
  s!"{yr}-{pad2 m}-{pad2 d}"

/-- Convert Unix epoch seconds to `YYYY-MM-DDTHH:MM:SSZ` (UTC). -/
def formatUtcIso8601 (epochSecs : UInt64) : String :=
  let ymd := formatUtcYmd epochSecs
  let dayRem := epochSecs.toNat % 86400
  let hh := dayRem / 3600
  let mm := (dayRem % 3600) / 60
  let ss := dayRem % 60
  let pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else s!"{n}"
  s!"{ymd}T{pad2 hh}:{pad2 mm}:{pad2 ss}Z"

private def resolveOrbStateDir (st : LocaldState) : Option System.FilePath :=
  let raw := st.orbStateDir.trimAscii.toString
  if raw.isEmpty then none else some (System.FilePath.mk raw)

private def connectionFilePath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "connection.json")

private def bindingsFilePath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "local-bindings.json")

private def originsFilePath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "local-origins.json")

private def uiPrefsFilePath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "ui-prefs.json")

private def uiCacheDirPath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "ui-cache")

private def uiCacheSqlitePath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "ui-cache.sqlite3")

private def uiDraftsSqlitePath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "ui-drafts.sqlite3")

initialize uiPrefsMutex : Std.Mutex Unit ← Std.Mutex.new ()
initialize uiCacheMutex : Std.Mutex Unit ← Std.Mutex.new ()
initialize uiDraftsMutex : Std.Mutex Unit ← Std.Mutex.new ()
initialize uiCacheDbPoolRef : IO.Ref (Array (String × OrbBin.Sqlite.SqliteDb)) ← IO.mkRef #[]
initialize uiDraftsDbPoolRef : IO.Ref (Array (String × OrbBin.Sqlite.SqliteDb)) ← IO.mkRef #[]

private def maxUiCacheRawBytes : Nat := 8388608
private def hotUiCacheTranscripts : Nat := 32
private def maxUiCacheTranscripts : Nat := 250
private def maxUiDraftRawBytes : Nat := 16777216
private def maxUiDraftEntries : Nat := 512

private def uiCacheSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS ui_sidebar (scope_key TEXT PRIMARY KEY, saved_at INTEGER NOT NULL, payload_json TEXT NOT NULL);" ++
  "CREATE TABLE IF NOT EXISTS ui_transcript_raw (record_key TEXT PRIMARY KEY, saved_at INTEGER NOT NULL, tier TEXT NOT NULL DEFAULT 'hot', payload_json TEXT NOT NULL);" ++
  "CREATE INDEX IF NOT EXISTS idx_ui_transcript_raw_saved_at ON ui_transcript_raw(saved_at);" ++
  "CREATE TABLE IF NOT EXISTS ui_transcript_meta (record_key TEXT PRIMARY KEY, scope_key TEXT NOT NULL, mission_id TEXT NOT NULL, saved_at INTEGER NOT NULL, total_events INTEGER NOT NULL, head_json TEXT NOT NULL);" ++
  "CREATE INDEX IF NOT EXISTS idx_ui_transcript_meta_saved_at ON ui_transcript_meta(saved_at);" ++
  "CREATE TABLE IF NOT EXISTS ui_transcript_events (record_key TEXT NOT NULL, idx INTEGER NOT NULL, event_json TEXT NOT NULL, PRIMARY KEY(record_key, idx));"

private def uiDraftsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS ui_drafts (scope_key TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, value_json TEXT NOT NULL);" ++
  "CREATE INDEX IF NOT EXISTS idx_ui_drafts_updated_at ON ui_drafts(updated_at);"

private def ensurePrivateSqliteHandle
    (poolRef : IO.Ref (Array (String × OrbBin.Sqlite.SqliteDb)))
    (stateDir dbPath : System.FilePath)
    (ddl : String) : IO (Except String OrbBin.Sqlite.SqliteDb) := do
  try
    IO.FS.createDirAll stateDir
    discard <| OrbBin.PosixExt.chmod stateDir.toString 0o700
  catch _ => pure ()
  let dirSt ← OrbBin.PosixExt.statPath stateDir.toString
  if dirSt.isSymlink then
    return .error "State directory must not be a symlink"
  let dbPathStr := dbPath.toString
  let fileSt ← OrbBin.PosixExt.statPath dbPathStr
  if fileSt.exists_ && (fileSt.isSymlink || !fileSt.isReg) then
    return .error "SQLite database path must be a regular non-symlink file"
  for suf in #["-wal", "-shm"] do
    let sideSt ← OrbBin.PosixExt.statPath (dbPathStr ++ suf)
    if sideSt.exists_ && sideSt.isSymlink then
      return .error "SQLite WAL/SHM sidecar must not be a symlink"
  let pool ← poolRef.get
  if let some (_, db) := pool.find? (fun (p, _) => p == dbPathStr) then
    if fileSt.exists_ then
      return .ok db
    OrbBin.Sqlite.sqliteCloseRaw db.handle
    poolRef.modify (fun xs => xs.filter (fun (p, _) => p != dbPathStr))
  match ← OrbBin.Sqlite.openSqliteDb dbPathStr ddl with
  | .error e => return .error e
  | .ok db =>
    let _ ← OrbBin.Sqlite.sqliteExecRaw db.handle
      "ALTER TABLE ui_transcript_raw ADD COLUMN tier TEXT NOT NULL DEFAULT 'hot';"
    discard <| OrbBin.PosixExt.chmod dbPathStr 0o600
    for suf in #["-wal", "-shm"] do
      let side := dbPathStr ++ suf
      if (← System.FilePath.pathExists side) then
        discard <| OrbBin.PosixExt.chmod side 0o600
    poolRef.modify fun xs =>
      let trimmed := if xs.size ≥ 8 then xs.extract 1 xs.size else xs
      trimmed.push (dbPathStr, db)
    return .ok db

private def reconcileSqliteTranscripts (h : UInt64) : IO (Array String) := do
  let _ ← OrbBin.Sqlite.sqliteQueryRowsRaw h
    "DELETE FROM ui_transcript_raw WHERE record_key NOT IN (SELECT record_key FROM ui_transcript_raw ORDER BY saved_at DESC, record_key DESC LIMIT ?1);"
    #[s!"{maxUiCacheTranscripts}"]
  let _ ← OrbBin.Sqlite.sqliteQueryRowsRaw h
    "DELETE FROM ui_transcript_meta WHERE record_key NOT IN (SELECT record_key FROM ui_transcript_meta ORDER BY saved_at DESC, record_key DESC LIMIT ?1);"
    #[s!"{maxUiCacheTranscripts}"]
  let _ ← OrbBin.Sqlite.sqliteExecRaw h
    "DELETE FROM ui_transcript_events WHERE record_key NOT IN (SELECT record_key FROM ui_transcript_meta);"
  match ← OrbBin.Sqlite.sqliteQueryRowsRaw h
      "SELECT record_key FROM ui_transcript_raw WHERE tier = 'hot' AND record_key NOT IN (SELECT record_key FROM ui_transcript_raw ORDER BY saved_at DESC, record_key DESC LIMIT ?1) ORDER BY saved_at ASC;"
      #[s!"{hotUiCacheTranscripts}"] with
  | .ok rows =>
    let mut keys : Array String := #[]
    for idx in [1:rows.size] do
      if rows[idx]!.size ≥ 1 then
        keys := keys.push rows[idx]![0]!
    return keys
  | .error _ => return #[]

private def evictExcessSqliteDrafts (h : UInt64) : IO Unit := do
  -- Never evict `thread:*` records (durable local message queues, receipts, tombstones,
  -- wake-stop fences, approved plans, and side-question transcripts); only bound
  -- disposable composer draft scopes (`scope_key NOT LIKE 'thread:%'`).
  let _ ← OrbBin.Sqlite.sqliteQueryRowsRaw h
    "DELETE FROM ui_drafts WHERE scope_key NOT LIKE 'thread:%' AND scope_key NOT IN (SELECT scope_key FROM ui_drafts WHERE scope_key NOT LIKE 'thread:%' ORDER BY updated_at DESC, scope_key DESC LIMIT ?1);"
    #[s!"{maxUiDraftEntries}"]

private def isValidUiCacheKind (k : String) : Bool :=
  k == "sidebar" || k == "transcript"

/-- Resolve the active or requested `ChromeScopeState`, hydrating from `~/.orb/ui-cache.sqlite3`
    (`ui_sidebar`) when in-memory `nativeChrome` does not yet hold `requestedScope`. -/
private def resolveNativeChromeScope (stRef : IO.Ref LocaldState) (requestedScope : String) :
    IO OrbLocald.NativeChrome.ChromeScopeState := do
  let req := requestedScope.trimAscii.toString
  let st ← stRef.get
  let target := if req.isEmpty then st.nativeChrome.activeScope else req
  if !target.isEmpty then
    if let some existing := st.nativeChrome.scopes.find? (·.scope == target) then
      return existing
  let hydrated? : Option OrbLocald.NativeChrome.ChromeScopeState ← do
    match resolveOrbStateDir st, uiCacheSqlitePath? st with
    | some stateDir, some dbPath =>
      uiCacheMutex.atomically do
        match ← ensurePrivateSqliteHandle uiCacheDbPoolRef stateDir dbPath uiCacheSchemaSql with
        | .error _ => pure none
        | .ok db =>
          let queryRes ←
            if !target.isEmpty then
              OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "SELECT scope_key, payload_json FROM ui_sidebar WHERE scope_key = ?1;" #[target]
            else
              OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "SELECT scope_key, payload_json FROM ui_sidebar ORDER BY saved_at DESC LIMIT 1;" #[]
          match queryRes with
          | .ok rows =>
            if rows.size ≥ 2 && rows[1]!.size ≥ 2 then
              pure (OrbLocald.NativeChrome.parsePersistedSidebarPayload? rows[1]![0]! rows[1]![1]!)
            else
              pure none
          | .error _ => pure none
    | _, _ => pure none
  match hydrated? with
  | some hyd =>
    stRef.modifyGet fun s =>
      let (resolved, nextHub) := s.nativeChrome.installHydratedScope hyd
      (resolved, { s with nativeChrome := nextHub })
  | none =>
    return { scope := target }

private def uiCacheEntryPath (dir : System.FilePath) (kind key : String) : System.FilePath :=
  let digest := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes key.toUTF8)
  dir / s!"{kind}-{digest}.cache"

private def parseUiCacheFile? (raw : String) (expectedKeyHex : String) : Option (Nat × String) :=
  match raw.splitOn "\n" with
  | tsStr :: rest0 =>
    let tsParts := tsStr.trimAscii.toString.splitOn ":"
    let savedAt := (tsParts[0]?.bind (·.toNat?)).getD 0
    match rest0 with
    | keyHex :: rest =>
      if keyHex != expectedKeyHex then none
      else
        let payload := String.intercalate "\n" rest
        if payload.isEmpty then none else some (savedAt, payload)
    | _ => none
  | _ => none

private def hexNibble? (c : Char) : Option UInt8 :=
  let n := c.toNat
  if '0'.toNat ≤ n && n ≤ '9'.toNat then some (UInt8.ofNat (n - '0'.toNat))
  else if 'a'.toNat ≤ n && n ≤ 'f'.toNat then some (UInt8.ofNat (10 + n - 'a'.toNat))
  else if 'A'.toNat ≤ n && n ≤ 'F'.toNat then some (UInt8.ofNat (10 + n - 'A'.toNat))
  else none

private def decodeHexUtf8? (hex : String) : Option String := Id.run do
  let cs := hex.trimAscii.toString.toList.toArray
  if cs.size == 0 || cs.size % 2 != 0 then return none
  let mut out := ByteArray.emptyWithCapacity (cs.size / 2)
  let mut i := 0
  while i + 1 < cs.size do
    match hexNibble? cs[i]!, hexNibble? cs[i + 1]! with
    | some hi, some lo =>
      out := out.push ((hi <<< 4) ||| lo)
      i := i + 2
    | _, _ => return none
  String.fromUTF8? out

private def readUiCacheMeta (path : System.FilePath) : IO (Nat × String × String) := do
  let st ← OrbBin.PosixExt.statPath path.toString
  if !st.exists_ || st.isSymlink || !st.isReg then return (0, "warm", "")
  try
    let h ← IO.FS.Handle.mk path .read
    let line1 ← h.getLine
    let line2 ← h.getLine
    let tsParts := line1.trimAscii.toString.splitOn ":"
    let ts := (tsParts[0]?.bind (·.toNat?)).getD 0
    let tier := match tsParts[1]? with
      | some "warm" => "warm"
      | _ => "hot"
    let key := (decodeHexUtf8? line2).getD ""
    return (ts, tier, key)
  catch _ =>
    return (0, "warm", "")

/-- Evict transcripts beyond `maxUiCacheTranscripts` (`250`) and return keys of any
    persisted hot records outside the newest `hotUiCacheTranscripts` (`32`) so the
    renderer can compact and write back their warm-tier spine digests across restarts. -/
private def reconcileUiCacheTranscripts (dir : System.FilePath) : IO (Array String) := do
  let entries ← try dir.readDir catch _ => pure #[]
  let txEntries := entries.filter fun e =>
    e.fileName.startsWith "transcript-" && e.fileName.endsWith ".cache"
  if txEntries.size ≤ hotUiCacheTranscripts then return #[]
  let mut stamped : Array (Nat × String × String × System.FilePath) := Array.mkEmpty txEntries.size
  for e in txEntries do
    let (ts, tier, key) ← readUiCacheMeta e.path
    stamped := stamped.push (ts, tier, key, e.path)
  let sorted := stamped.qsort (fun a b => a.1 < b.1)
  let dropCount := if sorted.size > maxUiCacheTranscripts then sorted.size - maxUiCacheTranscripts else 0
  for i in [0:dropCount] do
    if h : i < sorted.size then
      try IO.FS.removeFile sorted[i].2.2.2 catch _ => pure ()
  let warmEnd := if sorted.size > hotUiCacheTranscripts then sorted.size - hotUiCacheTranscripts else 0
  let mut demoteKeys : Array String := #[]
  for i in [dropCount:warmEnd] do
    if h : i < sorted.size then
      let (_, tier, key, _) := sorted[i]
      if tier == "hot" && !key.isEmpty then
        demoteKeys := demoteKeys.push key
  return demoteKeys

private def isAllowedUiPrefKey (k : String) : Bool :=
  !k.isEmpty && k.utf8ByteSize ≤ 512 &&
  (k == "orb-theme" || k.startsWith "orb." || k.startsWith "orb:") &&
  k != "orb.jwt" &&
  k != "orb.apiUrl" &&
  k != "orb.selectedConversation" &&
  k != "orb.recentPages" &&
  k != "orb.githubOAuthPending" &&
  k != "orb.projectedMove" &&
  k != "orb.localFailures" &&
  k != "orb.localFolderSeed" &&
  k != "orb.desktopPrefsMigrated.v1" &&
  !k.startsWith "orb.projectColorSync:" &&
  !k.startsWith "orb.catalog:" &&
  !k.startsWith "orb.software.inventory." &&
  !k.startsWith "orb.inbox." &&
  !k.startsWith "orb:inbox-digest:" &&
  !k.startsWith "orb.native.answered:" &&
  !k.startsWith "orb.turn-started:" &&
  (!k.startsWith "orb.btw:" || k.endsWith ",\"settings:btw\"]" || k.endsWith ",\"settings:inbox\"]")

private def acquireUiPrefsFlock (lockPath : String) : IO (Option Int32) := do
  for _ in [0:200] do
    let rc ← OrbBin.PosixExt.flockExclusiveNb lockPath
    if rc != 0xFFFFFFFF && rc != 0xFFFFFFFE then
      return some (Int32.ofBitVec (BitVec.ofNat 32 rc.toNat))
    if rc == 0xFFFFFFFF then
      return none
    IO.sleep 5
  return none

private def withUiPrefsLock (path? : Option System.FilePath) (act : IO (Except String JVal)) : IO (Except String JVal) :=
  uiPrefsMutex.atomically do
    match path? with
    | none => act
    | some path =>
      if let some dir := path.parent then
        try
          IO.FS.createDirAll dir
          discard <| OrbBin.PosixExt.chmod dir.toString 0o700
        catch _ => pure ()
      let lockPath := path.toString ++ ".lock"
      let lockSt ← OrbBin.PosixExt.statPath lockPath
      if lockSt.isSymlink then
        return .error "UI preferences lock must not be a symlink"
      let some lockFd ← acquireUiPrefsFlock lockPath
        | return .error "Cannot acquire UI preferences lock"
      try
        act
      finally
        OrbBin.PosixExt.closeFdRaw lockFd

private def canonicalUiPrefs (kvs : Array (String × JVal)) : JVal × String :=
  let filtered := kvs.foldl (init := (#[] : Array (String × JVal))) fun acc (k, v) =>
    match v.asStr? with
    | some s =>
      if isAllowedUiPrefKey k && s.utf8ByteSize ≤ 65536 then
        let rest := acc.filter (fun (ek, _) => ek != k)
        rest.push (k, .str s)
      else acc
    | none => acc
  let sorted := filtered.qsort (fun a b => a.1 < b.1)
  let obj := JVal.obj sorted
  let canon := renderCompact obj
  let rev := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes canon.toUTF8)
  (obj, rev)

private def readUiPrefsFromDisk (path? : Option System.FilePath) : IO (Except String (JVal × String × Bool)) := do
  match path? with
  | none =>
    let (obj, rev) := canonicalUiPrefs #[]
    return .ok (obj, rev, false)
  | some path =>
    let st ← OrbBin.PosixExt.statPath path.toString
    if !st.exists_ then
      let (obj, rev) := canonicalUiPrefs #[]
      return .ok (obj, rev, false)
    if st.isSymlink || !st.isReg then
      return .error "Invalid saved UI preferences path"
    try
      let raw ← IO.FS.readFile path
      match OrbBin.Json.parse raw.trimAscii.toString with
      | .ok (.obj kvs) =>
        let (obj, rev) := canonicalUiPrefs kvs
        return .ok (obj, rev, true)
      | _ => return .error "Invalid saved UI preferences"
    catch _ =>
      return .error "Cannot read saved UI preferences"

private def logsDirPath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "logs")

def ensurePersistedBindingsLoaded (stRef : IO.Ref LocaldState) : IO Unit := do
  let st ← stRef.get
  if st.bindingsLoaded then return ()
  match bindingsFilePath? st with
  | none =>
    stRef.modify fun s => { s with bindingsLoaded := true }
  | some path =>
    if !(← path.pathExists) then
      stRef.modify fun s => { s with bindingsLoaded := true }
    else
      try
        let raw ← IO.FS.readFile path
        match OrbBin.Json.parse raw.trimAscii.toString with
        | .ok jv =>
          let homeOv? := if st.homeDir.trimAscii.toString.isEmpty then none else some st.homeDir.trimAscii.toString
          let (defModel?, provNames, cfgModels) ← OrbBin.ClaudeControl.readLocalOpenCodeConfigInfo homeOv?
          let provIds := provNames.map Prod.fst
          let diskRev := (jv.fieldNat? "revision").getD 0
          let rawEntries : Array (String × JVal) :=
            match jv.field? "bindings" with
            | some (.obj kvs) => kvs
            | _ =>
              match jv with
              | .obj kvs => kvs.filter (fun (k, _) => k != "revision" && k != "bindings")
              | _ => #[]
          let mut repairedAny := false
          let mut diskEntries : Array (String × JVal) := Array.mkEmpty rawEntries.size
          for (k, v) in rawEntries do
            if v.fieldStr? "harness" == some "opencode" then
              if let some m := v.fieldStr? "model" then
                let resolved := (OrbBin.ClaudeControl.resolveOpenCodeModelForLocal (some m) defModel? provIds cfgModels).getD m
                if resolved != m then
                  repairedAny := true
                  diskEntries := diskEntries.push (k, JVal.setField v "model" (.str resolved))
                else
                  diskEntries := diskEntries.push (k, v)
              else
                diskEntries := diskEntries.push (k, v)
            else
              diskEntries := diskEntries.push (k, v)
          let stLoaded ← stRef.modifyGet fun s =>
            if s.bindingsLoaded then (none, s)
            else
              let merged := diskEntries.foldl (fun acc (k, v) =>
                if acc.any (fun (ek, _) => ek == k) then acc else acc.push (k, v)) s.bindingsEntries
              let baseRev := max s.bindingsRevision (max diskRev merged.size)
              let rev := if repairedAny then baseRev + 1 else baseRev
              let s' := { s with bindingsLoaded := true, bindingsRevision := rev, bindingsEntries := merged }
              (if repairedAny then some s' else none, s')
          if let some stToSave := stLoaded then
            let payload := (renderCompact stToSave.bindingsSnapshotJson ++ "\n").toUTF8
            discard <| OrbBin.PosixExt.writeAtomicPrivate0600 path payload
        | .error _ =>
          stRef.modify fun s => { s with bindingsLoaded := true }
      catch _ =>
        stRef.modify fun s => { s with bindingsLoaded := true }

private def persistBindingsSnapshot (st : LocaldState) : IO Unit := do
  if let some path := bindingsFilePath? st then
    let payload := (renderCompact st.bindingsSnapshotJson ++ "\n").toUTF8
    discard <| OrbBin.PosixExt.writeAtomicPrivate0600 path payload

def ensurePersistedOriginsLoaded (stRef : IO.Ref LocaldState) : IO Unit := do
  let st ← stRef.get
  if st.originsLoaded then return ()
  match originsFilePath? st with
  | none =>
    stRef.modify fun s => { s with originsLoaded := true }
  | some path =>
    if !(← path.pathExists) then
      stRef.modify fun s => { s with originsLoaded := true }
    else
      try
        let raw ← IO.FS.readFile path
        match OrbBin.Json.parse raw.trimAscii.toString with
        | .ok (.arr xs) =>
          let homeOv? := if st.homeDir.trimAscii.toString.isEmpty then none else some st.homeDir.trimAscii.toString
          let (defModel?, provNames, cfgModels) ← OrbBin.ClaudeControl.readLocalOpenCodeConfigInfo homeOv?
          let provIds := provNames.map Prod.fst
          let mut repairedAny := false
          let rawParsed := xs.filterMap LocalOriginEntry.fromMissionJson?
          let mut parsed : Array LocalOriginEntry := Array.mkEmpty rawParsed.size
          for row in rawParsed do
            if row.backend == "opencode" then
              match row.modelOverride with
              | some m =>
                let resolved := (OrbBin.ClaudeControl.resolveOpenCodeModelForLocal (some m) defModel? provIds cfgModels).getD m
                if resolved != m then
                  repairedAny := true
                  parsed := parsed.push { row with modelOverride := some resolved }
                else
                  parsed := parsed.push row
              | none =>
                parsed := parsed.push row
            else
              parsed := parsed.push row
          let stLoaded ← stRef.modifyGet fun s =>
            if s.originsLoaded then (none, s)
            else
              let merged := parsed.foldl (fun acc row =>
                if acc.any (fun r => r.id == row.id) then acc else acc.push row) s.localOrigins
              let s' := { s with originsLoaded := true, localOrigins := merged }
              (if repairedAny then some s' else none, s')
          if let some stToSave := stLoaded then
            let arr := stToSave.localOrigins.map LocalOriginEntry.toMissionJson
            let payload := (renderCompact (.arr arr) ++ "\n").toUTF8
            discard <| OrbBin.PosixExt.writeAtomicPrivate0600 path payload
        | _ =>
          stRef.modify fun s => { s with originsLoaded := true }
      catch _ =>
        stRef.modify fun s => { s with originsLoaded := true }

private def persistOriginsSnapshot (st : LocaldState) : IO Unit := do
  if let some path := originsFilePath? st then
    let arr := st.localOrigins.map LocalOriginEntry.toMissionJson
    let payload := (renderCompact (.arr arr) ++ "\n").toUTF8
    discard <| OrbBin.PosixExt.writeAtomicPrivate0600 path payload

private def isSafeHttpUrl (raw : String) : Bool :=
  let u := raw.trimAscii.toString
  (u.startsWith "https://" || u.startsWith "http://") &&
  !(u.toList.any (fun c => c.toNat ≤ 0x20 || c.toNat == 0x7F))

private def isSafeBasename (raw : String) : Bool :=
  let n := raw.trimAscii.toString
  !n.isEmpty && n != "." && n != ".." &&
  !(n.toList.any (fun c => c == '/' || c == '\\' || c.toNat < 0x20 || c.toNat == 0x7F))

private def resolveExecutableInPath? (name : String) (fallbacks : Array String := #[]) : IO (Option String) := do
  let pathEnv := (← IO.getEnv "PATH").getD ""
  for dir in pathEnv.splitOn ":" do
    let d := dir.trimAscii.toString
    if !d.isEmpty then
      let cand := (System.FilePath.mk d / name).toString
      if (← System.FilePath.pathExists cand) then
        return some cand
  for fb in fallbacks do
    if (← System.FilePath.pathExists fb) then
      return some fb
  return none

private def runCommandUnit (prog : String) (args : Array String) : IO (Except String Unit) := do
  try
    let child ← IO.Process.spawn {
      cmd := prog
      args := args
      stdin := .null
      stdout := .null
      stderr := .piped
    }
    let err ← child.stderr.readToEnd
    let code ← child.wait
    if code == 0 then return .ok ()
    else
      let detail := err.trimAscii.toString
      return .error (if detail.isEmpty then s!"{prog} exited {code}" else detail)
  catch e =>
    return .error (toString e)

/-- Encode an absolute POSIX path into an RFC 8089 `file://` URI (percent-encoding commas, spaces, and non-ASCII bytes so `dbus-send` `array:string:` never splits on `,`). -/
def filePathToUri (absPath : String) : String := Id.run do
  let hexDigit (n : UInt8) : Char :=
    let v := (n &&& 0x0F).toNat
    if v < 10 then Char.ofNat ('0'.toNat + v) else Char.ofNat ('A'.toNat + (v - 10))
  let mut out := "file://"
  for b in absPath.toUTF8 do
    let isUnreservedOrSlash :=
      (b ≥ 0x41 && b ≤ 0x5A) || (b ≥ 0x61 && b ≤ 0x7A) || (b ≥ 0x30 && b ≤ 0x39) ||
      b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E || b == 0x2F
    if isUnreservedOrSlash then
      out := out.push (Char.ofNat b.toNat)
    else
      out := ((out.push '%').push (hexDigit (b >>> 4))).push (hexDigit b)
  return out

private def hexNibbleVal? (b : UInt8) : Option UInt8 :=
  if b ≥ 0x30 && b ≤ 0x39 then some (b - 0x30)
  else if b ≥ 0x41 && b ≤ 0x46 then some (b - 0x41 + 10)
  else if b ≥ 0x61 && b ≤ 0x66 then some (b - 0x61 + 10)
  else none

private def percentDecodeNoNul? (s : String) : Option ByteArray := Id.run do
  let src := s.toUTF8
  let mut out := ByteArray.emptyWithCapacity src.size
  let mut i : Nat := 0
  while i < src.size do
    let b := src.get! i
    if b == 0 then return none
    if b == 0x25 then
      if i + 2 ≥ src.size then return none
      let some hi := hexNibbleVal? (src.get! (i + 1)) | return none
      let some lo := hexNibbleVal? (src.get! (i + 2)) | return none
      let dec := (hi <<< 4) ||| lo
      if dec == 0 then return none
      out := out.push dec
      i := i + 3
    else
      out := out.push b
      i := i + 1
  return some out

/-- Decode an RFC 8089 `file:///...` or `file://localhost/...` URI into an absolute POSIX path. -/
def fileUriToPath? (uri : String) : Option String := do
  let trimmed := uri.trimAscii.toString
  if !trimmed.startsWith "file://" then none
  let afterScheme := (trimmed.drop 7).toString
  let rawPath ←
    if afterScheme.startsWith "/" then some afterScheme
    else if afterScheme.startsWith "localhost/" then some (afterScheme.drop 9).toString
    else none
  let bytes ← percentDecodeNoNul? rawPath
  let decoded ← String.fromUTF8? bytes
  if !decoded.startsWith "/" then none
  let clean := OrbBin.PosixExt.stripTrailingSlash decoded
  some (if clean.isEmpty then "/" else clean)

/-! ### Minimal Session D-Bus Wire Client for `org.freedesktop.portal.FileChooser` -/

def dbusAlignUp (n align : Nat) : Nat :=
  if align ≤ 1 then n
  else
    let r := n % align
    if r == 0 then n else n + (align - r)

def dbusPadTo (b : ByteArray) (align : Nat) : ByteArray := Id.run do
  let target := dbusAlignUp b.size align
  let mut out := b
  while out.size < target do
    out := out.push 0
  return out

def dbusPushU32LE (b : ByteArray) (v : UInt32) : ByteArray :=
  let b1 := b.push (v &&& 0xFF).toUInt8
  let b2 := b1.push ((v >>> 8) &&& 0xFF).toUInt8
  let b3 := b2.push ((v >>> 16) &&& 0xFF).toUInt8
  b3.push ((v >>> 24) &&& 0xFF).toUInt8

def dbusReadU32 (b : ByteArray) (isBE : Bool) (off : Nat) : UInt32 :=
  if off + 4 > b.size then 0
  else if isBE then
    ((b.get! off).toUInt32 <<< 24) |||
    ((b.get! (off + 1)).toUInt32 <<< 16) |||
    ((b.get! (off + 2)).toUInt32 <<< 8) |||
    (b.get! (off + 3)).toUInt32
  else
    (b.get! off).toUInt32 |||
    ((b.get! (off + 1)).toUInt32 <<< 8) |||
    ((b.get! (off + 2)).toUInt32 <<< 16) |||
    ((b.get! (off + 3)).toUInt32 <<< 24)

def dbusPushString (b : ByteArray) (s : String) : ByteArray :=
  let bs := s.toUTF8
  let b1 := dbusPushU32LE (dbusPadTo b 4) bs.size.toUInt32
  (b1 ++ bs).push 0

def dbusPushSig (b : ByteArray) (sig : String) : ByteArray :=
  let bs := sig.toUTF8
  ((b.push bs.size.toUInt8) ++ bs).push 0

inductive DbusHdrVal where
  | str (s : String)
  | objPath (o : String)
  | sig (g : String)
  | u32 (v : UInt32)
  deriving Repr, Inhabited

inductive DbusOptVal where
  | str (s : String)
  | bool (v : Bool)
  | cstrBytes (path : String)
  deriving Repr, Inhabited

def buildDbusMessage (msgType : UInt8) (serial : UInt32)
    (fields : Array (UInt8 × DbusHdrVal)) (body : ByteArray := ByteArray.empty) : ByteArray := Id.run do
  let mut fbuf := ByteArray.empty
  let mut first := true
  for (code, hv) in fields do
    if !first then
      fbuf := dbusPadTo fbuf 8
    first := false
    fbuf := fbuf.push code
    match hv with
    | DbusHdrVal.str s =>
      fbuf := dbusPushSig fbuf "s"
      fbuf := dbusPushString fbuf s
    | DbusHdrVal.objPath o =>
      fbuf := dbusPushSig fbuf "o"
      fbuf := dbusPushString fbuf o
    | DbusHdrVal.sig g =>
      fbuf := dbusPushSig fbuf "g"
      fbuf := dbusPushSig fbuf g
    | DbusHdrVal.u32 v =>
      fbuf := dbusPushSig fbuf "u"
      fbuf := dbusPushU32LE (dbusPadTo fbuf 4) v
  let hdr0 := ByteArray.mk #['l'.toUInt8, msgType, 0, 1]
  let hdr1 := dbusPushU32LE hdr0 body.size.toUInt32
  let hdr2 := dbusPushU32LE hdr1 serial
  let hdr3 := dbusPushU32LE hdr2 fbuf.size.toUInt32
  (dbusPadTo (hdr3 ++ fbuf) 8) ++ body

def buildPortalOpenFileBody (title : String) (opts : Array (String × DbusOptVal)) : ByteArray := Id.run do
  let head := dbusPushString (dbusPushString ByteArray.empty "") title
  let mut elems := ByteArray.empty
  let mut first := true
  for (k, ov) in opts do
    if !first then
      elems := dbusPadTo elems 8
    first := false
    elems := dbusPushString elems k
    match ov with
    | DbusOptVal.str s =>
      elems := dbusPushSig elems "s"
      elems := dbusPushString elems s
    | DbusOptVal.bool v =>
      elems := dbusPushSig elems "b"
      elems := dbusPushU32LE (dbusPadTo elems 4) (if v then 1 else 0)
    | DbusOptVal.cstrBytes p =>
      elems := dbusPushSig elems "ay"
      let raw := p.toUTF8.push 0
      elems := (dbusPushU32LE (dbusPadTo elems 4) raw.size.toUInt32) ++ raw
  let withLen := dbusPushU32LE (dbusPadTo head 4) elems.size.toUInt32
  (dbusPadTo withLen 8) ++ elems

private partial def dbusSplitSingleType (sig : Array Char) (si : Nat) : Option Nat :=
  if h : si < sig.size then
    let c := sig[si]
    if c == 'y' || c == 'b' || c == 'n' || c == 'q' || c == 'i' || c == 'u' ||
       c == 'x' || c == 't' || c == 'd' || c == 'h' || c == 's' || c == 'o' ||
       c == 'g' || c == 'v' then
      some (si + 1)
    else if c == 'a' then
      dbusSplitSingleType sig (si + 1)
    else if c == '(' then
      Id.run do
        let mut depth : Nat := 1
        let mut j : Nat := si + 1
        while j < sig.size && depth > 0 do
          let cj := sig[j]!
          if cj == '(' then depth := depth + 1
          else if cj == ')' then depth := depth - 1
          j := j + 1
        return if depth == 0 then some j else none
    else if c == '{' then
      Id.run do
        let mut depth : Nat := 1
        let mut j : Nat := si + 1
        while j < sig.size && depth > 0 do
          let cj := sig[j]!
          if cj == '{' then depth := depth + 1
          else if cj == '}' then depth := depth - 1
          j := j + 1
        return if depth == 0 then some j else none
    else none
  else none

private def dbusTypeAlign (sig : Array Char) (si : Nat) : Nat :=
  if h : si < sig.size then
    match sig[si] with
    | 'n' | 'q' => 2
    | 'b' | 'i' | 'u' | 'h' | 's' | 'o' | 'a' => 4
    | 'x' | 't' | 'd' | '(' | '{' => 8
    | _ => 1
  else 1

private def dbusSkipValue (fuel : Nat) (buf : ByteArray) (isBE : Bool) (limit : Nat)
    (off : Nat) (sig : Array Char) (si se : Nat) : Option Nat :=
  match fuel with
  | 0 => none
  | fuel' + 1 =>
    if si ≥ se || se > sig.size || limit > buf.size then none
    else
      let p := dbusAlignUp off (dbusTypeAlign sig si)
      if p > limit then none
      else
        match sig[si]! with
        | 'y' => if p + 1 ≤ limit then some (p + 1) else none
        | 'n' | 'q' => if p + 2 ≤ limit then some (p + 2) else none
        | 'b' | 'i' | 'u' | 'h' => if p + 4 ≤ limit then some (p + 4) else none
        | 'x' | 't' | 'd' => if p + 8 ≤ limit then some (p + 8) else none
        | 's' | 'o' =>
          if p + 4 > limit then none
          else
            let sLen := (dbusReadU32 buf isBE p).toNat
            let after := p + 4 + sLen + 1
            if after ≤ limit then some after else none
        | 'g' =>
          if p + 1 > limit then none
          else
            let gLen := (buf.get! p).toNat
            let after := p + 1 + gLen + 1
            if after ≤ limit then some after else none
        | 'v' =>
          if p + 1 > limit then none
          else
            let gLen := (buf.get! p).toNat
            let valOff := p + 1 + gLen + 1
            if valOff > limit then none
            else
              match String.fromUTF8? (buf.extract (p + 1) (p + 1 + gLen)) with
              | none => none
              | some vs =>
                let vsig := vs.toList.toArray
                match dbusSplitSingleType vsig 0 with
                | some vse =>
                  if vse == vsig.size then dbusSkipValue fuel' buf isBE limit valOff vsig 0 vse
                  else none
                | none => none
        | 'a' =>
          if si + 1 ≥ se || p + 4 > limit then none
          else
            let arrBytes := (dbusReadU32 buf isBE p).toNat
            let elemStart := dbusAlignUp (p + 4) (dbusTypeAlign sig (si + 1))
            let after := elemStart + arrBytes
            if after ≤ limit then some after else none
        | '(' | '{' => Id.run do
          let mut curSi := si + 1
          let mut curOff := p
          while curSi + 1 < se do
            let some nextSi := dbusSplitSingleType sig curSi | return none
            let some nextOff := dbusSkipValue fuel' buf isBE limit curOff sig curSi nextSi | return none
            curSi := nextSi
            curOff := nextOff
          return if curSi + 1 == se then some curOff else none
        | _ => none

private def dbusReadStringAt? (buf : ByteArray) (isBE : Bool) (limit off : Nat) : Option (String × Nat) :=
  let p := dbusAlignUp off 4
  if limit > buf.size || p + 4 > limit then none
  else
    let sLen := (dbusReadU32 buf isBE p).toNat
    let after := p + 4 + sLen + 1
    if after > limit then none
    else
      match String.fromUTF8? (buf.extract (p + 4) (p + 4 + sLen)) with
      | some s => some (s, after)
      | none => none

private def dbusReadSigAt? (buf : ByteArray) (limit off : Nat) : Option (String × Nat) :=
  if limit > buf.size || off + 1 > limit then none
  else
    let gLen := (buf.get! off).toNat
    let after := off + 1 + gLen + 1
    if after > limit then none
    else
      match String.fromUTF8? (buf.extract (off + 1) (off + 1 + gLen)) with
      | some s => some (s, after)
      | none => none

structure DbusMessageFrame where
  msgType      : UInt8
  isBigEndian  : Bool
  serial       : UInt32
  replySerial? : Option UInt32 := none
  path?        : Option String := none
  interface?   : Option String := none
  member?      : Option String := none
  errorName?   : Option String := none
  bodySig?     : Option String := none
  rawMsg       : ByteArray
  bodyStart    : Nat
  bodyEnd      : Nat

inductive DbusFrameParse where
  | incomplete
  | invalid (reason : String)
  | ok (frame : DbusMessageFrame) (rest : ByteArray)

def parseDbusMessageFrame (rxBuf : ByteArray) : DbusFrameParse := Id.run do
  if rxBuf.size < 16 then return .incomplete
  let endianByte := rxBuf.get! 0
  if endianByte != 'l'.toUInt8 && endianByte != 'B'.toUInt8 then
    return .invalid "bad_dbus_endian"
  let isBE := endianByte == 'B'.toUInt8
  let msgType := rxBuf.get! 1
  let protoVer := rxBuf.get! 3
  if protoVer != 1 then
    return .invalid "bad_dbus_version"
  let bodyLen := (dbusReadU32 rxBuf isBE 4).toNat
  let serial := dbusReadU32 rxBuf isBE 8
  let fieldsLen := (dbusReadU32 rxBuf isBE 12).toNat
  if fieldsLen > 1048576 || bodyLen > 16777216 then
    return .invalid "dbus_frame_too_large"
  let fEnd := 16 + fieldsLen
  let bodyStart := dbusAlignUp fEnd 8
  let totalLen := bodyStart + bodyLen
  if rxBuf.size < totalLen then
    return .incomplete
  let rawMsg := rxBuf.extract 0 totalLen
  let rest := rxBuf.extract totalLen rxBuf.size
  let mut replySerial? : Option UInt32 := none
  let mut path? : Option String := none
  let mut interface? : Option String := none
  let mut member? : Option String := none
  let mut errorName? : Option String := none
  let mut bodySig? : Option String := none
  let mut fCur : Nat := 16
  while fCur < fEnd do
    fCur := dbusAlignUp fCur 8
    if fCur ≥ fEnd then break
    if fCur + 2 > fEnd then return .invalid "truncated_dbus_header_field"
    let code := rawMsg.get! fCur
    let some (fSig, valOff) := dbusReadSigAt? rawMsg fEnd (fCur + 1)
      | return .invalid "bad_dbus_header_sig"
    if code == 1 && (fSig == "o" || fSig == "s") then
      let some (v, nextOff) := dbusReadStringAt? rawMsg isBE fEnd valOff | return .invalid "bad_dbus_path"
      path? := some v
      fCur := nextOff
    else if code == 2 && fSig == "s" then
      let some (v, nextOff) := dbusReadStringAt? rawMsg isBE fEnd valOff | return .invalid "bad_dbus_iface"
      interface? := some v
      fCur := nextOff
    else if code == 3 && fSig == "s" then
      let some (v, nextOff) := dbusReadStringAt? rawMsg isBE fEnd valOff | return .invalid "bad_dbus_member"
      member? := some v
      fCur := nextOff
    else if code == 4 && fSig == "s" then
      let some (v, nextOff) := dbusReadStringAt? rawMsg isBE fEnd valOff | return .invalid "bad_dbus_error"
      errorName? := some v
      fCur := nextOff
    else if code == 5 && fSig == "u" then
      let up := dbusAlignUp valOff 4
      if up + 4 > fEnd then return .invalid "bad_dbus_reply_serial"
      replySerial? := some (dbusReadU32 rawMsg isBE up)
      fCur := up + 4
    else if code == 8 && fSig == "g" then
      let some (v, nextOff) := dbusReadSigAt? rawMsg fEnd valOff | return .invalid "bad_dbus_body_sig"
      bodySig? := some v
      fCur := nextOff
    else
      let sigChars := fSig.toList.toArray
      let some se := dbusSplitSingleType sigChars 0 | return .invalid "unknown_dbus_header_type"
      let some nextOff := dbusSkipValue 64 rawMsg isBE fEnd valOff sigChars 0 se
        | return .invalid "skip_dbus_header_failed"
      fCur := nextOff
  return .ok {
    msgType, isBigEndian := isBE, serial, replySerial?, path?, interface?, member?, errorName?, bodySig?,
    rawMsg, bodyStart, bodyEnd := totalLen
  } rest

def decodePortalResponseBody? (frame : DbusMessageFrame) : Option (UInt32 × Array String) := Id.run do
  let buf := frame.rawMsg
  let isBE := frame.isBigEndian
  let bStart := frame.bodyStart
  let bEnd := frame.bodyEnd
  if bStart + 8 > bEnd then return none
  let respCode := dbusReadU32 buf isBE bStart
  if respCode != 0 then
    return some (respCode, #[])
  let arrBytes := (dbusReadU32 buf isBE (bStart + 4)).toNat
  let elemStart := dbusAlignUp (bStart + 8) 8
  let arrEnd := elemStart + arrBytes
  if arrEnd > bEnd then return none
  let mut cur := elemStart
  while cur < arrEnd do
    cur := dbusAlignUp cur 8
    if cur ≥ arrEnd then break
    let some (key, afterKey) := dbusReadStringAt? buf isBE arrEnd cur | return none
    let some (vsigStr, valOff) := dbusReadSigAt? buf arrEnd afterKey | return none
    if key == "uris" && vsigStr == "as" then
      let ap := dbusAlignUp valOff 4
      if ap + 4 > arrEnd then return none
      let asBytes := (dbusReadU32 buf isBE ap).toNat
      let mut sCur := ap + 4
      let sEnd := sCur + asBytes
      if sEnd > arrEnd then return none
      let mut uris : Array String := #[]
      while sCur < sEnd do
        let some (u, nextS) := dbusReadStringAt? buf isBE sEnd sCur | return none
        uris := uris.push u
        sCur := nextS
      return some (0, uris)
    else
      let vsig := vsigStr.toList.toArray
      let some vse := dbusSplitSingleType vsig 0 | return none
      let some nextCur := dbusSkipValue 64 buf isBE arrEnd valOff vsig 0 vse | return none
      cur := nextCur
  return some (0, #[])

private def resolveDbusSessionSocketPath? : IO (Option String) := do
  let rawAddr := (← IO.getEnv "DBUS_SESSION_BUS_ADDRESS").getD ""
  for entry in rawAddr.splitOn ";" do
    let t := entry.trimAscii.toString
    if t.startsWith "unix:" then
      for kv in (t.drop 5).toString.splitOn "," do
        if kv.startsWith "path=" then
          let rawP := (kv.drop 5).toString
          if let some bs := percentDecodeNoNul? rawP then
            if let some p := String.fromUTF8? bs then
              if !p.isEmpty then
                return some p
  if let some xdg ← OrbBin.PosixExt.getEnvNonEmpty "XDG_RUNTIME_DIR" then
    let cand := (System.FilePath.mk xdg.trimAscii.toString / "bus").toString
    if (← System.FilePath.pathExists cand) then
      return some cand
  let euid ← OrbBin.PosixExt.geteuid
  let fallback := s!"/run/user/{euid}/bus"
  if (← System.FilePath.pathExists fallback) then
    return some fallback
  return none

private def readDbusFrameTimeout (fd : LeanSys.Posix.Fd) (carry : ByteArray) (budgetMs : Nat) :
    IO (Except String (DbusMessageFrame × ByteArray)) := do
  let tStart ← IO.monoMsNow
  let mut buf := carry
  while true do
    match parseDbusMessageFrame buf with
    | .ok frame rest => return .ok (frame, rest)
    | .invalid reason => return .error reason
    | .incomplete =>
      let elapsed := (← IO.monoMsNow) - tStart
      if elapsed ≥ budgetMs then
        return .error "dbus_timeout"
      let sliceMs : UInt32 := (Nat.min (budgetMs - elapsed) 2500).toUInt32
      match ← LeanSys.Posix.pollReadable fd sliceMs with
      | .error .eagain => pure ()
      | .error _ => return .error "dbus_poll_error"
      | .ok () =>
        let chunk ← LeanSys.Posix.readStreamChunk fd 16384
        if chunk.isEmpty then
          return .error "dbus_eof"
        buf := if buf.isEmpty then chunk else buf ++ chunk
  return .error "dbus_timeout"

private def findAsciiCrlf? (b : ByteArray) : Option Nat := Id.run do
  if b.size < 2 then return none
  for i in [0:b.size - 1] do
    if b.get! i == 0x0D && b.get! (i + 1) == 0x0A then
      return some i
  return none

inductive PortalChooserOutcome where
  | selected (paths : Array String)
  | cancelled
  | unavailable (reason : String)
  deriving Repr

private def runPortalFileChooser (title : String) (directory multiple : Bool)
    (initialDir? : Option String := none) : IO PortalChooserOutcome := do
  let some sockPath ← resolveDbusSessionSocketPath?
    | return .unavailable "no_dbus_session_socket"
  let fd ← match ← LeanSys.Posix.unixConnect sockPath with
    | .ok f => pure f
    | .error _ => return .unavailable "dbus_connect_failed"
  try
    let euid ← OrbBin.PosixExt.geteuid
    let uidHex := LeanSys.Auth.bytesToHexLower (toString euid).toUTF8
    let authWire := (ByteArray.mk #[0]) ++ s!"AUTH EXTERNAL {uidHex}\r\n".toUTF8
    if (← LeanSys.Posix.writeAll fd authWire false).isOk.not then
      return .unavailable "dbus_auth_write_failed"
    let tAuthStart ← IO.monoMsNow
    let mut authBuf := ByteArray.empty
    while (findAsciiCrlf? authBuf).isNone do
      if authBuf.size > 4096 || (← IO.monoMsNow) - tAuthStart ≥ 3000 then
        return .unavailable "dbus_auth_timeout"
      match ← LeanSys.Posix.pollReadable fd 1000 with
      | .error .eagain => pure ()
      | .error _ => return .unavailable "dbus_auth_poll_failed"
      | .ok () =>
        let chunk ← LeanSys.Posix.readStreamChunk fd 512
        if chunk.isEmpty then return .unavailable "dbus_auth_eof"
        authBuf := authBuf ++ chunk
    let some crlfIdx := findAsciiCrlf? authBuf
      | return .unavailable "dbus_auth_bad_line"
    let authLine := String.fromUTF8? (authBuf.extract 0 crlfIdx) |>.getD ""
    if !authLine.startsWith "OK " then
      return .unavailable "dbus_auth_rejected"
    let mut rxCarry := authBuf.extract (crlfIdx + 2) authBuf.size
    if (← LeanSys.Posix.writeAll fd "BEGIN\r\n".toUTF8 false).isOk.not then
      return .unavailable "dbus_begin_write_failed"

    -- 1. Hello (serial 1)
    let helloMsg := buildDbusMessage 1 1 #[
      (1, .objPath "/org/freedesktop/DBus"),
      (2, .str "org.freedesktop.DBus"),
      (3, .str "Hello"),
      (6, .str "org.freedesktop.DBus")
    ]
    if (← LeanSys.Posix.writeAll fd helloMsg false).isOk.not then
      return .unavailable "dbus_hello_write_failed"
    let mut helloDone := false
    let mut guardSteps : Nat := 0
    while !helloDone && guardSteps < 16 do
      guardSteps := guardSteps + 1
      match ← readDbusFrameTimeout fd rxCarry 5000 with
      | .error e => return .unavailable e
      | .ok (frm, rest) =>
        rxCarry := rest
        if frm.replySerial? == some 1 then
          if frm.msgType == 2 then helloDone := true
          else return .unavailable "dbus_hello_error"
    if !helloDone then return .unavailable "dbus_hello_unanswered"

    -- 2. AddMatch for org.freedesktop.portal.Request::Response (serial 2)
    let matchRule := "type='signal',interface='org.freedesktop.portal.Request',member='Response'"
    let addMatchMsg := buildDbusMessage 1 2 #[
      (1, .objPath "/org/freedesktop/DBus"),
      (2, .str "org.freedesktop.DBus"),
      (3, .str "AddMatch"),
      (6, .str "org.freedesktop.DBus"),
      (8, .sig "s")
    ] (dbusPushString ByteArray.empty matchRule)
    if (← LeanSys.Posix.writeAll fd addMatchMsg false).isOk.not then
      return .unavailable "dbus_addmatch_write_failed"
    let mut matchDone := false
    guardSteps := 0
    while !matchDone && guardSteps < 16 do
      guardSteps := guardSteps + 1
      match ← readDbusFrameTimeout fd rxCarry 5000 with
      | .error e => return .unavailable e
      | .ok (frm, rest) =>
        rxCarry := rest
        if frm.replySerial? == some 2 then
          if frm.msgType == 2 then matchDone := true
          else return .unavailable "dbus_addmatch_error"
    if !matchDone then return .unavailable "dbus_addmatch_unanswered"

    -- 3. OpenFile on org.freedesktop.portal.FileChooser (serial 3)
    let handleToken := "orb_" ++ (← randomHexBytes 8)
    let mut opts : Array (String × DbusOptVal) := #[
      ("handle_token", .str handleToken),
      ("modal", .bool true),
      ("directory", .bool directory),
      ("multiple", .bool multiple)
    ]
    if let some dirHint := initialDir? then
      let cleanHint := dirHint.trimAscii.toString
      if !cleanHint.isEmpty && cleanHint.startsWith "/" && !(cleanHint.toList.contains '\x00') then
        let stHint ← OrbBin.PosixExt.statPath cleanHint
        if stHint.exists_ && stHint.isDir then
          opts := opts.push ("current_folder", .cstrBytes cleanHint)
    let openBody := buildPortalOpenFileBody title opts
    let openMsg := buildDbusMessage 1 3 #[
      (1, .objPath "/org/freedesktop/portal/desktop"),
      (2, .str "org.freedesktop.portal.FileChooser"),
      (3, .str "OpenFile"),
      (6, .str "org.freedesktop.portal.Desktop"),
      (8, .sig "ssa{sv}")
    ] openBody
    if (← LeanSys.Posix.writeAll fd openMsg false).isOk.not then
      return .unavailable "portal_openfile_write_failed"

    let mut reqHandlePath : Option String := none
    let mut earlySignals : Array DbusMessageFrame := #[]
    guardSteps := 0
    while reqHandlePath.isNone && guardSteps < 32 do
      guardSteps := guardSteps + 1
      match ← readDbusFrameTimeout fd rxCarry 8000 with
      | .error e => return .unavailable e
      | .ok (frm, rest) =>
        rxCarry := rest
        if frm.replySerial? == some 3 then
          if frm.msgType == 3 then
            return .unavailable (frm.errorName?.getD "portal_openfile_error")
          else if frm.msgType == 2 then
            match dbusReadStringAt? frm.rawMsg frm.isBigEndian frm.bodyEnd frm.bodyStart with
            | some (hPath, _) => reqHandlePath := some hPath
            | none => return .unavailable "portal_bad_handle_reply"
        else if frm.msgType == 4 && frm.interface? == some "org.freedesktop.portal.Request" && frm.member? == some "Response" then
          earlySignals := earlySignals.push frm
    let some expectedPath := reqHandlePath
      | return .unavailable "portal_openfile_unanswered"

    let matchesHandle (frm : DbusMessageFrame) : Bool :=
      frm.path? == some expectedPath || (frm.path?.getD "").endsWith ("/" ++ handleToken)

    for sigFrm in earlySignals do
      if matchesHandle sigFrm then
        match decodePortalResponseBody? sigFrm with
        | some (0, uris) => return .selected (uris.filterMap fileUriToPath?)
        | some (_, _)    => return .cancelled
        | none           => return .unavailable "portal_bad_response_body"

    -- 4. Wait up to 10 minutes for interactive user selection/cancel
    let tWaitStart ← IO.monoMsNow
    while (← IO.monoMsNow) - tWaitStart < 600000 do
      let rem := 600000 - ((← IO.monoMsNow) - tWaitStart)
      match ← readDbusFrameTimeout fd rxCarry rem with
      | .error "dbus_timeout" =>
        return .cancelled
      | .error e =>
        return .unavailable e
      | .ok (frm, rest) =>
        rxCarry := rest
        if frm.msgType == 4 && frm.interface? == some "org.freedesktop.portal.Request" &&
           frm.member? == some "Response" && matchesHandle frm then
          match decodePortalResponseBody? frm with
          | some (0, uris) => return .selected (uris.filterMap fileUriToPath?)
          | some (_, _)    => return .cancelled
          | none           => return .unavailable "portal_bad_response_body"
    return .cancelled
  finally
    discard <| LeanSys.Posix.closeFd fd

private def readCommandStdout? (cmd : String) (args : Array String) : IO (Option String) := do
  try
    let child ← IO.Process.spawn {
      cmd := cmd
      args := args
      stdin := .null
      stdout := .piped
      stderr := .null
    }
    let out ← child.stdout.readToEnd
    let code ← child.wait
    if code == 0 then return some out.trimAscii.toString else return none
  catch _ =>
    return none

private def runCliFilePickerFallback (title : String) (directory multiple : Bool)
    (initialDir? : Option String := none) : IO (Array String) := do
  let validInitialDir? ← do
    match initialDir? with
    | none => pure none
    | some raw =>
      let clean := raw.trimAscii.toString
      if clean.isEmpty then pure none
      else
        let st ← OrbBin.PosixExt.statPath clean
        pure (if st.exists_ && st.isDir then some clean else none)
  if let some zenityBin ← resolveExecutableInPath? "zenity" #["/run/current-system/sw/bin/zenity", "/usr/bin/zenity"] then
    let mut zArgs : Array String := #["--file-selection", s!"--title={title}"]
    if directory then zArgs := zArgs.push "--directory"
    if multiple then zArgs := zArgs ++ #["--multiple", "--separator=\n"]
    if let some d := validInitialDir? then
      zArgs := zArgs.push s!"--filename={OrbBin.PosixExt.stripTrailingSlash d}/"
    match ← readCommandStdout? zenityBin zArgs with
    | some out =>
      return (out.splitOn "\n").toArray.filterMap fun ln =>
        let p := ln.trimAscii.toString
        if p.isEmpty then none else some p
    | none => return #[]
  if let some kdialogBin ← resolveExecutableInPath? "kdialog" #["/run/current-system/sw/bin/kdialog", "/usr/bin/kdialog"] then
    let startDir := validInitialDir?.getD "."
    let kArgs : Array String :=
      if directory then #["--getexistingdirectory", startDir, "--title", title]
      else if multiple then #["--getopenfilename", startDir, "--multiple", "--separate-output", "--title", title]
      else #["--getopenfilename", startDir, "--title", title]
    match ← readCommandStdout? kdialogBin kArgs with
    | some out =>
      return (out.splitOn "\n").toArray.filterMap fun ln =>
        let p := ln.trimAscii.toString
        if p.isEmpty then none else some p
    | none => return #[]
  return #[]

private def pickLinuxPaths (title : String) (directory multiple : Bool)
    (initialDir? : Option String := none) : IO (Array String) := do
  match ← runPortalFileChooser title directory multiple initialDir? with
  | .selected paths => return paths
  | .cancelled => return #[]
  | .unavailable _ => runCliFilePickerFallback title directory multiple initialDir?

private def runDetachedOpen (hostOs : String) (args : Array String) : IO (Except String Unit) := do
  let prog := if hostOs == "macos" then "/usr/bin/open" else "xdg-open"
  runCommandUnit prog args

private def runDetachedOpenDirectory (hostOs : String) (dirPath : String) : IO (Except String Unit) := do
  if hostOs == "macos" then
    return ← runDetachedOpen "macos" #[dirPath]
  if let some gioBin ← resolveExecutableInPath? "gio" #["/run/current-system/sw/bin/gio", "/usr/bin/gio"] then
    if let .ok () ← runCommandUnit gioBin #["open", dirPath] then
      return .ok ()
  runDetachedOpen hostOs #[dirPath]

private def runDetachedRevealFile (hostOs : String) (filePath : String) (fallbackDir : String) : IO (Except String Unit) := do
  if hostOs == "macos" then
    return ← runDetachedOpen "macos" #["-R", filePath]
  let dbusAddr := (← IO.getEnv "DBUS_SESSION_BUS_ADDRESS").getD ""
  if !dbusAddr.trimAscii.toString.isEmpty then
    if let some dbusSend ← resolveExecutableInPath? "dbus-send" #["/run/current-system/sw/bin/dbus-send", "/usr/bin/dbus-send"] then
      let uri := filePathToUri filePath
      let dbusArgs := #[
        "--session", "--print-reply", "--reply-timeout=2500",
        "--dest=org.freedesktop.FileManager1",
        "/org/freedesktop/FileManager1",
        "org.freedesktop.FileManager1.ShowItems",
        s!"array:string:{uri}",
        "string:"
      ]
      if let .ok () ← runCommandUnit dbusSend dbusArgs then
        return .ok ()
  runDetachedOpenDirectory hostOs fallbackDir

private def readSystemToolStdout? (name : String) (fallbacks : Array String) (args : Array String) : IO (Option String) := do
  match ← resolveExecutableInPath? name fallbacks with
  | some bin => readCommandStdout? bin args
  | none => readCommandStdout? name args

private def readProcCpuJiffies : IO (Option (Nat × Nat)) := do
  let raw ← try IO.FS.readFile "/proc/stat" catch _ => pure ""
  let some first := (raw.splitOn "\n").head? | return none
  if !(first.startsWith "cpu ") then return none
  let nums := ((first.drop 4).toString.splitOn " ").filterMap (fun s => s.trimAscii.toString.toNat?)
  if nums.length < 4 then return none
  let total := nums.foldl (· + ·) 0
  let idle := nums[3]! + (if h : 4 < nums.length then nums[4] else 0)
  return if total > 0 then some (total, idle) else none

private def sampleHostConsumers (hostOs : String) : IO (Array JVal) := do
  let mut orbRss : Nat := 0
  let mut orbProcs : Nat := 0
  let mut voiceRss : Nat := 0
  let mut voiceProcs : Nat := 0
  let mut agentRss : Nat := 0
  let mut agentProcs : Nat := 0
  if hostOs != "macos" then
    let procEntries ← try (System.FilePath.mk "/proc").readDir catch _ => pure #[]
    for ent in procEntries do
      if ent.fileName.toNat?.isSome then
        let stTxt ← try IO.FS.readFile (ent.path / "status") catch _ => pure ""
        if !stTxt.isEmpty then
          let mut nm := ""
          let mut rssBytes : Nat := 0
          for ln in stTxt.splitOn "\n" do
            if ln.startsWith "Name:" then
              nm := (ln.drop 5).toString.trimAscii.toString.toLower
            else if rssBytes == 0 && ln.startsWith "VmRSS:" then
              for tok in (ln.drop 6).toString.splitOn " " do
                if rssBytes == 0 then
                  if let some kb := tok.trimAscii.toString.toNat? then
                    rssBytes := kb * 1024
          if rssBytes > 0 && !nm.isEmpty then
            if nm == "orb" || nm == "orb-desktop" || nm == ".orb-desktop-un" || nm == "orb-locald" || nm == "orb-signer" ||
               nm.startsWith "webkitwebproces" || nm.startsWith "webkitnetworkpr" then
              orbRss := orbRss + rssBytes
              orbProcs := orbProcs + 1
            else if nm == "claude" || nm == "codex" || nm == "opencode" || nm == "grok" || nm == "agy" || nm == "vibe" then
              agentRss := agentRss + rssBytes
              agentProcs := agentProcs + 1
            else if nm.startsWith "python" || nm == "orb-voice" then
              let cmdRaw ← try IO.FS.readBinFile (ent.path / "cmdline") catch _ => pure ByteArray.empty
              let cmdStr := (String.ofList (cmdRaw.data.toList.map fun b => if b < 32 || b >= 127 then ' ' else Char.ofNat b.toNat)).toLower
              if ((cmdStr.splitOn "voice/worker.py").length > 1) || ((cmdStr.splitOn "orb-voice").length > 1) then
                voiceRss := voiceRss + rssBytes
                voiceProcs := voiceProcs + 1
  else if let some psOut ← readSystemToolStdout? "ps" #["/bin/ps", "/usr/bin/ps"] #["-axo", "rss=,comm="] then
    for ln in psOut.splitOn "\n" do
      let t := ln.trimAscii.toString
      if !t.isEmpty then
        let cols := (t.splitOn " ").filter (fun s => !s.isEmpty)
        if let rssStr :: commParts := cols then
          let rssBytes := (rssStr.toNat?.getD 0) * 1024
          let commFull := (String.intercalate " " commParts).trimAscii.toString
          let base := ((commFull.splitOn "/").getLast?.getD commFull).toLower
          if base == "orb" || base == "orb-locald" || base == "orb-signer" then
            orbRss := orbRss + rssBytes
            orbProcs := orbProcs + 1
          else if ((commFull.toLower.splitOn "voice/worker.py").length > 1) || ((commFull.toLower.splitOn "orb-voice").length > 1) then
            voiceRss := voiceRss + rssBytes
            voiceProcs := voiceProcs + 1
          else if base == "claude" || base == "codex" || base == "opencode" || base == "grok" || base == "agy" || base == "vibe" then
            agentRss := agentRss + rssBytes
            agentProcs := agentProcs + 1
  return #[
    .obj #[("label", .str "Orb"), ("memory", JVal.nat orbRss), ("processes", JVal.nat orbProcs)],
    .obj #[("label", .str "Voice"), ("memory", JVal.nat voiceRss), ("processes", JVal.nat voiceProcs)],
    .obj #[("label", .str "Local agents"), ("memory", JVal.nat agentRss), ("processes", JVal.nat agentProcs)]
  ]

private def sampleHostMetricsCached (stRef : IO.Ref LocaldState) (details : Bool) : IO JVal := do
  let nowMono ← IO.monoMsNow
  let st ← stRef.get
  if st.lastMetricsMonoMs > 0 && nowMono - st.lastMetricsMonoMs < 2500 &&
     st.lastMetricsSnap != .null && (!details || st.lastMetricsDetails) then
    return st.lastMetricsSnap
  let nowSec ← OrbBin.PosixExt.nowEpoch
  let sampledAtMs := nowSec.toNat * 1000
  let hostOs := st.hostOs
  let mut memTotal := st.cachedMemTotal
  let mut ncpu := st.cachedLogicalCpu
  let mut nextCpuTotal := st.prevCpuTotal
  let mut nextCpuIdle := st.prevCpuIdle
  let mut memUsed : Nat := 0
  let mut diskTotal : Nat := 0
  let mut diskUsed : Nat := 0
  let mut cpuPct? : Option Nat := none
  if hostOs == "macos" then
    if memTotal == 0 then
      if let some hwOut ← readSystemToolStdout? "sysctl" #["/usr/sbin/sysctl", "/sbin/sysctl"] #["-n", "hw.memsize"] then
        memTotal := hwOut.toNat?.getD 0
    if ncpu == 0 then
      if let some cpuOut ← readSystemToolStdout? "sysctl" #["/usr/sbin/sysctl", "/sbin/sysctl"] #["-n", "hw.logicalcpu"] then
        ncpu := max 1 (cpuOut.toNat?.getD 1)
    if ncpu == 0 then ncpu := 1
    if let some vmOut ← readSystemToolStdout? "vm_stat" #["/usr/bin/vm_stat"] #[] then
      let lines := vmOut.splitOn "\n"
      let mut pageSize : Nat := 16384
      if let some first := lines.head? then
        for tok in first.splitOn " " do
          if let some ps := tok.toNat? then
            if ps ≥ 4096 then pageSize := ps
      let parseVmPages (pfx : String) : Nat := Id.run do
        for ln in lines do
          if ln.startsWith pfx then
            let rhs := ((ln.splitOn ":").drop 1 |> String.intercalate ":").trimAscii.toString
            let clean := if rhs.endsWith "." then (rhs.dropEnd 1).toString else rhs
            if let some n := clean.trimAscii.toString.toNat? then return n
        return 0
      let active := parseVmPages "Pages active"
      let wired := parseVmPages "Pages wired down"
      let comp := parseVmPages "Pages occupied by compressor"
      let usedCandidate := (active + wired + comp) * pageSize
      if memTotal > 0 then
        memUsed := min usedCandidate memTotal
    if let some psOut ← readSystemToolStdout? "ps" #["/bin/ps", "/usr/bin/ps"] #["-A", "-o", "%cpu="] then
      let mut tenthsSum : Nat := 0
      for ln in psOut.splitOn "\n" do
        let t := ln.trimAscii.toString
        if !t.isEmpty then
          match t.splitOn "." with
          | [w] => tenthsSum := tenthsSum + (w.toNat?.getD 0) * 10
          | [w, f] =>
            let d1 := ((f.take 1).toString.toNat?).getD 0
            tenthsSum := tenthsSum + (w.toNat?.getD 0) * 10 + d1
          | _ => pure ()
      let normPct := min 100 ((tenthsSum / ncpu + 5) / 10)
      cpuPct? := some normPct
  else
    let memInfo ← try IO.FS.readFile "/proc/meminfo" catch _ => pure ""
    if !memInfo.isEmpty then
      let parseKb (k : String) : Nat := Id.run do
        for ln in memInfo.splitOn "\n" do
          if ln.startsWith k then
            for tok in (ln.drop k.length).toString.splitOn " " do
              if let some n := tok.trimAscii.toString.toNat? then return n * 1024
        return 0
      if memTotal == 0 then memTotal := parseKb "MemTotal:"
      let avail := parseKb "MemAvailable:"
      if memTotal > avail && avail > 0 then memUsed := memTotal - avail
    if let some (curTot, curIdle) ← readProcCpuJiffies then
      if st.prevCpuTotal > 0 && curTot > st.prevCpuTotal then
        let dTot := curTot - st.prevCpuTotal
        let dIdle := if curIdle ≥ st.prevCpuIdle then curIdle - st.prevCpuIdle else 0
        let dBusy := if dTot ≥ dIdle then dTot - dIdle else 0
        cpuPct? := some (min 100 ((dBusy * 100 + dTot / 2) / dTot))
        nextCpuTotal := curTot
        nextCpuIdle := curIdle
      else
        IO.sleep 25
        if let some (curTot2, curIdle2) ← readProcCpuJiffies then
          if curTot2 > curTot then
            let dTot := curTot2 - curTot
            let dIdle := if curIdle2 ≥ curIdle then curIdle2 - curIdle else 0
            let dBusy := if dTot ≥ dIdle then dTot - dIdle else 0
            cpuPct? := some (min 100 ((dBusy * 100 + dTot / 2) / dTot))
            nextCpuTotal := curTot2
            nextCpuIdle := curIdle2
          else
            cpuPct? := some 0
            nextCpuTotal := curTot2
            nextCpuIdle := curIdle2
        else
          nextCpuTotal := curTot
          nextCpuIdle := curIdle
  let (vfsTot, vfsUsed) ← OrbBin.PosixExt.statvfsBytes "/"
  if vfsTot > 0 then
    diskTotal := vfsTot.toNat
    diskUsed := vfsUsed.toNat
  else if let some dfOut ← readSystemToolStdout? "df" #["/bin/df", "/usr/bin/df", "/run/current-system/sw/bin/df"] #["-k", "/"] then
    if let some dataLn := (dfOut.splitOn "\n").drop 1 |>.head? then
      let cols := (dataLn.splitOn " ").filter (fun s => !s.trimAscii.toString.isEmpty)
      if cols.length ≥ 4 then
        diskTotal := (cols[1]!.toNat?.getD 0) * 1024
        diskUsed := (cols[2]!.toNat?.getD 0) * 1024
  let consumers ← if details then sampleHostConsumers hostOs else pure #[]
  let cpuVal : JVal := match cpuPct? with | some n => JVal.nat n | none => .null
  let memPctVal : JVal :=
    if memTotal > 0 then
      let tenths := (memUsed * 1000 + memTotal / 2) / memTotal
      .num s!"{tenths / 10}.{tenths % 10}"
    else .null
  let histPoint : JVal := .obj #[
    ("time", JVal.nat sampledAtMs),
    ("cpu", cpuVal),
    ("gpu", .null),
    ("memory", memPctVal)
  ]
  let snap ← stRef.modifyGet fun s =>
    let cutoff := if sampledAtMs > 60000 then sampledAtMs - 60000 else 0
    let keptHist := (s.metricsHistory.filter (fun (ts, _) => ts ≥ cutoff)).push (sampledAtMs, histPoint)
    let out : JVal := .obj #[
      ("sampled_at", JVal.nat sampledAtMs),
      ("cpu_percent", cpuVal),
      ("gpu_percent", .null),
      ("memory_used", JVal.nat memUsed),
      ("memory_total", JVal.nat memTotal),
      ("memory_used_bytes", JVal.nat memUsed),
      ("memory_total_bytes", JVal.nat memTotal),
      ("disk_used", JVal.nat diskUsed),
      ("disk_total", JVal.nat diskTotal),
      ("history", .arr (keptHist.map (·.2))),
      ("consumers", .arr consumers)
    ]
    (out, { s with
        cachedMemTotal := if memTotal > 0 then memTotal else s.cachedMemTotal
        cachedLogicalCpu := if ncpu > 0 then ncpu else s.cachedLogicalCpu
        prevCpuTotal := if nextCpuTotal > 0 then nextCpuTotal else s.prevCpuTotal
        prevCpuIdle := if nextCpuTotal > 0 then nextCpuIdle else s.prevCpuIdle
        lastMetricsMonoMs := nowMono
        lastMetricsDetails := details
        lastMetricsSnap := out
        metricsHistory := keptHist })
  return snap

private def appendDiagnosticsLines (st : LocaldState) (lines : Array String) : IO Unit := do
  let some logsDir := logsDirPath? st | return ()
  if lines.isEmpty then return ()
  try
    IO.FS.createDirAll logsDir
    let _ ← OrbBin.PosixExt.chmod logsDir.toString 0o700
    let epoch ← OrbBin.PosixExt.nowEpoch
    let logFile := logsDir / s!"orb-{formatUtcYmd epoch}.jsonl"
    let existingSize ← try
      let m ← logFile.metadata
      pure m.byteSize.toNat
    catch _ => pure 0
    if existingSize ≥ 20 * 1024 * 1024 then return ()
    let h ← IO.FS.Handle.mk logFile .append
    for line in lines do
      if line.utf8ByteSize ≤ 16384 && !(line.contains '\n') && !(line.contains '\r') then
        h.putStr (line ++ "\n")
    h.flush
  catch _ =>
    pure ()

private def ensureMachineId (stRef : IO.Ref LocaldState) : IO String := do
  let st ← stRef.get
  if !st.machineId.isEmpty then return st.machineId
  match resolveOrbStateDir st with
  | none =>
    let fallback ← randomUuidV4
    stRef.modify fun s => { s with machineId := fallback }
    return fallback
  | some dir =>
    let idFile := dir / "machine-id"
    let loaded? ← try
      if (← idFile.pathExists) then
        let txt := (← IO.FS.readFile idFile).trimAscii.toString
        pure (if txt.isEmpty then none else some txt)
      else pure none
    catch _ => pure none
    match loaded? with
    | some mid =>
      stRef.modify fun s => { s with machineId := mid }
      return mid
    | none =>
      let fresh ← randomUuidV4
      let _ ← OrbBin.PosixExt.writeAtomicPrivate0600 idFile (fresh ++ "\n").toUTF8
      stRef.modify fun s => { s with machineId := fresh }
      return fresh

private def canonicalizeExistingPath? (raw : String) : IO (Option String) := do
  let p := raw.trimAscii.toString
  if p.isEmpty || (p.splitOn "/").contains ".." then return none
  try
    let rp ← IO.FS.realPath (System.FilePath.mk p)
    let s := OrbBin.PosixExt.stripTrailingSlash rp.toString
    return some (if s.isEmpty then "/" else s)
  catch _ =>
    return none

private def isCanonicalWithinRoot (candReal rootReal : String) : Bool :=
  rootReal != "/" && !rootReal.isEmpty &&
  (candReal == rootReal || candReal.startsWith (if rootReal.endsWith "/" then rootReal else rootReal ++ "/"))

private def skippedUploadFolderNames : Array String :=
  #[".git", "node_modules", ".lake", "target", ".DS_Store", "__pycache__", ".venv", ".next", "dist"]

private partial def walkFolderForUploadAux (rootCanon : String) (depth : Nat)
    (dirFp : System.FilePath) (relPrefix : String)
    (acc : Array (String × String × String × Nat)) : IO (Array (String × String × String × Nat)) := do
  if depth > 64 || acc.size ≥ 4096 then
    return acc
  let rawEntries ← try dirFp.readDir catch _ => pure #[]
  let entries := rawEntries.qsort (fun a b => a.fileName < b.fileName)
  let mut out := acc
  for entry in entries do
    if out.size ≥ 4096 then break
    let name := entry.fileName
    if skippedUploadFolderNames.contains name then
      continue
    let st ← OrbBin.PosixExt.statPath entry.path.toString
    if !st.exists_ || st.isSymlink then
      continue
    if st.isDir then
      out ← walkFolderForUploadAux rootCanon (depth + 1) entry.path s!"{relPrefix}/{name}" out
    else if st.isReg then
      if let some fpReal ← canonicalizeExistingPath? entry.path.toString then
        if isCanonicalWithinRoot fpReal rootCanon then
          let idSt ← OrbBin.PosixExt.statIdentity fpReal false
          out := out.push (name, fpReal, s!"{relPrefix}/{name}", idSt.size.toNat)
  return out

private def walkFolderForUpload (rootCanon : String) (displayName? : Option String := none) :
    IO (Array (String × String × String × Nat)) := do
  let baseName :=
    match displayName? with
    | some n => if n.isEmpty then ((System.FilePath.mk rootCanon).fileName.getD "Folder") else n
    | none => (System.FilePath.mk rootCanon).fileName.getD "Folder"
  walkFolderForUploadAux rootCanon 0 (System.FilePath.mk rootCanon) baseName #[]

private def checkCanonicalUploadRead (st : LocaldState) (rawPath : String) : IO (Option System.FilePath) := do
  let p := rawPath.trimAscii.toString
  if p.isEmpty || !p.startsWith "/" || (p.splitOn "/").contains ".." then
    return none
  let lstat ← OrbBin.PosixExt.statPath p
  if !lstat.exists_ || !lstat.isReg || lstat.isSymlink then
    return none
  let some candReal ← canonicalizeExistingPath? p | return none
  if st.grantedUploadFiles.contains candReal then
    return some (System.FilePath.mk candReal)
  if st.grantedUploadBatches.any (fun (_, files) => files.contains candReal) then
    return some (System.FilePath.mk candReal)
  for g in st.grantedFolders do
    if let some rootReal ← canonicalizeExistingPath? g then
      if isCanonicalWithinRoot candReal rootReal then
        return some (System.FilePath.mk candReal)
  return none

private def collectAllowedBrowseRoots (st : LocaldState) : IO (Array String) := do
  let mut rawRoots : Array String := st.grantedBrowseRoots ++ st.grantedFolders
  for (_, bval) in st.bindingsEntries do
    if let some cwd := bval.fieldStr? "cwd" then
      rawRoots := rawRoots.push cwd
  for orig in st.localOrigins do
    if !orig.workingDirectory.isEmpty && orig.workingDirectory != "." then
      rawRoots := rawRoots.push orig.workingDirectory
  if let some sdir := resolveOrbStateDir st then
    rawRoots := rawRoots.push (sdir / "local-workspaces").toString
    rawRoots := rawRoots.push (sdir / "project-context").toString
    rawRoots := rawRoots.push (sdir / "staged-uploads").toString
  if !st.homeDir.trimAscii.toString.isEmpty then
    let h := System.FilePath.mk st.homeDir.trimAscii.toString
    rawRoots := rawRoots.push (h / ".orb" / "local-workspaces").toString
  let mut canon : Array String := #[]
  for r in rawRoots do
    if let some rp ← canonicalizeExistingPath? r then
      if rp != "/" && !canon.contains rp then
        canon := canon.push rp
  return canon

private def checkCanonicalBrowseRoot (st : LocaldState) (rawRoot : String) : IO (Option String) := do
  let some rootReal ← canonicalizeExistingPath? rawRoot | return none
  if rootReal == "/" then return none
  let lstat ← OrbBin.PosixExt.statPath rootReal
  if !lstat.exists_ || !lstat.isDir then return none
  let allowed ← collectAllowedBrowseRoots st
  if allowed.any (fun ar => isCanonicalWithinRoot rootReal ar) then
    return some rootReal
  return none

def isSecretRelPath (rel : String) : Bool := Id.run do
  let norm := (rel.replace "\\" "/").toLower
  let parts := (norm.splitOn "/").filter (fun s => !s.isEmpty)
  let name := parts.getLast?.getD norm
  if parts.any (fun p => p == ".git" || p == ".ssh" || p == ".aws" || p == ".codex" || p == ".claude" || p == ".env" || p.startsWith ".env.") then
    return true
  return name == ".env" || name.startsWith ".env." || name.endsWith ".pem" || name.endsWith ".key" ||
    name == "id_rsa" || name.startsWith "id_rsa." || name.startsWith "id_ed25519" ||
    ((name.splitOn "credentials").length > 1) || name == "auth.json" || name == "secrets" ||
    name == "secrets.yaml" || name == "secrets.yml" || name == "secrets.json" ||
    name.endsWith ".p12" || name.endsWith ".pfx"

private def isSafeRelSubpath (rel : String) : Option String := Id.run do
  let norm := rel.replace "\\" "/"
  if norm.startsWith "/" then return none
  let parts := norm.splitOn "/"
  if parts.any (fun p => p == ".." || p.toList.any (fun c => c.toNat < 0x20 || c.toNat == 0x7F)) then
    return none
  let clean := parts.filter (fun p => !p.isEmpty && p != ".")
  if clean.isEmpty then return none
  return some (String.intercalate "/" clean)

private def sanitizeSlug (raw : String) : String :=
  let chars := raw.trimAscii.toString.toList.map fun c =>
    if ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9') || c == '-' || c == '_' || c == '.' then c
    else '-'
  let s := (String.ofList chars).trimAscii.toString
  if s.isEmpty || s == "." || s == ".." then "default" else (s.take 80).toString

/-! ### Persistent Local Voice Worker (`orb/voice/worker.py`) -/

private def supportedVoiceLanguages : Array String := #[
  "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"
]

private def pinnedVoiceModelRepo : String :=
  "MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit"

private def pinnedVoiceModelRevision : String :=
  "553445e84959f9ec3fcd43443bce75ea05c400f3"

private structure VoiceWorkerProc where
  pythonBin : String
  scriptPath : String
  nextReqId : Nat := 1
  stdinH    : IO.FS.Handle
  child     : IO.Process.Child { stdin := .null, stdout := .piped, stderr := .null }

initialize voiceWorkerMutex : Std.Mutex (Option VoiceWorkerProc) ← Std.Mutex.new none

private def stopVoiceWorkerProc (srv? : Option VoiceWorkerProc) : IO Unit := do
  if let some srv := srv? then
    try srv.child.kill catch _ => pure ()
    try discard <| srv.child.wait catch _ => pure ()

private def resolveVoiceHome (st : LocaldState) : System.FilePath :=
  if st.hostOs == "macos" && !st.homeDir.trimAscii.toString.isEmpty then
    System.FilePath.mk st.homeDir.trimAscii.toString / "Library" / "Application Support" / "Orb" / "voice"
  else if !st.orbStateDir.trimAscii.toString.isEmpty then
    System.FilePath.mk st.orbStateDir.trimAscii.toString / "voice"
  else
    System.FilePath.mk "/tmp/orb-voice"

private def resolveVoiceScriptPath? (st : LocaldState) : IO (Option String) := do
  if let some envScript ← OrbBin.PosixExt.getEnvNonEmpty "ORB_VOICE_WORKER" then
    if (← System.FilePath.pathExists envScript) then return some envScript
  let appPath ← IO.appPath
  let mut cands : Array System.FilePath := #[
    System.FilePath.mk "orb/voice/worker.py",
    resolveVoiceHome st / "runtime" / "worker.py"
  ]
  if let some binDir := appPath.parent then
    cands := cands.push (binDir / ".." / "Resources" / "voice" / "worker.py")
    cands := cands.push (binDir / ".." / "share" / "orb-desktop" / "voice" / "worker.py")
    cands := cands.push (binDir / ".." / "voice" / "worker.py")
    cands := cands.push (binDir / ".." / ".." / ".." / ".." / "orb" / "voice" / "worker.py")
    cands := cands.push (binDir / ".." / ".." / ".." / "orb" / "voice" / "worker.py")
  for c in cands do
    if (← c.pathExists) then
      if let some rp ← canonicalizeExistingPath? c.toString then
        return some rp
      return some c.toString
  return none

private def resolveVoicePython? (st : LocaldState) (fakeMode : Bool) : IO (Option String) := do
  if let some envPy ← OrbBin.PosixExt.getEnvNonEmpty "ORB_VOICE_PYTHON" then
    if (← System.FilePath.pathExists envPy) then return some envPy
  let vhome := resolveVoiceHome st
  let mut cands : Array String := #[
    (vhome / ".venv" / "bin" / "python3").toString,
    (vhome / ".venv" / "bin" / "python").toString
  ]
  if !st.homeDir.trimAscii.toString.isEmpty then
    let h := System.FilePath.mk st.homeDir.trimAscii.toString
    cands := cands.push (h / ".orb" / "voice" / ".venv" / "bin" / "python3").toString
    cands := cands.push (h / ".orb" / "voice" / "venv" / "bin" / "python3").toString
  for c in cands do
    if (← System.FilePath.pathExists c) then
      return some c
  let hasLinuxCohere ← (OrbBin.PosixExt.getEnvNonEmpty "VOICED_COHERE_LIB").map Option.isSome
  if fakeMode || hasLinuxCohere then
    return (← resolveExecutableInPath? "python3" #[
      "/opt/homebrew/bin/python3",
      "/usr/bin/python3",
      "/usr/local/bin/python3",
      "/run/current-system/sw/bin/python3"
    ])
  return none

private def resolveVoiceModelDir (st : LocaldState) : IO String := do
  if let some envDir ← OrbBin.PosixExt.getEnvNonEmpty "ORB_VOICE_MODEL_DIR" then
    return envDir
  if let some hfCache ← OrbBin.PosixExt.getEnvNonEmpty "HF_HUB_CACHE" then
    return (System.FilePath.mk hfCache / "models--MarkChen1214--cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit" / "snapshots" / pinnedVoiceModelRevision).toString
  let home := if st.homeDir.trimAscii.toString.isEmpty then "/tmp" else st.homeDir.trimAscii.toString
  return (System.FilePath.mk home / ".cache" / "huggingface" / "hub" / "models--MarkChen1214--cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit" / "snapshots" / pinnedVoiceModelRevision).toString

private def isVoiceModelPresent (modelDir : String) : IO Bool := do
  let d := System.FilePath.mk modelDir
  return (← (d / "config.json").pathExists) && (← (d / "model.safetensors").pathExists)

private def detectHostArch : IO String := do
  match ← readSystemToolStdout? "uname" #["/usr/bin/uname", "/bin/uname", "/run/current-system/sw/bin/uname"] #["-m"] with
  | some a =>
    let clean := a.trimAscii.toString.toLower
    if clean == "arm64" || clean == "aarch64" then return "aarch64"
    return clean
  | none => return "unknown"

private def sendVoiceWorkerOp (st : LocaldState) (op : String) (extraFields : Array (String × JVal) := #[])
    (rawAudio : ByteArray := ByteArray.empty) : IO (Except String JVal) := do
  let fakeMode := ((← OrbBin.PosixExt.getEnvNonEmpty "ORB_VOICE_FAKE").getD "") == "1"
  let some scriptPath ← resolveVoiceScriptPath? st
    | return .error "python_missing: voice worker script not found"
  let some pyBin ← resolveVoicePython? st fakeMode
    | return .error "python_missing: Voice runtime not installed"
  let modelDir ← resolveVoiceModelDir st
  if !fakeMode && !(← isVoiceModelPresent modelDir) && (op == "load" || op == "transcribe") then
    return .error "model_missing: Speech model not downloaded"
  voiceWorkerMutex.atomically do
    let mut cur ← get
    if let some existing := cur then
      if existing.pythonBin != pyBin || existing.scriptPath != scriptPath then
        stopVoiceWorkerProc (some existing)
        cur := none
      else if (← try existing.child.tryWait catch _ => pure (some 1)).isSome then
        stopVoiceWorkerProc (some existing)
        cur := none
    let srv ← match cur with
      | some s => pure s
      | none =>
        try
          let envPairs ← OrbBin.PosixExt.currentEnvPairs
          let mut childEnv : Array (String × Option String) := envPairs.map fun (k, v) => (k, some v)
          childEnv := childEnv.push ("ORB_VOICE_MODEL_DIR", some modelDir)
          if fakeMode then
            childEnv := childEnv.push ("ORB_VOICE_FAKE", some "1")
          let rawChild ← IO.Process.spawn {
            cmd := pyBin
            args := #[scriptPath]
            env := childEnv
            stdin := .piped
            stdout := .piped
            stderr := .null
          }
          let (stdinH, child) ← rawChild.takeStdin
          let fresh : VoiceWorkerProc := { pythonBin := pyBin, scriptPath := scriptPath, nextReqId := 1, stdinH := stdinH, child := child }
          set (some fresh)
          pure fresh
        catch e =>
          set (none : Option VoiceWorkerProc)
          return .error s!"python_missing: {e}"
    let reqId := srv.nextReqId
    set (some { srv with nextReqId := reqId + 1 })
    let mut fields : Array (String × JVal) := #[("id", JVal.nat reqId), ("op", .str op)] ++ extraFields
    if !rawAudio.isEmpty then
      fields := fields.push ("audio_bytes", JVal.nat rawAudio.size)
    let hdrLine := renderCompact (.obj fields) ++ "\n"
    try
      srv.stdinH.putStr hdrLine
      if !rawAudio.isEmpty then
        srv.stdinH.write rawAudio
      srv.stdinH.flush
      let line ← srv.child.stdout.getLine
      let trimmed := line.trimAscii.toString
      if trimmed.isEmpty then
        let curNow ← get
        stopVoiceWorkerProc curNow
        set (none : Option VoiceWorkerProc)
        return .error "worker_exited"
      match OrbBin.Json.parse trimmed with
      | .error e =>
        let curNow ← get
        stopVoiceWorkerProc curNow
        set (none : Option VoiceWorkerProc)
        return .error s!"protocol: {e}"
      | .ok resp =>
        if (resp.fieldBool? "ok") == some true then
          return .ok ((resp.field? "result").getD (.obj #[]))
        else
          let errObj := (resp.field? "error").getD (.obj #[])
          let code := (errObj.fieldStr? "code").getD "error"
          let msg := (errObj.fieldStr? "message").getD "Voice worker error"
          return .error s!"{code}: {msg}"
    catch e =>
      let curNow ← get
      stopVoiceWorkerProc curNow
      set (none : Option VoiceWorkerProc)
      return .error s!"worker_exited: {e}"

private def cancelVoiceWorker : IO Bool := do
  voiceWorkerMutex.atomically do
    let cur ← get
    set (none : Option VoiceWorkerProc)
    match cur with
    | none => return false
    | some srv =>
      stopVoiceWorkerProc (some srv)
      return true

/-! ### Local CLI Agent Discovery, Execution & Skills Sync -/

private def candidateAgentBinDirs (homeDir : String) : Array String :=
  let h := homeDir.trimAscii.toString
  let userDirs :=
    if h.isEmpty then #[]
    else #[
      s!"{h}/.local/bin",
      s!"{h}/.opencode/bin",
      s!"{h}/.nix-profile/bin",
      s!"{h}/.local/state/nix/profile/bin",
      s!"{h}/.cargo/bin",
      s!"{h}/.bun/bin",
      s!"{h}/.npm-global/bin",
      s!"{h}/bin"
    ]
  userDirs ++ #["/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

private def resolveAgentExecutable? (homeDir : String) (binName : String) (override? : Option String) : IO (Option String) := do
  if let some ov := override? then
    let clean := ov.trimAscii.toString
    if !clean.isEmpty then
      let st ← OrbBin.PosixExt.statPath clean
      if st.exists_ && (st.isReg || st.isSymlink) then
        return some clean
      return none
  let pathEnv := ((← IO.getEnv "PATH").getD "").splitOn ":" |>.filter (fun s => !s.trimAscii.toString.isEmpty)
  let userEnv := ((← IO.getEnv "USER").getD "").trimAscii.toString
  let nixUserDirs := if userEnv.isEmpty then #[] else #[s!"/etc/profiles/per-user/{userEnv}/bin"]
  let searchDirs := pathEnv.toArray ++ nixUserDirs ++ candidateAgentBinDirs homeDir
  for d in searchDirs do
    let cand := (System.FilePath.mk d.trimAscii.toString / binName).toString
    if (← System.FilePath.pathExists cand) then
      let st ← OrbBin.PosixExt.statPath cand
      if st.exists_ && !st.isDir then
        return some cand
  return none

private def localHarnessSpecs : Array (String × String × String × Bool × String) := #[
  ("claudecode", "Claude Code", "claude", true, "npm install -g @anthropic-ai/claude-code"),
  ("codex", "Codex", "codex", false, "npm install -g @openai/codex"),
  ("grok", "Grok", "grok", false, "Install the Grok CLI in ~/.local/bin or /opt/homebrew/bin"),
  ("opencode", "OpenCode", "opencode", true, "curl -fsSL https://opencode.ai/install | bash"),
  ("antigravity", "Antigravity CLI", "agy", false, "Install Google Antigravity (`agy`)"),
  ("vibe", "Mistral Vibe", "vibe", true, "uv tool install mistral-vibe")
]

private def scanLocalAgents (st : LocaldState) (overridesObj : JVal) : IO (Array JVal) := do
  let tasks ← localHarnessSpecs.mapM fun (hid, _label, defaultBin, planSup, _instr) =>
    IO.asTask (prio := .dedicated) do
      let ov? := overridesObj.fieldStr? hid
      let resolved? ← resolveAgentExecutable? st.homeDir defaultBin ov?
      match resolved? with
      | none =>
        return JVal.obj #[
          ("id", .str hid),
          ("bin", .str defaultBin),
          ("path", .null),
          ("version", .null),
          ("installed", .bool false),
          ("plan_supported", .bool planSup)
        ]
      | some binPath =>
        let verOut? ← readCommandStdout? binPath #["--version"]
        let verFirst := verOut?.map fun v => ((v.splitOn "\n").head?.getD v).trimAscii.toString
        return JVal.obj #[
          ("id", .str hid),
          ("bin", .str defaultBin),
          ("path", .str binPath),
          ("version", match verFirst with | some v => (if v.isEmpty then .null else .str v) | none => .null),
          ("installed", .bool true),
          ("plan_supported", .bool planSup)
        ]
  let mut rows : Array JVal := Array.mkEmpty tasks.size
  for t in tasks do
    match t.get with
    | .ok row => rows := rows.push row
    | .error _ => pure ()
  return rows

/-! ### Local Skills Inspection & Sync (`local_skills_status` / `local_skills_sync`) -/

private def skillHarnessDisplayNames : Array (String × String) := #[
  ("claudecode", "Claude Code"),
  ("codex", "Codex"),
  ("antigravity", "Antigravity"),
  ("opencode", "OpenCode"),
  ("grok", "Grok"),
  ("vibe", "Mistral Vibe")
]

private def countLines (s : String) : Nat :=
  if s.isEmpty then 0 else (s.splitOn "\n").length

private def unquoteSkillYaml (raw : String) : String :=
  let v := raw.trimAscii.toString
  if v.length ≥ 2 && ((v.startsWith "\"" && v.endsWith "\"") || (v.startsWith "'" && v.endsWith "'")) then
    (((v.drop 1).dropEnd 1).toString).trimAscii.toString
  else
    v

/-- Parse `metadata.sandboxed.audience` and `metadata.sandboxed.scope` from `SKILL.md` YAML frontmatter. -/
private def parseSandboxedSkillMeta (markdown : String) : Option (Array String) × Option String := Id.run do
  let text := (markdown.replace "\r\n" "\n").replace "\uFEFF" ""
  if !text.startsWith "---\n" then
    return (none, none)
  let rest := (text.drop 4).toString
  let lines := rest.splitOn "\n"
  let mut yaml : Array String := #[]
  let mut closed := false
  for line in lines do
    if !closed then
      if line == "---" then closed := true
      else yaml := yaml.push line
  if !closed then
    return (none, none)
  let indentOf (s : String) : Nat := s.length - s.trimAsciiStart.toString.length
  let mut audience? : Option (Array String) := none
  let mut scope? : Option String := none
  let mut metaIndent? : Option Nat := none
  let mut sandIndent? : Option Nat := none
  let mut i : Nat := 0
  while i < yaml.size do
    let line := yaml[i]!
    let trimmed := line.trimAscii.toString
    if trimmed.isEmpty || trimmed.startsWith "#" then
      i := i + 1
      continue
    let ind := indentOf line
    if let some si := sandIndent? then
      if ind ≤ si then sandIndent? := none
    if let some mi := metaIndent? then
      if ind ≤ mi then
        metaIndent? := none
        sandIndent? := none
    if metaIndent?.isNone then
      if trimmed == "metadata:" then metaIndent? := some ind
      i := i + 1
      continue
    if sandIndent?.isNone then
      if trimmed == "sandboxed:" then sandIndent? := some ind
      i := i + 1
      continue
    if trimmed.startsWith "audience:" then
      let val := ((trimmed.drop 9).toString).trimAscii.toString
      if val.isEmpty then
        let mut items : Array String := #[]
        let mut j := i + 1
        while j < yaml.size do
          let t := yaml[j]!.trimAscii.toString
          if t.startsWith "-" then
            let item := unquoteSkillYaml ((t.drop 1).toString)
            if !item.isEmpty then items := items.push item
            j := j + 1
          else if t.isEmpty then
            j := j + 1
          else
            break
        audience? := some items
        i := j
        continue
      else
        let inner :=
          if val.startsWith "[" && val.endsWith "]" && val.length ≥ 2 then
            ((val.drop 1).dropEnd 1).toString
          else val
        let items := (inner.splitOn ",").toArray.filterMap fun part =>
          let u := unquoteSkillYaml part
          if u.isEmpty then none else some u
        audience? := some items
    else if trimmed.startsWith "scope:" then
      let v := unquoteSkillYaml ((trimmed.drop 6).toString)
      if !v.isEmpty then scope? := some v
    i := i + 1
  return (audience?, scope?)

private def effectiveSkillAudience (explicit? : Option (Array String)) (content : String) : Array String :=
  let raw := match explicit? with
    | some xs => xs
    | none => (parseSandboxedSkillMeta content).1.getD #["mission", "local"]
  raw.filterMap fun a =>
    let clean := a.trimAscii.toString.toLower
    if clean.isEmpty then none else some clean

private def isManagedSkillDir (dir : System.FilePath) : IO Bool := do
  if ← (dir / ".managed-by-orb-skills").pathExists then return true
  (dir / ".managed-by-agent-skills-repo").pathExists

private def normalizeSkillBody (s : String) : String :=
  ((s.replace "\r\n" "\n").replace "\uFEFF" "").trimAscii.toString

private structure CanonicalSkillEntry where
  name          : String
  content       : String
  files         : Array (String × String)
  copyDir?      : Option System.FilePath
  inLibrary     : Bool
  isIdentity    : Bool
  audience      : Array String
  scope?        : Option String
  desiredLocal  : Bool
  deriving Inhabited

private def buildCanonicalSkillCatalog (homeFp : System.FilePath) (libSkills : Array JVal) :
    IO (Array CanonicalSkillEntry × Bool) := do
  let mut entries : Array CanonicalSkillEntry := #[]
  for item in libSkills do
    if let some rawName := item.fieldStr? "name" then
      let name := rawName.trimAscii.toString
      let content := (item.fieldStr? "content").getD ""
      if validSkillIdentifier name && !content.trimAscii.toString.isEmpty then
        let explicitAud? := (item.fieldArr? "audience").map (fun xs => xs.filterMap (·.asStr?))
        let explicitScope? := (item.fieldStr? "scope").bind fun s =>
          let clean := s.trimAscii.toString
          if clean.isEmpty then none else some clean
        let (_, parsedScope?) := parseSandboxedSkillMeta content
        let aud := effectiveSkillAudience explicitAud? content
        let files := ((item.fieldArr? "files").getD #[]).filterMap fun rf => do
          let rel ← rf.fieldStr? "rel"
          return (rel, (rf.fieldStr? "content").getD "")
        let entry : CanonicalSkillEntry := {
          name := name
          content := content
          files := files
          copyDir? := none
          inLibrary := true
          isIdentity := false
          audience := aud
          scope? := explicitScope?.orElse (fun _ => parsedScope?)
          desiredLocal := aud.contains "local"
        }
        if let some idx := entries.findIdx? (fun e => e.name == name) then
          entries := entries.set! idx entry
        else
          entries := entries.push entry
  let idDir := homeFp / ".config" / "sandboxed-sh" / "development-identity" / "current" / "skill"
  let idMd := idDir / "SKILL.md"
  let idSt ← OrbBin.PosixExt.statPath idMd.toString
  let mut idReady := false
  if idSt.exists_ && idSt.isReg && !idSt.isSymlink then
    let idContent ← try IO.FS.readFile idMd catch _ => pure ""
    if !idContent.trimAscii.toString.isEmpty then
      idReady := true
      let (parsedAud?, parsedScope?) := parseSandboxedSkillMeta idContent
      let aud := effectiveSkillAudience parsedAud? idContent
      if let some idx := entries.findIdx? (fun e => e.name == "development-identity") then
        let prev := entries[idx]!
        -- Keep the provisioned machine-local `development-identity` mirror installed even offline,
        -- while letting an explicit Library payload stay canonical when connected.
        entries := entries.set! idx { prev with isIdentity := true, desiredLocal := true }
      else
        entries := entries.push {
          name := "development-identity"
          content := idContent
          files := #[]
          copyDir? := some idDir
          inLibrary := false
          isIdentity := true
          audience := aud
          scope? := parsedScope?
          desiredLocal := true
        }
  return (entries, idReady)

/-! ### Local Control-Plane MCP Provisioning (`~/.orb/mcp` + Local Harness MCP Configs) -/

private def localMcpDir (homeFp : System.FilePath) : System.FilePath :=
  homeFp / ".orb" / "mcp"

private def localMcpCredentialPath (homeFp : System.FilePath) : System.FilePath :=
  localMcpDir homeFp / "credential"

private def localMcpSessionMetaPath (homeFp : System.FilePath) : System.FilePath :=
  localMcpDir homeFp / "session.json"

private def isAllowedLocalMcpApiUrl (raw : String) : Bool :=
  let u := OrbBin.PosixExt.stripTrailingSlash raw.trimAscii.toString
  isSafeHttpUrl u &&
  (u.startsWith "https://" ||
   u == "http://127.0.0.1" || u.startsWith "http://127.0.0.1:" || u.startsWith "http://127.0.0.1/" ||
   u == "http://localhost" || u.startsWith "http://localhost:" || u.startsWith "http://localhost/" ||
   u == "http://[::1]" || u.startsWith "http://[::1]:" || u.startsWith "http://[::1]/")

private def localMcpRoleCode? (raw : String) : Option UInt8 :=
  match raw.trimAscii.toString.toLower with
  | "executor"    => some 0
  | "coordinator" => some 1
  | _             => none

private def harnessMcpConfigRel? (hid : String) : Option String :=
  match hid with
  | "claudecode"  => some ".claude.json"
  | "codex"       => some ".codex/config.toml"
  | "antigravity" => some ".gemini/config/mcp_config.json"
  | "opencode"    => some ".config/opencode/opencode.json"
  | _             => none

private def isHarnessMcpTargetPresent (homeFp : System.FilePath) (hid : String) : IO Bool := do
  match hid with
  | "claudecode"  =>
    if ← (homeFp / ".claude").pathExists then return true
    (homeFp / ".claude.json").pathExists
  | "codex"       => (homeFp / ".codex").pathExists
  | "antigravity" => (homeFp / ".gemini").pathExists
  | "opencode"    => (homeFp / ".config" / "opencode").pathExists
  | _             => pure false

private def isValidRegularNonSymlink (fp : System.FilePath) : IO Bool := do
  let st ← OrbBin.PosixExt.statPath fp.toString
  return st.exists_ && st.isReg && !st.isSymlink

private def resolveSandboxedMcpBin? (st : LocaldState) (homeFp : System.FilePath) : IO (Option String) := do
  if let some ov ← IO.getEnv "SANDBOXED_MCP_BIN" then
    let clean := ov.trimAscii.toString
    if !clean.isEmpty then
      let ovFp := System.FilePath.mk clean
      if ← isValidRegularNonSymlink ovFp then
        return some ovFp.toString
  let appPathStr ← try (·.toString) <$> IO.appPath catch _ => pure ""
  let sibling? : Option System.FilePath :=
    if appPathStr.isEmpty then none
    else ((System.FilePath.mk appPathStr).parent).map (· / "sandboxed-mcp")
  let candidates : Array System.FilePath :=
    if !st.homeDir.trimAscii.toString.isEmpty then
      let base := #[homeFp / ".local" / "bin" / "sandboxed-mcp"]
      match sibling? with | some sb => base.push sb | none => base
    else
      let appRootInstalled :=
        appPathStr.startsWith "/Applications/" ||
        appPathStr.startsWith "/usr/" ||
        appPathStr.startsWith (homeFp / "Applications").toString
      let sysPaths : Array System.FilePath := #[
        System.FilePath.mk "/Applications/Orb.app/Contents/MacOS/sandboxed-mcp",
        homeFp / ".local" / "bin" / "sandboxed-mcp",
        System.FilePath.mk "/usr/local/bin/sandboxed-mcp",
        System.FilePath.mk "/opt/homebrew/bin/sandboxed-mcp"
      ]
      match sibling? with
      | none => sysPaths
      | some sb => if appRootInstalled then #[sb] ++ sysPaths else sysPaths.push sb
  for cand in candidates do
    if ← isValidRegularNonSymlink cand then
      return some cand.toString
  return none

private structure LocalMcpCredentialState where
  ready         : Bool
  hasToken      : Bool
  storedApiUrl  : String
  targetApiUrl  : String
  sessionId?    : Option String
  role          : String
  hardExpiresAt : UInt64
  deriving Inhabited

private def persistLocalMcpSession (homeFp : System.FilePath) (sessObj : JVal) : IO (Except String Unit) := do
  let token := ((sessObj.fieldStr? "token").getD "").trimAscii.toString
  if !token.startsWith "mcp1." then
    return .error "External MCP credential must begin with `mcp1.`"
  let apiUrl := normalizeEndpointKey ((sessObj.fieldStr? "api_url").getD "")
  if !isAllowedLocalMcpApiUrl apiUrl then
    return .error "External MCP session requires an HTTPS or loopback Core URL"
  let roleStr := (((sessObj.fieldStr? "role").getD "coordinator").trimAscii.toString).toLower
  if (localMcpRoleCode? roleStr).isNone then
    return .error "External MCP session role must be `coordinator` or `executor`"
  let expiresAt := (sessObj.fieldUInt64? "expires_at").getD 0
  let hardExpiresAt := (sessObj.fieldUInt64? "hard_expires_at").getD expiresAt
  if hardExpiresAt == 0 then
    return .error "External MCP session is missing `hard_expires_at`"
  let sessionId? := (sessObj.fieldStr? "session_id").bind OrbBin.PosixExt.parseUuidCanonical?
  let dir := localMcpDir homeFp
  if let .error e ← OrbBin.PosixExt.ensurePrivateDir0700 dir then
    return .error e
  let credFp := localMcpCredentialPath homeFp
  if let .error e ← OrbBin.PosixExt.writeAtomicPrivate0600 credFp (token ++ "\n").toUTF8 then
    return .error e
  let metaJv : JVal := .obj #[
    ("api_url", .str apiUrl),
    ("session_id", match sessionId? with | some sid => .str sid | none => .null),
    ("role", .str roleStr),
    ("expires_at", JVal.uint64 expiresAt),
    ("hard_expires_at", JVal.uint64 hardExpiresAt)
  ]
  let metaFp := localMcpSessionMetaPath homeFp
  if let .error e ← OrbBin.PosixExt.writeAtomicPrivate0600 metaFp (OrbBin.Json.renderPretty metaJv ++ "\n").toUTF8 then
    return .error e
  return .ok ()

private def inspectLocalMcpCredential
    (homeFp : System.FilePath)
    (requestedApiUrl? : Option String) : IO LocalMcpCredentialState := do
  let nowSec ← OrbBin.PosixExt.nowEpoch
  let credFp := localMcpCredentialPath homeFp
  let metaFp := localMcpSessionMetaPath homeFp
  let credSt ← OrbBin.PosixExt.statPath credFp.toString
  let metaSt ← OrbBin.PosixExt.statPath metaFp.toString
  let credRaw ←
    if credSt.exists_ && credSt.isReg && !credSt.isSymlink then
      try IO.FS.readFile credFp catch _ => pure ""
    else pure ""
  let credTrim := credRaw.trimAscii.toString
  let hasPrefix := credTrim.startsWith "mcp1."
  let isPriv0600 : UInt8 :=
    if credSt.exists_ && credSt.isReg && !credSt.isSymlink && credSt.ownedByEuid &&
       (credSt.mode &&& 0o777) == 0o600 && hasPrefix && !metaSt.isSymlink then 1 else 0
  let metaJv : JVal ←
    if metaSt.exists_ && metaSt.isReg && !metaSt.isSymlink then
      let mraw ← try IO.FS.readFile metaFp catch _ => pure ""
      pure ((OrbBin.Json.parse mraw).toOption.getD (.obj #[]))
    else pure (.obj #[])
  let storedApi := normalizeEndpointKey ((metaJv.fieldStr? "api_url").getD "")
  let targetApi := match requestedApiUrl? with
    | some reqUrl => normalizeEndpointKey reqUrl
    | none        => storedApi
  let roleStr := (((metaJv.fieldStr? "role").getD "coordinator").trimAscii.toString).toLower
  let roleCode : UInt8 := (localMcpRoleCode? roleStr).getD 255
  let hardExp := (metaJv.fieldUInt64? "hard_expires_at").getD 0
  let sessionId? := (metaJv.fieldStr? "session_id").bind OrbBin.PosixExt.parseUuidCanonical?
  let sameEp : UInt8 :=
    if isAllowedLocalMcpApiUrl targetApi && !storedApi.isEmpty && storedApi == targetApi then 1 else 0
  let gateOk :=
    OrbLocald.Spec.verifyLocalMcpCredentialReuse isPriv0600 sameEp roleCode nowSec hardExp == 1
  return {
    ready := gateOk
    hasToken := hasPrefix
    storedApiUrl := storedApi
    targetApiUrl := targetApi
    sessionId? := sessionId?
    role := if roleCode == 0 then "executor" else "coordinator"
    hardExpiresAt := hardExp
  }

private def expectedLocalMcpArgs (apiUrl : String) (credPath : System.FilePath) (role : String) : Array String :=
  #["--api-url", apiUrl, "--token-file", credPath.toString, "--profile", role]

private def isOrbManagedMcpCommand (cmdStr : String) : Bool :=
  let clean := cmdStr.trimAscii.toString
  clean == "sandboxed-mcp" || clean.endsWith "/sandboxed-mcp" || clean.endsWith "\\sandboxed-mcp"

private def renderCodexSandboxedTomlBlock (binPath : String) (srvArgs : Array String) : Array String :=
  let argsRendered := "[" ++ String.intercalate ", " (srvArgs.toList.map OrbBin.Json.escapeJsonString) ++ "]"
  #[
    "[mcp_servers.sandboxed]",
    s!"command = {OrbBin.Json.escapeJsonString binPath}",
    s!"args = {argsRendered}",
    "startup_timeout_sec = 30",
    "tool_timeout_sec = 60",
    "enabled = true"
  ]

private def isTomlSectionHeader (line : String) : Bool :=
  let t := line.trimAscii.toString
  t.startsWith "[" && t.endsWith "]" && !(t.contains '=')

private def trimTrailingEmptyLines (xs : Array String) : Array String := Id.run do
  let mut endIdx := xs.size
  while endIdx > 0 && xs[endIdx - 1]!.trimAscii.toString.isEmpty do
    endIdx := endIdx - 1
  return xs.extract 0 endIdx

private def checkHarnessMcpSynced
    (homeFp : System.FilePath)
    (hid binPath : String)
    (srvArgs : Array String) : IO Bool := do
  let some rel := harnessMcpConfigRel? hid | return false
  let cfgFp := homeFp / rel
  let st ← OrbBin.PosixExt.statPath cfgFp.toString
  if !st.exists_ || !st.isReg || st.isSymlink then
    return false
  let raw ← try IO.FS.readFile cfgFp catch _ => return false
  if hid == "antigravity" || hid == "claudecode" then
    let .ok root := OrbBin.Json.parse raw | return false
    let expected := JVal.obj #[("command", .str binPath), ("args", .arr (srvArgs.map .str))]
    return ((root.field? "mcpServers").bind (·.field? "sandboxed")) == some expected
  else if hid == "opencode" then
    let .ok root := OrbBin.Json.parse raw | return false
    let some sb := (root.field? "mcp").bind (·.field? "sandboxed") | return false
    let wantCmd := (#[binPath] ++ srvArgs).map JVal.str
    return sb.fieldStr? "type" == some "local" &&
           sb.fieldBool? "enabled" == some true &&
           sb.field? "command" == some (.arr wantCmd)
  else if hid == "codex" then
    let norm := (raw.replace "\r\n" "\n").splitOn "\n" |>.toArray
    let some sIdx := norm.findIdx? (fun l => l.trimAscii.toString == "[mcp_servers.sandboxed]")
      | return false
    let mut eIdx := sIdx + 1
    while eIdx < norm.size && !isTomlSectionHeader norm[eIdx]! do
      eIdx := eIdx + 1
    let sec := trimTrailingEmptyLines (norm.extract sIdx eIdx)
    return sec == renderCodexSandboxedTomlBlock binPath srvArgs
  else
    return false

private def syncJsonMcpServersConfig
    (cfgFp : System.FilePath)
    (binPath : String)
    (srvArgs : Array String)
    (replaceUnmanaged : Bool) : IO Bool := do
  let st ← OrbBin.PosixExt.statPath cfgFp.toString
  if st.isSymlink then return false
  if let some p := cfgFp.parent then
    let pst ← OrbBin.PosixExt.statPath p.toString
    if pst.isSymlink then return false
  let existingRaw ←
    if st.exists_ && st.isReg then
      try IO.FS.readFile cfgFp catch _ => return false
    else pure ""
  let trimmed := existingRaw.trimAscii.toString
  let root ←
    if trimmed.isEmpty then
      pure (JVal.obj #[])
    else
      match OrbBin.Json.parse trimmed with
      | .ok v =>
        if v.asObj?.isSome then pure v else return false
      | .error _ => return false
  let servers ←
    match root.field? "mcpServers" with
    | none => pure (JVal.obj #[])
    | some sv =>
      if sv.asObj?.isSome then pure sv else return false
  let desired := JVal.obj #[("command", .str binPath), ("args", .arr (srvArgs.map .str))]
  if let some cur := servers.field? "sandboxed" then
    if cur == desired then return true
    let curCmd := (cur.fieldStr? "command").getD ""
    if !replaceUnmanaged && !isOrbManagedMcpCommand curCmd then
      return false
  let updated := root.setField "mcpServers" (servers.setField "sandboxed" desired)
  let rendered := (OrbBin.Json.renderPretty updated ++ "\n").toUTF8
  match ← OrbBin.PosixExt.writeAtomicPrivate0600 cfgFp rendered with
  | .ok () => return true
  | .error _ => return false

private def syncOpenCodeMcpConfig
    (cfgFp : System.FilePath)
    (binPath : String)
    (srvArgs : Array String)
    (replaceUnmanaged : Bool) : IO Bool := do
  let st ← OrbBin.PosixExt.statPath cfgFp.toString
  if st.isSymlink then return false
  if let some p := cfgFp.parent then
    let pst ← OrbBin.PosixExt.statPath p.toString
    if pst.isSymlink then return false
  let existingRaw ←
    if st.exists_ && st.isReg then
      try IO.FS.readFile cfgFp catch _ => return false
    else pure ""
  let trimmed := existingRaw.trimAscii.toString
  let root ←
    if trimmed.isEmpty then
      pure (JVal.obj #[])
    else
      match OrbBin.Json.parse trimmed with
      | .ok v =>
        if v.asObj?.isSome then pure v else return false
      | .error _ => return false
  let mcpObj ←
    match root.field? "mcp" with
    | none => pure (JVal.obj #[])
    | some mv =>
      if mv.asObj?.isSome then pure mv else return false
  let cmdArr := (#[binPath] ++ srvArgs).map JVal.str
  let desired := JVal.obj #[
    ("type", .str "local"),
    ("command", .arr cmdArr),
    ("enabled", .bool true),
    ("timeout", JVal.nat 60000)
  ]
  if let some cur := mcpObj.field? "sandboxed" then
    if cur == desired then return true
    let curCmd0 := match cur.fieldArr? "command" with
      | some xs => (xs[0]?.bind (·.asStr?)).getD ""
      | none    => (cur.fieldStr? "command").getD ""
    if !replaceUnmanaged && !isOrbManagedMcpCommand curCmd0 then
      return false
  let updated := root.setField "mcp" (mcpObj.setField "sandboxed" desired)
  let rendered := (OrbBin.Json.renderPretty updated ++ "\n").toUTF8
  match ← OrbBin.PosixExt.writeAtomicPrivate0600 cfgFp rendered with
  | .ok () => return true
  | .error _ => return false

private def syncCodexMcpConfig
    (cfgFp : System.FilePath)
    (binPath : String)
    (srvArgs : Array String)
    (replaceUnmanaged : Bool) : IO Bool := do
  let st ← OrbBin.PosixExt.statPath cfgFp.toString
  if st.isSymlink then return false
  if let some p := cfgFp.parent then
    let pst ← OrbBin.PosixExt.statPath p.toString
    if pst.isSymlink then return false
  let existingRaw ←
    if st.exists_ && st.isReg then
      try IO.FS.readFile cfgFp catch _ => return false
    else pure ""
  let desiredBlock := renderCodexSandboxedTomlBlock binPath srvArgs
  let normLines :=
    if existingRaw.trimAscii.toString.isEmpty then (#[] : Array String)
    else (existingRaw.replace "\r\n" "\n").splitOn "\n" |>.toArray
  let rebuilt : Array String ←
    match normLines.findIdx? (fun l => l.trimAscii.toString == "[mcp_servers.sandboxed]") with
    | none =>
      let base := trimTrailingEmptyLines normLines
      pure (if base.isEmpty then desiredBlock else base ++ #[""] ++ desiredBlock)
    | some sIdx =>
      let mut eIdx := sIdx + 1
      while eIdx < normLines.size && !isTomlSectionHeader normLines[eIdx]! do
        eIdx := eIdx + 1
      let curSec := trimTrailingEmptyLines (normLines.extract sIdx eIdx)
      if curSec == desiredBlock then
        return true
      let hasCmdLine := curSec.any (fun l => l.trimAscii.toString.startsWith "command")
      let mentionsSandboxedMcp := curSec.any (fun l => (l.splitOn "sandboxed-mcp").length > 1)
      if !replaceUnmanaged && hasCmdLine && !mentionsSandboxedMcp then
        return false
      let pfx := trimTrailingEmptyLines (normLines.extract 0 sIdx)
      let sfx := normLines.extract eIdx normLines.size
      let head := if pfx.isEmpty then desiredBlock else pfx ++ #[""] ++ desiredBlock
      pure (if sfx.isEmpty then head else head ++ #[""] ++ sfx)
  let rendered := (String.intercalate "\n" rebuilt.toList ++ "\n").toUTF8
  match ← OrbBin.PosixExt.writeAtomicPrivate0600 cfgFp rendered with
  | .ok () => return true
  | .error _ => return false

private def syncLocalHarnessesMcp
    (homeFp : System.FilePath)
    (binPath apiUrl role : String)
    (replaceUnmanaged : Bool) : IO (Array String) := do
  let credFp := localMcpCredentialPath homeFp
  let srvArgs := expectedLocalMcpArgs apiUrl credFp role
  let mut synced : Array String := #[]
  for hid in #["claudecode", "codex", "antigravity", "opencode"] do
    if ← isHarnessMcpTargetPresent homeFp hid then
      if let some rel := harnessMcpConfigRel? hid then
        let cfgFp := homeFp / rel
        let ok ←
          if hid == "antigravity" || hid == "claudecode" then
            syncJsonMcpServersConfig cfgFp binPath srvArgs replaceUnmanaged
          else if hid == "opencode" then
            syncOpenCodeMcpConfig cfgFp binPath srvArgs replaceUnmanaged
          else if hid == "codex" then
            syncCodexMcpConfig cfgFp binPath srvArgs replaceUnmanaged
          else pure false
        if ok then synced := synced.push hid
  return synced

private def buildLocalSkillsReport
    (st : LocaldState)
    (libSkills : Array JVal)
    (requestedApiUrl? : Option String := none) : IO JVal := do
  let checkedAt := (← OrbBin.PosixExt.nowEpoch).toNat * 1000
  let envHome := (← IO.getEnv "HOME").getD "/tmp"
  let homeStr := if st.homeDir.trimAscii.toString.isEmpty then envHome else st.homeDir
  let homeFp := System.FilePath.mk homeStr
  let pyVerRaw? ← readCommandStdout? "python3" #["--version"]
  let pyVer? := pyVerRaw?.map fun v =>
    let clean := v.trimAscii.toString
    if clean.startsWith "Python " then ((clean.drop 7).toString).trimAscii.toString else clean
  let receiptFp := homeFp / ".config" / "sandboxed-sh" / "development-identity" / "current" / "receipt.json"
  let receiptJson? : Option JVal ← if ← receiptFp.pathExists then
    let raw ← try IO.FS.readFile receiptFp catch _ => pure ""
    pure (OrbBin.Json.parse raw).toOption
  else pure none
  let idFingerprint? := receiptJson?.bind (·.fieldStr? "signing_fingerprint")
  let idUpdatedAt? := receiptJson?.bind (·.fieldNat? "created_at")
  let (catalog, idSkillExists) ← buildCanonicalSkillCatalog homeFp libSkills
  let sshKeyExists ← if st.homeDir.trimAscii.toString.isEmpty then pure false else (homeFp / ".ssh" / "paloma.pub").pathExists
  let idReady := (receiptJson?.isSome && idSkillExists) || sshKeyExists
  let preflight : JVal := .obj #[
    ("python3_ready", .bool pyVer?.isSome),
    ("python3_version", match pyVer? with | some v => .str v | none => .null),
    ("pyyaml_ready", .bool true),
    ("preflight_error", .null),
    ("identity_ready", .bool idReady),
    ("identity_fingerprint", match idFingerprint? with | some fp => .str fp | none => .null),
    ("identity_updated_at", match idUpdatedAt? with | some ts => JVal.nat ts | none => .null)
  ]
  let libraryKnown := !libSkills.isEmpty
  let desiredEntries := catalog.filter (·.desiredLocal)
  let idDir := homeFp / ".config" / "sandboxed-sh" / "development-identity" / "current" / "skill"
  let sourcesJson : Array JVal := #[
    .obj #[
      ("id", .str "development-identity"),
      ("label", .str "Development Identity"),
      ("path", .str idDir.toString),
      ("exists", .bool idSkillExists),
      ("skill_count", JVal.nat (if idSkillExists then 1 else 0)),
      ("legacy", .bool false)
    ]
  ]
  let mut harnessTargets : Array JVal := #[]
  let mcpBin? ← resolveSandboxedMcpBin? st homeFp
  let credSt ← inspectLocalMcpCredential homeFp requestedApiUrl?
  let mcpCredPath := localMcpCredentialPath homeFp
  let mcpExpectedArgs := expectedLocalMcpArgs credSt.targetApiUrl mcpCredPath credSt.role
  let mut mcpSyncedHarnesses : Array String := #[]
  let mut mcpMissingHarnesses : Array String := #[]
  -- `(name, desc?, harnesses, managed, preview?, staleHarnesses, editedCopy?, removedFromLib)`
  let mut discoveredMap : Array (String × Option String × Array String × Bool × Option String × Array String × Option (String × String × String) × Bool) := #[]
  for entry in catalog do
    let desc? := extractSkillDescription entry.content
    let prev := (entry.content.take 4000).toString
    discoveredMap := discoveredMap.push (entry.name, desc?, #[], false, some prev, #[], none, false)
  for (hid, hname) in skillHarnessDisplayNames do
    if let some (globalRel, projectRel) := harnessSkillTargets hid then
      let gdir := homeFp / globalRel
      let existsDir ← gdir.pathExists
      let entries ← if existsDir then (try gdir.readDir catch _ => pure #[]) else pure #[]
      let mut skillCount := 0
      let mut syncedCount := 0
      let mut presentNames : Array String := #[]
      let mut outdated : Array String := #[]
      let mut staleManaged : Array String := #[]
      for ent in entries do
        let sname := ent.fileName
        if validSkillIdentifier sname then
          let entSt ← OrbBin.PosixExt.statPath ent.path.toString
          let md := ent.path / "SKILL.md"
          let mst ← OrbBin.PosixExt.statPath md.toString
          if mst.exists_ && mst.isReg && !mst.isSymlink then
            skillCount := skillCount + 1
            presentNames := presentNames.push sname
            let content ← try IO.FS.readFile md catch _ => pure ""
            let isManaged ← if entSt.isSymlink then pure false else isManagedSkillDir ent.path
            let catEntry? := catalog.find? (fun e => e.name == sname)
            let mut staleHere := false
            let mut editHere? : Option (String × String × String) := none
            let mut removedHere := false
            match desiredEntries.find? (fun e => e.name == sname) with
            | some want =>
              if normalizeSkillBody content == normalizeSkillBody want.content then
                syncedCount := syncedCount + 1
              else
                outdated := outdated.push sname
                staleHere := true
                if !isManaged && want.inLibrary then
                  editHere? := some (hname, ent.path.toString, content)
            | none =>
              if isManaged then
                if libraryKnown then
                  staleManaged := staleManaged.push sname
                  if !(catEntry?.map (·.inLibrary) |>.getD false) && sname != "development-identity" then
                    removedHere := true
            let desc? := extractSkillDescription content
            let preview := (content.take 4000).toString
            if let some idx := discoveredMap.findIdx? (fun (dn, _, _, _, _, _, _, _) => dn == sname) then
              let (dn, dd, dhs, dm, dp, dstale, dedit, drem) := discoveredMap[idx]!
              let nextHarnesses := if dhs.contains hid then dhs else dhs.push hid
              let nextStale := if staleHere && !dstale.contains hid then dstale.push hid else dstale
              let nextEdit := dedit.orElse (fun _ => editHere?)
              discoveredMap := discoveredMap.set! idx (dn, dd.orElse (fun _ => desc?), nextHarnesses, dm || isManaged, dp.orElse (fun _ => some preview), nextStale, nextEdit, drem || removedHere)
            else
              let initStale := if staleHere then #[hid] else #[]
              discoveredMap := discoveredMap.push (sname, desc?, #[hid], isManaged, some preview, initStale, editHere?, removedHere)
      let missing := (desiredEntries.filterMap fun e =>
        if presentNames.contains e.name then none else some e.name).qsort (· < ·)
      let mcpRel? := harnessMcpConfigRel? hid
      let mcpSupported := mcpRel?.isSome
      let mcpTargetPresent ← if mcpSupported then isHarnessMcpTargetPresent homeFp hid else pure false
      let mcpSynced ←
        match mcpBin?, credSt.ready, mcpSupported with
        | some binPath, true, true => checkHarnessMcpSynced homeFp hid binPath mcpExpectedArgs
        | _, _, _                  => pure false
      if mcpSupported && mcpTargetPresent then
        if mcpSynced then
          mcpSyncedHarnesses := mcpSyncedHarnesses.push hid
        else
          mcpMissingHarnesses := mcpMissingHarnesses.push hid
      harnessTargets := harnessTargets.push (.obj #[
        ("id", .str hid),
        ("name", .str hname),
        ("global_rel", .str s!"~/{globalRel}"),
        ("global_path", .str gdir.toString),
        ("project_rel", .str projectRel),
        ("exists", .bool existsDir),
        ("skill_count", JVal.nat skillCount),
        ("synced_count", JVal.nat syncedCount),
        ("canonical_total", JVal.nat desiredEntries.size),
        ("missing_skills", .arr (missing.map .str)),
        ("outdated_skills", .arr ((outdated.qsort (· < ·)).map .str)),
        ("stale_managed", .arr ((staleManaged.qsort (· < ·)).map .str)),
        ("mcp_supported", .bool mcpSupported),
        ("mcp_config_rel", match mcpRel? with | some r => .str s!"~/{r}" | none => .null),
        ("mcp_synced", .bool mcpSynced)
      ])
  let skillsJson : Array JVal := (discoveredMap.qsort (fun a b => a.1 < b.1)).map fun (sname, desc?, hlist, managed, prev?, staleH, edit?, removed) =>
    let catEntry? := catalog.find? (fun e => e.name == sname)
    let inLib := catEntry?.map (·.inLibrary) |>.getD false
    let isDesired := catEntry?.map (·.desiredLocal) |>.getD false
    let isId := catEntry?.map (·.isIdentity) |>.getD false
    let aud := catEntry?.map (·.audience) |>.getD #[]
    let scope? := catEntry?.bind (·.scope?)
    let origin := if inLib then "Library" else if isId then "Development Identity" else "User global"
    let editedVal : JVal := match edit? with
      | some (eh, ep, ec) => .obj #[("harness", .str eh), ("path", .str ep), ("content", .str ec)]
      | none => .null
    let sourcesVal : Array JVal :=
      if isId then #[.obj #[
        ("id", .str "development-identity"),
        ("label", .str "Development Identity"),
        ("path", .str idDir.toString),
        ("legacy", .bool false),
        ("hash", .str ""),
        ("lines", JVal.nat (match prev? with | some p => countLines p | none => 0)),
        ("content", .null),
        ("files", .arr #[])
      ]] else #[]
    .obj #[
      ("name", .str sname),
      ("description", match desc? with | some d => .str d | none => .null),
      ("origin", .str origin),
      ("source_path", if isId && !inLib then .str idDir.toString else .null),
      ("harnesses", .arr (hlist.map .str)),
      ("managed", .bool managed),
      ("content_preview", match prev? with | some p => .str p | none => .null),
      ("sources", .arr sourcesVal),
      ("in_library", .bool inLib),
      ("desired", .bool isDesired),
      ("audience", .arr (aud.map .str)),
      ("scope", match scope? with | some sc => .str sc | none => .null),
      ("stale_harnesses", .arr (staleH.map .str)),
      ("removed_from_library", .bool removed),
      ("edited_copy", editedVal),
      ("lines", JVal.nat (match prev? with | some p => countLines p | none => 0))
    ]
  let mcpNeedsToken := mcpBin?.isSome && isAllowedLocalMcpApiUrl credSt.targetApiUrl && !credSt.ready
  let mcpJson : JVal := .obj #[
    ("ready", .bool (mcpBin?.isSome && credSt.ready)),
    ("needs_token", .bool mcpNeedsToken),
    ("binary_ready", .bool mcpBin?.isSome),
    ("binary_path", match mcpBin? with | some b => .str b | none => .null),
    ("credential_path", .str mcpCredPath.toString),
    ("api_url", if credSt.targetApiUrl.isEmpty then .null else .str credSt.targetApiUrl),
    ("session_id", match credSt.sessionId? with | some sid => .str sid | none => .null),
    ("role", .str credSt.role),
    ("hard_expires_at", if credSt.hardExpiresAt > 0 then JVal.uint64 credSt.hardExpiresAt else .null),
    ("synced_harnesses", .arr (mcpSyncedHarnesses.map .str)),
    ("missing_harnesses", .arr (mcpMissingHarnesses.map .str))
  ]
  return .obj #[
    ("checked_at", JVal.nat checkedAt),
    ("home_dir", .str homeStr),
    ("preflight", preflight),
    ("mcp", mcpJson),
    ("sources", .arr sourcesJson),
    ("harnesses", .arr harnessTargets),
    ("skills", .arr skillsJson),
    ("library_known", .bool libraryKnown)
  ]

/-! ### Loopback Desktop GitHub OAuth Listener (`github_oauth_sign_in`) -/

private def percentEncodeComponent (s : String) : String := Id.run do
  let hex := "0123456789ABCDEF".toList.toArray
  let mut out := ""
  for b in s.toUTF8 do
    let isUnreserved :=
      (0x41 ≤ b && b ≤ 0x5A) || (0x61 ≤ b && b ≤ 0x7A) || (0x30 ≤ b && b ≤ 0x39) ||
      b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
    if isUnreserved then
      out := out.push (Char.ofNat b.toNat)
    else
      let hi := hex[((b >>> 4) &&& 0x0F).toNat]!
      let lo := hex[(b &&& 0x0F).toNat]!
      out := out ++ "%" ++ String.ofList [hi, lo]
  return out

private def runGitHubDesktopOAuth (hostOs apiUrl : String) (state? : Option String) : IO (Except String JVal) := do
  let cleanBase := OrbBin.PosixExt.stripTrailingSlash apiUrl.trimAscii.toString
  if !isSafeHttpUrl cleanBase then
    return .error "Enter a valid http:// or https:// API URL first"
  let (listenFd, boundPort) ← match ← LeanSys.Posix.tcpListen "127.0.0.1" 0 4 with
    | .ok pair => pure pair
    | .error e => return .error s!"Could not start local sign-in listener: {e}"
  try
    let redirectUri := s!"http://127.0.0.1:{boundPort}/auth/callback"
    let mut startUrl := s!"{cleanBase}/api/auth/github/start?redirect={percentEncodeComponent redirectUri}"
    if let some stVal := state? then
      if !stVal.trimAscii.toString.isEmpty then
        startUrl := startUrl ++ s!"&state={percentEncodeComponent stVal.trimAscii.toString}"
    if let .error e ← runDetachedOpen hostOs #[startUrl] then
      return .error s!"Could not open browser for GitHub sign-in: {e}"
    let t0 ← IO.monoMsNow
    let deadlineMs : Nat := 180000
    let mut callbackUrl? : Option String := none
    while callbackUrl?.isNone && (← IO.monoMsNow) - t0 < deadlineMs do
      match ← LeanSys.Posix.tcpAcceptPoll listenFd 250 with
      | .error _ => pure ()
      | .ok cfd =>
        try
          match ← LeanSys.Http.readHttpRequestFromFd cfd none 5000 with
          | .error _ => pure ()
          | .ok req =>
            if req.path.startsWith "/auth/callback" then
              let html :=
                "<!doctype html><html><head><meta charset=\"utf-8\"><title>Orb Sign-In</title>" ++
                "<style>body{font-family:-apple-system,system-ui,sans-serif;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0}</style></head>" ++
                "<body><div><h2>Signed in to Orb</h2><p>You can close this tab and return to Orb.</p></div></body></html>"
              let body := html.toUTF8
              let head :=
                s!"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.size}\r\nConnection: close\r\n\r\n"
              discard <| LeanSys.Posix.writeAll cfd (head.toUTF8 ++ body) false
              callbackUrl? := some s!"http://127.0.0.1:{boundPort}{req.path}"
            else
              let head := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
              discard <| LeanSys.Posix.writeAll cfd head.toUTF8 false
        finally
          discard <| LeanSys.Posix.closeFd cfd
    match callbackUrl? with
    | some u => return .ok (.str u)
    | none => return .error "GitHub sign-in timed out before completing in the browser."
  finally
    discard <| LeanSys.Posix.closeFd listenFd

/-- Parse an origin URL (`https://host[:port][/pfx]` or bracketed IPv6 `https://[::1][:port][/pfx]`)
    into `(isTls, bareHost, port, pathPrefix)`. -/
def parseOriginHostPort (raw : String) : Option (Bool × String × UInt16 × String) :=
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
    if hostPort.startsWith "[" then
      match hostPort.splitOn "]" with
      | [brack, afterBrack] =>
        let ipv6 := (brack.drop 1).toString
        if !ipv6.contains ':' || !OrbNetLeaf.TlsHttp.isValidBareHost ipv6 then none
        else if afterBrack.isEmpty then
          some (isTls, ipv6, defPort, pfx)
        else if afterBrack.startsWith ":" then
          match LeanSys.Http.parseStrictContentLength? (afterBrack.drop 1).toString with
          | some p => if 1 ≤ p && p ≤ 65535 then some (isTls, ipv6, p.toUInt16, pfx) else none
          | none => none
        else none
      | _ => none
    else
      match hostPort.splitOn ":" with
      | [h] =>
        if !OrbNetLeaf.TlsHttp.isValidBareHost h then none
        else some (isTls, h, defPort, pfx)
      | [h, pStr] =>
        if !OrbNetLeaf.TlsHttp.isValidBareHost h then none
        else
          match LeanSys.Http.parseStrictContentLength? pStr with
          | some p => if 1 ≤ p && p ≤ 65535 then some (isTls, h, p.toUInt16, pfx) else none
          | none => none
      | _ => none

/-- Synchronize a `LocalOriginEntry` snapshot (`sequence = 1` at launch, `sequence = 2+` at completion)
    to Core's `POST /api/control/local-origins` endpoint so Turn 2+ follow-ups, `/btw`, and mobile clients
    observe local-origin missions without blocking local launch latency. -/
private def syncLocalOriginToCore (stRef : IO.Ref LocaldState) (missionId : String) (apiUrlRaw : String) (tokenRaw : String) : Nat → IO Unit
  | 0 => pure ()
  | remainingPasses + 1 => do
  let tok := tokenRaw.trimAscii.toString
  let apiUrl := apiUrlRaw.trimAscii.toString
  let normEp := normalizeEndpointKey apiUrl
  if tok.isEmpty || missionId.isEmpty || !apiUrl.startsWith "https://" then
    return ()
  let clientUuid ← ensureMachineId stRef
  let fallbackRunUuid ← randomUuidV4
  let claimedRow? ← stRef.modifyGet fun s =>
    if s.syncingOriginIds.contains missionId || s.unsupportedOriginSyncEndpoints.contains normEp then
      (none, s)
    else
      match s.localOrigins.find? (fun r => r.id == missionId) with
      | none => (none, s)
      | some r0 =>
        if !r0.localSyncPending || r0.ackedSeq >= r0.syncSeq then
          (none, s)
        else if r0.project.trimAscii.toString.isEmpty then
          let nextRows := s.localOrigins.map fun r =>
            if r.id == missionId && !r.syncLocalOnly then { r with syncLocalOnly := true, syncError := none } else r
          (none, { s with localOrigins := nextRows })
        else
          let assignedRunId := if r0.runId.isEmpty then fallbackRunUuid else r0.runId
          let rClaimed := { r0 with runId := assignedRunId }
          let nextRows := s.localOrigins.map fun r => if r.id == missionId then rClaimed else r
          (some rClaimed, { s with localOrigins := nextRows, syncingOriginIds := s.syncingOriginIds.push missionId })
  let some row := claimedRow?
    | return ()
  let mut shouldRetryNext := false
  try
    let st ← stRef.get
    let runUuid := row.runId
    let cleanFolder := ((row.folder.getD "").trimAscii.toString.dropWhile (· == '/')).dropEndWhile (· == '/') |>.toString
    let folderTags := row.tags.filter (fun t => t.startsWith "orb-folder:" && t.length ≤ 1024)
    let validEffort? : Option String :=
      match row.modelEffort with
      | none => none
      | some eff =>
        let ok :=
          if row.backend == "antigravity" then eff == "low" || eff == "medium" || eff == "high"
          else if row.backend == "codex" || row.backend == "claudecode" then
            eff == "low" || eff == "medium" || eff == "high" || eff == "xhigh" || eff == "max"
          else false
        if ok then some eff else none
    let mut originFields : Array (String × JVal) := #[
      ("id", .str row.id),
      ("run_id", .str runUuid),
      ("client_id", .str clientUuid),
      ("title", .str row.title),
      ("project", .str row.project),
      ("folder", .str cleanFolder),
      ("backend", .str row.backend),
      ("model", match row.modelOverride with | some m => (if m.isEmpty then .null else .str m) | none => .null),
      ("cwd", .str row.workingDirectory),
      ("prompt", .str (if row.rawPrompt.isEmpty then row.deliveredPrompt else row.rawPrompt)),
      ("created_at", .str (if row.createdAt.isEmpty then "1970-01-01T00:00:00Z" else row.createdAt)),
      ("tags", .arr (folderTags.map .str))
    ]
    if let some eff := validEffort? then
      originFields := originFields.push ("effort", .str eff)
    if row.backend == "codex" then
      if let some stTier := row.serviceTier then
        if stTier == "flex" || stTier == "priority" then
          originFields := originFields.push ("service_tier", .str stTier)
      if let some cy := row.cyberAccess then
        if !cy.isEmpty then
          originFields := originFields.push ("cyber_access", .str cy)
    let sentSeq := row.syncSeq
    let sentStatus :=
      if row.status == "active" || row.status == "awaiting_user" || row.status == "failed" || row.status == "interrupted" then
        row.status
      else
        "awaiting_user"
    let snapPayload : JVal := .obj #[
      ("origin", .obj originFields),
      ("sequence", JVal.uint64 sentSeq),
      ("text", .str row.syncText),
      ("status", .str sentStatus),
      ("error", match row.statusMessage with | some e => .str e | none => .null)
    ]
    let reqBody := (renderCompact snapPayload).toUTF8
    let reqHdrs : Array (String × String) := #[
      ("Authorization", s!"Bearer {tok}"),
      ("Content-Type", "application/json")
    ]
    let origins := candidateOriginsFor apiUrl
    let mut succeeded := false
    let mut rejected409 := false
    let mut unsupportedRoute := false
    let mut lastErr? : Option String := none
    for orig in origins do
      if !succeeded && !rejected409 && !unsupportedRoute then
        if let some (true, host, port, pfx) := parseOriginHostPort orig then
          let relPath := pfx ++ "/api/control/local-origins"
          let res ←
            match st.h2Pool? with
            | some pool =>
              match ← pool.request 1 "POST" host port relPath reqHdrs reqBody (2 * 1024 * 1024) true 8000 15000 with
              | .ok pooled => pure (.ok pooled.response)
              | .error e => pure (.error e)
            | none =>
              OrbNetLeaf.TlsHttp.httpsRequest "POST" host port relPath reqHdrs reqBody (2 * 1024 * 1024) true 15000
          match res with
          | .ok up =>
            if 200 ≤ up.status && up.status < 300 then
              succeeded := true
            else if up.status == 404 || up.status == 405 || up.status == 501 then
              unsupportedRoute := true
            else if up.status == 409 then
              rejected409 := true
              let det := ((String.fromUTF8? up.body).getD "").trimAscii.toString.take 240 |>.toString
              lastErr? := some s!"Core synchronization refused (409): {det}"
            else
              let det := ((String.fromUTF8? up.body).getD "").trimAscii.toString.take 240 |>.toString
              lastErr? := some s!"Core synchronization failed ({up.status}): {det}"
          | .error _ =>
            pure ()
    let notifyPayload : JVal := .obj #[("id", .str missionId)]
    if succeeded then
      let stUpd ← stRef.modifyGet fun s =>
        let nextRows := s.localOrigins.map fun r =>
          if r.id == missionId then
            let nextAck := if sentSeq > r.ackedSeq then sentSeq else r.ackedSeq
            let stillPending := r.localRunActive || nextAck < r.syncSeq
            { r with
              runId := if r.runId.isEmpty then runUuid else r.runId
              ackedSeq := nextAck
              localSyncPending := stillPending
              syncLocalOnly := false
              syncError := none }
          else r
        let s' := ({ s with localOrigins := nextRows }).enqueueNamedEvent "orb-local-origins-changed" notifyPayload
        (s', s')
      persistOriginsSnapshot stUpd
      let afterRow? := stUpd.localOrigins.find? (fun r => r.id == missionId)
      if let some ar := afterRow? then
        if ar.localSyncPending && ar.ackedSeq < ar.syncSeq then
          shouldRetryNext := true
    else if unsupportedRoute then
      let stUnsup ← stRef.modifyGet fun s =>
        let nextUnsup := if normEp.isEmpty || s.unsupportedOriginSyncEndpoints.contains normEp then s.unsupportedOriginSyncEndpoints else s.unsupportedOriginSyncEndpoints.push normEp
        let nextRows := s.localOrigins.map fun r =>
          if r.id == missionId || (!normEp.isEmpty && r.endpoint == normEp && r.localSyncPending) then
            { r with syncLocalOnly := true, syncError := none }
          else r
        let s' := ({ s with localOrigins := nextRows, unsupportedOriginSyncEndpoints := nextUnsup }).enqueueNamedEvent "orb-local-origins-changed" notifyPayload
        (s', s')
      persistOriginsSnapshot stUnsup
    else if rejected409 then
      let stRej ← stRef.modifyGet fun s =>
        let nextRows := s.localOrigins.map fun r =>
          if r.id == missionId then
            { r with
              localSyncPending := false
              syncError := lastErr?
              lastConflictCode := some "conflict_409"
              retryableConflict := false }
          else r
        let s' := ({ s with localOrigins := nextRows }).enqueueNamedEvent "orb-local-origins-changed" notifyPayload
        (s', s')
      persistOriginsSnapshot stRej
    else if let some em := lastErr? then
      let stErr ← stRef.modifyGet fun s =>
        let nextRows := s.localOrigins.map fun r =>
          if r.id == missionId then { r with syncError := some em } else r
        let s' := ({ s with localOrigins := nextRows }).enqueueNamedEvent "orb-local-origins-changed" notifyPayload
        (s', s')
      persistOriginsSnapshot stErr
  finally
    stRef.modify fun s => { s with syncingOriginIds := s.syncingOriginIds.filter (· != missionId) }
  if shouldRetryNext then
    syncLocalOriginToCore stRef missionId apiUrl tok remainingPasses

private def postCoreJson
    (st : LocaldState)
    (apiUrl : String)
    (tok : String)
    (subPath : String)
    (payload : JVal)
    (extraHdrs : Array (String × String) := #[])
    : IO (Except String (Nat × ByteArray)) := do
  let reqBody := (renderCompact payload).toUTF8
  let reqHdrs : Array (String × String) := #[
    ("Authorization", s!"Bearer {tok}"),
    ("Content-Type", "application/json")
  ] ++ extraHdrs
  let origins := candidateOriginsFor apiUrl
  let mut lastNetErr := "no candidate HTTPS origin"
  for orig in origins do
    if let some (true, host, port, pfx) := parseOriginHostPort orig then
      let relPath := pfx ++ subPath
      let res ←
        match st.h2Pool? with
        | some pool =>
          match ← pool.request 1 "POST" host port relPath reqHdrs reqBody (2 * 1024 * 1024) true 8000 15000 with
          | .ok pooled => pure (.ok pooled.response)
          | .error e => pure (.error e)
        | none =>
          OrbNetLeaf.TlsHttp.httpsRequest "POST" host port relPath reqHdrs reqBody (2 * 1024 * 1024) true 15000
      match res with
      | .ok up => return .ok (up.status, up.body)
      | .error e => lastNetErr := e
  return .error s!"error sending request ({subPath}): {lastNetErr}"

private def settleCoreClientRunReceipt
    (st : LocaldState)
    (missionId : String)
    (apiUrl : String)
    (tok : String)
    (runId : String)
    (gen : UInt64)
    : IO (Except String Unit) := do
  let settlePayload : JVal := .obj #[
    ("status", .str "interrupted"),
    ("run_id", .str runId),
    ("generation", JVal.uint64 gen)
  ]
  let idemHdr := #[("Idempotency-Key", s!"cstatus:{missionId}:{runId}:interrupted")]
  match ← postCoreJson st apiUrl tok s!"/api/control/missions/{missionId}/client-status" settlePayload idemHdr with
  | .error e => return .error e
  | .ok (setStatus, setBody) =>
    if 200 ≤ setStatus && setStatus < 300 then
      return .ok ()
    let det := ((String.fromUTF8? setBody).getD "").trimAscii.toString.take 240 |>.toString
    return .error s!"Could not reconcile previous run ({setStatus}): {det}"

/-- Inspect and settle any orphaned Core `client-run` receipt on this machine.
    Returns `.ok (some true)` when a receipt was settled, `.ok (some false)` when Core confirmed
    no active run on this machine, or `.ok none` when Core/mission does not use `client-run`. -/
private def reconcileCoreClientRunIfSupported
    (stRef : IO.Ref LocaldState)
    (missionId : String)
    (apiUrlRaw : String)
    (tokenRaw : String)
    : IO (Except String (Option Bool)) := do
  let tok := tokenRaw.trimAscii.toString
  let apiUrl := apiUrlRaw.trimAscii.toString
  if tok.isEmpty || missionId.isEmpty || !apiUrl.startsWith "https://" then
    return .ok none
  let st0 ← stRef.get
  let isUnsyncedLocal := st0.localOrigins.any fun r =>
    r.id == missionId && (r.localSyncPending || r.syncLocalOnly)
  if isUnsyncedLocal then
    return .ok none
  let clientUuid ← ensureMachineId stRef
  let st ← stRef.get
  let runSubPath := s!"/api/control/missions/{missionId}/client-run"
  let inspectPayload : JVal := .obj #[("op", .str "inspect"), ("client_id", .str clientUuid)]
  match ← postCoreJson st apiUrl tok runSubPath inspectPayload with
  | .error e => return .error e
  | .ok (inspStatus, inspBody) =>
    if inspStatus == 404 || inspStatus == 405 || inspStatus == 501 then
      return .ok none
    if 200 ≤ inspStatus && inspStatus < 300 then
      match parseBytes inspBody with
      | .error e => return .error s!"Invalid previous run receipt JSON: {e}"
      | .ok inspJv =>
        let some prevRunId := inspJv.fieldStr? "run_id"
          | return .error "Invalid previous run receipt"
        let some prevGen := inspJv.fieldUInt64? "generation"
          | return .error "Invalid previous run receipt"
        match ← settleCoreClientRunReceipt st missionId apiUrl tok prevRunId prevGen with
        | .error e => return .error e
        | .ok () => return .ok (some true)
    let det := ((String.fromUTF8? inspBody).getD "").trimAscii.toString.take 240 |>.toString
    if inspStatus == 409 && (det.splitOn "No active run on this computer").length > 1 then
      return .ok (some false)
    return .error s!"Could not inspect previous run ({inspStatus}): {det}"

private def beginCoreClientRunIfSupported
    (stRef : IO.Ref LocaldState)
    (missionId : String)
    (apiUrlRaw : String)
    (tokenRaw : String)
    (prompt : String)
    (cwd : String)
    (model : String)
    (svcTier? : Option String)
    (cyber : String)
    (sessionId? : Option String)
    : IO (Except String (Option (String × UInt64 × String))) := do
  match ← reconcileCoreClientRunIfSupported stRef missionId apiUrlRaw tokenRaw with
  | .error e => return .error e
  | .ok none => return .ok none
  | .ok (some _) =>
    let tok := tokenRaw.trimAscii.toString
    let apiUrl := apiUrlRaw.trimAscii.toString
    let clientUuid ← ensureMachineId stRef
    let st ← stRef.get
    let runSubPath := s!"/api/control/missions/{missionId}/client-run"
    let mut beginFields : Array (String × JVal) := #[
      ("op", .str "begin"),
      ("client_id", .str clientUuid),
      ("prompt", .str prompt),
      ("cwd", .str cwd),
      ("model", if model.isEmpty then .null else .str model),
      ("cyber_access", .str cyber)
    ]
    if let some stTier := svcTier? then
      if !stTier.trimAscii.toString.isEmpty then
        beginFields := beginFields.push ("service_tier", .str stTier)
    if let some sid := sessionId? then
      if !sid.trimAscii.toString.isEmpty then
        beginFields := beginFields.push ("session_id", .str sid)
    match ← postCoreJson st apiUrl tok runSubPath (.obj beginFields) with
    | .error e => return .error e
    | .ok (begStatus, begBody) =>
      if begStatus == 404 || begStatus == 405 || begStatus == 501 then
        return .ok none
      let det := ((String.fromUTF8? begBody).getD "").trimAscii.toString.take 240 |>.toString
      if begStatus == 409 then
        return .error s!"Local launch rejected: 409: {det}"
      if !(200 ≤ begStatus && begStatus < 300) then
        return .error s!"{begStatus}: {det}"
      match parseBytes begBody with
      | .error e => return .error s!"Invalid client-run receipt JSON: {e}"
      | .ok begJv =>
        let some coreRunId := begJv.fieldStr? "run_id"
          | return .error "Missing run identity in client-run receipt"
        let some coreGen := begJv.fieldUInt64? "generation"
          | return .error "Missing run generation in client-run receipt"
        let corePrompt := (begJv.fieldStr? "prompt").getD prompt
        return .ok (some (coreRunId, coreGen, corePrompt))

/-- Execute `local_machine_transfer` operations confined to a canonical workspace root. -/
private def handleLocalMachineTransfer (stRef : IO.Ref LocaldState) (args : JVal) : IO (Except String JVal) := do
  ensurePersistedBindingsLoaded stRef
  let st ← stRef.get
  let missionId := ((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "mission_id")).getD ""
  let transferId := ((args.fieldStr? "transferId").orElse (fun _ => args.fieldStr? "transfer_id")).getD "default"
  let side := (args.fieldStr? "side").getD "source"
  let opObj := (args.field? "operation").getD (.obj #[])
  let op := (opObj.fieldStr? "op").getD ""
  let resolveRoot : IO (Except String String) := do
    if side == "destination" then
      let baseDir : System.FilePath :=
        match resolveOrbStateDir st with
        | some d => d / "local-workspaces" / s!"transfer-{sanitizeSlug transferId}"
        | none =>
          let h := if st.homeDir.trimAscii.toString.isEmpty then "/tmp" else st.homeDir.trimAscii.toString
          System.FilePath.mk h / ".orb" / "local-workspaces" / s!"transfer-{sanitizeSlug transferId}"
      IO.FS.createDirAll baseDir
      match ← canonicalizeExistingPath? baseDir.toString with
      | some rp =>
        stRef.modify fun s =>
          if s.grantedBrowseRoots.contains rp then s else { s with grantedBrowseRoots := s.grantedBrowseRoots.push rp }
        return .ok rp
      | none => return .error "Could not resolve transfer destination workspace"
    else
      let cwd? := (st.bindingsEntries.find? (fun (k, _) => k == missionId)).bind (fun (_, bv) => bv.fieldStr? "cwd")
        |>.orElse (fun _ => (st.localOrigins.find? (fun o => o.id == missionId)).map (·.workingDirectory))
      let some rawCwd := cwd? | return .error "The source workspace is unavailable on this computer."
      match ← canonicalizeExistingPath? rawCwd with
      | some rp =>
        if rp == "/" then return .error "Refusing root filesystem in machine transfer"
        return .ok rp
      | none => return .error "Source workspace directory does not exist"
  let rootReal ← match ← resolveRoot with
    | .ok r => pure r
    | .error e => return .error e
  let rootFp := System.FilePath.mk rootReal
  let collectWorkspaceFiles : IO (Array (String × Nat × String × Bool) × Array JVal × Nat) := do
    let mut files : Array (String × Nat × String × Bool) := #[]
    let mut skipped : Array JVal := #[]
    let mut protectedCount : Nat := 0
    let mut stack : Array String := #[""]
    while !stack.isEmpty && files.size < 5000 do
      let relDir := stack.back!
      stack := stack.pop
      let curFp := if relDir.isEmpty then rootFp else rootFp / relDir
      let entries ← try curFp.readDir catch _ => pure #[]
      for ent in entries do
        let name := ent.fileName
        if !name.isEmpty && name != "." && name != ".." && name != "node_modules" && name != ".lake" && name != "target" then
          let relPath := if relDir.isEmpty then name else s!"{relDir}/{name}"
          if isSecretRelPath relPath then
            protectedCount := protectedCount + 1
            skipped := skipped.push (.obj #[("path", .str relPath), ("reason", .str "protected")])
          else
            let lst ← OrbBin.PosixExt.statPath ent.path.toString
            if lst.isSymlink then
              skipped := skipped.push (.obj #[("path", .str relPath), ("reason", .str "symlink")])
            else if lst.isDir then
              if let some subReal ← canonicalizeExistingPath? ent.path.toString then
                if isCanonicalWithinRoot subReal rootReal then
                  stack := stack.push relPath
            else if lst.isReg then
              if let some fReal ← canonicalizeExistingPath? ent.path.toString then
                if isCanonicalWithinRoot fReal rootReal then
                  let raw ← try IO.FS.readBinFile (System.FilePath.mk fReal) catch _ => pure ByteArray.empty
                  let sha := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes raw)
                  let exec := (lst.mode &&& 0o111) != 0
                  files := files.push (relPath, raw.size, sha, exec)
    let sorted := files.qsort (fun a b => a.1 < b.1)
    return (sorted, skipped, protectedCount)
  match op with
  | "inventory" =>
    let (files, _, protectedCount) ← collectWorkspaceFiles
    let totalBytes := files.foldl (fun acc (_, b, _, _) => acc + b) 0
    let rows : Array JVal := (files.take 200).map fun (p, b, _, _) =>
      .obj #[("path", .str p), ("folder", .bool false), ("state", .str "moved"), ("bytes", JVal.nat b), ("files", JVal.nat 1)]
    return .ok (.obj #[
      ("rows", .arr rows),
      ("bytes", JVal.nat totalBytes),
      ("files", JVal.nat files.size),
      ("truncated", .bool (files.size > 200)),
      ("protected", JVal.nat protectedCount),
      ("limits", .obj #[("bytes", JVal.nat (512 * 1024 * 1024)), ("files", JVal.nat 5000)])
    ])
  | "select" =>
    return .ok (.obj #[("ok", .bool true)])
  | "snapshot" =>
    let (files, skipped, _) ← collectWorkspaceFiles
    let totalBytes := files.foldl (fun acc (_, b, _, _) => acc + b) 0
    let filesJson : Array JVal := files.map fun (p, b, sha, exec) =>
      .obj #[("path", .str p), ("bytes", JVal.nat b), ("sha256", .str sha), ("executable", .bool exec)]
    return .ok (.obj #[
      ("files", .arr filesJson),
      ("excluded", .arr #[]),
      ("bytes", JVal.nat totalBytes),
      ("links", .arr #[]),
      ("skipped", .arr skipped)
    ])
  | "stage" =>
    let manifest := (opObj.field? "manifest").getD (.obj #[])
    let mfiles := (manifest.fieldArr? "files").getD #[]
    let mut received : Array (String × JVal) := #[]
    for mf in mfiles do
      if let some p := (mf.fieldStr? "path").bind isSafeRelSubpath then
        let fp := rootFp / p
        let lst ← OrbBin.PosixExt.statPath fp.toString
        if lst.exists_ && lst.isReg && !lst.isSymlink then
          let m ← try pure (some (← fp.metadata)) catch _ => pure none
          if let some meta_ := m then
            received := received.push (p, JVal.nat meta_.byteSize.toNat)
    let manifestBytes ← IO.FS.writeFile (rootFp / ".orb-transfer-manifest.json") (renderCompact manifest)
    let _ := manifestBytes
    return .ok (.obj #[("sealed", .bool false), ("received", .obj received)])
  | "read" =>
    let some rel := (opObj.fieldStr? "path").bind isSafeRelSubpath
      | return .error "Invalid transfer file path"
    let offset := (opObj.fieldNat? "offset").getD 0
    let target := rootFp / rel
    let lst ← OrbBin.PosixExt.statPath target.toString
    if !lst.exists_ || !lst.isReg || lst.isSymlink then
      return .error "Transfer source file missing or symlink"
    let some realTarget ← canonicalizeExistingPath? target.toString
      | return .error "Cannot canonicalize transfer source file"
    if !isCanonicalWithinRoot realTarget rootReal then
      return .error "Transfer source file escapes workspace root"
    let h ← IO.FS.Handle.mk (System.FilePath.mk realTarget) .read
    h.rewind
    let mut skipped : Nat := 0
    while skipped < offset do
      let step := min (offset - skipped) 1048576
      let chunk ← h.read step.toUSize
      if chunk.isEmpty then skipped := offset else skipped := skipped + chunk.size
    let block ← h.read (1048576 : USize)
    return .ok (.obj #[("data", .str (OrbBin.PosixExt.base64Encode block))])
  | "write" =>
    let some rel := (opObj.fieldStr? "path").bind isSafeRelSubpath
      | return .error "Invalid transfer write path"
    if isSecretRelPath rel then
      return .error "Refusing to write protected path"
    let offset := (opObj.fieldNat? "offset").getD 0
    let dataB64 := (opObj.fieldStr? "data").getD ""
    let some rawBytes := OrbBin.PosixExt.base64Decode? dataB64
      | return .error "Invalid base64 block in transfer write"
    let target := rootFp / rel
    if let some parent := target.parent then
      IO.FS.createDirAll parent
      let some parentReal ← canonicalizeExistingPath? parent.toString
        | return .error "Cannot resolve transfer destination directory"
      if !isCanonicalWithinRoot parentReal rootReal then
        return .error "Transfer destination parent escapes workspace root"
    let lst ← OrbBin.PosixExt.statPath target.toString
    if lst.isSymlink then
      return .error "Refusing to overwrite symlink in transfer destination"
    if offset == 0 || !lst.exists_ then
      IO.FS.writeBinFile target rawBytes
    else
      let existing ← IO.FS.readBinFile target
      let prefixBytes := if existing.size > offset then existing.extract 0 offset else existing
      IO.FS.writeBinFile target (prefixBytes ++ rawBytes)
    return .ok (.obj #[("written", JVal.nat rawBytes.size)])
  | "verify" =>
    let manifestPath := rootFp / ".orb-transfer-manifest.json"
    let mut totalBytes := 0
    let mut fileCount := 0
    let mut digestInput := ""
    if (← manifestPath.pathExists) then
      let mraw ← IO.FS.readFile manifestPath
      if let .ok mjv := OrbBin.Json.parse mraw then
        for mf in (mjv.fieldArr? "files").getD #[] do
          if let some rel := (mf.fieldStr? "path").bind isSafeRelSubpath then
            let expectedSha := (mf.fieldStr? "sha256").getD ""
            let exec := (mf.fieldBool? "executable").getD false
            let fp := rootFp / rel
            let lst ← OrbBin.PosixExt.statPath fp.toString
            if !lst.exists_ || !lst.isReg || lst.isSymlink then
              return .error s!"Missing transferred file: {rel}"
            let bytes ← IO.FS.readBinFile fp
            let actualSha := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes bytes)
            if !expectedSha.isEmpty && actualSha != expectedSha.toLower then
              return .error s!"Digest mismatch on transferred file: {rel}"
            if exec then
              discard <| OrbBin.PosixExt.chmod fp.toString 0o755
            totalBytes := totalBytes + bytes.size
            fileCount := fileCount + 1
            digestInput := digestInput ++ s!"{rel}:{actualSha}\n"
      try IO.FS.removeFile manifestPath catch _ => pure ()
    let digest := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes digestInput.toUTF8)
    return .ok (.obj #[
      ("root", .str rootReal),
      ("bytes", JVal.nat totalBytes),
      ("files", JVal.nat fileCount),
      ("digest", .str digest)
    ])
  | "check_source" =>
    return .ok (.obj #[("ok", .bool true), ("root", .str rootReal)])
  | _ =>
    return .error s!"Unsupported machine transfer operation: {op}"

/-- Pure/IO dispatcher for all desktop IPC commands plus internal `__orb_poll_events`. -/
def dispatchRpcCommand (stRef : IO.Ref LocaldState) (cmd : String) (args : JVal) : IO (Except String JVal) := do
  let st ← stRef.get
  match cmd with
  | "plugin:app|version" =>
    let ver := (← OrbBin.PosixExt.getEnvNonEmpty "ORB_APP_VERSION").getD "0.13.0"
    return .ok (.str ver)
  | "desktop_bootstrap" =>
    let shardCountU8 : UInt8 := UInt8.ofNat st.bridge.shardPorts.size
    if verifySseShardConfig shardCountU8 st.bridge.proxyPort != 1 ||
       !allShardPortsValid st.rpcPort st.bridge.proxyPort st.bridge.shardPorts then
      return .error "invalid SSE shard configuration"
    let connVal : JVal ← do
      match connectionFilePath? st with
      | none => pure st.connectionJson
      | some path =>
        if !(← path.pathExists) then pure st.connectionJson
        else
          try
            let raw ← IO.FS.readFile path
            match OrbBin.Json.parse raw.trimAscii.toString with
            | .ok jv =>
              stRef.modify fun s => { s with connectionJson := jv }
              pure jv
            | .error _ => pure st.connectionJson
          catch _ => pure st.connectionJson
    let sinceRev? := args.fieldStr? "since_rev"
    let prefsRes ← uiPrefsMutex.atomically do
      readUiPrefsFromDisk (uiPrefsFilePath? st)
    let prefsVal : JVal :=
      match prefsRes with
      | .error _ => .obj #[("unchanged", .bool false), ("rev", .str ""), ("exists", .bool false), ("prefs", .obj #[])]
      | .ok (prefsObj, rev, existed) =>
        if existed && sinceRev? == some rev then
          .obj #[("unchanged", .bool true), ("rev", .str rev), ("exists", .bool true)]
        else
          .obj #[("unchanged", .bool false), ("rev", .str rev), ("exists", .bool existed), ("prefs", prefsObj)]
    let explicitUrl := ((args.fieldStr? "apiUrl").orElse (fun _ => args.fieldStr? "api_url")).getD ""
    let savedUrl := ((connVal.fieldStr? "api_url").orElse (fun _ => connVal.fieldStr? "apiUrl")).getD ""
    let rawUrl := if !explicitUrl.trimAscii.toString.isEmpty then explicitUrl else savedUrl
    let cleanUrl := OrbBin.PosixExt.stripTrailingSlash rawUrl.trimAscii.toString
    let nextBridge ← stRef.modifyGet fun s =>
      if cleanUrl.startsWith "https://" && !(cleanUrl.toList.any (fun c => c.toNat ≤ 0x20 || c.toNat == 0x7F)) then
        let b := { s.bridge with configuredTarget := cleanUrl, failoverOrigins := candidateOriginsFor cleanUrl }
        (b, { s with bridge := b })
      else
        (s.bridge, s)
    if let some pool := st.h2Pool? then
      if let some primaryOrig := nextBridge.failoverOrigins[0]? then
        if let some (true, host, port, _) := parseOriginHostPort primaryOrig then
          pool.prewarm host port true 6000
    return .ok (.obj #[
      ("connection", connVal),
      ("prefs", prefsVal),
      ("transport", nextBridge.toJson)
    ])
  | "transport_bridge_configure" =>
    let shardCountU8 : UInt8 := UInt8.ofNat st.bridge.shardPorts.size
    if verifySseShardConfig shardCountU8 st.bridge.proxyPort != 1 ||
       !allShardPortsValid st.rpcPort st.bridge.proxyPort st.bridge.shardPorts then
      return .error "invalid SSE shard configuration"
    let rawUrl := ((args.fieldStr? "apiUrl").orElse (fun _ => args.fieldStr? "api_url")).getD ""
    let cleanUrl := OrbBin.PosixExt.stripTrailingSlash rawUrl.trimAscii.toString
    let nextBridge ← stRef.modifyGet fun s =>
      if cleanUrl.startsWith "https://" && !(cleanUrl.toList.any (fun c => c.toNat ≤ 0x20 || c.toNat == 0x7F)) then
        let b := { s.bridge with configuredTarget := cleanUrl, failoverOrigins := candidateOriginsFor cleanUrl }
        (b, { s with bridge := b })
      else
        (s.bridge, s)
    -- Non-blocking TLS 1.3 HTTP/2 prewarm on primary origin so user's first click/send pays 0 handshake RTTs
    if let some pool := st.h2Pool? then
      if let some primaryOrig := nextBridge.failoverOrigins[0]? then
        if let some (true, host, port, _) := parseOriginHostPort primaryOrig then
          pool.prewarm host port true 6000
    return .ok nextBridge.toJson
  | "__orb_poll_events" =>
    let tokFilter? : Option (Array Nat) := (args.fieldArr? "tokens").map (fun xs => xs.filterMap (·.asNat?))
    let evs ← stRef.modifyGet fun s =>
      match tokFilter? with
      | none =>
        let items := s.queuedChannelEvents.map fun (tok, payload) =>
          JVal.obj #[("token", JVal.nat tok), ("payload", payload)]
        (JVal.arr items, { s with queuedChannelEvents := #[] })
      | some wanted =>
        let (matched, remaining) := s.queuedChannelEvents.partition (fun (tok, _) => wanted.contains tok)
        let items := matched.map fun (tok, payload) =>
          JVal.obj #[("token", JVal.nat tok), ("payload", payload)]
        (JVal.arr items, { s with queuedChannelEvents := remaining })
    return .ok evs
  | "desktop_connection_load" =>
    match connectionFilePath? st with
    | none => return .ok st.connectionJson
    | some path =>
      if !(← path.pathExists) then
        return .ok st.connectionJson
      try
        let raw ← IO.FS.readFile path
        match OrbBin.Json.parse raw.trimAscii.toString with
        | .ok jv =>
          stRef.modify fun s => { s with connectionJson := jv }
          return .ok jv
        | .error _ => return .error "Invalid saved connection"
      catch _ =>
        return .error "Cannot read saved connection"
  | "desktop_connection_save" =>
    let rawConn := (args.field? "connection").getD args
    let connVal : JVal :=
      match rawConn with
      | .null => .null
      | _ =>
        let url := ((rawConn.fieldStr? "api_url").orElse (fun _ => rawConn.fieldStr? "apiUrl")).getD ""
        let tok := (rawConn.fieldStr? "token").getD ""
        if url.isEmpty && tok.isEmpty then .null
        else .obj #[("api_url", .str url), ("token", .str tok)]
    stRef.modify fun s => { s with connectionJson := connVal }
    if let some path := connectionFilePath? st then
      let payload := (renderCompact connVal ++ "\n").toUTF8
      if let .error e ← OrbBin.PosixExt.writeAtomicPrivate0600 path payload then
        return .error e
    return .ok .null
  | "desktop_prefs_load" =>
    let sinceRev? := args.fieldStr? "since_rev"
    uiPrefsMutex.atomically do
      match ← readUiPrefsFromDisk (uiPrefsFilePath? st) with
      | .error e => return .error e
      | .ok (prefsObj, rev, existed) =>
        if existed && sinceRev? == some rev then
          return .ok (.obj #[("unchanged", .bool true), ("rev", .str rev), ("exists", .bool true)])
        return .ok (.obj #[("unchanged", .bool false), ("rev", .str rev), ("exists", .bool existed), ("prefs", prefsObj)])
  | "desktop_prefs_patch" =>
    let setKvs := ((args.field? "set").bind (·.asObj?)).getD #[]
    let removeKeys := ((args.fieldArr? "remove").getD #[]).filterMap (·.asStr?)
    let clearAll := (args.fieldBool? "clear").getD false
    let path? := uiPrefsFilePath? st
    withUiPrefsLock path? do
      let curObj ←
        if clearAll then pure (JVal.obj #[])
        else
          match ← readUiPrefsFromDisk path? with
          | .ok (obj, _, _) => pure obj
          | .error e => return .error e
      let curKvs := (curObj.asObj?).getD #[]
      let afterRem := curKvs.filter (fun (k, _) => !removeKeys.contains k)
      let merged := afterRem ++ setKvs
      let (nextObj, rev) := canonicalUiPrefs merged
      if let some path := path? then
        let payload := (renderCompact nextObj ++ "\n").toUTF8
        if let .error e ← OrbBin.PosixExt.writeAtomicPrivate0600 path payload then
          return .error e
      return .ok (.obj #[("rev", .str rev), ("prefs", nextObj)])
  | "ui_cache_get" =>
    let kind := (args.fieldStr? "kind").getD ""
    let key := (args.fieldStr? "key").getD ""
    if !isValidUiCacheKind kind || key.isEmpty || key.utf8ByteSize > 512 then
      return .error "Invalid ui_cache_get arguments"
    match resolveOrbStateDir st, uiCacheSqlitePath? st with
    | some stateDir, some dbPath =>
      uiCacheMutex.atomically do
        match ← ensurePrivateSqliteHandle uiCacheDbPoolRef stateDir dbPath uiCacheSchemaSql with
        | .ok db =>
          let sql :=
            if kind == "sidebar" then
              "SELECT payload_json FROM ui_sidebar WHERE scope_key = ?1;"
            else
              "SELECT payload_json FROM ui_transcript_raw WHERE record_key = ?1;"
          if let .ok rows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle sql #[key] then
            if rows.size ≥ 2 && rows[1]!.size ≥ 1 then
              return .ok (.str rows[1]![0]!)
          if kind == "transcript" then
            if let .ok mrows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "SELECT scope_key, mission_id, saved_at, head_json FROM ui_transcript_meta WHERE record_key = ?1;" #[key] then
              if mrows.size ≥ 2 && mrows[1]!.size ≥ 4 then
                let scopeKey := mrows[1]![0]!
                let missionId := mrows[1]![1]!
                let savedAt := mrows[1]![2]!.trimAscii.toString.toNat?.getD 0
                let headRaw := mrows[1]![3]!
                if let .ok headJv := OrbBin.Json.parse headRaw then
                  if let .ok erows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                      "SELECT event_json FROM ui_transcript_events WHERE record_key = ?1 ORDER BY idx ASC;" #[key] then
                    let mut streamArr : Array JVal := #[]
                    for rIdx in [1:erows.size] do
                      if erows[rIdx]!.size ≥ 1 then
                        if let .ok ej := OrbBin.Json.parse erows[rIdx]![0]! then
                          streamArr := streamArr.push ej
                    let baseFields := ((headJv.asObj?).getD #[]).filter (fun (fk, _) => fk != "stream" && fk != "items")
                    let snapJv := JVal.obj (baseFields ++ #[("items", .arr #[]), ("stream", .arr streamArr)])
                    let recJv := JVal.obj #[
                      ("id", .str key),
                      ("scope", .str scopeKey),
                      ("missionId", .str missionId),
                      ("savedAt", .nat savedAt),
                      ("snapshot", snapJv)
                    ]
                    return .ok (.str (renderCompact recJv))
        | .error _ => pure ()
        -- Legacy flat-file fallback (`~/.orb/ui-cache/*.cache`)
        match uiCacheDirPath? st with
        | none => return .ok .null
        | some dir =>
          let dirSt ← OrbBin.PosixExt.statPath dir.toString
          if !dirSt.exists_ then return .ok .null
          if dirSt.isSymlink then return .error "UI cache directory must not be a symlink"
          let path := uiCacheEntryPath dir kind key
          let fileSt ← OrbBin.PosixExt.statPath path.toString
          if !fileSt.exists_ || fileSt.isSymlink || !fileSt.isReg then return .ok .null
          try
            let raw ← IO.FS.readFile path
            let keyHex := LeanSys.Auth.bytesToHexLower key.toUTF8
            match parseUiCacheFile? raw keyHex with
            | some (_, payload) => return .ok (.str payload)
            | none => return .ok .null
          catch _ =>
            return .ok .null
    | _, _ => return .ok .null
  | "ui_cache_put" =>
    let kind := (args.fieldStr? "kind").getD ""
    let key := (args.fieldStr? "key").getD ""
    let rawJson := (args.fieldStr? "raw").getD ""
    let savedAt := (args.fieldNat? "saved_at").getD 0
    let tier := match args.fieldStr? "tier" with
      | some "warm" => "warm"
      | _ => if rawJson == "{}" then "warm" else "hot"
    if !isValidUiCacheKind kind || key.isEmpty || key.utf8ByteSize > 512 then
      return .error "Invalid ui_cache_put key"
    if rawJson.isEmpty || rawJson.utf8ByteSize > maxUiCacheRawBytes then
      return .error "Invalid ui_cache_put payload"
    match resolveOrbStateDir st, uiCacheSqlitePath? st with
    | some stateDir, some dbPath =>
      uiCacheMutex.atomically do
        match ← ensurePrivateSqliteHandle uiCacheDbPoolRef stateDir dbPath uiCacheSchemaSql with
        | .ok db =>
          if kind == "sidebar" then
            match ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "INSERT INTO ui_sidebar (scope_key, saved_at, payload_json) VALUES (?1, ?2, ?3) ON CONFLICT(scope_key) DO UPDATE SET saved_at = excluded.saved_at, payload_json = excluded.payload_json WHERE excluded.saved_at >= ui_sidebar.saved_at;"
                #[key, s!"{savedAt}", rawJson] with
            | .ok _ => return .ok .null
            | .error e => return .error e
          else
            if let .ok erows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "SELECT saved_at FROM ui_transcript_raw WHERE record_key = ?1;" #[key] then
              if erows.size ≥ 2 && erows[1]!.size ≥ 1 then
                let curTs := erows[1]![0]!.trimAscii.toString.toNat?.getD 0
                if curTs > savedAt then
                  return .ok .null
            if let .ok mrows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "SELECT saved_at FROM ui_transcript_meta WHERE record_key = ?1;" #[key] then
              if mrows.size ≥ 2 && mrows[1]!.size ≥ 1 then
                let curTs := mrows[1]![0]!.trimAscii.toString.toNat?.getD 0
                if curTs > savedAt then
                  return .ok .null
            -- Tombstone `{}` or raw transcript write also drops any shadowed sliced rows for `key`.
            let _ ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle "DELETE FROM ui_transcript_events WHERE record_key = ?1;" #[key]
            let _ ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle "DELETE FROM ui_transcript_meta WHERE record_key = ?1;" #[key]
            match ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "INSERT INTO ui_transcript_raw (record_key, saved_at, tier, payload_json) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(record_key) DO UPDATE SET saved_at = excluded.saved_at, tier = excluded.tier, payload_json = excluded.payload_json WHERE excluded.saved_at >= ui_transcript_raw.saved_at;"
                #[key, s!"{savedAt}", tier, rawJson] with
            | .ok _ =>
              let demoteKeys ← reconcileSqliteTranscripts db.handle
              if !demoteKeys.isEmpty then
                return .ok (.obj #[("demote_keys", .arr (demoteKeys.map .str))])
              return .ok .null
            | .error e => return .error e
        | .error _ =>
          match uiCacheDirPath? st with
          | none => return .ok .null
          | some dir =>
            try
              IO.FS.createDirAll dir
              discard <| OrbBin.PosixExt.chmod dir.toString 0o700
            catch _ => pure ()
            let dirSt ← OrbBin.PosixExt.statPath dir.toString
            if dirSt.isSymlink then return .error "UI cache directory must not be a symlink"
            let path := uiCacheEntryPath dir kind key
            let (existingTs, _, _) ← readUiCacheMeta path
            if existingTs > savedAt then
              return .ok .null
            let keyHex := LeanSys.Auth.bytesToHexLower key.toUTF8
            let headerTs := if kind == "transcript" then s!"{savedAt}:{tier}" else s!"{savedAt}"
            let wire := (s!"{headerTs}\n{keyHex}\n" ++ rawJson).toUTF8
            if let .error e ← OrbBin.PosixExt.writeAtomicPrivate0600 path wire then
              return .error e
            if kind == "transcript" then
              let demoteKeys ← reconcileUiCacheTranscripts dir
              if !demoteKeys.isEmpty then
                return .ok (.obj #[("demote_keys", .arr (demoteKeys.map .str))])
            return .ok .null
    | _, _ => return .ok .null
  | "ui_cache_put_transcript" =>
    let scopeKey := (args.fieldStr? "scope").getD ""
    let missionId := (args.fieldStr? "mission_id").getD ""
    let savedAt := (args.fieldNat? "saved_at").getD 0
    let headRaw := (args.fieldStr? "head_raw").getD "{}"
    let eventsRaw := ((args.fieldArr? "events_raw").getD #[]).filterMap (·.asStr?)
    let startIdx := (args.fieldNat? "start_idx").getD 0
    let recordKey := s!"{scopeKey}::m:{missionId}"
    if scopeKey.isEmpty || missionId.isEmpty || recordKey.utf8ByteSize > 512 then
      return .error "Invalid ui_cache_put_transcript key"
    let mut totalBytes := headRaw.utf8ByteSize
    for ev in eventsRaw do
      totalBytes := totalBytes + ev.utf8ByteSize
    if totalBytes > maxUiCacheRawBytes then
      return .error "UI cache transcript exceeds 8 MiB limit"
    match resolveOrbStateDir st, uiCacheSqlitePath? st with
    | some stateDir, some dbPath =>
      uiCacheMutex.atomically do
        let db ← match ← ensurePrivateSqliteHandle uiCacheDbPoolRef stateDir dbPath uiCacheSchemaSql with
          | .ok d => pure d
          | .error e => return .error e
        if let .error e ← OrbBin.Sqlite.sqliteExecRaw db.handle "BEGIN IMMEDIATE;" then
          return .error e
        if let .ok mrows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
            "SELECT saved_at FROM ui_transcript_meta WHERE record_key = ?1;" #[recordKey] then
          if mrows.size ≥ 2 && mrows[1]!.size ≥ 1 then
            let curTs := mrows[1]![0]!.trimAscii.toString.toNat?.getD 0
            if curTs > savedAt then
              let _ ← OrbBin.Sqlite.sqliteExecRaw db.handle "ROLLBACK;"
              return .ok .null
        if let .ok rrows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
            "SELECT saved_at FROM ui_transcript_raw WHERE record_key = ?1;" #[recordKey] then
          if rrows.size ≥ 2 && rrows[1]!.size ≥ 1 then
            let curTs := rrows[1]![0]!.trimAscii.toString.toNat?.getD 0
            if curTs > savedAt then
              let _ ← OrbBin.Sqlite.sqliteExecRaw db.handle "ROLLBACK;"
              return .ok .null
        let txRes : Except String Unit ← do
          let _ ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle "DELETE FROM ui_transcript_raw WHERE record_key = ?1;" #[recordKey]
          let totalEvents := startIdx + eventsRaw.size
          if startIdx == 0 then
            if let .error e ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "DELETE FROM ui_transcript_events WHERE record_key = ?1;" #[recordKey] then
              pure (.error e)
            else
              let mut err? : Option String := none
              for i in [0:eventsRaw.size] do
                if err?.isNone then
                  if let .error e ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                      "INSERT INTO ui_transcript_events (record_key, idx, event_json) VALUES (?1, ?2, ?3);"
                      #[recordKey, s!"{i}", eventsRaw[i]!] then
                    err? := some e
              match err? with
              | some e => pure (.error e)
              | none =>
                match ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                    "INSERT INTO ui_transcript_meta (record_key, scope_key, mission_id, saved_at, total_events, head_json) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(record_key) DO UPDATE SET scope_key = excluded.scope_key, mission_id = excluded.mission_id, saved_at = excluded.saved_at, total_events = excluded.total_events, head_json = excluded.head_json;"
                    #[recordKey, scopeKey, missionId, s!"{savedAt}", s!"{totalEvents}", headRaw] with
                | .ok _ => pure (.ok ())
                | .error e => pure (.error e)
          else
            if let .error e ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                "DELETE FROM ui_transcript_events WHERE record_key = ?1 AND idx >= ?2;"
                #[recordKey, s!"{startIdx}"] then
              pure (.error e)
            else
              let mut err? : Option String := none
              for i in [0:eventsRaw.size] do
                if err?.isNone then
                  if let .error e ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                      "INSERT INTO ui_transcript_events (record_key, idx, event_json) VALUES (?1, ?2, ?3) ON CONFLICT(record_key, idx) DO UPDATE SET event_json = excluded.event_json;"
                      #[recordKey, s!"{startIdx + i}", eventsRaw[i]!] then
                    err? := some e
              match err? with
              | some e => pure (.error e)
              | none =>
                match ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                    "INSERT INTO ui_transcript_meta (record_key, scope_key, mission_id, saved_at, total_events, head_json) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(record_key) DO UPDATE SET scope_key = excluded.scope_key, mission_id = excluded.mission_id, saved_at = excluded.saved_at, total_events = excluded.total_events, head_json = excluded.head_json;"
                    #[recordKey, scopeKey, missionId, s!"{savedAt}", s!"{totalEvents}", headRaw] with
                | .ok _ => pure (.ok ())
                | .error e => pure (.error e)
        match txRes with
        | .error e =>
          let _ ← OrbBin.Sqlite.sqliteExecRaw db.handle "ROLLBACK;"
          return .error e
        | .ok () =>
          if let .error e ← OrbBin.Sqlite.sqliteExecRaw db.handle "COMMIT;" then
            let _ ← OrbBin.Sqlite.sqliteExecRaw db.handle "ROLLBACK;"
            return .error e
          let _ ← reconcileSqliteTranscripts db.handle
          return .ok .null
    | _, _ => return .ok .null
  | "ui_cache_get_tail" =>
    let scopeKey := (args.fieldStr? "scope").getD ""
    let missionId := (args.fieldStr? "mission_id").getD ""
    let tailLimit := max 1 (min ((args.fieldNat? "tail_limit").getD 80) 2000)
    let recordKey := s!"{scopeKey}::m:{missionId}"
    if scopeKey.isEmpty || missionId.isEmpty || recordKey.utf8ByteSize > 512 then
      return .error "Invalid ui_cache_get_tail arguments"
    match resolveOrbStateDir st, uiCacheSqlitePath? st with
    | some stateDir, some dbPath =>
      uiCacheMutex.atomically do
        match ← ensurePrivateSqliteHandle uiCacheDbPoolRef stateDir dbPath uiCacheSchemaSql with
        | .error _ => return .ok .null
        | .ok db =>
          if let .ok mrows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
              "SELECT saved_at, total_events, head_json FROM ui_transcript_meta WHERE record_key = ?1;" #[recordKey] then
            if mrows.size ≥ 2 && mrows[1]!.size ≥ 3 then
              let savedAt := mrows[1]![0]!.trimAscii.toString.toNat?.getD 0
              let totalEvents := mrows[1]![1]!.trimAscii.toString.toNat?.getD 0
              let headRaw := mrows[1]![2]!
              let startIdx := if totalEvents > tailLimit then totalEvents - tailLimit else 0
              if let .ok erows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
                  "SELECT idx, event_json FROM ui_transcript_events WHERE record_key = ?1 AND idx >= ?2 ORDER BY idx ASC;"
                  #[recordKey, s!"{startIdx}"] then
                let mut evArr : Array JVal := #[]
                let mut actualStart := startIdx
                if erows.size ≥ 2 && erows[1]!.size ≥ 1 then
                  actualStart := erows[1]![0]!.trimAscii.toString.toNat?.getD startIdx
                for rIdx in [1:erows.size] do
                  if erows[rIdx]!.size ≥ 2 then
                    evArr := evArr.push (.str erows[rIdx]![1]!)
                return .ok (.obj #[
                  ("saved_at", .nat savedAt),
                  ("total_events", .nat totalEvents),
                  ("start_idx", .nat actualStart),
                  ("head_raw", .str headRaw),
                  ("events_raw", .arr evArr)
                ])
          -- Fallback to whole raw transcript row if stored via legacy `ui_cache_put`
          if let .ok rrows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
              "SELECT payload_json FROM ui_transcript_raw WHERE record_key = ?1;" #[recordKey] then
            if rrows.size ≥ 2 && rrows[1]!.size ≥ 1 then
              return .ok (.obj #[("legacy_raw", .str rrows[1]![0]!)])
          return .ok .null
    | _, _ => return .ok .null
  | "ui_cache_get_slice" =>
    let scopeKey := (args.fieldStr? "scope").getD ""
    let missionId := (args.fieldStr? "mission_id").getD ""
    let beforeIdx := (args.fieldNat? "before_idx").getD 0
    let limit := max 1 (min ((args.fieldNat? "limit").getD 80) 2000)
    let recordKey := s!"{scopeKey}::m:{missionId}"
    if scopeKey.isEmpty || missionId.isEmpty || recordKey.utf8ByteSize > 512 then
      return .error "Invalid ui_cache_get_slice arguments"
    if beforeIdx == 0 then
      return .ok (.obj #[("start_idx", .nat 0), ("events_raw", .arr #[])])
    let startIdx := if beforeIdx > limit then beforeIdx - limit else 0
    match resolveOrbStateDir st, uiCacheSqlitePath? st with
    | some stateDir, some dbPath =>
      uiCacheMutex.atomically do
        match ← ensurePrivateSqliteHandle uiCacheDbPoolRef stateDir dbPath uiCacheSchemaSql with
        | .error _ => return .ok .null
        | .ok db =>
          if let .ok erows ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
              "SELECT idx, event_json FROM ui_transcript_events WHERE record_key = ?1 AND idx >= ?2 AND idx < ?3 ORDER BY idx ASC;"
              #[recordKey, s!"{startIdx}", s!"{beforeIdx}"] then
            let mut evArr : Array JVal := #[]
            let mut actualStart := startIdx
            if erows.size ≥ 2 && erows[1]!.size ≥ 1 then
              actualStart := erows[1]![0]!.trimAscii.toString.toNat?.getD startIdx
            for rIdx in [1:erows.size] do
              if erows[rIdx]!.size ≥ 2 then
                evArr := evArr.push (.str erows[rIdx]![1]!)
            return .ok (.obj #[
              ("start_idx", .nat actualStart),
              ("events_raw", .arr evArr)
            ])
          return .ok .null
    | _, _ => return .ok .null
  | "ui_cache_clear" =>
    stRef.modify fun s => { s with nativeChrome := {} }
    uiCacheMutex.atomically do
      if let some stateDir := resolveOrbStateDir st then
        if let some dbPath := uiCacheSqlitePath? st then
          let dbPathStr := dbPath.toString
          let pool ← uiCacheDbPoolRef.get
          for (p, db) in pool do
            if p == dbPathStr then
              OrbBin.Sqlite.sqliteCloseRaw db.handle
          uiCacheDbPoolRef.modify (fun xs => xs.filter (fun (p, _) => p != dbPathStr))
          for suf in #["", "-wal", "-shm"] do
            let target := dbPathStr ++ suf
            let fst ← OrbBin.PosixExt.statPath target
            if fst.exists_ && !fst.isSymlink && fst.isReg then
              try IO.FS.removeFile target catch _ => pure ()
          let _ := stateDir
      if let some dir := uiCacheDirPath? st then
        let dirSt ← OrbBin.PosixExt.statPath dir.toString
        if dirSt.exists_ && !dirSt.isSymlink then
          let entries ← try dir.readDir catch _ => pure #[]
          for e in entries do
            if (e.fileName.startsWith "sidebar-" || e.fileName.startsWith "transcript-") &&
               e.fileName.endsWith ".cache" then
              try IO.FS.removeFile e.path catch _ => pure ()
      return .ok .null
  | "ui_draft_get" =>
    let key := (args.fieldStr? "key").getD ""
    if key.isEmpty || key.utf8ByteSize > 1024 then
      return .error "Invalid ui_draft_get key"
    match resolveOrbStateDir st, uiDraftsSqlitePath? st with
    | some stateDir, some dbPath =>
      uiDraftsMutex.atomically do
        match ← ensurePrivateSqliteHandle uiDraftsDbPoolRef stateDir dbPath uiDraftsSchemaSql with
        | .error e => return .error e
        | .ok db =>
          match ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
              "SELECT value_json FROM ui_drafts WHERE scope_key = ?1;" #[key] with
          | .error e => return .error e
          | .ok rows =>
            if rows.size ≥ 2 && rows[1]!.size ≥ 1 then
              return .ok (.str rows[1]![0]!)
            return .ok .null
    | _, _ => return .ok .null
  | "ui_draft_put" =>
    let key := (args.fieldStr? "key").getD ""
    let rawVal := (args.fieldStr? "raw").getD ""
    let updatedAt := (args.fieldNat? "updated_at").getD 0
    let ifAbsent := args.fieldBool? "if_absent" == some true
    if key.isEmpty || key.utf8ByteSize > 1024 then
      return .error "Invalid ui_draft_put key"
    if rawVal.isEmpty || rawVal.utf8ByteSize > maxUiDraftRawBytes then
      return .error "Invalid ui_draft_put payload"
    match resolveOrbStateDir st, uiDraftsSqlitePath? st with
    | some stateDir, some dbPath =>
      uiDraftsMutex.atomically do
        let db ← match ← ensurePrivateSqliteHandle uiDraftsDbPoolRef stateDir dbPath uiDraftsSchemaSql with
          | .ok d => pure d
          | .error e => return .error e
        let sql :=
          if ifAbsent then
            "INSERT INTO ui_drafts (scope_key, updated_at, value_json) VALUES (?1, ?2, ?3) ON CONFLICT(scope_key) DO NOTHING;"
          else
            "INSERT INTO ui_drafts (scope_key, updated_at, value_json) VALUES (?1, ?2, ?3) ON CONFLICT(scope_key) DO UPDATE SET updated_at = excluded.updated_at, value_json = excluded.value_json WHERE excluded.updated_at >= ui_drafts.updated_at;"
        match ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle sql #[key, s!"{updatedAt}", rawVal] with
        | .ok _ =>
          evictExcessSqliteDrafts db.handle
          return .ok .null
        | .error e => return .error e
    | _, _ => return .ok .null
  | "ui_draft_delete" =>
    let key := (args.fieldStr? "key").getD ""
    if key.isEmpty || key.utf8ByteSize > 1024 then
      return .error "Invalid ui_draft_delete key"
    match resolveOrbStateDir st, uiDraftsSqlitePath? st with
    | some stateDir, some dbPath =>
      uiDraftsMutex.atomically do
        match ← ensurePrivateSqliteHandle uiDraftsDbPoolRef stateDir dbPath uiDraftsSchemaSql with
        | .error e => return .error e
        | .ok db =>
          match ← OrbBin.Sqlite.sqliteQueryRowsRaw db.handle
              "DELETE FROM ui_drafts WHERE scope_key = ?1;" #[key] with
          | .ok _ => return .ok .null
          | .error e => return .error e
    | _, _ => return .ok .null
  | "native_chrome_sync_state" =>
    let res ← stRef.modifyGet fun s =>
      match s.nativeChrome.syncFromJson args with
      | .error e => (.error e, s)
      | .ok (applied, scopeSt, nextHub) =>
        let rows := OrbLocald.NativeChrome.projectSidebarRows scopeSt
        let s1 := { s with nativeChrome := nextHub }
        let s2 :=
          if applied then
            s1.enqueueNamedEvent "native_chrome_rows_changed" (.obj #[
              ("scope", .str scopeSt.scope),
              ("revision", JVal.uint64 scopeSt.viewRevision),
              ("sync_revision", JVal.uint64 scopeSt.syncRevision),
              ("row_count", .nat rows.size)
            ])
          else s1
        (.ok (.obj #[
          ("scope", .str scopeSt.scope),
          ("revision", JVal.uint64 scopeSt.viewRevision),
          ("sync_revision", JVal.uint64 scopeSt.syncRevision),
          ("applied", .bool applied),
          ("row_count", .nat rows.size)
        ]), s2)
    return res
  | "native_chrome_get_rows" =>
    let reqScope := (args.fieldStr? "scope").getD ""
    let filterQ := (args.fieldStr? "filter_query").getD ""
    let scopeSt ← resolveNativeChromeScope stRef reqScope
    let rows := OrbLocald.NativeChrome.projectSidebarRows scopeSt filterQ
    let footer := OrbLocald.NativeChrome.projectSidebarFooter scopeSt
    let inSettings :=
      scopeSt.onSettings || (OrbLocald.NativeChrome.settingsSectionIdForSelected scopeSt.selected).isSome
    return .ok (.obj #[
      ("scope", .str scopeSt.scope),
      ("revision", JVal.uint64 scopeSt.viewRevision),
      ("sync_revision", JVal.uint64 scopeSt.syncRevision),
      ("on_settings", .bool inSettings),
      ("selected", .str scopeSt.selected),
      ("footer", footer.toJson),
      ("rows", .arr (rows.map OrbLocald.NativeChrome.SidebarRow.toJson))
    ])
  | "native_chrome_toggle_expand" =>
    let reqScope := (args.fieldStr? "scope").getD ""
    let rowId := (args.fieldStr? "row_id").getD ""
    let explicitExp? := args.fieldBool? "expanded"
    if rowId.trimAscii.toString.isEmpty then
      return .error "Invalid native_chrome_toggle_expand row_id"
    let _ ← resolveNativeChromeScope stRef reqScope
    let res ← stRef.modifyGet fun s =>
      match s.nativeChrome.toggleExpand reqScope rowId explicitExp? with
      | none => (.error "Unknown native chrome scope", s)
      | some (expandedNow, scopeSt, nextHub) =>
        let rows := OrbLocald.NativeChrome.projectSidebarRows scopeSt
        let footer := OrbLocald.NativeChrome.projectSidebarFooter scopeSt
        let s1 := { s with nativeChrome := nextHub }
        let s2 := s1.enqueueNamedEvent "native_chrome_rows_changed" (.obj #[
          ("scope", .str scopeSt.scope),
          ("revision", JVal.uint64 scopeSt.viewRevision),
          ("sync_revision", JVal.uint64 scopeSt.syncRevision),
          ("row_count", .nat rows.size)
        ])
        (.ok (.obj #[
          ("scope", .str scopeSt.scope),
          ("revision", JVal.uint64 scopeSt.viewRevision),
          ("sync_revision", JVal.uint64 scopeSt.syncRevision),
          ("row_id", .str rowId.trimAscii.toString),
          ("expanded", .bool expandedNow),
          ("footer", footer.toJson),
          ("rows", .arr (rows.map OrbLocald.NativeChrome.SidebarRow.toJson))
        ]), s2)
    return res
  | "native_chrome_move_admit" =>
    let itemKind := (args.fieldStr? "item_kind").getD ""
    let srcProj := (args.fieldStr? "src_project").getD ""
    let srcPath := (args.fieldStr? "src_path").getD ""
    let dstProj := (args.fieldStr? "dst_project").getD ""
    let dstPath := (args.fieldStr? "dst_path").getD ""
    let admitted := OrbLocald.NativeChrome.admitSidebarMove itemKind srcProj srcPath dstProj dstPath
    return .ok (.obj #[("admitted", .bool admitted)])
  | "native_chrome_palette_query" =>
    let reqScope := (args.fieldStr? "scope").getD ""
    let query := (args.fieldStr? "query").getD ""
    let limit := (args.fieldNat? "limit").getD 24
    let scopeSt ← resolveNativeChromeScope stRef reqScope
    let items := OrbLocald.NativeChrome.queryPaletteItems scopeSt query limit
    return .ok (.obj #[
      ("scope", .str scopeSt.scope),
      ("query", .str query),
      ("items", .arr (items.map OrbLocald.NativeChrome.PaletteItem.toJson))
    ])
  | "diagnostics_append" =>
    let lines : Array String := match args.fieldArr? "lines" with
      | some xs => xs.filterMap (·.asStr?)
      | none => #[]
    appendDiagnosticsLines st lines
    return .ok .null
  | "reveal_logs" =>
    match logsDirPath? st with
    | none => return .error "Log folder unavailable"
    | some dir =>
      try IO.FS.createDirAll dir catch _ => pure ()
      match ← runDetachedOpenDirectory st.hostOs dir.toString with
      | .ok () => return .ok .null
      | .error e => return .error s!"Could not open the log folder: {e}"
  | "open_url" =>
    let url := (args.fieldStr? "url").getD ""
    if !isSafeHttpUrl url then
      return .error "Refusing unsafe or non-HTTP URL"
    match ← runDetachedOpen st.hostOs #[url.trimAscii.toString] with
    | .ok () => return .ok .null
    | .error e => return .error s!"Could not open URL: {e}"
  | "reveal_download" =>
    let name := (args.fieldStr? "name").getD ""
    if !isSafeBasename name || st.homeDir.trimAscii.toString.isEmpty then
      return .error "Could not reveal download"
    let dlDir := System.FilePath.mk st.homeDir.trimAscii.toString / "Downloads"
    let dlPath := dlDir / name.trimAscii.toString
    if (← dlPath.pathExists) then
      match ← runDetachedRevealFile st.hostOs dlPath.toString dlDir.toString with
      | .ok () => return .ok .null
      | .error e => return .error s!"Could not reveal download: {e}"
    else if (← dlDir.pathExists) then
      match ← runDetachedOpenDirectory st.hostOs dlDir.toString with
      | .ok () => return .ok .null
      | .error e => return .error s!"Could not open Downloads folder: {e}"
    else
      return .error "Download file not found"
  | "set_window_theme" =>
    return .ok .null
  | "local_machine_metrics" =>
    let details := (args.fieldBool? "details").getD false
    let snap ← sampleHostMetricsCached stRef details
    return .ok snap
  | "paloma_ssh_pubkey" =>
    if st.homeDir.trimAscii.toString.isEmpty then return .ok .null
    let pubPath := System.FilePath.mk st.homeDir.trimAscii.toString / ".ssh" / "paloma.pub"
    if !(← pubPath.pathExists) then return .ok .null
    try
      let txt := (← IO.FS.readFile pubPath).trimAscii.toString
      return .ok (if txt.isEmpty then .null else .str txt)
    catch _ =>
      return .ok .null
  | "approval_key_status" =>
    match st.signerBin? with
    | some bin =>
      if (st.hostOs == "macos" || st.hostOs == "linux") && (← System.FilePath.pathExists bin) then
        match ← runOrbSigner bin (resolveApprovalKeyArgs st "public") with
        | .ok jv =>
          let pk := (jv.fieldStr? "public_key").getD ""
          return .ok (.obj #[("available", .bool true), ("enrolled", .bool (!pk.isEmpty)), ("public_key", if pk.isEmpty then .null else .str pk)])
        | .error (3, _) =>
          return .ok (.obj #[("available", .bool false), ("enrolled", .bool false), ("public_key", .null)])
        | .error _ =>
          if st.hostOs == "linux" then
            match ← runOrbSigner bin #["status"] none with
            | .ok sjv =>
              let avail := (sjv.fieldStr? "available") == some "true" || (sjv.fieldBool? "available") == some true
              return .ok (.obj #[("available", .bool avail), ("enrolled", .bool false), ("public_key", .null)])
            | .error _ =>
              return .ok (.obj #[("available", .bool false), ("enrolled", .bool false), ("public_key", .null)])
          else
            return .ok (.obj #[("available", .bool true), ("enrolled", .bool false), ("public_key", .null)])
      else
        return .ok (.obj #[("available", .bool false), ("enrolled", .bool false), ("public_key", .null)])
    | none =>
      return .ok (.obj #[("available", .bool false), ("enrolled", .bool false), ("public_key", .null)])
  | "approval_key_create" =>
    match st.signerBin? with
    | some bin =>
      if st.hostOs == "macos" || st.hostOs == "linux" then
        resetSignerServer
        stRef.modify fun s => { s with approvalGraceUntil := 0 }
        match ← runOrbSigner bin (resolveApprovalKeyArgs st "create") with
        | .ok jv =>
          let pk := (jv.fieldStr? "public_key").getD ""
          if pk.isEmpty then return .error "orb-signer returned empty public_key"
          return .ok (.str pk)
        | .error (_, msg) => return .error msg
      else return .error "Approval key signing is unavailable on this host"
    | none => return .error "Approval key signing is unavailable on this host"
  | "approval_sign" =>
    let payload := (args.fieldStr? "payload").getD ""
    match st.signerBin? with
    | some bin =>
      if st.hostOs == "macos" || st.hostOs == "linux" then
        match ← signViaOrbSignerServer bin (resolveApprovalKeyPath st) st.approvalGraceSecs payload with
        | .ok jv =>
          let sig := (jv.fieldStr? "signature").getD ""
          if sig.isEmpty then return .error "orb-signer returned empty signature"
          let graceNat :=
            if st.approvalGraceSecs > 0 then
              (jv.fieldStr? "grace_until").bind String.toNat? |>.getD 0
            else 0
          stRef.modify fun s => { s with approvalGraceUntil := graceNat.toUInt64 }
          return .ok (.str sig)
        | .error (2, _) =>
          stRef.modify fun s => { s with approvalGraceUntil := 0 }
          return .error "cancelled"
        | .error (_, msg) =>
          stRef.modify fun s => { s with approvalGraceUntil := 0 }
          return .error msg
      else return .error "Approval key signing unavailable on this host"
    | none => return .error "Approval key signing unavailable on this host"
  | "approval_grace_until" =>
    let nowSec ← OrbBin.PosixExt.nowEpoch
    let rem : Nat := if st.approvalGraceUntil > nowSec then st.approvalGraceUntil.toNat else 0
    return .ok (JVal.nat rem)
  | "set_approval_grace" =>
    let secs := ((args.fieldNat? "secs").orElse (fun _ => args.fieldNat? "seconds")).getD 300
    let clamped := min secs 3600
    let changed ← stRef.modifyGet fun s =>
      let diff := s.approvalGraceSecs != clamped
      (diff, { s with
          approvalGraceSecs := clamped,
          approvalGraceUntil := if diff || clamped == 0 then 0 else s.approvalGraceUntil })
    if changed then
      resetSignerServer
    return .ok .null
  | "biometric_status" =>
    if st.hostOs != "macos" && (st.hostOs != "linux" || st.signerBin?.isNone) then
      return .ok (.obj #[
        ("available", .bool false),
        ("kind", .str "none"),
        ("label", .str ""),
        ("biometry_type", .str "none")
      ])
    match st.signerBin? with
    | some bin =>
      if (← System.FilePath.pathExists bin) then
        match ← runOrbSigner bin #["status"] none with
        | .ok jv =>
          let avail := (jv.fieldStr? "available") == some "true" || (jv.fieldBool? "available") == some true
          let kind := (jv.fieldStr? "kind").getD (if avail then "touch_id" else "none")
          let label := (jv.fieldStr? "label").getD (if avail then "Touch ID" else "")
          return .ok (.obj #[
            ("available", .bool avail),
            ("kind", .str kind),
            ("label", .str label),
            ("biometry_type", .str kind)
          ])
        | .error _ =>
          let fallbackAvail := st.hostOs == "macos"
          return .ok (.obj #[
            ("available", .bool fallbackAvail),
            ("kind", .str (if fallbackAvail then "touch_id" else "none")),
            ("label", .str (if fallbackAvail then "Touch ID" else "")),
            ("biometry_type", .str (if fallbackAvail then "touch_id" else "none"))
          ])
      else
        return .ok (.obj #[
          ("available", .bool false),
          ("kind", .str "none"),
          ("label", .str ""),
          ("biometry_type", .str "none")
        ])
    | none =>
      return .ok (.obj #[
        ("available", .bool true),
        ("kind", .str "touch_id"),
        ("label", .str "Touch ID"),
        ("biometry_type", .str "touch_id")
      ])
  | "biometric_authenticate" =>
    if st.hostOs != "macos" && st.hostOs != "linux" then
      return .error "Biometric authentication is unavailable on this host"
    match st.signerBin? with
    | none =>
      return .error "orb-signer binary not found"
    | some bin =>
      let rawReason := (args.fieldStr? "reason").getD "Authenticate"
      let cleanReason := if rawReason.trimAscii.toString.isEmpty then "Authenticate" else rawReason.trimAscii.toString
      match ← runOrbSigner bin #["auth", "--reason", cleanReason] none with
      | .ok jv =>
        let ok := (jv.fieldStr? "authenticated") == some "true" || (jv.fieldBool? "authenticated") == some true
        if ok then return .ok (.bool true)
        else return .error "biometric_failed"
      | .error (2, _) => return .error "biometric_cancelled"
      | .error (_, msg) => return .error msg
  | "client_link_active" =>
    if (args.fieldBool? "inspect").getD false then
      return .ok st.clientLink.toSummaryJson
    return .ok (.bool (st.clientLink.connected && !st.clientLink.unsupportedLatched))
  | "client_link_connect" =>
    let connObj := (args.field? "connection").getD args
    let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD st.bridge.configuredTarget
    let build? := (args.fieldStr? "server_build").orElse (fun _ =>
      (args.fieldStr? "serverBuild").orElse (fun _ => connObj.fieldStr? "server_build"))
    let obsStatusNat := ((args.fieldNat? "observed_http_status").orElse (fun _ => args.fieldNat? "httpStatus")).getD 0
    let obsStatus := UInt16.ofNat (min obsStatusNat 65535)
    let peerAck? := (args.fieldUInt64? "peer_ack_seq").orElse (fun _ => args.fieldUInt64? "peerAckSeq")
    let res : Except String JVal ← stRef.modifyGet fun s =>
      let stepped := s.clientLink.stepEndpointEpoch epRaw build? obsStatus
      if stepped.unsupportedLatched then
        (.ok (.bool false), { s with clientLink := stepped })
      else
        let connectedCl := { stepped with connected := true }
        match peerAck? with
        | none =>
          (.ok (.bool true), { s with clientLink := connectedCl })
        | some peerAck =>
          match connectedCl.resyncWindow peerAck with
          | .error e => (.error e, { s with clientLink := connectedCl })
          | .ok (floorSeq, replayFrames) =>
            let ackedCl := match connectedCl.ackUpTo floorSeq with
              | .ok c => c
              | .error _ => connectedCl
            let summary := (ackedCl.toSummaryJson.setField "replay_from_seq" (JVal.uint64 floorSeq)).setField
              "replay_frames" (.arr (replayFrames.map fun f => .obj #[
                ("seq", JVal.uint64 f.seq),
                ("mission", .str f.missionId),
                ("payload", f.payload)
              ]))
            if (args.fieldBool? "inspect").getD false then
              (.ok summary, { s with clientLink := ackedCl })
            else
              (.ok (.bool true), { s with clientLink := ackedCl })
    return res
  | "client_link_flush" =>
    let action? := (args.fieldStr? "action").map (·.trimAscii.toString.toLower)
    let missionId := ((args.fieldStr? "mission").orElse (fun _ => args.fieldStr? "id")).getD ""
    match action? with
    | some "enqueue" =>
      let payload := (args.field? "payload").getD (.obj #[])
      let maxCap? := args.fieldNat? "max_cap"
      let res : Except String JVal ← stRef.modifyGet fun s =>
        let cl0 := match maxCap? with
          | some cap =>
            let c16 := UInt16.ofNat (min cap 65535)
            if 1 ≤ c16 && c16 ≤ 256 then { s.clientLink with maxCap := c16 } else s.clientLink
          | none => s.clientLink
        match cl0.enqueueFrame missionId payload with
        | .error e => (.error e, { s with clientLink := cl0 })
        | .ok (frame, clNext) =>
          (.ok (.obj #[
            ("seq", JVal.uint64 frame.seq),
            ("unacked_count", JVal.nat clNext.unackedFrames.size),
            ("last_acked_seq", JVal.uint64 clNext.lastAckedSeq),
            ("head_seq", JVal.uint64 clNext.headSeq)
          ]), { s with clientLink := clNext })
      return res
    | some "ack" =>
      let ackSeq := ((args.fieldUInt64? "ack_seq").orElse (fun _ => args.fieldUInt64? "ackSeq")).getD 0
      let res : Except String JVal ← stRef.modifyGet fun s =>
        match s.clientLink.ackUpTo ackSeq with
        | .error e => (.error e, s)
        | .ok clNext => (.ok clNext.toSummaryJson, { s with clientLink := clNext })
      return res
    | some "resync" =>
      let peerAck := ((args.fieldUInt64? "peer_ack_seq").orElse (fun _ => args.fieldUInt64? "peerAckSeq")).getD st.clientLink.lastAckedSeq
      match st.clientLink.resyncWindow peerAck with
      | .error e => return .error e
      | .ok (floorSeq, replayFrames) =>
        return .ok (.obj #[
          ("replay_from_seq", JVal.uint64 floorSeq),
          ("head_seq", JVal.uint64 st.clientLink.headSeq),
          ("replay_count", JVal.nat replayFrames.size),
          ("frames", .arr (replayFrames.map fun f => .obj #[
            ("seq", JVal.uint64 f.seq),
            ("mission", .str f.missionId),
            ("payload", f.payload)
          ]))
        ])
    | _ =>
      let activeOk := st.clientLink.connected && !st.clientLink.unsupportedLatched
      let drained := activeOk && !st.clientLink.hasPendingForMission missionId
      return .ok (.bool drained)
  | "client_link_set_capabilities" =>
    let connObj := (args.field? "connection").getD args
    let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD st.clientLink.endpoint
    let build? := (args.fieldStr? "server_build").orElse (fun _ => args.fieldStr? "serverBuild")
    let obsStatusNat := ((args.fieldNat? "observed_http_status").orElse (fun _ => args.fieldNat? "httpStatus")).getD 0
    let obsStatus := UInt16.ofNat (min obsStatusNat 65535)
    let harnesses := (args.field? "harnesses").getD st.clientLink.harnesses
    stRef.modify fun s =>
      let stepped := s.clientLink.stepEndpointEpoch epRaw build? obsStatus
      { s with clientLink := { stepped with harnesses := harnesses } }
    return .ok .null
  | "client_link_start_result" =>
    let reqId := ((args.fieldStr? "requestId").orElse (fun _ => args.fieldStr? "request_id")).getD ""
    let okFlag := (args.fieldBool? "ok").getD false
    let mid? := ((args.fieldStr? "missionId").orElse (fun _ => args.fieldStr? "mission_id")).filter (fun m => !m.isEmpty)
    let err? := (args.fieldStr? "error").filter (fun e => !e.isEmpty)
    if !reqId.trimAscii.toString.isEmpty then
      stRef.modify fun s =>
        let cleanReq := reqId.trimAscii.toString
        let kept := s.clientLink.startReceipts.filter (fun r => r.requestId != cleanReq)
        let nextRecs := kept.push { requestId := cleanReq, ok := okFlag, missionId := mid?, errorMsg := err? }
        { s with clientLink := { s.clientLink with startReceipts := nextRecs } }
    return .ok .null
  | "local_bindings_refresh" =>
    ensurePersistedBindingsLoaded stRef
    let cur ← stRef.get
    return .ok cur.bindingsSnapshotJson
  | "local_binding_set" =>
    ensurePersistedBindingsLoaded stRef
    let bid := (args.fieldStr? "id").getD ""
    let bval := (args.field? "binding").getD (.obj #[])
    let ifAbsent := (args.fieldBool? "ifAbsent").getD false
    let cwdCanon? ← match bval.fieldStr? "cwd" with
      | some c => canonicalizeExistingPath? c
      | none => pure none
    let (snap, didChange, stAfter) ← stRef.modifyGet fun s =>
      if bid.isEmpty || (ifAbsent && (s.bindingsEntries.any (fun (k, _) => k == bid))) then
        ((s.bindingsSnapshotJson, false, s), s)
      else
        let filtered := s.bindingsEntries.filter (fun (k, _) => k != bid)
        let nextEntries := filtered.push (bid, bval)
        let nextRev := s.bindingsRevision + 1
        let nextSnap : JVal := .obj #[("revision", JVal.nat nextRev), ("bindings", .obj nextEntries)]
        let nextRoots := match cwdCanon? with
          | some rp => if rp != "/" && !s.grantedBrowseRoots.contains rp then s.grantedBrowseRoots.push rp else s.grantedBrowseRoots
          | none => s.grantedBrowseRoots
        let s1 := { s with bindingsRevision := nextRev, bindingsEntries := nextEntries, grantedBrowseRoots := nextRoots }
        let s2 := s1.publishChannelEvent "local_bindings" nextSnap
        ((nextSnap, true, s2), s2)
    if didChange then
      persistBindingsSnapshot stAfter
    return .ok snap
  | "local_bindings_subscribe" =>
    ensurePersistedBindingsLoaded stRef
    let tok ← stRef.modifyGet fun s =>
      s.subscribe "local_bindings" (some s.bindingsSnapshotJson)
    return .ok (JVal.nat tok)
  | "local_interaction_subscribe" =>
    let rawId := ((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).getD ""
    let cleanId := rawId.trimAscii.toString
    let target? : Option String := if cleanId.isEmpty then none else some cleanId
    let tok ← stRef.modifyGet fun s =>
      let initEv := if cleanId.isEmpty then .null else s.activeInteractionJson cleanId
      s.subscribe "local_interaction" (some initEv) target?
    return .ok (JVal.nat tok)
  | "project_context_subscribe" =>
    let tok ← stRef.modifyGet fun s =>
      s.subscribe "project_context" none
    return .ok (JVal.nat tok)
  | "local_agents_subscribe" =>
    let rawId := ((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).getD ""
    let cleanId := rawId.trimAscii.toString
    let target? : Option String := if cleanId.isEmpty then none else some cleanId
    let mgr ← ensureWarmManager stRef
    let snap? ← if cleanId.isEmpty then pure none else OrbBin.ClaudeControl.getRunState? mgr cleanId
    let initEv? : Option JVal := snap?.map fun rs =>
      .obj #[
        ("text", .str rs.text),
        ("reset", .bool true),
        ("activities", .arr (rs.activities.map OrbBin.ClaudeControl.LocalActivityItem.toJVal)),
        ("state", if rs.done then rs.toPollJVal else .null)
      ]
    let tok ← stRef.modifyGet fun s =>
      s.subscribe "local_agents" initEv? target?
    return .ok (JVal.nat tok)
  | "local_bindings_unsubscribe" | "local_interaction_unsubscribe"
  | "project_context_unsubscribe" | "local_agents_unsubscribe" =>
    let tok := (args.fieldNat? "token").getD 0
    stRef.modify fun s => s.unsubscribe tok
    return .ok .null
  | "offer_upload_folder" =>
    let batch := (args.fieldStr? "batch").getD ""
    if batch.trimAscii.toString.isEmpty then
      return .error "Missing upload batch token"
    let rawRoots := ((args.fieldArr? "roots").getD #[]).filterMap (·.asStr?)
    let mut canonRoots : Array String := #[]
    for r in rawRoots do
      if let some rp ← canonicalizeExistingPath? r then
        if rp != "/" && !canonRoots.contains rp then
          canonRoots := canonRoots.push rp
    if canonRoots.isEmpty then
      return .error "No valid folder root for upload offer"
    let rawFiles := (args.fieldArr? "files").getD #[]
    let mut allowedPairs : Array (String × String) := #[]
    for item in rawFiles do
      let explicitLocal? := (item.fieldStr? "local_path").orElse (fun _ => item.fieldStr? "localPath")
      let explicitRel? := (item.fieldStr? "relative_path").orElse (fun _ => item.fieldStr? "relativePath")
      let (rel, lp) :=
        match explicitLocal?, explicitRel? with
        | some l, some r => (r, l)
        | some l, none   => ((item.fieldStr? "path").getD "", l)
        | none, some r   => (r, (item.fieldStr? "path").getD "")
        | none, none     => ("", "")
      if !rel.isEmpty && !lp.isEmpty then
        let lst ← OrbBin.PosixExt.statPath lp
        if lst.exists_ && lst.isReg && !lst.isSymlink then
          if let some fpReal ← canonicalizeExistingPath? lp then
            if canonRoots.any (fun r => isCanonicalWithinRoot fpReal r) then
              allowedPairs := allowedPairs.push (rel, fpReal)
    let cleanBatch := batch.trimAscii.toString
    stRef.modify fun s =>
      let kept := s.offeredUploadBatches.filter (fun (b, _, _) => b != cleanBatch)
      { s with offeredUploadBatches := kept.push (cleanBatch, canonRoots, allowedPairs) }
    return .ok .null
  | "grant_upload_files" =>
    let rawPaths := ((args.fieldArr? "paths").getD #[]).filterMap (·.asStr?)
    let mut canonFiles : Array String := #[]
    for p in rawPaths do
      let lst ← OrbBin.PosixExt.statPath p
      if lst.exists_ && lst.isReg && !lst.isSymlink then
        if let some fpReal ← canonicalizeExistingPath? p then
          if !canonFiles.contains fpReal then
            canonFiles := canonFiles.push fpReal
    if !canonFiles.isEmpty then
      stRef.modify fun s =>
        let merged := canonFiles.foldl (fun acc f => if acc.contains f then acc else acc.push f) s.grantedUploadFiles
        { s with grantedUploadFiles := merged }
    return .ok .null
  | "grant_browse_root" =>
    let rawPath := (args.fieldStr? "path").getD ""
    let some rp ← canonicalizeExistingPath? rawPath
      | return .error "Directory does not exist"
    if rp == "/" then return .error "Refusing root filesystem for browse grant"
    let lst ← OrbBin.PosixExt.statPath rp
    if !lst.exists_ || !lst.isDir then return .error "Browse grant path is not a directory"
    stRef.modify fun s =>
      if s.grantedBrowseRoots.contains rp then s
      else { s with grantedBrowseRoots := s.grantedBrowseRoots.push rp }
    return .ok .null
  | "grant_upload_folder" =>
    let key := ((args.fieldStr? "batch").orElse (fun _ => args.fieldStr? "path")).getD ""
    let cleanKey := key.trimAscii.toString
    if cleanKey.isEmpty then return .ok .null
    let relFilter? : Option (Array String) :=
      (args.fieldArr? "relativePaths").orElse (fun _ => args.fieldArr? "relative_paths")
        |>.map (fun xs => xs.filterMap (·.asStr?))
    let curSt ← stRef.get
    if let some (_, roots, pairs) := curSt.offeredUploadBatches.find? (fun (b, _, _) => b == cleanKey) then
      let selectedFiles : Array String := pairs.filterMap fun (rel, fpReal) =>
        match relFilter? with
        | none => some fpReal
        | some wanted => if wanted.isEmpty || wanted.contains rel then some fpReal else none
      stRef.modify fun s =>
        let kept := s.grantedUploadBatches.filter (fun (b, _) => b != cleanKey)
        let mergedRoots := roots.foldl (fun acc r => if acc.contains r then acc else acc.push r) s.grantedBrowseRoots
        { s with
            grantedUploadBatches := kept.push (cleanKey, selectedFiles)
            grantedBrowseRoots := mergedRoots }
      return .ok .null
    else
      if let some rp ← canonicalizeExistingPath? cleanKey then
        if rp != "/" then
          let lst ← OrbBin.PosixExt.statPath rp
          if lst.exists_ && lst.isDir then
            stRef.modify fun s =>
              let gf := if s.grantedFolders.contains rp then s.grantedFolders else s.grantedFolders.push rp
              let gb := if s.grantedBrowseRoots.contains rp then s.grantedBrowseRoots else s.grantedBrowseRoots.push rp
              { s with grantedFolders := gf, grantedBrowseRoots := gb }
      return .ok .null
  | "revoke_upload_folder" =>
    let key := ((args.fieldStr? "batch").orElse (fun _ => args.fieldStr? "path")).getD ""
    let cleanKey := key.trimAscii.toString
    let canon? ← canonicalizeExistingPath? cleanKey
    stRef.modify fun s =>
      let matchLegacy (g : String) : Bool :=
        g == cleanKey || (match canon? with | some rp => g == rp | none => false)
      { s with
          offeredUploadBatches := s.offeredUploadBatches.filter (fun (b, _, _) => b != cleanKey)
          grantedUploadBatches := s.grantedUploadBatches.filter (fun (b, _) => b != cleanKey)
          grantedFolders := s.grantedFolders.filter (fun g => !matchLegacy g) }
    return .ok .null
  | "stat_upload_file" =>
    let p := (args.fieldStr? "path").getD ""
    let some canonFp ← checkCanonicalUploadRead st p
      | return .error "File was not granted for upload"
    try
      let m ← canonFp.metadata
      let modMs := m.modified.sec.toNat * 1000
      return .ok (.obj #[("size", JVal.nat m.byteSize.toNat), ("modified", JVal.nat modMs)])
    catch e =>
      return .error s!"Cannot stat upload file: {e}"
  | "read_upload_file" =>
    let p := (args.fieldStr? "path").getD ""
    let maxBytes := (args.fieldNat? "maxBytes").getD (20 * 1024 * 1024)
    let some canonFp ← checkCanonicalUploadRead st p
      | return .error "File was not granted for upload"
    try
      let m ← canonFp.metadata
      if m.byteSize.toNat > maxBytes then
        return .error s!"File exceeds maximum size ({maxBytes} bytes)"
      let raw ← IO.FS.readBinFile canonFp
      return .ok (.str (OrbBin.PosixExt.base64Encode raw))
    catch e =>
      return .error s!"Cannot read upload file: {e}"
  | "read_upload_file_chunk" =>
    let p := (args.fieldStr? "path").getD ""
    let offset := (args.fieldNat? "offset").getD 0
    let length := min ((args.fieldNat? "length").getD (4 * 1024 * 1024)) (8 * 1024 * 1024)
    let some canonFp ← checkCanonicalUploadRead st p
      | return .error "File was not granted for upload"
    try
      let h ← IO.FS.Handle.mk canonFp .read
      h.rewind
      let mut skipped : Nat := 0
      while skipped < offset do
        let step := min (offset - skipped) 1048576
        let chunk ← h.read step.toUSize
        if chunk.isEmpty then skipped := offset
        else skipped := skipped + chunk.size
      let data ← h.read length.toUSize
      return .ok (.str (OrbBin.PosixExt.base64Encode data))
    catch e =>
      return .error s!"Cannot read upload file chunk: {e}"
  | "stage_upload_file" =>
    let name := (args.fieldStr? "name").getD ""
    let b64 := ((args.fieldStr? "dataBase64").orElse (fun _ => args.fieldStr? "data_base64")).getD ""
    if !isSafeBasename name then
      return .error "Invalid upload filename"
    let some rawBytes := OrbBin.PosixExt.base64Decode? b64
      | return .error "Invalid base64 upload payload"
    let baseRoot : System.FilePath :=
      match resolveOrbStateDir st with
      | some d => d / "staged-uploads"
      | none => System.FilePath.mk "/tmp/orb-staged-uploads"
    let uid ← randomUuidV4
    let stageDir := baseRoot / uid
    try
      IO.FS.createDirAll stageDir
      let _ ← OrbBin.PosixExt.chmod stageDir.toString 0o700
      let destFp := stageDir / name.trimAscii.toString
      IO.FS.writeBinFile destFp rawBytes
      let _ ← OrbBin.PosixExt.chmod destFp.toString 0o600
      let canonPath := (← canonicalizeExistingPath? destFp.toString).getD destFp.toString
      let canonDir := (← canonicalizeExistingPath? stageDir.toString).getD stageDir.toString
      stRef.modify fun s =>
        let gf := if s.grantedUploadFiles.contains canonPath then s.grantedUploadFiles else s.grantedUploadFiles.push canonPath
        let gb := if s.grantedBrowseRoots.contains canonDir then s.grantedBrowseRoots else s.grantedBrowseRoots.push canonDir
        { s with grantedUploadFiles := gf, grantedBrowseRoots := gb }
      return .ok (.str canonPath)
    catch e =>
      return .error s!"Could not stage upload file: {e}"
  | "stage_upload_file_from_path" =>
    let srcRaw := (args.fieldStr? "path").getD ""
    let nameRaw := (args.fieldStr? "name").getD ""
    let some srcFp ← checkCanonicalUploadRead st srcRaw
      | return .error "File was not granted for upload"
    let fallbackName := srcFp.fileName.getD "attachment.bin"
    let safeName := if isSafeBasename nameRaw then nameRaw.trimAscii.toString else fallbackName
    if !isSafeBasename safeName then
      return .error "Invalid staged filename"
    let baseRoot : System.FilePath :=
      match resolveOrbStateDir st with
      | some d => d / "staged-uploads"
      | none => System.FilePath.mk "/tmp/orb-staged-uploads"
    let uid ← randomUuidV4
    let stageDir := baseRoot / uid
    try
      let rawBytes ← IO.FS.readBinFile srcFp
      IO.FS.createDirAll stageDir
      let _ ← OrbBin.PosixExt.chmod stageDir.toString 0o700
      let destFp := stageDir / safeName
      IO.FS.writeBinFile destFp rawBytes
      let _ ← OrbBin.PosixExt.chmod destFp.toString 0o600
      let canonPath := (← canonicalizeExistingPath? destFp.toString).getD destFp.toString
      let canonDir := (← canonicalizeExistingPath? stageDir.toString).getD stageDir.toString
      stRef.modify fun s =>
        let gf := if s.grantedUploadFiles.contains canonPath then s.grantedUploadFiles else s.grantedUploadFiles.push canonPath
        let gb := if s.grantedBrowseRoots.contains canonDir then s.grantedBrowseRoots else s.grantedBrowseRoots.push canonDir
        { s with grantedUploadFiles := gf, grantedBrowseRoots := gb }
      return .ok (.str canonPath)
    catch e =>
      return .error s!"Could not stage upload file from path: {e}"
  | "save_file_as" =>
    let destRaw := (args.fieldStr? "destPath").getD ""
    let nameRaw := (args.fieldStr? "name").getD ""
    let b64 := (args.fieldStr? "dataBase64").getD ""
    let targetPath : String :=
      if !destRaw.trimAscii.toString.isEmpty then destRaw.trimAscii.toString
      else if isSafeBasename nameRaw && !st.homeDir.trimAscii.toString.isEmpty then
        (System.FilePath.mk st.homeDir.trimAscii.toString / "Downloads" / nameRaw.trimAscii.toString).toString
      else ""
    if targetPath.isEmpty then
      return .ok .null
    match OrbBin.PosixExt.base64Decode? b64 with
    | none => return .error "Invalid base64 file data"
    | some bytes =>
      try
        let fp := System.FilePath.mk targetPath
        if let some parent := fp.parent then
          IO.FS.createDirAll parent
        IO.FS.writeBinFile fp bytes
        return .ok (.str fp.toString)
      catch e =>
        return .error s!"Could not save file: {e}"
  | "pick_working_directory" =>
    if st.hostOs != "linux" then
      return .ok .null
    let rawHint := ((args.fieldStr? "path").getD "").trimAscii.toString
    let initialDir? : Option String :=
      if !rawHint.isEmpty then some rawHint
      else if !st.homeDir.trimAscii.toString.isEmpty then some st.homeDir.trimAscii.toString
      else none
    let picked ← pickLinuxPaths "Choose Working Folder" true false initialDir?
    let some firstRaw := picked[0]?
      | return .ok .null
    let some rp ← canonicalizeExistingPath? firstRaw
      | return .ok .null
    let lst ← OrbBin.PosixExt.statPath rp
    if !lst.exists_ || !lst.isDir then
      return .ok .null
    if rp != "/" then
      stRef.modify fun s =>
        if s.grantedBrowseRoots.contains rp then s
        else { s with grantedBrowseRoots := s.grantedBrowseRoots.push rp }
    return .ok (.str rp)
  | "pick_upload_files" =>
    if st.hostOs != "linux" then
      return .ok (.arr #[])
    let initialDir? : Option String :=
      if !st.homeDir.trimAscii.toString.isEmpty then some st.homeDir.trimAscii.toString else none
    let picked ← pickLinuxPaths "Attach Files" false true initialDir?
    let mut items : Array JVal := #[]
    let mut canonGrants : Array String := #[]
    for rawPath in picked do
      let lst ← OrbBin.PosixExt.statPath rawPath
      if lst.exists_ && lst.isReg && !lst.isSymlink then
        if let some fpReal ← canonicalizeExistingPath? rawPath then
          if !canonGrants.contains fpReal then
            canonGrants := canonGrants.push fpReal
            let dispName := (System.FilePath.mk rawPath).fileName.getD ((System.FilePath.mk fpReal).fileName.getD "file")
            items := items.push (.obj #[("name", .str dispName), ("path", .str fpReal)])
    if !canonGrants.isEmpty then
      stRef.modify fun s =>
        let merged := canonGrants.foldl (fun acc f => if acc.contains f then acc else acc.push f) s.grantedUploadFiles
        { s with grantedUploadFiles := merged }
    return .ok (.arr items)
  | "pick_upload_folder" =>
    if st.hostOs != "linux" then
      return .ok (.obj #[("batch", .null), ("files", .arr #[])])
    let initialDir? : Option String :=
      if !st.homeDir.trimAscii.toString.isEmpty then some st.homeDir.trimAscii.toString else none
    let picked ← pickLinuxPaths "Attach Folder" true false initialDir?
    let some firstRaw := picked[0]?
      | return .ok (.obj #[("batch", .null), ("files", .arr #[])])
    let some rootCanon ← canonicalizeExistingPath? firstRaw
      | return .ok (.obj #[("batch", .null), ("files", .arr #[])])
    let lst ← OrbBin.PosixExt.statPath rootCanon
    if rootCanon == "/" || !lst.exists_ || !lst.isDir then
      return .ok (.obj #[("batch", .null), ("files", .arr #[])])
    let dispBase := (System.FilePath.mk firstRaw).fileName
    let walked ← walkFolderForUpload rootCanon dispBase
    let batchId ← randomUuidV4
    let allowedPairs : Array (String × String) := walked.map fun (_, fpReal, relPath, _) => (relPath, fpReal)
    stRef.modify fun s =>
      let kept := s.offeredUploadBatches.filter (fun (b, _, _) => b != batchId)
      { s with offeredUploadBatches := kept.push (batchId, #[rootCanon], allowedPairs) }
    let filesJson : Array JVal := walked.map fun (name, fpReal, relPath, sz) =>
      .obj #[
        ("name", .str name),
        ("path", .str fpReal),
        ("relative_path", .str relPath),
        ("size", JVal.nat sz)
      ]
    return .ok (.obj #[("batch", .str batchId), ("files", .arr filesJson)])
  | "voice_capability" =>
    let fakeMode := ((← OrbBin.PosixExt.getEnvNonEmpty "ORB_VOICE_FAKE").getD "") == "1"
    let arch ← detectHostArch
    let py? ← resolveVoicePython? st fakeMode
    let script? ← resolveVoiceScriptPath? st
    let modelDir ← resolveVoiceModelDir st
    let modelReady ← if fakeMode then pure true else isVoiceModelPresent modelDir
    let workerWarm ← voiceWorkerMutex.atomically do
      let cur ← get
      return cur.isSome
    let hasLinuxCohere ← (OrbBin.PosixExt.getEnvNonEmpty "VOICED_COHERE_LIB").map Option.isSome
    let supported := fakeMode || (st.hostOs == "macos" && arch == "aarch64") || (st.hostOs == "linux" && hasLinuxCohere)
    let reasonVal : JVal :=
      if !supported then .str "Speech-to-text requires Orb Desktop on Apple Silicon (macOS arm64)."
      else .null
    let pyReady := py?.isSome && script?.isSome
    return .ok (.obj #[
      ("supported", .bool supported),
      ("reason", reasonVal),
      ("platform", .str st.hostOs),
      ("arch", .str arch),
      ("python", match py? with | some p => .str p | none => .null),
      ("python_ready", .bool pyReady),
      ("model_repo", .str pinnedVoiceModelRepo),
      ("model_revision", .str pinnedVoiceModelRevision),
      ("model_dir", .str modelDir),
      ("model_ready", .bool modelReady),
      ("worker", .str (if workerWarm then "warm" else "off")),
      ("languages", .arr (supportedVoiceLanguages.map .str)),
      ("max_seconds", JVal.nat 120),
      ("idle_seconds", JVal.nat 600)
    ])
  | "voice_prewarm" =>
    match ← sendVoiceWorkerOp st "load" with
    | .ok res => return .ok res
    | .error e => return .error e
  | "voice_transcribe" =>
    let b64 := (args.fieldStr? "__binaryBase64").getD ((args.fieldStr? "audioBase64").getD "")
    let some wavBytes := OrbBin.PosixExt.base64Decode? b64
      | return .error "invalid_wav: missing or corrupt audio bytes"
    if wavBytes.isEmpty then
      return .error "empty_audio: no speech audio recorded"
    let hdrLang? := (args.field? "__headers").bind fun h =>
      (h.fieldStr? "x-language").orElse (fun _ => h.fieldStr? "X-Language")
    let lang := (hdrLang?.orElse (fun _ => args.fieldStr? "language")).getD "en"
    let cleanLang := if supportedVoiceLanguages.contains lang.trimAscii.toString.toLower then lang.trimAscii.toString.toLower else "en"
    match ← sendVoiceWorkerOp st "transcribe" #[("language", .str cleanLang), ("punctuation", .bool true)] wavBytes with
    | .ok res => return .ok res
    | .error e => return .error e
  | "voice_cancel" =>
    let killed ← cancelVoiceWorker
    return .ok (.bool killed)
  | "software_inventory" =>
    let overrides := (args.field? "overrides").getD (.obj #[])
    let scanned ← scanLocalAgents st overrides
    let nowMs := (← OrbBin.PosixExt.nowEpoch).toNat * 1000
    let appVer := (← OrbBin.PosixExt.getEnvNonEmpty "ORB_APP_VERSION").getD "0.13.0"
    let appPath ← try pure (some (← IO.appPath).toString) catch _ => pure none
    let components : Array JVal := scanned.map fun row =>
      let hid := (row.fieldStr? "id").getD ""
      let spec? := localHarnessSpecs.find? (fun (id, _, _, _, _) => id == hid)
      let dispName := match spec? with | some (_, nm, _, _, _) => nm | none => hid
      let instr := match spec? with | some (_, _, _, _, ins) => ins | none => ""
      let inst := (row.fieldBool? "installed").getD false
      .obj #[
        ("id", .str hid),
        ("name", .str dispName),
        ("version", (row.field? "version").getD .null),
        ("path", (row.field? "path").getD .null),
        ("installed", .bool inst),
        ("owner", .str "user"),
        ("update_supported", .bool false),
        ("latest", .null),
        ("release_error", .null),
        ("running", .arr #[]),
        ("instructions", .str instr),
        ("ready", .bool inst),
        ("ready_detail", .null)
      ]
    return .ok (.obj #[
      ("checked_at", JVal.nat nowMs),
      ("components", .arr components),
      ("runtime", .obj #[
        ("name", .str "Orb Desktop"),
        ("version", .str appVer),
        ("build", .str "lean4"),
        ("path", match appPath with | some p => .str p | none => .null),
        ("restart_required", .bool false),
        ("running", .arr #[])
      ]),
      ("jobs", .arr st.softwareJobs)
    ])
  | "software_update" =>
    return .error "Local CLI installations are managed externally (Homebrew, npm, or uv)."
  | "software_cancel" =>
    let jid := (args.fieldStr? "id").getD ""
    if !jid.isEmpty then
      stRef.modify fun s => { s with softwareJobs := s.softwareJobs.filter (fun j => j.fieldStr? "id" != some jid) }
    return .ok .null
  | "local_origin_list" =>
    ensurePersistedOriginsLoaded stRef
    let cur ← stRef.get
    let connObj := (args.field? "connection").getD args
    let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD cur.bridge.configuredTarget
    let tokRaw := (connObj.fieldStr? "token").getD ""
    let ep := normalizeEndpointKey epRaw
    let filtered := cur.localOrigins.filter (fun row => ep.isEmpty || row.endpoint.isEmpty || row.endpoint == ep)
    if !tokRaw.trimAscii.toString.isEmpty && epRaw.trimAscii.toString.startsWith "https://" &&
       !cur.unsupportedOriginSyncEndpoints.contains ep then
      for row in filtered do
        if row.localSyncPending && row.ackedSeq < row.syncSeq && !row.project.isEmpty &&
           !cur.syncingOriginIds.contains row.id then
          let mid := row.id
          discard <| IO.asTask do
            syncLocalOriginToCore stRef mid epRaw tokRaw 2
    return .ok (.arr (filtered.map LocalOriginEntry.toMissionJson))
  | "local_agents_scan" =>
    let cur ← stRef.get
    let homeOv? := if cur.homeDir.trimAscii.toString.isEmpty then none else some cur.homeDir.trimAscii.toString
    let reqObj := (args.field? "request").getD args
    let ov := (reqObj.field? "overrides").getD (.obj #[])
    let rows ← OrbBin.ClaudeControl.scanInstalledHarnesses ov homeOv?
    return .ok rows
  | "local_claude_models" =>
    let p := (args.fieldStr? "path").getD ""
    match ← OrbBin.ClaudeControl.probeClaudeModels p with
    | .ok models => return .ok (.arr (models.map fun (id, lbl) => .arr #[.str id, .str lbl]))
    | .error e => return .error e
  | "local_opencode_models" =>
    let cur ← stRef.get
    let homeOv? := if cur.homeDir.trimAscii.toString.isEmpty then none else some cur.homeDir.trimAscii.toString
    let p := (args.fieldStr? "path").getD ""
    match ← OrbBin.ClaudeControl.probeOpenCodeModels p homeOv? with
    | .ok models => return .ok (.arr (models.map fun (id, lbl) => .arr #[.str id, .str lbl]))
    | .error e => return .error e
  | "local_antigravity_models" =>
    let p := (args.fieldStr? "path").getD ""
    match ← OrbBin.ClaudeControl.probeAntigravityModels p with
    | .ok models => return .ok (.arr (models.map fun (id, lbl) => .arr #[.str id, .str lbl]))
    | .error e => return .error e
  | "local_agents_directory" =>
    let rawPath := ((args.fieldStr? "path").orElse (fun _ => (args.field? "request").bind (·.fieldStr? "path"))).getD ""
    let some rp ← canonicalizeExistingPath? rawPath
      | return .error "Selected local folder does not exist."
    if rp == "/" then
      return .error "Refusing root filesystem `/` as a working directory."
    let lst ← OrbBin.PosixExt.statPath rp
    if !lst.exists_ || !lst.isDir then
      return .error "Selected path is not a folder."
    stRef.modify fun s =>
      if s.grantedBrowseRoots.contains rp then s else { s with grantedBrowseRoots := s.grantedBrowseRoots.push rp }
    return .ok (.str rp)
  | "local_agents_workspace" =>
    let reqObj := (args.field? "request").getD args
    let rawSlug := (reqObj.fieldStr? "slug").getD "default"
    let slug := OrbBin.GitWorkspace.sanitizeGitToken rawSlug "default" 64
    let baseDir : System.FilePath :=
      match resolveOrbStateDir st with
      | some d => d / "workspaces" / slug
      | none =>
        let h := if st.homeDir.trimAscii.toString.isEmpty then "/tmp/orb-local" else s!"{st.homeDir.trimAscii.toString}/.orb"
        System.FilePath.mk h / "workspaces" / slug
    try
      IO.FS.createDirAll (baseDir / ".paloma" / "attach")
      let canon := (← canonicalizeExistingPath? baseDir.toString).getD baseDir.toString
      stRef.modify fun s =>
        if s.grantedBrowseRoots.contains canon then s else { s with grantedBrowseRoots := s.grantedBrowseRoots.push canon }
      return .ok (.str canon)
    catch e =>
      return .error s!"Could not create local workspace: {e}"
  | "local_agents_write" =>
    let reqObj := (args.field? "request").getD args
    let rootRaw := (reqObj.fieldStr? "root").getD ""
    let some rootReal ← canonicalizeExistingPath? rootRaw
      | return .error "Workspace folder does not exist"
    if rootReal == "/" then
      return .error "Refusing to write into `/`"
    let rootFp := System.FilePath.mk rootReal
    let files := (reqObj.fieldArr? "files").getD #[]
    let mut written : Array JVal := #[]
    let mut skipped : Array JVal := #[]
    for f in files do
      let relRaw := (f.fieldStr? "rel").getD ""
      match isSafeRelSubpath relRaw with
      | none => skipped := skipped.push (.str relRaw)
      | some cleanRel =>
        if isSecretRelPath cleanRel then
          skipped := skipped.push (.str cleanRel)
        else
          let content := (f.fieldStr? "content").getD ""
          let enc := (f.fieldStr? "encoding").getD "utf8"
          let maxLen := if enc == "base64" then 14 * 1024 * 1024 else 512 * 1024
          if content.utf8ByteSize > maxLen then
            skipped := skipped.push (.str cleanRel)
          else
            let bytes? : Option ByteArray :=
              if enc == "base64" then OrbBin.PosixExt.base64Decode? content
              else if enc == "utf8" || enc.isEmpty then some content.toUTF8
              else none
            match bytes? with
            | none =>
              if enc == "base64" then return .error "Invalid base64 attachment payload"
              else return .error "Unsupported attachment encoding"
            | some bytes =>
              let target := rootFp / cleanRel
              let okWrite ← try
                if let some parent := target.parent then
                  IO.FS.createDirAll parent
                  let some pReal ← canonicalizeExistingPath? parent.toString | pure false
                  if !isCanonicalWithinRoot pReal rootReal then pure false
                  else
                    let lst ← OrbBin.PosixExt.statPath target.toString
                    if lst.isSymlink then pure false
                    else
                      IO.FS.writeBinFile target bytes
                      pure true
                else pure false
              catch _ => pure false
              if okWrite then written := written.push (.str cleanRel)
              else skipped := skipped.push (.str cleanRel)
    return .ok (.obj #[
      ("binary_supported", .bool true),
      ("written", .arr written),
      ("skipped", .arr skipped)
    ])
  | "project_context_workers" =>
    return .ok (.arr #[])
  | "local_skill_source_files" =>
    let sname := (args.fieldStr? "name").getD ""
    let sourceId := (args.fieldStr? "sourceId").getD ""
    let rels := ((args.fieldArr? "rels").getD #[]).filterMap (·.asStr?)
    if !validSkillIdentifier sname || rels.isEmpty then
      return .ok (.arr #[])
    let envHome := (← IO.getEnv "HOME").getD ""
    let homeStr := if st.homeDir.trimAscii.toString.isEmpty then envHome else st.homeDir
    if homeStr.isEmpty then return .ok (.arr #[])
    let some (globalRel, _) := harnessSkillTargets sourceId | return .ok (.arr #[])
    let skillDir := System.FilePath.mk homeStr / globalRel / sname
    let some skillReal ← canonicalizeExistingPath? skillDir.toString | return .ok (.arr #[])
    let mut out : Array JVal := #[]
    for r in rels do
      if let some cleanRel := isSafeRelSubpath r then
        if !isSecretRelPath cleanRel then
          let fp := System.FilePath.mk skillReal / cleanRel
          let lst ← OrbBin.PosixExt.statPath fp.toString
          if lst.exists_ && lst.isReg && !lst.isSymlink then
            if let some fpReal ← canonicalizeExistingPath? fp.toString then
              if isCanonicalWithinRoot fpReal skillReal then
                let txt ← try IO.FS.readFile (System.FilePath.mk fpReal) catch _ => pure ""
                out := out.push (.obj #[("rel", .str cleanRel), ("content", .str txt)])
    return .ok (.arr out)
  | "browse_local_files" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let rootRaw := (args.fieldStr? "root").getD ""
    let reqObj := (args.field? "request").getD (.obj #[])
    let action := (reqObj.fieldStr? "action").getD "list"
    let relRaw := (reqObj.fieldStr? "path").getD ""
    if rootRaw.trimAscii.toString.isEmpty || (relRaw.splitOn "/").contains ".." || (relRaw.splitOn "\\").contains ".." then
      return .error "Invalid local browse path"
    let some rootReal ← checkCanonicalBrowseRoot curSt rootRaw
      | return .error "Local folder was not granted for browsing"
    let rootFp := System.FilePath.mk rootReal
    let cleanRel := (relRaw.replace "\\" "/" |>.splitOn "/").filter (fun s => !s.isEmpty && s != ".") |> String.intercalate "/"
    let targetFp := if cleanRel.isEmpty then rootFp else rootFp / cleanRel
    if action == "reveal" then
      let lst ← OrbBin.PosixExt.statPath targetFp.toString
      if !lst.exists_ || lst.isSymlink then
        return .error "Could not reveal this file"
      let some targetReal ← canonicalizeExistingPath? targetFp.toString
        | return .error "Could not reveal this file"
      if !isCanonicalWithinRoot targetReal rootReal then
        return .error "Refusing path outside browsed workspace"
      let parentDir := (System.FilePath.mk targetReal |>.parent.getD rootFp).toString
      match ← runDetachedRevealFile curSt.hostOs targetReal parentDir with
      | .ok () => return .ok (.obj #[])
      | .error _ => return .error "Could not reveal this file"
    else if action == "read" then
      let lst ← OrbBin.PosixExt.statPath targetFp.toString
      if !lst.exists_ || !lst.isReg || lst.isSymlink then
        return .error "Could not read local file"
      let some targetReal ← canonicalizeExistingPath? targetFp.toString
        | return .error "Could not read local file"
      if !isCanonicalWithinRoot targetReal rootReal then
        return .error "Refusing to read file outside browsed workspace"
      try
        let realFp := System.FilePath.mk targetReal
        let m ← realFp.metadata
        if m.byteSize.toNat > 2 * 1024 * 1024 then
          return .error "File is too large to preview"
        let content ← IO.FS.readFile realFp
        return .ok (.obj #[("content", .str content), ("size", JVal.nat m.byteSize.toNat)])
      catch _ =>
        return .error "Could not read local file"
    else if action == "resolve" then
      let paths := (reqObj.fieldArr? "paths").getD #[]
      let mut results : Array JVal := #[]
      for pVal in paths do
        if let some refStr := pVal.asStr? then
          let hasDotDot := (refStr.splitOn "/").contains ".." || (refStr.splitOn "\\").contains ".."
          let cleanRef := (refStr.replace "\\" "/" |>.splitOn "/").filter (fun s => !s.isEmpty && s != "." && s != "..") |> String.intercalate "/"
          let cand := if cleanRef.isEmpty then rootFp else rootFp / cleanRef
          let existsSafe ←
            if hasDotDot || cleanRef.isEmpty then pure false
            else do
              let lst ← OrbBin.PosixExt.statPath cand.toString
              if !lst.exists_ || !lst.isReg || lst.isSymlink then pure false
              else
                match ← canonicalizeExistingPath? cand.toString with
                | some cr => pure (isCanonicalWithinRoot cr rootReal)
                | none => pure false
          let matchesArr : Array JVal :=
            if existsSafe then
              let fname := cand.fileName.getD cleanRef
              #[.obj #[("name", .str fname), ("path", .str cleanRef), ("kind", .str "file")]]
            else #[]
          results := results.push (.obj #[("reference", .str refStr), ("matches", .arr matchesArr)])
      return .ok (.obj #[("results", .arr results)])
    else
      let lstDir ← OrbBin.PosixExt.statPath targetFp.toString
      if !lstDir.exists_ || !lstDir.isDir || lstDir.isSymlink then
        return .error "Directory not found"
      let some targetReal ← canonicalizeExistingPath? targetFp.toString
        | return .error "Directory not found"
      if !isCanonicalWithinRoot targetReal rootReal then
        return .error "Refusing to list directory outside browsed workspace"
      try
        let dirEntries ← (System.FilePath.mk targetReal).readDir
        let mut out : Array JVal := #[]
        for entry in dirEntries do
          let name := entry.fileName
          if !name.isEmpty && name != "." && name != ".." then
            let elst ← OrbBin.PosixExt.statPath entry.path.toString
            if !elst.isSymlink then
              if let some erp ← canonicalizeExistingPath? entry.path.toString then
                if isCanonicalWithinRoot erp rootReal then
                  let m? ← try pure (some (← entry.path.metadata)) catch _ => pure none
                  let kind := if elst.isDir then "dir" else "file"
                  let sz := match m? with | some m => m.byteSize.toNat | none => 0
                  let entryPath := if cleanRel.isEmpty then name else s!"{cleanRel}/{name}"
                  out := out.push (.obj #[("name", .str name), ("path", .str entryPath), ("kind", .str kind), ("size", JVal.nat sz)])
        let sorted := out.qsort fun a b =>
          let ka := (a.fieldStr? "kind").getD "file"
          let kb := (b.fieldStr? "kind").getD "file"
          if ka != kb then ka == "dir"
          else ((a.fieldStr? "name").getD "") < ((b.fieldStr? "name").getD "")
        return .ok (.obj #[("entries", .arr sorted)])
      catch _ =>
        return .ok (.obj #[("entries", .arr #[])])
  | "local_machine_identity" =>
    let mid ← ensureMachineId stRef
    return .ok (.str mid)
  | "local_machine_transfer" =>
    handleLocalMachineTransfer stRef args
  | "project_context_file" | "project_context_status" | "project_context_sync"
  | "project_context_prepare" | "project_skills_prepare"
  | "project_context_disconnect" | "project_context_stop" =>
    -- Return `.null` when no local replica exists so callers cleanly use Core's `/api/projects/:slug/files` endpoints.
    return .ok .null
  | "local_session_git" =>
    let cwd := (args.fieldStr? "cwd").getD ""
    if cwd.trimAscii.toString.isEmpty then return .ok .null
    match ← readCommandStdout? "git" #["-C", cwd.trimAscii.toString, "rev-parse", "--show-toplevel"] with
    | none => return .ok .null
    | some top =>
      let repoName := (System.FilePath.mk top).fileName.getD top
      let branch? ← readCommandStdout? "git" #["-C", cwd.trimAscii.toString, "symbolic-ref", "--short", "HEAD"]
      let branchVal : JVal := match branch? with | some b => (if b.isEmpty then .null else .str b) | none => .null
      return .ok (.obj #[("repository", .str repoName), ("branch", branchVal)])
  | "mistral_usage_sign_in" =>
    return .ok .null
  | "github_oauth_sign_in" =>
    let apiUrl := ((args.fieldStr? "apiUrl").orElse (fun _ => args.fieldStr? "api_url")).getD st.bridge.configuredTarget
    let state? := args.fieldStr? "state"
    runGitHubDesktopOAuth st.hostOs apiUrl state?
  | "local_skills_status" =>
    let reqObj := (args.field? "request").getD args
    let libSkills := (reqObj.fieldArr? "library_skills").getD #[]
    let requestedApiUrl? := (reqObj.fieldStr? "api_url").orElse (fun _ => reqObj.fieldStr? "apiUrl")
    let report ← buildLocalSkillsReport st libSkills requestedApiUrl?
    return .ok report
  | "local_skills_sync" =>
    let reqObj := (args.field? "request").getD args
    let libSkills := (reqObj.fieldArr? "library_skills").getD #[]
    let pruneRemoved := (reqObj.fieldBool? "prune_removed").getD false
    let replaceUnmanaged := ((reqObj.fieldArr? "replace_unmanaged").getD #[]).filterMap (·.asStr?)
    let mcpSess? := (reqObj.field? "mcp_session").filter (!·.isNull)
    let requestedApiUrl? := ((reqObj.fieldStr? "api_url").orElse (fun _ => reqObj.fieldStr? "apiUrl")).orElse
      (fun _ => mcpSess?.bind (·.fieldStr? "api_url"))
    let envHome := (← IO.getEnv "HOME").getD "/tmp"
    let homeStr := if st.homeDir.trimAscii.toString.isEmpty then envHome else st.homeDir
    let homeFp := System.FilePath.mk homeStr
    let (catalog, _) ← buildCanonicalSkillCatalog homeFp libSkills
    let desiredEntries := catalog.filter (·.desiredLocal)
    let desiredNames := desiredEntries.map (·.name)
    let prune := pruneRemoved && !libSkills.isEmpty
    let mut harnessesUpdated : Nat := 0
    let mut skippedUnmanaged : Array String := #[]
    let mut skippedNames : Array String := #[]
    let mut pruned : Array String := #[]
    let installSkillEntry (sdir : System.FilePath) (entry : CanonicalSkillEntry) : IO Bool := do
      try
        let sdirSt ← OrbBin.PosixExt.statPath sdir.toString
        if sdirSt.exists_ || sdirSt.isSymlink then
          if sdirSt.isSymlink then
            IO.FS.removeFile sdir
          else
            IO.FS.removeDirAll sdir
        IO.FS.createDirAll sdir
        if let some srcDir := entry.copyDir? then
          let srcEntries ← try srcDir.readDir catch _ => pure #[]
          for se in srcEntries do
            let fname := se.fileName
            if fname != ".git" && fname != ".DS_Store" then
              let seSt ← OrbBin.PosixExt.statPath se.path.toString
              if seSt.exists_ && seSt.isReg && !seSt.isSymlink then
                let bytes ← IO.FS.readBinFile se.path
                IO.FS.writeBinFile (sdir / fname) bytes
        else
          IO.FS.writeFile (sdir / "SKILL.md") entry.content
          for (rawRel, rfContent) in entry.files do
            if let some cleanRel := isSafeRelSubpath rawRel then
              if !isSecretRelPath cleanRel && cleanRel != "SKILL.md" &&
                 cleanRel != ".managed-by-orb-skills" && cleanRel != ".managed-by-agent-skills-repo" then
                let rfp := sdir / cleanRel
                if let some rp := rfp.parent then IO.FS.createDirAll rp
                IO.FS.writeFile rfp rfContent
        IO.FS.writeFile (sdir / ".managed-by-orb-skills") "managed-by-orb-skills\n"
        return true
      catch _ =>
        return false
    for (hid, _) in skillHarnessDisplayNames do
      if let some (globalRel, _) := harnessSkillTargets hid then
        let gdir := homeFp / globalRel
        let gdirMeta ← OrbBin.PosixExt.statPath gdir.toString
        if !gdirMeta.isSymlink then
          let mut touchedHarness := false
          try IO.FS.createDirAll gdir catch _ => pure ()
          for entry in desiredEntries do
            let sname := entry.name
            let sdir := gdir / sname
            let sdirSt ← OrbBin.PosixExt.statPath sdir.toString
            if sdirSt.isSymlink then
              -- Preserve unbroken user symlinks; replace broken ones.
              let targetExists ← sdir.pathExists
              if !targetExists then
                if (← installSkillEntry sdir entry) then touchedHarness := true
            else if sdirSt.exists_ && sdirSt.isDir then
              let md := sdir / "SKILL.md"
              let existingMd ← try IO.FS.readFile md catch _ => pure ""
              let same := normalizeSkillBody existingMd == normalizeSkillBody entry.content
              let isManaged ← isManagedSkillDir sdir
              if !isManaged then
                if same then
                  -- Adopt identical unmanaged copy without overwriting reference files.
                  try IO.FS.writeFile (sdir / ".managed-by-orb-skills") "managed-by-orb-skills\n" catch _ => pure ()
                else if replaceUnmanaged.contains sname then
                  if (← installSkillEntry sdir entry) then touchedHarness := true
                else
                  let skipPath := s!"~/{globalRel}/{sname}"
                  if !(skippedUnmanaged.contains skipPath) then skippedUnmanaged := skippedUnmanaged.push skipPath
                  if !(skippedNames.contains sname) then skippedNames := skippedNames.push sname
              else
                if same && entry.copyDir?.isSome then
                  pure ()
                else
                  let ok ← installSkillEntry sdir entry
                  if ok && !same then touchedHarness := true
            else
              if (← installSkillEntry sdir entry) then touchedHarness := true
          if prune then
            let entries ← try gdir.readDir catch _ => pure #[]
            for ent in entries do
              let sname := ent.fileName
              if validSkillIdentifier sname && !(desiredNames.contains sname) then
                let entSt ← OrbBin.PosixExt.statPath ent.path.toString
                if entSt.exists_ && entSt.isDir && !entSt.isSymlink then
                  if (← isManagedSkillDir ent.path) then
                    try
                      IO.FS.removeDirAll ent.path
                      touchedHarness := true
                      let pPath := s!"~/{globalRel}/{sname}"
                      if !(pruned.contains pPath) then pruned := pruned.push pPath
                    catch _ => pure ()
          if touchedHarness then harnessesUpdated := harnessesUpdated + 1
    let mut mcpErr? : Option String := none
    if let some sessObj := mcpSess? then
      if let .error e ← persistLocalMcpSession homeFp sessObj then
        mcpErr? := some e
    let mut mcpSyncedNow : Array String := #[]
    let credSt ← inspectLocalMcpCredential homeFp requestedApiUrl?
    if credSt.ready then
      if let some binPath ← resolveSandboxedMcpBin? st homeFp then
        mcpSyncedNow ← syncLocalHarnessesMcp homeFp binPath credSt.targetApiUrl credSt.role (replaceUnmanaged.contains "sandboxed")
    let syncedSkills := desiredNames.filter (fun n => !(skippedNames.contains n)) |>.size
    let report ← buildLocalSkillsReport st libSkills requestedApiUrl?
    return .ok (.obj #[
      ("synced_skills", JVal.nat syncedSkills),
      ("harnesses_updated", JVal.nat harnessesUpdated),
      ("skipped_unmanaged", .arr (skippedUnmanaged.map .str)),
      ("pruned", .arr (pruned.map .str)),
      ("mcp_synced_harnesses", .arr (mcpSyncedNow.map .str)),
      ("mcp_error", match mcpErr? with | some e => .str e | none => .null),
      ("report", report)
    ])
  | "local_interaction" =>
    let runId := (((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).orElse
      (fun _ => args.fieldStr? "runId")).getD ""
    let reqId? := (((args.fieldStr? "request_id").orElse (fun _ => args.fieldStr? "requestId")).orElse
      (fun _ => (args.field? "payload").bind (·.fieldStr? "id")))
    let epoch? := (args.fieldUInt64? "session_epoch").orElse (fun _ => args.fieldUInt64? "sessionEpoch")
    let action? := (args.fieldStr? "action").map (·.trimAscii.toString.toLower)
    match action? with
    | none =>
      if reqId?.isNone then
        return .ok (st.activeInteractionJson runId)
      else
        let reqId := reqId?.getD ""
        let curEp := ((st.toolHub.findRun? runId.trimAscii.toString).map (·.currentEpoch)).getD 1
        let ep := epoch?.getD curEp
        let payload := ((args.field? "payload").orElse (fun _ => args.field? "request")).getD
          (.obj #[("id", .str reqId), ("method", .str ((args.fieldStr? "method").getD "questions")),
                  ("params", (args.field? "params").getD (.obj #[]))])
        let res : Except String JVal ← stRef.modifyGet fun s =>
          match s.toolHub.admitSlot runId ep reqId payload false with
          | .error e => (.error e, s)
          | .ok (slot, replayed, nextHub) =>
            let s' := ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
            let body := (slot.toSummaryJson.setField "idempotent_replay" (.bool replayed)).setField
              "active_slots" (JVal.nat ((nextHub.findRun? runId.trimAscii.toString).map (·.activeCount) |>.getD 0))
            (.ok body, s')
        return res
    | some "register" | some "offer_early" =>
      let isEarly := action? == some "offer_early"
      let reqId := reqId?.getD ""
      let res : Except String JVal ← stRef.modifyGet fun s =>
        let curEp := ((s.toolHub.findRun? runId.trimAscii.toString).map (·.currentEpoch)).getD 1
        let ep := epoch?.getD curEp
        let payload := ((args.field? "payload").orElse (fun _ => args.field? "request")).getD
          (.obj #[("id", .str reqId), ("method", .str ((args.fieldStr? "method").getD "questions")),
                  ("params", (args.field? "params").getD (.obj #[]))])
        let hub0 : InteractiveToolHubState := match args.fieldNat? "max_cap" with
          | some cap =>
            let clamped := min cap 65535
            { s.toolHub with maxCap := UInt16.ofNat clamped }
          | none     => s.toolHub
        match hub0.admitSlot runId ep reqId payload isEarly with
        | .error e =>
          let sKeep := if hub0.maxCap ≥ 1 && hub0.maxCap ≤ 256 then { s with toolHub := hub0 } else s
          (.error e, sKeep)
        | .ok (slot, replayed, nextHub) =>
          let s' := ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
          let body := (slot.toSummaryJson.setField "idempotent_replay" (.bool replayed)).setField
            "active_slots" (JVal.nat ((nextHub.findRun? runId.trimAscii.toString).map (·.activeCount) |>.getD 0))
          (.ok body, s')
      return res
    | some "respond" | some "answer" =>
      let reqId := reqId?.getD ""
      let ansVal := ((args.field? "answer").orElse (fun _ => args.field? "response")).getD .null
      let res : Except String JVal ← stRef.modifyGet fun s =>
        match s.toolHub.answerSlot runId epoch? reqId ansVal with
        | .error e => (.error e, s)
        | .ok (slot, nextHub) =>
          let s' := ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
          (.ok slot.toSummaryJson, s')
      if res.isOk && !runId.trimAscii.toString.isEmpty then
        let mgr ← ensureWarmManager stRef
        discard <| OrbBin.ClaudeControl.respondToControlRequest mgr runId.trimAscii.toString reqId.trimAscii.toString ansVal
      return res
    | some "poll" =>
      let cleanRun := runId.trimAscii.toString
      match st.toolHub.findRun? cleanRun with
      | none =>
        return .ok (if reqId?.isSome then .null else .obj #[("run_id", .str cleanRun), ("session_epoch", JVal.uint64 1), ("active_slots", JVal.nat 0), ("slots", .arr #[])])
      | some tbl =>
        match reqId? with
        | some rq =>
          let targetEp := epoch?.getD tbl.currentEpoch
          match tbl.slots.find? (fun sl => sl.sessionEpoch == targetEp && sl.requestId == rq.trimAscii.toString) with
          | some sl => return .ok sl.toSummaryJson
          | none    => return .ok .null
        | none =>
          return .ok (.obj #[
            ("run_id", .str tbl.runId),
            ("session_epoch", JVal.uint64 tbl.currentEpoch),
            ("active_slots", JVal.nat tbl.activeCount),
            ("active_request", st.activeInteractionJson cleanRun),
            ("slots", .arr (tbl.slots.map InteractiveToolSlot.toSummaryJson))
          ])
    | some "cancel_run" =>
      let reason := (args.fieldStr? "reason").getD "run_cancelled"
      let bump := (args.fieldBool? "bump_epoch").getD true
      let out ← stRef.modifyGet fun s =>
        let (cancelledCount, nextEp, nextHub) := s.toolHub.cancelRunSlots runId reason bump
        let s' := ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
        (.obj #[
          ("run_id", .str runId.trimAscii.toString),
          ("cancelled_slots", JVal.nat cancelledCount),
          ("session_epoch", JVal.uint64 nextEp)
        ], s')
      return .ok out
    | some "reconcile" =>
      let res : Except String JVal ← stRef.modifyGet fun s =>
        match s.toolHub.reconcileRun runId epoch? with
        | .error e => (.error e, s)
        | .ok (tbl, nextHub) =>
          let s' := { s with toolHub := nextHub }
          let activeArr := (tbl.slots.filter fun sl => sl.sessionEpoch == tbl.currentEpoch && sl.lifecycle.isActive).map
            InteractiveToolSlot.toSummaryJson
          (.ok (.obj #[
            ("run_id", .str tbl.runId),
            ("session_epoch", JVal.uint64 tbl.currentEpoch),
            ("active_slots", JVal.nat activeArr.size),
            ("active_request", s'.activeInteractionJson tbl.runId),
            ("pending", .arr activeArr),
            ("slots", .arr (tbl.slots.map InteractiveToolSlot.toSummaryJson))
          ]), s')
      return res
    | some other =>
      return .error s!"unsupported local_interaction action: {other}"
  | "local_interaction_answer" =>
    let runId := (((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).orElse
      (fun _ => args.fieldStr? "runId")).getD ""
    let reqId := ((args.fieldStr? "requestId").orElse (fun _ => args.fieldStr? "request_id")).getD ""
    let epoch? := (args.fieldUInt64? "session_epoch").orElse (fun _ => args.fieldUInt64? "sessionEpoch")
    let ansVal := ((args.field? "answer").orElse (fun _ => args.field? "response")).getD .null
    let res : Except String JVal ← stRef.modifyGet fun s =>
      match s.toolHub.answerSlot runId epoch? reqId ansVal with
      | .error e => (.error e, s)
      | .ok (_, nextHub) =>
        let s' := ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
        (.ok .null, s')
    if res.isOk && !runId.trimAscii.toString.isEmpty then
      let mgr ← ensureWarmManager stRef
      discard <| OrbBin.ClaudeControl.respondToControlRequest mgr runId.trimAscii.toString reqId.trimAscii.toString ansVal
    return res
  | "local_wakeups_sync" =>
    return .ok (.obj #[("pending", .arr #[]), ("changed", .bool false), ("cancelled", .arr #[])])
  | "local_wakeups_cancel" | "local_wakeups_discard" =>
    return .ok .null
  | "local_origin_confirm" =>
    ensurePersistedOriginsLoaded stRef
    let cur ← stRef.get
    let connObj := (args.field? "connection").getD args
    let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD cur.bridge.configuredTarget
    let ep := normalizeEndpointKey epRaw
    if let some statusNat := (args.fieldNat? "http_status").orElse (fun _ => args.fieldNat? "httpStatus") then
      let code := ((args.fieldStr? "conflict_code").orElse (fun _ => args.fieldStr? "conflictCode")).getD ""
      let statusU16 := UInt16.ofNat (min statusNat 65535)
      let targetId := ((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "mission_id")).getD ""
      match classifyLocalOriginConflict statusU16 code with
      | none => return .error "unclassified_local_origin_conflict"
      | some (tag, retryable) =>
        let tagName := conflictTagName tag
        if !targetId.trimAscii.toString.isEmpty then
          let stAfter ← stRef.modifyGet fun s =>
            let cleanId := targetId.trimAscii.toString
            let updated := s.localOrigins.map fun row =>
              if row.id == cleanId && (ep.isEmpty || row.endpoint.isEmpty || row.endpoint == ep) then
                { row with
                    localSyncPending := retryable
                    localRunActive := if retryable then row.localRunActive else false
                    status := if retryable then row.status else (if tag == 3 then "completed" else "failed")
                    lastConflictCode := some tagName
                    retryableConflict := retryable }
              else row
            let s' := { s with localOrigins := updated }
            (s', s')
          persistOriginsSnapshot stAfter
        return .ok (.obj #[
          ("conflict_tag", JVal.nat tag.toNat),
          ("conflict_code", .str tagName),
          ("retry", .bool retryable)
        ])
    let confs := (args.fieldArr? "confirmations").getD #[]
    let stAfter ← stRef.modifyGet fun s =>
      let nextRows := confs.foldl (fun acc c =>
        let cid := (c.fieldStr? "id").getD ""
        if cid.isEmpty then acc
        else
          let obsAt := (c.fieldUInt64? "observed_at").getD 0
          let isDel := (c.fieldBool? "deleted").getD false
          if isDel then
            acc.filter (fun row => !(row.id == cid && (ep.isEmpty || row.endpoint.isEmpty || row.endpoint == ep) && !row.localSyncPending))
          else
            acc.map fun row =>
              if row.id != cid || (!ep.isEmpty && !row.endpoint.isEmpty && row.endpoint != ep) then row
              else if row.localSyncPending && !(c.fieldBool? "synced").getD false then row
              else if obsAt < row.observedAt then row
              else
                let nextSt := (c.fieldStr? "status").getD row.status
                let nextTitle := match c.fieldStr? "title" with | some t => t | none => row.title
                let clearSync := (c.fieldBool? "synced").getD false
                let clearRun := (c.fieldBool? "run_active").getD (if clearSync then false else row.localRunActive)
                { row with
                    status := nextSt
                    title := nextTitle
                    localSyncPending := if clearSync then false else row.localSyncPending
                    localRunActive := clearRun
                    observedAt := obsAt }) s.localOrigins
      let s' := { s with localOrigins := nextRows }
      (s', s')
    persistOriginsSnapshot stAfter
    return .ok .null
  | "local_origin_disconnect" =>
    ensurePersistedOriginsLoaded stRef
    let connObj := (args.field? "connection").getD args
    let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD ""
    let ep := normalizeEndpointKey epRaw
    let stAfter ← stRef.modifyGet fun s =>
      let nextCl :=
        if ep.isEmpty || s.clientLink.endpoint == ep then
          { s.clientLink with connected := false }
        else
          s.clientLink
      let nextRows :=
        if ep.isEmpty then #[]
        else s.localOrigins.filter (fun row => row.endpoint != ep)
      let s' := { s with clientLink := nextCl, localOrigins := nextRows }
      (s', s')
    persistOriginsSnapshot stAfter
    return .ok .null
  | "local_agents_stop" =>
    ensurePersistedOriginsLoaded stRef
    let runId := (((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).orElse
      (fun _ => args.fieldStr? "runId")).getD ""
    if !runId.trimAscii.toString.isEmpty then
      let cleanId := runId.trimAscii.toString
      let bump := (args.fieldBool? "bump_epoch").getD true
      let stAfter ← stRef.modifyGet fun s =>
        let (_, _, nextHub) := s.toolHub.cancelRunSlots cleanId "stopped" bump
        let nextOrigins := s.localOrigins.map fun row =>
          if row.id == cleanId then
            { row with
              localRunActive := false
              status := if row.status == "active" then "interrupted" else row.status
              syncSeq := if row.localSyncPending && row.status == "active" then row.syncSeq + 1 else row.syncSeq }
          else row
        let s' := ({ s with toolHub := nextHub, localOrigins := nextOrigins }).publishInteractionSnapshot cleanId
        (s', s')
      let mgr ← ensureWarmManager stRef
      OrbBin.ClaudeControl.stopHarnessRun mgr cleanId
      persistOriginsSnapshot stAfter
    return .ok .null
  | "local_run_reconcile" =>
    let runId := (((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).orElse
      (fun _ => args.fieldStr? "runId")).getD ""
    let epoch? := (args.fieldUInt64? "session_epoch").orElse (fun _ => args.fieldUInt64? "sessionEpoch")
    let includeSummary := (args.fieldBool? "include_slots").getD (epoch?.isSome)
    if runId.trimAscii.toString.isEmpty then
      return .ok .null
    let cleanRunId := runId.trimAscii.toString
    if !includeSummary then
      let mgr ← ensureWarmManager stRef
      if let some activeRs ← OrbBin.ClaudeControl.getRunState? mgr cleanRunId then
        if !activeRs.done then
          return .error "This mission is still running locally or waiting for your answer."
    let res : Except String JVal ← stRef.modifyGet fun s =>
      match s.toolHub.reconcileRun cleanRunId epoch? with
      | .error e => (.error e, s)
      | .ok (tbl, nextHub) =>
        let s' := { s with toolHub := nextHub }
        if includeSummary then
          let activeArr := (tbl.slots.filter fun sl => sl.sessionEpoch == tbl.currentEpoch && sl.lifecycle.isActive).map
            InteractiveToolSlot.toSummaryJson
          (.ok (.obj #[
            ("run_id", .str tbl.runId),
            ("session_epoch", JVal.uint64 tbl.currentEpoch),
            ("active_slots", JVal.nat activeArr.size),
            ("active_request", s'.activeInteractionJson tbl.runId),
            ("pending", .arr activeArr)
          ]), s')
        else
          (.ok (.bool false), s')
    match res with
    | .error e => return .error e
    | .ok outJv =>
      if includeSummary then
        return .ok outJv
      ensurePersistedOriginsLoaded stRef
      let curSt ← stRef.get
      let connObj := (args.field? "connection").getD args
      let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD curSt.bridge.configuredTarget
      let tokRaw := (connObj.fieldStr? "token").getD ""
      match ← reconcileCoreClientRunIfSupported stRef cleanRunId epRaw tokRaw with
      | .error e => return .error e
      | .ok (some settled) => return .ok (.bool settled)
      | .ok none => return .ok (.bool false)
  | "local_agents_poll" =>
    let runId := (((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).orElse
      (fun _ => args.fieldStr? "runId")).getD ""
    if runId.trimAscii.toString.isEmpty then
      return .ok (.obj #[("text", .str ""), ("done", .bool true), ("resumed", .bool false)])
    let mgr ← ensureWarmManager stRef
    match ← OrbBin.ClaudeControl.getRunState? mgr runId.trimAscii.toString with
    | some rs => return .ok rs.toPollJVal
    | none => return .ok (.obj #[("text", .str ""), ("done", .bool true), ("resumed", .bool false)])
  | "local_codex_speed_options" =>
    return .ok (.obj #[
      ("tiers", .arr #[
        .obj #[("id", .str "standard"), ("available", .bool true)],
        .obj #[("id", .str "fast"), ("available", .bool true)]
      ])
    ])
  | "local_agents_cyber_capabilities" =>
    return .ok (JVal.nat 2)
  | "local_invocable_skills" =>
    let cwd := (args.fieldStr? "cwd").getD "."
    let harness := (args.fieldStr? "harness").getD ""
    let some home ← OrbBin.PosixExt.firstEnvNonEmpty ["ORB_SKILLS_TEST_HOME", "HOME"]
      | do
        if !st.homeDir.isEmpty then
          match ← invocableSkillsIn (System.FilePath.mk st.homeDir) (System.FilePath.mk cwd) harness with
          | .error e => return .error e
          | .ok skills =>
            return .ok (.arr (skills.map fun s => .obj #[
              ("name", .str s.name),
              ("description", match s.description with | some d => .str d | none => .null),
              ("path", .str s.path)
            ]))
        return .error "HOME is not set"
    match ← invocableSkillsIn (System.FilePath.mk home) (System.FilePath.mk cwd) harness with
    | .error e => return .error e
    | .ok skills =>
      return .ok (.arr (skills.map fun s => .obj #[
        ("name", .str s.name),
        ("description", match s.description with | some d => .str d | none => .null),
        ("path", .str s.path)
      ]))
  | "local_origin_launch" | "local_run_launch" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let reqObj := (args.field? "request").getD args
    let harness := (reqObj.fieldStr? "harness").getD ""
    let binPath := (reqObj.fieldStr? "bin").getD ""
    let cwd := (reqObj.fieldStr? "cwd").getD "."
    let prompt := (reqObj.fieldStr? "prompt").getD (((args.field? "draft").bind (·.fieldStr? "prompt")).getD "")
    let rawModel := (reqObj.fieldStr? "model").getD ""
    let model ←
      if harness == "opencode" then
        let homeOv? := if curSt.homeDir.trimAscii.toString.isEmpty then none else some curSt.homeDir.trimAscii.toString
        let reqMdl? := if rawModel.trimAscii.toString.isEmpty then none else some rawModel
        let (defModel?, provNames, cfgModels) ← OrbBin.ClaudeControl.readLocalOpenCodeConfigInfo homeOv?
        let firstChoice := (OrbBin.ClaudeControl.resolveOpenCodeModelForLocal
          reqMdl? defModel? (provNames.map Prod.fst) cfgModels).getD rawModel
        let needsCliProbe :=
          defModel?.isNone && cfgModels.isEmpty && !binPath.trimAscii.toString.isEmpty &&
          (let t := rawModel.trimAscii.toString
           t.isEmpty || t.startsWith "builtin/" || t.startsWith "sandboxed-sh/" || !(t.contains '/'))
        if needsCliProbe then
          match ← OrbBin.ClaudeControl.probeOpenCodeModels binPath homeOv? with
          | .ok probed =>
            let probedIds := probed.map Prod.fst
            pure ((OrbBin.ClaudeControl.resolveOpenCodeModelForLocal reqMdl? probedIds[0]? #[] probedIds).getD firstChoice)
          | .error _ => pure firstChoice
        else
          pure firstChoice
      else
        pure rawModel
    let effort? := (reqObj.fieldStr? "effort").filter (!·.trimAscii.toString.isEmpty)
    let svcTier? := (reqObj.fieldStr? "service_tier").orElse (fun _ => reqObj.fieldStr? "serviceTier")
    let sessionId? := ((reqObj.fieldStr? "session_id").orElse (fun _ => reqObj.fieldStr? "sessionId")).filter (!·.trimAscii.toString.isEmpty)
    let planMode := (reqObj.fieldBool? "planMode").getD ((reqObj.fieldBool? "plan_mode").getD false)
    let permModeStr := ((reqObj.fieldStr? "permission_mode").orElse (fun _ => reqObj.fieldStr? "permissionMode")).getD "bypassPermissions"
    let permMode := OrbBin.ClaudeControl.parsePermissionMode permModeStr
    let worktreeMode := ((reqObj.fieldStr? "worktree_mode").orElse (fun _ => reqObj.fieldStr? "worktreeMode")).getD "local"
    let cyber := (reqObj.fieldStr? "cyberAccess").getD ((reqObj.fieldStr? "cyber_access").getD "automatic")
    let rawImgs := ((reqObj.fieldArr? "image_paths").orElse (fun _ => reqObj.fieldArr? "imagePaths")).getD #[]
    let imgPaths := rawImgs.filterMap JVal.asStr?
    let hasImgs := !imgPaths.isEmpty
    let mut selectedSkills : Array (String × String × UInt8) := #[]
    if !harness.isEmpty then
      let home? ← do
        match ← OrbBin.PosixExt.firstEnvNonEmpty ["ORB_SKILLS_TEST_HOME", "HOME"] with
        | some h => pure (some h)
        | none => pure (if curSt.homeDir.isEmpty then none else some curSt.homeDir)
      if let some home := home? then
        match ← selectLocalSkillsIn (System.FilePath.mk home) (System.FilePath.mk cwd) harness prompt with
        | .error e => return .error e
        | .ok sel => selectedSkills := sel
      if harness == "codex" then
        if let .error e := validateLocalCodexLaunch prompt model cyber hasImgs then
          return .error e
    let mut deliveredPrompt := withLocalSkillDirective prompt selectedSkills
    let rawRunUuid ← randomUuidV4
    let mut runReceiptId := (OrbBin.PosixExt.parseUuidCanonical? rawRunUuid).getD rawRunUuid
    let targetMissionId ←
      if cmd == "local_origin_launch" then
        let rawId ← randomUuidV4
        pure ((OrbBin.PosixExt.parseUuidCanonical? rawId).getD rawId)
      else
        let rid := ((reqObj.fieldStr? "id").orElse (fun _ => args.fieldStr? "id")).getD ""
        pure (if rid.trimAscii.toString.isEmpty then runReceiptId else rid.trimAscii.toString)

    let shouldSpawnProcess := !binPath.trimAscii.toString.isEmpty || ((reqObj.fieldBool? "spawn").getD false)
    if shouldSpawnProcess && cmd == "local_run_launch" then
      let mgr ← ensureWarmManager stRef
      if let some activeRs ← OrbBin.ClaudeControl.getRunState? mgr targetMissionId then
        if !activeRs.done then
          return .error "This mission is still running locally or waiting for your answer."

    let connObj := (args.field? "connection").getD args
    let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD curSt.bridge.configuredTarget
    let tokRaw := (connObj.fieldStr? "token").getD ""

    let mut nextGen : UInt64 ← stRef.modifyGet fun s =>
      let prevGen := ((s.runGenerations.find? (fun (k, _) => k == targetMissionId)).map Prod.snd).getD 0
      let g := prevGen + 1
      let others := s.runGenerations.filter (fun (k, _) => k != targetMissionId)
      (g, { s with runGenerations := others.push (targetMissionId, g) })

    let mut acquiredCoreReceipt := false
    if cmd == "local_run_launch" then
      match ← beginCoreClientRunIfSupported stRef targetMissionId epRaw tokRaw prompt cwd model svcTier? cyber sessionId? with
      | .error e => return .error e
      | .ok none => pure ()
      | .ok (some (coreRunId, coreGen, corePrompt)) =>
        acquiredCoreReceipt := true
        runReceiptId := coreRunId
        nextGen := coreGen
        deliveredPrompt := withLocalSkillDirective corePrompt selectedSkills
        stRef.modify fun s =>
          let others := s.runGenerations.filter (fun (k, _) => k != targetMissionId)
          { s with runGenerations := others.push (targetMissionId, coreGen) }
    if cmd == "local_origin_launch" then
      let initIso := formatUtcIso8601 (← OrbBin.PosixExt.nowEpoch)
      let draftObj := (args.field? "draft").getD (.obj #[])
      let title := ((draftObj.fieldStr? "title").orElse (fun _ => reqObj.fieldStr? "title")).getD "Local Mission"
      let proj := ((draftObj.fieldStr? "project").orElse (fun _ => reqObj.fieldStr? "project")).getD ""
      let draftPrompt := ((draftObj.fieldStr? "prompt").orElse (fun _ => reqObj.fieldStr? "prompt")).getD prompt
      let folder? := ((draftObj.fieldStr? "folder").orElse (fun _ => reqObj.fieldStr? "folder")).filter (!·.isEmpty)
      let rawTags := ((draftObj.fieldArr? "tags").getD #[]).filterMap (·.asStr?)
      let tags := if rawTags.contains "placement:client" then rawTags else rawTags.push "placement:client"
      let ep := normalizeEndpointKey epRaw
      let backendName := if harness.isEmpty then "opencode" else harness
      let initEntry : LocalOriginEntry := {
        id := targetMissionId
        runId := runReceiptId
        endpoint := ep
        title := title
        status := "active"
        backend := backendName
        workingDirectory := cwd
        rawPrompt := draftPrompt
        deliveredPrompt := deliveredPrompt
        localSyncPending := true
        localRunActive := true
        syncSeq := 1
        ackedSeq := 0
        project := proj
        folder := folder?
        tags := tags
        modelOverride := if model.isEmpty then none else some model
        modelEffort := effort?
        serviceTier := if backendName == "codex" then svcTier? else none
        cyberAccess := if backendName == "codex" then some cyber else none
        createdAt := initIso
        updatedAt := initIso
        history := #[.obj #[("role", .str "user"), ("content", .str draftPrompt)]]
      }
      stRef.modify fun s =>
        let kept := s.localOrigins.filter (fun r => r.id != targetMissionId)
        { s with localOrigins := kept.push initEntry }
    else
      let resumeIso := formatUtcIso8601 (← OrbBin.PosixExt.nowEpoch)
      let displayPrompt := ((reqObj.fieldStr? "display_prompt").orElse (fun _ => reqObj.fieldStr? "displayPrompt")).getD prompt
      let messageId? := ((reqObj.fieldStr? "message_id").orElse (fun _ => reqObj.fieldStr? "messageId")).map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      let cleanDisplay := displayPrompt.trimAscii.toString
      let autoResumePrompt := "Your previous turn was interrupted before it finished. Check what is already done, then continue from there. Do not redo finished work."
      let (stResumed, originChanged) ← stRef.modifyGet fun s =>
        let found := s.localOrigins.any (fun r => r.id == targetMissionId)
        let nextOrigins := s.localOrigins.map fun r =>
          if r.id == targetMissionId then
            let lastUserMatch :=
              match r.history.back? with
              | some lastJv =>
                lastJv.fieldStr? "role" == some "user" &&
                ((match messageId? with | some mid => lastJv.fieldStr? "id" == some mid | none => false) ||
                 (lastJv.fieldStr? "content").map (·.trimAscii.toString) == some cleanDisplay)
              | none => false
            let userEntryFields : Array (String × JVal) :=
              match messageId? with
              | some mid => #[("id", .str mid), ("role", .str "user"), ("content", .str displayPrompt)]
              | none => #[("role", .str "user"), ("content", .str displayPrompt)]
            let nextHist :=
              if !cleanDisplay.isEmpty && cleanDisplay != autoResumePrompt && !lastUserMatch then
                r.history.push (.obj userEntryFields)
              else
                r.history
            { r with
              localRunActive := true
              status := "active"
              statusMessage := none
              syncError := none
              modelOverride := if model.isEmpty then r.modelOverride else some model
              syncSeq := if r.localSyncPending then r.syncSeq + 1 else r.syncSeq
              updatedAt := resumeIso
              history := nextHist }
          else r
        let s' :=
          if found then
            ({ s with localOrigins := nextOrigins }).enqueueNamedEvent "orb-local-origins-changed" (.obj #[("id", .str targetMissionId)])
          else
            { s with localOrigins := nextOrigins }
        ((s', found), s')
      if originChanged then persistOriginsSnapshot stResumed

    let mut effectiveWorkingDir := cwd
    let mut activeSessionId? := sessionId?
    if !binPath.trimAscii.toString.isEmpty && !harness.isEmpty then
      let mut preFields : Array (String × JVal) := #[
        ("harness", .str harness),
        ("bin", .str binPath),
        ("cwd", .str cwd),
        ("planMode", .bool planMode),
        ("permissionMode", .str permMode.toUiWire)
      ]
      if !model.isEmpty then preFields := preFields.push ("model", .str model)
      if let some eff := effort? then preFields := preFields.push ("effort", .str eff)
      if let some sid := sessionId? then preFields := preFields.push ("sessionId", .str sid)
      let preVal := JVal.obj preFields
      stRef.modify fun s =>
        let kept := s.bindingsEntries.filter (fun (k, _) => k != targetMissionId)
        { s with bindingsEntries := kept.push (targetMissionId, preVal) }
    if shouldSpawnProcess && !harness.isEmpty then
      let mgr ← ensureWarmManager stRef
      let cbs : OrbBin.ClaudeControl.HarnessCallbacks := {
        onOutputEvent := fun ev => do
          stRef.modify fun s => s.publishChannelEvent "local_agents" ev (some targetMissionId)
        onControlRequest := fun ctrlReq => do
          let payload := JVal.obj #[
            ("id", .str ctrlReq.requestId),
            ("method", .str ctrlReq.method),
            ("params", ctrlReq.uiParams)
          ]
          stRef.modify fun s =>
            let curEp := ((s.toolHub.findRun? targetMissionId).map (·.currentEpoch)).getD 1
            match s.toolHub.admitSlot targetMissionId curEp ctrlReq.requestId payload false with
            | .ok (_, _, nextHub) =>
              ({ s with toolHub := nextHub }).publishInteractionSnapshot targetMissionId
            | .error _ => s
        onTurnFinished := fun finalRs => do
          let finIso := formatUtcIso8601 (← OrbBin.PosixExt.nowEpoch)
          let termStatus :=
            if finalRs.stopping || finalRs.exitCode? == some 137 || finalRs.exitCode? == some 143 then "interrupted"
            else if finalRs.error?.isSome || (finalRs.exitCode?.isSome && finalRs.exitCode? != some 0) then "failed"
            else "awaiting_user"
          let cleanTurnErr := finalRs.error?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
          let (stFin, bindChangedFin) ← stRef.modifyGet fun (s : LocaldState) =>
            let nextOrigins := s.localOrigins.map fun row =>
              if row.id == targetMissionId then
                let nextHist :=
                  if finalRs.text.trimAscii.toString.isEmpty then row.history
                  else row.history.push (.obj #[("role", .str "assistant"), ("content", .str finalRs.text)])
                let keepSyncPending := cmd == "local_origin_launch" || row.localSyncPending
                { row with
                  localRunActive := false
                  localSyncPending := keepSyncPending
                  syncSeq := if keepSyncPending then row.syncSeq + 1 else row.syncSeq
                  syncText := if keepSyncPending then finalRs.text else row.syncText
                  statusMessage := if termStatus == "failed" then cleanTurnErr else none
                  status := termStatus
                  updatedAt := finIso
                  history := nextHist }
              else row
            let (nextBinds, bChanged) :=
              match finalRs.sessionId? with
              | none => (s.bindingsEntries, false)
              | some sid =>
                let updated := s.bindingsEntries.map fun (bk, (bv : JVal)) =>
                  if bk == targetMissionId then (bk, JVal.setField bv "sessionId" (.str sid)) else (bk, bv)
                (updated, s.bindingsEntries.any (fun (bk, _) => bk == targetMissionId))
            let sBase := ({ s with localOrigins := nextOrigins, bindingsEntries := nextBinds }).enqueueNamedEvent
              "orb-local-origins-changed" (.obj #[("id", .str targetMissionId)])
            let s' :=
              if bChanged then
                let nextRev := sBase.bindingsRevision + 1
                let nextSnap : JVal := .obj #[("revision", JVal.nat nextRev), ("bindings", .obj nextBinds)]
                ({ sBase with bindingsRevision := nextRev }).publishChannelEvent "local_bindings" nextSnap
              else
                sBase
            ((s', bChanged), s')
          persistOriginsSnapshot stFin
          if bindChangedFin then persistBindingsSnapshot stFin
          let needsCoreSync :=
            !tokRaw.trimAscii.toString.isEmpty &&
            stFin.localOrigins.any (fun r => r.id == targetMissionId && r.localSyncPending && r.ackedSeq < r.syncSeq)
          if needsCoreSync then
            discard <| IO.asTask do
              syncLocalOriginToCore stRef targetMissionId epRaw tokRaw 2
      }
      match ← OrbBin.ClaudeControl.startHarnessTurn
          mgr targetMissionId harness binPath cwd deliveredPrompt nextGen
          (if model.isEmpty then none else some model) effort? sessionId?
          permMode worktreeMode imgPaths cbs with
      | .error e =>
        if acquiredCoreReceipt then
          let stSettle ← stRef.get
          discard <| settleCoreClientRunReceipt stSettle targetMissionId epRaw.trimAscii.toString tokRaw.trimAscii.toString runReceiptId nextGen
        if cmd == "local_origin_launch" then
          stRef.modify fun s =>
            { s with
              localOrigins := s.localOrigins.filter (fun r => r.id != targetMissionId)
              bindingsEntries := s.bindingsEntries.filter (fun (k, _) => k != targetMissionId) }
        return .error e
      | .ok rs =>
        effectiveWorkingDir := rs.cwd
        activeSessionId? := rs.sessionId?.orElse (fun _ => sessionId?)

    let cwdCanon? ← canonicalizeExistingPath? effectiveWorkingDir
    if !binPath.trimAscii.toString.isEmpty && !harness.isEmpty then
      let mut bindFields : Array (String × JVal) := #[
        ("harness", .str harness),
        ("bin", .str binPath),
        ("cwd", .str effectiveWorkingDir),
        ("planMode", .bool planMode),
        ("permissionMode", .str permMode.toUiWire)
      ]
      if !model.isEmpty then bindFields := bindFields.push ("model", .str model)
      if let some eff := effort? then bindFields := bindFields.push ("effort", .str eff)
      let latestSid? ← do
        if let some s := activeSessionId? then pure (some s)
        else
          let mgr ← ensureWarmManager stRef
          pure ((← OrbBin.ClaudeControl.getRunState? mgr targetMissionId).bind (·.sessionId?))
      let stBind ← stRef.modifyGet fun s =>
        let existingSid? :=
          (s.bindingsEntries.find? (fun (k, _) => k == targetMissionId)).bind (fun (_, bv) => bv.fieldStr? "sessionId")
        let mergedSid? := latestSid?.orElse (fun _ => existingSid?)
        let finalFields := match mergedSid? with
          | some sid => bindFields.push ("sessionId", .str sid)
          | none => bindFields
        let bindVal := JVal.obj finalFields
        let filtered := s.bindingsEntries.filter (fun (k, _) => k != targetMissionId)
        let nextEntries := filtered.push (targetMissionId, bindVal)
        let nextRev := s.bindingsRevision + 1
        let nextSnap : JVal := .obj #[("revision", JVal.nat nextRev), ("bindings", .obj nextEntries)]
        let sPub := ({ s with bindingsRevision := nextRev, bindingsEntries := nextEntries }).publishChannelEvent "local_bindings" nextSnap
        (sPub, sPub)
      persistBindingsSnapshot stBind

    if let some rp := cwdCanon? then
      if rp != "/" then
        stRef.modify fun s =>
          if s.grantedBrowseRoots.contains rp then s else { s with grantedBrowseRoots := s.grantedBrowseRoots.push rp }

    if cmd == "local_origin_launch" then
      let (stAfter, retJson) ← stRef.modifyGet fun s =>
        let nextOrigins := s.localOrigins.map fun r =>
          if r.id == targetMissionId then { r with workingDirectory := effectiveWorkingDir } else r
        let s' := { s with localOrigins := nextOrigins }
        let outJv := (nextOrigins.find? (fun r => r.id == targetMissionId)).map LocalOriginEntry.toMissionJson |>.getD (.obj #[])
        ((s', outJv), s')
      persistOriginsSnapshot stAfter
      if !tokRaw.trimAscii.toString.isEmpty then
        discard <| IO.asTask do
          syncLocalOriginToCore stRef targetMissionId epRaw tokRaw 2
      return .ok retJson
    return .ok (.obj #[
      ("ok", .bool true),
      ("command", .str cmd),
      ("run_id", .str runReceiptId),
      ("generation", JVal.uint64 nextGen),
      ("cwd", .str effectiveWorkingDir),
      ("delivered_prompt", .str deliveredPrompt)
    ])
  | "local_checkpoints_list" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let cwdRaw := (args.fieldStr? "cwd").getD ""
    let some safeCwd ← checkCanonicalBrowseRoot curSt cwdRaw
      | return .error "Local folder was not granted for checkpoints"
    let mid := ((args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id")).getD ""
    match ← OrbBin.GitWorkspace.listCheckpoints safeCwd mid with
    | .ok cps => return .ok (.obj #[("checkpoints", .arr (cps.map OrbBin.GitWorkspace.CheckpointMeta.toJVal))])
    | .error e => return .error e
  | "local_checkpoint_diff" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let cwdRaw := (args.fieldStr? "cwd").getD ""
    let some safeCwd ← checkCanonicalBrowseRoot curSt cwdRaw
      | return .error "Local folder was not granted for checkpoint diff"
    let fromRef := ((args.fieldStr? "from_ref").orElse (fun _ => args.fieldStr? "fromRef")).getD "HEAD"
    let toRef := ((args.fieldStr? "to_ref").orElse (fun _ => args.fieldStr? "toRef")).getD "WORKTREE"
    let since? := (args.fieldUInt64? "since_epoch").orElse (fun _ => args.fieldUInt64? "sinceEpoch")
    match ← OrbBin.GitWorkspace.diffCheckpoints safeCwd fromRef toRef since? with
    | .ok rep => return .ok rep.toJVal
    | .error e => return .error e
  | "local_checkpoint_restore" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let cwdRaw := (args.fieldStr? "cwd").getD ""
    let some safeCwd ← checkCanonicalBrowseRoot curSt cwdRaw
      | return .error "Local folder was not granted for checkpoint restore"
    let mid := ((args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id")).getD "local"
    let targetRef := ((args.fieldStr? "ref").orElse (fun _ => args.fieldStr? "target_ref")).getD ""
    let turn? := args.fieldNat? "turn"
    match ← OrbBin.GitWorkspace.restoreCheckpoint safeCwd mid targetRef turn? with
    | .ok res => return .ok res
    | .error e => return .error e
  | "local_worktree_status" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let cwdRaw := (args.fieldStr? "cwd").getD ""
    let some safeCwd ← checkCanonicalBrowseRoot curSt cwdRaw
      | return .error "Local folder was not granted for worktree status"
    let mid := ((args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id")).getD "new"
    let preferWt := ((args.fieldBool? "prefer_worktree").orElse (fun _ => args.fieldBool? "preferWorktree")).getD false
    let mgr ← ensureWarmManager stRef
    let otherCwds ← OrbBin.ClaudeControl.activeRunCwdsExcept mgr mid
    let stWt ← OrbBin.GitWorkspace.inspectWorktreeStatus safeCwd mid otherCwds preferWt
    return .ok stWt.toJVal
  | "local_worktree_create" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let cwdRaw := (args.fieldStr? "cwd").getD ""
    let some safeCwd ← checkCanonicalBrowseRoot curSt cwdRaw
      | return .error "Local folder was not granted for worktree creation"
    let mid := ((args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id")).getD "new"
    let baseBranch? := (args.fieldStr? "base_branch").orElse (fun _ => args.fieldStr? "baseBranch")
    match ← OrbBin.GitWorkspace.createMissionWorktree safeCwd mid baseBranch? with
    | .ok wt =>
      if let some wtCanon ← canonicalizeExistingPath? wt.worktreePath then
        if wtCanon != "/" then
          stRef.modify fun s =>
            if s.grantedBrowseRoots.contains wtCanon then s else { s with grantedBrowseRoots := s.grantedBrowseRoots.push wtCanon }
      return .ok wt.toJVal
    | .error e => return .error e
  | "local_worktree_remove" =>
    ensurePersistedBindingsLoaded stRef
    ensurePersistedOriginsLoaded stRef
    let curSt ← stRef.get
    let wtPath := ((args.fieldStr? "worktree_path").orElse (fun _ => args.fieldStr? "path")).getD ""
    let some wtCanon ← checkCanonicalBrowseRoot curSt wtPath
      | return .error "Worktree folder was not granted"
    let force := (args.fieldBool? "force").getD false
    match ← OrbBin.GitWorkspace.removeMissionWorktree wtCanon force with
    | .ok res => return .ok res
    | .error e => return .error e
  | "local_permission_mode_set" =>
    let mid := ((args.fieldStr? "mission_id").orElse (fun _ => args.fieldStr? "id")).getD ""
    let rawMode := (args.fieldStr? "mode").getD "bypassPermissions"
    let parsedMode := OrbBin.ClaudeControl.parsePermissionMode rawMode
    let mgr ← ensureWarmManager stRef
    let ok ← OrbBin.ClaudeControl.setSessionPermissionMode mgr mid parsedMode
    if !mid.trimAscii.toString.isEmpty then
      let stBind ← stRef.modifyGet fun (s : LocaldState) =>
        let nextEntries := s.bindingsEntries.map fun (bk, (bv : JVal)) =>
          if bk == mid.trimAscii.toString then (bk, JVal.setField bv "permissionMode" (.str parsedMode.toUiWire)) else (bk, bv)
        let s' := { s with bindingsEntries := nextEntries }
        (s', s')
      persistBindingsSnapshot stBind
    return .ok (.obj #[("ok", .bool ok), ("mode", .str parsedMode.toUiWire)])
  | _ =>
    if supportedDesktopCommands.contains cmd then
      return .error s!"{cmd} is not supported in this local runtime"
    else
      return .error s!"unknown desktop command: {cmd}"

/-- Escape a string safely as a JSON string literal (`"..."`) for JS embedding. -/
def jsStringLiteral (s : String) : String :=
  renderCompact (.str s)

/-- WebView initialization JavaScript injecting `window.__ORB_DESKTOP__` (with `__TAURI__` /
    `__TAURI_INTERNALS__` aliases) using captured `_fetch` / `_jsonStringify` closures (preventing
    `window.fetch` token theft) and zero-idle-poll SSE event streaming (`/__orb_events`). -/
def renderWebviewInitScript (rpcPort : UInt16) (launchToken : String) : String :=
  let urlLit := jsStringLiteral s!"http://127.0.0.1:{rpcPort}/__orb_rpc"
  let sseLit := jsStringLiteral s!"http://127.0.0.1:{rpcPort}/__orb_events"
  let tokLit := jsStringLiteral launchToken
  "(() => {\n" ++
  "  const _fetch = window.fetch.bind(window);\n" ++
  "  const _jsonStringify = JSON.stringify;\n" ++
  "  const _btoa = window.btoa.bind(window);\n" ++
  s!"  const ORB_LOCALD_URL = {urlLit};\n" ++
  s!"  const ORB_EVENTS_URL = {sseLit};\n" ++
  s!"  const ORB_TOKEN = {tokLit};\n" ++
  "  const listeners = new Map();\n" ++
  "  const channels = new Map();\n" ++
  "  let streamCtrl = null;\n" ++
  "  class Channel {\n" ++
  "    constructor() { this.onmessage = () => {}; }\n" ++
  "  }\n" ++
  "  function emitLocalEvent(name, payload) {\n" ++
  "    const set = listeners.get(name);\n" ++
  "    if (!set) return;\n" ++
  "    for (const fn of Array.from(set)) {\n" ++
  "      try { fn({ event: name, payload }); } catch {}\n" ++
  "    }\n" ++
  "  }\n" ++
  "  window.__ORB_EMIT__ = emitLocalEvent;\n" ++
  "  function dispatchSseItem(ev) {\n" ++
  "    if (!ev || typeof ev !== 'object') return;\n" ++
  "    if (typeof ev.event === 'string') emitLocalEvent(ev.event, ev.payload);\n" ++
  "    else if (typeof ev.token === 'number') channels.get(ev.token)?.onmessage(ev.payload);\n" ++
  "  }\n" ++
  "  function bytesToBase64(u8) {\n" ++
  "    let bin = '';\n" ++
  "    for (let i = 0; i < u8.length; i += 0x8000) {\n" ++
  "      bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));\n" ++
  "    }\n" ++
  "    return _btoa(bin);\n" ++
  "  }\n" ++
  "  async function drain() {\n" ++
  "    if (!channels.size) return;\n" ++
  "    try {\n" ++
  "      const tokens = Array.from(channels.keys());\n" ++
  "      const r = await _fetch(ORB_LOCALD_URL, {\n" ++
  "        method: 'POST',\n" ++
  "        headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },\n" ++
  "        body: _jsonStringify({ command: '__orb_poll_events', args: { tokens } })\n" ++
  "      });\n" ++
  "      const b = await r.json();\n" ++
  "      if (Array.isArray(b.result)) {\n" ++
  "        for (const ev of b.result) dispatchSseItem(ev);\n" ++
  "      }\n" ++
  "    } catch {}\n" ++
  "  }\n" ++
  "  function stopStream() {\n" ++
  "    if (streamCtrl) { streamCtrl.abort(); streamCtrl = null; }\n" ++
  "  }\n" ++
  "  function ensureStream() {\n" ++
  "    if (streamCtrl || (!channels.size && !listeners.size)) return;\n" ++
  "    const ctrl = new AbortController();\n" ++
  "    streamCtrl = ctrl;\n" ++
  "    (async () => {\n" ++
  "      while (!ctrl.signal.aborted && (channels.size || listeners.size)) {\n" ++
  "        try {\n" ++
  "          const r = await _fetch(ORB_EVENTS_URL, {\n" ++
  "            headers: { 'Accept': 'text/event-stream', 'X-Orb-Token': ORB_TOKEN },\n" ++
  "            signal: ctrl.signal\n" ++
  "          });\n" ++
  "          if (!r.ok || !r.body) throw new Error('sse');\n" ++
  "          const reader = r.body.getReader();\n" ++
  "          const dec = new TextDecoder();\n" ++
  "          let buf = '';\n" ++
  "          while (!ctrl.signal.aborted && (channels.size || listeners.size)) {\n" ++
  "            const { value, done } = await reader.read();\n" ++
  "            if (done) break;\n" ++
  "            buf += dec.decode(value, { stream: true });\n" ++
  "            let idx;\n" ++
  "            while ((idx = buf.indexOf('\\n\\n')) >= 0) {\n" ++
  "              const frame = buf.slice(0, idx);\n" ++
  "              buf = buf.slice(idx + 2);\n" ++
  "              for (const ln of frame.split('\\n')) {\n" ++
  "                if (ln.startsWith('data: ')) {\n" ++
  "                  const arr = JSON.parse(ln.slice(6));\n" ++
  "                  if (Array.isArray(arr)) for (const ev of arr) dispatchSseItem(ev);\n" ++
  "                }\n" ++
  "              }\n" ++
  "            }\n" ++
  "          }\n" ++
  "        } catch {\n" ++
  "          if (ctrl.signal.aborted || (!channels.size && !listeners.size)) break;\n" ++
  "          await new Promise(res => setTimeout(res, 1500));\n" ++
  "          if (!ctrl.signal.aborted && channels.size) await drain();\n" ++
  "        }\n" ++
  "      }\n" ++
  "      if (streamCtrl === ctrl) streamCtrl = null;\n" ++
  "    })();\n" ++
  "  }\n" ++
  "  async function invoke(command, args = {}, options = {}) {\n" ++
  "    let cleanArgs;\n" ++
  "    let boundChan = null;\n" ++
  "    if (args instanceof Uint8Array) {\n" ++
  "      cleanArgs = { __binaryBase64: bytesToBase64(args) };\n" ++
  "    } else if (args instanceof ArrayBuffer) {\n" ++
  "      cleanArgs = { __binaryBase64: bytesToBase64(new Uint8Array(args)) };\n" ++
  "    } else {\n" ++
  "      cleanArgs = { ...(args || {}) };\n" ++
  "      if (cleanArgs.onEvent instanceof Channel) {\n" ++
  "        boundChan = cleanArgs.onEvent;\n" ++
  "        delete cleanArgs.onEvent;\n" ++
  "      }\n" ++
  "    }\n" ++
  "    if (options && typeof options === 'object' && options.headers && typeof options.headers === 'object') {\n" ++
  "      cleanArgs.__headers = { ...options.headers };\n" ++
  "    }\n" ++
  "    if (command.endsWith('_unsubscribe') && typeof cleanArgs.token === 'number') {\n" ++
  "      channels.delete(cleanArgs.token);\n" ++
  "      if (!channels.size && !listeners.size) stopStream();\n" ++
  "    }\n" ++
  "    let res = await (async () => {\n" ++
  "      for (let attempt = 0; ; attempt++) {\n" ++
  "        try {\n" ++
  "          return await _fetch(ORB_LOCALD_URL, {\n" ++
  "            method: 'POST',\n" ++
  "            headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },\n" ++
  "            body: _jsonStringify({ command, args: cleanArgs })\n" ++
  "          });\n" ++
  "        } catch (err) {\n" ++
  "          if (attempt >= 8) throw err;\n" ++
  "          await new Promise(r => setTimeout(r, 75));\n" ++
  "        }\n" ++
  "      }\n" ++
  "    })();\n" ++
  "    const body = await res.json();\n" ++
  "    if (!res.ok || body.error) throw new Error(body.error || `RPC ${command} failed`);\n" ++
  "    if (boundChan && typeof body.result === 'number') {\n" ++
  "      channels.set(body.result, boundChan);\n" ++
  "      void drain();\n" ++
  "      ensureStream();\n" ++
  "    }\n" ++
  "    return body.result;\n" ++
  "  }\n" ++
  "  async function listen(name, handler) {\n" ++
  "    if (!listeners.has(name)) listeners.set(name, new Set());\n" ++
  "    listeners.get(name).add(handler);\n" ++
  "    ensureStream();\n" ++
  "    return () => {\n" ++
  "      listeners.get(name)?.delete(handler);\n" ++
  "      if (listeners.get(name)?.size === 0) listeners.delete(name);\n" ++
  "      if (!channels.size && !listeners.size) stopStream();\n" ++
  "    };\n" ++
  "  }\n" ++
  "  const desktop = {\n" ++
  "    core: { invoke, Channel },\n" ++
  "    event: { listen },\n" ++
  "    window: { getCurrentWindow: () => ({\n" ++
  "      innerSize: async () => { const s = window.devicePixelRatio || 1; return { width: Math.round(window.innerWidth * s), height: Math.round(window.innerHeight * s) }; },\n" ++
  "      scaleFactor: async () => window.devicePixelRatio || 1\n" ++
  "    }) },\n" ++
  "    webview: { getCurrentWebview: () => ({ label: 'main' }) }\n" ++
  "  };\n" ++
  "  window.__ORB_DESKTOP__ = desktop;\n" ++
  "  window.__TAURI_INTERNALS__ = { invoke };\n" ++
  "  window.__TAURI__ = desktop;\n" ++
  "})();\n"

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

def maxLocaldRpcBodyBytes : Nat := 37748736   -- 36 MiB (headroom for 24 MiB WAV base64)
def maxLocaldProxyBodyBytes : Nat := 67108864 -- 64 MiB (context/blob/file uploads & responses)

private def validateLocaldHeaders (hdrLines : List String) (maxBody : Nat) :
    Except String (Array (String × String) × Option Nat × Option String) := Id.run do
  let mut headers : Array (String × String) := #[]
  let mut seenContentLen : Option Nat := none
  let mut seenAuthorization := false
  let mut authBearer : Option String := none
  for ln in hdrLines do
    if !ln.isEmpty then
      let lnBytes := ln.toUTF8
      let b0 := if lnBytes.size > 0 then lnBytes.get! 0 else 0
      if b0 == 32 || b0 == 9 then
        return .error "obs_fold_header_rejected"
      if LeanSys.Http.hasHttpFieldControlByte ln then
        return .error "invalid_header_value"
      match ln.splitOn ":" with
      | [] | [_] =>
        return .error "malformed_header_line"
      | k :: rest =>
        if !LeanSys.Http.isHttpToken k then
          return .error "invalid_header_name"
        let kTrim := k.trimAscii.toString
        let vTrim := (String.intercalate ":" rest).trimAscii.toString
        headers := headers.push (kTrim, vTrim)
        if headers.size > 32 then
          return .error "too_many_headers"
        if LeanSys.Http.asciiEqIgnoreCase kTrim "transfer-encoding" then
          return .error "unsupported_transfer_encoding"
        else if LeanSys.Http.asciiEqIgnoreCase kTrim "content-length" then
          match LeanSys.Http.parseStrictContentLength? vTrim with
          | none =>
            return .error "invalid_content_length"
          | some parsedLen =>
            if parsedLen > maxBody then
              return .error "payload_too_large"
            if seenContentLen.isSome then
              return .error "conflicting_content_length"
            seenContentLen := some parsedLen
        else if LeanSys.Http.asciiEqIgnoreCase kTrim "authorization" then
          if seenAuthorization then
            return .error "duplicate_authorization"
          seenAuthorization := true
          if vTrim.startsWith "Bearer " then
            authBearer := some (vTrim.drop 7).trimAscii.toString
  return .ok (headers, seenContentLen, authBearer)

/-- Smuggling-safe RFC 9112 request framer for `orb-locald` supporting `36 MiB` RPC bodies,
    `64 MiB` `/__orb_tx/` proxy bodies, and returning `(req, remainder)` for HTTP/1.1 keep-alive. -/
def parseLocaldHttpRequestHead (raw : ByteArray) (isProxyPort : Bool := false) :
    Except String (String × String × String × Array (String × String) × Nat × Option String × Nat) := do
  let some bodyStart := LeanSys.Http.findHeaderEnd? raw
    | .error "missing_header_terminator"
  if bodyStart - 4 > LeanSys.Http.maxHttpHeaderBytes then
    .error "headers_too_large"
  let some headStr := String.fromUTF8? (raw.extract 0 (bodyStart - 4))
    | .error "invalid_utf8_headers"
  match headStr.splitOn "\r\n" with
  | [] => .error "empty_request_line"
  | reqLine :: hdrLines =>
    let parts := reqLine.trimAscii.toString.splitOn " "
    let (method, path, proto) ← match parts with
      | [m, p, v] => .ok (m.trimAscii.toString, p.trimAscii.toString, v.trimAscii.toString)
      | _ => .error "malformed_request_line"
    if method.isEmpty || !LeanSys.Http.isHttpToken method || !path.startsWith "/" then
      .error "malformed_request_line"
    if proto != "HTTP/1.1" && proto != "HTTP/1.0" then
      .error "unsupported_http_version"
    let maxBody :=
      if isProxyPort || path.startsWith "/__orb_tx/" then maxLocaldProxyBodyBytes
      else maxLocaldRpcBodyBytes
    let (headers, cl?, authBearer) ← validateLocaldHeaders hdrLines maxBody
    return (method, path, proto, headers, cl?.getD 0, authBearer, bodyStart)

def parseLocaldHttpRequestFrame (raw : ByteArray) (isProxyPort : Bool := false) :
    Except String (LeanSys.Http.HttpRequest × ByteArray) := do
  let (method, path, proto, headers, contentLen, authBearer, bodyStart) ← parseLocaldHttpRequestHead raw isProxyPort
  if raw.size - bodyStart < contentLen then
    .error "content_length_mismatch"
  let exact := raw.extract 0 (bodyStart + contentLen)
  let rem := if bodyStart + contentLen < raw.size then raw.extract (bodyStart + contentLen) raw.size else ByteArray.empty
  let rootSlice := LeanSys.Posix.ByteSlice.ofByteArray exact
  let some bodySlice := LeanSys.Posix.ByteSlice.subSlice? rootSlice bodyStart contentLen
    | .error "invalid_body_slice"
  return ({
    method := method
    path := path
    version := proto
    headers := headers
    contentLength := contentLen
    authBearer := authBearer
    bodySlice := bodySlice
  }, rem)

def readLocaldHttpRequestFromFd
    (fd : LeanSys.Posix.Fd)
    (carry : ByteArray := ByteArray.empty)
    (isProxyPort : Bool := false)
    (timeoutMs : UInt32 := 15000) :
    IO (Except String (LeanSys.Http.HttpRequest × ByteArray)) := do
  let tStart ← IO.monoNanosNow
  let budgetMs : Nat := Nat.max 50 timeoutMs.toNat
  let mut buf := carry
  while (LeanSys.Http.findHeaderEnd? buf).isNone do
    if buf.size > LeanSys.Http.maxHttpHeaderBytes + 4 then
      return .error "headers_too_large"
    let now ← IO.monoNanosNow
    let elapsedMs := (now - tStart) / 1000000
    if elapsedMs >= budgetMs then
      return .error (if buf.isEmpty then "empty_socket_read" else "request_timeout")
    let remMs : UInt32 := (budgetMs - elapsedMs).toUInt32
    match ← LeanSys.Posix.pollReadable fd remMs with
    | .error .eagain =>
      return .error (if buf.isEmpty then "empty_socket_read" else "request_timeout")
    | .error _ =>
      return .error "socket_poll_error"
    | .ok () =>
      let chunk ← LeanSys.Posix.readStreamChunk fd 16384
      if chunk.isEmpty then
        return .error (if buf.isEmpty then "empty_socket_read" else "missing_header_terminator")
      buf := if buf.isEmpty then chunk else buf ++ chunk
  let (_, _, _, _, expectedBody, _, bodyStart) ← match parseLocaldHttpRequestHead buf isProxyPort with
    | .ok tup => pure tup
    | .error e => return .error e
  let bodyBudgetMs : Nat := if expectedBody > 4194304 then Nat.max budgetMs 60000 else budgetMs
  while buf.size - bodyStart < expectedBody do
    let now ← IO.monoNanosNow
    let elapsedMs := (now - tStart) / 1000000
    if elapsedMs >= bodyBudgetMs then
      return .error "request_timeout"
    let remMs : UInt32 := (bodyBudgetMs - elapsedMs).toUInt32
    match ← LeanSys.Posix.pollReadable fd remMs with
    | .error .eagain =>
      return .error "request_timeout"
    | .error _ =>
      return .error "socket_poll_error"
    | .ok () =>
      let missing := expectedBody - (buf.size - bodyStart)
      let chunk ← LeanSys.Posix.readStreamChunk fd (Nat.min missing 65536)
      if chunk.isEmpty then
        return .error "content_length_mismatch"
      buf := buf ++ chunk
  return parseLocaldHttpRequestFrame buf isProxyPort

def streamLocalEventsSse (stRef : IO.Ref LocaldState) (clientFd : LeanSys.Posix.Fd) (origin? : Option String) : IO Unit := do
  let corsHdr :=
    match origin? with
    | none => ""
    | some raw =>
      let o := raw.trimAscii.toString
      if !o.isEmpty && isAllowedLocaldOrigin (some o) then
        s!"Access-Control-Allow-Origin: {o}\r\nVary: Origin\r\n"
      else ""
  let head :=
    "HTTP/1.1 200 OK\r\n" ++
    corsHdr ++
    "Content-Type: text/event-stream\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "Connection: close\r\n\r\n: ready\n\n"
  let sid ← stRef.modifyGet LocaldState.registerSseSubscriber
  try
    match ← LeanSys.Posix.writeAll clientFd head.toUTF8 false with
    | .error _ => return ()
    | .ok _ =>
      let mut alive := true
      let mut idleTicks : Nat := 0
      while alive do
        let evs ← stRef.modifyGet (·.drainSseSubscriber sid)
        if !evs.isEmpty then
          idleTicks := 0
          let frame := "data: " ++ renderCompact (.arr evs) ++ "\n\n"
          match ← LeanSys.Posix.writeAll clientFd frame.toUTF8 false with
          | .ok _ => pure ()
          | .error _ => alive := false
        else
          match ← LeanSys.Posix.pollReadable clientFd 20 with
          | .ok () =>
            let chunk ← LeanSys.Posix.readStreamChunk clientFd 64
            if chunk.isEmpty then alive := false
          | .error .eagain =>
            idleTicks := idleTicks + 1
            if idleTicks ≥ 750 then
              idleTicks := 0
              match ← LeanSys.Posix.writeAll clientFd ": keepalive\n\n".toUTF8 false with
              | .ok _ => pure ()
              | .error _ => alive := false
          | .error _ =>
            alive := false
  finally
    stRef.modify (·.unregisterSseSubscriber sid)

end OrbLocald.Rpc
