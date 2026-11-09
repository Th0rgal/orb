import Std.Sync.Mutex
import LeanSys
import Orb.Kernel
import OrbNetLeaf
import OrbBin.Json
import OrbBin.PosixExt
import OrbLocald.Spec

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
  endpoint          : String
  title             : String
  status            : String := "active"
  backend           : String := "opencode"
  workingDirectory  : String := "."
  deliveredPrompt   : String := ""
  localSyncPending  : Bool := true
  localRunActive    : Bool := true
  observedAt        : UInt64 := 0
  lastConflictCode  : Option String := none
  retryableConflict : Bool := false
  project           : String := ""
  folder            : Option String := none
  tags              : Array String := #["placement:client"]
  modelOverride     : Option String := none
  modelEffort       : Option String := none
  serviceTier       : Option String := none
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
    ("total_cost_cents", JVal.nat 0),
    ("tags", .arr (e.tags.map .str)),
    ("history", .arr e.history),
    ("created_at", .str (if e.createdAt.isEmpty then "1970-01-01T00:00:00Z" else e.createdAt)),
    ("updated_at", .str (if e.updatedAt.isEmpty then "1970-01-01T00:00:00Z" else e.updatedAt))
  ]
  let withProj :=
    if e.project.isEmpty then base else base.push ("project", .str e.project)
  let withFolder :=
    match e.folder with | some f => withProj.push ("folder", .str f) | none => withProj
  let withModel :=
    match e.modelOverride with | some m => withFolder.push ("model_override", .str m) | none => withFolder
  let withEffort :=
    match e.modelEffort with | some ef => withModel.push ("model_effort", .str ef) | none => withModel
  let withTier :=
    match e.serviceTier with | some st => withEffort.push ("service_tier", .str st) | none => withEffort
  let withConflict := match e.lastConflictCode with
    | some code =>
      (withTier.push ("conflict_code", .str code)).push ("conflict_retryable", .bool e.retryableConflict)
    | none => withTier
  .obj withConflict

def LocalOriginEntry.fromMissionJson? (jv : JVal) : Option LocalOriginEntry := do
  let id ← jv.fieldStr? "id"
  let ep := (jv.fieldStr? "endpoint").getD ""
  let title := (jv.fieldStr? "title").getD "Local Mission"
  let status := (jv.fieldStr? "status").getD "active"
  let backend := (jv.fieldStr? "backend").getD "opencode"
  let cwd := (jv.fieldStr? "working_directory").getD "."
  let prompt := (jv.fieldStr? "delivered_prompt").getD ""
  let syncPend := (jv.fieldBool? "local_sync_pending").getD false
  let runAct := (jv.fieldBool? "local_run_active").getD false
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
  let createdAt := (jv.fieldStr? "created_at").getD ""
  let updatedAt := (jv.fieldStr? "updated_at").getD ""
  let hist := (jv.fieldArr? "history").getD #[]
  return {
    id, endpoint := ep, title, status, backend, workingDirectory := cwd,
    deliveredPrompt := prompt, localSyncPending := syncPend, localRunActive := runAct,
    observedAt := obsAt, lastConflictCode := confCode, retryableConflict := confRetry,
    project := proj, folder, tags, modelOverride := modelOv, modelEffort := modelEf,
    serviceTier := svcTier, createdAt, updatedAt, history := hist
  }

structure LocalRunRecord where
  id           : String
  runUuid      : String
  generation   : Nat := 1
  harness      : String := ""
  text         : String := ""
  done         : Bool := true
  exitCode?    : Option Int := none
  sessionId?   : Option String := none
  error?       : Option String := none
  retryable    : Bool := false
  resumed      : Bool := false
  activities   : Array JVal := #[]
  pid?         : Option Int64 := none
  deriving Repr, Inhabited

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
  localRuns            : Array LocalRunRecord := #[]
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
  lastMetricsMonoMs    : Nat := 0
  lastMetricsDetails   : Bool := false
  lastMetricsSnap      : JVal := .null
  metricsHistory       : Array (Nat × JVal) := #[]
  connectionJson       : JVal := .null
  hostOs               : String := "linux"
  signerBin?           : Option String := none
  originHealth         : Array OriginHealthEntry := #[]
  h2Pool?              : Option OrbNetLeaf.H2Pool.H2ClientPool := none
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
      o.isEmpty || o == "null" || o == "file://" || o == "tauri://localhost" ||
      o.startsWith "http://127.0.0.1:" || o.startsWith "http://localhost:" ||
      o == "http://127.0.0.1" || o == "http://localhost"

/-- Canonical list of all 89 desktop IPC commands (`88` commands + `plugin:app|version`). -/
def supportedDesktopCommands : Array String := #[
  "plugin:app|version",
  "transport_bridge_configure",
  "desktop_connection_load", "desktop_connection_save", "diagnostics_append",
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
  "local_antigravity_models", "local_claude_models", "local_agents_workspace", "local_agents_directory",
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
  "voice_capability", "voice_prewarm", "voice_transcribe", "voice_cancel"
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
          let diskRev := (jv.fieldNat? "revision").getD 0
          let diskEntries : Array (String × JVal) :=
            match jv.field? "bindings" with
            | some (.obj kvs) => kvs
            | _ =>
              match jv with
              | .obj kvs => kvs.filter (fun (k, _) => k != "revision" && k != "bindings")
              | _ => #[]
          stRef.modify fun s =>
            if s.bindingsLoaded then s
            else
              let merged := diskEntries.foldl (fun acc (k, v) =>
                if acc.any (fun (ek, _) => ek == k) then acc else acc.push (k, v)) s.bindingsEntries
              let rev := max s.bindingsRevision (max diskRev merged.size)
              { s with bindingsLoaded := true, bindingsRevision := rev, bindingsEntries := merged }
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
          let parsed := xs.filterMap LocalOriginEntry.fromMissionJson?
          stRef.modify fun s =>
            if s.originsLoaded then s
            else
              let merged := parsed.foldl (fun acc row =>
                if acc.any (fun r => r.id == row.id) then acc else acc.push row) s.localOrigins
              { s with originsLoaded := true, localOrigins := merged }
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

private def runDetachedOpen (hostOs : String) (args : Array String) : IO (Except String Unit) := do
  let prog := if hostOs == "macos" then "/usr/bin/open" else "xdg-open"
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

private def sampleHostConsumers (hostOs : String) : IO (Array JVal) := do
  let psArgs := if hostOs == "macos" then #["-axo", "rss=,comm="] else #["-eo", "rss=,comm="]
  let some psOut ← readCommandStdout? "/bin/ps" psArgs | return #[]
  let mut orbRss : Nat := 0
  let mut orbProcs : Nat := 0
  let mut voiceRss : Nat := 0
  let mut voiceProcs : Nat := 0
  let mut agentRss : Nat := 0
  let mut agentProcs : Nat := 0
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
  let mut memUsed : Nat := 0
  let mut diskTotal : Nat := 0
  let mut diskUsed : Nat := 0
  let mut cpuPct? : Option Nat := none
  if hostOs == "macos" then
    if memTotal == 0 then
      if let some hwOut ← readCommandStdout? "/usr/sbin/sysctl" #["-n", "hw.memsize"] then
        memTotal := hwOut.toNat?.getD 0
    if ncpu == 0 then
      if let some cpuOut ← readCommandStdout? "/usr/sbin/sysctl" #["-n", "hw.logicalcpu"] then
        ncpu := max 1 (cpuOut.toNat?.getD 1)
    if ncpu == 0 then ncpu := 1
    if let some vmOut ← readCommandStdout? "/usr/bin/vm_stat" #[] then
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
    if let some psOut ← readCommandStdout? "/bin/ps" #["-A", "-o", "%cpu="] then
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
    try
      let memInfo ← IO.FS.readFile "/proc/meminfo"
      let parseKb (k : String) : Nat := Id.run do
        for ln in memInfo.splitOn "\n" do
          if ln.startsWith k then
            for tok in (ln.drop k.length).toString.splitOn " " do
              if let some n := tok.trimAscii.toString.toNat? then return n * 1024
        return 0
      if memTotal == 0 then memTotal := parseKb "MemTotal:"
      let avail := parseKb "MemAvailable:"
      if memTotal > avail && avail > 0 then memUsed := memTotal - avail
    catch _ => pure ()
  if let some dfOut ← readCommandStdout? "/bin/df" #["-k", "/"] then
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
    let host ← OrbBin.PosixExt.getHostname
    let fallback := if host.trimAscii.toString.isEmpty then "local-desktop" else host.trimAscii.toString
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
  if fakeMode then
    cands := cands ++ #["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]
  for c in cands do
    if (← System.FilePath.pathExists c) then
      return some c
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
  match ← readCommandStdout? "/usr/bin/uname" #["-m"] with
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
      s!"{h}/.cargo/bin",
      s!"{h}/.bun/bin",
      s!"{h}/bin"
    ]
  userDirs ++ #["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

private def resolveAgentExecutable? (homeDir : String) (binName : String) (override? : Option String) : IO (Option String) := do
  if let some ov := override? then
    let clean := ov.trimAscii.toString
    if !clean.isEmpty then
      let st ← OrbBin.PosixExt.statPath clean
      if st.exists_ && (st.isReg || st.isSymlink) then
        return some clean
      return none
  let pathEnv := ((← IO.getEnv "PATH").getD "").splitOn ":" |>.filter (fun s => !s.trimAscii.toString.isEmpty)
  let searchDirs := pathEnv.toArray ++ candidateAgentBinDirs homeDir
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

private def extractStreamLineDelta (harness line : String) : (String × Option String) := Id.run do
  let trimmed := line.trimAscii.toString
  if trimmed.isEmpty then return ("", none)
  if !trimmed.startsWith "{" then
    return (line ++ "\n", none)
  match OrbBin.Json.parse trimmed with
  | .error _ => return (line ++ "\n", none)
  | .ok jv =>
    let sid? := (jv.fieldStr? "session_id").orElse (fun _ =>
      (jv.fieldStr? "sessionId").orElse (fun _ => jv.fieldStr? "thread_id"))
    let typ := (jv.fieldStr? "type").getD ""
    if harness == "claudecode" then
      if typ == "assistant" then
        if let some msg := jv.field? "message" then
          if let some blocks := msg.fieldArr? "content" then
            let mut acc := ""
            for b in blocks do
              if (b.fieldStr? "type") == some "text" then
                if let some tx := b.fieldStr? "text" then acc := acc ++ tx
            if !acc.isEmpty then return (acc, sid?)
      if typ == "result" then
        if let some resTxt := jv.fieldStr? "result" then
          return (resTxt, sid?)
      return ("", sid?)
    else if harness == "codex" then
      if typ == "item.completed" then
        if let some item := jv.field? "item" then
          if (item.fieldStr? "type") == some "agent_message" then
            if let some tx := item.fieldStr? "text" then
              return (tx ++ "\n", sid?)
      return ("", sid?)
    else if harness == "opencode" then
      if typ == "text" then
        if let some part := jv.field? "part" then
          if let some tx := part.fieldStr? "text" then return (tx, sid?)
        if let some tx := jv.fieldStr? "text" then return (tx, sid?)
      return ("", sid?)
    else
      if let some tx := jv.fieldStr? "text" then return (tx, sid?)
      return ("", sid?)

private def localRunRecordToPollJson (r : LocalRunRecord) : JVal :=
  .obj #[
    ("text", .str r.text),
    ("done", .bool r.done),
    ("exit_code", match r.exitCode? with | some c => .num (toString c) | none => .null),
    ("session_id", match r.sessionId? with | some s => .str s | none => .null),
    ("error", match r.error? with | some e => .str e | none => .null),
    ("retryable", .bool r.retryable),
    ("resumed", .bool r.resumed),
    ("activities", .arr r.activities)
  ]

private def buildLocalAgentSpawnArgs (harness prompt model effort sessionId : String) (planMode : Bool) : Array String := Id.run do
  if harness == "claudecode" then
    let mut a := #["-p", "--output-format", "stream-json", "--verbose"]
    if planMode then a := a ++ #["--permission-mode", "plan"]
    else a := a ++ #["--dangerously-skip-permissions"]
    if !model.isEmpty then a := a ++ #["--model", model]
    if !sessionId.isEmpty then a := a ++ #["--resume", sessionId]
    return a.push prompt
  else if harness == "codex" then
    let mut a := #["exec", "--json", "--dangerously-bypass-approvals-and-sandbox"]
    if !model.isEmpty then a := a ++ #["-m", model]
    if !effort.isEmpty then a := a ++ #["-c", s!"model_reasoning_effort=\"{effort}\""]
    return a.push prompt
  else if harness == "opencode" then
    let mut a := #["run", "--format", "json"]
    if !model.isEmpty then a := a ++ #["-m", model]
    if planMode then a := a ++ #["--agent", "plan"]
    if !sessionId.isEmpty then a := a ++ #["-s", sessionId]
    return a.push prompt
  else if harness == "grok" then
    let mut a := #["-p", prompt]
    if !model.isEmpty then a := a ++ #["-m", model]
    return a
  else
    return #[prompt]

private def spawnLocalAgentRunner
    (stRef : IO.Ref LocaldState)
    (missionId runUuid harness binPath cwd prompt model effort sessionId : String)
    (generation : Nat) (planMode : Bool) : IO Unit := do
  let cliArgs := buildLocalAgentSpawnArgs harness prompt model effort sessionId planMode
  discard <| IO.asTask (prio := .dedicated) do
    let mut fullText := ""
    let mut finalSession? : Option String := if sessionId.isEmpty then none else some sessionId
    let mut exitCode? : Option Int := none
    let mut errMsg? : Option String := none
    try
      let child ← IO.Process.spawn {
        cmd := binPath
        args := cliArgs
        cwd := some (System.FilePath.mk cwd)
        stdin := .null
        stdout := .piped
        stderr := .piped
      }
      let errTask ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
      let mut eof := false
      while !eof do
        let line ← try child.stdout.getLine catch _ => pure ""
        if line.isEmpty then
          eof := true
        else
          let (delta, sid?) := extractStreamLineDelta harness line
          if let some sid := sid? then finalSession? := some sid
          if !delta.isEmpty then
            fullText := fullText ++ delta
            stRef.modify fun s =>
              let curRuns := s.localRuns.map fun r =>
                if r.id == missionId && r.runUuid == runUuid then { r with text := fullText, sessionId? := finalSession? } else r
              let evPayload : JVal := .obj #[("text", .str delta), ("reset", .bool false)]
              ({ s with localRuns := curRuns }).publishChannelEvent "local_agents" evPayload (some missionId)
      let code ← child.wait
      let errStr ← IO.ofExcept errTask.get
      exitCode? := some (Int.ofNat code.toNat)
      if code != 0 && fullText.trimAscii.toString.isEmpty then
        let cleanErr := errStr.trimAscii.toString
        errMsg? := some (if cleanErr.isEmpty then s!"{harness} exited with status {code}" else cleanErr)
    catch e =>
      errMsg? := some (toString e)
    let nowIso := formatUtcIso8601 (← OrbBin.PosixExt.nowEpoch)
    let stAfter ← stRef.modifyGet fun s =>
      let finalRec : LocalRunRecord := {
        id := missionId
        runUuid := runUuid
        generation := generation
        harness := harness
        text := fullText
        done := true
        exitCode? := exitCode?
        sessionId? := finalSession?
        error? := errMsg?
        retryable := false
        resumed := !sessionId.isEmpty
      }
      let nextRuns :=
        if s.localRuns.any (fun r => r.id == missionId) then
          s.localRuns.map fun r => if r.id == missionId then finalRec else r
        else s.localRuns.push finalRec
      let nextOrigins := s.localOrigins.map fun orig =>
        if orig.id == missionId then
          let nextHist :=
            if fullText.trimAscii.toString.isEmpty then orig.history
            else orig.history.push (.obj #[("role", .str "assistant"), ("content", .str fullText)])
          { orig with
              localRunActive := false
              status := if errMsg?.isSome then "failed" else "completed"
              updatedAt := nowIso
              history := nextHist }
        else orig
      let pollJson := localRunRecordToPollJson finalRec
      let termEv : JVal := .obj #[("text", .str ""), ("reset", .bool false), ("state", pollJson)]
      let s1 := ({ s with localRuns := nextRuns, localOrigins := nextOrigins }).publishChannelEvent "local_agents" termEv (some missionId)
      (s1, s1)
    persistOriginsSnapshot stAfter

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
      match ← runDetachedOpen st.hostOs #[dir.toString] with
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
      let openArgs := if st.hostOs == "macos" then #["-R", dlPath.toString] else #[dlDir.toString]
      match ← runDetachedOpen st.hostOs openArgs with
      | .ok () => return .ok .null
      | .error e => return .error s!"Could not reveal download: {e}"
    else if (← dlDir.pathExists) then
      match ← runDetachedOpen st.hostOs #[dlDir.toString] with
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
      if st.hostOs == "macos" && (← System.FilePath.pathExists bin) then
        match ← runOrbSigner bin (resolveApprovalKeyArgs st "public") with
        | .ok jv =>
          let pk := (jv.fieldStr? "public_key").getD ""
          return .ok (.obj #[("available", .bool true), ("enrolled", .bool (!pk.isEmpty)), ("public_key", if pk.isEmpty then .null else .str pk)])
        | .error _ =>
          return .ok (.obj #[("available", .bool true), ("enrolled", .bool false), ("public_key", .null)])
      else
        return .ok (.obj #[("available", .bool false), ("enrolled", .bool false), ("public_key", .null)])
    | none =>
      return .ok (.obj #[("available", .bool false), ("enrolled", .bool false), ("public_key", .null)])
  | "approval_key_create" =>
    match st.signerBin? with
    | some bin =>
      if st.hostOs == "macos" then
        resetSignerServer
        stRef.modify fun s => { s with approvalGraceUntil := 0 }
        match ← runOrbSigner bin (resolveApprovalKeyArgs st "create") with
        | .ok jv =>
          let pk := (jv.fieldStr? "public_key").getD ""
          if pk.isEmpty then return .error "orb-signer returned empty public_key"
          return .ok (.str pk)
        | .error (_, msg) => return .error msg
      else return .error "Secure Enclave is only available on macOS"
    | none => return .error "Secure Enclave is only available on macOS"
  | "approval_sign" =>
    let payload := (args.fieldStr? "payload").getD ""
    match st.signerBin? with
    | some bin =>
      if st.hostOs == "macos" then
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
      else return .error "Secure Enclave signing unavailable on this host"
    | none => return .error "Secure Enclave signing unavailable on this host"
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
    if st.hostOs != "macos" then
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
          return .ok (.obj #[
            ("available", .bool true),
            ("kind", .str "touch_id"),
            ("label", .str "Touch ID"),
            ("biometry_type", .str "touch_id")
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
    if st.hostOs != "macos" then
      return .error "Biometric authentication is only available on macOS"
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
    let res ← stRef.modifyGet fun s =>
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
      let res ← stRef.modifyGet fun s =>
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
      let res ← stRef.modifyGet fun s =>
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
    let tok ← stRef.modifyGet fun s =>
      s.subscribe "local_agents" none target?
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
      let rel := (item.fieldStr? "path").getD ""
      let lp := ((item.fieldStr? "local_path").orElse (fun _ => item.fieldStr? "localPath")).getD ""
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
    return .ok .null
  | "pick_upload_files" =>
    return .ok (.arr #[])
  | "pick_upload_folder" =>
    return .ok (.obj #[("batch", .null), ("files", .arr #[])])
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
    let supported := fakeMode || (st.hostOs == "macos" && arch == "aarch64")
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
    let ep := normalizeEndpointKey epRaw
    let filtered := cur.localOrigins.filter (fun row => ep.isEmpty || row.endpoint.isEmpty || row.endpoint == ep)
    return .ok (.arr (filtered.map LocalOriginEntry.toMissionJson))
  | "local_agents_scan" =>
    let reqObj := (args.field? "request").getD args
    let ov := (reqObj.field? "overrides").getD (.obj #[])
    let rows ← scanLocalAgents st ov
    return .ok (.arr rows)
  | "local_claude_models" =>
    return .ok (.arr #[
      .arr #[.str "claude-sonnet-4-6", .str "Claude Sonnet 4.6"],
      .arr #[.str "claude-opus-4-6", .str "Claude Opus 4.6"],
      .arr #[.str "claude-haiku-4-5", .str "Claude Haiku 4.5"]
    ])
  | "local_antigravity_models" =>
    let path := (args.fieldStr? "path").getD ""
    if path.trimAscii.toString.isEmpty || !(← System.FilePath.pathExists path.trimAscii.toString) then
      return .ok (.arr #[])
    match ← readCommandStdout? path.trimAscii.toString #["models"] with
    | none => return .ok (.arr #[])
    | some out =>
      let mut pairs : Array JVal := #[]
      for ln in out.splitOn "\n" do
        let tok := ((ln.trimAscii.toString.splitOn " ").head?.getD "").trimAscii.toString
        if !tok.isEmpty && !tok.startsWith "-" && !tok.startsWith "#" && tok.toLower != "model" && tok.toLower != "models" && tok.toLower != "id" then
          pairs := pairs.push (.arr #[.str tok, .str tok])
      return .ok (.arr pairs)
  | "local_agents_directory" =>
    let rawPath := (args.fieldStr? "path").getD ""
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
    let slug := sanitizeSlug ((reqObj.fieldStr? "slug").getD "workspace")
    let baseDir : System.FilePath :=
      match resolveOrbStateDir st with
      | some d => d / "local-workspaces" / slug
      | none =>
        let h := if st.homeDir.trimAscii.toString.isEmpty then "/tmp" else st.homeDir.trimAscii.toString
        System.FilePath.mk h / ".orb" / "local-workspaces" / slug
    try
      IO.FS.createDirAll baseDir
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
    let mut written : Nat := 0
    let mut skipped : Array String := #[]
    for f in files do
      let relRaw := (f.fieldStr? "rel").getD ""
      match isSafeRelSubpath relRaw with
      | none => skipped := skipped.push relRaw
      | some cleanRel =>
        if isSecretRelPath cleanRel then
          skipped := skipped.push cleanRel
        else
          let content := (f.fieldStr? "content").getD ""
          let enc := (f.fieldStr? "encoding").getD "utf8"
          let bytes? : Option ByteArray :=
            if enc == "base64" then OrbBin.PosixExt.base64Decode? content
            else some content.toUTF8
          match bytes? with
          | none => skipped := skipped.push cleanRel
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
            if okWrite then written := written + 1
            else skipped := skipped.push cleanRel
    return .ok (.obj #[
      ("binary_supported", .bool true),
      ("written", JVal.nat written),
      ("skipped", .arr (skipped.map .str))
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
      let openArgs := if curSt.hostOs == "macos" then #["-R", targetReal] else #[(System.FilePath.mk targetReal |>.parent.getD rootFp).toString]
      match ← runDetachedOpen curSt.hostOs openArgs with
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
        let res ← stRef.modifyGet fun s =>
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
      let res ← stRef.modifyGet fun s =>
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
      let res ← stRef.modifyGet fun s =>
        match s.toolHub.answerSlot runId epoch? reqId ansVal with
        | .error e => (.error e, s)
        | .ok (slot, nextHub) =>
          let s' := ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
          (.ok slot.toSummaryJson, s')
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
      let res ← stRef.modifyGet fun s =>
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
    let res ← stRef.modifyGet fun s =>
      match s.toolHub.answerSlot runId epoch? reqId ansVal with
      | .error e => (.error e, s)
      | .ok (_, nextHub) =>
        let s' := ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
        (.ok .null, s')
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
    let cleanId := runId.trimAscii.toString
    if !cleanId.isEmpty then
      let bump := (args.fieldBool? "bump_epoch").getD true
      let (pidToKill?, stAfter) ← stRef.modifyGet fun s =>
        let (_, _, nextHub) := s.toolHub.cancelRunSlots cleanId "stopped" bump
        let existingRec? := s.localRuns.find? (fun r => r.id == cleanId)
        let pid? := existingRec?.bind (·.pid?)
        let nextRuns := s.localRuns.map fun r =>
          if r.id == cleanId then { r with done := true, pid? := none } else r
        let nextOrigins := s.localOrigins.map fun orig =>
          if orig.id == cleanId then { orig with localRunActive := false } else orig
        let s1 := ({ s with toolHub := nextHub, localRuns := nextRuns, localOrigins := nextOrigins }).publishInteractionSnapshot cleanId
        let s2 := match nextRuns.find? (fun r => r.id == cleanId) with
          | some rec =>
            let termEv : JVal := .obj #[("text", .str ""), ("reset", .bool false), ("state", localRunRecordToPollJson rec)]
            s1.publishChannelEvent "local_agents" termEv (some cleanId)
          | none => s1
        ((pid?, s2), s2)
      if let some pid := pidToKill? then
        discard <| OrbBin.PosixExt.killSig pid 15
      persistOriginsSnapshot stAfter
    return .ok .null
  | "local_run_reconcile" =>
    let runId := (((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).orElse
      (fun _ => args.fieldStr? "runId")).getD ""
    let epoch? := (args.fieldUInt64? "session_epoch").orElse (fun _ => args.fieldUInt64? "sessionEpoch")
    let includeSummary := (args.fieldBool? "include_slots").getD (epoch?.isSome)
    if runId.trimAscii.toString.isEmpty then
      return .ok .null
    let res ← stRef.modifyGet fun s =>
      match s.toolHub.reconcileRun runId epoch? with
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
          (.ok .null, s')
    return res
  | "local_agents_poll" =>
    let cleanId := ((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).getD "" |>.trimAscii.toString
    match st.localRuns.find? (fun r => r.id == cleanId) with
    | some rec => return .ok (localRunRecordToPollJson rec)
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
    let cwd := (reqObj.fieldStr? "cwd").getD "."
    let prompt := (reqObj.fieldStr? "prompt").getD (((args.field? "draft").bind (·.fieldStr? "prompt")).getD "")
    let model := (reqObj.fieldStr? "model").getD ""
    let effort := (reqObj.fieldStr? "effort").getD ""
    let svcTier? := (reqObj.fieldStr? "service_tier").orElse (fun _ => reqObj.fieldStr? "serviceTier")
    let binPath := (reqObj.fieldStr? "bin").getD "" |>.trimAscii.toString
    let sessionId := ((reqObj.fieldStr? "session_id").orElse (fun _ => reqObj.fieldStr? "sessionId")).getD "" |>.trimAscii.toString
    let planMode := (reqObj.fieldBool? "planMode").getD ((reqObj.fieldBool? "plan_mode").getD false)
    let cyber := (reqObj.fieldStr? "cyberAccess").getD ((reqObj.fieldStr? "cyber_access").getD "automatic")
    let hasImgs := (((reqObj.fieldArr? "image_paths").orElse (fun _ => reqObj.fieldArr? "imagePaths")).map (fun xs => !xs.isEmpty)).getD false
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
    let deliveredPrompt := withLocalSkillDirective prompt selectedSkills
    let runUuid ← randomUuidV4
    let shouldSpawn ←
      if binPath.isEmpty then pure false
      else System.FilePath.pathExists binPath
    let cwdCanon? ← canonicalizeExistingPath? cwd
    let nowIso := formatUtcIso8601 (← OrbBin.PosixExt.nowEpoch)
    if cmd == "local_origin_launch" then
      let rawId ← randomUuidV4
      let mid := (OrbBin.PosixExt.parseUuidCanonical? rawId).getD rawId
      let draftObj := (args.field? "draft").getD (.obj #[])
      let title := ((draftObj.fieldStr? "title").orElse (fun _ => reqObj.fieldStr? "title")).getD "Local Mission"
      let proj := ((draftObj.fieldStr? "project").orElse (fun _ => reqObj.fieldStr? "project")).getD ""
      let folder? := ((draftObj.fieldStr? "folder").orElse (fun _ => reqObj.fieldStr? "folder")).filter (!·.isEmpty)
      let rawTags := ((draftObj.fieldArr? "tags").getD #[]).filterMap (·.asStr?)
      let tags := if rawTags.contains "placement:client" then rawTags else rawTags.push "placement:client"
      let connObj := (args.field? "connection").getD args
      let epRaw := ((connObj.fieldStr? "api_url").orElse (fun _ => connObj.fieldStr? "apiUrl")).getD curSt.bridge.configuredTarget
      let ep := normalizeEndpointKey epRaw
      let backendName := if harness.isEmpty then "opencode" else harness
      let entry : LocalOriginEntry := {
        id := mid
        endpoint := ep
        title := title
        status := "active"
        backend := backendName
        workingDirectory := cwd
        deliveredPrompt := deliveredPrompt
        localSyncPending := true
        localRunActive := true
        project := proj
        folder := folder?
        tags := tags
        modelOverride := if model.isEmpty then none else some model
        modelEffort := if effort.isEmpty then none else some effort
        serviceTier := svcTier?
        createdAt := nowIso
        updatedAt := nowIso
        history := #[.obj #[("role", .str "user"), ("content", .str prompt)]]
      }
      let initRec : LocalRunRecord := {
        id := mid
        runUuid := runUuid
        generation := 1
        harness := backendName
        done := !shouldSpawn
        resumed := !sessionId.isEmpty
      }
      let (stAfter, bindChanged) ← stRef.modifyGet fun s =>
        let keptOrigins := s.localOrigins.filter (fun r => r.id != mid)
        let keptRuns := s.localRuns.filter (fun r => r.id != mid)
        let nextRoots := match cwdCanon? with
          | some rp => if rp != "/" && !s.grantedBrowseRoots.contains rp then s.grantedBrowseRoots.push rp else s.grantedBrowseRoots
          | none => s.grantedBrowseRoots
        let (nextRev, nextBinds, bChanged, sPub) :=
          if !binPath.isEmpty then
            let bObj : JVal := .obj #[
              ("harness", .str backendName),
              ("bin", .str binPath),
              ("cwd", .str cwd),
              ("planMode", .bool planMode)
            ]
            let filtB := s.bindingsEntries.filter (fun (k, _) => k != mid)
            let nb := filtB.push (mid, bObj)
            let nr := s.bindingsRevision + 1
            let snap : JVal := .obj #[("revision", JVal.nat nr), ("bindings", .obj nb)]
            let sTmp := ({ s with bindingsRevision := nr, bindingsEntries := nb }).publishChannelEvent "local_bindings" snap
            (nr, nb, true, sTmp)
          else
            (s.bindingsRevision, s.bindingsEntries, false, s)
        let sFinal := { sPub with
          bindingsRevision := nextRev
          bindingsEntries := nextBinds
          localOrigins := keptOrigins.push entry
          localRuns := keptRuns.push initRec
          grantedBrowseRoots := nextRoots
        }
        ((sFinal, bChanged), sFinal)
      persistOriginsSnapshot stAfter
      if bindChanged then persistBindingsSnapshot stAfter
      if shouldSpawn then
        spawnLocalAgentRunner stRef mid runUuid backendName binPath cwd deliveredPrompt model effort sessionId 1 planMode
      return .ok entry.toMissionJson
    else
      let reqId := (reqObj.fieldStr? "id").getD "" |>.trimAscii.toString
      let mid := if reqId.isEmpty then runUuid else reqId
      if curSt.localRuns.any (fun r => r.id == mid && !r.done) then
        return .error "This mission already has non-terminal run"
      let prevGen := ((curSt.localRuns.find? (fun r => r.id == mid)).map (·.generation)).getD 0
      let nextGen := prevGen + 1
      let backendName := if harness.isEmpty then "opencode" else harness
      let initRec : LocalRunRecord := {
        id := mid
        runUuid := runUuid
        generation := nextGen
        harness := backendName
        done := !shouldSpawn
        resumed := !sessionId.isEmpty
      }
      stRef.modify fun s =>
        let keptRuns := s.localRuns.filter (fun r => r.id != mid)
        let nextRoots := match cwdCanon? with
          | some rp => if rp != "/" && !s.grantedBrowseRoots.contains rp then s.grantedBrowseRoots.push rp else s.grantedBrowseRoots
          | none => s.grantedBrowseRoots
        { s with localRuns := keptRuns.push initRec, grantedBrowseRoots := nextRoots }
      if shouldSpawn then
        spawnLocalAgentRunner stRef mid runUuid backendName binPath cwd deliveredPrompt model effort sessionId nextGen planMode
      return .ok (.obj #[
        ("ok", .bool true),
        ("command", .str cmd),
        ("run_id", .str runUuid),
        ("generation", JVal.nat nextGen),
        ("delivered_prompt", .str deliveredPrompt)
      ])
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
  match ← LeanSys.Posix.writeAll clientFd head.toUTF8 false with
  | .error _ => return ()
  | .ok _ =>
    let sid ← stRef.modifyGet LocaldState.registerSseSubscriber
    try
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
          match ← LeanSys.Posix.pollReadable clientFd 10 with
          | .ok () =>
            let chunk ← LeanSys.Posix.readStreamChunk clientFd 64
            if chunk.isEmpty then alive := false
          | .error .eagain =>
            idleTicks := idleTicks + 1
            if idleTicks ≥ 1500 then
              idleTicks := 0
              match ← LeanSys.Posix.writeAll clientFd ": keepalive\n\n".toUTF8 false with
              | .ok _ => pure ()
              | .error _ => alive := false
          | .error _ =>
            alive := false
    finally
      stRef.modify (·.unregisterSseSubscriber sid)

end OrbLocald.Rpc
