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
  "https://agent-backend.nico-best-pc-ever.ovh",
  "https://agent-backend.thomas.md"
]

/-- Ordered candidate HTTPS origins matching `candidateApiUrls` in `orb/src/api.ts`. -/
def candidateOriginsFor (raw : String) : Array String :=
  let clean := OrbBin.PosixExt.stripTrailingSlash raw.trimAscii.toString
  if clean.isEmpty || !clean.startsWith "https://" ||
     clean.toList.any (fun c => c.toNat ≤ 0x20 || c.toNat == 0x7F) then
    defaultFailoverOrigins
  else
    let low := clean.toLower
    if low == "https://orbcore.thomas.md" then
      #[clean, "https://agent-backend.nico-best-pc-ever.ovh", "https://agent-backend.thomas.md"]
    else if low == "https://agent-backend.nico-best-pc-ever.ovh" then
      #[clean, "https://orbcore.thomas.md", "https://agent-backend.thomas.md"]
    else if low == "https://agent-backend.thomas.md" then
      #[clean, "https://orbcore.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh"]
    else if low.endsWith ".thomas.md" then
      #[clean, "https://orbcore.thomas.md", "https://agent-backend.thomas.md"]
    else
      #[clean]

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

structure LocaldState where
  launchToken         : String
  rpcPort             : UInt16 := 19479
  bridge              : TransportBridgeState := {}
  nextSubToken        : Nat := 1
  subscriptions       : Array SubscriptionEntry := #[]
  queuedChannelEvents : Array (Nat × JVal) := #[]
  bindingsRevision    : Nat := 0
  bindingsEntries     : Array (String × JVal) := #[]
  toolHub             : InteractiveToolHubState := {}
  clientLinkConnected : Bool := false
  approvalGraceSecs   : Nat := 300
  approvalGraceUntil  : UInt64 := 0
  approvalKeyPath     : String := ""
  orbStateDir         : String := ""
  homeDir             : String := ""
  machineId           : String := ""
  grantedFolders      : Array String := #[]
  connectionJson      : JVal := .null
  hostOs              : String := "linux"
  signerBin?          : Option String := none
  deriving Inhabited

def LocaldState.bindingsSnapshotJson (st : LocaldState) : JVal :=
  .obj #[("revision", JVal.nat st.bindingsRevision), ("bindings", .obj st.bindingsEntries)]

def LocaldState.activeInteractionJson (st : LocaldState) (runId : String) : JVal :=
  let clean := runId.trimAscii.toString
  if clean.isEmpty then .null
  else
    match (st.toolHub.findRun? clean).bind RunToolSlotTable.firstActiveSlot? with
    | some slot => slot.toClientRequestJson
    | none      => .null

def LocaldState.publishInteractionSnapshot (st : LocaldState) (runId : String) : LocaldState :=
  let clean := runId.trimAscii.toString
  let snap := st.activeInteractionJson clean
  let pushed := (st.subscriptions.filter fun e =>
      e.active && e.channel == "local_interaction" &&
      (match e.target? with | none => true | some t => t == clean)).foldl
    (fun acc e => acc.push (e.token, snap)) st.queuedChannelEvents
  { st with queuedChannelEvents := pushed }

def LocaldState.subscribe (st : LocaldState) (channel : String) (initialEvent? : Option JVal := none)
    (target? : Option String := none) : (Nat × LocaldState) :=
  let tok := st.nextSubToken
  let entry : SubscriptionEntry := { token := tok, channel := channel, target? := target?, active := true }
  let q := match initialEvent? with
    | some ev => st.queuedChannelEvents.push (tok, ev)
    | none    => st.queuedChannelEvents
  (tok, { st with nextSubToken := tok + 1, subscriptions := st.subscriptions.push entry, queuedChannelEvents := q })

def LocaldState.unsubscribe (st : LocaldState) (tok : Nat) : LocaldState :=
  { st with
      subscriptions := st.subscriptions.filter (fun e => e.token != tok && e.active),
      queuedChannelEvents := st.queuedChannelEvents.filter (fun (t, _) => t != tok) }

def LocaldState.clearAllSubscriptions (st : LocaldState) : LocaldState :=
  { st with subscriptions := #[], queuedChannelEvents := #[] }

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

private def resolveOrbStateDir (st : LocaldState) : Option System.FilePath :=
  let raw := st.orbStateDir.trimAscii.toString
  if raw.isEmpty then none else some (System.FilePath.mk raw)

private def connectionFilePath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "connection.json")

private def logsDirPath? (st : LocaldState) : Option System.FilePath :=
  (resolveOrbStateDir st).map (· / "logs")

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

private def sampleHostMetrics (hostOs : String) : IO JVal := do
  let nowSec ← OrbBin.PosixExt.nowEpoch
  let sampledAtMs := nowSec.toNat * 1000
  let mut memTotal : Nat := 0
  let mut memUsed : Nat := 0
  let mut diskTotal : Nat := 0
  let mut diskUsed : Nat := 0
  let mut cpuPct? : Option String := none
  if hostOs == "macos" then
    if let some hwOut ← readCommandStdout? "/usr/sbin/sysctl" #["-n", "hw.memsize"] then
      memTotal := hwOut.toNat?.getD 0
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
      let ncpu ← do
        match ← readCommandStdout? "/usr/sbin/sysctl" #["-n", "hw.logicalcpu"] with
        | some s => pure (max 1 (s.toNat?.getD 1))
        | none => pure 1
      let normPct := min 100 ((tenthsSum / ncpu + 5) / 10)
      cpuPct? := some s!"{normPct}"
  else
    try
      let memInfo ← IO.FS.readFile "/proc/meminfo"
      let parseKb (k : String) : Nat := Id.run do
        for ln in memInfo.splitOn "\n" do
          if ln.startsWith k then
            for tok in (ln.drop k.length).toString.splitOn " " do
              if let some n := tok.trimAscii.toString.toNat? then return n * 1024
        return 0
      memTotal := parseKb "MemTotal:"
      let avail := parseKb "MemAvailable:"
      if memTotal > avail && avail > 0 then memUsed := memTotal - avail
    catch _ => pure ()
  if let some dfOut ← readCommandStdout? "/bin/df" #["-k", "/"] then
    if let some dataLn := (dfOut.splitOn "\n").drop 1 |>.head? then
      let cols := (dataLn.splitOn " ").filter (fun s => !s.trimAscii.toString.isEmpty)
      if cols.length ≥ 4 then
        diskTotal := (cols[1]!.toNat?.getD 0) * 1024
        diskUsed := (cols[2]!.toNat?.getD 0) * 1024
  let cpuVal : JVal := match cpuPct? with | some s => .num s | none => .null
  return .obj #[
    ("sampled_at", JVal.nat sampledAtMs),
    ("cpu_percent", cpuVal),
    ("gpu_percent", .null),
    ("memory_used", JVal.nat memUsed),
    ("memory_total", JVal.nat memTotal),
    ("memory_used_bytes", JVal.nat memUsed),
    ("memory_total_bytes", JVal.nat memTotal),
    ("disk_used", JVal.nat diskUsed),
    ("disk_total", JVal.nat diskTotal),
    ("consumers", .arr #[])
  ]

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

private def isGrantedUploadPath (st : LocaldState) (rawPath : String) : Bool :=
  let p := rawPath.trimAscii.toString
  !p.isEmpty && p.startsWith "/" && !(p.splitOn "/").contains ".." &&
  st.grantedFolders.any (fun g => p == g || p.startsWith (if g.endsWith "/" then g else g ++ "/"))

/-- Pure/IO dispatcher for all desktop IPC commands plus internal `__orb_poll_events`. -/
def dispatchRpcCommand (stRef : IO.Ref LocaldState) (cmd : String) (args : JVal) : IO (Except String JVal) := do
  let st ← stRef.get
  match cmd with
  | "plugin:app|version" =>
    return .ok (.str "0.13.0")
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
    return .ok nextBridge.toJson
  | "__orb_poll_events" =>
    let evs ← stRef.modifyGet fun s =>
      let items := s.queuedChannelEvents.map fun (tok, payload) =>
        JVal.obj #[("token", JVal.nat tok), ("payload", payload)]
      (JVal.arr items, { s with queuedChannelEvents := #[] })
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
    let dlPath := System.FilePath.mk st.homeDir.trimAscii.toString / "Downloads" / name.trimAscii.toString
    if !(← dlPath.pathExists) then
      return .error "Download file not found"
    let openArgs := if st.hostOs == "macos" then #["-R", dlPath.toString] else #[(dlPath.parent.getD (System.FilePath.mk st.homeDir)).toString]
    match ← runDetachedOpen st.hostOs openArgs with
    | .ok () => return .ok .null
    | .error e => return .error s!"Could not reveal download: {e}"
  | "set_window_theme" =>
    return .ok .null
  | "local_machine_metrics" =>
    let snap ← sampleHostMetrics st.hostOs
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
    let avail := st.hostOs == "macos"
    return .ok (.obj #[
      ("available", .bool avail),
      ("kind", .str (if avail then "touch_id" else "none")),
      ("label", .str (if avail then "Touch ID" else "")),
      ("biometry_type", .str (if avail then "touch_id" else "none"))
    ])
  | "biometric_authenticate" =>
    if st.hostOs != "macos" then
      return .ok (.bool false)
    else
      match st.signerBin? with
      | none => return .ok (.bool false)
      | some bin =>
        let rawReason := (args.fieldStr? "reason").getD "Authenticate"
        let cleanReason := if rawReason.trimAscii.toString.isEmpty then "Authenticate" else rawReason.trimAscii.toString
        match ← runOrbSigner bin #["auth", "--reason", cleanReason] none with
        | .ok jv => return .ok (.bool ((jv.fieldStr? "authenticated") == some "true"))
        | .error _ => return .ok (.bool false)
  | "client_link_active" =>
    return .ok (.bool st.clientLinkConnected)
  | "client_link_connect" =>
    stRef.modify fun s => { s with clientLinkConnected := true }
    return .ok (.bool true)
  | "client_link_flush" | "client_link_set_capabilities" | "client_link_start_result" =>
    return .ok .null
  | "local_bindings_refresh" =>
    return .ok st.bindingsSnapshotJson
  | "local_binding_set" =>
    let bid := (args.fieldStr? "id").getD ""
    let bval := (args.field? "binding").getD (.obj #[])
    let ifAbsent := (args.fieldBool? "ifAbsent").getD false
    let snap ← stRef.modifyGet fun s =>
      if bid.isEmpty || (ifAbsent && (s.bindingsEntries.any (fun (k, _) => k == bid))) then
        (s.bindingsSnapshotJson, s)
      else
        let filtered := s.bindingsEntries.filter (fun (k, _) => k != bid)
        let nextEntries := filtered.push (bid, bval)
        let nextRev := s.bindingsRevision + 1
        let nextSnap : JVal := .obj #[("revision", JVal.nat nextRev), ("bindings", .obj nextEntries)]
        let pushed := (s.subscriptions.filter (fun e => e.active && e.channel == "local_bindings")).foldl
          (fun acc e => acc.push (e.token, nextSnap)) s.queuedChannelEvents
        (nextSnap, { s with bindingsRevision := nextRev, bindingsEntries := nextEntries, queuedChannelEvents := pushed })
    return .ok snap
  | "local_bindings_subscribe" =>
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
    let tok ← stRef.modifyGet fun s =>
      s.subscribe "local_agents" none
    return .ok (JVal.nat tok)
  | "local_bindings_unsubscribe" | "local_interaction_unsubscribe"
  | "project_context_unsubscribe" | "local_agents_unsubscribe" =>
    let tok := (args.fieldNat? "token").getD 0
    stRef.modify fun s => s.unsubscribe tok
    return .ok .null
  | "grant_upload_folder" =>
    let p := ((args.fieldStr? "path").orElse (fun _ => args.fieldStr? "batch")).getD ""
    if !p.isEmpty then
      stRef.modify fun s =>
        if s.grantedFolders.contains p then s
        else { s with grantedFolders := s.grantedFolders.push p }
    return .ok .null
  | "revoke_upload_folder" =>
    let p := ((args.fieldStr? "path").orElse (fun _ => args.fieldStr? "batch")).getD ""
    stRef.modify fun s => { s with grantedFolders := s.grantedFolders.filter (· != p) }
    return .ok .null
  | "stat_upload_file" =>
    let p := (args.fieldStr? "path").getD ""
    if !isGrantedUploadPath st p then
      return .error "File was not granted for upload"
    try
      let m ← (System.FilePath.mk p).metadata
      let modMs := m.modified.sec.toNat * 1000
      return .ok (.obj #[("size", JVal.nat m.byteSize.toNat), ("modified", JVal.nat modMs)])
    catch e =>
      return .error s!"Cannot stat upload file: {e}"
  | "read_upload_file" =>
    let p := (args.fieldStr? "path").getD ""
    let maxBytes := (args.fieldNat? "maxBytes").getD (20 * 1024 * 1024)
    if !isGrantedUploadPath st p then
      return .error "File was not granted for upload"
    try
      let fp := System.FilePath.mk p
      let m ← fp.metadata
      if m.byteSize.toNat > maxBytes then
        return .error s!"File exceeds maximum size ({maxBytes} bytes)"
      let raw ← IO.FS.readBinFile fp
      return .ok (.str (OrbBin.PosixExt.base64Encode raw))
    catch e =>
      return .error s!"Cannot read upload file: {e}"
  | "read_upload_file_chunk" =>
    let p := (args.fieldStr? "path").getD ""
    let offset := (args.fieldNat? "offset").getD 0
    let length := min ((args.fieldNat? "length").getD (4 * 1024 * 1024)) (8 * 1024 * 1024)
    if !isGrantedUploadPath st p then
      return .error "File was not granted for upload"
    try
      let h ← IO.FS.Handle.mk (System.FilePath.mk p) .read
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
  | "save_file_as" =>
    let destPath := (args.fieldStr? "destPath").getD ""
    let b64 := (args.fieldStr? "dataBase64").getD ""
    if destPath.trimAscii.toString.isEmpty then
      return .ok .null
    match OrbBin.PosixExt.base64Decode? b64 with
    | none => return .error "Invalid base64 file data"
    | some bytes =>
      try
        let fp := System.FilePath.mk destPath.trimAscii.toString
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
    return .ok (.obj #[("available", .bool false), ("backend", .str "none")])
  | "voice_prewarm" | "voice_cancel" =>
    return .ok .null
  | "software_inventory" =>
    return .ok (.arr #[])
  | "local_origin_list" | "local_agents_scan" | "local_antigravity_models"
  | "local_claude_models" | "project_context_workers"
  | "local_skill_source_files" =>
    return .ok (.arr #[])
  | "browse_local_files" =>
    let rootRaw := (args.fieldStr? "root").getD ""
    let reqObj := (args.field? "request").getD (.obj #[])
    let action := (reqObj.fieldStr? "action").getD "list"
    let relRaw := (reqObj.fieldStr? "path").getD ""
    if rootRaw.trimAscii.toString.isEmpty || (relRaw.splitOn "/").contains ".." then
      return .error "Invalid local browse path"
    let rootFp := System.FilePath.mk rootRaw.trimAscii.toString
    let cleanRel := (relRaw.splitOn "/").filter (fun s => !s.isEmpty && s != ".") |> String.intercalate "/"
    let targetFp := if cleanRel.isEmpty then rootFp else rootFp / cleanRel
    if action == "reveal" then
      let openArgs := if st.hostOs == "macos" then #["-R", targetFp.toString] else #[(targetFp.parent.getD rootFp).toString]
      match ← runDetachedOpen st.hostOs openArgs with
      | .ok () => return .ok (.obj #[])
      | .error _ => return .error "Could not reveal this file"
    else if action == "read" then
      try
        let m ← targetFp.metadata
        if m.byteSize.toNat > 2 * 1024 * 1024 then
          return .error "File is too large to preview"
        let content ← IO.FS.readFile targetFp
        return .ok (.obj #[("content", .str content), ("size", JVal.nat m.byteSize.toNat)])
      catch _ =>
        return .error "Could not read local file"
    else if action == "resolve" then
      let paths := (reqObj.fieldArr? "paths").getD #[]
      let mut results : Array JVal := #[]
      for pVal in paths do
        if let some refStr := pVal.asStr? then
          let cleanRef := (refStr.splitOn "/").filter (fun s => !s.isEmpty && s != "." && s != "..") |> String.intercalate "/"
          let cand := if cleanRef.isEmpty then rootFp else rootFp / cleanRef
          let existsFile ← try
            let m ← cand.metadata
            pure (m.type != .dir)
          catch _ => pure false
          let matchesArr : Array JVal :=
            if existsFile then
              let fname := cand.fileName.getD cleanRef
              #[.obj #[("name", .str fname), ("path", .str cleanRef), ("kind", .str "file")]]
            else #[]
          results := results.push (.obj #[("reference", .str refStr), ("matches", .arr matchesArr)])
      return .ok (.obj #[("results", .arr results)])
    else
      try
        let dirEntries ← targetFp.readDir
        let mut out : Array JVal := #[]
        for entry in dirEntries do
          let name := entry.fileName
          if !name.isEmpty && name != "." && name != ".." then
            let m? ← try pure (some (← entry.path.metadata)) catch _ => pure none
            let kind := match m? with | some m => (if m.type == .dir then "dir" else "file") | none => "file"
            let sz := match m? with | some m => m.byteSize.toNat | none => 0
            let entryPath := if cleanRel.isEmpty then name else s!"{cleanRel}/{name}"
            out := out.push (.obj #[("name", .str name), ("path", .str entryPath), ("kind", .str kind), ("size", JVal.nat sz)])
        return .ok (.obj #[("entries", .arr out)])
      catch _ =>
        return .ok (.obj #[("entries", .arr #[])])
  | "local_machine_identity" =>
    let mid ← ensureMachineId stRef
    return .ok (.str mid)
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
  | "mistral_usage_sign_in" | "local_skills_status" =>
    return .ok .null
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
        -- Legacy / desktop initial probe (`local_interaction` with `{}` or `{id}`):
        -- return active pending interaction request for `id`, or `.null` if idle.
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
  | "local_wakeups_cancel" | "local_wakeups_discard"
  | "local_origin_confirm" | "local_origin_disconnect" =>
    return .ok .null
  | "local_agents_stop" =>
    let runId := (((args.fieldStr? "id").orElse (fun _ => args.fieldStr? "run_id")).orElse
      (fun _ => args.fieldStr? "runId")).getD ""
    if !runId.trimAscii.toString.isEmpty then
      let bump := (args.fieldBool? "bump_epoch").getD true
      stRef.modify fun s =>
        let (_, _, nextHub) := s.toolHub.cancelRunSlots runId "stopped" bump
        ({ s with toolHub := nextHub }).publishInteractionSnapshot runId
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
    return .ok (.obj #[("text", .str ""), ("done", .bool true), ("resumed", .bool false)])
  | "local_codex_speed_options" =>
    return .ok (.obj #[("tiers", .arr #[])])
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
    let reqObj := (args.field? "request").getD args
    let harness := (reqObj.fieldStr? "harness").getD ""
    let cwd := (reqObj.fieldStr? "cwd").getD "."
    let prompt := (reqObj.fieldStr? "prompt").getD (((args.field? "draft").bind (·.fieldStr? "prompt")).getD "")
    let model := (reqObj.fieldStr? "model").getD ""
    let cyber := (reqObj.fieldStr? "cyberAccess").getD ((reqObj.fieldStr? "cyber_access").getD "automatic")
    let hasImgs := (((reqObj.fieldArr? "image_paths").orElse (fun _ => reqObj.fieldArr? "imagePaths")).map (fun xs => !xs.isEmpty)).getD false
    let mut selectedSkills : Array (String × String × UInt8) := #[]
    if !harness.isEmpty then
      let home? ← do
        match ← OrbBin.PosixExt.firstEnvNonEmpty ["ORB_SKILLS_TEST_HOME", "HOME"] with
        | some h => pure (some h)
        | none => pure (if st.homeDir.isEmpty then none else some st.homeDir)
      if let some home := home? then
        match ← selectLocalSkillsIn (System.FilePath.mk home) (System.FilePath.mk cwd) harness prompt with
        | .error e => return .error e
        | .ok sel => selectedSkills := sel
      if harness == "codex" then
        if let .error e := validateLocalCodexLaunch prompt model cyber hasImgs then
          return .error e
    let deliveredPrompt := withLocalSkillDirective prompt selectedSkills
    if cmd == "local_origin_launch" then
      let rawId ← randomUuidV4
      let mid := (OrbBin.PosixExt.parseUuidCanonical? rawId).getD rawId
      let title := (((args.field? "draft").bind (·.fieldStr? "title")).orElse (fun _ => reqObj.fieldStr? "title")).getD "Local Mission"
      return .ok (.obj #[
        ("id", .str mid),
        ("title", .str title),
        ("status", .str "active"),
        ("backend", .str (if harness.isEmpty then "opencode" else harness)),
        ("working_directory", .str cwd),
        ("delivered_prompt", .str deliveredPrompt),
        ("total_cost_cents", JVal.nat 0)
      ])
    return .ok (.obj #[("ok", .bool true), ("command", .str cmd), ("delivered_prompt", .str deliveredPrompt)])
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
  s!"  const ORB_LOCALD_URL = {urlLit};\n" ++
  s!"  const ORB_EVENTS_URL = {sseLit};\n" ++
  s!"  const ORB_TOKEN = {tokLit};\n" ++
  "  const listeners = new Map();\n" ++
  "  const channels = new Map();\n" ++
  "  let streamCtrl = null;\n" ++
  "  class Channel {\n" ++
  "    constructor() { this.onmessage = () => {}; }\n" ++
  "  }\n" ++
  "  async function drain() {\n" ++
  "    if (!channels.size) return;\n" ++
  "    try {\n" ++
  "      const r = await _fetch(ORB_LOCALD_URL, {\n" ++
  "        method: 'POST',\n" ++
  "        headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },\n" ++
  "        body: _jsonStringify({ command: '__orb_poll_events', args: {} })\n" ++
  "      });\n" ++
  "      const b = await r.json();\n" ++
  "      if (Array.isArray(b.result)) {\n" ++
  "        for (const ev of b.result) channels.get(ev.token)?.onmessage(ev.payload);\n" ++
  "      }\n" ++
  "    } catch {}\n" ++
  "  }\n" ++
  "  function stopStream() {\n" ++
  "    if (streamCtrl) { streamCtrl.abort(); streamCtrl = null; }\n" ++
  "  }\n" ++
  "  function ensureStream() {\n" ++
  "    if (streamCtrl || !channels.size) return;\n" ++
  "    const ctrl = new AbortController();\n" ++
  "    streamCtrl = ctrl;\n" ++
  "    (async () => {\n" ++
  "      while (!ctrl.signal.aborted && channels.size) {\n" ++
  "        try {\n" ++
  "          const r = await _fetch(ORB_EVENTS_URL, {\n" ++
  "            headers: { 'Accept': 'text/event-stream', 'X-Orb-Token': ORB_TOKEN },\n" ++
  "            signal: ctrl.signal\n" ++
  "          });\n" ++
  "          if (!r.ok || !r.body) throw new Error('sse');\n" ++
  "          const reader = r.body.getReader();\n" ++
  "          const dec = new TextDecoder();\n" ++
  "          let buf = '';\n" ++
  "          while (!ctrl.signal.aborted && channels.size) {\n" ++
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
  "                  if (Array.isArray(arr)) for (const ev of arr) channels.get(ev.token)?.onmessage(ev.payload);\n" ++
  "                }\n" ++
  "              }\n" ++
  "            }\n" ++
  "          }\n" ++
  "        } catch {\n" ++
  "          if (ctrl.signal.aborted || !channels.size) break;\n" ++
  "          await new Promise(res => setTimeout(res, 1500));\n" ++
  "          if (!ctrl.signal.aborted && channels.size) await drain();\n" ++
  "        }\n" ++
  "      }\n" ++
  "      if (streamCtrl === ctrl) streamCtrl = null;\n" ++
  "    })();\n" ++
  "  }\n" ++
  "  async function invoke(command, args = {}, _options = {}) {\n" ++
  "    const cleanArgs = { ...(args || {}) };\n" ++
  "    let boundChan = null;\n" ++
  "    if (cleanArgs.onEvent instanceof Channel) {\n" ++
  "      boundChan = cleanArgs.onEvent;\n" ++
  "      delete cleanArgs.onEvent;\n" ++
  "    }\n" ++
  "    if (command.endsWith('_unsubscribe') && typeof cleanArgs.token === 'number') {\n" ++
  "      channels.delete(cleanArgs.token);\n" ++
  "      if (!channels.size) stopStream();\n" ++
  "    }\n" ++
  "    const res = await _fetch(ORB_LOCALD_URL, {\n" ++
  "      method: 'POST',\n" ++
  "      headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },\n" ++
  "      body: _jsonStringify({ command, args: cleanArgs })\n" ++
  "    });\n" ++
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
  "    return () => listeners.get(name)?.delete(handler);\n" ++
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

end OrbLocald.Rpc
