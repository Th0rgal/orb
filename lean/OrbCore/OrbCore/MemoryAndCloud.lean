/-
  OrbCore.MemoryAndCloud: Governed Hindsight Memory MCP Broker (`memory_*`), Scoped MCP Gateway,
  Instant Paloma (`cloud_hermes`) Wakeup + SSE Streaming, and Cloud-to-Workspace Fork Handoff
  (`0 import Lean`, `0 sorryAx`).

  All policy decisions delegate to `Orb.Kernel`:
  - `Orb.Kernel.memoryToolGate` (`orb_memory_tool_gate`)
  - `Orb.Kernel.cloudHandoffStep` (`orb_cloud_handoff_step`)
-/
import Std.Sync.Mutex
import LeanSys
import Orb.Kernel
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbBin.McpCatalog
import OrbCore.Spec
import OrbCore.Store
import OrbCore.CloudAgents

namespace OrbCore.MemoryAndCloud

open LeanSys.Auth
open LeanSys.Codec
open Orb.Kernel
open Orb.HarnessCloud
open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient
open OrbCore.Store
open OrbCore.CloudAgents

/-! ### 1. Governed Hindsight Memory MCP Broker (`memory_*`) -/

def defaultSearchLimit : UInt32 := 10
def maxSearchLimit : UInt32 := 25
def defaultRecallTokens : UInt32 := 4096
def maxRecallTokens : UInt32 := 8192
def defaultMemoryMcpBaseUrl : String := "https://memory.thomas.md/mcp"
def tokenCacheTtlSecs : UInt64 := 300

/-- Caller security context evaluated by `Orb.Kernel.memoryToolGate`. -/
structure MemoryCallerContext where
  callerRole            : UInt8 := 0  -- 0 = executor, 1 = coordinator, 2 = operator
  isExternalSession     : Bool  := false
  onManagedNode         : Bool  := false
  bunkerState           : UInt8 := 0
  hasProjectMemorySkill : Bool  := false
  hasSecretAccess       : Bool  := false
  deriving Repr, DecidableEq

/-- Cached `(fetchedAtEpochSec, bearerToken, secretKeyName)` protected by `Std.Mutex`. -/
structure MemoryTokenCache where
  slot : Std.Mutex (Option (UInt64 × String × String))

def newMemoryTokenCache : IO MemoryTokenCache := do
  let m ← Std.Mutex.new none
  return { slot := m }

def isMemoryToolName (name : String) : Bool :=
  name == "memory_search_knowledge" ||
  name == "memory_get_knowledge_page" ||
  name == "memory_get_knowledge_tree" ||
  name == "memory_recall"

/-- Parse `bank` parameter into `(bankKind, bankSlug)` (`0="thomas"`, `1="ppl"`, `2=invalid`). -/
def parseBankSlug (args : JVal) : Except String (UInt8 × String) :=
  match args.field? "bank" with
  | none | some .null => .ok (0, "thomas")
  | some (.str s) =>
    let t := s.trimAscii.toString
    if t.isEmpty || t == "thomas" then .ok (0, "thomas")
    else if t == "ppl" then .ok (1, "ppl")
    else .ok (2, "")
  | some _ => .error "`bank` must be a string (`\"thomas\"` or `\"ppl\"`)"

/-- Parse positive integer budget field; non-positive integers map to `0` so `memoryToolGate` rejects them cleanly. -/
def parseU32Budget (args : JVal) (field : String) (defaultVal : UInt32) : Except String UInt32 :=
  match args.field? field with
  | none | some .null => .ok defaultVal
  | some (.num raw) =>
    let t := raw.trimAscii.toString
    if t.startsWith "-" then
      .ok 0
    else
      match t.toNat? with
      | some n => .ok (if n > 0xFFFFFFFF then 0xFFFFFFFF else n.toUInt32)
      | none => .error s!"`{field}` must be an integer"
  | some _ => .error s!"`{field}` must be an integer"

def requiredNonEmptyStr (args : JVal) (field : String) (maxChars : Nat) : Except String String :=
  match args.fieldStr? field with
  | none => .error s!"`{field}` is required and must be a non-empty string"
  | some raw =>
    let t := raw.trimAscii.toString
    if t.isEmpty then
      .error s!"`{field}` is required and must be a non-empty string"
    else if t.length > maxChars then
      .error s!"`{field}` exceeds maximum length ({maxChars})"
    else
      .ok t

private partial def stripTrailingSlash (s : String) : String :=
  if s.endsWith "/" then stripTrailingSlash (s.dropEnd 1).toString else s

def resolveMemoryBaseUrl (overrideUrl? : Option String := none) : IO String := do
  if let some ov := overrideUrl? then
    let t := stripTrailingSlash ov.trimAscii.toString
    if !t.isEmpty then return t
  if let some envUrl ← IO.getEnv "SPARK_MEMORY_MCP_BASE_URL" then
    let t := stripTrailingSlash envUrl.trimAscii.toString
    if !t.isEmpty then return t
  return defaultMemoryMcpBaseUrl

def resolveMemoryToken
    (cache : MemoryTokenCache)
    (nowEpochSec : UInt64)
    (overrideToken? : Option String := none) : IO (Except String (String × String)) := do
  if let some ov := overrideToken? then
    let t := ov.trimAscii.toString
    if !t.isEmpty then return .ok (t, "OVERRIDE")
  let cached? ← cache.slot.atomically do
    let cur ← get
    match cur with
    | some (ts, tok, keyName) =>
      if nowEpochSec ≥ ts && nowEpochSec - ts < tokenCacheTtlSecs then
        return some (tok, keyName)
      else
        return none
    | none => return none
  if let some hit := cached? then
    return .ok hit
  for envKey in #["SPARK_MEMORY_API_TOKEN", "HINDSIGHT_API_KEY"] do
    if let some raw ← IO.getEnv envKey then
      let trimmed := raw.trimAscii.toString
      if !trimmed.isEmpty then
        cache.slot.atomically (set (some (nowEpochSec, trimmed, envKey)))
        return .ok (trimmed, envKey)
  return .error "Memory service credential (`HINDSIGHT_API_KEY` or `SPARK_MEMORY_API_TOKEN`) is not configured in Core env."

private def containsSubstr (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length > 1

/-- Parse either `text/event-stream` (`data: {...}`) or `application/json` JSON-RPC responses from Hindsight MCP. -/
def parseMcpUpstreamBody (contentType bodyText : String) : Except String JVal := Id.run do
  let trimmed := bodyText.trimAscii.toString
  if trimmed.isEmpty then
    return .error "Empty response body from upstream Hindsight MCP server"
  let ctLow := contentType.toLower
  if containsSubstr ctLow "text/event-stream" || trimmed.startsWith "event:" || trimmed.startsWith "data:" then
    let mut lastRpc? : Option JVal := none
    for rawLine in trimmed.splitOn "\n" do
      let ln := rawLine.trimAscii.toString
      if ln.startsWith "data:" then
        let payload := (ln.drop 5).trimAscii.toString
        if !payload.isEmpty && payload != "[DONE]" then
          if let .ok parsed := OrbBin.Json.parse payload then
            if (parsed.field? "result").isSome || (parsed.field? "error").isSome then
              lastRpc? := some parsed
    if let some rpc := lastRpc? then
      return .ok rpc
  match OrbBin.Json.parse trimmed with
  | .ok v => return .ok v
  | .error e => return .error s!"Invalid JSON-RPC payload from upstream Hindsight MCP server: {e}"

/-- Unwrap Hindsight JSON-RPC `tools/call` output into normalized structured JSON. -/
def unwrapMcpToolResult (rpc : JVal) (bankSlug upstreamTool : String) : Except String JVal := do
  if let some errObj := rpc.field? "error" then
    let msg := (errObj.fieldStr? "message").getD "Upstream memory MCP error"
    let code := (errObj.fieldInt? "code").getD (-1)
    throw s!"Memory MCP `{upstreamTool}` error ({code}): {msg}"
  let some resObj := rpc.field? "result"
    | throw "Upstream memory MCP response lacked `result`"
  if (resObj.fieldBool? "isError") == some true then
    let errText :=
      match resObj.fieldArr? "content" with
      | some items =>
        match items[0]? with
        | some first => (first.fieldStr? "text").getD "Upstream memory tool reported an error"
        | none => "Upstream memory tool reported an error"
      | none => "Upstream memory tool reported an error"
    throw s!"Memory MCP `{upstreamTool}` failed: {errText}"
  if let some structured := resObj.field? "structuredContent" then
    return .obj #[("bank", .str bankSlug), ("tool", .str upstreamTool), ("data", structured)]
  if let some items := resObj.fieldArr? "content" then
    if items.size == 1 then
      if let some txt := items[0]!.fieldStr? "text" then
        match OrbBin.Json.parse txt with
        | .ok parsedJson =>
          return .obj #[("bank", .str bankSlug), ("tool", .str upstreamTool), ("data", parsedJson)]
        | .error _ =>
          return .obj #[("bank", .str bankSlug), ("tool", .str upstreamTool), ("text", .str txt)]
  return .obj #[("bank", .str bankSlug), ("tool", .str upstreamTool), ("result", resObj)]

/-- Execute a governed read-only Hindsight `memory_*` MCP tool call gated by `Orb.Kernel.memoryToolGate`. -/
def executeMemoryMcpTool
    (cache : MemoryTokenCache)
    (ctx : MemoryCallerContext)
    (toolName : String)
    (args : JVal)
    (nowEpochSec : UInt64)
    (overrideBaseUrl? : Option String := none)
    (overrideToken? : Option String := none) : IO (Except String JVal) := do
  let parsedSpec : Except String (UInt8 × String × UInt32 × UInt32 × JVal) := do
    match toolName with
    | "memory_search_knowledge" =>
      let query ← requiredNonEmptyStr args "query" 1000
      let lim ← parseU32Budget args "limit" defaultSearchLimit
      pure (0, "search_knowledge", lim, defaultRecallTokens,
        .obj #[("query", .str query), ("limit", .nat lim.toNat)])
    | "memory_get_knowledge_page" =>
      let p ← requiredNonEmptyStr args "path" 500
      pure (1, "get_knowledge_page", defaultSearchLimit, defaultRecallTokens,
        .obj #[("path", .str p)])
    | "memory_get_knowledge_tree" =>
      let mut fields : Array (String × JVal) := #[]
      if let some pv := args.field? "path" then
        if pv != .null then
          let p ← requiredNonEmptyStr args "path" 500
          fields := fields.push ("path", .str p)
      pure (2, "get_knowledge_tree", defaultSearchLimit, defaultRecallTokens, .obj fields)
    | "memory_recall" =>
      let query ← requiredNonEmptyStr args "query" 1000
      let maxTok ← parseU32Budget args "max_tokens" defaultRecallTokens
      pure (3, "recall", defaultSearchLimit, maxTok,
        .obj #[("query", .str query), ("max_tokens", .nat maxTok.toNat)])
    | _ =>
      throw s!"Unknown memory tool `{toolName}`"
  let (opKind, upstreamTool, reqLimit, reqTokens, upstreamArgs) ←
    match parsedSpec with
    | .ok tup => pure tup
    | .error e => return .error e
  let (bankKind, bankSlug) ←
    match parseBankSlug args with
    | .ok b => pure b
    | .error e => return .error e
  let admitted :=
    Orb.Kernel.memoryToolGate
      opKind
      ctx.callerRole
      (if ctx.isExternalSession then 1 else 0)
      ctx.bunkerState
      (if ctx.onManagedNode then 1 else 0)
      (if ctx.hasProjectMemorySkill then 1 else 0)
      (if ctx.hasSecretAccess then 1 else 0)
      bankKind
      reqLimit
      maxSearchLimit
      reqTokens
      maxRecallTokens
  if admitted != 1 then
    if ctx.onManagedNode then
      return .error "Memory tools (`memory_*`) are denied on untrusted managed compute nodes (`managed-*`). Run memory retrieval from a trusted workspace/controller and pass distilled context to the worker."
    if ctx.isExternalSession && ctx.bunkerState > 0 then
      return .error "Fleet Bunker quarantine is active; external MCP memory reads are suspended."
    if bankKind == 2 then
      return .error "Invalid `bank`: expected `\"thomas\"` or `\"ppl\"`."
    if opKind == 0 && (reqLimit == 0 || reqLimit > maxSearchLimit) then
      return .error s!"`limit` must be between 1 and {maxSearchLimit} (got {reqLimit})."
    if opKind == 3 && (reqTokens == 0 || reqTokens > maxRecallTokens) then
      return .error s!"`max_tokens` must be between 1 and {maxRecallTokens} (got {reqTokens})."
    return .error "Caller is not authorized to invoke `memory_*` tools (requires coordinator/operator role, `spark-memory` project skill, or secret access to `HINDSIGHT_API_KEY` / `SPARK_MEMORY_API_TOKEN`)."
  let (bearerTok, _) ←
    match ← resolveMemoryToken cache nowEpochSec overrideToken? with
    | .ok t => pure t
    | .error e => return .error e
  let baseUrl ← resolveMemoryBaseUrl overrideBaseUrl?
  let endpoint := s!"{baseUrl}/{bankSlug}/"
  let rpcPayload := JVal.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", .nat 1),
    ("method", .str "tools/call"),
    ("params", .obj #[("name", .str upstreamTool), ("arguments", upstreamArgs)])
  ]
  let hdrs : Array (String × String) := #[
    ("Authorization", s!"Bearer {bearerTok}"),
    ("Content-Type", "application/json"),
    ("Accept", "application/json, text/event-stream")
  ]
  match ← sendRequest "POST" endpoint hdrs (renderCompact rpcPayload).toUTF8 20000 with
  | .error e => return .error s!"Upstream Hindsight MCP transport failed: {e}"
  | .ok resp =>
    if resp.status < 200 || resp.status ≥ 300 then
      return .error s!"Upstream Hindsight MCP returned HTTP {resp.status}"
    let ct :=
      ((resp.headers.find? (fun (k, _) => k.toLower == "content-type")).map Prod.snd).getD "application/json"
    let bodyStr := String.fromUTF8? resp.body |>.getD ""
    match parseMcpUpstreamBody ct bodyStr with
    | .error e => return .error e
    | .ok rpcVal => return unwrapMcpToolResult rpcVal bankSlug upstreamTool

/-! ### 2. Scoped MCP Session Credentials (`mcp1.*`) & Capabilities Payload -/

structure McpSessionClaims where
  sessionId  : String
  missionId  : String
  role       : String
  project    : String := ""
  isExternal : Bool   := false
  expiresAt  : UInt64
  deriving Repr, DecidableEq

def roleCodeFor (role : String) : UInt8 :=
  match role.trimAscii.toString.toLower with
  | "operator" => 2
  | "coordinator" => 1
  | _ => 0

def normalizeMcpRole (role : String) : String :=
  match role.trimAscii.toString.toLower with
  | "operator" => "operator"
  | "coordinator" => "coordinator"
  | _ => "executor"

/-- Mint an HMAC-SHA256 signed `mcp1.<hdrB64>.<payloadB64>.<sigHex>` credential compatible with `sandboxed-mcp`. -/
def mintScopedMcpToken (secret : String) (claims : McpSessionClaims) : String :=
  let effSec := if secret.isEmpty then "dev-mode-ephemeral-mcp-secret-012345" else secret
  let hdrB64 := base64Encode "{\"alg\":\"HS256\",\"typ\":\"MCP1\"}".toUTF8 false false
  let payloadJson := renderCompact (.obj #[
    ("session_id", .str claims.sessionId),
    ("mission_id", .str claims.missionId),
    ("role", .str (normalizeMcpRole claims.role)),
    ("project", .str claims.project),
    ("external", .bool claims.isExternal),
    ("exp", .nat claims.expiresAt.toNat)
  ])
  let payB64 := base64Encode payloadJson.toUTF8 false false
  let signingInput := s!"mcp1.{hdrB64}.{payB64}"
  let sigHex := hmacSha256Hex effSec signingInput
  s!"{signingInput}.{sigHex}"

/-- Verify an `mcp1.<hdrB64>.<payloadB64>.<sigHex>` credential against `secret` and `nowEpochSec`. -/
def verifyScopedMcpToken? (secret token : String) (nowEpochSec : UInt64) : Option McpSessionClaims := do
  if !token.startsWith "mcp1." then none
  let effSec := if secret.isEmpty then "dev-mode-ephemeral-mcp-secret-012345" else secret
  let rest := (token.drop 5).toString
  match rest.splitOn "." with
  | [hdrB64, payB64, sigHex] =>
    let signingInput := s!"mcp1.{hdrB64}.{payB64}"
    let expectedSig := hmacSha256Hex effSec signingInput
    if !ctEqString sigHex expectedSig then
      none
    else do
      let payBytes ← base64Decode? payB64
      let jv ← (OrbBin.Json.parseBytes payBytes).toOption
      let expNat ← jv.fieldNat? "exp"
      let exp := expNat.toUInt64
      if nowEpochSec ≥ exp then none
      else
        let sid := (jv.fieldStr? "session_id").getD "00000000-0000-0000-0000-000000000001"
        let mid := (jv.fieldStr? "mission_id").getD ""
        let role := normalizeMcpRole ((jv.fieldStr? "role").getD "executor")
        let proj := (jv.fieldStr? "project").getD ""
        let ext := (jv.fieldBool? "external").getD false
        some {
          sessionId := sid
          missionId := mid
          role := role
          project := proj
          isExternal := ext
          expiresAt := exp
        }
  | _ => none

/-- Render `/api/mcp/capabilities` response with deterministic `OrbBin.McpCatalog.toolsForRole`. -/
def buildMcpCapabilitiesJson (claims : McpSessionClaims) : String :=
  let roleNorm := normalizeMcpRole claims.role
  let rawTools := (OrbBin.McpCatalog.catalogPrettyJsonForRole roleNorm).getD OrbBin.McpCatalog.executorCatalogPrettyJson
  let tools := match OrbBin.Json.parse rawTools with | .ok (.arr arr) => arr | _ => #[]
  let root := JVal.obj #[
    ("contract_version", .str OrbBin.McpCatalog.contractVersion),
    ("identity", .obj #[
      ("session_id", .str claims.sessionId),
      ("mission_id", .str claims.missionId),
      ("role", .str roleNorm),
      ("project", if claims.project.isEmpty then .null else .str claims.project),
      ("external", .bool claims.isExternal)
    ]),
    ("limits", .obj #[
      ("session_expires_at", .nat claims.expiresAt.toNat),
      ("max_search_limit", .nat maxSearchLimit.toNat),
      ("max_recall_tokens", .nat maxRecallTokens.toNat)
    ]),
    ("tools", .arr tools)
  ]
  renderCompact root

/-! ### 3. Instant Paloma (`cloud_hermes`) Wakeup, TTL Capability Cache & Incremental SSE -/

/-- Poll-free generation wakeup for the cloud execution loop (`0 ms` immediate dispatch when bumped). -/
structure CloudWorkerWakeup where
  gen : Std.Mutex UInt64

def newCloudWorkerWakeup : IO CloudWorkerWakeup := do
  let g ← Std.Mutex.new 0
  return { gen := g }

/-- Bump wakeup generation (`create`, `follow_up`, `cancel`) so `waitForCloudWake` returns immediately. -/
def notifyCloudWorker (w : CloudWorkerWakeup) : IO UInt64 :=
  w.gen.atomically do
    let n ← get
    let next := n + 1
    set next
    return next

/-- Wait until `w.gen` advances past `seenGen` or `maxWaitMs` elapses (checked in `10 ms` slices; `0 ms` if already bumped). -/
def waitForCloudWake (w : CloudWorkerWakeup) (seenGen : UInt64) (maxWaitMs : UInt32 := 1000) : IO UInt64 := do
  let cur0 ← w.gen.atomically get
  if cur0 != seenGen || maxWaitMs == 0 then
    return cur0
  let mut waited : UInt32 := 0
  while waited < maxWaitMs do
    let stepMs : UInt32 := if maxWaitMs - waited < 10 then maxWaitMs - waited else 10
    IO.sleep stepMs
    waited := waited + stepMs
    let cur ← w.gen.atomically get
    if cur != seenGen then
      return cur
  w.gen.atomically get

/-- `300 s` TTL cache for Hermes `/v1/capabilities` avoiding redundant pre-run handshakes. -/
structure HermesCapabilitiesCache where
  slot : Std.Mutex (Option (UInt64 × JVal))

def newHermesCapabilitiesCache : IO HermesCapabilitiesCache := do
  let s ← Std.Mutex.new none
  return { slot := s }

def hermesCapsTtlSecs : UInt64 := 300

def getOrFetchHermesCapabilities
    (cache : HermesCapabilitiesCache)
    (hermesBaseUrl : String)
    (bearerToken? : Option String)
    (nowEpochSec : UInt64) : IO (Except String JVal) := do
  let hit? ← cache.slot.atomically do
    match ← get with
    | some (ts, v) =>
      if nowEpochSec ≥ ts && nowEpochSec - ts < hermesCapsTtlSecs then return some v
      else return none
    | none => return none
  if let some v := hit? then
    return .ok v
  let url := s!"{stripTrailingSlash hermesBaseUrl.trimAscii.toString}/v1/capabilities"
  match ← sendJsonRequest "GET" url bearerToken? none #[] 10000 with
  | .error e => return .error e
  | .ok (status, _, body?) =>
    if status < 200 || status ≥ 300 then
      return .error s!"Hermes /v1/capabilities returned HTTP {status}"
    let v := body?.getD (.obj #[])
    cache.slot.atomically (set (some (nowEpochSec, v)))
    return .ok v

/-- Normalized live events emitted by `stepHermesSseChunk`. -/
inductive HermesSseEvent where
  | textDelta        (cursor : UInt64) (delta : String)
  | waitingApproval  (cursor : UInt64) (req : CloudApprovalRequest)
  | approvalResolved (cursor : UInt64)
  | completed        (cursor : UInt64) (finalText : String)
  | failed           (cursor : UInt64) (errorMsg : String)
  | cancelled        (cursor : UInt64)
  deriving Repr, DecidableEq

/-- Monotone-cursor incremental SSE state for `/v1/runs/{run_id}/events?after={cursor}`.
    `submittedAtMs?` and `eventCursor?` are separate fields, never multiplexed in a string cursor. -/
structure HermesSseState where
  lastCursor      : UInt64 := 0
  hasCursor       : Bool   := false
  submittedAtMs?  : Option UInt64 := none
  eventCursor?    : Option UInt64 := none
  pendingApproval? : Option CloudApprovalRequest := none
  accumulatedText : String := ""
  terminalStatus? : Option String := none
  terminalError?  : Option String := none
  deriving Repr, DecidableEq

private def parseHermesApproval? (jv : JVal) : Option CloudApprovalRequest := do
  let reqObj := (jv.field? "request").getD jv
  let reqId :=
    (reqObj.fieldUInt64? "request_id")
    |>.orElse (fun _ => reqObj.fieldUInt64? "req_id")
    |>.orElse (fun _ => (reqObj.fieldStr? "request_id").bind String.toNat? |>.map Nat.toUInt64)
    |>.orElse (fun _ => jv.fieldUInt64? "approval_req_id")
  let idVal ← reqId
  if idVal == 0 then none
  else
    let cmd := (reqObj.fieldStr? "command").getD ""
    let choices :=
      match reqObj.fieldArr? "choices" with
      | some xs => xs.filterMap (fun v => v.asStr?)
      | none => #[]
    some { reqId := idVal, command := cmd, choices := choices }

/-- Pure-Lean incremental SSE reducer enforcing strict cursor monotonicity across reconnects. -/
def stepHermesSseChunk (st0 : HermesSseState) (rawChunk : String) : HermesSseState × Array HermesSseEvent := Id.run do
  let mut st := st0
  let mut out : Array HermesSseEvent := #[]
  let normalized := String.intercalate "\n" (rawChunk.splitOn "\r\n")
  for block in normalized.splitOn "\n\n" do
    let trimmedBlock := block.trimAscii.toString
    if !trimmedBlock.isEmpty && st.terminalStatus?.isNone then
      let mut evName := ""
      let mut idCursor? : Option UInt64 := none
      let mut dataParts : Array String := #[]
      for line in trimmedBlock.splitOn "\n" do
        let ln := line.trimAscii.toString
        if ln.startsWith "event:" then
          evName := (ln.drop 6).trimAscii.toString
        else if ln.startsWith "id:" then
          if let some n := (ln.drop 3).trimAscii.toString.toNat? then
            idCursor? := some n.toUInt64
        else if ln.startsWith "data:" then
          dataParts := dataParts.push (ln.drop 5).trimAscii.toString
      let dataRaw := String.intercalate "\n" dataParts.toList
      if !dataRaw.isEmpty && dataRaw != "[DONE]" then
        if let .ok jv := OrbBin.Json.parse dataRaw then
          let curFromJson? := (jv.fieldNat? "cursor").orElse (fun _ => jv.fieldNat? "seq") |>.map Nat.toUInt64
          let effCursor? := idCursor?.orElse (fun _ => curFromJson?)
          let prevCur? := st.eventCursor?.orElse (fun _ => if st.hasCursor then some st.lastCursor else none)
          let freshCursor : Bool :=
            match effCursor?, prevCur? with
            | some 0, _ => false
            | some c, some prev => c > prev
            | some _, none => true
            | none, _ => true
          if freshCursor then
            let curVal : UInt64 :=
              match effCursor?, prevCur? with
              | some c, _ => c
              | none, some prev => prev + 1
              | none, none => 1
            st := { st with lastCursor := curVal, hasCursor := true, eventCursor? := some curVal }
            let kind :=
              if !evName.isEmpty then evName
              else (jv.fieldStr? "type").orElse (fun _ => jv.fieldStr? "status") |>.getD ""
            match kind with
            | "text_delta" | "delta" | "chunk" =>
              let delta := (jv.fieldStr? "delta").orElse (fun _ => jv.fieldStr? "text") |>.getD ""
              if !delta.isEmpty then
                st := { st with accumulatedText := st.accumulatedText ++ delta }
                out := out.push (.textDelta curVal delta)
            | "waiting_approval" | "waiting_user" | "approval_required" =>
              if let some req := parseHermesApproval? jv then
                st := { st with pendingApproval? := some req }
                out := out.push (.waitingApproval curVal req)
            | "approval_resolved" | "resumed" =>
              st := { st with pendingApproval? := none }
              out := out.push (.approvalResolved curVal)
            | "completed" | "succeeded" =>
              let fullTxt :=
                (jv.fieldStr? "output").orElse (fun _ => jv.fieldStr? "response")
                |>.orElse (fun _ => jv.fieldStr? "text")
                |>.getD st.accumulatedText
              let mergedTxt := if st.accumulatedText.isEmpty then fullTxt else st.accumulatedText
              st := { st with accumulatedText := mergedTxt, pendingApproval? := none, terminalStatus? := some "completed" }
              out := out.push (.completed curVal mergedTxt)
            | "failed" | "error" =>
              let errMsg := (jv.fieldStr? "error").orElse (fun _ => jv.fieldStr? "message") |>.getD "Hermes run failed"
              st := { st with pendingApproval? := none, terminalStatus? := some "failed", terminalError? := some errMsg }
              out := out.push (.failed curVal errMsg)
            | "cancelled" | "canceled" =>
              st := { st with pendingApproval? := none, terminalStatus? := some "cancelled" }
              out := out.push (.cancelled curVal)
            | _ => pure ()
  return (st, out)

/-- One persisted CAS step, even when the kernel walked request-cancel then the receipt. -/
private def singleRev (turn done : CloudTurnState) (effs : List CloudTurnEffect) :
    CloudTurnState × List CloudTurnEffect :=
  if effs.isEmpty then (turn, [])
  else ({ done with stateRevision := turn.stateRevision + 1 }, effs)

/-- Stamp `cur` onto a turn without counting a revision; the following kernel step owns the `+1`. -/
private def stampCursor (turn : CloudTurnState) (cur : UInt64) : CloudTurnState :=
  if cur == 0 || cur ≤ cursorOf turn then turn else { turn with eventCursor? := some cur }

/-- Kernel walk `requestCancel` then `finalizeCancelReceipt`. Revision is left as the stepper wrote it;
    the caller collapses a multi-step walk to one CAS bump. -/
private def finishCancelFrom (turn : CloudTurnState) (cur nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  let (mid, effs1) := requestCancel turn nowMs
  if effs1.isEmpty then (turn, [])
  else
    let (done, effs2) := finalizeCancelReceipt (stampCursor mid cur) nowMs
    if effs2.isEmpty then (turn, [])
    else (done, effs1 ++ effs2)

/-- Fold one `HermesSseEvent` into `CloudTurnState` exclusively via `Orb.HarnessCloud.stepCloudTurnSlice`.
    `submittedAtMs?` is never overwritten by `eventCursor?`. A provider cancel/fail/complete while
    `cancelRequested` is the termination receipt (`opCode = 9`) and keeps/advances `eventCursor?`.
    `running` / `waitingApproval` / `queued` cancel as request (`opCode = 8`) then receipt (`opCode = 9`)
    with exactly one `stateRevision` bump. `submitting` / `uncertain` cancel only when a provider turn
    is already bound (`confirmAccepted` / `bindExistingTurn`), otherwise they stay unchanged. -/
def applyHermesEventToTurn
    (turn : CloudTurnState)
    (ev : HermesSseEvent)
    (nowMs : UInt64) : CloudTurnState × List CloudTurnEffect :=
  match ev with
  | .textDelta cur _ =>
    (advanceRunningCursor turn cur, [])
  | .waitingApproval cur req =>
    awaitApproval (stampCursor turn cur) req nowMs
  | .approvalResolved cur =>
    let effCur := if cur > cursorOf turn then cur else cursorOf turn
    resolveApproval turn effCur nowMs
  | .completed cur _ =>
    if turn.phase == .cancelRequested then
      finalizeCancelReceipt (stampCursor turn cur) nowMs
    else
      let effCur := if cur > cursorOf turn then cur else cursorOf turn
      completeTurnReceipt turn effCur nowMs
  | .failed cur errMsg =>
    if turn.phase == .cancelRequested then
      let (next, effs) := finalizeCancelReceipt (stampCursor turn cur) nowMs
      if effs.isEmpty then (turn, [])
      else ({ next with errorKind := .providerRejected, detail := errMsg }, effs)
    else
      let effCur := if cur > cursorOf turn then cur else cursorOf turn
      let (next, effs) := completeTurnReceipt turn effCur nowMs
      if effs.isEmpty then (turn, [])
      else ({ next with errorKind := .providerRejected, detail := errMsg }, effs)
  | .cancelled cur =>
    match turn.phase with
    | .cancelRequested =>
      finalizeCancelReceipt (stampCursor turn cur) nowMs
    | .running | .waitingApproval | .queued =>
      let (done, effs) := finishCancelFrom (stampCursor turn cur) cur nowMs
      singleRev turn done effs
    | .submitting =>
      if turn.providerTurnId == 0 then (turn, [])
      else
        let (accepted, effs0) := confirmAccepted turn turn.providerTurnId (cursorOf turn) nowMs
        if effs0.isEmpty then (turn, [])
        else
          let (done, effs1) := finishCancelFrom accepted cur nowMs
          if effs1.isEmpty then (turn, [])
          else singleRev turn done (effs0 ++ effs1)
    | .uncertain =>
      if turn.providerTurnId == 0 then (turn, [])
      else
        let (bound, effs0) := bindExistingTurn turn turn.providerTurnId (cursorOf turn) nowMs
        if effs0.isEmpty then (turn, [])
        else
          let (done, effs1) := finishCancelFrom bound cur nowMs
          if effs1.isEmpty then (turn, [])
          else singleRev turn done (effs0 ++ effs1)
    | .terminal =>
      (turn, [])

/-- Mirror a `CloudTurnState` and incremental SSE fields into one `HermesSseState` view. -/
def hermesViewOf (turn : CloudTurnState) (text : String) (terminalStatus? terminalError? : Option String) : HermesSseState :=
  { lastCursor := cursorOf turn
    hasCursor := turn.eventCursor?.isSome
    submittedAtMs? := turn.submittedAtMs?
    eventCursor? := turn.eventCursor?
    pendingApproval? := turn.approval?
    accumulatedText := text
    terminalStatus? := terminalStatus?
    terminalError? := terminalError? }

/-- Seed an `HermesSseState` view from the authoritative `CloudTurnState` without losing an
    already-known cursor or terminal marker on `initState`. -/
def seedHermesView (turn : CloudTurnState) (initState : HermesSseState) : HermesSseState :=
  let initCur? :=
    turn.eventCursor?.orElse (fun _ =>
      initState.eventCursor?.orElse (fun _ =>
        if initState.hasCursor && initState.lastCursor != 0 then some initState.lastCursor else none))
  let pend? :=
    if turn.phase == .waitingApproval then turn.approval?.orElse (fun _ => initState.pendingApproval?)
    else if turn.phase.isTerminal || turn.phase == .cancelRequested then none
    else initState.pendingApproval?
  let termSt? :=
    if turn.phase.isTerminal then
      initState.terminalStatus?.orElse (fun _ =>
        some (if turn.cancel == .confirmedReceipt then "cancelled"
              else if turn.errorKind != .none then "failed"
              else "completed"))
    else if turn.phase == .cancelRequested then none
    else initState.terminalStatus?
  let termErr? :=
    if turn.phase.isTerminal then
      initState.terminalError?.orElse (fun _ => if turn.detail.isEmpty then none else some turn.detail)
    else if turn.phase == .cancelRequested then none
    else initState.terminalError?
  { lastCursor := initCur?.getD 0
    hasCursor := initCur?.isSome
    submittedAtMs? := turn.submittedAtMs?.orElse (fun _ => initState.submittedAtMs?)
    eventCursor? := initCur?
    pendingApproval? := pend?
    accumulatedText := initState.accumulatedText
    terminalStatus? := termSt?
    terminalError? := termErr? }

/-- Already-terminal turns, and cancel requests that already hold a termination receipt, are sticky. -/
def hermesPollSettled (turn : CloudTurnState) (view : HermesSseState) : Bool :=
  turn.phase.isTerminal || (turn.phase == .cancelRequested && turn.cancel == .confirmedReceipt) ||
    (view.terminalStatus?.isSome && turn.phase != .cancelRequested)

/-- Step a Hermes SSE chunk across both `(HermesSseState, CloudTurnState)`. -/
def stepHermesTurnChunk
    (sseSt : HermesSseState)
    (turn : CloudTurnState)
    (rawChunk : String)
    (nowMs : UInt64) : HermesSseState × CloudTurnState × Array HermesSseEvent × List CloudTurnEffect := Id.run do
  let seeded := seedHermesView turn sseSt
  if hermesPollSettled turn seeded then
    return (seeded, turn, #[], [])
  let (nextSse, evs) := stepHermesSseChunk seeded rawChunk
  let mut curTurn := turn
  let mut allEffs : List CloudTurnEffect := []
  for ev in evs do
    let (t1, effs) := applyHermesEventToTurn curTurn ev nowMs
    curTurn := t1
    allEffs := allEffs ++ effs
  if curTurn == turn && allEffs.isEmpty then
    return (seeded, turn, #[], [])
  let finalTurn := { curTurn with stateRevision := turn.stateRevision + 1 }
  let syncedSse : HermesSseState := {
    nextSse with
    submittedAtMs? := finalTurn.submittedAtMs?.orElse (fun _ => nextSse.submittedAtMs?)
    eventCursor? := finalTurn.eventCursor?.orElse (fun _ => seeded.eventCursor?)
    hasCursor := finalTurn.eventCursor?.isSome || seeded.hasCursor
    lastCursor := (finalTurn.eventCursor?.orElse (fun _ => seeded.eventCursor?)).getD seeded.lastCursor
    pendingApproval? := finalTurn.approval?
    terminalStatus? := if finalTurn.phase.isTerminal then nextSse.terminalStatus? else none
    terminalError? := if finalTurn.phase.isTerminal then nextSse.terminalError? else none
  }
  return (syncedSse, finalTurn, evs, allEffs)

/-- Fold a `/v1/runs/{runId}` JSON body into `CloudTurnState` via `applyHermesEventToTurn`.
    A sticky terminal (or a settled cancel receipt) emits nothing and does not move the cursor.
    `waitingApproval` plus provider `"running"` emits `.approvalResolved` and returns to `.running`.
    `cancelRequested` finalizes only on an explicit `"cancelled"` / `"failed"` / `"completed"` receipt. -/
def applyHermesJsonFallback
    (turn : CloudTurnState)
    (view : HermesSseState)
    (jv : JVal)
    (nowMs : UInt64) : CloudTurnState × HermesSseState × Array HermesSseEvent × List CloudTurnEffect :=
  if hermesPollSettled turn view then
    (turn, view, #[], [])
  else
    let statusStr := (jv.fieldStr? "status").getD "running"
    let outText :=
      (jv.fieldStr? "output").orElse (fun _ => jv.fieldStr? "response")
      |>.orElse (fun _ => jv.fieldStr? "text") |>.getD ""
    let initCur := view.eventCursor?.getD (if view.hasCursor then view.lastCursor else 0)
    let baseCur := max (cursorOf turn) initCur
    let jsonCur :=
      ((jv.fieldUInt64? "event_cursor").orElse (fun _ => jv.fieldUInt64? "cursor")
        |>.orElse (fun _ => jv.fieldUInt64? "seq")).getD 0
    let nextCur := if jsonCur > baseCur then jsonCur else baseCur + 1
    let pendingFromJson? := parseHermesApproval? jv
    let ev? : Option HermesSseEvent :=
      match statusStr with
      | "waiting_approval" | "waiting_user" | "approval_required" =>
        match pendingFromJson? with
        | some req => some (.waitingApproval nextCur req)
        | none => none
      | "running" | "in_progress" | "resumed" =>
        match pendingFromJson? with
        | some req =>
          if turn.phase == .running then some (.waitingApproval nextCur req) else none
        | none =>
          if turn.phase == .waitingApproval || view.pendingApproval?.isSome then
            some (.approvalResolved nextCur)
          else if !outText.isEmpty && outText != view.accumulatedText then
            some (.textDelta nextCur outText)
          else
            none
      | "completed" | "succeeded" =>
        some (.completed nextCur (if outText.isEmpty then view.accumulatedText else outText))
      | "failed" | "error" =>
        some (.failed nextCur (((jv.fieldStr? "error").orElse (fun _ => jv.fieldStr? "message")).getD "Hermes run failed"))
      | "cancelled" | "canceled" =>
        some (.cancelled nextCur)
      | _ =>
        if !outText.isEmpty && outText != view.accumulatedText then some (.textDelta nextCur outText)
        else none
    match ev? with
    | none => (turn, view, #[], [])
    | some ev =>
      let (nextTurn, effs) :=
         match ev with
        | .approvalResolved cur =>
          if turn.phase == CloudTurnPhase.waitingApproval then applyHermesEventToTurn turn ev nowMs
          else (advanceRunningCursor turn cur, [])
        | _ => applyHermesEventToTurn turn ev nowMs
      if nextTurn == turn && effs.isEmpty then
        (turn, view, #[], [])
      else
        let text :=
          match ev with
          | .textDelta _ d => d
          | .completed _ t => t
          | _ => if outText.isEmpty then view.accumulatedText else outText
        let (termSt, termErr) :=
          match ev with
          | .completed _ _ => (some "completed", none)
          | .failed _ err => (some "failed", some err)
          | .cancelled _ => (some "cancelled", none)
          | _ => (none, none)
        (nextTurn, hermesViewOf nextTurn text termSt termErr, #[ev], effs)

/-- Connect to Hermes SSE `/v1/runs/{runId}/events?after={cursor}` with automatic JSON fallback (`/v1/runs/{runId}`).
    Both paths step the authoritative `CloudTurnState`. When `store?` is supplied, a changed turn is
    persisted with `persistCloudTurn` using the pre-step `stateRevision` (`0` inserts revision `1`). -/
def streamOrFallbackHermesRun
    (hermesBaseUrl runId : String)
    (bearerToken? : Option String)
    (turn : CloudTurnState)
    (initState : HermesSseState := {})
    (store? : Option CoreStore := none)
    (nowMs : UInt64 := 0) : IO (Except String (HermesSseState × CloudTurnState × Array HermesSseEvent)) := do
  let view0 := seedHermesView turn initState
  if hermesPollSettled turn view0 then
    return .ok (view0, turn, #[])
  let base := stripTrailingSlash hermesBaseUrl.trimAscii.toString
  let afterParam := match view0.eventCursor? with | some c => s!"?after={c}" | none => "?after=0"
  let sseUrl := s!"{base}/v1/runs/{runId}/events{afterParam}"
  let mut hdrs : Array (String × String) := #[("Accept", "text/event-stream, application/json")]
  if let some tok := bearerToken? then
    if !tok.isEmpty then
      hdrs := hdrs.push ("Authorization", s!"Bearer {tok}")
  let stepped ←
    match ← sendRequest "GET" sseUrl hdrs ByteArray.empty 15000 with
    | .error e => return .error e
    | .ok resp =>
      let ct := ((resp.headers.find? (fun (k, _) => k.toLower == "content-type")).map Prod.snd).getD ""
      let bodyStr := String.fromUTF8? resp.body |>.getD ""
      if resp.status == 200 && (containsSubstr ct.toLower "text/event-stream" || bodyStr.trimAscii.toString.startsWith "data:" || bodyStr.trimAscii.toString.startsWith "id:" || bodyStr.trimAscii.toString.startsWith "event:") then
        let (sse1, turn1, evs, _) := stepHermesTurnChunk view0 turn bodyStr nowMs
        pure (turn1, sse1, evs)
      else if resp.status != 404 && resp.status != 405 && resp.status != 501 && resp.status != 200 then
        return .error s!"Hermes events endpoint returned HTTP {resp.status}"
      else
        let jsonUrl := s!"{base}/v1/runs/{runId}"
        match ← sendJsonRequest "GET" jsonUrl bearerToken? none #[] 10000 with
        | .error e => return .error e
        | .ok (jStatus, _, jBody?) =>
          if jStatus < 200 || jStatus ≥ 300 then
            return .error s!"Hermes run status endpoint returned HTTP {jStatus}"
          let jv := jBody?.getD (.obj #[])
          let (turn1, view1, evs, _) := applyHermesJsonFallback turn view0 jv nowMs
          pure (turn1, view1, evs)
  let (turn1, view1, evs) := stepped
  if let some store := store? then
    if turn1 != turn || turn1.stateRevision != turn.stateRevision then
      match ← persistCloudTurn store.missionsDb turn1 turn.stateRevision with
      | .error e => return .error e
      | .ok written =>
        return .ok (hermesViewOf written view1.accumulatedText view1.terminalStatus? view1.terminalError?, written, evs)
  return .ok (view1, turn1, evs)

/-- Load (or initialize) a Hermes turn in `store`, run `streamOrFallbackHermesRun`, and CAS-persist any change. -/
def syncHermesTurnWithStore
    (store : CoreStore)
    (hermesBaseUrl runId : String)
    (bearerToken? : Option String)
    (fallbackTurn : CloudTurnState)
    (initState : HermesSseState := {})
    (nowMs : UInt64 := 0) : IO (Except String (HermesSseState × CloudTurnState × Array HermesSseEvent)) := do
  match ← loadCloudTurn? store.missionsDb fallbackTurn.missionId fallbackTurn.turnIndex with
  | .error e => return .error e
  | .ok turn? =>
    let activeTurn := turn?.getD { fallbackTurn with stateRevision := 0 }
    streamOrFallbackHermesRun hermesBaseUrl runId bearerToken? activeTurn initState (some store) nowMs

/-! ### 4. Cloud-to-Workspace Handoff & Native Mission Fork (`POST /api/control/missions/:id/fork`) -/

def isCloudBackendName (backend : String) : Bool :=
  backend.trimAscii.toString.toLower.startsWith "cloud_"

def isNativeWorkspaceBackendName (backend : String) : Bool :=
  match backend.trimAscii.toString.toLower with
  | "claudecode" | "codex" | "opencode" | "grok" | "antigravity" | "vibe" => true
  | _ => false

structure ForkMissionRequest where
  sourceMissionId  : String
  newMissionId     : String
  targetBackend?   : Option String := none
  modelOverride?   : Option String := none
  modelEffort?     : Option String := none
  workingDir?      : Option String := none
  remoteNodeId?    : Option String := none
  title?           : Option String := none
  sideQuestion     : Bool          := false
  sidePrompt?      : Option String := none
  ownerUserId      : String        := ""
  nowAt            : String
  deriving Repr, DecidableEq

structure ForkMissionOutcome where
  missionId           : String
  forkedFrom          : String
  title               : String
  backend             : String
  modelOverride       : String
  modelEffort         : String
  workingDirectory    : String
  remoteNodeId?       : Option String
  turnsCopied         : Nat
  usedCloudTurns      : Bool
  sharedSourceWorkdir : Bool
  freshWorkspace      : Bool
  tagsJson            : String
  deriving Repr, DecidableEq

/-- Synthesize canonical `(role, content)` turns from `cloud_executions`, `missions.history_json`, or `mission_events`. -/
def loadCanonicalMissionTurns (st : CoreStore) (missionId : String) (preferCloudExecutions : Bool)
    : IO (Array (String × String)) := do
  let mut turns : Array (String × String) := #[]
  if preferCloudExecutions then
    if let .ok cRows ← execParamQuery st.missionsDb
        "SELECT prompt, response_text FROM cloud_executions WHERE mission_id=?1 ORDER BY created_at ASC, rowid ASC;"
        #[missionId] then
      if cRows.size > 1 then
        for i in [1:cRows.size] do
          let r := cRows[i]!
          let p := (r[0]?).getD ""
          let resp := (r[1]?).getD ""
          if !p.trimAscii.toString.isEmpty then
            turns := turns.push ("user", p)
          if !resp.trimAscii.toString.isEmpty then
            turns := turns.push ("assistant", resp)
  if turns.isEmpty then
    if let .ok hRows ← execParamQuery st.missionsDb
        "SELECT history_json FROM missions WHERE id=?1;" #[missionId] then
      if hRows.size > 1 then
        let rawHist := (hRows[1]?.bind (·[0]?)).getD "[]"
        if let .ok (.arr items) := OrbBin.Json.parse rawHist then
          for it in items do
            let role := (it.fieldStr? "role").getD ""
            let content := (it.fieldStr? "content").getD ""
            if (role == "user" || role == "assistant") && !content.trimAscii.toString.isEmpty then
              turns := turns.push (role, content)
  if turns.isEmpty then
    if let .ok eRows ← execParamQuery st.missionsDb
        "SELECT event_type, payload FROM mission_events WHERE mission_id=?1 ORDER BY seq ASC, id ASC;"
        #[missionId] then
      if eRows.size > 1 then
        for i in [1:eRows.size] do
          let r := eRows[i]!
          let evType := (r[0]?).getD ""
          let payload := (r[1]?).getD ""
          if let .ok jv := OrbBin.Json.parse payload then
            let content :=
              (jv.fieldStr? "content").orElse (fun _ => jv.fieldStr? "text")
              |>.orElse (fun _ => jv.fieldStr? "message") |>.getD ""
            if !content.trimAscii.toString.isEmpty then
              if evType == "user_message" then
                turns := turns.push ("user", content)
              else if evType == "assistant_message" || evType == "agent_message" then
                turns := turns.push ("assistant", content)
  return turns

private def encodeTurnsHistoryJson (turns : Array (String × String)) (createdAt : String) : String :=
  let objs := turns.map fun (role, content) =>
    JVal.obj #[
      ("role", .str role),
      ("content", .str content),
      ("created_at", .str createdAt)
    ]
  renderCompact (.arr objs)

/-- Execute a native mission fork or `cloud_*` -> native workspace handoff gated by `Orb.Kernel.cloudHandoffStep`. -/
def forkOrHandoffMission
    (st : CoreStore)
    (defaultWorkDir : String)
    (req : ForkMissionRequest) : IO (Except (Nat × String) ForkMissionOutcome) := do
  let mRows ← execParamQuery st.missionsDb
    "SELECT title,backend,COALESCE(model_override,''),COALESCE(model_effort,''),working_directory,project,authority_mode,placement_kind,tags,COALESCE(owner_user_id,'') FROM missions WHERE id=?1;"
    #[req.sourceMissionId]
  let .ok rs := mRows | return .error (500, "source_mission_query_failed")
  if rs.size ≤ 1 then
    return .error (404, "mission_not_found")
  let row := rs[1]!
  let srcTitle := (row[0]?).getD "Mission"
  let srcBackend := (row[1]?).getD "codex"
  let srcModelOv := (row[2]?).getD ""
  let srcEffort := (row[3]?).getD ""
  let srcWorkDir := (row[4]?).getD ""
  let srcProject := (row[5]?).getD ""
  let srcAuthMode := (row[6]?).getD "writer"
  let srcPlacement := (row[7]?).getD "managed"
  let srcExtraTags := parseStringJsonArray ((row[8]?).getD "[]")
  let srcOwnerUserId := (row[9]?).getD ""

  let srcIsCloud := isCloudBackendName srcBackend
  let targetBackend :=
    match req.targetBackend? with
    | some b =>
      let tb := b.trimAscii.toString.toLower
      if tb.isEmpty then (if srcIsCloud then "codex" else srcBackend) else tb
    | none => if srcIsCloud then "codex" else srcBackend
  let targetIsNative := isNativeWorkspaceBackendName targetBackend

  let turns ← loadCanonicalMissionTurns st req.sourceMissionId srcIsCloud
  let hasHistoryTurns := !turns.isEmpty

  let resolvedWorkDir :=
    match req.workingDir? with
    | some wd =>
      let t := wd.trimAscii.toString
      if !t.isEmpty then t
      else if srcIsCloud || srcWorkDir.trimAscii.toString.isEmpty then defaultWorkDir else srcWorkDir
    | none =>
      if srcIsCloud || srcWorkDir.trimAscii.toString.isEmpty then defaultWorkDir else srcWorkDir

  let remoteNodeClean? :=
    req.remoteNodeId?.bind fun rn =>
      let t := rn.trimAscii.toString
      if t.isEmpty || t == "local" then none else some t

  let placementValid : Bool :=
    !resolvedWorkDir.trimAscii.toString.isEmpty &&
    !(resolvedWorkDir.splitOn "/").any (· == "..") &&
    (match remoteNodeClean? with | some rn => !rn.contains '/' && !rn.contains ' ' | none => true)

  let handoffWord :=
    Orb.Kernel.cloudHandoffStep
      (if srcIsCloud then 1 else 0)
      (if req.sideQuestion then 1 else 0)
      (if targetIsNative then 1 else 0)
      (if hasHistoryTurns then 1 else 0)
      (if placementValid then 1 else 0)

  let admitBit := handoffWord &&& 1
  if admitBit != 1 then
    if !targetIsNative then
      return .error (400, s!"Target backend `{targetBackend}` is not a native workspace harness")
    if !placementValid then
      return .error (400, "Invalid target workspace placement for mission fork/handoff")
    if srcIsCloud && req.sideQuestion then
      return .error (400, "Side-questions (`/btw`) cannot be forked from cloud missions; use Continue in workspace instead")
    if srcIsCloud && !hasHistoryTurns then
      return .error (422, "Cloud mission has no completed conversation turns to hand off into a workspace yet")
    return .error (400, "Mission fork/handoff rejected by cloudHandoffStep")

  let useCloudTurns := ((handoffWord >>> 8) &&& 1) == 1
  let shareSourceWs := ((handoffWord >>> 16) &&& 1) == 1
  let freshWs := ((handoffWord >>> 24) &&& 1) == 1

  let mut customTags := srcExtraTags.filter fun t =>
    !(t.startsWith "fork-workspace:") && !(t.startsWith "forked-from:") && !(t.startsWith "remote-node:")
  customTags := customTags.push s!"forked-from:{req.sourceMissionId}"
  if shareSourceWs && !freshWs then
    customTags := customTags.push s!"fork-workspace:{req.sourceMissionId}"
  if req.sideQuestion then
    customTags := customTags.push "side-question"
  if let some rn := remoteNodeClean? then
    customTags := customTags.push s!"remote-node:{rn}"

  let nextAuthMode := if req.sideQuestion then "readonly" else srcAuthMode
  let nextPlacement :=
    if remoteNodeClean?.isSome then "remote_node"
    else if srcIsCloud then "local"
    else srcPlacement
  let nextTitle :=
    match req.title? with
    | some t => if t.trimAscii.toString.isEmpty then srcTitle else t.trimAscii.toString
    | none => srcTitle
  let nextModelOv :=
    match req.modelOverride? with
    | some m => m.trimAscii.toString
    | none => if srcIsCloud then "" else srcModelOv
  let nextEffort :=
    match req.modelEffort? with
    | some e => e.trimAscii.toString.toLower
    | none => if srcIsCloud then "" else srcEffort

  let mut finalTurns := turns
  if let some sp := req.sidePrompt? then
    let trimmedSp := sp.trimAscii.toString
    if !trimmedSp.isEmpty then
      finalTurns := finalTurns.push ("user", trimmedSp)

  let initTagsJson := projectCompatibilityTagsJson nextAuthMode nextPlacement "" "" 0 customTags
  let mRec : MissionRecord := {
    id := req.newMissionId
    title := nextTitle
    status := "awaiting_user"
    backend := targetBackend
    modelOverride := nextModelOv
    modelEffort := nextEffort
    workingDirectory := resolvedWorkDir
    project := srcProject
    updatedAt := req.nowAt
    totalCostCents := 0
    authorityMode := nextAuthMode
    placementKind := nextPlacement
    reservedDiskGib := 0
    nodeBootEpoch := st.bootEpoch
    tagsJson := initTagsJson
    ownerUserId := if !req.ownerUserId.isEmpty then req.ownerUserId else srcOwnerUserId
  }
  match ← insertNewMission st mRec with
  | .error "mission_already_exists" =>
    return .error (409, "mission_already_exists")
  | .error e =>
    return .error (500, e)
  | .ok () =>
    let histJson := encodeTurnsHistoryJson finalTurns req.nowAt
    discard <| execParamQuery st.missionsDb
      "UPDATE missions SET history_json=?2 WHERE id=?1;"
      #[req.newMissionId, histJson]
    let mut seq : Nat := 1
    for (role, content) in finalTurns do
      let evType := if role == "user" then "user_message" else "assistant_message"
      let evPayload := renderCompact (.obj #[
        ("type", .str evType),
        ("role", .str role),
        ("content", .str content),
        ("mission_id", .str req.newMissionId)
      ])
      discard <| execParamQuery st.missionsDb
        "INSERT INTO mission_events(mission_id,seq,event_type,payload,created_at) VALUES(?1,?2,?3,?4,?5);"
        #[req.newMissionId, s!"{seq}", evType, evPayload, req.nowAt]
      seq := seq + 1
    return .ok {
      missionId := req.newMissionId
      forkedFrom := req.sourceMissionId
      title := nextTitle
      backend := targetBackend
      modelOverride := nextModelOv
      modelEffort := nextEffort
      workingDirectory := resolvedWorkDir
      remoteNodeId? := remoteNodeClean?
      turnsCopied := finalTurns.size
      usedCloudTurns := useCloudTurns
      sharedSourceWorkdir := shareSourceWs
      freshWorkspace := freshWs
      tagsJson := initTagsJson
    }

end OrbCore.MemoryAndCloud
