/-
  OrbCore.Control: Pure-Lean Core HTTP/WS Gateway (`sandboxed-sh`), Fail-Closed Startup Security,
  JWT Subprotocol Auth (`:80/api/console/ws`), Mission Control, Automations & Model-Routing Dispatcher (`0 import Lean`, `0 sorryAx`).
-/
import LeanSys
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

def isLoopbackHostStr (h : String) : Bool :=
  let t := h.trimAscii.toString
  t == "127.0.0.1" || t == "localhost" || t == "::1" || t == "[::1]"

def isPlaceholderSecretStr (s : String) : Bool :=
  let low := s.trimAscii.toString.toLower
  low.isEmpty || low == "change-me" || low == "changeme" || low == "secret" ||
  low == "password" || low == "default" || low == "your-jwt-secret" ||
  low == "ci-placeholder"

/-- Validate `CoreConfig` at startup via `verifyCoreStartupConfig` (`OrbCore.Spec`).
    Fails closed when `DEV_MODE=false` lacks strong secrets or when `DEV_MODE=true` binds a non-loopback host! -/
def validateRuntimeSecurity (cfg : CoreConfig) : Except String Unit :=
  let devFlag : UInt8 := if cfg.devMode then 1 else 0
  let loopFlag : UInt8 := if isLoopbackHostStr cfg.host then 1 else 0
  let allowRemoteDev : UInt8 := if cfg.allowInsecureRemoteDevAuth then 1 else 0
  let pwdConfigured : UInt8 :=
    if (!cfg.dashboardPassword.isEmpty && !isPlaceholderSecretStr cfg.dashboardPassword) ||
       !cfg.usersJson.trimAscii.toString.isEmpty then 1 else 0
  let placeholderJwt : UInt8 := if isPlaceholderSecretStr cfg.jwtSecret then 1 else 0
  let jwtLen : UInt32 := cfg.jwtSecret.utf8ByteSize.toUInt32
  if verifyCoreStartupConfig devFlag loopFlag allowRemoteDev placeholderJwt jwtLen pwdConfigured != 1 then
    if !cfg.devMode then
      .error "Refusing to start sandboxed-sh with DEV_MODE=false: DASHBOARD_PASSWORD (or SANDBOXED_USERS) and a non-placeholder JWT_SECRET (>= 32 bytes) are required."
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

/-- Extract `jwt.<token>` from `Sec-WebSocket-Protocol` header list. -/
def extractWsJwtSubproto? (hdrs : Array (String × String)) : Option String := do
  let raw ← lookupHeaderCI hdrs "sec-websocket-protocol"
  for part in raw.splitOn "," do
    let p := part.trimAscii.toString
    if p.startsWith "jwt." then
      return (p.drop 4).toString
  none

/-- Extract `Bearer <token>` from `Authorization` header. -/
def extractBearerToken? (hdrs : Array (String × String)) : Option String := do
  let raw ← lookupHeaderCI hdrs "authorization"
  let t := raw.trimAscii.toString
  if t.startsWith "Bearer " || t.startsWith "bearer " then
    some (t.drop 7).trimAscii.toString
  else
    none

/-- Authenticate `:80/api/console/ws` (and `/api/monitoring/ws`, `/api/desktop/stream`, `/api/workspaces/:id/shell`)
    strictly through `verifyConsoleWsAuth` (`OrbCore.Spec`). -/
def authenticateConsoleWsUpgrade (cfg : CoreConfig) (hdrs : Array (String × String)) (nowEpochSec : UInt64) : Bool :=
  if cfg.devMode then true
  else
    let subTok? := extractWsJwtSubproto? hdrs
    let bearTok? := extractBearerToken? hdrs
    let subExp? := subTok?.bind (verifySessionToken cfg.jwtSecret · nowEpochSec)
    let bearExp? := bearTok?.bind (verifySessionToken cfg.jwtSecret · nowEpochSec)
    let expSec := (subExp?.orElse (fun _ => bearExp?)).getD 0
    verifyConsoleWsAuth
      (if subTok?.isSome then 1 else 0)
      (if subExp?.isSome then 1 else 0)
      (if bearTok?.isSome then 1 else 0)
      (if bearExp?.isSome then 1 else 0)
      nowEpochSec
      expSec == 1

/-- Authenticate protected HTTP API routes (`Authorization: Bearer <token>`). -/
def authenticateHttpBearer (cfg : CoreConfig) (hdrs : Array (String × String)) (nowEpochSec : UInt64) : Bool :=
  if cfg.devMode then true
  else
    match extractBearerToken? hdrs with
    | none => false
    | some tok =>
      (verifySessionToken cfg.jwtSecret tok nowEpochSec).isSome ||
      (!cfg.dashboardPassword.isEmpty && ctEqSlice (ByteSlice.ofString tok) (ByteSlice.ofString cfg.dashboardPassword))

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

/-- Render `GET /api/health` response body matching exact CI & client contract. -/
def renderHealthJson (cfg : CoreConfig) : String :=
  let authReq := !cfg.devMode
  let authMode := if cfg.devMode then "disabled" else if !cfg.usersJson.isEmpty then "multi_user" else "single_tenant"
  let ghEnabled := !cfg.githubClientId.isEmpty
  let libVal := if cfg.libraryRemote.isEmpty then "null" else jsonEscape cfg.libraryRemote
  let devStr := if cfg.devMode then "true" else "false"
  let authStr := if authReq then "true" else "false"
  let ghStr := if ghEnabled then "true" else "false"
  s!"\{\"status\":\"ok\",\"version\":\"0.7.10\",\"dev_mode\":{devStr},\"auth_required\":{authStr},\"auth_mode\":{jsonEscape authMode},\"max_iterations\":{cfg.maxIterations},\"library_remote\":{libVal},\"github_enabled\":{ghStr},\"dashboard_github_login_enabled\":{ghStr},\"github_oauth_client_state\":true}"

/-- Minimal HTTP wire response builder with custom headers (`Cache-Control`, `CORS`, etc.). -/
structure CoreHttpResponse where
  status      : Nat
  contentType : String := "application/json"
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

def encodeCoreHttpResponse (r : CoreHttpResponse) : ByteArray := Id.run do
  let mut head :=
    s!"HTTP/1.1 {r.status} {reasonPhrase r.status}\r\n" ++
    s!"Content-Type: {r.contentType}\r\n" ++
    s!"Content-Length: {r.body.size}\r\n" ++
    "Access-Control-Allow-Origin: *\r\n" ++
    "Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key\r\n" ++
    "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
    "Connection: close\r\n"
  for (k, v) in r.extraHdrs do
    head := head ++ s!"{k}: {v}\r\n"
  head := head ++ "\r\n"
  return head.toUTF8 ++ r.body

def jsonResponse (status : Nat) (bodyStr : String) (extraHdrs : Array (String × String) := #[]) : CoreHttpResponse :=
  { status := status, contentType := "application/json", extraHdrs := extraHdrs, body := bodyStr.toUTF8 }

/-- Dispatch a parsed `HttpRequest` against `CoreAppState` (`routes` capability parity:
    `"/api/control/missions/:id/automations"`, `"/api/model-routing"`). -/
def dispatchCoreRequest (st : CoreAppState) (req : HttpRequest) (nowEpochSec : UInt64) : IO (Except ByteArray CoreHttpResponse) := do
  let rawTarget := req.path
  let cleanPath :=
    match rawTarget.splitOn "?" with
    | p :: _ => p
    | [] => "/"
  if req.method == "OPTIONS" then
    return .ok { status := 204, body := ByteArray.empty }

  -- 1. Public Health Endpoint (`GET /api/health`)
  if req.method == "GET" && cleanPath == "/api/health" then
    return .ok (jsonResponse 200 (renderHealthJson st.cfg) #[("Cache-Control", "private, max-age=5")])

  -- 2. Public Auth Login (`POST /api/auth/login`)
  if req.method == "POST" && cleanPath == "/api/auth/login" then
    let tape := JsonTape.indexJsonObject req.bodySlice
    let supplied := (JsonTape.lookupString? tape "password").getD ""
    if st.cfg.devMode || (!st.cfg.dashboardPassword.isEmpty &&
       ctEqSlice (ByteSlice.ofString supplied) (ByteSlice.ofString st.cfg.dashboardPassword)) then
      let exp := nowEpochSec + 86400
      let tok := mintSessionToken (if st.cfg.jwtSecret.isEmpty then "dev-mode-ephemeral-jwt-secret-012345" else st.cfg.jwtSecret) exp
      return .ok (jsonResponse 200 s!"\{\"token\":{jsonEscape tok},\"expires_at\":{exp}}")
    else
      return .ok (jsonResponse 401 "{\"error\":\"invalid_credentials\"}")

  -- 3. Public WebSocket Upgrade Endpoints (`/api/console/ws`, `/api/monitoring/ws`, `/api/desktop/stream`)
  if req.method == "GET" &&
     (cleanPath == "/api/console/ws" || cleanPath == "/api/monitoring/ws" || cleanPath == "/api/desktop/stream") then
    if !authenticateConsoleWsUpgrade st.cfg req.headers nowEpochSec then
      return .ok (jsonResponse 401 "{\"error\":\"unauthorized_websocket\"}")
    match buildWebSocketUpgradeResponse? req with
    | some raw101 => return .error raw101
    | none => return .ok (jsonResponse 400 "{\"error\":\"invalid_websocket_upgrade\"}")

  -- 4. Public `/v1/*` LLM Proxy
  if cleanPath.startsWith "/v1/" then
    let chains ← st.chainsRef.get
    let activeChain := chains[0]?.getD { id := "default", name := "default", targets := #[] }
    let out ← forwardProxyChain activeChain req.method cleanPath #[] req.bodySlice.toByteArray
    return .ok { status := out.status, extraHdrs := out.headers, body := out.body }

  -- 5. Public Privilege Broker Verification (`POST /api/privilege-access/verify-and-log`)
  if req.method == "POST" && cleanPath == "/api/privilege-access/verify-and-log" then
    if !authenticateHttpBearer st.cfg req.headers nowEpochSec then
      return .ok (jsonResponse 401 "{\"allowed\":false,\"error\":\"unauthorized\"}")
    return .ok (jsonResponse 200 "{\"allowed\":true,\"scope\":\"ops_read\"}")

  -- 6. Protected Routes (`require_auth`)
  if !authenticateHttpBearer st.cfg req.headers nowEpochSec then
    return .ok (jsonResponse 401 "{\"error\":\"unauthorized\"}")

  -- Mission Automations (`"/api/control/missions/:id/automations"`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/automations" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if req.method == "GET" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,mission_id,cron_expr,prompt,enabled,created_at FROM mission_automations WHERE mission_id=?1 ORDER BY created_at ASC;" #[mid]
      return .ok (jsonResponse 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let aid := (JsonTape.lookupString? tape "id").getD s!"auto-{nowEpochSec}"
      let cron := (JsonTape.lookupString? tape "cron_expr").getD "0 * * * *"
      let prompt := (JsonTape.lookupString? tape "prompt").getD ""
      let _ ← execParamQuery st.store.missionsDb
        "INSERT OR REPLACE INTO mission_automations(id,mission_id,cron_expr,prompt,enabled,created_at) VALUES(?1,?2,?3,?4,'1',?5);"
        #[aid, mid, cron, prompt, s!"{nowEpochSec}"]
      return .ok (jsonResponse 201 s!"\{\"id\":{jsonEscape aid},\"mission_id\":{jsonEscape mid}}")

  -- Mission Opened (`POST /api/control/missions/:id/opened`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/opened" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let _ ← mark_mission_opened st.store mid s!"{nowEpochSec}"
      return .ok (jsonResponse 200 "{\"ok\":true}")

  -- Mission Machine Transfer (`GET|POST /api/control/missions/:id/machine-transfer`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/machine-transfer" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if req.method == "GET" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,mission_id,phase,revision,created_at FROM machine_transfers WHERE mission_id=?1 ORDER BY created_at ASC;" #[mid]
      return .ok (jsonResponse 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let dest := (JsonTape.lookupString? tape "destination").getD "local"
      let reqKey := (JsonTape.lookupString? tape "request_key").getD s!"rk-{nowEpochSec}"
      let srcRev := (JsonTape.lookupString? tape "source_revision").getD ""
      let srcGen := ((JsonTape.lookupNat? tape "source_generation").getD 0).toUInt64
      let txRec : TransferRecord := {
        id := s!"tx-{nowEpochSec}", missionId := mid, requestKey := reqKey, revision := 0,
        phase := "preparing", destination := dest, sourceRevision := srcRev,
        sourceGeneration := srcGen, generation := 0, createdAt := s!"{nowEpochSec}"
      }
      match ← startMachineTransfer st.store txRec with
      | .ok out => return .ok (jsonResponse 201 s!"\{\"id\":{jsonEscape out.id},\"generation\":{out.generation},\"phase\":\"preparing\"}")
      | .error e => return .ok (jsonResponse 409 s!"\{\"error\":{jsonEscape e}}")

  -- Missions Collection (`GET|POST /api/control/missions`)
  if cleanPath == "/api/control/missions" then
    if req.method == "GET" then
      match ← listMissionsJson st.store with
      | .ok j => return .ok (jsonResponse 200 j)
      | .error e => return .ok (jsonResponse 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let mid := (JsonTape.lookupString? tape "id").getD s!"m-{nowEpochSec}"
      let title := (JsonTape.lookupString? tape "title").getD "New Mission"
      let backend := (JsonTape.lookupString? tape "backend").getD "codex"
      let rawEffort := (JsonTape.lookupString? tape "model_effort").getD ""
      let _effort? := normalizeModelEffortForBackend (some backend) rawEffort
      let workDir := (JsonTape.lookupString? tape "working_directory").getD st.cfg.workingDir
      let mRec : MissionRecord := {
        id := mid, title := title, status := "awaiting_user", backend := backend,
        modelOverride := "", workingDirectory := workDir, updatedAt := s!"{nowEpochSec}", totalCostCents := 0
      }
      let _ ← upsertMission st.store mRec
      return .ok (jsonResponse 201 s!"\{\"id\":{jsonEscape mid},\"status\":\"awaiting_user\",\"total_cost_cents\":0}")

  -- Mission Search (`GET /api/control/missions/search`)
  if req.method == "GET" && cleanPath == "/api/control/missions/search" then
    let qParams := parseQueryParams rawTarget
    let q := (qParams.find? (fun p => p.1 == "q")).map Prod.snd |>.getD ""
    match st.searchIdx? with
    | none => return .ok (jsonResponse 200 "{\"hits\":[]}")
    | some sIdx =>
      let hits ← queryConversations sIdx q 32
      let hitJson := "[" ++ String.intercalate "," (hits.toList.map jsonEscape) ++ "]"
      return .ok (jsonResponse 200 s!"\{\"hits\":{hitJson}}")

  -- Model Routing Controls (`"/api/model-routing"` / `/api/model-routing/chains`)
  if cleanPath.startsWith "/api/model-routing" then
    if req.method == "GET" && cleanPath == "/api/model-routing/chains" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,name,models_json,updated_at FROM model_routing_chains ORDER BY id ASC;" #[]
      return .ok (jsonResponse 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" && cleanPath == "/api/model-routing/chains" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let cid := (JsonTape.lookupString? tape "id").getD s!"chain-{nowEpochSec}"
      let nm := (JsonTape.lookupString? tape "name").getD cid
      let _ ← execParamQuery st.store.missionsDb
        "INSERT OR REPLACE INTO model_routing_chains(id,name,models_json,updated_at) VALUES(?1,?2,'[]',?3);"
        #[cid, nm, s!"{nowEpochSec}"]
      return .ok (jsonResponse 201 s!"\{\"id\":{jsonEscape cid},\"name\":{jsonEscape nm}}")
    else
      return .ok (jsonResponse 200 "{\"ok\":true,\"router\":\"/api/model-routing\"}")

  -- Managed Compute Fleet (`/api/managed-machines/spend`, `/api/remote-nodes`)
  if req.method == "GET" && (cleanPath == "/api/managed-machines/spend" || cleanPath == "/api/managed-machines") then
    let mf ← st.managedRef.get
    return .ok (jsonResponse 200 (renderManagedBudgetJson mf))

  if req.method == "GET" && cleanPath == "/api/remote-nodes" then
    let mf ← st.managedRef.get
    return .ok (jsonResponse 200 s!"\{\"nodes\":[],\"managed_compute\":{renderManagedBudgetJson mf}}")

  return .ok (jsonResponse 404 s!"\{\"error\":\"not_found\",\"path\":{jsonEscape cleanPath}}")

/-- Serve one accepted TCP connection on `cfd`. -/
def handleClientConn (st : CoreAppState) (cfd : Fd) : IO Unit := do
  match ← pollReadable cfd 5000 with
  | .error _ => discard <| closeFd cfd
  | .ok () =>
    let raw ← readStreamChunk cfd 65536
    if raw.isEmpty then
      discard <| closeFd cfd
    else
      let nowSec ← coreEpochSec
      match parseRequest raw none with
      | .error _ =>
        let resp := encodeCoreHttpResponse (jsonResponse 400 "{\"error\":\"bad_http_request\"}")
        discard <| writeAll cfd resp false
        discard <| closeFd cfd
      | .ok req =>
        match ← dispatchCoreRequest st req nowSec with
        | .ok httpResp =>
          discard <| writeAll cfd (encodeCoreHttpResponse httpResp) false
          discard <| closeFd cfd
        | .error rawUpgrade101 =>
          discard <| writeAll cfd rawUpgrade101 false
          let closeFrame := (encodeFrame? { fin := true, opcode := .close, payload := ByteArray.empty } none).getD ByteArray.empty
          discard <| writeAll cfd closeFrame false
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
    let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
    let appState : CoreAppState := {
      cfg := cfg
      store := store
      searchIdx? := searchRes.toOption
      managedRef := managedRef
      chainsRef := chainsRef
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
      | .ok cfd =>
        served := served + 1
        handleClientConn appState cfd
      | .error _ =>
        pure ()
    discard <| closeFd listenFd
    closeCoreStore store
    return 0

end OrbCore.Control
