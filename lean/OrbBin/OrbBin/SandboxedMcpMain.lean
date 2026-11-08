/-
  OrbBin.SandboxedMcpMain: Unified Control-Plane MCP Client, Secret Broker & Harness Launcher (`sandboxed-mcp`).
  Replaces `src/bin/sandboxed_mcp.rs` + `src/control_mcp/{client,launch,protocol,antigravity}.rs` in native Lean 4.
-/
import Std.Sync.Mutex
import Orb.Kernel
import OrbBin.Spec
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbBin.McpCatalog
import OrbBin.McpRegistry
import OrbBin.StdioMcpServer

namespace OrbBin.SandboxedMcp

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient
open OrbBin.StdioMcpServer

def appVersion : String := "1.3.0"
def contractVersion : String := OrbBin.McpCatalog.contractVersion

def controlPlaneEnvVars : Array String := #[
  "JWT_SECRET",
  "API_SERVER_KEY",
  "HERMES_SANDBOXED_API_TOKEN",
  "SANDBOXED_API_TOKEN",
  "OPEN_AGENT_API_TOKEN",
  "API_TOKEN",
  "SANDBOXED_MCP_TOKEN",
  "SANDBOXED_MCP_TOKEN_FILE",
  "SANDBOXED_MCP_WRAPPER"
]

private def validateCoreUrl (apiUrl : String) : Except String String := do
  let parsed ← parseUrl apiUrl
  let isLoopback :=
    parsed.host == "127.0.0.1" || parsed.host == "localhost" || parsed.host == "::1"
  if !parsed.isHttps && !isLoopback then
    throw "Core requires HTTPS except on loopback"
  let mut trimmed := apiUrl.trimAscii.toString
  while trimmed.endsWith "/" do
    trimmed := (trimmed.dropEnd 1).toString
  return trimmed

def decodeMcpTokenSessionId? (token : String) : Option String := do
  if !token.startsWith "mcp1." then none
  let jwt := (token.drop 5).toString
  match jwt.splitOn "." with
  | _ :: payloadB64 :: _ =>
    let bytes ← base64Decode? payloadB64
    let v ← (Json.parseBytes bytes).toOption
    let sid ← v.fieldStr? "session_id"
    parseUuidCanonical? sid
  | _ => none

private def isSafeSecretFileName (name : String) : Bool :=
  !name.isEmpty && name.all (fun c =>
    ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_' || c == '-')

/-- Persist a renewed `mcp1.*` credential atomically (`0600`), guarded by `verifyMcpSecretPersistence`
    over real filesystem observations (private non-symlink parent directory + exclusive `0600` file). -/
def persistScopedCredential (path : System.FilePath) (token : String) : IO (Except String Unit) := do
  let hasPrefix : UInt8 := if token.startsWith "mcp1." then 1 else 0
  if hasPrefix != 1 then
    return .error "Core returned an invalid scoped credential"
  let parent := path.parent.getD (System.FilePath.mk ".")
  let ps := parent.toString
  if ps != "." && ps != "/" && ps != "/tmp" && ps != "/var/tmp" && ps != "/private/tmp" then
    let _ ← ensurePrivateDir0700 parent
  else
    IO.FS.createDirAll parent
  let pst ← statPath ps
  let isStickySharedTmp := ps == "/tmp" || ps == "/var/tmp" || ps == "/private/tmp"
  let dirPriv : UInt8 :=
    if pst.exists_ && pst.isDir && ((pst.ownedByEuid && (pst.mode &&& 0o077) == 0) || isStickySharedTmp) then 1 else 0
  let dirNotSym : UInt8 := if !pst.isSymlink then 1 else 0
  let fileName := path.fileName.getD ""
  let safeName : UInt8 := if !fileName.isEmpty && !fileName.contains '/' && fileName != "." && fileName != ".." then 1 else 0
  let preGate := OrbBin.Spec.verifyMcpSecretPersistence hasPrefix dirPriv dirNotSym 1 safeName
  if preGate != 1 then
    return .error "Credential parent directory failed verified private confinement check"
  match (← writeAtomicPrivate0600 path token.toUTF8) with
  | .error e => return .error e
  | .ok () =>
    let fst ← statPath path.toString
    let fileMode0600 : UInt8 :=
      if fst.exists_ && !fst.isSymlink && fst.isReg && fst.ownedByEuid && (fst.mode &&& 0o777) == 0o600 then 1 else 0
    let postGate := OrbBin.Spec.verifyMcpSecretPersistence hasPrefix dirPriv dirNotSym fileMode0600 safeName
    if postGate != 1 then
      try IO.FS.removeFile path catch _ => pure ()
      return .error "Persisted credential failed post-write 0600 verification"
    return .ok ()

/-- Compute per-session private secrets directory (`SANDBOXED_SECRETS_DIR`, `XDG_RUNTIME_DIR/paloma-secrets`, or `$HOME/.paloma-secrets`). -/
def secretsDirFor (missionId? sessionId? overrideDir? : Option String) : IO System.FilePath := do
  if let some ov := overrideDir? then
    if !ov.isEmpty then return System.FilePath.mk ov
  if let some envOv ← getEnvNonEmpty "SANDBOXED_SECRETS_DIR" then
    return System.FilePath.mk envOv
  let base ←
    if let some xdg ← getEnvNonEmpty "XDG_RUNTIME_DIR" then
      pure (System.FilePath.mk xdg / "paloma-secrets")
    else if let some home ← getEnvNonEmpty "HOME" then
      pure (System.FilePath.mk home / ".paloma-secrets")
    else
      pure (System.FilePath.mk ".paloma-secrets")
  let envMid ← firstEnvNonEmpty ["SANDBOXED_SH_MISSION_ID", "MISSION_ID"]
  let rawSub :=
    match missionId? with
    | some mid => mid
    | none =>
      match envMid with
      | some em => em
      | none =>
        match sessionId? with
        | some sid => s!"session-{sid}"
        | none => "session"
  let safeSub := String.ofList (rawSub.toList.map (fun c => if c == '/' || c == '.' then '_' else c))
  return base / safeSub

/-- Materialize `secret_delivery` into a `0600` file inside `dir` (`0700`), replacing `secret_delivery` with `path`/`export`/`message`. -/
def deliverSecretIn (dir : System.FilePath) (result : JVal) : IO JVal := do
  let some delivery := result.field? "secret_delivery" | return result
  let stripped := result.removeField "secret_delivery"
  let name := (delivery.fieldStr? "name").getD ""
  let value := (delivery.fieldStr? "value").getD ""
  let safeNameFlag : UInt8 := if isSafeSecretFileName name then 1 else 0
  if safeNameFlag != 1 then
    return stripped.setField "error" (.str "Secret name is not a safe file name; value withheld")
  match (← ensurePrivateDir0700 dir) with
  | .error e =>
    return stripped.setField "error" (.str s!"Could not write the secret file: {e}")
  | .ok () =>
    let st ← statPath dir.toString
    let dirPriv : UInt8 := if st.exists_ && st.isDir && st.ownedByEuid && (st.mode &&& 0o077) == 0 then 1 else 0
    let dirNoSym : UInt8 := if !st.isSymlink then 1 else 0
    let gate := OrbBin.Spec.verifyMcpSecretPersistence 1 dirPriv dirNoSym 1 safeNameFlag
    if gate != 1 then
      return stripped.setField "error" (.str "Secret directory failed verified confinement check")
    let target := dir / name
    match (← writeAtomicPrivate0600 target value.toUTF8) with
    | .error e =>
      return stripped.setField "error" (.str s!"Could not write the secret file: {e}")
    | .ok () =>
      let fst ← statPath target.toString
      let fileMode0600 : UInt8 :=
        if fst.exists_ && !fst.isSymlink && fst.isReg && fst.ownedByEuid && (fst.mode &&& 0o777) == 0o600 then 1 else 0
      let postGate := OrbBin.Spec.verifyMcpSecretPersistence 1 dirPriv dirNoSym fileMode0600 safeNameFlag
      if postGate != 1 then
        try IO.FS.removeFile target catch _ => pure ()
        return stripped.setField "error" (.str "Delivered secret file failed post-write 0600 verification")
      let shown := target.toString
      let s1 := stripped.setField "path" (.str shown)
      let s2 := s1.setField "export" (.str s!"export {name}=\"$(cat '{shown}')\"")
      return s2.setField "message" (.str "Value written to the private file at `path`. Load it with the `export` line; never print it.")

structure McpClient where
  apiUrl             : String
  inlineToken        : String
  tokenFile?         : Option System.FilePath
  role               : String
  missionId?         : Option String
  project?           : Option String
  clientLabel?       : Option String
  hostHint?          : Option String
  secretsDirOverride : Option String
  preflightCache?    : Option System.FilePath
  sessionLock        : Std.Mutex (Option (String × Int))
  resolvedSessionId  : Std.Mutex (Option String)
  stdioRegistry      : OrbBin.McpRegistry.McpStdioRegistry

def McpClient.create
    (rawApiUrl inlineToken : String)
    (tokenFile? : Option System.FilePath)
    (role : String)
    (missionId? : Option String)
    (project? : Option String := none)
    (clientLabel? : Option String := none)
    (hostHint? : Option String := none)
    (secretsDirOverride : Option String := none)
    (preflightCache? : Option System.FilePath := none) : IO (Except String McpClient) := do
  match validateCoreUrl rawApiUrl with
  | .error e => return .error e
  | .ok apiUrl =>
    let sessionLock ← Std.Mutex.new none
    let resolvedSessionId ← Std.Mutex.new (decodeMcpTokenSessionId? inlineToken)
    let stdioRegistry ← OrbBin.McpRegistry.McpStdioRegistry.new
    return .ok {
      apiUrl
      inlineToken
      tokenFile?
      role
      missionId?
      project?
      clientLabel?
      hostHint?
      secretsDirOverride
      preflightCache?
      sessionLock
      resolvedSessionId
      stdioRegistry
    }

private def readCredentialRaw (c : McpClient) : IO (Except String String) := do
  let raw ← match c.tokenFile? with
    | some p =>
      try
        IO.FS.readFile p
      catch _ =>
        return .error "Cannot read MCP credential file"
    | none => pure c.inlineToken
  let trimmed := raw.trimAscii.toString
  if trimmed.isEmpty then
    return .error "Missing MCP credential"
  return .ok trimmed

/-- Obtain or renew a valid `mcp1.*` scoped session token. -/
def McpClient.getToken
    (c : McpClient)
    (cancelled? : Option (IO.Ref Bool) := none) : IO (Except String String) := do
  let checkCancelled : IO Bool := do
    match cancelled? with
    | some cRef => cRef.get
    | none => pure false
  if (← checkCancelled) then
    return .error "Request cancelled; accepted actions continue"
  let cred ← match (← readCredentialRaw c) with
    | .ok s => pure s
    | .error e => return .error e
  c.sessionLock.atomically do
    if (← checkCancelled) then
      return .error "Request cancelled; accepted actions continue"
    let cached ← get
    let nowSec : Int := Int.ofNat (← nowEpoch).toNat
    if let some (tok, exp) := cached then
      if exp > nowSec + 120 then
        return .ok tok
    let mut curCached := cached
    if cred.startsWith "mcp1." && curCached.isNone then
      if let some sid := decodeMcpTokenSessionId? cred then
        c.resolvedSessionId.atomically (set (some sid))
      if (← checkCancelled) then
        return .error "Request cancelled; accepted actions continue"
      match (← sendJsonRequest "GET" s!"{c.apiUrl}/api/mcp/capabilities" (some cred) none) with
      | .error _ => return .error "Core is unavailable"
      | .ok (status, _, caps?) =>
        if status != 401 then
          if status < 200 || status ≥ 300 then
            return .error s!"Core refused scoped session ({status})"
          let some caps := caps? | return .error "Invalid capabilities response"
          if let some ident := caps.field? "identity" then
            if let some sidStr := ident.fieldStr? "session_id" then
              if let some sid := parseUuidCanonical? sidStr then
                c.resolvedSessionId.atomically (set (some sid))
          let some limits := caps.field? "limits" | return .error "Missing session limits"
          let some expiry := limits.fieldInt? "session_expires_at" | return .error "Missing session expiry"
          curCached := some (cred, expiry)
          set curCached
          if expiry > nowSec + 120 && c.clientLabel?.isNone && c.hostHint?.isNone then
            return .ok cred
    if (← checkCancelled) then
      return .error "Request cancelled; accepted actions continue"
    let isScoped := cred.startsWith "mcp1."
    let auth :=
      if c.tokenFile?.isSome then cred
      else
        match curCached with
        | some (tok, _) => if isScoped then tok else cred
        | none => cred
    let (path, payload) ←
      if isScoped then
        let mut fields : Array (String × JVal) := #[]
        if let some lbl := c.clientLabel? then
          fields := fields.push ("client_label", .str lbl)
        if let some hh := c.hostHint? then
          fields := fields.push ("host_hint", .str hh)
        pure ("/api/mcp/renew", JVal.obj fields)
      else
        match c.missionId? with
        | some mid =>
          let projVal := match c.project? with | some p => JVal.str p | none => JVal.null
          pure ("/api/mcp/session", JVal.obj #[
            ("role", .str c.role),
            ("mission_id", .str mid),
            ("project", projVal)
          ])
        | none =>
          return .error
            "Missionless MCP clients require a pre-issued `mcp1.*` external session credential (mint one in Orb Settings -> Security -> External MCP Sessions and pass SANDBOXED_MCP_TOKEN or --token-file)"
    match (← sendJsonRequest "POST" s!"{c.apiUrl}{path}" (some auth) (some payload)) with
    | .error _ => return .error "Cannot reach Core to establish MCP session"
    | .ok (status, _, body?) =>
      if status < 200 || status ≥ 300 then
        return .error s!"Core refused MCP session ({status})"
      let some data := body? | return .error "Invalid MCP session response"
      let some newTok := data.fieldStr? "token" | return .error "Missing session token"
      let sidOpt :=
        ((data.fieldStr? "session_id") >>= parseUuidCanonical?).orElse (fun _ => decodeMcpTokenSessionId? newTok)
      if let some sid := sidOpt then
        c.resolvedSessionId.atomically (set (some sid))
      if isScoped then
        if let some tf := c.tokenFile? then
          if let .error pe ← persistScopedCredential tf newTok then
            return .error pe
      let some exp := data.fieldInt? "expires_at" | return .error "Missing expiry"
      set (some (newTok, exp))
      return .ok newTok

inductive CoreRequestOutcome where
  | ok (payload : JVal)
  | preflightFailed (message : String)
  | httpRejected (status : Nat) (message : String) (payload? : Option JVal)
  | transportUncertain (message : String)

def CoreRequestOutcome.toExcept : CoreRequestOutcome → Except String JVal
  | .ok j => .ok j
  | .preflightFailed m => .error m
  | .httpRejected _ m _ => .error m
  | .transportUncertain m => .error m

def McpClient.requestDetailed
    (c : McpClient)
    (path : String)
    (body? : Option JVal := none)
    (cancelled? : Option (IO.Ref Bool) := none) : IO CoreRequestOutcome := do
  for attempt in [0:2] do
    if let some cRef := cancelled? then
      if (← cRef.get) then
        return .preflightFailed "Request cancelled; accepted actions continue"
    let tok ← match (← c.getToken cancelled?) with
      | .ok t => pure t
      | .error e => return .preflightFailed e
    if let some cRef := cancelled? then
      if (← cRef.get) then
        return .preflightFailed "Request cancelled; accepted actions continue"
    let method := if body?.isSome then "POST" else "GET"
    match (← sendJsonRequest method s!"{c.apiUrl}{path}" (some tok) body?) with
    | .error _ =>
      return .transportUncertain "Core connection failed; acceptance is unknown for a submitted mutation"
    | .ok (status, _, respJson?) =>
      if status == 401 && attempt == 0 then
        c.sessionLock.atomically do
          if let some (stTok, _) ← get then
            set (some (stTok, (0 : Int)))
      else if status < 200 || status ≥ 300 then
        return .httpRejected status s!"Core rejected request ({status})" respJson?
      else
        match respJson? with
        | some j => return .ok j
        | none => return .transportUncertain "Invalid Core response"
  return .httpRejected 401 "Core rejected the renewed scoped session; check mission authorization" none

def McpClient.request
    (c : McpClient)
    (path : String)
    (body? : Option JVal := none)
    (cancelled? : Option (IO.Ref Bool) := none) : IO (Except String JVal) := do
  return (← c.requestDetailed path body? cancelled?).toExcept

def preflightCacheMaxTtlSecs : UInt64 := 300

/-- Write a verified `/api/mcp/capabilities` preflight snapshot atomically (`0600`) for zero-RTT child stdio startup. -/
def writePreflightCache
    (path : System.FilePath)
    (missionId role scopedToken : String)
    (sessionExpiresAt : Int)
    (capabilities : JVal) : IO (Except String Unit) := do
  let nowSec ← nowEpoch
  let payload := JVal.obj #[
    ("cached_at", .nat nowSec.toNat),
    ("capabilities", capabilities),
    ("mission_id", .str missionId),
    ("role", .str role),
    ("scoped_token", .str scopedToken),
    ("session_expires_at", .int sessionExpiresAt)
  ]
  writeAtomicPrivate0600 path (renderCompact payload).toUTF8

/-- Attempt to satisfy `McpClient.preflight` from a private `0600` cache file gated by `Orb.Kernel.mcpPreflightCacheGate`.
    Fails closed (`none`) on any permission, symlink, ownership, identity, contract, or TTL violation. -/
private def tryLoadPreflightCache (c : McpClient) : IO (Option JVal) := do
  let some cachePath := c.preflightCache? | return none
  let st ← statPath cachePath.toString
  if !(st.exists_ && !st.isSymlink && st.isReg && st.ownedByEuid && (st.mode &&& 0o777) == 0o600) then
    return none
  let rawBytes ←
    try IO.FS.readBinFile cachePath
    catch _ => return none
  let .ok root := Json.parseBytes rawBytes | return none
  let some cachedAtNat := root.fieldNat? "cached_at" | return none
  let some sessionExp := root.fieldInt? "session_expires_at" | return none
  let some cachedMission := root.fieldStr? "mission_id" | return none
  let some cachedRole := root.fieldStr? "role" | return none
  let some scopedTok := root.fieldStr? "scoped_token" | return none
  if !scopedTok.startsWith "mcp1." then
    return none
  let some caps := root.field? "capabilities" | return none
  let nowSec ← nowEpoch
  let cachedAt := cachedAtNat.toUInt64
  if nowSec < cachedAt then
    return none
  let ageSecs : UInt64 := nowSec - cachedAt
  let ident := caps.fieldOrNull "identity"
  let idMatch : UInt8 :=
    if c.missionId? == some cachedMission &&
       (ident.fieldStr? "mission_id") == some cachedMission &&
       c.role == cachedRole &&
       (ident.fieldStr? "role") == some cachedRole then 1
    else 0
  let contractMatch : UInt8 :=
    if (caps.fieldStr? "contract_version") == some contractVersion then 1 else 0
  let nowInt : Int := Int.ofNat nowSec.toNat
  let sessionUnexpired : UInt8 := if sessionExp > nowInt + 120 then 1 else 0
  let gate :=
    Orb.Kernel.mcpPreflightCacheGate 1 idMatch contractMatch sessionUnexpired ageSecs preflightCacheMaxTtlSecs
  if gate != 1 then
    return none
  if let some sidStr := ident.fieldStr? "session_id" then
    if let some sid := parseUuidCanonical? sidStr then
      c.resolvedSessionId.atomically (set (some sid))
  else if let some sid := decodeMcpTokenSessionId? scopedTok then
    c.resolvedSessionId.atomically (set (some sid))
  c.sessionLock.atomically do
    let cur ← get
    if cur.isNone then
      set (some (scopedTok, sessionExp))
  return some caps

def McpClient.preflight
    (c : McpClient)
    (cancelled? : Option (IO.Ref Bool) := none) : IO (Except String JVal) := do
  if let some cRef := cancelled? then
    if (← cRef.get) then
      return .error "Request cancelled; accepted actions continue"
  if let some cachedCaps ← tryLoadPreflightCache c then
    return .ok cachedCaps
  match (← c.request "/api/mcp/capabilities" none cancelled?) with
  | .error e => return .error e
  | .ok v =>
    if let some ident := v.field? "identity" then
      if let some sidStr := ident.fieldStr? "session_id" then
        if let some sid := parseUuidCanonical? sidStr then
          c.resolvedSessionId.atomically (set (some sid))
    if (v.fieldStr? "contract_version") != some contractVersion then
      return .error "MCP contract version mismatch"
    return .ok v

def McpClient.secretsDir (c : McpClient) : IO System.FilePath := do
  let sid ← c.resolvedSessionId.atomically get
  secretsDirFor c.missionId? sid c.secretsDirOverride

def McpClient.fetchSecretFile
    (c : McpClient) (name : String) (reason? : Option String) (waitSecs : Nat)
    : IO (Except String (System.FilePath × String)) := do
  let trimmed := name.trimAscii.toString
  if trimmed.isEmpty then
    return .error "Secret name cannot be empty"
  let mut argFields : Array (String × JVal) := #[("name", .str trimmed)]
  if let some r := reason? then
    let rt := r.trimAscii.toString
    if !rt.isEmpty then
      argFields := argFields.push ("reason", .str rt)
  let startEpoch ← nowEpoch
  let deadline := startEpoch + waitSecs.toUInt64
  while true do
    let callBody := JVal.obj #[("name", .str "secret_get"), ("arguments", JVal.obj argFields)]
    let reply ← match (← c.request "/api/mcp/call" (some callBody)) with
      | .ok r => pure r
      | .error e => return .error e
    if (reply.fieldBool? "ok") != some true then
      let msg := (((reply.field? "error") >>= (·.fieldStr? "message"))).getD "Secret request refused by Core"
      return .error msg
    let result := reply.fieldOrNull "result"
    if (result.field? "secret_delivery").isSome then
      let dir ← c.secretsDir
      let delivered ← deliverSecretIn dir result
      if let some errStr := delivered.fieldStr? "error" then
        return .error errStr
      let some pathStr := delivered.fieldStr? "path" | return .error "Missing delivered secret file path"
      let some exportLine := delivered.fieldStr? "export" | return .error "Missing delivered secret export line"
      return .ok (System.FilePath.mk pathStr, exportLine)
    if (result.fieldStr? "status") == some "pending" then
      let some reqIdRaw := result.fieldStr? "request_id"
        | return .error "Core returned pending secret request without a valid request_id"
      let some reqId := parseUuidCanonical? reqIdRaw
        | return .error "Core returned pending secret request without a valid request_id"
      let now0 ← nowEpoch
      if now0 ≥ deadline then
        return .error s!"Timed out waiting for approval of secret `{trimmed}` (request {reqId})"
      let mut approved := false
      while !approved do
        let now1 ← nowEpoch
        if now1 ≥ deadline then
          return .error s!"Timed out waiting for approval of secret `{trimmed}` (request {reqId})"
        let remRaw := (deadline - now1).toNat
        let rem := Nat.min 25 (Nat.max 1 remRaw)
        let waitPath := s!"/api/mcp/requests/secret/{reqId}/wait?timeout_secs={rem}"
        let waited ← match (← c.request waitPath none) with
          | .ok w => pure w
          | .error e => return .error e
        match (waited.fieldStr? "status").getD "pending" with
        | "approved" => approved := true
        | "denied" =>
          let reasonErr := ((waited.fieldStr? "error").filter (fun s => !s.isEmpty)).getD "Operator denied access"
          return .error s!"Access to secret `{trimmed}` denied: {reasonErr}"
        | "expired" =>
          return .error s!"Approval request for secret `{trimmed}` expired"
        | _ => pure ()
    else
      let st := (result.fieldStr? "status").getD "unknown"
      return .error s!"Unexpected response from secret_get for `{trimmed}`: {st}"
  return .error "unreachable"

structure ActionReceiptOutcome where
  outcome          : OrbBin.Spec.McpActionOutcomeKind
  receiptSettled   : Bool
  durableSuccess   : Bool
  mayRetryFreshKey : Bool
  packedWord       : UInt32
  deriving Repr, DecidableEq

private def parseReceiptStateTag (s : String) : UInt8 :=
  match s.trimAscii.toString.toLower with
  | "" | "queued" | "pending" => 0
  | "running" | "dispatching" | "in_progress" => 1
  | "completed" | "succeeded" | "settled" => 2
  | "failed" | "rejected" | "cancelled" | "canceled" => 3
  | "reconciliation_required" | "uncertain" => 4
  | _ => 5

private def parseAcceptedJValTag (v : JVal) : UInt8 :=
  match v with
  | .null => 0
  | .bool true => 1
  | .bool false => 2
  | .str s =>
    match s.trimAscii.toString.toLower with
    | "yes" | "true" => 1
    | "no" | "false" => 2
    | "unknown" => 3
    | _ => 4
  | _ => 4

def parseAcceptedTag (receipt : JVal) : UInt8 :=
  let errObj := receipt.fieldOrNull "error"
  match receipt.field? "accepted" with
  | some .null | none =>
    match errObj.field? "accepted" with
    | some v => parseAcceptedJValTag v
    | none => 0
  | some v => parseAcceptedJValTag v

/-- Classify a single Core action receipt through `OrbBin.Spec.verifyMcpActionOutcome`,
    keeping `receipt_settled` (`bit 8`) strictly separate from `action_outcome` (`bits 0..7`). -/
def classifyMcpActionReceipt (receipt : JVal) (transportDropped : Bool := false) : ActionReceiptOutcome :=
  let dropFlag : UInt8 := if transportDropped then 1 else 0
  let stateRaw := ((receipt.fieldStr? "state").orElse (fun _ => receipt.fieldStr? "status")).getD ""
  let statusRaw := ((receipt.fieldStr? "status").orElse (fun _ => receipt.fieldStr? "state")).getD ""
  let stTag := parseReceiptStateTag stateRaw
  let hasErr := match receipt.field? "error" with
    | some .null | none => false
    | some _ => true
  let hasRes : UInt8 :=
    match receipt.field? "result" with
    | some .null | none => 0
    | some _ => if hasErr then 0 else 1
  let accTag := parseAcceptedTag receipt
  let rsTag : UInt8 :=
    let base := parseReceiptStateTag statusRaw
    if base == 0 && statusRaw.isEmpty then
      if accTag == 3 then 4
      else if hasErr || accTag == 2 then 3
      else if hasRes == 1 then 2
      else 0
    else if base == 2 && hasErr then 3
    else base
  let stClean : UInt8 := if stTag ≤ 4 then stTag else 3
  let word := OrbBin.Spec.verifyMcpActionOutcome rsTag accTag stClean dropFlag hasRes
  let kind : OrbBin.Spec.McpActionOutcomeKind :=
    match word &&& 255 with
    | 0 => .pending
    | 1 => .accepted
    | 3 => .uncertainReconciliationRequired
    | _ => .rejected
  { outcome          := kind
    receiptSettled   := ((word >>> 8) &&& 1) == 1
    durableSuccess   := ((word >>> 16) &&& 1) == 1
    mayRetryFreshKey := ((word >>> 24) &&& 1) == 1
    packedWord       := word }

private def annotateActionReceiptJson (receipt : JVal) (transportDropped : Bool := false) : JVal :=
  match receipt with
  | .obj _ =>
    let cls := classifyMcpActionReceipt receipt transportDropped
    let r1 := receipt.setField "receipt_settled" (.bool cls.receiptSettled)
    let r2 := r1.setField "action_outcome" (.str cls.outcome.toWire)
    let r3 := r2.setField "durable_success" (.bool cls.durableSuccess)
    r3.setField "may_retry_fresh_key" (.bool cls.mayRetryFreshKey)
  | other => other

private def isActionReceiptLike (v : JVal) : Bool :=
  match v with
  | .obj _ =>
    (v.field? "action_id").isSome ||
    (v.field? "accepted").isSome ||
    (v.fieldStr? "state") == some "reconciliation_required" ||
    ((v.fieldOrNull "error").field? "accepted").isSome
  | _ => false

/-- Normalize `get_action`, `wait_actions`, and `get_fleet_sweep` payloads so settled receipts
    with `reconciliation_required` or `accepted:"unknown"` never report durable action success. -/
def normalizeWaitActionsResult (payload : JVal) (transportDropped : Bool := false) : JVal := Id.run do
  let mut out := payload
  if isActionReceiptLike out || transportDropped then
    out := annotateActionReceiptJson out transportDropped
  let mut annotatedAny := false
  let mut allSettled := true
  let mut allAccepted := true
  let mut anyReconcile := false
  let mut count : Nat := 0
  for arrKey in ["receipts", "actions"] do
    if let some xs := out.fieldArr? arrKey then
      annotatedAny := true
      let mut mapped : Array JVal := Array.mkEmpty xs.size
      for item in xs do
        let cls := classifyMcpActionReceipt item false
        count := count + 1
        if !cls.receiptSettled then allSettled := false
        if !cls.durableSuccess then allAccepted := false
        if cls.outcome == .uncertainReconciliationRequired then anyReconcile := true
        mapped := mapped.push (annotateActionReceiptJson item false)
      out := out.setField arrKey (.arr mapped)
  if annotatedAny then
    let aggOutcome : OrbBin.Spec.McpActionOutcomeKind :=
      if anyReconcile then .uncertainReconciliationRequired
      else if count > 0 && !allSettled then .pending
      else if count > 0 && allAccepted then .accepted
      else if count == 0 then .accepted
      else .rejected
    out := out.setField "receipt_settled" (.bool (count == 0 || allSettled))
    out := out.setField "action_outcome" (.str aggOutcome.toWire)
    out := out.setField "all_succeeded" (.bool (count == 0 || (allSettled && allAccepted && !anyReconcile)))
    out := out.setField "reconciliation_required" (.bool anyReconcile)
  return out

private def loadConfiguredStdioMcps (reg : OrbBin.McpRegistry.McpStdioRegistry) : IO Unit := do
  let some raw ← getEnvNonEmpty "SANDBOXED_MCP_STDIO_SERVERS" | return
  let .ok (.arr entries) := Json.parse raw | return
  for item in entries do
    if let some name := item.fieldStr? "name" then
      if !name.isEmpty && name != "sandboxed" then
        if let some cmd := item.fieldStr? "command" then
          if !cmd.isEmpty then
            let args := match item.fieldArr? "args" with
              | some xs => xs.filterMap JVal.asStr?
              | none => #[]
            let timeoutMs : UInt32 := ((item.fieldNat? "timeout_ms").getD 5000).toUInt32
            let mut envPairs : Array (String × String) := #[]
            if let some envObj := (item.field? "env") >>= JVal.asObj? then
              for (ek, ev) in envObj do
                if let some sv := ev.asStr? then
                  envPairs := envPairs.push (ek, sv)
            let _ ← OrbBin.McpRegistry.connect reg name cmd args timeoutMs envPairs

private def parseNamespacedStdioTool? (toolName : String) : Option (String × String) :=
  match toolName.splitOn "." with
  | srv :: rest =>
    if !srv.isEmpty && !rest.isEmpty then
      let inner := String.intercalate "." rest
      if !inner.isEmpty then some (srv, inner) else none
    else none
  | _ => none

def McpClient.shutdown (c : McpClient) : IO Unit :=
  OrbBin.McpRegistry.shutdownAll c.stdioRegistry

def McpClient.handleRpc (c : McpClient) (req : JVal) (cancelled : IO.Ref Bool) : IO JVal := do
  let idVal := req.fieldOrNull "id"
  let method := (req.fieldStr? "method").getD ""
  if (← cancelled.get) then
    return jsonRpcError idVal (-32800) "Request cancelled; accepted actions continue"
  match method with
  | "initialize" =>
    match (← c.preflight (some cancelled)) with
    | .ok _ =>
      return jsonRpcSuccess idVal (.obj #[
        ("protocolVersion", .str "2024-11-05"),
        ("serverInfo", .obj #[("name", .str "sandboxed-mcp"), ("version", .str appVersion)]),
        ("capabilities", .obj #[("tools", .obj #[])])
      ])
    | .error e => return jsonRpcError idVal (-32000) e
  | "ping" =>
    return jsonRpcSuccess idVal (.obj #[])
  | "tools/list" =>
    match (← c.preflight (some cancelled)) with
    | .ok v =>
      let coreTools := (v.fieldArr? "tools").getD #[]
      let extPairs ← OrbBin.McpRegistry.listConnectedTools c.stdioRegistry
      let mut merged := coreTools
      for (srvName, tObj) in extPairs do
        if let some tName := tObj.fieldStr? "name" then
          merged := merged.push (tObj.setField "name" (.str s!"{srvName}.{tName}"))
      return jsonRpcSuccess idVal (.obj #[("tools", .arr merged)])
    | .error e => return jsonRpcError idVal (-32000) e
  | "tools/call" =>
    let params := req.fieldOrNull "params"
    match params.fieldStr? "name" with
    | none => return jsonRpcError idVal (-32602) "Missing tool name"
    | some toolName =>
      let arguments := (params.field? "arguments").getD (.obj #[])
      if let some (srvName, extTool) := parseNamespacedStdioTool? toolName then
        if let some _ ← OrbBin.McpRegistry.getEntry? c.stdioRegistry srvName then
          let extParams := JVal.obj #[("name", .str extTool), ("arguments", arguments)]
          match (← OrbBin.McpRegistry.request c.stdioRegistry srvName "tools/call" (some extParams)) with
          | .ok extRes =>
            match extRes with
            | .obj _ =>
              if (extRes.field? "content").isSome then
                return jsonRpcSuccess idVal extRes
              else
                let res := JVal.obj #[
                  ("isError", .bool false),
                  ("structuredContent", extRes),
                  ("content", .arr #[.obj #[("type", .str "text"), ("text", .str (renderCompact extRes))]])
                ]
                return jsonRpcSuccess idVal res
            | other =>
              let wrapped := JVal.obj #[("data", other)]
              let res := JVal.obj #[
                ("isError", .bool false),
                ("structuredContent", wrapped),
                ("content", .arr #[.obj #[("type", .str "text"), ("text", .str (renderCompact wrapped))]])
              ]
              return jsonRpcSuccess idVal res
          | .error errMsg =>
            let errPayload := JVal.obj #[
              ("error", .obj #[
                ("code", .str "external_mcp_error"),
                ("message", .str errMsg),
                ("retryable", .bool true)
              ])
            ]
            let res := JVal.obj #[
              ("isError", .bool true),
              ("structuredContent", errPayload),
              ("content", .arr #[.obj #[("type", .str "text"), ("text", .str (renderCompact errPayload))]])
            ]
            return jsonRpcSuccess idVal res
      let isMutating :=
        OrbBin.McpCatalog.isMutatingControlTool toolName ||
        (arguments.field? "idempotency_key").isSome
      let callBody := JVal.obj #[("name", .str toolName), ("arguments", arguments)]
      let (transportDropped, reply) ← match (← c.requestDetailed "/api/mcp/call" (some callBody) (some cancelled)) with
        | .ok r => pure (false, r)
        | .preflightFailed message =>
          let errFields : Array (String × JVal) :=
            if isMutating then
              #[("code", .str "preflight_failed"), ("message", .str message), ("accepted", .str "no"), ("retryable", .bool true)]
            else
              #[("code", .str "preflight_failed"), ("message", .str message), ("retryable", .bool true)]
          pure (false, JVal.obj #[("ok", .bool false), ("error", .obj errFields)])
        | .httpRejected status message respJson? =>
          let parsedObj? := match respJson? with | some (.obj _) => respJson? | _ => none
          let explicitAccTag : UInt8 := match parsedObj? with | some j => parseAcceptedTag j | none => 0
          let isAmbiguous5xx := status ≥ 500 && explicitAccTag != 2
          if isAmbiguous5xx && isMutating then
            let msg := (((parsedObj?.bind (·.field? "error")) >>= (·.fieldStr? "message"))).getD message
            pure (true, JVal.obj #[
              ("ok", .bool false),
              ("error", .obj #[
                ("code", .str "transport_unavailable"),
                ("message", .str msg),
                ("accepted", .str "unknown"),
                ("retryable", .bool false)
              ])
            ])
          else if let some j := parsedObj? then
            let errBase := match j.field? "error" with
              | some (.obj fs) => JVal.obj fs
              | _ => JVal.obj #[("code", .str s!"http_{status}"), ("message", .str message), ("retryable", .bool (status ≥ 500))]
            let errFixed :=
              if isMutating && explicitAccTag == 0 then
                errBase.setField "accepted" (.str "no")
              else
                errBase
            pure (false, (j.setField "ok" (.bool false)).setField "error" errFixed)
          else
            let errFields : Array (String × JVal) :=
              if isMutating then
                #[("code", .str s!"http_{status}"), ("message", .str message), ("accepted", .str "no"), ("retryable", .bool false)]
              else
                #[("code", .str s!"http_{status}"), ("message", .str message), ("retryable", .bool (status ≥ 500))]
            pure (false, JVal.obj #[("ok", .bool false), ("error", .obj errFields)])
        | .transportUncertain message =>
          if isMutating then
            pure (true, JVal.obj #[
              ("ok", .bool false),
              ("error", .obj #[
                ("code", .str "transport_unavailable"),
                ("message", .str message),
                ("accepted", .str "unknown"),
                ("retryable", .bool false)
              ])
            ])
          else
            pure (false, JVal.obj #[
              ("ok", .bool false),
              ("error", .obj #[
                ("code", .str "transport_unavailable"),
                ("message", .str message),
                ("retryable", .bool true)
              ])
            ])
      let rawFailed := (reply.fieldBool? "ok") != some true
      let rawPayload ←
        if rawFailed then
          pure <| JVal.obj #[("error", reply.fieldOrNull "error")]
        else
          let dir ← c.secretsDir
          deliverSecretIn dir (reply.fieldOrNull "result")
      let normalized :=
        if toolName == "get_action" || toolName == "wait_actions" || toolName == "get_fleet_sweep" ||
           isActionReceiptLike rawPayload || (transportDropped && isMutating) then
          normalizeWaitActionsResult rawPayload (transportDropped && isMutating)
        else
          rawPayload
      let structured :=
        match normalized with
        | .obj _ => normalized
        | other => JVal.obj #[("data", other)]
      let failed :=
        rawFailed ||
        (structured.fieldStr? "action_outcome") == some "reconciliation_required" ||
        ((isActionReceiptLike structured) && (structured.fieldStr? "action_outcome") == some "rejected")
      let res := JVal.obj #[
        ("isError", .bool failed),
        ("structuredContent", structured),
        ("content", .arr #[.obj #[("type", .str "text"), ("text", .str (renderCompact structured))]])
      ]
      return jsonRpcSuccess idVal res
  | _ =>
    return jsonRpcError idVal (-32601) "Method not found"

/-! ### `secret <get|env|exec>` Subcommands -/

inductive SecretGetOut where
  | path
  | exportLine
  deriving Repr, BEq

inductive SecretSubcmd where
  | get  (name : String) (reason? : Option String) (waitSecs : Nat) (out : SecretGetOut)
  | env  (names : Array String) (reason? : Option String) (waitSecs : Nat)
  | exec (names : Array String) (reason? : Option String) (waitSecs : Nat) (command : Array String)
  deriving Repr

private def isGlobalValFlag (f : String) : Bool :=
  f == "--api-url" || f == "--token-file" || f == "--mission-id" || f == "--profile" ||
  f == "--project" || f == "--client-label" || f == "--host-hint" || f == "--preflight-cache"

def parseSecretSubcommand (args : Array String) : Except String (Option SecretSubcmd) := Id.run do
  let mut i := 0
  let mut secretPos? : Option Nat := none
  while i < args.size do
    let a := args[i]!
    if a == "--" then break
    if isGlobalValFlag a then
      i := i + 2
    else if a.startsWith "-" then
      i := i + 1
    else
      if a == "secret" then secretPos? := some i
      break
  let some pos := secretPos? | return .ok none
  let rest := args.extract (pos + 1) args.size
  if rest.isEmpty then
    return .error "Usage: sandboxed-mcp secret <get|env|exec> ..."
  let sub := rest[0]!
  let tail := rest.extract 1 rest.size
  match sub with
  | "get" =>
    let mut name? : Option String := none
    let mut reason? : Option String := none
    let mut waitSecs : Nat := 120
    let mut printPath := false
    let mut printExport := false
    let mut idx := 0
    while idx < tail.size do
      let arg := tail[idx]!
      if isGlobalValFlag arg then
        if idx + 1 ≥ tail.size then return .error s!"Missing value for {arg}"
        idx := idx + 2
      else if arg == "--reason" then
        if idx + 1 ≥ tail.size then return .error "Missing value for --reason"
        reason? := some tail[idx + 1]!
        idx := idx + 2
      else if arg == "--wait-secs" then
        if idx + 1 ≥ tail.size then return .error "Missing value for --wait-secs"
        match tail[idx + 1]!.toNat? with
        | some n => waitSecs := n; idx := idx + 2
        | none => return .error "Invalid integer for --wait-secs"
      else if arg == "--print-path" then
        printPath := true; idx := idx + 1
      else if arg == "--print-export" then
        printExport := true; idx := idx + 1
      else if arg.startsWith "-" then
        return .error s!"Unknown flag for `secret get`: {arg}"
      else if name?.isNone then
        name? := some arg; idx := idx + 1
      else
        return .error s!"Unexpected extra argument `{arg}` for `secret get`"
    if printPath && printExport then
      return .error "Specify at most one of --print-path or --print-export"
    let some nm := name?
      | return .error "Usage: sandboxed-mcp secret get <NAME> [--reason ...] [--wait-secs 120] [--print-path | --print-export]"
    let outMode := if printExport then SecretGetOut.exportLine else SecretGetOut.path
    return .ok (some (.get nm reason? waitSecs outMode))
  | "env" =>
    let mut names : Array String := #[]
    let mut reason? : Option String := none
    let mut waitSecs : Nat := 120
    let mut idx := 0
    while idx < tail.size do
      let arg := tail[idx]!
      if isGlobalValFlag arg then
        if idx + 1 ≥ tail.size then return .error s!"Missing value for {arg}"
        idx := idx + 2
      else if arg == "--reason" then
        if idx + 1 ≥ tail.size then return .error "Missing value for --reason"
        reason? := some tail[idx + 1]!
        idx := idx + 2
      else if arg == "--wait-secs" then
        if idx + 1 ≥ tail.size then return .error "Missing value for --wait-secs"
        match tail[idx + 1]!.toNat? with
        | some n => waitSecs := n; idx := idx + 2
        | none => return .error "Invalid integer for --wait-secs"
      else if arg.startsWith "-" then
        return .error s!"Unknown flag for `secret env`: {arg}"
      else
        names := names.push arg; idx := idx + 1
    if names.isEmpty then
      return .error "Usage: sandboxed-mcp secret env [--reason ...] [--wait-secs 120] <NAME>..."
    return .ok (some (.env names reason? waitSecs))
  | "exec" =>
    let mut sep? : Option Nat := none
    for j in [0:tail.size] do
      if sep?.isNone && tail[j]! == "--" then sep? := some j
    let some sep := sep?
      | return .error "Usage: sandboxed-mcp secret exec [--reason ...] [--wait-secs 120] <NAME>... -- <COMMAND> [ARGS...]"
    let before := tail.extract 0 sep
    let cmd := tail.extract (sep + 1) tail.size
    if cmd.isEmpty then
      return .error "Missing <COMMAND> after `--` in `secret exec`"
    let mut names : Array String := #[]
    let mut reason? : Option String := none
    let mut waitSecs : Nat := 120
    let mut idx := 0
    while idx < before.size do
      let arg := before[idx]!
      if isGlobalValFlag arg then
        if idx + 1 ≥ before.size then return .error s!"Missing value for {arg}"
        idx := idx + 2
      else if arg == "--reason" then
        if idx + 1 ≥ before.size then return .error "Missing value for --reason"
        reason? := some before[idx + 1]!
        idx := idx + 2
      else if arg == "--wait-secs" then
        if idx + 1 ≥ before.size then return .error "Missing value for --wait-secs"
        match before[idx + 1]!.toNat? with
        | some n => waitSecs := n; idx := idx + 2
        | none => return .error "Invalid integer for --wait-secs"
      else if arg.startsWith "-" then
        return .error s!"Unknown flag for `secret exec`: {arg}"
      else
        names := names.push arg; idx := idx + 1
    if names.isEmpty then
      return .error "Specify at least one <NAME> before `--` in `secret exec`"
    return .ok (some (.exec names reason? waitSecs cmd))
  | other =>
    return .error s!"Unknown `secret` subcommand `{other}` (expected get, env, or exec)"

def runSecretCli (client : McpClient) (cmd : SecretSubcmd) : IO (Except String UInt32) := do
  match cmd with
  | .get name reason? waitSecs outMode =>
    match (← client.fetchSecretFile name reason? waitSecs) with
    | .error e => return .error e
    | .ok (path, expLine) =>
      match outMode with
      | .path => IO.println path.toString
      | .exportLine => IO.println expLine
      return .ok 0
  | .env names reason? waitSecs =>
    let mut lines : Array String := #[]
    for nm in names do
      match (← client.fetchSecretFile nm reason? waitSecs) with
      | .error e => return .error e
      | .ok (_, expLine) => lines := lines.push expLine
    for l in lines do
      IO.println l
    return .ok 0
  | .exec names reason? waitSecs command =>
    let mut injected : Array (String × Option String) := #[]
    for k in controlPlaneEnvVars do
      injected := injected.push (k, none)
    for nm in names do
      if !isSafeEnvIdent nm then
        return .error s!"Invalid environment variable name `{nm}`"
      match (← client.fetchSecretFile nm reason? waitSecs) with
      | .error e => return .error e
      | .ok (path, _) =>
        let val ←
          try IO.FS.readFile path
          catch ex => return .error s!"Failed reading private secret file: {ex}"
        injected := injected.push (nm, some val)
    let child ← IO.Process.spawn {
      cmd := command[0]!
      args := command.extract 1 command.size
      env := injected
    }
    let code ← child.wait
    return .ok code

/-! ### `launch --harness <...> ... -- <cmd>` Unified Native Harness Launcher -/

structure OverlayPlan where
  cliFlags : Array String
  envVars  : Array (String × String)
  fileJson : Option JVal

def buildHarnessOverlays
    (harness binary apiUrl credential missionId settingsFile : String)
    (existingEnv : Array (String × String))
    (preflightCache? : Option String := none) : Except String OverlayPlan := do
  let baseSrvArgs : Array JVal := #[
    .str "--api-url", .str apiUrl,
    .str "--token-file", .str credential,
    .str "--mission-id", .str missionId,
    .str "--profile", .str "executor"
  ]
  let srvArgs : Array JVal :=
    match preflightCache? with
    | some pc => baseSrvArgs ++ #[.str "--preflight-cache", .str pc]
    | none => baseSrvArgs
  let serverObj := JVal.obj #[("command", .str binary), ("args", .arr srvArgs)]
  let lookupEnv := fun (k : String) => (existingEnv.find? (fun (ek, _) => ek == k)).map Prod.snd
  match harness with
  | "codex" =>
    let pairs : Array (String × JVal) := #[
      ("command", .str binary),
      ("args", .arr srvArgs),
      ("startup_timeout_sec", JVal.nat 30),
      ("tool_timeout_sec", JVal.nat 60),
      ("enabled", .bool true),
      ("default_tools_approval_mode", .str "approve")
    ]
    let mut cli : Array String := #[]
    for (k, v) in pairs do
      cli := cli.push "-c"
      cli := cli.push s!"mcp_servers.sandboxed.{k}={renderCompact v}"
    return { cliFlags := cli, envVars := #[], fileJson := none }
  | "claudecode" =>
    let file := JVal.obj #[("mcpServers", .obj #[("sandboxed", serverObj)])]
    return { cliFlags := #["--mcp-config", settingsFile], envVars := #[], fileJson := some file }
  | "opencode" =>
    let rawCfg := (lookupEnv "OPENCODE_CONFIG_CONTENT").getD "{}"
    let mut cfg ← match Json.parse rawCfg with
      | .ok v => pure v
      | .error _ => .error "Invalid existing OpenCode inline config"
    if cfg.asObj?.isNone then
      throw "OpenCode inline config must be an object"
    if (cfg.field? "permission").isNone then
      cfg := cfg.setField "permission" (.obj #[
        ("*", .str "allow"),
        ("external_directory", .obj #[("*", .str "allow")]),
        ("doom_loop", .str "allow"),
        ("read", .obj #[("*", .str "allow")])
      ])
    if (cfg.field? "mcp").isNone then
      cfg := cfg.setField "mcp" (.obj #[])
    let some mcpObj := cfg.field? "mcp" | throw "OpenCode mcp config must be an object"
    if mcpObj.asObj?.isNone then
      throw "OpenCode mcp config must be an object"
    let cmdArr := #[JVal.str binary] ++ srvArgs
    let sbEntry := JVal.obj #[
      ("type", .str "local"),
      ("command", .arr cmdArr),
      ("enabled", .bool true),
      ("timeout", JVal.nat 60000)
    ]
    cfg := cfg.setField "mcp" (mcpObj.setField "sandboxed" sbEntry)
    return { cliFlags := #[], envVars := #[("OPENCODE_CONFIG_CONTENT", renderCompact cfg)], fileJson := none }
  | "vibe" =>
    let existingArr ← match lookupEnv "VIBE_MCP_SERVERS" with
      | none => pure #[]
      | some raw =>
        match Json.parse raw with
        | .ok (.arr xs) => pure xs
        | _ => .error "Invalid Vibe MCP configuration"
    let filtered := existingArr.filter (fun s => (s.fieldStr? "name") != some "sandboxed")
    let pushed := filtered.push (.obj #[
      ("name", .str "sandboxed"),
      ("transport", .str "stdio"),
      ("command", .arr #[.str binary]),
      ("args", .arr srvArgs)
    ])
    return { cliFlags := #[], envVars := #[("VIBE_MCP_SERVERS", renderCompact (.arr pushed))], fileJson := none }
  | "grok" =>
    let file := JVal.obj #[
      ("name", .str "sandboxed"),
      ("command", .str binary),
      ("args", .arr srvArgs),
      ("env", .arr #[])
    ]
    return { cliFlags := #[], envVars := #[], fileJson := some file }
  | "antigravity" =>
    let file := JVal.obj #[("mcpServers", .obj #[("sandboxed", serverObj)])]
    return { cliFlags := #[], envVars := #[], fileJson := some file }
  | _ =>
    throw "Harness does not support the unified MCP launcher"

partial def harnessArguments (program : String) (args flags : Array String) : Except String (Array String) := do
  if flags.isEmpty then return args
  let name := (System.FilePath.mk program).fileName.getD program
  if name == "sh" || name == "bash" then
    if args.size ≥ 4 && args[0]! == "-c" && args[1]! == "cat | \"$@\"" && args[2]! == "orb-native-plan" then
      let inner ← harnessArguments args[3]! (args.extract 4 args.size) flags
      return args.extract 0 4 ++ inner
    else
      throw "MCP CLI flags require a native executable or the supported plan-mode wrapper"
  else if name == "node" || name == "bun" then
    if args.isEmpty || args[0]!.startsWith "-" then
      throw "MCP launch requires an explicit CLI script after node or bun"
    return #[args[0]!] ++ flags ++ args.extract 1 args.size
  else
    return flags ++ args

def grokHeadlessProfile (server : JVal) : String :=
  let profile := JVal.obj #[
    ("name", .str "sandboxed-runtime"),
    ("description", .str "Native harness with mission-scoped tools"),
    ("promptMode", .str "extend"),
    ("mcpServers", .arr #[server])
  ]
  s!"---\n{renderCompact profile}\n---\n"

structure AntigravityOverlay where
  configPath : System.FilePath
  original?  : Option ByteArray
  installed  : ByteArray
  lockFd     : Int32

def installAntigravityOverlay (cwd : System.FilePath) (cfg : JVal) : IO (Except String AntigravityOverlay) := do
  let dir := cwd / ".agents"
  let dirSt ← statPath dir.toString
  if dirSt.isSymlink then
    return .error "Antigravity .agents must not be a symlink"
  IO.FS.createDirAll dir
  let lockPath := dir / ".sandboxed-mcp.lock"
  let lockSt ← statPath lockPath.toString
  if lockSt.isSymlink then
    return .error "Antigravity MCP lock must not be a symlink"
  let lockRc ← flockExclusiveNb lockPath.toString
  if lockRc == 0xFFFFFFFF then
    return .error "Cannot open Antigravity MCP lock"
  if lockRc == 0xFFFFFFFE then
    return .error "Another Antigravity run owns this checkout's MCP config; use a separate worktree"
  let lockFd : Int32 := Int32.ofBitVec (BitVec.ofNat 32 lockRc.toNat)
  let cfgPath := dir / "mcp_config.json"
  let cfgSt ← statPath cfgPath.toString
  if cfgSt.isSymlink then
    closeFdRaw lockFd
    return .error "Antigravity MCP config must not be a symlink"
  let original? ←
    if cfgSt.exists_ then
      try
        let b ← IO.FS.readBinFile cfgPath
        pure (some b)
      catch _ =>
        closeFdRaw lockFd
        return .error "Cannot read Antigravity MCP config"
    else
      pure none
  let mut merged ← match original? with
    | none => pure (JVal.obj #[])
    | some bytes =>
      match Json.parseBytes bytes with
      | .ok v => pure v
      | .error _ =>
        closeFdRaw lockFd
        return .error "Invalid Antigravity MCP config"
  if merged.asObj?.isNone then
    closeFdRaw lockFd
    return .error "Antigravity MCP config must be an object"
  if (merged.field? "mcpServers").isNone then
    merged := merged.setField "mcpServers" (.obj #[])
  let some servers := merged.field? "mcpServers"
    | do closeFdRaw lockFd; return .error "Antigravity mcpServers must be an object"
  if servers.asObj?.isNone then
    closeFdRaw lockFd
    return .error "Antigravity mcpServers must be an object"
  if (servers.field? "sandboxed").isSome then
    closeFdRaw lockFd
    return .error "Antigravity workspace already defines sandboxed MCP; remove the stale runtime entry or rename the existing server"
  let sbServer := (cfg.fieldOrNull "mcpServers").fieldOrNull "sandboxed"
  merged := merged.setField "mcpServers" (servers.setField "sandboxed" sbServer)
  let installedBytes := (renderPretty merged).toUTF8
  match (← writeAtomicPrivate0600 cfgPath installedBytes) with
  | .error e =>
    closeFdRaw lockFd
    return .error e
  | .ok () =>
    return .ok { configPath := cfgPath, original?, installed := installedBytes, lockFd }

def restoreAntigravityOverlay (ov : AntigravityOverlay) : IO Unit := do
  let cfgSt ← statPath ov.configPath.toString
  let parentSym ← match ov.configPath.parent with
    | some p => pure (← statPath p.toString).isSymlink
    | none => pure false
  if !cfgSt.isSymlink && !parentSym && cfgSt.exists_ then
    try
      let current ← IO.FS.readBinFile ov.configPath
      if current == ov.installed then
        match ov.original? with
        | some orig => IO.FS.writeBinFile ov.configPath orig
        | none => IO.FS.removeFile ov.configPath
    catch _ => pure ()
  closeFdRaw ov.lockFd

/-- Rewrite `session/new` and `session/load` frames on Grok ACP stdin to inject `server`. -/
def transformGrokAcpFrame (rawFrame : ByteArray) (server : JVal) : Except String ByteArray := do
  match Json.parseBytes rawFrame with
  | .error _ => return rawFrame
  | .ok req =>
    let m := (req.fieldStr? "method").getD ""
    if m == "session/new" || m == "session/load" then
      let some params := req.field? "params" | throw "Invalid ACP session parameters"
      if params.asObj?.isNone then throw "Invalid ACP session parameters"
      let existingServersVal := (params.field? "mcpServers").getD (.arr #[])
      let some serversArr := existingServersVal.asArr? | throw "Invalid ACP MCP servers"
      let filtered := serversArr.filter (fun entry => (entry.fieldStr? "name") != some "sandboxed")
      let updatedParams := params.setField "mcpServers" (.arr (filtered.push server))
      let updatedReq := req.setField "params" updatedParams
      return (renderCompact updatedReq).toUTF8
    else
      return rawFrame

private def forwardGrokAcpStdin (childStdinFd : Int32) (server : JVal) (failedRef : IO.Ref Bool) : IO Unit := do
  let reader ← FdLineReader.new 0
  while true do
    match (← reader.readFrame) with
    | .eof => break
    | .oversized =>
      failedRef.set true
      closeFdRaw childStdinFd
      return
    | .line frame =>
      match transformGrokAcpFrame frame server with
      | .error _ =>
        failedRef.set true
        closeFdRaw childStdinFd
        return
      | .ok outBytes =>
        let payload := outBytes ++ "\n".toUTF8
        let rc ← writeFdAll childStdinFd payload
        if rc != 0 then
          failedRef.set true
          closeFdRaw childStdinFd
          return
  closeFdRaw childStdinFd

private def cleanupRuntimeDir (dir : System.FilePath) : IO Unit := do
  for f in ["credential", "preflight.json", "settings.json", "agent.md"] do
    try IO.FS.removeFile (dir / f) catch _ => pure ()
  try IO.FS.removeDirAll dir catch _ => pure ()

private def containsWindowPair (xs : Array String) (a b : String) : Bool := Id.run do
  if xs.size < 2 then return false
  for i in [0:xs.size - 1] do
    if xs[i]! == a && xs[i + 1]! == b then return true
  return false

def runLaunch (args : Array String) : IO (Except String UInt32) := do
  let mut sep? : Option Nat := none
  for i in [0:args.size] do
    if sep?.isNone && args[i]! == "--" then sep? := some i
  let some sep := sep? | return .error "launch requires -- before the harness command"
  let header := args.extract 0 sep
  let command := args.extract (sep + 1) args.size
  if command.isEmpty then return .error "Missing harness executable"
  let program := command[0]!
  if header.size % 2 != 0 then return .error "Launcher options require values"
  let mut opts : Array (String × String) := #[]
  let mut idx := 0
  while idx < header.size do
    let k := header[idx]!
    let v := header[idx + 1]!
    if !(k == "--harness" || k == "--api-url" || k == "--token-file" || k == "--mission-id") then
      return .error "Unknown launcher option"
    if opts.any (fun (ek, _) => ek == k) then
      return .error "Duplicate launcher option"
    opts := opts.push (k, v)
    idx := idx + 2
  let lookupOpt := fun (k : String) => (opts.find? (fun (ek, _) => ek == k)).map Prod.snd
  let some harness := lookupOpt "--harness" | return .error "Missing --harness"
  let grokAcp := harness == "grok" && containsWindowPair command "agent" "stdio"
  let apiUrlOpt ← match lookupOpt "--api-url" with
    | some u => pure (some u)
    | none => getEnvNonEmpty "SANDBOXED_MCP_API_URL"
  let some apiUrl := apiUrlOpt | return .error "Missing Core MCP URL"
  let tokenFile? := (lookupOpt "--token-file").map System.FilePath.mk
  let envTok := (← getEnvNonEmpty "SANDBOXED_MCP_TOKEN").getD ""
  if tokenFile?.isNone && !envTok.startsWith "mcp1." then
    return .error "Harness launch requires a scoped MCP session or an explicit login file"
  let missionRawOpt ← match lookupOpt "--mission-id" with
    | some m => pure (some m)
    | none => firstEnvNonEmpty ["SANDBOXED_SH_MISSION_ID", "MISSION_ID"]
  let some missionRaw := missionRawOpt | return .error "Missing mission identity"
  let some missionId := parseUuidCanonical? missionRaw | return .error "Invalid mission identity"
  let client ← match (← McpClient.create apiUrl envTok tokenFile? "executor" (some missionId)) with
    | .ok c => pure c
    | .error e => return .error e
  let caps ← match (← client.preflight) with
    | .ok v => pure v
    | .error e => return .error e
  let ident := caps.fieldOrNull "identity"
  if (ident.fieldStr? "mission_id") != some missionId || (ident.fieldStr? "role") != some "executor" then
    return .error "MCP session identity does not match this harness launch"
  let scopedToken ← match (← client.getToken) with
    | .ok t => pure t
    | .error e => return .error e
  let tmpBase := (← firstEnvNonEmpty ["TMPDIR"]).getD "/tmp"
  let nonce ← newUuidV4
  let runtimeDir := System.FilePath.mk tmpBase / s!"sandboxed-mcp-{nonce}"
  if let .error e ← ensurePrivateDir0700 runtimeDir then
    return .error e
  let credPath := runtimeDir / "credential"
  if let .error e ← persistScopedCredential credPath scopedToken then
    cleanupRuntimeDir runtimeDir
    return .error e
  let sessionExpOpt ← client.sessionLock.atomically do
    let s ← get
    return s.map Prod.snd
  let sessionExp :=
    sessionExpOpt.getD (((caps.fieldOrNull "limits").fieldInt? "session_expires_at").getD (Int.ofNat (← nowEpoch).toNat + 900))
  let preflightPath := runtimeDir / "preflight.json"
  let preflightCacheArg? ← match (← writePreflightCache preflightPath missionId "executor" scopedToken sessionExp caps) with
    | .ok () => pure (some preflightPath.toString)
    | .error _ => pure none
  let settingsPath := runtimeDir / "settings.json"
  let selfExe ← IO.appPath
  let existingEnv ← currentEnvPairs
  let overlayPlan ← match buildHarnessOverlays harness selfExe.toString apiUrl credPath.toString missionId settingsPath.toString existingEnv preflightCacheArg? with
    | .ok p => pure p
    | .error e =>
      cleanupRuntimeDir runtimeDir
      return .error e
  let mut flags := overlayPlan.cliFlags
  if let some fj := overlayPlan.fileJson then
    if let .error e ← writeAtomicPrivate0600 settingsPath (renderCompact fj).toUTF8 then
      cleanupRuntimeDir runtimeDir
      return .error e
  if harness == "grok" && !grokAcp then
    let hasCustomAgent := command.any (fun a =>
      a == "--agent" || a == "--agents" || a.startsWith "--agent=" || a.startsWith "--agents=")
    if hasCustomAgent then
      cleanupRuntimeDir runtimeDir
      return .error "A custom Grok agent requires ACP launch to preserve its profile while injecting MCP"
    let some srvJson := overlayPlan.fileJson | do cleanupRuntimeDir runtimeDir; return .error "Missing Grok MCP server"
    let profilePath := runtimeDir / "agent.md"
    if let .error e ← writeAtomicPrivate0600 profilePath (grokHeadlessProfile srvJson).toUTF8 then
      cleanupRuntimeDir runtimeDir
      return .error e
    flags := flags ++ #["--agent", profilePath.toString]
  let agyOverlay? ←
    if harness == "antigravity" then
      let cwd ← IO.currentDir
      let some cfgJson := overlayPlan.fileJson | do cleanupRuntimeDir runtimeDir; return .error "Missing Antigravity MCP config"
      match (← installAntigravityOverlay cwd cfgJson) with
      | .ok ov => pure (some ov)
      | .error e =>
        cleanupRuntimeDir runtimeDir
        return .error e
    else
      pure none
  let finalArgs ← match harnessArguments program (command.extract 1 command.size) flags with
    | .ok a => pure a
    | .error e =>
      if let some ov := agyOverlay? then restoreAntigravityOverlay ov
      cleanupRuntimeDir runtimeDir
      return .error e
  -- Build scrubbed child environment
  let mut childEnvMap : Array (String × String) :=
    existingEnv.filter (fun (k, _) => !controlPlaneEnvVars.contains k)
  for (ok, ov) in overlayPlan.envVars do
    childEnvMap := (childEnvMap.filter (fun (ek, _) => ek != ok)).push (ok, ov)
  let childEnvStrings := childEnvMap.map (fun (k, v) => s!"{k}={v}")
  installTermTrap
  let spawned ←
    try
      spawnPgrp program finalArgs childEnvStrings grokAcp
    catch _ =>
      if let some ov := agyOverlay? then restoreAntigravityOverlay ov
      cleanupRuntimeDir runtimeDir
      return .error "Could not start configured harness"
  let fwdFailed ← IO.mkRef false
  if grokAcp then
    if let some srvJson := overlayPlan.fileJson then
      let _ ← IO.asTask (forwardGrokAcpStdin spawned.stdinFd srvJson fwdFailed)
  -- Supervise child & process group (`kill(-pgid, SIGTERM)` -> 5s -> `SIGKILL`)
  let mut exitCode : UInt32 := 0
  let mut done := false
  while !done do
    let w ← waitpidWnohang spawned.pid
    if w != 0xFFFFFFFF then
      exitCode := w
      done := true
    else
      let trapped ← pollTermTrap
      let failed ← fwdFailed.get
      if trapped != 0 || failed then
        let _ ← killSig (-spawned.pid) 15 -- SIGTERM process group
        let mut reaped := false
        for _ in [0:250] do
          if !reaped then
            let w2 ← waitpidWnohang spawned.pid
            if w2 != 0xFFFFFFFF then
              exitCode := w2
              reaped := true
            else
              IO.sleep 20
        if !reaped then
          let _ ← killSig (-spawned.pid) 9 -- SIGKILL process group
          while !reaped do
            let w3 ← waitpidWnohang spawned.pid
            if w3 != 0xFFFFFFFF then
              exitCode := w3
              reaped := true
            else
              IO.sleep 10
        done := true
      else
        IO.sleep 15
  if let some ov := agyOverlay? then
    restoreAntigravityOverlay ov
  cleanupRuntimeDir runtimeDir
  if (← fwdFailed.get) then
    IO.eprintln "Grok ACP input could not be forwarded safely"
    IO.Process.exit 1
  if grokAcp then
    -- Do not wait on the background stdin reader task if parent keeps pipe open!
    IO.Process.exit exitCode.toUInt8
  return .ok exitCode

/-! ### Top-Level CLI Dispatcher -/

private def findOptionValue? (headArgs : Array String) (flag : String) : Option String := Id.run do
  if headArgs.size < 2 then return none
  for i in [0:headArgs.size - 1] do
    if headArgs[i]! == flag then return some headArgs[i + 1]!
  return none

def runMain (args : List String) : IO UInt32 := do
  let arr := args.toArray
  if arr.size > 0 && arr[0]! == "launch" then
    match (← runLaunch (arr.extract 1 arr.size)) with
    | .ok code =>
      if code != 0 then IO.Process.exit code.toUInt8
      return 0
    | .error e =>
      IO.eprintln s!"sandboxed-mcp: {e}"
      return 1
  let mut sepIdx := arr.size
  for i in [0:arr.size] do
    if sepIdx == arr.size && arr[i]! == "--" then sepIdx := i
  let headArgs := arr.extract 0 sepIdx
  if headArgs.contains "--version" then
    IO.println s!"sandboxed-mcp {appVersion} contract {contractVersion}"
    return 0
  let secretCmd? ← match parseSecretSubcommand arr with
    | .ok sc => pure sc
    | .error e =>
      IO.eprintln s!"sandboxed-mcp: {e}"
      return 1
  let rawMissionOpt ← match findOptionValue? headArgs "--mission-id" with
    | some m => pure (some m)
    | none => firstEnvNonEmpty ["SANDBOXED_SH_MISSION_ID", "MISSION_ID"]
  let missionId? ← match rawMissionOpt with
    | none => pure none
    | some m =>
      match parseUuidCanonical? m with
      | some canon => pure (some canon)
      | none =>
        IO.eprintln "sandboxed-mcp: Invalid mission UUID"
        return 1
  let roleRaw ← match findOptionValue? headArgs "--profile" with
    | some p => pure p
    | none =>
      match (← getEnvNonEmpty "SANDBOXED_MCP_PROFILE") with
      | some ep => pure ep
      | none => pure (if missionId?.isSome then "executor" else "coordinator")
  if !(roleRaw == "executor" || roleRaw == "coordinator" || roleRaw == "operator") then
    IO.eprintln "sandboxed-mcp: Invalid MCP profile"
    return 1
  if headArgs.contains "--print-catalog" then
    match OrbBin.McpCatalog.catalogPrettyJsonForRole roleRaw with
    | some jsonTxt =>
      IO.println jsonTxt
      return 0
    | none =>
      IO.eprintln "sandboxed-mcp: Invalid MCP profile"
      return 1
  let apiUrlOpt ← match findOptionValue? headArgs "--api-url" with
    | some u => pure (some u)
    | none => firstEnvNonEmpty ["SANDBOXED_MCP_API_URL", "HERMES_SANDBOXED_API_URL", "SANDBOXED_API_URL", "API_URL"]
  let some apiUrl := apiUrlOpt | do
    IO.eprintln "sandboxed-mcp: Missing Core API URL"
    return 1
  let tokenFileStr? ← match findOptionValue? headArgs "--token-file" with
    | some tf => pure (some tf)
    | none => getEnvNonEmpty "SANDBOXED_MCP_TOKEN_FILE"
  let inlineTok := (← firstEnvNonEmpty ["SANDBOXED_MCP_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "SANDBOXED_API_TOKEN", "API_TOKEN"]).getD ""
  let project? := findOptionValue? headArgs "--project"
  let clientLabel? ← match findOptionValue? headArgs "--client-label" with
    | some l => pure (some l)
    | none => getEnvNonEmpty "SANDBOXED_MCP_CLIENT_LABEL"
  let hostHint? ← match findOptionValue? headArgs "--host-hint" with
    | some h => pure (some h)
    | none => getEnvNonEmpty "SANDBOXED_MCP_HOST_HINT"
  let preflightCache? := (findOptionValue? headArgs "--preflight-cache").map System.FilePath.mk
  let client ← match (← McpClient.create apiUrl inlineTok (tokenFileStr?.map System.FilePath.mk) roleRaw missionId? project? clientLabel? hostHint? none preflightCache?) with
    | .ok c => pure c
    | .error e =>
      IO.eprintln s!"sandboxed-mcp: {e}"
      return 1
  if let some sc := secretCmd? then
    match (← runSecretCli client sc) with
    | .ok code =>
      if code != 0 then IO.Process.exit code.toUInt8
      return 0
    | .error e =>
      IO.eprintln s!"sandboxed-mcp: {e}"
      return 1
  if headArgs.contains "--check" then
    match (← client.preflight) with
    | .error e =>
      IO.eprintln s!"sandboxed-mcp: {e}"
      return 1
    | .ok v =>
      let toolCountVal :=
        match v.fieldArr? "tools" with
        | some xs => JVal.nat xs.size
        | none => JVal.null
      let summary := JVal.obj #[
        ("contract_version", v.fieldOrNull "contract_version"),
        ("identity", v.fieldOrNull "identity"),
        ("tools", toolCountVal)
      ]
      IO.println (renderCompact summary)
      return 0
  loadConfiguredStdioMcps client.stdioRegistry
  -- Background 60s credential renewal loop while stdio server is active
  let stopRenew ← IO.mkRef false
  let _ ← IO.asTask do
    while !(← stopRenew.get) do
      for _ in [0:60] do
        if !(← stopRenew.get) then IO.sleep 1000
      if !(← stopRenew.get) then
        if let .error _ ← client.getToken then
          IO.eprintln "sandboxed-mcp: session renewal unavailable; retrying"
  try
    serveStdio (fun req cancelRef => client.handleRpc req cancelRef)
  finally
    stopRenew.set true
    client.shutdown
  return 0

end OrbBin.SandboxedMcp
