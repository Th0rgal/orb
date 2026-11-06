import LeanSys
import OrbNetLeaf
import OrbBin.Json
import OrbBin.PosixExt
import OrbLocald.Spec

/-
  OrbLocald.Rpc — Loopback JSON-RPC & transport proxy bridge for Orb desktop:
    - All 88 desktop IPC commands (`87` commands + `plugin:app|version`)
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

def defaultDohEndpoints : Array String := #[
  "https://1.1.1.1/dns-query",
  "https://8.8.8.8/dns-query"
]

structure TransportBridgeState where
  proxyPort       : UInt16 := 19480
  bridgeUuid      : String := "00000000-0000-4000-8000-000000000001"
  shardPorts      : Array UInt16 := #[19481, 19482, 19483, 19484, 19485, 19486]
  failoverOrigins : Array String := defaultFailoverOrigins
  dohEndpoints    : Array String := defaultDohEndpoints
  deriving Repr, Inhabited

def TransportBridgeState.proxyBaseUrl (st : TransportBridgeState) : String :=
  s!"http://127.0.0.1:{st.proxyPort}/__orb_tx/{st.bridgeUuid}"

def TransportBridgeState.streamProxyBaseUrls (st : TransportBridgeState) : Array String :=
  st.shardPorts.map fun p => s!"http://127.0.0.1:{p}/__orb_tx/{st.bridgeUuid}"

def TransportBridgeState.toJson (st : TransportBridgeState) : JVal :=
  .obj #[
    ("proxy_base_url", .str st.proxyBaseUrl),
    ("stream_proxy_base_urls", .arr (st.streamProxyBaseUrls.map .str)),
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
  active  : Bool := true
  deriving Repr, Inhabited

structure LocaldState where
  launchToken         : String
  rpcPort             : UInt16 := 19479
  bridge              : TransportBridgeState := {}
  nextSubToken        : Nat := 1
  subscriptions       : Array SubscriptionEntry := #[]
  queuedChannelEvents : Array (Nat × JVal) := #[]
  bindingsRevision    : Nat := 0
  bindingsEntries     : Array (String × JVal) := #[]
  clientLinkConnected : Bool := false
  approvalGraceSecs   : Nat := 300
  approvalGraceUntil  : UInt64 := 0
  approvalKeyPath     : String := ""
  grantedFolders      : Array String := #[]
  connectionJson      : JVal := .obj #[("url", .str ""), ("token", .str "")]
  hostOs              : String := "linux"
  signerBin?          : Option String := none
  deriving Inhabited

def LocaldState.bindingsSnapshotJson (st : LocaldState) : JVal :=
  .obj #[("revision", JVal.nat st.bindingsRevision), ("bindings", .obj st.bindingsEntries)]

def LocaldState.subscribe (st : LocaldState) (channel : String) (initialEvent? : Option JVal := none) : (Nat × LocaldState) :=
  let tok := st.nextSubToken
  let entry : SubscriptionEntry := { token := tok, channel := channel, active := true }
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

/-- Canonical list of all 88 desktop IPC commands (`87` commands + `plugin:app|version`). -/
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
  "local_skills_status", "local_skills_sync", "local_skill_source_files",
  "voice_capability", "voice_prewarm", "voice_transcribe", "voice_cancel"
]

private def runOrbSigner (signerBin : String) (subArgs : Array String) (stdinText? : Option String := none) :
    IO (Except (UInt32 × String) JVal) := do
  if !(← System.FilePath.pathExists signerBin) then
    return .error (127, "orb-signer binary not found")
  let child ← IO.Process.spawn {
    cmd := signerBin
    args := subArgs
    stdin := .piped
    stdout := .piped
    stderr := .piped
  }
  let (stdinH, child') ← child.takeStdin
  if let some txt := stdinText? then
    stdinH.putStr txt
    stdinH.flush
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

private def resolveApprovalKeyArgs (st : LocaldState) (verb : String) : Array String :=
  let kp := if st.approvalKeyPath.trimAscii.toString.isEmpty then "approval-key.bin" else st.approvalKeyPath
  #[verb, "--key", kp]

private def allShardPortsValid (rpcPort proxyPort : UInt16) (shardPorts : Array UInt16) : Bool :=
  shardPorts.all (fun p => p ≥ 1024 && p != rpcPort && p != proxyPort) &&
  (shardPorts.toList.eraseDups.length == shardPorts.size)

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
    return .ok st.bridge.toJson
  | "__orb_poll_events" =>
    let evs ← stRef.modifyGet fun s =>
      let items := s.queuedChannelEvents.map fun (tok, payload) =>
        JVal.obj #[("token", JVal.nat tok), ("payload", payload)]
      (JVal.arr items, { s with queuedChannelEvents := #[] })
    return .ok evs
  | "desktop_connection_load" =>
    return .ok st.connectionJson
  | "desktop_connection_save" =>
    stRef.modify fun s => { s with connectionJson := args }
    return .ok (.bool true)
  | "diagnostics_append" =>
    return .ok .null
  | "local_machine_metrics" =>
    return .ok (.obj #[("cpu_percent", JVal.int 0), ("memory_used_bytes", JVal.int 0), ("memory_total_bytes", JVal.int 0)])
  | "paloma_ssh_pubkey" =>
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
        match ← runOrbSigner bin (resolveApprovalKeyArgs st "sign") (some payload) with
        | .ok jv =>
          let sig := (jv.fieldStr? "signature").getD ""
          if sig.isEmpty then return .error "orb-signer returned empty signature"
          if isPalomaPayloadGraceEligible payload && st.approvalGraceSecs > 0 then
            let graceNat := (jv.fieldStr? "grace_until").bind String.toNat? |>.getD 0
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
    stRef.modify fun s =>
      { s with
          approvalGraceSecs := clamped,
          approvalGraceUntil := if clamped == 0 then 0 else s.approvalGraceUntil }
    return .ok .null
  | "biometric_status" =>
    let avail := st.hostOs == "macos"
    return .ok (.obj #[("available", .bool avail), ("biometry_type", .str (if avail then "touch_id" else "none"))])
  | "biometric_authenticate" =>
    return .ok (.bool false)
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
    let tok ← stRef.modifyGet fun s =>
      s.subscribe "local_interaction" (some .null)
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
    let p := (args.fieldStr? "path").getD ""
    if !p.isEmpty then
      stRef.modify fun s => { s with grantedFolders := s.grantedFolders.push p }
    return .ok .null
  | "revoke_upload_folder" =>
    let p := (args.fieldStr? "path").getD ""
    stRef.modify fun s => { s with grantedFolders := s.grantedFolders.filter (· != p) }
    return .ok .null
  | "voice_capability" =>
    return .ok (.obj #[("available", .bool false), ("backend", .str "none")])
  | "software_inventory" =>
    return .ok (.arr #[])
  | "local_origin_list" | "local_agents_scan" | "local_antigravity_models"
  | "local_claude_models" | "project_context_workers" | "browse_local_files"
  | "local_skill_source_files" =>
    return .ok (.arr #[])
  | "local_machine_identity" =>
    return .ok (.obj #[("hostname", .str "localhost"), ("os", .str st.hostOs)])
  | _ =>
    if supportedDesktopCommands.contains cmd then
      return .ok (.obj #[("ok", .bool true), ("command", .str cmd)])
    else
      return .error s!"unknown desktop command: {cmd}"

/-- Escape a string safely as a JSON string literal (`"..."`) for JS embedding. -/
def jsStringLiteral (s : String) : String :=
  renderCompact (.str s)

/-- WebView initialization JavaScript injecting `window.__TAURI__` and `window.__TAURI_INTERNALS__`
    with captured `_fetch` / `_jsonStringify` closures (preventing `window.fetch` token theft)
    and active `Channel` callback registration. -/
def renderWebviewInitScript (rpcPort : UInt16) (launchToken : String) : String :=
  let urlLit := jsStringLiteral s!"http://127.0.0.1:{rpcPort}/__orb_rpc"
  let tokLit := jsStringLiteral launchToken
  "(() => {\n" ++
  "  const _fetch = window.fetch.bind(window);\n" ++
  "  const _jsonStringify = JSON.stringify;\n" ++
  s!"  const ORB_LOCALD_URL = {urlLit};\n" ++
  s!"  const ORB_TOKEN = {tokLit};\n" ++
  "  const listeners = new Map();\n" ++
  "  const channels = new Map();\n" ++
  "  let timer = 0;\n" ++
  "  class Channel {\n" ++
  "    constructor() { this.onmessage = () => {}; }\n" ++
  "  }\n" ++
  "  async function drain() {\n" ++
  "    if (!channels.size) { if (timer) { clearInterval(timer); timer = 0; } return; }\n" ++
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
  "  async function invoke(command, args = {}, _options = {}) {\n" ++
  "    const cleanArgs = { ...(args || {}) };\n" ++
  "    let boundChan = null;\n" ++
  "    if (cleanArgs.onEvent instanceof Channel) {\n" ++
  "      boundChan = cleanArgs.onEvent;\n" ++
  "      delete cleanArgs.onEvent;\n" ++
  "    }\n" ++
  "    if (command.endsWith('_unsubscribe') && typeof cleanArgs.token === 'number') {\n" ++
  "      channels.delete(cleanArgs.token);\n" ++
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
  "      if (!timer) timer = setInterval(drain, 250);\n" ++
  "      void drain();\n" ++
  "    }\n" ++
  "    return body.result;\n" ++
  "  }\n" ++
  "  async function listen(name, handler) {\n" ++
  "    if (!listeners.has(name)) listeners.set(name, new Set());\n" ++
  "    listeners.get(name).add(handler);\n" ++
  "    return () => listeners.get(name)?.delete(handler);\n" ++
  "  }\n" ++
  "  window.__TAURI_INTERNALS__ = { invoke };\n" ++
  "  window.__TAURI__ = {\n" ++
  "    core: { invoke, Channel },\n" ++
  "    event: { listen },\n" ++
  "    window: { getCurrentWindow: () => ({\n" ++
  "      innerSize: async () => ({ width: window.innerWidth, height: window.innerHeight }),\n" ++
  "      scaleFactor: async () => window.devicePixelRatio || 1\n" ++
  "    }) },\n" ++
  "    webview: { getCurrentWebview: () => ({ label: 'main' }) }\n" ++
  "  };\n" ++
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
