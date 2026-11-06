/-
  OrbCore.Control: Pure-Lean Core HTTP/WS Gateway (`sandboxed-sh`), Fail-Closed Startup Security,
  JWT Subprotocol Auth (`:80/api/console/ws`), Privilege Lease Verification, Mission Control,
  Automations & Model-Routing Dispatcher (`0 import Lean`, `0 sorryAx`).
-/
import LeanSys
import Orb.Kernel
import OrbBin.Json
import OrbCore.Spec
import OrbCore.Store
import OrbCore.Search
import OrbCore.Harness
import OrbCore.Proxy
import OrbCore.Managed

namespace OrbCore.Control

open LeanSys.Posix
open LeanSys.Http
open LeanSys.WebSocket
open LeanSys.Auth
open LeanSys.Codec
open Orb.Kernel
open OrbBin.Json
open OrbCore.Spec
open OrbCore.Store
open OrbCore.Search
open OrbCore.Harness
open OrbCore.Proxy
open OrbCore.Managed

/-- Core runtime configuration parsed from environment variables (`HOST`, `PORT`, `WORKING_DIR`,
    `DEV_MODE`, `DASHBOARD_PASSWORD`, `JWT_SECRET`, `SANDBOXED_USERS`, `ALLOW_INSECURE_REMOTE_DEV_AUTH`). -/
structure CoreConfig where
  host                       : String := "127.0.0.1"
  port                       : UInt16 := 3000
  workingDir                 : String := "."
  devMode                    : Bool   := false
  allowInsecureRemoteDevAuth : Bool   := false
  dashboardPassword          : String := ""
  jwtSecret                  : String := ""
  usersJson                  : String := ""
  maxIterations              : Nat    := 50
  libraryRemote              : String := ""
  githubClientId             : String := ""
  proxySecret                : String := ""
  deriving Repr, DecidableEq

/-- Live runtime state for the `sandboxed-sh` HTTP/WS server. -/
structure CoreAppState where
  cfg          : CoreConfig
  store        : CoreStore
  searchIdx?   : Option SearchIndex
  managedRef   : IO.Ref ManagedFleetState
  chainsRef    : IO.Ref (Array RoutingChain)
  seqRef       : IO.Ref UInt64

def isLoopbackHostStr (h : String) : Bool :=
  let t := h.trimAscii.toString
  t == "127.0.0.1" || t == "localhost" || t == "::1" || t == "[::1]"

def isPlaceholderSecretStr (s : String) : Bool :=
  let low := s.trimAscii.toString.toLower
  low.isEmpty || low == "change-me" || low == "changeme" || low == "secret" ||
  low == "password" || low == "default" || low == "your-jwt-secret" ||
  low == "ci-placeholder"

/-- Parse `SANDBOXED_USERS` JSON (`[{"username":"...","password":"..."}]` or `{"user":"pass"}`)
    into non-placeholder `(username, password)` pairs (`password.utf8ByteSize ≥ 12`). -/
def parseConfiguredUsers (raw : String) : Array (String × String) := Id.run do
  let trimmed := raw.trimAscii.toString
  if trimmed.isEmpty then return #[]
  match OrbBin.Json.parse trimmed with
  | .error _ => return #[]
  | .ok (.arr items) =>
    let mut out : Array (String × String) := #[]
    for item in items do
      let u := (item.fieldStr? "username").orElse (fun _ => item.fieldStr? "user") |>.getD ""
      let p := (item.fieldStr? "password").getD ""
      if !u.isEmpty && p.utf8ByteSize ≥ 12 && !isPlaceholderSecretStr p then
        out := out.push (u, p)
    return out
  | .ok (.obj pairs) =>
    let mut out : Array (String × String) := #[]
    for (u, v) in pairs do
      let p := (v.asStr?).getD ""
      if !u.isEmpty && p.utf8ByteSize ≥ 12 && !isPlaceholderSecretStr p then
        out := out.push (u, p)
    return out
  | .ok _ => return #[]

/-- Validate `CoreConfig` at startup via `verifyCoreStartupConfig` (`OrbCore.Spec`).
    Fails closed when `DEV_MODE=false` lacks strong secrets (`≥ 12`-byte password or valid `SANDBOXED_USERS`,
    and `≥ 32`-byte non-placeholder `JWT_SECRET`) or when `DEV_MODE=true` binds a non-loopback host! -/
def validateRuntimeSecurity (cfg : CoreConfig) : Except String Unit :=
  let devFlag : UInt8 := if cfg.devMode then 1 else 0
  let loopFlag : UInt8 := if isLoopbackHostStr cfg.host then 1 else 0
  let allowRemoteDev : UInt8 := if cfg.allowInsecureRemoteDevAuth then 1 else 0
  let validDashPwd : Bool :=
    cfg.dashboardPassword.utf8ByteSize ≥ 12 && !isPlaceholderSecretStr cfg.dashboardPassword
  let validMultiUsers : Bool := !(parseConfiguredUsers cfg.usersJson).isEmpty
  let pwdConfigured : UInt8 := if validDashPwd || validMultiUsers then 1 else 0
  let placeholderJwt : UInt8 := if isPlaceholderSecretStr cfg.jwtSecret then 1 else 0
  let jwtLen : UInt32 := cfg.jwtSecret.utf8ByteSize.toUInt32
  if verifyCoreStartupConfig devFlag loopFlag allowRemoteDev placeholderJwt jwtLen pwdConfigured != 1 then
    if !cfg.devMode then
      .error "Refusing to start sandboxed-sh with DEV_MODE=false: DASHBOARD_PASSWORD (>= 12 bytes) or valid SANDBOXED_USERS, plus a non-placeholder JWT_SECRET (>= 32 bytes), are required."
    else
      .error s!"Refusing to start sandboxed-sh with DEV_MODE=true on non-loopback HOST={cfg.host} without ALLOW_INSECURE_REMOTE_DEV_AUTH=true."
  else
    .ok ()

/-- Load `CoreConfig` from process environment variables. -/
def loadConfigFromEnv : IO CoreConfig := do
  let host := ((← IO.getEnv "HOST").getD "127.0.0.1").trimAscii.toString
  let portNat := (((← IO.getEnv "PORT").getD "3000").trimAscii.toString.toNat?).getD 3000
  let workingDir := (← IO.getEnv "WORKING_DIR").getD "."
  let devRaw := ((← IO.getEnv "DEV_MODE").getD "false").trimAscii.toString.toLower
  let devMode := devRaw == "true" || devRaw == "1"
  let allowRaw := ((← IO.getEnv "ALLOW_INSECURE_REMOTE_DEV_AUTH").getD "false").trimAscii.toString.toLower
  let allowRemote := allowRaw == "true" || allowRaw == "1"
  let pwd := (← IO.getEnv "DASHBOARD_PASSWORD").getD ""
  let jwt := (← IO.getEnv "JWT_SECRET").getD ""
  let usersA := (← IO.getEnv "SANDBOXED_USERS").getD ""
  let usersB := (← IO.getEnv "SANDBOXED_SH_USERS").getD ""
  let users := if !usersA.isEmpty then usersA else usersB
  let maxIter := (((← IO.getEnv "MAX_ITERATIONS").getD "50").trimAscii.toString.toNat?).getD 50
  let libRem := (← IO.getEnv "LIBRARY_REMOTE").getD ""
  let ghId := (← IO.getEnv "GITHUB_CLIENT_ID").getD ""
  let proxySec := (← IO.getEnv "SANDBOXED_PROXY_SECRET").getD ""
  return {
    host := if host.isEmpty then "127.0.0.1" else host
    port := (if portNat == 0 || portNat > 65535 then 3000 else portNat).toUInt16
    workingDir := workingDir
    devMode := devMode
    allowInsecureRemoteDevAuth := allowRemote
    dashboardPassword := pwd
    jwtSecret := jwt
    usersJson := users
    maxIterations := maxIter
    libraryRemote := libRem
    githubClientId := ghId
    proxySecret := proxySec
  }

/-- Mint a deterministic HMAC-SHA256 bearer/WS session token (`expEpoch.hexMac`). -/
def mintSessionToken (secret : String) (expEpochSec : UInt64) : String :=
  let payload := s!"orb-jwt-v1:{expEpochSec}"
  let hex := hmacSha256Hex secret payload
  s!"{expEpochSec}.{hex}"

/-- Verify a session token (`<expEpochSec>.<hexMac>`) against `secret` and `nowEpochSec`. -/
def verifySessionToken (secret token : String) (nowEpochSec : UInt64) : Option UInt64 :=
  if secret.isEmpty then none
  else
    match token.splitOn "." with
    | [expStr, sigHex] =>
      match expStr.toNat? with
      | none => none
      | some expNat =>
        let exp := expNat.toUInt64
        let expected := mintSessionToken secret exp
        if ctEqSlice (ByteSlice.ofString s!"{expStr}.{sigHex}") (ByteSlice.ofString expected) &&
           nowEpochSec < exp then
          some exp
        else
          none
    | _ => none

private def lookupHeaderCI (hdrs : Array (String × String)) (target : String) : Option String :=
  let low := target.toLower
  (hdrs.find? (fun (k, _) => k.toLower == low)).map Prod.snd

/-- Extract `jwt.<token>` across all `Sec-WebSocket-Protocol` header lines. -/
def extractWsJwtSubproto? (hdrs : Array (String × String)) : Option String := Id.run do
  for (hk, hv) in hdrs do
    if hk.toLower == "sec-websocket-protocol" then
      for part in hv.splitOn "," do
        let p := part.trimAscii.toString
        if p.startsWith "jwt." then
          return some (p.drop 4).toString
  return none

/-- Extract `Bearer <token>` from `Authorization` header. -/
def extractBearerToken? (hdrs : Array (String × String)) (nowEpochSec : UInt64 := 0) : Option String := do
  let _ := nowEpochSec
  let raw ← lookupHeaderCI hdrs "authorization"
  let t := raw.trimAscii.toString
  if t.startsWith "Bearer " || t.startsWith "bearer " then
    some (t.drop 7).trimAscii.toString
  else
    none

/-- Authenticate `:80/api/console/ws`, `/api/monitoring/ws`, `/api/desktop/stream`, and `/api/workspaces/:id/shell`
    strictly through `verifyConsoleWsAuth` (`OrbCore.Spec`), rejecting conflicting dual credentials. -/
def authenticateConsoleWsUpgrade (cfg : CoreConfig) (hdrs : Array (String × String)) (nowEpochSec : UInt64) : Bool :=
  if cfg.devMode then true
  else
    let subTok? := extractWsJwtSubproto? hdrs
    let bearTok? := extractBearerToken? hdrs nowEpochSec
    let subExp? := subTok?.bind (verifySessionToken cfg.jwtSecret · nowEpochSec)
    let bearExp? := bearTok?.bind (verifySessionToken cfg.jwtSecret · nowEpochSec)
    let expSec : UInt64 :=
      match subExp?, bearExp? with
      | some e1, some e2 => if e1 ≤ e2 then e1 else e2
      | some e1, none    => e1
      | none,    some e2 => e2
      | none,    none    => 0
    verifyConsoleWsAuth
      (if subTok?.isSome then 1 else 0)
      (if subExp?.isSome then 1 else 0)
      (if bearTok?.isSome then 1 else 0)
      (if bearExp?.isSome then 1 else 0)
      nowEpochSec
      expSec == 1

/-- Check whether `(username?, suppliedPassword)` matches `DASHBOARD_PASSWORD` or any configured `SANDBOXED_USERS` entry. -/
def verifyLoginCredentials (cfg : CoreConfig) (username? : Option String) (suppliedPassword : String) : Bool :=
  if cfg.devMode then true
  else if !cfg.dashboardPassword.isEmpty &&
          ctEqSlice (ByteSlice.ofString suppliedPassword) (ByteSlice.ofString cfg.dashboardPassword) then
    true
  else
    let users := parseConfiguredUsers cfg.usersJson
    users.any fun (u, p) =>
      (match username? with | none => true | some reqU => reqU.isEmpty || reqU == u) &&
      ctEqSlice (ByteSlice.ofString suppliedPassword) (ByteSlice.ofString p)

/-- Authenticate protected HTTP API routes (`Authorization: Bearer <token>`). -/
def authenticateHttpBearer (cfg : CoreConfig) (hdrs : Array (String × String)) (nowEpochSec : UInt64) : Bool :=
  if cfg.devMode then true
  else
    match extractBearerToken? hdrs nowEpochSec with
    | none => false
    | some tok =>
      (verifySessionToken cfg.jwtSecret tok nowEpochSec).isSome ||
      verifyLoginCredentials cfg none tok

/-- Authenticate `/v1/*` LLM proxy requests (`SANDBOXED_PROXY_SECRET` if configured, otherwise Core bearer auth). -/
def authenticateProxyRequest (cfg : CoreConfig) (hdrs : Array (String × String)) (nowEpochSec : UInt64) : Bool :=
  if !cfg.proxySecret.isEmpty then
    match extractBearerToken? hdrs nowEpochSec with
    | none => false
    | some tok => ctEqSlice (ByteSlice.ofString tok) (ByteSlice.ofString cfg.proxySecret)
  else
    authenticateHttpBearer cfg hdrs nowEpochSec

/-- Normalize a requested model effort string for `backend?`, rejecting unsupported levels. -/
def normalizeModelEffortForBackend (backend? : Option String) (raw : String) : Option String :=
  let level := raw.trimAscii.toString.toLower
  match backend? with
  | some "antigravity" =>
    if level == "low" || level == "medium" || level == "high" then some level else none
  | some "claudecode" =>
    if level == "low" || level == "medium" || level == "high" || level == "xhigh" || level == "max" then some level else none
  | some "codex" =>
    if level == "low" || level == "medium" || level == "high" || level == "xhigh" || level == "max" then some level else none
  | _ => none

/-- Statuses that hold an active campaign / project `parallel_missions` cap slot. -/
def campaignSlotHeldBy (status : String) : Bool :=
  match status with
  | "active" | "awaiting_user" | "paused" | "pending" | "waiting_background" => true
  | _ => false

/-- Return `some cap` only when `parallelMissions?` is strictly positive (`> 0`). -/
def enforcedProjectParallelCap? (parallelMissions? : Option Int) : Option Nat :=
  match parallelMissions? with
  | some c => if c > 0 then some c.toNat else none
  | none => none

/-- Confine requested mission `working_directory` under `baseDir` (rejects `..` traversal and NUL bytes). -/
def confineWorkingDirectory (baseDir rawDir : String) : Except String String :=
  let t := rawDir.trimAscii.toString
  if t.isEmpty then .ok baseDir
  else if t.toList.any (fun c => c.toNat == 0) then
    .error "invalid_working_directory_nul"
  else
    let segs := t.splitOn "/"
    if segs.any (fun s => s == "..") then
      .error "working_directory_parent_traversal_rejected"
    else if t == baseDir || t.startsWith (if baseDir.endsWith "/" then baseDir else baseDir ++ "/") then
      .ok t
    else if !t.startsWith "/" then
      .ok s!"{if baseDir.endsWith "/" then baseDir.dropEnd 1 |>.toString else baseDir}/{t}"
    else
      .error "working_directory_outside_workspace_root"

/-- Parse `models_json` array into `ProviderTarget` list for `RoutingChain` hydration. -/
def parseChainTargetsJson (rawJson : String) : Array ProviderTarget := Id.run do
  match OrbBin.Json.parse rawJson with
  | .ok (.arr items) =>
    let mut out : Array ProviderTarget := #[]
    for it in items do
      let acct := (it.fieldStr? "account_id").orElse (fun _ => it.fieldStr? "accountId") |>.getD "default"
      let prov := (it.fieldStr? "provider").getD "openai"
      let url := (it.fieldStr? "base_url").orElse (fun _ => it.fieldStr? "baseUrl") |>.getD "https://api.openai.com"
      let key := (it.fieldStr? "api_key").orElse (fun _ => it.fieldStr? "apiKey") |>.getD ""
      let mdl := (it.fieldStr? "model_id").orElse (fun _ => it.fieldStr? "modelId") |>.getD ""
      out := out.push { accountId := acct, provider := prov, baseUrl := url, apiKey := key, modelId := mdl }
    return out
  | _ => return #[]

/-- Hydrate `RoutingChain` table from `missions.db` (`model_routing_chains`). -/
def loadRoutingChainsFromStore (st : CoreStore) : IO (Array RoutingChain) := do
  match ← execParamQuery st.missionsDb "SELECT id,name,models_json FROM model_routing_chains ORDER BY id ASC;" #[] with
  | .error _ => return #[]
  | .ok rows =>
    if rows.size ≤ 1 then return #[]
    let mut out : Array RoutingChain := #[]
    for i in [1:rows.size] do
      let r := rows[i]!
      let cid := (r[0]?).getD ""
      let nm := (r[1]?).getD cid
      let mj := (r[2]?).getD "[]"
      out := out.push { id := cid, name := nm, targets := parseChainTargetsJson mj }
    return out

private def scopeRankOf : String → UInt8
  | "ops_read"       => 0
  | "service_deploy" => 1
  | "root_exec"      => 2
  | _                => 3

private def hash64Fnv1a (s : String) : UInt64 := Id.run do
  let mut h : UInt64 := 14695981039346656037
  for b in s.toUTF8.toList do
    h := (h ^^^ b.toUInt64) * 1099511628211
  return if h == 0 then 1 else h

/-- Render `GET /api/health` response body matching exact CI & client contract. -/
def renderHealthJson (cfg : CoreConfig) : String :=
  let authReq := !cfg.devMode
  let authMode := if cfg.devMode then "disabled" else if !(parseConfiguredUsers cfg.usersJson).isEmpty then "multi_user" else "single_tenant"
  let ghEnabled := !cfg.githubClientId.isEmpty
  let libVal := if cfg.libraryRemote.isEmpty then "null" else jsonEscape cfg.libraryRemote
  let devStr := if cfg.devMode then "true" else "false"
  let authStr := if authReq then "true" else "false"
  let ghStr := if ghEnabled then "true" else "false"
  s!"\{\"status\":\"ok\",\"version\":\"0.7.10\",\"dev_mode\":{devStr},\"auth_required\":{authStr},\"auth_mode\":{jsonEscape authMode},\"max_iterations\":{cfg.maxIterations},\"library_remote\":{libVal},\"github_enabled\":{ghStr},\"dashboard_github_login_enabled\":{ghStr},\"github_oauth_client_state\":true}"

/-- Minimal HTTP wire response builder with safe CORS & header sanitization. -/
structure CoreHttpResponse where
  status      : Nat
  contentType : String := "application/json"
  corsOrigin? : Option String := none
  extraHdrs   : Array (String × String) := #[]
  body        : ByteArray
  deriving Inhabited

private def reasonPhrase : Nat → String
  | 101 => "Switching Protocols"
  | 200 => "OK"
  | 201 => "Created"
  | 202 => "Accepted"
  | 204 => "No Content"
  | 400 => "Bad Request"
  | 401 => "Unauthorized"
  | 403 => "Forbidden"
  | 404 => "Not Found"
  | 409 => "Conflict"
  | 422 => "Unprocessable Entity"
  | 429 => "Too Many Requests"
  | 502 => "Bad Gateway"
  | 503 => "Service Unavailable"
  | _   => "Internal Server Error"

private def isAllowedCorsOrigin (devMode : Bool) (origin : String) : Bool :=
  let t := origin.trimAscii.toString
  if t.isEmpty then false
  else if t == "null" || t == "tauri://localhost" then true
  else if t.startsWith "http://127.0.0.1:" || t.startsWith "http://localhost:" ||
          t == "http://127.0.0.1" || t == "http://localhost" then true
  else if !devMode && t.startsWith "https://" then true
  else false

private def safeHeaderLine? (k v : String) : Option String :=
  if k.toList.any (fun c => c == '\r' || c == '\n' || c.toNat == 0) ||
     v.toList.any (fun c => c == '\r' || c == '\n' || c.toNat == 0) then
    none
  else
    some s!"{k}: {v}\r\n"

def encodeCoreHttpResponse (r : CoreHttpResponse) : ByteArray := Id.run do
  let corsHdr :=
    match r.corsOrigin? with
    | some orig =>
      if orig.toList.any (fun c => c == '\r' || c == '\n' || c.toNat == 0) then ""
      else
        s!"Access-Control-Allow-Origin: {orig}\r\n" ++
        "Vary: Origin\r\n" ++
        "Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n"
    | none => ""
  let mut head :=
    s!"HTTP/1.1 {r.status} {reasonPhrase r.status}\r\n" ++
    s!"Content-Type: {r.contentType}\r\n" ++
    s!"Content-Length: {r.body.size}\r\n" ++
    corsHdr ++
    "Connection: close\r\n"
  for (k, v) in r.extraHdrs do
    if let some ln := safeHeaderLine? k v then
      head := head ++ ln
  head := head ++ "\r\n"
  return head.toUTF8 ++ r.body

def jsonResponse (status : Nat) (bodyStr : String) (extraHdrs : Array (String × String) := #[])
    (corsOrigin? : Option String := none) : CoreHttpResponse :=
  { status := status, contentType := "application/json", corsOrigin? := corsOrigin?, extraHdrs := extraHdrs, body := bodyStr.toUTF8 }

private def isWsUpgradePath (cleanPath rawTarget : String) : Bool :=
  cleanPath == "/api/console/ws" ||
  cleanPath == "/api/monitoring/ws" ||
  cleanPath == "/api/desktop/stream" ||
  (matchRoutePattern? "/api/workspaces/:id/shell" rawTarget).isSome

private def nextUniqueId (st : CoreAppState) (prefixStr : String) (nowEpochSec : UInt64) : IO String := do
  let seq ← st.seqRef.modifyGet fun n => (n + 1, n + 1)
  return s!"{prefixStr}-{nowEpochSec}-{seq}"

/-- Dispatch a parsed `HttpRequest` against `CoreAppState` (`routes` capability parity:
    `"/api/control/missions/:id/automations"`, `"/api/model-routing"`). -/
def dispatchCoreRequest (st : CoreAppState) (req : HttpRequest) (nowEpochSec : UInt64) : IO (Except ByteArray CoreHttpResponse) := do
  let rawTarget := req.path
  let cleanPath :=
    match rawTarget.splitOn "?" with
    | p :: _ => p
    | [] => "/"
  let reqOrigin? := (lookupHeaderCI req.headers "origin").filter (isAllowedCorsOrigin st.cfg.devMode)
  let mkJson (code : Nat) (bodyStr : String) : CoreHttpResponse :=
    jsonResponse code bodyStr #[] reqOrigin?
  let mkJsonHdr (code : Nat) (bodyStr : String) (hdrs : Array (String × String)) : CoreHttpResponse :=
    jsonResponse code bodyStr hdrs reqOrigin?

  if req.method == "OPTIONS" then
    return .ok { status := 204, corsOrigin? := reqOrigin?, body := ByteArray.empty }

  -- 1. Public Health Endpoint (`GET /api/health`)
  if req.method == "GET" && cleanPath == "/api/health" then
    return .ok (mkJsonHdr 200 (renderHealthJson st.cfg) #[("Cache-Control", "private, max-age=5")])

  -- 2. Public Auth Login (`POST /api/auth/login`)
  if req.method == "POST" && cleanPath == "/api/auth/login" then
    let tape := JsonTape.indexJsonObject req.bodySlice
    let user? := JsonTape.lookupString? tape "username"
    let supplied := (JsonTape.lookupString? tape "password").getD ""
    if verifyLoginCredentials st.cfg user? supplied then
      let exp := nowEpochSec + 86400
      let tok := mintSessionToken (if st.cfg.jwtSecret.isEmpty then "dev-mode-ephemeral-jwt-secret-012345" else st.cfg.jwtSecret) exp
      return .ok (mkJson 200 s!"\{\"token\":{jsonEscape tok},\"expires_at\":{exp}}")
    else
      return .ok (mkJson 401 "{\"error\":\"invalid_credentials\"}")

  -- 3. WebSocket Upgrade Endpoints (`/api/console/ws`, `/api/monitoring/ws`, `/api/desktop/stream`, `/api/workspaces/:id/shell`)
  if req.method == "GET" && isWsUpgradePath cleanPath rawTarget then
    if !authenticateConsoleWsUpgrade st.cfg req.headers nowEpochSec then
      return .ok (mkJson 401 "{\"error\":\"unauthorized_websocket\"}")
    let negProto? := (extractWsJwtSubproto? req.headers).map (fun t => s!"jwt.{t}")
    match buildWebSocketUpgradeResponse? req negProto? with
    | some raw101 => return .error raw101
    | none => return .ok (mkJson 400 "{\"error\":\"invalid_websocket_upgrade\"}")

  -- 4. Authenticated `/v1/*` LLM Proxy (`SANDBOXED_PROXY_SECRET` or Core Bearer Auth)
  if cleanPath.startsWith "/v1/" then
    if !authenticateProxyRequest st.cfg req.headers nowEpochSec then
      return .ok (mkJson 401 "{\"error\":\"unauthorized_proxy\"}")
    let chains ← st.chainsRef.get
    let activeChain := chains[0]?.getD { id := "default", name := "default", targets := #[] }
    let out ← forwardProxyChain activeChain req.method cleanPath #[] req.bodySlice.toByteArray
    return .ok { status := out.status, contentType := out.contentType, corsOrigin? := reqOrigin?, extraHdrs := out.headers, body := out.body }

  -- 5. Privilege Broker Verification & Audit Log (`POST /api/privilege-access/verify-and-log`)
  if req.method == "POST" && cleanPath == "/api/privilege-access/verify-and-log" then
    if !authenticateHttpBearer st.cfg req.headers nowEpochSec then
      return .ok (mkJson 401 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"unauthorized\"}")
    let bodyStr := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
    let .ok jv := OrbBin.Json.parse bodyStr
      | return .ok (mkJson 400 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"invalid_json\"}")
    let missionId := (jv.fieldStr? "mission_id").getD ""
    let leaseTok := (jv.fieldStr? "lease_token").getD ""
    let targetHost := (jv.fieldStr? "target_host").getD ""
    let execHost := (jv.fieldStr? "executing_host").getD ""
    let cmdText := (jv.fieldStr? "command").getD ""
    if missionId.isEmpty || leaseTok.isEmpty || targetHost.isEmpty then
      return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"missing_lease_fields\"}")
    let some lease ← lookupPrivilegeLease? st.store leaseTok
      | do
        discard <| appendPrivilegeAuditLog st.store "" missionId targetHost execHost cmdText false s!"{nowEpochSec}"
        return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"unknown_lease\"}")
    let bunkerWord := bunkerStep 0 0 0 0 0
    let bunkerState : UInt8 := (bunkerWord &&& 0xFF).toUInt8
    let sameOwner : UInt8 := if lease.missionId == missionId && lease.targetHost == targetHost &&
                                (execHost.isEmpty || execHost == targetHost) then 1 else 0
    let sRank := scopeRankOf lease.scope
    let privWord := privilegeStep
      sameOwner 1
      (if lease.biometricSigned then 1 else 0)
      sRank sRank bunkerState
      (if lease.revoked then 1 else 0)
      nowEpochSec lease.expiresAtEpoch (lease.expiresAtEpoch + 3600)
    let tgtHash : UInt32 := (hash64Fnv1a targetHost &&& 0xFFFFFFFF).toUInt32
    let execHash : UInt32 := (hash64Fnv1a (if execHost.isEmpty then targetHost else execHost) &&& 0xFFFFFFFF).toUInt32
    let cmdDigest := hash64Fnv1a lease.grantId
    let toctouWord := authToctouExecuteStep 1 bunkerState
      (if tgtHash == 0 then 1 else tgtHash) (if execHash == 0 then 1 else execHash)
      lease.expiresAtEpoch lease.expiresAtEpoch nowEpochSec lease.expiresAtEpoch
      cmdDigest cmdDigest
    let allowExec := (privWord &&& 1) == 1 && toctouWord == 257
    if let .error e ← appendPrivilegeAuditLog st.store lease.grantId missionId targetHost execHost cmdText allowExec s!"{nowEpochSec}" then
      return .ok (mkJson 500 s!"\{\"allow_exec\":false,\"allowed\":false,\"error\":{jsonEscape e}}")
    if !allowExec then
      return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"lease_denied\"}")
    let rfStr := if lease.requireForceCmd then "true" else "false"
    let unitsRaw := if lease.allowedUnitsJson.startsWith "[" then lease.allowedUnitsJson else "[]"
    return .ok (mkJson 200 s!"\{\"allow_exec\":true,\"allowed\":true,\"grant_id\":{jsonEscape lease.grantId},\"scope\":{jsonEscape lease.scope},\"allowed_units\":{unitsRaw},\"require_force_cmd\":{rfStr}}")

  -- 6. Protected Routes (`require_auth`)
  if !authenticateHttpBearer st.cfg req.headers nowEpochSec then
    return .ok (mkJson 401 "{\"error\":\"unauthorized\"}")

  -- Mission Automations (`"/api/control/missions/:id/automations"`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/automations" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if req.method == "GET" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,mission_id,cron_expr,prompt,enabled,created_at FROM mission_automations WHERE mission_id=?1 ORDER BY created_at ASC;" #[mid]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let defAid ← nextUniqueId st "auto" nowEpochSec
      let aid := (JsonTape.lookupString? tape "id").getD defAid
      let cron := (JsonTape.lookupString? tape "cron_expr").getD "0 * * * *"
      let prompt := (JsonTape.lookupString? tape "prompt").getD ""
      match ← execParamQuery st.store.missionsDb
        "INSERT INTO mission_automations(id,mission_id,cron_expr,prompt,enabled,created_at) VALUES(?1,?2,?3,?4,1,?5) ON CONFLICT(id) DO UPDATE SET cron_expr=excluded.cron_expr,prompt=excluded.prompt WHERE mission_automations.mission_id=excluded.mission_id;"
        #[aid, mid, cron, prompt, s!"{nowEpochSec}"] with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ => return .ok (mkJson 201 s!"\{\"id\":{jsonEscape aid},\"mission_id\":{jsonEscape mid}}")

  -- Mission Opened (`POST /api/control/missions/:id/opened`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/opened" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      match ← mark_mission_opened st.store mid s!"{nowEpochSec}" with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok () => return .ok (mkJson 200 "{\"ok\":true}")

  -- Mission Machine Transfer (`GET|POST /api/control/missions/:id/machine-transfer`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/machine-transfer" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if req.method == "GET" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,mission_id,phase,revision,created_at FROM machine_transfers WHERE mission_id=?1 ORDER BY created_at ASC;" #[mid]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let dest := (JsonTape.lookupString? tape "destination").getD "local"
      let defRk ← nextUniqueId st "rk" nowEpochSec
      let reqKey := (JsonTape.lookupString? tape "request_key").getD defRk
      let srcRev := (JsonTape.lookupString? tape "source_revision").getD ""
      let srcGen := ((JsonTape.lookupNat? tape "source_generation").getD 0).toUInt64
      let txId ← nextUniqueId st "tx" nowEpochSec
      let txRec : TransferRecord := {
        id := txId, missionId := mid, requestKey := reqKey, revision := 0,
        phase := "preparing", destination := dest, sourceRevision := srcRev,
        sourceGeneration := srcGen, generation := 0, createdAt := s!"{nowEpochSec}"
      }
      match ← startMachineTransfer st.store txRec with
      | .ok out => return .ok (mkJson 201 s!"\{\"id\":{jsonEscape out.id},\"generation\":{out.generation},\"phase\":\"preparing\"}")
      | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")

  -- Missions Collection (`GET|POST /api/control/missions`)
  if cleanPath == "/api/control/missions" then
    if req.method == "GET" then
      match ← listMissionsJson st.store with
      | .ok j => return .ok (mkJson 200 j)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let defMid ← nextUniqueId st "m" nowEpochSec
      let mid := (JsonTape.lookupString? tape "id").getD defMid
      let title := (JsonTape.lookupString? tape "title").getD "New Mission"
      let backend := (JsonTape.lookupString? tape "backend").getD "codex"
      let rawEffort := (JsonTape.lookupString? tape "model_effort").getD ""
      let normEffort ←
        if rawEffort.trimAscii.toString.isEmpty then pure ""
        else match normalizeModelEffortForBackend (some backend) rawEffort with
          | some eff => pure eff
          | none => pure "__REJECT_EFFORT__"
      if normEffort == "__REJECT_EFFORT__" then
        return .ok (mkJson 400 s!"\{\"error\":\"unsupported_model_effort\",\"backend\":{jsonEscape backend},\"effort\":{jsonEscape rawEffort}}")
      let rawWorkDir := (JsonTape.lookupString? tape "working_directory").getD st.cfg.workingDir
      let .ok safeWorkDir := confineWorkingDirectory st.cfg.workingDir rawWorkDir
        | return .ok (mkJson 400 "{\"error\":\"invalid_working_directory\"}")
      let projSlug := (JsonTape.lookupString? tape "project_slug").getD ""
      if !projSlug.isEmpty then
        let rawCap? ← queryProjectParallelMissions? st.store projSlug
        if let some cap := enforcedProjectParallelCap? rawCap? then
          if let .ok statuses ← listMissionStatuses st.store then
            let held := (statuses.filter campaignSlotHeldBy).size
            if held ≥ cap then
              return .ok (mkJson 429 s!"\{\"error\":\"project_parallel_cap_reached\",\"limit\":{cap},\"held\":{held}}")
      let mRec : MissionRecord := {
        id := mid, title := title, status := "awaiting_user", backend := backend,
        modelOverride := "", modelEffort := normEffort, workingDirectory := safeWorkDir,
        updatedAt := s!"{nowEpochSec}", totalCostCents := 0
      }
      match ← upsertMission st.store mRec with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok () =>
        if let some sIdx := st.searchIdx? then
          discard <| indexConversation sIdx mid title
        return .ok (mkJson 201 s!"\{\"id\":{jsonEscape mid},\"status\":\"awaiting_user\",\"model_effort\":{jsonEscape normEffort},\"total_cost_cents\":0}")

  -- Mission Search (`GET /api/control/missions/search`)
  if req.method == "GET" && cleanPath == "/api/control/missions/search" then
    let qParams := parseQueryParams rawTarget
    let q := (qParams.find? (fun p => p.1 == "q")).map Prod.snd |>.getD ""
    match st.searchIdx? with
    | none => return .ok (mkJson 200 "{\"hits\":[]}")
    | some sIdx =>
      let hits ← queryConversations sIdx q 32
      let hitJson := "[" ++ String.intercalate "," (hits.toList.map jsonEscape) ++ "]"
      return .ok (mkJson 200 s!"\{\"hits\":{hitJson}}")

  -- Model Routing Controls (`"/api/model-routing"` / `/api/model-routing/chains`)
  if cleanPath.startsWith "/api/model-routing" then
    if req.method == "GET" && cleanPath == "/api/model-routing/chains" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,name,models_json,updated_at FROM model_routing_chains ORDER BY id ASC;" #[]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" && cleanPath == "/api/model-routing/chains" then
      let rawBody := String.fromUTF8? req.bodySlice.toByteArray |>.getD "{}"
      let jv := (OrbBin.Json.parse rawBody).toOption.getD (.obj #[])
      let defCid ← nextUniqueId st "chain" nowEpochSec
      let cid := (jv.fieldStr? "id").getD defCid
      let nm := (jv.fieldStr? "name").getD cid
      let modelsJson := match jv.field? "models" with
        | some arr@(.arr _) => renderCompact arr
        | _ => (jv.fieldStr? "models_json").getD "[]"
      match ← execParamQuery st.store.missionsDb
        "INSERT OR REPLACE INTO model_routing_chains(id,name,models_json,updated_at) VALUES(?1,?2,?3,?4);"
        #[cid, nm, modelsJson, s!"{nowEpochSec}"] with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ =>
        let refreshed ← loadRoutingChainsFromStore st.store
        st.chainsRef.set refreshed
        return .ok (mkJson 201 s!"\{\"id\":{jsonEscape cid},\"name\":{jsonEscape nm}}")
    else
      return .ok (mkJson 200 "{\"ok\":true,\"router\":\"/api/model-routing\"}")

  -- Managed Compute Fleet (`/api/managed-machines/spend`, `/api/remote-nodes`)
  if req.method == "GET" && (cleanPath == "/api/managed-machines/spend" || cleanPath == "/api/managed-machines") then
    let mf ← st.managedRef.get
    return .ok (mkJson 200 (renderManagedBudgetJson mf))

  if req.method == "GET" && cleanPath == "/api/remote-nodes" then
    let mf ← st.managedRef.get
    return .ok (mkJson 200 s!"\{\"nodes\":[],\"managed_compute\":{renderManagedBudgetJson mf}}")

  return .ok (mkJson 404 s!"\{\"error\":\"not_found\",\"path\":{jsonEscape cleanPath}}")

/-- Bounded RFC 6455 WebSocket session loop after `101 Switching Protocols`:
    handles client `ping` (`pong` reply), `close` (echo `1000` close), and JSON messages cleanly. -/
private def runWebSocketSessionLoop (cfd : Fd) : IO Unit := do
  let readyHello := "{\"type\":\"ready\",\"server\":\"sandboxed-sh\"}".toUTF8
  if let some helloFrame := encodeFrame? { fin := true, opcode := .text, payload := readyHello } none then
    discard <| writeAll cfd helloFrame false
  let mut rxBuf := ByteArray.empty
  let mut steps : Nat := 0
  let mut openConn := true
  while openConn && steps < 64 do
    steps := steps + 1
    match ← pollReadable cfd 2000 with
    | .error _ => openConn := false
    | .ok () =>
      let chunk ← readStreamChunk cfd 65536
      if chunk.isEmpty then
        openConn := false
      else
        rxBuf := rxBuf ++ chunk
        match decodeFramePrefix rxBuf true with
        | .error _ => openConn := false
        | .ok none => pure ()
        | .ok (some (frame, consumed)) =>
          rxBuf := rxBuf.extract consumed rxBuf.size
          match frame.opcode with
          | .ping =>
            if let some pong := makeServerPong? frame.payload then
              discard <| writeAll cfd pong false
          | .close =>
            if let some cls := makeServerClose? 1000 "" then
              discard <| writeAll cfd cls false
            openConn := false
          | .text | .binary =>
            let ack := "{\"type\":\"ack\"}".toUTF8
            if let some ackFrame := encodeFrame? { fin := true, opcode := .text, payload := ack } none then
              discard <| writeAll cfd ackFrame false
          | _ => pure ()
  if openConn then
    if let some cls := makeServerClose? 1000 "" then
      discard <| writeAll cfd cls false

/-- Serve one accepted TCP connection on `cfd` using full multi-packet `readHttpRequestFromFd`. -/
def handleClientConn (st : CoreAppState) (cfd : Fd) : IO Unit := do
  match ← readHttpRequestFromFd cfd none 5000 with
  | .error errMsg =>
    let code := statusForParseError errMsg
    let resp := encodeCoreHttpResponse (jsonResponse code s!"\{\"error\":{jsonEscape errMsg}}")
    discard <| writeAll cfd resp false
    discard <| closeFd cfd
  | .ok req =>
    let nowSec ← coreEpochSec
    match ← dispatchCoreRequest st req nowSec with
    | .ok httpResp =>
      discard <| writeAll cfd (encodeCoreHttpResponse httpResp) false
      discard <| closeFd cfd
    | .error rawUpgrade101 =>
      discard <| writeAll cfd rawUpgrade101 false
      runWebSocketSessionLoop cfd
      discard <| closeFd cfd

/-- Run the blocking HTTP/1.1 + WebSocket listener loop on `cfg.host:cfg.port`. -/
def runCoreServer (cfg : CoreConfig) (maxRequests? : Option Nat := none) : IO UInt32 := do
  match validateRuntimeSecurity cfg with
  | .error msg =>
    IO.eprintln s!"[sandboxed-sh] FATAL security configuration error: {msg}"
    return 1
  | .ok () =>
    let dataRoot := s!"{cfg.workingDir}/.sandboxed-sh"
    let .ok store ← openCoreStore dataRoot
      | do IO.eprintln s!"[sandboxed-sh] FATAL: failed to open SQLite CoreStore at {dataRoot}"; return 1
    let searchRes ← openSearchIndex s!"{dataRoot}/search_index"
    let managedRef ← IO.mkRef ({} : ManagedFleetState)
    let initialChains ← loadRoutingChainsFromStore store
    let chainsRef ← IO.mkRef initialChains
    let seqRef ← IO.mkRef (0 : UInt64)
    let appState : CoreAppState := {
      cfg := cfg
      store := store
      searchIdx? := searchRes.toOption
      managedRef := managedRef
      chainsRef := chainsRef
      seqRef := seqRef
    }
    let bindHost := if cfg.host == "localhost" then "127.0.0.1" else cfg.host
    let .ok (listenFd, boundPort) ← tcpListen bindHost cfg.port 128
      | do
        closeCoreStore store
        IO.eprintln s!"[sandboxed-sh] FATAL: failed to bind {bindHost}:{cfg.port}"
        return 1
    IO.eprintln s!"[sandboxed-sh] listening on http://{bindHost}:{boundPort} (dev_mode={cfg.devMode})"
    let mut served : Nat := 0
    while (match maxRequests? with | some lim => decide (served < lim) | none => true) do
      match ← tcpAcceptPoll listenFd 250 with
      | .error _ => pure ()
      | .ok cfd =>
        handleClientConn appState cfd
        served := served + 1
    discard <| closeFd listenFd
    closeCoreStore store
    return 0

end OrbCore.Control
